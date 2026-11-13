-- fan.texts: every owner-visible string of the driver, verbatim from the v1
-- contract's section 7 (docs/v1-design.md), for the fan's name and the rename
-- job's answers from docs/fan-name-design.md 2.3, and for the Found Fans rows,
-- S2, L7, L21 and L32 from docs/auto-discovery-design.md sections 3 and 5, and
-- for Breeze's S5 forms, L33 to L41 and the 13 links from
-- docs/breeze-design.md sections 5 and 11 (BF-D2, BF-D10), and for S5 with a
-- Light Min On from docs/min-on-design.md MO-D11. The module is pure, so nothing here needs the fake
-- runtime. Times are built from
-- local-time fields, so the specs hold in any time zone.
--
-- texts.lua requires fan.names, the table of fan types and their names. This
-- spec is about wording, not about the table (names_spec.lua owns that), so
-- texts is loaded once against a fake of names' interface (fan-name-design
-- 2.1) and both module entries go back at once: the fake is bound inside this
-- instance of texts, and every other spec requires the real fan.names and its
-- own fan.texts. Which types the fake knows is up to each test through KNOWN;
-- it knows none by default, so every older Fan Model example shows the text
-- of a type without a name, as before the feature.

local KNOWN = {}
local fake_names = {
	-- A trimmed exact match, nil for anything else (fan-name-design 2.1).
	lookup = function(fan_type)
		if type(fan_type) ~= "string" then
			return nil
		end
		return KNOWN[(fan_type:match("^%s*(.-)%s*$"))]
	end,
	light = function(name)
		return name and (name .. " Light") or nil
	end,
}
local FAKE_LOOKUP = fake_names.lookup

local saved_names, saved_texts = package.loaded["fan.names"], package.loaded["fan.texts"]
package.loaded["fan.names"], package.loaded["fan.texts"] = fake_names, nil
local loaded, texts = pcall(require, "fan.texts")
package.loaded["fan.names"], package.loaded["fan.texts"] = saved_names, saved_texts
assert(loaded, texts)

local ADDR = "10.0.2.151"
local ADDR2 = "10.0.2.152"
local ID1 = "MF_00005E005301"
local ID2 = "MF_00005E005302"
local MAC1 = "00005E005301"

-- Seconds for a local date and time, as os.time reads it.
local function at(year, month, day, hour, min, sec)
	return os.time({ year = year, month = month, day = day, hour = hour, min = min, sec = sec or 0 })
end

local T = at(2026, 10, 27, 14, 2) -- shown as 14:02
local SOON = T + 600 -- ten minutes later: a clock time is enough
local LATER = T + 90000 -- 25 h later: the date comes with it

-- The state table of section 4.1 / 9.3: the fan on at 3, the light on at 40.
local function state(over)
	local st = { fan_on = true, speed = 3, direction = "forward", wind = false, light_on = true, level = 40 }
	for key, value in pairs(over or {}) do
		st[key] = value
	end
	return st
end

local function online(over)
	local v = { phase = "online", address = ADDR, st = state(), has_light = true, now = SOON }
	for key, value in pairs(over or {}) do
		v[key] = value
	end
	return v
end

describe("fan.texts", function()
	-- A test that taught the fake table a type or swapped its lookup leaves
	-- nothing behind for the next one.
	after_each(function()
		for fan_type in pairs(KNOWN) do
			KNOWN[fan_type] = nil
		end
		fake_names.lookup = FAKE_LOOKUP
	end)

	describe("the interface of section 9.6 and fan-name-design 2.3", function()
		it("offers every function the contract lists", function()
			for _, name in ipairs({ "status", "result", "fan_id", "fan_model", "firmware", "last_seen", "change_by",
				"automations", "keypad_links", "found_rows", "suffix", "mac", "clock", "rename_suffix", "clean" }) do
				assert.is_function(texts[name], name)
			end
		end)

		-- auto-discovery-design 5 and 6.4: the Find Fans action went, and with it
		-- its texts and the find_fans fields.
		it("has no Find Fans function or result any more", function()
			assert.is_nil(texts.found_fans)
			for _, key in ipairs({ "found", "found_none", "find_failed" }) do
				assert.equal("", texts.result(key, { count = 2, list = { {} }, address = ADDR }), key)
				for _, listed in ipairs(texts.RESULT_KEYS) do
					assert.not_equal(key, listed)
				end
			end
		end)

		it("lists the 18 result keys of section 9.6 left after L8 to L10, the 8 of fan-name-design 2.3, the 2 of"
			.. " address-follow-design 2.4, L32 of auto-discovery-design 5, the 8 of breeze-design 5, L41 of"
			.. " BF-D10, L42 of breeze-leds-design BL-D3 and L43 of speed-leds-design SL-D9, L44 and L45 of"
			.. " keypad-leds-visibility-design KL-D7, and L46 of #214, each with a text of its own", function()
			assert.equal(43, #texts.RESULT_KEYS)
			assert.same({ "learned", "moved", "now_using", "already", "no_answer", "not_a_fan", "nothing_to_use",
				"reboot_sent", "reboot_offline", "reboot_refused", "reboot_pending", "away_off", "away_already",
				"learning_off", "learning_already", "not_answering", "not_taken", "not_picked" },
				{ unpack(texts.RESULT_KEYS, 1, 18) })
			assert.same({ "name_renamed", "name_same", "name_unknown", "name_no_type", "name_no_ids", "name_unconfirmed",
				"name_no_pin", "name_busy", "followed", "follow_refused", "picked_wait" }, { unpack(texts.RESULT_KEYS, 19, 29) })
			assert.same({ "breeze_unavailable", "breeze_strength", "breeze_refused", "breeze_switch_added",
				"breeze_switch_exists", "breeze_switch_no_breeze", "breeze_switch_no_fan", "breeze_switch_failed",
				"breeze_old_switch", "breeze_leds_need_per_speed", "speed_leds_need_per_speed", "keypad_leds_shown",
				"keypad_leds_hidden", "breeze_fan_not_connected" }, { unpack(texts.RESULT_KEYS, 30) })
			local seen = {}
			for _, key in ipairs(texts.RESULT_KEYS) do
				local text = texts.result(key, { client_id = ID1, address = ADDR, which = "away", at = T,
					fan = "Sample", light = "Sample Light", fan_type = "1811-5-54", instance = "MF_Fan_005302" })
				assert.is_true(#text > 0, key)
				assert.is_nil(seen[text], key .. " repeats another key's text")
				seen[text] = true
			end
		end)

		-- fan/texts.lua on the module path.
		local function module_path()
			for template in package.path:gmatch("[^;]+") do
				local candidate = template:gsub("%?", "fan/texts")
				local file = io.open(candidate, "r")
				if file then
					file:close()
					return candidate
				end
			end
		end

		-- The one require is fan.names, on a line of its own (fan-name-design 2.3).
		it("is pure: no line of code names Director, a log, the clock or a require but fan.names", function()
			local path = assert(module_path(), "fan/texts.lua is on the path")
			local file = assert(io.open(path, "r"))
			local number = 0
			local requires = 0
			for line in file:lines() do
				number = number + 1
				if not line:match("^%s*%-%-") then
					for _, forbidden in ipairs({ "C4", "Properties", "PersistGetValue", "print", "log%.", "os%.time",
						"os%.clock", "os%.getenv", "io%.", "loadstring", "dofile" }) do
						assert.is_nil(line:find(forbidden), path .. ":" .. number .. " uses " .. forbidden .. ": " .. line)
					end
					if line:find("require", 1, true) then
						requires = requires + 1
						assert.equal('local names = require("fan.names")', line, path .. ":" .. number)
					end
				end
			end
			file:close()
			assert.equal(1, requires, "fan.names is the only module texts.lua requires")
		end)

		it("is pure: it runs with the standard library and fan.names alone, no C4, no print, no other require", function()
			local path = assert(module_path(), "fan/texts.lua is on the path")
			local sandbox = {}
			for _, name in ipairs({ "assert", "error", "ipairs", "math", "next", "os", "pairs", "pcall", "select",
				"string", "table", "tonumber", "tostring", "type", "unpack" }) do
				sandbox[name] = _G[name]
			end
			local asked = {}
			sandbox.require = function(name)
				asked[#asked + 1] = name
				if name ~= "fan.names" then
					error("fan/texts.lua asked for " .. tostring(name))
				end
				return fake_names
			end
			local chunk = assert(loadfile(path))
			setfenv(chunk, sandbox)
			local pure = chunk()
			assert.same({ "fan.names" }, asked)
			assert.equal("Waiting for the fan at " .. ADDR, pure.status({ phase = "waiting", address = ADDR }))
			assert.equal("Away mode is already off", pure.result("away_already"))
			assert.equal("None", pure.automations({}))
			assert.equal("14:02", pure.clock(T, SOON))
			KNOWN["1811-5-54"] = "Aviator 5"
			assert.equal("Gen 3, Aviator 5 (1811-5-54), no light kit", pure.fan_model({ generation = "3" },
				{ fan_type = "1811-5-54" }))
			assert.equal("; items renamed", pure.rename_suffix("renamed"))
		end)
	end)

	describe("status (section 7.1)", function()
		-- auto-discovery-design 5: S2 points at the list that fills by itself; S1
		-- is for a list that is failing (no search possible on this controller).
		describe("S1 to S3: no usable address", function()
			local S1 = "Not set up: enter the fan's address in Fan Address"
			local S2 = "Not set up: pick a fan in Found Fans, or enter Fan Address"

			it("S2 not set up: the contract's text, 58 characters", function()
				assert.equal(S2, texts.status({ phase = "unset" }))
				assert.equal(58, #S2)
				assert.equal(S2, texts.status({ phase = "unset", failing = false }))
			end)

			it("S1 not set up, while the Found Fans list is failing", function()
				assert.equal(S1, texts.status({ phase = "unset", failing = true }))
			end)

			it("only failing = true picks S1; anything else is S2", function()
				for _, other in ipairs({ false, "yes", 1, {}, "true" }) do
					assert.equal(S2, texts.status({ phase = "unset", failing = other }), tostring(other))
				end
			end)

			it("no longer reads find_fans", function()
				assert.equal(S2, texts.status({ phase = "unset", find_fans = true }))
				assert.equal(S2, texts.status({ phase = "unset", find_fans = false }))
				assert.equal(S1, texts.status({ phase = "unset", find_fans = true, failing = true }))
			end)

			it("S3 names what was typed", function()
				assert.equal('Fan Address "fan.local" is not an IPv4 address',
					texts.status({ phase = "unset", typed = "fan.local" }))
				assert.equal('Fan Address "10.0.2" is not an IPv4 address',
					texts.status({ phase = "unset", typed = "10.0.2" }), "S3 over S2")
				assert.equal('Fan Address "10.0.2" is not an IPv4 address',
					texts.status({ phase = "unset", typed = "10.0.2", failing = true }), "S3 over S1")
			end)

			it("S3 cuts the typed text to 24 characters, no marker", function()
				local typed = "abcdefghijklmnopqrstuvwxyz"
				assert.equal('Fan Address "abcdefghijklmnopqrstuvwx" is not an IPv4 address',
					texts.status({ phase = "unset", typed = typed }))
				assert.equal('Fan Address "abcdefghijklmnopqrstuvwx" is not an IPv4 address',
					texts.status({ phase = "unset", typed = "abcdefghijklmnopqrstuvwx" }), "24 stay whole")
			end)

			it("S3 trims what was typed, and an empty or blank text is S1 or S2", function()
				assert.equal('Fan Address "fan.local" is not an IPv4 address',
					texts.status({ phase = "unset", typed = "  fan.local \t" }))
				assert.equal(S1, texts.status({ phase = "unset", typed = "   ", failing = true }))
				assert.equal(S2, texts.status({ phase = "unset", typed = "" }))
				assert.equal(S2, texts.status({ phase = "unset", typed = "   " }))
			end)

			it("S3 shows every byte outside printable ASCII as ?", function()
				assert.equal('Fan Address "caf??.local" is not an IPv4 address',
					texts.status({ phase = "unset", typed = "caf\195\169.local" }))
				assert.equal('Fan Address "a?b?c" is not an IPv4 address',
					texts.status({ phase = "unset", typed = "a\1b\127c" }))
			end)

			it("S3 keeps all of printable ASCII, the space and the tilde at its ends", function()
				assert.equal('Fan Address "a b~!c?d?" is not an IPv4 address',
					texts.status({ phase = "unset", typed = "a b~!c\31d\127" }))
			end)

			it("S3 for a phase that keeps the not-IPv4 case apart from unset", function()
				assert.equal('Fan Address "x" is not an IPv4 address', texts.status({ phase = "invalid", typed = "x" }))
				assert.equal('Fan Address "x" is not an IPv4 address',
					texts.status({ phase = "invalid address", typed = "x" }))
			end)
		end)

		it("S4 waiting for the fan", function()
			assert.equal("Waiting for the fan at 10.0.2.151", texts.status({ phase = "waiting", address = ADDR }))
		end)

		describe("S5 online: the grammar of section 7.1", function()
			it("the fan at a speed, the light at a level", function()
				assert.equal("Online: fan speed 3, light 40 %", texts.status(online()))
			end)

			it("the fan off, the light off", function()
				local v = online({ st = state({ fan_on = false, light_on = false }) })
				assert.equal("Online: fan off, light off", texts.status(v))
			end)

			-- breeze-design BF-D1 and BF-D2: three states of one motor. Breeze
			-- mode (`fan_on` and `wind`, BZ1) shows the strength alone.
			it("reverse follows the speed in fan mode", function()
				assert.equal("Online: fan speed 2 reverse, light 40 %",
					texts.status(online({ st = state({ speed = 2, direction = "reverse" }) })))
				assert.equal("Online: fan speed 6 reverse, light 100 %",
					texts.status(online({ st = state({ speed = 6, direction = "reverse", level = 100 }) })))
			end)

			it("Breeze mode is the strength alone, no fan speed: Online: Breeze 2, light off", function()
				assert.equal("Online: Breeze 2, light off",
					texts.status(online({ st = state({ wind = true, wind_speed = 2, light_on = false }) })))
				for strength = 1, 3 do
					assert.equal("Online: Breeze " .. strength .. ", light 40 %",
						texts.status(online({ st = state({ speed = 5, wind = true, wind_speed = strength }) })))
				end
				assert.equal("Online: Breeze 1, light 40 %",
					texts.status(online({ st = { fan_on = true, wind = true, wind_speed = 1, light_on = true, level = 40 } })),
					"no speed known")
				assert.equal("Online: Breeze 2, no light kit",
					texts.status(online({ has_light = false, st = state({ wind = true, wind_speed = 2 }) })))
			end)

			it("Breeze mode shows no reverse marker: the direction does not matter there", function()
				assert.equal("Online: Breeze 3, light 100 %",
					texts.status(online({ st = state({ speed = 6, direction = "reverse", wind = true, wind_speed = 3,
						level = 100 }) })))
			end)

			it("Breeze mode with no strength known, or one that is not 1 to 3, shows no number", function()
				for _, odd in ipairs({ false, 0, 4, 2.5, -1, 1e308, 0 / 0, math.huge, "x", "", {} }) do
					assert.equal("Online: Breeze, light 40 %",
						texts.status(online({ st = state({ wind = true, wind_speed = odd }) })), tostring(odd))
				end
				assert.equal("Online: Breeze, light 40 %", texts.status(online({ st = state({ wind = true }) })))
				assert.equal("Online: Breeze, light 40 %",
					texts.status(online({ st = state({ speed = 1, direction = "reverse", wind = true }) })))
				assert.equal("Online: Breeze 2, light 40 %",
					texts.status(online({ st = state({ wind = true, wind_speed = "2" }) })), "a number as text")
			end)

			it("stopped with a stored wind: fan off, then reverse, then Breeze set; the strength is not shown", function()
				assert.equal("Online: fan off Breeze set, light off",
					texts.status(online({ st = state({ fan_on = false, wind = true, wind_speed = 2, light_on = false }) })))
				assert.equal("Online: fan off reverse Breeze set, light 40 %",
					texts.status(online({ st = state({ fan_on = false, direction = "reverse", wind = true }) })))
			end)

			it("Breeze with the fan's on/off unknown is the bare flag", function()
				assert.equal("Online: fan unknown Breeze, light unknown",
					texts.status(online({ st = { wind = true, wind_speed = 2 } })))
				assert.equal("Online: fan unknown reverse Breeze, light unknown",
					texts.status(online({ st = { direction = "reverse", wind = true } })))
			end)

			it("a strength without wind adds nothing", function()
				assert.equal("Online: fan speed 3, light 40 %",
					texts.status(online({ st = state({ wind = false, wind_speed = 2 }) })))
				assert.equal("Online: fan off, light 40 %",
					texts.status(online({ st = state({ fan_on = false, wind_speed = 3 }) })))
			end)

			it("a fan without Breeze (wind nil) reads as in 1.2", function()
				assert.equal("Online: fan speed 4 reverse, light 40 %",
					texts.status(online({ st = state({ speed = 4, direction = "reverse", wind = nil }) })))
				assert.equal("Online: fan off, light off",
					texts.status(online({ st = state({ fan_on = false, wind = nil, light_on = false }) })))
				assert.equal("Online: fan on, light 40 %",
					texts.status(online({ st = { fan_on = true, light_on = true, level = 40 } })))
				assert.equal("Online: fan unknown, light unknown", texts.status(online({ st = {} })))
			end)

			it("forward and Breeze off add nothing", function()
				local v = online({ st = state({ direction = "forward", wind = false }) })
				assert.equal("Online: fan speed 3, light 40 %", texts.status(v))
			end)

			it("a fan without a light kit says so, whatever the light fields hold", function()
				local v = online({ has_light = false, st = state({ light_on = nil, level = nil }) })
				assert.equal("Online: fan speed 3, no light kit", texts.status(v))
				assert.equal("Online: fan off, no light kit", texts.status(online({
					has_light = false, st = state({ fan_on = false, light_on = true, level = 40 }) })))
			end)

			it("every speed and the level's ends", function()
				for speed = 1, 6 do
					assert.equal("Online: fan speed " .. speed .. ", light 1 %",
						texts.status(online({ st = state({ speed = speed, level = 1 }) })))
				end
			end)

			it("an unknown part is said to be unknown, not guessed", function()
				assert.equal("Online: fan unknown, light unknown", texts.status(online({ st = {} })))
				assert.equal("Online: fan unknown, light unknown", texts.status({ phase = "online", address = ADDR }))
				assert.equal("Online: fan on, light on", texts.status(online({ st = { fan_on = true, light_on = true } })))
			end)

			it("a speed or level that is not a sane number is left out, not printed", function()
				for _, odd in ipairs({ 1e308, math.huge, -math.huge, 0 / 0, 2147483648, "many" }) do
					assert.equal("Online: fan on, light on",
						texts.status(online({ st = state({ speed = odd, level = odd }) })), tostring(odd))
				end
			end)
		end)

		-- min-on-design MO-D11 and edge cases RP1: with a Light Min On above 1,
		-- the light part names the Control4 level first and the fan's after it.
		-- st.level is the fan's level, light_level the Control4 level the light
		-- reports (light:c4_level(st)).
		describe("S5 with a Light Min On (min-on-design MO-D11)", function()
			local function min_on(m, light_level, over)
				return online({ min_on = m, light_level = light_level, st = state(over) })
			end

			it("the light on: the Control4 level, then the fan's: light 40 % (fan 52)", function()
				assert.equal("Online: fan speed 3, light 40 % (fan 52)", texts.status(min_on(20, 40, { level = 52 })))
				assert.equal("Online: fan speed 3, light 100 % (fan 100)", texts.status(min_on(20, 100, { level = 100 })))
				assert.equal("Online: fan off, light 50 % (fan 75)",
					texts.status(min_on(50, 50, { fan_on = false, level = 75 })))
				assert.equal("Online: Breeze 2, light 1 % (fan 20)",
					texts.status(min_on(20, 1, { wind = true, wind_speed = 2, level = 20 })), "the fan at the Min On is lit")
			end)

			it("a fan level below the Min On: light 1 % (fan 5, below Min On)", function()
				assert.equal("Online: fan speed 3, light 1 % (fan 5, below Min On)",
					texts.status(min_on(20, 1, { level = 5 })))
				assert.equal("Online: fan speed 3, light 1 % (fan 19, below Min On)",
					texts.status(min_on(20, 1, { level = 19 })), "one below")
				assert.equal("Online: fan speed 3, light 1 % (fan 1, below Min On)",
					texts.status(min_on(2, 1, { level = 1 })), "the smallest Min On that changes anything")
				assert.equal("Online: fan speed 3, light 1 % (fan 98, below Min On)",
					texts.status(min_on(99, 1, { level = 98 })), "the largest")
			end)

			it("below is the fan's level against the Min On, whatever the Control4 level says", function()
				assert.equal("Online: fan speed 3, light 1 % (fan 20)", texts.status(min_on(20, 1, { level = 20 })))
				assert.equal("Online: fan speed 3, light 3 % (fan 5, below Min On)",
					texts.status(min_on(20, 3, { level = 5 })), "the level given is shown, not a made-up 1 %")
			end)

			it("equal levels are still both shown while the Min On is above 1: light 40 % (fan 40)", function()
				assert.equal("Online: fan speed 3, light 40 % (fan 40)", texts.status(min_on(2, 40, { level = 40 })))
				assert.equal("Online: fan speed 3, light 100 % (fan 100)", texts.status(min_on(99, 100, { level = 100 })))
			end)

			it("a Min On of nil, 0 or 1 is the text of 1.5 exactly, the fan's level alone", function()
				for _, m in ipairs({ false, 0, 1 }) do
					local given = m or nil
					local label = tostring(given)
					assert.equal("Online: fan speed 3, light 40 %", texts.status(min_on(given, 40, { level = 40 })), label)
					assert.equal("Online: fan speed 3, light 40 %", texts.status(min_on(given, 41, { level = 40 })),
						label .. ": the fan's level, as before")
					assert.equal("Online: fan speed 3, light 1 %", texts.status(min_on(given, 1, { level = 1 })), label)
				end
				assert.equal("Online: fan speed 3, light 40 %", texts.status(online({ light_level = 40 })),
					"no min_on field")
			end)

			it("no Control4 level is the text of 1.5 exactly, whatever the Min On", function()
				assert.equal("Online: fan speed 3, light 52 %", texts.status(min_on(20, nil, { level = 52 })))
				assert.equal("Online: fan speed 3, light 5 %", texts.status(min_on(20, nil, { level = 5 })))
				assert.equal("Online: fan speed 3, light 40 %", texts.status(online({ min_on = 20 })),
					"no light_level field")
			end)

			it("off, unknown and no light kit are unchanged", function()
				assert.equal("Online: fan speed 3, light off", texts.status(min_on(20, 0, { light_on = false })))
				assert.equal("Online: fan off, light off",
					texts.status(min_on(20, 0, { fan_on = false, light_on = false, level = 5 })))
				assert.equal("Online: fan speed 3, light unknown", texts.status(min_on(20, 40, { light_on = "x" })))
				assert.equal("Online: fan unknown, light unknown",
					texts.status(online({ min_on = 20, light_level = 40, st = {} })))
				assert.equal("Online: fan speed 3, no light kit",
					texts.status(online({ min_on = 20, light_level = 40, has_light = false, st = state({ level = 52 }) })))
			end)

			it("a light on at an unknown fan level is 'light on', as in 1.5", function()
				assert.equal("Online: fan on, light on",
					texts.status(online({ min_on = 20, light_level = 40, st = { fan_on = true, light_on = true } })))
				assert.equal("Online: fan on, light on",
					texts.status(online({ min_on = 20, st = { fan_on = true, light_on = true } })))
			end)

			it("a Min On that is not 2 to 99 once rounded leaves the text of 1.5", function()
				for _, odd in ipairs({ 1.4, -5, 99.5, 100, 150, 0 / 0, math.huge, -math.huge, 1e308, "x", "", {}, true }) do
					assert.equal("Online: fan speed 3, light 52 %", texts.status(min_on(odd, 40, { level = 52 })),
						tostring(odd))
				end
				assert.equal("Online: fan speed 3, light 40 % (fan 52)", texts.status(min_on(1.5, 40, { level = 52 })),
					"1.5 rounds half up to 2")
				assert.equal("Online: fan speed 3, light 40 % (fan 52)", texts.status(min_on("20", 40, { level = 52 })),
					"a number as text")
			end)

			it("a Control4 or fan level that is not 0 to 100 leaves the text of 1.5", function()
				for _, odd in ipairs({ -1, 101, 1e308, 0 / 0, math.huge, "many", {}, true }) do
					assert.equal("Online: fan speed 3, light 52 %", texts.status(min_on(20, odd, { level = 52 })),
						"light_level " .. tostring(odd))
				end
				assert.equal("Online: fan speed 3, light 150 %", texts.status(min_on(20, 40, { level = 150 })),
					"a fan level over 100")
				assert.equal("Online: fan speed 3, light on", texts.status(min_on(20, 40, { level = 0 / 0 })))
				assert.equal("Online: fan speed 3, light 40 % (fan 52)",
					texts.status(min_on(20, 39.6, { level = 52.4 })), "rounded half up, as every level")
			end)

			it("the longest rows stay within 70 characters", function()
				local longest = texts.status(min_on(99, 1,
					{ fan_on = false, direction = "reverse", wind = true, level = 98 }))
				assert.equal("Online: fan off reverse Breeze set, light 1 % (fan 98, below Min On)", longest)
				assert.equal(68, #longest)
				local unknown = texts.status(online({ min_on = 99, light_level = 1,
					st = { direction = "reverse", wind = true, light_on = true, level = 98 } }))
				assert.equal("Online: fan unknown reverse Breeze, light 1 % (fan 98, below Min On)", unknown)
				assert.equal(68, #unknown)
				assert.equal("Online: fan speed 6 reverse, light 100 % (fan 100)",
					texts.status(min_on(20, 100, { speed = 6, direction = "reverse", level = 100 })))
			end)

			it("every Min On and fan level: below exactly under the Min On, and never over 70 characters", function()
				local base = { fan_on = false, direction = "reverse", wind = true }
				for m = 2, 99 do
					for f = 1, 100 do
						base.level = f
						for _, shown in ipairs({ 1, 50, 100 }) do
							local text = texts.status(min_on(m, shown, base))
							local tail = f < m and ", below Min On)" or ")"
							local want = "Online: fan off reverse Breeze set, light " .. shown .. " % (fan " .. f .. tail
							-- Asserted only on a miss: 29 400 asserts would swamp busted's output.
							if text ~= want then
								assert.equal(want, text, "Min On " .. m .. ", fan " .. f)
							end
							if #text > 70 then
								assert.is_true(#text <= 70, text)
							end
						end
					end
				end
			end)

			it("S6 and S14 still outrank it", function()
				assert.equal("Online, but the fan reports no lightBrightness; light control paused",
					texts.status(online({ min_on = 20, light_level = 40, missing = "lightBrightness" })))
				assert.equal("Controller OS 3.2.1 is older than 3.3.0; the light may misbehave",
					texts.status(online({ min_on = 20, light_level = 40, os = "3.2.1" })))
			end)
		end)

		describe("S6 online with a needed field missing (ECM F3)", function()
			local cases = {
				{ "fanSpeed", "speed" }, { "fanOn", "speed" }, { "fanDirection", "direction" },
				{ "lightOn", "light" }, { "lightBrightness", "light" },
			}
			for _, case in ipairs(cases) do
				it("names " .. case[1] .. " and pauses " .. case[2] .. " control", function()
					assert.equal("Online, but the fan reports no " .. case[1] .. "; " .. case[2] .. " control paused",
						texts.status(online({ missing = case[1] })))
				end)
			end

			it("the contract's example", function()
				assert.equal("Online, but the fan reports no fanSpeed; speed control paused",
					texts.status(online({ missing = "fanSpeed" })))
			end)

			it("takes the first of a list of missing keys", function()
				assert.equal("Online, but the fan reports no fanDirection; direction control paused",
					texts.status(online({ missing = { "fanDirection", "lightOn" } })))
			end)

			it("a key outside the list is named without claiming a pause", function()
				assert.equal("Online, but the fan reports no wind", texts.status(online({ missing = "wind" })))
			end)

			it("an empty list or an empty key is S5", function()
				assert.equal("Online: fan speed 3, light 40 %", texts.status(online({ missing = {} })))
				assert.equal("Online: fan speed 3, light 40 %", texts.status(online({ missing = "" })))
			end)
		end)

		describe("S7 to S9 offline", function()
			local function offline(over)
				local v = { phase = "offline", address = ADDR, since = T, now = SOON, known = true, failure = "timeout" }
				for key, value in pairs(over or {}) do
					v[key] = value
				end
				return v
			end

			it("S7 not answering, a state known", function()
				assert.equal("Not answering at 10.0.2.151 since 14:02; showing last state", texts.status(offline()))
			end)

			it("S8 not answering, no state known in this run", function()
				assert.equal("Not answering at 10.0.2.151 since 14:02; state unknown",
					texts.status(offline({ known = false })))
				local unset = offline()
				unset.known = nil
				assert.equal("Not answering at 10.0.2.151 since 14:02; state unknown", texts.status(unset))
			end)

			it("S9 no usable answer, with and without a state", function()
				assert.equal("No usable answer from 10.0.2.151 since 14:02; showing last state",
					texts.status(offline({ failure = "data" })))
				assert.equal("No usable answer from 10.0.2.151 since 14:02; state unknown",
					texts.status(offline({ failure = "data", known = false })))
			end)

			it("timeouts and refusals are S7 and S8 whatever their name", function()
				for _, failure in ipairs({ "timeout", "connect", "http", "refused", false }) do
					assert.equal("Not answering at 10.0.2.151 since 14:02; showing last state",
						texts.status(offline({ failure = failure })), tostring(failure))
				end
				assert.equal("Not answering at 10.0.2.151 since 14:02; showing last state",
					texts.status(offline({ failure = nil })))
			end)

			it("the time gets its date once it is more than 24 h old", function()
				assert.equal("Not answering at 10.0.2.151 since 14:02; showing last state",
					texts.status(offline({ now = T + 86400 })), "exactly 24 h is not older")
				assert.equal("Not answering at 10.0.2.151 since 10-27 14:02; showing last state",
					texts.status(offline({ now = LATER })))
				assert.equal("No usable answer from 10.0.2.151 since 10-27 14:02; state unknown",
					texts.status(offline({ now = LATER, failure = "data", known = false })))
			end)

			it("without a time the since clause is left out", function()
				assert.equal("Not answering at 10.0.2.151; showing last state", texts.status(offline({ since = false })))
				assert.equal("No usable answer from 10.0.2.151; state unknown",
					texts.status(offline({ since = "x", failure = "data", known = false })))
			end)
		end)

		it("S10 rebooting, with the time the reboot was sent", function()
			assert.equal("Rebooting the fan's Wi-Fi module (sent 14:02)",
				texts.status({ phase = "rebooting", sent = T, now = SOON }))
			assert.equal("Rebooting the fan's Wi-Fi module (sent 10-27 14:02)",
				texts.status({ phase = "rebooting", sent = T, now = LATER }))
			assert.equal("Rebooting the fan's Wi-Fi module", texts.status({ phase = "rebooting" }))
		end)

		describe("S11 another fan answers", function()
			it("names it by the last four digits of its MAC, never in full", function()
				local s = texts.status({ phase = "foreign", other = ID2, address = ADDR })
				assert.equal("Another fan (...5302) answers at 10.0.2.151; nothing is sent", s)
				assert.is_nil(s:find("00005E", 1, true))
			end)

			it("whatever form the other fan's id comes in", function()
				for _, other in ipairs({ ID2, "WAC_00005E005302", "00005E005302", "00:00:5e:00:53:02" }) do
					assert.equal("Another fan (...5302) answers at 10.0.2.151; nothing is sent",
						texts.status({ phase = "foreign", other = other, address = ADDR }), other)
				end
			end)

			it("an unknown other fan is ...?", function()
				assert.equal("Another fan (...?) answers at 10.0.2.151; nothing is sent",
					texts.status({ phase = "foreign", address = ADDR }))
			end)
		end)

		it("S12 a Gen 4 fan", function()
			assert.equal("10.0.2.151 is a Gen 4 fan; this driver controls Gen 1 to 3 only",
				texts.status({ phase = "gen4", address = ADDR }))
		end)

		it("S13 not a fan", function()
			assert.equal("10.0.2.151 answers, but not as a Modern Forms fan; nothing is sent",
				texts.status({ phase = "notfan", address = ADDR }))
		end)

		describe("S14 a controller older than 3.3.0", function()
			it("replaces S4 and S5", function()
				local text = "Controller OS 3.2.1 is older than 3.3.0; the light may misbehave"
				assert.equal(text, texts.status({ phase = "waiting", address = ADDR, os = "3.2.1" }))
				assert.equal(text, texts.status(online({ os = "3.2.1" })))
			end)

			it("shows the first three numbers of the version", function()
				assert.equal("Controller OS 3.2.1 is older than 3.3.0; the light may misbehave",
					texts.status(online({ os = "3.2.1.543210" })))
				assert.equal("Controller OS 2.10.4 is older than 3.3.0; the light may misbehave",
					texts.status(online({ os = "2.10.4" .. ".1" })))
			end)

			it("reads the table C4:GetVersionInfo returns", function()
				assert.equal("Controller OS 3.2.1 is older than 3.3.0; the light may misbehave",
					texts.status(online({ os = { version = "3.2.1.543210", buildtype = "RELEASE" } })))
			end)

			it("outranks S6, as the priority line says", function()
				assert.equal("Controller OS 3.2.1 is older than 3.3.0; the light may misbehave",
					texts.status(online({ os = "3.2.1", missing = "fanSpeed" })))
			end)

			it("is not there for 3.3.0 and newer, nor for a version it cannot read", function()
				local versions = { "3.3.0", "3.3.0" .. ".1", "3.4.2", "3.4.3" .. ".100", "3.10.0", "4.0.1", "10.0.0", "" }
				for _, os_version in ipairs(versions) do
					assert.equal("Online: fan speed 3, light 40 %", texts.status(online({ os = os_version })), os_version)
				end
				for _, os_version in ipairs({ "unknown", true, false, 3.5, {}, { version = "none" } }) do
					assert.equal("Waiting for the fan at 10.0.2.151",
						texts.status({ phase = "waiting", address = ADDR, os = os_version }), tostring(os_version))
				end
			end)

			it("os_is_old compares number by number, not as text", function()
				assert.is_true(texts.os_is_old("3.2.1"))
				assert.is_true(texts.os_is_old("3.2.99" .. ".5"))
				assert.is_true(texts.os_is_old("2.10.0"))
				assert.is_true(texts.os_is_old("3"))
				assert.is_false(texts.os_is_old("3.3"))
				assert.is_false(texts.os_is_old("3.3.0"))
				assert.is_false(texts.os_is_old("3.10.0"))
				assert.is_false(texts.os_is_old("4.0.0"))
				assert.is_false(texts.os_is_old(nil))
				assert.equal("3.3.0", texts.MIN_OS)
			end)
		end)

		describe("priority when several apply (section 7.1)", function()
			-- One view that carries every field at once; the phase picks.
			local function everything(phase)
				return {
					phase = phase, address = ADDR, typed = "fan.local", since = T, sent = T, now = SOON,
					failure = "data", known = true, other = ID2, st = state(), has_light = true,
					missing = "fanSpeed", os = "3.2.1", failing = true,
				}
			end

			it("an unusable address outranks everything: S3", function()
				assert.equal('Fan Address "fan.local" is not an IPv4 address', texts.status(everything("unset")))
			end)

			it("S1 and S2 outrank the old controller", function()
				local v = everything("unset")
				v.typed = nil
				assert.equal("Not set up: enter the fan's address in Fan Address", texts.status(v))
				v.failing = nil
				assert.equal("Not set up: pick a fan in Found Fans, or enter Fan Address", texts.status(v))
			end)

			it("another fan, Gen 4 and not a fan outrank the old controller: S11 to S13", function()
				assert.equal("Another fan (...5302) answers at 10.0.2.151; nothing is sent",
					texts.status(everything("foreign")))
				assert.equal("10.0.2.151 is a Gen 4 fan; this driver controls Gen 1 to 3 only",
					texts.status(everything("gen4")))
				assert.equal("10.0.2.151 answers, but not as a Modern Forms fan; nothing is sent",
					texts.status(everything("notfan")))
			end)

			it("rebooting outranks the old controller: S10", function()
				assert.equal("Rebooting the fan's Wi-Fi module (sent 14:02)", texts.status(everything("rebooting")))
			end)

			it("offline outranks the old controller: S7 to S9", function()
				assert.equal("No usable answer from 10.0.2.151 since 14:02; showing last state",
					texts.status(everything("offline")))
			end)

			it("the old controller outranks S4 to S6: S14", function()
				local s14 = "Controller OS 3.2.1 is older than 3.3.0; the light may misbehave"
				assert.equal(s14, texts.status(everything("waiting")))
				assert.equal(s14, texts.status(everything("online")))
			end)

			it("then S6, then S5", function()
				local v = everything("online")
				v.os = "4.0.1"
				assert.equal("Online, but the fan reports no fanSpeed; speed control paused", texts.status(v))
				v.missing = nil
				assert.equal("Online: fan speed 3, light 40 %", texts.status(v))
			end)

			it("the typed text, the other fan and the reboot time are read only in their own phase", function()
				local s = texts.status(everything("waiting"))
				assert.is_nil(s:find("fan.local", 1, true))
				assert.is_nil(s:find("5302", 1, true))
			end)
		end)

		it("an unknown or missing phase gives an empty Status, and a missing view does not raise", function()
			assert.equal("", texts.status({}))
			assert.equal("", texts.status({ phase = "somewhere else" }))
			assert.equal("", texts.status(nil))
			assert.equal("", texts.status("online"))
		end)

		it("lists the phases it understands", function()
			assert.same({ "unset", "waiting", "online", "offline", "rebooting", "foreign", "gen4", "notfan" }, texts.PHASES)
			for _, phase in ipairs(texts.PHASES) do
				assert.is_true(#texts.status({ phase = phase, address = ADDR }) > 0, phase)
			end
		end)
	end)

	describe("last action (section 7.2)", function()
		local function r(key, args)
			return texts.result(key, args)
		end

		it("L1 learned a fan: the contract's example", function()
			assert.equal("Learned fan MF_00005E005301 (Gen 3) at 10.0.2.151",
				r("learned", { client_id = ID1, generation = "3", address = ADDR }))
		end)

		it("L1 for a Gen 1/2 fan, and for a generation not known", function()
			assert.equal("Learned fan MF_00005E005301 (Gen 1/2) at 10.0.2.151",
				r("learned", { client_id = ID1, generation = "1/2", address = ADDR }))
			assert.equal("Learned fan MF_00005E005301 (Gen ?) at 10.0.2.151",
				r("learned", { client_id = ID1, address = ADDR }))
		end)

		it("L1 takes the fan from a pin, whole or in part", function()
			local pin = { client_id = ID1, mac = MAC1, generation = "3", address = ADDR }
			assert.equal("Learned fan MF_00005E005301 (Gen 3) at 10.0.2.151", r("learned", { pin = pin }))
			assert.equal("Learned fan MF_00005E005301 (Gen 3) at 10.0.2.152",
				r("learned", { pin = pin, address = ADDR2 }), "args win over the pin")
		end)

		it("L2 the same fan at a new address", function()
			assert.equal("Same fan MF_00005E005301, now at 10.0.2.152", r("moved", { client_id = ID1, address = ADDR2 }))
		end)

		it("L3 now using another fan, with the one it replaced", function()
			assert.equal("Now using fan MF_00005E005302 (was MF_00005E005301)",
				r("now_using", { client_id = ID2, was = ID1, address = ADDR }))
		end)

		it("L3 with no fan pinned before: the address instead", function()
			assert.equal("Now using fan MF_00005E005302 at 10.0.2.151", r("now_using", { client_id = ID2, address = ADDR }))
			assert.equal("Now using fan MF_00005E005302 at 10.0.2.151",
				r("now_using", { client_id = ID2, was = "", address = ADDR }))
		end)

		it("L3 takes the replaced fan as a pin as well", function()
			assert.equal("Now using fan MF_00005E005302 (was MF_00005E005301)",
				r("now_using", { client_id = ID2, was = { client_id = ID1, mac = MAC1 }, address = ADDR }))
		end)

		it("L4 already using this fan here", function()
			assert.equal("Already using fan MF_00005E005301 at 10.0.2.151", r("already", { client_id = ID1, address = ADDR }))
		end)

		it("L5 no fan answers", function()
			assert.equal("No fan answers at 10.0.2.151; nothing changed", r("no_answer", { address = ADDR }))
		end)

		it("L6 not a Gen 1 to 3 fan", function()
			assert.equal("10.0.2.151 is not a Gen 1 to 3 Modern Forms fan; nothing changed", r("not_a_fan", { address = ADDR }))
		end)

		-- auto-discovery-design 5: one text now, whatever the args say.
		it("L7 nothing to use: pick a fan in Found Fans, or enter Fan Address", function()
			local L7 = "Nothing to use: pick a fan in Found Fans, or enter Fan Address"
			assert.equal(L7, r("nothing_to_use", {}))
			assert.equal(L7, r("nothing_to_use"))
			assert.equal(L7, r("nothing_to_use", { find_fans = true }))
			assert.equal(L7, r("nothing_to_use", { find_fans = false, address = ADDR }))
			assert.equal(62, #L7)
		end)

		it("L8 to L10 went with the Find Fans action", function()
			for _, key in ipairs({ "found", "found_none", "find_failed" }) do
				assert.equal("", r(key, { count = 2 }), key)
			end
		end)

		it("L11 reboot sent, with the time", function()
			assert.equal("Reboot sent to the fan's Wi-Fi module at 14:02", r("reboot_sent", { at = T, now = SOON }))
			assert.equal("Reboot sent to the fan's Wi-Fi module at 14:02", r("reboot_sent", { at = T }))
			assert.equal("Reboot sent to the fan's Wi-Fi module", r("reboot_sent", {}))
		end)

		it("L12 reboot while offline", function()
			assert.equal("Reboot not sent: the fan is not answering (power it off for 10 s)", r("reboot_offline"))
		end)

		it("L13 reboot with no fan of this device", function()
			assert.equal("Reboot not sent: no fan of this device answers at 10.0.2.151", r("reboot_refused", { address = ADDR }))
		end)

		it("L20 reboot while rebooting", function()
			assert.equal("Reboot already sent at 14:02; waiting for the fan", r("reboot_pending", { at = T, now = SOON }))
			assert.equal("Reboot already sent; waiting for the fan", r("reboot_pending", {}))
		end)

		it("L21 the picked fan is not at its address any more: the driver searches again", function()
			assert.equal("The fan at 10.0.2.151 is not the one picked; searching again", r("not_picked", { address = ADDR }))
			local long = r("not_picked", { address = "192.168.100.200" })
			assert.equal("The fan at 192.168.100.200 is not the one picked; searching again", long)
			assert.equal(65, #long)
		end)

		-- L32 (auto-discovery-design 4 step 4 and 5): a pick of another fan on a
		-- device that has one reads nothing and waits for Use Selected Fan.
		describe("L32, the waiting pick", function()
			local TAIL = ": click Use Selected Fan to switch to it"

			it("names the picked fan by its instance: the contract's text", function()
				local text = r("picked_wait", { instance = "MF_Fan_005302" })
				assert.equal("Picked MF_Fan_005302: click Use Selected Fan to switch to it", text)
				assert.equal(60, #text)
			end)

			it("cuts the instance at its START so the line stays at 70: 23 of a 25-character instance", function()
				local text = r("picked_wait", { instance = "WAC Windermier Fan#005302" })
				assert.equal(25, #"WAC Windermier Fan#005302")
				assert.equal("Picked C Windermier Fan#005302" .. TAIL, text)
				assert.equal(70, #text)
			end)

			it("leaves no blank in front when the cut lands on one", function()
				local tail22 = "Kitchen Island #005302" -- the 22 characters after the blank
				assert.equal(22, #tail22)
				assert.equal("Picked " .. tail22 .. TAIL, r("picked_wait", { instance = "WAC " .. tail22 }))
				assert.equal(69, #r("picked_wait", { instance = "WAC " .. tail22 }))
			end)

			it("keeps an instance of 23 whole and cuts one of 24 by its first character", function()
				local i23 = "ABCDEFGHIJKLMNOPQ005302"
				assert.equal(23, #i23)
				assert.equal("Picked " .. i23 .. TAIL, r("picked_wait", { instance = i23 }))
				assert.equal("Picked " .. i23 .. TAIL, r("picked_wait", { instance = "Z" .. i23 }))
				assert.equal(70, #r("picked_wait", { instance = "Z" .. i23 }))
			end)

			it("stays at 70 whatever the instance, and the last six MAC digits stay", function()
				local text = r("picked_wait", { instance = string.rep("x", 200) .. "_005302" })
				assert.equal(70, #text)
				assert.truthy(text:find("x_005302: click", 1, true))
			end)

			it("trims the instance, drops control characters and shows bytes outside printable ASCII as ?", function()
				assert.equal("Picked MF_Fan_005302" .. TAIL, r("picked_wait", { instance = "  MF_Fan_005302\t\n" }))
				assert.equal("Picked caf??_005302" .. TAIL, r("picked_wait", { instance = "caf\195\169_005302" }))
				assert.equal("Picked Hall, Fan" .. TAIL, r("picked_wait", { instance = "Hall, Fan" }), "a row, not a list item")
			end)

			it("says ? for no instance, and reads it from the args only, never from a pin", function()
				for _, none in ipairs({ "", "   ", false, true, {}, 0 / 0 }) do
					assert.equal("Picked ?" .. TAIL, r("picked_wait", { instance = none }), tostring(none))
				end
				assert.equal("Picked ?" .. TAIL, r("picked_wait", {}))
				assert.equal("Picked ?" .. TAIL, r("picked_wait"))
				assert.equal("Picked ?" .. TAIL, r("picked_wait", { pin = { instance = "MF_Fan_005302" } }))
				assert.equal("Picked ?" .. TAIL, r("picked_wait", { client_id = ID2, address = ADDR2, mac = "00005E005302" }))
			end)
		end)

		it("L14 and L15 away mode", function()
			assert.equal("Away mode turned off (the Modern Forms app can turn it on again)", r("away_off"))
			assert.equal("Away mode is already off", r("away_already"))
		end)

		it("L16 and L17 adaptive learning", function()
			assert.equal("Adaptive learning turned off (the Modern Forms app can turn it on)", r("learning_off"))
			assert.equal("Adaptive learning is already off", r("learning_already"))
		end)

		it("L18 not changed, the fan is not answering", function()
			assert.equal("Not changed: the fan is not answering", r("not_answering"))
		end)

		it("L19 the fan did not take it, for each automation", function()
			assert.equal("The fan did not take it; it still reports away mode on", r("not_taken", { which = "away" }))
			assert.equal("The fan did not take it; it still reports adaptive learning on",
				r("not_taken", { which = "learning" }))
			assert.equal("The fan did not take it; it still reports it on", r("not_taken", {}))
		end)

		-- L30 and L31: the address follower (address-follow-design 2.4, F6).
		describe("L30 and L31, the address follower's lines", function()
			it("L30 names the fan, its new address and the old one, within 70 characters at 15-character addresses",
				function()
					local text = r("followed", { client_id = "MF_00005E005301", address = "10.0.2.152", was = "10.0.2.151" })
					assert.equal("Followed fan MF_00005E005301 to 10.0.2.152 (was 10.0.2.151)", text)
					local long = r("followed", { client_id = "MF_00005E005301", address = "192.168.100.200",
						was = "192.168.100.201" })
					assert.equal(69, #long)
				end)

			it("L30 is at most 70 characters with a WAC_ client id and two 15-character addresses", function()
				local text = r("followed", { client_id = "WAC_00005E005301", address = "192.168.100.200",
					was = "192.168.100.201" })
				assert.equal(70, #text)
			end)

			it("L30 without the old address leaves out the parenthesis", function()
				assert.equal("Followed fan MF_00005E005301 to 10.0.2.152",
					r("followed", { client_id = "MF_00005E005301", address = "10.0.2.152" }))
			end)

			it("L31 names the fan and says it is not following", function()
				local text = r("follow_refused", { client_id = "MF_00005E005301" })
				assert.equal("Fan MF_00005E005301 moved 3 times in an hour; not following", text)
				assert.is_true(#text <= 70)
			end)

			it("both read the fan from a pin handed over whole", function()
				local pin = { client_id = "MF_00005E005301", mac = "00005E005301" }
				assert.equal("Fan MF_00005E005301 moved 3 times in an hour; not following", r("follow_refused", { pin = pin }))
			end)
		end)

		-- L22 to L29: what Name Items After Fan answers (fan-name-design 2.3, ECR 5.5).
		describe("L22 to L29, the rename job's answers", function()
			local both = { fan = "Sample", light = "Sample Light" }

			-- { id, key, args, the text verbatim, its length }
			local cases = {
				{ "L22", "name_renamed", both, "Items named Sample and Sample Light", 35 },
				{ "L23", "name_same", both, "Items already named Sample and Sample Light", 43 },
				{ "L24", "name_unknown", { fan_type = "1811-5-54" },
					"No name known for fan type 1811-5-54; items not renamed", 55 },
				{ "L25", "name_no_type", {}, "Fan type not read yet; try again in a moment", 44 },
				{ "L26", "name_no_ids", {}, "Items not renamed: this device's items were not found", 53 },
				{ "L27", "name_unconfirmed", {}, "Rename not confirmed; check the item names in Composer", 54 },
				{ "L28", "name_no_pin", {}, "Nothing to name the items after: no fan is set up yet", 53 },
				{ "L29", "name_busy", {}, "Naming in progress; try again in a moment", 41 },
			}
			for _, case in ipairs(cases) do
				it(case[1] .. " " .. case[2] .. " says '" .. case[4] .. "' (" .. case[5] .. " characters)", function()
					local text = r(case[2], case[3])
					assert.equal(case[4], text)
					assert.equal(case[5], #text)
					assert.is_true(#text <= 70)
				end)
			end

			it("the texts that name nothing do not depend on the args", function()
				for _, key in ipairs({ "name_no_type", "name_no_ids", "name_unconfirmed", "name_no_pin", "name_busy" }) do
					assert.equal(r(key, {}), r(key, { fan = "x", light = "y", fan_type = "z", address = ADDR, client_id = ID1 }), key)
					assert.equal(r(key, {}), r(key), key)
				end
			end)

			it("L22 and L23 print the two names as the job hands them over", function()
				local aviator = { fan = "Aviator 5", light = "Aviator 5 Light" }
				assert.equal("Items named Aviator 5 and Aviator 5 Light", r("name_renamed", aviator))
				assert.equal("Items already named Aviator 5 and Aviator 5 Light", r("name_same", aviator))
			end)

			it("L22 and L23 stay within 70 characters for the longest name of the research table, 15 characters", function()
				local long = { fan = "Size Matters 65", light = "Size Matters 65 Light" }
				assert.equal("Items named Size Matters 65 and Size Matters 65 Light", r("name_renamed", long))
				assert.equal(53, #r("name_renamed", long))
				assert.equal("Items already named Size Matters 65 and Size Matters 65 Light", r("name_same", long))
				assert.equal(61, #r("name_same", long))
			end)

			it("L22 and L23 read the names from the args, never from the pin", function()
				local pin = { client_id = ID1, fan = "From The Pin", light = "From The Pin Light" }
				assert.equal("Items named ? and ?", r("name_renamed", { pin = pin }))
				assert.equal("Items already named ? and ?", r("name_same", { pin = pin }))
			end)

			it("L24 cuts the fan type to 14 characters, no marker", function()
				assert.equal("No name known for fan type ABCDEFGHIJKLMN; items not renamed",
					r("name_unknown", { fan_type = "ABCDEFGHIJKLMNOPQRST" }))
				assert.equal("No name known for fan type ABCDEFGHIJKLMN; items not renamed",
					r("name_unknown", { fan_type = "ABCDEFGHIJKLMN" }), "14 stay whole")
				assert.equal("No name known for fan type ABCDEFGHIJKLM; items not renamed",
					r("name_unknown", { fan_type = "ABCDEFGHIJKLM" }), "13 stay whole")
				assert.equal(60, #r("name_unknown", { fan_type = string.rep("x", 100) }), "the longest it gets")
			end)

			it("L24 trims the type, shows bytes outside printable ASCII as ? and says ? for none", function()
				assert.equal("No name known for fan type 1811-5-54; items not renamed",
					r("name_unknown", { fan_type = "  1811-5-54 \t" }))
				assert.equal("No name known for fan type caf??-5-54; items not renamed",
					r("name_unknown", { fan_type = "caf\195\169-5-54" }))
				assert.equal("No name known for fan type a?b?c; items not renamed", r("name_unknown", { fan_type = "a\1b\127c" }))
				for _, none in ipairs({ "", "   ", false, true, {}, 0 / 0 }) do
					assert.equal("No name known for fan type ?; items not renamed",
						r("name_unknown", { fan_type = none }), tostring(none))
				end
				assert.equal("No name known for fan type ?; items not renamed", r("name_unknown", {}))
				assert.equal("No name known for fan type ?; items not renamed", r("name_unknown"))
			end)

			it("L24 takes the type from the args, never from a pin", function()
				assert.equal("No name known for fan type ?; items not renamed",
					r("name_unknown", { pin = { fan_type = "1811-5-54" } }))
			end)

			it("a missing name is ?, never an error or the word nil", function()
				assert.equal("Items named ? and ?", r("name_renamed", {}))
				assert.equal("Items already named ? and ?", r("name_same", nil))
				assert.equal("Items named Sample and ?", r("name_renamed", { fan = "Sample" }))
				assert.equal("Items named ? and Sample Light", r("name_renamed", { light = "Sample Light" }))
			end)
		end)

		-- L33 to L41: Breeze (breeze-design section 5, BZ10, BZ11; section 11, BF-D10).
		describe("L33 to L41, Breeze", function()
			local AVIATOR = { name = "Aviator 5 Breeze" }

			-- { id, key, args, the text verbatim, its length }
			local cases = {
				{ "L33", "breeze_unavailable", {}, "Breeze not available: this fan reports no Breeze", 48 },
				{ "L34", "breeze_strength", { strength = "5" }, "Breeze strength 5 refused: use 1, 2 or 3", 40 },
				{ "L36", "breeze_switch_added", AVIATOR, "Breeze fan added: Aviator 5 Breeze", 34 },
				{ "L37", "breeze_switch_exists", AVIATOR, "A Breeze fan is already connected: Aviator 5 Breeze", 51 },
				{ "L38", "breeze_switch_no_breeze", {}, "No Breeze fan added: this fan reports no Breeze", 47 },
				{ "L39", "breeze_switch_no_fan", {}, "No Breeze fan added: set up the fan first", 41 },
				{ "L40", "breeze_switch_failed", {}, "No Breeze fan added: install modernforms_breeze_fan.c4z first", 61 },
				{ "L41", "breeze_old_switch", AVIATOR, "Delete the old Breeze switch first: Aviator 5 Breeze", 52 },
				{ "L42", "breeze_leds_need_per_speed", {}, "Breeze LEDs need Speed LED Colors set to Per speed", 50 },
				{ "L43", "speed_leds_need_per_speed", {}, "LED chase needs Speed LED Colors set to Per speed", 49 },
				{ "L44", "keypad_leds_shown", {}, "Keypad LED settings shown: a button is on a Fan Speed link", 58 },
				{ "L45", "keypad_leds_hidden", {}, "Keypad LED settings hidden: no button on a Fan Speed link", 57 },
			}
			for _, case in ipairs(cases) do
				it(case[1] .. " " .. case[2] .. " says '" .. case[4] .. "' (" .. case[5] .. " characters)", function()
					local text = r(case[2], case[3])
					assert.equal(case[4], text)
					assert.equal(case[5], #text)
					assert.is_true(#text <= 70)
				end)
			end

			it("the texts that name nothing do not depend on the args", function()
				for _, key in ipairs({ "breeze_unavailable", "breeze_switch_no_breeze", "breeze_switch_no_fan",
					"breeze_switch_failed" }) do
					assert.equal(r(key, {}), r(key, { name = "x", strength = "9", why = "unset", address = ADDR,
						client_id = ID1 }), key)
					assert.equal(r(key, {}), r(key), key)
				end
			end)

			it("L34 shows the value as given: a number, a text trimmed, cut to 8 characters, ASCII only", function()
				local function line(shown)
					return "Breeze strength " .. shown .. " refused: use 1, 2 or 3"
				end
				assert.equal(line("5"), r("breeze_strength", { strength = 5 }))
				assert.equal(line("0"), r("breeze_strength", { strength = 0 }))
				assert.equal(line("4.5"), r("breeze_strength", { strength = 4.5 }))
				assert.equal(line("-2"), r("breeze_strength", { strength = "  -2 " }))
				assert.equal(line("high"), r("breeze_strength", { strength = "high" }))
				assert.equal(line("12345678"), r("breeze_strength", { strength = "123456789012" }))
				assert.equal(line("12345678"), r("breeze_strength", { strength = 123456789012 }), "a long number is cut too")
				assert.equal(line("caf??"), r("breeze_strength", { strength = "caf\195\169" }))
				assert.equal(line("ab"), r("breeze_strength", { strength = "a\tb\n" }))
				assert.equal(47, #r("breeze_strength", { strength = string.rep("x", 100) }), "the longest it gets")
			end)

			it("L34 says ? for no value and for one that is no number or text", function()
				for _, none in ipairs({ "", "   ", false, true, {}, 0 / 0, math.huge, -math.huge, 1e308 }) do
					assert.equal("Breeze strength ? refused: use 1, 2 or 3", r("breeze_strength", { strength = none }),
						tostring(none))
				end
				assert.equal("Breeze strength ? refused: use 1, 2 or 3", r("breeze_strength", {}))
				assert.equal("Breeze strength ? refused: use 1, 2 or 3", r("breeze_strength"))
				assert.equal("Breeze strength ? refused: use 1, 2 or 3", r("breeze_strength", { pin = { strength = "5" } }),
					"never from a pin")
			end)

			-- L35: the model's refusal reasons in words (model.lua refusal() and
			-- validate(); breeze-design section 2 adds no_breeze and breeze_range).
			local reasons = {
				{ "unset", "Breeze not sent: no fan is set up yet", 37 },
				{ "invalid address", "Breeze not sent: Fan Address is not an IPv4 address", 51 },
				{ "foreign", "Breeze not sent: another fan answers at Fan Address", 51 },
				{ "gen4", "Breeze not sent: a Gen 4 fan answers at Fan Address", 51 },
				{ "notfan", "Breeze not sent: Fan Address answers, but not as a fan", 54 },
				{ "rebooting", "Breeze not sent: the fan's Wi-Fi module is rebooting", 52 },
				{ "range", "Breeze not sent: the value is out of range", 42 },
				{ "no fanOn", "Breeze not sent: the fan reports no fanOn", 41 },
				{ "no fanSpeed", "Breeze not sent: the fan reports no fanSpeed", 44 },
			}
			for _, case in ipairs(reasons) do
				it("L35 breeze_refused, " .. case[1] .. ": '" .. case[2] .. "' (" .. case[3] .. " characters)", function()
					local text = r("breeze_refused", { why = case[1] })
					assert.equal(case[2], text)
					assert.equal(case[3], #text)
					assert.is_true(#text <= 70)
				end)
			end

			it("L35 with the model's own Breeze reasons is L33 or L34", function()
				assert.equal(r("breeze_unavailable"), r("breeze_refused", { why = "no_breeze" }))
				assert.equal("Breeze strength 7 refused: use 1, 2 or 3",
					r("breeze_refused", { why = "breeze_range", strength = "7" }))
				assert.equal("Breeze strength ? refused: use 1, 2 or 3", r("breeze_refused", { why = "breeze_range" }))
			end)

			it("L35 cuts the key of a 'no <key>' reason to 16 characters", function()
				local text = r("breeze_refused", { why = "no " .. string.rep("k", 40) })
				assert.equal("Breeze not sent: the fan reports no " .. string.rep("k", 16), text)
				assert.equal(52, #text)
			end)

			it("L35 with a reason it does not know, or none, is the bare line, never the reason echoed", function()
				for _, odd in ipairs({ "busy", "", "no light kit", "no fan-On", "UNSET", "__index", 5, false, true, {} }) do
					assert.equal("Breeze not sent", r("breeze_refused", { why = odd }), tostring(odd))
				end
				assert.equal("Breeze not sent", r("breeze_refused", {}))
				assert.equal("Breeze not sent", r("breeze_refused"))
				assert.equal("Breeze not sent", r("breeze_refused", { pin = { why = "unset" } }), "never from a pin")
			end)

			it("L36, L37 and L41 name the device as Director gives it, trimmed, control characters dropped", function()
				assert.equal("Breeze fan added: Aviator 5 Breeze", r("breeze_switch_added", { name = "  Aviator 5 Breeze\n" }))
				assert.equal("Breeze fan added: Caf\195\169 Breeze", r("breeze_switch_added", { name = "Caf\195\169 Breeze" }),
					"a name is printed as it is, as L22 does")
				assert.equal("A Breeze fan is already connected: Hall, Fan Breeze",
					r("breeze_switch_exists", { name = "Hall, Fan Breeze" }), "a row, not a list item")
				assert.equal("Delete the old Breeze switch first: Aviator 5 Breeze",
					r("breeze_old_switch", { name = "\tAviator 5 Breeze " }))
			end)

			it("L36, L37 and L41 cut a long name so the line stays at 70: 52, 35 and 34 characters of it", function()
				local long = string.rep("N", 100)
				assert.equal("Breeze fan added: " .. string.rep("N", 52), r("breeze_switch_added", { name = long }))
				assert.equal(70, #r("breeze_switch_added", { name = long }))
				assert.equal("A Breeze fan is already connected: " .. string.rep("N", 35),
					r("breeze_switch_exists", { name = long }))
				assert.equal(70, #r("breeze_switch_exists", { name = long }))
				assert.equal("Delete the old Breeze switch first: " .. string.rep("N", 34),
					r("breeze_old_switch", { name = long }))
				assert.equal(70, #r("breeze_old_switch", { name = long }))
				local thirty = "Master Bedroom Ceiling F Breeze" -- the companion's own name, cut to 30 by breeze.lua
				for _, key in ipairs({ "breeze_switch_added", "breeze_switch_exists", "breeze_old_switch" }) do
					local text = r(key, { name = thirty })
					assert.equal(thirty, text:sub(-#thirty), key .. ": a 30-character name is never cut")
					assert.is_true(#text <= 70, key)
				end
			end)

			it("L36, L37 and L41 never cut inside a UTF-8 character, and leave no blank at the end", function()
				local e_acute, euro, cyclone = "\195\169", "\226\130\172", "\240\159\140\128"
				assert.equal("Breeze fan added: " .. string.rep("a", 51),
					r("breeze_switch_added", { name = string.rep("a", 51) .. e_acute .. "b" }))
				assert.equal("Breeze fan added: " .. string.rep("a", 50) .. e_acute,
					r("breeze_switch_added", { name = string.rep("a", 50) .. e_acute .. "b" }), "a whole character stays")
				assert.equal("Breeze fan added: " .. string.rep("a", 50),
					r("breeze_switch_added", { name = string.rep("a", 50) .. euro }))
				assert.equal("Breeze fan added: " .. string.rep("a", 49) .. euro,
					r("breeze_switch_added", { name = string.rep("a", 49) .. euro .. "zzz" }))
				assert.equal("A Breeze fan is already connected: " .. string.rep("a", 32),
					r("breeze_switch_exists", { name = string.rep("a", 32) .. cyclone }))
				assert.equal("A Breeze fan is already connected: " .. string.rep("a", 34),
					r("breeze_switch_exists", { name = string.rep("a", 34) .. " Breeze" }))
				assert.equal("Delete the old Breeze switch first: " .. string.rep("a", 31),
					r("breeze_old_switch", { name = string.rep("a", 31) .. cyclone }))
				assert.equal("Delete the old Breeze switch first: " .. string.rep("a", 33),
					r("breeze_old_switch", { name = string.rep("a", 33) .. " Breeze" }))
			end)

			it("L46 breeze_fan_not_connected names the device added but not bound, and says what to do (#214)", function()
				local text = r("breeze_fan_not_connected", AVIATOR)
				assert.equal("Added Aviator 5 Breeze, not connected: use Connections, then retry", text)
				assert.equal(66, #text)
			end)

			it("L46 cleans the name and cuts it to 20 characters, so the line stays at 70", function()
				local long = r("breeze_fan_not_connected", { name = string.rep("N", 100) })
				assert.equal("Added " .. string.rep("N", 20) .. ", not connected: use Connections, then retry", long)
				assert.equal(70, #long)
				assert.equal("Added Aviator 5, not connected: use Connections, then retry",
					r("breeze_fan_not_connected", { name = "\tAviator\n 5\0 " }), "control characters dropped, trimmed")
				assert.equal("Added Caf\195\169 ?, not connected: use Connections, then retry",
					r("breeze_fan_not_connected", { name = "Caf\195\169 \255" }), "UTF-8 kept, a broken byte is ?")
				assert.equal("Added " .. string.rep("a", 19) .. ", not connected: use Connections, then retry",
					r("breeze_fan_not_connected", { name = string.rep("a", 19) .. "\226\130\172" }),
					"never cut inside a character")
				for _, none in ipairs({ "", "   ", "\n\t", false, true, {}, 0 / 0 }) do
					assert.equal("Added ?, not connected: use Connections, then retry",
						r("breeze_fan_not_connected", { name = none }), tostring(none))
				end
				assert.equal("Added ?, not connected: use Connections, then retry",
					r("breeze_fan_not_connected", { pin = { name = "Aviator 5 Breeze" } }), "never from a pin")
			end)

			it("L36, L37 and L41 say ? for no name, and read it from the args only, never from a pin", function()
				for _, none in ipairs({ "", "   ", "\n\t", false, true, {}, 0 / 0 }) do
					assert.equal("Breeze fan added: ?", r("breeze_switch_added", { name = none }), tostring(none))
					assert.equal("A Breeze fan is already connected: ?", r("breeze_switch_exists", { name = none }))
					assert.equal("Delete the old Breeze switch first: ?", r("breeze_old_switch", { name = none }))
				end
				assert.equal("Breeze fan added: ?", r("breeze_switch_added"))
				assert.equal("Breeze fan added: ?", r("breeze_switch_added", { pin = { name = "Aviator 5 Breeze" } }))
				assert.equal("A Breeze fan is already connected: ?",
					r("breeze_switch_exists", { fan = "Aviator 5", client_id = ID1 }))
				assert.equal("Delete the old Breeze switch first: ?",
					r("breeze_old_switch", { pin = { name = "Aviator 5 Breeze" }, fan = "Aviator 5" }))
			end)
		end)

		it("a missing value is ?, never an error or the word nil", function()
			assert.equal("Learned fan ? (Gen ?) at ?", r("learned", {}))
			assert.equal("Same fan ?, now at ?", r("moved", nil))
			assert.equal("Now using fan ? at ?", r("now_using", {}))
			assert.equal("No fan answers at ?; nothing changed", r("no_answer", {}))
			assert.equal("The fan at ? is not the one picked; searching again", r("not_picked", {}))
		end)

		it("an unknown key is an empty text", function()
			assert.equal("", r("nope", { address = ADDR }))
			assert.equal("", r(nil, {}))
			assert.equal("", r(5, {}))
			assert.equal("", r("__index", {}))
		end)
	end)

	-- The second write of a Use Selected Fan line, once the guarded rename has
	-- ended: the same L2, L3 or L4 and one short tail (fan-name-design 2.3, ECR 5.5).
	describe("rename_suffix (fan-name-design 2.3)", function()
		it("renamed: items renamed", function()
			assert.equal("; items renamed", texts.rename_suffix("renamed"))
		end)

		it("kept: names kept", function()
			assert.equal("; names kept", texts.rename_suffix("kept"))
		end)

		it("no name, no type, no ids and an unconfirmed rename: not renamed", function()
			for _, outcome in ipairs({ "no_name", "no_type", "no_ids", "unconfirmed" }) do
				assert.equal("; not renamed", texts.rename_suffix(outcome), outcome)
			end
		end)

		it("busy is not renamed", function()
			assert.equal("; not renamed", texts.rename_suffix("busy"))
		end)

		it("same, no_pin and anything else add nothing", function()
			for _, outcome in ipairs({ "same", "no_pin", "", " ", "Renamed", "renamed ", "name_renamed", "forced",
				"guarded", "__index", false, true, 0, 5, 0 / 0, math.huge, {}, { "renamed" }, print }) do
				assert.equal("", texts.rename_suffix(outcome), tostring(outcome))
			end
			assert.equal("", texts.rename_suffix(nil))
			assert.equal("", texts.rename_suffix())
		end)

		it("every suffix starts with '; ' so it continues the line it follows", function()
			for _, outcome in ipairs({ "renamed", "kept", "no_name", "no_type", "no_ids", "unconfirmed" }) do
				assert.equal("; ", texts.rename_suffix(outcome):sub(1, 2), outcome)
			end
		end)

		describe("L2, L3 and L4 plus the longest suffix", function()
			local outcomes = { "renamed", "kept", "no_name", "no_type", "no_ids", "unconfirmed" }

			-- The longest tail of all the outcomes.
			local function longest()
				local best = ""
				for _, outcome in ipairs(outcomes) do
					if #texts.rename_suffix(outcome) > #best then
						best = texts.rename_suffix(outcome)
					end
				end
				return best
			end

			-- Every tail on every line, the line kept as the first write made it.
			local function assert_within(cases, limit)
				for _, case in ipairs(cases) do
					local line = texts.result(case[1], case[2])
					assert.is_true(#line > 0, case[1])
					for _, outcome in ipairs(outcomes) do
						local whole = line .. texts.rename_suffix(outcome)
						assert.is_true(#whole <= limit, #whole .. " > " .. limit .. ": " .. whole)
					end
				end
			end

			it("the longest suffix is '; items renamed', 15 characters", function()
				assert.equal("; items renamed", longest())
				assert.equal(15, #longest())
			end)

			it("stay at or under 70 characters with the placeholders", function()
				local placeholders = {
					{ "moved", { client_id = ID1, address = ADDR2 } },
					{ "now_using", { client_id = ID2, was = ID1, address = ADDR } },
					{ "now_using", { client_id = ID2, address = ADDR } },
					{ "already", { client_id = ID1, address = ADDR } },
				}
				assert_within(placeholders, 70)
				-- ECR 5.5: L3 with its "was" part is the longest, 51, so 66.
				local was = texts.result("now_using", { client_id = ID2, was = ID1, address = ADDR })
				assert.equal(51, #was)
				assert.equal(66, #(was .. longest()))
				assert.equal("Now using fan MF_00005E005302 (was MF_00005E005301); items renamed", was .. longest())
			end)

			it("and with the longest inputs: WAC_ client ids and a 15-character address, 68", function()
				local worst = {
					{ "moved", { client_id = "WAC_00005E005301", address = "255.255.255.255" } },
					{ "now_using", { client_id = "WAC_00005E005302", was = "WAC_00005E005301", address = "255.255.255.255" } },
					{ "now_using", { client_id = "WAC_00005E005302", address = "255.255.255.255" } },
					{ "already", { client_id = "WAC_00005E005301", address = "255.255.255.255" } },
				}
				assert_within(worst, 70)
				assert.equal(68, #(texts.result("already", worst[4][2]) .. longest()))
				assert.equal(68, #(texts.result("now_using", worst[2][2]) .. longest()))
			end)

			it("the line itself is the first write's: the suffix only follows it", function()
				local args = { client_id = ID1, address = ADDR }
				assert.equal(texts.result("already", args) .. "; names kept",
					texts.result("already", args) .. texts.rename_suffix("kept"))
				assert.equal("Already using fan MF_00005E005301 at 10.0.2.151; names kept",
					texts.result("already", args) .. texts.rename_suffix("kept"))
			end)
		end)
	end)

	describe("the other rows (section 7.3)", function()
		describe("Fan ID", function()
			it("the client id and the MAC", function()
				assert.equal("MF_00005E005301 (MAC 00:00:5e:00:53:01)", texts.fan_id({ client_id = ID1, mac = MAC1 }))
			end)

			it("a WAC_ client id, and a MAC in another spelling", function()
				assert.equal("WAC_00005E005301 (MAC 00:00:5e:00:53:01)",
					texts.fan_id({ client_id = "WAC_00005E005301", mac = "00:00:5E:00:53:01" }))
				assert.equal("MF_00005E005301 (MAC 00:00:5e:00:53:01)", texts.fan_id({ client_id = ID1, mac = "00005e005301" }))
			end)

			it("the client id alone when there is no usable MAC", function()
				assert.equal(ID1, texts.fan_id({ client_id = ID1 }))
				assert.equal(ID1, texts.fan_id({ client_id = ID1, mac = "00005E00" }))
			end)

			it("is empty before the first contact", function()
				assert.equal("", texts.fan_id(nil))
				assert.equal("", texts.fan_id({}))
				assert.equal("", texts.fan_id({ mac = MAC1 }))
				assert.equal("", texts.fan_id({ client_id = "" }))
			end)

			it("is read back by parse_fan_id (section 8: a restore onto a new controller)", function()
				local row = texts.fan_id({ client_id = ID1, mac = MAC1 })
				assert.same({ client_id = ID1, mac = MAC1 }, texts.parse_fan_id(row))
				assert.same({ client_id = ID1, mac = nil }, texts.parse_fan_id(ID1))
				assert.same({ client_id = "WAC_00005E005302", mac = "00005E005302" },
					texts.parse_fan_id("  WAC_00005E005302 (MAC 00:00:5e:00:53:02) "))
			end)

			it("parse_fan_id refuses what is not a Fan ID row", function()
				for _, text in ipairs({ "", "   ", "nothing", "MF_0000", "MF_00005E005301X", "MF_00005E005301(MAC x)", 5, true }) do
					assert.is_nil(texts.parse_fan_id(text), tostring(text))
				end
				assert.is_nil(texts.parse_fan_id(nil))
				assert.same({ client_id = ID1, mac = nil }, texts.parse_fan_id(ID1 .. " (MAC garbage)"))
			end)
		end)

		describe("Fan Model", function()
			local info = { fan_type = "1811-5-54", light_type = "F4IN-120V-R1-30", has_light = true }

			-- Until a test teaches the fake table a name (the block after these),
			-- 1811-5-54 is a type without one: the examples here are the text the
			-- row had before fan-name-design N3, which a type without a name keeps.
			it("M0's values, with Breeze", function()
				assert.equal("Gen 3, fan 1811-5-54, light kit F4IN-120V-R1-30, Breeze",
					texts.fan_model({ generation = "3" }, info, true))
			end)

			it("without Breeze", function()
				assert.equal("Gen 3, fan 1811-5-54, light kit F4IN-120V-R1-30",
					texts.fan_model({ generation = "3" }, info, false))
				assert.equal("Gen 3, fan 1811-5-54, light kit F4IN-120V-R1-30", texts.fan_model({ generation = "3" }, info))
			end)

			it("Breeze from the info when the third argument is absent", function()
				local with_wind = { fan_type = "1811-5-54", light_type = "F4IN-120V-R1-30", has_wind = true }
				assert.equal("Gen 3, fan 1811-5-54, light kit F4IN-120V-R1-30, Breeze",
					texts.fan_model({ generation = "3" }, with_wind))
				assert.equal("Gen 3, fan 1811-5-54, light kit F4IN-120V-R1-30",
					texts.fan_model({ generation = "3" }, with_wind, false), "an explicit false wins")
			end)

			it("no light kit", function()
				assert.equal("Gen 3, fan 1811-5-54, no light kit",
					texts.fan_model({ generation = "3" }, { fan_type = "1811-5-54", light_type = "", has_light = false }))
				assert.equal("Gen 3, fan 1811-5-54, no light kit",
					texts.fan_model({ generation = "3" }, { fan_type = "1811-5-54" }, false))
				assert.equal("Gen 3, fan 1811-5-54, no light kit", texts.fan_model({ generation = "3" },
					{ fan_type = "1811-5-54", light_type = "F4IN-120V-R1-30", has_light = false }), "has_light false wins")
			end)

			it("Gen 1/2 and Gen ?", function()
				assert.equal("Gen 1/2, fan 1811-5-54, light kit F4IN-120V-R1-30", texts.fan_model({ generation = "1/2" }, info))
				assert.equal("Gen ?, fan 1811-5-54, light kit F4IN-120V-R1-30", texts.fan_model({}, info))
				assert.equal("Gen ?, fan 1811-5-54, light kit F4IN-120V-R1-30", texts.fan_model(nil, info))
				assert.equal("Gen ?, fan 1811-5-54, light kit F4IN-120V-R1-30", texts.fan_model({ generation = "4" }, info))
			end)

			it("a fan type not known is ?", function()
				assert.equal("Gen 3, fan ?, no light kit", texts.fan_model({ generation = "3" }, {}))
			end)

			it("is empty until the info is known", function()
				assert.equal("", texts.fan_model({ generation = "3" }, nil, true))
				assert.equal("", texts.fan_model(nil, nil))
			end)

			describe("with a name from fan.names (fan-name-design N3)", function()
				before_each(function()
					KNOWN["1811-5-54"] = "Aviator 5"
				end)

				-- Replace the fake's lookup by `reply`; returns the types it was asked for.
				local function asked_with(reply)
					local asked = {}
					fake_names.lookup = function(fan_type)
						asked[#asked + 1] = fan_type
						return reply(fan_type)
					end
					return asked
				end

				it("the name, then the type in parentheses, in place of 'fan <type>'", function()
					local row = texts.fan_model({ generation = "3" }, info, true)
					assert.equal("Gen 3, Aviator 5 (1811-5-54), light kit F4IN-120V-R1-30, Breeze", row)
					assert.equal(63, #row)
				end)

				it("the rest of the row is as before: Breeze, the light kit and the generation", function()
					assert.equal("Gen 3, Aviator 5 (1811-5-54), light kit F4IN-120V-R1-30",
						texts.fan_model({ generation = "3" }, info, false))
					assert.equal("Gen 3, Aviator 5 (1811-5-54), light kit F4IN-120V-R1-30",
						texts.fan_model({ generation = "3" }, info))
					assert.equal("Gen 3, Aviator 5 (1811-5-54), light kit F4IN-120V-R1-30, Breeze",
						texts.fan_model({ generation = "3" }, { fan_type = "1811-5-54", light_type = "F4IN-120V-R1-30",
							has_wind = true }), "Breeze from the info")
					assert.equal("Gen 1/2, Aviator 5 (1811-5-54), light kit F4IN-120V-R1-30",
						texts.fan_model({ generation = "1/2" }, info))
					assert.equal("Gen ?, Aviator 5 (1811-5-54), light kit F4IN-120V-R1-30", texts.fan_model(nil, info))
					assert.equal("Gen ?, Aviator 5 (1811-5-54), light kit F4IN-120V-R1-30",
						texts.fan_model({ generation = "4" }, info))
				end)

				it("no light kit, whichever way the info says so", function()
					assert.equal("Gen 3, Aviator 5 (1811-5-54), no light kit",
						texts.fan_model({ generation = "3" }, { fan_type = "1811-5-54", light_type = "", has_light = false }))
					assert.equal("Gen 3, Aviator 5 (1811-5-54), no light kit",
						texts.fan_model({ generation = "3" }, { fan_type = "1811-5-54" }, false))
					assert.equal("Gen 3, Aviator 5 (1811-5-54), no light kit", texts.fan_model({ generation = "3" },
						{ fan_type = "1811-5-54", light_type = "F4IN-120V-R1-30", has_light = false }), "has_light false wins")
				end)

				it("a type the table has no name for keeps the older text, whatever else the table lists", function()
					KNOWN["2006-52"] = "Zephyr 52"
					assert.equal("Gen 3, fan 2003-52, light kit F4IN-120V-R1-30, Breeze", texts.fan_model({ generation = "3" },
						{ fan_type = "2003-52", light_type = "F4IN-120V-R1-30", has_light = true }, true))
					assert.equal("Gen 3, Zephyr 52 (2006-52), light kit F4IN-120V-R1-30", texts.fan_model({ generation = "3" },
						{ fan_type = "2006-52", light_type = "F4IN-120V-R1-30", has_light = true }))
				end)

				it("the type is looked up and shown without the blanks around it", function()
					local asked = asked_with(FAKE_LOOKUP)
					assert.equal("Gen 3, Aviator 5 (1811-5-54), no light kit",
						texts.fan_model({ generation = "3" }, { fan_type = "  1811-5-54\t" }))
					assert.same({ "1811-5-54" }, asked)
				end)

				it("looks up only a type there is: no type, an empty or blank one, or text that is not one asks nothing", function()
					local asked = asked_with(function()
						return "Aviator 5"
					end)
					assert.equal("Gen 3, fan ?, no light kit", texts.fan_model({ generation = "3" }, {}))
					for _, odd in ipairs({ "", "   ", true, false, {}, 0 / 0, math.huge, print }) do
						texts.fan_model({ generation = "3" }, { fan_type = odd })
					end
					assert.same({}, asked)
				end)

				it("a lookup with no usable answer gives the older text: nothing, empty, not text", function()
					for _, reply in ipairs({ false, "", "   ", 5, true, {}, print }) do
						asked_with(function()
							return reply
						end)
						assert.equal("Gen 3, fan 1811-5-54, no light kit",
							texts.fan_model({ generation = "3" }, { fan_type = "1811-5-54" }), tostring(reply))
					end
					fake_names.lookup = function() end
					assert.equal("Gen 3, fan 1811-5-54, no light kit",
						texts.fan_model({ generation = "3" }, { fan_type = "1811-5-54" }), "nil")
				end)

				it("a lookup that raises costs the name and nothing else", function()
					fake_names.lookup = function()
						error("table kaput")
					end
					local ok, row = pcall(texts.fan_model, { generation = "3" }, info, true)
					assert(ok, row)
					assert.equal("Gen 3, fan 1811-5-54, light kit F4IN-120V-R1-30, Breeze", row)
					fake_names.lookup = nil
					ok, row = pcall(texts.fan_model, { generation = "3" }, info, true)
					assert(ok, row)
					assert.equal("Gen 3, fan 1811-5-54, light kit F4IN-120V-R1-30, Breeze", row, "a table with no lookup")
				end)

				it("blanks around the name it gets are dropped", function()
					KNOWN["1811-5-54"] = "  Aviator 5 "
					assert.equal("Gen 3, Aviator 5 (1811-5-54), no light kit",
						texts.fan_model({ generation = "3" }, { fan_type = "1811-5-54" }))
				end)

				it("reads only the type, the kit and the generation, not the brand, the motor or the owner's name", function()
					local row = texts.fan_model({ generation = "3", client_id = ID1, mac = MAC1 },
						{ fan_type = "1811-5-54", light_type = "F4IN-120V-R1-30", brand = 1, motor = "DC125X20",
							deviceName = "Example Fan", owner = "owner@example.com" }, true)
					assert.equal("Gen 3, Aviator 5 (1811-5-54), light kit F4IN-120V-R1-30, Breeze", row)
				end)

				-- Section 7: rows under about 70 characters. The longest name in the
				-- research table (FNR Appendix B) is 15 characters.
				it("stays within 70 characters for a 15-character name: 69 on Gen 3 with the house's type and kit", function()
					KNOWN["1811-5-54"] = "Fifteen Letters"
					assert.equal(15, #"Fifteen Letters")
					local row = texts.fan_model({ generation = "3" }, info, true)
					assert.equal("Gen 3, Fifteen Letters (1811-5-54), light kit F4IN-120V-R1-30, Breeze", row)
					assert.equal(69, #row)
					assert.is_true(#row <= 70)
				end)

				it("and for the longest row in that table, Gen 1/2 with Size Matters 65: 69 as well", function()
					KNOWN["2403-65"] = "Size Matters 65"
					local row = texts.fan_model({ generation = "1/2" },
						{ fan_type = "2403-65", light_type = "F4IN-120V-R1-30", has_light = true }, true)
					assert.equal("Gen 1/2, Size Matters 65 (2403-65), light kit F4IN-120V-R1-30, Breeze", row)
					assert.equal(69, #row)
					assert.is_true(#row <= 70)
				end)
			end)
		end)

		describe("Firmware", function()
			it("the first sighting", function()
				assert.equal("02.00.0052 (motor 03.00.0000) since 2026-10-27", texts.firmware({
					firmware = "02.00.0052", mcu_firmware = "03.00.0000", firmware_since = "2026-10-27" }))
			end)

			it("after a change", function()
				assert.equal("02.00.0060 (motor 03.00.0000) since 2026-11-02, was 02.00.0052", texts.firmware({
					firmware = "02.00.0060", mcu_firmware = "03.00.0000", firmware_since = "2026-11-02",
					firmware_was = "02.00.0052" }))
			end)

			it("leaves out what is not known", function()
				assert.equal("02.00.0052", texts.firmware({ firmware = "02.00.0052" }))
				assert.equal("02.00.0052 since 2026-10-27", texts.firmware({ firmware = "02.00.0052",
					firmware_since = "2026-10-27" }))
				assert.equal("02.00.0052 (motor 03.00.0000)", texts.firmware({ firmware = "02.00.0052",
					mcu_firmware = "03.00.0000", firmware_was = "" }))
			end)

			it("shows a date given as seconds", function()
				assert.equal("02.00.0052 since 2026-10-27", texts.firmware({ firmware = "02.00.0052",
					firmware_since = at(2026, 10, 27, 12, 0) }))
			end)

			it("is empty before a firmware is known", function()
				assert.equal("", texts.firmware(nil))
				assert.equal("", texts.firmware({}))
				assert.equal("", texts.firmware({ mcu_firmware = "03.00.0000", firmware_since = "2026-10-27" }))
			end)
		end)

		describe("Last Seen", function()
			it("the contract's example: the time and how long the answer took", function()
				assert.equal("2026-10-27 18:02:10, answered in 0.31 s", texts.last_seen(at(2026, 10, 27, 18, 2, 10), 310))
			end)

			it("shows seconds with two decimals", function()
				local when = at(2026, 10, 27, 18, 2, 10)
				assert.equal("2026-10-27 18:02:10, answered in 0.25 s", texts.last_seen(when, 250))
				assert.equal("2026-10-27 18:02:10, answered in 1.36 s", texts.last_seen(when, 1360))
				assert.equal("2026-10-27 18:02:10, answered in 5.00 s", texts.last_seen(when, 5000))
				assert.equal("2026-10-27 18:02:10, answered in 0.00 s", texts.last_seen(when, 0))
				assert.equal("2026-10-27 18:02:10, answered in 0.00 s", texts.last_seen(when, -5))
			end)

			it("just the time when the duration is not known or not a sane number", function()
				local when = at(2026, 10, 27, 18, 2, 10)
				assert.equal("2026-10-27 18:02:10", texts.last_seen(when, nil))
				assert.equal("2026-10-27 18:02:10", texts.last_seen(when, "slow"))
				for _, odd in ipairs({ 1e308, math.huge, 0 / 0, 2147483648 }) do
					assert.equal("2026-10-27 18:02:10", texts.last_seen(when, odd), tostring(odd))
				end
			end)

			it("is empty when the time is not known", function()
				assert.equal("", texts.last_seen(nil, 310))
				assert.equal("", texts.last_seen("never", 310))
			end)
		end)

		describe("Last Change By", function()
			local cases = {
				{ "ble", "Remote or wall control" },
				{ "local_wifi", "Modern Forms app or another local client" },
				{ "cloud", "Modern Forms cloud (app away, voice assistant)" },
				{ "sleep_timer", "The fan's sleep timer" },
				{ "away_mode", "The fan's away mode" },
				{ "schedule", "A schedule in the Modern Forms app" },
			}
			for _, case in ipairs(cases) do
				it("userData " .. case[1] .. " is " .. case[2], function()
					assert.equal(case[2] .. " at 14:05", texts.change_by(case[1], at(2026, 10, 27, 14, 5), SOON + 180))
				end)
			end

			it("the contract's example for the remote", function()
				assert.equal("Remote or wall control at 14:05", texts.change_by("ble", at(2026, 10, 27, 14, 5), nil))
			end)

			it("none, absent (Gen 1/2) and anything else are an unnamed source", function()
				for _, source in ipairs({ "none", "", "unknown_source", "owner@example.com", 5, true }) do
					assert.equal("Outside Control4 (source not reported) at 14:02", texts.change_by(source, T, SOON),
						tostring(source))
				end
				assert.equal("Outside Control4 (source not reported) at 14:02", texts.change_by(nil, T, SOON))
			end)

			it("never echoes what the fan sent as the source", function()
				local text = texts.change_by("owner@example.com", T, SOON)
				assert.is_nil(text:find("example", 1, true))
			end)

			it("reads the source without regard to case or spaces", function()
				assert.equal("Remote or wall control at 14:02", texts.change_by(" BLE ", T, SOON))
			end)

			it("the time gets its date when older than 24 h", function()
				assert.equal("Modern Forms cloud (app away, voice assistant) at 10-27 14:02",
					texts.change_by("cloud", T, LATER))
			end)

			it("without a time just the source", function()
				assert.equal("Remote or wall control", texts.change_by("ble", nil, SOON))
				assert.equal("Outside Control4 (source not reported)", texts.change_by(nil, nil, nil))
			end)
		end)

		describe("Fan Automations", function()
			it("None when nothing is active", function()
				assert.equal("None", texts.automations({}))
				assert.equal("None", texts.automations(state({ away = false, learning = false, schedule_set = false,
					fan_timer = 0, light_timer = 0 }), "3"))
			end)

			it("each item alone", function()
				assert.equal("Active: schedule", texts.automations({ schedule_set = true }))
				assert.equal("Active: away mode", texts.automations({ away = true }))
				assert.equal("Active: adaptive learning", texts.automations({ learning = true }))
				assert.equal("Active: fan timer 25 min", texts.automations({ fan_timer = 1500 }, "3"))
				assert.equal("Active: light timer 10 min", texts.automations({ light_timer = 600 }, "3"))
			end)

			it("the contract's items in its order, joined by commas", function()
				assert.equal("Active: schedule, away mode, adaptive learning, fan timer 25 min",
					texts.automations({ schedule_set = true, away = true, learning = true, fan_timer = 1500 }, "3"))
				assert.equal("Active: schedule, away mode", texts.automations({ away = true, schedule_set = true }))
				assert.equal("Active: adaptive learning, light timer 1 min",
					texts.automations({ light_timer = 5, learning = true }, "3"))
			end)

			it("Gen 3 timers are minutes rounded up", function()
				local cases = { { 1, 1 }, { 59, 1 }, { 60, 1 }, { 61, 2 }, { 600, 10 }, { 1500, 25 }, { 3601, 61 } }
				for _, case in ipairs(cases) do
					assert.equal("Active: fan timer " .. case[2] .. " min",
						texts.automations({ fan_timer = case[1] }, "3"), case[1] .. " s")
				end
			end)

			it("a timer with no time left, or a value that is not a time, is not active", function()
				for _, seconds in ipairs({ 0, -1, "0", "", "soon", true, false, {}, 0 / 0 }) do
					assert.equal("None", texts.automations({ fan_timer = seconds, light_timer = seconds }, "3"),
						tostring(seconds))
				end
			end)

			it("Gen 1/2 timers are only set", function()
				assert.equal("Active: fan timer set", texts.automations({ fan_sleep_timer = 1700000000 }, "1/2"))
				assert.equal("Active: light timer set", texts.automations({ light_sleep_timer = 1700000000 }, "1/2"))
				assert.equal("Active: fan timer set, light timer set",
					texts.automations({ fan_sleep_timer = 1700000000, light_sleep_timer = 1700000001 }, "1/2"))
				assert.equal("None", texts.automations({ fan_sleep_timer = 0, light_sleep_timer = 0 }, "1/2"))
			end)

			it("the generation says which timers count", function()
				local both = { fan_timer = 1500, fan_sleep_timer = 1700000000 }
				assert.equal("Active: fan timer 25 min", texts.automations(both, "3"))
				assert.equal("Active: fan timer set", texts.automations(both, "1/2"))
			end)

			it("the state's own generation is used when none is passed; with neither, the fields that came", function()
				assert.equal("Active: fan timer set", texts.automations({ generation = "1/2", fan_timer = 600,
					fan_sleep_timer = 5 }))
				assert.equal("Active: fan timer 10 min", texts.automations({ fan_timer = 600 }))
				assert.equal("Active: fan timer set", texts.automations({ fan_sleep_timer = 5 }))
			end)

			it("only whether a schedule is set, never the schedule itself", function()
				local text = texts.automations({ schedule = "QkxPQg==", schedule_set = true })
				assert.equal("Active: schedule", text)
				assert.equal("None", texts.automations({ schedule = "QkxPQg==" }), "only schedule_set counts")
			end)

			it("is empty when there is no state to judge", function()
				assert.equal("", texts.automations(nil))
				assert.equal("", texts.automations("away"))
			end)

			it("shortens the two longest names when every item is active, to stay under what Composer shows", function()
				local gen3 = texts.automations({ schedule_set = true, away = true, learning = true, fan_timer = 1500,
					light_timer = 600 }, "3")
				assert.equal("Active: schedule, away, learning, fan timer 25 min, light timer 10 min", gen3)
				assert.equal(70, #gen3)
				local gen12 = texts.automations({ schedule_set = true, away = true, learning = true, fan_sleep_timer = 1,
					light_sleep_timer = 1 }, "1/2")
				assert.equal("Active: schedule, away, learning, fan timer set, light timer set", gen12)
				assert.equal(64, #gen12)
			end)
		end)

		describe("Keypad Links", function()
			local function row(link, keypad, id)
				return { link_name = link, keypad_name = keypad, device_id = id }
			end

			it("the count, then one item per bound keypad", function()
				assert.same({ "1 of 13 links bound", "Fan Speed 3: Example Keypad (456)" },
					texts.keypad_links({ row("Fan Speed 3 Button Link", "Example Keypad", 456) }))
			end)

			it("the Breeze link's row is Fan Breeze (breeze-design section 5)", function()
				local items = texts.keypad_links({ row("Fan Breeze Button Link", "Example Keypad", 456) })
				assert.same({ "1 of 13 links bound", "Fan Breeze: Example Keypad (456)" }, items)
				assert.same(items, texts.keypad_links({ row("Fan Breeze", "Example Keypad", 456) }, 13))
			end)

			it("the count is of links, not keypads: two keypads on one link are one", function()
				local items = texts.keypad_links({
					row("Fan Speed 2 Button Link", "Example Keypad", 456),
					row("Fan Speed 2 Button Link", "Second Keypad", 457),
					row("Fan Off Button Link", "Example Keypad", 456),
				})
				assert.same({ "2 of 13 links bound", "Fan Speed 2: Example Keypad (456)",
					"Fan Speed 2: Second Keypad (457)", "Fan Off: Example Keypad (456)" }, items)
			end)

			it("none bound", function()
				assert.same({ "0 of 13 links bound" }, texts.keypad_links({}))
				assert.same({ "0 of 13 links bound" }, texts.keypad_links(nil))
			end)

			it("takes the link name with or without Button Link, and rows as arrays", function()
				assert.same({ "2 of 13 links bound", "Light Top: Example Keypad (456)", "Fan Cycle: Example Keypad (456)" },
					texts.keypad_links({ { "Light Top Button Link", "Example Keypad", 456 },
						row("Fan Cycle", "Example Keypad", "456") }))
			end)

			it("a keypad that has no name shows as its device", function()
				assert.same({ "1 of 13 links bound", "Fan Toggle: device 456" },
					texts.keypad_links({ row("Fan Toggle Button Link", nil, 456) }))
				assert.same({ "1 of 13 links bound", "Fan Toggle: device 456" },
					texts.keypad_links({ row("Fan Toggle Button Link", "  ", 456) }))
				assert.same({ "1 of 13 links bound", "Fan Toggle: Example Keypad (?)" },
					texts.keypad_links({ row("Fan Toggle Button Link", "Example Keypad", nil) }))
			end)

			it("commas in a name become U+201A: an item of the list never holds one", function()
				local comma = "\226\128\154"
				local items = texts.keypad_links({ row("Fan Off Button Link", "Hall, Upstairs", 456) })
				assert.equal("Fan Off: Hall" .. comma .. " Upstairs (456)", items[2])
				for _, item in ipairs(items) do
					assert.is_nil(item:find(",", 1, true))
				end
			end)

			it("control characters in a name are dropped", function()
				local items = texts.keypad_links({ row("Fan Off Button Link", "Hall\nKeypad\t", 456) })
				assert.equal("Fan Off: HallKeypad (456)", items[2])
			end)

			it("counts against the number of links it is given, 13 by default (breeze-design section 5)", function()
				assert.equal(13, texts.LINK_COUNT)
				assert.equal("1 of 14 links bound", texts.keypad_links({ row("Fan Off", "K", 1) }, 14)[1])
				assert.equal("1 of 13 links bound", texts.keypad_links({ row("Fan Off", "K", 1) }, "many")[1])
				assert.equal("1 of 13 links bound", texts.keypad_links({ row("Fan Off", "K", 1) }, 1e308)[1])
			end)

			it("passes rows that are not tables over", function()
				assert.same({ "1 of 13 links bound", "Fan Off: K (1)" },
					texts.keypad_links({ "x", 5, row("Fan Off", "K", 1) }))
			end)
		end)

		-- keypad-leds-visibility-design KL-D7: the note the driver puts after the
		-- first row; ambient-pause-design AP-D10 (#207): the pause while the
		-- keypad bound to Ambient Light Level (Follower) is dark.
		describe("Keypad Links' note", function()
			local SHOWN = "; LED settings shown"
			local HIDDEN = "; LED settings hidden: bind a button to a Fan Speed link"
			local DARK = "; LED animations paused: the keypad is dark"

			it("without the dark argument reads as before: shown or hidden (KL-D7)", function()
				assert.equal(SHOWN, texts.keypad_leds_note(true))
				assert.equal(HIDDEN, texts.keypad_leds_note(false))
				assert.equal(HIDDEN, texts.keypad_leds_note(nil))
				assert.equal(HIDDEN, texts.keypad_leds_note())
			end)

			it("with the keypad not dark reads as before", function()
				assert.equal(SHOWN, texts.keypad_leds_note(true, false))
				assert.equal(SHOWN, texts.keypad_leds_note(true, nil))
				assert.equal(HIDDEN, texts.keypad_leds_note(false, false))
			end)

			it("while the keypad is dark says the animations are paused, in place of LED settings shown (AP-D10)",
				function()
					assert.equal(DARK, texts.keypad_leds_note(true, true))
				end)

			it("keeps the binding hint while the rows are hidden: no speed link, nothing to pause", function()
				assert.equal(HIDDEN, texts.keypad_leds_note(false, true))
				assert.equal(HIDDEN, texts.keypad_leds_note(nil, true))
			end)

			it("counts only true as dark", function()
				for _, value in ipairs({ 1, "true", "dark", {}, 0 }) do
					assert.equal(SHOWN, texts.keypad_leds_note(true, value), tostring(value))
				end
			end)

			it("leaves the first row under Composer's 75 characters, with no comma, ASCII only", function()
				for _, note in ipairs({ SHOWN, HIDDEN, DARK }) do
					assert.is_nil(note:find(",", 1, true), note)
					assert.is_nil(note:find("[^\32-\126]"), note)
				end
				-- Every link bound: the longest first row the pause can follow.
				local first = texts.keypad_links({ { "Fan Speed 3 Button Link", "K", 1 } }, 13)[1]:gsub("^1 ", "13 ")
				assert.equal("13 of 13 links bound; LED animations paused: the keypad is dark",
					first .. texts.keypad_leds_note(true, true))
				assert.equal(63, #(first .. texts.keypad_leds_note(true, true)))
				-- The most links bound with none of them a speed link (Off, Toggle,
				-- Cycle, Breeze and the light's three): dark adds nothing.
				assert.equal(75, #("7 of 13 links bound" .. texts.keypad_leds_note(false, true)))
			end)

			-- ambient-pause-design AP-D17 (#223): while paused, the note names the
			-- last counted reading and its time, { level, at_s, now_s }.
			describe("with the last reading", function()
				local NIGHT = at(2026, 11, 12, 23, 51) -- shown as 23:51
				local function last(level, at_s, now_s)
					return { level = level, at_s = at_s, now_s = now_s }
				end

				-- The first row with every link bound: 13 links, each its own.
				local function every_link_bound()
					local rows = {}
					for index = 1, texts.LINK_COUNT do
						rows[index] = { "Link " .. index .. " Button Link", "K", index }
					end
					return texts.keypad_links(rows)[1]
				end

				it("names the level and the time it was read", function()
					assert.equal("; LED animations paused: the keypad read 1 at 23:51",
						texts.keypad_leds_note(true, true, last(1, NIGHT, NIGHT + 60)))
					assert.equal("; LED animations paused: the keypad read 0 at 23:51",
						texts.keypad_leds_note(true, true, last(0, NIGHT, NIGHT)))
					assert.equal("; LED animations paused: the keypad read 255 at 23:51",
						texts.keypad_leds_note(true, true, last(255, NIGHT, NIGHT + 86400)), "exactly 24 h")
				end)

				it("gives the time without a present as texts.clock does, the hour alone", function()
					assert.equal("; LED animations paused: the keypad read 3 at 23:51",
						texts.keypad_leds_note(true, true, last(3, NIGHT)))
					assert.equal("; LED animations paused: the keypad read 3 at 23:51",
						texts.keypad_leds_note(true, true, last(3, NIGHT, "now")))
				end)

				it("adds the date once the reading is over a day old, without 'the' so that the row fits", function()
					assert.equal("; LED animations paused: keypad read 1 at 11-12 23:51",
						texts.keypad_leds_note(true, true, last(1, NIGHT, NIGHT + 86401)))
					assert.equal("; LED animations paused: keypad read 255 at 11-12 23:51",
						texts.keypad_leds_note(true, true, last(255, NIGHT, NIGHT + 3 * 86400)))
				end)

				it("names the level alone when the time cannot be shown", function()
					for _, at_s in ipairs({ 1e300, 0 / 0, math.huge, -math.huge }) do
						assert.equal("; LED animations paused: the keypad read 4",
							texts.keypad_leds_note(true, true, last(4, at_s, NIGHT)), tostring(at_s))
					end
				end)

				it("without it reads as today", function()
					assert.equal(DARK, texts.keypad_leds_note(true, true))
					assert.equal(DARK, texts.keypad_leds_note(true, true, nil))
				end)

				it("reads as today when it is not a reading: a bad level, a time that is no number", function()
					local bad = {
						last(0 / 0, NIGHT, NIGHT),
						last(math.huge, NIGHT, NIGHT),
						last(-1, NIGHT, NIGHT),
						last(256, NIGHT, NIGHT),
						last(1.5, NIGHT, NIGHT),
						last("5", NIGHT, NIGHT),
						last(nil, NIGHT, NIGHT),
						last(true, NIGHT, NIGHT),
						last(5, tostring(NIGHT), NIGHT),
						last(5, nil, NIGHT),
						last(5, {}, NIGHT),
						last(5, true, NIGHT),
						{ 5, NIGHT, NIGHT },
						{},
						"read 5",
						5,
						true,
					}
					for index, value in ipairs(bad) do
						assert.equal(DARK, texts.keypad_leds_note(true, true, value), "case " .. index)
					end
				end)

				it("changes nothing while not shown or not dark", function()
					local good = last(1, NIGHT, NIGHT + 60)
					assert.equal(SHOWN, texts.keypad_leds_note(true, false, good))
					assert.equal(SHOWN, texts.keypad_leds_note(true, nil, good))
					assert.equal(SHOWN, texts.keypad_leds_note(true, 1, good))
					assert.equal(HIDDEN, texts.keypad_leds_note(false, true, good))
					assert.equal(HIDDEN, texts.keypad_leds_note(nil, true, good))
					assert.equal(HIDDEN, texts.keypad_leds_note(false, false, good))
				end)

				it("keeps every first row at or under Composer's 75 characters, with no comma, ASCII only", function()
					local first = every_link_bound()
					assert.equal("13 of 13 links bound", first)
					local longest = 0
					for _, level in ipairs({ 0, 9, 10, 99, 100, 255 }) do
						for _, now_s in ipairs({ NIGHT, NIGHT + 86400, NIGHT + 86401, NIGHT + 40 * 86400, "?" }) do
							for _, at_s in ipairs({ NIGHT, 0 / 0 }) do
								local note = texts.keypad_leds_note(true, true, last(level, at_s, now_s))
								local row = first .. note
								assert.is_true(#row <= texts.ROW_CUT, row)
								assert.is_nil(note:find(",", 1, true), note)
								assert.is_nil(note:find("[^\32-\126]"), note)
								longest = math.max(longest, #row)
							end
						end
					end
					-- The longest: a three-digit level over a day old, exactly at the cut.
					assert.equal(75, longest)
					assert.equal("13 of 13 links bound; LED animations paused: keypad read 255 at 11-12 23:51",
						first .. texts.keypad_leds_note(true, true, last(255, NIGHT, NIGHT + 86401)))
					-- Within a day "the" stays: 73 at most.
					assert.equal(73, #(first .. texts.keypad_leds_note(true, true, last(255, NIGHT, NIGHT + 60))))
					-- With fewer links bound the date form is shorter still.
					assert.equal("4 of 13 links bound; LED animations paused: keypad read 1 at 11-12 23:51",
						"4 of 13 links bound" .. texts.keypad_leds_note(true, true, last(1, NIGHT, NIGHT + 86401)))
				end)
			end)
		end)

		-- auto-discovery-design 3.1 and 3.2: texts.found_rows(view) gives the
		-- summary (the first item, and the value while no pick waits) and the item
		-- rows under it; the summary is not repeated in the items.
		describe("Found Fans", function()
			-- An entry as found:entries gives it (auto-discovery-design 6.2):
			-- entry(1) is MF_Fan_005301 at 10.0.2.151, entry(2) MF_Fan_005302 at
			-- 10.0.2.152 (the placeholder fans), entry(3) and on MF_Fan_0053NN at
			-- 192.0.2.(150 + NN) (TEST-NET-1: the scan refuses any other address).
			local function entry(n, over)
				local tail = string.format("%04d", 5300 + n)
				local net = n <= 2 and "10.0.2." or "192.0.2."
				local e = { key = "00005e00" .. tail, instance = "MF_Fan_00" .. tail, address = net .. (150 + n),
					mac = "00005e00" .. tail }
				for key, value in pairs(over or {}) do
					e[key] = value
				end
				return e
			end
			local function entries(n, first)
				local list = {}
				for i = 1, n do
					list[i] = entry(i, i == 1 and first or nil)
				end
				return list
			end
			local function rows(view)
				local summary, items = texts.found_rows(view)
				return summary, items
			end
			local AVIATOR = { fan_type = "1811-5-54" }

			describe("the summary (section 3.1)", function()
				-- { what, view, the text verbatim, its length }
				local cases = {
					{ "from load until the first window closed", { state = "looking", entries = {} },
						"Looking for Modern Forms fans on the network...", 47 },
					{ "the last window could not open or send", { state = "failing", entries = {} },
						"No search possible on this controller: enter Fan Address", 56 },
					{ "unpinned, two fans", { state = "listed", entries = entries(2) },
						"2 fans found: pick one and click Set to use it", 46 },
					{ "unpinned, one fan: singular", { state = "listed", entries = entries(1) },
						"1 fan found: pick it and click Set to use it", 44 },
					{ "unpinned, none", { state = "listed", entries = {} },
						"No fan found yet: enter its address in Fan Address", 50 },
					{ "pinned, its fan heard, alone", { state = "listed", pinned = true, entries = entries(1, { own = true }) },
						"This device's fan answered; no other fan found", 46 },
					{ "pinned, its fan heard, others too", { state = "listed", pinned = true,
						entries = entries(3, { own = true }) }, "3 fans found; this device's fan is listed first", 47 },
					{ "pinned, its fan not heard, two others", { state = "listed", pinned = true, entries = entries(2) },
						"2 fans found; this device's fan did not answer", 46 },
					{ "pinned, its fan not heard, one other: singular", { state = "listed", pinned = true,
						entries = entries(1) }, "1 fan found; this device's fan did not answer", 45 },
					{ "pinned, none heard", { state = "listed", pinned = true, entries = {} },
						"No fan answered the last search", 31 },
					{ "stopped", { state = "stopped", pinned = true, entries = {} },
						"Not searching while Fan Address is empty", 40 },
				}
				for _, case in ipairs(cases) do
					it(case[1] .. ": '" .. case[3] .. "' (" .. case[4] .. " characters)", function()
						local summary = rows(case[2])
						assert.equal(case[3], summary)
						assert.equal(case[4], #summary)
						assert.is_true(#summary <= 70)
					end)
				end

				it("two fans with this device's fan is the smallest 'listed first' count", function()
					assert.equal("2 fans found; this device's fan is listed first",
						rows({ state = "listed", pinned = true, entries = entries(2, { own = true }) }))
				end)

				it("counts every entry, also those past the overflow row", function()
					assert.equal("40 fans found: pick one and click Set to use it", rows({ state = "listed", entries = entries(40) }))
					assert.equal("40 fans found; this device's fan is listed first",
						rows({ state = "listed", pinned = true, entries = entries(40, { own = true }) }))
					assert.equal("40 fans found; this device's fan did not answer",
						rows({ state = "listed", pinned = true, entries = entries(40) }))
				end)

				it("looking, failing and stopped say so whatever the entries are", function()
					for _, list in ipairs({ {}, entries(1), entries(3, { own = true }) }) do
						assert.equal("Looking for Modern Forms fans on the network...", rows({ state = "looking", entries = list }))
						assert.equal("No search possible on this controller: enter Fan Address",
							rows({ state = "failing", pinned = true, entries = list }))
						assert.equal("Not searching while Fan Address is empty", rows({ state = "stopped", entries = list }))
					end
				end)

				it("a missing or unknown state reads as listed", function()
					assert.equal("2 fans found: pick one and click Set to use it", rows({ entries = entries(2) }))
					assert.equal("2 fans found: pick one and click Set to use it", rows({ state = "bogus", entries = entries(2) }))
					assert.equal("No fan found yet: enter its address in Fan Address", rows({}))
					assert.equal("No fan found yet: enter its address in Fan Address", rows(nil))
				end)

				it("only pinned = true picks the pinned rows; this device's entry picks among them", function()
					assert.equal("1 fan found: pick it and click Set to use it",
						rows({ state = "listed", pinned = "yes", entries = entries(1, { own = true }) }))
					assert.equal("1 fan found; this device's fan did not answer",
						rows({ state = "listed", pinned = true, entries = entries(1, { own = "yes" }) }))
				end)

				it("the summary is never one of the items", function()
					local summary, items = rows({ state = "listed", pinned = true, entries = entries(3, { own = true }) })
					assert.equal(3, #items)
					for _, item in ipairs(items) do
						assert.not_equal(summary, item)
					end
				end)
			end)

			describe("an item (section 3.2)", function()
				it("one per entry, in the order given: the instance and the address", function()
					local _, items = rows({ state = "listed", entries = { entry(1), entry(2) } })
					assert.same({ "MF_Fan_005301 at 10.0.2.151", "MF_Fan_005302 at 10.0.2.152" }, items)
					_, items = rows({ state = "listed", entries = { entry(2), entry(1) } })
					assert.same({ "MF_Fan_005302 at 10.0.2.152", "MF_Fan_005301 at 10.0.2.151" }, items)
				end)

				it("this device's fan with the name fan.names knows: the contract's text, 52 characters", function()
					KNOWN["1811-5-54"] = "Aviator 5"
					local _, items = rows({ state = "listed", pinned = true, entries = { entry(1, { own = true }), entry(2) },
						info = AVIATOR })
					assert.same({ "MF_Fan_005301 at 10.0.2.151 (this device: Aviator 5)", "MF_Fan_005302 at 10.0.2.152" }, items)
					assert.equal(52, #items[1])
				end)

				it("looks the type up trimmed, as Fan Model does", function()
					KNOWN["1811-5-54"] = "Aviator 5"
					local _, items = rows({ pinned = true, entries = { entry(1, { own = true }) },
						info = { fan_type = " 1811-5-54\t" } })
					assert.equal("MF_Fan_005301 at 10.0.2.151 (this device: Aviator 5)", items[1])
				end)

				it("this device's fan without a known name: (this device's fan)", function()
					local plain = "MF_Fan_005301 at 10.0.2.151 (this device's fan)"
					local own = { entry(1, { own = true }) }
					assert.equal(plain, select(2, rows({ pinned = true, entries = own, info = AVIATOR }))[1], "a type the table lacks")
					KNOWN["1811-5-54"] = "Aviator 5"
					assert.equal(plain, select(2, rows({ pinned = true, entries = own }))[1], "no info")
					assert.equal(plain, select(2, rows({ pinned = true, entries = own, info = {} }))[1], "no fan type")
					assert.equal(plain, select(2, rows({ pinned = true, entries = own, info = "1811-5-54" }))[1], "info not a table")
					fake_names.lookup = function()
						error("broken table")
					end
					assert.equal(plain, select(2, rows({ pinned = true, entries = own, info = AVIATOR }))[1], "a lookup that raises")
					fake_names.lookup = function()
						return "   "
					end
					assert.equal(plain, select(2, rows({ pinned = true, entries = own, info = AVIATOR }))[1], "a blank name")
				end)

				it("marks only an entry whose own is true, and reads no name for the others", function()
					KNOWN["1811-5-54"] = "Aviator 5"
					local _, items = rows({ pinned = true, entries = { entry(1, { own = "yes" }), entry(2, { own = 1 }) },
						info = AVIATOR })
					assert.same({ "MF_Fan_005301 at 10.0.2.151", "MF_Fan_005302 at 10.0.2.152" }, items)
					local asked = 0
					fake_names.lookup = function()
						asked = asked + 1
						return "Aviator 5"
					end
					rows({ pinned = true, entries = entries(3), info = AVIATOR })
					assert.equal(0, asked, "no entry of this device: no lookup")
				end)

				it("cuts the instance at its START to 25 characters, no marker, so the MAC digits stay", function()
					local i25 = "WAC Windermier Fan#005302"
					assert.equal(25, #i25)
					local _, items = rows({ entries = { entry(2, { instance = i25 }) } })
					assert.equal("WAC Windermier Fan#005302 at 10.0.2.152", items[1], "25 stay whole")
					_, items = rows({ entries = { entry(2, { instance = "Ceiling " .. i25 }) } })
					assert.equal("WAC Windermier Fan#005302 at 10.0.2.152", items[1])
					_, items = rows({ entries = { entry(2, { instance = string.rep("x", 100) .. "_005302" }) } })
					assert.equal(string.rep("x", 18) .. "_005302 at 10.0.2.152", items[1])
				end)

				it("leaves no blank in front when the cut lands on one", function()
					local instance = "Big Kitchen Island Fn 005302"
					assert.equal(" ", instance:sub(-25, -25))
					local _, items = rows({ entries = { entry(2, { instance = instance }) } })
					assert.equal("Kitchen Island Fn 005302 at 10.0.2.152", items[1])
				end)

				it("adds ...5302 to an instance that does not end in the last six hex digits of its MAC", function()
					local _, items = rows({ entries = { entry(2, { instance = "Hall Fan" }) } })
					assert.equal("Hall Fan ...5302 at 10.0.2.152", items[1])
					_, items = rows({ entries = { entry(2, { instance = "005302 Hall Fan" }) } })
					assert.equal("005302 Hall Fan ...5302 at 10.0.2.152", items[1], "the digits must end it")
					_, items = rows({ entries = { entry(2, { instance = "MF_Fan_005301" }) } })
					assert.equal("MF_Fan_005301 ...5302 at 10.0.2.152", items[1], "another fan's digits")
				end)

				it("compares the digits case-blind, whatever the spelling of the MAC", function()
					local _, items = rows({ entries = {
						{ instance = "MF_Fan_0053AB", address = ADDR, mac = "00005e0053ab" },
						{ instance = "MF_Fan_0053ab", address = ADDR, mac = "00:00:5E:00:53:AB" },
						{ instance = "Hall Fan", address = ADDR, mac = "00:00:5e:00:53:ab" },
					} })
					assert.same({ "MF_Fan_0053AB at 10.0.2.151", "MF_Fan_0053ab at 10.0.2.151", "Hall Fan ...53AB at 10.0.2.151" },
						items)
				end)

				it("adds nothing when the entry has no MAC to compare with", function()
					local _, items = rows({ entries = {
						{ key = "i:hall fan", instance = "Hall Fan", address = ADDR },
						{ instance = "Hall Fan", address = ADDR, mac = "0000" },
					} })
					assert.same({ "Hall Fan at 10.0.2.151", "Hall Fan at 10.0.2.151" }, items)
				end)

				it("a cut instance keeps its digits, so the cut alone never adds the mark", function()
					local _, items = rows({ entries = { entry(2, { instance = "Living Room Ceiling Fan MF_Fan_005302" }) } })
					assert.equal("Ceiling Fan MF_Fan_005302 at 10.0.2.152", items[1])
				end)

				it("this device's mark comes after the address, the MAC digits after the instance", function()
					KNOWN["1811-5-54"] = "Aviator 5"
					local _, items = rows({ pinned = true, entries = { entry(1, { own = true, instance = "Bedroom" }) },
						info = AVIATOR })
					assert.equal("Bedroom ...5301 at 10.0.2.151 (this device: Aviator 5)", items[1])
				end)

				it("commas become U+201A, control characters go, other bytes outside printable ASCII show as ?", function()
					local _, items = rows({ entries = {
						{ instance = "Hall, fan\n", address = ADDR },
						{ instance = "caf\195\169", address = ADDR2 },
					} })
					assert.same({ "Hall\226\128\154 fan at 10.0.2.151", "caf?? at 10.0.2.152" }, items)
				end)

				it("leaves out what the answer lacked", function()
					local _, items = rows({ entries = {
						{ address = ADDR }, { instance = "MF_Fan_005301" }, { address = ADDR2, mac = "00005e005302" }, {},
					} })
					assert.same({ "fan at 10.0.2.151", "MF_Fan_005301", "fan ...5302 at 10.0.2.152", "fan" }, items)
				end)

				it("an entry that is not a table keeps its row, so items[i] stays the row of entries[i]", function()
					local _, items = rows({ entries = { "x", entry(2), 5 } })
					assert.same({ "fan", "MF_Fan_005302 at 10.0.2.152", "fan" }, items)
				end)

				it("reads the entries whatever the state says", function()
					for _, list_state in ipairs({ "looking", "failing", "stopped", "listed" }) do
						local _, items = rows({ state = list_state, entries = { entry(1) } })
						assert.same({ "MF_Fan_005301 at 10.0.2.151" }, items, list_state)
					end
				end)

				it("no entry, or no entries table, is no item", function()
					assert.same({}, select(2, rows({ state = "listed", entries = {} })))
					assert.same({}, select(2, rows({ state = "listed" })))
					assert.same({}, select(2, rows({ entries = "x" })))
					assert.same({}, select(2, rows(nil)))
				end)
			end)

			describe("at most 16 item rows (section 3)", function()
				local OVERFLOW = "... and 3 more: enter the address in Fan Address"

				it("16 entries: 16 items, no overflow row", function()
					assert.equal(16, texts.MAX_FOUND)
					local _, items = rows({ entries = entries(16) })
					assert.equal(16, #items)
					assert.equal("MF_Fan_005316 at 192.0.2.166", items[16])
				end)

				it("18 entries: 15 items, then the contract's overflow row as the 16th", function()
					local _, items = rows({ entries = entries(18) })
					assert.equal(16, #items)
					assert.equal("MF_Fan_005301 at 10.0.2.151", items[1])
					assert.equal("MF_Fan_005315 at 192.0.2.165", items[15])
					assert.equal(OVERFLOW, items[16])
					assert.equal(48, #OVERFLOW)
				end)

				it("17 entries: the overflow row counts the two not shown", function()
					local _, items = rows({ entries = entries(17) })
					assert.equal(16, #items)
					assert.equal("MF_Fan_005315 at 192.0.2.165", items[15])
					assert.equal("... and 2 more: enter the address in Fan Address", items[16])
				end)

				it("many entries: still 16 rows, and the count of the rest", function()
					local _, items = rows({ pinned = true, entries = entries(140, { own = true }) })
					assert.equal(16, #items)
					assert.equal("MF_Fan_005301 at 10.0.2.151 (this device's fan)", items[1])
					assert.equal("... and 125 more: enter the address in Fan Address", items[16])
					assert.is_true(#items[16] <= 70)
				end)
			end)

			describe("lengths (section 5: at most 72 with a 15-character address and a 25-character instance)", function()
				local LONG_ADDR = "192.168.100.200"
				local FULL_ADDR = "255.255.255.255"
				local I25 = "ABCDEFGHIJKLMNOPQRSTUVWXY"
				assert(#FULL_ADDR == 15 and #I25 == 25)

				it("the longest item: a 25-character instance without its MAC digits, this device's, no name", function()
					local _, items = rows({ pinned = true, entries = { { instance = I25, address = FULL_ADDR,
						mac = "00005e005301", own = true } } })
					assert.equal(I25 .. " ...5301 at 255.255.255.255 (this device's fan)", items[1])
					assert.equal(72, #items[1])
				end)

				it("drops the product name when the item would pass 72", function()
					KNOWN["1811-5-54"] = "Size Matters 65"
					local own = { instance = "MF_Fan_005301", address = LONG_ADDR, mac = "00005e005301", own = true }
					local _, items = rows({ pinned = true, entries = { own }, info = AVIATOR })
					assert.equal("MF_Fan_005301 at 192.168.100.200 (this device: Size Matters 65)", items[1], "63: it fits")
					own.instance = I25 .. "005301"
					_, items = rows({ pinned = true, entries = { own }, info = AVIATOR })
					assert.equal("GHIJKLMNOPQRSTUVWXY005301 at 192.168.100.200 (this device's fan)", items[1])
					assert.equal(64, #items[1])
				end)

				it("keeps the name at exactly 72 and drops it at 73", function()
					local own = { instance = I25 .. "005301", address = FULL_ADDR, mac = "00005e005301", own = true }
					KNOWN["1811-5-54"] = "Twelve Chars"
					local _, items = rows({ pinned = true, entries = { own }, info = AVIATOR })
					assert.equal("GHIJKLMNOPQRSTUVWXY005301 at 255.255.255.255 (this device: Twelve Chars)", items[1])
					assert.equal(72, #items[1])
					KNOWN["1811-5-54"] = "Thirteen Char"
					_, items = rows({ pinned = true, entries = { own }, info = AVIATOR })
					assert.equal("GHIJKLMNOPQRSTUVWXY005301 at 255.255.255.255 (this device's fan)", items[1])
				end)

				it("counts a comma as the one character Composer shows", function()
					KNOWN["1811-5-54"] = "Twelve Chars"
					local own = { instance = "ABCDEFGHIJKLMNOPQR,005301", address = FULL_ADDR, mac = "00005e005301", own = true }
					local _, items = rows({ pinned = true, entries = { own }, info = AVIATOR })
					assert.equal("ABCDEFGHIJKLMNOPQR\226\128\154005301 at 255.255.255.255 (this device: Twelve Chars)", items[1])
				end)

				it("every item of every shape stays at or under 72, every summary at or under 70", function()
					KNOWN["1811-5-54"] = "Size Matters 65"
					for _, address in ipairs({ ADDR, LONG_ADDR, FULL_ADDR }) do
						for _, instance in ipairs({ "MF_Fan_005301", I25, I25 .. "005301", "", string.rep("y", 300) }) do
							for _, own in ipairs({ true, false }) do
								local e = { instance = instance, address = address, mac = "00005e005301", own = own }
								for _, info in ipairs({ AVIATOR, {} }) do
									local _, items = rows({ pinned = true, entries = { e }, info = info })
									assert.is_true(#items[1] <= 72, #items[1] .. ": " .. items[1])
								end
							end
						end
					end
					for _, list_state in ipairs({ "looking", "failing", "stopped", "listed" }) do
						for _, pinned in ipairs({ true, false }) do
							for _, n in ipairs({ 0, 1, 2, 16, 17, 999 }) do
								local summary = rows({ state = list_state, pinned = pinned, entries = entries(n, { own = pinned }) })
								assert.is_true(#summary <= 70, #summary .. ": " .. summary)
								summary = rows({ state = list_state, pinned = pinned, entries = entries(n) })
								assert.is_true(#summary <= 70, #summary .. ": " .. summary)
							end
						end
					end
				end)
			end)
		end)
	end)

	describe("helpers", function()
		describe("suffix", function()
			it("the last four hex digits of the client id, the MAC, or the MAC with colons", function()
				assert.equal("...5302", texts.suffix(ID2))
				assert.equal("...5302", texts.suffix("WAC_00005E005302"))
				assert.equal("...5302", texts.suffix("00005E005302"))
				assert.equal("...5302", texts.suffix("00:00:5e:00:53:02"))
				assert.equal("...5301", texts.suffix(ID1))
			end)

			it("upper case, like the client id", function()
				assert.equal("...53AB", texts.suffix("00:00:5e:00:53:ab"))
			end)

			it("never the whole id", function()
				assert.is_nil(texts.suffix(ID1):find("5E", 1, true))
				assert.equal(7, #texts.suffix(ID1))
			end)

			it("...? where there is nothing to show; fewer than four digits show as they are", function()
				assert.equal("...?", texts.suffix(nil))
				assert.equal("...?", texts.suffix(""))
				assert.equal("...?", texts.suffix("zzz"))
				assert.equal("...?", texts.suffix({}))
				assert.equal("...A1", texts.suffix("a1"))
			end)
		end)

		describe("mac", function()
			it("12 hex digits as the Fan ID row shows them", function()
				assert.equal("00:00:5e:00:53:01", texts.mac("00005E005301"))
				assert.equal("00:00:5e:00:53:01", texts.mac("00005e005301"))
			end)

			it("a MAC that already has colons or dashes", function()
				assert.equal("00:00:5e:00:53:01", texts.mac("00:00:5E:00:53:01"))
				assert.equal("00:00:5e:00:53:01", texts.mac("00-00-5E-00-53-01"))
			end)

			it("is empty for anything that is not 12 hex digits", function()
				for _, text in ipairs({ "", "00005E00530", "00005E0053012", "zz", ID1, 5, true }) do
					assert.equal("", texts.mac(text), tostring(text))
				end
				assert.equal("", texts.mac(nil))
			end)
		end)

		describe("clock", function()
			it("HH:MM within a day", function()
				assert.equal("14:02", texts.clock(T, SOON))
				assert.equal("14:02", texts.clock(T, T))
				assert.equal("14:02", texts.clock(T, T + 86400), "exactly 24 h")
				assert.equal("00:00", texts.clock(at(2026, 10, 27, 0, 0), SOON))
				assert.equal("23:59", texts.clock(at(2026, 10, 27, 23, 59), SOON))
			end)

			it("MM-DD HH:MM once older than 24 h", function()
				assert.equal("10-27 14:02", texts.clock(T, T + 86401))
				assert.equal("10-27 14:02", texts.clock(T, LATER))
				assert.equal("01-05 09:07", texts.clock(at(2027, 1, 5, 9, 7), at(2027, 3, 1, 0, 0)))
			end)

			it("HH:MM when the present is not known, or is before the time", function()
				assert.equal("14:02", texts.clock(T))
				assert.equal("14:02", texts.clock(T, nil))
				assert.equal("14:02", texts.clock(T, "now"))
				assert.equal("14:02", texts.clock(T, T - 90000))
			end)

			it("is empty when the time is not a time", function()
				for _, value in ipairs({ "", "later", true, {}, 1e300, 0 / 0 }) do
					assert.equal("", texts.clock(value, SOON), tostring(value))
				end
				assert.equal("", texts.clock(nil, SOON))
			end)
		end)

		describe("list_item", function()
			it("replaces commas with U+201A and drops control characters", function()
				assert.equal("a\226\128\154 b", texts.list_item("a, b"))
				assert.equal("ab", texts.list_item("a\0b\r\n\t\127"))
				assert.equal("", texts.list_item(nil))
				assert.equal("5", texts.list_item(5))
			end)
		end)
	end)

	describe("private data (V20, section 3.7)", function()
		local blob = {
			owner = "owner@example.com", federatedIdentity = "us-east-1:00000000-0000-0000-0000-000000000000",
			deviceName = "Example Fan", SSID = "example-ssid", BSSID = "00:00:5e:00:53:ff", timezone = "UTC",
			schedule = "QkxPQkJMT0I=", certificateId = "cert-0", owner_email = "owner@example.com",
		}
		local function with(base)
			for key, value in pairs(blob) do
				base[key] = value
			end
			return base
		end
		local function assert_clean(text)
			for _, secret in pairs(blob) do
				assert.is_nil(text:find(secret, 1, true), secret .. " in: " .. text)
			end
		end

		it("no row reads the fields the fan keeps private", function()
			assert_clean(texts.status(online({ st = with(state()) })))
			assert_clean(texts.status(with({ phase = "foreign", other = ID2, address = ADDR })))
			assert_clean(texts.automations(with({ schedule_set = true, away = true })))
			assert_clean(texts.fan_id(with({ client_id = ID1, mac = MAC1 })))
			assert_clean(texts.fan_model(with({ generation = "3" }), with({ fan_type = "1811-5-54", light_type = "L" }), true))
			KNOWN["1811-5-54"] = "Aviator 5"
			assert_clean(texts.fan_model(with({ generation = "3" }), with({ fan_type = "1811-5-54", light_type = "L" }), true))
			assert_clean(texts.firmware(with({ firmware = "02.00.0052", mcu_firmware = "03.00.0000" })))
			assert_clean(texts.result("learned", with({ client_id = ID1, generation = "3", address = ADDR })))
			assert_clean(texts.result("name_renamed", with({ fan = "Sample", light = "Sample Light" })))
			assert_clean(texts.result("name_same", with({ fan = "Sample", light = "Sample Light" })))
			assert_clean(texts.result("name_unknown", with({ fan_type = "1811-5-54" })))
			for _, key in ipairs({ "name_no_type", "name_no_ids", "name_unconfirmed", "name_no_pin", "name_busy" }) do
				assert_clean(texts.result(key, with({ client_id = ID1, address = ADDR })))
			end
			assert_clean(texts.change_by(blob.owner, T, SOON))
			for _, list_state in ipairs({ "looking", "failing", "stopped", "listed" }) do
				local summary, items = texts.found_rows(with({ state = list_state, pinned = true,
					info = with({ fan_type = "1811-5-54" }),
					entries = { with({ key = "00005e005301", instance = "MF_Fan_005301", address = ADDR, mac = "00005e005301",
						own = true }), with({ key = "00005e005302", instance = "MF_Fan_005302", address = ADDR2,
						mac = "00005e005302" }) } }))
				assert_clean(summary)
				assert_clean(table.concat(items, "|"))
			end
			assert_clean(texts.result("picked_wait", with({ instance = "MF_Fan_005302", client_id = ID2 })))
			for _, key in ipairs({ "breeze_unavailable", "breeze_strength", "breeze_refused", "breeze_switch_added",
				"breeze_switch_exists", "breeze_switch_no_breeze", "breeze_switch_no_fan", "breeze_switch_failed" }) do
				assert_clean(texts.result(key, with({ client_id = ID1, address = ADDR, strength = "5", why = "unset",
					name = "Aviator 5 Breeze", pin = with({ client_id = ID1 }) })))
			end
			assert_clean(texts.status(online({ st = with(state({ wind = true, wind_speed = 2 })) })))
			assert_clean(table.concat(texts.keypad_links({ with({ link_name = "Fan Off", keypad_name = "K", device_id = 1 }) }),
				"|"))
		end)

		it("another fan's id is shown only as its last four digits", function()
			local text = texts.status({ phase = "foreign", other = ID2, address = ADDR })
			assert.is_nil(text:find(ID2, 1, true))
			assert.is_nil(text:find("00005E005302", 1, true))
			assert.truthy(text:find("...5302", 1, true))
		end)

		it("the pinned fan's id appears in full in Fan ID and Last Action L1 to L4 only, as the contract shows", function()
			local shown = {
				texts.fan_id({ client_id = ID1, mac = MAC1 }),
				texts.result("learned", { client_id = ID1, generation = "3", address = ADDR }),
				texts.result("moved", { client_id = ID1, address = ADDR2 }),
				texts.result("already", { client_id = ID1, address = ADDR }),
			}
			for _, text in ipairs(shown) do
				assert.truthy(text:find(ID1, 1, true), text)
			end
			local hidden = {
				texts.status(online()), texts.status({ phase = "foreign", other = ID1, address = ADDR }),
				texts.change_by("ble", T, SOON), texts.last_seen(T, 300), texts.firmware({ firmware = "02.00.0052" }),
				texts.automations({ away = true }), texts.result("reboot_refused", { address = ADDR }),
			}
			for _, text in ipairs(hidden) do
				assert.is_nil(text:find("00005E005301", 1, true), text)
			end
		end)
	end)

	describe("lengths (section 2.5, 7.1 and 10.2)", function()
		-- Every text with these inputs, labelled.
		local function every_text(address, client, now)
			local out = {}
			local function add(label, text)
				out[#out + 1] = { label, text }
			end
			local views = {
				S1 = { phase = "unset", failing = true }, S2 = { phase = "unset" },
				S3 = { phase = "unset", typed = string.rep("x", 40) }, S4 = { phase = "waiting", address = address },
				S5 = online({ address = address, st = state({ speed = 6, direction = "reverse", wind = true, wind_speed = 3,
					level = 100 }) }),
				S5b = online({ address = address, st = state({ fan_on = false, direction = "reverse", wind = true,
					level = 100 }) }),
				S6 = online({ address = address, missing = "lightBrightness" }),
				S6b = online({ address = address, missing = "fanDirection" }),
				S7 = { phase = "offline", address = address, since = T, now = now, known = true },
				S8 = { phase = "offline", address = address, since = T, now = now },
				S9 = { phase = "offline", failure = "data", address = address, since = T, now = now, known = true },
				S9b = { phase = "offline", failure = "data", address = address, since = T, now = now },
				S10 = { phase = "rebooting", sent = T, now = now },
				S11 = { phase = "foreign", other = client, address = address },
				S12 = { phase = "gen4", address = address }, S13 = { phase = "notfan", address = address },
				S14 = online({ os = "3.2.99" .. ".1", address = address }),
			}
			for label, view in pairs(views) do
				add(label, texts.status(view))
			end
			for _, key in ipairs(texts.RESULT_KEYS) do
				for _, which in ipairs({ "away", "learning" }) do
					-- L22 to L24 with the longest name of the research table and a type that gets cut;
					-- L34 to L37 with a strength, a reason key and a switch name that get cut.
					add("L " .. key .. " " .. which, texts.result(key, { client_id = client, was = client, address = address,
						generation = "1/2", instance = "ABCDEFGHIJKLMNOPQRSTUVWXY", at = T, now = now, which = which,
						fan = "Size Matters 65", light = "Size Matters 65 Light", fan_type = string.rep("x", 20),
						strength = string.rep("9", 20), why = "no " .. string.rep("k", 40), name = string.rep("N", 80) }))
				end
			end
			add("Fan ID", texts.fan_id({ client_id = client, mac = "00005E005301" }))
			add("Fan Model", texts.fan_model({ generation = "1/2" },
				{ fan_type = "1811-5-54", light_type = "F4IN-120V-R1-30", has_light = true }, true))
			-- With a name: the longest row of the research table (FNR Appendix B).
			KNOWN["2403-65"] = "Size Matters 65"
			add("Fan Model named", texts.fan_model({ generation = "1/2" },
				{ fan_type = "2403-65", light_type = "F4IN-120V-R1-30", has_light = true }, true))
			KNOWN["2403-65"] = nil
			add("Firmware", texts.firmware({ firmware = "02.00.0060", mcu_firmware = "03.00.0000",
				firmware_since = "2026-11-02", firmware_was = "02.00.0052" }))
			add("Last Seen", texts.last_seen(T, 12345))
			for _, source in ipairs({ "ble", "local_wifi", "cloud", "sleep_timer", "away_mode", "schedule", "none" }) do
				add("Last Change By " .. source, texts.change_by(source, T, now))
			end
			add("Fan Automations", texts.automations({ schedule_set = true, away = true, fan_timer = 1500 }, "3"))
			add("Fan Automations 1/2", texts.automations({ schedule_set = true, away = true, fan_sleep_timer = 1,
				light_sleep_timer = 1 }, "1/2"))
			for _, item in ipairs(texts.keypad_links({ { "Light Toggle Button Link", "Example Keypad", 123456 } })) do
				add("Keypad Links", item)
			end
			-- Found Fans: this device's fan named, another fan, and the summary of
			-- every state (its own section holds the 72-character items).
			KNOWN["1811-5-54"] = "Aviator 5"
			for _, list_state in ipairs({ "looking", "failing", "stopped", "listed" }) do
				local summary, items = texts.found_rows({ state = list_state, pinned = true, info = { fan_type = "1811-5-54" },
					entries = { { instance = "MF_Fan_005301", address = address, mac = "00005e005301", own = true },
						{ instance = "MF_Fan_005302", address = address, mac = "00005e005302" } } })
				add("Found Fans summary " .. list_state, summary)
				for _, item in ipairs(items) do
					add("Found Fans", item)
				end
			end
			KNOWN["1811-5-54"] = nil
			return out
		end

		it("every text stays under 72 characters with the contract's own inputs", function()
			for _, entry in ipairs(every_text(ADDR, ID2, SOON)) do
				assert.is_true(#entry[2] < 72, entry[1] .. " (" .. #entry[2] .. "): " .. entry[2])
			end
		end)

		it("and no longer than Composer shows (75) with a 15-character address, a date and a WAC_ id", function()
			for _, entry in ipairs(every_text("255.255.255.255", "WAC_00005E005302", LATER)) do
				assert.is_true(#entry[2] <= 75, entry[1] .. " (" .. #entry[2] .. "): " .. entry[2])
			end
		end)

		it("S9 is the longest and reaches 75: section 7.1 says under 75, which is one short", function()
			local text = texts.status({ phase = "offline", failure = "data", address = "255.255.255.255", since = T,
				now = LATER, known = true })
			assert.equal("No usable answer from 255.255.255.255 since 10-27 14:02; showing last state", text)
			assert.equal(75, #text)
		end)

		it("the S3 echo is cut so the whole line stays short", function()
			local text = texts.status({ phase = "unset", typed = string.rep("x", 100) })
			assert.equal('Fan Address "' .. string.rep("x", 24) .. '" is not an IPv4 address', text)
			assert.equal(61, #text)
		end)
	end)

	-- #214: text a fan sends, and the names a Last Action line holds, reach a row
	-- only through texts.clean: no control character, valid UTF-8, a bounded length.
	describe("fan-supplied text (#214, texts.clean)", function()
		local ELLIPSIS = "\226\128\166"

		-- The characters of a valid UTF-8 text (RFC 3629); raises on anything else.
		local function chars(text)
			local n, i = 0, 1
			while i <= #text do
				local b = text:byte(i)
				local len = (b < 128 and 1) or (b >= 194 and b <= 223 and 2) or (b >= 224 and b <= 239 and 3)
					or (b >= 240 and b <= 244 and 4) or nil
				assert(len, "not UTF-8 at byte " .. i .. ": " .. text)
				for j = i + 1, i + len - 1 do
					local c = text:byte(j)
					assert(c and c >= 128 and c <= 191, "a broken UTF-8 sequence at byte " .. i .. ": " .. text)
				end
				n, i = n + 1, i + len
			end
			return n
		end

		-- A text a row may carry: valid UTF-8, no control character, at most `max` characters.
		local function safe(text, max, where)
			assert.is_string(text, where)
			assert.is_nil(text:find("%c"), where .. " has a control character")
			assert.is_true(chars(text) <= max, where .. " is longer than " .. max .. ": " .. text)
		end

		-- A fan's answer at its worst (the lab answer of S1-4): control characters, NUL, an
		-- escape sequence, XML metacharacters, a broken byte, and far too long.
		local HOSTILE = string.rep("\r\n\0\1\27[1m<b>&amp;</b>\255", 400)

		describe("clean", function()
			it("turns every control character into a space: C0 with NUL, DEL, C1, the separators, bidi", function()
				assert.equal("a b c d", texts.clean("a\0b\tc\nd"))
				assert.equal("      x", texts.clean("\1\13\27\31\127\r" .. "x"))
				assert.equal("a b c", texts.clean("a\194\128b\194\159c"), "U+0080 and U+009F")
				assert.equal("a b c", texts.clean("a\226\128\168b\226\128\169c"), "U+2028 and U+2029")
				assert.equal("a b c d", texts.clean("a\226\128\174b\226\128\170c\226\129\167d"), "U+202E, U+202A, U+2067")
			end)

			it("keeps printable ASCII as it is, < & > and quotes included", function()
				local text = [[<b>&amp;</b> "quoted" 'single' ~!@#$%^*()_+-={}[]|\:;,./?]]
				assert.equal(text, texts.clean(text))
			end)

			it("keeps valid UTF-8 of every length", function()
				local text = "Caf\195\169 \226\130\172 \240\159\140\128 \244\143\191\191 \239\191\189"
				assert.equal(text, texts.clean(text))
				assert.equal(12, chars(texts.clean(text)))
			end)

			it("replaces each byte that is no valid UTF-8 with ?", function()
				assert.equal("a?b", texts.clean("a\255b"), "a byte no character starts with")
				assert.equal("a?b", texts.clean("a\128b"), "a continuation byte alone")
				assert.equal("a?b", texts.clean("a\195b"), "a lead byte cut short")
				assert.equal("??", texts.clean("\226\130"), "a three-byte character cut short")
				assert.equal("??", texts.clean("\192\128"), "an overlong NUL")
				assert.equal("???", texts.clean("\224\128\128"), "an overlong form")
				assert.equal("???", texts.clean("\237\160\128"), "a surrogate")
				assert.equal("????", texts.clean("\244\144\128\128"), "past U+10FFFF")
				assert.equal("?", texts.clean("\245"), "a lead byte UTF-8 no longer has")
				assert.equal("a?b?", texts.clean("a\239\191\190b\239\191\191"), "U+FFFE and U+FFFF, which XML 1.0 forbids")
			end)

			it("cuts past max characters, the last one kept being U+2026, never inside a character", function()
				assert.equal(string.rep("x", 9) .. ELLIPSIS, texts.clean(string.rep("x", 100), 10))
				assert.equal(10, chars(texts.clean(string.rep("x", 100), 10)))
				assert.equal(string.rep("x", 10), texts.clean(string.rep("x", 10), 10), "exactly max: not cut")
				assert.equal(string.rep("\195\169", 4) .. ELLIPSIS, texts.clean(string.rep("\195\169", 20), 5))
				assert.equal("ab" .. ELLIPSIS, texts.clean("ab\240\159\140\128cd", 3))
				assert.equal("a  " .. ELLIPSIS, texts.clean("a\0\0\0\0", 4))
				assert.equal(ELLIPSIS, texts.clean("ab", 1))
				assert.equal("", texts.clean("abc", 0))
				assert.equal("", texts.clean("abc", -5))
			end)

			it("cuts at TEXT_MAX (64) when no max is given; ROW_CUT is 75", function()
				assert.equal(64, texts.TEXT_MAX)
				assert.equal(75, texts.ROW_CUT)
				local text = texts.clean(string.rep("y", 200))
				assert.equal(64, chars(text))
				assert.equal(string.rep("y", 63) .. ELLIPSIS, text)
				assert.equal(64, chars(texts.clean(string.rep("y", 200), 0 / 0)), "a max that is no number")
				assert.equal(200, #texts.clean(string.rep("y", 200), math.huge), "no cut")
			end)

			it("gives a whole number's digits, and an empty text for anything else that is not a string", function()
				assert.equal("12345", texts.clean(12345))
				for _, odd in ipairs({ nil, false, true, 1.5, 0 / 0, math.huge, {}, print }) do
					assert.equal("", texts.clean(odd), tostring(odd))
				end
			end)

			it("leaves blanks for the caller to trim", function()
				assert.equal("  x  ", texts.clean("  x  "))
			end)

			-- What is stored cleaned and read back cleans to the same text, so a stored value and a fresh
			-- answer compare equal once both are cleaned with the same max.
			it("is idempotent: a cleaned text cleans to itself", function()
				for _, text in ipairs({ HOSTILE, string.rep("x", 100), "Caf\195\169\255\0", "MF_00005E005301", "" }) do
					for _, max in ipairs({ 1, 10, 64, 75 }) do
						local once = texts.clean(text, max)
						assert.equal(once, texts.clean(once, max), max .. ": " .. once)
					end
				end
			end)

			it("turns the lab's answer into a row Composer and the store can carry", function()
				local text = texts.clean(HOSTILE, texts.ROW_CUT)
				safe(text, 75, "clean")
				assert.equal(75, chars(text))
				assert.truthy(text:find("<b>&amp;</b>", 1, true), "XML metacharacters stay: Director takes plain text")
			end)

			it("is linear: 1 MB of control characters and broken bytes takes well under 50 ms", function()
				local big = string.rep("\0\255 \1", 256 * 1024)
				local started = os.clock()
				for _ = 1, 10 do
					safe(texts.clean(big, texts.ROW_CUT), 75, "big")
					safe(texts.clean(big), 64, "big default")
				end
				assert.is_true(os.clock() - started < 0.05, "took " .. (os.clock() - started) .. " s for 20 calls")
			end)
		end)

		describe("each rendered fan text is cleaned and capped", function()
			it("Fan ID: the client id at most 64 characters, the row at most 75", function()
				local text = texts.fan_id({ client_id = HOSTILE, mac = MAC1 })
				safe(text, 75, "Fan ID")
				assert.truthy(text:find(ELLIPSIS, 1, true))
				safe(texts.fan_id({ client_id = HOSTILE }), 64, "Fan ID without a MAC")
				assert.equal("MF_00005E005301 (MAC 00:00:5e:00:53:01)",
					texts.fan_id({ client_id = "MF_00005E005301\r\n", mac = MAC1 }), "a control character at the end is a blank")
			end)

			it("Fan Model: the fan type and the light kit at most 64 characters each, the row at most 75", function()
				safe(texts.fan_model({ generation = "3" }, { fan_type = HOSTILE, light_type = HOSTILE, has_light = true }, true),
					75, "Fan Model")
				local text = texts.fan_model({ generation = "3" }, { fan_type = "1811\0-5-54", light_type = "F4\nIN" })
				assert.equal("Gen 3, fan 1811 -5-54, light kit F4 IN", text)
				-- 64 characters of the type (63 and the marker), then the row cut at 75.
				local cut = texts.fan_model({ generation = "3" }, { fan_type = string.rep("t", 100) })
				assert.equal("Gen 3, fan " .. string.rep("t", 63) .. ELLIPSIS, cut)
				assert.equal(75, chars(cut))
			end)

			it("Fan Model: a name the table gives is cleaned too", function()
				KNOWN["1811-5-54"] = "Aviator\0 5"
				assert.equal("Gen 3, Aviator  5 (1811-5-54), no light kit",
					texts.fan_model({ generation = "3" }, { fan_type = "1811-5-54" }))
			end)

			it("Firmware: each version at most 64 characters, the row at most 75", function()
				safe(texts.firmware({ firmware = HOSTILE, mcu_firmware = HOSTILE, firmware_since = HOSTILE,
					firmware_was = HOSTILE }), 75, "Firmware")
				assert.equal("02.00.0052 (motor 03.00 0000) since 2026-10-27", texts.firmware({ firmware = "02.00.0052\0",
					mcu_firmware = "03.00\0270000", firmware_since = "2026-10-27" }))
				local text = texts.firmware({ firmware = string.rep("9", 100) })
				assert.equal(string.rep("9", 63) .. ELLIPSIS, text)
			end)

			it("Last Action: client ids, addresses and item names at most 64 characters, every line at most 75", function()
				local fields = { client_id = HOSTILE, was = HOSTILE, address = HOSTILE, generation = "3",
					fan = HOSTILE, light = HOSTILE, fan_type = HOSTILE, instance = HOSTILE, name = HOSTILE,
					strength = HOSTILE, why = HOSTILE, at = T, now = SOON, which = "away" }
				for _, key in ipairs(texts.RESULT_KEYS) do
					safe(texts.result(key, fields), 75, key)
					safe(texts.result(key, { pin = { client_id = HOSTILE, address = HOSTILE } }), 75, key .. " from a pin")
				end
				assert.equal("Learned fan " .. string.rep("Z", 62) .. ELLIPSIS,
					texts.result("learned", { client_id = string.rep("Z", 64) .. "!", address = ADDR, generation = "3" }),
					"64 of the id, then the line cut at 75")
				assert.equal("Learned fan " .. string.rep("Z", 20) .. " (Gen 3) at " .. ADDR,
					texts.result("learned", { client_id = string.rep("Z", 20), address = ADDR, generation = "3" }))
				assert.equal("Items named Sample 1 and Sample Light", texts.result("name_renamed",
					{ fan = "Sample\n1", light = "Sample Light\0" }))
				assert.equal("Same fan MF_00005E005301, now at 10.0.2.151", texts.result("moved",
					{ client_id = "\1MF_00005E005301", address = ADDR .. "\n" }))
			end)

			it("Status: an address at most 64 characters, the row at most 75", function()
				for _, phase in ipairs(texts.PHASES) do
					safe(texts.status({ phase = phase, address = HOSTILE, since = T, now = LATER, st = state(), other = HOSTILE }),
						75, phase)
				end
				assert.equal("Waiting for the fan at 10.0.2.151", texts.status({ phase = "waiting", address = " 10.0.2.151\r" }))
			end)

			it("Found Fans: every row at most 75 characters, with no control character and no comma", function()
				KNOWN["1811-5-54"] = "Aviator 5"
				local summary, items = texts.found_rows({ state = "listed", pinned = true, info = { fan_type = HOSTILE },
					entries = { { instance = HOSTILE, address = HOSTILE, mac = "00005e005301", own = true },
						{ instance = "MF_Fan_005302", address = HOSTILE .. ",x", mac = HOSTILE } } })
				safe(summary, 75, "summary")
				assert.equal(2, #items)
				for i, item in ipairs(items) do
					safe(item, 75, "item " .. i)
					assert.is_nil(item:find(",", 1, true), "item " .. i .. " has a comma")
				end
			end)
		end)
	end)

	describe("never raising", function()
		local WEIRD = { false, true, 0, -1, 1e308, 0 / 0, math.huge, -math.huge, "", " ", "x", "10.0.2.151", {}, { "a" },
			{ x = 1 }, print }

		-- A returned string shows no Lua value as text.
		local function plain(out, where)
			assert.is_string(out, where)
			for _, leak in ipairs({ "nil", "table:", "function:", "true", "false", "1e+" }) do
				assert.is_nil(out:find(leak, 1, true), where .. " -> " .. out)
			end
		end

		local function items_plain(list, where)
			assert.is_table(list, where)
			for _, item in ipairs(list) do
				plain(item, where)
				assert.is_nil(item:find(",", 1, true), where .. " has a comma: " .. item)
				assert.is_nil(item:find("%c"), where .. " has a control character")
			end
		end

		-- Every function that takes plain positional arguments, with every pair of odd values.
		local positional = {
			suffix = 1, mac = 1, clock = 2, fan_id = 1, fan_model = 3, firmware = 1, last_seen = 2, change_by = 3,
			automations = 2, list_item = 1, os_is_old = 1, parse_fan_id = 1, result = 2, rename_suffix = 1, clean = 2,
		}
		for name, arity in pairs(positional) do
			it(name .. " takes any value in any place", function()
				local fn = texts[name]
				local function try(...)
					local ok, out = pcall(fn, ...)
					assert(ok, name .. " raised: " .. tostring(out))
					if type(out) == "string" then
						plain(out, name)
					end
				end
				try()
				for _, a in ipairs(WEIRD) do
					try(a)
					if arity >= 2 then
						try(nil, a)
						for _, b in ipairs(WEIRD) do
							try(a, b)
						end
					end
					if arity >= 3 then
						try(nil, nil, a)
						try("ble", T, a)
						try({ generation = "3" }, { fan_type = "x", light_type = "y" }, a)
					end
				end
			end)
		end

		it("status takes any value for the view and for each of its fields, in every phase", function()
			local fields = { "phase", "address", "typed", "since", "sent", "now", "failure", "known", "other", "st",
				"has_light", "missing", "os", "failing" }
			local phases = { "bogus", "invalid" }
			for _, phase in ipairs(texts.PHASES) do
				phases[#phases + 1] = phase
			end
			for _, a in ipairs(WEIRD) do
				plain(texts.status(a), "status view")
			end
			for _, phase in ipairs(phases) do
				for _, field in ipairs(fields) do
					for _, a in ipairs(WEIRD) do
						local view = { phase = phase, address = ADDR, since = T, now = SOON, st = state() }
						view[field] = a
						local ok, out = pcall(texts.status, view)
						assert(ok, "status raised: " .. tostring(out))
						plain(out, phase .. "/" .. field)
					end
				end
				for _, field in ipairs({ "fan_on", "speed", "direction", "wind", "wind_speed", "light_on", "level" }) do
					for _, a in ipairs(WEIRD) do
						local st = state()
						st[field] = a
						plain(texts.status({ phase = phase, address = ADDR, st = st, has_light = true }), phase .. "/st." .. field)
					end
				end
			end
		end)

		it("result takes any value for each field of its args, for every key", function()
			local fields = { "client_id", "generation", "address", "was", "instance", "at", "now", "which",
				"pin", "fan", "light", "fan_type", "strength", "why", "name" }
			for _, key in ipairs(texts.RESULT_KEYS) do
				for _, field in ipairs(fields) do
					for _, a in ipairs(WEIRD) do
						local args = { client_id = ID1, address = ADDR, instance = "MF_Fan_005302", at = T, now = SOON,
							which = "away" }
						args[field] = a
						local ok, out = pcall(texts.result, key, args)
						assert(ok, "result raised: " .. tostring(out))
						plain(out, key .. "/" .. field)
					end
				end
			end
		end)

		it("automations takes any value for each field of the state", function()
			local fields = { "schedule_set", "away", "learning", "fan_timer", "light_timer", "fan_sleep_timer",
				"light_sleep_timer", "generation" }
			for _, field in ipairs(fields) do
				for _, a in ipairs(WEIRD) do
					local st = {}
					st[field] = a
					for _, generation in ipairs({ "3", "1/2", false }) do
						local ok, out = pcall(texts.automations, st, generation or nil)
						assert(ok, "automations raised: " .. tostring(out))
						plain(out, "automations/" .. field)
					end
				end
			end
		end)

		it("firmware, fan_model and fan_id take any value for each field", function()
			for _, field in ipairs({ "firmware", "mcu_firmware", "firmware_since", "firmware_was", "fan_type", "light_type",
				"has_light", "has_wind", "client_id", "mac", "generation" }) do
				for _, a in ipairs(WEIRD) do
					local info = { firmware = "02.00.0052", fan_type = "1811-5-54", light_type = "F4IN", client_id = ID1,
						mac = MAC1, generation = "3" }
					info[field] = a
					plain(texts.firmware(info), "firmware/" .. field)
					plain(texts.fan_model(info, info), "fan_model/" .. field)
					plain(texts.fan_id(info), "fan_id/" .. field)
				end
			end
		end)

		it("fan_model takes any value for the type, the pin and the info while the table knows the type", function()
			KNOWN["1811-5-54"] = "Aviator 5"
			for _, a in ipairs(WEIRD) do
				plain(texts.fan_model({ generation = "3" }, { fan_type = a }), "fan_model type")
				plain(texts.fan_model({ generation = "3" }, { fan_type = "1811-5-54", light_type = a, has_light = a }, a),
					"fan_model kit")
				plain(texts.fan_model(a, { fan_type = "1811-5-54" }), "fan_model pin")
				plain(texts.fan_model({ generation = a }, { fan_type = "1811-5-54" }), "fan_model generation")
			end
		end)

		it("fan_model takes any answer from the name table: it shows a name only when the answer is text", function()
			for _, a in ipairs(WEIRD) do
				fake_names.lookup = function()
					return a
				end
				local ok, out = pcall(texts.fan_model, { generation = "3" }, { fan_type = "1811-5-54" })
				assert(ok, "fan_model raised: " .. tostring(out))
				plain(out, "fan_model name")
			end
		end)

		it("keypad_links takes any rows, any fields, any total", function()
			for _, a in ipairs(WEIRD) do
				items_plain(texts.keypad_links(a), "keypad_links rows")
				items_plain(texts.keypad_links({ a }), "keypad_links row")
				items_plain(texts.keypad_links({}, a), "keypad_links total")
				for _, field in ipairs({ "link_name", "keypad_name", "device_id" }) do
					local row = { link_name = "Fan Off", keypad_name = "K", device_id = 1 }
					row[field] = a
					items_plain(texts.keypad_links({ row }), "keypad_links " .. field)
				end
			end
		end)

		-- found_rows: a string summary and a table of plain items, whatever it gets.
		local function rows_plain(view, where)
			local ok, summary, items = pcall(texts.found_rows, view)
			assert(ok, "found_rows raised: " .. tostring(summary))
			plain(summary, where)
			assert.is_true(#summary > 0, where)
			items_plain(items, where)
		end

		it("found_rows takes any view, any field of it, any entry and any field of an entry", function()
			local function entry()
				return { key = "00005e005301", instance = "MF_Fan_005301", address = ADDR, mac = "00005e005301", own = true }
			end
			KNOWN["1811-5-54"] = "Aviator 5"
			for _, a in ipairs(WEIRD) do
				rows_plain(a, "found_rows view")
				rows_plain({ state = "listed", entries = { a } }, "found_rows entry")
				rows_plain({ state = "listed", entries = { entry(), a, entry() } }, "found_rows entry among others")
				for _, field in ipairs({ "state", "pinned", "entries", "info" }) do
					local view = { state = "listed", pinned = true, entries = { entry() }, info = { fan_type = "1811-5-54" } }
					view[field] = a
					rows_plain(view, "found_rows " .. field)
				end
				for _, field in ipairs({ "key", "instance", "address", "mac", "own" }) do
					local e = entry()
					e[field] = a
					rows_plain({ state = "listed", pinned = true, entries = { e }, info = { fan_type = "1811-5-54" } },
						"found_rows entry " .. field)
				end
				rows_plain({ state = "listed", pinned = true, entries = { entry() }, info = { fan_type = a } }, "found_rows type")
			end
		end)

		it("found_rows takes any answer from the name table: it shows a name only when the answer is text", function()
			for _, a in ipairs(WEIRD) do
				fake_names.lookup = function()
					return a
				end
				rows_plain({ state = "listed", pinned = true, info = { fan_type = "1811-5-54" },
					entries = { { instance = "MF_Fan_005301", address = ADDR, mac = "00005e005301", own = true } } },
					"found_rows name")
			end
		end)
	end)
end)
