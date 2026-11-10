-- fan/ledrows.lua: the keypad LED rows shown only while a keypad can use them (#178). The contract is
-- docs/keypad-leds-visibility-design.md: decisions KL-D1 to KL-D10 and this module's interface (section 2.1); the
-- reasons are docs/edge-cases-keypad-leds-visibility.md (KF1 onward, KV1 to KV48) and
-- docs/keypad-leds-visibility-sdk-research.md.
--
-- The rows (KL-D1): the 20 rows of ROWS, in driver.xml order. `Keypad Links` is never one of them.
--
-- The gate (KL-D2): the rows are shown while at least one device is bound to a fan speed link 301 to 306
-- (`speed_bound`), whatever the device. Breeze (KL-D3): the three rows of BREEZE also need a fan that has Breeze;
-- they are hidden while `has_breeze` is false and follow the gate alone while it is true or nil (not known yet).
--
-- Show at once, hide late (KL-D4): a change that shows rows is applied at once; a change that closes the gate arms
-- one HIDE_MS timer, and the rows hide only when "nothing bound" has held that long without a break. An update that
-- reopens the gate cancels it; any other update leaves it running from where it was armed.
--
-- How (KL-D6): an apply records every row's state and sends it SEND_MS[1] = 400 ms later and again SEND_MS[2] =
-- 1,500 ms after the apply, through set_hidden(name, hidden) (the driver's C4:SetPropertyAttribs, 1 hides, 0 shows).
-- Every send carries all 20 rows, changed or not, in ROWS order, so a dropped send heals at the next one. A new
-- apply cancels the sends still pending from the one before and starts its own two; a send reads the state as
-- applied when it goes out. The 400 ms keep the sends clear of the row texts the driver writes in the same moment
-- (`changed` is called right after the apply), which Composer dropped visibility changes next to (KF4).
--
-- Display only (KL-D5): nothing here writes a value, talks to a keypad or touches an animation.
--
-- Choices where the contract is silent (each covered by tests/spec/ledrows_spec.lua):
--   * Late init fails open (KV1, KV21, KL-D4's "second look at start is 5 s"): the rows are shown from the moment
--     the device is added (KF3), and start() applies the gate open whatever the first read said; with nothing bound
--     it arms the HIDE_MS timer at once, so a keypad-less fan's rows hide HIDE_MS after late init and a first read
--     that missed the keypad (one nil read may be wrong, KF10) never hides the house's rows.
--   * changed(shown, cause) is called whenever an apply after start() moves the gate: cause "binding" for a bind
--     or unbind (the driver writes L44 or L45, KL-D7), cause "start" when the hide armed by start() fires (KV1: no
--     Last Action line, but the `Keypad Links` suffix must be rewritten). Never for start() itself or for a Breeze
--     change.
--   * has_breeze alone (KV26: the fan's info, read rarely, never re-read the way bindings are): its change shows or
--     hides the three Breeze rows at once, both sends, no `changed`. While the gate is closed or closing it is only
--     recorded; the rows follow it when the gate next opens or the hide applies.
--   * update{} is the whole view each time: a missing or non-true `speed_bound` reads as false, a `has_breeze` that
--     is neither true nor false as nil.
--   * stop() is final: every later call is ignored. A second start() sends the applied state again (both sends).
--   * A timer that cannot be armed: a send goes out at once (and the next is tried); a hide is not armed, so the
--     rows stay shown (fail open) until the inputs change again. Both are warned.
--   * A callback of a cancelled timer is ignored (a generation per timer), so a Cancel that raises is harmless.
--   * shown() before start() is true: the rows as driver.xml shows them.
--
-- Pure like fan/speedleds.lua: nothing here touches Director, no globals. Every option is called through pcall
-- (try); a failure is logged at warn and the module goes on:
--
--   local r = ledrows.new({ set_hidden = fn(name, hidden), timer = fn(ms, cb) -> handle (handle:Cancel()),
--       now = fn() -> ms, changed = fn(shown, cause), log = { debug, info, warn } })
--   r:start(); r:update({ speed_bound = bool, has_breeze = true | false | nil }); r:shown() -> bool
--   r:stop(); r:debug() -> table
--
-- Lua 5.1: no goto, no integer division, no bit operators.

local ledrows = {}

-- KL-D1: the managed rows, in driver.xml order (tests/spec/ledrows_spec.lua checks it against the file).
ledrows.ROWS = {
	"Speed 1 Link Also Lit At",
	"Speed 2 Link Also Lit At",
	"Speed 3 Link Also Lit At",
	"Speed 4 Link Also Lit At",
	"Speed 5 Link Also Lit At",
	"Speed 6 Link Also Lit At",
	"Speed LED Colors",
	"Speed 1 LED Color",
	"Speed 2 LED Color",
	"Speed 3 LED Color",
	"Speed 4 LED Color",
	"Speed 5 LED Color",
	"Speed 6 LED Color",
	"Speed LED Off Color",
	"Breeze LED Animation",
	"Breeze LED Bottom",
	"Breeze LED Step (ms)",
	"Breeze LED Night Brightness (%)",
	"Speed LED Animation",
	"Speed LED Rest (s)",
}

-- KL-D3: the rows only Breeze uses (`Breeze LED Bottom` also orders the chase and follows the gate alone).
ledrows.BREEZE = {
	["Breeze LED Animation"] = true,
	["Breeze LED Step (ms)"] = true,
	["Breeze LED Night Brightness (%)"] = true,
}

ledrows.HIDE_MS = 8000 -- KL-D4
ledrows.SEND_MS = { 400, 1500 } -- KL-D6: after the apply

local Rows = {}
Rows.__index = Rows

-- fn(...) in pcall; a function that is not there fails like one that raises.
local function try(fn, ...)
	if type(fn) ~= "function" then
		return false, "not given"
	end
	return pcall(fn, ...)
end

-- handle:Cancel() in pcall; no handle is nothing to cancel.
local function cancel(handle)
	if handle == nil then
		return true
	end
	return pcall(function()
		handle:Cancel()
	end)
end

-- What the rows show for a gate and a Breeze flag, as one word: two of them differ when any row would change.
local function picture(gate, breeze)
	if not gate then
		return "none"
	end
	return breeze and "all" or "all but Breeze"
end

function ledrows.new(opts)
	opts = type(opts) == "table" and opts or {}
	return setmetatable({
		o = opts,
		log = opts.log or require("common.log"),
		-- the inputs as last recorded (update)
		speed_bound = false,
		has_breeze = nil,
		-- the rows as applied: the gate open, as driver.xml shows every row (KF3) and late init fails open (KV21)
		gate = true,
		breeze = true, -- the Breeze rows' own flag (has_breeze ~= false when applied)
		started = false,
		stopped = false,
		-- the sends (KL-D6)
		send_handle = nil,
		send_gen = 0, -- bumped by every cancel: a callback of an older chain is ignored
		send_next = nil, -- the send pending (1 or 2), nil when none
		-- the hide (KL-D4)
		hide_armed = false,
		hide_handle = nil,
		hide_gen = 0,
		hide_cause = nil, -- "start" or "binding"
		hide_since = nil, -- now() when it was armed
		-- counts for debug()
		applies = 0,
		sends = 0,
		failures = 0,
	}, Rows)
end

function Rows:say(level, template, ...)
	local sink = self.log
	local fn = type(sink) == "table" and sink[level] or nil
	if type(fn) ~= "function" then
		return
	end
	local ok, text = pcall(string.format, template, ...)
	pcall(fn, "%s", "Keypad LED rows: " .. (ok and text or tostring(template)))
end

-- now() as a finite number, else nil (debug only: nothing here depends on the clock).
function Rows:clock()
	local ok, value = try(self.o.now)
	local n = ok and tonumber(value) or nil
	if n == nil or n ~= n or n == math.huge or n == -math.huge then
		return nil
	end
	return n
end

-- A row's state as applied (KL-D2, KL-D3).
function Rows:hidden(name)
	return not self.gate or (ledrows.BREEZE[name] == true and not self.breeze)
end

-- One send (KL-D6): every row, in ROWS order, a failing row logged and the rest sent.
function Rows:send(k)
	local failed, first, hidden = 0, nil, 0
	for _, name in ipairs(ledrows.ROWS) do
		local hide = self:hidden(name)
		if hide then
			hidden = hidden + 1
		end
		local ok, err = try(self.o.set_hidden, name, hide)
		if not ok then
			failed = failed + 1
			first = first or string.format("%s: %s", name, tostring(err))
		end
	end
	self.sends = self.sends + 1
	if failed > 0 then
		self.failures = self.failures + failed
		self:say("warn", "send %d: %d of %d rows could not be set (%s)", k, failed, #ledrows.ROWS, first)
	else
		self:say("debug", "send %d: %d shown, %d hidden", k, #ledrows.ROWS - hidden, hidden)
	end
end

-- Arms send k of the chain `gen`, SEND_MS[k] after the apply; without a timer it goes out at once.
function Rows:arm_send(k, gen)
	local at = ledrows.SEND_MS[k]
	self.send_handle, self.send_next = nil, nil
	if at == nil then
		return
	end
	local ms = math.max(1, at - (ledrows.SEND_MS[k - 1] or 0))
	local ok, handle = try(self.o.timer, ms, function()
		self:fire_send(k, gen)
	end)
	if ok then
		self.send_handle, self.send_next = handle, k
		return
	end
	self:say("warn", "no timer for send %d (%s): sent at once", k, tostring(handle))
	self:send(k)
	self:arm_send(k + 1, gen)
end

function Rows:fire_send(k, gen)
	if self.stopped or gen ~= self.send_gen then
		return
	end
	self.send_handle, self.send_next = nil, nil
	self:send(k)
	self:arm_send(k + 1, gen)
end

function Rows:cancel_sends()
	self.send_gen = self.send_gen + 1
	local handle = self.send_handle
	self.send_handle, self.send_next = nil, nil
	local ok, err = cancel(handle)
	if not ok then
		self:say("warn", "a pending send could not be cancelled (%s); it will be ignored", tostring(err))
	end
end

-- The rows' state from now on, sent at SEND_MS (KL-D6).
function Rows:apply(gate, breeze)
	self.gate, self.breeze = gate, breeze
	self.applies = self.applies + 1
	self:cancel_sends()
	self:arm_send(1, self.send_gen)
end

-- The hide (KL-D4): armed once while "nothing bound" holds; a later update that keeps it does not re-arm it.
function Rows:arm_hide(cause)
	if self.hide_armed then
		return
	end
	self.hide_gen = self.hide_gen + 1
	local gen = self.hide_gen
	local ok, handle = try(self.o.timer, ledrows.HIDE_MS, function()
		self:fire_hide(gen)
	end)
	if not ok then
		self:say("warn", "no timer for the hide (%s): the rows stay shown until the next change", tostring(handle))
		return
	end
	self.hide_armed, self.hide_handle, self.hide_cause, self.hide_since = true, handle, cause, self:clock()
	self:say("debug", "nothing bound to a Fan Speed link: the rows hide in %d ms unless one is bound (%s)",
		ledrows.HIDE_MS, cause)
end

function Rows:cancel_hide(why)
	if not self.hide_armed then
		return
	end
	self.hide_gen = self.hide_gen + 1
	local handle = self.hide_handle
	self.hide_armed, self.hide_handle, self.hide_cause, self.hide_since = false, nil, nil, nil
	local ok, err = cancel(handle)
	if not ok then
		self:say("warn", "the hide could not be cancelled (%s); it will be ignored", tostring(err))
	end
	self:say("debug", "the hide was cancelled: %s", why)
end

-- `changed` (KL-D7): only when an apply after start() moved the gate.
function Rows:notify(shown, cause)
	if self.o.changed == nil then
		return
	end
	local ok, err = try(self.o.changed, shown, cause)
	if not ok then
		self:say("warn", "changed(%s, %s) failed: %s", tostring(shown), tostring(cause), tostring(err))
	end
end

function Rows:fire_hide(gen)
	if self.stopped or gen ~= self.hide_gen or not self.hide_armed then
		return
	end
	local cause = self.hide_cause
	self.hide_armed, self.hide_handle, self.hide_cause, self.hide_since = false, nil, nil, nil
	if self.speed_bound then
		return -- a bind cancels the hide; nothing to do if one slipped through
	end
	self:apply(false, self.has_breeze ~= false)
	self:say("info", "hidden: no keypad button is bound to a Fan Speed link (%s)",
		cause == "start" and "since late init" or "after an unbind")
	self:notify(false, cause)
end

-- The inputs against the rows as applied (KL-D2 to KL-D4).
function Rows:evaluate()
	local gate, breeze = self.speed_bound, self.has_breeze ~= false
	if self.gate and not gate then
		self:arm_hide("binding")
		return
	end
	self:cancel_hide("a Fan Speed link is bound again")
	if picture(self.gate, self.breeze) == picture(gate, breeze) then
		return
	end
	local opened = gate and not self.gate
	self:apply(gate, breeze)
	if opened then
		self:say("info", "shown: a keypad button is bound to a Fan Speed link")
		self:notify(true, "binding")
	else
		self:say("info", "the Breeze rows %s: the fan %s", breeze and "shown" or "hidden",
			breeze and "has Breeze or has not said" or "has no Breeze")
	end
end

-- Late init (KL-D6): the first apply, the gate open (fail open, KV21), no `changed`; with nothing bound the hide
-- is armed from here (KV1).
function Rows:start()
	if self.stopped then
		return
	end
	if self.started then
		self:apply(self.gate, self.breeze)
		return
	end
	self.started = true
	self:apply(true, self.has_breeze ~= false)
	if not self.speed_bound then
		self:arm_hide("start")
	end
end

-- Before start() the inputs are only recorded; the same inputs again do nothing.
function Rows:update(view)
	if self.stopped then
		return
	end
	view = type(view) == "table" and view or {}
	local bound = view.speed_bound == true
	local has_breeze = view.has_breeze
	if has_breeze ~= true and has_breeze ~= false then
		has_breeze = nil
	end
	if bound == self.speed_bound and has_breeze == self.has_breeze then
		return
	end
	self.speed_bound, self.has_breeze = bound, has_breeze
	if self.started then
		self:evaluate()
	end
end

function Rows:shown()
	return self.gate == true
end

-- OnDriverDestroyed: every timer cancelled, nothing sent; final.
function Rows:stop()
	if self.stopped then
		return
	end
	self:cancel_sends()
	self:cancel_hide("stopped")
	self.stopped = true
end

function Rows:debug()
	local hidden = 0
	for _, name in ipairs(ledrows.ROWS) do
		if self:hidden(name) then
			hidden = hidden + 1
		end
	end
	local hide = nil
	if self.hide_armed then
		local now = self:clock()
		local left = nil
		if now ~= nil and self.hide_since ~= nil then
			left = math.max(0, ledrows.HIDE_MS - (now - self.hide_since))
		end
		hide = { cause = self.hide_cause, since = self.hide_since, left = left }
	end
	return {
		started = self.started,
		stopped = self.stopped,
		speed_bound = self.speed_bound,
		has_breeze = self.has_breeze,
		shown = self.gate,
		breeze_shown = self.gate and self.breeze,
		hidden = hidden,
		rows = #ledrows.ROWS,
		hide = hide,
		send = self.send_next,
		applies = self.applies,
		sends = self.sends,
		failures = self.failures,
	}
end

return ledrows
