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
--     (LF-D18, light.LEDS_FOLLOW); otherwise the shown state (V10);
--   * Min On (#195, docs/min-on-design.md, cited as MO-D<n>): the fan's light has no
--     trim of its own, so this module remaps. Everything toward Control4 (CHANGING,
--     CHANGED, the preset, the rates, the taps, the scenes) stays in Control4's 0 to
--     100 %; only the levels the light wants from the model (to_fan) and the levels it
--     reports from the fan's state (from_fan, with MO-D4's memory of the last level it
--     wanted) are converted, here and nowhere else (MO-D2). M of 0 or 1 changes
--     nothing. A fade keeps the M it started with, counts and steps in fan levels, and
--     keeps its times over Control4's range (MO-D6 to MO-D8). A change of M sends
--     nothing at load, and otherwise acts once the light is quiet (MO-D9).
--
-- Pure functions (MO-D3), M any number (nil, 0 or 1: no change):
--
--   light.to_fan(level, M)   -- Control4 0..100 -> fan 0..100 (0 stays off)
--   light.from_fan(f, M)     -- fan 0..100 -> Control4 0..100 (on below max(1, M): 1)
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
-- Min On's methods (#195, the coordinator's): set_min_on(value, why) with why "load"
-- (late init's replay: taken, nothing sent) or "property" (the owner's edit), returning
-- true and the M taken, or false and why (MO-D9, MO-D10); min_on(), the M in use (0
-- until set); c4_level(st), the Control4 level for a fan state with MO-D4's memory (0
-- when off, nil when not known), for the Status row (MO-D11).
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

-- #214: the longest time a change may take and the longest delay the light asks a
-- timer for, 24 h: driver.xml's click_rate_max (86 400 000 ms), the bound common/
-- device.lua already holds the keypad's rates to. A command's TIME or RATE past it
-- is taken as it; one that is not finite (nan, inf) is 0, a change at once.
light.MAX_MS = 86400000

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

-- Min On (#195 MO-D3) -------------------------------------------------------------

-- The first lit fan level m = max(1, M), kept under 100 so that the mapping never
-- divides by 0 (MO-D10 refuses 100 before it gets here).
local function lowest(M)
	local n = tonumber(M)
	if n == nil or n ~= n then
		return 1
	end
	return math.min(99, math.max(1, n))
end

-- MO-D3, to the fan: 0 stays off; Control4's 1 to 100 % become the fan's m to 100,
-- `m + round((s - 1) x (100 - m) / 99)`, rounded half up. M nil, 0 or 1 changes nothing.
-- nil for no number.
function light.to_fan(level, M)
	local s = tonumber(level)
	if s == nil or s ~= s then
		return nil
	end
	if s <= 0 then
		return 0
	end
	local m = lowest(M)
	if m <= 1 then
		return s
	end
	s = math.min(100, math.max(1, s))
	return m + math.floor((s - 1) * (100 - m) / 99 + 0.5)
end

-- MO-D3, from the fan: 0 (off) stays 0; a fan level below m, the light on, is 1 (never 0
-- while on, MO-D5); m to 100 become `1 + round((f - m) x 99 / (100 - m))`. M nil, 0 or 1
-- changes nothing. nil for no number. For every M and every fan level from m up,
-- to_fan(from_fan(f)) is f again.
function light.from_fan(f, M)
	local n = tonumber(f)
	if n == nil or n ~= n then
		return nil
	end
	if n <= 0 then
		return 0
	end
	local m = lowest(M)
	if m <= 1 then
		return n
	end
	n = math.min(100, n)
	if n < m then
		return 1
	end
	return 1 + math.floor((n - m) * 99 / (100 - m) + 0.5)
end

-- Where a fan level stands when FADE_MIN_LEVELS counts the fan's levels (MO-D6, RT4):
-- off counts as the level just below the first lit one (m - 1, so 0 at M of 0 or 1, as
-- before Min On), and a level below m as m, since a fade from there starts at m (TO10).
local function position(fan, m)
	if fan == 0 then
		return m - 1
	end
	return math.max(m, fan)
end

-- A level for a debug line, in the unit it is (MO-D12): "40 %" for Control4, with the
-- fan's level beside it while M is above 1 ("40 % (fan level 52)"); "off" for 0.
local function level_text(level, fan, M)
	if level == 0 then
		return "off"
	end
	if lowest(M) <= 1 or fan == nil then
		return string.format("%d %%", level)
	end
	return string.format("%d %% (fan level %d)", level, fan)
end

-- The level of a fade's straight line `elapsed` ms after its start (LF-D6),
-- rounded to a whole percent and kept between its two ends. The line runs in
-- Control4's levels (MO-D6: its time is over Control4's range); each level is mapped
-- to the fan's with the fade's own M when it is wanted.
local function line_level(f, elapsed)
	if elapsed >= f.T_line then
		return f.line_to
	end
	local level = math.floor(f.line_from + (f.line_to - f.line_from) * elapsed / f.T_line + 0.5)
	return math.max(math.min(f.line_from, f.line_to), math.min(math.max(f.line_from, f.line_to), level))
end

local function cancel(t)
	if t then
		pcall(t.Cancel, t)
	end
end

-- A value for a log line (#214): at most 40 characters, a control character
-- written as \<code> ("\10" for a newline), so a value the proxy or another
-- driver sends can neither flood the log nor start a line of its own.
local function loggable(value)
	local text = tostring(value):sub(1, 41):gsub("%c", function(c)
		return "\\" .. c:byte()
	end)
	if #text > 40 then
		text = text:sub(1, 37) .. "..."
	end
	return text
end

-- A time in ms as a fade and a timer may take it (#214): a whole number 0 to
-- MAX_MS; nil for one that is not a finite number (nan, inf, -inf, no number).
local function duration(n)
	n = tonumber(n)
	if n == nil or n ~= n or n == math.huge or n == -math.huge then
		return nil
	end
	return math.max(0, math.min(light.MAX_MS, math.floor(n)))
end

-- A command's parameters on one debug line, sorted (the rate commands' H1 to H3:
-- what the proxy really sends is read off this). Each key and value is loggable().
local function params_text(params)
	local keys = {}
	for key in pairs(params) do
		keys[#keys + 1] = tostring(key)
	end
	table.sort(keys)
	local parts = {}
	for _, key in ipairs(keys) do
		parts[#parts + 1] = loggable(key) .. "=" .. loggable(params[key])
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
		M = 0,                  -- #195: the Min On in use (MO-D3's M), 0 to 99
		memory = nil,           -- MO-D4: { c4, fan, M, was } of the last level the light wanted; never persisted
		min_on_pending = false, -- MO-D9 (CM6): M changed while a change ran; acted on once the light is quiet
		phase_now = nil,        -- the model's phase as phase() last heard it (CM9)
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

-- #195 MO-D4: the Control4 level for a fan state: 0 when off, nil when not known. A fan
-- level that is the one the light last wanted is the Control4 level it wanted it for (so
-- a slider set to 4 % at Min On 20, fan level 22, reads 4 % and not 3 %); any other is
-- mapped back with the M in use (MO-D3), and on below Min On is 1 % (MO-D5). While a change
-- of M moves the light (CM2), the fan level it leaves still reads as the same Control4 level,
-- until the move is answered (`was`), whichever of settled() and idle() comes first.
function light:c4_level(st)
	local fan = level_of(st)
	if fan == nil or fan == 0 then
		return fan
	end
	local memory = self.memory
	if memory and (memory.fan == fan or memory.was == fan) then
		return memory.c4
	end
	return light.from_fan(fan, self.M)
end

-- The level of the model's confirmed state (in Control4's levels), else what the
-- proxy last heard, else 0 (an unknown light reads as off, as device.lua's LEDs do).
function light:confirmed_level()
	return self:c4_level(self:confirmed_state()) or self.told_level or 0
end

-- Where a change starts: the level the light shows now (wanted over in flight over
-- confirmed, in Control4's levels), else what the proxy heard, else 0.
function light:start_level()
	return self:c4_level(self:shown_state()) or self.told_level or 0
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

-- The light on at the Control4 level `c4`, which is fan level `fan` at Min On `M` (MO-D3):
-- the model is given the fan's level, and MO-D4's memory keeps the pair, so the answer
-- reads as the Control4 level that asked for it. The memory is set before the want (a
-- model may report at once) and put back when the model refuses.
function light:want_on(c4, fan, opts, M)
	local before = self.memory
	self.memory = { c4 = c4, fan = fan, M = M }
	local ok, why = self:want({ light_on = true, level = fan }, opts)
	if not ok then
		self.memory = before
	end
	return ok, why
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
-- when it holds no finite number; below 0 is 0, past MAX_MS is MAX_MS (#214;
-- common/device.lua refuses both already, so this is the second line).
function light:rate(name, default)
	local n = tonumber(self.dev.setting(name))
	if n == nil or n ~= n or n == math.huge or n == -math.huge then
		return default
	end
	return math.max(0, math.min(light.MAX_MS, n))
end

-- The Default Brightness Rate (LF-D4).
function light:default_rate()
	return self:rate("brightness_rate", light.DEFAULT_RATE_MS)
end

-- The time of a command: its parameter `key` (RATE, TIME) in ms, the default rate
-- when it is missing or no number, 0 when negative (LF-D4, LF-D5). #214: nan, inf
-- and -inf are 0, a change at once, and logged; past MAX_MS (24 h) is MAX_MS, and
-- logged. `name` is the command, for the log.
function light:command_rate(params, key, name)
	local raw = key and pick(params, { key }) or nil
	local n = tonumber(raw)
	if raw == nil or n == nil then
		return self:default_rate()
	end
	local ms = duration(n)
	if ms == nil then
		self.log.warn("%s %s %s is not a finite time; taken as 0, a change at once", tostring(name), key, loggable(raw))
		return 0
	end
	if n > light.MAX_MS then
		self.log.warn("%s %s %s ms is over 24 h; taken as %d ms", tostring(name), key, loggable(raw), light.MAX_MS)
	end
	return ms
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

-- #214: the delay is held to 1 ms to MAX_MS (WATCHDOG_MS when it is no finite
-- number). A fade's deadline may lie further out (MAX_MS plus WATCHDOG_MS): the
-- watchdog then fires early and arms again for what is left (watchdog_fired).
function light:arm_watchdog(ms)
	cancel(self.watchdog)
	ms = duration(ms) or light.WATCHDOG_MS
	self.watchdog = self.timer(math.max(1, ms), function()
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
	local M = self.M
	local fan = light.to_fan(level, M) -- MO-D3: 1 % is the first lit level
	local ok, why
	if level == 0 then
		ok, why = self:want({ light_on = false })
	else
		ok, why = self:want_on(level, fan, nil, M)
	end
	if not ok then
		self.log.warn("light %s not sent: %s", what, tostring(why))
		self:report(self.told_level or 0)
		return false, why
	end
	self.log.debug("light %s: target %s", what, level_text(level, fan, M))
	return true
end

-- A change to `to` (a whole percent, 0 off) that should take `T` ms (#141 LF-D1,
-- LF-D2): a fade of `kind` ("tap", "timed", "hold" or "scene") when the time and the
-- distance allow it (LF-D5) and the level the light shows is known, else one request
-- (jump). `h` is the press of a hold, whose timer device.lua cancels when it ends.
-- A running fade is replaced from the level shown now (LF-D14). Returns true when
-- taken.
--
-- #195: `to`, `from` and the line are Control4 levels and T is over Control4's range
-- (MO-D6, RT1). The fade record keeps the M it started with (`f.M`, CM6), the target's
-- fan level (`f.to_fan`) and `f.last`, the fan level it wanted last; "too small to show"
-- counts fan levels (MO-D8 :527). A fade up from a fan level below Min On starts at 1 %,
-- which is m (TO10).
function light:fade(to, T, kind, what, h)
	if self:no_kit(what) then
		return false, "no light kit"
	end
	T = duration(T) or 0 -- #214: whatever the caller hands over, 0 to MAX_MS
	local shown = self:shown_state()
	local from = self:c4_level(shown)
	local M = self.M
	local m, to_fan = lowest(M), light.to_fan(to, M)
	if from == nil or T < light.FADE_MIN_MS
		or math.abs(position(to_fan, m) - position(level_of(shown), m)) < light.FADE_MIN_LEVELS then
		return self:jump(to, what)
	end
	self:supersede()
	local now = self.now()
	local f = {
		kind = kind, h = h, from = from, to = to, T = T, begin = now, steps = 0, M = M, to_fan = to_fan,
		-- A fade to off steps down to 1 (fan level m, TO3) and then wants off (LF-D10).
		line_to = to == 0 and 1 or to,
		deadline = now + T + light.WATCHDOG_MS,
		-- LF-D10: the level the fan should keep once it is off, so the app, the remote
		-- or the wall control later turn it on where it was: the raw fan level the fade
		-- started from, not a mapped one (TO4).
		restore = to == 0 and level_of(shown) or nil,
	}
	self.active = f
	self:open_changing(from, to, T, T + light.WATCHDOG_MS)
	if from == 0 then
		-- LF-D9: a dark first level and the turn-on, an ordinary want; the line's clock
		-- starts at that want's idle(), since a turn-on may take over a second. The first
		-- level is worked out in Control4's levels, then mapped (MO-D8 :546), so the light
		-- comes on lit and in step with the Navigator's animation (TO1, TO7).
		local first = math.min(to, math.max(1, math.floor(to * light.FIRST_STEP_MS / T + 0.5)))
		local first_fan = light.to_fan(first, M)
		f.line_from, f.T_line, f.last = first, T - light.FIRST_STEP_MS, first_fan
		f.first_pending, f.steps = true, 1
		local ok, why = self:want_on(first, first_fan, { of_fade = true }, M)
		if self.active ~= f then
			return true
		end
		if not ok then
			self:fade_refused(f, why)
			return false, why
		end
	else
		f.t0, f.line_from, f.T_line, f.last = now, from, T, level_of(shown)
		self:arm_tick(f, light.FADE_TICK_MS)
	end
	self:leds()
	self.log.debug("light %s: fade %s to %s over %d ms", what, level_text(from, level_of(shown), M),
		level_text(to, to_fan, M), T)
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
		return self.log.warn("%s level %s refused: %s", name, loggable(raw), why)
	end
	self:fade(level, self:command_rate(params, rate_key, name), "timed", name)
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
-- (EC FC18). Levels and distances are Control4's; "at the preset" compares the fan's
-- level with the preset's fan level (#195 MO-D8 :626, PL9), so a level reported one or
-- two points off after a restart (RO4) sends nothing either.
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
	local shown = self:shown_state()
	local level = self:c4_level(shown)
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
	if level > 0 and math.abs(level_of(shown) - light.to_fan(preset, self.M)) <= 1 then
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
	self.log.debug("light fade %s → %s over %.1f s: %d steps, ended at %.1f s%s",
		f.from == 0 and "off" or string.format("%d %%", f.from), level_text(f.to, f.to_fan, f.M), f.T / 1000,
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

-- Every FADE_TICK_MS: the level of the line for this moment, wanted only when its fan
-- level differs from the one wanted last (LF-D6; #195 MO-D6, MO-D8 :730: two Control4
-- levels may share a fan level, which is wanted once); at the end of the line the
-- target itself. The level is mapped with the fade's own M (CM6).
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
	local fan = light.to_fan(level, f.M)
	if fan ~= f.last then
		f.last, f.steps = fan, f.steps + 1
		local ok, why = self:want_on(level, fan, { fade = true }, f.M)
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
-- the steps (LF-D6, LF-D8). When the last step already was the target's fan level and
-- is not waiting any more, nothing is wanted twice: the fade ends when it is answered,
-- or at once when it has been (#195 MO-D8 :748, in fan levels). The fan level is then
-- the target's, so MO-D4's memory takes the target: the proxy hears the level it asked
-- for, not the neighbour that the last step was for.
function light:finish_line(f)
	if f.to > 0 and f.last == f.to_fan then
		self.memory = { c4 = f.to, fan = f.to_fan, M = f.M }
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
	local ok, why
	if f.to == 0 then
		ok, why = self:want({ light_on = false }, { of_fade = true })
	else
		ok, why = self:want_on(f.to, f.to_fan, { of_fade = true }, f.M)
	end
	if self.active ~= f then
		return
	end
	if not ok then
		self:fade_refused(f, why)
	end
end

-- The fade reached its target and the model went idle: CHANGED with the level the fan
-- confirmed, then (to off) the level written back while dark (LF-D10), then a change of
-- Min On made during the fade (CM6).
function light:finish(f, st)
	self:end_fade(f, "done")
	self:report(self:c4_level(st) or self:confirmed_level())
	self:restore_level(f.to == 0 and f.restore or nil, st)
	self:settle_min_on()
end

-- LF-D10: once off is confirmed and nothing else is wanted, the starting level `level` is
-- written back while the light is dark, unless the fan keeps it already. The model sends only
-- the dark level write when its latest answer already shows the light off, and drops it if the
-- light is seen on before it goes (review fix: no second off, nothing fights a wall switch).
-- `level` is the raw fan level the fade started from, and is compared with the fan's own
-- (#195 TO4, MO-D8 :785): a level set in the app below Min On comes back exactly.
function light:restore_level(level, st)
	if not level then
		return
	end
	st = type(st) == "table" and st or self:confirmed_state()
	if type(st) ~= "table" or st.light_on ~= false or tonumber(st.level) == level or self:busy() then
		return
	end
	self.log.debug("light fade: writing fan level %d back while the light is off", level)
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
		self.log.debug("light fade stopped before its turn-on was answered: the light stays on at fan level %d",
			f.last)
	else
		local _, flying = self:withdraw()
		if f.to == 0 and f.restore and flying and flying.light_on == false then
			self.write_back = f.restore
		end
	end
	self:leds()
	self:close_if_idle()
	self:settle_min_on()
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
--
-- #195: the replay is no step of the fade but a new request for the owner's target, sent
-- later, so it is mapped with the Min On in use then.
function light:fade_failed(f, why)
	local replay = f.kind ~= "hold" and f.kind ~= "scene"
	self:end_fade(f, why)
	self.log.warn("light fade stopped: a step %s%s", why == "given_up" and "was given up" or "failed",
		replay and "; its target goes once when the fan answers again" or "")
	self:report(self:confirmed_level())
	if not replay then
		return
	end
	local ok, refused
	if f.to == 0 then
		ok, refused = self:want({ light_on = false }, { after_contact = true })
	else
		ok, refused = self:want_on(f.to, light.to_fan(f.to, self.M), { after_contact = true }, self.M)
	end
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
-- 10/_10-SET_HOLD_RATE_UP.md); the proxy hears it once, as CHANGING. `from` and the
-- distance are Control4's (#195 RT1): down stops at 1 %, which is Min On (TO6).
function light:start_ramp(h, up, from, what)
	local to = up and 100 or 1
	if from == to then
		return self.log.debug("light ramp %s: the light is at %d %% already", up and "up" or "down", to)
	end
	local T = self:span(up and "hold_up" or "hold_down", light.HOLD_RATE_MS, math.abs(to - from))
	self:fade(to, T, h and "hold" or "scene", what, h)
end

-- A ramp's beginning, for a hold (h, a press) or a scene (no press). With the
-- light on it starts from the level shown; off, the light first turns on at
-- 1 % (a target like any other) and the ramp up follows DIM_AFTER_ON_MS later;
-- down from off does nothing. A light whose state is not known is left alone,
-- as for Toggle: a ramp from a guess could lower a light that is up. Levels are
-- Control4's: the turn-on at 1 % is the fan's Min On, lit at once (#195 TO5).
function light:begin_ramp(h, up, what)
	if self:no_kit(what) then
		return
	end
	local level = self:c4_level(self:shown_state())
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
		-- From the level the light shows, kept inside 1 to 100.
		local from = self:c4_level(self:shown_state())
		self:start_ramp(h, true, (from and from >= 1) and from or 1, what)
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
		self.log.debug("light scene ramp up (scene %s)", loggable(params.SCENE_ID))
		self:begin_ramp(nil, true, "RAMP_SCENE_UP")
	end,
	RAMP_SCENE_DOWN = function(self, params)
		self.log.debug("light scene ramp down (scene %s)", loggable(params.SCENE_ID))
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
		local level = self:c4_level(self:confirmed_state()) -- in Control4's levels (PL10)
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
--
-- #195: "the level the fade set" is the fan's level against the fan level the fade wanted
-- last (MO-D8 :1072): in Control4's levels the fade's own step could map back to a
-- neighbour and end the fade by itself. What the proxy hears, and the test against what it
-- heard last, are Control4's (MO-D8 :1084), so a remote stepping below Min On is 1 % once
-- (OX6), and a level set outside below Min On is 1 %, never corrected (MO-D5).
function light:settled(st, why)
	self:contain("settled", function()
		if self.has_light == false then
			return
		end
		local fan = level_of(st)
		local level = self:c4_level(st)
		local f = self.active
		if f then
			if why ~= "outside" or fan == nil then
				return
			end
			if fan ~= 0 and fan == f.last then
				return
			end
			if fan == 0 and f.to == 0 and f.final_wanted then
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
		self:settle_min_on()
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
			self:report(self:c4_level(st) or self:confirmed_level())
		end
		if self.write_back then
			local level = self.write_back
			self.write_back = nil
			self:restore_level(level, st) -- LF-D10 after a stop whose final off went out
		end
		self:settle_min_on() -- CM6: a change of Min On made while this change ran
		if self.memory and self.memory.was and not self:busy() then
			self.memory.was = nil -- CM2's move is answered: the level it left is the fan's own again
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
		self.phase_now = phase
		if phase ~= "online" and self.min_on_pending then
			-- #195 CM9: a change of Min On still waiting is kept and sends nothing; the
			-- contact that brings the fan back reports with it.
			self:drop_min_on()
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

-- Min On (#195, docs/min-on-design.md MO-D9, MO-D10; edge cases CM1 to CM9) ------------------

-- The M in use (0 until set).
function light:min_on()
	return self.M
end

-- The owner's Light Min On (%), or late init's replay of it. `value` is taken as a number,
-- rounded half up, then kept only from 0 to 99 (MO-D10; 100 would divide by 0, BV3).
-- Returns true and the M now in use, or false and why, keeping the old M (the coordinator
-- writes it back and warns). A value equal to the one in use changes nothing (CM7).
--   * why "load" (CM7): taken, and nothing is sent, to the fan or to the proxy; the first
--     contact reports with it.
--   * why "property": one always-on info line (MO-D12), then what MO-D9 says, at once or,
--     while a change runs (a fade, a hold, a scene ramp, a target the fan has not
--     answered), once the light is quiet (CM6).
function light:set_min_on(value, why)
	local n = tonumber(value)
	if n == nil or n ~= n or n == math.huge or n == -math.huge then
		return false, "not a number"
	end
	local M = math.floor(n + 0.5)
	if M < 0 or M > 99 then
		return false, "outside 0 to 99"
	end
	if M == self.M then
		return true, M
	end
	self.M = M
	if why ~= "property" then
		-- "load", or a word this module does not know: never a write (ECM S10).
		self.memory, self.min_on_pending = nil, false
		return true, M
	end
	if M <= 1 then
		self.log.info("Light Min On %d: levels are the fan's", M)
	else
		self.log.info("Light Min On %d: Control4's 1 %% is the fan's level %d", M, M)
	end
	self:contain("Min On", light.min_on_changed)
	return true, M
end

-- True while a change of the light is under way: a fade or a scene ramp waiting for its
-- turn-on, an open CHANGING, or a level the model has not finished with.
function light:changing_now()
	return self.active ~= nil or self.pending ~= nil or self.changing_open or self:busy()
end

-- MO-D9 for the owner's edit: offline, rebooting or foreign (CM9), nothing is sent; while a
-- change runs, it waits for the light to be quiet (CM6); else it acts now.
function light:min_on_changed()
	if self.phase_now ~= "online" or self.has_light == false then
		return self:drop_min_on()
	end
	self.min_on_pending = true
	if self:changing_now() then
		return self.log.debug("light Min On %d: the change under way keeps its own; it applies when that ends",
			self.M)
	end
	self:apply_min_on()
end

-- A change of M that waited and will not act (CM9): MO-D4's memory of a level wanted with
-- another M goes, so that the next report maps with the new one; nothing is sent.
function light:drop_min_on()
	self.min_on_pending = false
	if self.memory and self.memory.M ~= self.M then
		self.memory = nil
	end
end

-- Acts on a waiting change of M once the light is quiet: at the idle() after a change, when a
-- fade ends or stops, after a report from outside (CM6).
function light:settle_min_on()
	if self.min_on_pending and not self:changing_now() then
		self:apply_min_on()
	end
end

-- MO-D9, once, with the light quiet and the fan online. MO-D4's memory says whether Control4
-- set the level the fan shows; a memory made with the M in use (a level wanted since the
-- change) needs nothing.
--   * Off (CM1): nothing is sent; the dark level the fan keeps is left alone.
--   * On at a level Control4 set (CM2, MQ3's recommended answer): the Control4 level stays and
--     the light moves to its fan level for the new M, in one request with no fade, and no
--     CHANGING or CHANGED.
--   * On at a level set outside Control4 (CM3): the fan is not touched; the proxy hears the
--     new Control4 level for the fan's, once (only when it is not what it heard last, R1).
function light:apply_min_on()
	self.min_on_pending = false
	local memory = self.memory
	if memory and memory.M == self.M then
		return
	end
	self.memory = nil
	if self.phase_now ~= "online" or self.has_light == false then
		return
	end
	local fan = level_of(self:confirmed_state())
	if fan == nil or fan == 0 then
		return
	end
	local M = self.M
	if memory and memory.fan == fan then
		local target = light.to_fan(memory.c4, M)
		if target == fan then
			self.memory = { c4 = memory.c4, fan = fan, M = M }
			return
		end
		self.log.debug("light Min On %d: %d %% stays, the light moves from fan level %d to %d", M, memory.c4, fan,
			target)
		local ok, why = self:want_on(memory.c4, target, nil, M)
		if ok and self.memory and self.memory.fan == target then
			self.memory.was = fan
		elseif not ok then
			self.log.debug("light Min On %d: the light was not moved: %s", M, tostring(why))
		end
		return
	end
	local level = light.from_fan(fan, M)
	if level ~= self.told_level then
		self.log.debug("light Min On %d: fan level %d, set outside Control4, is %d %% now", M, fan, level)
		self:report(level)
	end
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
