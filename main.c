/* See LICENSE file for license details. */

#include <assert.h>
#include <errno.h>
#include <execinfo.h>
#include <lauxlib.h>
#include <lua.h>
#include <lualib.h>
#include <netdb.h>
#include <signal.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

#include "termbox.h"

const size_t TIMEOUT = 4096;
const size_t BT_BUF_SIZE = 16;

lua_State *L = NULL;
int conn_fd = 0;
FILE *conn = NULL;
char bufsrv[4096];
struct tb_event ev;

void signal_lhand(int sig);
void signal_fatal(int sig);

void die(const char *fmt, ...);
char *format(const char *format, ...);

#if LUA_VERSION_NUM >= 502
#define llua_rawlen(ST, NM) lua_rawlen(ST, NM)
#else
#define llua_rawlen(ST, NM) lua_objlen(ST, NM)
#endif

#if LUA_VERSION_NUM >= 502
#define llua_setfuncs(ST, FN) luaL_setfuncs(ST,   FN,  0);
#else
#define llua_setfuncs(ST, FN) luaL_register(ST, NULL, FN);
#endif

#define SETTABLE_INT(NAME, VALUE, TABLE) \
	do { \
		lua_pushstring(L, NAME); \
		lua_pushinteger(L, (lua_Integer) VALUE); \
		lua_settable(L, TABLE); \
	} while (0);

int  llua_panic(lua_State *pL);
void llua_sdump(lua_State *pL);
void llua_call(lua_State *pL, const char *fnname, size_t nargs,
		size_t nret);

/* TODO: move to separate file */
int api_conn_init(lua_State *pL);
int api_conn_fd(lua_State *pL);
int api_conn_send(lua_State *pL);
int api_tb_init(lua_State *pL);
int api_tb_shutdown(lua_State *pL);
int api_tb_size(lua_State *pL);
int api_tb_clear(lua_State *pL);
int api_tb_present(lua_State *pL);
int api_tb_writeline(lua_State *pL);
int api_tb_clearline(lua_State *pL);
int api_tb_hidecursor(lua_State *pL);
int api_tb_showcursor(lua_State *pL);

int
main(int argc, char **argv)
{
	/* register signal handlers */
	/* signals to whine and die on */
	struct sigaction fatal;
	fatal.sa_handler = &signal_fatal;
	sigaction(SIGILL,   &fatal, NULL);
	sigaction(SIGSEGV,  &fatal, NULL);
	sigaction(SIGFPE,   &fatal, NULL);
	sigaction(SIGBUS,   &fatal, NULL);

	/* signals to catch and handle in lua code */
	/* TODO: is handling SIGTERM a good idea? */
	struct sigaction lhand;
	lhand.sa_handler = &signal_lhand;
	sigaction(SIGHUP,   &lhand, NULL);
	sigaction(SIGINT,   &lhand, NULL);
	sigaction(SIGPIPE,  &lhand, NULL);
	sigaction(SIGUSR1,  &lhand, NULL);
	sigaction(SIGUSR2,  &lhand, NULL);
	sigaction(SIGWINCH, &lhand, NULL);

	/* init lua */
	L = luaL_newstate();
	assert(L);

	luaL_openlibs(L);
	luaopen_table(L);
	luaopen_io(L);
	luaopen_string(L);
	luaopen_math(L);

	/* set panic function */
	lua_atpanic(L, llua_panic);

	/* get executable path */
	char buf[4096];
	char path[128];
	sprintf((char *) &path, "/proc/%d/exe", getpid());
	int len = readlink((char *) &path, (char *) &buf, sizeof(buf));
	buf[len] = '\0';

	/* trim off the filename */
	for (size_t i = strlen(buf) - 1; i > 0; --i) {
		if (buf[i] == '/' || buf [i] == '\\') {
			buf[i] = '\0';
			break;
		}
	}

	lua_pushstring(L, (char *) &buf);
	lua_setglobal(L, "__LURCH_EXEDIR");

	/* TODO: do this the non-lazy way */
	(void) luaL_dostring(L,
		"package.path = __LURCH_EXEDIR .. '/rt/?.lua;' .. package.path\n"
		"package.path = __LURCH_EXEDIR .. '/conf/?.lua;' .. package.path\n"
	);

	/* setup lurch api functions */
	static const struct luaL_Reg lurch_lib[] = {
		{ "conn_init",     api_conn_init      },
		{ "conn_fd",       api_conn_fd        },
		{ "conn_send",     api_conn_send      },
		{ "tb_init",       api_tb_init        },
		{ "tb_shutdown",   api_tb_shutdown    },
		{ "tb_size",       api_tb_size        },
		{ "tb_clear",      api_tb_clear       },
		{ "tb_present",    api_tb_present     },
		{ "tb_writeline",  api_tb_writeline   },
		{ "tb_clearline",  api_tb_clearline   },
		{ "tb_hidecursor", api_tb_hidecursor  },
		{ "tb_showcursor", api_tb_showcursor  },
		{ NULL, NULL },
	};

	lua_newtable(L);
	llua_setfuncs(L, (luaL_Reg *) &lurch_lib);
	lua_pushvalue(L, -1);
	lua_setglobal(L, "lurch");

	!luaL_dofile(L, "./rt/init.lua") || llua_panic(L);
	lua_setglobal(L, "rt");

	/* run init function */
	llua_call(L, "init", 0, 0);

	/*
	 * no buffering for server,stdin,stdout. buffering causes
	 * certain escape sequences to not be output until a newline
	 * is sent, which often will badly mess up the TUI.
	 *
	 * by now, the server connection should have been opened.
	 */
	setvbuf(stdin, NULL, _IONBF, 0);
	setvbuf(stdout, NULL, _IONBF, 0);
	setvbuf(conn, NULL, _IONBF, 0);

	time_t trespond;
	struct timeval tv;
	tv.tv_sec  = 120;
	tv.tv_usec =   0;

	int n;
	fd_set rd;

	while ("pigs fly") {
		/* TODO: use poll(2) */
		FD_ZERO(&rd);
		FD_SET(conn_fd, &rd);
		FD_SET(0, &rd);

		n = select(conn_fd + 1, &rd, 0, 0, &tv);

		if (n < 0) {
			if (errno == EINTR)
				continue;
			die("error on select():");
		} else if (n == 0) {
			if (time(NULL) - trespond >= TIMEOUT)
				llua_call(L, "on_timeout", 0, 0);

			continue;
		}

		if (FD_ISSET(conn_fd, &rd)) {
			if (fgets(bufsrv, sizeof(bufsrv), conn) == NULL) {
				llua_call(L, "on_disconnect", 1, 0);
			} else {
				lua_pushstring(L, (const char *) &bufsrv);
				llua_call(L, "on_reply", 1, 0);
				trespond = time(NULL);
			}
		}

		if (FD_ISSET(0, &rd)) {
			int ret = 0;
			while ((ret = tb_peek_event(&ev, 16)) != 0) {
				assert(ret != -1); /* termbox error */

				/* don't push event.w and event.y; the Lua
				 * code can easily get those values by running
				 * lurch.tb_size() */
				lua_settop(L, 0);
				lua_newtable(L);
				SETTABLE_INT("type",   ev.type, -3);
				SETTABLE_INT("mod",    ev.mod,  -3);
				SETTABLE_INT("ch",     ev.ch,   -3);
				SETTABLE_INT("key",    ev.key,  -3);
				SETTABLE_INT("mousex", ev.x,    -3);
				SETTABLE_INT("mousey", ev.y,    -3);
				llua_call(L, "on_input", 1, 0);
			}
		}
	}
	
	lua_close(L);
	return 0;
}

// utility functions

void
signal_lhand(int sig)
{
	/* run signal handler */
	lua_pushinteger(L, (lua_Integer) sig);
	llua_call(L, "on_signal", 1, 0);
}

void
signal_fatal(int sig)
{
	llua_sdump(L);
	die("received signal %d; aborting.", sig);
}

void
die(const char *fmt, ...)
{
	fprintf(stderr, "fatal: ");

	va_list ap;
	va_start(ap, fmt);
	vfprintf(stderr, fmt, ap);
	va_end(ap);

	if (fmt[0] && fmt[strlen(fmt) - 1] == ':') {
		perror(" ");
	} else {
		fputc('\n', stderr);
	}

	int nptrs;
	void *buffer[BT_BUF_SIZE];
	char **strings;

	nptrs = backtrace(buffer, BT_BUF_SIZE);
	strings = backtrace_symbols(buffer, nptrs);
	assert(strings);

	fprintf(stderr, "backtrace:\n");
	for (size_t i = 0; i < nptrs; ++i)
		fprintf(stderr, "   %s\n", strings[i]);
	free(strings);

	exit(1);
}

char *
format(const char *fmt, ...)
{
	static char buf[4096];
	va_list ap;
	va_start(ap, fmt);
	int len = vsnprintf(buf, sizeof(buf), fmt, ap);
	va_end(ap);
	assert((size_t) len < sizeof(buf));
	return (char *) &buf;
}

int
llua_panic(lua_State *pL)
{
	char *err = (char *) lua_tostring(pL, -1);

	/* run error handler */
	lua_getglobal(pL, "rt");
	if (lua_type(L, -1) != LUA_TNIL) {
		lua_getfield(pL, -1, "on_lerror");
		lua_remove(pL, -2);
		int ret = lua_pcall(pL, 0, 0, 0);

		if (ret != 0) {
			/* if the call to rt.on_lerror failed, just ignore
			 * the error message and pop it. */
			lua_pop(pL, 1);
		}
	} else {
		lua_pop(pL, 1);
	}

	/* print the error, dump the lua stack, print lua traceback,
	 * and exit. */
	fprintf(stderr, "\r\x1b[2K\x1b[0m\rlua_call error: %s\n\n", err);
	llua_sdump(L); luaL_traceback(pL, pL, err, 0);
	fprintf(stderr, "\ntraceback: %s\n\n", lua_tostring(pL, -1));
	die("unable to recover; exiting");

	return 0;
}

void
llua_sdump(lua_State *pL)
{
	fprintf(stderr, "----- STACK DUMP -----\n");
	for (int i = lua_gettop(L); i; --i) {
		int t = lua_type(L, i);
		switch (t) {
		break; case LUA_TSTRING:
			fprintf(stderr, "%4d: [string] '%s'\n", i, lua_tostring(L, i));
		break; case LUA_TBOOLEAN:
			fprintf(stderr, "%4d: [bool]   '%s'\n", i, lua_toboolean(L, i) ? "true" : "false");
		break; case LUA_TNUMBER:
			fprintf(stderr, "%4d: [number] '%g'\n", i, lua_tonumber(L, i));
		break; case LUA_TNIL:
			fprintf(stderr, "%4d: [nil]\n", i);
		break; default:
			fprintf(stderr, "%4d: [%s] #%d <%p>\n", i, lua_typename(L, t), (int) llua_rawlen(L, i), lua_topointer(L, i));
		break;
		}
	}
	fprintf(stderr, "----- STACK DUMP END -----\n");
}

void
llua_call(lua_State *pL, const char *fnname, size_t nargs, size_t nret)
{
	/* get function from rt. */
	lua_getglobal(pL, "rt");
	lua_getfield(pL, -1, fnname);
	lua_remove(pL, -2);

	/* move function before args. */
	lua_insert(pL, -nargs - 1);

	lua_call(pL, nargs, nret);
}

// API functions

int
api_conn_init(lua_State *pL)
{
	char *host = (char *) luaL_checkstring(pL, 1);
	char *port = (char *) luaL_checkstring(pL, 2);

	struct addrinfo hints;
	struct addrinfo *res, *r;

	memset(&hints, 0, sizeof hints);
	hints.ai_family = AF_UNSPEC;
	hints.ai_socktype = SOCK_STREAM;

	if(getaddrinfo(host, port, &hints, &res) != 0) {
		lua_pushnil(pL);
		lua_pushstring(pL, format("cannot resolve hostname: %s", strerror(errno)));
		return 2;
	}

	for(r = res; r != NULL; r = r->ai_next) {
		if((conn_fd = socket(r->ai_family, r->ai_socktype, r->ai_protocol)) == -1)
			continue;
		if(connect(conn_fd, r->ai_addr, r->ai_addrlen) == 0)
			break;
		close(conn_fd);
	}

	freeaddrinfo(res);

	if (r == NULL || ((conn = fdopen(conn_fd, "r+")) == NULL)) {
		lua_pushnil(pL);
		lua_pushstring(pL, format("cannot connect to host: %s", strerror(errno)));
		return 2;
	}

	// push some random integer to provide a distinction between calls to this
	// function that return nil because they failed or because there was nothing
	// to return
	lua_pushinteger(L, (lua_Integer) 1);
	return 1;
}

int
api_conn_fd(lua_State *pL)
{
	lua_pushinteger(pL, (lua_Integer) conn_fd);
	return 1;
}

int
api_conn_send(lua_State *pL)
{
	// TODO: check if connection is still open
	char *data = (char *) luaL_checkstring(pL, 1);
	char *fmtd = format("%s\r\n", data);

	ssize_t sent = send(conn_fd, fmtd, strlen(fmtd), 0);

	if (sent == -1) {
		lua_pushnil(pL);
		lua_pushstring(pL, format("cannot send: %s", strerror(errno)));
		return 2;
	} else if (sent < (strlen(data) + 2)) {
		lua_pushnil(pL);
		lua_pushstring(pL, format("sent != len(data): %s", strerror(errno)));
		return 2;
	}

	return 0;
}

int
api_tb_init(lua_State *pL)
{
	char *errstrs[] = {
		NULL,
		"termbox: unsupported terminal",
		"termbox: could not open terminal",
		"termbox: pipe trap error"
	};

	char *err = errstrs[-(tb_init())];

	if (err) {
		lua_pushnil(pL); lua_pushstring(pL, err);
		return 2;
	} else {
		tb_select_output_mode(TB_OUTPUT_256);
		lua_pushboolean(pL, true);
		return 1;
	}
}

int
api_tb_shutdown(lua_State *pL)
{
	tb_shutdown();
	return 0;
}

int
api_tb_size(lua_State *pL)
{
	lua_pushinteger(pL, (lua_Integer) tb_height());
	lua_pushinteger(pL, (lua_Integer) tb_width());

	return 2;
}

int
api_tb_clear(lua_State *pL)
{
	tb_clear();
	return 0;
}

int
api_tb_present(lua_State *pL)
{
	tb_present();
	return 0;
}

int
api_tb_writeline(lua_State *pL)
{
	int line = luaL_checkinteger(pL, 1);
	char *string = (char *) luaL_checkstring(pL, 2);
	int col = 0;
	struct tb_cell c;
	c.fg = 15, c.bg = 0;

	/* TODO: unicode support */
	while (*string) {
		if (*string == '\x1b') {
			switch (*(++string)) {
			break; case 'r':
				c.fg = 15, c.bg = 0;
				++string;
			break; case '1':
				c.fg |= TB_BOLD;
				++string;
			break; case '2':;
				uint32_t oldfg = c.fg;
				c.fg = *(++string);

				if ((oldfg & TB_BOLD) == TB_BOLD)
					c.fg |= TB_BOLD;
				if ((oldfg & TB_REVERSE) == TB_REVERSE)
					c.fg |= TB_REVERSE;
			break; case '3':
				c.fg |= TB_REVERSE;
				++string;
			break; case '4':
				c.fg |= TB_UNDERLINE;
				++string;
			break; case '5': /* italic */
			break; case '6': /* blink */
				break;
			break; case '7':;
				uint32_t oldbg = c.bg;
				c.bg = *(++string);

				if ((oldbg & TB_BOLD) == TB_BOLD)
					c.fg |= TB_BOLD;
				if ((oldbg & TB_REVERSE) == TB_REVERSE)
					c.bg |= TB_REVERSE;
			break; default:
				break;
			}
		} else {
			c.ch = *string;
			tb_put_cell(col, line, &c);
			++col;
		}
		++string;
	}

	return 0;
}

int
api_tb_clearline(lua_State *pL)
{
	int line = luaL_checkinteger(pL, 1);
	int width = tb_width();
	for (size_t i = 0; i < width; ++i)
		tb_change_cell(i, line, ' ', 0, 0);
	return 0;
}

int
api_tb_hidecursor(lua_State *pL)
{
	tb_set_cursor(TB_HIDE_CURSOR, TB_HIDE_CURSOR);
	return 0;
}

int
api_tb_showcursor(lua_State *pL)
{
	int x = luaL_checkinteger(pL, 1);
	int y = luaL_checkinteger(pL, 2);
	tb_set_cursor(x, y);
	return 0;
}
