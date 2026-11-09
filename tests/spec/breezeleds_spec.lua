-- fan.breezeleds on fakes: Breeze on the keypad LEDs (#137, docs/breeze-leds-design.md section 1 as revised by
-- section 1a, BL-D19 to BL-D26, and the interfaces of sections 3.1 and 1a). The paint, light and settle calls
-- are recorded in order and replayed on a keypad that behaves as the house keypad was measured to (#137,
-- 2026-11-09): a colour loaded while dark stays dark, MATCH_LED_STATE shows the loaded colour or dark, and a
-- BUTTON_COLORS with CURRENT_COLOR repaints a lit button. The timer records its ms and callback and the spec
-- fires the callbacks by hand on a fake clock; random is scripted.
--
-- What the keypad shows is written one letter a pixel, pixel 1 (the bottom) first: "W" white (HEAD), "i", "t",
-- "s" the sparks ice, teal and sky (SKY is also GLINT), "." dark, "~" settled, "?" unknown.
--
-- Unless a spec says otherwise the random answers the low end of every range, and 100 to random(1, 100) (no
-- double gust, no glint); the step is 125 ms, so the front step is drawn at 100 ms and the front moves every
-- second tick: it reaches pixel i at tick 2i and leaves it at tick 2i + 2. A Breeze 2 tail is then 500 ms, ten
-- ticks: lit 2, dark 2, lit 3, dark 3.

local breezeleds = require("fan.breezeleds")
local log = require("common.log")

local REAL_SINK = log.sink
local SHIPPED_RECOLOUR = breezeleds.RECOLOUR_NEEDS_STATE

local HEAD, GLINT, SPARKS = breezeleds.HEAD, breezeleds.GLINT, breezeleds.SPARKS
local ICE, TEAL, SKY = SPARKS[1], SPARKS[2], SPARKS[3]
local LETTER = { [HEAD] = "W", [ICE] = "i", [TEAL] = "t", [SKY] = "s" }

local HOUSE = { 302, 303, 304, 305 } -- Low, Medium, Med-High, High (BL-D2)
local LISTS = { [1] = { 303 }, [2] = { 302, 303 }, [4] = HOUSE, [6] = { 301, 302, 303, 304, 305, 306 } }
local STEP = 125 -- drawn at its low end, 100 ms

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
	return l
end

-- The default script: the low end of every range, 100 to the percent draws.
local function low(lo, hi)
	if lo == 1 and hi == 100 then
		return 100
	end
	return lo
end

-- A seeded random (Park and Miller): the same numbers for the same seed.
local function seeded(seed)
	local state = seed
	return function(lo, hi)
		state = (state * 16807) % 2147483647
		return lo + state % (hi - lo + 1)
	end
end

-- The module on fakes. r.calls: { "paint", link, colour, with_state, preload }, { "light", link, lit } and
-- { "settle", link } in order; r.stamps: the clock of every message (a paint 1, 2 with the state; a light 1; a
-- settle 2); r.kp: the keypad; r.timers: every arm, { ms, cb, at, cancelled, fired }; r.randoms: every random's
-- { lo, hi }. opts: no_clock (no `now` option), no_log (the default log), no_light (no `light` option).
local function rig(opts)
	opts = opts or {}
	local r = { calls = {}, stamps = {}, timers = {}, randoms = {}, clock = 1000, log = fake_log(), kp = {} }
	local function count(n)
		for _ = 1, n do
			r.stamps[#r.stamps + 1] = r.clock
		end
	end
	local function pad(link)
		local k = r.kp[link]
		if k == nil or k.settled then
			k = {}
			r.kp[link] = k
		end
		return k
	end
	r.b = breezeleds.new({
		paint = function(link, colour, with_state, preload)
			r.calls[#r.calls + 1] = { "paint", link, colour, with_state, preload }
			count(with_state and 2 or 1)
			if r.fail_paint and r.fail_paint(link, colour) then
				error("paint refused")
			end
			local k = pad(link)
			k.loaded = colour
			if with_state then
				k.lit = true
			end
			if k.lit and (with_state or not preload) then
				k.current = colour
			end
		end,
		light = not opts.no_light and function(link, lit)
			r.calls[#r.calls + 1] = { "light", link, lit }
			count(1)
			if r.fail_light and r.fail_light(link, lit) then
				error("light refused")
			end
			local k = pad(link)
			k.lit = lit
			k.current = lit and k.loaded or nil
		end or nil,
		settle = function(link)
			r.calls[#r.calls + 1] = { "settle", link }
			count(2)
			if r.fail_settle and r.fail_settle(link) then
				error("settle refused")
			end
			r.kp[link] = { settled = true }
		end,
		timer = function(ms, cb)
			if r.fail_timer then
				error("no timer")
			end
			local t = { ms = ms, cb = cb, at = r.clock, cancelled = false, fired = false }
			function t:Cancel()
				self.cancelled = true
			end
			r.timers[#r.timers + 1] = t
			return t
		end,
		random = function(lo, hi)
			r.randoms[#r.randoms + 1] = { lo, hi }
			if r.fail_random then
				error("no random")
			end
			return (r.pick or low)(lo, hi)
		end,
		now = not opts.no_clock and function()
			if r.fail_clock then
				error("no clock")
			end
			return r.clock
		end or nil,
		log = not opts.no_log and r.log or nil,
	})
	return r
end

local function take(r)
	local calls = r.calls
	r.calls = {}
	return calls
end

-- The timers neither cancelled nor fired: one at a time (BL-D13).
local function live(r)
	local out = {}
	for _, t in ipairs(r.timers) do
		if not t.cancelled and not t.fired then
			out[#out + 1] = t
		end
	end
	return out
end

local function pending(r)
	local l = live(r)
	assert.is_true(#l <= 1, "one timer at a time")
	return l[1]
end

-- Fires the pending timer when it falls due, or `late` ms after, and returns the calls it made.
local function tick(r, late)
	local t = pending(r)
	assert.is_not_nil(t, "a timer is pending")
	t.fired = true
	r.clock = t.at + t.ms + (late or 0)
	r.calls = {}
	t.cb()
	return take(r)
end

local function ticks(r, n)
	for _ = 1, n do
		tick(r)
	end
end

-- What the keypad shows on the pixels of `order`, one letter each.
local function look(r, order)
	local out = {}
	for i, link in ipairs(order) do
		local k = r.kp[link]
		if k == nil or k.lit == nil then
			out[i] = k and k.settled and "~" or "?"
		elseif k.lit then
			out[i] = LETTER[k.current] or "?"
		else
			out[i] = "."
		end
	end
	return table.concat(out)
end

-- The ticks of a gust until its rest: what the keypad shows after each (looks[n] after tick n) and every call.
local function run_gust(r, order, cap)
	local looks, calls = {}, {}
	for n = 1, cap or 400 do
		for _, call in ipairs(tick(r)) do
			calls[#calls + 1] = call
		end
		if r.b:debug().phase ~= "gust" then
			return looks, calls
		end
		looks[n] = look(r, order)
	end
	error("the gust never ended")
end

-- The most messages in any one second.
local function max_window(stamps)
	local most, first = 0, 1
	for last = 1, #stamps do
		while stamps[last] - stamps[first] >= 1000 do
			first = first + 1
		end
		if last - first + 1 > most then
			most = last - first + 1
		end
	end
	return most
end

-- Where the fronts are now, from the gust debug() shows: one pixel per front step (BL-D21).
local function fronts_now(r)
	local g, at = r.b:debug().gust, {}
	if g == nil then
		return at
	end
	for f = 1, 2 do
		local x = g.offsets[f] ~= nil and g.tick * breezeleds.TICK_MS - g.offsets[f] or -1
		if x >= 0 then
			at[math.floor(x / g.step)] = true
		end
	end
	return at
end

local function reversed(list)
	local out = {}
	for i = #list, 1, -1 do
		out[#out + 1] = list[i]
	end
	return out
end

local function shuffled(list)
	local out = reversed(list)
	out[#out + 1] = list[1] -- a duplicate
	return out
end

-- Configured, bound and blowing: the calls of the start are returned.
local function start(r, list, bottom, strength)
	r.b:configure({ enabled = true, per_speed = true, bottom = bottom or 1, step = STEP })
	r.b:set_pixels(list or HOUSE)
	r.b:update({ breeze = true, strength = strength or 2, online = true })
	return take(r)
end

-- Through the first gust to its rest.
local function to_rest(r, list, bottom, strength)
	start(r, list, bottom, strength)
	run_gust(r, bottom == 6 and reversed(list or HOUSE) or list or HOUSE)
	assert.equal("rest", r.b:debug().phase)
	take(r)
end

local function held_list(r, list)
	local out = {}
	for _, link in ipairs(list) do
		out[#out + 1] = r.b:held(link)
	end
	return out
end

local function darks(list)
	local out = {}
	for _, link in ipairs(list) do
		out[#out + 1] = { "light", link, false }
	end
	return out
end

local function settles(list)
	local out = {}
	for _, link in ipairs(list) do
		out[#out + 1] = { "settle", link }
	end
	return out
end

-- The calls to one link.
local function calls_to(calls, link)
	local out = {}
	for _, call in ipairs(calls) do
		if call[2] == link then
			out[#out + 1] = call
		end
	end
	return out
end

-- The house's first gust at Breeze 2, as the defaults draw it (worked out in the file's header).
local HOUSE_GUST = {
	"....", "W...", "W...", "iW..", "iW..", ".iW.", ".iW.", "i.iW", "i.iW", "ii.i",
	".i.i", ".ii.", "..i.", "..ii", "...i", "...i", "....", "....", "....",
}

describe("fan.breezeleds", function()
	before_each(function()
		log.sink = function() end
	end)

	after_each(function()
		breezeleds.RECOLOUR_NEEDS_STATE = SHIPPED_RECOLOUR
		log.sink = REAL_SINK
	end)

	describe("the constants (section 1a's interface block)", function()
		it("ships the palette, the tick, the step bounds, the budget and the strength tables", function()
			assert.equal("ffffff", HEAD)
			assert.same({ "a0ffff", "00ffff", "40b0ff" }, SPARKS)
			assert.equal("40b0ff", GLINT)
			assert.equal(50, breezeleds.TICK_MS)
			assert.equal(60, breezeleds.STEP_MIN)
			assert.equal(400, breezeleds.STEP_MAX)
			assert.equal(120, breezeleds.STEP_DEFAULT)
			assert.equal(30, breezeleds.BUDGET_PER_S)
			assert.same({ [1] = { 4000, 8000 }, [2] = { 2000, 5000 }, [3] = { 1000, 3000 } }, breezeleds.REST_MS)
			assert.same({ [1] = { 300, 500 }, [2] = { 500, 800 }, [3] = { 700, 1100 } }, breezeleds.TAIL_MS)
			assert.same({ [1] = 10, [2] = 25, [3] = 40 }, breezeleds.DOUBLE_PERCENT)
			assert.same({ 2, 4 }, breezeleds.TAIL_GAP_TICKS)
			assert.same({ 2, 4 }, breezeleds.DOUBLE_GAP_STEPS)
			assert.is_false(SHIPPED_RECOLOUR)
		end)

		it("never uses pure blue or anything darker than sky (BL-D20)", function()
			for _, colour in ipairs({ HEAD, GLINT, ICE, TEAL, SKY }) do
				assert.not_equal("0000ff", colour)
				assert.is_truthy(colour:match("^%x%x%x%x%x%x$"))
			end
		end)
	end)

	describe("dark first (BL-D19)", function()
		it("takes every pixel and sends each dark at once; the first gust starts with nothing lit", function()
			local r = rig()
			local first = start(r, shuffled(HOUSE))
			assert.same(darks(HOUSE), first)
			assert.same({ true, true, true, true }, held_list(r, HOUSE))
			assert.equal("gust", r.b:debug().phase)
			assert.equal("....", look(r, HOUSE))
			assert.equal(50, pending(r).ms, "the gust ticks at once")
		end)

		it("the front enters pixel 1 one front step later: preloaded white, then lit", function()
			local r = rig()
			start(r)
			assert.same({}, tick(r))
			assert.same({ { "paint", 302, HEAD, false, true }, { "light", 302, true } }, tick(r))
			assert.equal("W...", look(r, HOUSE))
		end)

		it("starts from the highest speed with the bottom at speed 6", function()
			local r = rig()
			assert.same(darks({ 305, 304, 303, 302 }), start(r, HOUSE, 6))
			tick(r)
			assert.same({ { "paint", 305, HEAD, false, true }, { "light", 305, true } }, tick(r))
		end)
	end)

	describe("a gust (BL-D21, BL-D26)", function()
		it("plays the house's gust: a white front rising, the twinkling tail behind it, then dark", function()
			local r = rig()
			start(r)
			local looks = run_gust(r, HOUSE)
			assert.same(HOUSE_GUST, looks)
			assert.equal("....", look(r, HOUSE))
			assert.equal("rest", r.b:debug().phase)
			assert.equal(0, r.b:debug().budget.dropped)
		end)

		for _, n in ipairs({ 1, 2, 4, 6 }) do
			for _, bottom in ipairs({ 1, 6 }) do
				it(string.format("rises bottom to top over %d pixel(s) with the bottom at speed %d", n, bottom), function()
					local r = rig()
					local order = bottom == 6 and reversed(LISTS[n]) or LISTS[n]
					start(r, shuffled(LISTS[n]), bottom)
					assert.same(order, r.b:debug().pixels)
					local looks, calls = run_gust(r, order)
					for i = 1, n do
						for t = 1, #looks do
							local white = looks[t]:sub(i, i) == "W"
							assert.equal(t == 2 * i or t == 2 * i + 1, white,
								string.format("pixel %d white at ticks %d and %d only (tick %d)", i, 2 * i, 2 * i + 1, t))
						end
					end
					for _, call in ipairs(calls) do
						if call[1] == "paint" then
							assert.is_truthy(call[3] == HEAD or LETTER[call[3]], "only white and the sparks")
						end
					end
					assert.equal(string.rep(".", n), look(r, order), "every pixel dark at the end")
					assert.same({ 2000, 5000 }, r.randoms[#r.randoms], "then a rest")
				end)
			end
		end

		it("leaves each passed pixel in a spark colour, never white, never pure blue", function()
			local r = rig()
			r.pick = seeded(11)
			start(r, LISTS[6], 1, 3)
			for _ = 1, 3 do
				local looks = run_gust(r, LISTS[6])
				for _, frame in ipairs(looks) do
					assert.is_nil(frame:find("?", 1, true), "never unknown")
				end
				tick(r) -- the rest
			end
		end)

		describe("messages (BL-D23)", function()
			it("preloads a dark pixel's colour and lights it; recolours a lit one; darkens with a light", function()
				local r = rig()
				start(r)
				ticks(r, 3)
				assert.same({ { "paint", 302, ICE, false, false }, { "paint", 303, HEAD, false, true },
					{ "light", 303, true } }, tick(r), "the front moves on: 302 recoloured while lit, 303 lit white")
				tick(r)
				local calls = tick(r)
				assert.same({ "light", 302, false }, calls_to(calls, 302)[1], "a blink off: one light")
				tick(r)
				assert.same({ { "light", 302, true } }, calls_to(tick(r), 302), "relit in the colour it holds: one light")
			end)

			it("a relight in a new colour: a preload, then the light", function()
				local r = rig()
				local colours = { 1, 2 }
				r.pick = function(lo, hi)
					if lo == 1 and hi == #SPARKS then
						return table.remove(colours, 1) or 1
					end
					return low(lo, hi)
				end
				start(r, { 303 })
				ticks(r, 7)
				assert.same({ { "paint", 303, TEAL, false, true }, { "light", 303, true } }, tick(r))
			end)

			it("with RECOLOUR_NEEDS_STATE true a lit recolour carries the state", function()
				breezeleds.RECOLOUR_NEEDS_STATE = true
				local r = rig()
				start(r)
				ticks(r, 3)
				assert.same({ "paint", 302, ICE, true, false }, tick(r)[1])
			end)

			it("sends nothing for a tick that changes nothing", function()
				local r = rig()
				start(r)
				assert.same({}, tick(r), "the front below pixel 1")
				tick(r)
				assert.same({}, tick(r), "the front still on pixel 1")
			end)
		end)

		describe("the tail (BL-D26)", function()
			it("blinks a tail pixel off and on more than once (Breeze 3)", function()
				local r = rig()
				start(r, { 302, 303 }, 1, 3)
				local _, calls = run_gust(r, { 302, 303 })
				for _, link in ipairs({ 302, 303 }) do
					local relights, offs = 0, 0
					for _, call in ipairs(calls_to(calls, link)) do
						if call[1] == "light" and call[3] then
							relights = relights + 1
						elseif call[1] == "light" then
							offs = offs + 1
						end
					end
					assert.is_true(relights >= 3, link .. ": lit by the front, then relit at least twice")
					assert.is_true(offs >= 2, link .. ": off at least twice")
				end
			end)

			it("blinks at gaps of 2 to 4 ticks, each pixel its own", function()
				local r = rig()
				local seed = seeded(5)
				r.pick = function(lo, hi)
					if (lo == 1 and hi == 100) or lo == 100 then
						return low(lo, hi) -- no double, no glint, the front step 100 ms
					end
					return seed(lo, hi)
				end
				start(r, { 304 }, 1, 3)
				local gaps = 0
				for _ = 1, 8 do
					local looks = run_gust(r, { 304 })
					-- The changes after the front left (tick 4), the last one aside (the tail's end may be sooner).
					local changes, last = { 4 }, looks[4]
					for t = 5, #looks do
						if (looks[t] == ".") ~= (last == ".") then
							changes[#changes + 1] = t
						end
						last = looks[t]
					end
					for k = 2, #changes - 1 do
						local gap = changes[k] - changes[k - 1]
						assert.is_true(gap >= 2 and gap <= 4, "a gap of " .. gap .. " ticks")
						gaps = gaps + 1
					end
					tick(r)
				end
				assert.is_true(gaps >= 8, "enough gaps seen")
				for _, range in ipairs(r.randoms) do
					if range[2] == 4 and range[1] ~= 1 then
						assert.is_true(range[1] >= 2 and range[1] <= 4)
					end
				end
			end)

			it("grows its gaps towards the end: the gap's low end rises over the tail", function()
				local r = rig()
				start(r, { 303 }, 1, 3)
				run_gust(r, { 303 })
				local lows = {}
				for _, range in ipairs(r.randoms) do
					if range[2] == 4 and range[1] >= 2 then
						lows[#lows + 1] = range[1]
					end
				end
				-- 700 ms, 14 ticks, the gaps at their low end: at ticks 0, 2, 4, 6, 9 and 12 of the tail.
				assert.same({ 2, 2, 2, 3, 3, 4 }, lows)
			end)

			it("does not blink neighbours in step, and the same seed plays the same gust", function()
				local function play(seed)
					local r = rig()
					r.pick = seeded(seed)
					start(r, HOUSE, 1, 3)
					local looks, calls = run_gust(r, HOUSE)
					return looks, calls
				end
				local looks, calls = play(42)
				local again, calls_again = play(42)
				assert.same(looks, again)
				assert.same(calls, calls_again)
				-- Each pixel's blinks, as ticks after the front left it.
				local patterns = {}
				for i = 1, #HOUSE do
					local left
					for t = 1, #looks do
						if left == nil and t > 1 and looks[t - 1]:sub(i, i) == "W" and looks[t]:sub(i, i) ~= "W" then
							left = t
						end
					end
					local pattern, was = {}, true
					for t = left or #looks + 1, #looks do
						local lit = looks[t]:sub(i, i) ~= "."
						if lit ~= was then
							pattern[#pattern + 1] = t - left
						end
						was = lit
					end
					patterns[i] = table.concat(pattern, ",")
				end
				for i = 2, #HOUSE do
					assert.not_equal(patterns[i - 1], patterns[i], "pixels " .. (i - 1) .. " and " .. i)
				end
			end)

			for strength, range in ipairs({ { 300, 500 }, { 500, 800 }, { 700, 1100 } }) do
				it(string.format("lasts %d to %d ms at Breeze %d", range[1], range[2], strength), function()
					for _, at in ipairs({ "low", "high" }) do
						local r = rig()
						r.pick = function(lo, hi)
							if lo == range[1] and hi == range[2] then
								return at == "low" and lo or hi
							end
							return low(lo, hi)
						end
						start(r, { 303 }, 1, strength)
						local looks = run_gust(r, { 303 })
						local ms = at == "low" and range[1] or range[2]
						-- The front leaves at tick 4; the rest begins when the tail's time is out.
						assert.equal(4 + ms / 50 - 1, #looks, at .. " end")
						local seen = false
						for _, drawn in ipairs(r.randoms) do
							seen = seen or (drawn[1] == range[1] and drawn[2] == range[2])
						end
						assert.is_true(seen, "the tail time drawn in its strength's range")
					end
				end)
			end
		end)

		describe("double gusts (BL-D21, BL-D22)", function()
			-- The first percent draw is the double: `answer` to it, 100 to the rest.
			local function double_pick(answer)
				local draws = 0
				return function(lo, hi)
					if lo == 1 and hi == 100 then
						draws = draws + 1
						return draws == 1 and answer or 100
					end
					return low(lo, hi)
				end
			end

			it("runs a second front 2 front steps behind the first", function()
				local r = rig()
				r.pick = double_pick(1)
				start(r)
				assert.same({ 0, 200 }, r.b:debug().gust.offsets)
				local looks = run_gust(r, HOUSE)
				for i = 1, 4 do
					local whites = {}
					for t = 1, #looks do
						if looks[t]:sub(i, i) == "W" then
							whites[#whites + 1] = t
						end
					end
					assert.same({ 2 * i, 2 * i + 1, 2 * i + 4, 2 * i + 5 }, whites, "pixel " .. i .. " white twice")
				end
				assert.equal("....", look(r, HOUSE))
			end)

			for strength, percent in ipairs({ 10, 25, 40 }) do
				it(string.format("happens with %d %% at Breeze %d", percent, strength), function()
					local r = rig()
					r.pick = double_pick(percent)
					start(r, HOUSE, 1, strength)
					assert.equal(200, r.b:debug().gust.offsets[2])
					local s = rig()
					s.pick = double_pick(percent + 1)
					start(s, HOUSE, 1, strength)
					assert.is_nil(s.b:debug().gust.offsets[2])
				end)
			end

			it("is a single gust when both fronts would not fit the budget", function()
				local r = rig()
				r.pick = double_pick(1)
				start(r, LISTS[6])
				assert.is_nil(r.b:debug().gust.offsets[2], "6 dark-first and 36 for two fronts over 6 pixels")
				assert.is_true(r.log.has("debug", "no room in the budget for a second front"))
			end)
		end)

		describe("glints (BL-D21)", function()
			it("may glint the pixel two above the leading front for one tick, in sky", function()
				local r = rig()
				local draws = 0
				r.pick = function(lo, hi)
					if lo == 1 and hi == 100 then
						draws = draws + 1
						return draws == 1 and 100 or 1 -- no double; every glint
					end
					return low(lo, hi)
				end
				start(r)
				tick(r)
				local calls = tick(r)
				assert.same({ { "paint", 304, GLINT, false, true }, { "light", 304, true } }, calls_to(calls, 304))
				assert.equal("W.s.", look(r, HOUSE))
				assert.same({ { "light", 304, false } }, tick(r), "for one tick")
				tick(r)
				assert.equal("iW.s", look(r, HOUSE), "the front on pixel 2: pixel 4 glints")
				tick(r)
				assert.equal("iW..", look(r, HOUSE))
			end)

			it("draws no glint where there is no pixel two above the front", function()
				local r = rig()
				start(r, { 302, 303 })
				run_gust(r, { 302, 303 })
				local percents = 0
				for _, drawn in ipairs(r.randoms) do
					if drawn[1] == 1 and drawn[2] == 100 then
						percents = percents + 1
					end
				end
				assert.equal(1, percents, "the double's draw only")
			end)
		end)
	end)

	describe("rests (BL-D19, BL-D22)", function()
		for strength, range in ipairs({ { 4000, 8000 }, { 2000, 5000 }, { 1000, 3000 } }) do
			it(string.format("are dark and last %d to %d ms at Breeze %d, with no ticking", range[1], range[2], strength),
				function()
					local r = rig()
					to_rest(r, HOUSE, 1, strength)
					assert.equal("....", look(r, HOUSE))
					assert.same(range, r.randoms[#r.randoms])
					assert.equal(range[1], pending(r).ms, "one timer for the whole rest")
					local armed = #r.timers
					assert.same({}, tick(r), "the next gust starts dark")
					assert.equal("gust", r.b:debug().phase)
					assert.equal(armed + 1, #r.timers)
					assert.equal(50, pending(r).ms)
				end)
		end

		it("rest as Breeze 2 when the strength is unknown or not 1 to 3", function()
			for _, strength in ipairs({ 7, 0, 2.5, "x" }) do
				local r = rig()
				to_rest(r, HOUSE, 1, strength)
				assert.same({ 2000, 5000 }, r.randoms[#r.randoms])
				assert.same({ 500, 800 }, r.b:debug().tail)
			end
			local r = rig()
			r.b:configure({ enabled = true, per_speed = true, bottom = 1, step = STEP })
			r.b:set_pixels(HOUSE)
			r.b:update({ breeze = true, online = true })
			run_gust(r, HOUSE)
			assert.same({ 2000, 5000 }, r.randoms[#r.randoms])
		end)

		it("arm the time random gave, held within the range", function()
			local r = rig()
			r.pick = function(lo, hi)
				if lo == 2000 then
					return hi
				end
				return low(lo, hi)
			end
			to_rest(r)
			assert.equal(5000, pending(r).ms)
			local s = rig()
			s.pick = function(lo, hi)
				if lo == 2000 then
					return 10
				end
				return low(lo, hi)
			end
			to_rest(s)
			assert.equal(2000, pending(s).ms, "below the range: its low end")
		end)

		it("take a strength change from the next gust: the running gust keeps its tails", function()
			local r = rig()
			start(r, HOUSE, 1, 1)
			ticks(r, 4)
			r.b:update({ breeze = true, strength = 3, online = true })
			assert.same({}, take(r), "nothing sent")
			run_gust(r, HOUSE)
			for _, drawn in ipairs(r.randoms) do
				assert.is_false(drawn[1] == 700, "no Breeze 3 tail in this gust")
			end
			assert.same({ 1000, 3000 }, r.randoms[#r.randoms], "the rest takes the new strength")
			tick(r)
			run_gust(r, HOUSE)
			local seen = false
			for _, drawn in ipairs(r.randoms) do
				seen = seen or drawn[1] == 700
			end
			assert.is_true(seen, "the next gust's tails are Breeze 3's")
		end)

		it("keep the strength on an update without breeze (the phase listener sends online alone)", function()
			local r = rig()
			to_rest(r, HOUSE, 1, 3)
			r.b:update({ online = true })
			assert.same({ 1000, 3000 }, r.b:debug().rest)
			r.b:update({ breeze = true })
			assert.same({ 2000, 5000 }, r.b:debug().rest, "with breeze, a missing strength is unknown")
		end)
	end)

	describe("the budget (BL-D24)", function()
		it("never sends more than 30 messages in any second, and never drops a front or leaves white behind",
			function()
				for _, seed in ipairs({ 3, 17, 29 }) do
					local r = rig()
					r.pick = seeded(seed)
					start(r, LISTS[6], 1, 3)
					local gusts = 0
					while gusts < 12 do
						local before = r.b:debug().phase
						tick(r)
						local phase = r.b:debug().phase
						if phase == "gust" then
							local at, shows = fronts_now(r), look(r, LISTS[6])
							for i = 1, 6 do
								assert.equal(at[i] == true, shows:sub(i, i) == "W",
									string.format("seed %d: pixel %d is white exactly while a front is on it", seed, i))
							end
						elseif before == "gust" then
							gusts = gusts + 1
						end
					end
					assert.is_true(max_window(r.stamps) <= 30, "seed " .. seed .. ": " .. max_window(r.stamps))
					assert.is_true(r.b:debug().budget.dropped > 0, "tail changes were dropped")
				end
			end)

		it("drops tail changes, never the head: a busy tail freezes while the front runs on time", function()
			local r = rig()
			local colour = 0
			r.pick = function(lo, hi)
				if lo == 1 and hi == #SPARKS then
					colour = colour % #SPARKS + 1 -- a new colour at every relight: two messages each
					return colour
				elseif lo == 700 then
					return hi
				end
				return low(lo, hi)
			end
			start(r, LISTS[6], 1, 3)
			local looks = run_gust(r, LISTS[6])
			for i = 1, 6 do
				assert.equal("W", looks[2 * i]:sub(i, i), "pixel " .. i .. " white on time")
			end
			assert.is_true(r.b:debug().budget.dropped > 0)
			assert.is_true(max_window(r.stamps) <= 30)
		end)

		it("never drops a settle: the falling wipe settles every pixel, whatever the window holds", function()
			local r = rig()
			r.pick = seeded(3)
			start(r, LISTS[6], 1, 3)
			ticks(r, 12)
			r.b:update({ breeze = false })
			local calls = take(r)
			for _ = 1, 6 do
				for _, call in ipairs(tick(r)) do
					calls[#calls + 1] = call
				end
			end
			local settled = {}
			for _, call in ipairs(calls) do
				if call[1] == "settle" then
					settled[#settled + 1] = call[2]
				end
			end
			assert.same(reversed(LISTS[6]), settled)
			assert.equal("idle", r.b:debug().phase)
		end)
	end)

	describe("the falling wipe (BL-D8, BL-D25)", function()
		it("from a rest: the head runs down the dark column, settling each pixel it leaves", function()
			local r = rig()
			to_rest(r)
			local resting = pending(r)
			r.b:update({ breeze = false, strength = 2, online = true })
			assert.is_true(resting.cancelled)
			assert.same({ { "paint", 305, HEAD, false, true }, { "light", 305, true } }, take(r))
			assert.equal("leave", r.b:debug().phase)
			assert.equal(STEP, pending(r).ms, "at the step itself, not jittered")
			assert.same({ { "paint", 304, HEAD, false, true }, { "light", 304, true }, { "settle", 305 } }, tick(r))
			assert.same({ { "paint", 303, HEAD, false, true }, { "light", 303, true }, { "settle", 304 } }, tick(r))
			assert.same({ { "paint", 302, HEAD, false, true }, { "light", 302, true }, { "settle", 303 } }, tick(r))
			assert.same({ { "settle", 302 } }, tick(r))
			assert.equal("idle", r.b:debug().phase)
			assert.is_nil(pending(r), "nothing pending once idle")
			assert.same({ false, false, false, false }, held_list(r, HOUSE))
		end)

		it("from the top at speed 6 when the bottom is the highest speed", function()
			local r = rig()
			to_rest(r, HOUSE, 6)
			r.b:update({ breeze = false })
			assert.same({ { "paint", 302, HEAD, false, true }, { "light", 302, true } }, take(r))
			assert.same({ { "paint", 303, HEAD, false, true }, { "light", 303, true }, { "settle", 302 } }, tick(r))
		end)

		it("from a gust: at once from the top; a pixel not reached keeps what it shows until the head passes",
			function()
				local r = rig()
				start(r)
				ticks(r, 8)
				assert.equal("i.iW", look(r, HOUSE))
				local gusting = pending(r)
				r.b:update({ breeze = false })
				assert.is_true(gusting.cancelled)
				assert.same({}, take(r), "305 shows the head already")
				assert.equal(STEP, pending(r).ms)
				assert.same({ { "paint", 304, HEAD, false, false }, { "settle", 305 } }, tick(r), "lit: one recolour")
				assert.equal("i.W~", look(r, HOUSE), "the tail frozen below the head")
				assert.same({ { "paint", 303, HEAD, false, true }, { "light", 303, true }, { "settle", 304 } }, tick(r))
				assert.same({ { "paint", 302, HEAD, false, false }, { "settle", 303 } }, tick(r))
				assert.same({ { "settle", 302 } }, tick(r))
				assert.equal("~~~~", look(r, HOUSE))
				assert.equal("idle", r.b:debug().phase)
			end)

		for _, n in ipairs({ 1, 2, 6 }) do
			it(string.format("settles each of %d pixel(s) once, top to bottom", n), function()
				local r = rig()
				to_rest(r, LISTS[n])
				r.b:update({ breeze = false })
				local calls = take(r)
				while r.b:debug().phase == "leave" do
					for _, call in ipairs(tick(r)) do
						calls[#calls + 1] = call
					end
				end
				local settled = {}
				for _, call in ipairs(calls) do
					if call[1] == "settle" then
						settled[#settled + 1] = call[2]
					end
				end
				assert.same(reversed(LISTS[n]), settled)
			end)
		end

		it("takes a step change from its next arm", function()
			local r = rig()
			to_rest(r)
			r.b:update({ breeze = false })
			r.b:configure({ step = 300 })
			assert.equal(STEP, pending(r).ms)
			tick(r)
			assert.equal(300, pending(r).ms)
		end)
	end)

	describe("interruptions (BL-D10)", function()
		it("Breeze again during the leave: every pixel taken back and dark at once, then a new gust", function()
			local r = rig()
			to_rest(r)
			r.b:update({ breeze = false })
			tick(r) -- 305 settled, the head on 304
			take(r)
			r.b:update({ breeze = true, strength = 2 })
			assert.same(darks(HOUSE), take(r))
			assert.same({ true, true, true, true }, held_list(r, HOUSE))
			assert.equal("gust", r.b:debug().phase)
			assert.equal("....", look(r, HOUSE))
			tick(r)
			assert.same({ { "paint", 302, HEAD, false, true }, { "light", 302, true } }, tick(r))
		end)

		it("the newest shown state wins: leave, Breeze, leave again", function()
			local r = rig()
			to_rest(r)
			r.b:update({ breeze = false })
			tick(r)
			r.b:update({ breeze = true })
			take(r)
			r.b:update({ breeze = false })
			assert.same({ { "paint", 305, HEAD, false, true }, { "light", 305, true } }, take(r))
			assert.equal("leave", r.b:debug().phase)
			assert.equal(4, r.b:debug().head)
		end)

		it("leave right after the dark-first: the wipe from the top", function()
			local r = rig()
			start(r)
			r.b:update({ breeze = false })
			assert.same({ { "paint", 305, HEAD, false, true }, { "light", 305, true } }, take(r))
		end)
	end)

	describe("settling at once, no wipe (BL-D11)", function()
		local function gusting()
			local r = rig()
			start(r)
			ticks(r, 5)
			take(r)
			return r, pending(r)
		end

		local SETTLED = settles(HOUSE)

		it("when the fan goes offline, and dark first again when it is back in Breeze", function()
			local r, timer = gusting()
			r.b:update({ online = false })
			assert.same(SETTLED, take(r))
			assert.is_true(timer.cancelled)
			assert.is_nil(pending(r))
			assert.equal("idle", r.b:debug().phase)
			r.b:update({ online = true })
			assert.same(darks(HOUSE), take(r))
			assert.equal("gust", r.b:debug().phase)
		end)

		it("when Breeze ends and the fan goes offline in one update", function()
			local r = gusting()
			r.b:update({ breeze = false, online = false })
			assert.same(SETTLED, take(r))
		end)

		it("when the property is turned Off", function()
			local r = gusting()
			r.b:configure({ enabled = false })
			assert.same(SETTLED, take(r))
		end)

		it("when Speed LED Colors leaves Per speed", function()
			local r = gusting()
			r.b:configure({ per_speed = false })
			assert.same(SETTLED, take(r))
		end)

		it("during a rest", function()
			local r = rig()
			to_rest(r)
			r.b:update({ online = false })
			assert.same(SETTLED, take(r))
			assert.is_nil(pending(r))
		end)

		it("during the leave: what is still held", function()
			local r = rig()
			to_rest(r)
			r.b:update({ breeze = false })
			tick(r)
			take(r)
			r.b:update({ online = false })
			assert.same(settles({ 302, 303, 304 }), take(r))
			assert.is_nil(pending(r))
		end)

		it("when no pixel is left: each unbound pixel is dropped without a send", function()
			local r, timer = gusting()
			r.b:set_pixels({})
			assert.same({}, take(r))
			assert.is_true(timer.cancelled)
			assert.equal("idle", r.b:debug().phase)
			assert.same({ false, false, false, false }, held_list(r, HOUSE))
		end)
	end)

	describe("late ticks (BL-D13: no burst)", function()
		it("applies the tick that fell due last, each pixel only its final state", function()
			local on_time = rig()
			start(on_time)
			ticks(on_time, 9)
			local late = rig()
			start(late)
			local calls = tick(late, 400) -- tick 9 instead of tick 1
			assert.equal(look(on_time, HOUSE), look(late, HOUSE))
			assert.equal("i.iW", look(late, HOUSE))
			for _, link in ipairs(HOUSE) do
				local paints, lights = 0, 0
				for _, call in ipairs(calls_to(calls, link)) do
					if call[1] == "paint" then
						paints = paints + 1
					else
						lights = lights + 1
					end
				end
				assert.is_true(paints <= 1 and lights <= 1, link .. ": its final state only")
			end
			assert.equal(50, pending(late).ms, "back on the cadence")
			local off = rig()
			start(off)
			tick(off, 420)
			assert.equal(30, pending(off).ms, "the next tick when it falls due, not a full tick later")
		end)

		it("ends a gust in its rest when it fell due after the gust", function()
			local r = rig()
			start(r)
			ticks(r, 9)
			tick(r, 5000)
			assert.equal("....", look(r, HOUSE))
			assert.equal("rest", r.b:debug().phase)
			assert.same({ 2000, 5000 }, r.randoms[#r.randoms], "the rest armed once")
		end)

		it("starts the gust at the time a late rest fires, from its first tick", function()
			local r = rig()
			to_rest(r)
			assert.same({}, tick(r, 3000))
			assert.equal(0, r.b:debug().gust.tick)
			tick(r)
			assert.same({ { "paint", 302, HEAD, false, true }, { "light", 302, true } }, tick(r))
		end)

		it("settles every pixel a late wipe passed, top down", function()
			local r = rig()
			to_rest(r)
			r.b:update({ breeze = false })
			take(r)
			assert.same({ { "paint", 302, HEAD, false, true }, { "light", 302, true }, { "settle", 305 },
				{ "settle", 304 }, { "settle", 303 } }, tick(r, 2 * STEP))
			assert.same({ { "settle", 302 } }, tick(r))
			assert.equal("idle", r.b:debug().phase)

			local s = rig()
			to_rest(s)
			s.b:update({ breeze = false })
			take(s)
			assert.same(settles(reversed(HOUSE)), tick(s, 60000), "past the end: every pixel, once")
			assert.equal("idle", s.b:debug().phase)
			assert.is_nil(pending(s))
		end)

		it("steps one tick at a time without a clock", function()
			local r = rig({ no_clock = true })
			start(r)
			tick(r, 5000)
			assert.equal(1, r.b:debug().gust.tick)
			assert.equal(50, pending(r).ms)
		end)

		it("ignores a callback whose timer was cancelled", function()
			local r = rig()
			start(r)
			local old = pending(r)
			r.b:update({ online = false })
			take(r)
			assert.is_true(old.cancelled)
			old.cb()
			assert.same({}, take(r))
			assert.equal("idle", r.b:debug().phase)
		end)
	end)

	describe("set_pixels while active (BL-D16)", function()
		it("takes a pixel bound during a rest and sends it dark at once; the rest goes on", function()
			local r = rig()
			to_rest(r)
			local resting = pending(r)
			r.b:set_pixels({ 305, 301, 304, 303, 302 })
			assert.same({ { "light", 301, false } }, take(r))
			assert.is_true(r.b:held(301))
			assert.equal(resting, pending(r))
			assert.same({ 301, 302, 303, 304, 305 }, r.b:debug().pixels)
		end)

		it("takes a pixel bound during a gust dark; the gust runs on over the longer column", function()
			local r = rig()
			start(r)
			ticks(r, 3)
			take(r)
			r.b:set_pixels({ 302, 303, 304, 305, 306 })
			assert.same({ { "light", 306, false } }, take(r))
			local looks = run_gust(r, { 302, 303, 304, 305, 306 })
			assert.equal("W", looks[10 - 3]:sub(5, 5), "the front reaches 306 at tick 10")
		end)

		it("drops a removed pixel without any call", function()
			local r = rig()
			to_rest(r)
			r.b:set_pixels({ 302, 303, 304 })
			assert.same({}, take(r))
			assert.is_false(r.b:held(305))
			assert.equal("rest", r.b:debug().phase)
			tick(r)
			local looks = run_gust(r, { 302, 303, 304 })
			assert.same({}, calls_to(r.calls, 305))
			assert.equal(3, #looks[1])
		end)

		it("does not take a pixel bound during the leave: Breeze has ended", function()
			local r = rig()
			to_rest(r)
			r.b:update({ breeze = false })
			take(r)
			r.b:set_pixels({ 301, 302, 303, 304, 305 })
			assert.is_false(r.b:held(301))
			-- 301 is pixel 1 now: the head stays at pixel 4 (304), so 305 above it is settled.
			assert.same({ { "paint", 304, HEAD, false, true }, { "light", 304, true }, { "settle", 305 } }, take(r))
			assert.same({ { "paint", 303, HEAD, false, true }, { "light", 303, true }, { "settle", 304 } }, tick(r))
			assert.same({ { "paint", 302, HEAD, false, true }, { "light", 302, true }, { "settle", 303 } }, tick(r))
			assert.same({ { "settle", 302 } }, tick(r), "301 is not held: nothing shown there")
			assert.equal("idle", r.b:debug().phase)
		end)

		it("starts with the dark-first when the first pixel is bound while Breeze blows", function()
			local r = rig()
			r.b:configure({ enabled = true, per_speed = true, bottom = 1, step = STEP })
			r.b:update({ breeze = true, strength = 2, online = true })
			assert.same({}, take(r))
			assert.is_nil(pending(r))
			r.b:set_pixels({ 304 })
			assert.same({ { "light", 304, false } }, take(r))
		end)

		it("keeps only the speed links 301 to 306, each once", function()
			local r = rig()
			start(r, { 300, 311, 307, 308, 200, 304, "302", 304, 302.5, "x" })
			assert.same({ 302, 304 }, r.b:debug().pixels)
		end)
	end)

	describe("repaint (BL-D15)", function()
		it("sends a dark pixel dark, and forgets its loaded colour", function()
			local r = rig()
			start(r)
			ticks(r, 5)
			assert.equal("iW..", look(r, HOUSE))
			assert.is_true(r.b:repaint(304))
			assert.same({ { "light", 304, false } }, take(r))
			assert.is_nil(r.b:debug().loaded[304])
		end)

		it("sends a lit pixel its colour with the state", function()
			local r = rig()
			start(r)
			ticks(r, 5)
			r.b:repaint(302)
			r.b:repaint(303)
			assert.same({ { "paint", 302, ICE, true, false }, { "paint", 303, HEAD, true, false } }, take(r))
		end)

		it("relights a pixel whose colour it forgot with a preload", function()
			local r = rig()
			start(r)
			ticks(r, 6) -- 302 dark, ice loaded
			r.b:repaint(302)
			take(r)
			ticks(r, 1)
			assert.same({ { "paint", 302, ICE, false, true }, { "light", 302, true } }, calls_to(tick(r), 302))
		end)

		it("sends a pixel the falling head has not reached what it shows", function()
			local r = rig()
			start(r)
			ticks(r, 8) -- i.iW
			r.b:update({ breeze = false })
			take(r)
			r.b:repaint(302)
			r.b:repaint(303)
			assert.same({ { "paint", 302, ICE, true, false }, { "light", 303, false } }, take(r))
		end)

		it("does nothing for a link it does not hold", function()
			local r = rig()
			to_rest(r)
			assert.is_false(r.b:repaint(301))
			assert.is_false(r.b:repaint(300))
			r.b:update({ breeze = false })
			take(r)
			tick(r) -- 305 settled
			assert.is_false(r.b:repaint(305))
			assert.same({}, take(r))
		end)
	end)

	describe("stop (BL-D17)", function()
		it("cancels the timer, forgets every hold and sends nothing", function()
			local r = rig()
			start(r)
			ticks(r, 5)
			take(r)
			local timer = pending(r)
			r.b:stop()
			assert.same({}, take(r))
			assert.is_true(timer.cancelled)
			assert.same({ false, false, false, false }, held_list(r, HOUSE))
			timer.cb()
			assert.same({}, take(r), "a late callback does nothing")
		end)

		it("is final: later calls send nothing and arm nothing", function()
			local r = rig()
			start(r)
			r.b:stop()
			local armed = #r.timers
			r.b:update({ breeze = false })
			r.b:update({ breeze = true, online = true })
			r.b:configure({ enabled = true, per_speed = true, bottom = 6 })
			r.b:set_pixels({ 301 })
			assert.is_false(r.b:repaint(302))
			assert.same({}, take(r))
			assert.equal(armed, #r.timers)
			assert.is_true(r.b:debug().stopped)
		end)
	end)

	describe("failures (every option through pcall)", function()
		it("logs a paint that fails; the pixel is sent again at the next tick", function()
			local r = rig()
			start(r)
			tick(r)
			r.fail_paint = function(link, colour) return link == 302 and colour == HEAD end
			local calls
			assert.has_no.errors(function() calls = tick(r) end)
			assert.same({ { "paint", 302, HEAD, false, true } }, calls, "no light after a failed preload")
			assert.is_true(r.log.has("warn", "link 302 could not be painted ffffff"))
			r.fail_paint = nil
			assert.same({ { "paint", 302, HEAD, false, true }, { "light", 302, true } }, tick(r))
			assert.equal("W...", look(r, HOUSE))
		end)

		it("logs a light that fails; a pixel whose state is unknown is painted with the state", function()
			local r = rig()
			start(r)
			tick(r)
			r.fail_light = function(link, lit) return link == 302 and lit end
			assert.has_no.errors(function() tick(r) end)
			assert.is_true(r.log.has("warn", "link 302 could not be lit"))
			r.fail_light = nil
			assert.same({ { "paint", 302, HEAD, true, false } }, tick(r))
		end)

		it("rests anyway when a pixel cannot be darkened, after waiting for it", function()
			local r = rig()
			start(r, { 303 })
			r.fail_light = function(_, lit) return not lit end
			local looks = run_gust(r, { 303 })
			assert.equal("rest", r.b:debug().phase)
			assert.equal(4 + 10 + breezeleds.DARKEN_TICKS, #looks + 1, "the tail, then DARKEN_TICKS ticks")
			assert.is_true(r.log.has("debug", "a pixel still not dark"))
			assert.is_true(r.log.has("warn", "link 303 could not be darkened"))
		end)

		it("works on without the light option, logging each light it could not send", function()
			local r = rig({ no_light = true })
			assert.has_no.errors(function() start(r) end)
			assert.is_true(r.log.has("warn", "link 302 could not be darkened: not given"))
			assert.has_no.errors(function() ticks(r, 30) end)
		end)

		it("logs a settle that fails and goes on with the wipe", function()
			local r = rig()
			to_rest(r)
			r.fail_settle = function(link) return link == 305 end
			r.b:update({ breeze = false })
			take(r)
			local calls
			assert.has_no.errors(function() calls = tick(r) end)
			assert.same({ "settle", 305 }, calls[3])
			assert.is_true(r.log.has("warn", "link 305 could not be settled"))
			assert.is_false(r.b:held(305))
			ticks(r, 3)
			assert.equal("idle", r.b:debug().phase)
		end)

		it("logs a timer that cannot be armed; the next shown change still acts", function()
			local r = rig()
			r.fail_timer = true
			assert.has_no.errors(function() start(r) end)
			assert.is_true(r.log.has("error", "the timer could not be armed"))
			assert.is_false(r.b:debug().pending)
			r.fail_timer = false
			r.b:update({ breeze = false })
			assert.same({ { "paint", 305, HEAD, false, true }, { "light", 305, true } }, take(r))
		end)

		it("takes the middle of every range when random fails, and warns once", function()
			local r = rig()
			r.fail_random = true
			assert.has_no.errors(function() to_rest(r) end)
			assert.equal(3500, pending(r).ms)
			assert.is_true(r.log.has("warn", "no random number"))
			local warned = 0
			for _, line in ipairs(r.log.lines) do
				if line.text:find("no random number", 1, true) then
					warned = warned + 1
				end
			end
			assert.equal(1, warned)
		end)

		it("goes on by its own time when the clock fails", function()
			local r = rig()
			start(r)
			r.fail_clock = true
			assert.has_no.errors(function() tick(r, 500) end)
			assert.is_true(r.log.has("warn", "the clock failed"))
			assert.equal(1, r.b:debug().gust.tick, "one tick: the time armed")
			r.fail_clock = nil
			tick(r)
			assert.equal(2, r.b:debug().gust.tick)
		end)

		it("logs through common.log when no log is given, and a cancel that fails", function()
			local lines = {}
			log.sink = function(line) lines[#lines + 1] = line end
			local r = rig({ no_log = true })
			r.fail_light = function() return true end
			start(r)
			local found = false
			for _, line in ipairs(lines) do
				if line:find("could not be darkened", 1, true) then
					found = true
				end
			end
			assert.is_true(found)
			local timer = pending(r)
			timer.Cancel = function() error("gone") end
			assert.has_no.errors(function() r.b:update({ online = false }) end)
		end)
	end)

	describe("calls that change nothing send nothing", function()
		local function same_again(r)
			local timer, armed = pending(r), #r.timers
			r.b:configure({ enabled = true, per_speed = true, bottom = 1, step = STEP })
			r.b:set_pixels({ 305, 304, 303, 302, 302 })
			r.b:update({ breeze = r.b:debug().breeze, strength = 2, online = true })
			assert.same({}, take(r))
			assert.equal(armed, #r.timers, "nothing re-armed")
			assert.equal(timer, pending(r))
		end

		it("in every phase", function()
			local r = rig()
			start(r)
			same_again(r)
			ticks(r, 5)
			take(r)
			same_again(r)
			run_gust(r, HOUSE)
			take(r)
			assert.equal("rest", r.b:debug().phase)
			same_again(r)
			r.b:update({ breeze = false, strength = 2, online = true })
			take(r)
			same_again(r)
			tick(r)
			take(r)
			same_again(r)
		end)

		it("Breeze On while it blows restarts nothing (BL7)", function()
			local r = rig()
			to_rest(r)
			r.b:update({ breeze = true, strength = 2, online = true })
			r.b:update({ breeze = true, strength = 2, online = true })
			assert.same({}, take(r))
		end)

		it("a step change sends nothing, re-arms nothing, and applies from the next gust", function()
			local r = rig()
			start(r)
			tick(r)
			local timer = pending(r)
			r.b:configure({ step = 300 })
			assert.same({}, take(r))
			assert.equal(timer, pending(r))
			assert.equal(100, r.b:debug().gust.step, "the running gust keeps its front step")
			run_gust(r, HOUSE)
			tick(r)
			assert.equal(240, r.b:debug().gust.step, "the next gust's: 300 less 20 %")
		end)

		it("a step outside the range is held within it", function()
			local r = rig()
			r.b:configure({ step = 10 })
			assert.equal(60, r.b:debug().step)
			r.b:configure({ step = 900 })
			assert.equal(400, r.b:debug().step)
			r.b:configure({ step = "150" })
			assert.equal(150, r.b:debug().step)
			r.b:configure({ step = "fast" })
			assert.equal(120, r.b:debug().step)
		end)

		it("a front step is never shorter than a tick, so the front never skips a pixel", function()
			local r = rig()
			r.b:configure({ enabled = true, per_speed = true, bottom = 1, step = 60 })
			r.b:set_pixels(LISTS[6])
			r.b:update({ breeze = true, strength = 2, online = true })
			assert.equal(50, r.b:debug().gust.step, "60 less 20 % is 48: held at 50")
			local looks = run_gust(r, LISTS[6])
			for i = 1, 6 do
				assert.equal("W", looks[i]:sub(i, i))
			end
		end)
	end)

	describe("not active (section 3.1)", function()
		local ALL = { enabled = true, per_speed = true, online = true, breeze = true, pixels = true }

		for missing in pairs(ALL) do
			it("without " .. missing .. ": nothing sent, nothing armed, and the dark-first once it comes", function()
				local r = rig()
				r.b:configure({ enabled = missing ~= "enabled", per_speed = missing ~= "per_speed", bottom = 1 })
				if missing ~= "pixels" then
					r.b:set_pixels(HOUSE)
				end
				r.b:update({ breeze = missing ~= "breeze", strength = 2, online = missing ~= "online" })
				assert.same({}, take(r))
				assert.same({}, r.timers)
				assert.equal("idle", r.b:debug().phase)
				assert.is_false(r.b:held(302))
				if missing == "pixels" then
					r.b:set_pixels(HOUSE)
				elseif missing == "breeze" or missing == "online" then
					r.b:update({ [missing] = true })
				else
					r.b:configure({ [missing] = true })
				end
				assert.same(darks(HOUSE), take(r))
			end)
		end

		it("Breeze ending while idle sends nothing", function()
			local r = rig()
			r.b:configure({ enabled = true, per_speed = true })
			r.b:set_pixels(HOUSE)
			r.b:update({ breeze = false, online = true })
			assert.same({}, take(r))
		end)
	end)

	describe("the bottom (BL-D4)", function()
		it("changed during a gust: what is lit goes dark, then a rest", function()
			local r = rig()
			start(r)
			ticks(r, 4) -- iW..
			take(r)
			local timer = pending(r)
			r.b:configure({ bottom = 6 })
			assert.same({ { "light", 303, false }, { "light", 302, false } }, take(r))
			assert.is_true(timer.cancelled)
			assert.equal("rest", r.b:debug().phase)
			assert.same({ 305, 304, 303, 302 }, r.b:debug().pixels)
			tick(r)
			tick(r)
			assert.same({ { "paint", 305, HEAD, false, true }, { "light", 305, true } }, tick(r), "rising from 305")
		end)

		it("changed during a rest: the rest starts again, nothing sent", function()
			local r = rig()
			to_rest(r)
			local timer = pending(r)
			local draws = #r.randoms
			r.b:configure({ bottom = 6 })
			assert.same({}, take(r))
			assert.is_true(timer.cancelled)
			assert.is_not_nil(pending(r))
			assert.equal(draws + 1, #r.randoms)
		end)

		it("changed during the leave: what is still held is settled at once", function()
			local r = rig()
			to_rest(r)
			r.b:update({ breeze = false })
			tick(r)
			take(r)
			r.b:configure({ bottom = 6 })
			assert.same(settles({ 304, 303, 302 }), take(r))
			assert.equal("idle", r.b:debug().phase)
			assert.is_nil(pending(r))
		end)

		it("changed while idle: only the order", function()
			local r = rig()
			r.b:set_pixels(HOUSE)
			r.b:configure({ bottom = 6 })
			assert.same({}, take(r))
			assert.same({ 305, 304, 303, 302 }, r.b:debug().pixels)
			r.b:configure({ bottom = "Speed 1" })
			assert.same(HOUSE, r.b:debug().pixels, "anything but 6 is speed 1 at the bottom")
		end)
	end)

	describe("debug", function()
		it("shows the phase, the pixels in order, what each shows, the ranges, the gust and the budget", function()
			local r = rig()
			r.b:configure({ enabled = true, per_speed = true, bottom = 6, step = 250 })
			r.b:set_pixels(HOUSE)
			r.b:update({ breeze = true, strength = 3, online = true })
			ticks(r, 9)
			local d = r.b:debug()
			assert.equal("gust", d.phase)
			assert.same({ 305, 304, 303, 302 }, d.pixels)
			assert.same({ [302] = true, [303] = true, [304] = true, [305] = true }, d.held)
			assert.same({ [305] = ICE, [304] = HEAD, [303] = "dark", [302] = "dark" }, d.frame)
			assert.same({ [305] = ICE, [304] = HEAD }, d.loaded)
			assert.equal(250, d.step)
			assert.same({ 1000, 3000 }, d.rest)
			assert.same({ 700, 1100 }, d.tail)
			assert.equal(40, d.double)
			assert.same({ tick = 9, step = 200, offsets = { 0 }, strength = 3, dropped = 0 }, d.gust)
			assert.equal(30, d.budget.limit)
			assert.is_true(d.budget.sent > 0)
			assert.is_true(d.active)
			assert.is_true(d.pending)
			assert.equal(6, d.bottom)
			assert.equal(3, d.strength)
		end)

		it("starts idle, with nothing held and the defaults", function()
			local d = breezeleds.new({}):debug()
			assert.equal("idle", d.phase)
			assert.same({}, d.pixels)
			assert.same({}, d.held)
			assert.equal(120, d.step)
			assert.same({ 2000, 5000 }, d.rest)
			assert.is_nil(d.gust)
			assert.is_false(d.active)
			assert.is_false(d.pending)
		end)
	end)
end)
