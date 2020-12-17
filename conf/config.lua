local M = {}

M.tls  = true
M.host = "irc.tilde.chat"
M.port = 6697

M.nick = "inebriate|lurch"

-- server password. This is distinct from SASL or Nickserv IDENTIFY.
M.pass = nil

-- If this is nil, it defaults to M.nick
M.user = nil

-- your "real name". if nil, defaults to the nickname.
M.name = "o hai"

-- channels to join by on startup.
M.join = { "#chaos" }

-- default quit/part message. default to ""
M.quit_msg = "*thud*"
M.part_msg = "*confused shouting*"

-- set these to nil to not respond to CTCP messages.
M.ctcp_version = "lurch (beta)"
M.ctcp_source  = "https://github.com/lptstr/lurch"
M.ctcp_ping    = true

-- if set to false, will simply filter out mirc colors.
M.mirc = true

M.time_col_width = 5
M.right_col_width = nil -- defaults to $(terminal_width - left_col_width - time_col_width)
M.left_col_width = 12

-- words that will generate a notification if they appear in a message
M.pingwords = { "kiedtl" }

-- user defined commands. These take the place of aliases.
M.commands = { }

-- what timezone to display times in. (format: "UTC[+-]<offset>")
M.tz = "UTC-3:00"

-- Attempt to prevent the ident from being received.
-- This is done by delaying the registration of the user after connecting to the
-- IRC server for a few seconds; by then, some servers will have their identd
-- requests time out. Note that only a few IRCd's are susceptible to this.
M.no_ident = false

-- function used to draw the statusbar. There are *two* inbuilt statusbar
-- functions: simple_statusbar, which is a colorless statusline copied from
-- icyrc (https://github.com/icyphox/irc), and fancy_statusbar, which is a
-- more fully-featured statusline which makes heavy use of color, and was
-- inspired by catgirl (https://git.causal.agency/catgirl)
--M.statusbar = tui.fancy_statusbar

-- List of IRCv3 capabilities to enable.
--
-- Supported capabilities:
--   * server-time: enables adding the "time" IRCv3 tag to messages, thus
--        allowing us to accurately determine when a message was sent.
--   * away-notify: allows the server to notify us when a user changes their
--        away status
--   * account-notify: allows the server to notify us when a user logs in
--        or logs out of their NickServ account
--   * echo-message: normally, when the user sends a message, the server
--        does not let us know if the message was recieved or not. with this
--        enabled, the server will "echo" our messages back to us.
--
-- Note that these capabilities will only be enabled if the server
-- supports it.
--
M.caps = { "server-time", "away-notify", "account-notify", "echo-message" }

return M
