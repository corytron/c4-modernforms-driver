-- The Modern Forms Fan driver as the scaffold leaves it (docs/scaffold-design.md,
-- section 7): its driver.xml, its two rows, and the dev loop's hook, which
-- has the Hue Bridge driver's shape. The checks every driver passes are in
-- drivers_spec.lua.

local fake = require("helpers.fake_c4")
local log = require("common.log")

local DRIVER = "modernforms_fan"
local DEV_SERVER = "192.0.2.7:8081"

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

local function delays(c4)
	local out = {}
	for _, timer in ipairs(c4.active_timers()) do out[#out + 1] = timer.delay end
	table.sort(out)
	return out
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

describe("Modern Forms Fan driver", function()
	before_each(quiet)
	after_each(function()
		log.set_debug(false)
		log.set_prefix(nil)
	end)

	describe("driver.xml", function()
		local xml = read("src/" .. DRIVER .. "/driver.xml")
		local bare = xml:gsub("<!%-%-.-%-%->", "")

		it("is the scaffold: a combo driver named Modern Forms Fan, with 3.3.0 as a stand-in minimum OS", function()
			assert.equal("Modern Forms Fan", field(bare, "name"))
			assert.equal("Modern Forms", field(bare, "manufacturer"))
			assert.equal("true", field(bare, "combo"))
			assert.truthy(bare:find('<proxy name="Modern Forms Fan">modernforms_fan</proxy>', 1, true))
			assert.equal("3.3.0", field(bare, "minimum_os_version"))
			assert.truthy(xml:find("stand-in", 1, true), "the comment says the v1 research decides it")
		end)

		it("has no connections, capabilities, events, actions, commands, conditionals, icons or proxy binding yet",
			function()
				for _, tag in ipairs({ "connections", "capabilities", "events", "actions", "commands", "conditionals",
					"small", "large" }) do
					assert.is_nil(bare:find("<" .. tag, 1, true), tag)
				end
				assert.is_nil(bare:find("proxybindingid", 1, true), "the combo driver's proxy entry binds nothing")
			end)

		it("declares Driver Version and Debug Mode, and Dev Server in development builds only", function()
			local names = {}
			for body in bare:gmatch("<property>(.-)</property>") do names[#names + 1] = field(body, "name") end
			assert.same({ "Driver Version", "Debug Mode", "Dev Server" }, names)
			local block = xml:match("<!%-%- DEV%-ONLY BEGIN.-<!%-%- DEV%-ONLY END %-%->")
			assert.truthy(block and block:find("<name>Dev Server</name>", 1, true))
		end)
	end)

	describe("startup", function()
		it("does nothing before late init, then shows its version with Debug Mode off", function()
			local env, c4 = fake.load_driver(DRIVER, {})
			env.OnDriverInit("DIT_ADDING")
			-- UpdateProperty, SetTimer and GetDriverConfigInfo are not safe
			-- before late init [API 22/_25.2].
			assert.same({}, c4.calls)
			env.OnDriverLateInit("DIT_ADDING")
			assert.equal("1", env.Properties["Driver Version"])
			assert.same({ { "Driver Version", "1" } }, c4.calls_to("UpdateProperty"))
			assert.is_false(log.enabled("debug"))
			assert.same({}, c4.active_timers())
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

		it("looks at its version again at 5 s and 10 s while Director answers nothing", function()
			local env, c4 = fake.load_driver(DRIVER, {})
			c4.config_info.version = ""
			env.OnDriverLateInit("DIT_ADDING")
			assert.equal("", env.Properties["Driver Version"])
			assert.same({ 5000 }, delays(c4))
			c4.fire_timers()
			assert.same({ 10000 }, delays(c4))
			c4.config_info.version = "7"
			c4.fire_timers()
			assert.equal("7", env.Properties["Driver Version"])
			assert.same({}, delays(c4), "found: no third look")
		end)

		it("gives up after the third look", function()
			local env, c4 = fake.load_driver(DRIVER, {})
			c4.config_info.version = ""
			env.OnDriverLateInit("DIT_ADDING")
			c4.fire_timers()
			c4.fire_timers()
			assert.same({}, delays(c4))
			assert.equal("", env.Properties["Driver Version"])
			assert.equal(3, #c4.calls_to("GetDriverConfigInfo"))
		end)

		it("shows the build's own stamp when Director answers the lookup with nothing", function()
			package.preload["common.build_version"] = function() return "196" end
			package.loaded["common.build_version"] = nil
			local ok, err = pcall(function()
				local env, c4 = fake.load_driver(DRIVER, {})
				c4.config_info.version = ""
				env.OnDriverLateInit("DIT_ADDING")
				assert.equal("196", env.Properties["Driver Version"])
				assert.same({}, delays(c4))
			end)
			package.preload["common.build_version"] = nil
			package.loaded["common.build_version"] = nil
			assert(ok, err)
		end)

		it("keeps one look pending when late init runs again, and stops it on destroy", function()
			local env, c4 = fake.load_driver(DRIVER, {})
			c4.config_info.version = ""
			env.OnDriverLateInit("DIT_STARTUP")
			c4.fire_timers()
			assert.same({ 10000 }, delays(c4))
			env.OnDriverLateInit("DIT_UPDATING")
			assert.same({ 5000 }, delays(c4), "the pending look was replaced")
			env.OnDriverDestroyed("DIT_UPDATING")
			assert.same({}, delays(c4))
			c4.config_info.version = "7"
			assert.equal(0, c4.fire_timers())
			assert.equal("", env.Properties["Driver Version"], "no stray write after the destroy")
			assert.has_no.errors(function() env.OnDriverDestroyed("DIT_UPDATING") end, "nothing pending is fine")
		end)

		it("ignores commands, proxy messages and properties it has no handler for", function()
			local env, c4 = fake.load_driver(DRIVER, {})
			env.OnDriverLateInit("DIT_STARTUP")
			c4.calls = {}
			local lines = capture_log()
			assert.has_no.errors(function()
				env.ExecuteCommand("LUA_ACTION", { ACTION = "Some Action" })
				env.ExecuteCommand("DEV_RELOAD", {})
				env.ReceivedFromProxy(5001, "ON", {})
				env.OnPropertyChanged("Driver Version")
			end)
			assert.same({}, c4.calls)
			assert.same({}, lines)
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
					assert.same({}, c4.active_timers())
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
			assert.truthy(printed[1]:find("^%[ERROR%] Modern Forms Fan: dev loop failed to load: .*boom"), printed[1])
		end)

		it("comes through the dev loop's reload: the loop is asked for the same host again, nothing doubles", function()
			local stub = stub_devloop()
			with_devloop(function() return stub end, function()
				local env, c4 = fake.load_driver(DRIVER, { ["Dev Server"] = DEV_SERVER })
				c4.config_info.version = ""
				env.OnDriverLateInit("DIT_STARTUP")
				assert.same({ 5000 }, delays(c4), "a version look pending when the reload comes")
				-- The reload (common/devloop.lua): OnDriverDestroyed, the driver's
				-- modules cleared but the loop's own, driver.lua again, both inits.
				env.OnDriverDestroyed("DIT_UPDATING")
				for name in pairs(package.loaded) do
					if name:match("^common%.") and name ~= "common.log" and name ~= "common.devloop" then
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
				assert.same({ 5000 }, delays(c4), "one version look, the new code's")
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
				local repeating = {}
				for _, args in ipairs(c4.calls_to("SetTimer")) do
					if args[2] == true then repeating[#repeating + 1] = args[1] end
				end
				assert.same({ devloop.INTERVAL_MS }, repeating, "one repeating poll timer")
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
