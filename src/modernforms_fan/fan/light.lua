-- The fan's light on the light_v2 proxy (binding 5002) of the Modern Forms Fan
-- driver, on top of common/device.lua (docs/v1-design.md sections 4.7 and 9.9;
-- the report rules are 4.5's, R1 to R9; the fades are docs/light-fades-design.md,
-- #141, cited below as LF-D<n>).
--
-- common/device.lua keeps the plumbing: the press machine (taps, the double-tap
-- window, the 400 ms hold, the click guard), the keypad settings (Default On
-- Brightness as "preset", the click, hold and brightness rates), the LED colours,
-- REQUEST_BUTTON_COLORS and the settings page's SET_* commands. This module is
-- what the light does with them:
--   * every input that sets the light (ON, OFF, TOGGLE, SET_LEVEL,
--     RAMP_TO_LEVEL, SET_BRIGHTNESS_TARGET, the three taps, the holds and the
--     scene ramps) ends in one target, a whole percent where 0 is off, with the
--     time it should take: a click or hold rate x distance / 100, a command's
--     RATE or TIME, or the Default Brightness Rate (LF-D2, LF-D4). The fan has no
--     fade of its own, so light:fade() makes one: ONE time-based engine (LF-D1,
--     LF-D6). A fade is a straight line { from, to, t0, T }; every FADE_TICK_MS
--     the light works out the level of the line for that moment and wants it
--     only when it differs from the level it wanted last, and at t0 + T the
--     target itself. The model keeps only the newest wanted level and sends it
--     when its one request slot frees, so a slow answer makes the next step
--     bigger and no level is wanted twice. A change too short or too small to
--     show (under FADE_MIN_MS or FADE_MIN_LEVELS levels, LF-D5) is one request,
--     as before. From off the fade first writes a dark level and turns on
--     (LF-D9); to off it steps down to 1 and then wants off, and writes the
--     starting level back while dark (LF-D10);
--   * the proxy hears one CHANGING at the start of a change (with the planned
--     time in ms) and one CHANGED at its end or its stop, with the level the fan
--     confirmed; nothing per step (LF-D11). A fade is stopped by a tap (the
--     press machine's dev.ramp_active / dev.on_ramp_stop hooks), by
--     SET_BRIGHTNESS_STOP and the scene stops, or by a release (LF-D12, LF-D13):
--     the unsent step is withdrawn from the model and the step in flight
--     finishes, so the reported level is the real one. Any other brightness
--     command replaces the fade from the level shown now (LF-D14). A fade never
--     fights anyone: an off nobody asked for ends it (LF-D15), a failed step
--     ends it and the target goes once after the next contact (LF-D16), and a
--     deadline ends one that lost a timer (LF-D17). Nothing about a fade is
--     stored (LF-D21);
--   * the keypad LEDs and Toggle follow the fade's target while one runs
--     (LF-D18, light.LEDS_FOLLOW); otherwise the shown state (V10).
--
-- Everything that touches Director or another module is an argument (section
-- 9.1):
--
--   light.new({
--       model = m,        -- fan/model.lua: want(fields, opts), withdraw(group), shown(), confirmed(),
--                         -- busy() (section 9.5; opts and withdraw are #141 LF-D8, LF-D13, LF-D16;
--                         -- opts.of_fade marks a fade's own ordinary wants, and withdraw's second
--                         -- value is what the request in flight sends: the review fixes)
--       dev = dev,        -- common/device.lua's instance: notify(), setting(), update_leds(),
--                         -- dim_after_on(), holding(); the hooks below are assigned to it
--       on = fn(binding, command, handler),   -- handler(binding, params)
--       now = fn,         -- milliseconds, any origin
--       timer = fn(ms, callback),   -- a one-shot timer with :Cancel()
--       log = log,        -- default common.log
--   })
--
-- Hooks assigned to dev: is_on, on_click, on_hold, on_finish, on_end_hold (device.lua
-- calls on_end_hold for every end of a press, then on_finish for the release of a
-- hold; a hold's fade is stopped by whichever comes first, so a press replaced by
-- another still ends its fade), and, since #141 (LF-D12), ramp_active and
-- on_ramp_stop (the tap machine of the Hue project's #421).
--
-- Settings read through dev.setting(): "click_up", "click_down", "hold_up",
-- "hold_down", "brightness_rate" (the Default Brightness Rate, in ms) and "preset".
--
-- Methods the model's listener (and the coordinator) call: settled(st, why),
-- idle(st), dropped(why), shown(shown), phase(phase, detail, has_light), stop(),
-- debug(). None of them, and none of the callbacks handed to Director, raises: a
-- failure is logged and the open CHANGING is closed.
--
-- Lua 5.1: no goto, no integer division, no bit operators.

local light = {}
light.__index = light

-- driver.xml: the light_v2 proxy's proxybindingid (section 2.2).
light.BINDING = 5002

-- #141 LF-D6: a fade works out its next level this often (the level is wanted
-- only when it changed).
light.FADE_TICK_MS = 50

-- #141 LF-D5: a change under this long, or over fewer levels than FADE_MIN_LEVELS,
-- is one request.
light.FADE_MIN_MS = 1000
light.FADE_MIN_LEVELS = 3

-- #141 LF-D9: a fade from off wants a first, dark level worth this much of the
-- line (to x FIRST_STEP_MS / T), then runs the rest.
light.FIRST_STEP_MS = 400

-- #141 LF-D18: what the keypad LEDs follow while a fade runs: "target" (the fade's
-- target, from the start) or "light" (the shown state, so a fade to off shows on
-- until the light is off). Probe H4 decides what the release ships with.
light.LEDS_FOLLOW = "target"

-- #141 LF-D4: the Default Brightness Rate (ms) until the proxy has sent one
-- ([assumed: the house's proxy uses 750, SDK research 3.4; probe H1 reads it]),
-- and the click and hold rates used when the setting holds no number (LF-D3: 3000;
-- device.lua's own default for the hold rates is 5000).
light.DEFAULT_RATE_MS = 750
light.CLICK_RATE_MS = 3000
light.HOLD_RATE_MS = 5000

-- common/device.lua's DIM_AFTER_ON_MS, which it keeps local: a ramp up from
-- off starts this long after the turn-on at 1 %. A hold gets it from
-- dev.dim_after_on; a scene ramp has no press and waits on its own timer.
light.DIM_AFTER_ON_MS = 600

-- #141 LF-D17: a fade's deadline is its planned end plus this. A CHANGING open
-- with nothing pending in the model is a closing the model never delivered; after
-- this long it is closed here (a safety net, not a rule: the model's idle() is the
-- way, section 4.5).
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
-- are registered. The settings page's SET_PRESET_LEVEL, SET_CLICK_RATE_UP and
-- _DOWN, SET_HOLD_RATE_UP and _DOWN, UPDATE_BRIGHTNESS_RATE_DEFAULT,
-- BUTTON_ACTION and SET_BUTTON_COLOR are device.lua's.
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

-- The level of a fade's straight line `elapsed` ms after its start (LF-D6),
-- rounded to a whole percent and kept between its two ends.
local function line_level(f, elapsed)
	if elapsed >= f.T_line then
		return f.line_to
	end
	local level = math.floor(f.line_from + (f.line_to - f.line_from) * elapsed / f.T_line + 0.5)
	return math.max(math.min(f.line_from, f.line_to), math.min(math.max(f.line_from, f.line_to), level))
end

-- What a fade's target is, as the model's wanted fields (LF-D6, LF-D10).
local function target_fields(f)
	if f.to == 0 then
		return { light_on = false }
	end
	return { light_on = true, level = f.to }
end

local function cancel(t)
	if t then
		pcall(t.Cancel, t)
	end
end

-- A command's parameters on one debug line, sorted (the rate commands' H1 to H3:
-- what the proxy really sends is read off this).
local function params_text(params)
	local keys = {}
	for key in pairs(params) do
		keys[#keys + 1] = tostring(key)
	end
	table.sort(keys)
	local parts = {}
	for _, key in ipairs(keys) do
		parts[#parts + 1] = key .. "=" .. tostring(params[key])
	end
	return table.concat(parts, " ")
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
		active = nil,           -- the running fade (below; not named fade: light:fade is the method)
		pending = nil,          -- the timer of a scene ramp waiting for its turn-on
		write_back = nil,       -- LF-D10 after a stop: the level to write while dark, once the off in flight is answered
		watchdog = nil,
		stopped = false,
	}, light)
	self:hook(opts.dev)
	for _, command in ipairs(COMMANDS) do
		local handler = light.HANDLERS[command]
		opts.on(self.binding, command, function(_, params)
			params = params or {}
			if next(params) ~= nil then
				self.log.debug("light %s: %s", command, params_text(params))
			end
			self:contain(command, handler, params)
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

-- After a failure: no fade keeps running and the proxy is not left in a
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

function light:confirmed_state()
	local ok, st = pcall(self.model.confirmed, self.model)
	return (ok and type(st) == "table") and st or nil
end

-- The level of the model's confirmed state, else what the proxy last heard,
-- else 0 (an unknown light reads as off, as device.lua's LEDs do).
function light:confirmed_level()
	return level_of(self:confirmed_state()) or self.told_level or 0
end

-- Where a change starts: the level the light shows now (wanted over in flight over
-- confirmed), else what the proxy heard, else 0.
function light:start_level()
	return level_of(self:shown_state()) or self.told_level or 0
end

-- True while the model has a wanted or an in-flight light field. A model that
-- cannot say is taken as not busy: a closing is then sooner, never missing.
function light:busy()
	local ok, busy = pcall(self.model.busy, self.model, "light")
	return ok and busy == true
end

-- The model's m:want, which also never raises into this module. `opts` is
-- { fade = true } for a fade step (LF-D6, LF-D8) or { after_contact = true } for the
-- target after a failed step (LF-D16); nil for an ordinary want.
function light:want(fields, opts)
	local ok, took, why = pcall(self.model.want, self.model, fields, opts)
	if not ok then
		self.log.error("light: the model failed on a wanted light state: %s", tostring(took))
		return false, "error"
	end
	return took and true or false, why
end

-- The model's m:withdraw("light") (LF-D13): the light's wanted but unsent fields are
-- taken back, with no warning, and the request in flight goes on. True when
-- something was taken back; the second value is what the request still in flight for the
-- light sends ({ light_on = false } for an off on the wire), or nil. A model without it
-- takes nothing back.
function light:withdraw()
	if type(self.model.withdraw) ~= "function" then
		return false
	end
	local ok, took, flying = pcall(self.model.withdraw, self.model, "light")
	if not ok then
		self.log.error("light: the model failed to withdraw the wanted light state: %s", tostring(took))
		return false
	end
	return took == true, type(flying) == "table" and flying or nil
end

-- The keypad LEDs follow the shown state, or a fade's target (LF-D18).
function light:leds()
	if self.has_light ~= false then
		self.dev.update_leds()
	end
end

-- A setting's rate in ms (a speed for the whole range, or a duration), `default`
-- when it holds no number; below 0 is 0.
function light:rate(name, default)
	local n = tonumber(self.dev.setting(name))
	if n == nil or n ~= n then
		return default
	end
	return math.max(0, n)
end

-- The Default Brightness Rate (LF-D4).
function light:default_rate()
	return self:rate("brightness_rate", light.DEFAULT_RATE_MS)
end

-- The time of a command: its parameter `key` (RATE, TIME) in ms, the default rate
-- when it is missing or no number, 0 when negative (LF-D4, LF-D5).
function light:command_rate(params, key)
	local raw = key and pick(params, { key }) or nil
	local n = tonumber(raw)
	if raw == nil or n == nil or n ~= n then
		return self:default_rate()
	end
	return math.max(0, math.floor(n))
end

-- A click or hold rate is for the whole range: the time of a change of `distance`
-- levels is rate x distance / 100 (LF-D2).
function light:span(name, default, distance)
	return math.floor(self:rate(name, default) * distance / 100)
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

-- Whether the light is heading on, for Toggle and the LEDs: the fade's target while
-- one runs (a fade to off counts as off, LF-D18), else the shown state; nil when
-- that is not known.
function light:heading_on()
	local f = self.active
	if f then
		return f.to > 0
	end
	return self:shown_state().light_on
end

-- What the proxy is told ------------------------------------------------------------

-- CHANGED with a confirmed level, closing the CHANGING if one is open.
function light:report(level)
	self.told_level = level
	self.changing_open = false
	if not self.active then
		cancel(self.watchdog)
		self.watchdog = nil
	end
	self:notify("LIGHT_BRIGHTNESS_CHANGED", { LIGHT_BRIGHTNESS_CURRENT = level })
end

-- CHANGING (#141 LF-D11): where the light is, where it goes, and the planned time
-- in ms (0 for one request). `deadline_ms` is how long the watchdog waits.
function light:open_changing(current, goal, rate, deadline_ms)
	self:notify("LIGHT_BRIGHTNESS_CHANGING", {
		LIGHT_BRIGHTNESS_CURRENT = current,
		LIGHT_BRIGHTNESS_TARGET = goal,
		RATE = rate,
	})
	self.changing_open = true
	self:arm_watchdog(deadline_ms)
end

function light:arm_watchdog(ms)
	cancel(self.watchdog)
	self.watchdog = self.timer(ms or light.WATCHDOG_MS, function()
		self:contain("watchdog", light.watchdog_fired)
	end)
end

-- #141 LF-D17: a fade that runs past its deadline (its planned end plus WATCHDOG_MS)
-- is ended here, whatever became of its timers; a CHANGING with no fade and nothing
-- pending in the model is closed (the old safety net).
function light:watchdog_fired()
	self.watchdog = nil
	local f = self.active
	if f then
		local left = f.deadline - self.now()
		if left > 0 then
			return self:arm_watchdog(left)
		end
		self.log.warn("light: a fade ran past its deadline; ending it and reporting the light as it is")
		self:withdraw()
		self:end_fade(f, "deadline")
		return self:report(self:confirmed_level())
	end
	if not self.changing_open then
		return
	end
	if self.pending or self:busy() then
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

-- One request: a whole percent, 0 off, with no fade (a change too short or too small
-- to show, LF-D5; a state not known yet, EC FC18; the turn-on at 1 % of a hold from
-- off). The proxy hears CHANGING at once (the level the light shows to the target,
-- rate 0); the model gets the wanted fields; the CHANGED comes with idle(). A
-- target the model refuses is closed at once with the told level. Replaces any
-- running fade (LF-D14). Returns true when taken.
function light:jump(level, what)
	self:supersede()
	self:open_changing(self:start_level(), level, 0)
	local ok, why = self:want(level == 0 and { light_on = false } or { light_on = true, level = level })
	if not ok then
		self.log.warn("light %s not sent: %s", what, tostring(why))
		self:report(self.told_level or 0)
		return false, why
	end
	self.log.debug("light %s: target %d", what, level)
	return true
end

-- A change to `to` (a whole percent, 0 off) that should take `T` ms (#141 LF-D1,
-- LF-D2): a fade of `kind` ("tap", "timed", "hold" or "scene") when the time and the
-- distance allow it (LF-D5) and the level the light shows is known, else one request
-- (jump). `h` is the press of a hold, whose timer device.lua cancels when it ends.
-- A running fade is replaced from the level shown now (LF-D14). Returns true when
-- taken.
function light:fade(to, T, kind, what, h)
	if self:no_kit(what) then
		return false, "no light kit"
	end
	T = math.floor(tonumber(T) or 0)
	local from = level_of(self:shown_state())
	if from == nil or T < light.FADE_MIN_MS or math.abs(to - from) < light.FADE_MIN_LEVELS then
		return self:jump(to, what)
	end
	self:supersede()
	local now = self.now()
	local f = {
		kind = kind, h = h, from = from, to = to, T = T, begin = now, steps = 0,
		-- A fade to off steps down to 1 and then wants off (LF-D10).
		line_to = to == 0 and 1 or to,
		deadline = now + T + light.WATCHDOG_MS,
		-- LF-D10: the level the fan should keep once it is off, so the app, the remote
		-- or the wall control later turn it on where it was.
		restore = to == 0 and from or nil,
	}
	self.active = f
	self:open_changing(from, to, T, T + light.WATCHDOG_MS)
	if from == 0 then
		-- LF-D9: a dark first level and the turn-on, an ordinary want; the line's clock
		-- starts at that want's idle(), since a turn-on may take over a second.
		local first = math.min(to, math.max(1, math.floor(to * light.FIRST_STEP_MS / T + 0.5)))
		f.line_from, f.T_line, f.last = first, T - light.FIRST_STEP_MS, first
		f.first_pending, f.steps = true, 1
		local ok, why = self:want({ light_on = true, level = first }, { of_fade = true })
		if self.active ~= f then
			return true
		end
		if not ok then
			self:fade_refused(f, why)
			return false, why
		end
	else
		f.t0, f.line_from, f.T_line, f.last = now, from, T, from
		self:arm_tick(f, light.FADE_TICK_MS)
	end
	self:leds()
	self.log.debug("light %s: fade %d to %d over %d ms", what, from, to, T)
	return true
end

-- A level command's target: the first of `keys` that holds a level, over the time
-- of `rate_key` (RATE, TIME) or the Default Brightness Rate.
function light:level_command(name, params, keys, rate_key)
	local raw = pick(params, keys)
	if raw == nil then
		return self.log.warn("%s without a level", name)
	end
	local level, why = percent(raw)
	if not level then
		return self.log.warn("%s level %s refused: %s", name, tostring(raw), why)
	end
	self:fade(level, self:command_rate(params, rate_key), "timed", name)
end

-- Toggle goes by where the light is heading (LF-D18), over the Default Brightness
-- Rate; a light whose state is not known is left alone rather than guessed at (the
-- fan's Toggle does the same, section 4.6).
function light:toggle(what)
	if self:no_kit(what) then
		return
	end
	local on = self:heading_on()
	if on == nil then
		return self.log.debug("light %s refused: the light's state is not known yet", what)
	end
	self:fade(on and 0 or self:preset(), self:default_rate(), "timed", what)
end

-- A tap (device.lua's button ids), the rule of docs/light-fades-design.md section 3:
-- top is Default On Brightness, ramping up or down to it over the click rate x
-- distance / 100, bottom is off, toggle goes by where the light is heading. At the
-- preset (within 1 point) nothing is sent but the level; a bottom tap with the light
-- off does nothing. A light whose level is not known goes to the target at once
-- (EC FC18).
function light:tap(button, what)
	if self:no_kit(what) then
		return
	end
	local down = button == BUTTON_BOTTOM
	if button ~= BUTTON_TOP and not down then
		local on = self:heading_on()
		if on == nil then
			return self.log.debug("light %s refused: the light's state is not known yet", what)
		end
		down = on
	end
	local level = level_of(self:shown_state())
	if down then
		if level == nil then
			return self:jump(0, what)
		end
		if level == 0 then
			return self.log.debug("light %s: the light is off already", what)
		end
		return self:fade(0, self:span("click_down", light.CLICK_RATE_MS, level), "tap", what)
	end
	local preset = self:preset()
	if level == nil then
		return self:jump(preset, what)
	end
	if level > 0 and math.abs(level - preset) <= 1 then
		self.log.debug("light %s: the light is at the preset already", what)
		return self:report(level)
	end
	local rate = level > preset and "click_down" or "click_up"
	return self:fade(preset, self:span(rate, light.CLICK_RATE_MS, math.abs(preset - level)), "tap", what)
end

-- The engine (#141 LF-D6 to LF-D17) -------------------------------------------------
-- A fade is { kind, h (the press of a hold), from, to (0 is off), T (the planned time),
-- line_from, line_to (1 for off), T_line, t0, last (the level last wanted), steps,
-- first_pending, final_wanted, restore, begin, deadline, timer }. While one runs the
-- model's settled() and idle() are not passed on as they are (no CHANGED per step,
-- LF-D11): the fade ends when its last step is answered, when it is stopped (a tap,
-- a release, a stop command), replaced (LF-D14) or ended from outside (LF-D15), and
-- the CHANGING is closed by the idle() that follows.

-- Ends the running fade without a word to the proxy: no timer, a summary line at
-- debug (LF-D20), the LEDs told (unless a new change is about to follow). `why` is
-- "done" for a fade that reached its end.
function light:end_fade(f, why, keep_leds)
	if self.active ~= f then
		return
	end
	cancel(f.timer)
	f.timer = nil
	if f.h and f.h.timer ~= nil then
		f.h.timer = nil
	end
	self.active = nil
	self.log.debug("light fade %d → %d over %.1f s: %d steps, ended at %.1f s%s", f.from, f.to, f.T / 1000,
		f.steps, (self.now() - f.begin) / 1000, why == "done" and "" or (" (" .. why .. ")"))
	if not keep_leds then
		self:leds()
	end
end

-- A new change replaces the running fade and the scene ramp waiting for its turn-on
-- (LF-D14); the LEDs wait for the new change.
function light:supersede()
	cancel(self.pending)
	self.pending = nil
	self.write_back = nil -- a new change: the light is not going to stay dark
	if self.active then
		self:end_fade(self.active, "replaced", true)
	end
end

-- Ends every fade and waiting ramp, wherever they stand, taking back what the model
-- has not sent (an error, going offline-like).
function light:stop_ramps()
	cancel(self.pending)
	self.pending = nil
	self.write_back = nil
	local f = self.active
	if f then
		self:withdraw()
		self:end_fade(f, "ended")
	end
end

function light:arm_tick(f, delay)
	f.timer = self.timer(delay, function()
		self:contain("fade step", light.tick, f)
	end)
	if f.h then
		f.h.timer = f.timer -- device.lua cancels it when the press ends
	end
end

-- A want the model refused ends the fade, and the proxy hears where it was.
function light:fade_refused(f, why)
	self:end_fade(f, "refused")
	self.log.warn("light fade stopped: %s", tostring(why))
	self:report(self.told_level or 0)
end

-- The line starts: for a fade from off when the turn-on is answered (LF-D9).
function light:begin_line(f)
	f.first_pending = false
	f.t0 = self.now()
	f.deadline = f.t0 + f.T_line + light.WATCHDOG_MS
	self:arm_watchdog(f.T_line + light.WATCHDOG_MS)
	self:arm_tick(f, math.max(1, math.min(light.FADE_TICK_MS, f.T_line)))
end

-- Every FADE_TICK_MS: the level of the line for this moment, wanted only when it
-- differs from the one wanted last (LF-D6); at the end of the line the target itself.
function light:tick(f)
	if self.active ~= f then
		return
	end
	f.timer = nil
	if f.h then
		f.h.timer = nil
		if not self.dev.holding(f.h) then
			return self:stop_fade("press ended") -- the press ended and no release reached us
		end
	end
	local elapsed = self.now() - f.t0
	if elapsed >= f.T_line then
		return self:finish_line(f)
	end
	local level = line_level(f, elapsed)
	if level ~= f.last then
		f.last, f.steps = level, f.steps + 1
		local ok, why = self:want({ light_on = true, level = level }, { fade = true })
		if self.active ~= f then
			return
		end
		if not ok then
			return self:fade_refused(f, why)
		end
	end
	self:arm_tick(f, math.max(1, math.min(light.FADE_TICK_MS, f.T_line - elapsed)))
end

-- The line has run: the target is wanted, an ordinary want that skips the budget of
-- the steps (LF-D6, LF-D8). When the last step already was the target and is not
-- waiting any more, nothing is wanted twice: the fade ends when it is answered, or
-- at once when it has been.
function light:finish_line(f)
	if f.to > 0 and f.last == f.to then
		if not self:busy() then
			return self:finish(f, nil)
		end
		if not self:withdraw() then
			f.final_wanted = true -- the step with the target is in flight: its idle() ends the fade
			return
		end
	end
	f.final_wanted = true
	f.steps = f.steps + 1
	local ok, why = self:want(target_fields(f), { of_fade = true })
	if self.active ~= f then
		return
	end
	if not ok then
		self:fade_refused(f, why)
	end
end

-- The fade reached its target and the model went idle: CHANGED with the level the fan
-- confirmed, then (to off) the level written back while dark (LF-D10).
function light:finish(f, st)
	self:end_fade(f, "done")
	self:report(level_of(st) or self:confirmed_level())
	self:restore_level(f.to == 0 and f.restore or nil, st)
end

-- LF-D10: once off is confirmed and nothing else is wanted, the starting level `level` is
-- written back while the light is dark, unless the fan keeps it already. The model sends only
-- the dark level write when its latest answer already shows the light off, and drops it if the
-- light is seen on before it goes (review fix: no second off, nothing fights a wall switch).
function light:restore_level(level, st)
	if not level then
		return
	end
	st = type(st) == "table" and st or self:confirmed_state()
	if type(st) ~= "table" or st.light_on ~= false or tonumber(st.level) == level or self:busy() then
		return
	end
	self.log.debug("light fade: writing the level %d back while the light is off", level)
	self:want({ light_on = false, level = level }, { of_fade = true })
end

-- #141 LF-D13, the stop: a tap, a release, a stop command. The level the model has
-- wanted but not sent is taken back, the step in flight finishes, and the CHANGING is
-- closed with the level the fan confirmed at the idle() that follows, or at once when
-- nothing is in flight. No request is sent for it.
--
-- Two cases the review found (departures from the letter of LF-D13, written down in
-- docs/light-fades-design.md, "Review fixes"):
--   * a fade to off whose final off is on the wire: the off finishes, and the write-back of
--     LF-D10 still follows at the idle() (it is not sent when the off never went out: the
--     light then stays on at its last level);
--   * a fade from off stopped before its turn-on was answered: the first want (the dark level
--     and the turn-on) is not withdrawn, so the light is left on at the level reached, like a
--     Control4 dimmer stopped mid-ramp, never off with a level written.
function light:stop_fade(why)
	local f = self.active
	if not f then
		return
	end
	self:end_fade(f, why or "stopped", true)
	if f.first_pending and f.to > 0 then
		self.log.debug("light fade stopped before its turn-on was answered: the light stays on at %d", f.last)
	else
		local _, flying = self:withdraw()
		if f.to == 0 and f.restore and flying and flying.light_on == false then
			self.write_back = f.restore
		end
	end
	self:leds()
	self:close_if_idle()
end

-- SET_BRIGHTNESS_STOP, STOP_SCENE_RAMP and STOP_RAMP_SCENE (the documentation
-- spells it both ways): a running fade is stopped (LF-D13); else nothing is stopped,
-- but an open CHANGING is closed with the told level, and the model's settled() says
-- the rest if the fan answers otherwise.
function light:stop_command()
	cancel(self.pending)
	self.pending = nil
	if self.active then
		return self:stop_fade("stop command")
	end
	if self.changing_open then
		self:report(self.told_level or 0)
	end
end

-- #141 LF-D16: a step failed or was given up. The fade ends, the CHANGING is closed
-- with the level the fan confirmed, one warning is logged, and the fade's target is
-- wanted once, tied to the recovery contact: it does not hurry the contact, is dropped
-- if the contact fails and is never sent once the fan has gone offline. Nothing is
-- retried step by step.
--
-- Review fix: only a fade whose target is the owner's own (a tap, a timed change) is replayed. A
-- hold or a scene ramp "targets" the end of the range (100 or 1) only so that it runs until
-- released; replaying that after a recovery, long after the button was let go, would jump the
-- light to 100 or 1. Those just end, reporting what is known, and replay nothing.
function light:fade_failed(f, why)
	local fields = target_fields(f)
	local replay = f.kind ~= "hold" and f.kind ~= "scene"
	self:end_fade(f, why)
	self.log.warn("light fade stopped: a step %s%s", why == "given_up" and "was given up" or "failed",
		replay and "; its target goes once when the fan answers again" or "")
	self:report(self:confirmed_level())
	if not replay then
		return
	end
	local ok, refused = self:want(fields, { after_contact = true })
	if not ok then
		self.log.debug("light fade: its target was not kept for the next contact: %s", tostring(refused))
	end
end

-- The model's dropped(group, why) for the light group (#141 section 4.3): why is
-- "failed", "given_up", "refused" or "off_outside".
function light:dropped(why)
	self:contain("dropped", function()
		local f = self.active
		if not f then
			return self.log.debug("light: a wanted level was dropped (%s); no fade is running", tostring(why))
		end
		if why == "failed" or why == "given_up" then
			return self:fade_failed(f, why)
		elseif why == "off_outside" then
			-- LF-D15: the Modern Forms app, the remote, the wall control or the fan's timer
			-- turned the light off. The fade ends with no further want; the settled() that
			-- follows reports the off as a change from outside.
			return self:end_fade(f, "off from outside")
		end
		return self:fade_refused(f, why)
	end)
end

-- Holds and scene ramps (LF-D19) ---------------------------------------------------------
-- The same engine at the hold rates, toward 100 (up) or 1 (down).

-- The fade itself, from a level the light shows: toward 100 (up) or 1 (down) over hold
-- rate x distance / 100 (the rate is for the whole range, LV2
-- 10/_10-SET_HOLD_RATE_UP.md); the proxy hears it once, as CHANGING.
function light:start_ramp(h, up, from, what)
	local to = up and 100 or 1
	if from == to then
		return self.log.debug("light ramp %s: the light is at %d already", up and "up" or "down", to)
	end
	local T = self:span(up and "hold_up" or "hold_down", light.HOLD_RATE_MS, math.abs(to - from))
	self:fade(to, T, h and "hold" or "scene", what, h)
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
		return self:start_ramp(h, up, level, what)
	end
	if not up then
		return self.log.debug("light %s: down from off does nothing", what)
	end
	if not self:jump(1, what) then
		return
	end
	local function resume()
		self:start_ramp(h, true, ramp_start(self:shown_state()), what)
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

-- The proxy's commands (section 4.7) --------------------------------------------------

light.HANDLERS = {
	-- ON is Default On Brightness whatever the light shows (V14); a change of
	-- the level while on is SET_LEVEL's. Without a time they take the Default
	-- Brightness Rate (LF-D4).
	ON = function(self) self:fade(self:preset(), self:default_rate(), "timed", "ON") end,
	OFF = function(self) self:fade(0, self:default_rate(), "timed", "OFF") end,
	TOGGLE = function(self) self:toggle("TOGGLE") end,
	SET_LEVEL = function(self, params) self:level_command("SET_LEVEL", params, { "LEVEL" }) end,
	-- RAMP_TO_LEVEL has TIME (ms); SET_BRIGHTNESS_TARGET has RATE (LF-D2, LF-D4).
	RAMP_TO_LEVEL = function(self, params) self:level_command("RAMP_TO_LEVEL", params, { "LEVEL" }, "TIME") end,
	SET_BRIGHTNESS_TARGET = function(self, params)
		self:level_command("SET_BRIGHTNESS_TARGET", params,
			{ "LIGHT_BRIGHTNESS_TARGET", "LIGHT BRIGHTNESS TARGET", "LEVEL" }, "RATE")
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
		if self.changing_open or self.active or self.has_light == false then
			return
		end
		local st = self:confirmed_state()
		local level = level_of(st)
		if level ~= nil then
			self:report(level)
		end
	end,
}

-- The keypad (common/device.lua's hooks) --------------------------------------------------

function light:hook(dev)
	-- What the keypad LEDs follow: the light's shown on state, so a tap lights
	-- them at once and a refusal takes them back (V10); while a fade runs, with
	-- LEDS_FOLLOW "target", its target (LF-D18). nil while unknown or without a light
	-- kit, where device.lua leaves the LEDs alone.
	dev.is_on = function()
		if self.has_light == false then
			return nil
		end
		local f = self.active
		if f and light.LEDS_FOLLOW == "target" then
			return f.to > 0
		end
		local on = self:shown_state().light_on
		if on == nil then
			return nil
		end
		return on == true
	end

	-- #141 LF-D12: the press machine asks whether a fade runs, and has it stopped
	-- when the press of a button outside the double-tap window comes (any fade, not
	-- only a tap's own).
	dev.ramp_active = function()
		return self.active ~= nil
	end
	dev.on_ramp_stop = function()
		self:contain("tap stop", function()
			self:stop_fade("tap")
		end)
	end

	-- A tap (device.lua's button ids): top is Default On Brightness, bottom is
	-- off, toggle goes by where the light is heading.
	dev.on_click = function(button)
		self:contain("tap", function()
			if button == BUTTON_TOP then
				self:tap(button, "top tap")
			elseif button == BUTTON_BOTTOM then
				self:tap(button, "bottom tap")
			else
				self:tap(button, "toggle tap")
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

	-- The release of a hold, or any other end of a press: the hold's fade stops
	-- (LF-D13).
	local function release(h)
		self:contain("release", function()
			if self.active and self.active.h == h then
				self:stop_fade("release")
			end
		end)
	end
	dev.on_finish = release
	dev.on_end_hold = release
end

-- What the model reports (section 4.5) -----------------------------------------------------

-- The model's settled("light", st, why): the confirmed state differs from what
-- was told. Only what the proxy has not heard is sent (R1); "start" is heard
-- once whatever it was told (R6). A CHANGING that is open is closed by it. While a
-- fade runs only a change from outside counts (LF-D15): the light off, or on at a
-- level the fade did not set, ends the fade (nothing more is wanted) and is reported;
-- anything else is ignored until the fade ends.
function light:settled(st, why)
	self:contain("settled", function()
		if self.has_light == false then
			return
		end
		local level = level_of(st)
		local f = self.active
		if f then
			if why ~= "outside" or level == nil then
				return
			end
			if level ~= 0 and level == f.last then
				return
			end
			if level == 0 and f.to == 0 and f.final_wanted then
				return -- the fade's own off
			end
			self:withdraw()
			self:end_fade(f, "changed from outside")
		end
		if level == nil then
			return self.log.debug("light settled without a usable state; nothing sent")
		end
		if self.changing_open or why == "start" or level ~= self.told_level then
			self:report(level)
		end
	end)
end

-- The model's idle("light", st): the light group has nothing wanted or in
-- flight. It closes the CHANGING of a target or a stopped fade with the confirmed
-- level, whether or not that changed; nothing is open for a change made elsewhere,
-- which settled() reports. While a fade runs it matters only twice (LF-D9, LF-D10):
-- after the first, dark want of a fade from off it starts the line, and after the
-- target it reports CHANGED and ends the fade (then the restore of LF-D10); the
-- idles between the steps are ignored.
function light:idle(st)
	self:contain("idle", function()
		local f = self.active
		if f then
			if f.first_pending then
				return self:begin_line(f)
			end
			if f.final_wanted then
				return self:finish(f, st)
			end
			return
		end
		if self.changing_open then
			self:report(level_of(st) or self:confirmed_level())
		end
		if self.write_back then
			local level = self.write_back
			self.write_back = nil
			self:restore_level(level, st) -- LF-D10 after a stop whose final off went out
		end
	end)
end

-- The model's shown(shown): the keypad LEDs follow it (R4, V10).
function light:shown()
	self:contain("shown", function()
		self:leds()
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
-- offline for good. Going offline-like ends a fade and closes a CHANGING with
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
		if phase == "waiting" then
			-- Review fix (LF-D16): the model leaves online for waiting only when the address changes
			-- (the owner's edit, Use Selected Fan, a follow). A fade with nothing wanted or in
			-- flight at that moment has no dropped() to end it, so it is ended here and nothing of
			-- it goes to the new address; the told level closes any CHANGING (R7). ONLINE_CHANGED
			-- stays as it was.
			self:stop_ramps()
			if self.changing_open then
				self:report(self.told_level or 0)
			end
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

-- OnDriverDestroyed: no timer survives. Nothing about a fade is stored (LF-D21).
function light:stop()
	self.stopped = true
	cancel(self.pending)
	self.pending = nil
	local f = self.active
	if f then
		cancel(f.timer)
		self.active = nil
	end
	cancel(self.watchdog)
	self.watchdog = nil
end

-- Dev State (section 12): what was told and how often, and the running fade.
function light:debug()
	local f = self.active
	return {
		told_level = self.told_level,
		changing_open = self.changing_open,
		notify_light = self.notified,
		ramping = f ~= nil,
		fading = f ~= nil,
		fade_kind = f and f.kind or nil,
		fade_from = f and f.from or nil,
		fade_to = f and f.to or nil,
		fade_ms = f and f.T or nil,
		fade_steps = f and f.steps or nil,
	}
end

return light
