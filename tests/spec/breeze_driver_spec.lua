-- The Modern Forms Breeze companion (docs/breeze-design.md section 4, #111) on
-- the fake runtime: its driver.xml, and the driver alone, bound (or not) to a
-- fan device this harness does not run. The fan device's side is played by
-- the spec: its messages arrive through ExecuteCommand, the companion's go to
-- c4.sent. The checks every driver passes are in drivers_spec.lua; the fan
-- driver's half of the messages is fan_driver_spec's and breeze_spec's.

local fake = require("helpers.fake_c4")
local log = require("common.log")

local DRIVER = "modernforms_breeze"
local SELF, FAN, OTHER_FAN = 2001, 15, 16
local PROXY, FAN_BINDING, PROVIDER_BINDING, CLASS = 5001, 1, 400, "MODERNFORMS_BREEZE"
local UNBOUND = "Not connected to a Modern Forms Fan"

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

local function without_comments(xml)
	return (xml:gsub("<!%-%-.-%-%->", ""))
end

-- The companion on the fake, its binding 1 bound to the fan device FAN's 400
-- (opts.bound false: nothing bound), run through both inits. opts.before(env,
-- c4) runs after the load and before OnDriverInit.
local function companion(opts)
	opts = opts or {}
	local env, c4 = fake.load_driver(DRIVER, opts.properties, { device_id = SELF })
	if opts.bound ~= false then
		c4:Bind(FAN, PROVIDER_BINDING, SELF, FAN_BINDING, CLASS)
	end
	if opts.before then
		opts.before(env, c4)
	end
	env.OnDriverInit("DIT_STARTUP")
	env.OnDriverLateInit("DIT_STARTUP")
	return env, c4
end

-- What the companion sent with SendToDevice, optionally of one command:
-- { id, command, params } each.
local function sent(c4, command)
	local out = {}
	for _, m in ipairs(c4.sent) do
		if command == nil or m.command == command then
			out[#out + 1] = m
		end
	end
	return out
end

-- The notifications the light_v2 proxy got, of one command: the field `key`
-- of each (false kept as false), or the whole parameters.
local function notified(c4, command, key)
	local out = {}
	for _, m in ipairs(c4.proxy_messages(PROXY)) do
		if m[1] == command then
			if key then
				out[#out + 1] = m[2][key]
			else
				out[#out + 1] = m[2]
			end
		end
	end
	return out
end

-- The tile's two notifications in the order sent: "level 100", "online true".
local function tile_trace(c4)
	local out = {}
	for _, m in ipairs(c4.proxy_messages(PROXY)) do
		if m[1] == "LIGHT_BRIGHTNESS_CHANGED" then
			out[#out + 1] = "level " .. tostring(m[2].LIGHT_BRIGHTNESS_CURRENT)
		elseif m[1] == "ONLINE_CHANGED" then
			out[#out + 1] = "online " .. tostring(m[2].STATE)
		end
	end
	return out
end

-- The fan device's MF_BREEZE_STATE, as Director hands it over (strings).
local function state(env, blows, available, fan, extra)
	local params = { BLOWS = blows, AVAILABLE = available, FAN = fan }
	for k, v in pairs(extra or {}) do
		params[k] = v
	end
	env.ExecuteCommand("MF_BREEZE_STATE", params)
end

local function tap(env, command, params)
	env.ReceivedFromProxy(PROXY, command, params or {})
end

-- The UTF-8 characters of a string; raises on a broken sequence.
local function utf8_chars(text)
	local n, i = 0, 1
	while i <= #text do
		local b = text:byte(i)
		local len = b < 0x80 and 1 or b >= 0xF0 and 4 or b >= 0xE0 and 3 or b >= 0xC2 and 2 or nil
		assert(len, "a broken UTF-8 lead byte at " .. i)
		for j = i + 1, i + len - 1 do
			local c = text:byte(j)
			assert(c and c >= 0x80 and c < 0xC0, "a broken UTF-8 sequence at " .. i)
		end
		n, i = n + 1, i + len
	end
	return n
end

describe("Modern Forms Breeze companion", function()
	before_each(quiet)
	after_each(function()
		log.set_debug(false)
		log.set_prefix(nil)
	end)

	describe("driver.xml", function()
		local bare = without_comments(read("src/" .. DRIVER .. "/driver.xml"))
		local fan_bare = without_comments(read("src/modernforms_fan/driver.xml"))

		it("names the driver and takes the fan driver's maker, creator and minimum OS", function()
			assert.equal("Modern Forms Breeze", field(bare, "name"))
			for _, tag in ipairs({ "manufacturer", "creator", "minimum_os_version", "control", "driver" }) do
				assert.equal(field(fan_bare, tag), field(bare, tag), tag)
			end
			assert.equal("3.3.0", field(bare, "minimum_os_version"))
			for _, tag in ipairs({ "combo", "replaces", "auto_update" }) do
				assert.is_nil(bare:find("<" .. tag, 1, true), tag)
			end
		end)

		it("declares one light_v2 proxy on 5001, Modern Forms Breeze, with its own icons in the package", function()
			local proxies = {}
			for attrs, kind in bare:gmatch("<proxy ([^>]-)>(.-)</proxy>") do
				proxies[#proxies + 1] = { attrs = attrs, kind = kind }
			end
			assert.equal(1, #proxies)
			assert.equal("light_v2", proxies[1].kind)
			local attrs = proxies[1].attrs
			assert.truthy(attrs:find('proxybindingid="5001"', 1, true))
			assert.truthy(attrs:find('name="Modern Forms Breeze"', 1, true))
			assert.truthy(attrs:find('image_source="c4z"', 1, true))
			assert.truthy(attrs:find('small_image="images/devices_sm/modernforms_breeze_16.png"', 1, true))
			assert.truthy(attrs:find('large_image="images/devices_lg/modernforms_breeze_32.png"', 1, true))
			assert.truthy(bare:find('<small image_source="c4z">images/devices_sm/modernforms_breeze_16.png</small>', 1,
				true))
			assert.truthy(bare:find('<large image_source="c4z">images/devices_lg/modernforms_breeze_32.png</large>', 1,
				true))
			for path in bare:gmatch('(images/[%w_/]+%.png)') do
				local f = io.open("src/" .. DRIVER .. "/www/" .. path, "rb")
				assert.truthy(f, path .. " is in the package")
				if f then f:close() end
			end
		end)

		it("is an on/off switch: no dimming, no LEDs, no Advanced Lighting Scenes", function()
			local caps = field(bare, "capabilities")
			local want = {
				dimmer = "False", set_level = "False", ramp_level = "False", on_off = "True", has_leds = "False",
				hold_rates = "False", click_rates = "False", supports_target = "True", reduced_als_support = "False",
				advanced_scene_support = "False", supports_color = "False",
				supports_color_correlated_temperature = "False",
			}
			for tag, value in pairs(want) do
				assert.equal(value, field(caps, tag), tag)
			end
		end)

		it("declares the proxy binding and the consumer binding 1 to the fan's Breeze Switch, and no Button Link", function()
			local ids = {}
			for body in bare:gmatch("<connection>(.-)</connection>") do
				ids[#ids + 1] = field(body, "id") .. ":" .. field(body, "classname")
				if field(body, "id") == "1" then
					assert.equal("Modern Forms Fan", field(body, "connectionname"))
					assert.equal("1", field(body, "type"))
					assert.equal("True", field(body, "consumer"))
				elseif field(body, "id") == "5001" then
					assert.equal("2", field(body, "type"))
					assert.equal("False", field(body, "consumer"))
				end
			end
			assert.same({ "5001:LIGHT_V2", "1:MODERNFORMS_BREEZE" }, ids)
			-- The fan driver's provider end carries the same class.
			local provider = nil
			for body in fan_bare:gmatch("<connection>(.-)</connection>") do
				if field(body, "id") == tostring(PROVIDER_BINDING) then provider = body end
			end
			assert.truthy(provider, "the fan driver declares its binding 400")
			assert.equal(CLASS, field(provider, "classname"))
			assert.equal("False", field(provider, "consumer"))
		end)

		it("has the three rows in order, no actions, no commands, no events", function()
			local names = {}
			for body in bare:gmatch("<property>(.-)</property>") do
				names[#names + 1] = field(body, "name")
			end
			assert.same({ "Driver Version", "Status", "Debug Mode" }, names)
			assert.is_nil(bare:find("<action>", 1, true))
			assert.is_nil(bare:find("<command>", 1, true))
			assert.is_nil(bare:find("<event>", 1, true))
		end)
	end)

	describe("at late init", function()
		it("says hello to the bound fan device, and nothing else, and waits for its state", function()
			local env, c4 = companion()
			assert.same({ { id = FAN, command = "MF_BREEZE_HELLO", params = {} } }, sent(c4))
			assert.equal("Waiting for the fan", env.Properties["Status"])
			assert.same({}, tile_trace(c4), "the proxy keeps what it has until the fan device has said")
			assert.same({}, c4.active_timers())
		end)

		it("unbound: says so, takes the tile offline, sends nothing and looks for the binding again", function()
			local env, c4 = companion({ bound = false })
			assert.equal(UNBOUND, env.Properties["Status"])
			assert.same({ "online false" }, tile_trace(c4))
			assert.same({}, sent(c4))
			assert.equal(1, #c4.active_timers())
		end)

		it("takes the number 0 for unbound, as OS 3.4.2 answers it", function()
			local env, c4 = companion({
				bound = false,
				before = function(_, c4)
					c4.GetBoundProviderDevice = function() return 0 end
				end,
			})
			assert.equal(UNBOUND, env.Properties["Status"])
			assert.same({}, sent(c4))
		end)

		it("reads the documented table of id and name too", function()
			local _, c4 = companion({
				bound = false,
				before = function(_, c4)
					c4.GetBoundProviderDevice = function() return { [FAN] = "Modern Forms Fan" } end
				end,
			})
			assert.same({ "MF_BREEZE_HELLO" }, { sent(c4)[1].command })
			assert.equal(FAN, sent(c4)[1].id)
		end)

		it("finds a binding Director shows late, then greets that fan device", function()
			local env, c4 = companion({ bound = false })
			c4.advance(4000)
			c4:Bind(FAN, PROVIDER_BINDING, SELF, FAN_BINDING, CLASS) -- no OnBindingChanged follows
			c4.advance(1000)
			assert.same({ "MF_BREEZE_HELLO" }, { sent(c4)[1].command })
			assert.equal("Waiting for the fan", env.Properties["Status"])
			assert.same({}, c4.active_timers())
		end)

		it("stops looking 60 s after the start", function()
			local lines = capture_log()
			local _, c4 = companion({ bound = false })
			c4.advance(59000)
			assert.equal(1, #c4.active_timers())
			c4.advance(2000)
			assert.same({}, c4.active_timers())
			local said = false
			for _, line in ipairs(lines) do
				said = said or line:find("waiting for a binding", 1, true) ~= nil
			end
			assert.is_false(said, "an info line, silent without Debug Mode")
			assert.same({}, sent(c4))
		end)

		it("applies a state that came before late init, then says hello", function()
			local env, c4 = fake.load_driver(DRIVER, nil, { device_id = SELF })
			c4:Bind(FAN, PROVIDER_BINDING, SELF, FAN_BINDING, CLASS)
			env.OnDriverInit("DIT_STARTUP")
			state(env, "1", "1", "Aviator 5")
			assert.same({}, c4.proxy_messages(PROXY), "nothing reaches the proxy before late init")
			env.OnDriverLateInit("DIT_STARTUP")
			assert.same({ "online true", "level 100" }, tile_trace(c4))
			assert.equal("Breeze on Aviator 5", env.Properties["Status"])
			assert.same({ "MF_BREEZE_HELLO" }, { sent(c4)[1].command })
		end)
	end)

	describe("the fan device's state", function()
		it("lights the tile while Breeze blows and puts it online, once per change", function()
			local env, c4 = companion()
			state(env, "1", "1", "Aviator 5")
			assert.same({ "online true", "level 100" }, tile_trace(c4))
			assert.equal("Breeze on Aviator 5", env.Properties["Status"])
			state(env, "1", "1", "Aviator 5")
			assert.same({ "online true", "level 100" }, tile_trace(c4), "the same state again tells the proxy nothing")
			state(env, "0", "1", "Aviator 5")
			assert.same({ "online true", "level 100", "level 0" }, tile_trace(c4))
			assert.equal("Breeze off on Aviator 5", env.Properties["Status"])
			state(env, "0", "1", "Aviator 5")
			assert.same({ 100, 0 }, notified(c4, "LIGHT_BRIGHTNESS_CHANGED", "LIGHT_BRIGHTNESS_CURRENT"))
		end)

		it("reports off at the first state when Breeze does not blow", function()
			local env, c4 = companion()
			state(env, "0", "1", "Aviator 5")
			assert.same({ "online true", "level 0" }, tile_trace(c4))
		end)

		it("takes the tile offline on AVAILABLE 0 and says it waits for the fan", function()
			local env, c4 = companion()
			state(env, "1", "1", "Aviator 5")
			state(env, "1", "0", "Aviator 5")
			assert.same({ "online true", "level 100", "online false" }, tile_trace(c4))
			assert.equal("Waiting for Aviator 5", env.Properties["Status"])
		end)

		it("says the fan has no Breeze when the fan device says so (HAS_BREEZE 0)", function()
			local env, c4 = companion()
			state(env, "0", "0", "Aviator 5", { HAS_BREEZE = "0" })
			assert.same({ "level 0", "online false" }, tile_trace(c4))
			assert.equal("Aviator 5 has no Breeze", env.Properties["Status"])
			state(env, "0", "0", "Aviator 5", { HAS_BREEZE = "1" })
			assert.equal("Waiting for Aviator 5", env.Properties["Status"])
		end)

		it("puts the tile online again and tells its level again when the fan comes back", function()
			local env, c4 = companion()
			state(env, "1", "1", "Aviator 5")
			state(env, "1", "0", "Aviator 5")
			state(env, "1", "1", "Aviator 5")
			assert.same({ "online true", "level 100", "online false", "online true", "level 100" }, tile_trace(c4))
		end)

		it("sends ONLINE_CHANGED as a boolean and the level as a whole percent", function()
			local env, c4 = companion()
			state(env, "1", "1", "Aviator 5")
			assert.same({ true }, notified(c4, "ONLINE_CHANGED", "STATE"))
			assert.same({ { LIGHT_BRIGHTNESS_CURRENT = 100 } }, notified(c4, "LIGHT_BRIGHTNESS_CHANGED"))
		end)

		it("answers SYNCHRONIZE with what it has, again", function()
			local env, c4 = companion()
			tap(env, "SYNCHRONIZE")
			assert.same({}, tile_trace(c4), "nothing known yet: nothing said")
			state(env, "1", "1", "Aviator 5")
			tap(env, "SYNCHRONIZE")
			assert.same({ "online true", "level 100", "online true", "level 100" }, tile_trace(c4))
		end)

		it("names the fan as sent, cut so Status stays at 70 characters", function()
			local env = companion()
			state(env, "1", "1", string.rep("x", 100))
			local status = env.Properties["Status"]
			assert.equal(70, #status)
			assert.equal("Breeze on " .. string.rep("x", 57) .. "...", status)
			state(env, "0", "1", string.rep("\195\132", 80)) -- "Ä" 80 times
			status = env.Properties["Status"]
			assert.equal(70, utf8_chars(status))
			assert.truthy(status:find("^Breeze off on \195\132"))
			assert.truthy(status:find("%.%.%.$"))
			state(env, "0", "1", "Aviator\n5\t")
			assert.equal("Breeze off on Aviator5", env.Properties["Status"])
			state(env, "0", "1", nil)
			assert.equal("Breeze off on the fan", env.Properties["Status"])
		end)

		it("ignores a state without BLOWS or AVAILABLE, with a warning", function()
			local lines = capture_log()
			local env, c4 = companion()
			state(env, nil, "1", "Aviator 5")
			state(env, "1", "maybe", "Aviator 5")
			assert.same({}, tile_trace(c4))
			assert.equal("Waiting for the fan", env.Properties["Status"])
			local warned = 0
			for _, line in ipairs(lines) do
				if line:find("^%[WARN%] Modern Forms Breeze: MF_BREEZE_STATE ignored") then warned = warned + 1 end
			end
			assert.equal(2, warned)
		end)
	end)

	describe("the tile", function()
		it("turns Breeze on and off through the fan device, and reports nothing until it confirms", function()
			local env, c4 = companion()
			state(env, "0", "1", "Aviator 5")
			local before = #c4.proxy_messages(PROXY)
			tap(env, "ON")
			assert.same({ id = FAN, command = "MF_BREEZE_SET", params = { ON = "1" } }, sent(c4)[2])
			assert.equal(before, #c4.proxy_messages(PROXY), "no optimistic report")
			assert.equal("Breeze off on Aviator 5", env.Properties["Status"])
			state(env, "1", "1", "Aviator 5")
			assert.same({ 0, 100 }, notified(c4, "LIGHT_BRIGHTNESS_CHANGED", "LIGHT_BRIGHTNESS_CURRENT"))
			tap(env, "OFF")
			assert.same({ id = FAN, command = "MF_BREEZE_SET", params = { ON = "0" } }, sent(c4)[3])
			assert.same({ 0, 100 }, notified(c4, "LIGHT_BRIGHTNESS_CHANGED", "LIGHT_BRIGHTNESS_CURRENT"))
		end)

		it("toggles from the state the fan device confirmed", function()
			local env, c4 = companion()
			state(env, "0", "1", "Aviator 5")
			tap(env, "TOGGLE")
			tap(env, "TOGGLE")
			assert.same({ "1", "1" }, { sent(c4, "MF_BREEZE_SET")[1].params.ON, sent(c4, "MF_BREEZE_SET")[2].params.ON },
				"two taps before the fan confirms both ask for on")
			state(env, "1", "1", "Aviator 5")
			tap(env, "TOGGLE")
			assert.equal("0", sent(c4, "MF_BREEZE_SET")[3].params.ON)
		end)

		it("leaves a toggle to the fan device while it has not said", function()
			local env, c4 = companion()
			tap(env, "TOGGLE")
			assert.same({ id = FAN, command = "MF_BREEZE_TOGGLE", params = {} }, sent(c4)[2])
			assert.same({}, sent(c4, "MF_BREEZE_SET"))
		end)

		it("takes any level above 0 as on and 0 as off", function()
			local env, c4 = companion()
			state(env, "0", "1", "Aviator 5")
			tap(env, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "100", RATE = "0" })
			tap(env, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "37", RATE = "500" })
			tap(env, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "0", RATE = "0" })
			tap(env, "SET_LEVEL", { LEVEL = "1" })
			tap(env, "RAMP_TO_LEVEL", { LEVEL = "0", TIME = "1000" })
			tap(env, "SET_BRIGHTNESS_TARGET", {})
			local ons = {}
			for _, m in ipairs(sent(c4, "MF_BREEZE_SET")) do ons[#ons + 1] = m.params.ON end
			assert.same({ "1", "1", "0", "1", "0" }, ons)
			assert.same({ 0 }, notified(c4, "LIGHT_BRIGHTNESS_CHANGED", "LIGHT_BRIGHTNESS_CURRENT"))
		end)

		it("passes a tap on to a fan device that says it is not available, which refuses it itself", function()
			local env, c4 = companion()
			state(env, "0", "0", "Aviator 5")
			tap(env, "ON")
			assert.same({ ON = "1" }, sent(c4, "MF_BREEZE_SET")[1].params)
		end)

		it("takes the proxy's button route: top on, bottom off, toggle toggles", function()
			local env, c4 = companion()
			state(env, "1", "1", "Aviator 5")
			for _, button in ipairs({ "0", "1", "2" }) do
				tap(env, "BUTTON_ACTION", { BUTTON_ID = button, ACTION = "1" })
				tap(env, "BUTTON_ACTION", { BUTTON_ID = button, ACTION = "2" })
			end
			local ons = {}
			for _, m in ipairs(sent(c4, "MF_BREEZE_SET")) do ons[#ons + 1] = m.params.ON end
			assert.same({ "1", "0", "0" }, ons)
			env.OnDriverDestroyed("DIT_UPDATING")
			assert.same({}, c4.active_timers())
		end)

		it("unbound: refuses every command, sends nothing, and Status says why", function()
			local lines = capture_log()
			local env, c4 = companion({ bound = false })
			for _, command in ipairs({ "ON", "OFF", "TOGGLE" }) do
				tap(env, command)
			end
			tap(env, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "100" })
			assert.same({}, sent(c4))
			assert.equal(UNBOUND, env.Properties["Status"])
			local refused = {}
			for _, line in ipairs(lines) do
				local command = line:match("^%[WARN%] Modern Forms Breeze: (%S+) refused: not connected to a Modern Forms Fan$")
				if command then refused[#refused + 1] = command end
			end
			assert.same({ "ON", "OFF", "TOGGLE", "SET_BRIGHTNESS_TARGET" }, refused)
			assert.same({ "online false" }, tile_trace(c4))
		end)

		it("waits for late init with a command that comes first", function()
			local env, c4 = fake.load_driver(DRIVER, nil, { device_id = SELF })
			c4:Bind(FAN, PROVIDER_BINDING, SELF, FAN_BINDING, CLASS)
			env.OnDriverInit("DIT_STARTUP")
			tap(env, "ON")
			assert.same({}, sent(c4))
			env.OnDriverLateInit("DIT_STARTUP")
			assert.same({ "MF_BREEZE_SET", "MF_BREEZE_HELLO" }, { sent(c4)[1].command, sent(c4)[2].command })
		end)
	end)

	describe("the binding", function()
		it("unbound in Connections: offline, Status says so, then a tap and a late state do nothing", function()
			local env, c4 = companion()
			state(env, "1", "1", "Aviator 5")
			c4:Unbind(SELF, FAN_BINDING)
			env.OnBindingChanged(FAN_BINDING, CLASS, false, FAN, PROVIDER_BINDING)
			assert.equal(UNBOUND, env.Properties["Status"])
			assert.same({ "online true", "level 100", "online false" }, tile_trace(c4))
			local count = #c4.sent
			tap(env, "OFF")
			state(env, "0", "1", "Aviator 5")
			assert.equal(count, #c4.sent)
			assert.equal(UNBOUND, env.Properties["Status"])
			assert.same({ "online true", "level 100", "online false" }, tile_trace(c4))
		end)

		it("bound in Connections: says hello to the new fan device and waits for its state", function()
			local env, c4 = companion({ bound = false })
			c4:Bind(FAN, PROVIDER_BINDING, SELF, FAN_BINDING, CLASS)
			env.OnBindingChanged(FAN_BINDING, CLASS, true, FAN, PROVIDER_BINDING)
			assert.same({ { id = FAN, command = "MF_BREEZE_HELLO", params = {} } }, sent(c4))
			assert.equal("Waiting for the fan", env.Properties["Status"])
			assert.same({}, c4.active_timers(), "the re-check ends with the binding")
			state(env, "1", "1", "Aviator 5")
			assert.same({ "online false", "online true", "level 100" }, tile_trace(c4))
		end)

		it("takes the device OnBindingChanged names while Director's lookup does not show it yet", function()
			local env, c4 = companion({ bound = false })
			env.OnBindingChanged(FAN_BINDING, CLASS, true, FAN, PROVIDER_BINDING)
			assert.same({ { id = FAN, command = "MF_BREEZE_HELLO", params = {} } }, sent(c4))
		end)

		it("moved to another fan device: forgets the old state and greets the new one", function()
			local env, c4 = companion()
			state(env, "1", "1", "Aviator 5")
			c4:Unbind(SELF, FAN_BINDING)
			c4:Bind(OTHER_FAN, PROVIDER_BINDING, SELF, FAN_BINDING, CLASS)
			env.OnBindingChanged(FAN_BINDING, CLASS, true, OTHER_FAN, PROVIDER_BINDING)
			assert.same({ id = OTHER_FAN, command = "MF_BREEZE_HELLO", params = {} }, sent(c4)[#c4.sent])
			assert.equal("Waiting for the fan", env.Properties["Status"])
			tap(env, "TOGGLE")
			assert.same({ id = OTHER_FAN, command = "MF_BREEZE_TOGGLE", params = {} }, sent(c4)[#c4.sent])
		end)

		it("ignores bindings other than the fan's", function()
			local env, c4 = companion()
			env.OnBindingChanged(PROXY, "LIGHT_V2", false, 3001, PROXY)
			assert.equal("Waiting for the fan", env.Properties["Status"])
			assert.equal(1, #c4.sent)
		end)

		it("a binding change before late init is applied after it", function()
			local env, c4 = fake.load_driver(DRIVER, nil, { device_id = SELF })
			env.OnDriverInit("DIT_STARTUP")
			c4:Bind(FAN, PROVIDER_BINDING, SELF, FAN_BINDING, CLASS)
			env.OnBindingChanged(FAN_BINDING, CLASS, true, FAN, PROVIDER_BINDING)
			assert.same({}, sent(c4))
			assert.same({}, c4.calls_to("UpdateProperty"))
			env.OnDriverLateInit("DIT_STARTUP")
			assert.equal("Waiting for the fan", env.Properties["Status"])
			for _, m in ipairs(sent(c4)) do
				assert.equal(FAN, m.id)
				assert.equal("MF_BREEZE_HELLO", m.command)
			end
		end)

		it("a state from a fan device while unbound is taken once Director shows the binding", function()
			local env, c4 = companion({ bound = false })
			c4:Bind(FAN, PROVIDER_BINDING, SELF, FAN_BINDING, CLASS) -- the state comes before OnBindingChanged
			state(env, "1", "1", "Aviator 5")
			assert.equal("Breeze on Aviator 5", env.Properties["Status"])
			assert.same({ "MF_BREEZE_HELLO" }, { sent(c4)[1].command })
			assert.same({ "online false", "online true", "level 100" }, tile_trace(c4))
		end)
	end)

	it("stops every timer of its own when destroyed", function()
		local env, c4 = companion({ bound = false })
		assert.equal(1, #c4.active_timers())
		env.OnDriverDestroyed("DIT_UPDATING")
		assert.same({}, c4.active_timers())
	end)
end)
