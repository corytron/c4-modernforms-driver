-- The fake runtime itself: bindings, routing, the project model, the
-- Composer-side helpers, the url, timer, property and persistence fakes and
-- the colour maths. Two loaded drivers are two instances of the fan driver
-- (the project ships one driver); a driver with a proxy is one the spec
-- describes with fake.define_driver.
--
-- The fan driver declares two proxies (the fan on 5001, the light on 5002), so
-- every runtime of it owns two proxy devices, 3001 and 3002, and the first
-- proxy AddDevice hands out in a spec with one runtime is 3003.

local fake = require("helpers.fake_c4")
local log = require("common.log")

local FAN = "modernforms_fan"

-- A light_v2 device and a fan device this project does not ship, as Composer
-- would read them from their driver.xml.
local LIGHT_XML = [[
<devicedata>
	<name>Example Light</name>
	<proxies>
		<proxy proxybindingid="5001" name="Example Light">light_v2</proxy>
	</proxies>
</devicedata>]]
local FAN_XML = [[
<devicedata>
	<name>Example Fan</name>
	<proxies>
		<proxy proxybindingid="5002" name="Example Fan">fan</proxy>
	</proxies>
</devicedata>]]

-- A combo driver names itself as its proxy and has no proxy device; a driver
-- with two proxies, in the order the fan driver declares its own; and one
-- written with a bare <proxy> element, which sits on the default 5001.
local COMBO_XML = [[
<devicedata>
	<name>Example Combo</name>
	<proxies>
		<proxy proxybindingid="5001" name="Example Combo">example_combo</proxy>
	</proxies>
</devicedata>]]
local PAIR_XML = [[
<devicedata>
	<name>Example Pair</name>
	<proxies>
		<proxy proxybindingid="5001" name="Example Pair" primary="True">fan</proxy>
		<proxy proxybindingid="5002" name="Example Pair Light">light_v2</proxy>
	</proxies>
</devicedata>]]
local BARE_XML = [[
<devicedata>
	<name>Example Bare</name>
	<proxies>
		<proxy>light_v2</proxy>
		<proxy proxybindingid="5003" name="Example Bare Fan">fan</proxy>
	</proxies>
</devicedata>]]

-- The proxy ids a runtime of the fan driver holds (see the top), and the next.
local FAN_PROXY, LIGHT_PROXY, NEXT_PROXY = 3001, 3002, 3003

-- The binding fake.pair makes when a spec asks for one.
local BIND = { provider_binding = 1, consumer_binding = 1, class = "EXAMPLE_LINK" }

-- A fan (15) and a second fan bound to it; the second is 2001.
local function pair_up(opts)
	local provider = fake.load_driver(FAN, {})
	local consumer = fake.load_driver(FAN, {})
	local id = fake.pair(provider, consumer, opts or { bind = BIND })
	return provider, consumer, id
end

-- Sorted keys of a table.
local function keys(t)
	local out = {}
	for k in pairs(t) do out[#out + 1] = k end
	table.sort(out)
	return out
end

local function clear(t)
	for i = #t, 1, -1 do t[i] = nil end
end

-- The ids of the protocol devices in the project: everything but the proxies,
-- which every runtime of the fan driver brings along.
local function protocols()
	local out = {}
	for id, rec in pairs(fake.project.devices) do
		if not rec.protocol_id then out[#out + 1] = id end
	end
	table.sort(out)
	return out
end

-- Record every OnBindingChanged of an env as { who, ...its five params }.
local function watch_bindings(env, who, into)
	env.OnBindingChanged = function(...) into[#into + 1] = { who, ... } end
end

describe("fake C4 harness", function()
	before_each(function()
		log.sink = function() end
		fake.define_driver("example_light", LIGHT_XML)
		fake.define_driver("example_fan", FAN_XML)
		fake.define_driver("example_combo", COMBO_XML)
		fake.define_driver("example_pair", PAIR_XML)
		fake.define_driver("example_bare", BARE_XML)
	end)

	after_each(function()
		fake.define_driver("example_light", nil)
		fake.define_driver("example_fan", nil)
		fake.define_driver("example_combo", nil)
		fake.define_driver("example_pair", nil)
		fake.define_driver("example_bare", nil)
	end)

	describe("pairs", function()
		it("binds two loaded drivers and answers the bound-device lookups", function()
			local provider, consumer, id = pair_up()
			assert.equal(2001, id)
			-- The value is the driver's <name>, not the Composer name [verified: hardware].
			assert.same({ [2001] = "Modern Forms Fan" }, provider.C4:GetBoundConsumerDevices(15, 1))
			assert.equal(15, consumer.C4:GetBoundProviderDevice(2001, 1))
			assert.is_nil(provider.C4:GetBoundConsumerDevices(15, 2))
			assert.same({ { 15, 1, 2001, 1, "EXAMPLE_LINK" } }, provider.C4.calls_to("Bind"))
		end)

		it("binds nothing without opts.bind, shares one table, and wants a class for a bind", function()
			local provider, consumer, id = pair_up({})
			assert.equal(2001, id)
			assert.equal(0, #provider.C4.bindings)
			assert.equal(provider.C4.bindings, consumer.C4.bindings, "one shared table")
			local a = fake.load_driver(FAN, {})
			local b = fake.load_driver(FAN, {})
			assert.has_error(function() fake.pair(a, b, { bind = {} }) end, "fake.pair: opts.bind needs the binding's class")
		end)

		it("binds the bindings opts.bind names", function()
			local provider, consumer, id = pair_up({ bind = { provider_binding = 7, consumer_binding = 2, class = "X" } })
			assert.same({ [id] = "Modern Forms Fan" }, provider.C4:GetBoundConsumerDevices(15, 7))
			assert.equal(15, consumer.C4:GetBoundProviderDevice(id, 2))
			assert.is_nil(consumer.C4:GetBoundProviderDevice(id, 1))
		end)

		it("routes SendToDevice between the pair with stringified params", function()
			local provider, consumer, id = pair_up()
			local got, saw_c4
			consumer.ExecuteCommand = function(command, params)
				got = { command, params }
				saw_c4 = rawget(_G, "C4")
			end
			fake.as(provider, function() provider.C4:SendToDevice(id, "EXAMPLE_STATE", { speed = 3, on = true }) end)
			assert.equal(1, fake.pump())
			assert.same({ "EXAMPLE_STATE", { speed = "3", on = "true" } }, got)
			assert.equal(consumer.C4, saw_c4, "receiver ran with its own C4")
			assert.equal(0, fake.pump())
		end)

		it("runs each driver's timers with its own globals once paired", function()
			local provider, consumer = pair_up()
			local seen
			fake.as(consumer, function()
				consumer.C4:SetTimer(100, function() seen = rawget(_G, "C4") end)
			end)
			fake.as(provider, function()
				assert.equal(1, consumer.C4.fire_timers())
				assert.equal(provider.C4, rawget(_G, "C4"), "the caller's globals are back afterwards")
			end)
			assert.equal(consumer.C4, seen)
		end)
	end)

	it("keeps SendToDevice's two flags readable but out of the message", function()
		local c4 = fake.install_c4()
		c4:SendToDevice(16, "EXAMPLE", { a = 1 }, true, false)
		assert.same({ { id = 16, command = "EXAMPLE", params = { a = 1 } } }, c4.sent)
		assert.is_true(c4.sent[1].allow_empty)
		assert.is_false(c4.sent[1].log_command)
		assert.same({ { 16, "EXAMPLE", { a = 1 } } }, c4.calls_to("SendToDevice"))
		assert.equal(0, fake.pump(), "nobody loaded at 16: nothing delivered")
	end)

	it("AddDevice hands back ascending ids and records the request", function()
		local c4 = fake.install_c4()
		local ids, infos = {}, {}
		c4:AddDevice("example_light.c4z", 7, "Desk", function(id, info) ids[#ids + 1] = id; infos[#infos + 1] = info end)
		c4:AddDevice("example_light.c4z", function(id, info) ids[#ids + 1] = id; infos[#infos + 1] = info end)
		assert.same({ 2001, 2002 }, ids)
		assert.same({ {}, {} }, infos, "the callback's info table stays empty")
		assert.equal("Desk", c4.added[1].name)
		assert.same({ { "example_light.c4z", 7, "Desk" }, { "example_light.c4z" } }, c4.calls_to("AddDevice"))
	end)

	it("colour conversions round-trip to within a few percent", function()
		local c4 = fake.install_c4()
		for _, k in ipairs({ 2000, 2700, 4000, 6500 }) do
			local x, y = c4:ColorCCTtoXY(k)
			local back = c4:ColorXYtoCCT(x, y)
			assert.is_true(math.abs(back - k) / k < 0.05, string.format("%d K -> %.4f,%.4f -> %.0f K", k, x, y, back))
		end
	end)

	describe("define_driver", function()
		it("refuses to stand in for a driver this project ships, and forgets a definition given nil", function()
			assert.has_error(function() fake.define_driver(FAN, LIGHT_XML) end)
			fake.define_driver("example_light", nil)
			local c4 = fake.install_c4()
			c4:AddDevice("example_light.c4z", function() end)
			assert.same({ name = "example_light", room_id = 7, c4i = "example_light.c4z", driver_name = "example_light" },
				fake.project.devices[2001], "unknown again: base name, no proxy")
		end)
	end)

	describe("load_driver", function()
		it("loads a driver with its declared properties and points the globals at it", function()
			local env, c4 = fake.load_driver(FAN, { ["Debug Mode"] = "On" }, { device_id = 2101 })
			assert.equal("On", env.Properties["Debug Mode"])
			assert.equal("", env.Properties["Driver Version"])
			assert.equal(c4, rawget(_G, "C4"))
			assert.equal(env.Properties, rawget(_G, "Properties"))
			assert.equal(2101, c4:GetDeviceID())
			assert.equal("modernforms_fan.c4z", c4:GetDriverFileName())
			assert.is_function(env.OnDriverLateInit)
			assert.is_nil(rawget(_G, "OnDriverLateInit"), "the driver's globals stay in its env")
		end)

		it("refuses a property its driver.xml does not declare", function()
			assert.has_error(function() fake.load_driver(FAN, { ["No Such Row"] = "x" }) end,
				"property not declared in driver.xml: No Such Row")
		end)

		it("reads the declared properties and defaults, the DEV-ONLY ones included", function()
			local props = fake.declared_properties(FAN)
			assert.equal("", props["Driver Version"])
			assert.equal("Off", props["Debug Mode"])
			assert.equal("", props["Dev Server"], "a DEV-ONLY row is in the source xml")
			assert.equal("15", props["Poll Interval (s)"])
			assert.equal("No other speed", props["Speed 3 Link Also Lit At"])
			assert.is_nil(props["No Such Row"])
		end)
	end)

	describe("project", function()
		it("starts every runtime with the default room and the runtime's own device", function()
			local c4 = fake.install_c4()
			assert.same({ name = "Example Room", floor_id = 3, floor_name = "Main" }, fake.project.rooms[7])
			assert.same({ 7 }, keys(fake.project.rooms))
			assert.equal(7, c4:RoomGetId())
			assert.equal("Modern Forms Fan", c4:GetDeviceDisplayName())
			local own = fake.project.devices[15]
			assert.same({ "Modern Forms Fan", 7, "modernforms_fan.c4z", "Modern Forms Fan" },
				{ own.name, own.room_id, own.c4i, own.driver_name })
			assert.same({ 15 }, protocols())
			assert.same({ 15, FAN_PROXY, LIGHT_PROXY }, keys(fake.project.devices),
				"the fan driver's two proxies come with it")
			assert.equal("modernforms_fan.c4z", c4:GetDriverFileName())
		end)

		it("gives a combo driver, whose proxy is the driver itself, no proxy device", function()
			local c4 = fake.install_c4()
			c4:AddDevice("example_combo.c4z", 7, "Combined", function() end)
			assert.same({ name = "Combined", room_id = 7, c4i = "example_combo.c4z", driver_name = "Example Combo" },
				fake.project.devices[2001])
			assert.same({ 15, 2001 }, protocols())
			assert.is_nil(c4:GetBoundConsumerDevices(2001, 5001))
			assert.is_nil(c4:GetDevices({ DeviceIds = "2001" })[2001].proxies)
		end)

		it("gives a driver with a proxy its proxy device on the binding its xml names", function()
			local _, c4 = fake.load_driver(FAN, {})
			c4:AddDevice("example_light.c4z", 7, "Ceiling Light", function() end)
			assert.same({ name = "Ceiling Light", room_id = 7, c4i = "example_light.c4z", proxy_id = NEXT_PROXY,
				proxy_binding = 5001, driver_name = "Example Light" }, fake.project.devices[2001])
			assert.same({ name = "Ceiling Light", room_id = 7, c4i = "light_v2.c4i", protocol_id = 2001,
				driver_name = "Example Light" }, fake.project.devices[NEXT_PROXY])
			assert.same({ [NEXT_PROXY] = "Example Light" }, c4:GetBoundConsumerDevices(2001, 5001))
			assert.equal(2001, c4:GetBoundProviderDevice(NEXT_PROXY, 5001))
			assert.is_nil(c4:GetBoundProviderDevice(NEXT_PROXY, 1))
			assert.equal(0, #c4.bindings, "the proxy binding is implied, not listed")

			c4:AddDevice("example_fan.c4z", 7, "Ceiling Fan", function() end)
			assert.same({ name = "Ceiling Fan", room_id = 7, c4i = "example_fan.c4z", proxy_id = NEXT_PROXY + 1,
				proxy_binding = 5002, driver_name = "Example Fan" }, fake.project.devices[2002])
			assert.equal("fan.c4i", fake.project.devices[NEXT_PROXY + 1].c4i)
			assert.same({ [NEXT_PROXY + 1] = "Example Fan" }, c4:GetBoundConsumerDevices(2002, 5002))
			assert.is_nil(c4:GetBoundConsumerDevices(2002, 5001))
		end)

		it("resets when a runtime is loaded; pair registers both drivers at their final ids", function()
			local provider = fake.load_driver(FAN, {})
			fake.add_room(8, "Second Room")
			local consumer = fake.load_driver(FAN, {})
			assert.is_nil(fake.project.rooms[8], "a new runtime starts a new project")
			assert.equal(consumer.C4, rawget(_G, "C4"))

			local id = fake.pair(provider, consumer)
			assert.equal(2001, id)
			assert.same({ 15, 2001 }, protocols())
			assert.same({ 15, 2001, 3001, 3002, 3003, 3004 }, keys(fake.project.devices),
				"the consumer's proxies follow the provider's: the placeholder's ids went back")
			assert.equal("modernforms_fan.c4z", fake.project.devices[15].c4i)
			assert.equal("Modern Forms Fan", provider.C4:GetDeviceDisplayName(2001))
			assert.equal(2001, consumer.C4:GetDeviceID())
		end)

		it("keeps the entry AddDevice made when pair reuses its id", function()
			local consumer = fake.load_driver(FAN, {}, { device_id = 2001 })
			local provider = fake.load_driver(FAN, {})
			provider.C4:AddDevice("modernforms_fan.c4z", 7, "Second Fan", function() end)
			fake.pair(provider, consumer, { consumer_id = 2001 })
			assert.same({ 15, 2001 }, protocols())
			assert.equal("Second Fan", consumer.C4:GetDeviceDisplayName())
			assert.equal(2002, provider.C4.next_device_id, "consumer_id takes no id from the provider")
		end)

		it("reset_project keeps the loaded drivers and drops everything else", function()
			local provider, _, id = pair_up()
			fake.add_room(8, "Second Room")
			provider.C4:AddDevice("example_light.c4z", 8, "Ceiling Light", function() end)
			fake.move_device(id, 8)
			fake.reset_project()
			assert.same({ 7 }, keys(fake.project.rooms))
			assert.same({ 15, id }, protocols())
			assert.equal(7, fake.project.devices[id].room_id)
		end)

		it("AddDevice registers the device and its proxy in the room it was given", function()
			local c4 = fake.install_c4()
			fake.add_room(8, "Second Room", 4, "Upstairs")
			c4:AddDevice("example_light.c4z", 8, "Ceiling Light", function() end)
			assert.same({ name = "Ceiling Light", room_id = 8, c4i = "example_light.c4z", proxy_id = NEXT_PROXY,
				proxy_binding = 5001, driver_name = "Example Light" }, fake.project.devices[2001])
			assert.same({ name = "Ceiling Light", room_id = 8, c4i = "light_v2.c4i", protocol_id = 2001,
				driver_name = "Example Light" }, fake.project.devices[NEXT_PROXY])

			-- No room: the caller's; no name: the driver's <name>.
			c4:AddDevice("example_light.c4z", function() end)
			assert.equal(7, fake.project.devices[2002].room_id)
			assert.equal("Example Light", fake.project.devices[2002].name)
			assert.equal(NEXT_PROXY + 1, fake.project.devices[2002].proxy_id)

			-- A driver neither under src/ nor defined: base name, no proxy.
			c4:AddDevice("driver_properties.c4z", function() end)
			assert.same({ name = "driver_properties", room_id = 7, c4i = "driver_properties.c4z",
				driver_name = "driver_properties" }, fake.project.devices[2003])

			assert.has_error(function() c4:AddDevice("example_light.c4z", 99, function() end) end,
				"C4:AddDevice: unknown room 99; fake.add_room() it first")
		end)

		it("moves devices and renames and deletes rooms", function()
			local c4 = fake.install_c4()
			fake.add_room(8, "Second Room")
			c4:AddDevice("example_light.c4z", 7, "Lamp", function() end)
			fake.move_device(NEXT_PROXY, 8)  -- by proxy id: both halves move
			assert.equal(8, fake.project.devices[2001].room_id)
			assert.equal(8, fake.project.devices[NEXT_PROXY].room_id)
			fake.move_device(15, 8)
			assert.equal(8, c4:RoomGetId(), "the room containing this driver")
			assert.same({ 8, 8 }, { fake.project.devices[FAN_PROXY].room_id, fake.project.devices[LIGHT_PROXY].room_id },
				"all of its proxies move with it")

			fake.rename_room(8, "Renamed Room")
			assert.equal("Renamed Room", c4:GetDevices({ DeviceIds = "2001" })[2001].roomName)

			assert.has_error(function() fake.delete_room(8) end)  -- still holds devices
			fake.delete_room(7)
			assert.same({ 8 }, keys(fake.project.rooms))
			assert.has_error(function() fake.move_device(2001, 7) end)
			assert.has_error(function() fake.add_room(8, "Again") end)
			assert.has_error(function() fake.rename_room(7, "Gone") end)
		end)
	end)

	describe("several proxies per driver", function()
		it("gives each <proxy> its own proxy device, in the order declared, bound on its own binding", function()
			local c4 = fake.install_c4()
			c4:AddDevice("example_pair.c4z", 7, "Pair", function() end)
			local fan, light = NEXT_PROXY, NEXT_PROXY + 1
			assert.same({ name = "Pair", room_id = 7, c4i = "example_pair.c4z", driver_name = "Example Pair",
				proxy_id = fan, proxy_binding = 5001, more_proxies = { { id = light, binding = 5002 } } },
				fake.project.devices[2001])
			assert.same({ name = "Pair", room_id = 7, c4i = "fan.c4i", protocol_id = 2001, driver_name = "Example Pair" },
				fake.project.devices[fan])
			assert.same({ name = "Pair", room_id = 7, c4i = "light_v2.c4i", protocol_id = 2001,
				driver_name = "Example Pair" }, fake.project.devices[light])
			assert.same({ [fan] = "Example Pair" }, c4:GetBoundConsumerDevices(2001, 5001))
			assert.same({ [light] = "Example Pair" }, c4:GetBoundConsumerDevices(2001, 5002))
			assert.is_nil(c4:GetBoundConsumerDevices(2001, 5003))
			assert.equal(2001, c4:GetBoundProviderDevice(fan, 5001))
			assert.equal(2001, c4:GetBoundProviderDevice(light, 5002))
			assert.is_nil(c4:GetBoundProviderDevice(fan, 5002), "a proxy is bound on its own binding only")
			assert.is_nil(c4:GetBoundProviderDevice(light, 5001))
			assert.equal(0, #c4.bindings, "the proxy bindings are implied, not listed")
			assert.same({ [fan] = { deviceName = "Pair", driverFileName = "fan.c4i" },
				[light] = { deviceName = "Pair", driverFileName = "light_v2.c4i" } },
				c4:GetDevices({ DeviceIds = "2001" })[2001].proxies)
			assert.same({ [FAN_PROXY] = "Modern Forms Fan", [fan] = "Pair" }, c4:GetDevicesByC4iName("fan.c4i"))
		end)

		it("answers fake.proxy_id for each binding of a loaded driver, the first declared without one", function()
			local env = fake.load_driver(FAN, {})
			assert.equal(FAN_PROXY, fake.proxy_id(env, 5001))
			assert.equal(LIGHT_PROXY, fake.proxy_id(env, 5002))
			assert.equal(LIGHT_PROXY, fake.proxy_id(env, "5002"), "a numeric string names the same binding")
			assert.is_nil(fake.proxy_id(env, 5003))
			assert.equal(FAN_PROXY, fake.proxy_id(env))
			assert.is_nil(fake.proxy_id({ C4 = { device_id = 99 } }, 5001), "no such device")
			assert.same({ [FAN_PROXY] = "Modern Forms Fan" }, env.C4:GetBoundConsumerDevices(15, 5001))
			assert.same({ [LIGHT_PROXY] = "Modern Forms Fan" }, env.C4:GetBoundConsumerDevices(15, 5002))
			assert.equal(15, env.C4:GetBoundProviderDevice(LIGHT_PROXY, 5002))
			assert.is_nil(env.C4:GetBoundProviderDevice(LIGHT_PROXY, 5001))
		end)

		it("keeps the proxy ids apart across a pair: the consumer's follow the provider's", function()
			local provider, consumer = pair_up({})
			assert.same({ FAN_PROXY, LIGHT_PROXY }, { fake.proxy_id(provider, 5001), fake.proxy_id(provider, 5002) })
			assert.same({ NEXT_PROXY, NEXT_PROXY + 1 }, { fake.proxy_id(consumer, 5001), fake.proxy_id(consumer, 5002) })
			assert.same({ [NEXT_PROXY + 1] = "Modern Forms Fan" }, consumer.C4:GetBoundConsumerDevices(2001, 5002))
		end)

		it("reads a bare <proxy> as binding 5001 and mixed forms in document order", function()
			local c4 = fake.install_c4()
			c4:AddDevice("example_bare.c4z", 7, "Bare", function() end)
			local rec = fake.project.devices[2001]
			assert.same({ NEXT_PROXY, 5001, { { id = NEXT_PROXY + 1, binding = 5003 } } },
				{ rec.proxy_id, rec.proxy_binding, rec.more_proxies })
			assert.equal("light_v2.c4i", fake.project.devices[NEXT_PROXY].c4i)
			assert.equal("fan.c4i", fake.project.devices[NEXT_PROXY + 1].c4i)
		end)

		it("moves a device with all its proxies, and deletes it with them and the bindings on any of them", function()
			local c4 = fake.install_c4()
			fake.add_room(8, "Second Room")
			c4:AddDevice("example_pair.c4z", 7, "Pair", function() end)
			fake.move_device(NEXT_PROXY + 1, 8) -- by the second proxy's id
			assert.same({ 8, 8, 8 }, { fake.project.devices[2001].room_id, fake.project.devices[NEXT_PROXY].room_id,
				fake.project.devices[NEXT_PROXY + 1].room_id })
			c4:Bind(NEXT_PROXY + 1, 5002, 7, 1, "LIGHT_V2")
			local removed = fake.delete_device(2001)
			assert.equal(NEXT_PROXY, removed.proxy_id)
			assert.same({ 15, FAN_PROXY, LIGHT_PROXY }, keys(fake.project.devices))
			assert.equal(0, #c4.bindings, "a binding on the second proxy goes too")
		end)
	end)

	describe("GetDevices", function()
		local c4

		before_each(function()
			c4 = fake.install_c4()
			fake.add_room(8, "Second Room")
			fake.add_room(9, "Third Room", 4, "Upstairs")
			c4:AddDevice("example_light.c4z", 8, "Ceiling Light", function() end)   -- 2001, proxy NEXT_PROXY
			c4:AddDevice("example_light.c4z", 9, "Wall Light", function() end)      -- 2002, the proxy after it
		end)

		it("filters by a comma-delimited DeviceIds string, proxy ids included", function()
			local got = c4:GetDevices({ DeviceIds = "2001, " .. (NEXT_PROXY + 1) })
			assert.same({
				[2001] = { deviceName = "Ceiling Light", roomId = 8, roomName = "Second Room",
					driverFileName = "example_light.c4z",
					proxies = { [NEXT_PROXY] = { deviceName = "Ceiling Light", driverFileName = "light_v2.c4i" } } },
				[NEXT_PROXY + 1] = { deviceName = "Wall Light", roomId = 9, roomName = "Third Room",
					driverFileName = "light_v2.c4i",
					protocol = { [2002] = { deviceName = "Wall Light", driverFileName = "example_light.c4z" } } },
			}, got)
			assert.same({ { { DeviceIds = "2001, " .. (NEXT_PROXY + 1) } } }, c4.calls_to("GetDevices"))
			assert.same({}, c4:GetDevices({ DeviceIds = "99" }))
		end)

		it("filters by C4iNames: the protocol devices of that driver, a proxies key only with proxies", function()
			assert.same({ 2001, 2002 }, keys(c4:GetDevices({ C4iNames = "example_light.c4z" })))
			local fan = c4:GetDevices({ C4iNames = "modernforms_fan.c4z" })
			assert.same({ 15 }, keys(fan))
			assert.same({ [FAN_PROXY] = { deviceName = "Modern Forms Fan", driverFileName = "fan.c4i" },
				[LIGHT_PROXY] = { deviceName = "Modern Forms Fan", driverFileName = "light_v2.c4i" } },
				fan[15].proxies, "every proxy of a driver that has two")
			c4:AddDevice("example_combo.c4z", 7, "Combined", function() end)
			assert.same({ [2003] = { deviceName = "Combined", roomId = 7, roomName = "Example Room",
				driverFileName = "example_combo.c4z" } }, c4:GetDevices({ C4iNames = "example_combo.c4z" }),
				"no proxies key without proxies")
			assert.same({ 15, 2001, 2002 }, keys(c4:GetDevices({ C4iNames = "modernforms_fan.c4z,example_light.c4z" })))
			assert.same({ LIGHT_PROXY, NEXT_PROXY, NEXT_PROXY + 1 }, keys(c4:GetDevices({ C4iNames = "light_v2.c4i" })))
		end)

		it("narrows by location: a room, a floor, the building or site", function()
			local lights = { C4iNames = "example_light.c4z" }
			assert.same({ 2002 }, keys(c4:GetDevices(lights, "9")))
			assert.same({ 2002 }, keys(c4:GetDevices(lights, 4)), "floor Upstairs")
			assert.same({ 2001, 2002 }, keys(c4:GetDevices(lights, "3,9")))
			assert.same({ 2001, 2002 }, keys(c4:GetDevices(lights, 2)), "the building")
			assert.same({}, keys(c4:GetDevices(lights, 99)))
			assert.same({ 7, 15, FAN_PROXY, LIGHT_PROXY }, keys(c4:GetDevices({}, 7)),
				"the room, the fan in it and the fan's proxies")
		end)

		it("returns everything, rooms included, for an empty or missing filter", function()
			local got = c4:GetDevices({})
			assert.same({ 7, 8, 9, 15, 2001, 2002, FAN_PROXY, LIGHT_PROXY, NEXT_PROXY, NEXT_PROXY + 1 }, keys(got))
			assert.same({ deviceName = "Second Room", roomId = 8, roomName = "Second Room",
				driverFileName = "roomdevice.c4i" }, got[8])
			assert.same(keys(got), keys(c4:GetDevices()))
			assert.same({ 7, 8, 9 }, keys(c4:GetDevices({ C4iNames = "roomdevice.c4i" })))
		end)

		it("refuses a table of ids and unknown filter keys, as the controller does", function()
			assert.has_error(function() c4:GetDevices({ DeviceIds = { 2001 } }) end, "DeviceIds should be a string")
			assert.has_error(function() c4:GetDevices({ C4iNames = { "example_light.c4z" } }) end,
				"C4iNames should be a string")
			assert.has_error(function() c4:GetDevices({ c4iNames = "example_light.c4z" }) end)
			assert.has_error(function() c4:GetDevices("example_light.c4z") end)
		end)
	end)

	describe("project lookups", function()
		it("GetDevicesByC4iName lists devices by driver file and rooms through roomdevice.c4i", function()
			local c4 = fake.install_c4()
			fake.add_room(8, "Second Room")
			c4:AddDevice("example_light.c4z", 8, "Ceiling Light", function() end)
			assert.same({ [2001] = "Ceiling Light" }, c4:GetDevicesByC4iName("example_light.c4z"))
			assert.same({ [LIGHT_PROXY] = "Modern Forms Fan", [NEXT_PROXY] = "Ceiling Light" },
				c4:GetDevicesByC4iName("light_v2.c4i"), "the fan driver's own light proxy is one too")
			assert.same({ [7] = "Example Room", [8] = "Second Room" }, c4:GetDevicesByC4iName("roomdevice.c4i"))
			assert.same({}, c4:GetDevicesByC4iName("nothing.c4z"))
			assert.same({ { "example_light.c4z" } }, { c4.calls_to("GetDevicesByC4iName")[1] })
		end)

		it("GetProjectHierarchy nests the tree with the controller's numeric types", function()
			local c4 = fake.install_c4()
			fake.add_room(8, "Second Room")
			fake.add_room(9, "Third Room", 4, "Upstairs")
			local second, third = { name = "Second Room", type = 8 }, { name = "Third Room", type = 8 }
			local upstairs = { name = "Upstairs", type = 4, [9] = third }
			assert.same({ [1] = { name = "Home", type = 2, [2] = { name = "House", type = 3,
				[3] = { name = "Main", type = 4, [7] = { name = "Example Room", type = 8 }, [8] = second },
				[4] = upstairs } } }, c4:GetProjectHierarchy())
			assert.same({ [4] = upstairs }, c4:GetProjectHierarchy(4))
			assert.same({ [8] = second }, c4:GetProjectHierarchy("8"))
			assert.same({}, c4:GetProjectHierarchy(99))
			assert.same({ site = 2, building = 3, floor = 4, room = 8 }, fake.location_types)
		end)

		it("GetDeviceDisplayName answers for protocol and proxy ids, nil for strangers", function()
			local c4 = fake.install_c4()
			c4:AddDevice("example_light.c4z", 7, "Ceiling Light", function() end)
			assert.equal("Ceiling Light", c4:GetDeviceDisplayName(2001))
			assert.equal("Ceiling Light", c4:GetDeviceDisplayName(NEXT_PROXY))
			assert.equal("Modern Forms Fan", c4:GetDeviceDisplayName())
			assert.is_nil(c4:GetDeviceDisplayName(99))
			assert.equal(4, #c4.calls_to("GetDeviceDisplayName"))
		end)

		it("RenameDevice records the rename and applies it to the id named only", function()
			local c4 = fake.install_c4()
			c4:AddDevice("example_light.c4z", 7, "Ceiling Light", function() end)
			c4:RenameDevice(NEXT_PROXY, "Fan Light")
			assert.same({ { id = NEXT_PROXY, name = "Fan Light" } }, c4.renamed)
			assert.same({ { NEXT_PROXY, "Fan Light" } }, c4.calls_to("RenameDevice"))
			assert.equal("Fan Light", c4:GetDeviceDisplayName(NEXT_PROXY))
			assert.equal("Ceiling Light", c4:GetDeviceDisplayName(2001), "the protocol driver keeps its name")
			assert.equal("Fan Light", c4:GetDevices({ DeviceIds = "2001" })[2001].proxies[NEXT_PROXY].deviceName)
			assert.has_no.errors(function() c4:RenameDevice(99, "Ghost") end)
			assert.equal(2, #c4.renamed)
		end)
	end)

	describe("Bind and Unbind", function()
		it("tell both drivers of a pair, provider first, and mirror each other", function()
			local provider, consumer, id = pair_up({})
			local seen = {}
			watch_bindings(provider, "provider", seen)
			watch_bindings(consumer, "consumer", seen)

			provider.C4:Bind(15, 1, id, 1, "EXAMPLE_LINK")
			assert.same({
				{ "provider", 1, "EXAMPLE_LINK", true, id, 1 },
				{ "consumer", 1, "EXAMPLE_LINK", true, 15, 1 },
			}, seen)
			assert.equal(1, #consumer.C4.bindings, "one shared table")

			clear(seen)
			consumer.C4:Unbind(id, 1)
			assert.same({
				{ "provider", 1, "EXAMPLE_LINK", false, id, 1 },
				{ "consumer", 1, "EXAMPLE_LINK", false, 15, 1 },
			}, seen)
			assert.equal(0, #provider.C4.bindings)
			assert.is_nil(provider.C4:GetBoundConsumerDevices(15, 1))
			assert.is_nil(consumer.C4:GetBoundProviderDevice(id, 1))
			assert.same({ { id, 1 } }, consumer.C4.calls_to("Unbind"))

			clear(seen)
			consumer.C4:Unbind(id, 1)
			assert.same({}, seen, "nothing to unbind, nothing said")
		end)

		it("stay silent while one end is not a loaded driver, and for pair's own bind", function()
			local seen = {}
			local alone = fake.load_driver(FAN, {}, { device_id = 2001 })
			watch_bindings(alone, "alone", seen)
			alone.C4:Bind(15, 1, 2001, 1, "EXAMPLE_LINK")
			assert.equal(15, alone.C4:GetBoundProviderDevice(2001, 1))
			alone.C4:Unbind(2001, 1)
			assert.is_nil(alone.C4:GetBoundProviderDevice(2001, 1))
			assert.same({}, seen)

			local provider = fake.load_driver(FAN, {})
			local consumer = fake.load_driver(FAN, {})
			watch_bindings(provider, "provider", seen)
			watch_bindings(consumer, "consumer", seen)
			fake.pair(provider, consumer, { bind = BIND })
			assert.same({}, seen)
			assert.equal(1, #provider.C4.bindings)
		end)
	end)

	describe("link_keypad and unlink_keypad", function()
		it("bind a keypad button to a link and tell the driver alone, then take it away", function()
			local provider, consumer = pair_up({})
			local seen, saw_c4 = {}, nil
			watch_bindings(provider, "provider", seen)
			watch_bindings(consumer, "consumer", seen)
			local record = provider.OnBindingChanged
			provider.OnBindingChanged = function(...)
				saw_c4 = rawget(_G, "C4")
				record(...)
			end
			fake.link_keypad(provider, 200, 77, 3)
			assert.same({ { "provider", 200, "BUTTON_LINK", true, 77, 3 } }, seen)
			assert.equal(provider.C4, saw_c4, "the driver ran with its own globals")
			assert.same({ { provider = 15, provider_binding = 200, consumer = 77, consumer_binding = 3,
				class = "BUTTON_LINK" } }, provider.C4.bindings)
			assert.same({ [77] = "Device 77" }, provider.C4:GetBoundConsumerDevices(15, 200))
			assert.equal(15, provider.C4:GetBoundProviderDevice(77, 3))
			assert.equal(0, #provider.C4.calls_to("Bind"), "Composer binds, the driver does not")
			assert.is_nil(provider.C4:GetDeviceDisplayName(77))
			fake.project.devices[77] = { name = "Example Keypad", room_id = 7, c4i = "keypad.c4i",
				driver_name = "Example Keypad" }
			assert.equal("Example Keypad", provider.C4:GetDeviceDisplayName(77))
			assert.same({ [77] = "Example Keypad" }, provider.C4:GetBoundConsumerDevices(15, 200))

			clear(seen)
			fake.unlink_keypad(provider, 200, 77, 3)
			assert.same({ { "provider", 200, "BUTTON_LINK", false, 77, 3 } }, seen)
			assert.same({}, provider.C4.bindings)
			assert.is_nil(provider.C4:GetBoundConsumerDevices(15, 200))
			clear(seen)
			fake.unlink_keypad(provider, 200, 77, 3)
			assert.same({}, seen, "nothing linked, nothing said")
		end)

		it("let several keypads share a link, and unlink by keypad when no binding is named", function()
			local env = fake.load_driver(FAN, {})
			local seen = {}
			watch_bindings(env, "fan", seen)
			fake.link_keypad(env, 300, 77, 3)
			fake.link_keypad(env, 300, 78, 3)
			fake.link_keypad(env, 301, 77, 4)
			assert.same({ [77] = "Device 77", [78] = "Device 78" }, env.C4:GetBoundConsumerDevices(15, 300))
			clear(seen)
			fake.unlink_keypad(env, 300, 77)
			assert.same({ { "fan", 300, "BUTTON_LINK", false, 77, 3 } }, seen)
			assert.same({ [78] = "Device 78" }, env.C4:GetBoundConsumerDevices(15, 300))
			assert.same({ [77] = "Device 77" }, env.C4:GetBoundConsumerDevices(15, 301), "another link is not touched")
			clear(seen)
			fake.unlink_keypad(env, 300, 77, 9)
			assert.same({}, seen, "a binding the keypad does not have")
		end)

		it("want the arguments that make the binding", function()
			local env = fake.load_driver(FAN, {})
			assert.has_error(function() fake.link_keypad(env, 200, 77) end)
			assert.has_error(function() fake.unlink_keypad(env, 200) end)
		end)
	end)

	describe("delete_device", function()
		it("runs Composer's delete on a paired driver: callbacks, its last message, unbinding, gone", function()
			local provider, consumer, id = pair_up()
			local events = {}
			consumer.OnDriverRemovedFromProject = function()
				events[#events + 1] = { "removed", rawget(_G, "C4") == consumer.C4 }
				consumer.C4:SendToDevice(15, "EXAMPLE_GOODBYE", { device_id = id })
			end
			consumer.OnDriverDestroyed = function(dit) events[#events + 1] = { "destroyed", dit } end
			consumer.OnBindingChanged = function() error("the deleted driver hears nothing") end
			provider.ExecuteCommand = function(command, params) events[#events + 1] = { "provider", command, params } end
			watch_bindings(provider, "unbound", events)
			fake.as(consumer, function() consumer.C4:SetTimer(500, function() end) end)

			local removed = fake.delete_device(id)
			assert.same({
				{ "removed", true },
				{ "destroyed", "DIT_LOADED" },
				{ "provider", "EXAMPLE_GOODBYE", { device_id = tostring(id) } },
				{ "unbound", 1, "EXAMPLE_LINK", false, id, 1 },
			}, events)
			assert.equal("Modern Forms Fan", removed.name)
			assert.equal(0, #consumer.C4.active_timers(), "OnDriverDestroyed kills the timers")
			assert.same({}, provider.C4.bindings)
			assert.same({ 15, FAN_PROXY, LIGHT_PROXY }, keys(fake.project.devices),
				"the consumer and both its proxies are gone, the provider's stay")
			assert.is_nil(provider.C4:GetBoundConsumerDevices(15, 1))

			-- Messages to the dead id vanish; the id cannot be deleted twice.
			fake.as(provider, function() provider.C4:SendToDevice(id, "EXAMPLE_STATE", { speed = "3" }) end)
			assert.equal(0, fake.pump())
			assert.has_error(function() fake.delete_device(id) end)
		end)

		it("accepts the proxy id and a device whose driver is not loaded; bindings on its proxy go too", function()
			local c4, env = fake.install_c4()
			c4:AddDevice("example_light.c4z", 7, "Ceiling Light", function() end)
			c4:Bind(15, 1, 2001, 1, "EXAMPLE_LINK")
			-- A second binding on the proxy side, as Director wires a light_v2 proxy.
			c4:Bind(NEXT_PROXY, 5001, 7, 1, "LIGHT_V2")
			local seen = {}
			watch_bindings(env, "fan", seen)
			local removed = fake.delete_device(NEXT_PROXY)
			assert.equal("Ceiling Light", removed.name)
			assert.equal(NEXT_PROXY, removed.proxy_id)
			assert.same({ { "fan", 1, "EXAMPLE_LINK", false, 2001, 1 } }, seen,
				"the side still in the project hears the unbinding; the proxy's other end is no runtime")
			assert.same({ 15, FAN_PROXY, LIGHT_PROXY }, keys(fake.project.devices))
			assert.equal(0, #c4.bindings)
			assert.has_error(function() fake.delete_device(99) end)
		end)

		it("deleting the provider unbinds the consumer and leaves it in the project", function()
			local provider, consumer, id = pair_up()
			provider.OnDriverDestroyed = function() end
			local seen = {}
			watch_bindings(consumer, "consumer", seen)
			fake.delete_device(15)
			assert.same({ { "consumer", 1, "EXAMPLE_LINK", false, 15, 1 } }, seen)
			assert.same({ id }, protocols())
			assert.is_nil(fake.project.devices[FAN_PROXY], "the provider's proxies left with it")
			assert.is_nil(consumer.C4:GetBoundProviderDevice(id, 1))
			assert.equal(7, consumer.C4:RoomGetId())
		end)
	end)

	it("custom_select calls a driver's list function with its globals in place", function()
		local provider, consumer = pair_up()
		provider.ListRooms = function(prefix)
			return { prefix .. tostring(rawget(_G, "C4") == provider.C4), tostring(C4:GetDeviceID()) }
		end
		fake.as(consumer, function()
			assert.same({ "mine: true", "15" }, fake.custom_select(provider, "ListRooms", "mine: "))
			assert.equal(consumer.C4, rawget(_G, "C4"), "globals restored afterwards")
		end)
		assert.has_error(function() fake.custom_select(provider, "NoSuchList") end)
	end)

	describe("url transfers", function()
		local URL = "http://10.0.2.151/example"

		it("record the request and answer it in one go, the body gathered when there is no OnBodyChunk", function()
			local c4 = fake.install_c4()
			local got
			local t = c4:url()
				:SetOption("timeout", 5)
				:SetOptions({ connect_timeout = 2 })
				:OnDone(function(transfer, responses, err) got = { transfer, responses, err } end)
				:Post(URL, '{"example":1}', { ["Content-Type"] = "application/json" })
			assert.equal(t, c4.last_transfer())
			assert.same({ "POST", URL, '{"example":1}', "application/json", 5, 2 },
				{ t.method, t.url, t.data, t.headers["Content-Type"], t.options.timeout, t.options.connect_timeout })
			assert.equal(1, t:TicketId())
			t:respond(200, '{"ok":true}')
			assert.equal(t, got[1])
			assert.equal(0, got[3])
			assert.same({ { code = 200, headers = {}, body = '{"ok":true}' } }, got[2])
			assert.has_error(function() t:Get(URL) end, "transfer already started")
		end)

		it("hand the body to OnBodyChunk instead, and end a transfer that never answered with its error", function()
			local c4 = fake.install_c4()
			local chunks, done = {}, {}
			c4:url()
				:OnBodyChunk(function(_, _, data) chunks[#chunks + 1] = data end)
				:OnDone(function(_, responses, err, msg) done = { #responses, err, msg } end)
				:Get(URL)
			local t = c4.last_transfer()
			t:respond_headers(200, { ["Content-Type"] = "text/plain" })
			t:chunk("one ")
			t:chunk("two")
			t:done(0)
			assert.same({ "one ", "two" }, chunks)
			assert.same({ 1, 0 }, done)

			c4:url():OnDone(function(_, responses, err, msg) done = { #responses, err, msg } end):Get(URL)
			c4.last_transfer():done(7, "Couldn't connect to server")
			assert.same({ 0, 7, "Couldn't connect to server" }, done)
			assert.equal(2, #c4.transfers)
		end)

		it("abort when OnHeaders or OnBodyChunk answers true: no more chunks, OnDone with -1", function()
			local c4 = fake.install_c4()
			local done
			c4:url()
				:OnHeaders(function(_, response) return response.code ~= 200 end)
				:OnDone(function(_, responses, err) done = { #responses, err, responses[1].body } end)
				:Get(URL)
			local t = c4.last_transfer()
			t:respond(503, "busy")
			assert.is_true(t.aborted and t.cancelled)
			assert.same({ 1, -1, nil }, done, "no body after an aborting OnHeaders")

			local chunks = {}
			c4:url()
				:OnBodyChunk(function(_, _, data) chunks[#chunks + 1] = data; return data == "stop" end)
				:Get(URL)
			t = c4.last_transfer()
			t:respond_headers(200)
			t:chunk("stop")
			t:chunk("never")
			assert.same({ "stop" }, chunks)
			assert.is_true(t.aborted)
		end)

		it("follow a redirect on the same transfer: OnHeaders per response, OnDone with both", function()
			local c4 = fake.install_c4()
			local codes, done = {}, nil
			c4:url()
				:OnHeaders(function(_, response) codes[#codes + 1] = response.code end)
				:OnDone(function(_, responses, err) done = { #responses, err } end)
				:Get(URL)
			local t = c4.last_transfer()
			t:redirect(301, "http://10.0.2.151/elsewhere")
			t:respond(200, "{}")
			assert.same({ 301, 200 }, codes)
			assert.same({ 2, 0 }, done)
			assert.equal("http://10.0.2.151/elsewhere", t.responses[1].headers.Location)
		end)

		it("Cancel marks the transfer; an unstarted one has ticket 0; Put, Delete and Custom record their method",
			function()
				local c4 = fake.install_c4()
				local t = c4:url()
				assert.equal(0, t:TicketId())
				t:Put(URL, "x")
				assert.equal(t, t:Cancel())
				assert.is_true(t.cancelled)
				c4:url():Delete(URL)
				c4:url():Custom(URL, "PATCH", "y")
				assert.same({ "PUT", "DELETE", "PATCH" },
					{ c4.transfers[1].method, c4.transfers[2].method, c4.transfers[3].method })
			end)

		it("fail ends a transfer with the error and no responses; finished and open_transfers follow", function()
			local c4 = fake.install_c4()
			local done = {}
			local function start(name)
				c4:url():OnDone(function(_, responses, err, msg) done[name] = { #responses, err, msg } end):Get(URL)
				return c4.last_transfer()
			end
			assert.same({}, c4.open_transfers())
			c4:url() -- never started: not open
			local a, b, c = start("a"), start("b"), start("c")
			assert.is_false(a.finished)
			local open = c4.open_transfers()
			assert.same({ a, b, c }, { open[1], open[2], open[3] }, "in the order started")

			a:fail(7, "Couldn't connect to server")
			assert.same({ 0, 7, "Couldn't connect to server" }, done.a)
			assert.is_true(a.finished)
			b:respond(200, "{}")
			assert.same({ 1, 0 }, done.b)
			assert.is_true(b.finished)
			assert.equal(1, #c4.open_transfers())
			c:Cancel()
			assert.same({}, c4.open_transfers(), "finished, answered and cancelled transfers are over")
			assert.is_nil(done.c, "a cancelled transfer is not told")
		end)

		it("fail needs a real error code; a transfer without OnDone still finishes; an aborted one is over", function()
			local c4 = fake.install_c4()
			c4:url():Get(URL)
			local t = c4.last_transfer()
			assert.has_error(function() t:fail() end)
			assert.has_error(function() t:fail(0, "not an error") end)
			assert.is_false(t.finished)
			assert.has_no.errors(function() t:fail(28, "Timeout was reached") end)
			assert.is_true(t.finished)

			c4:url():OnHeaders(function() return true end):Get(URL)
			local aborted = c4.last_transfer()
			aborted:respond(503, "busy")
			assert.is_true(aborted.finished)
			assert.same({}, c4.open_transfers())
		end)
	end)

	describe("advance", function()
		-- The milliseconds since the runtime started, as a callback sees them.
		local function clock(c4)
			local t0 = c4.now_ms
			return function() return c4:GetTime() - t0 end
		end

		it("fires the timers that fall due in due order, the one armed first going first at the same time", function()
			local c4 = fake.install_c4()
			local t0, since = c4.now_ms, clock(c4)
			local fired = {}
			local function mark(name)
				return function() fired[#fired + 1] = name .. "@" .. since() end
			end
			c4:SetTimer(300, mark("c"))
			c4:SetTimer(100, mark("a"))
			c4:SetTimer(100, mark("b"))
			c4:SetTimer(500, mark("late"))
			c4.advance(350)
			assert.same({ "a@100", "b@100", "c@300" }, fired)
			assert.equal(t0 + 350, c4.now_ms)
			assert.equal(t0 + 350, c4:GetTime())
			assert.equal(1, #c4.active_timers())
			c4.advance(150)
			assert.same({ "a@100", "b@100", "c@300", "late@500" }, fired)
			assert.equal(0, #c4.active_timers())
		end)

		it("fires the timers a callback arms when they fall due within the same advance", function()
			local c4 = fake.install_c4()
			local since = clock(c4)
			local fired = {}
			c4:SetTimer(100, function()
				fired[#fired + 1] = "first@" .. since()
				c4:SetTimer(100, function() fired[#fired + 1] = "second@" .. since() end)
				c4:SetTimer(1000, function() fired[#fired + 1] = "far@" .. since() end)
			end)
			c4.advance(250)
			assert.same({ "first@100", "second@200" }, fired)
			assert.equal(1, #c4.active_timers())
			c4.advance(849)
			assert.equal(2, #fired)
			c4.advance(1)
			assert.same({ "first@100", "second@200", "far@1100" }, fired)
		end)

		it("re-arms a repeating timer, which can fire several times in one advance, until it is cancelled", function()
			local c4 = fake.install_c4()
			local since = clock(c4)
			local fired = {}
			c4:SetTimer(100, function(timer, skips)
				fired[#fired + 1] = since()
				assert.equal(0, skips)
				if #fired == 4 then timer:Cancel() end
			end, true)
			c4.advance(250)
			assert.same({ 100, 200 }, fired)
			assert.equal(1, #c4.active_timers())
			c4.advance(750)
			assert.same({ 100, 200, 300, 400 }, fired, "cancelled by its fourth firing")
			assert.equal(0, #c4.active_timers())
			assert.equal(1000, since())
		end)

		it("lets a callback cancel a timer that falls due later in the advance, and leaves cancelled ones alone", function()
			local c4 = fake.install_c4()
			local t0 = c4.now_ms
			local fired = {}
			local later = c4:SetTimer(200, function() fired[#fired + 1] = "later" end)
			c4:SetTimer(100, function() later:Cancel() fired[#fired + 1] = "canceller" end)
			local never = c4:SetTimer(50, function() fired[#fired + 1] = "never" end)
			never:Cancel()
			c4.advance(500)
			assert.same({ "canceller" }, fired)
			assert.equal(t0 + 500, c4.now_ms, "the clock moves with nothing left due")
		end)

		it("leaves fire_timers as it is: every active timer once; a repeating one then falls due a delay later", function()
			local c4 = fake.install_c4()
			local fired = {}
			c4:SetTimer(1000, function() fired[#fired + 1] = "once" end)
			c4:SetTimer(60000, function() fired[#fired + 1] = "every" end, true)
			assert.equal(2, c4.fire_timers())
			assert.same({ "once", "every" }, fired)
			c4.advance(59999)
			assert.same({ "once", "every" }, fired, "not at once: a delay after the firing")
			c4.advance(1)
			assert.same({ "once", "every", "every" }, fired)
		end)

		it("fires what falls due after the spec moved c4.now_ms itself", function()
			local c4 = fake.install_c4()
			local fired = 0
			c4:SetTimer(250, function() fired = fired + 1 end)
			c4.now_ms = c4.now_ms + 1000
			c4.advance(0)
			assert.equal(1, fired)
		end)

		it("runs a paired driver's timers with its own globals", function()
			local provider, consumer = pair_up({})
			local seen
			fake.as(consumer, function()
				consumer.C4:SetTimer(100, function() seen = rawget(_G, "C4") end)
			end)
			fake.as(provider, function()
				consumer.C4.advance(100)
				assert.equal(provider.C4, rawget(_G, "C4"), "the caller's globals are back afterwards")
			end)
			assert.equal(consumer.C4, seen)
		end)

		it("refuses a step backwards, and takes a timer that never stops falling due for a runaway", function()
			local c4 = fake.install_c4()
			assert.has_error(function() c4.advance(-1) end)
			assert.has_error(function() c4.advance("soon") end)
			c4:SetTimer(1, function() end, true)
			local ok, err = pcall(c4.advance, 1e9)
			assert.is_false(ok)
			assert.truthy(tostring(err):find("more than 100000 timers fired", 1, true))
		end)
	end)

	describe("SendToProxy", function()
		it("records its fourth argument, COMMAND or NOTIFY, and proxy_messages lists one binding in order", function()
			local c4 = fake.install_c4()
			c4:SendToProxy(5001, "CURRENT_SPEED", { SPEED = 3 }, "NOTIFY")
			c4:SendToProxy(300, "MATCH_LED_STATE", { STATE = true }, "COMMAND")
			c4:SendToProxy(5002, "PRESET_LEVEL", "100")
			c4:SendToProxy(5001, "ON", {})
			c4:SendToProxy(300, "MATCH_LED_STATE", { STATE = false }, "COMMAND")
			assert.same({
				{ 5001, "CURRENT_SPEED", { SPEED = 3 }, "NOTIFY" },
				{ 300, "MATCH_LED_STATE", { STATE = true }, "COMMAND" },
				{ 5002, "PRESET_LEVEL", "100" },
				{ 5001, "ON", {} },
				{ 300, "MATCH_LED_STATE", { STATE = false }, "COMMAND" },
			}, c4.calls_to("SendToProxy"))
			assert.same({ { "CURRENT_SPEED", { SPEED = 3 }, "NOTIFY" }, { "ON", {} } }, c4.proxy_messages(5001))
			assert.same({ { "MATCH_LED_STATE", { STATE = true }, "COMMAND" },
				{ "MATCH_LED_STATE", { STATE = false }, "COMMAND" } }, c4.proxy_messages(300))
			assert.same({ { "PRESET_LEVEL", "100" } }, c4.proxy_messages("5002"))
			assert.same({}, c4.proxy_messages(5003))
		end)
	end)

	describe("network connections", function()
		it("record the dynamic connection calls and nothing else", function()
			local c4 = fake.install_c4()
			c4:CreateNetworkConnection(6001, "224.0.0.251", "MULTICAST")
			c4:NetPortOptions(6001, 5353, "UDP", { MIRROR_UDP_PORT = false })
			c4:NetConnect(6001, 5353, "MULTICAST")
			c4:SendToNetwork(6001, 5353, "\0\1query")
			c4:NetDisconnect(6001, 5353)
			assert.same({ { 6001, "224.0.0.251", "MULTICAST" } }, c4.calls_to("CreateNetworkConnection"))
			assert.same({ { 6001, 5353, "UDP", { MIRROR_UDP_PORT = false } } }, c4.calls_to("NetPortOptions"))
			assert.same({ { 6001, 5353, "MULTICAST" } }, c4.calls_to("NetConnect"))
			assert.same({ { 6001, 5353, "\0\1query" } }, c4.calls_to("SendToNetwork"))
			assert.same({ { 6001, 5353 } }, c4.calls_to("NetDisconnect"))
			assert.equal(0, #c4.transfers)
		end)

		it("network_receive calls the driver's ReceivedFromNetwork with its globals in place, and the sender", function()
			local provider, consumer = pair_up({})
			local got, saw_c4
			provider.ReceivedFromNetwork = function(...)
				got = { ... }
				saw_c4 = rawget(_G, "C4")
			end
			fake.as(consumer, function()
				fake.network_receive(provider, 6001, 5353, "\0datagram", "10.0.2.151")
				assert.equal(consumer.C4, rawget(_G, "C4"), "the caller's globals are back afterwards")
			end)
			assert.same({ 6001, 5353, "\0datagram", "10.0.2.151" }, got)
			assert.equal(provider.C4, saw_c4)
			got = nil
			fake.network_receive(provider, 6001, 5353, "x") -- no sender: before OS 4.0.0
			assert.same({ 6001, 5353, "x" }, got)
		end)

		it("network_receive is harmless to a driver without ReceivedFromNetwork", function()
			local env = fake.load_driver(FAN, {})
			env.ReceivedFromNetwork = nil
			assert.has_no.errors(function() fake.network_receive(env, 6001, 5353, "x", "10.0.2.151") end)
		end)
	end)

	describe("timers, properties, persistence and the rest of the runtime", function()
		it("fire_timers runs every active timer once, retires one-shots and keeps repeating ones", function()
			local c4 = fake.install_c4()
			local fired = {}
			local once = c4:SetTimer(100, function() fired[#fired + 1] = "once" end)
			c4:SetTimer(3000, function(timer) fired[#fired + 1] = timer.delay end, true)
			local cancelled = c4:SetTimer(50, function() fired[#fired + 1] = "cancelled" end)
			cancelled:Cancel()
			assert.equal(2, c4.fire_timers())
			assert.same({ "once", 3000 }, fired)
			assert.is_false(once.active)
			assert.equal(1, c4.fire_timers())
			assert.same({ 3000 }, { c4.active_timers()[1].delay })
			assert.same({ { 100, false }, { 3000, true }, { 50, false } }, c4.calls_to("SetTimer"))
			assert.has_error(function() c4:SetTimer(0, function() end) end)
		end)

		it("properties: UpdateProperty, UpdatePropertyList and SetPropertyAttribs", function()
			local c4, env = fake.install_c4({ ["Debug Mode"] = "Off" })
			c4:UpdateProperty("Driver Version", "12")
			c4:UpdatePropertyList("Example List", "a,b,c", "b")
			c4:SetPropertyAttribs("Example List", 1)
			assert.equal("12", env.Properties["Driver Version"])
			assert.equal("b", env.Properties["Example List"])
			assert.equal("a,b,c", c4.property_lists["Example List"])
			assert.equal(1, c4.property_attribs["Example List"])
			assert.equal(env.Properties, rawget(_G, "Properties"))
		end)

		it("persists, reads back and deletes values; a key never written reads nil here", function()
			local c4 = fake.install_c4()
			c4:PersistSetValue("example_key", "x")
			c4:PersistSetValue("secret", "y", true)
			assert.equal("x", c4:PersistGetValue("example_key"))
			assert.is_nil(c4:PersistGetValue("never_written"))
			c4:PersistDeleteValue("example_key")
			assert.same({ secret = "y" }, c4.persist)
			assert.same({ { "example_key", "x", false }, { "secret", "y", true } }, c4.calls_to("PersistSetValue"))
		end)

		it("adds variables with ids from 1001, refuses a second of one name, and raises on an unknown one", function()
			local c4 = fake.install_c4()
			assert.same({ true, 1001 }, { c4:AddVariable("EXAMPLE_NUMBER", "0", "NUMBER") })
			assert.same({ true, 1002 }, { c4:AddVariable("EXAMPLE_BOOL", "0", "BOOL", true, false) })
			assert.is_false(c4:AddVariable("EXAMPLE_NUMBER", "1", "NUMBER"))
			c4:SetVariable("EXAMPLE_NUMBER", "3")
			assert.equal("3", c4.variables.EXAMPLE_NUMBER.value)
			assert.is_true(c4.variables.EXAMPLE_BOOL.read_only)
			assert.same({ "EXAMPLE_NUMBER", "EXAMPLE_BOOL" }, c4.variable_names)
			assert.has_error(function() c4:SetVariable("NOPE", "1") end)
			c4:FireEventByID(3)
			c4:FireEventByID(1)
			assert.same({ 3, 1 }, c4.events_fired)
		end)

		it("JSON, the version table, the clock and ISO 8601 times", function()
			local c4 = fake.install_c4()
			assert.same({ a = 1, b = { true, "x" } }, c4:JsonDecode(c4:JsonEncode({ a = 1, b = { true, "x" } })))
			local value, err = c4:JsonDecode("{not json")
			assert.is_nil(value)
			assert.truthy(err)
			assert.same({ version = "3.4.2.746094" }, c4:GetVersionInfo())
			c4.director_version = nil
			assert.is_nil(c4:GetVersionInfo())
			c4.now_ms = c4.now_ms + 250
			assert.equal(1000250, c4:GetTime())
			local t, epoch, micro = c4:ParseIso8601DateTime(" 2026-10-26T14:02:31.120+01:00 ")
			assert.same({ 2026, 10, 26, 13, 2, 31 }, { t.year, t.month, t.day, t.hour, t.min, t.sec })
			assert.equal(1793019751, epoch)
			assert.equal(120000, micro)
			assert.is_nil(c4:ParseIso8601DateTime(" 2026-10-26T14:02:31Z ", true), "strict: no white space")
			assert.is_nil(c4:ParseIso8601DateTime("yesterday"))
		end)

		it("JsonDecode answers nil and a message for invalid JSON, or raises once json_decode_raises is set", function()
			local c4 = fake.install_c4()
			local value, err = c4:JsonDecode("{not json")
			assert.is_nil(value)
			assert.truthy(err)
			c4.json_decode_raises = true
			local ok, raised = pcall(c4.JsonDecode, c4, "{not json")
			assert.is_false(ok)
			assert.truthy(raised)
			assert.same({ a = 1 }, c4:JsonDecode('{"a":1}'), "valid JSON decodes as before")
			c4.json_decode_raises = false
			assert.is_nil((c4:JsonDecode("{not json")))
		end)

		it("the File API: alias directories, handles that open at the end, read, write, list and delete", function()
			local c4 = fake.install_c4()
			assert.is_true(c4:FileSetDir("SANDBOX"))
			local fh = c4:FileOpen("state.txt")
			assert.equal(5, c4:FileWriteString(fh, "hello"))
			c4:FileSetPos(fh, 0)
			assert.equal("hel", c4:FileRead(fh, 3))
			assert.equal("lo", c4:FileRead(fh, 10))
			assert.equal(5, c4:FileGetSize(fh))
			c4:FileClose(fh)
			fh = c4:FileOpen("state.txt")
			assert.equal("", c4:FileRead(fh, 1), "FileOpen positions at the end")
			assert.is_true(c4:FileExists("state.txt"))
			assert.same({ "state.txt" }, c4:FileList())
			assert.equal("hello", c4.files["state.txt"])
			c4:FileSetDir("C4Z")
			assert.is_false(c4:FileExists("state.txt"))
			c4:FileSetDir("SANDBOX")
			c4:FileDelete("state.txt")
			assert.is_false(c4:FileExists("state.txt"))
			assert.has_error(function() c4:FileSetDir("NOWHERE") end)
		end)
	end)
end)
