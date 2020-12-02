local irc = {}

function irc.send(fmt, ...)
	__lurch_conn_send(fmt:format(...))
end

function irc.connect(host, port, nick, user, name, pass)
	local r, e = __lurch_conn_init(host, port)
	if not r then return false, e end

	irc.send("USER %s %s %s :%s", user, user, user, name)
	if pass then irc.send("PASS %s", pass) end
	irc.send("NICK %s", nick)

	return true
end

--
-- ported from the parse() function in https://github.com/dylanaraps/birch
--
-- example IRC message:
-- @time=2020-09-07T01:14:11Z :onisamot!~onisamot@reghog.pink PRIVMSG #meat :ahah
-- ^------------------------- ^------------------------------ ^------ ^---- ^----
-- IRCv3 tags                 sender                          command arg   msg
--
function irc.parse(rawmsg)
	assert(rawmsg)
	local event = {}

	-- Remove the trailing \r\n from the raw message.
	rawmsg = rawmsg:gsub("\r\n$", "")

	-- grab the first "word" of the IRC message, as we know that
	-- will be the timestamp of the message
	--
	-- TODO: full tag-parsing capability
	--date, time = string.gmatch(rawmsg, "@time=([%d-]+)T([%d:]+)Z")()
	--rawmsg = rawmsg:gsub(".-%s", "", 1)

	-- if the next word in the raw IRC message contains ':', '@',
	-- or '!', split it and grab the sender.
	if rawmsg:gmatch("(.-)%s")():find("[:@!]") then
		-- There are two types of senders: the server, or a user.
		-- The 'server' format is just <server>, but the 'user' format
		-- is more complicated: <nick>!<user>@<host>
		event.from = rawmsg:gmatch(":?(.-)%s")()
		if rawmsg:find("[!@]") then
			event.nick = (event.from):gmatch("(.-)!.-@.+")()
			event.user = (event.from):gmatch(".-!(.-)@.+")()
			event.host = (event.from):gmatch(".-!.-@(.+)")()
		else
			event.nick = event.from
		end

		-- strip out what was already processed.
		rawmsg = rawmsg:gsub("^.-%s", "", 1)
	end

	-- Grab all the stuff before the next ':' and stuff it into
	-- a table for later. Anything after the ':' is the message.
	local data, msg = rawmsg:gmatch("([^:]+):?(.*)")()
	event.msg = msg or ""

	event.fields = {}
	for w in data:gmatch("([^%s]+)%s?") do
		event.fields[#event.fields + 1] = w
	end

	-- If the field after the typical dest is a channel, use
	-- it in place of the regular field. This correctly catches
	-- MOTD and join messages.
	event.dest = event.fields[2]
	if event.fields[3] then
		if (event.fields[3]):find("^[*#]") then
			event.dest = event.fields[3]
		elseif (event.fields[3]):find("^=") then
			event.dest = event.fields[4]
		end
	end

	-- If the message itself contains text with surrounding '\x01',
	-- we're dealing with CTCP. Simply set the type to that text so
	-- we may specially deal with it later.
	if (event.msg):find("\1[A-Z]+%s?([^\1]*)\1") then
		event.fields[1] = (event.msg):gmatch("\1([A-Z]+)%s?")()
		event.msg = (event.msg):gsub("\1[A-Z]+%s?", "")
		event.msg = (event.msg):gsub("\1", "")

		-- prepend CTCP_ to the command to distinguish it from other
		-- non-CTCP commands (e.g. PING vs CTCP PING)
		event.fields[1] = "CTCP_" .. event.fields[1]

	end

	return event
end

return irc