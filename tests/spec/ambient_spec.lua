-- fan.ambient on fakes: whether the bound keypad's LEDs are dark, from its AMBIENT_LIGHT_LEVEL readings (#207,
-- docs/ambient-pause-design.md: AP1 to AP5, AP-D2 to AP-D5 and the interface of section 2). The timer records its
-- ms and callback; advance() moves the fake clock and fires every timer that falls due on the way. on_change is
-- recorded in r.changes as { dark, why }.
--
-- Unless a spec says otherwise: the keypad is device 123, bound and settled (bound, then 6 s, so the first
-- reading counts), the threshold is the default 10.

local ambient = require("fan.ambient")

local KEYPAD = 123
local OTHER = 456
local HOLD_MS = 10000
local SETTLE_MS = 5000

local function fake_log()
	local l = { lines = {} }
	for _, level in ipairs({ "error", "warn", "info", "debug" }) do
		l[level] = function(fmt, ...)
			l.lines[#l.lines + 1] = { level = level, text = string.format(fmt, ...) }
		end
	end
	function l.has(level, needle)
		for _, line in ipairs(l.lines) do
			if line.level == level and line.text:find(needle, 1, true) then
				return true
			end
		end
		return false
	end
	function l.count(level)
		local n = 0
		for _, line in ipairs(l.lines) do
			if line.level == level then
				n = n + 1
			end
		end
		return n
	end
	return l
end

-- The module on fakes. opts: no_clock (no `now`), no_timer (no `timer`), no_on_change.
local function rig(opts)
	opts = opts or {}
	local r = { clock = 1000, timers = {}, changes = {}, log = fake_log() }
	r.a = ambient.new({
		now = not opts.no_clock and function()
			if r.fail_clock then
				error("no clock")
			end
			return r.clock
		end or nil,
		timer = not opts.no_timer and function(ms, cb)
			if r.fail_timer then
				error("no timer")
			end
			local t = { ms = ms, cb = cb, at = r.clock, cancelled = false, fired = false }
			function t:Cancel()
				self.cancelled = true
			end
			r.timers[#r.timers + 1] = t
			return t
		end or nil,
		on_change = not opts.no_on_change and function(dark, why)
			r.changes[#r.changes + 1] = { dark, why }
			if r.raise then
				error("on_change refused")
			end
		end or nil,
		log = r.log,
	})
	return r
end

-- The timers neither cancelled nor fired.
local function live(r)
	local out = {}
	for _, t in ipairs(r.timers) do
		if not t.cancelled and not t.fired then
			out[#out + 1] = t
		end
	end
	return out
end

-- Moves the clock by ms, firing every live timer that falls due on the way, in order, at its time.
local function advance(r, ms)
	local target = r.clock + ms
	while true do
		local due
		for _, t in ipairs(live(r)) do
			if t.at + t.ms <= target and (due == nil or t.at + t.ms < due.at + due.ms) then
				due = t
			end
		end
		if due == nil then
			break
		end
		due.fired = true
		r.clock = due.at + due.ms
		due.cb()
	end
	r.clock = target
end

-- A reading as Director hands it to ExecuteCommand: strings (AP1). level is sent as given when it is not a number.
local function read(r, level, group)
	r.a:reading({
		GROUP = tostring(group or KEYPAD),
		LEVEL = type(level) == "number" and tostring(level) or level,
		TARGET = "1",
	})
end

-- Bound to the keypad and past the settle window, so the first reading counts.
local function settled(opts)
	local r = rig(opts)
	r.a:bound(KEYPAD)
	advance(r, SETTLE_MS + 1000)
	return r
end

local function changes(r)
	local out = r.changes
	r.changes = {}
	return out
end

describe("fan.ambient", function()
	it("has the contract's constants", function()
		assert.are.equal(HOLD_MS, ambient.LIT_HOLD_MS)
		assert.are.equal(SETTLE_MS, ambient.BIND_SETTLE_MS)
		assert.are.equal(10, ambient.DEFAULT_THRESHOLD)
		assert.are.equal(255, ambient.MAX_LEVEL)
	end)

	describe("the states (AP-D3)", function()
		it("starts unknown and not dark, and never calls on_change at construction", function()
			local r = rig()
			assert.are.equal("unknown", r.a:state())
			assert.is_false(r.a:dark())
			assert.are.same({}, r.changes)
			assert.are.same({}, r.timers)
		end)

		it("goes from unknown to dark at once on a reading below the threshold", function()
			local r = settled()
			read(r, 3)
			assert.are.equal("dark", r.a:state())
			assert.is_true(r.a:dark())
			assert.are.same({ { true, "keypad dark (reading 3 < 10)" } }, changes(r))
			assert.are.same({}, live(r))
		end)

		it("goes from unknown to lit at once on a reading at the threshold, with no on_change", function()
			local r = settled()
			read(r, 10)
			assert.are.equal("lit", r.a:state())
			assert.is_false(r.a:dark())
			assert.are.same({}, r.changes)
			assert.are.same({}, live(r))
		end)

		it("goes from lit to dark at once", function()
			local r = settled()
			read(r, 40)
			read(r, 9)
			assert.are.equal("dark", r.a:state())
			assert.are.same({ { true, "keypad dark (reading 9 < 10)" } }, changes(r))
		end)

		it("calls on_change once for a run of dark readings", function()
			local r = settled()
			read(r, 3)
			read(r, 6)
			read(r, 0)
			assert.are.equal(1, #changes(r))
			assert.is_true(r.a:dark())
		end)

		it("arms nothing for a lit reading while lit", function()
			local r = settled()
			read(r, 40)
			read(r, 50)
			assert.are.same({}, r.timers)
			assert.are.same({}, r.changes)
		end)
	end)

	describe("the lit hold (AP-D3, DM15)", function()
		it("resumes once when the hold completes with no dark reading since", function()
			local r = settled()
			read(r, 3)
			changes(r)
			read(r, 14)
			assert.is_true(r.a:dark(), "a lit reading does not resume at once")
			assert.are.equal(1, #live(r))
			assert.are.equal(HOLD_MS, live(r)[1].ms)
			advance(r, HOLD_MS - 1)
			assert.is_true(r.a:dark())
			assert.are.same({}, r.changes)
			advance(r, 1)
			assert.are.equal("lit", r.a:state())
			assert.are.same({ { false, "keypad lit again (reading 14 >= 10, held 10 s)" } }, changes(r))
			assert.are.same({}, live(r))
			advance(r, 60000)
			assert.are.same({}, r.changes)
		end)

		it("pauses once and does not resume for dark, lit and dark within the hold", function()
			local r = settled()
			read(r, 3)
			advance(r, 2000)
			read(r, 14)
			local hold = live(r)[1]
			advance(r, 4000)
			read(r, 5)
			assert.is_true(hold.cancelled, "the dark reading cancels the hold")
			assert.are.same({}, live(r))
			advance(r, 60000)
			assert.is_true(r.a:dark())
			assert.are.same({ { true, "keypad dark (reading 3 < 10)" } }, changes(r))
			hold.cb() -- a cancelled timer that fires anyway changes nothing
			assert.is_true(r.a:dark())
			assert.are.same({}, r.changes)
		end)

		it("times the hold from the first lit reading: later ones leave it running", function()
			local r = settled()
			read(r, 3)
			changes(r)
			read(r, 14)
			advance(r, 6000)
			read(r, 20)
			read(r, 30)
			assert.are.equal(1, #r.timers, "one hold")
			advance(r, 4000)
			assert.are.equal("lit", r.a:state())
			assert.are.same({ { false, "keypad lit again (reading 30 >= 10, held 10 s)" } }, changes(r))
		end)

		it("starts a new hold after a flicker, timed from its own first lit reading", function()
			local r = settled()
			read(r, 3)
			read(r, 14)
			advance(r, 5000)
			read(r, 4)
			advance(r, 1000)
			read(r, 15)
			advance(r, HOLD_MS - 1)
			assert.is_true(r.a:dark())
			advance(r, 1)
			assert.is_false(r.a:dark())
			assert.are.same({ true, false }, { r.changes[1][1], r.changes[2][1] })
			assert.are.equal(2, #r.changes)
		end)

		it("resumes at once with a warning when the hold cannot be armed (fail-open)", function()
			local r = settled()
			read(r, 3)
			changes(r)
			r.fail_timer = true
			read(r, 14)
			assert.are.equal("lit", r.a:state())
			assert.is_true(r.log.has("warn", "the hold timer could not be armed"))
			local got = changes(r)
			assert.are.equal(1, #got)
			assert.is_false(got[1][1])
			assert.is_truthy(got[1][2]:find("could not be armed", 1, true))
		end)

		it("resumes at once without a timer option", function()
			local r = settled({ no_timer = true })
			read(r, 3)
			read(r, 14)
			assert.are.equal("lit", r.a:state())
			assert.are.equal(2, #r.changes)
		end)
	end)

	describe("set_threshold (AP-D2)", function()
		it("takes a whole number 0 to 255 rounded half up, and the default 10 for anything else", function()
			local r = rig()
			local cases = {
				{ 20, 20 }, { "12", 12 }, { " 7 ", 7 }, { 3.5, 4 }, { 3.49, 3 }, { "3.5", 4 }, { 0, 0 },
				{ 255, 255 }, { 255.4, 255 }, { -0.4, 0 }, { 0.5, 1 },
				{ 256, 10 }, { 255.5, 10 }, { -1, 10 }, { -0.6, 10 }, { "abc", 10 }, { "", 10 },
				{ true, 10 }, { {}, 10 }, { 0 / 0, 10 }, { math.huge, 10 }, { -math.huge, 10 },
			}
			for _, case in ipairs(cases) do
				r.a:set_threshold(100) -- a different value first, so every case is a change
				r.a:set_threshold(case[1])
				assert.are.equal(case[2], r.a:debug().threshold, "set_threshold(" .. tostring(case[1]) .. ")")
			end
			r.a:set_threshold(100)
			r.a:set_threshold(nil)
			assert.are.equal(10, r.a:debug().threshold)
		end)

		it("goes dark at once when a higher threshold puts the last reading below it", function()
			local r = settled()
			read(r, 14)
			r.a:set_threshold(20)
			assert.is_true(r.a:dark())
			assert.are.same({ { true, "keypad dark (reading 14 < 20, the threshold changed)" } }, changes(r))
		end)

		it("arms the hold when a lower threshold puts the last reading at or above it while dark", function()
			local r = settled()
			read(r, 6)
			changes(r)
			r.a:set_threshold(6)
			assert.is_true(r.a:dark(), "the hold still applies to resuming")
			assert.are.equal(1, #live(r))
			advance(r, HOLD_MS)
			assert.is_false(r.a:dark())
			assert.are.same({ { false, "keypad lit again (reading 6 >= 6, held 10 s)" } }, changes(r))
		end)

		it("cancels the hold, staying dark, when a higher threshold puts the last reading below it again", function()
			local r = settled()
			read(r, 3)
			read(r, 14)
			changes(r)
			local hold = live(r)[1]
			r.a:set_threshold(20)
			assert.is_true(hold.cancelled)
			assert.is_true(r.a:dark())
			advance(r, 60000)
			assert.is_true(r.a:dark())
			assert.are.same({}, r.changes)
		end)

		it("never goes dark at threshold 0", function()
			local r = settled()
			r.a:set_threshold(0)
			read(r, 0)
			assert.are.equal("lit", r.a:state())
			assert.are.same({}, r.changes)
		end)

		it("resumes after the hold when set to 0 while dark", function()
			local r = settled()
			read(r, 0)
			changes(r)
			r.a:set_threshold(0)
			assert.is_true(r.a:dark())
			advance(r, HOLD_MS)
			assert.are.equal("lit", r.a:state())
			assert.are.same({ { false, "keypad lit again (reading 0 >= 0, held 10 s)" } }, changes(r))
		end)

		it("changes nothing while unknown, and the new threshold judges the next reading", function()
			local r = settled()
			r.a:set_threshold(30)
			assert.are.equal("unknown", r.a:state())
			read(r, 20)
			assert.is_true(r.a:dark())
		end)

		it("does nothing when the threshold is the same", function()
			local r = settled()
			read(r, 3)
			read(r, 14)
			local before = #r.log.lines
			r.a:set_threshold(10)
			r.a:set_threshold("10")
			assert.are.equal(before, #r.log.lines)
			assert.are.equal(1, #r.timers)
		end)
	end)

	describe("the readings that count (AP-D4)", function()
		it("ignores the first reading after a bind (AP3) and counts the second, even within the window", function()
			local r = rig()
			r.a:bound(KEYPAD)
			advance(r, 200)
			read(r, 0) -- the house keypad's first message after a bind
			assert.are.equal("unknown", r.a:state())
			assert.are.same({}, r.changes)
			assert.is_true(r.log.has("debug", "reading ignored: 0 is the first after the bind (200 ms after it)"))
			advance(r, 1000)
			read(r, 4)
			assert.is_true(r.a:dark())
			assert.are.equal(1, #r.changes)
		end)

		it("counts a first reading 6 s after the bind", function()
			local r = rig()
			r.a:bound(KEYPAD)
			advance(r, 6000)
			read(r, 4)
			assert.is_true(r.a:dark())
		end)

		it("ignores a first reading at exactly BIND_SETTLE_MS and counts one a millisecond later", function()
			local r = rig()
			r.a:bound(KEYPAD)
			advance(r, SETTLE_MS)
			read(r, 4)
			assert.are.equal("unknown", r.a:state())
			r.a:bound(KEYPAD)
			advance(r, SETTLE_MS + 1)
			read(r, 4)
			assert.are.equal("dark", r.a:state())
		end)

		it("ignores the first reading after a bind whatever its time when there is no clock", function()
			local r = rig({ no_clock = true })
			r.a:bound(KEYPAD)
			advance(r, 60000)
			read(r, 4)
			assert.are.equal("unknown", r.a:state())
			read(r, 4)
			assert.are.equal("dark", r.a:state())
		end)

		it("does not use the skip up on a bad LEVEL or another device's reading", function()
			local r = rig()
			r.a:bound(KEYPAD)
			read(r, "abc")
			read(r, 2, OTHER)
			read(r, 0)
			assert.are.equal("unknown", r.a:state(), "the bind's artifact is still the one skipped")
			read(r, 4)
			assert.are.equal("dark", r.a:state())
		end)

		it("ignores a reading from a device other than the bound one", function()
			local r = settled()
			read(r, 3, OTHER)
			assert.are.equal("unknown", r.a:state())
			assert.is_true(r.log.has("debug", "reading ignored: 3 from device 456, not the bound device 123"))
			read(r, 3, " 123 ")
			assert.are.equal("dark", r.a:state())
		end)

		it("counts a reading with no GROUP", function()
			local r = settled()
			r.a:reading({ LEVEL = "3" })
			assert.is_true(r.a:dark())
		end)

		it("does not check GROUP after a bind with no usable id", function()
			local r = rig()
			r.a:bound("")
			advance(r, 6000)
			read(r, 3, OTHER)
			assert.is_true(r.a:dark())
		end)

		it("counts a reading while unbound, from any device, with nothing skipped", function()
			local r = rig()
			read(r, 3, OTHER)
			assert.is_true(r.a:dark())
			read(r, 20, KEYPAD)
			assert.are.equal(1, #live(r))
			assert.is_nil(r.a:debug().bound)
		end)

		it("ignores LEVELs that are not whole numbers 0 to 255, and decides against rounding fractions", function()
			local r = settled()
			local bad = { "abc", "-1", "256", "3.5", "3.0", "1e2", "0x10", "+3", "", " ", "3 4", -1, 256, 3.5,
				0 / 0, math.huge, true, {} }
			for _, level in ipairs(bad) do
				r.a:reading({ GROUP = "123", LEVEL = level })
				assert.are.equal("unknown", r.a:state(), "LEVEL " .. tostring(level))
			end
			r.a:reading({ GROUP = "123" })
			assert.are.equal("unknown", r.a:state(), "no LEVEL")
			assert.is_true(r.log.has("debug", 'reading ignored: LEVEL "3.5" is not a whole number 0 to 255'))
			assert.is_true(r.log.has("debug", "reading ignored: LEVEL 3.5 is not a whole number 0 to 255"))
			assert.is_true(r.log.has("debug", "reading ignored: LEVEL nil is not a whole number 0 to 255"))
			assert.are.same({}, r.changes)
		end)

		it("takes LEVEL as decimal digits or a whole number", function()
			local cases = { { "0", 0 }, { "255", 255 }, { " 7 ", 7 }, { "007", 7 }, { 7, 7 }, { 7.0, 7 } }
			for _, case in ipairs(cases) do
				local r = settled()
				r.a:reading({ GROUP = "123", LEVEL = case[1] })
				assert.are.equal(case[2], r.a:debug().level, "LEVEL " .. tostring(case[1]))
			end
		end)

		it("ignores parameters that are not a table", function()
			local r = settled()
			r.a:reading(nil)
			r.a:reading("LEVEL=3")
			assert.are.equal("unknown", r.a:state())
			assert.is_true(r.log.has("debug", "reading ignored: the parameters are not a table"))
		end)
	end)

	describe("bind and unbind (AP-D4)", function()
		it("an unbind while dark makes the state unknown, cancels the hold and resumes", function()
			local r = settled()
			read(r, 3)
			read(r, 14)
			changes(r)
			local hold = live(r)[1]
			r.a:bound(nil)
			assert.are.equal("unknown", r.a:state())
			assert.is_false(r.a:dark())
			assert.is_true(hold.cancelled)
			assert.are.same({ { false, "unbound" } }, changes(r))
			advance(r, 60000)
			assert.are.same({}, r.changes)
			assert.are.equal("unknown", r.a:state())
		end)

		it("an unbind while lit makes the state unknown with no on_change", function()
			local r = settled()
			read(r, 40)
			r.a:bound(nil)
			assert.are.equal("unknown", r.a:state())
			assert.are.same({}, r.changes)
		end)

		it("forgets the last reading: a threshold change after an unbind changes nothing", function()
			local r = settled()
			read(r, 14)
			r.a:bound(nil)
			r.a:set_threshold(20)
			assert.are.equal("unknown", r.a:state())
			assert.is_nil(r.a:debug().level)
			assert.are.same({}, r.changes)
		end)

		it("a bind to another keypad while dark makes the state unknown and checks the new GROUP", function()
			local r = settled()
			read(r, 3)
			changes(r)
			r.a:bound(OTHER)
			assert.are.equal("unknown", r.a:state())
			assert.are.same({ { false, "bound" } }, changes(r))
			advance(r, 6000)
			read(r, 3, KEYPAD)
			assert.are.equal("unknown", r.a:state())
			read(r, 3, OTHER)
			assert.is_true(r.a:dark())
		end)
	end)

	describe("stop()", function()
		it("cancels the hold, and nothing happens afterwards", function()
			local r = settled()
			read(r, 3)
			read(r, 14)
			changes(r)
			local hold = live(r)[1]
			r.a:stop()
			assert.is_true(hold.cancelled)
			hold.cb()
			read(r, 2)
			read(r, 40)
			r.a:set_threshold(0)
			r.a:bound(nil)
			r.a:bound(OTHER)
			advance(r, 60000)
			assert.are.same({}, r.changes)
			assert.are.equal(1, #r.timers)
			assert.are.equal("dark", r.a:state())
			assert.is_false(r.a:debug().hold)
			r.a:stop()
		end)
	end)

	describe("on_change", function()
		it("is called in pcall: a failure is logged at warn and the state still changes", function()
			local r = settled()
			r.raise = true
			read(r, 3)
			assert.is_true(r.a:dark())
			assert.is_true(r.log.has("warn", "on_change(true) failed"))
			read(r, 14)
			advance(r, HOLD_MS)
			assert.is_false(r.a:dark())
			assert.is_true(r.log.has("warn", "on_change(false) failed"))
			assert.are.equal(2, #r.changes)
		end)

		it("may be left out", function()
			local r = settled({ no_on_change = true })
			read(r, 3)
			assert.is_true(r.a:dark())
			assert.are.equal(0, r.log.count("warn"))
		end)
	end)

	describe("debug()", function()
		it("reports the state, the last counted reading, the threshold, the bind and the hold", function()
			local r = rig()
			assert.are.same({ state = "unknown", threshold = 10, hold = false }, r.a:debug())
			r.a:bound(KEYPAD)
			advance(r, 6000)
			assert.are.same({ state = "unknown", threshold = 10, bound = KEYPAD, since_bind_ms = 6000, hold = false },
				r.a:debug())
			read(r, 3)
			read(r, 14)
			advance(r, 1500)
			assert.are.same({ state = "dark", level = 14, threshold = 10, bound = KEYPAD, since_bind_ms = 7500,
				hold = true }, r.a:debug())
			advance(r, HOLD_MS)
			assert.are.same({ state = "lit", level = 14, threshold = 10, bound = KEYPAD, since_bind_ms = 17500,
				hold = false }, r.a:debug())
			r.a:bound(nil)
			assert.are.same({ state = "unknown", threshold = 10, hold = false }, r.a:debug())
		end)

		it("has no since_bind_ms without a clock, or while the clock fails", function()
			local r = rig({ no_clock = true })
			r.a:bound(KEYPAD)
			assert.is_nil(r.a:debug().since_bind_ms)
			local s = rig()
			s.a:bound(KEYPAD)
			s.fail_clock = true
			assert.is_nil(s.a:debug().since_bind_ms)
			assert.is_true(s.log.has("warn", "the clock failed"))
		end)
	end)

	describe("logging", function()
		it("logs each counted reading, each ignored one with its reason, and each state change at debug", function()
			local r = settled()
			read(r, 3)
			read(r, 14)
			advance(r, HOLD_MS)
			local l = r.log
			assert.is_true(l.has("debug", "Ambient light: bound to device 123"))
			assert.is_true(l.has("debug", "Ambient light: reading 3 counted (threshold 10, state unknown)"))
			assert.is_true(l.has("debug", "Ambient light: keypad dark (reading 3 < 10)"))
			assert.is_true(l.has("debug", "Ambient light: reading 14 >= 10: lit again in 10 s"))
			assert.is_true(l.has("debug", "Ambient light: keypad lit again (reading 14 >= 10, held 10 s)"))
			assert.are.equal(0, l.count("warn"))
			r.a:bound(nil)
			assert.is_true(l.has("debug", "Ambient light: unbound"))
		end)

		it("logs the cancelled hold", function()
			local r = settled()
			read(r, 3)
			read(r, 14)
			read(r, 5)
			assert.is_true(r.log.has("debug", "Ambient light: the resume hold is cancelled (reading 5 < 10)"))
		end)

		it("uses common.log by default", function()
			local log = require("common.log")
			local sink = log.sink
			local lines = {}
			log.sink = function(line)
				lines[#lines + 1] = line
			end
			log.set_debug(true)
			local ok, err = pcall(function()
				local a = ambient.new({})
				a:reading({ LEVEL = "3" })
				assert.is_true(a:dark())
			end)
			log.set_debug(false)
			log.sink = sink
			assert(ok, err)
			local found = false
			for _, line in ipairs(lines) do
				found = found or line:find("keypad dark (reading 3 < 10)", 1, true) ~= nil
			end
			assert.is_true(found)
		end)
	end)
end)
