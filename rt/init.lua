-- lurch: an extendable irc client in lua
-- (c) Kiëd Llaentenn

local rt = {}

-- Add config paths to package.path before require'ing
-- config module
package.path = "/home/" .. os.getenv("USER") .. "/.config/lurch/?.lua;" .. package.path
if os.getenv("XDG_CONFIG_HOME") then
    package.path = os.getenv("XDG_CONFIG_HOME") .. "/lurch/?.lua;" .. package.path
end
package.path = __LURCH_EXEDIR .. "/conf/?.lua;" .. package.path
if os.getenv("LURCH_CONFIG") then
    package.path = os.getenv("LURCH_CONFIG") .. "/?.lua;" .. package.path
end

local config = require('config')

-- ----------------------------------

local inspect = require('inspect')

local irc       = require('irc')
local callbacks = require('callbacks')
local logs      = require('logs')
local mirc      = require('mirc')
local util      = require('util')
local tui       = require('tui')
local tb        = require('tb')
local termbox   = require('termbox')
local tbrl      = require('tbrl')
local lurchconn = require('lurchconn')

local printf    = util.printf
local eprintf   = util.eprintf
local panic     = util.panic
local format    = string.format
local hcol      = tui.highlight
local assert_t  = util.assert_t

-- Ugly globals
_G.irc_ctx = irc

L_NAME  = config.leftfmt.names
L_TOPIC = config.leftfmt.topic
L_ERR   = config.leftfmt.error
L_NORM  = config.leftfmt.normal
L_AWAY  = config.leftfmt.away
L_NICK  = config.leftfmt.nick

SRVCONF = config.servers[config.server]
DBGFILE = "/tmp/lurch_debug"

reconn      = config.reconn  -- Number of times we've reconnected.
reconn_wait = 5              -- Seconds to wait before reconnecting.
nick        = SRVCONF.nick   -- The current nickname
cbuf        = nil            -- The current buffer
bufs        = {}             -- List of all opened buffers

function hncol(_nick)
    return tui.highlight(_nick, irc.normalise_nick(_nick))
end

-- a simple wrapper around irc.connect.
function connect()
    local user  = SRVCONF.user or os.getenv("USER")
    local name  = SRVCONF.name or _nick
    local pass  = SRVCONF.pass

    local r, e = irc.connect(SRVCONF.host, SRVCONF.port, SRVCONF.tls,
        nick, user, name, pass, SRVCONF.caps, SRVCONF.no_ident)
    return r, e
end

-- a simple wrapper around tui.redraw.
function redraw()
    tui.redraw(tbrl.bufin[tbrl.hist], tbrl.cursor, config.time_col_width,
        config.left_col_width, config.right_col_width)
end

-- a simple wrapper around irc.send.
function send(fmt, ...)
    if not lurchconn.is_active() then
        return
    end

    if os.getenv("LURCH_DEBUG") then
        util.append(DBGFILE,
            format("%s <s< %s\n", os.time(), format(fmt, ...)))
    end

    irc.send(fmt, ...)
end

-- add a new buffer. statusline() should be run after this
-- to add the new buffer to the statusline.
function buf_add(name)
    assert_t({name, "string", "name"})

    local newbuf = {}
    newbuf.history = {}     -- lines in buffer.
    newbuf.name    = name
    newbuf.unreadh = 0      -- high-priority unread messages
    newbuf.unreadl = 0      -- low-priority unread messages
    newbuf.pings   = 0      -- maximum-priority unread messages
    newbuf.scroll  = 0      -- scroll offset.
    newbuf.names   = {}     -- nicknames in buffer/channel.
    newbuf.access  = {}     -- privilege for nicknames. (e.g. ~, @, +)

    local n_idx = #bufs + 1
    bufs[n_idx] = newbuf
    return n_idx
end

-- Clear all unread notifications for a buffer. statusline() should
-- be run after this.
function buf_read(idx)
    assert(bufs[idx])

    bufs[idx].unreadl = 0
    bufs[idx].unreadh = 0
    bufs[idx].pings   = 0

    callbacks.on_cleared_unread(idx)
end

function buf_scroll(idx, rel, abs)
    assert(bufs[idx])
    local bufsz = #bufs[idx].history

    if rel then
        bufs[idx].scroll = bufs[idx].scroll + rel
    elseif abs then
        bufs[idx].scroll = abs
    end

    if bufs[idx].scroll < 0 then bufs[idx].scroll = 0 end
    if bufs[idx].scroll > bufsz then bufs[idx].scroll = bufsz - 5 end
    if bufs[idx].scroll == 0 then buf_read(idx) end
end

-- check if a buffer exists, and if so, return the index
-- for that buffer.
function buf_idx(name)
    for i = 1, #bufs do
        if bufs[i].name == name then return i end
    end
    return nil
end

function buf_cur()
    return bufs[cbuf].name
end

function buf_idx_or_add(name)
    local idx = buf_idx(name)
    if not idx then idx = buf_add(name) end
    return idx
end

function buf_with_nick(name, fn, mainbuf)
    for i, buf in ipairs(bufs) do
        if buf.names[name] then
            if not mainbuf and i == 1 then
                -- skip
            else
                fn(i, buf)
            end
        end
    end
end

function buf_addname(bufidx, name)
    bufs[bufidx].names[name] = true
    bufs[buf_idx(MAINBUF)].names[name] = true
end

-- switch to a buffer and redraw the screen.
function buf_switch(ch)
    if bufs[ch] then
        cbuf = ch

        -- reset scroll, unread notifications
        buf_read(ch)
        buf_scroll(ch, nil, 0)

        redraw()
    end
end

-- check if a message will ping a user.
function msg_pings(sender, msg)
    -- can't ping yourself.
    if sender and sender == nick then
        return false
    end

    local rawmsg = mirc.remove(msg)
    local pingwords = config.pingwords
    pingwords[#pingwords + 1] = nick

    for _, pingw in ipairs(pingwords) do
        if rawmsg:find(pingw) then
            return true
        end
    end

    return false
end

-- print a response to an irc message.
local last_ircevent = nil
function prin_irc(prio, dest, left, right_fmt, ...)
    assert(last_ircevent)
    local right = format(right_fmt, ...)

    -- get the offset defined in the configuration and parse it.
    local offset = assert(util.parse_offset(config.tz))
    local time

    local ignlvl = nil
    for pat, lvl in pairs(config.ignores) do
        local sndr = last_ircevent.from
        if sndr and (sndr):match(pat) then
            ignlvl = lvl:upper(); break
        end
    end

    -- If the user is ignored, skip printing and logging.
    if ignlvl == "B" then return end

    -- if server-time is available, use that time instead of the
    -- local time.
    if irc.server.caps["server-time"] and last_ircevent.tags.time then
        -- the server-time is stored as a tag in the IRC message, in the
        -- format yyyy-mm-ddThh:mm:ss.sssZ, but is in the UTC timezone.
        -- convert it to the timezone the user wants.
        local srvtime = last_ircevent.tags.time
        local utc_time   = util.time_from_iso8601(srvtime)
        time = utc_time + (offset * 60 * 60)
    else
        time = util.time_with_offset(offset)
    end

    -- Only log JOIN, PART, QUIT, MODE(+b), PRIVMSG, and NOTICE
    -- because litterbox's unscoop utility ignores anything else
    local last_cmd = last_ircevent.fields[1]
    if last_cmd == "JOIN" or last_cmd == "PART"
    or last_cmd == "QUIT" or last_cmd == "MODE"
    or last_cmd == "PRIVMSG" or last_cmd == "NOTICE" then
        logs.append(dest, last_ircevent)
    end

    -- If the user is dimmed, color the message/sender a light grey.
    if ignlvl == "D" then
        right = mirc.grey(mirc.remove(right))
        left  = mirc.grey(mirc.remove(left))
    end

    -- If the user is filtered, skip printing.
    if ignlvl ~= "F" then
        prin(prio, time, dest, left, right)
    end
end

-- print text in response to a command.
function prin_cmd(dest, left, right_fmt, ...)
    last_ircevent = nil

    local priority = 1
    if left == L_ERR() then priority = 2 end

    -- get the offset defined in the configuration and parse it.
    local offset = assert(util.parse_offset(config.tz))

    local now = util.time_with_offset(offset)
    prin(priority, now, dest, left, format(right_fmt, ...))
end

function prin(priority, time, dest, left, right)
    assert_t({time, "number", "time"}, {dest, "string", "dest"},
        {left, "string", "left"}, {right, "string", "right"})

    local timestr = os.date(config.timefmt, time)

    -- keep track of whether we should redraw the statusline afterwards.
    local redraw_statusline = false

    local bufidx = buf_idx(dest)
    if not bufidx then
        bufidx = buf_add(dest)
        redraw_statusline = true
    end

    -- Add the output to the history and wait for it to be drawn.
    local histsz = #bufs[bufidx].history
    bufs[bufidx].history[histsz + 1] = { timestr, left, right }

    -- if the buffer we're writing to is focused and is not scrolled up,
    -- draw the text; otherwise, add to the list of unread notifications
    local cb = bufs[cbuf]
    if dest == cb.name and cb.scroll == 0 then
        redraw()
    else
        if priority == 0 then
            bufs[bufidx].unreadl = bufs[bufidx].unreadl + 1
        elseif priority == 1 then
            bufs[bufidx].unreadh = bufs[bufidx].unreadh + 1
        elseif priority == 2 then
            bufs[bufidx].pings = bufs[bufidx].pings + 1
        end

        redraw_statusline = true
        callbacks.on_unread(priority, bufidx, time, left,
            right, last_ircevent)
    end

    if redraw_statusline then tui.statusline() end
end

local function none(_) end
local function default2(e)
    prin_irc(0, MAINBUF, L_NORM(e), "There are %s %s", e.fields[3], e.msg)
end
local function default(e) prin_irc(0, e.dest, L_NORM(e), "%s", e.msg) end
local function hndfact_err(m)
    return function(e)
        prin_irc(1, e.dest or MAINBUF, L_ERR(e), "%s", m or e.msg)
    end
end

local irchand = {
    ["ACCOUNT"] = function(e)
        assert(irc.server.caps["account-notify"])

        -- account-notify is enabled, and the server is notifying
        -- us that one user has logged in/out of an account
        local msg
        local account = e.fields[2] or e.msg
        if not account then
            msg = format("%s has unidentified", hncol(e.nick))
        else
            msg = format("%s has identified as %s", hncol(e.nick), account)
        end

        buf_with_nick(e.nick, function(_, buf)
            prin_irc(0, buf.name, L_NORM(e), "(Account) %s", msg)
        end)
    end,
    ["AWAY"] = function(e)
        assert(irc.server.caps["away-notify"])

        -- away notify is enabled, and the server is giving us the
        -- status of a user in a channel.
        --
        -- TODO: keep track of how long users are away, and when they
        -- come back, set the message to "<nick> is back (gone <time>)"
        local msg
        if not e.msg or e.msg == "" then
            msg = format("%s is back", hncol(e.nick))
        else
            msg = format("%s is away: %s", hncol(e.nick), e.msg)
        end

        buf_with_nick(e.nick, function(_, buf)
            prin_irc(0, buf.name, L_AWAY(e), "%s", msg)
        end)
    end,
    ["MODE"] = function(e)
        if not e.dest then e.dest = e.msg end
        if (e.dest):find("#") then
            e.fields[#e.fields + 1] = e.msg
            local by   = e.nick or e.from
            local mode = util.join(" ", e.fields, 3)
            prin_irc(0, e.dest, L_NORM(e), "Mode [%s] by %s", mode, hncol(by))
        elseif e.nick == nick then
            prin_irc(0, MAINBUF, L_NORM(e), "Mode %s", e.msg)
        else
            prin_irc(0, MAINBUF, L_NORM(e), "Mode %s by %s", e.msg,
                hncol(e.nick or e.from))
        end
    end,
    ["NOTICE"] = function(e)
        local prio = 1
        if msg_pings(e.nick, e.msg) then prio = 2 end

        local dest = e.dest
        if dest == "*" or not dest then dest = MAINBUF end

        if e.nick then
            prin_irc(prio, dest, "NOTE", "<%s> %s", hncol(e.nick), e.msg)
        else
            prin_irc(prio, dest, "NOTE", "%s", e.msg)
        end
    end,
    ["TOPIC"] = function(e)
        prin_irc(0, e.dest, L_TOPIC(e), "%s changed the topic to \"%s\"",
            hncol(e.nick), e.msg)
    end,
    ["PART"] = function(e)
        local idx = buf_idx_or_add(e.dest)
        bufs[idx].names[e.nick] = false
        local userhost = e.user .. "@" .. e.host
        prin_irc(0, e.dest, "<--", "%s (%s) has left %s (%s)",
            hncol(e.nick), mirc.grey(userhost), hcol(e.dest), e.msg)
    end,
    ["KICK"] = function(e)
        local p = 0
        if e.fields == nick then p = 2 end -- if the user was kicked, ping them
        prin_irc(p, e.dest, "<--", "%s has kicked %s (%s)", hncol(e.nick),
            hncol(e.fields[3]), e.msg)
    end,
    ["INVITE"] = function(e)
        -- TODO: auto-join on invite?
        prin_irc(2, MAINBUF, L_NORM(e), "%s invited you to %s",
            hncol(e.nick), hcol(e.fields[3] or e.msg))
    end,
    ["PRIVMSG"] = function(e)
        local sender = e.nick or e.from
        local pings = msg_pings(sender, e.msg)
        local sndfmt = config.leftfmt.message(sender, pings)

        local prio = 1
        if pings then prio = 2 end

        -- convert or remove mIRC IRC colors.
        if not config.mirc then e.msg = mirc.remove(e.msg) end

        prin_irc(prio, e.dest, sndfmt, "%s", e.msg)
    end,
    ["QUIT"] = function(e)
        -- display quit message for all buffers that user has joined,
        -- except the main buffer.
        local userhost = e.user .. "@" .. e.host
        buf_with_nick(e.nick, function(i, buf)
            prin_irc(0, buf.name, "<--", "%s (%s) quit (%s)",
                hncol(e.nick), mirc.grey(userhost), e.msg)
            bufs[i].names[e.nick] = false
        end)
        bufs[1].names[e.nick] = false
    end,
    ["JOIN"] = function(e)
        -- sometimes the channel joined is contained in the message.
        if not e.dest or e.dest == "" then e.dest = e.msg end

        -- if the buffer isn't open yet, create it.
        local bufidx = buf_idx_or_add(e.dest)

        -- add to the list of users in that channel.
        buf_addname(bufidx, e.nick)

        -- if we are the ones joining, then switch to that buffer.
        if e.nick == nick then buf_switch(bufidx) end

        local userhost = e.user .. "@" .. e.host
        prin_irc(0, e.dest, "-->", "%s (%s) joined %s",
            hncol(e.nick), mirc.grey(userhost), hcol(e.dest))
    end,
    ["NICK"] = function(e)
        -- copy across nick information (this preserves nick highlighting across
        -- nickname changes), and display the nick change for all bufs that
        -- have that user
        for i = 2, #bufs do
            local buf = bufs[i]
            if buf.names[e.nick]
            or buf.name == e.nick or e.nick == nick then
                prin_irc(0, buf.name, L_NICK(e), "%s is now known as %s",
                    hncol(e.nick), hncol(e.msg))
                buf.names[e.nick] = nil; buf.names[e.msg] = true
            end
        end
        tui.set_colors[e.msg]  = tui.set_colors[e.nick]
        tui.set_colors[e.nick] = nil

        -- if the user changed the nickname, update the current nick.
        if e.nick == nick then nick = e.msg end
    end,

    -- Welcome to the xyz Internet Relay Chat Network, foo!
    ["001"] = default,

    -- Your host is irc.foo.net, running ircd-version
    ["002"] = default,

    -- This server was created on January 1, 2020.
    ["003"] = default,

    -- RPL_MYINFO
    -- <servername> <version> <available user modes> <available chan modes>
    -- I am not aware of any situation in which the user would need to see
    -- this useless information.
    ["004"] = none,

    -- I'm not really sure what 005 is. RFC2812 states that this is RPL_BOUNCE,
    -- telling the user to try another server as the one they connected to has
    -- reached the maximum number of connected clients.
    --
    -- However, freenode sends something that seems to be something entirely
    -- different. Here's an example:
    --
    -- :card.freenode.net 005 nick CNOTICE KNOCK :are supported by this server
    --
    -- Anyway, I don't think anyone is interested in seeing this info.
    ["005"] = none,

    -- 251: There are x users online
    -- 252: There are x operators online
    -- 253: There are x unknown connections
    -- 254: There are x channels formed
    -- 250, 255, 265, 266: Some junk
    ["251"] = default, ["252"] = default2, ["253"] = default2, ["254"] = default2,
    ["255"] = none,    ["265"] = none,     ["266"] = none,     ["250"] = none,

    -- WHOIS: <nick> has TLS cert fingerprint of sdflsd453lkd8
    ["276"] = function(e)
        prin_irc(0, buf_cur(), "WHOIS", "[%s] %s", hncol(e.fields[3]), e.msg)
    end,

    -- AWAY: otinuikaj10 is away: "Away message"
    -- Sent when you message a user that is marked as being away.
    ["301"] = function(e)
        prin_irc(1, e.fields[3], L_AWAY(e), "%s is away: %s",
            hncol(e.fields[3]), e.msg)
    end,

    -- AWAY: You are no longer marked as being away
    ["305"] = function(e)
        util.ivmap(bufs, function(_, v)
            prin_irc(0, v.name, L_AWAY(e), "You are no longer marked as being away.")
        end)
    end,

    -- AWAY: You have been marked as being away
    ["306"] = function(e)
        util.ivmap(bufs, function(_, v)
            prin_irc(0, v.name, L_AWAY(e), "You have been marked as being away.")
        end)
    end,

    -- WHOIS: <nick> is a registered nick
    ["307"] = function(e)
        prin_irc(0, buf_cur(), "WHOIS", "[%s] %s", hncol(e.fields[3]), e.msg)
    end,

    -- WHOIS: RPL_WHOISUSER (response to /whois)
    -- <nick> <user> <host> * :realname
    ["311"] = function(e)
        prin_irc(0, buf_cur(), "WHOIS", "[%s] (%s!%s@%s): %s", hncol(e.fields[3]),
            e.fields[3], e.fields[4], e.fields[5], e.msg)
    end,

    -- WHOIS: RPL_WHOISSERVER (response to /whois)
    -- <nick> <server> :serverinfo
    ["312"] = function(e)
        prin_irc(0, buf_cur(), "WHOIS", "[%s] %s (%s)", hncol(e.fields[3]), e.fields[4], e.msg)
    end,

    -- WHOWAS: RPL_WHOWASUSER
    -- <nick> <user> <host> * :<Real name>
    ["314"] = function(e)
        local nic = e.fields[3]
        prin_irc(0, buf_cur(), "WHOWAS", "[%s] (%s!%s@%s): %s",
            hncol(nic), nic, e.fields[4], e.fields[5], e.msg)
    end,

    -- WHO: RPL_ENDOFWHO
    ["315"] = function(_)
        --
        -- Disabled. Since 352 (RPL_WHOREPLY) is the only reply we get
        -- from a WHO query, this message is unnecessary.
        --
        -- Also, printing it may generate confusion, as $fields[3] is the
        -- text the *user* sent as an argument to /who, not the nick/username
        -- the server interpreted that argument as... so the "nick" printed
        -- by 352 and the nick printed here won't always match.
        --
        --prin_irc(0, buf_cur(), "WHO", "[%s] End of WHO info.",
        --    hncol(e.fields[3]))
    end,

    -- WHOIS: <nick> has been idle for 45345 seconds, and has been online
    -- since 4534534534
    ["317"] = function(e)
        prin_irc(0, buf_cur(), "WHOIS", "[%s] has been idle for %s",
            hncol(e.fields[3]), util.fmt_duration(tonumber(e.fields[4])))

        -- not all servers send the "has been online" bit...
        if e.fields[5] then
            prin_irc(0, buf_cur(), "WHOIS", "[%s] has been online since %s",
                hncol(e.fields[3]), os.date("%Y-%m-%d %H:%M", e.fields[5]))
        end
    end,

    -- End of WHOIS
    ["318"] = function(e)
        prin_irc(0, buf_cur(), "WHOIS", "[%s] End of WHOIS info.", hncol(e.fields[3]))
    end,

    -- WHOIS: <user> has joined #chan1, #chan2, #chan3
    ["319"] = function(e)
        prin_irc(0, buf_cur(), "WHOIS", "[%s] has joined %s", hncol(e.fields[3]), e.msg)
    end,

    -- URL for channel
    ["328"] = function(e) prin_irc(0, e.dest, "URL", "%s", e.msg) end,

    -- WHOIS: <nick> is logged in as <user> (response to /whois)
    ["330"] = function(e)
        prin_irc(0, buf_cur(), "WHOIS", "[%s] is logged in as %s", hncol(e.fields[3]),
            hcol(e.fields[4]))
    end,

    -- No topic set
    ["331"] = function(e) prin_irc(0, e.dest, L_ERR(e), "No topic set for %s", e.dest) end,

    -- TOPIC for channel
    ["332"] = function(e) prin_irc(0, e.dest, L_TOPIC(e), "%s", e.msg) end,

    -- TOPIC last set by nick!user@host
    ["333"] = function(e)
        -- sometimes, the nick is in the fields
        local n, userhost = (e.fields[4]):gmatch("(.-)!(.*)")()
        if n then
            prin_irc(0, e.dest, L_NORM(e), "Topic last set by %s (%s)",
                hncol(n), mirc.grey(userhost))
        else
            local datetime = os.date("%Y-%m-%d %H:%M:%S", tonumber(e.msg))
            prin_irc(0, e.dest, L_NORM(e), "Topic last set by %s on %s",
                hncol(e.fields[4]), datetime)
        end
    end,

    -- invited <nick> to <chan> (response to /invite)
    ["341"] = function(e)
        prin_irc(0, e.msg, L_NORM(e), "Invited %s to %s",
            hncol(e.fields[3]), hcol(e.msg))
    end,

    -- WHO: RPL_WHOREPLY (WHO information)
    -- <channel> <user> <host> <server> <nick> <H|G>[*][@|+] :<hopcount> <real>
    ["352"] = function(e)
        prin_irc(0, buf_cur(), "WHO", "[%s] is %s (%s!%s@%s): (%s) %s",
            hncol(e.fields[7]), mirc.bold(e.fields[4]), e.fields[7], e.fields[4],
            e.fields[5], hcol(e.fields[3]), e.msg)
    end,

    -- Reply to /names
    ["353"] = function(e)
        -- if the buffer isn't open yet, create it.
        local bufidx = buf_idx_or_add(e.dest)

        local nicklist = ""

        for _nick in (e.msg):gmatch("([^%s]+)%s?") do
            local access = ""
            if _nick:find("[%~@%%&%+!]") then
                access = _nick:gmatch(".")()
                _nick = _nick:gsub(access, "")
            end

            nicklist = format("%s%s%s ", nicklist, access, hncol(_nick))

            -- TODO: update access with mode changes
            -- TODO: show access in PRIVMSGs
            buf_addname(bufidx, _nick)
            bufs[bufidx].access[_nick] = access
        end

        prin_irc(0, e.dest, L_NAME(e), "%s", nicklist)
    end,

    -- End of /names
    ["366"] = function(e)
        local dest   = assert(e.dest)
        local bufidx = assert(buf_idx(dest))

        -- print a nice summary of those in the channel.
        --
        -- peasants:   normals, those without a special mode
        -- loudmouths: those with +v (voices)
        -- halfwits:   those with +h (halfops)
        -- operators:  those with +o
        -- founders:   those with +q (XXX: on InspirCD. isn't +q == 'quiet' with other IRCDs?)
        -- irccops:    those with +Y (server admins)
        local peasants,  loudmouths, halfwits
        local operators, founders,   irccops
        peasants  = 0; loudmouths = 0; halfwits = 0;
        operators = 0; founders   = 0; irccops  = 0;

        local total = 0

        util.kvmap(bufs[bufidx].names, function(k, _)
            local access = bufs[bufidx].access[k]
            if not access then return end

            if access == "!" then
                irccops = irccops + 1
            elseif access == "~" then
                founders = founders + 1
            elseif access == "@" then
                operators = operators + 1
            elseif access == "&" then
                halfwits = halfwits + 1
            elseif access == "+" then
                loudmouths = loudmouths + 1
            elseif access == "" then
                peasants = peasants + 1
            end

            total = total + 1
        end)

        local txt = ""
        if irccops    > 0 then txt = format("%s%s irccops, ",    txt, irccops)    end
        if founders   > 0 then txt = format("%s%s founders, ",   txt, founders)   end
        if operators  > 0 then txt = format("%s%s operators, ",  txt, operators)  end
        if halfwits   > 0 then txt = format("%s%s halfwits, ",   txt, halfwits)   end
        if loudmouths > 0 then txt = format("%s%s loudmouths, ", txt, loudmouths) end
        if peasants   > 0 then txt = format("%s%s peasants, ",   txt, peasants)   end
        txt = txt:sub(1, #txt - 2) -- trim comma
        txt = format("%s denizens of %s (%s)", total, hcol(dest), txt)

        prin_irc(0, dest, L_NAME(e), "%s", txt)
    end,

    -- WHOWAS: RPL_ENDOFWHOWAS
    -- <nick> :End of WHOWAS
    ["369"] = function(e)
        prin_irc(0, buf_cur(), "WHOWAS", "[%s] End of WHO info.",
            hncol(e.fields[3]))
    end,

    -- MOTD message
    ["372"] = default,

    -- Beginning of MOTD
    ["375"] = default,

    -- End of MOTD
    --
    -- Now that we know that the server has accepted our connection,
    -- and nothing has gone wrong in the registration process, we can
    -- connect to the default channels and set the default mode.
    ["376"] = function(_, _, _, _)
        if SRVCONF.mode and SRVCONF.mode ~= "" then
            send(":%s MODE %s :%s", nick, nick, SRVCONF.mode)
        end

        for c = 1, #SRVCONF.join do
            send(":%s JOIN %s", nick, SRVCONF.join[c])
        end
    end,

    -- WHOIS: <nick> is connecting from <host>
    ["378"] = function(e)
        prin_irc(0, buf_cur(), "WHOIS", "[%s] %s", hncol(e.fields[3]), e.msg)
    end,

    -- WHOIS: <nick> is using modes +abcd
    ["379"] = function(e)
        prin_irc(0, buf_cur(), "WHOIS", "[%s] %s", hncol(e.fields[3]), e.msg)
    end,

    -- "xyz" is now your hidden host (set by foo)
    ["396"] = function(e) prin_irc(0, MAINBUF, L_NORM(e), "%s %s", e.fields[3], e.msg) end,

    -- No such nick/channel
    ["401"] = function(e)
        prin_irc(1, buf_cur(), L_ERR(e), "No such nick/channel %s", e.fields[3])
    end,

    -- Nickname is reserved (being held for registered user)
    ["432"] = function(e)
        prin_irc(1, buf_cur(), L_ERR(e), "Nickname %s is reserved: %s",
            hncol(e.fields[3]), e.msg)
    end,

    -- Nickname is already in use
    ["433"] = function(e)
        assert(e.fields[3] == nick)
        local newnick = e.fields[3] .. "_" -- sprout a tail
        prin_irc(2, MAINBUF, L_NICK(e), "Nickname %s already in use; using %s",
            hncol(e.fields[3]), hncol(newnick))
        send("NICK %s", newnick)
        nick = newnick
    end,

    -- 441: <User> is not on that channel
    ["441"] = function(e)
        prin_irc(0, e.fields[4], L_ERR(e), "%s is not in %s", hncol(e.fields[3]),
            hcol(e.fields[4]))
    end,

    -- 442: You're not on that channel
    ["442"] = hndfact_err(),

    -- <nick> is already in channel (response to /invite)
    ["443"] = function(e)
        prin_irc(0, e.fields[4], L_ERR(e), "%s is already in %s", hncol(e.fields[3]),
            hcol(e.fields[4]))
    end,

    -- 464: Incorrect server password
    -- 465: You have been banned from the server
    -- 472: Unknown MODE character
    -- 473: Cannot join channel (invite-only)
    -- 474: Cannot join channel (you are banned)
    -- 475: Cannot join channel (bad channel key)
    -- 482: Permission denied (you're not a channel operator)
    -- 502: Cannot change mode for other users
    ["464"] = hndfact_err(), ["465"] = hndfact_err("You're banned creep"),
    ["472"] = hndfact_err(), ["473"] = hndfact_err(), ["474"] = hndfact_err(),
    ["475"] = hndfact_err(), ["482"] = hndfact_err(), ["502"] = hndfact_err(),

    -- WHOIS: <nick> is using a secure connection (response to /whois)
    ["671"] = function(e)
        prin_irc(0, buf_cur(), "WHOIS", "[%s] uses a secure connection",
            hncol(e.fields[3]))
    end,

    -- 716: <nick> has mode +g (server-side ignore)
    -- 717: <nick> has been informed that you messaged them.
    -- 718: joaquinito01 is messaging you, please run /ACCEPT +joaquinito01
    --      to begin the process of clogging your IRC logs.
    ["716"] = function(e)
        prin_irc(1, e.fields[3], L_ERR(e), "%s has mode +g (server-side ignore).",
            hncol(e.fields[3]))
    end,
    ["717"] = function(e)
        prin_irc(1, e.fields[3], L_ERR(e),
            "%s has been informed that you messaged them.", hncol(e.fields[3]))
    end,
    ["718"] = function(e)
        prin_irc(1, e.fields[3], L_ERR(e),
            "%s (%s) has messaged you, but you have mode +g set. Run /accept +%s to add them to your allow list.",
            hcol(e.fields[3]), mirc.grey(e.fields[4]), e.fields[3])
    end,

    -- 900: You are now logged in as xyz
    -- 901: You are now logged out
    ["900"] = function(e) prin_irc(0, MAINBUF, L_NORM(e), "%s", e.msg) end,
    ["901"] = function(e) prin_irc(0, MAINBUF, L_NORM(e), "%s", e.msg) end,

    -- CTCP stuff.
    ["CTCPQ_ACTION"] = function(e)
        local sender_fmt = hncol(e.nick or nick)
        local prio = 1

        if msg_pings(e.nick or nick, e.msg) then
            prio = 2
            sender_fmt = format("\x16%s\x0f", sender_fmt)
        end

        if not config.mirc then
            e.msg = mirc.remove(e.msg)
        end

        prin_irc(prio, e.dest, config.leftfmt.action(e), "%s %s",
            sender_fmt, e.msg)
    end,

    ["CTCPQ_VERSION"] = function(e)
        local vers = config.ctcp_version(e)
        if vers then
            prin_irc(1, MAINBUF, "CTCP", "%s requested VERSION (reply: %s)",
                e.nick, vers)
            send("NOTICE %s :\1VERSION %s\1", e.nick, vers)
        end
    end,
    ["CTCPQ_SOURCE"] = function(e)
        local src = config.ctcp_source(e)
        if src then
            prin_irc(1, MAINBUF, "CTCP", "%s requested SOURCE (reply: %s)",
                e.nick, src)
            send("NOTICE %s :\1SOURCE %s\1", e.nick, src)
        end
    end,
    ["CTCPQ_PING"] = function(e)
        if config.ctcp_ping(e) then
            prin_irc(1, MAINBUF, "CTCP", "PING from %s", e.nick)
            send("NOTICE %s :\1PING %s\1", e.nick, e.msg)
        end
    end,

    ["CTCPR_VERSION"] = none, ["CTCPR_PING"] = none, ["CTCPR_SOURCE"] = none,

    -- IRCv3 capability negotiation
    ["CAP"] = function(e)
        local subcmd = (e.fields[3]):lower()
        e.msg = (e.msg):match("(.-)%s*$") -- remove trailing whitespace

        if subcmd == "ls" then
            prin_irc(0, MAINBUF, L_NORM(e), "Supported IRCv3 capabilities: %s", e.msg)
        elseif subcmd == "ack" then
            prin_irc(0, MAINBUF, L_NORM(e), "Enabling IRCv3 capability: %s", e.msg)
        elseif subcmd == "nak" then
            prin_irc(0, MAINBUF, L_NORM(e), "Disabling IRCv3 capability: %s", e.msg)
        end
    end,
}

CFGHND_ALL      = -1
CFGHND_CONTINUE = 0
CFGHND_RETURN   = 1

function parseirc(reply)
    local event = irc.parse(reply)
    if not event then return end

    last_ircevent = event

    -- The first element in the fields array points to
    -- the type of message we're dealing with.
    local cmd = event.fields[1]

    -- When recieving MOTD messages and similar stuff from
    -- the IRCd, send it to the main tab
    if cmd:find("00.") or cmd:find("2[56].") or cmd:find("37.") then
        event.dest = MAINBUF
    end

    -- When recieving PMs, send it to the buffer named after
    -- the sender
    if event.dest == nick then event.dest = event.nick end

    -- if the user sends themself stuff, forward it to the main
    -- buffer. It doesn't always come from the user, the server may
    -- be sending messages that way for some reason.
    if event.dest == nick and event.nick == nick then
        event.dest = MAINBUF
    end

    -- Allow the IRC module to do its bookkeeping stuff.
    --
    -- We use has_handler to keep track of whether the command
    -- was handled or not.
    local has_handler = irc.handle(event)

    -- run each user handler, if it's not disabled.
    if config.handlers[CFGHND_ALL] then
        if (config.handlers[CFGHND_ALL]) == CFGHND_RETURN then
            return
        end
    end

    local _return = false
    if config.handlers[cmd] then
        util.kvmap(config.handlers[cmd], function(_, v)
            if v.disabled then return util.MAP_CONT end

            local ret = (v.fn)(event)
            if ret == CFGHND_RETURN then _return = true end
        end)
        has_handler = true
    end
    if _return then return end

    if irchand[cmd] then
        (irchand[cmd])(event)
        has_handler = true
    end

    if not has_handler then
        local text = "(" .. event.fields[1] .. ")"
        for i = 2, #event.fields do
            text = text .. " " .. event.fields[i]
        end
        if event.msg and event.msg ~= "" then
            text = text .. " :" .. event.msg
        end

        prin_irc(1, MAINBUF, "-?-", "%s", text)
    end
end

function send_both(fmt, ...)
    -- this is a simple function to send the input to the
    -- terminal and to the server at the same time.
    send(fmt, ...)

    -- don't send to the terminal if echo-message is enabled.
    if not irc.server.caps["echo-message"] then
        parseirc(format(fmt, ...))
    end
end

local cmdhand = {
    ["/close"] = {
        help = { "Close a buffer. The buffers after the one being closed are shifted left." },
        usage = "[buffer]",
        fn = function(a, _, _)
            local buf = a or cbuf

            if not tonumber(buf) then
                if not buf_idx(buf) then
                    prin_cmd(buf_cur(), L_ERR(), "%s is not an open buffer.", a)
                    return
                end

                buf = buf_idx(buf)
            else
                buf = tonumber(buf)
            end

            if buf == 1 then
                prin_cmd(buf_cur(), L_ERR(), "Cannot close main buffer.")
                return
            end

            bufs = util.remove(bufs, buf)
            local newcbuf = cbuf
            while not bufs[newcbuf] do
                newcbuf = newcbuf - 1
            end
            buf_switch(newcbuf)

            -- redraw, as the current buffer may have changed,
            -- and the statusline needs to be redrawn anyway.
            redraw()
        end,
    },
    ["/scroll"] = {
        REQUIRE_ARG = true,
        help = {
            "Scroll the current buffer.",
            "Examples:\n" ..
                "/scroll 0      Scroll to the bottom of the buffer.\n" ..
                "/scroll +12    Scroll up by 12 lines.\n" ..
                "/scroll -23    Scroll down by 23 lines.\n"
        },
        fn = function(a, _, _)
            if a:match("^%-") and tonumber(a) then
                buf_scroll(cbuf, -(tonumber(a:sub(2, #a))), nil)
            elseif a:match("^%+") and tonumber(a) then
                buf_scroll(cbuf, tonumber(a:sub(2, #a)), nil)
            elseif tonumber(a) then
                buf_scroll(cbuf, nil, tonumber(a))
            end
            redraw()
        end
    },
    ["/clear"] = {
        help = { "Clear the current buffer." },
        fn = function(_, _, _)
            bufs[cbuf].history = {}
            bufs[cbuf].scroll = 0
            redraw()
        end
    },
    ["/unread"] = {
        help = { "Switch to the first buffer with an unread message." },
        fn = function(_, _, _)
            for _, unread_type in ipairs({ "pings", "unreadh", "unreadl" }) do
                for i = 1, #bufs do
                    if bufs[i][unread_type] > 0 then
                        buf_switch(i)
                        return
                    end
                end
            end

            prin_cmd(buf_cur(), L_ERR(), "Nothing to see here... Press Alt+Tab and move along")
        end,
    },
    ["/read"] = {
        REQUIRE_ARG = true,
        help = {
            "Clear unread message notifications for a buffer.",
            "Examples:\n" ..
                "/read all      Clear notifications for all buffers.\n" ..
                "/read 1        Clear notifications for the main buffer.\n" ..
                "/read 34       Clear notifications for buffer 34."
        },
        usage = "<buffer>",
        fn = function(a, _, _)
            if a == "all" then
                for i = 1, #bufs do
                    buf_read(i)
                end
            elseif tonumber(a) then
                buf_read(tonumber(a))
            else
                prin_cmd(buf_cur(), L_ERR(), "Unknown buffer '%s'. Buffer should be either 'all' or '[0-9]+'.")
            end

            tui.statusline()
        end,
    },
    ["/redraw"] = {
        help = { "Redraw the screen. Ctrl+L may also be used." },
        fn = function(_, _, _) redraw() end,
    },
    ["/next"] = {
        help = { "Switch to the next buffer. Ctrl+N may also be used." },
        fn = function(_, _, _) buf_switch(cbuf + 1) end
    },
    ["/prev"] = {
        help = { "Switch to the previous buffer. Ctrl+P may also be used." },
        fn = function(_, _, _) buf_switch(cbuf - 1) end
    },
    ["/cmd"] = {
        REQUIRE_ARG = true,
        help = { "Execute a command, and use its output as input for the current buffer." },
        usage = "<command> [args...]",
        fn = function(a, args, _)
            -- FIXME: ensure this doesn't block on long-running commands
            local command = format("%s -c '%s %s'",
                os.getenv("SHELL") or "/bin/sh", a, args)
            local output = util.capture(command)
            for line in output:gmatch("([^\n]+)\n?") do
                parsecmd(line)
            end
        end,
    },
    ["/away"] = {
        help = {
            "Set away status. An empty status indicates that you're back.",
            "Examples:\n" ..
                "/away Ill be bacck     Sets away message to 'Ill be bacck'\n" ..
                "/away                  Clears away status."
        },
        usage = "[message]",
        fn = function(a, args, _)
            if a then
                send("AWAY :%s %s", nick, a, args)
            else
                send("AWAY")
            end
        end,
    },
    ["/invite"] = {
        REQUIRE_CHANBUF = true,
        REQUIRE_ARG = true,
        help = { "Invite a user to the current channel." },
        usage = "<user>",
        fn = function(a, _, _) send(":%s INVITE %s :%s", nick, a, buf_cur()) end
    },
    ["/names"] = {
        REQUIRE_CHANBUF_OR_ARG = true,
        help = { "See the users for a channel (the current one by default)." },
        usage = "[channel]",
        fn = function(a, _, _) send("NAMES %s", a or buf_cur()) end
    },
    ["/topic"] = {
        -- TODO: separate settopic command
        REQUIRE_CHANBUF_OR_ARG = true,
        help = { "See the current topic for a channel (the current one by default)." },
        usage = "[channel]",
        fn = function(a, _, _) send("TOPIC %s", a or buf_cur()) end
    },
    ["/whois"] = {
        REQUIRE_ARG = true,
        help = { "See WHOIS information for a user." },
        usage = "<user>",
        fn = function(a, _, _) send("WHOIS %s", a) end
    },
    ["/who"] = {
        REQUIRE_ARG = true,
        help = { "See WHO information for a user." },
        usage = "<user>",
        fn = function(a, _, _) send("WHO %s", a) end
    },
    ["/whowas"] = {
        REQUIRE_ARG = true,
        help = { "See WHOWAS information for a user." },
        usage = "<user>",
        fn = function(a, _, _) send("WHOWAS %s", a) end
    },
    ["/ctcp"] = {
        REQUIRE_ARG = true,
        help = { "Send a CTCP query to a user." },
        usage = "<user> <query>",
        fn = function(a, args, _)
            send("PRIVMSG %s :\1%s\1", a, args)
        end
    },
    ["/accept"] = {
        REQUIRE_ARG = true,
        help = { "If you have mode +g (server ignore) set, this command will put a nickname on your ACCEPT list, allowing them to message you." },
        usage = "<user>",
        fn = function(a, _, _) send("ACCEPT :%s", a) end,
    },
    ["/mode"] = {
        REQUIRE_ARG = true,
        help = {
            "Set a user/channel mode.",
            "If run in the main buffer, sets the user mode; otherwise, sets a channel mode."
        },
        usage = "<mode...>",
        fn = function(a, args, _)
            local recipient = bufs[cbuf].name
            if cbuf == 1 then recipient = nick end

            local mode = a
            if args and args ~= "" then mode = mode .. " " .. args end
            send("MODE %s %s", recipient, mode)
        end,
    },
    ["/kick"] = {
        REQUIRE_CHANBUF = true,
        REQUIRE_ARG = true,
        help = { "Kick a user from the current channel." },
        usage = "<user> [reason...]",
        fn = function(a, args, _)
            if args == "" then args = nil end
            local buf = bufs[cbuf].name
            local reason = args or config.kick_msg(buf_cur()) or ""
            send("KICK %s %s :%s", buf_cur(), a, reason)
        end,
    },
    ["/ignore"] = {
        help = {
            "Temporarily change the ignore status for a user, or list ignore users.",
            "Ignore status can be one of 'B' (Block), 'F' (Filter), 'D' (Dim), or ''"
        },
        usage = "[<pattern> [ignore_type]]",
        fn = function(a, args, _)
            if not a then
                local lvlstrs = { B = "Block", F = "Filter", D = "Dim" }
                prin_cmd(buf_cur(), L_NORM(), "Ignored users:")
                for pat, lvl in pairs(config.ignores) do
                    prin_cmd(buf_cur(), L_NORM(), "  - %-24s %s (%s)", pat, lvl, lvlstrs[lvl] or "None")
                end
            else
                if args == "" then args = nil end
                local oldign = config.ignores[a]; config.ignores[a] = args
                prin_cmd(buf_cur(), L_NORM(), "Ignore status for '%s' is now '%s' (was '%s')", a, args, oldign)
            end
        end,
    },
    ["/join"] = {
        REQUIRE_ARG = true,
        help = { "Join channels; if already joined, focus that buffer." },
        usage = "<channel>[,channel...]",
        fn = function(a, _, _)
            for channel in a:gmatch("([^,]+),?") do
                send(":%s JOIN %s", nick, channel)
                local bufidx = buf_idx_or_add(channel)

                -- draw the new buffer
                buf_switch(bufidx); tui.statusline()
            end
        end
    },
    ["/part"] = {
        REQUIRE_CHANBUF_OR_ARG = true,
        help = { "Part the current channel." },
        usage = "[part_message]",
        fn = function(a, args, _)
            local msg = config.part_msg(buf_cur()) or ""
            if a and a ~= "" then msg = format("%s %s", a, args) end
            send(":%s PART %s :%s", nick, buf_cur(), msg)
        end
    },
    ["/disable"] = {
        REQUIRE_ARG = true,
        help = {
            "Disable an active handler defined in config.lua.",
            "Example: /disable PRIVMSG quotes",
        },
        usage = "<cmd> <name>",
        fn = function(a, args, _)
            if not args then
                prin_cmd(buf_cur(), L_ERR(), "Need handler name (see /help disable).")
                return
            end

            local name = format("'%s::%s'", a, args)
            if not config.handlers[a] or not config.handlers[a][args] then
                prin_cmd(buf_cur(), L_ERR(), "No such handler %s", name)
                return
            end

            local hnd = config.handlers[a][args]
            if hnd.disabled then
                prin_cmd(buf_cur(), L_ERR(), "Handler %s is already disabled.", name)
                return
            end

            config.handlers[a][args].disabled = true
            prin_cmd(buf_cur(), L_NORM(), "Handler %s disabled.", name)
        end
    },
    ["/quit"] = {
        help = { "Exit lurch." },
        usage = "[quit_message]",
        fn = function(a, args, _)
            local msg
            if not a or a == "" then
                msg = config.quit_msg() or ""
            else
                msg = format("%s %s", a, args)
            end

            send("QUIT :%s", msg)
            lurchconn.close()
            termbox.shutdown()
            eprintf("[lurch exited]\n")
            os.exit(0)
        end
    },
    ["/nick"] = {
        REQUIRE_ARG = true,
        help = { "Change nickname." },
        usage = "<nickname>",
        fn = function(a, _, _) send("NICK %s", a); nick = a; end
    },
    ["/msg"] = {
        REQUIRE_ARG = true,
        help = { "Privately message a user. Opens a new buffer." },
        usage = "<user> <message...>",
        fn = function(a, args, _)
            local bufidx = buf_idx_or_add(a)
            buf_switch(bufidx); tui.statusline()

            if args and args ~= "" then
                send_both(":%s PRIVMSG %s :%s", nick, a, args)
            end
        end
    },
    ["/note"] = {
        REQUIRE_ARG = true,
        help = { "Send a NOTICE to a channel." },
        usage = "<user> <message...>",
        fn = function(a, args, _)
            send_both(":%s NOTICE %s :%s", nick, a, args or "")
        end,
    },
    ["/raw"] = {
        REQUIRE_ARG = true,
        help = { "Send a raw IRC command to the server." },
        usage = "<command> <args>",
        fn = function(a, args, _) send("%s %s", a, args) end
    },
    ["/me"] = {
        REQUIRE_ARG = true,
        REQUIRE_CHAN_OR_USERBUF = true,
        help = { "Send a CTCP action to the current channel." },
        usage = "<text>",
        fn = function(a, args, _)
            send_both(":%s PRIVMSG %s :\1ACTION %s %s\1", nick,
                buf_cur(), a, args)
        end,
    },
    ["/shrug"] = {
        REQUIRE_CHAN_OR_USERBUF = true,
        help = { "Send a shrug to the current channel." },
        fn = function(_, _, _)
            send_both(":%s PRIVMSG %s :¯\\_(ツ)_/¯", nick, buf_cur())
        end,
    },
    ["/help"] = {
        help = { "You know what this command is for." },
        usage = "[command]",
        fn = function(a, _, _)
            if not a or a == "" then
                -- all set up and ready to go !!!
                prin_cmd(buf_cur(), L_NORM(), "hello bastard !!!")
                return
            end

            local cmd = a
            if not (cmd:find("/") == 1) then cmd = "/" .. cmd end

            if not cmdhand[cmd] and not config.commands[cmd] then
                prin_cmd(buf_cur(), L_ERR(), "No such command '%s'", a)
                return
            end

            local cmdinfo = cmdhand[cmd] or config.commands[cmd]

            prin_cmd(buf_cur(), L_NORM(), "")
            prin_cmd(buf_cur(), L_NORM(), "Help for %s", cmd)

            if cmdinfo.usage then
                prin_cmd(buf_cur(), L_NORM(), "usage: %s %s", cmd, cmdinfo.usage)
            end

            prin_cmd(buf_cur(), L_NORM(), "")

            for i = 1, #cmdinfo.help do
                prin_cmd(buf_cur(), L_NORM(), "%s", cmdinfo.help[i])
                prin_cmd(buf_cur(), L_NORM(), "")
            end

            if cmdinfo.REQUIRE_CHANBUF then
                prin_cmd(buf_cur(), L_NORM(), "This command must be run in a channel buffer.")
                prin_cmd(buf_cur(), L_NORM(), "")
            elseif cmdinfo.REQUIRE_CHAN_OR_USERBUF then
                prin_cmd(buf_cur(), L_NORM(), "This command must be run in a channel or a user buffer.")
                prin_cmd(buf_cur(), L_NORM(), "")
            end
        end,
    },
    ["/list"] = {
        -- TODO: list user-defined commands.
        help = { "List builtin and user-defined lurch commands." },
        fn = function(_, _, _)
            prin_cmd(buf_cur(), L_NORM(), "")
            prin_cmd(buf_cur(), L_NORM(), "[builtin]")
            local cmdlist = ""
            for k, _ in pairs(cmdhand) do
                cmdlist = cmdlist .. k .. " "
            end
            prin_cmd(buf_cur(), L_NORM(), "%s", cmdlist)

            prin_cmd(buf_cur(), L_NORM(), "")
            prin_cmd(buf_cur(), L_NORM(), "[user]")
            cmdlist = ""
            for k, _ in pairs(config.commands) do
                cmdlist = cmdlist .. k .. " "
            end
            prin_cmd(buf_cur(), L_NORM(), "%s", cmdlist)

        end,
    },
    ["/dump"] = {
        help = { "Dump lurch's state and internal variables into a temporary file to aid with debugging." },
        usage = "[file]",
        fn = function(a, _, _)
            local file = a
            if not file then file = os.tmpname() end

            local fp, err = io.open(file, "w")
            if not fp then
                prin_cmd(buf_cur(), L_ERR(), "Couldn't open tmpfile %s", err)
                return
            end

            local state = {
                server = irc.server,
                nick = nick, cbuf = cbuf,
                bufs = bufs,

                input_buf = tbrl.bufin,
                input_cursor = tbrl.cursor,
                input_hist = tbrl.hist,

                set_colors = tui.set_colors,
                colors = tui.colors,
            }

            local ret, err = fp:write(inspect(state))
            if not ret then
                prin_cmd(buf_cur(), L_ERR(), "Could not open tmpfile: %s", err)
                return
            end

            prin_cmd(buf_cur(), L_ERR(), "Wrote information to %s", file)
            fp:close()
        end,
    },
    ["/panic"] = {
        help = { "Summon a Lua panic to aid with debugging." },
        usage = "[errmsg]",
        fn = function(a, args, _)
            local msg = "/panic was run"
            if a then msg = format("%s %s", a, args or "") end
            error(msg)
        end,
    },
}

function parsecmd(inp)
    -- Run user hooks
    inp = callbacks.on_input(inp)

    -- the input line clears itself, there's no need to clear it...

    -- split the input line into the command (first word), a (second
    -- word), and args (the rest of the input)
    local pw, _cmd, a, args = inp:gmatch("(%s*)([^%s]+)%s?([^%s]*)%s?(.*)")()
    if not _cmd then return end

    _cmd = pw .. _cmd
    if a == "" then a = nil; args = nil end

    -- if the command matches "/<number>", switch to that buffer.
    if _cmd:match("/%d+$") then
        buf_switch(tonumber(_cmd:sub(2, #_cmd)))
        return
    end

    -- if the command matches "/#<channel>", switch to that buffer.
    if _cmd:match("/#[^%s]+$") then
        local bufidx = buf_idx(_cmd:sub(2, #_cmd))
        if bufidx then buf_switch(bufidx) end
        return
    end

    -- if the command exists, then run it
    if _cmd:sub(1, 1) == "/" and _cmd:sub(2, 2) ~= "/" then
        if not cmdhand[_cmd] and not config.commands[_cmd] then
            prin_cmd(buf_cur(), "NOTE", "%s not implemented yet", _cmd)
            return
        end

        local hand = cmdhand[_cmd] or config.commands[_cmd]

        if hand.REQUIRE_CHANBUF and not (buf_cur()):find("#") then
            prin_cmd(buf_cur(), L_ERR(),
                "%s must be executed in a channel buffer.", _cmd)
            return
        end

        if hand.REQUIRE_ARG and (not a or a == "") then
            prin_cmd(buf_cur(), L_ERR(), "%s requires an argument.", _cmd)
            return
        end

        if hand.REQUIRE_CHANBUF_OR_ARG and (not a or a == "") and not (buf_cur()):find("#") then
            prin_cmd(buf_cur(), L_ERR(),
                "%s must be executed in a channel buffer or must be run with an argument.", _cmd)
            return
        end

        if hand.REQUIRE_CHAN_OR_USERBUF and cbuf == 1 then
            prin_cmd(buf_cur(), L_ERR(),
                "%s must be executed in a channel or user buffer.", _cmd)
        end

        (hand.fn)(a, args, inp)
    else
        -- make "//test" translate to "/test"
        if inp:sub(1, 2) == "//" then inp = inp:sub(2, #inp) end

        -- since the command doesn't exist, just send it as a message
        if buf_cur() == MAINBUF then
            prin_cmd(buf_cur(), L_ERR(), "Stop trying to talk to lurch.")
        else
            -- split long messages, as servers don't like IRC messages
            -- that are longer than about 512 characters (but that limit
            -- includes the trailing \r\n, the "PRIVMSG <channel>" bit,
            -- and the sender, so split by 256 chars just to stay safe).
            for line in (util.fold(inp, 256)):gmatch("([^\n]+)\n?") do
                send_both(":%s PRIVMSG %s :%s", nick, buf_cur(), line)
            end
        end
    end
end

local keyseq_handler = {
    keys = {
        [tb.TB_KEY_CTRL_N] = function(_) parsecmd("/next") end,
        [tb.TB_KEY_CTRL_P] = function(_) parsecmd("/prev") end,
        [tb.TB_KEY_PGUP]   = function(_) parsecmd("/scroll +3") end,
        [tb.TB_KEY_PGDN]   = function(_) parsecmd("/scroll -3") end,
        [tb.TB_KEY_CTRL_L] = function(_) parsecmd("/redraw") end,
        [tb.TB_KEY_CTRL_C] = function(_) parsecmd("/quit") end,
        [tb.TB_KEY_CTRL_B] = function(_) tbrl.insert_at_curs(mirc.BOLD) end,
        [tb.TB_KEY_CTRL_U] = function(_) tbrl.insert_at_curs(mirc.UNDERLINE) end,
        [tb.TB_KEY_CTRL_T] = function(_) tbrl.insert_at_curs(mirc.ITALIC) end,
        [tb.TB_KEY_CTRL_R] = function(_) tbrl.insert_at_curs(mirc.INVERT) end,
        [tb.TB_KEY_CTRL_O] = function(_) tbrl.insert_at_curs(mirc.RESET) end,
    },

    mods = {
        [tb.TB_MOD_ALT] = {
            -- Alt+a
            [97] = function() parsecmd("/unread") end,
        }
    }
}

function rt.on_keyseq(event)
    if event.mod ~= 0 then
        local ev_key = event.ch
        if ev_key == 0 then ev_key = event.key end

        if config.keyseqs.mods[event.mod]
        and config.keyseqs.mods[event.mod][ev_key] then
            (config.keyseqs.mods[event.mod][ev_key])(event)
        elseif keyseq_handler.mods[event.mod]
        and keyseq_handler.mods[event.mod][ev_key] then
            (keyseq_handler.mods[event.mod][ev_key])(event)
        end
    elseif event.key ~= 0 then
        if config.keyseqs.keys[event.key] then
            (config.keyseqs.keys[event.key])(event)
        elseif keyseq_handler.keys[event.key] then
            (keyseq_handler.keys[event.key])(event)
        end
    end
end

function rt.init(args)
    --
    -- for each option, if it begins with a "-", toggle
    -- the corresponding configuration value if it has no
    -- argument. If it does have an argument, set the
    -- configuration value to the argument.
    --
    -- For example: the following argument string:
    --    ./lurch -host irc.snoonet.org -port 6666 -mirc
    -- Will set the IRC host to irc.snoonet.org, the IRC port
    -- to 6666, and will toggle config.mirc.
    --
    local lastarg
    for _, arg in ipairs(args) do
        if arg:sub(1, 1) == "-" then
            arg = arg:sub(2, #arg)
            if SRVCONF[arg] ~= nil then
                SRVCONF[arg] = not SRVCONF[arg]
            else
                config[arg] = not config[arg]
            end
            lastarg = arg
        elseif lastarg then
            if SRVCONF[lastarg] ~= nil then
                SRVCONF[lastarg] = arg
            else
                config[lastarg] = arg
            end
            lastarg = nil
        end
    end

    -- HACK: re-set these vars, just in case they were changed
    -- while parsing arguments
    --
    -- FIXME: remove this
    SRVCONF = config.servers[config.server]
    nick = SRVCONF.nick
    MAINBUF = SRVCONF.host

    -- Get the IRC log directory and create it if necessary.
    logs.setup(SRVCONF.host)

    -- Set up the TUI. Retrieve the column width, set the prompt,
    -- line format, and statusline functions, and load the highlight
    -- colors.
    tui.linefmt_func           = config.linefmt
    tui.prompt_func            = callbacks.prompt
    tui.statusline_func        = callbacks.statusline
    tui.bottom_statusline_func = callbacks.bottom_statusline

    tui.refresh()
    tui.colors = config.colors()

    if tui.tty_width < 40 or tui.tty_height < 8 then
        panic("screen width too small (min 40x8)\n")
    end

    -- create the main buffer, switch to it, and set its color to plain
    -- white. Print the lurch logo.
    tui.set_colors[MAINBUF] = 14
    buf_add(MAINBUF)
    buf_switch(1)

    prin_cmd(buf_cur(), "--", "|     ._ _ |_    o ._  _    _ | o  _  ._ _|_")
    prin_cmd(buf_cur(), "--", "| |_| | (_ | |   | |  (_   (_ | | (/_ | | |_")
    prin_cmd(buf_cur(), "--", "")
    prin_cmd(buf_cur(), "--", "lurch beta (https://github.com/lptstr/lurch)")
    prin_cmd(buf_cur(), "--", "(c) Kiëd Llaentenn. Lurch is GPLv3 software.")
    prin_cmd(buf_cur(), "--", "")
    prin_cmd(buf_cur(), "--", "-- -- -- -- -- -- -- -- -- -- -- -- -- -- --")
    prin_cmd(buf_cur(), "--", "")

    -- Setup the termbox readline. Before termbox was used, lurch just
    -- used the normal GNU readline, but we now have to implement our
    -- own readline since GNU readline doesn't work in termbox/ncurses.
    -- This means we'll have to implement common features such as
    -- input history (DONE), completion (TODO), and undo/redo (TODO).
    --
    tbrl.bind_keys(config.keyseqs)
    tbrl.bind_keys(keyseq_handler)

    -- Set the functions to be called when <enter> is pressed, or when
    -- the screen is resized.
    tbrl.enter_callback = parsecmd
    tbrl.resize_callback = function() redraw() end

    -- Misc stuff
    callbacks.on_startup()

    -- Finally, we can connect to the server.
    prin_cmd(MAINBUF, L_ERR(), "Connecting to %s:%s (TLS: %s)",
        SRVCONF.host, SRVCONF.port, SRVCONF.tls)
    return connect()
end

function rt.on_disconnect(_err)
    if reconn == 0 then
        panic("lurch: link lost: %s\n", _err or "unknown error")
    end

    -- Wait for an increasing amount of time before reconnecting.
    if (os.time() - reconn_wait) < irc.server.connected then
        return false
    end

    reconn = reconn - 1
    prin_cmd(MAINBUF, L_ERR(),
        "Link lost, attempting reconnection... (%s tries left)", reconn)

    local ret, err = connect()
    if not ret then
        reconn_wait = math.floor(reconn_wait * 1.6)
        prin_cmd(MAINBUF, L_ERR(), "Unable to connect (%s), waiting %s seconds",
            err, reconn_wait)
    else
        -- rejoin channels.
        -- FIXME: this will join channels that have been left, too
        for i = 2, #bufs do
            -- clear the names list of the channels. it will
            -- be refreshed when the server sends 353.
            bufs[i].names = {}
            bufs[i].access = {}

            send(":%s JOIN :%s", nick, bufs[i].name)
        end
    end

    return ret, err
end

local sighand = {
    -- SIGHUP
    [1] = function() return true end,
    -- SIGINT
    [2] = function() return true end,
    -- SIGPIPE
    [13] = function() end,
    -- SIGUSR1
    [10] = function() end,
    -- SIGUSR2
    [12] = function() end,
    -- SIGWINCH
    [28] = function() redraw() end,
    -- catch-all
    [0] = function() return true end,
}

function rt.on_signal(sig)
    local quitmsg = config.quit_msg() or "*poof*"
    local handler = sighand[sig] or sighand[0]
    if (handler)() then
        send("QUIT :%s", quitmsg)
        lurchconn.close()
        termbox.shutdown()
        eprintf("[lurch exited]\n")
        os.exit(0)
    end
end

function rt.on_lerror(err)
    local bt = debug.traceback(err, 2)
    xpcall(function()
        bt = bt:gsub("\t", "    ")
        prin_cmd(MAINBUF, L_ERR(), "Lua error!: %s", bt)
    end, function(ohno)
        panic("While trying to handle error: %s\nAnother error occurred: %s\n",
            bt, ohno)
    end)
end

function rt.on_reply(reply)
    if os.getenv("LURCH_DEBUG") then
        util.append(DBGFILE, format("%s >r> %s\n", os.time(), reply))
    end

    parseirc(reply)
end

-- every time a key is pressed, redraw the prompt, and
-- write the input buffer.
function rt.on_input(event)
    tbrl.on_event(event)
    tui.prompt(tbrl.bufin[tbrl.hist], tbrl.cursor)
end

function rt.on_complete(text, from, to)
    local incomplete = text:sub(from, to)
    local matches = {}

    -- Possible matches:
    --     for start of line: "/<command>", "/#<channel>", "nick: "
    --     for middle of line: "nick "
    local possible = { nick }
    if from == 1 then
        for k, _ in pairs(cmdhand) do possible[#possible + 1] = k end
        for _, v in ipairs(bufs) do
            if (v.name):find("#") == 1 then
                possible[#possible + 1] = format("/%s", v.name)
            end
        end

        for k, _ in pairs(bufs[cbuf].names) do
            possible[#possible + 1] = format("%s:", k)
        end
    else
        for k, _ in pairs(bufs[cbuf].names) do
            possible[#possible + 1] = format("%s", k)
        end
    end

    for _, v in ipairs(possible) do
        if incomplete == v:sub(1, #incomplete) then
            matches[#matches + 1] = v
        end
    end

    return matches
end

return rt
