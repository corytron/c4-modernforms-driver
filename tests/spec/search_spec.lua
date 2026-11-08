-- fan.search on fakes: the scheduler of docs/auto-discovery-design.md (the modes and the schedule in section 2, the
-- interface in section 6.1, the search_spec list of section 8). The Finder, the clock, the timer and random() are
-- hand-made: the fake Finder keeps one window at a time, a find while one is open joins it, and a window closes when
-- a test says so (or 3 s after it opened, with auto). A "follower" window is one the fake Finder opens for someone
-- else. The scheduler never reads answers, so no fan data is needed here.

local search = require("fan.search")
local log = require("common.log")

local REAL_SINK = log.sink

local OPTION_NAMES = { "find", "last_closed", "mode", "timer", "now", "seed", "random", "log" }

local MINUTE, HOUR, DAY = 60000, 3600000, 86400000

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

local function raises()
	error("boom")
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

-- A scheduler on fakes. o.opts replaces options, o.without removes them, o.mode is the mode at first (seek),
-- o.auto closes every window 3 s after it opened.
local function rig(o)
	o = o or {}
	local r = {
		clock = 1000000, timers = {}, ftimers = {}, windows = {}, current = nil, last = nil,
		mode = o.mode or "seek", auto = o.auto, finds = 0, modes_at_open = {},
	}
	local function make_timer(list)
		return function(ms, cb)
			local t = { ms = ms, due = r.clock + ms, cb = cb, cancelled = false, fired = false }
			function t:Cancel() self.cancelled = true end
			list[#list + 1] = t
			return t
		end
	end
	local finder_timer = make_timer(r.ftimers)

	-- The fake Finder: a window, or the one open now joined. by: "search" or "follower".
	function r.open(by, cb)
		local w = r.current
		if w then
			w.cbs[#w.cbs + 1] = cb
			w.joined[#w.joined + 1] = by
			return w
		end
		w = { by = by, at = r.clock, cbs = { cb }, joined = {}, closed = false, mode = r.mode }
		r.windows[#r.windows + 1] = w
		r.current = w
		if r.auto then
			finder_timer(3000, function()
				if r.current == w then
					r.close()
				end
			end)
		end
		return w
	end
	-- The open window closes now: every caller's callback, last_closed() moves.
	function r.close(err)
		local w = r.current
		assert(w, "no window is open")
		r.current = nil
		w.closed, w.closed_at = true, r.clock
		r.last = r.clock
		for _, cb in ipairs(w.cbs) do
			cb({}, err, {})
		end
		return w
	end
	-- A window of the follower opens now (it joins one open, as the Finder does).
	function r.follower()
		return r.open("follower", function() end)
	end

	local options = {
		find = function(cb)
			r.finds = r.finds + 1
			r.open("search", cb)
			return true
		end,
		last_closed = function() return r.last end,
		mode = function() return r.mode end,
		timer = make_timer(r.timers),
		now = function() return r.clock end,
		seed = 4248, -- slot 0 (4248 mod 8): the window at load at 3 to 3.5 s
		random = seeded(12345),
		log = log,
	}
	for k, v in pairs(o.opts or {}) do
		options[k] = v
	end
	for _, name in ipairs(o.without or {}) do
		options[name] = nil
	end
	r.options = options
	r.s = search.new(options)

	-- The scheduler's timers not yet fired or cancelled.
	function r.live()
		local out = {}
		for _, t in ipairs(r.timers) do
			if not t.cancelled and not t.fired then
				out[#out + 1] = t
			end
		end
		return out
	end
	-- ms until the one timer the scheduler keeps, or nil.
	function r.next_due()
		local live = r.live()
		assert.is_true(#live <= 1, "one timer at a time")
		return live[1] and (live[1].due - r.clock) or nil
	end
	-- Moves the clock, firing every timer (the scheduler's and the Finder's) in the order they are due.
	function r.advance(ms)
		local target = r.clock + ms
		while true do
			local first
			for _, list in ipairs({ r.timers, r.ftimers }) do
				for _, t in ipairs(list) do
					if not t.cancelled and not t.fired and t.due <= target and (first == nil or t.due < first.due) then
						first = t
					end
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
	-- To the scheduler's timer and through it; the delay it had.
	function r.step()
		local delay = r.next_due()
		assert.is_not_nil(delay, "a timer is set")
		r.advance(delay)
		return delay
	end
	-- The scheduler's next window: its timer, a window opened by it, closed after `open_ms` (0). Returns the delay.
	function r.window(open_ms)
		local before = r.finds
		local delay = r.step()
		assert.equal(before + 1, r.finds, "a window opened")
		assert.equal("open", r.s:state())
		if open_ms and open_ms > 0 then
			r.advance(open_ms)
		end
		r.close()
		return delay
	end
	-- The mode changes and the driver says so.
	function r.go(mode)
		r.mode = mode
		r.s:changed()
	end
	-- Windows the scheduler opened itself (a join opens none).
	function r.own()
		local n = 0
		for _, w in ipairs(r.windows) do
			if w.by == "search" then
				n = n + 1
			end
		end
		return n
	end
	return r
end

describe("fan.search", function()
	before_each(function()
		quiet()
		log.set_prefix(nil)
		log.set_debug(false)
	end)
	after_each(function()
		log.set_debug(false)
		log.sink = REAL_SINK
	end)

	it("has the contract's constants (section 6.1)", function()
		assert.equal(3000, search.FIRST_MS)
		assert.equal(8, search.SLOTS)
		assert.equal(3500, search.SLOT_MS)
		assert.equal(500, search.JITTER_MS)
		assert.same({ 30000, 60000, 120000, 300000, 600000 }, search.SEEK_MS)
		assert.equal(900000, search.SEEK_EVERY_MS)
		assert.equal(0.2, search.SPREAD)
		assert.equal(30000, search.MIN_GAP_MS)
	end)

	it("calls no option when it is built, nor before start(): nothing is sent or armed in OnDriverInit", function()
		local called, options = {}, {}
		for _, name in ipairs(OPTION_NAMES) do
			options[name] = function() called[#called + 1] = name end
		end
		options.log = setmetatable({}, { __index = function(_, k) return function() called[#called + 1] = k end end })
		local s = search.new(options)
		assert.equal("off", s:state())
		s:changed()
		s:poke("stale")
		assert.same({}, called)
	end)

	describe("the window at load (section 2)", function()
		it("opens at 3 s plus a 3.5 s slot per device plus 0 to 0.5 s, in seek and in quiet", function()
			for _, mode in ipairs({ "seek", "quiet" }) do
				for id = 0, 23 do
					local r = rig({ mode = mode, opts = { seed = id, random = seeded(id + 1) } })
					r.s:start()
					local slot = id % 8
					local delay = r.next_due()
					assert.is_true(delay >= 3000 + slot * 3500 and delay <= 3500 + slot * 3500,
						string.format("%s, device %d: %d ms", mode, id, delay))
					assert.equal("due:" .. math.ceil(delay / 1000), r.s:state())
					r.window()
					assert.equal(1, r.own(), mode)
				end
			end
		end)

		it("reaches each end of each slot (random() at 0 and at 1)", function()
			local function first(id, value)
				local r = rig({ opts = { seed = id, random = constant(value) } })
				r.s:start()
				return r.next_due()
			end
			assert.equal(3000, first(0, 0))
			assert.equal(3500, first(0, 1))
			assert.equal(27500, first(7, 0), "slot 7, the last")
			assert.equal(28000, first(7, 1))
			assert.equal(3000, first(8, 0), "slot 0 again")
		end)

		it("puts devices in neighbouring slots more than a window apart, whatever random() says", function()
			local function first(id, value)
				local r = rig({ opts = { seed = id, random = constant(value) } })
				r.s:start()
				return r.next_due()
			end
			for id = 100, 115 do
				if id % 8 ~= 7 then
					local a, b = first(id, 1), first(id + 1, 0)
					assert.is_true(b - a >= 3000, id .. ": " .. a .. " and " .. b)
				end
			end
		end)

		it("reads the device id at start(), not when it is built, and only once (a second start too)", function()
			local calls = 0
			local r = rig({ opts = { seed = function() calls = calls + 1 return 4249 end } })
			assert.equal(0, calls, "not at load (API 22/_11)")
			r.s:start()
			assert.equal(1, calls)
			local delay = r.next_due()
			assert.is_true(delay >= 6500 and delay <= 7000, "slot 1: " .. delay)
			r.s:stop()
			r.s:start()
			assert.equal(1, calls)
		end)

		it("takes slot 0 when the device id cannot be read", function()
			for _, seed in ipairs({ raises, "not a number", -1 / 0, 0 / 0 }) do
				local r = rig({ opts = { seed = seed, random = constant(0) } })
				r.s:start()
				assert.equal(3000, r.next_due(), tostring(seed))
			end
		end)

		it("opens none in stopped or standby at start, however long", function()
			for _, mode in ipairs({ "stopped", "standby" }) do
				local r = rig({ mode = mode })
				r.s:start()
				assert.equal(0, #r.live(), mode)
				assert.equal(mode, r.s:state())
				r.advance(7 * DAY)
				assert.equal(0, r.finds, mode)
			end
		end)

		it("is kept while the mode moves between seek and quiet before it", function()
			local r = rig({ opts = { random = constant(0) } })
			r.s:start()
			r.advance(1000)
			r.go("quiet")
			assert.equal(2000, r.next_due())
			r.advance(500)
			r.go("seek")
			assert.equal(1500, r.next_due(), "the same window, not a new one")
			r.go("seek")
			assert.equal(1500, r.next_due())
			r.window()
			assert.equal(1, r.own())
		end)

		it("is cancelled by standby or stopped before it opens", function()
			for _, mode in ipairs({ "standby", "stopped" }) do
				local r = rig({ mode = "quiet" })
				r.s:start()
				local due = r.live()[1]
				r.go(mode)
				assert.is_true(due.cancelled, mode)
				assert.equal(0, #r.live(), mode)
				r.advance(HOUR)
				assert.equal(0, r.finds, mode)
			end
		end)

		it("still owed after stopped or standby, opens once the mode allows it: one per load all the same", function()
			-- Fan Address typed on a stopped device: the list must not say "Looking..." for the rest of the run.
			local r = rig({ mode = "stopped" })
			r.s:start()
			r.advance(HOUR)
			r.go("quiet")
			assert.equal(1, r.next_due(), "at once: its time has passed and no window closed for 30 s")
			r.window()
			r.advance(7 * DAY)
			assert.equal(1, r.own())

			-- Standby at start whose follower disarms before its first window closed.
			local q = rig({ mode = "standby", opts = { random = constant(0) } })
			q.s:start()
			q.advance(1000)
			q.go("quiet")
			assert.equal(2000, q.next_due(), "at its time")
			q.window()
			q.advance(DAY)
			assert.equal(1, q.own())
		end)

		it("is no longer owed once a window of the follower has closed in this run", function()
			local r = rig({ mode = "standby" })
			r.s:start()
			r.advance(2000)
			r.follower()
			r.advance(3000)
			r.close()
			r.advance(MINUTE)
			r.go("quiet")
			assert.equal(0, #r.live())
			r.advance(7 * DAY)
			assert.equal(0, r.own())
		end)
	end)

	describe("the seek ladder (section 2)", function()
		local RANGES = {
			{ 3000, 3500 }, { 30000, 36000 }, { 48000, 72000 }, { 96000, 144000 }, { 240000, 360000 },
			{ 480000, 720000 },
		}
		local CAP = { 720000, 1080000 }

		local function ladder(r, n, open_ms)
			r.s:start()
			local delays = {}
			for i = 1, n do
				delays[i] = r.window(open_ms)
			end
			return delays
		end

		it("opens the window at load, then 30 s, 1, 2, 5 and 10 min after the previous window closed, then every"
			.. " 15 min, each +/-20 %", function()
			for _, seed in ipairs({ 1, 7, 12345, 99991 }) do
				local r = rig({ opts = { random = seeded(seed), seed = 8 } })
				for i, ms in ipairs(ladder(r, 14)) do
					local range = RANGES[i] or CAP
					assert.is_true(ms >= range[1] and ms <= range[2], string.format("seed %d, window %d: %d ms", seed,
						i, ms))
				end
			end
		end)

		it("reaches each end of each range, and never goes under the 30 s floor (random() at 0 and at 1)", function()
			local low = ladder(rig({ opts = { random = constant(0), seed = 0 } }), 9)
			assert.same({ 3000, 30000, 48000, 96000, 240000, 480000, 720000, 720000, 720000 }, low)
			local high = ladder(rig({ opts = { random = constant(1), seed = 0 } }), 9)
			assert.same({ 3500, 36000, 72000, 144000, 360000, 720000, 1080000, 1080000, 1080000 }, high)
		end)

		it("counts each step from the previous window's close, not its opening", function()
			local r = rig({ opts = { random = constant(0.5), seed = 0 } })
			r.s:start()
			r.window(3000)
			assert.equal(30000, r.next_due(), "30 s, the middle of its range, after the close")
			r.window(3000)
			assert.equal(60000, r.next_due(), "1 min after the close")
		end)

		it("draws from a generator of its own without random(): two devices step apart, not alike", function()
			local function delays(seed)
				return ladder(rig({ without = { "random" }, opts = { seed = seed } }), 9)
			end
			local a, b = delays(15), delays(16)
			local same = 0
			for i = 1, 9 do
				local range = RANGES[i] or CAP
				if i == 1 then
					range = { 3000 + 7 * 3500, 3500 + 7 * 3500 } -- device 15: slot 7
				end
				assert.is_true(a[i] >= range[1] and a[i] <= range[2], "window " .. i .. ": " .. a[i])
				if i > 1 and a[i] == b[i] then
					same = same + 1
				end
			end
			assert.is_true(same < 8, "the ladders differ")
			assert.same(delays(15), delays(15), "the same device at the same time steps the same way")
		end)

		it("restarts on entering seek again: 30 s after the previous window closed, then 1 min, ...", function()
			local r = rig({ opts = { random = constant(0), seed = 0 } })
			ladder(r, 8) -- at 15 min now
			assert.equal(720000, r.next_due())
			r.advance(5000)
			r.go("quiet")
			assert.equal(0, #r.live(), "leaving seek cancels its window")
			assert.equal("quiet", r.s:state())
			r.advance(5000)
			r.go("seek")
			assert.equal(20000, r.next_due(), "30 s after the last close, 10 s ago")
			r.window()
			assert.equal(48000, r.next_due(), "then 1 min, -20 %")
			r.window()
			assert.equal(96000, r.next_due())
		end)

		it("opens at once on entering seek long after the previous window closed (its step has passed)", function()
			local r = rig({ mode = "quiet", opts = { random = constant(0) } })
			r.s:start()
			r.window()
			r.advance(2 * HOUR)
			r.go("seek")
			assert.equal(1, r.next_due())
			r.window()
			assert.equal(48000, r.next_due(), "the next step, 1 min")
		end)

		it("restarts after standby and stopped as after quiet", function()
			for _, mode in ipairs({ "standby", "stopped" }) do
				local r = rig({ opts = { random = constant(0), seed = 0 } })
				ladder(r, 6)
				r.go(mode)
				assert.equal(0, #r.live(), mode)
				r.advance(10000)
				r.go("seek")
				assert.equal(20000, r.next_due(), mode)
				r.window()
				assert.equal(48000, r.next_due(), mode)
			end
		end)

		it("does not step the ladder for a window opened before seek was entered again", function()
			local r = rig({ opts = { random = constant(0), seed = 0 } })
			ladder(r, 4) -- step 4 (5 min) planned
			r.step() -- window 5 opens, still open
			r.go("quiet")
			r.go("seek")
			r.close()
			assert.equal(30000, r.next_due(), "step 1 after its close")
		end)
	end)

	describe("quiet (section 2)", function()
		it("plans nothing after the window at load, however often changed() is called", function()
			local r = rig({ mode = "quiet" })
			r.s:start()
			r.window()
			for _ = 1, 50 do
				r.s:changed()
				r.advance(HOUR)
			end
			assert.equal(1, r.own())
			assert.equal("quiet", r.s:state())
		end)

		it("plans nothing after a seek ladder left for quiet (a fan was pinned)", function()
			local r = rig()
			r.s:start()
			r.window()
			r.window()
			r.go("quiet")
			r.advance(7 * DAY)
			assert.equal(2, r.own())
		end)
	end)

	describe("the floor (section 2)", function()
		it("holds a seek window until 30 s after a window of the follower closed", function()
			local r = rig({ opts = { random = constant(0), seed = 0 } })
			r.s:start()
			r.window()
			assert.equal(30000, r.next_due())
			r.advance(15000)
			r.follower()
			r.advance(3000)
			r.close() -- 18 s after ours
			r.advance(12000) -- our timer fires: 12 s after the follower's close
			assert.is_nil(r.current)
			assert.equal(1, r.own(), "not opened under the floor")
			assert.equal(18000, r.next_due())
			assert.equal("due:18", r.s:state())
			r.step()
			assert.equal(2, r.own())
		end)

		it("re-plans to the floor at once on changed() after another window closed", function()
			local r = rig({ opts = { random = constant(0), seed = 0 } })
			r.s:start()
			r.window()
			r.advance(20000)
			r.follower()
			r.close()
			r.s:changed()
			assert.equal(30000, r.next_due())
		end)

		it("holds the window at load until 30 s after a window that closed just before start()", function()
			local r = rig({ opts = { random = constant(0), seed = 0 } })
			r.follower()
			r.close()
			r.advance(10000)
			r.s:start()
			assert.equal(20000, r.next_due())
			r.window()
			assert.equal(1, r.own())
		end)

		it("joins a window open when one of ours is due, instead of opening a second", function()
			local r = rig({ opts = { random = constant(0), seed = 0 } })
			r.s:start()
			r.window()
			r.advance(29000)
			local theirs = r.follower()
			r.advance(1000) -- ours is due now; the follower's window is open
			assert.equal(2, r.finds, "find was called")
			assert.equal(2, #r.windows, "but no window was added")
			assert.same({ "search" }, theirs.joined)
			assert.equal("open", r.s:state())
			r.advance(2000)
			r.close()
			assert.equal(48000, r.next_due(), "the next step from the joined window's close")
		end)

		it("keeps 30 s between every window of the scheduler and the close before it, over a busy day", function()
			local r = rig({ auto = true, opts = { seed = 3 } })
			r.s:start()
			for minute = 1, 24 * 60 do
				if minute % 7 == 0 and r.current == nil then
					r.follower()
				end
				if minute % 11 == 0 then
					r.s:poke("stale")
				end
				r.advance(MINUTE)
			end
			for i = 2, #r.windows do
				local w = r.windows[i]
				if w.by == "search" then
					assert.is_true(w.at >= r.windows[i - 1].closed_at + 30000, "window " .. i)
				end
			end
			assert.is_true(r.own() > 100, "pokes were served: " .. r.own())
		end)
	end)

	describe("poke (section 2)", function()
		it("opens one window as soon as the floor allows, in seek, quiet and standby", function()
			for _, mode in ipairs({ "seek", "quiet", "standby" }) do
				local r = rig({ mode = mode, auto = true })
				r.s:start()
				r.advance(HOUR)
				local before = r.own()
				r.s:poke("stale")
				local floor = r.last and (r.last + 30000 - r.clock) or 1
				assert.equal(math.max(1, floor), r.next_due(), mode)
				r.window()
				assert.equal(before + 1, r.own(), mode)
			end
		end)

		it("waits for the floor: 30 s after the last window closed", function()
			local r = rig({ mode = "quiet" })
			r.s:start()
			r.window()
			r.advance(5000)
			r.s:poke("stale")
			assert.equal(25000, r.next_due())
			r.window()
			assert.equal(0, #r.live(), "one window, then quiet again")
			assert.equal("quiet", r.s:state())
		end)

		it("does nothing in stopped, and a poke still waiting is dropped when the mode becomes stopped", function()
			local r = rig({ mode = "stopped" })
			r.s:start()
			r.s:poke("dev")
			assert.equal(0, #r.live())
			assert.equal("stopped", r.s:state())

			local q = rig({ mode = "quiet" })
			q.s:start()
			q.window()
			q.s:poke("stale")
			assert.equal(1, #q.live())
			q.go("stopped")
			assert.equal(0, #q.live())
			q.go("quiet")
			assert.equal(0, #q.live(), "the poke went with stopped")
			q.advance(DAY)
			assert.equal(1, q.own())
		end)

		it("is answered by a window of ours open now: no second find", function()
			local r = rig()
			r.s:start()
			r.step()
			r.s:poke("stale")
			r.s:poke("dev")
			assert.equal(1, r.finds)
			assert.equal(0, #r.live())
			r.close()
			assert.equal(1, #r.live(), "the ladder only")
			local delay = r.next_due()
			assert.is_true(delay >= 30000 and delay <= 36000, tostring(delay))

			local q = rig({ mode = "quiet" })
			q.s:start()
			q.step() -- the window at load, open
			q.s:poke("stale")
			q.close()
			assert.equal(0, #q.live(), "no second window after it")
			q.advance(DAY)
			assert.equal(1, q.finds)
		end)

		it("pulls the waiting seek window forward; the ladder goes on from the next step", function()
			local r = rig({ opts = { random = constant(0), seed = 0 } })
			r.s:start()
			r.window()
			r.window()
			r.window() -- step 3 (2 min) planned
			assert.equal(96000, r.next_due())
			r.advance(40000)
			r.s:poke("stale")
			assert.equal(1, r.next_due())
			r.window()
			assert.equal(240000, r.next_due(), "step 4 (5 min) next")
		end)

		it("serves a waiting window at load too: the ladder starts after it", function()
			local r = rig({ opts = { random = constant(0), seed = 7 } }) -- slot 7: due at 27 s
			r.s:start()
			r.s:poke("dev")
			assert.equal(1, r.next_due())
			r.window()
			assert.equal(30000, r.next_due(), "step 1")
			r.advance(DAY)
			assert.is_true(r.own() < 100)
		end)
	end)

	describe("stop (section 6.1)", function()
		it("cancels every timer; nothing opens, plans or acts after it", function()
			local r = rig()
			r.s:start()
			local due = r.live()[1]
			r.s:stop()
			assert.is_true(due.cancelled)
			r.s:changed()
			r.s:poke("dev")
			assert.equal(0, #r.live())
			assert.equal("off", r.s:state())
			r.advance(7 * DAY)
			assert.equal(0, r.finds)
			for _, t in ipairs(r.timers) do
				assert.is_true(t.cancelled or t.fired)
			end
		end)

		it("ignores the callback of a window that closes after it", function()
			local r = rig()
			r.s:start()
			r.step()
			r.s:stop()
			assert.equal("off", r.s:state())
			r.close()
			assert.equal(0, #r.live())
			assert.equal("off", r.s:state())
			r.advance(DAY)
			assert.equal(1, r.finds)
		end)

		it("does nothing for a timer Director fires after its cancel", function()
			local r = rig()
			r.s:start()
			local due = r.live()[1]
			r.s:stop()
			due.cb(due)
			assert.equal(0, r.finds)
		end)

		it("starts a fresh run on start() after it: the window at load again, then the ladder from step 1", function()
			local r = rig({ opts = { random = constant(0), seed = 0 } })
			r.s:start()
			for _ = 1, 7 do
				r.window()
			end
			r.s:stop()
			r.advance(HOUR)
			r.s:start()
			assert.equal(3000, r.next_due())
			r.window()
			assert.equal(30000, r.next_due())
			r.window()
			assert.equal(48000, r.next_due())
		end)

		it("on a fresh start, a window of the earlier run closing in this one feeds the list: the ladder counts from"
			.. " its close", function()
			local r = rig({ opts = { random = constant(0), seed = 0 } })
			r.s:start()
			r.step() -- the window at load, still open
			r.s:stop()
			r.s:start()
			assert.equal(3000, r.next_due())
			r.advance(1000)
			r.close() -- the earlier run's window
			assert.equal("due:2", r.s:state(), "nothing re-planned by its callback")
			r.advance(2000) -- the timer: the floor holds it
			assert.equal(1, r.finds)
			assert.equal(28000, r.next_due(), "step 1: 30 s after that close")
			r.window()
			assert.equal(48000, r.next_due(), "step 2")
		end)

		it("a second start() without stop() is a fresh run too", function()
			local r = rig({ opts = { random = constant(0), seed = 0 } })
			r.s:start()
			r.advance(1000)
			r.s:start()
			assert.equal(1, #r.live())
			assert.equal(3000, r.next_due())
		end)
	end)

	describe("state() (Dev State's search=)", function()
		it("is off, due:<s>, open, or the mode when nothing is planned", function()
			local r = rig({ opts = { random = constant(0), seed = 0 } })
			assert.equal("off", r.s:state())
			r.s:start()
			assert.equal("due:3", r.s:state())
			r.advance(2500)
			assert.equal("due:1", r.s:state(), "rounded up")
			r.step()
			assert.equal("open", r.s:state())
			r.close()
			assert.equal("due:30", r.s:state())
			r.go("quiet")
			assert.equal("quiet", r.s:state())
			r.go("standby")
			assert.equal("standby", r.s:state())
			r.go("stopped")
			assert.equal("stopped", r.s:state())
			r.s:stop()
			assert.equal("off", r.s:state())
		end)

		it("is seek when no timer could be set, and plans again on the next changed()", function()
			local broken = true
			local r
			r = rig({ opts = { timer = function(ms, cb)
				if broken then
					error("no timer")
				end
				local t = { ms = ms, due = r.clock + ms, cb = cb, cancelled = false, fired = false }
				function t:Cancel() self.cancelled = true end
				r.timers[#r.timers + 1] = t
				return t
			end } })
			r.s:start()
			assert.equal("seek", r.s:state())
			broken = false
			r.s:changed()
			assert.equal(1, #r.live())
		end)
	end)

	describe("faults: an option that raises never escapes", function()
		local function cycle(r)
			r.s:start()
			for _ = 1, 4 do
				if #r.live() > 0 then
					r.step()
				end
				if r.current then
					r.close()
				end
			end
			r.s:poke("stale")
			r.s:changed()
			r.advance(HOUR)
			if r.current then
				r.close("send")
			end
			r.s:state()
			r.s:stop()
			r.s:start()
			r.s:stop()
		end

		it("each option raising on its own", function()
			for _, name in ipairs(OPTION_NAMES) do
				local r = rig({ opts = { [name] = raises } })
				local ok, err = pcall(cycle, r)
				assert.is_true(ok, name .. ": " .. tostring(err))
			end
		end)

		it("each option missing on its own", function()
			for _, name in ipairs(OPTION_NAMES) do
				local r = rig({ without = { name } })
				local ok, err = pcall(cycle, r)
				assert.is_true(ok, name .. ": " .. tostring(err))
			end
		end)

		it("every option raising, the log included, and no options at all", function()
			local options = { seed = "not a number" }
			for _, name in ipairs(OPTION_NAMES) do
				options[name] = raises
			end
			options.log = setmetatable({}, { __index = function() return raises end })
			assert.has_no.errors(function()
				local s = search.new(options)
				s:start()
				s:changed()
				s:poke("dev")
				s:state()
				s:stop()
			end)
			assert.has_no.errors(function()
				local s = search.new(nil)
				s:start()
				s:poke("dev")
				s:state()
				s:stop()
			end)
		end)

		it("a find that raises, or returns false, is a window that closed: the cadence goes on", function()
			for _, find in ipairs({ raises, function() return false end }) do
				local r = rig({ opts = { find = find } })
				local lines = capture_log()
				r.s:start()
				r.step()
				assert.equal(1, #r.live())
				local delay = r.next_due()
				assert.is_true(delay >= 30000 and delay <= 36000, tostring(delay))
				r.step()
				assert.equal(1, #r.live())
				if find == raises then
					assert.equal(2, count(lines, "Search: the window could not open"))
				end
				quiet()
			end
		end)

		it("a find that calls back at once, and again later, closes its window once", function()
			local cbs = {}
			local r
			r = rig({ opts = { random = constant(0), seed = 0, find = function(cb)
				r.finds = r.finds + 1
				cbs[#cbs + 1] = cb
				cb({}, "open", {})
				return true
			end } })
			r.s:start()
			r.step()
			assert.equal(30000, r.next_due())
			cbs[1]({}, nil, {})
			assert.equal(30000, r.next_due(), "the second call changes nothing")
		end)

		it("a mode() that raises or names no mode opens nothing, logged once per streak", function()
			local value = raises
			local r = rig({ opts = { mode = function()
				if type(value) == "function" then
					return value()
				end
				return value
			end } })
			local lines = capture_log()
			r.s:start()
			r.s:changed()
			r.s:poke("dev")
			assert.equal(0, #r.live())
			assert.equal("stopped", r.s:state())
			assert.equal(1, count(lines, "Search: the mode could not be read"))
			value = "something new"
			r.s:changed()
			assert.equal(1, count(lines, "Search: the mode could not be read"))
			value = "quiet"
			r.s:changed()
			assert.equal(1, #r.live(), "the window at load, still owed")
			value = 42
			r.s:changed()
			assert.equal(0, #r.live())
			assert.equal(2, count(lines, "Search: the mode could not be read"), "a new streak")
			r.advance(DAY)
			assert.equal(0, r.finds)
		end)

		it("a random() that raises is the middle of the range", function()
			local r = rig({ opts = { random = raises, seed = 0 } })
			r.s:start()
			assert.equal(3250, r.next_due())
			r.window()
			assert.equal(30000, r.next_due())
			r.window()
			assert.equal(60000, r.next_due())
		end)

		it("a clock that raises keeps the last time it read", function()
			local broken = false
			local r
			r = rig({ opts = { random = constant(0), seed = 0, now = function()
				if broken then
					error("no clock")
				end
				return r.clock
			end } })
			r.s:start()
			broken = true
			assert.has_no.errors(function()
				r.s:changed()
				r.s:poke("dev")
				r.s:state()
			end)
		end)

		it("a last_closed() that raises or answers nonsense leaves the scheduler's own floor", function()
			for _, lc in ipairs({ raises, constant("soon"), constant(0 / 0) }) do
				local r = rig({ mode = "quiet", opts = { last_closed = lc } })
				r.s:start()
				r.window()
				r.advance(1000)
				r.s:poke("stale")
				assert.equal(29000, r.next_due(), tostring(lc))
			end
		end)
	end)

	describe("log lines", function()
		it("writes the debug lines of each step with Debug Mode", function()
			local lines = capture_log()
			log.set_debug(true)
			local r = rig({ opts = { random = constant(0), seed = 0 } })
			r.s:start()
			r.window()
			r.go("quiet")
			r.s:poke("stale")
			assert.equal(1, count(lines, "Search: started (seek); window at load in 3 s"))
			assert.equal(1, count(lines, "Search: window opened (load)"))
			assert.equal(1, count(lines, "Search: window closed"))
			assert.equal(1, count(lines, "Search: next window in 30 s (seek, step 1)"))
			assert.equal(1, count(lines, "Search: mode quiet (was seek)"))
			assert.equal(1, count(lines, "Search: nothing planned (quiet)"))
			assert.equal(1, count(lines, "Search: next window in 30 s (poke)"))
		end)

		it("writes nothing without Debug Mode when all goes well", function()
			local lines = capture_log()
			local r = rig({ auto = true })
			r.s:start()
			r.advance(DAY)
			r.go("quiet")
			r.s:poke("stale")
			r.advance(HOUR)
			r.go("stopped")
			r.s:stop()
			assert.same({}, lines)
		end)
	end)

	describe("a simulated week (section 2's budget)", function()
		-- Runs `plan` (hour -> mode) for a week in minutes, with the follower's ladder while standby (its windows
		-- every 15 min) and the pokes asked; returns the rig and the scheduler's windows per mode.
		local function week(plan, pokes, start_mode)
			local r = rig({ auto = true, mode = start_mode, opts = { seed = 5, random = seeded(2026) } })
			r.s:start()
			local per_mode, per_day = { seek = 0, quiet = 0, standby = 0, stopped = 0 }, {}
			for minute = 1, 7 * 24 * 60 do
				local hour = math.floor((minute - 1) / 60)
				local mode = plan(hour)
				if mode ~= r.mode then
					r.go(mode)
				end
				if mode == "standby" and minute % 15 == 0 and r.current == nil then
					r.follower()
				end
				if pokes[minute] then
					r.s:poke(pokes[minute])
				end
				r.advance(MINUTE)
			end
			for _, w in ipairs(r.windows) do
				if w.by == "search" then
					per_mode[w.mode] = per_mode[w.mode] + 1
					local day = math.floor((w.at - 1000000) / DAY) + 1
					per_day[day] = (per_day[day] or 0) + 1
				end
			end
			return r, per_mode, per_day
		end

		local function floor_held(r)
			for i = 2, #r.windows do
				local w = r.windows[i]
				if w.by == "search" then
					assert.is_true(w.at >= r.windows[i - 1].closed_at + 30000, "window " .. i)
				end
			end
		end

		it("seek all week: about 100 windows a day, the ladder on the first", function()
			local r, per_mode, per_day = week(function() return "seek" end, {})
			for day = 1, 7 do
				assert.is_true(per_day[day] >= 88 and per_day[day] <= 106, "day " .. day .. ": " .. per_day[day])
			end
			assert.equal(per_mode.seek, r.own())
			assert.is_true(per_mode.seek >= 7 * 90 and per_mode.seek <= 7 * 102, tostring(per_mode.seek))
			floor_held(r)
		end)

		it("quiet all week: one window, the one at load", function()
			local r, per_mode = week(function() return "quiet" end, {}, "quiet")
			assert.same({ seek = 0, quiet = 1, standby = 0, stopped = 0 }, per_mode)
			assert.equal(1, #r.windows)
		end)

		it("standby and stopped all week: none of their own", function()
			for _, mode in ipairs({ "standby", "stopped" }) do
				local r, per_mode = week(function() return mode end, {}, mode)
				assert.equal(0, r.own(), mode)
				assert.same({ seek = 0, quiet = 0, standby = 0, stopped = 0 }, per_mode)
			end
		end)

		it("a week of every mode: unpinned, pinned, away with following On, emptied, away with it Off", function()
			-- day 1 seek (a new device), days 2-3 quiet (picked; a stale pick pokes once), day 4 standby (the fan
			-- away, the follower armed; a poke), day 5 stopped (Fan Address emptied; a poke ignored), day 6 seek
			-- (the fan away, Follow Address Changes Off), day 7 quiet (back).
			local function plan(hour)
				local day = math.floor(hour / 24) + 1
				return ({ "seek", "quiet", "quiet", "standby", "stopped", "seek", "quiet" })[day]
			end
			local pokes = { [30 * 60 + 7] = "stale", [80 * 60 + 7] = "stale", [100 * 60 + 7] = "dev" }
			local r, per_mode, per_day = week(plan, pokes)
			assert.is_true(per_day[1] >= 88 and per_day[1] <= 106, "day 1: " .. per_day[1])
			assert.equal(1, per_day[2], "the poke")
			assert.is_nil(per_day[3])
			assert.equal(1, per_day[4], "the poke in standby")
			assert.is_nil(per_day[5], "nothing while stopped")
			assert.is_true(per_day[6] >= 88 and per_day[6] <= 106, "day 6: " .. per_day[6])
			assert.is_nil(per_day[7])
			assert.equal(1, per_mode.quiet)
			assert.equal(1, per_mode.standby)
			assert.equal(0, per_mode.stopped)
			assert.equal(per_day[1] + per_day[6], per_mode.seek)
			floor_held(r)
			-- The ladder restarted on day 6: its step 1 (30 s after a close a day old) at once, then 1, 2 min.
			local day6 = {}
			for _, w in ipairs(r.windows) do
				if w.by == "search" and w.at >= 1000000 + 5 * DAY and #day6 < 3 then
					day6[#day6 + 1] = w
				end
			end
			assert.equal(1000000 + 5 * DAY + 1, day6[1].at, "at once")
			local gap2, gap3 = day6[2].at - day6[1].closed_at, day6[3].at - day6[2].closed_at
			assert.is_true(gap2 >= 48000 and gap2 <= 72000, "1 min, +/-20 %: " .. gap2)
			assert.is_true(gap3 >= 96000 and gap3 <= 144000, "2 min, +/-20 %: " .. gap3)
		end)
	end)
end)
