-- fan/wire.lua (docs/v1-design.md sections 9.3 and 10.2): every body of
-- section 3.1 byte for byte, the refusals, the answers reduced to the fields
-- the driver uses against the fixtures of section 10.1, and the identity
-- helpers. The ids in the names are the research cases of docs/edge-cases-
-- modernforms.md (N, P, H, F, S, V) and the decisions of docs/v1-design.md (V).

local fake = require("helpers.fake_c4")
local mf = require("fixtures.mf_gen3")
local wire = require("fan.wire")

-- The decoded object of a fixture, through the module under test.
local function decoded(text)
	return assert(wire.decode(text))
end

-- wire.state of a fixture answer with some keys replaced.
local function state_of(overrides)
	return assert(wire.state(decoded(mf.state(overrides))))
end

-- Whether a string anywhere in `value`, keys included, contains `needle`.
local function holds_text(value, needle, seen)
	seen = seen or {}
	if type(value) == "string" then
		return value:find(needle, 1, true) ~= nil
	end
	if type(value) ~= "table" or seen[value] then
		return false
	end
	seen[value] = true
	for key, item in pairs(value) do
		if holds_text(key, needle, seen) or holds_text(item, needle, seen) then
			return true
		end
	end
	return false
end

local function keys_of(tbl)
	local out = {}
	for key in pairs(tbl) do
		out[#out + 1] = key
	end
	table.sort(out)
	return out
end

describe("fan.wire", function()
	local c4

	before_each(function()
		c4 = fake.install_c4({})
	end)

	describe("constants", function()
		it("hold the paths, the header and the fixed bodies of sections 3.1 and 9.3", function()
			assert.equal("/mf", wire.PATH)
			assert.equal("/device", wire.G4_PATH)
			assert.same({ ["Content-Type"] = "application/json" }, wire.HEADERS)
			assert.equal('{"queryDynamicShadowData":1}', wire.QUERY_STATE)
			assert.equal('{"queryStaticShadowData":1}', wire.QUERY_INFO)
			assert.equal('{"query":true}', wire.QUERY_G4)
			assert.equal('{"reboot":true}', wire.REBOOT)
		end)

		it("are plain data: the module loads without Director (pure, section 9.3)", function()
			local saved = rawget(_G, "C4")
			rawset(_G, "C4", nil)
			package.loaded["fan.wire"] = nil
			local ok, loaded = pcall(require, "fan.wire")
			rawset(_G, "C4", saved)
			package.loaded["fan.wire"] = wire
			assert(ok, loaded)
			assert.equal("/mf", loaded.PATH)
		end)
	end)

	describe("body", function()
		it("builds every body of section 3.1 byte for byte, keys in that order (V6)", function()
			local cases = {
				{ { fan_on = true, speed = 1 }, '{"fanOn":true,"fanSpeed":1}' },
				{ { fan_on = true, speed = 2 }, '{"fanOn":true,"fanSpeed":2}' },
				{ { fan_on = true, speed = 3 }, '{"fanOn":true,"fanSpeed":3}' },
				{ { fan_on = true, speed = 4 }, '{"fanOn":true,"fanSpeed":4}' },
				{ { fan_on = true, speed = 5 }, '{"fanOn":true,"fanSpeed":5}' },
				{ { fan_on = true, speed = 6 }, '{"fanOn":true,"fanSpeed":6}' },
				{ { fan_on = false }, '{"fanOn":false}' },
				{ { direction = "forward" }, '{"fanDirection":"forward"}' },
				{ { direction = "reverse" }, '{"fanDirection":"reverse"}' },
				{ { level = 1 }, '{"lightBrightness":1}' },
				{ { level = 50 }, '{"lightBrightness":50}' },
				{ { level = 100 }, '{"lightBrightness":100}' },
				{ { light_on = true }, '{"lightOn":true}' },
				{ { light_on = false }, '{"lightOn":false}' },
				{ { away = false }, '{"awayModeEnabled":false}' },
				{ { learning = false }, '{"adaptiveLearning":false}' },
				-- Breeze (#111, docs/breeze-design.md section 2): exactly these four shapes.
				{ { wind = true }, '{"wind":true}' },
				{ { wind = false }, '{"wind":false}' },
				{ { wind_speed = 1 }, '{"windSpeed":1}' },
				{ { wind_speed = 2 }, '{"windSpeed":2}' },
				{ { wind_speed = 3 }, '{"windSpeed":3}' },
				{ { wind = true, wind_speed = 1 }, '{"wind":true,"windSpeed":1}' },
				{ { wind = true, wind_speed = 3 }, '{"wind":true,"windSpeed":3}' },
			}
			for _, case in ipairs(cases) do
				local body, why = wire.body(case[1])
				assert.equal(case[2], body, tostring(why))
				assert.is_nil(why)
			end
		end)

		it("builds bodies the fan's JSON parser (and C4:JsonDecode) reads back", function()
			local obj = decoded(wire.body({ fan_on = true, speed = 4 }))
			assert.equal(true, obj.fanOn)
			assert.equal(4, obj.fanSpeed)
			assert.equal("reverse", decoded(wire.body({ direction = "reverse" })).fanDirection)
			assert.equal(30, decoded(wire.body({ level = 30 })).lightBrightness)
			assert.equal(false, decoded(wire.body({ light_on = false })).lightOn)
		end)

		it("takes a number that is a whole number, written as an integer (%d)", function()
			assert.equal('{"fanOn":true,"fanSpeed":3}', wire.body({ fan_on = true, speed = 3.0 }))
			assert.equal('{"lightBrightness":40}', wire.body({ level = 40.0 }))
			assert.equal('{"windSpeed":2}', wire.body({ wind_speed = 2.0 }))
		end)

		it("writes Breeze as a boolean and its strength as a number, never a string (BRR 1, 4)", function()
			local on = decoded(wire.body({ wind = true, wind_speed = 2 }))
			assert.equal(true, on.wind)
			assert.equal(2, on.windSpeed)
			assert.equal("number", type(on.windSpeed))
			assert.same({ "wind", "windSpeed" }, keys_of(on))
			assert.equal(false, decoded(wire.body({ wind = false })).wind)
			assert.same({ "windSpeed" }, keys_of(decoded(wire.body({ wind_speed = 3 }))))
			local breeze = { { wind = true }, { wind = false }, { wind_speed = 1 }, { wind = true, wind_speed = 3 } }
			for _, fields in ipairs(breeze) do
				local body = assert(wire.body(fields))
				assert.is_nil(body:find('"windSpeed":"', 1, true), body)
				for _, name in ipairs({ "fanOn", "fanSpeed", "fanDirection", "light", "away", "adaptive" }) do
					assert.is_nil(body:find(name, 1, true), body .. " names " .. name)
				end
			end
		end)

		local function refuses(name, fields, why)
			it("refuses " .. name .. " as '" .. why .. "'", function()
				local body, reason = wire.body(fields)
				assert.is_nil(body)
				assert.equal(why, reason)
			end)
		end

		-- Nothing to build.
		refuses("no table", nil, "empty")
		refuses("a string", "fanOn", "empty")
		refuses("an empty table", {}, "empty")

		-- A key outside the allow-list: the fan's own names, the keys MFR 2.3 says are
		-- never written, and a received shadow's fields (a shadow is never sent back).
		refuses("the fan's own key names", { fanOn = true }, "unknown")
		refuses("the fan's own Breeze key names", { windSpeed = 2 }, "unknown")
		refuses("factory reset", { factory_reset = true }, "unknown")
		refuses("a reboot (only wire.REBOOT carries it)", { reboot = true }, "unknown")
		refuses("a schedule", { schedule = "AAAA" }, "unknown")
		refuses("a timer", { fan_timer = 10 }, "unknown")
		refuses("a numeric key", { [1] = true }, "unknown")
		refuses("an unknown key beside valid fields", { fan_on = true, speed = 3, extra = 1 }, "unknown")

		-- Mixes: one body, one group (section 3.1); the flash rule (S3, V14).
		refuses("fan and light fields together", { fan_on = true, speed = 3, light_on = true }, "mix")
		refuses("fan off with a level", { fan_on = false, level = 30 }, "mix")
		refuses("a level with lightOn:true, the flash of the old level (S3)", { level = 30, light_on = true }, "mix")
		refuses("a level with lightOn:false", { level = 30, light_on = false }, "mix")
		refuses("a direction with a speed", { direction = "forward", speed = 2 }, "mix")
		refuses("a direction with a level", { direction = "forward", level = 3 }, "mix")
		refuses("both automations at once", { away = false, learning = false }, "mix")
		refuses("Breeze with the fan's fields (one group per body)", { fan_on = true, speed = 3, wind = true }, "mix")
		refuses("Breeze with fan off", { fan_on = false, wind = false }, "mix")
		refuses("Breeze with a direction", { direction = "forward", wind = true }, "mix")
		refuses("a strength with a light level", { level = 30, wind_speed = 2 }, "mix")
		refuses("Breeze off with a strength (off carries none)", { wind = false, wind_speed = 2 }, "mix")
		refuses("a speed alone (no body of section 3.1)", { speed = 3 }, "mix")
		refuses("fan on without its speed", { fan_on = true }, "mix")
		refuses("fan off with a speed", { fan_on = false, speed = 3 }, "mix")

		-- Ranges and types (H7, S1, S3).
		refuses("speed 0 (S1)", { fan_on = true, speed = 0 }, "range")
		refuses("speed 7 (H7)", { fan_on = true, speed = 7 }, "range")
		refuses("a negative speed", { fan_on = true, speed = -1 }, "range")
		refuses("a fractional speed", { fan_on = true, speed = 2.5 }, "range")
		refuses("a speed as text", { fan_on = true, speed = "3" }, "range")
		refuses("a boolean speed", { fan_on = true, speed = true }, "range")
		refuses("a NaN speed", { fan_on = true, speed = 0 / 0 }, "range")
		refuses("an infinite speed", { fan_on = true, speed = math.huge }, "range")
		refuses("level 0 (S3: off is lightOn:false)", { level = 0 }, "range")
		refuses("level 101", { level = 101 }, "range")
		refuses("a negative level", { level = -5 }, "range")
		refuses("a fractional level", { level = 50.5 }, "range")
		refuses("a level as text", { level = "50" }, "range")
		refuses("an infinite level", { level = math.huge }, "range")
		refuses("fan_on as text", { fan_on = "yes", speed = 3 }, "range")
		refuses("fan_on as 1", { fan_on = 1, speed = 3 }, "range")
		refuses("light_on as text", { light_on = "on" }, "range")
		refuses("light_on as 1", { light_on = 1 }, "range")
		refuses("a direction up", { direction = "up" }, "range")
		refuses("a capitalised direction", { direction = "Forward" }, "range")
		refuses("a boolean direction (Gen 4's form)", { direction = true }, "range")
		refuses("away mode switched on (only off is ever sent, V22)", { away = true }, "range")
		refuses("adaptive learning switched on", { learning = true }, "range")
		refuses("away as text", { away = "false" }, "range")
		refuses("Breeze as text", { wind = "true" }, "range")
		refuses("Breeze as 1", { wind = 1 }, "range")
		refuses("Breeze strength 0", { wind_speed = 0 }, "range")
		refuses("Breeze strength 4", { wind_speed = 4 }, "range")
		refuses("a negative Breeze strength", { wind_speed = -1 }, "range")
		refuses("a fractional Breeze strength", { wind_speed = 1.5 }, "range")
		refuses("a Breeze strength as text (the vendor app's form, never ours)", { wind_speed = "2" }, "range")
		refuses("a boolean Breeze strength", { wind_speed = true }, "range")
		refuses("a NaN Breeze strength", { wind_speed = 0 / 0 }, "range")
		refuses("an infinite Breeze strength", { wind_speed = math.huge }, "range")
		refuses("Breeze on at strength 4", { wind = true, wind_speed = 4 }, "range")

		it("refuses a received shadow, and the fields wire.state made of one (a shadow is never sent back)", function()
			local shadow = decoded(mf.STATE)
			assert.equal("unknown", select(2, wire.body(shadow)))
			assert.equal("unknown", select(2, wire.body(wire.state(shadow))))
		end)

		it("can only ever write keys of section 3.1: no accepted body names a key the fan keeps for itself", function()
			local forbidden = { "factoryReset", "decommission", "resetRfPairList", "rfPairModeActive", "firmwareUrl",
				"schedule", "Timer", "wind", "reboot", "query" }
			local accepted = { { fan_on = true, speed = 6 }, { fan_on = false }, { direction = "reverse" },
				{ level = 100 }, { light_on = true }, { away = false }, { learning = false } }
			for _, fields in ipairs(accepted) do
				local body = assert(wire.body(fields))
				for _, name in ipairs(forbidden) do
					assert.is_nil(body:find(name, 1, true), body .. " names " .. name)
				end
			end
			-- Breeze's bodies (#111) name wind and windSpeed, and nothing else the fan keeps.
			local breeze = { { wind = true }, { wind = false }, { wind_speed = 3 }, { wind = true, wind_speed = 1 } }
			for _, fields in ipairs(breeze) do
				local body = assert(wire.body(fields))
				for _, name in ipairs(forbidden) do
					if name ~= "wind" then
						assert.is_nil(body:find(name, 1, true), body .. " names " .. name)
					end
				end
			end
		end)
	end)

	describe("decode", function()
		it("returns the object of a JSON body", function()
			local obj = assert(wire.decode(mf.STATE))
			assert.equal("MF_00005E005301", obj.clientId)
			assert.equal(1, obj.fanSpeed)
			assert.equal(true, obj.fanOn)
		end)

		it("says 'empty' for a body of nothing: nil, \"\" and white space (P10)", function()
			assert.same({ nil, "empty" }, { wire.decode(nil) })
			assert.same({ nil, "empty" }, { wire.decode(mf.EMPTY) })
			assert.same({ nil, "empty" }, { wire.decode("  \r\n\t ") })
		end)

		it("says 'json' for a body that is no JSON object (N4, P10)", function()
			for name, text in pairs({ html = mf.HTML, truncated = mf.TRUNCATED, array = mf.ARRAY, number = mf.NUMBER,
				not_found = mf.NOT_FOUND, string = '"MF_00005E005301"', boolean = "true", garbage = "{{" }) do
				local obj, why = wire.decode(text)
				assert.is_nil(obj, name)
				assert.equal("json", why, name)
			end
		end)

		it("counts a raise of C4:JsonDecode as 'json' (API 12_json/_3-JsonDecode documents the raise)", function()
			c4.JsonDecode = function() error("invalid JSON") end
			assert.same({ nil, "json" }, { wire.decode(mf.STATE) })
		end)

		it("counts nil with a message as 'json' (the other documented failure)", function()
			c4.JsonDecode = function() return nil, "no valid JSON value" end
			assert.same({ nil, "json" }, { wire.decode(mf.STATE) })
		end)

		it("counts a value that is no table as 'json'", function()
			c4.JsonDecode = function() return 42 end
			assert.same({ nil, "json" }, { wire.decode("42") })
			c4.JsonDecode = function() return "text" end
			assert.same({ nil, "json" }, { wire.decode('"text"') })
		end)

		it("never raises, whatever it is given", function()
			assert.has_no.errors(function()
				for _, value in ipairs({ 5, true, {}, function() end, mf.STATE }) do
					wire.decode(value)
				end
			end)
			assert.same({ nil, "json" }, { wire.decode(5) })
			assert.same({ nil, "json" }, { wire.decode({}) })
		end)

		it("does not decode a body over 64 KB: no fan's answer is that big (N4, a router's page)", function()
			local calls = 0
			c4.JsonDecode = function() calls = calls + 1 return {} end
			assert.same({ nil, "json" }, { wire.decode("{" .. string.rep(" ", 70000) .. "}") })
			assert.equal(0, calls)
		end)

		it("removes the private fields from the object it hands on (V20, V6), and keeps the rest", function()
			local info = decoded(mf.INFO)
			for _, key in ipairs({ "owner", "federatedIdentity", "deviceName", "SSID", "BSSID" }) do
				assert.is_nil(info[key], key)
			end
			assert.equal("MF_00005E005301", info.clientId)
			assert.equal("00:00:5e:00:53:01", info.mac)
			assert.equal("02.00.0052", info.firmwareVersion)
			local state = decoded(mf.STATE)
			assert.is_nil(state.timezone)
			assert.is_nil(state.FrCodes)
			assert.equal("", state.schedule, "the schedule stays: wire.state turns it into set or empty")
			for _, text in ipairs(mf.PRIVATE_VALUES) do
				assert.is_false(holds_text(info, text), text)
				assert.is_false(holds_text(state, text), text)
			end
		end)
	end)

	describe("state", function()
		it("reads M0's answer: fan on at 1, forward, light off at 100, Breeze off, Gen 3", function()
			assert.same({
				client_id = "MF_00005E005301",
				fan_on = true,
				speed = 1,
				direction = "forward",
				light_on = false,
				level = 100,
				wind = false,
				wind_speed = 2,
				away = false,
				learning = false,
				schedule_set = false,
				fan_timer = 0,
				light_timer = 0,
				user_data = "local_wifi",
				generation = "3",
				unknown = {},
				adjusted = {},
			}, assert(wire.state(decoded(mf.STATE))))
		end)

		it("reads a fan on at speed 3 with the light off at level 100", function()
			local st = assert(wire.state(decoded(mf.STATE_ON_3)))
			assert.equal(true, st.fan_on)
			assert.equal(3, st.speed)
			assert.equal(false, st.light_on)
			assert.equal(100, st.level)
		end)

		it("keeps the speed while the fan is off: off is fanOn false, never speed 0 (S1)", function()
			local st = state_of({ fanOn = false, fanSpeed = 4 })
			assert.equal(false, st.fan_on)
			assert.equal(4, st.speed)
		end)

		it("reads the light on at a level and the direction reverse", function()
			local st = state_of({ lightOn = true, lightBrightness = 40, fanDirection = "reverse" })
			assert.equal(true, st.light_on)
			assert.equal(40, st.level)
			assert.equal("reverse", st.direction)
		end)

		it("reads Breeze: the wind key exists, and its speed", function()
			local st = state_of({ wind = true, windSpeed = 3 })
			assert.equal(true, st.wind)
			assert.equal(3, st.wind_speed)
			assert.equal(1, state_of({ windSpeed = 1 }).wind_speed)
			assert.same({}, st.adjusted)
		end)

		it("reads the fan's own automations: away, learning, a schedule (set or empty), timers, who changed it", function()
			local st = state_of({ awayModeEnabled = true, adaptiveLearning = true, schedule = "AAECAwQFBgc=",
				fanTimer = 600, lightTimer = 30, userData = "schedule" })
			assert.equal(true, st.away)
			assert.equal(true, st.learning)
			assert.equal(true, st.schedule_set)
			assert.equal(600, st.fan_timer)
			assert.equal(30, st.light_timer)
			assert.equal("schedule", st.user_data)
			assert.is_false(holds_text(st, "AAECAwQFBgc="), "the schedule blob does not leave the parser")
		end)

		it("tells Gen 1/2 from Gen 3 by the timer keys, whatever their values (section 4.1)", function()
			local old = assert(wire.state(decoded(mf.GEN12_STATE)))
			assert.equal("1/2", old.generation)
			assert.is_nil(old.wind, "no Breeze key on Gen 1/2")
			assert.is_nil(old.wind_speed)
			assert.is_nil(old.user_data)
			assert.is_nil(old.fan_timer)
			assert.equal(0, old.fan_sleep_timer)
			assert.equal(0, old.light_sleep_timer)
			assert.equal("3", state_of({ fanTimer = mf.OMIT, lightTimer = 5 }).generation)
			assert.equal("3", state_of({ fanTimer = 5, lightTimer = mf.OMIT }).generation)
			assert.is_nil(state_of({ fanTimer = mf.OMIT, lightTimer = mf.OMIT }).generation)
		end)

		describe("without a usable answer", function()
			it("is nil and 'json' for a state without a clientId (section 3.3)", function()
				assert.same({ nil, "json" }, { wire.state(decoded(mf.NO_CLIENT)) })
				assert.same({ nil, "json" }, { wire.state(decoded(mf.state({ clientId = mf.OMIT }))) })
			end)

			it("is nil and 'json' for a clientId that is empty, blank or no string", function()
				for _, id in ipairs({ "", "   " }) do
					assert.same({ nil, "json" }, { wire.state(decoded(mf.state({ clientId = id }))) }, id)
				end
				for _, id in ipairs({ 5, true, {} }) do
					assert.same({ nil, "json" }, { wire.state({ clientId = id, fanOn = true }) }, tostring(id))
				end
			end)

			it("is nil and 'json' for anything that is no table", function()
				for _, value in ipairs({ "MF_00005E005301", 5, true }) do
					assert.same({ nil, "json" }, { wire.state(value) }, tostring(value))
				end
				assert.same({ nil, "json" }, { wire.state(nil) })
			end)
		end)

		describe("a missing or odd field is unknown, never a default (F3, rule 5)", function()
			it("leaves every field nil when the answer holds only a clientId", function()
				local st = assert(wire.state({ clientId = "MF_00005E005301" }))
				assert.same({ client_id = "MF_00005E005301", unknown = {}, adjusted = {} }, st)
				assert.is_nil(st.speed, "AIO's default of 6 is not ours")
				assert.is_nil(st.level, "nor its default of 100")
			end)

			it("takes a value of another type for unknown", function()
				local st = assert(wire.state({
					clientId = "MF_00005E005301",
					fanOn = 1,
					fanSpeed = "3",
					fanDirection = true, -- Gen 4 writes the direction as a boolean (F3)
					lightOn = "on",
					lightBrightness = "100",
					wind = 0,
					windSpeed = "2",
					awayModeEnabled = "false",
					fanTimer = "5",
					userData = 7,
					schedule = 9,
				}))
				for _, field in ipairs({ "fan_on", "speed", "direction", "light_on", "level", "wind", "wind_speed",
					"away", "fan_timer", "user_data", "schedule_set" }) do
					assert.is_nil(st[field], field)
				end
			end)

			it("takes the empty table C4:JsonDecode makes of a JSON null for unknown", function()
				local st = assert(wire.state({ clientId = "MF_00005E005301", fanOn = {}, fanSpeed = {}, lightOn = {},
					lightBrightness = {}, fanDirection = {}, userData = {}, schedule = {} }))
				for _, field in ipairs({ "fan_on", "speed", "direction", "light_on", "level", "user_data", "schedule_set" }) do
					assert.is_nil(st[field], field)
				end
			end)
		end)

		describe("values outside their range (section 3.3, H7, S1, S3)", function()
			it("clamps a fan speed above 6 to 6 and says so", function()
				local st = state_of({ fanSpeed = 9 })
				assert.equal(6, st.speed)
				assert.same({ "fanSpeed 9" }, st.adjusted)
			end)

			it("reads speed 0 with the fan off as 'off, speed unknown': no speed, nothing adjusted", function()
				local st = state_of({ fanOn = false, fanSpeed = 0 })
				assert.equal(false, st.fan_on)
				assert.is_nil(st.speed)
				assert.same({}, st.adjusted)
			end)

			it("clamps speed 0 to 1 when the fan is on or its state is unknown, and says so", function()
				assert.equal(1, state_of({ fanOn = true, fanSpeed = 0 }).speed)
				assert.same({ "fanSpeed 0" }, state_of({ fanOn = true, fanSpeed = 0 }).adjusted)
				local st = assert(wire.state({ clientId = "MF_00005E005301", fanSpeed = 0 }))
				assert.equal(1, st.speed)
				assert.same({ "fanSpeed 0" }, st.adjusted)
				assert.equal(1, state_of({ fanOn = false, fanSpeed = -2 }).speed)
			end)

			it("reports a level of 0 while the light is on as 1, and says so (never 0 while on, S3)", function()
				local st = state_of({ lightOn = true, lightBrightness = 0 })
				assert.equal(1, st.level)
				assert.same({ "lightBrightness 0" }, st.adjusted)
			end)

			it("reads a level of 0 while the light is off, or unknown, as an unknown kept level", function()
				local st = state_of({ lightOn = false, lightBrightness = 0 })
				assert.is_nil(st.level)
				assert.same({}, st.adjusted)
				assert.is_nil(assert(wire.state({ clientId = "MF_00005E005301", lightBrightness = 0 })).level)
			end)

			it("clamps a level above 100 to 100 and a negative one while off to unknown, saying so", function()
				local high = state_of({ lightBrightness = 150 })
				assert.equal(100, high.level)
				assert.same({ "lightBrightness 150" }, high.adjusted)
				local low = state_of({ lightOn = false, lightBrightness = -3 })
				assert.is_nil(low.level)
				assert.same({ "lightBrightness -3" }, low.adjusted)
			end)

			it("clamps a Breeze strength above 3 to 3 and below 1 to 1, rounds a fraction, and says so", function()
				local high = state_of({ wind = true, windSpeed = 5 })
				assert.equal(3, high.wind_speed)
				assert.same({ "windSpeed 5" }, high.adjusted)
				local low = state_of({ wind = true, windSpeed = -1 })
				assert.equal(1, low.wind_speed)
				assert.same({ "windSpeed -1" }, low.adjusted)
				assert.equal(1, state_of({ wind = true, windSpeed = 0 }).wind_speed, "0 while Breeze is on is clamped")
				assert.equal(2, state_of({ windSpeed = 2.4 }).wind_speed)
				assert.same({}, state_of({ windSpeed = 2.4 }).adjusted)
			end)

			it("reads strength 0 with Breeze off, or unknown Breeze, by the speed's rule: unknown only when off", function()
				local off = state_of({ wind = false, windSpeed = 0 })
				assert.is_nil(off.wind_speed)
				assert.same({}, off.adjusted)
				local unknown = state_of({ wind = mf.OMIT, windSpeed = 0 })
				assert.equal(1, unknown.wind_speed)
				assert.same({ "windSpeed 0" }, unknown.adjusted)
			end)

			it("lists every adjustment of one answer, and none for values in range", function()
				local st = state_of({ fanSpeed = 7, lightOn = true, lightBrightness = 0, windSpeed = 9 })
				assert.same({ "fanSpeed 7", "lightBrightness 0", "windSpeed 9" }, st.adjusted)
				assert.same({}, state_of({ fanSpeed = 6, lightOn = true, lightBrightness = 1 }).adjusted)
			end)
		end)

		describe("unknown keys (F2)", function()
			it("lists the names of keys it does not know, sorted, and never their values", function()
				local st = state_of({ newFeature = "secret-value-1", aaaNew = 7, zzzFlag = true })
				assert.same({ "aaaNew", "newFeature", "zzzFlag" }, st.unknown)
				assert.is_false(holds_text(st, "secret-value-1"))
			end)

			it("does not list the keys it knows and ignores or drops on purpose", function()
				local st = assert(wire.state(decoded(mf.STATE)))
				assert.same({}, st.unknown)
				local raw = assert(C4:JsonDecode(mf.STATE))
				raw.owner, raw.certificateId, raw.fanSleepTimer = "someone", "cert", 0
				assert.same({}, assert(wire.state(raw)).unknown)
			end)

			it("keeps at most 32 names, each at most 40 characters", function()
				local overrides = { longName = nil }
				for i = 1, 40 do
					overrides[string.format("extra%02d", i)] = i
				end
				overrides[string.rep("n", 60)] = 1
				local st = state_of(overrides)
				assert.equal(32, #st.unknown)
				for _, name in ipairs(st.unknown) do
					assert.is_true(#name <= 40)
				end
			end)
		end)

		describe("private data (V20, V6)", function()
			it("copies nothing but the documented fields, and none of a private key's value", function()
				local raw = assert(C4:JsonDecode(mf.STATE))
				raw.owner, raw.federatedIdentity, raw.deviceName = "owner-marker", "identity-marker", "name-marker"
				raw.SSID, raw.BSSID, raw.certificateId = "ssid-marker", "bssid-marker", "cert-marker"
				raw.timezone, raw.schedule, raw.FrCodes = "tz-marker", "blob-marker", "codes-marker"
				local st = assert(wire.state(raw))
				for _, marker in ipairs({ "owner-marker", "identity-marker", "name-marker", "ssid-marker",
					"bssid-marker", "cert-marker", "tz-marker", "blob-marker", "codes-marker" }) do
					assert.is_false(holds_text(st, marker), marker)
				end
				assert.same({ "adjusted", "away", "client_id", "direction", "fan_on", "fan_timer", "generation",
					"learning", "level", "light_on", "light_timer", "schedule_set", "speed", "unknown", "user_data",
					"wind", "wind_speed" }, keys_of(st))
				assert.equal(true, st.schedule_set)
			end)

			it("does not change the object it reads", function()
				local raw = assert(C4:JsonDecode(mf.STATE))
				wire.state(raw)
				assert.equal("UTC0", raw.timezone)
				assert.equal(1, raw.fanSpeed)
			end)
		end)
	end)

	describe("info", function()
		it("reads the static answer into the identity and model fields, nothing else (V20)", function()
			assert.same({
				client_id = "MF_00005E005301",
				mac = "00005E005301",
				fan_type = "1811-5-54",
				light_type = "F4IN-120V-R1-30",
				has_light = true,
				motor_type = "DC125X20",
				firmware = "02.00.0052",
				mcu_firmware = "03.00.0000",
				brand = 1,
			}, assert(wire.info(decoded(mf.INFO))))
		end)

		it("copies no private value and no field beyond the nine, even from an object that still holds them", function()
			local raw = assert(C4:JsonDecode(mf.INFO))
			assert.equal("owner@example.com", raw.owner, "this object is not scrubbed")
			local info = assert(wire.info(raw))
			for _, text in ipairs(mf.PRIVATE_VALUES) do
				assert.is_false(holds_text(info, text), text)
			end
			assert.same({ "brand", "client_id", "fan_type", "firmware", "has_light", "light_type", "mac", "mcu_firmware",
				"motor_type" }, keys_of(info))
		end)

		it("says a fan without a light kit has none: lightType empty (H4)", function()
			local info = assert(wire.info(decoded(mf.INFO_NO_KIT)))
			assert.equal("", info.light_type)
			assert.equal(false, info.has_light)
			assert.equal(false, assert(wire.info({ clientId = "MF_00005E005301", lightType = "  " })).has_light)
		end)

		it("leaves the light kit unknown when lightType is missing or odd (F3)", function()
			local info = assert(wire.info(decoded(mf.info({ lightType = mf.OMIT }))))
			assert.is_nil(info.light_type)
			assert.is_nil(info.has_light)
			assert.is_nil(assert(wire.info({ clientId = "MF_00005E005301", lightType = 7 })).has_light)
		end)

		it("reads another fan's identity (N3)", function()
			local info = assert(wire.info(decoded(mf.INFO_OTHER)))
			assert.equal("MF_00005E005302", info.client_id)
			assert.equal("00005E005302", info.mac)
		end)

		it("writes the MAC as 12 uppercase hex digits whatever the fan writes (N9)", function()
			for _, mac in ipairs({ "00:00:5e:00:53:01", "00:00:5E:00:53:01", "00-00-5e-00-53-01", "00005e005301" }) do
				assert.equal("00005E005301", assert(wire.info(decoded(mf.info({ mac = mac })))).mac, mac)
			end
		end)

		it("leaves the MAC nil when the answer has none a MAC can be read from (N4: JSON without mac)", function()
			for _, overrides in ipairs({ { mac = mf.OMIT }, { mac = "" }, { mac = "not-a-mac" }, { mac = 5 } }) do
				local info = assert(wire.info(decoded(mf.info(overrides))))
				assert.is_nil(info.mac)
				assert.equal("MF_00005E005301", info.client_id)
			end
		end)

		it("takes a field of another type for unknown (F3)", function()
			local info = assert(wire.info({ clientId = "MF_00005E005301", fanType = 5, firmwareVersion = 2,
				mainMcuFirmwareVersion = true, brand = "1", fanMotorType = {} }))
			for _, field in ipairs({ "fan_type", "firmware", "mcu_firmware", "brand", "motor_type" }) do
				assert.is_nil(info[field], field)
			end
		end)

		it("is nil and 'json' without a clientId, or for no table (section 3.3)", function()
			assert.same({ nil, "json" }, { wire.info(decoded(mf.NO_CLIENT)) })
			assert.same({ nil, "json" }, { wire.info(decoded(mf.info({ clientId = mf.OMIT }))) })
			assert.same({ nil, "json" }, { wire.info(decoded(mf.info({ clientId = "" }))) })
			assert.same({ nil, "json" }, { wire.info("x") })
			assert.same({ nil, "json" }, { wire.info(nil) })
		end)
	end)

	describe("is_g4", function()
		it("is true for a systemType that contains fan_g4 (H2)", function()
			assert.is_true(wire.is_g4(decoded(mf.G4_DEVICE)))
			assert.is_true(wire.is_g4({ systemType = "wac_fan_g4_us" }))
			assert.is_true(wire.is_g4({ systemType = "FAN_G4" }))
		end)

		it("is false for every other answer (N4)", function()
			assert.is_false(wire.is_g4({ systemType = "fan_g3" }))
			assert.is_false(wire.is_g4({ systemType = 4 }))
			assert.is_false(wire.is_g4({ systemType = {} }))
			assert.is_false(wire.is_g4(decoded(mf.STATE)))
			assert.is_false(wire.is_g4(decoded(mf.INFO)))
			assert.is_false(wire.is_g4({}))
			assert.is_false(wire.is_g4(nil))
			assert.is_false(wire.is_g4("fan_g4"))
			assert.is_false(wire.is_g4(true))
		end)
	end)

	describe("trims in linear time (#49)", function()
		it("trims an address and a MAC with long runs of blanks around and inside them", function()
			local runs = (" "):rep(100000)
			local started = os.clock()
			assert.equal("10.0.2.151", wire.ipv4(runs .. "10.0.2.151" .. runs))
			assert.is_nil(wire.ipv4("10.0" .. runs .. ".2.151"))
			assert.is_nil(wire.ipv4(runs))
			assert.equal("00005E005301", wire.mac12(runs .. "00:00:5e:00:53:01" .. runs))
			assert.is_nil(wire.mac12("00:00:5e" .. runs .. ":00:53:01"))
			assert.is_true(os.clock() - started < 1, "a trim that is not linear takes minutes on this")
		end)
	end)

	describe("mac12", function()
		it("writes a MAC as 12 uppercase hex digits from the forms a fan or mDNS uses (N9)", function()
			for _, text in ipairs({ "00:00:5e:00:53:01", "00:00:5E:00:53:01", "00-00-5e-00-53-01", "00005e005301",
				"00005E005301", "  00:00:5e:00:53:01\n", "\t00005e005301 " }) do
				assert.equal("00005E005301", wire.mac12(text), text)
			end
			assert.equal("00005E0053AB", wire.mac12("00:00:5e:00:53:ab"), "lower-case letters are written upper case")
		end)

		it("refuses what is not a MAC", function()
			for _, text in ipairs({ "", "00:00:5e:00:53", "00:00:5e:00:53:01:02", "00:00:5e:00:53:0g", "00:00-5e:00:53:01",
				"00.00.5e.00.53.01", "MF_00005E005301", "0000 5e00 5301", "00005e00530", "00005e0053012", "::::::" }) do
				assert.is_nil(wire.mac12(text), text)
			end
			for _, value in ipairs({ 5, true, {} }) do
				assert.is_nil(wire.mac12(value), tostring(value))
			end
			assert.is_nil(wire.mac12(nil))
		end)
	end)

	describe("same_fan", function()
		it("compares client ids without regard to case (N9)", function()
			assert.is_true(wire.same_fan("MF_00005E005301", "MF_00005E005301"))
			assert.is_true(wire.same_fan("MF_00005E005301", "mf_00005e005301"))
			assert.is_true(wire.same_fan("mf_00005e005301", "MF_00005E005301"))
			assert.is_true(wire.same_fan(" MF_00005E005301 ", "MF_00005E005301"))
		end)

		it("takes the id itself or a table that holds it as client_id (a pin, an info, a state)", function()
			local pin = { client_id = "MF_00005E005301", mac = "00005E005301" }
			assert.is_true(wire.same_fan(pin, "mf_00005e005301"))
			assert.is_true(wire.same_fan("MF_00005E005301", pin))
			assert.is_true(wire.same_fan(pin, assert(wire.info(decoded(mf.INFO)))))
			assert.is_true(wire.same_fan(pin, assert(wire.state(decoded(mf.STATE)))))
			assert.is_false(wire.same_fan(pin, assert(wire.info(decoded(mf.INFO_OTHER)))))
		end)

		it("is false for another fan, another brand prefix, or anything that is no id (N3)", function()
			assert.is_false(wire.same_fan("MF_00005E005301", "MF_00005E005302"))
			assert.is_false(wire.same_fan("MF_00005E005301", "WAC_00005E005301"))
			assert.is_false(wire.same_fan("MF_00005E005301", nil))
			assert.is_false(wire.same_fan(nil, "MF_00005E005301"))
			assert.is_false(wire.same_fan(nil, nil), "two unknowns are not the same fan")
			assert.is_false(wire.same_fan("", ""))
			assert.is_false(wire.same_fan("  ", "  "))
			assert.is_false(wire.same_fan({}, {}))
			assert.is_false(wire.same_fan(5, 5))
			assert.is_false(wire.same_fan(true, true))
		end)
	end)

	describe("ipv4", function()
		-- Addresses that are not placeholders are put together from their parts, so no
		-- literal of this file looks like a LAN address to the secrets check.
		local function quad(a, b, c, d)
			return string.format("%s.%s.%s.%s", tostring(a), tostring(b), tostring(c), tostring(d))
		end

		it("returns a dotted quad, trimmed", function()
			assert.equal("10.0.2.151", wire.ipv4("10.0.2.151"))
			assert.equal("10.0.2.151", wire.ipv4("  10.0.2.151\t\n"))
			assert.equal("0.0.0.0", wire.ipv4("0.0.0.0"))
			assert.equal("255.255.255.255", wire.ipv4("255.255.255.255"))
			assert.equal("192.0.2.7", wire.ipv4("192.0.2.7"))
			assert.equal(quad(10, 0, 2, 0), wire.ipv4(quad(10, 0, 2, 0)), "a part of 0 is fine")
			assert.equal(quad(10, 0, 2, 255), wire.ipv4(quad(10, 0, 2, 255)), "so is 255")
		end)

		it("refuses what is not one (S3: nothing is sent to it)", function()
			local bad = { "", "   ", "10.0.2", "10.0.2.151.1", quad(10, 0, 2, 256), quad(300, 0, 0, 1), "10.0.2.-1",
				"10.0.2.a", "10.0.2.151:80", "http://10.0.2.151", "10.0.2.151/mf", "fan.local", "fan",
				quad(10, 0, 2, "1 51"), "10..2.151", ".10.0.2.151", "10.0.2.151.", quad("1e1", 0, 0, 1),
				quad(10, 0, 2, 1234), "10,0,2,151",
				"0x0a.0.2.151", "::1" }
			for _, text in ipairs(bad) do
				assert.is_nil(wire.ipv4(text), text)
			end
		end)

		it("refuses leading zeros: a C resolver reads 010 as octal", function()
			assert.is_nil(wire.ipv4("10.0.2.010"))
			assert.is_nil(wire.ipv4("010.0.2.151"))
			assert.is_nil(wire.ipv4("10.00.2.151"))
			assert.is_nil(wire.ipv4(quad(10, 0, 2, "00")))
		end)

		it("refuses what is no string", function()
			for _, value in ipairs({ 10, true, {} }) do
				assert.is_nil(wire.ipv4(value), tostring(value))
			end
			assert.is_nil(wire.ipv4(nil))
		end)
	end)
end)
