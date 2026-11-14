-- fan/roomdark.lua: the LED animations pause in a dark room at night (#233, revised by #240). The contract is
-- docs/room-dark-pause-design.md: decisions RD-D3 to RD-D8 and RD-D11, the edge cases RE1 to RE14 and this
-- module's interface (section 3). It decides whether the speed LED chase and the Breeze LED animation are paused;
-- the engines (fan/speedleds.lua, fan/breezeleds.lua) take that as configure{ paused } (RD-D9), and the driver
-- wires the Director calls, the look at the sun (it computes the window, RD-D5) and the property.
--
-- The room's lights (RD-D3) are what lights() returns, { [proxy_id] = name } for every light_v2 proxy in the fan
-- item's room, read again at every scan (late init, the property set, sunrise, sunset and the 6-hourly look of
-- the sun). A scan listens to every light it finds new and unlistens every light it no longer finds, so a light
-- added or moved in counts from the next scan (RE1), one moved out or deleted keeps its last state until the next
-- scan drops it (RE2), and a fan item moved to another room reads the new room (RE3). A light's state (RD-D4) is
-- its Light State variable (1000) as Director reports it through light(id, value): "1", "true" (any case) or a
-- number above 0 is on; "0", "false" or 0 is off; anything else, and a light that has not reported, is unknown.
-- It keeps its last state until it reports again, so an offline light's last value counts (RE4).
--
-- The pause is a condition, not a latch (#240, RD-D6): paused exactly while
--   - it is enabled (Pause LED Animations is "Room lights off after sunset"),
--   - it is inside the window (RD-D5: sunset to 30 minutes after sunrise; the driver computes it and passes it in
--     as set_night(bool), so only the meaning of "night" changed, and that is the driver's),
--   - the room has at least one light, and
--   - every light is known off (none on, none unknown).
-- It is decided again whenever one of them may have changed:
--   starts  (RD-D6) at a light reporting off (RE5: the last light off inside the window pauses at once, and again
--           after a light on and off), every set_night(true) (sunset, RE7, and every later look of the sun inside
--           the window, which is harmless), the end of a scan, configure and the start.
--   ends    (RD-D7) when a light reports on, when set_night(false) closes the window (30 minutes after sunrise, even
--           with every light still off), when configure disables it (RE14), or when a scan reads the room and finds
--           no light in it (RE8). An unknown light never ends it (RE13), so a new light's first report causes no
--           blip; a light on and off again outside the window does not pause (RE6).
--   is not saved (RD-D8): start() restores nothing; it scans, then decides. Director reports every light right
--           after its listener is set, so a restart inside the window with every light off pauses again within
--           moments (RE10), and one outside it does not (RE11). Build 244 latched (sunrise did not end a pause, and
--           load/save kept it over a restart); #240 withdrew both.
--
-- Re-entrance (RD-D4: Director calls OnWatchedVariableChanged right after a listener is set, so possibly inside
-- listen): a light is marked watched, state unknown, before listen is called, and a report during a scan only
-- records the light's state. The scan decides once, at its end, on the whole list: a report of on during a scan
-- ends a pause there, once, naming the first light that reported on; a room reporting all off inside the window
-- pauses there, once. on_change never nests: a change made inside on_change waits until it returns, so the
-- driver sees every change in order and the last one it sees is the state that holds.
--
-- The log (RD-D11): a pause and its end at always, "LED animations paused: <why>" and "LED animations resumed:
-- <why>", where <why> is the phrase on_change gets:
--   paused   "the only light in the room is off after sunset", "both lights in the room are off after sunset",
--            "all <n> lights in the room are off after sunset"
--   resumed  "<name> (<id>) came on", "30 minutes after sunrise" (#240), "Pause LED Animations is Never",
--            "no light in the room"
-- (build 244's "restored after a restart" is gone with the saved pause, #240). A scan that changes the list (or
-- its names) logs at info ("Room lights: ..."); a scan that changes nothing logs nothing, since it runs every 6
-- hours; each light's report is a debug line; a failure a warn line.
--
-- Choices where the contract is silent (each covered by tests/spec/roomdark_spec.lua):
--   * enabled starts true, the property's default, until configure says otherwise; configure without an enabled
--     key changes nothing; only enabled == true enables. Likewise only set_night(true) is inside the window.
--   * set_night(false) while paused ends the pause at once, wherever it comes from (inside a scan or inside
--     on_change too, as configure's Never does), so the pause never outlasts the window; while not paused it does
--     nothing: no on_change, no log line.
--   * opts.load and opts.save, which build 244 took, are ignored: never called, so a driver that still passes
--     them works.
--   * listen returning false, or raising, is a failure; any other return (true, or none) is success. The first
--     failure of a light warns; while it keeps failing, each later scan's retry logs at debug.
--   * lights() raising, or returning anything but a table, is a failed read: the last list and the pause stay
--     (warn line), and nothing is decided. Only a read that succeeds and finds nothing ends a pause (RD-D7); a
--     room whose lights all failed to listen leaves the pause as it is and cannot start one (no light counts).
--   * A light report carrying a Lua boolean counts as on (true) or off (false), as its text would.
--   * scan() before start() does nothing (start scans); scan() during a scan (re-entrant) is ignored.
--   * stop() is final: every later call except paused(), counts() and debug() is ignored, and a change still
--     waiting inside on_change is dropped.
--
-- Pure: nothing here touches Director, no globals. Every option is called through pcall; a failure is logged at
-- warn and the module goes on:
--
--   local r = roomdark.new({
--       lights = fn() -> { [id] = name, ... } | nil, err,  -- the room's light_v2 proxies now (RD-D3)
--       listen = fn(id) -> true | false, err,              -- RegisterVariableListener(id, 1000); may call r:light
--       unlisten = fn(id),                                 -- UnregisterVariableListener(id, 1000)
--       on_change = fn(paused, why),                       -- only on a real change; why is RD-D11's phrase
--       log = { always, info, warn, debug } })             -- common/log.lua's functions
--   r:configure({ enabled = bool })  -- Pause LED Animations is "Room lights off after sunset"
--   r:set_night(bool)                -- inside the window or not (RD-D5); before start() it is only kept
--   r:start()                        -- late init: scan, then decide (RD-D6); nothing is restored (RD-D8)
--   r:scan(why); r:light(id, value); r:paused() -> bool; r:counts() -> lights, on, unknown; r:stop()
--   r:debug() -> table
--
-- Lua 5.1: no goto, no integer division, no bit operators.

local roomdark = {}

roomdark.LIST_MAX = 8 -- names in the "Room lights:" line (RD-D11), then "and N more"
roomdark.NAME_MAX = 40 -- characters of each name in that line

local Room = {}
Room.__index = Room

-- Helpers ------------------------------------------------------------------------------------------------------

-- A device id: a whole number above 0, from a number or a numeric string, else nil.
local function id_of(value)
	local n = tonumber(value)
	if n == nil or n ~= n or n <= 0 or n == math.huge or n ~= math.floor(n) then
		return nil
	end
	return n
end

-- A light's name for the log and the why phrases; a name that is not a text is "Light".
local function name_of(value)
	if type(value) == "string" then
		local trimmed = value:match("^%s*(.-)%s*$")
		if trimmed ~= "" then
			return trimmed
		end
	end
	return "Light"
end

-- RD-D4: a Light State value as "on", "off" or "unknown".
local function state_of(value)
	local kind = type(value)
	if kind == "boolean" then
		return value and "on" or "off"
	elseif kind == "string" then
		local text = value:match("^%s*(.-)%s*$"):lower()
		if text == "true" then
			return "on"
		elseif text == "false" then
			return "off"
		end
		value = tonumber(text)
	elseif kind ~= "number" then
		return "unknown"
	end
	if value == nil or value ~= value then
		return "unknown"
	elseif value > 0 then
		return "on"
	elseif value == 0 then
		return "off"
	end
	return "unknown"
end

-- A value as the debug line shows it: a text in quotes, anything else as tostring.
local function shown(value)
	if type(value) == "string" then
		return '"' .. value .. '"'
	end
	return tostring(value)
end

local function label(id, name)
	return ("%s (%d)"):format(name, id)
end

local function short(name)
	if #name > roomdark.NAME_MAX then
		return name:sub(1, roomdark.NAME_MAX - 3) .. "..."
	end
	return name
end

-- RD-D11: why the pause starts, for n lights all off.
local function all_off(n)
	if n == 1 then
		return "the only light in the room is off after sunset"
	elseif n == 2 then
		return "both lights in the room are off after sunset"
	end
	return ("all %d lights in the room are off after sunset"):format(n)
end

-- The module ---------------------------------------------------------------------------------------------------

function roomdark.new(opts)
	opts = type(opts) == "table" and opts or {}
	return setmetatable({
		o = opts,
		log = opts.log,
		enabled = true, -- Pause LED Animations' default (RD-D2) until configure says otherwise
		night = false,
		started = false,
		stopped = false,
		is_paused = false,
		read = false, -- a read of the room has succeeded
		room_size = 0, -- lights the last successful read found, watched or not
		watched = {}, -- [id] = { name = text, state = "on" | "off" | "unknown" }
		failing = {}, -- [id] = true while listen keeps failing (warned once a streak)
		scanning = false,
		first_on = nil, -- the first light to report on during the scan in progress
		listed = nil, -- the list as last logged (RD-D11); nil before the first read
		queue = {}, -- changes waiting for on_change, in order
		notifying = false,
	}, Room)
end

function Room:say(level, template, ...)
	local sink = self.log
	local fn = type(sink) == "table" and sink[level] or nil
	if type(fn) ~= "function" then
		return
	end
	local ok, text = pcall(string.format, template, ...)
	pcall(fn, "%s", ok and text or tostring(template))
end

-- The watched ids, ascending.
function Room:ids()
	local ids = {}
	for id in pairs(self.watched) do
		ids[#ids + 1] = id
	end
	table.sort(ids)
	return ids
end

-- An option without a function behind it is skipped quietly; one that raises warns.
function Room:call(name, what, ...)
	local fn = self.o[name]
	if type(fn) ~= "function" then
		return
	end
	local ok, err = pcall(fn, ...)
	if not ok then
		self:say("warn", "Room lights: %s failed: %s", what, tostring(err))
	end
end

-- A real change of the pause: logged at always (RD-D11), then on_change(paused, why), never nested: a change made
-- inside on_change is passed on after it returns. Nothing is saved (RD-D8, #240).
function Room:change(paused, why)
	if self.stopped or self.is_paused == paused then
		return
	end
	self.is_paused = paused
	self:say("always", "LED animations %s: %s", paused and "paused" or "resumed", why)
	self.queue[#self.queue + 1] = { paused = paused, why = why }
	if self.notifying then
		return
	end
	self.notifying = true
	while self.queue[1] ~= nil and not self.stopped do
		local c = table.remove(self.queue, 1)
		self:call("on_change", c.paused and "passing on the pause" or "passing on the resume", c.paused, c.why)
	end
	self.queue = {}
	self.notifying = false
end

-- RD-D6: pause when enabled, inside the window (night, RD-D5), with at least one light and every light known off.
function Room:check_start()
	if self.is_paused or not self.enabled or not self.night or not self.started or self.stopped
			or self.scanning then
		return
	end
	local lights, on, unknown = self:counts()
	if lights > 0 and on == 0 and unknown == 0 then
		self:change(true, all_off(lights))
	end
end

-- RD-D7 at the end of a scan (and the start): a light on ends the pause, naming `first` (the first light to report
-- on during the scan) if it is still on, else the lowest id on.
function Room:check_on(first)
	if not self.is_paused then
		return
	end
	local id = first
	if not (id and self.watched[id] and self.watched[id].state == "on") then
		id = nil
		for _, k in ipairs(self:ids()) do
			if self.watched[k].state == "on" then
				id = k
				break
			end
		end
	end
	if id then
		self:change(false, label(id, self.watched[id].name) .. " came on")
	end
end

function Room:evaluate()
	if not self.started or self.stopped or self.scanning then
		return
	end
	self:check_on()
	self:check_start()
end

-- lights() as { [id] = name } with whole ids above 0, and how many; or nil and why the read failed.
function Room:read_room()
	local fn = self.o.lights
	if type(fn) ~= "function" then
		return nil, "no lights function"
	end
	local ok, list, err = pcall(fn)
	if not ok then
		return nil, tostring(list)
	elseif type(list) ~= "table" then
		return nil, tostring(err or "no list")
	end
	local room, size = {}, 0
	for key, name in pairs(list) do
		local id = id_of(key)
		if id and not room[id] then
			room[id] = name_of(name)
			size = size + 1
		end
	end
	return room, size
end

-- RD-D3, RD-D4: unlisten every watched light the room no longer has.
function Room:drop_gone(room)
	for _, id in ipairs(self:ids()) do
		if not room[id] then
			local name = self.watched[id].name
			self.watched[id] = nil
			self:unlisten(id, name)
		end
	end
	for id in pairs(self.failing) do
		if not room[id] then
			self.failing[id] = nil
		end
	end
end

function Room:unlisten(id, name)
	local fn = self.o.unlisten
	if type(fn) ~= "function" then
		return
	end
	local ok, err = pcall(fn, id)
	if not ok then
		self:say("warn", "Room lights: could not stop watching %s: %s", label(id, name), tostring(err))
	end
end

-- RD-D4: listen to one light found new. It is watched (unknown) before listen is called, so a report inside the
-- call counts; a failure leaves it out, warned once a streak, and the next scan tries again (RE13).
function Room:listen(id, name)
	self.watched[id] = { name = name, state = "unknown" }
	local fn = self.o.listen
	local ok, result, err
	if type(fn) == "function" then
		ok, result, err = pcall(fn, id)
	else
		ok, result = false, "no listen function"
	end
	if self.stopped then
		return
	end
	if ok and result ~= false then
		self.failing[id] = nil
		return
	end
	self.watched[id] = nil
	if self.first_on == id then
		self.first_on = nil
	end
	local why = ok and tostring(err or "refused") or tostring(result)
	self:say(self.failing[id] and "debug" or "warn", "Room lights: could not watch %s: %s; tried again at the next scan",
		label(id, name), why)
	self.failing[id] = true
end

-- RD-D3: new names for the lights kept, then listen to the new ones, ascending.
function Room:add_new(room)
	local new = {}
	for id, name in pairs(room) do
		local entry = self.watched[id]
		if entry then
			entry.name = name
		else
			new[#new + 1] = id
		end
	end
	table.sort(new)
	for _, id in ipairs(new) do
		if self.stopped then
			return
		end
		self:listen(id, room[id])
	end
end

-- RD-D11: the list at info when it (or a name in it) changed since it was last logged.
function Room:report_list()
	local ids = self:ids()
	local missing = self.room_size - #ids
	local keys, parts = {}, {}
	for i, id in ipairs(ids) do
		local name = self.watched[id].name
		keys[i] = id .. "=" .. name
		if i <= roomdark.LIST_MAX then
			parts[#parts + 1] = short(name) .. " " .. id
		end
	end
	local signature = table.concat(keys, "\n") .. "\n" .. missing
	if signature == self.listed then
		return
	end
	self.listed = signature
	if self.room_size == 0 then
		self:say("info", "Room lights: none in this room; the LED animations never pause")
		return
	elseif #ids == 0 then
		self:say("info", "Room lights: none of the %d in this room could be watched; tried again at the next scan",
			self.room_size)
		return
	end
	local more = #ids - roomdark.LIST_MAX
	local list = table.concat(parts, ", ") .. (more > 0 and (" and %d more"):format(more) or "")
	if missing > 0 then
		self:say("info", "Room lights: %d of %d in this room watched (%s); the rest are tried again at the next scan",
			#ids, self.room_size, list)
	else
		self:say("info", "Room lights: %d in this room (%s)", #ids, list)
	end
end

-- Interface ----------------------------------------------------------------------------------------------------

function Room:configure(cfg)
	if self.stopped or type(cfg) ~= "table" or cfg.enabled == nil then
		return
	end
	self.enabled = cfg.enabled == true
	if not self.started then
		return
	end
	if self.enabled then
		self:check_start() -- RD-D6: the property set
	else
		self:change(false, "Pause LED Animations is Never") -- RD-D7, RE14
	end
end

-- RD-D5 (#240): the driver's look at the sun, true inside the window (sunset to 30 minutes after sunrise). The
-- window opening, and every later look inside it, checks the start (RD-D6); the window closing ends a pause at
-- once, even with every light still off (RD-D7), and does nothing while not paused. Before start() it is only kept.
function Room:set_night(night)
	if self.stopped then
		return
	end
	self.night = night == true
	if not self.started then
		return
	end
	if self.night then
		self:check_start()
	else
		self:change(false, "30 minutes after sunrise") -- RD-D7; nothing while not paused
	end
end

-- Late init: the first scan, then decide (RD-D6). Nothing is restored (RD-D8, #240): the lights report from inside
-- their listen calls, so the decision is on the room as it is now.
function Room:start()
	if self.started or self.stopped then
		return
	end
	self.started = true
	self:scan("start")
	self:evaluate()
end

-- RD-D3: read the room again, unlisten the gone, listen to the new, then decide once on the whole list.
function Room:scan(why)
	if not self.started or self.stopped then
		return
	end
	why = tostring(why or "asked")
	if self.scanning then
		self:say("debug", "Room lights: a scan (%s) during a scan; ignored", why)
		return
	end
	self:say("debug", "Room lights: reading the room (%s)", why)
	local room, size = self:read_room()
	if not room then
		local count = self:counts()
		self:say("warn", "Room lights: could not read the room's lights (%s): %s; the last list of %d is kept",
			why, size, count)
		return
	end
	self.read = true
	self.room_size = size
	self.scanning = true
	self.first_on = nil
	self:drop_gone(room)
	self:add_new(room)
	self.scanning = false
	local first = self.first_on
	self.first_on = nil
	if self.stopped then
		return
	end
	self:report_list()
	if size == 0 then
		self:change(false, "no light in the room") -- RD-D7, RE8
		return
	end
	self:check_on(first)
	self:check_start()
end

-- OnWatchedVariableChanged(id, 1000, value) (RD-D4). During a scan the state is only recorded; the scan decides
-- at its end.
function Room:light(id, value)
	if not self.started or self.stopped then
		return
	end
	local n = id_of(id)
	local entry = n and self.watched[n]
	if not entry then
		self:say("debug", "Room lights: a report from device %s, not watched; ignored", tostring(id))
		return
	end
	local state = state_of(value)
	self:say("debug", "Room light %s reports %s: %s", label(n, entry.name), shown(value), state)
	entry.state = state
	if self.scanning then
		if state == "on" and self.first_on == nil then
			self.first_on = n
		end
		return
	end
	if state == "on" then
		self:change(false, label(n, entry.name) .. " came on") -- RD-D7; nothing while not paused
	elseif state == "off" then
		self:check_start() -- RD-D6, RE5
	end
end

function Room:paused()
	return self.is_paused
end

function Room:counts()
	local lights, on, unknown = 0, 0, 0
	for _, entry in pairs(self.watched) do
		lights = lights + 1
		if entry.state == "on" then
			on = on + 1
		elseif entry.state ~= "off" then
			unknown = unknown + 1
		end
	end
	return lights, on, unknown
end

-- OnDriverDestroyed: unlisten every light; nothing more is called.
function Room:stop()
	if self.stopped then
		return
	end
	self.stopped = true
	self.queue = {}
	local ids, watched = self:ids(), self.watched
	self.watched = {}
	for _, id in ipairs(ids) do
		self:unlisten(id, watched[id].name)
	end
end

function Room:debug()
	local lights, on, unknown = self:counts()
	local list = {}
	for _, id in ipairs(self:ids()) do
		local entry = self.watched[id]
		list[#list + 1] = { id = id, name = entry.name, state = entry.state }
	end
	return {
		enabled = self.enabled,
		night = self.night,
		started = self.started,
		paused = self.is_paused,
		stopped = self.stopped,
		read = self.read,
		lights = lights,
		on = on,
		unknown = unknown,
		list = list,
	}
end

return roomdark
