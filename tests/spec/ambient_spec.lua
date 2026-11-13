-- fan.ambient on fakes: whether the bound keypad's LEDs are dark, from its AMBIENT_LIGHT_LEVEL readings (#207,
-- docs/ambient-pause-design.md: AP1 to AP5, AP-D2 to AP-D5, the lapse of section 1a (#223, AP-D16 to AP-D18) and
-- the interfaces of sections 1a and 2). The timer records its ms and callback; advance() moves the fake clock and
-- fires every timer that falls due on the way. on_change is recorded in r.changes as { dark, why }.
--
-- The two timers share the one timer option, so the fake files them apart by their length: one of LAPSE_MIN_MS or
-- more is a lapse (r.lapses, lapses(r)), since the module clamps every lapse to at least that, and any other is a
-- hold (r.timers, live(r)), which is LIT_HOLD_MS; the hold's specs read as they did before #223. lapse_ms gives
-- r.lapse (nil: the default 12 h), raises while r.fail_lapse and counts its calls in r.lapse_calls; epoch follows
-- the fake clock, EPOCH0 + its whole seconds, and raises while r.fail_epoch.
--
-- Unless a spec says otherwise: the keypad is device 123, bound and settled (bound, then 6 s, so the first
-- reading counts, at clock 7000 ms: epoch EPOCH0 + 7), the threshold is the default 10.

local ambient = require("fan.ambient")

local KEYPAD = 123
local OTHER = 456
local HOLD_MS = 10000
local SETTLE_MS = 5000
local LAPSE_DEFAULT_MS = 43200000
local LAPSE_MIN_MS = 60000
local LAPSE_MAX_MS = 86400000
local EPOCH0 = 1763000000

local function fake_log()
	local l = { lines = {} }
	for _, level in ipairs({ "error", "warn", "info", "debug", "always" }) do
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

-- The module on fakes. opts: no_clock (no `now`), no_timer (no `timer`), no_on_change, no_lapse_ms (no
-- `lapse_ms`), no_epoch (no `epoch`: os.time).
local function rig(opts)
	opts = opts or {}
	local r = { clock = 1000, timers = {}, lapses = {}, changes = {}, log = fake_log(), lapse_calls = 0 }
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
			local list = ms >= LAPSE_MIN_MS and r.lapses or r.timers
			list[#list + 1] = t
			return t
		end or nil,
		on_change = not opts.no_on_change and function(dark, why)
			r.changes[#r.changes + 1] = { dark, why }
			if r.raise then
				error("on_change refused")
			end
		end or nil,
		lapse_ms = not opts.no_lapse_ms and function()
			r.lapse_calls = r.lapse_calls + 1
			if r.fail_lapse then
				error("no sunrise")
			end
			return r.lapse
		end or nil,
		epoch = not opts.no_epoch and function()
			if r.fail_epoch then
				error("no epoch")
			end
			return EPOCH0 + math.floor(r.clock / 1000)
		end or nil,
		log = r.log,
	})
	return r
end

-- The timers of a list neither cancelled nor fired.
local function pending(list)
	local out = {}
	for _, t in ipairs(list) do
		if not t.cancelled and not t.fired then
			out[#out + 1] = t
		end
	end
	return out
end

-- The holds neither cancelled nor fired.
local function live(r)
	return pending(r.timers)
end

-- The lapses neither cancelled nor fired.
local function lapses(r)
	return pending(r.lapses)
end

-- Moves the clock by ms, firing every live timer (holds and lapses) that falls due on the way, in order, at its
-- time.
local function advance(r, ms)
	local target = r.clock + ms
	while true do
		local due
		for _, list in ipairs({ r.timers, r.lapses }) do
			for _, t in ipairs(pending(list)) do
				if t.at + t.ms <= target and (due == nil or t.at + t.ms < due.at + due.ms) then
					due = t
				end
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
			assert.is_true(r.log.has("always", "reading ignored: 0 is the first after the bind (200 ms after it)"))
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
			assert.is_true(r.log.has("always", "reading ignored: 3 from device 456, not the bound device 123"))
			read(r, 3, " 123 ")
			assert.are.equal("dark", r.a:state())
		end)

		-- #214 (S2-4): once the bound keypad's id is known, a reading must name it; one with no GROUP is ignored
		-- as one from another device is.
		it("ignores a reading with no GROUP once a keypad is bound with a known id", function()
			local r = settled()
			r.a:reading({ LEVEL = "3" })
			assert.are.equal("unknown", r.a:state())
			assert.is_true(r.log.has("always", "reading ignored: 3 with no GROUP, while bound to device 123"))
			for _, none in ipairs({ "", "   ", {}, true, 0 / 0, math.huge }) do
				r.a:reading({ LEVEL = "3", GROUP = none })
				assert.are.equal("unknown", r.a:state(), "GROUP " .. tostring(none))
			end
			assert.are.same({}, r.changes)
			read(r, 3, KEYPAD)
			assert.is_true(r.a:dark(), "the bound keypad's own reading still counts")
		end)

		it("does not use the skip up on a reading with no GROUP", function()
			local r = rig()
			r.a:bound(KEYPAD)
			r.a:reading({ LEVEL = "2" })
			read(r, 0)
			assert.are.equal("unknown", r.a:state(), "the bind's artifact is still the one skipped")
			read(r, 4)
			assert.are.equal("dark", r.a:state())
		end)

		it("does not check GROUP after a bind with no usable id", function()
			local r = rig()
			r.a:bound("")
			advance(r, 6000)
			read(r, 3, OTHER)
			assert.is_true(r.a:dark())
			r = rig()
			r.a:bound("")
			advance(r, 6000)
			r.a:reading({ LEVEL = "3" })
			assert.is_true(r.a:dark(), "no id known: a reading with no GROUP counts, as before")
		end)

		it("counts a reading while unbound, from any device, with nothing skipped", function()
			local r = rig()
			read(r, 3, OTHER)
			assert.is_true(r.a:dark())
			read(r, 20, KEYPAD)
			assert.are.equal(1, #live(r))
			assert.is_nil(r.a:debug().bound)
		end)

		it("counts a reading with no GROUP while unbound, and after an unbind", function()
			local r = rig()
			r.a:reading({ LEVEL = "3" })
			assert.is_true(r.a:dark())
			r = settled()
			r.a:bound(nil)
			r.a:reading({ LEVEL = "3" })
			assert.is_true(r.a:dark())
		end)

		-- #214 (S2-2): GROUP is whatever the sender writes; no device id is longer than 32 characters, so a longer
		-- one is refused before anything reads it, and the trim of a shorter one is linear.
		it("refuses a GROUP longer than 32 characters, bound or not, and handles 32 KB of it at once", function()
			assert.are.equal(32, ambient.MAX_ID_CHARS)
			local long = "1" .. string.rep(" ", 32 * 1024) .. "2"
			for _, r in ipairs({ settled(), rig() }) do
				local started = os.clock()
				for _ = 1, 10 do
					r.a:reading({ LEVEL = "3", GROUP = long })
				end
				assert.is_true(os.clock() - started < 0.05, "took " .. (os.clock() - started) .. " s for 10 readings")
				assert.are.equal("unknown", r.a:state())
				assert.is_true(r.log.has("always", "reading ignored: 3 with a GROUP of 32770 characters, no device id"))
			end
			local r = settled()
			r.a:reading({ LEVEL = "3", GROUP = string.rep(" ", 29) .. "123" })
			assert.is_true(r.a:dark(), "32 characters with the blanks: the bound keypad")
			r = settled()
			r.a:reading({ LEVEL = "3", GROUP = string.rep(" ", 30) .. "123" })
			assert.are.equal("unknown", r.a:state(), "33 characters: refused")
		end)

		it("takes a bound id longer than 32 characters as unknown, so GROUP is not checked", function()
			local r = rig()
			r.a:bound(string.rep("7", 33))
			advance(r, 6000)
			read(r, 3, OTHER)
			assert.is_true(r.a:dark())
		end)

		-- #214 (S2-7): what another driver sends reaches the log short and on one line.
		it("logs a GROUP short, on one line, with its control characters written out", function()
			local r = settled()
			r.a:reading({ LEVEL = "3", GROUP = "4\n[ERROR] forged\0" })
			local found
			for _, line in ipairs(r.log.lines) do
				if line.text:find("reading ignored: 3 from device", 1, true) then
					found = line.text
				end
			end
			assert.is_truthy(found)
			assert.is_nil(found:find("%c"), found)
			assert.is_truthy(found:find("4\\10[ERROR] forged\\0", 1, true), found)
			r.a:reading({ GROUP = "123", LEVEL = string.rep("x\n", 5000) })
			for _, line in ipairs(r.log.lines) do
				assert.is_nil(line.text:find("%c"), line.text)
				assert.is_true(#line.text <= 120, line.text)
			end
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
			assert.is_true(r.log.has("always", 'reading ignored: LEVEL "3.5" is not a whole number 0 to 255'))
			assert.is_true(r.log.has("always", "reading ignored: LEVEL 3.5 is not a whole number 0 to 255"))
			assert.is_true(r.log.has("always", "reading ignored: LEVEL nil is not a whole number 0 to 255"))
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
			assert.is_true(r.log.has("always", "reading ignored: the parameters are not a table"))
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
		it("reports the state, the last counted reading, the threshold, the bind, the hold and the lapse", function()
			local r = rig()
			assert.are.same({ state = "unknown", threshold = 10, hold = false, lapse = false }, r.a:debug())
			r.a:bound(KEYPAD)
			advance(r, 6000)
			assert.are.same({ state = "unknown", threshold = 10, bound = KEYPAD, since_bind_ms = 6000, hold = false,
				lapse = false }, r.a:debug())
			read(r, 3)
			read(r, 14)
			advance(r, 1500)
			assert.are.same({ state = "dark", level = 14, threshold = 10, bound = KEYPAD, since_bind_ms = 7500,
				hold = true, last_level = 14, last_at_s = EPOCH0 + 7, lapse = true }, r.a:debug())
			advance(r, HOLD_MS)
			assert.are.same({ state = "lit", level = 14, threshold = 10, bound = KEYPAD, since_bind_ms = 17500,
				hold = false, last_level = 14, last_at_s = EPOCH0 + 7, lapse = false }, r.a:debug())
			r.a:bound(nil)
			assert.are.same({ state = "unknown", threshold = 10, hold = false, lapse = false }, r.a:debug())
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
			assert.is_true(l.has("always", "Ambient light: keypad dark (reading 3 < 10)"))
			assert.is_true(l.has("debug", "Ambient light: reading 14 >= 10: lit again in 10 s"))
			assert.is_true(l.has("always", "Ambient light: keypad lit again (reading 14 >= 10, held 10 s)"))
			-- #223: every message the keypad sends is logged whatever Debug Mode says, with its raw values.
			assert.is_true(l.has("always", "Ambient light: the keypad sent LEVEL 3 GROUP 123 TARGET 1 (state unknown)"))
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

	-- #223, found on the house: after a dark reading at night no bright reading reached the driver in the morning,
	-- and the chase stayed paused in a bright room until the binding was reconnected. AP-D16: the dark verdict
	-- lapses; AP-D17: last(); AP-D18: nothing else changes (every spec above).
	describe("#223 the dark verdict lapses", function()
		-- The one lapse armed now.
		local function lapse(r)
			local got = lapses(r)
			assert.are.equal(1, #got, "one lapse armed")
			return got[1]
		end

		local function lapsed_since(at_s)
			return "the dark verdict lapsed (no reading since " .. os.date("%H:%M", at_s) .. ")"
		end

		it("has the contract's constants", function()
			assert.are.equal(LAPSE_DEFAULT_MS, ambient.LAPSE_DEFAULT_MS)
			assert.are.equal(LAPSE_MIN_MS, ambient.LAPSE_MIN_MS)
			assert.are.equal(LAPSE_MAX_MS, ambient.LAPSE_MAX_MS)
		end)

		it("arms the lapse on a dark reading, and none on a lit one", function()
			local r = settled()
			read(r, 40)
			assert.are.same({}, r.lapses)
			assert.are.equal(0, r.lapse_calls)
			read(r, 3)
			assert.are.equal(LAPSE_DEFAULT_MS, lapse(r).ms)
			assert.are.equal(1, r.lapse_calls)
			assert.is_true(r.a:debug().lapse)
			assert.is_true(r.log.has("debug", "Ambient light: the dark verdict lapses in 12 h"))
		end)

		it("goes from dark to unknown when it fires, with one on_change(false)", function()
			local r = settled()
			read(r, 3)
			changes(r)
			advance(r, LAPSE_DEFAULT_MS - 1)
			assert.is_true(r.a:dark())
			assert.are.same({}, r.changes)
			advance(r, 1)
			assert.are.equal("unknown", r.a:state())
			assert.is_false(r.a:dark())
			assert.is_nil(r.a:debug().level)
			assert.are.same({ { false, lapsed_since(EPOCH0 + 7) } }, changes(r))
			assert.are.same({}, lapses(r))
			assert.is_true(r.log.has("always", "Ambient light: " .. lapsed_since(EPOCH0 + 7)
				.. ": the keypad state is unknown, the animations run"))
			advance(r, 2 * LAPSE_MAX_MS)
			assert.are.same({}, r.changes)
			assert.are.equal("unknown", r.a:state())
		end)

		it("cancels a lit hold when it fires first", function()
			local r = settled()
			r.lapse = LAPSE_MIN_MS
			read(r, 3)
			changes(r)
			advance(r, 55000)
			read(r, 14)
			local hold = live(r)[1]
			advance(r, 5000)
			assert.are.equal("unknown", r.a:state())
			assert.is_true(hold.cancelled)
			assert.are.same({ { false, lapsed_since(EPOCH0 + 62) } }, changes(r))
			assert.is_true(r.log.has("debug", "the resume hold is cancelled (the dark verdict lapsed)"))
			hold.cb() -- a cancelled hold that fires anyway changes nothing
			advance(r, HOLD_MS)
			assert.are.equal("unknown", r.a:state())
			assert.are.same({}, r.changes)
		end)

		it("arms again with a fresh lapse_ms() at every dark reading while dark", function()
			local r = settled()
			r.lapse = 3600000
			read(r, 3)
			local first = lapse(r)
			assert.are.equal(3600000, first.ms)
			advance(r, 1800000)
			r.lapse = 7200000
			read(r, 5)
			assert.is_true(first.cancelled)
			assert.are.equal(7200000, lapse(r).ms)
			assert.are.equal(2, r.lapse_calls)
			first.cb() -- a cancelled lapse that fires anyway changes nothing
			advance(r, 1800000)
			assert.is_true(r.a:dark(), "past the first lapse's time")
			advance(r, 7200000 - 1800000 - 1)
			assert.is_true(r.a:dark())
			advance(r, 1)
			assert.are.equal("unknown", r.a:state())
			local got = changes(r)
			assert.are.equal(2, #got)
			assert.are.same({ false, lapsed_since(EPOCH0 + 7 + 1800) }, got[2])
		end)

		it("arms when a threshold change makes the state dark, and runs on when one keeps it dark", function()
			local r = settled()
			read(r, 14)
			r.a:set_threshold(20)
			assert.is_true(r.a:dark())
			local armed = lapse(r)
			r.a:set_threshold(30)
			assert.is_false(armed.cancelled)
			assert.are.equal(1, r.lapse_calls)
			advance(r, LAPSE_DEFAULT_MS)
			assert.are.equal("unknown", r.a:state())
		end)

		it("is cancelled when the hold resumes after a lit reading", function()
			local r = settled()
			read(r, 3)
			local armed = lapse(r)
			read(r, 14)
			assert.is_false(armed.cancelled, "a lit reading alone leaves it running")
			advance(r, HOLD_MS)
			assert.are.equal("lit", r.a:state())
			assert.is_true(armed.cancelled)
			assert.is_false(r.a:debug().lapse)
			changes(r)
			armed.cb()
			advance(r, LAPSE_MAX_MS)
			assert.are.same({}, r.changes)
			assert.are.equal("lit", r.a:state())
		end)

		it("is cancelled when a lower threshold resumes through the hold, or at once with no hold", function()
			local r = settled()
			read(r, 6)
			local armed = lapse(r)
			r.a:set_threshold(6)
			assert.is_false(armed.cancelled, "still dark during the hold")
			advance(r, HOLD_MS)
			assert.are.equal("lit", r.a:state())
			assert.is_true(armed.cancelled)
			r = settled()
			read(r, 3)
			armed = lapse(r)
			r.fail_timer = true
			read(r, 14)
			assert.are.equal("lit", r.a:state())
			assert.is_true(armed.cancelled)
		end)

		it("is cancelled by an unbind and by a bind", function()
			for _, case in ipairs({ { nil, "unbound" }, { OTHER, "bound" }, { KEYPAD, "bound" } }) do
				local r = settled()
				read(r, 3)
				local armed = lapse(r)
				changes(r)
				r.a:bound(case[1])
				assert.is_true(armed.cancelled, case[2])
				assert.are.same({ { false, case[2] } }, changes(r))
				advance(r, LAPSE_MAX_MS)
				assert.are.same({}, r.changes)
				assert.are.equal("unknown", r.a:state())
			end
		end)

		it("is cancelled by stop(), and a late callback changes nothing", function()
			local r = settled()
			read(r, 3)
			local armed = lapse(r)
			changes(r)
			r.a:stop()
			assert.is_true(armed.cancelled)
			assert.is_false(r.a:debug().lapse)
			armed.cb()
			advance(r, LAPSE_MAX_MS)
			assert.are.equal("dark", r.a:state())
			assert.are.same({}, r.changes)
		end)

		it("takes lapse_ms() rounded and clamped to 1 min through 24 h, and 12 h for anything not a number", function()
			local cases = {
				{ nil, LAPSE_DEFAULT_MS }, { 0 / 0, LAPSE_DEFAULT_MS }, { math.huge, LAPSE_DEFAULT_MS },
				{ -math.huge, LAPSE_DEFAULT_MS }, { "90000", LAPSE_DEFAULT_MS }, { true, LAPSE_DEFAULT_MS },
				{ {}, LAPSE_DEFAULT_MS }, { -5, LAPSE_MIN_MS }, { 0, LAPSE_MIN_MS }, { 59999, LAPSE_MIN_MS },
				{ LAPSE_MIN_MS, LAPSE_MIN_MS }, { 5400000.4, 5400000 }, { 5400000.5, 5400001 },
				{ LAPSE_MAX_MS, LAPSE_MAX_MS }, { LAPSE_MAX_MS + 1, LAPSE_MAX_MS }, { 1e12, LAPSE_MAX_MS },
			}
			for _, case in ipairs(cases) do
				local r = settled()
				r.lapse = case[1]
				read(r, 3)
				assert.are.equal(case[2], lapse(r).ms, "lapse_ms() -> " .. tostring(case[1]))
				assert.are.equal(0, r.log.count("warn"))
			end
			local r = settled({ no_lapse_ms = true })
			read(r, 3)
			assert.are.equal(LAPSE_DEFAULT_MS, lapse(r).ms, "no lapse_ms")
			assert.are.equal(0, r.log.count("warn"))
		end)

		it("takes 12 h, with a warning, when lapse_ms raises", function()
			local r = settled()
			r.fail_lapse = true
			read(r, 3)
			assert.is_true(r.a:dark())
			assert.are.equal(LAPSE_DEFAULT_MS, lapse(r).ms)
			assert.is_true(r.log.has("warn", "lapse_ms failed, the default 12 h applies: "))
			assert.are.equal(1, #r.changes)
		end)

		it("stays dark, with a warning, when the lapse cannot be armed", function()
			local r = settled()
			r.fail_timer = true
			read(r, 3)
			assert.is_true(r.a:dark())
			assert.is_false(r.a:debug().lapse)
			assert.is_true(r.log.has("warn", "the lapse timer could not be armed (43200000 ms)"))
			r.fail_timer = false
			read(r, 4)
			assert.are.equal(1, #lapses(r), "the next dark reading arms it")
		end)

		it("decides as from unknown after a lapse: dark goes dark again, lit goes lit with no on_change", function()
			local r = settled()
			read(r, 3)
			advance(r, LAPSE_DEFAULT_MS)
			changes(r)
			read(r, 4)
			assert.is_true(r.a:dark())
			assert.are.same({ { true, "keypad dark (reading 4 < 10)" } }, changes(r))
			assert.are.equal(1, #lapses(r), "armed again")
			r = settled()
			read(r, 3)
			advance(r, LAPSE_DEFAULT_MS)
			changes(r)
			read(r, 40)
			assert.are.equal("lit", r.a:state())
			assert.are.same({}, r.changes)
			assert.are.same({}, live(r))
			assert.are.same({}, lapses(r))
		end)

		it("keeps the last counted reading and its time in last(): through a lapse, not through a bind", function()
			local r = rig()
			assert.are.same({}, { r.a:last() })
			r.a:bound(KEYPAD)
			advance(r, 200)
			read(r, 0) -- the bind's artifact is no reading
			assert.are.same({}, { r.a:last() })
			advance(r, 5800)
			read(r, 3)
			assert.are.same({ 3, EPOCH0 + 7 }, { r.a:last() })
			advance(r, 4000)
			read(r, 5, OTHER) -- ignored
			read(r, 5)
			assert.are.same({ 5, EPOCH0 + 11 }, { r.a:last() })
			advance(r, LAPSE_DEFAULT_MS)
			assert.are.equal("unknown", r.a:state())
			assert.is_nil(r.a:debug().level)
			assert.are.same({ 5, EPOCH0 + 11 }, { r.a:last() }, "a lapse keeps it")
			r.a:bound(KEYPAD)
			assert.are.same({}, { r.a:last() }, "a bind clears it")
			r = settled()
			read(r, 3)
			r.a:bound(nil)
			assert.are.same({}, { r.a:last() }, "an unbind clears it")
			r.a:stop()
			assert.are.same({}, { r.a:last() }, "it still answers after stop()")
		end)

		it("has no time in last() when epoch fails, and the lapse then says how long it waited", function()
			local r = settled()
			r.fail_epoch = true
			read(r, 3)
			local level, at_s = r.a:last()
			assert.are.equal(3, level)
			assert.is_nil(at_s)
			assert.is_true(r.log.has("warn", "the epoch clock failed"))
			changes(r)
			advance(r, LAPSE_DEFAULT_MS)
			assert.are.same({ { false, "the dark verdict lapsed (no reading for 12 h)" } }, changes(r))
			r = settled()
			r.fail_epoch, r.lapse = true, 5400000
			read(r, 3)
			changes(r)
			advance(r, 5400000)
			assert.are.same({ { false, "the dark verdict lapsed (no reading for 90 min)" } }, changes(r))
		end)

		it("takes epoch as a whole second, os.time by default, and nil for one that is not a number", function()
			local r = settled({ no_epoch = true })
			local before = os.time()
			read(r, 3)
			local _, at_s = r.a:last()
			assert.is_true(at_s >= before and at_s <= os.time(), tostring(at_s))
			for _, case in ipairs({ { 1763000000.9, 1763000000 }, { "1763000000", nil }, { 0 / 0, nil } }) do
				local a = ambient.new({ epoch = function() return case[1] end, log = fake_log() })
				a:reading({ LEVEL = "40" })
				assert.are.same({ 40, case[2] }, { a:last() }, "epoch() -> " .. tostring(case[1]))
			end
		end)

		it("reports last_level, last_at_s and lapse in debug()", function()
			local r = settled()
			local d = r.a:debug()
			assert.is_nil(d.last_level)
			assert.is_nil(d.last_at_s)
			assert.is_false(d.lapse)
			read(r, 3)
			d = r.a:debug()
			assert.are.same({ 3, EPOCH0 + 7, true }, { d.last_level, d.last_at_s, d.lapse })
			advance(r, LAPSE_DEFAULT_MS)
			assert.are.same({ state = "unknown", threshold = 10, bound = KEYPAD, since_bind_ms = 6000 + LAPSE_DEFAULT_MS,
				hold = false, last_level = 3, last_at_s = EPOCH0 + 7, lapse = false }, r.a:debug())
		end)
	end)
end)
