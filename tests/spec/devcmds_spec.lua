-- fan.devcmds: the signed development commands of the dev build and the log
-- redactor (docs/v1-design.md, sections 3.7, 9.10 and 12), on hand-made fakes
-- of the model, the proxies, the transport and the clock: none of the sibling
-- modules is loaded. The one real neighbour is common.devloop, which hands
-- the table to the dev loop's signed `execute` and runs the redactor.
--
-- Placeholders only: fan 10.0.2.151 (a second 10.0.2.152), the VM 192.0.2.7,
-- MAC 00:00:5e:00:53:01 (12 hex 00005E005301), client id MF_00005E005301.

local devcmds = require("fan.devcmds")

-- Fakes ---------------------------------------------------------------------------------

-- A logger that keeps what it is told: { level, text } in order.
local function fake_log()
	local log = { lines = {} }
	local function add(level)
		return function(fmt, ...)
			local ok, text = pcall(string.format, fmt, ...)
			log.lines[#log.lines + 1] = { level = level, text = ok and text or tostring(fmt) }
		end
	end
	log.always, log.warn, log.info, log.debug, log.error = add("always"), add("warn"), add("info"), add("debug"),
		add("error")
	-- The texts logged at `level` (all levels when nil).
	function log.texts(level)
		local out = {}
		for _, line in ipairs(log.lines) do
			if level == nil or line.level == level then out[#out + 1] = line.text end
		end
		return out
	end
	return log
end

-- A clock the spec moves: make(ms, cb) is C4:SetTimer's stand-in, with the
-- :Cancel() of a C4LuaTimer. advance(ms) fires what falls due, in due order
-- (arming order among equals), including timers armed meanwhile.
local function fake_timers()
	local clock = { list = {}, now = 0 }
	function clock.make(ms, cb)
		local timer = { at = clock.now + ms, cb = cb, ms = ms }
		function timer:Cancel() self.cancelled = true end
		clock.list[#clock.list + 1] = timer
		return timer
	end
	function clock.advance(ms)
		local target = clock.now + ms
		while true do
			local next_timer
			for _, timer in ipairs(clock.list) do
				if not timer.fired and not timer.cancelled and timer.at <= target
					and (not next_timer or timer.at < next_timer.at) then
					next_timer = timer
				end
			end
			if not next_timer then break end
			clock.now = next_timer.at
			next_timer.fired = true
			next_timer.cb()
		end
		clock.now = target
	end
	-- Timers armed and neither fired nor cancelled.
	function clock.waiting()
		local n = 0
		for _, timer in ipairs(clock.list) do
			if not timer.fired and not timer.cancelled then n = n + 1 end
		end
		return n
	end
	return clock
end

-- The model of section 9.5 as far as Dev State asks it (phase, debug, confirmed,
-- shown, busy, info), holding what the spec sets in m.st.
local function fake_model(over)
	local st = {
		phase = "online", seq = 231, ms = 310,
		confirmed = { fan_on = true, speed = 3, direction = "forward", light_on = true, level = 40 },
		shown = { fan_on = true, speed = 3, direction = "forward", light_on = true, level = 40 },
		busy = {}, info = { has_light = true },
	}
	for key, value in pairs(over or {}) do st[key] = value end
	local m = { st = st }
	function m.phase() return st.phase, {} end
	function m.debug() return { seq = st.seq, ms = st.ms } end
	function m.confirmed() return st.confirmed end
	function m.shown() return st.shown end
	function m.busy(_, group) return st.busy[group] == true end
	function m.info() return st.info end
	return m
end

-- The three debug() reports of section 9.7 to 9.9 with the numbers of
-- section 12's example line.
local function fake_fan(over)
	local report = { told_fan = 3, told_dir = "forward", notify_fan = 12, notify_dir = 1, preset = 3 }
	for key, value in pairs(over or {}) do report[key] = value end
	return { debug = function() return report end, report = report }
end

local function fake_links(leds)
	leds = leds or { [300] = false, [301] = false, [302] = false, [303] = true, [304] = false, [305] = false,
		[306] = false, [307] = true, [308] = true }
	return { debug = function() return { leds = leds, bound = 5 } end }
end

local function fake_light(over)
	local report = { told_level = 40, changing_open = false, notify_light = 8, ramping = false }
	for key, value in pairs(over or {}) do report[key] = value end
	return { debug = function() return report end, report = report }
end

-- The names job of fan-name-design 2.2 as far as Dev Names Plan asks it: plan(mode) answers a
-- copy of the table the spec gives, with the mode it was asked for, and job.modes says which
-- modes it was asked for. run() is there to be caught: the command must never reach it.
local function fake_names(plan)
	local job = { modes = {}, ran = 0 }
	function job.plan(_, mode)
		job.modes[#job.modes + 1] = mode
		local copy = {}
		for key, value in pairs(plan) do copy[key] = value end
		copy.mode = mode
		return copy
	end
	function job.run()
		job.ran = job.ran + 1
		error("Dev Names Plan must not run the job")
	end
	return job
end

-- What the job plans for the house fan (type 1811-5-54, named Aviator 5 by the contract)
-- while both items still have their shipped names, and the line Dev Names Plan prints for it.
local PLAN = {
	outcome = "renamed", fan_type = "1811-5-54", fan_id = 1205, light_id = 1206,
	fan_live = "Modern Forms Fan", light_live = "Modern Forms Fan Light",
	fan_to = "Aviator 5", light_to = "Aviator 5 Light", fan_ours = true, light_ours = true,
}

local function plan_line(mode)
	return "Dev Names Plan: mode=" .. mode .. ' would=renamed fan_type=1811-5-54 fan_id=1205 '
		.. 'fan_live="Modern Forms Fan" fan_to="Aviator 5" fan_ours=1 light_id=1206 '
		.. 'light_live="Modern Forms Fan Light" light_to="Aviator 5 Light" light_ours=1; nothing was renamed'
end

-- A fan/wire.lua with the surface devcmds uses: constants, decode, body
-- (section 9.3's refusals: unknown, mix, range, empty), state and info.
local function fake_wire()
	local wire = {
		PATH = "/mf", QUERY_STATE = '{"queryDynamicShadowData":1}', QUERY_INFO = '{"queryStaticShadowData":1}',
	}
	-- A flat JSON object: "key":true|false|number|"text"; anything else is not an object.
	function wire.decode(text)
		if type(text) ~= "string" or not text:find("%S") then return nil, "empty" end
		if not text:match("^%s*{.*}%s*$") then return nil, "json" end
		local obj = {}
		for key, value in text:gmatch('"([%w]+)"%s*:%s*([^,}]+)') do
			if value == "true" then obj[key] = true
			elseif value == "false" then obj[key] = false
			elseif tonumber(value) then obj[key] = tonumber(value)
			else obj[key] = (value:gsub('^"(.*)"$', "%1")) end
		end
		return obj
	end
	local GROUP = { fan_on = "fan", speed = "fan", direction = "direction", level = "light", light_on = "light",
		away = "away", learning = "learning" }
	function wire.body(fields)
		local group
		for key in pairs(fields) do
			if not GROUP[key] then return nil, "unknown" end
			if group and group ~= GROUP[key] then return nil, "mix" end
			group = GROUP[key]
		end
		if not group then return nil, "empty" end
		if group == "fan" then
			if fields.fan_on == false then return '{"fanOn":false}' end
			if fields.fan_on ~= true or type(fields.speed) ~= "number" or fields.speed < 1 or fields.speed > 6 then
				return nil, "range"
			end
			return string.format('{"fanOn":true,"fanSpeed":%d}', fields.speed)
		elseif group == "light" then
			if fields.level ~= nil then
				if type(fields.level) ~= "number" or fields.level < 1 or fields.level > 100 then return nil, "range" end
				return string.format('{"lightBrightness":%d}', fields.level)
			end
			return string.format('{"lightOn":%s}', tostring(fields.light_on))
		end
		return nil, "range"
	end
	function wire.state(obj)
		if type(obj) ~= "table" or not obj.clientId then return nil, "json" end
		return { client_id = obj.clientId, fan_on = obj.fanOn, speed = obj.fanSpeed, direction = obj.fanDirection,
			light_on = obj.lightOn, level = obj.lightBrightness }
	end
	function wire.info(obj)
		if type(obj) ~= "table" or not obj.clientId then return nil, "json" end
		return { client_id = obj.clientId, firmware = obj.firmwareVersion, has_light = obj.lightType ~= "" }
	end
	return wire
end

-- The contract's example line (section 12).
local EXAMPLE = "phase=online seq=231 fan=on/3 dir=forward light=on/40 shown.fan=on/3 shown.light=on/40 busy=- "
	.. "told.fan=3 told.dir=forward told.light=40 notify.fan=12 notify.dir=1 notify.light=8 changing=0 "
	.. "leds=300:0,301:0,302:0,303:1,304:0,305:0,306:0,307:1,308:1,200:1,201:0,202:1 follow=idle search=quiet ms=310"

-- The keys of Dev State, in the order section 12 gives them.
local KEYS = { "phase", "seq", "fan", "dir", "light", "shown.fan", "shown.light", "busy", "told.fan", "told.dir",
	"told.light", "notify.fan", "notify.dir", "notify.light", "changing", "leds", "follow", "search", "ms" }

local PIN = { client_id = "MF_00005E005301", mac = "00005E005301", generation = "3", address = "10.0.2.151" }

-- A devcmds.new on fakes: the commands, stop(), and what they touched.
local function new_commands(over)
	local env = { log = fake_log(), clock = fake_timers(), injected = {}, rows = {}, requests = {} }
	env.model, env.fan, env.links, env.light = fake_model(), fake_fan(), fake_links(), fake_light()
	env.wire = fake_wire()
	for key, value in pairs(over or {}) do env[key] = value end
	env.commands, env.stop = devcmds.new({
		model = env.model, fan = env.fan, links = env.links, light = env.light, names = env.names, log = env.log,
		follow = env.follow or { state = function() return "idle" end },
		search = env.search or {
			state = function() return env.search_state or "quiet" end,
			poke = function(_, why) env.poked = why end,
		},
		prop = env.prop or function(name, value) env.rows[name] = value end,
		inject = env.inject or function(binding, command, params)
			env.injected[#env.injected + 1] = { binding, command, params }
		end,
		timer = env.timer or env.clock.make,
		request = env.request,
		wire = env.wire,
	})
	return env
end

-- The messages Dev Press and Dev Proxy have injected, as "binding command".
local function injected(env)
	local out = {}
	for _, call in ipairs(env.injected) do out[#out + 1] = call[1] .. " " .. call[2] end
	return out
end

local function warned(env)
	return env.log.texts("warn")
end

-- The fields of a Dev State line, as a table.
local function fields_of(line)
	local out = {}
	for key, value in line:gmatch("(%S-)=(%S*)") do out[key] = value end
	return out
end

describe("fan.devcmds", function()
	describe("the table for devloop.set_signed_commands", function()
		it("holds the six commands of section 12, fan-name-design 2.4 and auto-discovery-design 6.5 under the names "
			.. "common/dispatch.lua gives them, and nothing else", function()
				local env = new_commands()
				local names = {}
				for name, fn in pairs(env.commands) do
					assert.is_function(fn, name)
					names[#names + 1] = name
				end
				table.sort(names)
				assert.same({ "Dev_Fan_State", "Dev_Names_Plan", "Dev_Press", "Dev_Proxy", "Dev_Request", "Dev_Search" },
					names)
				assert.is_function(env.stop)
			end)

		it("works with nothing but a logger: every command refuses or says so instead of raising", function()
			local log = fake_log()
			local commands = devcmds.new({ log = log })
			assert.has_no.errors(function()
				commands.Dev_Fan_State()
				commands.Dev_Names_Plan({ MODE = "forced" })
				commands.Dev_Press({ LINK = "303", ACTION = "tap" })
				commands.Dev_Proxy({ BINDING = "5001", COMMAND = "ON" })
				commands.Dev_Request({ BODY = '{"queryDynamicShadowData":1}' })
				commands.Dev_Search()
				commands.Dev_Press(nil)
			end)
			assert.is_true(#log.texts("warn") >= 6)
		end)

		it("Dev Search pokes the search with \"dev\" and logs its state; nothing else", function()
			local env = new_commands({ search_state = "due:12" })
			env.commands.Dev_Search()
			assert.equal("dev", env.poked)
			assert.same({ "Dev Search: a window is asked for (search=due:12)" }, env.log.texts("always"))
			assert.same({}, warned(env))
		end)

		it("Dev Search refuses when the search raises", function()
			local env = new_commands({ search = { poke = function() error("boom") end } })
			env.commands.Dev_Search()
			assert.equal(1, #warned(env))
			assert.truthy(warned(env)[1]:find("Dev Search refused", 1, true))
		end)

		it("falls back to common.log when no logger is given", function()
			local commands = devcmds.new({})
			assert.is_function(commands.Dev_Press)
		end)
	end)

	describe("Dev Fan State", function()
		it("writes section 12's example line to the row Dev State and logs it", function()
			local env = new_commands()
			env.commands.Dev_Fan_State({})
			assert.equal(EXAMPLE, env.rows["Dev State"])
			assert.same({ "Dev State: " .. EXAMPLE }, env.log.texts("always"))
		end)

		it("has the keys of section 12 in that order", function()
			local env = new_commands()
			env.commands.Dev_Fan_State()
			local keys = {}
			for key in env.rows["Dev State"]:gmatch("(%S-)=") do keys[#keys + 1] = key end
			assert.same(KEYS, keys)
		end)

		it("is one line: no newline, no tab, single spaces between pairs", function()
			local env = new_commands()
			env.commands.Dev_Fan_State()
			assert.is_nil(env.rows["Dev State"]:find("[\n\r\t]"))
			assert.is_nil(env.rows["Dev State"]:find("  ", 1, true))
		end)

		it("reads off states: fan=off and light=off carry no speed or level", function()
			local env = new_commands({ model = fake_model({
				confirmed = { fan_on = false, speed = 4, direction = "reverse", light_on = false, level = 100 },
				shown = { fan_on = false, speed = 4, light_on = false, level = 100 },
			}) })
			env.commands.Dev_Fan_State()
			local f = fields_of(env.rows["Dev State"])
			assert.equal("off", f.fan)
			assert.equal("off", f.light)
			assert.equal("off", f["shown.fan"])
			assert.equal("off", f["shown.light"])
			assert.equal("reverse", f.dir)
		end)

		it("derives the light buttons' LEDs by section 5.2's rule: top and toggle lit while on, bottom while off",
			function()
				local env = new_commands({ model = fake_model({
					shown = { fan_on = true, speed = 3, light_on = false, level = 100 },
				}) })
				env.commands.Dev_Fan_State()
				assert.truthy(env.rows["Dev State"]:find("leds=[%d:,]+,200:0,201:1,202:0 ", 1))
			end)

		it("takes the light buttons' LEDs from the links, else from the light, before deriving them", function()
			local leds = { [300] = false, [303] = true, [200] = false, [201] = true }
			local env = new_commands({ links = fake_links(leds),
				light = fake_light({ leds = { [201] = false, [202] = true } }) })
			env.commands.Dev_Fan_State()
			-- 200 and 201 from the links, 202 from the light (the shown light is on: derived would be 1 as well,
			-- so 201 is the one that proves the order)
			assert.truthy(env.rows["Dev State"]:find("200:0,201:1,202:1 ", 1, true))
			local env2 = new_commands({ links = fake_links({ [303] = true }),
				light = fake_light({ leds = { [200] = false, [201] = true, [202] = false } }) })
			env2.commands.Dev_Fan_State()
			assert.truthy(env2.rows["Dev State"]:find("200:0,201:1,202:0 ", 1, true))
		end)

		it("writes ? for an unknown value and - for none", function()
			local env = new_commands({ links = fake_links({}) })
			env.model.st.phase = "waiting"
			env.model.st.confirmed, env.model.st.shown = nil, {}
			env.model.st.seq, env.model.st.ms = nil, nil
			env.fan.report.told_fan, env.fan.report.told_dir, env.fan.report.notify_dir = nil, nil, nil
			env.light.report.told_level, env.light.report.notify_light = nil, nil
			env.commands.Dev_Fan_State()
			local f = fields_of(env.rows["Dev State"])
			assert.equal("waiting", f.phase)
			assert.equal("?", f.seq)
			assert.equal("?", f.fan)
			assert.equal("?", f.dir)
			assert.equal("?", f.light)
			assert.equal("?", f["shown.fan"])
			assert.equal("-", f.busy)
			assert.equal("-", f["told.fan"])
			assert.equal("-", f["told.dir"])
			assert.equal("-", f["told.light"])
			assert.equal("?", f["notify.dir"])
			assert.equal("?", f["notify.light"])
			assert.equal("?", f.ms)
			assert.truthy(f.leds:find("300:?,301:?", 1, true))
			assert.truthy(f.leds:find("200:?,201:?,202:?", 1, true))
		end)

		it("writes ? for everything a missing module would have said", function()
			local log = fake_log()
			local rows = {}
			local commands = devcmds.new({ log = log, prop = function(name, value) rows[name] = value end })
			commands.Dev_Fan_State()
			local f = fields_of(rows["Dev State"])
			for _, key in ipairs({ "phase", "seq", "fan", "dir", "light", "shown.fan", "shown.light", "busy",
				"told.fan", "told.dir", "told.light", "notify.fan", "notify.dir", "notify.light", "changing", "ms" }) do
				assert.equal("?", f[key], key)
			end
			assert.equal("300:?,301:?,302:?,303:?,304:?,305:?,306:?,307:?,308:?,200:?,201:?,202:?", f.leds)
		end)

		it("lists the busy groups by name, in the order fan, direction, light", function()
			local env = new_commands({ model = fake_model({ busy = { light = true, fan = true } }) })
			env.commands.Dev_Fan_State()
			assert.equal("fan,light", fields_of(env.rows["Dev State"]).busy)
			env.model.st.busy = { direction = true }
			env.commands.Dev_Fan_State()
			assert.equal("direction", fields_of(env.rows["Dev State"]).busy)
			env.model.st.busy = { light = true, direction = true, fan = true }
			env.commands.Dev_Fan_State()
			assert.equal("fan,direction,light", fields_of(env.rows["Dev State"]).busy)
		end)

		it("shows an open CHANGING as changing=1 and a closed one as changing=0", function()
			local env = new_commands()
			env.light.report.changing_open = true
			env.commands.Dev_Fan_State()
			assert.equal("1", fields_of(env.rows["Dev State"]).changing)
			env.light.report.changing_open = nil -- a light that keeps the flag only while it is open
			env.commands.Dev_Fan_State()
			assert.equal("0", fields_of(env.rows["Dev State"]).changing)
		end)

		it("reads a light kit that is not there as '-' for the light's fields", function()
			local env = new_commands({ model = fake_model({
				confirmed = { fan_on = true, speed = 2, direction = "forward" },
				shown = { fan_on = true, speed = 2 }, info = { has_light = false },
			}), light = fake_light({ told_level = nil }) })
			env.commands.Dev_Fan_State()
			local f = fields_of(env.rows["Dev State"])
			assert.equal("-", f.light)
			assert.equal("-", f["shown.light"])
			assert.equal("on/2", f.fan)
			assert.truthy(f.leds:find("200:?,201:?,202:?", 1, true))
		end)

		it("keeps whatever a module reports to one word: no white space, no '=', lower-case directions", function()
			local env = new_commands({ model = fake_model({ phase = "not a=fan" }),
				fan = fake_fan({ told_dir = "REVERSE" }) })
			env.commands.Dev_Fan_State()
			local f = fields_of(env.rows["Dev State"])
			assert.equal("not_a_fan", f.phase)
			assert.equal("reverse", f["told.dir"])
		end)

		it("writes whole numbers without a decimal point and others with two places", function()
			local line = devcmds.format_state({ seq = 5.0, ms = 310.4, notify_fan = 2.5, shown = {} })
			local f = fields_of(line)
			assert.equal("5", f.seq)
			assert.equal("310.40", f.ms)
			assert.equal("2.50", f["notify.fan"])
		end)

		it("survives a module whose debug() raises: that module's keys read ?, the rest is there, a warning says why",
			function()
				local env = new_commands()
				env.fan.debug = function() error("kaput") end
				env.model.debug = function() error("also kaput") end
				env.commands.Dev_Fan_State()
				local f = fields_of(env.rows["Dev State"])
				assert.equal("?", f.seq)
				assert.equal("?", f["told.fan"])
				assert.equal("?", f["notify.dir"])
				assert.equal("on/3", f.fan)
				assert.equal("on/40", f.light)
				local joined = table.concat(warned(env), "\n")
				assert.truthy(joined:find("kaput", 1, true))
				assert.truthy(joined:find("also kaput", 1, true))
			end)

		it("survives a model that cannot answer", function()
			local env = new_commands()
			for _, method in ipairs({ "phase", "confirmed", "shown", "info", "busy" }) do
				env.model[method] = function() error("no " .. method) end
			end
			assert.has_no.errors(function() env.commands.Dev_Fan_State() end)
			local f = fields_of(env.rows["Dev State"])
			assert.equal("?", f.phase)
			assert.equal("?", f.fan)
			assert.equal("?", f.busy)
		end)

		it("takes a busy() that answers nothing for a group as not busy, one that is missing as unknown", function()
			local env = new_commands()
			env.model.busy = function() return nil end
			env.commands.Dev_Fan_State()
			assert.equal("-", fields_of(env.rows["Dev State"]).busy)
			env.model.busy = nil
			env.commands.Dev_Fan_State()
			assert.equal("?", fields_of(env.rows["Dev State"]).busy)
		end)

		it("logs the line even when the row cannot be written", function()
			local env = new_commands({ prop = function() error("no such property") end })
			assert.has_no.errors(function() env.commands.Dev_Fan_State() end)
			assert.same({ "Dev State: " .. EXAMPLE }, env.log.texts("always"))
			assert.truthy(table.concat(warned(env), "\n"):find("no such property", 1, true))
		end)

		it("passes the command's own parameters by: any params table is fine", function()
			local env = new_commands()
			assert.has_no.errors(function()
				env.commands.Dev_Fan_State({ ANYTHING = "x" })
				env.commands.Dev_Fan_State(nil)
			end)
			assert.equal(EXAMPLE, env.rows["Dev State"])
		end)
	end)

	describe("Dev Press", function()
		it("sends one DO_PUSH, DO_CLICK or DO_RELEASE with the link as a number and no parameters", function()
			for action, command in pairs({ push = "DO_PUSH", click = "DO_CLICK", release = "DO_RELEASE" }) do
				local env = new_commands()
				env.commands.Dev_Press({ LINK = "303", ACTION = action })
				assert.same({ { 303, command, {} } }, env.injected, action)
				assert.equal("number", type(env.injected[1][1]), action)
				assert.equal(0, env.clock.waiting(), action)
			end
		end)

		it("makes a tap a push now and a click 100 ms later, timed on the controller", function()
			local env = new_commands()
			env.commands.Dev_Press({ LINK = "200", ACTION = "tap" })
			assert.same({ "200 DO_PUSH" }, injected(env))
			assert.equal(1, env.clock.waiting())
			env.clock.advance(99)
			assert.same({ "200 DO_PUSH" }, injected(env))
			env.clock.advance(1)
			assert.same({ "200 DO_PUSH", "200 DO_CLICK" }, injected(env))
			assert.equal(0, env.clock.waiting())
		end)

		it("repeats COUNT times EVERY ms apart, the first at once", function()
			local env = new_commands()
			env.commands.Dev_Press({ LINK = "308", ACTION = "push", COUNT = "3", EVERY = "150" })
			assert.same({ "308 DO_PUSH" }, injected(env))
			env.clock.advance(149)
			assert.equal(1, #env.injected)
			env.clock.advance(1)
			assert.equal(2, #env.injected)
			env.clock.advance(150)
			assert.equal(3, #env.injected)
			env.clock.advance(10000)
			assert.equal(3, #env.injected)
		end)

		it("repeats taps with the click of each 100 ms after its push (F5: Dev Press 308 tap COUNT=3 EVERY=150)",
			function()
				local env = new_commands()
				env.commands.Dev_Press({ LINK = "308", ACTION = "tap", COUNT = "3", EVERY = "150" })
				env.clock.advance(1000)
				assert.same({ "308 DO_PUSH", "308 DO_CLICK", "308 DO_PUSH", "308 DO_CLICK", "308 DO_PUSH",
					"308 DO_CLICK" }, injected(env))
				-- push at 0, 150, 300 and click at 100, 250, 400: five timers armed, the first push went at once
				local armed = {}
				for _, timer in ipairs(env.clock.list) do armed[#armed + 1] = timer.ms end
				table.sort(armed)
				assert.same({ 100, 150, 250, 300, 400 }, armed)
			end)

		it("keeps each tap's push before its click, and a click before the next push, when EVERY is 100", function()
			local env = new_commands()
			env.commands.Dev_Press({ LINK = "303", ACTION = "tap", COUNT = "2", EVERY = "100" })
			env.clock.advance(500)
			assert.same({ "303 DO_PUSH", "303 DO_CLICK", "303 DO_PUSH", "303 DO_CLICK" }, injected(env))
		end)

		it("defaults to COUNT 1 and EVERY 300", function()
			local env = new_commands()
			env.commands.Dev_Press({ LINK = "303", ACTION = "push" })
			env.clock.advance(5000)
			assert.equal(1, #env.injected)
			local env2 = new_commands()
			env2.commands.Dev_Press({ LINK = "303", ACTION = "push", COUNT = "2" })
			env2.clock.advance(299)
			assert.equal(1, #env2.injected)
			env2.clock.advance(1)
			assert.equal(2, #env2.injected)
			assert.equal(300, env2.clock.list[1].ms)
		end)

		it("takes an empty COUNT or EVERY (devctl.py run ... COUNT=) as no parameter", function()
			local env = new_commands()
			env.commands.Dev_Press({ LINK = "303", ACTION = "push", COUNT = "", EVERY = "  " })
			env.clock.advance(5000)
			assert.equal(1, #env.injected)
			assert.same({}, warned(env))
		end)

		it("accepts every Button Link: 200 to 202 and 300 to 308", function()
			local ids = { 200, 201, 202, 300, 301, 302, 303, 304, 305, 306, 307, 308 }
			for _, id in ipairs(ids) do
				local env = new_commands()
				env.commands.Dev_Press({ LINK = tostring(id), ACTION = "push" })
				assert.same({ { id, "DO_PUSH", {} } }, env.injected, tostring(id))
			end
		end)

		it("accepts numbers as well as strings, any case and padding of the action", function()
			local env = new_commands()
			env.commands.Dev_Press({ LINK = 303, ACTION = " TAP ", COUNT = 2, EVERY = 200 })
			env.clock.advance(1000)
			assert.same({ "303 DO_PUSH", "303 DO_CLICK", "303 DO_PUSH", "303 DO_CLICK" }, injected(env))
			local env2 = new_commands()
			env2.commands.Dev_Press({ LINK = " 305 ", ACTION = "Release" })
			assert.same({ "305 DO_RELEASE" }, injected(env2))
		end)

		it("refuses a LINK that is not one of the twelve, sending nothing and saying so", function()
			for _, bad in ipairs({ "199", "203", "209", "299", "309", "319", "5001", "0", "abc", "", "30x", "-1",
				"303.5", "0x12F", "1e2", "1000000000000" }) do
				local env = new_commands()
				env.commands.Dev_Press({ LINK = bad, ACTION = "tap" })
				assert.same({}, env.injected, bad)
				assert.equal(0, env.clock.waiting(), bad)
				assert.equal(1, #warned(env), bad)
				assert.truthy(warned(env)[1]:find("^Dev Press refused: LINK"), bad)
			end
			for _, bad in ipairs({ 199, 303.5, -303, 1e12 }) do
				local env = new_commands()
				env.commands.Dev_Press({ LINK = bad, ACTION = "tap" })
				assert.same({}, env.injected, tostring(bad))
			end
			local env = new_commands()
			env.commands.Dev_Press({ ACTION = "tap" })
			env.commands.Dev_Press({})
			env.commands.Dev_Press(nil)
			assert.same({}, env.injected)
			assert.equal(3, #warned(env))
		end)

		it("refuses an ACTION that is not tap, push, click or release", function()
			for _, bad in ipairs({ "", "double", "taps", "hold", "DO_PUSH", "t ap", "tap2" }) do
				local env = new_commands()
				env.commands.Dev_Press({ LINK = "303", ACTION = bad })
				assert.same({}, env.injected, bad)
				assert.truthy(warned(env)[1]:find("^Dev Press refused: ACTION"), bad)
			end
			local env = new_commands()
			env.commands.Dev_Press({ LINK = "303" })
			env.commands.Dev_Press({ LINK = "303", ACTION = 5 })
			assert.same({}, env.injected)
			assert.equal(2, #warned(env))
		end)

		it("refuses a COUNT outside 1 to 100 and an EVERY outside 10 to 60000 ms", function()
			for _, bad in ipairs({ "0", "101", "abc", "-1", "2.5", "1000000000", "one" }) do
				local env = new_commands()
				env.commands.Dev_Press({ LINK = "303", ACTION = "push", COUNT = bad })
				assert.same({}, env.injected, "COUNT " .. bad)
				assert.truthy(warned(env)[1]:find("^Dev Press refused: COUNT"), bad)
			end
			for _, bad in ipairs({ "0", "9", "60001", "fast", "-5", "1.5" }) do
				local env = new_commands()
				env.commands.Dev_Press({ LINK = "303", ACTION = "push", EVERY = bad })
				assert.same({}, env.injected, "EVERY " .. bad)
				assert.truthy(warned(env)[1]:find("^Dev Press refused: EVERY"), bad)
			end
			for _, good in ipairs({ { "1", "10" }, { "100", "60000" } }) do
				local env = new_commands()
				env.commands.Dev_Press({ LINK = "303", ACTION = "push", COUNT = good[1], EVERY = good[2] })
				assert.same({}, warned(env))
				assert.equal(1, #env.injected)
			end
		end)

		it("echoes a bad value with its control characters replaced, so it cannot forge a log line", function()
			local env = new_commands()
			env.commands.Dev_Press({ LINK = "303\nFAKE LINE", ACTION = "tap" })
			assert.is_nil(warned(env)[1]:find("\n", 1, true))
			assert.truthy(warned(env)[1]:find("303?FAKE LINE", 1, true))
		end)

		it("says what it presses: link, action, count, spacing", function()
			local env = new_commands()
			env.commands.Dev_Press({ LINK = "308", ACTION = "tap", COUNT = "3", EVERY = "150" })
			assert.same({ "Dev Press: link 308 tap x3 every 150 ms" }, env.log.texts("always"))
		end)

		it("stop() cancels the presses still waiting for their timers", function()
			local env = new_commands()
			env.commands.Dev_Press({ LINK = "308", ACTION = "tap", COUNT = "3", EVERY = "150" })
			assert.equal(5, env.clock.waiting())
			env.clock.advance(120)
			assert.equal(2, #env.injected)
			env.stop()
			assert.equal(0, env.clock.waiting())
			env.clock.advance(5000)
			assert.equal(2, #env.injected)
			env.stop() -- twice is harmless
		end)

		it("does not cancel a timer that has fired", function()
			local env = new_commands()
			env.commands.Dev_Press({ LINK = "200", ACTION = "tap" })
			env.clock.advance(100)
			env.stop()
			assert.is_nil(env.clock.list[1].cancelled)
		end)

		it("contains an inject that raises: said once per message, the rest of the burst still runs", function()
			local calls = 0
			local env = new_commands({ inject = function() calls = calls + 1 error("handler kaput") end })
			assert.has_no.errors(function()
				env.commands.Dev_Press({ LINK = "303", ACTION = "push", COUNT = "2", EVERY = "100" })
				env.clock.advance(100)
			end)
			assert.equal(2, calls)
			assert.equal(2, #warned(env))
			assert.truthy(warned(env)[1]:find("handler kaput", 1, true))
		end)

		it("says so when no inject function is wired", function()
			local log = fake_log()
			local commands = devcmds.new({ log = log })
			commands.Dev_Press({ LINK = "303", ACTION = "push" })
			assert.truthy(log.texts("warn")[1]:find("no inject function", 1, true))
		end)

		it("falls back to C4:SetTimer when no timer function is wired", function()
			-- busted runs a spec file in its own environment: the global is set the way fake_c4 sets it
			local saved = rawget(_G, "C4")
			local armed = {}
			rawset(_G, "C4", { SetTimer = function(_, ms, cb)
				local timer = { ms = ms, cb = cb }
				function timer:Cancel() self.cancelled = true end
				armed[#armed + 1] = timer
				return timer
			end })
			local ok, err = pcall(function()
				local calls = {}
				local commands, stop = devcmds.new({ log = fake_log(),
					inject = function(binding, command) calls[#calls + 1] = binding .. " " .. command end })
				commands.Dev_Press({ LINK = "200", ACTION = "tap" })
				assert.same({ "200 DO_PUSH" }, calls)
				assert.equal(1, #armed)
				assert.equal(100, armed[1].ms)
				armed[1].cb()
				assert.same({ "200 DO_PUSH", "200 DO_CLICK" }, calls)
				commands.Dev_Press({ LINK = "200", ACTION = "push", COUNT = "2" })
				stop()
				assert.is_true(armed[2].cancelled)
			end)
			rawset(_G, "C4", saved)
			assert(ok, err)
		end)

		it("survives a timer function that fails: the immediate press is sent, the rest is said to be lost", function()
			local env = new_commands({ timer = function() error("no timers here") end })
			assert.has_no.errors(function()
				env.commands.Dev_Press({ LINK = "200", ACTION = "tap" })
			end)
			assert.same({ "200 DO_PUSH" }, injected(env))
			assert.truthy(warned(env)[1]:find("no timers here", 1, true))
		end)

		it("copes with a timer that fires inside the call that made it", function()
			local env = new_commands({ timer = function(_, cb)
				cb()
				return { Cancel = function() end }
			end })
			env.commands.Dev_Press({ LINK = "200", ACTION = "tap" })
			assert.same({ "200 DO_PUSH", "200 DO_CLICK" }, injected(env))
			assert.has_no.errors(function() env.stop() end)
		end)
	end)

	describe("Dev Proxy", function()
		it("hands ReceivedFromProxy the binding as a number, the command, and the other parameters as they came",
			function()
				local env = new_commands()
				env.commands.Dev_Proxy({ BINDING = "5001", COMMAND = "SET_SPEED", SPEED = "3" })
				assert.same({ { 5001, "SET_SPEED", { SPEED = "3" } } }, env.injected)
				assert.equal("number", type(env.injected[1][1]))
			end)

		it("reaches the light proxy with a light_v2 target (F6)", function()
			local env = new_commands()
			env.commands.Dev_Proxy({ BINDING = "5002", COMMAND = "SET_BRIGHTNESS_TARGET",
				LIGHT_BRIGHTNESS_TARGET = "70", RATE = "0" })
			assert.same({ { 5002, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "70", RATE = "0" } } },
				env.injected)
		end)

		it("sends {} when there are no other parameters, and does not touch the caller's table", function()
			local env = new_commands()
			local params = { BINDING = "5001", COMMAND = "TOGGLE" }
			env.commands.Dev_Proxy(params)
			assert.same({ { 5001, "TOGGLE", {} } }, env.injected)
			assert.same({ BINDING = "5001", COMMAND = "TOGGLE" }, params)
			assert.not_equal(params, env.injected[1][3])
		end)

		it("keeps the value types of the other parameters", function()
			local env = new_commands()
			env.commands.Dev_Proxy({ BINDING = 5002, COMMAND = "SET_LEVEL", LEVEL = 50, FLAG = true })
			assert.same({ { 5002, "SET_LEVEL", { LEVEL = 50, FLAG = true } } }, env.injected)
		end)

		it("refuses a BINDING other than 5001 or 5002", function()
			for _, bad in ipairs({ "5000", "5003", "200", "300", "6001", "abc", "", "5001x", "-5001", "5001.5" }) do
				local env = new_commands()
				env.commands.Dev_Proxy({ BINDING = bad, COMMAND = "ON" })
				assert.same({}, env.injected, bad)
				assert.truthy(warned(env)[1]:find("^Dev Proxy refused: BINDING"), bad)
			end
			local env = new_commands()
			env.commands.Dev_Proxy({ COMMAND = "ON" })
			env.commands.Dev_Proxy(nil)
			assert.same({}, env.injected)
			assert.equal(2, #warned(env))
		end)

		it("refuses a COMMAND that is not a plain name", function()
			for _, bad in ipairs({ "", "SET SPEED", "SET-SPEED", "ON;OFF", "ON\n", string.rep("A", 65) }) do
				local env = new_commands()
				env.commands.Dev_Proxy({ BINDING = "5001", COMMAND = bad })
				assert.same({}, env.injected, bad)
				assert.truthy(warned(env)[1]:find("^Dev Proxy refused: COMMAND"), bad)
			end
			local env = new_commands()
			env.commands.Dev_Proxy({ BINDING = "5001" })
			env.commands.Dev_Proxy({ BINDING = "5001", COMMAND = 5 })
			assert.same({}, env.injected)
			assert.equal(2, #warned(env))
			local ok = new_commands()
			ok.commands.Dev_Proxy({ BINDING = "5001", COMMAND = string.rep("A", 64) })
			assert.equal(1, #ok.injected)
		end)

		it("logs the command with its parameters sorted, control characters replaced", function()
			local env = new_commands()
			env.commands.Dev_Proxy({ BINDING = "5002", COMMAND = "SET_BRIGHTNESS_TARGET", RATE = "0",
				LIGHT_BRIGHTNESS_TARGET = "30" })
			env.commands.Dev_Proxy({ BINDING = "5001", COMMAND = "SET_SPEED", SPEED = "3\nforged" })
			env.commands.Dev_Proxy({ BINDING = "5001", COMMAND = "ON" })
			assert.same({
				"Dev Proxy: 5002 SET_BRIGHTNESS_TARGET LIGHT_BRIGHTNESS_TARGET=30 RATE=0",
				"Dev Proxy: 5001 SET_SPEED SPEED=3?forged",
				"Dev Proxy: 5001 ON",
			}, env.log.texts("always"))
		end)

		it("contains an inject that raises", function()
			local env = new_commands({ inject = function() error("proxy handler kaput") end })
			assert.has_no.errors(function()
				env.commands.Dev_Proxy({ BINDING = "5001", COMMAND = "ON" })
			end)
			assert.truthy(warned(env)[1]:find("proxy handler kaput", 1, true))
		end)
	end)

	describe("Dev Request", function()
		-- A request function that records what it is given and answers with a sequence number.
		local function recording()
			local seen = { reqs = {}, callbacks = {} }
			seen.request = function(req, cb)
				seen.reqs[#seen.reqs + 1] = req
				seen.callbacks[#seen.callbacks + 1] = cb
				return 40 + #seen.reqs
			end
			return seen
		end

		it("sends the two queries as the kinds state and info", function()
			local seen = recording()
			local env = new_commands({ request = seen.request })
			env.commands.Dev_Request({ BODY = '{"queryDynamicShadowData":1}' })
			env.commands.Dev_Request({ BODY = '{"queryStaticShadowData":1}' })
			assert.same({
				{ kind = "state", path = "/mf", body = '{"queryDynamicShadowData":1}' },
				{ kind = "info", path = "/mf", body = '{"queryStaticShadowData":1}' },
			}, seen.reqs)
		end)

		it("sends a body wire.body accepts, as the bytes wire.body builds", function()
			local seen = recording()
			local env = new_commands({ request = seen.request })
			env.commands.Dev_Request({ BODY = '{"fanOn":true,"fanSpeed":4}' })
			env.commands.Dev_Request({ BODY = '{"fanSpeed":4,"fanOn":true}' }) -- another key order
			env.commands.Dev_Request({ BODY = ' { "lightBrightness" : 30 } ' }) -- other spacing
			env.commands.Dev_Request({ BODY = '{"fanOn":false}' })
			assert.same({
				{ kind = "command", path = "/mf", body = '{"fanOn":true,"fanSpeed":4}' },
				{ kind = "command", path = "/mf", body = '{"fanOn":true,"fanSpeed":4}' },
				{ kind = "command", path = "/mf", body = '{"lightBrightness":30}' },
				{ kind = "command", path = "/mf", body = '{"fanOn":false}' },
			}, seen.reqs)
		end)

		it("refuses a body wire.body does not accept, and sends nothing", function()
			local cases = {
				['{"fanOn":true,"lightOn":true}'] = "mix",
				['{"fanSpeed":9,"fanOn":true}'] = "range",
				['{"fanOn":true}'] = "range",
				['{"lightBrightness":0}'] = "range",
				['{"reboot":true}'] = "not one the driver writes",
				['{"factoryReset":true}'] = "not one the driver writes",
				['{"schedule":"x"}'] = "not one the driver writes",
				['{"wind":true}'] = "not one the driver writes",
				['{"firmwareUrl":"x"}'] = "not one the driver writes",
				['{}'] = "holds no field",
				['[1,2]'] = "not a JSON object",
				['not json'] = "not a JSON object",
			}
			for body, why in pairs(cases) do
				local seen = recording()
				local env = new_commands({ request = seen.request })
				env.commands.Dev_Request({ BODY = body })
				assert.same({}, seen.reqs, body)
				assert.equal(1, #warned(env), body)
				assert.truthy(warned(env)[1]:find("^Dev Request refused: "), body)
				assert.truthy(warned(env)[1]:find(why, 1, true), body .. " -> " .. warned(env)[1])
			end
		end)

		it("refuses a missing, empty or over-long BODY", function()
			local seen = recording()
			local env = new_commands({ request = seen.request })
			env.commands.Dev_Request({})
			env.commands.Dev_Request(nil)
			env.commands.Dev_Request({ BODY = "" })
			env.commands.Dev_Request({ BODY = 5 })
			env.commands.Dev_Request({ BODY = '{"fanOn":false}' .. string.rep(" ", 400) })
			assert.same({}, seen.reqs)
			assert.equal(5, #warned(env))
		end)

		it("refuses when no request function is wired", function()
			local env = new_commands()
			env.commands.Dev_Request({ BODY = '{"queryDynamicShadowData":1}' })
			assert.truthy(warned(env)[1]:find("no request function", 1, true))
		end)

		it("says why a request was not sent, and contains a request function that raises", function()
			local env = new_commands({ request = function() return nil, "busy" end })
			env.commands.Dev_Request({ BODY = '{"queryDynamicShadowData":1}' })
			assert.truthy(warned(env)[1]:find("not sent (busy)", 1, true))
			local env2 = new_commands({ request = function() error("transport kaput") end })
			assert.has_no.errors(function()
				env2.commands.Dev_Request({ BODY = '{"queryDynamicShadowData":1}' })
			end)
			assert.truthy(warned(env2)[1]:find("transport kaput", 1, true))
		end)

		it("contains a wire that raises while checking the body", function()
			local seen = recording()
			local wire = fake_wire()
			wire.decode = function() error("decoder kaput") end
			local env = new_commands({ request = seen.request, wire = wire })
			assert.has_no.errors(function() env.commands.Dev_Request({ BODY = '{"fanOn":false}' }) end)
			assert.same({}, seen.reqs)
			assert.truthy(warned(env)[1]:find("decoder kaput", 1, true))
		end)

		it("looks fan.wire up when none is handed over, and says when it cannot", function()
			local saved_loaded, saved_preload = package.loaded["fan.wire"], package.preload["fan.wire"]
			local seen = recording()
			local ok, err = pcall(function()
				package.loaded["fan.wire"] = nil
				package.preload["fan.wire"] = function() return fake_wire() end
				local log = fake_log()
				local commands = devcmds.new({ log = log, request = seen.request })
				commands.Dev_Request({ BODY = '{"fanOn":false}' })
				assert.equal(1, #seen.reqs)
				package.loaded["fan.wire"] = nil
				package.preload["fan.wire"] = function() error("wire kaput") end
				commands.Dev_Request({ BODY = '{"fanOn":false}' })
				assert.equal(1, #seen.reqs)
				assert.truthy(log.texts("warn")[1]:find("fan.wire is not available", 1, true))
			end)
			package.loaded["fan.wire"], package.preload["fan.wire"] = saved_loaded, saved_preload
			assert(ok, err)
		end)

		it("logs what it sent, with the sequence number the request function gave", function()
			local seen = recording()
			local env = new_commands({ request = seen.request })
			env.commands.Dev_Request({ BODY = '{"fanSpeed":4,"fanOn":true}' })
			assert.same({ 'Dev Request: command {"fanOn":true,"fanSpeed":4} sent as #41' }, env.log.texts("always"))
		end)

		it("logs a state answer normalized, one line", function()
			local seen = recording()
			local env = new_commands({ request = seen.request })
			env.commands.Dev_Request({ BODY = '{"fanOn":true,"fanSpeed":4}' })
			seen.callbacks[1]({ seq = 41, ok = true, code = 200, ms = 310, kind = "command", json = {
				clientId = "MF_00005E005301", fanOn = true, fanSpeed = 4, fanDirection = "forward",
				lightOn = false, lightBrightness = 100, owner = "owner@example.com" } })
			local last = env.log.texts("always")[2]
			assert.equal("Dev Request #41 command: 200 in 0.31 s: fan on/4 forward, light off/100", last)
			assert.is_nil(last:find("owner", 1, true))
			assert.is_nil(last:find("00005E005301", 1, true))
		end)

		it("logs an info answer with the client id as its last four digits only", function()
			local seen = recording()
			local env = new_commands({ request = seen.request })
			env.commands.Dev_Request({ BODY = '{"queryStaticShadowData":1}' })
			seen.callbacks[1]({ seq = 42, ok = true, code = 200, ms = 250, json = {
				clientId = "MF_00005E005301", firmwareVersion = "02.00.0052", lightType = "F4IN-120V-R1-30",
				deviceName = "Example Fan", SSID = "example-ssid" } })
			local last = env.log.texts("always")[2]
			assert.equal("Dev Request #42 info: 200 in 0.25 s: firmware 02.00.0052, light kit yes, id ...5301", last)
			assert.is_nil(last:find("Example", 1, true))
		end)

		it("logs a failure with its kind and detail, and an answer that holds nothing usable", function()
			local seen = recording()
			local env = new_commands({ request = seen.request })
			env.commands.Dev_Request({ BODY = '{"queryDynamicShadowData":1}' })
			env.commands.Dev_Request({ BODY = '{"queryDynamicShadowData":1}' })
			seen.callbacks[1]({ seq = 43, ok = false, err = "timeout", detail = "Operation timed out after 5001 ms" })
			seen.callbacks[2]({ seq = 44, ok = true, code = 200, ms = 120 })
			local lines = env.log.texts("always")
			assert.equal("Dev Request #43 state failed: timeout (Operation timed out after 5001 ms)", lines[3])
			assert.equal("Dev Request #44 state: 200 in 0.12 s: no usable data", lines[4])
		end)

		it("contains an answer it cannot read, and a callback given no table", function()
			local seen = recording()
			local wire = fake_wire()
			local env = new_commands({ request = seen.request, wire = wire })
			env.commands.Dev_Request({ BODY = '{"queryDynamicShadowData":1}' })
			wire.state = function() error("state kaput") end
			assert.has_no.errors(function()
				seen.callbacks[1]({ seq = 45, ok = true, code = 200, ms = 100, json = { clientId = "MF_00005E005301" } })
				seen.callbacks[1](nil)
			end)
			local lines = env.log.texts("always")
			assert.truthy(lines[2]:find("answer not readable", 1, true))
			assert.truthy(lines[3]:find("failed", 1, true))
		end)
	end)

	describe("Dev Names Plan", function()
		it("prints what a guarded click would decide as one line, and says nothing was renamed", function()
			local job = fake_names(PLAN)
			local env = new_commands({ names = job })
			env.commands.Dev_Names_Plan({})
			assert.same({ plan_line("guarded") }, env.log.texts("always"))
			assert.same({ "guarded" }, job.modes)
			assert.equal(0, job.ran)
			assert.same({}, warned(env))
			-- it only reads: no row, no message to a proxy, no timer
			assert.same({}, env.rows)
			assert.same({}, env.injected)
			assert.equal(0, #env.clock.list)
		end)

		it("is one line: no newline, single spaces between the pairs", function()
			local env = new_commands({ names = fake_names(PLAN) })
			env.commands.Dev_Names_Plan({})
			local line = env.log.texts("always")[1]
			assert.is_nil(line:find("[\n\r\t]"))
			assert.is_nil(line:find("  ", 1, true))
		end)

		it("plans the forced click for MODE=forced, in any case and with padding", function()
			for _, value in ipairs({ "forced", "FORCED", "  Forced " }) do
				local job = fake_names(PLAN)
				local env = new_commands({ names = job })
				env.commands.Dev_Names_Plan({ MODE = value })
				assert.same({ "forced" }, job.modes, value)
				assert.same({ plan_line("forced") }, env.log.texts("always"), value)
			end
		end)

		it("takes no MODE, an empty one (devctl.py run ... MODE=) and guarded as guarded", function()
			for _, params in ipairs({ {}, { MODE = "" }, { MODE = "   " }, { MODE = "guarded" }, { MODE = " GUARDED " } }) do
				local job = fake_names(PLAN)
				local env = new_commands({ names = job })
				env.commands.Dev_Names_Plan(params)
				assert.same({ "guarded" }, job.modes, tostring(params.MODE))
				assert.same({ plan_line("guarded") }, env.log.texts("always"), tostring(params.MODE))
			end
			local job = fake_names(PLAN)
			local env = new_commands({ names = job })
			env.commands.Dev_Names_Plan(nil)
			assert.same({ "guarded" }, job.modes)
		end)

		it("refuses a MODE that is neither, and asks the job nothing", function()
			for _, bad in ipairs({ "both", "rename", "1", "forced guarded", "forced;", "force", 5, true }) do
				local job = fake_names(PLAN)
				local env = new_commands({ names = job })
				env.commands.Dev_Names_Plan({ MODE = bad })
				assert.same({}, job.modes, tostring(bad))
				assert.same({}, env.log.texts("always"), tostring(bad))
				assert.equal(1, #warned(env), tostring(bad))
				assert.truthy(warned(env)[1]:find("^Dev Names Plan refused: MODE"), tostring(bad))
			end
		end)

		it("says the names job is missing when there is none, or when it has no plan", function()
			for _, names in ipairs({ false, {}, { plan = "not a function" }, "job" }) do
				local env = new_commands({ names = names or nil })
				env.commands.Dev_Names_Plan({ MODE = "forced" })
				assert.same({ "Dev Names Plan refused: the names job is missing; nothing was done" }, warned(env))
				assert.same({}, env.log.texts("always"))
			end
		end)

		it("says the job is missing before it judges a MODE", function()
			local env = new_commands()
			env.commands.Dev_Names_Plan({ MODE = "both" })
			assert.truthy(warned(env)[1]:find("the names job is missing", 1, true))
		end)

		it("contains a job whose plan raises, and one that answers no table", function()
			local raising = fake_names(PLAN)
			raising.plan = function() error("job kaput") end
			local env = new_commands({ names = raising })
			assert.has_no.errors(function() env.commands.Dev_Names_Plan({}) end)
			assert.truthy(warned(env)[1]:find("^Dev Names Plan refused: the plan could not be made"))
			assert.truthy(warned(env)[1]:find("job kaput", 1, true))
			for _, answer in ipairs({ "plan", 5, true }) do
				local job = fake_names(PLAN)
				job.plan = function() return answer end
				local silent = new_commands({ names = job })
				silent.commands.Dev_Names_Plan({})
				assert.truthy(warned(silent)[1]:find("the names job gave no plan", 1, true), tostring(answer))
			end
			local nothing = fake_names(PLAN)
			nothing.plan = function() end
			local env2 = new_commands({ names = nothing })
			env2.commands.Dev_Names_Plan({})
			assert.truthy(warned(env2)[1]:find("the names job gave no plan", 1, true))
		end)

		it("writes a dash for what the plan did not get as far as", function()
			local env = new_commands({ names = fake_names({ outcome = "no_name", fan_type = "9999-9-99" }) })
			env.commands.Dev_Names_Plan({ MODE = "forced" })
			assert.same({ "Dev Names Plan: mode=forced would=no_name fan_type=9999-9-99 fan_id=- fan_live=- fan_to=- "
				.. "fan_ours=- light_id=- light_live=- light_to=- light_ours=-; nothing was renamed" },
				env.log.texts("always"))
		end)

		it("prints the contract's table alone too: the mode is the one asked for, the extra pairs read dashes", function()
			local job = fake_names(PLAN)
			job.plan = function()
				return { outcome = "same", fan_id = 1205, light_id = 1206, fan_live = "Aviator 5",
					light_live = "Aviator 5 Light", fan_to = "Aviator 5", light_to = "Aviator 5 Light" }
			end
			local env = new_commands({ names = job })
			env.commands.Dev_Names_Plan({})
			assert.same({ 'Dev Names Plan: mode=guarded would=same fan_type=- fan_id=1205 fan_live="Aviator 5" '
				.. 'fan_to="Aviator 5" fan_ours=- light_id=1206 light_live="Aviator 5 Light" '
				.. 'light_to="Aviator 5 Light" light_ours=-; nothing was renamed' }, env.log.texts("always"))
		end)

		it("writes the ours flags as 1 and 0, and an id that is no number as ?", function()
			local plan = {}
			for key, value in pairs(PLAN) do plan[key] = value end
			plan.fan_ours, plan.light_ours, plan.fan_id, plan.light_id = false, true, "abc", 0 / 0
			local env = new_commands({ names = fake_names(plan) })
			env.commands.Dev_Names_Plan({})
			local line = env.log.texts("always")[1]
			assert.truthy(line:find("fan_ours=0", 1, true))
			assert.truthy(line:find("light_ours=1", 1, true))
			assert.truthy(line:find("fan_id=? ", 1, true))
			assert.truthy(line:find("light_id=? ", 1, true))
		end)

		it("quotes the owner's names, cleaned of control characters and cut, and keeps the type one word", function()
			local plan = {}
			for key, value in pairs(PLAN) do plan[key] = value end
			plan.fan_live, plan.light_live = "Bad\nline\tname", string.rep("n", 80)
			plan.fan_type = "99\n9 9=x"
			local env = new_commands({ names = fake_names(plan) })
			env.commands.Dev_Names_Plan({})
			local line = env.log.texts("always")[1]
			assert.is_nil(line:find("[\n\r\t]"))
			assert.truthy(line:find('fan_live="Bad?line?name"', 1, true))
			assert.truthy(line:find('light_live="' .. string.rep("n", 60) .. '..."', 1, true))
			assert.truthy(line:find("fan_type=99?9_9_x ", 1, true))
		end)

		it("contains a plan it cannot read", function()
			local plan = {}
			for key, value in pairs(PLAN) do plan[key] = value end
			plan.fan_live = setmetatable({}, { __tostring = function() error("name kaput") end })
			local env = new_commands({ names = fake_names(plan) })
			assert.has_no.errors(function() env.commands.Dev_Names_Plan({}) end)
			assert.truthy(warned(env)[1]:find("^Dev Names Plan refused: the plan could not be read"))
			assert.same({}, env.log.texts("always"))
		end)

		it("prints a line the redactor leaves alone: ids and names, no address, no client id", function()
			local line = plan_line("guarded")
			assert.equal(line, devcmds.redact(line, {}))
			assert.equal(line, devcmds.redactor(function() return PIN end)(line))
		end)
	end)

	describe("the redactor", function()
		local function redactor(pin)
			return devcmds.redactor(function() return pin end)
		end

		it("withholds a line that holds a private key name in quotes", function()
			local redact = redactor(PIN)
			for _, key in ipairs(devcmds.PRIVATE_KEYS) do
				assert.is_nil(redact('{"' .. key .. '":"x"}'), key)
				assert.is_nil(redact('answer: {"clientId":"x","' .. key .. '":1}'), key)
			end
			assert.same({ "owner", "federatedIdentity", "deviceName", "SSID", "BSSID", "timezone", "certificateId",
				"schedule", "FrCodes" }, devcmds.PRIVATE_KEYS)
		end)

		it("withholds the quoted forms a log line can take: any case, single quotes, a JSON text inside a JSON text",
			function()
				local redact = redactor(PIN)
				assert.is_nil(redact('"OWNER":"x"'))
				assert.is_nil(redact('"SsId":"x"'))
				assert.is_nil(redact("{'owner': 'x'}"))
				assert.is_nil(redact('body={\\"federatedIdentity\\":\\"us-east-1\\"}'))
				assert.is_nil(redact('["schedule"] = {...}'))
			end)

		it("withholds the whole line, whatever else it holds", function()
			local redact = redactor(PIN)
			assert.is_nil(redact('MF_00005E005301 at 10.0.2.151 {"owner":"x"}'))
		end)

		it("keeps a line that only uses the words: prose, unquoted, or part of a longer word", function()
			local redact = redactor(PIN)
			for _, line in ipairs({
				"Fan Automations: schedule set",
				"the schedule is empty",
				"owner=none",
				'"ownership" is not a key',
				'"timezones"',
				'a "BSSIDs" list',
				"SSID of the router",
			}) do
				assert.equal(line, redact(line), line)
			end
		end)

		it("replaces the pinned client id, in any case, wherever it stands", function()
			local redact = redactor(PIN)
			assert.equal("fan <client-id> answered", redact("fan MF_00005E005301 answered"))
			assert.equal("<client-id> and <client-id>", redact("mf_00005e005301 and Mf_00005E005301"))
			assert.equal("id=<client-id>,<client-id>", redact("id=MF_00005E005301,MF_00005E005301"))
		end)

		it("replaces an id of the other shapes, pinned or not: WAC_, another fan's", function()
			local redact = redactor(PIN)
			assert.equal("<client-id>", redact("WAC_00005E005301"))
			assert.equal("<client-id>", redact("wac_00005e005301"))
			assert.equal("other <client-id>", redact("other MF_00005E005302"))
			local other_prefix = redactor({ client_id = "XY_00005E005301" })
			assert.equal("fan <client-id> answered", other_prefix("fan XY_00005E005301 answered"))
		end)

		it("replaces the MAC in both forms, either case", function()
			local redact = redactor(PIN)
			assert.equal("mac <mac>", redact("mac 00005E005301"))
			assert.equal("mac <mac>", redact("mac 00005e005301"))
			assert.equal("mac <mac>", redact("mac 00:00:5e:00:53:01"))
			assert.equal("mac <mac>", redact("mac 00:00:5E:00:53:01"))
			assert.equal("<mac> <mac>", redact("00:00:5e:00:53:02 00:00:5e:00:53:01"))
		end)

		it("takes the MAC from the pin's MAC in either form, else from the client id", function()
			assert.equal("<mac>", redactor({ client_id = "MF_00005E005301", mac = "00:00:5e:00:53:01" })("00005E005301"))
			assert.equal("<mac>", redactor({ mac = "00005E005301" })("00005e005301"))
			assert.equal("<mac>", redactor({ client_id = "MF_00005E005301" })("00005e005301"))
			assert.equal("<mac>", redactor({ client_id = "WAC_00005E005301" })("00005e005301"))
		end)

		it("replaces the client id before the MAC it contains", function()
			local redact = redactor(PIN)
			assert.equal("<client-id> <mac>", redact("MF_00005E005301 00005E005301"))
		end)

		it("replaces every IPv4 address, with or without a port", function()
			local redact = redactor(PIN)
			assert.equal("fan at <ip>", redact("fan at 10.0.2.151"))
			assert.equal("<ip>:8081", redact("192.0.2.7:8081"))
			assert.equal("<ip> -> <ip>", redact("10.0.2.151 -> 10.0.2.152"))
			assert.equal("(<ip>)", redact("(10.0.2.10)"))
			assert.equal("<ip>/mf", redact("10.0.2.151/mf"))
			assert.equal("<ip>", redact("010.000.002.151"))
		end)

		it("leaves what is not an address: octets above 255, too few parts, versions, times", function()
			local redact = redactor(PIN)
			for _, line in ipairs({ "192.0.2.256", "192.0.2.1000", "1.2.3", "02.00.0052", "Firmware 02.00.0052",
				"mcu 03.00.0000", "esp-idf 4.0.4", "14:02", "14:02:11", "since 14:02", "...5301", "...5302" }) do
				assert.equal(line, redact(line), line)
			end
		end)

		it("keeps the last four digits of an id: ...5301 is what the log may show", function()
			local redact = redactor(PIN)
			assert.equal("Another fan (...5302) answers at <ip>",
				redact("Another fan (...5302) answers at 10.0.2.151"))
			assert.equal("<- fan #42 info: Gen 3, firmware 02.00.0052, light kit yes, id ...5301",
				redact("<- fan #42 info: Gen 3, firmware 02.00.0052, light kit yes, id ...5301"))
		end)

		it("does all of it in one line", function()
			local redact = redactor(PIN)
			assert.equal("Another fan (...5302) answers at <ip>: id <client-id>, mac <mac>, ours <client-id> (<mac>)",
				redact("Another fan (...5302) answers at 10.0.2.151: id MF_00005E005302, mac 00:00:5e:00:53:02, "
					.. "ours MF_00005E005301 (00005E005301)"))
		end)

		it("leaves the driver's own lines alone, the Dev State line included", function()
			local redact = redactor(PIN)
			for _, line in ipairs({
				EXAMPLE,
				"Dev State: " .. EXAMPLE,
				'-> fan #41 command {"fanOn":true,"fanSpeed":3}',
				"<- fan #41 200 in 0.31 s: fan on/3 forward, light off/100",
				"-> fan proxy CURRENT_SPEED 3",
				"-> link 303 MATCH_LED_STATE true",
				"Fan offline: 3 failures since 14:02",
				"fan #43 failed: timeout after 5.0 s (1 in a row)",
				"The fan did not take speed 3 (reports 2)",
				"devloop: commands refused: signature mismatch",
				"Dev Press: link 308 tap x3 every 150 ms",
				"",
			}) do
				assert.equal(line, redact(line), line)
			end
		end)

		it("is idempotent: the dev loop runs a line through it when buffered and again when shipped", function()
			local redact = redactor(PIN)
			local line = "Another fan MF_00005E005302 at 10.0.2.151 mac 00:00:5e:00:53:01 or 00005E005301"
			local once = redact(line)
			assert.equal("Another fan <client-id> at <ip> mac <mac> or <mac>", once)
			assert.equal(once, redact(once))
		end)

		it("answers a string or nil, never anything else: non-strings keep nothing", function()
			local redact = redactor(PIN)
			assert.is_nil(redact(nil))
			assert.is_nil(redact(5))
			assert.is_nil(redact({}))
			assert.is_nil(redact(true))
		end)

		it("still redacts the shapes when it is given no way to ask for the pin, bare MAC digits aside", function()
			local redact = devcmds.redactor(nil)
			assert.equal("<client-id> <mac> <ip> 00005E005301", redact("MF_00005E005301 00:00:5e:00:53:01 10.0.2.151 "
				.. "00005E005301"))
		end)

		it("asks the pin on every line: a pin that appears later is covered from then on", function()
			local pin
			local redact = devcmds.redactor(function() return pin end)
			assert.equal("00005E005301", redact("00005E005301"))
			pin = PIN
			assert.equal("<mac>", redact("00005E005301"))
		end)

		it("keeps every identity it was ever told: after a re-point, after the pin is gone, when asking raises",
			function()
				local pin = PIN
				local failing = false
				local redact = devcmds.redactor(function()
					if failing then error("model stopped") end
					return pin
				end)
				assert.equal("<client-id>", redact("MF_00005E005301"))
				pin = { client_id = "MF_00005E005302", mac = "00005E005302" }
				assert.equal("<client-id> <mac>", redact("MF_00005E005302 00005E005302"))
				assert.equal("<mac>", redact("00005E005301")) -- the first fan, still covered
				pin = nil
				assert.equal("<mac> <mac>", redact("00005E005301 00005E005302"))
				failing = true
				assert.equal("<mac> <mac>", redact("00005E005301 00005E005302"))
			end)

		it("ignores a pin that is not a table or holds nothing usable", function()
			for _, pin in ipairs({ "pin", 5, true }) do
				local redact = devcmds.redactor(function() return pin end)
				assert.equal("plain line", redact("plain line"))
			end
			local redact = redactor({ client_id = "", mac = "123" })
			assert.equal("plain line 123", redact("plain line 123"))
		end)

		it("remembers at most sixteen identities: the oldest MAC digits go first, the newest stay", function()
			local pin = {}
			local redact = devcmds.redactor(function() return pin end)
			for i = 1, 20 do
				pin = { client_id = string.format("MF_00005E0053%02X", i) }
				redact("x")
			end
			assert.equal("<mac>", redact("00005E005314")) -- the twentieth
			assert.equal("<mac>", redact("00005E005305")) -- the fifth, the oldest of the sixteen
			assert.equal("00005E005301", redact("00005E005301")) -- the first has been forgotten
		end)
	end)

	-- The one real neighbour: the dev loop that runs the commands and the redactor.
	describe("with common.devloop", function()
		local function with_devloop(fn)
			local saved_module, saved_state = package.loaded["common.devloop"], rawget(_G, "__DEVLOOP")
			package.loaded["common.devloop"] = nil
			rawset(_G, "__DEVLOOP", nil)
			local ok, err = pcall(function() fn(require("common.devloop")) end)
			package.loaded["common.devloop"] = saved_module
			rawset(_G, "__DEVLOOP", saved_state)
			assert(ok, err)
		end

		it("runs each command from a signed execute, found by the name devctl.py run gives it", function()
			with_devloop(function(devloop)
				local env = new_commands()
				devloop.set_signed_commands(env.commands)
				assert.is_nil(devloop.execute("Dev Fan State", {}))
				assert.equal(EXAMPLE, env.rows["Dev State"])
				assert.is_nil(devloop.execute("Dev Press", { LINK = "303", ACTION = "push" }))
				assert.is_nil(devloop.execute("Dev Proxy", { BINDING = "5001", COMMAND = "SET_SPEED", SPEED = "2" }))
				assert.same({ "303 DO_PUSH", "5001 SET_SPEED" }, injected(env))
				assert.same({ SPEED = "2" }, env.injected[2][3])
				assert.is_nil(devloop.execute("Dev Request", { BODY = '{"queryDynamicShadowData":1}' }))
				assert.truthy(warned(env)[1]:find("^Dev Request refused: no request function"))
			end)
		end)

		it("runs Dev Names Plan from a signed execute, with its MODE", function()
			with_devloop(function(devloop)
				local job = fake_names(PLAN)
				local env = new_commands({ names = job })
				devloop.set_signed_commands(env.commands)
				assert.is_nil(devloop.execute("Dev Names Plan", { MODE = "forced" }))
				assert.is_nil(devloop.execute("Dev Names Plan", {}))
				assert.same({ "forced", "guarded" }, job.modes)
				assert.equal(0, job.ran)
				assert.same({ plan_line("forced"), plan_line("guarded") }, env.log.texts("always"))
			end)
		end)

		it("also finds them as a Composer action (LUA_ACTION) and keeps ACTION out of the parameters", function()
			with_devloop(function(devloop)
				local env = new_commands()
				devloop.set_signed_commands(env.commands)
				assert.is_nil(devloop.execute("LUA_ACTION", { ACTION = "Dev Proxy", BINDING = "5002", COMMAND = "OFF" }))
				assert.same({ { 5002, "OFF", {} } }, env.injected)
			end)
		end)

		it("is not in the dispatch table: nothing but a signed command reaches it", function()
			with_devloop(function()
				package.loaded["common.dispatch"] = nil
				local dispatch = require("common.dispatch")
				new_commands()
				for _, name in ipairs({ "Dev_Fan_State", "Dev_Names_Plan", "Dev_Press", "Dev_Proxy", "Dev_Request" }) do
					assert.is_nil(dispatch.commands[name], name)
				end
				package.loaded["common.dispatch"] = nil
			end)
		end)

		it("installs as the loop's redactor: a private line is withheld, an id and an address replaced", function()
			with_devloop(function(devloop)
				devloop.set_redactor(devcmds.redactor(function() return PIN end))
				assert.is_nil(devloop.redacted('{"owner":"x"}'))
				assert.equal("fan <client-id> at <ip>", devloop.redacted("fan MF_00005E005301 at 10.0.2.151"))
				assert.equal("-> link 303 MATCH_LED_STATE true", devloop.redacted("-> link 303 MATCH_LED_STATE true"))
				devloop.set_redactor(nil)
			end)
		end)

		it("never makes the loop withhold a line for a failure: the redactor does not raise on odd lines", function()
			with_devloop(function(devloop)
				devloop.set_redactor(devcmds.redactor(function() error("model gone") end))
				assert.equal("plain", devloop.redacted("plain"))
				assert.equal("<client-id>", devloop.redacted("MF_00005E005301"))
				devloop.set_redactor(nil)
			end)
		end)
	end)
end)
