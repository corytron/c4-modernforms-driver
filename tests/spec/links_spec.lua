-- fan.links on fakes: the nine fan Button Links (300 to 308) and Fan Breeze
-- (311, breeze-design BZ4 and section 6) as a keypad drives them, the LED
-- rules and Speed N Link Also Lit At, the colours of V27, and the Keypad Links
-- bookkeeping of all thirteen links (sections 5.1, 5.3 and 9.8). The event
-- orders are the ones measured on the house keypad (K6 and K7, section 11.1):
-- a tap is push then click 0.15 to 0.25 s later, a hold is push then release,
-- a double tap is two push and click pairs, and a bind is followed 3 ms later
-- by REQUEST_BUTTON_COLORS. The model, the texts and the clock are hand-made;
-- the proxy is the real fan.fanproxy only where a test says so, to show what
-- the links and the proxy do with the same press.

local links = require("fan.links")
local fanproxy = require("fan.fanproxy")
local log = require("common.log")

local REAL_SINK = log.sink

local BREEZE = 311
local FAN_IDS = { 300, 301, 302, 303, 304, 305, 306, 307, 308 }
local LINK_IDS = { 300, 301, 302, 303, 304, 305, 306, 307, 308, BREEZE }
local ALL_IDS = { 200, 201, 202, 300, 301, 302, 303, 304, 305, 306, 307, 308, BREEZE }

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
	function f:cycle(step) return self:record({ "cycle", step }) end
	return f
end

-- texts.keypad_links as section 7.3 shows it: "5 of 13 links bound", then a
-- row per bound keypad; a keypad without a name is worded by device id, as
-- fan/texts.lua does. The total is the one links hands over ("?" for none).
local function fake_texts()
	local t = { calls = {}, totals = {} }
	function t.keypad_links(rows, total)
		t.calls[#t.calls + 1] = rows
		t.totals[#t.totals + 1] = total
		local seen, bound_links, items = {}, 0, {}
		for _, row in ipairs(rows) do
			if not seen[row.link_name] then
				seen[row.link_name] = true
				bound_links = bound_links + 1
			end
		end
		items[1] = string.format("%d of %s links bound", bound_links, tostring(total or "?"))
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
-- no_timer, no_list, no_breeze (no breeze_toggle and no breeze_blows, as
-- when fan/breeze.lua is not wired). Breeze: r.blows is what breeze_blows
-- answers (false by default), r.toggles counts breeze_toggle's calls and
-- r.blows_asked breeze_blows'. Breeze LEDs (breeze-leds-design section 3.2),
-- wired only with opts.leds: r.held[link] = true holds a link (r.hold_all
-- holds every link held is asked about), r.held_asked lists those links,
-- r.repaints the links repaint was called for and r.pixel_lists every list
-- pixels took; opts.held, opts.repaint and opts.pixels replace the recorders.
local function rig(opts)
	opts = opts or {}
	local r = {
		clock = { t = 100000 }, timers = {}, sent = {}, handlers = {}, registered = {}, listed = {}, reads = {},
		proxy_sent = {}, project = opts.project or {}, names = opts.names or {}, texts = fake_texts(),
		model = fake_model(opts.shown), blows = false, toggles = 0, blows_asked = 0,
		held = {}, hold_all = false, held_asked = {}, repaints = {}, pixel_lists = {},
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
		breeze_toggle = not opts.no_breeze and function() r.toggles = r.toggles + 1 end or nil,
		breeze_blows = not opts.no_breeze and function()
			r.blows_asked = r.blows_asked + 1
			return r.blows
		end or nil,
		held = opts.leds and (opts.held or function(link)
			r.held_asked[#r.held_asked + 1] = link
			return r.hold_all or r.held[link] == true
		end) or nil,
		repaint = opts.leds and (opts.repaint or function(link) r.repaints[#r.repaints + 1] = link end) or nil,
		pixels = opts.leds and (opts.pixels or function(list) r.pixel_lists[#r.pixel_lists + 1] = list end) or nil,
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
		it("registers the five link commands on 300 to 308 and 311 only", function()
			local r = rig()
			local expected = {}
			local commands = { "DO_PUSH", "DO_CLICK", "DO_RELEASE", "REQUEST_BUTTON_COLORS", "SET_BUTTON_COLOR" }
			for _, link in ipairs(LINK_IDS) do
				for _, command in ipairs(commands) do
					expected[#expected + 1] = link .. " " .. command
				end
			end
			assert.same(expected, r.registered, "the light's 200 to 202 are common/device.lua's")
		end)

		it("names the links as section 9.8 and breeze-design section 6 do", function()
			assert.same({
				[300] = "Fan Off", [301] = "Fan Speed 1", [302] = "Fan Speed 2", [303] = "Fan Speed 3",
				[304] = "Fan Speed 4", [305] = "Fan Speed 5", [306] = "Fan Speed 6", [307] = "Fan Toggle",
				[308] = "Fan Cycle", [311] = "Fan Breeze",
			}, links.LINKS)
			assert.equal(311, links.BREEZE)
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
		it("each link's push does its intent: Off, Speed 1 to 6, Toggle, Cycle", function()
			local r = rig()
			for _, link in ipairs(FAN_IDS) do
				r.recv(link, "DO_PUSH")
			end
			assert.same({
				{ "off" }, { "speed", 1 }, { "speed", 2 }, { "speed", 3 }, { "speed", 4 }, { "speed", 5 }, { "speed", 6 },
				{ "toggle" }, { "cycle", 1 },
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
		it("Cycle stops at 6 on the link as on the proxy (#77)", function()
			local r = rig({ real_fan = true, shown = { fan_on = true, speed = 6 } })
			r.recv(5001, "CYCLE_SPEED_UP")
			assert.same({}, r.model.wants, "the proxy's Cycle stops at 6")
			r.recv(308, "DO_PUSH")
			assert.same({}, r.model.wants, "and so does the link's: nothing is sent at 6")
		end)

		it("Cycle from off goes to 1 on the link, and on from there up to 6, where it stays", function()
			local r = rig({ real_fan = true, shown = { fan_on = false } })
			local seen = {}
			for _ = 1, 8 do
				r.recv(308, "DO_PUSH")
				seen[#seen + 1] = r.model.wants[#r.model.wants].speed
			end
			assert.same({ 1, 2, 3, 4, 5, 6, 6, 6 }, seen)
			assert.equal(6, #r.model.wants, "the seventh and eighth presses send nothing")
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
		it("the first shown state goes to all ten links, as a COMMAND with a boolean STATE", function()
			local r = rig()
			r.lk:shown({ fan_on = true, speed = 3 })
			assert.same({
				"300:false", "301:false", "302:false", "303:true", "304:false", "305:false", "306:false", "307:true",
				"308:true", "311:false",
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
			assert.same({ "300:false", "307:true", "308:true", "311:false" }, r2.leds())
		end)

		it("an off fan darkens every speed link even where its speed is unknown", function()
			local r = rig()
			r.lk:shown({ fan_on = false })
			assert.same({
				"300:true", "301:false", "302:false", "303:false", "304:false", "305:false", "306:false", "307:false",
				"308:false", "311:false",
			}, r.leds())
		end)

		it("refresh sends all ten whether they changed or not, from the model's shown state", function()
			local r = rig({ shown = { fan_on = true, speed = 5 } })
			r.lk:shown(r.model:shown())
			r.clear()
			r.lk:refresh()
			assert.same({
				"300:false", "301:false", "302:false", "303:false", "304:false", "305:true", "306:false", "307:true",
				"308:true", "311:false",
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
			assert.same({ [300] = false, [307] = true, [308] = true, [311] = false }, r.lk:debug().leds)
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
				"308:true", "311:false",
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

		it("a binding that is none of the thirteen is ignored, and said so in the debug log", function()
			local r = rig({ shown = { fan_on = true, speed = 3 } })
			local lines = capture_log()
			log.set_debug(true)
			r.lk:binding_changed(5001, true, 456, 3)
			r.lk:binding_changed(999, true, 456, 3)
			r.lk:binding_changed(nil, true, 456, 3)
			assert.same({}, r.sent)
			assert.same({}, r.listed)
			assert.is_true(contains(lines, "OnBindingChanged on binding 5001: not one of the thirteen links"))
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
				"307 MATCH_LED_STATE", "308 MATCH_LED_STATE", "311 MATCH_LED_STATE",
			}, r.trace(), "dark links and the Off, Toggle, Cycle and Breeze links get none")
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
				"3 of 13 links bound",
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
			assert.same({ { "0 of 13 links bound" } }, r.listed)
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
			assert.same({ "1 of 13 links bound", "Fan Speed 1: Example Keypad (456)" }, r.listed[1])
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
				"2 of 13 links bound", "Fan Speed 1: Example Keypad (456)", "Fan Speed 4: Example Keypad (456)",
			}, r.listed[2])
		end)

		it("reads a second nil as nothing bound, and only once more", function()
			local r = rig()
			r.lk:late_init()
			r.advance(5000)
			r.advance(60000)
			assert.equal(1, #r.timers, "the second look arms no third")
			assert.equal(0, r.pending_timers())
			assert.same({ "0 of 13 links bound" }, r.listed[#r.listed])
		end)

		it("a link an event has told about since is not overwritten by the second look", function()
			local r = rig({ names = { [456] = "Example Keypad" } })
			r.lk:late_init()
			r.lk:binding_changed(303, true, 456, 3)
			r.project[303] = nil -- Director's table lags behind the event
			r.advance(5000)
			assert.same({ "1 of 13 links bound", "Fan Speed 3: Example Keypad (456)" }, r.listed[#r.listed])
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
			assert.same({ { "0 of 13 links bound" } }, r.listed)
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
				"1 of 13 links bound",
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
			assert.same({ "1 of 13 links bound", "Fan Speed 1: Table Name (456)" }, r.listed[1])
		end)

		it("a bind adds the keypad to the list, a second keypad on the same link adds a row (ECC C6)", function()
			local r = rig({ names = { [456] = "Example Keypad", [457] = "Second Keypad" } })
			r.lk:late_init()
			r.lk:binding_changed(303, true, 456, 3)
			assert.same({ "1 of 13 links bound", "Fan Speed 3: Example Keypad (456)" }, r.listed[#r.listed])
			r.project[303] = { [456] = "x" }
			r.lk:binding_changed(303, true, 457, 5)
			assert.same({
				"1 of 13 links bound", "Fan Speed 3: Example Keypad (456)", "Fan Speed 3: Second Keypad (457)",
			}, r.listed[#r.listed])
			assert.equal(1, r.lk:debug().bound, "one link, two keypads")
		end)

		it("an unbind removes a keypad whose buttons the events told, even while Director's table still lists it", function()
			local r = rig({ names = { [456] = "Example Keypad", [457] = "Second Keypad" } })
			r.lk:late_init()
			r.lk:binding_changed(303, true, 456, 3)
			r.lk:binding_changed(303, true, 457, 3)
			assert.equal(3, #r.listed[#r.listed])
			local timers = r.pending_timers()
			r.project[303] = { [456] = "x", [457] = "x" }
			r.lk:binding_changed(303, false, 456, 3)
			assert.same({ "1 of 13 links bound", "Fan Speed 3: Second Keypad (457)" }, r.listed[#r.listed])
			r.project[303] = nil
			r.lk:binding_changed(303, false, 457, 3)
			assert.same({ "0 of 13 links bound" }, r.listed[#r.listed])
			assert.equal(0, r.lk:debug().bound)
			assert.equal(timers, r.pending_timers(), "no second read: the events told every button")
		end)

		it("#92 an unbind of a keypad known only from Director's table: kept, read again 3 s later", function()
			local r = rig({
				names = { [456] = "Example Keypad", [457] = "Second Keypad" },
				project = { [303] = { [456] = "x", [457] = "x" } },
			})
			r.lk:late_init()
			local timers = r.pending_timers()
			r.lk:binding_changed(303, false, 456, 3)
			assert.equal(3, #r.listed[#r.listed], "another button of that keypad may still be bound")
			assert.equal(timers + 1, r.pending_timers())
			r.project[303] = { [457] = "x" } -- Director has caught up
			r.advance(links.REREAD_MS)
			assert.same({ "1 of 13 links bound", "Fan Speed 3: Second Keypad (457)" }, r.listed[#r.listed])
		end)

		it("#92 two buttons of one keypad on one link: unbinding one keeps the keypad, unbinding both removes it", function()
			local r = rig({ names = { [456] = "Example Keypad" } })
			r.lk:late_init()
			r.lk:binding_changed(304, true, 456, 3)
			r.project[304] = { [456] = "x" }
			r.lk:binding_changed(304, true, 456, 4)
			assert.same({ "1 of 13 links bound", "Fan Speed 4: Example Keypad (456)" }, r.listed[#r.listed])
			r.lk:binding_changed(304, false, 456, 4)
			assert.same({ "1 of 13 links bound", "Fan Speed 4: Example Keypad (456)" }, r.listed[#r.listed])
			r.project[304] = nil
			r.lk:binding_changed(304, false, 456, 3)
			assert.same({ "0 of 13 links bound" }, r.listed[#r.listed])
		end)

		it("#92 as on the house: a button bound at start, a second one bound and unbound again, the link stays", function()
			local r = rig({ names = { [456] = "Example Keypad" }, project = { [304] = { [456] = "x" } } })
			r.lk:late_init()
			assert.same({ "1 of 13 links bound", "Fan Speed 4: Example Keypad (456)" }, r.listed[#r.listed])
			r.lk:binding_changed(304, true, 456, 5)
			r.lk:binding_changed(304, false, 456, 5)
			assert.same({ "1 of 13 links bound", "Fan Speed 4: Example Keypad (456)" }, r.listed[#r.listed])
			r.advance(links.REREAD_MS)
			assert.same({ "1 of 13 links bound", "Fan Speed 4: Example Keypad (456)" }, r.listed[#r.listed],
				"the table still lists the keypad: its first button is bound")
		end)

		it("#92 an unbind that names no button takes the keypad off the link at once", function()
			local r = rig({ names = { [456] = "Example Keypad" } })
			r.lk:late_init()
			r.lk:binding_changed(304, true, 456, 3)
			r.lk:binding_changed(304, true, 456, 4)
			r.lk:binding_changed(304, false, 456, nil)
			assert.same({ "0 of 13 links bound" }, r.listed[#r.listed])
		end)

		it("#92 the second read drops a keypad the table no longer lists, keeps one an event bound", function()
			local r = rig({
				names = { [456] = "Example Keypad", [457] = "Second Keypad" },
				project = { [303] = { [456] = "x" } },
			})
			r.lk:late_init()
			r.lk:binding_changed(303, false, 456, 3)
			r.lk:binding_changed(303, true, 457, 3) -- the table lags: it does not list 457 yet
			r.project[303] = {}
			r.advance(links.REREAD_MS)
			assert.same({ "1 of 13 links bound", "Fan Speed 3: Second Keypad (457)" }, r.listed[#r.listed])
		end)

		it("#92 without a timer for the second read, the unbind is believed at once", function()
			local r = rig({ no_timer = true, names = { [456] = "Example Keypad" }, project = { [303] = { [456] = "x" } } })
			r.lk:late_init()
			r.lk:binding_changed(303, false, 456, 3)
			assert.same({ "0 of 13 links bound" }, r.listed[#r.listed])
		end)

		it("#92 stop() cancels a pending second read", function()
			local r = rig({ names = { [456] = "Example Keypad" }, project = { [303] = { [456] = "x" } } })
			r.lk:late_init()
			local timers = r.pending_timers()
			r.lk:binding_changed(303, false, 456, 3)
			assert.equal(timers + 1, r.pending_timers())
			r.lk:stop()
			assert.equal(0, r.pending_timers())
		end)

		it("an unbind that names no keypad reads Director's table instead", function()
			local r = rig({
				names = { [456] = "Example Keypad" },
				project = { [303] = { [456] = "x" } },
			})
			r.lk:late_init()
			r.project[303] = nil
			r.lk:binding_changed(303, false, 0, 0)
			assert.same({ "0 of 13 links bound" }, r.listed[#r.listed])
		end)

		it("takes the link and the keypad as text too, and a boolean bound that is nil as unbound", function()
			local r = rig({ names = { [456] = "Example Keypad" } })
			r.lk:late_init()
			r.lk:binding_changed("303", true, "456", "3")
			assert.same({ "1 of 13 links bound", "Fan Speed 3: Example Keypad (456)" }, r.listed[#r.listed])
			r.lk:binding_changed("303", nil, "456", "3")
			assert.same({ "0 of 13 links bound" }, r.listed[#r.listed])
		end)

		it("the light's links are in the list under their names, in link order before the fan's", function()
			local r = rig({ names = { [456] = "Example Keypad" } })
			r.lk:late_init()
			r.lk:binding_changed(308, true, 456, 1)
			r.lk:binding_changed(201, true, 456, 2)
			r.lk:binding_changed(202, true, 456, 3)
			assert.same({
				"3 of 13 links bound",
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
			assert.same({ { "0 of 13 links bound" } }, r.listed)
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
			assert.same({ "1 of 13 links bound", "Fan Speed 3: Example Keypad (456)" }, r.listed[#r.listed])
		end)
	end)

	-- breeze-design BZ4 and section 6 (ECB BC11, BC13, BC15, BC22, BC27): Fan
	-- Breeze is handled as Fan Toggle; its LED is breeze_blows().
	describe("fan mode and Breeze mode (#121, breeze-design BF-D2, BF93 to BF96)", function()
		local BLOWING = { fan_on = true, speed = 3, wind = true, wind_speed = 2 }

		it("Breeze mode darkens every speed link, Toggle, Cycle and Off; only 311 lights (BF93)", function()
			local r = rig()
			r.blows = true
			r.lk:shown(BLOWING)
			assert.same({
				"300:false", "301:false", "302:false", "303:false", "304:false", "305:false", "306:false", "307:false",
				"308:false", "311:true",
			}, r.leds())
		end)

		it("fan mode lights the speed, Toggle and Cycle as in 1.2, with `wind` false", function()
			local r = rig()
			r.lk:shown({ fan_on = true, speed = 3, wind = false })
			assert.same({
				"300:false", "301:false", "302:false", "303:true", "304:false", "305:false", "306:false", "307:true",
				"308:true", "311:false",
			}, r.leds())
		end)

		it("Off lights only while the motor is stopped, a stored `wind` or not (BF94, BF95)", function()
			local r = rig()
			r.lk:shown({ fan_on = false, speed = 3, wind = true })
			assert.same({
				"300:true", "301:false", "302:false", "303:false", "304:false", "305:false", "306:false", "307:false",
				"308:false", "311:false",
			}, r.leds(), "stopped with a stored `wind`: Off lit, nothing else")
			r.clear()
			r.blows = true
			r.lk:shown(BLOWING)
			assert.same({ "300:false", "311:true" }, r.leds(), "Breeze blows: Off dark, since Off would stop it")
		end)

		it("from fan mode into Breeze and back: the links of fan mode go dark, then light again", function()
			local r = rig()
			r.lk:shown({ fan_on = true, speed = 4, wind = false })
			r.clear()
			r.blows = true
			r.lk:shown({ fan_on = true, speed = 4, wind = true })
			assert.same({ "304:false", "307:false", "308:false", "311:true" }, r.leds())
			r.clear()
			r.blows = false
			r.lk:shown({ fan_on = true, speed = 2, wind = false })
			assert.same({ "302:true", "307:true", "308:true", "311:false" }, r.leds(), "fan mode at the speed it shows")
		end)

		it("gusts or a new base speed during Breeze light nothing (BF76)", function()
			local r = rig()
			r.blows = true
			r.lk:shown(BLOWING)
			r.clear()
			for speed = 1, 6 do
				r.lk:shown({ fan_on = true, speed = speed, wind = true })
			end
			r.lk:shown({ fan_on = true, wind = true })
			assert.same({}, r.leds())
		end)

		it("Also Lit At lights nothing during Breeze (BF96)", function()
			local r = rig()
			r.lk:set_also(2, 1)
			r.lk:set_also(5, 6)
			r.blows = true
			r.show({ fan_on = true, speed = 1, wind = true })
			assert.same({
				"300:false", "301:false", "302:false", "303:false", "304:false", "305:false", "306:false", "307:false",
				"308:false", "311:true",
			}, r.leds())
			r.clear()
			r.lk:set_also(2, 1)
			assert.same({ "302:false" }, r.leds(), "a changed row sends its link again: dark")
		end)

		it("Per speed: no BUTTON_COLORS during Breeze, on a change, a request, a bind or a new colour set (BF96)",
			function()
				local r = rig({ shown = { fan_on = true, speed = 3, wind = true } })
				r.blows = true
				r.lk:set_colors("per_speed", COLORS, "101010")
				r.lk:shown(r.model:shown())
				r.lk:refresh()
				r.recv(303, "REQUEST_BUTTON_COLORS")
				r.lk:binding_changed(303, true, 456, 7)
				r.lk:set_colors("per_speed", COLORS, "202020")
				for _, s in ipairs(r.sent) do
					assert.equal("MATCH_LED_STATE", s.command)
					if s.link ~= BREEZE then
						assert.is_false(s.params.STATE, tostring(s.link))
					end
				end
				r.clear()
				r.blows = false
				r.lk:shown({ fan_on = true, speed = 3, wind = false })
				assert.is_true(contains(r.trace(), "303 BUTTON_COLORS"), "fan mode again: the colour of speed 3")
			end)

		it("REQUEST_BUTTON_COLORS and a bind during Breeze answer the speed links dark and 311 lit", function()
			local r = rig({ shown = { fan_on = true, speed = 3, wind = true } })
			r.blows = true
			r.recv(303, "REQUEST_BUTTON_COLORS")
			r.recv(307, "REQUEST_BUTTON_COLORS")
			r.recv(300, "REQUEST_BUTTON_COLORS")
			r.lk:binding_changed(BREEZE, true, 456, 7)
			assert.same({ "303:false", "307:false", "300:false", "311:true" }, r.leds())
		end)

		describe("presses through the real proxy (BF-D3, BF-D4, BF78 to BF84)", function()
			it("a speed link during Breeze wants that speed and `wind` false; it lights at once and 311 goes dark",
				function()
					local r = rig({ real_fan = true, shown = { fan_on = true, speed = 3, wind = true } })
					r.blows = true
					r.lk:refresh()
					r.clear()
					r.recv(305, "DO_PUSH")
					assert.same({ { fan_on = true, speed = 5, wind = false } }, r.model.wants)
					r.blows = false -- fan/breeze.lua reads the same shown state: `wind` false
					r.lk:shown(r.model:shown())
					assert.same({ "305:true", "307:true", "308:true", "311:false" }, r.leds())
				end)

			it("a speed link at the speed the fan held during Breeze still ends Breeze (BF80)", function()
				local r = rig({ real_fan = true, shown = { fan_on = true, speed = 3, wind = true } })
				r.recv(303, "DO_PUSH")
				assert.same({ { fan_on = true, speed = 3, wind = false } }, r.model.wants)
			end)

			it("Off during Breeze stops the motor and clears `wind`; Off lights at once (BF94)", function()
				local r = rig({ real_fan = true, shown = { fan_on = true, speed = 3, wind = true } })
				r.blows = true
				r.lk:refresh()
				r.clear()
				r.recv(300, "DO_PUSH")
				assert.same({ { fan_on = false, wind = false } }, r.model.wants)
				r.blows = false
				r.lk:shown(r.model:shown())
				assert.same({ "300:true", "311:false" }, r.leds())
			end)

			it("Off with a stored `wind` and the motor stopped clears it (BF84)", function()
				local r = rig({ real_fan = true, shown = { fan_on = false, speed = 3, wind = true } })
				r.recv(300, "DO_PUSH")
				assert.same({ { fan_on = false, wind = false } }, r.model.wants)
			end)

			it("Toggle during Breeze turns fan mode on at the preset: it does not stop the spinning fan (BF79)",
				function()
					local r = rig({ real_fan = true, shown = { fan_on = true, speed = 2, wind = true } })
					r.recv(5001, "DESIGNATE_PRESET", { PRESET = "4" })
					r.recv(307, "DO_PUSH")
					assert.same({ { fan_on = true, speed = 4, wind = false } }, r.model.wants)
					r.recv(307, "DO_PUSH")
					assert.same({ fan_on = false }, r.model.wants[2], "from fan mode, off; `wind` is false by then")
				end)

			it("Cycle during Breeze counts from off: Fan Cycle gives speed 1 in fan mode (BF81)", function()
				local r = rig({ real_fan = true, shown = { fan_on = true, speed = 5, wind = true } })
				r.recv(308, "DO_PUSH")
				assert.same({ { fan_on = true, speed = 1, wind = false } }, r.model.wants)
				r.recv(308, "DO_PUSH")
				assert.same({ fan_on = true, speed = 2 }, r.model.wants[2], "and on from there in fan mode")
			end)

			it("a fan-mode press from a stopped fan with a stored `wind` clears it first (BF83)", function()
				local r = rig({ real_fan = true, shown = { fan_on = false, speed = 3, wind = true } })
				r.recv(302, "DO_PUSH")
				assert.same({ { fan_on = true, speed = 2, wind = false } }, r.model.wants)
				local t = rig({ real_fan = true, shown = { fan_on = false, speed = 3, wind = true } })
				t.recv(307, "DO_PUSH")
				assert.same({ { fan_on = true, speed = 3, wind = false } }, t.model.wants)
				local c = rig({ real_fan = true, shown = { fan_on = false, speed = 3, wind = true } })
				c.recv(308, "DO_PUSH")
				assert.same({ { fan_on = true, speed = 1, wind = false } }, c.model.wants)
			end)

			it("in fan mode with `wind` false no press adds `wind` (BF72)", function()
				for _, link in ipairs(FAN_IDS) do
					local r = rig({ real_fan = true, shown = { fan_on = true, speed = 3, wind = false } })
					r.recv(link, "DO_PUSH")
					for _, want in ipairs(r.model.wants) do
						assert.is_nil(want.wind, tostring(link))
					end
				end
			end)

			it("a fan without Breeze is never sent a `wind`, from any press in any state (BF71)", function()
				for _, shown in ipairs({ { fan_on = true, speed = 3 }, { fan_on = false, speed = 3 }, { fan_on = false } }) do
					for _, link in ipairs(FAN_IDS) do
						local r = rig({ real_fan = true, shown = shown })
						r.recv(link, "DO_PUSH")
						for _, want in ipairs(r.model.wants) do
							assert.is_nil(want.wind, tostring(link))
						end
					end
				end
			end)
		end)
	end)

	describe("Fan Breeze, link 311 (breeze-design BZ4)", function()
		-- The 311 sends since the last clear, as "311:true".
		local function breeze_leds(r)
			local out = {}
			for _, led in ipairs(r.leds()) do
				if led:find("^311:") then
					out[#out + 1] = led
				end
			end
			return out
		end

		describe("presses", function()
			it("a push toggles Breeze once and touches nothing of the fan's", function()
				local r = rig({ shown = { fan_on = true, speed = 3 } })
				r.recv(BREEZE, "DO_PUSH")
				assert.equal(1, r.toggles)
				assert.same({}, r.fan.calls, "breeze_toggle is the whole intent")
				assert.same({}, r.sent, "the LED follows the model's shown state, not the press")
			end)

			it("a tap is push then click 0.25 s later (K6): one toggle, at the push", function()
				local r = rig()
				r.recv(BREEZE, "DO_PUSH")
				assert.equal(1, r.toggles)
				r.advance(250)
				r.recv(BREEZE, "DO_CLICK")
				assert.equal(1, r.toggles, "the click that follows the push does not toggle again")
			end)

			it("a hold is push then release: one toggle, the release does nothing, nor does a release alone", function()
				local r = rig()
				r.recv(BREEZE, "DO_PUSH")
				r.advance(3000)
				r.recv(BREEZE, "DO_RELEASE")
				r.advance(60000)
				r.recv(BREEZE, "DO_RELEASE")
				assert.equal(1, r.toggles)
				local alone = rig()
				alone.recv(BREEZE, "DO_RELEASE")
				assert.equal(0, alone.toggles)
			end)

			it("a click acts only without a push on 311 in the last 10 s", function()
				local r = rig()
				r.recv(BREEZE, "DO_CLICK")
				assert.equal(1, r.toggles, "a keypad that sends clicks alone")
				r.recv(BREEZE, "DO_PUSH")
				assert.equal(2, r.toggles)
				r.advance(9999)
				r.recv(BREEZE, "DO_CLICK")
				assert.equal(2, r.toggles, "9.999 s after the push: the same tap")
				r.advance(1)
				r.recv(BREEZE, "DO_CLICK")
				assert.equal(3, r.toggles, "10 s after the push: the window is over")
			end)

			it("a double tap toggles twice, as on Fan Toggle (what each toggle does is fan/breeze.lua's, BF90)", function()
				local r = rig()
				r.recv(BREEZE, "DO_PUSH")
				r.advance(100)
				r.recv(BREEZE, "DO_CLICK")
				r.advance(220)
				r.recv(BREEZE, "DO_PUSH")
				r.advance(100)
				r.recv(BREEZE, "DO_CLICK")
				assert.equal(2, r.toggles)
			end)

			it("keeps the click rule per link: a push on 307 does not swallow a click on 311, nor 311 one on 307", function()
				local r = rig()
				r.recv(307, "DO_PUSH")
				r.advance(100)
				r.recv(BREEZE, "DO_CLICK")
				assert.equal(1, r.toggles)
				assert.same({ { "toggle" } }, r.fan.calls)
				local other = rig()
				other.recv(BREEZE, "DO_PUSH")
				other.advance(100)
				other.recv(307, "DO_CLICK")
				assert.same({ { "toggle" } }, other.fan.calls)
				assert.equal(1, other.toggles)
			end)

			it("without breeze_toggle a press does nothing: no throw, no send, a debug line only", function()
				local r = rig({ no_breeze = true, shown = { fan_on = true, speed = 3 } })
				local lines = capture_log()
				assert.has_no.errors(function()
					r.recv(BREEZE, "DO_PUSH")
					r.recv(BREEZE, "DO_CLICK")
					r.advance(20000)
					r.recv(BREEZE, "DO_CLICK")
				end)
				assert.same({}, r.sent)
				assert.same({}, r.fan.calls)
				assert.same({}, lines, "nothing at the default log level")
				log.set_debug(true)
				r.recv(BREEZE, "DO_PUSH")
				assert.is_true(contains(lines, "link 311 (Fan Breeze): push; nothing to do without Breeze"))
			end)

			it("a breeze_toggle that raises is logged as an error and fails nothing", function()
				local r = rig()
				local lk = links.new({
					model = r.model, fan = r.fan, on = function(binding, command, handler)
						r.handlers[binding .. ":" .. command] = handler
					end,
					send = function() end, now = function() return 0 end, log = log,
					breeze_toggle = function() error("breeze not ready") end,
				})
				assert.is_table(lk)
				local lines = capture_log()
				assert.has_no.errors(function() r.recv(BREEZE, "DO_PUSH") end)
				assert.is_true(contains(lines, "[ERROR] link 311 (Fan Breeze): push failed: "))
			end)

			it("a refusal breeze_toggle hands back is logged for Debug Mode alone", function()
				local r = rig()
				local lk = links.new({
					model = r.model, fan = r.fan, on = function(binding, command, handler)
						r.handlers[binding .. ":" .. command] = handler
					end,
					send = function() end, now = function() return 0 end, log = log,
					breeze_toggle = function() return false, "no_breeze" end,
				})
				assert.is_table(lk)
				local lines = capture_log()
				r.recv(BREEZE, "DO_PUSH")
				assert.same({}, lines)
				log.set_debug(true)
				r.recv(BREEZE, "DO_PUSH")
				assert.is_true(contains(lines, "link 311 (Fan Breeze): push refused: no_breeze"))
			end)
		end)

		describe("the LED (BZ1: breeze_blows)", function()
			it("follows breeze_blows, read again on every shown state, sent only when it changes", function()
				local r = rig()
				r.lk:shown({ fan_on = true, speed = 3 })
				assert.same({ "311:false" }, breeze_leds(r), "the first contact tells it dark")
				local asked = r.blows_asked
				r.clear()
				r.blows = true
				r.lk:shown({ fan_on = true, speed = 3, wind = true })
				assert.equal(asked + 1, r.blows_asked, "read again at this shown state")
				assert.same({ "303:false", "307:false", "308:false", "311:true" }, r.leds(),
					"311 lights, and fan mode's links go dark (BF-D2)")
				r.clear()
				r.lk:shown({ fan_on = true, speed = 3, wind = true })
				r.lk:shown({ fan_on = true, speed = 3, wind = true, light_on = true })
				assert.same({}, r.leds(), "the same lit state twice sends nothing")
				r.lk:shown({ fan_on = true, speed = 4, wind = true })
				assert.same({}, r.leds(), "a speed change during Breeze lights nothing: the speed does not matter then")
				r.blows = false
				r.lk:shown({ fan_on = false, speed = 4, wind = true })
				assert.same({ "300:true", "311:false" }, r.leds(), "the motor stopped: Off lights, 311 goes dark")
			end)

			it("shows a press's target at once: the model's shown state changes and breeze_blows says so", function()
				local r = rig({ shown = { fan_on = true, speed = 2 } })
				r.lk:refresh()
				r.clear()
				r.recv(BREEZE, "DO_PUSH")
				r.blows = true -- fan/breeze.lua wanted { wind = true }; the model shows it
				r.lk:shown({ fan_on = true, speed = 2, wind = true })
				assert.same({ "302:false", "307:false", "308:false", "311:true" }, r.leds())
				r.clear()
				r.blows = false -- the request failed; the shown state fell back
				r.lk:shown({ fan_on = true, speed = 2 })
				assert.same({ "302:true", "307:true", "308:true", "311:false" }, r.leds())
			end)

			it("waits for the first contact like the other links (BC22): nothing while the fan's state is unknown", function()
				local r = rig()
				r.blows = true
				r.lk:shown({})
				r.lk:shown(nil)
				r.lk:shown({ wind = true, light_on = true })
				r.lk:refresh()
				assert.same({}, r.sent)
				assert.is_nil(r.lk:debug().leds[BREEZE])
			end)

			it("refresh sends it whether it changed or not", function()
				local r = rig({ shown = { fan_on = true, speed = 1, wind = true } })
				r.blows = true
				r.lk:shown(r.model:shown())
				r.clear()
				r.lk:refresh()
				r.lk:refresh()
				assert.same({ "311:true", "311:true" }, breeze_leds(r))
			end)

			it("answers REQUEST_BUTTON_COLORS at once, each time, and dark while the state is unknown", function()
				local r = rig({ shown = { fan_on = true, speed = 3, wind = true } })
				r.blows = true
				r.recv(BREEZE, "REQUEST_BUTTON_COLORS")
				r.recv(BREEZE, "REQUEST_BUTTON_COLORS")
				assert.same({ "311:true", "311:true" }, r.leds(), "that link alone, again each time")
				local unknown = rig({ shown = {} })
				unknown.blows = true
				unknown.recv(BREEZE, "REQUEST_BUTTON_COLORS")
				assert.same({ "311:false" }, unknown.leds(), "ECC C14")
			end)

			it("a keypad bound to 311 gets its LED at once; an unbind sends nothing (BC27)", function()
				local r = rig({ shown = { fan_on = true, speed = 3, wind = true }, names = { [456] = "Example Keypad" } })
				r.blows = true
				r.lk:binding_changed(BREEZE, true, 456, 7)
				assert.same({ "311:true" }, r.leds())
				r.clear()
				r.lk:binding_changed(BREEZE, false, 456, 7)
				assert.same({}, r.sent)
				local early = rig({ shown = {} })
				early.lk:binding_changed(BREEZE, true, 456, 7)
				assert.same({ "311:false" }, early.leds(), "a bind before the first contact is told dark")
			end)

			it("never gets BUTTON_COLORS, whatever Speed LED Colors says: the keypad's own colours (BC27)", function()
				local r = rig({ shown = { fan_on = true, speed = 3, wind = true } })
				r.blows = true
				r.lk:set_colors("per_speed", COLORS, "101010")
				r.lk:shown(r.model:shown())
				r.lk:refresh()
				r.recv(BREEZE, "REQUEST_BUTTON_COLORS")
				r.lk:binding_changed(BREEZE, true, 456, 7)
				r.blows = false
				r.lk:shown({ fan_on = true, speed = 3 })
				local commands = {}
				for _, s in ipairs(r.sent) do
					if s.link == BREEZE then
						commands[#commands + 1] = s.command .. " " .. tostring(s.params.STATE)
						assert.equal("COMMAND", s.kind)
					end
				end
				assert.same({
					"MATCH_LED_STATE true", "MATCH_LED_STATE true", "MATCH_LED_STATE true", "MATCH_LED_STATE true",
					"MATCH_LED_STATE false",
				}, commands)
				assert.is_true(contains(r.trace(), "303 BUTTON_COLORS"), "the speed link still gets its colour")
			end)

			it("SET_BUTTON_COLOR on 311 is ignored", function()
				local r = rig({ shown = { fan_on = true, speed = 3 } })
				r.recv(BREEZE, "SET_BUTTON_COLOR", { BUTTON_ID = "0", ON_COLOR = "ff0000" })
				assert.same({}, r.sent)
			end)

			it("stays dark without breeze_blows (a fan device built without fan/breeze.lua)", function()
				local r = rig({ no_breeze = true })
				r.lk:shown({ fan_on = true, speed = 3, wind = true })
				assert.same({ "311:false" }, breeze_leds(r))
				r.clear()
				r.lk:shown({ fan_on = false, wind = true })
				assert.same({}, breeze_leds(r), "dark already: nothing more")
				r.recv(BREEZE, "REQUEST_BUTTON_COLORS")
				assert.same({ "311:false" }, breeze_leds(r))
			end)

			it("lights only for true: anything else breeze_blows answers is dark", function()
				for _, odd in ipairs({ 1, "1", "true", {}, false }) do
					local r = rig()
					r.blows = odd
					r.lk:shown({ fan_on = true, speed = 3 })
					assert.same({ "311:false" }, breeze_leds(r), tostring(odd))
				end
			end)

			it("a breeze_blows that raises is warned about: nothing sent on a change, dark on a request", function()
				local r = rig()
				local sent = {}
				local lk = links.new({
					model = fake_model({ fan_on = true, speed = 3 }), fan = r.fan, on = function(binding, command, handler)
						r.handlers[binding .. ":" .. command] = handler
					end,
					send = function(link, _, params) sent[#sent + 1] = link .. ":" .. tostring(params.STATE) end,
					now = function() return 0 end, log = log,
					breeze_blows = function() error("not ready") end,
				})
				local lines = capture_log()
				assert.has_no.errors(function() lk:shown({ fan_on = true, speed = 3 }) end)
				assert.is_true(contains(lines, "[WARN] link 311: whether Breeze blows could not be read: "))
				assert.is_false(contains(sent, "311:"), "nothing for 311 while it cannot be read")
				assert.equal(9, #sent, "the other nine links went")
				r.recv(BREEZE, "REQUEST_BUTTON_COLORS")
				assert.equal("311:false", sent[#sent])
			end)

			it("debug() lists what 311 was last sent", function()
				local r = rig()
				r.blows = true
				r.lk:shown({ fan_on = true, speed = 3, wind = true })
				assert.is_true(r.lk:debug().leds[BREEZE])
			end)
		end)

		describe("Keypad Links (BC27)", function()
			it("a bind lists the keypad as Fan Breeze, counted out of 13 links, after the fan's other links", function()
				local r = rig({ names = { [456] = "Example Keypad", [457] = "Second Keypad" } })
				r.lk:late_init()
				r.lk:binding_changed(BREEZE, true, 456, 7)
				assert.same({ "1 of 13 links bound", "Fan Breeze: Example Keypad (456)" }, r.listed[#r.listed])
				r.lk:binding_changed(308, true, 457, 1)
				r.lk:binding_changed(200, true, 457, 2)
				assert.same({
					"3 of 13 links bound",
					"Light Top: Second Keypad (457)",
					"Fan Cycle: Second Keypad (457)",
					"Fan Breeze: Example Keypad (456)",
				}, r.listed[#r.listed])
				assert.equal(3, r.lk:debug().bound)
				for _, total in ipairs(r.texts.totals) do
					assert.equal(13, total, "links hands texts the number of links it keeps")
				end
			end)

			it("late init reads 311 and lists what Director's table says is bound there", function()
				local r = rig({ names = { [456] = "Example Keypad" }, project = { [BREEZE] = { [456] = "x" } } })
				r.lk:late_init()
				assert.equal(BREEZE, r.reads[#r.reads], "311 is read last, in link order")
				assert.same({ "1 of 13 links bound", "Fan Breeze: Example Keypad (456)" }, r.listed[1])
			end)

			it("#92 two buttons of one keypad on 311: unbinding one keeps the keypad, unbinding both removes it", function()
				local r = rig({ names = { [456] = "Example Keypad" } })
				r.lk:late_init()
				r.lk:binding_changed(BREEZE, true, 456, 3)
				r.project[BREEZE] = { [456] = "x" }
				r.lk:binding_changed(BREEZE, true, 456, 4)
				assert.same({ "1 of 13 links bound", "Fan Breeze: Example Keypad (456)" }, r.listed[#r.listed])
				r.lk:binding_changed(BREEZE, false, 456, 4)
				assert.same({ "1 of 13 links bound", "Fan Breeze: Example Keypad (456)" }, r.listed[#r.listed])
				r.project[BREEZE] = nil
				r.lk:binding_changed(BREEZE, false, 456, 3)
				assert.same({ "0 of 13 links bound" }, r.listed[#r.listed])
			end)

			it("#92 an unbind on 311 of a keypad known only from Director's table: kept, read again 3 s later", function()
				local r = rig({
					names = { [456] = "Example Keypad", [457] = "Second Keypad" },
					project = { [BREEZE] = { [456] = "x", [457] = "x" } },
				})
				r.lk:late_init()
				local timers = r.pending_timers()
				r.lk:binding_changed(BREEZE, false, 456, 3)
				assert.equal(3, #r.listed[#r.listed], "another button of that keypad may still be bound")
				assert.equal(timers + 1, r.pending_timers())
				r.project[BREEZE] = { [457] = "x" }
				r.advance(links.REREAD_MS)
				assert.same({ "1 of 13 links bound", "Fan Breeze: Second Keypad (457)" }, r.listed[#r.listed])
			end)
		end)
	end)

	-- Breeze on the keypad LEDs (#137, breeze-leds-design BL-D2, BL-D14 to
	-- BL-D16 and section 3.2): fan/breezeleds.lua holds the bound speed links,
	-- paints them through paint and gives them back through settle; the links
	-- send a held link nothing of their own.
	describe("Breeze on the keypad LEDs (#137, breeze-leds-design section 3.2)", function()
		local function fan_mode_3()
			return { fan_on = true, speed = 3, wind = false }
		end
		local function blowing()
			return { fan_on = true, speed = 3, wind = true, wind_speed = 2 }
		end

		-- The sends since the last clear to one link.
		local function sent_to(r, link)
			local out = {}
			for _, s in ipairs(r.sent) do
				if s.link == link then
					out[#out + 1] = s
				end
			end
			return out
		end

		describe("paint (BL-D14)", function()
			it("with state: BUTTON_COLORS as a NOTIFY, then MATCH_LED_STATE true as a COMMAND", function()
				local r = rig({ shown = blowing() })
				r.lk:set_colors("per_speed", COLORS, "101010")
				r.clear()
				r.lk:paint(302, "0080FF", true)
				assert.same({ "302 BUTTON_COLORS", "302 MATCH_LED_STATE" }, r.trace())
				assert.equal("NOTIFY", r.sent[1].kind)
				assert.same({ ON_COLOR = "0080ff", OFF_COLOR = "101010", CURRENT_COLOR = "0080ff" }, r.sent[1].params,
					"on and current the frame colour in lower case, off Speed LED Off Color")
				assert.equal("COMMAND", r.sent[2].kind)
				assert.same({ STATE = true }, r.sent[2].params)
			end)

			it("without state: BUTTON_COLORS alone", function()
				local r = rig({ shown = blowing() })
				r.lk:paint(305, "ffffff", false)
				r.lk:paint(306, "00ffff")
				assert.same({ "305 BUTTON_COLORS", "306 BUTTON_COLORS" }, r.trace())
				assert.equal("000000", r.sent[1].params.OFF_COLOR, "black until Speed LED Off Color is set")
			end)

			it("leaves nothing counted as sent for the link: its next state goes out whole", function()
				local r = rig({ shown = fan_mode_3() })
				r.lk:set_colors("per_speed", COLORS, "000000")
				r.lk:shown(r.model:shown())
				assert.is_true(r.lk:debug().leds[303])
				r.lk:paint(303, "00ffff", true)
				r.lk:paint(304, "0080ff", true)
				assert.is_nil(r.lk:debug().leds[303])
				assert.is_nil(r.lk:debug().leds[304])
				r.clear()
				r.lk:shown(r.model:shown())
				assert.same({ "303 BUTTON_COLORS", "303 MATCH_LED_STATE", "304 MATCH_LED_STATE" }, r.trace(),
					"the same shown state sends both again: 303 in its own colour, 304 dark")
				assert.equal("ffff00", r.sent[1].params.ON_COLOR)
			end)

			it("refuses anything but the speed links 301 to 306, with a warning, and sends nothing", function()
				local r = rig({ shown = blowing() })
				local lines = capture_log()
				for _, link in ipairs({ 300, 307, 308, BREEZE, 200, 201, 202, 309, 0, 302.5, "abc" }) do
					r.lk:paint(link, "ffffff", true)
				end
				r.lk:paint(nil, "ffffff", true)
				assert.same({}, r.sent)
				assert.is_true(contains(lines, "[WARN] paint on link 300 refused"))
				assert.is_true(contains(lines, "[WARN] paint on link 311 refused"))
				assert.is_true(contains(lines, "[WARN] paint on link nil refused"))
			end)

			it("refuses a colour that is not 6-digit hex, with a warning, and sends nothing", function()
				local r = rig({ shown = blowing() })
				local lines = capture_log()
				for _, colour in ipairs({ "fff", "#0080ff", "0080ff0", "12345g", "", 33023 }) do
					r.lk:paint(302, colour, true)
				end
				r.lk:paint(302, nil, true)
				assert.same({}, r.sent)
				assert.is_true(contains(lines, "[WARN] paint on link 302 refused: #0080ff is not a 6-digit hex colour"))
				assert.is_true(contains(lines, "[WARN] paint on link 302 refused: nil is not a 6-digit hex colour"))
			end)
		end)

		describe("settle (BL-D8, BL-D11)", function()
			it("sends the real state, colours first under Per speed, whatever was sent before", function()
				local r = rig({ shown = fan_mode_3() })
				r.lk:set_colors("per_speed", COLORS, "101010")
				r.lk:shown(r.model:shown())
				r.lk:paint(303, "ffffff", true)
				r.clear()
				r.lk:settle(303)
				assert.same({ "303 BUTTON_COLORS", "303 MATCH_LED_STATE" }, r.trace())
				assert.same({ ON_COLOR = "ffff00", OFF_COLOR = "101010", CURRENT_COLOR = "ffff00" }, r.sent[1].params)
				assert.same({ STATE = true }, r.sent[2].params)
				assert.is_true(r.lk:debug().leds[303])
				r.clear()
				r.lk:settle(302)
				assert.same({ "302 BUTTON_COLORS", "302 MATCH_LED_STATE" }, r.trace(),
					"a dark link too, though it was sent dark already")
				assert.same({ STATE = false }, r.sent[2].params)
				r.clear()
				r.lk:settle(303)
				assert.same({ "303 BUTTON_COLORS", "303 MATCH_LED_STATE" }, r.trace(), "again, though nothing changed")
			end)

			it("Per speed, dark: its own speed's colour, then STATE false", function()
				local r = rig({ shown = fan_mode_3() })
				r.lk:set_colors("per_speed", COLORS, "101010")
				r.lk:shown(r.model:shown())
				r.lk:paint(305, "0080ff", true)
				r.clear()
				r.lk:settle(305)
				assert.same({ "305 BUTTON_COLORS", "305 MATCH_LED_STATE" }, r.trace())
				assert.equal("NOTIFY", r.sent[1].kind)
				assert.same({ ON_COLOR = "00ffff", OFF_COLOR = "101010", CURRENT_COLOR = "00ffff" }, r.sent[1].params,
					"speed 5's colour as its on colour: no frame colour left behind")
				assert.equal("COMMAND", r.sent[2].kind)
				assert.same({ STATE = false }, r.sent[2].params)
				assert.is_false(r.lk:debug().leds[305])
				r.clear()
				r.lk:shown(r.model:shown())
				assert.same({}, r.sent, "counted as sent: the same state sends nothing")
				r.model.shown_state = { fan_on = true, speed = 5, wind = false }
				r.lk:shown(r.model:shown())
				assert.same({ "303 MATCH_LED_STATE", "305 BUTTON_COLORS", "305 MATCH_LED_STATE" }, r.trace(),
					"lit later as push_led lights it")
			end)

			it("Per speed, lit: the colour of the speed it is lit at, then STATE true", function()
				local r = rig({ shown = { fan_on = true, speed = 4, wind = false } })
				r.lk:set_colors("per_speed", COLORS, "000000")
				r.lk:shown(r.model:shown())
				r.lk:paint(304, "ffffff", true)
				r.clear()
				r.lk:settle(304)
				assert.same({ "304 BUTTON_COLORS", "304 MATCH_LED_STATE" }, r.trace())
				assert.same({ ON_COLOR = "00ff00", OFF_COLOR = "000000", CURRENT_COLOR = "00ff00" }, r.sent[1].params)
				assert.same({ STATE = true }, r.sent[2].params)
				r.clear()
				r.lk:shown(r.model:shown())
				assert.same({}, r.sent, "state and colour counted as sent")
			end)

			it("Per speed, dark, no colour set for its own speed: STATE alone", function()
				local r = rig({ shown = fan_mode_3() })
				r.lk:set_colors("per_speed", { "ff0000", nil, "ffff00" }, "000000")
				r.lk:paint(302, "00ffff", true)
				r.clear()
				r.lk:settle(302)
				assert.same({ "302 MATCH_LED_STATE" }, r.trace())
				assert.same({ STATE = false }, r.sent[1].params)
			end)

			it("the keypad's own colours: STATE alone, lit or dark", function()
				local r = rig({ shown = fan_mode_3() })
				r.lk:set_colors("keypad", COLORS, "101010")
				r.lk:paint(303, "ffffff", true)
				r.lk:paint(304, "ffffff", true)
				r.clear()
				r.lk:settle(303)
				r.lk:settle(304)
				assert.same({ "303 MATCH_LED_STATE", "304 MATCH_LED_STATE" }, r.trace())
				assert.same({ "303:true", "304:false" }, r.leds())
			end)

			it("follows the mode at the call: settled under Per speed, then switched to the keypad's own", function()
				local r = rig({ shown = fan_mode_3() })
				r.lk:set_colors("per_speed", COLORS, "000000")
				r.lk:paint(306, "0080ff", true)
				r.clear()
				r.lk:settle(306)
				r.lk:set_colors("keypad", COLORS, "000000")
				assert.same({ "306 BUTTON_COLORS", "306 MATCH_LED_STATE" }, r.trace(), "the switch itself sends nothing")
				assert.equal("0000ff", r.sent[1].params.ON_COLOR)
			end)

			it("works while held still says the link is held, and does not ask held", function()
				local r = rig({ leds = true, shown = fan_mode_3() })
				r.lk:set_colors("per_speed", COLORS, "000000")
				r.held[303] = true
				r.lk:paint(303, "0080ff", true)
				r.clear()
				r.held_asked = {}
				r.lk:settle(303)
				assert.same({ "303 BUTTON_COLORS", "303 MATCH_LED_STATE" }, r.trace())
				assert.equal("ffff00", r.sent[1].params.ON_COLOR)
				assert.same({}, r.held_asked)
			end)

			it("uses the colours and the Also Lit At row set while the link was held", function()
				local r = rig({ leds = true, shown = blowing() })
				r.held[302] = true
				r.lk:shown(r.model:shown())
				r.lk:set_colors("per_speed", COLORS, "101010")
				r.lk:set_also(2, 1)
				r.model.shown_state = { fan_on = true, speed = 1, wind = false }
				r.lk:shown(r.model:shown())
				assert.same({}, sent_to(r, 302), "held all along: nothing of its own")
				r.clear()
				r.lk:settle(302)
				assert.same({ "302 BUTTON_COLORS", "302 MATCH_LED_STATE" }, r.trace())
				assert.same({ ON_COLOR = "ff0000", OFF_COLOR = "101010", CURRENT_COLOR = "ff0000" }, r.sent[1].params,
					"lit at speed 1 by Also Lit At, in speed 1's colour")
			end)

			it("sends nothing while the state is unknown, and refuses anything but 301 to 306", function()
				local r = rig({ shown = {} })
				local lines = capture_log()
				r.lk:settle(303)
				assert.same({}, r.sent)
				r.model.shown_state = fan_mode_3()
				r.lk:settle(300)
				r.lk:settle(BREEZE)
				r.lk:settle(200)
				assert.same({}, r.sent)
				assert.is_true(contains(lines, "[WARN] settle on link 300 refused"))
				assert.is_true(contains(lines, "[WARN] settle on link 311 refused"))
			end)
		end)

		describe("pixels_list (BL-D2)", function()
			it("the speed links with a known keypad, ascending; never Off, Toggle, Cycle, Breeze or the light", function()
				local r = rig({
					names = { [456] = "Example Keypad" },
					project = {
						[305] = { [456] = "x" }, [302] = { [456] = "x", [457] = "x" }, [304] = { [457] = "x" },
						[300] = { [456] = "x" }, [307] = { [456] = "x" }, [308] = { [456] = "x" },
						[BREEZE] = { [456] = "x" }, [200] = { [456] = "x" }, [301] = {},
					},
				})
				assert.same({}, r.lk:pixels_list(), "nothing read yet")
				r.lk:late_init()
				assert.same({ 302, 304, 305 }, r.lk:pixels_list())
			end)

			it("a keypad known only from Director's table, or by a bind naming no button, counts", function()
				local r = rig({ names = { [456] = "Example Keypad" }, project = { [303] = { [456] = "x" } } })
				r.lk:late_init()
				r.lk:binding_changed(306, true, 457, nil)
				assert.same({ 303, 306 }, r.lk:pixels_list())
				assert.same({ "2 of 13 links bound", "Fan Speed 3: Example Keypad (456)", "Fan Speed 6: device 457" },
					r.listed[#r.listed], "the links the Keypad Links property lists")
			end)

			it("#92 an unbind that leaves a keypad known only from the table keeps the pixel until the reread", function()
				local r = rig({ names = { [456] = "Example Keypad" }, project = { [303] = { [456] = "x" } } })
				r.lk:late_init()
				r.lk:binding_changed(303, false, 456, 3)
				assert.same({ 303 }, r.lk:pixels_list(), "another button of that keypad may still be bound")
				assert.same({ "1 of 13 links bound", "Fan Speed 3: Example Keypad (456)" }, r.listed[#r.listed])
				r.project[303] = {}
				r.advance(links.REREAD_MS)
				assert.same({}, r.lk:pixels_list())
				assert.same({ "0 of 13 links bound" }, r.listed[#r.listed])
			end)

			it("an unbound link, a link that answered nil twice and a link that lost its last button are none", function()
				local r = rig({ names = { [456] = "Example Keypad" }, project = { [302] = {} } })
				r.lk:late_init()
				assert.same({}, r.lk:pixels_list(), "302 answered an empty table, the rest nil")
				r.advance(links.SECOND_LOOK_MS)
				assert.same({}, r.lk:pixels_list())
				r.lk:binding_changed(304, true, 456, 4)
				assert.same({ 304 }, r.lk:pixels_list())
				r.lk:binding_changed(304, false, 456, 4)
				assert.same({}, r.lk:pixels_list())
			end)
		end)

		describe("the pixels callback (section 3.2)", function()
			it("late init hands the list once, even an empty one; a second look that finds nothing hands none", function()
				local r = rig({ leds = true })
				r.lk:late_init()
				assert.same({ {} }, r.pixel_lists)
				r.advance(links.SECOND_LOOK_MS)
				assert.same({ {} }, r.pixel_lists)
			end)

			it("late init hands the list though it did not change since the last one", function()
				local r = rig({ leds = true, names = { [456] = "Example Keypad" } })
				r.lk:binding_changed(303, true, 456, 3)
				assert.same({ { 303 } }, r.pixel_lists, "a bind before late init")
				r.project[303] = { [456] = "x" }
				r.lk:late_init()
				assert.same({ { 303 }, { 303 } }, r.pixel_lists)
			end)

			it("a bind and an unbind on a speed link hand the new list; the unbind sends the link nothing", function()
				local r = rig({ leds = true, shown = blowing(), names = { [456] = "Example Keypad" } })
				r.lk:late_init()
				r.lk:binding_changed(305, true, 456, 5)
				r.project[305] = { [456] = "x" }
				r.lk:binding_changed(302, true, 456, 2)
				r.project[302] = { [456] = "x" }
				assert.same({ {}, { 305 }, { 302, 305 } }, r.pixel_lists)
				r.clear()
				r.project[305] = nil
				r.lk:binding_changed(305, false, 456, 5)
				assert.same({ 302 }, r.pixel_lists[#r.pixel_lists])
				assert.same({}, r.sent)
			end)

			it("a speed link that gains a button mid-animation is a pixel before its answer, which repaint gives", function()
				local r
				r = rig({
					leds = true, shown = blowing(), names = { [456] = "Example Keypad" },
					pixels = function(list)
						r.pixel_lists[#r.pixel_lists + 1] = list
						for _, link in ipairs(list) do
							r.held[link] = true -- what breezeleds:set_pixels does while it animates
						end
					end,
				})
				r.lk:late_init()
				r.clear()
				r.lk:binding_changed(304, true, 456, 4)
				assert.same({ 304 }, r.pixel_lists[#r.pixel_lists])
				assert.same({ 304 }, r.repaints, "answered by the animation")
				assert.same({}, r.sent, "not with the real state")
			end)

			it("is not called again when the list did not change", function()
				local r = rig({ leds = true, names = { [456] = "Example Keypad", [457] = "Second Keypad" } })
				r.lk:late_init()
				r.lk:binding_changed(303, true, 456, 3)
				local calls = #r.pixel_lists
				r.project[303] = { [456] = "x" }
				r.lk:binding_changed(303, true, 457, 3)
				r.lk:binding_changed(303, true, 456, 3)
				r.lk:binding_changed(300, true, 456, 1)
				r.lk:binding_changed(307, true, 456, 7)
				r.lk:binding_changed(BREEZE, true, 456, 8)
				r.lk:binding_changed(201, true, 456, 2)
				assert.equal(calls, #r.pixel_lists, "a second keypad, the same bind, links that are no pixels")
				assert.same({ 303 }, r.pixel_lists[#r.pixel_lists])
			end)

			it("the second look and the reread hand the list when it changed", function()
				local second = false
				local r = rig({
					leds = true, names = { [456] = "Example Keypad" },
					project = {
						[303] = { [456] = "x" },
						[305] = function() return second and { [456] = "x" } or nil end,
					},
				})
				r.lk:late_init()
				assert.same({ { 303 } }, r.pixel_lists)
				second = true
				r.advance(links.SECOND_LOOK_MS)
				assert.same({ { 303 }, { 303, 305 } }, r.pixel_lists, "the second look found 305")
				r.lk:binding_changed(303, false, 456, 3)
				assert.equal(2, #r.pixel_lists, "kept until the reread")
				r.project[303] = {}
				r.advance(links.REREAD_MS)
				assert.equal(3, #r.pixel_lists)
				assert.same({ 305 }, r.pixel_lists[3], "the reread dropped 303")
			end)
		end)

		describe("held links (BL-D15)", function()
			it("shown sends a held speed link nothing; the rest follow the state as before", function()
				local r = rig({ leds = true })
				for link = 302, 305 do
					r.held[link] = true
				end
				r.lk:shown(fan_mode_3())
				assert.same({ "300:false", "301:false", "306:false", "307:true", "308:true", "311:false" }, r.leds())
				assert.same({ 301, 302, 303, 304, 305, 306 }, r.held_asked, "held is asked about the speed links alone")
			end)

			it("refresh sends a held speed link nothing", function()
				local r = rig({ leds = true, shown = fan_mode_3() })
				r.held[303], r.held[306] = true, true
				r.lk:refresh()
				assert.same({
					"300:false", "301:false", "302:false", "304:false", "305:false", "307:true", "308:true", "311:false",
				}, r.leds())
			end)

			it("set_colors keeps its tables while a lit link is held, and sends it nothing", function()
				local r = rig({ leds = true, shown = fan_mode_3() })
				r.lk:shown(r.model:shown())
				r.held[303] = true
				r.clear()
				r.lk:set_colors("per_speed", COLORS, "101010")
				assert.same({}, r.sent)
				assert.equal("per_speed", r.lk.mode)
				assert.equal("ffff00", r.lk.colors[3])
				assert.equal("101010", r.lk.off_color)
				r.lk:paint(303, "0080ff", true)
				assert.equal("101010", r.sent[1].params.OFF_COLOR, "a paint takes the new off colour")
				r.held[303] = nil
				r.clear()
				r.lk:set_colors("per_speed", COLORS, "101010")
				assert.same({ "303 BUTTON_COLORS", "303 MATCH_LED_STATE" }, r.trace(), "released: it follows again")
			end)

			it("set_also keeps the row while the link is held, and sends it nothing", function()
				local r = rig({ leds = true, shown = fan_mode_3() })
				r.lk:shown(r.model:shown())
				r.held[302] = true
				r.clear()
				r.lk:set_also(2, 3)
				assert.same({}, r.sent)
				assert.equal(3, r.lk.also[2])
				r.lk:settle(302)
				assert.same({ "302:true" }, r.leds(), "the settle shows the row: lit at speed 3")
			end)

			it("REQUEST_BUTTON_COLORS and a bind on a held link call repaint instead of sending the real state", function()
				local r = rig({ leds = true, shown = blowing(), names = { [456] = "Example Keypad" } })
				r.lk:late_init()
				r.held[303] = true
				r.clear()
				r.recv(303, "REQUEST_BUTTON_COLORS")
				r.lk:binding_changed(303, true, 456, 3)
				assert.same({ 303, 303 }, r.repaints)
				assert.same({}, r.sent)
				r.recv(304, "REQUEST_BUTTON_COLORS")
				assert.same({ "304:false" }, r.leds(), "a link not held is answered as before")
				assert.same({ 303, 303 }, r.repaints)
			end)

			it("300, 307, 308 and 311 are never held: held is not asked about them and they follow the state", function()
				local r = rig({ leds = true, shown = blowing(), names = { [456] = "Example Keypad" } })
				r.hold_all = true
				r.blows = true
				r.lk:shown(r.model:shown())
				assert.same({ "300:false", "307:false", "308:false", "311:true" }, r.leds())
				r.clear()
				r.lk:refresh()
				for _, link in ipairs({ 300, 307, 308, BREEZE }) do
					r.recv(link, "REQUEST_BUTTON_COLORS")
				end
				r.lk:binding_changed(308, true, 456, 1)
				r.lk:binding_changed(200, true, 456, 2)
				assert.same({
					"300:false", "307:false", "308:false", "311:true", "300:false", "307:false", "308:false", "311:true",
					"308:false",
				}, r.leds())
				assert.same({}, r.repaints)
				assert.equal(12, #r.held_asked, "the six speed links on the shown state and on the refresh")
				for _, link in ipairs(r.held_asked) do
					assert.is_true(link >= 301 and link <= 306, "held asked about " .. tostring(link))
				end
			end)
		end)

		describe("absent and failing callbacks (logged, never raised)", function()
			it("absent, or no functions: nothing held, nothing repainted, no list", function()
				local sent = {}
				local lk = links.new({
					model = fake_model(fan_mode_3()), fan = fake_fan(), on = function() end,
					now = function() return 0 end, log = log, held = true, repaint = "x", pixels = {},
					send = function(link, command) sent[#sent + 1] = link .. " " .. command end,
				})
				assert.has_no.errors(function()
					lk:late_init()
					lk:shown(fan_mode_3())
					lk:answer(303)
				end)
				assert.equal(11, #sent, "ten on the shown state, one answer")
			end)

			it("a held link with no repaint wired is sent nothing on a request", function()
				local sent = {}
				local lk = links.new({
					model = fake_model(blowing()), fan = fake_fan(), on = function() end,
					now = function() return 0 end, log = log, held = function(link) return link == 303 end,
					send = function(link, command) sent[#sent + 1] = link .. " " .. command end,
				})
				lk:answer(303)
				lk:answer(304)
				assert.same({ "304 MATCH_LED_STATE" }, sent)
			end)

			it("a held that raises is warned about, and the link is treated as not held", function()
				local r = rig({ leds = true, held = function() error("animation broke") end })
				local lines = capture_log()
				assert.has_no.errors(function() r.lk:shown(fan_mode_3()) end)
				assert.equal(10, #r.leds(), "every link follows the state")
				assert.is_true(contains(lines, "[WARN] link 301: whether the Breeze animation holds it could not be read"))
				assert.is_false(contains(lines, "link 300: whether"), "never asked about 300")
			end)

			it("a repaint that raises is logged as an error: nothing sent, nothing raised", function()
				local r = rig({ leds = true, shown = blowing(), repaint = function() error("no frame") end })
				r.held[302] = true
				local lines = capture_log()
				assert.has_no.errors(function()
					r.recv(302, "REQUEST_BUTTON_COLORS")
					r.lk:binding_changed(302, true, 456, 2)
				end)
				assert.same({}, r.sent)
				assert.is_true(contains(lines, "[ERROR] link 302: the Breeze animation could not repaint it"))
			end)

			it("a pixels that raises is logged as an error and offered again at the next change", function()
				local fail, offered = true, {}
				local r = rig({
					leds = true, names = { [456] = "Example Keypad" },
					pixels = function(list)
						offered[#offered + 1] = list
						if fail then
							error("not ready")
						end
					end,
				})
				local lines = capture_log()
				assert.has_no.errors(function() r.lk:late_init() end)
				assert.is_true(contains(lines, "[ERROR] the Breeze animation could not take the pixels"))
				fail = false
				r.lk:binding_changed(200, true, 456, 1)
				assert.same({ {}, {} }, offered, "the same list, offered again: the first was not taken")
				r.lk:binding_changed(201, true, 456, 2)
				assert.equal(2, #offered, "taken: not offered again")
			end)
		end)
	end)
end)
