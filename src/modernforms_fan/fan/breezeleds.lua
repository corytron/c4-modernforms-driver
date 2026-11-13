-- fan/breezeleds.lua: Breeze on the keypad LEDs (#137). The contract is docs/breeze-leds-design.md: section 1
-- (BL-D1 to BL-D18) as revised by section 1a (BL-D19 to BL-D30, which replace BL-D5 to BL-D7, BL-D12, BL-D14
-- and BL-D22's sparkle ticks), this module's interface (section 3.1 and section 1a's interface block) and what
-- the owner sees; the reasons are docs/edge-cases-breeze-leds.md (BL1 to BL70), docs/breeze-leds-sdk-research.md
-- section 6 and the keypad probes of #137 (2026-11-09).
--
-- While the fan blows Breeze, the keypad buttons on the fan's bound speed links (301 to 306, the pixels; BL-D2)
-- play gusts. Pixel 1 is the bottom: the lowest link, or the highest with bottom = 6 (BL-D4). Colours (BL-D20):
-- the front HEAD (white), the tail's SPARKS (ice, teal, sky) and the glint GLINT (sky); full values only.
--
--   idle   nothing held, nothing sent.
--   gust   (BL-D21, BL-D26, BL-D27) a front rises from below pixel 1, one position per front step (the step
--          property drawn once a gust within +-JITTER_PERCENT, never under TICK_MS, so the front never skips a
--          pixel on time), and runs on past the top, unseen, at the same pace. The pixel a front is on is HEAD.
--          Behind each front runs its tail: the pixels its head passed within the last L front steps, L = the
--          gust's tail time (drawn once a gust in TAIL_MS[strength]) over its front step, rounded, at least 1.
--          A pixel joins the tail lit in a SPARKS colour as the head leaves it, then blinks off and on at gaps
--          drawn in TAIL_GAP_TICKS, relighting each time in a SPARKS colour drawn again; the gap's low end rises
--          with the pixel's place in the tail, so the back edge blinks least; each pixel draws its own gaps, so
--          neighbours never blink in step. A dark tail pixel relights only while the pixel above it shows lit,
--          is that front's head, or lies past the top, so a twinkle never travels down. The pixel the back edge
--          leaves goes dark and stays dark for the rest of the gust (unless a later front's head reaches it). So
--          no tail twinkles without its head ahead of it, on the column or just past its top. When the leading
--          front reaches pixel p, pixel p + 2 may glint GLINT for one tick (GLINT_PERCENT; once a pixel a gust).
--          With DOUBLE_PERCENT[strength] a second front follows DOUBLE_GAP_STEPS (2 to 4) front steps behind,
--          with its own tail; a pixel belongs to the tail of the latest front that passed it. Every other pixel
--          is dark. When every back edge has passed the top (N + 1 + L steps for N pixels): a rest.
--          Direction (BL-D30): the above is a gust blowing up, the fan in reverse (and when its direction is
--          unknown). With the fan blowing down (forward) the gust runs the same way down the column: it enters
--          at the top pixel, its tail trails above its head, its head runs on past the bottom, its glints come
--          below it, and a dark tail pixel relights only while the pixel below it is lit, the head or past the
--          bottom. Positions count along the gust's lane, so everything above holds mirrored.
--   rest   (BL-D19, BL-D22) every pixel dark, nothing sent and no ticking: one timer for a time drawn in
--          REST_MS[strength], then the next gust.
--   leave  (BL-D8, BL-D25, BL-D30) the ending wipe, once, when Breeze ends while online and everything else
--          still holds, the other way from the gusts (in the direction at its start): after rising gusts the head
--          (HEAD) starts on the top held pixel and falls one pixel per step (the step property, not jittered);
--          after downward gusts it starts on the bottom held pixel and rises. Each pixel it leaves is settled
--          (settle(link): the links send its real state). A pixel the head has not reached keeps what it shows
--          (a tail is frozen). The last pixel settled: idle.
--
-- Start (BL-D19): from idle, or when Breeze is back during the leave (BL-D10), every pixel is taken (held) and
-- sent dark at once, and the first gust starts at once; its front enters pixel 1 one front step later, so the
-- dark shows first. Active means enabled, per_speed, online, breeze, at least one pixel and the keypad not dark.
-- Any other way out of active settles every held pixel at once, with no wipe (BL-D11). Leave during a gust or a
-- rest starts the ending wipe at once (BL-D10). The strength and the direction are read when a gust starts (its
-- tail, double and way) and the strength when a rest is armed; the direction when the wipe starts; a step change
-- applies from the next gust, and in the wipe from the next arm. A change of strength or direction alone sends
-- nothing.
--
-- The keypad's dark (#207, docs/ambient-pause-design.md AP-D6 to AP-D8; docs/edge-cases-led-dimming.md DM16 to
-- DM21): configure{ dark = true } takes the animation out of active and out of leaving alike, so it stops the
-- way BL-D11 stops it: every held pixel settled once, at once, with no ending wipe, whether the first gust after
-- the dark-first, a later gust, a rest or the ending wipe was running. While dark nothing animates and nothing is
-- armed: Breeze starting starts nothing, Breeze ending plays no wipe, now or later. dark = false with Breeze
-- still blowing (and the rest of active holding) starts again as Breeze starting does (BL-D19): dark first, then
-- the first gust; nothing missed is replayed. The engine never sends black, a dark state or a scaled colour in
-- the keypad's place (AP-D8): pausing only stops frames, and the steady LEDs are the links'. Night (BL-D28) is
-- separate and unchanged. Whether the keypad is dark is the driver's to decide (fan/ambient.lua).
--
-- Messages (BL-D23): what the keypad shows is kept per pixel (lit, dark or unknown, and the colour loaded) and
-- only real changes are sent: a dark pixel's colour is preloaded with paint(link, colour, false, true) and shown
-- with light(link, true); a lit pixel changes colour with paint(link, colour, RECOLOUR_NEEDS_STATE, false);
-- dark is light(link, false); a pixel whose state is unknown is lit with paint(link, colour, true, false). A
-- send that fails leaves that part unknown, so the next tick sends it again.
--
-- Night (BL-D28): while configure's `night` is true and `night_percent` is under 100, every colour the animation
-- lights (heads, tails, glints, the falling wipe's head) is sent through breezeleds.scale(colour, night_percent);
-- settles are the links' own colours, untouched. A change of night or percent applies from the next colour the
-- engine sends and sends nothing by itself: a pixel lit in the colour it should show keeps the brightness it
-- was lit at, while relighting a dark pixel compares the scaled colours, so a colour loaded at the other
-- brightness is preloaded again and one loaded at this brightness is not. The day-or-night decision is the
-- driver's (fan/sun.lua, BL-D29).
--
-- One clock and a budget (BL-D24, BL-D13): one one-shot timer at a time, re-armed every TICK_MS while a gust
-- runs, every step while the wipe runs, once for the rest's length during a rest; every phase change, stop and
-- re-arm cancel the pending one first, and a callback of a cancelled timer is ignored. The engine keeps its own
-- time, which follows the `now` clock and never runs backwards (without a clock, or while it fails, a tick
-- advances it by the time the timer was armed for). The budget is a sliding window: every message is stamped
-- with that time (a paint 1, 2 with the state; a light 1; a settle 2, its colours and its state) and at most
-- BUDGET_PER_S may fall in any WINDOW_MS. Always sent and counted: the heads, a pixel a front has left that
-- still shows HEAD, the darkening behind a tail's back edge (BL-D27: skipping it would leave a tail without its
-- head), the dark-first, settles, the wipe and repaints. A tail pixel going dark, a relight, a glint and the
-- darkening of a glint are sent only when the window has room for them on top of a reserve for what the gust
-- itself must still send in the next WINDOW_MS (its schedule, worst case: 2 an arrival, 1 a recolour as a
-- head leaves a pixel, 1 a back-edge darkening), so a gust's own musts always fit; otherwise they are dropped
-- for this tick (a glint's darkening first in line, then tail pixels going dark, then relights, top down, then
-- glints, which light only with room to darken them at the next tick), and what is still wanted is tried
-- again at the next tick; a relight that has to wait is checked against the pixel above again. A double gust
-- runs only when its schedule, with what the window holds, keeps every second within the budget; otherwise it
-- is single (4 pixels always fit after the first gust, whose dark-first counts too; 5 and 6 pixels fit only
-- at slow steps). So only calls from outside (a leave, a new pixel, a repaint) can push a window past the
-- budget. A late tick never bursts: the gust is evaluated at the tick that fell due last (the heads, tails and
-- back edges where they are then; a blink that fell due in between happens once), each pixel sent only its
-- final state, and the wipe settles every pixel it passed. A gust whose last darkening cannot be sent (a send
-- that fails) waits up to DARKEN_TICKS ticks, then rests anyway (and darkens).
--
-- Randomness: random(lo, hi), integers, inclusive. A gust draws its step (lo, hi = the step -+20 %), its tail
-- time (TAIL_MS), its double (random(1, 100) <= DOUBLE_PERCENT) and, if double, its gap (random(2, 4)). Each tick
-- the leading front reaches a new pixel p with p + 2 on the column draws the glint (random(1, 100) <=
-- GLINT_PERCENT). Then, top down, a pixel joining a tail draws its colour (random(1, #SPARKS)) and its first gap
-- (random(low, 4)); a blink off draws its gap; and, top down again, a relight draws its colour and its gap. A
-- rest draws its length (REST_MS). A random that fails or answers no number takes the middle of the range.
--
-- Choices where the contract is silent (each covered by tests/spec/breezeleds_spec.lua):
--   * Pixels are positions: a set_pixels change mid-gust keeps the gust; a new pixel is taken and sent dark at
--     once (a repaint after its bind sends it what it shows). A pixel bound during the leave is not taken.
--   * A bottom change while running darkens what is lit and rests; during the leave it settles at once.
--   * repaint(link) sends what the pixel shows: lit, paint(colour, true, false); otherwise light(false), and its
--     loaded colour counts as unknown (the keypad that asked may hold its own).
--   * update{} without `breeze` keeps the strength and direction it has (listener.phase may send `online`
--     alone); with `breeze` they are read too, nil meaning unknown (Breeze 2, up). A missing key of configure{}
--     or update{} keeps its value (night_percent: 50 at first; anything in it that is not a number is 50).
--     stop() is final: every later call is ignored (held() answers false).
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
--   b:configure({ enabled = bool, per_speed = bool, bottom = 1 | 6, step = ms, night = bool,
--                 night_percent = 10..100, dark = bool })  -- dark: the keypad shows nothing (#207), false at first
--   breezeleds.scale(colour, percent) -> colour  -- each component * percent / 100, rounded half up (BL-D28)
--   b:set_pixels(list)       -- the bound speed links, any order, duplicates ignored, only 301 to 306 kept
--   b:update({ breeze = bool, strength = 1 | 2 | 3 | nil, online = bool,
--              direction = "down" | "up" | nil })  -- the fan's airflow (BL-D30); nil counts as "up"
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
breezeleds.NIGHT_PERCENT_DEFAULT = 50 -- Breeze LED Night Brightness (%) (BL-D28)
breezeleds.NIGHT_PERCENT_MIN = 10
breezeleds.NIGHT_PERCENT_MAX = 100
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

-- A percent for scale(): rounded and held within NIGHT_PERCENT_MIN to NIGHT_PERCENT_MAX; nil when not a number.
local function percent_of(value)
	local n = number_of(value)
	if n == nil then
		return nil
	end
	n = round(n)
	if n < breezeleds.NIGHT_PERCENT_MIN then
		return breezeleds.NIGHT_PERCENT_MIN
	elseif n > breezeleds.NIGHT_PERCENT_MAX then
		return breezeleds.NIGHT_PERCENT_MAX
	end
	return n
end

-- `colour` ("rrggbb") with each component at `percent` (10 to 100) of its value, rounded half up, as lower-case
-- hex (BL-D28): the hue stays, the brightness goes down. 100, a percent that is not a number, and a colour that
-- is not 6-digit hex come back unchanged.
function breezeleds.scale(colour, percent)
	local p = percent_of(percent)
	if p == nil or p >= 100 or type(colour) ~= "string" or not colour:match("^%x%x%x%x%x%x$") then
		return colour
	end
	local out = {}
	for i = 1, 5, 2 do
		local c = tonumber(colour:sub(i, i + 1), 16)
		out[#out + 1] = string.format("%02x", math.floor((2 * c * p + 100) / 200))
	end
	return table.concat(out)
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
		night = false,
		night_percent = breezeleds.NIGHT_PERCENT_DEFAULT,
		dark = false, -- the keypad LEDs are dark (#207, AP-D6): not active, and no wipe
		-- update
		breeze = false,
		strength = nil,
		online = false,
		down = false, -- the fan blows down: the gusts run down the column (BL-D30); unknown is up
		-- set_pixels
		links = {}, -- the bound speed links, ascending
		order = {}, -- the pixels, pixel 1 (the bottom) first
		-- the animation
		phase = "idle",
		head = 0, -- the ending wipe's pixel
		rising = false, -- the ending wipe runs up the column (after downward gusts, BL-D30)
		gust = nil, -- the running gust (gust phase)
		hold = {}, -- [link] = true while the animation holds it
		shows = {}, -- [link] = { lit = true | false | nil (unknown), colour = the colour loaded, as sent (scaled at
		-- night), or nil (unknown), base = the animation's colour it was sent for (HEAD, a spark, GLINT) }
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
	return self.enabled and self.per_speed and self.online and self.breeze and #self.order > 0 and not self.dark
end

-- Breeze ended while everything else still holds: the falling wipe plays (BL-D8). Any other way out of active
-- settles at once (BL-D11); the dark is one of them (AP-D6: no ending wipe while dark).
function Leds:leaving()
	return self.enabled and self.per_speed and self.online and not self.breeze and #self.order > 0
		and not self.dark
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

-- The pixels in the order a gust runs over them (BL-D30): bottom to top, or top to bottom when it blows down.
function Leds:lane(down)
	if not down then
		return self.order
	end
	local lane, n = {}, #self.order
	for i = 1, n do
		lane[i] = self.order[n + 1 - i]
	end
	return lane
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

function Leds:send_paint(link, colour, with_state, preload, base)
	self:stamp(with_state and 2 or 1)
	local s = self:record(link)
	local ok, err = try(self.o.paint, link, colour, with_state, preload)
	if not ok then
		self:say("warn", "link %d could not be painted %s: %s", link, colour, tostring(err))
		s.colour, s.base = nil, nil
		if with_state then
			s.lit = nil
		end
		return false
	end
	s.colour, s.base = colour, base
	if with_state then
		s.lit = true
	end
	return true
end

-- The colour sent for an animation colour: scaled at night (BL-D28).
function Leds:shade(colour)
	if self.night and self.night_percent < 100 then
		return breezeleds.scale(colour, self.night_percent)
	end
	return colour
end

-- Brings a held pixel to lit in the animation colour `colour` (sent through shade), or dark (BL-D23), with the
-- fewest messages; nothing when it shows that already. A lit pixel showing `colour` keeps the brightness it was
-- lit at (BL-D28: nothing is repainted for night); a dark one is relit at the brightness of now. Unless `must`,
-- only when the budget has room for all of it and `spare` more (else dropped). true when it shows it.
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
	local sent = self:shade(colour)
	if s.lit == true then
		if s.colour == sent or (s.colour ~= nil and s.base == colour) then
			return true
		end
		local with_state = breezeleds.RECOLOUR_NEEDS_STATE == true
		if not fits(with_state and 2 or 1) then
			return self:drop()
		end
		return self:send_paint(link, sent, with_state, false, colour)
	elseif s.lit == false then
		local loaded = s.colour == sent
		if not fits(loaded and 1 or 2) then
			return self:drop()
		end
		if not loaded and not self:send_paint(link, sent, false, true, colour) then
			return false
		end
		return self:send_light(link, true)
	end
	if not fits(2) then
		return self:drop()
	end
	return self:send_paint(link, sent, true, false, colour)
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

-- Gusts (BL-D21, BL-D22, BL-D26, BL-D27) ---------------------------------------------------------------------

-- The front f's position at tick n: 0 below pixel 1, then one pixel per front step, on past the top unseen.
local function front_at(g, f, n)
	local x = n * breezeleds.TICK_MS - g.offsets[f]
	if x < 0 then
		return 0
	end
	return math.floor(x / g.fstep)
end

-- The tick at which front f reaches position i (i = 1, 2, ..., past the top too); i + 1's is when it leaves i.
local function arrival(g, f, i)
	return ceil_div(i * g.fstep + g.offsets[f], breezeleds.TICK_MS)
end

local WINDOW_TICKS = math.floor(breezeleds.WINDOW_MS / breezeleds.TICK_MS)

function Leds:spark()
	return breezeleds.SPARKS[self:draw(1, #breezeleds.SPARKS)]
end

-- A blink's gap for a pixel at place k of a tail of `length` (1 just behind the head, `length` the back edge):
-- the low end rises from TAIL_GAP_TICKS' low to its high towards the back edge, which blinks least (BL-D27).
function Leds:gap(k, length)
	local lo, hi = breezeleds.TAIL_GAP_TICKS[1], breezeleds.TAIL_GAP_TICKS[2]
	local low = math.min(hi, lo + math.floor((hi - lo + 1) * (k - 1) / length))
	return self:draw(low, hi)
end

-- The gust's always-sent messages, worst case, by tick (BL-D24, BL-D27): for every front and pixel its arrival
-- (2: a preload and a light), the recolour as it leaves the pixel (1, 2 with RECOLOUR_NEEDS_STATE) and the
-- darkening as its tail's back edge leaves the pixel (1), unless a later front has passed the pixel by then (that
-- front's tail holds it). { [tick] = count }.
function Leds:schedule(g)
	local recolour = breezeleds.RECOLOUR_NEEDS_STATE == true and 2 or 1
	local at, count, offsets = {}, #self.order, g.offsets
	local function add(tick, n)
		at[tick] = (at[tick] or 0) + n
	end
	for f = 1, #offsets do
		local overtaken = false
		for later = f + 1, #offsets do
			overtaken = overtaken or offsets[later] - offsets[f] <= g.length * g.fstep
		end
		for i = 1, count do
			add(arrival(g, f, i), 2)
			add(arrival(g, f, i + 1), recolour)
			if not overtaken then
				add(arrival(g, f, i + g.length + 1), 1)
			end
		end
	end
	return at
end

function Leds:schedule_of(g)
	if g.count ~= #self.order or g.at == nil then
		g.count, g.at = #self.order, self:schedule(g)
	end
	return g.at
end

-- What the schedule still holds after tick n within the window: the reserve (BL-D24).
function Leds:due(g, n)
	local at, sum = self:schedule_of(g), 0
	for t = n + 1, n + WINDOW_TICKS - 1 do
		sum = sum + (at[t] or 0)
	end
	return sum
end

-- The most messages any one-second window would hold if the schedule ran from tick 0 now, with what the window
-- already holds.
function Leds:peak(g)
	self:prune()
	local at, last = self:schedule_of(g), 0
	for t in pairs(at) do
		if t > last then
			last = t
		end
	end
	local most = 0
	for m = 0, last do
		local sum, cut = 0, self.vt + m * breezeleds.TICK_MS - breezeleds.WINDOW_MS
		for _, stamp in ipairs(self.window) do
			if stamp > cut then
				sum = sum + 1
			end
		end
		for t = math.max(0, m - WINDOW_TICKS + 1), m do
			sum = sum + (at[t] or 0)
		end
		if sum > most then
			most = sum
		end
	end
	return most
end

function Leds:start_gust()
	local strength = self:strength_now()
	local step = self.step
	local lo = round(step * (100 - breezeleds.JITTER_PERCENT) / 100)
	local hi = round(step * (100 + breezeleds.JITTER_PERCENT) / 100)
	local fstep = math.max(breezeleds.TICK_MS, self:draw(lo, hi))
	local range = breezeleds.TAIL_MS[strength]
	local tail_ms = self:draw(range[1], range[2])
	local offsets = { 0 }
	if self:chance(breezeleds.DOUBLE_PERCENT[strength]) then
		offsets[2] = self:draw(breezeleds.DOUBLE_GAP_STEPS[1], breezeleds.DOUBLE_GAP_STEPS[2]) * fstep
	end
	local g = {
		t0 = self.vt, -- tick 0
		n = -1, -- the tick last applied
		fstep = fstep,
		tail_ms = tail_ms,
		length = math.max(1, round(tail_ms / fstep)), -- L: the tail, in front steps (BL-D27)
		offsets = offsets,
		strength = strength,
		down = self.down, -- the gust runs down the column (BL-D30); positions count along its lane
		tails = {}, -- [f][i] = pixel i's blinking in front f's tail: { lit, colour, next }
		glints = {}, -- [i] = the tick pixel i glints
		lead = 0, -- the leading front's position at the tick last applied
		waited = 0, -- ticks spent after the gust waiting to darken
		dropped = 0,
	}
	self.gust = g
	if offsets[2] ~= nil and self:peak(g) > breezeleds.BUDGET_PER_S then
		-- A double gust only when both fronts fit the budget with what the window holds (BL-D24).
		self:say("debug", "no room in the budget for a second front: a single gust")
		offsets[2], g.at = nil, nil
	end
	for f = 1, #offsets do
		g.tails[f] = {}
	end
	self.phase = "gust"
	self:say("debug", "a gust %s: a front step of %d ms, a tail of %d step(s)%s, strength %d",
		g.down and "down" or "up", fstep, g.length,
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

-- Whether place i of a tail (along the gust's lane) may relight now (BL-D27, BL-D30): the next place towards
-- the head is past the end of the column, is that front's head, or shows lit; so a twinkle never travels
-- against the gust.
function Leds:may_relight(w, pos, lane)
	local above = lane[w.i + 1]
	if above == nil or pos[w.front] == w.i + 1 then
		return true
	end
	local s = self.shows[above]
	return s ~= nil and s.lit == true
end

-- The gust at tick n: what every pixel wants, sent within the budget (BL-D24), then the next tick or the rest.
function Leds:gust_at(n)
	local g = self.gust
	local order = self:lane(g.down) -- positions count along the gust's lane: 1 is where it enters
	local count, length = #order, g.length
	g.n = n
	local pos, over = {}, true
	for f = 1, #g.offsets do
		pos[f] = front_at(g, f, n)
		if pos[f] <= count + length then
			over = false -- a back edge still on the column (BL-D27)
		end
	end
	local lead = pos[1]
	if lead > g.lead then
		g.lead = lead
		local target = lead + 2
		if lead >= 1 and target <= count and g.glints[target] == nil and self:chance(breezeleds.GLINT_PERCENT) then
			g.glints[target] = n
		end
	end
	-- Each pixel, top down: a front's head; in the tail of the latest front that passed it (within `length`
	-- steps of its head); behind that tail (dark, for good this gust); or ahead of every front (dark, or a glint).
	-- Always sent: the heads, a pixel still showing HEAD, and the darkening behind a tail's back edge.
	local musts, aheads, tails = {}, {}, {}
	for i = count, 1, -1 do
		local link = order[i]
		local head, front = false, nil
		for f = 1, #g.offsets do
			head = head or pos[f] == i
		end
		if not head then
			for f = #g.offsets, 1, -1 do
				if pos[f] > i then
					front = f
					break
				end
			end
		end
		local s = self.shows[link]
		local white = s ~= nil and s.lit == true and s.base == HEAD
		local want = { link = link, i = i, front = front }
		if head then
			want.lit, want.colour = true, HEAD
			musts[#musts + 1] = want
		elseif front ~= nil and pos[front] - i <= length then
			local k = pos[front] - i
			local t = g.tails[front][i]
			if t == nil then
				t = { lit = true, colour = self:spark() } -- the head just left: lit in a spark at once
				t.next = n + self:gap(k, length)
				g.tails[front][i] = t
			elseif t.lit and n >= t.next then
				t.lit = false
				t.next = n + self:gap(k, length)
			end
			want.k, want.t = k, t
			if white then
				want.lit, want.colour = t.lit, t.colour
				musts[#musts + 1] = want
			else
				tails[#tails + 1] = want
			end
		elseif front ~= nil then
			want.lit = false
			musts[#musts + 1] = want
		else
			want.lit = g.glints[i] == n
			want.colour = want.lit and breezeleds.GLINT or nil
			if white then
				musts[#musts + 1] = want
			else
				aheads[#aheads + 1] = want
			end
		end
	end
	self.reserve = 0
	for _, w in ipairs(musts) do
		self:apply(w.link, w.lit, w.colour, true)
	end
	-- Dropped first when the budget is short, in this order: a pixel ahead to darken, a tail pixel going dark,
	-- a relight (top down, so the pixel above is settled first), a glint (only with room to darken it next).
	self.reserve = self:due(g, n)
	for _, w in ipairs(aheads) do
		if not w.lit then
			self:apply(w.link, false, nil, false)
		end
	end
	for _, w in ipairs(tails) do
		if not w.t.lit then
			self:apply(w.link, false, nil, false)
		end
	end
	for _, w in ipairs(tails) do
		local t, s = w.t, self:record(w.link)
		if not t.lit and n >= t.next and s.lit == false and self:may_relight(w, pos, order) then
			t.lit, t.colour = true, self:spark()
			t.next = n + self:gap(w.k, length)
		end
		if t.lit then
			if s.lit ~= true and not self:may_relight(w, pos, order) then
				t.lit = false -- the pixel above went dark first: wait for it
			else
				self:apply(w.link, true, t.colour, false)
			end
		end
	end
	for _, w in ipairs(aheads) do
		if w.lit then
			self:apply(w.link, true, w.colour, false, 1)
		end
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

-- The ending wipe's frame: the head HEAD if held, every held pixel it has passed settled, in the head's order
-- (BL-D8, BL-D25; rising after downward gusts, BL-D30).
function Leds:wipe_frame()
	local h, order = self.head, self.order
	local link = order[h]
	if link ~= nil and self.hold[link] then
		self:apply(link, true, HEAD, true)
	end
	if self.rising then
		for i = 1, math.min(h - 1, #order) do
			if self.hold[order[i]] then
				self:release(order[i])
			end
		end
	else
		for i = #order, h + 1, -1 do
			if self.hold[order[i]] then
				self:release(order[i])
			end
		end
	end
end

-- The ending wipe, the other way from the gusts (BL-D30): from the top held pixel down after rising gusts, from
-- the bottom held pixel up after downward ones; the direction is the one at its start.
function Leds:start_leave()
	self:cancel()
	self.gust = nil
	self.rising = self.down
	local first = 0
	for i, link in ipairs(self.order) do
		if self.hold[link] and (not self.rising or first == 0) then
			first = i
		end
	end
	if first == 0 then
		self:idle("Breeze ended; nothing held")
		return
	end
	self.phase, self.head = "leave", first
	self:say("debug", "Breeze ended: the %s wipe from pixel %d", self.rising and "rising" or "falling", first)
	self:wipe_frame()
	self:arm(self.step)
end

-- A step of the wipe; the steps that fell due since `due` together (BL-D13), the next on the cadence.
function Leds:wipe_tick(due)
	local step = self.step
	local k = 1 + math.floor((self.vt - due) / step)
	if k > 1 then
		self:say("debug", "a late tick: %d steps of the ending wipe together", k)
	end
	if self.rising then
		self.head = math.min(#self.order + 1, self.head + k)
	else
		self.head = math.max(0, self.head - k)
	end
	self:wipe_frame()
	if self.head < 1 or self.head > #self.order or not self:any_held() then
		self:idle("the ending wipe is done")
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
	if c.night ~= nil then
		self.night = c.night == true -- from the next colour sent (BL-D28)
	end
	if c.night_percent ~= nil then
		self.night_percent = percent_of(c.night_percent) or breezeleds.NIGHT_PERCENT_DEFAULT
	end
	local why = "configure"
	if c.dark ~= nil and (c.dark == true) ~= self.dark then
		self.dark = c.dark == true -- AP-D6, AP-D7: settled with no wipe, or dark first again
		why = self.dark and "the keypad LEDs are dark" or "the keypad LEDs are lit again"
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
		self:evaluate(why)
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
	if u.breeze ~= nil or u.direction ~= nil then
		self.down = u.direction == "down" -- from the next gust, or the next wipe (BL-D30); unknown is up
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
		return self:send_paint(link, s.colour, true, false, s.base)
	end
	s.colour, s.base = nil, nil
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
		night = self.night,
		night_percent = self.night_percent,
		rest = { rest[1], rest[2] },
		tail = { tail[1], tail[2] },
		double = breezeleds.DOUBLE_PERCENT[strength],
		strength = self.strength,
		direction = self.down and "down" or "up",
		wipe = self.phase == "leave" and (self.rising and "rising" or "falling") or nil,
		bottom = self.bottom,
		enabled = self.enabled,
		per_speed = self.per_speed,
		online = self.online,
		breeze = self.breeze,
		dark = self.dark, -- the keypad LEDs are dark (#207): paused
		active = self:active() == true,
		pending = self.armed,
		stopped = self.stopped,
		gust = g and {
			tick = g.n,
			step = g.fstep,
			tail = g.tail_ms,
			length = g.length,
			offsets = { g.offsets[1], g.offsets[2] },
			strength = g.strength,
			direction = g.down and "down" or "up",
			dropped = g.dropped,
		} or nil,
		budget = { sent = #self.window, limit = breezeleds.BUDGET_PER_S, dropped = self.dropped },
	}
end

return breezeleds
