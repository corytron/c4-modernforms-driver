-- MF Probe (delete after M1): the throwaway hardware probe of docs/v1-design.md,
-- section 11, for checks K4 to K10 and K14 (probes/README.md says how the
-- Windows session runs each). It is not the real driver (src/modernforms_fan)
-- and is never released: probes/build_probe.sh packs it as
-- build/probe/mf_probe.c4z.
--
-- It controls nothing. It never talks to a fan, and it never answers a proxy,
-- a keypad or a press by itself; the one exception is the "Echo LED On Press"
-- property. It logs every call Director makes into it, so that what Composer,
-- the two proxies and the keypads really send can be read in the device's Lua
-- tab, and it gives the Lua window helpers in the global table P (P.help()
-- lists them).
--
-- Every line starts with "[MFP]", a sequence number, the controller's clock
-- to the millisecond and the seconds since the previous line. print's output
-- order in Composer is not guaranteed [API 9_helper/_14-print.md], hence the
-- numbers; and Composer's Lua output pane shows only lines that arrive while
-- the device's Lua tab is open (docs/composer-remote.md, rule 13), hence the
-- last 400 lines kept in memory, which P.history() prints again.
--
-- Private data: every line is passed through P.dns.redact_text, which cuts
-- MAC-like text down to its last four hex digits; mDNS traffic that is not
-- about the fan's service is counted, never printed (names of other devices
-- can be names of people and rooms).
--
-- Doc paths (paraphrased, never quoted) are relative to ~/c4-tools/reference/,
-- each under source/includes: API = docs-driverworks-api, FUND =
-- docs-driverworks-fundamentals, KP, FAN and LV2 = docs-driverworks-
-- proxyprotocol-keypad, -fan and -lightv2. Lua 5.1 only (the controller runs
-- LuaJIT with 5.1 semantics); no bit library.

-- The DriverWorks entry points are globals Director calls by name, and P is
-- the Lua window's handle on the helpers.
-- luacheck: globals P OnDriverInit OnDriverLateInit OnDriverDestroyed OnDriverRemovedFromProject
-- luacheck: globals ExecuteCommand ReceivedFromProxy OnBindingChanged OnPropertyChanged
-- luacheck: globals ReceivedFromNetwork OnConnectionStatusChanged OnNetworkBindingChanged
-- luacheck: globals OnWatchedVariableChanged

local TAG = "[MFP]"
local HISTORY_MAX = 400 -- lines kept for P.history()
local LINE_MAX = 600 -- a longer text is printed in numbered pieces
local SHOW_MAX = 200 -- lines one table dump prints at most

-- The bindings of driver.xml.
local FAN_PROXY, LIGHT_PROXY = 5001, 5002
local LIGHT_LINK, FAN_LINK = 200, 300
local ECHO_PROPERTY = "Echo LED On Press"
local ECHO_LINKS = { [LIGHT_LINK] = true, [FAN_LINK] = true }

-- P.keypad's "tap" and "hold": push, then click or release this much later.
local TAP_MS, HOLD_MS = 150, 1500

-- K10: one PTR question for the fan's service (docs/modernforms-api-research.md,
-- section 7; issue #11, M0) to the mDNS group and port (RFC 6762), over a
-- network binding made at run time, so driver.xml declares none
-- [API 32_serial_network_device/_1-CreateNetworkConnection.md]. One binding per
-- way of sending, so that a reply names the way it came back on.
local MDNS_GROUP, MDNS_PORT = "224.0.0.251", 5353
local MDNS_SERVICE = "_easylink._tcp.local"
local MDNS_PTR = 12
local MDNS_WAIT_MS = 1000 -- for OnConnectionStatusChanged ONLINE before sending anyway
local MDNS_REPEAT_MS = 1000 -- the second query, as Find Fans would send it (docs/v1-design.md 9.10)
local MDNS_WINDOW_MS = 3000 -- answers are collected this long after the first query
local MDNS_GAP_MS = 500 -- between one way and the next
-- Datagrams outside a window are logged up to this many, then only counted:
-- a group connection that NetDisconnect does not close would flood the log.
local MDNS_STRAY_MAX = 20
local MDNS_MODES = {
	-- NetConnect's IP type MULTICAST [API 32_serial_network_device/_23-NetConnect.md].
	MULTICAST = { binding = 6001, ip_type = "MULTICAST" },
	-- UDP from a port of the controller's choosing; MIRROR_UDP_PORT, which
	-- would send from 5353 too, is documented for dynamic connections and off by
	-- default [API 32_serial_network_device/_25-NetPortOptions.md]: said
	-- explicitly here, and on for UDP_MIRROR.
	UDP = { binding = 6002, ip_type = "UDP", mirror = false },
	UDP_MIRROR = { binding = 6003, ip_type = "UDP", mirror = true },
}
local MDNS_MODE_ORDER = { "MULTICAST", "UDP", "UDP_MIRROR" }
local MDNS_DEFAULT = { "MULTICAST", "UDP" }

local BINDING_NAMES = {
	[FAN_PROXY] = "fan proxy",
	[LIGHT_PROXY] = "light proxy",
	[LIGHT_LINK] = "light link, proxybindingid 5002",
	[FAN_LINK] = "fan link",
	[6001] = "mDNS MULTICAST",
	[6002] = "mDNS UDP",
	[6003] = "mDNS UDP_MIRROR",
}

P = {}

-- DNS: building a question and reading an answer (pure; P.dns) -------------
-- RFC 1035 sections 4.1.1 to 4.1.4 and 3.3 for the format, RFC 6762 for the
-- mDNS bits (the unicast-response bit of a question's class, the cache-flush
-- bit of a record's class). Plain arithmetic on bytes: no bit library.

local dns = { MAX_HOPS = 16 }
P.dns = dns

dns.TYPES = { [1] = "A", [2] = "NS", [5] = "CNAME", [12] = "PTR", [16] = "TXT", [28] = "AAAA", [33] = "SRV",
	[47] = "NSEC", [255] = "ANY" }

function dns.type_name(t)
	return dns.TYPES[t] or ("TYPE" .. tostring(t))
end

local function class_name(class)
	return class == 1 and "IN" or ("CLASS" .. tostring(class))
end

local function u16_bytes(n)
	return string.char(math.floor(n / 256) % 256, n % 256)
end

-- "_easylink._tcp.local" -> length-prefixed labels and the closing zero.
function dns.encode_name(name)
	local out = {}
	for label in tostring(name):gmatch("[^%.]+") do
		if #label > 63 then
			error("DNS label longer than 63 bytes: " .. label, 2)
		end
		out[#out + 1] = string.char(#label) .. label
	end
	out[#out + 1] = "\0"
	return table.concat(out)
end

-- One question: a header with QDCOUNT 1 and no flags (a standard query), the
-- name, the type and class IN; opts.qu sets the unicast-response bit, opts.id
-- the query id (a legacy unicast answer repeats it).
function dns.query(name, qtype, opts)
	opts = opts or {}
	local id = math.floor(tonumber(opts.id) or 0) % 65536
	local qclass = opts.qu and 32769 or 1
	return u16_bytes(id) .. u16_bytes(0) .. u16_bytes(1) .. u16_bytes(0) .. u16_bytes(0) .. u16_bytes(0)
		.. dns.encode_name(name) .. u16_bytes(qtype or MDNS_PTR) .. u16_bytes(qclass)
end

-- Readers over the datagram, 1-based positions; each raises a message on a
-- read past the end, which dns.parse turns into nil and that message.
local function byte_at(data, pos)
	local b = data:byte(pos)
	if not b then
		error("the datagram ends at byte " .. (pos - 1), 0)
	end
	return b
end

local function u16(data, pos)
	return byte_at(data, pos) * 256 + byte_at(data, pos + 1)
end

local function u32(data, pos)
	return u16(data, pos) * 65536 + u16(data, pos + 2)
end

-- A name at pos: its labels, following compression pointers at most MAX_HOPS
-- times, and the position after the name where it started. Every label's
-- bytes go into ranges, for the redacted hex dump.
local function read_name(data, pos, ranges)
	local labels, after, hops, length = {}, nil, 0, 0
	while true do
		local len = byte_at(data, pos)
		if len == 0 then
			return table.concat(labels, "."), after or (pos + 1)
		elseif len >= 192 then
			local target = (len - 192) * 256 + byte_at(data, pos + 1)
			after = after or (pos + 2)
			hops = hops + 1
			if hops > dns.MAX_HOPS then
				error("more than " .. dns.MAX_HOPS .. " compression pointers in one name", 0)
			end
			pos = target + 1
		elseif len >= 64 then
			error(string.format("label type 0x%02x at byte %d", len, pos - 1), 0)
		else
			if pos + len > #data then
				error("a label runs past the end at byte " .. (pos - 1), 0)
			end
			ranges[#ranges + 1] = { pos + 1, pos + len }
			labels[#labels + 1] = data:sub(pos + 1, pos + len)
			length = length + len + 1
			if length > 255 then
				error("a name longer than 255 bytes", 0)
			end
			pos = pos + len + 1
		end
	end
end

local function read_question(data, pos, ranges)
	local q = {}
	q.name, pos = read_name(data, pos, ranges)
	q.type = u16(data, pos)
	local class = u16(data, pos + 2)
	q.class, q.qu = class % 32768, class >= 32768
	return q, pos + 4
end

-- A resource record; PTR, SRV, TXT, A and AAAA data decoded, other types kept
-- as their length. Address bytes go into hidden (shown as "--" in the dump).
local function read_record(data, pos, ranges, hidden)
	local rec = {}
	rec.name, pos = read_name(data, pos, ranges)
	rec.type = u16(data, pos)
	local class = u16(data, pos + 2)
	rec.class, rec.flush = class % 32768, class >= 32768
	rec.ttl = u32(data, pos + 4)
	rec.rdlength = u16(data, pos + 8)
	local first, last = pos + 10, pos + 9 + rec.rdlength
	if last > #data then
		error("record data runs past the end at byte " .. (pos + 9), 0)
	end
	if rec.type == 12 or rec.type == 5 or rec.type == 2 then
		rec.target = read_name(data, first, ranges)
	elseif rec.type == 33 then
		rec.priority, rec.weight, rec.port = u16(data, first), u16(data, first + 2), u16(data, first + 4)
		rec.target = read_name(data, first + 6, ranges)
	elseif rec.type == 16 then
		rec.strings = {}
		local at = first
		while at <= last do
			local len = byte_at(data, at)
			if at + len > last then
				error("a TXT string runs past its record at byte " .. (at - 1), 0)
			end
			if len > 0 then
				ranges[#ranges + 1] = { at + 1, at + len }
			end
			rec.strings[#rec.strings + 1] = data:sub(at + 1, at + len)
			at = at + len + 1
		end
	elseif rec.type == 1 and rec.rdlength == 4 then
		rec.address = string.format("%d.%d.%d.%d", data:byte(first, last))
		hidden[#hidden + 1] = { first, last }
	elseif rec.type == 28 and rec.rdlength == 16 then
		local groups = {}
		for at = first, last, 2 do
			groups[#groups + 1] = string.format("%x", u16(data, at))
		end
		rec.address = table.concat(groups, ":")
		hidden[#hidden + 1] = { first, last }
	end
	return rec, last + 1
end

-- The message, or nil and why; never raises, whatever the bytes.
function dns.parse(data)
	if type(data) ~= "string" then
		return nil, "not a string"
	end
	local ok, result = pcall(function()
		if #data < 12 then
			error("shorter than a DNS header (" .. #data .. " bytes)", 0)
		end
		local msg = { ranges = {}, hidden = {}, questions = {}, answers = {}, authorities = {}, additionals = {} }
		msg.id = u16(data, 1)
		local flags = u16(data, 3)
		msg.flags = flags
		msg.qr = flags >= 32768
		msg.opcode = math.floor(flags / 2048) % 16
		msg.aa = math.floor(flags / 1024) % 2 == 1
		msg.tc = math.floor(flags / 512) % 2 == 1
		msg.rcode = flags % 16
		msg.counts = { u16(data, 5), u16(data, 7), u16(data, 9), u16(data, 11) }
		local pos = 13
		for _ = 1, msg.counts[1] do
			local q
			q, pos = read_question(data, pos, msg.ranges)
			msg.questions[#msg.questions + 1] = q
		end
		for section, list in ipairs({ msg.answers, msg.authorities, msg.additionals }) do
			for _ = 1, msg.counts[section + 1] do
				local rec
				rec, pos = read_record(data, pos, msg.ranges, msg.hidden)
				list[#list + 1] = rec
			end
		end
		msg.trailing = #data - pos + 1
		return msg
	end)
	if ok then
		return result
	end
	return nil, tostring(result)
end

-- MAC-like text cut down to its last four hex digits, the rest "x", so the
-- text keeps its length (docs/v1-design.md V20; docs/scaffold-design.md,
-- section 2): six hex octets joined by ":" or "-"; a run of exactly twelve hex
-- digits (a MAC written whole, as in a client id or a TXT value); and a run
-- of exactly six after "_", "-" or "Fan#" (the instance names' MAC suffix,
-- MF_Fan_XXXXXX and Fan#XXXXXX, docs/modernforms-api-research.md section 1).
local MAC_SEPARATED = "(%x%x)([:%-])(%x%x)([:%-])(%x%x)([:%-])(%x%x)([:%-])(%x%x)([:%-])(%x%x)"

function dns.redact_text(text)
	text = tostring(text)
	text = text:gsub(MAC_SEPARATED, function(_, s1, _, s2, _, s3, _, s4, o5, s5, o6)
		return "xx" .. s1 .. "xx" .. s2 .. "xx" .. s3 .. "xx" .. s4 .. o5 .. s5 .. o6
	end)
	text = text:gsub("()(%x+)", function(at, run)
		local mac_suffix = #run == 6 and (text:sub(at - 1, at - 1):match("[_%-]")
			or text:sub(math.max(1, at - 4), at - 1):lower() == "fan#")
		if #run == 12 or mac_suffix then
			return string.rep("x", #run - 4) .. run:sub(-4)
		end
		return nil
	end)
	return text
end

-- The datagram in hex, 16 bytes a line with their printable characters,
-- redacted: every name label and TXT string through redact_text, and the
-- bytes of every address record as "--". Without a parsed msg (the parse
-- failed) the whole datagram goes through redact_text.
function dns.hexdump(data, msg)
	local bytes, hidden = {}, {}
	for i = 1, #data do
		bytes[i] = data:sub(i, i)
	end
	local function overlay(first, masked)
		for i = 1, #masked do
			bytes[first + i - 1] = masked:sub(i, i)
		end
	end
	if msg then
		for _, range in ipairs(msg.ranges) do
			overlay(range[1], dns.redact_text(data:sub(range[1], range[2])))
		end
		for _, range in ipairs(msg.hidden) do
			for i = range[1], range[2] do
				hidden[i] = true
			end
		end
	else
		overlay(1, dns.redact_text(data))
	end
	local lines = {}
	for offset = 0, #data - 1, 16 do
		local hex, chars = {}, {}
		for i = offset + 1, math.min(offset + 16, #data) do
			if hidden[i] then
				hex[#hex + 1], chars[#chars + 1] = "--", "."
			else
				local b = bytes[i]:byte()
				hex[#hex + 1] = string.format("%02x", b)
				chars[#chars + 1] = (b >= 32 and b < 127) and bytes[i] or "."
			end
		end
		lines[#lines + 1] = string.format("%04x  %-47s  |%s|", offset, table.concat(hex, " "), table.concat(chars))
	end
	return lines
end

local function rdata_text(rec)
	if rec.port then
		return string.format("priority=%d weight=%d port=%d target=%s", rec.priority, rec.weight, rec.port, rec.target)
	elseif rec.target then
		return "-> " .. rec.target
	elseif rec.strings then
		local quoted = {}
		for i, s in ipairs(rec.strings) do
			quoted[i] = '"' .. s .. '"'
		end
		return table.concat(quoted, " ")
	elseif rec.address then
		return rec.address
	end
	return "(" .. rec.rdlength .. " bytes)"
end

-- One line for the header, one per question and record, all redacted.
function dns.describe(msg)
	local lines = {}
	lines[1] = string.format("id=0x%04x %s opcode=%d%s%s rcode=%d qd=%d an=%d ns=%d ar=%d", msg.id,
		msg.qr and "response" or "query", msg.opcode, msg.aa and " aa" or "", msg.tc and " tc" or "", msg.rcode,
		msg.counts[1], msg.counts[2], msg.counts[3], msg.counts[4])
	for _, q in ipairs(msg.questions) do
		lines[#lines + 1] = string.format("QD %s %s %s%s", q.name, dns.type_name(q.type), class_name(q.class),
			q.qu and " QU" or "")
	end
	for _, section in ipairs({ { "AN", msg.answers }, { "NS", msg.authorities }, { "AR", msg.additionals } }) do
		for _, rec in ipairs(section[2]) do
			lines[#lines + 1] = string.format("%s %s %s %s%s ttl=%d %s", section[1], rec.name, dns.type_name(rec.type),
				class_name(rec.class), rec.flush and " flush" or "", rec.ttl, rdata_text(rec))
		end
	end
	if msg.trailing > 0 then
		lines[#lines + 1] = msg.trailing .. " bytes after the last record"
	end
	for i, line in ipairs(lines) do
		lines[i] = dns.redact_text(line)
	end
	return lines
end

-- The log ----------------------------------------------------------------------

local history = {}
local seq = 0
local last_ms = nil

-- Milliseconds since the epoch from C4:GetTime [API 34_timer/_2-GetTime.md,
-- from 3.2.3], else os.time.
local function now_ms()
	local ok, t = pcall(function()
		return C4:GetTime()
	end)
	if ok and type(t) == "number" then
		return t
	end
	return os.time() * 1000
end

local function clock_text(ms)
	return os.date("%H:%M:%S", math.floor(ms / 1000)) .. string.format(".%03d", math.floor(ms % 1000))
end

-- One logged text: redacted, cut into pieces of LINE_MAX, printed
-- [API 9_helper/_14-print.md] and kept.
local function emit(text)
	text = dns.redact_text(tostring(text))
	local pieces = math.max(1, math.ceil(#text / LINE_MAX))
	for i = 1, pieces do
		local piece = text:sub((i - 1) * LINE_MAX + 1, i * LINE_MAX)
		if pieces > 1 then
			piece = string.format("(%d/%d) %s", i, pieces, piece)
		end
		seq = seq + 1
		local ms = now_ms()
		local delta = last_ms and (ms - last_ms) / 1000 or 0
		last_ms = ms
		local line = string.format("%s %d %s +%.3f %s", TAG, seq, clock_text(ms), delta, piece)
		history[#history + 1] = line
		if #history > HISTORY_MAX then
			table.remove(history, 1)
		end
		print(line)
	end
end

local function escape(text)
	return (text:gsub('[%c"\\]', function(c)
		if c == '"' or c == "\\" then
			return "\\" .. c
		end
		return string.format("\\%03d", c:byte())
	end))
end

local function sorted_keys(t)
	local keys = {}
	for k in pairs(t) do
		keys[#keys + 1] = k
	end
	table.sort(keys, function(a, b)
		local ta, tb = type(a), type(b)
		if ta ~= tb then
			return ta < tb
		end
		if ta == "number" or ta == "string" then
			return a < b
		end
		return tostring(a) < tostring(b)
	end)
	return keys
end

-- Strings quoted, so their type and an empty value show; tables inline.
local function format_value(value, depth)
	local kind = type(value)
	if kind == "string" then
		return '"' .. escape(value) .. '"'
	elseif kind == "table" then
		if depth > 3 then
			return "{...}"
		end
		local parts = {}
		for _, key in ipairs(sorted_keys(value)) do
			parts[#parts + 1] = tostring(key) .. "=" .. format_value(value[key], depth + 1)
		end
		return "{" .. table.concat(parts, ", ") .. "}"
	end
	return tostring(value)
end

local function format_params(params)
	if params == nil then
		return "(no params)"
	end
	return format_value(params, 1)
end

local function binding_text(binding)
	local name = BINDING_NAMES[tonumber(binding)]
	return tostring(binding) .. " (" .. (name or "not declared by the probe") .. ")"
end

-- A table value one line per leaf (path = value); anything else on one line.
local function show_value(label, value)
	if type(value) ~= "table" then
		emit(label .. ": " .. format_value(value, 1))
		return
	end
	emit(label .. ":")
	if next(value) == nil then
		emit("  (an empty table)")
		return
	end
	local shown = 0
	local function walk(t, prefix, depth)
		for _, key in ipairs(sorted_keys(t)) do
			if shown >= SHOW_MAX then
				return
			end
			local v, path = t[key], prefix .. tostring(key)
			if type(v) == "table" and next(v) ~= nil and depth < 4 then
				walk(v, path .. ".", depth + 1)
			else
				shown = shown + 1
				emit("  " .. path .. " = " .. format_value(v, 1))
			end
		end
	end
	walk(value, "", 1)
	if shown >= SHOW_MAX then
		emit("  (more not shown)")
	end
end

-- One Director call: its failure is logged, never raised (what fails is
-- itself a finding). Returns whether it ran.
local function call(what, fn)
	local ok, err = pcall(fn)
	if not ok then
		emit(what .. " failed: " .. tostring(err))
	end
	return ok
end

local function show(label, fn)
	local ok, value = pcall(fn)
	if ok then
		show_value(label, value)
	else
		emit(label .. " failed: " .. tostring(value))
	end
end

-- How often each entry point was called since the driver loaded.
local counts = {}
local function count(name)
	counts[name] = (counts[name] or 0) + 1
end

-- Timers [API 34_timer/_1-SetTimer.md], all cancelled by OnDriverDestroyed.
local timers = {}

local function after(ms, fn)
	local timer
	timer = C4:SetTimer(ms, function()
		timers[timer] = nil
		fn()
	end)
	timers[timer] = true
	return timer
end

local function cancel(timer)
	if timer then
		timers[timer] = nil
		pcall(function()
			timer:Cancel()
		end)
	end
end

-- Sending ----------------------------------------------------------------------

-- SendToProxy with the message kind always given (COMMAND or NOTIFY)
-- [API 25_proxy/_6-SendToProxy.md].
local function send_to_proxy(binding, command, params, kind, why)
	local what = string.format("C4:SendToProxy(%d, %s)", binding, command)
	if call(what, function()
		C4:SendToProxy(binding, command, params, kind)
	end) then
		emit(string.format("%ssent SendToProxy(%d, %s, %s, %s)", why or "", binding, command, format_params(params), kind))
	end
end

local function truthy(value)
	if type(value) == "string" then
		local v = value:lower()
		return v == "true" or v == "on" or v == "1"
	end
	return value == true or value == 1
end

local function color(value)
	local text = tostring(value or ""):gsub("^#", ""):lower()
	if text:match("^%x%x%x%x%x%x$") then
		return text
	end
	return nil
end

-- The Button Link's LED: on or off colour active [KP
-- 62_keypad_button_link_bindings/_1-KEYPADBUTTONLINKBINDINGS.md], a COMMAND as
-- common/device.lua sends it on the house.
function P.led(link, on)
	link = tonumber(link)
	if not link then
		emit("P.led(link, on): a link id such as 300")
		return
	end
	send_to_proxy(link, "MATCH_LED_STATE", { STATE = truthy(on) }, "COMMAND")
end

-- The link's colours as "rrggbb" [KP 62/_1], a NOTIFY with the fields
-- docs/v1-design.md K6 names; current defaults to on.
function P.colors(link, on, off, current)
	link = tonumber(link)
	local on_color, off_color = color(on), color(off)
	local current_color = current == nil and on_color or color(current)
	if not (link and on_color and off_color and current_color) then
		emit('P.colors(link, on, off, current): a link id and colours as "rrggbb"')
		return
	end
	send_to_proxy(link, "BUTTON_COLORS", { ON_COLOR = on_color, OFF_COLOR = off_color, CURRENT_COLOR = current_color },
		"NOTIFY")
end

-- Any notification to a proxy or a link [API 25_proxy/_6-SendToProxy.md];
-- params a table (default {}) or a string, SendToProxy's other form.
function P.notify(binding, command, params)
	binding = tonumber(binding)
	if not binding or type(command) ~= "string" then
		emit('P.notify(binding, command, params): for example P.notify(5001, "PRESET_SPEED", { SPEED = 4 })')
		return
	end
	send_to_proxy(binding, command, params or {}, "NOTIFY")
end

-- CURRENT_SPEED {SPEED} to the fan proxy, 0 to N, 0 is off
-- [FAN 42_fan_protocol_notifications/_1-CURRENTSPEED.md].
function P.speed(n)
	local speed = tonumber(n)
	if not speed then
		emit("P.speed(n): a speed, 0 to 6")
		return
	end
	send_to_proxy(FAN_PROXY, "CURRENT_SPEED", { SPEED = speed }, "NOTIFY")
end

-- KEYPAD_BUTTON_ACTION, the keypad proxy's command that acts as if a button
-- were used: ACTION 0 release, 1 push, 2 click, and the button's id [KP
-- 60_keypad_proxy_commands/_4-KEYPADBUTTONACTION.md, which prints the id's name
-- with a space; the protocol notification KP
-- 61_keypad_protocol_notifications/_4-KEYPAD_BUTTON_ACTION.md adds 3 and 4 for
-- double and triple clicks]. Sent to the keypad with SendToDevice
-- [API 32_serial_network_device/_19-SendToDevice.md]. "tap" is push, then click
-- TAP_MS later; "hold" push, then release HOLD_MS later. key is the name of the
-- id parameter: "BUTTON_ID" unless given.
local KEYPAD_ACTIONS = { release = 0, push = 1, click = 2 }

function P.keypad(device, button, action, key)
	device, button = tonumber(device), tonumber(button)
	if not (device and button) then
		emit('P.keypad(device_id, button_id, action, key): numbers, then "tap", "hold", "push", "click", "release" or 0-4')
		return
	end
	key = key or "BUTTON_ID"
	local function send(code)
		local params = { [key] = button, ACTION = code }
		if call("C4:SendToDevice", function()
			C4:SendToDevice(device, "KEYPAD_BUTTON_ACTION", params)
		end) then
			emit(string.format("sent SendToDevice(%d, KEYPAD_BUTTON_ACTION, %s)", device, format_params(params)))
		end
	end
	local name = action == nil and "tap" or (type(action) == "string" and action:lower() or action)
	if name == "tap" then
		send(1)
		after(TAP_MS, function()
			send(2)
		end)
	elseif name == "hold" then
		send(1)
		after(HOLD_MS, function()
			send(0)
		end)
	elseif KEYPAD_ACTIONS[name] then
		send(KEYPAD_ACTIONS[name])
	elseif tonumber(name) then
		send(tonumber(name))
	else
		emit("P.keypad: the action " .. tostring(action) .. " is none of tap, hold, push, click, release, 0-4")
	end
end

-- The proxy device on binding 5001 or 5002: the device bound to this
-- driver's proxy binding [API 32_serial_network_device/_3-GetBoundConsumerDevices.md;
-- called with this driver's own id, as the Hue drivers do on the house].
local function proxy_id(binding)
	local ok, devices = pcall(function()
		return C4:GetBoundConsumerDevices(C4:GetDeviceID(), binding)
	end)
	if ok and type(devices) == "table" then
		return tonumber((next(devices)))
	end
	return nil
end

local function device_of(target)
	local id = tonumber(target)
	if id == FAN_PROXY or id == LIGHT_PROXY then
		return proxy_id(id), BINDING_NAMES[id]
	end
	return id, "device"
end

-- A device's variables [API 22_miscellaneous/_12-GetDeviceVariables.md]: the
-- fan proxy's (target 5001, the default), the light proxy's (5002) or any
-- device id's.
function P.vars(target)
	local id, what = device_of(target or FAN_PROXY)
	if not id then
		emit("P.vars: no device for " .. tostring(target))
		return
	end
	show(string.format("C4:GetDeviceVariables(%d) (%s)", id, what), function()
		return C4:GetDeviceVariables(id)
	end)
end

-- Listeners on a device's variables, reported by OnWatchedVariableChanged
-- [API 36_variable/_10-RegisterVariableListener.md, _11-UnregisterVariableListener.md,
-- _9-OnWatchedVariableChanged.md]; the variable ids come from P.vars.
local function listen(register, target, ...)
	local id = device_of(target)
	local n = select("#", ...)
	if not id or n == 0 then
		emit("P.watch(target, variable_id, ...): a target (5001, 5002 or a device id) and variable ids from P.vars")
		return
	end
	for i = 1, n do
		local variable = tonumber((select(i, ...)))
		local what = string.format("C4:%sVariableListener(%d, %s)", register and "Register" or "Unregister", id,
			tostring(variable))
		if variable and call(what, function()
			if register then
				C4:RegisterVariableListener(id, variable)
			else
				C4:UnregisterVariableListener(id, variable)
			end
		end) then
			emit(what .. " done")
		end
	end
end

function P.watch(target, ...)
	listen(true, target, ...)
end

function P.unwatch(target, ...)
	listen(false, target, ...)
end

-- K10: the mDNS query ---------------------------------------------------------

local mdns = { active = nil, queue = {}, created = {}, sent_ids = {}, next_id = 0x4D00, qu = false, gap = nil,
	stray = 0 }

local mdns_next -- forward: starts the next way in the queue

local function mdns_finish(run, reason)
	if mdns.active ~= run then
		return
	end
	cancel(run.wait_timer)
	cancel(run.repeat_timer)
	cancel(run.window_timer)
	call("C4:NetDisconnect", function()
		C4:NetDisconnect(run.binding, MDNS_PORT) -- [API 32_serial_network_device/_24-NetDisconnect.md]
	end)
	emit(string.format("mDNS %s: %s; %d quer%s sent, %d datagram(s) received: %d own quer%s, %d answer(s) "
		.. "about %s, %d other, %d unparsed", run.mode, reason, run.sent, run.sent == 1 and "y" or "ies",
		run.received, run.own, run.own == 1 and "y" or "ies", run.answers, MDNS_SERVICE, run.other, run.unparsed))
	mdns.active = nil
	if #mdns.queue > 0 then
		mdns.gap = after(MDNS_GAP_MS, function()
			mdns.gap = nil
			mdns_next()
		end)
	else
		emit("mDNS probe done")
	end
end

local function mdns_send(run, n)
	if mdns.active ~= run then
		return
	end
	mdns.next_id = (mdns.next_id + 1) % 65536
	local id = mdns.next_id
	local packet = dns.query(MDNS_SERVICE, MDNS_PTR, { id = id, qu = run.qu })
	if call("C4:SendToNetwork", function()
		C4:SendToNetwork(run.binding, MDNS_PORT, packet) -- [API 32_serial_network_device/_20-SendToNetwork.md]
	end) then
		mdns.sent_ids[id] = true
		run.sent = run.sent + 1
		emit(string.format("mDNS %s: query %d sent on %d to %s:%d (id 0x%04x, PTR %s, %s, %d bytes)", run.mode, n,
			run.binding, MDNS_GROUP, MDNS_PORT, id, MDNS_SERVICE, run.qu and "QU" or "QM", #packet))
		if n == 1 then
			for _, line in ipairs(dns.hexdump(packet)) do
				emit("  " .. line)
			end
		end
	end
end

local function mdns_start_queries(run, why)
	if mdns.active ~= run or run.querying then
		return
	end
	run.querying = true
	cancel(run.wait_timer)
	emit(string.format("mDNS %s: %s; listening for %d s", run.mode, why, MDNS_WINDOW_MS / 1000))
	mdns_send(run, 1)
	run.repeat_timer = after(MDNS_REPEAT_MS, function()
		mdns_send(run, 2)
	end)
	run.window_timer = after(MDNS_WINDOW_MS, function()
		mdns_finish(run, "the window is over")
	end)
end

-- One way of sending: the binding made once [API 32/_1, with no connection
-- type, as Snap One's public SSDP module does for its multicast search], the
-- port options for UDP [API 32/_25], the connection [API 32/_23]; the queries
-- go out on ONLINE [API 32_serial_network_device/_27-OnConnectionStatusChanged.md]
-- or after MDNS_WAIT_MS without it.
local function mdns_start(mode)
	local m = MDNS_MODES[mode]
	local run = { mode = mode, binding = m.binding, qu = mdns.qu, sent = 0, received = 0, own = 0, answers = 0,
		other = 0, unparsed = 0 }
	mdns.active = run
	emit(string.format("mDNS %s: binding %d, %s to %s:%d%s", mode, m.binding, m.ip_type, MDNS_GROUP, MDNS_PORT,
		m.mirror == nil and "" or (", MIRROR_UDP_PORT " .. tostring(m.mirror))))
	if not mdns.created[m.binding] then
		if not call("C4:CreateNetworkConnection", function()
			C4:CreateNetworkConnection(m.binding, MDNS_GROUP)
		end) then
			return mdns_finish(run, "no connection")
		end
		mdns.created[m.binding] = true
	end
	if m.mirror ~= nil and not call("C4:NetPortOptions", function()
		C4:NetPortOptions(m.binding, MDNS_PORT, m.ip_type, { MIRROR_UDP_PORT = m.mirror })
	end) then
		return mdns_finish(run, "the port options were refused")
	end
	if not call("C4:NetConnect", function()
		C4:NetConnect(m.binding, MDNS_PORT, m.ip_type)
	end) then
		return mdns_finish(run, "the connection was refused")
	end
	run.wait_timer = after(MDNS_WAIT_MS, function()
		mdns_start_queries(run, string.format("no ONLINE within %d s, sending anyway", MDNS_WAIT_MS / 1000))
	end)
end

mdns_next = function()
	local mode = table.remove(mdns.queue, 1)
	if mode then
		mdns_start(mode)
	end
end

-- What one datagram is. Only one about the fan's service is printed whole
-- (decoded and as hex); others are counted with their record types.
local function report_datagram(data, run)
	local msg, err = dns.parse(data)
	local about_fan = data:lower():find("_easylink", 1, true) ~= nil
	local kind
	if not msg then
		kind = "unparsed"
		emit("  not a DNS message (" .. err .. ")" .. (about_fan and "" or "; content not logged"))
		if about_fan then
			for _, line in ipairs(dns.hexdump(data)) do
				emit("  " .. line)
			end
		end
	elseif not about_fan then
		kind = "other"
		local types, seen = {}, {}
		for _, list in ipairs({ msg.questions, msg.answers, msg.authorities, msg.additionals }) do
			for _, item in ipairs(list) do
				local name = dns.type_name(item.type)
				if not seen[name] then
					seen[name] = true
					types[#types + 1] = name
				end
			end
		end
		emit(string.format("  other mDNS traffic, names not logged: id=0x%04x %s qd=%d an=%d ns=%d ar=%d types=%s",
			msg.id, msg.qr and "response" or "query", msg.counts[1], msg.counts[2], msg.counts[3], msg.counts[4],
			#types > 0 and table.concat(types, ",") or "-"))
	else
		if not msg.qr and mdns.sent_ids[msg.id] then
			kind = "own"
			emit("  our own query, looped back")
		elseif msg.qr then
			kind = "answers"
		else
			kind = "other"
			emit("  a query from someone else for the fan's service")
		end
		for _, line in ipairs(dns.describe(msg)) do
			emit("  " .. line)
		end
		for _, line in ipairs(dns.hexdump(data, msg)) do
			emit("  " .. line)
		end
	end
	if run then
		run[kind] = run[kind] + 1
	end
end

-- K10 from the Lua window or the "Run mDNS Probe" action: mode nil or "ALL"
-- runs MULTICAST, then UDP; "MULTICAST", "UDP" or "UDP_MIRROR" runs one; qu
-- true sets the unicast-response bit of the question.
function P.mdns(mode, qu)
	if mdns.active or #mdns.queue > 0 then
		emit("mDNS: a probe is still running; wait for its \"mDNS probe done\" line")
		return
	end
	local modes
	if mode == nil or tostring(mode):upper() == "ALL" then
		modes = { MDNS_DEFAULT[1], MDNS_DEFAULT[2] }
	else
		local name = tostring(mode):upper()
		if not MDNS_MODES[name] then
			emit("mDNS: the mode " .. tostring(mode) .. " is none of MULTICAST, UDP, UDP_MIRROR or ALL")
			return
		end
		modes = { name }
	end
	mdns.qu = qu == true
	mdns.queue = modes
	mdns.stray = 0
	emit(string.format("mDNS probe: %s, PTR %s, %s, %d s each", table.concat(modes, " then "), MDNS_SERVICE,
		mdns.qu and "QU" or "QM", MDNS_WINDOW_MS / 1000))
	mdns_next()
end

local function mdns_stop()
	mdns.queue = {}
	cancel(mdns.gap)
	mdns.gap = nil
	local run = mdns.active
	if run then
		mdns_finish(run, "stopped")
	end
end

-- Dump State and the rest of P -----------------------------------------------

local function counts_text()
	local parts = {}
	for _, name in ipairs(sorted_keys(counts)) do
		parts[#parts + 1] = name .. "=" .. counts[name]
	end
	return #parts > 0 and table.concat(parts, " ") or "none"
end

local function lua_text()
	local jit_lib = rawget(_G, "jit")
	local jit_version = type(jit_lib) == "table" and jit_lib.version or nil
	return tostring(_VERSION) .. (jit_version and (", " .. tostring(jit_version)) or "")
end

-- What the probe and Director say about it now: the driver, the proxies and
-- what is bound to the links [API 32_serial_network_device/_3-GetBoundConsumerDevices.md],
-- every binding Director lists for the device and each proxy (K5: the fan
-- proxy's own speed links, if it makes any)
-- [API 32_serial_network_device/_2.5-GetBindingsByDevice.md, which asks for a
-- proxy's id where a device has proxies; 25_proxy/_1-GetProxyDevices.md], and
-- the K10 bindings' addresses [API 32_serial_network_device/_2-GetBindingAddress.md].
function P.dump()
	emit("Dump State: begin")
	show("driver version", function()
		return C4:GetDriverConfigInfo("version") -- [API 22_miscellaneous/_13-GetDriverConfigInfo.md]
	end)
	show("device id", function()
		return C4:GetDeviceID() -- [API 22_miscellaneous/_11-GetDeviceID.md]
	end)
	show("Director", function()
		return C4:GetVersionInfo() -- [API 5_director_command/_2-GetVersionInfo.md]
	end)
	emit("Lua: " .. lua_text())
	emit(ECHO_PROPERTY .. ": " .. format_value(Properties[ECHO_PROPERTY], 1))
	show("C4:GetProxyDevices()", function()
		return C4:GetProxyDevices()
	end)
	for _, binding in ipairs({ FAN_PROXY, LIGHT_PROXY, LIGHT_LINK, FAN_LINK }) do
		show("C4:GetBoundConsumerDevices(device, " .. binding_text(binding) .. ")", function()
			return C4:GetBoundConsumerDevices(C4:GetDeviceID(), binding)
		end)
	end
	show("C4:GetBindingsByDevice(device)", function()
		return C4:GetBindingsByDevice(C4:GetDeviceID())
	end)
	for _, binding in ipairs({ FAN_PROXY, LIGHT_PROXY }) do
		local id = proxy_id(binding)
		if id then
			show(string.format("C4:GetBindingsByDevice(%d) (the %s)", id, BINDING_NAMES[binding]), function()
				return C4:GetBindingsByDevice(id)
			end)
		end
	end
	for _, mode in ipairs(MDNS_MODE_ORDER) do
		local binding = MDNS_MODES[mode].binding
		if mdns.created[binding] then
			show(string.format("C4:GetBindingAddress(%d) (mDNS %s)", binding, mode), function()
				return C4:GetBindingAddress(binding)
			end)
		end
	end
	emit("calls into the probe: " .. counts_text())
	emit(string.format("mDNS: %s; %d datagram(s) outside a probe window since the last run",
		mdns.active and (mdns.active.mode .. " running") or "idle", mdns.stray))
	emit("Dump State: end")
end

-- The kept lines again (the last n, or all), printed and not kept twice.
function P.history(n)
	local total = #history
	local shown = math.min(total, math.max(0, math.floor(tonumber(n) or total)))
	print(string.format("%s history: the last %d of %d kept lines", TAG, shown, total))
	for i = total - shown + 1, total do
		print(history[i])
	end
end

local HELP = {
	"P.help()                      this list",
	"P.led(link, on)               MATCH_LED_STATE {STATE} on a link (200, 300 or another id), COMMAND",
	'P.colors(link, on, off, cur)  BUTTON_COLORS {ON_COLOR, OFF_COLOR, CURRENT_COLOR} "rrggbb", NOTIFY',
	"P.notify(binding, cmd, params) SendToProxy(binding, cmd, params, NOTIFY)",
	"P.speed(n)                    CURRENT_SPEED {SPEED = n} to the fan proxy (5001)",
	"P.keypad(device, button, action, key)  KEYPAD_BUTTON_ACTION to a keypad: action tap (default), hold,",
	'                              push, click, release or 0-4; key "BUTTON_ID" (default) or "BUTTON ID"',
	"P.mdns(mode, qu)              K10: nil = MULTICAST then UDP; MULTICAST, UDP or UDP_MIRROR; qu = true for QU",
	"P.vars(target)                C4:GetDeviceVariables of 5001 (default), 5002 or a device id",
	"P.watch(target, id, ...)      listen to those variables; P.unwatch(target, id, ...) stops",
	"P.dump()                      the Dump State action",
	"P.history(n)                  the last n kept lines again (all without n)",
}

function P.help()
	for _, line in ipairs(HELP) do
		emit(line)
	end
end

-- Entry points -------------------------------------------------------------------

-- The Lua window is allowed from the start [API 22_miscellaneous/_2-AllowExecute.md,
-- callable in OnDriverInit; FUND 6_Understanding .c4z Drivers/_3-C4ALLOWEXECUTE.md:
-- true unlocks the window]; build_probe.sh also packs with dp3's --allowexecute.
function OnDriverInit(init_type)
	count("OnDriverInit")
	local allowed = call("C4:AllowExecute", function()
		C4:AllowExecute(true)
	end)
	emit(string.format("OnDriverInit %s; Lua window %s", tostring(init_type), allowed and "allowed" or "NOT allowed"))
end

-- [API 22_miscellaneous/_25.1-OnDriverLateInit.md]: the lookups are safe from here.
function OnDriverLateInit(init_type)
	count("OnDriverLateInit")
	local function value(fn)
		local ok, v = pcall(fn)
		return ok and v or nil
	end
	local director = value(function()
		return C4:GetVersionInfo()
	end)
	emit(string.format("OnDriverLateInit %s: MF Probe version %s, device %s, Director %s, %s; P.help() lists the helpers",
		tostring(init_type), tostring(value(function()
			return C4:GetDriverConfigInfo("version")
		end)), tostring(value(function()
			return C4:GetDeviceID()
		end)), type(director) == "table" and tostring(director.version) or "?", lua_text()))
end

-- [API 22_miscellaneous/_24-OnDriverDestroyed.md]: the K10 connection closed,
-- every timer cancelled.
function OnDriverDestroyed(init_type)
	count("OnDriverDestroyed")
	emit("OnDriverDestroyed " .. tostring(init_type))
	mdns_stop()
	for timer in pairs(timers) do
		pcall(function()
			timer:Cancel()
		end)
	end
	timers = {}
end

-- [API 22_miscellaneous/_26-OnDriverRemovedFromProject.md]
function OnDriverRemovedFromProject()
	count("OnDriverRemovedFromProject")
	emit("OnDriverRemovedFromProject")
end

-- Everything a proxy or a keypad link sends [API 25_proxy/_5-ReceivedFromProxy.md;
-- KP 62_keypad_button_link_bindings/_1-KEYPADBUTTONLINKBINDINGS.md for
-- DO_PUSH, DO_CLICK, DO_RELEASE and REQUEST_BUTTON_COLORS]. Nothing is
-- answered, except with Echo LED On Press On: DO_PUSH on 200 or 300 lights
-- that link's LED and DO_RELEASE darkens it.
function ReceivedFromProxy(idBinding, strCommand, tParams)
	count("ReceivedFromProxy")
	emit(string.format("ReceivedFromProxy binding=%s cmd=%s %s", binding_text(idBinding), tostring(strCommand),
		format_params(tParams)))
	local binding = tonumber(idBinding)
	if ECHO_LINKS[binding] and Properties[ECHO_PROPERTY] == "On" then
		if strCommand == "DO_PUSH" then
			send_to_proxy(binding, "MATCH_LED_STATE", { STATE = true }, "COMMAND", "echo: ")
		elseif strCommand == "DO_RELEASE" then
			send_to_proxy(binding, "MATCH_LED_STATE", { STATE = false }, "COMMAND", "echo: ")
		end
	end
end

local function action_key(text)
	return (tostring(text or ""):lower():gsub("[_%s]+", " "):match("^%s*(.-)%s*$"))
end

local ACTIONS = {
	["run mdns probe"] = function()
		P.mdns()
	end,
	["dump state"] = function()
		P.dump()
	end,
}

-- Commands to the driver: Composer's actions arrive as LUA_ACTION with the
-- action's <command> in ACTION; programming and SendToDevice commands too
-- [API 5_director_command/_1-ExecuteCommand.md].
function ExecuteCommand(strCommand, tParams)
	count("ExecuteCommand")
	emit(string.format("ExecuteCommand cmd=%s %s", tostring(strCommand), format_params(tParams)))
	if strCommand == "LUA_ACTION" and type(tParams) == "table" then
		local action = ACTIONS[action_key(tParams.ACTION)]
		if action then
			action()
		end
	end
end

-- [API 9_helper/_12-OnBindingChanged.md]: K4 and K6 read which keypad and
-- which of its bindings is bound to a link.
function OnBindingChanged(idBinding, strClass, bIsBound, otherDeviceID, otherBindingID)
	count("OnBindingChanged")
	emit(string.format("OnBindingChanged binding=%s class=%s bound=%s other_device=%s other_binding=%s",
		binding_text(idBinding), tostring(strClass), tostring(bIsBound), tostring(otherDeviceID),
		tostring(otherBindingID)))
end

-- [API 24_properties/_3-OnPropertyChanged.md]: the value is in Properties.
function OnPropertyChanged(strName)
	count("OnPropertyChanged")
	emit(string.format("OnPropertyChanged name=%s value=%s", format_value(strName, 1),
		format_value(Properties[strName], 1)))
end

-- [API 32_serial_network_device/_15-ReceivedFromNetwork.md]: from only on
-- OS 4.0.0 and later. K10 reads what arrives on 6001 to 6003.
function ReceivedFromNetwork(idBinding, nPort, strData, from)
	count("ReceivedFromNetwork")
	local data = tostring(strData or "")
	local run = mdns.active
	if run and run.binding ~= tonumber(idBinding) then
		run = nil
	end
	if not run then
		mdns.stray = mdns.stray + 1
		if mdns.stray > MDNS_STRAY_MAX then
			if mdns.stray == MDNS_STRAY_MAX + 1 then
				emit(string.format("ReceivedFromNetwork: more than %d datagrams outside a probe window; the rest are "
					.. "only counted (P.dump)", MDNS_STRAY_MAX))
			end
			return
		end
	end
	emit(string.format("ReceivedFromNetwork binding=%s port=%s bytes=%d%s%s", binding_text(idBinding),
		tostring(nPort), #data, from ~= nil and (" from=" .. tostring(from)) or "",
		run and "" or " (outside a probe window)"))
	if run then
		run.received = run.received + 1
	end
	report_datagram(data, run)
end

-- [API 32_serial_network_device/_27-OnConnectionStatusChanged.md]: ONLINE on
-- the binding of the running K10 way sends its queries.
function OnConnectionStatusChanged(idBinding, nPort, strStatus)
	count("OnConnectionStatusChanged")
	emit(string.format("OnConnectionStatusChanged binding=%s port=%s status=%s", binding_text(idBinding),
		tostring(nPort), tostring(strStatus)))
	local run = mdns.active
	if run and run.binding == tonumber(idBinding) and strStatus == "ONLINE" then
		mdns_start_queries(run, "the connection is ONLINE")
	end
end

-- [API 32_serial_network_device/_28-OnNetworkBindingChanged.md]
function OnNetworkBindingChanged(idBinding, bIsBound)
	count("OnNetworkBindingChanged")
	emit(string.format("OnNetworkBindingChanged binding=%s bound=%s", binding_text(idBinding), tostring(bIsBound)))
end

-- [API 36_variable/_9-OnWatchedVariableChanged.md]: the variables P.watch listens to.
function OnWatchedVariableChanged(idDevice, idVariable, strValue)
	count("OnWatchedVariableChanged")
	emit(string.format("OnWatchedVariableChanged device=%s variable=%s value=%s", tostring(idDevice),
		tostring(idVariable), format_value(strValue, 1)))
end
