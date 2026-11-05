-- fan/transport.lua (docs/v1-design.md sections 9.4, 3.2, 3.3, 4.2 and 10.2):
-- one request in flight, the gap, the options and the header on the transfer,
-- every row of the answer table, late answers of a request given up, stop().
-- Driven with the fake runtime's C4:url transfers and a virtual clock; the
-- ids in the names are the research cases of docs/edge-cases-modernforms.md.

local fake = require("helpers.fake_c4")
local log = require("common.log")
local mf = require("fixtures.mf_gen3")
local wire = require("fan.wire")
local transport = require("fan.transport")

local ADDRESS = "10.0.2.151"

-- Time as a spec moves it: now() in ms, and timers that fire when advance()
-- passes their due time, in due order, those armed on the way included.
local function new_clock()
	local clock = { t = 0, pending = {} }
	function clock.now() return clock.t end
	function clock.timer(ms, cb)
		local timer = { due = clock.t + ms, cb = cb, active = true }
		function timer:Cancel() self.active = false end
		clock.pending[#clock.pending + 1] = timer
		return timer
	end
	function clock.advance(ms)
		local target = clock.t + ms
		while true do
			local next_timer
			for _, timer in ipairs(clock.pending) do
				if timer.active and timer.due <= target and (not next_timer or timer.due < next_timer.due) then
					next_timer = timer
				end
			end
			if not next_timer then break end
			next_timer.active = false
			clock.t = math.max(clock.t, next_timer.due)
			next_timer.cb()
		end
		clock.t = target
	end
	function clock.armed()
		local n = 0
		for _, timer in ipairs(clock.pending) do
			if timer.active then n = n + 1 end
		end
		return n
	end
	return clock
end

local function state_request(kind, body)
	return { kind = kind or "state", path = wire.PATH, body = body or wire.QUERY_STATE }
end

local function command_request()
	return { kind = "command", path = wire.PATH, body = '{"fanOn":true,"fanSpeed":3}' }
end

-- Answer the fake transfer the way Director would, and remember that it ended.
local function answer(transfer, code, body)
	transfer.answered = true
	transfer:respond(code, body)
end

local function fail(transfer, err_code, err_msg)
	transfer.answered = true
	transfer:done(err_code, err_msg)
end

describe("fan.transport", function()
	local c4, clock, t, idle, lines, results

	local function collect(result)
		results[#results + 1] = result
	end

	-- Transfers started and not yet answered.
	local function open_transfers()
		local n = 0
		for _, transfer in ipairs(c4.transfers) do
			if not transfer.answered then n = n + 1 end
		end
		return n
	end

	local function logged(needle)
		for _, line in ipairs(lines) do
			if line:find(needle, 1, true) then return true end
		end
		return false
	end

	before_each(function()
		c4 = fake.install_c4({})
		clock = new_clock()
		idle = { count = 0, at = {} }
		lines = {}
		results = {}
		log.sink = function(line) lines[#lines + 1] = line end
		log.set_debug(true)
		t = transport.new({
			now = clock.now,
			timer = clock.timer,
			url = function() return c4:url() end,
			on_idle = function()
				idle.count = idle.count + 1
				idle.at[#idle.at + 1] = clock.now()
			end,
			log = log,
		})
		t:set_address(ADDRESS)
	end)

	after_each(function()
		log.set_debug(false)
		log.set_prefix(nil)
		log.sink = print
	end)

	describe("construction", function()
		it("needs the clock, the timer and the transfer factory", function()
			local function opts()
				return { now = clock.now, timer = clock.timer, url = function() return c4:url() end }
			end
			assert.has_no.errors(function() transport.new(opts()) end)
			for _, missing in ipairs({ "now", "timer", "url" }) do
				local o = opts()
				o[missing] = nil
				assert.has_error(function() transport.new(o) end, "transport.new: opts." .. missing .. " is required")
			end
			assert.has_error(function() transport.new() end)
		end)

		it("starts without an address: epoch 0, nothing issued, nothing in flight", function()
			local fresh = transport.new({ now = clock.now, timer = clock.timer, url = function() return c4:url() end })
			assert.equal(0, fresh.epoch)
			assert.equal(0, fresh.seq)
			assert.is_nil(fresh.address)
			assert.is_false(fresh:busy())
			assert.same({ nil, "no address" }, { fresh:send(state_request(), collect) })
			assert.equal(0, #c4.transfers)
		end)

		it("works without an on_idle hook and without a log", function()
			local bare = transport.new({ now = clock.now, timer = clock.timer, url = function() return c4:url() end })
			bare:set_address(ADDRESS)
			assert.equal(1, bare:send(state_request(), collect))
			answer(c4.last_transfer(), 200, mf.STATE)
			assert.has_no.errors(function() clock.advance(1000) end)
			assert.equal(1, #results)
		end)
	end)

	describe("set_address", function()
		it("takes a dotted IPv4 address, trimmed, and answers true", function()
			assert.is_true(t:set_address("  10.0.2.152 "))
			assert.equal("10.0.2.152", t.address)
		end)

		it("starts a new epoch on every call, also when the address is unchanged (section 4.2)", function()
			local first = t.epoch
			t:set_address(ADDRESS)
			t:set_address(ADDRESS)
			t:set_address("10.0.2.152")
			assert.equal(first + 3, t.epoch)
		end)

		it("clears the address for nil, \"\" and white space: nothing is sent", function()
			for _, value in ipairs({ "", "   " }) do
				t:set_address(ADDRESS)
				assert.is_true(t:set_address(value))
				assert.is_nil(t.address)
				assert.same({ nil, "no address" }, { t:send(state_request(), collect) })
			end
			t:set_address(ADDRESS)
			assert.is_true(t:set_address(nil))
			assert.same({ nil, "no address" }, { t:send(state_request(), collect) })
			assert.equal(0, #c4.transfers)
		end)

		it("refuses text that is no dotted IPv4 address: false, 'invalid address', nothing is sent (S3)", function()
			local too_big = string.format("10.0.2.%d", 256)
			for _, value in ipairs({ "fan.local", "10.0.2", too_big, "http://10.0.2.151", 10, true, {} }) do
				t:set_address(ADDRESS)
				local epoch = t.epoch
				assert.same({ false, "invalid address" }, { t:set_address(value) }, tostring(value))
				assert.is_nil(t.address)
				assert.equal(epoch + 1, t.epoch)
				assert.same({ nil, "no address" }, { t:send(state_request(), collect) })
			end
			assert.equal(0, #c4.transfers)
		end)
	end)

	describe("the call (section 3.2)", function()
		it("posts the body to http://<address>/mf with the one header and the options", function()
			local seq = t:send(command_request(), collect)
			assert.equal(1, seq)
			local transfer = c4.last_transfer()
			assert.equal("POST", transfer.method)
			assert.equal("http://10.0.2.151/mf", transfer.url)
			assert.equal('{"fanOn":true,"fanSpeed":3}', transfer.data)
			assert.same({ ["Content-Type"] = "application/json" }, transfer.headers)
			assert.same({ timeout = 5, connect_timeout = 3, fail_on_error = false }, transfer.options)
			assert.is_function(transfer.callbacks.done)
			assert.is_nil(transfer.callbacks.headers, "nothing is started from OnHeaders (section 3.2)")
			assert.is_nil(transfer.callbacks.chunk)
		end)

		it("gives each transfer its own copy of the header table", function()
			t:send(state_request(), collect)
			c4.last_transfer().headers["Content-Type"] = "text/plain"
			assert.same({ ["Content-Type"] = "application/json" }, wire.HEADERS)
		end)

		it("sends the Gen 4 probe to /device and nothing else there (section 3.6)", function()
			t:send({ kind = "g4", path = wire.G4_PATH, body = wire.QUERY_G4 }, collect)
			assert.equal("http://10.0.2.151/device", c4.last_transfer().url)
			assert.equal('{"query":true}', c4.last_transfer().data)
		end)

		it("follows the address it was given", function()
			t:set_address("10.0.2.152")
			t:send(state_request(), collect)
			assert.equal("http://10.0.2.152/mf", c4.last_transfer().url)
		end)

		it("times out after 5 s by default, 3 s for a reboot, and as asked within 30 s", function()
			local function timeout_of(req)
				t:set_address(ADDRESS)
				assert(t:send(req, collect))
				return c4.last_transfer().options.timeout
			end
			assert.equal(5, timeout_of(state_request()))
			assert.equal(3, timeout_of({ kind = "reboot", path = wire.PATH, body = wire.REBOOT }))
			assert.equal(7, timeout_of({ kind = "state", path = wire.PATH, body = wire.QUERY_STATE, timeout = 7 }))
			assert.equal(30, timeout_of({ kind = "state", path = wire.PATH, body = wire.QUERY_STATE, timeout = 300 }))
			assert.equal(5, timeout_of({ kind = "state", path = wire.PATH, body = wire.QUERY_STATE, timeout = 0 }))
			assert.equal(5, timeout_of({ kind = "state", path = wire.PATH, body = wire.QUERY_STATE, timeout = "x" }))
			assert.equal(3, timeout_of({ kind = "reboot", path = wire.PATH, body = wire.REBOOT, timeout = -1 }))
		end)

		it("keeps the connect timeout at 3 s for every request", function()
			t:send({ kind = "reboot", path = wire.PATH, body = wire.REBOOT, timeout = 20 }, collect)
			assert.equal(3, c4.last_transfer().options.connect_timeout)
		end)

		it("numbers requests 1, 2, 3 ... for the life of the device, across epochs (section 4.2)", function()
			local first = t.epoch
			assert.equal(1, t:send(state_request(), collect))
			answer(c4.last_transfer(), 200, mf.STATE)
			clock.advance(250)
			t:set_address(ADDRESS)
			assert.equal(2, t:send(state_request(), collect))
			answer(c4.last_transfer(), 200, mf.STATE)
			clock.advance(250)
			assert.equal(3, t:send(state_request(), collect))
			assert.equal(3, t.seq)
			answer(c4.last_transfer(), 200, mf.STATE)
			assert.same({ 1, 2, 3 }, { results[1].seq, results[2].seq, results[3].seq })
			assert.same({ first, first + 1, first + 1 }, { results[1].epoch, results[2].epoch, results[3].epoch })
		end)

		it("never calls back from inside send()", function()
			t:send(state_request(), collect)
			assert.equal(0, #results)
		end)

		it("writes one debug line per request, normalized as in section 3.7, with no address in it", function()
			t:send(command_request(), collect)
			assert.is_true(logged('-> fan #1 command {"fanOn":true,"fanSpeed":3}'))
			for _, line in ipairs(lines) do
				assert.is_nil(line:find(ADDRESS, 1, true), line)
			end
		end)

		it("does not call Cancel(): it ends nothing on OS 3.4.2 and is never relied on", function()
			t:send(state_request(), collect)
			local transfer = c4.last_transfer()
			t:set_address(ADDRESS)
			t:stop()
			assert.is_false(transfer.cancelled)
		end)
	end)

	describe("the single slot (V6)", function()
		it("refuses a second request while one is in flight: nothing is queued, one transfer exists", function()
			assert.equal(1, t:send(state_request(), collect))
			assert.is_true(t:busy())
			assert.same({ nil, "busy" }, { t:send(command_request(), collect) })
			assert.equal(1, #c4.transfers)
			assert.equal(1, t.seq, "a refused request is not numbered")
		end)

		it("stays busy through the 250 ms gap after the answer, then calls on_idle once", function()
			t:send(state_request(), collect)
			clock.advance(310)
			answer(c4.last_transfer(), 200, mf.STATE)
			assert.equal(1, #results)
			assert.is_true(t:busy(), "the gap has begun")
			assert.same({ nil, "busy" }, { t:send(state_request(), collect) })
			clock.advance(249)
			assert.is_true(t:busy())
			assert.equal(0, idle.count)
			clock.advance(1)
			assert.is_false(t:busy())
			assert.equal(1, idle.count)
			assert.same({ 560 }, idle.at, "250 ms after the answer at 310 ms")
			clock.advance(5000)
			assert.equal(1, idle.count, "once per result")
		end)

		it("takes the next request as soon as the gap is over", function()
			t:send(state_request(), collect)
			answer(c4.last_transfer(), 200, mf.STATE)
			clock.advance(250)
			assert.equal(2, t:send(command_request(), collect))
			assert.equal(2, #c4.transfers)
		end)

		it("measures the gap from the end of the request, not from its start", function()
			t:send(state_request(), collect)
			clock.advance(3000)
			fail(c4.last_transfer(), 28, "Timeout was reached")
			assert.equal(3000, results[1].ms)
			clock.advance(249)
			assert.is_true(t:busy())
			clock.advance(1)
			assert.is_false(t:busy())
		end)

		it("runs the callback before on_idle, and refuses a send() made from inside it as busy", function()
			local order, inside = {}, nil
			t:send(state_request(), function(result)
				order[#order + 1] = "cb"
				inside = { t:send(state_request(), collect) }
				results[#results + 1] = result
			end)
			answer(c4.last_transfer(), 200, mf.STATE)
			assert.same({ "cb" }, order)
			assert.same({ nil, "busy" }, inside)
			assert.equal(0, idle.count, "on_idle is called after the callback returned, GAP_MS later")
			clock.advance(250)
			assert.equal(1, idle.count)
		end)

		it("lets on_idle send the next request: the model's own loop, one at a time", function()
			local looping
			local sent = 0
			local function next_request()
				sent = sent + 1
				assert(looping:send(state_request(), collect))
			end
			looping = transport.new({
				now = clock.now,
				timer = clock.timer,
				url = function() return c4:url() end,
				on_idle = function()
					if sent < 3 then next_request() end
				end,
				log = log,
			})
			looping:set_address(ADDRESS)
			next_request()
			for i = 1, 3 do
				assert.equal(i, #c4.transfers)
				assert.equal(1, open_transfers())
				answer(c4.last_transfer(), 200, mf.STATE)
				assert.equal(i, #results)
				clock.advance(250)
			end
			assert.equal(3, #c4.transfers, "after the third answer on_idle sends nothing more")
			assert.is_false(looping:busy())
		end)

		it("keeps its gap and its on_idle when the callback changes the address (Use Selected Fan)", function()
			local inside
			t:send(state_request(), function(result)
				results[#results + 1] = result
				t:set_address("10.0.2.152")
				inside = { t:send(state_request(), collect) }
			end)
			answer(c4.last_transfer(), 200, mf.STATE)
			assert.same({ nil, "busy" }, inside, "still in the gap of the request that just ended")
			clock.advance(250)
			assert.equal(1, idle.count)
			assert.equal(2, t:send(state_request(), collect))
			assert.equal("http://10.0.2.152/mf", c4.last_transfer().url)
		end)

		it("never has two requests in flight over a run of requests", function()
			local most = 0
			for i = 1, 12 do
				local seq = t:send(i % 2 == 0 and command_request() or state_request(), collect)
				assert.equal(i, seq)
				assert.same({ nil, "busy" }, { t:send(state_request(), collect) })
				most = math.max(most, open_transfers())
				answer(c4.last_transfer(), 200, mf.STATE)
				clock.advance(100)
				assert.same({ nil, "busy" }, { t:send(state_request(), collect) }, "still in the gap")
				clock.advance(150)
			end
			assert.equal(1, most)
			assert.equal(12, #results)
			assert.equal(12, idle.count)
		end)

		it("keeps the slot after a failure too: a timeout is followed by its gap (P5)", function()
			t:send(state_request(), collect)
			fail(c4.last_transfer(), 28, "Timeout was reached")
			assert.is_true(t:busy())
			clock.advance(250)
			assert.is_false(t:busy())
			assert.equal(1, idle.count)
		end)
	end)

	describe("answers (section 3.3)", function()
		local function one(respond)
			assert(t:send(state_request(), collect))
			respond(c4.last_transfer())
			return results[#results]
		end

		it("is ok for a 200 whose body is a JSON object: the decoded object, no error class", function()
			clock.advance(7)
			t:send(state_request(), collect)
			clock.advance(310)
			answer(c4.last_transfer(), 200, mf.STATE_ON_3)
			local result = results[1]
			assert.is_true(result.ok)
			assert.is_nil(result.err)
			assert.equal(200, result.code)
			assert.equal(1, result.seq)
			assert.equal("state", result.kind)
			assert.equal(t.epoch, result.epoch)
			assert.equal(310, result.ms)
			assert.equal(3, result.json.fanSpeed)
			assert.equal("MF_00005E005301", result.json.clientId)
		end)

		it("hands on the kind it was sent with: state, info, command, g4, reboot", function()
			for _, kind in ipairs({ "state", "info", "command", "g4", "reboot" }) do
				t:set_address(ADDRESS)
				local path = kind == "g4" and wire.G4_PATH or wire.PATH
				assert(t:send({ kind = kind, path = path, body = '{"x":1}' }, collect))
				answer(c4.last_transfer(), 200, mf.STATE)
				assert.equal(kind, results[#results].kind)
				clock.advance(250)
			end
		end)

		it("calls an object without a clientId 'json' on /mf: no fan's answer (section 3.3, N4)", function()
			for _, kind in ipairs({ "state", "info", "command" }) do
				for _, body in ipairs({ mf.NO_CLIENT, mf.state({ clientId = "" }), mf.state({ clientId = 5 }), "{}" }) do
					t:set_address(ADDRESS)
					assert(t:send({ kind = kind, path = wire.PATH, body = '{"x":1}' }, collect))
					answer(c4.last_transfer(), 200, body)
					local result = results[#results]
					assert.is_false(result.ok, kind .. " " .. body)
					assert.equal("json", result.err, kind .. " " .. body)
					assert.equal(200, result.code)
					assert.is_nil(result.json)
					assert.equal("no clientId", result.detail)
					clock.advance(250)
				end
			end
		end)

		it("does not ask the Gen 4 probe's answer, nor a reboot's, for a clientId", function()
			t:send({ kind = "g4", path = wire.G4_PATH, body = wire.QUERY_G4 }, collect)
			answer(c4.last_transfer(), 200, mf.G4_DEVICE)
			assert.is_true(results[1].ok)
			assert.is_true(wire.is_g4(results[1].json))
			clock.advance(250)
			t:send({ kind = "reboot", path = wire.PATH, body = wire.REBOOT }, collect)
			answer(c4.last_transfer(), 200, '{"reboot":true}')
			assert.is_true(results[2].ok)
		end)

		it("judges nothing else of the fields: whose clientId it is, is the model's (wire.same_fan)", function()
			t:send(state_request(), collect)
			answer(c4.last_transfer(), 200, mf.state({ clientId = "MF_00005E005302", fanSpeed = 9, fanDirection = "up" }))
			assert.is_true(results[1].ok)
			assert.equal("MF_00005E005302", results[1].json.clientId)
		end)

		it("hands on an info answer without the private fields (V20)", function()
			local result = one(function(transfer) answer(transfer, 200, mf.INFO) end)
			assert.is_true(result.ok)
			assert.equal("02.00.0052", result.json.firmwareVersion)
			for _, key in ipairs({ "owner", "federatedIdentity", "deviceName", "SSID", "BSSID" }) do
				assert.is_nil(result.json[key], key)
			end
		end)

		describe("a transfer error is a timeout when it says so, else a connect failure", function()
			local timeouts = {
				{ 28, "Timeout was reached" },
				{ 28, "Operation timed out after 5001 milliseconds with 0 bytes received" },
				{ 28, "" },
				{ 28, nil },
				{ 7, "Failed to connect to 10.0.2.151 port 80: Connection timed out" },
				{ 99, "Resolving timed out after 3000 milliseconds" },
				{ 99, "TIMEOUT" },
			}
			for _, case in ipairs(timeouts) do
				it(string.format("(%s, %s) is a timeout (P5)", tostring(case[1]), tostring(case[2])), function()
					local result = one(function(transfer) fail(transfer, case[1], case[2]) end)
					assert.is_false(result.ok)
					assert.equal("timeout", result.err)
					assert.is_nil(result.code)
					assert.is_nil(result.json)
					assert.is_string(result.detail)
				end)
			end

			local refusals = {
				{ 7, "Failed to connect to 10.0.2.151 port 80: Connection refused" },
				{ 7, "Couldn't connect to server" },
				{ 6, "Could not resolve host: fan.local" },
				{ 52, "Empty reply from server" },
				{ 56, "Recv failure: Connection reset by peer" },
				{ 2, "Failed initialization" },
				{ -1, nil },
			}
			for _, case in ipairs(refusals) do
				it(string.format("(%s, %s) is a connect failure (P1, P4)", tostring(case[1]), tostring(case[2])), function()
					local result = one(function(transfer) fail(transfer, case[1], case[2]) end)
					assert.is_false(result.ok)
					assert.equal("connect", result.err)
					assert.is_nil(result.code)
					assert.is_string(result.detail)
				end)
			end

			it("names the error in the detail, for the log", function()
				local result = one(function(transfer) fail(transfer, 7, "Connection refused") end)
				assert.is_true(result.detail:find("7", 1, true) ~= nil)
				assert.is_true(result.detail:find("Connection refused", 1, true) ~= nil)
			end)
		end)

		describe("a status other than 200 is an http failure", function()
			it("keeps the 404 of a Gen 4 fan or another server on /mf for the model to probe (H2, N4)", function()
				local result = one(function(transfer) answer(transfer, 404, mf.NOT_FOUND) end)
				assert.is_false(result.ok)
				assert.equal("http", result.err)
				assert.equal(404, result.code)
				assert.is_nil(result.json)
				assert.equal("HTTP 404", result.detail)
			end)

			for _, code in ipairs({ 204, 301, 302, 400, 403, 500, 503 }) do
				it("HTTP " .. code .. " (N4)", function()
					local result = one(function(transfer) answer(transfer, code, mf.STATE) end)
					assert.is_false(result.ok)
					assert.equal("http", result.err)
					assert.equal(code, result.code)
					assert.is_nil(result.json, "a failure's body is not read")
				end)
			end
		end)

		describe("a 200 without a JSON object is a failure of the answer", function()
			it("says 'empty' for a body of nothing (P10)", function()
				for _, body in ipairs({ "", "   \r\n" }) do
					local result = one(function(transfer) answer(transfer, 200, body) end)
					assert.is_false(result.ok)
					assert.equal("empty", result.err)
					assert.equal(200, result.code)
					assert.equal("empty body", result.detail)
					clock.advance(250)
				end
			end)

			it("says 'empty' for a response with no body field at all", function()
				local result = one(function(transfer)
					transfer.answered = true
					transfer:respond_headers(200, {})
					transfer:done(0)
				end)
				assert.equal("empty", result.err)
			end)

			it("says 'json' for HTML, a cut-off object, an array or a number (N4, P10)", function()
				for _, body in ipairs({ mf.HTML, mf.TRUNCATED, mf.ARRAY, mf.NUMBER, "not json at all" }) do
					local result = one(function(transfer) answer(transfer, 200, body) end)
					assert.is_false(result.ok, body)
					assert.equal("json", result.err, body)
					assert.equal(200, result.code)
					assert.is_nil(result.json)
					clock.advance(250)
				end
			end)

			it("says 'json' when C4:JsonDecode raises (API 12_json/_3-JsonDecode)", function()
				c4.JsonDecode = function() error("invalid JSON") end
				local result = one(function(transfer) answer(transfer, 200, mf.STATE) end)
				assert.is_false(result.ok)
				assert.equal("json", result.err)
			end)

			it("keeps the body out of the detail", function()
				local result = one(function(transfer) answer(transfer, 200, mf.HTML) end)
				assert.is_nil(result.detail:find("Example Router", 1, true))
			end)
		end)

		it("calls a transfer that ends well with no response a connect failure", function()
			local result = one(function(transfer)
				transfer.answered = true
				transfer:done(0)
			end)
			assert.is_false(result.ok)
			assert.equal("connect", result.err)
			assert.equal("no response", result.detail)
		end)

		it("reads the last response of a redirected transfer", function()
			local result = one(function(transfer)
				transfer.answered = true
				transfer:redirect(302, "http://10.0.2.152/mf")
				transfer:respond(200, mf.STATE)
			end)
			assert.is_true(result.ok)
			assert.equal(200, result.code)
		end)

		it("delivers each transfer's result once, however often Director reports it", function()
			t:send(state_request(), collect)
			local transfer = c4.last_transfer()
			answer(transfer, 200, mf.STATE)
			transfer:done(0)
			transfer:respond(200, mf.STATE)
			assert.equal(1, #results)
			clock.advance(250)
			assert.equal(1, idle.count)
		end)
	end)

	describe("late answers (P9, S7, section 4.2)", function()
		it("drops the answer of a request given up by a new epoch: no callback, no on_idle", function()
			t:send(state_request(), collect)
			local old = c4.last_transfer()
			t:set_address(ADDRESS)
			assert.is_false(t:busy(), "the slot is free the moment the request is given up")
			answer(old, 200, mf.STATE)
			assert.equal(0, #results)
			clock.advance(1000)
			assert.equal(0, idle.count)
			assert.is_true(logged("fan #1"), "the drop is logged at debug")
		end)

		it("keeps a late answer away from the newer request that holds the slot", function()
			t:send(state_request(), collect)
			local old = c4.last_transfer()
			t:set_address(ADDRESS)
			assert.equal(2, t:send(command_request(), collect))
			local newer = c4.last_transfer()
			assert.are_not.equal(old, newer)
			assert.equal(2, open_transfers(), "a given-up transfer is not cancelled; Director ends it")
			answer(old, 200, mf.STATE_ON_3)
			assert.equal(0, #results, "the old answer reached nobody")
			assert.is_true(t:busy(), "the newer request still holds the slot")
			assert.same({ nil, "busy" }, { t:send(state_request(), collect) })
			clock.advance(1000)
			assert.equal(0, idle.count, "no gap was started by the old answer")
			answer(newer, 200, mf.STATE)
			assert.equal(1, #results)
			assert.equal(2, results[1].seq)
			assert.equal("command", results[1].kind)
			assert.equal(1, results[1].json.fanSpeed, "the newer request's own answer")
		end)

		it("drops the old answer that comes after the newer request was answered, gap untouched", function()
			t:send(state_request(), collect)
			local old = c4.last_transfer()
			t:set_address(ADDRESS)
			t:send(command_request(), collect)
			answer(c4.last_transfer(), 200, mf.STATE)
			assert.equal(1, #results)
			clock.advance(100)
			fail(old, 28, "Timeout was reached")
			assert.equal(1, #results)
			assert.is_true(t:busy(), "still in the newer request's gap")
			clock.advance(149)
			assert.equal(0, idle.count)
			clock.advance(1)
			assert.equal(1, idle.count, "the gap ran its 250 ms from the newer answer alone")
		end)

		it("sends the next request to the new address while the old one lingers (N1)", function()
			t:send(state_request(), collect)
			local old = c4.last_transfer()
			t:set_address("10.0.2.152")
			t:send({ kind = "info", path = wire.PATH, body = wire.QUERY_INFO }, collect)
			assert.equal("http://10.0.2.151/mf", old.url)
			assert.equal("http://10.0.2.152/mf", c4.last_transfer().url)
			answer(old, 200, mf.STATE)
			assert.equal(0, #results)
			answer(c4.last_transfer(), 200, mf.INFO_OTHER)
			assert.equal("info", results[1].kind)
			assert.equal("MF_00005E005302", results[1].json.clientId)
		end)

		it("drops the answer when the address is cleared in flight: nothing more is sent", function()
			t:send(state_request(), collect)
			local old = c4.last_transfer()
			t:set_address("")
			assert.same({ nil, "no address" }, { t:send(state_request(), collect) })
			answer(old, 200, mf.STATE)
			assert.equal(0, #results)
			assert.equal(0, idle.count)
		end)

		it("drops a request's answer after stop() and a restart on the same address", function()
			t:send(state_request(), collect)
			local old = c4.last_transfer()
			t:stop()
			t:set_address(ADDRESS)
			answer(old, 200, mf.STATE)
			assert.equal(0, #results)
			assert.is_false(t:busy())
		end)

		it("stamps each result with the epoch it was sent in", function()
			t:send(state_request(), collect)
			local epoch = t.epoch
			answer(c4.last_transfer(), 200, mf.STATE)
			clock.advance(250)
			t:set_address(ADDRESS)
			t:send(state_request(), collect)
			answer(c4.last_transfer(), 200, mf.STATE)
			assert.equal(epoch, results[1].epoch)
			assert.equal(epoch + 1, results[2].epoch)
		end)
	end)

	describe("stop()", function()
		it("drops the request in flight, and send() answers 'stopped' from then on", function()
			t:send(state_request(), collect)
			local old = c4.last_transfer()
			t:stop()
			assert.is_false(t:busy())
			assert.same({ nil, "stopped" }, { t:send(state_request(), collect) })
			answer(old, 200, mf.STATE)
			assert.equal(0, #results)
			clock.advance(1000)
			assert.equal(0, idle.count)
		end)

		it("cancels the gap: on_idle is not called again", function()
			t:send(state_request(), collect)
			answer(c4.last_transfer(), 200, mf.STATE)
			assert.is_true(t:busy())
			t:stop()
			assert.is_false(t:busy())
			assert.equal(0, clock.armed())
			clock.advance(1000)
			assert.equal(0, idle.count)
		end)

		it("starts a new epoch (OnDriverDestroyed, section 4.2)", function()
			local epoch = t.epoch
			t:stop()
			assert.equal(epoch + 1, t.epoch)
		end)

		it("is harmless when idle and when repeated", function()
			assert.has_no.errors(function()
				t:stop()
				t:stop()
			end)
			assert.same({ nil, "stopped" }, { t:send(state_request(), collect) })
		end)

		it("holds when called from inside the callback: no gap is armed, no on_idle", function()
			t:send(state_request(), function(result)
				results[#results + 1] = result
				t:stop()
			end)
			answer(c4.last_transfer(), 200, mf.STATE)
			assert.equal(1, #results)
			assert.equal(0, clock.armed())
			clock.advance(1000)
			assert.equal(0, idle.count)
			assert.same({ nil, "stopped" }, { t:send(state_request(), collect) })
		end)

		it("is undone by set_address: the address typed back after it was cleared resumes (section 3.5)", function()
			t:stop()
			t:set_address(ADDRESS)
			assert.is_number(t:send(state_request(), collect))
		end)

		it("keeps the address, so 'no address' and 'stopped' are told apart", function()
			t:stop()
			assert.equal(ADDRESS, t.address)
			t:set_address("")
			assert.same({ nil, "no address" }, { t:send(state_request(), collect) })
		end)
	end)

	describe("a handler that fails", function()
		it("does not take the slot down with it: the gap runs, on_idle follows (error path, never into Director)", function()
			t:send(state_request(), function() error("handler bug") end)
			assert.has_no.errors(function() answer(c4.last_transfer(), 200, mf.STATE) end)
			assert.is_true(logged("handler bug"))
			assert.is_true(t:busy())
			clock.advance(250)
			assert.equal(1, idle.count)
			assert.is_number(t:send(state_request(), collect))
		end)

		it("logs an on_idle that raises, and carries on", function()
			local raising = transport.new({
				now = clock.now,
				timer = clock.timer,
				url = function() return c4:url() end,
				on_idle = function() error("idle bug") end,
				log = log,
			})
			raising:set_address(ADDRESS)
			raising:send(state_request(), collect)
			answer(c4.last_transfer(), 200, mf.STATE)
			assert.has_no.errors(function() clock.advance(250) end)
			assert.is_true(logged("idle bug"))
			assert.is_false(raising:busy())
		end)

		it("survives a logger that raises", function()
			local noisy = transport.new({
				now = clock.now,
				timer = clock.timer,
				url = function() return c4:url() end,
				log = { debug = function() error("sink") end, error = function() error("sink") end },
			})
			noisy:set_address(ADDRESS)
			assert.has_no.errors(function()
				noisy:send(state_request(), function() error("handler bug") end)
				answer(c4.last_transfer(), 200, mf.STATE)
			end)
		end)
	end)

	describe("a transfer that cannot begin", function()
		it("reports a connect failure from a timer, with the request's number returned first", function()
			local slot = transport.new({
				now = clock.now,
				timer = clock.timer,
				url = function()
					local transfer = c4:url()
					transfer.Post = function() error("no transfer slot") end
					return transfer
				end,
				on_idle = function() idle.count = idle.count + 1 end,
				log = log,
			})
			slot:set_address(ADDRESS)
			assert.equal(1, slot:send(state_request(), collect))
			assert.equal(0, #results, "never from inside send()")
			assert.is_true(slot:busy())
			assert.is_true(logged("no transfer slot"))
			clock.advance(1)
			assert.equal(1, #results)
			assert.is_false(results[1].ok)
			assert.equal("connect", results[1].err)
			assert.equal(1, results[1].seq)
			clock.advance(250)
			assert.equal(1, idle.count)
			assert.is_false(slot:busy())
		end)

		it("reports it when the transfer factory raises, too", function()
			local slot = transport.new({
				now = clock.now,
				timer = clock.timer,
				url = function() error("no C4:url") end,
				log = log,
			})
			slot:set_address(ADDRESS)
			assert.equal(1, slot:send(state_request(), collect))
			clock.advance(1)
			assert.equal("connect", results[1].err)
		end)

		it("drops that report when the request was given up meanwhile", function()
			local slot = transport.new({
				now = clock.now,
				timer = clock.timer,
				url = function() error("no C4:url") end,
				log = log,
			})
			slot:set_address(ADDRESS)
			slot:send(state_request(), collect)
			slot:set_address(ADDRESS)
			clock.advance(1000)
			assert.equal(0, #results)
		end)

		it("frees the slot and says so when not even a timer can be armed", function()
			local slot = transport.new({
				now = clock.now,
				timer = function() error("no timer") end,
				url = function() error("no C4:url") end,
				log = log,
			})
			slot:set_address(ADDRESS)
			assert.same({ nil, "could not start" }, { slot:send(state_request(), collect) })
			assert.is_false(slot:busy())
		end)

		it("does not hold the slot when the gap timer cannot be armed: on_idle at once", function()
			local calls = 0
			local slot = transport.new({
				now = clock.now,
				timer = function() error("no timer") end,
				url = function() return c4:url() end,
				on_idle = function() calls = calls + 1 end,
				log = log,
			})
			slot:set_address(ADDRESS)
			slot:send(state_request(), collect)
			answer(c4.last_transfer(), 200, mf.STATE)
			assert.equal(1, #results)
			assert.equal(1, calls)
			assert.is_false(slot:busy())
		end)
	end)

	describe("a request that is not one", function()
		local function refused(name, req, cb)
			it("refuses " .. name .. " as 'bad request': nothing is sent, nothing is numbered, the slot stays free", function()
				assert.same({ nil, "bad request" }, { t:send(req, cb or collect) })
				assert.equal(0, #c4.transfers)
				assert.equal(0, t.seq)
				assert.is_false(t:busy())
			end)
		end

		refused("no request", nil)
		refused("a string", "state")
		refused("an unknown kind", { kind = "factory", path = wire.PATH, body = "{}" })
		refused("no kind", { path = wire.PATH, body = wire.QUERY_STATE })
		refused("no body", { kind = "state", path = wire.PATH })
		refused("an empty body", { kind = "state", path = wire.PATH, body = "" })
		refused("a body that is no string", { kind = "state", path = wire.PATH, body = { fanOn = true } })
		refused("a path nothing may use", { kind = "state", path = "/config-read", body = wire.QUERY_STATE })
		refused("another path still", { kind = "command", path = "/factory", body = '{"fanOn":false}' })
		refused("no path", { kind = "state", body = wire.QUERY_STATE })
		refused("a command to /device (only the Gen 4 probe goes there)", { kind = "command", path = wire.G4_PATH,
			body = '{"fanOn":false}' })
		refused("a state read on /device", { kind = "state", path = wire.G4_PATH, body = wire.QUERY_STATE })
		refused("the Gen 4 probe on /mf", { kind = "g4", path = wire.PATH, body = wire.QUERY_G4 })
		refused("no callback", { kind = "state", path = wire.PATH, body = wire.QUERY_STATE }, 5)

		it("is not told 'busy' for a good request just because a bad one came first", function()
			t:send({ kind = "nope" }, collect)
			assert.is_number(t:send(state_request(), collect))
		end)
	end)

	describe("private data (V20, section 3.7)", function()
		it("never logs an answer: no id, MAC, e-mail, name or SSID reaches the log", function()
			t:send({ kind = "info", path = wire.PATH, body = wire.QUERY_INFO }, collect)
			answer(c4.last_transfer(), 200, mf.INFO)
			clock.advance(250)
			t:send(state_request(), collect)
			answer(c4.last_transfer(), 200, mf.STATE)
			clock.advance(250)
			t:send(state_request(), collect)
			answer(c4.last_transfer(), 200, mf.HTML)
			assert.is_true(#lines > 0, "the requests are logged")
			for _, line in ipairs(lines) do
				for _, text in ipairs(mf.PRIVATE_VALUES) do
					assert.is_nil(line:find(text, 1, true), line)
				end
				assert.is_nil(line:find("MF_00005E005301", 1, true), line)
				assert.is_nil(line:find("00:00:5e:00:53:01", 1, true), line)
				assert.is_nil(line:find("Example Router", 1, true), line)
			end
		end)
	end)
end)
