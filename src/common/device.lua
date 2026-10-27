-- The plumbing a Control4 device driver keeps around its light_v2 proxy and
-- its keypad Button Links: properties and proxy notifies, the proxy lookup,
-- the Driver Version row, the buffer for messages that arrive before late
-- init, OnBindingChanged before late init, and the keypad machine (the LEDs,
-- button colours and keypad settings, and the press / click / release
-- machine with its holds). What a driver does with a tap or a hold stays in
-- the driver and reaches this module through hooks.
--
-- Ported from the owner's Hue project (corytron/c4-hue-driver,
-- src/common/device.lua, Apache-2.0), where the Hue Light and Hue Scene
-- drivers shared it and its behaviour was measured on this house's
-- controller and keypads (OS 3.4.2, October 2026; the Hue project's
-- docs/keypad-design.md). The behaviour of every block kept is unchanged;
-- tests/spec/device_spec.lua pins it here.
--
-- Stripped in the port, because it served the Hue Bridge and the devices
-- bound to it, a structure this project does not have (yet):
--   * the bridge binding (consumer binding 1, opts.bridge and opts.rid):
--     bound_bridge(), which read GetBoundProviderDevice and took 0 or nil as
--     unbound (OS 3.4.2 answers 0); send(), a C4:SendToDevice to the bridge
--     in pcall that returns false once the error is logged; the binding
--     re-check (schedule_recheck / cancel_recheck: after a Director restart
--     the binding can be invisible to GetBoundProviderDevice at late init,
--     so the device looked again at 5, 15, 30 and 60 s); goodbye(), which
--     told the bridge from OnDriverRemovedFromProject; and replay_bindings()
--     dropping a bridge binding that late init had already greeted.
--   * the dev loop's device side: forwarding every log line to the bridge
--     (devloop.forward_logs and dev.flush_log; HUE_LOG there, DEV_LOG in
--     this project's common/devloop.lua, which keeps that side dormant) and
--     DEV_RELOAD (devloop.reload_handler, opts.tree). The fan driver runs the
--     loop itself, as the Hue Bridge driver does (src/modernforms_fan/driver.lua).
--   * dim_after_on() checked for the bridge and a Hue resource before the
--     dim up; here dim_up is the driver's and decides whether it can act.
-- All of it is wanted back, from the Hue project's file, if the v1 contract
-- splits the light (or the fan) into a second driver bound to the first.
-- Hue's relative dimming (HUE_DIM) and the scene's holds were never here:
-- they lived in those drivers' on_hold / on_finish hooks.
--
-- What the v1 contract decides on top (not built here):
--   * One instance serves one light_v2 proxy on binding 5001 and its three
--     Button Links (200 top, 201 bottom, 202 toggle), and registers its proxy
--     handlers in common/dispatch by command name only. A driver with a fan
--     proxy and a light_v2 proxy needs the bindings told apart first (the
--     handlers get the binding) and the light's proxy binding as an option.
--   * The fan's per-speed links (the fan proxy's proxy_fan_speed_connections,
--     OS 3.4.2) light the active speed only: a link table and an LED rule of
--     their own, where these three links follow on / off.
--
-- No module-level state: device.new() returns one instance per driver.
--
--   local dev = device.new({
--       prefix = "Modern Forms Fan", -- the log prefix (log.set_prefix)
--       noun = "light",              -- what the keypad's log lines call the device
--       settings = { "hold_up", "hold_down" },  -- the keypad settings its driver.xml declares (SETTINGS)
--   })
--
-- Hooks the driver assigns once the functions they call exist (they are read
-- when something arrives, never at load):
--   dev.is_on()              nil while the on state is unknown, else whether the device
--                            shows on: what the keypad LEDs and holds follow
--   dev.on_click(button)     a keypad tap
--   dev.on_hold(h, up, on)   a keypad hold began ("Keypad press, click and release" below)
--   dev.on_finish(h)         the release of a hold that began
--   dev.on_end_hold(h)       optional: a press ended, whatever ended it
--
-- The instance: prop(), notify(), device_id(), result(), proxy_id(),
-- after_late_init(), late_init(), binding_changed(), replay_bindings(),
-- show_driver_version(), load_colors(), update_leds(), setting(),
-- load_settings(), button_action(), holding(), dim_after_on(), link_button()
-- and cancel_timers(). It registers the Driver_Version and Debug_Mode
-- property handlers, the proxy's BUTTON_ACTION, DO_PUSH, DO_RELEASE,
-- DO_CLICK, REQUEST_BUTTON_COLORS and SET_BUTTON_COLOR, and the SET_* command
-- of each keypad setting it takes.
--
-- OnDriverLateInit: load_settings() and load_colors(), replay the properties,
-- show_driver_version(1), then late_init() (the buffered messages), and
-- replay_bindings() last; OnDriverDestroyed calls cancel_timers().

local log = require("common.log")
local dispatch = require("common.dispatch")

local device = {}

-- The light_v2 proxy's binding, the proxybindingid its driver.xml gives it.
device.PROXY_BINDING = 5001
local PROXY_BINDING = device.PROXY_BINDING

-- BUTTON_ACTION's actions: 1 press, 2 release as a click, 0 release after a
-- hold; its buttons: 0 top, 1 bottom, 2 toggle [verified: proxy-protocol
-- reference, light_v2 BUTTON_ACTION].
device.ACT_RELEASE, device.ACT_PRESS, device.ACT_CLICK = 0, 1, 2
local ACT_RELEASE, ACT_PRESS, ACT_CLICK = device.ACT_RELEASE, device.ACT_PRESS, device.ACT_CLICK
device.BUTTON_TOP, device.BUTTON_BOTTOM = 0, 1
local BUTTON_TOP, BUTTON_BOTTOM = device.BUTTON_TOP, device.BUTTON_BOTTOM

-- Keypad buttons bound to the driver's Button Link connections (driver.xml
-- 200 top, 201 bottom, 202 toggle) -> BUTTON_ID.
device.LINK_BUTTON = { [200] = 0, [201] = 1, [202] = 2 }
local LINK_BUTTON = device.LINK_BUTTON
local LINK_BINDINGS = { 200, 201, 202 }
local BUTTON_LINK = { [0] = 200, [1] = 201, [2] = 202 }

-- Per-button colours: bottom is lit while the device is off.
local COLOR_DEFAULTS = {
	[0] = { on = "0000ff", off = "000000" },
	[1] = { on = "000000", off = "0000ff" },
	[2] = { on = "0000ff", off = "000000" },
}

-- The keypad machine's timing (the Hue project's docs/keypad-design.md): a
-- press still down after HOLD_AFTER_MS is a hold; a hold from off dims up
-- DIM_AFTER_ON_MS after the device was turned on at 1 %; a click on the same
-- button within CLICK_GUARD_MS after a hold's release is the keypad's own and
-- is ignored.
local HOLD_AFTER_MS = 400
local DIM_AFTER_ON_MS = 600
local CLICK_GUARD_MS = 1000

-- The keypad settings the light_v2 proxy sends when the dealer edits them in
-- Composer [verified: proxy-protocol reference, light_v2 SET_PRESET_LEVEL
-- {LEVEL}, SET_CLICK_RATE_* and SET_HOLD_RATE_* {RATE ms}]: the persisted key,
-- the default, the command and its parameter, and the notification that
-- tells the proxy the value now in use (PRESET_LEVEL, CLICK_RATE_UP/DOWN,
-- HOLD_RATE_UP/DOWN). Without that answer the proxy keeps its old value: on
-- the house (a Hue dev build, 2026-10-25) a hold rate set to 2.000 s reached
-- the driver, Composer still showed 5.000 afterwards, and setting 5.000 again
-- sent nothing. The notification carries the BARE value: the reference
-- documents a table ({RATE} / {BRIGHTNESS}), but the proxy reads such a
-- table as 0 (Default On Brightness 0, click rates 0, hold rates clamped to
-- its 1 s minimum), while "5000" or 5000 is stored as sent [verified:
-- hardware, OS 3.4.2, the Hue project's Composer rounds 41 and 42]. A driver
-- takes the ones its driver.xml declares (opts.settings).
local SETTINGS = {
	preset = { key = "preset_level", default = 100, command = "SET_PRESET_LEVEL", param = "LEVEL",
		notify = "PRESET_LEVEL", min = 1, max = 100 },
	click_up = { key = "click_rate_up", default = 250, command = "SET_CLICK_RATE_UP", param = "RATE",
		notify = "CLICK_RATE_UP", min = 0, max = 86400000 },
	click_down = { key = "click_rate_down", default = 250, command = "SET_CLICK_RATE_DOWN", param = "RATE",
		notify = "CLICK_RATE_DOWN", min = 0, max = 86400000 },
	hold_up = { key = "hold_rate_up", default = 5000, command = "SET_HOLD_RATE_UP", param = "RATE",
		notify = "HOLD_RATE_UP", min = 0, max = 86400000 },
	hold_down = { key = "hold_rate_down", default = 5000, command = "SET_HOLD_RATE_DOWN", param = "RATE",
		notify = "HOLD_RATE_DOWN", min = 0, max = 86400000 },
}

-- Parsing ------------------------------------------------------------------

-- A string param, or nil when absent or empty (SendToDevice drops empty
-- values, so "" never arrives; an absent key is the same thing).
function device.text(v)
	if v == nil or v == "" then
		return nil
	end
	return tostring(v)
end

function device.to_bool(v)
	if type(v) == "boolean" then
		return v
	end
	v = v ~= nil and tostring(v):lower() or nil
	if v == "true" or v == "1" then
		return true
	elseif v == "false" or v == "0" then
		return false
	end
	return nil
end

-- "0000ff" from a 6-digit hex string, nil for anything else.
local function valid_color(v)
	v = v ~= nil and tostring(v) or ""
	if v:match("^%x%x%x%x%x%x$") then
		return v:lower()
	end
	return nil
end

local function color_key(button, which)
	return string.format("button_%d_%s_color", button, which)
end

-- The instance ---------------------------------------------------------------

function device.new(opts)
	opts = opts or {}
	local dev = {}

	log.set_prefix(opts.prefix)

	-- Properties and proxy notifies ----------------------------------------

	local function prop(name, value)
		C4:UpdateProperty(name, tostring(value == nil and "" or value))
	end
	dev.prop = prop

	-- The parameter dump is for the debug line alone: with Debug Mode off
	-- (the default) nothing is built, sorted or joined per notification.
	local function notify(command, params)
		if log.enabled("debug") then
			local parts = {}
			for k, v in pairs(params or {}) do parts[#parts + 1] = k .. "=" .. tostring(v) end
			table.sort(parts)
			log.debug("-> proxy %s %s", command, table.concat(parts, " "))
		end
		C4:SendToProxy(PROXY_BINDING, command, params)
	end
	dev.notify = notify

	-- Every inter-driver param is a string.
	local function device_id()
		return tostring(C4:GetDeviceID())
	end
	dev.device_id = device_id

	-- Composer actions (LUA_ACTION): every click ends in Last Action and a
	-- log line, whatever happened.
	function dev.result(text)
		log.always("%s", text)
		prop("Last Action", text)
	end

	-- Our light_v2 proxy: the consumer bound to binding 5001, the device
	-- Composer shows and renames [verified: API 32/_3 usage note; hardware,
	-- the Hue project: the first key of the table]. nil when none.
	function dev.proxy_id()
		local bound = C4:GetBoundConsumerDevices(C4:GetDeviceID(), PROXY_BINDING)
		if type(bound) ~= "table" then
			return nil
		end
		return tonumber((next(bound)))
	end

	-- Driver Version and Debug Mode -----------------------------------------

	-- Director answers the version lookup with nothing at the first init of a
	-- device created by AddDevice [hardware 2026-10-24, the Hue project], so
	-- the build's own stamp (common/build_version.lua, written by
	-- tools/build.sh) is the fallback.
	local build_version_ok, build_version = pcall(require, "common.build_version")
	local function driver_version()
		local v = C4:GetDriverConfigInfo("version")
		if v == nil or tostring(v) == "" then
			v = build_version_ok and tostring(build_version) or ""
		end
		return v
	end

	dispatch.properties["Driver_Version"] = function()
		prop("Driver Version", driver_version())
	end

	-- Director fills a new device's property table late: at the first init
	-- of a device created by AddDevice the replay of the properties reaches
	-- no Driver_Version handler [hardware 2026-10-24, the Hue project], so
	-- late init writes the row itself and looks again twice while it is
	-- empty. The pending look is tracked: cancel_timers() (OnDriverDestroyed)
	-- stops it, and a late init run again starts over instead of adding a
	-- second chain.
	local version_timer = nil

	local function show_driver_version(attempt)
		if version_timer then
			version_timer:Cancel()
			version_timer = nil
		end
		local v = driver_version()
		prop("Driver Version", v)
		if v == "" and attempt < 3 then
			version_timer = C4:SetTimer(5000 * attempt, function()
				version_timer = nil
				show_driver_version(attempt + 1)
			end)
		end
	end
	dev.show_driver_version = show_driver_version

	dispatch.properties["Debug_Mode"] = function(value)
		log.set_debug(value == "On")
	end

	-- Before late init --------------------------------------------------------

	-- Director late-inits drivers in no particular order, so another driver's
	-- messages can reach a device before its own OnDriverLateInit, where
	-- UpdateProperty and SendToProxy are not yet safe [verified: API 22/_25.2].
	-- A handler wrapped here waits, in order, and late_init() applies the
	-- waiting calls.
	local late_init_done = false
	local early = {} -- messages received before late init, in arrival order

	function dev.after_late_init(name, handler)
		return function(params)
			if late_init_done then
				return handler(params)
			end
			if #early >= 200 then
				log.warn("%s before late init dropped: %d already waiting", name, #early)
				return
			end
			early[#early + 1] = { name = name, handler = handler, params = params }
			log.debug("%s before late init; buffered (%d waiting)", name, #early)
		end
	end

	-- OnDriverLateInit, once the driver's own state is read: from here
	-- messages are handled at once, and the buffered ones are applied in order.
	function dev.late_init()
		late_init_done = true
		local queued = early
		early = {}
		for _, m in ipairs(queued) do
			log.debug("applying buffered %s", m.name)
			local ok, err = pcall(m.handler, m.params)
			if not ok then
				log.error("buffered %s failed: %s", m.name, tostring(err))
			end
		end
	end

	-- OnBindingChanged before late init: Director can call it while the driver
	-- is still initialising, where UpdateProperty and SendToProxy are not yet
	-- safe [verified: API 22/_25.2]. binding_changed(handler) wraps the
	-- driver's handler: before late init the latest call per binding waits (an
	-- older one for the same binding says nothing the latest does not), and
	-- replay_bindings(), the last step of OnDriverLateInit, hands those calls
	-- over in arrival order; from late init on, calls pass straight through.
	local early_bindings = {} -- { id, handler, args, n }: the latest call per binding, in arrival order

	function dev.binding_changed(handler)
		return function(...)
			if late_init_done then
				return handler(...)
			end
			local id, _, bound, other = ...
			for i = #early_bindings, 1, -1 do
				if early_bindings[i].id == id then
					table.remove(early_bindings, i)
				end
			end
			early_bindings[#early_bindings + 1] = { id = id, handler = handler, args = { ... }, n = select("#", ...) }
			log.debug("OnBindingChanged on binding %s (%s, device %s) before late init; applied after it",
				tostring(id), bound and "bound" or "unbound", tostring(other))
		end
	end

	-- Every waiting call reaches the handler (a keypad bound to a Button Link
	-- during the start, an unbind), in arrival order; one that fails is logged
	-- and does not stop the rest.
	function dev.replay_bindings()
		local queued = early_bindings
		early_bindings = {}
		for _, call in ipairs(queued) do
			log.debug("applying OnBindingChanged on binding %s from before late init", tostring(call.id))
			local ok, err = pcall(call.handler, unpack(call.args, 1, call.n))
			if not ok then
				log.error("OnBindingChanged on binding %s from before late init failed: %s", tostring(call.id),
					tostring(err))
			end
		end
	end

	-- Keypad LEDs -----------------------------------------------------------
	-- A keypad bound to a Button Link follows the device: MATCH_LED_STATE on
	-- each link, and BUTTON_INFO per button to the proxy [verified: Snap One's
	-- drivers-template-code-public c4hook_light_v2.lua, the Hue project's
	-- docs/keypad-design.md "Keypad LEDs"; BUTTON_INFO fields: proxy ref,
	-- BUTTON_INFO notification]. The on state is the driver's (dev.is_on):
	-- nil while unknown.

	local colors = { [0] = {}, [1] = {}, [2] = {} } -- persisted overrides, nil = default
	local led_on = nil -- the on state the LEDs were last sent, nil before the first

	local function button_color(button, which)
		return colors[button][which] or COLOR_DEFAULTS[button][which]
	end

	function dev.load_colors()
		for button in pairs(COLOR_DEFAULTS) do
			for _, which in ipairs({ "on", "off" }) do
				colors[button][which] = valid_color(C4:PersistGetValue(color_key(button, which)))
			end
		end
	end

	local function send_button_info(button, on)
		C4:SendToProxy(PROXY_BINDING, "BUTTON_INFO", {
			BUTTON_ID = button,
			ON_COLOR = button_color(button, "on"),
			OFF_COLOR = button_color(button, "off"),
			CURRENT_COLOR = button_color(button, on and "on" or "off"),
		}, "NOTIFY")
	end

	-- BUTTON_COLORS on a link: the colours of the button bound there, with
	-- the same four fields as BUTTON_INFO [verified: Snap One
	-- c4hook_light_v2.lua, NOTIFY.BTN_COLOR_CHANGED].
	local function send_button_colors(binding, button)
		C4:SendToProxy(binding, "BUTTON_COLORS", {
			BUTTON_ID = button,
			ON_COLOR = button_color(button, "on"),
			OFF_COLOR = button_color(button, "off"),
			CURRENT_COLOR = button_color(button, (dev.is_on() == true) and "on" or "off"),
		}, "NOTIFY")
	end

	local function send_leds(on)
		led_on = on
		for _, binding in ipairs(LINK_BINDINGS) do
			C4:SendToProxy(binding, "MATCH_LED_STATE", { STATE = on }, "COMMAND")
		end
		for button = 0, 2 do
			send_button_info(button, on)
		end
	end

	-- The LEDs follow the on state once it is known; `force` resends an
	-- unchanged state (a keypad was just bound to a link).
	function dev.update_leds(force)
		local on = dev.is_on()
		if on == nil then
			return
		end
		on = on == true
		if force or on ~= led_on then
			send_leds(on)
		end
	end

	-- Keypad settings (SETTINGS) -------------------------------------------
	-- Persisted per device; one never set reads as its default.

	local setting_names = opts.settings or {}
	local settings = {}

	function dev.setting(name)
		return tonumber(settings[name]) or SETTINGS[name].default
	end

	-- The proxy hears the value in use, so Composer shows what the driver
	-- does (and a later edit back to the old value is sent at all).
	local function report_setting(name)
		local value = tostring(dev.setting(name))
		log.debug("-> proxy %s %s", SETTINGS[name].notify, value)
		C4:SendToProxy(PROXY_BINDING, SETTINGS[name].notify, value)
	end

	-- A setting outside its range is never taken: a preset level of 0 would
	-- make the top button turn the light off (seen on the house, 2026-10-25,
	-- after the proxy had been told 0 by a malformed notification).
	local function in_range(name, value)
		local s = SETTINGS[name]
		return value ~= nil and value >= s.min and value <= s.max
	end

	-- At late init: the persisted values, each reported to the proxy. One out
	-- of range reads as the default and is deleted, so it is warned about once
	-- rather than at every start (Composer shows the default, so nobody has a
	-- reason to edit the field and overwrite it).
	function dev.load_settings()
		for _, name in ipairs(setting_names) do
			-- The extra parentheses keep one value: Director's PersistGetValue
			-- returns none at all for a key never written, and tonumber() with no
			-- argument raises (a new device failed its late init on the house,
			-- the Hue project's #298).
			local value = tonumber((C4:PersistGetValue(SETTINGS[name].key)))
			if value ~= nil and not in_range(name, value) then
				log.warn("%s %s is out of range; using %s", SETTINGS[name].key, tostring(value),
					tostring(SETTINGS[name].default))
				C4:PersistDeleteValue(SETTINGS[name].key)
				value = nil
			end
			settings[name] = value
			report_setting(name)
		end
	end

	-- A value that is not a number is refused as one out of range is: the
	-- proxy hears the value kept, so Composer shows that one again rather
	-- than what was typed (the Hue project's #234).
	local function save_setting(name, raw)
		local value = tonumber(raw)
		if not value then
			log.warn("%s %s; kept %s", SETTINGS[name].key,
				raw == nil and "without a value" or string.format("%q is not a number", tostring(raw)),
				tostring(dev.setting(name)))
			return report_setting(name)
		end
		if not in_range(name, value) then
			log.warn("%s %s is out of range; kept %s", SETTINGS[name].key, tostring(value), tostring(dev.setting(name)))
			return report_setting(name)
		end
		settings[name] = value
		C4:PersistSetValue(SETTINGS[name].key, value)
		report_setting(name)
	end

	for _, name in ipairs(setting_names) do
		local s = SETTINGS[name]
		dispatch.proxy[s.command] = function(_, params) save_setting(name, params[s.param]) end
	end

	-- Keypad press, click and release ----------------------------------------
	-- A click before the hold timer fires is a tap (dev.on_click). A press
	-- still down after HOLD_AFTER_MS is a hold: top, or toggle while off, dims
	-- up; bottom, or toggle while on, down; down from off does nothing.
	-- dev.on_hold gets the direction and the on state and keeps a timer it
	-- arms for the hold in h.timer, cancelled when the press ends (for any
	-- reason; dev.on_end_hold hears each end). The release, or a
	-- release-as-click, of a hold calls dev.on_finish and ignores a click on
	-- that button for CLICK_GUARD_MS (some keypads send one). The guard is
	-- armed before dev.on_finish runs, so a failing hook still leaves the
	-- keypad's click ignored. The on state a hold starts from is
	-- dev.is_on() == true when the hold time passes.

	local noun = opts.noun or "device"
	local hold = nil  -- { button, timer, held, ... } while a button is down; the hooks add their own fields
	local guard = nil -- { button, timer } for CLICK_GUARD_MS after a hold's release

	function dev.on_end_hold() end

	-- True while `h` is the press in progress: no release, click or new press since.
	function dev.holding(h)
		return hold == h
	end

	local function end_hold()
		if hold and hold.timer then
			hold.timer:Cancel()
		end
		if hold then
			dev.on_end_hold(hold)
		end
		hold = nil
	end

	local function disarm_guard()
		if guard then
			guard.timer:Cancel()
			guard = nil
		end
	end

	local function arm_guard(button)
		disarm_guard()
		local g = { button = button }
		g.timer = C4:SetTimer(CLICK_GUARD_MS, function()
			if guard == g then
				guard = nil
			end
		end)
		guard = g
	end

	-- The hold timer fired with the button still down.
	local function start_hold(h)
		h.held = true
		local on = dev.is_on() == true
		local up = h.button == BUTTON_TOP or (h.button ~= BUTTON_BOTTOM and not on)
		if not up and not on then
			return log.debug("hold: dimming down a %s that is off does nothing", noun)
		end
		dev.on_hold(h, up, on)
	end

	local function finish_hold()
		local h = hold
		end_hold()
		arm_guard(h.button)
		dev.on_finish(h)
	end

	-- A hold from off: once dev.on_hold has turned the device on at 1 %, the
	-- dim up follows DIM_AFTER_ON_MS later, while the button is still down.
	-- Whether the device can still act then is for dim_up to decide.
	function dev.dim_after_on(h, dim_up)
		h.timer = C4:SetTimer(DIM_AFTER_ON_MS, function()
			if hold ~= h then
				return
			end
			h.timer = nil
			dim_up()
		end)
	end

	-- The routes below end here (a spec may put its own in place).
	function dev.button_action(button, action)
		if action == ACT_PRESS then
			end_hold()
			local h = { button = button }
			h.timer = C4:SetTimer(HOLD_AFTER_MS, function()
				if hold == h then
					h.timer = nil
					start_hold(h)
				end
			end)
			hold = h
		elseif action == ACT_CLICK then
			if hold and hold.held then
				finish_hold()
			elseif guard and guard.button == button then
				end_hold()
				log.debug("click on button %d right after a hold ignored", button)
			else
				end_hold()
				dev.on_click(button)
			end
		elseif action == ACT_RELEASE then
			-- Release after a hold: finish it; a release that follows a click
			-- has nothing left to do.
			if hold and hold.held then
				finish_hold()
			else
				end_hold()
			end
		end
	end

	-- Keypad buttons --------------------------------------------------------
	-- The proxy's own route (BUTTON_ACTION on the proxy binding) carries the
	-- button in the parameters and wants every action echoed [verified:
	-- proxy-protocol reference, light_v2 BUTTON_ACTION command and
	-- notification]; a keypad button bound to one of the driver's Button Link
	-- connections (200 top, 201 bottom, 202 toggle) delivers DO_PUSH,
	-- DO_RELEASE and DO_CLICK on that binding [verified: public light_v2
	-- drivers]. Both end in the machine above, dev.button_action.

	local function link_button(binding, command)
		local button = LINK_BUTTON[tonumber(binding)]
		if not button then
			log.warn("%s on binding %s: not a Button Link", command, tostring(binding))
		end
		return button
	end
	dev.link_button = link_button

	dispatch.proxy["BUTTON_ACTION"] = function(_, params)
		local button, action = tonumber(params.BUTTON_ID), tonumber(params.ACTION)
		if not button or not action then
			return log.warn("BUTTON_ACTION without BUTTON_ID/ACTION")
		end
		notify("BUTTON_ACTION", { BUTTON_ID = button, ACTION = action })
		dev.button_action(button, action)
	end

	dispatch.proxy["DO_PUSH"] = function(binding)
		local button = link_button(binding, "DO_PUSH")
		if button then dev.button_action(button, ACT_PRESS) end
	end

	dispatch.proxy["DO_RELEASE"] = function(binding)
		local button = link_button(binding, "DO_RELEASE")
		if button then dev.button_action(button, ACT_RELEASE) end
	end

	dispatch.proxy["DO_CLICK"] = function(binding)
		local button = link_button(binding, "DO_CLICK")
		if button then dev.button_action(button, ACT_CLICK) end
	end

	-- A keypad on a link asks for its button's colours and the LED state.
	dispatch.proxy["REQUEST_BUTTON_COLORS"] = function(binding)
		local button = link_button(binding, "REQUEST_BUTTON_COLORS")
		if not button then
			return
		end
		send_button_colors(tonumber(binding), button)
		C4:SendToProxy(tonumber(binding), "MATCH_LED_STATE", { STATE = dev.is_on() == true }, "COMMAND")
	end

	-- The proxy stores a button's on or off colour (the docs print the names
	-- with spaces; both spellings are accepted).
	dispatch.proxy["SET_BUTTON_COLOR"] = function(_, params)
		local button = tonumber(params.BUTTON_ID or params["BUTTON ID"])
		if not (button and COLOR_DEFAULTS[button]) then
			return log.warn("SET_BUTTON_COLOR without a known BUTTON_ID (%s)", tostring(params.BUTTON_ID))
		end
		for which, names in pairs({ on = { "ON_COLOR", "ON COLOR" }, off = { "OFF_COLOR", "OFF COLOR" } }) do
			local raw = params[names[1]] or params[names[2]]
			if raw ~= nil then
				local color = valid_color(raw)
				if color then
					colors[button][which] = color
					C4:PersistSetValue(color_key(button, which), color)
				else
					log.warn("SET_BUTTON_COLOR: %s %q is not a 6-digit hex colour", names[1], tostring(raw))
				end
			end
		end
		send_button_colors(BUTTON_LINK[button], button)
		send_button_info(button, dev.is_on() == true)
	end

	-- OnDriverDestroyed: the timers this module arms (a keypad press and its
	-- hold, the click guard and the Driver Version looks) stop with the
	-- driver. Harmless on the controller, where the Lua state goes with the
	-- device, but after a dev-loop reload a stray look would still write the
	-- row.
	function dev.cancel_timers()
		end_hold()
		disarm_guard()
		if version_timer then
			version_timer:Cancel()
			version_timer = nil
		end
	end

	return dev
end

return device
