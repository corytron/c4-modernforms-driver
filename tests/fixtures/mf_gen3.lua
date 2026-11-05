-- The Gen 3 fixtures of docs/v1-design.md section 10.1, loaded as
-- require("fixtures.mf_gen3"): the JSON strings of the house fan's two answers
-- (M0) with every private value replaced by the placeholders of
-- docs/scaffold-design.md section 2, keys in the order the fan sent them and
-- values of the types it sent them (wifiSignal is a string, as the fan sends
-- it). Strings marked "synthesized" are not the fan's: they are written from
-- the public code (AIO, docs/modernforms-api-research.md) to cover answers the
-- house fan does not give. No real address, MAC, client id, e-mail, identity,
-- name or SSID belongs in this file, ever: the `secrets` check refuses them.

local M = {}

-- In an overrides table, drops the key from the answer.
M.OMIT = setmetatable({}, { __tostring = function() return "OMIT" end })

-- The private values the info answer carries, for specs that check they never
-- come out of the parsers.
M.PRIVATE_VALUES = {
	"owner@example.com",
	"us-east-1:00000000-0000-0000-0000-000000000000",
	"Example Fan",
	"example-ssid",
	"00:00:5e:00:53:ff",
	"UTC0",
}

-- A flat JSON writer: booleans, integers, strings; compact, as the fan writes.
local ESCAPES = { ['"'] = '\\"', ["\\"] = "\\\\", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }

local function encode_value(value)
	local kind = type(value)
	if kind == "boolean" then
		return value and "true" or "false"
	elseif kind == "number" then
		if value == math.floor(value) then
			return string.format("%d", value)
		end
		return string.format("%.14g", value)
	elseif kind == "string" then
		local escaped = value:gsub('[%c"\\]', function(char)
			return ESCAPES[char] or string.format("\\u%04x", char:byte())
		end)
		return '"' .. escaped .. '"'
	end
	error("fixture value of type " .. kind)
end

-- keys: the names in the order to write; defaults: name -> value; overrides:
-- name -> value or M.OMIT. A key the defaults do not know is appended after
-- them, in name order (a field the fan does not send today).
local function encode(keys, defaults, overrides)
	overrides = overrides or {}
	local parts = {}
	local function add(key, value)
		if value ~= M.OMIT then
			parts[#parts + 1] = encode_value(key) .. ":" .. encode_value(value)
		end
	end
	for _, key in ipairs(keys) do
		local value = overrides[key]
		if value == nil then
			value = defaults[key]
		end
		add(key, value)
	end
	local extra = {}
	for key in pairs(overrides) do
		if defaults[key] == nil then
			extra[#extra + 1] = key
		end
	end
	table.sort(extra)
	for _, key in ipairs(extra) do
		add(key, overrides[key])
	end
	return "{" .. table.concat(parts, ",") .. "}"
end

-- The dynamic answer (queryDynamicShadowData; also every command's answer) --------

M.STATE_KEYS = {
	"clientId", "cloudPort", "lightOn", "fanOn", "lightBrightness", "fanSpeed", "fanDirection", "wind", "windSpeed",
	"rfPairModeActive", "resetRfPairList", "factoryReset", "awayModeEnabled", "fanTimer", "lightTimer",
	"decommission", "schedule", "adaptiveLearning", "userData", "timezone", "FrCodes", "cdebug",
	"feedbackToneMute",
}

-- M0: fan on at 1, forward, light off at 100, Breeze off, cloudPort 8883.
local STATE_DEFAULTS = {
	clientId = "MF_00005E005301",
	cloudPort = 8883,
	lightOn = false,
	fanOn = true,
	lightBrightness = 100,
	fanSpeed = 1,
	fanDirection = "forward",
	wind = false,
	windSpeed = 2,
	rfPairModeActive = false,
	resetRfPairList = false,
	factoryReset = false,
	awayModeEnabled = false,
	fanTimer = 0,
	lightTimer = 0,
	decommission = false,
	schedule = "",
	adaptiveLearning = false,
	userData = "local_wifi",
	timezone = "UTC0",
	FrCodes = "HHxxxxxxxxxxxxx",
	cdebug = false,
	feedbackToneMute = false,
}

-- M0's state with the given fan keys replaced: state({ fanSpeed = 3 }) is the
-- fan on at 3 with the light off at 100; state({ wind = M.OMIT }) leaves a key out.
function M.state(overrides)
	return encode(M.STATE_KEYS, STATE_DEFAULTS, overrides)
end

M.STATE = M.state()
M.STATE_ON_3 = M.state({ fanSpeed = 3 })

-- The static answer (queryStaticShadowData) ----------------------------------------------

M.INFO_KEYS = {
	"clientId", "mac", "lightType", "fanType", "fanMotorType", "brand", "dateCode", "owner", "federatedIdentity",
	"deviceName", "firmwareVersion", "esp-idf-version", "mainMcuFirmwareVersion", "firmwareUrl", "wifiSignal",
	"SSID", "BSSID", "isUvcFan", "built", "dimTableId", "elecFreq",
}

local INFO_DEFAULTS = {
	clientId = "MF_00005E005301",
	mac = "00:00:5e:00:53:01",
	lightType = "F4IN-120V-R1-30",
	fanType = "1811-5-54",
	fanMotorType = "DC125X20",
	brand = 1,
	dateCode = "2021-12-02",
	owner = "owner@example.com",
	federatedIdentity = "us-east-1:00000000-0000-0000-0000-000000000000",
	deviceName = "Example Fan",
	firmwareVersion = "02.00.0052",
	["esp-idf-version"] = "4.0.4",
	mainMcuFirmwareVersion = "03.00.0000",
	firmwareUrl = "",
	wifiSignal = "-68",
	SSID = "example-ssid",
	BSSID = "00:00:5e:00:53:ff",
	isUvcFan = false,
	built = "realHardware",
	dimTableId = 416020,
	elecFreq = 60,
}

function M.info(overrides)
	return encode(M.INFO_KEYS, INFO_DEFAULTS, overrides)
end

M.INFO = M.info()
-- A second Modern Forms fan (MF_00005E005302): what answers when two fans swap addresses.
M.INFO_OTHER = M.info({ clientId = "MF_00005E005302", mac = "00:00:5e:00:53:02" })
-- A fan without a light kit (H4).
M.INFO_NO_KIT = M.info({ lightType = "" })

-- Synthesized from the public code ---------------------------------------------------------

-- Gen 1/2 (MFR 2.2): M0's state without the Gen 3 keys, with the sleep timers.
M.GEN12_STATE = M.state({
	wind = M.OMIT,
	windSpeed = M.OMIT,
	userData = M.OMIT,
	fanTimer = M.OMIT,
	lightTimer = M.OMIT,
	fanSleepTimer = 0,
	lightSleepTimer = 0,
})

-- A Gen 4 fan's POST /device {"query":true} answer (MFR 4; AIO const.py, gen4.py).
M.G4_DEVICE = '{"systemType":"fan_g4","deviceName":"Example Fan","iotmVer":"01.00.0082",'
	.. '"staMac":"00:00:5e:00:53:01","awayModeEnabled":false}'

-- What a Gen 4 fan or another web server answers on /mf: HTTP 404 and a short text.
M.NOT_FOUND = "404 Not Found"
-- What a router's or a NAS's page looks like (N4).
M.HTML = "<html><head><title>Example</title></head><body><h1>Example Router</h1></body></html>"

M.EMPTY = ""
-- Valid JSON, but no clientId: not a fan's answer (section 3.3).
M.NO_CLIENT = '{"fanOn":true}'
-- An answer cut off in the middle, a JSON array and a bare number: not objects.
M.TRUNCATED = '{"clientId":"MF_00005E005301","cloudPort":8883,"lightOn":fal'
M.ARRAY = "[1,2,3]"
M.NUMBER = "42"

return M
