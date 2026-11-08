-- fan.fanproxy on fakes: the proxy's commands as intents (section 4.6), the
-- reports the proxy hears and when (R1 to R9, section 4.5), the preset and
-- GET_CURRENT_STATE, and the methods the keypad links call (section 9.7).
-- The model is a hand-made table of the shape section 9.5 gives; `on` and
-- `send` record what the module registers and tells.

local fanproxy = require("fan.fanproxy")
local log = require("common.log")

local REAL_SINK = log.sink

local PRESET_KEY = "mf_preset_speed"

local function quiet()
	log.sink = function() end
end

-- Every line the logger emits from here on.
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

-- The parts of model.lua the proxy uses. want() puts the wanted fields over
-- the shown state, as the real model's shown() does (wanted over in flight
-- over confirmed), so a burst of intents counts from its target (R5).
local function fake_model(shown)
	local m = { wants = {}, shown_state = shown or {}, confirmed_state = nil, refuse = nil }
	function m:want(fields)
		if self.refuse then
			return false, self.refuse
		end
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
		return self.confirmed_state
	end
	return m
end

local function fake_store(initial)
	local s = { data = initial or {}, gets = 0, sets = {}, fail_get = false, fail_set = false }
	function s.get(key)
		s.gets = s.gets + 1
		if s.fail_get then
			error("the store is not ready")
		end
		return s.data[key]
	end
	function s.set(key, value)
		if s.fail_set then
			error("the store is not ready")
		end
		s.data[key] = value
		s.sets[#s.sets + 1] = { key, value }
	end
	return s
end

-- A proxy on fakes. opts: shown (the model's shown state), stored (the
-- store's content), can_reverse (default true).
local function rig(opts)
	opts = opts or {}
	local r = {
		model = fake_model(opts.shown), store = fake_store(opts.stored), sent = {}, registered = {}, handlers = {},
	}
	local function on(binding, command, handler)
		r.registered[#r.registered + 1] = binding .. " " .. command
		r.handlers[binding .. ":" .. command] = handler
	end
	local function send(command, params)
		r.sent[#r.sent + 1] = { command, params }
	end
	r.fp = fanproxy.new({
		model = r.model, on = on, send = send, store = r.store, log = log,
		can_reverse = opts.can_reverse ~= false,
	})
	-- A command as Director delivers it: the binding and the parameters.
	function r.recv(command, params)
		local handler = r.handlers["5001:" .. command]
		assert(handler, "no handler registered for " .. command)
		return handler(5001, params)
	end
	-- The last want, or nil.
	function r.last_want()
		return r.model.wants[#r.model.wants]
	end
	function r.clear()
		r.sent = {}
		r.model.wants = {}
	end
	return r
end

describe("fan.fanproxy", function()
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
		it("registers the ten commands of section 9.7 on binding 5001 and nothing else", function()
			local r = rig()
			local expected = {}
			for _, command in ipairs({ "ON", "OFF", "TOGGLE", "SET_SPEED", "CYCLE_SPEED_UP", "CYCLE_SPEED_DOWN",
				"DESIGNATE_PRESET", "SET_DIRECTION", "TOGGLE_DIRECTION", "GET_CURRENT_STATE" }) do
				expected[#expected + 1] = "5001 " .. command
			end
			assert.same(expected, r.registered)
		end)

		it("tells the proxy nothing and reads nothing at construction (late init is the first moment)", function()
			local r = rig({ stored = { [PRESET_KEY] = 5 } })
			assert.same({}, r.sent)
			assert.equal(0, r.store.gets)
		end)

		it("hands a missing argument over loudly: a wiring mistake, not a run-time condition", function()
			assert.has_error(function() fanproxy.new({ model = fake_model(), send = function() end }) end)
			assert.has_error(function() fanproxy.new({ on = function() end, send = function() end }) end)
		end)

		it("has the binding, six speeds and the default preset as constants", function()
			assert.equal(5001, fanproxy.BINDING)
			assert.equal(6, fanproxy.SPEEDS)
			assert.equal(3, fanproxy.DEFAULT_PRESET)
			assert.equal("mf_preset_speed", fanproxy.PRESET_KEY)
		end)
	end)

	describe("ON, OFF and TOGGLE (V11)", function()
		it("ON with the fan off turns it on at the preset, 3 by default", function()
			local r = rig({ shown = { fan_on = false, speed = 5 } })
			r.recv("ON")
			assert.same({ { fan_on = true, speed = 3 } }, r.model.wants)
		end)

		it("ON with the fan running changes nothing, whatever the speed (a fan at 5 does not drop to 3)", function()
			local r = rig({ shown = { fan_on = true, speed = 5 } })
			local ok = r.fp:on()
			assert.is_true(ok)
			assert.same({}, r.model.wants)
			r.recv("ON")
			assert.same({}, r.model.wants)
		end)

		it("ON in a state not known yet counts as off: the request to run is kept", function()
			local r = rig({ shown = {} })
			r.recv("ON")
			assert.same({ { fan_on = true, speed = 3 } }, r.model.wants)
		end)

		it("ON goes to the preset the owner designated", function()
			local r = rig({ shown = { fan_on = false }, stored = { [PRESET_KEY] = 5 } })
			r.recv("ON")
			assert.same({ { fan_on = true, speed = 5 } }, r.model.wants)
		end)

		it("OFF is wanted whatever the shown state says (V8: it can be a poll old)", function()
			local r = rig({ shown = { fan_on = true, speed = 2 } })
			r.recv("OFF")
			assert.same({ { fan_on = false } }, r.model.wants)
			r.clear()
			r.model.shown_state.fan_on = false
			r.recv("OFF")
			assert.same({ { fan_on = false } }, r.model.wants)
		end)

		it("TOGGLE turns a running fan off and a stopped one on at the preset", function()
			local r = rig({ shown = { fan_on = true, speed = 4 } })
			r.recv("TOGGLE")
			assert.same({ { fan_on = false } }, r.model.wants)
			r.recv("TOGGLE")
			assert.same({ { fan_on = false }, { fan_on = true, speed = 3 } }, r.model.wants)
		end)

		it("TOGGLE reads the shown state, so two quick presses undo each other (R5)", function()
			local r = rig({ shown = { fan_on = false, speed = 1 } })
			r.fp:toggle()
			r.fp:toggle()
			assert.same({ { fan_on = true, speed = 3 }, { fan_on = false } }, r.model.wants)
		end)

		it("TOGGLE in a state not known yet is refused: it would be a guess", function()
			local r = rig({ shown = {} })
			local ok, why = r.fp:toggle()
			assert.is_false(ok)
			assert.equal("unknown", why)
			assert.same({}, r.model.wants)
		end)

		it("hands the model's refusal back, and logs it for Debug Mode alone", function()
			local r = rig({ shown = { fan_on = false } })
			r.model.refuse = "foreign"
			local lines = capture_log()
			local ok, why = r.fp:on()
			assert.is_false(ok)
			assert.equal("foreign", why)
			assert.same({}, lines, "a refusal the Status already names is not a warning")
			log.set_debug(true)
			r.fp:off()
			assert.is_true(contains(lines, "fan command refused: foreign"))
		end)
	end)

	describe("SET_SPEED (section 4.6)", function()
		it("0 is off and 1 to 6 are on at that speed, whether the parameter is a string or a number", function()
			local r = rig({ shown = { fan_on = true, speed = 2 } })
			r.recv("SET_SPEED", { SPEED = "0" })
			assert.same({ fan_on = false }, r.last_want())
			for speed = 1, 6 do
				r.recv("SET_SPEED", { SPEED = tostring(speed) })
				assert.same({ fan_on = true, speed = speed }, r.last_want())
			end
			r.recv("SET_SPEED", { SPEED = 4 })
			assert.same({ fan_on = true, speed = 4 }, r.last_want())
			assert.equal(8, #r.model.wants)
		end)

		it("sends the speed the fan already shows too (V8: Control4's commands are always sent)", function()
			local r = rig({ shown = { fan_on = true, speed = 3 } })
			r.recv("SET_SPEED", { SPEED = "3" })
			assert.same({ { fan_on = true, speed = 3 } }, r.model.wants)
		end)

		it("refuses what is no speed, and logs a warning for it", function()
			local r = rig({ shown = { fan_on = true, speed = 2 } })
			local lines = capture_log()
			for _, bad in ipairs({ "7", "-1", "2.5", "abc", "", "nan", "inf", 9, -2 }) do
				r.recv("SET_SPEED", { SPEED = bad })
			end
			r.recv("SET_SPEED", {})
			r.recv("SET_SPEED", nil)
			assert.same({}, r.model.wants)
			assert.equal(11, #lines)
			assert.is_true(contains(lines, "[WARN] fan speed 7 refused: 0 to 6"))
		end)

		it("method form returns true, or false and why", function()
			local r = rig({ shown = { fan_on = false } })
			assert.is_true(r.fp:speed(3))
			local ok, why = r.fp:speed(8)
			assert.is_false(ok)
			assert.equal("range", why)
			r.model.refuse = "gen4"
			ok, why = r.fp:speed(2)
			assert.is_false(ok)
			assert.equal("gen4", why)
		end)
	end)

	describe("CYCLE_SPEED_UP and CYCLE_SPEED_DOWN on the proxy path (V11)", function()
		it("up: off goes to 1, N to N+1, and 6 stays 6 (nothing is sent at the top)", function()
			local r = rig({ shown = { fan_on = false, speed = 4 } })
			r.recv("CYCLE_SPEED_UP")
			assert.same({ fan_on = true, speed = 1 }, r.last_want())
			r.recv("CYCLE_SPEED_UP")
			assert.same({ fan_on = true, speed = 2 }, r.last_want())
			r.model.shown_state.speed = 6
			r.clear()
			r.recv("CYCLE_SPEED_UP")
			assert.same({}, r.model.wants)
		end)

		it("down: off does nothing, N goes to N-1, and 1 stays 1, never off", function()
			local r = rig({ shown = { fan_on = false, speed = 3 } })
			r.recv("CYCLE_SPEED_DOWN")
			assert.same({}, r.model.wants, "a stopped fan stays stopped")
			r.model.shown_state = { fan_on = true, speed = 3 }
			r.recv("CYCLE_SPEED_DOWN")
			assert.same({ fan_on = true, speed = 2 }, r.last_want())
			r.model.shown_state.speed = 1
			r.clear()
			r.recv("CYCLE_SPEED_DOWN")
			assert.same({}, r.model.wants)
		end)

		it("a burst counts from the target, not from the last report, and tells the proxy once (R5)", function()
			local r = rig({ shown = { fan_on = true, speed = 2 } })
			r.recv("CYCLE_SPEED_UP")
			r.recv("CYCLE_SPEED_UP")
			r.recv("CYCLE_SPEED_UP")
			assert.same({ { fan_on = true, speed = 3 }, { fan_on = true, speed = 4 }, { fan_on = true, speed = 5 } },
				r.model.wants)
			assert.same({}, r.sent, "the intermediate steps are the proxy's business only if the fan confirms them")
			r.fp:settled("fan", { fan_on = true, speed = 5 }, "command")
			assert.same({ { "CURRENT_SPEED", { SPEED = 5 } } }, r.sent)
		end)

		it("refuses while the speed is not known: on without a speed, or no state at all", function()
			local r = rig({ shown = {} })
			local ok, why = r.fp:cycle(1, false)
			assert.is_false(ok)
			assert.equal("unknown", why)
			r.model.shown_state = { fan_on = true }
			ok, why = r.fp:cycle(-1, false)
			assert.is_false(ok)
			assert.equal("unknown", why)
			assert.same({}, r.model.wants)
		end)

		it("the method never goes round: 6 stays 6 up and 1 stays 1 down (V11, #77)", function()
			local r = rig({ shown = { fan_on = true, speed = 6 } })
			assert.is_true(r.fp:cycle(1))
			assert.same({}, r.model.wants)
			r.model.shown_state.speed = 1
			assert.is_true(r.fp:cycle(-1))
			assert.same({}, r.model.wants)
			r.model.shown_state = { fan_on = false }
			assert.is_true(r.fp:cycle(1))
			assert.same({ fan_on = true, speed = 1 }, r.last_want())
		end)

		it("a step of 0 does nothing", function()
			local r = rig({ shown = { fan_on = true, speed = 3 } })
			assert.is_true(r.fp:cycle(0))
			assert.same({}, r.model.wants)
		end)
	end)

	describe("DESIGNATE_PRESET and the preset (V11)", function()
		it("keeps 1 to 6, saves it as mf_preset_speed and answers PRESET_SPEED, whether a string or a number", function()
			local r = rig({ shown = { fan_on = false } })
			r.recv("DESIGNATE_PRESET", { PRESET = "4" })
			assert.equal(4, r.fp:preset())
			assert.same({ { PRESET_KEY, 4 } }, r.store.sets)
			assert.same({ { "PRESET_SPEED", { SPEED = 4 } } }, r.sent)
			r.recv("DESIGNATE_PRESET", { PRESET = 6 })
			assert.equal(6, r.fp:preset())
			assert.same({ { PRESET_KEY, 4 }, { PRESET_KEY, 6 } }, r.store.sets)
		end)

		it("ON and Toggle from off then go to it", function()
			local r = rig({ shown = { fan_on = false } })
			r.recv("DESIGNATE_PRESET", { PRESET = "5" })
			r.recv("ON")
			assert.same({ fan_on = true, speed = 5 }, r.last_want())
			r.model.shown_state.fan_on = false
			r.recv("TOGGLE")
			assert.same({ fan_on = true, speed = 5 }, r.last_want())
		end)

		it("answers the same value again too: the proxy asked, and the answer is how its page follows (K8)", function()
			local r = rig()
			r.recv("DESIGNATE_PRESET", { PRESET = "3" })
			r.recv("DESIGNATE_PRESET", { PRESET = "3" })
			assert.same({ { "PRESET_SPEED", { SPEED = 3 } }, { "PRESET_SPEED", { SPEED = 3 } } }, r.sent)
		end)

		it("refuses 0, 7, text and a missing PRESET: not saved, warned, and the preset in use is answered", function()
			local r = rig({ stored = { [PRESET_KEY] = 2 } })
			local lines = capture_log()
			for _, bad in ipairs({ "0", "7", "x", "2.5", "" }) do
				r.recv("DESIGNATE_PRESET", { PRESET = bad })
			end
			r.recv("DESIGNATE_PRESET", {})
			r.recv("DESIGNATE_PRESET", nil)
			assert.equal(2, r.fp:preset())
			assert.same({}, r.store.sets)
			assert.equal(7, #r.sent)
			for _, sent in ipairs(r.sent) do
				assert.same({ "PRESET_SPEED", { SPEED = 2 } }, sent)
			end
			assert.equal(7, #lines)
			assert.is_true(contains(lines, "[WARN] DESIGNATE_PRESET 7 refused: 1 to 6; kept 2"))
		end)

		it("loads the saved preset when it is first needed, once, and takes a number or a string", function()
			local r = rig({ stored = { [PRESET_KEY] = "5" } })
			assert.equal(5, r.fp:preset())
			assert.equal(5, r.fp:preset())
			assert.equal(1, r.store.gets)
		end)

		it("falls back to 3 for a saved value that is no speed, and warns once", function()
			for _, bad in ipairs({ 0, 7, "x", 2.5, "" }) do
				local r = rig({ stored = { [PRESET_KEY] = bad } })
				local lines = capture_log()
				assert.equal(3, r.fp:preset(), tostring(bad))
				r.fp:preset()
				if bad ~= "" then
					assert.equal(1, #lines, tostring(bad))
					assert.is_true(contains(lines, "is not a speed; using 3"))
				end
			end
		end)

		it("falls back to 3 when the store cannot be read, and warns", function()
			local r = rig()
			r.store.fail_get = true
			local lines = capture_log()
			assert.equal(3, r.fp:preset())
			assert.is_true(contains(lines, "[WARN] mf_preset_speed could not be read"))
		end)

		it("keeps a designated preset in memory when it cannot be saved, answers, and logs an error", function()
			local r = rig()
			r.store.fail_set = true
			local lines = capture_log()
			r.recv("DESIGNATE_PRESET", { PRESET = "6" })
			assert.equal(6, r.fp:preset())
			assert.same({ { "PRESET_SPEED", { SPEED = 6 } } }, r.sent)
			assert.is_true(contains(lines, "[ERROR] mf_preset_speed could not be saved"))
		end)

		it("works with no store at all: the preset lives in memory", function()
			local sent = {}
			local fp = fanproxy.new({
				model = fake_model(), on = function() end, send = function(c, p) sent[#sent + 1] = { c, p } end, log = log,
			})
			assert.equal(3, fp:preset())
			fp:late_init()
			assert.same({ { "PRESET_SPEED", { SPEED = 3 } } }, sent)
		end)
	end)

	describe("late init (section 4.6)", function()
		it("tells the proxy the preset: 3 by default", function()
			local r = rig()
			r.fp:late_init()
			assert.same({ { "PRESET_SPEED", { SPEED = 3 } } }, r.sent)
		end)

		it("tells it the saved preset", function()
			local r = rig({ stored = { [PRESET_KEY] = 5 } })
			r.fp:late_init()
			assert.same({ { "PRESET_SPEED", { SPEED = 5 } } }, r.sent)
		end)

		it("tells it 3 when the saved value is no speed", function()
			local r = rig({ stored = { [PRESET_KEY] = 12 } })
			r.fp:late_init()
			assert.same({ { "PRESET_SPEED", { SPEED = 3 } } }, r.sent)
		end)

		it("sends nothing of the fan's state: R6 keeps that for the first contact", function()
			local r = rig({ shown = { fan_on = true, speed = 4 } })
			r.fp:late_init()
			for _, sent in ipairs(r.sent) do
				assert.equal("PRESET_SPEED", sent[1])
			end
		end)
	end)

	describe("SET_DIRECTION and TOGGLE_DIRECTION (V18)", function()
		it("writes FORWARD and REVERSE in any case as the direction", function()
			local r = rig({ shown = { direction = "forward" } })
			r.recv("SET_DIRECTION", { DIRECTION = "REVERSE" })
			assert.same({ direction = "reverse" }, r.last_want())
			r.recv("SET_DIRECTION", { DIRECTION = "forward" })
			assert.same({ direction = "forward" }, r.last_want())
			r.recv("SET_DIRECTION", { DIRECTION = " Reverse " })
			assert.same({ direction = "reverse" }, r.last_want())
		end)

		it("trims the direction in linear time (#49)", function()
			local r = rig({ shown = { direction = "forward" } })
			local runs = (" "):rep(100000)
			local started = os.clock()
			r.recv("SET_DIRECTION", { DIRECTION = runs .. "REVERSE" .. runs })
			assert.same({ direction = "reverse" }, r.last_want())
			r.recv("SET_DIRECTION", { DIRECTION = "RE" .. runs .. "VERSE" })
			assert.same({ direction = "reverse" }, r.last_want(), "not a direction: nothing new is wanted")
			assert.is_true(os.clock() - started < 1, "a trim that is not linear takes minutes on this")
		end)

		it("takes the value from a parameter of another name too (the documentation leaves it unnamed)", function()
			local r = rig()
			r.recv("SET_DIRECTION", { str = "REVERSE" })
			assert.same({ direction = "reverse" }, r.last_want())
			r.recv("SET_DIRECTION", { OTHER = "FORWARD" })
			assert.same({ direction = "forward" }, r.last_want())
		end)

		it("prefers DIRECTION over another parameter", function()
			local r = rig()
			r.recv("SET_DIRECTION", { AAA = "FORWARD", DIRECTION = "REVERSE" })
			assert.same({ direction = "reverse" }, r.last_want())
		end)

		it("refuses anything else, with a warning", function()
			local r = rig()
			local lines = capture_log()
			r.recv("SET_DIRECTION", { DIRECTION = "SIDEWAYS" })
			r.recv("SET_DIRECTION", {})
			r.recv("SET_DIRECTION", nil)
			assert.same({}, r.model.wants)
			assert.equal(3, #lines)
			assert.is_true(contains(lines, "[WARN] SET_DIRECTION refused"))
		end)

		it("TOGGLE_DIRECTION writes the other direction, from the shown one", function()
			local r = rig({ shown = { direction = "forward" } })
			r.recv("TOGGLE_DIRECTION")
			assert.same({ direction = "reverse" }, r.last_want())
			r.recv("TOGGLE_DIRECTION")
			assert.same({ direction = "forward" }, r.last_want())
		end)

		it("TOGGLE_DIRECTION is refused while the direction is not known", function()
			local r = rig({ shown = {} })
			local ok, why = r.fp:direction("toggle")
			assert.is_false(ok)
			assert.equal("unknown", why)
			assert.same({}, r.model.wants)
		end)

		it("without can_reverse nothing is ever written, and it is logged (not a warning: the proxy should not ask)",
			function()
				local r = rig({ can_reverse = false, shown = { direction = "forward" } })
				local lines = capture_log()
				log.set_debug(true)
				r.recv("SET_DIRECTION", { DIRECTION = "REVERSE" })
				r.recv("SET_DIRECTION", { DIRECTION = "nonsense" })
				r.recv("TOGGLE_DIRECTION")
				local ok, why = r.fp:direction("reverse")
				assert.is_false(ok)
				assert.equal("cannot reverse", why)
				assert.same({}, r.model.wants)
				assert.is_true(contains(lines, "direction reverse ignored: can_reverse is False"))
				assert.is_false(contains(lines, "[WARN]"))
			end)

		it("the method form takes forward, reverse and toggle, and refuses a word it does not know", function()
			local r = rig({ shown = { direction = "reverse" } })
			assert.is_true(r.fp:direction("forward"))
			assert.same({ direction = "forward" }, r.last_want())
			local ok, why = r.fp:direction("sideways")
			assert.is_false(ok)
			assert.equal("range", why)
		end)

		it("passes the model's refusal on (K11's 'no fanDirection' or a foreign fan)", function()
			local r = rig({ shown = { direction = "forward" } })
			r.model.refuse = "no fanDirection"
			local ok, why = r.fp:direction("reverse")
			assert.is_false(ok)
			assert.equal("no fanDirection", why)
		end)
	end)

	describe("GET_CURRENT_STATE (R6, hardware K8)", function()
		it("arrives at the add with no parameters, before the state is known: nothing is sent", function()
			local r = rig()
			assert.has_no.errors(function() r.recv("GET_CURRENT_STATE", nil) end)
			assert.same({}, r.sent)
			assert.has_no.errors(function() r.recv("GET_CURRENT_STATE", {}) end)
			assert.same({}, r.sent)
		end)

		it("answers CURRENT_SPEED, DIRECTION and PRESET_SPEED once the state is known", function()
			local r = rig({ stored = { [PRESET_KEY] = 4 } })
			r.model.confirmed_state = { fan_on = true, speed = 2, direction = "reverse", light_on = false, level = 100 }
			r.recv("GET_CURRENT_STATE")
			assert.same({
				{ "CURRENT_SPEED", { SPEED = 2 } },
				{ "DIRECTION", { DIRECTION = "REVERSE" } },
				{ "PRESET_SPEED", { SPEED = 4 } },
			}, r.sent)
		end)

		it("answers 0 for a fan that is off, and the confirmed state rather than the wanted one", function()
			local r = rig({ shown = { fan_on = true, speed = 6 } })
			r.model.confirmed_state = { fan_on = false, speed = 2, direction = "forward" }
			r.recv("GET_CURRENT_STATE")
			assert.same({ "CURRENT_SPEED", { SPEED = 0 } }, r.sent[1])
		end)

		it("leaves DIRECTION out without can_reverse, and while the direction is unknown", function()
			local r = rig({ can_reverse = false })
			r.model.confirmed_state = { fan_on = true, speed = 1, direction = "forward" }
			r.recv("GET_CURRENT_STATE")
			assert.same({ { "CURRENT_SPEED", { SPEED = 1 } }, { "PRESET_SPEED", { SPEED = 3 } } }, r.sent)
			local r2 = rig()
			r2.model.confirmed_state = { fan_on = true, speed = 1 }
			r2.recv("GET_CURRENT_STATE")
			assert.same({ { "CURRENT_SPEED", { SPEED = 1 } }, { "PRESET_SPEED", { SPEED = 3 } } }, r2.sent)
		end)

		it("leaves CURRENT_SPEED out for a fan that is on without a speed", function()
			local r = rig()
			r.model.confirmed_state = { fan_on = true, direction = "forward" }
			r.recv("GET_CURRENT_STATE")
			assert.same({ { "DIRECTION", { DIRECTION = "FORWARD" } }, { "PRESET_SPEED", { SPEED = 3 } } }, r.sent)
		end)

		it("counts as having told the proxy, so the same state settling later is not sent again (R1)", function()
			local r = rig()
			r.model.confirmed_state = { fan_on = true, speed = 2, direction = "forward" }
			r.recv("GET_CURRENT_STATE")
			r.sent = {}
			r.fp:settled("fan", r.model.confirmed_state, "online")
			r.fp:settled("direction", r.model.confirmed_state, "online")
			assert.same({}, r.sent)
		end)
	end)

	describe("settled: what the proxy hears, and when (R1 to R9)", function()
		it("R1 tells CURRENT_SPEED when the speed differs from the last one sent, as a number", function()
			local r = rig()
			r.fp:settled("fan", { fan_on = true, speed = 3 }, "command")
			r.fp:settled("fan", { fan_on = true, speed = 3 }, "outside")
			r.fp:settled("fan", { fan_on = true, speed = 4 }, "outside")
			r.fp:settled("fan", { fan_on = true, speed = 4 }, "command")
			assert.same({ { "CURRENT_SPEED", { SPEED = 3 } }, { "CURRENT_SPEED", { SPEED = 4 } } }, r.sent)
			assert.equal("number", type(r.sent[1][2].SPEED))
		end)

		it("R1 says 0 when the fan is off, once, whatever speed the model still holds", function()
			local r = rig()
			r.fp:settled("fan", { fan_on = true, speed = 2 }, "command")
			r.fp:settled("fan", { fan_on = false, speed = 2 }, "command")
			r.fp:settled("fan", { fan_on = false, speed = 2 }, "outside")
			assert.same({ { "CURRENT_SPEED", { SPEED = 2 } }, { "CURRENT_SPEED", { SPEED = 0 } } }, r.sent)
		end)

		it("R1 sends the same speed again when the fan went off and on", function()
			local r = rig()
			r.fp:settled("fan", { fan_on = true, speed = 3 }, "command")
			r.fp:settled("fan", { fan_on = false }, "command")
			r.fp:settled("fan", { fan_on = true, speed = 3 }, "command")
			assert.equal(3, #r.sent)
		end)

		it("R6 start tells the proxy once even where it matches what was sent", function()
			local r = rig()
			r.fp:settled("fan", { fan_on = true, speed = 3, direction = "forward" }, "start")
			r.fp:settled("fan", { fan_on = true, speed = 3, direction = "forward" }, "start")
			r.fp:settled("direction", { fan_on = true, speed = 3, direction = "forward" }, "start")
			r.fp:settled("direction", { fan_on = true, speed = 3, direction = "forward" }, "start")
			assert.same({
				{ "CURRENT_SPEED", { SPEED = 3 } },
				{ "CURRENT_SPEED", { SPEED = 3 } },
				{ "DIRECTION", { DIRECTION = "FORWARD" } },
				{ "DIRECTION", { DIRECTION = "FORWARD" } },
			}, r.sent)
		end)

		it("R6 sends nothing before the first contact: a command only changes what is wanted", function()
			local r = rig({ shown = { fan_on = false } })
			r.recv("SET_SPEED", { SPEED = "4" })
			r.recv("TOGGLE")
			r.recv("CYCLE_SPEED_UP")
			r.recv("SET_DIRECTION", { DIRECTION = "REVERSE" })
			r.recv("GET_CURRENT_STATE")
			assert.same({}, r.sent)
		end)

		it("R4 and R5: commands tell the proxy nothing; only settled does, and only the confirmed value", function()
			local r = rig({ shown = { fan_on = true, speed = 1 } })
			r.fp:settled("fan", { fan_on = true, speed = 1 }, "start")
			r.sent = {}
			r.recv("SET_SPEED", { SPEED = "5" })
			r.recv("SET_SPEED", { SPEED = "2" })
			assert.same({}, r.sent)
			r.fp:settled("fan", { fan_on = true, speed = 2 }, "command")
			assert.same({ { "CURRENT_SPEED", { SPEED = 2 } } }, r.sent)
		end)

		it("R7 an unknown state is never reported as speed 0: offline keeps the proxy's last value", function()
			local r = rig()
			r.fp:settled("fan", {}, "online")
			r.fp:settled("fan", { speed = 3 }, "online")
			r.fp:settled("fan", nil, "online")
			r.fp:settled("direction", {}, "online")
			assert.same({}, r.sent)
		end)

		it("is silent about a fan that is on without a speed (Status S6 says so), and says so in the debug log", function()
			local r = rig()
			local lines = capture_log()
			log.set_debug(true)
			r.fp:settled("fan", { fan_on = true }, "outside")
			assert.same({}, r.sent)
			assert.is_true(contains(lines, "the fan is on without a speed"))
		end)

		it("R8 back online reports what changed meanwhile, and nothing when nothing did", function()
			local r = rig()
			r.fp:settled("fan", { fan_on = true, speed = 2 }, "start")
			r.sent = {}
			r.fp:settled("fan", { fan_on = true, speed = 2 }, "online")
			assert.same({}, r.sent)
			r.fp:settled("fan", { fan_on = true, speed = 5 }, "online")
			assert.same({ { "CURRENT_SPEED", { SPEED = 5 } } }, r.sent)
		end)

		it("R9 never sends ON or OFF, through a whole day of changes", function()
			local r = rig({ shown = { fan_on = false } })
			r.fp:late_init()
			r.fp:settled("fan", { fan_on = false }, "start")
			r.recv("ON")
			r.fp:settled("fan", { fan_on = true, speed = 3 }, "command")
			r.recv("TOGGLE")
			r.fp:settled("fan", { fan_on = false }, "command")
			r.recv("SET_SPEED", { SPEED = "6" })
			r.fp:settled("fan", { fan_on = true, speed = 6 }, "command")
			r.recv("DESIGNATE_PRESET", { PRESET = "2" })
			r.recv("GET_CURRENT_STATE")
			r.model.confirmed_state = { fan_on = true, speed = 6, direction = "forward" }
			r.recv("GET_CURRENT_STATE")
			r.fp:settled("fan", { fan_on = false }, "outside")
			assert.is_true(#r.sent >= 6)
			for _, sent in ipairs(r.sent) do
				assert.is_truthy(({ CURRENT_SPEED = true, DIRECTION = true, PRESET_SPEED = true })[sent[1]], sent[1])
			end
		end)

		it("tells DIRECTION as FORWARD or REVERSE, only on a change, and only with can_reverse", function()
			local r = rig()
			r.fp:settled("direction", { direction = "forward" }, "command")
			r.fp:settled("direction", { direction = "forward" }, "outside")
			r.fp:settled("direction", { direction = "reverse" }, "outside")
			assert.same({ { "DIRECTION", { DIRECTION = "FORWARD" } }, { "DIRECTION", { DIRECTION = "REVERSE" } } }, r.sent)
			local r2 = rig({ can_reverse = false })
			r2.fp:settled("direction", { direction = "reverse" }, "start")
			assert.same({}, r2.sent)
		end)

		it("ignores a direction that is not known, and the light's group", function()
			local r = rig()
			r.fp:settled("direction", { fan_on = true }, "start")
			r.fp:settled("direction", { direction = "sideways" }, "start")
			r.fp:settled("light", { light_on = true, level = 40 }, "start")
			r.fp:settled("nonsense", {}, "start")
			assert.same({}, r.sent)
		end)

		it("does not count a notification that failed, so the next settle sends it again", function()
			local r = rig()
			local fail = true
			local fp = fanproxy.new({
				model = r.model, on = function() end, log = log,
				send = function(command, params)
					if fail then
						error("proxy not ready")
					end
					r.sent[#r.sent + 1] = { command, params }
				end,
			})
			local lines = capture_log()
			assert.has_no.errors(function() fp:settled("fan", { fan_on = true, speed = 3 }, "start") end)
			assert.is_true(contains(lines, "[ERROR] fan proxy CURRENT_SPEED failed: "))
			assert.is_nil(fp:debug().told_fan)
			assert.equal(0, fp:debug().notify_fan)
			fail = false
			fp:settled("fan", { fan_on = true, speed = 3 }, "outside")
			assert.same({ { "CURRENT_SPEED", { SPEED = 3 } } }, r.sent)
			assert.equal(3, fp:debug().told_fan)
		end)

		it("writes the notification into the debug log as section 3.7 shows it", function()
			local r = rig()
			local lines = capture_log()
			log.set_debug(true)
			r.fp:settled("fan", { fan_on = true, speed = 3 }, "start")
			r.fp:settled("direction", { direction = "reverse" }, "start")
			r.fp:late_init()
			assert.is_true(contains(lines, "[DEBUG] -> fan proxy CURRENT_SPEED 3"))
			assert.is_true(contains(lines, "[DEBUG] -> fan proxy DIRECTION REVERSE"))
			assert.is_true(contains(lines, "[DEBUG] -> fan proxy PRESET_SPEED 3"))
		end)

		it("writes nothing to the log without Debug Mode", function()
			local r = rig()
			local lines = capture_log()
			r.fp:settled("fan", { fan_on = true, speed = 3 }, "start")
			r.fp:late_init()
			assert.same({}, lines)
		end)
	end)

	describe("the methods the links call (section 9.7)", function()
		it("off, on, toggle, speed, cycle and direction return true when they act or have nothing to do", function()
			local r = rig({ shown = { fan_on = true, speed = 3, direction = "forward" } })
			assert.is_true(r.fp:on())
			assert.is_true(r.fp:off())
			assert.is_true(r.fp:toggle())
			assert.is_true(r.fp:speed(2))
			assert.is_true(r.fp:cycle(1, true))
			assert.is_true(r.fp:direction("reverse"))
		end)

		it("return false and why when the model refuses (foreign, offline-less states, unset)", function()
			local r = rig({ shown = { fan_on = true, speed = 3, direction = "forward" } })
			local reasons = { "unset", "invalid address", "foreign", "gen4", "notfan", "rebooting", "no fanSpeed", "range" }
			for _, why in ipairs(reasons) do
				r.model.refuse = why
				for _, call in ipairs({
					function() return r.fp:off() end,
					function() return r.fp:toggle() end,
					function() return r.fp:speed(4) end,
					function() return r.fp:cycle(1, true) end,
					function() return r.fp:direction("reverse") end,
				}) do
					local ok, reason = call()
					assert.is_false(ok)
					assert.equal(why, reason)
				end
			end
			assert.same({}, r.model.wants)
		end)

		it("debug() reports what was told and how many notifications went out", function()
			local r = rig({ stored = { [PRESET_KEY] = 4 } })
			assert.same({ told_fan = nil, told_dir = nil, notify_fan = 0, notify_dir = 0, preset = 4 }, r.fp:debug())
			r.fp:late_init()
			r.fp:settled("fan", { fan_on = true, speed = 6 }, "start")
			r.fp:settled("fan", { fan_on = false }, "command")
			r.fp:settled("direction", { direction = "reverse" }, "command")
			assert.same({ told_fan = 0, told_dir = "reverse", notify_fan = 2, notify_dir = 1, preset = 4 }, r.fp:debug())
		end)

		it("debug() counts CURRENT_SPEED and DIRECTION only, not the preset", function()
			local r = rig()
			r.fp:late_init()
			r.recv("DESIGNATE_PRESET", { PRESET = "2" })
			assert.equal(0, r.fp:debug().notify_fan)
			assert.equal(0, r.fp:debug().notify_dir)
			assert.equal(2, #r.sent)
		end)
	end)

	describe("fan mode and Breeze mode: the commands (#121, breeze-design BF-D3, BF-D4, BF78 to BF84)", function()
		local BLOWING = { fan_on = true, speed = 2, wind = true, wind_speed = 2, direction = "forward" }
		local STORED = { fan_on = false, speed = 2, wind = true } -- the remote's power off during Breeze (BF98)
		local FAN_MODE = { fan_on = true, speed = 2, wind = false }
		local NO_BREEZE = { fan_on = true, speed = 2 } -- Gen 1/2, Gen 3 without Breeze: no `wind` at all

		local function copy(t)
			local out = {}
			for k, v in pairs(t) do
				out[k] = v
			end
			return out
		end

		it("ON in Breeze mode starts fan mode at the preset and ends Breeze: this device shows off (BF78)", function()
			local r = rig({ shown = copy(BLOWING), stored = { [PRESET_KEY] = 4 } })
			r.recv("ON")
			assert.same({ { fan_on = true, speed = 4, wind = false } }, r.model.wants)
		end)

		it("ON in fan mode changes nothing, `wind` false or no `wind` at all", function()
			for _, shown in ipairs({ FAN_MODE, NO_BREEZE }) do
				local r = rig({ shown = copy(shown) })
				r.recv("ON")
				assert.same({}, r.model.wants)
			end
		end)

		it("ON with the motor stopped and a stored `wind` clears it, so Control4 never resumes Breeze here (BF83)",
			function()
				local r = rig({ shown = copy(STORED) })
				r.recv("ON")
				assert.same({ { fan_on = true, speed = 3, wind = false } }, r.model.wants)
			end)

		it("ON in a state not known yet with a `wind` known still ends Breeze", function()
			local r = rig({ shown = { wind = true } })
			r.recv("ON")
			assert.same({ { fan_on = true, speed = 3, wind = false } }, r.model.wants)
		end)

		it("OFF stops the motor and clears `wind` while it is true: blowing or stored (BF-D4, BF84)", function()
			for _, shown in ipairs({ BLOWING, STORED }) do
				local r = rig({ shown = copy(shown) })
				r.recv("OFF")
				assert.same({ { fan_on = false, wind = false } }, r.model.wants)
				local zero = rig({ shown = copy(shown) })
				zero.recv("SET_SPEED", { SPEED = "0" })
				assert.same({ { fan_on = false, wind = false } }, zero.model.wants)
				r.recv("OFF")
				assert.same({ fan_on = false }, r.model.wants[2], "a second Off: the shown `wind` is false by then")
			end
		end)

		it("OFF with `wind` false, or on a fan without Breeze, is `fan_on = false` alone (BF71, BF72)", function()
			for _, shown in ipairs({ FAN_MODE, NO_BREEZE, { fan_on = false, speed = 2, wind = false }, { fan_on = false } }) do
				local r = rig({ shown = copy(shown) })
				r.recv("OFF")
				r.recv("SET_SPEED", { SPEED = "0" })
				assert.same({ { fan_on = false }, { fan_on = false } }, r.model.wants)
			end
		end)

		it("TOGGLE in Breeze mode turns fan mode on at the preset: it does not stop the spinning fan (BF79)", function()
			local r = rig({ shown = copy(BLOWING), stored = { [PRESET_KEY] = 5 } })
			r.recv("TOGGLE")
			assert.same({ { fan_on = true, speed = 5, wind = false } }, r.model.wants)
			r.recv("TOGGLE")
			assert.same({ fan_on = false }, r.model.wants[2], "the second, from fan mode's target, stops it")
		end)

		it("TOGGLE from a stopped fan with a stored `wind` starts fan mode and clears it (BF83)", function()
			local r = rig({ shown = copy(STORED) })
			r.recv("TOGGLE")
			assert.same({ { fan_on = true, speed = 3, wind = false } }, r.model.wants)
		end)

		it("TOGGLE in fan mode stops the fan without a `wind` (there is none to clear)", function()
			local r = rig({ shown = copy(FAN_MODE) })
			r.recv("TOGGLE")
			assert.same({ { fan_on = false } }, r.model.wants)
		end)

		it("TOGGLE is still refused while fan_on is not known, whatever `wind` says", function()
			local r = rig({ shown = { wind = true } })
			local ok, why = r.fp:toggle()
			assert.is_false(ok)
			assert.equal("unknown", why)
			assert.same({}, r.model.wants)
		end)

		it("SET_SPEED 1 to 6 in Breeze mode wants the speed and `wind` false, the held speed too (BF80)", function()
			for n = 1, 6 do
				local r = rig({ shown = copy(BLOWING) })
				r.recv("SET_SPEED", { SPEED = tostring(n) })
				assert.same({ { fan_on = true, speed = n, wind = false } }, r.model.wants)
			end
		end)

		it("SET_SPEED in fan mode, and on a fan without Breeze, sends no `wind`", function()
			for _, shown in ipairs({ FAN_MODE, NO_BREEZE, { fan_on = false, speed = 2, wind = false } }) do
				local r = rig({ shown = copy(shown) })
				r.recv("SET_SPEED", { SPEED = "4" })
				assert.same({ { fan_on = true, speed = 4 } }, r.model.wants)
			end
		end)

		it("a speed after Breeze On was wanted ends it again: the shown `wind` is the target (R5)", function()
			local r = rig({ shown = copy(FAN_MODE) })
			r.model:want({ wind = true }) -- fan/breeze.lua's Breeze On, not answered yet
			r.model.wants = {}
			r.recv("SET_SPEED", { SPEED = "3" })
			assert.same({ { fan_on = true, speed = 3, wind = false } }, r.model.wants)
		end)

		it("CYCLE in Breeze mode counts from off: up gives speed 1 in fan mode, down nothing (BF81)", function()
			local r = rig({ shown = copy(BLOWING) })
			r.recv("CYCLE_SPEED_DOWN")
			assert.same({}, r.model.wants, "down from what this device shows as off")
			r.recv("CYCLE_SPEED_UP")
			assert.same({ { fan_on = true, speed = 1, wind = false } }, r.model.wants)
			r.recv("CYCLE_SPEED_UP")
			assert.same({ fan_on = true, speed = 2 }, r.model.wants[2], "then on from 1 in fan mode")
		end)

		it("CYCLE in Breeze mode goes to 1 whatever speed the fan reports, or none (BF76)", function()
			for _, speed in ipairs({ 6, 1, false }) do
				local shown = copy(BLOWING)
				shown.speed = speed or nil
				local r = rig({ shown = shown })
				assert.is_true(r.fp:cycle(1))
				assert.same({ { fan_on = true, speed = 1, wind = false } }, r.model.wants)
			end
		end)

		it("CYCLE from a stopped fan with a stored `wind`: up clears it, down does nothing and clears nothing", function()
			local r = rig({ shown = copy(STORED) })
			r.recv("CYCLE_SPEED_DOWN")
			assert.same({}, r.model.wants)
			r.recv("CYCLE_SPEED_UP")
			assert.same({ { fan_on = true, speed = 1, wind = false } }, r.model.wants)
		end)

		it("CYCLE is still refused while fan_on is not known", function()
			local r = rig({ shown = { wind = true, speed = 2 } })
			local ok, why = r.fp:cycle(1)
			assert.is_false(ok)
			assert.equal("unknown", why)
		end)

		it("a fan without Breeze is never sent a `wind`, by any command in any state (BF71)", function()
			for _, shown in ipairs({ { fan_on = true, speed = 3 }, { fan_on = false, speed = 3 }, { fan_on = false }, {} }) do
				local r = rig({ shown = copy(shown) })
				for _, command in ipairs({ "ON", "OFF", "TOGGLE", "CYCLE_SPEED_UP", "CYCLE_SPEED_DOWN" }) do
					r.recv(command)
				end
				r.recv("SET_SPEED", { SPEED = "5" })
				r.recv("SET_SPEED", { SPEED = "0" })
				for _, want in ipairs(r.model.wants) do
					assert.is_nil(want.wind)
				end
			end
		end)

		it("the model's refusal comes back from a fan-mode command in Breeze mode as from any other", function()
			local r = rig({ shown = copy(BLOWING) })
			r.model.refuse = "foreign"
			for _, call in ipairs({
				function() return r.fp:on() end,
				function() return r.fp:off() end,
				function() return r.fp:toggle() end,
				function() return r.fp:speed(4) end,
				function() return r.fp:cycle(1) end,
			}) do
				local ok, why = call()
				assert.is_false(ok)
				assert.equal("foreign", why)
			end
		end)
	end)

	describe("fan mode and Breeze mode: what the proxy hears (#121, BF-D2, BF-D13, BF-D14)", function()
		local function speeds(r)
			local out = {}
			for _, sent in ipairs(r.sent) do
				if sent[1] == "CURRENT_SPEED" then
					out[#out + 1] = sent[2].SPEED
				end
			end
			return out
		end

		local function directions(r)
			local out = {}
			for _, sent in ipairs(r.sent) do
				if sent[1] == "DIRECTION" then
					out[#out + 1] = sent[2].DIRECTION
				end
			end
			return out
		end

		-- A rig whose model shows `shown` and confirmed what the proxy was told at start.
		local function started(shown)
			local r = rig({ shown = shown })
			r.fp:settled("fan", shown, "start")
			r.fp:settled("direction", shown, "start")
			r.fp:settled("breeze", shown, "start")
			r.sent = {}
			return r
		end

		-- The model's state moved to `st` with nothing wanted or in flight.
		local function confirm(r, st)
			r.model.shown_state = {}
			for k, v in pairs(st) do
				r.model.shown_state[k] = v
			end
			return st
		end

		it("Breeze starting from fan mode tells CURRENT_SPEED 0 from the Breeze settle (BF73)", function()
			local r = started({ fan_on = true, speed = 4, wind = false })
			r.fp:settled("breeze", confirm(r, { fan_on = true, speed = 4, wind = true }), "outside")
			assert.same({ 0 }, speeds(r))
		end)

		it("the fan group's settle during Breeze is 0 too, and gusts or a new base speed tell nothing (BF76)", function()
			local r = started({ fan_on = true, speed = 4, wind = true })
			for _, speed in ipairs({ 5, 6, 1, 3 }) do
				r.fp:settled("fan", confirm(r, { fan_on = true, speed = speed, wind = true }), "command")
			end
			r.fp:settled("fan", confirm(r, { fan_on = true, wind = true }), "outside")
			assert.same({}, r.sent)
		end)

		it("Breeze ending with the motor turning tells the speed the fan reports (BF75)", function()
			local r = started({ fan_on = true, speed = 4, wind = true })
			r.fp:settled("breeze", confirm(r, { fan_on = true, speed = 4, wind = false }), "outside")
			assert.same({ 4 }, speeds(r))
		end)

		it("Breeze ending with the motor stopped tells nothing: it was 0 and stays 0", function()
			local r = started({ fan_on = true, speed = 4, wind = true })
			r.fp:settled("fan", confirm(r, { fan_on = false, speed = 4, wind = true }), "outside")
			r.fp:settled("breeze", confirm(r, { fan_on = false, speed = 4, wind = false }), "outside")
			assert.same({}, r.sent)
		end)

		it("a restart during Breeze tells 0 once (BF106, R6); the Breeze group's start adds nothing", function()
			local r = rig()
			local st = { fan_on = true, speed = 4, wind = true }
			r.fp:settled("fan", st, "start")
			r.fp:settled("breeze", st, "start")
			assert.same({ 0 }, speeds(r))
		end)

		it("a fan without Breeze is told as in 1.2, and a Breeze settle that drops `wind` adds nothing (BC18)", function()
			local r = started({ fan_on = true, speed = 4 })
			r.fp:settled("fan", confirm(r, { fan_on = true, speed = 5 }), "outside")
			r.fp:settled("breeze", confirm(r, { fan_on = true, speed = 5 }), "outside")
			r.fp:settled("fan", confirm(r, { fan_on = false, speed = 5 }), "command")
			assert.same({ 5, 0 }, speeds(r))
		end)

		describe("two requests, one change (BF-D6, BF-D13)", function()
			it("Breeze to fan mode at another speed: the first answer waits, the proxy hears the new speed once",
				function()
					local r = started({ fan_on = true, speed = 3, wind = true })
					r.recv("SET_SPEED", { SPEED = "5" }) -- the model: wind first, then the speed
					r.fp:settled("breeze", { fan_on = true, speed = 3, wind = false }, "command")
					assert.same({}, r.sent, "not the old speed: the speed request is still to go")
					r.fp:settled("fan", confirm(r, { fan_on = true, speed = 5, wind = false }), "command")
					r.fp:idle("fan", { fan_on = true, speed = 5, wind = false })
					assert.same({ 5 }, speeds(r))
				end)

			it("Breeze to fan mode at the speed the fan held: told at the first answer, which the model will not settle again",
				function()
					local r = started({ fan_on = true, speed = 3, wind = true })
					r.recv("SET_SPEED", { SPEED = "3" })
					r.fp:settled("breeze", { fan_on = true, speed = 3, wind = false }, "command")
					assert.same({ 3 }, speeds(r))
					r.fp:idle("fan", confirm(r, { fan_on = true, speed = 3, wind = false }))
					assert.same({ 3 }, speeds(r), "nothing more")
				end)

			it("a second half the fan did not take: idle() tells what the fan shows", function()
				local r = started({ fan_on = true, speed = 3, wind = true })
				r.recv("SET_SPEED", { SPEED = "5" })
				r.fp:settled("breeze", { fan_on = true, speed = 3, wind = false }, "command")
				assert.same({}, speeds(r))
				-- the speed request failed and was dropped: nothing wanted or in flight, the fan at 3 in fan mode
				r.fp:idle("fan", confirm(r, { fan_on = true, speed = 3, wind = false }))
				assert.same({ 3 }, speeds(r))
			end)

			it("what waited is told by the next settle of any group once nothing is half way", function()
				local r = started({ fan_on = true, speed = 3, wind = true })
				r.recv("SET_SPEED", { SPEED = "5" })
				r.fp:settled("breeze", { fan_on = true, speed = 3, wind = false }, "command")
				r.fp:settled("light", { fan_on = true, speed = 3, wind = false, light_on = true }, "outside")
				assert.same({}, r.sent, "still half way")
				r.fp:settled("light", confirm(r, { fan_on = true, speed = 3, wind = false, light_on = false }), "outside")
				assert.same({ 3 }, speeds(r))
			end)

			it("a start of Breeze whose second half is the motor: the fan settle waits for `wind`", function()
				-- a model that sends the fan first (1.2's order) still never shows the fan's speed on this tile
				local r = started({ fan_on = false, speed = 2, wind = false })
				r.model:want({ fan_on = true, speed = 2, wind = true }) -- fan/breeze.lua's Breeze On from off
				r.fp:settled("fan", { fan_on = true, speed = 2, wind = false }, "command")
				assert.same({}, r.sent)
				r.fp:settled("breeze", confirm(r, { fan_on = true, speed = 2, wind = true }), "command")
				r.fp:idle("breeze", { fan_on = true, speed = 2, wind = true })
				assert.same({}, r.sent, "0 all along")
			end)

			it("Breeze to stopped (fan first, then `wind`) tells nothing: 0 all along", function()
				local r = started({ fan_on = true, speed = 3, wind = true })
				r.recv("OFF")
				r.fp:settled("fan", { fan_on = false, speed = 3, wind = true }, "command")
				r.fp:settled("breeze", confirm(r, { fan_on = false, speed = 3, wind = false }), "command")
				r.fp:idle("breeze", { fan_on = false, speed = 3, wind = false })
				assert.same({}, r.sent)
			end)

			it("start never waits (R6): the first contact tells what the fan shows", function()
				local r = rig({ shown = { fan_on = true, speed = 5, wind = false } })
				r.fp:settled("breeze", { fan_on = true, speed = 3, wind = false }, "start")
				r.fp:settled("fan", { fan_on = true, speed = 3, wind = false }, "start")
				assert.same({ 3, 3 }, speeds(r), "the fan group's start tells it even where it matches (R6)")
			end)

			it("idle() with nothing waiting tells nothing", function()
				local r = started({ fan_on = true, speed = 3, wind = false })
				r.fp:idle("fan", { fan_on = true, speed = 4, wind = false })
				r.fp:idle("breeze", { fan_on = true, speed = 4, wind = false })
				r.fp:idle("light", nil)
				assert.same({}, r.sent)
			end)
		end)

		describe("the direction during Breeze (BF-D14, BF77)", function()
			it("is held while Breeze blows and told once it ends, when it differs", function()
				local r = started({ fan_on = true, speed = 3, wind = false, direction = "reverse" })
				r.fp:settled("breeze", confirm(r, { fan_on = true, speed = 3, wind = true, direction = "reverse" }), "outside")
				r.fp:settled("direction", confirm(r, { fan_on = true, speed = 3, wind = true, direction = "forward" }),
					"outside")
				assert.same({}, directions(r), "held")
				r.fp:settled("breeze", confirm(r, { fan_on = true, speed = 3, wind = false, direction = "forward" }),
					"outside")
				assert.same({ "FORWARD" }, directions(r), "Breeze ended and the direction stayed forward")
			end)

			it("fires no direction event when the fan returns to its direction after Breeze", function()
				local r = started({ fan_on = true, speed = 3, wind = false, direction = "reverse" })
				-- one answer: Breeze blows and the direction reads forward
				local blowing = confirm(r, { fan_on = true, speed = 3, wind = true, direction = "forward" })
				r.fp:settled("direction", blowing, "outside")
				r.fp:settled("breeze", blowing, "outside")
				-- one answer: Breeze over and the direction back (groups settle fan, direction, breeze)
				local back = confirm(r, { fan_on = true, speed = 3, wind = false, direction = "reverse" })
				r.fp:settled("direction", back, "outside")
				r.fp:settled("breeze", back, "outside")
				assert.same({}, directions(r))
				assert.same({ 0, 3 }, speeds(r))
			end)

			it("is told when the motor stops with `wind` still set: that is no longer Breeze", function()
				local r = started({ fan_on = true, speed = 3, wind = false, direction = "reverse" })
				r.fp:settled("direction", confirm(r, { fan_on = true, speed = 3, wind = true, direction = "forward" }),
					"outside")
				r.fp:settled("fan", confirm(r, { fan_on = false, speed = 3, wind = true, direction = "forward" }), "outside")
				assert.same({ "FORWARD" }, directions(r))
			end)

			it("a light settle during Breeze keeps it held", function()
				local r = started({ fan_on = true, speed = 3, wind = false, direction = "reverse" })
				local blowing = confirm(r, { fan_on = true, speed = 3, wind = true, direction = "forward" })
				r.fp:settled("direction", blowing, "outside")
				r.fp:settled("light", blowing, "outside")
				r.fp:idle("light", blowing)
				assert.same({}, directions(r))
			end)

			it("a start during Breeze holds it, then tells it once Breeze ends even when it is the one told before (R6)",
				function()
					local r = rig()
					r.fp:settled("direction", { fan_on = true, speed = 3, wind = false, direction = "forward" }, "start")
					r.sent = {}
					local st = { fan_on = true, speed = 3, wind = true, direction = "forward" }
					r.fp:settled("fan", st, "start")
					r.fp:settled("direction", st, "start")
					assert.same({}, directions(r))
					r.fp:settled("breeze", confirm(r, { fan_on = true, speed = 3, wind = false, direction = "forward" }),
						"outside")
					assert.same({ "FORWARD" }, directions(r))
				end)

			it("GET_CURRENT_STATE during Breeze answers 0 and no DIRECTION, which follows once Breeze ends", function()
				local r = rig()
				r.model.confirmed_state = { fan_on = true, speed = 3, wind = true, direction = "reverse" }
				r.recv("GET_CURRENT_STATE")
				assert.same({ { "CURRENT_SPEED", { SPEED = 0 } }, { "PRESET_SPEED", { SPEED = 3 } } }, r.sent)
				r.sent = {}
				r.fp:settled("breeze", confirm(r, { fan_on = true, speed = 3, wind = false, direction = "reverse" }),
					"outside")
				assert.same({ "REVERSE" }, directions(r))
				assert.same({ 3 }, speeds(r))
			end)

			it("in fan mode, and on a fan without Breeze, it is told as in 1.2", function()
				for _, wind in ipairs({ false, "none" }) do
					local w = wind ~= "none" and wind or nil
					local r = started({ fan_on = true, speed = 3, wind = w, direction = "forward" })
					r.fp:settled("direction", confirm(r, { fan_on = true, speed = 3, wind = w, direction = "reverse" }),
						"command")
					assert.same({ "REVERSE" }, directions(r))
				end
			end)

			it("without can_reverse nothing is held or told, during Breeze or after", function()
				local r = rig({ can_reverse = false })
				r.fp:settled("direction", { fan_on = true, speed = 3, wind = true, direction = "forward" }, "start")
				r.fp:settled("breeze", { fan_on = true, speed = 3, wind = false, direction = "forward" }, "outside")
				assert.same({}, directions(r))
			end)
		end)
	end)

	describe("a tap from a Navigator (section 9.11)", function()
		it("speed 3 is wanted, the fan answers, the proxy hears one CURRENT_SPEED, then the remote's change", function()
			local r = rig({ shown = { fan_on = true, speed = 1, direction = "forward" } })
			r.fp:settled("fan", { fan_on = true, speed = 1 }, "start")
			r.sent = {}
			r.recv("SET_SPEED", { SPEED = "3" })
			assert.same({ { fan_on = true, speed = 3 } }, r.model.wants)
			assert.same({}, r.sent)
			r.fp:settled("fan", { fan_on = true, speed = 3 }, "command")
			assert.same({ { "CURRENT_SPEED", { SPEED = 3 } } }, r.sent)
			r.sent = {}
			-- the remote then sets 5; the next read reports it
			r.fp:settled("fan", { fan_on = true, speed = 5 }, "outside")
			assert.same({ { "CURRENT_SPEED", { SPEED = 5 } } }, r.sent)
		end)
	end)
end)
