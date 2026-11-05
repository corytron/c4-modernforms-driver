-- fan.discovery: the DNS question, the answer parser and the Find Fans window (docs/v1-design.md section 9.10,
-- V5a; K10 in section 11.1). Pure: no Director and no fake runtime. The network binding and the timer are hand-made
-- fakes; the datagrams come from tests/fixtures/mdns.lua, whose encoder builds the variants below.

local fx = require("fixtures.mdns")
local discovery = require("fan.discovery")

-- Test addresses built from their parts, so the source holds no address
-- literal outside the documented placeholders (the secrets check).
local function ip(...)
	return table.concat({ ... }, ".")
end

local enc = fx.encode
local TYPE = fx.TYPE

-- The parser reads strangers' datagrams: it must never raise, and its own guard must never have to catch one
-- (that would be a bug the guard hides).
local function parse(data)
	local ok, list, why = pcall(discovery.parse, data)
	assert(ok, tostring(list))
	assert.is_table(list)
	assert.is_not.equal("error", why, "the parser's own guard caught an error")
	return list, why
end

-- What a fan record may hold, spelled differently from the module's own cleaning.
local function well_formed(fan)
	local function printable(text)
		return type(text) == "string" and not text:find("[%c,\128-\255]")
	end
	return printable(fan.instance) and #fan.instance >= 1 and #fan.instance <= 63
		and type(fan.address) == "string" and fan.address:match("^%d+%.%d+%.%d+%.%d+$") ~= nil
		and type(fan.port) == "number"
		and (fan.mac == nil or (type(fan.mac) == "string" and fan.mac:match("^%x%x%x%x%x%x%x%x%x%x%x%x$") ~= nil
			and fan.mac == fan.mac:upper()))
		and (fan.firmware == nil or (printable(fan.firmware) and #fan.firmware >= 1 and #fan.firmware <= 32))
end

local function assert_well_formed(list)
	for _, fan in ipairs(list) do
		assert.is_true(well_formed(fan), "malformed fan record " .. tostring(fan.instance))
	end
end

-- The record set of fan one with a TXT record made of these strings.
local function with_strings(...)
	return fx.fan_message({ strings = { ... } })
end

local PROTOCOL = "Protocol=com.modernforms.fan"

-- The TXT owner of FAN_ONE reached through exactly `hops` compression pointers (RFC 1035 section 4.1.4): a record
-- of a type nobody reads holds the instance's name written out and a chain of pointers, and the TXT record's
-- owner is the first of them. The other names are written out.
local function hop_message(hops)
	local fan = fx.FAN_ONE
	local buf = enc.buffer()
	buf.put(enc.header({ flags = 0x8400, an = 3, ar = 1 }))
	local name_at = buf.size()
	local _, chain_at = enc.rr(buf, enc.name(fan.instance, "_easylink", "_tcp", "local"), 99, 1, 120, function(at)
		local stones = {}
		for i = 1, hops - 1 do
			stones[i] = enc.ptr(i < hops - 1 and at + 2 * i or name_at)
		end
		return table.concat(stones)
	end)
	enc.rr(buf, enc.name(fan.instance, "_easylink", "_tcp", "local"), TYPE.SRV, 1, 120,
		enc.srv(0, 0, 80, enc.name(fan.instance, "local")))
	enc.rr(buf, enc.ptr(hops > 1 and chain_at or name_at), TYPE.TXT, 1, 4500,
		enc.txt(PROTOCOL, "MAC=00:00:5E:00:53:01", "Firmware Rev=02.00.0052"))
	enc.rr(buf, enc.name(fan.instance, "local"), TYPE.A, 1, 120, enc.a(fan.address))
	return buf.bytes()
end

-- A deterministic stream of numbers 0..n-1 (a linear congruential generator that stays exact in doubles).
local function random_source(seed)
	local state = seed
	return function(n)
		state = (state * 1664525 + 1013904223) % 4294967296
		return math.floor(state / 65536) % n
	end
end

-- A log that keeps what the finder writes, formatted as common.log would (log.has finds a line by its text).
local function new_log()
	local log = { lines = {} }
	for _, level in ipairs({ "debug", "info", "warn", "error" }) do
		log[level] = function(fmt, ...)
			log.lines[#log.lines + 1] = level:upper() .. " " .. string.format(fmt, ...)
		end
	end
	function log.has(text)
		for _, line in ipairs(log.lines) do
			if line:find(text, 1, true) then
				return true
			end
		end
		return false
	end
	return log
end

-- The finder on fakes: a binding that counts its opens, sends and closes, and a clock that runs the timers the
-- finder arms. opts.open, opts.send and opts.timer replace what the fakes do; opts.no_log leaves the log out.
local function new_world(opts)
	opts = opts or {}
	local world = { opened = 0, closed = 0, sent = {}, sent_at = {}, now = 0, timers = {}, log = new_log() }

	local function open()
		world.opened = world.opened + 1
		if opts.open then
			return opts.open()
		end
	end
	local function send(bytes)
		world.sent[#world.sent + 1] = bytes
		world.sent_at[#world.sent_at + 1] = world.now
		if opts.send then
			return opts.send(#world.sent)
		end
	end
	local function close()
		world.closed = world.closed + 1
	end
	local function timer(ms, fn)
		if opts.timer then
			return opts.timer(ms, fn)
		end
		local armed = { due = world.now + ms, fn = fn, cancelled = false, fired = false }
		function armed:Cancel()
			self.cancelled = true
		end
		world.timers[#world.timers + 1] = armed
		return armed
	end

	-- Runs the timers that fall due, earliest first, those armed meanwhile included.
	function world.advance(ms)
		local target = world.now + ms
		while true do
			local next_timer = nil
			for _, armed in ipairs(world.timers) do
				if not armed.cancelled and not armed.fired and armed.due <= target
					and (not next_timer or armed.due < next_timer.due) then
					next_timer = armed
				end
			end
			if not next_timer then
				break
			end
			world.now = next_timer.due
			next_timer.fired = true
			next_timer.fn(next_timer)
		end
		world.now = target
	end
	function world.pending()
		local count = 0
		for _, armed in ipairs(world.timers) do
			if not armed.cancelled and not armed.fired then
				count = count + 1
			end
		end
		return count
	end

	world.finder = discovery.new({ open = open, send = send, close = close, timer = timer,
		log = (not opts.no_log) and world.log or nil })
	return world
end

-- A callback for find that keeps what it was told.
local function collector()
	local got = { calls = {} }
	got.callback = function(list, err)
		got.calls[#got.calls + 1] = { list = list, err = err }
	end
	return got
end

-- A callback for find that keeps all it was told: the list, the error, heard, and how many values came.
local function hearing()
	local got = { calls = {} }
	got.callback = function(...)
		local list, err, heard = ...
		got.calls[#got.calls + 1] = { list = list, err = err, heard = heard, count = select("#", ...) }
	end
	return got
end

-- A fan record as heard hands it out: the four fields a follow needs (address-follow-design 2.1).
local function pair_of(fan)
	return { instance = fan.instance, address = fan.address, mac = fan.mac, port = fan.port }
end

local function numbered_fan(index)
	return { instance = string.format("MF_Fan_%06d", index), address = "10.0.2.151", port = 80,
		mac = "00005E005301", firmware = "02.00.0052" }
end

local PIN, CURRENT, MOVED = "00005E005301", "10.0.2.151", "10.0.2.152" -- the pinned MAC, its old and new address

describe("fan.discovery", function()
	describe("query", function()
		it("is one PTR question for _easylink._tcp.local, id 0, class IN with the unicast bit clear: 38 bytes", function()
			local expected = string.char(0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0)
				.. string.char(9) .. "_easylink" .. string.char(4) .. "_tcp" .. string.char(5) .. "local" .. string.char(0)
				.. string.char(0, 12, 0, 1)
			local query = discovery.query()
			assert.equal(38, #query, "the length K10 logged")
			assert.equal(expected, query)
			assert.equal(query, discovery.query())
		end)

		it("goes to the mDNS group and port, which the driver's binding uses", function()
			assert.equal("224.0.0.251", discovery.GROUP)
			assert.equal(5353, discovery.PORT)
		end)

		it("is a question, not an answer: parse says so", function()
			local list, why = parse(discovery.query())
			assert.same({}, list)
			assert.equal("query", why)
		end)
	end)

	describe("parse: the datagrams K10 saw", function()
		it("reads the first answer, 250 bytes: PTR, SRV and TXT as answers, the A record added", function()
			assert.equal(250, #fx.K10_FIRST)
			local list, why = parse(fx.K10_FIRST)
			assert.same({ fx.FAN_ONE }, list)
			assert.is_nil(why)
		end)

		it("reads the second answer, 299 bytes, which names the same records in other words", function()
			assert.equal(299, #fx.K10_SECOND)
			local list, why = parse(fx.K10_SECOND)
			assert.same({ fx.FAN_ONE }, list)
			assert.is_nil(why)
		end)

		it("gives each fan as { instance, address, port, mac, firmware } and nothing else", function()
			local fan = parse(fx.K10_FIRST)[1]
			assert.same({ "address", "firmware", "instance", "mac", "port" }, (function()
				local keys = {}
				for key in pairs(fan) do keys[#keys + 1] = key end
				table.sort(keys)
				return keys
			end)())
			assert.equal("MF_Fan_005301", fan.instance)
			assert.equal("10.0.2.151", fan.address)
			assert.equal(80, fan.port)
			assert.equal("00005E005301", fan.mac)
			assert.equal("02.00.0052", fan.firmware)
		end)
	end)

	describe("parse: other datagrams", function()
		it("reads the same records in another order and other sections (A first, PTR last, cache-flush classes)", function()
			local list, why = parse(fx.REORDERED)
			assert.same({ fx.FAN_ONE }, list)
			assert.is_nil(why)
		end)

		it("reads two fans from one datagram, in the order of their TXT records", function()
			local list, why = parse(fx.TWO_FANS)
			assert.same({ fx.FAN_ONE, fx.FAN_TWO }, list)
			assert.is_nil(why)
		end)

		it("reads the second fan alone", function()
			assert.same({ fx.FAN_TWO }, parse(fx.FAN_TWO_ALONE))
		end)

		it("skips a service of another maker under _easylink: an empty list, and not a malformed datagram", function()
			local list, why = parse(fx.OTHER_EASYLINK)
			assert.same({}, list)
			assert.is_nil(why)
		end)

		it("skips a TXT record without Protocol", function()
			local list, why = parse(fx.TXT_NO_PROTOCOL)
			assert.same({}, list)
			assert.is_nil(why)
		end)

		it("gives a truncated datagram no fan and says it was cut", function()
			local list, why = parse(fx.TRUNCATED)
			assert.same({}, list)
			assert.equal("short", why)
		end)

		it("gives a datagram whose names all loop no fan, without raising", function()
			local list, why = parse(fx.LOOP)
			assert.same({}, list)
			assert.is_nil(why, "the records are framed well; it is their names that cannot be read")
		end)

		it("gives a datagram whose pointers lead out of it no fan", function()
			local list, why = parse(fx.POINTER_OUT_OF_BOUNDS)
			assert.same({}, list)
			assert.is_nil(why)
		end)

		it("stops at a label no name may have, and says so", function()
			local list, why = parse(fx.OVERSIZED_LABEL)
			assert.same({}, list)
			assert.equal("name", why)
		end)
	end)

	describe("parse: the header", function()
		it("takes only a plain response: a query, another opcode or a non-zero rcode are set aside", function()
			local function with_flags(flags)
				return fx.fan_message({ flags = flags })
			end
			assert.equal("query", select(2, parse(with_flags(0x0400))))
			assert.equal("query", select(2, parse(with_flags(0x0000))))
			assert.equal("opcode", select(2, parse(with_flags(0x8C00))))
			assert.equal("rcode", select(2, parse(with_flags(0x8403))))
			assert.same({}, parse(with_flags(0x8C00)))
		end)

		it("ignores the other flags of a response (RFC 6762 section 18): authoritative, truncated, RD, RA, AD, CD", function()
			for _, flags in ipairs({ 0x8000, 0x8200, 0x8780, 0x85B0, 0x87F0 }) do
				assert.same({ fx.FAN_ONE }, parse(fx.fan_message({ flags = flags })), string.format("flags %04x", flags))
			end
		end)

		it("ignores the id (the fan's answers carry 0, a legacy unicast answer repeats the query's)", function()
			assert.same({ fx.FAN_ONE }, parse(fx.fan_message({ id = 0x4D01 })))
		end)

		it("skips the question a legacy unicast answer repeats", function()
			local list, why = parse(fx.fan_message({ question = true }))
			assert.same({ fx.FAN_ONE }, list)
			assert.is_nil(why)
		end)

		it("skips the authority section", function()
			local list, why = parse(fx.fan_message({ authority = true }))
			assert.same({ fx.FAN_ONE }, list)
			assert.is_nil(why)
		end)

		it("follows the counts: a header that says no records gives none", function()
			assert.same({}, parse(fx.fan_message({ counts = { an = 0, ar = 0 } })))
		end)

		it("keeps what was complete when the counts promise more than the datagram holds", function()
			local list, why = parse(fx.fan_message({ counts = { an = 65535, ns = 65535, ar = 65535 } }))
			assert.same({ fx.FAN_ONE }, list, "the A record was read as the fourth answer")
			assert.equal("name", why)
		end)

		it("gives up on a question section that is not there", function()
			local list, why = parse(fx.fan_message({ counts = { qd = 65535 } }))
			assert.same({}, list)
			assert.equal("malformed", why)
		end)

		it("sets aside what is too short or too long, and what is not a string", function()
			assert.equal("short", select(2, parse("")))
			assert.equal("short", select(2, parse(fx.K10_FIRST:sub(1, 11))))
			local bare, bare_why = parse(enc.header({ flags = 0x8400 }))
			assert.same({}, bare, "a header that counts no records is a response without records")
			assert.is_nil(bare_why)
			assert.equal("name", select(2, parse(fx.K10_FIRST:sub(1, 12))), "its counts promise records that are not there")
			local padded = fx.K10_FIRST .. string.rep("\0", 9000 - #fx.K10_FIRST)
			assert.equal(9000, #padded)
			assert.same({ fx.FAN_ONE }, parse(padded), "trailing bytes after the last record are ignored")
			assert.equal("large", select(2, parse(padded .. "\0")))
			for _, value in ipairs({ true, 7, {}, print }) do
				local list, why = parse(value)
				assert.same({}, list)
				assert.equal("type", why)
			end
			assert.equal("type", select(2, parse(nil)))
		end)
	end)

	describe("parse: names", function()
		it("compares names and TXT keys without regard to case, and keeps the instance as sent", function()
			local message = fx.fan_message({
				fan = { instance = "mf_fan_005301", address = "10.0.2.151", port = 80, mac = "00005E005301",
					firmware = "02.00.0052" },
				service = { "_EASYLINK", "_Tcp", "LOCAL" },
				host = { "mf_fan_005301", "local" },
				a_host = { "MF_FAN_005301", "LOCAL" },
				strings = { "PROTOCOL=COM.MODERNFORMS.FAN", "mac=00:00:5e:00:53:01", "firmware rev=02.00.0052" },
			})
			local list = parse(message)
			assert.equal(1, #list)
			assert.equal("mf_fan_005301", list[1].instance)
			assert.equal("00005E005301", list[1].mac)
			assert.equal("02.00.0052", list[1].firmware, "values keep their case")
		end)

		it("takes only instances of _easylink._tcp.local: one label, then the service", function()
			assert.same({}, parse(fx.fan_message({ service = { "_other", "_tcp", "local" } })))
			assert.same({}, parse(fx.fan_message({ service = { "_easylink", "_udp", "local" } })))
			assert.same({}, parse(fx.fan_message({ service = { "_easylink", "_tcp", "example" } })))
			assert.same({}, parse(fx.fan_message({ service = { "x", "_easylink", "_tcp", "local" } })))
			assert.same({}, parse(fx.fan_message({ service = { "_tcp", "local" } })))
			assert.same({}, parse(fx.fan_message({ service = { "_easylink", "_tcp", "local", "extra" } })))
		end)

		it("follows a chain of 16 compression pointers and refuses 17", function()
			assert.same({ fx.FAN_ONE }, parse(hop_message(1)))
			assert.same({ fx.FAN_ONE }, parse(hop_message(2)))
			assert.same({ fx.FAN_ONE }, parse(hop_message(16)))
			assert.same({}, parse(hop_message(17)))
			assert.equal(16, discovery.MAX_HOPS)
		end)

		it("takes a label of 63 octets and refuses one of 64", function()
			local long = { instance = string.rep("a", 63), address = "10.0.2.151", port = 80, mac = "00005E005301",
				firmware = "02.00.0052" }
			assert.same({ long }, parse(fx.fan_message({ fan = long })))
			local too_long = { instance = string.rep("a", 64), address = "10.0.2.151", port = 80,
				mac = "00005E005301", firmware = "02.00.0052" }
			local list, why = parse(fx.fan_message({ fan = too_long }))
			assert.same({}, list)
			assert.equal("name", why)
		end)

		it("refuses a name over 255 octets and takes one just under", function()
			local label = string.rep("h", 63)
			assert.same({ fx.FAN_ONE }, parse(fx.fan_message({ host = { label, label, label, "local" } })))
			assert.same({}, parse(fx.fan_message({ host = { label, label, label, label, "local" } })))
		end)

		it("refuses a pointer into the header", function()
			-- Octet 3 is the second octet of the flags, 0: read as a name it is the root. Followed, it would give the
			-- SRV target and the A record's owner the same name, and so a fan.
			local fan = fx.FAN_ONE
			local buf = enc.buffer()
			buf.put(enc.header({ flags = 0x8400, an = 3, ar = 1 }))
			local service_at = buf.size()
			enc.rr(buf, enc.name("_easylink", "_tcp", "local"), TYPE.PTR, 1, 4500,
				enc.label(fan.instance) .. enc.ptr(service_at))
			enc.rr(buf, enc.label(fan.instance) .. enc.ptr(service_at), TYPE.SRV, 1, 120,
				enc.srv(0, 0, 80, enc.ptr(3)))
			enc.rr(buf, enc.name(fan.instance, "_easylink", "_tcp", "local"), TYPE.TXT, 1, 4500, enc.txt(PROTOCOL))
			enc.rr(buf, enc.ptr(3), TYPE.A, 1, 120, enc.a(fan.address))
			assert.same({}, parse(buf.bytes()))
		end)

		it("does not read a reserved label type, the second bits 01 and 10, as a name", function()
			for _, length in ipairs({ 64, 65, 127, 128, 191 }) do
				local buf = enc.buffer()
				buf.put(enc.header({ flags = 0x8400, an = 1 }))
				buf.put(string.char(length) .. string.rep("x", 20))
				local list, why = parse(buf.bytes())
				assert.same({}, list)
				assert.equal("name", why)
			end
		end)
	end)

	describe("parse: the TXT record", function()
		it("takes Protocol=com.modernforms.fan and nothing else", function()
			assert.same({}, parse(with_strings("Protocol=com.example.gadget", "MAC=00:00:5E:00:53:01")))
			assert.same({}, parse(with_strings("Protocol=com.modernforms.fans")))
			assert.same({}, parse(with_strings("Protocol=")))
			assert.same({}, parse(with_strings("Protocol")))
			assert.same({}, parse(with_strings("Model=com.modernforms.fan")))
			assert.same({}, parse(with_strings()), "a TXT record without data")
			assert.equal(1, #parse(with_strings(PROTOCOL)))
		end)

		it("takes the first of a repeated key (RFC 6763 section 6.4)", function()
			assert.same({}, parse(with_strings("Protocol=com.example.gadget", PROTOCOL)))
			local list = parse(with_strings(PROTOCOL, "Protocol=com.example.gadget", "MAC=00:00:5E:00:53:01",
				"MAC=00:00:5E:00:53:02"))
			assert.equal(1, #list)
			assert.equal("00005E005301", list[1].mac)
		end)

		it("keeps a fan whose TXT record has no MAC or no firmware, with nil in their place", function()
			local list = parse(with_strings(PROTOCOL))
			assert.same({ { instance = "MF_Fan_005301", address = "10.0.2.151", port = 80 } }, list)
			list = parse(with_strings(PROTOCOL, "Firmware Rev=02.00.0052"))
			assert.is_nil(list[1].mac)
			assert.equal("02.00.0052", list[1].firmware)
		end)

		it("reads a MAC as 12 uppercase hex digits by the rule of wire.mac12: bare, or pairs with one separator", function()
			for _, text in ipairs({ "00:00:5E:00:53:01", "00:00:5e:00:53:01", "00-00-5E-00-53-01", "00005e005301",
				"00005E005301", " 00:00:5E:00:53:01 " }) do
				assert.equal("00005E005301", parse(with_strings(PROTOCOL, "MAC=" .. text))[1].mac, text)
			end
			for _, text in ipairs({ "", "00:00:5E:00:53", "00:00:5E:00:53:01:02", "zz:00:5E:00:53:01", "00:00:5E:00:53:0g",
				"0x00005E005301", "0000.5e00.5301", "00.00.5E.00.53.01", "00:00-5E:00:53:01", "0:0:5E:00:53:01",
				"000:00:5E:00:53:01", "00 00 5E 00 53 01", "00005E00530" }) do
				local list = parse(with_strings(PROTOCOL, "MAC=" .. text))
				assert.equal(1, #list, text)
				assert.is_nil(list[1].mac, text)
			end
			assert.is_nil(parse(with_strings(PROTOCOL, "MAC"))[1].mac, "a key without a value")
		end)

		it("cuts a firmware text to 32 octets of printable ASCII and drops an empty one", function()
			assert.is_nil(parse(with_strings(PROTOCOL, "Firmware Rev="))[1].firmware)
			assert.equal(string.rep("9", 32), parse(with_strings(PROTOCOL, "Firmware Rev=" .. string.rep("9", 50)))[1].firmware)
			assert.equal("1.?.3?", parse(with_strings(PROTOCOL, "Firmware Rev=1.\1.3,"))[1].firmware)
		end)

		it("ignores a TXT record whose strings run past its data", function()
			local message = fx.K10_FIRST:gsub(string.char(23) .. "Firmware Rev=", string.char(60) .. "Firmware Rev=")
			assert.equal(#fx.K10_FIRST, #message)
			assert.same({}, parse(message))
		end)
	end)

	describe("parse: the other records", function()
		it("needs the SRV and the A record of the target; the PTR record is not needed", function()
			assert.same({}, parse(fx.fan_message({ omit = { a = true } })))
			assert.same({}, parse(fx.fan_message({ omit = { srv = true } })))
			assert.same({}, parse(fx.fan_message({ omit = { txt = true } })))
			assert.same({ fx.FAN_ONE }, parse(fx.fan_message({ omit = { ptr = true } })))
		end)

		it("reads the answer and additional sections only, not the authority section", function()
			assert.same({}, parse(fx.fan_message({ a_section = "authority" })))
		end)

		it("reads only TXT, SRV and A records: the same records under any other type are not a fan", function()
			local function retyped(message, owner, from, to)
				local at = message:find(owner .. enc.u16(from), 1, true)
				assert(at, "the record is in the fixture")
				return message:sub(1, at - 1 + #owner) .. enc.u16(to) .. message:sub(at + #owner + 2)
			end
			local txt_owner = enc.name(fx.FAN_ONE.instance, "_easylink", "_tcp", "local")
			local srv_owner = enc.label(fx.FAN_ONE.instance) .. enc.ptr(12)
			assert.same({}, parse(retyped(fx.K10_FIRST, txt_owner, TYPE.TXT, 99)))
			assert.same({}, parse(retyped(fx.K10_FIRST, srv_owner, TYPE.SRV, 99)))
			assert.same({}, parse(retyped(fx.K10_FIRST, txt_owner, TYPE.TXT, 28)), "AAAA is no TXT record")
			assert.same({ fx.FAN_ONE }, parse(retyped(retyped(fx.K10_FIRST, txt_owner, TYPE.TXT, 99), txt_owner, 99, TYPE.TXT)))
		end)

		it("takes the A record by the SRV target's name, not by its place", function()
			assert.same({}, parse(fx.fan_message({ a_host = { "Another_Host", "local" } })))
			assert.same({ fx.FAN_ONE }, parse(fx.fan_message({ host = { "fan-host", "local" } })))
		end)

		it("reports the SRV record's port", function()
			assert.equal(8080, parse(fx.fan_message({ port = 8080 }))[1].port)
		end)

		it("ignores records with a time to live of 0 (RFC 6762 section 10.1: they withdraw a record)", function()
			assert.same({}, parse(fx.fan_message({ ttl = 0 })))
		end)

		it("ignores records of a class other than IN, with or without the cache-flush bit", function()
			assert.same({}, parse(fx.fan_message({ class = 3 })))
			assert.same({}, parse(fx.fan_message({ class = 255 })))
			assert.same({ fx.FAN_ONE }, parse(fx.fan_message({ class = 0x8001 })))
		end)

		it("takes the address of the A record unless it is no host's", function()
			assert.equal("10.0.2.152", parse(fx.fan_message({ address = "10.0.2.152" }))[1].address)
			for _, address in ipairs({ "0.0.0.0", "127.0.0.1", "224.0.0.251", "239.255.255.250", "240.0.0.1",
				"255.255.255.255" }) do
				assert.same({}, parse(fx.fan_message({ address = address })), address)
			end
		end)

		it("ignores an A record whose data is not four octets, shorter or longer", function()
			assert.same({ fx.FAN_ONE }, parse(fx.fan_message({ a_data = "\10\0\2\151" })))
			for _, data in ipairs({ "", "\10", "\10\0\2", "\10\0\2\151\1", string.rep("\10", 16) }) do
				assert.same({}, parse(fx.fan_message({ a_data = data })), #data .. " octets")
			end
		end)

		it("ignores an SRV record whose target runs past the record's data", function()
			local fan = fx.FAN_ONE
			local buf = enc.buffer()
			buf.put(enc.header({ flags = 0x8400, an = 4 }))
			enc.rr(buf, enc.name(fan.instance, "local"), TYPE.A, 1, 120, enc.a(fan.address))
			enc.rr(buf, enc.name(fan.instance, "_easylink", "_tcp", "local"), TYPE.TXT, 1, 4500,
				enc.txt(PROTOCOL, "MAC=00:00:5E:00:53:01", "Firmware Rev=02.00.0052"))
			local srv_at = buf.size()
			enc.rr(buf, enc.name(fan.instance, "_easylink", "_tcp", "local"), TYPE.SRV, 1, 120,
				enc.srv(0, 0, 80, enc.name(fan.instance, "local")))
			local whole = buf.bytes()
			assert.same({ fx.FAN_ONE }, parse(whole), "as long as the record's data holds its target, the fan is found")
			-- The record's length field says 7 octets (the port and one more) while its target takes 21.
			local length_at = srv_at + #enc.name(fan.instance, "_easylink", "_tcp", "local") + 8 + 1
			local cut = whole:sub(1, length_at - 1) .. enc.u16(7) .. whole:sub(length_at + 2)
			assert.equal(#whole, #cut)
			assert.same({}, parse(cut))
		end)

		it("lists an instance once even when its TXT record is repeated", function()
			local fan = fx.FAN_ONE
			local buf = enc.buffer()
			buf.put(enc.header({ flags = 0x8400, an = 4, ar = 1 }))
			local service_at = buf.size()
			enc.rr(buf, enc.name("_easylink", "_tcp", "local"), TYPE.PTR, 1, 4500,
				enc.label(fan.instance) .. enc.ptr(service_at))
			local _, srv_at = enc.rr(buf, enc.label(fan.instance) .. enc.ptr(service_at), TYPE.SRV, 1, 120,
				enc.srv(0, 0, 80, enc.name(fan.instance, "local")))
			enc.rr(buf, enc.label(fan.instance) .. enc.ptr(service_at), TYPE.TXT, 1, 4500,
				enc.txt(PROTOCOL, "MAC=00:00:5E:00:53:01"))
			enc.rr(buf, enc.label(fan.instance) .. enc.ptr(service_at), TYPE.TXT, 1, 4500,
				enc.txt(PROTOCOL, "MAC=00:00:5E:00:53:02"))
			enc.rr(buf, enc.ptr(srv_at + 6), TYPE.A, 1, 120, enc.a(fan.address))
			local list = parse(buf.bytes())
			assert.equal(1, #list)
			assert.equal("00005E005301", list[1].mac)
		end)
	end)

	describe("parse: what a stranger may send in a name", function()
		it("keeps the printable ASCII of an instance label, spaces and # included (a Gen 1/2 fan's name)", function()
			local fan = { instance = "WAC Windermier Fan#005301", address = "10.0.2.151", port = 80,
				mac = "00005E005301", firmware = "01.03.0025" }
			assert.same({ fan }, parse(fx.fan_message({ fan = fan })))
		end)

		it("turns control characters, high bytes and commas of an instance label into ?", function()
			local fan = { instance = "A,B\1C\127D\200", address = "10.0.2.151", port = 80, mac = "00005E005301",
				firmware = "02.00.0052" }
			assert.equal("A?B?C?D?", parse(fx.fan_message({ fan = fan }))[1].instance)
		end)

		it("keeps every printable character but the comma", function()
			local printable = {}
			for byte = 32, 126 do
				if byte ~= 44 then printable[#printable + 1] = string.char(byte) end
			end
			local text = table.concat(printable)
			for first = 1, #text, 40 do
				local piece = text:sub(first, first + 39)
				local fan = { instance = piece, address = "10.0.2.151", port = 80, mac = "00005E005301",
					firmware = "02.00.0052" }
				assert.equal(piece, parse(fx.fan_message({ fan = fan }))[1].instance)
			end
		end)
	end)

	describe("parse: a Gen 1/2 announcement and a moved fan (address-follow-design 4, ECA E4)", function()
		it("has the fixture in the layout ECA E4 describes: unprompted, four answers, ttl 1500, cache-flush but on PTR",
			function()
				local data = fx.GEN12_ANNOUNCEMENT
				assert.equal(enc.header({ flags = 0x8400, an = 4 }), data:sub(1, 12), "id 0, no question, four answers")
				local function record(rtype, class)
					return enc.u16(rtype) .. enc.u16(class) .. enc.u32(1500)
				end
				assert.is_truthy(data:find(record(TYPE.PTR, 1), 13, true), "the shared PTR record")
				assert.is_truthy(data:find(record(TYPE.SRV, 0x8001), 13, true))
				assert.is_truthy(data:find(record(TYPE.TXT, 0x8001), 13, true))
				assert.is_truthy(data:find(record(TYPE.A, 0x8001), 13, true))
				assert.is_truthy(data:find(enc.label("WAC Windermier Fan#005301"), 13, true))
				assert.is_truthy(data:find("MAC=00:00:5E:00:53:01", 13, true), "the MAC as a Gen 3 fan spells it")
				for _, key in ipairs({ "Hardware Rev=", "MICO OS Rev=", "Model=", "Manufacturer=", "Seed=" }) do
					assert.is_truthy(data:find(key, 13, true), key)
				end
			end)

		it("reads it: a name with spaces and #, more TXT keys, Protocol not the first, all in the answer section",
			function()
				local list, why = parse(fx.GEN12_ANNOUNCEMENT)
				assert.same({ fx.GEN12_FAN }, list)
				assert.is_nil(why)
				assert.equal("00005E005301", list[1].mac)
				assert.equal("10.0.2.152", list[1].address)
			end)

		it("reads the fan's answer from its new address, the first layout with another A record", function()
			local list, why = parse(fx.K10_MOVED)
			assert.same({ fx.FAN_ONE_MOVED }, list)
			assert.is_nil(why)
			assert.equal(#fx.K10_FIRST, #fx.K10_MOVED)
			assert.equal(fx.FAN_ONE.mac, fx.FAN_ONE_MOVED.mac)
			assert.equal(fx.FAN_ONE.instance, fx.FAN_ONE_MOVED.instance)
		end)

		it("reads the announcement with any one octet replaced by an edge value without raising", function()
			local data = fx.GEN12_ANNOUNCEMENT
			for at = 1, #data do
				for _, value in ipairs({ 0, 1, 63, 64, 127, 128, 191, 192, 193, 255 }) do
					assert_well_formed(parse(data:sub(1, at - 1) .. string.char(value) .. data:sub(at + 1)))
				end
			end
		end)
	end)

	describe("parse: it never raises", function()
		it("reads every prefix of every fixture without raising, finding only what the whole datagram has", function()
			for _, name in ipairs(fx.NAMES) do
				local data = fx[name]
				local whole = {}
				for _, fan in ipairs(parse(data)) do whole[fan.instance] = fan end
				for length = 0, #data do
					local list = parse(data:sub(1, length))
					assert_well_formed(list)
					for _, fan in ipairs(list) do
						assert.same(whole[fan.instance], fan, name .. " cut to " .. length)
					end
				end
			end
		end)

		it("reads every prefix of the variants the specs build without raising", function()
			local variants = {
				fx.fan_message({ question = true, authority = true }),
				fx.fan_message({ class = 0x8001, ttl = 7 }),
				hop_message(16),
				fx.fan_message({ fan = fx.FAN_TWO, address = "10.0.2.152" }),
			}
			for index, data in ipairs(variants) do
				for length = 0, #data do
					assert_well_formed(parse(data:sub(1, length)))
				end
				assert.is_true(#parse(data) >= 1, "variant " .. index)
			end
		end)

		it("reads a datagram with any one octet replaced by an edge value without raising", function()
			local edges = { 0, 1, 63, 64, 127, 128, 191, 192, 193, 255 }
			for _, name in ipairs({ "K10_FIRST", "K10_SECOND", "REORDERED", "TWO_FANS" }) do
				local data = fx[name]
				for at = 1, #data do
					for _, value in ipairs(edges) do
						local changed = data:sub(1, at - 1) .. string.char(value) .. data:sub(at + 1)
						assert_well_formed(parse(changed))
					end
				end
			end
		end)

		it("answers an empty list and \"error\" if reading does raise after all: a bug must not reach Director", function()
			local real_byte = string.byte
			rawset(string, "byte", function() error("boom") end)
			local ok, list, why = pcall(discovery.parse, fx.K10_FIRST)
			rawset(string, "byte", real_byte)
			assert.is_true(ok)
			assert.same({}, list)
			assert.equal("error", why)
		end)

		it("reads random octets, and random octets after a plausible header, without raising", function()
			local random = random_source(20261104)
			for _ = 1, 1500 do
				local bytes = {}
				for i = 1, random(400) do bytes[i] = string.char(random(256)) end
				assert_well_formed(parse(table.concat(bytes)))
			end
			for _ = 1, 1500 do
				local bytes = { string.char(0, 0, 0x84, 0, 0, random(2), 0, random(6), 0, random(3), 0, random(6)) }
				for i = 2, random(300) + 2 do
					local pick = random(4)
					if pick == 0 then
						bytes[i] = string.char(192 + random(2), random(30))
					elseif pick == 1 then
						bytes[i] = string.char(random(24))
					else
						bytes[i] = string.char(random(256))
					end
				end
				assert_well_formed(parse(table.concat(bytes)))
			end
		end)
	end)

	describe("candidates (address-follow-design F4, 2.1; ECA 3.4 step 1)", function()
		-- One heard entry as find hands it out: FAN_ONE's instance, and the pinned MAC and port 80 unless given.
		local function entry(address, mac, port)
			return { instance = "MF_Fan_005301", address = address, mac = mac or PIN, port = port or 80 }
		end

		it("takes the entries of the pinned MAC, in either case, and of no other MAC", function()
			local heard = {
				entry(ip(172, 16, 0, 1), "00005E005302"),
				{ instance = "MF_Fan_005301", address = "192.168.0.1", port = 80 }, -- a TXT record without a MAC
				entry(MOVED, "00005e005301"),
				entry(ip(169, 254, 0, 1), "00005E005399"),
			}
			assert.same({ MOVED }, discovery.candidates(heard, PIN, CURRENT))
			assert.same({ MOVED }, discovery.candidates(heard, "00005e005301", CURRENT))
			assert.same({ MOVED }, discovery.candidates(heard, "00:00:5E:00:53:01", CURRENT), "as parse reads a MAC")
			assert.same({ MOVED }, discovery.candidates({ entry(MOVED, "00:00:5e:00:53:01") }, PIN, CURRENT))
			assert.same({ ip(172, 16, 0, 1) }, discovery.candidates(heard, "00005E005302", CURRENT))
			for _, pin in ipairs({ "00005E005303", "MF_00005E005301", "00005E00530", "00005E0053011", "", "  " }) do
				assert.same({}, discovery.candidates(heard, pin, CURRENT), pin)
			end
		end)

		it("takes SRV port 80 only", function()
			local heard = {
				entry(ip(172, 16, 0, 1), PIN, 8080),
				entry("192.168.0.1", PIN, 443),
				entry(ip(169, 254, 0, 1), PIN, "80"),
				{ instance = "MF_Fan_005301", address = ip(10, 0, 0, 1), mac = PIN },
				entry(MOVED, PIN, 80),
			}
			assert.same({ MOVED }, discovery.candidates(heard, PIN, CURRENT))
		end)

		it("takes private (RFC 1918) and link-local addresses only, to the edges of each block", function()
			for _, address in ipairs({ ip(10, 0, 0, 1), ip(10, 255, 255, 254), ip(172, 16, 0, 1),
				ip(172, 31, 255, 254), "192.168.0.1", "192.168.255.254", ip(169, 254, 0, 1),
				ip(169, 254, 255, 254) }) do
				assert.same({ address }, discovery.candidates({ entry(address) }, PIN, CURRENT), address)
			end
			for _, address in ipairs({ ip(9, 255, 255, 255), ip(11, 0, 0, 0), ip(172, 15, 255, 255),
				ip(172, 32, 0, 0), ip(192, 167, 255, 255), ip(192, 169, 0, 0), ip(169, 253, 255, 255),
				ip(169, 255, 0, 0), ip(100, 64, 0, 1), "198.51.100.7", "127.0.0.1", "0.0.0.0", "224.0.0.251",
				"255.255.255.255" }) do
				assert.same({}, discovery.candidates({ entry(address) }, PIN, CURRENT), address)
			end
		end)

		it("drops a lying public address: an answer may name any address, a follow reads private ones only", function()
			assert.same({}, discovery.candidates({ entry("203.0.113.9") }, PIN, CURRENT))
			assert.same({ MOVED }, discovery.candidates({ entry("203.0.113.9"), entry(MOVED) }, PIN, CURRENT))
		end)

		it("takes an address only in the one spelling parse writes: four octets, no leading zero, nothing around it",
			function()
				for _, address in ipairs({ "010.0.2.152", "10.00.2.152", "10.0.2.0152", ip(10, 0, 2, 256), "10.0.2",
					"10.0.2.152.1", " 10.0.2.152", "10.0.2.152 ", "10.0.2.152:80", "-10.0.2.152", "fan.local", "" }) do
					assert.same({}, discovery.candidates({ entry(address) }, PIN, CURRENT), address)
				end
				for _, address in ipairs({ 167772568, true, {} }) do
					assert.same({}, discovery.candidates({ entry(address) }, PIN, CURRENT))
				end
				assert.same({}, discovery.candidates({ { instance = "MF_Fan_005301", mac = PIN, port = 80 } }, PIN,
					CURRENT), "no address")
			end)

		it("drops the current address, as the model writes it or padded", function()
			local heard = { entry(CURRENT), entry(MOVED) }
			assert.same({ MOVED }, discovery.candidates(heard, PIN, CURRENT))
			assert.same({ MOVED }, discovery.candidates(heard, PIN, " " .. CURRENT .. "\t"))
			assert.same({ CURRENT }, discovery.candidates(heard, PIN, MOVED))
			assert.same({}, discovery.candidates({ entry(CURRENT) }, PIN, CURRENT), "heard where it is: nothing to read")
		end)

		it("takes two addresses of one instance, in the order heard", function()
			local heard = { entry(MOVED), entry("192.168.0.1") }
			assert.same({ MOVED, "192.168.0.1" }, discovery.candidates(heard, PIN, CURRENT))
			assert.same({ "192.168.0.1", MOVED }, discovery.candidates({ heard[2], heard[1] }, PIN, CURRENT))
		end)

		it("gives each address once, whichever instance named it", function()
			local gen12 = { instance = "WAC Windermier Fan#005301", address = MOVED, mac = PIN, port = 80 }
			assert.same({ MOVED }, discovery.candidates({ entry(MOVED), gen12, entry(MOVED) }, PIN, CURRENT))
		end)

		it("gives at most 3 addresses, the first heard; the current address and repeats do not count", function()
			assert.equal(3, discovery.MAX_CANDIDATES)
			local heard = { entry(CURRENT), entry(MOVED), entry(MOVED), entry(ip(172, 16, 0, 1)), entry(CURRENT),
				entry("192.168.0.1"), entry(ip(169, 254, 0, 1)), entry(ip(10, 0, 0, 1)) }
			assert.same({ MOVED, ip(172, 16, 0, 1), "192.168.0.1" }, discovery.candidates(heard, PIN, CURRENT))
		end)

		it("gives nothing for an empty or missing heard list or a pin that is no MAC; no current takes nothing away",
			function()
				local heard = { entry(CURRENT), entry(MOVED) }
				assert.same({}, discovery.candidates({}, PIN, CURRENT))
				assert.same({}, discovery.candidates(nil, PIN, CURRENT))
				assert.same({}, discovery.candidates("heard", PIN, CURRENT))
				assert.same({}, discovery.candidates(heard, nil, CURRENT))
				for _, pin in ipairs({ false, 42, {}, true }) do
					assert.same({}, discovery.candidates(heard, pin, CURRENT))
				end
				assert.same({ CURRENT, MOVED }, discovery.candidates(heard, PIN, nil))
				assert.same({ CURRENT, MOVED }, discovery.candidates(heard, PIN, ""))
				assert.same({}, discovery.candidates())
			end)

		it("skips entries that are not records, or whose MAC is not text, and never raises", function()
			local heard = { "10.0.2.152", 7, true, function() end, { address = MOVED, mac = 42, port = 80 },
				{ address = MOVED, mac = {}, port = 80 }, entry(MOVED) }
			local result
			assert.has_no.errors(function() result = discovery.candidates(heard, PIN, CURRENT) end)
			assert.same({ MOVED }, result)
		end)

		it("is pure: heard is left as it was, and each call gives a list of its own", function()
			local heard = { entry(CURRENT), entry(MOVED), entry("203.0.113.9") }
			local before = { entry(CURRENT), entry(MOVED), entry("203.0.113.9") }
			local first = discovery.candidates(heard, PIN, CURRENT)
			local second = discovery.candidates(heard, PIN, CURRENT)
			assert.same(before, heard)
			assert.same({ MOVED }, first)
			assert.same(first, second)
			assert.is_not.equal(first, second)
		end)
	end)

	describe("find", function()
		it("opens the binding, sends the query at once and again 1 s later, listens for 3 s, closes it once", function()
			local world = new_world()
			local got = collector()
			assert.is_true(world.finder:find(got.callback))
			assert.equal(1, world.opened)
			assert.same({ discovery.query() }, world.sent)
			assert.is_true(world.finder:busy())

			world.advance(999)
			assert.equal(1, #world.sent)
			world.advance(1)
			assert.same({ discovery.query(), discovery.query() }, world.sent)
			assert.same({ 0, 1000 }, world.sent_at)

			world.advance(1999)
			assert.equal(0, #got.calls, "not before the 3 s are over")
			assert.equal(0, world.closed)
			assert.is_true(world.finder:busy())
			world.advance(1)
			assert.equal(1, #got.calls)
			assert.equal(1, world.closed)
			assert.is_false(world.finder:busy())
			assert.same({}, got.calls[1].list, "the queries went out and nobody answered")
			assert.is_nil(got.calls[1].err)

			world.advance(60000)
			assert.equal(2, #world.sent)
			assert.equal(1, world.closed)
			assert.equal(1, #got.calls)
			assert.equal(0, world.pending())
			assert.equal(1000, discovery.REPEAT_MS)
			assert.equal(3000, discovery.WINDOW_MS)
		end)

		it("collects the answers: the same fan twice is one entry, the fans in the order they were first heard", function()
			local world = new_world()
			local got = collector()
			world.finder:find(got.callback)
			world.advance(170)
			assert.equal("answer", world.finder:received(6001, 5353, fx.K10_FIRST, "10.0.2.151"))
			world.advance(1110)
			assert.equal("answer", world.finder:received(6001, 5353, fx.K10_SECOND, "10.0.2.151"))
			world.advance(720)
			assert.equal("answer", world.finder:received(6001, 5353, fx.FAN_TWO_ALONE, "10.0.2.152"))
			world.advance(1000)
			assert.equal(1, #got.calls)
			assert.same({ fx.FAN_ONE, fx.FAN_TWO }, got.calls[1].list)
			assert.is_nil(got.calls[1].err)
		end)

		it("takes two fans from one datagram, and an answer that comes with no sender (OS 3.x passes none)", function()
			local world = new_world()
			local got = collector()
			world.finder:find(got.callback)
			world.finder:received(6001, 5353, fx.TWO_FANS)
			world.advance(3000)
			assert.same({ fx.FAN_ONE, fx.FAN_TWO }, got.calls[1].list)
		end)

		it("de-duplicates by instance without regard to case, and keeps the first answer", function()
			local world = new_world()
			local got = collector()
			world.finder:find(got.callback)
			world.finder:received(6001, 5353, fx.K10_FIRST)
			local shouted = { instance = "MF_FAN_005301", address = "10.0.2.152", port = 80, mac = "00005E005302",
				firmware = "02.00.0060" }
			world.finder:received(6001, 5353, fx.fan_message({ fan = shouted }))
			world.advance(3000)
			assert.same({ fx.FAN_ONE }, got.calls[1].list)
		end)

		it("keeps at most 64 fans in a window", function()
			local world = new_world()
			local got = collector()
			world.finder:find(got.callback)
			for index = 1, 70 do
				world.finder:received(6001, 5353, fx.fan_message({ fan = numbered_fan(index) }))
			end
			world.advance(3000)
			local list = got.calls[1].list
			assert.equal(64, #list)
			assert.equal(64, discovery.MAX_FOUND)
			assert.equal("MF_Fan_000001", list[1].instance)
			assert.equal("MF_Fan_000064", list[64].instance)
		end)

		it("hears nothing after the window: the list it handed out stays as it was", function()
			local world = new_world()
			local got = collector()
			world.finder:find(got.callback)
			world.finder:received(6001, 5353, fx.K10_FIRST)
			world.advance(3000)
			assert.equal("closed", world.finder:received(6001, 5353, fx.FAN_TWO_ALONE))
			assert.same({ fx.FAN_ONE }, got.calls[1].list)
		end)

		it("sets aside the controller's own query echoed back, other hosts' queries, other services, what is not DNS",
			function()
				local world = new_world()
				local got = collector()
				world.finder:find(got.callback)
				local other_query = enc.header({ qd = 1 }) .. enc.name("_airplay", "_tcp", "local") .. enc.u16(12) .. enc.u16(1)
				assert.equal("query", world.finder:received(6001, 5353, discovery.query(), "10.0.2.10"))
				assert.equal("query", world.finder:received(6001, 5353, other_query))
				assert.equal("other", world.finder:received(6001, 5353, fx.OTHER_EASYLINK))
				assert.equal("other", world.finder:received(6001, 5353, fx.TXT_NO_PROTOCOL))
				assert.equal("unparsed", world.finder:received(6001, 5353, "hello"))
				assert.equal("unparsed", world.finder:received(6001, 5353, string.rep("\255", 40)))
				assert.equal("unparsed", world.finder:received(6001, 5353, fx.TRUNCATED))
				assert.equal("unparsed", world.finder:received(6001, 5353, ""))
				assert.equal("unparsed", world.finder:received(6001, 5353, nil))
				assert.equal("unparsed", world.finder:received(6001, 5353, 42))
				world.advance(3000)
				assert.same({}, got.calls[1].list)
				assert.is_nil(got.calls[1].err)
				assert.is_true(world.log.has("Find Fans: window over: sent=2 answers=0 other=2 queries=2 unparsed=6 fans=0"))
			end)

		it("lets a second find join the window: one binding, two queries, every callback told at the same time", function()
			local world = new_world()
			local first, second = collector(), collector()
			assert.is_true(world.finder:find(first.callback))
			world.advance(500)
			assert.is_true(world.finder:find(second.callback))
			world.finder:received(6001, 5353, fx.K10_FIRST)
			world.advance(2499)
			assert.equal(0, #first.calls + #second.calls)
			world.advance(1)
			assert.equal(1, world.opened)
			assert.equal(2, #world.sent)
			assert.equal(1, world.closed)
			assert.same({ fx.FAN_ONE }, first.calls[1].list)
			assert.same({ fx.FAN_ONE }, second.calls[1].list)
			assert.equal(1, #first.calls)
			assert.equal(1, #second.calls)
		end)

		it("starts a new window, with a new list, for the next find", function()
			local world = new_world()
			local first, second = collector(), collector()
			world.finder:find(first.callback)
			world.finder:received(6001, 5353, fx.K10_FIRST)
			world.advance(3000)
			world.finder:find(second.callback)
			assert.equal(2, world.opened)
			world.advance(3000)
			assert.same({ fx.FAN_ONE }, first.calls[1].list)
			assert.same({}, second.calls[1].list)
			assert.equal(2, world.closed)
			assert.equal(4, #world.sent)
		end)

		it("lets a callback start the next find: its window opens after the old one is closed", function()
			local world = new_world()
			local calls = 0
			local function again()
				calls = calls + 1
				if calls == 1 then
					assert.is_false(world.finder:busy())
					assert.is_true(world.finder:find(again))
				end
			end
			world.finder:find(again)
			world.advance(3000)
			assert.equal(1, calls)
			assert.is_true(world.finder:busy())
			assert.equal(2, world.opened)
			assert.equal(1, world.closed)
			world.advance(3000)
			assert.equal(2, calls)
			assert.equal(2, world.closed)
			assert.is_false(world.finder:busy())
		end)

		it("tells every callback even when one raises, logs it, and goes on working", function()
			local world = new_world()
			local after = collector()
			world.finder:find(function() error("boom") end)
			world.finder:find(after.callback)
			world.advance(3000)
			assert.equal(1, #after.calls)
			assert.is_true(world.log.has("ERROR Find Fans: the callback failed:"))
			assert.is_true(world.log.has("boom"))
			local next_one = collector()
			world.finder:find(next_one.callback)
			world.advance(3000)
			assert.equal(1, #next_one.calls)
		end)

		it("refuses a callback that is not a function, and opens nothing for it", function()
			local world = new_world()
			local ok, why = world.finder:find(nil)
			assert.is_false(ok)
			assert.equal("callback", why)
			assert.is_false(world.finder:find("later"))
			assert.equal(0, world.opened)
			assert.is_false(world.finder:busy())
		end)

		it("logs a fan by the last four digits of its MAC and its address, never the whole MAC or the instance", function()
			local world = new_world()
			world.finder:find(function() end)
			world.finder:received(6001, 5353, fx.K10_FIRST)
			world.advance(3000)
			assert.is_true(world.log.has("DEBUG Find Fans: ...5301 at 10.0.2.151"))
			for _, line in ipairs(world.log.lines) do
				assert.is_nil(line:find("00005E005301", 1, true), line)
				assert.is_nil(line:find("00:00:5E", 1, true), line)
				assert.is_nil(line:find("MF_Fan", 1, true), line)
			end
		end)

		it("sums the window up in one debug line, with the failure when there was one", function()
			local world = new_world()
			world.finder:find(function() end)
			world.finder:received(6001, 5353, fx.TWO_FANS)
			world.finder:received(6001, 5353, fx.K10_FIRST)
			world.advance(3000)
			assert.is_true(world.log.has("DEBUG Find Fans: window over: sent=2 answers=2 other=0 queries=0 unparsed=0 fans=2"))
			local failing = new_world({ send = function() return false end })
			failing.finder:find(function() end)
			failing.advance(3000)
			assert.is_true(failing.log.has("window over: sent=0 answers=0 other=0 queries=0 unparsed=0 fans=0 failed=send"))
		end)

		it("goes on when the log itself raises", function()
			local world = new_world()
			for _, level in ipairs({ "debug", "info", "warn", "error" }) do
				world.log[level] = function() error("log is broken") end
			end
			local got = collector()
			assert.has_no.errors(function()
				world.finder:find(got.callback)
				world.finder:received(6001, 5353, fx.K10_FIRST)
				world.finder:received(6001, 5353, "hello")
				world.advance(3000)
			end)
			assert.same({ fx.FAN_ONE }, got.calls[1].list)
		end)

		it("closes the window when the timers it was given cannot be cancelled", function()
			local armed = {}
			local function timer_without_cancel(ms, fn)
				armed[#armed + 1] = { ms = ms, fn = fn }
				return {}
			end
			local world = new_world({ timer = timer_without_cancel })
			local got = collector()
			world.finder:find(got.callback)
			assert.has_no.errors(function() armed[2].fn() end)
			assert.has_no.errors(function() armed[1].fn() end)
			assert.equal(1, #got.calls)
			assert.equal(1, world.closed)

			local raising = new_world({ timer = function()
				return { Cancel = function() error("cannot cancel") end }
			end })
			raising.finder:find(function() end)
			assert.has_no.errors(function() raising.finder:stop() end)
			assert.equal(1, raising.closed)
		end)

		it("works with no log, and ignores a timer that fires after its window (one Cancel could not stop)", function()
			local armed = {}
			local world = new_world({ no_log = true, timer = function(ms, fn) armed[#armed + 1] = { ms = ms, fn = fn } end })
			local got = collector()
			world.finder:find(got.callback)
			assert.same({ 3000, 1000 }, { armed[1].ms, armed[2].ms }, "the end of the window is armed first")
			armed[2].fn()
			armed[1].fn()
			armed[2].fn()
			armed[1].fn()
			assert.equal(2, #world.sent)
			assert.equal(1, #got.calls)
			assert.equal(1, world.closed)
		end)
	end)

	describe("find: when it cannot", function()
		it("calls back at once when the binding does not open (open says false), and closes it", function()
			local world = new_world({ open = function() return false end })
			local got = collector()
			assert.is_true(world.finder:find(got.callback))
			assert.equal(1, #got.calls, "before find returned")
			assert.same({}, got.calls[1].list)
			assert.equal("open", got.calls[1].err)
			assert.equal(1, world.closed)
			assert.equal(0, #world.sent)
			assert.equal(0, world.pending())
			assert.is_false(world.finder:busy())
			assert.is_true(world.log.has("WARN Find Fans: the network binding did not open (refused)"))
		end)

		it("does the same when open raises", function()
			local world = new_world({ open = function() error("no such binding") end })
			local got = collector()
			assert.has_no.errors(function() world.finder:find(got.callback) end)
			assert.equal("open", got.calls[1].err)
			assert.equal(1, world.closed)
			assert.is_true(world.log.has("no such binding"))
		end)

		it("takes open that returns nothing, or true, as success", function()
			local silent = new_world()
			silent.finder:find(function() end)
			assert.equal(1, #silent.sent)
			local agreed = new_world({ open = function() return true end })
			agreed.finder:find(function() end)
			assert.equal(1, #agreed.sent)
		end)

		it("opens again on the next find after a failed open", function()
			local attempts = 0
			local world = new_world({ open = function()
				attempts = attempts + 1
				return attempts > 1
			end })
			local first, second = collector(), collector()
			world.finder:find(first.callback)
			world.finder:find(second.callback)
			world.advance(3000)
			assert.equal("open", first.calls[1].err)
			assert.is_nil(second.calls[1].err)
			assert.equal(2, world.opened)
			assert.equal(2, world.closed)
		end)

		it("calls back with \"send\" at the end of the window when no query could be sent", function()
			local world = new_world({ send = function() return false end })
			local got = collector()
			world.finder:find(got.callback)
			world.advance(2999)
			assert.equal(0, #got.calls)
			world.advance(1)
			assert.same({}, got.calls[1].list)
			assert.equal("send", got.calls[1].err)
			assert.equal(2, #world.sent, "both queries were tried")
			assert.equal(1, world.closed)
			assert.is_true(world.log.has("WARN Find Fans: the query was not sent (refused)"))
		end)

		it("does the same when send raises", function()
			local world = new_world({ send = function() error("not connected") end })
			local got = collector()
			assert.has_no.errors(function() world.finder:find(got.callback) end)
			world.advance(3000)
			assert.equal("send", got.calls[1].err)
			assert.is_true(world.log.has("not connected"))
		end)

		it("is no failure when only one of the queries is lost", function()
			local world = new_world({ send = function(count) return count ~= 1 end })
			local got = collector()
			world.finder:find(got.callback)
			world.advance(3000)
			assert.same({}, got.calls[1].list)
			assert.is_nil(got.calls[1].err)
		end)

		it("is no failure when a fan answers although nothing could be sent", function()
			local world = new_world({ send = function() return false end })
			local got = collector()
			world.finder:find(got.callback)
			world.finder:received(6001, 5353, fx.K10_FIRST)
			world.advance(3000)
			assert.same({ fx.FAN_ONE }, got.calls[1].list)
			assert.is_nil(got.calls[1].err)
		end)

		it("calls back with \"timer\" at once when no timer can be armed, and closes the binding", function()
			local world = new_world({ timer = function() error("no timers") end })
			local got = collector()
			assert.has_no.errors(function() world.finder:find(got.callback) end)
			assert.equal("timer", got.calls[1].err)
			assert.equal(1, world.closed)
			assert.equal(0, #world.sent)
			assert.is_false(world.finder:busy())
		end)

		it("is built, and fails into the same paths, when it was given nothing", function()
			local bare = discovery.new()
			local got = collector()
			assert.has_no.errors(function() bare:find(got.callback) end)
			assert.equal("open", got.calls[1].err)
			assert.is_false(bare:busy())
			local empty = discovery.new({})
			assert.equal("closed", empty:received(6001, 5353, fx.K10_FIRST))
			assert.has_no.errors(function() empty:stop() end)
		end)
	end)

	describe("find: heard, for the follower (address-follow-design 2.1; ECA 3.9)", function()
		it("gives every callback a third value: each (instance, address) heard, with the four fields a follow needs",
			function()
				local world = new_world()
				local got = hearing()
				world.finder:find(got.callback)
				world.finder:received(6001, 5353, fx.K10_FIRST)
				world.advance(3000)
				local call = got.calls[1]
				assert.equal(3, call.count)
				assert.same({ fx.FAN_ONE }, call.list)
				assert.is_nil(call.err)
				assert.same({ pair_of(fx.FAN_ONE) }, call.heard)
				assert.is_nil(call.heard[1].firmware)
				assert.is_not.equal(call.list[1], call.heard[1], "a record of its own")
			end)

		it("hears one fan's repeated answers once, and nothing when nobody answered", function()
			local world = new_world()
			local got = hearing()
			world.finder:find(got.callback)
			world.finder:received(6001, 5353, fx.K10_FIRST)
			world.finder:received(6001, 5353, fx.K10_SECOND)
			world.finder:received(6001, 5353, fx.REORDERED)
			world.advance(3000)
			assert.same({ pair_of(fx.FAN_ONE) }, got.calls[1].heard)
			local quiet = new_world()
			local none = hearing()
			quiet.finder:find(none.callback)
			quiet.advance(3000)
			assert.same({}, none.calls[1].heard)
			assert.is_nil(none.calls[1].err)
		end)

		it("keeps the stale answer and the fresh one of one instance: the list keeps the first, heard both (ECA FA11)",
			function()
				local world = new_world()
				local got = hearing()
				world.finder:find(got.callback)
				world.advance(170)
				assert.equal("answer", world.finder:received(6001, 5353, fx.K10_FIRST))
				world.advance(1170)
				assert.equal("answer", world.finder:received(6001, 5353, fx.K10_MOVED))
				world.advance(1660)
				local call = got.calls[1]
				assert.same({ fx.FAN_ONE }, call.list, "Find Fans shows the first answer, as before")
				assert.same({ pair_of(fx.FAN_ONE), pair_of(fx.FAN_ONE_MOVED) }, call.heard)
				assert.same({ MOVED }, discovery.candidates(call.heard, PIN, CURRENT))
				assert.same({ 0, 1000 }, world.sent_at, "the window as it was: two queries 1 s apart")
				assert.equal(1, world.opened)
				assert.equal(1, world.closed)

				local reverse = new_world()
				local other = hearing()
				reverse.finder:find(other.callback)
				reverse.finder:received(6001, 5353, fx.K10_MOVED)
				reverse.finder:received(6001, 5353, fx.K10_FIRST)
				reverse.advance(3000)
				assert.same({ fx.FAN_ONE_MOVED }, other.calls[1].list)
				assert.same({ pair_of(fx.FAN_ONE_MOVED), pair_of(fx.FAN_ONE) }, other.calls[1].heard)
				assert.same({ MOVED }, discovery.candidates(other.calls[1].heard, PIN, CURRENT))
			end)

		it("keeps two answers for one MAC under two instances: a Gen 3 answer and a Gen 1/2 announcement", function()
			local world = new_world()
			local got = hearing()
			world.finder:find(got.callback)
			world.finder:received(6001, 5353, fx.K10_FIRST)
			assert.equal("answer", world.finder:received(6001, 5353, fx.GEN12_ANNOUNCEMENT))
			world.advance(3000)
			local call = got.calls[1]
			assert.same({ fx.FAN_ONE, fx.GEN12_FAN }, call.list)
			assert.same({ pair_of(fx.FAN_ONE), pair_of(fx.GEN12_FAN) }, call.heard)
			assert.same({ MOVED }, discovery.candidates(call.heard, PIN, CURRENT))
		end)

		it("hears a Gen 1/2 fan's announcement alone, as an answer", function()
			local world = new_world()
			local got = hearing()
			world.finder:find(got.callback)
			assert.equal("answer", world.finder:received(6001, 5353, fx.GEN12_ANNOUNCEMENT))
			world.advance(3000)
			assert.same({ fx.GEN12_FAN }, got.calls[1].list)
			assert.same({ pair_of(fx.GEN12_FAN) }, got.calls[1].heard)
			assert.same({ MOVED }, discovery.candidates(got.calls[1].heard, PIN, CURRENT))
		end)

		it("keeps a lying public address in heard, which candidates then drops", function()
			local world = new_world()
			local got = hearing()
			world.finder:find(got.callback)
			world.finder:received(6001, 5353, fx.fan_message({ address = "203.0.113.9" }))
			world.finder:received(6001, 5353, fx.K10_MOVED)
			world.advance(3000)
			local call = got.calls[1]
			assert.equal(2, #call.heard)
			assert.equal("203.0.113.9", call.heard[1].address)
			assert.equal("203.0.113.9", call.list[1].address, "the list keeps the first answer, whatever it says")
			assert.same({ MOVED }, discovery.candidates(call.heard, PIN, CURRENT))
		end)

		it("compares the instance without regard to case, as the list does, and keeps the first spelling", function()
			local function shouted(address)
				return fx.fan_message({ fan = { instance = "MF_FAN_005301", address = address, port = 80,
					mac = "00005E005301", firmware = "02.00.0052" } })
			end
			local world = new_world()
			local got = hearing()
			world.finder:find(got.callback)
			world.finder:received(6001, 5353, fx.K10_FIRST)
			world.finder:received(6001, 5353, shouted(CURRENT))
			world.finder:received(6001, 5353, shouted(MOVED))
			world.advance(3000)
			assert.same({ fx.FAN_ONE }, got.calls[1].list)
			assert.same({ pair_of(fx.FAN_ONE),
				{ instance = "MF_FAN_005301", address = MOVED, mac = "00005E005301", port = 80 } }, got.calls[1].heard)
		end)

		it("hears a fan whose TXT record has no MAC, with mac nil", function()
			local world = new_world()
			local got = hearing()
			world.finder:find(got.callback)
			world.finder:received(6001, 5353, fx.fan_message({ strings = { "Protocol=com.modernforms.fan" } }))
			world.advance(3000)
			assert.same({ { instance = "MF_Fan_005301", address = CURRENT, port = 80 } }, got.calls[1].heard)
			assert.same({}, discovery.candidates(got.calls[1].heard, PIN, MOVED))
		end)

		it("keeps as many pairs as fans (64), so ten other fans heard first do not crowd the pinned one out",
			function()
				assert.equal(discovery.MAX_FOUND, discovery.MAX_HEARD)
				local world = new_world()
				local got = hearing()
				world.finder:find(got.callback)
				for index = 1, 10 do
					world.finder:received(6001, 5353, fx.fan_message({ fan = numbered_fan(index) }))
				end
				world.finder:received(6001, 5353, fx.K10_MOVED)
				world.advance(3000)
				local call = got.calls[1]
				assert.equal(11, #call.list)
				assert.equal(11, #call.heard)
				assert.equal("MF_Fan_000001", call.heard[1].instance)
				assert.same({ MOVED }, discovery.candidates(call.heard, PIN, CURRENT))
			end)

		it("keeps at most 64 pairs, the first heard: a 65th is not kept, whoever sent it", function()
			local world = new_world()
			local got = hearing()
			world.finder:find(got.callback)
			for index = 1, 70 do
				world.finder:received(6001, 5353, fx.fan_message({ fan = numbered_fan(index) }))
			end
			world.advance(3000)
			assert.equal(64, #got.calls[1].heard)
			assert.equal("MF_Fan_000064", got.calls[1].heard[64].instance)
		end)

		it("gives both lists empty, with the error, when the window cannot be had", function()
			local closed = new_world({ open = function() return false end })
			local got = hearing()
			closed.finder:find(got.callback)
			assert.same({ list = {}, err = "open", heard = {}, count = 3 }, got.calls[1])
			local timeless = new_world({ timer = function() error("no timers") end })
			local late = hearing()
			timeless.finder:find(late.callback)
			assert.same({ list = {}, err = "timer", heard = {}, count = 3 }, late.calls[1])
			local mute = new_world({ send = function() return false end })
			local unsent = hearing()
			mute.finder:find(unsent.callback)
			mute.advance(3000)
			assert.same({ list = {}, err = "send", heard = {}, count = 3 }, unsent.calls[1])
		end)

		it("tells a joined callback the same heard", function()
			local world = new_world()
			local first, second = hearing(), hearing()
			world.finder:find(first.callback)
			world.finder:received(6001, 5353, fx.K10_FIRST)
			world.finder:find(second.callback)
			world.finder:received(6001, 5353, fx.K10_MOVED)
			world.advance(3000)
			assert.same({ pair_of(fx.FAN_ONE), pair_of(fx.FAN_ONE_MOVED) }, first.calls[1].heard)
			assert.equal(first.calls[1].heard, second.calls[1].heard)
		end)

		it("leaves the heard it handed out alone: a straggler does not reach it, the next window starts empty", function()
			local world = new_world()
			local first, second = hearing(), hearing()
			world.finder:find(first.callback)
			world.finder:received(6001, 5353, fx.K10_FIRST)
			world.advance(3000)
			assert.equal("closed", world.finder:received(6001, 5353, fx.K10_MOVED))
			assert.same({ pair_of(fx.FAN_ONE) }, first.calls[1].heard)
			world.finder:find(second.callback)
			world.advance(3000)
			assert.same({}, second.calls[1].heard)
		end)

		it("tells a callback of (list, err), as Find Fans has, what it was told before", function()
			local world = new_world()
			local seen = {}
			world.finder:find(function(list, err)
				seen[#seen + 1] = { list = list, err = err }
			end)
			world.finder:received(6001, 5353, fx.K10_FIRST)
			world.finder:received(6001, 5353, fx.K10_MOVED)
			world.finder:received(6001, 5353, fx.FAN_TWO_ALONE)
			world.advance(3000)
			assert.same({ { list = { fx.FAN_ONE, fx.FAN_TWO } } }, seen)
		end)

		it("logs another address of an instance by the last four digits of its MAC, never the whole MAC or a name",
			function()
				local world = new_world()
				world.finder:find(function() end)
				world.finder:received(6001, 5353, fx.K10_FIRST)
				world.finder:received(6001, 5353, fx.K10_MOVED)
				world.finder:received(6001, 5353, fx.GEN12_ANNOUNCEMENT)
				world.advance(3000)
				assert.is_true(world.log.has("DEBUG Find Fans: ...5301 at 10.0.2.151"))
				assert.is_true(world.log.has("DEBUG Find Fans: ...5301 also at 10.0.2.152"))
				assert.is_true(world.log.has("DEBUG Find Fans: ...5301 at 10.0.2.152"), "the Gen 1/2 instance is new")
				assert.is_true(world.log.has("window over: sent=2 answers=3 other=0 queries=0 unparsed=0 fans=2"))
				for _, line in ipairs(world.log.lines) do
					for _, secret in ipairs({ "00005E005301", "00:00:5E", "MF_Fan", "Windermier" }) do
						assert.is_nil(line:find(secret, 1, true), line)
					end
				end
			end)
	end)

	describe("stop", function()
		it("ends an open window quietly: timers cancelled, the binding closed once, no callback", function()
			local world = new_world()
			local got = collector()
			world.finder:find(got.callback)
			world.advance(500)
			world.finder:stop()
			assert.equal(1, world.closed)
			assert.equal(0, world.pending())
			assert.is_false(world.finder:busy())
			world.advance(10000)
			assert.equal(0, #got.calls)
			assert.equal(1, #world.sent, "the second query never went out")
			assert.equal(1, world.closed)
			assert.equal("closed", world.finder:received(6001, 5353, fx.K10_FIRST))
		end)

		it("drops a joined callback as well, and lets the next find start fresh", function()
			local world = new_world()
			local first, second, third = collector(), collector(), collector()
			world.finder:find(first.callback)
			world.finder:find(second.callback)
			world.finder:stop()
			world.finder:find(third.callback)
			world.advance(3000)
			assert.equal(0, #first.calls + #second.calls)
			assert.equal(1, #third.calls)
			assert.equal(2, world.opened)
			assert.equal(2, world.closed)
		end)

		it("does nothing when no window is open", function()
			local world = new_world()
			world.finder:stop()
			assert.equal(0, world.closed)
			local got = collector()
			world.finder:find(got.callback)
			world.advance(3000)
			world.finder:stop()
			assert.equal(1, world.closed)
		end)
	end)

	describe("received outside a window", function()
		it("ignores everything before the first find, and never raises", function()
			local world = new_world()
			assert.equal("closed", world.finder:received(6001, 5353, fx.K10_FIRST, "10.0.2.151"))
			assert.equal("closed", world.finder:received(6001, 5353, discovery.query()))
			assert.equal("closed", world.finder:received(6001, 5353, "hello"))
			assert.equal("closed", world.finder:received(nil, nil, nil, nil))
			assert.equal("closed", world.finder:received())
			assert.equal(0, world.opened)
			assert.equal(0, #world.sent)
			assert.equal(0, #world.log.lines)
		end)

		it("ignores a straggler that comes after the window closed, and does not carry it into the next window", function()
			local world = new_world()
			local first, second = collector(), collector()
			world.finder:find(first.callback)
			world.advance(3000)
			assert.equal("closed", world.finder:received(6001, 5353, fx.K10_FIRST))
			world.finder:find(second.callback)
			world.advance(3000)
			assert.same({}, first.calls[1].list)
			assert.same({}, second.calls[1].list)
		end)

		it("ignores what arrives after stop", function()
			local world = new_world()
			world.finder:find(function() end)
			world.finder:stop()
			assert.equal("closed", world.finder:received(6001, 5353, fx.K10_FIRST))
		end)
	end)
end)
