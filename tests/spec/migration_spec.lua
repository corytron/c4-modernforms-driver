-- fan.migration: the Migration Report of docs/migration-design.md, section 4, on
-- fakes of what Director returns (GetDevices, GetAllCodeItems, GetDeviceVariables,
-- GetBindingsByDevice, GetBoundConsumerDevices) in the shapes of sections 4.2 and
-- 4.3 and of probe H8's reading (the API reference's example: { event_mgr = {
-- { deviceid, eventid, codeitem = root } } }, a root of id 0 and device 0).
--
-- The house is section 1's inventory with the placeholders of the neutral set
-- (tools/composer/Shots.ps1): the stock device 1201 with its fan proxy 1202 and its
-- light proxy 1203, the new device 1204 with 1205 and 1206, the keypad 1210 with
-- its proxies 1211 and 1212 (the keypad proxy carries the button events), the Timer
-- agent 1220, all in "Example Room". Its scripts are 1.3's I1 to I11: 22 old lines
-- in 11 scripts, the workaround's LED lines among the others.

local migration = require("fan.migration")
local T = migration.T

local STOCK, STOCK_FAN, STOCK_LIGHT = 1201, 1202, 1203
local NEW, NEW_FAN, NEW_LIGHT = 1204, 1205, 1206
local KEYPAD, KEYPAD_LIGHT, BUTTONS = 1210, 1211, 1212
local TIMER = 1220
local STOCK2, STOCK2_FAN, STOCK2_LIGHT = 1301, 1302, 1303
local STOCK_FILE = "wac_mf_fan_and_light_controller(v4).c4z"
local CLOCK = 1793793600

local ARROW = "\226\150\184" -- U+25B8
local DOT = "\194\183" -- U+00B7
local ELLIPSIS = "\226\128\166" -- U+2026
local COMMA = "\226\128\154" -- U+201A

-- Code items --------------------------------------------------------------------

local function mk(kind, device, display, subitems, enabled)
	return {
		enabled = enabled ~= false, cmdcond = { xml = "" }, creator = 0, device = device or 0,
		type = kind, display = display or "", subitems = subitems or {}, creatorstate = "", id = 1,
	}
end

local function command(device, display, enabled) return mk(1, device, display, nil, enabled) end
local function condition(device, display, subitems, enabled) return mk(2, device, display, subitems, enabled) end
local function loop(device, display, subitems, enabled) return mk(3, device, display, subitems, enabled) end
local function otherwise(subitems, enabled) return mk(4, 0, "Else", subitems, enabled) end
local function comment(device, display) return mk(5, device, display) end
local function operator(device, display) return mk(6, device, display) end
local function container(subitems, enabled) return mk(0, 0, "", subitems, enabled) end

-- One event's entry of GetAllCodeItems: the root has id 0 and device 0, its subitems are the lines.
local function entry(device, event, lines, root_enabled)
	return {
		deviceid = device, eventid = event,
		codeitem = {
			enabled = root_enabled ~= false, cmdcond = { xml = "" }, creator = 0, device = 0, type = 1,
			display = "", subitems = lines or {}, creatorstate = "", id = 0,
		},
	}
end

local function join(...)
	local out = {}
	for _, list in ipairs({ ... }) do
		for _, line in ipairs(list) do
			out[#out + 1] = line
		end
	end
	return out
end

local function set(...)
	local out = {}
	for _, value in ipairs({ ... }) do
		out[value] = true
	end
	return out
end

-- Section 1.3: the keypad's single-tap scripts light one button and darken the other four.
local BUTTON_NAMES = { "Low", "Medium", "Med-High", "High", "Off" }

local function leds(lit)
	local lines = {}
	for _, name in ipairs(BUTTON_NAMES) do
		local verb = name == lit and "Use the on color for " or "Use the off color for "
		lines[#lines + 1] = command(BUTTONS, verb .. name)
	end
	return lines
end

local function double_tap(button, speed)
	return {
		command(STOCK_FAN, "Set speed on NAME to " .. speed),
		command(BUTTONS, "Set the on color for " .. button),
		command(BUTTONS, "Use the on color for " .. button),
	}
end

-- The Timer agent's Expires script: 12 Ifs on the stock fan, five LED lines in each.
local function settle_lines()
	local ifs = {}
	for speed = 0, 11 do
		ifs[#ifs + 1] = condition(STOCK_FAN, "If NAME speed is " .. speed, leds("Low"))
	end
	return ifs
end

local LOW, LOW2, MEDIUM, MEDHIGH, HIGH, HIGH2, OFF, UP, DOWN = 12, 13, 14, 15, 16, 17, 18, 19, 20
local SPEED_CHANGED, SETTLE = 7, 31

local SCRIPTS = {
	{ event = LOW, device = BUTTONS, build = function()
		return join({ command(STOCK_FAN, "Set speed on NAME to 2") }, leds("Low"))
	end },
	{ event = LOW2, device = BUTTONS, build = function() return double_tap("Low", 1) end },
	{ event = MEDIUM, device = BUTTONS, build = function()
		return join({ command(STOCK_FAN, "Set speed on NAME to 3") }, leds("Medium"))
	end },
	{ event = MEDHIGH, device = BUTTONS, build = function()
		return join({ command(STOCK_FAN, "Set speed on NAME to 4") }, leds("Med-High"))
	end },
	{ event = HIGH, device = BUTTONS, build = function()
		return join({ command(STOCK_FAN, "Set speed on NAME to 5") }, leds("High"))
	end },
	{ event = HIGH2, device = BUTTONS, build = function() return double_tap("High", 6) end },
	{ event = OFF, device = BUTTONS, build = function()
		return join({ command(STOCK_FAN, "Turn off NAME") }, leds("Off"))
	end },
	{ event = UP, device = BUTTONS, build = function() return { command(STOCK_LIGHT, "Turn on NAME") } end },
	{ event = DOWN, device = BUTTONS, build = function() return { command(STOCK_LIGHT, "Turn off NAME") } end },
	{ event = SPEED_CHANGED, device = STOCK_FAN, build = function()
		return { command(TIMER, "Start the timer Fan LED Settle") }
	end },
	{ event = SETTLE, device = TIMER, build = settle_lines },
}

-- What a phase of section 3 did to the scripts: event_off is Disable Event (the root's
-- flag), item_off Disable Item on every line the script had, deleted removes those lines,
-- dropped removes the script, added gives the new lines.
local NEW_LINES = {
	[LOW2] = function() return command(NEW_FAN, "Set speed on NAME to 1") end,
	[HIGH2] = function() return command(NEW_FAN, "Set speed on NAME to 6") end,
	[UP] = function() return command(NEW_LIGHT, "Turn on NAME") end,
	[DOWN] = function() return command(NEW_LIGHT, "Turn off NAME") end,
}

local SINGLE_TAPS = set(LOW, MEDIUM, MEDHIGH, HIGH, OFF)

local PHASES = {
	start = {},
	medium = { event_off = set(MEDIUM) },
	buttons = { event_off = SINGLE_TAPS, item_off = set(LOW2, HIGH2, UP, DOWN), added = NEW_LINES },
	workaround_off = {
		event_off = set(LOW, MEDIUM, MEDHIGH, HIGH, OFF, SPEED_CHANGED, SETTLE),
		item_off = set(LOW2, HIGH2, UP, DOWN), added = NEW_LINES,
	},
	-- G7's fallback: no Disable Event, Disable Item on every top-level line instead
	items_only = {
		item_off = set(LOW, MEDIUM, MEDHIGH, HIGH, OFF, SPEED_CHANGED, SETTLE, LOW2, HIGH2, UP, DOWN),
		added = NEW_LINES,
	},
	removed = {
		dropped = set(LOW, MEDIUM, MEDHIGH, HIGH, OFF, SPEED_CHANGED, SETTLE),
		deleted = set(LOW2, HIGH2, UP, DOWN), added = NEW_LINES,
	},
}

local function house_items(phase)
	phase = phase or {}
	local items = {}
	for _, script in ipairs(SCRIPTS) do
		local event = script.event
		local lines = script.build()
		if phase.item_off and phase.item_off[event] then
			for _, line in ipairs(lines) do
				line.enabled = false
			end
		end
		if phase.deleted and phase.deleted[event] then
			lines = {}
		end
		if phase.added and phase.added[event] then
			lines[#lines + 1] = phase.added[event]()
		end
		if not (phase.dropped and phase.dropped[event]) then
			local off = phase.event_off and phase.event_off[event]
			items[#items + 1] = entry(script.device, event, lines, not off)
		end
	end
	return items
end

-- The project -----------------------------------------------------------------------

local function stock_device(fan, light, room)
	return {
		deviceName = "Fan Light", driverFileName = STOCK_FILE, roomId = 100, roomName = room,
		proxies = {
			[fan] = { deviceName = "Fan", driverFileName = "fan.c4i" },
			[light] = { deviceName = "Fan Light", driverFileName = "light_v2.c4i" },
		},
	}
end

local function project_devices(opts)
	opts = opts or {}
	local devices = {
		[NEW] = {
			deviceName = "Modern Forms Fan", driverFileName = "modernforms_fan.c4z", roomId = 100,
			roomName = "Example Room",
			proxies = {
				[NEW_FAN] = { deviceName = "Fan (new)", driverFileName = "fan.c4i" },
				[NEW_LIGHT] = { deviceName = "Fan Light (new)", driverFileName = "light_v2.c4i" },
			},
		},
		[KEYPAD] = {
			deviceName = "Keypad", driverFileName = "combo_dimmer.c4i", roomId = 100, roomName = "Example Room",
			proxies = {
				[KEYPAD_LIGHT] = { deviceName = "Keypad Light", driverFileName = "light_v2.c4i" },
				[BUTTONS] = { deviceName = "Keypad", driverFileName = "keypad_proxy.c4i" },
			},
		},
	}
	if not opts.no_stock then
		devices[STOCK] = stock_device(STOCK_FAN, STOCK_LIGHT, "Example Room")
	end
	if opts.second_stock then
		devices[STOCK2] = stock_device(STOCK2_FAN, STOCK2_LIGHT, "Second Room")
	end
	return devices
end

local function default_vars()
	return {
		[STOCK_FAN] = {
			["1000"] = { name = "Is On", value = "1" },
			["1001"] = { name = "Current Selected Speed", value = "3" },
			["1002"] = { name = "Is Reversed", value = "0" },
		},
		[STOCK_LIGHT] = { ["1000"] = { name = "LIGHT_LEVEL", value = "0" } },
		[NEW_FAN] = { ["1001"] = { name = "Current Selected Speed", value = "3" } },
	}
end

-- Simulates PersistSetValue: a table of plain values only [API 26.5/_4].
local function deep_copy(value)
	local kind = type(value)
	if kind == "table" then
		local out = {}
		for key, item in pairs(value) do
			out[deep_copy(key)] = deep_copy(item)
		end
		return out
	elseif kind == "function" or kind == "userdata" or kind == "thread" then
		error("PersistSetValue cannot hold a " .. kind)
	end
	return value
end

-- h: replacements for the project's parts. The env is the world the api's functions read.
local function new_env(h)
	h = h or {}
	return {
		devices = h.devices or project_devices(),
		items = h.items or house_items(),
		vars = h.vars or default_vars(),
		bound = h.bound or {}, -- ["1201:3"] = { [keypad] = "Keypad" }
		bindings = h.bindings or {}, -- [proxy id] = what GetBindingsByDevice returns
		display = h.display or { [TIMER] = "Timer" },
		props = h.props or { ["Fan Address"] = "10.0.2.151", ["Stock Device"] = "", ["Driver Version"] = "57" },
		clock = CLOCK,
		store = h.store or {},
		calls = {}, logs = {}, lists = {},
	}
end

-- overrides: a function replaces the api's, false removes it.
local function make_api(env, overrides)
	local function note(name) env.calls[#env.calls + 1] = name end
	local log = {}
	for _, level in ipairs({ "error", "warn", "info", "debug", "always" }) do
		log[level] = function(template, ...)
			env.logs[#env.logs + 1] = { level = level, text = string.format(template, ...) }
		end
	end
	local api = {
		get_devices = function() note("get_devices"); return env.devices end,
		get_all_code_items = function() note("get_all_code_items"); return { event_mgr = env.items } end,
		get_device_variables = function(id) note("get_device_variables"); return env.vars[id] end,
		get_bindings_by_device = function(id) note("get_bindings_by_device"); return env.bindings[id] end,
		get_bound_consumer_devices = function(id, link)
			note("get_bound_consumer_devices")
			return env.bound[id .. ":" .. link]
		end,
		get_device_display_name = function(id) note("get_device_display_name"); return env.display[id] end,
		get_device_id = function() note("get_device_id"); return NEW end,
		get_proxy_devices = function() note("get_proxy_devices"); return NEW_FAN, NEW_LIGHT end,
		property = function(name) note("property"); return env.props[name] end,
		now = function() return env.clock end,
		log = log,
		store = {
			get = function(key)
				note("store.get")
				local value = env.store[key]
				return value ~= nil and deep_copy(value) or nil
			end,
			set = function(key, value)
				note("store.set")
				env.store[key] = deep_copy(value)
			end,
		},
		update_list = function(items, selected)
			note("update_list")
			env.lists[#env.lists + 1] = { items = items, selected = selected }
		end,
	}
	for key, value in pairs(overrides or {}) do
		if value == false then
			api[key] = nil
		else
			api[key] = value
		end
	end
	return api
end

local function house(phase, h)
	h = h or {}
	h.items = house_items(PHASES[phase])
	local env = new_env(h)
	return migration.new(make_api(env)), env
end

-- A project with the stock device, the new device and the keypad, and only these scripts.
local function mini(items, h, overrides)
	h = h or {}
	h.items = items
	local env = new_env(h)
	return migration.new(make_api(env, overrides)), env
end

local function found(rows, prefix)
	for index, row in ipairs(rows) do
		if row:sub(1, #prefix) == prefix then
			return row, index
		end
	end
	return nil
end

-- The script rows (item 10), in order.
local function script_rows(rows)
	local out = {}
	for _, row in ipairs(rows) do
		if row:find(" " .. ARROW .. " event ", 1, true) then
			out[#out + 1] = row
		end
	end
	return out
end

local function ulen(s)
	return #(s:gsub("[\128-\191]", ""))
end

local function valid_utf8(s)
	local i, n = 1, #s
	while i <= n do
		local b = s:byte(i)
		local need = 0
		if b >= 240 then
			need = 3
		elseif b >= 224 then
			need = 2
		elseif b >= 192 then
			need = 1
		elseif b >= 128 then
			return false
		end
		for k = 1, need do
			local c = s:byte(i + k)
			if not c or c < 128 or c > 191 then
				return false
			end
		end
		i = i + need + 1
	end
	return true
end

local function report_row(build)
	return "Report of " .. os.date("%Y-%m-%d %H:%M", CLOCK) .. " by build " .. (build or "57") .. "; it changed nothing"
end

local function count(list, value)
	local n = 0
	for _, item in ipairs(list) do
		if item == value then
			n = n + 1
		end
	end
	return n
end

local function levels(env, level)
	local out = {}
	for _, line in ipairs(env.logs) do
		if line.level == level then
			out[#out + 1] = line.text
		end
	end
	return out
end

describe("fan.migration", function()
	describe("the texts of section 4.5", function()
		it("pins the verdicts verbatim", function()
			assert.equal("Not run yet: click Migration Report on the Actions tab", T.not_run)
			assert.equal("Stock Device changed: click Migration Report again", T.changed)
			assert.equal("No stock WAC device in the project; nothing to migrate", T.none)
			assert.equal("3 stock WAC devices: pick this fan's in Stock Device", string.format(T.several, 3))
			assert.equal("Stock device 1201: 22 enabled lines name it; keep it",
				string.format(T.keep_lines[2], 1201, 22))
			assert.equal("Stock device 1201: 2 keypad links bound to it; keep it",
				string.format(T.keep_links[2], 1201, 2))
			assert.equal("Stock device 1201: nothing enabled names it; safe to remove",
				string.format(T.safe, 1201))
			assert.equal("Stock device 1201 is gone; nothing names it", string.format(T.gone, 1201))
			assert.equal("Stock device 1201 is gone; 3 lines still name it",
				string.format(T.gone_lines[2], 1201, 3))
			assert.equal("Report failed: this OS has no GetAllCodeItems (needs 3.3.0)",
				string.format(T.failed, T.no_api))
			assert.equal("Report failed: Stock Device 1204 is not a stock WAC device",
				string.format(T.failed, string.format(T.not_stock, 1204)))
			assert.equal("Report failed: reading the programming failed; see the Lua tab",
				string.format(T.failed, T.read_failed))
		end)

		it("pins the fixed rows verbatim", function()
			assert.equal("Not read here: lighting scenes; favourites; voice", T.not_read)
			assert.equal("Script rows count lines on/total: old " .. DOT .. " new " .. DOT .. " other", T.legend)
			assert.equal("Stock links bound to keypads: 0 of 12", string.format(T.links, 0, 12))
			assert.equal("Speed held by the stock fan: 3; by this fan: 3", string.format(T.speeds, 3, 3))
			assert.equal(ELLIPSIS .. " 5 more scripts; the Lua tab lists all by id",
				string.format(T.more_scripts[2], 5))
		end)

		it("uses the singular where the plural would read wrongly", function()
			assert.equal("Stock device 1201: 1 enabled line names it; keep it", string.format(T.keep_lines[1], 1201, 1))
			assert.equal("Stock device 1201: 1 keypad link bound to it; keep it",
				string.format(T.keep_links[1], 1201, 1))
			assert.equal("Stock device 1201 is gone; 1 line still names it", string.format(T.gone_lines[1], 1201, 1))
			assert.equal("Lines naming device 1201: 1 in 1 script; 1 enabled",
				string.format(T.stock_lines[1], 1201, 1, 1, 1))
		end)
	end)

	describe("before any run", function()
		it("says it has not run, calls nothing and writes nothing", function()
			local env = new_env()
			local m = migration.new(make_api(env))
			assert.equal(T.not_run, m:verdict())
			assert.same({ T.not_run }, m:rows())
			assert.is_nil(m:last())
			assert.same({}, env.calls)
			assert.same({}, env.store)
		end)

		it("is made from nothing at all", function()
			local m = migration.new(nil)
			assert.equal(T.not_run, m:verdict())
			assert.has_no.errors(function()
				m:run()
				m:restore()
				m:stock_device_changed()
				m:snap_back()
			end)
		end)

		it("hands out copies of its rows", function()
			local m = migration.new(make_api(new_env()))
			local rows = m:rows()
			rows[1] = "changed by the caller"
			assert.same({ T.not_run }, m:rows())
		end)
	end)

	describe("the house, phase by phase (section 3)", function()
		it("Phase 3's entry: 22 enabled lines in 11 scripts, the rows of section 4.4", function()
			local m, env = house("start")
			local verdict, rows = m:run()

			assert.equal("Stock device 1201: 22 enabled lines name it; keep it", verdict)
			assert.equal(verdict, m:verdict())
			assert.same(rows, m:rows())
			assert.equal(verdict, rows[1])
			assert.equal(report_row(), rows[2])
			assert.equal("Stock: device 1201 in Example Room (the only one)", rows[3])
			assert.equal("Speed held by the stock fan: 3; by this fan: 3", rows[4])
			assert.equal("Stock links bound to keypads: 0 of 12", rows[5])
			assert.equal("Lines naming device 1201: 22 in 11 scripts; 22 enabled", rows[6])
			assert.equal("Lines naming this device: 0 in 0 scripts; 0 enabled", rows[7])
			assert.equal("Other lines still on in scripts naming it: 89", rows[8])
			assert.equal("Script rows count lines on/total: old " .. DOT .. " new " .. DOT .. " other", rows[9])
			assert.equal("Not read here: lighting scenes; favourites; voice", rows[#rows])
			assert.equal(48, #rows)
			assert.same({}, levels(env, "warn"))
			assert.same({}, levels(env, "error"))
		end)

		it("lists the scripts, those with an enabled old line first, then by device and event", function()
			local m = house("start")
			local _, rows = m:run()
			local K = "Example Room Keypad " .. ARROW .. " event "
			assert.same({
				"Example Room Fan " .. ARROW .. " event 7: old 1/1",
				K .. "12: old 1/1 " .. DOT .. " other 5/5",
				K .. "13: old 1/1 " .. DOT .. " other 2/2",
				K .. "14: old 1/1 " .. DOT .. " other 5/5",
				K .. "15: old 1/1 " .. DOT .. " other 5/5",
				K .. "16: old 1/1 " .. DOT .. " other 5/5",
				K .. "17: old 1/1 " .. DOT .. " other 2/2",
				K .. "18: old 1/1 " .. DOT .. " other 5/5",
				K .. "19: old 1/1",
				K .. "20: old 1/1",
				"Timer " .. ARROW .. " event 31: old 12/12 " .. DOT .. " other 60/60",
			}, script_rows(rows))
		end)

		it("shows each script's first line and its enabled old lines, as the sample of 4.4 does", function()
			local m = house("start")
			local _, rows = m:run()
			local _, at = found(rows, "Example Room Keypad " .. ARROW .. " event 12: ")
			assert.equal("  first: Set speed on Example Room->Fan to 2", rows[at + 1])
			assert.equal("  on: Set speed on Example Room->Fan to 2", rows[at + 2])

			local _, timer = found(rows, "Timer " .. ARROW .. " event 31: ")
			assert.equal("  first: If Example Room->Fan speed is 0", rows[timer + 1])
			for n = 0, 4 do
				assert.equal("  on: If Example Room->Fan speed is " .. n, rows[timer + 2 + n])
			end
			assert.equal("  on: " .. ELLIPSIS .. " and 7 more", rows[timer + 7])
			assert.equal(T.not_read, rows[timer + 8])
		end)

		it("names an agent GetDevices does not list with GetDeviceDisplayName, once", function()
			local m, env = house("start")
			m:run()
			assert.equal(1, count(env.calls, "get_device_display_name"))
		end)

		it("one button moved (Disable Event on Medium): 21 lines, its script last", function()
			local m = house("medium")
			local verdict, rows = m:run()
			assert.equal("Stock device 1201: 21 enabled lines name it; keep it", verdict)
			assert.equal("Lines naming device 1201: 22 in 11 scripts; 21 enabled", rows[6])
			assert.equal("Other lines still on in scripts naming it: 84", rows[8])
			local list = script_rows(rows)
			assert.equal("Example Room Keypad " .. ARROW .. " event 14: old 0/1 " .. DOT .. " other 0/5", list[#list])
		end)

		it("all five buttons and the double taps moved: 13 enabled lines, 4 new, as Phases 3 and 4 check", function()
			local m = house("buttons")
			local verdict, rows = m:run()
			assert.equal("Stock device 1201: 13 enabled lines name it; keep it", verdict)
			assert.equal("Lines naming device 1201: 22 in 11 scripts; 13 enabled", rows[6])
			assert.equal("Lines naming this device: 4 in 4 scripts; 4 enabled", rows[7])
			assert.equal("Other lines still on in scripts naming it: 60", rows[8])
			-- the sample of 4.4: Low's Double Tap script after the cutover
			local row, at = found(rows, "Example Room Keypad " .. ARROW .. " event 13: ")
			assert.equal("Example Room Keypad " .. ARROW .. " event 13: old 0/1 " .. DOT .. " new 1/1 " .. DOT
				.. " other 0/2", row)
			assert.equal("  first: Set speed on Example Room->Fan to 1", rows[at + 1])
			assert.equal("Example Room Keypad " .. ARROW .. " event 14: old 0/1 " .. DOT .. " other 0/5", rows[at + 2])
			-- the enabled old lines come first: the stock fan's script and the timer's
			local list = script_rows(rows)
			assert.equal("Example Room Fan " .. ARROW .. " event 7: old 1/1", list[1])
			assert.equal("Timer " .. ARROW .. " event 31: old 12/12 " .. DOT .. " other 60/60", list[2])
		end)

		it("shows a new line's text under a script whose old lines are all off", function()
			local m = house("buttons")
			local _, rows = m:run()
			local _, up = found(rows, "Example Room Keypad " .. ARROW .. " event 19: ")
			assert.equal("Example Room Keypad " .. ARROW .. " event 19: old 0/1 " .. DOT .. " new 1/1", rows[up])
			assert.equal("  first: Turn on Example Room->Fan Light", rows[up + 1])
		end)

		it("the workaround off: nothing enabled names the stock device, safe to remove", function()
			local m = house("workaround_off")
			local verdict, rows = m:run()
			assert.equal("Stock device 1201: nothing enabled names it; safe to remove", verdict)
			assert.equal("Lines naming device 1201: 22 in 11 scripts; 0 enabled", rows[6])
			assert.equal("Lines naming this device: 4 in 4 scripts; 4 enabled", rows[7])
			assert.equal("Other lines still on in scripts naming it: 0", rows[8])
			for _, row in ipairs(script_rows(rows)) do
				assert.is_nil(row:find("old [1-9]"), row) -- "old 0/…" everywhere (Phase 5's check)
				assert.is_nil(row:find("other [1-9]"), row)
			end
			assert.is_nil(found(rows, "  on: "))
		end)

		it("G7's fallback: Disable Item on every top-level line reads the same", function()
			local m = house("items_only")
			local verdict, rows = m:run()
			assert.equal("Stock device 1201: nothing enabled names it; safe to remove", verdict)
			assert.equal("Other lines still on in scripts naming it: 0", rows[8])
		end)

		it("the stock device removed, after a report that saw it: gone, nothing names it", function()
			local env = new_env({ items = house_items(PHASES.workaround_off) })
			local first = migration.new(make_api(env))
			assert.equal("Stock device 1201: nothing enabled names it; safe to remove", (first:run()))

			-- Phase 8: the old lines, the timer script and the stock device are deleted; the
			-- controller restarts, and the report comes back from what it persisted
			env.items = house_items(PHASES.removed)
			env.devices = project_devices({ no_stock = true })
			local second = migration.new(make_api(env))
			second:restore()
			local verdict, rows = second:run()

			assert.equal("Stock device 1201 is gone; nothing names it", verdict)
			assert.equal("Lines naming device 1201: 0 in 0 scripts; 0 enabled", rows[3])
			assert.equal("Lines naming this device: 4 in 4 scripts; 4 enabled", rows[4])
			assert.is_nil(found(rows, "Stock: device"))
			assert.is_nil(found(rows, "Speed held"))
			assert.is_nil(found(rows, "Stock links"))
			assert.equal(T.not_read, rows[#rows])
		end)

		it("the stock device removed but one old line left: the gone verdict counts it, disabled or not", function()
			local env = new_env({ items = house_items(PHASES.workaround_off) })
			assert.truthy(migration.new(make_api(env)):run())

			local items = house_items(PHASES.removed)
			items[#items + 1] = entry(STOCK_FAN, SPEED_CHANGED, { command(TIMER, "Start the timer", false) }, false)
			env.items = items
			env.devices = project_devices({ no_stock = true })
			local m = migration.new(make_api(env))
			m:restore()
			assert.equal("Stock device 1201 is gone; 1 line still names it", (m:run()))

			items[#items + 1] = entry(BUTTONS, 60, { command(STOCK_LIGHT, "Turn on NAME") })
			assert.equal("Stock device 1201 is gone; 2 lines still name it", (m:run()))
		end)

		it("the stock device removed and no report ever saw it: nothing to migrate", function()
			local env = new_env({ items = house_items(PHASES.removed), devices = project_devices({ no_stock = true }) })
			local m = migration.new(make_api(env))
			local verdict, rows = m:run()
			assert.equal("No stock WAC device in the project; nothing to migrate", verdict)
			assert.same({ verdict, report_row(), T.not_read }, rows)
			assert.equal(0, count(env.calls, "get_all_code_items"), "nothing to count, so nothing read")
		end)

		it("keeps the remembered ids through a later run that finds no stock device", function()
			local env = new_env({ items = house_items(PHASES.workaround_off) })
			migration.new(make_api(env)):run()
			env.devices = project_devices({ no_stock = true })
			env.items = house_items(PHASES.removed)
			local m = migration.new(make_api(env))
			m:restore()
			m:run()
			assert.equal("Stock device 1201 is gone; nothing names it", (m:run()))
			assert.same({ id = 1201, ids = { 1201, 1202, 1203 }, how = "only" }, env.store[migration.KEY].stock)
		end)
	end)

	describe("the stock links (4.3.4, G12)", function()
		it("counts a link once, whichever stock id answers for it", function()
			local env = new_env({
				items = house_items(PHASES.workaround_off),
				bound = { [STOCK .. ":3"] = { [BUTTONS] = "Keypad" }, [STOCK_FAN .. ":3"] = { [BUTTONS] = "Keypad" },
					[STOCK .. ":11"] = { [BUTTONS] = "Keypad" } },
			})
			local m = migration.new(make_api(env))
			local verdict, rows = m:run()
			assert.equal("Stock device 1201: 2 keypad links bound to it; keep it", verdict)
			assert.equal("Stock links bound to keypads: 2 of 12", rows[5])
			assert.equal(36, count(env.calls, "get_bound_consumer_devices"), "12 links on 3 ids")
		end)

		it("does not take the keypad's five buttons bound to the new device's links for stock links", function()
			-- after Phase 3: Low, Medium, Med-High, High and Off on Fan Speed 2, 3, 4, 5 and Fan Off (300 to 305)
			local bound = {}
			for link = 300, 305 do
				bound[NEW .. ":" .. link] = { [BUTTONS] = "Keypad" }
				bound[NEW_FAN .. ":" .. link] = { [BUTTONS] = "Keypad" }
			end
			-- and a keypad bound to something at the same ids elsewhere: only the stock ids are read
			bound[KEYPAD .. ":3"] = { [BUTTONS] = "Keypad" }
			bound[STOCK2 .. ":3"] = { [BUTTONS] = "Keypad" }
			local env = new_env({ items = house_items(PHASES.workaround_off), bound = bound })
			local verdict, rows = migration.new(make_api(env)):run()
			assert.equal("Stock device 1201: nothing enabled names it; safe to remove", verdict)
			assert.equal("Stock links bound to keypads: 0 of 12", rows[5])
		end)

		it("keeps the stock device with enabled lines and links, saying both", function()
			local env = new_env({
				bound = { [STOCK .. ":0"] = { [BUTTONS] = "Keypad" }, [STOCK .. ":1"] = { [BUTTONS] = "Keypad" } },
			})
			local verdict = migration.new(make_api(env)):run()
			assert.equal("Stock device 1201: 22 enabled lines and 2 links; keep it", verdict)
		end)

		it("reads one line and one link in the singular", function()
			local one_line = { entry(BUTTONS, 50, { command(STOCK_FAN, "Set speed on NAME to 2") }) }
			local m = mini(one_line, { bound = { [STOCK .. ":5"] = { [BUTTONS] = "Keypad" } } })
			assert.equal("Stock device 1201: 1 enabled line and 1 link; keep it", (m:run()))
			assert.equal("Stock device 1201: 1 enabled line names it; keep it", (mini(one_line):run()))
			local none = { entry(BUTTONS, 50, { command(STOCK_FAN, "x", false) }) }
			local linked = mini(none, { bound = { [STOCK .. ":5"] = { [BUTTONS] = "Keypad" } } })
			assert.equal("Stock device 1201: 1 keypad link bound to it; keep it", (linked:run()))
		end)

		it("takes an empty table, nil or a non-table as nothing bound", function()
			local env = new_env({
				items = house_items(PHASES.workaround_off),
				bound = { [STOCK .. ":2"] = {}, [STOCK .. ":4"] = 0, [STOCK .. ":6"] = false },
			})
			local verdict = migration.new(make_api(env)):run()
			assert.equal("Stock device 1201: nothing enabled names it; safe to remove", verdict)
		end)
	end)

	describe("finding this fan's stock device (4.2)", function()
		local ONE_LINE = { entry(BUTTONS, 50, { command(STOCK_FAN, "Set speed on NAME to 2") }) }
		local BOTH = function()
			return {
				entry(BUTTONS, 50, { command(STOCK_FAN, "Set speed on NAME to 2") }),
				entry(BUTTONS, 51, { command(STOCK2_FAN, "Set speed on NAME to 4"), command(STOCK2_LIGHT, "Turn on NAME") }),
			}
		end

		it("takes the only one, whatever Stock Device is not", function()
			local m = mini(ONE_LINE)
			local verdict, rows = m:run()
			assert.equal("Stock device 1201: 1 enabled line names it; keep it", verdict)
			assert.equal("Stock: device 1201 in Example Room (the only one)", rows[3])
		end)

		it("takes a stock device set in Stock Device, by its protocol id or either proxy's", function()
			for _, id in ipairs({ "1201", "1202", "1203", " 1201 " }) do
				local m = mini(ONE_LINE, { props = { ["Stock Device"] = id, ["Fan Address"] = "", ["Driver Version"] = "57" } })
				local verdict, rows = m:run()
				assert.equal("Stock device 1201: 1 enabled line names it; keep it", verdict, id)
				assert.equal("Stock: device 1201 in Example Room (set in Stock Device)", rows[3], id)
			end
		end)

		it("fails when Stock Device is not a stock WAC device", function()
			local props = { ["Stock Device"] = "1204", ["Fan Address"] = "", ["Driver Version"] = "57" }
			local m, env = mini(ONE_LINE, { props = props })
			local verdict, rows = m:run()
			assert.equal("Report failed: Stock Device 1204 is not a stock WAC device", verdict)
			assert.same({ verdict, report_row(), "Stock: device 1201 in Example Room (not matched)", T.not_read }, rows)
			assert.equal(0, count(env.calls, "get_all_code_items"))
			-- nor is an id that is no device at all
			env.props["Stock Device"] = "9999"
			assert.equal("Report failed: Stock Device 9999 is not a stock WAC device", (m:run()))
		end)

		it("takes Stock Device text without a number as not set", function()
			for _, text in ipairs({ "", "   ", "abc", "0", "none" }) do
				local m = mini(ONE_LINE, { props = { ["Stock Device"] = text, ["Fan Address"] = "", ["Driver Version"] = "57" } })
				local verdict, rows = m:run()
				assert.equal("Stock device 1201: 1 enabled line names it; keep it", verdict, text)
				assert.equal("Stock: device 1201 in Example Room (the only one)", rows[3], text)
			end
		end)

		it("takes a number-valued Stock Device", function()
			local m = mini(ONE_LINE, { props = { ["Stock Device"] = 1201, ["Fan Address"] = "", ["Driver Version"] = "57" } })
			assert.equal("Stock device 1201: 1 enabled line names it; keep it", (m:run()))
		end)

		it("with several, and no Stock Device, asks for a pick", function()
			local m = mini(BOTH(), { devices = project_devices({ second_stock = true }) })
			local verdict, rows = m:run()
			assert.equal("2 stock WAC devices: pick this fan's in Stock Device", verdict)
			assert.same({
				verdict, report_row(),
				"Stock: device 1201 in Example Room (not matched)",
				"Stock: device 1301 in Second Room (not matched)",
				T.not_read,
			}, rows)
		end)

		it("with several, picks the one whose address is this fan's (a text answer)", function()
			local bindings = {
				[STOCK_FAN] = "networkbindingid: 6001\naddr: 10.0.2.151\nuuid: c4:example\nstatus: online\n"
					.. "ssdptype: c4:example\ndeviceid: 1202\naddresstype: 1",
				[STOCK2_FAN] = "networkbindingid: 6001\naddr: 10.0.2.152\nuuid: c4:example\nstatus: online",
			}
			local m = mini(BOTH(), { devices = project_devices({ second_stock = true }), bindings = bindings })
			local verdict, rows = m:run()
			assert.equal("Stock device 1201: 1 enabled line names it; keep it", verdict)
			assert.equal("Stock: device 1201 in Example Room (same address)", rows[3])
			assert.equal("Stock: device 1301 in Second Room (not this fan's)", rows[4])
		end)

		it("with several, picks by address from a table answer too, and by the other fan's address", function()
			local bindings = {
				[STOCK_FAN] = { { networkbindingid = 6001, addr = "10.0.2.151", status = "online" } },
				[STOCK2_FAN] = { { networkbindingid = 6001, addr = "10.0.2.152", status = "online" } },
			}
			local h = { devices = project_devices({ second_stock = true }), bindings = bindings,
				props = { ["Fan Address"] = "10.0.2.152", ["Stock Device"] = "", ["Driver Version"] = "57" } }
			local m = mini(BOTH(), h)
			local verdict, rows = m:run()
			assert.equal("Stock device 1301: 2 enabled lines name it; keep it", verdict)
			assert.equal("Stock: device 1201 in Example Room (not this fan's)", rows[3])
			assert.equal("Stock: device 1301 in Second Room (same address)", rows[4])
		end)

		it("with several, asks for a pick when the address matches none, both, or is unknown", function()
			local both = { [STOCK_FAN] = "addr: 10.0.2.151", [STOCK2_FAN] = "addr: 10.0.2.151" }
			local none = { [STOCK_FAN] = "addr: 10.0.2.152", [STOCK2_FAN] = "addr: 10.0.2.10" }
			local devices = project_devices({ second_stock = true })
			for name, bindings in pairs({ both = both, none = none, unreadable = {} }) do
				local m = mini(BOTH(), { devices = devices, bindings = bindings })
				assert.equal("2 stock WAC devices: pick this fan's in Stock Device", (m:run()), name)
			end
			local no_address = mini(BOTH(), { devices = devices, bindings = both,
				props = { ["Fan Address"] = "", ["Stock Device"] = "", ["Driver Version"] = "57" } })
			assert.equal("2 stock WAC devices: pick this fan's in Stock Device", (no_address:run()))
			local no_api = mini(BOTH(), { devices = devices, bindings = both }, { get_bindings_by_device = false })
			assert.equal("2 stock WAC devices: pick this fan's in Stock Device", (no_api:run()))
			local raising = mini(BOTH(), { devices = devices, bindings = both },
				{ get_bindings_by_device = function() error("boom") end })
			assert.equal("2 stock WAC devices: pick this fan's in Stock Device", (raising:run()))
		end)

		it("with several, takes Stock Device over the address", function()
			local bindings = { [STOCK_FAN] = "addr: 10.0.2.151", [STOCK2_FAN] = "addr: 10.0.2.152" }
			local h = { devices = project_devices({ second_stock = true }), bindings = bindings,
				props = { ["Stock Device"] = "1302", ["Fan Address"] = "10.0.2.151", ["Driver Version"] = "57" } }
			local m = mini(BOTH(), h)
			local verdict, rows = m:run()
			assert.equal("Stock device 1301: 2 enabled lines name it; keep it", verdict)
			assert.equal("Stock: device 1201 in Example Room (not this fan's)", rows[3])
			assert.equal("Stock: device 1301 in Second Room (set in Stock Device)", rows[4])
			-- the other fan's stock device is no concern of this report: its script is not listed
			assert.equal(1, #script_rows(rows))
			assert.equal("Lines naming device 1301: 2 in 1 script; 2 enabled", found(rows, "Lines naming device"))
		end)

		it("names three stock devices by the count", function()
			local devices = project_devices({ second_stock = true })
			devices[1401] = stock_device(1402, 1403, "Third Room")
			local m = mini(ONE_LINE, { devices = devices })
			assert.equal("3 stock WAC devices: pick this fan's in Stock Device", (m:run()))
		end)

		it("finds no stock device where there is none", function()
			local m = mini(ONE_LINE, { devices = project_devices({ no_stock = true }) })
			assert.equal("No stock WAC device in the project; nothing to migrate", (m:run()))
		end)

		it("finds another version of WAC's file, in any case, and no other driver", function()
			local devices = project_devices({ no_stock = true })
			devices[STOCK] = stock_device(STOCK_FAN, STOCK_LIGHT, "Example Room")
			devices[STOCK].driverFileName = "WAC_MF_Fan_And_Light_Controller(v5).c4z"
			local m = mini(ONE_LINE, { devices = devices })
			assert.equal("Stock device 1201: 1 enabled line names it; keep it", (m:run()))

			-- a fresh instance each time: a run that saw a stock device remembers it (4.6)
			for _, other in ipairs({ "modernforms_fan.c4z", "combo_dimmer.c4i", false }) do
				devices[STOCK].driverFileName = other or nil
				local fresh = mini(ONE_LINE, { devices = devices })
				assert.equal("No stock WAC device in the project; nothing to migrate", (fresh:run()), tostring(other))
			end
		end)

		it("shows a stock device without a room by its id alone", function()
			local devices = project_devices()
			devices[STOCK].roomName = nil
			local _, rows = mini(ONE_LINE, { devices = devices }):run()
			assert.equal("Stock: device 1201 (the only one)", rows[3])
		end)

		it("clears a dangling Stock Device through the remembered ids, else fails it", function()
			local env = new_env({ items = house_items(PHASES.workaround_off) })
			migration.new(make_api(env)):run()
			env.devices = project_devices({ no_stock = true })
			env.items = house_items(PHASES.removed)
			env.props["Stock Device"] = "1201" -- the device was deleted with the property still set
			local m = migration.new(make_api(env))
			m:restore()
			assert.equal("Stock device 1201 is gone; nothing names it", (m:run()))
			env.props["Stock Device"] = "9999"
			assert.equal("Report failed: Stock Device 9999 is not a stock WAC device", (m:run()))
		end)
	end)

	describe("reading the programming (4.3)", function()
		local function run_rows(items, h, overrides)
			local m = mini(items, h, overrides)
			local verdict, rows = m:run()
			return verdict, rows, m
		end

		it("sorts a line into old, new or other by its device", function()
			local items = { entry(BUTTONS, 50, {
				command(STOCK_FAN, "a"), command(STOCK, "b"), command(STOCK_LIGHT, "c"),
				command(NEW_FAN, "d"), command(NEW_LIGHT, "e"), command(NEW, "f"),
				command(BUTTONS, "g"), command(0, "h"), command(99, "i"),
			}) }
			local _, rows = run_rows(items)
			assert.same({ "Example Room Keypad " .. ARROW .. " event 50: old 3/3 " .. DOT .. " new 3/3 " .. DOT
				.. " other 3/3" }, script_rows(rows))
			assert.equal("Lines naming device 1201: 3 in 1 script; 3 enabled", rows[6])
			assert.equal("Lines naming this device: 3 in 1 script; 3 enabled", rows[7])
			assert.equal("Other lines still on in scripts naming it: 3", rows[8])
		end)

		it("counts everything under a stock device's event as old: it runs because of that device", function()
			local items = { entry(STOCK_FAN, 7, {
				command(TIMER, "Start the timer"), command(NEW_FAN, "x"), command(0, "y"), command(BUTTONS, "z"),
			}) }
			local _, rows = run_rows(items)
			assert.same({ "Example Room Fan " .. ARROW .. " event 7: old 4/4" }, script_rows(rows))
			assert.equal("Lines naming this device: 0 in 0 scripts; 0 enabled", rows[7])
		end)

		it("leaves out a script that holds neither an old nor a new line, and its other lines", function()
			local items = {
				entry(BUTTONS, 50, { command(BUTTONS, "an LED line"), command(99, "x") }),
				entry(BUTTONS, 51, { command(STOCK_FAN, "old") }),
			}
			local _, rows = run_rows(items)
			assert.equal(1, #script_rows(rows))
			assert.equal("Other lines still on in scripts naming it: 0", rows[8])
		end)

		it("leaves out an empty script", function()
			local verdict, rows = run_rows({ entry(BUTTONS, 50, {}), entry(STOCK_FAN, 7, {}) })
			assert.equal("Stock device 1201: nothing enabled names it; safe to remove", verdict)
			assert.same({}, script_rows(rows))
		end)

		it("counts commands, conditions and loops, and walks through containers, else, comments and operators", function()
			local items = { entry(BUTTONS, 50, {
				condition(STOCK_FAN, "If NAME speed is 2", {
					command(STOCK_FAN, "Set speed on NAME to 1"),
					loop(STOCK_FAN, "Repeat on NAME", { command(NEW_FAN, "Set speed on NAME to 6") }),
					comment(STOCK_FAN, "a note that names the stock fan"),
					operator(STOCK_FAN, "AND"),
				}),
				otherwise({ command(STOCK_LIGHT, "Turn off NAME") }),
				container({ command(STOCK_LIGHT, "Turn on NAME") }),
			}) }
			local _, rows = run_rows(items)
			-- old: the If, its command, the loop, the else's command, the container's command = 5; new: 1
			assert.same({ "Example Room Keypad " .. ARROW .. " event 50: old 5/5 " .. DOT .. " new 1/1" },
				script_rows(rows))
		end)

		it("counts a line as enabled only if every item above it up to the event's root is", function()
			local items = {
				-- a disabled If: it and its enabled child are off; an enabled If with a disabled child: 1 of 2
				entry(BUTTONS, 50, {
					condition(STOCK_FAN, "If NAME speed is 2", { command(STOCK_FAN, "child") }, false),
					condition(STOCK_FAN, "If NAME speed is 3", { command(STOCK_FAN, "child", false) }),
				}),
				-- a disabled else branch and a disabled container
				entry(BUTTONS, 51, {
					otherwise({ command(STOCK_FAN, "in else") }, false),
					container({ command(STOCK_FAN, "in container") }, false),
					command(STOCK_FAN, "plain"),
				}),
				-- a disabled root: Disable Event
				entry(BUTTONS, 52, { command(STOCK_FAN, "one"), command(STOCK_FAN, "two") }, false),
				-- deeper: a disabled loop in an enabled If
				entry(BUTTONS, 53, { condition(STOCK_FAN, "If", {
					loop(STOCK_FAN, "Loop", { condition(STOCK_FAN, "Inner", { command(STOCK_FAN, "deep") }) }, false),
				}) }),
			}
			local verdict, rows = run_rows(items)
			local K = "Example Room Keypad " .. ARROW .. " event "
			assert.same({
				K .. "50: old 1/4",
				K .. "51: old 1/3",
				K .. "52: old 0/2",
				K .. "53: old 1/4",
			}, (function()
				local list = script_rows(rows)
				table.sort(list, function(a, b) return a:match("event (%d+)") + 0 < b:match("event (%d+)") + 0 end)
				return list
			end)())
			assert.equal("Stock device 1201: 3 enabled lines name it; keep it", verdict)
			assert.equal("Lines naming device 1201: 13 in 4 scripts; 3 enabled", rows[6])
		end)

		it("reads ids, types and flags given as text, as the API's printed dump suggests", function()
			local line = mk("1", "1202", "Set speed on NAME to 2", nil, nil)
			line.enabled = "true"
			local off = mk("1", "1202", "Another", nil, nil)
			off.enabled = "false"
			local zero = mk("1", "1202", "A third", nil, nil)
			zero.enabled = 0
			local item = entry("1212", "50", { line, off, zero })
			local _, rows = run_rows({ item })
			assert.same({ "Example Room Keypad " .. ARROW .. " event 50: old 1/3" }, script_rows(rows))
		end)

		it("takes a missing enabled flag as enabled", function()
			local line = command(STOCK_FAN, "x")
			line.enabled = nil
			local item = entry(BUTTONS, 50, { line })
			item.codeitem.enabled = nil
			assert.equal("Stock device 1201: 1 enabled line names it; keep it", (run_rows({ item })))
		end)

		it("reads an answer without the event_mgr wrapper and a codeitem that is a list of roots", function()
			local plain = entry(BUTTONS, 50, { command(STOCK_FAN, "x") })
			local env = new_env({ items = {} })
			local bare = migration.new(make_api(env, { get_all_code_items = function() return { plain } end }))
			assert.equal("Stock device 1201: 1 enabled line names it; keep it", (bare:run()))

			local listed = entry(BUTTONS, 50, nil)
			listed.codeitem = { entry(BUTTONS, 0, { command(STOCK_FAN, "x"), command(STOCK_FAN, "y") }).codeitem }
			local m = mini({ listed })
			assert.equal("Stock device 1201: 2 enabled lines name it; keep it", (m:run()))
		end)

		it("reads item lists with holes, ids or names for keys, and skips what is not a table", function()
			local holes = entry(BUTTONS, 50, nil)
			holes.codeitem.subitems = { [1] = command(STOCK_FAN, "a"), [3] = command(STOCK_FAN, "b"),
				[10] = command(STOCK_FAN, "c") }
			local keyed = entry(BUTTONS, 51, nil)
			keyed.codeitem.subitems = { [7] = command(STOCK_FAN, "a"), first = command(STOCK_FAN, "b"),
				[2] = command(STOCK_FAN, "c") }
			local junk = entry(BUTTONS, 52, { command(STOCK_FAN, "a"), "text", 5, command(STOCK_FAN, "b") })
			local _, rows = run_rows({ holes, keyed, junk })
			local K = "Example Room Keypad " .. ARROW .. " event "
			local list = script_rows(rows)
			table.sort(list)
			assert.same({ K .. "50: old 3/3", K .. "51: old 3/3", K .. "52: old 2/2" }, list)
		end)

		it("takes the lines of a keyed list in key order, ids before names", function()
			local keyed = entry(BUTTONS, 51, nil)
			keyed.codeitem.subitems = { z = command(STOCK_FAN, "from z"), [7] = command(STOCK_FAN, "from 7"),
				a = command(STOCK_FAN, "from a"), [2] = command(STOCK_FAN, "from 2") }
			local _, rows = run_rows({ keyed })
			local _, at = found(rows, "Example Room Keypad " .. ARROW .. " event 51")
			assert.equal("  first: from 2", rows[at + 1])
			assert.same({ "  on: from 2", "  on: from 7", "  on: from a", "  on: from z" },
				{ rows[at + 2], rows[at + 3], rows[at + 4], rows[at + 5] })
		end)

		it("reads an empty project as nothing to count", function()
			local env = new_env({ items = {} })
			local m = migration.new(make_api(env, { get_all_code_items = function() return { event_mgr = {} } end }))
			assert.equal("Stock device 1201: nothing enabled names it; safe to remove", (m:run()))
			local bare = migration.new(make_api(env, { get_all_code_items = function() return {} end }))
			assert.equal("Stock device 1201: nothing enabled names it; safe to remove", (bare:run()))
		end)

		it("shows the first new line when a script has no old one", function()
			local items = { entry(BUTTONS, 50, {
				command(BUTTONS, "an LED line"), command(NEW_FAN, "Set speed on NAME to 6"),
			}) }
			local _, rows = run_rows(items)
			local _, at = found(rows, "Example Room Keypad " .. ARROW .. " event 50")
			assert.equal("Example Room Keypad " .. ARROW .. " event 50: new 1/1 " .. DOT .. " other 1/1", rows[at])
			assert.equal("  first: Set speed on Example Room->Fan (new) to 6", rows[at + 1])
			assert.equal(T.not_read, rows[at + 2], "no old line, so no on: rows")
		end)

		it("shows at most five enabled old lines, then how many more", function()
			local lines = {}
			for n = 1, 7 do
				lines[n] = command(STOCK_FAN, "Set speed on NAME to " .. n, n ~= 2)
			end
			local _, rows = run_rows({ entry(BUTTONS, 50, lines) })
			local _, at = found(rows, "Example Room Keypad " .. ARROW .. " event 50")
			assert.equal("Example Room Keypad " .. ARROW .. " event 50: old 6/7", rows[at])
			assert.equal("  first: Set speed on Example Room->Fan to 1", rows[at + 1])
			local wanted = { 1, 3, 4, 5, 6 }
			for i, n in ipairs(wanted) do
				assert.equal("  on: Set speed on Example Room->Fan to " .. n, rows[at + 1 + i])
			end
			assert.equal("  on: " .. ELLIPSIS .. " and 1 more", rows[at + 7])
		end)

		it("lists the first 40 scripts and counts the rest in row 13", function()
			local items = {}
			for n = 1, 45 do
				items[n] = entry(BUTTONS, 100 + n, { command(STOCK_FAN, "Set speed on NAME to 2") })
			end
			local _, rows = run_rows(items)
			assert.equal(40, #script_rows(rows))
			assert.equal(ELLIPSIS .. " 5 more scripts; the Lua tab lists all by id", rows[#rows - 1])
			assert.equal(T.not_read, rows[#rows])
			assert.equal("Lines naming device 1201: 45 in 45 scripts; 45 enabled", rows[6])

			table.remove(items)
			table.remove(items)
			table.remove(items)
			table.remove(items)
			local _, one_more = run_rows(items)
			assert.equal(ELLIPSIS .. " 1 more script; the Lua tab lists all by id", one_more[#one_more - 1])

			table.remove(items)
			local _, exactly = run_rows(items)
			assert.equal(40, #script_rows(exactly))
			assert.is_nil(found(exactly, ELLIPSIS .. " "))
		end)

		it("orders the scripts with an enabled old line first, then by device and event", function()
			local items = {
				entry(BUTTONS, 90, { command(STOCK_FAN, "off", false) }),
				entry(BUTTONS, 20, { command(STOCK_FAN, "on") }),
				entry(STOCK_FAN, 5, { command(TIMER, "on") }),
				entry(BUTTONS, 10, { command(STOCK_FAN, "on") }),
				entry(BUTTONS, 15, { command(STOCK_FAN, "off", false) }),
			}
			local _, rows = run_rows(items)
			local K = "Example Room Keypad " .. ARROW .. " event "
			assert.same({
				"Example Room Fan " .. ARROW .. " event 5: old 1/1",
				K .. "10: old 1/1",
				K .. "20: old 1/1",
				K .. "15: old 0/1",
				K .. "90: old 0/1",
			}, script_rows(rows))
		end)

		it("is not misled by an event that appears twice, or a nesting too deep to be real", function()
			local deep = command(STOCK_FAN, "deep")
			for _ = 1, 200 do
				deep = container({ deep })
			end
			local items = {
				entry(BUTTONS, 50, { command(STOCK_FAN, "x") }),
				entry(BUTTONS, 50, { command(STOCK_FAN, "y") }),
				entry(BUTTONS, 51, { deep, command(STOCK_FAN, "z") }),
			}
			local verdict, rows = run_rows(items)
			assert.equal("Stock device 1201: 3 enabled lines name it; keep it", verdict)
			assert.equal(3, #script_rows(rows))
		end)
	end)

	describe("rows (4.4)", function()
		local function all_rows(items, h)
			local _, rows = mini(items, h):run()
			return rows
		end

		it("keeps every row under 70 characters, cutting rooms, device names and line texts with an ellipsis", function()
			local devices = project_devices()
			devices[KEYPAD].proxies[BUTTONS].deviceName = string.rep("D", 80)
			devices[KEYPAD].roomName = "Room " .. string.rep("R", 40)
			devices[STOCK].roomName = "Stock " .. string.rep("S", 40)
			local text = string.rep("long text ", 30)
			local rows = all_rows({ entry(BUTTONS, 12, { command(STOCK_FAN, text), command(STOCK_FAN, text) }) },
				{ devices = devices })
			for _, row in ipairs(rows) do
				assert.is_true(ulen(row) <= 69, row)
			end
			local room = "Room " .. string.rep("R", 16) .. ELLIPSIS -- 22 characters
			assert.equal("Stock: device 1201 in Stock " .. string.rep("S", 15) .. ELLIPSIS .. " (the only one)", rows[3])
			local label = found(rows, room)
			assert.truthy(label)
			assert.equal(69, ulen(label))
			assert.equal("  first: " .. text:sub(1, 59) .. ELLIPSIS, found(rows, "  first: "))
			assert.equal("  on: " .. text:sub(1, 62) .. ELLIPSIS, found(rows, "  on: "))
		end)

		it("never cuts a device name below 12 characters", function()
			local devices = project_devices()
			devices[KEYPAD].proxies[BUTTONS].deviceName = string.rep("N", 50)
			devices[KEYPAD].roomName = nil
			local lines = {}
			for _ = 1, 120 do
				lines[#lines + 1] = command(STOCK_FAN, "old")
				lines[#lines + 1] = command(NEW_FAN, "new")
				lines[#lines + 1] = command(BUTTONS, "other")
			end
			local rows = all_rows({ entry(BUTTONS, 1234567, lines) }, { devices = devices })
			local label = script_rows(rows)[1]
			assert.equal(string.rep("N", 11) .. ELLIPSIS .. " " .. ARROW .. " event 1234567: old 120/120 " .. DOT
				.. " new 120/120 " .. DOT .. " other 120/120", label)
		end)

		it("cuts by characters, never inside a UTF-8 sequence", function()
			local devices = project_devices()
			devices[KEYPAD].proxies[BUTTONS].deviceName = string.rep("\195\169", 60)
			devices[KEYPAD].roomName = string.rep("\226\130\172", 30)
			local text = string.rep("\195\188", 100)
			local rows = all_rows({ entry(BUTTONS, 12, { command(STOCK_FAN, text) }) }, { devices = devices })
			for _, row in ipairs(rows) do
				assert.is_true(valid_utf8(row), row)
				assert.is_true(ulen(row) <= 69, row)
			end
			assert.equal(string.rep("\226\130\172", 21) .. ELLIPSIS .. " " .. string.rep("\195\169", 25) .. ELLIPSIS
				.. " " .. ARROW .. " event 12: old 1/1", script_rows(rows)[1])
		end)

		it("holds no comma in any row: a comma in a name or a text is drawn as U+201A", function()
			local devices = project_devices()
			devices[KEYPAD].proxies[BUTTONS].deviceName = "Keypad, Hall"
			devices[KEYPAD].roomName = "Example Room, North"
			devices[STOCK].roomName = "Room, with comma"
			local rows = all_rows({ entry(BUTTONS, 12, { command(STOCK_FAN, "Set speed, then wait on NAME") }) },
				{ devices = devices })
			for _, row in ipairs(rows) do
				assert.is_nil(row:find(",", 1, true), row)
			end
			assert.equal("Stock: device 1201 in Room" .. COMMA .. " with comma (the only one)", rows[3])
			assert.truthy(found(rows, "Example Room" .. COMMA .. " North Keypad" .. COMMA .. " Hall " .. ARROW))
			assert.truthy(found(rows, "  first: Set speed" .. COMMA .. " then wait on Room" .. COMMA .. " with comma->Fan"))
		end)

		it("takes a newline or tab in a text as one space", function()
			local rows = all_rows({ entry(BUTTONS, 12, { command(STOCK_FAN, "Set\nspeed\ton\r\nNAME") }) })
			assert.equal("  first: Set speed on Example Room->Fan", found(rows, "  first: "))
		end)

		it("fills the NAME macro with Room->Name, the whole word only", function()
			local rows = all_rows({ entry(BUTTONS, 12, { command(STOCK_FAN, "NAME is not RENAME or NAMES; NAME.") }) })
			assert.equal("  first: Example Room->Fan is not RENAME or NAMES; Example Room->Fan.", found(rows, "  first: "))
		end)

		it("falls back to the kind of line when the text is empty, and to device <id> for an unknown device", function()
			local rows = all_rows({
				entry(BUTTONS, 12, { command(STOCK_FAN, ""), condition(STOCK_FAN, "", {}), loop(STOCK_FAN, nil, {}) }),
				entry(77, 13, { command(STOCK_FAN, "Turn on NAME"), command(88, "NAME") }),
			})
			assert.equal("  first: command", found(rows, "  first: command"))
			local _, at = found(rows, "device 77 " .. ARROW .. " event 13")
			assert.truthy(at)
			-- the unknown event device is named by its id; the line's own device is the stock fan
			assert.equal("  first: Turn on Example Room->Fan", rows[at + 1])
		end)

		it("names a line's unknown device by id in its text", function()
			local item = entry(BUTTONS, 12, { command(STOCK_FAN, "x") })
			item.codeitem.subitems[1].display = "Do NAME"
			item.codeitem.subitems[1].device = 88
			-- 88 names no stock id, so the script has no old line; make the event the stock fan's
			item.deviceid = STOCK_FAN
			local rows = all_rows({ item })
			assert.equal("  first: Do device 88", found(rows, "  first: "))
		end)

		it("shows a build from Driver Version, from api.build, or a question mark", function()
			local items = { entry(BUTTONS, 12, { command(STOCK_FAN, "x") }) }
			local _, rows = mini(items):run()
			assert.equal(report_row("57"), rows[2])
			local _, with_build = mini(items, nil, { build = function() return 58 end }):run()
			assert.equal(report_row("58"), with_build[2])
			local h = { props = { ["Fan Address"] = "", ["Stock Device"] = "" } }
			local _, unknown = mini(items, h):run()
			assert.equal(report_row("?"), unknown[2])
		end)

		it("takes the time from now() in seconds or milliseconds, else from the system clock", function()
			local items = { entry(BUTTONS, 12, { command(STOCK_FAN, "x") }) }
			local _, seconds = mini(items):run()
			assert.equal(report_row(), seconds[2])
			local _, millis = mini(items, nil, { now = function() return CLOCK * 1000 end }):run()
			assert.equal(report_row(), millis[2])
			for _, now in ipairs({ function() return 5 end, function() error("no clock") end, function() return "x" end }) do
				local _, rows = mini(items, nil, { now = now }):run()
				assert.truthy(rows[2]:match("^Report of %d%d%d%d%-%d%d%-%d%d %d%d:%d%d by build 57; it changed nothing$"),
					rows[2])
			end
			local _, absent = mini(items, nil, { now = false }):run()
			assert.truthy(absent[2]:match("^Report of %d%d%d%d%-%d%d%-%d%d %d%d:%d%d by build 57"))
		end)
	end)

	describe("the speeds (row 4, G13)", function()
		local ITEMS = { entry(BUTTONS, 12, { command(STOCK_FAN, "x") }) }

		it("shows the speed the stock fan holds beside this fan's; 0 is off", function()
			local h = { vars = default_vars() }
			h.vars[STOCK_FAN]["1001"].value = "0"
			h.vars[NEW_FAN]["1001"].value = "5"
			local _, rows = mini(ITEMS, h):run()
			assert.equal("Speed held by the stock fan: 0; by this fan: 5", rows[4])
		end)

		it("says unknown when the variable is not found, or cannot be read", function()
			local h = { vars = {} }
			local _, rows = mini(ITEMS, h):run()
			assert.equal("Speed held by the stock fan: unknown; by this fan: unknown", rows[4])
			local verdict = mini(ITEMS, h):run()
			assert.equal("Stock device 1201: 1 enabled line names it; keep it", verdict)

			local raising = { get_device_variables = function() error("boom") end }
			local _, raised = mini(ITEMS, nil, raising):run()
			assert.equal("Speed held by the stock fan: unknown; by this fan: unknown", raised[4])
			local _, absent = mini(ITEMS, nil, { get_device_variables = false }):run()
			assert.equal("Speed held by the stock fan: unknown; by this fan: unknown", absent[4])
		end)

		it("says unknown for a value that is not a number", function()
			local h = { vars = default_vars() }
			h.vars[STOCK_FAN]["1001"].value = ""
			h.vars[NEW_FAN]["1001"].value = "fast"
			local _, rows = mini(ITEMS, h):run()
			assert.equal("Speed held by the stock fan: unknown; by this fan: unknown", rows[4])
		end)

		it("reads CURRENT_SPEED in the shape GetDeviceVariables gave on the house (M1, #35)", function()
			local h = { vars = {
				[STOCK_FAN] = {
					["1000"] = { name = "IS_ON", value = "1", type = "4", readonly = "False", hidden = "False" },
					["1001"] = { name = "CURRENT_SPEED", value = "2", type = "4", readonly = "False" },
					["1002"] = { name = "IS_REVERSED", value = "0" },
					["1003"] = { name = "PRESET_SPEED", value = "3" },
				},
				[NEW_FAN] = { ["1001"] = { name = "CURRENT_SPEED", value = "0" } } } }
			local _, rows = mini(ITEMS, h):run()
			assert.equal("Speed held by the stock fan: 2; by this fan: 0", rows[4])
		end)

		it("prefers CURRENT_SPEED over the display name when both are there", function()
			local h = { vars = { [STOCK_FAN] = {
				["1001"] = { name = "Current Selected Speed", value = "5" },
				["1002"] = { name = "CURRENT_SPEED", value = "1" } } } }
			local _, rows = mini(ITEMS, h):run()
			assert.truthy(rows[4]:find("stock fan: 1;", 1, true), rows[4])
		end)

		it("reads the variable from whichever stock proxy carries it, and from tables keyed by name", function()
			local h = { vars = { [STOCK_LIGHT] = { ["1"] = { name = "LIGHT_LEVEL", value = "1" } },
				[STOCK_FAN] = { ["Current Selected Speed"] = { value = 4 } },
				[NEW_FAN] = { ["Current Selected Speed"] = "2" } } }
			local _, rows = mini(ITEMS, h):run()
			assert.equal("Speed held by the stock fan: 4; by this fan: 2", rows[4])
		end)

		it("takes this fan's shown speed from the coordinator when it gives one", function()
			local _, rows = mini(ITEMS, nil, { shown_speed = function() return 6 end }):run()
			assert.equal("Speed held by the stock fan: 3; by this fan: 6", rows[4])
			local _, off = mini(ITEMS, nil, { shown_speed = function() return 0 end }):run()
			assert.equal("Speed held by the stock fan: 3; by this fan: 0", off[4])
			local _, nothing = mini(ITEMS, nil, { shown_speed = function() return nil end }):run()
			assert.equal("Speed held by the stock fan: 3; by this fan: 3", nothing[4], "then the proxy's variable")
		end)
	end)

	describe("failing soft (4.5, 4.7)", function()
		local ITEMS = { entry(BUTTONS, 12, { command(STOCK_FAN, "x") }) }

		local function failed(overrides, h)
			local m, env = mini(ITEMS, h, overrides)
			local verdict, rows
			assert.has_no.errors(function() verdict, rows = m:run() end)
			return verdict, rows, env, m
		end

		it("says so when this OS has no GetAllCodeItems", function()
			local verdict, rows = failed({ get_all_code_items = false })
			assert.equal("Report failed: this OS has no GetAllCodeItems (needs 3.3.0)", verdict)
			assert.same({
				verdict, report_row(), "Stock: device 1201 in Example Room (not matched)", T.not_read,
			}, rows)
		end)

		it("takes the error of calling a missing method as the same thing", function()
			local verdict = failed({ get_all_code_items = function()
				error("attempt to call method 'GetAllCodeItems' (a nil value)")
			end })
			assert.equal("Report failed: this OS has no GetAllCodeItems (needs 3.3.0)", verdict)
		end)

		it("fails any other error, a nil, a non-table and a table without events as unreadable programming", function()
			local cases = {
				raising = function() error("director is busy") end,
				nothing = function() return nil end,
				text = function() return "not a table" end,
				number = function() return 42 end,
				junk = function() return { 1, 2, { foo = "bar" } } end,
				wrapped_junk = function() return { something = "else" } end,
			}
			for name, fn in pairs(cases) do
				local verdict, _, env = failed({ get_all_code_items = fn })
				assert.equal("Report failed: reading the programming failed; see the Lua tab", verdict, name)
				assert.is_true(#levels(env, "error") >= 1, name)
			end
		end)

		it("logs why the programming could not be read, as an error", function()
			local _, _, env = failed({ get_all_code_items = function() error("director is busy") end })
			local errors = levels(env, "error")
			assert.equal(1, #errors)
			assert.truthy(errors[1]:find("director is busy", 1, true))
		end)

		it("fails when the project's devices cannot be read", function()
			local cases = {
				absent = false,
				raising = function() error("boom") end,
				nothing = function() return nil end,
				text = function() return "devices" end,
			}
			for name, fn in pairs(cases) do
				local verdict, rows = failed({ get_devices = fn })
				assert.equal("Report failed: reading the project's devices failed; see the Lua tab", verdict, name)
				assert.same({ verdict, report_row(), T.not_read }, rows, name)
			end
		end)

		it("fails when the stock links cannot be read, and never says safe to remove then", function()
			local verdict, rows = failed({ get_bound_consumer_devices = false })
			assert.equal("Report failed: reading the stock links failed; see the Lua tab", verdict)
			assert.equal(T.not_read, rows[#rows])
			local all = failed({ get_bound_consumer_devices = function() error("boom") end })
			assert.equal("Report failed: reading the stock links failed; see the Lua tab", all)
		end)

		it("goes on when only some stock ids cannot answer for their links", function()
			local env = new_env({ items = house_items(PHASES.workaround_off) })
			local api = make_api(env, { get_bound_consumer_devices = function(id)
				if id == STOCK_LIGHT then
					error("not a link provider")
				end
				return nil
			end })
			local verdict = migration.new(api):run()
			assert.equal("Stock device 1201: nothing enabled names it; safe to remove", verdict)
		end)

		it("goes on without this device's ids, counting its lines as other, with a warning", function()
			local items = { entry(BUTTONS, 12, { command(STOCK_FAN, "x"), command(NEW_FAN, "y") }) }
			local m, env = mini(items, nil, { get_device_id = false, get_proxy_devices = function() error("boom") end })
			local verdict, rows = m:run()
			assert.equal("Stock device 1201: 1 enabled line names it; keep it", verdict)
			assert.equal("Example Room Keypad " .. ARROW .. " event 12: old 1/1 " .. DOT .. " other 1/1",
				script_rows(rows)[1])
			assert.equal(1, #levels(env, "warn"))
		end)

		it("reads this device's ids however GetProxyDevices answers", function()
			local items = { entry(BUTTONS, 12, { command(STOCK_FAN, "x"), command(NEW_FAN, "y"), command(NEW_LIGHT, "z") }) }
			local shapes = {
				numbers = function() return NEW_FAN, NEW_LIGHT end,
				array = function() return { NEW_FAN, NEW_LIGHT } end,
				by_binding = function() return { [5001] = NEW_FAN, [5002] = NEW_LIGHT } end,
				by_id = function() return { [NEW_FAN] = "Fan", [NEW_LIGHT] = "Light" } end,
			}
			for name, fn in pairs(shapes) do
				local _, rows = mini(items, nil, { get_proxy_devices = fn }):run()
				assert.equal("Example Room Keypad " .. ARROW .. " event 12: old 1/1 " .. DOT .. " new 2/2",
					script_rows(rows)[1], name)
			end
			local only_device = mini(items, nil, { get_proxy_devices = false, get_device_id = function() return NEW_FAN end })
			local _, rows = only_device:run()
			assert.equal("Example Room Keypad " .. ARROW .. " event 12: old 1/1 " .. DOT .. " new 1/1 " .. DOT
				.. " other 1/1", script_rows(rows)[1])
		end)

		it("goes on without a store, a log, a clock, a property reader or a list writer", function()
			local m = mini(ITEMS, nil, { store = false, log = false, now = false, property = false, update_list = false })
			local verdict
			assert.has_no.errors(function() verdict = m:run() end)
			assert.equal("Stock device 1201: 1 enabled line names it; keep it", verdict)
			assert.has_no.errors(function()
				m:restore()
				m:stock_device_changed()
				m:snap_back()
			end)
		end)

		it("warns, and still answers, when the result cannot be kept or the list cannot be written", function()
			local m, env = mini(ITEMS, nil, {
				update_list = function() error("no list") end,
			})
			assert.equal("Stock device 1201: 1 enabled line names it; keep it", (m:run()))
			local broken = new_env({ items = ITEMS })
			local api = make_api(broken, {
				store = { get = function() end, set = function() error("disk full") end },
			})
			local second = migration.new(api)
			assert.equal("Stock device 1201: 1 enabled line names it; keep it", (second:run()))
			assert.is_true(#levels(env, "warn") >= 1)
			assert.is_true(#levels(broken, "warn") >= 1)
		end)

		it("logs through a plain function when that is the log it is given", function()
			local lines = {}
			local env = new_env({ items = ITEMS })
			local m = migration.new(make_api(env, { log = function(line) lines[#lines + 1] = line end }))
			m:run()
			assert.equal(1, #lines)
			assert.truthy(lines[1]:find("Stock device 1201", 1, true))
		end)

		it("never raises, whatever every function does", function()
			local boom = function() error("boom") end
			local hostile = {
				get_devices = boom, get_all_code_items = boom, get_device_variables = boom,
				get_bindings_by_device = boom, get_bound_consumer_devices = boom, get_device_display_name = boom,
				get_device_id = boom, get_proxy_devices = boom, property = boom, now = boom, build = boom,
				shown_speed = boom, update_list = boom,
				log = { error = boom, warn = boom, info = boom, debug = boom, always = boom },
				store = { get = boom, set = boom },
			}
			local m = migration.new(hostile)
			local verdict, rows
			assert.has_no.errors(function() verdict, rows = m:run() end)
			assert.equal("Report failed: reading the project's devices failed; see the Lua tab", verdict)
			assert.equal(verdict, rows[1])
			assert.has_no.errors(function()
				m:restore()
				m:stock_device_changed()
				m:snap_back()
				m:rows()
				m:verdict()
				m:last()
			end)
		end)

		it("fails an unexpected error as unreadable programming, logs it, and keeps what it remembered", function()
			local env = new_env({ items = house_items(PHASES.workaround_off) })
			local m = migration.new(make_api(env))
			m:run()
			-- a device entry that raises when it is read: nothing in the report guards against that
			local trap = setmetatable({}, { __index = function() error("trap sprung") end })
			env.devices = { [1500] = trap }
			local verdict, rows
			assert.has_no.errors(function() verdict, rows = m:run() end)
			assert.equal("Report failed: reading the programming failed; see the Lua tab", verdict)
			assert.equal(verdict, rows[1])
			assert.equal(T.not_read, rows[#rows])
			local errors = levels(env, "error")
			assert.equal(1, #errors)
			assert.truthy(errors[1]:find("trap sprung", 1, true))
			assert.equal(verdict, env.store[migration.KEY].verdict)
			assert.equal(1201, env.store[migration.KEY].stock.id, "the stock ids stay remembered")
		end)

		it("does not call the list writer again from inside it", function()
			local env = new_env({ items = ITEMS })
			local m
			local calls = 0
			local api = make_api(env, { update_list = function()
				calls = calls + 1
				m:snap_back() -- what OnPropertyChanged("Migration") would do, if the list update raised it
			end })
			m = migration.new(api)
			m:run()
			assert.equal(1, calls)
			m:snap_back()
			assert.equal(2, calls)
		end)

		it("never raises on answers of the wrong shape", function()
			local junk = {
				get_devices = function()
					return { [STOCK] = "text", [true] = {}, [1201.5] = {}, abc = { driverFileName = STOCK_FILE },
						[1500] = { driverFileName = STOCK_FILE, proxies = "none", roomName = {} },
						[1501] = { driverFileName = STOCK_FILE, proxies = { x = 1, [1502] = "nope" } } }
				end,
				get_all_code_items = function()
					return { event_mgr = { "x", 5, { codeitem = "y" }, { codeitem = { subitems = "z" } },
						{ deviceid = {}, eventid = {}, codeitem = { subitems = { 1, "a", {}, { subitems = 5, type = {} } } } },
						{ deviceid = 1500, eventid = 1, codeitem = { subitems = { { type = 1, device = {}, display = 7 } } } } } }
				end,
				get_device_variables = function() return { "a", 1, { name = {} }, [{}] = 5 } end,
				get_bindings_by_device = function() return { {}, "x", 7 } end,
				get_bound_consumer_devices = function() return "yes" end,
				get_device_display_name = function() return {} end,
				get_device_id = function() return {} end,
				get_proxy_devices = function() return "a", "b" end,
				property = function() return {} end,
			}
			local m = migration.new(junk)
			local verdict
			assert.has_no.errors(function() verdict = m:run() end)
			assert.is_string(verdict)
			assert.is_true(#m:rows() >= 2)
		end)
	end)

	describe("persistence (4.6)", function()
		it("keeps one value per run: the time, build, ids, readings, counts, verdict and rows", function()
			local m, env = house("start")
			local verdict, rows = m:run()
			local stored = env.store[migration.KEY]
			assert.equal("mf_migration", migration.KEY)
			assert.same({
				v = 1,
				at = CLOCK,
				build = "57",
				setting = 0,
				verdict = verdict,
				rows = rows,
				stock = { id = 1201, ids = { 1201, 1202, 1203 }, how = "only" },
				speeds = { stock = 3, this = 3 },
				counts = {
					old = { lines = 22, scripts = 11, on = 22 },
					new = { lines = 0, scripts = 0, on = 0 },
					other_on = 89,
					links = { bound = 0, total = 12 },
				},
			}, stored)
			assert.equal(1, count(env.calls, "store.set"))
			assert.same(stored, m:last())
			assert.same({}, levels(env, "warn"), "a plain table of numbers, strings and booleans")
		end)

		it("remembers how the stock device was matched, and the Stock Device used", function()
			local env = new_env({ items = house_items(PHASES.start), props = { ["Stock Device"] = "1203", ["Fan Address"] = "",
				["Driver Version"] = "57" } })
			migration.new(make_api(env)):run()
			assert.equal("set", env.store[migration.KEY].stock.how)
			assert.equal(1203, env.store[migration.KEY].setting)
		end)

		it("keeps a failed run too, with the stock ids of the last run that found one", function()
			local env = new_env({ items = house_items(PHASES.start) })
			local m = migration.new(make_api(env))
			m:run()
			env.devices = project_devices({ no_stock = true })
			local broken = migration.new(make_api(env, { get_all_code_items = false }))
			broken:restore()
			local verdict = broken:run()
			assert.equal("Report failed: this OS has no GetAllCodeItems (needs 3.3.0)", verdict)
			local stored = env.store[migration.KEY]
			assert.equal(verdict, stored.verdict)
			assert.equal(1201, stored.stock.id)
			assert.is_nil(stored.counts)
		end)

		it("restores the rows and the verdict from the persisted value, in a new instance", function()
			local m, env = house("buttons")
			local verdict, rows = m:run()
			local again = migration.new(make_api(env))
			assert.equal(T.not_run, again:verdict())
			local restored = again:restore(env.store[migration.KEY])
			assert.same(rows, restored)
			assert.same(rows, again:rows())
			assert.equal(verdict, again:verdict())
			assert.equal(report_row(), again:rows()[2], "row 2 says when the rows were read")
		end)

		it("reads the store itself when restore is given nothing, and writes the list", function()
			local m, env = house("buttons")
			local _, rows = m:run()
			local lists_before = #env.lists
			local again = migration.new(make_api(env))
			assert.same(rows, again:restore())
			assert.equal(lists_before + 1, #env.lists)
			local written = env.lists[#env.lists]
			assert.same(rows, written.items)
			assert.equal(rows[1], written.selected)
		end)

		it("writes the list with the verdict as the selected value after a run", function()
			local m, env = house("start")
			local verdict, rows = m:run()
			assert.equal(1, #env.lists)
			assert.same(rows, env.lists[1].items)
			assert.equal(verdict, env.lists[1].selected)
		end)

		it("restores 'not run' from nothing, a wrong type, empty rows or rows that are not text", function()
			local junk = { nil, "text", 5, true, {}, { rows = {} }, { rows = "x" }, { rows = { 1, 2 } },
				{ rows = { "ok", 7 } }, { verdict = "x" } }
			for index = 1, 10 do
				local env = new_env()
				local m = migration.new(make_api(env))
				local rows = m:restore(junk[index])
				assert.same({ T.not_run }, rows, "case " .. index)
				assert.equal(T.not_run, m:verdict(), "case " .. index)
				assert.is_nil(m:last(), "case " .. index)
			end
		end)

		it("trusts the first row as the verdict, and draws a stored comma as U+201A", function()
			local env = new_env()
			local m = migration.new(make_api(env))
			m:restore({ verdict = "something else", rows = { "the verdict", "a, b" }, stock = "no", setting = "x" })
			assert.equal("the verdict", m:verdict())
			assert.same({ "the verdict", "a" .. COMMA .. " b" }, m:rows())
			m:run() -- a stock field that is no table is dropped, not trusted
			assert.equal("Stock device 1201: 22 enabled lines name it; keep it", m:verdict())
		end)

		it("drops stored stock ids that are not numbers", function()
			local env = new_env({ devices = project_devices({ no_stock = true }), items = house_items(PHASES.removed) })
			local m = migration.new(make_api(env))
			m:restore({ rows = { "v" }, stock = { id = 1201, ids = { 1201, "x", {}, 1202 } } })
			assert.equal("Stock device 1201 is gone; nothing names it", (m:run()))
			local bad = migration.new(make_api(env))
			bad:restore({ rows = { "v" }, stock = { id = "x", ids = { 1 } } })
			assert.equal("No stock WAC device in the project; nothing to migrate", (bad:run()))
		end)

		it("shows 'Stock Device changed' when the property differs from what the run used, and undoes it", function()
			local m, env = house("buttons")
			local verdict, rows = m:run()
			assert.equal(verdict, m:stock_device_changed(), "nothing changed")

			env.props["Stock Device"] = "1201"
			assert.equal("Stock Device changed: click Migration Report again", m:stock_device_changed())
			local changed = m:rows()
			assert.equal("Stock Device changed: click Migration Report again", changed[1])
			assert.same({ unpack(rows, 2) }, { unpack(changed, 2) }, "the other rows stay")
			assert.equal("Stock Device changed: click Migration Report again", env.lists[#env.lists].selected)

			env.props["Stock Device"] = ""
			assert.equal(verdict, m:stock_device_changed())
			assert.same(rows, m:rows())
		end)

		it("shows it after a restart too, and runs the report fresh on a click", function()
			local m, env = house("buttons")
			m:run()
			env.props["Stock Device"] = "1202"
			local again = migration.new(make_api(env))
			again:restore()
			assert.equal("Stock Device changed: click Migration Report again", again:verdict())
			assert.equal("Stock device 1201: 13 enabled lines name it; keep it", (again:run()))
			assert.equal(1202, env.store[migration.KEY].setting)
			assert.equal("Stock device 1201: 13 enabled lines name it; keep it", again:stock_device_changed())
		end)

		it("says 'changed' when Stock Device was cleared since the run that used it (Phase 8, step 3)", function()
			local env = new_env({ items = house_items(PHASES.workaround_off),
				props = { ["Stock Device"] = "1201", ["Fan Address"] = "", ["Driver Version"] = "57" } })
			local m = migration.new(make_api(env))
			m:run()
			assert.equal(1201, env.store[migration.KEY].setting)
			env.props["Stock Device"] = ""
			assert.equal("Stock Device changed: click Migration Report again", m:stock_device_changed())
			assert.equal("Stock device 1201: nothing enabled names it; safe to remove", (m:run()))
			assert.equal(0, env.store[migration.KEY].setting)
		end)

		it("gives the same rows when run again on the same project", function()
			local m = house("buttons")
			local first_verdict, first_rows = m:run()
			local second_verdict, second_rows = m:run()
			assert.equal(first_verdict, second_verdict)
			assert.same(first_rows, second_rows)
		end)

		it("does not say 'changed' before the first run", function()
			local env = new_env({ props = { ["Stock Device"] = "1201", ["Fan Address"] = "", ["Driver Version"] = "57" } })
			local m = migration.new(make_api(env))
			assert.equal(T.not_run, m:stock_device_changed())
			m:restore()
			assert.equal(T.not_run, m:verdict())
		end)

		it("puts the verdict back when a row is picked", function()
			local m, env = house("buttons")
			local verdict = m:run()
			local lists = #env.lists
			assert.equal(verdict, m:snap_back())
			assert.equal(lists + 1, #env.lists)
			assert.equal(verdict, env.lists[#env.lists].selected)
			assert.same(m:rows(), env.lists[#env.lists].items)
		end)

		it("replaces its rows on every run", function()
			local m, env = house("start")
			m:run()
			env.items = house_items(PHASES.workaround_off)
			local verdict, rows = m:run()
			assert.equal("Stock device 1201: nothing enabled names it; safe to remove", verdict)
			assert.equal(verdict, env.store[migration.KEY].verdict)
			assert.same(rows, env.store[migration.KEY].rows)
			assert.equal(2, count(env.calls, "store.set"))
		end)
	end)

	describe("what it touches (4.1, 4.7)", function()
		it("reads the project once, writes the one persisted value and the list, and nothing else", function()
			local m, env = house("start")
			m:run()
			assert.equal(1, count(env.calls, "get_devices"))
			assert.equal(1, count(env.calls, "get_all_code_items"))
			assert.equal(1, count(env.calls, "store.set"))
			assert.equal(1, count(env.calls, "update_list"))
			local allowed = set("get_devices", "get_all_code_items", "get_device_variables", "get_bindings_by_device",
				"get_bound_consumer_devices", "get_device_display_name", "get_device_id", "get_proxy_devices",
				"property", "store.get", "store.set", "update_list")
			for _, call in ipairs(env.calls) do
				assert.is_true(allowed[call] == true, call)
			end
		end)

		it("reads a minimum of the project when there is nothing to count", function()
			local m, env = mini({}, { devices = project_devices({ no_stock = true }) })
			m:run()
			assert.equal(0, count(env.calls, "get_all_code_items"))
			assert.equal(0, count(env.calls, "get_bound_consumer_devices"))
		end)

		it("logs one line: counts, ids and the time it took, never a name", function()
			local m, env = house("start")
			m:run()
			assert.equal(1, #env.logs)
			assert.equal("always", env.logs[1].level)
			local line = env.logs[1].text
			assert.truthy(line:find("1201", 1, true))
			assert.truthy(line:find("old 22/22 in 11", 1, true))
			assert.truthy(line:find("links 0/12", 1, true))
			assert.truthy(line:find("speeds 3/3", 1, true))
			assert.truthy(line:find("1212/12=1/1,0/0,5/5", 1, true), "the scripts by device and event id")
			assert.truthy(line:find("0.00 s", 1, true))
			for _, name in ipairs({ "Example", "Keypad", "Timer", "Fan Light", "10.0.2" }) do
				assert.is_nil(line:find(name, 1, true), name)
			end
		end)

		it("lists every script by id in the log line, even those past the 40 rows", function()
			local items = {}
			for n = 1, 45 do
				items[n] = entry(BUTTONS, 100 + n, { command(STOCK_FAN, "x") })
			end
			local m, env = mini(items)
			m:run()
			local line = env.logs[1].text
			assert.truthy(line:find("1212/101=", 1, true))
			assert.truthy(line:find("1212/145=", 1, true))
		end)

		it("logs the failure's verdict too", function()
			local m, env = mini({}, nil, { get_all_code_items = false })
			m:run()
			local always = levels(env, "always")
			assert.equal(1, #always)
			assert.truthy(always[1]:find("Report failed: this OS has no GetAllCodeItems", 1, true))
		end)
	end)
end)
