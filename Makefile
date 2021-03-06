CMD      = @

VERSION  = 0.1.0
NAME     = lurch
SRC      = main.c luau.c luaa.c util.c tool/dwidth.c mirc.c
OBJ      = $(SRC:.c=.o)
FNLSRC   = rt/irc.fnl rt/mirc.fnl rt/tb.fnl rt/tui.fnl \
	   test/fun_test.fnl
LUASRC   = $(FNLSRC:.fnl=.lua)

TERMBOX  = tb/bin/termbox.a
LUA      = lua5.3
UTF8PROC = ~/local/lib/libutf8proc.a

WARNING  = -Wall -Wpedantic -Wextra -Wold-style-definition \
	   -Wmissing-prototypes -Winit-self -Wfloat-equal -Wstrict-prototypes \
	   -Wredundant-decls -Wendif-labels -Wstrict-aliasing=2 -Woverflow \
	   -Wformat=2 -Wmissing-include-dirs -Wtrigraphs -Wno-format-nonliteral \
	   -Wincompatible-pointer-types -Wunused-parameter \
	   -Werror=extern-initializer
DEF      = -D_DEFAULT_SOURCE -D_POSIX_C_SOURCE=200112L -D_XOPEN_SOURCE -D_GNU_SOURCE
INCL     = -Itb/src/ -I/usr/include/$(LUA) -I ~/local/include -Itool/
CC       = clang
CFLAGS   = -Og -ggdb $(DEF) $(INCL) $(WARNING) -funsigned-char
LD       = bfd
LDFLAGS  = -fuse-ld=$(LD) -L/usr/include -lm -ltls -l$(LUA)
FNLC     = fennel
FFLAGS   = --indent "    "

.PHONY: all
all: $(LUASRC) $(NAME)

.PHONY: test
test: $(LUASRC) $(NAME)
	$(CMD)./test/test.lua

.PHONY: run
run: $(LUASRC) $(NAME)
	$(CMD)./$(NAME)

%.lua: %.fnl
	@printf "    %-8s%s\n" "FNLC" $@
	$(CMD)$(FNLC) $(FFLAGS) --compile $< > $@

.c.o: $(HDR)
	@printf "    %-8s%s\n" "CC" $@
	$(CMD)$(CC) -c $< -o $(<:.c=.o) $(CFLAGS)

$(NAME): $(OBJ) $(UTF8PROC) $(TERMBOX)
	@printf "    %-8s%s\n" "CCLD" $@
	$(CMD)$(CC) -o $@ $^ $(CFLAGS) $(LDFLAGS)

$(TERMBOX):
	@printf "    %-8s%s\n" "MAKE" $@
	$(CMD)make -C tb CC=$(CC)

tool/dwidth.c: tool/gendwidth
	@printf "    %-8s%s\n" "GEN" $@
	$(CMD)$^ > $@

tool/gendwidth: $(UTF8PROC)
	@printf "    %-8s%s\n" "CCLD" $@
	$(CMD)$(CC) $@.c $(UTF8PROC) -o $@ $(INCL)

.PHONY: clean
clean:
	rm -f $(NAME) $(OBJ) $(LUASRC) tool/gendwidth tool/dwidth.c
