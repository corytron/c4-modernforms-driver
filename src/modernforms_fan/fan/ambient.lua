-- fan/ambient.lua: whether the bound keypad's LEDs are dark, from its ambient light readings (#207). The contract is
-- docs/ambient-pause-design.md: what the house probe measured (section 0, AP1 to AP5), AP-D2 to AP-D5 and this
-- module's interface (section 2); the reasons are docs/edge-cases-led-dimming.md (DM15, DM48, DM61, DM72 to DM74).
--
-- A keypad dimmer's Ambient Light Level (Source), bound to the fan's Ambient Light Level (Follower), sends the
-- command AMBIENT_LIGHT_LEVEL with GROUP (its device id), LEVEL (its reading, 0 to 255) and TARGET (unused), on
-- change only (AP1, AP2). The keypad is dark while its last reading is below the threshold, the property Pause LED
-- Animations Below (AP-D2). Only dark pauses the LED animations: unknown runs them as today (fail-open, DM72).
--
--   unknown   at construction, after a bind and after an unbind, until a reading counts. dark() is false.
--   lit       the last counted reading is at or above the threshold.
--   dark      a counted reading was below the threshold, and nothing has resumed since. dark() is true.
--
-- Going dark is at once: a counted reading below the threshold makes the state dark and cancels the lit hold.
-- Going lit from dark is held (AP-D3, DM15): a counted reading at or above the threshold arms one hold of
-- LIT_HOLD_MS; further lit readings leave it running, so it is timed from the first of them. When it fires with no
-- dark reading since, the state is lit. A flicker therefore pauses once and resumes once. From unknown a lit
-- reading makes the state lit at once (dark() was false and stays false).
--
-- The threshold (set_threshold): a number, or a numeric string, rounded half up; anything that is not a number, or
-- that rounds to outside 0 to 255, is the default 10. 0 never makes the state dark (no reading is below 0). A new
-- threshold applies to the last counted reading at once: below it, the state is dark (a hold is cancelled); at or
-- above it while dark, the hold arms (the hold still applies to resuming). While unknown it changes nothing.
--
-- Readings that count (AP-D4), checked in this order; each one ignored is logged at debug with its reason:
--   1. LEVEL is a whole number 0 to 255: a number with no fraction, or a string of decimal digits (spaces around
--      allowed). Decided: a fraction is rejected, not rounded. The keypad sends whole numbers (AP1), so "3.5" is not
--      a reading this module understands, and rounding it could tip the dark or lit verdict at the threshold.
--      Rejected too: "abc", "-1", "256", "3.0" (text), "1e2", "0x10", "+3", "", a missing LEVEL.
--   2. GROUP, when both it and the bound device id are known, is the bound device: a reading from another device
--      is ignored. Ids compare as text, a whole number written without a fraction ("123" and 123 are the same).
--   3. The first reading after a bind that passes 1 and 2 is ignored when it comes within BIND_SETTLE_MS of the
--      bind (inclusive), or when either time is unknown (no clock): the house keypad's first message after a bind
--      read LEVEL 0 (AP3). Only that first one: later readings in the window count, and a first one later than the
--      window counts. A bad LEVEL or another device's reading does not use the skip up.
-- A reading while unbound counts (Director may deliver it before OnBindingChanged after a restart): it is taken
-- as from a bound keypad whose id is unknown, so GROUP is not checked and nothing is skipped.
--
-- bound(id) is a bind: the id (nil when it is not a number or non-empty text, and then GROUP is not checked) and
-- the bind time are kept, the state is unknown, the hold is cancelled and the last reading forgotten. bound(nil)
-- (or false) is an unbind: the same, with no id and no bind time. Either calls on_change(false, "bound") or
-- on_change(false, "unbound") when the state was dark.
--
-- on_change(dark, why) is called only when dark() changes, never at construction, always in pcall (a failure is
-- logged at warn and changes nothing). why is one English phrase: "keypad dark (reading 3 < 10)", "keypad lit again
-- (reading 14 >= 10, held 10 s)", "bound" or "unbound". The state has changed before it is called.
--
-- The timer: one one-shot timer at a time, the hold; every re-arm and cancel bumps a generation, so a callback of a
-- cancelled timer is ignored. A hold that cannot be armed resumes at once with a warning (fail-open, as unknown
-- runs the animations, DM72). stop() cancels it and is final: every later call is ignored, dark(), state() and
-- debug() still answer.
--
-- No persistence and no polling (AP-D5, DM48, DM61): after a restart the state is unknown until the keypad's next
-- change, and there is no staleness rule, because silence means "no change" (AP2).
--
--   local a = ambient.new({ now = fn() -> ms, timer = fn(ms, cb) -> handle with :Cancel(),
--       on_change = fn(dark, why), log = { debug, warn } })   -- log: default common.log
--   a:set_threshold(n); a:bound(device_id_or_nil); a:reading(params)   -- params: GROUP, LEVEL, TARGET
--   a:dark() -> bool; a:state() -> "unknown" | "lit" | "dark"; a:stop()
--   a:debug() -> { state, level, threshold, bound, since_bind_ms, hold }
--
-- Pure: no Director calls, no globals. Lua 5.1: no goto, no integer division, no bit operators.

local ambient = {}

ambient.LIT_HOLD_MS = 10000 -- AP-D3, DM15
ambient.BIND_SETTLE_MS = 5000 -- AP-D4, AP3
ambient.DEFAULT_THRESHOLD = 10 -- AP-D2
ambient.MAX_LEVEL = 255 -- AP1: the keypad's Ambient Light Profile scale

local Ambient = {}
Ambient.__index = Ambient

-- Helpers ----------------------------------------------------------------------------------------------------

-- fn(...) in pcall; a function that is not there fails like one that raises.
local function try(fn, ...)
	if type(fn) ~= "function" then
		return false, "not given"
	end
	return pcall(fn, ...)
end

local function finite(n)
	return type(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge
end

-- A finite number from a number or a numeric string, else nil.
local function number_of(value)
	local n = tonumber(value)
	if not finite(n) then
		return nil
	end
	return n
end

local function round(n)
	return math.floor(n + 0.5)
end

-- The threshold: rounded half up, within 0 to MAX_LEVEL, else the default.
local function threshold_of(value)
	local n = number_of(value)
	if n == nil then
		return ambient.DEFAULT_THRESHOLD
	end
	n = round(n)
	if n < 0 or n > ambient.MAX_LEVEL then
		return ambient.DEFAULT_THRESHOLD
	end
	return n
end

-- A reading: a whole number 0 to MAX_LEVEL, from a number or a string of decimal digits; else nil.
local function level_of(value)
	local n
	if type(value) == "number" then
		n = value
	elseif type(value) == "string" then
		local digits = value:match("^%s*(%d+)%s*$")
		n = digits and tonumber(digits) or nil
	end
	if not finite(n) or n ~= math.floor(n) or n < 0 or n > ambient.MAX_LEVEL then
		return nil
	end
	return n
end

-- A device id as text, for comparing: a whole number without its fraction, other text trimmed; nil when unknown.
local function id_of(value)
	local n
	if type(value) == "number" then
		n = value
	elseif type(value) == "string" then
		local text = value:match("^%s*(.-)%s*$")
		if text == "" then
			return nil
		end
		n = text:match("^%d+$") and tonumber(text) or nil
		if n == nil then
			return text
		end
	end
	if not finite(n) then
		return nil
	end
	if n == math.floor(n) then
		return string.format("%.0f", n)
	end
	return tostring(n)
end

-- A value for a log line: short, and never raising.
local function shown(value)
	local text = type(value) == "string" and string.format("%q", value) or tostring(value)
	if #text > 40 then
		text = text:sub(1, 37) .. "..."
	end
	return text
end

-- The hold, read when it arms: LIT_HOLD_MS, whole and at least 1 ms.
local function hold_ms()
	return math.max(1, round(number_of(ambient.LIT_HOLD_MS) or 0))
end

local function seconds(ms)
	return string.format("%g s", ms / 1000)
end

-- The instance -----------------------------------------------------------------------------------------------

function ambient.new(opts)
	opts = type(opts) == "table" and opts or {}
	return setmetatable({
		o = opts,
		log = opts.log or require("common.log"),
		threshold = ambient.DEFAULT_THRESHOLD,
		st = "unknown",
		level = nil, -- the last counted reading since the last bind or unbind
		bound_given = nil, -- the id as bound() was given it, for debug()
		bound_id = nil, -- the id as text, for comparing with GROUP; nil: unknown (GROUP not checked)
		bind_at = nil, -- the clock at the last bind
		settling = false, -- true from a bind until its first reading that passes LEVEL and GROUP
		-- the hold
		handle = nil,
		armed = false,
		gen = 0, -- bumped by every cancel: a callback of an older arm is ignored
		stopped = false,
	}, Ambient)
end

function Ambient:say(level, template, ...)
	local sink = self.log
	local fn = type(sink) == "table" and sink[level] or nil
	if type(fn) ~= "function" then
		return
	end
	local ok, text = pcall(string.format, template, ...)
	pcall(fn, "%s", "Ambient light: " .. (ok and text or tostring(template)))
end

function Ambient:clock()
	if self.o.now == nil then
		return nil
	end
	local ok, t = try(self.o.now)
	if not ok then
		self:say("warn", "the clock failed: %s", tostring(t))
		return nil
	end
	return number_of(t)
end

-- Milliseconds since the last bind, or nil (no bind, or no clock at the bind or now).
function Ambient:since_bind()
	if self.bind_at == nil then
		return nil
	end
	local c = self:clock()
	if c == nil then
		return nil
	end
	return c - self.bind_at
end

-- on_change in pcall, only when given; a failure is logged at warn.
function Ambient:notify(dark, why)
	local fn = self.o.on_change
	if fn == nil then
		return
	end
	local ok, err = try(fn, dark, why)
	if not ok then
		self:say("warn", "on_change(%s) failed: %s", tostring(dark), tostring(err))
	end
end

-- The hold timer ---------------------------------------------------------------------------------------------

function Ambient:cancel()
	self.gen = self.gen + 1
	self.armed = false
	local handle = self.handle
	self.handle = nil
	if handle ~= nil then
		local ok, err = pcall(function() handle:Cancel() end)
		if not ok then
			self:say("warn", "the hold timer could not be cancelled: %s", tostring(err))
		end
	end
end

-- One hold of LIT_HOLD_MS; true when it is armed (or already fired, for a timer that calls back at once).
function Ambient:arm(ms)
	self:cancel()
	local gen = self.gen
	self.armed = true
	local ok, handle = try(self.o.timer, ms, function() self:fire(gen) end)
	if not ok then
		self.armed = false
		self:say("warn", "the hold timer could not be armed (%d ms): %s", ms, tostring(handle))
		return false
	end
	if self.armed and self.gen == gen then
		self.handle = handle
	end
	return true
end

function Ambient:fire(gen)
	if self.stopped or gen ~= self.gen then
		return
	end
	self.handle, self.armed = nil, false
	if self.st ~= "dark" or self.level == nil or self.level < self.threshold then
		return -- a dark verdict cancels the hold, so this is not reached; nothing to resume
	end
	self:go_lit(string.format("keypad lit again (reading %d >= %d, held %s)", self.level, self.threshold,
		seconds(hold_ms())))
end

-- State changes ----------------------------------------------------------------------------------------------

function Ambient:go_dark(reason)
	if self.armed then
		self:cancel()
		self:say("debug", "the resume hold is cancelled (%s)", reason)
	end
	if self.st == "dark" then
		return
	end
	self.st = "dark"
	local why = "keypad dark (" .. reason .. ")"
	self:say("debug", "%s", why)
	self:notify(true, why)
end

function Ambient:go_lit(why)
	local was_dark = self.st == "dark"
	self.st = "lit"
	self:say("debug", "%s", why)
	if was_dark then
		self:notify(false, why)
	end
end

-- While dark with a reading at or above the threshold: one hold, timed from the first such reading.
function Ambient:hold_lit()
	if self.armed then
		self:say("debug", "reading %d >= %d: the resume hold goes on", self.level, self.threshold)
		return
	end
	local ms = hold_ms()
	if self:arm(ms) then
		if self.armed then
			self:say("debug", "reading %d >= %d: lit again in %s unless a reading below %d comes", self.level,
				self.threshold, seconds(ms), self.threshold)
		end
		return
	end
	self:go_lit(string.format("keypad lit again (reading %d >= %d, at once: the hold could not be armed)",
		self.level, self.threshold))
end

-- The last counted reading against the threshold.
function Ambient:judge(note)
	local level, threshold = self.level, self.threshold
	if level == nil then
		return
	end
	if level < threshold then
		self:go_dark(string.format("reading %d < %d%s", level, threshold, note or ""))
	elseif self.st == "dark" then
		self:hold_lit()
	elseif self.st == "unknown" then
		self:go_lit(string.format("keypad lit (reading %d >= %d)", level, threshold))
	end
end

-- The interface ----------------------------------------------------------------------------------------------

function Ambient:set_threshold(n)
	if self.stopped then
		return
	end
	local threshold = threshold_of(n)
	if threshold == self.threshold then
		return
	end
	self:say("debug", "threshold %d -> %d", self.threshold, threshold)
	self.threshold = threshold
	self:judge(", the threshold changed")
end

function Ambient:bound(id)
	if self.stopped then
		return
	end
	local was_dark = self.st == "dark"
	self:cancel()
	self.st, self.level = "unknown", nil
	local why
	if id == nil or id == false then
		self.bound_given, self.bound_id, self.bind_at, self.settling = nil, nil, nil, false
		why = "unbound"
		self:say("debug", "unbound: the keypad state is unknown, the animations run")
	else
		self.bound_given, self.bound_id = id, id_of(id)
		self.bind_at, self.settling = self:clock(), true
		why = "bound"
		self:say("debug", "bound to device %s: the keypad state is unknown until a reading counts", shown(id))
	end
	if was_dark then
		self:notify(false, why)
	end
end

function Ambient:ignore(template, ...)
	local ok, text = pcall(string.format, template, ...)
	self:say("debug", "reading ignored: %s", ok and text or tostring(template))
end

function Ambient:reading(params)
	if self.stopped then
		return
	end
	if type(params) ~= "table" then
		self:ignore("the parameters are not a table (%s)", shown(params))
		return
	end
	local level = level_of(params.LEVEL)
	if level == nil then
		self:ignore("LEVEL %s is not a whole number 0 to %d", shown(params.LEVEL), ambient.MAX_LEVEL)
		return
	end
	local group = id_of(params.GROUP)
	if group ~= nil and self.bound_id ~= nil and group ~= self.bound_id then
		self:ignore("%d from device %s, not the bound device %s", level, group, self.bound_id)
		return
	end
	if self.settling then
		self.settling = false
		local since = self:since_bind()
		if since == nil or since <= ambient.BIND_SETTLE_MS then
			self:ignore("%d is the first after the bind (%s ms after it), not a reading (AP3)", level,
				since == nil and "unknown" or string.format("%.0f", since))
			return
		end
	end
	self:say("debug", "reading %d counted (threshold %d, state %s)", level, self.threshold, self.st)
	self.level = level
	self:judge()
end

function Ambient:dark()
	return self.st == "dark"
end

function Ambient:state()
	return self.st
end

function Ambient:stop()
	if self.stopped then
		return
	end
	self:cancel()
	self.stopped = true
end

function Ambient:debug()
	return {
		state = self.st,
		level = self.level,
		threshold = self.threshold,
		bound = self.bound_given,
		since_bind_ms = self:since_bind(),
		hold = self.armed,
	}
end

return ambient
