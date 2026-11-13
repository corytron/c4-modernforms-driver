-- fan.light on fakes (docs/v1-design.md sections 4.7, 9.9 and 10.2): the light
-- on the light_v2 proxy. Nothing here is the real model or the real
-- common/device.lua, both of which other specs pin; the fakes below are made
-- by hand from the interfaces of section 9.5 and 9.9:
--
--   * a clock whose timers fire in due order under clock.advance(ms), and
--     whose now() is the same time;
--   * a model that keeps the light group as section 4.3 and 4.5 describe it:
--     the wanted fields replace each other, one request is in flight, "on at
--     N" from off is the level and then lightOn (V14), and a group that stops
--     being busy is reported with settled() (only on a difference from what it
--     told) and idle();
--   * a keypad that is device.lua's press machine as far as the light depends
--     on it (the 400 ms hold, dim_after_on's 600 ms, on_end_hold before
--     on_finish, h.timer cancelled when a press ends).

local light = require("fan.light")
local fake = require("helpers.fake_c4")
local real_log = require("common.log")
local mf = require("fixtures.mf_gen3")

-- Fakes ----------------------------------------------------------------------

local function new_clock()
	local clock = { t = 0, timers = {}, count = 0 }

	function clock.now()
		return clock.t
	end

	function clock.timer(ms, callback)
		clock.count = clock.count + 1
		local timer = { id = clock.count, due = clock.t + ms, callback = callback }
		function timer:Cancel()
			self.cancelled = true
		end
		clock.timers[#clock.timers + 1] = timer
		return timer
	end

	-- The delays still to run of the timers that are armed, shortest first.
	function clock.armed()
		local out = {}
		for _, timer in ipairs(clock.timers) do
			if not timer.cancelled and not timer.fired then
				out[#out + 1] = timer.due - clock.t
			end
		end
		table.sort(out)
		return out
	end

	-- Runs every timer that falls due within `ms`, in due order, including the
	-- ones armed on the way.
	function clock.advance(ms)
		local goal = clock.t + ms
		while true do
			local nxt
			for _, timer in ipairs(clock.timers) do
				if not timer.cancelled and not timer.fired and timer.due <= goal
					and (nxt == nil or timer.due < nxt.due or (timer.due == nxt.due and timer.id < nxt.id)) then
					nxt = timer
				end
			end
			if nxt == nil then
				break
			end
			clock.t = nxt.due
			nxt.fired = true
			nxt.callback()
		end
		clock.t = goal
	end

	return clock
end

local function new_log()
	local log = { lines = {} }
	local function sink(level)
		return function(fmt, ...)
			local ok, text = pcall(string.format, fmt, ...)
			log.lines[#log.lines + 1] = level .. ": " .. (ok and text or tostring(fmt))
		end
	end
	log.debug, log.info, log.warn, log.error = sink("debug"), sink("info"), sink("warn"), sink("error")
	-- The lines of one level, without the level.
	function log.of(level)
		local out = {}
		for _, line in ipairs(log.lines) do
			if line:sub(1, #level + 2) == level .. ": " then
				out[#out + 1] = line:sub(#level + 3)
			end
		end
		return out
	end
	return log
end

local function copy(st)
	return st and { light_on = st.light_on, level = st.level } or nil
end

-- The light group of fan/model.lua as sections 4.3 to 4.5 give it, with the #141
-- additions of docs/light-fades-design.md section 4.3 (want's opts, withdraw). The
-- spec drives the answers (model:answer()), or gives them a delay (answer_after), and
-- the model reports through env.lt as the real one does.
local function new_model(env)
	local m = {
		confirmed_state = nil, -- { light_on, level } once known
		wanted = nil,          -- the latest want, until its target is done
		sent_for = nil,        -- the wanted a request was sent for
		sent_completes = false, -- that request finishes the wanted (no second request follows)
		inflight = nil,        -- the request body on the wire
		leveled = false,       -- the level of this turn-on was answered
		waiting = false,       -- inside the gap after an answer
		requests = {},         -- every body sent, in order
		wants = {},            -- every want() it was given
		want_opts = {},        -- the opts of each, parallel to wants (false for none)
		withdrawals = 0,       -- withdraw() calls that took something back
		in_flight = 0,
		max_in_flight = 0,
		told = nil,            -- the level its settled() last reported
		refuse = nil,          -- a why: want() refuses with it
		idle_first = false,    -- idle() before settled()
		answer_after = nil,    -- ms: answers by itself; else the spec calls model:answer()
		gap = 0,               -- ms between an answer and the next request
		busy_override = nil,
		last_shown = nil,
	}

	-- Wanted over confirmed; the request in flight belongs to the wanted.
	local function shown_state()
		local c = m.confirmed_state
		local s = { light_on = c and c.light_on, level = c and c.level }
		if m.wanted then
			s.light_on = m.wanted.light_on
			if m.wanted.level then
				s.level = m.wanted.level
			end
		end
		return s
	end

	local function notify_shown()
		local s = shown_state()
		local before = m.last_shown
		if before == nil or before.light_on ~= s.light_on or before.level ~= s.level then
			m.last_shown = s
			env.lt:shown(copy(s))
		end
	end

	local function next_body()
		local w, c = m.wanted, m.confirmed_state or {}
		if w.light_on == false then
			if c.light_on ~= false then
				return '{"lightOn":false}'
			end
			if w.level and w.level ~= c.level then
				return string.format('{"lightBrightness":%d}', w.level) -- the dark write (LF-D10)
			end
			return '{"lightOn":false}'
		end
		if c.light_on == true then
			return string.format('{"lightBrightness":%d}', w.level)
		end
		if not m.leveled and w.level ~= c.level then
			return string.format('{"lightBrightness":%d}', w.level)
		end
		return '{"lightOn":true}'
	end

	-- The state after an answer to `body`, and whether it finishes the wanted fields.
	local function apply(c, body)
		local out = { light_on = c.light_on, level = c.level }
		local level = body:match('"lightBrightness":(%d+)')
		if level then
			out.level = tonumber(level)
		elseif body == '{"lightOn":true}' then
			out.light_on = true
		else
			out.light_on = false
		end
		return out
	end

	local function finished(w, c)
		if w.light_on == false then
			return c.light_on == false and (w.level == nil or c.level == w.level)
		end
		return c.light_on == true and c.level == w.level
	end

	local function pump()
		if m.inflight or m.waiting or not m.wanted then
			return
		end
		m.inflight, m.sent_for = next_body(), m.wanted
		m.sent_completes = finished(m.wanted, apply(m.confirmed_state or { light_on = false, level = 100 }, m.inflight))
		m.requests[#m.requests + 1] = m.inflight
		m.in_flight = m.in_flight + 1
		m.max_in_flight = math.max(m.max_in_flight, m.in_flight)
		if m.answer_after then
			local delay = m.answer_after
			if type(delay) == "function" then
				delay = delay(m.inflight)
			end
			env.clock.timer(delay, function() m:answer() end)
		end
	end

	function m.want(_, fields, opts)
		m.wants[#m.wants + 1] = fields
		m.want_opts[#m.want_opts + 1] = opts or false
		if m.refuse then
			return false, m.refuse
		end
		if opts and opts.after_contact then
			m.after_contact = fields -- held until a contact; nothing is sent
			return true
		end
		m.wanted = fields
		notify_shown()
		pump()
		return true
	end

	-- #141 section 4.3: the wanted but unsent fields are taken back; a request in flight
	-- that finishes them leaves nothing unsent.
	-- Its second value is what the request on the wire sends (review fix), as the real model's.
	function m.withdraw(_, group)
		assert.equal("light", group)
		local flying
		if m.inflight == '{"lightOn":false}' then
			flying = { light_on = false }
		elseif m.inflight == '{"lightOn":true}' then
			flying = { light_on = true }
		elseif m.inflight then
			flying = { level = tonumber(m.inflight:match('"lightBrightness":(%d+)')) }
		end
		local w = m.wanted
		if not w or (m.inflight and m.sent_for == w and m.sent_completes) then
			return false, flying
		end
		m.wanted = nil
		m.withdrawals = m.withdrawals + 1
		notify_shown()
		return true, flying
	end

	-- The group has nothing left: settled() only for a difference from what it
	-- told, then idle() (or the other way round).
	local function group_idle()
		local c = m.confirmed_state
		local current = c.light_on and c.level or 0
		local function do_settled()
			if current ~= m.told then
				m.told = current
				env.lt:settled(copy(c), "command")
			end
		end
		local function do_idle()
			env.lt:idle(copy(c))
		end
		if m.idle_first then
			do_idle()
			do_settled()
		else
			do_settled()
			do_idle()
		end
	end

	function m.answer()
		local body = assert(m.inflight, "answer: no request in flight")
		m.inflight = nil
		m.in_flight = m.in_flight - 1
		local c = m.confirmed_state or { light_on = false, level = 100 }
		local was_on = c.light_on
		local after = apply(c, body)
		if body:match('"lightBrightness"') and not was_on then
			m.leveled = true
		elseif body == '{"lightOn":true}' then
			m.leveled = false
		end
		c.light_on, c.level = after.light_on, after.level
		m.confirmed_state = c
		local w = m.wanted
		if w and w == m.sent_for and finished(w, c) then
			m.wanted, m.leveled = nil, false
		end
		notify_shown()
		if m.wanted then
			if m.gap > 0 then
				m.waiting = true
				env.clock.timer(m.gap, function()
					m.waiting = false
					pump()
				end)
			else
				pump()
			end
			return
		end
		group_idle()
	end

	-- The request failed: nothing was done, the shown state falls back.
	function m.fail()
		m.inflight, m.sent_for, m.wanted, m.leveled = nil, nil, nil, false
		m.in_flight = m.in_flight - 1
		notify_shown()
		env.lt:idle(copy(m.confirmed_state))
	end

	function m.shown()
		return shown_state()
	end

	function m.confirmed()
		return copy(m.confirmed_state)
	end

	function m.busy()
		if m.busy_override ~= nil then
			return m.busy_override
		end
		return m.wanted ~= nil or m.inflight ~= nil
	end

	return m
end

-- device.lua's press machine as far as the light depends on it.
local function new_keypad(env)
	local dev, clock = env.dev, env.clock
	local k = { hold = nil }

	local function end_hold()
		if k.hold and k.hold.timer then
			k.hold.timer:Cancel()
		end
		if k.hold then
			dev.on_end_hold(k.hold)
		end
		k.hold = nil
	end

	local function start_hold(h)
		h.held = true
		local on = dev.is_on() == true
		local up = h.button == 0 or (h.button ~= 1 and not on)
		if not up and not on then
			return -- down from off does nothing: the machine never calls the light
		end
		dev.on_hold(h, up, on)
	end

	function dev.holding(h)
		return k.hold == h
	end

	function dev.dim_after_on(h, dim_up)
		h.timer = clock.timer(600, function()
			if k.hold ~= h then
				return
			end
			h.timer = nil
			dim_up()
		end)
	end

	-- With k.stops on, the press of a button while a fade runs stops it and its click
	-- is swallowed, as common/device.lua's tap machine does (LF-D12; its own spec pins
	-- the window).
	function k.press(button)
		end_hold()
		local stopped = false
		if k.stops and dev.ramp_active() then
			dev.on_ramp_stop(button)
			stopped = true
		end
		local h = { button = button, stopped = stopped }
		h.timer = clock.timer(400, function()
			if k.hold == h then
				h.timer = nil
				start_hold(h)
			end
		end)
		k.hold = h
	end

	-- The release of a hold, or of a press that was no hold.
	function k.release()
		local h = k.hold
		end_hold()
		if h and h.held then
			dev.on_finish(h)
		end
	end

	-- A click: the release of a hold, else a tap.
	function k.click(button)
		local h = k.hold
		end_hold()
		if h and h.held then
			dev.on_finish(h)
		elseif not (h and h.stopped) then
			dev.on_click(button)
		end
	end

	-- A tap: the press, and the click 100 ms later.
	function k.tap(button)
		k.press(button)
		clock.advance(100)
		k.click(button)
	end

	return k
end

local function new_env(opts)
	opts = opts or {}
	-- The click rates are 0 here, so a tap is one request unless a spec asks for a fade
	-- (the real default is 3000, LF-D3); no Default Brightness Rate is sent, so 750 is
	-- the one in use (LF-D4).
	local env = { clock = new_clock(), log = new_log(), registered = {}, settings = { preset = 100, hold_up = 5000,
		hold_down = 5000, click_up = 0, click_down = 0 } }
	for key, value in pairs(opts.settings or {}) do
		env.settings[key] = value
	end
	env.dev = { sent = {}, leds = {} }
	function env.dev.notify(command, params)
		env.dev.sent[#env.dev.sent + 1] = { command, params }
	end
	function env.dev.setting(name)
		return env.settings[name]
	end
	function env.dev.update_leds(force)
		env.dev.leds[#env.dev.leds + 1] = { force = force, on = env.dev.is_on() }
	end
	env.model = new_model(env)
	env.lt = light.new({
		model = env.model,
		dev = env.dev,
		on = function(binding, command, handler)
			env.registered[binding .. ":" .. command] = handler
		end,
		now = env.clock.now,
		timer = env.clock.timer,
		log = env.log,
	})
	env.keypad = new_keypad(env)

	-- A command from the light_v2 proxy.
	function env.send(command, params)
		local handler = assert(env.registered[light.BINDING .. ":" .. command], command)
		handler(light.BINDING, params or {})
	end

	-- What the spec looks at is what happens after this.
	function env.clear()
		env.dev.sent, env.dev.leds = {}, {}
		env.model.wants, env.model.requests, env.model.want_opts = {}, {}, {}
	end

	-- The first contact found the light in this state: the model is online and
	-- reported it (R6).
	function env.start(light_on, level)
		env.model.confirmed_state = { light_on = light_on, level = level }
		env.model.told = light_on and level or 0
		env.model.last_shown = { light_on = light_on, level = level }
		env.lt:phase("online", {}, true)
		env.lt:settled({ light_on = light_on, level = level }, "start")
		env.clear()
	end

	return env
end

local function changing(current, goal, rate)
	return { "LIGHT_BRIGHTNESS_CHANGING", { LIGHT_BRIGHTNESS_CURRENT = current, LIGHT_BRIGHTNESS_TARGET = goal,
		RATE = rate } }
end

local function changed(level)
	return { "LIGHT_BRIGHTNESS_CHANGED", { LIGHT_BRIGHTNESS_CURRENT = level } }
end

local function online(state)
	return { "ONLINE_CHANGED", { STATE = state } }
end

-- The levels of the wants, in order.
local function levels(env)
	local out = {}
	for _, fields in ipairs(env.model.wants) do
		out[#out + 1] = fields.light_on and fields.level or 0
	end
	return out
end

local function count(env, command)
	local n = 0
	for _, note in ipairs(env.dev.sent) do
		if note[1] == command then
			n = n + 1
		end
	end
	return n
end

-- Runs fn with fields of the module set (its constants are fields so specs and probes
-- can set them), and puts them back.
local function with(changes, fn)
	local saved = {}
	for key, value in pairs(changes) do
		saved[key] = light[key]
		light[key] = value
	end
	local ok, err = pcall(fn)
	for key, value in pairs(saved) do
		light[key] = value
	end
	assert(ok, err)
end

describe("fan.light", function()
	describe("construction", function()
		it("registers the commands of section 9.9 on binding 5002, and none of device.lua's", function()
			local env = new_env()
			local names = {}
			for key in pairs(env.registered) do
				names[#names + 1] = key
			end
			table.sort(names)
			local expected = {}
			for _, command in ipairs({ "ON", "OFF", "TOGGLE", "SET_LEVEL", "RAMP_TO_LEVEL", "SET_BRIGHTNESS_TARGET",
				"SET_BRIGHTNESS_STOP", "STOP_SCENE_RAMP", "STOP_RAMP_SCENE", "RAMP_SCENE_UP", "RAMP_SCENE_DOWN",
				"SYNCHRONIZE" }) do
				expected[#expected + 1] = "5002:" .. command
			end
			table.sort(expected)
			assert.same(expected, names)
			assert.equal(5002, light.BINDING)
		end)

		it("takes the binding from its options", function()
			local seen = {}
			local env = new_env()
			light.new({ model = env.model, dev = {}, on = function(binding, command) seen[binding .. ":" .. command] = true end,
				now = env.clock.now, timer = env.clock.timer, log = env.log, binding = 6002 })
			assert.is_true(seen["6002:ON"])
		end)

		it("sets the hooks device.lua's machine calls", function()
			local env = new_env()
			for _, hook in ipairs({ "is_on", "on_click", "on_hold", "on_finish", "on_end_hold" }) do
				assert.is_function(env.dev[hook], hook)
			end
		end)

		it("sends nothing before the first contact (R6) and starts with an empty debug view", function()
			local env = new_env()
			assert.same({}, env.dev.sent)
			assert.same({ told_level = nil, changing_open = false, notify_light = 0, ramping = false, fading = false },
				env.lt:debug())
			assert.same({}, env.clock.armed())
		end)

		it("needs its model, dev, on, now and timer", function()
			assert.has_error(function() light.new({}) end)
			assert.has_error(function() light.new() end)
			local env = new_env()
			assert.has_error(function() light.new({ model = env.model, dev = env.dev, on = function() end }) end)
		end)
	end)

	describe("targets (section 4.7)", function()
		local env
		before_each(function()
			env = new_env()
			env.start(true, 40)
		end)

		it("SET_BRIGHTNESS_TARGET with RATE 0: CHANGING at once, one want, CHANGED at idle (9.11)", function()
			env.send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "70", RATE = "0" })
			assert.same({ changing(40, 70, 0) }, env.dev.sent, "the slider's rate of 0: no fade (Q4)")
			assert.same({ { light_on = true, level = 70 } }, env.model.wants)
			assert.same({ '{"lightBrightness":70}' }, env.model.requests)
			assert.is_true(env.lt:debug().changing_open)
			env.model:answer()
			assert.same({ changing(40, 70, 0), changed(70) }, env.dev.sent)
			assert.same({ told_level = 70, changing_open = false, notify_light = 4, ramping = false, fading = false },
				env.lt:debug())
		end)

		it("takes the target from either spelling of the parameter, and from LEVEL", function()
			env.send("SET_BRIGHTNESS_TARGET", { ["LIGHT BRIGHTNESS TARGET"] = "55" })
			env.send("SET_BRIGHTNESS_TARGET", { LEVEL = "65" })
			assert.same({ 55, 65 }, levels(env))
		end)

		it("SET_LEVEL goes to LEVEL at the default rate whatever TIME says; RAMP_TO_LEVEL with TIME 0 too", function()
			env.send("SET_LEVEL", { LEVEL = "35", TIME = "30000" })
			env.send("RAMP_TO_LEVEL", { LEVEL = "80", TIME = "0" })
			assert.same({ 35, 80 }, levels(env))
			assert.same({ changing(40, 35, 0), changing(35, 80, 0) }, env.dev.sent, "from the level shown now")
		end)

		it("OFF is a target of 0: lightOn false, CHANGING toward 0, CHANGED 0", function()
			env.send("OFF")
			assert.same({ changing(40, 0, 0) }, env.dev.sent)
			assert.same({ { light_on = false } }, env.model.wants)
			env.model:answer()
			assert.same({ changing(40, 0, 0), changed(0) }, env.dev.sent)
			assert.same({ '{"lightOn":false}' }, env.model.requests)
		end)

		it("ON is Default On Brightness, whatever the light shows and whatever the setting is", function()
			env.settings.preset = 60
			env.send("ON")
			assert.same({ changing(40, 60, 0) }, env.dev.sent, "on at 40: still the preset")
			env.settings.preset = 25
			env.send("ON")
			assert.same({ 60, 25 }, levels(env))
		end)

		it("takes 100 when the preset setting is no level", function()
			for _, setting in ipairs({ 0, 101, "abc", false }) do
				env.settings.preset = setting
				env.clear()
				env.send("ON")
				assert.same({ 100 }, levels(env), tostring(setting))
			end
			env.settings.preset = nil
			env.clear()
			env.send("ON")
			assert.same({ 100 }, levels(env))
		end)

		it("TOGGLE goes by the shown state: on to off, off to Default On Brightness", function()
			env.send("TOGGLE")
			assert.same({ { light_on = false } }, env.model.wants)
			env.model:answer() -- the light is off now
			env.clear()
			env.settings.preset = 70
			env.send("TOGGLE")
			assert.same({ { light_on = true, level = 70 } }, env.model.wants)
		end)

		it("TOGGLE reads the shown state, wanted over confirmed, so two in a row go back and forth (R5)", function()
			env.send("TOGGLE")
			env.send("TOGGLE")
			env.send("TOGGLE")
			assert.same({ 0, 100, 0 }, levels(env))
		end)

		it("TOGGLE leaves a light whose state is not known alone, with a debug line and no notification", function()
			local fresh = new_env()
			fresh.send("TOGGLE")
			fresh.keypad.tap(2)
			assert.same({}, fresh.dev.sent)
			assert.same({}, fresh.model.wants)
			assert.equal(2, #fresh.log.of("debug"))
		end)

		it("rounds a level to a whole percent; a positive level never rounds down to off", function()
			for _, case in ipairs({ { "70", 70 }, { 70, 70 }, { "70.4", 70 }, { "70.5", 71 }, { "0.2", 1 }, { "0", 0 },
				{ "100", 100 }, { "100.4", 100 }, { "99.5", 100 } }) do
				env.clear()
				env.send("SET_LEVEL", { LEVEL = case[1] })
				assert.same({ case[2] }, levels(env), tostring(case[1]))
			end
		end)

		it("refuses a level that is no number, outside 0 to 100, or missing: a warning, nothing sent", function()
			for _, raw in ipairs({ "abc", "101", "-1", "100.5", "nan", "1e9" }) do
				env.send("SET_LEVEL", { LEVEL = raw })
			end
			env.send("SET_LEVEL", {})
			env.send("SET_LEVEL", { LEVEL = "" })
			env.send("SET_BRIGHTNESS_TARGET", {})
			assert.same({}, env.dev.sent)
			assert.same({}, env.model.wants)
			assert.equal(9, #env.log.of("warn"))
		end)

		it("a target equal to the level it is at still goes (V8) and still ends in a CHANGED", function()
			env.send("SET_LEVEL", { LEVEL = "40" })
			assert.same({ { light_on = true, level = 40 } }, env.model.wants)
			env.model:answer()
			assert.same({ changing(40, 40, 0), changed(40) }, env.dev.sent, "the open CHANGING is closed whatever the level")
		end)

		it("a target the model refuses is closed at once with the told level, and logged", function()
			env.model.refuse = "foreign"
			env.send("ON")
			assert.same({ changing(40, 100, 0), changed(40) }, env.dev.sent)
			assert.is_false(env.lt:debug().changing_open)
			assert.same({ "light ON not sent: foreign" }, env.log.of("warn"))
			assert.same({}, env.dev.leds, "the shown state did not move: the LEDs are left alone")
		end)

		it("before anything was told, a refused target closes with 0 (an unknown light reads as off)", function()
			local fresh = new_env()
			fresh.model.refuse = "unset"
			fresh.send("SET_LEVEL", { LEVEL = "30" })
			assert.same({ changing(0, 30, 0), changed(0) }, fresh.dev.sent)
		end)

		it("a burst of targets: one CHANGING each, the latest wins in the model, one CHANGED at the end (R5)", function()
			for level = 41, 50 do
				env.send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = tostring(level), RATE = "0" })
			end
			assert.equal(10, count(env, "LIGHT_BRIGHTNESS_CHANGING"))
			assert.same({ '{"lightBrightness":41}' }, env.model.requests, "one in flight, nothing piled up")
			env.model:answer() -- 41 is answered, the wanted 50 goes next
			assert.same({ '{"lightBrightness":41}', '{"lightBrightness":50}' }, env.model.requests)
			assert.equal(0, count(env, "LIGHT_BRIGHTNESS_CHANGED"), "a burst's intermediate answers fire nothing")
			env.model:answer()
			assert.equal(1, count(env, "LIGHT_BRIGHTNESS_CHANGED"))
			assert.same(changed(50), env.dev.sent[#env.dev.sent])
		end)
	end)

	describe("the two-step on (V14, section 4.3)", function()
		it("a top tap with the light off: one want, level then lightOn, one CHANGED after the second answer", function()
			local env = new_env({ settings = { preset = 50 } })
			env.start(false, 100)
			env.keypad.tap(0)
			assert.same({ changing(0, 50, 0) }, env.dev.sent)
			assert.same({ { light_on = true, level = 50 } }, env.model.wants, "the module hands over 'on at 50' whole")
			assert.same({ { on = true } }, env.dev.leds, "the LEDs are on at once (V10)")
			assert.same({ '{"lightBrightness":50}' }, env.model.requests)
			env.model:answer() -- off at 50: the level is kept while off
			assert.same({ '{"lightBrightness":50}', '{"lightOn":true}' }, env.model.requests)
			assert.same({ changing(0, 50, 0) }, env.dev.sent, "the CHANGING stays open across both requests")
			env.model:answer()
			assert.same({ changing(0, 50, 0), changed(50) }, env.dev.sent)
			assert.equal(1, #env.model.wants)
		end)

		it("when the target is the kept level there is one request, lightOn", function()
			local env = new_env({ settings = { preset = 50 } })
			env.start(false, 50)
			env.send("ON")
			assert.same({ '{"lightOn":true}' }, env.model.requests)
			env.model:answer()
			assert.same(changed(50), env.dev.sent[#env.dev.sent])
		end)

		it("a change of level while on is one plain level request", function()
			local env = new_env()
			env.start(true, 40)
			env.send("SET_LEVEL", { LEVEL = "20" })
			env.model:answer()
			assert.same({ '{"lightBrightness":20}' }, env.model.requests)
			assert.same(changed(20), env.dev.sent[#env.dev.sent])
		end)

		it("off is one lightOn false request, and the LEDs go dark at once", function()
			local env = new_env()
			env.start(true, 40)
			env.keypad.tap(1)
			assert.same({ { on = false } }, env.dev.leds)
			assert.same({ '{"lightOn":false}' }, env.model.requests)
		end)
	end)

	describe("what the proxy is told (R1 to R8)", function()
		local env
		before_each(function()
			env = new_env()
			env.start(true, 40)
		end)

		it("a change made elsewhere is a CHANGED when nothing is open, in whole percents", function()
			env.lt:settled({ light_on = true, level = 55 }, "outside")
			env.lt:settled({ light_on = true, level = 40.4 }, "outside")
			assert.same({ changed(55), changed(40) }, env.dev.sent)
		end)

		it("sends only what the proxy has not heard (R1)", function()
			env.lt:settled({ light_on = true, level = 40 }, "outside")
			env.lt:settled({ light_on = true, level = 40 }, "online")
			assert.same({}, env.dev.sent)
			env.lt:settled({ light_on = false, level = 40 }, "outside")
			env.lt:settled({ light_on = false, level = 40 }, "outside")
			env.lt:settled({ light_on = false, level = 90 }, "outside")
			assert.same({ changed(0) }, env.dev.sent, "off is 0 whatever level the fan keeps; a kept level is no change")
		end)

		it("a start is heard whatever the proxy was told (R6)", function()
			env.lt:settled({ light_on = true, level = 40 }, "start")
			env.lt:settled({ light_on = true, level = 40 }, "start")
			assert.same({ changed(40), changed(40) }, env.dev.sent)
		end)

		it("never reports 0 while on, and nothing for a state it cannot read", function()
			env.lt:settled({ light_on = true, level = 0 }, "outside")
			env.lt:settled({ light_on = true, level = 120 }, "outside")
			env.lt:settled({ light_on = true }, "outside")
			env.lt:settled({ level = 30 }, "outside")
			env.lt:settled(nil, "outside")
			assert.same({ changed(1), changed(100) }, env.dev.sent)
		end)

		it("closes a CHANGING with idle(): the confirmed level, whether or not it moved", function()
			env.send("SET_LEVEL", { LEVEL = "70" })
			env.lt:idle({ light_on = true, level = 65 })
			assert.same({ changing(40, 70, 0), changed(65) }, env.dev.sent)
			env.lt:idle({ light_on = true, level = 65 })
			assert.equal(2, #env.dev.sent, "idle with nothing open says nothing")
		end)

		it("idle without a state falls back to the model's confirmed state", function()
			env.send("SET_LEVEL", { LEVEL = "70" })
			env.model.confirmed_state = { light_on = true, level = 33 }
			env.lt:idle(nil)
			assert.same(changed(33), env.dev.sent[2])
		end)

		for _, idle_first in ipairs({ false, true }) do
			it("exactly one CHANGED for a target, " .. (idle_first and "idle()" or "settled()") .. " first", function()
				env.model.idle_first = idle_first
				env.send("SET_LEVEL", { LEVEL = "70" })
				env.model:answer()
				assert.same({ changing(40, 70, 0), changed(70) }, env.dev.sent)
			end)
		end

		it("a failed request closes the target with the level it was at, and the LEDs fall back", function()
			env.model.confirmed_state = { light_on = false, level = 40 }
			env.model.told = 0
			env.lt:settled({ light_on = false, level = 40 }, "outside")
			env.clear()
			env.keypad.tap(0)
			assert.same({ { on = true } }, env.dev.leds)
			env.model:fail()
			assert.same({ changing(0, 100, 0), changed(0) }, env.dev.sent)
			assert.same({ { on = true }, { on = false } }, env.dev.leds)
		end)

		it("a CHANGED is whole: LIGHT_BRIGHTNESS_CURRENT only (never LIGHT_LEVEL)", function()
			env.send("OFF")
			env.model:answer()
			for _, note in ipairs(env.dev.sent) do
				assert.is_truthy(note[1]:find("^LIGHT_BRIGHTNESS_CHANG"), note[1])
			end
			assert.same({ LIGHT_BRIGHTNESS_CURRENT = 0 }, env.dev.sent[2][2])
		end)
	end)

	describe("phases and ONLINE_CHANGED (section 6.1)", function()
		it("says nothing while waiting or rebooting, false when it refuses, true once online, once per change", function()
			local env = new_env()
			env.lt:phase("waiting", {}, nil)
			assert.same({}, env.dev.sent)
			env.lt:phase("online", {}, true)
			env.lt:phase("online", {}, true)
			assert.same({ online(true) }, env.dev.sent, "the proxy starts online, but R6 says it once")
			env.lt:phase("offline", {}, true)
			env.lt:phase("offline", {}, true)
			env.lt:phase("rebooting", {}, true)
			assert.same({ online(true), online(false) }, env.dev.sent, "rebooting leaves the last word")
			env.lt:phase("online", {}, true)
			env.lt:phase("foreign", {}, true)
			env.lt:phase("online", {}, true)
			env.lt:phase("gen4", {}, true)
			env.lt:phase("notfan", {}, true)
			env.lt:phase("unset", {}, true)
			env.lt:phase("online", {}, true)
			assert.same({ online(true), online(false), online(true), online(false), online(true), online(false), online(true) },
				env.dev.sent)
		end)

		it("a fan that is rebooting is neither online nor offline: the last word stands", function()
			local env = new_env()
			env.lt:phase("online", {}, true)
			env.lt:phase("rebooting", {}, true)
			env.lt:phase("online", {}, true) -- the first answer after it
			assert.same({ online(true) }, env.dev.sent)
		end)

		it("an unset driver greys the light out at once", function()
			local env = new_env()
			env.lt:phase("unset", {}, nil)
			assert.same({ online(false) }, env.dev.sent)
		end)

		it("warns about a phase it does not know and leaves the last word", function()
			local env = new_env()
			env.lt:phase("online", {}, true)
			env.lt:phase("hibernating", {}, true)
			assert.same({ online(true) }, env.dev.sent)
			assert.same({ "light: unknown phase hibernating ignored" }, env.log.of("warn"))
		end)

		it("takes the old phase the model's listener passes in third place as no word about the kit", function()
			local env = new_env()
			env.lt:phase("online", {}, "waiting")
			env.lt:phase("offline", {}, "online")
			assert.same({ online(true), online(false) }, env.dev.sent)
			env.send("ON")
			assert.equal(1, #env.model.wants, "not taken for a fan without a light kit")
		end)

		it("asks the model's info() about the kit when no boolean comes, and follows its answers", function()
			local env = new_env()
			env.model.info = function()
				return { has_light = false }
			end
			env.lt:phase("online", {}, "waiting")
			assert.same({ online(false) }, env.dev.sent, "no kit: never online")
			env.send("ON")
			assert.same({}, env.model.wants)
			env.model.info = function()
				return { has_light = true }
			end
			env.lt:phase("online", {}, "online")
			assert.same({ online(false), online(true) }, env.dev.sent)
			env.send("ON")
			assert.equal(1, #env.model.wants)
		end)

		it("a model whose info() raises or knows nothing leaves the kit as it was, and is no failure", function()
			local env = new_env()
			env.model.info = function()
				error("boom")
			end
			env.lt:phase("online", {}, nil)
			env.model.info = function()
				return nil
			end
			env.lt:phase("offline", {}, nil)
			env.lt:phase("online", {}, nil)
			assert.same({ online(true), online(false), online(true) }, env.dev.sent)
			assert.same({}, env.log.of("error"))
		end)

		it("an info() word that is not a boolean is no word: the last one stands", function()
			local env = new_env()
			env.model.info = function()
				return { has_light = false }
			end
			env.lt:phase("online", {}, nil)
			env.model.info = function()
				return { has_light = "yes" }
			end
			env.lt:phase("online", {}, nil)
			env.model.info = function()
				return {}
			end
			env.lt:phase("online", {}, nil)
			assert.same({ online(false) }, env.dev.sent)
			env.send("ON")
			assert.same({}, env.model.wants, "still a fan without a light kit")
		end)

		it("going offline closes an open CHANGING with the told level, never 0 (R7), and ends a ramp", function()
			local env = new_env()
			env.start(true, 40)
			env.send("SET_LEVEL", { LEVEL = "70" })
			env.lt:phase("offline", {}, true)
			assert.same({ changing(40, 70, 0), changed(40), online(false) }, env.dev.sent)
			assert.same({ told_level = 40, changing_open = false, notify_light = 5, ramping = false, fading = false },
				env.lt:debug())
		end)

		it("a command while offline is tried once: the model takes it, the proxy hears the pair", function()
			local env = new_env()
			env.start(true, 40)
			env.lt:phase("offline", {}, true)
			env.clear()
			env.send("OFF")
			assert.same({ changing(40, 0, 0) }, env.dev.sent)
			env.model:fail() -- the one try failed
			assert.same({ changing(40, 0, 0), changed(40) }, env.dev.sent)
		end)

		it("back online the differences are reported with why online, and ONLINE_CHANGED true", function()
			local env = new_env()
			env.start(true, 40)
			env.lt:phase("offline", {}, true)
			env.clear()
			env.lt:phase("online", {}, true)
			env.lt:settled({ light_on = true, level = 65 }, "online")
			assert.same({ online(true), changed(65) }, env.dev.sent)
		end)

		it("SYNCHRONIZE tells the proxy again what it knows, and nothing it does not", function()
			local env = new_env()
			env.send("SYNCHRONIZE")
			assert.same({}, env.dev.sent, "a light nobody has heard from: nothing to say")
			env.start(true, 40)
			env.send("SYNCHRONIZE")
			assert.same({ online(true), changed(40) }, env.dev.sent)
			env.clear()
			env.send("SET_LEVEL", { LEVEL = "70" })
			env.send("SYNCHRONIZE")
			assert.same({ changing(40, 70, 0), online(true) }, env.dev.sent, "its closing is on the way: no CHANGED")
			env.model:answer()
			env.lt:phase("offline", {}, true)
			env.clear()
			env.send("SYNCHRONIZE")
			assert.same({ online(false), changed(70) }, env.dev.sent)
		end)
	end)

	-- #141 LF-D1, LF-D6, LF-D9 to LF-D11: the one time-based engine.
	describe("the fade engine (LF-D6)", function()
		local env
		before_each(function()
			env = new_env()
			env.start(true, 40)
			env.model.answer_after = 100
		end)

		local function target(level, rate)
			env.send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = tostring(level), RATE = tostring(rate) })
		end

		it("opens CHANGING once with the planned time, and wants nothing until the first tick", function()
			target(100, 3000)
			assert.same({ changing(40, 100, 3000) }, env.dev.sent)
			assert.same({}, env.model.wants)
			assert.same({ fading = true, ramping = true, fade_kind = "timed", fade_from = 40, fade_to = 100, fade_ms = 3000,
				fade_steps = 0, told_level = 40, changing_open = true, notify_light = 3 }, env.lt:debug())
			env.clock.advance(49)
			assert.same({}, env.model.wants)
			env.clock.advance(1)
			assert.same({ 41 }, levels(env), "the line's level at 50 ms")
		end)

		it("wants the level of the straight line every tick, only when it changed, and the target at t0 + T", function()
			target(100, 3000)
			env.clock.advance(2999)
			local wanted = levels(env)
			assert.equal(59, #wanted, "41 at 50 ms to 99 at 2950 ms: 40 + elapsed / 50")
			for i, level in ipairs(wanted) do
				assert.equal(40 + i, level)
				assert.same({ fade = true }, env.model.want_opts[i], "a step carries the fade mark (LF-D6, LF-D8)")
			end
			assert.same({ changing(40, 100, 3000) }, env.dev.sent, "nothing per step (LF-D11)")
			env.clock.advance(1)
			assert.same({ light_on = true, level = 100 }, env.model.wants[60])
			assert.same({ of_fade = true }, env.model.want_opts[60], "the final target: no step mark, a fade's own")
			assert.equal(60, #env.model.wants, "no level is wanted twice")
			env.clock.advance(1000)
			assert.same({ changing(40, 100, 3000), changed(100) }, env.dev.sent)
			assert.is_false(env.lt:debug().fading)
			assert.same({}, env.clock.armed(), "no timer is left: not the tick, not the watchdog")
		end)

		it("goes by time, not by size: slow answers change what is sent, not what is wanted", function()
			local slow = new_env()
			slow.start(true, 40)
			slow.model.answer_after = 700
			slow.model.gap = 250
			slow.send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "100", RATE = "3000" })
			target(100, 3000)
			env.clock.advance(7000)
			slow.clock.advance(7000)
			assert.same(levels(env), levels(slow), "the same line whatever the fan's pace")
			assert.equal(1, slow.model.max_in_flight)
			assert.is_true(#slow.model.requests < #env.model.requests, "the newest level goes when the slot frees")
			local sent = {}
			for _, body in ipairs(slow.model.requests) do
				sent[#sent + 1] = tonumber(body:match("(%d+)"))
			end
			assert.equal(100, sent[#sent])
			for i = 2, #sent do
				assert.is_true(sent[i] > sent[i - 1], "never a level twice, never backwards")
			end
			assert.same({ changing(40, 100, 3000), changed(100) }, slow.dev.sent)
		end)

		it("fades down the same way", function()
			target(10, 2000) -- 40 to 10: 30 levels over 2 s
			env.clock.advance(150)
			assert.same({ 39, 38 }, levels(env), "40 - 30 x 50 / 2000 = 39.25; 38.5 is still 39; 37.75")
			env.clock.advance(3000)
			local wanted = levels(env)
			assert.same({ light_on = true, level = 10 }, env.model.wants[#env.model.wants])
			assert.equal(10, wanted[#wanted])
			assert.same({ changing(40, 10, 2000), changed(10) }, env.dev.sent)
		end)

		it("does not want the target twice when the last step was it: the fade ends when that is answered", function()
			-- 40 to 44 over 1000 ms: the line reaches 44 at the tick of 900 ms; its request is on the wire at 1000.
			env.model.answer_after = 150
			target(44, 1000)
			env.clock.advance(1000)
			assert.same({ 41, 42, 43, 44 }, levels(env))
			assert.is_true(env.lt:debug().fading)
			assert.same({ changing(40, 44, 1000) }, env.dev.sent)
			env.clock.advance(50)
			assert.same({ 41, 42, 43, 44 }, levels(env), "no second 44")
			assert.same({ changing(40, 44, 1000), changed(44) }, env.dev.sent)
			assert.is_false(env.lt:debug().fading)
		end)

		it("ends at once when the last step was the target and is answered already", function()
			target(44, 1000)
			env.clock.advance(1000) -- the 44 of 900 ms was answered at 1000, before the line's end
			assert.same({ 41, 42, 43, 44 }, levels(env))
			assert.same({ changing(40, 44, 1000), changed(44) }, env.dev.sent)
			assert.is_false(env.lt:debug().fading)
		end)

		it("takes back a step held in the model at the end and wants the target as an ordinary want (no budget)", function()
			env.model.answer_after = nil -- the first step stays on the wire; the newest waits behind it
			target(44, 1000)
			env.clock.advance(1000)
			assert.same({ 41, 42, 43, 44, 44 }, levels(env))
			assert.equal(1, env.model.withdrawals, "the waiting step is taken back")
			assert.same({ fade = true }, env.model.want_opts[4])
			assert.same({ of_fade = true }, env.model.want_opts[5], "and the target is wanted as an ordinary want")
			env.model:answer()
			env.model:answer()
			assert.same({ changing(40, 44, 1000), changed(44) }, env.dev.sent)
		end)

		it("a fade from off writes a dark first level and turns on, then starts its line at that idle (LF-D9)", function()
			local off = new_env()
			off.start(false, 100)
			off.model.answer_after = 100
			off.send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "80", RATE = "3000" })
			assert.same({ changing(0, 80, 3000) }, off.dev.sent)
			assert.same({ { light_on = true, level = 11 } }, off.model.wants, "80 x 400 / 3000, rounded")
			assert.same({ of_fade = true }, off.model.want_opts[1], "an ordinary want, marked as a fade's own")
			assert.same({ '{"lightBrightness":11}' }, off.model.requests)
			off.clock.advance(100)
			assert.same({ '{"lightBrightness":11}', '{"lightOn":true}' }, off.model.requests, "dark level, then lightOn")
			assert.is_true(off.lt:debug().fading)
			off.clock.advance(100) -- lightOn answered: the line starts at 200 ms
			assert.equal(1, #off.model.wants)
			off.clock.advance(50)
			assert.same({ 11, 12 }, levels(off), "11 + 69 x 50 / 2600, rounded")
			off.clock.advance(2549) -- 2799 ms: the line ends at 200 + 2600
			local before = #off.model.wants
			off.clock.advance(1)
			assert.equal(before + 1, #off.model.wants)
			assert.same({ light_on = true, level = 80 }, off.model.wants[before + 1])
			assert.same({ of_fade = true }, off.model.want_opts[before + 1], "the target is an ordinary want")
			off.clock.advance(1000)
			assert.same({ changing(0, 80, 3000), changed(80) }, off.dev.sent)
		end)

		it("the line's clock starts when the turn-on is answered, however long that takes (EC FT4)", function()
			local off = new_env()
			off.start(false, 100)
			off.model.answer_after = function(body)
				return body == '{"lightOn":true}' and 1500 or 100
			end
			off.send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "80", RATE = "3000" })
			off.clock.advance(1599)
			assert.equal(1, #off.model.wants, "no step while the light is turning on")
			off.clock.advance(1) -- answered at 1600
			off.clock.advance(50)
			assert.equal(2, #off.model.wants)
			off.clock.advance(2549) -- 1600 + 2600 = 4200
			local before = #off.model.wants
			off.clock.advance(1)
			assert.equal(before + 1, #off.model.wants, "the target at the end of the line")
			assert.same({ light_on = true, level = 80 }, off.model.wants[#off.model.wants])
		end)

		it("a fade to off steps down to 1, wants off at the end, and writes the level back while dark (LF-D10)", function()
			target(0, 2000)
			assert.same({ changing(40, 0, 2000) }, env.dev.sent)
			env.clock.advance(1999)
			local wanted = levels(env)
			assert.is_true(wanted[#wanted] <= 3 and wanted[#wanted] >= 1, "the last step is at the bottom, never off")
			for _, level in ipairs(wanted) do
				assert.is_true(level >= 1)
			end
			env.clock.advance(1)
			assert.same({ light_on = false }, env.model.wants[#env.model.wants], "off is the target")
			assert.same({ of_fade = true }, env.model.want_opts[#env.model.wants])
			assert.equal(0, count(env, "LIGHT_BRIGHTNESS_CHANGED"))
			env.clock.advance(250) -- the step in flight, then off, answered
			assert.same({ changing(40, 0, 2000), changed(0) }, env.dev.sent, "CHANGED 0 at that want's idle")
			assert.same({ light_on = false, level = 40 }, env.model.wants[#env.model.wants], "then the starting level, once")
			assert.equal('{"lightBrightness":40}', env.model.requests[#env.model.requests])
			env.clock.advance(1000)
			assert.same({ changing(40, 0, 2000), changed(0) }, env.dev.sent, "the write-back says nothing")
			assert.same({ light_on = false, level = 40 }, env.model:confirmed())
			assert.is_nil(env.model.wanted)
		end)

		it("the write-back is skipped when the fan keeps the level already, and when something else is wanted", function()
			local function final_wanted()
				local e = new_env()
				e.start(true, 40)
				e.model.answer_after = nil
				e.send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "0", RATE = "2000" })
				e.clock.advance(2000) -- the final off is wanted
				return e
			end
			local kept = final_wanted()
			kept.model.busy_override = false
			kept.lt:idle({ light_on = false, level = 40 })
			assert.same(changed(0), kept.dev.sent[#kept.dev.sent])
			assert.same({ light_on = false }, kept.model.wants[#kept.model.wants], "the fan keeps 40 already: nothing wanted")

			local other = final_wanted()
			other.model.busy_override = true -- something else is wanted
			other.lt:idle({ light_on = false, level = 1 })
			assert.same({ light_on = false }, other.model.wants[#other.model.wants])

			local free = final_wanted()
			free.model.busy_override = false
			free.lt:idle({ light_on = false, level = 1 })
			assert.same({ light_on = false, level = 40 }, free.model.wants[#free.model.wants])
		end)

		it("never writes the level back when the light is not off", function()
			env.model.answer_after = nil
			target(0, 2000)
			env.clock.advance(2000)
			env.model.busy_override = false
			env.lt:idle({ light_on = true, level = 1 })
			assert.same({ light_on = false }, env.model.wants[#env.model.wants])
		end)

		it("the settled() and idle() of the steps are not passed on (no CHANGED per step)", function()
			target(100, 3000)
			env.clock.advance(400)
			env.lt:settled({ light_on = true, level = 45 }, "command")
			env.lt:settled({ light_on = true, level = 45 }, "online")
			env.lt:settled({ light_on = true, level = 45 }, "start")
			env.lt:idle({ light_on = true, level = 45 })
			assert.same({ changing(40, 100, 3000) }, env.dev.sent)
			assert.is_true(env.lt:debug().fading)
		end)

		it("a fade too short or too small is one request, with CHANGING at rate 0 (LF-D5)", function()
			target(42, 5000) -- under FADE_MIN_LEVELS
			target(70, 999) -- under FADE_MIN_MS
			target(70, 0)
			assert.same({ 42, 70, 70 }, levels(env))
			assert.same({ changing(40, 42, 0), changing(42, 70, 0), changing(70, 70, 0) }, env.dev.sent)
			assert.is_false(env.lt:debug().fading)
			assert.is_false(env.model.want_opts[1])
		end)

		it("exactly the minimum fades: 1000 ms over 3 levels", function()
			target(43, 1000)
			assert.same({ changing(40, 43, 1000) }, env.dev.sent)
			assert.is_true(env.lt:debug().fading)
		end)

		it("a light whose level is not known is sent the target at once (EC FC18)", function()
			local fresh = new_env()
			fresh.send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "80", RATE = "3000" })
			assert.same({ changing(0, 80, 0) }, fresh.dev.sent)
			assert.same({ 80 }, levels(fresh))
		end)

		it("the constants are fields of the module, and the engine reads them when used", function()
			assert.equal(50, light.FADE_TICK_MS)
			assert.equal(1000, light.FADE_MIN_MS)
			assert.equal(3, light.FADE_MIN_LEVELS)
			assert.equal(400, light.FIRST_STEP_MS)
			assert.equal("target", light.LEDS_FOLLOW)
			assert.equal(600, light.DIM_AFTER_ON_MS)
			assert.is_nil(light.RAMP_STEP_MS, "the 500 ms hold ramp is gone")
			with({ FADE_TICK_MS = 100, FADE_MIN_MS = 200 }, function()
				target(100, 500) -- 40 to 100 over 500 ms
				env.clock.advance(100)
				assert.same({ 52 }, levels(env), "one tick in 100 ms: 40 + 60 x 100 / 500")
			end)
		end)

		it("a rate changed during a fade applies to the next one (LF-D22)", function()
			env.settings.brightness_rate = 3000
			env.send("ON")
			env.settings.brightness_rate = 1500
			env.settings.preset = 70
			env.clock.advance(100)
			assert.equal(3000, env.lt:debug().fade_ms)
			env.send("ON")
			assert.equal(1500, env.lt:debug().fade_ms)
		end)

		it("writes one summary line at debug when it ends, and logs no warning (LF-D20)", function()
			target(100, 3000)
			env.clock.advance(4000)
			local found
			for _, line in ipairs(env.log.of("debug")) do
				if line:find("light fade", 1, true) then
					found = line
				end
			end
			-- #195 MO-D12: a level names its unit ("40 %" is Control4's).
			assert.is_truthy(found:find("^light fade 40 %% → 100 %% over 3%.0 s: 60 steps, ended at 3%.%d s$"), found)
			assert.same({}, env.log.of("warn"))
		end)
	end)

	-- #141 LF-D2, LF-D4, LF-D5: what time each input asks for.
	describe("the time of a change (LF-D2 to LF-D5)", function()
		local env
		before_each(function()
			env = new_env()
			env.start(true, 40)
		end)

		local function send(command, params)
			env.send(command, params)
			return env.lt:debug()
		end

		it("SET_BRIGHTNESS_TARGET fades over RATE", function()
			local d = send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "70", RATE = "2000" })
			assert.same({ changing(40, 70, 2000) }, env.dev.sent)
			assert.is_true(d.fading)
			assert.equal(2000, d.fade_ms)
		end)

		it("a RATE of 0 (the Navigator slider) is one request (Q4)", function()
			send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "70", RATE = "0" })
			assert.same({ changing(40, 70, 0) }, env.dev.sent)
			assert.same({ 70 }, levels(env))
		end)

		it("a RATE under FADE_MIN_MS, and the 750 ms default rate, are one request (LF-D5)", function()
			send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "70", RATE = "750" })
			send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "80" })
			assert.same({ changing(40, 70, 0), changing(70, 80, 0) }, env.dev.sent)
			assert.is_false(env.lt:debug().fading)
		end)

		it("a RATE that is missing, empty or no number is the Default Brightness Rate; a negative one is 0", function()
			env.settings.brightness_rate = 4000
			for _, rate in ipairs({ "", "abc" }) do
				local d = send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "70", RATE = rate })
				assert.equal(4000, d.fade_ms, "RATE " .. rate)
			end
			assert.equal(4000, send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "75" }).fade_ms)
			env.clear()
			local d = send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "30", RATE = "-5" })
			assert.is_false(d.fading, "negative is 0: one request")
			assert.same({ 30 }, levels(env))
			assert.equal(1500, send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "90", RATE = "1500.7" }).fade_ms)
		end)

		it("the Default Brightness Rate is the 'brightness_rate' setting; 750 until the proxy sends one", function()
			env.settings.brightness_rate = nil
			assert.equal(750, light.DEFAULT_RATE_MS)
			assert.is_false(send("ON").fading)
			env.settings.brightness_rate = 3000
			assert.equal(3000, send("OFF").fade_ms)
			env.settings.brightness_rate = "x"
			assert.is_false(send("ON").fading, "no number: 750")
		end)

		it("RAMP_TO_LEVEL fades over TIME, or the default rate without one", function()
			assert.equal(5000, send("RAMP_TO_LEVEL", { LEVEL = "80", TIME = "5000" }).fade_ms)
			env.settings.brightness_rate = 2500
			assert.equal(2500, send("RAMP_TO_LEVEL", { LEVEL = "30" }).fade_ms)
			assert.same({ changing(40, 80, 5000), changing(40, 30, 2500) }, env.dev.sent)
		end)

		it("SET_LEVEL, ON, OFF and TOGGLE have no time of their own: the default rate", function()
			env.settings.brightness_rate = 3000
			assert.equal(3000, send("SET_LEVEL", { LEVEL = "80", TIME = "30000" }).fade_ms)
			assert.equal(3000, send("ON").fade_ms)
			assert.equal(3000, send("OFF").fade_ms)
			assert.equal(3000, send("TOGGLE").fade_ms)
		end)

		it("a change over fewer than 3 levels is one request however long it would take", function()
			env.settings.brightness_rate = 5000
			send("SET_LEVEL", { LEVEL = "42" })
			assert.is_false(env.lt:debug().fading)
			assert.same({ changing(40, 42, 0) }, env.dev.sent)
		end)

		it("logs the parameters of a command at debug, sorted, and nothing for a command with none (H1 to H3)", function()
			env.send("SET_BRIGHTNESS_TARGET", { RATE = "2000", LIGHT_BRIGHTNESS_TARGET = "70" })
			env.send("OFF")
			local found = {}
			for _, line in ipairs(env.log.of("debug")) do
				if line:find("^light SET_BRIGHTNESS_TARGET: LIGHT") then
					found[#found + 1] = line
				end
			end
			assert.same({ "light SET_BRIGHTNESS_TARGET: LIGHT_BRIGHTNESS_TARGET=70 RATE=2000" }, found)
			for _, line in ipairs(env.log.of("debug")) do
				assert.is_nil(line:find("^light OFF: %u"))
			end
		end)
	end)

	-- #141 section 3, the rows for taps.
	describe("taps (section 3)", function()
		local function tap_env(on, level, settings)
			local e = new_env({ settings = settings or {} })
			e.settings.click_up, e.settings.click_down = 3000, 4000
			e.start(on, level)
			e.model.answer_after = 100
			return e
		end

		it("off, top tap: a fade to the preset over click up x preset / 100, from a dark first level", function()
			local env = tap_env(false, 100, { preset = 60 })
			env.keypad.tap(0)
			assert.same({ changing(0, 60, 1800) }, env.dev.sent)
			assert.same({ { light_on = true, level = 13 } }, env.model.wants, "60 x 400 / 1800")
			assert.same({ on = true }, env.dev.leds[1], "the LEDs at the start of the fade (LF-D18)")
		end)

		it("on below the preset: a fade up over click up x distance / 100", function()
			local env = tap_env(true, 40)
			env.keypad.tap(0)
			assert.same({ changing(40, 100, 1800) }, env.dev.sent)
		end)

		it("on above the preset: a fade down to it over click down x distance / 100", function()
			local env = tap_env(true, 90, { preset = 50 })
			env.keypad.tap(0)
			assert.same({ changing(90, 50, 1600) }, env.dev.sent)
			env.clock.advance(3000)
			assert.same({ light_on = true, level = 50 }, env.model.wants[#env.model.wants])
			assert.same(changed(50), env.dev.sent[#env.dev.sent])
		end)

		it("at the preset (within 1 point): nothing is sent but CHANGED with the level", function()
			local env = tap_env(true, 50, { preset = 50 })
			env.keypad.tap(0)
			assert.same({ changed(50) }, env.dev.sent)
			assert.same({}, env.model.wants)
			local near = tap_env(true, 51, { preset = 50 })
			near.keypad.tap(0)
			assert.same({ changed(51) }, near.dev.sent)
			assert.same({}, near.model.wants)
			local off = tap_env(false, 100, { preset = 1 })
			off.keypad.tap(0)
			assert.same({ { light_on = true, level = 1 } }, off.model.wants, "off is not 'at the preset', even at 1")
		end)

		it("on, bottom tap: a fade to off over click down x level / 100", function()
			local env = tap_env(true, 40)
			env.keypad.tap(1)
			assert.same({ changing(40, 0, 1600) }, env.dev.sent)
			assert.same({ { on = false } }, env.dev.leds)
		end)

		it("off, bottom tap: nothing", function()
			local env = tap_env(false, 100)
			env.keypad.tap(1)
			assert.same({}, env.dev.sent)
			assert.same({}, env.model.wants)
		end)

		it("a toggle tap goes as the top tap from off and as the bottom tap from on", function()
			local env = tap_env(false, 100, { preset = 80 })
			env.keypad.tap(2)
			assert.same({ changing(0, 80, 2400) }, env.dev.sent)
			env.clock.advance(5000)
			env.clear()
			env.keypad.tap(2)
			assert.same({ changing(80, 0, 3200) }, env.dev.sent)
		end)

		it("a click rate of 0 is instant, and an unset one is 3000 ms (LF-D3, LF-D24)", function()
			local env = tap_env(true, 40)
			env.settings.click_up = 0
			env.keypad.tap(0)
			assert.same({ changing(40, 100, 0) }, env.dev.sent)
			local unset = tap_env(true, 40)
			unset.settings.click_up = nil
			unset.keypad.tap(0)
			assert.same({ changing(40, 100, 1800) }, unset.dev.sent)
		end)

		it("a change that is too short to show is one request: 97 to 100 over 90 ms", function()
			local env = tap_env(true, 97)
			env.keypad.tap(0)
			assert.same({ changing(97, 100, 0) }, env.dev.sent)
		end)

		it("a light whose level is not known goes to the target at once (EC FC18)", function()
			local top = new_env()
			top.settings.click_up = 3000
			top.keypad.tap(0)
			assert.same({ 100 }, levels(top))
			assert.same({ changing(0, 100, 0) }, top.dev.sent)
			local bottom = new_env()
			bottom.settings.click_down = 3000
			bottom.keypad.tap(1)
			assert.same({ 0 }, levels(bottom))
			assert.same({ changing(0, 0, 0) }, bottom.dev.sent)
		end)
	end)

	-- #141 LF-D12, LF-D13.
	describe("stopping a fade (LF-D13)", function()
		local env
		local function chasing()
			env = new_env()
			env.start(true, 40)
			env.model.answer_after = nil -- the spec answers: the first step stays on the wire
			env.send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "100", RATE = "3000" })
		end

		it("is a fade running for the press machine: dev.ramp_active", function()
			chasing()
			assert.is_true(env.dev.ramp_active())
			env.dev.on_ramp_stop(0)
			assert.is_false(env.dev.ramp_active())
			local idle = new_env()
			assert.is_false(idle.dev.ramp_active())
		end)

		it("takes back the step not sent, lets the one on the wire finish, and reports what the fan confirmed", function()
			chasing()
			env.clock.advance(150)
			assert.same({ 41, 42, 43 }, levels(env))
			assert.same({ '{"lightBrightness":41}' }, env.model.requests)
			env.dev.on_ramp_stop(1) -- any button
			assert.equal(1, env.model.withdrawals)
			assert.is_false(env.lt:debug().fading)
			assert.same({ changing(40, 100, 3000) }, env.dev.sent, "the step in flight is not over: still open")
			env.clock.advance(5000)
			assert.equal(3, #env.model.wants, "nothing more is wanted")
			assert.same({ '{"lightBrightness":41}' }, env.model.requests, "and no request goes out for the stop")
			env.model:answer()
			assert.same({ changing(40, 100, 3000), changed(41) }, env.dev.sent, "the level the fan confirmed")
			assert.same({}, env.clock.armed())
		end)

		it("reports at once when nothing is in flight", function()
			chasing()
			env.clock.advance(60)
			env.model:answer() -- the 41 is answered; the next tick has not come
			assert.same({ changing(40, 100, 3000) }, env.dev.sent)
			env.dev.on_ramp_stop(0)
			assert.same({ changing(40, 100, 3000), changed(41) }, env.dev.sent)
			assert.equal(0, env.model.withdrawals, "nothing was waiting")
		end)

		for _, stop in ipairs({ "SET_BRIGHTNESS_STOP", "STOP_SCENE_RAMP", "STOP_RAMP_SCENE" }) do
			it(stop .. " stops it the same way", function()
				chasing()
				env.clock.advance(150)
				env.send(stop, { SCENE_ID = "7" })
				assert.is_false(env.lt:debug().fading)
				assert.equal(1, env.model.withdrawals)
				env.model:answer()
				assert.same(changed(41), env.dev.sent[#env.dev.sent])
				env.clock.advance(5000)
				assert.equal(3, #env.model.wants)
			end)
		end

		-- Review fix 4 (a departure from the letter of LF-D13, see "Review fixes" in the contract): a
		-- stop before the turn-on was answered leaves the light on at the level reached, like a
		-- Control4 dimmer stopped mid-ramp, never dark with a level written and nothing more.
		it("a stop in the first, dark phase of a fade from off leaves the light on at the level reached", function()
			local off = new_env()
			off.start(false, 100)
			off.model.answer_after = nil
			off.send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "80", RATE = "3000" })
			off.dev.on_ramp_stop(0)
			assert.equal(0, off.model.withdrawals, "the first want is not taken back")
			assert.same({ changing(0, 80, 3000) }, off.dev.sent, "still open: the dark level is on the wire")
			off.model:answer() -- the dark level
			assert.same({ '{"lightBrightness":11}', '{"lightOn":true}' }, off.model.requests, "and the turn-on follows")
			off.model:answer()
			assert.same({ changing(0, 80, 3000), changed(11) }, off.dev.sent, "the light is on at 11, and says so")
			off.clock.advance(5000)
			assert.same({ { light_on = true, level = 11 } }, off.model.wants, "nothing else was wanted")
			assert.same({ light_on = true, level = 11 }, off.model:confirmed())
		end)

		it("a stop while that turn-on is already on the wire lets it finish", function()
			local off = new_env()
			off.start(false, 100)
			off.model.answer_after = 100
			off.send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "80", RATE = "3000" })
			off.clock.advance(150) -- the dark level answered; lightOn:true is on the wire
			assert.same({ '{"lightBrightness":11}', '{"lightOn":true}' }, off.model.requests)
			off.send("SET_BRIGHTNESS_STOP")
			off.clock.advance(5000)
			assert.same({ '{"lightBrightness":11}', '{"lightOn":true}' }, off.model.requests, "no second turn-on")
			assert.same({ changing(0, 80, 3000), changed(11) }, off.dev.sent)
			assert.same({ light_on = true, level = 11 }, off.model:confirmed())
		end)

		it("a stop after the line has begun takes back what is unsent, as before", function()
			local off = new_env()
			off.start(false, 100)
			off.model.answer_after = nil
			off.send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "80", RATE = "3000" })
			off.model:answer() -- the dark level
			off.model:answer() -- the turn-on: the line begins
			off.clock.advance(300)
			assert.is_true(off.lt:debug().fading)
			off.dev.on_ramp_stop(0)
			assert.equal(1, off.model.withdrawals)
		end)

		-- Review fix 3: a fade to off stopped while its final off is on the wire still writes
		-- the starting level back while dark (LF-D10); stopped before the off went out it leaves the
		-- light on at its last level, as before.
		describe("a fade to off", function()
			local off
			local function fading_to_off()
				off = new_env()
				off.start(true, 40)
				off.model.answer_after = nil
				off.send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "0", RATE = "1000" })
				off.clock.advance(1000) -- the final target is wanted, behind the step on the wire
				off.model:answer() -- the step: now the off goes out
			end

			it("stopped with its off on the wire writes the starting level back after the answer", function()
				fading_to_off()
				assert.equal('{"lightOn":false}', off.model.inflight)
				off.dev.on_ramp_stop(0)
				assert.is_false(off.lt:debug().fading)
				off.model:answer() -- the off
				assert.same({ changing(40, 0, 1000), changed(0) }, off.dev.sent)
				assert.same({ light_on = false, level = 40 }, off.model.wants[#off.model.wants], "the write-back")
				assert.same({ of_fade = true }, off.model.want_opts[#off.model.want_opts])
				assert.equal('{"lightBrightness":40}', off.model.inflight)
				off.model:answer()
				assert.same({ light_on = false, level = 40 }, off.model:confirmed())
				assert.same({ changing(40, 0, 1000), changed(0) }, off.dev.sent, "and says nothing")
			end)

			it("stopped before its off went out leaves the light on, and writes nothing back", function()
				off = new_env()
				off.start(true, 40)
				off.model.answer_after = nil
				off.send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "0", RATE = "1000" })
				off.clock.advance(1000) -- the off is wanted but waits behind the step on the wire
				off.dev.on_ramp_stop(0)
				local wants = #off.model.wants
				off.model:answer()
				assert.is_true(off.model:confirmed().light_on)
				assert.same(changed(off.model:confirmed().level), off.dev.sent[#off.dev.sent])
				off.clock.advance(5000)
				assert.equal(wants, #off.model.wants)
			end)

			it("a new command before the off is answered cancels the write-back", function()
				fading_to_off()
				off.dev.on_ramp_stop(0)
				off.send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "90", RATE = "0" })
				off.model.answer_after = 100
				off.model:answer() -- the off; the rest is answered by itself
				off.clock.advance(5000)
				for _, fields in ipairs(off.model.wants) do
					assert.is_false(fields.light_on == false and fields.level ~= nil, "no write-back of the old level")
				end
				assert.same({ light_on = true, level = 90 }, off.model:confirmed())
			end)

			it("a light that is not off when the stop's idle comes is not written to", function()
				fading_to_off()
				off.dev.on_ramp_stop(0)
				off.model.busy_override = false
				local wants = #off.model.wants
				off.lt:idle({ light_on = true, level = 12 })
				assert.equal(wants, #off.model.wants)
				off.lt:idle({ light_on = false, level = 40 }) -- and the write-back is spent, not kept for later
				assert.equal(wants, #off.model.wants)
			end)

			it("a level the fan keeps already is not written", function()
				fading_to_off()
				off.dev.on_ramp_stop(0)
				off.model.busy_override = false
				local wants = #off.model.wants
				off.lt:idle({ light_on = false, level = 40 })
				assert.equal(wants, #off.model.wants)
			end)
		end)

		it("a tap's press stops it and its click is swallowed: no new fade", function()
			chasing()
			env.keypad.stops = true
			env.settings.click_up = 3000
			env.clock.advance(400)
			env.keypad.tap(0)
			assert.is_false(env.lt:debug().fading)
			assert.equal(1, count(env, "LIGHT_BRIGHTNESS_CHANGING"))
		end)

		it("a hold during a fade stops it, then holds from the stopped level", function()
			local k = new_env()
			k.start(true, 40)
			k.model.answer_after = 100
			k.keypad.stops = true
			k.send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "20", RATE = "3000" })
			k.clock.advance(700)
			k.keypad.press(0)
			k.clock.advance(400 + 200)
			local sent = k.dev.sent
			assert.equal("LIGHT_BRIGHTNESS_CHANGING", sent[1][1])
			assert.equal("LIGHT_BRIGHTNESS_CHANGED", sent[2][1], "the stop's CHANGED comes first")
			assert.equal("LIGHT_BRIGHTNESS_CHANGING", sent[3][1])
			local stopped = sent[2][2].LIGHT_BRIGHTNESS_CURRENT
			assert.is_true(stopped < 40 and stopped > 20)
			assert.equal(stopped, sent[3][2].LIGHT_BRIGHTNESS_CURRENT, "the hold starts where the fade stopped")
			assert.equal(100, sent[3][2].LIGHT_BRIGHTNESS_TARGET, "up: top button")
			assert.equal("hold", k.lt:debug().fade_kind)
		end)
	end)

	-- #141 LF-D14.
	describe("a new command replaces the fade (LF-D14)", function()
		local env
		before_each(function()
			env = new_env()
			env.start(true, 40)
			env.model.answer_after = 100
			env.send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "100", RATE = "3000" })
			env.clock.advance(500)
		end)

		it("a new target fades from the level shown now, with a new CHANGING and no CHANGED in between", function()
			local shown = env.model.shown().level
			assert.is_true(shown > 45)
			env.send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "20", RATE = "2000" })
			assert.same({ changing(40, 100, 3000), changing(shown, 20, 2000) }, env.dev.sent)
			assert.equal("timed", env.lt:debug().fade_kind)
			assert.equal(20, env.lt:debug().fade_to)
			local before = #env.model.wants
			env.clock.advance(100)
			for i = before + 1, #env.model.wants do
				assert.is_true(env.model.wants[i].level < shown, "the old line is gone: the new one goes down")
			end
			env.clock.advance(4000)
			assert.same({ light_on = true, level = 20 }, env.model.wants[#env.model.wants])
			assert.same({ changing(40, 100, 3000), changing(shown, 20, 2000), changed(20) }, env.dev.sent)
		end)

		it("cancels the old fade's tick: one tick and one watchdog are armed", function()
			local manual = new_env()
			manual.start(true, 40)
			manual.send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "100", RATE = "3000" })
			manual.clock.advance(120)
			assert.equal(2, #manual.clock.armed())
			manual.send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "20", RATE = "2000" })
			assert.equal(2, #manual.clock.armed(), "the old tick is cancelled, the watchdog is moved")
		end)

		it("an OFF with no time of its own is one request, and no step follows it", function()
			local shown = env.model.shown().level
			env.send("OFF")
			assert.same({ changing(40, 100, 3000), changing(shown, 0, 0) }, env.dev.sent)
			assert.same({ light_on = false }, env.model.wants[#env.model.wants])
			local wants = #env.model.wants
			env.clock.advance(5000)
			assert.equal(wants, #env.model.wants)
			assert.same(changed(0), env.dev.sent[#env.dev.sent])
			assert.is_false(env.lt:debug().fading)
		end)

		it("a tap that is not a stop (the proxy route has no machine) fades the other way", function()
			env.settings.click_down = 3000
			local shown = env.model.shown().level
			env.keypad.tap(1)
			local second = env.dev.sent[2]
			assert.equal("LIGHT_BRIGHTNESS_CHANGING", second[1])
			assert.equal(0, second[2].LIGHT_BRIGHTNESS_TARGET)
			assert.is_true(second[2].LIGHT_BRIGHTNESS_CURRENT >= shown)
		end)

		it("a scene replaces it, and so does a hold", function()
			env.send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "50", RATE = "0" })
			assert.is_false(env.lt:debug().fading)
			env.send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "90", RATE = "3000" })
			env.keypad.press(1)
			env.clock.advance(400)
			assert.equal("hold", env.lt:debug().fade_kind)
			assert.equal(1, env.lt:debug().fade_to)
		end)

		it("a change that is too short to fade ends the fade too, and the replaced fade logs its summary", function()
			env.send("SET_LEVEL", { LEVEL = "10" })
			local found
			for _, line in ipairs(env.log.of("debug")) do
				if line:find("light fade", 1, true) then
					found = line
				end
			end
			assert.is_truthy(found:find("(replaced)", 1, true))
		end)
	end)

	-- #141 LF-D15.
	describe("a fade never fights anyone (LF-D15)", function()
		local env
		before_each(function()
			env = new_env()
			env.start(true, 40)
			env.model.answer_after = 100
			env.send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "100", RATE = "3000" })
			env.clock.advance(500)
		end)

		it("an off from outside (the model's dropped, then settled) ends it, is reported, and is never undone", function()
			local wants = #env.model.wants
			env.lt:dropped("off_outside")
			assert.is_false(env.lt:debug().fading)
			assert.same({ changing(40, 100, 3000) }, env.dev.sent, "the settled() that follows reports it")
			env.lt:settled({ light_on = false, level = 50 }, "outside")
			assert.same({ changing(40, 100, 3000), changed(0) }, env.dev.sent)
			env.clock.advance(10000)
			assert.equal(wants, #env.model.wants, "no further want: the light is not turned back on")
			assert.same({}, env.log.of("warn"))
		end)

		it("a settled() that shows the light off ends it even without the dropped()", function()
			local wants = #env.model.wants
			env.lt:settled({ light_on = false, level = 50 }, "outside")
			assert.same({ changing(40, 100, 3000), changed(0) }, env.dev.sent)
			assert.is_false(env.lt:debug().fading)
			env.clock.advance(10000)
			assert.equal(wants, #env.model.wants)
		end)

		it("a level the fade did not set (a poll during a slow fade) ends it and is reported", function()
			local last = levels(env)
			last = last[#last]
			env.lt:settled({ light_on = true, level = last + 20 }, "outside")
			assert.same({ changing(40, 100, 3000), changed(last + 20) }, env.dev.sent)
			assert.is_false(env.lt:debug().fading)
		end)

		it("the level it set last is no change from outside", function()
			local last = levels(env)
			last = last[#last]
			env.lt:settled({ light_on = true, level = last }, "outside")
			assert.is_true(env.lt:debug().fading)
			assert.same({ changing(40, 100, 3000) }, env.dev.sent)
		end)

		it("its own off at the end of a fade to off is no change from outside", function()
			local off = new_env()
			off.start(true, 40)
			off.model.answer_after = nil
			off.send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "0", RATE = "2000" })
			off.clock.advance(2000)
			off.lt:settled({ light_on = false, level = 1 }, "outside")
			assert.is_true(off.lt:debug().fading)
			assert.same({ changing(40, 0, 2000) }, off.dev.sent)
		end)
	end)

	-- #141 LF-D16.
	describe("a failure ends the fade (LF-D16)", function()
		local env
		local function chasing(to, from_on)
			env = new_env()
			env.start(from_on ~= false, from_on == false and 100 or 40)
			env.model.answer_after = nil
			env.send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = tostring(to), RATE = "3000" })
			env.clock.advance(150)
		end

		it("ends it, closes with the confirmed level, warns once, wants the target after the contact", function()
			chasing(100)
			local wants = #env.model.wants
			env.lt:dropped("failed")
			env.model:fail() -- and the idle() that follows
			assert.is_false(env.lt:debug().fading)
			assert.same({ changing(40, 100, 3000), changed(40) }, env.dev.sent, "the confirmed level, not the line's")
			assert.equal(1, #env.log.of("warn"))
			assert.equal(wants + 1, #env.model.wants)
			assert.same({ light_on = true, level = 100 }, env.model.wants[wants + 1])
			assert.same({ after_contact = true }, env.model.want_opts[wants + 1], "tied to the contact: not sent now")
			env.clock.advance(20000)
			assert.equal(wants + 1, #env.model.wants, "nothing is retried step by step")
			assert.equal(1, #env.model.requests, "and nothing more went on the wire")
		end)

		it("a given-up step is the same", function()
			chasing(100)
			env.lt:dropped("given_up")
			assert.is_false(env.lt:debug().fading)
			assert.same(changed(40), env.dev.sent[#env.dev.sent])
			assert.equal(1, #env.log.of("warn"))
			assert.same({ after_contact = true }, env.model.want_opts[#env.model.want_opts])
		end)

		it("a fade to off wants off after the contact, a fade from off wants its target", function()
			chasing(0)
			env.lt:dropped("failed")
			assert.same({ light_on = false }, env.model.wants[#env.model.wants])
			chasing(80, false)
			env.lt:dropped("failed")
			assert.same({ light_on = true, level = 80 }, env.model.wants[#env.model.wants])
			assert.same(changed(0), env.dev.sent[#env.dev.sent], "a light that was off is told it is still off")
		end)

		it("a target the model will not keep for the contact is only logged at debug", function()
			chasing(100)
			env.model.refuse = "offline"
			env.lt:dropped("failed")
			assert.equal(1, #env.log.of("warn"))
			assert.same(changed(40), env.dev.sent[#env.dev.sent])
		end)

		it("a refused step ends it with the told level and a warning, and keeps no target", function()
			chasing(100)
			local wants = #env.model.wants
			env.lt:dropped("refused")
			assert.is_false(env.lt:debug().fading)
			assert.same({ changing(40, 100, 3000), changed(40) }, env.dev.sent)
			assert.same({ "light fade stopped: refused" }, env.log.of("warn"))
			assert.equal(wants, #env.model.wants)
		end)

		-- Review fix 1: a hold's or a scene ramp's "target" is only the end of the range (100 or 1), so
		-- replaying it after a recovery would jump the light long after the button was let go.
		it("a hold that fails is not replayed: it ends, tells what is known, and wants nothing", function()
			local k = new_env()
			k.start(true, 40)
			k.model.answer_after = 100
			k.keypad.press(0)
			k.clock.advance(400 + 300)
			assert.equal("hold", k.lt:debug().fade_kind)
			local wants = #k.model.wants
			k.lt:dropped("failed")
			assert.is_false(k.lt:debug().fading)
			assert.equal(wants, #k.model.wants, "nothing after the contact")
			assert.is_nil(k.model.after_contact)
			assert.same(changed(k.model:confirmed().level), k.dev.sent[#k.dev.sent], "closed with the confirmed level")
			assert.same({ "light fade stopped: a step failed" }, k.log.of("warn"))
			k.keypad.release()
			k.clock.advance(20000)
			assert.equal(wants, #k.model.wants)
		end)

		it("a hold's step given up is not replayed either, and neither is a scene ramp's", function()
			local k = new_env()
			k.start(true, 40)
			k.model.answer_after = 100
			k.keypad.press(1)
			k.clock.advance(400 + 300)
			local wants = #k.model.wants
			k.lt:dropped("given_up")
			assert.equal(wants, #k.model.wants)
			assert.is_nil(k.model.after_contact)
			local scene = new_env()
			scene.start(true, 40)
			scene.model.answer_after = 100
			scene.send("RAMP_SCENE_UP", { SCENE_ID = "3" })
			assert.equal("scene", scene.lt:debug().fade_kind)
			scene.clock.advance(300)
			wants = #scene.model.wants
			scene.lt:dropped("failed")
			assert.is_false(scene.lt:debug().fading)
			assert.equal(wants, #scene.model.wants)
			assert.is_nil(scene.model.after_contact)
		end)

		it("a tap's fade is replayed, as a timed one is: their target is the owner's own", function()
			local t = new_env({ settings = { click_up = 3000 } })
			t.start(true, 40)
			t.model.answer_after = 100
			t.keypad.tap(0)
			assert.equal("tap", t.lt:debug().fade_kind)
			t.lt:dropped("failed")
			assert.same({ light_on = true, level = 100 }, t.model.after_contact)
			local timed = new_env()
			timed.start(true, 40)
			timed.model.answer_after = 100
			timed.send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "20", RATE = "3000" })
			timed.lt:dropped("failed")
			assert.same({ light_on = true, level = 20 }, timed.model.after_contact)
		end)

		it("a dropped() with no fade running changes nothing", function()
			local env2 = new_env()
			env2.start(true, 40)
			for _, why in ipairs({ "failed", "given_up", "refused", "off_outside" }) do
				env2.lt:dropped(why)
			end
			assert.same({}, env2.dev.sent)
			assert.same({}, env2.log.of("warn"))
			assert.same({}, env2.model.wants)
		end)

		it("a step the model refuses ends the fade with a warning and the told level", function()
			local e = new_env()
			e.start(true, 40)
			e.model.answer_after = 100
			e.send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "100", RATE = "3000" })
			e.clock.advance(500)
			e.model.refuse = "foreign"
			e.clock.advance(100)
			assert.is_false(e.lt:debug().fading)
			assert.same({ changing(40, 100, 3000), changed(40) }, e.dev.sent)
			assert.same({ "light fade stopped: foreign" }, e.log.of("warn"))
			local wants = #e.model.wants
			e.clock.advance(5000)
			assert.equal(wants, #e.model.wants)
		end)

		it("the turn-on of a fade from off that the model refuses starts no fade", function()
			local off = new_env()
			off.start(false, 100)
			off.model.refuse = "foreign"
			off.send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "80", RATE = "3000" })
			assert.same({ changing(0, 80, 3000), changed(0) }, off.dev.sent)
			assert.is_false(off.lt:debug().fading)
			assert.same({}, off.clock.armed())
		end)

		-- Review fix 2: an address change leaves online for waiting; a fade with nothing wanted or in
		-- flight then has no dropped() to end it, so the phase does (LF-D16).
		it("an address change (the phase becomes waiting) ends a fade the model is idle in", function()
			env = new_env()
			env.start(true, 40)
			env.model.answer_after = 100
			env.send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "100", RATE = "40000" })
			env.clock.advance(800) -- a step at 667 ms, answered at 767 ms: between two steps
			assert.same({ 41 }, levels(env))
			assert.is_false(env.model:busy())
			assert.is_true(env.lt:debug().fading)
			local wants = #env.model.wants
			env.lt:phase("waiting", {}, "online")
			assert.is_false(env.lt:debug().fading)
			assert.same({ changing(40, 100, 40000), changed(40) }, env.dev.sent,
				"the CHANGING is closed with the level the proxy heard last, nothing said about being online")
			env.clock.advance(60000)
			assert.equal(wants, #env.model.wants, "nothing of it goes on")
			assert.same({}, env.clock.armed())
		end)

		it("the same for a fade whose target waits in the model, which is taken back", function()
			chasing(100)
			env.model.answer_after = nil
			local before = env.model.withdrawals
			env.lt:phase("waiting", {}, "online")
			assert.is_false(env.lt:debug().fading)
			assert.equal(before + 1, env.model.withdrawals)
		end)

		it("waiting with no fade running, as at the start, changes nothing", function()
			local e = new_env()
			e.lt:phase("waiting", {}, "unset")
			assert.same({}, e.dev.sent)
			e.start(true, 40)
			e.model.answer_after = 100
			e.send("ON")
			e.model:answer()
			e.clear()
			e.lt:phase("waiting", {}, "online")
			assert.same({}, e.dev.sent)
		end)

		it("an address change or a reboot (the fan leaves the online phase) ends it, as today", function()
			chasing(100)
			env.lt:phase("offline", {}, true)
			assert.same({ changing(40, 100, 3000), changed(40), online(false) }, env.dev.sent)
			assert.is_false(env.lt:debug().fading)
			assert.same({}, env.clock.armed())
		end)
	end)

	-- #141 LF-D17.
	describe("the deadline (LF-D17)", function()
		it("ends a fade whose timer was lost at its planned end plus WATCHDOG_MS, and says so", function()
			local env = new_env()
			env.start(true, 40)
			env.send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "100", RATE = "3000" })
			env.clock.timers[#env.clock.timers]:Cancel() -- the tick: lost
			env.clock.advance(3000 + light.WATCHDOG_MS - 1)
			assert.same({ changing(40, 100, 3000) }, env.dev.sent)
			assert.is_true(env.lt:debug().fading)
			env.clock.advance(1)
			assert.same({ changing(40, 100, 3000), changed(40) }, env.dev.sent)
			assert.is_false(env.lt:debug().fading)
			assert.equal(1, #env.log.of("warn"))
			assert.same({}, env.clock.armed())
		end)

		it("takes back what the model has not sent", function()
			local env = new_env()
			env.start(true, 40)
			env.model.answer_after = nil
			env.send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "100", RATE = "1000" })
			env.clock.advance(200) -- 41 on the wire, 42 waiting
			env.clock.timers[#env.clock.timers]:Cancel()
			env.clock.advance(1000 + light.WATCHDOG_MS)
			assert.equal(1, env.model.withdrawals)
			env.model:answer() -- the step on the wire lands after the report: told as a change
			assert.same(changed(env.model:confirmed().level), env.dev.sent[#env.dev.sent])
		end)

		it("a long fade is no stuck CHANGING: the deadline is its own end plus WATCHDOG_MS", function()
			local env = new_env()
			env.start(true, 40)
			env.model.answer_after = 10
			env.send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "100", RATE = "60000" })
			env.clock.advance(light.WATCHDOG_MS * 3)
			assert.same({ changing(40, 100, 60000) }, env.dev.sent)
			assert.is_true(env.lt:debug().fading)
			assert.same({}, env.log.of("warn"))
		end)

		it("a fade from off moves its deadline to the start of its line", function()
			local off = new_env()
			off.start(false, 100)
			off.model.answer_after = function(body)
				return body == '{"lightOn":true}' and 12500 or 100
			end
			off.send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "80", RATE = "3000" })
			off.clock.advance(3000 + light.WATCHDOG_MS + 1) -- past the first deadline, planned end plus margin
			assert.is_true(off.lt:debug().fading, "the turn-on is answered at 12600 ms, and its line still has to run")
			assert.same({}, off.log.of("warn"))
		end)
	end)

	-- #141 LF-D18.
	describe("toggle and the keypad LEDs during a fade (LF-D18)", function()
		local env
		before_each(function()
			env = new_env()
			env.settings.click_down = 3000
			env.settings.brightness_rate = 2000
			env.start(true, 40)
			env.model.answer_after = 100
		end)

		it("with LEDS_FOLLOW 'target' the LEDs change at the start of a fade to off, and stay", function()
			env.keypad.tap(1)
			assert.is_false(env.dev.is_on())
			assert.same({ on = false }, env.dev.leds[1])
			env.clock.advance(1000)
			for _, led in ipairs(env.dev.leds) do
				assert.is_false(led.on)
			end
			env.clock.advance(3000)
			assert.is_false(env.dev.is_on())
		end)

		it("with LEDS_FOLLOW 'light' a fade to off shows on until the light is off", function()
			with({ LEDS_FOLLOW = "light" }, function()
				env.keypad.tap(1)
				env.clock.advance(500)
				assert.is_true(env.dev.is_on())
				env.clock.advance(5000)
				assert.is_false(env.dev.is_on())
			end)
		end)

		it("a fade up from off lights the LEDs at its start", function()
			local off = new_env()
			off.settings.click_up = 3000
			off.start(false, 100)
			off.keypad.tap(0)
			assert.is_true(off.dev.is_on())
			assert.same({ on = true }, off.dev.leds[1])
		end)

		it("the LEDs are told when a fade ends or is stopped", function()
			env.send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "0", RATE = "2000" })
			env.clock.advance(300)
			local n = #env.dev.leds
			env.dev.on_ramp_stop(0)
			assert.is_true(#env.dev.leds > n)
			assert.is_true(env.dev.is_on(), "stopped on: the shown state again")
			env.clock.advance(500)
			assert.is_true(env.dev.is_on())
		end)

		it("TOGGLE during a fade to off goes on, and during a fade up goes off, whatever the light shows", function()
			env.send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "0", RATE = "3000" })
			env.clock.advance(500)
			assert.is_true(env.model.shown().light_on, "still on at the first steps")
			env.send("TOGGLE")
			assert.equal(100, env.lt:debug().fade_to, "back on, to the preset")
			env.clock.advance(300)
			env.send("TOGGLE")
			assert.equal(0, env.lt:debug().fade_to, "heading on: off")
		end)

		it("a toggle tap goes by the target too", function()
			env.settings.click_up = 3000
			env.send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "0", RATE = "3000" })
			env.clock.advance(500)
			env.keypad.tap(2)
			assert.equal(100, env.lt:debug().fade_to)
		end)
	end)

	-- #141 LF-D19.
	describe("holds on the engine (LF-D19)", function()
		local env
		before_each(function()
			env = new_env()
			env.start(true, 40)
			env.model.answer_after = 100
		end)

		it("a hold up fades toward 100 over hold rate x distance / 100: one CHANGING, one CHANGED", function()
			env.keypad.press(0)
			env.clock.advance(400)
			assert.same({ changing(40, 100, 3000) }, env.dev.sent, "5000 ms for the whole range, 60 % of it to go")
			assert.equal("hold", env.lt:debug().fade_kind)
			env.clock.advance(50)
			assert.same({ 41 }, levels(env))
			env.clock.advance(3500)
			assert.same({ light_on = true, level = 100 }, env.model.wants[#env.model.wants])
			assert.same({ changing(40, 100, 3000), changed(100) }, env.dev.sent, "no CHANGED per step; the end closes it")
			assert.is_false(env.lt:debug().fading)
			env.clock.advance(5000)
			assert.same({}, env.clock.armed())
			local sent = #env.dev.sent
			env.keypad.release()
			assert.equal(sent, #env.dev.sent, "the release after the end changes nothing")
		end)

		it("a hold down fades toward 1, never off", function()
			env.keypad.press(1)
			env.clock.advance(400)
			assert.same({ changing(40, 1, 1950) }, env.dev.sent, "5000 ms for the whole range, 39 % of it to go")
			env.clock.advance(3000)
			assert.same({ light_on = true, level = 1 }, env.model.wants[#env.model.wants])
			for _, fields in ipairs(env.model.wants) do
				assert.is_true(fields.light_on and fields.level >= 1)
			end
			assert.same({ changing(40, 1, 1950), changed(1) }, env.dev.sent)
		end)

		it("the release stops it where the fan is: the step in flight finishes, and CHANGED says the level", function()
			env.keypad.press(0)
			env.clock.advance(400 + 1300)
			assert.is_true(env.lt:debug().fading)
			env.keypad.release()
			assert.is_false(env.lt:debug().fading)
			local wants = #env.model.wants
			env.clock.advance(100)
			local confirmed = env.model:confirmed().level
			assert.is_true(confirmed >= 60 and confirmed <= 66, "40 + 60 x 1300 / 3000 = 66")
			assert.same({ changing(40, 100, 3000), changed(confirmed) }, env.dev.sent)
			env.clock.advance(10000)
			assert.equal(wants, #env.model.wants, "no step after the release")
			assert.same({}, env.clock.armed())
		end)

		it("a hold from off turns the light on at 1 % and fades up 600 ms later", function()
			env.model.confirmed_state = { light_on = false, level = 100 }
			env.model.told = 0
			env.lt:settled({ light_on = false, level = 100 }, "outside")
			env.clear()
			env.keypad.press(0)
			env.clock.advance(400)
			assert.same({ changing(0, 1, 0) }, env.dev.sent, "the turn-on is a target like any other")
			assert.same({ { light_on = true, level = 1 } }, env.model.wants)
			env.clock.advance(200) -- both requests are answered
			assert.same({ changing(0, 1, 0), changed(1) }, env.dev.sent)
			env.clock.advance(400) -- 600 ms after the turn-on
			assert.same({ changing(0, 1, 0), changed(1), changing(1, 100, 4950) }, env.dev.sent)
			env.clock.advance(5500)
			assert.same({ light_on = true, level = 100 }, env.model.wants[#env.model.wants])
			assert.same(changed(100), env.dev.sent[#env.dev.sent])
		end)

		it("a release before the ramp begins leaves only the turn-on at 1 %", function()
			env.model.confirmed_state = { light_on = false, level = 100 }
			env.model.told = 0
			env.lt:settled({ light_on = false, level = 100 }, "outside")
			env.clear()
			env.keypad.press(0)
			env.clock.advance(700)
			env.keypad.release()
			env.clock.advance(5000)
			assert.same({ changing(0, 1, 0), changed(1) }, env.dev.sent)
			assert.same({ { light_on = true, level = 1 } }, env.model.wants)
		end)

		it("a hold down from off does nothing at all (device.lua never calls the light)", function()
			env.model.confirmed_state = { light_on = false, level = 100 }
			env.model.told = 0
			env.lt:settled({ light_on = false, level = 100 }, "outside")
			env.clear()
			env.keypad.press(1)
			env.clock.advance(5000)
			env.keypad.release()
			assert.same({}, env.dev.sent)
			assert.same({}, env.model.wants)
		end)

		it("a ramp from where the light already is does nothing: up at 100, down at 1", function()
			local top = new_env()
			top.start(true, 100)
			top.keypad.press(0)
			top.clock.advance(5000)
			assert.same({}, top.dev.sent)
			assert.same({}, top.model.wants)
			local bottom = new_env()
			bottom.start(true, 1)
			bottom.keypad.press(1)
			bottom.clock.advance(5000)
			assert.same({}, bottom.dev.sent)
		end)

		it("a hold that is too short to fade (2 levels to go) is one request", function()
			local top = new_env()
			top.start(true, 98)
			top.keypad.press(0)
			top.clock.advance(400)
			assert.same({ changing(98, 100, 0) }, top.dev.sent)
			assert.is_false(top.lt:debug().fading)
		end)

		it("a hold whose light state is not known is left alone", function()
			local fresh = new_env()
			fresh.keypad.press(0)
			fresh.clock.advance(5000)
			assert.same({}, fresh.dev.sent)
			assert.same({}, fresh.model.wants)
			assert.equal(1, #fresh.log.of("debug"))
		end)

		it("the hold rates are device.lua's: up and down apart, over the distance to go", function()
			env.settings.hold_up = 2000
			env.keypad.press(0)
			env.clock.advance(400)
			assert.same({ changing(40, 100, 1200) }, env.dev.sent, "2000 x 60 / 100")
			env.keypad.release()
			local down = new_env({ settings = { hold_down = 10000 } })
			down.start(true, 40)
			down.keypad.press(1)
			down.clock.advance(400)
			assert.same({ changing(40, 1, 3900) }, down.dev.sent, "10000 x 39 / 100")
		end)

		it("a hold whose turn-on the model refuses begins no ramp", function()
			local off = new_env()
			off.start(false, 100)
			off.model.refuse = "foreign"
			off.keypad.press(0)
			off.clock.advance(400)
			assert.same({ changing(0, 1, 0), changed(0) }, off.dev.sent)
			assert.same({ "light hold not sent: foreign" }, off.log.of("warn"))
			assert.same({}, off.clock.armed(), "no ramp waits to begin")
			off.clock.advance(5000)
			assert.equal(2, #off.dev.sent)
		end)

		it("a step the model refuses ends the fade; the proxy hears the told level", function()
			env.keypad.press(0)
			env.clock.advance(400 + 500)
			env.model.refuse = "foreign"
			env.clock.advance(100)
			assert.same({ changing(40, 100, 3000), changed(40) }, env.dev.sent)
			assert.same({ "light fade stopped: foreign" }, env.log.of("warn"))
			assert.is_false(env.lt:debug().fading)
		end)

		it("a target replaces the hold: no step after it, and the release has nothing to stop", function()
			env.keypad.press(0)
			env.clock.advance(400 + 700)
			env.send("OFF")
			local wants = #env.model.wants
			assert.same({ light_on = false }, env.model.wants[wants])
			env.clock.advance(100)
			env.keypad.release()
			env.clock.advance(5000)
			assert.equal(wants, #env.model.wants)
			assert.same(changed(0), env.dev.sent[#env.dev.sent])
			assert.equal(2, count(env, "LIGHT_BRIGHTNESS_CHANGING"))
		end)

		it("a press that replaces a hold still ends its fade (on_end_hold without on_finish)", function()
			env.keypad.press(0)
			env.clock.advance(400 + 1300)
			env.keypad.press(2) -- the keypad lost the release
			env.keypad.release() -- and this one is no hold
			assert.is_false(env.lt:debug().fading)
			env.clock.advance(1000)
			assert.equal(1, count(env, "LIGHT_BRIGHTNESS_CHANGING"))
			assert.equal(1, count(env, "LIGHT_BRIGHTNESS_CHANGED"))
			assert.same(changed(env.model:confirmed().level), env.dev.sent[#env.dev.sent])
		end)

		it("a step that finds its press gone stops the fade (a machine that told nothing)", function()
			env.keypad.press(0)
			env.clock.advance(400 + 700)
			env.keypad.hold = nil -- the press is gone, and neither on_end_hold nor on_finish was called
			assert.is_true(env.lt:debug().fading, "nothing told the light")
			env.clock.advance(50)
			assert.is_false(env.lt:debug().fading)
			env.clock.advance(1000)
			assert.equal(1, count(env, "LIGHT_BRIGHTNESS_CHANGED"))
		end)

		it("the device's timer cancel (h.timer) reaches the fade's tick", function()
			env.keypad.press(0)
			env.clock.advance(400 + 100)
			local h = env.keypad.hold
			assert.is_not_nil(h.timer, "device.lua cancels it when the press ends")
			h.timer:Cancel()
			local wants = #env.model.wants
			env.clock.advance(1000)
			assert.equal(wants, #env.model.wants, "a cancelled tick is a stopped fade's, not another")
		end)

		it("going offline during a hold stops it and closes the CHANGING with the told level", function()
			env.keypad.press(0)
			env.clock.advance(400 + 900)
			env.lt:phase("offline", {}, true)
			assert.same({ changing(40, 100, 3000), changed(40), online(false) }, env.dev.sent)
			local wants = #env.model.wants
			env.clock.advance(5000)
			assert.equal(wants, #env.model.wants)
			assert.same({}, env.clock.armed())
		end)

		it("steps with slow answers never put two requests in flight, and the newest wanted level is the one sent", function()
			env.model.answer_after = 700
			env.model.gap = 250
			env.keypad.press(0)
			env.clock.advance(400 + 3000 + 4000)
			assert.equal(1, env.model.max_in_flight)
			local sent = {}
			for _, body in ipairs(env.model.requests) do
				sent[#sent + 1] = tonumber(body:match("(%d+)"))
			end
			assert.is_true(#sent < 12, "the steps that found a request on the wire were coalesced")
			assert.equal(100, sent[#sent])
			for i = 2, #sent do
				assert.is_true(sent[i] > sent[i - 1])
			end
			assert.same({ changing(40, 100, 3000), changed(100) }, env.dev.sent)
			assert.is_false(env.model:busy())
		end)
	end)

	describe("Advanced Lighting Scenes (reduced_als_support)", function()
		local env
		before_each(function()
			env = new_env()
			env.start(true, 40)
			env.model.answer_after = 100
		end)

		it("RAMP_SCENE_UP fades toward 100 at the hold rate as a hold does, and a stop stops it", function()
			env.send("RAMP_SCENE_UP", { SCENE_ID = "3" })
			assert.same({ changing(40, 100, 3000) }, env.dev.sent)
			assert.equal("scene", env.lt:debug().fade_kind)
			env.clock.advance(1300)
			env.send("SET_BRIGHTNESS_STOP")
			assert.is_false(env.lt:debug().fading)
			env.clock.advance(5000)
			local confirmed = env.model:confirmed().level
			assert.is_true(confirmed >= 60 and confirmed <= 66)
			assert.same({ changing(40, 100, 3000), changed(confirmed) }, env.dev.sent)
		end)

		for _, stop in ipairs({ "SET_BRIGHTNESS_STOP", "STOP_SCENE_RAMP", "STOP_RAMP_SCENE" }) do
			it(stop .. " stops a running ramp", function()
				env.send("RAMP_SCENE_DOWN", { SCENE_ID = "7" })
				assert.same({ changing(40, 1, 1950) }, env.dev.sent)
				env.clock.advance(1000)
				env.send(stop, { SCENE_ID = "7" })
				env.clock.advance(300)
				local confirmed = env.model:confirmed().level
				assert.is_true(confirmed >= 17 and confirmed <= 24, "40 - 39 x 1000 / 1950 = 20")
				assert.same(changed(confirmed), env.dev.sent[#env.dev.sent])
			end)
		end

		it("a scene ramp runs its range and closes by itself", function()
			env.send("RAMP_SCENE_UP", {})
			env.clock.advance(4000)
			assert.same({ light_on = true, level = 100 }, env.model.wants[#env.model.wants])
			assert.same({ changing(40, 100, 3000), changed(100) }, env.dev.sent)
		end)

		it("a scene ramp on a light whose state is not known is left alone", function()
			local fresh = new_env()
			fresh.send("RAMP_SCENE_UP", { SCENE_ID = "1" })
			fresh.send("RAMP_SCENE_DOWN", { SCENE_ID = "1" })
			fresh.clock.advance(5000)
			assert.same({}, fresh.dev.sent)
			assert.same({}, fresh.model.wants)
		end)

		it("RAMP_SCENE_DOWN while off does nothing", function()
			env.model.confirmed_state = { light_on = false, level = 40 }
			env.model.told = 0
			env.lt:settled({ light_on = false, level = 40 }, "outside")
			env.clear()
			env.send("RAMP_SCENE_DOWN", { SCENE_ID = "1" })
			assert.same({}, env.dev.sent)
			assert.same({}, env.model.wants)
		end)

		it("RAMP_SCENE_UP while off turns the light on at 1 % and fades 600 ms later", function()
			env.model.confirmed_state = { light_on = false, level = 100 }
			env.model.told = 0
			env.lt:settled({ light_on = false, level = 100 }, "outside")
			env.clear()
			env.send("RAMP_SCENE_UP", { SCENE_ID = "1" })
			assert.same({ changing(0, 1, 0) }, env.dev.sent)
			env.clock.advance(600)
			assert.same({ changing(0, 1, 0), changed(1), changing(1, 100, 4950) }, env.dev.sent)
			env.clock.advance(500)
			assert.is_true(#env.model.wants > 1)
		end)

		it("a stop before that ramp begins keeps it from ever beginning", function()
			env.model.confirmed_state = { light_on = false, level = 100 }
			env.model.told = 0
			env.lt:settled({ light_on = false, level = 100 }, "outside")
			env.clear()
			env.send("RAMP_SCENE_UP", {})
			env.clock.advance(300)
			env.send("STOP_SCENE_RAMP")
			env.clock.advance(5000)
			assert.same({ changing(0, 1, 0), changed(1) }, env.dev.sent)
			assert.same({ 1 }, levels(env))
		end)

		it("a stop with no fade closes an open CHANGING with the told level; the answer says the rest", function()
			env.model.answer_after = nil
			env.send("SET_LEVEL", { LEVEL = "70" })
			env.send("SET_BRIGHTNESS_STOP")
			assert.same({ changing(40, 70, 0), changed(40) }, env.dev.sent)
			assert.same({ 70 }, levels(env), "nothing is taken back from the model")
			env.model:answer()
			assert.same({ changing(40, 70, 0), changed(40), changed(70) }, env.dev.sent)
		end)

		it("a stop with nothing running and nothing open does nothing", function()
			for _, stop in ipairs({ "SET_BRIGHTNESS_STOP", "STOP_SCENE_RAMP", "STOP_RAMP_SCENE" }) do
				env.send(stop, {})
			end
			assert.same({}, env.dev.sent)
			assert.same({}, env.model.wants)
		end)

		it("a scene's SET_BRIGHTNESS_TARGET fades over its per-load rate (LF-D2)", function()
			env.send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "30", RATE = "8000" })
			assert.same({ changing(40, 30, 8000) }, env.dev.sent)
		end)
	end)

	describe("without a light kit (section 4.7)", function()
		local env
		before_each(function()
			env = new_env()
			env.lt:phase("online", {}, false)
			env.clear()
		end)

		it("ONLINE_CHANGED is false for good, whatever the phase says", function()
			local fresh = new_env()
			fresh.lt:phase("online", {}, false)
			fresh.lt:phase("online", {}, false)
			fresh.lt:phase("offline", {}, false)
			fresh.lt:phase("online", {}, nil) -- no word of a kit: the last one stands
			assert.same({ online(false) }, fresh.dev.sent)
		end)

		it("refuses and logs every command: nothing wanted, nothing told", function()
			for _, command in ipairs({ "ON", "OFF", "TOGGLE", "SET_LEVEL", "SET_BRIGHTNESS_TARGET", "RAMP_SCENE_UP",
				"RAMP_SCENE_DOWN" }) do
				env.send(command, { LEVEL = "30", LIGHT_BRIGHTNESS_TARGET = "30" })
			end
			env.keypad.tap(0)
			env.keypad.press(0)
			env.clock.advance(1000)
			assert.same({}, env.dev.sent)
			assert.same({}, env.model.wants)
			assert.equal(9, #env.log.of("warn"), "seven commands, a tap and a hold")
			assert.equal("light ON refused: this fan has no light kit", env.log.of("warn")[1])
		end)

		it("leaves the LEDs alone: is_on is nil and the shown state is not followed", function()
			env.model.confirmed_state = { light_on = true, level = 50 }
			assert.is_nil(env.dev.is_on())
			env.lt:shown({ light_on = true, level = 50 })
			assert.same({}, env.dev.leds)
		end)

		it("reports nothing the model might still say about the light", function()
			env.lt:settled({ light_on = true, level = 50 }, "start")
			env.send("SYNCHRONIZE")
			assert.same({ online(false) }, env.dev.sent, "SYNCHRONIZE says the online word and no level")
		end)

		it("a kit that appears later is online again with the next online phase", function()
			env.lt:phase("online", {}, true)
			assert.same({ online(true) }, env.dev.sent)
			env.model.confirmed_state = { light_on = false, level = 50 }
			assert.is_false(env.dev.is_on())
		end)
	end)

	describe("the keypad's links and LEDs (200, 201, 202)", function()
		local env
		before_each(function()
			env = new_env({ settings = { preset = 60 } })
			env.start(false, 100)
		end)

		it("is_on is the shown state: nil while unknown, then wanted over confirmed (V10)", function()
			local fresh = new_env()
			assert.is_nil(fresh.dev.is_on())
			assert.is_false(env.dev.is_on())
			env.send("ON")
			assert.is_true(env.dev.is_on(), "on at once, before the fan has answered")
			env.model:fail()
			assert.is_false(env.dev.is_on(), "back when the request failed")
		end)

		it("the top tap goes to Default On Brightness, the bottom tap to off", function()
			env.keypad.tap(0)
			env.keypad.tap(1)
			assert.same({ changing(0, 60, 0), changing(60, 0, 0) }, env.dev.sent, "from the level shown now")
			assert.same({ 60, 0 }, levels(env))
		end)

		it("the toggle tap goes by the shown state", function()
			env.keypad.tap(2)
			assert.same({ 60 }, levels(env))
			env.keypad.tap(2)
			assert.same({ 60, 0 }, levels(env), "the shown state is the target, not the last answer")
		end)

		it("the LEDs hear every change of the shown state through shown(), the unforced update", function()
			env.keypad.tap(0)
			env.model:answer()
			env.model:answer()
			env.keypad.tap(1)
			assert.same({ { on = true }, { on = false } }, env.dev.leds)
		end)

		it("a refused tap leaves the LEDs where they were", function()
			env.model.refuse = "gen4"
			env.keypad.tap(0)
			assert.same({}, env.dev.leds)
			assert.is_false(env.dev.is_on())
		end)

		it("a change made elsewhere reaches the LEDs the same way, through the model's shown()", function()
			env.model.confirmed_state = { light_on = true, level = 80 }
			env.lt:shown({ light_on = true, level = 80 })
			assert.same({ { on = true } }, env.dev.leds)
		end)
	end)

	describe("robustness", function()
		it("a model that fails on want() is contained: logged, and the target closed with the told level", function()
			local env = new_env()
			env.start(true, 40)
			env.model.want = function() error("boom") end
			assert.has_no.errors(function() env.send("ON") end)
			assert.same({ changing(40, 100, 0), changed(40) }, env.dev.sent)
			assert.is_truthy(env.log.of("error")[1]:find("boom", 1, true))
		end)

		it("a failing dev.notify never reaches the caller, and leaves nothing open", function()
			local env = new_env()
			env.start(true, 40)
			env.dev.notify = function() error("no proxy") end
			assert.has_no.errors(function() env.send("OFF") end)
			assert.has_no.errors(function() env.lt:settled({ light_on = true, level = 10 }, "outside") end)
			assert.has_no.errors(function() env.lt:phase("offline", {}, true) end)
			assert.is_false(env.lt:debug().changing_open)
			assert.is_true(#env.log.of("error") >= 2)
		end)

		it("a failing update_leds never reaches the model", function()
			local env = new_env()
			env.start(true, 40)
			env.dev.update_leds = function() error("leds") end
			assert.has_no.errors(function() env.lt:shown({}) end)
			assert.is_truthy(env.log.of("error")[1]:find("leds", 1, true))
		end)

		it("a failing fade step is contained, and stops the fade", function()
			local env = new_env()
			env.start(true, 40)
			env.keypad.press(0)
			env.clock.advance(400)
			env.dev.holding = function() error("step") end
			assert.has_no.errors(function() env.clock.advance(500) end)
			assert.is_false(env.lt:debug().fading)
			assert.same({}, env.clock.armed())
			assert.same(changed(40), env.dev.sent[#env.dev.sent])
			assert.is_truthy(env.log.of("error")[1]:find("fade step failed", 1, true))
		end)

		it("stop() cancels every timer and the module answers nothing afterwards", function()
			local env = new_env()
			env.start(true, 40)
			env.keypad.press(0)
			env.clock.advance(400 + 700)
			assert.is_true(#env.clock.armed() >= 2, "the next step and the watchdog")
			local sent, wants = #env.dev.sent, #env.model.wants
			env.lt:stop()
			assert.same({}, env.clock.armed())
			env.send("OFF")
			env.lt:settled({ light_on = false, level = 40 }, "outside")
			env.lt:idle({ light_on = false, level = 40 })
			env.lt:phase("offline", {}, true)
			env.keypad.release()
			env.clock.advance(10000)
			assert.equal(sent, #env.dev.sent)
			assert.equal(wants, #env.model.wants, "no further wants")
			assert.has_no.errors(function() env.lt:stop() end)
		end)

		it("closes a CHANGING the model never closed, after WATCHDOG_MS, with the confirmed level, and says so", function()
			local env = new_env()
			env.start(true, 40)
			env.send("SET_LEVEL", { LEVEL = "70" })
			env.model.busy_override = false -- the model lost the target without an idle()
			env.clock.advance(light.WATCHDOG_MS - 1)
			assert.same({ changing(40, 70, 0) }, env.dev.sent)
			env.clock.advance(1)
			assert.same({ changing(40, 70, 0), changed(40) }, env.dev.sent)
			assert.equal(1, #env.log.of("warn"))
			assert.same({}, env.clock.armed())
		end)

		it("waits while the model is busy, and while a ramp runs", function()
			local env = new_env()
			env.start(true, 40)
			env.send("SET_LEVEL", { LEVEL = "70" })
			env.clock.advance(light.WATCHDOG_MS * 3)
			assert.same({ changing(40, 70, 0) }, env.dev.sent, "a request still on the wire")
			env.model:answer()
			assert.equal(2, #env.dev.sent)

			local ramp = new_env({ settings = { hold_up = 40000 } })
			ramp.start(true, 40)
			ramp.model.answer_after = 10
			ramp.keypad.press(0)
			ramp.clock.advance(400 + light.WATCHDOG_MS * 2)
			assert.same({ changing(40, 100, 24000) }, ramp.dev.sent, "a long ramp is no stuck CHANGING")
			assert.is_true(ramp.lt:debug().ramping)
		end)

		it("waits for a scene ramp that has not begun yet", function()
			local saved = light.WATCHDOG_MS
			light.WATCHDOG_MS = 300
			local ok, err = pcall(function()
				local env = new_env()
				env.start(false, 100)
				env.model.busy_override = false -- nothing in the model keeps the CHANGING open
				env.send("RAMP_SCENE_UP", {})
				env.clock.advance(300)
				assert.same({ changing(0, 1, 0) }, env.dev.sent, "the ramp begins at 600 ms: still waiting")
				env.clock.advance(300)
				assert.same({ changing(0, 1, 0), changing(1, 100, 4950) }, env.dev.sent)
				assert.same({}, env.log.of("warn"))
			end)
			light.WATCHDOG_MS = saved
			assert(ok, err)
		end)

		it("debug() counts what it told: CHANGING, CHANGED and ONLINE_CHANGED", function()
			local env = new_env()
			env.start(true, 40) -- ONLINE_CHANGED and CHANGED
			env.send("OFF")
			env.model:answer() -- CHANGING and CHANGED
			assert.same({ told_level = 0, changing_open = false, notify_light = 4, ramping = false, fading = false },
				env.lt:debug())
		end)
	end)

	-- #195 Min On (docs/min-on-design.md MO-D2 to MO-D12; docs/edge-cases-min-on.md sections 1 to 6). The
	-- fake model speaks the fan's levels, as the real one does: every want and request below is a fan
	-- level, and everything the proxy hears is a Control4 level.
	describe("Min On (#195)", function()
		-- An env whose light has Min On `M`, taken as late init's replay takes it: before the first
		-- contact, nothing sent.
		local function min_env(M, opts)
			local env = new_env(opts)
			local ok, taken = env.lt:set_min_on(M, "load")
			assert.is_true(ok)
			assert.equal(M, taken)
			return env
		end

		-- The debug lines that match `pattern`.
		local function debug_lines(env, pattern)
			local out = {}
			for _, line in ipairs(env.log.of("debug")) do
				if line:find(pattern) then
					out[#out + 1] = line
				end
			end
			return out
		end

		describe("the mapping (MO-D3)", function()
			it("is no change at M nil, 0 or 1, both ways, for every level", function()
				for level = 0, 100 do
					assert.equal(level, light.to_fan(level))
					assert.equal(level, light.from_fan(level))
					for _, M in ipairs({ 0, 1, "0", 0.4 }) do
						assert.equal(level, light.to_fan(level, M), tostring(M))
						assert.equal(level, light.from_fan(level, M), tostring(M))
					end
				end
			end)

			it("keeps every level in range for every M from 0 to 99: off is off, on is m to 100 on the fan, 1 to 100 here",
				function()
					for M = 0, 99 do
						local m = math.max(1, M)
						assert.equal(0, light.to_fan(0, M))
						assert.equal(0, light.from_fan(0, M))
						assert.equal(m, light.to_fan(1, M), "Control4's 1 % is the first lit level, M " .. M)
						assert.equal(100, light.to_fan(100, M))
						assert.equal(100, light.from_fan(100, M))
						local before = m
						for s = 1, 100 do
							local f = light.to_fan(s, M)
							assert.is_true(f >= m and f <= 100 and f == math.floor(f), "M " .. M .. ", " .. s .. " %")
							assert.is_true(f >= before and f <= before + 1, "a straight line, never down, never a gap")
							before = f
						end
						for f = 1, 100 do
							local c = light.from_fan(f, M)
							assert.is_true(c >= 1 and c <= 100 and c == math.floor(c), "M " .. M .. ", fan level " .. f)
						end
					end
				end)

			it("brings every fan level from m up back through Control4 unchanged, keeps them apart, is 1 % below m", function()
				for M = 0, 99 do
					local m = math.max(1, M)
					local seen = {}
					for f = m, 100 do
						local c = light.from_fan(f, M)
						assert.equal(f, light.to_fan(c, M), "M " .. M .. ", fan level " .. f .. " (RO5)")
						assert.is_nil(seen[c], "two fan levels, one Control4 level")
						seen[c] = true
					end
					for f = 1, m - 1 do
						assert.equal(1, light.from_fan(f, M), "on below Min On is 1 %, never 0 (MO-D5)")
					end
				end
			end)

			it("takes a Control4 level back to within a point up to M 67 and two up to 80 (why RO1 keeps a memory)", function()
				for M = 0, 80 do
					local worst = 0
					for s = 1, 100 do
						worst = math.max(worst, math.abs(light.from_fan(light.to_fan(s, M), M) - s))
					end
					assert.is_true(worst <= (M <= 67 and 1 or 2), "M " .. M .. ": " .. worst)
				end
			end)

			it("gives the edge cases' examples, rounding half up", function()
				assert.equal(20, light.to_fan(1, 20))
				assert.equal(22, light.to_fan(4, 20), "4 % is fan level 22 ...")
				assert.equal(3, light.from_fan(22, 20), "... which maps back to 3 % (RO1)")
				assert.equal(30, light.to_fan(13, 20), "TO7")
				assert.equal(60, light.to_fan(50, 20))
				assert.equal(51, light.from_fan(60, 20), "49.5 rounds up")
				assert.equal(51, light.to_fan(2, 50))
				assert.equal(3, light.from_fan(51, 50))
				assert.equal(75, light.to_fan(50, 50))
				assert.equal(1, light.from_fan(5, 20))
				assert.equal(1, light.from_fan(20, 20))
			end)

			it("never turns a positive level off, never divides by 0, and says nil for no number", function()
				assert.equal(20, light.to_fan(0.4, 20), "a level above 0 is at least 1 %")
				assert.equal(52, light.to_fan("40", 20))
				assert.equal(99, light.to_fan(1, 100), "M of 100 or more acts as 99")
				assert.equal(100, light.from_fan(100, 1000))
				assert.equal(1, light.from_fan(99, 1000))
				assert.equal(0, light.to_fan(-3, 20))
				assert.equal(100, light.to_fan(150, 20))
				assert.is_nil(light.to_fan("abc", 20))
				assert.is_nil(light.to_fan(nil, 20))
				assert.is_nil(light.from_fan(0 / 0, 20))
				assert.is_nil(light.from_fan(nil, 20))
			end)
		end)

		-- Edge cases table 1.4: each check in the unit that table names, at M = 20 (MO-D8). The :1072 one
		-- first: it could end a fade by itself.
		describe("the eight checks of edge cases 1.4, at M = 20 (MO-D8)", function()
			it(":1072 a fade does not end itself when a read shows its own step, which maps back to a neighbour", function()
				-- 2 % (fan level 21) to 100 % over 2450 ms, two Control4 levels a tick: the first step is 4 %,
				-- fan level 22, which maps back to 3 %.
				local env = min_env(20)
				env.start(true, 21)
				env.model.answer_after = 10
				env.send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "100", RATE = "2450" })
				env.clock.advance(60)
				assert.same({ 22 }, levels(env))
				assert.equal(3, light.from_fan(22, 20))
				env.lt:settled({ light_on = true, level = 22 }, "outside")
				assert.is_true(env.lt:debug().fading, "its own step is no change from outside")
				assert.same({ changing(2, 100, 2450) }, env.dev.sent)

				-- 1 % (fan level 20) to 100 % over 9900 ms: the line passes 3 % and then 4 %, both fan level 22.
				local slow = min_env(20)
				slow.start(true, 20)
				slow.model.answer_after = 10
				slow.send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "100", RATE = "9900" })
				slow.clock.advance(260)
				assert.same({ 21, 22 }, levels(slow), "4 % at 250 ms is fan level 22 again: not wanted")
				slow.lt:settled({ light_on = true, level = 22 }, "outside")
				assert.is_true(slow.lt:debug().fading)
				assert.same({ changing(1, 100, 9900) }, slow.dev.sent)
				-- A level the fade did not set still ends it (LF-D15), told in Control4's levels.
				slow.lt:settled({ light_on = true, level = 60 }, "outside")
				assert.is_false(slow.lt:debug().fading)
				assert.same({ changing(1, 100, 9900), changed(51) }, slow.dev.sent)
			end)

			it(":527 a change too small to show counts fan levels: 3 % to 6 % is fan level 22 to 24, one request", function()
				local env = min_env(20)
				env.start(true, 22)
				env.send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "6", RATE = "3000" })
				assert.same({ changing(3, 6, 0) }, env.dev.sent, "three Control4 levels, two of the fan's: no fade")
				assert.same({ { light_on = true, level = 24 } }, env.model.wants)
				assert.is_false(env.lt:debug().fading)
				-- From off, off counts as the level below the first lit one, as it does at Min On 0.
				local two = min_env(20)
				two.start(false, 100)
				two.send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "2", RATE = "3000" })
				assert.is_false(two.lt:debug().fading, "off to 2 %, fan level 21: two levels")
				local three = min_env(20)
				three.start(false, 100)
				three.send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "3", RATE = "3000" })
				assert.is_true(three.lt:debug().fading, "off to 3 %, fan level 22: three levels")
			end)

			it(":546 a fade from off works out its dark first level in Control4's levels, then maps it: 13 % is fan 30",
				function()
					local env = min_env(20)
					env.start(false, 100)
					env.model.answer_after = 100
					env.send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "100", RATE = "3000" })
					assert.same({ changing(0, 100, 3000) }, env.dev.sent)
					assert.same({ { light_on = true, level = 30 } }, env.model.wants, "100 x 400 / 3000 = 13 %, fan 30 (TO7)")
					assert.same({ of_fade = true }, env.model.want_opts[1])
					assert.same({ '{"lightBrightness":30}' }, env.model.requests, "written while dark, then lightOn (TO1)")
					env.clock.advance(250) -- the turn-on is answered at 200 ms; the line runs from 13 % on
					assert.same({ 30, 31 }, levels(env), "13 + 87 x 50 / 2600 = 15 %, fan level 31")
					env.clock.advance(4000)
					assert.same(changed(100), env.dev.sent[#env.dev.sent])
				end)

			it(":626 'at the preset' compares the fan's level with the preset's fan level", function()
				-- The preset 50 % is fan level 60. Fan level 61 reads 52 %: two Control4 points, one of the fan's.
				local settings = { preset = 50, click_up = 3000, click_down = 3000 }
				local env = min_env(20, { settings = settings })
				env.start(true, 61)
				env.keypad.tap(0)
				assert.same({ changed(52) }, env.dev.sent, "at the preset: nothing sent but the level (PL9)")
				assert.same({}, env.model.wants)
				local far = min_env(20, { settings = settings })
				far.start(true, 62)
				far.keypad.tap(0)
				assert.same({ changing(53, 50, 0) }, far.dev.sent, "fan level 62 is two away")
				assert.same({ { light_on = true, level = 60 } }, far.model.wants)
			end)

			it(":730 a step is wanted only when its fan level changes: 1 % to 100 %, a Control4 level a tick, is 80 steps",
				function()
					local env = min_env(20)
					env.start(true, 20)
					env.model.answer_after = 10
					env.send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "100", RATE = "4950" })
					env.clock.advance(6000)
					local wanted = levels(env)
					assert.equal(80, #wanted, "fan levels 21 to 100, each once, over 99 ticks (RT3)")
					for i, level in ipairs(wanted) do
						assert.equal(20 + i, level)
					end
					assert.same({ changing(1, 100, 4950), changed(100) }, env.dev.sent)
				end)

			it(":748 a last step at the target's fan level is not wanted again, and the proxy hears the target", function()
				-- 41 % (fan 52) to 3 % (fan 22) over 1900 ms: the last tick is 4 %, fan level 22 as well.
				local env = min_env(20)
				env.start(true, 52)
				env.model.answer_after = 10
				env.send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "3", RATE = "1900" })
				env.clock.advance(1899)
				local wanted = levels(env)
				assert.equal(22, wanted[#wanted])
				env.clock.advance(1000)
				local n = 0
				for _, level in ipairs(levels(env)) do
					n = n + (level == 22 and 1 or 0)
				end
				assert.equal(1, n, "fan level 22 once")
				assert.same({ changing(41, 3, 1900), changed(3) }, env.dev.sent, "3 %, what Control4 asked for, not 4 %")
				assert.is_false(env.lt:debug().fading)
			end)

			it(":785 a fade to off writes back the raw fan level it started from, and skips one the fan keeps (TO4)",
				function()
					local env = min_env(20)
					env.start(true, 52) -- 41 %
					env.model.answer_after = 100
					env.send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "0", RATE = "2000" })
					env.clock.advance(3000)
					assert.same({ light_on = false, level = 52 }, env.model.wants[#env.model.wants], "fan level 52, not 41")
					assert.same({ light_on = false, level = 52 }, env.model:confirmed())

					local kept = min_env(20)
					kept.start(true, 52)
					kept.model.answer_after = nil
					kept.send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "0", RATE = "2000" })
					kept.clock.advance(2000) -- the final off is wanted
					kept.model.busy_override = false
					kept.lt:idle({ light_on = false, level = 52 })
					assert.same(changed(0), kept.dev.sent[#kept.dev.sent])
					assert.same({ light_on = false }, kept.model.wants[#kept.model.wants], "the fan keeps 52 already")
				end)

			it(":1084 the proxy hears a Control4 level once: a remote stepping below Min On is 1 % once (OX6)", function()
				local env = min_env(20)
				env.start(true, 52)
				for _, fan in ipairs({ 5, 8, 12, 19, 20 }) do
					env.lt:settled({ light_on = true, level = fan }, "outside")
				end
				assert.same({ changed(1) }, env.dev.sent, "five fan levels, one Control4 level")
				env.lt:settled({ light_on = true, level = 21 }, "outside")
				assert.same({ changed(1), changed(2) }, env.dev.sent)
				assert.same({}, env.model.wants, "nothing is written (MO-D5)")
			end)
		end)

		describe("what the light does with it", function()
			it("a slider set to 4 %: the fan gets 22 and the proxy hears 4 %, not 3 % (RO1, RO2, PL5)", function()
				local env = min_env(20)
				env.start(true, 52)
				env.send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "4", RATE = "0" })
				assert.same({ { light_on = true, level = 22 } }, env.model.wants)
				assert.same({ '{"lightBrightness":22}' }, env.model.requests)
				env.model:answer()
				assert.same({ changing(41, 4, 0), changed(4) }, env.dev.sent)
				assert.equal(4, env.lt:c4_level(env.model:confirmed()))
				-- A later read of that level is no change; another level is mapped back.
				env.lt:settled({ light_on = true, level = 22 }, "online")
				env.lt:settled({ light_on = true, level = 23 }, "outside")
				assert.same({ changing(41, 4, 0), changed(4), changed(5) }, env.dev.sent)
			end)

			it("a hold from off turns on at 1 %, fan level 20, lit at once, and ramps from there over Control4's range (TO5)",
				function()
					local env = min_env(20)
					env.start(false, 100)
					env.model.answer_after = 100
					env.keypad.press(0)
					env.clock.advance(400)
					assert.same({ changing(0, 1, 0) }, env.dev.sent)
					assert.same({ { light_on = true, level = 20 } }, env.model.wants, "the first want is fan level 20")
					assert.same({ '{"lightBrightness":20}' }, env.model.requests, "the level while dark, then lightOn")
					env.clock.advance(200)
					assert.same({ changing(0, 1, 0), changed(1) }, env.dev.sent)
					env.clock.advance(400) -- DIM_AFTER_ON_MS after the turn-on
					assert.same(changing(1, 100, 4950), env.dev.sent[3], "the hold rate over Control4's range (RT1)")
					env.clock.advance(6000)
					for _, level in ipairs(levels(env)) do
						assert.is_true(level >= 20)
					end
					assert.same(changed(100), env.dev.sent[#env.dev.sent])
				end)

			it("a hold down stops at 1 %, which is fan level 20, never below (TO6)", function()
				local env = min_env(20)
				env.start(true, 52)
				env.model.answer_after = 100
				env.keypad.press(1)
				env.clock.advance(400)
				assert.same({ changing(41, 1, 2000) }, env.dev.sent, "5000 ms x 40 / 100: over Control4's range")
				env.clock.advance(3000)
				assert.same({ light_on = true, level = 20 }, env.model.wants[#env.model.wants])
				for _, level in ipairs(levels(env)) do
					assert.is_true(level >= 20)
				end
				assert.same({ changing(41, 1, 2000), changed(1) }, env.dev.sent)
			end)

			it("a fade to off steps down to fan level 20, then off, then writes the raw starting level back dark (TO3)",
				function()
					local env = min_env(20)
					env.start(true, 52)
					env.model.answer_after = 100
					env.send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "0", RATE = "5000" })
					env.clock.advance(6000)
					local n = #env.model.wants
					assert.same({ light_on = true, level = 20 }, env.model.wants[n - 2], "the last lit step: 1 %, fan level 20")
					assert.same({ light_on = false }, env.model.wants[n - 1], "then off")
					assert.same({ light_on = false, level = 52 }, env.model.wants[n], "then fan level 52 back, dark (TO4)")
					for i = 1, n - 2 do
						assert.is_true(env.model.wants[i].level >= 20, "visible to the end")
					end
					assert.equal('{"lightBrightness":52}', env.model.requests[#env.model.requests])
					assert.same({ changing(41, 0, 5000), changed(0) }, env.dev.sent)
					assert.same({ light_on = false, level = 52 }, env.model:confirmed())
				end)

			it("a level set outside Control4 below Min On shows as 1 %, on, and nothing is written (MO-D5, OX1, OX5)",
				function()
					local env = min_env(20)
					env.start(false, 5)
					env.model.confirmed_state = { light_on = true, level = 5 } -- the remote's own on, at the kept level
					env.lt:settled({ light_on = true, level = 5 }, "outside")
					assert.same({ changed(1) }, env.dev.sent, "1 %, never 0 while on")
					assert.is_true(env.dev.is_on())
					assert.equal(1, env.lt:c4_level(env.model:confirmed()))
					env.clock.advance(10000)
					assert.same({}, env.model.wants, "never raised to Min On")
				end)

			it("a fade up from a fan level below Min On starts at 1 %, fan level 20 (TO10)", function()
				local env = min_env(20)
				env.start(true, 5)
				env.model.answer_after = 10
				env.send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "100", RATE = "20000" })
				assert.same({ changing(1, 100, 20000) }, env.dev.sent)
				env.clock.advance(50)
				assert.same({ 20 }, levels(env), "out of the dead zone at the first step")
				env.clock.advance(25000)
				for _, level in ipairs(levels(env)) do
					assert.is_true(level >= 20)
				end
				assert.same(changed(100), env.dev.sent[#env.dev.sent])
			end)

			it("keeps times over Control4's range whatever M is: a 3 s tap from off plans 3 s (RT1)", function()
				for _, M in ipairs({ 0, 20, 50, 80 }) do
					local env = min_env(M, { settings = { click_up = 3000 } })
					env.start(false, 100)
					env.model.answer_after = 100
					env.keypad.tap(0)
					assert.same({ changing(0, 100, 3000) }, env.dev.sent, "Min On " .. M)
					assert.equal(light.to_fan(13, M), env.model.wants[1].level, "the first level, lit")
					env.clock.advance(4000)
					assert.same(changed(100), env.dev.sent[#env.dev.sent], "Min On " .. M)
				end
			end)

			it("SYNCHRONIZE tells the mapped level (PL10); Set Level 1 % is Min On and 0 is off (PL6 to PL8)", function()
				local env = min_env(20)
				env.start(true, 52)
				env.send("SYNCHRONIZE")
				assert.same({ online(true), changed(41) }, env.dev.sent)
				env.clear()
				env.send("SET_LEVEL", { LEVEL = "1" })
				env.send("SET_LEVEL", { LEVEL = "0.4" })
				env.send("SET_LEVEL", { LEVEL = "0" })
				assert.same({ { light_on = true, level = 20 }, { light_on = true, level = 20 }, { light_on = false } },
					env.model.wants)
			end)

			it("c4_level: 0 off, nil unknown, the memory first, else mapped back; min_on is 0 until set", function()
				local plain = new_env()
				assert.equal(0, plain.lt:min_on())
				assert.equal(52, plain.lt:c4_level({ light_on = true, level = 52 }))
				local env = min_env(20)
				assert.equal(20, env.lt:min_on())
				assert.is_nil(env.lt:c4_level(nil))
				assert.is_nil(env.lt:c4_level({}))
				assert.is_nil(env.lt:c4_level({ light_on = true }))
				assert.equal(0, env.lt:c4_level({ light_on = false, level = 52 }))
				assert.equal(41, env.lt:c4_level({ light_on = true, level = 52 }))
				assert.equal(41, env.lt:c4_level({ light_on = true, level = 51.6 }))
				assert.equal(1, env.lt:c4_level({ light_on = true, level = 5 }))
				assert.equal(51, env.lt:c4_level({ light_on = true, level = 60 }))
				env.start(true, 52)
				env.send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "50", RATE = "0" })
				assert.equal(50, env.lt:c4_level({ light_on = true, level = 60 }), "fan level 60 was wanted for 50 %")
				assert.equal(41, env.lt:c4_level({ light_on = true, level = 52 }), "any other is mapped back")
			end)

			it("names the unit of every level in its debug lines (MO-D12)", function()
				local env = min_env(20)
				env.start(true, 52)
				env.model.answer_after = 10
				env.send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "4", RATE = "0" })
				env.clock.advance(100)
				env.send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "50", RATE = "2000" })
				env.clock.advance(3000)
				assert.same({
					"light SET_BRIGHTNESS_TARGET: target 4 % (fan level 22)",
					"light SET_BRIGHTNESS_TARGET: fade 4 % (fan level 22) to 50 % (fan level 60) over 2000 ms",
				}, debug_lines(env, "^light SET_BRIGHTNESS_TARGET: [tf]"))
				local summary = debug_lines(env, "^light fade ")
				assert.equal(1, #summary)
				assert.is_truthy(summary[1]:find("^light fade 4 %% → 50 %% %(fan level 60%) over 2%.0 s: %d+ steps"),
					summary[1])
				local plain = new_env()
				plain.start(true, 40)
				plain.send("SET_LEVEL", { LEVEL = "30" })
				assert.same({ "light SET_LEVEL: target 30 %" }, debug_lines(plain, ": target "))
			end)
		end)

		describe("changing it: set_min_on (MO-D9, MO-D10)", function()
			it("refuses what is no number, below 0, or 100 and over, keeping the M in use; rounds half up first", function()
				local env = new_env()
				env.start(true, 40)
				for _, case in ipairs({ { nil, "not a number" }, { "abc", "not a number" }, { "", "not a number" },
					{ "nan", "not a number" }, { "inf", "not a number" }, { 0 / 0, "not a number" },
					{ -math.huge, "not a number" }, { -1, "outside 0 to 99" }, { "-0.6", "outside 0 to 99" },
					{ 100, "outside 0 to 99" }, { "99.5", "outside 0 to 99" }, { 1e9, "outside 0 to 99" } }) do
					local ok, why = env.lt:set_min_on(case[1], "property")
					assert.is_false(ok, tostring(case[1]))
					assert.equal(case[2], why, tostring(case[1]))
					assert.equal(0, env.lt:min_on())
				end
				assert.same({}, env.dev.sent)
				assert.same({}, env.model.wants)
				assert.same({}, env.log.of("info"), "a refusal's warning is the coordinator's (BV1 to BV3)")
				assert.same({ true, 21 }, { env.lt:set_min_on(20.5, "property") }, "BV4")
				assert.equal(21, env.lt:min_on())
				assert.same({ true, 21 }, { env.lt:set_min_on("21.4", "property") })
				assert.same({ true, 0 }, { env.lt:set_min_on("-0.4", "property") })
				assert.same({ true, 99 }, { env.lt:set_min_on("99.4", "load") })
				assert.is_false((env.lt:set_min_on(100, "property")))
				assert.equal(99, env.lt:min_on(), "a refusal keeps the M in use")
			end)

			it("at load: taken, and nothing is sent to the fan or the proxy, nor logged; the first report uses it (CM7)",
				function()
					local env = new_env()
					env.start(true, 30)
					env.send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "40", RATE = "0" })
					env.model:answer()
					env.clear()
					assert.same({ true, 20 }, { env.lt:set_min_on("20", "load") })
					assert.equal(20, env.lt:min_on())
					env.clock.advance(10000)
					assert.same({}, env.dev.sent)
					assert.same({}, env.model.wants)
					assert.same({}, env.log.of("info"))
					env.lt:settled({ light_on = true, level = 40 }, "start")
					assert.same({ changed(26) }, env.dev.sent, "the memory went with the change: mapped back (RO4)")
				end)

			it("the value in use again changes nothing, and logs nothing (CM7)", function()
				local env = new_env()
				env.start(true, 40)
				env.lt:set_min_on(20, "property")
				env.clear()
				assert.same({ true, 20 }, { env.lt:set_min_on(20, "property") })
				assert.same({ true, 20 }, { env.lt:set_min_on("20.2", "property") })
				assert.same({}, env.dev.sent)
				assert.equal(1, #env.log.of("info"))
			end)

			it("with the light off: nothing is sent, the dark level stays, and one info line says what 1 % is (CM1, MO-D12)",
				function()
					local env = new_env()
					env.start(false, 50)
					assert.same({ true, 20 }, { env.lt:set_min_on(20, "property") })
					env.clock.advance(10000)
					assert.same({}, env.dev.sent)
					assert.same({}, env.model.wants)
					assert.same({ "Light Min On 20: Control4's 1 % is the fan's level 20" }, env.log.of("info"))
					env.send("SET_LEVEL", { LEVEL = "40" })
					assert.same({ { light_on = true, level = 52 } }, env.model.wants, "the next turn-on uses it")
				end)

			it("on at a level Control4 set: it stays, and the light moves once to its new fan level, nothing told (CM2)",
				function()
					local env = new_env()
					env.start(true, 30)
					env.model.answer_after = 100
					env.send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "40", RATE = "0" })
					env.clock.advance(200)
					env.clear()
					env.lt:set_min_on(20, "property")
					assert.same({ { light_on = true, level = 52 } }, env.model.wants)
					assert.same({ false }, env.model.want_opts, "an ordinary want: no fade step")
					env.clock.advance(1000)
					assert.same({ '{"lightBrightness":52}' }, env.model.requests)
					assert.same({}, env.dev.sent, "no CHANGING and no CHANGED: Control4's 40 % stays")
					assert.is_false(env.lt:debug().fading)
					assert.equal(40, env.lt:c4_level(env.model:confirmed()))
					-- Back to 0 (CM5): the same, the other way.
					env.lt:set_min_on(0, "property")
					env.clock.advance(1000)
					assert.same({ 52, 40 }, levels(env))
					assert.same({}, env.dev.sent)
					assert.same({ "Light Min On 20: Control4's 1 % is the fan's level 20", "Light Min On 0: levels are the fan's" },
						env.log.of("info"))
				end)

			it("on at a level set outside: the fan is not touched, and the proxy hears the new level once (CM3, CM4)",
				function()
					local env = new_env()
					env.start(true, 40) -- found by the first contact: no level of Control4's
					env.lt:set_min_on(20, "property")
					assert.same({ changed(26) }, env.dev.sent)
					env.lt:set_min_on(30, "property")
					assert.same({ changed(26), changed(15) }, env.dev.sent)
					env.lt:set_min_on(50, "property")
					assert.same({ changed(26), changed(15), changed(1) }, env.dev.sent, "raised above it: 1 %")
					env.lt:set_min_on(1, "property")
					assert.same({ changed(26), changed(15), changed(1), changed(40) }, env.dev.sent, "1 is no remap")
					env.clock.advance(10000)
					assert.same({}, env.model.wants)
					assert.same("Light Min On 1: levels are the fan's", env.log.of("info")[4])
					local top = new_env()
					top.start(true, 100)
					top.lt:set_min_on(20, "property")
					assert.same({}, top.dev.sent, "100 % is fan level 100 at any Min On: nothing new to tell (R1)")
				end)

			it("during a fade: the fade keeps the M it started with, and CM2 applies once when it ends (CM6)", function()
				local env = new_env()
				env.start(true, 40)
				env.model.answer_after = 100
				env.send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "80", RATE = "3000" })
				env.clock.advance(1000)
				local before = #env.model.wants
				env.lt:set_min_on(20, "property")
				assert.equal(before, #env.model.wants, "nothing at once")
				env.clock.advance(1990)
				local wanted = levels(env)
				for i = 2, #wanted do
					assert.equal(wanted[i - 1] + 1, wanted[i], "still Min On 0's line, never a jump half way")
				end
				env.clock.advance(1000)
				assert.same({ changing(40, 80, 3000), changed(80) }, env.dev.sent, "the fade's own end: 80 %")
				local n = #env.model.wants
				assert.same({ light_on = true, level = 80 }, env.model.wants[n - 1])
				assert.same({ light_on = true, level = 84 }, env.model.wants[n], "then once to 80 % at Min On 20")
				assert.is_false(env.model.want_opts[n])
				env.clock.advance(5000)
				assert.equal(n, #env.model.wants)
				assert.same({ changing(40, 80, 3000), changed(80) }, env.dev.sent, "no second CHANGED")
				assert.same({ light_on = true, level = 84 }, env.model:confirmed())
			end)

			it("a fade stopped between its steps: the proxy hears the stopped level at the new M, once (CM6, CM3, TO9)",
				function()
					local env = new_env()
					env.start(true, 40)
					env.model.answer_after = nil
					env.send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "100", RATE = "3000" })
					env.clock.advance(150) -- 41 on the wire, 43 waiting
					env.lt:set_min_on(20, "property")
					env.dev.on_ramp_stop(0)
					env.model:answer()
					assert.same({ changing(40, 100, 3000), changed(27) }, env.dev.sent, "fan level 41 is 27 % at Min On 20")
					env.clock.advance(5000)
					assert.same({ 41, 42, 43 }, levels(env), "nothing is moved: no level of Control4's was reached")
				end)

			for _, idle_first in ipairs({ false, true }) do
				it("a change while a target is on the wire waits for its answer, then moves once"
					.. (idle_first and " (idle() first)" or ""), function()
					local env = new_env()
					env.start(true, 30)
					env.model.idle_first = idle_first
					env.send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "40", RATE = "0" })
					env.lt:set_min_on(20, "property")
					assert.same({ '{"lightBrightness":40}' }, env.model.requests, "nothing yet")
					env.model:answer()
					assert.same({ changing(30, 40, 0), changed(40) }, env.dev.sent)
					assert.same({ '{"lightBrightness":40}', '{"lightBrightness":52}' }, env.model.requests)
					env.model:answer()
					assert.same({ changing(30, 40, 0), changed(40) }, env.dev.sent, "Control4's 40 % stays")
					env.lt:settled({ light_on = true, level = 40 }, "outside")
					assert.same(changed(26), env.dev.sent[#env.dev.sent], "the level it left is the fan's own again")
				end)
			end

			it("several changes in a row: one request on the wire, then the newest (CM8)", function()
				local env = new_env()
				env.start(true, 30)
				env.send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "40", RATE = "0" })
				env.model:answer()
				env.clear()
				env.lt:set_min_on(10, "property")
				env.lt:set_min_on(20, "property")
				env.lt:set_min_on(30, "property")
				assert.same({ '{"lightBrightness":45}' }, env.model.requests)
				env.model:answer()
				assert.same({ '{"lightBrightness":45}', '{"lightBrightness":58}' }, env.model.requests)
				env.model:answer()
				assert.same({}, env.dev.sent)
				assert.equal(40, env.lt:c4_level(env.model:confirmed()))
				assert.equal(3, #env.log.of("info"))
			end)

			for _, phase in ipairs({ "offline", "rebooting", "foreign" }) do
				it("while the fan is " .. phase .. ": kept, nothing sent; the contact back reports with it (CM9)", function()
					local env = new_env()
					env.start(true, 30)
					env.send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "40", RATE = "0" })
					env.model:answer()
					env.lt:phase(phase, {}, true)
					env.clear()
					assert.same({ true, 20 }, { env.lt:set_min_on(20, "property") })
					env.clock.advance(10000)
					assert.same({}, env.dev.sent)
					assert.same({}, env.model.wants)
					env.lt:phase("online", {}, true)
					env.lt:settled({ light_on = true, level = 40 }, "online")
					assert.same(changed(26), env.dev.sent[#env.dev.sent], "fan level 40 at Min On 20; the light stays")
					assert.same({}, env.model.wants)
				end)
			end

			it("a change waiting for a fade that going offline ends sends nothing afterwards (CM6, CM9)", function()
				local env = new_env()
				env.start(true, 40)
				env.model.answer_after = 100
				env.send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "80", RATE = "3000" })
				env.clock.advance(1000)
				env.lt:set_min_on(20, "property")
				env.lt:phase("offline", {}, true)
				local wants = #env.model.wants
				env.clock.advance(10000)
				env.lt:phase("online", {}, true)
				env.lt:idle(env.model:confirmed())
				env.clock.advance(10000)
				assert.equal(wants, #env.model.wants, "nothing is moved when the fan is back")
			end)

			it("takes the value after stop() and sends nothing", function()
				local env = new_env()
				env.start(true, 40)
				env.lt:stop()
				assert.same({ true, 20 }, { env.lt:set_min_on(20, "property") })
				assert.same({}, env.dev.sent)
				assert.same({}, env.model.wants)
			end)

			it("a model that fails while the light moves is contained (MO-D9 never raises)", function()
				local env = new_env()
				env.start(true, 30)
				env.send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "40", RATE = "0" })
				env.model:answer()
				env.model.want = function() error("boom") end
				local ok, M
				assert.has_no.errors(function() ok, M = env.lt:set_min_on(20, "property") end)
				assert.is_true(ok)
				assert.equal(20, M)
				assert.is_truthy(env.log.of("error")[1]:find("boom", 1, true))
			end)
		end)
	end)
end)

-- The review fixes with the real driver: the real model, transport and common/device.lua on the fake
-- runtime, and a simulated fan (a state, a latency, an optional failure or a change of its own).
describe("fan.light with the real driver (review fixes of #141)", function()
	local FAN = "10.0.2.151"
	local real_sink

	before_each(function()
		real_sink = real_log.sink
		real_log.sink = function() end
	end)

	after_each(function()
		real_log.sink = real_sink
	end)

	-- A driver on a fan whose light is `on` at `level`, answering every request after `latency` ms.
	local function new_sim(on, level, latency)
		local w = { state = { lightOn = on, lightBrightness = level }, latency = latency or 150, seen = {}, due = {},
			sends = {}, heard = 0, told = {}, t = 0 }
		local env, c4 = fake.load_driver("modernforms_fan", { ["Fan Address"] = FAN })
		w.env, w.c4 = env, c4
		env.OnDriverInit("DIT_STARTUP")
		env.OnDriverLateInit("DIT_STARTUP")
		local function body()
			return mf.state({ fanOn = true, fanSpeed = 3, lightOn = w.state.lightOn,
				lightBrightness = w.state.lightBrightness })
		end
		c4.last_transfer():respond(200, mf.INFO)
		c4.advance(300)
		c4.last_transfer():respond(200, body())
		c4.advance(300)
		w.start_ms, w.heard = c4.now_ms, #c4.proxy_messages(5002)

		-- Runs `ms` of simulated time, answering each request after the latency.
		function w.step(ms)
			for _ = 1, math.floor(ms / 5) do
				c4.advance(5)
				local t = c4.last_transfer()
				if t and not w.seen[t] then
					w.seen[t] = true
					w.sends[#w.sends + 1] = { at = c4.now_ms - w.start_ms, body = t.data or "", transfer = t }
					w.due[#w.due + 1] = { t = t, at = c4.now_ms + w.latency }
				end
				for i = #w.due, 1, -1 do
					local d = w.due[i]
					if c4.now_ms >= d.at then
						table.remove(w.due, i)
						local data = d.t.data or ""
						if w.fail then
							d.t:fail(-1, "timeout")
						else
							local lo, lb = data:match('"lightOn":(%a+)'), data:match('"lightBrightness":(%d+)')
							if lo then w.state.lightOn = lo == "true" end
							if lb then w.state.lightBrightness = tonumber(lb) end
							d.t:respond(200, data:find("queryStaticShadowData", 1, true) and mf.INFO or body())
						end
					end
				end
				local msgs = c4.proxy_messages(5002)
				for i = w.heard + 1, #msgs do
					w.told[#w.told + 1] = { msgs[i][1], msgs[i][2] }
				end
				w.heard = #msgs
			end
		end

		function w.idle() -- until the request on the wire is answered
			local n = 0
			while #w.due > 0 and n < 400 do
				w.step(5)
				n = n + 1
			end
		end

		function w.command(name, params)
			env.ReceivedFromProxy(5002, name, params or {})
		end

		function w.button(id, action)
			env.ReceivedFromProxy(5002, "BUTTON_ACTION", { BUTTON_ID = id, ACTION = action })
		end

		function w.tap(id)
			w.button(id, 1)
			w.step(30)
			w.button(id, 0)
			w.button(id, 2)
		end

		-- The notifications of one name, in order, as their CURRENT levels.
		function w.heard_of(name)
			local out = {}
			for _, n in ipairs(w.told) do
				if n[1] == name then
					out[#out + 1] = n[2].LIGHT_BRIGHTNESS_CURRENT
				end
			end
			return out
		end

		-- The requests that set the light, from `since` ms on, as their bodies.
		function w.light_sends(since)
			local out = {}
			for _, s in ipairs(w.sends) do
				if s.at >= (since or 0) and s.body:find('"light', 1, true) and not s.body:find("query", 1, true) then
					out[#out + 1] = s.body
				end
			end
			return out
		end

		return w
	end

	-- Review fix 1 (the reviewer's H2): a hold's step fails, the owner lets go, the fan comes back ~10 s
	-- later: the light must not jump to 100.
	it("a hold whose step failed does not jump the light to 100 after the recovery", function()
		local w = new_sim(true, 20)
		w.button(0, 1) -- a hold: top button
		w.step(1300)
		assert.is_true(w.state.lightBrightness > 20 and w.state.lightBrightness < 100)
		w.fail = true
		w.step(300)
		w.fail = false
		w.step(1000)
		w.button(0, 0) -- let go long before the fan answers again
		w.step(15000)
		for _, body in ipairs(w.light_sends()) do
			assert.is_nil(body:find('"lightBrightness":100', 1, true), body)
		end
		assert.is_true(w.state.lightBrightness < 100)
		local opened, closed = w.heard_of("LIGHT_BRIGHTNESS_CHANGING"), w.heard_of("LIGHT_BRIGHTNESS_CHANGED")
		assert.equal(#opened, #closed, "every CHANGING is closed")
	end)

	it("a timed change that failed is still replayed once after the recovery", function()
		local w = new_sim(true, 20)
		w.command("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 90, RATE = 4000 })
		w.step(1000)
		w.fail = true
		w.step(400)
		w.fail = false
		w.step(40000)
		assert.equal(90, w.state.lightBrightness, "its target, once")
	end)

	-- Review fix 2 (s10): the address changes between two steps of a slow fade.
	it("an address change between the steps of a slow fade ends it: the new address gets no step", function()
		local w = new_sim(true, 20)
		w.command("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 60, RATE = 40000 })
		w.step(3000)
		w.idle()
		w.step(200) -- between two steps
		assert.equal(0, #w.due)
		local before = #w.sends
		w.env.Properties["Fan Address"] = "10.0.2.152"
		w.env.OnPropertyChanged("Fan Address")
		w.step(40000)
		for i = before + 1, #w.sends do
			assert.is_nil(w.sends[i].body:find('"light', 1, true), "sent to the new address: " .. w.sends[i].body)
		end
		local opened, closed = w.heard_of("LIGHT_BRIGHTNESS_CHANGING"), w.heard_of("LIGHT_BRIGHTNESS_CHANGED")
		assert.equal(#opened, #closed, "and the CHANGING was closed")
	end)

	-- Review fix 4 (s2/outG): the fade from off is stopped before the turn-on went out.
	it("a stop at any moment of the start of a fade from off leaves the light on at the level reached", function()
		for _, stop_at in ipairs({ 0, 50, 100, 200, 300, 400, 500, 600, 800 }) do
			local w = new_sim(false, 1)
			w.command("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 3000 })
			w.step(stop_at)
			w.tap(0) -- any press stops
			w.step(5000)
			local first = math.floor(100 * light.FIRST_STEP_MS / 3000 + 0.5)
			assert.is_true(w.state.lightOn, "on, stopped at " .. stop_at .. " ms")
			assert.is_true(w.state.lightBrightness >= first, "at the level reached, stopped at " .. stop_at)
			assert.is_true(w.state.lightBrightness < 100)
			local opened, closed = w.heard_of("LIGHT_BRIGHTNESS_CHANGING"), w.heard_of("LIGHT_BRIGHTNESS_CHANGED")
			assert.equal(#opened, #closed)
			assert.equal(w.state.lightBrightness, closed[#closed], "told what the fan has, stopped at " .. stop_at)
		end
	end)

	-- Review fix 3: a fade to off stopped at any moment never leaves the fan off at a level of ~1.
	it("a fade to off stopped at any moment leaves the fan on, or off at the level it had", function()
		for stop_at = 0, 3600, 100 do
			local w = new_sim(true, 80)
			w.command("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 0, RATE = 3000 })
			w.step(stop_at)
			w.tap(1)
			w.step(5000)
			if not w.state.lightOn then
				assert.equal(80, w.state.lightBrightness, "off, stopped at " .. stop_at .. " ms: its level is kept")
			end
			local opened, closed = w.heard_of("LIGHT_BRIGHTNESS_CHANGING"), w.heard_of("LIGHT_BRIGHTNESS_CHANGED")
			assert.equal(#opened, #closed, "closed, stopped at " .. stop_at)
		end
	end)

	-- Review fix 6: the write-back after a fade to off is the dark level alone.
	it("a fade to off sends one off, then the level written back while dark: no second off", function()
		local w = new_sim(true, 80)
		w.command("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 0, RATE = 3000 })
		w.step(6000)
		local offs = 0
		for _, body in ipairs(w.light_sends()) do
			if body:find('"lightOn":false', 1, true) then
				offs = offs + 1
			end
		end
		local sent = w.light_sends()
		assert.equal(1, offs, "one off")
		assert.equal('{"lightBrightness":80}', sent[#sent], "then the starting level, while dark")
		assert.is_false(w.state.lightOn)
		assert.equal(80, w.state.lightBrightness)
	end)
end)
