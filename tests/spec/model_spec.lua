-- fan.model on a fake clock: the state model, the scheduler and the phases of
-- docs/v1-design.md sections 3.4 to 3.6, 4 and 6, with the research case ids
-- (ECM N/P/S/H/F/A, ECC R/D/C) in the test names. Everything the model touches
-- is a hand-made fake passed in (section 9.1): a virtual clock and timers, a
-- transport that keeps the real one's rules (one request in flight, the gap
-- after a result, an epoch bumped by set_address, an abandoned request never
-- calling back), a stand-in for fan/wire.lua that follows section 9.3, and a
-- store. The answers are decoded-JSON tables with the fan's own key names.

local model = require("fan.model")

local NIL = {} -- in a JSON override: remove the key

-- Virtual time ------------------------------------------------------------------

local function new_clock()
	local c = { ms = 0, base = 1700000000, timers = {}, ids = 0 }
	function c.now() return c.ms end
	function c.secs() return c.base + math.floor(c.ms / 1000) end
	function c.timer(delay, cb)
		c.ids = c.ids + 1
		local t = { id = c.ids, due = c.ms + delay, delay = delay, cb = cb }
		function t.Cancel() t.cancelled = true end
		c.timers[#c.timers + 1] = t
		return t
	end
	local function pending(t) return not t.cancelled and not t.fired end
	-- Moves time on, firing the timers that fall due in due order (ties by arming order),
	-- including the ones armed while it runs.
	function c.advance(ms)
		local target = c.ms + ms
		local live = {}
		for _, t in ipairs(c.timers) do
			if pending(t) then live[#live + 1] = t end
		end
		c.timers = live
		while true do
			local best
			for _, t in ipairs(c.timers) do
				if pending(t) and t.due <= target and (not best or t.due < best.due) then
					best = t
				end
			end
			if not best then break end
			c.ms = math.max(c.ms, best.due)
			best.fired = true
			best.cb()
		end
		c.ms = target
	end
	function c.active()
		local n = 0
		for _, t in ipairs(c.timers) do
			if pending(t) then n = n + 1 end
		end
		return n
	end
	-- Milliseconds until the next timer, nil with none.
	function c.next_due()
		local best
		for _, t in ipairs(c.timers) do
			if pending(t) and (not best or t.due < best) then best = t.due end
		end
		return best and (best - c.ms) or nil
	end
	return c
end

-- The transport's rules (section 9.4; fan/transport.lua) ------------------------------

local function new_transport(clock)
	local t = { epoch = 0, seq = 0, address = nil, sent = {}, addresses = {}, gap = false, stops = 0 }
	function t:set_address(addr)
		self.epoch = self.epoch + 1
		self.address = addr
		self.stopped = false
		self.addresses[#self.addresses + 1] = addr or false
		if self.inflight then
			self.inflight.abandoned = true
			self.abandoned = self.inflight
			self.inflight = nil
		end
		return true
	end
	function t:busy() return self.inflight ~= nil or self.gap end
	function t:stop()
		self.stopped = true
		self.stops = self.stops + 1
		self.inflight, self.gap = nil, false
	end
	function t:send(req, cb)
		if self.stopped then return nil, "stopped" end
		if not self.address then return nil, "no address" end
		if self:busy() then return nil, "busy" end
		self.seq = self.seq + 1
		local entry = { seq = self.seq, epoch = self.epoch, kind = req.kind, req = req, cb = cb }
		self.inflight = entry
		self.sent[#self.sent + 1] = {
			seq = self.seq, kind = req.kind, path = req.path, body = req.body, timeout = req.timeout,
			address = self.address, epoch = self.epoch,
		}
		return self.seq
	end
	-- The test answers the request in flight. The slot is free and in its gap before the
	-- callback runs; the gap ends (and on_idle follows) GAP_MS after it returns.
	function t:respond(result)
		local entry = assert(self.inflight, "no request in flight")
		self.inflight = nil
		result.seq, result.epoch, result.kind = entry.seq, entry.epoch, entry.kind
		self.gap = true
		entry.cb(result)
		clock.timer(model.GAP_MS, function()
			self.gap = false
			if self.on_idle then self.on_idle() end
		end)
	end
	-- A request given up earlier is answered at last: the real transport drops it silently.
	function t:late_answer(result)
		local entry = assert(self.abandoned, "no abandoned request")
		self.abandoned = nil
		result.seq, result.epoch, result.kind = entry.seq, entry.epoch, entry.kind
		return entry, result
	end
	return t
end

-- fan/wire.lua as section 9.3 states it, as much as the model uses --------------------

local function new_wire()
	local w = {
		PATH = "/mf", G4_PATH = "/device",
		QUERY_STATE = '{"queryDynamicShadowData":1}', QUERY_INFO = '{"queryStaticShadowData":1}',
		QUERY_G4 = '{"query":true}', REBOOT = '{"reboot":true}',
	}
	local function is_int(v, lo, hi) return type(v) == "number" and v >= lo and v <= hi and v == math.floor(v) end
	function w.body(f)
		local n = 0
		for k in pairs(f) do
			n = n + 1
			if not ({ fan_on = 1, speed = 1, direction = 1, level = 1, light_on = 1, away = 1, learning = 1 })[k] then
				return nil, "unknown"
			end
		end
		if f.fan_on ~= nil then
			if f.fan_on == false then
				return n == 1 and '{"fanOn":false}' or nil, "mix"
			end
			if n ~= 2 or not is_int(f.speed, 1, 6) then return nil, "mix" end
			return string.format('{"fanOn":true,"fanSpeed":%d}', f.speed)
		elseif f.speed ~= nil then
			return nil, "mix"
		elseif f.direction ~= nil then
			if n ~= 1 or (f.direction ~= "forward" and f.direction ~= "reverse") then return nil, "mix" end
			return string.format('{"fanDirection":"%s"}', f.direction)
		elseif f.level ~= nil then
			if n ~= 1 or not is_int(f.level, 1, 100) then return nil, "mix" end
			return string.format('{"lightBrightness":%d}', f.level)
		elseif f.light_on ~= nil then
			if n ~= 1 then return nil, "mix" end
			return f.light_on and '{"lightOn":true}' or '{"lightOn":false}'
		elseif f.away == false and n == 1 then
			return '{"awayModeEnabled":false}'
		elseif f.learning == false and n == 1 then
			return '{"adaptiveLearning":false}'
		end
		return nil, "empty"
	end
	function w.mac12(text)
		local hex = tostring(text or ""):gsub("[^%x]", "")
		return #hex == 12 and hex:upper() or nil
	end
	function w.same_fan(pin, id)
		if type(pin) == "table" then pin = pin.client_id end
		if type(id) == "table" then id = id.client_id end
		return type(pin) == "string" and type(id) == "string" and pin:lower() == id:lower()
	end
	function w.ipv4(text)
		local a, b, c, d = tostring(text or ""):match("^%s*(%d+)%.(%d+)%.(%d+)%.(%d+)%s*$")
		if not a then return nil end
		for _, p in ipairs({ a, b, c, d }) do
			if tonumber(p) > 255 then return nil end
		end
		return table.concat({ a, b, c, d }, ".")
	end
	function w.is_g4(obj)
		return type(obj) == "table" and tostring(obj.systemType):find("fan_g4", 1, true) ~= nil
	end
	-- The dynamic answer as section 4.1's fields; out-of-range values clamped and named in `adjusted`.
	function w.state(obj)
		if type(obj) ~= "table" or type(obj.clientId) ~= "string" then return nil, "json" end
		local adjusted = {}
		local st = {
			client_id = obj.clientId, fan_on = obj.fanOn, direction = obj.fanDirection, light_on = obj.lightOn,
			wind = obj.wind, wind_speed = obj.windSpeed, away = obj.awayModeEnabled, learning = obj.adaptiveLearning,
			fan_timer = obj.fanTimer, light_timer = obj.lightTimer, fan_sleep_timer = obj.fanSleepTimer,
			light_sleep_timer = obj.lightSleepTimer, user_data = obj.userData, adjusted = adjusted,
		}
		if type(obj.schedule) == "string" then st.schedule_set = obj.schedule:find("%S") ~= nil end
		local s = obj.fanSpeed
		if type(s) == "number" then
			if s >= 1 and s <= 6 then
				st.speed = s
			elseif not (s == 0 and obj.fanOn == false) then
				adjusted[#adjusted + 1] = "fanSpeed " .. s
				st.speed = s > 6 and 6 or 1
			end
		end
		local l = obj.lightBrightness
		if type(l) == "number" then
			if l >= 1 and l <= 100 then
				st.level = l
			elseif l > 100 then
				adjusted[#adjusted + 1] = "lightBrightness " .. l
				st.level = 100
			elseif obj.lightOn == true then
				adjusted[#adjusted + 1] = "lightBrightness " .. l
				st.level = 1
			end
		end
		if obj.fanTimer ~= nil or obj.lightTimer ~= nil then
			st.generation = "3"
		elseif obj.fanSleepTimer ~= nil or obj.lightSleepTimer ~= nil then
			st.generation = "1/2"
		end
		return st
	end
	function w.info(obj)
		if type(obj) ~= "table" or type(obj.clientId) ~= "string" then return nil, "json" end
		local light = type(obj.lightType) == "string" and obj.lightType or nil
		return {
			client_id = obj.clientId, mac = w.mac12(obj.mac), fan_type = obj.fanType, light_type = light,
			has_light = light ~= nil and light:find("%S") ~= nil, motor_type = obj.fanMotorType,
			firmware = obj.firmwareVersion, mcu_firmware = obj.mainMcuFirmwareVersion, brand = obj.brand,
		}
	end
	return w
end

-- The fan's answers (M0's shapes, placeholders only) ------------------------------------

local function with(base, over)
	for k, v in pairs(over or {}) do
		if v == NIL then base[k] = nil else base[k] = v end
	end
	return base
end

local function state_json(over)
	return with({
		clientId = "MF_00005E005301", cloudPort = 8883, lightOn = false, fanOn = true, lightBrightness = 100,
		fanSpeed = 1, fanDirection = "forward", wind = false, windSpeed = 1, awayModeEnabled = false,
		adaptiveLearning = false, schedule = "", fanTimer = 0, lightTimer = 0, userData = "none",
	}, over)
end

local function info_json(over)
	return with({
		clientId = "MF_00005E005301", mac = "00:00:5e:00:53:01", lightType = "F4IN-120V-R1-30", fanType = "1811-5-54",
		fanMotorType = "DC125X20", brand = 1, firmwareVersion = "02.00.0052", mainMcuFirmwareVersion = "03.00.0000",
	}, over)
end

local OTHER = { clientId = "MF_00005E005302", mac = "00:00:5e:00:53:02" }

local PIN = {
	client_id = "MF_00005E005301", mac = "00005E005301", generation = "3", address = "10.0.2.151", learned = 1,
}

-- The harness ---------------------------------------------------------------------------

local LISTENER = { "settled", "idle", "shown", "phase", "info", "seen", "outside", "automations", "result" }

local function new_harness(opts)
	opts = opts or {}
	local h = { events = {}, logs = {}, writes = {}, data = opts.store or {}, unknown = {} }
	h.clock = new_clock()
	h.transport = new_transport(h.clock)
	h.wire = new_wire()
	h.state, h.info = state_json(), info_json()
	-- an event the model emits that section 9.5 does not list lands in h.unknown
	local listener = setmetatable({}, { __index = function(_, name)
		h.unknown[#h.unknown + 1] = tostring(name)
	end })
	for _, name in ipairs(LISTENER) do
		listener[name] = function(a, b, c)
			h.events[#h.events + 1] = { name = name, a, b, c }
		end
	end
	for name, fn in pairs(opts.listener or {}) do listener[name] = fn end
	h.store = {
		get = function(k) return h.data[k] end,
		set = function(k, v) h.data[k] = v; h.writes[#h.writes + 1] = { k, v } end,
	}
	local logger = {}
	for _, level in ipairs({ "debug", "info", "warn", "error", "always" }) do
		logger[level] = function(fmt, ...)
			local ok, text = pcall(string.format, fmt, ...)
			h.logs[#h.logs + 1] = { level = level, text = ok and text or tostring(fmt) }
		end
	end
	h.log = logger
	h.m = model.new({
		transport = h.transport, wire = h.wire, now = h.clock.now, clock = h.clock.secs, timer = h.clock.timer,
		store = h.store, log = logger, listener = listener, date = function() return "2026-10-27" end,
	})
	h.transport.on_idle = function() h.m:on_idle() end
	return h
end

local function pending(h) return h.transport.inflight end

-- Answers the request in flight.
local function ok(h, json, ms) h.transport:respond({ ok = true, code = 200, json = json, ms = ms or 300 }) end
local function fail(h, err, code, ms) h.transport:respond({ ok = false, err = err, code = code, ms = ms or 5000 }) end
local function gap(h) h.clock.advance(model.GAP_MS) end
local function answer(h) -- the quiet fan: whatever was asked, h.state / h.info
	local p = assert(pending(h), "nothing in flight")
	ok(h, p.kind == "info" and h.info or h.state)
end

-- The events of one name, as { a, b, c } lists in order; take() also clears the whole log.
local function events(h, name)
	local out = {}
	for _, e in ipairs(h.events) do
		if e.name == name then out[#out + 1] = e end
	end
	return out
end
local function names(h)
	local out = {}
	for _, e in ipairs(h.events) do out[#out + 1] = e.name end
	return out
end
local function clear(h) h.events = {} end

local function bodies(h)
	local out = {}
	for _, s in ipairs(h.transport.sent) do out[#out + 1] = s.body end
	return out
end
local function kinds(h)
	local out = {}
	for _, s in ipairs(h.transport.sent) do out[#out + 1] = s.kind end
	return out
end
local function last_sent(h) return h.transport.sent[#h.transport.sent] end

local function logged(h, level, pattern)
	for _, l in ipairs(h.logs) do
		if (level == nil or l.level == level) and l.text:find(pattern, 1, true) then return true end
	end
	return false
end

-- The first contact: the info read, then the state read.
local function contact(h, state, info)
	assert(pending(h) and pending(h).kind == "info", "the contact starts with the info read")
	ok(h, info or h.info)
	gap(h)
	assert(pending(h) and pending(h).kind == "state", "the info read is followed by the state read")
	ok(h, state or h.state)
end

local function online(h, state, info)
	assert(h.m:start("10.0.2.151") == nil)
	contact(h, state, info)
	gap(h)
	return h
end

-- A fan on a pinned address with the contact done, past the fast window.
local function steady(h, state, info)
	-- the quiet fan keeps answering with the given state, not the default one
	h.state, h.info = state or h.state, info or h.info
	online(h, state, info)
	-- the fast window is 20 s of 2 s polls; after it the poll is armed for the interval
	for _ = 1, 30 do
		if h.clock.next_due() > model.FAST_POLL_MS then break end
		h.clock.advance(h.clock.next_due())
		answer(h)
		gap(h)
	end
	assert(h.clock.next_due() == model.POLL_DEFAULT_S * 1000 - model.GAP_MS,
		"the quiet poll is armed: " .. tostring(h.clock.next_due()))
	clear(h)
	return h
end

-- Runs the quiet fan for `ms`, answering every request, jumping from timer to timer.
local function run(h, ms)
	local stop = h.clock.ms + ms
	while h.clock.ms < stop do
		local due = h.clock.next_due()
		if due == nil or h.clock.ms + due > stop then
			h.clock.advance(stop - h.clock.ms)
			break
		end
		h.clock.advance(due)
		if pending(h) then answer(h) end
	end
end

-- The next quiet poll is due: the request goes out, and the test answers it with `json`
-- after `took` ms (the default is no time at all).
local function poll(h, json, took)
	h.clock.advance(h.clock.next_due())
	assert(pending(h), "a poll should be in flight")
	if took then h.clock.advance(took) end
	ok(h, json or (pending(h).kind == "info" and h.info or h.state), took)
end

-- Poll, time out after 5 s: one failure.
local function poll_fail(h, err, code)
	h.clock.advance(h.clock.next_due())
	assert(pending(h), "a request should be in flight")
	h.clock.advance(5000)
	fail(h, err or "timeout", code, 5000)
end

-- The next request goes out and times out after 5 s; the gap passes. Returns when it was sent.
local function attempt(h, err, code)
	h.clock.advance(h.clock.next_due())
	assert(pending(h), "a request should be in flight")
	local sent_at = h.clock.ms
	h.clock.advance(5000)
	fail(h, err or "timeout", code, 5000)
	gap(h)
	return sent_at
end

-- Three timeouts in a row from a quiet online fan: offline.
local function went_offline(h)
	attempt(h)
	attempt(h)
	attempt(h)
	assert.equal("offline", h.m:phase())
	return h
end

describe("fan.model", function()
	describe("construction and the constants (section 3.4)", function()
		it("holds the contract's constants", function()
			assert.equal(15, model.POLL_DEFAULT_S)
			assert.equal(10, model.POLL_MIN_S)
			assert.equal(120, model.POLL_MAX_S)
			assert.equal(2000, model.FAST_POLL_MS)
			assert.equal(20000, model.FAST_WINDOW_MS)
			assert.equal(250, model.GAP_MS)
			assert.equal(2500, model.SETTLE_MS)
			assert.same({ 10, 20, 40, 60 }, model.BACKOFF_S)
			assert.equal(3, model.OFFLINE_AFTER)
			assert.equal(60, model.IDENTITY_POLL_S)
			assert.equal(120, model.REBOOT_WINDOW_S)
			assert.equal(10, model.REBOOT_POLL_S)
			assert.equal(21600, model.INFO_REFRESH_S)
			assert.equal(500, model.RAMP_STEP_MS)
		end)

		it("needs a transport, the wire module, now and a timer", function()
			local h = new_harness()
			local base = { transport = h.transport, wire = h.wire, now = h.clock.now, timer = h.clock.timer }
			assert.has_no.errors(function() model.new(base) end)
			for _, key in ipairs({ "transport", "wire", "now", "timer" }) do
				local opts = {}
				for k, v in pairs(base) do opts[k] = v end
				opts[key] = nil
				assert.has.errors(function() model.new(opts) end, "model.new needs " .. (key == "transport" and "a transport"
					or key == "wire" and "the wire module" or key .. "()"))
			end
		end)

		it("works with the defaults: no log, no listener, an in-memory store", function()
			local h = new_harness()
			local m = model.new({ transport = h.transport, wire = h.wire, now = h.clock.now, timer = h.clock.timer })
			assert.has_no.errors(function() m:start("10.0.2.151") end)
			assert.equal("waiting", m:phase())
		end)
	end)

	describe("start (late init): the addresses and the first phases (S1, S3, S4)", function()
		it("S1 an empty Fan Address leaves it unset: nothing sent, nothing known", function()
			local h = new_harness()
			assert.is_nil(h.m:start(""))
			local phase, detail = h.m:phase()
			assert.equal("unset", phase)
			assert.is_false(detail.online)
			assert.is_nil(detail.event)
			assert.same({}, h.transport.sent)
			assert.is_nil(h.m:confirmed())
			assert.is_nil(h.m:identity())
			assert.same({ false }, h.transport.addresses, "the transport is told there is no address")
			local e = events(h, "phase")
			assert.equal(1, #e)
			assert.equal("unset", e[1][1])
			assert.is_nil(e[1][3], "no old phase at start")
			assert.equal("unset", h.m:status_view().phase)
			assert.equal("", h.m:status_view().typed)
		end)

		it("6.1 unset sets the Online flag false without an event, and writes it", function()
			local h = new_harness({ store = { mf_online = true } })
			h.m:start("")
			local _, detail = h.m:phase()
			assert.is_false(detail.online)
			assert.is_nil(detail.event, "unset fires no Fan Offline")
			assert.same({ { "mf_online", false } }, h.writes)
		end)

		it("S3 text that is not an IPv4 address is refused and kept for the Status", function()
			local h = new_harness()
			assert.equal("invalid", h.m:start("fan.local"))
			assert.equal("unset", h.m:phase())
			assert.equal("fan.local", h.m:status_view().typed)
			assert.same({}, h.transport.sent)
			local ok_, why = h.m:want({ fan_on = false })
			assert.is_false(ok_)
			assert.equal("invalid address", why)
		end)

		it("S4 a valid address makes it wait and sends the info read first (D1)", function()
			local h = new_harness()
			assert.is_nil(h.m:start("  10.0.2.151 "))
			local phase, detail = h.m:phase()
			assert.equal("waiting", phase)
			assert.equal("10.0.2.151", detail.address)
			assert.is_nil(detail.online, "waiting leaves the Online variable alone")
			assert.is_nil(detail.event)
			assert.equal("10.0.2.151", h.transport.address)
			assert.equal(1, #h.transport.sent)
			local s = last_sent(h)
			assert.equal("info", s.kind)
			assert.equal("/mf", s.path)
			assert.equal(h.wire.QUERY_INFO, s.body)
			local e = events(h, "phase")[1]
			assert.equal("waiting", e[1])
			assert.same({ address = "10.0.2.151", since = h.clock.secs() }, e[2])
			assert.is_nil(e[3])
			assert.equal("10.0.2.151", h.m:status_view().address)
		end)

		it("loads the persisted identity, info and Online flag; the Fan ID row's pin is the fallback (D10)", function()
			local h = new_harness({ store = {
				mf_identity = { client_id = "MF_00005E005301", mac = "00005E005301", generation = "3", address = "10.0.2.151",
					learned = 5 },
				mf_info = { fan_type = "1811-5-54", light_type = "F4IN-120V-R1-30", motor_type = "DC125X20",
					firmware = "02.00.0052", mcu_firmware = "03.00.0000", firmware_since = "2026-10-20" },
				mf_online = true,
			} })
			h.m:start("10.0.2.151", { client_id = "MF_00005E005399", mac = "00005E005399" })
			assert.equal("MF_00005E005301", h.m:identity().client_id, "the store wins over the row")
			assert.equal("00005E005301", h.m:identity().mac)
			local info = h.m:info()
			assert.equal("02.00.0052", info.firmware)
			assert.is_true(info.has_light, "known before the first contact")
			assert.is_nil(info.has_wind, "unknown until a state is read")

			local h2 = new_harness()
			h2.m:start("10.0.2.151", { client_id = "MF_00005E005301", mac = "00005E005301" })
			assert.equal("MF_00005E005301", h2.m:identity().client_id)
			assert.is_nil(h2.m:info())
			assert.same({}, h2.writes, "a pin from the row is not stored before it is checked")
		end)
	end)

	describe("first contact (3.5, N10, L1, R6)", function()
		it("an info read, then a state read; the fan is learned, pinned and stored; every group is reported once", function()
			local h = new_harness()
			h.m:start("10.0.2.151")
			assert.same({}, events(h, "settled"), "R6: nothing of the fan's state before the first contact")
			ok(h, h.info)
			assert.same({}, events(h, "settled"), "the info alone reports nothing")
			gap(h)
			assert.equal("state", last_sent(h).kind)
			assert.equal(h.wire.QUERY_STATE, last_sent(h).body)
			ok(h, h.state)

			local settled = events(h, "settled")
			assert.equal(3, #settled)
			assert.same({ "fan", "direction", "light" }, { settled[1][1], settled[2][1], settled[3][1] })
			for _, e in ipairs(settled) do assert.equal("start", e[3]) end
			assert.equal(1, settled[1][2].speed)
			assert.is_true(settled[1][2].fan_on)
			assert.equal("forward", settled[2][2].direction)
			assert.equal(100, settled[3][2].level)
			assert.is_false(settled[3][2].light_on)

			local result = events(h, "result")
			assert.equal(1, #result)
			assert.equal("learned", result[1][1])
			assert.same({ client_id = "MF_00005E005301", generation = "3", address = "10.0.2.151", mac = "00005E005301" },
				result[1][2])

			local pin = h.m:identity()
			assert.equal("MF_00005E005301", pin.client_id)
			assert.equal("00005E005301", pin.mac)
			assert.equal("3", pin.generation)
			assert.equal("10.0.2.151", pin.address)
			assert.equal(h.clock.secs(), pin.learned)
			assert.same({ pin, h.m:info() }, { events(h, "info")[1][1], events(h, "info")[1][2] })
			assert.equal(1, #events(h, "info"))

			local phase = events(h, "phase")
			assert.equal("online", phase[#phase][1])
			assert.equal("waiting", phase[#phase][3])
			assert.is_true(phase[#phase][2].online)
			assert.equal("online", phase[#phase][2].event, "the flag was false: Fan Online fires")
			assert.equal(2, #events(h, "seen"))
			assert.equal(1, #events(h, "automations"))
		end)

		it("stores the identity, the model and the Online flag (section 8)", function()
			local h = online(new_harness())
			local data = h.data
			assert.same({ client_id = "MF_00005E005301", mac = "00005E005301", generation = "3", address = "10.0.2.151",
				learned = h.m:identity().learned }, data.mf_identity)
			assert.same({ fan_type = "1811-5-54", light_type = "F4IN-120V-R1-30", motor_type = "DC125X20",
				firmware = "02.00.0052", mcu_firmware = "03.00.0000", firmware_since = "2026-10-27" }, data.mf_info)
			assert.is_true(data.mf_online)
			assert.is_nil(data.mf_preset_speed, "the preset is the fan proxy's")
			local info = h.m:info()
			assert.is_true(info.has_light)
			assert.is_true(info.has_wind, "the wind key exists")
			assert.is_nil(info.firmware_was)
		end)

		it("opens the fast window on coming online: the first poll is 2 s after the contact", function()
			local h = online(new_harness())
			-- the state answer was 250 ms ago (online() waited out the gap)
			assert.equal(model.FAST_POLL_MS - model.GAP_MS, h.clock.next_due())
		end)

		it("the state is known afterwards; confirmed() has the fields of 4.1, shown() follows it", function()
			local h = online(new_harness(), state_json({ fanSpeed = 4, fanOn = true, lightOn = true, lightBrightness = 40,
				fanDirection = "reverse", wind = true, awayModeEnabled = true, userData = "ble" }))
			local st = h.m:confirmed()
			assert.is_true(st.fan_on)
			assert.equal(4, st.speed)
			assert.equal("reverse", st.direction)
			assert.is_true(st.light_on)
			assert.equal(40, st.level)
			assert.is_true(st.wind)
			assert.is_true(st.away)
			assert.equal("ble", st.user_data)
			assert.same({ fan_on = true, speed = 4, direction = "reverse", light_on = true, level = 40 }, h.m:shown())
			assert.is_true(h.m:status_view().known)
			assert.same({ fan_on = true, speed = 4, direction = "reverse", light_on = true, level = 40 },
				events(h, "shown")[1][1])
		end)

		it("a fan without a light kit: the light is not present (H4)", function()
			local h = online(new_harness(), nil, info_json({ lightType = "" }))
			local groups = {}
			for _, e in ipairs(events(h, "settled")) do groups[#groups + 1] = e[1] end
			assert.same({ "fan", "direction" }, groups)
			assert.is_false(h.m:info().has_light)
			assert.is_false(h.m:status_view().has_light)
			local took, why = h.m:want({ light_on = true, level = 40 })
			assert.is_false(took)
			assert.equal("no light kit", why)
			assert.is_nil(h.m:shown().light_on)
			assert.is_nil(h.m:confirmed().light_on, "the light fields are ignored")
		end)

		it("commands wanted during the contact wait for it and go after its state read (3.5)", function()
			local h = new_harness()
			h.m:start("10.0.2.151")
			assert.is_true(h.m:want({ fan_on = true, speed = 3 }))
			assert.same({ "info" }, kinds(h), "the info read first")
			ok(h, h.info)
			gap(h)
			assert.same({ "info", "state" }, kinds(h), "still no command: the state read first")
			ok(h, h.state)
			gap(h)
			assert.same({ "info", "state", "command" }, kinds(h))
			assert.equal('{"fanOn":true,"fanSpeed":3}', last_sent(h).body)
		end)

		it("P8 a command wanted during a contact is dropped, logged, when the contact fails", function()
			local h = new_harness()
			h.m:start("10.0.2.151")
			assert.is_true(h.m:want({ fan_on = true, speed = 3 }))
			fail(h, "timeout") -- the read that was in flight when the command came: not its try
			assert.is_true(h.m:busy("fan"), "the command waits for the contact, which goes at once")
			gap(h)
			assert.same({ "info", "info" }, kinds(h), "the forced attempt is the command's one try")
			fail(h, "timeout")
			assert.is_nil(h.m:shown().fan_on)
			assert.is_nil(h.m:shown().speed)
			assert.is_false(h.m:busy("fan"))
			assert.is_true(logged(h, "warn", "Fan not answering: speed 3 not sent"))
			assert.equal(1, #events(h, "idle"))
			gap(h)
			assert.same({ "info", "info" }, kinds(h), "nothing more until the backoff is over")
		end)

		it("V3/H3 a changed light kit is learned at a later contact and announced", function()
			local h = steady(new_harness())
			h.m:set_address("10.0.2.151")
			clear(h)
			contact(h, nil, info_json({ lightType = "" }))
			assert.is_false(h.m:info().has_light)
			assert.equal(1, #events(h, "info"))
			assert.is_true(logged(h, "warn", "The fan reports different static data: light kit F4IN-120V-R1-30 -> none"))
		end)

		it("H3 an unchanged contact says nothing about the static data", function()
			local h = steady(new_harness())
			h.m:set_address("10.0.2.151")
			contact(h)
			assert.is_false(logged(h, "warn", "different static data"))
			assert.same({}, events(h, "info"))
		end)
	end)
end)

describe("fan.model identity: another fan, Gen 4, not a fan (3.5, 3.6, N3, N4, N9, H2)", function()
	local function stored(over)
		local data = {
			mf_identity = { client_id = "MF_00005E005301", mac = "00005E005301", generation = "3", address = "10.0.2.151",
				learned = 5 },
			mf_info = { fan_type = "1811-5-54", light_type = "F4IN-120V-R1-30", motor_type = "DC125X20",
				firmware = "02.00.0052", mcu_firmware = "03.00.0000", firmware_since = "2026-10-20" },
			mf_online = true,
		}
		for k, v in pairs(over or {}) do data[k] = v end
		return data
	end

	it("N3 another fan answers a poll: foreign, its state is not applied, the last state is kept, 60 s polls", function()
		local h = steady(new_harness())
		poll(h, state_json({ clientId = "MF_00005E005302", fanSpeed = 5 }))
		local phase, detail = h.m:phase()
		assert.equal("foreign", phase)
		assert.equal("MF_00005E005302", detail.other_client_id)
		assert.equal("10.0.2.151", detail.address)
		local e = events(h, "phase")[1]
		assert.equal("foreign", e[1])
		assert.equal("online", e[3])
		assert.is_false(e[2].online)
		assert.equal("offline", e[2].event, "Fan Offline, as for offline (6.1)")
		assert.equal(1, h.m:confirmed().speed, "the other fan's state is not ours")
		assert.same({}, events(h, "settled"))
		assert.is_true(logged(h, "warn", "Another fan (...5302) answers at 10.0.2.151"))
		assert.is_false(logged(h, nil, "MF_00005E005302"), "the full id is never logged")
		assert.is_false(h.data.mf_online)
		assert.equal("MF_00005E005301", h.m:identity().client_id, "the pin stays")
		assert.equal("MF_00005E005302", h.m:status_view().other)

		local n = #h.transport.sent
		gap(h)
		h.clock.advance(59000)
		assert.equal(n, #h.transport.sent, "nothing for 60 s")
		h.clock.advance(1000)
		assert.equal(n + 1, #h.transport.sent)
		assert.equal("info", last_sent(h).kind, "the identity is read again with the static data")
	end)

	it("N3 commands are refused while foreign and nothing is ever sent but the identity read (V5)", function()
		local h = steady(new_harness())
		poll(h, state_json({ clientId = "MF_00005E005302" }))
		local wants = { { fan_on = true, speed = 2 }, { direction = "reverse" }, { light_on = true, level = 5 } }
		for _, fields in ipairs(wants) do
			local took, why = h.m:want(fields)
			assert.is_false(took)
			assert.equal("foreign", why)
		end
		run(h, 130000)
		for _, kind in ipairs(kinds(h)) do assert.is_truthy(kind == "state" or kind == "info") end
		for _, body in ipairs(bodies(h)) do assert.is_falsy(body:find("fanOn", 1, true)) end
	end)

	it("N3 the other fan staying: no new phase event and no new warning on each 60 s read", function()
		local h = steady(new_harness())
		poll(h, state_json({ clientId = "MF_00005E005302" }))
		gap(h)
		clear(h)
		local warns = #h.logs
		h.clock.advance(h.clock.next_due())
		ok(h, info_json(OTHER))
		assert.same({}, events(h, "phase"))
		assert.equal("foreign", h.m:phase())
		assert.equal(warns, #h.logs, "said once")
		gap(h)
		assert.equal(1, h.clock.next_due() > 59000 and 1 or 0, "armed again for 60 s")
	end)

	it("N3/R8 the right fan comes back: a contact, the differences reported with why online, Fan Online", function()
		local h = steady(new_harness())
		poll(h, state_json({ clientId = "MF_00005E005302" }))
		gap(h)
		h.clock.advance(h.clock.next_due())
		ok(h, h.info)
		gap(h)
		clear(h)
		ok(h, state_json({ fanSpeed = 5 }))
		local settled = events(h, "settled")
		assert.equal(1, #settled)
		assert.equal("fan", settled[1][1])
		assert.equal("online", settled[1][3])
		assert.same({}, events(h, "outside"), "a change made while it was away is not 'outside'")
		local phase = events(h, "phase")[1]
		assert.equal("online", phase[1])
		assert.equal("foreign", phase[3])
		assert.equal("online", phase[2].event)
		assert.is_true(h.data.mf_online)
		assert.same({}, events(h, "result"), "the same fan: nothing learned or moved")
	end)

	it("D10/D18 a restored project: the info read finds another fan, the pin is kept and nothing is sent", function()
		local h = new_harness({ store = stored() })
		h.m:start("10.0.2.151")
		ok(h, info_json(OTHER))
		assert.equal("foreign", h.m:phase())
		gap(h)
		assert.same({ "info" }, kinds(h), "no state read from the wrong fan")
		assert.equal("MF_00005E005301", h.data.mf_identity.client_id)
		local phase = events(h, "phase")
		assert.equal("offline", phase[#phase][2].event, "the persisted flag was on: Fan Offline")
	end)

	it("N9 the same client id with another MAC is another fan", function()
		local h = new_harness({ store = stored() })
		h.m:start("10.0.2.151")
		ok(h, info_json({ mac = "00:00:5e:00:53:99" }))
		assert.equal("foreign", h.m:phase())
	end)

	it("D10 a pin read back from the Fan ID row is checked at the first contact and stored when it holds", function()
		local h = new_harness()
		h.m:start("10.0.2.151", { client_id = "MF_00005E005301", mac = "00005E005301" })
		contact(h)
		assert.equal("online", h.m:phase())
		assert.equal("MF_00005E005301", h.data.mf_identity.client_id)
		assert.equal("3", h.data.mf_identity.generation, "completed from the state read")
		assert.equal("10.0.2.151", h.data.mf_identity.address)
		assert.same({}, events(h, "result"), "nothing was learned: the row named this fan")

		local wrong = new_harness()
		wrong.m:start("10.0.2.151", { client_id = "MF_00005E005399", mac = "00005E005399" })
		ok(wrong, info_json())
		assert.equal("foreign", wrong.m:phase())
		assert.is_nil(wrong.data.mf_identity, "a wrong pin is never stored")
	end)

	describe("Gen 4 and not a fan", function()
		local G4 = { systemType = "fan_g4", iotmVer = "01.00.0082", staMac = "00:00:5e:00:53:01", deviceName = "Example Fan" }

		local function probe_sent(h)
			gap(h)
			local s = last_sent(h)
			assert.equal("g4", s.kind)
			assert.equal("/device", s.path)
			assert.equal('{"query":true}', s.body)
		end

		it("H2 HTTP 404 then fan_g4 from /device: Gen 4, nothing sent, /mf read every 60 s without probing again", function()
			local h = new_harness({ store = { mf_online = true } })
			h.m:start("10.0.2.151")
			fail(h, "http", 404)
			probe_sent(h)
			ok(h, G4)
			local phase, detail = h.m:phase()
			assert.equal("gen4", phase)
			assert.equal("10.0.2.151", detail.address)
			assert.equal("offline", events(h, "phase")[2][2].event, "Fan Offline, as for offline (6.1)")
			assert.is_false(events(h, "phase")[2][2].online)
			assert.is_nil(h.data.mf_identity, "a Gen 4 fan is never pinned")
			local took, why = h.m:want({ fan_on = true, speed = 1 })
			assert.is_false(took)
			assert.equal("gen4", why)
			assert.is_true(logged(h, "warn", "Gen 4"))

			gap(h)
			h.clock.advance(59000)
			assert.same({ "info", "g4" }, kinds(h), "silent for a minute")
			h.clock.advance(1000)
			assert.equal("info", last_sent(h).kind)
			assert.equal("/mf", last_sent(h).path)
			fail(h, "http", 404)
			gap(h)
			h.clock.advance(60000)
			assert.same({ "info", "g4", "info", "info" }, kinds(h), "the verdict is kept; no second probe")
			assert.equal("gen4", h.m:phase())
		end)

		it("3.6 HTTP 404 then anything else is not a fan: another JSON, an HTML page, an empty body, a 404", function()
			local cases = {
				function(h) ok(h, { systemType = "something_else" }) end,
				function(h) fail(h, "json") end,
				function(h) fail(h, "empty") end,
				function(h) fail(h, "http", 404) end,
				function(h) fail(h, "http", 500) end,
			}
			for i, answer_probe in ipairs(cases) do
				local h = new_harness()
				h.m:start("10.0.2.151")
				fail(h, "http", 404)
				probe_sent(h)
				answer_probe(h)
				assert.equal("notfan", h.m:phase(), "case " .. i)
			end
		end)

		it("a probe that times out is an ordinary failure, not a verdict; the next contact may probe again", function()
			local h = new_harness()
			h.m:start("10.0.2.151")
			fail(h, "http", 404)
			probe_sent(h)
			fail(h, "timeout")
			assert.equal("waiting", h.m:phase())
			assert.equal(1, h.m:debug().failures)
			gap(h)
			h.clock.advance(10000)
			assert.equal("info", last_sent(h).kind, "the contact starts again after the backoff")
			fail(h, "http", 404)
			probe_sent(h)
		end)

		it("N4/S13 three answers in a row that are no fan's make it 'not a fan'", function()
			local h = new_harness()
			h.m:start("10.0.2.151")
			fail(h, "json")
			assert.equal("waiting", h.m:phase())
			gap(h)
			h.clock.advance(10000)
			fail(h, "json")
			gap(h)
			h.clock.advance(20000)
			assert.equal("waiting", h.m:phase())
			fail(h, "json")
			assert.equal("notfan", h.m:phase())
			assert.is_nil(h.data.mf_identity)
		end)

		it("P10/S9 three empty answers make it offline after unusable answers, not 'not a fan'", function()
			local h = steady(new_harness())
			poll_fail(h, "empty")
			gap(h)
			poll_fail(h, "empty")
			gap(h)
			poll_fail(h, "empty")
			local phase, detail = h.m:phase()
			assert.equal("offline", phase)
			assert.equal("data", detail.failure)
			assert.equal("data", h.m:status_view().failure)
		end)

		it("the right fan answering /mf again ends the verdict: a contact and online", function()
			local h = new_harness({ store = stored() })
			h.m:start("10.0.2.151")
			fail(h, "http", 404)
			probe_sent(h)
			ok(h, G4)
			gap(h)
			h.clock.advance(60000)
			ok(h, h.info)
			gap(h)
			ok(h, h.state)
			assert.equal("online", h.m:phase())
			local phase = events(h, "phase")
			assert.equal("gen4", phase[#phase][3])
			assert.equal("online", phase[#phase][2].event)
		end)
	end)
end)

describe("fan.model polling (V7, 3.4)", function()
	it("polls the state every Poll Interval while idle, one read each", function()
		local h = steady(new_harness())
		local n = #h.transport.sent
		h.clock.advance(14749)
		assert.equal(n, #h.transport.sent)
		h.clock.advance(1)
		assert.equal(n + 1, #h.transport.sent)
		assert.equal("state", last_sent(h).kind)
		assert.equal(h.wire.QUERY_STATE, last_sent(h).body)
		answer(h)
		gap(h)
		assert.equal(model.POLL_DEFAULT_S * 1000 - model.GAP_MS, h.clock.next_due())
		assert.equal(1, h.clock.active(), "one one-shot timer is all that is armed")
	end)

	it("the poll is one one-shot timer re-armed after the answer: a slow answer never overlaps the next poll", function()
		local h = steady(new_harness())
		h.clock.advance(h.clock.next_due())
		local n = #h.transport.sent
		h.clock.advance(100000)
		assert.equal(n, #h.transport.sent, "the request is still in flight: nothing else goes")
		ok(h, h.state)
		gap(h)
		assert.equal(model.POLL_DEFAULT_S * 1000 - model.GAP_MS, h.clock.next_due())
	end)

	it("the fast window: 2 s polls for 20 s after a command's answer, then the interval again", function()
		local h = steady(new_harness())
		assert.is_true(h.m:want({ fan_on = true, speed = 3 }))
		ok(h, state_json({ fanSpeed = 3 }))
		local t0 = h.clock.ms
		local n = #h.transport.sent
		local at = {}
		while h.clock.next_due() + h.clock.ms <= t0 + 40000 do
			h.clock.advance(h.clock.next_due())
			if pending(h) then
				at[#at + 1] = h.clock.ms - t0
				ok(h, state_json({ fanSpeed = 3 }))
			end
		end
		assert.same({ 2000, 4000, 6000, 8000, 10000, 12000, 14000, 16000, 18000, 20000, 35000 }, at)
		assert.equal(n + 11, #h.transport.sent)
	end)

	it("a command's answer counts as a poll: the timer restarts from it", function()
		local h = steady(new_harness())
		h.clock.advance(14000)
		assert.is_true(h.m:want({ fan_on = true, speed = 2 }))
		local n = #h.transport.sent
		ok(h, state_json({ fanSpeed = 2 }))
		gap(h)
		assert.equal(model.FAST_POLL_MS - model.GAP_MS, h.clock.next_due(), "the old poll (due in 750 ms) is replaced")
		h.clock.advance(1000)
		assert.equal(n, #h.transport.sent)
	end)

	it("V7 set_poll_interval clamps to 10..120 and measures again from the last answer", function()
		local h = steady(new_harness())
		assert.equal(10, h.m:set_poll_interval(3))
		assert.equal(10 * 1000 - model.GAP_MS, h.clock.next_due())
		assert.equal(120, h.m:set_poll_interval(500))
		assert.equal(120 * 1000 - model.GAP_MS, h.clock.next_due())
		assert.equal(30, h.m:set_poll_interval("30"))
		assert.equal(30 * 1000 - model.GAP_MS, h.clock.next_due())
		assert.equal(30, h.m:set_poll_interval("not a number"), "garbage changes nothing")
		h.m:set_poll_interval(15)
		h.clock.advance(h.clock.next_due())
		assert.equal("state", last_sent(h).kind)
	end)

	it("V7 an interval already past when it is set arms a poll one millisecond away, never 0", function()
		local h = steady(new_harness())
		h.clock.advance(12000)
		assert.equal(10, h.m:set_poll_interval(10))
		local due = h.clock.next_due()
		assert.truthy(due and due >= 1, "a live poll timer with a delay above 0")
	end)

	it("F1 the static data is read again after 6 h instead of one poll, then the state again", function()
		local h = steady(new_harness())
		run(h, model.INFO_REFRESH_S * 1000 - 20000)
		local infos = 0
		for _, k in ipairs(kinds(h)) do if k == "info" then infos = infos + 1 end end
		assert.equal(1, infos, "only the first contact's info so far")
		run(h, 16000)
		infos = 0
		for _, k in ipairs(kinds(h)) do if k == "info" then infos = infos + 1 end end
		assert.equal(2, infos, "the refresh went out as a poll")
		assert.equal("info", last_sent(h).kind)
		run(h, 16000)
		assert.equal("state", last_sent(h).kind, "and the state read follows")
		assert.equal(2, infos)
		assert.equal("online", h.m:phase())
	end)

	it("F1 a refresh that finds a new firmware records it with its date and the old one", function()
		local h = steady(new_harness())
		h.info = info_json({ firmwareVersion = "02.00.0060" })
		run(h, model.INFO_REFRESH_S * 1000 + 16000)
		assert.equal("02.00.0060", h.data.mf_info.firmware)
		assert.equal("02.00.0052", h.data.mf_info.firmware_was)
		assert.equal("2026-10-27", h.data.mf_info.firmware_since)
		assert.equal("02.00.0052", h.m:info().firmware_was)
		assert.equal(1, #events(h, "info"))
		assert.equal("online", h.m:phase())
	end)
end)

describe("fan.model commands (4.3, 4.4, V8, V14, R4, R5)", function()
	local function settled_of(h, group)
		local out = {}
		for _, e in ipairs(events(h, "settled")) do
			if e[1] == group then out[#out + 1] = e end
		end
		return out
	end

	-- The commands sent so far, as their bodies.
	local function commands(h)
		local out = {}
		for _, s in ipairs(h.transport.sent) do
			if s.kind == "command" then out[#out + 1] = s.body end
		end
		return out
	end

	it("9.11 fan on at N: one body at once, shown at once, settled 'command' and idle when the answer comes", function()
		local h = steady(new_harness())
		assert.is_true(h.m:want({ fan_on = true, speed = 3 }))
		local s = last_sent(h)
		assert.equal("command", s.kind)
		assert.equal("/mf", s.path)
		assert.equal('{"fanOn":true,"fanSpeed":3}', s.body)
		assert.same({ fan_on = true, speed = 3, direction = "forward", light_on = false, level = 100 }, h.m:shown())
		assert.same({ "shown" }, names(h), "R4: the LEDs hear it now, the proxies not yet")
		assert.equal(3, events(h, "shown")[1][1].speed)
		assert.equal(1, h.m:confirmed().speed)
		assert.is_true(h.m:busy("fan"))
		assert.is_false(h.m:busy("light"))
		assert.same({ "fan" }, h.m:debug().busy)

		clear(h)
		ok(h, state_json({ fanSpeed = 3 }))
		local settled = events(h, "settled")
		assert.equal(1, #settled)
		assert.equal("fan", settled[1][1])
		assert.equal(3, settled[1][2].speed)
		assert.equal("command", settled[1][3])
		assert.same({ "fan" }, { events(h, "idle")[1][1] })
		assert.same({}, events(h, "shown"), "the shown state did not change: wanted became confirmed")
		assert.same({}, events(h, "outside"))
		assert.is_false(h.m:busy("fan"))
		assert.equal(3, h.m:debug().told.fan)
		gap(h)
		assert.equal(model.FAST_POLL_MS - model.GAP_MS, h.clock.next_due())
	end)

	it("fan off and the direction are one body each; off keeps the remembered speed", function()
		local h = steady(new_harness(), state_json({ fanSpeed = 4 }))
		assert.is_true(h.m:want({ fan_on = false }))
		assert.equal('{"fanOn":false}', last_sent(h).body)
		assert.is_false(h.m:shown().fan_on)
		assert.equal(4, h.m:shown().speed)
		ok(h, state_json({ fanOn = false, fanSpeed = 4 }))
		local st = events(h, "settled")[1]
		assert.is_false(st[2].fan_on)
		assert.equal(4, st[2].speed)
		gap(h)
		assert.is_true(h.m:want({ direction = "reverse" }))
		assert.equal('{"fanDirection":"reverse"}', last_sent(h).body)
		ok(h, state_json({ fanOn = false, fanSpeed = 4, fanDirection = "reverse" }))
		local dir = settled_of(h, "direction")
		assert.equal("reverse", dir[#dir][2].direction)
		assert.equal("command", dir[#dir][3])
	end)

	it("a speed alone means on at that speed; off ignores a speed", function()
		local h = steady(new_harness())
		assert.is_true(h.m:want({ speed = 5 }))
		assert.equal('{"fanOn":true,"fanSpeed":5}', last_sent(h).body)
		ok(h, state_json({ fanSpeed = 5 }))
		gap(h)
		assert.is_true(h.m:want({ fan_on = false, speed = 5 }))
		assert.equal('{"fanOn":false}', last_sent(h).body)
	end)

	it("V8 a command is sent even when it equals the confirmed state", function()
		local h = steady(new_harness())
		assert.is_true(h.m:want({ fan_on = true, speed = 1 }))
		assert.equal('{"fanOn":true,"fanSpeed":1}', last_sent(h).body)
		ok(h, state_json({ fanSpeed = 1 }))
		assert.same({}, events(h, "settled"), "nothing changed, so nothing is said")
		assert.equal(1, #events(h, "idle"), "but the group is idle again")
	end)

	it("4.3 groups go in the order fan, direction, light, one group per request", function()
		local h = steady(new_harness())
		assert.is_true(h.m:want({ fan_on = true, speed = 2, direction = "reverse", light_on = true, level = 50 }))
		assert.same({ '{"fanOn":true,"fanSpeed":2}' }, commands(h))
		ok(h, state_json({ fanSpeed = 2 }))
		gap(h)
		assert.equal('{"fanDirection":"reverse"}', last_sent(h).body)
		ok(h, state_json({ fanSpeed = 2, fanDirection = "reverse" }))
		gap(h)
		assert.equal('{"lightBrightness":50}', last_sent(h).body)
		ok(h, state_json({ fanSpeed = 2, fanDirection = "reverse", lightBrightness = 50 }))
		gap(h)
		assert.equal('{"lightOn":true}', last_sent(h).body)
		ok(h, state_json({ fanSpeed = 2, fanDirection = "reverse", lightBrightness = 50, lightOn = true }))
		assert.equal(4, #commands(h))
		assert.equal(3, #events(h, "idle"))
	end)

	describe("the light: on at a level is the level first, then on (V14)", function()
		it("a light that is off and a level that is not the kept one: two bodies, the proxies hear the end state once",
			function()
				local h = steady(new_harness())
				assert.is_true(h.m:want({ light_on = true, level = 40 }))
				assert.equal('{"lightBrightness":40}', last_sent(h).body)
				assert.is_true(h.m:shown().light_on, "the LEDs show the target at once")
				assert.equal(40, h.m:shown().level)
				clear(h)
				ok(h, state_json({ lightBrightness = 40 }))
				assert.same({}, settled_of(h, "light"), "the light is still off: R5, nothing yet")
				assert.same({}, events(h, "idle"))
				assert.is_true(h.m:busy("light"))
				gap(h)
				assert.equal('{"lightOn":true}', last_sent(h).body)
				ok(h, state_json({ lightBrightness = 40, lightOn = true }))
				local light = settled_of(h, "light")
				assert.equal(1, #light)
				assert.equal(40, light[1][2].level)
				assert.is_true(light[1][2].light_on)
				assert.equal("command", light[1][3])
				assert.equal(1, #events(h, "idle"))
				assert.same({ '{"lightBrightness":40}', '{"lightOn":true}' }, commands(h))
			end)

		it("the wanted level is the kept one: only on is sent", function()
			local h = steady(new_harness())
			assert.is_true(h.m:want({ light_on = true, level = 100 }))
			assert.equal('{"lightOn":true}', last_sent(h).body)
			ok(h, state_json({ lightOn = true }))
			assert.equal(1, #settled_of(h, "light"))
			assert.same({ '{"lightOn":true}' }, commands(h))
		end)

		it("a light that is on takes the new level alone", function()
			local h = steady(new_harness(), state_json({ lightOn = true, lightBrightness = 40 }))
			assert.is_true(h.m:want({ light_on = true, level = 70 }))
			assert.equal('{"lightBrightness":70}', last_sent(h).body)
			ok(h, state_json({ lightOn = true, lightBrightness = 70 }))
			local light = settled_of(h, "light")
			assert.equal(70, light[1][2].level)
			assert.equal(1, #commands(h))
			gap(h)
			h.clock.advance(5000)
			assert.equal(1, #commands(h), "done: nothing more is sent")
		end)

		it("off is one body", function()
			local h = steady(new_harness(), state_json({ lightOn = true, lightBrightness = 40 }))
			assert.is_true(h.m:want({ light_on = false }))
			assert.equal('{"lightOn":false}', last_sent(h).body)
			ok(h, state_json({ lightOn = false, lightBrightness = 40 }))
			local st = settled_of(h, "light")[1][2]
			assert.is_false(st.light_on)
			assert.equal(40, st.level, "the level is kept while off (M0)")
		end)

		it("a confirmed state that was stale still takes at most two requests", function()
			local h = steady(new_harness(), state_json({ lightOn = true, lightBrightness = 40 }))
			assert.is_true(h.m:want({ light_on = true, level = 70 }))
			assert.equal('{"lightBrightness":70}', last_sent(h).body)
			ok(h, state_json({ lightOn = false, lightBrightness = 70 })) -- it was off after all
			assert.is_true(h.m:busy("light"), "not done: the answer does not show the light on")
			gap(h)
			assert.equal('{"lightOn":true}', last_sent(h).body)
			ok(h, state_json({ lightOn = true, lightBrightness = 70 }))
			assert.is_false(h.m:busy("light"))
			assert.equal(2, #commands(h))
		end)

		it("a hold that keeps changing the level: one level of the turn-on, then on, and the newer level as a plain change",
			function()
				local h = steady(new_harness())
				assert.is_true(h.m:want({ light_on = true, level = 30 }))
				assert.equal('{"lightBrightness":30}', last_sent(h).body)
				assert.is_true(h.m:want({ light_on = true, level = 35 }))
				assert.is_true(h.m:want({ light_on = true, level = 38 }))
				ok(h, state_json({ lightBrightness = 30 }))
				gap(h)
				assert.equal('{"lightOn":true}', last_sent(h).body, "not another level step")
				ok(h, state_json({ lightBrightness = 30, lightOn = true }))
				assert.same({}, settled_of(h, "light"), "the newer level is still wanted")
				gap(h)
				assert.equal('{"lightBrightness":38}', last_sent(h).body)
				ok(h, state_json({ lightBrightness = 38, lightOn = true }))
				local light = settled_of(h, "light")
				assert.equal(1, #light)
				assert.equal(38, light[1][2].level)
				assert.same({ '{"lightBrightness":30}', '{"lightOn":true}', '{"lightBrightness":38}' }, commands(h))
			end)

		it("S9 a target is done once its on was answered, whatever the answer shows: no loop", function()
			local h = steady(new_harness())
			assert.is_true(h.m:want({ light_on = true, level = 100 }))
			ok(h, state_json({ lightOn = false })) -- the fan did not take it
			assert.is_true(logged(h, "warn", "The fan did not take light on (reports off)"))
			assert.is_false(h.m:busy("light"))
			gap(h)
			h.clock.advance(30000)
			assert.equal(1, #commands(h))
			assert.equal(1, #events(h, "idle"))
		end)

		it("R5 a slider burst on a light that is on: the first level goes, the latest follows, one report", function()
			local h = steady(new_harness(), state_json({ lightOn = true, lightBrightness = 40 }))
			assert.is_true(h.m:want({ light_on = true, level = 50 }))
			assert.is_true(h.m:want({ light_on = true, level = 60 }))
			assert.is_true(h.m:want({ light_on = true, level = 70 }))
			assert.equal(70, h.m:shown().level)
			assert.equal('{"lightBrightness":50}', last_sent(h).body)
			clear(h)
			ok(h, state_json({ lightOn = true, lightBrightness = 50 }))
			assert.same({}, settled_of(h, "light"), "70 is still wanted")
			gap(h)
			assert.equal('{"lightBrightness":70}', last_sent(h).body)
			ok(h, state_json({ lightOn = true, lightBrightness = 70 }))
			local light = settled_of(h, "light")
			assert.equal(1, #light)
			assert.equal(70, light[1][2].level)
			assert.same({ '{"lightBrightness":50}', '{"lightBrightness":70}' }, commands(h))
		end)

		it("on without a level resumes the kept level: one body, lightOn", function()
			local h = steady(new_harness(), state_json({ lightBrightness = 35 }))
			assert.is_true(h.m:want({ light_on = true }))
			assert.is_true(h.m:shown().light_on)
			assert.equal(35, h.m:shown().level)
			assert.equal('{"lightOn":true}', last_sent(h).body)
			ok(h, state_json({ lightOn = true, lightBrightness = 35 }))
			assert.equal(35, settled_of(h, "light")[1][2].level)
		end)

		it("a new target replaces the old one: off while the level step is in flight is done by its answer (4.3)",
			function()
				local h = steady(new_harness())
				assert.is_true(h.m:want({ light_on = true, level = 30 }))
				assert.is_true(h.m:want({ light_on = false }))
				assert.is_false(h.m:shown().light_on)
				clear(h)
				ok(h, state_json({ lightBrightness = 30 }))
				assert.is_false(h.m:busy("light"), "the answer shows the light off: the target is done")
				assert.equal(1, #events(h, "idle"))
				assert.same({}, events(h, "settled"), "off was told already, so nothing changed")
				gap(h)
				h.clock.advance(1000)
				assert.same({ '{"lightBrightness":30}' }, commands(h))
			end)

		it("off wanted behind a level change of a light that is on is sent after it", function()
			local h = steady(new_harness(), state_json({ lightOn = true, lightBrightness = 40 }))
			assert.is_true(h.m:want({ light_on = true, level = 70 }))
			assert.is_true(h.m:want({ light_on = false }))
			ok(h, state_json({ lightOn = true, lightBrightness = 70 }))
			assert.is_true(h.m:busy("light"), "the answer still shows the light on")
			gap(h)
			assert.equal('{"lightOn":false}', last_sent(h).body)
			clear(h)
			ok(h, state_json({ lightOn = false, lightBrightness = 70 }))
			assert.is_false(h.m:busy("light"))
			local light = settled_of(h, "light")
			assert.equal(1, #light)
			assert.is_false(light[1][2].light_on)
			assert.equal("command", light[1][3])
		end)
	end)

	it("a command's answer that also shows another group changed reports that group as outside (A1)", function()
		local h = steady(new_harness())
		assert.is_true(h.m:want({ fan_on = true, speed = 3 }))
		clear(h)
		ok(h, state_json({ fanSpeed = 3, fanDirection = "reverse" })) -- somebody else, at the same time
		local settled = events(h, "settled")
		assert.equal(2, #settled)
		assert.equal("fan", settled[1][1])
		assert.equal("command", settled[1][3])
		assert.equal("direction", settled[2][1])
		assert.equal("outside", settled[2][3])
		assert.same({ "direction" }, events(h, "outside")[1][1])
	end)

	it("R5 a burst coalesces: the latest target is sent, intermediate answers fire nothing", function()
		local h = steady(new_harness())
		assert.is_true(h.m:want({ fan_on = true, speed = 2 }))
		assert.is_true(h.m:want({ fan_on = true, speed = 3 }))
		assert.is_true(h.m:want({ fan_on = true, speed = 4 }))
		assert.is_true(h.m:want({ fan_on = true, speed = 5 }))
		assert.equal(5, h.m:shown().speed)
		clear(h)
		ok(h, state_json({ fanSpeed = 2 }))
		assert.same({}, events(h, "settled"), "the group is still busy: 5 is wanted")
		assert.same({}, events(h, "idle"))
		gap(h)
		assert.equal('{"fanOn":true,"fanSpeed":5}', last_sent(h).body)
		ok(h, state_json({ fanSpeed = 5 }))
		local settled = events(h, "settled")
		assert.equal(1, #settled)
		assert.equal(5, settled[1][2].speed)
		assert.equal(2, #commands(h), "two requests in all: the first and the last")
		gap(h)
		h.clock.advance(1000)
		assert.equal(2, #commands(h))
	end)

	it("a repeated press equal to the request in flight costs nothing", function()
		local h = steady(new_harness())
		assert.is_true(h.m:want({ fan_on = true, speed = 3 }))
		assert.is_true(h.m:want({ fan_on = true, speed = 3 }))
		ok(h, state_json({ fanSpeed = 3 }))
		gap(h)
		h.clock.advance(1000)
		assert.equal(1, #commands(h))
		assert.is_false(h.m:busy("fan"))
	end)

	it("a different press during the flight is sent after it", function()
		local h = steady(new_harness())
		assert.is_true(h.m:want({ fan_on = true, speed = 3 }))
		assert.is_true(h.m:want({ fan_on = false }))
		ok(h, state_json({ fanSpeed = 3 }))
		gap(h)
		assert.equal('{"fanOn":false}', last_sent(h).body)
	end)

	it("one request in flight: a command wanted behind a request waits for its answer and the gap", function()
		local h = steady(new_harness())
		h.clock.advance(h.clock.next_due()) -- a poll goes out
		assert.equal("state", pending(h).kind)
		local n = #h.transport.sent
		assert.is_true(h.m:want({ fan_on = true, speed = 6 }))
		assert.equal(n, #h.transport.sent, "behind the poll")
		ok(h, h.state)
		assert.equal(n, #h.transport.sent, "behind the gap")
		gap(h)
		assert.equal(n + 1, #h.transport.sent)
		assert.equal('{"fanOn":true,"fanSpeed":6}', last_sent(h).body)
	end)

	describe("what want refuses, and why", function()
		it("range: values outside what the fan takes", function()
			local h = steady(new_harness())
			local bad = {
				{ fan_on = true, speed = 0 }, { fan_on = true, speed = 7 }, { fan_on = true, speed = 2.5 },
				{ fan_on = true, speed = "3" }, { fan_on = true }, { fan_on = "yes", speed = 2 },
				{ direction = "sideways" }, { light_on = true, level = 0 }, { light_on = true, level = 101 },
				{ light_on = "on" }, {}, { unknown = 1 },
			}
			for i, fields in ipairs(bad) do
				local took, why = h.m:want(fields)
				assert.is_false(took, "case " .. i)
				assert.equal("range", why, "case " .. i)
			end
			assert.is_false((h.m:want("fast")))
			assert.is_nil(pending(h), "nothing was sent")
			assert.is_false(h.m:busy("fan"))
		end)

		it("a refused call changes nothing, even when another group in it was fine", function()
			local h = steady(new_harness())
			local took, why = h.m:want({ fan_on = true, speed = 3, direction = "sideways" })
			assert.is_false(took)
			assert.equal("range", why)
			assert.is_false(h.m:busy("fan"))
			assert.is_nil(pending(h))
		end)

		it("unset, foreign, gen4, notfan and rebooting", function()
			local fresh = new_harness()
			assert.same({ false, "unset" }, { fresh.m:want({ fan_on = false }) })
			fresh.m:start("")
			assert.same({ false, "unset" }, { fresh.m:want({ fan_on = false }) })
			local h = steady(new_harness())
			h.m:reboot()
			assert.same({ false, "rebooting" }, { h.m:want({ fan_on = false }) })
		end)

		it("F3/S6 a key the fan does not report: 'no <key>' for the part it pauses, the rest works", function()
			local h = steady(new_harness(), state_json({ fanSpeed = NIL, lightBrightness = NIL, lightOn = true }))
			assert.same({ "fanSpeed", "lightBrightness" }, h.m:status_view().missing)
			assert.same({ false, "no fanSpeed" }, { h.m:want({ fan_on = true, speed = 2 }) })
			assert.same({ false, "no lightBrightness" }, { h.m:want({ light_on = true, level = 20 }) })
			assert.is_true(h.m:want({ fan_on = false }), "off needs only fanOn")
			assert.is_true(h.m:want({ direction = "reverse" }))
			assert.is_true(h.m:want({ light_on = false }), "light off needs only lightOn")

			local d = steady(new_harness(), state_json({ fanDirection = NIL }))
			assert.same({ false, "no fanDirection" }, { d.m:want({ direction = "reverse" }) })
			local o = steady(new_harness(), state_json({ fanOn = NIL }))
			assert.same({ false, "no fanOn" }, { o.m:want({ fan_on = false }) })
			assert.same({ false, "no fanOn" }, { o.m:want({ fan_on = true, speed = 2 }) })
		end)

		it("a speed or level that is only unknown while off is not 'missing'", function()
			local h = steady(new_harness(), state_json({ fanOn = false, fanSpeed = 0, lightOn = false, lightBrightness = 0 }))
			assert.is_nil(h.m:status_view().missing)
			assert.is_true(h.m:want({ fan_on = true, speed = 2 }))
		end)
	end)

	it("a body the wire module refuses is dropped and logged, and the next group goes on", function()
		local h = steady(new_harness())
		local real = h.wire.body
		h.wire.body = function(fields)
			if fields.direction then return nil, "range" end
			return real(fields)
		end
		assert.is_true(h.m:want({ direction = "reverse", fan_on = true, speed = 4 }))
		assert.equal('{"fanOn":true,"fanSpeed":4}', last_sent(h).body)
		ok(h, state_json({ fanSpeed = 4 }))
		gap(h)
		assert.is_true(logged(h, "error", "direction: no body for the wanted fields (range); dropped"))
		assert.is_false(h.m:busy("direction"))
	end)
end)

describe("fan.model answers: order, epochs, stale (4.2, P9, R2)", function()
	it("P9 the late answer of a request given up never becomes state", function()
		local h = steady(new_harness())
		h.clock.advance(h.clock.next_due()) -- a poll goes out
		h.m:set_address("10.0.2.152")
		clear(h)
		-- the old transfer finishes at last, through a transport that does not filter
		local entry, result = h.transport:late_answer({
			ok = true, code = 200, json = state_json({ fanSpeed = 6 }), ms = 300,
		})
		entry.cb(result)
		assert.equal(1, h.m:confirmed().speed)
		assert.same({}, events(h, "settled"))
		assert.same({}, events(h, "seen"))
	end)

	it("R2 an answer with another seq or another epoch is dropped unread", function()
		local h = steady(new_harness())
		h.clock.advance(h.clock.next_due())
		local entry = pending(h)
		clear(h)
		entry.cb({ seq = entry.seq + 1, epoch = entry.epoch, ok = true, json = state_json({ fanSpeed = 6 }), ms = 1 })
		entry.cb({ seq = entry.seq, epoch = entry.epoch + 1, ok = true, json = state_json({ fanSpeed = 6 }), ms = 1 })
		assert.equal(1, h.m:confirmed().speed)
		assert.same({}, events(h, "settled"))
		ok(h, state_json({ fanSpeed = 2 })) -- the real one still counts
		assert.equal(2, h.m:confirmed().speed)
		assert.equal("outside", events(h, "settled")[1][3])
	end)

	it("a result delivered twice counts once", function()
		local h = steady(new_harness())
		h.clock.advance(h.clock.next_due())
		local entry = pending(h)
		ok(h, state_json({ fanSpeed = 2 }))
		clear(h)
		entry.cb({ seq = entry.seq, epoch = entry.epoch, ok = true, json = state_json({ fanSpeed = 5 }), ms = 1 })
		assert.equal(2, h.m:confirmed().speed)
		assert.same({}, events(h, "settled"))
	end)

	it("a transport that never calls on_idle still gets the next request out: the model looks again itself", function()
		local h = new_harness()
		h.transport.on_idle = nil
		h.m:start("10.0.2.151")
		ok(h, h.info)
		-- the model's own look may fall inside the gap (it was armed first), the next one is after it
		h.clock.advance(model.GAP_MS * 2)
		assert.equal("state", last_sent(h).kind)
		ok(h, h.state)
		h.clock.advance(model.GAP_MS * 2)
		assert.equal("online", h.m:phase())
		assert.is_true(h.m:want({ fan_on = true, speed = 3 }))
		assert.equal("command", last_sent(h).kind)
		clear(h)
		ok(h, state_json({ fanSpeed = 3 }))
		h.clock.advance(model.GAP_MS * 2)
		assert.equal("command", events(h, "settled")[1][3])
		assert.is_true(h.clock.active() > 0, "the next poll is armed")
	end)

	it("an answer that is not a state (no client id) is a failure, never state", function()
		local h = steady(new_harness())
		poll(h, { fanOn = true, fanSpeed = 6 })
		assert.equal(1, h.m:confirmed().speed)
		assert.equal(1, h.m:debug().failures)
		assert.is_true(logged(h, "warn", "fan #"))
	end)

	it("stop() ends everything: no timer, no request, late answers dropped, wants refused", function()
		local h = steady(new_harness())
		h.clock.advance(h.clock.next_due())
		local entry = pending(h)
		h.m:stop()
		assert.equal(1, h.transport.stops)
		assert.equal(0, h.clock.active())
		clear(h)
		entry.cb({ seq = entry.seq, epoch = entry.epoch, ok = true, json = state_json({ fanSpeed = 6 }), ms = 1 })
		assert.same({}, h.events)
		assert.same({ false, "unset" }, { h.m:want({ fan_on = false }) })
		local n = #h.transport.sent
		h.clock.advance(100000)
		assert.equal(n, #h.transport.sent, "no poll after stop")
	end)
end)

describe("fan.model settle window (4.4, S7, S9, S11, R3)", function()
	local saved
	before_each(function() saved = model.SETTLE_MS end)
	after_each(function() model.SETTLE_MS = saved end)

	-- The command is wanted, answered with `st`, and the gap passes: the settle window
	-- is open and the first fast read is 1.75 s away.
	local function commanded(h, fields, st)
		assert.is_true(h.m:want(fields))
		ok(h, st)
		gap(h)
		clear(h)
	end

	it("S7/R3 the old value read inside the window is held and not believed; the next read agrees, nothing is said",
		function()
			local h = steady(new_harness())
			commanded(h, { fan_on = true, speed = 3 }, state_json({ fanSpeed = 3 }))
			assert.equal(model.FAST_POLL_MS - model.GAP_MS, h.clock.next_due())
			poll(h, state_json({ fanSpeed = 1 })) -- the fan's lag: its old value, 2 s after the command
			assert.equal(3, h.m:confirmed().speed)
			assert.same({}, events(h, "settled"))
			assert.same({}, events(h, "outside"))
			assert.is_true(logged(h, "debug", "is held"))
			gap(h)
			poll(h, state_json({ fanSpeed = 3 }))
			assert.equal(3, h.m:confirmed().speed)
			assert.same({}, events(h, "settled"), "R1: nothing really changed, so nothing is told")
		end)

	it("S11 the fan really went back (someone else): the next read believes it and reports it as outside", function()
		local h = steady(new_harness())
		commanded(h, { fan_on = true, speed = 3 }, state_json({ fanSpeed = 3 }))
		poll(h, state_json({ fanSpeed = 1 }))
		assert.same({}, events(h, "settled"))
		gap(h)
		poll(h, state_json({ fanSpeed = 1 }))
		assert.equal(1, h.m:confirmed().speed)
		local settled = events(h, "settled")
		assert.equal(1, #settled)
		assert.equal("fan", settled[1][1])
		assert.equal(1, settled[1][2].speed)
		assert.equal("outside", settled[1][3])
		assert.same({ "fan" }, events(h, "outside")[1][1])
	end)

	it("inside a longer window two reads that agree with each other are believed at the second", function()
		model.SETTLE_MS = 10000
		local h = steady(new_harness())
		commanded(h, { fan_on = true, speed = 3 }, state_json({ fanSpeed = 3 }))
		poll(h, state_json({ fanSpeed = 1 }))
		assert.equal(3, h.m:confirmed().speed)
		gap(h)
		poll(h, state_json({ fanSpeed = 1 }))
		assert.equal(1, h.m:confirmed().speed)
		assert.equal("outside", events(h, "settled")[1][3])
	end)

	it("inside a longer window a held value is dropped when the next read agrees with the command", function()
		model.SETTLE_MS = 10000
		local h = steady(new_harness())
		commanded(h, { fan_on = true, speed = 3 }, state_json({ fanSpeed = 3 }))
		poll(h, state_json({ fanSpeed = 1 }))
		gap(h)
		poll(h, state_json({ fanSpeed = 3 }))
		assert.equal(3, h.m:confirmed().speed)
		assert.is_true(logged(h, "debug", "the next read agrees with the command"))
		assert.same({}, events(h, "settled"))
		-- and a later read of the old value is held again: the held value did not stay
		gap(h)
		poll(h, state_json({ fanSpeed = 1 }))
		assert.equal(3, h.m:confirmed().speed)
	end)

	it("after the window one read is enough", function()
		model.SETTLE_MS = 1000
		local h = steady(new_harness())
		commanded(h, { fan_on = true, speed = 3 }, state_json({ fanSpeed = 3 }))
		poll(h, state_json({ fanSpeed = 2 }))
		assert.equal(2, h.m:confirmed().speed)
		local settled = events(h, "settled")
		assert.equal(1, #settled)
		assert.equal(2, settled[1][2].speed)
		assert.equal("outside", settled[1][3])
	end)

	it("the window is per field: another field of the same read is believed at once", function()
		local h = steady(new_harness())
		commanded(h, { fan_on = true, speed = 3 }, state_json({ fanSpeed = 3 }))
		poll(h, state_json({ fanSpeed = 1, fanDirection = "reverse" }))
		assert.equal("reverse", h.m:confirmed().direction)
		assert.equal(3, h.m:confirmed().speed)
		local settled = events(h, "settled")
		assert.equal(1, #settled)
		assert.equal("direction", settled[1][1])
		assert.equal("outside", settled[1][3])
	end)

	it("S9 the answer to a command the fan did not take wins, is logged once and is not retried", function()
		local h = steady(new_harness())
		assert.is_true(h.m:want({ fan_on = true, speed = 6 }))
		clear(h)
		ok(h, state_json({ fanSpeed = 4 }))
		assert.is_true(logged(h, "warn", "The fan did not take speed 6 (reports 4)"))
		local settled = events(h, "settled")
		assert.equal(4, settled[1][2].speed)
		assert.equal("command", settled[1][3])
		gap(h)
		h.clock.advance(30000)
		local n = 0
		for _, s in ipairs(h.transport.sent) do
			if s.kind == "command" then n = n + 1 end
		end
		assert.equal(1, n)
	end)

	it("the settle window holds the answer's values: the command's own answer is the authority (R3)", function()
		local h = steady(new_harness())
		-- the answer shows speed 2 although 3 was sent; a read at +2 s that says 3 is the odd one out
		assert.is_true(h.m:want({ fan_on = true, speed = 3 }))
		ok(h, state_json({ fanSpeed = 2 }))
		gap(h)
		clear(h)
		poll(h, state_json({ fanSpeed = 3 }))
		assert.equal(2, h.m:confirmed().speed)
		assert.same({}, events(h, "settled"))
	end)

	it("a contact reads afresh: what a command still held does not outrank the contact's state", function()
		local h = steady(new_harness())
		commanded(h, { fan_on = true, speed = 3 }, state_json({ fanSpeed = 3 }))
		h.m:set_address("10.0.2.151") -- the same address typed again: a new epoch and a contact
		contact(h, state_json({ fanSpeed = 1 }))
		assert.equal(1, h.m:confirmed().speed)
	end)
end)

describe("fan.model settled reports (4.5; R1 to R9, A1 to A12)", function()
	it("R1 identical reads are silent, a change is one notification, the same value again is silent", function()
		local h = steady(new_harness())
		for _ = 1, 3 do
			poll(h)
			gap(h)
		end
		assert.same({}, events(h, "settled"))
		assert.same({}, events(h, "idle"))
		assert.same({}, events(h, "shown"))
		poll(h, state_json({ fanSpeed = 4 }))
		assert.equal(1, #events(h, "settled"))
		gap(h)
		poll(h, state_json({ fanSpeed = 4 }))
		assert.equal(1, #events(h, "settled"))
	end)

	it("A1 a change nobody commanded: settled 'outside', then outside(groups, userData, at), then the fast window",
		function()
			local h = steady(new_harness())
			poll(h, state_json({ fanSpeed = 5, userData = "cloud" }))
			local settled = events(h, "settled")
			assert.equal(1, #settled)
			assert.equal("fan", settled[1][1])
			assert.equal(5, settled[1][2].speed)
			assert.equal("outside", settled[1][3])
			local out = events(h, "outside")
			assert.equal(1, #out)
			assert.same({ "fan" }, out[1][1])
			assert.equal("cloud", out[1][2])
			assert.equal(h.clock.secs(), out[1][3])
			local order = {}
			for _, name in ipairs(names(h)) do
				if name == "settled" or name == "outside" then order[#order + 1] = name end
			end
			assert.same({ "settled", "outside" }, order)
			gap(h)
			assert.equal(model.FAST_POLL_MS - model.GAP_MS, h.clock.next_due(), "the fast window is open")
		end)

	it("A1 several groups changed in one read are reported group by group, one outside() for all of them", function()
		local h = steady(new_harness())
		poll(h, state_json({ fanSpeed = 2, fanDirection = "reverse", lightOn = true, lightBrightness = 30 }))
		local groups = {}
		for _, e in ipairs(events(h, "settled")) do groups[#groups + 1] = e[1] end
		assert.same({ "fan", "direction", "light" }, groups)
		local out = events(h, "outside")
		assert.equal(1, #out)
		assert.same({ "fan", "direction", "light" }, out[1][1])
	end)

	it("R5 the fan off from outside reports 0 with the remembered speed kept in the state", function()
		local h = steady(new_harness(), state_json({ fanSpeed = 4 }))
		poll(h, state_json({ fanOn = false, fanSpeed = 4 }))
		local settled = events(h, "settled")
		assert.is_false(settled[1][2].fan_on)
		assert.equal(4, settled[1][2].speed)
		assert.equal(0, h.m:debug().told.fan)
	end)

	it("the fast window lasts FAST_WINDOW_MS after the change, then the interval is back", function()
		local h = steady(new_harness())
		poll(h, state_json({ fanSpeed = 5 }))
		h.state = state_json({ fanSpeed = 5 })
		local last
		for _ = 1, 30 do
			gap(h)
			local due = h.clock.next_due()
			if due > model.FAST_POLL_MS then last = due break end
			h.clock.advance(due)
			answer(h)
		end
		assert.equal(model.POLL_DEFAULT_S * 1000 - model.GAP_MS, last)
	end)

	it("R5 a group is reported only once idle: a read during a wanted command tells nothing about that group",
		function()
			local h = steady(new_harness())
			h.clock.advance(h.clock.next_due()) -- a poll goes out
			assert.is_true(h.m:want({ fan_on = true, speed = 3 }))
			clear(h)
			ok(h, state_json({ fanSpeed = 2, fanDirection = "reverse" })) -- somebody else, just then
			local settled = events(h, "settled")
			assert.equal(1, #settled)
			assert.equal("direction", settled[1][1], "the busy fan group says nothing")
			assert.same({ "direction" }, events(h, "outside")[1][1])
			gap(h)
			assert.equal('{"fanOn":true,"fanSpeed":3}', last_sent(h).body)
			clear(h)
			ok(h, state_json({ fanSpeed = 3, fanDirection = "reverse" }))
			settled = events(h, "settled")
			assert.equal(1, #settled)
			assert.equal("fan", settled[1][1])
			assert.equal("command", settled[1][3])
			assert.equal(3, settled[1][2].speed)
		end)

	it("R2 reports come in the order of the answers: 2, then 4, never 2 after 4", function()
		local h = steady(new_harness())
		assert.is_true(h.m:want({ fan_on = true, speed = 2 }))
		ok(h, state_json({ fanSpeed = 2 }))
		gap(h)
		assert.is_true(h.m:want({ fan_on = true, speed = 4 }))
		ok(h, state_json({ fanSpeed = 4 }))
		gap(h)
		poll(h, state_json({ fanSpeed = 4 }))
		local speeds = {}
		for _, e in ipairs(events(h, "settled")) do speeds[#speeds + 1] = e[2].speed end
		assert.same({ 2, 4 }, speeds)
	end)

	it("R9 only the nine events of section 9.5 exist, and no group is ever told 'on' or 'off'", function()
		local h = steady(new_harness())
		assert.is_true(h.m:want({ fan_on = true, speed = 3, light_on = true, level = 60 }))
		ok(h, state_json({ fanSpeed = 3 }))
		gap(h)
		ok(h, state_json({ fanSpeed = 3, lightBrightness = 60 }))
		gap(h)
		ok(h, state_json({ fanSpeed = 3, lightBrightness = 60, lightOn = true }))
		gap(h)
		assert.is_true(h.m:want({ fan_on = false, light_on = false }))
		ok(h, state_json({ fanOn = false, fanSpeed = 3, lightBrightness = 60 }))
		gap(h)
		ok(h, state_json({ fanOn = false, fanSpeed = 3, lightBrightness = 60 }))
		for _, e in ipairs(h.events) do
			local ok_name = false
			for _, name in ipairs(LISTENER) do
				if name == e.name then ok_name = true end
			end
			assert.is_true(ok_name, tostring(e.name))
		end
		assert.same({}, h.unknown)
		assert.equal(0, h.m:debug().told.fan)
		assert.equal(0, h.m:debug().told.light)
	end)

	describe("the fan's automations (A4 to A7)", function()
		it("the first contact announces them once; identical reads do not repeat it", function()
			local h = online(new_harness())
			assert.equal(1, #events(h, "automations"))
			clear(h)
			h.clock.advance(h.clock.next_due())
			answer(h)
			assert.same({}, events(h, "automations"))
		end)

		it("away mode, adaptive learning and a schedule each fire one event with the confirmed state", function()
			local h = steady(new_harness())
			poll(h, state_json({ awayModeEnabled = true }))
			local auto = events(h, "automations")
			assert.equal(1, #auto)
			assert.is_true(auto[1][1].away)
			gap(h)
			poll(h, state_json({ awayModeEnabled = true, adaptiveLearning = true, schedule = "blob" }))
			auto = events(h, "automations")
			assert.equal(2, #auto)
			assert.is_true(auto[2][1].learning)
			assert.is_true(auto[2][1].schedule_set)
			gap(h)
			poll(h, state_json({ awayModeEnabled = true, adaptiveLearning = true, schedule = "blob" }))
			assert.equal(2, #events(h, "automations"))
		end)

		it("a Gen 3 timer counting down fires only when its minutes change, not every second", function()
			local h = steady(new_harness(), state_json({ fanTimer = 0 }))
			poll(h, state_json({ fanTimer = 3600 }))
			assert.equal(1, #events(h, "automations"))
			gap(h)
			poll(h, state_json({ fanTimer = 3585 })) -- 15 s later: still 60 minutes
			assert.equal(1, #events(h, "automations"))
			gap(h)
			poll(h, state_json({ fanTimer = 3540 }))
			assert.equal(2, #events(h, "automations"))
			gap(h)
			poll(h, state_json({ fanTimer = 0 }))
			assert.equal(3, #events(h, "automations"))
		end)

		it("a Gen 1/2 sleep timer is running or not", function()
			local h = steady(new_harness(), state_json({ fanTimer = NIL, lightTimer = NIL, fanSleepTimer = 0 }))
			poll(h, state_json({ fanTimer = NIL, lightTimer = NIL, fanSleepTimer = 900 }))
			assert.equal(1, #events(h, "automations"))
			gap(h)
			poll(h, state_json({ fanTimer = NIL, lightTimer = NIL, fanSleepTimer = 600 }))
			assert.equal(1, #events(h, "automations"))
		end)
	end)

	describe("a fan without a light kit (H4)", function()
		it("never reports the light group and keeps the fan and direction working", function()
			local h = steady(new_harness(), state_json(), info_json({ lightType = "" }))
			assert.is_false(h.m:info().has_light)
			poll(h, state_json({ lightOn = true, lightBrightness = 20, fanSpeed = 3 }))
			local groups = {}
			for _, e in ipairs(events(h, "settled")) do groups[#groups + 1] = e[1] end
			assert.same({ "fan" }, groups)
			assert.is_nil(h.m:shown().light_on)
			assert.same({ false, "no light kit" }, { h.m:want({ light_on = true, level = 10 }) })
			assert.is_true(h.m:want({ fan_on = false }))
		end)
	end)
end)

describe("fan.model offline and back online (3.4, 6, P1, P2, P8, R7, R8)", function()
	it("P1 one failure shows nothing; the retry is a contact and its success ends the streak", function()
		local h = steady(new_harness())
		attempt(h)
		assert.equal("online", h.m:phase())
		assert.equal(1, h.m:debug().failures)
		assert.same({}, events(h, "phase"))
		assert.same({}, events(h, "settled"))
		assert.is_true(logged(h, "warn", "failed: timeout after 5.0 s (1 in a row)"))
		assert.equal(model.BACKOFF_S[1] * 1000 - model.GAP_MS, h.clock.next_due())
		h.clock.advance(h.clock.next_due())
		contact(h)
		gap(h)
		assert.equal(0, h.m:debug().failures)
		assert.equal("online", h.m:phase())
		assert.same({}, events(h, "settled"))
		assert.same({}, events(h, "phase"))
	end)

	it("P1 three failures 5 s each, 10 s and 20 s apart: offline after about 45 s, with Fan Offline", function()
		local h = steady(new_harness())
		local s1 = attempt(h)
		local s2 = attempt(h)
		assert.equal("online", h.m:phase())
		local s3 = attempt(h)
		assert.equal(model.BACKOFF_S[1] * 1000 + 5000, s2 - s1)
		assert.equal(model.BACKOFF_S[2] * 1000 + 5000, s3 - s2)
		assert.equal(45000, s3 + 5000 - s1)
		local phase, d = h.m:phase()
		assert.equal("offline", phase)
		assert.equal("timeout", d.failure)
		assert.is_number(d.since)
		local ph = events(h, "phase")
		assert.equal(1, #ph)
		assert.equal("offline", ph[1][1])
		assert.equal("offline", ph[1][2].event)
		assert.is_false(ph[1][2].online)
		assert.equal("online", ph[1][3])
		assert.is_false(h.data.mf_online, "the Online flag is persisted (D9)")
		assert.is_true(logged(h, "warn", "Fan offline: 3 failures since"))
		assert.same({}, events(h, "settled"), "R7: nothing about the fan's state goes to the proxies")
		assert.equal(1, h.m:confirmed().speed, "the last state is kept")
		local view = h.m:status_view()
		assert.equal("offline", view.phase)
		assert.equal("timeout", view.failure)
		assert.is_true(view.known)
		assert.equal(1, view.st.speed)
	end)

	it("the backoff is 10, 20, 40 and then 60 s, and an offline fan is read every 60 s", function()
		local h = steady(new_harness())
		local gaps, prev = {}, nil
		for _ = 1, 6 do
			local at = attempt(h)
			if prev then gaps[#gaps + 1] = at - prev - 5000 end
			prev = at
		end
		assert.same({ 10000, 20000, 40000, 60000, 60000 }, gaps)
		assert.equal(1, #events(h, "phase"), "staying offline says nothing more")
	end)

	it("P4 a fan that answers with errors is offline of kind 'data'; a refused connection counts as silence", function()
		local h = steady(new_harness())
		for _ = 1, 3 do attempt(h, "http", 500) end
		local phase, d = h.m:phase()
		assert.equal("offline", phase)
		assert.equal("data", d.failure)
		assert.is_true(logged(h, "warn", "http 500"))

		local c = steady(new_harness())
		for _ = 1, 3 do attempt(c, "connect") end
		local _, cd = c.m:phase()
		assert.equal("timeout", cd.failure)
	end)

	it("P2/R8 back online: the contact's differences are reported 'online', then Fan Online; nothing is re-sent",
		function()
			local h = went_offline(steady(new_harness()))
			local sent_before = #h.transport.sent
			clear(h)
			h.clock.advance(h.clock.next_due())
			contact(h, state_json({ fanSpeed = 4, lightOn = true, lightBrightness = 60 }))
			assert.equal("online", h.m:phase())
			local settled = events(h, "settled")
			assert.equal(2, #settled)
			assert.equal("fan", settled[1][1])
			assert.equal(4, settled[1][2].speed)
			assert.equal("online", settled[1][3])
			assert.equal("light", settled[2][1])
			assert.equal(60, settled[2][2].level)
			assert.equal("online", settled[2][3])
			assert.same({}, events(h, "outside"), "coming back is not somebody else's change")
			local order = {}
			for _, n in ipairs(names(h)) do
				if n == "settled" or n == "phase" then order[#order + 1] = n end
			end
			assert.same({ "settled", "settled", "phase" }, order)
			local ph = events(h, "phase")[1]
			assert.equal("online", ph[1])
			assert.equal("online", ph[2].event)
			assert.is_true(ph[2].online)
			assert.equal("offline", ph[3])
			assert.is_true(h.data.mf_online)
			assert.is_true(logged(h, "warn", "Fan online again after 40 s"))
			for i = sent_before + 1, #h.transport.sent do
				assert.not_equal("command", h.transport.sent[i].kind, "nothing is replayed")
			end
			gap(h)
			assert.equal(model.FAST_POLL_MS - model.GAP_MS, h.clock.next_due(), "the fast window opened")
		end)

	it("a long offline is logged in minutes when it ends", function()
		local h = steady(new_harness())
		for _ = 1, 6 do attempt(h) end
		h.clock.advance(h.clock.next_due())
		contact(h)
		assert.is_true(logged(h, "warn", "Fan online again after 3 min"))
	end)

	it("a fan that was never online does not announce an offline it was never in (D9)", function()
		local h = new_harness()
		h.m:start("10.0.2.151")
		h.clock.advance(5000) -- the first contact's info read is already out
		fail(h, "timeout", nil, 5000)
		gap(h)
		attempt(h)
		attempt(h)
		assert.equal("offline", h.m:phase())
		for _, e in ipairs(events(h, "phase")) do
			assert.is_nil(e[2].event, "no event for " .. e[1])
		end
		assert.is_nil(h.m:confirmed(), "nothing was ever read")
	end)

	describe("a Control4 command that meets a fan that does not answer (P8)", function()
		it("a command that times out is dropped at once and the LEDs fall back", function()
			local h = steady(new_harness())
			assert.is_true(h.m:want({ fan_on = true, speed = 3 }))
			assert.equal(3, h.m:shown().speed)
			h.clock.advance(5000)
			fail(h, "timeout", nil, 5000)
			assert.is_false(h.m:busy("fan"))
			assert.equal(1, h.m:shown().speed)
			assert.is_true(logged(h, "warn", "Fan not answering: speed 3 not sent"))
			assert.equal(1, h.m:debug().failures)
			gap(h)
			h.clock.advance(h.clock.next_due())
			assert.equal("info", pending(h).kind, "the retry is a contact, not a replay")
		end)

		it("while offline it is one try through a contact; failing, it is dropped and never replayed", function()
			local h = went_offline(steady(new_harness()))
			clear(h)
			assert.is_true(h.m:want({ fan_on = true, speed = 3 }))
			assert.equal("info", last_sent(h).kind, "nothing goes to an unverified fan")
			assert.equal(3, h.m:shown().speed)
			h.clock.advance(5000)
			fail(h, "timeout", nil, 5000)
			assert.is_true(logged(h, "warn", "Fan not answering: speed 3 not sent"))
			assert.is_false(h.m:busy("fan"))
			local shown = events(h, "shown")
			assert.equal(2, #shown)
			assert.equal(3, shown[1][1].speed)
			assert.equal(1, shown[2][1].speed)
			gap(h)
			h.clock.advance(h.clock.next_due())
			contact(h)
			gap(h)
			h.clock.advance(60000)
			for _, s in ipairs(h.transport.sent) do
				assert.not_equal("command", s.kind)
			end
		end)

		it("when the fan has come back, the command goes out after the contact verified it", function()
			local h = went_offline(steady(new_harness()))
			assert.is_true(h.m:want({ fan_on = true, speed = 3 }))
			assert.equal("info", last_sent(h).kind)
			ok(h, h.info)
			gap(h)
			assert.equal("state", last_sent(h).kind)
			ok(h, h.state)
			assert.equal("online", h.m:phase())
			gap(h)
			assert.equal("command", last_sent(h).kind)
			assert.equal('{"fanOn":true,"fanSpeed":3}', last_sent(h).body)
			clear(h)
			ok(h, state_json({ fanSpeed = 3 }))
			local settled = events(h, "settled")
			assert.equal(1, #settled)
			assert.equal("fan", settled[1][1])
			assert.equal("command", settled[1][3])
		end)
	end)
end)

describe("fan.model Reboot Fan (6.4, V23, P6)", function()
	local function reboot(h)
		local got = {}
		h.m:reboot(function(key, args) got.key, got.args = key, args end)
		return got
	end

	it("V23 while online: the request goes first, the phase is rebooting, commands are refused", function()
		local h = steady(new_harness())
		local got = reboot(h)
		assert.equal("reboot_sent", got.key)
		assert.equal(h.clock.secs(), got.args.at)
		assert.equal("rebooting", h.m:phase())
		local s = last_sent(h)
		assert.equal("reboot", s.kind)
		assert.equal("/mf", s.path)
		assert.equal('{"reboot":true}', s.body)
		assert.equal(3, s.timeout)
		local ph = events(h, "phase")
		assert.equal("rebooting", ph[1][1])
		assert.is_nil(ph[1][2].online, "the Online flag is not touched while rebooting")
		assert.is_nil(ph[1][2].event)
		assert.same({ false, "rebooting" }, { h.m:want({ fan_on = false }) })
		assert.equal("rebooting", h.m:status_view().phase)
		assert.equal(got.args.at, h.m:status_view().sent)
	end)

	it("a command wanted just before is dropped with a log line", function()
		local h = steady(new_harness())
		h.clock.advance(h.clock.next_due()) -- a poll is in flight
		assert.is_true(h.m:want({ fan_on = true, speed = 3 }))
		reboot(h)
		assert.is_true(logged(h, "warn", "Rebooting the fan: speed 3 not sent"))
		assert.is_false(h.m:busy("fan"))
	end)

	it("the reboot's own outcome is ignored; the info read every 10 s is the way back, without events", function()
		local h = steady(new_harness())
		reboot(h)
		h.clock.advance(3000)
		fail(h, "timeout", nil, 3000) -- the fan drops the connection
		assert.equal(0, h.m:debug().failures)
		assert.equal("rebooting", h.m:phase())
		gap(h)
		assert.equal(model.REBOOT_POLL_S * 1000 - model.GAP_MS, h.clock.next_due())
		h.clock.advance(h.clock.next_due())
		assert.equal("info", pending(h).kind)
		fail(h, "connect", nil, 10) -- still starting up
		gap(h)
		assert.equal(0, h.m:debug().failures, "silence is expected")
		assert.equal("rebooting", h.m:phase())
		h.clock.advance(h.clock.next_due())
		clear(h)
		contact(h, state_json({ fanSpeed = 2 }))
		assert.equal("online", h.m:phase())
		local ph = events(h, "phase")
		assert.equal(1, #ph)
		assert.equal("online", ph[1][1])
		assert.is_nil(ph[1][2].event, "the Online variable never left 1")
		assert.is_true(ph[1][2].online)
		local settled = events(h, "settled")
		assert.equal(1, #settled)
		assert.equal(2, settled[1][2].speed)
		assert.equal("online", settled[1][3])
		assert.is_true(h.data.mf_online ~= false)
	end)

	it("after REBOOT_WINDOW_S of silence the fan is offline with Fan Offline, and comes back with Fan Online", function()
		local h = steady(new_harness())
		reboot(h)
		fail(h, "connect", nil, 10)
		local t0 = h.clock.ms
		local reads = 0
		while h.m:phase() == "rebooting" and h.clock.ms - t0 <= model.REBOOT_WINDOW_S * 1000 + 5000 do
			h.clock.advance(h.clock.next_due())
			if pending(h) then
				reads = reads + 1
				fail(h, "connect", nil, 10)
			end
		end
		assert.equal("offline", h.m:phase())
		assert.is_true(reads >= 10 and reads <= 12, "reads: " .. reads)
		local last = events(h, "phase")
		last = last[#last]
		assert.equal("offline", last[1])
		assert.equal("offline", last[2].event)
		assert.equal("timeout", last[2].failure)
		assert.is_false(h.data.mf_online)
		gap(h)
		clear(h)
		h.clock.advance(h.clock.next_due())
		contact(h)
		assert.equal("online", h.m:phase())
		local ph = events(h, "phase")
		assert.equal("online", ph[#ph][2].event)
	end)

	it("a read in flight at the deadline decides: silence ends it, an answer in time counts", function()
		local function to_the_last_read(h)
			reboot(h)
			fail(h, "connect", nil, 10)
			local t0 = h.clock.ms
			while true do
				h.clock.advance(h.clock.next_due())
				if pending(h) then
					if h.clock.ms - t0 >= model.REBOOT_WINDOW_S * 1000 - 8000 then return t0 end
					h.clock.advance(5000)
					fail(h, "timeout", nil, 5000)
				end
			end
		end
		local h = steady(new_harness())
		local t0 = to_the_last_read(h)
		h.clock.advance(t0 + model.REBOOT_WINDOW_S * 1000 - h.clock.ms + 100) -- the deadline passes mid-read
		assert.equal("rebooting", h.m:phase(), "the read in flight decides")
		fail(h, "timeout", nil, 5000)
		assert.equal("offline", h.m:phase())

		local a = steady(new_harness())
		local t1 = to_the_last_read(a)
		a.clock.advance(t1 + model.REBOOT_WINDOW_S * 1000 - a.clock.ms + 100)
		assert.equal("rebooting", a.m:phase())
		ok(a, a.info)
		gap(a)
		ok(a, a.state)
		assert.equal("online", a.m:phase())
		assert.is_nil(events(a, "phase")[#events(a, "phase")][2].event)
	end)

	it("a second Reboot Fan while rebooting, or one while offline, unset or foreign, is answered, not sent", function()
		local h = steady(new_harness())
		local first = reboot(h)
		local n = #h.transport.sent
		local again = reboot(h)
		assert.equal("reboot_pending", again.key)
		assert.equal(first.args.at, again.args.at)
		assert.equal(n, #h.transport.sent)

		local o = steady(new_harness())
		for _ = 1, 3 do
			o.clock.advance(o.clock.next_due())
			o.clock.advance(5000)
			fail(o, "timeout", nil, 5000)
			gap(o)
		end
		assert.equal("reboot_offline", reboot(o).key)

		local u = new_harness()
		assert.equal("reboot_refused", reboot(u).key)
		local f = steady(new_harness())
		poll(f, state_json({ clientId = OTHER.clientId }))
		assert.equal("foreign", f.m:phase())
		assert.equal("reboot_refused", reboot(f).key)

		for _, verdict in ipairs({ { "gen4", { systemType = "fan_g4" } }, { "notfan", { systemType = "router" } } }) do
			local g = new_harness()
			g.m:start("10.0.2.151")
			fail(g, "http", 404)
			gap(g)
			ok(g, verdict[2])
			assert.equal(verdict[1], g.m:phase())
			assert.equal("reboot_refused", reboot(g).key)
			assert.equal("g4", last_sent(g).kind, "nothing was sent for the reboot")
		end
	end)

	it("a callback that raises is contained", function()
		local h = steady(new_harness())
		h.m:reboot(function() error("boom") end)
		assert.is_true(logged(h, "error", "the Reboot Fan callback failed"))
		assert.equal("rebooting", h.m:phase())
	end)
end)

describe("fan.model address changes (3.5, N1, S1, S3, S4)", function()
	it("N1 a new address: a new epoch, the request in flight given up, the same fan followed there (L2)", function()
		local h = steady(new_harness())
		h.clock.advance(h.clock.next_due()) -- a poll is in flight
		local epoch = h.transport.epoch
		assert.is_nil(h.m:set_address("10.0.2.152"))
		assert.equal(epoch + 1, h.transport.epoch)
		assert.equal("10.0.2.152", h.transport.address)
		assert.equal("waiting", h.m:phase())
		assert.equal("info", pending(h).kind)
		clear(h)
		contact(h)
		gap(h)
		assert.equal("online", h.m:phase())
		assert.equal("10.0.2.152", h.m:identity().address)
		assert.equal("10.0.2.152", h.data.mf_identity.address)
		local res = events(h, "result")
		assert.equal(1, #res)
		assert.equal("moved", res[1][1])
		assert.equal("10.0.2.152", res[1][2].address)
		assert.equal(1, #events(h, "info"))
		assert.same({}, events(h, "settled"), "nothing changed on the fan")
	end)

	it("N3 another fan at the new address: foreign, the pin and the old address are kept", function()
		local h = steady(new_harness())
		assert.is_nil(h.m:set_address("10.0.2.152"))
		ok(h, info_json(OTHER))
		assert.equal("foreign", h.m:phase())
		assert.equal("MF_00005E005301", h.m:identity().client_id)
		assert.equal("10.0.2.151", h.m:identity().address)
		assert.same({ false, "foreign" }, { h.m:want({ fan_on = false }) })
		assert.equal("MF_00005E005302", h.m:status_view().other)
	end)

	it("S1 an empty address stops everything but keeps the pin; typing the old address back resumes", function()
		local h = steady(new_harness())
		clear(h)
		assert.is_nil(h.m:set_address(""))
		assert.equal("unset", h.m:phase())
		assert.is_nil(h.transport.address)
		assert.equal(0, h.clock.active())
		assert.is_nil(pending(h))
		assert.equal("MF_00005E005301", h.m:identity().client_id)
		local ph = events(h, "phase")
		assert.equal("unset", ph[1][1])
		assert.is_false(ph[1][2].online)
		assert.is_nil(ph[1][2].event, "unset turns the flag off without an event")
		assert.is_false(h.data.mf_online)
		assert.same({ false, "unset" }, { h.m:want({ fan_on = false }) })
		clear(h)
		assert.is_nil(h.m:set_address("10.0.2.151"))
		contact(h)
		assert.equal("online", h.m:phase())
		assert.equal("MF_00005E005301", h.m:identity().client_id)
		assert.same({}, events(h, "result"), "the same fan at the same address: nothing moved")
		local back = events(h, "phase")
		assert.equal("online", back[#back][2].event)
	end)

	it("S3 text that is not an IPv4 address: 'invalid', nothing sent, the text kept for Status; spaces are trimmed",
		function()
			local h = steady(new_harness())
			assert.equal("invalid", h.m:set_address("fan.local"))
			assert.equal("unset", h.m:phase())
			assert.equal("fan.local", h.m:status_view().typed)
			assert.is_nil(h.transport.address)
			assert.same({ false, "invalid address" }, { h.m:want({ fan_on = false }) })
			assert.equal("invalid", h.m:set_address("192.0.2.256"))
			assert.is_nil(h.m:set_address("  10.0.2.151  "))
			assert.equal("10.0.2.151", h.transport.address)
			assert.equal("", h.m:status_view().typed)
		end)

	it("S4 the same address typed again restarts the contact on a new epoch", function()
		local h = steady(new_harness())
		local epoch = h.transport.epoch
		assert.is_nil(h.m:set_address("10.0.2.151"))
		assert.equal(epoch + 1, h.transport.epoch)
		assert.equal("info", pending(h).kind)
		assert.equal("waiting", h.m:phase())
	end)

	it("a command wanted while the address changes waits for the contact; it is dropped if the contact fails", function()
		local h = steady(new_harness())
		assert.is_nil(h.m:set_address("10.0.2.152"))
		assert.is_true(h.m:want({ fan_on = true, speed = 3 }))
		assert.equal("info", last_sent(h).kind)
		ok(h, h.info)
		gap(h)
		assert.equal("state", last_sent(h).kind)
		ok(h, h.state)
		gap(h)
		assert.equal('{"fanOn":true,"fanSpeed":3}', last_sent(h).body)

		local f = steady(new_harness())
		assert.is_nil(f.m:set_address("10.0.2.152"))
		assert.is_true(f.m:want({ fan_on = true, speed = 3 }))
		f.clock.advance(5000)
		fail(f, "timeout", nil, 5000) -- the read that was already out is not the command's try
		assert.is_true(f.m:busy("fan"))
		gap(f)
		assert.equal("info", pending(f).kind, "the command forces its own try")
		f.clock.advance(5000)
		fail(f, "timeout", nil, 5000)
		assert.is_false(f.m:busy("fan"))
		assert.is_true(logged(f, "warn", "Fan not answering: speed 3 not sent"))
	end)

	it("an address that is typed while the old one is being read: the late answer is never state (P9)", function()
		local h = steady(new_harness())
		h.clock.advance(h.clock.next_due())
		assert.is_nil(h.m:set_address("10.0.2.152"))
		local entry, result = h.transport:late_answer({ ok = true, code = 200, json = state_json({ fanSpeed = 6 }), ms = 9 })
		clear(h)
		entry.cb(result)
		assert.same({}, h.events)
		assert.equal("info", pending(h).kind, "the new contact is untouched")
	end)
end)

describe("fan.model Use Selected Fan (3.5, L2 to L7, L21, D18)", function()
	local function use(h, address, mac12)
		local got = {}
		h.m:use_fan(address, mac12, function(key, args) got.key, got.args = key, args end)
		return got
	end

	it("L4 the pinned fan at the address in use: one info read, 'already', and the polling resumes", function()
		local h = steady(new_harness())
		local got = use(h, "10.0.2.151")
		assert.equal("info", pending(h).kind)
		assert.equal("10.0.2.151", h.transport.address)
		ok(h, h.info)
		assert.equal("already", got.key)
		assert.equal("10.0.2.151", got.args.address)
		gap(h)
		assert.equal("info", pending(h).kind, "a contact resumes the polling")
		assert.equal("10.0.2.151", h.m:identity().address)
	end)

	it("L2 the pinned fan elsewhere: followed, the address stored, then one state read", function()
		local h = steady(new_harness())
		local got = use(h, "10.0.2.152", "00005E005301")
		assert.equal("10.0.2.152", h.transport.address)
		assert.equal("info", pending(h).kind)
		clear(h)
		ok(h, h.info)
		assert.equal("moved", got.key)
		assert.equal("10.0.2.152", got.args.address)
		assert.equal("10.0.2.152", h.m:identity().address)
		assert.equal("10.0.2.152", h.data.mf_identity.address)
		assert.equal("waiting", h.m:phase())
		assert.equal(1, #events(h, "info"))
		gap(h)
		assert.equal("state", last_sent(h).kind, "the info read is not repeated")
		ok(h, h.state)
		assert.equal("online", h.m:phase())
		local infos = 0
		for _, k in ipairs(kinds(h)) do
			if k == "info" then infos = infos + 1 end
		end
		assert.equal(2, infos, "the contact's own read at the start and the one Use Selected Fan made")
	end)

	it("L3/D18 another fan, picked: re-pointed. The pin and info are replaced, the state comes back as changes", function()
		local h = steady(new_harness())
		assert.is_true(h.m:want({ direction = "reverse" }))
		local got = use(h, "10.0.2.152", "00005E005302")
		ok(h, info_json(OTHER))
		assert.equal("now_using", got.key)
		assert.equal("MF_00005E005302", got.args.client_id)
		assert.equal("MF_00005E005301", got.args.was)
		assert.equal("MF_00005E005302", h.m:identity().client_id)
		assert.equal("10.0.2.152", h.m:identity().address)
		assert.equal("MF_00005E005302", h.data.mf_identity.client_id)
		assert.is_nil(h.m:confirmed(), "nothing is known about the new fan yet")
		assert.is_false(h.m:busy("direction"), "what was wanted of the old fan is dropped")
		assert.equal(1, #events(h, "info"))
		gap(h)
		clear(h)
		ok(h, state_json({ clientId = OTHER.clientId, fanSpeed = 5 }))
		assert.equal("online", h.m:phase())
		local settled = events(h, "settled")
		assert.equal(1, #settled)
		assert.equal("fan", settled[1][1])
		assert.equal(5, settled[1][2].speed)
		assert.equal("online", settled[1][3])
	end)

	it("L3 with no fan pinned yet, a pick is learned the same way", function()
		local h = new_harness()
		assert.is_nil(h.m:start(""))
		local got = use(h, "10.0.2.151")
		ok(h, h.info)
		assert.equal("now_using", got.key)
		assert.is_nil(got.args.was)
		gap(h)
		ok(h, h.state)
		assert.equal("online", h.m:phase())
		assert.equal("MF_00005E005301", h.m:identity().client_id)
		assert.equal("3", h.m:identity().generation)
	end)

	it("L5 no answer: nothing changes, the old address is back with a contact", function()
		local h = steady(new_harness())
		local pin = h.m:identity()
		local got = use(h, "10.0.2.152")
		h.clock.advance(5000)
		fail(h, "timeout", nil, 5000)
		assert.equal("no_answer", got.key)
		assert.equal("10.0.2.152", got.args.address)
		assert.equal("10.0.2.151", h.transport.address)
		assert.same(pin, h.m:identity())
		gap(h)
		assert.equal("info", pending(h).kind)
	end)

	it("L6 something that is not a Gen 1-3 fan (a 404, a page, no mac): nothing changes", function()
		local h = steady(new_harness())
		local got = use(h, "10.0.2.152")
		fail(h, "http", 404, 100)
		assert.equal("not_a_fan", got.key)
		assert.equal("10.0.2.151", h.transport.address)
		gap(h)
		pending(h)
		local g = use(h, "10.0.2.152")
		ok(h, { hello = "world" })
		assert.equal("not_a_fan", g.key)
	end)

	it("L21 a pick whose fan answers with another MAC is not used", function()
		local h = steady(new_harness())
		local got = use(h, "10.0.2.152", "00005E005399")
		ok(h, h.info)
		assert.equal("not_picked", got.key)
		assert.equal("10.0.2.151", h.transport.address)
		assert.equal("10.0.2.151", h.m:identity().address)
	end)

	it("L7 no usable address: 'nothing_to_use', nothing is sent", function()
		local h = steady(new_harness())
		local n = #h.transport.sent
		assert.equal("nothing_to_use", use(h, "").key)
		assert.equal("nothing_to_use", use(h, "banana").key)
		assert.equal("nothing_to_use", use(h, nil).key)
		assert.equal(n, #h.transport.sent)
		assert.equal("10.0.2.151", h.transport.address)
	end)

	it("a second click while the first read is out answers the first with 'no_answer'", function()
		local h = steady(new_harness())
		local first = use(h, "10.0.2.152")
		local second = use(h, "192.0.2.153")
		assert.equal("no_answer", first.key)
		assert.equal("10.0.2.152", first.args.address)
		assert.is_nil(second.key)
		assert.equal("192.0.2.153", h.transport.address)
	end)

	it("a callback that raises is contained", function()
		local h = steady(new_harness())
		h.m:use_fan("10.0.2.152", nil, function() error("boom") end)
		ok(h, h.info)
		assert.is_true(logged(h, "error", "the Use Selected Fan callback failed"))
	end)
end)

describe("fan.model Turn Off Away Mode / Adaptive Learning (L14 to L19, A5, A6)", function()
	local function off(h, which)
		local got = {}
		h.m:turn_off(which, function(key, args) got.key, got.args = key, args end)
		return got
	end

	it("L14 away mode on: the body goes out; the answer that shows it off ends it, and the automations follow", function()
		local h = steady(new_harness(), state_json({ awayModeEnabled = true }))
		local got = off(h, "away")
		local s = last_sent(h)
		assert.equal("command", s.kind)
		assert.equal('{"awayModeEnabled":false}', s.body)
		clear(h)
		ok(h, state_json({ awayModeEnabled = false }))
		assert.equal("away_off", got.key)
		assert.equal("away", got.args.which)
		local auto = events(h, "automations")
		assert.equal(1, #auto)
		assert.is_false(auto[1][1].away)
	end)

	it("L15 away mode already off: answered at once, nothing sent", function()
		local h = steady(new_harness())
		local n = #h.transport.sent
		assert.equal("away_already", off(h, "away").key)
		assert.equal(n, #h.transport.sent)
	end)

	it("L16 the fan keeps away mode on: 'not_taken'", function()
		local h = steady(new_harness(), state_json({ awayModeEnabled = true }))
		local got = off(h, "away")
		ok(h, state_json({ awayModeEnabled = true }))
		assert.equal("not_taken", got.key)
	end)

	it("L17 adaptive learning has its own body and keys", function()
		local h = steady(new_harness(), state_json({ adaptiveLearning = true }))
		local got = off(h, "learning")
		assert.equal('{"adaptiveLearning":false}', last_sent(h).body)
		ok(h, state_json({ adaptiveLearning = false }))
		assert.equal("learning_off", got.key)
		assert.equal("learning_already", off(steady(new_harness()), "learning").key)
	end)

	it("L18 not online (offline, unset, waiting): 'not_answering', nothing sent", function()
		local u = new_harness()
		assert.equal("not_answering", off(u, "away").key)
		assert.equal(0, #u.transport.sent)
		local w = new_harness()
		w.m:start("10.0.2.151")
		local n = #w.transport.sent
		assert.equal("not_answering", off(w, "away").key)
		assert.equal(n, #w.transport.sent)
	end)

	it("L19 the request fails: 'not_answering', and the click is not tried again", function()
		local h = steady(new_harness(), state_json({ awayModeEnabled = true }))
		local got = off(h, "away")
		h.clock.advance(5000)
		fail(h, "timeout", nil, 5000)
		assert.equal("not_answering", got.key)
		gap(h)
		h.clock.advance(60000)
		local n = 0
		for _, s in ipairs(h.transport.sent) do
			if s.body == '{"awayModeEnabled":false}' then n = n + 1 end
		end
		assert.equal(1, n)
	end)

	it("an unknown switch is refused", function()
		local h = steady(new_harness())
		assert.equal("not_answering", off(h, "schedule").key)
	end)

	it("a click wanted behind a read waits for it and keeps its place after a command", function()
		local h = steady(new_harness(), state_json({ awayModeEnabled = true }))
		assert.is_true(h.m:want({ fan_on = true, speed = 2 }))
		local got = off(h, "away")
		assert.equal('{"fanOn":true,"fanSpeed":2}', last_sent(h).body)
		ok(h, state_json({ fanSpeed = 2, awayModeEnabled = true }))
		gap(h)
		assert.equal('{"awayModeEnabled":false}', last_sent(h).body)
		ok(h, state_json({ fanSpeed = 2 }))
		assert.equal("away_off", got.key)
	end)
end)

describe("fan.model persistence and restore (8, D9, F1, D10)", function()
	local function stored(over)
		local data = {
			mf_identity = with({}, PIN),
			mf_info = {
				fan_type = "1811-5-54", light_type = "F4IN-120V-R1-30", motor_type = "DC125X20",
				firmware = "02.00.0052", mcu_firmware = "03.00.0000", firmware_since = "2026-10-20",
			},
			mf_online = true,
		}
		for k, v in pairs(over or {}) do
			if v == NIL then data[k] = nil else data[k] = v end
		end
		return data
	end

	local function writes_of(h, key)
		local out = {}
		for _, w in ipairs(h.writes) do
			if w[1] == key then out[#out + 1] = w[2] end
		end
		return out
	end

	-- The pending request times out after 5 s and the gap passes.
	local function silent(h)
		assert(pending(h), "a request should be in flight")
		h.clock.advance(5000)
		fail(h, "timeout", nil, 5000)
		gap(h)
	end

	-- Three failures: the request already out, then two more at the backoff.
	local function fail_three(h)
		silent(h)
		for _ = 1, 2 do
			h.clock.advance(h.clock.next_due())
			silent(h)
		end
	end

	it("the pin and the static data are known at start; the state is never restored (R6)", function()
		local h = new_harness({ store = stored() })
		assert.is_nil(h.m:start("10.0.2.151"))
		assert.equal("MF_00005E005301", h.m:identity().client_id)
		assert.equal("02.00.0052", h.m:info().firmware)
		assert.is_true(h.m:info().has_light)
		assert.is_nil(h.m:confirmed())
		assert.equal("waiting", h.m:phase())
		assert.same({}, events(h, "settled"))
		contact(h)
		assert.equal(3, #events(h, "settled"))
		for _, e in ipairs(events(h, "settled")) do assert.equal("start", e[3]) end
	end)

	it("nothing is written when nothing changed", function()
		local h = new_harness({ store = stored() })
		h.m:start("10.0.2.151")
		contact(h)
		assert.same({}, h.writes)
		assert.same({}, events(h, "info"))
		assert.same({}, events(h, "result"))
		assert.equal("2026-10-20", h.m:info().firmware_since)
		assert.is_nil(h.m:info().firmware_was)
	end)

	it("D9 online before the restart and online again: no Fan Online for a fan that never left", function()
		local h = new_harness({ store = stored({ mf_online = true }) })
		h.m:start("10.0.2.151")
		contact(h)
		for _, e in ipairs(events(h, "phase")) do
			assert.is_nil(e[2].event, e[1])
		end
	end)

	it("D9 offline before the restart and reachable now: Fan Online", function()
		local h = new_harness({ store = stored({ mf_online = false }) })
		h.m:start("10.0.2.151")
		contact(h)
		local ph = events(h, "phase")
		assert.equal("online", ph[#ph][2].event)
		assert.same({ true }, writes_of(h, "mf_online"))
	end)

	it("D9 online before the restart and unreachable now: Fan Offline after three failures", function()
		local h = new_harness({ store = stored({ mf_online = true }) })
		h.m:start("10.0.2.151")
		fail_three(h)
		local ph = events(h, "phase")
		assert.equal("offline", ph[#ph][1])
		assert.equal("offline", ph[#ph][2].event)
		assert.same({ false }, writes_of(h, "mf_online"))
	end)

	it("D9 offline before the restart and still unreachable: no event", function()
		local h = new_harness({ store = stored({ mf_online = false }) })
		h.m:start("10.0.2.151")
		fail_three(h)
		assert.equal("offline", h.m:phase())
		for _, e in ipairs(events(h, "phase")) do
			assert.is_nil(e[2].event, e[1])
		end
	end)

	it("F1 a firmware change is recorded with the date and the old version, announced and persisted", function()
		local h = new_harness({ store = stored() })
		h.m:start("10.0.2.151")
		clear(h)
		contact(h, nil, info_json({ firmwareVersion = "02.00.0060" }))
		local info = h.m:info()
		assert.equal("02.00.0060", info.firmware)
		assert.equal("02.00.0052", info.firmware_was)
		assert.equal("2026-10-27", info.firmware_since)
		local written = writes_of(h, "mf_info")
		assert.equal("02.00.0052", written[#written].firmware_was)
		assert.is_true(#events(h, "info") >= 1)
	end)

	it("N10 the first info ever is stamped with today's date", function()
		local h = online(new_harness())
		assert.equal("2026-10-27", h.m:info().firmware_since)
		assert.equal("02.00.0052", h.m:info().firmware)
		assert.is_nil(h.m:info().firmware_was)
	end)

	it("N1 the stored address is old: the Fan Address says where the fan is now, and it is followed", function()
		local h = new_harness({ store = stored() })
		h.m:start("10.0.2.152")
		contact(h)
		assert.equal("10.0.2.152", h.m:identity().address)
		local written = writes_of(h, "mf_identity")
		assert.equal("10.0.2.152", written[#written].address)
		assert.equal("moved", events(h, "result")[1][1])
	end)

	it("D10 the pin parsed from the Fan ID row is used when nothing is stored, and stored at the first contact",
		function()
			local h = new_harness()
			h.m:start("10.0.2.151", { client_id = "MF_00005E005301", mac = "00005E005301" })
			assert.equal("MF_00005E005301", h.m:identity().client_id)
			assert.is_nil(h.data.mf_identity)
			contact(h)
			assert.equal("MF_00005E005301", h.data.mf_identity.client_id)
			assert.same({}, events(h, "result"), "a fan that is known is not learned again")
		end)

	it("what is stored wins over the row", function()
		local h = new_harness({ store = stored() })
		h.m:start("10.0.2.151", { client_id = "MF_00005E005302", mac = "00005E005302" })
		assert.equal("MF_00005E005301", h.m:identity().client_id)
		contact(h)
		assert.equal("online", h.m:phase())
	end)

	it("the first contact of a fan nobody knew learns it and persists plain data only", function()
		local h = new_harness()
		h.m:start("10.0.2.151")
		contact(h)
		assert.equal("learned", events(h, "result")[1][1])
		local keys = {}
		for _, w in ipairs(h.writes) do
			keys[w[1]] = true
			if type(w[2]) == "table" then
				for k, x in pairs(w[2]) do
					local t = type(x)
					assert.is_true(t == "string" or t == "number" or t == "boolean", w[1] .. "." .. tostring(k))
				end
			end
		end
		assert.same({ mf_identity = true, mf_info = true, mf_online = true }, keys)
		assert.equal("3", h.data.mf_identity.generation)
	end)

	it("the identity is written when it changes, not at every contact", function()
		local h = online(new_harness())
		local n = #writes_of(h, "mf_identity")
		assert.equal(1, n)
		h.m:set_address("10.0.2.151")
		contact(h)
		assert.equal(n, #writes_of(h, "mf_identity"))
	end)

	it("a store that raises is contained: logged, and the driver goes on", function()
		local h = new_harness()
		h.store.set = function() error("disk full") end
		h.m:start("10.0.2.151")
		contact(h)
		assert.equal("online", h.m:phase())
		assert.is_true(logged(h, "error", "could not persist mf_identity"))

		local g = new_harness()
		g.store.get = function() error("no access") end
		assert.is_nil(g.m:start("10.0.2.151"))
		assert.is_true(logged(g, "error", "could not read mf_identity"))
		contact(g)
		assert.equal("online", g.m:phase())
	end)

	it("data of the wrong shape in the store is ignored", function()
		local h = new_harness({ store = { mf_identity = "x", mf_info = 5, mf_online = "yes" } })
		assert.is_nil(h.m:start("10.0.2.151"))
		assert.is_nil(h.m:identity())
		assert.is_nil(h.m:info())
		local g = new_harness({ store = { mf_identity = {}, mf_info = {} } })
		g.m:start("10.0.2.151")
		assert.is_nil(g.m:identity())
		contact(g)
		assert.equal("MF_00005E005301", g.m:identity().client_id)
	end)

	it("a stored fan without a light kit keeps the light group out before the first contact", function()
		local info = stored().mf_info
		info.light_type = ""
		local h = new_harness({ store = stored({ mf_info = info }) })
		h.m:start("10.0.2.151")
		assert.is_false(h.m:info().has_light)
		assert.same({ false, "no light kit" }, { h.m:want({ light_on = false }) })
	end)

	it("stop() and start() again: a fresh contact on the same pin", function()
		local h = steady(new_harness())
		h.m:stop()
		assert.equal(0, h.clock.active())
		assert.is_nil(h.m:start("10.0.2.151"))
		assert.equal("waiting", h.m:phase())
		assert.equal("info", pending(h).kind)
		assert.equal("MF_00005E005301", h.m:identity().client_id)
	end)
end)

describe("fan.model views, debug and the odd corners", function()
	it("S1/S3 status_view of a fan with no usable address", function()
		local h = new_harness()
		local v = h.m:status_view()
		assert.equal("unset", v.phase)
		assert.equal("", v.typed)
		assert.is_false(v.known)
		assert.is_nil(v.st)
		h.m:start("fan.local")
		v = h.m:status_view()
		assert.equal("unset", v.phase)
		assert.equal("fan.local", v.typed)
		assert.is_nil(v.address)
	end)

	it("status_view of a fan being contacted, online, foreign and rebooting", function()
		local h = new_harness()
		h.m:start("10.0.2.151")
		local v = h.m:status_view()
		assert.equal("waiting", v.phase)
		assert.equal("10.0.2.151", v.address)
		contact(h)
		gap(h)
		v = h.m:status_view()
		assert.equal("online", v.phase)
		assert.is_true(v.known)
		assert.equal(1, v.st.speed)
		assert.is_true(v.has_light)
		assert.is_true(v.has_wind)
		assert.is_number(v.since)
		assert.is_number(v.now)
		assert.is_nil(v.missing)

		local f = steady(new_harness())
		poll(f, state_json({ clientId = OTHER.clientId }))
		v = f.m:status_view()
		assert.equal("foreign", v.phase)
		assert.equal("MF_00005E005302", v.other)
		assert.equal(1, v.st.speed, "the last state of the fan that was there")

		local r = steady(new_harness())
		r.m:reboot()
		assert.equal("rebooting", r.m:status_view().phase)
		assert.is_number(r.m:status_view().sent)
	end)

	it("S6 the missing keys come and go with the answers", function()
		local h = steady(new_harness(), state_json({ lightBrightness = NIL, lightOn = true }))
		assert.same({ "lightBrightness" }, h.m:status_view().missing)
		assert.same({ false, "no lightBrightness" }, { h.m:want({ light_on = true, level = 30 }) })
		h.state = state_json({ lightOn = true })
		poll(h)
		assert.is_nil(h.m:status_view().missing)
		assert.is_true(h.m:want({ light_on = true, level = 30 }))
	end)

	it("debug() is what the Dev State line shows", function()
		local h = steady(new_harness())
		local d = h.m:debug()
		assert.equal("online", d.phase)
		assert.equal(#h.transport.sent, d.seq)
		assert.equal(h.transport.epoch, d.epoch)
		assert.equal(0, d.failures)
		assert.same({}, d.busy)
		assert.equal(1, d.told.fan)
		assert.equal("forward", d.told.direction)
		assert.equal(0, d.told.light)
		assert.is_true(h.m:want({ fan_on = true, speed = 3 }))
		d = h.m:debug()
		assert.same({ "fan" }, d.busy)
		ok(h, state_json({ fanSpeed = 3 }), 420)
		d = h.m:debug()
		assert.equal(420, d.ms)
		assert.equal(3, d.told.fan)
	end)

	it("every good answer says it was seen, with its time", function()
		local h = steady(new_harness())
		poll(h, nil, 250)
		local seen = events(h, "seen")
		assert.equal(1, #seen)
		assert.equal(h.clock.secs(), seen[1][1])
		assert.equal(250, seen[1][2])
	end)

	it("a state the parser let through with a speed of 9 is clamped to 6 and logged once", function()
		local h = steady(new_harness())
		local real = h.wire.state
		h.wire.state = function(obj)
			local st = real(obj)
			st.speed = 9
			return st
		end
		poll(h, state_json({ fanSpeed = 5 }))
		assert.equal(6, h.m:confirmed().speed)
		assert.is_true(logged(h, "warn", "out-of-range fanSpeed 9"))
		gap(h)
		poll(h)
		local n = 0
		for _, l in ipairs(h.logs) do
			if l.text:find("out-of-range", 1, true) then n = n + 1 end
		end
		assert.equal(1, n)
	end)

	it("H7 values the parser clamped are named once and shown clamped", function()
		local h = steady(new_harness())
		poll(h, state_json({ fanSpeed = 9 }))
		assert.equal(6, h.m:confirmed().speed)
		assert.is_true(logged(h, "warn", "out-of-range fanSpeed 9"))
		gap(h)
		poll(h, state_json({ fanSpeed = 9 }))
		local n = 0
		for _, l in ipairs(h.logs) do
			if l.text:find("out-of-range", 1, true) then n = n + 1 end
		end
		assert.equal(1, n)
	end)

	it("a listener that raises is logged and the others are still called", function()
		local calls = {}
		local h = new_harness({ listener = {
			settled = function() error("boom") end,
			idle = function(group) calls[#calls + 1] = group end,
		} })
		steady(h)
		assert.is_true(h.m:want({ fan_on = true, speed = 3 }))
		ok(h, state_json({ fanSpeed = 3 }))
		assert.is_true(logged(h, "error", "listener settled failed"))
		assert.same({ "fan" }, calls)
	end)

	it("a listener may call back into the model: what it asks is queued, not nested", function()
		local h
		h = new_harness({ listener = {
			idle = function(group)
				if group == "fan" then h.m:want({ direction = "reverse" }) end
			end,
		} })
		steady(h)
		assert.is_true(h.m:want({ fan_on = true, speed = 3 }))
		ok(h, state_json({ fanSpeed = 3 }))
		gap(h)
		assert.equal('{"fanDirection":"reverse"}', last_sent(h).body)
	end)

	it("the model works with a listener that has none of the events", function()
		local h = new_harness()
		h.m = model.new({
			transport = h.transport, wire = h.wire, now = h.clock.now, clock = h.clock.secs,
			timer = h.clock.timer, store = h.store, log = h.log,
		})
		h.transport.on_idle = function() h.m:on_idle() end
		h.m:start("10.0.2.151")
		contact(h)
		assert.equal("online", h.m:phase())
	end)

	it("a log without some levels, and no log at all, are fine", function()
		local h = new_harness()
		h.m = model.new({
			transport = h.transport, wire = h.wire, now = h.clock.now, clock = h.clock.secs,
			timer = h.clock.timer, store = h.store, log = { warn = function() end },
		})
		h.transport.on_idle = function() h.m:on_idle() end
		h.m:start("10.0.2.151")
		contact(h)
		assert.equal("online", h.m:phase())
		local g = new_harness()
		g.m = model.new({
			transport = g.transport, wire = g.wire, now = g.clock.now, clock = g.clock.secs, timer = g.clock.timer,
		})
		g.transport.on_idle = function() g.m:on_idle() end
		g.m:start("10.0.2.151")
		contact(g)
		assert.equal("online", g.m:phase())
	end)

	it("a timer that cannot be armed is logged, not raised", function()
		local h = new_harness()
		h.m = model.new({
			transport = h.transport, wire = h.wire, now = h.clock.now, clock = h.clock.secs,
			timer = function() error("no timers") end, store = h.store, log = h.log,
		})
		h.transport.on_idle = function() h.m:on_idle() end
		h.m:start("10.0.2.151")
		ok(h, h.info)
		assert.is_true(logged(h, "error", "could not arm the"))
	end)

	describe("Dev Request (section 12)", function()
		it("goes through the model's slot only while online and idle; the model does not read the answer", function()
			local h = steady(new_harness())
			local got
			local seq = h.m:request({ kind = "state", path = "/mf", body = h.wire.QUERY_STATE }, function(r) got = r end)
			assert.is_number(seq)
			assert.equal(h.wire.QUERY_STATE, last_sent(h).body)
			assert.same({ nil, "busy" }, { h.m:request({ kind = "state", path = "/mf", body = "{}" }, function() end) })
			ok(h, state_json({ fanSpeed = 2 }))
			assert.equal(2, got.json.fanSpeed)
			assert.equal(1, h.m:confirmed().speed)
			gap(h)
			assert.equal(model.FAST_POLL_MS - model.GAP_MS, h.clock.next_due(), "a read follows soon")
			poll(h, state_json({ fanSpeed = 2 }))
			assert.equal(2, h.m:confirmed().speed)
		end)

		it("is refused when there is no address, no callback, or the fan is not online", function()
			local u = new_harness()
			assert.same({ nil, "no address" }, { u.m:request({ kind = "state", path = "/mf", body = "{}" }, function() end) })
			local h = steady(new_harness())
			assert.same({ nil, "bad request" }, { h.m:request({ kind = "state" }) })
			assert.same({ nil, "bad request" }, { h.m:request("x", function() end) })
			local w = new_harness()
			w.m:start("10.0.2.151")
			assert.same({ nil, "busy" }, { w.m:request({ kind = "state", path = "/mf", body = "{}" }, function() end) })
		end)

		it("a callback that raises is contained", function()
			local h = steady(new_harness())
			h.m:request({ kind = "state", path = "/mf", body = h.wire.QUERY_STATE }, function() error("boom") end)
			ok(h, h.state)
			assert.is_true(logged(h, "error", "the Dev Request callback failed"))
		end)
	end)
end)

describe("fan.model robustness: seeded random operations keep the invariants", function()
	-- A small deterministic generator (Park-Miller; the products stay below 2^53).
	local function rng(seed)
		local x = seed
		return function(n)
			x = (x * 16807) % 2147483647
			return x % n + 1
		end
	end

	local ADDRESSES = { "10.0.2.151", "10.0.2.152", "192.0.2.153", "192.0.2.154", "192.0.2.155" }

	-- The little world the fan answers from: .151 is our fan, .152 another one, .153 a Gen 4 fan,
	-- .154 something that is no fan, .155 nothing at all.
	local function new_world()
		local fans = {
			["10.0.2.151"] = { id = "MF_00005E005301", mac = "00:00:5e:00:53:01", st = {
				fanOn = true, fanSpeed = 1, fanDirection = "forward", lightOn = false, lightBrightness = 100,
				awayModeEnabled = false, adaptiveLearning = false,
			} },
			["10.0.2.152"] = { id = "MF_00005E005302", mac = "00:00:5e:00:53:02", lightless = true, st = {
				fanOn = false, fanSpeed = 4, fanDirection = "reverse", lightOn = true, lightBrightness = 30,
				awayModeEnabled = true, adaptiveLearning = false,
			} },
		}
		return fans
	end

	local function apply(fan, body)
		local st = fan.st
		local on = body:match('"fanOn":(%a+)')
		if on then st.fanOn = on == "true" end
		local speed = body:match('"fanSpeed":(%d+)')
		if speed then st.fanSpeed = tonumber(speed) end
		local dir = body:match('"fanDirection":"(%a+)"')
		if dir then st.fanDirection = dir end
		local lon = body:match('"lightOn":(%a+)')
		if lon then st.lightOn = lon == "true" end
		local level = body:match('"lightBrightness":(%d+)')
		if level then st.lightBrightness = tonumber(level) end
		if body:find('"awayModeEnabled":false', 1, true) then st.awayModeEnabled = false end
		if body:find('"adaptiveLearning":false', 1, true) then st.adaptiveLearning = false end
	end

	local function state_of(fan)
		local o = state_json({ clientId = fan.id })
		for k, v in pairs(fan.st) do o[k] = v end
		return o
	end

	-- Answers the request in flight the way the world would, or with one of the ways it goes wrong.
	local function answer_world(h, world, pick, healthy)
		local p = pending(h)
		local s = h.transport.sent[#h.transport.sent]
		local fan = world[s.address]
		local roll = healthy and 50 or pick(100)
		if roll <= 8 then
			return fail(h, "timeout", nil, 5000)
		elseif roll <= 12 then
			return fail(h, "connect", nil, 20)
		elseif roll <= 15 then
			return fail(h, "http", 500, 50)
		elseif roll <= 17 then
			return fail(h, pick(2) == 1 and "json" or "empty", nil, 50)
		end
		if s.address == "192.0.2.153" then
			if p.kind == "g4" then return ok(h, { systemType = "fan_g4" }) end
			return fail(h, "http", 404, 50)
		elseif s.address == "192.0.2.154" then
			if p.kind == "g4" then return ok(h, { systemType = "router" }) end
			return fail(h, "http", 404, 50)
		elseif not fan then
			return fail(h, "timeout", nil, 5000)
		end
		if roll > 90 then -- somebody else changes the fan just now
			fan.st.fanSpeed = pick(6)
			fan.st.fanOn = pick(2) == 1
			fan.st.lightOn = pick(2) == 1
			fan.st.lightBrightness = pick(100)
		end
		if p.kind == "info" then
			return ok(h, info_json({ clientId = fan.id, mac = fan.mac, lightType = fan.lightless and "" or nil }))
		end
		if p.kind == "command" then apply(fan, s.body) end
		if p.kind == "reboot" then return fail(h, "timeout", nil, 3000) end
		local shadow = state_of(fan)
		if not healthy and pick(100) <= 3 then -- an answer that lacks a key (S6)
			shadow[({ "fanOn", "fanSpeed", "fanDirection", "lightOn", "lightBrightness" })[pick(5)]] = nil
		end
		return ok(h, shadow)
	end

	-- What a proxy hears for a group (section 4.1): nil while the fields are not known.
	local function group_value(g, st)
		if g == "fan" then
			if st.fan_on == false then return 0 end
			return st.fan_on == true and st.speed or nil
		elseif g == "direction" then
			return st.direction
		end
		if st.light_on == false then return 0 end
		return st.light_on == true and st.level or nil
	end

	local function run_case(seed, steps)
		local pick = rng(seed)
		local world = new_world()
		local problems = {}
		local h = new_harness()
		local told, last_shown = {}, nil
		local trace = {}
		local function note(text) trace[#trace + 1] = text end
		local function problem(text)
			local from = math.max(1, #trace - 12)
			local lines = {}
			for i = math.max(1, #h.logs - 10), #h.logs do lines[#lines + 1] = h.logs[i].level .. ": " .. h.logs[i].text end
			problems[#problems + 1] = string.format("seed %d: %s\n  after: %s\n  log: %s", seed, text,
				table.concat(trace, "\n         ", from), table.concat(lines, "\n       "))
		end

		-- the invariants that hold at every delivery
		h.m = nil
		local owes = {} -- a group seen busy that has not yet been told it is idle
		local last_flag_event -- the Online variable's events alternate: online, offline, online ...
		local listener = {
			idle = function(group) owes[group] = nil end,
			phase = function(new, d)
				-- unset turns the flag off without an event (section 6.1), so online may follow online
				if new == "unset" then last_flag_event = "offline" end
				if d.event then
					if d.event == last_flag_event or (last_flag_event == nil and d.event ~= "online") then
						problem("the event " .. d.event .. " after " .. tostring(last_flag_event))
					end
					last_flag_event = d.event
				end
				local flag = ({ online = true, unset = false, offline = false, foreign = false, gen4 = false,
					notfan = false })[new]
				if d.online ~= flag then problem("phase " .. new .. " carries online=" .. tostring(d.online)) end
			end,
			settled = function(group, st, why)
				local v = group_value(group, st)
				if v == nil then problem("settled " .. group .. " without a value") end
				if v == told[group] then problem("settled " .. group .. " twice with " .. tostring(v) .. " (" .. why .. ")") end
				told[group] = v
				local phase = h.m:phase()
				if phase ~= "online" then problem("settled " .. group .. " while " .. phase) end
			end,
			shown = function(st)
				local key = table.concat({ tostring(st.fan_on), tostring(st.speed), tostring(st.direction),
					tostring(st.light_on), tostring(st.level) }, "|")
				if key == last_shown then problem("shown twice with the same state") end
				last_shown = key
			end,
		}
		h = new_harness({ listener = listener })
		-- at a quiet point (between operations): what the proxies were told is the confirmed state of
		-- an online fan, and a group that stopped being busy has been told so
		local function check_quiet()
			local m = h.m
			local conf = m:confirmed()
			for _, g in ipairs({ "fan", "direction", "light" }) do
				if m:busy(g) then
					owes[g] = true
				elseif owes[g] then
					problem("group " .. g .. " stopped being busy without idle")
					owes[g] = nil
				end
				if m:phase() == "online" and conf and not m:busy(g) then
					local v = group_value(g, conf)
					if v ~= nil and m:debug().told[g] ~= v then
						problem(string.format("told %s %s but the fan is confirmed at %s", g,
							tostring(m:debug().told[g]), tostring(v)))
					end
				end
			end
		end
		local real_send = h.transport.send
		local last_command, wants_since = nil, 0 -- each Control4 command is tried once (ECM P8)
		h.transport.send = function(t, req, cb)
			local phase = h.m:phase()
			if req.kind == "command" then
				if req.body == last_command and wants_since == 0 then problem("the command " .. req.body .. " was sent twice") end
				last_command, wants_since = req.body, 0
			end
			if req.kind == "command" and phase ~= "online" then problem("a command sent while " .. phase) end
			if req.kind == "reboot" and phase ~= "rebooting" then problem("a reboot sent while " .. phase) end
			if (phase == "foreign" or phase == "gen4" or phase == "notfan") and req.kind == "command" then
				problem("a request to the wrong fan: " .. req.kind)
			end
			return real_send(t, req, cb)
		end
		h.m:start(ADDRESSES[1])

		for step = 1, steps do
			local op = pick(100)
			if op <= 40 then
				local p = pending(h)
				if p and pick(10) > 2 then
					local sent = h.transport.sent[#h.transport.sent]
					note(string.format("answer %s #%d at %s (%s) in phase %s", p.kind, p.seq, sent.address,
						tostring(sent.body), h.m:phase()))
					answer_world(h, world, pick)
				end
			elseif op <= 70 then
				local due = h.clock.next_due()
				note("advance " .. tostring(due and math.min(due, 30000) or 1000))
				if due then h.clock.advance(math.min(due, 30000)) else h.clock.advance(1000) end
			elseif op <= 78 then
				local fields = ({
					{ fan_on = true, speed = pick(6) }, { fan_on = false }, { direction = pick(2) == 1 and "forward" or "reverse" },
					{ light_on = true, level = pick(100) }, { light_on = false }, { light_on = true },
					{ speed = pick(6) }, { level = pick(100) }, { fan_on = true, speed = 9 },
				})[pick(9)]
				wants_since = wants_since + 1 -- before the call: the request may go out inside it
				local took, why = h.m:want(fields)
				note(string.format("want %s -> %s %s", tostring(fields.fan_on) .. "/" .. tostring(fields.speed) .. "/"
					.. tostring(fields.direction) .. "/" .. tostring(fields.light_on) .. "/" .. tostring(fields.level),
					tostring(took), tostring(why)))
			elseif op <= 82 then
				local text = ({ "10.0.2.151", "10.0.2.152", "192.0.2.153", "192.0.2.154", "192.0.2.155", "", "bogus" })[pick(7)]
				note("set_address " .. text)
				h.m:set_address(text)
			elseif op <= 85 then
				local target = ADDRESSES[pick(#ADDRESSES)]
				note("use_fan " .. target)
				h.m:use_fan(target, pick(3) == 1 and "00005E005301" or nil, function() end)
			elseif op <= 87 then
				note("reboot")
				h.m:reboot(function() end)
			elseif op <= 89 then
				note("turn_off")
				wants_since = wants_since + 1
				h.m:turn_off(pick(2) == 1 and "away" or "learning", function() end)
			elseif op <= 91 then
				note("set_poll_interval")
				h.m:set_poll_interval(pick(130))
			elseif op <= 94 then
				note("late answer")
				if h.transport.abandoned then
					local entry, result = h.transport:late_answer({ ok = true, code = 200, json = state_json(), ms = 10 })
					entry.cb(result)
				end
			elseif op <= 95 then
				note("stop and start")
				h.m:stop()
				h.m:start(ADDRESSES[pick(#ADDRESSES)])
			else
				local ms = pick(3000)
				note("advance " .. ms)
				h.clock.advance(ms)
			end
			for _, l in ipairs(h.logs) do
				if l.level == "error" then
					problem("step " .. step .. " logged an error: " .. l.text)
					h.logs = {}
					break
				end
			end
			if op == 95 then owes = {} end
			check_quiet()
			if #problems > 0 then break end
		end
		if #problems > 0 then return problems, h end

		-- Liveness: a healthy fan at a good address brings everything back to a quiet online state,
		-- whatever happened before, and a command then goes through.
		owes = {}
		local pin = h.m:identity()
		local home = (pin and pin.client_id == "MF_00005E005302") and ADDRESSES[2] or ADDRESSES[1]
		h.m:set_address(home)
		local until_ms = h.clock.ms + 150000
		while h.clock.ms < until_ms do
			if pending(h) then answer_world(h, world, pick, true) end
			local due = h.clock.next_due()
			h.clock.advance(due and math.min(due, 30000) or 1000)
			check_quiet()
		end
		local fan = world[home]
		if h.m:phase() ~= "online" then problem("not back online: " .. h.m:phase()) end
		for _, g in ipairs({ "fan", "direction", "light" }) do
			if h.m:busy(g) then problem("still busy after the settle: " .. g) end
		end
		local conf = h.m:confirmed()
		if conf and (conf.fan_on ~= fan.st.fanOn or conf.speed ~= fan.st.fanSpeed
			or conf.direction ~= fan.st.fanDirection) then
			problem("the confirmed state is not the fan's")
		end
		if conf and not fan.lightless and (conf.light_on ~= fan.st.lightOn or conf.level ~= fan.st.lightBrightness) then
			problem("the confirmed light is not the fan's")
		end
		wants_since = wants_since + 2
		local light_before = h.m:debug().told.light
		h.m:want({ fan_on = true, speed = 4 })
		h.m:want({ light_on = true, level = 55 })
		local end2 = h.clock.ms + 10000
		while h.clock.ms < end2 do
			if pending(h) then answer_world(h, world, pick, true) end
			local due = h.clock.next_due()
			h.clock.advance(due and math.min(due, 5000) or 1000)
		end
		if fan.st.fanSpeed ~= 4 or fan.st.fanOn ~= true then problem("the fan command did not reach the fan") end
		local told_now = h.m:debug().told
		if fan.lightless then
			if told_now.light ~= light_before then problem("a light was reported for a fan without a light kit") end
		else
			if fan.st.lightOn ~= true or fan.st.lightBrightness ~= 55 then
				problem("the light command did not reach the fan")
			end
			if told_now.light ~= 55 then problem("the proxies were told light " .. tostring(told_now.light)) end
		end
		if told_now.fan ~= 4 then problem("the proxies were told fan " .. tostring(told_now.fan)) end
		return problems, h
	end

	-- FUZZ_SEEDS, FUZZ_STEPS and FUZZ_BASE widen or move the run for a deeper local search;
	-- CI uses the defaults.
	it("seeded runs of random operations: nothing raises, no command to a fan that is not verified, R1 and R7 hold",
		function()
			local seeds = tonumber(os.getenv("FUZZ_SEEDS")) or 200
			local steps = tonumber(os.getenv("FUZZ_STEPS")) or 150
			local base = tonumber(os.getenv("FUZZ_BASE")) or 7919
			local all = {}
			for seed = 1, seeds do
				local problems = run_case(seed * base, steps)
				for _, p in ipairs(problems) do all[#all + 1] = p end
				if #all >= 5 then break end
			end
			assert.same({}, all)
		end)
end)

describe("fan.model commands that outlive their moment (found by the random runs)", function()
	local function reboot(h)
		local got = {}
		h.m:reboot(function(key, args) got.key, got.args = key, args end)
		return got
	end

	local function use(h, address, mac12)
		local got = {}
		h.m:use_fan(address, mac12, function(key, args) got.key, got.args = key, args end)
		return got
	end

	local function sent_kinds(h)
		local n = 0
		for _, s in ipairs(h.transport.sent) do
			if s.kind == "command" then n = n + 1 end
		end
		return n
	end

	it("R8 a command dropped after a contact read the fan: the difference is told as 'online', not 'outside'", function()
		local h = went_offline(steady(new_harness()))
		assert.is_true(h.m:want({ fan_on = true, speed = 3 }))
		ok(h, h.info)
		gap(h)
		ok(h, state_json({ fanSpeed = 5 })) -- the fan was changed while it was away; the fan group is busy
		assert.equal("online", h.m:phase())
		assert.same({}, events(h, "settled"), "R5: nothing is told about a busy group")
		gap(h)
		assert.equal('{"fanOn":true,"fanSpeed":3}', last_sent(h).body)
		clear(h)
		h.clock.advance(5000)
		fail(h, "timeout", nil, 5000) -- the command does not get through (tried once)
		local settled = events(h, "settled")
		assert.equal(1, #settled)
		assert.equal("fan", settled[1][1])
		assert.equal(5, settled[1][2].speed)
		assert.equal("online", settled[1][3])
		assert.same({}, events(h, "outside"), "this is not somebody else's change now")
		assert.equal(1, #events(h, "idle"))
	end)

	it("R7 a difference a busy group left is not told while the fan is rebooting; the contact that ends it tells it",
		function()
			local h = steady(new_harness())
			h.clock.advance(h.clock.next_due()) -- a poll is in flight
			assert.is_true(h.m:want({ fan_on = true, speed = 3 }))
			ok(h, state_json({ fanSpeed = 5 })) -- somebody else, meanwhile: the fan group is busy
			clear(h)
			reboot(h)
			assert.same({}, events(h, "settled"), "a rebooting fan tells the proxies nothing")
			assert.equal("fan", events(h, "idle")[1][1], "but the dropped command does let go")
			h.clock.advance(3000)
			fail(h, "timeout", nil, 3000)
			gap(h)
			h.clock.advance(h.clock.next_due())
			clear(h)
			contact(h, state_json({ fanSpeed = 5 }))
			local settled = events(h, "settled")
			assert.equal(1, #settled)
			assert.equal(5, settled[1][2].speed)
			assert.equal("online", settled[1][3])
		end)

	it("a Reboot Fan not yet sent is cancelled by Use Selected Fan; it never follows the transport", function()
		local h = steady(new_harness())
		h.clock.advance(h.clock.next_due()) -- a poll is on the wire: the reboot has to wait for the slot
		local got = reboot(h)
		assert.equal("reboot_sent", got.key)
		assert.equal("rebooting", h.m:phase())
		local picked = use(h, "10.0.2.152", "00005E005301")
		assert.equal("waiting", h.m:phase())
		assert.is_true(logged(h, "warn", "Reboot Fan cancelled before it was sent"))
		ok(h, h.info)
		assert.equal("moved", picked.key)
		gap(h)
		ok(h, h.state)
		assert.equal("online", h.m:phase())
		h.clock.advance(60000)
		for _, k in ipairs(kinds(h)) do
			assert.not_equal("reboot", k)
		end
	end)

	it("L13 Reboot Fan is refused while a Use Selected Fan read is under way", function()
		local h = steady(new_harness())
		use(h, "10.0.2.152")
		local got = reboot(h)
		assert.equal("reboot_refused", got.key)
		assert.equal("online", h.m:phase())
		ok(h, h.info)
		gap(h)
		h.clock.advance(60000)
		for _, k in ipairs(kinds(h)) do
			assert.not_equal("reboot", k)
		end
	end)

	it("P8 a command on the wire when the address changes has had its try: dropped, not sent again", function()
		local h = steady(new_harness())
		assert.is_true(h.m:want({ fan_on = true, speed = 3 }))
		clear(h)
		assert.is_nil(h.m:set_address("10.0.2.152"))
		assert.is_false(h.m:busy("fan"))
		assert.is_true(logged(h, "warn", "Request given up: speed 3 not sent"))
		assert.equal("fan", events(h, "idle")[1][1])
		assert.equal(1, h.m:shown().speed)
		contact(h)
		gap(h)
		h.clock.advance(60000)
		assert.equal(1, sent_kinds(h))
	end)

	it("a command waiting for the slot is kept across an address change and goes out after the contact", function()
		local h = steady(new_harness())
		h.clock.advance(h.clock.next_due()) -- a poll is on the wire
		assert.is_true(h.m:want({ fan_on = true, speed = 3 }))
		assert.is_nil(h.m:set_address("10.0.2.152"))
		contact(h)
		gap(h)
		assert.equal('{"fanOn":true,"fanSpeed":3}', last_sent(h).body)
	end)

	it("an empty address ends what was wanted and lets the groups go (idle)", function()
		local h = steady(new_harness())
		assert.is_true(h.m:want({ fan_on = true, speed = 3 }))
		assert.is_true(h.m:want({ light_on = false }))
		clear(h)
		assert.is_nil(h.m:set_address(""))
		local groups = {}
		for _, e in ipairs(events(h, "idle")) do groups[#groups + 1] = e[1] end
		table.sort(groups)
		assert.same({ "fan", "light" }, groups)
		assert.same({}, events(h, "settled"))
		assert.same({}, h.m:debug().busy)
	end)

	it("stop() ends what was wanted: nothing is sent after a start", function()
		local h = steady(new_harness())
		h.clock.advance(h.clock.next_due())
		assert.is_true(h.m:want({ fan_on = true, speed = 3 }))
		h.m:stop()
		assert.is_false(h.m:busy("fan"))
		assert.is_nil(h.m:start("10.0.2.151"))
		contact(h)
		gap(h)
		h.clock.advance(60000)
		assert.equal(0, sent_kinds(h))
	end)

	it("H4 a light kit that turns out not to be there lets go of what was wanted of the light", function()
		local h = new_harness()
		h.m:start("10.0.2.151")
		assert.is_true(h.m:want({ light_on = true, level = 40 }), "the kit is not known yet")
		clear(h)
		contact(h, nil, info_json({ lightType = "" }))
		assert.is_false(h.m:busy("light"))
		assert.is_true(logged(h, "warn", "No light kit: light 40 not sent"))
		local idle = events(h, "idle")
		assert.equal("light", idle[1][1])
		gap(h)
		h.clock.advance(60000)
		assert.equal(0, sent_kinds(h))
	end)

	it("idle's state is an empty table while nothing has been read", function()
		local h = new_harness()
		h.m:start("10.0.2.151")
		assert.is_true(h.m:want({ fan_on = true, speed = 3 }))
		clear(h)
		h.m:set_address("")
		local idle = events(h, "idle")
		assert.equal("fan", idle[1][1])
		assert.same({}, idle[1][2])
	end)
end)
