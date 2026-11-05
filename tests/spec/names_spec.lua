-- fan.names: the fan's product name from its model code, and the rule a name
-- must meet before the driver writes it into the project (docs/fan-name-design.md
-- sections 2.1 and 4; the table is docs/fan-names-research.md, Appendix B; the
-- rule is docs/edge-cases-rename.md 5.4). The module is pure, so nothing here
-- needs the fake runtime.

local names = require("fan.names")

local MODULE = "src/modernforms_fan/fan/names.lua"
local DRIVER_XML = "src/modernforms_fan/driver.xml"

local function read(path)
	local file = assert(io.open(path))
	local text = file:read("*a")
	file:close()
	return text
end

local function count(t)
	local n = 0
	for _ in pairs(t) do
		n = n + 1
	end
	return n
end

-- `fn()` with names.TABLE[key] set to `value`; the table is put back afterwards
-- whatever `fn` does.
local function with_entry(key, value, fn)
	local before = names.TABLE[key]
	names.TABLE[key] = value
	local ok, err = pcall(fn)
	names.TABLE[key] = before
	assert(ok, err)
end

-- The `name` attributes of the two proxies of driver.xml: the fan's, then the
-- light_v2's (the way fan_driver_spec.lua reads the same file).
local function proxy_names()
	local bare = read(DRIVER_XML):gsub("<!%-%-.-%-%->", "")
	local found = {}
	for attrs, kind in bare:gmatch("<proxy ([^>]-)>(.-)</proxy>") do
		found[kind] = (" " .. attrs):match(' name="([^"]*)"')
	end
	return found.fan, found.light_v2
end

-- Strings the name rule refuses, each with what is wrong with it.
local BAD = {
	{ "empty", "" },
	{ "23 characters", ("W"):rep(23) },
	{ "a comma", "Aviator, 5" },
	{ "an inch sign (a double quote)", 'Aviator 5"' },
	{ "a single quote", "Aviator's 5" },
	{ "angle brackets", "<Aviator 5>" },
	{ "an ampersand", "Aviator & 5" },
	{ "a semicolon", "Aviator;5" },
	{ "a pipe", "Aviator|5" },
	{ "a backslash", "Aviator\\5" },
	{ "a period", "Aviator 5.0" },
	{ "an underscore", "Aviator_5" },
	{ "parentheses", "Aviator (5)" },
	{ "a tab", "Aviator\t5" },
	{ "a newline", "Aviator 5\n" },
	{ "a NUL", "Aviator\0 5" },
	{ "DEL", "Aviator\1275" },
	{ "a non-ASCII letter (U+00E9)", "Z\195\169phyr 52" },
	{ "a low quote (U+201A)", "Aviator\226\128\154 5" },
	{ "a typographic inch sign (U+2033)", "Aviator 5\226\128\179" },
	{ "a leading blank", " Aviator 5" },
	{ "a trailing blank", "Aviator 5 " },
	{ "a double blank", "Aviator  5" },
	{ "a blank alone", " " },
	{ "the light item's suffix", "Wynd Light" },
	{ "the light item's suffix on a name that is a light's", "Aviator 5 Light" },
}

-- Appendix B of docs/fan-names-research.md, entry for entry: the seed the
-- module started from. The module may grow (a later build adds an entry from
-- an owner's report, and the count below follows), but a seeded entry changes
-- only on purpose, here and in the module together.
local SEED = {
	["1801-42"] = "Wynd 42", ["1801-52"] = "Wynd 52", ["1801-60"] = "Wynd 60", ["1802-26"] = "Vox 26",
	["1802-38"] = "Vox 38", ["1803-44"] = "Axis 44", ["1803-52"] = "Axis 52", ["1804-52"] = "Stargazer",
	["1805-80"] = "Hydra 80", ["1805-96"] = "Hydra 96", ["1805-120"] = "Hydra 120", ["1806-56"] = "Cervantes",
	["1807-44"] = "Aloft", ["1809-54"] = "Lotus", ["1810-60"] = "Vortex", ["1811-54"] = "Aviator 54",
	["1811-5-54"] = "Aviator 5", ["1811-70"] = "Aviator 70", ["1812-60"] = "Morpheus II", ["1813-60"] = "Morpheus III",
	["1814-60"] = "Woody 60", ["1814-72"] = "Woody 72", ["1815-60"] = "Windflower 60", ["1815-80"] = "Windflower 80",
	["1816-62"] = "Orb 62", ["1816-82"] = "Orb 82", ["1817-56"] = "Osprey", ["1818-56"] = "Nautilus",
	["1819-52"] = "Mykonos", ["1910-52"] = "Roboto 52", ["1910-62"] = "Roboto 62", ["1916-56"] = "Nirvana",
	["1920-60"] = "Venus", ["1922-56"] = "Paradox", ["2001-52"] = "Renegade 52", ["2001-66"] = "Renegade 66",
	["2003-52"] = "Slim", ["2004-44"] = "Tip Top 44", ["2004-52"] = "Tip Top 52", ["2006-52"] = "Zephyr 52",
	["2006-62"] = "Zephyr 62", ["2006-72"] = "Zephyr 72", ["2008-60"] = "Mykonos 5", ["2101-72"] = "Wynd XL",
	["2102-54"] = "Ultra", ["2103-58"] = "Twirl", ["2201-65"] = "Wyndmill", ["2202-54"] = "Skylark 54",
	["2202-62"] = "Skylark 62", ["2203-44"] = "Corona 44", ["2203-52"] = "Corona 52", ["2204-58"] = "Torque 58",
	["2204-70"] = "Torque 70", ["2301-70"] = "Roboto XL", ["2303-60"] = "Aura 60", ["2303-72"] = "Aura 72",
	["2304-62"] = "Lucid", ["2401-62"] = "Zephyr 5", ["2402-28"] = "Veloce", ["2403-56"] = "Size Matters 56",
	["2403-65"] = "Size Matters 65", ["2403-84"] = "Size Matters 84", ["2404-60"] = "Spinster", ["2501-56"] = "Bolo",
	["2501-62"] = "Bolo 62", ["2502-52"] = "Smooth", ["2503-54"] = "Pisces", ["2504-60"] = "Carve 60",
	["2504-72"] = "Carve 72", ["2601-56"] = "Smooth 5", ["2602-62"] = "Crown", ["2603-56"] = "Radiant 56",
	["2603-64"] = "Radiant 64", ["2605-54"] = "Chill", ["2606-60"] = "Spoke",
}

describe("fan.names", function()
	describe("the interface of section 2.1", function()
		it("offers the table, the defaults, the drop count and the three functions", function()
			assert.is_table(names.TABLE)
			assert.is_table(names.DEFAULTS)
			assert.is_number(names.DROPPED)
			for _, name in ipairs({ "valid", "lookup", "light" }) do
				assert.is_function(names[name], name)
			end
		end)

		it("is pure: it runs with `type` and `pairs` alone, no C4, no print, no require", function()
			local sandbox = setmetatable({ type = type, pairs = pairs }, {
				__index = function(_, global)
					error("the module reached for the global " .. tostring(global), 2)
				end,
			})
			local chunk = assert(loadfile(MODULE))
			setfenv(chunk, sandbox)
			local pure = chunk()
			assert.equal("Aviator 5", pure.lookup("1811-5-54"))
			assert.equal("Aviator 5 Light", pure.light("Aviator 5"))
			assert.is_true(pure.valid("Aviator 5"))
			assert.is_false(pure.valid("Aviator, 5"))
		end)
	end)

	describe("TABLE", function()
		it("holds the 75 entries of the research note's Appendix B and dropped none at load", function()
			assert.equal(75, count(SEED), "the seed above is Appendix B whole")
			assert.equal(75, count(names.TABLE), "a later build that adds an entry changes this number")
			assert.equal(0, names.DROPPED)
		end)

		it("keeps every entry of Appendix B as the note has it", function()
			local wrong = {}
			for key, name in pairs(SEED) do
				if names.TABLE[key] ~= name then
					wrong[#wrong + 1] = key .. ": the table has " .. tostring(names.TABLE[key]) .. ", the note " .. name
				end
			end
			assert.same({}, wrong)
		end)

		it("gives every key a name that passes valid()", function()
			local bad = {}
			for key, name in pairs(names.TABLE) do
				if not names.valid(name) then
					bad[#bad + 1] = key .. " = " .. tostring(name)
				end
			end
			assert.same({}, bad)
		end)

		it("keys every entry in one of the two shapes of the research note's grammar", function()
			local bad = {}
			for key in pairs(names.TABLE) do
				-- family-size, or family-blades-size (a blade-count digit only where the maker has one)
				if not (key:match("^%d%d%d%d%-%d%d?%d?$") or key:match("^%d%d%d%d%-%d%-%d%d?%d?$")) then
					bad[#bad + 1] = key
				end
			end
			assert.same({}, bad)
		end)

		it("writes no key twice in the source, where the later line would silently win", function()
			local code = read(MODULE):gsub("%-%-[^\n]*", "")
			local seen, twice, written = {}, {}, 0
			for key in code:gmatch('%["([^"]+)"%]%s*=') do
				written = written + 1
				if seen[key] then
					twice[#twice + 1] = key
				end
				seen[key] = true
			end
			assert.same({}, twice)
			assert.equal(count(names.TABLE), written)
		end)

		it("gives no two models one name", function()
			local owner, twice = {}, {}
			for key, name in pairs(names.TABLE) do
				if owner[name] then
					twice[#twice + 1] = name .. " (" .. owner[name] .. " and " .. key .. ")"
				end
				owner[name] = key
			end
			assert.same({}, twice)
		end)

		it("names the house fan, 1811-5-54, Aviator 5", function()
			assert.equal("Aviator 5", names.TABLE["1811-5-54"])
			assert.equal("Aviator 5", names.lookup("1811-5-54"))
		end)

		it("keeps the three Aviators apart: the five-blade fan has a key of its own", function()
			assert.equal("Aviator 54", names.lookup("1811-54"))
			assert.equal("Aviator 5", names.lookup("1811-5-54"))
			assert.equal("Aviator 70", names.lookup("1811-70"))
		end)

		it("has the other types seen on real fans and in public fixtures", function()
			for key, name in pairs({
				["2603-56"] = "Radiant 56", -- a Gen 4 owner's report
				["2006-52"] = "Zephyr 52", -- a Gen 3 owner's report
				["1801-60"] = "Wynd 60", -- a Gen 3 owner's report
				["1818-56"] = "Nautilus", -- a public test fixture
				["2003-52"] = "Slim", -- a public test fixture
			}) do
				assert.equal(name, names.lookup(key), key)
			end
		end)

		it("has the names that differ by a digit or a word as entries of their own", function()
			for key, name in pairs({
				["2006-52"] = "Zephyr 52", ["2401-62"] = "Zephyr 5",
				["2502-52"] = "Smooth", ["2601-56"] = "Smooth 5",
				["1819-52"] = "Mykonos", ["2008-60"] = "Mykonos 5",
				["1910-62"] = "Roboto 62", ["2301-70"] = "Roboto XL",
				["1801-60"] = "Wynd 60", ["2101-72"] = "Wynd XL",
				["1812-60"] = "Morpheus II", ["1813-60"] = "Morpheus III",
				["2501-56"] = "Bolo", ["2501-62"] = "Bolo 62",
			}) do
				assert.equal(name, names.lookup(key), key)
			end
		end)

		it("has the families with several sizes and the longest names", function()
			assert.equal("Hydra 120", names.lookup("1805-120"))
			assert.equal("Size Matters 84", names.lookup("2403-84"))
			assert.equal("Windflower 80", names.lookup("1815-80"))
			assert.equal("Veloce", names.lookup("2402-28"))
			assert.equal("Spoke", names.lookup("2606-60"))
		end)
	end)

	describe("fail closed at load", function()
		-- The module's source with the name of the 1801-42 entry replaced by
		-- `literal` (Lua source for the value), run as a chunk of its own.
		local function load_with(literal)
			local patched, replaced = read(MODULE):gsub('(%["1801%-42"%]%s*=%s*)"Wynd 42"', function(head)
				return head .. literal
			end)
			assert.equal(1, replaced, "the 1801-42 entry is where the spec looks for it")
			return assert(loadstring(patched, "=fan/names.lua (patched)"))()
		end

		it("loads every entry when the patch changes nothing", function()
			local loaded = load_with('"Wynd 42"')
			assert.equal(0, loaded.DROPPED)
			assert.equal(count(names.TABLE), count(loaded.TABLE))
			assert.equal("Wynd 42", loaded.lookup("1801-42"))
		end)

		local cases = {}
		for _, case in ipairs(BAD) do
			cases[#cases + 1] = { case[1], ("%q"):format(case[2]) }
		end
		cases[#cases + 1] = { "a number", "42" }
		cases[#cases + 1] = { "false", "false" }
		cases[#cases + 1] = { "a table", "{}" }

		it("drops an entry whose name fails valid(), counts it and knows no name for its type", function()
			for _, case in ipairs(cases) do
				local loaded = load_with(case[2])
				assert.equal(1, loaded.DROPPED, case[1])
				assert.is_nil(loaded.TABLE["1801-42"], case[1])
				assert.is_nil(loaded.lookup("1801-42"), case[1])
				assert.equal(count(names.TABLE) - 1, count(loaded.TABLE), case[1])
				assert.equal("Wynd 52", loaded.lookup("1801-52"), case[1] .. ": the entries next to it stay")
			end
		end)

		it("counts every entry it drops", function()
			local source = read(MODULE)
			local patched, replaced = source:gsub('= "Wynd (%d+)"', '= "Wynd, %1"')
			assert.equal(3, replaced, "the three Wynd entries of family 1801")
			local loaded = assert(loadstring(patched, "=fan/names.lua (patched)"))()
			assert.equal(3, loaded.DROPPED)
			assert.equal(count(names.TABLE) - 3, count(loaded.TABLE))
			assert.is_nil(loaded.lookup("1801-60"))
			assert.equal("Wynd XL", loaded.lookup("2101-72"), "the other Wynd is not touched")
		end)
	end)

	describe("lookup", function()
		it("answers the name for a type the table knows", function()
			assert.equal("Aviator 5", names.lookup("1811-5-54"))
			assert.equal("Radiant 64", names.lookup("2603-64"))
			assert.equal("Hydra 120", names.lookup("1805-120"))
		end)

		it("trims white space around the type, and only there", function()
			assert.equal("Aviator 5", names.lookup(" 1811-5-54 "))
			assert.equal("Aviator 5", names.lookup("\t1811-5-54\r\n"))
			assert.equal("Aviator 5", names.lookup("   1811-5-54"))
			assert.equal("Aviator 5", names.lookup("1811-5-54   "))
			assert.is_nil(names.lookup("1811 -5-54"))
			assert.is_nil(names.lookup("1811-5- 54"))
			assert.is_nil(names.lookup("1811-5-54 1811-5-54"))
		end)

		it("trims a type with long runs of blanks in linear time", function()
			local runs = (" "):rep(100000)
			local started = os.clock()
			assert.equal("Aviator 5", names.lookup(runs .. "1811-5-54" .. runs))
			assert.is_nil(names.lookup("1811" .. runs .. "5-54"))
			assert.is_nil(names.lookup(runs))
			assert.is_true(os.clock() - started < 1, "a trim that is not linear takes minutes on this")
		end)

		it("matches the whole type, exactly: a prefix, an extension, another size or a model code is a miss", function()
			for _, miss in ipairs({
				"1811-5-52", "1811-5-5", "1811-5-540", "1811-5-054", "1811-05-54", "1811-5", "1811", "5-54", "-5-54",
				"18115-54", "1811-5-54L", "1811-5-54 Light", "FR-W1811-5-54", "FH-W1811-5-54", "FR-W1811-5-54L",
				"fr-w1811-5-54", "1811\226\128\147" .. "5\226\128\147" .. "54", -- en dashes
				"2006-40", -- a size the family does not list: no family match (N1)
				"1808-52", "2607-60", "9999-5-120", -- a family nobody found, a newer one, an unknown one
				"F-036L", -- a WAC number: its fans have no known fanType
			}) do
				assert.is_nil(names.lookup(miss), miss)
			end
		end)

		it("does not match the type of the three-blade Aviator for the five-blade one, or the other way round", function()
			assert.not_equal(names.lookup("1811-5-54"), names.lookup("1811-54"))
			assert.is_nil(names.lookup("1811-5-70"))
		end)

		it("answers nil for nil, a value that is not a string, the empty string and blanks alone", function()
			assert.is_nil(names.lookup())
			assert.is_nil(names.lookup(nil))
			for _, value in ipairs({ 1811, 1811.5, true, false, {}, { "1811-5-54" }, print, "", " ", "\t\r\n " }) do
				assert.is_nil(names.lookup(value), tostring(value))
			end
		end)

		it("answers nil for an entry that fails valid() now, one put into the table after load", function()
			for _, case in ipairs(BAD) do
				with_entry("1811-5-54", case[2], function()
					assert.is_nil(names.lookup("1811-5-54"), case[1])
				end)
			end
			with_entry("1811-5-54", 42, function()
				assert.is_nil(names.lookup("1811-5-54"), "a number")
			end)
			with_entry("9999-9", "Bad, Name", function()
				assert.is_nil(names.lookup("9999-9"))
			end)
			assert.equal("Aviator 5", names.lookup("1811-5-54"), "the table is put back")
		end)

		it("answers a name a later build adds, the way the header says to add one", function()
			with_entry("2006-40", "Zephyr 40", function()
				assert.equal("Zephyr 40", names.lookup("2006-40"))
				assert.equal("Zephyr 52", names.lookup("2006-52"))
			end)
			assert.is_nil(names.lookup("2006-40"))
		end)
	end)

	describe("valid", function()
		it("accepts a name of ASCII letters, digits, blanks and hyphens of 1 to 22 characters", function()
			for _, name in ipairs({
				"Aviator 5", "Wynd XL", "Size Matters 84", "A", "7", "2006", "Tip-Top 44", "Modern Forms Fan",
				("A"):rep(22), -- the longest
				"Light Wynd 52", "Wynd Lighting", "Wynd Lights", -- only a final " Light" is refused
			}) do
				assert.is_true(names.valid(name), name)
			end
		end)

		it("returns true or false and nothing else", function()
			assert.is_true(names.valid("Aviator 5") == true)
			assert.is_true(names.valid(nil) == false)
			assert.is_true(names.valid("Aviator, 5") == false)
		end)

		it("refuses what is not a string", function()
			assert.is_false(names.valid())
			for _, value in ipairs({ 5, 5.5, true, false, {}, { "Aviator 5" }, print }) do
				assert.is_false(names.valid(value), tostring(value))
			end
		end)

		it("refuses each string of the BAD list, whatever is wrong with it", function()
			for _, case in ipairs(BAD) do
				assert.is_false(names.valid(case[2]), case[1])
			end
		end)

		it("refuses 23 characters and accepts 22, whatever the characters", function()
			assert.is_true(names.valid(("Ab 1-"):rep(4) .. "Ab")) -- 22 characters
			assert.is_false(names.valid(("Ab 1-"):rep(4) .. "Abc")) -- 23, and nothing else wrong with it
			assert.is_true(names.valid(("9"):rep(22)))
			assert.is_false(names.valid(("9"):rep(23)))
			assert.is_false(names.valid(("9"):rep(5000)))
		end)

		it("refuses only a blank at the ends or twice in a row, not one between words", function()
			assert.is_true(names.valid("A B"))
			assert.is_true(names.valid("A B C D"))
			assert.is_true(names.valid("A - B"))
			assert.is_false(names.valid("A B "))
			assert.is_false(names.valid(" A B"))
			assert.is_false(names.valid("A  B"))
			assert.is_false(names.valid("A B  "))
		end)

		it("refuses a name that ends in ' Light', which is how the light item is named", function()
			assert.is_false(names.valid("Wynd Light"))
			assert.is_false(names.valid("Aviator 5 Light"))
			assert.is_false(names.valid("Modern Forms Fan Light"))
			assert.is_true(names.valid("Wynd Light 5"))
		end)
	end)

	describe("light", function()
		it("adds ' Light' to a name", function()
			assert.equal("Aviator 5 Light", names.light("Aviator 5"))
			assert.equal("Modern Forms Fan Light", names.light("Modern Forms Fan"))
			assert.equal("Size Matters 84 Light", names.light("Size Matters 84"))
		end)

		it("gives every name of the table a light name of at most 28 characters", function()
			local bad = {}
			for key, name in pairs(names.TABLE) do
				local light = names.light(name)
				if light ~= name .. " Light" or #light > 28 then
					bad[#bad + 1] = key
				end
			end
			assert.same({}, bad)
			assert.equal(28, #names.light(("A"):rep(22)))
		end)

		it("answers nil for nil, a value that is not a string, and a name that fails valid()", function()
			assert.is_nil(names.light())
			assert.is_nil(names.light(nil))
			for _, value in ipairs({ 5, true, false, {}, print }) do
				assert.is_nil(names.light(value), tostring(value))
			end
			for _, case in ipairs(BAD) do
				assert.is_nil(names.light(case[2]), case[1])
			end
		end)

		it("does not make a light name of a light name", function()
			assert.is_nil(names.light(names.light("Aviator 5")))
		end)
	end)

	describe("DEFAULTS", function()
		it("is a list of pairs of item names, each a fan name and a light name", function()
			assert.is_table(names.DEFAULTS)
			assert.is_true(#names.DEFAULTS >= 1)
			for index, pair in ipairs(names.DEFAULTS) do
				assert.is_string(pair.fan, "pair " .. index)
				assert.is_string(pair.light, "pair " .. index)
				assert.is_true(pair.fan ~= "" and pair.light ~= "", "pair " .. index)
			end
		end)

		it("starts with the pair the first build shipped: Modern Forms Fan and Modern Forms Fan Light", function()
			assert.same({ fan = "Modern Forms Fan", light = "Modern Forms Fan Light" }, names.DEFAULTS[1])
		end)

		it("holds the pair of item names driver.xml gives the fan and the light_v2 proxy", function()
			local fan, light = proxy_names()
			assert.is_string(fan, "the fan proxy has a name in driver.xml")
			assert.is_string(light, "the light_v2 proxy has a name in driver.xml")
			local found = false
			for _, pair in ipairs(names.DEFAULTS) do
				if pair.fan == fan and pair.light == light then
					found = true
				end
			end
			assert.is_true(found, "DEFAULTS lacks the pair driver.xml ships: " .. fan .. " and " .. light)
		end)

	end)
end)
