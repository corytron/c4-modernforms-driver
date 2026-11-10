-- fan.speedleds on fakes: the speed LED chase (#159, docs/speed-leds-design.md section 1, SL-D1 to SL-D19, the
-- interface of section 3.1 and the tests of section 5; SL-D18 is #172, no double blink at the edges; SL-D19 is
-- #177, a new run's first chase 2.5 s after it starts, then one every rest). The paint,
-- light and settle calls are recorded in order and replayed on a keypad that behaves as the house keypad was
-- measured to (#137): a colour preloaded while dark stays dark, MATCH_LED_STATE shows the loaded colour or dark, and
-- a settle shows what the links would show (lit at rest in the speed's colour, or dark). The timer records its ms
-- and callback and the spec fires the callbacks by hand on a fake clock.
--
-- What the keypad shows is written one letter a pixel, along the lane (where the dot starts first): "#" lit in
-- the chase colour, "x" lit in another, "." dark, "?" unknown.
--
-- Unless a spec says otherwise: the house's four buttons (302 Low to 305 High, bottom = 1), Speeds 2 to 5, Per
-- speed, the shipped rest of 5 s, the fan at speed 3 blowing down (forward, so the lane is 305, 304, 303, 302) and
-- only the Medium button (303) lit at rest, in purple.

local speedleds = require("fan.speedleds")

local REST_MS = 5000 -- the shipped rest (SL-D6, #177), what start() configures unless told otherwise
local FIRST_MS = 2500 -- a new run's first chase (SL-D19, #177)
local HOUSE = { 302, 303, 304, 305 } -- Low, Medium, Med-High, High
local PURPLE = "8000ff"
local COLOURS = { [1] = "ff0000", [2] = "00ff00", [3] = PURPLE, [4] = "0000ff", [5] = "ffff00", [6] = "00ffff" }
local SHIPPED_BUDGET = speedleds.BUDGET_PER_S

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

local function copy(t)
	local out = {}
	for k, v in pairs(t) do
		out[k] = v
	end
	return out
end

-- The engine on fakes. r.calls: { "paint", link, colour, with_state, preload }, { "light", link, lit } and
-- { "settle", link } in order; r.stamps: the clock of every message (a paint 1, 2 with the state; a light 1; a
-- settle 2); r.kp: the keypad, [link] = { lit, loaded }; r.rest: [link] = true for a link lit at rest (what
-- lit(link) answers); r.colours: colour(speed); r.blocked: [link] = true while Breeze holds it; r.timers: every
-- arm, { ms, cb, at, cancelled, fired }. opts: no_clock (no `now`), no_blocked (no `blocked`).
local function rig(opts)
	opts = opts or {}
	local r = {
		calls = {}, stamps = {}, timers = {}, clock = 1000, log = fake_log(), kp = {},
		rest = { [303] = true }, colours = copy(COLOURS), blocked = {}, speed = 3,
	}
	local function count(n)
		for _ = 1, n do
			r.stamps[#r.stamps + 1] = r.clock
		end
	end
	local function pad(link)
		r.kp[link] = r.kp[link] or {}
		return r.kp[link]
	end
	r.s = speedleds.new({
		paint = function(link, colour, with_state, preload)
			r.calls[#r.calls + 1] = { "paint", link, colour, with_state, preload }
			count(with_state and 2 or 1)
			if r.fail_paint and r.fail_paint(link) then
				error("paint refused")
			end
			local k = pad(link)
			k.loaded = colour
			if with_state then
				k.lit = true
			end
		end,
		light = function(link, lit)
			r.calls[#r.calls + 1] = { "light", link, lit }
			count(1)
			if r.fail_light and r.fail_light(link, lit) then
				error("light refused")
			end
			pad(link).lit = lit
		end,
		settle = function(link)
			r.calls[#r.calls + 1] = { "settle", link }
			count(2)
			if r.fail_settle and r.fail_settle(link) then
				error("settle refused")
			end
			-- The links send their truth: lit at rest in the speed's colour, or dark with its own colour.
			local lit = r.rest[link] == true
			r.kp[link] = { lit = lit, loaded = lit and r.colours[r.speed] or "own" }
		end,
		lit = function(link)
			if r.fail_lit then
				error("lit refused")
			end
			return r.rest[link] == true
		end,
		colour = function(speed)
			if r.fail_colour then
				error("colour refused")
			end
			return r.colours[speed]
		end,
		blocked = not opts.no_blocked and function(link)
			if r.fail_blocked then
				error("blocked refused")
			end
			return r.blocked[link] == true
		end or nil,
		timer = function(ms, cb)
			if r.fail_timer then
				error("no timer")
			end
			local t = { ms = ms, cb = cb, at = r.clock, cancelled = false, fired = false }
			function t:Cancel()
				if r.fail_cancel then
					error("cannot cancel")
				end
				self.cancelled = true
			end
			r.timers[#r.timers + 1] = t
			return t
		end,
		now = not opts.no_clock and function()
			if r.fail_clock then
				error("no clock")
			end
			return r.clock
		end or nil,
		log = r.log,
	})
	return r
end

local function take(r)
	local calls = r.calls
	r.calls = {}
	return calls
end

-- The timers neither cancelled nor fired: one at a time.
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

-- The view the driver hands update, with `changes` on top (a key set to false is removed: unknown).
local function view(r, changes)
	local v = { fan_mode = true, speed = r.speed, online = true, direction = r.direction or "forward" }
	for k, value in pairs(changes or {}) do
		if value == false and k ~= "fan_mode" and k ~= "online" then
			v[k] = nil
		else
			v[k] = value
		end
	end
	return v
end

-- Configures the engine (o: speeds, bottom, rest, pixels, speed, direction, lit = the links lit at rest; by
-- default the house at speed 3, forward) and fills the keypad as the links left it; the calls and stamps are
-- cleared.
local function start(r, o)
	o = o or {}
	r.speed = o.speed or 3
	r.direction = o.direction or "forward"
	r.rest = o.lit or { [300 + r.speed] = true }
	r.pixels = o.pixels or HOUSE
	r.s:configure({ speeds = o.speeds or "2-5", per_speed = true, bottom = o.bottom or 1, rest = o.rest or 5 })
	r.s:set_pixels(r.pixels)
	for _, link in ipairs(r.pixels) do
		local lit = r.rest[link] == true
		r.kp[link] = { lit = lit, loaded = lit and r.colours[r.speed] or "own" }
	end
	r.s:update(view(r))
	r.calls, r.stamps = {}, {}
end

-- What the keypad shows along `lane`, one letter a pixel.
local function look(r, lane, colour)
	colour = colour or r.colours[r.speed]
	local out = {}
	for i, link in ipairs(lane) do
		local k = r.kp[link]
		if k == nil or k.lit == nil then
			out[i] = "?"
		elseif k.lit then
			out[i] = k.loaded == colour and "#" or "x"
		else
			out[i] = "."
		end
	end
	return table.concat(out)
end

-- Fires the pending timer (a run's first delay or the rest) and every step until the chase is over: every call,
-- the keypad after each frame, and the calls of each frame (frames[1] is frame 1, played when that timer fires).
local function run_chase(r)
	local lane = r.s:debug().lane
	local calls, looks, frames = {}, {}, {}
	for _ = 1, 40 do
		local frame = tick(r)
		for _, call in ipairs(frame) do
			calls[#calls + 1] = call
		end
		frames[#frames + 1] = frame
		looks[#looks + 1] = look(r, lane)
		if r.s:debug().state ~= "chasing" then
			return calls, looks, frames
		end
	end
	error("the chase never ended")
end

-- Fires every step of the chase that is playing until it is over; its calls.
local function finish(r)
	local calls = {}
	for _ = 1, 40 do
		if r.s:debug().state ~= "chasing" then
			return calls
		end
		for _, call in ipairs(tick(r)) do
			calls[#calls + 1] = call
		end
	end
	error("the chase never ended")
end

-- The blinks of a chase (#172): a link sent light(link, false) and then light(link, true) within one frame, so
-- the keypad turns it off and on again at once. Each as "link in frame f".
local function blinks(frames)
	local out = {}
	for f, frame in ipairs(frames) do
		local dark = {}
		for _, call in ipairs(frame) do
			if call[1] == "light" and call[3] == false then
				dark[call[2]] = true
			elseif call[1] == "light" and call[3] == true and dark[call[2]] then
				out[#out + 1] = string.format("%d in frame %d", call[2], f)
			end
		end
	end
	return out
end

-- What one link was sent, frame by frame: "f:preload", "f:light", "f:dark" or "f:settle", in order.
local function schedule(frames, link)
	local out = {}
	for f, frame in ipairs(frames) do
		for _, call in ipairs(frame) do
			if call[2] == link then
				local kind = call[1]
				if kind == "light" then
					kind = call[3] and "light" or "dark"
				elseif kind == "paint" and call[4] == false and call[5] == true then
					kind = "preload"
				end
				out[#out + 1] = string.format("%d:%s", f, kind)
			end
		end
	end
	return out
end

local function held_any(r)
	for link = 300, 307 do
		if r.s:held(link) then
			return true
		end
	end
	return false
end

-- The order the dot arrives in: the links of the light(link, true) calls before the last frame.
local function arrivals(calls, n)
	local out = {}
	for _, call in ipairs(calls) do
		if call[1] == "light" and call[3] == true and #out < n then
			out[#out + 1] = call[2]
		end
	end
	return out
end

local function settles(links)
	local out = {}
	for i, link in ipairs(links) do
		out[i] = { "settle", link }
	end
	return out
end

-- The house's chase at speed 3, forward (SL-D12): 13 messages. Medium is a middle place, so SL-D18 leaves it as is.
local HOUSE_CHASE = {
	{ "light", 303, false }, { "paint", 305, PURPLE, false, true }, { "light", 305, true },
	{ "paint", 304, PURPLE, false, true }, { "light", 304, true }, { "light", 305, false },
	{ "light", 303, true }, { "light", 304, false },
	{ "paint", 302, PURPLE, false, true }, { "light", 302, true }, { "light", 303, false },
	{ "light", 302, false }, { "light", 303, true },
}

describe("fan.speedleds", function()
	after_each(function()
		speedleds.BUDGET_PER_S = SHIPPED_BUDGET
	end)

	describe("constants (SL-D5, SL-D6, SL-D14, SL-D19)", function()
		it("has the contract's step table, rest, first delay and retry", function()
			assert.are.same({ [1] = 500, [2] = 400, [3] = 300, [4] = 200, [5] = 120, [6] = 100 }, speedleds.STEP_MS)
			assert.are.equal(5, speedleds.REST_DEFAULT)
			assert.are.equal(2500, speedleds.FIRST_MS)
			assert.are.equal(5, speedleds.REST_MIN)
			assert.are.equal(60, speedleds.REST_MAX)
			assert.are.equal(200, speedleds.RETRY_MS)
			assert.are.equal(30, speedleds.BUDGET_PER_S)
			assert.are.equal(1000, speedleds.WINDOW_MS)
		end)
	end)

	describe("the house chase (SL-D12)", function()
		it("sends the 13 messages in order and leaves Medium lit", function()
			local r = rig()
			start(r)
			assert.are.same({}, r.calls)
			assert.are.equal(FIRST_MS, pending(r).ms)
			local calls, looks = run_chase(r)
			assert.are.same(HOUSE_CHASE, calls)
			-- Lane 305, 304, 303, 302: the dot runs top to bottom; Medium relights at the end.
			assert.are.same({ "#...", ".#..", "..#.", "...#", "..#." }, looks)
			assert.is_false(held_any(r))
			local t = pending(r)
			assert.are.equal(REST_MS, t.ms)
			assert.are.equal("resting", r.s:debug().state)
		end)

		it("plays frame 1 at once and every later frame one step apart, held while it plays", function()
			local r = rig()
			start(r)
			local first = tick(r)
			assert.are.same({ HOUSE_CHASE[1], HOUSE_CHASE[2], HOUSE_CHASE[3] }, first)
			for _, link in ipairs(HOUSE) do
				assert.is_true(r.s:held(link))
			end
			assert.is_false(r.s:held(301))
			local d = r.s:debug()
			assert.are.equal("chasing", d.state)
			assert.are.same(HOUSE, d.held)
			assert.are.equal(PURPLE, d.colour)
			assert.are.same({ 303 }, d.lit)
			assert.are.equal(2, d.frame)
			assert.are.equal(5, d.frames)
			for _ = 1, 4 do
				assert.are.equal(300, pending(r).ms)
				tick(r)
			end
			assert.are.equal("resting", r.s:debug().state)
		end)

		it("plays the same 13 again after the rest: the preload is sent every chase", function()
			local r = rig()
			start(r)
			run_chase(r)
			local calls = run_chase(r)
			assert.are.same(HOUSE_CHASE, calls)
		end)

		it("reads the colour at the start of every chase (SL-D7)", function()
			local r = rig()
			start(r)
			run_chase(r)
			r.colours[3] = "ff00ff"
			for _, link in ipairs(HOUSE) do
				r.kp[link].loaded = r.kp[link].lit and "ff00ff" or "own" -- the links repainted the rest LED
			end
			local calls, looks = run_chase(r)
			assert.are.same({ "paint", 305, "ff00ff", false, true }, calls[2])
			assert.are.same({ "#...", ".#..", "..#.", "...#", "..#." }, looks)
		end)

		it("skips a chase while the speed has no colour, and rests again", function()
			local r = rig()
			start(r)
			r.colours[3] = nil
			assert.are.same({}, tick(r))
			assert.is_false(held_any(r))
			assert.are.equal(REST_MS, pending(r).ms)
			assert.are.equal("resting", r.s:debug().state)
			r.colours[3] = PURPLE
			assert.are.same({ HOUSE_CHASE[1], HOUSE_CHASE[2], HOUSE_CHASE[3] }, tick(r))
		end)
	end)

	describe("the order (SL-D4)", function()
		local cases = {
			{ direction = "forward", bottom = 1, lane = { 305, 304, 303, 302 } },
			{ direction = "reverse", bottom = 1, lane = { 302, 303, 304, 305 } },
			{ direction = "forward", bottom = 6, lane = { 302, 303, 304, 305 } },
			{ direction = "reverse", bottom = 6, lane = { 305, 304, 303, 302 } },
		}
		for _, case in ipairs(cases) do
			it(string.format("runs %s with bottom = %d along %s", case.direction, case.bottom,
				table.concat(case.lane, ", ")), function()
				local r = rig()
				start(r, { direction = case.direction, bottom = case.bottom })
				assert.are.same(case.lane, r.s:debug().lane)
				local calls, looks = run_chase(r)
				assert.are.same(case.lane, arrivals(calls, 4))
				assert.are.same({ "#...", ".#..", "..#.", "...#" }, { looks[1], looks[2], looks[3], looks[4] })
			end)
		end

		it("takes the bound links in any order, each once, only 301 to 306", function()
			local r = rig()
			start(r, { pixels = { 305, "302", 304, 303, 303, 300, 307, "x", 3.5 } })
			assert.are.same(HOUSE, r.s:debug().pixels)
			assert.are.same({ 305, 304, 303, 302 }, r.s:debug().lane)
		end)
	end)

	describe("pace and rest (SL-D5, SL-D6)", function()
		local cases = {
			{ speeds = "2-5", speed = 2, step = 400 }, { speeds = "2-5", speed = 3, step = 300 },
			{ speeds = "2-5", speed = 4, step = 200 }, { speeds = "2-5", speed = 5, step = 120 },
			{ speeds = "1-6", speed = 1, step = 500 }, { speeds = "1-6", speed = 6, step = 100 },
			{ speeds = "1-6", speed = 3, step = 300 },
		}
		for _, case in ipairs(cases) do
			it(string.format("steps %d ms at speed %d under %s, after the same first delay, then the same rest",
				case.step, case.speed, case.speeds), function()
				local r = rig()
				start(r, { speeds = case.speeds, speed = case.speed })
				assert.are.equal(FIRST_MS, pending(r).ms) -- a new run's first chase (SL-D19)
				assert.are.equal(case.step, r.s:debug().step)
				tick(r)
				for _ = 1, 4 do
					assert.are.equal(case.step, pending(r).ms)
					tick(r)
				end
				local t = pending(r)
				assert.are.equal(REST_MS, t.ms) -- measured from the end of the chase, the same at every speed
				assert.are.equal(r.clock, t.at)
			end)
		end

		it("never steps under the floor", function()
			local shipped = speedleds.STEP_MS[5]
			speedleds.STEP_MS[5] = 40
			local ok, err = pcall(function()
				local r = rig()
				start(r, { speed = 5 })
				tick(r)
				assert.are.equal(100, pending(r).ms)
			end)
			speedleds.STEP_MS[5] = shipped
			assert(ok, err)
		end)

		it("takes the rest in seconds, held within 5 to 60, 5 for anything else", function()
			local r = rig()
			start(r, { rest = 30 })
			assert.are.equal(FIRST_MS, pending(r).ms) -- the first chase does not wait for the rest (SL-D19)
			run_chase(r)
			assert.are.equal(30000, pending(r).ms)
			for _, case in ipairs({ { 3, 5 }, { 99, 60 }, { "12", 12 }, { 7.4, 7 }, { "x", 5 } }) do
				r.s:configure({ rest = case[1] })
				assert.are.equal(case[2], r.s:debug().rest)
				assert.are.equal(case[2] * 1000, pending(r).ms) -- from the chase's end, which is now
			end
		end)

		it("starts a new run on a speed change, its first chase FIRST_MS later, sending nothing", function()
			local r = rig()
			start(r)
			local first = pending(r)
			r.clock = r.clock + 1000
			r.speed = 4
			r.s:update(view(r))
			assert.are.same({}, r.calls)
			assert.is_true(first.cancelled)
			local t = pending(r)
			assert.are.equal(FIRST_MS, t.ms)
			assert.are.equal(r.clock, t.at)
			-- A callback of the cancelled timer is ignored.
			first.cb()
			assert.are.same({}, r.calls)
			assert.are.equal("resting", r.s:debug().state)
		end)

		it("plays just the next frame for a late timer, the step after it one step later", function()
			local r = rig()
			start(r)
			tick(r)
			local calls = tick(r, 1000)
			assert.are.same({ HOUSE_CHASE[4], HOUSE_CHASE[5], HOUSE_CHASE[6] }, calls)
			assert.are.equal(300, pending(r).ms)
			assert.are.equal(r.clock, pending(r).at)
		end)

		it("starts one chase for a late rest timer, no burst", function()
			local r = rig()
			start(r)
			local calls = tick(r, 5000)
			assert.are.same({ HOUSE_CHASE[1], HOUSE_CHASE[2], HOUSE_CHASE[3] }, calls)
			assert.are.equal(300, pending(r).ms)
		end)

		it("runs without a clock, on the time the timers were armed for", function()
			local r = rig({ no_clock = true })
			start(r)
			local calls = run_chase(r)
			assert.are.same(HOUSE_CHASE, calls)
		end)
	end)

	describe("messages per chase (SL-D12, SL-D18)", function()
		local LINKS = { 301, 302, 303, 304, 305, 306 }
		-- The pixels lit at rest, by their place among the N bound links (ascending); nil: not with N buttons.
		local SETS = {
			{ "none", function() return {} end },
			{ "one in the middle", function(n) return n >= 3 and { 2 } or nil end },
			{ "the lowest", function() return { 1 } end },
			{ "the highest", function(n) return { n } end },
			{ "both ends", function(n) return { 1, n } end },
			{ "two in the middle", function(n) return n >= 4 and { 2, 3 } or nil end },
		}
		local function case(n, places, direction)
			local pixels = {}
			for i = 1, n do
				pixels[i] = LINKS[i]
			end
			local lit, l = {}, #places
			for _, i in ipairs(places) do
				lit[pixels[i]] = true
			end
			local r = rig()
			start(r, { pixels = pixels, lit = lit, direction = direction })
			local lane = r.s:debug().lane
			-- SL-D18: each pixel lit at rest where the dot starts or ends saves two messages.
			local edges = (lit[lane[1]] and 1 or 0) + (lit[lane[n]] and 1 or 0)
			local calls, looks, frames = run_chase(r)
			assert.are.equal(2 * n + 2 * l + (n - l) - 2 * edges, #calls)
			assert.are.equal(#calls, #r.stamps)
			assert.are.same({}, blinks(frames))
			-- Frame 1 starts with the L lit pixels darkened along the lane, all but one where the dot starts, which
			-- is the dot's first position as it is (SL-D18); a dark one is preloaded and lit.
			local k = 0
			for i, link in ipairs(lane) do
				if lit[link] and i > 1 then
					k = k + 1
					assert.are.same({ "light", link, false }, frames[1][k])
				end
			end
			if lit[lane[1]] then
				assert.are.equal(k, #frames[1])
			else
				assert.are.same({ { "paint", lane[1], PURPLE, false, true }, { "light", lane[1], true } },
					{ frames[1][k + 1], frames[1][k + 2] })
				assert.are.equal(k + 2, #frames[1])
			end
			-- The last frame darkens lane[N] unless it is lit at rest, where the dot stays (SL-D18), and relights
			-- the others lit at rest.
			local want = {}
			if not lit[lane[n]] then
				want[1] = { "light", lane[n], false }
			end
			for i, link in ipairs(lane) do
				if lit[link] and i < n then
					want[#want + 1] = { "light", link, true }
				end
			end
			assert.are.same(want, frames[n + 1])
			-- A preload on each pixel dark at rest, just before it is lit; none on a lit one.
			local preloads = 0
			for i, call in ipairs(calls) do
				if call[1] == "paint" then
					preloads = preloads + 1
					assert.is_nil(lit[call[2]])
					assert.are.same({ "paint", call[2], PURPLE, false, true }, call)
					assert.are.same({ "light", call[2], true }, calls[i + 1])
				end
			end
			assert.are.equal(n - l, preloads)
			-- What the keypad shows is unchanged by SL-D18: exactly one pixel lit after each of frames 1 to N, the
			-- dot on lane[k].
			for f = 1, n do
				assert.are.equal(string.rep(".", f - 1) .. "#" .. string.rep(".", n - f), looks[f])
			end
			-- After the last frame the pixels lit at rest are lit, the others dark; the chase lasted N steps.
			local final = {}
			for i, link in ipairs(lane) do
				final[i] = lit[link] and "#" or "."
			end
			assert.are.equal(table.concat(final), looks[n + 1])
			assert.are.equal(n + 1, #looks)
			assert.is_false(held_any(r))
			assert.are.equal(REST_MS, pending(r).ms)
		end
		for n = 2, 6 do
			for _, set in ipairs(SETS) do
				local places = set[2](n)
				for _, direction in ipairs(places and { "forward", "reverse" } or {}) do
					it(string.format("sends 2N + 2L + (N - L), less 2 an edge lit at rest, for N = %d, %s lit, %s",
						n, set[1], direction), function()
						case(n, places, direction)
					end)
				end
			end
		end

		it("sends 11 for the house's four buttons with the selected one at an edge, 10 with Also Lit At at both", function()
			local r = rig()
			start(r, { speed = 2 })
			assert.are.equal(11, #(run_chase(r)))
			r = rig()
			start(r, { speed = 5 })
			assert.are.equal(11, #(run_chase(r)))
			r = rig()
			start(r, { speed = 2, lit = { [302] = true, [305] = true } })
			assert.are.equal(10, #(run_chase(r)))
		end)

		it("plays two buttons both lit at rest in four messages", function()
			local r = rig()
			start(r, { speed = 2, pixels = { 302, 303 }, lit = { [302] = true, [303] = true } })
			local lane = r.s:debug().lane
			assert.are.same({ 303, 302 }, lane)
			local before = look(r, lane)
			local calls, looks = run_chase(r)
			assert.are.same({
				{ "light", 302, false }, -- frame 1: 303 stays lit as the dot's first position
				{ "light", 302, true }, { "light", 303, false }, -- frame 2: the dot moves on to 302
				{ "light", 303, true }, -- frame 3: 303 relit; 302 keeps the dot
			}, calls)
			assert.are.same({ "##", "#.", ".#", "##" }, { before, looks[1], looks[2], looks[3] })
			assert.is_false(held_any(r))
		end)
	end)

	describe("no double blink at the edges (SL-D18, #172)", function()
		-- The house's four buttons, the selected speed's button lit at rest, at each place of the lane.
		local CASES = {
			{ direction = "forward", bottom = 1, lane = { 305, 304, 303, 302 } },
			{ direction = "reverse", bottom = 1, lane = { 302, 303, 304, 305 } },
			{ direction = "forward", bottom = 6, lane = { 302, 303, 304, 305 } },
			{ direction = "reverse", bottom = 6, lane = { 305, 304, 303, 302 } },
		}
		-- What each pixel along the lane is sent, frame by frame (5 is the last frame), with the selected button at
		-- lane place p. The dark pixels are the same at every p; only the selected one differs.
		local DOT = {
			{ "1:preload", "1:light", "2:dark" }, { "2:preload", "2:light", "3:dark" },
			{ "3:preload", "3:light", "4:dark" }, { "4:preload", "4:light", "5:dark" },
		}
		local SELECTED = {
			[1] = { "2:dark", "5:light" }, -- lit at rest as the dot's first position, darkened as the dot moves on
			[2] = { "1:dark", "2:light", "3:dark", "5:light" }, -- a middle place: as before #172
			[3] = { "1:dark", "3:light", "4:dark", "5:light" },
			[4] = { "1:dark", "4:light" }, -- dark while the dot runs; the dot stays on it for the rest
		}
		local PICTURES = { "#...", ".#..", "..#.", "...#" }
		local function chase_at(case, p)
			local r = rig()
			start(r, { direction = case.direction, bottom = case.bottom, speed = case.lane[p] - 300 })
			assert.are.same(case.lane, r.s:debug().lane)
			return r
		end
		for _, case in ipairs(CASES) do
			local where = string.format("%s, bottom = %d", case.direction, case.bottom)
			for p = 1, 4 do
				local edge = p == 1 or p == 4
				local what = p == 1 and "keeps the selected button lit where the dot starts"
					or p == 4 and "leaves the dot on the selected button where it ends"
					or "still darkens a selected middle button at the start and relights it at the end"
				it(string.format("%s (%s, place %d): %d messages, no blink", what, where, p, edge and 11 or 13),
					function()
						local r = chase_at(case, p)
						local selected = case.lane[p]
						local before = look(r, case.lane)
						local calls, looks, frames = run_chase(r)
						assert.are.equal(edge and 11 or 13, #calls)
						assert.are.same({}, blinks(frames))
						for i, link in ipairs(case.lane) do
							assert.are.same(i == p and SELECTED[p] or DOT[i], schedule(frames, link),
								"what link " .. link .. " is sent")
						end
						if p == 1 then
							assert.are.same({}, frames[1]) -- nothing else lit at rest: nothing to send at once
						end
						-- What the keypad shows after each frame is the dot's run, then the rest, as before #172.
						assert.are.same(PICTURES[p], before)
						assert.are.same({ PICTURES[1], PICTURES[2], PICTURES[3], PICTURES[4], PICTURES[p] }, looks)
						assert.is_true(r.kp[selected].lit)
						assert.are.equal(COLOURS[selected - 300], r.kp[selected].loaded)
						assert.is_false(held_any(r))
						assert.are.equal(REST_MS, pending(r).ms)
						assert.are.equal(r.clock, pending(r).at)
						-- The next chase is the same.
						local again = run_chase(r)
						assert.are.same(calls, again)
					end)
			end

			for _, p in ipairs({ 1, 4 }) do
				it(string.format("settles every held pixel when stopped after any frame, the edge button too (%s,"
					.. " place %d)", where, p), function()
					for after = 1, 4 do
						local r = chase_at(case, p)
						for _ = 1, after do
							tick(r)
						end
						for _, link in ipairs(case.lane) do
							assert.is_true(r.s:held(link))
						end
						r.calls, r.stamps = {}, {}
						r.s:stop()
						assert.are.same(settles(HOUSE), r.calls)
						assert.are.equal(8, #r.stamps)
						assert.is_false(held_any(r))
						assert.is_nil(pending(r))
						for _, link in ipairs(HOUSE) do
							assert.are.equal(r.rest[link] == true, r.kp[link].lit)
						end
						assert.are.equal(PICTURES[p], look(r, case.lane))
					end
				end)

				it(string.format("settles every held pixel on a speed change or a repaint of the edge button"
					.. " mid-chase (%s, place %d)", where, p), function()
					local r = chase_at(case, p)
					tick(r)
					r.calls = {}
					r.speed = case.lane[5 - p] - 300 -- the other edge, which then rests lit
					r.rest = { [case.lane[5 - p]] = true }
					r.s:update(view(r))
					assert.are.same(settles(HOUSE), r.calls)
					assert.is_false(held_any(r))
					assert.are.equal(PICTURES[5 - p], look(r, case.lane))
					assert.are.equal(FIRST_MS, pending(r).ms)
					r = chase_at(case, p)
					tick(r)
					r.calls = {}
					assert.is_true(r.s:repaint(case.lane[p])) -- held although nothing was sent to it yet at place 1
					assert.are.same(settles(HOUSE), r.calls)
					assert.are.equal(PICTURES[p], look(r, case.lane))
					assert.are.equal(FIRST_MS, pending(r).ms)
				end)
			end
		end

		it("settles an edge button lit at rest that is not known to be right at the end, instead of leaving it", function()
			local LANE = { 305, 304, 303, 302 }
			-- Place 4: Low lit at speed 3 through Also Lit At, which is cleared while the dot is on Low.
			local r = rig()
			start(r, { lit = { [302] = true, [303] = true } })
			for _ = 1, 4 do
				tick(r)
			end
			assert.are.equal("...#", look(r, LANE))
			r.rest = { [303] = true }
			assert.are.same({ { "light", 303, true }, { "settle", 302 } }, tick(r))
			assert.are.equal("..#.", look(r, LANE))
			assert.is_false(held_any(r))
			-- Place 4, the selected button: Speed 2 LED Color changes mid-chase.
			r = rig()
			start(r, { speed = 2 })
			tick(r)
			r.colours[2] = "ff00ff"
			for _ = 1, 3 do
				tick(r)
			end
			assert.are.same({ { "settle", 302 } }, tick(r))
			assert.are.equal("...#", look(r, LANE, "ff00ff"))
			-- Place 1, the selected button: Speed 5 LED Color changes mid-chase; settled instead of relit.
			r = rig()
			start(r, { speed = 5 })
			tick(r)
			r.colours[5] = "ff00ff"
			for _ = 1, 3 do
				tick(r)
			end
			assert.are.same({ { "light", 302, false }, { "settle", 305 } }, tick(r))
			assert.are.equal("#...", look(r, LANE, "ff00ff"))
			assert.is_false(held_any(r))
		end)

		it("settles a last edge button whose arrival failed, instead of leaving it as it is", function()
			local r = rig()
			start(r, { speed = 2 })
			r.fail_light = function(link, lit) return link == 302 and lit end
			local _, _, frames = run_chase(r)
			assert.are.same({ { "settle", 302 } }, frames[5])
			assert.is_true(r.kp[302].lit)
			assert.is_false(held_any(r))
		end)
	end)

	describe("idempotent inputs (SL-D10)", function()
		it("sends nothing and keeps the rest timer for the same inputs", function()
			local r = rig()
			start(r)
			local t = pending(r)
			local count = #r.timers
			r.clock = r.clock + 2000
			r.s:update(view(r, { level = 40, light_on = true })) -- a light-level change upstream
			r.s:configure({ speeds = "2-5", per_speed = true, bottom = 1, rest = 5 })
			r.s:configure({})
			r.s:configure({ rest = "5" })
			r.s:set_pixels({ 305, 304, 303, 302, 302 })
			assert.are.same({}, r.calls)
			assert.are.equal(count, #r.timers)
			assert.is_false(t.cancelled)
			assert.are.equal(t, pending(r))
		end)

		it("keeps a chase playing for the same inputs", function()
			local r = rig()
			start(r)
			local calls = tick(r)
			for _, call in ipairs(tick(r)) do
				calls[#calls + 1] = call
			end
			local t = pending(r)
			r.s:update(view(r, { level = 10 }))
			r.s:set_pixels({ 302, 303, 304, 305 })
			r.s:configure({ per_speed = true })
			assert.are.same({}, r.calls)
			assert.are.equal(t, pending(r))
			for _ = 1, 3 do
				for _, call in ipairs(tick(r)) do
					calls[#calls + 1] = call
				end
			end
			assert.are.same(HOUSE_CHASE, calls)
		end)
	end)

	describe("no chase (SL-D8, SL-D9)", function()
		local cases = {
			{ "Speed LED Animation Off", function(r) r.s:configure({ speeds = "off" }) end },
			{ "an unknown Speed LED Animation", function(r) r.s:configure({ speeds = "chase" }) end },
			{ "Keypad's own colours", function(r) r.s:configure({ per_speed = false }) end },
			{ "offline", function(r) r.s:update(view(r, { online = false })) end },
			{ "an unknown direction", function(r) r.s:update(view(r, { direction = false })) end },
			{ "a direction that is neither", function(r) r.s:update(view(r, { direction = "down" })) end },
			{ "Breeze (fan_mode false)", function(r) r.s:update(view(r, { fan_mode = false, speed = 0 })) end },
			{ "fan mode unknown", function(r) r.s:update(view(r, { fan_mode = "yes" })) end },
			{ "a stopped motor", function(r) r.s:update(view(r, { fan_mode = false, speed = 0 })) end },
			{ "an unknown speed", function(r) r.s:update(view(r, { speed = false })) end },
			{ "speed 1 under 2-5", function(r) r.s:update(view(r, { speed = 1 })) end },
			{ "speed 6 under 2-5", function(r) r.s:update(view(r, { speed = 6 })) end },
			{ "one bound button", function(r) r.s:set_pixels({ 303 }) end },
			{ "no bound button", function(r) r.s:set_pixels({}) end },
		}
		for _, case in ipairs(cases) do
			it("runs none with " .. case[1], function()
				local r = rig()
				start(r)
				case[2](r)
				assert.are.same({}, r.calls)
				assert.is_nil(pending(r))
				assert.is_false(held_any(r))
				local d = r.s:debug()
				assert.are.equal("off", d.state)
				assert.is_false(d.active)
				assert.is_string(d.why)
			end)
		end

		it("runs none before anything is configured", function()
			local r = rig()
			r.s:set_pixels(HOUSE)
			r.s:update({ fan_mode = true, speed = 3, online = true, direction = "forward" })
			assert.is_nil(pending(r))
			assert.are.equal("off", r.s:debug().state)
			assert.are.equal("Speed LED Animation is Off", r.s:debug().why)
		end)

		it("chases speeds 1 and 6 only under 1-6", function()
			local r = rig()
			start(r, { speeds = "1-6", speed = 1 })
			assert.are.equal(FIRST_MS, pending(r).ms)
			r.s:configure({ speeds = "2-5" })
			assert.is_nil(pending(r))
			r.s:configure({ speeds = "1-6" })
			r.speed = 6
			r.s:update(view(r))
			assert.are.equal(FIRST_MS, pending(r).ms)
			assert.are.equal(100, r.s:debug().step)
		end)

		it("starts a new run once the last missing input arrives, its first chase FIRST_MS later", function()
			local r = rig()
			start(r)
			r.s:update(view(r, { direction = false }))
			assert.is_nil(pending(r))
			r.direction = "reverse"
			r.s:update(view(r))
			assert.are.equal(FIRST_MS, pending(r).ms)
			assert.are.same({}, r.calls)
		end)
	end)

	describe("every stop path (SL-D9, SL-D11, SL-D16)", function()
		-- Each case mid-chase (after frame 2, every pixel held): `run` says whether a new run follows, its first
		-- chase FIRST_MS later (SL-D19). A rest change is not a stop: see "a rest change mid-chase".
		local cases = {
			{ "a speed change", function(r) r.speed = 4; r.s:update(view(r)) end, run = true },
			{ "Breeze", function(r) r.s:update(view(r, { fan_mode = false, speed = 0 })) end },
			{ "fan mode unknown", function(r) r.s:update(view(r, { fan_mode = "?" })) end },
			{ "offline", function(r) r.s:update(view(r, { online = false })) end },
			{ "an unknown direction", function(r) r.s:update(view(r, { direction = false })) end },
			{ "a reversed fan", function(r) r.direction = "reverse"; r.s:update(view(r)) end, run = true },
			{ "speed 6 under 2-5", function(r) r.speed = 6; r.s:update(view(r)) end },
			{ "Keypad's own", function(r) r.s:configure({ per_speed = false }) end },
			{ "Speed LED Animation Off", function(r) r.s:configure({ speeds = "off" }) end },
			{ "Speeds 1 to 6", function(r) r.s:configure({ speeds = "1-6" }) end, run = true },
			{ "a bottom change", function(r) r.s:configure({ bottom = 6 }) end, run = true },
			{ "a button unbound", function(r) r.s:set_pixels({ 302, 303, 304 }) end, run = true },
			{ "a button bound", function(r) r.s:set_pixels({ 301, 302, 303, 304, 305 }) end, run = true },
			{ "one button left", function(r) r.s:set_pixels({ 303 }) end },
			{ "a repaint", function(r) assert.is_true(r.s:repaint(304)) end, run = true },
			{ "a repaint by name", function(r) assert.is_true(r.s:repaint("302")) end, run = true },
			{ "stop", function(r) r.s:stop() end },
		}
		for _, case in ipairs(cases) do
			it("settles every held pixel and holds nothing after: " .. case[1], function()
				local r = rig()
				start(r)
				tick(r)
				tick(r)
				local step = pending(r)
				r.clock = r.clock + 100
				r.calls, r.stamps = {}, {}
				case[2](r)
				assert.are.same(settles(HOUSE), r.calls)
				assert.are.equal(8, #r.stamps)
				assert.is_false(held_any(r))
				assert.is_true(step.cancelled)
				-- What the links sent is what the keypad shows: the selected speed's LED lit, the others dark.
				for _, link in ipairs(HOUSE) do
					assert.are.equal(r.rest[link] == true, r.kp[link].lit)
				end
				local t = pending(r)
				if case.run then
					assert.are.equal(FIRST_MS, t.ms)
					assert.are.equal(r.clock, t.at)
					assert.are.equal("resting", r.s:debug().state)
					assert.is_true(r.s:debug().first)
				else
					assert.is_nil(t)
					assert.are.equal("off", r.s:debug().state)
					assert.is_false(r.s:debug().first)
				end
			end)
		end

		it("sends nothing for a change while resting or waiting, and starts a new run", function()
			local r = rig()
			start(r)
			local first = pending(r)
			r.s:configure({ rest = 15 })
			assert.are.same({}, r.calls)
			assert.are.equal(first, pending(r)) -- the first chase does not wait for the rest
			r.blocked[305] = true
			tick(r)
			assert.are.equal("waiting", r.s:debug().state)
			r.speed = 5
			r.s:update(view(r))
			assert.are.same({}, r.calls)
			assert.are.equal(FIRST_MS, pending(r).ms)
			assert.are.equal("resting", r.s:debug().state)
		end)

		it("keeps a chase playing through a rest change mid-chase, the new rest after it (SL-D19)", function()
			local r = rig()
			start(r)
			local calls = tick(r)
			for _, call in ipairs(tick(r)) do
				calls[#calls + 1] = call
			end
			local step = pending(r)
			r.clock = r.clock + 100
			r.s:configure({ rest = 20 })
			assert.are.same({}, r.calls)
			assert.is_false(step.cancelled)
			assert.are.equal(step, pending(r))
			assert.are.equal("chasing", r.s:debug().state)
			assert.are.equal(20, r.s:debug().rest)
			for _, call in ipairs(finish(r)) do
				calls[#calls + 1] = call
			end
			assert.are.same(HOUSE_CHASE, calls)
			local t = pending(r)
			assert.are.equal(20000, t.ms)
			assert.are.equal(r.clock, t.at)
		end)

		it("settles a held link that just left the list too", function()
			local r = rig()
			start(r)
			tick(r)
			r.calls = {}
			r.s:set_pixels({ 302, 303 })
			assert.are.same(settles(HOUSE), r.calls)
			assert.are.same({ 302, 303 }, r.s:debug().pixels)
		end)

		it("answers false to a repaint of a link it does not hold, sending nothing", function()
			local r = rig()
			start(r)
			assert.is_false(r.s:repaint(303)) -- resting: the links own it
			tick(r)
			r.calls = {}
			assert.is_false(r.s:repaint(306))
			assert.is_false(r.s:repaint(nil))
			assert.are.same({}, r.calls)
			assert.are.equal("chasing", r.s:debug().state)
		end)

		it("stops for good: every later call is ignored", function()
			local r = rig()
			start(r)
			r.s:stop()
			assert.are.same({}, r.calls) -- resting: nothing held, nothing to settle
			local count = #r.timers
			r.s:configure({ rest = 20 })
			r.s:set_pixels({ 301, 302 })
			r.speed = 4
			r.s:update(view(r))
			assert.is_false(r.s:repaint(303))
			r.s:stop()
			assert.are.same({}, r.calls)
			assert.are.equal(count, #r.timers)
			assert.is_nil(pending(r))
			assert.is_false(held_any(r))
			local d = r.s:debug()
			assert.are.equal("off", d.state)
			assert.is_true(d.stopped)
		end)
	end)

	describe("waiting for Breeze (SL-D2, SL-D14)", function()
		it("delays a chase by RETRY_MS while another engine holds a pixel, holding nothing", function()
			local r = rig()
			start(r)
			r.blocked[302] = true
			assert.are.same({}, tick(r))
			assert.is_false(held_any(r))
			assert.are.equal("waiting", r.s:debug().state)
			assert.are.equal(200, pending(r).ms)
			assert.are.same({}, tick(r))
			assert.are.equal(200, pending(r).ms)
			r.blocked = {}
			assert.are.same({ HOUSE_CHASE[1], HOUSE_CHASE[2], HOUSE_CHASE[3] }, tick(r))
			assert.are.equal("chasing", r.s:debug().state)
		end)

		it("runs without a blocked option", function()
			local r = rig({ no_blocked = true })
			start(r)
			assert.are.same(HOUSE_CHASE, (run_chase(r)))
		end)

		it("counts a blocked that raises as held, warned once", function()
			local r = rig()
			start(r)
			r.fail_blocked = true
			tick(r)
			tick(r)
			tick(r)
			assert.are.same({}, r.calls)
			assert.are.equal("waiting", r.s:debug().state)
			assert.are.equal(1, r.log.count("warn"))
			r.fail_blocked = false
			assert.are.equal(3, #tick(r))
		end)
	end)

	describe("the budget (SL-D13)", function()
		-- Every message stamp within any WINDOW_MS: at most `limit`.
		local function within(stamps, limit)
			for i = 1, #stamps do
				local n = 0
				for j = 1, #stamps do
					if stamps[j] > stamps[i] - 1000 and stamps[j] <= stamps[i] then
						n = n + 1
					end
				end
				if n > limit then
					return false
				end
			end
			return true
		end

		it("delays a step until the window has room, never dropping one", function()
			speedleds.BUDGET_PER_S = 4
			local r = rig()
			start(r)
			local calls = run_chase(r)
			assert.are.same(HOUSE_CHASE, calls)
			assert.is_true(within(r.stamps, 4))
			assert.is_true(r.s:debug().budget.delayed > 0)
		end)

		it("waits exactly until the oldest messages leave the window", function()
			speedleds.BUDGET_PER_S = 4
			local r = rig()
			start(r)
			tick(r) -- frame 1: three messages at t0
			local t0 = r.clock
			local t = pending(r)
			assert.are.equal(300, t.ms)
			assert.are.same({}, tick(r)) -- frame 2 would make six: delayed
			assert.are.equal(700, pending(r).ms) -- until t0 + 1000
			assert.are.same({ HOUSE_CHASE[4], HOUSE_CHASE[5], HOUSE_CHASE[6] }, tick(r))
			assert.are.equal(t0 + 1000, r.clock)
		end)

		it("sends a frame bigger than the whole budget once the window is empty", function()
			speedleds.BUDGET_PER_S = 2
			local r = rig()
			start(r)
			local calls = run_chase(r)
			assert.are.same(HOUSE_CHASE, calls)
		end)
	end)

	describe("truthful at the end", function()
		it("settles a pixel whose rest state changed mid-chase instead of guessing", function()
			local r = rig()
			start(r)
			tick(r)
			tick(r)
			r.rest[302] = true -- Also Lit At: Low now lit at speed 3 too
			tick(r)
			tick(r)
			local last = tick(r)
			assert.are.same({ { "light", 303, true }, { "settle", 302 } }, last)
			assert.are.equal("..##", look(r, { 305, 304, 303, 302 }))
			assert.is_false(held_any(r))
		end)

		it("settles the pixels lit at rest when the speed's colour changed mid-chase", function()
			local r = rig()
			start(r)
			tick(r)
			r.colours[3] = "ff00ff"
			tick(r)
			tick(r)
			tick(r)
			local last = tick(r)
			assert.are.same({ { "light", 302, false }, { "settle", 303 } }, last)
			assert.are.equal("..#.", look(r, { 305, 304, 303, 302 }, "ff00ff"))
		end)
	end)

	describe("failing callbacks are survived", function()
		it("finishes a chase whose paint fails, settling that pixel at the end", function()
			local r = rig()
			start(r)
			r.fail_paint = function(link) return link == 304 end
			local calls = run_chase(r)
			assert.are.same({ { "light", 302, false }, { "settle", 304 }, { "light", 303, true } },
				{ calls[#calls - 2], calls[#calls - 1], calls[#calls] })
			assert.is_true(r.log.has("warn", "link 304 could not be painted"))
			assert.is_false(held_any(r))
			assert.are.equal(REST_MS, pending(r).ms)
		end)

		it("finishes a chase whose every light fails, settling every pixel at the end", function()
			local r = rig()
			start(r)
			r.fail_light = function() return true end
			local calls = run_chase(r)
			assert.are.same(settles({ 305, 304, 303, 302 }), { calls[#calls - 3], calls[#calls - 2],
				calls[#calls - 1], calls[#calls] })
			assert.is_true(r.log.has("warn", "could not be lit"))
			assert.is_false(held_any(r))
			assert.are.equal(REST_MS, pending(r).ms)
		end)

		it("settles a pixel whose last-frame light fails", function()
			local r = rig()
			start(r)
			for _ = 1, 4 do
				tick(r)
			end
			r.fail_light = function(link, lit) return link == 303 and lit end
			local last = tick(r)
			assert.are.same({ { "light", 302, false }, { "light", 303, true }, { "settle", 303 } }, last)
			assert.is_false(held_any(r))
		end)

		it("chases every pixel as dark when lit fails, and settles them all at the end", function()
			local r = rig()
			start(r)
			r.fail_lit = true
			local calls = run_chase(r)
			assert.are.same({ "paint", 305, PURPLE, false, true }, calls[1])
			assert.are.same(settles({ 305, 304, 303, 302 }), { calls[#calls - 3], calls[#calls - 2],
				calls[#calls - 1], calls[#calls] })
			assert.are.equal("..#.", look(r, { 305, 304, 303, 302 }))
			assert.is_true(r.log.has("warn", "lit at rest could not be read"))
		end)

		it("puts back every pixel when a settle fails", function()
			local r = rig()
			start(r)
			tick(r)
			r.fail_settle = function(link) return link == 303 end
			r.calls = {}
			r.s:stop()
			assert.are.same(settles(HOUSE), r.calls)
			assert.is_false(held_any(r))
			assert.is_true(r.log.has("warn", "link 303 could not be settled"))
		end)

		it("skips a chase when the colour cannot be read", function()
			local r = rig()
			start(r)
			r.fail_colour = true
			assert.are.same({}, tick(r))
			assert.are.equal(REST_MS, pending(r).ms)
			assert.is_true(r.log.has("warn", "the colour of speed 3 could not be read"))
		end)

		it("survives a timer that cannot be armed, and arms again on a real change", function()
			local r = rig()
			r.fail_timer = true
			start(r)
			assert.is_nil(pending(r))
			assert.is_true(r.log.has("warn", "the timer could not be armed"))
			r.fail_timer = false
			r.clock = r.clock + 1000
			r.s:configure({ rest = 12 }) -- a rest change arms the first chase where the run put it
			assert.are.equal(FIRST_MS - 1000, pending(r).ms)
			r.clock = r.clock + 500
			r.speed = 4
			r.s:update(view(r)) -- a real change: a new run
			assert.are.equal(FIRST_MS, pending(r).ms)
			assert.are.equal(r.clock, pending(r).at)
		end)

		it("settles every held pixel when a step cannot be timed", function()
			local r = rig()
			start(r)
			local t = pending(r)
			r.fail_timer = true
			t.fired = true
			r.clock = t.at + t.ms
			t.cb()
			assert.are.same(settles(HOUSE), { r.calls[4], r.calls[5], r.calls[6], r.calls[7] })
			assert.is_false(held_any(r))
			assert.is_true(r.log.has("warn", "the chase stopped: no timer"))
			assert.is_nil(pending(r))
			assert.are.equal("resting", r.s:debug().state)
			-- A rest change arms the rest from where the chase stopped.
			r.fail_timer = false
			r.clock = r.clock + 1000
			r.s:configure({ rest = 7 })
			assert.are.equal(6000, pending(r).ms)
		end)

		it("survives a clock and a cancel that raise", function()
			local r = rig()
			start(r)
			local old = pending(r)
			r.fail_clock = true
			r.fail_cancel = true
			r.s:configure({ speeds = "1-6" }) -- a real change at speed 3: a new run, the same chase
			r.fail_cancel = false
			assert.is_true(r.log.has("warn", "the timer could not be cancelled"))
			old.cb() -- the timer that could not be cancelled fires anyway: ignored
			assert.are.same({}, r.calls)
			old.cancelled = true
			assert.are.equal(FIRST_MS, pending(r).ms)
			local calls = run_chase(r)
			assert.are.same(HOUSE_CHASE, calls)
		end)

		it("survives a log that raises", function()
			local r = rig()
			r.log.warn = function() error("no log") end
			r.log.debug = function() error("no log") end
			start(r)
			r.fail_paint = function() return true end
			local calls = run_chase(r)
			-- Three preloads failed: 305, 304 and 302 are settled at the end, 302 instead of its darkening.
			assert.are.equal(13 - 1 + 3, #calls)
			assert.is_false(held_any(r))
		end)
	end)

	describe("a new run's first chase (SL-D19, #177)", function()
		-- The first frame of the chase that falls due next: its calls, and the clock it played at.
		local function next_chase(r)
			local calls = tick(r)
			assert.are.equal("chasing", r.s:debug().state)
			return calls, r.clock
		end

		it("comes 2,500 ms after a speed change, the second a rest after the first ends", function()
			local r = rig()
			start(r)
			run_chase(r) -- the start's run, so the change below comes mid-rest
			local seen = r.clock + 1000
			r.clock = seen
			r.speed, r.rest = 4, { [304] = true }
			r.s:update(view(r))
			assert.are.same({}, r.calls)
			local t = pending(r)
			assert.are.equal(FIRST_MS, t.ms)
			assert.are.equal(seen, t.at)
			assert.is_true(r.s:debug().first)
			local _, at = next_chase(r)
			assert.are.equal(seen + FIRST_MS, at)
			assert.is_false(r.s:debug().first)
			finish(r)
			local ended = r.clock
			assert.are.equal(at + 4 * 200, ended) -- four steps of 200 ms at speed 4
			t = pending(r)
			assert.are.equal(REST_MS, t.ms)
			assert.are.equal(ended, t.at)
			_, at = next_chase(r)
			assert.are.equal(ended + REST_MS, at)
			finish(r)
			assert.are.equal(REST_MS, pending(r).ms) -- and one every rest while the speed stays
		end)

		it("restarts with 2,500 ms on a speed change mid-rest", function()
			local r = rig()
			start(r)
			run_chase(r)
			local resting = pending(r)
			r.clock = r.clock + 3000
			r.speed = 5
			r.s:update(view(r))
			assert.are.same({}, r.calls)
			assert.is_true(resting.cancelled)
			local t = pending(r)
			assert.are.equal(FIRST_MS, t.ms)
			assert.are.equal(r.clock, t.at)
			local _, at = next_chase(r)
			assert.are.equal(t.at + FIRST_MS, at)
		end)

		it("restarts with 2,500 ms on a speed change mid-chase, after settling every held pixel", function()
			local r = rig()
			start(r)
			tick(r)
			tick(r)
			r.clock = r.clock + 100
			r.calls = {}
			r.speed = 5
			r.s:update(view(r))
			assert.are.same(settles(HOUSE), r.calls)
			assert.is_false(held_any(r))
			local t = pending(r)
			assert.are.equal(FIRST_MS, t.ms)
			assert.are.equal(r.clock, t.at)
			assert.is_true(r.s:debug().first)
		end)

		-- Every source of a new run: `before` (if any) leaves the chase impossible, `after` is the change the engine
		-- sees. Each starts mid-rest after a chase, so a run that merely went on would wait a whole rest.
		local SOURCES = {
			{ "the fan starting at a speed from off",
				function(r) r.s:update(view(r, { fan_mode = false, speed = 0 })) end,
				function(r) r.s:update(view(r)) end },
			{ "Breeze ending at a speed",
				function(r) r.s:update(view(r, { fan_mode = false, speed = 3 })) end,
				function(r) r.s:update(view(r)) end },
			{ "the chase turned on",
				function(r) r.s:configure({ speeds = "off" }) end,
				function(r) r.s:configure({ speeds = "2-5" }) end },
			{ "Speed LED Colors set to Per speed",
				function(r) r.s:configure({ per_speed = false }) end,
				function(r) r.s:configure({ per_speed = true }) end },
			{ "the chase's speeds widened", nil, function(r) r.s:configure({ speeds = "1-6" }) end },
			{ "the fan back online",
				function(r) r.s:update(view(r, { online = false })) end,
				function(r) r.s:update(view(r)) end },
			{ "the direction known again",
				function(r) r.s:update(view(r, { direction = false })) end,
				function(r) r.s:update(view(r)) end },
			{ "a direction change", nil, function(r) r.direction = "reverse"; r.s:update(view(r)) end },
			{ "a speed from the app or the API, seen at a poll", nil,
				function(r) r.speed, r.rest = 2, { [302] = true }; r.s:update(view(r)) end },
			{ "a changed pixel list", nil, function(r) r.s:set_pixels({ 302, 303, 304 }) end },
			{ "a button bound", function(r) r.s:set_pixels({ 303 }) end, function(r) r.s:set_pixels(HOUSE) end },
		}
		for _, case in ipairs(SOURCES) do
			it("starts with 2,500 ms on " .. case[1], function()
				local r = rig()
				start(r)
				run_chase(r)
				r.clock = r.clock + 3000
				if case[2] then
					case[2](r)
					assert.is_nil(pending(r))
					assert.are.equal("off", r.s:debug().state)
					r.clock = r.clock + 1000
				end
				r.calls = {}
				case[3](r)
				assert.are.same({}, r.calls) -- resting: nothing held, nothing to settle
				local t = pending(r)
				assert.are.equal(FIRST_MS, t.ms)
				assert.are.equal(r.clock, t.at)
				local d = r.s:debug()
				assert.are.equal("resting", d.state)
				assert.is_true(d.first)
				local calls, at = next_chase(r)
				assert.are.equal(t.at + FIRST_MS, at)
				assert.is_true(#calls > 0)
			end)
		end

		it("is not pushed back by an identical update at 2,400 ms", function()
			local r = rig()
			start(r)
			local t = pending(r)
			local count = #r.timers
			r.clock = t.at + 2400
			r.s:update(view(r, { level = 40, light_on = true })) -- a light-level change upstream
			r.s:update(view(r)) -- a poll that changes nothing
			r.s:configure({ speeds = "2-5", per_speed = true, bottom = 1, rest = 5 })
			r.s:set_pixels({ 305, 304, 303, 302 })
			assert.are.same({}, r.calls)
			assert.are.equal(count, #r.timers)
			assert.is_false(t.cancelled)
			assert.are.equal(t, pending(r))
			assert.is_true(r.s:debug().first)
			local calls, at = next_chase(r)
			assert.are.same({ HOUSE_CHASE[1], HOUSE_CHASE[2], HOUSE_CHASE[3] }, calls)
			assert.are.equal(t.at + FIRST_MS, at)
		end)

		it("retries every 200 ms when Breeze's leave wipe still holds a pixel at 2,500 ms", function()
			local r = rig()
			start(r)
			run_chase(r)
			r.s:update(view(r, { fan_mode = false, speed = 0 })) -- Breeze
			for _, link in ipairs(HOUSE) do
				r.blocked[link] = true -- the gusts, then the leave wipe
			end
			r.clock = r.clock + 20000
			local seen = r.clock
			r.s:update(view(r)) -- Breeze ends at speed 3
			assert.are.equal(FIRST_MS, pending(r).ms)
			assert.are.same({}, tick(r))
			assert.are.equal(seen + FIRST_MS, r.clock)
			assert.are.equal("waiting", r.s:debug().state)
			assert.is_true(r.s:debug().first)
			assert.is_false(held_any(r))
			assert.are.equal(200, pending(r).ms)
			assert.are.same({}, tick(r))
			assert.are.equal(seen + FIRST_MS + 200, r.clock)
			assert.are.equal(200, pending(r).ms)
			r.blocked = {} -- the wipe lets go
			local calls, at = next_chase(r)
			assert.are.same({ HOUSE_CHASE[1], HOUSE_CHASE[2], HOUSE_CHASE[3] }, calls)
			assert.are.equal(seen + FIRST_MS + 400, at)
			finish(r)
			local t = pending(r)
			assert.are.equal(REST_MS, t.ms) -- then a rest after the chase's end
			assert.are.equal(r.clock, t.at)
		end)

		it("comes at 2,500 ms when Breeze's leave wipe lets go before then", function()
			local r = rig()
			start(r)
			r.s:update(view(r, { fan_mode = false, speed = 0 }))
			r.blocked[302] = true
			r.clock = r.clock + 8000
			local seen = r.clock
			r.s:update(view(r))
			r.clock = seen + 1000
			r.blocked = {}
			local _, at = next_chase(r)
			assert.are.equal(seen + FIRST_MS, at)
		end)

		it("keeps the first chase at 2,500 ms through a rest change in the first delay, the new rest after it",
			function()
				local r = rig()
				start(r)
				local t = pending(r)
				r.clock = t.at + 1000
				r.s:configure({ rest = 20 })
				assert.are.same({}, r.calls)
				assert.is_false(t.cancelled)
				assert.are.equal(t, pending(r))
				assert.are.equal(20, r.s:debug().rest)
				assert.is_true(r.s:debug().first)
				local _, at = next_chase(r)
				assert.are.equal(t.at + FIRST_MS, at)
				finish(r)
				local rest = pending(r)
				assert.are.equal(20000, rest.ms)
				assert.are.equal(r.clock, rest.at)
			end)

		it("moves the next chase to a rest after the last chase's end on a rest change while resting, never"
			.. " earlier than now", function()
				local r = rig()
				start(r, { rest = 10 })
				run_chase(r)
				local ended = r.clock
				local old = pending(r)
				assert.are.equal(10000, old.ms)
				-- Longer, 3 s into the rest: due 20 s after the end.
				r.clock = ended + 3000
				r.s:configure({ rest = 20 })
				assert.are.same({}, r.calls)
				assert.is_true(old.cancelled)
				local t = pending(r)
				assert.are.equal(17000, t.ms)
				assert.are.equal(ended + 3000, t.at)
				assert.is_false(r.s:debug().first)
				-- Shorter, 8 s into the rest: due 6 s after the end, already past, so at once.
				r.clock = ended + 8000
				r.s:configure({ rest = 6 })
				t = pending(r)
				assert.are.equal(1, t.ms)
				assert.are.equal(ended + 8000, t.at)
				local calls, at = next_chase(r)
				assert.are.same({ HOUSE_CHASE[1], HOUSE_CHASE[2], HOUSE_CHASE[3] }, calls)
				assert.is_true(at >= ended + 8000)
				finish(r)
				assert.are.equal(6000, pending(r).ms)
			end)

		it("keeps the retry while waiting on a rest change; the new rest comes after the chase", function()
			local r = rig()
			start(r)
			r.blocked[304] = true
			tick(r)
			local retry = pending(r)
			r.s:configure({ rest = 9 })
			assert.are.equal(retry, pending(r))
			assert.is_false(retry.cancelled)
			r.blocked = {}
			next_chase(r)
			finish(r)
			assert.are.equal(9000, pending(r).ms)
		end)

		it("arms nothing on a rest change while off; the run that follows starts with 2,500 ms", function()
			local r = rig()
			start(r)
			r.s:configure({ speeds = "off" })
			r.s:configure({ rest = 30 })
			assert.is_nil(pending(r))
			r.s:configure({ speeds = "2-5" })
			assert.are.equal(FIRST_MS, pending(r).ms)
			next_chase(r)
			finish(r)
			assert.are.equal(30000, pending(r).ms)
		end)

		it("counts a chase skipped for want of a colour as one that ended: the next a rest later", function()
			local r = rig()
			start(r)
			r.colours[3] = nil
			assert.are.same({}, tick(r))
			assert.is_false(r.s:debug().first)
			local t = pending(r)
			assert.are.equal(REST_MS, t.ms)
			assert.are.equal(r.clock, t.at)
		end)

		it("starts a new run after a repaint mid-chase (SL-D16)", function()
			local r = rig()
			start(r)
			run_chase(r)
			tick(r)
			assert.is_true(r.s:repaint(303))
			assert.are.equal(FIRST_MS, pending(r).ms)
			assert.is_true(r.s:debug().first)
		end)
	end)

	describe("debug", function()
		it("reports the state, the first-chase phase, speed, step, rest and held links", function()
			local r = rig()
			assert.are.equal("off", r.s:debug().state)
			assert.is_false(r.s:debug().first)
			start(r)
			local d = r.s:debug()
			assert.are.equal("resting", d.state)
			assert.is_true(d.first) -- a new run: the first chase FIRST_MS after its start (SL-D19)
			assert.are.equal(3, d.speed)
			assert.are.equal(300, d.step)
			assert.are.equal(5, d.rest)
			assert.are.same({}, d.held)
			assert.is_true(d.pending)
			assert.is_true(d.active)
			assert.is_nil(d.why)
			r.blocked[303] = true
			tick(r)
			assert.are.equal("waiting", r.s:debug().state)
			assert.is_true(r.s:debug().first) -- still the first chase of the run
			r.blocked = {}
			tick(r)
			d = r.s:debug()
			assert.are.equal("chasing", d.state)
			assert.is_false(d.first)
			assert.are.same(HOUSE, d.held)
			assert.are.equal(3, d.budget.sent)
			assert.are.equal(30, d.budget.limit)
			finish(r)
			d = r.s:debug()
			assert.are.equal("resting", d.state)
			assert.is_false(d.first) -- the rest between chases
		end)
	end)
end)
