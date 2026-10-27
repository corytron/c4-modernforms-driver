-- Routes DriverWorks entry points to small handler tables, so a driver
-- registers one function per command/property instead of a long if/else.
-- Ported from the owner's Hue project (corytron/c4-hue-driver,
-- src/common/dispatch.lua); the code is unchanged.
--
--   dispatch.commands["Some_Action"] = function(params) ... end   -- ExecuteCommand, LUA_ACTION "Some Action"
--   dispatch.properties["Debug_Mode"] = function(value) ... end   -- OnPropertyChanged("Debug Mode")
--   dispatch.proxy["ON"] = function(binding, params) ... end      -- ReceivedFromProxy(binding, "ON", params)
--
-- Names have whitespace replaced by "_" so they work as Lua keys. Proxy
-- commands are keyed by command alone: a driver with two proxies tells
-- them apart by the binding its handler gets.

local log = require("common.log")

local dispatch = {
	commands = {},
	properties = {},
	proxy = {},
}

local function key(name)
	return (string.gsub(name or "", "%s+", "_"))
end

local function call(kind, name, fn, ...)
	if type(fn) ~= "function" then
		log.debug("no %s handler for %s", kind, tostring(name))
		return nil
	end
	local ok, result = pcall(fn, ...)
	if not ok then
		log.error("%s handler %s failed: %s", kind, tostring(name), tostring(result))
		return nil
	end
	return result
end

function dispatch.execute_command(command, params)
	params = params or {}
	-- Composer actions arrive as LUA_ACTION with the action name in ACTION.
	if command == "LUA_ACTION" and params.ACTION then
		command = params.ACTION
		params.ACTION = nil
	end
	local name = key(command)
	log.debug("ExecuteCommand %s", name)
	return call("command", name, dispatch.commands[name], params)
end

function dispatch.property_changed(property, value)
	local name = key(property)
	log.debug("OnPropertyChanged %s = %s", name, tostring(value))
	return call("property", name, dispatch.properties[name], value or "")
end

function dispatch.received_from_proxy(binding, command, params)
	log.debug("ReceivedFromProxy %s %s", tostring(binding), tostring(command))
	return call("proxy", command, dispatch.proxy[command], binding, params or {})
end

-- Wire the DriverWorks globals to this dispatcher. `env` is the global table
-- in production and a fake in tests.
function dispatch.install(env)
	env.ExecuteCommand = dispatch.execute_command
	env.ReceivedFromProxy = dispatch.received_from_proxy
	env.OnPropertyChanged = function(property)
		local props = env.Properties or {}
		return dispatch.property_changed(property, props[property])
	end
end

-- Re-run every property handler, used at late init so state matches Composer.
function dispatch.replay_properties(props)
	for property, value in pairs(props or {}) do
		dispatch.property_changed(property, value)
	end
end

return dispatch
