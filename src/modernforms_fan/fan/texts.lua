-- fan/texts.lua: every string the owner can read, in one place (v1 contract
-- section 9.6; the wording is section 7's). Pure: plain tables in, strings
-- out, no Director calls, so the manual and the specs can pin every word.
-- Nothing else in the driver builds a Status, a Last Action or a property
-- text.
--
-- What this file keeps for the whole driver:
--   * A value the caller did not have shows as "?" inside a sentence, or the
--     optional clause (" since 14:02") is left out; no function raises and
--     none prints "nil". A row with nothing to say is "" (no fan pinned yet,
--     no firmware read, an unknown phase or result key).
--   * Private data (V20, section 3.7): each function reads only the fields its
--     comment names, so an owner, an SSID or the schedule blob riding along in
--     a state table cannot reach a row. The client id and the MAC are written
--     in full only where section 7 shows them (Fan ID, Last Action L1 to L4);
--     another fan is named by its last four hex digits, "...5302" (S11, and
--     texts.suffix for the log lines).
--   * ASCII only, except U+201A, which stands for a comma inside a list item
--     (a list property is one comma-separated string), as the Hue drivers
--     write it. What the owner typed into Fan Address is echoed cut, with
--     every byte outside printable ASCII shown as "?".
--   * Rows stay under about 70 characters (Composer clips near 75, ECC F29).
--     Two texts can pass that: Fan Automations with every item active (84
--     characters; the contract gives no shorter form) and S9 with a
--     15-character address and a date, which reaches exactly 75 where section
--     7.1 says it stays under 75.

local texts = {}

-- The oldest controller OS the light is known to work on (V3, section 2.1).
texts.MIN_OS = "3.3.0"

-- Links the driver declares: nine fan links (300 to 308) and three light
-- links (200 to 202), section 2.4. "5 of 12 links bound" counts against it.
texts.LINK_COUNT = 12

-- Found Fans lists at most this many fans (section 7.3).
texts.MAX_FOUND = 16

-- Phases texts.status understands (section 6.1; the names are the ones
-- m:want's refusals use, section 9.5). "invalid" and "invalid address" are
-- the S3 case spelt out, for a model that keeps it apart from "unset".
texts.PHASES = { "unset", "waiting", "online", "offline", "rebooting", "foreign", "gen4", "notfan" }

-- Keys texts.result understands, in the contract's order (section 9.6).
texts.RESULT_KEYS = {
	"learned", "moved", "now_using", "already", "no_answer", "not_a_fan", "nothing_to_use", "found",
	"found_none", "find_failed", "reboot_sent", "reboot_offline", "reboot_refused", "reboot_pending",
	"away_off", "away_already", "learning_off", "learning_already", "not_answering", "not_taken", "not_picked",
}

-- S3 shows the typed text cut to this many characters (section 7.1).
local TYPED_CUT = 24

-- A time is shown with its date once it is older than this (section 7).
local DAY_S = 86400

-- U+201A, the "comma" of a list item (as the Hue drivers write it).
local LOW_QUOTE = "\226\128\154"

-- Helpers -----------------------------------------------------------------

-- Larger than any speed, level, count, device id or minute count the fan or
-- Director can give; string.format("%d") is only trusted below it.
local BIG = 2147483647

-- Text for a string or a whole number; "" for anything else (nil, a table, a
-- boolean, a fraction, nan, inf), so a wrong type never prints as "table:
-- 0x...", "true" or "1e+308".
local function scalar(x)
	local kind = type(x)
	if kind == "string" then
		return x
	elseif kind == "number" and x == math.floor(x) and x > -BIG and x < BIG then
		return string.format("%d", x)
	end
	return ""
end

-- A value a sentence needs: "?" when the caller had none.
local function val(x)
	local s = scalar(x)
	if s == "" then
		return "?"
	end
	return s
end

local function trim(s)
	return (s:match("^%s*(.-)%s*$"))
end

-- A whole number as a string; nil for what is not a number of sensible size
-- (a speed, a level, a count). Lua 5.1's tonumber reads "nan" and "inf",
-- hence the guard.
local function whole(x)
	local n = tonumber(x)
	if not n or n ~= n or n >= BIG or n <= -BIG then
		return nil
	end
	return string.format("%d", math.floor(n + 0.5))
end

-- A timer value that means "running": a positive finite number (Gen 3: seconds
-- left; Gen 1/2: the epoch time it switches off, 0 for none).
local function running(x)
	local n = tonumber(x)
	if not n or n ~= n or n <= 0 or n == math.huge then
		return nil
	end
	return n
end

-- Minutes, rounded up, of a Gen 3 timer's seconds left; nil when it has none.
local function minutes_left(seconds)
	local n = running(seconds)
	return n and string.format("%d", math.min(math.ceil(n / 60), BIG)) or nil
end

-- os.date in the controller's local time; nil where it cannot format.
local function stamp(fmt, at)
	local ok, out = pcall(os.date, fmt, at)
	if ok and type(out) == "string" then
		return out
	end
	return nil
end

-- A date for the Firmware row: the "2026-10-27" text the store keeps, or a
-- time in seconds.
local function date_text(x)
	if type(x) == "number" then
		return stamp("%Y-%m-%d", x) or ""
	end
	return scalar(x)
end

-- The hex digits of an id, a MAC with or without colons, or a client id
-- ("MF_00005E005301" gives "F00005E005301": only its tail is used).
local function hex_of(id)
	return (scalar(id):gsub("[^%x]", ""))
end

-- The 12 hex digits of a MAC, lower case; nil unless there are exactly 12 in
-- the text (a client id carries more: it goes through mac_key instead).
local function mac_digits(text)
	local hex = hex_of(text):lower()
	if #hex ~= 12 then
		return nil
	end
	return hex
end

-- A comparison key for "is this the same fan's MAC": the last 12 hex digits,
-- so a mac12, a colon form and a client id all give the same key.
local function mac_key(id)
	local hex = hex_of(id):lower()
	if #hex < 12 then
		return nil
	end
	return hex:sub(-12)
end

-- Printable ASCII only; used on text the owner typed.
local function ascii(s)
	return (s:gsub("[^ -~]", "?"))
end

-- A list item (a DYNAMIC_LIST is one comma-separated string,
-- C4:UpdatePropertyList): no control characters, and a comma written as U+201A.
function texts.list_item(text)
	return (scalar(text):gsub("%c", ""):gsub(",", LOW_QUOTE))
end

-- Times --------------------------------------------------------------------

-- A time for a row: "14:02", or "10-26 14:02" once `at_s` is more than 24 h
-- before `now_s` (section 7). "" when `at_s` is not a time. Both in seconds
-- (os.time), shown in the controller's local time.
function texts.clock(at_s, now_s)
	local at = tonumber(at_s)
	if not at then
		return ""
	end
	local now = tonumber(now_s)
	local fmt = "%H:%M"
	if now and now - at > DAY_S then
		fmt = "%m-%d %H:%M"
	end
	return stamp(fmt, at) or ""
end

-- " since 14:02" for the clause of a sentence; "" when the time is unknown.
local function clause(word, at_s, now_s)
	local when = texts.clock(at_s, now_s)
	if when == "" then
		return ""
	end
	return " " .. word .. " " .. when
end

-- Identity -----------------------------------------------------------------

-- "...5302": the last four hex digits of a client id or MAC, upper case like
-- the client id. S11 uses it for another fan; log lines use it for the pinned
-- one (V20). "...?" when there is no digit to show.
function texts.suffix(id)
	local tail = hex_of(id):sub(-4):upper()
	if tail == "" then
		return "...?"
	end
	return "..." .. tail
end

-- "00:00:5e:00:53:01" from "00005E005301" (any case, with or without
-- colons); "" when the text is not exactly 12 hex digits.
function texts.mac(mac12)
	local hex = mac_digits(mac12)
	if not hex then
		return ""
	end
	return (hex:gsub("(%x%x)", "%1:"):sub(1, -2))
end

-- Fan ID: "MF_00005E005301 (MAC 00:00:5e:00:53:01)", from the pin the model
-- keeps ({ client_id, mac, ... }); "" before the first contact (section 7.3).
function texts.fan_id(pin)
	if type(pin) ~= "table" then
		return ""
	end
	local id = scalar(pin.client_id)
	if id == "" then
		return ""
	end
	local mac = texts.mac(pin.mac)
	if mac == "" then
		return id
	end
	return string.format("%s (MAC %s)", id, mac)
end

-- The pin back from a Fan ID row (section 8: after a restore onto a new
-- controller the store may be empty and the row is all there is, ECC D10):
-- { client_id = "MF_00005E005301", mac = "00005E005301" } (mac nil when the row
-- has none), or nil when the text is not a Fan ID row. The inverse of fan_id.
function texts.parse_fan_id(text)
	local id, rest = scalar(text):match("^%s*(%a+_%x%x%x%x%x%x%x%x%x%x%x%x)(.*)$")
	if not id or not (rest == "" or rest:match("^%s")) then
		return nil
	end
	local colon_mac = rest:match("%(MAC%s+([%x:]+)%)")
	local mac = colon_mac and mac_digits(colon_mac)
	return { client_id = id, mac = mac and mac:upper() or nil }
end

-- "Gen 3", "Gen 1/2", "Gen ?" for the generation the model keeps as text.
local function gen_label(generation)
	local g = scalar(generation)
	if g == "3" or g == "1/2" then
		return g
	end
	return "?"
end

-- Fan Model: "Gen 3, fan 1811-5-54, light kit F4IN-120V-R1-30, Breeze" and
-- the forms of section 7.3. `pin` carries the generation, `info` the types
-- ({ fan_type, light_type, has_light, has_wind }). "" until the info is known.
function texts.fan_model(pin, info, has_wind)
	if type(info) ~= "table" then
		return ""
	end
	local generation = type(pin) == "table" and pin.generation or nil
	local fan = val(info.fan_type)
	local kit = scalar(info.light_type)
	local light = "no light kit"
	if kit ~= "" and info.has_light ~= false then
		light = "light kit " .. kit
	end
	local out = string.format("Gen %s, fan %s, %s", gen_label(generation), fan, light)
	if has_wind == nil then
		has_wind = info.has_wind
	end
	if has_wind == true then
		out = out .. ", Breeze"
	end
	return out
end

-- Firmware: "02.00.0052 (motor 03.00.0000) since 2026-10-27", and after a
-- change "02.00.0060 (motor 03.00.0000) since 2026-11-02, was 02.00.0052"
-- (section 7.3). `info` = { firmware, mcu_firmware, firmware_since,
-- firmware_was }. "" until a firmware is known.
function texts.firmware(info)
	if type(info) ~= "table" then
		return ""
	end
	local firmware = scalar(info.firmware)
	if firmware == "" then
		return ""
	end
	local out = firmware
	local motor = scalar(info.mcu_firmware)
	if motor ~= "" then
		out = out .. " (motor " .. motor .. ")"
	end
	local since = date_text(info.firmware_since)
	if since ~= "" then
		out = out .. " since " .. since
	end
	local was = scalar(info.firmware_was)
	if was ~= "" then
		out = out .. ", was " .. was
	end
	return out
end

-- Last Seen: "2026-10-27 18:02:10, answered in 0.31 s" (section 7.3); the
-- caller writes it at most every 10 s. `at_s` is the time of the answer in
-- seconds, `ms` how long it took. "" when the time is unknown.
function texts.last_seen(at_s, ms)
	local at = tonumber(at_s)
	local when = at and stamp("%Y-%m-%d %H:%M:%S", at)
	if not when then
		return ""
	end
	local took = tonumber(ms)
	if not took or took ~= took or took >= BIG then
		return when
	end
	return string.format("%s, answered in %.2f s", when, math.max(0, took) / 1000)
end

-- Last Change By: "<who> at 14:05", from the Gen 3 `userData` source
-- (section 7.3). Only the six known values are named; anything else, "none"
-- or nothing (Gen 1/2) is "Outside Control4 (source not reported)", so a value
-- the fan sends is never echoed.
local SOURCES = {
	ble = "Remote or wall control",
	local_wifi = "Modern Forms app or another local client",
	cloud = "Modern Forms cloud (app away, voice assistant)",
	sleep_timer = "The fan's sleep timer",
	away_mode = "The fan's away mode",
	schedule = "A schedule in the Modern Forms app",
}
local SOURCE_OTHER = "Outside Control4 (source not reported)"

function texts.change_by(user_data, at_s, now_s)
	local who = SOURCES[trim(scalar(user_data)):lower()] or SOURCE_OTHER
	return who .. clause("at", at_s, now_s)
end

-- Fan Automations: "None", or "Active: " and the items joined by ", "
-- (section 7.3). `st` is the state record ({ schedule_set, away, learning,
-- fan_timer, light_timer, fan_sleep_timer, light_sleep_timer, generation });
-- `generation` ("3" or "1/2", else st.generation) picks the timers: Gen 3
-- reports seconds left (shown in minutes, rounded up), Gen 1/2 only that a
-- timer is set. With no generation, whichever fields came are read. The
-- schedule itself is never read, only whether one is set. With every item
-- active the long forms of section 7.3 are 84 characters (78 on Gen 1/2),
-- which Composer clips: past 72 the two longest names are shortened (below).
-- "" when there is no state to judge.
function texts.automations(st, generation)
	if type(st) ~= "table" then
		return ""
	end
	local gen = scalar(generation)
	if gen == "" then
		gen = scalar(st.generation)
	end
	-- Composer clips a row near 75 characters (ECC F29) and every item active
	-- at once is 84 long in section 7.3's long forms: past 72 the two longest
	-- names are shortened ("away mode" to "away", "adaptive learning" to
	-- "learning"), which keeps that case at 70.
	local function build(short)
		local items = {}
		if st.schedule_set == true then
			items[#items + 1] = "schedule"
		end
		if st.away == true then
			items[#items + 1] = short and "away" or "away mode"
		end
		if st.learning == true then
			items[#items + 1] = short and "learning" or "adaptive learning"
		end
		if gen ~= "1/2" then
			local fan, light = minutes_left(st.fan_timer), minutes_left(st.light_timer)
			if fan then
				items[#items + 1] = "fan timer " .. fan .. " min"
			end
			if light then
				items[#items + 1] = "light timer " .. light .. " min"
			end
		end
		if gen ~= "3" then
			if running(st.fan_sleep_timer) then
				items[#items + 1] = "fan timer set"
			end
			if running(st.light_sleep_timer) then
				items[#items + 1] = "light timer set"
			end
		end
		if #items == 0 then
			return "None"
		end
		return "Active: " .. table.concat(items, ", ")
	end
	local text = build(false)
	if #text > 72 then
		text = build(true)
	end
	return text
end

-- Status ---------------------------------------------------------------------

-- A dotted version ("3.2.1" or "3.2.1.543210", or the table
-- C4:GetVersionInfo returns) as its first three numbers, and the text of
-- those; nil when there is no number in it.
local function version_of(raw)
	if type(raw) == "table" then
		raw = raw.version
	end
	local nums = {}
	for digits in scalar(raw):gmatch("%d+") do
		nums[#nums + 1] = math.min(tonumber(digits), 999999)
		if #nums == 3 then
			break
		end
	end
	if #nums == 0 then
		return nil
	end
	local shown = table.concat(nums, ".")
	while #nums < 3 do
		nums[#nums + 1] = 0
	end
	return nums, shown
end

-- Is this controller OS older than texts.MIN_OS (the S14 case)? false for
-- anything that is not a version, so an unknown OS never raises the warning.
function texts.os_is_old(raw)
	local have = version_of(raw)
	local need = version_of(texts.MIN_OS)
	if not have then
		return false
	end
	for i = 1, 3 do
		if have[i] ~= need[i] then
			return have[i] < need[i]
		end
	end
	return false
end

-- S14, which takes the place of S4 to S6 on an old controller; nil otherwise.
local function old_os_status(v)
	if not texts.os_is_old(v.os) then
		return nil
	end
	local _, shown = version_of(v.os)
	return string.format("Controller OS %s is older than %s; the light may misbehave", shown, texts.MIN_OS)
end

-- The part a missing key pauses (S6; section 7.1).
local MISSING_PART = {
	fanOn = "speed",
	fanSpeed = "speed",
	fanDirection = "direction",
	lightOn = "light",
	lightBrightness = "light",
}

-- S5's fan part: "speed 3", "off", then " reverse" and " Breeze" when they apply.
local function fan_part(st)
	local out = "unknown"
	if st.fan_on == true then
		local speed = whole(st.speed)
		out = speed and ("speed " .. speed) or "on"
	elseif st.fan_on == false then
		out = "off"
	end
	if st.direction == "reverse" then
		out = out .. " reverse"
	end
	if st.wind == true then
		out = out .. " Breeze"
	end
	return out
end

-- S5's light part: "light off", "light 40 %", or "no light kit".
local function light_part(st, has_light)
	if has_light == false then
		return "no light kit"
	end
	if st.light_on == true then
		local level = whole(st.level)
		return level and ("light " .. level .. " %") or "light on"
	elseif st.light_on == false then
		return "light off"
	end
	return "light unknown"
end

local STATUS = {}

-- S1, S2, S3: no usable address. The text the owner typed is S3's.
function STATUS.unset(v)
	local typed = ascii(trim(scalar(v.typed)))
	if typed ~= "" then
		return string.format('Fan Address "%s" is not an IPv4 address', typed:sub(1, TYPED_CUT))
	end
	if v.find_fans == true then
		return "Not set up: Find Fans, or enter the fan's address in Fan Address"
	end
	return "Not set up: enter the fan's address in Fan Address"
end
STATUS.invalid = STATUS.unset
STATUS["invalid address"] = STATUS.unset

-- S4, or S14 in its place.
function STATUS.waiting(v)
	return old_os_status(v) or string.format("Waiting for the fan at %s", val(v.address))
end

-- S5, S6 or S14.
function STATUS.online(v)
	local old = old_os_status(v)
	if old then
		return old
	end
	local missing = v.missing
	if type(missing) == "table" then
		missing = missing[1]
	end
	missing = scalar(missing)
	if missing ~= "" then
		local part = MISSING_PART[missing]
		local tail = part and ("; " .. part .. " control paused") or ""
		return "Online, but the fan reports no " .. missing .. tail
	end
	local st = type(v.st) == "table" and v.st or {}
	return string.format("Online: fan %s, %s", fan_part(st), light_part(st, v.has_light))
end

-- S7, S8, S9: offline after timeouts and refusals, or after answers that
-- held nothing usable; with or without a state to show.
function STATUS.offline(v)
	local since = clause("since", v.since, v.now)
	local tail = v.known == true and "; showing last state" or "; state unknown"
	if v.failure == "data" then
		return string.format("No usable answer from %s%s%s", val(v.address), since, tail)
	end
	return string.format("Not answering at %s%s%s", val(v.address), since, tail)
end

-- S10.
function STATUS.rebooting(v)
	local when = texts.clock(v.sent, v.now)
	if when == "" then
		return "Rebooting the fan's Wi-Fi module"
	end
	return string.format("Rebooting the fan's Wi-Fi module (sent %s)", when)
end

-- S11: another fan answers at the address; named by the end of its MAC.
function STATUS.foreign(v)
	return string.format("Another fan (%s) answers at %s; nothing is sent", texts.suffix(v.other), val(v.address))
end

-- S12.
function STATUS.gen4(v)
	return string.format("%s is a Gen 4 fan; this driver controls Gen 1 to 3 only", val(v.address))
end

-- S13.
function STATUS.notfan(v)
	return string.format("%s answers, but not as a Modern Forms fan; nothing is sent", val(v.address))
end

-- Status: the one line of section 7.1 for the model's status view
-- (m:status_view(), section 9.5):
--   phase      one of texts.PHASES
--   address    the fan's address (S4, S7 to S9, S11 to S13)
--   typed      what the owner typed into Fan Address (S3, with phase "unset")
--   since      seconds, when the fan went quiet (S7 to S9)
--   sent       seconds, when the reboot was sent (S10)
--   now        seconds, the present (a time older than 24 h shows its date)
--   failure    "data" for S9; anything else is S7 or S8
--   known      a state is known in this run (S7, S9: "showing last state")
--   other      the other fan's client id or MAC (S11)
--   st         the state record (S5): fan_on, speed, direction, wind, light_on, level
--   has_light  false for "no light kit"
--   has_wind   accepted and unused: Breeze is shown from st.wind, being on
--   missing    the key a needed field is missing as (S6): "fanSpeed" and so on
--   os         the controller's version, text or C4:GetVersionInfo()'s table (S14)
--   find_fans  the build has Find Fans (S1 against S2)
-- Priority when several apply is section 7.1's: S3/S1/S2, S11 to S13, S10,
-- S7 to S9, S14, then S4 to S6. The phase is one value, so it settles most of
-- that by itself; what is left is S3 against S1/S2 (the typed text), and S14
-- against S4 to S6, where S14 outranks S6 as the priority line says although
-- the table names only S4 and S5. "" for an unknown phase.
function texts.status(v)
	v = type(v) == "table" and v or {}
	local build = STATUS[v.phase]
	if not build then
		return ""
	end
	return build(v)
end

-- Last Action ---------------------------------------------------------------

-- The fields a result text reads, from args and, for what args lacks, from
-- args.pin (the model may hand over the identity whole):
--   client_id, generation, address   the fan (L1 to L4, L21, ...)
--   was                              the previous client id, or a pin (L3)
--   count, or list                   fans found (L8)
--   find_fans                        the build has Find Fans (L7)
--   at, now                          seconds: when the reboot was sent (L11, L20)
--   which                            "away" or "learning" (L19)
local function fields(args)
	local a = type(args) == "table" and args or {}
	local pin = type(a.pin) == "table" and a.pin or {}
	local function pick(key)
		if a[key] ~= nil then
			return a[key]
		end
		return pin[key]
	end
	local was = a.was
	if type(was) == "table" then
		was = was.client_id
	end
	local count = a.count
	if count == nil and type(a.list) == "table" then
		count = #a.list
	end
	return {
		client_id = scalar(pick("client_id")),
		generation = pick("generation"),
		address = scalar(pick("address")),
		was = scalar(was),
		count = whole(count),
		find_fans = a.find_fans == true,
		at = a.at,
		now = a.now,
		which = a.which,
	}
end

local RESULTS = {}

-- L1: first contact pinned a fan.
function RESULTS.learned(f)
	return string.format("Learned fan %s (Gen %s) at %s", val(f.client_id), gen_label(f.generation), val(f.address))
end

-- L2: the pinned fan at a typed or picked new address.
function RESULTS.moved(f)
	return string.format("Same fan %s, now at %s", val(f.client_id), val(f.address))
end

-- L3: Use Selected Fan re-pointed; with no fan pinned before, the address instead of "was".
function RESULTS.now_using(f)
	if f.was ~= "" then
		return string.format("Now using fan %s (was %s)", val(f.client_id), f.was)
	end
	return string.format("Now using fan %s at %s", val(f.client_id), val(f.address))
end

-- L4.
function RESULTS.already(f)
	return string.format("Already using fan %s at %s", val(f.client_id), val(f.address))
end

-- L5.
function RESULTS.no_answer(f)
	return string.format("No fan answers at %s; nothing changed", val(f.address))
end

-- L6.
function RESULTS.not_a_fan(f)
	return string.format("%s is not a Gen 1 to 3 Modern Forms fan; nothing changed", val(f.address))
end

-- L7: with Find Fans, the pick is a way too.
function RESULTS.nothing_to_use(f)
	if f.find_fans then
		return "Nothing to use: pick a fan in Found Fans, or enter Fan Address"
	end
	return "Nothing to use: enter the fan's address in Fan Address"
end

-- L9: also what "found" says for none.
function RESULTS.found_none()
	return "No Modern Forms fan answered on this network"
end

-- L8: one fan or several.
function RESULTS.found(f)
	local count = tonumber(f.count)
	if not count or count < 1 then
		return RESULTS.found_none()
	elseif count == 1 then
		return "Found 1 fan: pick it in Found Fans, then Use Selected Fan"
	end
	return string.format("Found %d fans: pick one in Found Fans, then Use Selected Fan", count)
end

-- L10.
function RESULTS.find_failed()
	return "Find Fans could not send its query on this controller"
end

-- L11.
function RESULTS.reboot_sent(f)
	return "Reboot sent to the fan's Wi-Fi module" .. clause("at", f.at, f.now)
end

-- L12.
function RESULTS.reboot_offline()
	return "Reboot not sent: the fan is not answering (power it off for 10 s)"
end

-- L13.
function RESULTS.reboot_refused(f)
	return string.format("Reboot not sent: no fan of this device answers at %s", val(f.address))
end

-- L20.
function RESULTS.reboot_pending(f)
	return "Reboot already sent" .. clause("at", f.at, f.now) .. "; waiting for the fan"
end

-- L14.
function RESULTS.away_off()
	return "Away mode turned off (the Modern Forms app can turn it on again)"
end

-- L15.
function RESULTS.away_already()
	return "Away mode is already off"
end

-- L16.
function RESULTS.learning_off()
	return "Adaptive learning turned off (the Modern Forms app can turn it on)"
end

-- L17.
function RESULTS.learning_already()
	return "Adaptive learning is already off"
end

-- L18.
function RESULTS.not_answering()
	return "Not changed: the fan is not answering"
end

-- L19: the answer still shows the automation on. Without `which` the text
-- stays true without naming it.
function RESULTS.not_taken(f)
	local names = { away = "away mode", learning = "adaptive learning" }
	return "The fan did not take it; it still reports " .. (names[f.which] or "it") .. " on"
end

-- L21.
function RESULTS.not_picked(f)
	return string.format("The fan at %s is not the one picked; Find Fans again", val(f.address))
end

-- Last Action text for a result key (texts.RESULT_KEYS) and its args (see
-- `fields`). "" for a key it does not know.
function texts.result(key, args)
	local build = RESULTS[key]
	if not build then
		return ""
	end
	return build(fields(args))
end

-- List rows ----------------------------------------------------------------------

-- "Fan Speed 3" from the connection's "Fan Speed 3 Button Link".
local function link_label(name)
	local label = trim(scalar(name))
	label = trim((label:gsub("%s*Button Link$", "")))
	if label == "" then
		return "?"
	end
	return label
end

-- Keypad Links items (section 7.3): "5 of 12 links bound", then one per
-- bound keypad, "Fan Speed 3: Example Keypad (456)". `rows` is one record per
-- link and keypad, { link_name, keypad_name, device_id } (or that order as an
-- array), in the order to show; several keypads on one link are several rows
-- and one bound link. A keypad the driver cannot name shows as "device 456".
-- `total` defaults to texts.LINK_COUNT.
function texts.keypad_links(rows, total)
	local items, seen, bound = {}, {}, 0
	for _, row in ipairs(type(rows) == "table" and rows or {}) do
		if type(row) == "table" then
			local link = link_label(row.link_name or row[1])
			if not seen[link] then
				seen[link] = true
				bound = bound + 1
			end
			local name = trim(scalar(row.keypad_name or row[2]))
			local id = val(row.device_id or row[3])
			local text = string.format("%s: device %s", link, id)
			if name ~= "" then
				text = string.format("%s: %s (%s)", link, name, id)
			end
			items[#items + 1] = texts.list_item(text)
		end
	end
	local of = whole(total) or tostring(texts.LINK_COUNT)
	table.insert(items, 1, string.format("%d of %s links bound", bound, of))
	return items
end

-- Found Fans items (section 7.3): "MF_Fan_005301 at 10.0.2.151", with
-- " (this device's fan)" for the one whose MAC is the pinned fan's; at most
-- texts.MAX_FOUND. `list` is discovery's, { instance, address, mac, ... }
-- each; `pin` the pinned identity ({ mac } or { client_id }), or nil.
function texts.found_fans(list, pin)
	local items = {}
	if type(list) ~= "table" then
		return items
	end
	local pinned = type(pin) == "table" and (mac_key(pin.mac) or mac_key(pin.client_id)) or nil
	for _, fan in ipairs(list) do
		if #items >= texts.MAX_FOUND then
			break
		end
		if type(fan) == "table" then
			local text = scalar(fan.instance)
			if text == "" then
				text = "fan"
			end
			if scalar(fan.address) ~= "" then
				text = text .. " at " .. scalar(fan.address)
			end
			if pinned and mac_key(fan.mac) == pinned then
				text = text .. " (this device's fan)"
			end
			items[#items + 1] = texts.list_item(text)
		end
	end
	return items
end

return texts
