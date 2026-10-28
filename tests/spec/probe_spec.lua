-- The M1 probe (probes/mf_probe; docs/v1-design.md section 11; probes/README.md):
-- its driver.xml, the log of every entry point, the echo, the Lua window
-- helpers, the K10 mDNS run, Dump State, and the DNS packet build and parse
-- against an answer recorded with placeholders. The probe lives outside src/,
-- so it is loaded here by path, the way fake.load_driver loads a driver, on the
-- fake runtime of fake.install_c4.

local fake = require("helpers.fake_c4")

-- The repository root, from where busted found this file.
local ROOT = debug.getinfo(1, "S").source:match("^@(.-)tests/spec/probe_spec%.lua$") or ""
local PROBE = ROOT .. "probes/mf_probe/"

local function read(path)
	local file = assert(io.open(path))
	local text = file:read("*a")
	file:close()
	return text
end

local function record(c4, name, ...)
	c4.calls[#c4.calls + 1] = { name = name, args = { ... } }
end

-- The Director calls the probe makes that the fake runtime does not record,
-- recorded the same way; SendToProxy again, with its fourth argument (COMMAND
-- or NOTIFY).
local function add_calls(c4)
	function c4:SendToProxy(binding, command, params, kind)
		record(c4, "SendToProxy", binding, command, params, kind)
	end
	function c4:AllowExecute(allowed)
		record(c4, "AllowExecute", allowed)
	end
	function c4:CreateNetworkConnection(binding, address, kind)
		record(c4, "CreateNetworkConnection", binding, address, kind)
	end
	function c4:NetPortOptions(binding, port, kind, options)
		record(c4, "NetPortOptions", binding, port, kind, options)
	end
	function c4:NetConnect(binding, port, kind)
		record(c4, "NetConnect", binding, port, kind)
	end
	function c4:NetDisconnect(binding, port)
		record(c4, "NetDisconnect", binding, port)
	end
	function c4:SendToNetwork(binding, port, data)
		record(c4, "SendToNetwork", binding, port, data)
	end
	function c4:RegisterVariableListener(device, variable)
		record(c4, "RegisterVariableListener", device, variable)
	end
	function c4:UnregisterVariableListener(device, variable)
		record(c4, "UnregisterVariableListener", device, variable)
	end
end

-- The probe's driver.lua in a fresh environment; returns it, the fake C4
-- and the lines it printed.
local function load_probe(properties)
	local props = { ["Echo LED On Press"] = "Off" }
	for k, v in pairs(properties or {}) do
		props[k] = v
	end
	local c4, env = fake.install_c4(props)
	add_calls(c4)
	local lines = {}
	env.print = function(...)
		local parts = {}
		for i = 1, select("#", ...) do
			parts[i] = tostring((select(i, ...)))
		end
		lines[#lines + 1] = table.concat(parts, " ")
	end
	env._G = env
	setmetatable(env, { __index = _G })
	local chunk = assert(loadfile(PROBE .. "driver.lua"))
	setfenv(chunk, env)
	chunk()
	return env, c4, lines
end

-- Fire the active timers armed with this delay (the probe's delays differ
-- except where a test says so), as Director would when it falls due.
local function fire(c4, delay)
	local due = {}
	for _, timer in ipairs(c4.active_timers()) do
		if timer.delay == delay then
			due[#due + 1] = timer
		end
	end
	for _, timer in ipairs(due) do
		timer.active = timer.repeating
		timer.callback(timer, 0)
	end
	return #due
end

local function find(lines, text)
	for _, line in ipairs(lines) do
		if line:find(text, 1, true) then
			return line
		end
	end
	return nil
end

local function count_lines(lines, text)
	local n = 0
	for _, line in ipairs(lines) do
		if line:find(text, 1, true) then
			n = n + 1
		end
	end
	return n
end

-- Byte builders for recorded datagrams, independent of the probe's encoder.
local function u16(n)
	return string.char(math.floor(n / 256) % 256, n % 256)
end

local function u32(n)
	return u16(math.floor(n / 65536)) .. u16(n % 65536)
end

local function labels(...)
	local out = {}
	for _, label in ipairs({ ... }) do
		out[#out + 1] = string.char(#label) .. label
	end
	return table.concat(out)
end

local function pointer(offset)
	return u16(0xC000 + offset)
end

local function rr(name, rtype, class, ttl, rdata)
	return name .. u16(rtype) .. u16(class) .. u32(ttl) .. u16(#rdata) .. rdata
end

-- The fan's answer to the PTR question, as M0 saw it on the house (issue #11:
-- the instance MF_Fan_<the MAC's last six hex digits>, SRV port 80, TXT
-- Protocol, MAC and Firmware Rev, an A record), with the placeholders of
-- docs/scaffold-design.md section 2 and the compressed names a responder
-- writes. opts.question repeats the question first, as a legacy unicast
-- answer does with the query's id (opts.id); opts.mac is the TXT MAC value.
local INSTANCE = "MF_Fan_005301"

local function fan_answer(opts)
	opts = opts or {}
	local header = u16(opts.id or 0) .. u16(0x8400) .. u16(opts.question and 1 or 0) .. u16(1) .. u16(0) .. u16(3)
	local service = labels("_easylink", "_tcp", "local") .. "\0"
	local service_at = #header
	local local_at = service_at + 1 + #"_easylink" + 1 + #"_tcp"
	local prefix = header .. (opts.question and (service .. u16(12) .. u16(1)) or "")
	local answer_name = opts.question and pointer(service_at) or service
	local instance_at = #prefix + #answer_name + 10
	local answer = rr(answer_name, 12, 1, 4500, labels(INSTANCE) .. pointer(service_at))
	local srv = rr(pointer(instance_at), 33, 0x8001, 120,
		u16(0) .. u16(0) .. u16(80) .. labels(INSTANCE) .. pointer(local_at))
	local host_at = #prefix + #answer + 2 + 10 + 6
	local txt = rr(pointer(instance_at), 16, 0x8001, 4500,
		labels("Protocol=com.modernforms.fan", "MAC=" .. (opts.mac or "00:00:5E:00:53:01"), "Firmware Rev=02.00.0052"))
	local address = rr(pointer(host_at), 1, 0x8001, 120, string.char(10, 0, 2, 151))
	return prefix .. answer .. srv .. txt .. address
end

-- Another device's announcement on the group, which the probe must not print.
local function other_answer()
	local header = u16(0) .. u16(0x8400) .. u16(0) .. u16(1) .. u16(0) .. u16(0)
	local service = labels("_airplay", "_tcp", "local") .. "\0"
	return header .. rr(service, 12, 1, 4500, labels("Example Speaker") .. pointer(12))
end

-- The query the probe must send: id, no flags, one question, PTR, class IN
-- (with the unicast-response bit for QU).
local function expected_query(id, qu)
	return u16(id) .. u16(0) .. u16(1) .. u16(0) .. u16(0) .. u16(0) .. "\9_easylink\4_tcp\5local\0" .. u16(12)
		.. u16(qu and 0x8001 or 1)
end

local LINE = "^%[MFP%] (%d+) (%d%d:%d%d:%d%d%.%d%d%d) %+(%d+%.%d%d%d) (.*)$"

describe("MF Probe", function()
	describe("driver.xml", function()
		local xml = read(PROBE .. "driver.xml")
		local bare = xml:gsub("<!%-%-.-%-%->", "")
		local real = read(ROOT .. "src/modernforms_fan/driver.xml")

		local function field(text, tag)
			return text:match("<" .. tag .. ">(.-)</" .. tag .. ">")
		end

		it("is never the real driver: its own name and model", function()
			assert.are.equal("MF Probe (delete after M1)", field(bare, "name"))
			assert.are_not.equal(field(real, "name"), field(bare, "name"))
			assert.are_not.equal(field(real, "model"), field(bare, "model"))
		end)

		it("declares the fan proxy first, on 5001, then light_v2 on 5002", function()
			local proxies = {}
			for attrs, kind in bare:gmatch("<proxy%s([^>]*)>(.-)</proxy>") do
				proxies[#proxies + 1] = { id = attrs:match('proxybindingid="(%d+)"'), kind = kind,
					primary = attrs:match('primary="(%a+)"') }
			end
			assert.are.same({
				{ id = "5001", kind = "fan", primary = "True" },
				{ id = "5002", kind = "light_v2" },
			}, proxies)
		end)

		it("carries the capabilities K1 verified and proxy_fan_speed_connections for K5", function()
			local caps = field(bare, "capabilities")
			assert.are.equal("6", field(caps, "discrete_levels"))
			assert.are.equal("Level 1, Level 2, Level 3, Level 4, Level 5, Level 6", field(caps, "speed_names"))
			assert.are.equal("True", field(caps, "proxy_fan_speed_connections"))
			assert.are.equal("True", field(caps, "can_reverse"))
			assert.are.equal("True", field(caps, "has_leds"))
			assert.are.equal("True", field(caps, "reduced_als_support"))
		end)

		it("has link 200 with proxybindingid 5002 and link 300 without, and no network connection", function()
			local connections = {}
			for attrs, body in bare:gmatch("<connection([^>]*)>(.-)</connection>") do
				connections[#connections + 1] = { id = field(body, "id"), proxy = attrs:match('proxybindingid="(%d+)"'),
					class = field(body, "classname"), type = field(body, "type") }
			end
			assert.are.same({
				{ id = "5001", class = "FAN", type = "2" },
				{ id = "5002", class = "LIGHT_V2", type = "2" },
				{ id = "200", proxy = "5002", class = "BUTTON_LINK", type = "1" },
				{ id = "300", class = "BUTTON_LINK", type = "1" },
			}, connections)
		end)

		it("has one property and the two actions, each command its name", function()
			assert.are.equal(1, select(2, bare:gsub("<property>", "")))
			assert.are.equal("Echo LED On Press", field(field(bare, "property"), "name"))
			assert.are.equal("Off", field(field(bare, "property"), "default"))
			local actions = {}
			for body in bare:gmatch("<action>(.-)</action>") do
				actions[#actions + 1] = { field(body, "name"), field(body, "command"), field(body, "sort_order") }
			end
			assert.are.same({ { "Run mDNS Probe", "Run mDNS Probe", "1" }, { "Dump State", "Dump State", "2" } }, actions)
		end)
	end)

	describe("the Director calls it makes", function()
		-- Every C4 method the probe calls, with the SDK page that documents it
		-- (under ~/c4-tools/reference/docs-driverworks-api/source/includes/).
		local DOCUMENTED = {
			AllowExecute = "22_miscellaneous/_2-AllowExecute.md",
			CreateNetworkConnection = "32_serial_network_device/_1-CreateNetworkConnection.md",
			GetBindingAddress = "32_serial_network_device/_2-GetBindingAddress.md",
			GetBindingsByDevice = "32_serial_network_device/_2.5-GetBindingsByDevice.md",
			GetBoundConsumerDevices = "32_serial_network_device/_3-GetBoundConsumerDevices.md",
			GetDeviceID = "22_miscellaneous/_11-GetDeviceID.md",
			GetDeviceVariables = "22_miscellaneous/_12-GetDeviceVariables.md",
			GetDriverConfigInfo = "22_miscellaneous/_13-GetDriverConfigInfo.md",
			GetProxyDevices = "25_proxy/_1-GetProxyDevices.md",
			GetTime = "34_timer/_2-GetTime.md",
			GetVersionInfo = "5_director_command/_2-GetVersionInfo.md",
			NetConnect = "32_serial_network_device/_23-NetConnect.md",
			NetDisconnect = "32_serial_network_device/_24-NetDisconnect.md",
			NetPortOptions = "32_serial_network_device/_25-NetPortOptions.md",
			RegisterVariableListener = "36_variable/_10-RegisterVariableListener.md",
			SendToDevice = "32_serial_network_device/_19-SendToDevice.md",
			SendToNetwork = "32_serial_network_device/_20-SendToNetwork.md",
			SendToProxy = "25_proxy/_6-SendToProxy.md",
			SetTimer = "34_timer/_1-SetTimer.md",
			UnregisterVariableListener = "36_variable/_11-UnregisterVariableListener.md",
		}

		it("are all documented ones", function()
			local source = read(PROBE .. "driver.lua")
			local unknown = {}
			for name in source:gmatch("C4:(%w+)%(") do
				if not DOCUMENTED[name] then
					unknown[#unknown + 1] = name
				end
			end
			assert.are.same({}, unknown)
		end)

		it("defines the documented entry points and nothing else global but P", function()
			local env = load_probe()
			local globals = {}
			for name, value in pairs(env) do
				if type(value) == "function" then
					globals[#globals + 1] = name
				end
			end
			table.sort(globals)
			assert.are.same({ "ExecuteCommand", "OnBindingChanged", "OnConnectionStatusChanged", "OnDriverDestroyed",
				"OnDriverInit", "OnDriverLateInit", "OnDriverRemovedFromProject", "OnNetworkBindingChanged",
				"OnPropertyChanged", "OnWatchedVariableChanged", "ReceivedFromNetwork", "ReceivedFromProxy", "print" },
				globals)
			assert.are.equal("table", type(env.P))
		end)
	end)

	describe("the log", function()
		it("allows the Lua window in OnDriverInit and says so", function()
			local env, c4, lines = load_probe()
			env.OnDriverInit("DIT_ADDING")
			assert.are.same({ { true } }, c4.calls_to("AllowExecute"))
			assert.truthy(find(lines, "OnDriverInit DIT_ADDING; Lua window allowed"))
		end)

		it("says when the Lua window could not be allowed", function()
			local env, c4, lines = load_probe()
			function c4:AllowExecute()
				error("not here")
			end
			env.OnDriverInit("DIT_STARTUP")
			assert.truthy(find(lines, "C4:AllowExecute failed"))
			assert.truthy(find(lines, "Lua window NOT allowed"))
		end)

		it("names the build, the device and Director at late init", function()
			local env, _, lines = load_probe()
			env.OnDriverLateInit("DIT_ADDING")
			assert.truthy(find(lines, "OnDriverLateInit DIT_ADDING: MF Probe version 1, device 15, Director 3.4.2.746094"))
		end)

		it("prefixes every line with [MFP], a sequence number, the clock and the time since the last line", function()
			local env, c4, lines = load_probe()
			env.ReceivedFromProxy(300, "DO_PUSH", {})
			c4.now_ms = c4.now_ms + 412
			env.ReceivedFromProxy(300, "DO_CLICK", {})
			local seq1, _, _, text1 = lines[1]:match(LINE)
			local seq2, _, delta2, text2 = lines[2]:match(LINE)
			assert.are.equal("ReceivedFromProxy binding=300 (fan link) cmd=DO_PUSH {}", text1)
			assert.are.equal("ReceivedFromProxy binding=300 (fan link) cmd=DO_CLICK {}", text2)
			assert.are.equal(tonumber(seq1) + 1, tonumber(seq2))
			assert.are.equal("0.412", delta2)
		end)

		it("logs every entry point with its binding, command and every parameter", function()
			local env, c4, lines = load_probe()
			env.ReceivedFromProxy(5001, "SET_SPEED", { SPEED = "4" })
			env.ReceivedFromProxy(201, "DO_PUSH")
			env.ExecuteCommand("SET_FAN_SPEED", { SPEED = 3, NAME = "a \"b\"\n" })
			env.OnBindingChanged(300, "BUTTON_LINK", true, 1204, 101)
			env.OnPropertyChanged("Echo LED On Press")
			env.OnNetworkBindingChanged(6001, false)
			env.OnConnectionStatusChanged(6002, 5353, "OFFLINE")
			env.OnWatchedVariableChanged(3001, 1001, "2")
			env.OnDriverRemovedFromProject()
			env.OnDriverDestroyed("DIT_UPDATING")
			assert.truthy(find(lines, 'ReceivedFromProxy binding=5001 (fan proxy) cmd=SET_SPEED {SPEED="4"}'))
			assert.truthy(find(lines, "ReceivedFromProxy binding=201 (not declared by the probe) cmd=DO_PUSH (no params)"))
			assert.truthy(find(lines, 'ExecuteCommand cmd=SET_FAN_SPEED {NAME="a \\"b\\"\\010", SPEED=3}'))
			assert.truthy(find(lines,
				"OnBindingChanged binding=300 (fan link) class=BUTTON_LINK bound=true other_device=1204 other_binding=101"))
			assert.truthy(find(lines, 'OnPropertyChanged name="Echo LED On Press" value="Off"'))
			assert.truthy(find(lines, "OnNetworkBindingChanged binding=6001 (mDNS MULTICAST) bound=false"))
			assert.truthy(find(lines, "OnConnectionStatusChanged binding=6002 (mDNS UDP) port=5353 status=OFFLINE"))
			assert.truthy(find(lines, 'OnWatchedVariableChanged device=3001 variable=1001 value="2"'))
			assert.truthy(find(lines, "OnDriverRemovedFromProject"))
			assert.truthy(find(lines, "OnDriverDestroyed DIT_UPDATING"))
			-- Nothing is answered.
			assert.are.same({}, c4.calls_to("SendToProxy"))
		end)

		it("cuts MAC-like text down to its last four hex digits in every line", function()
			local env, _, lines = load_probe()
			env.ExecuteCommand("NOTE", { MAC = "00:00:5E:00:53:01", ID = "MF_00005E005301", NAME = "MF_Fan_005301" })
			local line = find(lines, "ExecuteCommand cmd=NOTE")
			assert.truthy(line:find('MAC="xx:xx:xx:xx:53:01"', 1, true))
			assert.truthy(line:find('ID="MF_xxxxxxxx5301"', 1, true))
			assert.truthy(line:find('NAME="MF_Fan_xx5301"', 1, true))
			assert.falsy(line:find("00:00:5E", 1, true))
		end)

		it("prints a long text in numbered pieces", function()
			local env, _, lines = load_probe()
			env.ExecuteCommand("LONG", { TEXT = string.rep("a", 1300) })
			assert.are.equal(3, #lines)
			assert.truthy(lines[1]:find(" (1/3) ExecuteCommand cmd=LONG", 1, true))
			assert.truthy(lines[3]:find(" (3/3) ", 1, true))
		end)

		it("keeps the last 400 lines, which P.history prints again", function()
			local env, _, lines = load_probe()
			for i = 1, 405 do
				env.OnPropertyChanged("Row " .. i)
			end
			local before = #lines
			env.P.history(2)
			assert.are.equal(before + 3, #lines)
			assert.truthy(lines[before + 1]:find("history: the last 2 of 400 kept lines", 1, true))
			assert.are.equal(lines[before - 1], lines[before + 2])
			assert.are.equal(lines[before], lines[before + 3])
			env.P.history()
			assert.truthy(lines[before + 4]:find("history: the last 400 of 400 kept lines", 1, true))
			assert.truthy(lines[before + 5]:find('name="Row 6"', 1, true))
		end)
	end)

	describe("Echo LED On Press", function()
		local function leds(c4)
			local out = {}
			for _, args in ipairs(c4.calls_to("SendToProxy")) do
				out[#out + 1] = { args[1], args[2], args[3].STATE, args[4] }
			end
			return out
		end

		it("Off: a press is only logged", function()
			local env, c4 = load_probe()
			env.ReceivedFromProxy(300, "DO_PUSH", {})
			env.ReceivedFromProxy(300, "DO_RELEASE", {})
			assert.are.same({}, leds(c4))
		end)

		it("On: DO_PUSH lights the link's LED and DO_RELEASE darkens it, on 300 and 200 only", function()
			local env, c4, lines = load_probe({ ["Echo LED On Press"] = "On" })
			env.ReceivedFromProxy(300, "DO_PUSH", {})
			env.ReceivedFromProxy(300, "DO_CLICK", {})
			env.ReceivedFromProxy(300, "DO_RELEASE", {})
			env.ReceivedFromProxy(200, "DO_PUSH", {})
			env.ReceivedFromProxy(200, "DO_RELEASE", {})
			env.ReceivedFromProxy(301, "DO_PUSH", {})
			env.ReceivedFromProxy(5001, "DO_PUSH", {})
			env.ReceivedFromProxy(300, "REQUEST_BUTTON_COLORS", {})
			assert.are.same({
				{ 300, "MATCH_LED_STATE", true, "COMMAND" },
				{ 300, "MATCH_LED_STATE", false, "COMMAND" },
				{ 200, "MATCH_LED_STATE", true, "COMMAND" },
				{ 200, "MATCH_LED_STATE", false, "COMMAND" },
			}, leds(c4))
			assert.truthy(find(lines, "echo: sent SendToProxy(300, MATCH_LED_STATE, {STATE=true}, COMMAND)"))
		end)

		it("follows the property as it changes", function()
			local env, c4 = load_probe()
			env.Properties["Echo LED On Press"] = "On"
			env.OnPropertyChanged("Echo LED On Press")
			env.ReceivedFromProxy(300, "DO_PUSH", {})
			env.Properties["Echo LED On Press"] = "Off"
			env.ReceivedFromProxy(300, "DO_RELEASE", {})
			assert.are.same({ { 300, "MATCH_LED_STATE", true, "COMMAND" } }, leds(c4))
		end)
	end)

	describe("the Lua window helpers", function()
		it("P.led sends MATCH_LED_STATE as a COMMAND", function()
			local env, c4, lines = load_probe()
			env.P.led(300, true)
			env.P.led("200", "off")
			env.P.led(nil, true)
			assert.are.same({
				{ 300, "MATCH_LED_STATE", { STATE = true }, "COMMAND" },
				{ 200, "MATCH_LED_STATE", { STATE = false }, "COMMAND" },
			}, c4.calls_to("SendToProxy"))
			assert.truthy(find(lines, "P.led(link, on): a link id such as 300"))
		end)

		it("P.colors sends BUTTON_COLORS as a NOTIFY, the current colour the on colour unless given", function()
			local env, c4, lines = load_probe()
			env.P.colors(300, "FF0000", "#000000")
			env.P.colors(300, "0000ff", "000000", "000000")
			env.P.colors(300, "red", "000000")
			assert.are.same({
				{ 300, "BUTTON_COLORS", { ON_COLOR = "ff0000", OFF_COLOR = "000000", CURRENT_COLOR = "ff0000" }, "NOTIFY" },
				{ 300, "BUTTON_COLORS", { ON_COLOR = "0000ff", OFF_COLOR = "000000", CURRENT_COLOR = "000000" }, "NOTIFY" },
			}, c4.calls_to("SendToProxy"))
			assert.truthy(find(lines, 'P.colors(link, on, off, current): a link id and colours as "rrggbb"'))
		end)

		it("P.notify and P.speed send notifications", function()
			local env, c4 = load_probe()
			env.P.notify(5001, "PRESET_SPEED", { SPEED = 4 })
			env.P.notify(5001, "ON")
			env.P.speed(2)
			env.P.speed("x")
			assert.are.same({
				{ 5001, "PRESET_SPEED", { SPEED = 4 }, "NOTIFY" },
				{ 5001, "ON", {}, "NOTIFY" },
				{ 5001, "CURRENT_SPEED", { SPEED = 2 }, "NOTIFY" },
			}, c4.calls_to("SendToProxy"))
		end)

		it("logs a send that fails instead of raising", function()
			local env, c4, lines = load_probe()
			function c4:SendToProxy()
				error("refused")
			end
			env.P.speed(1)
			assert.truthy(find(lines, "C4:SendToProxy(5001, CURRENT_SPEED) failed"))
		end)

		it("P.keypad sends KEYPAD_BUTTON_ACTION: a tap is push then click, a hold push then release", function()
			local env, c4, lines = load_probe()
			env.P.keypad(1204, 3)
			assert.are.same({ { 1204, "KEYPAD_BUTTON_ACTION", { BUTTON_ID = 3, ACTION = 1 } } }, c4.calls_to("SendToDevice"))
			assert.are.equal(1, fire(c4, 150))
			env.P.keypad(1204, 3, "hold")
			assert.are.equal(1, fire(c4, 1500))
			env.P.keypad(1204, 3, "release")
			env.P.keypad(1204, 3, 3)
			env.P.keypad(1204, 4, "click", "BUTTON ID")
			env.P.keypad(1204, 3, "wiggle")
			env.P.keypad("keypad", 3)
			local sent = {}
			for _, args in ipairs(c4.calls_to("SendToDevice")) do
				sent[#sent + 1] = args[3]
			end
			assert.are.same({
				{ BUTTON_ID = 3, ACTION = 1 }, { BUTTON_ID = 3, ACTION = 2 },
				{ BUTTON_ID = 3, ACTION = 1 }, { BUTTON_ID = 3, ACTION = 0 },
				{ BUTTON_ID = 3, ACTION = 0 }, { BUTTON_ID = 3, ACTION = 3 },
				{ ["BUTTON ID"] = 4, ACTION = 2 },
			}, sent)
			assert.truthy(find(lines, "sent SendToDevice(1204, KEYPAD_BUTTON_ACTION, {ACTION=1, BUTTON_ID=3})"))
			assert.truthy(find(lines, "P.keypad: the action wiggle is none of"))
		end)

		it("P.vars reads the fan proxy's variables, P.watch and P.unwatch listen to them", function()
			local env, c4, lines = load_probe()
			function c4:GetBoundConsumerDevices(device, binding)
				record(c4, "GetBoundConsumerDevices", device, binding)
				return binding == 5001 and { [3001] = "MF Probe (delete after M1)" } or nil
			end
			function c4:GetDeviceVariables(id)
				record(c4, "GetDeviceVariables", id)
				return { [1000] = { name = "IS_ON", value = "0" }, [1001] = { name = "CURRENT_SPEED", value = "2" } }
			end
			env.P.vars()
			env.P.watch(5001, 1000, "1001")
			env.P.unwatch(5001, 1001)
			env.P.vars(5002)
			assert.are.same({ { 15, 5001 }, { 15, 5001 }, { 15, 5001 }, { 15, 5002 } }, c4.calls_to("GetBoundConsumerDevices"))
			assert.are.same({ { 3001 } }, c4.calls_to("GetDeviceVariables"))
			assert.truthy(find(lines, "C4:GetDeviceVariables(3001) (fan proxy):"))
			assert.truthy(find(lines, '  1001.name = "CURRENT_SPEED"'))
			assert.are.same({ { 3001, 1000 }, { 3001, 1001 } }, c4.calls_to("RegisterVariableListener"))
			assert.are.same({ { 3001, 1001 } }, c4.calls_to("UnregisterVariableListener"))
			assert.truthy(find(lines, "P.vars: no device for 5002"))
		end)

		it("P.help lists the helpers", function()
			local env, _, lines = load_probe()
			env.P.help()
			for _, name in ipairs({ "P.led(", "P.colors(", "P.notify(", "P.speed(", "P.keypad(", "P.mdns(", "P.vars(",
				"P.watch(", "P.dump(", "P.history(" }) do
				assert.truthy(find(lines, name), name)
			end
		end)
	end)

	describe("DNS", function()
		local dns = load_probe().P.dns

		it("builds the PTR question byte for byte, QM and QU", function()
			assert.are.equal(expected_query(0x4D01, false), dns.query("_easylink._tcp.local", 12, { id = 0x4D01 }))
			assert.are.equal(expected_query(7, true), dns.query("_easylink._tcp.local", 12, { id = 7, qu = true }))
			assert.are.equal("\5local\0", dns.encode_name("local."))
			assert.has_error(function()
				dns.encode_name(string.rep("a", 64) .. ".local")
			end)
		end)

		it("reads the fan's answer: PTR, SRV, TXT and A, through compressed names", function()
			local msg = assert(dns.parse(fan_answer()))
			assert.are.equal(0, msg.id)
			assert.is_true(msg.qr)
			assert.is_true(msg.aa)
			assert.are.same({ 0, 1, 0, 3 }, msg.counts)
			assert.are.equal(0, msg.trailing)
			local ptr = msg.answers[1]
			assert.are.equal("_easylink._tcp.local", ptr.name)
			assert.are.equal(12, ptr.type)
			assert.are.equal("MF_Fan_005301._easylink._tcp.local", ptr.target)
			assert.is_false(ptr.flush)
			local srv, txt, a = msg.additionals[1], msg.additionals[2], msg.additionals[3]
			assert.are.equal(80, srv.port)
			assert.are.equal("MF_Fan_005301.local", srv.target)
			assert.is_true(srv.flush)
			assert.are.same({ "Protocol=com.modernforms.fan", "MAC=00:00:5E:00:53:01", "Firmware Rev=02.00.0052" },
				txt.strings)
			assert.are.equal("MF_Fan_005301.local", a.name)
			assert.are.equal("10.0.2.151", a.address)
		end)

		it("reads a legacy unicast answer, which repeats the question and the query's id", function()
			local msg = assert(dns.parse(fan_answer({ question = true, id = 0x4D01 })))
			assert.are.equal(0x4D01, msg.id)
			assert.are.same({ { name = "_easylink._tcp.local", type = 12, class = 1, qu = false } }, msg.questions)
			assert.are.equal("MF_Fan_005301._easylink._tcp.local", msg.answers[1].target)
			assert.are.equal("10.0.2.151", msg.additionals[3].address)
		end)

		it("describes the answer with the MAC cut to its last four hex digits", function()
			local text = table.concat(dns.describe(assert(dns.parse(fan_answer()))), "\n")
			assert.truthy(text:find("AN _easylink._tcp.local PTR IN ttl=4500 -> MF_Fan_xx5301._easylink._tcp.local", 1,
				true))
			assert.truthy(text:find("SRV IN flush ttl=120 priority=0 weight=0 port=80 target=MF_Fan_xx5301.local", 1,
				true))
			assert.truthy(text:find('"MAC=xx:xx:xx:xx:53:01" "Firmware Rev=02.00.0052"', 1, true))
			assert.truthy(text:find("AR MF_Fan_xx5301.local A IN flush ttl=120 10.0.2.151", 1, true))
			assert.falsy(text:find("005301", 1, true))
		end)

		it("dumps the hex with names redacted and address bytes hidden", function()
			local datagram = fan_answer({ mac = "00005E005301" })
			local lines = dns.hexdump(datagram, assert(dns.parse(datagram)))
			assert.are.equal(math.ceil(#datagram / 16), #lines)
			local hex, chars = {}, {}
			for _, line in ipairs(lines) do
				local offset, bytes, ascii = line:match("^(%x%x%x%x)  (.-)%s*  |(.*)|$")
				assert.truthy(offset, line)
				hex[#hex + 1], chars[#chars + 1] = bytes, ascii
			end
			local all_hex, all_chars = table.concat(hex, " "), table.concat(chars)
			assert.truthy(all_chars:find("MF_Fan_xx5301", 1, true))
			assert.truthy(all_chars:find("MAC=xxxxxxxx5301", 1, true))
			assert.falsy(all_chars:find("005301", 1, true))
			assert.falsy(all_hex:find("30 30 35 33 30 31", 1, true)) -- "005301" in hex
			assert.truthy(all_hex:find("-- -- -- --", 1, true))
			assert.falsy(all_hex:find("0a 00 02 97", 1, true))
			assert.are.equal("0000  00 00 84 00 00 00 00 01 00 00 00 03 09 5f 65 61  |............._ea|", lines[1])
		end)

		it("redacts MAC-like text only", function()
			assert.are.equal("xx:xx:xx:xx:53:01 xx-xx-xx-xx-53-01", dns.redact_text("00:00:5E:00:53:01 00-00-5e-00-53-01"))
			assert.are.equal("MF_xxxxxxxx5301 MF_Fan_xx5301 WAC Windermier Fan#xx5301",
				dns.redact_text("MF_00005E005301 MF_Fan_005301 WAC Windermier Fan#005301"))
			assert.are.equal("ff0000 #0000ff 3.4.3.746094 SPEED=4 1204",
				dns.redact_text("ff0000 #0000ff 3.4.3.746094 SPEED=4 1204"))
			local once = dns.redact_text("MAC=00:00:5E:00:53:01 MF_00005E005301")
			assert.are.equal(once, dns.redact_text(once))
		end)

		it("never raises on a broken datagram", function()
			local header = u16(0) .. u16(0) .. u16(1) .. u16(0) .. u16(0) .. u16(0)
			local cases = {
				[""] = "shorter than a DNS header",
				[string.rep("\0", 11)] = "shorter than a DNS header",
				[header] = "the datagram ends",
				[header .. pointer(12) .. u16(12) .. u16(1)] = "compression pointers",
				[header .. "\64abc"] = "label type 0x40",
				[header .. "\9_easy"] = "a label runs past the end",
				[u16(0) .. u16(0x8400) .. u16(0) .. u16(1) .. u16(0) .. u16(0) .. "\0" .. u16(16) .. u16(1) .. u32(1)
					.. u16(10) .. "\5ab"] = "record data runs past the end",
				[u16(0) .. u16(0x8400) .. u16(0) .. u16(1) .. u16(0) .. u16(0) .. "\0" .. u16(16) .. u16(1) .. u32(1)
					.. u16(3) .. "\5abcdef"] = "a TXT string runs past its record",
			}
			for datagram, why in pairs(cases) do
				local msg, err = dns.parse(datagram)
				assert.is_nil(msg)
				assert.truthy(err:find(why, 1, true), why .. " / " .. tostring(err))
			end
			assert.are.same({ nil, "not a string" }, { dns.parse(nil) })
		end)
	end)

	describe("K10, the mDNS run", function()
		local function network(c4)
			local out = {}
			for _, call in ipairs(c4.calls) do
				local name = call.name
				if name == "CreateNetworkConnection" or name == "NetPortOptions" or name == "NetConnect"
					or name == "NetDisconnect" or name == "SendToNetwork" then
					out[#out + 1] = { name, unpack(call.args, 1, 4) }
				end
			end
			return out
		end

		it("asks over MULTICAST, then over UDP with MIRROR_UDP_PORT off, 3 s each", function()
			local env, c4, lines = load_probe()
			env.P.mdns()
			assert.are.same({
				{ "CreateNetworkConnection", 6001, "224.0.0.251" },
				{ "NetConnect", 6001, 5353, "MULTICAST" },
			}, network(c4))
			-- ONLINE sends the first query at once (the 1 s wait is cancelled).
			env.OnConnectionStatusChanged(6001, 5353, "ONLINE")
			assert.are.same({ "SendToNetwork", 6001, 5353, expected_query(0x4D01, false) }, network(c4)[3])
			assert.are.equal(1, fire(c4, 1000))
			assert.are.same({ "SendToNetwork", 6001, 5353, expected_query(0x4D02, false) }, network(c4)[4])
			-- What arrives: our own query looped back, the fan's answer, another device's.
			env.ReceivedFromNetwork(6001, 5353, expected_query(0x4D01, false))
			env.ReceivedFromNetwork(6001, 5353, fan_answer())
			env.ReceivedFromNetwork(6001, 5353, other_answer())
			env.ReceivedFromNetwork(6001, 5353, "garbage")
			assert.are.equal(1, fire(c4, 3000))
			assert.are.same({ "NetDisconnect", 6001, 5353 }, network(c4)[5])
			assert.truthy(find(lines, "mDNS MULTICAST: the window is over; 2 queries sent, 4 datagram(s) received: "
				.. "1 own query, 1 answer(s) about _easylink._tcp.local, 1 other, 1 unparsed"))
			-- Then UDP, after a short gap; no ONLINE comes, so it sends anyway.
			assert.are.equal(1, fire(c4, 500))
			assert.are.same({
				{ "CreateNetworkConnection", 6002, "224.0.0.251" },
				{ "NetPortOptions", 6002, 5353, "UDP", { MIRROR_UDP_PORT = false } },
				{ "NetConnect", 6002, 5353, "UDP" },
			}, { network(c4)[6], network(c4)[7], network(c4)[8] })
			assert.are.equal(1, fire(c4, 1000))
			assert.truthy(find(lines, "mDNS UDP: no ONLINE within 1 s, sending anyway; listening for 3 s"))
			assert.are.same({ "SendToNetwork", 6002, 5353, expected_query(0x4D03, false) }, network(c4)[9])
			env.ReceivedFromNetwork(6002, 5353, fan_answer({ question = true, id = 0x4D03 }))
			assert.are.equal(1, fire(c4, 1000))
			assert.are.equal(1, fire(c4, 3000))
			assert.are.same({ "NetDisconnect", 6002, 5353 }, network(c4)[11])
			assert.truthy(find(lines, "mDNS UDP: the window is over; 2 queries sent, 1 datagram(s) received: "
				.. "0 own queries, 1 answer(s) about _easylink._tcp.local, 0 other, 0 unparsed"))
			assert.truthy(find(lines, "mDNS probe done"))
			assert.are.same({}, c4.active_timers())
		end)

		it("prints the fan's answer decoded and as hex, and nothing of other devices' traffic", function()
			local env, _, lines = load_probe()
			env.P.mdns("MULTICAST")
			env.OnConnectionStatusChanged(6001, 5353, "ONLINE")
			env.ReceivedFromNetwork(6001, 5353, fan_answer(), "10.0.2.151")
			env.ReceivedFromNetwork(6001, 5353, other_answer())
			env.ReceivedFromNetwork(6001, 5353, expected_query(0x4D01, false))
			assert.truthy(find(lines, "ReceivedFromNetwork binding=6001 (mDNS MULTICAST) port=5353 bytes="))
			assert.truthy(find(lines, " from=10.0.2.151"))
			assert.truthy(find(lines, "  AR MF_Fan_xx5301.local A IN flush ttl=120 10.0.2.151"))
			assert.truthy(find(lines, "  0000  00 00 84 00"))
			assert.truthy(find(lines, "  other mDNS traffic, names not logged: id=0x0000 response qd=0 an=1 ns=0 ar=0 "
				.. "types=PTR"))
			assert.truthy(find(lines, "  our own query, looped back"))
			for _, line in ipairs(lines) do
				assert.falsy(line:find("Example Speaker", 1, true), line)
				assert.falsy(line:find("_airplay", 1, true), line)
				assert.falsy(line:find("005301", 1, true), line)
				assert.falsy(line:find("00:00:5E", 1, true), line)
			end
		end)

		it("UDP_MIRROR sends from 5353 too, and qu sets the unicast-response bit", function()
			local env, c4 = load_probe()
			env.P.mdns("udp_mirror", true)
			env.OnConnectionStatusChanged(6003, 5353, "ONLINE")
			assert.are.same({
				{ "CreateNetworkConnection", 6003, "224.0.0.251" },
				{ "NetPortOptions", 6003, 5353, "UDP", { MIRROR_UDP_PORT = true } },
				{ "NetConnect", 6003, 5353, "UDP" },
				{ "SendToNetwork", 6003, 5353, expected_query(0x4D01, true) },
			}, network(c4))
		end)

		it("runs one probe at a time, refuses an unknown mode, and makes each binding once", function()
			local env, c4, lines = load_probe()
			env.P.mdns("bogus")
			assert.truthy(find(lines, "mDNS: the mode bogus is none of MULTICAST, UDP, UDP_MIRROR or ALL"))
			env.P.mdns("MULTICAST")
			env.P.mdns("UDP")
			assert.truthy(find(lines, "mDNS: a probe is still running"))
			env.OnConnectionStatusChanged(6001, 5353, "ONLINE")
			fire(c4, 1000)
			fire(c4, 3000)
			env.P.mdns("MULTICAST")
			assert.are.equal(1, #c4.calls_to("CreateNetworkConnection"))
			assert.are.equal(2, #c4.calls_to("NetConnect"))
		end)

		it("logs a refused connection and goes on to the next way", function()
			local env, c4, lines = load_probe()
			function c4:CreateNetworkConnection(binding)
				if binding == 6001 then
					error("no multicast here")
				end
				record(c4, "CreateNetworkConnection", binding)
			end
			env.P.mdns()
			assert.truthy(find(lines, "C4:CreateNetworkConnection failed"))
			assert.truthy(find(lines, "mDNS MULTICAST: no connection; 0 queries sent"))
			assert.are.equal(1, fire(c4, 500))
			assert.are.same({ { 6002 } }, c4.calls_to("CreateNetworkConnection"))
		end)

		it("is stopped by OnDriverDestroyed: the connection closed, no timer left", function()
			local env, c4, lines = load_probe()
			env.P.mdns()
			env.OnConnectionStatusChanged(6001, 5353, "ONLINE")
			env.P.keypad(1204, 3)
			env.OnDriverDestroyed("DIT_UPDATING")
			assert.are.same({ { 6001, 5353 } }, c4.calls_to("NetDisconnect"))
			assert.truthy(find(lines, "mDNS MULTICAST: stopped"))
			assert.are.same({}, c4.active_timers())
		end)

		it("logs datagrams outside a window, the first 20, then counts them", function()
			local env, _, lines = load_probe()
			env.ReceivedFromNetwork(6002, 5353, fan_answer())
			assert.truthy(find(lines, "ReceivedFromNetwork binding=6002 (mDNS UDP) port=5353 bytes=197 (outside a probe "
				.. "window)"))
			assert.truthy(find(lines, "  AN _easylink._tcp.local PTR IN ttl=4500 -> MF_Fan_xx5301._easylink._tcp.local"))
			for _ = 1, 24 do
				env.ReceivedFromNetwork(6001, 5353, other_answer())
			end
			assert.are.equal(20, count_lines(lines, "ReceivedFromNetwork binding="))
			assert.are.equal(1, count_lines(lines, "more than 20 datagrams outside a probe window"))
			env.P.dump()
			assert.truthy(find(lines, "mDNS: idle; 25 datagram(s) outside a probe window since the last run"))
			-- A new run logs again.
			env.P.mdns("MULTICAST")
			env.ReceivedFromNetwork(6002, 5353, other_answer())
			assert.are.equal(21, count_lines(lines, "ReceivedFromNetwork binding="))
		end)
	end)

	describe("the actions", function()
		it("Run mDNS Probe starts K10", function()
			local env, c4 = load_probe()
			env.ExecuteCommand("LUA_ACTION", { ACTION = "Run mDNS Probe" })
			assert.are.same({ { 6001, "224.0.0.251" } }, c4.calls_to("CreateNetworkConnection"))
		end)

		it("Dump State prints the driver, the proxies, the bindings and the counts", function()
			local env, c4, lines = load_probe()
			local name = "MF Probe (delete after M1)"
			local bound = { [5001] = { [3001] = name }, [5002] = { [3002] = name }, [300] = { [1204] = "Keypad" } }
			function c4:GetBoundConsumerDevices(_, binding)
				return bound[binding]
			end
			function c4:GetProxyDevices()
				return "3001,3002"
			end
			function c4:GetBindingsByDevice(id)
				return id == 3001 and { [1] = { bindingid = 301, name = "Level 1", class = "BUTTON_LINK" } } or {}
			end
			env.ReceivedFromProxy(300, "DO_PUSH", {})
			env.ExecuteCommand("LUA_ACTION", { ACTION = "Dump State" })
			for _, text in ipairs({
				"Dump State: begin",
				'driver version: "1"',
				"device id: 15",
				'  version = "3.4.2.746094"',
				'Echo LED On Press: "Off"',
				'C4:GetProxyDevices(): "3001,3002"',
				"C4:GetBoundConsumerDevices(device, 200 (light link, proxybindingid 5002)): nil",
				'  1204 = "Keypad"',
				"C4:GetBindingsByDevice(3001) (the fan proxy):",
				'  1.name = "Level 1"',
				"C4:GetBindingsByDevice(3002) (the light proxy):",
				"  (an empty table)",
				"calls into the probe: ExecuteCommand=1 ReceivedFromProxy=1",
				"mDNS: idle",
				"Dump State: end",
			}) do
				assert.truthy(find(lines, text), text)
			end
		end)

		it("Dump State logs what Director cannot answer and goes on", function()
			local env, _, lines = load_probe()
			env.ExecuteCommand("LUA_ACTION", { ACTION = "Dump_State" })
			assert.truthy(find(lines, "C4:GetProxyDevices() failed"))
			assert.truthy(find(lines, "C4:GetBindingsByDevice(device) failed"))
			assert.truthy(find(lines, "Dump State: end"))
			assert.are.equal(1, count_lines(lines, "Dump State: begin"))
		end)

		it("lists the mDNS bindings' addresses once they exist", function()
			local env, c4, lines = load_probe()
			function c4:GetBindingAddress(binding)
				return binding == 6001 and "224.0.0.251" or ""
			end
			env.P.mdns("MULTICAST")
			env.P.dump()
			assert.truthy(find(lines, 'C4:GetBindingAddress(6001) (mDNS MULTICAST): "224.0.0.251"'))
			assert.falsy(find(lines, "C4:GetBindingAddress(6002)"))
			assert.truthy(find(lines, "mDNS: MULTICAST running"))
		end)
	end)
end)
