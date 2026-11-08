-- Modern Forms Fan driver (docs/v1-design.md): the coordinator. It builds the
-- modules of fan/ and common/ (the wire and the transport, the state model,
-- the fan proxy, the fan links, the light, the fan search and its list, the
-- item names),
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
local names = require("fan.names")
local rename_mod = require("fan.rename")
local follow_mod = require("fan.follow")
local search_mod = require("fan.search")
local found_mod = require("fan.found")
local breeze_mod = require("fan.breeze")

-- Prefix of every line this driver logs.
local LOG_PREFIX = "Modern Forms Fan"
log.set_prefix(LOG_PREFIX)

-- Section 2.2 and 2.4: the proxies' bindings, the search's dynamic binding (V5a),
-- the two events (section 2.7) and the light's and the fan's links.
local FAN_BINDING, LIGHT_BINDING = 5001, 5002
local FIND_BINDING, MDNS_PORT, MDNS_GROUP = 6001, 5353, "224.0.0.251"
-- breeze-design BZ2 (#111): the companion's binding and its class; BF-D7 (#121):
-- the Breeze fan's package, and the driver name of 1.2's light-type switch, which
-- GetBoundConsumerDevices reports for a device still bound [verified: hardware,
-- the Hue project; API 32/_3].
local BREEZE_BINDING, BREEZE_CLASS, BREEZE_DRIVER = 400, "MODERNFORMS_BREEZE", "modernforms_breeze_fan.c4z"
local OLD_BREEZE_NAME = "Modern Forms Breeze"
local EVENT_FAN_OFFLINE, EVENT_FAN_ONLINE = 1, 2
local LIGHT_LINKS = { [200] = true, [201] = true, [202] = true }
local FAN_LINKS = { [311] = true } -- 311 Fan Breeze (breeze-design BZ4)
for id = 300, 308 do
	FAN_LINKS[id] = true
end

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
-- SetTimer's delay must be greater than 0 [API 34_timer/_1], so a due-now
-- timer waits 1 ms.
local function timer(ms, callback)
	return C4:SetTimer(math.max(1, math.floor(ms)), function()
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
		prop(name, text)
		rows[name] = text
	end
end

-- A dynamic list: the items and the row shown. On the house the list's default
-- alone did not move the shown row; UpdateProperty beside it did (the Hue
-- project, 2026-10), so every list is written with both.
local function prop_list(name, items, selected)
	C4:UpdatePropertyList(name, table.concat(items, ","), selected)
	C4:UpdateProperty(name, selected)
end

-- Last Action keeps the full text; the always-on log carries only the last four
-- hex digits of a client id or MAC (section 3.7).
-- shown_count counts the writes, so a line written later (the rename suffix)
-- can tell whether anything else wrote Last Action in between (review of #37).
local shown_count = 0
local function show_result(text)
	shown_count = shown_count + 1
	log.always("%s", (text:gsub("%x%x%x%x%x%x%x%x(%x%x%x%x)", "...%1")))
	prop("Last Action", text)
end

local function result(key, args)
	show_result(texts.result(key, args))
end

-- Linear: "^%s*(.-)%s*$" rescans a long run of inner blanks at every step (#49).
local function trimmed(value)
	local text = value or ""
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

-- The modules ------------------------------------------------------------------

local model, fan, links, light, discovery, names_job, follower, search, found_list, breeze
local keypad_items = {} -- the Keypad Links list as written; a pick snaps back to its first row
-- Found Fans as last written (auto-discovery-design 3): the rows, the entry
-- behind each item row, and the text the row was written with.
local found_shown = { items = {}, entries = {}, key = nil }
local draw_found -- writes Found Fans; set once the list and the scheduler exist

local function refresh_status()
	if not model then
		return
	end
	local view = model:status_view()
	-- S1 rather than S2 when no search can help: the list is failing, or a pinned
	-- device's empty Fan Address stops the search (auto-discovery-design AD5).
	view.failing = (found_list ~= nil and found_list:failing())
		or (model:identity() ~= nil and trimmed(Properties["Fan Address"]) == "")
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
	if breeze and (group == "fan" or group == "breeze") then
		breeze:settled(group, st, why)
	end
	refresh_status()
end

function listener.idle(group, st)
	-- BF-D13 (#121): what the fan proxy held half way goes out when nothing follows.
	fan:idle(group, st)
	if breeze then
		breeze:idle(group)
	end
	if group == "light" then
		light:idle(st)
	end
end

function listener.shown(shown)
	if breeze then
		breeze:shown(shown) -- first: link 311's LED reads it (BZ4)
	end
	links:shown(shown)
	light:shown()
	refresh_status()
end

-- Section 6.1: the phase carries what the driver applies (detail.online for
-- the Online variable and the light, detail.event for the two events).
function listener.phase(phase, detail, old)
	-- The follower first (address-follow-design F2, F5), so a fault further on
	-- cannot keep it from arming: online is the pinned fan answering at Fan
	-- Address, the contact that ends a pending typed address.
	if follower then
		if phase == "online" then
			follower:contact()
		end
		follower:phase_changed(phase)
	end
	-- The search's mode follows the phase and the follower (auto-discovery-design 2).
	if search and started then
		search:changed()
	end
	light:phase(phase, detail)
	if breeze then
		breeze:phase(phase)
	end
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
	if started and draw_found then
		draw_found()
	end
	refresh_status()
end

-- Last Seen is written at most every 10 s (section 7.3).
function listener.seen(at_s, ms)
	if last_seen_at == nil or at_s < last_seen_at or at_s - last_seen_at >= 10 then
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
	prop_list("Keypad Links", items, items[1])
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
	-- Link 311, Fan Breeze (breeze-design BZ4): a press toggles, the LED shows Breeze.
	breeze_toggle = function()
		if breeze then
			breeze:toggle()
		end
	end,
	breeze_blows = function()
		return breeze ~= nil and breeze:blows_shown()
	end,
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

-- The search (V5a, K10, auto-discovery-design): a dynamic binding to the mDNS
-- group, created once. Every closed window, the scheduler's or the follower's,
-- feeds the list (on_window).
local on_window -- set below, once the list exists
local find_connection = false
discovery = discovery_mod.new({
	open = function()
		local ok, err = pcall(function()
			if not find_connection then
				-- The binding survives a dev reload of this file and cannot be
				-- removed, so a second create is allowed to fail.
				pcall(C4.CreateNetworkConnection, C4, FIND_BINDING, MDNS_GROUP)
				find_connection = true
			end
			C4:NetConnect(FIND_BINDING, MDNS_PORT, "MULTICAST")
		end)
		if not ok then
			log.debug("Search: could not open the connection: %s", tostring(err)) -- warned once per streak by the list
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
	now = now_ms,
	on_window = function(list, err, heard)
		if on_window then
			on_window(list, err, heard)
		end
	end,
	log = log,
})

-- Following the pinned fan to a new address (address-follow-design, #39):
-- search windows for the pinned MAC while the fan is not at Fan Address,
-- one read-only check of what answers, then the model moves.
follower = follow_mod.new({
	find = function(cb)
		return discovery:find(cb)
	end,
	candidates = discovery_mod.candidates,
	follow = function(address, mac12, cb)
		model:follow(address, mac12, cb)
	end,
	phase = function()
		return model:phase()
	end,
	identity = function()
		return model:identity()
	end,
	address = function()
		return trimmed(Properties["Fan Address"])
	end,
	enabled = function()
		return Properties["Follow Address Changes"] ~= "Off"
	end,
	timer = timer,
	now = now_ms,
	-- Read at the first arm, after late init: never at load (API 22/_11). The
	-- follower draws its jitter from a generator of its own, seeded from it.
	seed = function()
		return C4:GetDeviceID()
	end,
	on_followed = function(address, was)
		prop("Fan Address", address)
		result("followed", { pin = model:identity(), address = address, was = was })
		refresh_status()
	end,
	on_refused = function()
		result("follow_refused", { pin = model:identity() })
	end,
	log = log,
})

-- The fans heard, kept across windows (auto-discovery-design 3).
found_list = found_mod.new({
	usable = discovery_mod.usable,
	now = function()
		return now_ms() / 1000
	end,
	log = log,
})

-- The scheduler's mode (auto-discovery-design 2), in the contract's order. A
-- pinned fan that is away is the follower's (standby) or, with following Off or
-- a typed address waiting, nobody's (quiet: Off keeps meaning no windows, F7).
local function search_mode()
	local pin = model:identity()
	if pin and trimmed(Properties["Fan Address"]) == "" then
		return "stopped"
	end
	local state = follower:state()
	if type(state) == "string" and state:find("^armed") then
		return "standby"
	end
	if not pin or model:phase() == "unset" then
		return "seek"
	end
	return "quiet"
end

-- Writes Found Fans when its text changed, or always with force (a pick snaps
-- back: Composer then shows the picked row, whatever was written last). The
-- value is the waiting pick's row, else the summary.
draw_found = function(force)
	if not found_list then
		return
	end
	local pin = model:identity()
	local state = "listed"
	if search_mode() == "stopped" then
		state = "stopped"
	elseif not found_list:heard_once() then
		state = "looking"
	elseif found_list:failing() then
		state = "failing"
	end
	local entries = found_list:entries(pin and pin.mac or nil)
	local summary, items = texts.found_rows({
		state = state, pinned = pin ~= nil, entries = entries, info = model:info(),
	})
	items = items or {}
	local shown = { summary }
	local behind = {}
	local overflow = #entries > texts.MAX_FOUND
	local kept = found_list:kept()
	local value = summary
	for index, item in ipairs(items) do
		shown[#shown + 1] = item
		local entry = entries[index]
		if entry and not (overflow and index == #items) then
			behind[item] = entry
			if kept and entry.key == kept.key then
				value = item
			end
		end
	end
	local key = table.concat(shown, "\n") .. "\n=" .. value
	if force or key ~= found_shown.key then
		prop_list("Found Fans", shown, value)
		found_shown = { items = shown, entries = behind, key = key }
	end
end

on_window = function(_, err, heard)
	found_list:window(heard, err)
	draw_found()
	refresh_status()
end

search = search_mod.new({
	find = function(cb)
		return discovery:find(cb)
	end,
	last_closed = function()
		return discovery:last_closed()
	end,
	mode = search_mode,
	timer = timer,
	now = now_ms,
	-- Read at the first plan, after late init: never at load (API 22/_11).
	seed = function()
		return C4:GetDeviceID()
	end,
	log = log,
})

-- Properties ---------------------------------------------------------------------

-- Fan Address: a new epoch and a contact, or S1 and S3 (section 3.5). Late init
-- reads the value itself, so an edit before it is ignored.
dispatch.properties["Fan_Address"] = function(value)
	if not started then
		return
	end
	-- The owner's typed address wins until the pinned fan answers there (F5).
	-- Two values are no such edit: an empty one is the stop switch (the
	-- follower never looks without an address), and the address the pinned fan
	-- was last seen at, typed back, resumes (v1-design 3.5): it is known to be
	-- the fan's, as a contact there would show.
	local typed = trimmed(value)
	local pin = model:identity()
	if pin and pin.address and typed == pin.address then
		follower:contact()
	elseif typed ~= "" then
		follower:address_edited()
	end
	model:set_address(value)
	search:changed()
	draw_found()
	refresh_status()
end

-- Follow Address Changes (F7): On by default; Off stops every window.
dispatch.properties["Follow_Address_Changes"] = function(value)
	follower:switch(value ~= "Off")
	if started then
		search:changed()
	end
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

-- Speed LED Colors (V27, #31). A COLOR_SELECTOR holds "r,g,b" in decimal
-- (Fundamentals, 15_composerpro_interface_into_the_sdk/_5-COLORSELECTOR.md);
-- links want "rrggbb". Anything else reads as nothing and links.lua warns.
local function color_hex(value)
	local text = tostring(value or "")
	local r, g, b = text:match("^%s*(%d+)%s*,%s*(%d+)%s*,%s*(%d+)%s*$")
	r, g, b = tonumber(r), tonumber(g), tonumber(b)
	if r and r <= 255 and g <= 255 and b <= 255 then
		return string.format("%02x%02x%02x", r, g, b)
	end
	return text:match("^#?(%x%x%x%x%x%x)$")
end

-- Every colour row is read together, so one change or the replay at late init
-- hands links.lua the whole set.
local function apply_colors()
	local function read(name)
		local raw = Properties[name]
		local hex = color_hex(raw)
		if hex == nil and trimmed(raw) ~= "" then
			log.warn("%s %s is not a colour (red,green,blue from 0 to 255); ignored", name, tostring(raw))
		end
		return hex
	end
	local colors = {}
	for speed = 1, 6 do
		colors[speed] = read("Speed " .. speed .. " LED Color")
	end
	local mode = Properties["Speed LED Colors"] == "Per speed" and "per_speed" or "keypad"
	links:set_colors(mode, colors, read("Speed LED Off Color"))
end

dispatch.properties["Speed_LED_Colors"] = apply_colors
dispatch.properties["Speed_LED_Off_Color"] = apply_colors
for speed = 1, 6 do
	dispatch.properties["Speed_" .. speed .. "_LED_Color"] = apply_colors
end

-- Keypad Links lists; a pick changes nothing and snaps back to the first row.
dispatch.properties["Keypad_Links"] = function()
	if keypad_items[1] then
		C4:UpdateProperty("Keypad Links", keypad_items[1])
	end
end


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

-- Naming the two items after the fan's product name (fan-name-design, #37):
-- only on Use Selected Fan (guarded) and Name Items After Fan (forced).
local function one_consumer(binding)
	local found_id, count = nil, 0
	for id in pairs(C4:GetBoundConsumerDevices(C4:GetDeviceID(), binding) or {}) do
		found_id, count = id, count + 1
	end
	return count == 1 and found_id or nil
end

-- The id when it is one of this device's own proxies, as GetDevices lists them
-- under "proxies" (API 22_miscellaneous/_9, example 3), else nil.
local function own_proxy(proxies, id)
	if id == nil then
		return nil
	end
	for key in pairs(proxies) do
		if tonumber(key) == tonumber(id) then
			return id
		end
	end
	return nil
end

-- Both items, or neither: each must be the one bound consumer of its binding,
-- one of this device's own proxies, and not this device itself (review of #37,
-- finding 5). Anything else answers no_ids, so nothing else is ever renamed.
local function item_ids()
	local me = C4:GetDeviceID()
	local ok, devices = pcall(C4.GetDevices, C4, { DeviceIds = tostring(me) })
	if not ok or type(devices) ~= "table" then
		return nil, nil
	end
	local entry
	for key, value in pairs(devices) do
		if tonumber(key) == tonumber(me) then
			entry = value
		end
	end
	if type(entry) ~= "table" or type(entry.proxies) ~= "table" then
		return nil, nil
	end
	local fan_id = own_proxy(entry.proxies, one_consumer(FAN_BINDING))
	local light_id = own_proxy(entry.proxies, one_consumer(LIGHT_BINDING))
	if fan_id == nil or light_id == nil or tonumber(fan_id) == tonumber(light_id)
		or tonumber(fan_id) == tonumber(me) or tonumber(light_id) == tonumber(me) then
		return nil, nil
	end
	return fan_id, light_id
end

names_job = rename_mod.new({
	ids = item_ids,
	display_name = function(id)
		return C4:GetDeviceDisplayName(id)
	end,
	rename = function(id, name)
		C4:RenameDevice(id, name) -- API 22_miscellaneous/_32-RenameDevice.md: a proxy id
	end,
	fan_type = function()
		local info = model:info()
		return info and info.fan_type or nil
	end,
	pinned = function()
		return model:identity() ~= nil
	end,
	lookup = names.lookup,
	light = names.light,
	defaults = names.DEFAULTS,
	timer = timer,
	store = store,
	now = os.time,
	log = log,
})

-- Breeze (breeze-design, #111): the commands, the variable, the events, the
-- condition and the companion switch; link 311 goes through links.
local function fan_item_name()
	local id = one_consumer(FAN_BINDING)
	local name = id and C4:GetDeviceDisplayName(id) or nil
	if type(name) ~= "string" or name == "" then
		name = "Modern Forms Fan"
	end
	return name
end

breeze = breeze_mod.new({
	model = model,
	preset = function()
		return fan:preset()
	end,
	set_variable = function(value)
		C4:SetVariable("Breeze", value)
	end,
	fire = function(id)
		C4:FireEventByID(id)
	end,
	persist = function(key, value)
		store.set(key, value)
	end,
	recall = function(key)
		return store.get(key)
	end,
	result = result,
	companions = function()
		local ids = {}
		for id in pairs(C4:GetBoundConsumerDevices(C4:GetDeviceID(), BREEZE_BINDING) or {}) do
			ids[#ids + 1] = tonumber(id) or id
		end
		table.sort(ids, function(a, b) return tostring(a) < tostring(b) end)
		return ids
	end,
	send = function(id, command, params)
		C4:SendToDevice(id, command, params)
	end,
	-- API 9_helper/_0.1-AddDevice.md: for user-initiated use, as this click is.
	add_device = function(name, cb)
		C4:AddDevice(BREEZE_DRIVER, C4:RoomGetId(), name, cb)
	end,
	bind = function(id)
		return (pcall(C4.Bind, C4, C4:GetDeviceID(), BREEZE_BINDING, id, 1, BREEZE_CLASS))
	end,
	item_name = fan_item_name,
	-- BF-D10: a bound 1.2 switch gets L41 instead of L37.
	old_companion = function(id)
		local bound = C4:GetBoundConsumerDevices(C4:GetDeviceID(), BREEZE_BINDING) or {}
		local name = bound[id]
		if name == nil then name = bound[tonumber(id)] end
		if name == nil then name = bound[tostring(id)] end
		return name == OLD_BREEZE_NAME
	end,
	log = log,
})

-- The rename job's outcomes as Last Action keys (fan-name-design 2.3).
local NAME_RESULTS = {
	renamed = "name_renamed", same = "name_same", no_name = "name_unknown", no_type = "name_no_type",
	no_ids = "name_no_ids", unconfirmed = "name_unconfirmed", no_pin = "name_no_pin", busy = "name_busy",
}

local stop_devcmds = nil
if devloop and devcmds then
	local commands, stop = devcmds.new({
		model = model,
		names = names_job,
		follow = follower,
		search = search,
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

-- Takes the fan at `address` (mac: the one picked, or nil for Fan Address):
-- Use Selected Fan's path (section 3.5), also for a pick in Found Fans
-- (auto-discovery-design 4). A stale list answers not_picked or no_answer and
-- asks once more at once.
local function take_fan(address, mac)
	-- A window open now drops its candidates (address-follow-design F4).
	follower:clicked()
	model:use_fan(address, mac, function(key, args)
		found_list:drop()
		draw_found(true)
		if key == "nothing_to_use" then
			args = nil
		end
		if key == "moved" or key == "now_using" then
			prop("Fan Address", address)
		end
		result(key, args)
		refresh_status()
		search:changed()
		if key == "not_picked" or key == "no_answer" then
			search:poke("stale")
		end
		local shown = shown_count
		-- A fan pinned by the click: the guarded rename, then the same line again
		-- with its suffix (fan-name-design N4), unless something else wrote Last
		-- Action in the meantime: that line stays and the log has the ending.
		if key == "already" or key == "moved" or key == "now_using" then
			names_job:run("guarded", function(outcome)
				local suffix = texts.rename_suffix(outcome)
				if suffix == "" then
					return
				end
				if shown_count == shown then
					show_result(texts.result(key, args) .. suffix)
				else
					log.always("names: Use Selected Fan ended %q; Last Action has a later line", suffix)
				end
			end)
		end
	end)
end

-- Found Fans, after Set (auto-discovery-design 4): a fan's row takes it at
-- once; a different fan on a device already pinned waits for Use Selected Fan
-- (L32); the summary, the overflow row or a row of an older list do nothing.
-- The late-init replay comes before `started` and is ignored.
dispatch.properties["Found_Fans"] = function(value)
	if not started then
		return
	end
	local entry = found_shown.entries[value]
	if not entry then
		draw_found(true)
		return
	end
	if model:identity() and not entry.own then
		found_list:keep(entry.key)
		result("picked_wait", { instance = entry.instance })
		draw_found(true)
		return
	end
	found_list:drop()
	take_fan(entry.address, entry.mac)
end

-- Use Selected Fan: the waiting pick, else Fan Address (section 3.5).
dispatch.commands["Use_Selected_Fan"] = function()
	local kept = found_list:kept()
	local address, mac
	if kept then
		address, mac = kept.address, kept.mac
	else
		address = trimmed(Properties["Fan Address"])
		if address == "" then
			address = nil
		end
	end
	if not address then
		follower:clicked()
		result("nothing_to_use")
		return
	end
	take_fan(address, mac)
end

-- Name Items After Fan: the forced rename (fan-name-design N5).
dispatch.commands["Name_Items_After_Fan"] = function()
	names_job:run("forced", function(outcome, args)
		result(NAME_RESULTS[outcome] or "name_unconfirmed", args)
	end)
end

-- Breeze (breeze-design BZ3, BZ11): the programming commands, the action and
-- the companion's messages (C4:SendToDevice lands in ExecuteCommand).
for _, name in ipairs({ "Breeze_On", "Breeze_Off", "Toggle_Breeze", "Set_Breeze_Strength" }) do
	dispatch.commands[name] = function(params)
		breeze:command(name, params)
	end
end
dispatch.commands["Add_Breeze_Fan"] = function()
	breeze:add_switch()
end
for _, name in ipairs({ "MF_BREEZE_SET", "MF_BREEZE_TOGGLE", "MF_BREEZE_CYCLE", "MF_BREEZE_HELLO" }) do
	dispatch.commands[name] = function(params)
		breeze:companion(name, params)
	end
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

-- Lifecycle ----------------------------------------------------------------------

dispatch.install(_G)

-- Section 2.7: the Online variable, added in OnDriverInit in this order and
-- never reordered or renamed; its value is the persisted one, so the first
-- difference after a restart reads as a change (D9).
function OnDriverInit()
	online_now = (C4:PersistGetValue("mf_online")) == true
	C4:AddVariable("Online", online_now and "1" or "0", "BOOL", true)
	-- breeze-design BZ3: second, never reordered; seeded so a restart alone
	-- changes nothing (BC22).
	C4:AddVariable("Breeze", (C4:PersistGetValue("mf_breeze")) == true and "1" or "0", "BOOL", true)
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
	-- The Migration Report's verdict, persisted by v1.0-beta.1 and beta.2, goes
	-- with the report (#45). Found Fans starts empty (lists are not persisted,
	-- FUND 15/_2); the search refills it (auto-discovery-design 2).
	pcall(C4.PersistDeleteValue, C4, "mf_migration") -- API 26.5_persistence/_2
	found_list:clear()
	dispatch.replay_properties(Properties)
	dev.show_driver_version(1)
	os_info = C4:GetVersionInfo()
	-- The proxy's preset before the model's first answers can tell it.
	fan:late_init()
	model:start(trimmed(Properties["Fan Address"]), texts.parse_fan_id(Properties["Fan ID"]))
	started = true
	show_restored()
	draw_found(true)
	refresh_status()
	-- Buffered proxy messages (GET_CURRENT_STATE at the add), then the links'
	-- reads of their keypads, before the binding changes that came early.
	dev.late_init()
	links:late_init()
	-- The load window, then the mode's schedule (auto-discovery-design 2).
	search:start()
	-- The companions hear the state (breeze-design 3).
	breeze:late_init()
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
	if binding == BREEZE_BINDING then
		breeze:binding_changed(bound)
	end
end)

-- Section 2.7: the one condition, "Fan is online". With a VALUE (the text
-- picked) it compares; without, it answers the state itself.
function TestCondition(name, params)
	local answer = breeze:test_condition(name, params)
	if answer ~= nil then
		return answer
	end
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

-- The search's answers: the dynamic binding's datagrams (the Finder's window).
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
	follower:stop()
	search:stop()
	discovery:stop()
	names_job:stop()
	breeze:stop()
	links:stop()
	light:stop()
	model:stop()
	transport:stop()
	dev.cancel_timers()
end
