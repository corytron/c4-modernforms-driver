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
end)
