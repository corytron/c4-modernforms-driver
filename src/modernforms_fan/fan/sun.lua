-- fan/sun.lua: sunrise, sunset and night at the Control4 project's location
-- (#137, docs/breeze-leds-design.md section 1a, BL-D29, for BL-D28's night
-- brightness). The driver passes in C4:GetProjectProperty("Latitude") and
-- ("Longitude") and the clock; everything is worked out here, on the
-- controller, with no internet.
--
-- The sun's position follows NOAA's solar equations (the ones behind NOAA's
-- Solar Calculator spreadsheet): from the Julian century, the sun's mean
-- longitude and anomaly give its apparent longitude, which with the corrected
-- obliquity gives its declination and the equation of time. The sun is up
-- while its centre is above -0.833 degrees (refraction and the sun's radius),
-- that is at a zenith of 90.833 degrees. Each event is then found by iteration:
-- its time is guessed at the meridian's mean noon, the sun's position is taken
-- again at the guessed time, and the time is worked out anew, until it moves by
-- less than a second.
--
-- Times are epoch seconds, as os.time() returns them (UTC-based), so the
-- controller's time zone never matters; the Julian day comes straight from the
-- epoch. Latitude is north positive and longitude east positive, in degrees.
-- Pure: no Director calls, no clock, no log.
--
--   sun.location(lat_text, lon_text)  -> lat, lon, or nil and a reason (one English sentence for the log)
--   sun.events(lat, lon, epoch)       -> sorted { { at = epoch_s, kind = "rise" | "set" }, ... }: every sunrise
--                                        and sunset within the UTC day containing epoch and the UTC days on
--                                        either side of it; a day of polar day or polar night has none
--   sun.night(lat, lon, epoch)        -> is_night, next_change (epoch_s, or nil when no event follows)
--
-- night() decides by the last event at or before epoch ("set" is night, "rise"
-- is day), so it flips exactly at each event's second, and next_change is the
-- first event after epoch. Below 60 degrees or so there is always an event on
-- both sides, since the list reaches at least a day either way. Where there is
-- not (polar day or night, or the few days at the edge of one, where the last
-- set may have no rise after it), the sun's altitude at epoch decides instead,
-- and next_change is the first event after epoch if there is one, else nil, so
-- the caller looks again later. Numbers that are not finite, which location()
-- never returns, give no events and never night.

local sun = {}

local RAD = math.pi / 180
local DAY = 86400
-- The sun's centre at the horizon, as NOAA counts it, in degrees of altitude.
local HORIZON = -0.833
-- A degree of hour angle is four minutes of time.
local S_PER_DEGREE = 240
-- 1970-01-01 00:00 UTC as a Julian day, and J2000.0 (2000-01-01 12:00 TT).
local JD_EPOCH = 2440587.5
local JD_2000 = 2451545
local ITERATIONS = 6

local sin, cos, tan, asin, acos, floor = math.sin, math.cos, math.tan, math.asin, math.acos, math.floor

local function finite(x)
	return type(x) == "number" and x == x and x ~= math.huge and x ~= -math.huge
end

-- The sun at an instant: its declination (radians) and the equation of time
-- (minutes; how far the true sun runs ahead of the mean sun).
local function position(epoch)
	local t = (epoch / DAY + JD_EPOCH - JD_2000) / 36525 -- Julian centuries since J2000.0
	local mean_long = (280.46646 + t * (36000.76983 + t * 0.0003032)) % 360
	local anomaly = (357.52911 + t * (35999.05029 - t * 0.0001537)) * RAD
	local ecc = 0.016708634 - t * (0.000042037 + t * 0.0000001267)
	local centre = sin(anomaly) * (1.914602 - t * (0.004817 + t * 0.000014))
		+ sin(2 * anomaly) * (0.019993 - t * 0.000101)
		+ sin(3 * anomaly) * 0.000289
	local node = (125.04 - 1934.136 * t) * RAD -- the moon's ascending node, for nutation
	local apparent = (mean_long + centre - 0.00569 - 0.00478 * sin(node)) * RAD
	local seconds = 21.448 - t * (46.815 + t * (0.00059 - t * 0.001813))
	local obliquity = (23 + (26 + seconds / 60) / 60 + 0.00256 * cos(node)) * RAD
	local declination = asin(sin(obliquity) * sin(apparent))
	local y = tan(obliquity / 2) ^ 2
	local l2 = 2 * mean_long * RAD
	local eot = y * sin(l2) - 2 * ecc * sin(anomaly) + 4 * ecc * y * sin(anomaly) * cos(l2)
		- 0.5 * y * y * sin(2 * l2) - 1.25 * ecc * ecc * sin(2 * anomaly)
	return declination, 4 * eot / RAD
end

-- The hour angle (degrees) at which the sun crosses the horizon, or nil when it
-- stays above it (polar day) or below it (polar night) at this declination.
local function crossing(lat_r, declination)
	local x = (cos((90 - HORIZON) * RAD) - sin(lat_r) * sin(declination)) / (cos(lat_r) * cos(declination))
	if not (x >= -1 and x <= 1) then
		return nil
	end
	return acos(x) / RAD
end

-- One event of solar day k, the day whose mean noon on this meridian falls
-- near k * DAY + 12 h - lon * 4 min: sign -1 is the sunrise, +1 the sunset.
-- Returns the epoch (not rounded), or nil when the sun does not cross.
local function event(k, lat_r, lon, sign)
	local mean_noon = k * DAY + DAY / 2 - lon * S_PER_DEGREE
	local at = mean_noon
	for _ = 1, ITERATIONS do
		local declination, eot = position(at)
		local ha = crossing(lat_r, declination)
		if not ha then
			return nil
		end
		local next_at = mean_noon - eot * 60 + sign * ha * S_PER_DEGREE
		local moved = next_at - at
		at = next_at
		if moved < 1 and moved > -1 then
			break
		end
	end
	return at
end

-- The sun's altitude (degrees) at an instant.
local function altitude(lat, lon, epoch)
	local declination, eot = position(epoch)
	local solar_minutes = (epoch % DAY) / 60 + eot + 4 * lon
	local hour_angle = (solar_minutes / 4 - 180) * RAD
	local lat_r = lat * RAD
	local s = sin(lat_r) * sin(declination) + cos(lat_r) * cos(declination) * cos(hour_angle)
	if s > 1 then
		s = 1
	elseif s < -1 then
		s = -1
	end
	return asin(s) / RAD
end

-- A property text as a plain decimal number: optional sign, digits with an
-- optional point. Anything else (a comma, an exponent, hex, "nan", "inf") is
-- not taken. Returns the number, or nil and "empty" or "nan".
local function decimal(text)
	if type(text) == "number" then
		if finite(text) then
			return text
		end
		return nil, "nan"
	end
	if type(text) ~= "string" then
		return nil, "empty"
	end
	local trimmed = text:match("^%s*(.-)%s*$")
	if trimmed == "" then
		return nil, "empty"
	end
	local sign, whole, fraction = trimmed:match("^([+-]?)(%d*)%.?(%d*)$")
	if not sign or (whole == "" and fraction == "") then
		return nil, "nan"
	end
	local value = tonumber((whole ~= "" and whole or "0") .. "." .. (fraction ~= "" and fraction or "0"))
	if not value then
		return nil, "nan"
	end
	return sign == "-" and -value or value
end

local PROBLEM = {
	empty = "The project's %s is not set.",
	nan = "The project's %s is not a plain decimal number.",
}

-- The project's latitude and longitude as numbers, or nil and why not.
function sun.location(lat_text, lon_text)
	local lat, lat_problem = decimal(lat_text)
	if not lat then
		return nil, PROBLEM[lat_problem]:format("latitude")
	end
	local lon, lon_problem = decimal(lon_text)
	if not lon then
		return nil, PROBLEM[lon_problem]:format("longitude")
	end
	if lat > 90 or lat < -90 then
		return nil, "The project's latitude is outside -90 to 90 degrees."
	end
	if lon > 180 or lon < -180 then
		return nil, "The project's longitude is outside -180 to 180 degrees."
	end
	if lat == 0 and lon == 0 then
		return nil, "The project's location is 0, 0, which means it was never set."
	end
	return lat, lon
end

local function earlier(a, b)
	if a.at ~= b.at then
		return a.at < b.at
	end
	return a.kind < b.kind
end

-- Every sunrise and sunset within the UTC day containing epoch, the day before
-- and the day after, in order. Solar days two either side are worked out too,
-- since an event of one can fall in a neighbouring UTC day; each event is kept
-- only if its time lies within the three days.
function sun.events(lat, lon, epoch)
	local list = {}
	if not (finite(lat) and finite(lon) and finite(epoch)) then
		return list
	end
	local day = floor(epoch / DAY)
	local first, last = (day - 1) * DAY, (day + 2) * DAY
	local lat_r = lat * RAD
	for k = day - 2, day + 2 do
		for sign = -1, 1, 2 do
			local at = event(k, lat_r, lon, sign)
			if at then
				at = floor(at + 0.5)
				if at >= first and at < last then
					list[#list + 1] = { at = at, kind = sign < 0 and "rise" or "set" }
				end
			end
		end
	end
	table.sort(list, earlier)
	return list
end

-- Whether it is night at epoch, and when that next changes.
function sun.night(lat, lon, epoch)
	if not (finite(lat) and finite(lon) and finite(epoch)) then
		return false, nil
	end
	local before, after
	for _, ev in ipairs(sun.events(lat, lon, epoch)) do
		if ev.at <= epoch then
			before = ev
		elseif not after then
			after = ev
		end
	end
	if before and after then
		return before.kind == "set", after.at
	end
	return altitude(lat, lon, epoch) <= HORIZON, after and after.at or nil
end

return sun
