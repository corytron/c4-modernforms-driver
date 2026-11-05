-- fan/names.lua: the fan's product name from the model code it reports, and the
-- rule every name meets before the driver writes it into the project
-- (docs/fan-name-design.md section 2.1, decisions N1 and N2). Pure: no
-- Director calls, so the spec can pin every entry.
--
--   names.TABLE             [fan_type] = name, the maker's family name
--   names.DEFAULTS          every pair of item names a build shipped
--   names.DROPPED           how many table entries failed valid() at load
--   names.valid(name)       ECR 5.4: may the driver write this name?
--   names.lookup(fan_type)  trimmed, exact match, else nil
--   names.light(name)       the light item's name for a fan item's name
--
-- Where the table comes from (docs/fan-names-research.md, FNR): the maker's
-- catalogue names, read from its public product pages on 2026-11-04, with the
-- ENERGY STAR open data as a check; FNR's Appendix B is this table. A key is
-- the fanType the fan reports: the four-digit family, a blade-count digit
-- where the maker has one, and the blade span in inches (FNR section 2).
-- Seen on a real fan or in a public test fixture: 1811-5-54 (the house fan),
-- 2603-56, 2006-52, 1801-60, 1818-56 and 2003-52; the other 69 follow from
-- that grammar and are assumed. Generation, mount, light kit and finish are
-- not part of a key.
--
-- Matching is exact (N1): the trimmed fan type must equal a key. Nothing is
-- stripped, shortened or guessed from the family number, the brand, the light
-- kit or the app's device name; a type that is not in the table has no name
-- and nothing is renamed.
--
-- Names are the maker's own, in ASCII, without the brand and without an inch
-- sign; the size is part of a name only where the maker's name has one (N2).
-- An alias stays in a comment, not in the table. An entry that fails valid()
-- is dropped at load (fail closed) and counted in DROPPED; the spec checks
-- that none is.
--
-- Adding an entry in a later build, from an owner's report: an unknown type
-- shows in the Fan Model row ("fan 2006-40") and in the debug log. Find the
-- model on the maker's product page, add ["2006-40"] = "Zephyr 40" under its
-- family (a new family gets a comment line of its own), keep the maker's
-- spelling, and run the spec: it checks the key's shape, the name's rule and
-- that no key or name repeats. The driver reads no website; the table changes
-- only with a build.

local names = {}

-- Every pair of item names a build shipped: the name attributes of the two
-- proxies in driver.xml (the fan's, then the light_v2's). A build that changes
-- them adds its pair and keeps the old ones, so a device made by an older
-- build still counts as untouched (ECR 5.3); the spec holds the current pair
-- against driver.xml.
names.DEFAULTS = {
	{ fan = "Modern Forms Fan", light = "Modern Forms Fan Light" },
}

local MAX_NAME = 19 -- the longest fan item name, so L23 stays within 70 characters (review of #37; ECR 5.4 said 22)
local LIGHT = " Light" -- what the light item's name adds to the fan item's

-- ECR 5.4: ASCII letters, digits, blanks and hyphens only (explicit ranges, so
-- a locale cannot widen the class), 1 to 19 characters, no blank at either end
-- or twice in a row, and not ending in " Light", which is how the light item's
-- name is made. What is not a string is refused, never raised on.
function names.valid(name)
	if type(name) ~= "string" or #name < 1 or #name > MAX_NAME then
		return false
	end
	if name:find("[^A-Za-z0-9 %-]") or name:find("^ ") or name:find(" $") or name:find("  ", 1, true) then
		return false
	end
	return name:sub(-#LIGHT) ~= LIGHT
end

-- The text without white space at either end. Linear however the text is
-- built: a fan's answer is not ours to trust to be short.
local function trim(text)
	local first = text:find("%S")
	if not first then
		return ""
	end
	local last = #text
	while last > first and text:find("^%s", last) do
		last = last - 1
	end
	return text:sub(first, last)
end

-- The name for a fan type: the trimmed type must be a key (N1). nil for a
-- value that is not a string, for "", for a type the table does not know, and
-- for an entry that fails valid() now (the table is a plain table a caller
-- could have changed since load).
function names.lookup(fan_type)
	if type(fan_type) ~= "string" then
		return nil
	end
	local name = names.TABLE[trim(fan_type)]
	if names.valid(name) then
		return name
	end
	return nil
end

-- The light item's name: the fan item's name and " Light" (N2). Only a name
-- that passes valid() gets one, so no light name is built from a bad name and
-- none is longer than 25 characters.
function names.light(name)
	if not names.valid(name) then
		return nil
	end
	return name .. LIGHT
end

-- The entries, as FNR's Appendix B lists them, one comment per family.
local ENTRIES = {
	-- 1801 Wynd (1801-60 seen on a Gen 3 fan)
	["1801-42"] = "Wynd 42",
	["1801-52"] = "Wynd 52",
	["1801-60"] = "Wynd 60",
	-- 1802 Vox (the downrod 38 was "Elf" in 2019)
	["1802-26"] = "Vox 26",
	["1802-38"] = "Vox 38",
	-- 1803 Axis
	["1803-44"] = "Axis 44",
	["1803-52"] = "Axis 52",
	-- 1804 Stargazer
	["1804-52"] = "Stargazer",
	-- 1805 Hydra
	["1805-80"] = "Hydra 80",
	["1805-96"] = "Hydra 96",
	["1805-120"] = "Hydra 120",
	-- 1806 Cervantes
	["1806-56"] = "Cervantes",
	-- 1807 Aloft
	["1807-44"] = "Aloft",
	-- 1809 Lotus
	["1809-54"] = "Lotus",
	-- 1810 Vortex
	["1810-60"] = "Vortex",
	-- 1811 Aviator: 1811-54 has three blades, 1811-5-54 five (the house fan)
	["1811-54"] = "Aviator 54",
	["1811-5-54"] = "Aviator 5",
	["1811-70"] = "Aviator 70",
	-- 1812 Morpheus II
	["1812-60"] = "Morpheus II",
	-- 1813 Morpheus III
	["1813-60"] = "Morpheus III",
	-- 1814 Woody
	["1814-60"] = "Woody 60",
	["1814-72"] = "Woody 72",
	-- 1815 Windflower
	["1815-60"] = "Windflower 60",
	["1815-80"] = "Windflower 80",
	-- 1816 Orb
	["1816-62"] = "Orb 62",
	["1816-82"] = "Orb 82",
	-- 1817 Osprey
	["1817-56"] = "Osprey",
	-- 1818 Nautilus (1818-56 seen in a public test fixture)
	["1818-56"] = "Nautilus",
	-- 1819 Mykonos
	["1819-52"] = "Mykonos",
	-- 1910 Roboto
	["1910-52"] = "Roboto 52",
	["1910-62"] = "Roboto 62",
	-- 1916 Nirvana
	["1916-56"] = "Nirvana",
	-- 1920 Venus
	["1920-60"] = "Venus",
	-- 1922 Paradox
	["1922-56"] = "Paradox",
	-- 2001 Renegade
	["2001-52"] = "Renegade 52",
	["2001-66"] = "Renegade 66",
	-- 2003 Slim (2003-52 seen in a public test fixture)
	["2003-52"] = "Slim",
	-- 2004 Tip Top
	["2004-44"] = "Tip Top 44",
	["2004-52"] = "Tip Top 52",
	-- 2006 Zephyr (2006-52 seen on a Gen 3 fan)
	["2006-52"] = "Zephyr 52",
	["2006-62"] = "Zephyr 62",
	["2006-72"] = "Zephyr 72",
	-- 2008 Mykonos 5
	["2008-60"] = "Mykonos 5",
	-- 2101 Wynd XL
	["2101-72"] = "Wynd XL",
	-- 2102 Ultra
	["2102-54"] = "Ultra",
	-- 2103 Twirl
	["2103-58"] = "Twirl",
	-- 2201 Wyndmill
	["2201-65"] = "Wyndmill",
	-- 2202 Skylark
	["2202-54"] = "Skylark 54",
	["2202-62"] = "Skylark 62",
	-- 2203 Corona
	["2203-44"] = "Corona 44",
	["2203-52"] = "Corona 52",
	-- 2204 Torque
	["2204-58"] = "Torque 58",
	["2204-70"] = "Torque 70",
	-- 2301 Roboto XL
	["2301-70"] = "Roboto XL",
	-- 2303 Aura
	["2303-60"] = "Aura 60",
	["2303-72"] = "Aura 72",
	-- 2304 Lucid
	["2304-62"] = "Lucid",
	-- 2401 Zephyr 5
	["2401-62"] = "Zephyr 5",
	-- 2402 Veloce
	["2402-28"] = "Veloce",
	-- 2403 Size Matters
	["2403-56"] = "Size Matters 56",
	["2403-65"] = "Size Matters 65",
	["2403-84"] = "Size Matters 84",
	-- 2404 Spinster
	["2404-60"] = "Spinster",
	-- 2501 Bolo
	["2501-56"] = "Bolo",
	["2501-62"] = "Bolo 62",
	-- 2502 Smooth
	["2502-52"] = "Smooth",
	-- 2503 Pisces
	["2503-54"] = "Pisces",
	-- 2504 Carve
	["2504-60"] = "Carve 60",
	["2504-72"] = "Carve 72",
	-- 2601 Smooth 5
	["2601-56"] = "Smooth 5",
	-- 2602 Crown
	["2602-62"] = "Crown",
	-- 2603 Radiant (2603-56 seen on a Gen 4 fan)
	["2603-56"] = "Radiant 56",
	["2603-64"] = "Radiant 64",
	-- 2605 Chill
	["2605-54"] = "Chill",
	-- 2606 Spoke
	["2606-60"] = "Spoke",
}

-- The table the module answers from: the entries, less any whose name fails
-- valid() (fail closed, ECR 5.4), which are counted.
names.TABLE = {}
names.DROPPED = 0
for key, name in pairs(ENTRIES) do
	if names.valid(name) then
		names.TABLE[key] = name
	else
		names.DROPPED = names.DROPPED + 1
	end
end

return names
