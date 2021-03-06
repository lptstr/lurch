(local inspect   (require :inspect))
(local F         (require :fun))
(local mirc      (require :mirc))
(local tb        (require :tb))
(local termbox   (require :termbox))
(local utf8utils (require :utf8utils))
(local util      (require :util))

(local format   string.format)
(local assert_t util.assert_t)

(var M {}) 
(tset M :linefmt_func            nil)
(tset M :prompt_func             nil)
(tset M :statusline_func         nil)
(tset M :bottom_statusline_func  nil)
(tset M :set_colors               {})
(tset M :colors                   {})
(tset M :tty_height               80)
(tset M :tty_width                24)

(lambda M.refresh []
  (let [(y x) (termbox.size)]
    (tset M :tty_height y)
    (tset M :tty_width  x)))

(lambda _hash [str]
  (fn _hash_fn [hsh _ char]
    (var hsh hsh)
    (set hsh (bxor hsh (utf8.codepoint char)))
    (set hsh (* hsh 0x5be7413b))
    (set hsh (bxor hsh (rshift hsh 15)))
    hsh)

  ; "avalanche"
  (var hsh (-?>> [(F.iter str)]
                 (F.foldl 0 _hash_fn)))
  (set hsh (+ hsh (lshift hsh 3)))
  (set hsh (bxor hsh (rshift hsh 23)))
  (+ hsh (lshift hsh 15)))

(lambda M.highlight [text ?text_as ?no_bold?]
  (assert_t [text :string :text])

  (var ?text_as ?text_as)
  (when (not ?text_as) (set ?text_as text))

  ; store nickname highlight color, so that we don't have to
  ; calculate the text's hash each time.
  (when (not (. M :set_colors ?text_as))
    ; Add one to the hash, as it could be zero. This could cause
    ; problems because we use the hash as the index for the color table.
    (var hash (% (_hash ?text_as) (- (length M.colors) 1)))
    (set hash (+ hash 1))

    (let [color (. M :colors hash)]
      (tset M :set_colors ?text_as color)))

  (var esc (if ?no_bold? "" mirc.BOLD))

  (let [color (. M :set_colors ?text_as)]
    (when color
      (set esc (.. esc (format "%s%003d" mirc._256COLOR color)))))
  (format "%s%s%s" esc text mirc.RESET))


(lambda M.prompt [inp cursor]
  (assert_t [inp :string :inp] [cursor :number :cursor])

  ; if the user has scrolled up, don't draw the input field.
  (if (not= (. bufs cbuf :scroll) 0)
    (do
      (termbox.writeline (- M.tty_height 1) "\x16\x02 -- more -- \x0f")
      (termbox.setcursor tb.TB_HIDE_CURSOR tb.TB_HIDE_CURSOR))
    (termbox.writeline (- M.tty_height 1) (M.prompt_func inp cursor))))


(lambda M.statusline []
  (termbox.writeline 0 (M.statusline_func)))


(lambda M.bottom_statusline []
  (when M.bottom_statusline_func
    (termbox.writeline (- M.tty_height 2) (M.bottom_statusline_func))))


(lambda M.format_line [timestr left right timew leftw ?rightw]
  (assert_t [timestr :string :timestr] [timew :number :timew]
            [left :string :left] [right :string :right]
            [leftw :number :leftw])

  (var leftw leftw)
  (var right right)

  ; fold message to width, like /bin/fold
  (when (= leftw 0)
    (set leftw (# left)))
  (let [infow (+ leftw timew)
        width (- (or ?rightw M.tty_width) infow)
        rpadd (string.rep " " (+ infow 2))]
    (set right (util.fold right (- width 4)))
    (set right (right:gsub "\n" (.. "%1" rpadd))))

  ; Strip escape sequences from the left column so that
  ; we can calculate how much padding to add for alignment, and
  ; not get confused by the invisible escape sequences.
  (local raw (mirc.remove left))

  ; Generate a cursor right sequence based on the length of
  ; the above "raw" word. The nick column is a fixed width
  ; of LEFT_PADDING so it's simply 'LEFT_PADDING - word_len'
  (var left_pad (- (+ leftw 1) (utf8utils.dwidth raw)))
  (var time_pad (- (+ timew 1) (utf8utils.dwidth timestr)))
  (when (> (length raw)     leftw) (set left_pad 0))
  (when (> (length timestr) timew) (set time_pad 0))

  (M.linefmt_func time_pad left_pad timestr left right))

; if not bufs[cbuf].history then return end
(lambda M.buffer_text [timew leftw ?rightw]
  ; beginning at the bottom of the terminal, draw each line
  ; of text from that buffer's history, then move up.
  ; If there is nothing to draw, just clear the line and
  ; move on.
  ;
  ; this bottom-up approach is used because we don't know in
  ; advance how many lines a particular history entry will take
  ; up, and thus don't know how many history events will fit
  ; on the screen.

  ; keep one blank line in between statusline and text, and
  ; don't overwrite the prompt/inputline.
  (let [linestart 1
        lineend   (if (not M.bottom_statusline_func)
                    (- M.tty_height 2)
                    (- M.tty_height 3))
        h_st      (- (length (. bufs cbuf :history)) (- M.tty_height 4))
        h_end     (length (. bufs cbuf :history))
        scr       (. bufs cbuf :scroll)]
    (var line lineend)

    (lambda _process_msg [msg]
      ; fold the text to width. this is done now, instead
      ; of when prin_*() is called, so that when the terminal
      ; size changes we can fold text according to the new
      ; terminal width when the screen is redrawn.
      (var out (M.format_line (. msg 1) (. msg 2) (. msg 3)
                              timew leftw ?rightw))

      ; Reset colors/attributes before drawing the line.
      (termbox.writeline line mirc.RESET)

      ; Get the lines in the message, and move the cursor up.
      (var msglines (-?>> [(out:gmatch "([^\n]+)\n?")] (F.collect #$)))
      (set line (- line (length msglines)))

      ; Print each line and move down.
      (-?>> [(F.iter msglines)]
            (F.map #(do
                      (set line (+ line 1))
                      (when (> line linestart)
                        (termbox.writeline line $2)))))

      ; Move the cursor back up to prepare to draw the next message.
      (set line (- line (length msglines))))

    (-?>> [(F.range (- h_end scr) (- h_st scr) -1)]
          (F.map #(when (> line linestart)
                   (let [msg (. bufs cbuf :history $1)]
                     (if msg
                       (_process_msg msg)
                       (set line (- line 1)))))))))

(lambda M.redraw [inbuf incurs timew leftw ?rightw]
    (M.refresh)
    (termbox.clear)
    (M.statusline)
    (M.bottom_statusline)
    (M.buffer_text timew leftw ?rightw)
    (M.prompt inbuf incurs))

M
