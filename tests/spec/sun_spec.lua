-- fan.sun: sunrise, sunset and night at the Control4 project's location (#137, docs/breeze-leds-design.md
-- section 1a, BL-D29, and the interface under BL-D28 and BL-D29). The module is pure arithmetic, so plain numbers
-- are the whole rig.
--
-- The module's NOAA equations are checked against two other methods, written here from other sources and never
-- shipped: the US Naval Observatory's sunrise and sunset algorithm from its "Almanac for Computers" (1990) for the
-- event times, and the Astronomical Almanac's low-precision solar coordinates with Greenwich mean sidereal time for
-- the sun's altitude at any instant. Dates become epoch seconds through a civil-calendar day count, so nothing here
-- depends on the machine's time zone. Every coordinate is a plain grid value, nobody's home.

local sun = require("fan.sun")

local RAD = math.pi / 180
local DAY, HOUR, MINUTE = 86400, 3600, 60
local HORIZON = -0.833 -- degrees: the sun's centre at the horizon, refraction included
local TOLERANCE = 3 * MINUTE -- the most the module and the USNO method may differ by

-- Days from 1970-01-01 to a date of the proleptic Gregorian calendar.
local function days(y, m, d)
	if m <= 2 then
		y = y - 1
	end
	local era = math.floor(y / 400)
	local year_of_era = y - era * 400
	local day_of_year = math.floor((153 * ((m + 9) % 12) + 2) / 5) + d - 1 -- counted from 1 March
	local day_of_era = year_of_era * 365 + math.floor(year_of_era / 4) - math.floor(year_of_era / 100) + day_of_year
	return era * 146097 + day_of_era - 719468
end

local function utc(y, m, d, h, mi, s)
	return days(y, m, d) * DAY + (h or 0) * HOUR + (mi or 0) * MINUTE + (s or 0)
end

local function stamp(epoch)
	return os.date("!%Y-%m-%d %H:%M:%S", epoch)
end

-- The USNO "Almanac for Computers" (1990) method: the sunrise (rising true) or sunset of a local date, as an epoch,
-- or nil when the sun does not cross the horizon that day. It works in local mean time and the day of the year.
local function usno(lat, lon, y, m, d, rising)
	local day_of_year = days(y, m, d) - days(y, 1, 1) + 1
	local lon_hours = lon / 15
	local t = day_of_year + ((rising and 6 or 18) - lon_hours) / 24
	local anomaly = 0.9856 * t - 3.289
	local long = (anomaly + 1.916 * math.sin(anomaly * RAD) + 0.020 * math.sin(2 * anomaly * RAD) + 282.634) % 360
	local ra = (math.atan(0.91764 * math.tan(long * RAD)) / RAD) % 360
	ra = (ra + math.floor(long / 90) * 90 - math.floor(ra / 90) * 90) / 15 -- in the quadrant of long, in hours
	local sin_dec = 0.39782 * math.sin(long * RAD)
	local cos_dec = math.cos(math.asin(sin_dec))
	local cos_h = (math.cos((90 - HORIZON) * RAD) - sin_dec * math.sin(lat * RAD)) / (cos_dec * math.cos(lat * RAD))
	if cos_h > 1 or cos_h < -1 then
		return nil
	end
	local h = math.acos(cos_h) / RAD
	if rising then
		h = 360 - h
	end
	local local_mean = (h / 15 + ra - 0.06571 * t - 6.622) % 24
	return days(y, m, d) * DAY + (local_mean - lon_hours) * HOUR
end

-- The Astronomical Almanac's low-precision sun: its altitude in degrees at an instant.
local function almanac_altitude(lat, lon, epoch)
	local n = epoch / DAY + 2440587.5 - 2451545
	local mean_long = 280.460 + 0.9856474 * n
	local anomaly = (357.528 + 0.9856003 * n) * RAD
	local ecliptic = (mean_long + 1.915 * math.sin(anomaly) + 0.020 * math.sin(2 * anomaly)) * RAD
	local obliquity = (23.439 - 0.0000004 * n) * RAD
	local ra = math.atan2(math.cos(obliquity) * math.sin(ecliptic), math.cos(ecliptic))
	local dec = math.asin(math.sin(obliquity) * math.sin(ecliptic))
	local sidereal = (18.697374558 + 24.06570982441908 * n) * 15 -- degrees
	local hour_angle = (sidereal + lon) * RAD - ra
	local lat_r = lat * RAD
	return math.asin(math.sin(lat_r) * math.sin(dec) + math.cos(lat_r) * math.cos(dec) * math.cos(hour_angle)) / RAD
end

-- The event of a kind in the module's list around `near` that lies closest to it.
local function nearest(lat, lon, kind, near)
	local best
	for _, ev in ipairs(sun.events(lat, lon, near)) do
		if ev.kind == kind and (not best or math.abs(ev.at - near) < math.abs(best - near)) then
			best = ev.at
		end
	end
	return best
end

-- The sunrise and sunset around the meridian's mean noon of a UTC date.
local function daylight(lat, lon, y, m, d)
	local noon = utc(y, m, d, 12) - lon * 240
	local rise, set
	for _, ev in ipairs(sun.events(lat, lon, noon)) do
		if ev.kind == "rise" and ev.at <= noon then
			rise = ev.at
		elseif ev.kind == "set" and ev.at > noon and not set then
			set = ev.at
		end
	end
	return rise, set
end

local function day_length(lat, lon, y, m, d)
	local rise, set = daylight(lat, lon, y, m, d)
	assert(rise and set, "no sunrise and sunset at " .. lat .. ", " .. lon)
	return set - rise
end

-- How far the module's events lie from the USNO method's over a set of places and dates, in seconds, and where
-- the worst one is. A place where USNO finds an event and the module none, or none of the same kind within an
-- hour, counts as a miss.
local function compare(lats, lons, dates)
	local worst, where, misses, count = 0, "nowhere", {}, 0
	for _, lat in ipairs(lats) do
		for _, lon in ipairs(lons) do
			for _, date in ipairs(dates) do
				for _, kind in ipairs({ "rise", "set" }) do
					local label = string.format("%s at %g, %g on %d-%02d-%02d", kind, lat, lon, date[1], date[2], date[3])
					local expected = usno(lat, lon, date[1], date[2], date[3], kind == "rise")
					local got = expected and nearest(lat, lon, kind, expected)
					if not expected or not got or math.abs(got - expected) > HOUR then
						misses[#misses + 1] = label
					else
						count = count + 1
						local diff = math.abs(got - expected)
						if diff > worst then
							worst, where = diff, label
						end
					end
				end
			end
		end
	end
	return worst, where, misses, count
end

local function range(from, to, step)
	local list = {}
	for x = from, to, step do
		list[#list + 1] = x
	end
	return list
end

describe("fan.sun", function()
	describe("the spec's own calendar", function()
		it("counts days from 1970 and knows the leap years, 2100 not among them", function()
			assert.equal(0, days(1970, 1, 1))
			assert.equal(10957, days(2000, 1, 1))
			assert.equal("2026-11-09 00:00:00", stamp(utc(2026, 11, 9)))
			assert.equal(2, days(2028, 3, 1) - days(2028, 2, 28))
			assert.equal(1, days(2027, 3, 1) - days(2027, 2, 28))
			assert.equal(1, days(2100, 3, 1) - days(2100, 2, 28))
			assert.equal(2, days(2000, 3, 1) - days(2000, 2, 28))
		end)
	end)

	describe("location (BL-D29: the project's Latitude and Longitude, checked)", function()
		it("takes plain decimal numbers, trimmed, with an optional sign", function()
			assert.same({ 40.7, -74 }, { sun.location(" 40.7 ", "-74.0") })
			assert.same({ 12.5, -0.5 }, { sun.location("+12.5", "-.5") })
			assert.same({ 51, 7 }, { sun.location("51.", "\t7\n") })
			assert.same({ 40, -74 }, { sun.location(40, -74) }, "numbers pass as they are")
		end)

		it("takes the ends of each range", function()
			assert.same({ 90, 180 }, { sun.location("90", "180") })
			assert.same({ -90, -180 }, { sun.location("-90", "-180") })
		end)

		it("refuses a latitude or longitude that is not set", function()
			for _, empty in ipairs({ { nil }, { "" }, { "   " }, { false }, { {} } }) do
				local lat, reason = sun.location(empty[1], "10")
				assert.is_nil(lat)
				assert.equal("The project's latitude is not set.", reason)
				lat, reason = sun.location("10", empty[1])
				assert.is_nil(lat)
				assert.equal("The project's longitude is not set.", reason)
			end
		end)

		it("refuses text that is not a plain decimal number", function()
			for _, text in ipairs({ "40,7", "40.7N", "N40", "1e1", "0x10", "nan", "inf", "-inf", "-", ".", "+",
				"4.5.6", "40 7", "--4", "4-", "forty" }) do
				local lat, reason = sun.location(text, "10")
				assert.is_nil(lat, text)
				assert.equal("The project's latitude is not a plain decimal number.", reason, text)
				lat, reason = sun.location("10", text)
				assert.is_nil(lat, text)
				assert.equal("The project's longitude is not a plain decimal number.", reason, text)
			end
			assert.is_nil((sun.location(0 / 0, "10")), "a NaN number")
			assert.is_nil((sun.location("10", math.huge)), "an infinite number")
		end)

		it("refuses a value out of range, without echoing it", function()
			for _, text in ipairs({ "90.0001", "-91", "123.456" }) do
				local lat, reason = sun.location(text, "10")
				assert.is_nil(lat, text)
				assert.equal("The project's latitude is outside -90 to 90 degrees.", reason)
			end
			for _, text in ipairs({ "180.5", "-181", "345.678" }) do
				local lat, reason = sun.location("10", text)
				assert.is_nil(lat, text)
				assert.equal("The project's longitude is outside -180 to 180 degrees.", reason)
			end
		end)

		it("refuses 0, 0 together (a location never set) but not a single 0", function()
			for _, pair in ipairs({ { "0", "0" }, { "0.0", "-0" }, { " 0 ", "+0.000" } }) do
				local lat, reason = sun.location(pair[1], pair[2])
				assert.is_nil(lat)
				assert.equal("The project's location is 0, 0, which means it was never set.", reason)
			end
			assert.same({ 0, 10 }, { sun.location("0", "10") })
			assert.same({ 10, 0 }, { sun.location("10", "0") })
		end)
	end)

	describe("events", function()
		it("lists whole-second sunrises and sunsets, in order, within the UTC days around epoch", function()
			local epoch = utc(2026, 6, 21, 15, 30)
			local list = sun.events(40, 0, epoch)
			assert.equal(6, #list)
			local first, last = utc(2026, 6, 20), utc(2026, 6, 23)
			for i, ev in ipairs(list) do
				assert.equal(i % 2 == 1 and "rise" or "set", ev.kind)
				assert.equal(math.floor(ev.at), ev.at)
				assert.is_true(ev.at >= first and ev.at < last, stamp(ev.at))
				if i > 1 then
					assert.is_true(ev.at > list[i - 1].at)
				end
			end
		end)

		it("gives the same list for any moment of the same UTC day", function()
			local list = sun.events(-34, 150, utc(2026, 6, 21))
			assert.same(list, sun.events(-34, 150, utc(2026, 6, 21, 23, 59, 59)))
			assert.same(list, sun.events(-34, 150, utc(2026, 6, 21, 12) + 0.25))
			assert.are_not.same(list, sun.events(-34, 150, utc(2026, 6, 22)))
		end)

		it("keeps an event that falls in a neighbouring UTC day of its solar day (east of Greenwich)", function()
			-- At 150E in June the sunrise comes about 21:05 UTC, the evening before its local date.
			local list = sun.events(-34, 150, utc(2026, 6, 21, 12))
			assert.equal("set", list[1].kind)
			local rise = nearest(-34, 150, "rise", utc(2026, 6, 21, 21))
			assert.is_true(math.abs(rise - utc(2026, 6, 21, 21, 5)) < 10 * MINUTE, stamp(rise))
		end)

		it("treats 180 and -180 as the same meridian", function()
			for _, epoch in ipairs({ utc(2026, 3, 1, 6), utc(2026, 9, 9, 23, 59, 59) }) do
				assert.same(sun.events(52, 180, epoch), sun.events(52, -180, epoch))
			end
		end)

		it("is empty for numbers that are not usable", function()
			assert.same({}, sun.events(nil, 0, utc(2026, 1, 1)))
			assert.same({}, sun.events(40, 0 / 0, utc(2026, 1, 1)))
			assert.same({}, sun.events(40, 0, math.huge))
			assert.same({}, sun.events("40", "0", utc(2026, 1, 1)))
		end)
	end)

	describe("agreement with the USNO Almanac for Computers method", function()
		it("is within 3 minutes from 55S to 60N, all round the world, through 2026 and 2027", function()
			local dates = {
				{ 2026, 1, 15 }, { 2026, 3, 20 }, { 2026, 5, 5 }, { 2026, 6, 21 }, { 2026, 8, 10 }, { 2026, 9, 23 },
				{ 2026, 11, 7 }, { 2026, 12, 21 }, { 2027, 2, 14 }, { 2027, 4, 30 }, { 2027, 7, 4 }, { 2027, 10, 31 },
			}
			local worst, where, misses, count = compare(range(-55, 60, 5), range(-180, 180, 45), dates)
			assert.same({}, misses)
			assert.equal(24 * 9 * 12 * 2, count)
			assert.is_true(worst <= TOLERANCE, string.format("worst %.0f s, %s", worst, where))
			assert.is_true(worst > 0, "the two methods are not the same method")
		end)
	end)

	describe("facts that need no outside source", function()
		it("gives the equator about 12 h 7 min of daylight at an equinox (refraction and the sun's radius)", function()
			for _, date in ipairs({ { 2026, 3, 20 }, { 2026, 9, 23 }, { 2027, 3, 20 } }) do
				local length = day_length(0, 0, date[1], date[2], date[3])
				assert.is_true(math.abs(length - (12 * HOUR + 7 * MINUTE)) <= 2 * MINUTE, tostring(length))
			end
		end)

		it("raises the sun at about 06:00 UTC at 0N 0E around the March equinox", function()
			local rise = daylight(0, 0, 2026, 3, 20)
			assert.is_true(math.abs(rise - utc(2026, 3, 20, 6)) <= 10 * MINUTE, stamp(rise))
		end)

		it("makes June days longer with latitude in the north and shorter in the south, December the reverse", function()
			local function lengths(lats, month, day)
				local list = {}
				for _, lat in ipairs(lats) do
					list[#list + 1] = day_length(lat, 0, 2026, month, day)
				end
				return list
			end
			local function rising(list, label)
				for i = 2, #list do
					assert.is_true(list[i] > list[i - 1], label .. " " .. i)
				end
			end
			local north, south = range(0, 60, 10), range(0, -50, -10)
			rising(lengths(north, 6, 21), "north in June")
			rising(lengths(south, 12, 21), "south in December")
			local june_south, december_north = lengths(south, 6, 21), lengths(north, 12, 21)
			for i = 2, #june_south do
				assert.is_true(june_south[i] < june_south[i - 1], "south in June " .. i)
			end
			for i = 2, #december_north do
				assert.is_true(december_north[i] < december_north[i - 1], "north in December " .. i)
			end
		end)

		it("has polar day at 78N in late June and polar night in late December, and the reverse at 78S", function()
			local june, december = utc(2026, 6, 25, 3), utc(2026, 12, 24, 15)
			for _, case in ipairs({
				{ 78, 15, june, false }, { 78, 15, december, true },
				{ -78, -60, june, true }, { -78, -60, december, false },
				{ 90, 0, june, false }, { -90, 0, june, true },
			}) do
				local lat, lon, epoch, dark = case[1], case[2], case[3], case[4]
				assert.same({}, sun.events(lat, lon, epoch))
				local is_night, change = sun.night(lat, lon, epoch)
				assert.equal(dark, is_night, lat .. " " .. stamp(epoch))
				assert.is_nil(change)
				-- every hour of the day the same: it is the sun's altitude, not the clock, that decides
				for h = 1, 23 do
					assert.same({ dark }, { sun.night(lat, lon, epoch + h * HOUR) })
				end
			end
		end)

		it("handles 29 February and 31 December of a leap year", function()
			local rise, set = daylight(40, 0, 2028, 2, 29)
			assert.is_true(rise >= utc(2028, 2, 29) and set < utc(2028, 3, 1), stamp(rise) .. " " .. stamp(set))
			local feb28, feb29, mar1 = day_length(40, 0, 2028, 2, 28), day_length(40, 0, 2028, 2, 29),
				day_length(40, 0, 2028, 3, 1)
			assert.is_true(feb28 < feb29 and feb29 < mar1)
			local worst, where, misses = compare(range(-50, 60, 10), { -120, 0, 135 }, {
				{ 2028, 2, 29 }, { 2028, 3, 1 }, { 2028, 12, 31 }, { 2024, 12, 31 }, { 2100, 3, 1 },
			})
			assert.same({}, misses)
			assert.is_true(worst <= TOLERANCE, string.format("worst %.0f s, %s", worst, where))
		end)
	end)

	describe("night", function()
		it("flips exactly at each sunset and sunrise", function()
			local list = sun.events(40, -74, utc(2026, 6, 21, 12))
			for i = 2, #list - 1 do
				local ev = list[i]
				local dark = ev.kind == "set"
				assert.same({ not dark, ev.at }, { sun.night(40, -74, ev.at - 1) })
				assert.same({ dark, list[i + 1].at }, { sun.night(40, -74, ev.at) })
				assert.same({ dark, list[i + 1].at }, { sun.night(40, -74, ev.at + 0.5) })
			end
		end)

		it("finds the next change across UTC midnight west of Greenwich (170W)", function()
			-- There the June sun sets about 06:52 UTC, the morning after its local date.
			local before = { sun.night(40, -170, utc(2026, 6, 21, 23, 59, 59)) }
			local after = { sun.night(40, -170, utc(2026, 6, 22)) }
			assert.is_false(before[1])
			assert.same(before, after)
			assert.is_true(before[2] > utc(2026, 6, 22, 6, 30) and before[2] < utc(2026, 6, 22, 7, 15), stamp(before[2]))
			assert.is_true((sun.night(40, -170, before[2])))
		end)

		it("finds the next change across UTC midnight east of Greenwich (150E)", function()
			-- At 34S 150E in June the sun rises about 21:05 UTC and sets about 06:58 UTC.
			local is_night, change = sun.night(-34, 150, utc(2026, 6, 21, 20))
			assert.is_true(is_night)
			assert.is_true(change > utc(2026, 6, 21, 20, 55) and change < utc(2026, 6, 21, 21, 15), stamp(change))
			is_night, change = sun.night(-34, 150, utc(2026, 6, 21, 23, 59, 59))
			assert.is_false(is_night)
			assert.is_true(change > utc(2026, 6, 22, 6, 45) and change < utc(2026, 6, 22, 7, 10), stamp(change))
		end)

		it("agrees with the sun's altitude, and its next change flips it, around the clock and the date line", function()
			local places = { { -34, 150 }, { 40, -170 }, { 52, 180 }, { -20, -180 }, { 60, 10 }, { 0, 90 }, { -55, -70 } }
			local margin = 0.5 -- degrees of altitude either side of the horizon where the methods may differ
			local checked = 0
			for _, place in ipairs(places) do
				local lat, lon = place[1], place[2]
				for _, start in ipairs({ utc(2026, 6, 21), utc(2026, 12, 21), utc(2027, 3, 20) }) do
					for t = start - 12 * HOUR, start + 48 * HOUR, 13 * MINUTE do
						local where = string.format("%g, %g at %s", lat, lon, stamp(t))
						local is_night, change = sun.night(lat, lon, t)
						assert.is_number(change, where)
						assert.is_true(change > t and change - t <= DAY, where)
						assert.equal(is_night, (sun.night(lat, lon, change - 1)), where)
						assert.equal(not is_night, (sun.night(lat, lon, change)), where)
						local altitude = almanac_altitude(lat, lon, t)
						if altitude > HORIZON + margin then
							assert.is_false(is_night, where)
							checked = checked + 1
						elseif altitude < HORIZON - margin then
							assert.is_true(is_night, where)
							checked = checked + 1
						end
					end
				end
			end
			assert.is_true(checked > 2500, tostring(checked))
		end)

		it("follows the sun's altitude at the edge of polar day, where a sunset has no sunrise after it", function()
			-- 70N in late May: the last few sunsets, then the midnight sun.
			local checked = 0
			for t = utc(2026, 5, 10), utc(2026, 6, 1), 37 * MINUTE do
				local is_night, change = sun.night(70, 20, t)
				local altitude = almanac_altitude(70, 20, t)
				if altitude > HORIZON + 0.5 then
					assert.is_false(is_night, stamp(t))
					checked = checked + 1
				elseif altitude < HORIZON - 0.5 then
					assert.is_true(is_night, stamp(t))
					checked = checked + 1
				end
				if change then
					assert.is_true(change > t)
				end
			end
			assert.is_true(checked > 700, tostring(checked))
			assert.same({ false }, { sun.night(70, 20, utc(2026, 6, 1)) })
		end)

		it("is never night for numbers that are not usable", function()
			assert.same({ false }, { sun.night(nil, 0, utc(2026, 12, 21)) })
			assert.same({ false }, { sun.night(78, 15, 0 / 0) })
			assert.same({ false }, { sun.night(78, "15", utc(2026, 12, 21)) })
		end)
	end)
end)
