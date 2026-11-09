-- fan/breezeleds.lua: Breeze on the keypad LEDs (#137). The contract is docs/breeze-leds-design.md: decisions
-- BL-D1 to BL-D18 (section 1), this module's interface (section 3.1) and what the owner sees (section 4); the
-- reasons are docs/edge-cases-breeze-leds.md (BL1 to BL70) and docs/breeze-leds-sdk-research.md section 6.
--
-- While the fan blows Breeze, the keypad buttons on the fan's bound speed links (301 to 306, the pixels; BL-D2)
-- play an animation in three full-value colours (BL-D5): the head HEAD (white), the trail TRAIL (teal) and the
-- base BASE (azure). Pixel 1 is the bottom: the lowest link, or the highest with bottom = 6 (BL-D4).
--
--   idle   nothing held, nothing sent.
--   enter  the rising wipe (BL-D6): every pixel is taken at once (held, so the links send it nothing); the head
--          starts on pixel 1 and climbs one pixel per step, each pixel it leaves turning BASE. A pixel above the
--          head is held but not painted yet: it keeps what the keypad shows. When the top pixel turns BASE: rest.
--   rest   nothing sent for a random time in REST_MS[strength] (BL-D7; a strength that is nil or not 1 to 3
--          rests as 2), then a gust. A strength change applies from the next rest.
--   gust   the head climbs from pixel 1 to above the top with the trail one pixel behind it; each pixel the trail
--          leaves turns BASE again. N pixels: N + 2 steps, the rest's own expiry being the first. Then a rest.
--   leave  the falling wipe (BL-D8), once, when Breeze ends while online and everything else still holds: the
--          head starts on the top held pixel and descends one pixel per step; each pixel it leaves is settled
--          (settle(link): the links take it back and send its real state). Pixel 1 settled: idle.
--
-- Active means enabled, per_speed, online, breeze and at least one pixel. Any other way out of active settles
-- every held pixel at once, with no wipe (BL-D11). Interruptions (BL-D10): leave during enter or gust starts the
-- falling wipe from the top at once (pixels it has not reached keep their frame); Breeze again during leave
-- starts the rising wipe from pixel 1, and pixels the leave already settled stay with the links (not held) until
-- the rising head reaches them and takes them back. A bottom change while active restarts the cycle with a rest
-- (every pixel BASE, no wipe); during leave it settles at once. A step change applies from the next timer arm.
--
-- Choices where the contract is silent (each covered by tests/spec/breezeleds_spec.lua):
--   * A held pixel the enter's head has not reached yet has no frame colour of its own. When one must be painted
--     anyway (repaint, i.e. a keypad's REQUEST_BUTTON_COLORS or a new binding, or a pixel bound mid-enter), it
--     gets BASE, the colour the rising head leaves behind; the head then passes over it as over any other.
--   * Pixels are positions: a set_pixels change while running keeps the phase and the head's position, and every
--     pixel whose frame colour moved is repainted. A pixel bound during leave is not taken (Breeze has ended).
--   * update{} without `breeze` keeps the strength it has (listener.phase may send `online` alone); with `breeze`
--     the strength is read too, nil meaning unknown. A missing key of configure{} or update{} keeps its value.
--   * stop() is final: every later call is ignored (held() answers false), so a destroyed driver never animates.
--
-- Pacing (BL-D13): one one-shot timer at a time, re-armed each step; every phase change, stop and re-arm cancel
-- the pending one first, and a callback from a cancelled timer is ignored. A pixel is painted only when its
-- colour changes. A late tick never bursts: the steps that fell due since the timer's own due time (now() at
-- arming plus its ms; without `now`, one step per tick) are applied together, each pixel gets only its final
-- colour of those steps, every pixel a leave wipe passed is settled, and the next step keeps the cadence.
-- Messages (BL-D14): a pixel's first paint after it is taken passes with_state = true, later paints pass
-- RECOLOUR_NEEDS_STATE (read at each paint); repaint always passes true.
--
-- Pure like fan/links.lua and fan/breeze.lua: nothing here touches Director (no C4, no os.time). Everything
-- arrives as an option, every option is called through pcall, a failure is logged, never raised, and the
-- animation goes on as best it can (a pixel whose paint failed is painted again at its next frame):
--
--   local b = breezeleds.new({
--       paint = fn(link, colour, with_state),  -- links:paint
--       settle = fn(link),                     -- links:settle
--       timer = fn(ms, cb) -> handle,          -- handle:Cancel(); the driver's one-shot timer
--       random = fn(lo, hi) -> integer,        -- inclusive, ms; math.random in the driver
--       now = fn() -> ms,                      -- a clock (only differences are used); optional
--       log = log,                             -- default common.log
--   })
--   b:configure({ enabled = bool, per_speed = bool, bottom = 1 | 6, step = ms })
--   b:set_pixels(list)       -- the bound speed links, any order, duplicates ignored, only 301 to 306 kept
--   b:update({ breeze = bool, strength = 1 | 2 | 3 | nil, online = bool })
--   b:held(link) -> bool     -- the links ask before sending a speed link anything (BL-D15)
--   b:repaint(link) -> bool  -- a held pixel's REQUEST_BUTTON_COLORS or new binding: its frame colour, with state
--   b:stop()                 -- OnDriverDestroyed: cancel the timer, forget every hold, send nothing
--   b:debug() -> table       -- phase, head, pixels, held, frame, step, rest range and the inputs
--
-- Lua 5.1: no goto, no integer division, no bit operators.

local breezeleds = {}

breezeleds.HEAD = "ffffff"
breezeleds.TRAIL = "00ffff"
breezeleds.BASE = "0080ff"
breezeleds.REST_MS = { [1] = { 6000, 9000 }, [2] = { 3500, 6000 }, [3] = { 1500, 3500 } }
breezeleds.DEFAULT_STRENGTH = 2 -- the rest of a strength that is nil or unknown (BL-D7)
breezeleds.STEP_MIN = 200
breezeleds.STEP_MAX = 600
breezeleds.STEP_DEFAULT = 300
breezeleds.RECOLOUR_NEEDS_STATE = true -- BL-D14: until hardware check HB2 shows BUTTON_COLORS alone repaints
breezeleds.FIRST_LINK = 301 -- the speed links, the only links that ever animate (BL-D2)
breezeleds.LAST_LINK = 306

local HEAD, TRAIL, BASE = breezeleds.HEAD, breezeleds.TRAIL, breezeleds.BASE

-- The phases in which the animation holds its pixels and runs its cycle.
local RUNNING = { enter = true, rest = true, gust = true }

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

-- The step time: rounded and held within STEP_MIN to STEP_MAX; anything not a number is the default.
local function step_of(value)
	local n = number_of(value)
	if n == nil then
		return breezeleds.STEP_DEFAULT
	end
	n = math.floor(n + 0.5)
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
		head = 0, -- the head's pixel (enter, gust, leave); in a gust the trail is head - 1
		hold = {}, -- [link] = true while the animation holds it
		sent = {}, -- [link] = the colour last painted since it was taken; nil: not painted yet
		handle = nil, -- the pending timer's handle
		armed = false, -- a timer is pending
		gen = 0, -- bumped by every cancel: a callback of an older arm is ignored
		due = nil, -- when the pending timer falls due, on the now() clock
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

function Leds:index_of(link)
	for i, pixel in ipairs(self.order) do
		if pixel == link then
			return i
		end
	end
	return nil
end

function Leds:rest_range()
	return breezeleds.REST_MS[self.strength or breezeleds.DEFAULT_STRENGTH]
		or breezeleds.REST_MS[breezeleds.DEFAULT_STRENGTH]
end

-- The timer --------------------------------------------------------------------------------------------------

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

function Leds:cancel()
	self.gen = self.gen + 1
	self.due = nil
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
	local gen = self.gen
	local t = self:clock()
	local ok, handle = try(self.o.timer, ms, function() self:tick(gen) end)
	if not ok then
		self:say("error", "the timer could not be armed (%s ms): %s", tostring(ms), tostring(handle))
		return
	end
	self.handle = handle
	self.armed = true
	self.due = t ~= nil and t + ms or nil
end

-- A rest: random(lo, hi) within the strength's range; a failing or unusable random rests the middle of it.
function Leds:arm_rest()
	local range = self:rest_range()
	local lo, hi = range[1], range[2]
	local ok, ms = try(self.o.random, lo, hi)
	ms = ok and number_of(ms) or nil
	if ms == nil then
		self:say("warn", "no random rest (%s); resting %d ms", ok and "not a number" or tostring(ms),
			math.floor((lo + hi) / 2))
		ms = math.floor((lo + hi) / 2)
	elseif ms < lo then
		ms = lo
	elseif ms > hi then
		ms = hi
	end
	self:arm(ms)
end

-- Sends ------------------------------------------------------------------------------------------------------

function Leds:paint(link, colour, with_state)
	local ok, err = try(self.o.paint, link, colour, with_state)
	if not ok then
		self:say("warn", "link %d could not be painted %s: %s", link, colour, tostring(err))
		return false
	end
	self.sent[link] = colour
	return true
end

-- A held pixel to `colour`, only when it changes (BL-D13), with the state on its first paint (BL-D14).
function Leds:show(link, colour)
	local last = self.sent[link]
	if last == colour then
		return
	end
	self:paint(link, colour, last == nil or breezeleds.RECOLOUR_NEEDS_STATE == true)
end

function Leds:take(link)
	self.hold[link] = true
	self.sent[link] = nil
end

-- Hands the link back: no longer held when the links hear settle(link), so they send its real state.
function Leds:release(link)
	self.hold[link] = nil
	self.sent[link] = nil
	local ok, err = try(self.o.settle, link)
	if not ok then
		self:say("warn", "link %d could not be settled: %s", link, tostring(err))
	end
end

-- Frames -----------------------------------------------------------------------------------------------------

-- What the frame wants of pixel i (1 = the bottom): a colour and how.
--   "take"     hold it (if not yet) and show the colour
--   "own"      show the colour only if held (the falling head never takes a pixel back)
--   "keep"     leave it: a held pixel keeps its last frame, or what the keypad shows when never painted
--   "release"  settle it if held
function Leds:target(i)
	local phase, h = self.phase, self.head
	if phase == "enter" then
		if i < h then
			return BASE, "take"
		elseif i == h then
			return HEAD, "take"
		end
		return nil, "keep"
	elseif phase == "rest" then
		return BASE, "take"
	elseif phase == "gust" then
		if i == h then
			return HEAD, "take"
		elseif i == h - 1 then
			return TRAIL, "take"
		end
		return BASE, "take"
	elseif phase == "leave" then
		if i > h then
			return nil, "release"
		elseif i == h then
			return HEAD, "own"
		end
		return nil, "keep"
	end
	return nil, "release"
end

-- The colour a held pixel shows when it must be painted now (repaint, a pixel bound mid-run): its frame's, or for
-- a pixel the frame keeps, its last colour, else BASE (not reached by the rising head yet). nil: not in the frame.
function Leds:colour_at(i, link)
	local colour, how = self:target(i)
	if how == "keep" then
		return self.sent[link] or BASE
	end
	return colour
end

-- Brings every pixel to the frame of the current phase and head, sending only what changed.
function Leds:render()
	local order = self.order
	for i, link in ipairs(order) do
		local colour, how = self:target(i)
		if how == "release" then
			if self.hold[link] then
				self:release(link)
			end
		elseif how == "take" then
			if not self.hold[link] then
				self:take(link)
			end
			self:show(link, colour)
		elseif how == "own" then
			if self.hold[link] then
				self:show(link, colour)
			end
		end
	end
end

-- Phases -----------------------------------------------------------------------------------------------------

function Leds:idle(why)
	self:cancel()
	self.phase, self.head = "idle", 0
	self.hold, self.sent = {}, {}
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

-- The rising wipe (BL-D6). From idle every pixel is taken at once; from a leave (BL-D10) the pixels it settled
-- stay with the links until the head reaches them.
function Leds:start_enter(take_all)
	self:cancel()
	if take_all then
		self.hold, self.sent = {}, {}
		for _, link in ipairs(self.order) do
			self:take(link)
		end
	end
	self.phase, self.head = "enter", 1
	self:say("debug", "Breeze: the rising wipe over %d pixel(s)%s", #self.order, take_all and "" or ", from the leave")
	self:render()
	self:arm(self.step)
end

-- The falling wipe (BL-D8), from the top held pixel.
function Leds:start_leave()
	self:cancel()
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
	self:render()
	self:arm(self.step)
end

-- The cycle again from a rest, no wipe (a bottom change while running).
function Leds:start_rest()
	self:cancel()
	self.phase, self.head = "rest", 0
	self:render()
	self:arm_rest()
end

-- Applies BL-D6 to BL-D11 to the inputs as they are now.
function Leds:evaluate(why)
	if self:active() then
		if self.phase == "idle" then
			self:start_enter(true)
		elseif self.phase == "leave" then
			self:start_enter(false)
		end
	elseif self.phase ~= "idle" then
		if not self:leaving() then
			self:settle_all(why)
		elseif RUNNING[self.phase] then
			self:start_leave()
		end
	end
end

-- One step of the current phase; false once it ends in a rest or idle (a batch of late steps stops there).
function Leds:advance()
	local phase, n = self.phase, #self.order
	if phase == "enter" then
		self.head = self.head + 1
		if self.head > n then
			self.phase, self.head = "rest", 0
			return false
		end
	elseif phase == "rest" then
		self.phase, self.head = "gust", 1
	elseif phase == "gust" then
		self.head = self.head + 1
		if self.head >= n + 2 then
			self.phase, self.head = "rest", 0
			return false
		end
	elseif phase == "leave" then
		self.head = self.head - 1
		if self.head < 1 then
			self.phase, self.head = "idle", 0
			return false
		end
	else
		return false
	end
	return true
end

-- A timer callback: the steps that fell due, applied together (BL-D13), then the next arm.
function Leds:tick(gen)
	if self.stopped or gen ~= self.gen then
		return
	end
	self.handle, self.armed = nil, false
	local due, step = self.due, self.step
	self.due = nil
	local t = due ~= nil and self:clock() or nil
	local k = 1
	if t ~= nil and t > due then
		k = 1 + math.floor((t - due) / step)
	end
	local done = 0
	while done < k do
		done = done + 1
		if not self:advance() then
			break
		end
	end
	if done > 1 then
		self:say("debug", "a late tick: %d steps applied together", done)
	end
	self:render()
	if self.phase == "idle" then
		self:idle("the falling wipe is done")
	elseif self.phase == "rest" then
		self:arm_rest()
	elseif self.phase == "leave" and not self:any_held() then
		self:idle("the falling wipe is done")
	elseif t ~= nil and t >= due then
		self:arm(due + k * step - t) -- the next step keeps the cadence
	else
		self:arm(step)
	end
end

-- The interface ----------------------------------------------------------------------------------------------

function Leds:configure(c)
	if self.stopped then
		return
	end
	c = type(c) == "table" and c or {}
	if c.enabled ~= nil then
		self.enabled = c.enabled == true
	end
	if c.per_speed ~= nil then
		self.per_speed = c.per_speed == true
	end
	if c.step ~= nil then
		self.step = step_of(c.step) -- from the next arm
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
		self:say("debug", "the bottom is now speed %d: the cycle restarts with a rest", self.bottom)
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
	u = type(u) == "table" and u or {}
	if u.breeze ~= nil then
		self.breeze = u.breeze == true
	end
	if u.online ~= nil then
		self.online = u.online == true
	end
	if u.breeze ~= nil or u.strength ~= nil then
		self.strength = strength_of(u.strength) -- from the next rest
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
			self.hold[link], self.sent[link] = nil, nil
		end
	end
	self.links = links
	self:reorder()
	if RUNNING[self.phase] and self:active() then
		-- A link that gained a button joins at once, painted its frame colour with the state (BL-D16).
		for i, link in ipairs(self.order) do
			if not before[link] then
				self:take(link)
				self:show(link, self:colour_at(i, link))
			end
		end
		self:render()
	elseif self.phase == "leave" and self:leaving() then
		if self.head > #self.order then
			self.head = #self.order
		end
		self:render()
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

-- A held pixel's REQUEST_BUTTON_COLORS or new binding (BL-D15): its current frame colour, with the state.
function Leds:repaint(link)
	if self.stopped then
		return false
	end
	link = number_of(link) or link
	if not self.hold[link] then
		return false
	end
	local i = self:index_of(link)
	local colour = i ~= nil and self:colour_at(i, link) or nil
	if colour == nil then
		return false
	end
	return self:paint(link, colour, true)
end

function Leds:stop()
	self:cancel()
	self.stopped = true
	self.phase, self.head = "idle", 0
	self.hold, self.sent = {}, {}
end

function Leds:debug()
	local pixels, held, frame = {}, {}, {}
	for i, link in ipairs(self.order) do
		pixels[i] = link
		if self.hold[link] then
			held[link] = true
			frame[link] = self.sent[link]
		end
	end
	local range = self:rest_range()
	return {
		phase = self.phase,
		head = self.head,
		pixels = pixels,
		held = held,
		frame = frame,
		step = self.step,
		rest = { range[1], range[2] },
		strength = self.strength,
		bottom = self.bottom,
		enabled = self.enabled,
		per_speed = self.per_speed,
		online = self.online,
		breeze = self.breeze,
		active = self:active() == true,
		pending = self.armed,
		stopped = self.stopped,
	}
end

return breezeleds
