-- Modern Forms Breeze Fan driver (docs/breeze-design.md section 11, BF-D7 and
-- BF-D8, #121): a Modern Forms fan's Breeze as a second fan device on the
-- Navigators, listed with the room's fans, with three speeds Breeze 1 to 3.
-- The fan is either in fan mode or in Breeze mode, never both (BF-D1): the
-- main fan item shows fan mode, this device shows Breeze mode. One fan proxy
-- (5001). It never speaks to the fan itself: it is bound to the Modern Forms
-- Fan device (consumer binding 1, class MODERNFORMS_BREEZE, the fan's provider
-- binding 400), sends that device MF_BREEZE_SET, MF_BREEZE_TOGGLE,
-- MF_BREEZE_CYCLE and MF_BREEZE_HELLO with C4:SendToDevice, and hears
-- MF_BREEZE_STATE back through ExecuteCommand. The fan device decides every
-- tap from its own shown state and refuses, with its own Last Action, what it
-- cannot do.
--
-- The tile shows only what the fan device confirms: a tap sends a message and
-- reports nothing. CURRENT_SPEED goes out from a state message alone: the
-- Breeze strength (1 to 3) while BLOWS is "1", 0 while BLOWS is "0" and for a
-- fan without Breeze (HAS_BREEZE "0"), nothing new while the fan device is
-- unavailable (AVAILABLE "0" with HAS_BREEZE not "0": the tile keeps its last
-- value, since a fan proxy has no offline state, BF25 and BF26 [verified: FAN
-- 42_fan_protocol_notifications/ lists CURRENT_SPEED, DIRECTION,
-- PRESET_SPEED, ON and OFF, no online notification]) and nothing new while
-- Breeze blows at a strength the fan device does not know (STRENGTH absent is
-- unknown, never a guess). A value goes when it differs from the last one
-- sent; the first state message after a tap goes even when unchanged, so a
-- Navigator that drew the tapped speed is put back when the fan refused it
-- (BF35). Never ON or OFF notifications: ON makes the proxy assume its preset
-- speed [verified: FAN 42/_4-ON.md; hardware K8, 2026-10-27, on the main fan].
--
-- Unbound, the tile shows 0 (it controls nothing) and every tap is refused
-- here with a log line. After a Director restart the binding can be invisible
-- at late init although Composer shows it [hardware 2026-10-22, the Hue
-- project's docs/keypad-design.md]: until the re-check below has looked for
-- 60 s, or an unbind is reported, the tile keeps its value rather than
-- dropping to 0 and back (which would fire the proxy's turned_off and
-- turned_on events [verified: FAN 45_fan_events/_1-FANEVENTS.md]).
--
-- Built on common/ as the 1.2 Breeze switch was: the entry points through
-- common/dispatch.lua, the log through common/log.lua, the Driver Version and
-- Debug Mode rows, the buffer before late init and OnBindingChanged before
-- late init through common/device.lua. The provider lookup that takes 0 for
-- unbound, the protected SendToDevice and the binding re-check follow the Hue
-- project's device drivers (corytron/c4-hue-driver src/common/device.lua, the
-- owner's own code).
--
-- No dev-loop hooks: the fan driver's loop needs a Dev Server row and its own
-- command set, which this small driver does not carry.

-- DriverWorks entry points are globals the controller calls by name
-- (common/dispatch.lua sets ExecuteCommand, ReceivedFromProxy and
-- OnPropertyChanged).
-- luacheck: globals OnDriverInit OnDriverLateInit OnDriverDestroyed OnBindingChanged

local log = require("common.log")
local dispatch = require("common.dispatch")
local device = require("common.device")

local LOG_PREFIX = "Modern Forms Breeze Fan"

-- driver.xml: the fan proxy and the binding to the fan device.
local PROXY_BINDING = 5001
local FAN_BINDING = 1

-- driver.xml's discrete_levels and preset_speed.
local STRENGTHS = 3
local PRESET = 3

-- Rows stay at 70 characters or fewer (the fan driver's rule, Composer clips
-- near 75); a long fan name is cut to fit.
local ROW_MAX = 70

-- While unbound after late init the device looks again after these delays
-- (60 s in all), then takes itself for unbound and waits for a binding.
local RECHECK_MS = { 5000, 10000, 15000, 30000 }

-- Status (BF-D8); %s is the fan item's name, %d the Breeze strength. `on` is
-- for a Breeze whose strength the fan device does not know (a 1.2 fan sends
-- no STRENGTH, BF52).
local TEXTS = {
	strength = "Breeze %d on %s",
	on = "Breeze on %s",
	off = "Breeze off on %s",
	no_breeze = "%s has no Breeze",
	waiting = "Waiting for %s",
	unbound = "Not connected to a Modern Forms Fan",
}
-- The name while the fan device has not said it yet.
local NO_NAME = "the fan"

local dev = device.new({
	prefix = LOG_PREFIX,
	noun = "Breeze fan",
	proxy_binding = PROXY_BINDING,
})
local prop = dev.prop

-- device.new registers the light_v2 proxy's BUTTON_ACTION and SET_BUTTON_COLOR
-- on the proxy binding and the keypad routes on Button Links 200 to 202. A fan
-- proxy sends neither [FAN 41_fan_proxy_commands/] and this driver declares no
-- Button Link, so they go: whatever arrives there ends in dispatch's "no proxy
-- handler" debug line, as every command this driver does not know.
for _, binding in ipairs({ PROXY_BINDING, 200, 201, 202 }) do
	local handlers = dispatch.binding(binding)
	for command in pairs(handlers) do
		handlers[command] = nil
	end
end

local provider = nil       -- the bound fan device's id, or nil
local state = nil          -- { blows, available, has_breeze, fan, strength }: its last MF_BREEZE_STATE
local speed_sent = nil     -- the CURRENT_SPEED last reported, nil before any since late init
local status_shown = nil   -- the Status row as last written
local recheck_timer = nil  -- the pending binding re-check
local unbound_known = false -- true once unbound is certain: an unbind reported, or the re-check gave up
local tapped = false       -- a tap went to the fan device since its last state message

-- Parsing ---------------------------------------------------------------------

-- A value for a log line (#214): at most 40 characters, a control character
-- written as \<code> ("\10" for a newline), so a value another driver sends
-- can neither flood the log nor start a line of its own.
local function shown(value)
	local text = tostring(value):sub(1, 41):gsub("%c", function(c)
		return "\\" .. c:byte()
	end)
	if #text > 40 then
		text = text:sub(1, 37) .. "..."
	end
	return text
end

-- A whole number in lo..hi from a parameter (they arrive as strings, hardware
-- K5 and K8 on the main fan), else nil: 2.5, "x" and out-of-range values are
-- nothing.
local function whole(value, lo, hi)
	local n = tonumber(value)
	if n == nil or n ~= math.floor(n) or n < lo or n > hi then
		return nil
	end
	return n
end

-- #214: a FAN longer than this many bytes is no item name (the fan device
-- sends its item's display name, BF-D9, which no Composer name comes near),
-- so it is refused before anything reads it.
local MAX_NAME_BYTES = 256

-- Blanks trimmed, in linear time: the pattern form "^%s*(.-)%s*$" is
-- quadratic on a long run of inner blanks (#49, #214).
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

-- A name as the fan device sent it: no control characters, blanks trimmed;
-- nil when nothing is left, and for one longer than MAX_NAME_BYTES (logged;
-- the state itself still counts, shown for "the fan").
local function clean_name(text)
	text = device.text(text)
	if not text then
		return nil
	end
	if #text > MAX_NAME_BYTES then
		log.warn("MF_BREEZE_STATE: FAN of %d bytes refused (over %d); the fan is not named", #text, MAX_NAME_BYTES)
		return nil
	end
	text = trim((text:gsub("%c", "")))
	return text ~= "" and text or nil
end

-- STRENGTH "1" to "3", or nil: absent means unknown (C4:SendToDevice drops an
-- empty value [verified: API 32_serial_network_device/_19-SendToDevice.md,
-- allowEmptyValues], so the fan device leaves it out when it does not know,
-- BF-D9), and so does anything else, which is logged.
local function strength_of(value)
	local n = whole(value, 1, STRENGTHS)
	if n == nil and value ~= nil then
		log.warn("MF_BREEZE_STATE: STRENGTH %s is not 1 to %d; taken as unknown", shown(value), STRENGTHS)
	end
	return n
end

-- Texts -------------------------------------------------------------------------

-- `fmt` (one %s) with `name`, the name cut at a character boundary (UTF-8)
-- and ended with "..." when the whole line would pass ROW_MAX.
local function fit(fmt, name)
	local room = ROW_MAX - (#fmt - 2)
	local chars = {}
	for ch in name:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
		chars[#chars + 1] = ch
	end
	if #chars > room then
		name = table.concat(chars, "", 1, room - 3):match("^(.-)%s*$") .. "..."
	end
	return string.format(fmt, name)
end

local function status_text()
	if not provider then
		return TEXTS.unbound
	end
	local name = state and state.fan or NO_NAME
	if not state then
		return fit(TEXTS.waiting, name)
	end
	if state.has_breeze == false then
		return fit(TEXTS.no_breeze, name)
	end
	if not state.available then
		return fit(TEXTS.waiting, name)
	end
	if not state.blows then
		return fit(TEXTS.off, name)
	end
	if state.strength then
		return fit(string.format(TEXTS.strength, state.strength, "%s"), name)
	end
	return fit(TEXTS.on, name)
end

local function refresh_status()
	local text = status_text()
	if text ~= status_shown then
		status_shown = text
		prop("Status", text)
	end
end

-- The tile -------------------------------------------------------------------------

-- One notification to the fan proxy, protected: the API documents no error
-- [API 25_proxy/_6-SendToProxy.md], but a raise must not end the handler.
-- NOTIFY as the fan driver's proxy sends it (fan/fanproxy.lua). True when it
-- went out.
local function tell(command, params)
	if log.enabled("debug") then
		local parts = {}
		for k, v in pairs(params) do parts[#parts + 1] = k .. "=" .. tostring(v) end
		table.sort(parts)
		log.debug("-> proxy %s %s", command, table.concat(parts, " "))
	end
	local ok, err = pcall(function()
		C4:SendToProxy(PROXY_BINDING, command, params, "NOTIFY")
	end)
	if not ok then
		log.error("fan proxy %s failed: %s", command, tostring(err))
	end
	return ok
end

-- The speed the tile shows now [FAN 42/_1-CURRENTSPEED.md: 0 to N, 0 off], or
-- nil to keep what it shows: before the fan device's first state, while it is
-- unavailable, while Breeze blows at a strength not known, and while unbound
-- is not certain yet.
local function speed_now()
	if not provider then
		return unbound_known and 0 or nil
	end
	if not state then
		return nil
	end
	if state.has_breeze == false then
		return 0
	end
	if not state.available then
		return nil
	end
	if not state.blows then
		return 0
	end
	return state.strength
end

-- CURRENT_SPEED when it differs from the last one sent; `force` sends it
-- unchanged, or the last one sent again where the tile keeps its value.
local function report(force)
	local speed = speed_now()
	if speed == nil and force then
		speed = speed_sent
	end
	if speed == nil or (speed == speed_sent and not force) then
		return
	end
	if tell("CURRENT_SPEED", { SPEED = speed }) then
		speed_sent = speed
	end
end

local function show(force)
	report(force)
	refresh_status()
end

-- The fan device -------------------------------------------------------------------

-- The bound fan device's id, or nil. The API documents a table of id/name
-- pairs [verified: API 32_serial_network_device/_4-GetBoundProviderDevice.md],
-- the Hue drivers saw a number, and with nothing bound OS 3.4.2 answers 0
-- [hardware 2026-10-22, the Hue project], which Lua would take for a device.
local function bound_fan()
	local found = C4:GetBoundProviderDevice(C4:GetDeviceID(), FAN_BINDING)
	if type(found) == "table" then
		found = next(found)
	end
	found = tonumber(found)
	if found and found > 0 then
		return found
	end
	return nil
end

-- A message to the bound fan device, protected: the API documents no error
-- [API 32/_19-SendToDevice.md], but a raise must not end the handler. True
-- when it went out.
local function send(command, params)
	local target = provider
	if not target then
		return false
	end
	if log.enabled("debug") then
		local parts = {}
		for k, v in pairs(params) do parts[#parts + 1] = k .. "=" .. tostring(v) end
		table.sort(parts)
		log.debug("-> fan device %d %s %s", target, command, table.concat(parts, " "))
	end
	local ok, err = pcall(function()
		C4:SendToDevice(target, command, params)
	end)
	if not ok then
		log.error("%s to fan device %d failed: %s", command, target, tostring(err))
	end
	return ok
end

-- Ask the fan device for its state; it answers MF_BREEZE_STATE.
local function hello()
	send("MF_BREEZE_HELLO", {})
end

local function cancel_recheck()
	if recheck_timer then
		recheck_timer:Cancel()
		recheck_timer = nil
	end
end

-- Bound to `id`: a different fan device's state is not this one's, so it is
-- dropped until the hello is answered; the tile keeps its value till then.
local function connect(id)
	cancel_recheck()
	unbound_known = false
	tapped = false
	if id ~= provider then
		provider = id
		state = nil
	end
	hello()
	show(false)
end

-- Unbound for certain: the tile goes to 0.
local function disconnect()
	cancel_recheck()
	provider, state, tapped, unbound_known = nil, nil, false, true
	show(false)
end

-- True when bound; a binding Director shows by now although nothing said so
-- (the re-check's case) is taken on the way.
local function ensure_bound()
	if provider then
		return true
	end
	local id = bound_fan()
	if id then
		log.info("bound to fan device %d", id)
		connect(id)
	end
	return provider ~= nil
end

-- [API 34_timer/_1-SetTimer.md]
local function schedule_recheck(attempt)
	cancel_recheck()
	local delay = RECHECK_MS[attempt]
	if not delay then
		log.info("not bound to a Modern Forms Fan 60 s after the start; waiting for a binding")
		unbound_known = true
		return show(false)
	end
	recheck_timer = C4:SetTimer(delay, function()
		recheck_timer = nil
		if provider then
			return
		end
		local id = bound_fan()
		if id then
			log.info("binding to fan device %d visible after %d checks", id, attempt)
			connect(id)
		else
			schedule_recheck(attempt + 1)
		end
	end)
end

-- Taps -------------------------------------------------------------------------------
-- Every tap becomes one message to the fan device (BF-D8), which decides from
-- its own shown state and answers with MF_BREEZE_STATE, done or refused
-- (BF-D9). Unbound, the tap is refused here; Status already says why, and the
-- tile is told its value again.

local function refuse(command)
	log.warn("%s refused: not connected to a Modern Forms Fan", command)
	refresh_status()
	report(true)
end

local function forward(command, message, params)
	if not ensure_bound() then
		return refuse(command)
	end
	if send(message, params) then
		tapped = true
	else
		report(true)
	end
end

-- The fan proxy's commands on its binding [FAN 41_fan_proxy_commands/; API
-- 25_proxy/_5-ReceivedFromProxy.md]. One that arrives before late init waits
-- for it (GET_CURRENT_STATE comes at the add, hardware K8).
local function on_proxy(command, handler)
	local waiting = dev.after_late_init(command, handler)
	dispatch.binding(PROXY_BINDING)[command] = function(_, params)
		return waiting(params or {})
	end
end

-- ON resumes the fan's own last strength (BF27); OFF and SET_SPEED 0 end
-- Breeze, and stop the motor while Breeze blows (BF-D4); a speed is Breeze at
-- that strength (BF29).
on_proxy("ON", function()
	forward("ON", "MF_BREEZE_SET", { ON = "1" })
end)
on_proxy("OFF", function()
	forward("OFF", "MF_BREEZE_SET", { ON = "0" })
end)
on_proxy("SET_SPEED", function(params)
	local n = whole(params.SPEED, 0, STRENGTHS)
	if n == nil then
		log.warn("SET_SPEED %s refused: 0 to %d", shown(params.SPEED), STRENGTHS)
		return report(true)
	end
	if n == 0 then
		return forward("SET_SPEED", "MF_BREEZE_SET", { ON = "0" })
	end
	forward("SET_SPEED", "MF_BREEZE_SET", { ON = "1", STRENGTH = tostring(n) })
end)
-- Always the fan device's decision, from its shown state (BF28).
on_proxy("TOGGLE", function()
	forward("TOGGLE", "MF_BREEZE_TOGGLE", {})
end)
-- One step, counted by the fan device from its shown strength (BF30).
on_proxy("CYCLE_SPEED_UP", function()
	forward("CYCLE_SPEED_UP", "MF_BREEZE_CYCLE", { STEP = "1" })
end)
on_proxy("CYCLE_SPEED_DOWN", function()
	forward("CYCLE_SPEED_DOWN", "MF_BREEZE_CYCLE", { STEP = "-1" })
end)
-- The proxy asks for the state [FAN 41/_10-GETCURRENTSTATE.md]: what the tile
-- shows, again; nothing while nothing is known.
on_proxy("GET_CURRENT_STATE", function()
	report(true)
end)
-- No preset on this device (can_set_preset False, BF31), yet one such command
-- reached the main fan's proxy unasked (hardware K8). The proxy hears the
-- declared preset back [FAN 42/_3-PRESETSPEED.md], as the fan driver answers a
-- refused value, so it keeps what driver.xml says.
on_proxy("DESIGNATE_PRESET", function(params)
	log.info("DESIGNATE_PRESET %s ignored: the Breeze fan has no preset", shown(params.PRESET))
	tell("PRESET_SPEED", { SPEED = PRESET })
end)
-- can_reverse False [FAN 41/_8-SETDIRECTION.md, _9-TOGGLEDIRECTION.md]: not
-- expected, and nothing to do.
on_proxy("SET_DIRECTION", function()
	log.info("SET_DIRECTION ignored: Breeze has no direction")
end)
on_proxy("TOGGLE_DIRECTION", function()
	log.info("TOGGLE_DIRECTION ignored: Breeze has no direction")
end)

-- From the fan device (ExecuteCommand) ---------------------------------------------

-- BF-D9: BLOWS "1" in Breeze mode, AVAILABLE "0" without Breeze or while the
-- fan device is not online, HAS_BREEZE ("1" or "0", optional) whether the fan
-- has Breeze at all, FAN the fan item's name, STRENGTH ("1" to "3") the
-- confirmed Breeze strength when known.
dispatch.commands["MF_BREEZE_STATE"] = dev.after_late_init("MF_BREEZE_STATE", function(params)
	params = params or {}
	local blows, available = device.to_bool(params.BLOWS), device.to_bool(params.AVAILABLE)
	if blows == nil or available == nil then
		return log.warn("MF_BREEZE_STATE ignored: BLOWS %s, AVAILABLE %s", shown(params.BLOWS),
			shown(params.AVAILABLE))
	end
	if not ensure_bound() then
		return log.debug("MF_BREEZE_STATE ignored: not bound to a Modern Forms Fan")
	end
	state = {
		blows = blows,
		available = available,
		has_breeze = device.to_bool(params.HAS_BREEZE),
		fan = clean_name(params.FAN),
		strength = strength_of(params.STRENGTH),
	}
	local force = tapped
	tapped = false
	show(force)
end)

-- Lifecycle ------------------------------------------------------------------------

dispatch.install(_G)

-- GetBoundProviderDevice, SendToDevice, SendToProxy and UpdateProperty are not
-- for OnDriverInit [API 22_miscellaneous/_25.2-SafeUsageTable.md]: everything
-- starts at late init.
-- #214: a release build locks Composer's Lua command window, which an
-- unencrypted driver otherwise leaves open [FUND 6_Understanding .c4z
-- Drivers/_3-C4ALLOWEXECUTE.md; API 22_miscellaneous/_2-AllowExecute.md]. A
-- dev build (it carries common/devkey.lua) keeps the window its packager
-- opened.
function OnDriverInit()
	if not pcall(require, "common.devkey") then
		pcall(C4.AllowExecute, C4, false)
	end
end

-- [API 22_miscellaneous/_25.1-OnDriverLateInit.md]
function OnDriverLateInit()
	dispatch.replay_properties(Properties)
	dev.show_driver_version(1)
	cancel_recheck()
	-- A start: the proxy hears everything again.
	provider, state = bound_fan(), nil
	speed_sent, status_shown, tapped, unbound_known = nil, nil, false, false
	show(false)
	-- Messages that came first, then the hello, which the fan device answers
	-- with its state.
	dev.late_init()
	if provider then
		hello()
	else
		schedule_recheck(1)
	end
	dev.replay_bindings()
end

-- Only the binding to the fan device; the proxy's binding is not one. A call
-- before late init waits for it (common/device.lua). `other` is the device
-- OnBindingChanged names, for when Director's lookup does not show the new
-- binding yet [API 22_miscellaneous/_23-OnBindingChanged.md].
OnBindingChanged = dev.binding_changed(function(binding, _, bound, other)
	if tonumber(binding) ~= FAN_BINDING then
		return
	end
	if bound then
		local id = bound_fan() or tonumber(other)
		if id then
			connect(id)
		end
	else
		disconnect()
	end
end)

function OnDriverDestroyed()
	cancel_recheck()
	dev.cancel_timers()
end
