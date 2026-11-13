-- fan/wire.lua: what goes onto the wire and what comes back, pure
-- (docs/v1-design.md section 9.3). Bodies are built from an allow-list with
-- string.format, keys in the order of section 3.1; answers are decoded inside
-- pcall and reduced to the fields the driver uses, so a private value of the
-- fan (V20; ECM rule 8, V6) never leaves this file. The only Director call is
-- C4:JsonDecode; nothing is logged here, the callers log.

local wire = {}

wire.PATH = "/mf"
wire.G4_PATH = "/device"
-- Director adds Host, Accept, Accept-Encoding and Connection by itself and asks
-- drivers not to overwrite them [verified: API 37_web_service/_13-urlSetTimeout].
-- The one exception is Accept-Encoding: Director's own is "deflate, gzip" (same
-- page), and the fan does not compress (M0 saw only Content-Type and
-- Content-Length come back, docs/v1-design.md), so the request asks for the body
-- as it is: "identity" (#214). That a header the driver names replaces
-- Director's own of the same name is [assumed: libcurl's custom-header rule]; the
-- transport refuses a compressed answer and counts the body's bytes either way.
-- A shared table: copy it before handing it to a transfer.
wire.HEADERS = { ["Content-Type"] = "application/json", ["Accept-Encoding"] = "identity" }
wire.QUERY_STATE = '{"queryDynamicShadowData":1}'
wire.QUERY_INFO = '{"queryStaticShadowData":1}'
wire.QUERY_G4 = '{"query":true}'
wire.REBOOT = '{"reboot":true}'

-- Small helpers ----------------------------------------------------------------

-- Linear: "^%s*(.-)%s*$" rescans a long run of inner blanks at every step (#49).
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

local function round(n)
	return math.floor(n + 0.5)
end

-- Text for a log line (#214): text that came from the fan or from a transfer
-- is cut to wire.LOG_TEXT_MAX characters, "…" ending a text that was cut, and
-- every byte outside printable ASCII (control characters, NUL, the bytes of
-- other encodings) becomes "?". Cut before the replacement, so a long text costs
-- no more than a short one. Never raises.
wire.LOG_TEXT_MAX = 200
local ELLIPSIS = "\226\128\166" -- "…" in UTF-8, one character

function wire.log_text(value, max)
	local ok, text = pcall(tostring, value)
	if not ok or type(text) ~= "string" then
		return "?"
	end
	max = tonumber(max) or wire.LOG_TEXT_MAX
	if max < 1 then
		max = 1
	end
	local cut = #text > max
	if cut then
		text = text:sub(1, max - 1)
	end
	text = text:gsub("[^ -~]", "?")
	if cut then
		text = text .. ELLIPSIS
	end
	return text
end

-- The typed readers: a value of another type (including the empty table that
-- C4:JsonDecode makes of a JSON null, API 12_json/_3-JsonDecode) is unknown,
-- never a default (ECM F3, rule 5).
local function bool_of(value)
	if type(value) == "boolean" then
		return value
	end
	return nil
end

local function string_of(value)
	if type(value) == "string" then
		return value
	end
	return nil
end

local function number_of(value)
	if type(value) == "number" and value == value and value > -math.huge and value < math.huge then
		return value
	end
	return nil
end

-- A non-blank string, as sent.
local function text_of(value)
	if type(value) == "string" and value:find("%S") then
		return value
	end
	return nil
end

-- Bodies (section 3.1) -------------------------------------------------------------

-- Which group each field belongs to: one body carries one group's fields, and a
-- fan and a light field never share one (section 3.1, last paragraph). Breeze is
-- a group of its own (#111, docs/breeze-design.md section 2).
local FIELD_GROUP = {
	fan_on = "fan",
	speed = "fan",
	direction = "direction",
	level = "light",
	light_on = "light",
	wind = "breeze",
	wind_speed = "breeze",
	away = "away",
	learning = "learning",
}

local function integer_in(value, low, high)
	return type(value) == "number" and value == math.floor(value) and value >= low and value <= high
end

-- "fan on at N" is one body (V11, MFR 2.3); off carries no speed, and a speed
-- alone is no body of section 3.1.
local function fan_body(fields)
	local on, speed = fields.fan_on, fields.speed
	if on == nil then
		return nil, "mix"
	end
	if type(on) ~= "boolean" then
		return nil, "range"
	end
	if not on then
		if speed ~= nil then
			return nil, "mix"
		end
		return '{"fanOn":false}'
	end
	if speed == nil then
		return nil, "mix"
	end
	if not integer_in(speed, 1, 6) then
		return nil, "range"
	end
	return string.format('{"fanOn":true,"fanSpeed":%d}', speed)
end

local function direction_body(fields)
	local direction = fields.direction
	if direction ~= "forward" and direction ~= "reverse" then
		return nil, "range"
	end
	return string.format('{"fanDirection":"%s"}', direction)
end

-- The level and "on" are two bodies, level first (V14, S3): a body with
-- lightOn:true and a changed lightBrightness flashes the old level (MFR 2.3).
local function light_body(fields)
	local level, on = fields.level, fields.light_on
	if level ~= nil and on ~= nil then
		return nil, "mix"
	end
	if level ~= nil then
		if not integer_in(level, 1, 100) then
			return nil, "range"
		end
		return string.format('{"lightBrightness":%d}', level)
	end
	if type(on) ~= "boolean" then
		return nil, "range"
	end
	return on and '{"lightOn":true}' or '{"lightOn":false}'
end

-- Breeze (breeze-design section 2; BRR 4): exactly four bodies, the strength a
-- number 1 to 3 and never a string. Off carries no strength, and a strength is
-- sent alone or with on.
local function breeze_body(fields)
	local on, strength = fields.wind, fields.wind_speed
	if on ~= nil and type(on) ~= "boolean" then
		return nil, "range"
	end
	if strength ~= nil and not integer_in(strength, 1, 3) then
		return nil, "range"
	end
	if strength == nil then
		return on and '{"wind":true}' or '{"wind":false}'
	end
	if on == false then
		return nil, "mix"
	end
	if on == nil then
		return string.format('{"windSpeed":%d}', strength)
	end
	return string.format('{"wind":true,"windSpeed":%d}', strength)
end

-- The two fan automations are only ever switched off, on a click (V22).
local function off_body(fields, field, key)
	if fields[field] ~= false then
		return nil, "range"
	end
	return string.format('{"%s":false}', key)
end

local BUILDERS = {
	fan = fan_body,
	direction = direction_body,
	light = light_body,
	breeze = breeze_body,
	away = function(fields) return off_body(fields, "away", "awayModeEnabled") end,
	learning = function(fields) return off_body(fields, "learning", "adaptiveLearning") end,
}

-- The body of one group's fields, or nil and why: "empty" (no field), "unknown"
-- (a key outside the allow-list: factory_reset, reboot, schedule, a timer ...
-- are never written), "mix" (fields of two groups, or not one of the bodies of
-- section 3.1 and breeze-design section 2) or "range" (the right key, a value
-- out of range or of another type).
function wire.body(fields)
	if type(fields) ~= "table" then
		return nil, "empty"
	end
	for key in pairs(fields) do
		if not FIELD_GROUP[key] then
			return nil, "unknown"
		end
	end
	local group
	for key in pairs(fields) do
		local this = FIELD_GROUP[key]
		if group and group ~= this then
			return nil, "mix"
		end
		group = this
	end
	if not group then
		return nil, "empty"
	end
	return BUILDERS[group](fields)
end

-- Answers ----------------------------------------------------------------------------

-- No answer of a fan is near this: M0's are 455 and 547 bytes, the static read
-- the larger (tests/fixtures/mf_gen3.lua). A router's or a NAS's page at a
-- mistyped address may be (N4), and is not worth decoding. Bodies over 16 KB are
-- refused here and, before Director has gathered them, by the transport (#214).
wire.MAX_BODY_BYTES = 16384

-- The fan's answers are flat (depth 1: a string, number or boolean per key), and
-- C4:JsonDecode is documented with no depth limit (API 12_json/_3-JsonDecode):
-- nesting deeper than this is refused before the decoder sees it (#214).
wire.MAX_DEPTH = 8

-- Fields nothing in the driver reads (V20): removed from the decoded object so
-- that no later log line, report or dump can carry them. `schedule` stays,
-- because wire.state turns it into set/empty; `FrCodes` (what a fan keeps of
-- its paired remotes) is treated as private too [assumed].
local PRIVATE_KEYS = { "owner", "federatedIdentity", "deviceName", "SSID", "BSSID", "timezone", "certificateId",
	"FrCodes" }

local function is_object(value)
	for key in pairs(value) do
		if type(key) ~= "string" then
			return false
		end
	end
	return true
end

-- Why the arrays and objects of a JSON text cannot go to the decoder, in one
-- linear pass (#214), or nil when they can: "deep" when they nest deeper than
-- `limit`, "syntax" when the text cannot be JSON in a way that would make this
-- count differ from a decoder's. Only "[" and "{" outside strings deepen it; a
-- string runs from its quote to the next quote that no backslash escapes, and a
-- backslash always takes the byte after it, so "\\" ends at its quote and "\""
-- does not. "syntax" is a string that never ends, a "]" or "}" with nothing
-- open, and "/" or "'" outside a string: JSON has none of these, and a decoder
-- that took "/" for a comment or "'" for a quote would see other nesting.
local STRUCTURE = "[%[%]{}\"/']"
local QUOTE_OR_ESCAPE = "[\"\\]"
local BYTE_QUOTE, BYTE_BACKSLASH = 34, 92
local BYTE_OPEN_ARRAY, BYTE_OPEN_OBJECT = 91, 123
local BYTE_CLOSE_ARRAY, BYTE_CLOSE_OBJECT = 93, 125

local function nesting_refused(text, limit)
	local depth, i = 0, 1
	while true do
		local at = text:find(STRUCTURE, i)
		if not at then
			return nil
		end
		local byte = text:byte(at)
		if byte == BYTE_QUOTE then
			local j = at + 1
			while true do
				local q = text:find(QUOTE_OR_ESCAPE, j)
				if not q then
					return "syntax"
				end
				if text:byte(q) == BYTE_BACKSLASH then
					j = q + 2
				else
					i = q + 1
					break
				end
			end
		elseif byte == BYTE_OPEN_ARRAY or byte == BYTE_OPEN_OBJECT then
			depth = depth + 1
			if depth > limit then
				return "deep"
			end
			i = at + 1
		elseif byte == BYTE_CLOSE_ARRAY or byte == BYTE_CLOSE_OBJECT then
			if depth == 0 then
				return "syntax"
			end
			depth = depth - 1
			i = at + 1
		else
			return "syntax"
		end
	end
end

-- The decoded JSON object of an answer's body. C4:JsonDecode fails in two
-- documented ways, a raise and nil with a message (API 12_json/_3-JsonDecode),
-- both counted as "json"; so is any other JSON value than an object (a number,
-- a string, an array). A body over wire.MAX_BODY_BYTES (tested first, before any
-- scan of it) or nested deeper than MAX_DEPTH is "json" too, and a third value
-- says which, for the log; the decoder never sees it (#214). Never raises.
function wire.decode(text)
	if text == nil then
		return nil, "empty"
	end
	if type(text) ~= "string" then
		return nil, "json"
	end
	if #text > wire.MAX_BODY_BYTES then
		return nil, "json", string.format("over %d bytes; refused", wire.MAX_BODY_BYTES)
	end
	if not text:find("%S") then
		return nil, "empty"
	end
	local refused = nesting_refused(text, wire.MAX_DEPTH)
	if refused == "deep" then
		return nil, "json", string.format("nested deeper than %d; refused", wire.MAX_DEPTH)
	elseif refused then
		return nil, "json", "not JSON; refused before decoding"
	end
	local ok, value = pcall(function() return C4:JsonDecode(text) end)
	if not ok or type(value) ~= "table" or not is_object(value) then
		return nil, "json"
	end
	for _, key in ipairs(PRIVATE_KEYS) do
		value[key] = nil
	end
	return value
end

-- Every key an answer is known to carry, the ones the driver ignores and the
-- private ones included: only others are "unknown" (ECM F2). M0's keys, the
-- Gen 1/2 sleep timers (MFR 2.2) and the private names (V20).
local KNOWN_KEYS = {}
for _, key in ipairs({ "clientId", "cloudPort", "lightOn", "fanOn", "lightBrightness", "fanSpeed", "fanDirection",
	"wind", "windSpeed", "rfPairModeActive", "resetRfPairList", "factoryReset", "awayModeEnabled", "fanTimer",
	"lightTimer", "fanSleepTimer", "lightSleepTimer", "decommission", "schedule", "adaptiveLearning", "userData",
	"timezone", "FrCodes", "cdebug", "feedbackToneMute", "owner", "federatedIdentity", "deviceName", "SSID", "BSSID",
	"certificateId" }) do
	KNOWN_KEYS[key] = true
end
local MAX_UNKNOWN = 32
local MAX_KEY_NAME = 40

-- Names only, never values, sorted so the list does not depend on pairs().
-- Each is cut to MAX_KEY_NAME bytes and every byte outside printable ASCII
-- becomes "?", as for a log line (#214).
local function unknown_keys(obj)
	local names = {}
	for key in pairs(obj) do
		if type(key) == "string" and not KNOWN_KEYS[key] then
			names[#names + 1] = (key:sub(1, MAX_KEY_NAME):gsub("[^ -~]", "?"))
		end
	end
	table.sort(names)
	local out = {}
	for i = 1, math.min(#names, MAX_UNKNOWN) do
		out[i] = names[i]
	end
	return out
end

-- Values outside their range (section 3.3, H7). The caller logs `adjusted` once
-- per contact. fanSpeed 0 while the fan is off is "off, speed unknown" and is
-- not an adjustment; a speed above 6 is clamped to 6, one below 1 (while on, or
-- with the fan's state unknown) to 1.
local function speed_of(value, fan_on, adjusted)
	local n = number_of(value)
	if n == nil then
		return nil
	end
	n = round(n)
	if n >= 1 and n <= 6 then
		return n
	end
	if n == 0 and fan_on == false then
		return nil
	end
	adjusted[#adjusted + 1] = "fanSpeed " .. tostring(n)
	return n > 6 and 6 or 1
end

-- A level of 0 while the light is on is reported as 1 (never 0 while on, LV2
-- 35/_10.2); above 100 it is 100. While off (or unknown) a 0 says only that the
-- kept level is unknown (M0: the level is kept while off).
local function level_of(value, light_on, adjusted)
	local n = number_of(value)
	if n == nil then
		return nil
	end
	n = round(n)
	if n >= 1 and n <= 100 then
		return n
	end
	if n > 100 then
		adjusted[#adjusted + 1] = "lightBrightness " .. tostring(n)
		return 100
	end
	if light_on == true then
		adjusted[#adjusted + 1] = "lightBrightness " .. tostring(n)
		return 1
	end
	if n < 0 then
		adjusted[#adjusted + 1] = "lightBrightness " .. tostring(n)
	end
	return nil
end

-- The Breeze strength 1 to 3 (BRR 1), read as the speed is: rounded, above 3
-- clamped to 3 and below 1 to 1, saying so; 0 with Breeze off says only that
-- the kept strength is unknown, and is not an adjustment.
local function wind_speed_of(value, wind, adjusted)
	local n = number_of(value)
	if n == nil then
		return nil
	end
	n = round(n)
	if n >= 1 and n <= 3 then
		return n
	end
	if n == 0 and wind == false then
		return nil
	end
	adjusted[#adjusted + 1] = "windSpeed " .. tostring(n)
	return n > 3 and 3 or 1
end

local function direction_of(value)
	local text = string_of(value)
	text = text and text:lower()
	if text == "forward" or text == "reverse" then
		return text
	end
	return nil
end

-- The schedule is a base64 blob: only whether there is one leaves this file.
local function schedule_set_of(value)
	local text = string_of(value)
	if text == nil then
		return nil
	end
	return text:find("%S") ~= nil
end

-- A timer key in the dynamic shadow means Gen 3, a sleep timer Gen 1/2 (section
-- 4.1; AIO _infer_generation); by the keys' presence, whatever their values.
local function generation_of(obj)
	if obj.fanTimer ~= nil or obj.lightTimer ~= nil then
		return "3"
	end
	if obj.fanSleepTimer ~= nil or obj.lightSleepTimer ~= nil then
		return "1/2"
	end
	return nil
end

-- The fan's dynamic answer as the fields of section 4.1 (nil = missing, odd or
-- unknown, never a default) or nil, "json" when it is no fan's answer: not a
-- table or without a clientId (section 3.3). Beyond section 9.3's list,
-- `adjusted` names the out-of-range values that were clamped ("fanSpeed 9").
function wire.state(obj)
	if type(obj) ~= "table" then
		return nil, "json"
	end
	local client_id = text_of(obj.clientId)
	if not client_id then
		return nil, "json"
	end
	local adjusted = {}
	local st = { client_id = client_id }
	st.fan_on = bool_of(obj.fanOn)
	st.speed = speed_of(obj.fanSpeed, st.fan_on, adjusted)
	st.direction = direction_of(obj.fanDirection)
	st.light_on = bool_of(obj.lightOn)
	st.level = level_of(obj.lightBrightness, st.light_on, adjusted)
	st.wind = bool_of(obj.wind)
	st.wind_speed = wind_speed_of(obj.windSpeed, st.wind, adjusted)
	st.away = bool_of(obj.awayModeEnabled)
	st.learning = bool_of(obj.adaptiveLearning)
	st.schedule_set = schedule_set_of(obj.schedule)
	st.fan_timer = number_of(obj.fanTimer)
	st.light_timer = number_of(obj.lightTimer)
	st.fan_sleep_timer = number_of(obj.fanSleepTimer)
	st.light_sleep_timer = number_of(obj.lightSleepTimer)
	st.user_data = string_of(obj.userData)
	st.generation = generation_of(obj)
	st.unknown = unknown_keys(obj)
	st.adjusted = adjusted
	return st
end

-- Identity helpers --------------------------------------------------------------------

-- The station MAC as 12 uppercase hex digits from the forms a fan or an mDNS
-- record writes it: bare, or six pairs joined by one ":" or "-".
function wire.mac12(text)
	if type(text) ~= "string" then
		return nil
	end
	local s = trim(text)
	if s:match("^%x%x%x%x%x%x%x%x%x%x%x%x$") then
		return s:upper()
	end
	local a, _, b, c, d, e, f = s:match("^(%x%x)([:%-])(%x%x)%2(%x%x)%2(%x%x)%2(%x%x)%2(%x%x)$")
	if not a then
		return nil
	end
	return (a .. b .. c .. d .. e .. f):upper()
end

-- The static answer reduced to the identity and model fields (V20: nothing
-- else is copied; owner, federatedIdentity, deviceName, SSID, BSSID, the
-- firmware URL and the Wi-Fi strength stay behind) or nil, "json" without a
-- clientId. `mac` is nil when the answer has none a MAC can be read from (the
-- caller treats that as not a fan's static answer, N4); `light_type` and
-- `has_light` are nil when lightType is missing, "" and false without a light
-- kit (H4).
function wire.info(obj)
	if type(obj) ~= "table" then
		return nil, "json"
	end
	local client_id = text_of(obj.clientId)
	if not client_id then
		return nil, "json"
	end
	local light_type = string_of(obj.lightType)
	local has_light
	if light_type ~= nil then
		has_light = light_type:find("%S") ~= nil
	end
	return {
		client_id = client_id,
		mac = wire.mac12(obj.mac),
		fan_type = string_of(obj.fanType),
		light_type = light_type,
		has_light = has_light,
		motor_type = string_of(obj.fanMotorType),
		firmware = string_of(obj.firmwareVersion),
		mcu_firmware = string_of(obj.mainMcuFirmwareVersion),
		brand = number_of(obj.brand),
	}
end

-- A Gen 4 fan's /device answer (section 3.6; AIO const.py, gen4.py).
function wire.is_g4(obj)
	if type(obj) ~= "table" then
		return false
	end
	local system_type = string_of(obj.systemType)
	return system_type ~= nil and system_type:lower():find("fan_g4", 1, true) ~= nil
end

local function id_text(value)
	if type(value) == "table" then
		value = value.client_id
	end
	if type(value) ~= "string" then
		return nil
	end
	value = trim(value):lower()
	if value == "" then
		return nil
	end
	return value
end

-- Whether the client id an answer carries is the pinned fan's (N9). Either
-- argument may be the id itself or a table holding it as `client_id` (the
-- model's pin, wire.state's or wire.info's result); case does not matter.
function wire.same_fan(pin, client_id)
	local pinned, seen = id_text(pin), id_text(client_id)
	return pinned ~= nil and pinned == seen
end

-- A dotted quad of four decimal parts 0 to 255, trimmed. Leading zeros are
-- refused: C resolvers read "010" as octal, so the owner's "10.0.2.010" could
-- reach another host than it reads as. Hostnames are not accepted in v1
-- (section 3.5).
function wire.ipv4(text)
	if type(text) ~= "string" then
		return nil
	end
	local parts = { trim(text):match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$") }
	if #parts ~= 4 then
		return nil
	end
	for i = 1, 4 do
		local part = parts[i]
		if #part > 3 or (#part > 1 and part:sub(1, 1) == "0") or tonumber(part) > 255 then
			return nil
		end
	end
	return table.concat(parts, ".")
end

return wire
