-- The fan's light on the light_v2 proxy (binding 5002) of the Modern Forms Fan
-- driver, on top of common/device.lua (docs/v1-design.md sections 4.7 and 9.9;
-- the report rules are 4.5's, R1 to R9).
--
-- common/device.lua keeps the plumbing: the press machine (taps, the 400 ms
-- hold, the click guard), the keypad settings (Default On Brightness as
-- "preset", the hold rates), the LED colours, REQUEST_BUTTON_COLORS and the
-- settings page's SET_* commands. This module is what the light does with
-- them:
--   * every input that sets the light (ON, OFF, TOGGLE, SET_LEVEL,
--     RAMP_TO_LEVEL, SET_BRIGHTNESS_TARGET and the three taps) ends in one
--     target, a whole percent where 0 is off, handed to the model as the
--     wanted fields { light_on, level }. The model turns "on at N" into the
--     level request and then lightOn (V14, section 4.3), so this module never
--     splits a target. The rate of a command is not honoured: the light has no
--     fade (section 4.7);
--   * a hold, or a scene ramp, steps the level itself: a linear estimate
--     wanted every RAMP_STEP_MS, the latest wins in the model, and the proxy
--     hears one CHANGING at the start and one CHANGED at the end;
--   * the proxy is told only what the fan confirmed: CHANGED from the model's
--     settled() and idle(), ONLINE_CHANGED from phase(); the keypad LEDs
--     follow the shown state (V10).
--
-- Everything that touches Director or another module is an argument (section
-- 9.1):
--
--   light.new({
--       model = m,        -- fan/model.lua: want(), shown(), confirmed(), busy() (section 9.5)
--       dev = dev,        -- common/device.lua's instance: notify(), setting(), update_leds(),
--                         -- dim_after_on(), holding(); the hooks below are assigned to it
--       on = fn(binding, command, handler),   -- handler(binding, params)
--       now = fn,         -- milliseconds, any origin
--       timer = fn(ms, callback),   -- a one-shot timer with :Cancel()
--       log = log,        -- default common.log
--   })
--
-- Hooks assigned to dev: is_on, on_click, on_hold, on_finish and on_end_hold
-- (device.lua calls on_end_hold for every end of a press, then on_finish for
-- the release of a hold; a ramp is frozen by whichever comes first, so a
-- press replaced by another still ends its ramp).
--
-- Methods the model's listener (and the coordinator) call: settled(st, why),
-- idle(st), shown(shown), phase(phase, detail, has_light), stop(), debug().
-- None of them, and none of the callbacks handed to Director, raises: a
-- failure is logged and the open CHANGING is closed.

local light = {}
light.__index = light

-- driver.xml: the light_v2 proxy's proxybindingid (section 2.2).
light.BINDING = 5002

-- Section 3.4, RAMP_STEP_MS: a ramp wants its next level at most this often
-- (hardware K13 may tune it).
light.RAMP_STEP_MS = 500

-- common/device.lua's DIM_AFTER_ON_MS, which it keeps local: a ramp up from
-- off starts this long after the turn-on at 1 %. A hold gets it from
-- dev.dim_after_on; a scene ramp has no press and waits on its own timer.
light.DIM_AFTER_ON_MS = 600

-- A CHANGING open with nothing pending in the model is a closing the model
-- never delivered; after this long it is closed here (a safety net, not a
-- rule: the model's idle() is the way, section 4.5).
light.WATCHDOG_MS = 10000

-- The keypad's buttons as device.lua numbers them (the Button Links 200, 201
-- and 202): top, bottom, toggle.
local BUTTON_TOP, BUTTON_BOTTOM = 0, 1

-- What each phase of section 6.1 says about the light's ONLINE_CHANGED: true,
-- false, or "keep" (nothing sent, the last word stands).
local PHASE_ONLINE = {
	unset = false, waiting = "keep", online = true, offline = false, rebooting = "keep",
	foreign = false, gen4 = false, notfan = false,
}

-- The commands the proxy sends to the driver (LV2 10_light_v2_commands/, and
-- 45_Light_V2_advanced_lighting_scene/ for the scene ramps), in the order they
-- are registered. The settings page's SET_PRESET_LEVEL, SET_HOLD_RATE_UP and
-- _DOWN, BUTTON_ACTION and SET_BUTTON_COLOR are device.lua's.
local COMMANDS = {
	"ON", "OFF", "TOGGLE", "SET_LEVEL", "RAMP_TO_LEVEL", "SET_BRIGHTNESS_TARGET", "SET_BRIGHTNESS_STOP",
	"STOP_SCENE_RAMP", "STOP_RAMP_SCENE", "RAMP_SCENE_UP", "RAMP_SCENE_DOWN", "SYNCHRONIZE",
}

-- Parsing ------------------------------------------------------------------

-- The first parameter of those names that holds something. The documentation
-- prints LIGHT BRIGHTNESS TARGET with spaces; the house's proxy sends the
-- underscore spelling (the Hue Light, hardware 2026-10-22); LEVEL is the
-- target of the older command set (LV2 10/_1.5, "supports_target disabled").
local function pick(params, keys)
	for _, key in ipairs(keys) do
		local v = params[key]
		if v ~= nil and v ~= "" then
			return v
		end
	end
	return nil
end

-- A command's level as a whole percent, 0 for off; nil and why when it is no
-- number or lies outside 0 to 100. A positive level never rounds down to off.
local function percent(raw)
	local n = tonumber(raw)
	if n == nil or n ~= n then
		return nil, "not a number"
	end
	local level = math.floor(n + 0.5)
	if level == 0 and n > 0 then
		level = 1
	end
	if level < 0 or level > 100 then
		return nil, "outside 0 to 100"
	end
	return level
end

-- What the proxy hears for a state (section 4.1): 0 when off, the level when
-- on (a whole percent, never 0 while on); nil when that is not known.
local function level_of(st)
	if type(st) ~= "table" or st.light_on == nil then
		return nil
	end
	if st.light_on == false then
		return 0
	end
	local n = tonumber(st.level)
	if n == nil or n ~= n then
		return nil
	end
	return math.max(1, math.min(100, math.floor(n + 0.5)))
end

-- A ramp starts from the level the light shows, kept inside 1 to 100.
local function ramp_start(st)
	local level = level_of(st)
	return (level and level >= 1) and level or 1
end

local function cancel(t)
	if t then
		pcall(t.Cancel, t)
	end
end

-- The instance -----------------------------------------------------------------

function light.new(opts)
	assert(opts and opts.model and opts.dev and opts.on and opts.now and opts.timer,
		"light.new needs model, dev, on, now and timer")
	local self = setmetatable({
		model = opts.model,
		dev = opts.dev,
		now = opts.now,
		timer = opts.timer,
		log = opts.log or require("common.log"),
		binding = opts.binding or light.BINDING,
		told_level = nil,       -- the level the proxy last heard in a CHANGED (0 is off); nil before one
		changing_open = false,  -- a CHANGING the proxy has not heard the end of
		online_sent = nil,      -- the last ONLINE_CHANGED STATE sent
		online = nil,           -- what the phase asks of ONLINE_CHANGED now (true, false, or nil before any)
		has_light = nil,        -- false: the fan has no light kit, for good (sections 4.1 and 4.7)
		notified = 0,           -- CHANGING, CHANGED and ONLINE_CHANGED sent since the start
		ramp = nil,             -- the running ramp (below)
		pending = nil,          -- the timer of a scene ramp waiting for its turn-on
		watchdog = nil,
		stopped = false,
	}, light)
	self:hook(opts.dev)
	for _, command in ipairs(COMMANDS) do
		local handler = light.HANDLERS[command]
		opts.on(self.binding, command, function(_, params)
			self:contain(command, handler, params or {})
		end)
	end
	return self
end

-- Plumbing -----------------------------------------------------------------------

-- Runs fn(self, ...) so that nothing raises into the model or Director: a
-- failure is logged and recovered. Nothing runs after stop().
function light:contain(name, fn, ...)
	if self.stopped then
		return
	end
	local ok, err = pcall(fn, self, ...)
	if not ok then
		self:recover(name, err)
	end
end

-- After a failure: no ramp keeps running and the proxy is not left in a
-- CHANGING it would never hear the end of.
function light:recover(name, err)
	self.log.error("light %s failed: %s", name, tostring(err))
	pcall(function()
		self:stop_ramps()
		if self.changing_open then
			self:report(self.told_level or 0)
		end
	end)
end

function light:notify(command, params)
	self.notified = self.notified + 1
	self.dev.notify(command, params)
end

function light:shown_state()
	local ok, st = pcall(self.model.shown, self.model)
	return (ok and type(st) == "table") and st or {}
end

-- The level of the model's confirmed state, else what the proxy last heard,
-- else 0 (an unknown light reads as off, as device.lua's LEDs do).
function light:confirmed_level()
	local ok, st = pcall(self.model.confirmed, self.model)
	return (ok and level_of(st)) or self.told_level or 0
end

-- True while the model has a wanted or an in-flight light field. A model that
-- cannot say is taken as not busy: a closing is then sooner, never missing.
function light:busy()
	local ok, busy = pcall(self.model.busy, self.model, "light")
	return ok and busy == true
end

-- The model's m:want, which also never raises into this module.
function light:want(fields)
	local ok, took, why = pcall(self.model.want, self.model, fields)
	if not ok then
		self.log.error("light: the model failed on a wanted light state: %s", tostring(took))
		return false, "error"
	end
	return took and true or false, why
end

-- The light's Default On Brightness (device.lua's "preset", 1 to 100).
function light:preset()
	local n = tonumber(self.dev.setting("preset"))
	if n and n >= 1 and n <= 100 then
		return math.floor(n + 0.5)
	end
	return 100
end

-- True when the fan has no light kit: the command is refused and logged
-- (section 4.7, "No light kit"); the proxy is greyed out by ONLINE_CHANGED.
function light:no_kit(what)
	if self.has_light ~= false then
		return false
	end
	self.log.warn("light %s refused: this fan has no light kit", what)
	return true
end

-- What the proxy is told ------------------------------------------------------------

-- CHANGED with a confirmed level, closing the CHANGING if one is open.
function light:report(level)
	self.told_level = level
	self.changing_open = false
	cancel(self.watchdog)
	self.watchdog = nil
	self:notify("LIGHT_BRIGHTNESS_CHANGED", { LIGHT_BRIGHTNESS_CURRENT = level })
end

function light:open_changing(current, goal, rate)
	self:notify("LIGHT_BRIGHTNESS_CHANGING", {
		LIGHT_BRIGHTNESS_CURRENT = current,
		LIGHT_BRIGHTNESS_TARGET = goal,
		RATE = rate,
	})
	self.changing_open = true
	self:arm_watchdog()
end

function light:arm_watchdog()
	cancel(self.watchdog)
	self.watchdog = self.timer(light.WATCHDOG_MS, function()
		self:contain("watchdog", light.watchdog_fired)
	end)
end

function light:watchdog_fired()
	self.watchdog = nil
	if not self.changing_open then
		return
	end
	if self.ramp or self.pending or self:busy() then
		return self:arm_watchdog()
	end
	self.log.warn("light: a target was never closed by the model; reporting the light as it is")
	self:report(self:confirmed_level())
end

-- Closes the CHANGING now when the model has nothing left to do for the light,
-- which its idle() would otherwise have closed.
function light:close_if_idle()
	if self.changing_open and not self:busy() then
		self:report(self:confirmed_level())
	end
end

-- Targets ------------------------------------------------------------------------

-- One target: a whole percent, 0 off. The proxy hears CHANGING at once (the
-- told level to the target, no rate, since there is no fade); the model gets
-- the wanted fields; the CHANGED comes with idle(). A target the model
-- refuses is closed at once with the told level. Returns true when taken.
function light:target(level, what)
	if self:no_kit(what) then
		return false, "no light kit"
	end
	self:stop_ramps()
	self:open_changing(self.told_level or 0, level, 0)
	local ok, why = self:want(level == 0 and { light_on = false } or { light_on = true, level = level })
	if not ok then
		self.log.warn("light %s not sent: %s", what, tostring(why))
		self:report(self.told_level or 0)
		return false, why
	end
	self.log.debug("light %s: target %d", what, level)
	return true
end

-- A level command's target: the first of `keys` that holds a level.
function light:level_command(name, params, keys)
	local raw = pick(params, keys)
	if raw == nil then
		return self.log.warn("%s without a level", name)
	end
	local level, why = percent(raw)
	if not level then
		return self.log.warn("%s level %s refused: %s", name, tostring(raw), why)
	end
	self:target(level, name)
end

-- Toggle works from the shown state; a light whose state is not known is left
-- alone rather than guessed at (the fan's Toggle does the same, section 4.6).
function light:toggle(what)
	if self:no_kit(what) then
		return
	end
	local on = self:shown_state().light_on
	if on == nil then
		return self.log.debug("light %s refused: the light's state is not known yet", what)
	end
	self:target(on and 0 or self:preset(), what)
end

-- Ramps (holds and scene ramps) --------------------------------------------------------
-- A ramp is { h = the press (nil for a scene), from, to, t0, duration, last =
-- the level last wanted, timer }. While one runs, the model's settled() and
-- idle() are not passed on (no CHANGED per step); the ramp ends when it is
-- frozen (a release or a stop), when it has run its range, or when a target
-- replaces it, and the CHANGING is closed by the idle() that follows.

function light:stop_ramps()
	if self.ramp then
		cancel(self.ramp.timer)
		self.ramp = nil
	end
	cancel(self.pending)
	self.pending = nil
end

-- The linear estimate of the level at this moment, and whether the ramp has
-- run its range.
function light:estimate(r)
	local elapsed = self.now() - r.t0
	if elapsed >= r.duration then
		return r.to, true
	end
	local level = math.floor(r.from + (r.to - r.from) * elapsed / r.duration + 0.5)
	return math.max(math.min(r.from, r.to), math.min(math.max(r.from, r.to), level)), false
end

function light:arm_tick(r)
	r.timer = self.timer(light.RAMP_STEP_MS, function()
		self:contain("ramp step", light.tick, r)
	end)
	if r.h then
		r.h.timer = r.timer -- device.lua cancels it when the press ends
	end
end

-- A step the model refused ends the ramp, and the proxy hears where it was.
function light:ramp_refused(why)
	self.log.warn("light ramp stopped: %s", tostring(why))
	self:report(self.told_level or 0)
end

function light:tick(r)
	if self.ramp ~= r then
		return
	end
	r.timer = nil
	if r.h then
		r.h.timer = nil
		if not self.dev.holding(r.h) then
			return self:freeze(r) -- the press ended and no release reached us
		end
	end
	local level, spent = self:estimate(r)
	if level ~= r.last then
		r.last = level
		local ok, why = self:want({ light_on = true, level = level })
		if not ok then
			self:stop_ramps()
			return self:ramp_refused(why)
		end
	end
	if spent then
		-- The end of the range: the button may still be down, but nothing more
		-- will be wanted, so the next idle() closes the CHANGING.
		self.ramp = nil
		return self:close_if_idle()
	end
	self:arm_tick(r)
end

-- A release or a stop: the ramp stops where its estimate stands, which is
-- wanted once, and idle() closes the CHANGING (now, if the model has nothing
-- left to do).
function light:freeze(r)
	if self.ramp ~= r then
		return
	end
	cancel(r.timer)
	if r.h then
		r.h.timer = nil
	end
	self.ramp = nil
	local level = self:estimate(r)
	if level ~= r.last then
		r.last = level
		local ok, why = self:want({ light_on = true, level = level })
		if not ok then
			return self:ramp_refused(why)
		end
	end
	self:close_if_idle()
	self.log.debug("light ramp frozen at %d", level)
end

-- The ramp itself, from a level the light shows: toward 100 (up) or 1 (down)
-- over hold rate x distance / 100 (the rate is for the whole range, LV2
-- 10/_10-SET_HOLD_RATE_UP.md); the proxy hears it once, as CHANGING.
function light:start_ramp(h, up, from)
	local to = up and 100 or 1
	if from == to then
		return self.log.debug("light ramp %s: the light is at %d already", up and "up" or "down", to)
	end
	self:stop_ramps()
	local rate = tonumber(self.dev.setting(up and "hold_up" or "hold_down")) or 5000
	local duration = math.floor(rate * math.abs(to - from) / 100)
	local r = { h = h, from = from, to = to, t0 = self.now(), duration = duration, last = from }
	self.ramp = r
	self:open_changing(from, to, duration)
	self:arm_tick(r)
	self.log.debug("light ramp %s from %d over %d ms", up and "up" or "down", from, duration)
end

-- A ramp's beginning, for a hold (h, a press) or a scene (no press). With the
-- light on it starts from the level shown; off, the light first turns on at
-- 1 % (a target like any other) and the ramp up follows DIM_AFTER_ON_MS later;
-- down from off does nothing. A light whose state is not known is left alone,
-- as for Toggle: a ramp from a guess could lower a light that is up.
function light:begin_ramp(h, up, what)
	if self:no_kit(what) then
		return
	end
	local level = level_of(self:shown_state())
	if level == nil then
		return self.log.debug("light %s refused: the light's state is not known yet", what)
	end
	if level > 0 then
		return self:start_ramp(h, up, level)
	end
	if not up then
		return self.log.debug("light %s: down from off does nothing", what)
	end
	if not self:target(1, what) then
		return
	end
	local function resume()
		self:start_ramp(h, true, ramp_start(self:shown_state()))
	end
	if h then
		self.dev.dim_after_on(h, function()
			self:contain("hold ramp", resume)
		end)
	else
		self.pending = self.timer(light.DIM_AFTER_ON_MS, function()
			self.pending = nil
			self:contain("scene ramp", resume)
		end)
	end
end

-- SET_BRIGHTNESS_STOP, STOP_SCENE_RAMP and STOP_RAMP_SCENE (the documentation
-- spells it both ways): a running ramp is frozen where it stands; else
-- nothing is stopped, but an open CHANGING is closed with the told level, and
-- the model's settled() says the rest if the fan answers otherwise.
function light:stop_command()
	cancel(self.pending)
	self.pending = nil
	if self.ramp then
		return self:freeze(self.ramp)
	end
	if self.changing_open then
		self:report(self.told_level or 0)
	end
end

-- The proxy's commands (section 4.7) --------------------------------------------------

light.HANDLERS = {
	-- ON is Default On Brightness whatever the light shows (V14); a change of
	-- the level while on is SET_LEVEL's.
	ON = function(self) self:target(self:preset(), "ON") end,
	OFF = function(self) self:target(0, "OFF") end,
	TOGGLE = function(self) self:toggle("TOGGLE") end,
	SET_LEVEL = function(self, params) self:level_command("SET_LEVEL", params, { "LEVEL" }) end,
	RAMP_TO_LEVEL = function(self, params) self:level_command("RAMP_TO_LEVEL", params, { "LEVEL" }) end,
	SET_BRIGHTNESS_TARGET = function(self, params)
		self:level_command("SET_BRIGHTNESS_TARGET", params,
			{ "LIGHT_BRIGHTNESS_TARGET", "LIGHT BRIGHTNESS TARGET", "LEVEL" })
	end,
	SET_BRIGHTNESS_STOP = function(self) self:stop_command() end,
	STOP_SCENE_RAMP = function(self) self:stop_command() end,
	STOP_RAMP_SCENE = function(self) self:stop_command() end,
	-- Advanced Lighting Scenes (reduced_als_support): a ramp as a hold makes it.
	RAMP_SCENE_UP = function(self, params)
		self.log.debug("light scene ramp up (scene %s)", tostring(params.SCENE_ID))
		self:begin_ramp(nil, true, "RAMP_SCENE_UP")
	end,
	RAMP_SCENE_DOWN = function(self, params)
		self.log.debug("light scene ramp down (scene %s)", tostring(params.SCENE_ID))
		self:begin_ramp(nil, false, "RAMP_SCENE_DOWN")
	end,
	-- The proxy asks for everything it should know: the online word, and the
	-- level once it is known (as the Hue Light does; undocumented). Nothing for
	-- a CHANGING that is open: its closing is on the way.
	SYNCHRONIZE = function(self)
		if self.online ~= nil then
			self.online_sent = self.online
			self:notify("ONLINE_CHANGED", { STATE = self.online })
		end
		if self.changing_open or self.ramp or self.has_light == false then
			return
		end
		local ok, st = pcall(self.model.confirmed, self.model)
		local level = ok and level_of(st) or nil
		if level ~= nil then
			self:report(level)
		end
	end,
}

-- The keypad (common/device.lua's hooks) --------------------------------------------------

function light:hook(dev)
	-- What the keypad LEDs follow: the light's shown on state, so a tap lights
	-- them at once and a refusal takes them back (V10). nil while unknown or
	-- without a light kit, where device.lua leaves the LEDs alone.
	dev.is_on = function()
		if self.has_light == false then
			return nil
		end
		local on = self:shown_state().light_on
		if on == nil then
			return nil
		end
		return on == true
	end

	-- A tap (device.lua's button ids): top is Default On Brightness, bottom is
	-- off, toggle goes by the shown state.
	dev.on_click = function(button)
		self:contain("tap", function()
			if button == BUTTON_TOP then
				self:target(self:preset(), "top tap")
			elseif button == BUTTON_BOTTOM then
				self:target(0, "bottom tap")
			else
				self:toggle("toggle tap")
			end
		end)
	end

	-- A hold began: `up` comes from the press machine (top, or toggle while
	-- off, goes up; down from off never reaches here). The light's own shown
	-- state decides the rest, as it did the machine's `on`.
	dev.on_hold = function(h, up)
		self:contain("hold", function()
			self:begin_ramp(h, up, "hold")
		end)
	end

	-- The release of a hold, or any other end of a press: the ramp is frozen.
	local function release(h)
		self:contain("release", function()
			if self.ramp and self.ramp.h == h then
				self:freeze(self.ramp)
			end
		end)
	end
	dev.on_finish = release
	dev.on_end_hold = release
end

-- What the model reports (section 4.5) -----------------------------------------------------

-- The model's settled("light", st, why): the confirmed state differs from what
-- was told. Only what the proxy has not heard is sent (R1); "start" is heard
-- once whatever it was told (R6). A CHANGING that is open is closed by it, and
-- a ramp reports only at its end.
function light:settled(st, why)
	self:contain("settled", function()
		if self.has_light == false or self.ramp then
			return
		end
		local level = level_of(st)
		if level == nil then
			return self.log.debug("light settled without a usable state; nothing sent")
		end
		if self.changing_open or why == "start" or level ~= self.told_level then
			self:report(level)
		end
	end)
end

-- The model's idle("light", st): the light group has nothing wanted or in
-- flight. It closes the CHANGING of a target or a ramp with the confirmed
-- level, whether or not that changed; nothing is open for a change made
-- elsewhere, which settled() reports.
function light:idle(st)
	self:contain("idle", function()
		if self.ramp or not self.changing_open then
			return
		end
		self:report(level_of(st) or self:confirmed_level())
	end)
end

-- The model's shown(shown): the keypad LEDs follow it (R4, V10).
function light:shown()
	self:contain("shown", function()
		if self.has_light ~= false then
			self.dev.update_leds()
		end
	end)
end

-- The light-kit word of the model's info() (section 9.5): a boolean once the
-- fan is known, else nil. A model that cannot say, or raises, says nothing.
function light:kit_of_model()
	if type(self.model.info) ~= "function" then
		return nil
	end
	local ok, info = pcall(self.model.info, self.model)
	if ok and type(info) == "table" and type(info.has_light) == "boolean" then
		return info.has_light
	end
	return nil
end

-- The model's phase(phase, detail, has_light) (section 6.1): the proxy's
-- ONLINE_CHANGED follows it, once per change; a fan without a light kit is
-- offline for good. Going offline-like ends a ramp and closes a CHANGING with
-- the told level (never 0 for offline, R7).
function light:phase(phase, _, has_light)
	self:contain("phase", function()
		-- Only a boolean answers "is there a light kit": the model's own listener
		-- hands over the old phase in this place (section 9.5), so then the model
		-- itself is asked.
		if type(has_light) ~= "boolean" then
			has_light = self:kit_of_model()
		end
		if has_light ~= nil then
			self.has_light = has_light
		end
		local online = PHASE_ONLINE[phase]
		if online == nil then
			self.log.warn("light: unknown phase %s ignored", tostring(phase))
			online = "keep"
		end
		if self.has_light == false then
			online = false
		end
		if online == "keep" then
			return
		end
		self.online = online
		if online == false then
			self:stop_ramps()
			if self.changing_open then
				self:report(self.told_level or 0)
			end
		end
		if online ~= self.online_sent then
			self.online_sent = online
			self:notify("ONLINE_CHANGED", { STATE = online })
		end
	end)
end

-- OnDriverDestroyed: no timer survives.
function light:stop()
	self.stopped = true
	self:stop_ramps()
	cancel(self.watchdog)
	self.watchdog = nil
end

-- Dev State (section 12): what was told and how often.
function light:debug()
	return {
		told_level = self.told_level,
		changing_open = self.changing_open,
		notify_light = self.notified,
		ramping = self.ramp ~= nil,
	}
end

return light
