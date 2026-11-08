-- Development commands of the Modern Forms Fan driver, dev builds only
-- (docs/v1-design.md, sections 3.7, 9.10 and 12). tools/build.sh lists this
-- file in DEV_ONLY_FILES, so a release package carries none of it, and
-- driver.lua loads it only when common/devloop.lua is there:
--
--   local cmds, stop = devcmds.new({ model = m, fan = fp, links = lk, light = lt, names = job, follow = f,
--                                    prop = dev.prop, inject = fn(binding, command, params), log = log })
--   devloop.set_signed_commands(cmds)        -- OnDriverDestroyed calls stop()
--   devloop.set_redactor(devcmds.redactor(function() return m:identity() end))
--
-- The commands stay out of the dispatch table on purpose: ExecuteCommand has
-- no sender, so whatever sits there any driver in the project could run with
-- C4:SendToDevice, while the table handed to devloop.set_signed_commands is
-- reached only by an `execute` command the dev key signed (docs/dev-loop.md,
-- "Development commands"). Its keys are the names common/dispatch.lua gives
-- commands (white space as "_"), so `devctl.py run "Dev Press" LINK=303
-- ACTION=tap` finds Dev_Press.
--
-- Everything the commands touch comes in through the arguments, so the spec
-- runs on hand-made fakes:
--   model    section 9.5: phase, debug, confirmed, shown, busy, info
--   fan      section 9.7: debug  (told_fan, told_dir, notify_fan, notify_dir)
--   links    section 9.8: debug  (leds)
--   light    section 9.9: debug  (told_level, changing_open, notify_light, and leds if it keeps them)
--   prop     fn(name, value): writes a property row (Dev State)
--   inject   fn(binding, command, params): ReceivedFromProxy as Director would call it
--   log      common/log.lua
-- and, beyond section 9.10's list, all optional:
--   timer    fn(ms, cb) -> object with :Cancel(), as the other modules take it (default: C4:SetTimer)
--   request  fn(req, cb) -> seq | nil, why: sends one request, req as section 9.4's t:send takes it
--            (Dev Request; without it the command refuses). The model's m:request(req, cb) has this
--            shape and sends only while the fan is online and nothing else is due:
--            request = function(req, cb) return m:request(req, cb) end
--   wire     the fan/wire.lua table (default: require("fan.wire"), looked up when Dev Request first needs it)
--   names    fan/rename.lua's job (docs/fan-name-design.md 2.2, 2.4): plan(mode) -> the table of what a
--            click would decide, which Dev Names Plan prints; without it the command refuses. Dev Names
--            Plan never calls the job's run(): nothing is renamed.

local devcmds = {}

-- Section 3.7: keys of the fan's answers that are never stored, shown or
-- logged. A log line holding one in quotes is a raw answer and is withheld.
-- FrCodes (what the fan keeps of its paired remotes) is fan/wire.lua's
-- addition to the contract's list, kept in step with it.
devcmds.PRIVATE_KEYS = { "owner", "federatedIdentity", "deviceName", "SSID", "BSSID", "timezone", "certificateId",
	"schedule", "FrCodes" }

-- Section 12: the leds field of Dev State lists the fan's links, then the light's.
devcmds.FAN_LINKS = { 300, 301, 302, 303, 304, 305, 306, 307, 308, 311 }
devcmds.LIGHT_LINKS = { 200, 201, 202 }
devcmds.BINDINGS = { 5001, 5002 }
-- The groups model:busy takes, in the order section 4.3 sends them.
devcmds.GROUPS = { "fan", "direction", "light" }

-- Dev Press: a tap is a push and, 100 ms later, a click (section 12); K6 and K7
-- (section 11.1) saw a real tap send those two 0.15 to 0.25 s apart.
devcmds.TAP_CLICK_MS = 100
devcmds.COUNT_DEFAULT, devcmds.COUNT_MAX = 1, 100
devcmds.EVERY_DEFAULT_MS, devcmds.EVERY_MIN_MS, devcmds.EVERY_MAX_MS = 300, 10, 60000
devcmds.BODY_MAX = 400
devcmds.PROXY_COMMAND_MAX = 64

-- Text ----------------------------------------------------------------------------------

-- A number as text, or nil: whole numbers without a decimal point, anything
-- that is no finite number not at all.
local function number(n)
	if type(n) ~= "number" or n ~= n or n == math.huge or n == -math.huge then
		return nil
	end
	if n == math.floor(n) then
		return string.format("%.0f", n)
	end
	return string.format("%.2f", n)
end

-- One word of a key=value line: no white space and no "=" inside, so the line
-- stays parseable; "?" for nothing.
local function word(value)
	if value == nil then
		return "?"
	end
	local text = tostring(value):gsub("[%s=]+", "_")
	return text ~= "" and text or "?"
end

-- A caller's value echoed into a log line: control characters out (a value
-- cannot forge a second line of the shipped log), cut at `max`.
local function plain(value, max)
	local text = tostring(value):gsub("%c", "?")
	if #text > max then
		text = text:sub(1, max) .. "..."
	end
	return text
end

-- "on/3", "off" or "?" (unknown): a fan's or a light's state in Dev State.
local function power(on, level)
	if on == nil then
		return "?"
	end
	if not on then
		return "off"
	end
	return "on/" .. (number(level) or "?")
end

-- The same with the level kept while off, as the debug lines of section 3.7
-- write it: "on/3", "off/100".
local function power_kept(on, level)
	if on == nil then
		return "?"
	end
	return (on and "on" or "off") .. "/" .. (number(level) or "?")
end

-- What a proxy was last told: "-" while nothing was.
local function told(value)
	if value == nil then
		return "-"
	end
	return number(value) or word(value):lower()
end

local function led(value)
	if value == true or value == 1 then
		return "1"
	elseif value == false or value == 0 then
		return "0"
	end
	return "?"
end

local function flag(value)
	if value == nil then
		return "?"
	elseif value == false or value == 0 then
		return "0"
	end
	return (value == true) and "1" or (number(value) or "1")
end

-- Dev State --------------------------------------------------------------------------------

-- The Dev State line from already gathered values (section 12): one line of
-- key=value pairs separated by spaces, always in this order, "?" for an unknown
-- value and "-" for none. `s`:
--   phase, seq, ms                      the model's
--   fan_on, speed, direction,
--   light_on, level                     confirmed (nil: unknown)
--   shown = { fan_on, speed, light_on, level }
--   busy = { "fan", ... } | nil         groups with a command wanted or in flight; nil: unknown
--   told_fan, told_dir, told_light      what the proxies were last told (nil: nothing yet)
--   notify_fan, notify_dir, notify_light, changing   counters and the light's open CHANGING
--   leds = { [300] = bool, ... }        the links' lit state, nil: never sent
--   has_light                           false: no light kit, the light's fields read "-"
--   follow                              the address follower's state (#39): off, idle, armed:N, pending
--   search                              the fan search's state (#102): off, stopped, standby, quiet, due:N, open
function devcmds.format_state(s)
	local shown = type(s.shown) == "table" and s.shown or {}
	local kit = s.has_light ~= false
	local busy = "?"
	if type(s.busy) == "table" then
		busy = #s.busy > 0 and table.concat(s.busy, ",") or "-"
	end
	local leds = {}
	for _, id in ipairs(devcmds.FAN_LINKS) do
		leds[#leds + 1] = id .. ":" .. led(s.leds and s.leds[id])
	end
	for _, id in ipairs(devcmds.LIGHT_LINKS) do
		leds[#leds + 1] = id .. ":" .. led(s.leds and s.leds[id])
	end
	return table.concat({
		"phase=" .. word(s.phase),
		"seq=" .. (number(s.seq) or "?"),
		"fan=" .. power(s.fan_on, s.speed),
		"dir=" .. (s.direction == nil and "?" or word(s.direction):lower()),
		"light=" .. (kit and power(s.light_on, s.level) or "-"),
		"shown.fan=" .. power(shown.fan_on, shown.speed),
		"shown.light=" .. (kit and power(shown.light_on, shown.level) or "-"),
		"busy=" .. busy,
		"told.fan=" .. told(s.told_fan),
		"told.dir=" .. told(s.told_dir),
		"told.light=" .. told(s.told_light),
		"notify.fan=" .. (number(s.notify_fan) or "?"),
		"notify.dir=" .. (number(s.notify_dir) or "?"),
		"notify.light=" .. (number(s.notify_light) or "?"),
		"changing=" .. flag(s.changing),
		"leds=" .. table.concat(leds, ","),
		"follow=" .. ((type(s.follow) == "string" and s.follow:find("^[%w:]+$")) and s.follow or "?"),
		"search=" .. ((type(s.search) == "string" and s.search:find("^[%w:]+$")) and s.search or "?"),
		"ms=" .. (number(s.ms) or "?"),
	}, " ")
end

-- Stands in the second place of ask()'s answer when there is none to give.
local UNKNOWN = {}

-- obj:method(...) in pcall: its answers, or nil and UNKNOWN when obj has no such
-- method or it raises (said in the log, since a method that fails is a bug
-- somebody wants to see).
local function ask(o, obj, method, ...)
	if type(obj) ~= "table" or type(obj[method]) ~= "function" then
		return nil, UNKNOWN
	end
	local ok, first, second = pcall(obj[method], obj, ...)
	if not ok then
		o.log.warn("Dev State: %s failed: %s", method, tostring(first))
		return nil, UNKNOWN
	end
	return first, second
end

-- obj:debug() as a table, and whether it answered with one at all.
local function debug_of(o, obj)
	local t = ask(o, obj, "debug")
	if type(t) == "table" then
		return t, true
	end
	return {}, false
end

-- The light buttons' lit state by section 5.2's rule (top and toggle lit while
-- the light is on, bottom while it is off), for a light module that does not
-- report its own.
local function light_leds(on)
	if on == nil then
		return {}
	end
	return { [200] = on and true or false, [201] = not on, [202] = on and true or false }
end

-- What a proxy module says it was last told. nil, from a module that
-- answered, is "nothing yet" ("-" in the line); a module that did not answer
-- leaves it unknown.
local function told_by(answered, report, key)
	if not answered then
		return "?"
	end
	return report[key]
end

-- Asks the model and the modules for what Dev State shows. Whatever one of
-- them cannot say stays nil and reads "?".
local function gather(o)
	local m = o.model
	local s = {}
	s.phase = ask(o, m, "phase")
	if o.follow ~= nil then
		s.follow = ask(o, o.follow, "state")
	end
	if o.search ~= nil then
		s.search = ask(o, o.search, "state")
	end
	local d = debug_of(o, m)
	s.seq, s.ms = d.seq, d.ms or d.last_ms
	local st = ask(o, m, "confirmed")
	if type(st) == "table" then
		s.fan_on, s.speed, s.direction, s.light_on, s.level = st.fan_on, st.speed, st.direction, st.light_on, st.level
	end
	local shown = ask(o, m, "shown")
	s.shown = type(shown) == "table" and shown or {}
	local info = ask(o, m, "info")
	if type(info) == "table" and info.has_light ~= nil then
		s.has_light = info.has_light and true or false
	end
	-- busy: the groups with a command wanted or in flight; a model that cannot
	-- say leaves it unknown (a nil answer for a group is "not busy").
	if type(m) == "table" then
		s.busy = {}
		for _, group in ipairs(devcmds.GROUPS) do
			local busy, unknown = ask(o, m, "busy", group)
			if unknown == UNKNOWN then
				s.busy = nil
				break
			end
			if busy then
				s.busy[#s.busy + 1] = group
			end
		end
	end
	local fan, fan_answered = debug_of(o, o.fan)
	local light, light_answered = debug_of(o, o.light)
	s.told_fan, s.told_dir = told_by(fan_answered, fan, "told_fan"), told_by(fan_answered, fan, "told_dir")
	s.told_light = told_by(light_answered, light, "told_level")
	s.notify_fan, s.notify_dir, s.notify_light = fan.notify_fan, fan.notify_dir, light.notify_light
	-- An open CHANGING is a flag the light keeps only while it is open: a light
	-- that answered without one has none open.
	s.changing = light.changing_open
	if s.changing == nil and light_answered then
		s.changing = false
	end
	-- Links first; the light's own report next; section 5.2's rule last.
	local from_links = debug_of(o, o.links).leds
	from_links = type(from_links) == "table" and from_links or {}
	local from_light = type(light.leds) == "table" and light.leds or {}
	local derived = light_leds(s.shown.light_on)
	s.leds = {}
	for _, id in ipairs(devcmds.FAN_LINKS) do
		s.leds[id] = from_links[id]
	end
	for _, id in ipairs(devcmds.LIGHT_LINKS) do
		local lit = from_links[id]
		if lit == nil then
			lit = from_light[id]
		end
		if lit == nil then
			lit = derived[id]
		end
		s.leds[id] = lit
	end
	return s
end

-- Parameters ---------------------------------------------------------------------------------

-- A whole number from a number or a string of digits, else nil. Parameters
-- arrive as strings (devctl.py sends Key=Value), as Director hands a proxy's
-- parameters over.
local function whole(value)
	if type(value) == "number" then
		if value == math.floor(value) and value >= 0 and value < 1e9 then
			return value
		end
		return nil
	end
	if type(value) == "string" then
		local digits = value:match("^%s*(%d+)%s*$")
		if digits and #digits <= 9 then
			return tonumber(digits)
		end
	end
	return nil
end

local function set_of(list)
	local set = {}
	for _, item in ipairs(list) do
		set[item] = true
	end
	return set
end

local PRESS_LINKS = set_of({ 200, 201, 202, 300, 301, 302, 303, 304, 305, 306, 307, 308, 311 })
local PROXY_BINDINGS = set_of(devcmds.BINDINGS)
local ACTION_COMMANDS = { push = "DO_PUSH", click = "DO_CLICK", release = "DO_RELEASE" }

-- Section 9.3's field names for the keys of a body (the allow-list of section 3.1).
local REQUEST_FIELDS = {
	fanOn = "fan_on", fanSpeed = "speed", fanDirection = "direction",
	lightBrightness = "level", lightOn = "light_on",
	awayModeEnabled = "away", adaptiveLearning = "learning",
	-- breeze-design 2: the breeze group (wire.body takes the four Breeze bodies).
	wind = "wind", windSpeed = "wind_speed",
}

-- A parameter or its default as a whole number within lo..hi, or nil and why.
local function bounded(value, default, lo, hi, name)
	-- devctl.py run ... COUNT= sends an empty string: the same as no parameter.
	if value == nil or (type(value) == "string" and not value:find("%S")) then
		return default
	end
	local n = whole(value)
	if not n or n < lo or n > hi then
		return nil, string.format("%s %s is not a whole number from %d to %d", name, plain(value, 30), lo, hi)
	end
	return n
end

-- "K=V K=V" of a parameter table, keys sorted, for the log line of a command.
local function describe(params)
	local keys = {}
	for key in pairs(params) do
		keys[#keys + 1] = tostring(key)
	end
	table.sort(keys)
	local out = {}
	for _, key in ipairs(keys) do
		out[#out + 1] = plain(key, 30) .. "=" .. plain(params[key], 60)
	end
	return table.concat(out, " ")
end

-- Dev Press's plan: { at_ms, command } in the order things happen. A tap is a
-- push and, TAP_CLICK_MS later, a click; the others are one message.
local function press_plan(action, count, every)
	local plan = {}
	for i = 1, count do
		local at = (i - 1) * every
		if action == "tap" then
			plan[#plan + 1] = { at, "DO_PUSH" }
			plan[#plan + 1] = { at + devcmds.TAP_CLICK_MS, "DO_CLICK" }
		else
			plan[#plan + 1] = { at, ACTION_COMMANDS[action] }
		end
	end
	return plan
end

-- Dev Request ---------------------------------------------------------------------------------

-- The request table for `body` (section 9.4's req), or nil and why: one of the
-- two queries, or a body that parses to fields fan/wire.lua builds a body from
-- (the bytes sent are wire.body's, never the caller's text).
local function request_for(wire, body)
	if body == wire.QUERY_STATE then
		return { kind = "state", path = wire.PATH, body = body }
	elseif body == wire.QUERY_INFO then
		return { kind = "info", path = wire.PATH, body = body }
	end
	local obj, why = wire.decode(body)
	if not obj then
		return nil, "BODY is not a JSON object (" .. tostring(why) .. ")"
	end
	local fields, any = {}, false
	for key, value in pairs(obj) do
		local field = REQUEST_FIELDS[key]
		if not field then
			return nil, string.format('the key "%s" is not one the driver writes', plain(key, 30))
		end
		fields[field], any = value, true
	end
	if not any then
		return nil, "BODY holds no field"
	end
	local canonical, refusal = wire.body(fields)
	if not canonical then
		return nil, "wire.body refuses it (" .. tostring(refusal) .. ")"
	end
	return { kind = "command", path = wire.PATH, body = canonical }
end

local function suffix(id)
	if type(id) ~= "string" or #id < 4 then
		return "?"
	end
	return "..." .. id:sub(-4)
end

-- The answer of a request as one normalized line (section 3.7's debug lines):
-- the state fields or the info fields wire.lua copies, the client id as its
-- last four digits, and nothing else of the body.
local function answer_text(wire, req, result)
	if not result.ok then
		local detail = result.detail and (" (" .. plain(result.detail, 80) .. ")") or ""
		return string.format("%s failed: %s%s", req.kind, tostring(result.err or "error"), detail)
	end
	local head = string.format("%s: %s in %.2f s", req.kind, tostring(result.code or "?"),
		(tonumber(result.ms) or 0) / 1000)
	local summary
	if req.kind == "info" then
		local info = wire.info(result.json)
		if info then
			summary = string.format("firmware %s, light kit %s, id %s", word(info.firmware),
				info.has_light and "yes" or "no", suffix(info.client_id))
		end
	else
		local st = wire.state(result.json)
		if st then
			summary = string.format("fan %s %s, light %s", power_kept(st.fan_on, st.speed),
				st.direction == nil and "?" or word(st.direction):lower(), power_kept(st.light_on, st.level))
		end
	end
	return head .. ": " .. (summary or "no usable data")
end

-- Dev Names Plan ------------------------------------------------------------------------------------

-- The MODE of Dev Names Plan: guarded (also for no value, which is what devctl.py sends
-- for an empty one) or forced, in any case and with padding; else nil and why.
local function plan_mode(value)
	if value == nil or (type(value) == "string" and not value:find("%S")) then
		return "guarded"
	end
	local text = type(value) == "string" and value:lower():match("^%s*(%a+)%s*$") or nil
	if text == "guarded" or text == "forced" then
		return text
	end
	return nil, string.format("MODE %s is not guarded or forced", plain(value, 30))
end

-- The plan the names job made (fan-name-design 2.2) as one line of key=value pairs in the
-- style of Dev State, always in this order, "-" for what the plan did not get as far as.
-- would= is the outcome a click would end in if Director confirms every call. A name is
-- the owner's own word: quoted, cleaned of control characters and cut. fan_type and the
-- two ours flags are fan/rename.lua's additions to the table the contract lists (outcome,
-- ids, live names, targets) and read "-" from a job that has none; mode is the one asked for.
local function format_plan(plan, mode)
	local function dash(value, make)
		if value == nil then
			return "-"
		end
		return make(value)
	end
	local function quoted(value)
		return '"' .. plain(value, 60) .. '"'
	end
	local function ident(value)
		return number(value) or "?"
	end
	local function token(value)
		return word(plain(value, 40))
	end
	local function ours(value)
		return value and "1" or "0"
	end
	return table.concat({
		"mode=" .. mode,
		"would=" .. word(plan.outcome),
		"fan_type=" .. dash(plan.fan_type, token),
		"fan_id=" .. dash(plan.fan_id, ident),
		"fan_live=" .. dash(plan.fan_live, quoted),
		"fan_to=" .. dash(plan.fan_to, quoted),
		"fan_ours=" .. dash(plan.fan_ours, ours),
		"light_id=" .. dash(plan.light_id, ident),
		"light_live=" .. dash(plan.light_live, quoted),
		"light_to=" .. dash(plan.light_to, quoted),
		"light_ours=" .. dash(plan.light_ours, ours),
	}, " ")
end

-- The commands -----------------------------------------------------------------------------------

-- Returns the table for devloop.set_signed_commands (Dev_Fan_State, Dev_Names_Plan,
-- Dev_Press, Dev_Proxy, Dev_Request, Dev_Search: section 12, fan-name-design 2.4 and
-- auto-discovery-design 6.5) and a stop()
-- that cancels the presses still waiting for their timers (OnDriverDestroyed: a reload
-- must not leave them to fire into the new code).
function devcmds.new(opts)
	opts = type(opts) == "table" and opts or {}
	local o = { model = opts.model, fan = opts.fan, links = opts.links, light = opts.light, names = opts.names,
		follow = opts.follow, search = opts.search,
		log = opts.log or require("common.log") }
	local log = o.log
	local pending = {} -- timers armed and not yet fired

	local function refuse(command, why)
		log.warn("%s refused: %s; nothing was done", command, why)
	end

	local function set_timer(ms, fn)
		local make = opts.timer
		if type(make) ~= "function" then
			make = function(delay, cb)
				return C4:SetTimer(delay, function() cb() end)
			end
		end
		local timer, fired
		local ok, err = pcall(function()
			timer = make(ms, function()
				fired = true
				if timer then
					pending[timer] = nil
				end
				fn()
			end)
		end)
		if not ok then
			log.warn("no timer for the press %d ms away: %s", ms, tostring(err))
			return false
		end
		if timer and not fired then
			pending[timer] = true
		end
		return true
	end

	local function send(binding, command, params)
		if type(opts.inject) ~= "function" then
			log.warn("%s on %s: no inject function is wired; nothing was sent", command, tostring(binding))
			return false
		end
		local ok, err = pcall(opts.inject, binding, command, params)
		if not ok then
			log.warn("%s on %s failed: %s", command, tostring(binding), tostring(err))
		end
		return ok
	end

	local function stop()
		local timers = pending
		pending = {}
		for timer in pairs(timers) do
			pcall(function() timer:Cancel() end)
		end
	end

	-- Writes the row Dev State, which comes back in the command_done report
	-- (the dev loop shadows what the driver sets), and logs it as well, for a
	-- build whose installed driver.xml has no such row yet.
	local function dev_fan_state()
		local line = devcmds.format_state(gather(o))
		if type(opts.prop) == "function" then
			local ok, err = pcall(opts.prop, "Dev State", line)
			if not ok then
				log.warn("Dev State row not written: %s", tostring(err))
			end
		end
		log.always("Dev State: %s", line)
	end

	-- LINK 200..202 / 300..308 / 311, ACTION tap|push|click|release, COUNT, EVERY ms:
	-- ReceivedFromProxy(LINK, "DO_PUSH"/"DO_CLICK"/"DO_RELEASE") as a keypad
	-- sends them, the first at once and the rest on the controller's own timers,
	-- so the spacing is not the dev loop's 3 s poll.
	local function dev_press(params)
		params = type(params) == "table" and params or {}
		local link = whole(params.LINK)
		if not (link and PRESS_LINKS[link]) then
			return refuse("Dev Press", string.format("LINK %s is not a Button Link (200 to 202, 300 to 308, 311)",
				plain(params.LINK, 30)))
		end
		local action = type(params.ACTION) == "string" and params.ACTION:lower():match("^%s*(%a+)%s*$") or nil
		if not (action == "tap" or ACTION_COMMANDS[action or ""]) then
			return refuse("Dev Press", string.format("ACTION %s is not tap, push, click or release",
				plain(params.ACTION, 30)))
		end
		local count, why = bounded(params.COUNT, devcmds.COUNT_DEFAULT, 1, devcmds.COUNT_MAX, "COUNT")
		if not count then
			return refuse("Dev Press", why)
		end
		local every
		every, why = bounded(params.EVERY, devcmds.EVERY_DEFAULT_MS, devcmds.EVERY_MIN_MS, devcmds.EVERY_MAX_MS, "EVERY")
		if not every then
			return refuse("Dev Press", why)
		end
		log.always("Dev Press: link %d %s x%d every %d ms", link, action, count, every)
		for _, step in ipairs(press_plan(action, count, every)) do
			local at, command = step[1], step[2]
			if at == 0 then
				send(link, command, {})
			else
				set_timer(at, function() send(link, command, {}) end)
			end
		end
	end

	-- BINDING 5001 | 5002, COMMAND, and any other parameters as they are:
	-- ReceivedFromProxy(BINDING, COMMAND, params) as the proxy would call it.
	local function dev_proxy(params)
		params = type(params) == "table" and params or {}
		local binding = whole(params.BINDING)
		if not (binding and PROXY_BINDINGS[binding]) then
			return refuse("Dev Proxy", string.format("BINDING %s is not a proxy binding (5001 or 5002)",
				plain(params.BINDING, 30)))
		end
		local command = params.COMMAND
		if type(command) ~= "string" or #command > devcmds.PROXY_COMMAND_MAX or not command:match("^[%w_]+$") then
			return refuse("Dev Proxy", string.format("COMMAND %s is not a command name", plain(command, 30)))
		end
		local forwarded = {}
		for key, value in pairs(params) do
			if key ~= "BINDING" and key ~= "COMMAND" then
				forwarded[key] = value
			end
		end
		local extra = describe(forwarded)
		log.always("Dev Proxy: %d %s%s", binding, command, extra ~= "" and (" " .. extra) or "")
		send(binding, command, forwarded)
	end

	-- BODY: one of the two queries, or a body fan/wire.lua builds; sent through
	-- opts.request (the model's queue, the transport behind it) and the answer
	-- logged normalized.
	local function dev_request(params)
		params = type(params) == "table" and params or {}
		local body = params.BODY
		if type(body) ~= "string" or body == "" then
			return refuse("Dev Request", "BODY is empty")
		end
		if #body > devcmds.BODY_MAX then
			return refuse("Dev Request", string.format("BODY is longer than %d characters", devcmds.BODY_MAX))
		end
		if type(opts.request) ~= "function" then
			return refuse("Dev Request", "no request function is wired")
		end
		local wire = opts.wire
		if wire == nil then
			local ok, loaded = pcall(require, "fan.wire")
			if not ok then
				return refuse("Dev Request", "fan.wire is not available (" .. plain(loaded, 80) .. ")")
			end
			wire = loaded
		end
		local built, req, why = pcall(request_for, wire, body)
		if not built then
			return refuse("Dev Request", "the body could not be checked (" .. plain(req, 80) .. ")")
		end
		if not req then
			return refuse("Dev Request", why)
		end
		local ok, seq, reason = pcall(opts.request, req, function(result)
			local good, text = pcall(answer_text, wire, req, type(result) == "table" and result or {})
			log.always("Dev Request #%s %s", tostring(type(result) == "table" and result.seq or "?"),
				good and text or ("answer not readable: " .. plain(text, 80)))
		end)
		if not ok then
			return refuse("Dev Request", "the request function failed: " .. plain(seq, 80))
		end
		if not seq then
			return refuse("Dev Request", "not sent (" .. plain(reason or "no reason given", 40) .. ")")
		end
		log.always("Dev Request: %s %s sent as #%s", req.kind, req.body, tostring(seq))
	end

	-- MODE guarded (the default) | forced: what a click on Use Selected Fan, or on Name Items
	-- After Fan, would decide now, from the names job's plan(). It never calls the job's run()
	-- or anything that renames: the Windows session and the VM read the ids, the live names and
	-- the plan with it before anything is renamed (fan-name-design 2.4, ECR 5.6).
	local function dev_names_plan(params)
		params = type(params) == "table" and params or {}
		local job = o.names
		if type(job) ~= "table" or type(job.plan) ~= "function" then
			return refuse("Dev Names Plan", "the names job is missing")
		end
		local mode, why = plan_mode(params.MODE)
		if not mode then
			return refuse("Dev Names Plan", why)
		end
		local ok, plan = pcall(job.plan, job, mode)
		if not ok then
			return refuse("Dev Names Plan", "the plan could not be made (" .. plain(plan, 80) .. ")")
		end
		if type(plan) ~= "table" then
			return refuse("Dev Names Plan", "the names job gave no plan")
		end
		local made, line = pcall(format_plan, plan, mode)
		if not made then
			return refuse("Dev Names Plan", "the plan could not be read (" .. plain(line, 80) .. ")")
		end
		log.always("Dev Names Plan: %s; nothing was renamed", line)
	end

	-- Dev Search (auto-discovery-design 6.5): one search window as soon as the 30 s
	-- floor allows, for the house checks; the list and its log line follow by
	-- themselves, and nothing goes to Last Action.
	local function dev_search()
		local search = o.search
		if type(search) ~= "table" or type(search.poke) ~= "function" then
			return refuse("Dev Search", "the search is missing")
		end
		local ok, err = pcall(search.poke, search, "dev")
		if not ok then
			return refuse("Dev Search", "the search could not be asked (" .. plain(err, 80) .. ")")
		end
		local state = ask(o, search, "state")
		log.always("Dev Search: a window is asked for (search=%s)", plain(state, 20))
	end

	return {
		Dev_Fan_State = dev_fan_state,
		Dev_Names_Plan = dev_names_plan,
		Dev_Press = dev_press,
		Dev_Proxy = dev_proxy,
		Dev_Request = dev_request,
		Dev_Search = dev_search,
	}, stop
end

-- The redactor ---------------------------------------------------------------------------------------

-- Every non-overlapping occurrence of `needle` in `line`, any case, replaced.
local function replace_plain(line, needle, replacement)
	if needle == "" then
		return line
	end
	local low, want = line:lower(), needle:lower()
	local parts, from = {}, 1
	while true do
		local first, last = low:find(want, from, true)
		if not first then
			break
		end
		parts[#parts + 1] = line:sub(from, first - 1)
		parts[#parts + 1] = replacement
		from = last + 1
	end
	if from == 1 then
		return line
	end
	parts[#parts + 1] = line:sub(from)
	return table.concat(parts)
end

-- Whether the line holds a private key name in quotes: "owner", 'owner', or
-- \"owner\" (a JSON text inside another).
local function holds_private_key(line)
	local low = line:lower()
	for _, key in ipairs(devcmds.PRIVATE_KEYS) do
		if low:find("[\"']" .. key:lower() .. "\\*[\"']") then
			return true
		end
	end
	return false
end

-- The 12 hex digits of a MAC given with or without separators, or nil.
local function mac_digits(text)
	if type(text) ~= "string" then
		return nil
	end
	local digits = text:gsub("[^%x]", "")
	return #digits == 12 and digits or nil
end

-- The 12 hex digits a client id ends in (section 3.5: "MF_" or "WAC_" and the
-- station MAC), or nil.
local function id_digits(id)
	if type(id) ~= "string" then
		return nil
	end
	return id:match("_(%x%x%x%x%x%x%x%x%x%x%x%x)$")
end

local function remember(list, value)
	for _, known in ipairs(list) do
		if known:lower() == value:lower() then
			return
		end
	end
	list[#list + 1] = value
	if #list > 16 then
		table.remove(list, 1)
	end
end

-- `known`: { ids = { client ids }, macs = { 12 hex digits } } the redactor has
-- been told about. A line that holds a private key in quotes is withheld
-- (nil); in any other, the client ids, the MACs in both forms and the IPv4
-- addresses are replaced by <client-id>, <mac> and <ip>. Section 3.7 says the
-- address may be logged; the redactor takes it out all the same, since these
-- lines leave the controller for the VM's log and the reports built from it
-- (the last gsub drops that, if the contract's reading is to win). Shapes
-- catch what the pin does not name: another fan's id, a MAC in the colon form.
function devcmds.redact(line, known)
	if type(line) ~= "string" then
		return nil
	end
	if holds_private_key(line) then
		return nil
	end
	known = known or {}
	for _, id in ipairs(known.ids or {}) do
		line = replace_plain(line, id, "<client-id>")
	end
	line = line:gsub("[Mm][Ff]_%x%x%x%x%x%x%x%x%x%x%x%x", "<client-id>")
	line = line:gsub("[Ww][Aa][Cc]_%x%x%x%x%x%x%x%x%x%x%x%x", "<client-id>")
	line = line:gsub("%x%x:%x%x:%x%x:%x%x:%x%x:%x%x", "<mac>")
	for _, digits in ipairs(known.macs or {}) do
		line = replace_plain(line, digits, "<mac>")
	end
	line = line:gsub("(%d+)%.(%d+)%.(%d+)%.(%d+)", function(a, b, c, d)
		for _, part in ipairs({ a, b, c, d }) do
			if #part > 3 or tonumber(part) > 255 then
				return nil
			end
		end
		return "<ip>"
	end)
	return line
end

-- The function for devloop.set_redactor. `get_pin` returns the pinned
-- identity ({ client_id, mac, ... }, model:identity()) or nil; it is asked on
-- every line, and every identity it ever named stays redacted, so a line
-- buffered before a re-point or after a stop is covered too.
function devcmds.redactor(get_pin)
	local known = { ids = {}, macs = {} }
	return function(line)
		if type(get_pin) == "function" then
			local ok, pin = pcall(get_pin)
			if ok and type(pin) == "table" then
				if type(pin.client_id) == "string" and pin.client_id ~= "" then
					remember(known.ids, pin.client_id)
				end
				local digits = mac_digits(pin.mac) or id_digits(pin.client_id)
				if digits then
					remember(known.macs, digits)
				end
			end
		end
		return devcmds.redact(line, known)
	end
end

return devcmds
