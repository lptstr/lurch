local format    = string.format
local mirc      = require('mirc')
local lurchconn = require('lurchconn')
local termbox   = require('termbox')
local utf8utils = require('utf8utils')
local util = {}

-- sleep for x seconds. Note that this is a busy sleep.
function util.sleep(seconds)
    local starttime = os.time()
    while (starttime + seconds) >= os.time() do end
end

function util.last_gmatch(s, pat)
    local last = ""
    for i in s:gmatch(pat) do
        last = i
    end
    return last
end

function util.capture(cmd)
    local cmd = io.popen(cmd, 'r')
    if not cmd then return nil end
    local out = cmd:read('a')
    if not out then return nil end
    cmd:close()
    return out
end

function util.printf(fmt, ...)
    io.write(string.format(fmt, ...))
end

function util.eprintf(fmt, ...)
    io.stderr:write(string.format(fmt, ...))
end

-- XXX: This is more of a "die" function than a "panic"
-- function, that is, it informs the user of errors in the
-- configuration, not of errors thrown from code.
function util.panic(fmt, ...)
    lurchconn.close()
    termbox.shutdown()
    util.eprintf(fmt, ...)
    os.exit(1)
end

function util.read(file)
    local f = assert(io.open(file, 'rb'))
    local out = assert(f:read('*all'))
    f:close()
    return out
end

function util.write(file, stuff)
    local f = assert(io.open(file, 'w'))
    assert(f:write(stuff))
    f:close()
end

function util.append(file, stuff)
    local f = assert(io.open(file, 'a'))
    assert(f:write(stuff))
    f:close()
end

function util.create(file)
    util.write(file, "")
end

function util.exists(file)
    local f = io.open(file, "rb")
    if f ~= nil then f:close() end
    return f ~= nil
end

-- Fold text to width, adding newlines between words. This is basically
-- a /bin/fold implementation in Lua.
--
-- FIXME: not all unicode characters are just one display width...
-- FIXME: this may occasionally split unicode characters
function util.fold(text, width)
    -- Ugly hack to keep tests working when utf8utils aren't available.
    if not utf8utils.dwith then
        utf8utils.dwidth = utf8.len
    end

    local _raw_len = function(data)
        local rd = mirc.remove(data)
        return utf8utils.dwidth(rd) or utf8.len(rd) or #rd
    end

    local res = ""

    -- iterate over each word and surrounding whitespace
    for wp, w, wt in string.gmatch(text, "([%s]*)([^%s]+%s?)([%s]*)") do
        -- get the last line of the message.
        local last_line = util.last_gmatch(res..w, "([^\n]+)\n?")
        if not last_line then last_line = res..w end

        -- break up long words.
        if _raw_len(w) >= width then
            w = utf8utils.insert(w, width - 1, '\n')
        end

        -- only append a newline if the word's width is greater
        -- than zero. This is to prevent situations where a
        -- long word (say, a URL) is put on its own line with
        -- nothing on the line above.
        if _raw_len(last_line) >= width and _raw_len(res) > 0 then
            res = res .. "\n"
        end

        res = res .. w
        if wp then res = wp .. res end
        if wt then res = res .. wt end
    end

    return res
end

-- parse an UTC timezone offset of the format UTC[+-]<offset>
function util.parse_offset(str)
    local sign, offset_h, offset_m = str:match("UTC([+-])(.-):(.+)")

    if not sign or not offset_h or not offset_m then
        return nil
    end

    if not tonumber(offset_h) or not tonumber(offset_m) then
        return nil
    end

    offset_h = tonumber(offset_h)
    offset_m = tonumber(offset_m)

    local offset
    if offset_m == 0 then
        offset = offset_h
    else
        offset_m = (10 / (60 / offset_m))
        offset = offset_h + (offset_m / 10)
    end

    if sign == "+" then
        return offset
    elseif sign == "-" then
        return -offset
    end
end

-- get current time for a specific UTC offset.
function util.time_with_offset(offset)
    local utc_time = tonumber(os.time(os.date("!*t")))
    local local_time = utc_time + (offset * 60 * 60)
    return local_time
end

-- parse dates of the format YYYY-MM-DDThh:mm:ss.sssZ
-- (see ISO 8601:2004(E) 4.3.2)
function util.time_from_iso8601(str)
    local Y, M, D, h, m, s = str:match("(%d-)%-(%d-)%-(%d-)T(%d-):(%d-):([%d.]-)Z")

    -- get rid of the .000 part of the seconds, as os.time()
    -- doesn't seem to like non-integer fields
    local utc_time_struct = {
        isdst = false,
        year = tonumber(Y), month = tonumber(M),
        day  = tonumber(D), hour  = tonumber(h),
        min  = tonumber(m), sec   = math.floor(tonumber(s) or 0),
    }

    return os.time(utc_time_struct)
end

-- format a duration (e.g. "4534534") as "38d 2h 1m 45s"
function util.fmt_duration(secs)
    local dur_str = ""
    assert(type(secs) == "number")

    local days  = math.floor(secs / 60 / 60 / 24)
    local hours = math.floor(secs / 60 / 60 % 24)
    local mins  = math.floor(secs / 60 % 60)

    if days > 0 then dur_str = format("%s%sd ", dur_str, days) end
    if hours > 0 then dur_str = format("%s%sh ", dur_str, hours) end
    if mins > 0 then dur_str = format("%s%sm ", dur_str, mins) end

    if dur_str == "" then dur_str = format("%s%ss", dur_str, secs) end
    return dur_str:gsub("%s$", "")
end

-- remove an item at idx from an array table
-- stolen from stack overflow, of course
function util.remove(tbl, idx)
    local sz = #tbl

    for i = 1, sz do
        if i == idx then
            tbl[i] = nil
        end
    end

    local j = 0
    for i = 1, sz do
        if tbl[i] ~= nil then
            j = j + 1
            tbl[j] = tbl[i]
        end
    end

    for i = (j + 1), sz do
        tbl[i] = nil
    end

    return tbl
end

function util.table_eq(a, b)
    if #a ~= #b then return false end

    for k, v in pairs(a) do
        if type(a[k]) ~= type(b[k]) then
            return false
        end

        if type(a[k]) ~= "table" then
            if a[k] ~= b[k] then
                return false
            end
        else
            if not util.table_eq(a[k], b[k]) then
                return false
            end
        end
    end
    return true
end

util.MAP_BREAK = 0
util.MAP_CONT  = 1
util.map_SETIT = 2
function util.kvmap(tb, fn)
    for k, v in pairs(tb) do
        if fn(k, v) == util.MAP_BREAK then
            break
        end
    end
end
function util.ivmap(tb, fn)
    for i, v in ipairs(tb) do
        local ret, a1 = fn(i, v)
        if ret == util.MAP_BREAK then
            break
        elseif ret == util.MAP_SETIT then
            i = a1
        end
    end
end

function util.assert_t(...)
    for i = 1, select("#", ...) do
        local cur = select(i, ...)
        local v = select(i, ...)[1]
        local t = select(i, ...)[2]
        local c = select(i, ...)[3]

        assert(type(v) == t, format("%s: expected %s, got %s",
            c or "parameter", t, type(v)))
    end
end

function util.join(str, tb, from, to)
    if not tb then return "" end
    from = from or 1; to = to or #tb

    local buf = tb[from]
    for i = (from + 1), to do
        buf = buf .. str .. tb[i]
    end
    return buf
end

return util
