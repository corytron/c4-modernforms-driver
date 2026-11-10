-- fan/speedleds.lua: the speed LED chase (#159, #177). The contract is docs/speed-leds-design.md: section 1 (SL-D1
-- to SL-D19), this module's interface (section 3.1) and what the owner sees (section 4); the reasons are
-- docs/edge-cases-speed-leds.md, docs/speed-leds-c4-guidelines.md and docs/speed-leds-engine-options.md.
--
-- At a fixed fan speed a single dot in that speed's colour (SL-D7) runs across the keypad buttons on the fan's
-- bound speed links (301 to 306, the pixels), one after the other, in the direction the fan blows (SL-D4), one
-- button per STEP_MS[speed] (SL-D5). Between chases a constant rest (SL-D6) in which the engine holds nothing and
-- the links light the selected speed's button exactly as they do without the feature (SL-D3).
--
-- Runs (SL-D19, #177): the chase becoming possible, and every real change of its inputs while it is (SL-D10),
-- starts a new run, whatever selected the speed. A run's first chase comes FIRST_MS after the engine saw the
-- change; every later one a rest after the previous one ended. The same inputs again change nothing, so an
-- update that repeats the view never pushes a chase back.
--
--   off       no chase can run (SL-D9): nothing held, no timer.
--   resting   nothing held; one timer, then the chase: FIRST_MS from a new run's start while `first` (SL-D19),
--             else the rest from the previous chase's end (SL-D6).
--   waiting   the chase fell due while another engine (Breeze's leave wipe) held a pixel: nothing held; one timer
--             for RETRY_MS, then the chase is tried again (SL-D14). After Breeze ends at a speed the first chase
--             comes FIRST_MS later or as soon as the wipe lets go, whichever is later.
--   chasing   every pixel held; one timer per step.
--
-- The rest is not an input of a run (SL-D19): a rest change while resting moves the next chase to a rest after
-- the previous chase's end (a run's first chase stays FIRST_MS after its start), never earlier than now; while
-- chasing or waiting it applies after the chase.
--
-- Pixel 1 is the bottom: the lowest link, or the highest with bottom = 6. The lane is the order the dot runs:
-- forward (blowing down) from the top pixel to pixel 1, reverse from pixel 1 up; an unknown direction, no chase.
--
-- A chase (SL-D12, SL-D18), N pixels along the lane, L of them lit at rest (lit(link), asked when the chase
-- starts), the colour C = colour(speed) read when it starts (none: no chase this time, another full rest):
--   frame 1      (at once) the L lit pixels darkened, light(link, false), except lane[1]; then the dot arrives on
--                lane[1].
--   frame k      (k = 2 .. N, one step apart) the dot arrives on lane[k], then lane[k - 1] is darkened.
--   frame N + 1  (one step after frame N) lane[N] darkened, then the L pixels relit, light(link, true), lane[N]
--                neither when it is lit at rest; every pixel handed back (held false) without a message: each
--                shows what the links would show.
-- The dot arriving on a pixel dark at rest is paint(link, C, false, true) (the preload: loaded, still dark), then
-- light(link, true); on a pixel lit at rest light(link, true) alone, its loaded colour being C already.
-- No double blink at the edges (SL-D18, #172): a pixel lit at rest where the dot starts (lane[1]) is neither
-- darkened nor lit in frame 1: it stays lit as the dot's first position and is darkened in frame 2 like any other.
-- One where the dot ends (lane[N]) is lit by the dot in frame N and left lit by frame N + 1, which neither darkens
-- nor relights it. That is 2N + 2L + (N - L) messages less 2 for each edge pixel lit at rest: 13 for the house's
-- four buttons with a middle one lit, 11 with an edge one; a chase lasts N steps either way.
-- Step order: the next pixel is lit before the previous one is darkened, so the dot never vanishes mid-chase.
--
-- Truthful at the end: frame N + 1 settles (settle(link): the links send their truth) instead of darkening or
-- relighting any pixel that a send failed on, whose rest state was unknown at the start, whose lit(link) now
-- differs from the start (Also Lit At changed mid-chase), or that is lit at rest while colour(speed) now differs
-- from C (Speed N LED Color edited mid-chase). In the house that costs nothing: no such pixel, no settle.
--
-- Stops (SL-D9 to SL-D11, SL-D16): a real change of the inputs (speeds, per_speed, bottom, fan_mode, speed,
-- online, direction, the pixel list), repaint(link) on a held link, or stop() settles every held pixel at once,
-- ascending (a link that just left the list too), and holds nothing; then a new run (SL-D19) while a chase can
-- still run, else off. The same inputs again send nothing and keep the timer (SL-D10).
--
-- One clock and a budget (SL-D13, the Breeze window BL-D24): one one-shot timer at a time; every re-arm, change
-- and stop cancels the pending one first, and a callback of a cancelled timer is ignored. The engine's time
-- follows `now` and never runs backwards (without a clock, a timer's time is what it was armed for). Every
-- message is stamped (a paint without the state 1, a light 1, a settle 2) and is must-send: a frame whose
-- messages would put more than BUDGET_PER_S in a WINDOW_MS is delayed whole until they fit, never dropped (a frame
-- bigger than the budget waits for an empty window). A late timer plays just the next frame; the step after it
-- is one step later: no catch-up, no burst. Stops are sent at once.
--
-- Choices where the contract is silent (each covered by tests/spec/speedleds_spec.lua):
--   * update{} is the whole view each time: a missing field reads as unknown (fan_mode, speed, direction) or
--     false (online). configure{} keeps the value of a missing key.
--   * blocked(link) that raises counts as held (one owner per pixel first), warned once until it answers again;
--     without a `blocked` option nothing is held elsewhere.
--   * stop() is final, as Breeze's: every later call is ignored and held() answers false.
--   * A timer that cannot be armed mid-chase settles every held pixel; the engine then waits for a real change
--     (or a rest change, which arms the rest from there).
--   * A repaint (SL-D16) ends the chase as a real change does, so it starts a new run too: the next chase
--     FIRST_MS later (SL-D19).
--   * A chase skipped for want of a colour counts as one that ended when it fell due: the next a rest later.
--
-- Pure like fan/links.lua: nothing here touches Director, no globals. Every option is called through pcall (try);
-- a failure is logged at warn and the engine goes on:
--
--   local s = speedleds.new({ paint = fn(link, colour, with_state, preload), light = fn(link, lit),
--       settle = fn(link), lit = fn(link) -> bool, colour = fn(speed) -> "rrggbb" | nil,
--       blocked = fn(link) -> bool, timer = fn(ms, cb) -> handle, now = fn() -> ms, log = { debug, info, warn } })
--   s:configure({ speeds = "off" | "2-5" | "1-6", per_speed = bool, bottom = 1 | 6, rest = seconds })
--   s:set_pixels(list)  -- the bound speed links, any order, duplicates ignored, only 301 to 306 kept
--   s:update({ fan_mode = bool | nil, speed = 0..6 | nil, online = bool, direction = "forward" | "reverse" | nil })
--   s:held(link) -> bool; s:repaint(link) -> bool (true: it was held, the chase ended); s:stop(); s:debug() -> table
--
-- Lua 5.1: no goto, no integer division, no bit operators.

local speedleds = {}

speedleds.STEP_MS = { [1] = 500, [2] = 400, [3] = 300, [4] = 200, [5] = 120, [6] = 100 } -- SL-D5
speedleds.STEP_FLOOR_MS = 100 -- SL-D5: no step is shorter
speedleds.REST_DEFAULT = 5 -- seconds (SL-D6, #177; 10 before 1.7)
speedleds.REST_MIN = 5
speedleds.REST_MAX = 60
speedleds.FIRST_MS = 2500 -- a new run's first chase (SL-D19, #177), fixed
speedleds.RETRY_MS = 200 -- SL-D14
speedleds.BUDGET_PER_S = 30 -- messages in any WINDOW_MS (SL-D13, BL-D24)
speedleds.WINDOW_MS = 1000
speedleds.RANGES = { ["2-5"] = { 2, 5 }, ["1-6"] = { 1, 6 } } -- Speed LED Animation (SL-D8); "off" has none
speedleds.FIRST_LINK = 301 -- the speed links, the only links that ever chase
speedleds.LAST_LINK = 306

-- What a message costs in the budget, counted as Breeze counts it.
local COST = { preload = 1, light = 1, dark = 1, settle = 2 }

local Leds = {}
Leds.__index = Leds

-- Helpers (the twins of breezeleds.lua's) --------------------------------------------------------------------

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

-- The rest in seconds: rounded and held within REST_MIN to REST_MAX; anything not a number is the default.
local function seconds_of(value)
	local n = number_of(value)
	if n == nil then
		return speedleds.REST_DEFAULT
	end
	n = round(n)
	if n < speedleds.REST_MIN then
		return speedleds.REST_MIN
	elseif n > speedleds.REST_MAX then
		return speedleds.REST_MAX
	end
	return n
end

-- A whole speed 0 to 6, else nil (unknown).
local function speed_of(value)
	local n = number_of(value)
	if n ~= nil and n == math.floor(n) and n >= 0 and n <= 6 then
		return n
	end
	return nil
end

-- The step of a speed (SL-D5): the table's, never under the floor.
local function step_ms(speed)
	local n = number_of(speedleds.STEP_MS[speed]) or speedleds.STEP_FLOOR_MS
	return math.max(speedleds.STEP_FLOOR_MS, round(n))
end

-- The speed links of a list, ascending, each once.
local function links_of(list)
	local seen, out = {}, {}
	if type(list) ~= "table" then
		return out
	end
	for _, value in pairs(list) do
		local n = number_of(value)
		if n ~= nil and n == math.floor(n) and n >= speedleds.FIRST_LINK and n <= speedleds.LAST_LINK
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

local function copy(list)
	local out = {}
	for i, v in ipairs(list) do
		out[i] = v
	end
	return out
end

-- Frames 1 to N of a chase (SL-D12): { { kind, link }, ... } each; kind is preload, light or dark. A pixel lit at
-- rest where the dot starts is left lit as its first position (SL-D18): no darkening and no light in frame 1, so
-- frame 1 can be empty.
local function frames_of(lane, rest)
	local frames = {}
	local function arrive(frame, link)
		if rest[link] ~= true then
			frame[#frame + 1] = { "preload", link }
		end
		frame[#frame + 1] = { "light", link }
	end
	local first = {}
	for k, link in ipairs(lane) do
		if rest[link] == true and k > 1 then
			first[#first + 1] = { "dark", link }
		end
	end
	if rest[lane[1]] ~= true then
		arrive(first, lane[1])
	end
	frames[1] = first
	for k = 2, #lane do
		local frame = {}
		arrive(frame, lane[k])
		frame[#frame + 1] = { "dark", lane[k - 1] } -- after the arrival: the dot never vanishes
		frames[k] = frame
	end
	return frames
end

-- The instance -----------------------------------------------------------------------------------------------

function speedleds.new(opts)
	opts = type(opts) == "table" and opts or {}
	return setmetatable({
		o = opts,
		log = opts.log or require("common.log"),
		-- configure
		speeds = "off",
		per_speed = false,
		bottom = 1,
		rest = speedleds.REST_DEFAULT,
		-- update
		fan_mode = nil,
		speed = nil,
		online = false,
		direction = nil,
		-- set_pixels
		links = {}, -- the bound speed links, ascending
		order = {}, -- the pixels, pixel 1 (the bottom) first
		-- the chase
		state = "off",
		hold = {}, -- [link] = true while a chase holds it
		chase = nil, -- the running chase: lane, n, speed, colour, step, rest, dirty, frames, frame
		blocked_failed = false,
		-- the run (SL-D19)
		first = false, -- true from a new run's start until its first chase starts
		run_vt = 0, -- the engine's time when the run started
		end_vt = nil, -- and when its last chase ended (nil: none yet)
		-- time and the budget
		vt = 0, -- the engine's time, ms
		cref = nil, -- the clock when vt was last brought up to it
		window = {}, -- the engine times of the messages of the last WINDOW_MS, oldest first
		delayed = 0, -- frames delayed for the budget, all told
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
	pcall(fn, "%s", "Speed LEDs: " .. (ok and text or tostring(template)))
end

function Leds:enabled_for(speed)
	local range = speedleds.RANGES[self.speeds]
	return range ~= nil and speed ~= nil and speed >= range[1] and speed <= range[2]
end

-- Why no chase can run now (SL-D4, SL-D8, SL-D9), or nil when one can.
function Leds:why_not()
	if speedleds.RANGES[self.speeds] == nil then
		return "Speed LED Animation is Off"
	elseif not self.per_speed then
		return "Speed LED Colors is not Per speed"
	elseif self.fan_mode ~= true then
		return "not in fan mode"
	elseif not self.online then
		return "not online"
	elseif not self:enabled_for(self.speed) then
		return string.format("no chase at speed %s", tostring(self.speed))
	elseif self.direction == nil then
		return "the direction is unknown"
	elseif #self.order < 2 then
		return "fewer than two speed buttons bound"
	end
	return nil
end

function Leds:active()
	return self:why_not() == nil
end

-- Everything a real change is made of (SL-D10), as one string. The rest is not one: a rest change reschedules
-- the run it is in instead of starting a new one (SL-D19).
function Leds:inputs()
	return table.concat({
		self.speeds, tostring(self.per_speed), tostring(self.bottom),
		tostring(self.fan_mode), tostring(self.speed), tostring(self.online), tostring(self.direction),
		table.concat(self.links, ","),
	}, "|")
end

function Leds:reorder()
	local order, n = {}, #self.links
	for i = 1, n do
		order[i] = self.bottom == 6 and self.links[n + 1 - i] or self.links[i]
	end
	self.order = order
end

-- The pixels in the order the dot runs over them (SL-D4): from the top down when the fan blows down (forward),
-- from pixel 1 up in reverse.
function Leds:lane()
	if self.direction ~= "forward" then
		return copy(self.order)
	end
	local lane, n = {}, #self.order
	for i = 1, n do
		lane[i] = self.order[n + 1 - i]
	end
	return lane
end

-- Questions to the driver -------------------------------------------------------------------------------------

-- Whether the links light `link` at rest now (SL-D12): true, false, or nil when lit fails or answers neither.
function Leds:lit_at_rest(link)
	local ok, answer = try(self.o.lit, link)
	if not ok then
		self:say("warn", "whether link %d is lit at rest could not be read: %s", link, tostring(answer))
		return nil
	end
	if answer == true or answer == false then
		return answer
	end
	return nil
end

-- The selected speed's colour (SL-D7) as 6-digit hex, or nil (none set, or the read failed).
function Leds:colour_of(speed)
	local ok, colour = try(self.o.colour, speed)
	if not ok then
		self:say("warn", "the colour of speed %s could not be read: %s", tostring(speed), tostring(colour))
		return nil
	end
	if type(colour) ~= "string" or not colour:match("^%x%x%x%x%x%x$") then
		return nil
	end
	return colour
end

-- The first pixel of `lane` another engine holds (SL-D2, SL-D14), or nil. A blocked that raises counts as
-- held: one owner per pixel comes first. Its warning is logged once until a whole pass answers again.
function Leds:blocker(lane)
	if self.o.blocked == nil then
		return nil
	end
	for _, link in ipairs(lane) do
		local ok, answer = try(self.o.blocked, link)
		if not ok then
			if not self.blocked_failed then
				self.blocked_failed = true
				self:say("warn", "whether another engine holds link %d could not be read (%s); waiting", link,
					tostring(answer))
			end
			return link
		elseif answer == true then
			return link
		end
	end
	self.blocked_failed = false
	return nil
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

-- One one-shot timer; true when it is armed.
function Leds:arm(ms)
	self:cancel()
	ms = math.max(1, round(ms))
	local gen = self.gen
	local ok, handle = try(self.o.timer, ms, function() self:fire(gen) end)
	if not ok then
		self:say("warn", "the timer could not be armed (%s ms): %s", tostring(ms), tostring(handle))
		return false
	end
	self.handle, self.armed = handle, true
	self.arm_vt, self.arm_ms = self.vt, ms
	return true
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
	if self.state == "resting" or self.state == "waiting" then
		self:start_chase()
	elseif self.state == "chasing" then
		self:play()
	end
end

-- The budget (SL-D13, BL-D24) ---------------------------------------------------------------------------------

function Leds:prune()
	local cut, window = self.vt - speedleds.WINDOW_MS, self.window
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
	return #self.window + count <= speedleds.BUDGET_PER_S
end

-- How long until the window has room for `count` more; a frame bigger than the whole budget waits for an empty
-- window and is then sent whole (delayed, never dropped).
function Leds:wait_for(count)
	self:prune()
	local window = self.window
	local e = math.min(#window, #window + count - speedleds.BUDGET_PER_S)
	if e < 1 then
		return 0
	end
	return window[e] + speedleds.WINDOW_MS - self.vt
end

-- Sends ------------------------------------------------------------------------------------------------------

function Leds:send_light(link, lit)
	self:stamp(1)
	local ok, err = try(self.o.light, link, lit)
	if not ok then
		self:say("warn", "link %d could not be %s: %s", link, lit and "lit" or "darkened", tostring(err))
	end
	return ok
end

function Leds:send_paint(link, colour, with_state, preload)
	self:stamp(with_state and 2 or 1)
	local ok, err = try(self.o.paint, link, colour, with_state, preload)
	if not ok then
		self:say("warn", "link %d could not be painted %s: %s", link, tostring(colour), tostring(err))
	end
	return ok
end

function Leds:take(link)
	self.hold[link] = true
end

-- Hands the link back: no longer held when the links hear settle(link), so they send its real state.
function Leds:release(link)
	self.hold[link] = nil
	self:stamp(2)
	local ok, err = try(self.o.settle, link)
	if not ok then
		self:say("warn", "link %d could not be settled: %s", link, tostring(err))
	end
	return ok
end

-- One planned message; true when its callback did not fail.
function Leds:send(msg, colour)
	local kind, link = msg[1], msg[2]
	if kind == "preload" then
		return self:send_paint(link, colour, false, true)
	elseif kind == "settle" then
		return self:release(link)
	end
	return self:send_light(link, kind == "light")
end

-- Phases -----------------------------------------------------------------------------------------------------

-- Every held pixel back to the links at once, ascending (SL-D11); nothing held after.
function Leds:settle_all(why)
	local links = {}
	for link in pairs(self.hold) do
		links[#links + 1] = link
	end
	table.sort(links)
	for _, link in ipairs(links) do
		self:release(link)
	end
	self.hold, self.chase = {}, nil
	if #links > 0 then
		self:say("debug", "%s: the chase ends, %d pixel(s) settled", why, #links)
	end
end

-- The rest after a chase that ended now (SL-D6): the next one a rest from here (SL-D19).
function Leds:start_rest(why)
	self.state, self.chase, self.first = "resting", nil, false
	self.end_vt = self.vt
	self:say("debug", "%s; the next chase in %d s", why, self.rest)
	self:arm(self.rest * 1000)
end

-- A new run (SL-D19): its first chase FIRST_MS after the engine saw the change, whatever its source.
function Leds:start_run(why)
	self.state, self.chase, self.first = "resting", nil, true
	self.run_vt, self.end_vt = self.vt, nil
	self:say("debug", "%s: a new run, the first chase in %d ms", why, speedleds.FIRST_MS)
	self:arm(speedleds.FIRST_MS)
end

-- After a real change, a repaint or a chase that cannot go on: every held pixel settled, then a new run while a
-- chase can still run (SL-D11, SL-D19), else off (SL-D9).
function Leds:evaluate(why)
	self:cancel()
	self:settle_all(why)
	local reason = self:why_not()
	if reason == nil then
		self:start_run(why)
		return
	end
	if self.state ~= "off" then
		self:say("debug", "off (%s)", reason)
	end
	self.state, self.first, self.end_vt = "off", false, nil
end

-- A rest change (SL-D19): while resting the next chase comes a rest after the previous chase's end, or FIRST_MS
-- after the run's start when none has started yet, never earlier than now; a timer already armed for that time
-- is kept. While chasing or waiting the chase falls due anyway: the new rest applies after it. Off: nothing.
function Leds:rest_changed()
	if self.state ~= "resting" then
		return
	end
	local due
	if self.first then
		due = self.run_vt + speedleds.FIRST_MS
	elseif self.end_vt ~= nil then
		due = self.end_vt + self.rest * 1000
	else
		return
	end
	if self.armed and self.arm_vt + self.arm_ms == due then
		return
	end
	local wait = math.max(0, due - self:advance_time())
	self:say("debug", "the rest is now %d s; the next chase in %d ms", self.rest, wait)
	self:arm(wait)
end

-- The chase that fell due (SL-D12): wait for another engine's pixels (SL-D14), read the colour (SL-D7) and what
-- is lit at rest, take every pixel and play frame 1 at once.
function Leds:start_chase()
	local reason = self:why_not()
	if reason ~= nil then
		self:evaluate(reason)
		return
	end
	local lane = self:lane()
	local blocker = self:blocker(lane)
	if blocker ~= nil then
		self.state = "waiting"
		self:say("debug", "link %d is held by another engine; the chase tries again in %d ms", blocker,
			speedleds.RETRY_MS)
		self:arm(speedleds.RETRY_MS)
		return
	end
	local speed = self.speed
	local colour = self:colour_of(speed)
	if colour == nil then
		self:start_rest(string.format("speed %d has no LED colour: no chase this time", speed))
		return
	end
	local rest, dirty, lit = {}, {}, 0
	for _, link in ipairs(lane) do
		local answer = self:lit_at_rest(link)
		rest[link] = answer
		if answer == nil then
			dirty[link] = true -- unknown at rest: chased as dark, settled at the end
		elseif answer then
			lit = lit + 1
		end
	end
	self.chase = {
		lane = lane,
		n = #lane,
		speed = speed,
		colour = colour,
		step = step_ms(speed),
		rest = rest, -- [link] = lit at rest: true, false or nil (unknown)
		lit = lit,
		dirty = dirty, -- [link] = true: settled, not relit or darkened, at the end
		frames = frames_of(lane, rest),
		frame = 1, -- the frame played next; n + 1 is the last
	}
	self.state, self.first = "chasing", false
	for _, link in ipairs(lane) do
		self:take(link)
	end
	self:say("debug", "a chase at speed %d in %s: %d button(s), %d lit at rest, %d ms a step", speed, colour,
		#lane, lit, self.chase.step)
	self:play()
end

-- Frame N + 1 (SL-D12): lane[N] darkened, the pixels lit at rest relit; a pixel that is not known to be right
-- is settled instead (lit now differs, the colour changed, a send failed). lane[N] lit at rest keeps the dot
-- (SL-D18): already lit in C, it is handed back without a message.
function Leds:last_frame()
	local c = self.chase
	local colour = self:colour_of(c.speed)
	for _, link in ipairs(c.lane) do
		local now = self:lit_at_rest(link)
		if now ~= c.rest[link] or (now == true and colour ~= c.colour) then
			c.dirty[link] = true
		end
	end
	local last, frame = c.lane[c.n], {}
	if not c.dirty[last] and c.rest[last] ~= true then
		frame[1] = { "dark", last }
	end
	for _, link in ipairs(c.lane) do
		if c.dirty[link] then
			frame[#frame + 1] = { "settle", link }
		elseif c.rest[link] and link ~= last then
			frame[#frame + 1] = { "light", link }
		end
	end
	return frame
end

-- A chase that cannot be timed any more: every pixel back to the links; a real change starts it again.
function Leds:abandon()
	self:say("warn", "the chase stopped: no timer")
	self:settle_all("no timer")
	self.state, self.end_vt = "resting", self.vt -- a rest change arms the rest from here (rest_changed)
end

-- The chase's next frame, within the budget (SL-D13): delayed whole while the window is full, never dropped.
function Leds:play()
	local c = self.chase
	local last = c.frame > c.n
	local frame = last and self:last_frame() or c.frames[c.frame]
	local count = 0
	for _, msg in ipairs(frame) do
		count = count + COST[msg[1]]
	end
	if not self:room(count) and #self.window > 0 then
		local wait = self:wait_for(count)
		self.delayed = self.delayed + 1
		self:say("debug", "the budget is full: frame %d of the chase waits %d ms", c.frame, wait)
		if not self:arm(wait) then
			self:abandon()
		end
		return
	end
	for _, msg in ipairs(frame) do
		local link = msg[2]
		if not last or self.hold[link] then -- in the last frame a pixel settled after a failure is left alone
			if not self:send(msg, c.colour) then
				c.dirty[link] = true
				if last and msg[1] ~= "settle" then
					self:release(link) -- the last frame's send failed: the links send the truth instead
				end
			end
		end
	end
	if last then
		self.hold = {} -- handed back without a message (SL-D3): each pixel shows what the links would show
		self:start_rest("the chase is over")
		return
	end
	c.frame = c.frame + 1
	if not self:arm(c.step) then
		self:abandon()
	end
end

-- A real change of the inputs (SL-D10): settle, then a new run (SL-D19) or off; the same inputs send nothing.
-- True when it was one.
function Leds:changed(before, why)
	if self:inputs() == before then
		return false
	end
	self:advance_time()
	self:evaluate(why)
	return true
end

-- The interface ----------------------------------------------------------------------------------------------

function Leds:configure(c)
	if self.stopped then
		return
	end
	c = type(c) == "table" and c or {}
	local before = self:inputs()
	if c.speeds ~= nil then
		if c.speeds == "off" or speedleds.RANGES[c.speeds] ~= nil then
			self.speeds = c.speeds
		else
			self:say("warn", "Speed LED Animation %s is not off, 2-5 or 1-6: off", tostring(c.speeds))
			self.speeds = "off"
		end
	end
	if c.per_speed ~= nil then
		self.per_speed = c.per_speed == true
	end
	if c.bottom ~= nil then
		local bottom = number_of(c.bottom) == 6 and 6 or 1
		if bottom ~= self.bottom then
			self.bottom = bottom
			self:reorder()
		end
	end
	local rest = self.rest
	if c.rest ~= nil then
		self.rest = seconds_of(c.rest)
	end
	if not self:changed(before, "configure") and self.rest ~= rest then
		self:rest_changed() -- SL-D19: not a new run
	end
end

function Leds:set_pixels(list)
	if self.stopped then
		return
	end
	local links = links_of(list)
	if same_list(links, self.links) then
		return
	end
	local before = self:inputs()
	self.links = links
	self:reorder()
	self:changed(before, "the speed buttons changed")
end

-- The whole view each time: a missing field is unknown (fan_mode, speed, direction) or false (online).
function Leds:update(u)
	if self.stopped then
		return
	end
	u = type(u) == "table" and u or {}
	local before = self:inputs()
	if type(u.fan_mode) == "boolean" then
		self.fan_mode = u.fan_mode
	else
		self.fan_mode = nil
	end
	self.speed = speed_of(u.speed)
	self.online = u.online == true
	if u.direction == "forward" or u.direction == "reverse" then
		self.direction = u.direction
	else
		self.direction = nil
	end
	self:changed(before, self.online and "update" or "not online")
end

function Leds:held(link)
	return self.hold[number_of(link) or link] == true
end

-- A bind or REQUEST_BUTTON_COLORS on a held pixel (SL-D16): the chase ends as SL-D11 says; the settles answer.
function Leds:repaint(link)
	if self.stopped then
		return false
	end
	link = number_of(link) or link
	if not self.hold[link] then
		return false
	end
	self:advance_time()
	self:evaluate(string.format("link %d asked for its colours", link))
	return true
end

-- OnDriverDestroyed (SL-D16): every held pixel settled, the timer cancelled; final.
function Leds:stop()
	if self.stopped then
		return
	end
	self:advance_time()
	self:cancel()
	self:settle_all("stopped")
	self.stopped = true
	self.state, self.first = "off", false
end

function Leds:debug()
	local held, lit = {}, nil
	for link in pairs(self.hold) do
		held[#held + 1] = link
	end
	table.sort(held)
	local c = self.chase
	if c ~= nil then
		lit = {}
		for _, link in ipairs(c.lane) do
			if c.rest[link] then
				lit[#lit + 1] = link
			end
		end
	end
	local step = nil
	if c ~= nil then
		step = c.step
	elseif self:enabled_for(self.speed) then
		step = step_ms(self.speed)
	end
	self:prune()
	return {
		state = self.state,
		first = self.first, -- a new run's first chase not started yet: due FIRST_MS after the run's start (SL-D19)
		speed = self.speed,
		step = step,
		frame = c and c.frame or nil,
		frames = c and c.n + 1 or nil,
		rest = self.rest,
		held = held,
		pixels = copy(self.order),
		lane = self.direction and self:lane() or nil,
		colour = c and c.colour or nil,
		lit = lit,
		speeds = self.speeds,
		per_speed = self.per_speed,
		bottom = self.bottom,
		fan_mode = self.fan_mode,
		online = self.online,
		direction = self.direction,
		active = self:active(),
		why = self:why_not(),
		pending = self.armed,
		stopped = self.stopped,
		budget = { sent = #self.window, limit = speedleds.BUDGET_PER_S, delayed = self.delayed },
	}
end

return speedleds
