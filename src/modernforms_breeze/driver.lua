-- Modern Forms Breeze driver (docs/breeze-design.md section 4, #111): the
-- companion switch that puts a Modern Forms fan's Breeze on the Navigators,
-- which the fan proxy cannot show (BZ2). One on/off light_v2 proxy (5001),
-- lit while the fan blows a Breeze; a tap starts or ends it. It never speaks
-- to the fan itself: it is bound to the Modern Forms Fan device (consumer
-- binding 1, class MODERNFORMS_BREEZE, the fan's provider binding 400), sends
-- that device MF_BREEZE_SET, MF_BREEZE_TOGGLE and MF_BREEZE_HELLO with
-- C4:SendToDevice, and hears MF_BREEZE_STATE back through ExecuteCommand.
--
-- The tile shows only what the fan device confirms: a tap sends a message and
-- reports nothing; LIGHT_BRIGHTNESS_CHANGED (100 while Breeze blows, 0
-- otherwise) goes out from a state message alone, when the level changes, at
-- the first state after a start, when the fan comes back online and on the
-- proxy's SYNCHRONIZE. A switch needs no LIGHT_BRIGHTNESS_CHANGING [verified:
-- LV2 35/_10.2-LIGHTBRIGHTNESSCHANGED.md, usage note]. ONLINE_CHANGED is false
-- while unbound or while the fan device says AVAILABLE "0" [LV2
-- 35/_15-ONLINECHANGED.md: the proxy starts online and disables its controls
-- while offline]; while bound and not yet answered, nothing is said.
--
-- Built on common/ as the fan driver is: the entry points through
-- common/dispatch.lua, the log through common/log.lua, the light_v2 plumbing
-- (Driver Version and Debug Mode rows, proxy notifies, the buffer before late
-- init, OnBindingChanged before late init) through common/device.lua. What
-- that module's port left out, because the fan driver has no binding to
-- another driver, is written here after the Hue project's device drivers
-- (corytron/c4-hue-driver src/common/device.lua, the owner's own code): the
-- provider lookup that takes 0 for unbound, the protected SendToDevice, and
-- the binding re-check after a Director restart.
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

local LOG_PREFIX = "Modern Forms Breeze"

-- driver.xml: the light_v2 proxy and the binding to the fan device.
local PROXY_BINDING = 5001
local FAN_BINDING = 1

-- Rows stay at 70 characters or fewer (the fan driver's rule, Composer clips
-- near 75); a long fan name is cut to fit.
local ROW_MAX = 70

-- After a Director restart the binding can be invisible to
-- GetBoundProviderDevice at late init although Composer shows it, and no
-- OnBindingChanged follows [hardware 2026-10-22, the Hue project's
-- docs/keypad-design.md]: while unbound the device looks again after these
-- delays (60 s in all), then waits for a binding.
local RECHECK_MS = { 5000, 10000, 15000, 30000 }

-- Status (docs/breeze-design.md section 4); %s is the fan item's name.
local TEXTS = {
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
	noun = "Breeze switch",
	proxy_binding = PROXY_BINDING,
})
local prop = dev.prop

local provider = nil      -- the bound fan device's id, or nil
local state = nil         -- { blows, available, fan, has_breeze }: the last MF_BREEZE_STATE from it
local level_sent = nil    -- the LIGHT_BRIGHTNESS_CURRENT last reported (100 or 0), nil before any
local online_sent = nil   -- the ONLINE_CHANGED STATE last reported, nil before any
local status_shown = nil  -- the Status row as last written
local recheck_timer = nil -- the pending binding re-check

-- Texts -------------------------------------------------------------------------

-- A name as the fan device sent it: no control characters, blanks trimmed;
-- nil when nothing is left.
local function clean_name(text)
	text = device.text(text)
	if not text then
		return nil
	end
	text = text:gsub("%c", ""):match("^%s*(.-)%s*$")
	return text ~= "" and text or nil
end

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
	if state.available then
		return fit(state.blows and TEXTS.on or TEXTS.off, name)
	end
	-- AVAILABLE "0" means no Breeze or a fan device that is not online; only
	-- the optional HAS_BREEZE "0" tells the first apart.
	if state.has_breeze == false then
		return fit(TEXTS.no_breeze, name)
	end
	return fit(TEXTS.waiting, name)
end

local function refresh_status()
	local text = status_text()
	if text ~= status_shown then
		status_shown = text
		prop("Status", text)
	end
end

-- The tile -----------------------------------------------------------------------

-- 100 while Breeze blows, 0 otherwise; nil until the fan device has said.
local function level_now()
	if not state then
		return nil
	end
	return state.blows and 100 or 0
end

-- false while unbound, the fan device's AVAILABLE once it has spoken, nil in
-- between (bound, not yet answered: the proxy keeps what it has).
local function online_now()
	if not provider then
		return false
	end
	if not state then
		return nil
	end
	return state.available
end

local function report_level(force)
	local level = level_now()
	if level == nil or (level == level_sent and not force) then
		return
	end
	level_sent = level
	dev.notify("LIGHT_BRIGHTNESS_CHANGED", { LIGHT_BRIGHTNESS_CURRENT = level })
end

local function report_online(force)
	local online = online_now()
	if online == nil or (online == online_sent and not force) then
		return
	end
	online_sent = online
	dev.notify("ONLINE_CHANGED", { STATE = online })
end

-- The proxy and Status after anything changed. A tile coming online hears
-- ONLINE_CHANGED first and then its level again (LV2 35/_10.2: the level is
-- sent when the hardware comes online); otherwise the level goes first.
local function show()
	local was = online_sent
	if online_now() == true and was ~= true then
		report_online(false)
		report_level(was == false)
	else
		report_level(false)
		report_online(false)
	end
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
-- dropped until the hello is answered.
local function connect(id)
	cancel_recheck()
	if id ~= provider then
		provider = id
		state = nil
	end
	hello()
	show()
end

local function disconnect()
	cancel_recheck()
	provider = nil
	state = nil
	show()
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

local function schedule_recheck(attempt)
	cancel_recheck()
	local delay = RECHECK_MS[attempt]
	if not delay then
		return log.info("not bound to a Modern Forms Fan 60 s after the start; waiting for a binding")
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

-- Tile commands ------------------------------------------------------------------
-- Every command becomes a message to the fan device, which starts or ends
-- Breeze (and refuses, with its own Last Action, what it cannot do). Unbound,
-- it is refused here, and Status already says why.

local function refuse(command)
	log.warn("%s refused: not connected to a Modern Forms Fan", command)
	refresh_status()
end

local function want(on, command)
	if not ensure_bound() then
		return refuse(command)
	end
	send("MF_BREEZE_SET", { ON = on and "1" or "0" })
end

-- From the tile's state; while the fan device has not said, it decides.
local function toggle(command)
	if not ensure_bound() then
		return refuse(command)
	end
	if state then
		send("MF_BREEZE_SET", { ON = state.blows and "0" or "1" })
	else
		send("MF_BREEZE_TOGGLE", {})
	end
end

-- A level is a switch position: above 0 on, 0 off.
local function target(value, command)
	local level = tonumber(value)
	if not level then
		return log.warn("%s without a level ignored", command)
	end
	want(level > 0, command)
end

-- The proxy's commands on its binding (common/dispatch.binding: device.lua
-- registers BUTTON_ACTION there, so the table shadows the fallback). One
-- that arrives before late init waits for it.
local function on_proxy(command, handler)
	local waiting = dev.after_late_init(command, handler)
	dispatch.binding(PROXY_BINDING)[command] = function(_, params)
		return waiting(params or {})
	end
end

on_proxy("ON", function() want(true, "ON") end)
on_proxy("OFF", function() want(false, "OFF") end)
on_proxy("TOGGLE", function() toggle("TOGGLE") end)
-- With supports_target the proxy sends LIGHT_BRIGHTNESS_TARGET [LV2
-- 10/_1.5-SETBRIGHTNESSTARGET.md]; the legacy commands carry LEVEL.
on_proxy("SET_BRIGHTNESS_TARGET", function(params)
	target(params.LIGHT_BRIGHTNESS_TARGET or params["LIGHT BRIGHTNESS TARGET"], "SET_BRIGHTNESS_TARGET")
end)
on_proxy("SET_LEVEL", function(params) target(params.LEVEL, "SET_LEVEL") end)
on_proxy("RAMP_TO_LEVEL", function(params) target(params.LEVEL, "RAMP_TO_LEVEL") end)
-- The proxy asks for the state after Director starts or a Navigator connects.
on_proxy("SYNCHRONIZE", function()
	report_online(true)
	report_level(true)
end)

-- The light_v2 proxy's own button route (BUTTON_ACTION, common/device.lua):
-- top on, bottom off, toggle toggles; a switch has nothing to dim, so a hold
-- does nothing. No Button Links are declared, so it is not expected to arrive.
dev.is_on = function()
	if not state then
		return nil
	end
	return state.blows
end
dev.on_click = function(button)
	if button == device.BUTTON_TOP then
		want(true, "BUTTON_ACTION")
	elseif button == device.BUTTON_BOTTOM then
		want(false, "BUTTON_ACTION")
	else
		toggle("BUTTON_ACTION")
	end
end
dev.on_hold = function()
	log.debug("hold on a Breeze switch does nothing")
end
dev.on_finish = function() end

-- From the fan device (ExecuteCommand) ---------------------------------------------

-- docs/breeze-design.md section 4: BLOWS "1" while the fan blows a Breeze,
-- AVAILABLE "0" without Breeze or while the fan device is not online, FAN the
-- fan item's name; HAS_BREEZE ("1" or "0", optional) says whether the fan has
-- Breeze at all. Only a change reaches the proxy.
dispatch.commands["MF_BREEZE_STATE"] = dev.after_late_init("MF_BREEZE_STATE", function(params)
	params = params or {}
	local blows, available = device.to_bool(params.BLOWS), device.to_bool(params.AVAILABLE)
	if blows == nil or available == nil then
		return log.warn("MF_BREEZE_STATE ignored: BLOWS %s, AVAILABLE %s", tostring(params.BLOWS),
			tostring(params.AVAILABLE))
	end
	if not ensure_bound() then
		return log.debug("MF_BREEZE_STATE ignored: not bound to a Modern Forms Fan")
	end
	state = {
		blows = blows,
		available = available,
		fan = clean_name(params.FAN),
		has_breeze = device.to_bool(params.HAS_BREEZE),
	}
	show()
end)

-- Lifecycle ------------------------------------------------------------------------

dispatch.install(_G)

-- GetBoundProviderDevice and SendToDevice are not for OnDriverInit [API
-- 32/_4, 32/_19]: everything starts at late init.
function OnDriverInit()
end

function OnDriverLateInit()
	dispatch.replay_properties(Properties)
	dev.show_driver_version(1)
	cancel_recheck()
	-- A start: the proxy hears everything again.
	provider, state = bound_fan(), nil
	level_sent, online_sent, status_shown = nil, nil, nil
	show()
	-- State messages that came first, then the hello, which the fan device
	-- answers with its state.
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
-- binding yet.
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
