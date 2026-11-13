-- Routes DriverWorks entry points to small handler tables, so a driver
-- registers one function per command/property instead of a long if/else.
-- Ported from the owner's Hue project (corytron/c4-hue-driver,
-- src/common/dispatch.lua) and extended here with one handler table per proxy
-- binding (docs/v1-design.md section 9.2); the rest is unchanged.
--
--   dispatch.actions["Some_Action"] = function(params) ... end         -- ExecuteCommand LUA_ACTION "Some Action" only
--   dispatch.commands["Some_Command"] = function(params) ... end       -- ExecuteCommand "Some Command" (programming,
--                                                                       -- other drivers' C4:SendToDevice)
--   dispatch.properties["Debug_Mode"] = function(value) ... end        -- OnPropertyChanged("Debug Mode")
--   dispatch.binding(5002)["ON"] = function(binding, params) ... end   -- ReceivedFromProxy(5002, "ON", params)
--   dispatch.proxy["ON"] = function(binding, params) ... end           -- the same for a binding with no table
--
-- Names of actions and properties have whitespace replaced by "_" so they
-- work as Lua keys; a proxy command is keyed by its name as it arrives.
--
-- Proxy messages are routed by binding first: two proxies in one driver both
-- send ON, OFF and TOGGLE, and Director hands the binding to the entry point
-- (API 25_proxy/_5-ReceivedFromProxy.md), so each proxy, and each Button Link
-- (they send DO_PUSH and the like on their own bindings), registers in the
-- table of its own binding. Once a binding has a table, only that table is
-- looked at for its messages. A binding without one falls back to
-- dispatch.proxy, keyed by command alone, so a driver with one proxy that
-- never asks for a binding table works as it always did. A driver that mixes
-- the two for one binding (a module that registers through dispatch.binding
-- and the driver through dispatch.proxy) must register all of that binding's
-- handlers through dispatch.binding: the table shadows the fallback.

local log = require("common.log")

local dispatch = {
	actions = {},
	commands = {},
	properties = {},
	proxy = {},
}

-- binding id (a number) -> that binding's handler table, made by dispatch.binding.
local by_binding = {}

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

-- The handler table of one binding, made on first use: the same table for the
-- same number however it is written (5002, "5002"). Handlers keep the
-- signature fn(binding, params), the binding as it arrived. A binding that is
-- no number raises here, at load, where the mistake is: a table filed under
-- nothing would never be asked for.
function dispatch.binding(id)
	local n = tonumber(id)
	if n == nil then
		error("dispatch.binding: a binding id is a number, got " .. tostring(id), 2)
	end
	local handlers = by_binding[n]
	if handlers == nil then
		handlers = {}
		by_binding[n] = handlers
	end
	return handlers
end

-- Composer actions arrive as LUA_ACTION with the action name in ACTION, and
-- only that way reach dispatch.actions: a bare command of the same name (a
-- stray or colliding SendToDevice from another driver) does not run an
-- action (#214). ExecuteCommand carries no sender [API
-- 5_director_command/_1-ExecuteCommand.md], so this is no authentication:
-- it keeps actions to the path Composer uses. A LUA_ACTION with no action of
-- that name falls back to dispatch.commands.
function dispatch.execute_command(command, params)
	params = type(params) == "table" and params or {}
	if command == "LUA_ACTION" and params.ACTION then
		local name = key(tostring(params.ACTION))
		params.ACTION = nil
		log.debug("ExecuteCommand LUA_ACTION %s", name)
		local fn = dispatch.actions[name]
		if fn ~= nil then
			return call("action", name, fn, params)
		end
		return call("command", name, dispatch.commands[name], params)
	end
	local name = key(tostring(command))
	log.debug("ExecuteCommand %s", name)
	return call("command", name, dispatch.commands[name], params)
end

function dispatch.property_changed(property, value)
	local name = key(property)
	log.debug("OnPropertyChanged %s = %s", name, tostring(value))
	return call("property", name, dispatch.properties[name], value or "")
end

-- The binding's own table when it has one, else the command-only table. A
-- message nobody handles (a command the binding's table lacks, a binding no
-- table knows) ends in one debug line that names both; it is no error.
function dispatch.received_from_proxy(binding, command, params)
	log.debug("ReceivedFromProxy %s %s", tostring(binding), tostring(command))
	local handlers = by_binding[tonumber(binding)] or dispatch.proxy
	local fn = handlers[command]
	if type(fn) ~= "function" then
		log.debug("no proxy handler for %s on binding %s", tostring(command), tostring(binding))
		return nil
	end
	return call("proxy", command, fn, binding, params or {})
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
