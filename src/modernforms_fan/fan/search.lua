-- fan/search.lua: when the driver asks the network for fans by itself (#102). The contract is
-- docs/auto-discovery-design.md (decisions AD1, AD4, AD5; the modes and the schedule in section 2; this module's
-- interface in section 6.1); where it is silent, docs/auto-discovery-research.md section 4.1 is the rule, then
-- docs/edge-cases-discovery.md section 4.2.
--
-- The scheduler only decides when a window opens. It opens one through `find` (the Finder's find, which joins a
-- window already open, whoever opened it) and notes when its window closed; it never reads the answers (the list is
-- fed by the Finder's on_window, fan/found.lua), never writes Last Action, and never pins or reads a fan. The driver
-- says which mode applies (mode(), section 2's table); the scheduler asks it whenever it plans:
--
--   seek     the window at load, then 30 s, 1, 2, 5, 10 min after the previous window closed, then every 15 min,
--            each +/-20 %; entering seek again restarts the ladder
--   quiet    the window at load only
--   standby  none of its own: the follower's windows feed the list
--   stopped  none, not even at load (AD5: an empty Fan Address on a pinned device)
--
-- No window of the scheduler opens less than 30 s after any window of this device closed (last_closed(), which
-- covers the follower's windows too); a due window waits for that floor. poke() opens one window as soon as the
-- floor allows, in any mode but stopped. The window at load is owed from start() until a window of this device has
-- closed: it opens at 3 s plus the device's slot plus jitter while the mode is seek or quiet, and, when the mode at
-- that moment was standby or stopped, as soon as the mode allows it (so a list is never left "Looking..." for the
-- rest of a run; one window per load all the same). Nothing is persisted: a load starts afresh.
--
-- Pure like fan/follow.lua, its model: nothing here touches Director. Everything arrives as an option, every option
-- is called through pcall, and nothing raises from here:
--
--   search.new({
--       find = fn(cb(list, err, heard)) -> true,   -- Finder:find: one window, or the one already open
--       last_closed = fn() -> ms or nil,           -- Finder:last_closed(): when any window of this device closed
--       mode = fn() -> "seek" | "quiet" | "standby" | "stopped",
--       timer = fn(ms, cb) -> object with :Cancel(),   -- C4:SetTimer
--       now = fn() -> ms,
--       seed = fn() -> number or a number,         -- the device id, read at the first plan, never at load
--       random = fn() -> 0..1,                     -- tests; default: a generator of its own, seeded from seed and now
--       log = common/log.lua,
--   })
--   s:start(), s:changed(), s:poke(why), s:state(), s:stop()
--
-- Lua 5.1: no goto, no integer division, no bit operators.

local search = {}

-- The schedule (section 2).
search.FIRST_MS = 3000                                     -- the window at load: 3 s after start(),
search.SLOTS = 8                                           -- plus the device's slot (its id mod 8)
search.SLOT_MS = 3500                                      -- of 3.5 s each, longer than a window (3 s),
search.JITTER_MS = 500                                     -- plus 0 to 0.5 s from random()
search.SEEK_MS = { 30000, 60000, 120000, 300000, 600000 } -- seek: after the previous window closed,
search.SEEK_EVERY_MS = 900000                              -- then every 15 min,
search.SPREAD = 0.2                                        -- each step +/-20 %
search.MIN_GAP_MS = 30000                                  -- never sooner than this after any window closed

-- The modes mode() may answer; anything else plans nothing, as stopped does (an automation acts only on what it
-- can check).
search.MODES = { seek = true, quiet = true, standby = true, stopped = true }

-- The generator of its own (Park and Miller's minimal standard), as fan/follow.lua has it: LuaJIT seeds every Lua
-- state alike, so two devices drawing from math.random would step alike forever (review of #48). The products stay
-- below 2^46, exact in a double.
local PM_MODULUS, PM_MULTIPLIER = 2147483647, 16807
local SEED_STEP = 7919 -- spreads consecutive device ids across the generator's seeds

local function park_miller(state)
	return function()
		state = (state * PM_MULTIPLIER) % PM_MODULUS
		return state / PM_MODULUS
	end
end

-- A device id as a whole number >= 0; anything else is 0.
local function seed_of(value)
	local n = math.floor(math.abs(tonumber(value) or 0))
	if not (n >= 0 and n < 9007199254740992) then -- NaN, infinity, or past exact integers
		return 0
	end
	return n
end

local function span(ms)
	if ms < 60000 then
		return string.format("%d s", math.floor(ms / 1000 + 0.5))
	end
	return string.format("%d min", math.floor(ms / 60000 + 0.5))
end

-- A finite number, or nil.
local function number(value)
	if type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge then
		return value
	end
	return nil
end

-- The instance -----------------------------------------------------------------------------------------------------

local Search = {}
Search.__index = Search

-- Never raises and calls no option: building the scheduler in OnDriverInit sends and arms nothing.
function search.new(opts)
	opts = type(opts) == "table" and opts or {}
	return setmetatable({
		o = opts,
		random = opts.random, -- nil until the first plan makes the generator of its own
		seeded = nil,         -- the device id, once read (seed_value)
		running = false,      -- between start() and stop()
		run = nil,            -- a token per run: a window of an earlier run does not act in this one
		mode = nil,           -- the mode the last plan read
		bad_mode = false,     -- an unreadable mode() was logged, once per streak
		started_at = nil,
		load_due = nil,       -- when the window at load is due
		owed = false,         -- the window at load has not happened: no window of this device closed since start()
		poked = nil,          -- why poke() asked for a window, until one of ours opens
		entry = 0,            -- times seek was entered, so a window of an earlier stay does not step the ladder
		step = 1,             -- the seek window planned next: SEEK_MS[step], then SEEK_EVERY_MS
		ladder_due = nil,     -- when that window is due, while in seek
		window = nil,         -- our window, from find() until its callback
		own_close = nil,      -- when a window of ours last closed (the floor, with last_closed())
		due = nil,            -- when the one timer opens the next window
		token = nil, handle = nil,
		last_now = nil,
	}, Search)
end

function Search:say(level, fmt, ...)
	pcall(function(...)
		self.o.log[level](fmt, ...)
	end, ...)
end

function Search:now()
	local ok, t = pcall(self.o.now)
	if ok and number(t) then
		self.last_now = t
		return t
	end
	self:say("error", "Search: the clock could not be read: %s", tostring(t))
	return self.last_now or 0
end

-- The device id (seed), read once, at the first plan and never at load (API 22/_11: GetDeviceID is not for
-- OnDriverInit); it also seeds the generator of its own when no random() was given.
function Search:seed_value()
	if self.seeded == nil then
		local value = self.o.seed
		if type(value) == "function" then
			local ok, v = pcall(value)
			if not ok then
				self:say("error", "Search: the device id could not be read: %s", tostring(v))
			end
			value = ok and v or nil
		end
		self.seeded = seed_of(value)
		if self.random == nil then
			self.random = park_miller((self.seeded * SEED_STEP + math.floor(math.abs(self:now()))) % (PM_MODULUS - 1) + 1)
		end
	end
	return self.seeded
end

-- 0..1; a broken random() is the middle of every range.
function Search:rand()
	if self.random == nil then
		self:seed_value()
	end
	local ok, r = pcall(self.random)
	if not ok or type(r) ~= "number" or r ~= r then
		return 0.5
	elseif r < 0 then
		return 0
	elseif r > 1 then
		return 1
	end
	return r
end

-- The timer ----------------------------------------------------------------------------------------------------------

function Search:cancel()
	local handle = self.handle
	self.handle, self.token, self.due = nil, nil, nil
	if handle ~= nil then
		-- Director's timer object may be userdata, so it is not type-tested.
		pcall(function() handle:Cancel() end)
	end
end

-- Replaces the one timer. The token makes a callback that comes after a cancel, or for a replaced timer, a no-op.
-- false when no timer could be set.
function Search:schedule(ms, fn)
	self:cancel()
	ms = math.floor(ms + 0.5)
	if ms < 1 then
		ms = 1 -- C4:SetTimer wants a delay above 0 (API 34_timer/_1-SetTimer.md)
	end
	local token = {}
	self.token = token
	local ok, handle = pcall(self.o.timer, ms, function()
		if self.token ~= token or not self.running then
			return
		end
		self.token, self.handle = nil, nil
		local fine, err = pcall(fn)
		if not fine then
			self:say("error", "Search: %s", tostring(err))
		end
	end)
	if not ok then
		if self.token == token then
			self.token = nil
		end
		self:say("error", "Search: no timer could be set: %s", tostring(handle))
		return false
	end
	if self.token == token then
		self.handle = handle
	end
	return true
end

-- What the options say -----------------------------------------------------------------------------------------------

-- The mode now; one that raises or names no mode is stopped (nothing opens), logged once per streak.
function Search:read_mode()
	local ok, mode = pcall(self.o.mode)
	if ok and type(mode) == "string" and search.MODES[mode] then
		self.bad_mode = false
		return mode
	end
	if not self.bad_mode then
		self.bad_mode = true
		self:say("error", "Search: the mode could not be read (%s); not searching", tostring(mode))
	end
	return "stopped"
end

-- When a window of this device last closed: the Finder's word or our own, whichever is later; nil before any.
function Search:latest_close()
	local ok, at = pcall(self.o.last_closed)
	if not ok then
		self:say("error", "Search: the last window could not be read: %s", tostring(at))
		at = nil
	end
	at = number(at)
	local own = self.own_close
	if at == nil or (own ~= nil and own > at) then
		return own
	end
	return at
end

-- The schedule (section 2) -------------------------------------------------------------------------------------------

-- The window at load: 3 s, plus the device's slot (its id mod 8, 3.5 s each: longer than a window, so devices of one
-- project started together in different slots never share one), plus 0..0.5 s.
function Search:first_delay()
	local slot = self:seed_value() % search.SLOTS
	return search.FIRST_MS + slot * search.SLOT_MS + math.floor(self:rand() * search.JITTER_MS + 0.5)
end

-- The seek window `step` after the previous window closed: its step +/-20 %, never under the floor.
function Search:step_delay(step)
	local base = search.SEEK_MS[step] or search.SEEK_EVERY_MS
	local ms = math.floor(base * (1 - search.SPREAD + 2 * search.SPREAD * self:rand()) + 0.5)
	if ms < search.MIN_GAP_MS then
		ms = search.MIN_GAP_MS
	end
	return ms
end

-- The ladder's next window, counted from `ref` (the previous window's close). Drawn once per step, so a re-plan
-- keeps it.
function Search:plan_step(ref)
	self.ladder_due = ref + self:step_delay(self.step)
end

-- Entering seek (again) restarts the ladder: its first step after the previous window of this device closed.
function Search:enter_seek()
	self.entry = self.entry + 1
	self.step = 1
	self:plan_step(self:latest_close() or self:now())
end

-- Reads the mode and notes a change; returns it.
function Search:refresh()
	local mode = self:read_mode()
	if mode ~= self.mode then
		local was = self.mode
		self.mode = mode
		if mode == "seek" then
			self:enter_seek()
		elseif mode == "stopped" then
			self.poked = nil -- not in stopped (section 2)
		end
		if was ~= nil then
			self:say("debug", "Search: mode %s (was %s)", mode, was)
		end
	end
	return mode
end

-- The window at load is owed until a window of this device has closed since start() (ours, or the follower's).
function Search:still_owed()
	if self.owed then
		local at = self:latest_close()
		if at ~= nil and self.started_at ~= nil and at >= self.started_at then
			self.owed = false -- a window closed in this run (the follower's): it fed the list
			if self.mode == "seek" then
				self:plan_step(at) -- the ladder's first step from that close
			end
		end
	end
	return self.owed
end

-- The next window for the mode: the earliest of a poke, the window at load and the ladder, then held to the floor.
-- With may_open (the timer's callback), a window due now opens; otherwise a timer is set, or kept when it is the same.
function Search:plan(may_open)
	if not self.running or self.window ~= nil then
		return -- planned again when our window closes
	end
	local mode = self.mode
	local due, why
	if mode ~= "stopped" and mode ~= nil then
		if self.poked ~= nil then
			due, why = self:now(), "poke"
		end
		if (mode == "seek" or mode == "quiet") and self:still_owed() then
			if due == nil or self.load_due < due then
				due, why = self.load_due, "load"
			end
		end
		if mode == "seek" and not self.owed and self.ladder_due ~= nil then
			if due == nil or self.ladder_due < due then
				due, why = self.ladder_due, "seek"
			end
		end
	end
	if due == nil then
		if self.token ~= nil then
			self:say("debug", "Search: nothing planned (%s)", tostring(mode))
		end
		self:cancel()
		return
	end
	local now = self:now()
	local floor = self:latest_close()
	floor = floor and (floor + search.MIN_GAP_MS)
	if floor and floor > due then
		due = floor
	end
	if due < now then
		due = now
	end
	if may_open and due <= now then
		self:open_window()
		return
	end
	if self.token ~= nil and self.due == due then
		return -- the same window, already planned
	end
	if self:schedule(due - now, function() self:fire() end) then
		self.due = due
		self:say("debug", "Search: next window in %s (%s%s)", span(due - now), why,
			why == "seek" and (", step " .. self.step) or "")
	end
end

-- The timer: the mode may have changed without changed(), and a window may have closed since (the floor).
function Search:fire()
	self.due = nil
	self:refresh()
	self:plan(true)
end

-- A window (section 2) -----------------------------------------------------------------------------------------------

function Search:open_window()
	self:cancel()
	local w = {
		run = self.run, entry = self.entry, open = true,
		load = self.owed,
		ladder = self.mode == "seek" and not self.owed,
		poke = self.poked,
	}
	self.poked = nil
	self.window = w
	self:say("debug", "Search: window opened (%s)", w.poke and ("poke: " .. w.poke) or w.load and "load"
		or ("seek, step " .. self.step))
	local ok, started = pcall(self.o.find, function()
		self:window_closed(w)
	end)
	if not ok then
		self:say("error", "Search: the window could not open: %s", tostring(started))
	end
	if w.open and (not ok or started == false) then
		self:window_closed(w)
	end
end

-- The window's callback only notes its end: the list reads the answers (section 6.1).
function Search:window_closed(w)
	if not w.open then
		return
	end
	w.open = false
	if not self.running then
		return -- after stop() no callback acts
	end
	local now = self:now()
	self.own_close = now -- a window of an earlier run still counts for the floor
	if w.run ~= self.run then
		return
	end
	if self.window == w then
		self.window = nil
	end
	self.owed = false
	self:refresh()
	if self.mode == "seek" then
		if w.ladder and w.entry == self.entry then
			self.step = self.step + 1
		end
		self:plan_step(now)
	end
	self:say("debug", "Search: window closed")
	self:plan(false)
end

-- The interface (section 6.1) ----------------------------------------------------------------------------------------

-- The end of OnDriverLateInit: the window at load (section 2), unless the mode is stopped or standby now. A second
-- start, with or without stop() before it, is a fresh run.
function Search:start()
	self:cancel()
	self.running = true
	self.run = {}
	self.window = nil
	self.mode = nil
	self.poked = nil
	self.owed = true
	self.step = 1
	self.ladder_due = nil
	local now = self:now()
	self.started_at = now
	self.load_due = now + self:first_delay()
	local mode = self:refresh()
	if mode == "seek" or mode == "quiet" then
		self:say("debug", "Search: started (%s); window at load in %s", mode, span(self.load_due - now))
	else
		self:say("debug", "Search: started (%s); no window at load now", mode)
	end
	self:plan(false)
end

-- Re-plan for the mode now (the driver calls it whenever the mode may have changed). Leaving seek cancels its
-- window; quiet, standby and stopped plan nothing of their own.
function Search:changed()
	if not self.running then
		return
	end
	self:refresh()
	self:plan(false)
end

-- One window as soon as the floor allows, in any mode but stopped: "stale" (a pick or Use Selected Fan answered
-- not_picked or no_answer), "dev" (Dev Search). A window of ours open now answers it.
function Search:poke(why)
	if not self.running then
		return
	end
	local mode = self:refresh()
	why = tostring(why)
	if mode == "stopped" then
		self:say("debug", "Search: %s ignored: not searching while stopped", why)
		return
	elseif self.window ~= nil then
		self:say("debug", "Search: %s: a window is open now", why)
		return
	end
	self.poked = why
	self:plan(false)
end

-- Dev State's search=: "off" before start() and after stop(), "open" while our window has not called back,
-- "due:<s>" (whole seconds, rounded up) while a window is planned, else the mode (seek only when no timer could be
-- set).
function Search:state()
	if not self.running then
		return "off"
	elseif self.window ~= nil then
		return "open"
	elseif self.due ~= nil then
		local s = math.ceil((self.due - self:now()) / 1000)
		if s < 0 then
			s = 0
		end
		return "due:" .. tostring(s)
	end
	return self.mode or "stopped"
end

-- OnDriverDestroyed: the timer cancelled; nothing opens, plans or acts after it.
function Search:stop()
	self:cancel()
	self.running = false
	self.run = nil
	self.window = nil
	self.poked = nil
end

return search
