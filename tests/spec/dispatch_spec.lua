-- common.dispatch: the DriverWorks entry points routed to handler tables.

local function fresh_dispatch()
	package.loaded["common.dispatch"] = nil
	return require("common.dispatch")
end

describe("common.dispatch", function()
	local log = require("common.log")
	local logged

	before_each(function()
		logged = {}
		log.sink = function(line) table.insert(logged, line) end
	end)

	after_each(function()
		log.set_debug(false)
	end)

	it("routes Composer actions (LUA_ACTION) by action name", function()
		local dispatch = fresh_dispatch()
		local got
		dispatch.commands["Example_Action"] = function(params) got = params end

		dispatch.execute_command("LUA_ACTION", { ACTION = "Example Action", X = "1" })

		assert.same({ X = "1" }, got)
	end)

	it("routes a command sent by name, and a LUA_ACTION without ACTION as LUA_ACTION itself", function()
		local dispatch = fresh_dispatch()
		local got = {}
		dispatch.commands["DEV_RELOAD"] = function(params) got[#got + 1] = { "reload", params } end
		dispatch.commands["LUA_ACTION"] = function(params) got[#got + 1] = { "action", params } end

		dispatch.execute_command("DEV_RELOAD", { version = "7" })
		dispatch.execute_command("LUA_ACTION", { X = "1" })
		dispatch.execute_command("DEV_RELOAD", nil)

		assert.same({ { "reload", { version = "7" } }, { "action", { X = "1" } }, { "reload", {} } }, got)
	end)

	it("passes property values to the matching handler, white space in the name as one _", function()
		local dispatch = fresh_dispatch()
		local got = {}
		dispatch.properties["Debug_Mode"] = function(value) got[#got + 1] = value end

		dispatch.property_changed("Debug Mode", "On")
		dispatch.property_changed("Debug  \tMode", "Off")
		dispatch.property_changed("Debug Mode", nil)

		assert.same({ "On", "Off", "" }, got, "a missing value arrives as the empty string")
	end)

	it("hands a proxy command its binding and params, {} when there are none", function()
		local dispatch = fresh_dispatch()
		local got
		dispatch.proxy["ON"] = function(binding, params) got = { binding, params } end

		dispatch.received_from_proxy(5001, "ON", nil)

		assert.same({ 5001, {} }, got)
	end)

	it("returns the handler's result", function()
		local dispatch = fresh_dispatch()
		dispatch.commands["Answer"] = function() return 42 end
		assert.equal(42, dispatch.execute_command("Answer", {}))
	end)

	it("contains handler errors and logs them", function()
		local dispatch = fresh_dispatch()
		dispatch.proxy["BOOM"] = function() error("kaput") end

		assert.has_no.errors(function()
			dispatch.received_from_proxy(5001, "BOOM", {})
		end)
		assert.truthy(logged[1]:match("kaput"))
		assert.truthy(logged[1]:find("^%[ERROR%] .*proxy handler BOOM failed"))
	end)

	it("ignores what has no handler, saying so only in Debug Mode", function()
		local dispatch = fresh_dispatch()
		assert.is_nil(dispatch.execute_command("Nothing_Here", {}))
		assert.is_nil(dispatch.property_changed("No Such Row", "x"))
		assert.is_nil(dispatch.received_from_proxy(5001, "NOPE", {}))
		assert.same({}, logged)

		log.set_debug(true)
		dispatch.execute_command("Nothing Here", {})
		assert.truthy(logged[#logged]:find("no command handler for Nothing_Here", 1, true))
	end)

	it("installs the entry points into an environment; OnPropertyChanged reads the value from its Properties", function()
		local dispatch = fresh_dispatch()
		local env = { Properties = { ["Debug Mode"] = "On" } }
		local got = {}
		dispatch.properties["Debug_Mode"] = function(value) got[#got + 1] = value end
		dispatch.commands["Example_Action"] = function() got[#got + 1] = "action" end
		dispatch.proxy["OFF"] = function(binding) got[#got + 1] = binding end

		dispatch.install(env)
		env.OnPropertyChanged("Debug Mode")
		env.ExecuteCommand("LUA_ACTION", { ACTION = "Example Action" })
		env.ReceivedFromProxy(5001, "OFF", {})

		assert.same({ "On", "action", 5001 }, got)
	end)

	it("replays every property through its handler (late init)", function()
		local dispatch = fresh_dispatch()
		local got = {}
		dispatch.properties["Debug_Mode"] = function(value) got["Debug Mode"] = value end
		dispatch.properties["Driver_Version"] = function(value) got["Driver Version"] = value end

		dispatch.replay_properties({ ["Debug Mode"] = "On", ["Driver Version"] = "12", ["Unhandled"] = "x" })
		dispatch.replay_properties(nil)

		assert.same({ ["Debug Mode"] = "On", ["Driver Version"] = "12" }, got)
	end)

	-- docs/v1-design.md section 9.2: two proxies in one driver both send ON,
	-- OFF and TOGGLE, so proxy handlers are chosen by binding first.
	describe("a handler table per binding", function()
		it("binding(id) makes the table on first use and gives the same one back, however the number is written",
			function()
				local dispatch = fresh_dispatch()
				local fan = dispatch.binding(5001)
				assert.same({}, fan)
				assert.equal(fan, dispatch.binding(5001))
				assert.equal(fan, dispatch.binding("5001"))
				assert.are_not.equal(fan, dispatch.binding(5002))
				assert.are_not.equal(fan, dispatch.proxy)
				assert.same({}, dispatch.proxy, "the command-only table is another thing")
			end)

		it("binding(id) refuses what is no number, where it is written", function()
			local dispatch = fresh_dispatch()
			local ok, err = pcall(dispatch.binding, "fan")
			assert.is_false(ok)
			assert.truthy(tostring(err):find("a binding id is a number, got fan", 1, true))
			assert.has_error(function() dispatch.binding(nil) end)
			assert.has_error(function() dispatch.binding({}) end)
		end)

		it("sends the same command name on two bindings to each binding's own handler", function()
			local dispatch = fresh_dispatch()
			local got = {}
			dispatch.binding(5001)["ON"] = function(binding, params) got[#got + 1] = { "fan", binding, params } end
			dispatch.binding(5002)["ON"] = function(binding, params) got[#got + 1] = { "light", binding, params } end

			dispatch.received_from_proxy(5002, "ON", { X = "1" })
			dispatch.received_from_proxy(5001, "ON", nil)
			dispatch.received_from_proxy("5002", "ON", {})

			assert.same({ { "light", 5002, { X = "1" } }, { "fan", 5001, {} }, { "light", "5002", {} } }, got,
				"the binding as it came, and {} for no params")
		end)

		it("finds a handler registered after the first message, and one replaced", function()
			local dispatch = fresh_dispatch()
			local got = {}
			assert.is_nil(dispatch.received_from_proxy(5002, "ON", {}))
			dispatch.binding(5002)["ON"] = function() got[#got + 1] = "first" end
			dispatch.received_from_proxy(5002, "ON", {})
			dispatch.binding(5002)["ON"] = function() got[#got + 1] = "second" end
			dispatch.received_from_proxy(5002, "ON", {})
			assert.same({ "first", "second" }, got)
		end)

		it("looks only in the binding's table once it has one: the command-only table is no fallback for it", function()
			local dispatch = fresh_dispatch()
			local got = {}
			dispatch.proxy["ON"] = function() got[#got + 1] = "command-only ON" end
			dispatch.proxy["OFF"] = function() got[#got + 1] = "command-only OFF" end
			dispatch.binding(5001)["ON"] = function() got[#got + 1] = "5001 ON" end

			dispatch.received_from_proxy(5001, "ON", {})
			assert.is_nil(dispatch.received_from_proxy(5001, "OFF", {}))

			assert.same({ "5001 ON" }, got)
		end)

		it("falls back to the command-only table for a binding without a table: a one-proxy driver is unchanged", function()
			local dispatch = fresh_dispatch()
			local got = {}
			dispatch.proxy["ON"] = function(binding, params) got[#got + 1] = { binding, params } end
			dispatch.binding(5002)["ON"] = function() got[#got + 1] = "light" end

			dispatch.received_from_proxy(5001, "ON", { X = "1" })
			dispatch.received_from_proxy(9999, "ON", nil)
			dispatch.received_from_proxy(5002, "ON", {})

			assert.same({ { 5001, { X = "1" } }, { 9999, {} }, "light" }, got)
		end)

		it("drops what no table handles with one debug line naming the binding and the command, an error never", function()
			local dispatch = fresh_dispatch()
			dispatch.binding(5001)["ON"] = function() end

			-- Unknown binding, and a known one without the command.
			assert.is_nil(dispatch.received_from_proxy(9999, "ON", {}))
			assert.is_nil(dispatch.received_from_proxy(5001, "CYCLE_SPEED_UP", {}))
			assert.same({}, logged, "silent unless Debug Mode is on")

			log.set_debug(true)
			assert.is_nil(dispatch.received_from_proxy(9999, "ON", {}))
			assert.equal(2, #logged)
			assert.truthy(logged[1]:find("ReceivedFromProxy 9999 ON", 1, true))
			assert.truthy(logged[2]:find("no proxy handler for ON on binding 9999", 1, true))
			assert.is_nil(dispatch.received_from_proxy(5001, "CYCLE_SPEED_UP", {}))
			assert.truthy(logged[4]:find("no proxy handler for CYCLE_SPEED_UP on binding 5001", 1, true))
		end)

		it("returns the result of a binding's handler", function()
			local dispatch = fresh_dispatch()
			dispatch.binding(5002)["ASK"] = function() return 42 end
			assert.equal(42, dispatch.received_from_proxy(5002, "ASK", {}))
		end)

		it("contains the errors of a binding's handler as of any other, and keeps routing", function()
			local dispatch = fresh_dispatch()
			local got = {}
			dispatch.binding(5002)["BOOM"] = function() error("kaput") end
			dispatch.binding(5002)["FINE"] = function() got[#got + 1] = "fine" end

			assert.has_no.errors(function()
				dispatch.received_from_proxy(5002, "BOOM", {})
			end)
			dispatch.received_from_proxy(5002, "FINE", {})

			assert.equal(1, #logged)
			assert.truthy(logged[1]:find("^%[ERROR%] .*proxy handler BOOM failed: .*kaput"))
			assert.same({ "fine" }, got)
		end)

		it("is the route install() wires into ReceivedFromProxy", function()
			local dispatch = fresh_dispatch()
			local env = { Properties = {} }
			local got = {}
			dispatch.binding(5002)["ON"] = function(binding) got[#got + 1] = "light " .. binding end
			dispatch.binding(5001)["ON"] = function(binding) got[#got + 1] = "fan " .. binding end

			dispatch.install(env)
			env.ReceivedFromProxy(5001, "ON", {})
			env.ReceivedFromProxy(5002, "ON", {})

			assert.same({ "fan 5001", "light 5002" }, got)
		end)

		it("keeps a fresh module's tables to itself: reloading the module forgets them", function()
			local first = fresh_dispatch()
			first.binding(5001)["ON"] = function() end
			local second = fresh_dispatch()
			assert.same({}, second.binding(5001))
			assert.is_function(first.binding(5001)["ON"])
		end)
	end)
end)
