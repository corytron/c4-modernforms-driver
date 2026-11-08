-- fan/breeze.lua: the fan's Breeze as Control4 sees it (#111, #121). The contract is
-- docs/breeze-design.md: decisions BZ1, BZ3, BZ10, BZ11 and this module's interface in section 3 (1.2),
-- and section 11 (1.3, BF-D1 to BF-D12), which supersedes BZ5 (d), BZ6, BZ7 and the 1.2 meaning of Breeze Off;
-- where it is silent, docs/edge-cases-breeze-fan.md (BF rows) and docs/edge-cases-breeze.md (ECB) section 3
-- and its BC decisions are the rule.
--
-- It turns the four programming commands, link 311's press and the Breeze fan's taps into the model's wanted
-- fields, and turns what the fan confirms into the Breeze variable, the events Breeze Started and Stopped,
-- the condition BOOL_BREEZE and the state every bound companion is told.
--
-- One motor, three states (BF-D1; fan/mode.lua decides them from the shown state): stopped, fan mode, and
-- Breeze mode (`fan_on` and `wind` both true). Breeze on (BF-D5) wants `wind` true, with a strength when one
-- is given, and from stopped also the fan on at its confirmed speed (the request order is the model's,
-- BF-D6). Breeze off (BF-D4) in Breeze mode stops the motor and clears `wind`; stopped with a stored `wind`
-- it clears `wind`; in fan mode it does nothing, so it never stops a fan in fan mode.
--
-- "Breeze blows" (BZ1) is the confirmed `wind` true AND `fan_on` true. That one value is the variable, the
-- events, the condition and the companions' BLOWS; link 311's LED is Breeze mode on the shown state
-- (blows_shown). The companions hear only what the fan confirmed (section 4: the tile never reports
-- optimistically), and the state again after every message they send (BF-D9); shown() changes nothing
-- they are told.
--
-- Pure like fan/follow.lua and fan/rename.lua: nothing here touches Director. Everything arrives as an
-- option, every option is called through pcall, one that is missing counts as one that failed, nothing
-- raises from here, and new() calls nothing (OnDriverInit):
--
--   breeze.new({
--       model = m,             -- want(fields) -> ok, why; shown(); confirmed(); info(); phase(); identity()
--       preset = fn() -> 1..6, -- the fan proxy's preset speed (BF-D5: when the confirmed speed is unknown)
--       set_variable = fn("1" | "0"),          -- C4:SetVariable("Breeze", value)
--       fire = fn(event_id),                   -- C4:FireEventByID: 4 Breeze Started, 5 Breeze Stopped
--       persist = fn(key, value), recall = fn(key) -> value,   -- breeze.KEY, a boolean
--       result = fn(key, args),                -- a Last Action line (texts.result)
--       companions = fn() -> { device_id, ... },   -- the bound consumers of binding 400
--       send = fn(device_id, command, params),     -- C4:SendToDevice
--       add_device = fn(name, cb(device_id or nil, err)),   -- C4:AddDevice of the Breeze fan package
--       bind = fn(device_id) -> true on success,   -- C4:Bind(this device, 400, device_id, 1, ...)
--       item_name = fn() -> string,            -- the fan item's display name
--       old_companion = fn(device_id) -> bool, -- true for a bound 1.2 switch (BF-D10); missing: never
--       log = log,                             -- default common.log
--   })
--
-- The companions' messages (section 4, BF-D8, BF-D9): MF_BREEZE_STATE { BLOWS, AVAILABLE, HAS_BREEZE, FAN,
-- STRENGTH } goes out; STRENGTH ("1" to "3", the confirmed `wind_speed`) is left out while it is unknown.
-- In: MF_BREEZE_SET { ON = "1" | "0", STRENGTH = "1".."3" optional }, MF_BREEZE_TOGGLE {},
-- MF_BREEZE_CYCLE { STEP = "1" | "-1" }, MF_BREEZE_HELLO {}.
--
-- The Last Action keys it writes through result(key, args) (sections 5 and 11):
--   breeze_unavailable  {}                  L33: the fan has no Breeze (the model's no_breeze)
--   breeze_strength     { strength = given } L34: STRENGTH is not 1, 2 or 3 (the raw parameter)
--   breeze_refused      { why = reason }    L35: any other refusal of the model ("unset", "invalid address",
--                                           "foreign", "gen4", "notfan", "rebooting", "range", "no <key>"),
--                                           or "error" when the model could not be asked
--   breeze_switch_added    { name }         L36: the Breeze fan was added and bound
--   breeze_switch_exists   { name }         L37: a companion is bound already
--   breeze_switch_no_breeze {}              L38
--   breeze_switch_no_fan   {}               L39
--   breeze_switch_failed   { name, step }   L40 (step "add": Composer refused the device; "bind": the binding)
--   breeze_old_switch      { name }         L41: the bound companion is a 1.2 switch (BF-D10)
-- A command the model takes writes nothing (as every proxy command); nor does an off with nothing to end
-- or a cycle step with nowhere to go (logged).
--
-- Lua 5.1: no goto, no integer division, no bit operators.

local mode = require("fan.mode")

local breeze = {}

breeze.EVENT_STARTED = 4
breeze.EVENT_STOPPED = 5
breeze.CONDITION = "BOOL_BREEZE"
breeze.KEY = "mf_breeze"                 -- the one persisted value (BZ12)
breeze.COMMANDS = { "Breeze_On", "Breeze_Off", "Toggle_Breeze", "Set_Breeze_Strength" }
breeze.STATE = "MF_BREEZE_STATE"         -- fan -> companion (section 4)
breeze.SET = "MF_BREEZE_SET"             -- companion -> fan, ON "1" | "0", STRENGTH "1".."3" optional
breeze.TOGGLE = "MF_BREEZE_TOGGLE"
breeze.CYCLE = "MF_BREEZE_CYCLE"         -- STEP "1" | "-1" (BF-D9)
breeze.HELLO = "MF_BREEZE_HELLO"
-- The phases in which a companion shows the fan's Breeze (section 4): the pinned fan answers, is being
-- contacted, or reboots (BC19: unchanged while rebooting). Offline, unset, foreign, Gen 4, not a fan: offline.
breeze.AVAILABLE_PHASES = { online = true, waiting = true, rebooting = true }
breeze.NAME_MAX = 30                     -- the companion's name, in characters (BZ11)
breeze.SUFFIX = " Breeze"
breeze.DEFAULT_NAME = "Modern Forms Breeze" -- when the fan item's name cannot be read
breeze.DEFAULT_PRESET = 3                -- fan/fanproxy.lua's, when the preset cannot be read either
breeze.SPEEDS = 6
breeze.STRENGTHS = 3

-- Refusals of the model that mean "this fan has no Breeze" (L33).
local UNAVAILABLE = { no_breeze = true, ["no wind"] = true, ["no windSpeed"] = true }

-- Helpers ----------------------------------------------------------------------------------------------------

-- fn(...) in pcall; a function that is not there fails like one that raises.
local function try(fn, ...)
	if type(fn) ~= "function" then
		return false, "not given"
	end
	return pcall(fn, ...)
end

-- A whole number in lo..hi from a parameter (a string, hardware K5) or a number, else nil.
local function whole(value, lo, hi)
	local n = tonumber(value)
	if n == nil or n ~= n or n ~= math.floor(n) or n < lo or n > hi then
		return nil
	end
	return n
end

-- A device id: a positive whole number, given as a number or as digits; nil for anything else.
local function id_of(value)
	if type(value) == "string" then
		value = value:match("^%s*(%d+)%s*$")
	end
	local n = tonumber(value)
	if n == nil or n ~= n or n < 1 or n == math.huge or n ~= math.floor(n) then
		return nil
	end
	return n
end

-- Linear however the text is built (#49: the pattern form is quadratic on long inner blanks).
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

-- The first `max` characters of a UTF-8 text, never half of one.
local function cut_chars(text, max)
	local i, n, len = 1, 0, #text
	while i <= len do
		if n == max then
			return text:sub(1, i - 1)
		end
		local c = text:byte(i)
		if c >= 0xF0 then
			i = i + 4
		elseif c >= 0xE0 then
			i = i + 3
		elseif c >= 0xC0 then
			i = i + 2
		else
			i = i + 1
		end
		n = n + 1
	end
	return text
end

local function copy(t)
	local out = {}
	for k, v in pairs(t) do
		out[k] = v
	end
	return out
end

local function flag(value)
	return value and "1" or "0"
end

-- A strength as MF_BREEZE_STATE carries it: "1" to "3", nil for anything else (BF-D9: left out when unknown).
local function strength_text(value)
	local n = whole(value, 1, breeze.STRENGTHS)
	return n and string.format("%d", n) or nil
end

-- The instance -------------------------------------------------------------------------------------------------

local Breeze = {}
Breeze.__index = Breeze

-- Calls no option: building it in OnDriverInit sends, persists and reads nothing.
function breeze.new(opts)
	opts = type(opts) == "table" and opts or {}
	return setmetatable({
		o = opts,
		log = opts.log or require("common.log"),
		stopped = false,
		gen = 0,           -- stop() moves it on; an add_device callback from before does nothing
		blows = nil,       -- the confirmed value, from the first settled on; nil until then
		strength_now = nil, -- the confirmed wind_speed as "1".."3", from the settled reports; nil while unknown
		recalled = nil,    -- breeze.KEY as read once (the variable's seed), until the first settled replaces it
		told = nil,        -- { blows, available, has_breeze, strength }: what the companions were last told
		last_shown = nil,  -- the last shown state the model gave, for blows_shown when the model cannot answer
		adding = false,    -- an Add Breeze Fan waits for Composer's callback
	}, Breeze)
end

function Breeze:say(level, template, ...)
	local sink = self.log
	local fn = type(sink) == "table" and sink[level] or nil
	if type(fn) ~= "function" then
		return
	end
	local ok, text = pcall(string.format, template, ...)
	pcall(fn, "%s", ok and text or tostring(template))
end

-- model:method(...) in pcall: ok, value.
function Breeze:ask(method, ...)
	local m = self.o.model
	if type(m) ~= "table" or type(m[method]) ~= "function" then
		return false, "no model:" .. method
	end
	return pcall(m[method], m, ...)
end

function Breeze:report(key, args)
	local ok, err = try(self.o.result, key, args or {})
	if not ok then
		self:say("error", "Breeze: Last Action %s could not be written: %s", key, tostring(err))
	end
end

-- The value the variable, the condition and the companions carry: the confirmed one once the fan answered
-- (BZ1), until then the persisted one the variable was seeded with (BC22).
function Breeze:current()
	if self.blows ~= nil then
		return self.blows
	end
	if self.recalled == nil then
		local ok, value = try(self.o.recall, breeze.KEY)
		if not ok then
			self:say("warn", "Breeze: %s could not be read: %s", breeze.KEY, tostring(value))
		end
		self.recalled = ok and (value == true or value == "1" or value == 1) or false
	end
	return self.recalled
end

-- Whether the fan has Breeze: the info says so, and the last breeze settle did not drop it (the model settles
-- "breeze" once with `wind` nil when Breeze disappears, BC18, while `has_wind` stays as it was).
function Breeze:has_breeze()
	if self.reported == false then
		return false
	end
	local oki, info = self:ask("info")
	return oki and type(info) == "table" and info.has_wind == true
end

-- Whether the device's phase lets a companion show the fan's Breeze: online, waiting or rebooting (section 4).
function Breeze:phase_ok()
	local okp, phase = self:ask("phase")
	return okp and breeze.AVAILABLE_PHASES[phase] == true
end

-- A companion shows the fan's Breeze only while the fan has it and the phase allows it (section 4).
function Breeze:available()
	return self:phase_ok() and self:has_breeze()
end

function Breeze:item_name()
	local ok, name = try(self.o.item_name)
	if not ok or type(name) ~= "string" then
		return ""
	end
	return trim((name:gsub("%c", " ")))
end

-- The bound companions, as distinct device ids in the order given.
function Breeze:companion_ids()
	local ok, list = try(self.o.companions)
	if not ok then
		self:say("warn", "Breeze: the bound switches could not be read: %s", tostring(list))
		return {}
	end
	local out, seen = {}, {}
	if type(list) ~= "table" then
		return out
	end
	for _, value in ipairs(list) do
		local id = id_of(value)
		if id and not seen[id] then
			seen[id] = true
			out[#out + 1] = id
		end
	end
	return out
end

-- MF_BREEZE_STATE to every bound companion (section 4), from the confirmed values. STRENGTH is the confirmed
-- strength when it is known and is left out otherwise (BF-D9; C4:SendToDevice drops an empty value, BF52).
function Breeze:broadcast(why)
	local blows, phase_ok, has = self:current(), self:phase_ok(), self:has_breeze()
	local available = phase_ok and has
	-- HAS_BREEZE is "0" only when the phase allows Breeze but the fan has none, so the companion can say
	-- "has no Breeze" instead of "Waiting" (section 4).
	local has_breeze = has or not phase_ok
	local strength = self.strength_now
	self.told = { blows = blows, available = available, has_breeze = has_breeze, strength = strength }
	local params = { BLOWS = flag(blows), AVAILABLE = flag(available), HAS_BREEZE = flag(has_breeze),
		FAN = self:item_name(), STRENGTH = strength }
	local ids = self:companion_ids()
	if #ids > 0 then
		self:say("debug", "Breeze: %s BLOWS=%s AVAILABLE=%s STRENGTH=%s to %d companion(s) (%s)", breeze.STATE,
			params.BLOWS, params.AVAILABLE, tostring(strength), #ids, why)
	end
	for _, id in ipairs(ids) do
		local ok, err = try(self.o.send, id, breeze.STATE, copy(params))
		if not ok then
			self:say("warn", "Breeze: the state could not be sent to device %d: %s", id, tostring(err))
		end
	end
end

-- The state again, only when BLOWS, AVAILABLE, HAS_BREEZE or STRENGTH differ from what the companions were
-- last told (STRENGTH: BF43, a strength changed in the Modern Forms app reaches the Breeze fan's tile).
function Breeze:refresh(why)
	local told = self.told
	local phase_ok, has = self:phase_ok(), self:has_breeze()
	if told == nil or told.blows ~= self:current() or told.available ~= (phase_ok and has)
		or told.has_breeze ~= (has or not phase_ok) or told.strength ~= self.strength_now then
		self:broadcast(why)
	end
end

-- Commands (section 3, BF-D4, BF-D5, BF-D9; BC9 to BC12) --------------------------------------------------------

-- The model's shown state (wanted over in flight over confirmed), else the last one it gave.
function Breeze:shown_state()
	local ok, shown = self:ask("shown")
	if ok and type(shown) == "table" then
		return shown
	end
	return self.last_shown or {}
end

function Breeze:preset()
	local ok, value = try(self.o.preset)
	local n = ok and whole(value, 1, breeze.SPEEDS) or nil
	if n == nil then
		self:say("warn", "Breeze: the preset speed could not be read (%s); using %d", tostring(value),
			breeze.DEFAULT_PRESET)
		return breeze.DEFAULT_PRESET
	end
	return n
end

-- The speed a start into Breeze gives the fan (BF-D5): the confirmed fan speed, which the fan keeps for fan
-- mode, or the preset while it is unknown.
function Breeze:start_speed()
	local ok, conf = self:ask("confirmed")
	local n = ok and type(conf) == "table" and whole(conf.speed, 1, breeze.SPEEDS) or nil
	return n or self:preset()
end

-- A refusal of the model as its Last Action line (section 5).
function Breeze:refused(what, why, given)
	self:say("debug", "Breeze: %s refused: %s", what, tostring(why))
	if UNAVAILABLE[why] then
		self:report("breeze_unavailable", {})
	elseif why == "breeze_range" then
		self:report("breeze_strength", { strength = given })
	else
		self:report("breeze_refused", { why = why })
	end
end

-- model:want(fields): true, or false and why, the refusal written to Last Action.
function Breeze:want(what, fields, given)
	local ok, taken, why = self:ask("want", fields)
	if not ok then
		self:say("error", "Breeze: %s could not reach the model: %s", what, tostring(taken))
		why = "error"
	elseif taken then
		return true
	end
	why = why or "error"
	self:refused(what, why, given)
	return false, why
end

-- A STRENGTH parameter (Set Breeze Strength, MF_BREEZE_SET): 1 to 3, else L34 here (the model is not asked).
function Breeze:strength_of(what, value)
	local n = whole(value, 1, breeze.STRENGTHS)
	if n == nil then
		self:say("warn", "Breeze: %s with strength %s refused: 1, 2 or 3", what, tostring(value))
		self:report("breeze_strength", { strength = value })
	end
	return n
end

-- Breeze on (BF-D5): `wind` true, with `wind_speed` when a strength is given (else the fan resumes its own);
-- from stopped also the fan on at start_speed(), so one want holds both groups and the model orders them
-- (BF-D6). From fan mode `wind` alone switches the mode; in Breeze mode it changes nothing but a strength.
-- A fan whose on/off is unknown gets `wind` alone (only a shown stop adds the fan).
function Breeze:on(what, strength)
	if self.stopped then
		return false, "stopped"
	end
	local fields = { wind = true, wind_speed = strength }
	if mode.stopped(self:shown_state()) then
		fields.fan_on = true
		fields.speed = self:start_speed()
	end
	return self:want(what or "Breeze On", fields, strength)
end

-- Breeze off (BF-D4): in Breeze mode the motor stops and `wind` clears (the model sends the fan first,
-- BF-D6); with a stored `wind` and the motor stopped (or its on/off unknown) only `wind` clears; in fan mode,
-- or with nothing stored, nothing is sent: it never stops a fan in fan mode. A fan without Breeze is asked
-- as in 1.2, so the model's refusal reaches Last Action (BZ10, BF-D2).
function Breeze:off(what)
	if self.stopped then
		return false, "stopped"
	end
	what = what or "Breeze Off"
	local shown = self:shown_state()
	if mode.breeze(shown) then
		return self:want(what, { fan_on = false, wind = false })
	elseif shown.wind == true or not self:has_breeze() then
		return self:want(what, { wind = false })
	end
	self:say("info", "Breeze: %s sends nothing: %s", what, mode.fan_on(shown) and "the fan runs in fan mode"
		or "no Breeze to end")
	return false, "nothing"
end

-- Toggle Breeze, link 311's press and MF_BREEZE_TOGGLE: from the shown state (BC11, BF28), Breeze mode goes
-- off (BF-D4), anything else on (BF-D5).
function Breeze:toggle()
	if self.stopped then
		return false, "stopped"
	end
	if self:blows_shown() then
		return self:off("Toggle Breeze")
	end
	return self:on("Toggle Breeze")
end

-- Set Breeze Strength: 1 to 3, anything else refused here with L34; the strength only (BZ5 e, BF-D5).
function Breeze:strength(value)
	if self.stopped then
		return false, "stopped"
	end
	local n = self:strength_of("Set Breeze Strength", value)
	if n == nil then
		return false, "breeze_range"
	end
	return self:want("Set Breeze Strength", { wind_speed = n }, value)
end

-- MF_BREEZE_CYCLE (BF-D9, BF30), counted from the shown state: STEP "1" outside Breeze mode is Breeze on at
-- strength 1 (ending fan mode, starting a stopped fan as Breeze on does); in Breeze mode one strength up,
-- clamped to 3. STEP "-1" in Breeze mode is one strength down, clamped to 1; outside Breeze mode nothing.
-- Never wraps and never ends Breeze. Any other STEP is refused (logged).
function Breeze:cycle(step)
	if self.stopped then
		return false, "stopped"
	end
	local text = type(step) == "string" and trim(step) or tostring(step)
	local delta = (text == "1" and 1) or (text == "-1" and -1) or nil
	if delta == nil then
		self:say("warn", "Breeze: %s with STEP %s refused: 1 or -1", breeze.CYCLE, text)
		return false, "step"
	end
	local shown = self:shown_state()
	if not mode.breeze(shown) then
		if delta > 0 then
			return self:on("Breeze Cycle", 1)
		end
		self:say("info", "Breeze: %s down sends nothing: not in Breeze mode", breeze.CYCLE)
		return false, "nothing"
	end
	local now = whole(shown.wind_speed, 1, breeze.STRENGTHS)
	if now == nil then
		self:say("info", "Breeze: %s sends nothing: the strength is not known", breeze.CYCLE)
		return false, "nothing"
	end
	local target = math.max(1, math.min(breeze.STRENGTHS, now + delta))
	if target == now then
		self:say("info", "Breeze: %s sends nothing: strength %d is the end", breeze.CYCLE, now)
		return false, "nothing"
	end
	return self:want("Breeze Cycle", { wind_speed = target })
end

local COMMAND = {
	Breeze_On = function(self) return self:on() end,
	Breeze_Off = function(self) return self:off() end,
	Toggle_Breeze = function(self) return self:toggle() end,
	Set_Breeze_Strength = function(self, params) return self:strength(params.STRENGTH) end,
}

-- One of the four programming commands: true when the name is one of them (whether or not the model took it).
function Breeze:command(name, params)
	local handler = COMMAND[name]
	if not handler then
		return false
	end
	handler(self, type(params) == "table" and params or {})
	return true
end

-- What link 311's LED shows: Breeze mode on the shown state (wanted over in flight over confirmed, V10).
function Breeze:blows_shown()
	return mode.breeze(self:shown_state()) == true
end

-- Reports from the model (BZ1, BC18 to BC22) ------------------------------------------------------------------------

-- settled("fan" | "breeze", st, why): the value from the confirmed state; on a change the variable, the
-- persisted value, one event and the companions. The first settled after new() compares with the persisted
-- value, so a restart alone fires nothing (BC22); offline sends no settled, so the last value stays (BC20).
-- The confirmed strength rides along: the companions hear it when it changes (BF43), with no event.
function Breeze:settled(group, st, why)
	if self.stopped or (group ~= "fan" and group ~= "breeze") then
		return
	end
	if type(st) ~= "table" then
		local ok, conf = self:ask("confirmed")
		if not (ok and type(conf) == "table") then
			return
		end
		st = conf
	end
	if group == "breeze" then
		self.reported = st.wind ~= nil
	end
	self.strength_now = strength_text(st.wind_speed)
	local before = self:current()
	local now = st.wind == true and st.fan_on == true
	self.blows = now
	if now ~= before then
		self:say("always", "Breeze %s (%s)", now and "started" or "stopped", tostring(why))
		local ok, err = try(self.o.set_variable, flag(now))
		if not ok then
			self:say("error", "Breeze: the variable could not be set: %s", tostring(err))
		end
		ok, err = try(self.o.persist, breeze.KEY, now)
		if not ok then
			self:say("error", "Breeze: %s could not be saved: %s", breeze.KEY, tostring(err))
		end
		local event = now and breeze.EVENT_STARTED or breeze.EVENT_STOPPED
		ok, err = try(self.o.fire, event)
		if not ok then
			self:say("error", "Breeze: event %d could not be fired: %s", event, tostring(err))
		end
	end
	if self.reply_due then
		-- Half way through a request Control4 made, nothing is told: the reply carries the whole state.
		if self:reply_ready() then
			self.reply_due = false
			self:broadcast("reply")
		end
	else
		self:refresh("settled " .. group)
	end
end

-- The shown state changed. The companions hear only confirmed changes (section 4); link 311's LED reads
-- blows_shown(), and this keeps the state for when the model cannot be asked.
function Breeze:shown(shown)
	if self.stopped or type(shown) ~= "table" then
		return
	end
	self.last_shown = copy(shown)
end

-- The device's phase changed: AVAILABLE may have.
function Breeze:phase(phase)
	if self.stopped then
		return
	end
	self:refresh("phase " .. tostring(phase))
end

-- BOOL_BREEZE (BZ3), as the driver's BOOL_ONLINE: VALUE "True" or "False" compared, LOGIC NOT_EQUAL inverts;
-- without VALUE the state itself. nil for any other condition.
function Breeze:test_condition(name, params)
	if name ~= breeze.CONDITION then
		return nil
	end
	params = type(params) == "table" and params or {}
	local value = self:current()
	local wanted = params.VALUE
	if wanted == nil then
		return value
	end
	local equal = value == (wanted == "True")
	if params.LOGIC == "NOT_EQUAL" then
		return not equal
	end
	return equal
end

-- The companion (section 4, BF-D8, BF-D9) -------------------------------------------------------------------------

-- MF_BREEZE_SET: ON "1" is Breeze on, with STRENGTH when it carries one (1 to 3, else L34 and nothing sent;
-- a 1.2 switch sends none, BF52); ON "0" is Breeze off (BF-D4; a STRENGTH beside it means nothing).
function Breeze:set(params)
	local on = tostring(params.ON)
	if on == "1" then
		local strength = nil
		if params.STRENGTH ~= nil then
			strength = self:strength_of(breeze.SET, params.STRENGTH)
			if strength == nil then
				return false, "breeze_range"
			end
		end
		return self:on(breeze.SET, strength)
	elseif on == "0" then
		return self:off(breeze.SET)
	end
	self:say("debug", "Breeze: %s with ON %s ignored", breeze.SET, on)
	return false, "ignored"
end

-- A message from a companion: true when it is one of the four, false for anything else (ignored). After
-- MF_BREEZE_SET, MF_BREEZE_TOGGLE and MF_BREEZE_CYCLE, taken, refused or with nothing to do, every companion
-- is told the state at once (BF-D9, BF35): a tap the fan refused puts the tile back, and what the fan then
-- confirms follows as a change.
function Breeze:companion(command, params)
	if self.stopped then
		return false
	end
	params = type(params) == "table" and params or {}
	local taken
	if command == breeze.SET then
		taken = self:set(params)
	elseif command == breeze.TOGGLE then
		taken = self:toggle()
	elseif command == breeze.CYCLE then
		taken = self:cycle(params.STEP)
	elseif command == breeze.HELLO then
		self:broadcast("hello")
		return true
	else
		self:say("debug", "Breeze: companion message %s ignored", tostring(command))
		return false
	end
	-- BF-D9, BF35: a request the model took is answered once it has settled, so the tile never steps back to
	-- the old value while the fan works on it; a refused or empty one is answered at once.
	if taken == true then
		self.reply_due = true
	else
		self:broadcast("after " .. command)
	end
	return true
end

-- Whether the fan has answered everything Control4 asked of its fan and Breeze groups (nothing half way).
function Breeze:reply_ready()
	local oks, shown = self:ask("shown")
	local okc, conf = self:ask("confirmed")
	if not (oks and okc and type(shown) == "table" and type(conf) == "table") then
		return true
	end
	return shown.fan_on == conf.fan_on and shown.wind == conf.wind and shown.wind_speed == conf.wind_speed
end

-- The model has nothing more coming for a group (a dropped second request, a target the fan already had): a
-- reply still due goes now.
function Breeze:idle(group)
	if self.stopped or not self.reply_due or (group ~= "fan" and group ~= "breeze") then
		return
	end
	self.reply_due = false
	self:broadcast("reply (idle " .. tostring(group) .. ")")
end

-- Binding 400 changed (BC29 to BC31): every companion still bound is told the state.
function Breeze:binding_changed(bound)
	if self.stopped then
		return
	end
	self:broadcast(bound and "bound" or "unbound")
end

-- Late init: the state to the companions; the variable was seeded by driver.lua from breeze.KEY.
function Breeze:late_init()
	if self.stopped then
		return
	end
	self:broadcast("late init")
end

-- Add Breeze Fan (BZ11, BC28, BF-D10) ------------------------------------------------------------------------------

-- The companion's name: the fan item's name cut so that it and " Breeze" fit NAME_MAX characters, so the
-- Breeze fan is never named exactly as the fan.
function Breeze:switch_name()
	local base = self:item_name()
	if base == "" then
		return breeze.DEFAULT_NAME
	end
	base = trim(cut_chars(base, breeze.NAME_MAX - #breeze.SUFFIX))
	return base .. breeze.SUFFIX
end

-- Composer's answer to the add: bind, then L36; a failure of either is L40.
function Breeze:added(name, value, err)
	local id = id_of(value)
	if id == nil then
		self:say("always", "Breeze fan %q not added: %s", name, tostring(err or value))
		self:report("breeze_switch_failed", { name = name, step = "add" })
		return
	end
	local ok, bound = try(self.o.bind, id)
	if not (ok and bound) then
		self:say("always", "Breeze fan %q added as device %d but not bound: %s", name, id, tostring(bound))
		self:report("breeze_switch_failed", { name = name, step = "bind" })
		return
	end
	self:say("always", "Breeze fan %q added as device %d and bound", name, id)
	self:report("breeze_switch_added", { name = name })
end

-- The first bound companion that old_companion() calls a 1.2 switch (BF-D10), or nil. An answer that is not
-- true, raises or is missing counts as "not old".
function Breeze:old_switch(ids)
	for _, id in ipairs(ids) do
		local ok, old = try(self.o.old_companion, id)
		if ok and old == true then
			return id
		end
	end
	return nil
end

-- The action Add Breeze Fan, only on the click: refused without a pin, without Breeze, or while any companion
-- is bound (L41 when one is a 1.2 switch, else L37); otherwise the Breeze fan is added into the fan item's
-- room (add_device decides where and which package) and bound. A second click while Composer has not answered
-- the first adds nothing.
function Breeze:add_switch()
	if self.stopped then
		return false, "stopped"
	end
	local name = self:switch_name()
	local okp, pin = self:ask("identity")
	if not (okp and pin ~= nil) then
		self:say("always", "Breeze fan not added: no fan is set up")
		self:report("breeze_switch_no_fan", {})
		return false, "no_fan"
	end
	if not self:has_breeze() then
		self:say("always", "Breeze fan not added: the fan reports no Breeze")
		self:report("breeze_switch_no_breeze", {})
		return false, "no_breeze"
	end
	local ids = self:companion_ids()
	if #ids > 0 then
		local old = self:old_switch(ids)
		if old then
			self:say("always", "Breeze fan not added: device %d is a 1.2 Breeze switch; delete it first", old)
			self:report("breeze_old_switch", { name = name })
			return false, "old"
		end
		self:say("always", "Breeze fan not added: device %d is bound already", ids[1])
		self:report("breeze_switch_exists", { name = name })
		return false, "exists"
	end
	if self.adding then
		self:say("always", "Breeze fan not added: the last one is still being added")
		return false, "busy"
	end
	self.adding = true
	local gen, answered = self.gen, false
	local ok, err = try(self.o.add_device, name, function(value, why)
		if answered then
			return
		end
		answered = true
		if self.gen ~= gen then
			return
		end
		self.adding = false
		self:added(name, value, why)
	end)
	if not ok and not answered then
		answered = true
		self.adding = false
		self:added(name, nil, err)
		return false, "failed"
	end
	return true
end

-- OnDriverDestroyed: nothing acts afterwards, an add_device callback that arrives later included.
function Breeze:stop()
	self.stopped = true
	self.gen = self.gen + 1
	self.adding = false
end

return breeze
