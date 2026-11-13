-- fan/texts.lua: every string the owner can read, in one place (v1 contract
-- section 9.6; the wording is section 7's, and fan-name-design 2.3 adds the
-- fan's name and the rename texts). Pure: plain tables in, strings out, no
-- Director calls, so the manual and the specs can pin every word. The one
-- module it reads is fan.names, the table of fan types and their names, which
-- is pure as well. Nothing else in the driver builds a Status, a Last Action
-- or a property text.
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
--     write it, U+2026, which ends a text texts.clean cut, and the UTF-8 a
--     name or a fan's answer holds. What the owner typed into Fan Address,
--     and the instance name another fan announces (Found Fans, L32), are
--     echoed cut, with every byte outside printable ASCII shown as "?"; so is
--     the Breeze strength given (L34). Item names Director gives (L22, L23,
--     L36, L37, L41, L46) are printed as they are, cut only between
--     characters.
--   * Text a fan sends (#214: the client id, the fan and light types, the
--     firmware versions, an address) and the names a Last Action line holds
--     go through texts.clean before they reach a row: no control character,
--     no invalid UTF-8, at most TEXT_MAX characters each; and every row that
--     holds them is cut at ROW_CUT, where Composer cuts. The characters <, &
--     and > stay: UpdateProperty and UpdatePropertyList take plain text, and
--     the SDK documents C4:XmlEscapeString only for XML a driver builds
--     itself (API 24_properties/_5, _6; 9_helper/_20). What no escaping can
--     carry is a character XML 1.0 forbids (NUL, the other C0 controls, U+FFFE
--     and U+FFFF), and clean leaves none.
--   * Rows stay under about 70 characters (Composer clips near 75, ECC F29).
--     Two texts can pass that: Fan Automations with every item active (84
--     characters; the contract gives no shorter form) and S9 with a
--     15-character address and a date, which reaches exactly 75 where section
--     7.1 says it stays under 75. A Found Fans item may reach 72, the limit
--     auto-discovery-design 5 sets for items.

-- Fan Model (fan-name-design N3) and the Found Fans item of this device's fan
-- (auto-discovery-design 3.2) are the only texts that read the name table.
local names = require("fan.names")

local texts = {}

-- The oldest controller OS the light is known to work on (V3, section 2.1).
texts.MIN_OS = "3.3.0"

-- Links the driver declares: ten fan links (300 to 308, and 311 Fan Breeze
-- of breeze-design BZ4) and three light links (200 to 202), section 2.4. "5
-- of 13 links bound" counts against it.
texts.LINK_COUNT = 13

-- Found Fans shows at most this many item rows under its summary; with more
-- fans the last of them is the overflow row (auto-discovery-design 3).
texts.MAX_FOUND = 16

-- Phases texts.status understands (section 6.1; the names are the ones
-- m:want's refusals use, section 9.5). "invalid" and "invalid address" are
-- the S3 case spelt out, for a model that keeps it apart from "unset".
texts.PHASES = { "unset", "waiting", "online", "offline", "rebooting", "foreign", "gen4", "notfan" }

-- Keys texts.result understands, in the contract's order (section 9.6, less
-- L8 to L10, which went with the Find Fans action: auto-discovery-design 5),
-- then the eight answers of the rename job, L22 to L29 (fan-name-design 2.3),
-- then the address follower's two, L30 and L31 (address-follow-design 2.4),
-- then the waiting pick, L32 (auto-discovery-design 5), then Breeze's eight,
-- L33 to L40 (breeze-design section 5; "Breeze fan" since section 11), and
-- L41, the 1.2 switch still bound (breeze-design BF-D10), then L42, the Breeze
-- LED animation without Per speed (breeze-leds-design BL-D3, section 2), and the
-- rest in the order they came; L46 (#214) is the Breeze fan added but not bound.
texts.RESULT_KEYS = {
	"learned", "moved", "now_using", "already", "no_answer", "not_a_fan", "nothing_to_use",
	"reboot_sent", "reboot_offline", "reboot_refused", "reboot_pending",
	"away_off", "away_already", "learning_off", "learning_already", "not_answering", "not_taken", "not_picked",
	"name_renamed", "name_same", "name_unknown", "name_no_type", "name_no_ids", "name_unconfirmed", "name_no_pin",
	"name_busy", "followed", "follow_refused", "picked_wait",
	"breeze_unavailable", "breeze_strength", "breeze_refused", "breeze_switch_added", "breeze_switch_exists",
	"breeze_switch_no_breeze", "breeze_switch_no_fan", "breeze_switch_failed", "breeze_old_switch",
	"breeze_leds_need_per_speed",
	"speed_leds_need_per_speed",
	"keypad_leds_shown",
	"keypad_leds_hidden",
	"breeze_fan_not_connected",
}

-- S3 shows the typed text cut to this many characters (section 7.1).
local TYPED_CUT = 24

-- L24 shows the fan type cut to this many characters (ECR 5.5), so the line
-- stays at 60 whatever the fan sent.
local TYPE_CUT = 14

-- A Found Fans item shows the instance cut at its start to this many
-- characters, so the last six MAC digits it ends in stay (auto-discovery-design
-- 3.2); an item stays at or under ITEM_MAX, past which the product name goes.
local INSTANCE_CUT = 25
local ITEM_MAX = 72

-- Last Action rows stay at or under this many characters (section 7, ECC F29);
-- L32 cuts the instance at its start to fit.
local ROW_MAX = 70

-- A time is shown with its date once it is older than this (section 7).
local DAY_S = 86400

-- U+201A, the "comma" of a list item (as the Hue drivers write it).
local LOW_QUOTE = "\226\128\154"

-- #214: fan-supplied text (an id, a type, a version, an address) and a name in
-- a Last Action line are cut to this many characters by texts.clean, and a row
-- that holds them to ROW_CUT, the width Composer shows (ECC F29).
texts.TEXT_MAX = 64
texts.ROW_CUT = 75

-- U+2026, the end of a text texts.clean cut.
local ELLIPSIS = "\226\128\166"

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

-- Linear however the text is built (review of #37: the pattern form is
-- quadratic on long inner blanks, and a fan's answer is not ours to trust).
local function trim(s)
	local first = s:find("%S")
	if not first then
		return ""
	end
	local last = #s
	while last > first and s:find("^%s", last) do
		last = last - 1
	end
	return s:sub(first, last)
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

-- The length in bytes of the valid UTF-8 character at `i` of `s`, whose first
-- byte `b` is 128 or over, by RFC 3629 (no overlong form, no surrogate,
-- nothing past U+10FFFF); nil when the bytes there are not one.
local function utf8_len(s, i, b)
	local need, lo, hi
	if b >= 194 and b <= 223 then
		need, lo, hi = 2, 128, 191
	elseif b == 224 then
		need, lo, hi = 3, 160, 191
	elseif b == 237 then
		need, lo, hi = 3, 128, 159
	elseif b >= 225 and b <= 239 then
		need, lo, hi = 3, 128, 191
	elseif b == 240 then
		need, lo, hi = 4, 144, 191
	elseif b >= 241 and b <= 243 then
		need, lo, hi = 4, 128, 191
	elseif b == 244 then
		need, lo, hi = 4, 128, 143
	else
		return nil
	end
	local second = s:byte(i + 1)
	if not second or second < lo or second > hi then
		return nil
	end
	for j = i + 2, i + need - 1 do
		local c = s:byte(j)
		if not c or c < 128 or c > 191 then
			return nil
		end
	end
	return need
end

-- Valid UTF-8 characters that clean does not keep: the C1 controls, the line
-- and paragraph separators and the bidirectional controls (which break or
-- reorder what follows them) become a space; U+FFFE and U+FFFF, which are no
-- characters (XML 1.0 forbids them), become "?".
local function replaced(ch)
	local b1, b2, b3 = ch:byte(1, 3)
	if b1 == 194 and b2 <= 159 then
		return " " -- U+0080 to U+009F
	elseif b1 == 226 and b2 == 128 and b3 >= 168 and b3 <= 174 then
		return " " -- U+2028, U+2029, U+202A to U+202E
	elseif b1 == 226 and b2 == 129 and b3 >= 166 and b3 <= 169 then
		return " " -- U+2066 to U+2069
	elseif b1 == 239 and b2 == 191 and (b3 == 190 or b3 == 191) then
		return "?" -- U+FFFE, U+FFFF
	end
	return nil
end

-- texts.clean(x, max) -> string (#214): text from outside the driver (a fan's
-- answer, a name) made safe for a row, a list item, the store or a log line.
--   * A control character (NUL, the other C0 controls, DEL, the C1 controls,
--     and the separators and bidirectional controls above) becomes a space.
--   * Printable ASCII and valid UTF-8 stay as they are, < & > included.
--   * Every byte that is not part of a valid UTF-8 character becomes "?".
--   * Past `max` characters (default TEXT_MAX) the text is cut: the first
--     max - 1 characters and U+2026, so the result is never longer than
--     `max` characters. A max below 1 gives "".
-- Blanks are left as they are (the callers trim). A whole number gives its
-- digits; anything that is not a string or a whole number gives "". Linear:
-- at most 4 x (max + 1) bytes are read, however long the text is.
function texts.clean(x, max)
	local s = scalar(x)
	local cap = tonumber(max)
	if cap == nil or cap ~= cap then
		cap = texts.TEXT_MAX
	end
	cap = math.floor(cap)
	if cap < 1 or s == "" then
		return ""
	end
	-- Each character takes 1 to 4 bytes, so the first cap + 1 of them lie in
	-- these bytes, and whatever was cut off is past the cut anyway.
	if #s > 4 * (cap + 1) then
		s = s:sub(1, 4 * (cap + 1))
	end
	local out, count, i, n = {}, 0, 1, #s
	while i <= n and count < cap do
		local _, run_end = s:find("^[ -~]+", i)
		if run_end then
			local take = math.min(run_end - i + 1, cap - count)
			out[#out + 1] = s:sub(i, i + take - 1)
			count, i = count + take, i + take
		else
			local b = s:byte(i)
			local len = b >= 128 and utf8_len(s, i, b) or nil
			local piece
			if len then
				piece = s:sub(i, i + len - 1)
				piece = replaced(piece) or piece
			else
				len = 1
				piece = (b < 32 or b == 127) and " " or "?"
			end
			out[#out + 1] = piece
			count, i = count + 1, i + len
		end
	end
	if i <= n then
		-- More is left: the last character kept gives way to the marker.
		local last = out[#out]
		if #last > 1 and last:find("^[ -~]+$") then
			out[#out] = last:sub(1, -2)
		else
			out[#out] = nil
		end
		out[#out + 1] = ELLIPSIS
	end
	return table.concat(out)
end

-- Fan-supplied text for a row (#214): blanks trimmed, then texts.clean to
-- TEXT_MAX characters, then trimmed again (a control character at an end is a
-- blank by then). "" for none.
local function fan_text(x)
	return trim(texts.clean(trim(scalar(x)), texts.TEXT_MAX))
end

-- A whole row that holds fan-supplied text, cut where Composer cuts.
local function cut_row(text)
	return texts.clean(text, texts.ROW_CUT)
end

-- Text a fan's multicast DNS answer carries (its instance name, its address),
-- as Found Fans and L32 show it: control characters dropped (as
-- texts.list_item drops them), every other byte outside printable ASCII shown
-- as "?", blanks trimmed, then, given `cut`, cut at its START to that many
-- characters with no marker, so the end of an instance that carries the last
-- six MAC digits stays (auto-discovery-design 3.2), and trimmed again when
-- the cut left a blank in front. Every byte is one character by then, so the
-- cut never splits one. "" for none.
local function announced(x, cut)
	local text = trim(ascii((scalar(x):gsub("%c", ""))))
	if cut and #text > cut then
		text = trim(text:sub(-cut))
	end
	return text
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
-- The client id is the fan's own text: cleaned and cut (#214).
function texts.fan_id(pin)
	if type(pin) ~= "table" then
		return ""
	end
	local id = fan_text(pin.client_id)
	if id == "" then
		return ""
	end
	local mac = texts.mac(pin.mac)
	if mac == "" then
		return id
	end
	return cut_row(string.format("%s (MAC %s)", id, mac))
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

-- The name fan.names gives a fan type, or "" for none: no type, a type the
-- table does not list (an exact match only, N1) or a lookup that fails. A
-- broken table costs the name and nothing else, so this never raises.
local function maker_name(fan_type)
	if fan_type == "" then
		return ""
	end
	local ok, name = pcall(names.lookup, fan_type)
	if ok and type(name) == "string" then
		return fan_text(name)
	end
	return ""
end

-- Fan Model: "Gen 3, Aviator 5 (1811-5-54), light kit F4IN-120V-R1-30, Breeze"
-- when fan.names has a name for the type (fan-name-design N3: the name, then
-- the type in parentheses so the table stays checkable by eye), and for a
-- type it has none for the older "Gen 3, fan 1811-5-54, light kit
-- F4IN-120V-R1-30, Breeze", plus the other forms of section 7.3. `pin`
-- carries the generation, `info` the types ({ fan_type, light_type,
-- has_light, has_wind }). "" until the info is known.
--
-- Length (section 7: rows under about 70): the house fan's named row is 63
-- characters. Over the 75 entries of the research table (FNR Appendix B) the
-- longest row is 69, "Gen 1/2, Size Matters 65 (2403-65), light kit
-- F4IN-120V-R1-30, Breeze", and a 15-character name (the longest in that
-- table) with the house's type on Gen 3 is 69 too. So no shortened form is
-- needed, as Fan Automations needs one; a name longer than the table's, or a
-- longer kit code, would have to bring one.
--
-- #214: the type and the kit are the fan's own text, each cleaned and cut to
-- TEXT_MAX characters, and the row is cut at ROW_CUT.
function texts.fan_model(pin, info, has_wind)
	if type(info) ~= "table" then
		return ""
	end
	local generation = type(pin) == "table" and pin.generation or nil
	-- The type that was looked up is the type that is shown, blanks trimmed.
	local fan_type = fan_text(info.fan_type)
	local fan = "fan " .. val(fan_type)
	local name = maker_name(fan_type)
	if name ~= "" then
		fan = string.format("%s (%s)", name, fan_type)
	end
	local kit = fan_text(info.light_type)
	local light = "no light kit"
	if kit ~= "" and info.has_light ~= false then
		light = "light kit " .. kit
	end
	local out = string.format("Gen %s, %s, %s", gen_label(generation), fan, light)
	if has_wind == nil then
		has_wind = info.has_wind
	end
	if has_wind == true then
		out = out .. ", Breeze"
	end
	return cut_row(out)
end

-- Firmware: "02.00.0052 (motor 03.00.0000) since 2026-10-27", and after a
-- change "02.00.0060 (motor 03.00.0000) since 2026-11-02, was 02.00.0052"
-- (section 7.3). `info` = { firmware, mcu_firmware, firmware_since,
-- firmware_was }. "" until a firmware is known. #214: each version is the
-- fan's own text, cleaned and cut to TEXT_MAX characters; the row is cut at
-- ROW_CUT.
function texts.firmware(info)
	if type(info) ~= "table" then
		return ""
	end
	local firmware = fan_text(info.firmware)
	if firmware == "" then
		return ""
	end
	local out = firmware
	local motor = fan_text(info.mcu_firmware)
	if motor ~= "" then
		out = out .. " (motor " .. motor .. ")"
	end
	local since = fan_text(date_text(info.firmware_since))
	if since ~= "" then
		out = out .. " since " .. since
	end
	local was = fan_text(info.firmware_was)
	if was ~= "" then
		out = out .. ", was " .. was
	end
	return cut_row(out)
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

-- Breeze's strength as S5 shows it: "1" to "3", nil for anything else (the
-- fan's windSpeed, read by the wire with the range handling of the speed).
local function strength_of(x)
	local n = tonumber(x)
	if n and n == math.floor(n) and n >= 1 and n <= 3 then
		return string.format("%d", n)
	end
	return nil
end

-- S5's fan part, by the motor's three states (breeze-design BF-D1, BF-D2).
-- Breeze mode (`fan_on` and `wind` both true, "Breeze blows" of BZ1) is
-- "Breeze 2", the strength alone, since the fan speed does not matter then
-- ("Breeze" when the strength is unknown or not 1 to 3). Otherwise "fan speed
-- 3", "fan off" or "fan unknown", then " reverse" when it applies, then the
-- raw `wind` flag: " Breeze set" while `wind` is set and the fan is off, and
-- " Breeze" while the fan's on/off is unknown. A fan without Breeze (`wind`
-- nil) reads as in 1.2.
local function fan_part(st)
	if st.fan_on == true and st.wind == true then
		local strength = strength_of(st.wind_speed)
		return "Breeze" .. (strength and (" " .. strength) or "")
	end
	local out = "fan unknown"
	if st.fan_on == true then
		local speed = whole(st.speed)
		out = speed and ("fan speed " .. speed) or "fan on"
	elseif st.fan_on == false then
		out = "fan off"
	end
	if st.direction == "reverse" then
		out = out .. " reverse"
	end
	if st.wind == true then
		out = out .. (st.fan_on == false and " Breeze set" or " Breeze")
	end
	return out
end

-- A level of 0 to 100 as text, rounded half up; nil for anything else, so the
-- two-level form of the light part below only ever shows sane levels.
local function percent(x)
	local s = whole(x)
	local n = tonumber(s)
	if n and n >= 0 and n <= 100 then
		return s, n
	end
	return nil
end

-- The Light Min On that changes the light part: a number that rounds half up
-- to 2 to 99 (min-on-design MO-D1, MO-D10); nil for nil, 0, 1 and anything
-- the light would refuse, which all leave the levels as they are.
local function min_on_of(x)
	local n = tonumber(x)
	if not n or n ~= n or n >= BIG or n <= -BIG then
		return nil
	end
	n = math.floor(n + 0.5)
	if n >= 2 and n <= 99 then
		return n
	end
	return nil
end

-- S5's light part: "light off", "light 40 %", or "no light kit". With a Light
-- Min On above 1 and the Control4 level known (min-on-design MO-D11, edge
-- cases RP1), a light that is on shows the Control4 level first and the fan's
-- after it, both even when they are equal: "light 40 % (fan 52)", and with
-- the fan's level below the Min On "light 1 % (fan 5, below Min On)". A Min On
-- of nil, 0 or 1, or no Control4 level, gives the text of release 1.5
-- exactly, which shows the fan's level. The longest S5 row this makes is 68
-- characters ("Online: fan off reverse Breeze set, light 1 % (fan 98, below Min
-- On)"), and 70 for a pair the light never reports (100 % with a fan level
-- below the Min On): within the 70 of the file's header either way.
local function light_part(st, has_light, min_on, light_level)
	if has_light == false then
		return "no light kit"
	end
	if st.light_on == true then
		local level = whole(st.level)
		local m = min_on_of(min_on)
		local shown = percent(light_level)
		local fan, f = percent(st.level)
		if m and shown and fan then
			local below = f < m and ", below Min On" or ""
			return "light " .. shown .. " % (fan " .. fan .. below .. ")"
		end
		return level and ("light " .. level .. " %") or "light on"
	elseif st.light_on == false then
		return "light off"
	end
	return "light unknown"
end

local STATUS = {}

-- The address a status names (S4, S7 to S9, S11 to S13), "?" for none. It may
-- be one a fan announced, so it is cleaned and cut (#214).
local function where(v)
	return val(fan_text(v.address))
end

-- S1, S2, S3: no usable address. The text the owner typed is S3's; S1 when
-- the Found Fans list is failing (no search possible on this controller), S2
-- otherwise (auto-discovery-design 5: the list fills by itself).
function STATUS.unset(v)
	local typed = ascii(trim(scalar(v.typed)))
	if typed ~= "" then
		return string.format('Fan Address "%s" is not an IPv4 address', typed:sub(1, TYPED_CUT))
	end
	if v.failing == true then
		return "Not set up: enter the fan's address in Fan Address"
	end
	return "Not set up: pick a fan in Found Fans, or enter Fan Address"
end
STATUS.invalid = STATUS.unset
STATUS["invalid address"] = STATUS.unset

-- S4, or S14 in its place.
function STATUS.waiting(v)
	return old_os_status(v) or string.format("Waiting for the fan at %s", where(v))
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
	return string.format("Online: %s, %s", fan_part(st), light_part(st, v.has_light, v.min_on, v.light_level))
end

-- S7, S8, S9: offline after timeouts and refusals, or after answers that
-- held nothing usable; with or without a state to show.
function STATUS.offline(v)
	local since = clause("since", v.since, v.now)
	local tail = v.known == true and "; showing last state" or "; state unknown"
	if v.failure == "data" then
		return string.format("No usable answer from %s%s%s", where(v), since, tail)
	end
	return string.format("Not answering at %s%s%s", where(v), since, tail)
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
	return string.format("Another fan (%s) answers at %s; nothing is sent", texts.suffix(v.other), where(v))
end

-- S12.
function STATUS.gen4(v)
	return string.format("%s is a Gen 4 fan; this driver controls Gen 1 to 3 only", where(v))
end

-- S13.
function STATUS.notfan(v)
	return string.format("%s answers, but not as a Modern Forms fan; nothing is sent", where(v))
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
--   st         the state record (S5): fan_on, speed, direction, wind, wind_speed,
--              light_on, level
--   has_light  false for "no light kit"
--   min_on     the light's Min On in use (S5; min-on-design MO-D11): above 1,
--              with light_level, the light part shows both levels
--   light_level the Control4 level the light reports, 0 to 100 (S5), from
--              light:c4_level(st); nil gives the fan's level alone
--   has_wind   accepted and unused: Breeze is shown from st.wind and st.fan_on
--   missing    the key a needed field is missing as (S6): "fanSpeed" and so on
--   os         the controller's version, text or C4:GetVersionInfo()'s table (S14)
--   failing    the Found Fans list is failing (S1 against S2, auto-discovery-design 5)
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
	return cut_row(build(v))
end

-- Last Action ---------------------------------------------------------------

-- The fields a result text reads, from args and, for what args lacks, from
-- args.pin (the model may hand over the identity whole):
--   client_id, generation, address   the fan (L1 to L4, L21, ...)
--   was                              the previous client id, or a pin (L3);
--                                    the previous address (L30)
--   instance                         the picked fan's announced name (L32);
--                                    never read from a pin
--   at, now                          seconds: when the reboot was sent (L11, L20)
--   which                            "away" or "learning" (L19)
--   fan, light                       the two item names the rename job set or
--                                    found (L22, L23); never read from a pin
--   fan_type                         the model the name table lacks (L24)
--   strength                         the Breeze strength as given (L34)
--   why                              the model's refusal reason (L35)
--   name                             the Breeze fan's item name (L36, L37,
--                                    L46), or the 1.2 switch's (L41)
-- The last three are never read from a pin. #214: the ids, the addresses and
-- the item names are cleaned and cut to TEXT_MAX characters here (texts.clean),
-- and texts.result cuts the whole line at ROW_CUT.
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
	return {
		client_id = fan_text(pick("client_id")),
		generation = pick("generation"),
		address = fan_text(pick("address")),
		was = fan_text(was),
		instance = a.instance,
		at = a.at,
		now = a.now,
		which = a.which,
		fan = fan_text(a.fan),
		light = fan_text(a.light),
		fan_type = scalar(a.fan_type),
		strength = a.strength,
		why = a.why,
		name = a.name,
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

-- L30: the follower found the pinned fan at a new address (address-follow-design F6).
function RESULTS.followed(f)
	if f.was ~= "" then
		return string.format("Followed fan %s to %s (was %s)", val(f.client_id), val(f.address), f.was)
	end
	return string.format("Followed fan %s to %s", val(f.client_id), val(f.address))
end

-- L31: the flap guard refused a fourth follow in an hour (F6), said once.
function RESULTS.follow_refused(f)
	return string.format("Fan %s moved 3 times in an hour; not following", val(f.client_id))
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

-- L7: the pick is a way too (the list fills by itself, auto-discovery-design
-- 5). L8 to L10, the Find Fans action's answers, went with the action.
function RESULTS.nothing_to_use()
	return "Nothing to use: pick a fan in Found Fans, or enter Fan Address"
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
	local automation = { away = "away mode", learning = "adaptive learning" }
	return "The fan did not take it; it still reports " .. (automation[f.which] or "it") .. " on"
end

-- L21: the driver searches again by itself (auto-discovery-design 4, step 6).
function RESULTS.not_picked(f)
	return string.format("The fan at %s is not the one picked; searching again", val(f.address))
end

-- L32: a pick of another fan on a device that has one waits for Use Selected
-- Fan (auto-discovery-design 4, step 4). The instance is cut at its start so
-- the line stays at or under ROW_MAX characters: 23 of a 25-character one.
local PICKED_TAIL = ": click Use Selected Fan to switch to it"

function RESULTS.picked_wait(f)
	local room = ROW_MAX - #"Picked " - #PICKED_TAIL
	local shown = announced(f.instance, room)
	if shown == "" then
		shown = "?"
	end
	return "Picked " .. shown .. PICKED_TAIL
end

-- L22 to L29: what Name Items After Fan answers (fan-name-design 2.3, ECR
-- 5.5; the keys are the rename job's outcomes under the action's names).
-- L22 and L23 print the two names as the job hands them over, "Sample" and
-- "Sample Light", so the item names appear exactly as Composer shows them.

-- L22: the action renamed.
function RESULTS.name_renamed(f)
	return string.format("Items named %s and %s", val(f.fan), val(f.light))
end

-- L23: nothing to change.
function RESULTS.name_same(f)
	return string.format("Items already named %s and %s", val(f.fan), val(f.light))
end

-- L24: the table has no name for the model. What the fan sent is echoed cut
-- to TYPE_CUT characters with no marker, every byte outside printable ASCII
-- shown as "?" (as S3 does for the typed text).
function RESULTS.name_unknown(f)
	local shown = ascii(trim(f.fan_type)):sub(1, TYPE_CUT)
	if shown == "" then
		shown = "?"
	end
	return string.format("No name known for fan type %s; items not renamed", shown)
end

-- L25: the fan type is not read yet.
function RESULTS.name_no_type()
	return "Fan type not read yet; try again in a moment"
end

-- L26: the items' ids were not found.
function RESULTS.name_no_ids()
	return "Items not renamed: this device's items were not found"
end

-- L27: Director did not confirm the new names.
function RESULTS.name_unconfirmed()
	return "Rename not confirmed; check the item names in Composer"
end

-- L28: no fan is pinned.
function RESULTS.name_no_pin()
	return "Nothing to name the items after: no fan is set up yet"
end

-- L29: a rename is already pending.
function RESULTS.name_busy()
	return "Naming in progress; try again in a moment"
end

-- L33 to L41: Breeze (breeze-design section 5, BZ10, BZ11; section 11,
-- BF-D10: the action is Add Breeze Fan, and L41 is new).

-- L34 shows the strength it was given cut to this many characters; L35 the
-- key a "no <key>" refusal names cut to this many.
local STRENGTH_CUT = 8
local KEY_CUT = 16

-- What a command was given (L34): a string with its control characters
-- dropped, every other byte outside printable ASCII shown as "?" and blanks
-- trimmed; a number as written, whole or not, below 1e15 (which "%.15g"
-- writes without an exponent); cut to `cut` characters with no marker. ""
-- for anything else.
local function given(x, cut)
	local text = ""
	if type(x) == "string" then
		text = trim(ascii((x:gsub("%c", ""))))
	elseif type(x) == "number" and x == x and x > -1e15 and x < 1e15 then
		text = string.format("%.15g", x)
	end
	return text:sub(1, cut)
end

-- An item name as Director gives it (L36, L37, L41, L46): control characters
-- dropped, blanks trimmed, and past `cut` bytes cut with no marker, never
-- inside a UTF-8 character (a name may hold any, and L22 prints names as they
-- are). Then texts.clean (#214): a byte of no valid UTF-8 character is "?",
-- and a C1 or bidirectional control a blank; the text is `cut` bytes at most
-- by then, so clean cuts nothing. "?" for none.
local function item_name(x, cut)
	local text = trim((scalar(x):gsub("%c", "")))
	if #text > cut then
		text = text:sub(1, cut)
		-- A lead byte whose character the cut left short goes, with what follows it.
		local lead = text:find("[\192-\255][\128-\191]*$")
		if lead then
			local byte = text:byte(lead)
			local need = (byte >= 240 and 4) or (byte >= 224 and 3) or 2
			if #text - lead + 1 < need then
				text = text:sub(1, lead - 1)
			end
		end
		text = trim(text)
	end
	text = trim(texts.clean(text, cut))
	if text == "" then
		return "?"
	end
	return text
end

-- L33: a Breeze command or a press on link 311, and the fan reports no Breeze.
function RESULTS.breeze_unavailable()
	return "Breeze not available: this fan reports no Breeze"
end

-- L34: Set Breeze Strength with a value that is not 1, 2 or 3.
function RESULTS.breeze_strength(f)
	local shown = given(f.strength, STRENGTH_CUT)
	if shown == "" then
		shown = "?"
	end
	return "Breeze strength " .. shown .. " refused: use 1, 2 or 3"
end

-- L35: a Breeze command the model refused for another reason. No proxy
-- command writes a Last Action line for its refusals (they are logged), so
-- there is no line to reuse: these are the model's reasons (model.lua's
-- refusal() and validate(), breeze-design section 2) in words, with the
-- wording of the rows that already name them (L28, S3, S11 to S13, S10, S6).
-- The model's own Breeze reasons give L33 and L34; any other reason is the
-- bare "Breeze not sent".
local BREEZE_REFUSALS = {
	unset = "no fan is set up yet",
	["invalid address"] = "Fan Address is not an IPv4 address",
	foreign = "another fan answers at Fan Address",
	gen4 = "a Gen 4 fan answers at Fan Address",
	notfan = "Fan Address answers, but not as a fan",
	rebooting = "the fan's Wi-Fi module is rebooting",
	range = "the value is out of range",
}

function RESULTS.breeze_refused(f)
	local why = type(f.why) == "string" and f.why or ""
	if why == "no_breeze" then
		return RESULTS.breeze_unavailable(f)
	elseif why == "breeze_range" then
		return RESULTS.breeze_strength(f)
	end
	local words = BREEZE_REFUSALS[why]
	local key = why:match("^no (%a+)$")
	if not words and key then
		words = "the fan reports no " .. key:sub(1, KEY_CUT)
	end
	if not words then
		return "Breeze not sent"
	end
	return "Breeze not sent: " .. words
end

-- L36, L37 and L41 name the device after a fixed start, the name cut so the
-- line stays at ROW_MAX: 52 characters of it for L36, 35 for L37, 34 for L41.
local FAN_ADDED = "Breeze fan added: "
local FAN_EXISTS = "A Breeze fan is already connected: "
local OLD_SWITCH = "Delete the old Breeze switch first: "

-- L36: Add Breeze Fan added and bound the Breeze fan (BZ11, BF-D10).
function RESULTS.breeze_switch_added(f)
	return FAN_ADDED .. item_name(f.name, ROW_MAX - #FAN_ADDED)
end

-- L37: a Breeze fan is already bound to this fan device; named.
function RESULTS.breeze_switch_exists(f)
	return FAN_EXISTS .. item_name(f.name, ROW_MAX - #FAN_EXISTS)
end

-- L38: the fan reports no Breeze (BZ10).
function RESULTS.breeze_switch_no_breeze()
	return "No Breeze fan added: this fan reports no Breeze"
end

-- L39: no fan is pinned yet.
function RESULTS.breeze_switch_no_fan()
	return "No Breeze fan added: set up the fan first"
end

-- L40: Composer refused the new device or its binding (the package is not
-- installed, most likely).
function RESULTS.breeze_switch_failed()
	return "No Breeze fan added: install modernforms_breeze_fan.c4z first"
end

-- L41: the companion bound to this fan device is 1.2's light-type Breeze
-- switch (BF-D10), which has to go before the Breeze fan is added; named.
function RESULTS.breeze_old_switch(f)
	return OLD_SWITCH .. item_name(f.name, ROW_MAX - #OLD_SWITCH)
end

-- L46 (#214, S2-1): Add Breeze Fan added the device, but binding it to this
-- fan device failed; named, the name cut so the line stays at ROW_MAX (18
-- characters of it). The owner connects it in Connections, then clicks Add
-- Breeze Fan again, which finds it connected (L37) or binds it.
local NOT_CONNECTED = ", not connected: use Connections, then retry"

function RESULTS.breeze_fan_not_connected(f)
	return "Added " .. item_name(f.name, ROW_MAX - #"Added " - #NOT_CONNECTED) .. NOT_CONNECTED
end

-- L42: Breeze LED Animation is Gusts while Speed LED Colors is not Per speed
-- (breeze-leds-design BL-D3, section 2): the driver owns no colours to put back.
function RESULTS.breeze_leds_need_per_speed()
	return "Breeze LEDs need Speed LED Colors set to Per speed"
end

-- L44 and L45 (keypad-leds-visibility-design KL-D7): a binding showed or hid the
-- keypad LED rows.
function RESULTS.keypad_leds_shown()
	return "Keypad LED settings shown: a button is on a Fan Speed link"
end

function RESULTS.keypad_leds_hidden()
	return "Keypad LED settings hidden: no button on a Fan Speed link"
end

-- L43 (speed-leds-design SL-D9): the chase is on but the colours are the keypad's own.
function RESULTS.speed_leds_need_per_speed()
	return "LED chase needs Speed LED Colors set to Per speed"
end

-- Last Action text for a result key (texts.RESULT_KEYS) and its args (see
-- `fields`). "" for a key it does not know. Cut at ROW_CUT (#214).
function texts.result(key, args)
	local build = RESULTS[key]
	if not build then
		return ""
	end
	return cut_row(build(fields(args)))
end

-- The tail the second write of a Use Selected Fan line carries once the
-- guarded rename has ended (fan-name-design 2.3, ECR 5.5), by the job's
-- outcome. An outcome with nothing to add gets "": "same" (the names already
-- matched), "no_pin" and anything the job does not name; "busy" (a rename
-- already running) is "; not renamed" (ECR RC19, review of #37). L2 to L4
-- plus the longest tail stay under 70 characters: L3 "(was ...)" is 51, so
-- 66, and 68 with two WAC_ ids.
local SUFFIXES = {
	renamed = "; items renamed",
	kept = "; names kept",
	no_name = "; not renamed",
	busy = "; not renamed",
	no_type = "; not renamed",
	no_ids = "; not renamed",
	unconfirmed = "; not renamed",
}

function texts.rename_suffix(outcome)
	if type(outcome) ~= "string" then
		return ""
	end
	return SUFFIXES[outcome] or ""
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

-- The note after Keypad Links' first row (keypad-leds-visibility-design KL-D7);
-- no comma, since the row is one item of a list.
--
-- `dark` (ambient-pause-design AP-D10, #207): true while the keypad bound to
-- Ambient Light Level (Follower) is dark and the LED animations are paused.
-- Only `true` counts, so a call without it reads as before. While the rows
-- are shown, the pause takes the place of "LED settings shown" rather than
-- following it: the rows are shown whenever it is said, and both together
-- (83 characters with "13 of 13") would pass the 75 Composer clips at, so
-- that the row would lose its end. While they are hidden no speed link is
-- bound, nothing animates and nothing can be paused: the binding hint stays.
--
-- `last` (#223, AP-D17), optional: { level = n, at_s = epoch seconds, now_s =
-- epoch seconds }, the last counted reading and the present. While paused,
-- the note names it: "; LED animations paused: the keypad read 1 at 23:51",
-- the time as texts.clock gives it (with the date once over a day old), or
-- without " at ..." when that is "". Only a whole-number level 0 to 255 with
-- a number at_s counts; any other `last` gives the text without one. Every
-- first row stays at or under ROW_CUT with every link bound ("13 of 13 links
-- bound"): when the note would pass that, "the" goes, and nothing else. Only
-- the date form needs it: "keypad read 255 at 11-12 23:51" makes 75.
local function reading_note(last)
	if type(last) ~= "table" then
		return nil
	end
	local level, at = last.level, last.at_s
	if type(level) ~= "number" or level ~= math.floor(level) or level < 0 or level > 255
		or type(at) ~= "number" then
		return nil
	end
	local now = type(last.now_s) == "number" and last.now_s or nil
	-- texts.clock is only asked about a time os.date could format.
	local when = ""
	if at == at and at ~= math.huge and at ~= -math.huge then
		when = texts.clock(at, now)
	end
	local tail = string.format("read %d", level)
	if when ~= "" then
		tail = tail .. " at " .. when
	end
	local budget = texts.ROW_CUT - #string.format("%d of %d links bound", texts.LINK_COUNT, texts.LINK_COUNT)
	local note = "; LED animations paused: the keypad " .. tail
	if #note > budget then
		note = "; LED animations paused: keypad " .. tail
	end
	return note
end

function texts.keypad_leds_note(shown, dark, last)
	if shown and dark == true then
		return reading_note(last) or "; LED animations paused: the keypad is dark"
	end
	if shown then
		return "; LED settings shown"
	end
	return "; LED settings hidden: bind a button to a Fan Speed link"
end

-- Keypad Links items (section 7.3): "5 of 13 links bound", then one per
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

-- Found Fans (auto-discovery-design 3) ------------------------------------------

-- The summary of section 3.1, the list's first item and its value while no
-- pick waits. `count` is every entry (also those past the overflow row),
-- `own` whether one of them is this device's fan. A state this does not know
-- reads as "listed".
local function found_summary(state, pinned, count, own)
	if state == "looking" then
		return "Looking for Modern Forms fans on the network..."
	elseif state == "failing" then
		return "No search possible on this controller: enter Fan Address"
	elseif state == "stopped" then
		return "Not searching while Fan Address is empty"
	end
	if not pinned then
		if count == 0 then
			return "No fan found yet: enter its address in Fan Address"
		elseif count == 1 then
			return "1 fan found: pick it and click Set to use it"
		end
		return string.format("%d fans found: pick one and click Set to use it", count)
	end
	if own then
		if count == 1 then
			return "This device's fan answered; no other fan found"
		end
		return string.format("%d fans found; this device's fan is listed first", count)
	elseif count == 0 then
		return "No fan answered the last search"
	elseif count == 1 then
		return "1 fan found; this device's fan did not answer"
	end
	return string.format("%d fans found; this device's fan did not answer", count)
end

-- One item of section 3.2, from an entry of found:entries ({ instance,
-- address, mac, own }; nothing else is read) and the product name of this
-- device's fan ("" for none):
--   <instance> at <address>      the instance cut at its start to 25
--   + " ...5302"                 after an instance that does not end in the
--                                last six hex digits of its MAC (an unknown
--                                layout): the last four, as S11 names a fan
--   + " (this device: Aviator 5)" for this device's fan when the name is
--                                known and the item stays at or under 72,
--     " (this device's fan)"     otherwise
-- What the answer lacked is left out: "fan" for no instance, no " at " part
-- for no address. With a 15-character address the longest item without the
-- name is 72 (25 + 8 + 4 + 15 + 20). Commas go through texts.list_item last,
-- so the length is counted in characters as Composer shows them.
local function found_item(entry, name)
	local text = announced(entry.instance, INSTANCE_CUT)
	if text == "" then
		text = "fan"
	end
	local key = mac_key(entry.mac)
	if key and text:lower():sub(-6) ~= key:sub(-6) then
		text = text .. " " .. texts.suffix(key)
	end
	local address = announced(entry.address)
	if address ~= "" then
		text = text .. " at " .. address
	end
	if entry.own == true then
		local mark = " (this device: " .. name .. ")"
		if name == "" or #text + #mark > ITEM_MAX then
			mark = " (this device's fan)"
		end
		text = text .. mark
	end
	return cut_row(texts.list_item(text))
end

-- Found Fans rows (auto-discovery-design 3.1 and 3.2): the summary, and the
-- item rows that follow it (the summary is not repeated in them). `view`:
--   state    "looking" | "failing" | "stopped" | "listed" (the summary's row)
--   pinned   true when a fan is pinned on this device
--   entries  found:entries(pin): { key, instance, address, mac, own } each,
--            in display order (this device's fan first)
--   info     model:info() or nil; only info.fan_type is read, for the name
-- items[i] is the row of entries[i], at most texts.MAX_FOUND rows: with more
-- entries the last row is "... and 3 more: enter the address in Fan Address"
-- in place of entries[MAX_FOUND] and after. An entry that is not a table
-- still takes its row ("fan"), so the rows and the entries stay aligned.
-- The items read the entries whatever the state says.
function texts.found_rows(view)
	local v = type(view) == "table" and view or {}
	local entries = type(v.entries) == "table" and v.entries or {}
	local count, own = 0, false
	for _, entry in ipairs(entries) do
		count = count + 1
		if type(entry) == "table" and entry.own == true then
			own = true
		end
	end
	local name = ""
	if own and type(v.info) == "table" then
		name = maker_name(trim(scalar(v.info.fan_type)))
	end
	local shown = count
	if count > texts.MAX_FOUND then
		shown = texts.MAX_FOUND - 1
	end
	local items = {}
	for i = 1, shown do
		local entry = entries[i]
		items[i] = found_item(type(entry) == "table" and entry or {}, name)
	end
	if count > shown then
		items[#items + 1] = string.format("... and %d more: enter the address in Fan Address", count - shown)
	end
	return found_summary(v.state, v.pinned == true, count, own), items
end

return texts
