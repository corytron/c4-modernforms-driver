-- fan/migration.lua: the Migration Report (docs/migration-design.md, section 4).
--
-- A click-only, read-only report on how far the house has moved from the stock
-- WAC driver to this one. It finds this fan's stock device (4.2), reads the
-- project's programming for the lines that name it (4.3), counts the stock
-- links keypads are still bound to, and sets the speed the stock fan holds
-- beside this fan's (G13). Its verdict (4.5) says "safe to remove" exactly
-- when G12 holds. It changes nothing in the project: no API can write, disable
-- or delete programming (G11), and none that binds, renames or deletes is
-- reachable from here (4.1). It writes only the Migration list (through
-- api.update_list), one persisted value (4.6) and one log line (4.7).
--
-- Pure apart from the api table it is given (section 9.1); the coordinator
-- wires each function to Director, a spec passes fakes of the same shapes:
--
--   api.get_devices()                         C4:GetDevices({})              [API 22/_9]
--   api.get_all_code_items()                  C4:GetAllCodeItems()           [API 9/_5.5]
--       nil on a controller without the call (OS before 3.3.0): the report says so
--   api.get_device_variables(id)              C4:GetDeviceVariables(id)      [API 22/_12]
--   api.get_bindings_by_device(id)            C4:GetBindingsByDevice(id)     [API 32/_2.5]
--   api.get_bound_consumer_devices(id, link)  C4:GetBoundConsumerDevices     [API 32/_3]
--   api.get_device_display_name(id)           C4:GetDeviceDisplayName(id)    [API 32/_6]
--   api.get_device_id()                       C4:GetDeviceID()               [API 22/_11]
--   api.get_proxy_devices()                   C4:GetProxyDevices()           [API 25/_1]
--   api.property(name)                        Properties[name]; read: "Fan Address",
--                                             "Stock Device", "Driver Version"
--   api.now()                                 the wall clock, epoch seconds (os.time);
--                                             above 1e11 it is taken as milliseconds
--   api.log                                   the common.log module, or a function(line)
--   api.store                                 { get = fn(key), set = fn(key, value) }
--   optional: api.update_list(items, selected)
--                 C4:UpdatePropertyList("Migration", table.concat(items, ","), selected)
--                 and then C4:UpdateProperty("Migration", selected): the Hue drivers found
--                 that the shown row moves only with both [Hue docs/status.md]
--             api.build()                     the build, if "Driver Version" is not it
--             api.shown_speed()               this device's shown speed, 0 when off
--
-- Every call is made in pcall: a missing function, an error or an answer of
-- another shape degrades the report (an "unknown" speed, no address match) or
-- fails it with a verdict of its own (4.5), and never raises into Director.
--
-- The object (see M.new): run() on the action's click; restore() at
-- OnDriverLateInit with the persisted value, before the properties are replayed;
-- stock_device_changed() from the `Stock Device` handler and snap_back() from the
-- `Migration` handler (a pick changes nothing, 4.1); rows(), verdict(), last().
--
-- Not known until the first run on the house (H8, H10; section 8 of the contract):
-- the file name as GetDevices spells it, the shape of GetBindingsByDevice's and
-- GetDeviceVariables' answers, whether a condition carries its device in `device`
-- (if not, the timer's 12 Ifs are invisible, 4.3.3), and whether Disable Event
-- leaves a trace in the root's `enabled` flag (G7). Each is read in a few shapes
-- and degrades to "unknown" or to no line counted, never to a guess.

local M = {}

M.KEY = "mf_migration" -- the one persisted value (4.6)
M.STOCK_FILE = "wac_mf_fan_and_light_controller(v4).c4z" -- as M0 read it (K1)
M.STOCK_LINKS = 12 -- the stock driver's links, ids 0 to 11 (M0, K1)
-- The fan proxy's speed variable, first match wins. GetDeviceVariables names it
-- CURRENT_SPEED (hardware, M1 round 2, 2026-11-04: ids 1000 to 1003 are IS_ON,
-- CURRENT_SPEED, IS_REVERSED and PRESET_SPEED, each with a name and a value;
-- #35); "Current Selected Speed" is the proxy documentation's display name
-- [FAN 46/_1], kept as a fallback.
M.SPEED_VARIABLES = { "CURRENT_SPEED", "Current Selected Speed" }
M.SPEED_VARIABLE = M.SPEED_VARIABLES[1]

local STOCK_PREFIX = "wac_mf_fan" -- another version of WAC's file is found too (4.2)
local MAX_SCRIPT_ROWS = 40 -- row 13 follows the 40th script row (4.4)
local MAX_ON_ROWS = 5 -- row 12, then "... and n more"
local ROW_LIMIT = 69 -- rows stay under 70 characters; Composer clips near 75 (4.4)
local ROOM_LIMIT = 22 -- a room name is cut to 22 characters
local NAME_MIN = 12 -- a device name is never cut below 12
local MAX_DEPTH = 64 -- programming nests a few levels; the cap only stops a malformed table
local MAX_ROWS = 600 -- 40 scripts of up to 8 rows and the fixed rows stay well below
local LAYOUT = 1 -- of the persisted value

-- Characters the rows use, as UTF-8 [section 4.4; the Hue rows show them on the house].
local COMMA = "\226\128\154" -- U+201A, the one a comma becomes: no row holds a comma
local ELLIPSIS = "\226\128\166" -- U+2026
local ARROW = "\226\150\184" -- U+25B8
local DOT = "\194\183" -- U+00B7

-- Texts ----------------------------------------------------------------------
-- Every owner-visible string of section 4.4 and 4.5. A pair is { one, many }:
-- the contract gives the plural; the singular is added so that "1 enabled
-- lines name it" is never shown (the last line left is a state the report is
-- for).

local T = {
	-- 4.5, the verdicts
	not_run = "Not run yet: click Migration Report on the Actions tab",
	changed = "Stock Device changed: click Migration Report again",
	none = "No stock WAC device in the project; nothing to migrate",
	several = "%d stock WAC devices: pick this fan's in Stock Device",
	keep_lines = {
		"Stock device %s: 1 enabled line names it; keep it",
		"Stock device %s: %d enabled lines name it; keep it",
	},
	keep_links = {
		"Stock device %s: 1 keypad link bound to it; keep it",
		"Stock device %s: %d keypad links bound to it; keep it",
	},
	keep_both = "Stock device %s: %s and %s; keep it",
	both_lines = { "1 enabled line", "%d enabled lines" },
	both_links = { "1 link", "%d links" },
	safe = "Stock device %s: nothing enabled names it; safe to remove",
	gone = "Stock device %s is gone; nothing names it",
	gone_lines = {
		"Stock device %s is gone; 1 line still names it",
		"Stock device %s is gone; %d lines still name it",
	},
	failed = "Report failed: %s",
	-- the reasons: the first three are 4.5's; the last two are the same kind, for
	-- the two other reads the verdict depends on
	no_api = "this OS has no GetAllCodeItems (needs 3.3.0)",
	not_stock = "Stock Device %s is not a stock WAC device",
	read_failed = "reading the programming failed; see the Lua tab",
	devices_failed = "reading the project's devices failed; see the Lua tab",
	links_failed = "reading the stock links failed; see the Lua tab",
	-- 4.4, the rows
	report = "Report of %s by build %s; it changed nothing",
	stock_in = "Stock: device %s in %s (%s)",
	stock_bare = "Stock: device %s (%s)",
	how = {
		only = "the only one",
		address = "same address",
		set = "set in Stock Device",
		other = "not this fan's",
		open = "not matched", -- no verdict, so no device is "not this fan's" yet
	},
	speeds = "Speed held by the stock fan: %s; by this fan: %s",
	unknown = "unknown",
	links = "Stock links bound to keypads: %d of %d",
	stock_lines = {
		"Lines naming device %s: %d in %d script; %d enabled",
		"Lines naming device %s: %d in %d scripts; %d enabled",
	},
	this_lines = {
		"Lines naming this device: %d in %d script; %d enabled",
		"Lines naming this device: %d in %d scripts; %d enabled",
	},
	others = "Other lines still on in scripts naming it: %d",
	legend = "Script rows count lines on/total: old " .. DOT .. " new " .. DOT .. " other",
	first = "  first: ",
	on = "  on: ",
	on_more = "  on: " .. ELLIPSIS .. " and %d more",
	more_scripts = {
		ELLIPSIS .. " %d more script; the Lua tab lists all by id",
		ELLIPSIS .. " %d more scripts; the Lua tab lists all by id",
	},
	not_read = "Not read here: lighting scenes; favourites; voice",
	-- a line without text is shown by its kind (item types 1 to 3, section 4.3)
	kind = { [1] = "command", [2] = "condition", [3] = "loop" },
	no_time = "unknown time",
	no_build = "?",
}
M.T = T

-- Small helpers -------------------------------------------------------------

local function fmt(template, ...)
	local ok, text = pcall(string.format, template, ...)
	return ok and text or tostring(template)
end

local function pick(pair, n)
	return n == 1 and pair[1] or pair[2]
end

-- A function that may be absent or raise: (ok, results...).
local function try(fn, ...)
	if type(fn) ~= "function" then
		return false, "missing"
	end
	return pcall(fn, ...)
end

local function num(value)
	local n = tonumber(value)
	if n ~= nil and n == n then
		return n
	end
	return nil
end

-- The enabled flag of a code item. Absent counts as enabled (the report then
-- errs towards "keep it"); the string forms are accepted because the API
-- documents the table as a printed dump.
local function flag(value)
	if value == nil then
		return true
	end
	if value == false or value == 0 then
		return false
	end
	if type(value) == "string" then
		local s = value:lower()
		return not (s == "false" or s == "0")
	end
	return true
end

-- The tables of a list in key order: a list of code items is an array, but a
-- hole or a key that is an id must not hide the items after it.
local function members(list)
	local out = {}
	if type(list) ~= "table" then
		return out
	end
	-- The usual case, a plain array of tables: used as it is (this runs once per item
	-- of the whole project's programming).
	local n, total = #list, 0
	for _ in pairs(list) do
		total = total + 1
	end
	if total == n then
		local plain = true
		for i = 1, n do
			if type(list[i]) ~= "table" then
				plain = false
				break
			end
		end
		if plain then
			return list
		end
	end
	local keyed = {}
	for key, value in pairs(list) do
		if type(value) == "table" then
			keyed[#keyed + 1] = { sort = num(key) or math.huge, name = tostring(key), value = value }
		end
	end
	table.sort(keyed, function(a, b)
		if a.sort ~= b.sort then
			return a.sort < b.sort
		end
		return a.name < b.name
	end)
	for i, member in ipairs(keyed) do
		out[i] = member.value
	end
	return out
end

local function set_of(list)
	local out = {}
	for _, id in ipairs(list) do
		out[id] = true
	end
	return out
end

local function append(list, more)
	for _, row in ipairs(more) do
		list[#list + 1] = row
	end
end

local function copy_list(list)
	local out = {}
	for i, value in ipairs(list) do
		out[i] = value
	end
	return out
end

-- UTF-8: the rows are cut by characters, never inside one.
local function ulen(s)
	return #(s:gsub("[\128-\191]", ""))
end

local function usub(s, n)
	if n <= 0 then
		return ""
	end
	local count = 0
	for i = 1, #s do
		local b = s:byte(i)
		if b < 128 or b >= 192 then -- the first byte of a character
			count = count + 1
			if count > n then
				return s:sub(1, i - 1)
			end
		end
	end
	return s
end

local function cut(s, n)
	if ulen(s) <= n then
		return s
	end
	return usub(s, n - 1) .. ELLIPSIS
end

-- Text that goes into a row: one line, single spaces, no comma (the list is one
-- comma-delimited string, 4.4).
local function clean(value)
	local s = value == nil and "" or tostring(value)
	s = s:gsub("%c", " ")
	s = s:gsub(",", COMMA)
	s = s:gsub("%s+", " ")
	return (s:match("^%s*(.-)%s*$"))
end

-- Composer fills the NAME macro of a code item's text with "Room->Name" [FUND
-- 10_conditionals/_2-SIMPLECONDITIONAL]. Only the whole word is replaced.
local function fill_name(display, name)
	local out, pos = {}, 1
	while true do
		local s, e = display:find("NAME", pos, true)
		if not s then
			break
		end
		out[#out + 1] = display:sub(pos, s - 1)
		local before, after = display:sub(s - 1, s - 1), display:sub(e + 1, e + 1)
		if before:find("%w") or after:find("%w") then
			out[#out + 1] = "NAME"
		else
			out[#out + 1] = name
		end
		pos = e + 1
	end
	out[#out + 1] = display:sub(pos)
	return table.concat(out)
end

-- The log: the common.log module or a function(line); either may be absent.
local function make_say(sink)
	return function(level, template, ...)
		local text = fmt(template, ...)
		if type(sink) == "table" then
			local fn = sink[level] or sink.info or sink.always
			if type(fn) == "function" then
				pcall(fn, "%s", text)
			end
		elseif type(sink) == "function" then
			pcall(sink, text)
		end
	end
end

local function property(api, name)
	local ok, value = try(api.property, name)
	if not ok or (type(value) ~= "string" and type(value) ~= "number") then
		return ""
	end
	return (tostring(value):match("^%s*(.-)%s*$"))
end

-- The wall clock for the report's time and the run's duration (4.4 row 2, 4.7).
local function clock(api)
	local ok, t = try(api.now)
	t = ok and num(t) or nil
	if t == nil or t < 1e9 then
		return os.time()
	end
	if t > 1e11 then
		return t / 1000
	end
	return t
end

local function stamp(at)
	local ok, text = pcall(os.date, "%Y-%m-%d %H:%M", math.floor(at))
	if ok and type(text) == "string" then
		return text
	end
	return T.no_time
end

local function build_of(api)
	local ok, value = try(api.build)
	if not ok or value == nil or tostring(value) == "" then
		value = property(api, "Driver Version")
	end
	value = clean(value)
	return value == "" and T.no_build or cut(value, 12)
end

-- The id a DEVICE_SELECTOR holds [FUND 15_composerpro_interface_into_the_sdk/
-- _3.1-DEVICESELECTOR]: the digits of "1201"; anything else is "not set".
local function setting_of(api)
	local digits = property(api, "Stock Device"):match("%d+")
	local id = digits and tonumber(digits)
	if id and id > 0 then
		return id
	end
	return nil
end

-- The project's devices (4.2) ------------------------------------------------

local function room_of(entry)
	if type(entry.roomName) == "string" and entry.roomName ~= "" then
		return entry.roomName
	end
	return nil
end

-- id -> { name, room } for every device and every proxy GetDevices lists.
local function index_devices(devices)
	local names = {}
	for key, entry in pairs(devices) do
		local id = num(key)
		if id and type(entry) == "table" then
			names[id] = { name = tostring(entry.deviceName or ""), room = room_of(entry) }
		end
	end
	for key, entry in pairs(devices) do
		if num(key) and type(entry) == "table" and type(entry.proxies) == "table" then
			for proxy_key, proxy in pairs(entry.proxies) do
				local pid = num(proxy_key)
				if pid and type(proxy) == "table" and not names[pid] then
					names[pid] = { name = tostring(proxy.deviceName or ""), room = room_of(entry) }
				end
			end
		end
	end
	return names
end

local function is_stock_file(file)
	if type(file) ~= "string" then
		return false
	end
	local lower = file:lower()
	return lower == M.STOCK_FILE or lower:sub(1, #STOCK_PREFIX) == STOCK_PREFIX
end

-- A stock device: its protocol device and its proxies (M0: 1201, 1202, 1203).
local function stock_record(id, entry)
	local proxies = {}
	if type(entry.proxies) == "table" then
		for key, proxy in pairs(entry.proxies) do
			local pid = num(key)
			if pid then
				proxies[#proxies + 1] = { id = pid, file = type(proxy) == "table" and proxy.driverFileName or nil }
			end
		end
	end
	table.sort(proxies, function(a, b) return a.id < b.id end)
	local ids = { id }
	for _, proxy in ipairs(proxies) do
		ids[#ids + 1] = proxy.id
	end
	return { id = id, room = room_of(entry), proxies = proxies, ids = ids }
end

local function read_devices(api)
	local ok, devices = try(api.get_devices)
	if not ok or type(devices) ~= "table" then
		return nil, ok and "no table" or tostring(devices)
	end
	local found = {}
	for key, entry in pairs(devices) do
		local id = num(key)
		if id and type(entry) == "table" and is_stock_file(entry.driverFileName) then
			found[#found + 1] = stock_record(id, entry)
		end
	end
	table.sort(found, function(a, b) return a.id < b.id end)
	return { names = index_devices(devices), stock = found }
end

-- The proxy ids to read a stock fan's variables from: a proxy whose file name
-- says "fan" first, then the others (the light proxy has no speed variable).
local function proxy_order(proxies)
	local first, rest = {}, {}
	for _, proxy in ipairs(proxies) do
		local file = type(proxy.file) == "string" and proxy.file:lower() or ""
		if file:find("fan", 1, true) then
			first[#first + 1] = proxy.id
		else
			rest[#rest + 1] = proxy.id
		end
	end
	append(first, rest)
	return first
end

local function owns(ids, id)
	for _, own in ipairs(ids) do
		if own == id then
			return true
		end
	end
	return false
end

-- The IPv4 addresses a GetBindingsByDevice answer shows (H10): the documented
-- example is a text with an "addr: <IPv4>" line per binding; a table is searched
-- for addr/address/ip keys. What the house returns is not known yet.
local ADDRESS_KEYS = { addr = true, address = true, ip = true, ipaddress = true }

local function ipv4_in(text)
	local a, b, c, d = text:match("(%d+)%.(%d+)%.(%d+)%.(%d+)")
	if a and num(a) <= 255 and num(b) <= 255 and num(c) <= 255 and num(d) <= 255 then
		return a .. "." .. b .. "." .. c .. "." .. d
	end
	return nil
end

local function collect_addresses(value, found, depth)
	if depth > 6 then
		return
	end
	if type(value) == "string" then
		for rest in value:lower():gmatch("addr[%a]*[%s:=\"']*([%d%.]+)") do
			local address = ipv4_in(rest)
			if address then
				found[address] = true
			end
		end
	elseif type(value) == "table" then
		for key, item in pairs(value) do
			if type(item) == "table" then
				collect_addresses(item, found, depth + 1)
			elseif type(item) == "string" then
				if type(key) == "string" and ADDRESS_KEYS[key:lower()] then
					local address = ipv4_in(item)
					if address then
						found[address] = true
					end
				elseif type(key) == "number" then
					collect_addresses(item, found, depth + 1)
				end
			end
		end
	end
end

-- Several stock devices: the one whose address is this fan's, if exactly one.
-- The proxy's id first, as the API asks for a device with proxies.
local function match_address(api, stock, address)
	if address == "" then
		return nil
	end
	local hits = {}
	for _, rec in ipairs(stock) do
		local found = {}
		local ids = proxy_order(rec.proxies)
		ids[#ids + 1] = rec.id
		for _, id in ipairs(ids) do
			local ok, answer = try(api.get_bindings_by_device, id)
			if ok then
				collect_addresses(answer, found, 0)
			end
		end
		if found[address] then
			hits[#hits + 1] = rec
		end
	end
	if #hits == 1 then
		return hits[1]
	end
	return nil
end

-- 4.2.2: pick = { rec, how } or nil and why ("none", "several", "not_stock").
local function choose(api, stock, setting, address)
	if setting then
		for _, rec in ipairs(stock) do
			if owns(rec.ids, setting) then
				return { rec = rec, how = "set" }
			end
		end
		return nil, "not_stock"
	end
	if #stock == 1 then
		return { rec = stock[1], how = "only" }
	end
	if #stock == 0 then
		return nil, "none"
	end
	local rec = match_address(api, stock, address)
	if rec then
		return { rec = rec, how = "address" }
	end
	return nil, "several"
end

-- This device's own ids: the driver's and its proxies' (4.3.3).
local function add_ids(ids, list, value)
	if type(value) == "table" then
		local before = #list
		for _, item in pairs(value) do
			local id = num(item)
			if id and id > 0 then
				ids[id] = true
				list[#list + 1] = id
			end
		end
		if #list == before then -- { [binding] = id } read the other way: { [id] = name }
			for key in pairs(value) do
				local id = num(key)
				if id and id > 0 then
					ids[id] = true
					list[#list + 1] = id
				end
			end
		end
	else
		local id = num(value)
		if id and id > 0 then
			ids[id] = true
			list[#list + 1] = id
		end
	end
end

local function my_ids(api, say)
	local ids, proxies = {}, {}
	local ok, id = try(api.get_device_id)
	if ok then
		add_ids(ids, {}, id)
	end
	local packed = { try(api.get_proxy_devices) }
	if packed[1] then
		for i = 2, #packed do
			add_ids(ids, proxies, packed[i])
		end
	end
	table.sort(proxies)
	if next(ids) == nil then
		say("warn", "Migration Report: this device's ids are unknown; no line is counted as new")
	end
	return ids, proxies
end

-- The programming (4.3) -------------------------------------------------------

-- GetAllCodeItems: { event_mgr = { { deviceid, eventid, codeitem = root }, ... } }
-- [API 9/_5.5]. nil, reason, detail when it cannot be read.
local function read_programming(api)
	if type(api.get_all_code_items) ~= "function" then
		return nil, T.no_api, "get_all_code_items is not provided"
	end
	local ok, answer = pcall(api.get_all_code_items)
	if not ok then
		local text = tostring(answer)
		-- a controller before 3.3.0 raises "attempt to call method 'GetAllCodeItems' (a nil value)"
		if text:find("GetAllCodeItems", 1, true) and text:find("nil", 1, true) then
			return nil, T.no_api, text
		end
		return nil, T.read_failed, text
	end
	if type(answer) ~= "table" then
		return nil, T.read_failed, "the answer is " .. type(answer)
	end
	local list = answer.event_mgr
	if type(list) ~= "table" then
		list = answer
		local has_entry = false
		for _, entry in pairs(list) do
			if type(entry) == "table" and entry.codeitem ~= nil then
				has_entry = true
			end
		end
		if next(list) ~= nil and not has_entry then
			return nil, T.read_failed, "the answer holds no event entries"
		end
	end
	return list
end

local function new_part()
	return { total = 0, on = 0, shown = {}, first = nil }
end

-- 4.3.3: old when the line names a stock id or its script's event belongs to a
-- stock device, else new when it names this device, else other.
local function count_line(script, ctx, item, enabled)
	local device = num(item.device)
	local kind
	if script.stock_event or (device and ctx.stock[device]) then
		kind = "old"
	elseif device and ctx.me[device] then
		kind = "new"
	else
		kind = "other"
	end
	local part = script[kind]
	part.total = part.total + 1
	local info
	if kind ~= "other" then
		info = { display = item.display, device = device, kind = num(item.type) }
		part.first = part.first or info
	end
	if enabled then
		part.on = part.on + 1
		if kind == "old" and #part.shown < MAX_ON_ROWS then
			part.shown[#part.shown + 1] = info
		end
	end
end

-- 4.3.2: a line (item type 1, 2 or 3) is enabled when it and every item above
-- it, up to the event's root, are. Containers, comments, else and operators are
-- walked through and not counted.
local function walk(item, script, ctx, enabled, depth)
	if depth > MAX_DEPTH then
		return
	end
	for _, sub in ipairs(members(item.subitems)) do
		local on = enabled and flag(sub.enabled)
		local kind = num(sub.type)
		if kind == 1 or kind == 2 or kind == 3 then
			count_line(script, ctx, sub, on)
		end
		walk(sub, script, ctx, on, depth + 1)
	end
end

-- The entry's codeitem is the event's root (id 0, device 0): not a line, but its
-- own enabled flag counts, so that a root Disable Event switched off disables every
-- line under it (G7; H8 shows whether Composer leaves such a flag).
local function roots_of(codeitem)
	if codeitem.subitems ~= nil or codeitem.type ~= nil or codeitem.enabled ~= nil then
		return { codeitem }
	end
	return members(codeitem)
end

local function scan_entry(entry, ctx)
	if type(entry.codeitem) ~= "table" then
		return nil
	end
	local device = num(entry.deviceid)
	local script = {
		device = device,
		event = num(entry.eventid),
		stock_event = (device and ctx.stock[device]) and true or false,
		old = new_part(),
		new = new_part(),
		other = new_part(),
	}
	for _, root in ipairs(roots_of(entry.codeitem)) do
		walk(root, script, ctx, flag(root.enabled), 0)
	end
	return script
end

-- The scripts that hold an old or a new line (4.3.3), those with an enabled old
-- line first (4.4 row 10).
local function scan(list, ctx)
	local scripts = {}
	for _, entry in ipairs(members(list)) do
		local script = scan_entry(entry, ctx)
		if script and (script.old.total > 0 or script.new.total > 0) then
			scripts[#scripts + 1] = script
		end
	end
	table.sort(scripts, function(a, b)
		local ea, eb = a.old.on > 0, b.old.on > 0
		if ea ~= eb then
			return ea
		end
		local da, db = a.device or 0, b.device or 0
		if da ~= db then
			return da < db
		end
		return (a.event or 0) < (b.event or 0)
	end)
	return scripts
end

local function totals(scripts)
	local sum = { old = { n = 0, s = 0, on = 0 }, new = { n = 0, s = 0, on = 0 }, other_on = 0 }
	for _, script in ipairs(scripts) do
		for _, kind in ipairs({ "old", "new" }) do
			local part, into = script[kind], sum[kind]
			if part.total > 0 then
				into.n = into.n + part.total
				into.s = into.s + 1
				into.on = into.on + part.on
			end
		end
		sum.other_on = sum.other_on + script.other.on
	end
	return sum
end

-- The stock links and the stock fan's speed (4.3.4, 4.3.6) -----------------------

-- Links 0 to 11 with a consumer on any of the stock ids, or nil when nothing
-- could be read (an id that errors on its own is skipped: the API asks for a
-- proxy's id, and the links are the protocol device's).
local function read_links(api, ids)
	if type(api.get_bound_consumer_devices) ~= "function" then
		return nil
	end
	local bound, calls, errors = 0, 0, 0
	for link = 0, M.STOCK_LINKS - 1 do
		local any = false
		for _, id in ipairs(ids) do
			calls = calls + 1
			local ok, consumers = pcall(api.get_bound_consumer_devices, id, link)
			if not ok then
				errors = errors + 1
			elseif type(consumers) == "table" and next(consumers) ~= nil then
				any = true
			end
		end
		if any then
			bound = bound + 1
		end
	end
	if errors == calls then
		return nil
	end
	return bound
end

-- The value of the "Current Selected Speed" variable in a GetDeviceVariables
-- answer: a table of variables, each with a name and a value [API 22/_12 does
-- not give the shape; Snap One's own helper reads an item's `name`], or a table
-- keyed by the variable's name.
local function find_named(variables, name)
	for key, item in pairs(variables) do
		if type(item) == "table" then
			if item.name == name or key == name then
				local value = num(item.value)
				if value == nil then
					value = num(item.Value)
				end
				if value ~= nil then
					return value
				end
			end
		elseif key == name and num(item) ~= nil then
			return num(item)
		end
	end
	return nil
end

local function find_speed(variables)
	if type(variables) ~= "table" then
		return nil
	end
	for _, name in ipairs(M.SPEED_VARIABLES) do
		local speed = find_named(variables, name)
		if speed ~= nil then
			return speed
		end
	end
	return nil
end

local function speed_of(api, ids)
	for _, id in ipairs(ids) do
		local ok, variables = try(api.get_device_variables, id)
		if ok then
			local speed = find_speed(variables)
			if speed ~= nil then
				return speed
			end
		end
	end
	return nil
end

local function this_speed(S)
	local ok, shown = try(S.api.shown_speed)
	if ok and num(shown) ~= nil then
		return num(shown)
	end
	return speed_of(S.api, S.proxies)
end

local function speed_text(speed)
	return speed == nil and T.unknown or tostring(speed)
end

-- Names and rows (4.4) -------------------------------------------------------------

-- { name, room } of a device: GetDevices' table, then GetDeviceDisplayName for an
-- id it lacks, such as an agent (4.3.5).
local function lookup(ctx, id)
	if not id then
		return nil
	end
	if ctx.names[id] then
		return ctx.names[id]
	end
	if ctx.cache[id] == nil then
		local ok, name = try(ctx.api.get_device_display_name, id)
		ctx.cache[id] = (ok and type(name) == "string" and name ~= "") and { name = name } or false
	end
	return ctx.cache[id] or nil
end

local function unnamed(id)
	return id and ("device " .. tostring(id)) or "unknown device"
end

local function qualified(ctx, id)
	local rec = lookup(ctx, id)
	if not rec or rec.name == "" then
		return unnamed(id)
	end
	return rec.room and (rec.room .. "->" .. rec.name) or rec.name
end

local function line_text(ctx, info)
	local display = info.display
	if type(display) ~= "string" or display == "" then
		return T.kind[info.kind] or "line"
	end
	return clean(fill_name(display, qualified(ctx, info.device)))
end

-- "Example Room Keypad": the room cut to 22 characters, the name as far as the
-- row needs and never below 12 (4.4).
local function device_label(ctx, id, tail_length)
	local rec = lookup(ctx, id)
	if not rec or rec.name == "" then
		return clean(unnamed(id))
	end
	local room = rec.room and (cut(clean(rec.room), ROOM_LIMIT) .. " ") or ""
	local budget = math.max(NAME_MIN, ROW_LIMIT - tail_length - ulen(room))
	return room .. cut(clean(rec.name), budget)
end

local function counts_text(script)
	local parts = {}
	for _, kind in ipairs({ "old", "new", "other" }) do
		local part = script[kind]
		if part.total > 0 then
			parts[#parts + 1] = fmt("%s %d/%d", kind, part.on, part.total)
		end
	end
	return table.concat(parts, " " .. DOT .. " ")
end

local function script_row(ctx, script)
	local tail = fmt(" %s event %s: %s", ARROW, tostring(script.event or "?"), counts_text(script))
	return device_label(ctx, script.device, ulen(tail)) .. tail
end

local function text_row(ctx, prefix, info)
	return prefix .. cut(line_text(ctx, info), ROW_LIMIT - ulen(prefix))
end

-- Rows 10 to 13, for the first 40 scripts.
local function script_rows(ctx, scripts)
	local rows = {}
	for i = 1, math.min(#scripts, MAX_SCRIPT_ROWS) do
		local script = scripts[i]
		rows[#rows + 1] = script_row(ctx, script)
		local first = script.old.first or script.new.first
		if first then
			rows[#rows + 1] = text_row(ctx, T.first, first)
		end
		for _, info in ipairs(script.old.shown) do
			rows[#rows + 1] = text_row(ctx, T.on, info)
		end
		if script.old.on > #script.old.shown then
			rows[#rows + 1] = fmt(T.on_more, script.old.on - #script.old.shown)
		end
	end
	if #scripts > MAX_SCRIPT_ROWS then
		local more = #scripts - MAX_SCRIPT_ROWS
		rows[#rows + 1] = fmt(pick(T.more_scripts, more), more)
	end
	return rows
end

-- Rows 6 to 13.
local function summary_rows(ctx, scripts, sum, stock_id)
	local rows = {
		fmt(pick(T.stock_lines, sum.old.s), stock_id, sum.old.n, sum.old.s, sum.old.on),
		fmt(pick(T.this_lines, sum.new.s), sum.new.n, sum.new.s, sum.new.on),
		fmt(T.others, sum.other_on),
		T.legend,
	}
	append(rows, script_rows(ctx, scripts))
	return rows
end

-- Row 3, one per stock device.
local function stock_rows(found, chosen)
	local rows = {}
	for _, rec in ipairs(found) do
		local how = T.how.open
		if chosen then
			how = rec == chosen.rec and T.how[chosen.how] or T.how.other
		end
		if rec.room then
			rows[#rows + 1] = fmt(T.stock_in, rec.id, cut(clean(rec.room), ROOM_LIMIT), how)
		else
			rows[#rows + 1] = fmt(T.stock_bare, rec.id, how)
		end
	end
	return rows
end

local function live_verdict(id, lines, links)
	if lines > 0 and links > 0 then
		return fmt(T.keep_both, id, fmt(pick(T.both_lines, lines), lines), fmt(pick(T.both_links, links), links))
	elseif lines > 0 then
		return fmt(pick(T.keep_lines, lines), id, lines)
	elseif links > 0 then
		return fmt(pick(T.keep_links, links), id, links)
	end
	return fmt(T.safe, id)
end

-- The result of a run (4.6) --------------------------------------------------------

-- Rows 1 and 2, the middle rows, row 14; `extra` is added to the persisted value.
-- Every text that enters a row is cleaned where it is built; the loop below holds
-- the one rule "no row holds a comma" (4.4) at the single exit, whatever a text is.
local function finish(S, verdict, middle, extra)
	local rows = { verdict, fmt(T.report, stamp(S.at), S.build) }
	append(rows, middle or {})
	rows[#rows + 1] = T.not_read
	for i, row in ipairs(rows) do
		rows[i] = (row:gsub(",", COMMA))
	end
	verdict = rows[1]
	local data = {
		v = LAYOUT,
		at = S.at,
		build = S.build,
		setting = S.setting or 0,
		verdict = verdict,
		rows = rows,
		stock = S.prev and S.prev.stock or nil, -- remembered until a run finds a stock device again
	}
	for key, value in pairs(extra or {}) do
		data[key] = value
	end
	return { verdict = verdict, rows = rows, data = data }
end

local function fail(S, reason, found, detail)
	local result = finish(S, fmt(T.failed, reason), found and stock_rows(found, nil) or nil)
	result.detail = detail
	return result
end

local function counts_of(sum, links)
	return {
		old = { lines = sum.old.n, scripts = sum.old.s, on = sum.old.on },
		new = { lines = sum.new.n, scripts = sum.new.s, on = sum.new.on },
		other_on = sum.other_on,
		links = links and { bound = links, total = M.STOCK_LINKS } or nil,
	}
end

-- The programming read against one set of stock ids: scripts, totals, context.
local function read_scripts(S, stock_ids)
	local list, reason, detail = read_programming(S.api)
	if not list then
		return nil, reason, detail
	end
	local ctx = { api = S.api, names = S.devs.names, cache = {}, stock = set_of(stock_ids), me = S.me }
	local scripts = scan(list, ctx)
	return { ctx = ctx, scripts = scripts, sum = totals(scripts) }
end

-- 4.2.2 found this fan's stock device: the full report.
local function live(S, chosen)
	local rec = chosen.rec
	local prog, reason, detail = read_scripts(S, rec.ids)
	if not prog then
		return fail(S, reason, S.devs.stock, detail)
	end
	local bound = read_links(S.api, rec.ids)
	if bound == nil then
		return fail(S, T.links_failed, S.devs.stock, "no stock link could be read")
	end
	local stock_speed = speed_of(S.api, proxy_order(rec.proxies))
	local this = this_speed(S)
	local middle = stock_rows(S.devs.stock, chosen)
	append(middle, {
		fmt(T.speeds, speed_text(stock_speed), speed_text(this)),
		fmt(T.links, bound, M.STOCK_LINKS),
	})
	append(middle, summary_rows(prog.ctx, prog.scripts, prog.sum, rec.id))
	local result = finish(S, live_verdict(rec.id, prog.sum.old.on, bound), middle, {
		stock = { id = rec.id, ids = copy_list(rec.ids), how = chosen.how },
		speeds = { stock = stock_speed, this = this },
		counts = counts_of(prog.sum, bound),
	})
	result.prog = prog
	return result
end

-- The remembered stock device no longer exists: what still names its ids.
local function gone(S, kept)
	local prog, reason, detail = read_scripts(S, kept.ids)
	if not prog then
		return fail(S, reason, nil, detail)
	end
	local lines = prog.sum.old.n
	local verdict = lines == 0 and fmt(T.gone, kept.id) or fmt(pick(T.gone_lines, lines), kept.id, lines)
	local result = finish(S, verdict, summary_rows(prog.ctx, prog.scripts, prog.sum, kept.id), {
		counts = counts_of(prog.sum, nil),
	})
	result.prog = prog
	return result
end

local function compute(api, say, prev, at)
	local S = {
		api = api,
		prev = prev,
		at = at,
		build = build_of(api),
		setting = setting_of(api),
	}
	local devs, why = read_devices(api)
	if not devs then
		return fail(S, T.devices_failed, nil, why)
	end
	S.devs = devs
	S.me, S.proxies = my_ids(api, say)
	local chosen, state = choose(api, devs.stock, S.setting, property(api, "Fan Address"))
	if chosen then
		return live(S, chosen)
	elseif state == "several" then
		return finish(S, fmt(T.several, #devs.stock), stock_rows(devs.stock, nil))
	end
	local kept = prev and prev.stock
	if kept and (S.setting == nil or owns(kept.ids, S.setting)) then
		return gone(S, kept)
	elseif state == "not_stock" then
		return fail(S, fmt(T.not_stock, S.setting), devs.stock)
	end
	return finish(S, T.none, nil)
end

-- What a stored value may be trusted to hold: rows that are strings, the stock
-- ids that are numbers. Anything else is "nothing persisted yet".
local function sanitize(stored)
	if type(stored) ~= "table" or type(stored.rows) ~= "table" then
		return nil
	end
	local rows = {}
	for i = 1, math.min(#stored.rows, MAX_ROWS) do
		if type(stored.rows[i]) ~= "string" then
			return nil
		end
		rows[i] = (stored.rows[i]:gsub(",", COMMA))
	end
	if #rows == 0 then
		return nil
	end
	local data = {}
	for key, value in pairs(stored) do
		data[key] = value
	end
	data.rows, data.verdict = rows, rows[1]
	data.setting = num(stored.setting) or 0
	local kept = stored.stock
	if type(kept) == "table" and num(kept.id) and type(kept.ids) == "table" then
		local ids = {}
		for _, id in ipairs(kept.ids) do
			if num(id) then
				ids[#ids + 1] = num(id)
			end
		end
		data.stock = { id = num(kept.id), ids = ids, how = kept.how }
	else
		data.stock = nil
	end
	return data
end

-- One log line: counts, ids and the time the run took, never a name (4.7).
local function log_line(result, took)
	local data = result.data
	local parts = {}
	local kept = data.stock
	if kept then
		parts[#parts + 1] = "stock " .. table.concat(kept.ids, "+") .. (kept.how and (" " .. kept.how) or "")
	end
	local counts = data.counts
	if counts then
		parts[#parts + 1] = fmt("old %d/%d in %d, new %d/%d in %d, other on %d", counts.old.on, counts.old.lines,
			counts.old.scripts, counts.new.on, counts.new.lines, counts.new.scripts, counts.other_on)
		if counts.links then
			parts[#parts + 1] = fmt("links %d/%d", counts.links.bound, counts.links.total)
		end
	end
	if data.speeds then
		parts[#parts + 1] = fmt("speeds %s/%s", speed_text(data.speeds.stock), speed_text(data.speeds.this))
	end
	if result.prog then
		local ids = {}
		for _, script in ipairs(result.prog.scripts) do
			ids[#ids + 1] = fmt("%s/%s=%d/%d,%d/%d,%d/%d", tostring(script.device), tostring(script.event),
				script.old.on, script.old.total, script.new.on, script.new.total, script.other.on, script.other.total)
		end
		parts[#parts + 1] = "scripts " .. (#ids > 0 and table.concat(ids, " ") or "none")
	end
	parts[#parts + 1] = fmt("%.2f s", took)
	return fmt("Migration Report: %s (%s)", result.verdict, table.concat(parts, "; "))
end

-- The report ------------------------------------------------------------------------

local Report = {}
Report.__index = Report

-- api: see the header. Nothing is read until run().
function M.new(api)
	api = type(api) == "table" and api or {}
	return setmetatable({
		api = api,
		say = make_say(api.log),
		rows_ = { T.not_run },
		verdict_ = T.not_run,
		data = nil, -- the last run's persisted value
	}, Report)
end

-- The DYNAMIC_LIST items, verdict first (a copy).
function Report:rows()
	return copy_list(self.rows_)
end

function Report:verdict()
	return self.verdict_
end

-- The persisted value of the last run, or of the restore (4.6): counts, ids
-- and the rows as written. Read-only for the caller.
function Report:last()
	return self.data
end

-- Writes the Migration list through api.update_list, if the coordinator gave one
-- (C4:UpdatePropertyList does not belong in OnDriverInit, API 24/_6).
function Report:publish()
	-- Re-entry is cut: C4:UpdateProperty raises no OnPropertyChanged (API 24/_3), but
	-- the docs are silent on UpdatePropertyList, and a pick's handler calls snap_back().
	if type(self.api.update_list) == "function" and not self.publishing then
		self.publishing = true
		local ok, err = pcall(self.api.update_list, self:rows(), self.verdict_)
		self.publishing = false
		if not ok then
			self.say("warn", "Migration Report: the list could not be written: %s", tostring(err))
		end
	end
end

local function persist(self, data)
	local store = self.api.store
	if type(store) ~= "table" or type(store.set) ~= "function" then
		self.say("warn", "Migration Report: there is no store; the result is not kept")
		return
	end
	local ok, err = pcall(store.set, M.KEY, data)
	if not ok then
		self.say("warn", "Migration Report: the result could not be kept: %s", tostring(err))
	end
end

-- The click: reads the project, sets the rows and the verdict, keeps the result
-- and writes the list. Never raises. Returns the verdict and a copy of the rows.
function Report:run()
	local started = clock(self.api)
	local ok, result = pcall(compute, self.api, self.say, self.data, started)
	if not ok then
		self.say("error", "Migration Report: %s", tostring(result))
		local S = { api = self.api, prev = self.data, at = started, build = T.no_build, setting = nil }
		local made, fallback = pcall(fail, S, T.read_failed)
		result = made and fallback or { verdict = fmt(T.failed, T.read_failed), rows = { fmt(T.failed, T.read_failed) } }
	end
	if result.detail then
		self.say("error", "Migration Report: %s", tostring(result.detail))
	end
	self.rows_, self.verdict_, self.data = result.rows, result.verdict, result.data or self.data
	if result.data then
		persist(self, result.data)
	end
	self:publish()
	if result.data then
		local lined, line = pcall(log_line, result, math.max(0, clock(self.api) - started))
		self.say("always", "%s", lined and line or result.verdict)
	end
	return self.verdict_, self:rows()
end

-- `Stock Device` was set, changed or cleared (4.5): the verdict says so until the
-- report runs again; changed back to what the last run used, the verdict is the
-- run's again. Also what the late-init replay of the property calls.
function Report:stock_device_changed()
	local data = self.data
	if data then
		local rows = copy_list(data.rows)
		if (setting_of(self.api) or 0) ~= (data.setting or 0) then
			rows[1] = T.changed
		end
		self.rows_, self.verdict_ = rows, rows[1]
	end
	self:publish()
	return self.verdict_
end

-- The list at OnDriverLateInit (4.6): from the persisted value handed in (or
-- read from the store), with the verdict of "Stock Device changed" if the
-- property differs from what the persisted run used. Returns the rows.
function Report:restore(stored)
	if stored == nil then
		local store = self.api.store
		local ok, value = try(store and store.get, M.KEY)
		stored = ok and value or nil
	end
	local data = sanitize(stored)
	self.data = data
	if data then
		self.rows_, self.verdict_ = copy_list(data.rows), data.verdict
	else
		self.rows_, self.verdict_ = { T.not_run }, T.not_run
	end
	self:stock_device_changed()
	return self:rows()
end

-- A pick in the list changes nothing: the verdict is put back as the value
-- (4.1; C4:UpdateProperty raises no OnPropertyChanged, API 24/_3).
function Report:snap_back()
	self:publish()
	return self.verdict_
end

return M
