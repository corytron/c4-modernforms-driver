-- The Modern Forms Fan driver as a whole (docs/v1-design.md): its driver.xml,
-- its startup, the dev loop's hook, and the round trips of section 9.11 on the
-- fake runtime (a press to a request to an answer to the notifications and
-- LEDs; Find Fans). The modules have their own specs; this one pins the wiring
-- in driver.lua. The checks every driver passes are in drivers_spec.lua.

local fake = require("helpers.fake_c4")
local log = require("common.log")
local mf = require("fixtures.mf_gen3")
local mdns = require("fixtures.mdns")

local DRIVER = "modernforms_fan"
local DEV_SERVER = "192.0.2.7:8081"
local FAN = "10.0.2.151"

local function quiet()
	log.sink = function() end
end

local function capture_log()
	local lines = {}
	log.sink = function(line) lines[#lines + 1] = line end
	return lines
end

local function read(path)
	local file = assert(io.open(path))
	local text = file:read("*a")
	file:close()
	return text
end

local function field(body, tag)
	return body and body:match("<" .. tag .. ">(.-)</" .. tag .. ">")
end

-- `fn()` with common.devloop answered by `loader` (a function returning the
-- module, or raising as a missing or broken one does); the real module comes
-- back afterwards. Returns what `fn` returns.
local function with_devloop(loader, fn)
	package.loaded["common.devloop"] = nil
	package.preload["common.devloop"] = loader
	local ok, result = pcall(fn)
	package.preload["common.devloop"] = nil
	package.loaded["common.devloop"] = nil
	assert(ok, result)
	return result
end

-- A stand-in dev loop recording the calls the driver makes, in order.
local function stub_devloop()
	local stub = { calls = {} }
	function stub.start(host)
		stub.calls[#stub.calls + 1] = { "start", host }
		return true
	end
	function stub.stop()
		stub.calls[#stub.calls + 1] = { "stop" }
	end
	function stub.set_signed_commands(commands)
		stub.commands = commands
	end
	function stub.set_redactor(redactor)
		stub.redactor = redactor
	end
	return stub
end

-- `fn()` with print replaced by a recorder; returns the lines printed.
local function with_print(fn)
	local printed = {}
	local real_print = _G.print
	_G.print = function(...) printed[#printed + 1] = table.concat({ ... }, " ") end
	local ok, err = pcall(fn)
	_G.print = real_print
	assert(ok, err)
	return printed
end

-- The last request the driver made, answered with `body`; the transport's gap
-- (250 ms) then the model's next move.
local function answer(c4, body)
	c4.last_transfer():respond(200, body)
	c4.advance(300)
end

local function last_sent(c4)
	local transfer = c4.last_transfer()
	return transfer and transfer.data
end

-- The messages one binding got, filtered by command: the list of one field.
local function sent(c4, binding, command, key)
	local out = {}
	for _, message in ipairs(c4.proxy_messages(binding)) do
		if message[1] == command then
			out[#out + 1] = key and message[2][key] or message[2]
		end
	end
	return out
end

-- The driver on the fake, its fan at FAN answering as the house fan does, run
-- up to the first state read answered.
local function online_driver(properties)
	properties = properties or {}
	properties["Fan Address"] = FAN
	local env, c4 = fake.load_driver(DRIVER, properties)
	env.OnDriverInit("DIT_STARTUP")
	env.OnDriverLateInit("DIT_STARTUP")
	assert.equal('{"queryStaticShadowData":1}', last_sent(c4), "the info read comes first")
	answer(c4, mf.INFO)
	assert.equal('{"queryDynamicShadowData":1}', last_sent(c4), "then the state read")
	answer(c4, mf.state({ fanOn = true, fanSpeed = 3 }))
	return env, c4
end

describe("Modern Forms Fan driver", function()
	before_each(quiet)
	after_each(function()
		log.set_debug(false)
		log.set_prefix(nil)
	end)

	describe("driver.xml", function()
		local xml = read("src/" .. DRIVER .. "/driver.xml")
		local bare = xml:gsub("<!%-%-.-%-%->", "")

		it("names the driver, asks for 3.3.0 and has no combo, icons or replaces", function()
			assert.equal("Modern Forms Fan", field(bare, "name"))
			assert.equal("Modern Forms", field(bare, "manufacturer"))
			assert.equal("3.3.0", field(bare, "minimum_os_version"))
			for _, tag in ipairs({ "combo", "small", "large", "replaces", "auto_update" }) do
				assert.is_nil(bare:find("<" .. tag, 1, true), tag)
			end
		end)

		it("declares the fan first and primary, then the light_v2 proxy", function()
			local proxies = {}
			for attrs, kind in bare:gmatch("<proxy ([^>]-)>(.-)</proxy>") do
				proxies[#proxies + 1] = { attrs = attrs, kind = kind }
			end
			assert.equal(2, #proxies)
			assert.equal("fan", proxies[1].kind)
			assert.truthy(proxies[1].attrs:find('proxybindingid="5001"', 1, true))
			assert.truthy(proxies[1].attrs:find('primary="True"', 1, true))
			assert.equal("light_v2", proxies[2].kind)
			assert.truthy(proxies[2].attrs:find('proxybindingid="5002"', 1, true))
		end)

		it("declares the two proxy bindings and the Button Links of section 2.4, none with a proxybindingid", function()
			local ids = {}
			for body in bare:gmatch("<connection>(.-)</connection>") do
				ids[#ids + 1] = field(body, "id") .. ":" .. field(body, "classname")
			end
			assert.same({ "5001:FAN", "5002:LIGHT_V2", "200:BUTTON_LINK", "201:BUTTON_LINK", "202:BUTTON_LINK",
				"300:BUTTON_LINK", "301:BUTTON_LINK", "302:BUTTON_LINK", "303:BUTTON_LINK", "304:BUTTON_LINK",
				"305:BUTTON_LINK", "306:BUTTON_LINK", "307:BUTTON_LINK", "308:BUTTON_LINK" }, ids)
			assert.is_nil(bare:find("<connection proxybindingid", 1, true), "no link carries proxybindingid (K4)")
		end)

		it("declares the capabilities of section 2.3, one flat block, and not the fan's own speed links", function()
			local caps = field(bare, "capabilities")
			assert.equal("6", field(caps, "discrete_levels"))
			assert.equal("Level 1,Level 2,Level 3,Level 4,Level 5,Level 6", field(caps, "speed_names"))
			assert.equal("3", field(caps, "preset_speed"))
			assert.equal("True", field(caps, "can_reverse"))
			assert.equal("False", field(caps, "click_rates"))
			assert.is_nil(caps:find("proxy_fan_speed_connections", 1, true))
		end)

		it("declares the properties of section 2.5 in order, the colour per speed rows (V27) among them, Dev rows in a block",
			function()
				local names = {}
				for body in bare:gmatch("<property>(.-)</property>") do names[#names + 1] = field(body, "name") end
				assert.same({ "Driver Version", "Status", "Last Action", "Fan Address", "Found Fans",
					"Follow Address Changes", "Fan ID",
					"Fan Model", "Firmware", "Last Seen", "Last Change By", "Fan Automations", "Poll Interval (s)",
					"Keypad Links", "Speed 1 Link Also Lit At", "Speed 2 Link Also Lit At", "Speed 3 Link Also Lit At",
					"Speed 4 Link Also Lit At", "Speed 5 Link Also Lit At", "Speed 6 Link Also Lit At",
					"Speed LED Colors", "Speed 1 LED Color", "Speed 2 LED Color", "Speed 3 LED Color",
					"Speed 4 LED Color", "Speed 5 LED Color", "Speed 6 LED Color", "Speed LED Off Color",
					"Migration", "Stock Device", "Debug Mode", "Dev Server", "Dev State" }, names)
				local block = xml:match("<!%-%- DEV%-ONLY BEGIN.-<!%-%- DEV%-ONLY END %-%->")
				assert.truthy(block and block:find("<name>Dev Server</name>", 1, true))
				assert.truthy(block:find("<name>Dev State</name>", 1, true))
			end)

		it("declares the seven actions with sort_order, the two events and the one condition", function()
			local actions = {}
			for body in bare:gmatch("<action>(.-)</action>") do
				actions[#actions + 1] = field(body, "sort_order") .. ":" .. field(body, "command")
			end
			assert.same({ "1:Find Fans", "2:Use Selected Fan", "3:Name Items After Fan", "4:Reboot Fan",
				"5:Turn Off Away Mode", "6:Turn Off Adaptive Learning", "7:Migration Report" }, actions)
			local events = {}
			for body in bare:gmatch("<event>(.-)</event>") do
				events[#events + 1] = field(body, "id") .. ":" .. field(body, "name")
			end
			assert.same({ "1:Fan Offline", "2:Fan Online" }, events)
			assert.equal("BOOL_ONLINE", field(field(bare, "conditionals"), "name"))
		end)
	end)

	describe("startup", function()
		it("adds the Online variable at init and touches nothing else before late init", function()
			local env, c4 = fake.load_driver(DRIVER, {})
			env.OnDriverInit("DIT_ADDING")
			assert.same({ { "Online", "0", "BOOL", true } }, c4.calls_to("AddVariable"))
			assert.same({}, c4.calls_to("UpdateProperty"))
			assert.same({}, c4.active_timers())
			assert.same({}, c4.transfers)
		end)

		it("shows its version and the Not set up Status at late init, and sends nothing without an address", function()
			local env, c4 = fake.load_driver(DRIVER, {})
			env.OnDriverInit("DIT_ADDING")
			env.OnDriverLateInit("DIT_ADDING")
			assert.equal("1", env.Properties["Driver Version"])
			assert.equal("Not set up: Find Fans, or enter the fan's address in Fan Address", env.Properties["Status"])
			assert.is_false(log.enabled("debug"))
			assert.same({}, c4.transfers)
		end)

		it("applies a Debug Mode already On at late init, and follows its changes", function()
			local env = fake.load_driver(DRIVER, { ["Debug Mode"] = "On" })
			env.OnDriverLateInit("DIT_STARTUP")
			assert.is_true(log.enabled("debug"))
			env.Properties["Debug Mode"] = "Off"
			env.OnPropertyChanged("Debug Mode")
			assert.is_false(log.enabled("debug"))
		end)

		it("logs with its own prefix", function()
			local env = fake.load_driver(DRIVER, { ["Debug Mode"] = "On" })
			env.OnDriverLateInit("DIT_STARTUP")
			local lines = capture_log()
			env.ExecuteCommand("LUA_ACTION", { ACTION = "Some Action" })
			assert.same({ "[DEBUG] Modern Forms Fan: ExecuteCommand Some_Action",
				"[DEBUG] Modern Forms Fan: no command handler for Some_Action" }, lines)
		end)

		it("shows the build's own stamp when Director answers the version lookup with nothing", function()
			package.preload["common.build_version"] = function() return "196" end
			package.loaded["common.build_version"] = nil
			local ok, err = pcall(function()
				local env, c4 = fake.load_driver(DRIVER, {})
				c4.config_info.version = ""
				env.OnDriverLateInit("DIT_ADDING")
				assert.equal("196", env.Properties["Driver Version"])
			end)
			package.preload["common.build_version"] = nil
			package.loaded["common.build_version"] = nil
			assert(ok, err)
		end)

		it("stops every timer on destroy and survives a second destroy", function()
			local env, c4 = online_driver()
			assert.truthy(#c4.active_timers() > 0, "the model polls")
			env.OnDriverDestroyed("DIT_UPDATING")
			assert.same({}, c4.active_timers())
			assert.has_no.errors(function() env.OnDriverDestroyed("DIT_UPDATING") end)
		end)

		it("ignores commands and proxy messages it has no handler for", function()
			local env, c4 = fake.load_driver(DRIVER, {})
			env.OnDriverLateInit("DIT_STARTUP")
			c4.calls = {}
			assert.has_no.errors(function()
				env.ExecuteCommand("LUA_ACTION", { ACTION = "Some Action" })
				env.ExecuteCommand("DEV_RELOAD", {})
				env.ReceivedFromProxy(5001, "NO_SUCH_COMMAND", {})
				env.ReceivedFromProxy(4242, "ON", {})
				env.OnPropertyChanged("Driver Version")
			end)
			assert.same({}, c4.calls_to("SendToProxy"))
		end)
	end)

	describe("a fan on the network (section 9.11)", function()
		it("pins the fan, shows it and tells both proxies after the first two answers", function()
			local env, c4 = online_driver()
			assert.equal("Online: fan speed 3, light off", env.Properties["Status"])
			assert.equal("MF_00005E005301 (MAC 00:00:5e:00:53:01)", env.Properties["Fan ID"])
			assert.equal("Learned fan MF_00005E005301 (Gen 3) at " .. FAN, env.Properties["Last Action"])
			assert.same({ 3 }, sent(c4, 5001, "CURRENT_SPEED", "SPEED"))
			assert.same({ true }, sent(c4, 5002, "ONLINE_CHANGED", "STATE"))
			assert.same({ { "Online", "1" } }, c4.calls_to("SetVariable"))
			assert.equal(2, c4.calls_to("FireEventByID")[1][1], "Fan Online fired")
		end)

		it("sends one request for a tap on Fan Speed 4, lights its link and tells the proxy once it is answered",
			function()
				local env, c4 = online_driver()
				env.ReceivedFromProxy(304, "DO_PUSH", {})
				assert.equal('{"fanOn":true,"fanSpeed":4}', last_sent(c4))
				local lit = sent(c4, 304, "MATCH_LED_STATE", "STATE")
				assert.equal(true, lit[#lit], "the link lights at once")
				env.ReceivedFromProxy(304, "DO_CLICK", {})
				assert.equal(1, #c4.transfers - 2, "a click after a push sends nothing more")
				answer(c4, mf.state({ fanOn = true, fanSpeed = 4 }))
				assert.same({ 3, 4 }, sent(c4, 5001, "CURRENT_SPEED", "SPEED"))
				assert.equal("Online: fan speed 4, light off", env.Properties["Status"])
			end)

		it("turns the fan off from the proxy", function()
			local env, c4 = online_driver()
			env.ReceivedFromProxy(5001, "OFF", {})
			assert.equal('{"fanOn":false}', last_sent(c4))
			answer(c4, mf.state({ fanOn = false, fanSpeed = 3 }))
			assert.equal("Online: fan off, light off", env.Properties["Status"])
		end)

		it("follows a new Fan Address and reads the fan there", function()
			local env, c4 = online_driver()
			env.Properties["Fan Address"] = "10.0.2.152"
			env.OnPropertyChanged("Fan Address")
			assert.equal("http://10.0.2.152/mf", c4.last_transfer().url)
		end)

		it("says so on a Fan Address that is no address", function()
			local env = online_driver()
			env.Properties["Fan Address"] = "fan.local"
			env.OnPropertyChanged("Fan Address")
			assert.equal('Fan Address "fan.local" is not an IPv4 address', env.Properties["Status"])
		end)

		it("answers the online condition from the state, and with a picked text", function()
			local env = online_driver()
			assert.is_true(env.TestCondition("BOOL_ONLINE", {}))
			assert.is_true(env.TestCondition("BOOL_ONLINE", { VALUE = "True" }))
			assert.is_false(env.TestCondition("BOOL_ONLINE", { VALUE = "False" }))
			assert.is_true(env.TestCondition("BOOL_ONLINE", { VALUE = "False", LOGIC = "NOT_EQUAL" }))
			assert.is_false(env.TestCondition("SOMETHING_ELSE", {}))
		end)

		describe("a colour per speed (V27, #31)", function()
			local PER_SPEED = {
				["Speed LED Colors"] = "Per speed",
				["Speed 1 LED Color"] = "0,0,255",
				["Speed 2 LED Color"] = "128,0,255",
				["Speed 6 LED Color"] = "255,96,0",
				["Speed LED Off Color"] = "16,16,16",
			}

			-- Fan Speed 6 pressed and answered: the fan runs at 6.
			local function run_at_six(env, c4)
				env.ReceivedFromProxy(306, "DO_PUSH", {})
				answer(c4, mf.state({ fanOn = true, fanSpeed = 6 }))
			end

			it("sends the colour of the speed a link is lit at, just before its LED state", function()
				local env, c4 = online_driver(PER_SPEED)
				run_at_six(env, c4)
				local messages = c4.proxy_messages(306)
				local colours, at = {}, nil
				for index, message in ipairs(messages) do
					if message[1] == "BUTTON_COLORS" then
						colours[#colours + 1] = message[2]
						at = index
					end
				end
				assert.equal(1, #colours)
				assert.equal("ff6000", colours[1].ON_COLOR)
				assert.equal("101010", colours[1].OFF_COLOR)
				assert.equal("MATCH_LED_STATE", messages[at + 1][1])
				assert.is_true(messages[at + 1][2].STATE)
			end)

			it("answers a keypad's request with the colour of the speed in force", function()
				local env, c4 = online_driver(PER_SPEED)
				env.Properties["Speed 3 Link Also Lit At"] = "Speed 6"
				env.OnPropertyChanged("Speed 3 Link Also Lit At")
				run_at_six(env, c4)
				c4.calls = {}
				env.ReceivedFromProxy(303, "REQUEST_BUTTON_COLORS", {})
				assert.same({ "ff6000" }, sent(c4, 303, "BUTTON_COLORS", "ON_COLOR"))
			end)

			it("sends again at once when a colour changes while its link is lit", function()
				local env, c4 = online_driver(PER_SPEED)
				run_at_six(env, c4)
				env.Properties["Speed 6 LED Color"] = "0,255,0"
				env.OnPropertyChanged("Speed 6 LED Color")
				local colours = sent(c4, 306, "BUTTON_COLORS", "ON_COLOR")
				assert.equal("00ff00", colours[#colours])
			end)

			it("sends no colours with Keypad's own, the default, and none for a link that is dark", function()
				local env, c4 = online_driver()
				run_at_six(env, c4)
				assert.same({}, sent(c4, 306, "BUTTON_COLORS"))
				env.Properties["Speed LED Colors"] = "Per speed"
				env.OnPropertyChanged("Speed LED Colors")
				assert.equal(1, #sent(c4, 306, "BUTTON_COLORS"), "the lit link takes its colour at once")
				assert.same({}, sent(c4, 301, "BUTTON_COLORS"), "a dark link gets none")
				assert.same({}, sent(c4, 300, "BUTTON_COLORS"), "nor does Fan Off")
			end)

			it("ignores a colour it cannot read and keeps the others", function()
				local lines = capture_log()
				local env, c4 = online_driver(PER_SPEED)
				env.Properties["Speed 6 LED Color"] = "red"
				env.OnPropertyChanged("Speed 6 LED Color")
				run_at_six(env, c4)
				assert.same({}, sent(c4, 306, "BUTTON_COLORS"))
				local found = false
				for _, line in ipairs(lines) do
					found = found or line:find("Speed 6 LED Color red", 1, true) ~= nil
				end
				assert.is_true(found, "the warning names the colour row")
			end)
		end)

		it("snaps a pick in Keypad Links back to its first row", function()
			local env, c4 = online_driver()
			fake.link_keypad(env, 303, 456, 12)
			c4.calls = {}
			env.Properties["Keypad Links"] = "something else"
			env.OnPropertyChanged("Keypad Links")
			local updated = c4.calls_to("UpdateProperty")
			assert.equal("Keypad Links", updated[#updated][1])
		end)
	end)

	describe("Find Fans", function()
		it("sends the query on the mDNS group, collects the answers and fills Found Fans", function()
			local env, c4 = fake.load_driver(DRIVER, {})
			env.OnDriverInit("DIT_STARTUP")
			env.OnDriverLateInit("DIT_STARTUP")
			env.ExecuteCommand("LUA_ACTION", { ACTION = "Find Fans" })
			local created = c4.calls_to("CreateNetworkConnection")[1]
			assert.same({ 6001, "224.0.0.251" }, { created[1], created[2] })
			local connected = c4.calls_to("NetConnect")[1]
			assert.same({ 6001, 5353, "MULTICAST" }, { connected[1], connected[2], connected[3] })
			assert.equal(1, #c4.calls_to("SendToNetwork"))
			fake.network_receive(env, 6001, 5353, mdns.K10_FIRST, FAN)
			c4.advance(3100)
			assert.truthy(env.Properties["Last Action"]:find("^Found 1 fan"), env.Properties["Last Action"])
			local lists = c4.calls_to("UpdatePropertyList")
			local last = lists[#lists]
			assert.equal("Found Fans", last[1])
			assert.truthy(last[2]:find("MF_Fan_005301 at " .. FAN, 1, true), last[2])
			assert.equal(1, #c4.calls_to("NetDisconnect"))
		end)

		it("says so when no fan answers", function()
			local env, c4 = fake.load_driver(DRIVER, {})
			env.OnDriverLateInit("DIT_STARTUP")
			env.ExecuteCommand("LUA_ACTION", { ACTION = "Find Fans" })
			c4.advance(3100)
			assert.equal("No Modern Forms fan answered on this network", env.Properties["Last Action"])
		end)

		it("ignores a datagram outside a Find Fans window", function()
			local env = fake.load_driver(DRIVER, {})
			env.OnDriverLateInit("DIT_STARTUP")
			assert.has_no.errors(function() fake.network_receive(env, 6001, 5353, mdns.K10_FIRST, FAN) end)
		end)
	end)

	describe("actions", function()
		it("Use Selected Fan with nothing to use says what to do", function()
			local env = fake.load_driver(DRIVER, {})
			env.OnDriverLateInit("DIT_STARTUP")
			env.ExecuteCommand("LUA_ACTION", { ACTION = "Use Selected Fan" })
			assert.equal("Nothing to use: pick a fan in Found Fans, or enter Fan Address", env.Properties["Last Action"])
		end)

		it("Reboot Fan with no fan refuses", function()
			local env = fake.load_driver(DRIVER, {})
			env.OnDriverLateInit("DIT_STARTUP")
			env.ExecuteCommand("LUA_ACTION", { ACTION = "Reboot Fan" })
			assert.truthy(env.Properties["Last Action"]:find("^Reboot not sent"), env.Properties["Last Action"])
		end)

		it("Migration Report runs without a project to read and reports instead of raising", function()
			local env = fake.load_driver(DRIVER, {})
			env.OnDriverLateInit("DIT_STARTUP")
			assert.has_no.errors(function() env.ExecuteCommand("LUA_ACTION", { ACTION = "Migration Report" }) end)
			assert.truthy(env.Properties["Last Action"] ~= "", "the verdict is Last Action")
		end)

		it("Migration Report shows this fan's own speed, and 0 when it is off (#35)", function()
			local function row4(c4)
				local lists = c4.calls_to("UpdatePropertyList")
				for index = #lists, 1, -1 do
					if lists[index][1] == "Migration" then
						return lists[index][2]:match("Speed held by the stock fan: [^;]+; by this fan: [^,]+")
					end
				end
			end
			local env, c4 = online_driver()
			-- One stock device in the room, its fan proxy holding speed 2 as the
			-- house's did (M1: CURRENT_SPEED); no programming.
			c4.GetDevices = function()
				return { [559] = { deviceName = "Fan", roomId = 7, roomName = "Example Room",
					driverFileName = "wac_mf_fan_and_light_controller(v4).c4z",
					proxies = { [560] = { driverFileName = "fan.c4i", deviceName = "Fan" } } } }
			end
			c4.GetDeviceVariables = function(_, id)
				if id == 560 then
					return { ["1001"] = { name = "CURRENT_SPEED", value = "2" } }
				end
				return {}
			end
			c4.GetAllCodeItems = function() return {} end
			env.ExecuteCommand("LUA_ACTION", { ACTION = "Migration Report" })
			assert.equal("Speed held by the stock fan: 2; by this fan: 3", row4(c4))
			env.ReceivedFromProxy(5001, "OFF", {})
			answer(c4, mf.state({ fanOn = false, fanSpeed = 3 }))
			env.ExecuteCommand("LUA_ACTION", { ACTION = "Migration Report" })
			assert.equal("by this fan: 0", row4(c4):match("by this fan: .*"))
		end)
	end)

	describe("naming the items after the fan (fan-name-design, #37)", function()
		-- The two proxy items as the fake project holds them, given the names
		-- Composer gives a new device (the proxies' name attributes).
		local function items(env, fan_name, light_name)
			local c4 = env.C4
			local function one(binding)
				return (next(c4:GetBoundConsumerDevices(c4:GetDeviceID(), binding) or {}))
			end
			local fan_id, light_id = one(5001), one(5002)
			fake.project.devices[fan_id].name = fan_name or "Modern Forms Fan"
			fake.project.devices[light_id].name = light_name or "Modern Forms Fan Light"
			return fan_id, light_id
		end

		local function name_of(id)
			return fake.project.devices[id].name
		end

		-- Use Selected Fan on Fan Address: the same fan answers its info read.
		local function use_selected(env, c4)
			env.ExecuteCommand("LUA_ACTION", { ACTION = "Use Selected Fan" })
			for _ = 1, 3 do
				local data = last_sent(c4)
				if data == '{"queryStaticShadowData":1}' then
					answer(c4, mf.INFO)
				elseif data == '{"queryDynamicShadowData":1}' then
					answer(c4, mf.state({ fanOn = true, fanSpeed = 3 }))
				end
			end
			c4.advance(2500)
		end

		it("shows the product name in Fan Model", function()
			local env = online_driver()
			assert.equal("Gen 3, Aviator 5 (1811-5-54), light kit F4IN-120V-R1-30, Breeze", env.Properties["Fan Model"])
		end)

		it("Use Selected Fan names both items of a fresh device after the fan", function()
			local env, c4 = online_driver()
			local fan_id, light_id = items(env)
			use_selected(env, c4)
			assert.equal("Aviator 5", name_of(fan_id))
			assert.equal("Aviator 5 Light", name_of(light_id))
			assert.truthy(env.Properties["Last Action"]:find("; items renamed$"), env.Properties["Last Action"])
		end)

		it("Use Selected Fan keeps names someone typed, and Name Items After Fan takes them back", function()
			local env, c4 = online_driver()
			local fan_id, light_id = items(env, "Fan", "Fan Light")
			use_selected(env, c4)
			assert.equal("Fan", name_of(fan_id))
			assert.equal("Fan Light", name_of(light_id))
			assert.truthy(env.Properties["Last Action"]:find("; names kept$"), env.Properties["Last Action"])
			env.ExecuteCommand("LUA_ACTION", { ACTION = "Name Items After Fan" })
			c4.advance(2500)
			assert.equal("Aviator 5", name_of(fan_id))
			assert.equal("Aviator 5 Light", name_of(light_id))
			assert.truthy(env.Properties["Last Action"]:find("Aviator 5", 1, true), env.Properties["Last Action"])
		end)

		it("renames nothing at start-up or on a poll", function()
			local _, c4 = online_driver()
			c4.advance(60000)
			assert.same({}, c4.calls_to("RenameDevice"))
		end)

		it("Name Items After Fan with no fan set up refuses with L28", function()
			local env, c4 = fake.load_driver(DRIVER, {})
			env.OnDriverInit("DIT_STARTUP")
			env.OnDriverLateInit("DIT_STARTUP")
			env.ExecuteCommand("LUA_ACTION", { ACTION = "Name Items After Fan" })
			c4.advance(10)
			assert.same({}, c4.calls_to("RenameDevice"))
			assert.equal("Nothing to name the items after: no fan is set up yet", env.Properties["Last Action"])
		end)

		it("a later Last Action line is not overwritten by the rename suffix", function()
			local env, c4 = online_driver()
			local fan_id, light_id = items(env)
			env.ExecuteCommand("LUA_ACTION", { ACTION = "Use Selected Fan" })
			for _ = 1, 3 do
				local data = last_sent(c4)
				if data == '{"queryStaticShadowData":1}' then
					answer(c4, mf.INFO)
				elseif data == '{"queryDynamicShadowData":1}' then
					answer(c4, mf.state({ fanOn = true, fanSpeed = 3 }))
				end
			end
			-- A second click while the guarded naming is pending is answered busy.
			env.ExecuteCommand("LUA_ACTION", { ACTION = "Name Items After Fan" })
			c4.advance(2500)
			assert.equal("Aviator 5", name_of(fan_id))
			assert.equal("Aviator 5 Light", name_of(light_id))
			assert.equal("Naming in progress; try again in a moment", env.Properties["Last Action"])
		end)

		it("renames nothing when Use Selected Fan does not reach the fan", function()
			local env, c4 = online_driver()
			items(env)
			env.ExecuteCommand("LUA_ACTION", { ACTION = "Use Selected Fan" })
			c4.advance(30000)
			assert.same({}, c4.calls_to("RenameDevice"))
			assert.falsy(env.Properties["Last Action"]:find("renamed", 1, true), env.Properties["Last Action"])
		end)

		it("renames nothing when the driver is destroyed while a naming is pending", function()
			local env, c4 = online_driver()
			items(env)
			env.ExecuteCommand("LUA_ACTION", { ACTION = "Name Items After Fan" })
			env.OnDriverDestroyed()
			c4.advance(2500)
			assert.same({}, c4.calls_to("RenameDevice"))
		end)

		it("renames nothing when the bound items are not this device's own proxies (L26)", function()
			local env, c4 = online_driver()
			items(env)
			c4.GetDevices = function() return {} end
			env.ExecuteCommand("LUA_ACTION", { ACTION = "Name Items After Fan" })
			c4.advance(2500)
			assert.same({}, c4.calls_to("RenameDevice"))
			assert.equal("Items not renamed: this device's items were not found", env.Properties["Last Action"])
		end)

		it("Name Items After Fan on names already right records them, so Use Selected Fan may rename later", function()
			local env, c4 = online_driver()
			local fan_id, light_id = items(env, "Aviator 5", "Aviator 5 Light")
			env.ExecuteCommand("LUA_ACTION", { ACTION = "Name Items After Fan" })
			c4.advance(2500)
			assert.equal("Items already named Aviator 5 and Aviator 5 Light", env.Properties["Last Action"])
			assert.same({}, c4.calls_to("RenameDevice"))
			-- The record makes these names the driver's: the guard now treats them as ours.
			fake.project.devices[fan_id].name = "Aviator 5"
			fake.project.devices[light_id].name = "Aviator 5 Light"
			use_selected(env, c4)
			assert.same({}, c4.calls_to("RenameDevice"))
			assert.equal("Aviator 5", name_of(fan_id))
		end)
	end)

	describe("following the pinned fan to a new address (address-follow-design, #39)", function()
		local MOVED = "10.0.2.152"

		-- Runs the fake clock 100 ms at a time for `ms`: every open request to FAN
		-- fails (the fan has gone), a request to MOVED gets the fan's answers, and
		-- each Find Fans query is answered by the fan from MOVED (announce false: none).
		local function run(env, c4, ms, announce)
			local queries = #c4.calls_to("SendToNetwork")
			for _ = 1, ms / 100 do
				for _, t in ipairs(c4.open_transfers()) do
					if t.url:find("//" .. FAN .. "/", 1, true) then
						t:fail(-1, "timeout")
					elseif t.url:find("//" .. MOVED .. "/", 1, true) then
						if t.data == '{"queryStaticShadowData":1}' then
							t:respond(200, mf.INFO)
						else
							t:respond(200, mf.state({ fanOn = true, fanSpeed = 3 }))
						end
					end
				end
				local now = #c4.calls_to("SendToNetwork")
				if now > queries then
					queries = now
					if announce ~= false then
						fake.network_receive(env, 6001, 5353, mdns.K10_MOVED, MOVED)
					end
				end
				c4.advance(100)
			end
		end

		it("declares Follow Address Changes, On by default, after Found Fans", function()
			local env = online_driver()
			assert.equal("On", env.Properties["Follow Address Changes"])
		end)

		it("follows the fan when it stops answering and announces itself at another address", function()
			local env, c4 = online_driver()
			run(env, c4, 120000)
			assert.equal(MOVED, env.Properties["Fan Address"])
			assert.equal("Followed fan MF_00005E005301 to " .. MOVED .. " (was " .. FAN .. ")",
				env.Properties["Last Action"])
		end)

		it("does not look while the fan answers", function()
			local env, c4 = online_driver()
			local before = #c4.calls_to("SendToNetwork")
			c4.advance(120000)
			assert.equal(before, #c4.calls_to("SendToNetwork"))
			assert.equal(FAN, env.Properties["Fan Address"])
		end)

		it("stays at the typed address with Follow Address Changes Off", function()
			local env, c4 = online_driver({ ["Follow Address Changes"] = "Off" })
			run(env, c4, 120000)
			assert.equal(FAN, env.Properties["Fan Address"])
			assert.equal(0, #c4.calls_to("SendToNetwork"))
		end)

		it("does not follow a fan whose answer at the new address is another fan", function()
			local env, c4 = online_driver()
			local other = mf.INFO:gsub("00005E005301", "00005E005302")
			local queries = 0
			for _ = 1, 1200 do
				for _, t in ipairs(c4.open_transfers()) do
					if t.url:find("//" .. FAN .. "/", 1, true) then
						t:fail(-1, "timeout")
					elseif t.url:find("//" .. MOVED .. "/", 1, true) then
						t:respond(200, other)
					end
				end
				local now = #c4.calls_to("SendToNetwork")
				if now > queries then
					queries = now
					fake.network_receive(env, 6001, 5353, mdns.K10_MOVED, MOVED)
				end
				c4.advance(100)
			end
			assert.equal(FAN, env.Properties["Fan Address"])
		end)

		it("stops with the driver", function()
			local env, c4 = online_driver()
			env.OnDriverDestroyed()
			local before = #c4.calls_to("SendToNetwork")
			c4.advance(300000)
			assert.equal(before, #c4.calls_to("SendToNetwork"))
		end)
	end)

	describe("dev loop hook", function()
		it("starts the loop last in late init when Dev Server holds a host:port, trimmed", function()
			local stub = stub_devloop()
			with_devloop(function() return stub end, function()
				local env = fake.load_driver(DRIVER, { ["Dev Server"] = " " .. DEV_SERVER .. " " })
				local version_at_start
				stub.start = function(host)
					version_at_start = env.Properties["Driver Version"]
					stub.calls[#stub.calls + 1] = { "start", host }
				end
				env.OnDriverInit("DIT_STARTUP")
				assert.same({}, stub.calls)
				env.OnDriverLateInit("DIT_STARTUP")
				assert.same({ { "start", DEV_SERVER } }, stub.calls, "the replay of the row waits for late init")
				assert.equal("1", version_at_start, "the rest of late init ran first")
				assert.is_table(stub.commands, "the signed development commands are registered")
				assert.is_function(stub.redactor)
			end)
		end)

		it("follows Dev Server changes after late init: a new host starts it there, empty stops it", function()
			local stub = stub_devloop()
			with_devloop(function() return stub end, function()
				local env = fake.load_driver(DRIVER, { ["Dev Server"] = DEV_SERVER })
				env.OnDriverLateInit("DIT_STARTUP")
				local lines = capture_log()
				env.Properties["Dev Server"] = "192.0.2.7:8082"
				env.OnPropertyChanged("Dev Server")
				env.Properties["Dev Server"] = "  "
				env.OnPropertyChanged("Dev Server")
				assert.same({ { "start", DEV_SERVER }, { "start", "192.0.2.7:8082" }, { "stop" } }, stub.calls)
				assert.same({ "Modern Forms Fan: dev loop: starting against 192.0.2.7:8082" }, lines)
			end)
		end)

		it("with an empty Dev Server only passes the replay's stop on, and starts nothing", function()
			local stub = stub_devloop()
			with_devloop(function() return stub end, function()
				local env = fake.load_driver(DRIVER, {})
				env.OnDriverLateInit("DIT_STARTUP")
				assert.same({ { "stop" } }, stub.calls)
			end)
		end)

		it("a release build (no common.devloop) has no Dev Server handler and prints nothing", function()
			local printed = with_print(function()
				with_devloop(function() error("module 'common.devloop' not found: release build") end, function()
					local env, c4 = fake.load_driver(DRIVER, { ["Dev Server"] = DEV_SERVER })
					assert.is_nil(require("common.dispatch").properties["Dev_Server"])
					env.OnDriverLateInit("DIT_STARTUP")
					env.Properties["Dev Server"] = ""
					env.OnPropertyChanged("Dev Server")
					assert.equal("1", env.Properties["Driver Version"])
					assert.same({}, c4.transfers, "no loop, no request")
				end)
			end)
			assert.same({}, printed)
		end)

		it("takes the controller's wording for a missing module as a release build too", function()
			local printed = with_print(function()
				with_devloop(function() error("An unknown error occurred") end, function()
					fake.load_driver(DRIVER, {})
					assert.is_nil(require("common.dispatch").properties["Dev_Server"])
				end)
			end)
			assert.same({}, printed)
		end)

		it("says so through print when the dev loop fails to load for another reason", function()
			local printed = with_print(function()
				with_devloop(function() error("boom") end, function()
					fake.load_driver(DRIVER, {})
					assert.is_nil(require("common.dispatch").properties["Dev_Server"])
				end)
			end)
			assert.equal(1, #printed)
			assert.truthy(printed[1]:find("^%[ERROR%] Modern Forms Fan: common.devloop failed to load: .*boom"),
				printed[1])
		end)

		it("comes through the dev loop's reload: the loop is asked for the same host again, nothing doubles", function()
			local stub = stub_devloop()
			with_devloop(function() return stub end, function()
				local env, c4 = fake.load_driver(DRIVER, { ["Dev Server"] = DEV_SERVER })
				env.OnDriverLateInit("DIT_STARTUP")
				-- The reload (common/devloop.lua): OnDriverDestroyed, the driver's
				-- modules cleared but the loop's own, driver.lua again, both inits.
				env.OnDriverDestroyed("DIT_UPDATING")
				assert.same({}, c4.active_timers(), "everything the driver armed is cancelled")
				for name in pairs(package.loaded) do
					if (name:match("^common%.") or name:match("^fan%.")) and name ~= "common.log"
						and name ~= "common.devloop" then
						package.loaded[name] = nil
					end
				end
				local chunk = assert(loadfile("src/" .. DRIVER .. "/driver.lua"))
				setfenv(chunk, env)
				chunk()
				env.OnDriverInit("DIT_UPDATING")
				env.OnDriverLateInit("DIT_UPDATING")
				assert.same({ { "start", DEV_SERVER }, { "start", DEV_SERVER } }, stub.calls,
					"once per late init; start is the loop's to make idempotent for one host")
				env.Properties["Dev Server"] = ""
				env.OnPropertyChanged("Dev Server")
				assert.same({ "stop" }, stub.calls[3], "the new code's handler answers")
			end)
		end)

		it("drives the real common/devloop.lua: Dev Server starts it, clearing the row stops it", function()
			local env, c4 = fake.load_driver(DRIVER, { ["Dev Server"] = DEV_SERVER })
			local devloop = require("common.devloop") -- the instance the driver loaded
			local real_print = _G.print
			_G.print = function() end -- the loop's own messages bypass log.sink
			local ok, err = pcall(function()
				env.OnDriverLateInit("DIT_STARTUP")
				assert.is_true(devloop.running())
				local to_server = 0
				for _, t in ipairs(c4.transfers) do
					if t.url:find("http://" .. DEV_SERVER .. "/", 1, true) == 1 then to_server = to_server + 1 end
				end
				assert.truthy(to_server >= 1, "the loop talks to the dev server")

				env.Properties["Dev Server"] = ""
				env.OnPropertyChanged("Dev Server")
				assert.is_false(devloop.running())
			end)
			devloop.stop()
			_G.print = real_print
			assert(ok, err)
		end)
	end)
end)
