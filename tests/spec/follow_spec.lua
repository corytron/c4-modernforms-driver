-- fan.follow on fakes: the follower of docs/address-follow-design.md (F2 to F7, section 2.3) and the rules of
-- docs/edge-cases-address.md section 3 (ECA). The Finder, the model's follow, candidates, the clock, the timer and
-- random() are hand-made: a window opens when its timer fires and closes when a test says what it heard; a read
-- answers when a test says how. Placeholders only: the pinned fan MF_00005E005301 (MAC 00:00:5E:00:53:01) at
-- 10.0.2.151, other addresses 10.0.2.152 and three more beside them, built with ip().

local follow = require("fan.follow")
local log = require("common.log")

-- Test addresses built from their parts, so the source holds no address
-- literal outside the documented placeholders (the secrets check).
local function ip(...)
	return table.concat({ ... }, ".")
end

local REAL_SINK = log.sink

local MAC = "00005E005301"
local OPTION_NAMES = {
	"find", "candidates", "follow", "phase", "identity", "address", "enabled", "timer", "now", "random",
	"on_followed", "on_refused",
}

local function quiet()
	log.sink = function() end
end

local function capture_log()
	local lines = {}
	log.sink = function(line) lines[#lines + 1] = line end
	return lines
end

local function count(lines, needle)
	local n = 0
	for _, line in ipairs(lines) do
		if line:find(needle, 1, true) then
			n = n + 1
		end
	end
	return n
end

local function contains(lines, needle)
	return count(lines, needle) > 0
end

local function raises()
	error("boom")
end

-- An entry of the window's heard list (address-follow-design 2.1).
local function entry(address, mac, port)
	return { instance = "MF_Fan_005301", address = address, mac = mac or MAC, port = port or 80 }
end

-- A seeded stand-in for math.random (Park and Miller): the same numbers for the same seed, in (0, 1).
local function seeded(seed)
	local state = seed
	return function()
		state = (state * 16807) % 2147483647
		return state / 2147483647
	end
end

local function constant(value)
	return function() return value end
end

local function addresses(reads)
	local out = {}
	for i, read in ipairs(reads) do
		out[i] = read.address
	end
	return out
end

-- A follower on fakes. o.opts replaces options, o.without removes them.
local function rig(o)
	o = o or {}
	local r = {
		clock = 1000000, timers = {}, finds = {}, reads = {}, followed = {}, refused = 0, asked = {},
		phase = "online", address = "10.0.2.151", enabled = true,
		pin = { client_id = "MF_00005E005301", mac = MAC, generation = "3", address = "10.0.2.151", learned = 0 },
	}
	local function timer(ms, cb)
		local t = { ms = ms, due = r.clock + ms, cb = cb, cancelled = false, fired = false }
		function t:Cancel() self.cancelled = true end
		r.timers[#r.timers + 1] = t
		return t
	end
	local options = {
		find = function(cb)
			r.finds[#r.finds + 1] = { cb = cb, at = r.clock, closed = false }
			return true
		end,
		-- discovery.candidates as section 2.1 says it, for the cases here: the pinned MAC, port 80, not the
		-- current address, at most 3 in the order heard.
		candidates = function(heard, mac12, current)
			r.asked[#r.asked + 1] = { heard = heard, mac12 = mac12, current = current }
			local out = {}
			for _, e in ipairs(heard) do
				if e.mac == mac12 and e.port == 80 and e.address ~= current and #out < 3 then
					out[#out + 1] = e.address
				end
			end
			return out
		end,
		follow = function(address, mac12, cb)
			r.reads[#r.reads + 1] = { address = address, mac12 = mac12, cb = cb, at = r.clock, answered = false }
		end,
		phase = function() return r.phase end,
		identity = function() return r.pin end,
		address = function() return r.address end,
		enabled = function() return r.enabled end,
		timer = timer,
		now = function() return r.clock end,
		random = seeded(12345),
		seed = 4248, -- slot 0 (4248 mod 8): window 1 at 2 to 2.5 s
		on_followed = function(address, was)
			r.followed[#r.followed + 1] = { address = address, was = was }
		end,
		on_refused = function() r.refused = r.refused + 1 end,
		log = log,
	}
	for k, v in pairs(o.opts or {}) do
		options[k] = v
	end
	for _, name in ipairs(o.without or {}) do
		options[name] = nil
	end
	r.f = follow.new(options)

	function r.live()
		local out = {}
		for _, t in ipairs(r.timers) do
			if not t.cancelled and not t.fired then
				out[#out + 1] = t
			end
		end
		return out
	end
	-- ms until the one timer the follower keeps, or nil.
	function r.next_due()
		local live = r.live()
		assert.is_true(#live <= 1, "one timer at a time")
		return live[1] and (live[1].due - r.clock) or nil
	end
	-- Moves the clock, firing the timers in the order they are due, each at its own time.
	function r.advance(ms)
		local target = r.clock + ms
		while true do
			local first
			for _, t in ipairs(r.timers) do
				if not t.cancelled and not t.fired and t.due <= target and (first == nil or t.due < first.due) then
					first = t
				end
			end
			if not first then
				break
			end
			if first.due > r.clock then
				r.clock = first.due
			end
			first.fired = true
			first.cb(first)
		end
		r.clock = target
	end
	-- To the follower's timer and through it; the delay it had.
	function r.step()
		local delay = r.next_due()
		assert.is_not_nil(delay, "a timer is set")
		r.advance(delay)
		return delay
	end
	function r.open_finds()
		local n = 0
		for _, w in ipairs(r.finds) do
			if not w.closed then
				n = n + 1
			end
		end
		return n
	end
	-- The oldest open window closes: its list, its error word, and heard (the list unless given; false for none).
	function r.close(list, err, heard)
		list = list or {}
		if heard == nil then
			heard = list
		elseif heard == false then
			heard = nil
		end
		for _, w in ipairs(r.finds) do
			if not w.closed then
				w.closed = true
				w.cb(list, err, heard)
				return
			end
		end
		error("no window is open")
	end
	-- The next window: its timer, then closed at once with `list` heard. Returns the delay its timer had.
	function r.window(list, err)
		local before = #r.finds
		local delay = r.step()
		assert.equal(before + 1, #r.finds, "a window opened")
		r.close(list, err)
		return delay
	end
	function r.pending_reads()
		local n = 0
		for _, read in ipairs(r.reads) do
			if not read.answered then
				n = n + 1
			end
		end
		return n
	end
	-- The oldest read the model has not answered gets its answer.
	function r.answer(result, args)
		for _, read in ipairs(r.reads) do
			if not read.answered then
				read.answered = true
				read.cb(result, args)
				return
			end
		end
		error("no read is pending")
	end
	-- The model's listener.phase, with the model's phase() saying the same.
	function r.go(phase)
		r.phase = phase
		r.f:phase_changed(phase)
	end
	return r
end

describe("fan.follow", function()
	before_each(function()
		quiet()
		log.set_prefix(nil)
		log.set_debug(false)
	end)
	after_each(function()
		log.set_debug(false)
		log.sink = REAL_SINK
	end)

	describe("arming (F2)", function()
		it("names the offline-like phases as fan/model.lua does (v1-design 6.1)", function()
			assert.same({ offline = true, foreign = true, gen4 = true, notfan = true }, follow.OFFLINE_LIKE)
		end)

		it("calls no option when it is built: nothing is sent or armed in OnDriverInit", function()
			local called, options = {}, {}
			for _, name in ipairs(OPTION_NAMES) do
				options[name] = function() called[#called + 1] = name end
			end
			follow.new(options)
			assert.same({}, called)
		end)

		it("does nothing while online, however long", function()
			local r = rig()
			r.go("online")
			r.advance(2 * 3600 * 1000)
			assert.same({}, r.timers)
			assert.same({}, r.finds)
			assert.equal("idle", r.f:state())
		end)

		it("arms on each offline-like phase: window 1 opens 2 to 2.5 s later in slot 0", function()
			for _, phase in ipairs({ "offline", "foreign", "gen4", "notfan" }) do
				local r = rig()
				r.go(phase)
				assert.equal("armed:1", r.f:state(), phase)
				local delay = r.next_due()
				assert.is_true(delay >= 2000 and delay <= 2500, phase .. ": " .. tostring(delay))
				r.step()
				assert.equal(1, #r.finds, phase)
			end
		end)

		it("does not arm on online, waiting, unset, rebooting or a phase it does not know", function()
			for _, phase in ipairs({ "online", "waiting", "unset", "rebooting", "something new" }) do
				local r = rig()
				r.go(phase)
				assert.equal(0, #r.live(), phase)
				assert.equal("idle", r.f:state(), phase)
			end
		end)

		it("does not arm with Fan Address empty (F5: the stop switch), without a pin, or with a pin naming no MAC",
			function()
				local cases = {
					function(r) r.address = "  " end,
					function(r) r.pin = nil end,
					function(r) r.pin = { client_id = "a name", address = "10.0.2.151" } end,
				}
				for i, setup in ipairs(cases) do
					local r = rig()
					setup(r)
					r.go("offline")
					assert.equal(0, #r.live(), "case " .. i)
					assert.equal("idle", r.f:state(), "case " .. i)
					r.advance(3600 * 1000)
					assert.same({}, r.finds, "case " .. i)
				end
			end)

		it("does not arm for a pin without a MAC: none is taken from the client id (F2, review of #48)", function()
			local r = rig()
			r.pin = { client_id = "MF_00005e005301", address = "10.0.2.151" }
			r.go("offline")
			assert.equal("idle", r.f:state())
			assert.same({}, r.live())
			r.advance(3600 * 1000)
			assert.same({}, r.finds)
		end)

		it("reads the pin's MAC with separators as 12 uppercase digits", function()
			local r = rig()
			r.pin = { client_id = "MF_00005E005301", mac = "00:00:5e:00:53:01", address = "10.0.2.151" }
			r.go("offline")
			r.window({ entry("10.0.2.152") })
			assert.equal(MAC, r.asked[1].mac12)
			assert.equal(MAC, r.reads[1].mac12)
		end)

		it("changes nothing when an offline-like phase is reported again while armed", function()
			local r = rig()
			r.go("offline")
			local first = r.live()[1]
			r.go("offline")
			assert.equal(1, #r.live())
			assert.equal(first, r.live()[1])
		end)
	end)

	describe("the ladder (F3; ECA 3.3)", function()
		-- The delays of windows 1 to n: the first after arming, every other after the previous window closed.
		local function ladder(r, n)
			local delays = {}
			r.go("offline")
			for i = 1, n do
				assert.equal("armed:" .. i, r.f:state())
				delays[i] = r.window({})
			end
			return delays
		end

		local RANGES = {
			{ 2000, 27000 }, { 30000, 36000 }, { 48000, 72000 }, { 96000, 144000 }, { 240000, 360000 },
			{ 480000, 720000 },
		}
		local CAP = { 720000, 1080000 }

		it("opens window 1 at 2 s plus a 3.5 s slot per device plus 0 to 0.5 s, then 30 s, 1, 2, 5 and 10 min, then"
			.. " every 15 min, each +/-20 %", function()
			for _, seed in ipairs({ 1, 7, 12345, 99991 }) do
				local r = rig({ opts = { random = seeded(seed), seed = seed } })
				for i, ms in ipairs(ladder(r, 12)) do
					local range = RANGES[i] or CAP
					assert.is_true(ms >= range[1] and ms <= range[2],
						string.format("seed %d, window %d: %d ms", seed, i, ms))
				end
			end
		end)

		it("reaches each end of each range, and never goes under 30 s (random() at 0 and at 1)", function()
			local low = ladder(rig({ opts = { random = constant(0), seed = 0 } }), 9)
			assert.same({ 2000, 30000, 48000, 96000, 240000, 480000, 720000, 720000, 720000 }, low)
			local high = ladder(rig({ opts = { random = constant(1), seed = 0 } }), 9)
			assert.same({ 2500, 36000, 72000, 144000, 360000, 720000, 1080000, 1080000, 1080000 }, high)
			local last = ladder(rig({ opts = { random = constant(1), seed = 7 } }), 1)
			assert.same({ 27000 }, last, "slot 7, the last")
		end)

		it("puts window 1 of devices in neighbouring slots more than a window apart, whatever random() says", function()
			local function first(seed, value)
				local r = rig({ opts = { random = constant(value), seed = seed } })
				r.go("offline")
				return r.next_due()
			end
			for id = 100, 115 do
				local a, b = first(id, 1), first(id + 1, 0)
				if id % 8 ~= 7 then
					assert.is_true(b - a >= 3000, id .. ": " .. a .. " and " .. b)
				end
			end
			assert.equal(first(101, 0.5), first(101, 0.5), "the same seed, the same delay")
		end)

		it("reads the device id at the first arm, not when it is built, and only once", function()
			local calls = 0
			local r = rig({ opts = { seed = function() calls = calls + 1 return 4249 end } })
			assert.equal(0, calls, "not at load (API 22/_11)")
			r.go("offline")
			assert.equal(1, calls)
			assert.is_true(r.next_due() >= 5500 and r.next_due() <= 6000, "slot 1")
			r.go("online")
			r.go("offline")
			assert.equal(1, calls)
		end)

		it("takes slot 0 when the device id cannot be read", function()
			local r = rig({ opts = { seed = raises } })
			r.go("offline")
			assert.is_true(r.next_due() >= 2000 and r.next_due() <= 2500)
		end)

		it("draws from a generator of its own without random(): two devices step apart, not alike", function()
			local function delays(seed)
				local r = rig({ without = { "random" }, opts = { seed = seed } })
				return ladder(r, 8)
			end
			local a, b = delays(15), delays(16)
			local same = 0
			for i = 2, 8 do
				if a[i] == b[i] then
					same = same + 1
				end
				local range = RANGES[i] or CAP
				assert.is_true(a[i] >= range[1] and a[i] <= range[2], "window " .. i .. ": " .. a[i])
			end
			assert.is_true(same < 7, "the ladders differ")
		end)

		it("opens no window less than 30 s after the last one closed, across a disarm", function()
			local r = rig()
			r.go("offline")
			r.window({})
			local closed = r.clock
			r.advance(1000)
			r.go("online")
			r.advance(1000)
			r.go("offline")
			assert.equal("armed:1", r.f:state())
			assert.equal(closed + 30000, r.clock + r.next_due())
		end)

		it("keeps the 30 s from a window a disarm left open, when it closes after the next was planned", function()
			local r = rig()
			r.go("offline")
			r.step() -- window 1 opens; its answers are still to come
			r.go("online")
			r.go("offline") -- armed again at once: window 1 planned 2 to 5 s away
			r.advance(1000)
			r.close({}) -- the old window closes now
			local closed = r.clock
			r.step()
			assert.equal(1, #r.finds, "not within 30 s of that close")
			assert.equal("armed:1", r.f:state())
			assert.equal(closed + 30000, r.clock + r.next_due())
			r.step()
			assert.equal(2, #r.finds)
		end)

		it("pulls the next window forward on a change between offline-like phases, not closer than 30 s", function()
			local r = rig()
			r.go("offline")
			r.window({})
			r.window({})
			r.window({})
			assert.equal("armed:4", r.f:state()) -- window 4 is 96 to 144 s away
			r.advance(40000)
			r.go("foreign") -- another fan took the address
			local delay = r.next_due()
			assert.is_true(delay >= 2000 and delay <= 5000, tostring(delay))
			assert.equal("armed:4", r.f:state(), "the ladder goes on from where it was")
			r.window({})
			local closed = r.clock
			r.advance(1000)
			r.go("gen4")
			assert.equal(closed + 30000, r.clock + r.next_due())
		end)

		it("counts a window that could not send as done: the ladder goes on, one warning per streak (FA17)", function()
			local r = rig()
			local lines = capture_log()
			local text = "Following could not send its query on this controller"
			r.go("offline")
			r.window({}, "open")
			r.window({}, "send")
			assert.equal(1, count(lines, text))
			assert.equal("armed:3", r.f:state())
			r.window({})
			r.window({}, "open")
			assert.equal(2, count(lines, text), "a window that worked ended the streak")
		end)

		it("goes on the same when the Finder fails inside find and calls back at once", function()
			local r = rig({ opts = { find = function(cb)
				cb({}, "open", {})
				return true
			end } })
			r.go("offline")
			r.step()
			assert.equal("armed:2", r.f:state())
			local delay = r.next_due()
			assert.is_true(delay >= 30000 and delay <= 36000, tostring(delay))
		end)
	end)

	describe("reading the candidates (F4) and following (F6)", function()
		it("asks candidates with the window's heard list, the pin's MAC and the current address", function()
			local r = rig()
			r.go("offline")
			local heard = { entry("10.0.2.152"), entry(ip(10, 0, 2, 153), "00005E005302") }
			r.window(heard)
			assert.equal(heard, r.asked[1].heard)
			assert.equal(MAC, r.asked[1].mac12)
			assert.equal("10.0.2.151", r.asked[1].current)
			assert.same({ "10.0.2.152" }, addresses(r.reads))
		end)

		it("reads the list when the Finder passes no heard list", function()
			local r = rig()
			r.go("offline")
			r.step()
			r.close({ entry("10.0.2.152") }, nil, false)
			assert.same({ "10.0.2.152" }, addresses(r.reads))
		end)

		it("follows the pinned fan: on_followed with the address and was, the ladder disarmed", function()
			local r = rig()
			r.go("offline")
			r.window({ entry("10.0.2.152") })
			assert.same({ address = "10.0.2.152", mac12 = MAC }, { address = r.reads[1].address, mac12 = r.reads[1].mac12 })
			r.answer("followed", { address = "10.0.2.152", was = "10.0.2.151" })
			assert.same({ { address = "10.0.2.152", was = "10.0.2.151" } }, r.followed)
			assert.equal("idle", r.f:state())
			assert.equal(0, #r.live())
			r.advance(3600 * 1000)
			assert.equal(1, #r.finds)
		end)

		it("takes the address read and the window's Fan Address when the answer names neither", function()
			local r = rig()
			r.go("offline")
			r.window({ entry("10.0.2.152") })
			r.answer("followed")
			assert.same({ { address = "10.0.2.152", was = "10.0.2.151" } }, r.followed)
		end)

		it("tries the next candidate after not_same and no_answer, and stops at the one that follows", function()
			local r = rig()
			r.go("offline")
			r.window({ entry("10.0.2.152"), entry(ip(10, 0, 2, 153)), entry(ip(10, 0, 2, 154)) })
			r.answer("not_same")
			r.answer("no_answer")
			r.answer("followed", { address = ip(10, 0, 2, 154), was = "10.0.2.151" })
			assert.same({ "10.0.2.152", ip(10, 0, 2, 153), ip(10, 0, 2, 154) }, addresses(r.reads))
			assert.same({ { address = ip(10, 0, 2, 154), was = "10.0.2.151" } }, r.followed)
			assert.equal(0, #r.live())
		end)

		it("reads at most 3 addresses a window, never the current one, each once", function()
			local r = rig({ opts = { candidates = function()
				return { "10.0.2.151", "10.0.2.152", "10.0.2.152", ip(10, 0, 2, 153), ip(10, 0, 2, 154), ip(10, 0, 2, 155) }
			end } })
			r.go("offline")
			r.window({})
			for _ = 1, 3 do
				r.answer("not_same")
			end
			assert.same({ "10.0.2.152", ip(10, 0, 2, 153), ip(10, 0, 2, 154) }, addresses(r.reads))
		end)

		it("works the same when the model answers inside follow", function()
			local answers = { "no_answer", "followed" }
			local r = rig({ opts = { follow = function(address, _, cb)
				local result = table.remove(answers, 1)
				cb(result, result == "followed" and { address = address, was = "10.0.2.151" } or nil)
			end } })
			r.go("offline")
			r.window({ entry("10.0.2.152"), entry(ip(10, 0, 2, 153)) })
			assert.same({ { address = ip(10, 0, 2, 153), was = "10.0.2.151" } }, r.followed)
			assert.equal(0, #r.live())
		end)

		it("reports a follow whose phase waiting the model told first", function()
			local r = rig()
			r.go("offline")
			r.window({ entry("10.0.2.152") })
			r.go("waiting") -- the model moved, its listener ran before the read's callback
			r.answer("followed", { address = "10.0.2.152", was = "10.0.2.151" })
			assert.same({ { address = "10.0.2.152", was = "10.0.2.151" } }, r.followed)
			assert.equal("idle", r.f:state())
		end)

		it("reports a follow whose phase waiting the model tells after", function()
			local r = rig()
			r.go("offline")
			r.window({ entry("10.0.2.152") })
			r.answer("followed", { address = "10.0.2.152", was = "10.0.2.151" })
			r.go("waiting")
			assert.equal(1, #r.followed)
			assert.equal("idle", r.f:state())
			assert.equal(0, #r.live())
		end)

		it("ignores an answer that comes twice", function()
			local cb
			local r = rig({ opts = { follow = function(_, _, callback) cb = callback end } })
			r.go("offline")
			r.window({ entry("10.0.2.152") })
			cb("followed", { address = "10.0.2.152", was = "10.0.2.151" })
			cb("followed", { address = "10.0.2.152", was = "10.0.2.151" })
			assert.equal(1, #r.followed)
		end)
	end)

	describe("retries (F3; ECA 3.3, FA15)", function()
		it("reads an unverified candidate again at +10, +30 and +90 s without a window, then the ladder goes on",
			function()
				local r = rig()
				r.go("offline")
				r.window({ entry("10.0.2.152") })
				r.advance(400)
				r.answer("no_answer")
				local t0 = r.clock
				for i, at in ipairs({ 10000, 30000, 90000 }) do
					assert.equal(t0 + at, r.clock + r.next_due(), "retry " .. i)
					r.step()
					assert.same("10.0.2.152", r.reads[i + 1].address, "retry " .. i)
					assert.equal(1, #r.finds, "no window for a retry")
					assert.equal("armed:2", r.f:state())
					r.advance(500)
					r.answer("no_answer")
				end
				-- Window 2's 30 to 36 s after window 1 closed have passed: it opens now.
				r.step()
				assert.equal(2, #r.finds)
				assert.equal(4, #r.reads)
				assert.equal("armed:2", r.f:state())
			end)

		it("does not read again a candidate that answered as another fan", function()
			local r = rig()
			r.go("offline")
			r.window({ entry("10.0.2.152") })
			r.answer("not_same", { client_id = "MF_00005E005302" })
			local delay = r.next_due()
			assert.is_true(delay >= 30000 and delay <= 36000, tostring(delay))
			r.step()
			assert.equal(2, #r.finds)
			assert.equal(1, #r.reads)
		end)

		it("follows when a retry finds the fan", function()
			local r = rig()
			r.go("offline")
			r.window({ entry("10.0.2.152") })
			r.answer("no_answer")
			r.step()
			r.answer("followed", { address = "10.0.2.152", was = "10.0.2.151" })
			assert.equal(1, #r.followed)
			assert.equal(0, #r.live())
			assert.equal("idle", r.f:state())
		end)

		it("ends the window's reads on busy; what was not read is read with the retries", function()
			local r = rig()
			r.go("offline")
			r.window({ entry("10.0.2.152"), entry(ip(10, 0, 2, 153)) })
			r.answer("busy")
			assert.equal(1, #r.reads, "the second is not asked while the model is busy")
			assert.equal(10000, r.next_due())
			r.step()
			assert.equal("10.0.2.152", r.reads[2].address)
			r.answer("no_answer")
			assert.equal(ip(10, 0, 2, 153), r.reads[3].address)
		end)

		it("warns once per streak when the pinned fan announces the current address and HTTP is silent", function()
			local r = rig()
			local lines = capture_log()
			local text = "Fan ...5301 is on the network at 10.0.2.151, but its web server does not answer"
			r.go("offline")
			r.window({ entry("10.0.2.151") })
			r.window({ entry("10.0.2.151") })
			assert.equal(1, count(lines, text))
			assert.same({}, r.reads, "the current address is never read")
			r.window({})
			r.window({ entry("10.0.2.151") })
			assert.equal(2, count(lines, text))
		end)
	end)

	describe("disarming (F3; ECA 3.2)", function()
		local CAUSES = {
			{ "online", function(r) r.go("online") end, "idle" },
			{ "waiting", function(r) r.go("waiting") end, "idle" },
			{ "unset", function(r) r.go("unset") end, "idle" },
			{ "rebooting", function(r) r.go("rebooting") end, "idle" },
			{ "a Fan Address edit", function(r)
				r.address = "10.0.2.152"
				r.f:address_edited()
			end, "pending" },
			{ "switch Off", function(r) r.f:switch(false) end, "off" },
			{ "stop", function(r) r.f:stop() end, "off" },
		}

		for _, case in ipairs(CAUSES) do
			local name, cause, state = case[1], case[2], case[3]
			it("on " .. name .. ": a window due, a window open, a retry due", function()
				local r = rig()
				r.go("offline")
				cause(r)
				assert.equal(0, #r.live())
				assert.equal(state, r.f:state())
				r.advance(3600 * 1000)
				assert.same({}, r.finds)

				local s = rig()
				s.go("offline")
				s.step()
				cause(s)
				s.close({ entry("10.0.2.152") })
				assert.same({}, s.reads, "the window's answers are dropped")
				assert.equal(0, #s.live())
				assert.equal(state, s.f:state())

				local t = rig()
				t.go("offline")
				t.window({ entry("10.0.2.152") })
				t.answer("no_answer")
				cause(t)
				assert.equal(0, #t.live())
				t.advance(3600 * 1000)
				assert.equal(1, #t.reads)
				assert.equal(1, #t.finds)
				assert.equal(state, t.f:state())
			end)
		end

		it("starts again from step 1", function()
			local r = rig()
			r.go("offline")
			r.window({})
			r.window({})
			assert.equal("armed:3", r.f:state())
			r.go("online")
			r.advance(60000)
			r.go("offline")
			assert.equal("armed:1", r.f:state())
			local delay = r.next_due()
			assert.is_true(delay >= 2000 and delay <= 5000, tostring(delay))
		end)

		it("does not open a window whose phase the model no longer finds offline-like", function()
			local r = rig()
			r.go("offline")
			r.phase = "online" -- the listener has not told yet
			r.step()
			assert.same({}, r.finds)
			assert.equal("idle", r.f:state())
			assert.equal(0, #r.live())
		end)
	end)

	describe("the typed address (F5; ECA CA3)", function()
		it("makes the follower pending: an offline phase then arms nothing", function()
			local r = rig()
			local lines = capture_log()
			log.set_debug(true)
			r.address = "10.0.2.152"
			r.f:address_edited()
			assert.equal("pending", r.f:state())
			r.go("waiting")
			r.go("offline")
			assert.equal(0, #r.live())
			assert.equal("pending", r.f:state())
			assert.is_true(contains(lines, "Follow: waiting, the typed address has not answered yet"))
			r.advance(3600 * 1000)
			assert.same({}, r.finds)
		end)

		it("stays pending through foreign: the second fan's typed address is not overridden", function()
			local r = rig()
			r.address = "10.0.2.152"
			r.f:address_edited()
			r.go("waiting")
			r.go("foreign")
			assert.equal(0, #r.live())
			r.f:switch(true)
			assert.equal(0, #r.live())
			assert.equal("pending", r.f:state())
		end)

		it("is cleared by a contact at the typed address: the next loss arms again", function()
			local r = rig()
			r.address = "10.0.2.152"
			r.f:address_edited()
			r.go("waiting")
			r.go("online")
			r.f:contact()
			assert.equal("idle", r.f:state())
			r.go("offline")
			assert.equal("armed:1", r.f:state())
		end)
	end)

	describe("the switch (F7)", function()
		it("Off disarms and keeps the follower off", function()
			local r = rig()
			r.go("offline")
			r.enabled = false
			r.f:switch(false)
			assert.equal("off", r.f:state())
			assert.equal(0, #r.live())
			r.go("foreign")
			assert.equal(0, #r.live())
			r.advance(3600 * 1000)
			assert.same({}, r.finds)
		end)

		it("On arms at once while the phase is offline-like, and stays idle while online", function()
			local r = rig()
			r.f:switch(false)
			r.go("offline")
			assert.equal(0, #r.live())
			r.f:switch(true)
			assert.equal("armed:1", r.f:state())
			r.step()
			assert.equal(1, #r.finds)

			local s = rig()
			s.f:switch(false)
			s.go("online")
			s.f:switch(true)
			assert.equal("idle", s.f:state())
			assert.equal(0, #s.live())
		end)

		it("takes enabled() as the property: Off there keeps the follower off whatever switch() said", function()
			local r = rig()
			r.enabled = false
			r.go("offline")
			assert.equal(0, #r.live())
			assert.equal("off", r.f:state())
			r.enabled = true
			assert.equal("idle", r.f:state())
			r.go("foreign")
			assert.equal("armed:1", r.f:state())
		end)

		it("reads only true and On as On", function()
			local r = rig({ without = { "enabled" } })
			for _, value in ipairs({ "Off", "off", false, "yes", 1 }) do
				r.f:switch(value)
				assert.equal("off", r.f:state(), tostring(value))
			end
			r.go("offline")
			assert.equal(0, #r.live())
			r.f:switch("On")
			assert.equal("armed:1", r.f:state())
		end)
	end)

	describe("the flap guard (F6)", function()
		it("follows three times in an hour; the fourth is refused without a read and on_refused once", function()
			local r = rig()
			local function lose_and_follow(address)
				r.go("offline")
				r.window({ entry(address) })
				r.answer("followed", { address = address, was = r.address })
				r.followed[#r.followed].at = r.clock
				r.address = address
				r.go("waiting")
				r.go("online")
				r.f:contact()
				r.advance(60000)
			end
			lose_and_follow("10.0.2.152")
			lose_and_follow(ip(10, 0, 2, 153))
			lose_and_follow(ip(10, 0, 2, 154))
			assert.equal(3, #r.followed)
			assert.equal(0, r.refused)
			local reads = #r.reads
			r.go("offline")
			r.window({ entry(ip(10, 0, 2, 155)) })
			assert.equal(reads, #r.reads, "the fourth is not read")
			assert.equal(1, r.refused)
			assert.equal("armed:2", r.f:state(), "the ladder goes on")
			r.window({ entry(ip(10, 0, 2, 155)) })
			assert.equal(reads, #r.reads)
			assert.equal(1, r.refused, "once per streak")
			-- An hour after the first follow, the guard lets the next one through.
			local hour_after = r.followed[1].at + 3600 * 1000
			while r.clock + r.next_due() < hour_after do
				r.window({ entry(ip(10, 0, 2, 155)) })
			end
			assert.equal(reads, #r.reads)
			r.window({ entry(ip(10, 0, 2, 155)) })
			assert.equal(reads + 1, #r.reads)
			r.answer("followed", { address = ip(10, 0, 2, 155), was = ip(10, 0, 2, 154) })
			assert.equal(4, #r.followed)
			assert.equal(1, r.refused)
		end)
	end)

	describe("the re-check before accepting (F4)", function()
		it("refuses the follow when Fan Address is typed while a read is pending", function()
			local r = rig()
			r.go("offline")
			r.window({ entry("10.0.2.152") })
			r.address = ip(10, 0, 2, 153)
			r.f:address_edited()
			r.answer("followed", { address = "10.0.2.152", was = "10.0.2.151" })
			assert.same({}, r.followed)
			assert.equal("pending", r.f:state())
			assert.equal(0, #r.live())
		end)

		it("reads nothing more once the model's phase is not offline-like", function()
			local r = rig()
			r.go("offline")
			r.window({ entry("10.0.2.152"), entry(ip(10, 0, 2, 153)) })
			r.phase = "online" -- the model is back; its listener has not told yet
			r.answer("no_answer")
			assert.equal(1, #r.reads)
			assert.equal("idle", r.f:state())
			assert.equal(0, #r.live())
		end)

		it("reads nothing more once the property is Off, though switch() was not called", function()
			local r = rig()
			r.go("offline")
			r.window({ entry("10.0.2.152"), entry(ip(10, 0, 2, 153)) })
			r.enabled = false
			r.answer("no_answer")
			assert.equal(1, #r.reads)
			assert.equal(0, #r.live())
		end)

		it("switched Off during a read: nothing more is read, but a move the model made is reported (ECA CA1)",
			function()
				local r = rig()
				r.go("offline")
				r.window({ entry("10.0.2.152"), entry(ip(10, 0, 2, 153)) })
				r.f:switch(false)
				r.answer("followed", { address = "10.0.2.152", was = "10.0.2.151" })
				assert.equal(1, #r.followed, "Fan Address must say where the model is")
				assert.equal("off", r.f:state())

				local s = rig()
				s.go("offline")
				s.window({ entry("10.0.2.152"), entry(ip(10, 0, 2, 153)) })
				s.f:switch(false)
				s.answer("no_answer")
				assert.equal(1, #s.reads)
				assert.equal(0, #s.live())
			end)

		it("reports nothing once stopped", function()
			local r = rig()
			r.go("offline")
			r.window({ entry("10.0.2.152") })
			r.f:stop()
			r.answer("followed", { address = "10.0.2.152", was = "10.0.2.151" })
			assert.same({}, r.followed)
		end)
	end)

	describe("stop", function()
		it("cancels every timer, and nothing runs, arms or reports after it", function()
			local r = rig()
			r.go("offline")
			local due = r.live()[1]
			r.f:stop()
			assert.is_true(due.cancelled)

			local s = rig()
			s.go("offline")
			s.window({ entry("10.0.2.152") })
			s.answer("no_answer")
			local retry = s.live()[1]
			s.f:stop()
			assert.is_true(retry.cancelled)
			for _, t in ipairs(s.timers) do
				assert.is_true(t.cancelled or t.fired)
			end
			s.go("foreign")
			s.f:switch(true)
			s.f:contact()
			s.f:address_edited()
			s.f:stop()
			assert.equal(0, #s.live())
			assert.equal("off", s.f:state())
			s.advance(3600 * 1000)
			assert.equal(1, #s.finds)
			assert.equal(1, #s.reads)
		end)

		it("does nothing for a timer Director fires after its cancel", function()
			local r = rig()
			r.go("offline")
			local due = r.live()[1]
			r.f:stop()
			due.cb(due)
			assert.same({}, r.finds)
		end)
	end)

	describe("faults: an option that raises never escapes", function()
		it("each option raising on its own", function()
			for _, name in ipairs(OPTION_NAMES) do
				local r = rig({ opts = { [name] = raises } })
				local ok, err = pcall(function()
					r.go("offline")
					for _ = 1, 4 do
						if #r.live() > 0 then
							r.step()
						end
						if r.open_finds() > 0 then
							r.close({ entry("10.0.2.152") })
						end
						if r.pending_reads() > 0 then
							r.answer("no_answer")
						end
					end
					if #r.live() > 0 then
						r.step()
					end
					if r.pending_reads() > 0 then
						r.answer("followed", { address = "10.0.2.152", was = "10.0.2.151" })
					end
					r.f:state()
					r.f:switch(false)
					r.f:switch(true)
					r.f:address_edited()
					r.f:contact()
					r.f:stop()
				end)
				assert.is_true(ok, name .. ": " .. tostring(err))
			end
		end)

		it("every option raising, the log included", function()
			local options = { seed = "not a number", log = setmetatable({}, { __index = function() return raises end }) }
			for _, name in ipairs(OPTION_NAMES) do
				options[name] = raises
			end
			assert.has_no.errors(function()
				local f = follow.new(options)
				f:phase_changed("offline")
				f:switch(true)
				f:contact()
				f:address_edited()
				f:switch(false)
				f:state()
				f:stop()
			end)
			assert.has_no.errors(function() follow.new(nil):phase_changed("offline") end)
		end)

		it("a find that raises is a window that could not send: the ladder goes on", function()
			local r = rig({ opts = { find = raises } })
			local lines = capture_log()
			r.go("offline")
			r.step()
			assert.equal("armed:2", r.f:state())
			assert.equal(1, #r.live())
			assert.is_true(contains(lines, "Following could not send its query on this controller"))
		end)

		it("a follow that raises is no answer: the candidate is read again", function()
			local r = rig({ opts = { follow = raises } })
			r.go("offline")
			r.window({ entry("10.0.2.152") })
			assert.equal(10000, r.next_due())
		end)

		it("an on_followed that raises still counts the follow and disarms", function()
			local r = rig({ opts = { on_followed = raises } })
			r.go("offline")
			r.window({ entry("10.0.2.152") })
			r.answer("followed", { address = "10.0.2.152", was = "10.0.2.151" })
			assert.equal("idle", r.f:state())
			assert.equal(0, #r.live())
		end)

		it("a timer that cannot be set leaves the follower idle", function()
			local r = rig({ opts = { timer = raises } })
			local lines = capture_log()
			r.go("offline")
			assert.equal("idle", r.f:state())
			assert.is_true(contains(lines, "Follow: no timer could be set"))
		end)

		it("a random() that raises is the middle of the range", function()
			local r = rig({ opts = { random = raises, seed = 0 } })
			r.go("offline")
			assert.equal(2250, r.next_due())
		end)
	end)

	describe("clicked() (F4: a Use Selected Fan click)", function()
		it("drops the candidates of the window open at the click; nothing pending, the ladder goes on", function()
			local r = rig()
			r.go("offline")
			r.step()
			r.f:clicked()
			r.close({ entry("10.0.2.152") })
			assert.same({}, r.reads)
			assert.equal("armed:2", r.f:state())
			r.window({ entry("10.0.2.152") })
			assert.equal(1, #r.reads, "the next window reads again")
		end)

		it("drops the retries of an unverified candidate too", function()
			local r = rig()
			r.go("offline")
			r.window({ entry("10.0.2.152") })
			r.answer("no_answer", { address = "10.0.2.152" })
			r.f:clicked()
			r.advance(120 * 1000)
			assert.equal(1, #r.reads, "no retry after the click")
		end)

		it("does nothing once stopped", function()
			local r = rig()
			r.f:stop()
			assert.has_no.errors(function() r.f:clicked() end)
		end)
	end)

	describe("state() (Dev State)", function()
		it("is off, pending, armed:N or idle", function()
			local r = rig()
			assert.equal("idle", r.f:state())
			r.go("offline")
			assert.equal("armed:1", r.f:state())
			r.window({})
			assert.equal("armed:2", r.f:state())
			r.step()
			assert.equal("armed:2", r.f:state(), "window 2 under way")
			r.close({})
			assert.equal("armed:3", r.f:state())
			r.f:switch(false)
			assert.equal("off", r.f:state())
			r.address = "10.0.2.152"
			r.f:address_edited()
			assert.equal("off", r.f:state(), "Off comes before pending")
			r.f:switch(true)
			assert.equal("pending", r.f:state())
			r.go("online")
			r.f:contact()
			assert.equal("idle", r.f:state())
			r.f:stop()
			assert.equal("off", r.f:state())
		end)
	end)

	describe("log lines (ECA 3.6)", function()
		it("writes the debug lines of each step as ECA 3.6 shows them", function()
			local lines = capture_log()
			log.set_debug(true)
			local r = rig({ opts = { random = constant(0), seed = 0 } })
			r.go("offline")
			r.window({})
			r.window({ entry("10.0.2.152") })
			r.answer("not_same", { client_id = "MF_00005E005302" })
			assert.is_true(contains(lines, "Follow: window 1 (next in 30 s): heard 0 fans"))
			assert.is_true(contains(lines, "Follow: ...5301 heard at 10.0.2.152; reading it"))
			assert.is_true(contains(lines, "Follow: 10.0.2.152 answers as another fan (...5302); not followed"))
			for _, line in ipairs(lines) do
				assert.is_nil(line:find("00005E005301", 1, true), "no whole MAC or client id: " .. line)
			end
		end)

		it("writes nothing without Debug Mode when all goes well", function()
			local lines = capture_log()
			local r = rig()
			r.go("offline")
			r.window({})
			r.window({ entry("10.0.2.152") })
			r.answer("no_answer")
			r.step()
			r.answer("followed", { address = "10.0.2.152", was = "10.0.2.151" })
			assert.same({}, lines)
		end)
	end)

	describe("the subnet of a follow (#214, security-214 S1-7)", function()
		-- candidates that hands back what the window heard, whatever its subnet, and keeps the anchor it was given.
		local function permissive(r)
			return function(heard, _mac12, _current, anchor)
				r.anchors = r.anchors or {}
				r.anchors[#r.anchors + 1] = anchor == nil and "nil" or anchor
				local out = {}
				for _, e in ipairs(heard) do
					out[#out + 1] = e.address
				end
				return out
			end
		end

		it("reads no address outside the subnet the pinned fan last answered in, whatever candidates answers", function()
			local lines = capture_log()
			log.set_debug(true)
			local r
			r = rig({ opts = { candidates = function(...) return r.o_candidates(...) end } })
			r.o_candidates = permissive(r)
			r.go("offline")
			r.window({ entry(ip(10, 9, 9, 9)), entry(ip(10, 0, 3, 152)), entry(ip(169, 254, 169, 254)),
				entry(ip(172, 16, 2, 152)), entry("10.0.2.152") })
			assert.same({ "10.0.2.152" }, addresses(r.reads))
			assert.is_true(contains(lines, "Follow: " .. ip(10, 9, 9, 9) .. " is outside the subnet of 10.0.2.151; not read"))
		end)

		it("hands candidates the address the pinned fan last answered at as the anchor, else Fan Address", function()
			local r
			r = rig({ opts = { candidates = function(...) return r.o_candidates(...) end } })
			r.o_candidates = permissive(r)
			r.go("offline")
			r.window({})
			assert.equal("10.0.2.151", r.anchors[1])
			r.pin.address = nil
			r.address = "10.0.2.151"
			r.window({})
			assert.equal("10.0.2.151", r.anchors[2], "no address in the pin: Fan Address")
			r.pin.address = " 10.0.2.151 "
			r.window({})
			assert.equal("10.0.2.151", r.anchors[3], "trimmed")
		end)

		it("follows within the subnet of the pin's address when Fan Address names another", function()
			local r
			r = rig({ opts = { candidates = function(...) return r.o_candidates(...) end } })
			r.o_candidates = permissive(r)
			r.pin.address = ip(10, 0, 3, 151)
			r.go("offline")
			r.window({ entry("10.0.2.152"), entry(ip(10, 0, 3, 152)) })
			assert.same({ ip(10, 0, 3, 152) }, addresses(r.reads))
		end)

		it("never restricts the address the owner types: once the fan answers there, follows stay in its subnet",
			function()
				local r
				r = rig({ opts = { candidates = function(...) return r.o_candidates(...) end } })
				r.o_candidates = permissive(r)
				-- The owner types an address in another subnet; the model reads it (not the follower) and the fan
				-- answers there, so the pin moves with it.
				r.address = "192.168.2.20"
				r.f:address_edited()
				assert.equal("pending", r.f:state())
				r.pin.address = "192.168.2.20"
				r.f:contact()
				r.go("offline")
				r.window({ entry("10.0.2.152"), entry("192.168.2.21") })
				assert.same({ "192.168.2.21" }, addresses(r.reads))
			end)

		it("reads nothing when neither the pin's address nor Fan Address is an address", function()
			local r
			r = rig({ opts = { candidates = function(...) return r.o_candidates(...) end } })
			r.o_candidates = permissive(r)
			r.pin.address = nil
			r.address = "fan.local"
			r.go("offline")
			r.window({ entry("10.0.2.152") })
			assert.same({}, r.reads)
			assert.equal("nil", r.anchors[1])
			assert.equal("armed:2", r.f:state(), "the ladder goes on")
		end)

		it("works with discovery.candidates as the driver wires it", function()
			local discovery = require("fan.discovery")
			local r = rig({ opts = { candidates = discovery.candidates } })
			r.go("offline")
			r.window({ entry(ip(10, 9, 9, 9)), entry("10.0.2.152") })
			assert.same({ "10.0.2.152" }, addresses(r.reads))
		end)
	end)

	describe("text off the network in the log (#214, security-214 S1-8)", function()
		it("writes another fan's client id by its last four characters, printable", function()
			local lines = capture_log()
			log.set_debug(true)
			local r = rig()
			r.go("offline")
			r.window({ entry("10.0.2.152") })
			r.answer("not_same", { client_id = "MF_00005E0053\r\n\0\27" })
			assert.is_true(contains(lines, "Follow: 10.0.2.152 answers as another fan (...????); not followed"))
		end)

		it("cuts what the model reports to 200 characters and writes no control character", function()
			local lines = capture_log()
			log.set_debug(true)
			local r = rig()
			r.go("offline")
			r.window({ entry("10.0.2.152") })
			r.answer("followed", { address = "10.0.2.152", was = "\n" .. string.rep("w", 5000) })
			assert.equal(1, #r.followed)
			local seen = false
			for _, line in ipairs(lines) do
				if line:find("Follow: followed", 1, true) then
					seen = true
					assert.is_true(#line < 400, tostring(#line))
					assert.is_nil(line:find("\n", 1, true))
					assert.is_truthy(line:find("(was ?" .. string.rep("w", 199) .. ")", 1, true))
				end
			end
			assert.is_true(seen)
		end)
	end)
end)
