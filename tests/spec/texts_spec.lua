-- fan.texts: every owner-visible string of the driver, verbatim from the v1
-- contract's section 7 (docs/v1-design.md) and, for the fan's name and the
-- rename job's answers, from docs/fan-name-design.md 2.3. The module is pure,
-- so nothing here needs the fake runtime. Times are built from local-time
-- fields, so the specs hold in any time zone.
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
				"automations", "keypad_links", "found_fans", "suffix", "mac", "clock", "rename_suffix" }) do
				assert.is_function(texts[name], name)
			end
		end)

		it("lists the 21 result keys of section 9.6 and the 8 of fan-name-design 2.3, each with a text of its own", function()
			assert.equal(29, #texts.RESULT_KEYS)
			assert.same({ "name_renamed", "name_same", "name_unknown", "name_no_type", "name_no_ids", "name_unconfirmed",
				"name_no_pin", "name_busy" }, { unpack(texts.RESULT_KEYS, 22) })
			local seen = {}
			for _, key in ipairs(texts.RESULT_KEYS) do
				local text = texts.result(key, { client_id = ID1, address = ADDR, count = 2, which = "away", at = T,
					fan = "Sample", light = "Sample Light", fan_type = "1811-5-54" })
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
		describe("S1 to S3: no usable address", function()
			it("S1 not set up, in a build without Find Fans", function()
				assert.equal("Not set up: enter the fan's address in Fan Address", texts.status({ phase = "unset" }))
			end)

			it("S2 not set up, with Find Fans", function()
				assert.equal("Not set up: Find Fans, or enter the fan's address in Fan Address",
					texts.status({ phase = "unset", find_fans = true }))
				assert.equal("Not set up: enter the fan's address in Fan Address",
					texts.status({ phase = "unset", find_fans = false }), "a build without Find Fans says so with false")
			end)

			it("S3 names what was typed", function()
				assert.equal('Fan Address "fan.local" is not an IPv4 address',
					texts.status({ phase = "unset", typed = "fan.local" }))
				assert.equal('Fan Address "10.0.2" is not an IPv4 address',
					texts.status({ phase = "unset", typed = "10.0.2", find_fans = true }), "S3 over S2")
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
				assert.equal("Not set up: enter the fan's address in Fan Address",
					texts.status({ phase = "unset", typed = "   " }))
				assert.equal("Not set up: Find Fans, or enter the fan's address in Fan Address",
					texts.status({ phase = "unset", typed = "", find_fans = true }))
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

			it("reverse and Breeze follow the speed", function()
				local v = online({ st = state({ speed = 6, direction = "reverse", wind = true, level = 100 }) })
				assert.equal("Online: fan speed 6 reverse Breeze, light 100 %", texts.status(v))
				assert.equal("Online: fan speed 2 reverse, light 40 %",
					texts.status(online({ st = state({ speed = 2, direction = "reverse" }) })))
				assert.equal("Online: fan speed 1 Breeze, light 40 %",
					texts.status(online({ st = state({ speed = 1, wind = true }) })))
			end)

			it("reverse and Breeze follow off as well (the grammar has no exception)", function()
				local v = online({ st = state({ fan_on = false, direction = "reverse", wind = true }) })
				assert.equal("Online: fan off reverse Breeze, light 40 %", texts.status(v))
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
					missing = "fanSpeed", os = "3.2.1", find_fans = true,
				}
			end

			it("an unusable address outranks everything: S3", function()
				assert.equal('Fan Address "fan.local" is not an IPv4 address', texts.status(everything("unset")))
			end)

			it("S1 and S2 outrank the old controller", function()
				local v = everything("unset")
				v.typed = nil
				assert.equal("Not set up: Find Fans, or enter the fan's address in Fan Address", texts.status(v))
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

		it("L7 nothing to use, without and with Find Fans", function()
			assert.equal("Nothing to use: enter the fan's address in Fan Address", r("nothing_to_use", {}))
			assert.equal("Nothing to use: enter the fan's address in Fan Address", r("nothing_to_use"))
			assert.equal("Nothing to use: pick a fan in Found Fans, or enter Fan Address",
				r("nothing_to_use", { find_fans = true }))
		end)

		it("L8 found some: plural", function()
			assert.equal("Found 2 fans: pick one in Found Fans, then Use Selected Fan", r("found", { count = 2 }))
			assert.equal("Found 16 fans: pick one in Found Fans, then Use Selected Fan", r("found", { count = 16 }))
		end)

		it("L8 found one: singular", function()
			assert.equal("Found 1 fan: pick it in Found Fans, then Use Selected Fan", r("found", { count = 1 }))
		end)

		it("L8 counts a list it is handed, and says L9 for none", function()
			assert.equal("Found 3 fans: pick one in Found Fans, then Use Selected Fan", r("found", { list = { {}, {}, {} } }))
			assert.equal("Found 1 fan: pick it in Found Fans, then Use Selected Fan", r("found", { list = { {} } }))
			assert.equal("No Modern Forms fan answered on this network", r("found", { count = 0 }))
			assert.equal("No Modern Forms fan answered on this network", r("found", {}))
		end)

		it("L9 found none", function()
			assert.equal("No Modern Forms fan answered on this network", r("found_none"))
		end)

		it("L10 Find Fans could not send", function()
			assert.equal("Find Fans could not send its query on this controller", r("find_failed"))
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

		it("L21 the picked fan is not at its address any more", function()
			assert.equal("The fan at 10.0.2.151 is not the one picked; Find Fans again", r("not_picked", { address = ADDR }))
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

		it("a missing value is ?, never an error or the word nil", function()
			assert.equal("Learned fan ? (Gen ?) at ?", r("learned", {}))
			assert.equal("Same fan ?, now at ?", r("moved", nil))
			assert.equal("Now using fan ? at ?", r("now_using", {}))
			assert.equal("No fan answers at ?; nothing changed", r("no_answer", {}))
			assert.equal("The fan at ? is not the one picked; Find Fans again", r("not_picked", {}))
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

		it("same, busy, no_pin and anything else add nothing", function()
			for _, outcome in ipairs({ "same", "busy", "no_pin", "", " ", "Renamed", "renamed ", "name_renamed", "forced",
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
				assert.same({ "1 of 12 links bound", "Fan Speed 3: Example Keypad (456)" },
					texts.keypad_links({ row("Fan Speed 3 Button Link", "Example Keypad", 456) }))
			end)

			it("the count is of links, not keypads: two keypads on one link are one", function()
				local items = texts.keypad_links({
					row("Fan Speed 2 Button Link", "Example Keypad", 456),
					row("Fan Speed 2 Button Link", "Second Keypad", 457),
					row("Fan Off Button Link", "Example Keypad", 456),
				})
				assert.same({ "2 of 12 links bound", "Fan Speed 2: Example Keypad (456)",
					"Fan Speed 2: Second Keypad (457)", "Fan Off: Example Keypad (456)" }, items)
			end)

			it("none bound", function()
				assert.same({ "0 of 12 links bound" }, texts.keypad_links({}))
				assert.same({ "0 of 12 links bound" }, texts.keypad_links(nil))
			end)

			it("takes the link name with or without Button Link, and rows as arrays", function()
				assert.same({ "2 of 12 links bound", "Light Top: Example Keypad (456)", "Fan Cycle: Example Keypad (456)" },
					texts.keypad_links({ { "Light Top Button Link", "Example Keypad", 456 },
						row("Fan Cycle", "Example Keypad", "456") }))
			end)

			it("a keypad that has no name shows as its device", function()
				assert.same({ "1 of 12 links bound", "Fan Toggle: device 456" },
					texts.keypad_links({ row("Fan Toggle Button Link", nil, 456) }))
				assert.same({ "1 of 12 links bound", "Fan Toggle: device 456" },
					texts.keypad_links({ row("Fan Toggle Button Link", "  ", 456) }))
				assert.same({ "1 of 12 links bound", "Fan Toggle: Example Keypad (?)" },
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

			it("counts against the number of links it is given, 12 by default", function()
				assert.equal(12, texts.LINK_COUNT)
				assert.equal("1 of 14 links bound", texts.keypad_links({ row("Fan Off", "K", 1) }, 14)[1])
				assert.equal("1 of 12 links bound", texts.keypad_links({ row("Fan Off", "K", 1) }, "many")[1])
				assert.equal("1 of 12 links bound", texts.keypad_links({ row("Fan Off", "K", 1) }, 1e308)[1])
			end)

			it("passes rows that are not tables over", function()
				assert.same({ "1 of 12 links bound", "Fan Off: K (1)" },
					texts.keypad_links({ "x", 5, row("Fan Off", "K", 1) }))
			end)
		end)

		describe("Found Fans", function()
			local fan1 = { instance = "MF_Fan_005301", address = ADDR, port = 80, mac = MAC1, firmware = "02.00.0052" }
			local fan2 = { instance = "MF_Fan_005302", address = ADDR2, port = 80, mac = "00005E005302" }

			it("one item per fan: the instance and the address", function()
				assert.same({ "MF_Fan_005301 at 10.0.2.151", "MF_Fan_005302 at 10.0.2.152" }, texts.found_fans({ fan1, fan2 }))
			end)

			it("marks this device's fan by its MAC", function()
				assert.same({ "MF_Fan_005301 at 10.0.2.151 (this device's fan)", "MF_Fan_005302 at 10.0.2.152" },
					texts.found_fans({ fan1, fan2 }, { client_id = ID1, mac = MAC1, generation = "3" }))
			end)

			it("marks it whatever the spelling of the MACs", function()
				local colon = { instance = "MF_Fan_005301", address = ADDR, mac = "00:00:5e:00:53:01" }
				assert.same({ "MF_Fan_005301 at 10.0.2.151 (this device's fan)" }, texts.found_fans({ colon }, { mac = MAC1 }))
				assert.same({ "MF_Fan_005301 at 10.0.2.151 (this device's fan)" }, texts.found_fans({ fan1 }, { client_id = ID1 }))
				assert.same({ "MF_Fan_005301 at 10.0.2.151 (this device's fan)" },
					texts.found_fans({ fan1 }, { mac = "00:00:5E:00:53:01" }))
			end)

			it("marks nothing when no fan is pinned or the pin has no MAC", function()
				assert.same({ "MF_Fan_005301 at 10.0.2.151" }, texts.found_fans({ fan1 }, nil))
				assert.same({ "MF_Fan_005301 at 10.0.2.151" }, texts.found_fans({ fan1 }, {}))
				assert.same({ "MF_Fan_005301 at 10.0.2.151" }, texts.found_fans({ fan1 }, { mac = "0000" }))
			end)

			it("a fan that answered without a MAC is never this device's", function()
				local no_mac = { instance = "MF_Fan_005301", address = ADDR }
				assert.same({ "MF_Fan_005301 at 10.0.2.151" }, texts.found_fans({ no_mac }, { mac = MAC1 }))
			end)

			it("at most 16 fans", function()
				local list = {}
				for i = 1, 20 do
					list[i] = { instance = "MF_Fan_" .. i, address = "192.0.2." .. i, mac = "00005E00" .. string.format("%04X", i) }
				end
				local items = texts.found_fans(list)
				assert.equal(16, #items)
				assert.equal(16, texts.MAX_FOUND)
				assert.equal("MF_Fan_1 at 192.0.2.1", items[1])
				assert.equal("MF_Fan_16 at 192.0.2.16", items[16])
			end)

			it("commas become U+201A and control characters go", function()
				local items = texts.found_fans({ { instance = "Hall, fan\n", address = ADDR } })
				assert.equal("Hall\226\128\154 fan at 10.0.2.151", items[1])
			end)

			it("leaves out what the answer lacked", function()
				assert.same({ "fan at 10.0.2.151", "MF_Fan_005301" },
					texts.found_fans({ { address = ADDR }, { instance = "MF_Fan_005301" } }))
			end)

			it("nothing found, or nothing usable, is an empty list", function()
				assert.same({}, texts.found_fans({}))
				assert.same({}, texts.found_fans(nil))
				assert.same({}, texts.found_fans({ "x", 5 }))
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
			assert_clean(table.concat(texts.found_fans({ with({ instance = "MF_Fan_005301", address = ADDR }) }), "|"))
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
				S1 = { phase = "unset" }, S2 = { phase = "unset", find_fans = true },
				S3 = { phase = "unset", typed = string.rep("x", 40) }, S4 = { phase = "waiting", address = address },
				S5 = online({ address = address, st = state({ speed = 6, direction = "reverse", wind = true, level = 100 }) }),
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
					-- L22 to L24 with the longest name of the research table and a type that gets cut.
					add("L " .. key .. " " .. which, texts.result(key, { client_id = client, was = client, address = address,
						generation = "1/2", count = 16, find_fans = true, at = T, now = now, which = which,
						fan = "Size Matters 65", light = "Size Matters 65 Light", fan_type = string.rep("x", 20) }))
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
			for _, item in ipairs(texts.found_fans({ { instance = "MF_Fan_005301", address = address, mac = "00005E005301" } },
				{ mac = "00005E005301" })) do
				add("Found Fans", item)
			end
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
			automations = 2, list_item = 1, os_is_old = 1, parse_fan_id = 1, result = 2, rename_suffix = 1,
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
				"has_light", "missing", "os", "find_fans" }
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
				for _, field in ipairs({ "fan_on", "speed", "direction", "wind", "light_on", "level" }) do
					for _, a in ipairs(WEIRD) do
						local st = state()
						st[field] = a
						plain(texts.status({ phase = phase, address = ADDR, st = st, has_light = true }), phase .. "/st." .. field)
					end
				end
			end
		end)

		it("result takes any value for each field of its args, for every key", function()
			local fields = { "client_id", "generation", "address", "was", "count", "list", "find_fans", "at", "now", "which",
				"pin", "fan", "light", "fan_type" }
			for _, key in ipairs(texts.RESULT_KEYS) do
				for _, field in ipairs(fields) do
					for _, a in ipairs(WEIRD) do
						local args = { client_id = ID1, address = ADDR, count = 2, at = T, now = SOON, which = "away" }
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

		it("keypad_links and found_fans take any rows, any fields, any pin", function()
			for _, a in ipairs(WEIRD) do
				items_plain(texts.keypad_links(a), "keypad_links rows")
				items_plain(texts.keypad_links({ a }), "keypad_links row")
				items_plain(texts.keypad_links({}, a), "keypad_links total")
				items_plain(texts.found_fans(a), "found_fans list")
				items_plain(texts.found_fans({ a }), "found_fans entry")
				items_plain(texts.found_fans({ { instance = "MF_Fan_005301", address = ADDR, mac = MAC1 } }, a), "found_fans pin")
				for _, field in ipairs({ "link_name", "keypad_name", "device_id" }) do
					local row = { link_name = "Fan Off", keypad_name = "K", device_id = 1 }
					row[field] = a
					items_plain(texts.keypad_links({ row }), "keypad_links " .. field)
				end
				for _, field in ipairs({ "instance", "address", "mac" }) do
					local fan = { instance = "MF_Fan_005301", address = ADDR, mac = MAC1 }
					fan[field] = a
					items_plain(texts.found_fans({ fan }, { mac = MAC1 }), "found_fans " .. field)
				end
			end
		end)
	end)
end)
