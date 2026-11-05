-- fan.links on fakes: the nine fan Button Links (300 to 308) as a keypad
-- drives them, the LED rules and Speed N Link Also Lit At, the colours of
-- V27, and the Keypad Links bookkeeping of all twelve links (sections 5.1,
-- 5.3 and 9.8). The event orders are the ones measured on the house keypad
-- (K6 and K7, section 11.1): a tap is push then click 0.15 to 0.25 s later, a
-- hold is push then release, a double tap is two push and click pairs, and a
-- bind is followed 3 ms later by REQUEST_BUTTON_COLORS. The model, the texts
-- and the clock are hand-made; the proxy is the real fan.fanproxy only where a
-- test says so, to show what the links and the proxy do with the same press.

local links = require("fan.links")
local fanproxy = require("fan.fanproxy")
local log = require("common.log")

local REAL_SINK = log.sink

local FAN_IDS = { 300, 301, 302, 303, 304, 305, 306, 307, 308 }
local ALL_IDS = { 200, 201, 202, 300, 301, 302, 303, 304, 305, 306, 307, 308 }

local function quiet()
	log.sink = function() end
end

local function capture_log()
	local lines = {}
	log.sink = function(line) lines[#lines + 1] = line end
	return lines
end

local function contains(lines, needle)
	for _, line in ipairs(lines) do
		if line:find(needle, 1, true) then
			return true
		end
	end
	return false
end

-- The parts of model.lua the links use; want() puts the wanted fields over
-- the shown state as the real model's shown() does.
local function fake_model(shown)
	local m = { wants = {}, shown_state = shown or {} }
	function m:want(fields)
		local copy = {}
		for k, v in pairs(fields) do
			copy[k] = v
			self.shown_state[k] = v
		end
		self.wants[#self.wants + 1] = copy
		return true
	end
	function m:shown()
		local out = {}
		for k, v in pairs(self.shown_state) do
			out[k] = v
		end
		return out
	end
	function m:confirmed()
		return nil
	end
	return m
end

-- fan.fanproxy's intents, recorded.
local function fake_fan()
	local f = { calls = {}, refuse = nil }
	function f:record(call)
		self.calls[#self.calls + 1] = call
		if self.refuse then
			return false, self.refuse
		end
		return true
	end
	function f:off() return self:record({ "off" }) end
	function f:toggle() return self:record({ "toggle" }) end
	function f:speed(n) return self:record({ "speed", n }) end
	function f:cycle(step, wrap) return self:record({ "cycle", step, wrap }) end
	return f
end

-- texts.keypad_links as section 7.3 shows it: "5 of 12 links bound", then a
-- row per bound keypad; a keypad without a name is worded by device id, as
-- fan/texts.lua does.
local function fake_texts()
	local t = { calls = {} }
	function t.keypad_links(rows)
		t.calls[#t.calls + 1] = rows
		local seen, bound_links, items = {}, 0, {}
		for _, row in ipairs(rows) do
			if not seen[row.link_name] then
				seen[row.link_name] = true
				bound_links = bound_links + 1
			end
		end
		items[1] = string.format("%d of 12 links bound", bound_links)
		for _, row in ipairs(rows) do
			if row.keypad_name == "" then
				items[#items + 1] = string.format("%s: device %d", row.link_name, row.device_id)
			else
				items[#items + 1] = string.format("%s: %s (%d)", row.link_name, row.keypad_name, row.device_id)
			end
		end
		return items
	end
	return t
end

-- Links on fakes. opts: shown (the model's shown state), real_fan (use
-- fan.fanproxy over the same model), project ([link] = what
-- GetBoundConsumerDevices answers, or a function), names ([device_id] = name),
-- no_timer, no_list.
local function rig(opts)
	opts = opts or {}
	local r = {
		clock = { t = 100000 }, timers = {}, sent = {}, handlers = {}, registered = {}, listed = {}, reads = {},
		proxy_sent = {}, project = opts.project or {}, names = opts.names or {}, texts = fake_texts(),
		model = fake_model(opts.shown),
	}
	local function on(binding, command, handler)
		r.registered[#r.registered + 1] = binding .. " " .. command
		r.handlers[binding .. ":" .. command] = handler
	end
	local function send(link, command, params, kind)
		r.sent[#r.sent + 1] = { link = link, command = command, params = params, kind = kind }
	end
	local function timer(ms, cb)
		local t = { due = r.clock.t + ms, ms = ms, cb = cb, cancelled = false, fired = false }
		function t:Cancel() self.cancelled = true end
		r.timers[#r.timers + 1] = t
		return t
	end
	if opts.real_fan then
		r.fan = fanproxy.new({
			model = r.model, on = on, log = log, can_reverse = true,
			send = function(command, params) r.proxy_sent[#r.proxy_sent + 1] = { command, params } end,
		})
	else
		r.fan = fake_fan()
	end
	r.lk = links.new({
		model = r.model, fan = r.fan, on = on, send = send,
		now = function() return r.clock.t end,
		timer = not opts.no_timer and timer or nil,
		bound = function(link)
			r.reads[#r.reads + 1] = link
			local answer = r.project[link]
			if type(answer) == "function" then
				return answer()
			end
			return answer
		end,
		display = function(id) return r.names[id] end,
		list = not opts.no_list and function(items) r.listed[#r.listed + 1] = items end or nil,
		texts = r.texts,
		log = log,
	})

	-- A message as Director delivers it: the link's binding and the parameters.
	function r.recv(link, command, params)
		local handler = r.handlers[link .. ":" .. command]
		assert(handler, "no handler registered for " .. link .. " " .. command)
		return handler(link, params)
	end
	function r.advance(ms)
		r.clock.t = r.clock.t + ms
		for _, t in ipairs(r.timers) do
			if not t.cancelled and not t.fired and t.due <= r.clock.t then
				t.fired = true
				t.cb()
			end
		end
	end
	-- The model changed the shown state and told its listener.
	function r.show(shown)
		r.model.shown_state = shown
		r.lk:shown(r.model:shown())
	end
	-- MATCH_LED_STATE sends since the last clear, as "303:true".
	function r.leds()
		local out = {}
		for _, s in ipairs(r.sent) do
			if s.command == "MATCH_LED_STATE" then
				out[#out + 1] = s.link .. ":" .. tostring(s.params.STATE)
			end
		end
		return out
	end
	-- Every send, as "303 BUTTON_COLORS" and "303 MATCH_LED_STATE", in order.
	function r.trace()
		local out = {}
		for _, s in ipairs(r.sent) do
			out[#out + 1] = s.link .. " " .. s.command
		end
		return out
	end
	function r.clear()
		r.sent = {}
	end
	function r.pending_timers()
		local n = 0
		for _, t in ipairs(r.timers) do
			if not t.cancelled and not t.fired then
				n = n + 1
			end
		end
		return n
	end
	return r
end

local COLORS = { "ff0000", "ff8000", "ffff00", "00ff00", "00ffff", "0000ff" }

describe("fan.links", function()
	before_each(function()
		quiet()
		log.set_prefix(nil)
		log.set_debug(false)
	end)
	after_each(function()
		log.set_debug(false)
		log.sink = REAL_SINK
	end)

	describe("registration", function()
		it("registers the five link commands on 300 to 308 only", function()
			local r = rig()
			local expected = {}
			local commands = { "DO_PUSH", "DO_CLICK", "DO_RELEASE", "REQUEST_BUTTON_COLORS", "SET_BUTTON_COLOR" }
			for _, link in ipairs(FAN_IDS) do
				for _, command in ipairs(commands) do
					expected[#expected + 1] = link .. " " .. command
				end
			end
			assert.same(expected, r.registered, "the light's 200 to 202 are common/device.lua's")
		end)

		it("names the links as section 9.8 does", function()
			assert.same({
				[300] = "Fan Off", [301] = "Fan Speed 1", [302] = "Fan Speed 2", [303] = "Fan Speed 3",
				[304] = "Fan Speed 4", [305] = "Fan Speed 5", [306] = "Fan Speed 6", [307] = "Fan Toggle",
				[308] = "Fan Cycle",
			}, links.LINKS)
			assert.same({ [200] = "Light Top", [201] = "Light Bottom", [202] = "Light Toggle" }, links.LIGHT_LINKS)
		end)

		it("sends and reads nothing at construction", function()
			local r = rig()
			assert.same({}, r.sent)
			assert.same({}, r.reads)
			assert.same({}, r.listed)
			assert.equal(0, r.pending_timers())
		end)

		it("hands a missing argument over loudly: a wiring mistake", function()
			assert.has_error(function() links.new({ model = fake_model(), fan = fake_fan(), on = function() end }) end)
		end)
	end)

	describe("presses (section 5.1)", function()
		it("each link's push does its intent: Off, Speed 1 to 6, Toggle, Cycle (which wraps)", function()
			local r = rig()
			for _, link in ipairs(FAN_IDS) do
				r.recv(link, "DO_PUSH")
			end
			assert.same({
				{ "off" }, { "speed", 1 }, { "speed", 2 }, { "speed", 3 }, { "speed", 4 }, { "speed", 5 }, { "speed", 6 },
				{ "toggle" }, { "cycle", 1, true },
			}, r.fan.calls)
		end)

		it("a tap is push then click 0.25 s later (K6): one act, at the push", function()
			local r = rig()
			r.recv(303, "DO_PUSH")
			assert.same({ { "speed", 3 } }, r.fan.calls, "the push acts at once")
			r.advance(250)
			r.recv(303, "DO_CLICK")
			assert.same({ { "speed", 3 } }, r.fan.calls, "the click that follows it does not")
		end)

		it("a tap's click 0.15 s later is the same tap (K7)", function()
			local r = rig()
			r.recv(301, "DO_PUSH")
			r.advance(150)
			r.recv(301, "DO_CLICK")
			assert.same({ { "speed", 1 } }, r.fan.calls)
		end)

		it("a hold is push then release (K6): one act, and the release does nothing", function()
			local r = rig()
			r.recv(305, "DO_PUSH")
			r.advance(3000)
			r.recv(305, "DO_RELEASE")
			assert.same({ { "speed", 5 } }, r.fan.calls)
			r.advance(60000)
			r.recv(305, "DO_RELEASE")
			assert.same({ { "speed", 5 } }, r.fan.calls, "no repeat while held, nothing on release")
		end)

		it("a double tap is two push and click pairs (K6): it acts twice, never four times", function()
			local r = rig()
			r.recv(303, "DO_PUSH")
			r.advance(100)
			r.recv(303, "DO_CLICK")
			r.advance(120)
			r.recv(303, "DO_PUSH")
			r.advance(100)
			r.recv(303, "DO_CLICK")
			assert.same({ { "speed", 3 }, { "speed", 3 } }, r.fan.calls)
		end)

		it("a double tap on Fan Toggle toggles twice (V12: each push acts)", function()
			local r = rig()
			r.recv(307, "DO_PUSH")
			r.advance(100)
			r.recv(307, "DO_CLICK")
			r.advance(220)
			r.recv(307, "DO_PUSH")
			r.advance(100)
			r.recv(307, "DO_CLICK")
			assert.same({ { "toggle" }, { "toggle" } }, r.fan.calls)
		end)

		it("acts on a click that no push came before: a keypad that sends clicks alone", function()
			local r = rig()
			r.recv(304, "DO_CLICK")
			r.advance(500)
			r.recv(304, "DO_CLICK")
			assert.same({ { "speed", 4 }, { "speed", 4 } }, r.fan.calls)
		end)

		it("ignores a click for 10 s after a push on its link and acts on it after that (the 10 s rule)", function()
			local r = rig()
			r.recv(303, "DO_PUSH")
			r.advance(9999)
			r.recv(303, "DO_CLICK")
			assert.equal(1, #r.fan.calls, "9.999 s after the push")
			r.advance(1)
			r.recv(303, "DO_CLICK")
			assert.equal(2, #r.fan.calls, "10 s after the push: the window is over")
			assert.same({ "speed", 3 }, r.fan.calls[2])
		end)

		it("measures the 10 s from the latest push", function()
			local r = rig()
			r.recv(303, "DO_PUSH")
			r.advance(20000)
			r.recv(303, "DO_PUSH")
			r.advance(5000)
			r.recv(303, "DO_CLICK")
			assert.equal(2, #r.fan.calls, "a click 5 s after the second push is that push's")
			r.advance(5000)
			r.recv(303, "DO_CLICK")
			assert.equal(3, #r.fan.calls)
		end)

		it("keeps the rule per link: a push on one does not swallow a click on another", function()
			local r = rig()
			r.recv(303, "DO_PUSH")
			r.advance(100)
			r.recv(304, "DO_CLICK")
			assert.same({ { "speed", 3 }, { "speed", 4 } }, r.fan.calls)
		end)

		it("shares a link's record between the keypads bound to it (ECC C6)", function()
			local r = rig()
			r.recv(300, "DO_PUSH") -- one keypad
			r.advance(300)
			r.recv(300, "DO_CLICK") -- the same link from another keypad
			assert.same({ { "off" } }, r.fan.calls)
		end)

		it("does not mistake a clock that went backwards for a recent push", function()
			local r = rig()
			r.recv(303, "DO_PUSH")
			r.clock.t = r.clock.t - 50000
			r.recv(303, "DO_CLICK")
			assert.equal(2, #r.fan.calls)
		end)

		it("keeps a refused press out of everything else: logged for Debug Mode alone, no LED, no throw", function()
			local r = rig({ shown = { fan_on = true, speed = 3 } })
			r.fan.refuse = "foreign"
			local lines = capture_log()
			assert.has_no.errors(function() r.recv(303, "DO_PUSH") end)
			assert.same({}, r.sent)
			assert.same({}, lines)
			log.set_debug(true)
			r.recv(305, "DO_PUSH")
			assert.is_true(contains(lines, "link 305 (Fan Speed 5): push refused: foreign"))
		end)

		it("a release before any push is not a push: the click that follows it still acts", function()
			local r = rig()
			r.recv(306, "DO_RELEASE")
			r.recv(306, "DO_CLICK")
			assert.same({ { "speed", 6 } }, r.fan.calls)
		end)
	end)

	describe("the same press through the real proxy (V11, V12, R5)", function()
		it("Cycle wraps on the link and stops on the proxy", function()
			local r = rig({ real_fan = true, shown = { fan_on = true, speed = 6 } })
			r.recv(5001, "CYCLE_SPEED_UP")
			assert.same({}, r.model.wants, "the proxy's Cycle stops at 6")
			r.recv(308, "DO_PUSH")
			assert.same({ { fan_on = true, speed = 1 } }, r.model.wants, "the link's Cycle goes round to 1")
		end)

		it("Cycle from off goes to 1 on the link, and on from there up to 6 and round", function()
			local r = rig({ real_fan = true, shown = { fan_on = false } })
			local seen = {}
			for _ = 1, 8 do
				r.recv(308, "DO_PUSH")
				seen[#seen + 1] = r.model.wants[#r.model.wants].speed
			end
			assert.same({ 1, 2, 3, 4, 5, 6, 1, 2 }, seen)
		end)

		it("a double tap on Fan Cycle counts the second step from the first one's target and tells the proxy once", function()
			local r = rig({ real_fan = true, shown = { fan_on = true, speed = 2 } })
			r.recv(308, "DO_PUSH")
			r.advance(100)
			r.recv(308, "DO_CLICK")
			r.advance(120)
			r.recv(308, "DO_PUSH")
			r.advance(100)
			r.recv(308, "DO_CLICK")
			assert.same({ { fan_on = true, speed = 3 }, { fan_on = true, speed = 4 } }, r.model.wants)
			assert.same({}, r.proxy_sent, "no notification for the intermediate target (R4, R5)")
			r.fan:settled("fan", { fan_on = true, speed = 4 }, "command")
			assert.same({ { "CURRENT_SPEED", { SPEED = 4 } } }, r.proxy_sent)
		end)

		it("a double tap on one speed link wants that speed twice and the proxy still hears it once", function()
			local r = rig({ real_fan = true, shown = { fan_on = true, speed = 1 } })
			for _ = 1, 2 do
				r.recv(303, "DO_PUSH")
				r.advance(100)
				r.recv(303, "DO_CLICK")
				r.advance(120)
			end
			assert.same({ { fan_on = true, speed = 3 }, { fan_on = true, speed = 3 } }, r.model.wants)
			r.fan:settled("fan", { fan_on = true, speed = 3 }, "command")
			assert.equal(1, #r.proxy_sent)
		end)

		it("Toggle goes on at the designated preset and off from there", function()
			local r = rig({ real_fan = true, shown = { fan_on = false } })
			r.recv(5001, "DESIGNATE_PRESET", { PRESET = "5" })
			r.recv(307, "DO_PUSH")
			assert.same({ fan_on = true, speed = 5 }, r.model.wants[1])
			r.recv(307, "DO_PUSH")
			assert.same({ fan_on = false }, r.model.wants[2])
		end)

		it("section 9.11: a tap on Fan Speed 3 while the fan runs at 1 lights 303 at once and darkens 301", function()
			local r = rig({ real_fan = true, shown = { fan_on = true, speed = 1 } })
			r.lk:refresh()
			r.clear()
			r.recv(303, "DO_PUSH")
			assert.same({ { fan_on = true, speed = 3 } }, r.model.wants)
			r.lk:shown(r.model:shown()) -- the model's listener.shown, as the wanted state changed
			assert.same({ "301:false", "303:true" }, r.leds())
			r.advance(200)
			r.recv(303, "DO_CLICK")
			assert.same({ { fan_on = true, speed = 3 } }, r.model.wants, "the click does not act again")
			assert.same({ "301:false", "303:true" }, r.leds(), "nor does it light anything")
		end)

		it("a request that fails reverts the LEDs at once (V10): only the links that changed", function()
			local r = rig({ real_fan = true, shown = { fan_on = true, speed = 1 } })
			r.lk:refresh()
			r.recv(305, "DO_PUSH")
			r.lk:shown(r.model:shown())
			r.clear()
			r.lk:shown({ fan_on = true, speed = 1 }) -- the model: the request failed, the shown state fell back
			assert.same({ "301:true", "305:false" }, r.leds())
		end)
	end)

	describe("the LED rule (section 5.1)", function()
		it("the first shown state goes to all nine links, as a COMMAND with a boolean STATE", function()
			local r = rig()
			r.lk:shown({ fan_on = true, speed = 3 })
			assert.same({
				"300:false", "301:false", "302:false", "303:true", "304:false", "305:false", "306:false", "307:true",
				"308:true",
			}, r.leds())
			for _, s in ipairs(r.sent) do
				assert.equal("COMMAND", s.kind)
				assert.same({ STATE = s.params.STATE }, s.params)
				assert.equal("boolean", type(s.params.STATE))
			end
		end)

		it("later only the links whose lit state changed get a message", function()
			local r = rig()
			r.lk:shown({ fan_on = true, speed = 3 })
			r.clear()
			r.lk:shown({ fan_on = true, speed = 4 })
			assert.same({ "303:false", "304:true" }, r.leds())
			r.clear()
			r.lk:shown({ fan_on = true, speed = 4 })
			assert.same({}, r.leds(), "an unchanged state sends nothing")
			r.lk:shown({ fan_on = true, speed = 4, direction = "reverse", light_on = true, level = 50 })
			assert.same({}, r.leds(), "nor does a change of the light or the direction")
		end)

		it("off lights Fan Off and darkens the rest; on again lights Toggle and Cycle", function()
			local r = rig()
			r.lk:shown({ fan_on = true, speed = 6 })
			r.clear()
			r.lk:shown({ fan_on = false, speed = 6 })
			assert.same({ "300:true", "306:false", "307:false", "308:false" }, r.leds())
			r.clear()
			r.lk:shown({ fan_on = true, speed = 2 })
			assert.same({ "300:false", "302:true", "307:true", "308:true" }, r.leds())
		end)

		it("sends nothing while the state is unknown", function()
			local r = rig()
			r.lk:shown({})
			r.lk:shown(nil)
			r.lk:shown({ light_on = true, level = 80 })
			assert.same({}, r.sent)
			assert.same({}, r.lk:debug().leds)
		end)

		it("a fan on with no speed lights Off, Toggle and Cycle, and leaves the speed links as they were", function()
			local r = rig()
			r.lk:shown({ fan_on = true, speed = 2 })
			r.clear()
			r.lk:shown({ fan_on = true })
			assert.same({}, r.leds(), "same lit state for 300, 307 and 308; the speed links are unknown")
			local r2 = rig()
			r2.lk:shown({ fan_on = true })
			assert.same({ "300:false", "307:true", "308:true" }, r2.leds())
		end)

		it("an off fan darkens every speed link even where its speed is unknown", function()
			local r = rig()
			r.lk:shown({ fan_on = false })
			assert.same({
				"300:true", "301:false", "302:false", "303:false", "304:false", "305:false", "306:false", "307:false",
				"308:false",
			}, r.leds())
		end)

		it("refresh sends all nine whether they changed or not, from the model's shown state", function()
			local r = rig({ shown = { fan_on = true, speed = 5 } })
			r.lk:shown(r.model:shown())
			r.clear()
			r.lk:refresh()
			assert.same({
				"300:false", "301:false", "302:false", "303:false", "304:false", "305:true", "306:false", "307:true",
				"308:true",
			}, r.leds())
		end)

		it("refresh sends nothing while the state is unknown", function()
			local r = rig({ shown = {} })
			r.lk:refresh()
			assert.same({}, r.sent)
		end)

		it("debug() lists what each link was last sent, nil for a link never sent", function()
			local r = rig()
			r.lk:shown({ fan_on = true })
			assert.same({ [300] = false, [307] = true, [308] = true }, r.lk:debug().leds)
			r.lk:shown({ fan_on = true, speed = 4 })
			local leds = r.lk:debug().leds
			assert.is_true(leds[304])
			assert.is_false(leds[303])
			assert.is_nil(leds[200], "the light's links are device.lua's")
		end)

		it("a send that fails is logged and not counted as sent, so the next change tries again", function()
			local calls = 0
			local r = rig()
			local lk = links.new({
				model = r.model, fan = r.fan, on = function() end, now = function() return 0 end, log = log,
				send = function()
					calls = calls + 1
					if calls == 1 then
						error("proxy not ready")
					end
				end,
			})
			local lines = capture_log()
			assert.has_no.errors(function() lk:shown({ fan_on = false }) end)
			assert.is_true(contains(lines, "[ERROR] link 300 MATCH_LED_STATE failed: "))
			assert.is_nil(lk:debug().leds[300])
			lk:shown({ fan_on = false })
			assert.is_true(lk:debug().leds[300], "the second try went through")
		end)

		it("writes the sends into the debug log as section 3.7 shows them", function()
			local r = rig()
			local lines = capture_log()
			log.set_debug(true)
			r.lk:shown({ fan_on = true, speed = 3 })
			assert.is_true(contains(lines, "[DEBUG] -> link 303 MATCH_LED_STATE true"))
			assert.is_true(contains(lines, "[DEBUG] -> link 300 MATCH_LED_STATE false"))
		end)
	end)

	describe("Speed N Link Also Lit At (V26)", function()
		it("the house's Low button: Fan Speed 2 also lit at speed 1", function()
			local r = rig()
			r.lk:set_also(2, 1)
			r.lk:shown({ fan_on = true, speed = 1 })
			assert.same({
				"300:false", "301:true", "302:true", "303:false", "304:false", "305:false", "306:false", "307:true",
				"308:true",
			}, r.leds())
			r.clear()
			r.lk:shown({ fan_on = true, speed = 2 })
			assert.same({ "301:false" }, r.leds(), "302 stays lit and is not sent again; 301 goes dark")
			r.clear()
			r.lk:shown({ fan_on = true, speed = 3 })
			assert.same({ "302:false", "303:true" }, r.leds())
		end)

		it("the house's High button: Fan Speed 5 also lit at speed 6", function()
			local r = rig()
			r.lk:set_also(5, 6)
			r.lk:shown({ fan_on = true, speed = 4 })
			r.clear()
			r.lk:shown({ fan_on = true, speed = 6 })
			assert.same({ "304:false", "305:true", "306:true" }, r.leds())
			r.clear()
			r.lk:shown({ fan_on = true, speed = 5 })
			assert.same({ "306:false" }, r.leds())
			r.clear()
			r.lk:shown({ fan_on = false })
			assert.same({ "300:true", "305:false", "307:false", "308:false" }, r.leds())
		end)

		it("is only an LED rule: a press on the link still sets the link's own speed", function()
			local r = rig()
			r.lk:set_also(2, 1)
			r.recv(302, "DO_PUSH")
			assert.same({ { "speed", 2 } }, r.fan.calls)
		end)

		it("sends the link's LED again at once when the row changes, and not before the state is known", function()
			local r = rig({ shown = { fan_on = true, speed = 1 } })
			r.lk:set_also(2, 1)
			assert.same({ "302:true" }, r.leds())
			r.clear()
			r.lk:set_also(2, nil)
			assert.same({ "302:false" }, r.leds())
			r.clear()
			r.lk:set_also(2, 1)
			r.lk:set_also(2, 1)
			assert.same({ "302:true", "302:true" }, r.leds(), "the row was set; the link's LED is sent again each time")

			local unknown = rig({ shown = {} })
			unknown.lk:set_also(5, 6)
			assert.same({}, unknown.sent, "the late-init replay of the rows runs before the first contact")
			unknown.lk:shown({ fan_on = true, speed = 6 })
			assert.is_true(unknown.lk:debug().leds[305])
		end)

		it("takes the link's own speed as no other speed", function()
			local r = rig({ shown = { fan_on = true, speed = 1 } })
			r.lk:set_also(2, 1)
			r.clear()
			r.lk:set_also(2, 2)
			assert.same({ "302:false" }, r.leds())
			r.lk:shown({ fan_on = true, speed = 2 })
			r.lk:shown({ fan_on = true, speed = 1 })
			assert.is_false(r.lk:debug().leds[302])
		end)

		it("takes numbers as strings too (the rows are parsed by the driver, but Director sends text)", function()
			local r = rig({ shown = { fan_on = true, speed = 1 } })
			r.lk:set_also("2", "1")
			assert.same({ "302:true" }, r.leds())
		end)

		it("ignores a call that names no speed or no other speed, with a warning", function()
			local r = rig({ shown = { fan_on = true, speed = 1 } })
			local lines = capture_log()
			r.lk:set_also(0, 1)
			r.lk:set_also(7, 1)
			r.lk:set_also("x", 1)
			r.lk:set_also(nil, 1)
			r.lk:set_also(2, 9)
			r.lk:set_also(2, "x")
			r.lk:set_also(2, 0)
			assert.same({}, r.sent)
			assert.equal(7, #lines)
			assert.is_true(contains(lines, "[WARN] Speed 7 Link Also Lit At 1 ignored: speeds are 1 to 6"))
			r.lk:shown({ fan_on = true, speed = 1 })
			assert.is_false(r.lk:debug().leds[302], "nothing took effect")
		end)

		it("a row of one link does not touch the others", function()
			local r = rig({ shown = { fan_on = true, speed = 6 } })
			r.lk:shown(r.model:shown())
			r.clear()
			r.lk:set_also(2, 6)
			assert.same({ "302:true" }, r.leds(), "only the link whose row it is")
			r.clear()
			r.lk:set_also(3, 6)
			r.lk:set_also(3, nil)
			assert.same({ "303:true", "303:false" }, r.leds())
			r.clear()
			r.lk:shown({ fan_on = true, speed = 6 })
			assert.same({}, r.leds(), "the rows and the shown state agree")
			r.lk:shown({ fan_on = true, speed = 5 })
			assert.same({ "302:false", "305:true", "306:false" }, r.leds())
		end)
	end)

	describe("REQUEST_BUTTON_COLORS and binds (hardware K6)", function()
		it("answers the asking link, and only that link, with its LED state", function()
			local r = rig({ shown = { fan_on = true, speed = 3 } })
			r.recv(303, "REQUEST_BUTTON_COLORS")
			assert.same({ "303:true" }, r.leds())
			r.clear()
			r.recv(301, "REQUEST_BUTTON_COLORS")
			assert.same({ "301:false" }, r.leds())
			r.clear()
			r.recv(307, "REQUEST_BUTTON_COLORS")
			r.recv(300, "REQUEST_BUTTON_COLORS")
			assert.same({ "307:true", "300:false" }, r.leds())
		end)

		it("answers again each time, even when the link's LED state did not change", function()
			local r = rig({ shown = { fan_on = true, speed = 3 } })
			r.lk:shown(r.model:shown())
			r.clear()
			r.recv(303, "REQUEST_BUTTON_COLORS")
			r.recv(303, "REQUEST_BUTTON_COLORS")
			assert.same({ "303:true", "303:true" }, r.leds())
		end)

		it("answers dark while the state is unknown (ECC C14)", function()
			local r = rig({ shown = {} })
			r.recv(303, "REQUEST_BUTTON_COLORS")
			assert.same({ "303:false" }, r.leds())
			assert.is_false(r.lk:debug().leds[303])
		end)

		it("answers with the wanted state, not the confirmed one (V10)", function()
			local r = rig({ shown = { fan_on = true, speed = 3 } })
			r.model:want({ fan_on = true, speed = 5 })
			r.recv(305, "REQUEST_BUTTON_COLORS")
			r.recv(303, "REQUEST_BUTTON_COLORS")
			assert.same({ "305:true", "303:false" }, r.leds())
		end)

		it("a keypad bound to a link gets that link's LED at once", function()
			local r = rig({ shown = { fan_on = true, speed = 3 }, names = { [456] = "Example Keypad" } })
			r.lk:binding_changed(303, true, 456, 3)
			assert.same({ "303:true" }, r.leds())
			r.clear()
			r.lk:binding_changed(305, true, 456, 4)
			assert.same({ "305:false" }, r.leds())
		end)

		it("a rebind: the bind sends the LED, REQUEST_BUTTON_COLORS 3 ms later sends it again, to that link alone", function()
			local r = rig({ shown = { fan_on = true, speed = 3 }, names = { [456] = "Example Keypad" } })
			r.lk:shown(r.model:shown())
			r.clear()
			r.lk:binding_changed(303, false, 456, 3) -- Disconnect
			assert.same({}, r.sent, "the button keeps its last LED; the driver never touches a keypad's settings")
			r.advance(5000)
			r.lk:binding_changed(303, true, 456, 3)
			r.advance(3)
			r.recv(303, "REQUEST_BUTTON_COLORS")
			assert.same({ "303:true", "303:true" }, r.leds())
			for _, s in ipairs(r.sent) do
				assert.equal(303, s.link)
			end
		end)

		it("a bind before the state is known gives STATE false (ECC C14), and the first contact then lights it", function()
			local r = rig({ shown = {} })
			r.lk:binding_changed(303, true, 456, 3)
			assert.same({ "303:false" }, r.leds())
			r.clear()
			r.lk:shown({ fan_on = true, speed = 3 })
			assert.is_true(r.lk:debug().leds[303])
			local sent_303 = {}
			for _, led in ipairs(r.leds()) do
				if led:find("^303:") then
					sent_303[#sent_303 + 1] = led
				end
			end
			assert.same({ "303:true" }, sent_303)
		end)

		it("an unbind sends nothing", function()
			local r = rig({ shown = { fan_on = true, speed = 3 } })
			r.lk:binding_changed(303, false, 456, 3)
			assert.same({}, r.sent)
		end)

		it("a light link's bind is bookkeeping only: device.lua sends the light's LEDs", function()
			local r = rig({ shown = { fan_on = true, speed = 3 } })
			for _, link in ipairs({ 200, 201, 202 }) do
				r.lk:binding_changed(link, true, 456, 3)
			end
			assert.same({}, r.sent)
		end)

		it("a binding that is none of the twelve is ignored, and said so in the debug log", function()
			local r = rig({ shown = { fan_on = true, speed = 3 } })
			local lines = capture_log()
			log.set_debug(true)
			r.lk:binding_changed(5001, true, 456, 3)
			r.lk:binding_changed(999, true, 456, 3)
			r.lk:binding_changed(nil, true, 456, 3)
			assert.same({}, r.sent)
			assert.same({}, r.listed)
			assert.is_true(contains(lines, "OnBindingChanged on binding 5001: not one of the twelve links"))
		end)
	end)

	describe("SET_BUTTON_COLOR on a fan link", function()
		it("is logged at debug and ignored: nothing sent, nothing changed", function()
			local r = rig({ shown = { fan_on = true, speed = 3 } })
			local lines = capture_log()
			r.recv(303, "SET_BUTTON_COLOR", { BUTTON_ID = "0", ON_COLOR = "ff0000", OFF_COLOR = "000000" })
			assert.same({}, r.sent)
			assert.same({}, lines)
			log.set_debug(true)
			r.recv(303, "SET_BUTTON_COLOR", { BUTTON_ID = "0", ON_COLOR = "ff0000" })
			assert.is_true(contains(lines, "link 303: SET_BUTTON_COLOR ignored"))
			r.lk:shown(r.model:shown())
			for _, s in ipairs(r.sent) do
				assert.not_equal("BUTTON_COLORS", s.command)
			end
		end)
	end)

	describe("colours (V27, section 5.1 'Colours')", function()
		it("sends no BUTTON_COLORS by default: on a change, a refresh, a request or a bind", function()
			local r = rig({ shown = { fan_on = true, speed = 3 } })
			r.lk:shown({ fan_on = true, speed = 1 })
			r.lk:shown({ fan_on = true, speed = 3 })
			r.lk:refresh()
			r.recv(303, "REQUEST_BUTTON_COLORS")
			r.lk:binding_changed(303, true, 456, 3)
			assert.is_true(#r.sent > 9)
			for _, s in ipairs(r.sent) do
				assert.equal("MATCH_LED_STATE", s.command)
			end
		end)

		it("with 'keypad' set explicitly it is the same", function()
			local r = rig()
			r.lk:set_colors("keypad", COLORS, "000000")
			r.lk:shown({ fan_on = true, speed = 3 })
			for _, s in ipairs(r.sent) do
				assert.equal("MATCH_LED_STATE", s.command)
			end
		end)

		it("Per speed: a speed link lit at s gets that speed's colour, as a NOTIFY, just before its state", function()
			local r = rig()
			r.lk:set_colors("per_speed", COLORS, "101010")
			r.lk:shown({ fan_on = true, speed = 3 })
			assert.same({
				"300 MATCH_LED_STATE", "301 MATCH_LED_STATE", "302 MATCH_LED_STATE",
				"303 BUTTON_COLORS", "303 MATCH_LED_STATE",
				"304 MATCH_LED_STATE", "305 MATCH_LED_STATE", "306 MATCH_LED_STATE",
				"307 MATCH_LED_STATE", "308 MATCH_LED_STATE",
			}, r.trace(), "dark links and the Off, Toggle and Cycle links get none")
			local colors
			for _, s in ipairs(r.sent) do
				if s.command == "BUTTON_COLORS" then
					colors = s
				end
			end
			assert.equal("NOTIFY", colors.kind)
			assert.same({ ON_COLOR = "ffff00", OFF_COLOR = "101010", CURRENT_COLOR = "ffff00" }, colors.params)
		end)

		it("Per speed: the colour follows the fan's speed from link to link", function()
			local r = rig()
			r.lk:set_colors("per_speed", COLORS, "000000")
			r.lk:shown({ fan_on = true, speed = 3 })
			r.clear()
			r.lk:shown({ fan_on = true, speed = 4 })
			assert.same({ "303 MATCH_LED_STATE", "304 BUTTON_COLORS", "304 MATCH_LED_STATE" }, r.trace())
			assert.equal("00ff00", r.sent[2].params.ON_COLOR)
			r.clear()
			r.lk:shown({ fan_on = false })
			assert.same({
				"300 MATCH_LED_STATE", "304 MATCH_LED_STATE", "307 MATCH_LED_STATE", "308 MATCH_LED_STATE",
			}, r.trace())
		end)

		it("Per speed with Also Lit At: the button takes the colour of the speed the fan runs at (Low)", function()
			local r = rig()
			r.lk:set_also(2, 1)
			r.lk:set_colors("per_speed", COLORS, "000000")
			r.lk:shown({ fan_on = true, speed = 2 })
			r.clear()
			r.lk:shown({ fan_on = true, speed = 1 })
			-- 301 lights in colour 1; 302 stays lit but its colour changes from 2 to 1, so it is sent again
			assert.same({ "301 BUTTON_COLORS", "301 MATCH_LED_STATE", "302 BUTTON_COLORS", "302 MATCH_LED_STATE" }, r.trace())
			for _, s in ipairs(r.sent) do
				if s.command == "BUTTON_COLORS" then
					assert.equal("ff0000", s.params.ON_COLOR)
					assert.equal("ff0000", s.params.CURRENT_COLOR)
				end
			end
			r.clear()
			r.lk:shown({ fan_on = true, speed = 1 })
			assert.same({}, r.sent)
		end)

		it("Per speed: REQUEST_BUTTON_COLORS gets the colour first while lit, and no colour while dark", function()
			local r = rig({ shown = { fan_on = true, speed = 6 } })
			r.lk:set_colors("per_speed", COLORS, "000000")
			r.clear()
			r.recv(306, "REQUEST_BUTTON_COLORS")
			assert.same({ "306 BUTTON_COLORS", "306 MATCH_LED_STATE" }, r.trace())
			assert.equal("0000ff", r.sent[1].params.ON_COLOR)
			r.clear()
			r.recv(305, "REQUEST_BUTTON_COLORS")
			r.recv(300, "REQUEST_BUTTON_COLORS")
			r.recv(307, "REQUEST_BUTTON_COLORS")
			r.recv(308, "REQUEST_BUTTON_COLORS")
			assert.same({
				"305 MATCH_LED_STATE", "300 MATCH_LED_STATE", "307 MATCH_LED_STATE", "308 MATCH_LED_STATE",
			}, r.trace())
		end)

		it("Per speed: a bind gets the colour and the state", function()
			local r = rig({ shown = { fan_on = true, speed = 2 } })
			r.lk:set_colors("per_speed", COLORS, "000000")
			r.clear()
			r.lk:binding_changed(302, true, 456, 1)
			assert.same({ "302 BUTTON_COLORS", "302 MATCH_LED_STATE" }, r.trace())
		end)

		it("Per speed: choosing it while links are lit sends them their colours; 'keypad' again sends nothing", function()
			local r = rig({ shown = { fan_on = true, speed = 4 } })
			r.lk:set_also(5, 4)
			r.lk:shown(r.model:shown())
			r.clear()
			r.lk:set_colors("per_speed", COLORS, "000000")
			assert.same({
				"304 BUTTON_COLORS", "304 MATCH_LED_STATE", "305 BUTTON_COLORS", "305 MATCH_LED_STATE",
			}, r.trace(), "only the links lit now")
			r.clear()
			r.lk:set_colors("keypad", COLORS, "000000")
			assert.same({}, r.sent)
			r.lk:shown({ fan_on = true, speed = 6 })
			for _, s in ipairs(r.sent) do
				assert.equal("MATCH_LED_STATE", s.command)
			end
		end)

		it("Per speed: new colours reach the links that are lit", function()
			local r = rig({ shown = { fan_on = true, speed = 3 } })
			r.lk:set_colors("per_speed", COLORS, "000000")
			r.clear()
			local changed = { "ff0000", "ff8000", "123456", "00ff00", "00ffff", "0000ff" }
			r.lk:set_colors("per_speed", changed, "000000")
			assert.same({ "303 BUTTON_COLORS", "303 MATCH_LED_STATE" }, r.trace())
			assert.equal("123456", r.sent[1].params.ON_COLOR)
		end)

		it("takes upper case hex, and falls back to black for a missing or bad off colour", function()
			local r = rig({ shown = { fan_on = true, speed = 1 } })
			r.lk:set_colors("per_speed", { "FF00AA", "ff8000", "ffff00", "00ff00", "00ffff", "0000ff" }, nil)
			assert.equal("ff00aa", r.sent[1].params.ON_COLOR)
			assert.equal("000000", r.sent[1].params.OFF_COLOR)
			r.clear()
			r.lk:set_colors("per_speed", COLORS, "not a color")
			assert.equal("000000", r.sent[1].params.OFF_COLOR)
		end)

		it("a speed without a valid colour is lit in the keypad's own colour, with a warning", function()
			local r = rig({ shown = { fan_on = true, speed = 2 } })
			local lines = capture_log()
			r.lk:set_colors("per_speed", { "ff0000", "zzzzzz", "ffff00" }, "000000")
			assert.same({ "302 MATCH_LED_STATE" }, r.trace())
			assert.is_true(contains(lines, "[WARN] Speed 2 LED Color zzzzzz is not a 6-digit hex colour"))
			assert.is_false(contains(lines, "Speed 3 LED Color"), "a good colour is not mentioned")
			assert.is_false(contains(lines, "Speed 4 LED Color"), "a speed left out is not an error")
		end)

		it("an unknown mode changes nothing", function()
			local r = rig({ shown = { fan_on = true, speed = 2 } })
			local lines = capture_log()
			r.lk:set_colors("rainbow", COLORS, "000000")
			assert.same({}, r.sent)
			assert.is_true(contains(lines, "[WARN] Speed LED Colors rainbow ignored"))
			r.lk:shown({ fan_on = true, speed = 2 })
			for _, s in ipairs(r.sent) do
				assert.equal("MATCH_LED_STATE", s.command)
			end
		end)

		it("sends nothing from set_colors while the state is unknown", function()
			local r = rig({ shown = {} })
			r.lk:set_colors("per_speed", COLORS, "000000")
			assert.same({}, r.sent)
		end)
	end)

	describe("Keypad Links bookkeeping (section 5.3)", function()
		it("late init reads every link once, in order, and writes the list: a count and a row per keypad", function()
			local r = rig({
				names = { [456] = "Example Keypad", [457] = "Second Keypad" },
				project = {
					[303] = { [456] = "x" },
					[200] = { [457] = "x" },
					[300] = { [457] = "x", [456] = "x" },
				},
			})
			r.lk:late_init()
			assert.same(ALL_IDS, r.reads)
			assert.equal(1, #r.listed)
			assert.same({
				"3 of 12 links bound",
				"Light Top: Second Keypad (457)",
				"Fan Off: Example Keypad (456)",
				"Fan Off: Second Keypad (457)",
				"Fan Speed 3: Example Keypad (456)",
			}, r.listed[1])
			assert.is_nil(r.lk:debug().leds[300], "no LED is sent by reading who is bound")
			assert.equal(3, r.lk:debug().bound)
		end)

		it("hands texts rows that carry the field names and the positions", function()
			local r = rig({ names = { [456] = "Example Keypad" }, project = { [303] = { [456] = "x" } } })
			r.lk:late_init()
			assert.same({
				{
					"Fan Speed 3", "Example Keypad", 456,
					link_name = "Fan Speed 3", keypad_name = "Example Keypad", device_id = 456,
				},
			}, r.texts.calls[1])
		end)

		it("nothing bound anywhere: every link answers nil, the list says 0 of 12, a second look comes 5 s later", function()
			local r = rig()
			r.lk:late_init()
			assert.same({ { "0 of 12 links bound" } }, r.listed)
			assert.equal(1, r.pending_timers())
			assert.equal(5000, r.timers[1].ms)
			r.reads = {}
			r.advance(4999)
			assert.same({}, r.reads)
			r.advance(1)
			assert.same(ALL_IDS, r.reads, "every link that answered nil is read once more")
			assert.equal(1, #r.listed, "nothing changed, so the property is not written again")
			assert.equal(0, r.lk:debug().bound)
		end)

		it("the second look reads only the links that answered nil, and shows what it finds", function()
			local second = false
			local r = rig({
				names = { [456] = "Example Keypad" },
				project = {
					[301] = { [456] = "x" },
					[304] = function() return second and { [456] = "x" } or nil end,
				},
			})
			r.lk:late_init()
			assert.same({ "1 of 12 links bound", "Fan Speed 1: Example Keypad (456)" }, r.listed[1])
			second = true
			r.reads = {}
			r.advance(5000)
			local again = {}
			for _, link in ipairs(ALL_IDS) do
				if link ~= 301 then
					again[#again + 1] = link
				end
			end
			assert.same(again, r.reads, "301 answered a table the first time and is not read again")
			assert.equal(2, #r.listed)
			assert.same({
				"2 of 12 links bound", "Fan Speed 1: Example Keypad (456)", "Fan Speed 4: Example Keypad (456)",
			}, r.listed[2])
		end)

		it("reads a second nil as nothing bound, and only once more", function()
			local r = rig()
			r.lk:late_init()
			r.advance(5000)
			r.advance(60000)
			assert.equal(1, #r.timers, "the second look arms no third")
			assert.equal(0, r.pending_timers())
			assert.same({ "0 of 12 links bound" }, r.listed[#r.listed])
		end)

		it("a link an event has told about since is not overwritten by the second look", function()
			local r = rig({ names = { [456] = "Example Keypad" } })
			r.lk:late_init()
			r.lk:binding_changed(303, true, 456, 3)
			r.project[303] = nil -- Director's table lags behind the event
			r.advance(5000)
			assert.same({ "1 of 12 links bound", "Fan Speed 3: Example Keypad (456)" }, r.listed[#r.listed])
		end)

		it("stop() cancels the second look", function()
			local r = rig()
			r.lk:late_init()
			r.lk:stop()
			assert.equal(0, r.pending_timers())
			r.reads = {}
			r.advance(10000)
			assert.same({}, r.reads)
		end)

		it("a late init run again starts over: one pending second look, not two", function()
			local r = rig()
			r.lk:late_init()
			r.lk:late_init()
			assert.equal(1, r.pending_timers())
			assert.is_true(r.timers[1].cancelled)
		end)

		it("late init needs no timer: without one it reads once and does not fail", function()
			local r = rig({ no_timer = true })
			assert.has_no.errors(function() r.lk:late_init() end)
			assert.equal(1, #r.listed)
		end)

		it("late init arms no second look when every link answered a table", function()
			local project = {}
			for _, link in ipairs(ALL_IDS) do
				project[link] = {}
			end
			local r = rig({ project = project })
			r.lk:late_init()
			assert.equal(0, r.pending_timers())
			assert.same({ { "0 of 12 links bound" } }, r.listed)
		end)

		it("an unreadable link counts as unknown: warned, read again, never a failure", function()
			local r = rig({ project = { [303] = function() error("Director is busy") end } })
			local lines = capture_log()
			assert.has_no.errors(function() r.lk:late_init() end)
			assert.is_true(contains(lines, "[WARN] link 303: the bound keypads could not be read"))
			assert.equal(1, r.pending_timers())
		end)

		it("names a keypad by C4:GetDeviceDisplayName, else by the binding table, else leaves the name to texts", function()
			local r = rig({
				names = { [456] = "Example Keypad" },
				project = { [301] = { [456] = "old name", [457] = "Table Name", [458] = "" } },
			})
			r.lk:late_init()
			assert.same({
				"1 of 12 links bound",
				"Fan Speed 1: Example Keypad (456)",
				"Fan Speed 1: Table Name (457)",
				"Fan Speed 1: device 458",
			}, r.listed[1])
			assert.equal("", r.texts.calls[1][3].keypad_name, "an empty name, never nil")
		end)

		it("survives a display lookup that raises", function()
			local r = rig({ project = { [301] = { [456] = "Table Name" } } })
			local lk = links.new({
				model = r.model, fan = r.fan, on = function() end, send = function() end, now = function() return 0 end,
				bound = function(link) return r.project[link] end,
				display = function() error("no such device") end,
				list = function(items) r.listed[#r.listed + 1] = items end, texts = r.texts, log = log,
			})
			assert.has_no.errors(function() lk:late_init() end)
			assert.same({ "1 of 12 links bound", "Fan Speed 1: Table Name (456)" }, r.listed[1])
		end)

		it("a bind adds the keypad to the list, a second keypad on the same link adds a row (ECC C6)", function()
			local r = rig({ names = { [456] = "Example Keypad", [457] = "Second Keypad" } })
			r.lk:late_init()
			r.lk:binding_changed(303, true, 456, 3)
			assert.same({ "1 of 12 links bound", "Fan Speed 3: Example Keypad (456)" }, r.listed[#r.listed])
			r.project[303] = { [456] = "x" }
			r.lk:binding_changed(303, true, 457, 5)
			assert.same({
				"1 of 12 links bound", "Fan Speed 3: Example Keypad (456)", "Fan Speed 3: Second Keypad (457)",
			}, r.listed[#r.listed])
			assert.equal(1, r.lk:debug().bound, "one link, two keypads")
		end)

		it("an unbind removes the keypad even while Director's table still lists it, and keeps the other", function()
			local r = rig({
				names = { [456] = "Example Keypad", [457] = "Second Keypad" },
				project = { [303] = { [456] = "x", [457] = "x" } },
			})
			r.lk:late_init()
			assert.equal(3, #r.listed[1])
			r.lk:binding_changed(303, false, 456, 3)
			assert.same({ "1 of 12 links bound", "Fan Speed 3: Second Keypad (457)" }, r.listed[#r.listed])
			r.project[303] = nil
			r.lk:binding_changed(303, false, 457, 3)
			assert.same({ "0 of 12 links bound" }, r.listed[#r.listed])
			assert.equal(0, r.lk:debug().bound)
		end)

		it("an unbind that names no keypad reads Director's table instead", function()
			local r = rig({
				names = { [456] = "Example Keypad" },
				project = { [303] = { [456] = "x" } },
			})
			r.lk:late_init()
			r.project[303] = nil
			r.lk:binding_changed(303, false, 0, 0)
			assert.same({ "0 of 12 links bound" }, r.listed[#r.listed])
		end)

		it("takes the link and the keypad as text too, and a boolean bound that is nil as unbound", function()
			local r = rig({ names = { [456] = "Example Keypad" } })
			r.lk:late_init()
			r.lk:binding_changed("303", true, "456", "3")
			assert.same({ "1 of 12 links bound", "Fan Speed 3: Example Keypad (456)" }, r.listed[#r.listed])
			r.lk:binding_changed("303", nil, "456", "3")
			assert.same({ "0 of 12 links bound" }, r.listed[#r.listed])
		end)

		it("the light's links are in the list under their names, in link order before the fan's", function()
			local r = rig({ names = { [456] = "Example Keypad" } })
			r.lk:late_init()
			r.lk:binding_changed(308, true, 456, 1)
			r.lk:binding_changed(201, true, 456, 2)
			r.lk:binding_changed(202, true, 456, 3)
			assert.same({
				"3 of 12 links bound",
				"Light Bottom: Example Keypad (456)",
				"Light Toggle: Example Keypad (456)",
				"Fan Cycle: Example Keypad (456)",
			}, r.listed[#r.listed])
		end)

		it("writes the property only when the items change", function()
			local r = rig({ names = { [456] = "Example Keypad" } })
			r.lk:late_init()
			local before = #r.listed
			r.lk:binding_changed(303, true, 456, 3)
			assert.equal(before + 1, #r.listed)
			r.lk:binding_changed(303, true, 456, 3)
			assert.equal(before + 1, #r.listed, "the same bind twice")
		end)

		it("a failed write is logged and tried again at the next change", function()
			local r = rig({ names = { [456] = "Example Keypad" } })
			local fail = true
			local lk = links.new({
				model = r.model, fan = r.fan, on = function() end, send = function() end, now = function() return 0 end,
				bound = function() return nil end, texts = r.texts, log = log,
				list = function(items)
					if fail then
						error("property not ready")
					end
					r.listed[#r.listed + 1] = items
				end,
			})
			local lines = capture_log()
			assert.has_no.errors(function() lk:late_init() end)
			assert.is_true(contains(lines, "[ERROR] Keypad Links could not be written"))
			fail = false
			lk:binding_changed(201, false, 0, 0)
			assert.same({ { "0 of 12 links bound" } }, r.listed)
		end)

		it("a texts module that fails leaves the list alone and warns", function()
			local r = rig()
			r.texts.keypad_links = function() error("boom") end
			local lines = capture_log()
			assert.has_no.errors(function() r.lk:late_init() end)
			assert.same({}, r.listed)
			assert.is_true(contains(lines, "[WARN] Keypad Links: the text could not be built"))
		end)

		it("takes fan.texts when none is given", function()
			local saved = package.loaded["fan.texts"]
			local used = {}
			package.loaded["fan.texts"] = {
				keypad_links = function(rows)
					used[#used + 1] = #rows
					return { "from the module" }
				end,
			}
			local listed = {}
			local lk = links.new({
				model = fake_model(), fan = fake_fan(), on = function() end, send = function() end,
				now = function() return 0 end, bound = function() return nil end, log = log,
				list = function(items) listed[#listed + 1] = items end,
			})
			local ok, err = pcall(function() lk:late_init() end)
			package.loaded["fan.texts"] = saved
			assert(ok, err)
			assert.same({ 0 }, used)
			assert.same({ { "from the module" } }, listed)
		end)

		it("without list or bound it does nothing and fails at nothing", function()
			local r = rig({ no_list = true })
			assert.has_no.errors(function()
				r.lk:late_init()
				r.lk:binding_changed(303, true, 456, 3)
			end)
			local bare = links.new({
				model = fake_model(), fan = fake_fan(), on = function() end, send = function() end, now = function() return 0 end,
				log = log,
			})
			assert.has_no.errors(function()
				bare:late_init()
				bare:binding_changed(303, true, 456, 3)
				bare:stop()
			end)
		end)

		it("a bind after the first contact lights its link and lists the keypad", function()
			local r = rig({ shown = { fan_on = true, speed = 3 }, names = { [456] = "Example Keypad" } })
			r.lk:late_init()
			r.lk:refresh()
			r.clear()
			r.lk:binding_changed(303, true, 456, 3)
			assert.same({ "303:true" }, r.leds())
			assert.same({ "1 of 12 links bound", "Fan Speed 3: Example Keypad (456)" }, r.listed[#r.listed])
		end)
	end)
end)
