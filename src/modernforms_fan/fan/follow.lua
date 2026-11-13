-- fan/follow.lua: following the pinned fan to its new address by itself (#39). The contract is
-- docs/address-follow-design.md (decisions F1 to F9, this module's interface in section 2.3); where it is
-- silent, docs/edge-cases-address.md (ECA) section 3 is the rule.
--
-- While the model's phase says the pinned fan is not at Fan Address (offline, foreign, Gen 4, not a fan), the
-- follower asks the network for the pinned MAC in Find Fans windows on a growing schedule and hands each address
-- an answer names to the model, which reads it once and moves only when the pinned fan answers there
-- (model:follow, section 2.2). The follower decides when to look and what to read; the model decides whether it
-- is the fan; the driver writes the Fan Address row and Last Action. Nothing here is persisted (F3: memory only).
--
-- Pure like fan/discovery.lua: nothing here touches Director. Everything arrives as an option, and every option
-- is called through pcall, so one that is missing or raises lands on a refusal and nothing raises from here:
--
--   follow.new({
--       find = fn(cb(list, err, heard)),   -- Finder:find: one window, the query twice, 3 s of answers
--       candidates = discovery.candidates, -- (heard, mac12, current, anchor) -> { address, ... }: F4's first step;
--                                          -- anchor: the address the pinned fan last answered at (#214)
--       follow = fn(address, mac12, cb(result, args)),   -- model:follow: "followed" with { address, was },
--                                          -- else "not_same", "no_answer" or "busy"
--       phase = fn() -> string,            -- the model's phase now (model:phase())
--       identity = fn() -> pin or nil,     -- model:identity(): { client_id, mac, address, ... }
--       address = fn() -> string,          -- the current Fan Address
--       enabled = fn() -> bool,            -- Follow Address Changes is On (F7)
--       timer = fn(ms, cb) -> object with :Cancel(),   -- C4:SetTimer
--       now = fn() -> ms, random = fn() -> 0..1 (tests; default: a generator of its own, see seed),
--       seed = fn() -> number or a number, -- the device id, read at the first arm: window 1's slot and the seed
--                                          -- of the generator (with the clock), so devices never step alike
--       on_followed = fn(address, was),    -- driver.lua: the Fan Address row and Last Action L30 (F6)
--       on_refused = fn(),                 -- driver.lua: Last Action L31, once per streak (F6)
--       log = common/log.lua,
--   })
--   f:phase_changed(phase), f:address_edited(), f:clicked(), f:contact(), f:switch(on), f:state(), f:stop()
--
-- Lua 5.1: no goto, no integer division, no bit operators.

local follow = {}

-- The offline-like phases (docs/v1-design.md section 6.1), as fan/model.lua names them: the pinned fan is not
-- answering at Fan Address, or something else is (F2).
follow.OFFLINE_LIKE = { offline = true, foreign = true, gen4 = true, notfan = true }

-- The schedule (F3; ECA 3.3).
follow.FIRST_MS = 2000                                      -- window 1: 2 s after arming,
follow.SLOTS = 8                                            -- plus the device's slot (its id mod 8)
follow.SLOT_MS = 3500                                       -- of 3.5 s each, longer than a window (3 s),
follow.JITTER_MS = 500                                      -- plus 0 to 0.5 s from random()
follow.LADDER_MS = { 30000, 60000, 120000, 300000, 600000 } -- windows 2 to 6, after the previous one closed
follow.CAP_MS = 900000                                      -- window 7 on: every 15 min
follow.SPREAD = 0.2                                         -- each step +/-20 %
follow.MIN_GAP_MS = 30000                                   -- never closer than this after a window closed
follow.RETRY_AT_MS = { 10000, 30000, 90000 }                -- an unverified candidate read again, no window
follow.MAX_READS = 3                                        -- addresses read in one window (F4)
follow.GUARD_MAX = 3                                        -- follows in an hour; the next is refused (F6)
follow.GUARD_MS = 3600000

-- The generator of its own (Park and Miller's minimal standard): LuaJIT seeds every Lua state alike, so two
-- devices drawing from math.random would step alike forever (review of #48). The products stay below 2^46, exact
-- in a double.
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

-- Helpers -----------------------------------------------------------------------------------------------------

local function trim(text)
	if type(text) ~= "string" then
		return ""
	end
	-- Linear: a pattern anchored at the end rescans a long inner run of blanks
	-- from every start, and this text comes off the network.
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

-- 12 uppercase hex digits, by the rule of wire.mac12 (bare, or six pairs joined by one ":" or "-"), kept here so
-- this module needs no other.
local function mac_digits(text)
	if type(text) ~= "string" then
		return nil
	end
	local s = trim(text)
	if s:find("^%x%x%x%x%x%x%x%x%x%x%x%x$") then
		return s:upper()
	end
	local a, _, b, c, d, e, f = s:match("^(%x%x)([:%-])(%x%x)%2(%x%x)%2(%x%x)%2(%x%x)%2(%x%x)$")
	if not a then
		return nil
	end
	return (a .. b .. c .. d .. e .. f):upper()
end

-- Text that came off the network, or through an option, as a log line may carry it (#214): at most LOG_CUT
-- characters, and every byte that is not printable ASCII written as "?", so a fan's answer cannot break a line or
-- forge one.
local LOG_CUT = 200

local function printable(text)
	text = tostring(text)
	if #text > LOG_CUT then
		text = text:sub(1, LOG_CUT)
	end
	return (text:gsub("[^\32-\126]", "?"))
end

-- "...5301": an id in the log shows its last four characters only (docs/v1-design.md section 3.7), printable.
local function tail(id)
	if type(id) ~= "string" or id == "" then
		return "...????"
	end
	return "..." .. printable(id:sub(-4))
end

-- The four numbers of a dotted quad in the one spelling discovery and wire.ipv4 write (no leading zero), or nil.
local function octets(text)
	if type(text) ~= "string" then
		return nil
	end
	local parts = { text:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$") }
	if #parts ~= 4 then
		return nil
	end
	for i, part in ipairs(parts) do
		if #part > 3 or (#part > 1 and part:sub(1, 1) == "0") or tonumber(part) > 255 then
			return nil
		end
		parts[i] = tonumber(part)
	end
	return parts
end

-- The rule of discovery.same_subnet, kept here so this module needs no other (#214): the same /24 (no documented
-- API gives the LAN's netmask), or both in the link-local 169.254/16. false for anything that is not an address.
local function same_subnet(a, b)
	local x, y = octets(a), octets(b)
	if not x or not y then
		return false
	end
	if x[1] == 169 and x[2] == 254 then
		return y[1] == 169 and y[2] == 254
	end
	return x[1] == y[1] and x[2] == y[2] and x[3] == y[3]
end

local function span(ms)
	if ms < 60000 then
		return string.format("%d s", math.floor(ms / 1000 + 0.5))
	end
	return string.format("%d min", math.floor(ms / 60000 + 0.5))
end

local function fans(n)
	return n == 1 and "1 fan" or string.format("%d fans", n)
end

-- The instance -------------------------------------------------------------------------------------------------

local Follower = {}
Follower.__index = Follower

-- Never raises and calls no option: building the follower in OnDriverInit sends and arms nothing (ECA E8).
function follow.new(opts)
	opts = type(opts) == "table" and opts or {}
	return setmetatable({
		o = opts,
		random = opts.random,  -- nil until the first arm makes the generator of its own
		seeded = nil,          -- the device id, once read (seed_value)
		stopped = false,
		switched = true,       -- switch()'s last word; Follow Address Changes defaults to On (F7)
		pending = false,       -- the typed address has not answered yet (F5)
		edits = 0,             -- address_edited() and clicked() calls, so a window knows whether the owner acted since
		tracked = nil,         -- the phase phase_changed() last reported
		armed = false,
		step = 1,              -- the window that is due or under way (state() shows it)
		window = nil,          -- that window, from its opening to the end of its reads and retries
		due = nil,             -- when the next window opens, while only its timer is pending
		token = nil, handle = nil, -- the one timer: the next window or the next retry
		last_close = nil,      -- when a window of this follower last closed (the 30 s floor)
		last_now = nil,
		follows = {},          -- when the last follows happened (the flap guard)
		refusing = false,      -- the guard refused, and on_refused was told, since it last let one through
		warned_send = false,   -- the streak warns of ECA 3.6
		warned_silent = false,
	}, Follower)
end

function Follower:say(level, fmt, ...)
	pcall(function(...)
		self.o.log[level](fmt, ...)
	end, ...)
end

function Follower:now()
	local ok, t = pcall(self.o.now)
	if ok and type(t) == "number" and t == t then
		self.last_now = t
		return t
	end
	self:say("error", "Follow: the clock could not be read: %s", tostring(t))
	return self.last_now or 0
end

-- The device id (seed), read once, at the first arm and never at load (API 22/_11: GetDeviceID is not for
-- OnDriverInit); it also seeds the generator of its own when no random() was given.
function Follower:seed_value()
	if self.seeded == nil then
		local value = self.o.seed
		if type(value) == "function" then
			local ok, v = pcall(value)
			if not ok then
				self:say("error", "Follow: the device id could not be read: %s", tostring(v))
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
function Follower:rand()
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

-- The timer ------------------------------------------------------------------------------------------------------

function Follower:cancel()
	local handle = self.handle
	self.handle, self.token = nil, nil
	if handle ~= nil then
		-- Director's timer object may be userdata, so it is not type-tested.
		pcall(function() handle:Cancel() end)
	end
end

-- Replaces the one timer. The token makes a callback that comes after a cancel, or for a replaced timer, a no-op.
-- false when no timer could be set.
function Follower:schedule(ms, fn)
	self:cancel()
	ms = math.floor(ms + 0.5)
	if ms < 1 then
		ms = 1 -- C4:SetTimer wants a delay above 0 (API 34_timer/_1-SetTimer.md)
	end
	local token = {}
	self.token = token
	local ok, handle = pcall(self.o.timer, ms, function()
		if self.token ~= token or self.stopped then
			return
		end
		self.token, self.handle = nil, nil
		local fine, err = pcall(fn)
		if not fine then
			self:say("error", "Follow: %s", tostring(err))
		end
	end)
	if not ok then
		if self.token == token then
			self.token = nil
		end
		self:say("error", "Follow: no timer could be set: %s", tostring(handle))
		return false
	end
	if self.token == token then
		self.handle = handle
	end
	return true
end

-- What the options say -------------------------------------------------------------------------------------------

-- The model's phase now. Without the option, the one phase_changed() last reported; one that raises is no phase,
-- so nothing opens (an automation acts only on what it can check).
function Follower:model_phase()
	if self.o.phase == nil then
		return self.tracked
	end
	local ok, phase = pcall(self.o.phase)
	if not ok then
		self:say("error", "Follow: the phase could not be read: %s", tostring(phase))
		return nil
	end
	return phase
end

function Follower:current()
	local ok, text = pcall(self.o.address)
	if not ok then
		self:say("error", "Follow: Fan Address could not be read: %s", tostring(text))
		return ""
	end
	return trim(text)
end

-- The pinned fan's MAC as 12 digits, or nil: no pin, or a pin without a MAC. None is taken from the client id:
-- model:follow refuses a pin without a MAC (F2), so a window for one could never end in a follow (review of #48).
function Follower:pinned_mac()
	local ok, pin = pcall(self.o.identity)
	if not ok then
		self:say("error", "Follow: the pinned fan could not be read: %s", tostring(pin))
		return nil
	end
	if type(pin) ~= "table" then
		return nil
	end
	return mac_digits(pin.mac12) or mac_digits(pin.mac)
end

-- The address whose subnet a follow stays in (#214): where the pinned fan last answered (the pin's address), else
-- `current`, the Fan Address in use; nil when neither is an address. Only the automatic move is held to it: an
-- address the owner types into Fan Address is the owner's, wherever it is (F5).
function Follower:anchor(current)
	local ok, pin = pcall(self.o.identity)
	if ok and type(pin) == "table" then
		local address = trim(pin.address)
		if octets(address) then
			return address
		end
	end
	if octets(current) then
		return current
	end
	return nil
end

-- Follow Address Changes (F7): the last switch() and, when it is given, enabled(). Only true or "On" is On; one
-- that raises is Off.
function Follower:switched_on()
	if not self.switched then
		return false
	elseif self.o.enabled == nil then
		return true
	end
	local ok, on = pcall(self.o.enabled)
	if not ok then
		self:say("error", "Follow: Follow Address Changes could not be read: %s", tostring(on))
		return false
	end
	return on == true or (type(on) == "string" and on:lower() == "on")
end

-- Why the follower may not look now, or nil (F2; ECA 3.2): the switch, the typed address (F5), the phase, an
-- empty Fan Address (F5: the stop switch, never filled, never searched), a pin without a MAC. A Use Selected Fan
-- read under way is the model's to say ("busy"); rebooting, unset and waiting are not offline-like.
function Follower:blocked(phase)
	if self.stopped then
		return "stopped"
	elseif not self:switched_on() then
		return "switched Off"
	elseif self.pending then
		return "pending"
	elseif not follow.OFFLINE_LIKE[phase] then
		return "phase " .. tostring(phase)
	elseif self:current() == "" then
		return "Fan Address is empty"
	elseif self:pinned_mac() == nil then
		return "the pinned fan has no MAC"
	end
	return nil
end

-- The flap guard (F6): fewer than 3 follows in the last hour.
function Follower:guard_ok()
	local now, kept = self:now(), {}
	for _, at in ipairs(self.follows) do
		if now - at < follow.GUARD_MS then
			kept[#kept + 1] = at
		end
	end
	self.follows = kept
	return #kept < follow.GUARD_MAX
end

-- The schedule (F3; ECA 3.3) -------------------------------------------------------------------------------------

-- Window 1: 2 s, plus the device's slot (its id mod 8, 3.5 s each: longer than a window, so two devices armed
-- together in different slots never share one), plus 0..0.5 s.
function Follower:first_delay()
	local slot = self:seed_value() % follow.SLOTS
	return follow.FIRST_MS + slot * follow.SLOT_MS + math.floor(self:rand() * follow.JITTER_MS + 0.5)
end

-- Window `step` (2 on) after the previous one closed: its step +/-20 %, never under 30 s.
function Follower:ladder_delay(step)
	local base = follow.LADDER_MS[step - 1] or follow.CAP_MS
	local ms = math.floor(base * (1 - follow.SPREAD + 2 * follow.SPREAD * self:rand()) + 0.5)
	if ms < follow.MIN_GAP_MS then
		ms = follow.MIN_GAP_MS
	end
	return ms
end

function Follower:not_before(due)
	local floor = self.last_close and (self.last_close + follow.MIN_GAP_MS)
	if floor and due < floor then
		return floor
	end
	return due
end

-- Disarmed: the timer cancelled, back to step 1 (ECA 3.2). A read in flight still lands in read_done: a follow the
-- model has made is reported, nothing else is.
function Follower:disarm()
	self:cancel()
	self.armed, self.step, self.window, self.due = false, 1, nil, nil
	self.warned_send, self.warned_silent = false, false
end

function Follower:wait_window(due)
	self.window = nil
	due = self:not_before(due)
	self.due = due
	if not self:schedule(due - self:now(), function() self:open_window() end) then
		self:disarm()
	end
end

function Follower:arm(phase)
	if not follow.OFFLINE_LIKE[phase] then
		return
	end
	local why = self:blocked(phase)
	if why == "pending" then
		self:say("debug", "Follow: waiting, the typed address has not answered yet")
		return
	elseif why then
		self:say("debug", "Follow: not armed (%s)", why)
		return
	end
	self.armed, self.step = true, 1
	local now = self:now()
	local due = self:not_before(now + self:first_delay())
	self:say("debug", "Follow: armed (%s); window 1 in %s", tostring(phase), span(due - now))
	self:wait_window(due)
end

-- ECA 3.3: a change between offline-like phases pulls the next window forward, never to less than 30 s after the
-- last one closed. A window under way, its reads and their retries go on as they are.
function Follower:pull_forward()
	if self.due == nil then
		return
	end
	local now = self:now()
	local due = self:not_before(now + self:first_delay())
	if due < self.due then
		self:say("debug", "Follow: window %d pulled forward; in %s", self.step, span(due - now))
		self:wait_window(due)
	end
end

-- A window (F3: as Find Fans runs it) ----------------------------------------------------------------------------

function Follower:open_window()
	self.due = nil
	local phase = self:model_phase()
	local why = self:blocked(phase)
	if why then
		self:say("debug", "Follow: window %d not opened (%s)", self.step, why)
		self:disarm()
		return
	end
	local now = self:now()
	if self:not_before(now) > now then
		-- A window closed after this one was planned (one that a disarm left running): 30 s after it.
		self:wait_window(now)
		return
	end
	local w = {
		n = self.step, edits = self.edits, current = self:current(), mac = self:pinned_mac(), phase = phase,
		open = true,
	}
	w.anchor = self:anchor(w.current)
	self.window = w
	local ok, started = pcall(self.o.find, function(list, err, heard)
		self:window_closed(w, list, err, heard)
	end)
	if not ok then
		self:say("error", "Follow: the window could not open: %s", tostring(started))
	end
	if w.open and (not ok or started == false) then
		self:window_closed(w, nil, "find", nil)
	end
end

-- FA15 (ECA 3.6): the pinned fan announces itself at the current address while its web server stays silent, a
-- warning once per streak (Reboot Fan cannot help then).
function Follower:check_silent(w, heard)
	local here = false
	if w.phase == "offline" then
		for _, entry in ipairs(heard) do
			if type(entry) == "table" and mac_digits(entry.mac) == w.mac and trim(entry.address) == w.current then
				here = true
				break
			end
		end
	end
	if here and not self.warned_silent then
		self:say("warn", "Fan %s is on the network at %s, but its web server does not answer", tail(w.mac),
			printable(w.current))
	end
	self.warned_silent = here
end

-- F4's first step through the option, then at most 3 distinct addresses other than the current one, each in the
-- subnet of the window's anchor (#214: where the pinned fan last answered), whatever the option answers. An address
-- outside it is never read: a fan that moved to another subnet waits for the owner to type its address.
function Follower:pick(heard, w)
	local ok, list = pcall(self.o.candidates, heard, w.mac, w.current, w.anchor)
	if not ok then
		self:say("error", "Follow: the candidates could not be read: %s", tostring(list))
		return {}
	end
	local out, seen = {}, {}
	if type(list) == "table" then
		for _, address in ipairs(list) do
			if #out >= follow.MAX_READS then
				break
			end
			if type(address) == "string" and address ~= w.current and not seen[address] then
				seen[address] = true
				if same_subnet(w.anchor, address) then
					out[#out + 1] = address
				else
					self:say("debug", "Follow: %s is outside the subnet of %s; not read", printable(address),
						tostring(w.anchor))
				end
			end
		end
	end
	return out
end

-- The window's callback: `heard` is every distinct answer of the window (section 2.1); a Finder that passes only
-- the list is read through the list.
function Follower:window_closed(w, list, err, heard)
	if not w.open then
		return
	end
	w.open = false
	local now = self:now()
	self.last_close = now -- a window a disarm left running still counts for the 30 s
	if self.window ~= w or self.stopped then
		return
	end
	self.step = w.n + 1
	w.next_due = now + self:ladder_delay(self.step)
	if type(heard) ~= "table" then
		heard = type(list) == "table" and list or {}
	end
	-- FA17: nothing could be sent; the ladder goes on, nothing in Last Action.
	if err ~= nil and not self.warned_send then
		self:say("warn", "Following could not send its query on this controller")
	end
	self.warned_send = err ~= nil
	self:check_silent(w, heard)
	local cands = self:pick(heard, w)
	if #cands == 0 then
		self:say("debug", "Follow: window %d (next in %s): heard %s%s", w.n, span(w.next_due - now), fans(#heard),
			err ~= nil and (" (" .. tostring(err) .. ")") or "")
		self:wait_window(w.next_due)
		return
	end
	self:say("debug", "Follow: window %d: heard %s, reading %d", w.n, fans(#heard), #cands)
	w.queue, w.unverified, w.retries = cands, {}, 0
	self:read_next(w)
end

-- Reads (F4) -----------------------------------------------------------------------------------------------------

-- The next address of the window or of its retry. F4's re-check comes here, before the read that may accept: the
-- model moves before it answers (section 2.2), so this is the moment of accepting. A Use Selected Fan click under
-- way, or a phase the model no longer finds offline-like, is the model's "busy".
function Follower:read_next(w)
	if self.window ~= w or self.stopped then
		return
	end
	local address = table.remove(w.queue, 1)
	if address == nil then
		self:reads_done(w)
		return
	end
	local why = self:blocked(self:model_phase())
	if why then
		self:say("debug", "Follow: %s not read (%s)", address, why)
		self:disarm()
		return
	end
	-- F4: an edit or a Use Selected Fan click since the window opened drops its candidates and their retries; the
	-- ladder goes on.
	if self.edits ~= w.edits then
		self:say("debug", "Follow: %s not read (the owner acted since window %d opened)", address, w.n)
		w.queue, w.unverified = {}, {}
		self:reads_done(w)
		return
	end
	if not self:guard_ok() then
		if not self.refusing then
			self.refusing = true
			local ok, err = pcall(self.o.on_refused)
			if not ok then
				self:say("error", "Follow: on_refused failed: %s", tostring(err))
			end
		end
		self:say("debug", "Follow: %s heard at %s; not followed, it moved %d times in an hour", tail(w.mac), address,
			follow.GUARD_MAX)
		w.queue, w.unverified = {}, {}
		self:reads_done(w)
		return
	end
	self.refusing = false
	self:say("debug", "Follow: %s heard at %s; reading it", tail(w.mac), address)
	local read = { w = w, address = address, done = false }
	local ok, err = pcall(self.o.follow, address, w.mac, function(result, args)
		self:read_done(read, result, args)
	end)
	if not ok then
		self:say("error", "Follow: the read of %s failed: %s", address, tostring(err))
		self:read_done(read, "no_answer", nil)
	end
end

function Follower:read_done(read, result, args)
	if read.done then
		return
	end
	read.done = true
	if self.stopped then
		return -- after OnDriverDestroyed nothing is written
	end
	local w = read.w
	if type(args) ~= "table" then
		args = {}
	end
	if result == "followed" then
		-- The model has moved already, so a disarm since (its own phase waiting, the switch) does not hide it: the
		-- row must say where the model is (ECA CA1). Only Fan Address typed since the window opened wins: the
		-- later Set over an earlier follow (F5; ECA CA2).
		if self.edits ~= w.edits then
			self:say("debug", "Follow: %s answered as the pinned fan, but Fan Address was typed since; not followed",
				read.address)
			return
		end
		self:followed(read, args)
		return
	end
	if self.window ~= w then
		return
	end
	if result == "not_same" then
		local other = args.client_id or args.other_client_id
		if type(other) == "string" and other ~= "" then
			self:say("debug", "Follow: %s answers as another fan (%s); not followed", read.address, tail(other))
		else
			self:say("debug", "Follow: %s is not the pinned fan; not followed", read.address)
		end
	elseif result == "busy" then
		-- What a busy model was not asked now is read again with the retries.
		self:say("debug", "Follow: %s not read now: the model is busy", read.address)
		w.unverified[#w.unverified + 1] = read.address
		for _, address in ipairs(w.queue) do
			w.unverified[#w.unverified + 1] = address
		end
		w.queue = {}
	else
		self:say("debug", "Follow: %s did not answer as the pinned fan (%s)", read.address, printable(result))
		w.unverified[#w.unverified + 1] = read.address
	end
	self:read_next(w)
end

-- A follow: counted for the guard, the ladder disarmed, then the driver told (F6).
function Follower:followed(read, args)
	local address = type(args.address) == "string" and args.address or read.address
	local was = args.was
	if was == nil then
		was = read.w.current
	end
	self.follows[#self.follows + 1] = self:now()
	self:say("debug", "Follow: followed %s to %s (was %s)", tail(read.w.mac), printable(address), printable(was))
	self:disarm()
	local ok, err = pcall(self.o.on_followed, address, was)
	if not ok then
		self:say("error", "Follow: on_followed failed: %s", tostring(err))
	end
end

-- The reads of a window or a retry are over and nothing was followed. Candidates heard but not verified are read
-- again at +10, +30 and +90 s from the end of the window's reads, without a window; then the ladder goes on, its
-- next window no sooner than its step after the window closed.
function Follower:reads_done(w)
	if self.window ~= w or self.stopped then
		return
	end
	local now = self:now()
	if #w.unverified > 0 and w.retries < #follow.RETRY_AT_MS then
		w.t0 = w.t0 or now
		w.retries = w.retries + 1
		w.queue, w.unverified = w.unverified, {}
		local at = w.t0 + follow.RETRY_AT_MS[w.retries]
		self:say("debug", "Follow: reading %s again in %s", table.concat(w.queue, ", "), span(math.max(0, at - now)))
		if not self:schedule(at - now, function() self:read_next(w) end) then
			self:disarm()
		end
		return
	end
	local due = w.next_due
	if due < now then
		due = now
	end
	self:say("debug", "Follow: window %d in %s", self.step, span(self:not_before(due) - now))
	self:wait_window(due)
end

-- The interface (address-follow-design section 2.3) --------------------------------------------------------------

-- The model's listener.phase. Armed on an offline-like phase when F2's conditions hold; disarmed on any other
-- (online, waiting, unset, rebooting).
function Follower:phase_changed(phase)
	if self.stopped then
		return
	end
	local before = self.tracked
	self.tracked = phase
	if not follow.OFFLINE_LIKE[phase] then
		if self.armed then
			self:say("debug", "Follow: disarmed (%s)", tostring(phase))
		end
		self:disarm()
	elseif not self.armed then
		self:arm(phase)
	elseif before ~= phase then
		self:pull_forward()
	end
end

-- The owner typed Fan Address (F5): pending until a contact there succeeds, and disarmed.
function Follower:address_edited()
	if self.stopped then
		return
	end
	self.edits = self.edits + 1
	self.pending = true
	if self.armed then
		self:say("debug", "Follow: disarmed (Fan Address typed)")
	end
	self:disarm()
end

-- A Use Selected Fan click (F4): a window open now drops its candidates, as after an edit, but nothing is pending.
function Follower:clicked()
	if self.stopped then
		return
	end
	self.edits = self.edits + 1
end

-- A contact succeeded at the current address: the typed address has answered (F5).
function Follower:contact()
	if self.stopped then
		return
	end
	if self.pending then
		self:say("debug", "Follow: the typed address answered; following again")
	end
	self.pending = false
end

-- Follow Address Changes (F7): Off disarms; On arms at once when the phase is offline-like.
function Follower:switch(on)
	if self.stopped then
		return
	end
	local want = on == true or (type(on) == "string" and on:lower() == "on")
	self.switched = want
	if not want then
		if self.armed then
			self:say("debug", "Follow: disarmed (switched Off)")
		end
		self:disarm()
	elseif not self.armed then
		self:arm(self:model_phase())
	end
end

-- Dev State: "off", "pending", "armed:N" (N the window due or under way) or "idle".
function Follower:state()
	if self.stopped or not self:switched_on() then
		return "off"
	elseif self.pending then
		return "pending"
	elseif self.armed then
		return "armed:" .. tostring(self.step)
	end
	return "idle"
end

-- OnDriverDestroyed: the timer cancelled; nothing runs, arms or reports after it (ECA E8: timers die there).
function Follower:stop()
	self:disarm()
	self.stopped = true
end

return follow
