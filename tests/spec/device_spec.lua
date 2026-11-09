-- common.device on the fake runtime by itself: the module's own contract,
-- the hooks, the handlers it registers, and what each block does with the
-- runtime. Ported from the Hue project's spec with the blocks the port
-- stripped (the bridge binding, the dev loop's device side) taken out and
-- pinned as absent.

local fake = require("helpers.fake_c4")
local log = require("common.log")

local function quiet()
	log.sink = function() end
end

-- Every line the logger emits from here on.
local function capture_log()
	local lines = {}
	log.sink = function(line) lines[#lines + 1] = line end
	return lines
end

-- A fresh instance on a fresh runtime: common.device and common.dispatch
-- reloaded, so the handlers it registers land in this test's dispatch. The
-- hooks answer from `st`, which a test changes as the driver would.
-- opts.proxy_binding and opts.settings go to device.new.
local function new_device(opts)
	opts = opts or {}
	package.loaded["common.device"] = nil
	package.loaded["common.dispatch"] = nil
	local c4, env = fake.install_c4({ ["Debug Mode"] = "Off", ["Driver Version"] = "" })
	local device = require("common.device")
	local dispatch = require("common.dispatch")
	local st = { on = nil, buttons = {} }
	local dev = device.new({ prefix = opts.prefix or "Test Device", proxy_binding = opts.proxy_binding,
		settings = opts.settings })
	dev.is_on = function() return st.on end
	dev.button_action = function(button, action) st.buttons[#st.buttons + 1] = { button, action } end
	return dev, c4, env, dispatch, st, device
end

-- Every SendToProxy with that command, as { binding, params }.
local function proxied(c4, command)
	local out = {}
	for _, args in ipairs(c4.calls_to("SendToProxy")) do
		if args[2] == command then out[#out + 1] = { args[1], args[3] } end
	end
	return out
end

local function delays(c4)
	local out = {}
	for _, timer in ipairs(c4.active_timers()) do out[#out + 1] = timer.delay end
	table.sort(out)
	return out
end

describe("common.device", function()
	before_each(quiet)
	after_each(function()
		log.set_debug(false)
		log.set_prefix(nil)
	end)

	describe("construction", function()
		it("sets the log prefix", function()
			new_device()
			local lines = capture_log()
			log.warn("hello")
			assert.same({ "[WARN] Test Device: hello" }, lines)
		end)

		it("leaves the dev loop alone: no module loaded, no DEV_RELOAD, log.sink untouched (stripped in the port)",
			function()
				local sink = function() end
				log.sink = sink
				local real = package.loaded["common.devloop"]
				package.loaded["common.devloop"] = nil
				package.preload["common.devloop"] = function() error("common.device must not load the dev loop") end
				local ok, err = pcall(function()
					local dev, _, _, dispatch = new_device()
					assert.is_nil(package.loaded["common.devloop"])
					assert.is_nil(dispatch.commands["DEV_RELOAD"])
					assert.equal(sink, log.sink)
					assert.is_nil(dev.devloop)
					assert.is_nil(dev.flush_log)
				end)
				package.preload["common.devloop"] = nil
				package.loaded["common.devloop"] = real
				assert(ok, err)
			end)

		it("has none of the Hue bridge plumbing the port stripped", function()
			local dev, _, _, _, _, device = new_device()
			for _, name in ipairs({ "bound_bridge", "send", "schedule_recheck", "cancel_recheck", "goodbye" }) do
				assert.is_nil(dev[name], name)
			end
			assert.is_nil(device.BRIDGE_BINDING)
		end)

		it("works without options: no prefix, no keypad settings", function()
			package.loaded["common.device"] = nil
			package.loaded["common.dispatch"] = nil
			fake.install_c4({})
			local dev = require("common.device").new()
			local dispatch = require("common.dispatch")
			local lines = capture_log()
			log.warn("plain")
			assert.same({ "[WARN] plain" }, lines)
			assert.is_nil(dispatch.proxy["SET_HOLD_RATE_UP"])
			assert.is_function(dev.prop)
		end)
	end)

	describe("properties and notifies", function()
		it("prop writes strings, an empty one for nil", function()
			local dev, _, env = new_device()
			dev.prop("Status", 5)
			dev.prop("Online", nil)
			assert.equal("5", env.Properties["Status"])
			assert.equal("", env.Properties["Online"])
		end)

		it("notify sends to the proxy binding and dumps the parameters only in Debug Mode", function()
			local dev, c4 = new_device()
			local lines = capture_log()
			dev.notify("LIGHT_BRIGHTNESS_CHANGED", { LIGHT_BRIGHTNESS_CURRENT = 40 })
			assert.same({ { 5001, { LIGHT_BRIGHTNESS_CURRENT = 40 } } }, proxied(c4, "LIGHT_BRIGHTNESS_CHANGED"))
			assert.same({}, lines, "nothing built for a line nobody sees")
			log.set_debug(true)
			dev.notify("LIGHT_BRIGHTNESS_CHANGING", { RATE = 0, LIGHT_BRIGHTNESS_TARGET = 75, LIGHT_BRIGHTNESS_CURRENT = 40 })
			assert.same({ "[DEBUG] Test Device: -> proxy LIGHT_BRIGHTNESS_CHANGING"
				.. " LIGHT_BRIGHTNESS_CURRENT=40 LIGHT_BRIGHTNESS_TARGET=75 RATE=0" }, lines, "sorted keys")
			dev.notify("SYNC", nil)
			assert.equal("[DEBUG] Test Device: -> proxy SYNC ", lines[2])
		end)

		it("device_id is a string, result logs always and fills Last Action", function()
			local dev, _, env = new_device()
			assert.equal("15", dev.device_id())
			local lines = capture_log()
			dev.result("Renamed device 7 to Example Room Fan")
			assert.same({ "Test Device: Renamed device 7 to Example Room Fan" }, lines)
			assert.equal("Renamed device 7 to Example Room Fan", fake.last_action(env))
		end)
	end)

	describe("proxy lookup", function()
		it("proxy_id is the first consumer on 5001, nil without one", function()
			local dev, c4 = new_device()
			c4.GetBoundConsumerDevices = function(_, id, binding)
				assert.equal(15, id)
				assert.equal(5001, binding)
				return { [3001] = "Example Light" }
			end
			assert.equal(3001, dev.proxy_id())
			c4.GetBoundConsumerDevices = function() return nil end
			assert.is_nil(dev.proxy_id())
		end)
	end)

	describe("Driver Version and Debug Mode", function()
		it("Driver_Version writes Director's version; show_driver_version looks again twice while it is empty", function()
			local dev, c4, env, dispatch = new_device()
			dispatch.property_changed("Driver Version", "")
			assert.equal("1", env.Properties["Driver Version"])
			c4.config_info.version = ""
			dev.show_driver_version(1)
			assert.equal("", env.Properties["Driver Version"])
			assert.same({ 5000 }, delays(c4))
			c4.fire_timers()
			assert.same({ 10000 }, delays(c4))
			c4.config_info.version = "7"
			c4.fire_timers()
			assert.equal("7", env.Properties["Driver Version"])
			assert.same({}, delays(c4), "found: no third look")
		end)

		it("gives up after the third look and falls back to the build's own stamp", function()
			local dev, c4, env = new_device()
			c4.config_info.version = ""
			dev.show_driver_version(1)
			c4.fire_timers()
			c4.fire_timers()
			assert.same({}, delays(c4))
			assert.equal("", env.Properties["Driver Version"])

			package.preload["common.build_version"] = function() return "196" end
			package.loaded["common.build_version"] = nil
			local ok, err = pcall(function()
				local dev2, c42, env2 = new_device()
				c42.config_info.version = ""
				dev2.show_driver_version(1)
				assert.equal("196", env2.Properties["Driver Version"])
				assert.same({}, delays(c42))
			end)
			package.preload["common.build_version"] = nil
			package.loaded["common.build_version"] = nil
			assert(ok, err)
		end)

		it("a second show_driver_version starts over: one look pending, never two chains", function()
			local dev, c4 = new_device()
			c4.config_info.version = ""
			dev.show_driver_version(1)
			c4.fire_timers()
			assert.same({ 10000 }, delays(c4))
			dev.show_driver_version(1) -- late init run again
			assert.same({ 5000 }, delays(c4), "the pending look was replaced")
		end)

		it("cancel_timers stops the pending look (OnDriverDestroyed)", function()
			local dev, c4, env = new_device()
			c4.config_info.version = ""
			dev.show_driver_version(1)
			assert.same({ 5000 }, delays(c4))
			dev.cancel_timers()
			assert.same({}, delays(c4))
			c4.config_info.version = "7"
			assert.equal(0, c4.fire_timers())
			assert.equal("", env.Properties["Driver Version"], "no stray write after the destroy")
			assert.has_no.errors(dev.cancel_timers, "nothing pending is fine")
		end)

		it("Debug_Mode On enables debug lines, anything else keeps them off", function()
			local _, _, _, dispatch = new_device()
			dispatch.property_changed("Debug Mode", "On")
			assert.is_true(log.enabled("debug"))
			dispatch.property_changed("Debug Mode", "Off")
			assert.is_false(log.enabled("debug"))
			dispatch.property_changed("Debug Mode", "on")
			assert.is_false(log.enabled("debug"), "only the item Composer offers")
		end)
	end)

	describe("before late init", function()
		it("after_late_init buffers in order until late_init applies them, then passes straight through", function()
			local dev = new_device()
			local seen = {}
			local a = dev.after_late_init("A", function(params) seen[#seen + 1] = "A:" .. params.n end)
			local b = dev.after_late_init("B", function(params) seen[#seen + 1] = "B:" .. params.n end)
			a({ n = "1" })
			b({ n = "2" })
			a({ n = "3" })
			assert.same({}, seen)
			dev.late_init()
			assert.same({ "A:1", "B:2", "A:3" }, seen)
			assert.equal("done", a({ n = "4" }) or "done")
			assert.same({ "A:1", "B:2", "A:3", "A:4" }, seen)
		end)

		it("a buffered handler that fails is logged and does not stop the rest", function()
			local dev = new_device()
			local lines = capture_log()
			local seen = {}
			dev.after_late_init("BAD", function() error("boom") end)({})
			dev.after_late_init("GOOD", function() seen[#seen + 1] = "good" end)({})
			dev.late_init()
			assert.same({ "good" }, seen)
			assert.equal(1, #lines)
			assert.truthy(lines[1]:find("^%[ERROR%] Test Device: buffered BAD failed: .*boom"))
		end)

		it("keeps at most 200 waiting and drops the next with a warning", function()
			local dev = new_device()
			local seen = 0
			local handler = dev.after_late_init("MSG", function() seen = seen + 1 end)
			for _ = 1, 200 do handler({}) end
			local lines = capture_log()
			handler({})
			assert.same({ "[WARN] Test Device: MSG before late init dropped: 200 already waiting" }, lines)
			dev.late_init()
			assert.equal(200, seen)
		end)
	end)

	describe("binding changes before late init", function()
		-- A handler through binding_changed that records every call it gets.
		local function recorder(dev)
			local seen = {}
			local handler = dev.binding_changed(function(id, class, bound, other, other_binding)
				seen[#seen + 1] = { id, class, bound, other, other_binding }
			end)
			return handler, seen
		end

		it("wait until replay_bindings, the latest call per binding in arrival order, then pass straight through", function()
			local dev, c4 = new_device()
			local handler, seen = recorder(dev)
			c4.calls = {}
			handler(200, "BUTTON_LINK", true, 77, 1)
			handler(1, "EXAMPLE_CLASS", true, 16, 1)
			handler(200, "BUTTON_LINK", false, 77, 1)
			assert.same({}, seen)
			assert.same({}, c4.calls, "nothing touches Director before late init")
			dev.late_init()
			assert.same({}, seen, "late_init applies the buffered messages only; the driver acts first")
			dev.replay_bindings()
			assert.same({ { 1, "EXAMPLE_CLASS", true, 16, 1 }, { 200, "BUTTON_LINK", false, 77, 1 } }, seen,
				"one call per binding, the latest; the older one for 200 says nothing the latest does not")
			handler(201, "BUTTON_LINK", true, 78, 1)
			assert.same({ 201, "BUTTON_LINK", true, 78, 1 }, seen[3], "after late init: at once")
			dev.replay_bindings()
			assert.equal(3, #seen, "nothing is replayed twice")
		end)

		it("replays every waiting call, whatever its binding (no bridge to recognise any more)", function()
			for _, call in ipairs({ { 1, "EXAMPLE_CLASS", true, 15, 1 }, { 1, "EXAMPLE_CLASS", false, 15, 1 } }) do
				local dev = new_device()
				local handler, seen = recorder(dev)
				handler(unpack(call))
				dev.late_init()
				dev.replay_bindings()
				assert.same({ call }, seen)
			end
		end)

		it("a replayed call that fails is logged and does not stop the rest", function()
			local dev = new_device()
			local seen = {}
			local handler = dev.binding_changed(function(id)
				if id == 200 then error("boom") end
				seen[#seen + 1] = id
			end)
			handler(200, "BUTTON_LINK", true, 77, 1)
			handler(201, "BUTTON_LINK", true, 78, 1)
			dev.late_init()
			local lines = capture_log()
			dev.replay_bindings()
			assert.same({ 201 }, seen)
			assert.equal(1, #lines)
			assert.truthy(lines[1]:find(
				"^%[ERROR%] Test Device: OnBindingChanged on binding 200 from before late init failed: .*boom"))
		end)
	end)

	describe("keypad LEDs", function()
		local INFO_OFF = {
			{ 5001, { BUTTON_ID = 0, ON_COLOR = "0000ff", OFF_COLOR = "000000", CURRENT_COLOR = "000000" } },
			{ 5001, { BUTTON_ID = 1, ON_COLOR = "000000", OFF_COLOR = "0000ff", CURRENT_COLOR = "0000ff" } },
			{ 5001, { BUTTON_ID = 2, ON_COLOR = "0000ff", OFF_COLOR = "000000", CURRENT_COLOR = "000000" } },
		}

		it("update_leds waits for a known on state, sends on a change or when forced, with BUTTON_INFO", function()
			local dev, c4, _, _, st = new_device()
			dev.update_leds()
			dev.update_leds(true)
			assert.equal(0, #c4.calls_to("SendToProxy"), "nothing while is_on() is nil")
			st.on = false
			dev.update_leds()
			assert.same({ { 200, { STATE = false } }, { 201, { STATE = false } }, { 202, { STATE = false } } },
				proxied(c4, "MATCH_LED_STATE"))
			assert.same(INFO_OFF, proxied(c4, "BUTTON_INFO"))
			dev.update_leds()
			assert.equal(3, #proxied(c4, "MATCH_LED_STATE"), "unchanged: nothing")
			dev.update_leds(true)
			assert.equal(6, #proxied(c4, "MATCH_LED_STATE"), "forced: again")
			st.on = true
			dev.update_leds()
			local all = proxied(c4, "MATCH_LED_STATE")
			assert.same({ { 200, { STATE = true } }, { 201, { STATE = true } }, { 202, { STATE = true } } },
				{ all[7], all[8], all[9] })
			assert.equal("0000ff", proxied(c4, "BUTTON_INFO")[7][2].CURRENT_COLOR, "top lit while on")
		end)

		it("load_colors reads persisted overrides and ignores what is not a 6-digit hex colour", function()
			local dev, c4, _, _, st = new_device()
			c4.persist.button_0_on_color = "FF0000"
			c4.persist.button_1_off_color = "blue"
			dev.load_colors()
			st.on = true
			dev.update_leds()
			local info = proxied(c4, "BUTTON_INFO")
			assert.same({ BUTTON_ID = 0, ON_COLOR = "ff0000", OFF_COLOR = "000000", CURRENT_COLOR = "ff0000" }, info[1][2])
			assert.same({ BUTTON_ID = 1, ON_COLOR = "000000", OFF_COLOR = "0000ff", CURRENT_COLOR = "000000" }, info[2][2])
		end)

		it("REQUEST_BUTTON_COLORS on a link answers BUTTON_COLORS there, then MATCH_LED_STATE", function()
			local _, c4, _, dispatch, st = new_device()
			dispatch.received_from_proxy(201, "REQUEST_BUTTON_COLORS", {})
			assert.same({ { 201, { BUTTON_ID = 1, ON_COLOR = "000000", OFF_COLOR = "0000ff", CURRENT_COLOR = "0000ff" } } },
				proxied(c4, "BUTTON_COLORS"), "bottom lit while off")
			assert.same({ { 201, { STATE = false } } }, proxied(c4, "MATCH_LED_STATE"), "unknown reads as off")
			st.on = true
			dispatch.received_from_proxy("200", "REQUEST_BUTTON_COLORS", {})
			assert.equal("0000ff", proxied(c4, "BUTTON_COLORS")[2][2].CURRENT_COLOR)
			assert.same({ 200, { STATE = true } }, proxied(c4, "MATCH_LED_STATE")[2], "a string binding is fine")
		end)

		-- docs/v1-design.md section 9.2: the link commands are registered on the
		-- links, so on the proxy binding they find no handler (they used to reach
		-- one and be refused with a warning, when handlers were keyed by command).
		it("REQUEST_BUTTON_COLORS on the proxy binding is no link command: nothing answered, a debug line only", function()
			local _, c4, _, dispatch = new_device()
			local lines = capture_log()
			dispatch.received_from_proxy(5001, "REQUEST_BUTTON_COLORS", {})
			assert.equal(0, #c4.calls_to("SendToProxy"))
			assert.same({}, lines, "no handler, so no warning either")
			log.set_debug(true)
			dispatch.received_from_proxy(5001, "REQUEST_BUTTON_COLORS", {})
			assert.equal(0, #c4.calls_to("SendToProxy"))
			assert.truthy(lines[#lines]:find("no proxy handler for REQUEST_BUTTON_COLORS on binding 5001", 1, true))
		end)

		it("SET_BUTTON_COLOR persists a valid colour under either spelling, echoes it, and warns on a bad one", function()
			local _, c4, _, dispatch, st = new_device()
			st.on = true
			local lines = capture_log()
			dispatch.received_from_proxy(5001, "SET_BUTTON_COLOR", { BUTTON_ID = "2", ["OFF COLOR"] = "00FF00",
				ON_COLOR = "blue" })
			assert.equal("00ff00", c4.persist.button_2_off_color)
			assert.is_nil(c4.persist.button_2_on_color)
			assert.same({ { 202, { BUTTON_ID = 2, ON_COLOR = "0000ff", OFF_COLOR = "00ff00", CURRENT_COLOR = "0000ff" } } },
				proxied(c4, "BUTTON_COLORS"))
			assert.same({ { 5001, { BUTTON_ID = 2, ON_COLOR = "0000ff", OFF_COLOR = "00ff00", CURRENT_COLOR = "0000ff" } } },
				proxied(c4, "BUTTON_INFO"))
			assert.same({ '[WARN] Test Device: SET_BUTTON_COLOR: ON_COLOR "blue" is not a 6-digit hex colour' }, lines)

			dispatch.received_from_proxy(5001, "SET_BUTTON_COLOR", { BUTTON_ID = "7", ON_COLOR = "ffffff" })
			assert.equal("[WARN] Test Device: SET_BUTTON_COLOR without a known BUTTON_ID (7)", lines[2])
			assert.equal(1, #proxied(c4, "BUTTON_COLORS"))
		end)
	end)

	describe("keypad buttons", function()
		it("BUTTON_ACTION is echoed to the proxy and handed to the driver's machine", function()
			local _, c4, _, dispatch, st = new_device()
			dispatch.received_from_proxy(5001, "BUTTON_ACTION", { BUTTON_ID = "0", ACTION = "1" })
			dispatch.received_from_proxy(5001, "BUTTON_ACTION", { BUTTON_ID = "2", ACTION = "2" })
			assert.same({ { 5001, { BUTTON_ID = 0, ACTION = 1 } }, { 5001, { BUTTON_ID = 2, ACTION = 2 } } },
				proxied(c4, "BUTTON_ACTION"))
			assert.same({ { 0, 1 }, { 2, 2 } }, st.buttons)
		end)

		it("BUTTON_ACTION without its ids warns and reaches nothing", function()
			local _, c4, _, dispatch, st = new_device()
			local lines = capture_log()
			dispatch.received_from_proxy(5001, "BUTTON_ACTION", { BUTTON_ID = "0" })
			assert.same({ "[WARN] Test Device: BUTTON_ACTION without BUTTON_ID/ACTION" }, lines)
			assert.same({}, st.buttons)
			assert.equal(0, #c4.calls_to("SendToProxy"))
		end)

		it("DO_PUSH, DO_RELEASE and DO_CLICK on the links become the button's press, release and click", function()
			local _, c4, _, dispatch, st, device = new_device()
			dispatch.received_from_proxy(200, "DO_PUSH", {})
			dispatch.received_from_proxy(201, "DO_RELEASE", {})
			dispatch.received_from_proxy("202", "DO_CLICK", {})
			assert.same({ { 0, device.ACT_PRESS }, { 1, device.ACT_RELEASE }, { 2, device.ACT_CLICK } }, st.buttons)
			assert.same({ 0, 1, 2 }, { device.ACT_RELEASE, device.ACT_PRESS, device.ACT_CLICK })
			assert.equal(0, #c4.calls_to("SendToProxy"), "no echo on the link route")
		end)

		it("takes the link commands on the links only: on the proxy binding they reach nothing, not even a warning",
			function()
				local dev, _, _, dispatch, st = new_device()
				local lines = capture_log()
				for _, command in ipairs({ "DO_PUSH", "DO_RELEASE", "DO_CLICK" }) do
					dispatch.received_from_proxy(5001, command, {})
				end
				assert.same({}, st.buttons)
				assert.same({}, lines)
				-- link_button itself still refuses a binding that is no link.
				assert.is_nil(dev.link_button(5001, "DO_CLICK"))
				assert.same({ "[WARN] Test Device: DO_CLICK on binding 5001: not a Button Link" }, lines)
				assert.equal(1, dev.link_button(201, "x"))
				assert.is_nil(dev.link_button(nil, "DO_PUSH"))
			end)
	end)

	-- The keypad press / click / release machine, its hooks recording what
	-- reaches them. A driver's own spec pins what it does in its hooks.
	describe("keypad machine", function()
		-- BUTTON_ACTION's ACTION values (device.ACT_*).
		local RELEASE, PRESS, CLICK = 0, 1, 2

		-- An instance with the module's own machine in dev.button_action and
		-- every hook recording into st.calls; st.on is what the device shows.
		local function new_keypad(opts)
			opts = opts or {}
			package.loaded["common.device"] = nil
			package.loaded["common.dispatch"] = nil
			local c4, env = fake.install_c4({ ["Debug Mode"] = "Off", ["Driver Version"] = "" })
			local device = require("common.device")
			local dispatch = require("common.dispatch")
			local st = { on = true, calls = {} }
			local dev = device.new({
				prefix = "Test Device",
				noun = opts.noun,
				settings = opts.settings,
				proxy_binding = opts.proxy_binding,
			})
			local function record(...) st.calls[#st.calls + 1] = { ... } end
			dev.is_on = function() return st.on end
			dev.on_click = function(button) record("click", button) end
			dev.on_hold = function(h, up, on) record("hold", h.button, up, on) end
			dev.on_finish = function(h) record("finish", h.button) end
			dev.on_end_hold = function(h) record("end", h.button) end
			return dev, c4, env, dispatch, st
		end

		it("a click before the hold time is a tap: the press ends, then on_click; a click alone too", function()
			local dev, c4, _, _, st = new_keypad()
			dev.button_action(0, PRESS)
			assert.same({ 400, false }, c4.calls_to("SetTimer")[1])
			dev.button_action(0, CLICK)
			assert.same({ { "end", 0 }, { "click", 0 } }, st.calls)
			assert.same({}, delays(c4), "the hold timer is cancelled")
			dev.button_action(2, CLICK)
			assert.same({ "click", 2 }, st.calls[3])
		end)

		it("holds once the press is still down at 400 ms: top up, bottom down, toggle by the on state then", function()
			-- { button, what the device shows, the direction (up), the on state on_hold hears }
			for _, case in ipairs({
				{ 0, true, true, true }, { 0, false, true, false },
				{ 1, true, false, true },
				{ 2, true, false, true }, { 2, false, true, false }, { 2, nil, true, false },
			}) do
				local dev, c4, _, _, st = new_keypad()
				st.on = case[2]
				dev.button_action(case[1], PRESS)
				assert.same({ 400 }, delays(c4))
				c4.fire_timers()
				assert.same({ { "hold", case[1], case[3], case[4] } }, st.calls)
			end
			-- The on state counts when the hold time passes, not at the press.
			local dev, c4, _, _, st = new_keypad()
			st.on = false
			dev.button_action(2, PRESS)
			st.on = true
			c4.fire_timers()
			assert.same({ { "hold", 2, false, true } }, st.calls)
		end)

		it("does nothing for down from off, with the device's own word in the debug line", function()
			for _, noun in ipairs({ "light", "fan" }) do
				local dev, c4, _, _, st = new_keypad({ noun = noun })
				st.on = false
				log.set_debug(true)
				local lines = capture_log()
				dev.button_action(1, PRESS)
				c4.fire_timers()
				assert.same({}, st.calls)
				assert.same({ "[DEBUG] Test Device: hold: dimming down a " .. noun .. " that is off does nothing" }, lines)
				dev.button_action(1, RELEASE) -- still a hold that ends: the click after it is guarded
				assert.same({ { "end", 1 }, { "finish", 1 } }, st.calls)
				assert.same({ 1000 }, delays(c4))
			end
			-- Without a noun the line says "device".
			local dev, c4, _, _, st = new_keypad()
			st.on = false
			log.set_debug(true)
			local lines = capture_log()
			dev.button_action(1, PRESS)
			c4.fire_timers()
			assert.same({ "[DEBUG] Test Device: hold: dimming down a device that is off does nothing" }, lines)
		end)

		it("finishes a hold at its release and then ignores a click on that button for 1 s, not on another", function()
			local dev, c4, _, _, st = new_keypad()
			log.set_debug(true)
			local lines = capture_log()
			dev.button_action(0, PRESS)
			c4.fire_timers()
			dev.button_action(0, RELEASE)
			assert.same({ { "hold", 0, true, true }, { "end", 0 }, { "finish", 0 } }, st.calls)
			assert.same({ 1000 }, delays(c4), "the click guard")
			st.calls = {}
			dev.button_action(0, CLICK)
			assert.same({}, st.calls, "the keypad's click after the hold")
			assert.same({ "[DEBUG] Test Device: click on button 0 right after a hold ignored" }, lines)
			dev.button_action(0, PRESS)
			dev.button_action(0, CLICK)
			assert.same({ { "end", 0 } }, st.calls, "a new tap within the second is the keypad's too")
			dev.button_action(1, CLICK)
			assert.same({ "click", 1 }, st.calls[2], "another button is not guarded")
			c4.advance(1000) -- 1 s later: the guard is over, and so is the double-tap window (#141 LF-D12)
			dev.button_action(0, CLICK)
			assert.same({ "click", 0 }, st.calls[3])
		end)

		it("finishes a hold at a release-as-click instead of tapping", function()
			local dev, c4, _, _, st = new_keypad()
			dev.button_action(2, PRESS)
			c4.fire_timers()
			dev.button_action(2, CLICK)
			assert.same({ { "hold", 2, false, true }, { "end", 2 }, { "finish", 2 } }, st.calls)
			assert.same({ 1000 }, delays(c4))
		end)

		it("ends a press released before the hold time quietly: no tap, no finish, no guard", function()
			local dev, c4, _, _, st = new_keypad()
			dev.button_action(0, PRESS)
			dev.button_action(0, RELEASE)
			assert.same({ { "end", 0 } }, st.calls)
			assert.same({}, delays(c4))
			dev.button_action(0, CLICK) -- the click a keypad sends after such a release is the tap
			assert.same({ { "end", 0 }, { "click", 0 } }, st.calls)
		end)

		it("ends a press when the next one starts, which gets its own hold time", function()
			local dev, c4, _, _, st = new_keypad()
			dev.button_action(0, PRESS)
			dev.button_action(1, PRESS)
			assert.same({ { "end", 0 } }, st.calls)
			assert.same({ 400 }, delays(c4), "only the new press's hold timer")
			c4.fire_timers()
			assert.same({ { "end", 0 }, { "hold", 1, false, true } }, st.calls)
		end)

		it("cancels the timer a hook keeps in h.timer when the press ends; holding(h) names the press", function()
			local dev, c4 = new_keypad()
			local held
			dev.on_hold = function(h)
				held = h
				h.timer = c4:SetTimer(100, function() end, true)
			end
			dev.button_action(0, PRESS)
			c4.fire_timers()
			assert.is_true(dev.holding(held))
			assert.same({ 100 }, delays(c4))
			dev.button_action(0, RELEASE)
			assert.is_false(dev.holding(held))
			assert.same({ 1000 }, delays(c4), "the hook's timer is gone; the click guard remains")
		end)

		it("dim_after_on dims up 600 ms later while the press lasts, and never after it ended", function()
			for _, case in ipairs({ "held", "released", "pressed again" }) do
				local dev, c4 = new_keypad()
				local dims = 0
				dev.on_hold = function(h)
					dev.dim_after_on(h, function() dims = dims + 1 end)
				end
				dev.button_action(0, PRESS)
				c4.fire_timers() -- the hold time
				assert.same({ 600, false }, c4.calls_to("SetTimer")[2], case)
				if case == "released" then dev.button_action(0, RELEASE) end
				if case == "pressed again" then
					-- The fake keeps a cancelled timer's callback: fire it by hand
					-- as a late one would, after a new press replaced the hold.
					local timer = c4.timers[2]
					dev.button_action(1, PRESS)
					timer.callback(timer, 0)
				else
					c4.fire_timers() -- 600 ms later
				end
				assert.equal(case == "held" and 1 or 0, dims, case)
			end
		end)

		it("loads on a new device, where Director's PersistGetValue returns no value at all", function()
			local dev, c4 = new_keypad({ settings = { "preset", "click_up", "click_down", "hold_up", "hold_down" } })
			-- Director answers a key never written with nothing (not nil);
			-- tonumber() without an argument raises.
			c4.PersistGetValue = function() end
			assert.has_no.errors(function() dev.load_settings() end)
			assert.same({ 100, 3000, 3000, 5000, 5000 }, { dev.setting("preset"), dev.setting("click_up"),
				dev.setting("click_down"), dev.setting("hold_up"), dev.setting("hold_down") })
		end)

		it("takes the declared settings: defaults, persisted values, and the proxy's commands that set them", function()
			local dev, c4, _, dispatch = new_keypad({ settings = { "preset", "click_up", "click_down", "hold_up",
				"hold_down" } })
			local function all()
				return { dev.setting("preset"), dev.setting("click_up"), dev.setting("click_down"),
					dev.setting("hold_up"), dev.setting("hold_down") }
			end
			assert.same({ 100, 3000, 3000, 5000, 5000 }, all())
			c4.persist.preset_level = 40
			c4.persist.hold_rate_down = "2000"
			dev.load_settings()
			assert.same({ 40, 3000, 3000, 5000, 2000 }, all())
			dispatch.received_from_proxy(5001, "SET_PRESET_LEVEL", { LEVEL = "60" })
			dispatch.received_from_proxy(5001, "SET_CLICK_RATE_UP", { RATE = "1500" })
			dispatch.received_from_proxy(5001, "SET_CLICK_RATE_DOWN", { RATE = "500" })
			dispatch.received_from_proxy(5001, "SET_HOLD_RATE_UP", { RATE = "7000" })
			dispatch.received_from_proxy(5001, "SET_HOLD_RATE_DOWN", { RATE = "3000" })
			assert.same({ 60, 1500, 500, 7000, 3000 }, all())
			assert.same({ preset_level = 60, click_rate_up = 1500, click_rate_down = 500, hold_rate_up = 7000,
				hold_rate_down = 3000 }, c4.persist)
			local lines = capture_log()
			dispatch.received_from_proxy(5001, "SET_HOLD_RATE_UP", { RATE = "fast" })
			dispatch.received_from_proxy(5001, "SET_PRESET_LEVEL", {})
			assert.same({ '[WARN] Test Device: hold_rate_up "fast" is not a number; kept 7000',
				"[WARN] Test Device: preset_level without a value; kept 60" }, lines)
			assert.same({ 60, 1500, 500, 7000, 3000 }, all(), "unchanged")
		end)

		-- Hardware 2026-10-25 (a Hue dev build): without the answer the proxy
		-- kept its old value, so Composer showed 5.000 s after a change to
		-- 2.000 s and setting 5.000 s again sent nothing.
		it("answers each setting command with the notification the proxy stores, and reports all at late init", function()
			local dev, c4, _, dispatch = new_keypad({ settings = { "preset", "click_up", "click_down", "hold_up",
				"hold_down" } })
			c4.persist.hold_rate_down = "2000"
			dev.load_settings()
			assert.same({ { 5001, "100" } }, proxied(c4, "PRESET_LEVEL"))
			assert.same({ { 5001, "3000" } }, proxied(c4, "CLICK_RATE_UP"))
			assert.same({ { 5001, "3000" } }, proxied(c4, "CLICK_RATE_DOWN"))
			assert.same({ { 5001, "5000" } }, proxied(c4, "HOLD_RATE_UP"))
			assert.same({ { 5001, "2000" } }, proxied(c4, "HOLD_RATE_DOWN"),
				"the persisted value, bare (the proxy reads a table as 0)")
			dispatch.received_from_proxy(5001, "SET_HOLD_RATE_DOWN", { RATE = "5000" })
			dispatch.received_from_proxy(5001, "SET_PRESET_LEVEL", { LEVEL = "60" })
			assert.same({ 5001, "5000" }, proxied(c4, "HOLD_RATE_DOWN")[2])
			assert.same({ 5001, "60" }, proxied(c4, "PRESET_LEVEL")[2])
			dispatch.received_from_proxy(5001, "SET_HOLD_RATE_UP", { RATE = "fast" })
			assert.same({ 5001, "5000" }, proxied(c4, "HOLD_RATE_UP")[2], "a refused value: the one kept")
		end)

		it("answers a value that is not a number with the value kept, as one out of range", function()
			local dev, c4, _, dispatch = new_keypad({ settings = { "preset", "click_up", "hold_down" } })
			c4.persist.click_rate_up = 1500
			dev.load_settings()
			c4.calls = {}
			local lines = capture_log()
			dispatch.received_from_proxy(5001, "SET_CLICK_RATE_UP", { RATE = "1.5 s" })
			dispatch.received_from_proxy(5001, "SET_PRESET_LEVEL", { LEVEL = "" })
			dispatch.received_from_proxy(5001, "SET_HOLD_RATE_DOWN", {})
			assert.same({ { 5001, "1500" } }, proxied(c4, "CLICK_RATE_UP"))
			assert.same({ { 5001, "100" } }, proxied(c4, "PRESET_LEVEL"))
			assert.same({ { 5001, "5000" } }, proxied(c4, "HOLD_RATE_DOWN"))
			assert.same({ 1500, 100, 5000 }, { dev.setting("click_up"), dev.setting("preset"), dev.setting("hold_down") })
			assert.equal(0, #c4.calls_to("PersistSetValue"), "nothing stored")
			assert.same({
				'[WARN] Test Device: click_rate_up "1.5 s" is not a number; kept 1500',
				'[WARN] Test Device: preset_level "" is not a number; kept 100',
				"[WARN] Test Device: hold_rate_down without a value; kept 5000",
			}, lines)
		end)

		it("refuses a setting out of range, from the proxy and at load, and tells the proxy the value kept", function()
			local dev, c4, _, dispatch = new_keypad({ settings = { "preset", "hold_down" } })
			c4.persist.preset_level = "0"
			local lines = capture_log()
			dev.load_settings()
			assert.equal(100, dev.setting("preset"), "a persisted 0 reads as the default")
			assert.same({ { 5001, "100" } }, proxied(c4, "PRESET_LEVEL"))
			assert.same({ "[WARN] Test Device: preset_level 0 is out of range; using 100" }, lines)
			assert.is_nil(c4.persist.preset_level, "the bad value is deleted, so the next start does not warn again")
			dev.load_settings()
			assert.equal(1, #lines, "warned once")
			dispatch.received_from_proxy(5001, "SET_PRESET_LEVEL", { LEVEL = "0" })
			assert.equal(100, dev.setting("preset"))
			assert.same({ 5001, "100" }, proxied(c4, "PRESET_LEVEL")[2], "the proxy hears the value kept")
			dispatch.received_from_proxy(5001, "SET_HOLD_RATE_DOWN", { RATE = "-5" })
			assert.equal(5000, dev.setting("hold_down"))
		end)

		it("handles only the settings a driver declares; the rest stay without a handler", function()
			local dev, c4, _, dispatch = new_keypad({ settings = { "hold_up", "hold_down" } })
			assert.is_function(dispatch.binding(5001)["SET_HOLD_RATE_UP"])
			assert.is_function(dispatch.binding(5001)["SET_HOLD_RATE_DOWN"])
			for _, command in ipairs({ "SET_PRESET_LEVEL", "SET_CLICK_RATE_UP", "SET_CLICK_RATE_DOWN" }) do
				assert.is_nil(dispatch.binding(5001)[command], command)
			end
			dev.load_settings()
			local keys = {}
			for _, args in ipairs(c4.calls_to("PersistGetValue")) do keys[#keys + 1] = args[1] end
			assert.same({ "hold_rate_up", "hold_rate_down" }, keys)
			local _, _, _, none = new_keypad()
			assert.is_nil(none.binding(5001)["SET_HOLD_RATE_UP"], "no settings declared, none handled")
		end)

		it("is fed by both routes: the Button Links and the proxy's BUTTON_ACTION", function()
			local _, c4, _, dispatch, st = new_keypad()
			dispatch.received_from_proxy(201, "DO_PUSH", {})
			c4.fire_timers()
			dispatch.received_from_proxy(5001, "BUTTON_ACTION", { BUTTON_ID = "1", ACTION = "0" })
			assert.same({ { "hold", 1, false, true }, { "end", 1 }, { "finish", 1 } }, st.calls)
			assert.same({ { 5001, { BUTTON_ID = 1, ACTION = 0 } } }, proxied(c4, "BUTTON_ACTION"))
		end)

		it("arms the click guard before on_finish, so a failing hook still leaves the keypad's click ignored", function()
			local dev, c4, _, dispatch, st = new_keypad()
			dev.on_finish = function() error("boom") end
			local lines = capture_log()
			dispatch.received_from_proxy(200, "DO_PUSH", {})
			c4.fire_timers()
			dispatch.received_from_proxy(200, "DO_RELEASE", {})
			assert.equal(1, #lines)
			assert.truthy(lines[1]:find("^%[ERROR%] Test Device: proxy handler DO_RELEASE failed: .*boom"))
			dispatch.received_from_proxy(200, "DO_CLICK", {})
			assert.same({ { "hold", 0, true, true }, { "end", 0 } }, st.calls, "no tap after the hold")
		end)

		it("cancel_timers ends a press and the click guard (OnDriverDestroyed)", function()
			local dev, c4, _, _, st = new_keypad()
			dev.button_action(0, PRESS)
			dev.cancel_timers()
			assert.same({ { "end", 0 } }, st.calls)
			assert.same({}, delays(c4))
			dev.button_action(1, PRESS)
			c4.fire_timers()
			dev.button_action(1, RELEASE)
			assert.same({ 1000 }, delays(c4))
			dev.cancel_timers()
			assert.same({}, delays(c4))
			dev.button_action(1, CLICK)
			assert.same({ "click", 1 }, st.calls[#st.calls], "the guard went with it")
		end)

		-- #141 LF-D12 (ported from the Hue project's #421 D4 and D5): the
		-- double-tap window and the stop, on the fake clock (c4.advance moves
		-- C4:GetTime and fires what falls due on the way).
		describe("double-tap window and fade stop (#141 LF-D12)", function()
			local COMMANDS = { [PRESS] = "DO_PUSH", [CLICK] = "DO_CLICK", [RELEASE] = "DO_RELEASE" }
			local ROUTES = {
				{ name = "the proxy's BUTTON_ACTION", echoes = true, act = function(dispatch, button, action)
					dispatch.received_from_proxy(5001, "BUTTON_ACTION", { BUTTON_ID = tostring(button),
						ACTION = tostring(action) })
				end },
				{ name = "the Button Links", echoes = false, act = function(dispatch, button, action)
					dispatch.received_from_proxy(200 + button, COMMANDS[action], {})
				end },
			}

			-- The light's side as the machine sees it (the light's fade): ramp_active
			-- answers st.ramping, the stop records itself and ends the ramp, and
			-- with st.tap_ramps a tap starts one. Without opts.ramp the hooks keep
			-- the module's defaults, as on a device with no fade.
			local function on_route(route, opts)
				opts = opts or {}
				local dev, c4, _, dispatch, st = new_keypad(opts)
				if opts.ramp ~= false then
					st.ramping = false
					dev.ramp_active = function() return st.ramping end
					dev.on_ramp_stop = function(button)
						st.calls[#st.calls + 1] = { "stop", button }
						st.ramping = false
					end
					dev.on_click = function(button)
						st.calls[#st.calls + 1] = { "click", button }
						if st.tap_ramps then st.ramping = true end
					end
				end
				local k = {}
				for name, action in pairs({ press = PRESS, click = CLICK, release = RELEASE }) do
					k[name] = function(button) route.act(dispatch, button, action) end
				end
				function k.tap(button)
					k.press(button)
					k.click(button)
				end
				return k, dev, c4, st
			end

			it("exports DOUBLE_TAP_MS = 600 (LF-D12)", function()
				new_keypad()
				assert.equal(600, require("common.device").DOUBLE_TAP_MS)
			end)

			it("falls back to os.time() when C4:GetTime fails: the window then holds to the second", function()
				local dev, c4, _, _, st = new_keypad()
				c4.GetTime = function() error("no clock") end
				local now = 1000
				local clock = stub(os, "time", function() return now end)
				local ok, err = pcall(function()
					dev.button_action(0, PRESS)
					dev.button_action(0, CLICK)
					dev.button_action(0, PRESS) -- the same second
					dev.button_action(0, CLICK)
					now = 1001
					dev.button_action(0, PRESS) -- 1000 ms on
					dev.button_action(0, CLICK)
				end)
				clock:revert()
				assert(ok, err)
				assert.same({ { "end", 0 }, { "click", 0 }, { "end", 0 }, { "end", 0 }, { "click", 0 } }, st.calls)
			end)

			it("a stop that fails (logged by dispatch) still swallows its click", function()
				local k, dev, _, st = on_route(ROUTES[2])
				dev.on_ramp_stop = function() error("boom") end
				st.ramping = true
				local lines = capture_log()
				k.tap(0)
				assert.equal(1, #lines)
				assert.truthy(lines[1]:find("^%[ERROR%] Test Device: proxy handler DO_PUSH failed: .*boom"))
				assert.same({ { "end", 0 } }, st.calls, "no tap")
			end)

			for _, route in ipairs(ROUTES) do
				describe("through " .. route.name, function()
					it("a single tap reaches on_click", function()
						local k, _, c4, st = on_route(route)
						k.tap(0)
						assert.same({ { "end", 0 }, { "click", 0 } }, st.calls)
						assert.same({}, delays(c4), "no hold timer, no guard")
					end)

					it("a second press within 600 ms on the same button is swallowed, a third too, all echoed", function()
						local k, _, c4, st = on_route(route)
						k.tap(2)
						c4.advance(599)
						k.tap(2)
						c4.advance(599) -- measured from the second press, not the first
						k.tap(2)
						assert.same({ { "end", 2 }, { "click", 2 }, { "end", 2 }, { "end", 2 } }, st.calls)
						assert.equal(route.echoes and 6 or 0, #proxied(c4, "BUTTON_ACTION"),
							"the proxy route echoes every action, the swallowed ones too")
					end)

					it("a press 600 ms or more after the last is a fresh tap; so is one after the clock went back", function()
						local k, _, c4, st = on_route(route)
						k.tap(0)
						c4.advance(600)
						k.tap(0)
						c4.now_ms = c4.now_ms - 5000
						k.tap(0)
						assert.same({ { "end", 0 }, { "click", 0 }, { "end", 0 }, { "click", 0 }, { "end", 0 },
							{ "click", 0 } }, st.calls)
					end)

					it("the window is per button: another button within 600 ms is a tap of its own", function()
						local k, _, c4, st = on_route(route)
						k.tap(0)
						c4.advance(100)
						k.tap(1)
						c4.advance(100)
						k.tap(2)
						assert.same({ { "end", 0 }, { "click", 0 }, { "end", 1 }, { "click", 1 }, { "end", 2 },
							{ "click", 2 } }, st.calls)
					end)

					it("while a ramp runs, the press of any button stops it once at the push; its click is swallowed", function()
						for button = 0, 2 do
							local k, _, c4, st = on_route(route)
							st.ramping = true
							k.press(button)
							assert.same({ { "stop", button } }, st.calls, "on the push, before any click")
							assert.same({ 400 }, delays(c4), "the hold timer starts as before")
							k.click(button)
							assert.same({ { "stop", button }, { "end", button } }, st.calls, "no tap, no second stop")
							assert.same({}, delays(c4), "a stop arms no guard")
							c4.advance(600)
							k.tap(button)
							assert.same({ "click", button }, st.calls[4], "the next tap acts from the stopped level")
						end
					end)

					it("a tap ramps, a tap after the window stops it, on either button: the light does not reverse", function()
						for _, second in ipairs({ 0, 1, 2 }) do
							local k, _, c4, st = on_route(route)
							st.tap_ramps = true
							k.tap(0)
							c4.advance(second == 0 and 1000 or 100) -- the other buttons are outside the top's window at once
							k.tap(second)
							assert.same({ { "end", 0 }, { "click", 0 }, { "stop", second }, { "end", second } }, st.calls)
							assert.is_false(st.ramping)
						end
					end)

					it("a press held past HOLD_AFTER_MS while ramping stops, then holds from the stopped level", function()
						local k, dev, c4, st = on_route(route)
						dev.on_hold = function(h, up, on)
							st.calls[#st.calls + 1] = { "hold", h.button, up, on, h.stopped == true, st.ramping }
						end
						st.ramping = true
						k.press(1)
						c4.advance(400)
						assert.same({ { "stop", 1 }, { "hold", 1, false, true, true, false } }, st.calls,
							"the stop ran first: the hold reads its level, with the record marked stopped")
						k.release(1)
						assert.same({ "finish", 1 }, st.calls[4])
						assert.same({ 1000 }, delays(c4), "the hold's release arms the guard as before")
					end)

					it("a press within the window while ramping does not stop: the ramp goes on; held, it holds", function()
						local k, dev, c4, st = on_route(route)
						dev.on_hold = function(h, up, on)
							st.calls[#st.calls + 1] = { "hold", h.button, up, on, h.multi == true }
						end
						st.tap_ramps = true
						k.tap(0)
						c4.advance(300)
						k.tap(0)
						assert.same({ { "end", 0 }, { "click", 0 }, { "end", 0 } }, st.calls)
						assert.is_true(st.ramping, "the first tap's ramp goes on")
						c4.advance(300) -- 300 ms after the second press: still the window
						k.press(0)
						c4.advance(400)
						assert.same({ "hold", 0, true, true, true }, st.calls[4], "held, it becomes a hold, with no stop")
						k.release(0)
						assert.same({ { "end", 0 }, { "finish", 0 } }, { st.calls[5], st.calls[6] })
					end)

					it("a click with no press on record follows the same rules, judged at the click", function()
						local k, _, c4, st = on_route(route)
						st.tap_ramps = true
						k.click(0)               -- a tap: the ramp starts
						c4.advance(300)
						k.click(0)               -- within the window: ignored, the ramp goes on
						assert.is_true(st.ramping)
						c4.advance(600)
						k.click(0)               -- 600 ms after the last click: stops
						c4.advance(600)
						k.click(1)               -- idle again: a tap
						c4.advance(100)
						k.click(0)               -- another button's window does not count: stops
						assert.same({ { "click", 0 }, { "stop", 0 }, { "click", 1 }, { "stop", 0 } }, st.calls)
						assert.same({}, delays(c4))
					end)

					it("push, release, click: the click follows its press's verdict and judges nothing again", function()
						local k, _, c4, st = on_route(route)
						st.tap_ramps = true
						local function tap(button)
							k.press(button)
							k.release(button)
							k.click(button)
						end
						tap(0)
						c4.advance(300)
						tap(0) -- multi
						c4.advance(1000)
						tap(0) -- stops the first tap's ramp
						c4.advance(1000)
						tap(0) -- idle: a tap
						assert.same({ { "end", 0 }, { "click", 0 }, { "end", 0 }, { "stop", 0 }, { "end", 0 }, { "end", 0 },
							{ "click", 0 } }, st.calls)
					end)

					it("the guard after a hold still ignores a click, before any stop; a hold opens no window", function()
						local k, _, c4, st = on_route(route)
						k.press(0)
						c4.advance(400)
						k.release(0)
						assert.same({ { "hold", 0, true, true }, { "end", 0 }, { "finish", 0 } }, st.calls)
						st.ramping = true
						k.click(0)
						assert.equal(3, #st.calls, "the keypad's click after the hold: no tap, no stop")
						st.ramping = false
						c4.fire_timers() -- the guard runs out; the clock stays 400 ms after the hold's press
						k.click(0)
						assert.same({ "click", 0 }, st.calls[4], "a hold is no tap: the click is not part of a double tap")
					end)

					it("with the default hooks (a device with no fade) only the window changes", function()
						local k, dev, c4, st = on_route(route, { ramp = false })
						assert.is_false(dev.ramp_active())
						assert.has_no.errors(function() dev.on_ramp_stop(0) end)
						k.tap(0)
						c4.advance(300)
						k.tap(0) -- the second tap of a double tap: nothing
						c4.advance(600)
						k.tap(0) -- nothing is ramping: a tap, never a stop
						k.press(1)
						c4.advance(400)
						k.release(1)
						k.click(1)
						assert.same({ { "end", 0 }, { "click", 0 }, { "end", 0 }, { "end", 0 }, { "click", 0 },
							{ "hold", 1, false, true }, { "end", 1 }, { "finish", 1 } }, st.calls)
					end)
				end)
			end
		end)

		-- #141 LF-D4: the proxy's Default Brightness Rate. The command returns
		-- nothing, so the setting has no notify.
		describe("the brightness rate setting (#141 LF-D4)", function()
			local ALL = { "preset", "click_up", "click_down", "hold_up", "hold_down", "brightness_rate" }

			it("defaults to 750 ms and answers nothing to the proxy, at late init or after a command", function()
				local dev, c4, _, dispatch = new_keypad({ settings = ALL })
				assert.equal(750, dev.setting("brightness_rate"))
				dev.load_settings()
				assert.equal(750, dev.setting("brightness_rate"))
				local before = #c4.calls_to("SendToProxy")
				assert.equal(5, before, "the five settings with a notify are reported, this one is not")
				dispatch.received_from_proxy(5001, "UPDATE_BRIGHTNESS_RATE_DEFAULT", { RATE = "3000" })
				assert.equal(before, #c4.calls_to("SendToProxy"), "no notification goes back")
			end)

			it("is taken from UPDATE_BRIGHTNESS_RATE_DEFAULT {RATE}, persisted, and read back at the next start", function()
				local dev, c4, _, dispatch = new_keypad({ settings = ALL })
				dev.load_settings()
				dispatch.received_from_proxy(5001, "UPDATE_BRIGHTNESS_RATE_DEFAULT", { RATE = "3000" })
				assert.equal(3000, dev.setting("brightness_rate"))
				assert.equal(3000, c4.persist.brightness_rate_default)
				dispatch.received_from_proxy(5001, "UPDATE_BRIGHTNESS_RATE_DEFAULT", { RATE = "0" })
				assert.equal(0, dev.setting("brightness_rate"), "0 is a rate (a single request)")
				c4.persist.brightness_rate_default = "1200"
				dev.load_settings()
				assert.equal(1200, dev.setting("brightness_rate"))
			end)

			it("logs RATE at debug when it arrives", function()
				local _, _, _, dispatch = new_keypad({ settings = ALL })
				log.set_debug(true)
				local lines = capture_log()
				dispatch.received_from_proxy(5001, "UPDATE_BRIGHTNESS_RATE_DEFAULT", { RATE = "3000" })
				assert.same("[DEBUG] Test Device: UPDATE_BRIGHTNESS_RATE_DEFAULT 3000", lines[#lines],
					"after dispatch's own line")
			end)

			it("refuses a value out of range or not a number and keeps the one in use, without a notify", function()
				local dev, c4, _, dispatch = new_keypad({ settings = ALL })
				dev.load_settings()
				dispatch.received_from_proxy(5001, "UPDATE_BRIGHTNESS_RATE_DEFAULT", { RATE = "2000" })
				local sent = #c4.calls_to("SendToProxy")
				local lines = capture_log()
				dispatch.received_from_proxy(5001, "UPDATE_BRIGHTNESS_RATE_DEFAULT", { RATE = "86400001" })
				dispatch.received_from_proxy(5001, "UPDATE_BRIGHTNESS_RATE_DEFAULT", { RATE = "-1" })
				dispatch.received_from_proxy(5001, "UPDATE_BRIGHTNESS_RATE_DEFAULT", { RATE = "slow" })
				dispatch.received_from_proxy(5001, "UPDATE_BRIGHTNESS_RATE_DEFAULT", {})
				assert.equal(2000, dev.setting("brightness_rate"))
				assert.equal(2000, c4.persist.brightness_rate_default)
				assert.equal(sent, #c4.calls_to("SendToProxy"))
				assert.equal(4, #lines)
				assert.truthy(lines[1]:find("brightness_rate_default 86400001 is out of range; kept 2000", 1, true))
				assert.truthy(lines[3]:find('"slow" is not a number', 1, true))
				assert.truthy(lines[4]:find("without a value", 1, true))
			end)

			it("deletes a stored value out of range at late init and reads the default", function()
				local dev, c4 = new_keypad({ settings = ALL })
				c4.persist.brightness_rate_default = "99999999999"
				dev.load_settings()
				assert.equal(750, dev.setting("brightness_rate"))
				assert.is_nil(c4.persist.brightness_rate_default)
			end)

			it("is taken only when the driver lists it: no handler, the default still reads", function()
				local dev, _, _, dispatch = new_keypad({ settings = { "preset" } })
				assert.equal(750, dev.setting("brightness_rate"))
				assert.is_nil(dispatch.binding(5001)["UPDATE_BRIGHTNESS_RATE_DEFAULT"])
				local _, _, _, dispatch2 = new_keypad({ settings = ALL })
				assert.is_function(dispatch2.binding(5001)["UPDATE_BRIGHTNESS_RATE_DEFAULT"])
			end)
		end)
	end)

	-- docs/v1-design.md section 9.2: the fan driver has a fan proxy on 5001 and
	-- the light_v2 proxy on 5002, and the handlers are filed per binding.
	describe("routing by binding", function()
		local PROXY_COMMANDS = { "BUTTON_ACTION", "SET_BUTTON_COLOR", "SET_CLICK_RATE_DOWN", "SET_CLICK_RATE_UP",
			"SET_HOLD_RATE_DOWN", "SET_HOLD_RATE_UP", "SET_PRESET_LEVEL" }
		local LINK_COMMANDS = { "DO_CLICK", "DO_PUSH", "DO_RELEASE", "REQUEST_BUTTON_COLORS", "SET_BUTTON_COLOR" }

		local function names(handlers)
			local out = {}
			for name in pairs(handlers) do out[#out + 1] = name end
			table.sort(out)
			return out
		end

		it("files its handlers per binding and writes nothing to the command-only table", function()
			local _, _, _, dispatch = new_device({ settings = { "preset", "click_up", "click_down", "hold_up", "hold_down" } })
			assert.same({}, dispatch.proxy)
			assert.same(PROXY_COMMANDS, names(dispatch.binding(5001)), "the proxy binding")
			for _, link in ipairs({ 200, 201, 202 }) do
				assert.same(LINK_COMMANDS, names(dispatch.binding(link)), "link " .. link)
			end
			assert.same({}, dispatch.binding(5002), "another proxy's binding is left alone")
			assert.same({}, dispatch.binding(300), "and the driver's other links")
		end)

		it("files the proxy's commands under the binding it was given, and the links' under the links", function()
			local _, _, _, dispatch = new_device({ proxy_binding = 5002,
				settings = { "preset", "click_up", "click_down", "hold_up", "hold_down" } })
			assert.same({}, dispatch.proxy)
			assert.same(PROXY_COMMANDS, names(dispatch.binding(5002)))
			assert.same({}, dispatch.binding(5001), "the default binding stays free for the fan proxy")
			for _, link in ipairs({ 200, 201, 202 }) do
				assert.same(LINK_COMMANDS, names(dispatch.binding(link)), "link " .. link)
			end
		end)

		it("ignores a SET_BUTTON_COLOR on a link: nothing stored, nothing sent, a debug line", function()
			local _, c4, _, dispatch, st = new_device()
			st.on = true
			log.set_debug(true)
			local lines = capture_log()
			for _, link in ipairs({ 200, 201, 202 }) do
				dispatch.received_from_proxy(link, "SET_BUTTON_COLOR", { BUTTON_ID = "1", ON_COLOR = "ff0000" })
			end
			assert.same({}, c4.persist)
			assert.equal(0, #c4.calls_to("SendToProxy"))
			assert.equal(6, #lines, "a trace line and the ignore line for each")
			for i, link in ipairs({ 200, 201, 202 }) do
				assert.truthy(lines[2 * i]:find("SET_BUTTON_COLOR on binding " .. link .. " ignored", 1, true), lines[2 * i])
			end
			-- The proxy binding still takes it.
			dispatch.received_from_proxy(5001, "SET_BUTTON_COLOR", { BUTTON_ID = "1", ON_COLOR = "ff0000" })
			assert.equal("ff0000", c4.persist.button_1_on_color)
		end)

		it("takes the same command name on two proxies apart: only its own binding reaches the instance", function()
			local dev, c4, _, dispatch, st = new_device({ proxy_binding = 5002, settings = { "preset" } })
			local fan = {}
			dispatch.binding(5001)["SET_PRESET_LEVEL"] = function(binding, params) fan[#fan + 1] = { binding, params.LEVEL } end
			dispatch.binding(5001)["BUTTON_ACTION"] = function(binding) fan[#fan + 1] = { binding, "BUTTON_ACTION" } end

			dispatch.received_from_proxy(5001, "SET_PRESET_LEVEL", { LEVEL = "30" })
			dispatch.received_from_proxy(5001, "BUTTON_ACTION", { BUTTON_ID = "0", ACTION = "1" })
			assert.same({ { 5001, "30" }, { 5001, "BUTTON_ACTION" } }, fan)
			assert.equal(100, dev.setting("preset"), "the fan proxy's preset command is not the light's")
			assert.same({}, st.buttons)
			assert.equal(0, #c4.calls_to("SendToProxy"))

			dispatch.received_from_proxy(5002, "SET_PRESET_LEVEL", { LEVEL = "60" })
			dispatch.received_from_proxy(5002, "BUTTON_ACTION", { BUTTON_ID = "0", ACTION = "1" })
			assert.equal(60, dev.setting("preset"))
			assert.same({ { 0, 1 } }, st.buttons)
			assert.same({ { 5001, "30" }, { 5001, "BUTTON_ACTION" } }, fan, "the fan proxy heard nothing more")
		end)

		it("hears a link command on the links of a light on another proxy binding too", function()
			local _, c4, _, dispatch, st, device = new_device({ proxy_binding = 5002 })
			dispatch.received_from_proxy(200, "DO_PUSH", {})
			dispatch.received_from_proxy(201, "DO_RELEASE", {})
			dispatch.received_from_proxy("202", "DO_CLICK", {})
			assert.same({ { 0, device.ACT_PRESS }, { 1, device.ACT_RELEASE }, { 2, device.ACT_CLICK } }, st.buttons)
			-- ...and none of them on either proxy binding.
			for _, binding in ipairs({ 5001, 5002 }) do
				dispatch.received_from_proxy(binding, "DO_PUSH", {})
			end
			assert.equal(3, #st.buttons)
			assert.equal(0, #c4.calls_to("SendToProxy"))
		end)

		it("leaves a message for a link the instance does not own to the driver's other modules", function()
			local _, _, _, dispatch, st = new_device({ proxy_binding = 5002 })
			local fan_links = {}
			dispatch.binding(300)["DO_PUSH"] = function(binding) fan_links[#fan_links + 1] = binding end
			dispatch.received_from_proxy(300, "DO_PUSH", {})
			dispatch.received_from_proxy(300, "DO_CLICK", {})
			assert.same({ 300 }, fan_links)
			assert.same({}, st.buttons, "the light's machine never saw link 300")
		end)
	end)

	describe("a proxy on another binding (the fan driver's light on 5002)", function()
		local function bindings_of(c4)
			local seen = {}
			for _, args in ipairs(c4.calls_to("SendToProxy")) do seen[args[1]] = (seen[args[1]] or 0) + 1 end
			return seen
		end

		it("takes the binding as a number or a numeric string, 5001 by default, and keeps it in proxy_binding", function()
			local dev, _, _, _, _, device = new_device()
			assert.equal(5001, device.PROXY_BINDING)
			assert.equal(5001, dev.proxy_binding)
			assert.equal(5002, (new_device({ proxy_binding = 5002 })).proxy_binding)
			assert.equal(5002, (new_device({ proxy_binding = "5002" })).proxy_binding)
		end)

		it("refuses a binding that is no number, rather than sending the light's messages to 5001", function()
			package.loaded["common.device"] = nil
			package.loaded["common.dispatch"] = nil
			fake.install_c4({})
			local device = require("common.device")
			local ok, err = pcall(device.new, { proxy_binding = "light" })
			assert.is_false(ok)
			assert.truthy(tostring(err):find("proxy_binding is a binding number, got light", 1, true))
		end)

		it("notify goes to that binding, with the parameter dump as before", function()
			local dev, c4 = new_device({ proxy_binding = 5002 })
			local lines = capture_log()
			dev.notify("LIGHT_BRIGHTNESS_CHANGED", { LIGHT_BRIGHTNESS_CURRENT = 40 })
			assert.same({ { 5002, { LIGHT_BRIGHTNESS_CURRENT = 40 } } }, proxied(c4, "LIGHT_BRIGHTNESS_CHANGED"))
			assert.same({}, c4.proxy_messages(5001))
			assert.same({}, lines)
			log.set_debug(true)
			dev.notify("LIGHT_BRIGHTNESS_CHANGING", { RATE = 0, LIGHT_BRIGHTNESS_TARGET = 75, LIGHT_BRIGHTNESS_CURRENT = 40 })
			assert.same({ "[DEBUG] Test Device: -> proxy LIGHT_BRIGHTNESS_CHANGING"
				.. " LIGHT_BRIGHTNESS_CURRENT=40 LIGHT_BRIGHTNESS_TARGET=75 RATE=0" }, lines)
		end)

		it("sends BUTTON_INFO to that binding as a NOTIFY, and the link LEDs to the links as COMMANDs", function()
			local dev, c4, _, _, st = new_device({ proxy_binding = 5002 })
			st.on = false
			dev.update_leds()
			assert.same({ 5002, 5002, 5002 }, { proxied(c4, "BUTTON_INFO")[1][1], proxied(c4, "BUTTON_INFO")[2][1],
				proxied(c4, "BUTTON_INFO")[3][1] })
			assert.equal(3, #proxied(c4, "BUTTON_INFO"))
			assert.same({ BUTTON_ID = 1, ON_COLOR = "000000", OFF_COLOR = "0000ff", CURRENT_COLOR = "0000ff" },
				proxied(c4, "BUTTON_INFO")[2][2])
			for _, message in ipairs(c4.proxy_messages(5002)) do
				assert.same({ "BUTTON_INFO", "NOTIFY" }, { message[1], message[3] })
			end
			assert.same({ { 200, { STATE = false } }, { 201, { STATE = false } }, { 202, { STATE = false } } },
				proxied(c4, "MATCH_LED_STATE"))
			for _, link in ipairs({ 200, 201, 202 }) do
				assert.same({ { "MATCH_LED_STATE", { STATE = false }, "COMMAND" } }, c4.proxy_messages(link))
			end
			assert.same({ [5002] = 3, [200] = 1, [201] = 1, [202] = 1 }, bindings_of(c4), "nothing to 5001")
		end)

		it("answers each setting on that binding, at late init and after a command", function()
			local dev, c4, _, dispatch = new_device({ proxy_binding = 5002, settings = { "preset", "hold_up", "hold_down" } })
			c4.persist.hold_rate_down = "2000"
			dev.load_settings()
			assert.same({ { 5002, "100" } }, proxied(c4, "PRESET_LEVEL"))
			assert.same({ { 5002, "5000" } }, proxied(c4, "HOLD_RATE_UP"))
			assert.same({ { 5002, "2000" } }, proxied(c4, "HOLD_RATE_DOWN"))
			dispatch.received_from_proxy(5002, "SET_PRESET_LEVEL", { LEVEL = "60" })
			dispatch.received_from_proxy(5002, "SET_HOLD_RATE_UP", { RATE = "fast" })
			assert.same({ 5002, "60" }, proxied(c4, "PRESET_LEVEL")[2])
			assert.same({ 5002, "5000" }, proxied(c4, "HOLD_RATE_UP")[2], "a refused value: the one kept, on the same binding")
			assert.same({ [5002] = 5 }, bindings_of(c4), "three at load, one per command")
			-- The proxy that is not ours sends the same commands; they change nothing here.
			dispatch.received_from_proxy(5001, "SET_PRESET_LEVEL", { LEVEL = "30" })
			assert.equal(60, dev.setting("preset"))
			assert.equal(5, #c4.calls_to("SendToProxy"))
		end)

		it("echoes BUTTON_ACTION on that binding", function()
			local _, c4, _, dispatch, st = new_device({ proxy_binding = 5002 })
			dispatch.received_from_proxy(5002, "BUTTON_ACTION", { BUTTON_ID = "0", ACTION = "1" })
			assert.same({ { 5002, { BUTTON_ID = 0, ACTION = 1 } } }, proxied(c4, "BUTTON_ACTION"))
			assert.same({ { 0, 1 } }, st.buttons)
		end)

		it("keeps the Button Links' colours on the links and answers the light's page on its binding", function()
			local _, c4, _, dispatch, st = new_device({ proxy_binding = 5002 })
			st.on = true
			dispatch.received_from_proxy(200, "REQUEST_BUTTON_COLORS", {})
			assert.same({ { 200, { BUTTON_ID = 0, ON_COLOR = "0000ff", OFF_COLOR = "000000", CURRENT_COLOR = "0000ff" } } },
				proxied(c4, "BUTTON_COLORS"))
			assert.same({ { 200, { STATE = true } } }, proxied(c4, "MATCH_LED_STATE"))
			dispatch.received_from_proxy(5002, "SET_BUTTON_COLOR", { BUTTON_ID = "2", OFF_COLOR = "00FF00" })
			assert.equal("00ff00", c4.persist.button_2_off_color)
			assert.same({ 202, { BUTTON_ID = 2, ON_COLOR = "0000ff", OFF_COLOR = "00ff00", CURRENT_COLOR = "0000ff" } },
				proxied(c4, "BUTTON_COLORS")[2])
			assert.same({ { 5002, { BUTTON_ID = 2, ON_COLOR = "0000ff", OFF_COLOR = "00ff00", CURRENT_COLOR = "0000ff" } } },
				proxied(c4, "BUTTON_INFO"))
			-- Not on the other proxy's binding.
			dispatch.received_from_proxy(5001, "SET_BUTTON_COLOR", { BUTTON_ID = "0", ON_COLOR = "ff0000" })
			assert.is_nil(c4.persist.button_0_on_color)
		end)

		it("proxy_id looks for the consumer on that binding", function()
			local dev, c4 = new_device({ proxy_binding = 5002 })
			c4.GetBoundConsumerDevices = function(_, id, binding)
				assert.equal(15, id)
				assert.equal(5002, binding)
				return { [3002] = "Example Light" }
			end
			assert.equal(3002, dev.proxy_id())
			c4.GetBoundConsumerDevices = function() return nil end
			assert.is_nil(dev.proxy_id())
		end)

		it("proxy_id finds each proxy of the fan driver's runtime on its own binding", function()
			local light, _, env, _, _, device = new_device({ proxy_binding = 5002 })
			local fan = device.new({ prefix = "Test Device" })
			assert.equal(fake.proxy_id(env, 5002), light.proxy_id())
			assert.equal(fake.proxy_id(env, 5001), fan.proxy_id())
			assert.is_number(light.proxy_id())
			assert.are_not.equal(light.proxy_id(), fan.proxy_id())
		end)
	end)

	describe("parsers", function()
		it("text is a string or nil for absent and empty", function()
			local device = require("common.device")
			assert.equal("7", device.text(7))
			assert.equal("a", device.text("a"))
			assert.is_nil(device.text(""))
			assert.is_nil(device.text(nil))
		end)

		it("to_bool reads booleans, true/false and 1/0 in any case, nil otherwise", function()
			local device = require("common.device")
			assert.is_true(device.to_bool(true))
			assert.is_false(device.to_bool(false))
			assert.is_true(device.to_bool("TRUE"))
			assert.is_true(device.to_bool("1"))
			assert.is_false(device.to_bool("False"))
			assert.is_false(device.to_bool(0))
			assert.is_nil(device.to_bool("yes"))
			assert.is_nil(device.to_bool(nil))
		end)
	end)
end)
