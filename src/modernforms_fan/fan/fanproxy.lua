-- The fan proxy of the Modern Forms Fan driver: the `fan` proxy on binding
-- 5001 (docs/v1-design.md sections 4.5, 4.6 and 9.7).
--
-- It keeps no fan state of its own and does three things:
--   * turns the proxy's commands into the model's wanted fields, working from
--     the state the model shows (wanted over in flight over confirmed, so a
--     burst of cycles counts from its target, R5), and offers the same
--     intents as methods to the keypad links (fan/links.lua);
--   * tells the proxy what the fan reported, through settled(): CURRENT_SPEED
--     (0 when off) and, with can_reverse, DIRECTION. Never ON or OFF: ON moves
--     the speed to the preset (hardware K8, 2026-10-27: a fan at 2 went to
--     3), so CURRENT_SPEED alone says on and off (R9). Never CURRENT_SPEED 0
--     for offline (R7), nothing before the first contact (R6), and a value
--     only when it differs from the last one sent (R1);
--   * keeps the preset speed ON and Toggle go to (1 to 6, default 3,
--     persisted as mf_preset_speed) and tells the proxy as PRESET_SPEED.
--
-- Fan mode and Breeze mode (#121, docs/breeze-design.md section 11): the
-- motor is stopped, in fan mode or in Breeze mode, never two of them
-- (fan/mode.lua, BF-D1), and this device shows fan mode only:
--   * CURRENT_SPEED is the speed in fan mode and 0 when stopped or in Breeze
--     mode (BF-D2), from the "fan" and the "breeze" settles alike. The model
--     reports a group once it is idle (R5), but this value reads both groups,
--     so a settle of one waits while the other half of a two-request change
--     is still wanted or in flight (BF-D13: one speed_changed, never the old
--     speed and then the new), and idle() catches up with a change whose
--     second half the fan did not take;
--   * "on" means on in fan mode (BF-D3, BF78, BF79): in Breeze mode ON and
--     TOGGLE start fan mode at the preset, CYCLE counts from off (up gives 1,
--     down nothing); a fan-mode command (ON, SET_SPEED 1 to 6, TOGGLE to on,
--     CYCLE) wants its fields through mode.exit, so `wind = false` joins them
--     while the shown `wind` is true, and OFF, SET_SPEED 0 and TOGGLE to off
--     want `fan_on = false` the same way (BF-D4: stop, and clear a stored
--     `wind`). The model orders the two requests (BF-D6);
--   * DIRECTION is held while Breeze blows and told once it ends (BF-D14,
--     BF77), so the fan's own behaviour during Breeze fires no direction
--     events on this device.
-- A fan without Breeze (`wind` nil) is never sent a `wind` and behaves as in
-- 1.2 (BF71).
--
-- Everything that touches Director is an argument (section 9.1):
--
--   fanproxy.new({
--       model = m,         -- fan/model.lua: want(), shown(), confirmed() (section 9.5)
--       on = fn(binding, command, handler),   -- handler(binding, params)
--       send = fn(command, params),           -- C4:SendToProxy(5001, command, params, "NOTIFY")
--       store = { get = fn(key), set = fn(key, value) },
--       can_reverse = bool,                   -- the static capability (V18); nil reads as False
--       log = log,                            -- default common.log
--   })
--
-- The model's listener hands it settled(group, st, why) for every group and
-- idle(group, st) for the fan and Breeze groups at least (driver.lua).
--
-- Director delivers some proxy commands before late init (GET_CURRENT_STATE
-- arrives at the add, hardware K8, 2026-10-27), where SendToProxy and the
-- persistence store are not safe. GET_CURRENT_STATE answers nothing while the
-- state is unknown, which covers it; DESIGNATE_PRESET persists and notifies,
-- so the driver hands `on` an `on` whose handlers wait for late init, as
-- common/device.lua's dev.after_late_init does for its own.

local mode = require("fan.mode")

local fanproxy = {}
fanproxy.__index = fanproxy

fanproxy.BINDING = 5001
fanproxy.SPEEDS = 6
fanproxy.DEFAULT_PRESET = 3
fanproxy.PRESET_KEY = "mf_preset_speed"

local BINDING, SPEEDS = fanproxy.BINDING, fanproxy.SPEEDS

-- The commands the proxy sends to the driver (FAN 41_fan_proxy_commands/),
-- in the order they are registered.
local COMMANDS = {
	"ON", "OFF", "TOGGLE", "SET_SPEED", "CYCLE_SPEED_UP", "CYCLE_SPEED_DOWN", "DESIGNATE_PRESET",
	"SET_DIRECTION", "TOGGLE_DIRECTION", "GET_CURRENT_STATE",
}

-- Parsing ------------------------------------------------------------------

-- A whole number in lo..hi from a proxy parameter or a number, else nil.
-- Parameters arrive as strings (hardware K5 and K8: SET_SPEED {SPEED="2"},
-- DESIGNATE_PRESET {PRESET="3"}); 2.5, "x", nan and out-of-range values are
-- nothing.
local function whole(value, lo, hi)
	local n = tonumber(value)
	if n == nil or n ~= math.floor(n) or n < lo or n > hi then
		return nil
	end
	return n
end

-- Linear: "^%s*(.-)%s*$" rescans a long run of inner blanks at every step (#49).
local function trim(text)
	local first = text:find("%S")
	if not first then
		return ""
	end
	local last = #text
	while last > first and text:find("^%s", last) do
		last = last - 1
	end
	return text:sub(first, last)
end

-- "forward" or "reverse" from FORWARD/REVERSE in any case, else nil.
local function direction_of(value)
	if type(value) ~= "string" then
		return nil
	end
	local v = trim(value):lower()
	if v == "forward" or v == "reverse" then
		return v
	end
	return nil
end

-- SET_DIRECTION's value: the parameter DIRECTION (Snap One's template; the
-- documentation leaves it unnamed, FAN 41/_8), else any parameter that holds
-- FORWARD or REVERSE, the first by name.
local function direction_param(params)
	local d = direction_of(params.DIRECTION)
	if d then
		return d
	end
	local keys = {}
	for key in pairs(params) do
		keys[#keys + 1] = key
	end
	table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
	for _, key in ipairs(keys) do
		d = direction_of(params[key])
		if d then
			return d
		end
	end
	return nil
end

-- What CURRENT_SPEED says for a state (BF-D2): the speed in fan mode, 0 when
-- stopped or in Breeze mode, nil when that is not known (nothing is reported
-- then, never a guess).
local function reported_speed(st)
	local speed = mode.speed(st)
	if speed == nil or speed == 0 then
		return speed
	end
	return whole(speed, 1, SPEEDS)
end

local function shown_of(self)
	return self.model:shown() or {}
end

-- The instance -----------------------------------------------------------------

function fanproxy.new(opts)
	assert(opts and opts.model and opts.on and opts.send, "fanproxy.new needs model, on and send")
	local self = setmetatable({
		model = opts.model,
		send = opts.send,
		store = opts.store or { get = function() end, set = function() end },
		can_reverse = opts.can_reverse == true,
		log = opts.log or require("common.log"),
		preset_speed = fanproxy.DEFAULT_PRESET,
		loaded = false,
		told_fan = nil, -- the last CURRENT_SPEED sent
		told_dir = nil, -- the last DIRECTION sent, "forward" or "reverse"
		notify_fan = 0,
		notify_dir = 0,
		speed_waits = false, -- a CURRENT_SPEED waits for the other half of a change (BF-D13)
		dir_held = false, -- a DIRECTION was held while Breeze blew (BF-D14)
		dir_force = false, -- and it was a "start" or GET_CURRENT_STATE's: told once Breeze ends, even unchanged
	}, fanproxy)

	for _, command in ipairs(COMMANDS) do
		local handler = fanproxy.HANDLERS[command]
		opts.on(BINDING, command, function(_, params)
			handler(self, params or {})
		end)
	end
	return self
end

-- One notification to the proxy; a failing send is logged and reported so
-- the caller keeps what it last told.
function fanproxy:notify(command, params)
	local ok, err = pcall(self.send, command, params)
	if not ok then
		self.log.error("fan proxy %s failed: %s", command, tostring(err))
	end
	return ok
end

function fanproxy:send_speed(speed)
	self.log.debug("-> fan proxy CURRENT_SPEED %d", speed)
	if self:notify("CURRENT_SPEED", { SPEED = speed }) then
		self.told_fan = speed
		self.notify_fan = self.notify_fan + 1
	end
end

function fanproxy:send_direction(direction)
	local name = direction:upper()
	self.log.debug("-> fan proxy DIRECTION %s", name)
	if self:notify("DIRECTION", { DIRECTION = name }) then
		self.told_dir = direction
		self.notify_dir = self.notify_dir + 1
	end
end

function fanproxy:send_preset()
	self.log.debug("-> fan proxy PRESET_SPEED %d", self:preset())
	self:notify("PRESET_SPEED", { SPEED = self:preset() })
end

-- The preset (section 4.6, V11) ----------------------------------------------------

-- The persisted preset when it is a speed, else 3. A bad stored value is
-- warned about and ignored; the store has no delete, so it is overwritten by
-- the next DESIGNATE_PRESET.
function fanproxy:load_preset()
	local ok, raw = pcall(self.store.get, fanproxy.PRESET_KEY)
	if not ok then
		self.log.warn("%s could not be read: %s; using %d", fanproxy.PRESET_KEY, tostring(raw), fanproxy.DEFAULT_PRESET)
		raw = nil
	end
	self.preset_speed = fanproxy.DEFAULT_PRESET
	if raw ~= nil and raw ~= "" then
		local n = whole(raw, 1, SPEEDS)
		if n then
			self.preset_speed = n
		else
			self.log.warn("%s %s is not a speed; using %d", fanproxy.PRESET_KEY, tostring(raw), fanproxy.DEFAULT_PRESET)
		end
	end
	self.loaded = true
end

-- ON and Toggle turn the fan on at this speed.
function fanproxy:preset()
	if not self.loaded then
		self:load_preset()
	end
	return self.preset_speed
end

-- Late init: the preset is the driver's own setting, so the proxy hears it
-- now and not with the first contact (R6; hardware K8: the proxy's Preset
-- Level page follows a PRESET_SPEED notification).
function fanproxy:late_init()
	self:load_preset()
	self:send_preset()
end

-- Intents (section 4.6) ----------------------------------------------------------
-- Each returns true, or false and why: the model's refusal, "range" for a
-- value that is no speed or direction, "unknown" when it works from a state
-- the model does not know yet, "cannot reverse" when the capability is off.

function fanproxy:want(fields)
	local ok, why = self.model:want(fields)
	if not ok then
		self.log.debug("fan command refused: %s", tostring(why))
		return false, why
	end
	return true
end

-- ON: off goes to the preset, fan mode changes nothing. Breeze mode is off
-- for this device, so ON starts fan mode at the preset and ends Breeze
-- (BF78). An unknown state counts as off: ON is a request to run, and
-- dropping it would lose the intent.
function fanproxy:on()
	local shown = shown_of(self)
	if mode.fan_on(shown) == true then
		self.log.debug("ON: the fan runs in fan mode already; nothing changes")
		return true
	end
	return self:want(mode.exit({ fan_on = true, speed = self:preset() }, shown))
end

-- OFF is sent whatever the shown state says (V8: it can be a poll old): it
-- stops the motor in Breeze mode too, and clears a stored `wind` (BF-D4).
function fanproxy:off()
	return self:want(mode.exit({ fan_on = false }, shown_of(self)))
end

-- From fan mode to off; from off or Breeze mode (which this device shows as
-- off) to fan mode at the preset (BF79: it does not stop a fan blowing Breeze).
function fanproxy:toggle()
	local shown = shown_of(self)
	local on = mode.fan_on(shown)
	if on == true then
		return self:want(mode.exit({ fan_on = false }, shown))
	elseif on == false then
		return self:want(mode.exit({ fan_on = true, speed = self:preset() }, shown))
	end
	self.log.debug("TOGGLE refused: the fan's state is not known yet")
	return false, "unknown"
end

-- SET_SPEED: 0 is off, 1 to 6 on at that speed, anything else is refused.
function fanproxy:speed(value)
	local n = whole(value, 0, SPEEDS)
	if n == nil then
		self.log.warn("fan speed %s refused: 0 to %d", tostring(value), SPEEDS)
		return false, "range"
	end
	local shown = shown_of(self)
	if n == 0 then
		return self:want(mode.exit({ fan_on = false }, shown))
	end
	return self:want(mode.exit({ fan_on = true, speed = n }, shown))
end

-- One step up (step > 0) or down (step < 0) from the shown speed, so a burst
-- counts from its target (R5). From off, up goes to 1 and down does nothing;
-- Breeze mode counts as off (BF81). At an end the speed stays: never round,
-- never off by cycling (V11; the proxy's CYCLE_SPEED_UP and DOWN and, since
-- #77, the Fan Cycle link).
function fanproxy:cycle(step)
	local shown = shown_of(self)
	local on = mode.fan_on(shown)
	if on == nil then
		self.log.debug("cycle refused: the fan's state is not known yet")
		return false, "unknown"
	end
	step = tonumber(step) or 0
	if step == 0 then
		return true
	end
	step = step > 0 and 1 or -1
	local target
	if on == false then
		if step < 0 then
			self.log.debug("cycle down: the fan is not in fan mode (off or Breeze); nothing changes")
			return true
		end
		target = 1
	else
		local speed = whole(shown.speed, 1, SPEEDS)
		if speed == nil then
			self.log.debug("cycle refused: the fan's speed is not known")
			return false, "unknown"
		end
		target = math.max(1, math.min(SPEEDS, speed + step))
		if target == speed then
			self.log.debug("cycle: the fan stays at speed %d", speed)
			return true
		end
	end
	return self:want(mode.exit({ fan_on = true, speed = target }, shown))
end

-- "forward", "reverse" or "toggle". Without the capability nothing is ever
-- written to the fan's direction (V18).
function fanproxy:direction(which)
	if not self.can_reverse then
		self.log.debug("direction %s ignored: can_reverse is False", tostring(which))
		return false, "cannot reverse"
	end
	local target = direction_of(which)
	if which == "toggle" then
		local current = direction_of(shown_of(self).direction)
		if current == nil then
			self.log.debug("direction toggle refused: the direction is not known yet")
			return false, "unknown"
		end
		target = current == "forward" and "reverse" or "forward"
	end
	if target == nil then
		self.log.warn("fan direction %s refused: FORWARD or REVERSE", tostring(which))
		return false, "range"
	end
	return self:want({ direction = target })
end

-- Reports (section 4.5) ----------------------------------------------------------

-- Whether the other half of a two-request change is still wanted or in
-- flight (BF-D6, BF-D13): the shown state against the confirmed one the
-- settle carries. A "fan" settle looks at `wind`, a "breeze" settle at fan_on
-- and the speed (the settled group itself is idle, R5); anything else at all
-- three. A fan without Breeze has no `wind` on either side, so its "fan"
-- settles never wait.
function fanproxy:half_way(group, st)
	local shown = shown_of(self)
	local fan_fields = shown.fan_on ~= st.fan_on or shown.speed ~= st.speed
	if group == "fan" then
		return shown.wind ~= st.wind
	elseif group == "breeze" then
		return fan_fields
	end
	return fan_fields or shown.wind ~= st.wind
end

-- CURRENT_SPEED from a confirmed state (BF-D2), when it differs from the last
-- one sent (R1) or at the "fan" group's "start" (R6: the "breeze" group's
-- start, from the same state, adds nothing). Outside "start" it waits while
-- the other half of the change is under way, and the next settle or idle()
-- tells it.
function fanproxy:tell_speed(group, st, why)
	local speed = reported_speed(st)
	if speed == nil then
		if st.fan_on == true then
			self.log.debug("the fan is on without a speed: no CURRENT_SPEED sent")
		end
		return
	end
	if why ~= "start" and self:half_way(group, st) then
		self.speed_waits = true
		self.log.debug("CURRENT_SPEED %d waits for the rest of the change", speed)
		return
	end
	self.speed_waits = false
	if speed ~= self.told_fan or (why == "start" and group == "fan") then
		self:send_speed(speed)
	end
end

-- DIRECTION from a confirmed state, with can_reverse: held while Breeze blows
-- (BF-D14: what the fan does with its direction during Breeze is no change of
-- this device's), else sent when it differs from the last one sent (R1), at
-- "start" (R6), or once after a hold that a "start" or GET_CURRENT_STATE asked for.
function fanproxy:tell_direction(st, why)
	if not self.can_reverse then
		return
	end
	local direction = direction_of(st.direction)
	if direction == nil then
		return
	end
	if mode.breeze(st) then
		self.dir_held = true
		self.dir_force = self.dir_force or why == "start"
		self.log.debug("DIRECTION %s held while Breeze blows", direction:upper())
		return
	end
	local force = why == "start" or self.dir_force
	self.dir_held, self.dir_force = false, false
	if direction ~= self.told_dir or force then
		self:send_direction(direction)
	end
end

-- What waited is told from a later state: the speed once nothing is half way,
-- a held direction once Breeze no longer blows.
function fanproxy:catch_up(group, st)
	if self.speed_waits then
		self:tell_speed(group, st, nil)
	end
	if self.dir_held and not mode.breeze(st) then
		self:tell_direction(st, nil)
	end
end

-- The model's settled(group, st, why), st the whole confirmed state: the fan
-- and Breeze groups give CURRENT_SPEED, the direction group DIRECTION; any
-- settle catches up with what waited. The light's is the light's.
function fanproxy:settled(group, st, why)
	st = st or {}
	if group == "fan" or group == "breeze" then
		self:tell_speed(group, st, why)
		if self.dir_held and not mode.breeze(st) then
			self:tell_direction(st, nil)
		end
	elseif group == "direction" then
		self:tell_direction(st, why)
		self:catch_up(group, st)
	else
		self:catch_up(group, st)
	end
end

-- The model's idle(group, st): a group's command is done, answered or
-- dropped. A CURRENT_SPEED that waited for it is told now, so a second half
-- the fan did not take (or a target equal to what the first answer showed,
-- which the model does not settle again) still reaches the proxy.
function fanproxy:idle(group, st)
	self:catch_up(group, st or {})
end

-- GET_CURRENT_STATE: the proxy asks for everything (it comes at the add,
-- hardware K8). Nothing until the first contact has made the state known
-- (R6; the first contact's settled "start" and late_init's PRESET_SPEED
-- cover that), then the confirmed values, which the proxy asked for.
function fanproxy:report_all()
	local st = self.model:confirmed()
	if st == nil then
		self.log.debug("GET_CURRENT_STATE: the fan's state is not known yet; nothing sent")
		return
	end
	local speed = reported_speed(st)
	if speed ~= nil then
		self:send_speed(speed)
	end
	local direction = direction_of(st.direction)
	if self.can_reverse and direction then
		if mode.breeze(st) then
			-- BF-D14: told once Breeze ends, even when it is the one told before.
			self.dir_held, self.dir_force = true, true
			self.log.debug("GET_CURRENT_STATE: DIRECTION %s held while Breeze blows", direction:upper())
		else
			self.dir_held, self.dir_force = false, false
			self:send_direction(direction)
		end
	end
	self:send_preset()
end

-- The proxy's commands -----------------------------------------------------------

fanproxy.HANDLERS = {
	ON = function(self) self:on() end,
	OFF = function(self) self:off() end,
	TOGGLE = function(self) self:toggle() end,
	SET_SPEED = function(self, params) self:speed(params.SPEED) end,
	CYCLE_SPEED_UP = function(self) self:cycle(1) end,
	CYCLE_SPEED_DOWN = function(self) self:cycle(-1) end,
	-- The reply is sent for a refused value too, so the proxy's Preset Level
	-- page shows the preset in use again (the Hue project's #234).
	DESIGNATE_PRESET = function(self, params)
		local n = whole(params.PRESET, 1, SPEEDS)
		if n == nil then
			self.log.warn("DESIGNATE_PRESET %s refused: 1 to %d; kept %d", tostring(params.PRESET), SPEEDS, self:preset())
			return self:send_preset()
		end
		self.preset_speed, self.loaded = n, true
		local ok, err = pcall(self.store.set, fanproxy.PRESET_KEY, n)
		if not ok then
			self.log.error("%s could not be saved: %s", fanproxy.PRESET_KEY, tostring(err))
		end
		self:send_preset()
	end,
	SET_DIRECTION = function(self, params)
		local d = direction_param(params)
		if d == nil and self.can_reverse then
			self.log.warn("SET_DIRECTION refused: FORWARD or REVERSE expected")
			return
		end
		self:direction(d)
	end,
	TOGGLE_DIRECTION = function(self) self:direction("toggle") end,
	GET_CURRENT_STATE = function(self) self:report_all() end,
}

-- Dev State (section 12): what was told and how often.
function fanproxy:debug()
	return {
		told_fan = self.told_fan,
		told_dir = self.told_dir,
		notify_fan = self.notify_fan,
		notify_dir = self.notify_dir,
		preset = self:preset(),
	}
end

return fanproxy
