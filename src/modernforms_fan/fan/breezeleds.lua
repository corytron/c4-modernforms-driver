-- fan/breezeleds.lua: Breeze on the keypad LEDs (#137). The contract is docs/breeze-leds-design.md: section 1
-- (BL-D1 to BL-D18) as revised by section 1a (BL-D19 to BL-D26, which replace BL-D5 to BL-D7, BL-D12, BL-D14
-- and BL-D22's sparkle ticks), this module's interface (section 3.1 and section 1a's interface block) and what
-- the owner sees; the reasons are docs/edge-cases-breeze-leds.md (BL1 to BL70), docs/breeze-leds-sdk-research.md
-- section 6 and the keypad probes of #137 (2026-11-09).
--
-- While the fan blows Breeze, the keypad buttons on the fan's bound speed links (301 to 306, the pixels; BL-D2)
-- play gusts. Pixel 1 is the bottom: the lowest link, or the highest with bottom = 6 (BL-D4). Colours (BL-D20):
-- the front HEAD (white), the tail's SPARKS (ice, teal, sky) and the glint GLINT (sky); full values only.
--
--   idle   nothing held, nothing sent.
--   gust   (BL-D21, BL-D26) a front rises from below pixel 1, one pixel per front step: the step property drawn
--          once a gust within +-JITTER_PERCENT (never under TICK_MS, so the front never skips a pixel on time).
--          The pixel a front is on is HEAD. A pixel a front has passed is in its tail for a tail time drawn in
--          TAIL_MS[strength]: lit at once in a SPARKS colour, then blinking off and on at gaps drawn in
--          TAIL_GAP_TICKS (the gap's low end rises over the tail, so the gaps grow and the tail thins out),
--          relighting each time in a SPARKS colour drawn again; then dark. Each pixel draws its own tail, so
--          neighbours never blink in step. When the leading front reaches pixel p, pixel p + 2 may glint GLINT
--          for one tick (GLINT_PERCENT; once a pixel a gust). With DOUBLE_PERCENT[strength] a second front
--          follows DOUBLE_GAP_STEPS (2 to 4) front steps behind. Every other pixel is dark. When every front is
--          past the top, every tail over and every pixel dark: a rest.
--   rest   (BL-D19, BL-D22) every pixel dark, nothing sent and no ticking: one timer for a time drawn in
--          REST_MS[strength], then the next gust.
--   leave  (BL-D8, BL-D25) the falling wipe, once, when Breeze ends while online and everything else still
--          holds: the head (HEAD) starts on the top held pixel and descends one pixel per step (the step
--          property, not jittered); each pixel it leaves is settled (settle(link): the links send its real
--          state). A pixel the head has not reached keeps what it shows (a tail is frozen). Pixel 1 settled: idle.
--
-- Start (BL-D19): from idle, or when Breeze is back during the leave (BL-D10), every pixel is taken (held) and
-- sent dark at once, and the first gust starts at once; its front enters pixel 1 one front step later, so the
-- dark shows first. Active means enabled, per_speed, online, breeze and at least one pixel. Any other way out
-- of active settles every held pixel at once, with no wipe (BL-D11). Leave during a gust or a rest starts the
-- falling wipe from the top at once (BL-D10). The strength is read when a gust starts (its tails and double)
-- and when a rest is armed; a step change applies from the next gust, and in the wipe from the next arm.
--
-- Messages (BL-D23): what the keypad shows is kept per pixel (lit, dark or unknown, and the colour loaded) and
-- only real changes are sent: a dark pixel's colour is preloaded with paint(link, colour, false, true) and shown
-- with light(link, true); a lit pixel changes colour with paint(link, colour, RECOLOUR_NEEDS_STATE, false);
-- dark is light(link, false); a pixel whose state is unknown is lit with paint(link, colour, true, false). A
-- send that fails leaves that part unknown, so the next tick sends it again.
--
-- One clock and a budget (BL-D24, BL-D13): one one-shot timer at a time, re-armed every TICK_MS while a gust
-- runs, every step while the wipe runs, once for the rest's length during a rest; every phase change, stop and
-- re-arm cancel the pending one first, and a callback of a cancelled timer is ignored. The engine keeps its own
-- time, which follows the `now` clock and never runs backwards (without a clock, or while it fails, a tick
-- advances it by the time the timer was armed for). The budget is a sliding window: every message is stamped
-- with that time (a paint 1, 2 with the state; a light 1; a settle 2, its colours and its state) and at most
-- BUDGET_PER_S may fall in any WINDOW_MS. Always sent and counted: the front (a pixel a front is on, and a
-- pixel a front has left that still shows HEAD), the dark-first, settles, the wipe and repaints. A tail change,
-- a glint and the darkening of a pixel whose tail is over are sent only when the window has room for them on
-- top of a reserve for the fronts still due in the next WINDOW_MS (2 an arrival, 1 a recolour as a front
-- leaves a pixel), so a gust's own fronts always fit; otherwise they are dropped for this tick (the darkening
-- first in line, then tail changes going dark, then relights, the youngest first, then glints, which light
-- only with room to darken them at the next tick), and what is still wanted is tried again at the next tick.
-- A double gust runs only when both fronts fit the budget with what the window holds; otherwise the gust is
-- single (a 6-pixel column never doubles: 2 x 18). So only calls from outside (a leave, a new pixel, a repaint)
-- can push a window past the budget. A late tick never bursts: the gust is evaluated at the tick that fell due
-- last, each pixel sent only its final state within the budget, and the wipe settles every pixel it passed. A
-- gust whose last darkening cannot be sent waits up to DARKEN_TICKS ticks, then rests anyway (and darkens).
--
-- Randomness: random(lo, hi), integers, inclusive. A gust draws its step (lo, hi = the step -+20 %), its double
-- (random(1, 100) <= DOUBLE_PERCENT) and, if double, its gap (random(2, 4)). Each tick the leading front reaches a
-- new pixel p with p + 2 on the column draws the glint (random(1, 100) <= GLINT_PERCENT). Then, bottom to top,
-- a pixel seen passed by a front for the first time draws its tail: the time (TAIL_MS), its first colour
-- (random(1, #SPARKS)), then each gap (random(lo, 4)) and each relight's colour, until the tail time is out. A
-- rest draws its length (REST_MS). A random that fails or answers no number takes the middle of the range.
--
-- Choices where the contract is silent (each covered by tests/spec/breezeleds_spec.lua):
--   * Pixels are positions: a set_pixels change mid-gust keeps the gust; a new pixel is taken and sent dark at
--     once (a repaint after its bind sends it what it shows). A pixel bound during the leave is not taken.
--   * A bottom change while running darkens what is lit and rests; during the leave it settles at once.
--   * repaint(link) sends what the pixel shows: lit, paint(colour, true, false); otherwise light(false), and its
--     loaded colour counts as unknown (the keypad that asked may hold its own).
--   * update{} without `breeze` keeps the strength it has (listener.phase may send `online` alone); with
--     `breeze` the strength is read too, nil meaning unknown. A missing key of configure{} or update{} keeps
--     its value. stop() is final: every later call is ignored (held() answers false).
--
-- Pure like fan/links.lua: nothing here touches Director. Every option is called through pcall; a failure is
-- logged, never raised, and the animation goes on as best it can:
--
--   local b = breezeleds.new({
--       paint = fn(link, colour, with_state, preload),  -- links:paint
--       light = fn(link, lit),                          -- links:light
--       settle = fn(link),                              -- links:settle
--       timer = fn(ms, cb) -> handle,                   -- handle:Cancel(); the driver's one-shot timer
--       random = fn(lo, hi) -> integer,                 -- inclusive; math.random in the driver
--       now = fn() -> ms,                               -- a clock (only differences are used); optional
--       log = log,                                      -- default common.log
--   })
--   b:configure({ enabled = bool, per_speed = bool, bottom = 1 | 6, step = ms })
--   b:set_pixels(list)       -- the bound speed links, any order, duplicates ignored, only 301 to 306 kept
--   b:update({ breeze = bool, strength = 1 | 2 | 3 | nil, online = bool })
--   b:held(link) -> bool     -- the links ask before sending a speed link anything (BL-D15)
--   b:repaint(link) -> bool  -- a held pixel's REQUEST_BUTTON_COLORS or new binding: what it shows
--   b:stop()                 -- OnDriverDestroyed: cancel the timer, forget every hold, send nothing
--   b:debug() -> table       -- phase, pixels, held, what each shows, step, ranges, gust, budget
--
-- Lua 5.1: no goto, no integer division, no bit operators.

local breezeleds = {}

breezeleds.HEAD = "ffffff"
breezeleds.SPARKS = { "a0ffff", "00ffff", "40b0ff" } -- ice, teal, sky (BL-D20)
breezeleds.GLINT = "40b0ff"
breezeleds.TICK_MS = 50
breezeleds.STEP_MIN = 60
breezeleds.STEP_MAX = 400
breezeleds.STEP_DEFAULT = 120
breezeleds.JITTER_PERCENT = 20 -- a gust's front step, drawn once a gust (BL-D21)
breezeleds.BUDGET_PER_S = 30 -- messages in any WINDOW_MS (BL-D24)
breezeleds.WINDOW_MS = 1000
breezeleds.REST_MS = { [1] = { 4000, 8000 }, [2] = { 2000, 5000 }, [3] = { 1000, 3000 } } -- BL-D22
breezeleds.TAIL_MS = { [1] = { 300, 500 }, [2] = { 500, 800 }, [3] = { 700, 1100 } } -- BL-D26
breezeleds.DOUBLE_PERCENT = { [1] = 10, [2] = 25, [3] = 40 } -- BL-D22
breezeleds.DOUBLE_GAP_STEPS = { 2, 4 } -- the second front, in front steps behind the first (BL-D21)
breezeleds.TAIL_GAP_TICKS = { 2, 4 } -- a tail's blink gaps (BL-D26)
breezeleds.GLINT_PERCENT = 30 -- the chance of a glint two pixels above the leading front, as it reaches a pixel
breezeleds.DEFAULT_STRENGTH = 2 -- a strength that is nil or unknown (BL-D22)
breezeleds.DARKEN_TICKS = 20 -- after a gust, ticks waiting for room to darken a pixel still lit
breezeleds.RECOLOUR_NEEDS_STATE = false -- BL-D23: BUTTON_COLORS with CURRENT_COLOR repaints a lit button (measured)
breezeleds.FIRST_LINK = 301 -- the speed links, the only links that ever animate (BL-D2)
breezeleds.LAST_LINK = 306

local HEAD = breezeleds.HEAD

-- The phases in which the animation holds its pixels and runs its cycle.
local RUNNING = { gust = true, rest = true }

local Leds = {}
Leds.__index = Leds

-- Helpers ----------------------------------------------------------------------------------------------------

-- fn(...) in pcall; a function that is not there fails like one that raises.
local function try(fn, ...)
	if type(fn) ~= "function" then
		return false, "not given"
	end
	return pcall(fn, ...)
end

-- A finite number from a number or a numeric string, else nil.
local function number_of(value)
	local n = tonumber(value)
	if n == nil or n ~= n or n == math.huge or n == -math.huge then
		return nil
	end
	return n
end

local function round(n)
	return math.floor(n + 0.5)
end

-- ceil(a / b) for a >= 0 and b > 0.
local function ceil_div(a, b)
	return math.ceil(a / b)
end

-- The step time: rounded and held within STEP_MIN to STEP_MAX; anything not a number is the default.
local function step_of(value)
	local n = number_of(value)
	if n == nil then
		return breezeleds.STEP_DEFAULT
	end
	n = round(n)
	if n < breezeleds.STEP_MIN then
		return breezeleds.STEP_MIN
	elseif n > breezeleds.STEP_MAX then
		return breezeleds.STEP_MAX
	end
	return n
end

-- 1, 2 or 3; nil for anything else (unknown).
local function strength_of(value)
	local n = number_of(value)
	if n ~= nil and breezeleds.REST_MS[n] ~= nil then
		return n
	end
	return nil
end

-- The speed links of a list, ascending, each once.
local function links_of(list)
	local seen, out = {}, {}
	if type(list) ~= "table" then
		return out
	end
	for _, value in pairs(list) do
		local n = number_of(value)
		if n ~= nil and n == math.floor(n) and n >= breezeleds.FIRST_LINK and n <= breezeleds.LAST_LINK
				and not seen[n] then
			seen[n] = true
			out[#out + 1] = n
		end
	end
	table.sort(out)
	return out
end

local function same_list(a, b)
	if #a ~= #b then
		return false
	end
	for i = 1, #a do
		if a[i] ~= b[i] then
			return false
		end
	end
	return true
end

-- The instance -----------------------------------------------------------------------------------------------

function breezeleds.new(opts)
	opts = type(opts) == "table" and opts or {}
	return setmetatable({
		o = opts,
		log = opts.log or require("common.log"),
		-- configure
		enabled = false,
		per_speed = false,
		bottom = 1,
		step = breezeleds.STEP_DEFAULT,
		-- update
		breeze = false,
		strength = nil,
		online = false,
		-- set_pixels
		links = {}, -- the bound speed links, ascending
		order = {}, -- the pixels, pixel 1 (the bottom) first
		-- the animation
		phase = "idle",
		head = 0, -- the falling wipe's pixel
		gust = nil, -- the running gust (gust phase)
		hold = {}, -- [link] = true while the animation holds it
		shows = {}, -- [link] = { lit = true | false | nil (unknown), colour = loaded colour or nil (unknown) }
		-- time and the budget
		vt = 0, -- the engine's time, ms
		cref = nil, -- the clock when vt was last brought up to it
		window = {}, -- the engine times of the messages of the last WINDOW_MS, oldest first
		reserve = 0, -- messages kept for the fronts due within the window (during a gust tick)
		dropped = 0, -- changes dropped for the budget, all told
		random_failed = false,
		-- the timer
		handle = nil,
		armed = false,
		gen = 0, -- bumped by every cancel: a callback of an older arm is ignored
		arm_vt = 0, -- vt when the pending timer was armed
		arm_ms = 0, -- and for how long
		stopped = false,
	}, Leds)
end

function Leds:say(level, template, ...)
	local sink = self.log
	local fn = type(sink) == "table" and sink[level] or nil
	if type(fn) ~= "function" then
		return
	end
	local ok, text = pcall(string.format, template, ...)
	pcall(fn, "%s", "Breeze LEDs: " .. (ok and text or tostring(template)))
end

function Leds:active()
	return self.enabled and self.per_speed and self.online and self.breeze and #self.order > 0
end

-- Breeze ended while everything else still holds: the falling wipe plays (BL-D8). Any other way out of active
-- settles at once (BL-D11).
function Leds:leaving()
	return self.enabled and self.per_speed and self.online and not self.breeze and #self.order > 0
end

function Leds:any_held()
	return next(self.hold) ~= nil
end

function Leds:reorder()
	local order, n = {}, #self.links
	for i = 1, n do
		order[i] = self.bottom == 6 and self.links[n + 1 - i] or self.links[i]
	end
	self.order = order
end

function Leds:strength_now()
	return self.strength or breezeleds.DEFAULT_STRENGTH
end

function Leds:rest_range()
	return breezeleds.REST_MS[self:strength_now()]
end

-- Randomness -------------------------------------------------------------------------------------------------

-- random(lo, hi) as an integer within lo to hi; a random that fails or answers no number takes the middle.
function Leds:draw(lo, hi)
	local ok, n = try(self.o.random, lo, hi)
	n = ok and number_of(n) or nil
	if n == nil then
		if not self.random_failed then
			self.random_failed = true
			self:say("warn", "no random number (%s); taking the middle of each range", ok and "not a number"
				or tostring(n))
		end
		return math.floor((lo + hi) / 2)
	end
	self.random_failed = false
	n = math.floor(n)
	if n < lo then
		return lo
	elseif n > hi then
		return hi
	end
	return n
end

function Leds:chance(percent)
	return self:draw(1, 100) <= percent
end

-- Time -------------------------------------------------------------------------------------------------------

function Leds:clock()
	if self.o.now == nil then
		return nil
	end
	local ok, t = try(self.o.now)
	if not ok then
		self:say("warn", "the clock failed: %s", tostring(t))
		return nil
	end
	return number_of(t)
end

-- Brings the engine's time up to the clock: it follows the clock forwards and never runs backwards. A clock
-- that fails is taken up again from where it is when it is back.
function Leds:advance_time()
	local c = self:clock()
	if c == nil then
		self.cref = nil
	else
		if self.cref ~= nil and c > self.cref then
			self.vt = self.vt + (c - self.cref)
		end
		self.cref = c
	end
	return self.vt
end

-- The timer --------------------------------------------------------------------------------------------------

function Leds:cancel()
	self.gen = self.gen + 1
	self.armed = false
	local handle = self.handle
	self.handle = nil
	if handle ~= nil then
		local ok, err = pcall(function() handle:Cancel() end)
		if not ok then
			self:say("warn", "the timer could not be cancelled: %s", tostring(err))
		end
	end
end

function Leds:arm(ms)
	self:cancel()
	ms = math.max(1, round(ms))
	local gen = self.gen
	local ok, handle = try(self.o.timer, ms, function() self:fire(gen) end)
	if not ok then
		self:say("error", "the timer could not be armed (%s ms): %s", tostring(ms), tostring(handle))
		return
	end
	self.handle, self.armed = handle, true
	self.arm_vt, self.arm_ms = self.vt, ms
end

function Leds:arm_rest()
	local range = self:rest_range()
	self:arm(self:draw(range[1], range[2]))
end

function Leds:fire(gen)
	if self.stopped or gen ~= self.gen then
		return
	end
	self.handle, self.armed = nil, false
	self:advance_time()
	local due = self.arm_vt + self.arm_ms
	if self.vt < due then
		self.vt = due -- a timer is never early on the engine's time, and without a clock this is its time
	end
	if self.phase == "rest" then
		self:start_gust()
	elseif self.phase == "gust" then
		self:gust_tick()
	elseif self.phase == "leave" then
		self:wipe_tick(due)
	end
end

-- The budget (BL-D24) ----------------------------------------------------------------------------------------

function Leds:prune()
	local cut, window = self.vt - breezeleds.WINDOW_MS, self.window
	local first = 1
	while window[first] ~= nil and window[first] <= cut do
		first = first + 1
	end
	if first > 1 then
		local kept = {}
		for i = first, #window do
			kept[#kept + 1] = window[i]
		end
		self.window = kept
	end
end

function Leds:stamp(count)
	self:prune()
	for _ = 1, count do
		self.window[#self.window + 1] = self.vt
	end
end

function Leds:room(count)
	self:prune()
	return #self.window + self.reserve + count <= breezeleds.BUDGET_PER_S
end

function Leds:drop()
	self.dropped = self.dropped + 1
	if self.gust then
		self.gust.dropped = self.gust.dropped + 1
	end
	return false
end

-- Sends ------------------------------------------------------------------------------------------------------

function Leds:record(link)
	local s = self.shows[link]
	if s == nil then
		s = {}
		self.shows[link] = s
	end
	return s
end

function Leds:send_light(link, lit)
	self:stamp(1)
	local s = self:record(link)
	local ok, err = try(self.o.light, link, lit)
	if not ok then
		self:say("warn", "link %d could not be %s: %s", link, lit and "lit" or "darkened", tostring(err))
		s.lit = nil
		return false
	end
	s.lit = lit
	return true
end

function Leds:send_paint(link, colour, with_state, preload)
	self:stamp(with_state and 2 or 1)
	local s = self:record(link)
	local ok, err = try(self.o.paint, link, colour, with_state, preload)
	if not ok then
		self:say("warn", "link %d could not be painted %s: %s", link, colour, tostring(err))
		s.colour = nil
		if with_state then
			s.lit = nil
		end
		return false
	end
	s.colour = colour
	if with_state then
		s.lit = true
	end
	return true
end

-- Brings a held pixel to lit in `colour`, or dark (BL-D23), with the fewest messages; nothing when it shows that
-- already. Unless `must`, only when the budget has room for all of it and `spare` more (else dropped). true when
-- it shows it.
function Leds:apply(link, lit, colour, must, spare)
	local s = self:record(link)
	local function fits(count)
		return must or self:room(count + (spare or 0))
	end
	if not lit then
		if s.lit == false then
			return true
		elseif not fits(1) then
			return self:drop()
		end
		return self:send_light(link, false)
	end
	if s.lit == true then
		if s.colour == colour then
			return true
		end
		local with_state = breezeleds.RECOLOUR_NEEDS_STATE == true
		if not fits(with_state and 2 or 1) then
			return self:drop()
		end
		return self:send_paint(link, colour, with_state, false)
	elseif s.lit == false then
		local loaded = s.colour == colour
		if not fits(loaded and 1 or 2) then
			return self:drop()
		end
		if not loaded and not self:send_paint(link, colour, false, true) then
			return false
		end
		return self:send_light(link, true)
	end
	if not fits(2) then
		return self:drop()
	end
	return self:send_paint(link, colour, true, false)
end

function Leds:take(link)
	self.hold[link] = true
	self.shows[link] = {}
end

-- Hands the link back: no longer held when the links hear settle(link), so they send its real state.
function Leds:release(link)
	self.hold[link] = nil
	self.shows[link] = nil
	self:stamp(2)
	local ok, err = try(self.o.settle, link)
	if not ok then
		self:say("warn", "link %d could not be settled: %s", link, tostring(err))
	end
end

-- Gusts (BL-D21, BL-D22, BL-D26) -----------------------------------------------------------------------------

-- The front f's position at tick n: 0 below pixel 1, then one pixel per front step.
local function front_at(g, f, n)
	local x = n * breezeleds.TICK_MS - g.offsets[f]
	if x < 0 then
		return 0
	end
	return math.floor(x / g.fstep)
end

-- The tick at which front f reaches pixel i (i = 1, 2, ...); pixel i + 1's is when it leaves pixel i.
local function arrival(g, f, i)
	return ceil_div(i * g.fstep + g.offsets[f], breezeleds.TICK_MS)
end

-- A tail (BL-D26): its length in ticks and its changes { at = tick within it, lit, colour }, lit first.
function Leds:draw_tail(g)
	local range = breezeleds.TAIL_MS[g.strength]
	local ticks = math.max(1, round(self:draw(range[1], range[2]) / breezeleds.TICK_MS))
	local sparks = breezeleds.SPARKS
	local changes = { { at = 0, lit = true, colour = sparks[self:draw(1, #sparks)] } }
	local lo, hi = breezeleds.TAIL_GAP_TICKS[1], breezeleds.TAIL_GAP_TICKS[2]
	local at, lit = 0, true
	while true do
		-- The gap's low end rises from lo to hi over the tail: the gaps grow, the tail thins out.
		local low = math.min(hi, lo + math.floor((hi - lo + 1) * at / ticks))
		at = at + self:draw(low, hi)
		if at >= ticks then
			break
		end
		lit = not lit
		changes[#changes + 1] = { at = at, lit = lit, colour = lit and sparks[self:draw(1, #sparks)] or nil }
	end
	return { ticks = ticks, changes = changes }
end

local function tail_state(tail, age)
	local state = tail.changes[1]
	for _, change in ipairs(tail.changes) do
		if change.at <= age then
			state = change
		end
	end
	return state.lit, state.colour
end

function Leds:start_gust()
	local strength = self:strength_now()
	local step = self.step
	local lo = round(step * (100 - breezeleds.JITTER_PERCENT) / 100)
	local hi = round(step * (100 + breezeleds.JITTER_PERCENT) / 100)
	local fstep = math.max(breezeleds.TICK_MS, self:draw(lo, hi))
	local offsets = { 0 }
	if self:chance(breezeleds.DOUBLE_PERCENT[strength]) then
		offsets[2] = self:draw(breezeleds.DOUBLE_GAP_STEPS[1], breezeleds.DOUBLE_GAP_STEPS[2]) * fstep
	end
	self.gust = {
		t0 = self.vt, -- tick 0
		n = -1, -- the tick last applied
		fstep = fstep,
		offsets = offsets,
		strength = strength,
		tails = {}, -- [f][i] = the tail front f left on pixel i
		glints = {}, -- [i] = the tick pixel i glints
		lead = 0, -- the leading front's position at the tick last applied
		waited = 0, -- ticks spent after the gust waiting to darken
		dropped = 0,
	}
	local g = self.gust
	if offsets[2] ~= nil then
		-- A double gust only when both fronts fit the budget with what the window holds (BL-D24).
		self:prune()
		if #self.window + self:fronts_cost(g, -1, math.huge) > breezeleds.BUDGET_PER_S then
			self:say("debug", "no room in the budget for a second front: a single gust")
			offsets[2] = nil
		end
	end
	for f = 1, #offsets do
		g.tails[f] = {}
	end
	self.phase = "gust"
	self:say("debug", "a gust: a front step of %d ms%s, strength %d", fstep,
		offsets[2] and string.format(", a second front %d steps behind", offsets[2] / fstep) or "", strength)
	self:gust_at(0)
end

-- The tick that fell due last; never the same tick twice.
function Leds:gust_tick()
	local g = self.gust
	local n = math.floor((self.vt - g.t0) / breezeleds.TICK_MS)
	if n <= g.n then
		n = g.n + 1
	elseif n > g.n + 1 then
		self:say("debug", "a late tick: %d ticks applied together", n - g.n)
	end
	self:gust_at(n)
end

-- What the fronts may still send after tick `from` up to tick `to`: 2 for each arrival (a preload and a light,
-- or a paint with the state) and a recolour for each pixel a front leaves white behind it.
function Leds:fronts_cost(g, from, to)
	local recolour = breezeleds.RECOLOUR_NEEDS_STATE == true and 2 or 1
	local cost = 0
	for f = 1, #g.offsets do
		for i = 1, #self.order do
			local a, leaves = arrival(g, f, i), arrival(g, f, i + 1)
			if a > from and a <= to then
				cost = cost + 2
			end
			if leaves > from and leaves <= to then
				cost = cost + recolour
			end
		end
	end
	return cost
end

-- The gust at tick n: what every pixel wants, sent within the budget (BL-D24), then the next tick or the rest.
function Leds:gust_at(n)
	local g, order = self.gust, self.order
	local count = #order
	g.n = n
	local front, over = {}, true
	for f = 1, #g.offsets do
		local p = front_at(g, f, n)
		if p >= 1 and p <= count then
			front[p] = true
		end
		if p <= count then
			over = false
		end
	end
	local lead = front_at(g, 1, n)
	if lead > g.lead then
		g.lead = lead
		local target = lead + 2
		if lead >= 1 and target <= count and g.glints[target] == nil and self:chance(breezeleds.GLINT_PERCENT) then
			g.glints[target] = n
		end
	end
	-- What each pixel wants, by class. Always sent: the front, and a pixel a front has left that still shows
	-- HEAD (the front moving on). Dropped first when the budget is short, in this order: a pixel to darken, a
	-- tail change (going dark before relighting, so a starved tail thins out; the youngest first), a glint
	-- (only with room to darken it at the next tick too).
	local musts, darks, tails, glints = {}, {}, {}, {}
	for i, link in ipairs(order) do
		local lit, colour, age = true, HEAD, nil
		if not front[i] then
			local passed
			for f = #g.offsets, 1, -1 do
				if front_at(g, f, n) > i then
					passed = f
					break
				end
			end
			if passed ~= nil then
				local tail = g.tails[passed][i]
				if tail == nil then
					tail = self:draw_tail(g)
					tail.from = arrival(g, passed, i + 1)
					g.tails[passed][i] = tail
				end
				age = n - tail.from
				if age < tail.ticks then
					over = false
					lit, colour = tail_state(tail, age)
				else
					age = nil
				end
			end
			if age == nil then
				if g.glints[i] == n then
					lit, colour = true, breezeleds.GLINT
				else
					lit, colour = false, nil
				end
			end
		end
		local s = self.shows[link]
		local want = { link = link, lit = lit, colour = colour, age = age, i = i }
		if front[i] or (s ~= nil and s.lit == true and s.colour == HEAD) then
			musts[#musts + 1] = want
		elseif age ~= nil then
			tails[#tails + 1] = want
		elseif lit then
			glints[#glints + 1] = want
		else
			darks[#darks + 1] = want
		end
	end
	table.sort(tails, function(a, b)
		if a.lit ~= b.lit then
			return not a.lit
		elseif a.age ~= b.age then
			return a.age < b.age
		end
		return a.i < b.i
	end)
	self.reserve = 0
	for _, w in ipairs(musts) do
		self:apply(w.link, w.lit, w.colour, true)
	end
	self.reserve = self:fronts_cost(g, n, n + math.floor(breezeleds.WINDOW_MS / breezeleds.TICK_MS))
	for _, list in ipairs({ darks, tails }) do
		for _, w in ipairs(list) do
			self:apply(w.link, w.lit, w.colour, false)
		end
	end
	for _, w in ipairs(glints) do
		self:apply(w.link, w.lit, w.colour, false, 1)
	end
	self.reserve = 0
	if over then
		local lit = false
		for _, link in ipairs(order) do
			if self.shows[link] == nil or self.shows[link].lit ~= false then
				lit = true
			end
		end
		if not lit or g.waited >= breezeleds.DARKEN_TICKS then
			self:say("debug", "the gust is over after %d ticks%s; %d change(s) dropped for the budget", n,
				lit and ", a pixel still not dark" or "", g.dropped)
			self:start_rest()
			return
		end
		g.waited = g.waited + 1
	end
	self:arm(g.t0 + (n + 1) * breezeleds.TICK_MS - self.vt)
end

-- Phases -----------------------------------------------------------------------------------------------------

function Leds:idle(why)
	self:cancel()
	self.phase, self.head, self.gust = "idle", 0, nil
	self.hold, self.shows = {}, {}
	self:say("debug", "idle (%s)", why)
end

-- Every held pixel back to the links at once, no wipe (BL-D11).
function Leds:settle_all(why)
	self:cancel()
	local n = 0
	for _, link in ipairs(self.order) do
		if self.hold[link] then
			n = n + 1
			self:release(link)
		end
	end
	self:idle(string.format("%s; %d pixel(s) settled at once", why, n))
end

-- Every pixel taken and dark at once, then the first gust at once (BL-D19).
function Leds:start()
	self:cancel()
	self.hold, self.shows, self.head = {}, {}, 0
	for _, link in ipairs(self.order) do
		self:take(link)
		self:send_light(link, false)
	end
	self:say("debug", "Breeze: %d pixel(s) dark, the first gust starts", #self.order)
	self:start_gust()
end

-- A rest: whatever is still lit goes dark (always sent), then one timer for the rest's length.
function Leds:start_rest()
	self:cancel()
	self.phase, self.gust = "rest", nil
	for _, link in ipairs(self.order) do
		if self.hold[link] then
			self:apply(link, false, nil, true)
		end
	end
	self:arm_rest()
end

-- The falling wipe's frame: the head HEAD if held, every held pixel above it settled, top down (BL-D8, BL-D25).
function Leds:wipe_frame()
	local h, order = self.head, self.order
	local link = order[h]
	if link ~= nil and self.hold[link] then
		self:apply(link, true, HEAD, true)
	end
	for i = #order, h + 1, -1 do
		if self.hold[order[i]] then
			self:release(order[i])
		end
	end
end

function Leds:start_leave()
	self:cancel()
	self.gust = nil
	local top = 0
	for i, link in ipairs(self.order) do
		if self.hold[link] then
			top = i
		end
	end
	if top == 0 then
		self:idle("Breeze ended; nothing held")
		return
	end
	self.phase, self.head = "leave", top
	self:say("debug", "Breeze ended: the falling wipe from pixel %d", top)
	self:wipe_frame()
	self:arm(self.step)
end

-- A step of the wipe; the steps that fell due since `due` together (BL-D13), the next on the cadence.
function Leds:wipe_tick(due)
	local step = self.step
	local k = 1 + math.floor((self.vt - due) / step)
	if k > 1 then
		self:say("debug", "a late tick: %d steps of the falling wipe together", k)
	end
	self.head = math.max(0, self.head - k)
	self:wipe_frame()
	if self.head < 1 or not self:any_held() then
		self:idle("the falling wipe is done")
		return
	end
	self:arm(due + k * step - self.vt)
end

-- Applies BL-D8 to BL-D11 and BL-D19 to the inputs as they are now.
function Leds:evaluate(why)
	if self:active() then
		if self.phase == "idle" or self.phase == "leave" then
			self:start()
		end
	elseif self.phase ~= "idle" then
		if not self:leaving() then
			self:settle_all(why)
		elseif RUNNING[self.phase] then
			self:start_leave()
		end
	end
end

-- The interface ----------------------------------------------------------------------------------------------

function Leds:configure(c)
	if self.stopped then
		return
	end
	self:advance_time()
	c = type(c) == "table" and c or {}
	if c.enabled ~= nil then
		self.enabled = c.enabled == true
	end
	if c.per_speed ~= nil then
		self.per_speed = c.per_speed == true
	end
	if c.step ~= nil then
		self.step = step_of(c.step) -- from the next gust, or the wipe's next arm
	end
	local moved = false
	if c.bottom ~= nil then
		local bottom = number_of(c.bottom) == 6 and 6 or 1
		if bottom ~= self.bottom then
			self.bottom = bottom
			self:reorder()
			moved = true
		end
	end
	if moved and RUNNING[self.phase] and self:active() then
		self:say("debug", "the bottom is now speed %d: dark and a rest", self.bottom)
		self:start_rest()
	elseif moved and self.phase == "leave" then
		self:settle_all("the bottom changed during the falling wipe")
	else
		self:evaluate("configure")
	end
end

function Leds:update(u)
	if self.stopped then
		return
	end
	self:advance_time()
	u = type(u) == "table" and u or {}
	if u.breeze ~= nil then
		self.breeze = u.breeze == true
	end
	if u.online ~= nil then
		self.online = u.online == true
	end
	if u.breeze ~= nil or u.strength ~= nil then
		self.strength = strength_of(u.strength) -- from the next gust or rest
	end
	self:evaluate(self.online and "update" or "not online")
end

function Leds:set_pixels(list)
	if self.stopped then
		return
	end
	local links = links_of(list)
	if same_list(links, self.links) then
		return
	end
	self:advance_time()
	local before, now = {}, {}
	for _, link in ipairs(self.links) do
		before[link] = true
	end
	for _, link in ipairs(links) do
		now[link] = true
	end
	-- A link that lost its last button is dropped without a send: it keeps its last colour (BL-D16).
	for link in pairs(before) do
		if not now[link] then
			self.hold[link], self.shows[link] = nil, nil
		end
	end
	self.links = links
	self:reorder()
	if RUNNING[self.phase] and self:active() then
		-- A link that gained a button joins at once, dark (BL-D16, BL-D19); the gust goes on over the new column.
		for _, link in ipairs(self.order) do
			if not before[link] then
				self:take(link)
				self:send_light(link, false)
			end
		end
	elseif self.phase == "leave" and self:leaving() then
		if self.head > #self.order then
			self.head = #self.order
		end
		self:wipe_frame()
		if not self:any_held() then
			self:idle("the falling wipe has no pixel left")
		end
	else
		self:evaluate("pixels")
	end
end

function Leds:held(link)
	return self.hold[number_of(link) or link] == true
end

-- A held pixel's REQUEST_BUTTON_COLORS or new binding (BL-D15): what it shows, sent whole.
function Leds:repaint(link)
	if self.stopped then
		return false
	end
	link = number_of(link) or link
	if not self.hold[link] then
		return false
	end
	self:advance_time()
	local s = self:record(link)
	if s.lit == true and s.colour ~= nil then
		return self:send_paint(link, s.colour, true, false)
	end
	s.colour = nil
	return self:send_light(link, false)
end

function Leds:stop()
	self:cancel()
	self.stopped = true
	self.phase, self.head, self.gust = "idle", 0, nil
	self.hold, self.shows = {}, {}
end

function Leds:debug()
	local pixels, held, frame, loaded = {}, {}, {}, {}
	for i, link in ipairs(self.order) do
		pixels[i] = link
		if self.hold[link] then
			held[link] = true
			local s = self.shows[link] or {}
			if s.lit == true then
				frame[link] = s.colour or "unknown"
			elseif s.lit == false then
				frame[link] = "dark"
			else
				frame[link] = "unknown"
			end
			loaded[link] = s.colour
		end
	end
	local strength = self:strength_now()
	local rest, tail = self:rest_range(), breezeleds.TAIL_MS[strength]
	local g = self.gust
	self:prune()
	return {
		phase = self.phase,
		head = self.head,
		pixels = pixels,
		held = held,
		frame = frame,
		loaded = loaded,
		step = self.step,
		rest = { rest[1], rest[2] },
		tail = { tail[1], tail[2] },
		double = breezeleds.DOUBLE_PERCENT[strength],
		strength = self.strength,
		bottom = self.bottom,
		enabled = self.enabled,
		per_speed = self.per_speed,
		online = self.online,
		breeze = self.breeze,
		active = self:active() == true,
		pending = self.armed,
		stopped = self.stopped,
		gust = g and {
			tick = g.n,
			step = g.fstep,
			offsets = { g.offsets[1], g.offsets[2] },
			strength = g.strength,
			dropped = g.dropped,
		} or nil,
		budget = { sent = #self.window, limit = breezeleds.BUDGET_PER_S, dropped = self.dropped },
	}
end

return breezeleds
