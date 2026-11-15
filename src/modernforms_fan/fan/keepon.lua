-- fan/keepon.lua: is a room light kept on by Control4 programming? (#247, docs/ignored-lights-design.md: the
-- interface of section 2, decisions IL-D1 to IL-D3; the programming it reads is docs/keep-on-design.md section 3).
-- The room-dark pause leaves such a light out of its scan, since its on state says nothing about the room being dark.
-- Pure: no Director calls, no log. The driver passes in a function that wraps C4:GetCodeItems.
--
--   keepon.EVENT_TURNED_OFF     5101, the light_v2 proxy's Turned Off event
--   keepon.kept_on(items, proxy) -> true | false: IL-D1 holds in items, what GetCodeItems(proxy, 5101) returned
--   keepon.check(proxy, get)    -> kept, why: calls get(proxy, 5101) under pcall and judges its answer; why is
--                                  "kept on by Control4 programming", "no keep-on programming",
--                                  "programming unreadable: <the error, cut to 80 characters>" or
--                                  "programming unreadable: not a table"
--
-- What GetCodeItems gives (API 9_helper/_5.9-GETCODEITEMS.md, from OS 3.3.0; in short: for a device id and an
-- event id, a table holding that event's code items, each with an enabled flag, a type, a device, the command or
-- condition XML under cmdcond, a display text and its nested subitems), as measured on the house (OS 3.4.3,
-- 2026-11-15): { codeitems = { item, ... } }, whose one item is a container (type 1, device 0) holding the
-- event's script. Types: 1 command, 2 condition, 3 loop, 4 else. A keep-on is a command item (type 1) aimed at the
-- light itself (device = its proxy id) whose cmdcond.xml is a devicecommand holding <command>ON</command>; on the
-- house it sits in an Else, under the maintenance condition, under the container.
--
-- IL-D1: kept on when such an On item is enabled and so is every item that encloses it (its parent, that one's
-- parent, up to the item in codeitems). What the conditions test does not matter. IL-D3: only positive evidence
-- says kept, so anything malformed is false: items that is not a table, or has no codeitems table; an entry of a
-- list that is not a table; a subitems that is neither a table nor nil; a table met twice (a cycle, or one item
-- in two places); more than 32 levels of items, or more than 2000 items in all. A malformed answer is false even
-- when an On item was found in it, since the whole answer is walked before it is judged. kept_on never raises:
-- the walk runs under pcall, so even a table whose metatable raises gives false.
--
-- Choices where the contract is silent (each covered by tests/spec/keepon_spec.lua):
--   * enabled counts only as true or the string "true" (any case); nil, false, 1 or anything else is not enabled.
--   * type, device and proxy are each a whole number above 0 (type: 1 or above) or a string of digits; "1" is a
--     command and "123" is proxy 123. A proxy that is neither is never matched.
--   * the XML is item.cmdcond.xml (the SDK's shape; the measured dump joins nested keys with a dot), or a string
--     under the key "cmdcond.xml", in case a Director gives it flat. The match ignores case and allows white space
--     inside the tags and around ON, so <command> ON </command> and <COMMAND>on</COMMAND> match; ONE, OFF, TOGGLE
--     and RAMP_TO_LEVEL do not.
--   * the enclosing items are the structural ones only: an Else follows its If as a sibling (the house's Else
--     does), so a disabled If does not disable the Else after it here.
--   * check: get may return several values; only the first counts. An error that is not a string is shown through
--     tostring; an error whose tostring raises reads "programming unreadable: (no message)".

local keepon = {}

keepon.EVENT_TURNED_OFF = 5101

local MAX_DEPTH = 32
local MAX_ITEMS = 2000
local ERROR_CHARS = 80
local COMMAND = 1

-- A whole number above 0, from a number or a string of digits; nil otherwise.
local function whole(v)
	if type(v) == "string" and v:match("^%d+$") then
		v = tonumber(v)
	end
	if type(v) == "number" and v >= 1 and v < 2 ^ 53 and v == math.floor(v) then
		return v
	end
	return nil
end

local function enabled(item)
	local e = item.enabled
	return e == true or (type(e) == "string" and e:lower() == "true")
end

-- The item's command or condition XML, or nil.
local function xml_of(item)
	local cmdcond = item.cmdcond
	if type(cmdcond) == "table" and type(cmdcond.xml) == "string" then
		return cmdcond.xml
	end
	local flat = item["cmdcond.xml"]
	if type(flat) == "string" then
		return flat
	end
	return nil
end

local function is_on(xml)
	return xml ~= nil and xml:lower():find("<%s*command%s*>%s*on%s*<%s*/%s*command%s*>") ~= nil
end

-- Walks every item; returns found (an On item for proxy, enabled with every enclosing item) and ok (well formed
-- within the bounds). Stops at the first fault.
local function walk(list, proxy)
	local seen, count, found = {}, 0, false
	local function visit(items, depth, live)
		if type(items) ~= "table" or seen[items] then
			return false
		end
		seen[items] = true
		for _, item in pairs(items) do
			if type(item) ~= "table" or seen[item] then
				return false
			end
			seen[item] = true
			count = count + 1
			if count > MAX_ITEMS or depth > MAX_DEPTH then
				return false
			end
			local on = live and enabled(item)
			if on and whole(item.type) == COMMAND and whole(item.device) == proxy and is_on(xml_of(item)) then
				found = true
			end
			local subitems = item.subitems
			if subitems ~= nil and not visit(subitems, depth + 1, on) then
				return false
			end
		end
		return true
	end
	local ok = visit(list, 1, true)
	return found, ok
end

function keepon.kept_on(items, proxy)
	proxy = whole(proxy)
	if proxy == nil or type(items) ~= "table" then
		return false
	end
	local ran, found, ok = pcall(function()
		return walk(items.codeitems, proxy)
	end)
	return ran and ok == true and found == true
end

local function message(err)
	local ok, text = pcall(tostring, err)
	if not ok or type(text) ~= "string" then
		return "(no message)"
	end
	return text:sub(1, ERROR_CHARS)
end

function keepon.check(proxy, get)
	local ok, items = pcall(get, proxy, keepon.EVENT_TURNED_OFF)
	if not ok then
		return false, "programming unreadable: " .. message(items)
	end
	if type(items) ~= "table" then
		return false, "programming unreadable: not a table"
	end
	if keepon.kept_on(items, proxy) then
		return true, "kept on by Control4 programming"
	end
	return false, "no keep-on programming"
end

return keepon
