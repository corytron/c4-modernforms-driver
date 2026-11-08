-- The Modern Forms Breeze Fan (docs/breeze-design.md section 11, BF-D7 and
-- BF-D8, #121) on the fake runtime: its driver.xml, and the driver alone,
-- bound (or not) to a fan device this harness does not run. The fan device's
-- side is played by the spec: its messages arrive through ExecuteCommand, the
-- Breeze fan's go to c4.sent. The checks every driver passes are in
-- drivers_spec.lua; the fan driver's half of the messages, and the two
-- drivers paired, are fan_driver_spec's and breeze_spec's.

local fake = require("helpers.fake_c4")
local log = require("common.log")

local DRIVER = "modernforms_breeze_fan"
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

local function logged(lines, pattern)
	for _, line in ipairs(lines) do
		if line:find(pattern) then
			return true
		end
	end
	return false
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

-- The Breeze fan on the fake, its binding 1 bound to the fan device FAN's 400
-- (opts.bound false: nothing bound), run through both inits. opts.before(env,
-- c4) runs after the load and before OnDriverInit.
local function breeze_fan(opts)
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

-- What the Breeze fan sent with SendToDevice, optionally of one command:
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

local function last_sent(c4)
	return c4.sent[#c4.sent]
end

-- The SPEED of every CURRENT_SPEED the fan proxy got, in order.
local function speeds(c4)
	local out = {}
	for _, m in ipairs(c4.proxy_messages(PROXY)) do
		if m[1] == "CURRENT_SPEED" then
			out[#out + 1] = m[2].SPEED
		end
	end
	return out
end

-- Every command the fan proxy got, in order.
local function proxy_commands(c4)
	local out = {}
	for _, m in ipairs(c4.proxy_messages(PROXY)) do
		out[#out + 1] = m[1]
	end
	return out
end

-- The fan device's MF_BREEZE_STATE, as Director hands it over (strings; an
-- absent STRENGTH stays absent, as C4:SendToDevice drops an empty value).
local function state(env, blows, available, fan, extra)
	local params = { BLOWS = blows, AVAILABLE = available, FAN = fan }
	for k, v in pairs(extra or {}) do
		params[k] = v
	end
	env.ExecuteCommand("MF_BREEZE_STATE", params)
end

-- Breeze mode at strength `n` on "Aviator 5".
local function blowing(env, n)
	state(env, "1", "1", "Aviator 5", { HAS_BREEZE = "1", STRENGTH = tostring(n) })
end

-- Not in Breeze mode (stopped or fan mode); the strength the fan keeps.
local function not_blowing(env, n)
	state(env, "0", "1", "Aviator 5", { HAS_BREEZE = "1", STRENGTH = n and tostring(n) or nil })
end

-- The fan device unavailable (offline, not set up): the last state it knew.
local function away(env, blows, n)
	state(env, blows, "0", "Aviator 5", { HAS_BREEZE = "1", STRENGTH = n and tostring(n) or nil })
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

describe("Modern Forms Breeze Fan", function()
	before_each(quiet)
	after_each(function()
		log.set_debug(false)
		log.set_prefix(nil)
	end)

	describe("driver.xml", function()
		local bare = without_comments(read("src/" .. DRIVER .. "/driver.xml"))
		local fan_bare = without_comments(read("src/modernforms_fan/driver.xml"))

		it("names the driver and takes the fan driver's maker, creator and minimum OS", function()
			assert.equal("Modern Forms Breeze Fan", field(bare, "name"))
			-- Read raw too, as the fake's project model and a quick regex read it:
			-- no comment may hold a tag that comes first.
			assert.equal("Modern Forms Breeze Fan", field(read("src/" .. DRIVER .. "/driver.xml"), "name"))
			for _, tag in ipairs({ "manufacturer", "creator", "minimum_os_version", "control", "driver" }) do
				assert.equal(field(fan_bare, tag), field(bare, tag), tag)
			end
			assert.equal("Modern Forms", field(bare, "manufacturer"))
			assert.equal("3.3.0", field(bare, "minimum_os_version"))
			for _, tag in ipairs({ "combo", "replaces", "auto_update" }) do
				assert.is_nil(bare:find("<" .. tag, 1, true), tag)
			end
		end)

		it("declares one fan proxy on 5001, Modern Forms Breeze, primary, with its own icons in the package", function()
			local proxies = {}
			for attrs, kind in bare:gmatch("<proxy ([^>]-)>(.-)</proxy>") do
				proxies[#proxies + 1] = { attrs = attrs, kind = kind }
			end
			assert.equal(1, #proxies)
			assert.equal("fan", proxies[1].kind)
			local attrs = proxies[1].attrs
			assert.truthy(attrs:find('proxybindingid="5001"', 1, true))
			assert.truthy(attrs:find('name="Modern Forms Breeze"', 1, true))
			assert.truthy(attrs:find('primary="True"', 1, true))
			assert.truthy(attrs:find('image_source="c4z"', 1, true))
			assert.truthy(attrs:find('small_image="images/devices_sm/modernforms_breeze_fan_16.png"', 1, true))
			assert.truthy(attrs:find('large_image="images/devices_lg/modernforms_breeze_fan_32.png"', 1, true))
			assert.truthy(bare:find('<small image_source="c4z">images/devices_sm/modernforms_breeze_fan_16.png</small>',
				1, true))
			assert.truthy(bare:find('<large image_source="c4z">images/devices_lg/modernforms_breeze_fan_32.png</large>',
				1, true))
			for path in bare:gmatch('(images/[%w_/]+%.png)') do
				local f = io.open("src/" .. DRIVER .. "/www/" .. path, "rb")
				assert.truthy(f, path .. " is in the package")
				if f then f:close() end
			end
		end)

		it("has three speeds Breeze 1 to 3, no preset to set, no direction, no proxy speed links, no light", function()
			local caps = field(bare, "capabilities")
			local found = {}
			for tag, value in caps:gmatch("<([%w_]+)>(.-)</%1>") do
				found[tag] = value
			end
			assert.same({
				discrete_levels = "3",
				speed_names = "Breeze 1,Breeze 2,Breeze 3",
				preset_speed = "3",
				can_set_preset = "False",
				can_reverse = "False",
			}, found)
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
			assert.same({ "5001:FAN", "1:MODERNFORMS_BREEZE" }, ids)
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
			local env, c4 = breeze_fan()
			assert.same({ { id = FAN, command = "MF_BREEZE_HELLO", params = {} } }, sent(c4))
			assert.equal("Waiting for the fan", env.Properties["Status"])
			assert.same({}, c4.proxy_messages(PROXY), "the proxy keeps what it has until the fan device has said")
			assert.same({}, c4.active_timers())
		end)

		it("unbound: says so and sends nothing, keeps the tile while it looks for the binding, then shows 0", function()
			local env, c4 = breeze_fan({ bound = false })
			assert.equal(UNBOUND, env.Properties["Status"])
			assert.same({}, sent(c4))
			assert.same({}, c4.proxy_messages(PROXY), "a binding Director shows late must not drop the tile to 0")
			assert.equal(1, #c4.active_timers())
			c4.advance(59000)
			assert.same({}, speeds(c4))
			c4.advance(2000)
			assert.same({ 0 }, speeds(c4))
			assert.same({}, c4.active_timers())
			assert.same({}, sent(c4))
		end)

		it("takes the number 0 for unbound, as OS 3.4.2 answers it", function()
			local env, c4 = breeze_fan({
				bound = false,
				before = function(_, c4)
					c4.GetBoundProviderDevice = function() return 0 end
				end,
			})
			assert.equal(UNBOUND, env.Properties["Status"])
			assert.same({}, sent(c4))
		end)

		it("reads the documented table of id and name too", function()
			local _, c4 = breeze_fan({
				bound = false,
				before = function(_, c4)
					c4.GetBoundProviderDevice = function() return { [FAN] = "Modern Forms Fan" } end
				end,
			})
			assert.same({ { id = FAN, command = "MF_BREEZE_HELLO", params = {} } }, sent(c4))
		end)

		it("finds a binding Director shows late, then greets that fan device and never showed 0", function()
			local env, c4 = breeze_fan({ bound = false })
			c4.advance(4000)
			c4:Bind(FAN, PROVIDER_BINDING, SELF, FAN_BINDING, CLASS) -- no OnBindingChanged follows
			c4.advance(1000)
			assert.same({ { id = FAN, command = "MF_BREEZE_HELLO", params = {} } }, sent(c4))
			assert.equal("Waiting for the fan", env.Properties["Status"])
			assert.same({}, c4.active_timers())
			blowing(env, 2)
			assert.same({ 2 }, speeds(c4))
		end)

		it("stops looking 60 s after the start, with an info line only", function()
			local lines = capture_log()
			local _, c4 = breeze_fan({ bound = false })
			c4.advance(61000)
			assert.same({}, c4.active_timers())
			assert.is_false(logged(lines, "waiting for a binding"), "an info line, silent without Debug Mode")
		end)

		it("applies a state that came before late init, then says hello", function()
			local env, c4 = fake.load_driver(DRIVER, nil, { device_id = SELF })
			c4:Bind(FAN, PROVIDER_BINDING, SELF, FAN_BINDING, CLASS)
			env.OnDriverInit("DIT_STARTUP")
			blowing(env, 3)
			assert.same({}, c4.proxy_messages(PROXY), "nothing reaches the proxy before late init")
			env.OnDriverLateInit("DIT_STARTUP")
			assert.same({ 3 }, speeds(c4))
			assert.equal("Breeze 3 on Aviator 5", env.Properties["Status"])
			assert.same({ "MF_BREEZE_HELLO" }, { sent(c4)[1].command })
		end)

		it("tells the proxy the state again after a restart, even when unchanged", function()
			local env, c4 = breeze_fan()
			blowing(env, 2)
			env.OnDriverLateInit("DIT_STARTUP")
			blowing(env, 2)
			assert.same({ 2, 2 }, speeds(c4))
		end)
	end)

	describe("the fan device's state", function()
		it("shows the strength in Breeze mode and 0 otherwise, once per change", function()
			local env, c4 = breeze_fan()
			blowing(env, 2)
			assert.same({ 2 }, speeds(c4))
			assert.equal("Breeze 2 on Aviator 5", env.Properties["Status"])
			blowing(env, 2)
			assert.same({ 2 }, speeds(c4), "the same state again tells the proxy nothing")
			blowing(env, 3)
			assert.same({ 2, 3 }, speeds(c4), "a strength changed in the app or with the remote (BF43)")
			assert.equal("Breeze 3 on Aviator 5", env.Properties["Status"])
			not_blowing(env, 3)
			assert.same({ 2, 3, 0 }, speeds(c4))
			assert.equal("Breeze off on Aviator 5", env.Properties["Status"])
			not_blowing(env, 1)
			assert.same({ 2, 3, 0 }, speeds(c4), "the kept strength means nothing while Breeze is off (BF44)")
		end)

		it("reports 0 at the first state when Breeze does not blow", function()
			local env, c4 = breeze_fan()
			not_blowing(env, 2)
			assert.same({ 0 }, speeds(c4))
		end)

		it("sends CURRENT_SPEED as a NOTIFY with a whole number, and never ON, OFF or ONLINE_CHANGED", function()
			local env, c4 = breeze_fan()
			blowing(env, 1)
			not_blowing(env)
			away(env, "0")
			state(env, "0", "0", "Aviator 5", { HAS_BREEZE = "0" })
			blowing(env, 3)
			tap(env, "GET_CURRENT_STATE")
			tap(env, "ON")
			blowing(env, 3)
			c4:Unbind(SELF, FAN_BINDING)
			env.OnBindingChanged(FAN_BINDING, CLASS, false, FAN, PROVIDER_BINDING)
			for _, m in ipairs(c4.proxy_messages(PROXY)) do
				assert.equal("NOTIFY", m[3])
				assert.equal("number", type(m[2].SPEED))
			end
			assert.same({ 1, 0, 3, 3, 3, 0 }, speeds(c4))
			assert.same({ "CURRENT_SPEED", "CURRENT_SPEED", "CURRENT_SPEED", "CURRENT_SPEED", "CURRENT_SPEED",
				"CURRENT_SPEED" }, proxy_commands(c4))
		end)

		it("keeps the last value while Breeze blows at a strength the fan device does not know", function()
			local lines = capture_log()
			local env, c4 = breeze_fan()
			blowing(env, 2)
			state(env, "1", "1", "Aviator 5", { HAS_BREEZE = "1" })
			assert.same({ 2 }, speeds(c4), "STRENGTH absent is unknown, not 0 and not a guess")
			assert.equal("Breeze on Aviator 5", env.Properties["Status"])
			blowing(env, 2)
			assert.same({ 2 }, speeds(c4))
			state(env, "1", "1", "Aviator 5", { HAS_BREEZE = "1", STRENGTH = "5" })
			assert.same({ 2 }, speeds(c4), "a STRENGTH outside 1 to 3 is unknown too")
			assert.truthy(logged(lines, "^%[WARN%] Modern Forms Breeze Fan: MF_BREEZE_STATE: STRENGTH 5"))
			not_blowing(env)
			assert.same({ 2, 0 }, speeds(c4), "off needs no strength")
		end)

		it("says nothing at all at a first state that blows at an unknown strength", function()
			local env, c4 = breeze_fan()
			state(env, "1", "1", "Aviator 5", { HAS_BREEZE = "1" })
			assert.same({}, c4.proxy_messages(PROXY))
			assert.equal("Breeze on Aviator 5", env.Properties["Status"])
		end)

		it("keeps the last value while the fan device is unavailable, whatever that state says", function()
			local env, c4 = breeze_fan()
			blowing(env, 2)
			away(env, "1", 2)
			away(env, "0")
			away(env, "1")
			assert.same({ 2 }, speeds(c4), "a fan proxy cannot go offline: never 0 for offline (BF26)")
			assert.equal("Waiting for Aviator 5", env.Properties["Status"])
			-- HAS_BREEZE left out reads as "may have Breeze": still waiting.
			state(env, "0", "0", "Aviator 5")
			assert.same({ 2 }, speeds(c4))
			assert.equal("Waiting for Aviator 5", env.Properties["Status"])
			not_blowing(env, 2)
			assert.same({ 2, 0 }, speeds(c4), "back: what the fan does now")
		end)

		it("shows 0 for a fan without Breeze and says so", function()
			local env, c4 = breeze_fan()
			blowing(env, 2)
			state(env, "0", "0", "Aviator 5", { HAS_BREEZE = "0" })
			assert.same({ 2, 0 }, speeds(c4))
			assert.equal("Aviator 5 has no Breeze", env.Properties["Status"])
			state(env, "0", "0", "Aviator 5", { HAS_BREEZE = "1" })
			assert.equal("Waiting for Aviator 5", env.Properties["Status"])
			assert.same({ 2, 0 }, speeds(c4))
		end)

		it("names the fan as sent, cut so Status stays at 70 characters", function()
			local env = breeze_fan()
			blowing(env, 2)
			state(env, "1", "1", string.rep("x", 100), { STRENGTH = "2" })
			local status = env.Properties["Status"]
			assert.equal(70, #status)
			assert.equal("Breeze 2 on " .. string.rep("x", 55) .. "...", status)
			state(env, "0", "1", string.rep("\195\132", 80)) -- "Ä" 80 times
			status = env.Properties["Status"]
			assert.equal(70, utf8_chars(status))
			assert.truthy(status:find("^Breeze off on \195\132"))
			assert.truthy(status:find("%.%.%.$"))
			state(env, "0", "0", string.rep("y", 90), { HAS_BREEZE = "0" })
			assert.equal(70, #env.Properties["Status"])
			assert.truthy(env.Properties["Status"]:find(" has no Breeze$"))
			state(env, "0", "1", "Aviator\n5\t")
			assert.equal("Breeze off on Aviator5", env.Properties["Status"])
			state(env, "0", "1", nil)
			assert.equal("Breeze off on the fan", env.Properties["Status"])
		end)

		it("ignores a state without BLOWS or AVAILABLE, with a warning", function()
			local lines = capture_log()
			local env, c4 = breeze_fan()
			state(env, nil, "1", "Aviator 5", { STRENGTH = "2" })
			state(env, "1", "maybe", "Aviator 5", { STRENGTH = "2" })
			assert.same({}, c4.proxy_messages(PROXY))
			assert.equal("Waiting for the fan", env.Properties["Status"])
			local warned = 0
			for _, line in ipairs(lines) do
				if line:find("^%[WARN%] Modern Forms Breeze Fan: MF_BREEZE_STATE ignored") then warned = warned + 1 end
			end
			assert.equal(2, warned)
		end)
	end)

	describe("the tile", function()
		-- Each tap and the one message it sends to the fan device (BF-D8).
		local TAPS = {
			{ "SET_SPEED", { SPEED = "1" }, "MF_BREEZE_SET", { ON = "1", STRENGTH = "1" } },
			{ "SET_SPEED", { SPEED = "2" }, "MF_BREEZE_SET", { ON = "1", STRENGTH = "2" } },
			{ "SET_SPEED", { SPEED = "3" }, "MF_BREEZE_SET", { ON = "1", STRENGTH = "3" } },
			{ "SET_SPEED", { SPEED = "0" }, "MF_BREEZE_SET", { ON = "0" } },
			{ "OFF", {}, "MF_BREEZE_SET", { ON = "0" } },
			{ "ON", {}, "MF_BREEZE_SET", { ON = "1" } },
			{ "TOGGLE", {}, "MF_BREEZE_TOGGLE", {} },
			{ "CYCLE_SPEED_UP", {}, "MF_BREEZE_CYCLE", { STEP = "1" } },
			{ "CYCLE_SPEED_DOWN", {}, "MF_BREEZE_CYCLE", { STEP = "-1" } },
		}

		for _, case in ipairs(TAPS) do
			local command, params, message, body = case[1], case[2], case[3], case[4]
			local name = command .. (params.SPEED and (" " .. params.SPEED) or "")
			it(name .. " sends " .. message .. " to the fan device and reports nothing until it answers", function()
				local env, c4 = breeze_fan()
				not_blowing(env, 2)
				local told = #c4.proxy_messages(PROXY)
				local count = #c4.sent
				tap(env, command, params)
				assert.equal(count + 1, #c4.sent, "one message per tap")
				assert.same({ id = FAN, command = message, params = body }, last_sent(c4))
				assert.equal(told, #c4.proxy_messages(PROXY), "no optimistic report")
				assert.equal("Breeze off on Aviator 5", env.Properties["Status"])
			end)
		end

		it("sends the same messages whatever the tile shows: the fan device decides (BF28, BF30)", function()
			local env, c4 = breeze_fan()
			blowing(env, 3)
			tap(env, "TOGGLE")
			tap(env, "TOGGLE")
			tap(env, "ON")
			tap(env, "CYCLE_SPEED_UP")
			local out = {}
			for _, m in ipairs(sent(c4)) do
				if m.command ~= "MF_BREEZE_HELLO" then out[#out + 1] = m end
			end
			assert.same({
				{ id = FAN, command = "MF_BREEZE_TOGGLE", params = {} },
				{ id = FAN, command = "MF_BREEZE_TOGGLE", params = {} },
				{ id = FAN, command = "MF_BREEZE_SET", params = { ON = "1" } },
				{ id = FAN, command = "MF_BREEZE_CYCLE", params = { STEP = "1" } },
			}, out)
		end)

		it("reports the first state after a tap even when unchanged, so a refused tap puts the tile back", function()
			local env, c4 = breeze_fan()
			not_blowing(env, 2)
			tap(env, "SET_SPEED", { SPEED = "3" })
			not_blowing(env, 2) -- the fan device refused, or has not done it yet
			assert.same({ 0, 0 }, speeds(c4))
			not_blowing(env, 2)
			assert.same({ 0, 0 }, speeds(c4), "only the first state after the tap")
			tap(env, "SET_SPEED", { SPEED = "3" })
			blowing(env, 3)
			assert.same({ 0, 0, 3 }, speeds(c4), "a change is reported once")
			blowing(env, 3)
			assert.same({ 0, 0, 3 }, speeds(c4))
		end)

		it("without a tap, an unchanged state tells the proxy nothing", function()
			local env, c4 = breeze_fan()
			blowing(env, 2)
			for _ = 1, 3 do blowing(env, 2) end
			assert.same({ 2 }, speeds(c4))
		end)

		it("puts the tile back after a tap the unavailable fan device refused: the last value again", function()
			local env, c4 = breeze_fan()
			blowing(env, 2)
			away(env, "1", 2)
			tap(env, "OFF")
			assert.same({ ON = "0" }, last_sent(c4).params, "tried: the fan device refuses it itself")
			away(env, "1", 2)
			assert.same({ 2, 2 }, speeds(c4))
		end)

		it("refuses a speed outside 0 to 3, sends the fan device nothing and tells the tile again", function()
			local lines = capture_log()
			local env, c4 = breeze_fan()
			blowing(env, 2)
			local count = #c4.sent
			for _, speed in ipairs({ "4", "-1", "2.5", "x" }) do
				tap(env, "SET_SPEED", { SPEED = speed })
			end
			tap(env, "SET_SPEED", {})
			assert.equal(count, #c4.sent)
			assert.same({ 2, 2, 2, 2, 2, 2 }, speeds(c4))
			assert.truthy(logged(lines, "^%[WARN%] Modern Forms Breeze Fan: SET_SPEED 4 refused: 0 to 3$"))
			assert.truthy(logged(lines, "^%[WARN%] Modern Forms Breeze Fan: SET_SPEED nil refused: 0 to 3$"))
		end)

		it("answers GET_CURRENT_STATE with what the tile shows, and nothing while nothing is known", function()
			local env, c4 = breeze_fan()
			tap(env, "GET_CURRENT_STATE")
			assert.same({}, c4.proxy_messages(PROXY))
			blowing(env, 1)
			tap(env, "GET_CURRENT_STATE")
			assert.same({ 1, 1 }, speeds(c4))
			away(env, "0")
			tap(env, "GET_CURRENT_STATE")
			assert.same({ 1, 1, 1 }, speeds(c4), "unavailable: the last value")
			assert.equal(1, #c4.sent, "the fan device hears nothing of it")
		end)

		it("answers DESIGNATE_PRESET with the declared preset and sends the fan device nothing (BF31)", function()
			local lines = capture_log()
			local env, c4 = breeze_fan({ properties = { ["Debug Mode"] = "On" } })
			tap(env, "DESIGNATE_PRESET", { PRESET = "1" })
			assert.same({ { "PRESET_SPEED", { SPEED = 3 }, "NOTIFY" } }, c4.proxy_messages(PROXY))
			assert.equal(1, #c4.sent)
			assert.truthy(logged(lines, "DESIGNATE_PRESET 1 ignored: the Breeze fan has no preset"))
		end)

		it("logs and ignores the direction and any other command", function()
			local lines = capture_log()
			local env, c4 = breeze_fan({ properties = { ["Debug Mode"] = "On" } })
			blowing(env, 2)
			local told, count = #c4.proxy_messages(PROXY), #c4.sent
			tap(env, "SET_DIRECTION", { DIRECTION = "REVERSE" })
			tap(env, "TOGGLE_DIRECTION")
			tap(env, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "100" })
			tap(env, "BUTTON_ACTION", { BUTTON_ID = "0", ACTION = "2" })
			env.ReceivedFromProxy(200, "DO_CLICK", {})
			assert.equal(told, #c4.proxy_messages(PROXY))
			assert.equal(count, #c4.sent)
			assert.truthy(logged(lines, "SET_DIRECTION ignored"))
			assert.truthy(logged(lines, "TOGGLE_DIRECTION ignored"))
			assert.truthy(logged(lines, "no proxy handler for SET_BRIGHTNESS_TARGET on binding 5001"))
			assert.truthy(logged(lines, "no proxy handler for BUTTON_ACTION on binding 5001"))
			assert.truthy(logged(lines, "no proxy handler for DO_CLICK on binding 200"))
			assert.is_false(logged(lines, "^%[ERROR%]"))
		end)

		it("unbound: refuses every tap with a log line, sends nothing, and puts the tile back at 0", function()
			local lines = capture_log()
			local env, c4 = breeze_fan({ bound = false })
			c4.advance(61000) -- the re-check is over: unbound for certain
			for _, case in ipairs(TAPS) do
				tap(env, case[1], case[2])
			end
			assert.same({}, sent(c4))
			assert.equal(UNBOUND, env.Properties["Status"])
			local refused = {}
			for _, line in ipairs(lines) do
				local command = line:match("^%[WARN%] Modern Forms Breeze Fan: (%S+) refused: not connected to a Modern Forms Fan$")
				if command then refused[#refused + 1] = command end
			end
			local want = {}
			for _, case in ipairs(TAPS) do want[#want + 1] = case[1] end
			assert.same(want, refused)
			assert.same({ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, speeds(c4))
		end)

		it("unbound while still looking: refuses the tap and says nothing to the tile", function()
			local env, c4 = breeze_fan({ bound = false })
			tap(env, "ON")
			assert.same({}, sent(c4))
			assert.same({}, c4.proxy_messages(PROXY))
			assert.equal(UNBOUND, env.Properties["Status"])
		end)

		it("takes a binding Director shows by the time of a tap, greets the fan device and sends the tap", function()
			local env, c4 = breeze_fan({ bound = false })
			c4:Bind(FAN, PROVIDER_BINDING, SELF, FAN_BINDING, CLASS) -- no OnBindingChanged follows
			tap(env, "SET_SPEED", { SPEED = "2" })
			assert.same({ "MF_BREEZE_HELLO", "MF_BREEZE_SET" }, { sent(c4)[1].command, sent(c4)[2].command })
			assert.same({}, c4.active_timers())
		end)

		it("waits for late init with a command that comes first", function()
			local env, c4 = fake.load_driver(DRIVER, nil, { device_id = SELF })
			c4:Bind(FAN, PROVIDER_BINDING, SELF, FAN_BINDING, CLASS)
			env.OnDriverInit("DIT_STARTUP")
			tap(env, "SET_SPEED", { SPEED = "1" })
			tap(env, "GET_CURRENT_STATE") -- as the proxy sends it at the add (hardware K8)
			assert.same({}, sent(c4))
			assert.same({}, c4.calls_to("SendToProxy"))
			env.OnDriverLateInit("DIT_STARTUP")
			assert.same({ "MF_BREEZE_SET", "MF_BREEZE_HELLO" }, { sent(c4)[1].command, sent(c4)[2].command })
			assert.same({}, c4.proxy_messages(PROXY))
		end)
	end)

	describe("the binding", function()
		it("unbound in Connections: 0 at once, Status says so, then a tap and a late state do nothing", function()
			local env, c4 = breeze_fan()
			blowing(env, 2)
			c4:Unbind(SELF, FAN_BINDING)
			env.OnBindingChanged(FAN_BINDING, CLASS, false, FAN, PROVIDER_BINDING)
			assert.equal(UNBOUND, env.Properties["Status"])
			assert.same({ 2, 0 }, speeds(c4))
			local count = #c4.sent
			tap(env, "OFF")
			blowing(env, 3)
			assert.equal(count, #c4.sent)
			assert.equal(UNBOUND, env.Properties["Status"])
			assert.same({ 2, 0, 0 }, speeds(c4), "the refused tap is told 0 again; the late state nothing")
		end)

		it("bound in Connections: says hello to the new fan device and waits for its state", function()
			local env, c4 = breeze_fan({ bound = false })
			c4:Bind(FAN, PROVIDER_BINDING, SELF, FAN_BINDING, CLASS)
			env.OnBindingChanged(FAN_BINDING, CLASS, true, FAN, PROVIDER_BINDING)
			assert.same({ { id = FAN, command = "MF_BREEZE_HELLO", params = {} } }, sent(c4))
			assert.equal("Waiting for the fan", env.Properties["Status"])
			assert.same({}, c4.active_timers(), "the re-check ends with the binding")
			blowing(env, 1)
			assert.same({ 1 }, speeds(c4))
		end)

		it("takes the device OnBindingChanged names while Director's lookup does not show it yet", function()
			local env, c4 = breeze_fan({ bound = false })
			env.OnBindingChanged(FAN_BINDING, CLASS, true, FAN, PROVIDER_BINDING)
			assert.same({ { id = FAN, command = "MF_BREEZE_HELLO", params = {} } }, sent(c4))
		end)

		it("says hello again when the same fan device is bound again", function()
			local env, c4 = breeze_fan()
			env.OnBindingChanged(FAN_BINDING, CLASS, true, FAN, PROVIDER_BINDING)
			assert.same({ "MF_BREEZE_HELLO", "MF_BREEZE_HELLO" }, { sent(c4)[1].command, sent(c4)[2].command })
		end)

		it("moved to another fan device: forgets the old state, keeps the tile, greets the new one", function()
			local env, c4 = breeze_fan()
			blowing(env, 2)
			c4:Unbind(SELF, FAN_BINDING)
			c4:Bind(OTHER_FAN, PROVIDER_BINDING, SELF, FAN_BINDING, CLASS)
			env.OnBindingChanged(FAN_BINDING, CLASS, true, OTHER_FAN, PROVIDER_BINDING)
			assert.same({ id = OTHER_FAN, command = "MF_BREEZE_HELLO", params = {} }, last_sent(c4))
			assert.equal("Waiting for the fan", env.Properties["Status"])
			assert.same({ 2 }, speeds(c4))
			tap(env, "TOGGLE")
			assert.same({ id = OTHER_FAN, command = "MF_BREEZE_TOGGLE", params = {} }, last_sent(c4))
		end)

		it("ignores bindings other than the fan's", function()
			local env, c4 = breeze_fan()
			env.OnBindingChanged(PROXY, "FAN", false, 3001, PROXY)
			assert.equal("Waiting for the fan", env.Properties["Status"])
			assert.equal(1, #c4.sent)
			assert.same({}, c4.proxy_messages(PROXY))
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
			assert.truthy(#sent(c4) >= 1)
			for _, m in ipairs(sent(c4)) do
				assert.equal(FAN, m.id)
				assert.equal("MF_BREEZE_HELLO", m.command)
			end
		end)

		it("a state from a fan device while unbound is taken once Director shows the binding", function()
			local env, c4 = breeze_fan({ bound = false })
			c4:Bind(FAN, PROVIDER_BINDING, SELF, FAN_BINDING, CLASS) -- the state comes before OnBindingChanged
			blowing(env, 2)
			assert.equal("Breeze 2 on Aviator 5", env.Properties["Status"])
			assert.same({ "MF_BREEZE_HELLO" }, { sent(c4)[1].command })
			assert.same({ 2 }, speeds(c4))
		end)

		it("a state while unbound for certain is ignored", function()
			local env, c4 = breeze_fan({ bound = false })
			c4.advance(61000)
			blowing(env, 2)
			assert.equal(UNBOUND, env.Properties["Status"])
			assert.same({ 0 }, speeds(c4))
		end)
	end)

	it("stops every timer of its own when destroyed", function()
		local env, c4 = breeze_fan({ bound = false })
		assert.equal(1, #c4.active_timers())
		env.OnDriverDestroyed("DIT_UPDATING")
		assert.same({}, c4.active_timers())
	end)
end)
