-- The Modern Forms Fan driver as a whole (docs/v1-design.md): its driver.xml,
-- its startup, the dev loop's hook, and the round trips of section 9.11 on the
-- fake runtime (a press to a request to an answer to the notifications and
-- LEDs; the fan search and Found Fans). The modules have their own specs; this one pins the wiring
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
			local value = message[2]
			if key then value = value[key] end
			out[#out + 1] = value
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

		it("names the driver, asks for 3.3.0 and has no combo or replaces", function()
			assert.equal("Modern Forms Fan", field(bare, "name"))
			assert.equal("Modern Forms", field(bare, "manufacturer"))
			assert.equal("3.3.0", field(bare, "minimum_os_version"))
			for _, tag in ipairs({ "combo", "replaces", "auto_update" }) do
				assert.is_nil(bare:find("<" .. tag, 1, true), tag)
			end
		end)

		it("declares the driver's own icons on the device and on each proxy, every file in the package (#78)", function()
			assert.truthy(bare:find('<small image_source="c4z">images/devices_sm/modernforms_fan_16.png</small>', 1, true))
			assert.truthy(bare:find('<large image_source="c4z">images/devices_lg/modernforms_fan_32.png</large>', 1, true))
			local want = {
				fan = { "images/devices_sm/modernforms_fan_16.png", "images/devices_lg/modernforms_fan_32.png" },
				light_v2 = { "images/devices_sm/modernforms_light_16.png", "images/devices_lg/modernforms_light_32.png" },
			}
			for attrs, kind in bare:gmatch("<proxy ([^>]-)>(.-)</proxy>") do
				assert.truthy(attrs:find('image_source="c4z"', 1, true), kind)
				assert.truthy(attrs:find('small_image="' .. want[kind][1] .. '"', 1, true), kind)
				assert.truthy(attrs:find('large_image="' .. want[kind][2] .. '"', 1, true), kind)
			end
			for path in bare:gmatch('(images/[%w_/]+%.png)') do
				local f = io.open("src/" .. DRIVER .. "/www/" .. path, "rb")
				assert.truthy(f, path .. " is in the package")
				if f then f:close() end
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

		it("declares the two proxy bindings, the Button Links of section 2.4 with 311 (#111) and the Breeze switch's 400",
			function()
			local ids = {}
			for body in bare:gmatch("<connection>(.-)</connection>") do
				ids[#ids + 1] = field(body, "id") .. ":" .. field(body, "classname")
			end
			assert.same({ "5001:FAN", "5002:LIGHT_V2", "200:BUTTON_LINK", "201:BUTTON_LINK", "202:BUTTON_LINK",
				"300:BUTTON_LINK", "301:BUTTON_LINK", "302:BUTTON_LINK", "303:BUTTON_LINK", "304:BUTTON_LINK",
				"305:BUTTON_LINK", "306:BUTTON_LINK", "307:BUTTON_LINK", "308:BUTTON_LINK", "311:BUTTON_LINK",
				"400:MODERNFORMS_BREEZE" }, ids)
			assert.is_nil(bare:find("<connection proxybindingid", 1, true), "no link carries proxybindingid (K4)")
			for body in bare:gmatch("<connection>(.-)</connection>") do
				if field(body, "id") == "400" then
					assert.equal("Breeze Switch", field(body, "connectionname"))
					assert.equal("1", field(body, "type"))
					assert.equal("False", field(body, "consumer"))
				end
			end
		end)

		it("declares the capabilities of section 2.3, one flat block, and not the fan's own speed links", function()
			local caps = field(bare, "capabilities")
			assert.equal("6", field(caps, "discrete_levels"))
			assert.equal("Level 1,Level 2,Level 3,Level 4,Level 5,Level 6", field(caps, "speed_names"))
			assert.equal("3", field(caps, "preset_speed"))
			assert.equal("True", field(caps, "can_reverse"))
			-- #141 LF-D3: taps fade over Click Rates, a static capability (one controller reboot).
			assert.equal("True", field(caps, "click_rates"))
			assert.equal("0", field(caps, "click_rate_min"))
			assert.equal("86400000", field(caps, "click_rate_max"))
			assert.is_nil(caps:find("proxy_fan_speed_connections", 1, true))
		end)

		it("declares the properties of section 2.5 in order, the colour per speed rows (V27) and the Breeze LED rows"
			.. " (breeze-leds-design 2) and the speed chase rows (speed-leds-design 2) among them, Dev rows in a block",
			function()
				local names = {}
				for body in bare:gmatch("<property>(.-)</property>") do names[#names + 1] = field(body, "name") end
				assert.same({ "Driver Version", "Status", "Last Action", "Fan Address", "Found Fans",
					"Follow Address Changes", "Fan ID",
					"Fan Model", "Firmware", "Last Seen", "Last Change By", "Fan Automations", "Poll Interval (s)", "Light Min On (%)",
					"Keypad Links", "Speed 1 Link Also Lit At", "Speed 2 Link Also Lit At", "Speed 3 Link Also Lit At",
					"Speed 4 Link Also Lit At", "Speed 5 Link Also Lit At", "Speed 6 Link Also Lit At",
					"Speed LED Colors", "Speed 1 LED Color", "Speed 2 LED Color", "Speed 3 LED Color",
					"Speed 4 LED Color", "Speed 5 LED Color", "Speed 6 LED Color", "Speed LED Off Color",
					"Breeze LED Animation", "Breeze LED Bottom", "Breeze LED Step (ms)", "Breeze LED Night Brightness (%)",
					"Speed LED Animation", "Speed LED Rest (s)", "Debug Mode", "Dev Server", "Dev State" }, names)
				local block = xml:match("<!%-%- DEV%-ONLY BEGIN.-<!%-%- DEV%-ONLY END %-%->")
				assert.truthy(block and block:find("<name>Dev Server</name>", 1, true))
				assert.truthy(block:find("<name>Dev State</name>", 1, true))
			end)

		it("declares the six actions with sort_order (Find Fans went with #102), the four events and the two conditions",
			function()
			local actions = {}
			for body in bare:gmatch("<action>(.-)</action>") do
				actions[#actions + 1] = field(body, "sort_order") .. ":" .. field(body, "command")
			end
			assert.same({ "2:Use Selected Fan", "3:Name Items After Fan", "4:Reboot Fan",
				"5:Turn Off Away Mode", "6:Turn Off Adaptive Learning", "7:Add Breeze Fan" }, actions)
			local events = {}
			for body in bare:gmatch("<event>(.-)</event>") do
				events[#events + 1] = field(body, "id") .. ":" .. field(body, "name")
			end
			assert.same({ "1:Fan Offline", "2:Fan Online", "4:Breeze Started", "5:Breeze Stopped" }, events)
			local conditions = {}
			for body in bare:gmatch("<conditional>(.-)</conditional>") do
				conditions[#conditions + 1] = field(body, "id") .. ":" .. field(body, "name")
			end
			assert.same({ "0:BOOL_ONLINE", "1:BOOL_BREEZE" }, conditions)
		end)

		it("declares the four Breeze commands for programming, STRENGTH a list of 1, 2 and 3 (#111, BZ3)", function()
			local commands = field(bare, "commands")
			assert.truthy(commands, "a <commands> block")
			local names = {}
			for body in commands:gmatch("<command>(.-)</command>") do
				names[#names + 1] = field(body, "sort_order") .. ":" .. field(body, "name")
			end
			assert.same({ "0:Breeze On", "1:Breeze Off", "2:Toggle Breeze", "3:Set Breeze Strength" }, names)
			local param = field(commands, "param")
			assert.equal("STRENGTH", field(param, "name"))
			assert.equal("LIST", field(param, "type"))
			local items = {}
			for item in param:gmatch("<item>(.-)</item>") do items[#items + 1] = item end
			assert.same({ "1", "2", "3" }, items)
			assert.truthy(field(bare, "config"):find("<commands>", 1, true), "inside <config>, after the actions")
		end)
	end)

	describe("startup", function()
		it("adds the Online and Breeze variables at init and touches nothing else before late init", function()
			local env, c4 = fake.load_driver(DRIVER, {})
			env.OnDriverInit("DIT_ADDING")
			assert.same({ { "Online", "0", "BOOL", true }, { "Breeze", "0", "BOOL", true } },
				c4.calls_to("AddVariable"))
			assert.same({}, c4.calls_to("UpdateProperty"))
			assert.same({}, c4.active_timers())
			assert.same({}, c4.transfers)
		end)

		it("shows its version and the Not set up Status at late init, and sends nothing without an address", function()
			local env, c4 = fake.load_driver(DRIVER, {})
			env.OnDriverInit("DIT_ADDING")
			env.OnDriverLateInit("DIT_ADDING")
			assert.equal("1", env.Properties["Driver Version"])
			assert.equal("Not set up: pick a fan in Found Fans, or enter Fan Address", env.Properties["Status"])
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

		it("trims a Fan Address with long runs of blanks in linear time (#49)", function()
			local env, c4 = online_driver()
			local started = os.clock()
			env.Properties["Fan Address"] = (" "):rep(100000) .. "10.0.2.152" .. (" "):rep(100000)
			env.OnPropertyChanged("Fan Address")
			assert.equal("http://10.0.2.152/mf", c4.last_transfer().url)
			assert.is_true(os.clock() - started < 1, "a trim that is not linear takes minutes on this")
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

	describe("Found Fans fills by itself (auto-discovery-design, #102)", function()
		-- The fake's device id is 15: slot 7, so the window at load opens 27.5 to
		-- 28 s after late init (3 s + 7 x 3.5 s + 0 to 0.5 s).
		local LOAD_MS = 3000 + 7 * 3500 + 600
		local SECOND = "10.0.2.152"

		local function set(env, name, value)
			env.Properties[name] = value
			env.OnPropertyChanged(name)
		end

		-- The last Found Fans list written: its rows (comma-joined) and its value.
		local function found(c4)
			local lists = c4.calls_to("UpdatePropertyList")
			for i = #lists, 1, -1 do
				if lists[i][1] == "Found Fans" then
					return lists[i][2], lists[i][3]
				end
			end
		end

		local function sends(c4)
			return #c4.calls_to("SendToNetwork")
		end

		-- Runs the clock 100 ms at a time for `ms`: the fan at FAN answers every
		-- request (requests elsewhere wait), and each new query is answered by
		-- `announce`, a list of { message, address }.
		local function serve(env, c4, ms, announce)
			local seen = sends(c4)
			for _ = 1, ms / 100 do
				for _, t in ipairs(c4.open_transfers()) do
					if t.url:find("//" .. FAN .. "/", 1, true) then
						if t.data == '{"queryStaticShadowData":1}' then
							t:respond(200, mf.INFO)
						else
							t:respond(200, mf.state({ fanOn = true, fanSpeed = 3 }))
						end
					end
				end
				if sends(c4) > seen then
					seen = sends(c4)
					for _, a in ipairs(announce or {}) do
						fake.network_receive(env, 6001, 5353, a[1], a[2])
					end
				end
				c4.advance(100)
			end
		end

		it("asks on the mDNS group at load after the device's slot and lists the answers, never in Last Action",
			function()
				local env, c4 = fake.load_driver(DRIVER, {})
				env.OnDriverInit("DIT_ADDING")
				env.OnDriverLateInit("DIT_ADDING")
				assert.equal("Looking for Modern Forms fans on the network...", select(2, found(c4)))
				local before = env.Properties["Last Action"]
				c4.advance(3000)
				assert.equal(0, sends(c4), "not before 3 s plus the slot")
				c4.advance(LOAD_MS - 3000)
				assert.equal(1, sends(c4))
				local created = c4.calls_to("CreateNetworkConnection")[1]
				assert.same({ 6001, "224.0.0.251" }, { created[1], created[2] })
				local connected = c4.calls_to("NetConnect")[1]
				assert.same({ 6001, 5353, "MULTICAST" }, { connected[1], connected[2], connected[3] })
				fake.network_receive(env, 6001, 5353, mdns.K10_FIRST, FAN)
				c4.advance(3100)
				local rows, value = found(c4)
				assert.truthy(rows:find("MF_Fan_005301 at " .. FAN, 1, true), rows)
				assert.equal("1 fan found: pick it and click Set to use it", value)
				assert.equal(before, env.Properties["Last Action"])
				assert.equal("Not set up: pick a fan in Found Fans, or enter Fan Address", env.Properties["Status"])
				assert.equal(1, #c4.calls_to("NetDisconnect"))
			end)

		it("asks again on the seek ladder while no fan is pinned", function()
			local env, c4 = fake.load_driver(DRIVER, {})
			env.OnDriverLateInit("DIT_ADDING")
			c4.advance(LOAD_MS + 3100)
			local after_load = sends(c4)
			assert.equal(2, after_load, "the query and its repeat")
			c4.advance(40000)
			assert.is_true(sends(c4) > after_load, "30 s (+-20 %) after the window closed")
			assert.equal("No fan found yet: enter its address in Fan Address", select(2, found(c4)))
		end)

		it("a pick on an unpinned device takes that fan at once", function()
			local env, c4 = fake.load_driver(DRIVER, {})
			env.OnDriverInit("DIT_ADDING")
			env.OnDriverLateInit("DIT_ADDING")
			c4.advance(LOAD_MS)
			fake.network_receive(env, 6001, 5353, mdns.K10_FIRST, FAN)
			c4.advance(3100)
			local item = found(c4):match("(MF_Fan_005301 at [%d%.]+)")
			set(env, "Found Fans", item)
			assert.equal('{"queryStaticShadowData":1}', last_sent(c4))
			answer(c4, mf.INFO)
			assert.equal(FAN, env.Properties["Fan Address"])
			assert.truthy(env.Properties["Last Action"]:find("^Now using fan MF_00005E005301 at " .. FAN),
				env.Properties["Last Action"])
			assert.equal(select(1, found(c4)):match("^[^,]*"), select(2, found(c4)), "the row snaps back to the summary")
		end)

		it("a pinned device asks only at load, lists its own fan first, and a pick of it changes nothing", function()
			local env, c4 = online_driver()
			serve(env, c4, 35000, { { mdns.K10_FIRST, FAN }, { mdns.FAN_TWO_ALONE, SECOND } })
			local rows, value = found(c4)
			assert.equal("2 fans found; this device's fan is listed first", value)
			assert.truthy(rows:find("^[^,]*,MF_Fan_005301 at " .. FAN .. " %(this device"), rows)
			local after_load = sends(c4)
			serve(env, c4, 600000)
			assert.equal(after_load, sends(c4), "no more windows while the fan answers")
			set(env, "Found Fans", rows:match("(MF_Fan_005301 at [^,]+)"))
			serve(env, c4, 1000)
			assert.truthy(env.Properties["Last Action"]:find("^Already using fan MF_00005E005301"),
				env.Properties["Last Action"])
			assert.equal(FAN, env.Properties["Fan Address"])
		end)

		it("a pick of another fan on a pinned device waits (L32); Use Selected Fan then switches", function()
			local env, c4 = online_driver()
			serve(env, c4, 35000, { { mdns.K10_FIRST, FAN }, { mdns.FAN_TWO_ALONE, SECOND } })
			local item = found(c4):match("(MF_Fan_005302 at [%d%.]+)")
			local transfers = #c4.transfers
			set(env, "Found Fans", item)
			assert.equal("Picked MF_Fan_005302: click Use Selected Fan to switch to it", env.Properties["Last Action"])
			for i = transfers + 1, #c4.transfers do
				assert.is_nil(c4.transfers[i].url:find("//" .. SECOND .. "/", 1, true), "nothing is read yet")
			end
			assert.equal(item, select(2, found(c4)), "the row keeps the waiting pick")
			env.ExecuteCommand("LUA_ACTION", { ACTION = "Use Selected Fan" })
			local t = c4.last_transfer()
			assert.truthy(t.url:find("//" .. SECOND .. "/", 1, true), t.url)
			t:respond(200, (mf.INFO:gsub("00005E005301", "00005E005302"):gsub("00:00:5e:00:53:01", "00:00:5e:00:53:02")))
			c4.advance(300)
			assert.equal(SECOND, env.Properties["Fan Address"])
			assert.truthy(env.Properties["Last Action"]:find("^Now using fan MF_00005E005302 %(was MF_00005E005301%)"),
				env.Properties["Last Action"])
		end)

		it("a pinned device with an empty Fan Address asks nothing, not even at load", function()
			local env, c4 = online_driver()
			set(env, "Fan Address", "")
			c4.advance(120000)
			assert.equal(0, sends(c4))
			assert.equal("Not searching while Fan Address is empty", select(2, found(c4)))
		end)

		it("a second late init (an update in place) asks again", function()
			local env, c4 = fake.load_driver(DRIVER, {})
			env.OnDriverLateInit("DIT_ADDING")
			c4.advance(LOAD_MS + 3100)
			local first = sends(c4)
			env.OnDriverDestroyed("DIT_UPDATING")
			assert.same({}, c4.active_timers())
			env.OnDriverLateInit("DIT_UPDATING")
			c4.advance(40000) -- the slot, and the 30 s floor after the last window closed
			assert.is_true(sends(c4) > first)
		end)

		it("ignores a datagram outside a search window", function()
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

		it("late init deletes the Migration Report's persisted verdict, which went with the report (#45)", function()
			local env, c4 = fake.load_driver(DRIVER, {})
			env.OnDriverInit("DIT_STARTUP")
			env.OnDriverLateInit("DIT_STARTUP")
			local deleted = {}
			for _, call in ipairs(c4.calls_to("PersistDeleteValue")) do deleted[#deleted + 1] = call[1] end
			assert.same({ "mf_migration" }, deleted)
		end)

		it("Reboot Fan with no fan refuses", function()
			local env = fake.load_driver(DRIVER, {})
			env.OnDriverLateInit("DIT_STARTUP")
			env.ExecuteCommand("LUA_ACTION", { ACTION = "Reboot Fan" })
			assert.truthy(env.Properties["Last Action"]:find("^Reboot not sent"), env.Properties["Last Action"])
		end)
	end)

	describe("Breeze (breeze-design, #111, #121)", function()
		local READ = '{"queryDynamicShadowData":1}'

		-- The driver on the fake, its fan answering `state` (mf.state overrides)
		-- to the first state read; `persisted` seeds mf_breeze before init.
		local function breeze_driver(state, persisted)
			local env, c4 = fake.load_driver(DRIVER, { ["Fan Address"] = FAN })
			c4.persist.mf_breeze = persisted
			env.OnDriverInit("DIT_STARTUP")
			env.OnDriverLateInit("DIT_STARTUP")
			answer(c4, mf.INFO)
			assert.equal(READ, last_sent(c4))
			answer(c4, mf.state(state or { fanOn = true, fanSpeed = 3 }))
			return env, c4
		end

		-- The next state read the driver starts by itself, within `limit_ms`.
		local function next_read(c4, limit_ms)
			local seen = #c4.transfers
			for _ = 1, (limit_ms or 30000) / 250 do
				c4.advance(250)
				if #c4.transfers > seen and last_sent(c4) == READ then
					return c4.last_transfer()
				end
			end
			error("no state read within " .. tostring(limit_ms or 30000) .. " ms")
		end

		local function breeze_variable(c4)
			local out = {}
			for _, call in ipairs(c4.calls_to("SetVariable")) do
				if call[1] == "Breeze" then out[#out + 1] = call[2] end
			end
			return out
		end

		local function fired(c4)
			local out = {}
			for _, call in ipairs(c4.calls_to("FireEventByID")) do out[#out + 1] = call[1] end
			return out
		end

		local function to_companion(c4, id)
			local out = {}
			for _, m in ipairs(c4.sent) do
				if m.id == id and m.command == "MF_BREEZE_STATE" then out[#out + 1] = m.params end
			end
			return out
		end

		it("adds the Breeze variable second, after Online, seeded from mf_breeze", function()
			local env, c4 = fake.load_driver(DRIVER, {})
			c4.persist.mf_breeze = true
			env.OnDriverInit("DIT_STARTUP")
			local added = c4.calls_to("AddVariable")
			assert.equal("Online", added[1][1])
			assert.same({ "Breeze", "1", "BOOL", true }, { added[2][1], added[2][2], added[2][3], added[2][4] })
			local env2, c42 = fake.load_driver(DRIVER, {})
			env2.OnDriverInit("DIT_STARTUP")
			assert.equal("0", c42.calls_to("AddVariable")[2][2])
		end)

		it("Breeze On while the fan runs sends {\"wind\":true}; the answer sets the variable and fires Started once",
			function()
				local env, c4 = breeze_driver()
				local events_before = #fired(c4)
				env.ExecuteCommand("Breeze On", {})
				assert.equal('{"wind":true}', last_sent(c4))
				answer(c4, mf.state({ fanOn = true, fanSpeed = 3, wind = true }))
				assert.same({ "1" }, breeze_variable(c4))
				assert.same({ 4 }, { select(events_before + 1, unpack(fired(c4))) })
				assert.is_true(env.TestCondition("BOOL_BREEZE", {}))
				assert.is_false(env.TestCondition("BOOL_BREEZE", { VALUE = "False" }))
				assert.is_true(env.TestCondition("BOOL_BREEZE", { VALUE = "False", LOGIC = "NOT_EQUAL" }))
				assert.truthy(env.Properties["Status"]:find("Breeze 2", 1, true), env.Properties["Status"])
				assert.is_nil(env.Properties["Status"]:find("fan speed", 1, true), "Breeze mode shows no fan speed")
				local speeds = sent(c4, 5001, "CURRENT_SPEED", "SPEED")
				assert.equal(0, speeds[#speeds], "the main fan shows off while Breeze blows (BF-D2)")
				assert.equal(true, c4.persist.mf_breeze)
				-- The same state again changes nothing.
				next_read(c4)
				answer(c4, mf.state({ fanOn = true, fanSpeed = 3, wind = true }))
				assert.same({ "1" }, breeze_variable(c4))
				assert.same({ 4 }, { select(events_before + 1, unpack(fired(c4))) })
			end)

		it("Breeze On while the fan is stopped sends Breeze first, then starts the fan (BF-D5, BF-D6)", function()
			local env, c4 = breeze_driver({ fanOn = false, fanSpeed = 2 })
			env.ExecuteCommand("Breeze On", {})
			assert.equal('{"wind":true}', last_sent(c4), "the mode first")
			answer(c4, mf.state({ fanOn = false, fanSpeed = 2, wind = true }))
			assert.equal('{"fanOn":true,"fanSpeed":2}', last_sent(c4), "then the fan, at its own speed")
			answer(c4, mf.state({ fanOn = true, fanSpeed = 2, wind = true }))
			assert.same({ "1" }, breeze_variable(c4))
			for _, speed in ipairs(sent(c4, 5001, "CURRENT_SPEED", "SPEED")) do
				assert.equal(0, speed, "the main fan never shows a speed: it went straight into Breeze")
			end
		end)

		it("a stopped fan that does not take Breeze is not started: no fan request follows (BF-D13)", function()
			local env, c4 = breeze_driver({ fanOn = false, fanSpeed = 2 })
			env.ExecuteCommand("Breeze On", {})
			assert.equal('{"wind":true}', last_sent(c4))
			local count = #c4.transfers
			answer(c4, mf.state({ fanOn = false, fanSpeed = 2, wind = false }))
			c4.advance(1000)
			assert.equal(count, #c4.transfers, "the start is dropped: it would have started fan mode")
			assert.same({}, breeze_variable(c4))
		end)

		it("Breeze Off while Breeze blows stops the fan, then clears Breeze; Stopped fires (BF-D4)", function()
			local env, c4 = breeze_driver({ fanOn = true, fanSpeed = 3, wind = true })
			assert.is_true(env.TestCondition("BOOL_BREEZE", {}))
			env.ExecuteCommand("Breeze Off", {})
			assert.equal('{"fanOn":false}', last_sent(c4), "the motor stops first")
			answer(c4, mf.state({ fanOn = false, fanSpeed = 3, wind = true }))
			assert.equal('{"wind":false}', last_sent(c4), "then Breeze is cleared")
			answer(c4, mf.state({ fanOn = false, fanSpeed = 3, wind = false }))
			local values = breeze_variable(c4)
			assert.equal("0", values[#values])
			local events = fired(c4)
			assert.equal(5, events[#events])
			assert.is_false(env.TestCondition("BOOL_BREEZE", {}))
			local speeds = sent(c4, 5001, "CURRENT_SPEED", "SPEED")
			assert.equal(0, speeds[#speeds], "the main fan stays off: nothing comes on after Breeze")
		end)

		it("Breeze Off in fan mode sends nothing: it never stops a fan running at a speed (BF-D4)", function()
			local env, c4 = breeze_driver({ fanOn = true, fanSpeed = 3, wind = false })
			local count = #c4.transfers
			env.ExecuteCommand("Breeze Off", {})
			assert.equal(count, #c4.transfers)
		end)

		it("a fan speed on the main fan ends Breeze first, then sets the speed (BF-D3, BF-D6)", function()
			local env, c4 = breeze_driver({ fanOn = true, fanSpeed = 3, wind = true })
			env.ReceivedFromProxy(5001, "SET_SPEED", { SPEED = "4" })
			assert.equal('{"wind":false}', last_sent(c4), "the mode first")
			answer(c4, mf.state({ fanOn = true, fanSpeed = 3, wind = false }))
			assert.equal('{"fanOn":true,"fanSpeed":4}', last_sent(c4), "then the speed")
			answer(c4, mf.state({ fanOn = true, fanSpeed = 4, wind = false }))
			local speeds = sent(c4, 5001, "CURRENT_SPEED", "SPEED")
			assert.equal(4, speeds[#speeds])
			assert.is_false(env.TestCondition("BOOL_BREEZE", {}))
		end)

		it("Off on the main fan during Breeze stops the fan and clears Breeze (BF-D4)", function()
			local env, c4 = breeze_driver({ fanOn = true, fanSpeed = 3, wind = true })
			env.ReceivedFromProxy(5001, "OFF", {})
			assert.equal('{"fanOn":false}', last_sent(c4))
			answer(c4, mf.state({ fanOn = false, fanSpeed = 3, wind = true }))
			assert.equal('{"wind":false}', last_sent(c4))
		end)

		it("Toggle Breeze goes from what is shown; Set Breeze Strength sends the number, refusing anything but 1 to 3",
			function()
				local env, c4 = breeze_driver()
				env.ExecuteCommand("Toggle Breeze", {})
				assert.equal('{"wind":true}', last_sent(c4))
				answer(c4, mf.state({ fanOn = true, fanSpeed = 3, wind = true }))
				env.ExecuteCommand("Toggle Breeze", {})
				assert.equal('{"fanOn":false}', last_sent(c4), "toggling off while Breeze blows stops the fan")
				answer(c4, mf.state({ fanOn = false, fanSpeed = 3, wind = true }))
				answer(c4, mf.state({ fanOn = false, fanSpeed = 3, wind = false }))
				env.ExecuteCommand("Set Breeze Strength", { STRENGTH = "3" })
				assert.equal('{"windSpeed":3}', last_sent(c4))
				answer(c4, mf.state({ fanOn = false, fanSpeed = 3, windSpeed = 3 }))
				local count = #c4.transfers
				env.ExecuteCommand("Set Breeze Strength", { STRENGTH = "5" })
				assert.equal(count, #c4.transfers, "nothing sent")
				assert.equal("Breeze strength 5 refused: use 1, 2 or 3", env.Properties["Last Action"])
			end)

		it("a restart with the fan blowing as mf_breeze says fires nothing and sets nothing (BC22)", function()
			local _, c4 = breeze_driver({ fanOn = true, fanSpeed = 3, wind = true }, true)
			assert.same({}, breeze_variable(c4))
			for _, id in ipairs(fired(c4)) do
				assert.is_true(id ~= 4 and id ~= 5, "no Breeze event at a restart")
			end
		end)

		it("a restart that finds Breeze ended fires Stopped once", function()
			local _, c4 = breeze_driver({ fanOn = true, fanSpeed = 3, wind = false }, true)
			assert.same({ "0" }, breeze_variable(c4))
			local stopped = 0
			for _, id in ipairs(fired(c4)) do
				if id == 5 then stopped = stopped + 1 end
			end
			assert.equal(1, stopped)
		end)

		it("guards against gusts: a read whose only change is the speed during Breeze is not told (BZ8)", function()
			local _, c4 = breeze_driver({ fanOn = true, fanSpeed = 3, wind = true })
			assert.same({ 0 }, sent(c4, 5001, "CURRENT_SPEED", "SPEED"), "Breeze mode: the main fan shows off")
			next_read(c4)
			answer(c4, mf.state({ fanOn = true, fanSpeed = 5, wind = true }))
			assert.same({ 0 }, sent(c4, 5001, "CURRENT_SPEED", "SPEED"), "the gust is not told")
			next_read(c4)
			answer(c4, mf.state({ fanOn = true, fanSpeed = 4, wind = false }))
			local speeds = sent(c4, 5001, "CURRENT_SPEED", "SPEED")
			assert.equal(4, speeds[#speeds], "the speed is told again once Breeze ends")
		end)

		it("link 311 toggles Breeze on a push and its LED follows Breeze (BZ4)", function()
			local env, c4 = breeze_driver()
			fake.link_keypad(env, 311, 456, 3)
			env.ReceivedFromProxy(311, "DO_PUSH", {})
			assert.equal('{"wind":true}', last_sent(c4))
			answer(c4, mf.state({ fanOn = true, fanSpeed = 3, wind = true }))
			local lit = sent(c4, 311, "MATCH_LED_STATE", "STATE")
			assert.equal(true, lit[#lit])
			env.ReceivedFromProxy(311, "DO_PUSH", {})
			assert.equal('{"fanOn":false}', last_sent(c4), "toggling off while Breeze blows stops the fan")
			answer(c4, mf.state({ fanOn = false, fanSpeed = 3, wind = true }))
			answer(c4, mf.state({ fanOn = false, fanSpeed = 3, wind = false }))
			lit = sent(c4, 311, "MATCH_LED_STATE", "STATE")
			assert.equal(false, lit[#lit])
		end)

		-- #137, docs/breeze-leds-design.md: gusts on the bound speed links while
		-- Breeze blows, a rising wipe in, a falling wipe out (BL-D6 to BL-D11).
		describe("the Breeze LEDs (breeze-leds-design, #137)", function()
			local PURPLE, HEAD = "8000ff", "ffffff"
			local PIXELS = { 302, 303, 304, 305 } -- Low, Medium, Med-High, High on the house
			-- The animation's colours (section 1a, BL-D20); pure blue is never one.
			local FRAME = { ffffff = true, a0ffff = true, ["00ffff"] = true, ["40b0ff"] = true }

			-- The house's keypad: four speed buttons and Off; 311 bound too.
			local function leds_driver(state, extra)
				local props = {
					["Fan Address"] = FAN,
					["Speed LED Colors"] = "Per speed",
					["Breeze LED Animation"] = "Gusts",
				}
				for speed = 1, 6 do
					props["Speed " .. speed .. " LED Color"] = "128,0,255"
				end
				for name, value in pairs(extra or {}) do
					props[name] = value
				end
				local env, c4 = fake.load_driver(DRIVER, props)
				env.OnDriverInit("DIT_STARTUP")
				env.OnDriverLateInit("DIT_STARTUP")
				answer(c4, mf.INFO)
				answer(c4, mf.state(state or { fanOn = true, fanSpeed = 3, wind = false }))
				for index, link in ipairs({ 302, 303, 304, 305, 300, 311 }) do
					fake.link_keypad(env, link, 456, 10 + index)
				end
				return env, c4
			end

			-- What the keypad shows on each pixel, replayed from the messages since
			-- c4.calls was last emptied, as measured on the house (#137): a colour
			-- loaded while dark stays dark; MATCH_LED_STATE shows the loaded colour
			-- or dark; a BUTTON_COLORS with CURRENT_COLOR repaints a lit button.
			-- Returns every visible change in order, { link, colour or "dark" }.
			local function shows(c4, loaded)
				loaded = loaded or {}
				local lit, out = {}, {}
				local function see(link, what)
					out[#out + 1] = { link, what }
				end
				for _, args in ipairs(c4.calls_to("SendToProxy")) do
					local link, command, params = args[1], args[2], args[3]
					if link >= 302 and link <= 305 then
						if command == "BUTTON_COLORS" then
							loaded[link] = params.ON_COLOR
							if lit[link] and params.CURRENT_COLOR then
								see(link, params.CURRENT_COLOR)
							end
						elseif command == "MATCH_LED_STATE" then
							lit[link] = params.STATE == true
							see(link, lit[link] and (loaded[link] or "?") or "dark")
						end
					end
				end
				return out
			end

			-- The index of the first change of `link` to `what`, or nil.
			local function first(list, link, what)
				for index, item in ipairs(list) do
					if item[1] == link and item[2] == what then
						return index
					end
				end
				return nil
			end

			-- Whether any change in `list` shows one of the animation's colours.
			local function any_frame(list)
				for _, item in ipairs(list) do
					if FRAME[item[2]] then
						return true
					end
				end
				return false
			end

			-- The last MATCH_LED_STATE a link got.
			local function last_state(c4, link)
				local states = sent(c4, link, "MATCH_LED_STATE", "STATE")
				return states[#states]
			end

			-- The fan answers every read and command with `state` for `ms`.
			local function hold_state(c4, state, ms)
				for _ = 1, ms / 100 do
					for _, t in ipairs(c4.open_transfers()) do
						t:respond(200, mf.state(state))
					end
					c4.advance(100)
				end
			end

			it("runs the gusts down from the top while the fan blows down (forward, BL-D30)", function()
				local env, c4 = leds_driver()
				c4.calls = {}
				env.ReceivedFromProxy(311, "DO_PUSH", {})
				hold_state(c4, { fanOn = true, fanSpeed = 3, wind = true, windSpeed = 2, fanDirection = "forward" }, 6000)
				local list = shows(c4)
				for index = #PIXELS, 2, -1 do
					local upper, lower = first(list, PIXELS[index], HEAD), first(list, PIXELS[index - 1], HEAD)
					assert.is_not_nil(upper, "the front reaches " .. PIXELS[index])
					assert.is_not_nil(lower, "the front reaches " .. PIXELS[index - 1])
					assert.is_true(upper < lower, "top to bottom")
				end
			end)

			it("loads a dark button's next colour without CURRENT_COLOR, so the load never lights it (#164)", function()
				local env, c4 = leds_driver()
				c4.calls = {}
				env.ReceivedFromProxy(311, "DO_PUSH", {})
				hold_state(c4, { fanOn = true, fanSpeed = 3, wind = true, windSpeed = 2, fanDirection = "forward" }, 6000)
				local lit, preloads = { [303] = true }, 0
				for _, args in ipairs(c4.calls_to("SendToProxy")) do
					local link, command, params = args[1], args[2], args[3]
					if link >= 302 and link <= 305 then
						if command == "MATCH_LED_STATE" then
							lit[link] = params.STATE == true
						elseif command == "BUTTON_COLORS" and not lit[link] then
							preloads = preloads + 1
							assert.is_nil(params.CURRENT_COLOR, "a colour loaded into dark " .. link)
						end
					end
				end
				assert.is_true(preloads > 0, "the gusts preload dark buttons")
			end)

			it("darkens every speed button first, then runs a gust's white front up from the bottom while the fan "
				.. "blows up (BL-D19, BL-D21, BL-D30)", function()
					local env, c4 = leds_driver({ fanOn = true, fanSpeed = 3, wind = false, fanDirection = "reverse" })
					c4.calls = {}
					env.ReceivedFromProxy(311, "DO_PUSH", {})
					local list = shows(c4)
					for _, link in ipairs(PIXELS) do
						assert.is_not_nil(first(list, link, "dark"), link .. " goes dark at the press")
					end
					assert.is_false(any_frame(list), "nothing animated before the dark-first")
					hold_state(c4, { fanOn = true, fanSpeed = 3, wind = true, windSpeed = 2, fanDirection = "reverse" },
						6000)
					list = shows(c4)
					for index, link in ipairs(PIXELS) do
						assert.is_not_nil(first(list, link, HEAD), "the front reaches " .. link)
						if index > 1 then
							assert.is_true(first(list, PIXELS[index - 1], HEAD) < first(list, link, HEAD), "bottom to top")
						end
					end
					for _, item in ipairs(list) do
						assert.not_equal("0000ff", item[2], "never pure blue")
					end
					assert.same({}, sent(c4, 300, "BUTTON_COLORS"), "Off never takes a colour")
					assert.is_not_true(last_state(c4, 300), "Off stays dark while Breeze blows")
					assert.equal(true, last_state(c4, 311), "311 lights")
				end)

			-- The index, among every SendToProxy since c4.calls was emptied, of the
			-- first BUTTON_COLORS with `colour` to `link`; nil when none.
			local function colour_at(c4, link, colour)
				for index, args in ipairs(c4.calls_to("SendToProxy")) do
					if args[1] == link and args[2] == "BUTTON_COLORS" and args[3].ON_COLOR == colour then
						return index
					end
				end
				return nil
			end

			-- BL-D28, BL-D29: at a grid location (no one's home), midnight in January
			-- (05:00 UTC) is night and noon (17:00 UTC) is day.
			local NIGHT_S, DAY_S = 1768453200, 1768496400
			local function at_location(epoch, extra)
				local real_time = os.time
				os.time = function(t) -- luacheck: ignore 122
					if t == nil then
						return epoch
					end
					return real_time(t)
				end
				local ok, env, c4 = pcall(function()
					local props = {
						["Fan Address"] = FAN,
						["Speed LED Colors"] = "Per speed",
						["Breeze LED Animation"] = "Gusts",
					}
					for speed = 1, 6 do
						props["Speed " .. speed .. " LED Color"] = "128,0,255"
					end
					for name, value in pairs(extra or {}) do
						props[name] = value
					end
					local env, c4 = fake.load_driver(DRIVER, props)
					c4.GetProjectProperty = function(_, name)
						return ({ Latitude = "40.7", Longitude = "-74.0" })[name]
					end
					env.OnDriverInit("DIT_STARTUP")
					env.OnDriverLateInit("DIT_STARTUP")
					answer(c4, mf.INFO)
					answer(c4, mf.state({ fanOn = true, fanSpeed = 3, wind = false }))
					for index, link in ipairs({ 302, 303, 304, 305, 300, 311 }) do
						fake.link_keypad(env, link, 456, 10 + index)
					end
					c4.calls = {}
					env.ReceivedFromProxy(311, "DO_PUSH", {})
					hold_state(c4, { fanOn = true, fanSpeed = 3, wind = true, windSpeed = 2 }, 6000)
					return env, c4
				end)
				os.time = real_time -- luacheck: ignore 122
				assert(ok, env)
				return env, c4
			end

			it("sends the animation's colours at half strength at night at the project's location (BL-D28, BL-D29)",
				function()
					local _, c4 = at_location(NIGHT_S)
					local list = shows(c4)
					assert.is_not_nil(first(list, PIXELS[#PIXELS], "808080"), "a half-white head at night")
					assert.is_false(any_frame(list), "no full-strength frame colour at night")
					local _, c4_day = at_location(DAY_S)
					local day = shows(c4_day)
					assert.is_not_nil(first(day, PIXELS[#PIXELS], HEAD), "a full-white head by day")
					local _, c4_full = at_location(NIGHT_S, { ["Breeze LED Night Brightness (%)"] = "100" })
					assert.is_not_nil(first(shows(c4_full), PIXELS[#PIXELS], HEAD), "100 % keeps full white at night")
				end)

			it("plays the ending wipe once when a speed press ends Breeze, against the gusts, and leaves the pressed "
				.. "button lit (BL-D25, BL-D30)", function()
				local env, c4 = leds_driver({ fanOn = true, fanSpeed = 3, wind = true, windSpeed = 2 })
				hold_state(c4, { fanOn = true, fanSpeed = 3, wind = true, windSpeed = 2 }, 6000)
				c4.calls = {}
				env.ReceivedFromProxy(303, "DO_PUSH", {})
				hold_state(c4, { fanOn = true, fanSpeed = 3, wind = false }, 4000)
				-- Each pixel is settled, with its own per-speed colour, as the head
				-- leaves it: top to bottom.
				local settled = {}
				for index, link in ipairs(PIXELS) do
					settled[index] = colour_at(c4, link, PURPLE)
					assert.is_not_nil(settled[index], link .. " is settled")
				end
				-- The fixture's fan blows down (forward), so the gusts fell and the wipe rises.
				for index = 2, #PIXELS do
					assert.is_true(settled[index - 1] < settled[index], "bottom to top")
				end
				assert.equal(true, last_state(c4, 303), "Medium ends lit")
				local colours = sent(c4, 303, "BUTTON_COLORS", "ON_COLOR")
				assert.equal(PURPLE, colours[#colours], "in its own colour")
				for _, link in ipairs({ 302, 304, 305 }) do
					assert.equal(false, last_state(c4, link), link .. " ends dark")
				end
				-- Nothing of the animation after the last settle: the wipe played once.
				local calls = c4.calls_to("SendToProxy")
				for index = settled[#PIXELS] + 1, #calls do
					local args = calls[index]
					if args[1] >= 302 and args[1] <= 305 and args[2] == "BUTTON_COLORS" then
						assert.is_nil(FRAME[args[3].ON_COLOR], "no frame colour after the wipe")
					end
				end
			end)

			it("lights Off at once when Off ends Breeze, and the falling wipe leaves every speed button dark", function()
				local env, c4 = leds_driver({ fanOn = true, fanSpeed = 3, wind = true, windSpeed = 2 })
				hold_state(c4, { fanOn = true, fanSpeed = 3, wind = true, windSpeed = 2 }, 6000)
				c4.calls = {}
				env.ReceivedFromProxy(300, "DO_PUSH", {})
				assert.equal(true, last_state(c4, 300), "Off lights with the press")
				hold_state(c4, { fanOn = false, fanSpeed = 3, wind = false }, 4000)
				for _, link in ipairs(PIXELS) do
					assert.equal(false, last_state(c4, link), link .. " ends dark")
				end
			end)

			it("starts the gusts when Breeze is started from the Modern Forms app (a poll)", function()
				local _, c4 = leds_driver()
				c4.calls = {}
				next_read(c4)
				answer(c4, mf.state({ fanOn = true, fanSpeed = 3, wind = true, windSpeed = 3 }))
				hold_state(c4, { fanOn = true, fanSpeed = 3, wind = true, windSpeed = 3 }, 5000)
				local list = shows(c4)
				assert.is_true(first(list, 305, HEAD) < first(list, 302, HEAD), "down from the top: the fan blows down (BL-D30)")
			end)

			it("puts every pixel back at once, with no wipe, when the property goes Off", function()
				local env, c4 = leds_driver({ fanOn = true, fanSpeed = 3, wind = true, windSpeed = 3 })
				hold_state(c4, { fanOn = true, fanSpeed = 3, wind = true, windSpeed = 3 }, 3000)
				c4.calls = {}
				env.Properties["Breeze LED Animation"] = "Off"
				env.OnPropertyChanged("Breeze LED Animation")
				for _, link in ipairs(PIXELS) do
					assert.equal(false, last_state(c4, link), link .. " shows the real state at once")
				end
				c4.calls = {}
				hold_state(c4, { fanOn = true, fanSpeed = 3, wind = true, windSpeed = 3 }, 10000)
				assert.is_false(any_frame(shows(c4)), "and nothing is shown afterwards")
				assert.same({}, sent(c4, 305, "MATCH_LED_STATE"))
			end)

			it("puts every pixel back at once when the fan goes offline, and sends nothing more", function()
				local _, c4 = leds_driver({ fanOn = true, fanSpeed = 3, wind = true, windSpeed = 2 })
				hold_state(c4, { fanOn = true, fanSpeed = 3, wind = true, windSpeed = 2 }, 3000)
				local function fail_for(ms)
					for _ = 1, ms / 100 do
						for _, t in ipairs(c4.open_transfers()) do
							t:fail(-1, "timeout")
						end
						c4.advance(100)
					end
				end
				fail_for(90000)
				for _, link in ipairs(PIXELS) do
					assert.equal(false, last_state(c4, link), link .. " back to the steady Breeze picture")
				end
				c4.calls = {}
				fail_for(10000)
				for _, link in ipairs(PIXELS) do
					assert.same({}, c4.proxy_messages(link), link .. " gets nothing while the fan is away")
				end
			end)

			it("writes L42 and animates nothing under Keypad's own colours", function()
				local env, c4 = leds_driver(nil, { ["Speed LED Colors"] = "Keypad's own" })
				env.Properties["Breeze LED Animation"] = "Gusts"
				env.OnPropertyChanged("Breeze LED Animation")
				assert.equal("Breeze LEDs need Speed LED Colors set to Per speed", env.Properties["Last Action"])
				c4.calls = {}
				env.ReceivedFromProxy(311, "DO_PUSH", {})
				hold_state(c4, { fanOn = true, fanSpeed = 3, wind = true, windSpeed = 2 }, 5000)
				assert.is_false(any_frame(shows(c4)))
				for _, link in ipairs(PIXELS) do
					assert.same({}, sent(c4, link, "BUTTON_COLORS"), link .. " takes no colour")
				end
			end)

			-- #159, docs/speed-leds-design.md: the chase at a fixed speed.
			local FWD3 = { fanOn = true, fanSpeed = 3, wind = false, fanDirection = "forward" }

			it("waits 2.5 s after the speed is selected, then runs a dot in the speed's colour down the speed buttons"
				.. " at speed 3, with Medium dark during the chase and lit again after it (SL-D3 to SL-D12, SL-D19)", function()
					local env, c4 = leds_driver(FWD3, { ["Speed LED Animation"] = "Speeds 2 to 5" })
					assert.is_not_nil(env)
					c4.calls = {}
					hold_state(c4, FWD3, 2400)
					assert.same({}, shows(c4, { [303] = PURPLE }), "nothing changes before 2.5 s")
					c4.calls = {}
					hold_state(c4, FWD3, 1600)
					local list = shows(c4, { [303] = PURPLE })
					assert.same({ 303, "dark" }, list[1], "the selected button goes dark first")
					-- Lowest speed at the bottom and the fan blowing down: High to Low.
					local order = { 305, 304, 303, 302 }
					for index = 1, #order - 1 do
						local upper, lower = first(list, order[index], PURPLE), first(list, order[index + 1], PURPLE)
						assert.is_not_nil(upper, "the dot reaches " .. order[index])
						assert.is_not_nil(lower, "the dot reaches " .. order[index + 1])
						assert.is_true(upper < lower, "top to bottom")
					end
					for _, item in ipairs(list) do
						assert.is_true(item[2] == PURPLE or item[2] == "dark", "only the speed's colour or dark")
					end
					assert.same({ 303, PURPLE }, list[#list], "Medium is lit again at the end")
					for _, link in ipairs({ 302, 304, 305 }) do
						assert.is_false(last_state(c4, link), link .. " ends dark")
					end
				end)

			it("never blinks the selected button twice at the edge speeds: it is the dot's first or last position"
				.. " (SL-D18, #172)", function()
					-- Lowest speed at the bottom, blowing down: the dot runs High (305) to Low (302).
					for _, case in ipairs({ { speed = 5, link = 305 }, { speed = 2, link = 302 } }) do
						local state = { fanOn = true, fanSpeed = case.speed, wind = false, fanDirection = "forward" }
						local _, c4 = leds_driver(state, { ["Speed LED Animation"] = "Speeds 2 to 5" })
						c4.calls = {}
						hold_state(c4, state, 4500) -- the first chase only (2.5 s to 4.1 s at speed 2)
						local seen = {}
						for _, item in ipairs(shows(c4, { [case.link] = PURPLE })) do
							if item[1] == case.link then
								seen[#seen + 1] = item[2]
							end
						end
						assert.same({ "dark", PURPLE }, seen, "speed " .. case.speed .. ": one dark, one lit, per chase")
						assert.is_true(last_state(c4, case.link), "speed " .. case.speed .. " ends lit")
					end
				end)

			it("leaves the buttons to the gusts when Breeze starts during a chase (SL-D2, SL-D11)", function()
				local env, c4 = leds_driver(FWD3, { ["Speed LED Animation"] = "Speeds 2 to 5" })
				hold_state(c4, FWD3, 3000) -- the first chase plays from 2.5 s to 3.7 s
				c4.calls = {}
				env.ReceivedFromProxy(311, "DO_PUSH", {})
				hold_state(c4, { fanOn = true, fanSpeed = 3, wind = true, windSpeed = 2, fanDirection = "forward" }, 6000)
				local list = shows(c4, { [302] = PURPLE, [303] = PURPLE, [304] = PURPLE, [305] = PURPLE })
				assert.is_true(any_frame(list), "the gusts run")
				local gusting = false
				for _, item in ipairs(list) do
					gusting = gusting or FRAME[item[2]] ~= nil
					if gusting then
						assert.is_true(item[2] ~= PURPLE, "no dot once the gusts run (" .. item[1] .. ")")
					end
				end
			end)

			it("ends a chase when the speed's colour changes, so Medium lights in the new colour (SL-D11)", function()
				local env, c4 = leds_driver(FWD3, { ["Speed LED Animation"] = "Speeds 2 to 5" })
				hold_state(c4, FWD3, 3000) -- the first chase plays from 2.5 s to 3.7 s
				c4.calls = {}
				env.Properties["Speed 3 LED Color"] = "255,0,0"
				env.OnPropertyChanged("Speed 3 LED Color")
				hold_state(c4, FWD3, 2000)
				local list, medium = shows(c4), nil
				for _, item in ipairs(list) do
					if item[1] == 303 then
						medium = item[2]
					end
				end
				assert.equal("ff0000", medium, "Medium ends lit in the new colour")
				for _, link in ipairs({ 302, 304, 305 }) do
					assert.is_false(last_state(c4, link), link .. " ends dark")
				end
			end)

			-- When `link` is first lit after `start` and when it first goes dark after that, in ms, while the fan
			-- answers every read and command with `state` (#177).
			local function lit_then_dark(c4, state, ms, link)
				local lit_at, dark_at
				for t = 100, ms, 100 do
					for _, transfer in ipairs(c4.open_transfers()) do
						transfer:respond(200, mf.state(state))
					end
					c4.advance(100)
					for _, args in ipairs(c4.calls_to("SendToProxy")) do
						if args[1] == link and args[2] == "MATCH_LED_STATE" then
							if args[3].STATE == true and not lit_at then
								lit_at = t
							elseif args[3].STATE == false and lit_at and not dark_at then
								dark_at = t
							end
						end
					end
				end
				return lit_at, dark_at
			end

			describe("starts the first chase 2.5 s after a speed is selected, whatever selected it (#177, SL-D19)",
				function()
					local FWD4 = { fanOn = true, fanSpeed = 4, wind = false, fanDirection = "forward" }

					local function settled_driver(state)
						local env, c4 = leds_driver(state, { ["Speed LED Animation"] = "Speeds 2 to 5" })
						hold_state(c4, state, 4000) -- past the first chase at the old speed
						c4.calls = {}
						return env, c4
					end

					local function assert_first_chase(lit_at, dark_at, what)
						assert.is_not_nil(lit_at, what .. ": Med-High lights")
						assert.is_not_nil(dark_at, what .. ": the chase starts")
						local wait = dark_at - lit_at
						assert.is_true(wait >= 2400 and wait <= 2700, what .. ": 2.5 s, not " .. wait .. " ms")
					end

					it("a keypad press", function()
						local env, c4 = settled_driver(FWD3)
						env.ReceivedFromProxy(304, "DO_PUSH", {})
						env.ReceivedFromProxy(304, "DO_RELEASE", {})
						local lit_at, dark_at = lit_then_dark(c4, FWD4, 6000, 304)
						assert_first_chase(lit_at, dark_at, "keypad")
					end)

					it("programming or a Navigator, through the fan proxy", function()
						local env, c4 = settled_driver(FWD3)
						env.ReceivedFromProxy(5001, "SET_SPEED", { SPEED = "4" })
						local lit_at, dark_at = lit_then_dark(c4, FWD4, 6000, 304)
						assert_first_chase(lit_at, dark_at, "programming")
					end)

					it("the Modern Forms app, its remote or the wall control, seen at the next poll", function()
						local _, c4 = settled_driver(FWD3)
						local lit_at, dark_at = lit_then_dark(c4, FWD4, 25000, 304)
						assert_first_chase(lit_at, dark_at, "app")
					end)

					it("the fan started at a speed", function()
						local env, c4 = settled_driver({ fanOn = false, fanSpeed = 3, wind = false, fanDirection = "forward" })
						env.ReceivedFromProxy(5001, "SET_SPEED", { SPEED = "4" })
						local lit_at, dark_at = lit_then_dark(c4, FWD4, 6000, 304)
						assert_first_chase(lit_at, dark_at, "start")
					end)
				end)

			it("chases nothing by default (SL-D8)", function()
				local _, c4 = leds_driver(FWD3, { ["Breeze LED Animation"] = "Off" })
				c4.calls = {}
				hold_state(c4, FWD3, 25000)
				for _, link in ipairs(PIXELS) do
					assert.same({}, sent(c4, link, "MATCH_LED_STATE"), link .. " is left alone")
				end
			end)

			it("writes L43 and chases nothing under Keypad's own colours (SL-D9)", function()
				local env, c4 = leds_driver(FWD3, { ["Speed LED Colors"] = "Keypad's own" })
				env.Properties["Speed LED Animation"] = "Speeds 2 to 5"
				env.OnPropertyChanged("Speed LED Animation")
				assert.equal("LED chase needs Speed LED Colors set to Per speed", env.Properties["Last Action"])
				c4.calls = {}
				hold_state(c4, FWD3, 25000)
				for _, link in ipairs(PIXELS) do
					assert.same({}, sent(c4, link, "MATCH_LED_STATE"), link .. " is left alone")
					assert.same({}, sent(c4, link, "BUTTON_COLORS"), link .. " takes no colour")
				end
			end)
		end)

		it("Add Breeze Fan adds the Breeze fan in the fan's room, named after the fan item, and binds it (BF-D10)",
			function()
				local env, c4 = breeze_driver()
				env.ExecuteCommand("LUA_ACTION", { ACTION = "Add Breeze Fan" })
				assert.equal(1, #c4.added)
				local added = c4.added[1]
				assert.equal("modernforms_breeze_fan.c4z", added.driver)
				assert.equal("Modern Forms Fan Breeze", added.name)
				assert.same({ { c4.device_id, 400, added.id, 1, "MODERNFORMS_BREEZE" } }, c4.calls_to("Bind"))
				assert.equal("Breeze fan added: Modern Forms Fan Breeze", env.Properties["Last Action"])
				-- A second click names the one already there and adds nothing.
				env.ExecuteCommand("LUA_ACTION", { ACTION = "Add Breeze Fan" })
				assert.equal(1, #c4.added)
				assert.equal("A Breeze fan is already connected: Modern Forms Fan Breeze", env.Properties["Last Action"])
			end)

		it("Add Breeze Fan with a 1.2 Breeze switch still bound asks for its delete first (BF-D10, L41)", function()
			local env, c4 = breeze_driver()
			fake.define_driver("modernforms_breeze", "<devicedata><name>Modern Forms Breeze</name></devicedata>")
			local old
			c4:AddDevice("modernforms_breeze.c4z", 7, "Aviator 5 Breeze", function(id) old = id end)
			c4:Bind(c4.device_id, 400, old, 1, "MODERNFORMS_BREEZE")
			local adds = #c4.added
			env.ExecuteCommand("LUA_ACTION", { ACTION = "Add Breeze Fan" })
			fake.define_driver("modernforms_breeze", nil)
			assert.equal(adds, #c4.added, "nothing added")
			assert.equal("Delete the old Breeze switch first: Modern Forms Fan Breeze", env.Properties["Last Action"])
		end)

		it("Add Breeze Fan with no fan set up adds nothing", function()
			local env, c4 = fake.load_driver(DRIVER, {})
			env.OnDriverInit("DIT_STARTUP")
			env.OnDriverLateInit("DIT_STARTUP")
			env.ExecuteCommand("LUA_ACTION", { ACTION = "Add Breeze Fan" })
			assert.same({}, c4.added)
			assert.equal("No Breeze fan added: set up the fan first", env.Properties["Last Action"])
		end)

		it("answers the companion: its HELLO gets the state, its SET and TOGGLE run the commands", function()
			local env, c4 = breeze_driver()
			env.ExecuteCommand("LUA_ACTION", { ACTION = "Add Breeze Fan" })
			local id = c4.added[1].id
			env.OnBindingChanged(400, "MODERNFORMS_BREEZE", true, id, 1)
			env.ExecuteCommand("MF_BREEZE_HELLO", {})
			local states = to_companion(c4, id)
			assert.truthy(#states >= 1)
			local last = states[#states]
			assert.equal("0", tostring(last.BLOWS))
			assert.equal("1", tostring(last.AVAILABLE))
			assert.equal("Modern Forms Fan", last.FAN)
			assert.equal("2", tostring(last.STRENGTH), "the fan's own strength (BF-D9)")
			env.ExecuteCommand("MF_BREEZE_SET", { ON = "1" })
			assert.equal('{"wind":true}', last_sent(c4))
			answer(c4, mf.state({ fanOn = true, fanSpeed = 3, wind = true }))
			states = to_companion(c4, id)
			assert.equal("1", tostring(states[#states].BLOWS), "the change goes to the companion")
			env.ExecuteCommand("MF_BREEZE_TOGGLE", {})
			assert.equal('{"fanOn":false}', last_sent(c4), "the fan decides the toggle: off while Breeze blows")
			answer(c4, mf.state({ fanOn = false, fanSpeed = 3, wind = true }))
			answer(c4, mf.state({ fanOn = false, fanSpeed = 3, wind = false }))
			local sent_before = #to_companion(c4, id)
			env.ExecuteCommand("MF_BREEZE_SET", { ON = "1", STRENGTH = "9" })
			assert.equal("Breeze strength 9 refused: use 1, 2 or 3", env.Properties["Last Action"])
			assert.truthy(#to_companion(c4, id) > sent_before, "a refused request is answered with the state (BF-D9)")
			env.ExecuteCommand("MF_BREEZE_CYCLE", { STEP = "1" })
			assert.equal('{"wind":true,"windSpeed":1}', last_sent(c4), "cycle up from not-Breeze is Breeze 1")
		end)

		it("with the Breeze fan paired, its tile shows the strength and its speeds start Breeze (BF-D8)", function()
			local fan_env, fan_c4 = fake.load_driver(DRIVER, { ["Fan Address"] = FAN })
			local sw_env, sw_c4 = fake.load_driver("modernforms_breeze_fan", {})
			fake.pair(fan_env, sw_env,
				{ bind = { provider_binding = 400, consumer_binding = 1, class = "MODERNFORMS_BREEZE" } })
			fake.as(fan_env, function()
				fan_env.OnDriverInit("DIT_STARTUP")
				fan_env.OnDriverLateInit("DIT_STARTUP")
				answer(fan_c4, mf.INFO)
				answer(fan_c4, mf.state({ fanOn = true, fanSpeed = 3 }))
			end)
			fake.as(sw_env, function()
				sw_env.OnDriverInit("DIT_STARTUP")
				sw_env.OnDriverLateInit("DIT_STARTUP")
			end)
			fake.pump()
			local tile = sent(sw_c4, 5001, "CURRENT_SPEED", "SPEED")
			assert.equal(0, tonumber(tile[#tile]), "the Breeze fan is off in fan mode")
			fake.as(sw_env, sw_env.ReceivedFromProxy, 5001, "SET_SPEED", { SPEED = "3" })
			fake.pump()
			assert.equal('{"wind":true,"windSpeed":3}', last_sent(fan_c4), "Breeze 3 reached the fan")
			fake.as(fan_env, answer, fan_c4, mf.state({ fanOn = true, fanSpeed = 3, wind = true, windSpeed = 3 }))
			fake.pump()
			tile = sent(sw_c4, 5001, "CURRENT_SPEED", "SPEED")
			assert.equal(3, tonumber(tile[#tile]), "the tile shows Breeze 3 once the fan confirms")
			local main = sent(fan_c4, 5001, "CURRENT_SPEED", "SPEED")
			assert.equal(0, tonumber(main[#main]), "the main fan shows off: never both")
			-- A fan speed on the main fan ends Breeze: the Breeze fan goes off.
			fake.as(fan_env, fan_env.ReceivedFromProxy, 5001, "SET_SPEED", { SPEED = "2" })
			fake.as(fan_env, answer, fan_c4, mf.state({ fanOn = true, fanSpeed = 3, wind = false, windSpeed = 3 }))
			fake.as(fan_env, answer, fan_c4, mf.state({ fanOn = true, fanSpeed = 2, wind = false, windSpeed = 3 }))
			fake.pump()
			tile = sent(sw_c4, 5001, "CURRENT_SPEED", "SPEED")
			assert.equal(0, tonumber(tile[#tile]))
			main = sent(fan_c4, 5001, "CURRENT_SPEED", "SPEED")
			assert.equal(2, tonumber(main[#main]))
		end)

		it("a fan without Breeze refuses the commands, the press and the switch, and sends nothing (BZ10)", function()
			local env, c4 = breeze_driver({ fanOn = true, fanSpeed = 3, wind = mf.OMIT, windSpeed = mf.OMIT })
			local count = #c4.transfers
			env.ExecuteCommand("Breeze On", {})
			assert.equal(count, #c4.transfers)
			assert.equal("Breeze not available: this fan reports no Breeze", env.Properties["Last Action"])
			env.ExecuteCommand("LUA_ACTION", { ACTION = "Add Breeze Fan" })
			assert.same({}, c4.added)
			assert.equal("No Breeze fan added: this fan reports no Breeze", env.Properties["Last Action"])
			assert.same({}, breeze_variable(c4))
			assert.is_false(env.TestCondition("BOOL_BREEZE", {}))
		end)
	end)

	describe("the keypad LED rows only with a keypad (keypad-leds-visibility-design, #178)", function()
		local ROWS = require("fan.ledrows").ROWS
		local SHOWN = "Keypad LED settings shown: a button is on a Fan Speed link"
		local HIDDEN = "Keypad LED settings hidden: no button on a Fan Speed link"
		local STATE = { fanOn = true, fanSpeed = 3, wind = false, fanDirection = "forward" }

		local function rows_driver()
			local env, c4 = fake.load_driver(DRIVER, { ["Fan Address"] = FAN })
			env.OnDriverInit("DIT_STARTUP")
			assert.same({}, c4.property_attribs, "nothing is hidden or shown in OnDriverInit (KL-D6)")
			env.OnDriverLateInit("DIT_STARTUP")
			answer(c4, mf.INFO)
			answer(c4, mf.state(STATE))
			return env, c4
		end

		-- Time passes while the fan answers every read with STATE.
		local function run(c4, ms)
			for _ = 1, ms / 100 do
				for _, transfer in ipairs(c4.open_transfers()) do
					transfer:respond(200, mf.state(STATE))
				end
				c4.advance(100)
			end
		end

		local function all_rows(c4, attrib)
			for _, name in ipairs(ROWS) do
				if c4.property_attribs[name] ~= attrib then
					return false, name
				end
			end
			return true
		end

		local function values(env)
			local out = {}
			for _, name in ipairs(ROWS) do
				out[name] = env.Properties[name]
			end
			return out
		end

		it("hides the 20 rows of a fan with no keypad 8 s after late init, with no Last Action, values kept"
			.. " (KL-D1, KL-D4, KL-D5)", function()
				local env, c4 = rows_driver()
				local before = values(env)
				run(c4, 2000)
				assert.is_true(all_rows(c4, 0), "shown at first: fail open")
				run(c4, 9000)
				local ok, name = all_rows(c4, 1)
				assert.is_true(ok, "hidden: " .. tostring(name))
				assert.are_not.equal(HIDDEN, env.Properties["Last Action"])
				assert.same(before, values(env))
				assert.truthy(env.Properties["Keypad Links"]:find("; LED settings hidden: bind a button to a Fan Speed link",
					1, true))
				assert.is_nil(env.Properties["Keypad Links"]:find(",", 1, true))
			end)

		it("shows them at once when a button is bound to Fan Speed 3 (L44) and hides them 8 s after it is"
			.. " unbound (L45) (KL-D2, KL-D4, KL-D7)", function()
				local env, c4 = rows_driver()
				run(c4, 11000)
				fake.link_keypad(env, 303, 456, 12)
				run(c4, 2000)
				assert.is_true(all_rows(c4, 0), "shown once bound")
				assert.equal(SHOWN, env.Properties["Last Action"])
				assert.truthy(env.Properties["Keypad Links"]:find("; LED settings shown", 1, true))
				fake.unlink_keypad(env, 303, 456, 12)
				run(c4, 5000)
				assert.is_true(all_rows(c4, 0), "still shown 5 s after the unbind")
				-- The links believe the unbind after two empty rereads (6 s, #185), then 8 s (KL-D4).
				run(c4, 10000)
				assert.is_true(all_rows(c4, 1), "hidden once nothing was bound for 8 s")
				assert.equal(HIDDEN, env.Properties["Last Action"])
			end)

		it("keeps them hidden for a keypad on Off only: it takes no colours (KL-D2)", function()
			local env, c4 = rows_driver()
			run(c4, 11000)
			fake.link_keypad(env, 300, 456, 11)
			run(c4, 10000)
			assert.is_true(all_rows(c4, 1))
			assert.are_not.equal(SHOWN, env.Properties["Last Action"])
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

		it("shows Breeze in Fan Model after a restart before the fan answers (#69)", function()
			local env, c4 = online_driver()
			local persisted = {}
			for k, v in pairs(c4.persist) do persisted[k] = v end
			assert.is_true(persisted.mf_wind)
			env.OnDriverDestroyed()
			local env2, c42 = fake.load_driver(DRIVER, { ["Fan Address"] = FAN, ["Fan ID"] = env.Properties["Fan ID"] })
			for k, v in pairs(persisted) do c42.persist[k] = v end
			env2.OnDriverInit("DIT_STARTUP")
			env2.OnDriverLateInit("DIT_STARTUP")
			assert.equal('{"queryStaticShadowData":1}', last_sent(c42), "the fan has not answered yet")
			assert.equal("Gen 3, Aviator 5 (1811-5-54), light kit F4IN-120V-R1-30, Breeze", env2.Properties["Fan Model"])
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

		-- Runs the fake clock 100 ms at a time for `ms`. The fan answers at `o.at`
		-- (MOVED unless given; false: nowhere): a request there gets its answers,
		-- every other request fails. Each search query is answered from o.at by
		-- the fan's announcement there (o.message, K10_MOVED unless given), unless
		-- o.announce is false or the fan is nowhere.
		local function run(env, c4, ms, o)
			o = o or {}
			local at = o.at == nil and MOVED or o.at
			local queries = #c4.calls_to("SendToNetwork")
			for _ = 1, ms / 100 do
				for _, t in ipairs(c4.open_transfers()) do
					if at and t.url:find("//" .. at .. "/", 1, true) then
						if t.data == '{"queryStaticShadowData":1}' then
							t:respond(200, mf.INFO)
						else
							t:respond(200, mf.state({ fanOn = true, fanSpeed = 3 }))
						end
					else
						t:fail(-1, "timeout")
					end
				end
				local now = #c4.calls_to("SendToNetwork")
				if now > queries then
					queries = now
					if at and o.announce ~= false then
						fake.network_receive(env, 6001, 5353, o.message or mdns.K10_MOVED, at)
					end
				end
				c4.advance(100)
			end
		end

		local function queries(c4)
			return #c4.calls_to("SendToNetwork")
		end

		local function set(env, name, value)
			env.Properties[name] = value
			env.OnPropertyChanged(name)
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

		it("does not look while the fan answers (after the search's one window at load)", function()
			local env, c4 = online_driver()
			run(env, c4, 35000, { at = FAN, message = mdns.K10_FIRST })
			local before = queries(c4)
			run(env, c4, 600000, { at = FAN, message = mdns.K10_FIRST })
			assert.equal(before, queries(c4))
			assert.equal(FAN, env.Properties["Fan Address"])
			assert.truthy(env.Properties["Status"]:find("Online", 1, true), env.Properties["Status"])
		end)

		it("an address the owner types wins until the fan answers there; the next loss after that is followed", function()
			local env, c4 = online_driver()
			run(env, c4, 35000, { at = FAN, message = mdns.K10_FIRST }) -- the window at load
			set(env, "Fan Address", MOVED)
			local before = queries(c4)
			run(env, c4, 3600 * 1000, { at = false })
			assert.equal(before, queries(c4), "no window while the typed address has not answered")
			assert.equal(MOVED, env.Properties["Fan Address"])
			run(env, c4, 30000, { at = MOVED, announce = false })
			assert.truthy(env.Properties["Status"]:find("Online", 1, true), env.Properties["Status"])
			-- The fan goes back to the first address and says so there.
			run(env, c4, 300000, { at = FAN, message = mdns.K10_FIRST })
			assert.equal(FAN, env.Properties["Fan Address"])
			assert.equal("Followed fan MF_00005E005301 to " .. FAN .. " (was " .. MOVED .. ")", env.Properties["Last Action"])
		end)

		it("typing back the address the fan was last seen at resumes following (v1-design 3.5)", function()
			local env, c4 = online_driver()
			set(env, "Fan Address", "")
			c4.advance(1000)
			set(env, "Fan Address", FAN)
			run(env, c4, 300000)
			assert.equal(MOVED, env.Properties["Fan Address"])
		end)

		it("typing back the last address after a wrong one ends the wait for the wrong one", function()
			local env, c4 = online_driver()
			set(env, "Fan Address", table.concat({ 10, 0, 2, 99 }, ".")) -- nothing answers there: pending
			c4.advance(1000)
			set(env, "Fan Address", FAN)
			run(env, c4, 300000)
			assert.equal(MOVED, env.Properties["Fan Address"])
		end)

		it("Follow Address Changes switched Off while looking stops the windows, and On starts them again", function()
			local env, c4 = online_driver()
			run(env, c4, 90000, { at = false })
			local armed = queries(c4)
			assert.is_true(armed > 0, "windows while the fan is away")
			set(env, "Follow Address Changes", "Off")
			run(env, c4, 3600 * 1000, { at = false })
			assert.equal(armed, queries(c4), "none while Off")
			set(env, "Follow Address Changes", "On")
			run(env, c4, 40000, { at = false })
			assert.is_true(queries(c4) > armed, "windows again once On")
		end)

		it("a restart while the fan is away still follows it (the replayed Fan Address is no edit)", function()
			local env, c4 = online_driver()
			local persisted = {}
			for k, v in pairs(c4.persist) do persisted[k] = v end
			env.OnDriverDestroyed()
			local env2, c42 = fake.load_driver(DRIVER, { ["Fan Address"] = FAN, ["Fan ID"] = env.Properties["Fan ID"] })
			for k, v in pairs(persisted) do c42.persist[k] = v end
			env2.OnDriverInit("DIT_STARTUP")
			env2.OnDriverLateInit("DIT_STARTUP")
			run(env2, c42, 300000)
			assert.equal(MOVED, env2.Properties["Fan Address"])
		end)

		it("stays at the typed address with Follow Address Changes Off: only the search's window at load", function()
			local env, c4 = online_driver({ ["Follow Address Changes"] = "Off" })
			run(env, c4, 120000)
			assert.equal(FAN, env.Properties["Fan Address"])
			assert.equal(2, #c4.calls_to("SendToNetwork"), "the query and its repeat, at load")
		end)

		it("does not follow a fan whose answer at the new address is another fan", function()
			local env, c4 = online_driver()
			local other = mf.INFO:gsub("00005E005301", "00005E005302")
			local seen = 0
			for _ = 1, 1200 do
				for _, t in ipairs(c4.open_transfers()) do
					if t.url:find("//" .. FAN .. "/", 1, true) then
						t:fail(-1, "timeout")
					elseif t.url:find("//" .. MOVED .. "/", 1, true) then
						t:respond(200, other)
					end
				end
				local now = queries(c4)
				if now > seen then
					seen = now
					fake.network_receive(env, 6001, 5353, mdns.K10_MOVED, MOVED)
				end
				c4.advance(100)
			end
			assert.is_true(seen > 0, "it looked")
			assert.equal(FAN, env.Properties["Fan Address"])
		end)

		it("stops with the driver, also while it is looking", function()
			local env, c4 = online_driver()
			run(env, c4, 90000, { at = false })
			local armed = queries(c4)
			assert.is_true(armed > 0, "windows while the fan is away")
			env.OnDriverDestroyed()
			c4.advance(3600 * 1000)
			assert.equal(armed, queries(c4))
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
