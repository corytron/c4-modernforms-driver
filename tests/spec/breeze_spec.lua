-- fan.breeze on fakes: the Control4 face of the fan's Breeze (docs/breeze-design.md sections 1, 3, 4 and 5,
-- and section 11, BF-D4, BF-D5, BF-D9, BF-D10 of 1.3; docs/edge-cases-breeze.md BC9 to BC12, BC15, BC18 to
-- BC22, BC28 to BC31; docs/edge-cases-breeze-fan.md BF28, BF30, BF35, BF43). The model is a hand-made table of
-- the shape section 3 gives (want, shown, confirmed, info, phase, identity); every Director call (SetVariable,
-- FireEventByID, the store, Last Action, SendToDevice, AddDevice, Bind, the item's name, the 1.2-switch test)
-- is a recording fake. The motor's three states come from the real fan/mode.lua (breeze-design 11.1).
--
-- Placeholders only: the fan MF_00005E005301 (MAC 00:00:5E:00:53:01) at 10.0.2.151, named Aviator 5;
-- companion devices 2001 and 2002.

local breeze = require("fan.breeze")

local PIN = { client_id = "MF_00005E005301", mac = "00005E005301", address = "10.0.2.151", generation = "3" }
local OPTION_NAMES = {
	"preset", "set_variable", "fire", "persist", "recall", "result", "companions", "send", "add_device", "bind",
	"item_name", "old_companion",
}
local MODEL_METHODS = { "want", "shown", "confirmed", "info", "phase", "identity" }

local function copy(t)
	local out = {}
	for k, v in pairs(t) do
		out[k] = v
	end
	return out
end

local function raises()
	error("boom")
end

-- A logger that keeps what it is told: { level, text } in order.
local function fake_log()
	local log = { lines = {} }
	local function add(level)
		return function(fmt, ...)
			local ok, text = pcall(string.format, fmt, ...)
			log.lines[#log.lines + 1] = { level = level, text = ok and text or tostring(fmt) }
		end
	end
	log.always, log.warn, log.info, log.debug, log.error = add("always"), add("warn"), add("info"), add("debug"),
		add("error")
	function log.has(level, needle)
		for _, line in ipairs(log.lines) do
			if line.level == level and line.text:find(needle, 1, true) then
				return true
			end
		end
		return false
	end
	return log
end

-- A breeze face on fakes. o.opts replaces options, o.without removes them. The fan runs at speed 3 with
-- Breeze off, online, with Breeze hardware; nothing is bound and nothing is stored.
local function rig(o)
	o = o or {}
	local r = {
		phase = "online",
		info = { has_wind = true, has_light = true },
		pin = copy(PIN),
		conf = { fan_on = true, speed = 3, direction = "forward", wind = false, wind_speed = 1 },
		shown = nil, -- the shown state; the confirmed one while nil
		refuse = nil, -- a reason: model:want refuses with it
		preset = 3,
		item = "Aviator 5",
		bound = {},
		old = {}, -- device ids old_companion() calls a 1.2 switch
		old_asked = {},
		bind_ok = true,
		store = {},
		wants = {}, variables = {}, fired = {}, persisted = {}, results = {}, sent = {}, adds = {}, binds = {},
		log = fake_log(),
	}
	r.model = {
		want = function(_, fields)
			r.wants[#r.wants + 1] = fields
			if r.refuse then
				return false, r.refuse
			end
			return true
		end,
		shown = function() return copy(r.shown or r.conf) end,
		confirmed = function() return copy(r.conf) end,
		info = function() return r.info and copy(r.info) or nil end,
		phase = function() return r.phase, {} end,
		identity = function() return r.pin and copy(r.pin) or nil end,
	}
	local options = {
		model = r.model,
		preset = function() return r.preset end,
		set_variable = function(value) r.variables[#r.variables + 1] = value end,
		fire = function(id) r.fired[#r.fired + 1] = id end,
		persist = function(key, value)
			r.persisted[#r.persisted + 1] = { key = key, value = value }
			r.store[key] = value
		end,
		recall = function(key) return r.store[key] end,
		result = function(key, args) r.results[#r.results + 1] = { key = key, args = args } end,
		companions = function() return r.bound end,
		send = function(id, command, params) r.sent[#r.sent + 1] = { id = id, command = command, params = params } end,
		add_device = function(name, cb) r.adds[#r.adds + 1] = { name = name, cb = cb } end,
		bind = function(id)
			r.binds[#r.binds + 1] = id
			return r.bind_ok
		end,
		item_name = function() return r.item end,
		old_companion = function(id)
			r.old_asked[#r.old_asked + 1] = id
			return r.old[id] == true
		end,
		log = r.log,
	}
	for k, v in pairs(o.opts or {}) do
		options[k] = v
	end
	for _, name in ipairs(o.without or {}) do
		options[name] = nil
	end
	r.b = breeze.new(options)

	-- The model's settled(group, st, why) after the confirmed state took `changes`.
	function r.settle(group, changes, why)
		for k, v in pairs(changes or {}) do
			r.conf[k] = v
		end
		r.b:settled(group, copy(r.conf), why or "outside")
	end
	-- The device's phase moves (the model's phase() says the same) and the face hears it.
	function r.go(phase)
		r.phase = phase
		r.b:phase(phase)
	end
	-- The last state message, and how many were sent.
	function r.last_state()
		return r.sent[#r.sent]
	end
	function r.keys()
		local out = {}
		for i, entry in ipairs(r.results) do
			out[i] = entry.key
		end
		return out
	end
	-- Starts blowing once (the first contact after a restart with nothing stored), then forgets what that did.
	function r.blowing()
		r.settle("breeze", { wind = true }, "start")
		r.clear()
	end
	function r.clear()
		r.wants, r.variables, r.fired, r.persisted, r.results, r.sent = {}, {}, {}, {}, {}, {}
	end
	-- The shown state in one of the motor's states (BF-D1), wanted over confirmed.
	function r.breeze_mode(strength)
		r.shown = { fan_on = true, speed = 3, direction = "forward", wind = true, wind_speed = strength }
	end
	function r.fan_mode(speed)
		r.shown = { fan_on = true, speed = speed or 3, direction = "forward", wind = false, wind_speed = 2 }
	end
	function r.stopped_mode(wind)
		r.shown = { fan_on = false, speed = 3, direction = "forward", wind = wind, wind_speed = 2 }
	end
	return r
end

-- MF_BREEZE_STATE params as the fan sends them; STRENGTH only when given.
local function state(blows, available, has_breeze, strength)
	return { BLOWS = blows, AVAILABLE = available, HAS_BREEZE = has_breeze, FAN = "Aviator 5", STRENGTH = strength }
end

describe("fan.breeze", function()
	describe("the module", function()
		it("exports the ids the XML declares (BZ3)", function()
			assert.equal(4, breeze.EVENT_STARTED)
			assert.equal(5, breeze.EVENT_STOPPED)
			assert.equal("BOOL_BREEZE", breeze.CONDITION)
			assert.equal("mf_breeze", breeze.KEY)
			assert.same({ "Breeze_On", "Breeze_Off", "Toggle_Breeze", "Set_Breeze_Strength" }, breeze.COMMANDS)
			assert.equal("MF_BREEZE_STATE", breeze.STATE)
			assert.equal("MF_BREEZE_SET", breeze.SET)
			assert.equal("MF_BREEZE_TOGGLE", breeze.TOGGLE)
			assert.equal("MF_BREEZE_CYCLE", breeze.CYCLE)
			assert.equal("MF_BREEZE_HELLO", breeze.HELLO)
		end)

		it("calls no option and no model method when it is built (OnDriverInit)", function()
			local called, options, model = {}, {}, {}
			for _, name in ipairs(OPTION_NAMES) do
				options[name] = function() called[#called + 1] = name end
			end
			for _, name in ipairs(MODEL_METHODS) do
				model[name] = function() called[#called + 1] = "model:" .. name end
			end
			options.model = model
			options.log = fake_log()
			breeze.new(options)
			assert.same({}, called)
		end)

		it("builds without options and raises from nothing", function()
			local b = breeze.new(nil)
			local log = fake_log()
			b.log = log
			assert.has_no.errors(function()
				assert.is_true(b:command("Breeze_On", {}))
				b:settled("breeze", { wind = true, fan_on = true }, "start")
				b:shown({ wind = true })
				b:phase("online")
				b:companion("MF_BREEZE_HELLO", {})
				b:companion("MF_BREEZE_CYCLE", { STEP = "1" })
				b:companion("MF_BREEZE_SET", { ON = "1", STRENGTH = "2" })
				b:binding_changed(true)
				b:late_init()
				b:add_switch()
				b:toggle()
				b:blows_shown()
				b:test_condition("BOOL_BREEZE", {})
				b:stop()
			end)
		end)
	end)

	describe("Breeze on (BF-D5)", function()
		it("Breeze On in fan mode wants wind alone, which switches the mode, and writes nothing", function()
			local r = rig()
			assert.is_true(r.b:command("Breeze_On", {}))
			assert.same({ { wind = true } }, r.wants)
			assert.same({}, r.results)
		end)

		it("Breeze On in Breeze mode wants wind again and nothing else", function()
			local r = rig()
			r.breeze_mode(2)
			r.b:command("Breeze_On", {})
			assert.same({ { wind = true } }, r.wants)
		end)

		it("Breeze On from stopped adds the fan on at its confirmed speed, which the fan keeps for fan mode", function()
			local r = rig()
			r.conf.fan_on, r.conf.speed = false, 2
			r.preset = 5
			r.b:command("Breeze_On", {})
			assert.same({ { wind = true, fan_on = true, speed = 2 } }, r.wants)
			assert.same({}, r.results)
		end)

		it("Breeze On from stopped with a stored wind starts the same way", function()
			local r = rig()
			r.conf.fan_on, r.conf.wind, r.conf.speed = false, true, 4
			r.b:command("Breeze_On", {})
			assert.same({ { wind = true, fan_on = true, speed = 4 } }, r.wants)
		end)

		it("Breeze On from stopped uses the preset while the confirmed speed is unknown or out of range", function()
			for _, speed in ipairs({ false, 0, 7, 2.5, "x" }) do
				local r = rig()
				r.conf.fan_on = false
				r.conf.speed = speed or nil
				r.preset = 5
				r.b:command("Breeze_On", {})
				assert.same({ { wind = true, fan_on = true, speed = 5 } }, r.wants, tostring(speed))
			end
			local r = rig()
			r.shown = { fan_on = false, wind = false }
			r.model.confirmed = function() return nil end -- nothing read yet in this run
			r.preset = 4
			r.b:command("Breeze_On", {})
			assert.same({ { wind = true, fan_on = true, speed = 4 } }, r.wants)
			local q = rig()
			q.shown = { fan_on = false, wind = false }
			q.model.confirmed = raises
			q.b:command("Breeze_On", {})
			assert.same({ { wind = true, fan_on = true, speed = 3 } }, q.wants)
		end)

		it("Breeze On decides stopped from the shown state, and takes the speed from the confirmed one (V10)", function()
			local r = rig()
			r.conf.fan_on = false
			r.shown = { fan_on = true, speed = 2, wind = false } -- an ON in flight
			r.b:command("Breeze_On", {})
			assert.same({ { wind = true } }, r.wants)
			r.conf.fan_on = true
			r.shown = { fan_on = false, speed = 2, wind = false } -- an OFF wanted
			r.b:command("Breeze_On", {})
			assert.same({ wind = true, fan_on = true, speed = 3 }, r.wants[2])
		end)

		it("Breeze On with the fan's on/off unknown wants wind alone (only a shown stop adds the fan)", function()
			local r = rig()
			r.shown = {}
			r.b:command("Breeze_On", {})
			r.shown = { wind = true, wind_speed = 2 }
			r.b:command("Breeze_On", {})
			assert.same({ { wind = true }, { wind = true } }, r.wants)
		end)

		it("Breeze On from stopped uses speed 3 when neither the confirmed speed nor the preset can be read", function()
			local cases = {
				{ opts = { preset = raises } }, { opts = { preset = function() return 0 end } },
				{ opts = { preset = function() return "x" end } }, { without = { "preset" } },
			}
			for _, case in ipairs(cases) do
				local r = rig(case)
				r.conf.fan_on, r.conf.speed = false, nil
				r.b:command("Breeze_On", {})
				assert.same({ { wind = true, fan_on = true, speed = 3 } }, r.wants)
				assert.is_true(r.log.has("warn", "preset speed"))
			end
		end)

		it("Set Breeze Strength wants wind_speed 1 to 3 from a string or a number, the strength only", function()
			local r = rig()
			r.b:command("Set_Breeze_Strength", { STRENGTH = "2" })
			r.b:command("Set_Breeze_Strength", { STRENGTH = 3 })
			r.b:command("Set_Breeze_Strength", { STRENGTH = " 1 " })
			r.conf.fan_on = false
			r.b:command("Set_Breeze_Strength", { STRENGTH = "2" })
			assert.same({ { wind_speed = 2 }, { wind_speed = 3 }, { wind_speed = 1 }, { wind_speed = 2 } }, r.wants)
			assert.same({}, r.results)
		end)

		it("Set Breeze Strength refuses anything but 1 to 3 with L34, naming what was given", function()
			for _, given in ipairs({ "0", "4", "5", "2.5", "x", "", -1 }) do
				local r = rig()
				assert.is_true(r.b:command("Set_Breeze_Strength", { STRENGTH = given }))
				assert.same({}, r.wants)
				assert.same({ { key = "breeze_strength", args = { strength = given } } }, r.results)
			end
			local r = rig()
			r.b:command("Set_Breeze_Strength", {})
			assert.same({ { key = "breeze_strength", args = {} } }, r.results)
		end)

		it("answers false for any other command and asks the model nothing", function()
			local r = rig()
			for _, name in ipairs({ "ON", "BREEZE_ON", "breeze_on", "Dev Request", "LUA_ACTION", "MF_BREEZE_CYCLE" }) do
				assert.is_false(r.b:command(name, {}))
			end
			assert.is_false(r.b:command(nil, nil))
			assert.same({}, r.wants)
			assert.same({}, r.results)
		end)

		it("takes missing parameters as empty", function()
			local r = rig()
			assert.is_true(r.b:command("Breeze_On"))
			assert.is_true(r.b:command("Set_Breeze_Strength", "3"))
			assert.same({ { wind = true } }, r.wants)
			assert.equal("breeze_strength", r.results[1].key)
		end)
	end)

	describe("Breeze off (BF-D4)", function()
		it("in Breeze mode stops the motor and clears wind in one want (the model sends the fan first)", function()
			local r = rig()
			r.breeze_mode(2)
			local ok = r.b:command("Breeze_Off", {})
			assert.is_true(ok)
			assert.same({ { fan_on = false, wind = false } }, r.wants)
			assert.same({}, r.results)
		end)

		it("stopped with a stored wind clears wind only", function()
			local r = rig()
			r.stopped_mode(true)
			r.b:command("Breeze_Off", {})
			assert.same({ { wind = false } }, r.wants)
		end)

		it("with a stored wind and the fan's on/off unknown clears wind only", function()
			local r = rig()
			r.shown = { wind = true, wind_speed = 2 }
			r.b:command("Breeze_Off", {})
			assert.same({ { wind = false } }, r.wants)
		end)

		it("in fan mode sends nothing and writes nothing: it never stops a fan in fan mode (logged)", function()
			local r = rig()
			r.fan_mode(4)
			local ok, why = r.b:off()
			assert.is_false(ok)
			assert.equal("nothing", why)
			r.b:command("Breeze_Off", {})
			assert.same({}, r.wants)
			assert.same({}, r.results)
			assert.is_true(r.log.has("info", "fan mode"))
		end)

		it("stopped with nothing stored, or with the state unknown, sends nothing", function()
			for _, shown in ipairs({ { fan_on = false, wind = false }, { fan_on = false }, {} }) do
				local r = rig()
				r.shown = shown
				r.b:command("Breeze_Off", {})
				assert.same({}, r.wants)
				assert.same({}, r.results)
			end
		end)

		it("reads the shown state: an off in flight leaves nothing more, a Breeze On in flight is ended", function()
			local r = rig()
			r.blowing() -- confirmed Breeze mode
			r.shown = { fan_on = false, speed = 3, wind = false } -- an off already wanted
			r.b:command("Breeze_Off", {})
			assert.same({}, r.wants)
			local q = rig() -- confirmed fan mode
			q.shown = { fan_on = true, speed = 3, wind = true } -- Breeze On wanted
			q.b:command("Breeze_Off", {})
			assert.same({ { fan_on = false, wind = false } }, q.wants)
		end)

		it("a fan without Breeze is asked as in 1.2, so the model's refusal reaches Last Action (BZ10)", function()
			local r = rig()
			r.info = { has_wind = false }
			r.conf.wind = nil
			r.refuse = "no_breeze"
			r.b:command("Breeze_Off", {})
			assert.same({ { wind = false } }, r.wants)
			assert.same({ "breeze_unavailable" }, r.keys())
		end)
	end)

	describe("Toggle Breeze and link 311 (BC11, BF28)", function()
		it("Breeze mode goes off: the motor stops and wind clears", function()
			local r = rig()
			r.breeze_mode(3)
			r.b:command("Toggle_Breeze", {})
			assert.is_true((r.b:toggle()))
			assert.same({ { fan_on = false, wind = false }, { fan_on = false, wind = false } }, r.wants)
		end)

		it("fan mode, stopped, or wind stored with the motor stopped all go on", function()
			local r = rig()
			r.fan_mode()
			r.b:command("Toggle_Breeze", {})
			r.stopped_mode(false)
			r.b:command("Toggle_Breeze", {})
			r.stopped_mode(true)
			r.b:toggle()
			assert.same({
				{ wind = true },
				{ wind = true, fan_on = true, speed = 3 },
				{ wind = true, fan_on = true, speed = 3 },
			}, r.wants)
		end)

		it("reads the shown state, so a burst counts from its target (BC12)", function()
			local r = rig()
			r.blowing() -- confirmed blowing
			r.shown = { fan_on = true, speed = 3, wind = false } -- an Off already wanted
			r.b:command("Toggle_Breeze", {})
			assert.same({ { wind = true } }, r.wants)
		end)

		it("a double tap ends where it started: Breeze mode, stopped, Breeze mode again", function()
			local r = rig()
			r.breeze_mode(2)
			r.b:toggle()
			r.stopped_mode(false)
			r.b:toggle()
			assert.same({ { fan_on = false, wind = false }, { wind = true, fan_on = true, speed = 3 } }, r.wants)
		end)
	end)

	describe("refusals as Last Action (section 5)", function()
		it("no Breeze is L33 for every command and the 311 press (BZ10, BC15)", function()
			local r = rig()
			r.info = { has_wind = false }
			r.conf.wind, r.conf.wind_speed = nil, nil
			r.refuse = "no_breeze"
			r.b:command("Breeze_On", {})
			r.b:command("Breeze_Off", {})
			r.b:command("Toggle_Breeze", {})
			r.b:command("Set_Breeze_Strength", { STRENGTH = "2" })
			local ok, why = r.b:toggle()
			assert.is_false(ok)
			assert.equal("no_breeze", why)
			assert.same({ "breeze_unavailable", "breeze_unavailable", "breeze_unavailable", "breeze_unavailable",
				"breeze_unavailable" }, r.keys())
			assert.same({}, r.results[1].args)
		end)

		it("the fan's missing wind keys read as no Breeze too", function()
			for _, why in ipairs({ "no wind", "no windSpeed" }) do
				local r = rig()
				r.refuse = why
				r.b:command("Breeze_On", {})
				assert.same({ "breeze_unavailable" }, r.keys())
			end
		end)

		it("the model's breeze_range is L34 with the strength given", function()
			local r = rig()
			r.refuse = "breeze_range"
			r.b:command("Set_Breeze_Strength", { STRENGTH = "2" })
			r.b:companion("MF_BREEZE_SET", { ON = "1", STRENGTH = "3" })
			assert.same({ { key = "breeze_strength", args = { strength = "2" } },
				{ key = "breeze_strength", args = { strength = 3 } } }, r.results)
		end)

		it("every other refusal is breeze_refused with the model's reason", function()
			for _, why in ipairs({ "unset", "invalid address", "foreign", "gen4", "notfan", "rebooting", "range",
				"no fanOn" }) do
				local r = rig()
				r.breeze_mode(2)
				r.refuse = why
				r.b:command("Breeze_On", {})
				r.b:companion("MF_BREEZE_SET", { ON = "0" })
				assert.same({ { key = "breeze_refused", args = { why = why } },
					{ key = "breeze_refused", args = { why = why } } }, r.results)
			end
		end)

		it("a model that raises or is missing is refused with why error, and nothing raises", function()
			local r = rig()
			r.model.want = raises
			assert.has_no.errors(function() r.b:command("Breeze_On", {}) end)
			assert.same({ { key = "breeze_refused", args = { why = "error" } } }, r.results)
			assert.is_true(r.log.has("error", "could not reach the model"))
			local bare = rig({ opts = { model = false } })
			assert.has_no.errors(function() bare.b:command("Breeze_Off", {}) end)
			assert.same({ "breeze_refused" }, bare.keys())
		end)

		it("a result that raises is logged, never raised", function()
			local r = rig({ opts = { result = raises } })
			r.refuse = "no_breeze"
			assert.has_no.errors(function() r.b:command("Breeze_On", {}) end)
			assert.is_true(r.log.has("error", "Last Action breeze_unavailable"))
		end)

		it("toggle answers true when the model takes it", function()
			local r = rig()
			assert.is_true((r.b:toggle()))
			assert.same({}, r.results)
		end)
	end)

	describe("Breeze blows (BZ1)", function()
		it("wind and the fan on: the variable 1, mf_breeze true, Breeze Started once, the companions", function()
			local r = rig()
			r.bound = { 2001 }
			r.settle("fan", {}, "start") -- the first contact: not blowing, nothing stored, so no change
			assert.same({}, r.fired)
			assert.same({}, r.variables)
			r.clear()
			r.settle("breeze", { wind = true }, "command")
			assert.same({ "1" }, r.variables)
			assert.same({ { key = "mf_breeze", value = true } }, r.persisted)
			assert.same({ 4 }, r.fired)
			assert.same({ { id = 2001, command = "MF_BREEZE_STATE", params = state("1", "1", "1", "1") } }, r.sent)
			assert.is_true(r.log.has("always", "Breeze started (command)"))
		end)

		it("wind with the fan off does not blow; the fan stopping under wind is Breeze Stopped once", function()
			local r = rig()
			r.blowing()
			r.settle("fan", { fan_on = false }, "outside")
			assert.same({ "0" }, r.variables)
			assert.same({ { key = "mf_breeze", value = false } }, r.persisted)
			assert.same({ 5 }, r.fired)
			r.settle("breeze", { wind = true, wind_speed = 3 }, "outside")
			assert.same({ 5 }, r.fired)
			assert.same({ "0" }, r.variables)
		end)

		it("the fan starting while wind is set starts Breeze (BZ5 c)", function()
			local r = rig()
			r.settle("fan", { fan_on = false, wind = true }, "start")
			assert.same({}, r.fired)
			r.settle("fan", { fan_on = true }, "outside")
			assert.same({ 4 }, r.fired)
			assert.same({ "1" }, r.variables)
		end)

		it("the fan on without wind does not blow", function()
			local r = rig()
			r.settle("breeze", { wind = false, fan_on = true }, "start")
			r.settle("fan", { speed = 5 }, "outside")
			assert.same({}, r.fired)
			assert.same({}, r.variables)
		end)

		it("fires once per change, however many reports repeat it; a strength is a message, not an event", function()
			local r = rig()
			r.bound = { 2001 }
			r.settle("breeze", { wind = true }, "start")
			r.settle("fan", { speed = 4 }, "outside")
			r.settle("breeze", { wind_speed = 2 }, "outside")
			r.settle("breeze", {}, "command")
			assert.same({ 4 }, r.fired)
			assert.same({ "1" }, r.variables)
			assert.equal(1, #r.persisted)
			assert.equal(2, #r.sent) -- the start, then strength 2
			r.settle("breeze", { wind = false }, "command")
			r.settle("breeze", { wind_speed = 3 }, "outside")
			assert.same({ 4, 5 }, r.fired)
			assert.same({ "1", "0" }, r.variables)
			assert.equal(4, #r.sent)
		end)

		it("hears only the fan and breeze groups", function()
			local r = rig()
			r.conf.wind = true
			r.b:settled("light", copy(r.conf), "outside")
			r.b:settled("direction", copy(r.conf), "outside")
			assert.same({}, r.fired)
			assert.same({}, r.variables)
			r.b:settled("breeze", copy(r.conf), "outside")
			assert.same({ 4 }, r.fired)
		end)

		it("reads the confirmed state when settled brings none, and does nothing when there is none", function()
			local r = rig()
			r.conf.wind = true
			r.b:settled("breeze", nil, "outside")
			assert.same({ 4 }, r.fired)
			local q = rig()
			q.model.confirmed = function() return nil end
			q.b:settled("breeze", nil, "outside")
			assert.same({}, q.fired)
			assert.same({}, q.variables)
		end)

		it("Director's failures are logged and the rest still happens", function()
			local r = rig({ opts = { set_variable = raises, persist = raises } })
			r.bound = { 2001 }
			r.settle("breeze", { wind = true }, "command")
			assert.same({ 4 }, r.fired)
			assert.equal(1, #r.sent)
			assert.is_true(r.log.has("error", "variable could not be set"))
			assert.is_true(r.log.has("error", "mf_breeze could not be saved"))
			local q = rig({ opts = { fire = raises } })
			assert.has_no.errors(function() q.settle("breeze", { wind = true }, "command") end)
			assert.is_true(q.log.has("error", "event 4 could not be fired"))
		end)

		it("another fan without Breeze hardware stops Breeze once (BC18)", function()
			local r = rig()
			r.blowing()
			r.info = { has_wind = false }
			r.conf = { fan_on = true, speed = 3, direction = "forward" } -- no wind key
			r.b:settled("fan", copy(r.conf), "online")
			assert.same({ 5 }, r.fired)
			assert.same({ "0" }, r.variables)
		end)
	end)

	describe("a restart (BC22)", function()
		it("fires nothing when the first report equals mf_breeze", function()
			for _, stored in ipairs({ true, "1", 1 }) do
				local r = rig()
				r.store.mf_breeze = stored
				r.settle("breeze", { wind = true }, "start")
				assert.same({}, r.fired)
				assert.same({}, r.variables)
				assert.same({}, r.persisted)
			end
			local q = rig()
			q.store.mf_breeze = false
			q.settle("fan", {}, "start")
			assert.same({}, q.fired)
			assert.same({}, q.variables)
		end)

		it("fires once when the first report differs from mf_breeze", function()
			local r = rig()
			r.store.mf_breeze = true
			r.settle("fan", {}, "start") -- stopped while the driver was away
			assert.same({ 5 }, r.fired)
			assert.same({ "0" }, r.variables)
			assert.same({ { key = "mf_breeze", value = false } }, r.persisted)
			local q = rig()
			q.settle("breeze", { wind = true }, "start") -- nothing stored: off
			assert.same({ 4 }, q.fired)
			assert.same({ "1" }, q.variables)
		end)

		it("an unreadable mf_breeze counts as off", function()
			local r = rig({ opts = { recall = raises } })
			r.settle("breeze", { wind = true }, "start")
			assert.same({ 4 }, r.fired)
			assert.is_true(r.log.has("warn", "mf_breeze could not be read"))
		end)

		it("compares with mf_breeze only once: later reports compare with the fan", function()
			local r = rig()
			r.store.mf_breeze = true
			r.settle("breeze", { wind = true }, "start")
			r.store.mf_breeze = false -- whatever is stored later does not matter
			r.settle("fan", { speed = 2 }, "outside")
			assert.same({}, r.fired)
		end)

		it("before the first report the companions and the condition carry mf_breeze", function()
			local r = rig()
			r.store.mf_breeze = true
			r.bound = { 2001 }
			r.phase = "waiting"
			r.b:late_init()
			assert.same({ BLOWS = "1", AVAILABLE = "1", HAS_BREEZE = "1", FAN = "Aviator 5" }, r.last_state().params)
			assert.is_true(r.b:test_condition("BOOL_BREEZE", { VALUE = "True", LOGIC = "EQUAL" }))
			assert.same({}, r.fired)
			assert.same({}, r.variables)
		end)
	end)

	describe("offline and back (BC20, BC21)", function()
		it("offline keeps the last value: no event, no variable, the condition still true", function()
			local r = rig()
			r.bound = { 2001 }
			r.blowing()
			r.go("offline")
			assert.same({}, r.fired)
			assert.same({}, r.variables)
			assert.same(state("1", "0", "1", "1"), r.last_state().params, "the strength stays known offline")
			assert.is_true(r.b:test_condition("BOOL_BREEZE", {}))
		end)

		it("back online, a change made meanwhile is reported once with its event", function()
			local r = rig()
			r.bound = { 2001 }
			r.blowing()
			r.go("offline")
			r.clear()
			r.phase = "online"
			r.settle("breeze", { wind = false }, "online")
			r.b:phase("online")
			assert.same({ 5 }, r.fired)
			assert.same({ "0" }, r.variables)
			assert.equal(1, #r.sent)
			assert.same(state("0", "1", "1", "1"), r.last_state().params)
		end)
	end)

	describe("the companions (section 4)", function()
		it("MF_BREEZE_STATE goes to every bound companion, each with its own table", function()
			local r = rig()
			r.bound = { 2001, "2002", 2001, "x", 0, 2.5 }
			r.b:late_init()
			assert.equal(2, #r.sent)
			assert.same({ 2001, 2002 }, { r.sent[1].id, r.sent[2].id })
			for _, entry in ipairs(r.sent) do
				assert.equal("MF_BREEZE_STATE", entry.command)
				assert.same({ BLOWS = "0", AVAILABLE = "1", HAS_BREEZE = "1", FAN = "Aviator 5" }, entry.params)
			end
			assert.are_not.equal(r.sent[1].params, r.sent[2].params)
		end)

		it("AVAILABLE is 1 only with Breeze and the phase online, waiting or rebooting; HAS_BREEZE 0 only for a fan "
			.. "without Breeze in such a phase", function()
			local cases = {
				{ "online", true, "1", "1" }, { "waiting", true, "1", "1" }, { "rebooting", true, "1", "1" },
				{ "offline", true, "0", "1" }, { "unset", true, "0", "1" }, { "foreign", true, "0", "1" },
				{ "gen4", true, "0", "1" }, { "notfan", true, "0", "1" }, { "online", false, "0", "0" },
				{ "online", nil, "0", "0" }, { "waiting", false, "0", "0" }, { "offline", false, "0", "1" },
			}
			for _, case in ipairs(cases) do
				local r = rig()
				r.bound = { 2001 }
				r.phase = case[1]
				r.info = { has_wind = case[2] }
				r.b:late_init()
				assert.equal(case[3], r.last_state().params.AVAILABLE, case[1] .. " " .. tostring(case[2]))
				assert.equal(case[4], r.last_state().params.HAS_BREEZE, case[1] .. " " .. tostring(case[2]))
			end
			local r = rig()
			r.bound = { 2001 }
			r.info = nil -- nothing read yet
			r.b:late_init()
			assert.equal("0", r.last_state().params.AVAILABLE)
		end)

		it("Breeze dropped by the model (a breeze settle with wind nil, BC18) is no Breeze, though has_wind stays",
			function()
				local r = rig()
				r.bound = { 2001 }
				r.blowing()
				r.settle("breeze", { wind = false }, "outside")
				r.clear()
				r.conf.wind, r.conf.wind_speed = nil, nil
				r.b:settled("breeze", copy(r.conf), "outside")
				assert.equal(1, #r.sent)
				assert.same(state("0", "0", "0"), r.last_state().params, "no strength either")
				assert.is_false(r.b:add_switch())
				assert.same({ "breeze_switch_no_breeze" }, r.keys())
				-- Breeze back in an answer: available again.
				r.clear()
				r.settle("breeze", { wind = false, wind_speed = 1 }, "outside")
				assert.same(state("0", "1", "1", "1"), r.last_state().params)
			end)

		it("a phase change that changes AVAILABLE sends the state; one that does not sends nothing", function()
			local r = rig()
			r.bound = { 2001 }
			r.b:late_init()
			r.clear()
			r.go("rebooting")
			r.go("waiting")
			r.go("online")
			assert.same({}, r.sent)
			r.go("foreign")
			assert.equal(1, #r.sent)
			assert.equal("0", r.last_state().params.AVAILABLE)
			r.go("gen4")
			assert.equal(1, #r.sent)
			r.go("waiting")
			assert.equal(2, #r.sent)
			assert.equal("1", r.last_state().params.AVAILABLE)
		end)

		it("Breeze appearing at a contact makes the companions available (BC17)", function()
			local r = rig()
			r.bound = { 2001 }
			r.info = { has_wind = false }
			r.b:late_init()
			r.clear()
			r.info = { has_wind = true }
			r.settle("fan", {}, "start")
			assert.equal(1, #r.sent)
			assert.equal("1", r.last_state().params.AVAILABLE)
		end)

		it("the shown state is never sent: the tile reports only what the fan confirmed", function()
			local r = rig()
			r.bound = { 2001 }
			r.b:late_init()
			r.clear()
			r.b:shown({ fan_on = true, speed = 3, wind = true })
			r.shown = { fan_on = true, speed = 3, wind = true }
			r.b:command("Breeze_On", {})
			assert.same({}, r.sent)
			assert.is_true(r.b:blows_shown())
			r.settle("breeze", { wind = true }, "command")
			assert.same(state("1", "1", "1", "1"), r.last_state().params)
		end)

		it("binding_changed, MF_BREEZE_HELLO and late_init send the state, changed or not", function()
			local r = rig()
			r.bound = { 2001 }
			r.b:late_init()
			r.b:binding_changed(true)
			r.bound = { 2002 }
			r.b:binding_changed(false)
			assert.is_true(r.b:companion("MF_BREEZE_HELLO", {}))
			assert.same({ 2001, 2001, 2002, 2002 }, { r.sent[1].id, r.sent[2].id, r.sent[3].id, r.sent[4].id })
			for _, entry in ipairs(r.sent) do
				assert.equal("MF_BREEZE_STATE", entry.command)
			end
		end)

		it("FAN is the fan item's name, trimmed; empty when it cannot be read", function()
			local r = rig()
			r.bound = { 2001 }
			r.item = "  Aviator 5\n"
			r.b:late_init()
			assert.equal("Aviator 5", r.last_state().params.FAN)
			local q = rig({ opts = { item_name = raises } })
			q.bound = { 2001 }
			q.b:late_init()
			assert.equal("", q.last_state().params.FAN)
		end)

		it("MF_BREEZE_SET runs Breeze on and off, MF_BREEZE_TOGGLE the toggle (BF-D4, BF-D5)", function()
			local r = rig()
			assert.is_true(r.b:companion("MF_BREEZE_SET", { ON = "1" })) -- fan mode: Breeze on
			r.breeze_mode(2)
			assert.is_true(r.b:companion("MF_BREEZE_SET", { ON = "0" })) -- Breeze mode: stop and clear
			r.stopped_mode(true)
			assert.is_true(r.b:companion("MF_BREEZE_SET", { ON = "0" })) -- stored wind: clear
			r.stopped_mode(false)
			assert.is_true(r.b:companion("MF_BREEZE_SET", { ON = "1" })) -- stopped: start in Breeze
			assert.is_true(r.b:companion("MF_BREEZE_TOGGLE", {}))
			r.breeze_mode(1)
			assert.is_true(r.b:companion("MF_BREEZE_TOGGLE", {}))
			assert.same({
				{ wind = true }, { fan_on = false, wind = false }, { wind = false },
				{ wind = true, fan_on = true, speed = 3 }, { wind = true, fan_on = true, speed = 3 },
				{ fan_on = false, wind = false },
			}, r.wants)
			assert.same({}, r.results)
		end)

		it("MF_BREEZE_SET ON 0 in fan mode sends nothing: the Breeze fan never stops a fan in fan mode", function()
			local r = rig()
			r.fan_mode(5)
			assert.is_true(r.b:companion("MF_BREEZE_SET", { ON = "0" }))
			assert.is_true(r.b:companion("MF_BREEZE_SET", { ON = "0", STRENGTH = "9" }))
			assert.same({}, r.wants)
			assert.same({}, r.results, "a STRENGTH beside ON 0 means nothing")
		end)

		it("a refused tap writes Last Action as the command does", function()
			local r = rig()
			r.refuse = "no_breeze"
			r.b:companion("MF_BREEZE_TOGGLE", {})
			r.refuse = "foreign"
			r.b:companion("MF_BREEZE_SET", { ON = "1" })
			r.b:companion("MF_BREEZE_CYCLE", { STEP = "1" })
			assert.same({ { key = "breeze_unavailable", args = {} }, { key = "breeze_refused", args = { why = "foreign" } },
				{ key = "breeze_refused", args = { why = "foreign" } } }, r.results)
		end)

		it("ignores another ON, and any other message, which also gets no state", function()
			local r = rig()
			r.bound = { 2001 }
			assert.is_true(r.b:companion("MF_BREEZE_SET", { ON = "yes" }))
			assert.is_true(r.b:companion("MF_BREEZE_SET", {}))
			assert.same({}, r.wants)
			assert.same({}, r.results)
			assert.equal(2, #r.sent, "the state after each MF_BREEZE_SET")
			r.clear()
			assert.is_false(r.b:companion("MF_BREEZE_STATE", { BLOWS = "1" }))
			assert.is_false(r.b:companion("LUA_ACTION", {}))
			assert.is_false(r.b:companion(nil, nil))
			assert.same({}, r.wants)
			assert.same({}, r.sent)
			assert.same({}, r.results)
			assert.is_true(r.log.has("debug", "MF_BREEZE_STATE ignored"))
		end)

		it("a send that fails is logged and the next companion still hears", function()
			local heard = {}
			local r = rig({ opts = { send = function(id, command, params)
				if id == 2001 then
					error("gone")
				end
				heard[#heard + 1] = { id = id, command = command, params = params }
			end } })
			r.bound = { 2001, 2002 }
			assert.has_no.errors(function() r.b:late_init() end)
			assert.equal(1, #heard)
			assert.equal(2002, heard[1].id)
			assert.is_true(r.log.has("warn", "device 2001"))
		end)

		it("bound companions that cannot be read are none", function()
			for _, companions in ipairs({ raises, function() return nil end, function() return "2001" end }) do
				local r = rig({ opts = { companions = companions } })
				assert.has_no.errors(function() r.b:late_init() end)
				assert.same({}, r.sent)
			end
		end)
	end)

	describe("MF_BREEZE_SET with STRENGTH (BF-D5, BF-D9)", function()
		it("ON 1 with STRENGTH 1 to 3 wants wind and the strength, as text or a number", function()
			local r = rig()
			r.b:companion("MF_BREEZE_SET", { ON = "1", STRENGTH = "2" })
			r.b:companion("MF_BREEZE_SET", { ON = "1", STRENGTH = 3 })
			r.b:companion("MF_BREEZE_SET", { ON = "1", STRENGTH = " 1 " })
			assert.same({ { wind = true, wind_speed = 2 }, { wind = true, wind_speed = 3 },
				{ wind = true, wind_speed = 1 } }, r.wants)
			assert.same({}, r.results)
		end)

		it("from stopped adds the fan on at its confirmed speed; in Breeze mode only the strength changes", function()
			local r = rig()
			r.conf.fan_on, r.conf.speed = false, 6
			r.b:companion("MF_BREEZE_SET", { ON = "1", STRENGTH = "3" })
			r.breeze_mode(1)
			r.b:companion("MF_BREEZE_SET", { ON = "1", STRENGTH = "2" })
			assert.same({ { wind = true, wind_speed = 3, fan_on = true, speed = 6 }, { wind = true, wind_speed = 2 } },
				r.wants)
		end)

		it("a STRENGTH outside 1 to 3 is L34 with what was given, and nothing is sent to the fan", function()
			for _, given in ipairs({ "0", "4", "2.5", "x", "", " ", -1, 9 }) do
				local r = rig()
				r.bound = { 2001 }
				assert.is_true(r.b:companion("MF_BREEZE_SET", { ON = "1", STRENGTH = given }))
				assert.same({}, r.wants, tostring(given))
				assert.same({ { key = "breeze_strength", args = { strength = given } } }, r.results)
				assert.equal(1, #r.sent, "the tile is put back")
				assert.is_true(r.log.has("warn", "MF_BREEZE_SET with strength"))
			end
		end)

		it("without STRENGTH (a 1.2 switch, or none known) the fan resumes its own strength (BF52)", function()
			local r = rig()
			r.b:companion("MF_BREEZE_SET", { ON = "1" })
			assert.same({ { wind = true } }, r.wants)
		end)
	end)

	describe("MF_BREEZE_CYCLE (BF-D9, BF30)", function()
		it("STEP 1 outside Breeze mode is Breeze on at strength 1, ending fan mode", function()
			local r = rig()
			r.fan_mode(4)
			assert.is_true(r.b:companion("MF_BREEZE_CYCLE", { STEP = "1" }))
			assert.same({ { wind = true, wind_speed = 1 } }, r.wants)
			assert.same({}, r.results)
		end)

		it("STEP 1 from stopped, with or without a stored wind, starts the fan as Breeze on does", function()
			for _, wind in ipairs({ false, true }) do
				local r = rig()
				r.stopped_mode(wind)
				r.conf.speed = 5
				r.b:companion("MF_BREEZE_CYCLE", { STEP = "1" })
				assert.same({ { wind = true, wind_speed = 1, fan_on = true, speed = 5 } }, r.wants)
			end
		end)

		it("STEP 1 in Breeze mode is one strength up, and nothing at 3", function()
			local r = rig()
			r.breeze_mode(1)
			r.b:companion("MF_BREEZE_CYCLE", { STEP = "1" })
			r.breeze_mode(2)
			r.b:companion("MF_BREEZE_CYCLE", { STEP = "1" })
			r.breeze_mode(3)
			local ok, why = r.b:cycle("1")
			assert.is_false(ok)
			assert.equal("nothing", why)
			assert.same({ { wind_speed = 2 }, { wind_speed = 3 } }, r.wants)
			assert.same({}, r.results)
		end)

		it("STEP -1 in Breeze mode is one strength down, and nothing at 1: it never ends Breeze", function()
			local r = rig()
			r.breeze_mode(3)
			r.b:companion("MF_BREEZE_CYCLE", { STEP = "-1" })
			r.breeze_mode(2)
			r.b:companion("MF_BREEZE_CYCLE", { STEP = "-1" })
			r.breeze_mode(1)
			r.b:companion("MF_BREEZE_CYCLE", { STEP = "-1" })
			assert.same({ { wind_speed = 2 }, { wind_speed = 1 } }, r.wants)
			assert.same({}, r.results)
		end)

		it("STEP -1 outside Breeze mode does nothing (logged)", function()
			for _, shown in ipairs({
				{ fan_on = true, speed = 3, wind = false }, { fan_on = false, wind = false },
				{ fan_on = false, wind = true, wind_speed = 2 }, {},
			}) do
				local r = rig()
				r.shown = shown
				local ok, why = r.b:cycle("-1")
				assert.is_false(ok)
				assert.equal("nothing", why)
				assert.same({}, r.wants)
				assert.same({}, r.results)
				assert.is_true(r.log.has("info", "not in Breeze mode"))
			end
		end)

		it("counts from the shown strength, so a burst counts from its target", function()
			local r = rig()
			r.conf.wind, r.conf.wind_speed = true, 1
			r.shown = { fan_on = true, speed = 3, wind = true, wind_speed = 2 } -- strength 2 already wanted
			r.b:companion("MF_BREEZE_CYCLE", { STEP = "1" })
			assert.same({ { wind_speed = 3 } }, r.wants)
		end)

		it("in Breeze mode with the strength unknown it does nothing", function()
			for _, step in ipairs({ "1", "-1" }) do
				local r = rig()
				r.breeze_mode(nil)
				r.b:companion("MF_BREEZE_CYCLE", { STEP = step })
				assert.same({}, r.wants)
				assert.is_true(r.log.has("info", "strength is not known"))
			end
		end)

		it("takes STEP as a number too, trimmed text, and refuses anything else (logged, nothing sent)", function()
			local r = rig()
			r.breeze_mode(2)
			r.b:companion("MF_BREEZE_CYCLE", { STEP = 1 })
			r.b:companion("MF_BREEZE_CYCLE", { STEP = " -1 " })
			r.b:companion("MF_BREEZE_CYCLE", { STEP = -1 })
			assert.same({ { wind_speed = 3 }, { wind_speed = 1 }, { wind_speed = 1 } }, r.wants)
			for _, step in ipairs({ "2", "0", "+1", "", "up", 2, 0.5, false }) do
				local q = rig()
				q.breeze_mode(2)
				local ok, why = q.b:cycle(step)
				assert.is_false(ok)
				assert.equal("step", why)
				assert.is_true(q.b:companion("MF_BREEZE_CYCLE", { STEP = step }))
				assert.same({}, q.wants, tostring(step))
				assert.same({}, q.results)
				assert.is_true(q.log.has("warn", "MF_BREEZE_CYCLE with STEP"))
			end
			local q = rig()
			q.b:companion("MF_BREEZE_CYCLE", {})
			assert.same({}, q.wants)
			assert.is_true(q.log.has("warn", "STEP nil refused"))
		end)
	end)

	describe("the state after every companion message (BF-D9, BF35)", function()
		-- { name, command, params, start in Breeze mode, taken by the model when it accepts }
		local cases = {
			{ "MF_BREEZE_SET on", "MF_BREEZE_SET", { ON = "1" }, false, true },
			{ "MF_BREEZE_SET off", "MF_BREEZE_SET", { ON = "0" }, "breeze", true },
			{ "MF_BREEZE_SET off with nothing to end", "MF_BREEZE_SET", { ON = "0" } },
			{ "MF_BREEZE_SET with a bad STRENGTH", "MF_BREEZE_SET", { ON = "1", STRENGTH = "7" } },
			{ "MF_BREEZE_SET with a bad ON", "MF_BREEZE_SET", { ON = "x" } },
			{ "MF_BREEZE_TOGGLE", "MF_BREEZE_TOGGLE", {}, false, true },
			{ "MF_BREEZE_CYCLE up", "MF_BREEZE_CYCLE", { STEP = "1" }, false, true },
			{ "MF_BREEZE_CYCLE down with nowhere to go", "MF_BREEZE_CYCLE", { STEP = "-1" } },
			{ "MF_BREEZE_CYCLE with a bad STEP", "MF_BREEZE_CYCLE", { STEP = "9" } },
		}
		for _, case in ipairs(cases) do
			it(case[1] .. ": one state message to every companion, at once when refused or empty, else once settled",
				function()
				for _, refuse in ipairs({ false, "foreign" }) do
					local r = rig()
					r.bound = { 2001, 2002 }
					r.b:late_init()
					r.clear()
					if case[4] == "breeze" then
						r.breeze_mode(2)
					end
					r.refuse = refuse or nil
					assert.is_true(r.b:companion(case[2], case[3]))
					local want = state("0", "1", "1")
					if case[5] and not refuse then
						assert.equal(0, #r.sent, "nothing until the fan has answered")
						r.shown = nil -- the fan answered: nothing is pending
						r.b:settled("breeze", copy(r.conf), "command")
						want = state("0", "1", "1", "1")
					end
					assert.equal(2, #r.sent, tostring(refuse))
					assert.same({ 2001, 2002 }, { r.sent[1].id, r.sent[2].id })
					for _, entry in ipairs(r.sent) do
						assert.equal("MF_BREEZE_STATE", entry.command)
						assert.same(want, entry.params, "confirmed, never the shown target")
					end
				end
			end)
		end

		it("MF_BREEZE_HELLO sends the state once", function()
			local r = rig()
			r.bound = { 2001 }
			r.b:companion("MF_BREEZE_HELLO", {})
			assert.equal(1, #r.sent)
		end)

		it("what the fan then confirms follows as a change", function()
			local r = rig()
			r.bound = { 2001 }
			r.settle("breeze", {}, "start")
			r.clear()
			r.b:companion("MF_BREEZE_SET", { ON = "1", STRENGTH = "3" })
			assert.equal(0, #r.sent, "a taken request is answered once it settles")
			r.settle("breeze", { wind = true, wind_speed = 3 }, "command")
			assert.equal(1, #r.sent)
			assert.same(state("1", "1", "1", "3"), r.last_state().params)
		end)

		it("half way through a pair nothing is answered; the reply goes once nothing is pending", function()
			local r = rig()
			r.bound = { 2001 }
			r.settle("fan", { fan_on = false }, "start")
			r.clear()
			r.b:companion("MF_BREEZE_SET", { ON = "1", STRENGTH = "2" })
			r.shown = { fan_on = true, speed = 3, direction = "forward", wind = true, wind_speed = 2 }
			r.settle("breeze", { wind = true, wind_speed = 2 }, "command") -- the fan is still off
			assert.equal(0, #r.sent, "half way: no reply")
			r.shown = nil
			r.settle("fan", { fan_on = true }, "command")
			assert.equal(1, #r.sent)
			assert.same(state("1", "1", "1", "2"), r.last_state().params)
		end)

		it("a reply still due goes when the model says a group has nothing more coming (idle)", function()
			local r = rig()
			r.bound = { 2001 }
			r.b:companion("MF_BREEZE_TOGGLE", {})
			assert.equal(0, #r.sent)
			r.b:idle("light")
			assert.equal(0, #r.sent, "only the fan and breeze groups count")
			r.b:idle("breeze")
			assert.equal(1, #r.sent)
			r.b:idle("breeze")
			assert.equal(1, #r.sent, "once")
		end)
	end)

	describe("STRENGTH in MF_BREEZE_STATE (BF-D9, BF43)", function()
		it("is the confirmed strength once the fan reported one, also while Breeze is off", function()
			local r = rig()
			r.bound = { 2001 }
			r.settle("fan", {}, "start") -- wind false, wind_speed 1
			r.b:late_init()
			assert.same(state("0", "1", "1", "1"), r.last_state().params)
			r.settle("breeze", { wind = true, wind_speed = 3 }, "command")
			assert.same(state("1", "1", "1", "3"), r.last_state().params)
		end)

		it("is left out before the first report, and while the strength is unknown or not 1 to 3", function()
			local r = rig()
			r.bound = { 2001 }
			r.b:late_init()
			assert.is_nil(r.last_state().params.STRENGTH)
			for _, odd in ipairs({ false, 0, 4, 2.5, "x" }) do
				local q = rig()
				q.bound = { 2001 }
				q.conf.wind_speed = odd or nil
				q.settle("breeze", {}, "start")
				q.b:late_init()
				assert.is_nil(q.last_state().params.STRENGTH, tostring(odd))
			end
		end)

		it("a strength the fan reports as text is sent as its digit", function()
			local r = rig()
			r.bound = { 2001 }
			r.settle("breeze", { wind_speed = "2" }, "start")
			r.b:late_init()
			assert.equal("2", r.last_state().params.STRENGTH)
		end)

		it("a new strength alone is a state message, with no event and no variable, blowing or not", function()
			local r = rig()
			r.bound = { 2001 }
			r.blowing()
			r.settle("breeze", { wind_speed = 2 }, "outside")
			assert.equal(1, #r.sent)
			assert.same(state("1", "1", "1", "2"), r.last_state().params)
			r.settle("breeze", { wind_speed = 2 }, "outside")
			r.settle("fan", { speed = 5 }, "outside")
			assert.equal(1, #r.sent, "the same strength again sends nothing")
			r.settle("breeze", { wind = false }, "command")
			r.clear()
			r.settle("breeze", { wind_speed = 3 }, "outside")
			assert.equal(1, #r.sent)
			assert.same(state("0", "1", "1", "3"), r.last_state().params)
			assert.same({}, r.fired)
			assert.same({}, r.variables)
			assert.same({}, r.persisted)
		end)

		it("a strength that becomes unknown is a message without STRENGTH", function()
			local r = rig()
			r.bound = { 2001 }
			r.settle("breeze", {}, "start")
			r.clear()
			r.conf.wind_speed = nil
			r.b:settled("breeze", copy(r.conf), "outside")
			assert.equal(1, #r.sent)
			assert.same(state("0", "1", "1"), r.last_state().params)
		end)
	end)

	describe("link 311's LED (blows_shown)", function()
		it("is Breeze mode on the shown state: the shown wind and fan_on, wanted over confirmed", function()
			local r = rig()
			assert.is_false(r.b:blows_shown())
			r.shown = { fan_on = true, speed = 3, wind = true }
			assert.is_true(r.b:blows_shown())
			r.shown = { fan_on = false, speed = 3, wind = true }
			assert.is_false(r.b:blows_shown())
			r.shown = { fan_on = true, speed = 3 }
			assert.is_false(r.b:blows_shown())
		end)

		it("is dark before the first contact (BC22: nothing shown yet)", function()
			local r = rig()
			r.store.mf_breeze = true
			r.shown = {}
			assert.is_false(r.b:blows_shown())
		end)

		it("uses the last shown state given when the model cannot answer", function()
			local r = rig()
			r.b:shown({ fan_on = true, speed = 2, wind = true })
			r.model.shown = raises
			assert.is_true(r.b:blows_shown())
			r.b:shown({ fan_on = true, speed = 2, wind = false })
			assert.is_false(r.b:blows_shown())
		end)
	end)

	describe("BOOL_BREEZE (BZ3)", function()
		it("answers nil for any other condition", function()
			local r = rig()
			assert.is_nil(r.b:test_condition("BOOL_ONLINE", { VALUE = "True" }))
			assert.is_nil(r.b:test_condition(nil, {}))
		end)

		it("compares VALUE as BOOL_ONLINE does, NOT_EQUAL inverting", function()
			local r = rig()
			r.blowing()
			assert.is_true(r.b:test_condition("BOOL_BREEZE", {}))
			assert.is_true(r.b:test_condition("BOOL_BREEZE", { VALUE = "True", LOGIC = "EQUAL" }))
			assert.is_false(r.b:test_condition("BOOL_BREEZE", { VALUE = "False", LOGIC = "EQUAL" }))
			assert.is_false(r.b:test_condition("BOOL_BREEZE", { VALUE = "True", LOGIC = "NOT_EQUAL" }))
			assert.is_true(r.b:test_condition("BOOL_BREEZE", { VALUE = "False", LOGIC = "NOT_EQUAL" }))
			r.settle("fan", { fan_on = false }, "outside")
			assert.is_false(r.b:test_condition("BOOL_BREEZE", nil))
			assert.is_true(r.b:test_condition("BOOL_BREEZE", { VALUE = "False" }))
		end)

		it("is the confirmed value, not the shown one", function()
			local r = rig()
			r.shown = { fan_on = true, speed = 3, wind = true }
			assert.is_false(r.b:test_condition("BOOL_BREEZE", {}))
		end)
	end)

	describe("Add Breeze Fan (BZ11, BC28, BF-D10)", function()
		it("adds the companion named after the fan item, binds it and writes L36", function()
			local r = rig()
			assert.is_true(r.b:add_switch())
			assert.equal(1, #r.adds)
			assert.equal("Aviator 5 Breeze", r.adds[1].name)
			assert.same({}, r.binds)
			r.adds[1].cb(2001)
			assert.same({ 2001 }, r.binds)
			assert.same({ { key = "breeze_switch_added", args = { name = "Aviator 5 Breeze" } } }, r.results)
			assert.same({}, r.sent)
		end)

		it("takes the new device id as digits too", function()
			local r = rig()
			r.b:add_switch()
			r.adds[1].cb("2001")
			assert.same({ 2001 }, r.binds)
			assert.equal("breeze_switch_added", r.results[1].key)
		end)

		it("is refused without a pin (L39), before anything else", function()
			local r = rig()
			r.pin = nil
			r.info = { has_wind = false }
			r.bound = { 2001 }
			assert.is_false(r.b:add_switch())
			assert.same({ { key = "breeze_switch_no_fan", args = {} } }, r.results)
			assert.same({}, r.adds)
			local q = rig()
			q.model.identity = raises
			q.b:add_switch()
			assert.same({ "breeze_switch_no_fan" }, q.keys())
		end)

		it("is refused without Breeze (L38, BZ10)", function()
			for _, info in ipairs({ { has_wind = false }, { has_light = true }, false }) do
				local r = rig()
				r.info = info or nil
				r.bound = { 2001 }
				r.b:add_switch()
				assert.same({ { key = "breeze_switch_no_breeze", args = {} } }, r.results)
				assert.same({}, r.adds)
			end
		end)

		it("is refused while a companion is bound (L37), naming the switch", function()
			local r = rig()
			r.bound = { 2002 }
			local ok, why = r.b:add_switch()
			assert.is_false(ok)
			assert.equal("exists", why)
			assert.same({ { key = "breeze_switch_exists", args = { name = "Aviator 5 Breeze" } } }, r.results)
			assert.same({}, r.adds)
		end)

		it("a bound 1.2 switch is L41 instead of L37, naming it, and nothing is added", function()
			local r = rig()
			r.bound = { 2002 }
			r.old = { [2002] = true }
			local ok, why = r.b:add_switch()
			assert.is_false(ok)
			assert.equal("old", why)
			assert.same({ 2002 }, r.old_asked)
			assert.same({ { key = "breeze_old_switch", args = { name = "Aviator 5 Breeze" } } }, r.results)
			assert.same({}, r.adds)
			assert.is_true(r.log.has("always", "1.2 Breeze switch"))
		end)

		it("L41 when any bound companion is a 1.2 switch, whatever else is bound", function()
			local r = rig()
			r.bound = { 2001, "2002" }
			r.old = { [2002] = true }
			r.b:add_switch()
			assert.same({ 2001, 2002 }, r.old_asked)
			assert.same({ "breeze_old_switch" }, r.keys())
		end)

		it("an old_companion that says no, raises, answers oddly or is missing leaves L37", function()
			for _, o in ipairs({
				{}, { opts = { old_companion = raises } }, { opts = { old_companion = function() return "true" end } },
				{ opts = { old_companion = function() return 1 end } }, { without = { "old_companion" } },
			}) do
				local r = rig(o)
				r.bound = { 2001 }
				r.b:add_switch()
				assert.same({ { key = "breeze_switch_exists", args = { name = "Aviator 5 Breeze" } } }, r.results)
				assert.same({}, r.adds)
			end
		end)

		it("no pin (L39) and no Breeze (L38) come before L41", function()
			local r = rig()
			r.pin = nil
			r.bound = { 2002 }
			r.old = { [2002] = true }
			r.b:add_switch()
			r.pin = copy(PIN)
			r.info = { has_wind = false }
			r.b:add_switch()
			assert.same({ "breeze_switch_no_fan", "breeze_switch_no_breeze" }, r.keys())
			assert.same({}, r.old_asked)
		end)

		it("nothing bound asks old_companion nothing", function()
			local r = rig()
			r.b:add_switch()
			assert.same({}, r.old_asked)
			assert.equal(1, #r.adds)
		end)

		it("a device Composer did not add is L40, and nothing is bound", function()
			local r = rig()
			r.b:add_switch()
			r.adds[1].cb(nil, "driver not found")
			assert.same({}, r.binds)
			assert.same({ { key = "breeze_switch_failed", args = { name = "Aviator 5 Breeze", step = "add" } } },
				r.results)
			assert.is_true(r.log.has("always", "driver not found"))
		end)

		it("a bind that fails or raises says the device was added but not connected (#214)", function()
			for _, bind in ipairs({ function() return false end, function() return nil end, raises }) do
				local r = rig({ opts = { bind = bind } })
				r.b:add_switch()
				r.adds[1].cb(2001)
				assert.same({ { key = "breeze_fan_not_connected", args = { name = "Aviator 5 Breeze" } } }, r.results)
			end
		end)

		it("after a failed bind, Add Breeze Fan binds the same device again and never adds another (#214)",
			function()
				local tries = 0
				local r = rig({ opts = { bind = function()
					tries = tries + 1
					return tries >= 3
				end } })
				r.b:add_switch()
				r.adds[1].cb(2001)
				assert.is_false((r.b:add_switch()))
				assert.equal(1, #r.adds, "no second device added")
				assert.same({ "breeze_fan_not_connected", "breeze_fan_not_connected" }, r.keys())
				assert.is_true((r.b:add_switch()))
				assert.equal(1, #r.adds, "bound on the third try, still one device")
				assert.same({ "breeze_fan_not_connected", "breeze_fan_not_connected", "breeze_switch_added" }, r.keys())
				assert.equal(3, tries, "the same device bound three times")
			end)

		it("an add_device that raises or is missing is L40 at once", function()
			for _, o in ipairs({ { opts = { add_device = raises } }, { without = { "add_device" } } }) do
				local r = rig(o)
				local ok = r.b:add_switch()
				assert.is_false(ok)
				assert.same({ "breeze_switch_failed" }, r.keys())
				assert.equal("add", r.results[1].args.step)
				-- and the next click tries again
				r.b:add_switch()
				assert.equal(2, #r.results)
			end
		end)

		it("cuts the fan's name so the switch fits 30 characters and still ends in Breeze", function()
			local r = rig()
			r.item = "Example Room Ceiling Fan North Side"
			r.b:add_switch()
			local name = r.adds[1].name
			assert.equal("Example Room Ceiling Fa Breeze", name)
			assert.equal(30, #name)
		end)

		it("never cuts a character in half, and drops a blank left at the cut", function()
			local r = rig()
			r.item = string.rep("é", 30) -- two bytes each
			r.b:add_switch()
			assert.equal(string.rep("é", 23) .. " Breeze", r.adds[1].name)
			local q = rig()
			q.item = "Example Room Ceiling A Fan"
			q.b:add_switch()
			assert.equal("Example Room Ceiling A Breeze", q.adds[1].name)
		end)

		it("falls back to the proxy's default name when the item's cannot be read", function()
			for _, item_name in ipairs({ raises, function() return "  " end, function() return 7 end }) do
				local r = rig({ opts = { item_name = item_name } })
				r.b:add_switch()
				assert.equal("Modern Forms Breeze", r.adds[1].name)
			end
		end)

		it("a second click while Composer has not answered adds nothing", function()
			local r = rig()
			r.b:add_switch()
			local ok, why = r.b:add_switch()
			assert.is_false(ok)
			assert.equal("busy", why)
			assert.equal(1, #r.adds)
			r.adds[1].cb(2001)
			r.bound = { 2001 }
			r.b:add_switch()
			assert.same({ "breeze_switch_added", "breeze_switch_exists" }, r.keys())
			assert.equal(1, #r.adds)
		end)

		it("a callback called twice acts once", function()
			local r = rig()
			r.b:add_switch()
			r.adds[1].cb(2001)
			r.adds[1].cb(2002)
			assert.same({ 2001 }, r.binds)
			assert.equal(1, #r.results)
		end)

		it("a callback inside add_device works as a later one", function()
			local r = rig({ opts = { add_device = function(_, cb) cb(2001) end } })
			assert.is_true(r.b:add_switch())
			assert.same({ 2001 }, r.binds)
			assert.same({ "breeze_switch_added" }, r.keys())
		end)
	end)

	describe("stop", function()
		it("an add_device callback after stop does nothing", function()
			local r = rig()
			r.b:add_switch()
			r.b:stop()
			r.adds[1].cb(2001)
			assert.same({}, r.binds)
			assert.same({}, r.results)
		end)

		it("nothing acts after stop", function()
			local r = rig()
			r.bound = { 2001 }
			r.b:stop()
			r.settle("breeze", { wind = true }, "command")
			r.go("offline")
			r.b:shown({ fan_on = true, wind = true })
			r.b:late_init()
			r.b:binding_changed(true)
			assert.is_false(r.b:companion("MF_BREEZE_HELLO", {}))
			assert.is_false(r.b:companion("MF_BREEZE_SET", { ON = "1" }))
			assert.is_false(r.b:companion("MF_BREEZE_CYCLE", { STEP = "1" }))
			assert.is_false((r.b:cycle("1")))
			assert.is_true(r.b:command("Breeze_On", {}))
			assert.is_false((r.b:toggle()))
			assert.is_false((r.b:add_switch()))
			assert.same({}, r.wants)
			assert.same({}, r.fired)
			assert.same({}, r.variables)
			assert.same({}, r.persisted)
			assert.same({}, r.sent)
			assert.same({}, r.results)
			assert.same({}, r.adds)
		end)
	end)
end)
