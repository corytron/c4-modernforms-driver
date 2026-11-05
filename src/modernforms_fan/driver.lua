-- Modern Forms Fan driver (docs/v1-design.md): the coordinator. It builds the
-- modules of fan/ and common/ (the wire and the transport, the state model,
-- the fan proxy, the fan links, the light, Find Fans, the Migration Report),
-- hands each what touches Director as arguments, and wires the DriverWorks
-- entry points, the properties, the actions, the events and the Online
-- variable to them. Nothing here decides what the fan does: the model does
-- (sections 3, 4 and 6); the texts are fan/texts.lua's (section 7).
--
-- Wired the way the owner's Hue drivers are (corytron/c4-hue-driver): the
-- entry points go through common/dispatch.lua, the log through common/log.lua,
-- the light_v2 plumbing through common/device.lua, and the dev loop hooks in
-- as in the Hue Bridge driver: a guarded require of common/devloop.lua, which
-- only a dev build ships, a Dev Server property handler, and the loop started
-- last in late init. The loop's reload runs OnDriverDestroyed, this file again,
-- then OnDriverInit and OnDriverLateInit("DIT_UPDATING"), so all of this may
-- run twice in one Lua state: handlers are registered at load into the fresh
-- dispatch module, and every timer armed here is cancelled in
-- OnDriverDestroyed.
--
-- UpdateProperty, SetTimer and SendToProxy are not safe before
-- OnDriverLateInit [verified: API 22/_25.2], so the objects are built at load
-- but start nothing: messages that arrive first wait in dev.after_late_init,
-- and the model's first request goes out from late init.

local log = require("common.log")
local dispatch = require("common.dispatch")
local device = require("common.device")
local wire = require("fan.wire")
local transport_mod = require("fan.transport")
local model_mod = require("fan.model")
local texts = require("fan.texts")
local fanproxy_mod = require("fan.fanproxy")
local links_mod = require("fan.links")
local light_mod = require("fan.light")
local discovery_mod = require("fan.discovery")
local migration_mod = require("fan.migration")

-- Prefix of every line this driver logs.
local LOG_PREFIX = "Modern Forms Fan"
log.set_prefix(LOG_PREFIX)

-- Section 2.2 and 2.4: the proxies' bindings, Find Fans' dynamic binding (V5a),
-- the two events (section 2.7) and the light's and the fan's links.
local FAN_BINDING, LIGHT_BINDING = 5001, 5002
local FIND_BINDING, MDNS_PORT, MDNS_GROUP = 6001, 5353, "224.0.0.251"
local EVENT_FAN_OFFLINE, EVENT_FAN_ONLINE = 1, 2
local LIGHT_LINKS = { [200] = true, [201] = true, [202] = true }
local FAN_LINKS = {}
for id = 300, 308 do
	FAN_LINKS[id] = true
end
local PICK_ROW = "Pick a fan" -- the first row of Found Fans: no pick (section 3.5)

-- Dev builds only (tools/build.sh --dev ships common/devloop.lua and
-- fan/devcmds.lua): the driver fetches its code from a server on the LAN and
-- reloads itself. See docs/dev-loop.md. Release builds have no such modules,
-- so both are nil there.
local function optional(name)
	local ok, module = pcall(require, name)
	if ok then
		return module
	end
	-- Absent in release builds (expected); anything else is a real error that
	-- must be visible. A missing module reads "not found" under busted and
	-- "An unknown error occurred" on the controller [hardware 2026-10-24, the
	-- Hue project].
	local reason = tostring(module):lower()
	if not (reason:find("not found", 1, true) or reason:find("unknown error", 1, true)) then
		print("[ERROR] " .. LOG_PREFIX .. ": " .. name .. " failed to load: " .. tostring(module))
	end
	return nil
end
local devloop = optional("common.devloop")
local devcmds = optional("fan.devcmds")

-- Director -------------------------------------------------------------------

local function now_ms()
	return C4:GetTime()
end

-- A timer the modules can cancel; its callback takes no arguments.
local function timer(ms, callback)
	return C4:SetTimer(ms, function()
		callback()
	end)
end

-- A value never written reads as no value at all on the house (HUE #298), so
-- the call is wrapped in parentheses: exactly one result.
local store = {
	get = function(key)
		return (C4:PersistGetValue(key))
	end,
	set = function(key, value)
		C4:PersistSetValue(key, value)
	end,
}

local dev = device.new({
	prefix = LOG_PREFIX,
	noun = "light",
	settings = { "preset", "hold_up", "hold_down" },
	proxy_binding = LIGHT_BINDING,
})
local prop = dev.prop

-- The handler of one proxy command or link command; a message that arrives
-- before late init waits for it (GET_CURRENT_STATE comes at the add, and
-- DESIGNATE_PRESET persists).
local function on(binding, command, handler)
	local waiting = dev.after_late_init(command .. " on " .. tostring(binding), function(params)
		return handler(binding, params)
	end)
	dispatch.binding(binding)[command] = function(_, params)
		return waiting(params)
	end
end

local started = false -- late init has started the model
local os_info = nil -- C4:GetVersionInfo(), read at late init (S14)

-- Rows: written only when the text changes, so Composer's rows are not
-- rewritten by every poll.
local rows = {}
local function set_row(name, text)
	text = text or ""
	if rows[name] ~= text then
		rows[name] = text
		prop(name, text)
	end
end

local function result(key, args)
	dev.result(texts.result(key, args))
end

-- The modules ------------------------------------------------------------------

local model, fan, links, light, discovery, migration
local keypad_items = {} -- the Keypad Links list as written; a pick snaps back to its first row
local found = { items = {}, list = {} } -- the last Find Fans, row by row

local function refresh_status()
	if not model then
		return
	end
	local view = model:status_view()
	view.find_fans = true
	view.os = os_info
	set_row("Status", texts.status(view))
end

local function show_identity(pin, info)
	set_row("Fan ID", texts.fan_id(pin))
	set_row("Fan Model", texts.fan_model(pin, info, info and info.has_wind))
	set_row("Firmware", texts.firmware(info))
end

-- The Online variable and the condition share this value; the model persists
-- it (mf_online) itself.
local online_now = false
local function set_online_variable(online)
	online_now = online and true or false
	C4:SetVariable("Online", online_now and "1" or "0")
end

local last_seen_at = nil
local listener = {}

function listener.settled(group, st, why)
	fan:settled(group, st, why)
	if group == "light" then
		light:settled(st, why)
	end
	refresh_status()
end

function listener.idle(group, st)
	if group == "light" then
		light:idle(st)
	end
end

function listener.shown(shown)
	links:shown(shown)
	light:shown(shown)
	refresh_status()
end

-- Section 6.1: the phase carries what the driver applies (detail.online for
-- the Online variable and the light, detail.event for the two events).
function listener.phase(phase, detail, old)
	light:phase(phase, detail)
	if detail and detail.online ~= nil then
		set_online_variable(detail.online)
	end
	if detail and detail.event == "offline" then
		C4:FireEventByID(EVENT_FAN_OFFLINE)
	elseif detail and detail.event == "online" then
		C4:FireEventByID(EVENT_FAN_ONLINE)
	end
	refresh_status()
	log.debug("phase %s -> %s", tostring(old), tostring(phase))
end

function listener.info(pin, info)
	show_identity(pin, info)
	refresh_status()
end

-- Last Seen is written at most every 10 s (section 7.3).
function listener.seen(at_s, ms)
	if last_seen_at == nil or at_s - last_seen_at >= 10 then
		last_seen_at = at_s
		set_row("Last Seen", texts.last_seen(at_s, ms))
	end
end

function listener.outside(_, user_data, at_s)
	set_row("Last Change By", texts.change_by(user_data, at_s, os.time()))
end

function listener.automations(st)
	local pin = model:identity()
	set_row("Fan Automations", texts.automations(st, pin and pin.generation))
end

function listener.result(key, args)
	result(key, args)
end

local transport = transport_mod.new({
	now = now_ms,
	timer = timer,
	url = function()
		return C4:url()
	end,
	on_idle = function()
		if model then
			model:on_idle()
		end
	end,
	log = log,
})

model = model_mod.new({
	transport = transport,
	wire = wire,
	now = now_ms,
	timer = timer,
	clock = os.time,
	store = store,
	log = log,
	listener = listener,
})

-- Hardware K11 (2026-10-27): the fan runs in reverse and keeps answering, so
-- the capability is declared (driver.xml can_reverse True).
fan = fanproxy_mod.new({
	model = model,
	on = on,
	send = function(command, params)
		C4:SendToProxy(FAN_BINDING, command, params, "NOTIFY")
	end,
	store = store,
	can_reverse = true,
	log = log,
})

-- Keypad Links (section 7.3): the property list, the first row the pick.
local function write_keypad_links(items)
	keypad_items = items
	C4:UpdatePropertyList("Keypad Links", table.concat(items, ","), items[1])
end

links = links_mod.new({
	model = model,
	fan = fan,
	on = on,
	send = function(binding, command, params, kind)
		C4:SendToProxy(binding, command, params, kind)
	end,
	now = now_ms,
	timer = timer,
	bound = function(link)
		return C4:GetBoundConsumerDevices(C4:GetDeviceID(), link)
	end,
	display = function(id)
		return C4:GetDeviceDisplayName(id)
	end,
	list = write_keypad_links,
	log = log,
})

light = light_mod.new({
	model = model,
	dev = dev,
	on = on,
	now = now_ms,
	timer = timer,
	log = log,
})

-- Find Fans (V5a, K10): a dynamic binding to the mDNS group, created once.
local find_connection = false
discovery = discovery_mod.new({
	open = function()
		local ok, err = pcall(function()
			if not find_connection then
				C4:CreateNetworkConnection(FIND_BINDING, MDNS_GROUP)
				find_connection = true
			end
			C4:NetConnect(FIND_BINDING, MDNS_PORT, "MULTICAST")
		end)
		if not ok then
			log.warn("Find Fans could not open its connection: %s", tostring(err))
		end
		return ok
	end,
	send = function(bytes)
		return (pcall(C4.SendToNetwork, C4, FIND_BINDING, MDNS_PORT, bytes))
	end,
	close = function()
		pcall(C4.NetDisconnect, C4, FIND_BINDING, MDNS_PORT)
	end,
	timer = timer,
	log = log,
})

-- The Migration Report (migration-design.md section 4): reads the project only
-- when its action is clicked.
migration = migration_mod.new({
	get_devices = function()
		return C4:GetDevices({})
	end,
	get_all_code_items = function()
		return C4:GetAllCodeItems()
	end,
	get_device_variables = function(id)
		return C4:GetDeviceVariables(id)
	end,
	get_bindings_by_device = function(id)
		return C4:GetBindingsByDevice(id)
	end,
	get_bound_consumer_devices = function(id, link)
		return C4:GetBoundConsumerDevices(id, link)
	end,
	get_device_display_name = function(id)
		return C4:GetDeviceDisplayName(id)
	end,
	get_device_id = function()
		return C4:GetDeviceID()
	end,
	get_proxy_devices = function()
		return C4:GetProxyDevices()
	end,
	property = function(name)
		return Properties[name]
	end,
	now = os.time,
	log = log,
	store = store,
	-- The shown row moves only with both calls (the Hue project, 2026-10).
	update_list = function(items, selected)
		C4:UpdatePropertyList("Migration", table.concat(items, ","), selected)
		C4:UpdateProperty("Migration", selected)
	end,
})

-- Properties ---------------------------------------------------------------------

local function trimmed(value)
	return (value or ""):match("^%s*(.-)%s*$")
end

-- Fan Address: a new epoch and a contact, or S1 and S3 (section 3.5). Late init
-- reads the value itself, so an edit before it is ignored.
dispatch.properties["Fan_Address"] = function(value)
	if not started then
		return
	end
	model:set_address(value)
	refresh_status()
end

dispatch.properties["Poll_Interval_(s)"] = function(value)
	local seconds = tonumber(value)
	if seconds then
		model:set_poll_interval(seconds)
	end
end

-- "Speed 3" -> 3, "No other speed" -> nil (V26).
for speed = 1, 6 do
	dispatch.properties["Speed_" .. speed .. "_Link_Also_Lit_At"] = function(value)
		local also = tonumber(tostring(value):match("^Speed (%d)$"))
		links:set_also(speed, also)
	end
end

-- Keypad Links lists; a pick changes nothing and snaps back to the first row.
dispatch.properties["Keypad_Links"] = function()
	if keypad_items[1] then
		C4:UpdateProperty("Keypad Links", keypad_items[1])
	end
end

dispatch.properties["Migration"] = function()
	migration:snap_back()
end

dispatch.properties["Stock_Device"] = function()
	migration:stock_device_changed()
end

-- Found Fans: a pick waits for Use Selected Fan; nothing to do here.

-- Dev loop -----------------------------------------------------------------------

if devloop then
	dispatch.properties["Dev_Server"] = function(value)
		local host = trimmed(value)
		if host == "" then
			devloop.stop()
		elseif started then
			log.always("dev loop: starting against %s", host)
			devloop.start(host)
		end
	end
end

local stop_devcmds = nil
if devloop and devcmds then
	local commands, stop = devcmds.new({
		model = model,
		fan = fan,
		links = links,
		light = light,
		prop = prop,
		inject = function(binding, command, params)
			return ReceivedFromProxy(binding, command, params)
		end,
		request = function(req, callback)
			return model:request(req, callback)
		end,
		log = log,
	})
	stop_devcmds = stop
	devloop.set_signed_commands(commands)
	devloop.set_redactor(devcmds.redactor(function()
		return model:identity()
	end))
end

-- Actions ------------------------------------------------------------------------

-- Find Fans: one mDNS query, 3 s of answers, the list into Found Fans.
dispatch.commands["Find_Fans"] = function()
	discovery:find(function(list, err)
		if err then
			result("find_failed")
			return
		end
		list = list or {}
		local items = texts.found_fans(list, model:identity())
		found = { items = items, list = list }
		local shown = { PICK_ROW }
		for _, item in ipairs(items) do
			shown[#shown + 1] = item
		end
		C4:UpdatePropertyList("Found Fans", table.concat(shown, ","), PICK_ROW)
		if #list == 0 then
			result("found_none")
		else
			result("found", { count = #list, list = list })
		end
	end)
end

-- The fan the owner picked in Found Fans, or nil (the placeholder row, a pick
-- from an older list).
local function picked_fan()
	local pick = Properties["Found Fans"]
	for index, item in ipairs(found.items) do
		if item == pick then
			return found.list[index]
		end
	end
	return nil
end

local function clear_pick()
	C4:UpdateProperty("Found Fans", PICK_ROW)
end

-- Use Selected Fan: the pick, else Fan Address (section 3.5).
dispatch.commands["Use_Selected_Fan"] = function()
	local pick = picked_fan()
	local address, mac
	if pick then
		address, mac = pick.address, pick.mac
	else
		address = trimmed(Properties["Fan Address"])
		if address == "" then
			address = nil
		end
	end
	if not address then
		result("nothing_to_use", { find_fans = true })
		return
	end
	model:use_fan(address, mac, function(key, args)
		clear_pick()
		if key == "moved" or key == "now_using" then
			prop("Fan Address", address)
		end
		result(key, args)
		refresh_status()
	end)
end

dispatch.commands["Reboot_Fan"] = function()
	model:reboot(function(key, args)
		result(key, args)
		refresh_status()
	end)
end

dispatch.commands["Turn_Off_Away_Mode"] = function()
	model:turn_off("away", function(key, args)
		result(key, args)
	end)
end

dispatch.commands["Turn_Off_Adaptive_Learning"] = function()
	model:turn_off("learning", function(key, args)
		result(key, args)
	end)
end

dispatch.commands["Migration_Report"] = function()
	migration:run()
	dev.result(migration:verdict())
end

-- Lifecycle ----------------------------------------------------------------------

dispatch.install(_G)

-- Section 2.7: the Online variable, added in OnDriverInit in this order and
-- never reordered or renamed; its value is the persisted one, so the first
-- difference after a restart reads as a change (D9).
function OnDriverInit()
	online_now = (C4:PersistGetValue("mf_online")) == true
	C4:AddVariable("Online", online_now and "1" or "0", "BOOL", true)
end

-- The identity rows come from the restored model state until the first answer
-- arrives.
local function show_restored()
	local pin, info = model:identity(), model:info()
	if pin then
		show_identity(pin, info)
	end
end

function OnDriverLateInit()
	dev.load_settings()
	dev.load_colors()
	dispatch.replay_properties(Properties)
	dev.show_driver_version(1)
	os_info = C4:GetVersionInfo()
	-- The proxy's preset before the model's first answers can tell it.
	fan:late_init()
	model:start(trimmed(Properties["Fan Address"]), texts.parse_fan_id(Properties["Fan ID"]))
	started = true
	show_restored()
	migration:restore()
	refresh_status()
	-- Buffered proxy messages (GET_CURRENT_STATE at the add), then the links'
	-- reads of their keypads, before the binding changes that came early.
	dev.late_init()
	links:late_init()
	-- Dev builds: the dev loop starts last, so a reload pushed through it sees
	-- a fully initialised driver.
	if devloop then
		local host = trimmed(Properties["Dev Server"])
		if host ~= "" then
			devloop.start(host)
		end
	end
	dev.replay_bindings()
end

-- A Button Link's binding changes (a keypad button bound or unbound): the
-- links' bookkeeping, and the light's links get their LED state at once. The
-- proxies' bindings are not links. A call before late init waits for it
-- (common/device.lua).
OnBindingChanged = dev.binding_changed(function(binding, _, bound, other_device, other_binding)
	if FAN_LINKS[binding] or LIGHT_LINKS[binding] then
		links:binding_changed(binding, bound, other_device, other_binding)
	end
	if LIGHT_LINKS[binding] and bound then
		dev.update_leds(true)
	end
end)

-- Section 2.7: the one condition, "Fan is online". With a VALUE (the text
-- picked) it compares; without, it answers the state itself.
function TestCondition(name, params)
	if name ~= "BOOL_ONLINE" then
		return false
	end
	params = params or {}
	local wanted = params.VALUE
	if wanted == nil then
		return online_now
	end
	local equal = online_now == (wanted == "True")
	if params.LOGIC == "NOT_EQUAL" then
		return not equal
	end
	return equal
end

-- Find Fans' answers: the dynamic binding's datagrams.
function ReceivedFromNetwork(binding, port, data, from)
	if binding == FIND_BINDING then
		discovery:received(binding, port, data, from)
	end
end

-- Composer deletes the device: nothing to tell the fan, which keeps its state
-- (section 8: delete and re-add loses links and programming, the manual says
-- never to do it).
function OnDriverRemovedFromProject()
	log.always("removed from the project")
end

-- The dev loop keeps running: its reload calls this before it loads the new
-- code, and its state outlives the reload; Director kills every timer of a
-- driver that is really destroyed [verified: API 22/_24].
function OnDriverDestroyed()
	started = false
	if stop_devcmds then
		stop_devcmds()
	end
	discovery:stop()
	links:stop()
	light:stop()
	model:stop()
	transport:stop()
	dev.cancel_timers()
end
