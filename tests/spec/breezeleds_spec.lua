-- fan.breezeleds on fakes: Breeze on the keypad LEDs (#137, docs/breeze-leds-design.md section 1, BL-D6 to
-- BL-D16, and the interface of section 3.1; section 5's first bullet is this file's list). The paint and settle
-- calls are recorded in order; the timer records its ms and callback and the spec fires the callbacks by hand
-- on a fake clock; random records its bounds.
--
-- Frames are written as pixel positions, 1 being the bottom: "2=H" paints pixel 2 HEAD with with_state false,
-- "2=H!" the same with with_state true, "~2" settles pixel 2; a pixel is mapped to its link through the order
-- the spec expects (the links ascending, or descending with bottom = 6). Most specs run with
-- RECOLOUR_NEEDS_STATE false, so a "!" marks exactly the first paint after a pixel is taken (BL-D14); the
-- shipped value, true, has its own specs.

local breezeleds = require("fan.breezeleds")
local log = require("common.log")

local REAL_SINK = log.sink
local SHIPPED_RECOLOUR = breezeleds.RECOLOUR_NEEDS_STATE

local HEAD, TRAIL, BASE = breezeleds.HEAD, breezeleds.TRAIL, breezeleds.BASE
local COLOURS = { H = HEAD, T = TRAIL, B = BASE }

local HOUSE = { 302, 303, 304, 305 } -- Low, Medium, Med-High, High (BL-D2)

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

-- The module on fakes. r.calls: { "paint", link, colour, with_state } and { "settle", link } in order;
-- r.timers: every arm, { ms, cb, at, cancelled, fired }; r.randoms: every random's { lo, hi }.
-- opts: no_clock (no `now` option), no_log (the default log).
local function rig(opts)
	opts = opts or {}
	local r = { calls = {}, timers = {}, randoms = {}, clock = 1000, log = fake_log() }
	r.b = breezeleds.new({
		paint = function(link, colour, with_state)
			r.calls[#r.calls + 1] = { "paint", link, colour, with_state }
			if r.fail_paint and r.fail_paint(link, colour) then
				error("paint refused")
			end
		end,
		settle = function(link)
			r.calls[#r.calls + 1] = { "settle", link }
			if r.fail_settle and r.fail_settle(link) then
				error("settle refused")
			end
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
			if r.pick then
				return r.pick(lo, hi)
			end
			return lo
		end,
		now = not opts.no_clock and function() return r.clock end or nil,
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

-- "2=H!" and "~2" through the pixel order to calls.
local function calls_of(order, frame)
	local out = {}
	for token in frame:gmatch("%S+") do
		local settled = token:match("^~(%d+)$")
		if settled then
			out[#out + 1] = { "settle", (assert(order[tonumber(settled)], token)) }
		else
			local pos, colour, bang = token:match("^(%d+)=(%u)(!?)$")
			assert(pos and COLOURS[colour], "bad token " .. token)
			out[#out + 1] = { "paint", (assert(order[tonumber(pos)], token)), COLOURS[colour], bang == "!" }
		end
	end
	return out
end

-- frames[1] against `first` (the calls of the call that started it; nil: the next tick's), then one tick each.
local function play(r, order, frames, first)
	if first == nil then
		first = tick(r)
	end
	assert.same(calls_of(order, frames[1]), first, "frame 1")
	for i = 2, #frames do
		assert.same(calls_of(order, frames[i]), tick(r), "frame " .. i)
	end
end

local function reversed(list)
	local out = {}
	for i = #list, 1, -1 do
		out[#out + 1] = list[i]
	end
	return out
end

local function shuffled(list)
	local out = {}
	for i = #list, 1, -1 do
		out[#out + 1] = list[i]
	end
	out[#out + 1] = list[1] -- a duplicate
	return out
end

-- Configured, bound and blowing: the rising wipe's first frame is returned.
local function start(r, list, bottom, strength)
	r.b:configure({ enabled = true, per_speed = true, bottom = bottom or 1, step = 300 })
	r.b:set_pixels(list or HOUSE)
	r.b:update({ breeze = true, strength = strength or 2, online = true })
	return take(r)
end

-- Through the rising wipe to the first rest.
local function to_rest(r, list, bottom, strength)
	start(r, list, bottom, strength)
	for _ = 1, #(list or HOUSE) do
		tick(r)
	end
	assert.equal("rest", r.b:debug().phase)
	take(r)
end

-- A gust's first `steps` steps (the rest's expiry is the first).
local function into_gust(r, steps)
	for _ = 1, steps do
		tick(r)
	end
	assert.equal("gust", r.b:debug().phase)
end

local function held_list(r, list)
	local out = {}
	for _, link in ipairs(list) do
		out[#out + 1] = r.b:held(link)
	end
	return out
end

local FRAMES = {
	[1] = {
		enter = { "1=H!", "1=B" },
		gust = { "1=H", "1=T", "1=B" },
		leave = { "1=H", "~1" },
	},
	[2] = {
		enter = { "1=H!", "1=B 2=H!", "2=B" },
		gust = { "1=H", "1=T 2=H", "1=B 2=T", "2=B" },
		leave = { "2=H", "1=H ~2", "~1" },
	},
	[4] = {
		enter = { "1=H!", "1=B 2=H!", "2=B 3=H!", "3=B 4=H!", "4=B" },
		gust = { "1=H", "1=T 2=H", "1=B 2=T 3=H", "2=B 3=T 4=H", "3=B 4=T", "4=B" },
		leave = { "4=H", "3=H ~4", "2=H ~3", "1=H ~2", "~1" },
	},
	[6] = {
		enter = { "1=H!", "1=B 2=H!", "2=B 3=H!", "3=B 4=H!", "4=B 5=H!", "5=B 6=H!", "6=B" },
		gust = { "1=H", "1=T 2=H", "1=B 2=T 3=H", "2=B 3=T 4=H", "3=B 4=T 5=H", "4=B 5=T 6=H", "5=B 6=T",
			"6=B" },
		leave = { "6=H", "5=H ~6", "4=H ~5", "3=H ~4", "2=H ~3", "1=H ~2", "~1" },
	},
}

local LISTS = { [1] = { 303 }, [2] = { 302, 303 }, [4] = HOUSE, [6] = { 301, 302, 303, 304, 305, 306 } }

describe("fan.breezeleds", function()
	before_each(function()
		breezeleds.RECOLOUR_NEEDS_STATE = false
		log.sink = function() end
	end)

	after_each(function()
		breezeleds.RECOLOUR_NEEDS_STATE = SHIPPED_RECOLOUR
		log.sink = REAL_SINK
	end)

	describe("the constants (section 3.1)", function()
		it("ships the palette, the rest ranges, the step bounds and RECOLOUR_NEEDS_STATE true", function()
			assert.equal("ffffff", HEAD)
			assert.equal("00ffff", TRAIL)
			assert.equal("0080ff", BASE)
			assert.same({ [1] = { 6000, 9000 }, [2] = { 3500, 6000 }, [3] = { 1500, 3500 } }, breezeleds.REST_MS)
			assert.equal(200, breezeleds.STEP_MIN)
			assert.equal(600, breezeleds.STEP_MAX)
			assert.equal(300, breezeleds.STEP_DEFAULT)
			assert.is_true(SHIPPED_RECOLOUR)
		end)
	end)

	describe("frames: the rising wipe, a gust and the falling wipe (BL-D6 to BL-D8)", function()
		for _, n in ipairs({ 1, 2, 4, 6 }) do
			for _, bottom in ipairs({ 1, 6 }) do
				local order = bottom == 6 and reversed(LISTS[n]) or LISTS[n]
				it(string.format("plays them over %d pixel(s) with the bottom at speed %d", n, bottom), function()
					local r = rig()
					local frames = FRAMES[n]

					-- Breeze starts: every pixel is taken at once, the head is on pixel 1.
					local first = start(r, shuffled(LISTS[n]), bottom)
					for _, link in ipairs(order) do
						assert.is_true(r.b:held(link), "taken at the start of the enter")
					end
					assert.same(order, r.b:debug().pixels)
					play(r, order, frames.enter, first)
					assert.equal("rest", r.b:debug().phase)
					assert.equal(3500, pending(r).ms, "the rest random(lo, hi) gave")
					assert.same({ 3500, 6000 }, r.randoms[#r.randoms])

					-- The rest's expiry is the gust's first step; the gust is N + 2 steps, then a rest.
					assert.equal(n + 2, #frames.gust)
					play(r, order, frames.gust)
					assert.equal("rest", r.b:debug().phase)
					assert.equal(2, #r.randoms)

					-- Breeze ends: the falling wipe, each pixel settled as the head leaves it, then idle.
					r.b:update({ breeze = false, strength = nil, online = true })
					play(r, order, frames.leave, take(r))
					assert.equal("idle", r.b:debug().phase)
					assert.is_nil(pending(r), "nothing pending once idle")
					for _, link in ipairs(order) do
						assert.is_false(r.b:held(link))
					end
				end)
			end
		end

		it("sends the house's links themselves: Low to High rising, High to Low falling, reversed for Speed 6",
			function()
				local r = rig()
				local first = start(r, HOUSE, 1)
				assert.same({ { "paint", 302, HEAD, true } }, first)
				assert.same({ { "paint", 302, BASE, false }, { "paint", 303, HEAD, true } }, tick(r))

				local top = rig()
				first = start(top, HOUSE, 6)
				assert.same({ { "paint", 305, HEAD, true } }, first)
				assert.same({ { "paint", 305, BASE, false }, { "paint", 304, HEAD, true } }, tick(top))
			end)

		it("steps at the step time; a gust waits for its rest", function()
			local r = rig()
			start(r)
			assert.equal(300, pending(r).ms)
			r.b:configure({ step = 450 })
			assert.equal(300, pending(r).ms, "a step change waits for the next arm")
			tick(r)
			assert.equal(450, pending(r).ms)
		end)
	end)

	describe("with_state (BL-D14)", function()
		it("ships true for every paint: both messages each time", function()
			breezeleds.RECOLOUR_NEEDS_STATE = true
			local r = rig()
			local all = start(r)
			local function add(calls)
				for _, call in ipairs(calls) do
					all[#all + 1] = call
				end
			end
			for _ = 1, 4 + 6 do -- the enter, then a gust
				add(tick(r))
			end
			r.b:update({ breeze = false })
			add(take(r))
			for _ = 1, 4 do -- the leave
				add(tick(r))
			end
			local paints = 0
			for _, call in ipairs(all) do
				if call[1] == "paint" then
					paints = paints + 1
					assert.is_true(call[4], "with_state on every paint while RECOLOUR_NEEDS_STATE is true")
				end
			end
			assert.equal(8 + 12 + 4, paints, "8 for the enter, 12 for a gust of 4, 4 heads for the leave")
		end)

		it("is true for a pixel's first paint after it is taken again, false for a recolour", function()
			local r = rig()
			to_rest(r)
			r.b:update({ online = false })
			take(r)
			r.b:update({ online = true })
			assert.same(calls_of(HOUSE, "1=H!"), take(r), "taken again: the first paint carries the state")
			assert.same(calls_of(HOUSE, "1=B 2=H!"), tick(r))
		end)
	end)

	describe("rests (BL-D7)", function()
		local function rest_of(strength)
			local r = rig()
			to_rest(r, HOUSE, 1, strength)
			return r.randoms[#r.randoms], pending(r).ms
		end

		it("rests 6 to 9 s at strength 1, 3.5 to 6 s at 2, 1.5 to 3.5 s at 3", function()
			assert.same({ 6000, 9000 }, (rest_of(1)))
			assert.same({ 3500, 6000 }, (rest_of(2)))
			assert.same({ 1500, 3500 }, (rest_of(3)))
		end)

		it("rests as strength 2 when the strength is unknown or not 1 to 3", function()
			local r = rig()
			r.b:configure({ enabled = true, per_speed = true, bottom = 1, step = 300 })
			r.b:set_pixels(HOUSE)
			r.b:update({ breeze = true, online = true })
			for _ = 1, 4 do
				tick(r)
			end
			assert.same({ 3500, 6000 }, r.randoms[1])
			assert.same({ 3500, 6000 }, (rest_of(7)))
			assert.same({ 3500, 6000 }, (rest_of(0)))
			assert.same({ 3500, 6000 }, (rest_of(2.5)))
		end)

		it("arms the time random gave, held within the range", function()
			local r = rig()
			r.pick = function(_, hi) return hi end
			to_rest(r)
			assert.equal(6000, pending(r).ms)
			local low = rig()
			low.pick = function() return 10 end
			to_rest(low)
			assert.equal(3500, pending(low).ms, "below the range: its low end")
		end)

		it("takes a strength change from the next rest, without re-arming", function()
			local r = rig()
			to_rest(r, HOUSE, 1, 1)
			local resting = pending(r)
			assert.same({ 6000, 9000 }, r.randoms[#r.randoms])
			r.b:update({ breeze = true, strength = 3, online = true })
			assert.same({}, take(r))
			assert.equal(resting, pending(r), "the rest keeps its timer")
			assert.equal(1, #r.randoms)
			into_gust(r, 3)
			for _ = 1, 3 do
				tick(r)
			end
			assert.equal("rest", r.b:debug().phase)
			assert.same({ 1500, 3500 }, r.randoms[#r.randoms], "the next rest takes the new strength")
			into_gust(r, 3)
			r.b:update({ breeze = true, strength = 1, online = true })
			assert.same({}, take(r), "mid-gust: nothing sent")
			for _ = 1, 3 do
				tick(r)
			end
			assert.same({ 6000, 9000 }, r.randoms[#r.randoms])
			assert.same({ 6000, 9000 }, r.b:debug().rest)
		end)

		it("keeps the strength on an update without breeze (the phase listener sends online alone)", function()
			local r = rig()
			to_rest(r, HOUSE, 1, 3)
			r.b:update({ online = true })
			assert.same({ 1500, 3500 }, r.b:debug().rest)
			r.b:update({ breeze = true })
			assert.same({ 3500, 6000 }, r.b:debug().rest, "with breeze, a missing strength is unknown")
		end)
	end)

	describe("late ticks (BL-D13: no burst)", function()
		it("applies every step that fell due at once, each pixel only its final colour", function()
			local r = rig()
			start(r)
			assert.same(calls_of(HOUSE, "1=B 2=B! 3=B! 4=H!"), tick(r, 600), "three steps due")
			assert.equal(300, pending(r).ms, "back on the cadence")
			local s = rig()
			start(s)
			assert.same(calls_of(HOUSE, "1=B 2=B! 3=B! 4=H!"), tick(s, 700))
			assert.equal(200, pending(s).ms, "the next step when it falls due, not a full step later")
		end)

		it("ends an enter in its rest when more steps fell due than it had left", function()
			local r = rig()
			start(r)
			assert.same(calls_of(HOUSE, "1=B 2=B! 3=B! 4=B!"), tick(r, 5000))
			assert.equal("rest", r.b:debug().phase)
			assert.equal(1, #r.randoms, "the rest armed once")
		end)

		it("jumps into a gust when its rest's timer fires late", function()
			local r = rig()
			to_rest(r)
			assert.same(calls_of(HOUSE, "2=T 3=H"), tick(r, 600))
			assert.equal(300, pending(r).ms)
			assert.same(calls_of(HOUSE, "2=B 3=B 4=T"), tick(r, 300), "two more: the head above the top")
		end)

		it("ends a gust in its rest", function()
			local r = rig()
			to_rest(r)
			into_gust(r, 2)
			take(r)
			assert.same(calls_of(HOUSE, "1=B 2=B"), tick(r, 4000))
			assert.equal("rest", r.b:debug().phase)
		end)

		it("settles every pixel a leave wipe passed", function()
			local r = rig()
			to_rest(r)
			r.b:update({ breeze = false })
			assert.same(calls_of(HOUSE, "4=H"), take(r))
			assert.same(calls_of(HOUSE, "1=H ~2 ~3 ~4"), tick(r, 600))
			assert.same(calls_of(HOUSE, "~1"), tick(r))
			assert.equal("idle", r.b:debug().phase)

			local s = rig()
			to_rest(s)
			s.b:update({ breeze = false })
			take(s)
			assert.same(calls_of(HOUSE, "~1 ~2 ~3 ~4"), tick(s, 60000), "past the end: every pixel, once")
			assert.equal("idle", s.b:debug().phase)
			assert.is_nil(pending(s))
		end)

		it("steps one at a time without a clock", function()
			local r = rig({ no_clock = true })
			start(r)
			assert.same(calls_of(HOUSE, "1=B 2=H!"), tick(r, 5000))
			assert.equal(300, pending(r).ms)
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

	describe("interruptions (BL-D10)", function()
		it("leave during the enter: the falling wipe from the top at once; unreached pixels keep their frame",
			function()
				local r = rig()
				start(r)
				tick(r) -- 302 BASE, 303 HEAD, 304 and 305 held, not painted
				r.b:update({ breeze = false })
				assert.same(calls_of(HOUSE, "4=H!"), take(r))
				assert.same(calls_of(HOUSE, "3=H! ~4"), tick(r))
				assert.same(calls_of(HOUSE, "~3"), tick(r), "303 shows HEAD already")
				assert.same(calls_of(HOUSE, "1=H ~2"), tick(r))
				assert.same(calls_of(HOUSE, "~1"), tick(r))
				assert.equal("idle", r.b:debug().phase)
			end)

		it("leave during a gust: the falling wipe from the top at once", function()
			local r = rig()
			to_rest(r)
			into_gust(r, 3) -- 302 BASE, 303 TRAIL, 304 HEAD
			local gusting = pending(r)
			r.b:update({ breeze = false })
			assert.is_true(gusting.cancelled)
			assert.same(calls_of(HOUSE, "4=H"), take(r))
			assert.same(calls_of(HOUSE, "~4"), tick(r))
			assert.same(calls_of(HOUSE, "2=H ~3"), tick(r))
			assert.same(calls_of(HOUSE, "1=H ~2"), tick(r))
			assert.same(calls_of(HOUSE, "~1"), tick(r))
		end)

		it("leave during a rest, Off or a speed alike: the falling wipe", function()
			local r = rig()
			to_rest(r)
			r.b:update({ breeze = false, online = true })
			assert.same(calls_of(HOUSE, "4=H"), take(r))
			assert.equal("leave", r.b:debug().phase)
		end)

		it("Breeze again during the leave: the rising wipe from pixel 1, taking back settled pixels as it passes",
			function()
				local r = rig()
				to_rest(r)
				r.b:update({ breeze = false })
				take(r)
				tick(r) -- 304 HEAD, 305 settled
				r.b:update({ breeze = true, strength = 2 })
				assert.same(calls_of(HOUSE, "1=H"), take(r))
				assert.same({ true, true, true, false }, held_list(r, HOUSE), "305 stays with the links")
				assert.equal("enter", r.b:debug().phase)
				assert.same(calls_of(HOUSE, "1=B 2=H"), tick(r))
				assert.same(calls_of(HOUSE, "2=B"), tick(r), "304 shows HEAD already")
				assert.same(calls_of(HOUSE, "3=B 4=H!"), tick(r), "305 taken back: its first paint again")
				assert.is_true(r.b:held(305))
				assert.same(calls_of(HOUSE, "4=B"), tick(r))
				assert.equal("rest", r.b:debug().phase)
			end)

		it("the newest shown state wins: leave, Breeze, leave again", function()
			local r = rig()
			to_rest(r)
			r.b:update({ breeze = false })
			tick(r)
			r.b:update({ breeze = true })
			take(r) -- 302 HEAD; 303 BASE, 304 HEAD held; 305 with the links
			r.b:update({ breeze = false })
			assert.same({}, take(r), "the top held pixel, 304, shows HEAD already")
			assert.equal(3, r.b:debug().head)
			assert.same(calls_of(HOUSE, "2=H ~3"), tick(r))
			assert.same(calls_of(HOUSE, "~2"), tick(r), "302 shows HEAD already")
			assert.same(calls_of(HOUSE, "~1"), tick(r))
			assert.equal("idle", r.b:debug().phase)
		end)
	end)

	describe("settling at once, no wipe (BL-D11)", function()
		local function gusting()
			local r = rig()
			to_rest(r)
			into_gust(r, 2)
			take(r)
			return r, pending(r)
		end

		local SETTLED = calls_of(HOUSE, "~1 ~2 ~3 ~4")

		it("when the fan goes offline, and plays the rising wipe again when it is back in Breeze", function()
			local r, timer = gusting()
			r.b:update({ online = false })
			assert.same(SETTLED, take(r))
			assert.is_true(timer.cancelled)
			assert.is_nil(pending(r))
			assert.equal("idle", r.b:debug().phase)
			r.b:update({ online = true })
			assert.same(calls_of(HOUSE, "1=H!"), take(r))
			assert.equal("enter", r.b:debug().phase)
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

		it("during the enter, the pixels the head never reached included", function()
			local r = rig()
			start(r)
			r.b:update({ online = false })
			assert.same(SETTLED, take(r))
		end)

		it("during the leave: what is still held", function()
			local r = rig()
			to_rest(r)
			r.b:update({ breeze = false })
			tick(r)
			take(r)
			r.b:update({ online = false })
			assert.same(calls_of(HOUSE, "~1 ~2 ~3"), take(r))
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

	describe("set_pixels while running (BL-D16)", function()
		it("takes a new pixel during a rest and paints it BASE with the state", function()
			local r = rig()
			to_rest(r)
			local resting = pending(r)
			r.b:set_pixels({ 305, 301, 304, 303, 302 })
			assert.same({ { "paint", 301, BASE, true } }, take(r))
			assert.is_true(r.b:held(301))
			assert.equal(resting, pending(r), "the rest goes on")
			assert.same({ 301, 302, 303, 304, 305 }, r.b:debug().pixels)
		end)

		it("drops a removed pixel without any call", function()
			local r = rig()
			to_rest(r)
			r.b:set_pixels({ 302, 303, 304 })
			assert.same({}, take(r))
			assert.is_false(r.b:held(305))
			assert.equal("rest", r.b:debug().phase)
			into_gust(r, 1)
			for _ = 1, 4 do
				tick(r)
			end
			assert.equal("rest", r.b:debug().phase, "the gust is now 3 + 2 steps")
		end)

		it("paints a pixel bound above the rising head BASE, then the head passes it", function()
			local r = rig()
			start(r, { 302, 303, 304 })
			r.b:set_pixels({ 302, 303, 304, 306 })
			assert.same({ { "paint", 306, BASE, true } }, take(r))
			local order = { 302, 303, 304, 306 }
			assert.same(calls_of(order, "1=B 2=H!"), tick(r))
			assert.same(calls_of(order, "2=B 3=H!"), tick(r))
			assert.same(calls_of(order, "3=B 4=H"), tick(r))
			assert.same(calls_of(order, "4=B"), tick(r))
		end)

		it("paints a pixel bound during a gust its frame colour; the gust grows by one step", function()
			local r = rig()
			to_rest(r)
			into_gust(r, 2) -- 302 TRAIL, 303 HEAD
			take(r)
			r.b:set_pixels({ 302, 303, 304, 305, 306 })
			assert.same({ { "paint", 306, BASE, true } }, take(r))
			local order = { 302, 303, 304, 305, 306 }
			assert.same(calls_of(order, "1=B 2=T 3=H"), tick(r))
			assert.same(calls_of(order, "2=B 3=T 4=H"), tick(r))
			assert.same(calls_of(order, "3=B 4=T 5=H"), tick(r))
			assert.same(calls_of(order, "4=B 5=T"), tick(r))
			assert.same(calls_of(order, "5=B"), tick(r))
			assert.equal("rest", r.b:debug().phase)
		end)

		it("repaints the pixels a new order moved, from the same head position", function()
			local r = rig()
			to_rest(r)
			into_gust(r, 2) -- 302 TRAIL, 303 HEAD
			take(r)
			r.b:set_pixels({ 301, 302, 303, 304, 305 })
			-- 301 joins as pixel 1, the trail; 302 becomes the head; 303 goes back to BASE.
			assert.same({ { "paint", 301, TRAIL, true }, { "paint", 302, HEAD, false }, { "paint", 303, BASE, false } },
				take(r))
		end)

		it("does not take a pixel bound during the leave: Breeze has ended", function()
			local r = rig()
			to_rest(r)
			r.b:update({ breeze = false })
			take(r)
			r.b:set_pixels({ 301, 302, 303, 304, 305 })
			assert.is_false(r.b:held(301))
			-- 301 is pixel 1 now: the head is still at pixel 4 (304), so 305 above it is settled.
			assert.same({ { "paint", 304, HEAD, false }, { "settle", 305 } }, take(r))
			assert.same({ { "paint", 303, HEAD, false }, { "settle", 304 } }, tick(r))
			assert.same({ { "paint", 302, HEAD, false }, { "settle", 303 } }, tick(r))
			assert.same({ { "settle", 302 } }, tick(r), "301 is not held: nothing shown there")
			assert.equal("idle", r.b:debug().phase)
		end)

		it("starts the rising wipe when the first pixel is bound while Breeze blows", function()
			local r = rig()
			r.b:configure({ enabled = true, per_speed = true, bottom = 1, step = 300 })
			r.b:update({ breeze = true, strength = 2, online = true })
			assert.same({}, take(r))
			assert.is_nil(pending(r))
			r.b:set_pixels({ 304 })
			assert.same({ { "paint", 304, HEAD, true } }, take(r))
		end)

		it("keeps only the speed links 301 to 306, each once", function()
			local r = rig()
			start(r, { 300, 311, 307, 308, 200, 304, "302", 304, 302.5, "x" })
			assert.same({ 302, 304 }, r.b:debug().pixels)
		end)
	end)

	describe("repaint (BL-D15)", function()
		it("paints a held pixel its frame colour with the state, during a rest", function()
			local r = rig()
			to_rest(r)
			assert.is_true(r.b:repaint(303))
			assert.same({ { "paint", 303, BASE, true } }, take(r))
		end)

		it("paints the head and the trail where they are", function()
			local r = rig()
			start(r)
			r.b:repaint(302)
			assert.same({ { "paint", 302, HEAD, true } }, take(r))
			local s = rig()
			to_rest(s)
			into_gust(s, 2)
			take(s)
			s.b:repaint(302)
			s.b:repaint(303)
			assert.same({ { "paint", 302, TRAIL, true }, { "paint", 303, HEAD, true } }, take(s))
		end)

		it("paints a held pixel the rising head has not reached BASE; the head passes it as a recolour", function()
			local r = rig()
			start(r)
			assert.is_true(r.b:repaint(305))
			assert.same({ { "paint", 305, BASE, true } }, take(r))
			tick(r)
			tick(r)
			assert.same(calls_of(HOUSE, "3=B 4=H"), tick(r), "305 painted already: no state")
		end)

		it("paints a pixel the falling head has not reached its last frame", function()
			local r = rig()
			to_rest(r)
			into_gust(r, 3) -- 303 TRAIL
			r.b:update({ breeze = false })
			take(r)
			r.b:repaint(303)
			r.b:repaint(305)
			assert.same({ { "paint", 303, TRAIL, true }, { "paint", 305, HEAD, true } }, take(r))
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
			to_rest(r)
			into_gust(r, 2)
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
		it("logs a paint that fails and paints the pixel again at its next frame", function()
			local r = rig()
			local failed = false
			r.fail_paint = function()
				if not failed then
					failed = true
					return true
				end
				return false
			end
			assert.has_no.errors(function() start(r) end)
			assert.is_true(r.log.has("warn", "link 302 could not be painted"))
			assert.is_true(r.b:held(302))
			assert.is_not_nil(pending(r), "the animation goes on")
			assert.same(calls_of(HOUSE, "1=B! 2=H!"), tick(r), "302 never got a frame: the next carries the state")
		end)

		it("logs a settle that fails and goes on with the wipe", function()
			local r = rig()
			to_rest(r)
			r.fail_settle = function(link) return link == 305 end
			r.b:update({ breeze = false })
			take(r)
			local calls
			assert.has_no.errors(function() calls = tick(r) end)
			assert.same(calls_of(HOUSE, "3=H ~4"), calls)
			assert.is_true(r.log.has("warn", "link 305 could not be settled"))
			assert.is_false(r.b:held(305))
			tick(r)
			tick(r)
			tick(r)
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
			assert.same(calls_of(HOUSE, "4=H!"), take(r))
		end)

		it("rests the middle of the range when random fails", function()
			local r = rig()
			r.fail_random = true
			assert.has_no.errors(function() to_rest(r) end)
			assert.equal(4750, pending(r).ms)
			assert.is_true(r.log.has("warn", "no random rest"))
		end)

		it("logs through common.log when no log is given, and a cancel that fails", function()
			local lines = {}
			log.sink = function(line) lines[#lines + 1] = line end
			local r = rig({ no_log = true })
			r.fail_paint = function() return true end
			start(r)
			local found = false
			for _, line in ipairs(lines) do
				if line:find("could not be painted", 1, true) then
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
			r.b:configure({ enabled = true, per_speed = true, bottom = 1, step = 300 })
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
			tick(r)
			same_again(r)
			for _ = 1, 3 do
				tick(r)
			end
			assert.equal("rest", r.b:debug().phase)
			same_again(r)
			into_gust(r, 2)
			take(r)
			same_again(r)
			r.b:update({ breeze = false, strength = 2, online = true })
			take(r)
			same_again(r)
			tick(r)
			same_again(r)
		end)

		it("Breeze On while it blows restarts nothing (BL7)", function()
			local r = rig()
			to_rest(r)
			r.b:update({ breeze = true, strength = 2, online = true })
			r.b:update({ breeze = true, strength = 2, online = true })
			assert.same({}, take(r))
		end)

		it("a step change sends nothing and re-arms nothing", function()
			local r = rig()
			to_rest(r)
			into_gust(r, 1)
			take(r)
			local timer = pending(r)
			r.b:configure({ step = 500 })
			assert.same({}, take(r))
			assert.equal(timer, pending(r))
			tick(r)
			assert.equal(500, pending(r).ms)
		end)

		it("a step outside the range is held within it", function()
			local r = rig()
			r.b:configure({ step = 100 })
			assert.equal(200, r.b:debug().step)
			r.b:configure({ step = 900 })
			assert.equal(600, r.b:debug().step)
			r.b:configure({ step = "450" })
			assert.equal(450, r.b:debug().step)
			r.b:configure({ step = "fast" })
			assert.equal(300, r.b:debug().step)
		end)
	end)

	describe("not active (section 3.1)", function()
		local ALL = { enabled = true, per_speed = true, online = true, breeze = true, pixels = true }

		for missing in pairs(ALL) do
			it("without " .. missing .. ": nothing sent, nothing armed, and the rising wipe once it comes", function()
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
				assert.same(calls_of(HOUSE, "1=H!"), take(r))
			end)
		end

		it("turns on while Breeze blows: the rising wipe at once (BL31)", function()
			local r = rig()
			r.b:configure({ enabled = false, per_speed = true })
			r.b:set_pixels(HOUSE)
			r.b:update({ breeze = true, strength = 2, online = true })
			assert.same({}, take(r))
			r.b:configure({ enabled = true })
			assert.same(calls_of(HOUSE, "1=H!"), take(r))
		end)

		it("Breeze ending while idle sends nothing", function()
			local r = rig()
			r.b:configure({ enabled = true, per_speed = true })
			r.b:set_pixels(HOUSE)
			r.b:update({ breeze = false, online = true })
			assert.same({}, take(r))
		end)
	end)

	describe("the bottom (BL-D4)", function()
		it("changed during a gust: the cycle restarts with a rest, every pixel BASE, no wipe", function()
			local r = rig()
			to_rest(r)
			into_gust(r, 2) -- 302 TRAIL, 303 HEAD
			take(r)
			local timer = pending(r)
			r.b:configure({ bottom = 6 })
			assert.same({ { "paint", 303, BASE, false }, { "paint", 302, BASE, false } }, take(r))
			assert.is_true(timer.cancelled)
			assert.equal("rest", r.b:debug().phase)
			assert.equal(2, #r.randoms)
			assert.same({ 305, 304, 303, 302 }, r.b:debug().pixels)
			assert.same(calls_of({ 305, 304, 303, 302 }, "1=H"), tick(r), "the next gust rises from 305")
		end)

		it("changed during the enter: a rest with every pixel BASE", function()
			local r = rig()
			start(r)
			r.b:configure({ bottom = 6 })
			-- New order 305, 304, 303, 302: none painted yet but 302, which was the head.
			assert.same({ { "paint", 305, BASE, true }, { "paint", 304, BASE, true }, { "paint", 303, BASE, true },
				{ "paint", 302, BASE, false } }, take(r))
			assert.equal("rest", r.b:debug().phase)
		end)

		it("changed during a rest: the rest starts again, nothing sent", function()
			local r = rig()
			to_rest(r)
			local timer = pending(r)
			r.b:configure({ bottom = 6 })
			assert.same({}, take(r))
			assert.is_true(timer.cancelled)
			assert.is_not_nil(pending(r))
			assert.equal(2, #r.randoms)
		end)

		it("changed during the leave: what is still held is settled at once", function()
			local r = rig()
			to_rest(r)
			r.b:update({ breeze = false })
			tick(r)
			take(r)
			r.b:configure({ bottom = 6 })
			-- The new order lists 304, 303, 302 from the bottom.
			assert.same({ { "settle", 304 }, { "settle", 303 }, { "settle", 302 } }, take(r))
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
		it("shows the phase, the pixels in order, the held set, the step, the rest range and the frame", function()
			local r = rig()
			r.b:configure({ enabled = true, per_speed = true, bottom = 6, step = 250 })
			r.b:set_pixels(HOUSE)
			r.b:update({ breeze = true, strength = 3, online = true })
			for _ = 1, 4 do
				tick(r)
			end
			into_gust(r, 2)
			local d = r.b:debug()
			assert.equal("gust", d.phase)
			assert.equal(2, d.head)
			assert.same({ 305, 304, 303, 302 }, d.pixels)
			assert.same({ [302] = true, [303] = true, [304] = true, [305] = true }, d.held)
			assert.equal(250, d.step)
			assert.same({ 1500, 3500 }, d.rest)
			assert.same({ [305] = TRAIL, [304] = HEAD, [303] = BASE, [302] = BASE }, d.frame)
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
			assert.equal(300, d.step)
			assert.same({ 3500, 6000 }, d.rest)
			assert.is_false(d.active)
			assert.is_false(d.pending)
		end)
	end)
end)
