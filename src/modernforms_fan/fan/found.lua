-- fan/found.lua: the fans heard, kept across search windows (#102). The contract is docs/auto-discovery-design.md:
-- section 3 (the list), section 4 (the kept pick) and section 6.2 (this interface); where it is silent,
-- docs/auto-discovery-research.md 4.3.3 and 4.3.5, then docs/edge-cases-discovery.md 4.3 and 4.4.
--
-- Every window that closes feeds it, whoever opened it (the scheduler of fan/search.lua or the follower of
-- fan/follow.lua; AD6): the driver's on_window hands over the window's heard list and its error word. One key per
-- fan: the 12 hex digits of its MAC in lower case, or "i:" and its instance in lower case when the answer has no
-- usable MAC. A key keeps the instance, the MAC and the address of its latest answer, and when it was last heard.
-- A key goes after `misses` (3) windows in a row that sent their query without hearing it; a window with an error
-- word ages nothing and makes failing() true until a window sends again; the kept pick never ages out while it is
-- kept. A window's answers count even when it carries an error word (Finder:find gives none then; an answer is an
-- answer), and within one window the last answer of a key is its latest.
--
-- Pure like fan/discovery.lua: nothing here touches Director. Every option is called through pcall, so one that is
-- missing or raises lands on a refusal (no usable entry, no time, no log line), and nothing raises from here:
--
--   found.new({
--       usable = fn(entry) -> bool,   -- discovery.usable: SRV port 80, a private or link-local IPv4 address
--       now = fn() -> s,              -- when a key was last heard
--       log = common/log.lua,         -- always (the list changed) and warn (a failing streak began)
--       misses = 3,                   -- sending windows in a row without a key before it goes
--   })
--   l:window(heard, err) -> changed   -- true when the keys, an address, an instance or failing() changed, and
--                                     -- for the first window of a run (the summary leaves "Looking...")
--   l:entries(pin_mac) -> { { key, instance, address, mac, own, last_heard }, ... }   -- section 3's order
--   l:failing(), l:heard_once(), l:get(key), l:keep(key), l:kept(), l:drop(), l:clear()
--   found.key(entry) -> key or nil
--
-- A returned entry is a copy: `mac` is 12 upper-case hex digits as discovery and the model write a MAC (nil for an
-- "i:" key), `own` (entries only) says it is the pinned MAC. What this module does not do: word or write a row
-- (texts.found_rows and the driver do), cap the rows (texts.MAX_FOUND does), read, pin, rename or adopt a fan, or
-- persist anything (AD1, AD9). The follower never acts on this list (AD10).
--
-- Lua 5.1: no goto, no integer division, no bit operators.

local found = {}

found.MISSES = 3 -- section 3: sending windows in a row without a key before it goes

-- Helpers -----------------------------------------------------------------------------------------------------

-- Linear: a pattern anchored at the end rescans a long inner run of blanks from every start, and this text comes
-- off the network.
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

-- 12 lower-case hex digits, by the rule of wire.mac12 (white space trimmed, then 12 hex digits, or six pairs joined
-- by one and the same ":" or "-"), kept here so this module needs no other. nil for anything else.
local function mac_lower(text)
	-- A MAC is at most 17 characters; anything much longer is refused before the trim.
	if type(text) ~= "string" or #text > 64 then
		return nil
	end
	local mac = trim(text)
	if mac:find("^%x%x%x%x%x%x%x%x%x%x%x%x$") then
		return mac:lower()
	end
	local a, _, b, c, d, e, f = mac:match("^(%x%x)([:%-])(%x%x)%2(%x%x)%2(%x%x)%2(%x%x)%2(%x%x)$")
	if not a then
		return nil
	end
	return (a .. b .. c .. d .. e .. f):lower()
end

local function is_mac_key(key)
	return key:sub(1, 2) ~= "i:"
end

-- found.key(entry) -> key or nil: the entry's MAC as 12 lower-case hex digits, else "i:" .. its instance in lower
-- case, else nil (no MAC and no instance, or not a record).
function found.key(entry)
	if type(entry) ~= "table" then
		return nil
	end
	local mac = mac_lower(entry.mac)
	if mac then
		return mac
	end
	local instance = entry.instance
	if type(instance) == "string" and instance ~= "" then
		return "i:" .. instance:lower()
	end
	return nil
end

-- An address in the order section 3 wants: a dotted quad by its numbers (so .9 comes before .10), anything else
-- after every quad, by its text.
local function address_order(address)
	local a, b, c, d = address:match("^(%d%d?%d?)%.(%d%d?%d?)%.(%d%d?%d?)%.(%d%d?%d?)$")
	if a then
		return string.format("0%03d.%03d.%03d.%03d", tonumber(a), tonumber(b), tonumber(c), tonumber(d))
	end
	return "1" .. address
end

-- Own first, then the instance case-blind, then the address, then the key: keys are unique, so the order is total
-- and the same fans give the same order from window to window.
local function earlier(x, y)
	if x.own ~= y.own then
		return x.own
	elseif x.instance ~= y.instance then
		return x.instance < y.instance
	elseif x.address ~= y.address then
		return x.address < y.address
	end
	return x.key < y.key
end

-- "...5301": an id in the log shows its last four characters only (docs/v1-design.md section 3.7); an "i:" key
-- shows its instance's, which ends in the MAC's last digits on every known layout.
local function tail(e)
	return "..." .. (e.mac or e.instance or "????"):sub(-4)
end

local function fans(n)
	return n == 1 and "1 fan" or string.format("%d fans", n)
end

-- The instance -------------------------------------------------------------------------------------------------

local List = {}
List.__index = List

-- Calls no option: building the list sends, reads and logs nothing.
function found.new(opts)
	opts = type(opts) == "table" and opts or {}
	local misses = tonumber(opts.misses)
	if not (misses and misses >= 1 and misses < math.huge) then
		misses = found.MISSES
	end
	local l = setmetatable({ o = opts, misses = math.floor(misses), last_now = nil }, List)
	l:clear()
	return l
end

-- l:clear(): a fresh run: no key, no pick, not failing, no window heard, no log line written.
function List:clear()
	self.map = {}          -- key -> { key, instance, address, mac, misses, heard }
	self.pick = nil        -- the kept pick's key (section 4)
	self.failing_ = false  -- the last window could not open or send
	self.closed = false    -- a window has closed in this run
	self.said = nil        -- the keys and addresses the last "Found Fans:" line named
end

function List:say(level, fmt, ...)
	local log = self.o.log
	pcall(function(...)
		log[level](fmt, ...)
	end, ...)
end

function List:usable(entry)
	local ok, yes = pcall(self.o.usable, entry)
	return ok and yes == true
end

-- The time now; the last good one (or nil) when now() fails.
function List:now()
	local ok, t = pcall(self.o.now)
	if ok and type(t) == "number" and t == t then
		self.last_now = t
	end
	return self.last_now
end

-- A copy for the caller, so nothing it does reaches the list.
local function copy(e)
	return { key = e.key, instance = e.instance, address = e.address, mac = e.mac, last_heard = e.heard }
end

-- What changed() compares: each key's address and instance.
function List:snapshot()
	local shot = {}
	for key, e in pairs(self.map) do
		shot[key] = e.address .. "\0" .. (e.instance or "")
	end
	return shot
end

local function same(a, b)
	for key, value in pairs(a) do
		if b[key] ~= value then
			return false
		end
	end
	for key in pairs(b) do
		if a[key] == nil then
			return false
		end
	end
	return true
end

-- What the "Found Fans:" line names, as one comparable string: the keys and their addresses.
function List:signature()
	local parts = {}
	for key, e in pairs(self.map) do
		parts[#parts + 1] = key .. "=" .. e.address
	end
	table.sort(parts)
	return table.concat(parts, ",")
end

-- "Found Fans: 2 fans (...5301 at 10.0.2.151, ...5302 at 10.0.2.152)", or "Found Fans: no fan answered".
function List:line()
	local list = self:entries(nil)
	if #list == 0 then
		return "Found Fans: no fan answered"
	end
	local parts = {}
	for i, e in ipairs(list) do
		parts[i] = tail(e) .. " at " .. e.address
	end
	return string.format("Found Fans: %s (%s)", fans(#list), table.concat(parts, ", "))
end

-- l:window(heard, err) -> changed: one closed window, its heard list ({ instance, address, mac, port } each, as
-- Finder:find gives it) and its error word (nil when the query went out). Only records for which usable() says
-- true and that have a key and an address count. Writes the log lines of section 3.
function List:window(heard, err)
	local failed = err ~= nil and err ~= false
	local before = self:snapshot()
	local was_failing, was_closed = self.failing_, self.closed

	-- This window's answers: the last one of each key is its latest.
	local hits = {}
	if type(heard) == "table" then
		for _, entry in ipairs(heard) do
			if type(entry) == "table" and type(entry.address) == "string" and entry.address ~= "" then
				local key = found.key(entry)
				if key and self:usable(entry) then
					hits[key] = entry
				end
			end
		end
	end

	local stamp = next(hits) ~= nil and self:now() or nil
	for key, entry in pairs(hits) do
		local e = self.map[key]
		if not e then
			e = { key = key, mac = is_mac_key(key) and key:upper() or nil }
			self.map[key] = e
		end
		if type(entry.instance) == "string" and entry.instance ~= "" then
			e.instance = entry.instance
		end
		e.address = entry.address
		e.misses = 0
		e.heard = stamp
	end

	if failed then
		if not self.failing_ then
			self:say("warn", "Search: the query could not be sent on this controller")
		end
		self.failing_ = true
	else
		self.failing_ = false
		-- Assigning nil to a field during pairs is allowed (Lua 5.1 manual, next).
		for key, e in pairs(self.map) do
			if not hits[key] then
				e.misses = e.misses + 1
				if e.misses >= self.misses and key ~= self.pick then
					self.map[key] = nil
				end
			end
		end
		local said = self:signature()
		if said ~= self.said then
			self.said = said
			self:say("always", "%s", self:line())
		end
	end
	self.closed = true

	return not was_closed or was_failing ~= self.failing_ or not same(before, self:snapshot())
end

-- l:entries(pin_mac) -> every key, as copies, in section 3's order: the pinned MAC's first (own = true; a MAC in any
-- spelling mac12 reads), then by instance case-blind, then by address, then by key.
function List:entries(pin_mac)
	local pin = mac_lower(pin_mac)
	local rows = {}
	for key, e in pairs(self.map) do
		rows[#rows + 1] = {
			own = pin ~= nil and key == pin,
			instance = (e.instance or ""):lower(),
			address = address_order(e.address),
			key = key,
			entry = e,
		}
	end
	table.sort(rows, earlier)
	local out = {}
	for i, row in ipairs(rows) do
		local c = copy(row.entry)
		c.own = row.own
		out[i] = c
	end
	return out
end

-- l:failing() -> bool: the last window could not open or send (until a window sends again).
function List:failing()
	return self.failing_
end

-- l:heard_once() -> bool: a window has closed in this run (until then the summary reads "Looking...").
function List:heard_once()
	return self.closed
end

-- l:get(key) -> a copy of the key's entry, or nil.
function List:get(key)
	local e = type(key) == "string" and self.map[key] or nil
	return e and copy(e) or nil
end

-- l:keep(key) -> the entry, or nil: the waiting pick (section 4, step 4). A key that is not listed is not kept
-- and leaves the pick as it was.
function List:keep(key)
	local e = type(key) == "string" and self.map[key] or nil
	if not e then
		return nil
	end
	self.pick = key
	return copy(e)
end

-- l:kept() -> the kept pick's entry, at its latest address, or nil.
function List:kept()
	local e = self.pick and self.map[self.pick] or nil
	return e and copy(e) or nil
end

-- l:drop(): no pick waits any more; its key ages again from the next window that sends.
function List:drop()
	self.pick = nil
end

return found
