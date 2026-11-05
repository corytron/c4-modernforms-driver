-- fan/model.lua: the state model, the scheduler and the phases of the Modern
-- Forms Fan driver (docs/v1-design.md section 9.5; the rules are sections 3.4
-- to 3.6, 4 and 6, the persistence is section 8).
--
-- The model never touches Director. What does arrives as an argument
-- (section 9.1): the transport (one request in flight, section 9.4), the wire
-- module (pure bodies and answers, section 9.3), the clocks, a one-shot timer,
-- the persistent store and a listener table. Answers come from the transport's
-- callbacks; the driver reads the model through its methods and hears it
-- through the listener (section 9.5).
--
-- The shape of it:
--
--   * Per field the model keeps a confirmed value (the last the fan reported),
--     an in-flight value (the request on the wire) and a wanted one (asked for,
--     not yet sent); per group (fan, direction, light) it also keeps what the
--     proxies were last told (section 4.1). Shown is wanted over in flight over
--     confirmed: what keypad LEDs follow. A group is busy while one of its
--     fields is wanted or in flight, and is reported only once it is not
--     (R5), so a burst's intermediate answers fire nothing.
--   * One request is in flight at a time. What goes next is, in this order: the
--     pending Use Selected Fan read (or a follow's), a reboot, the contact (an info
--     read, then a state read) while one is due, a command (one group per request,
--     fan, direction, light), the due poll (section 4.3).
--   * A failure of any request makes the next one a contact, so a command is
--     never sent to a fan whose identity has not been read again since it last
--     went quiet (V5, ECM N3). A command wanted while a contact is due makes
--     the contact go at once and is tied to it: when that attempt fails the
--     command is dropped, never replayed (ECM P8; "tried once").
--   * Every listener call is queued while the model changes its state and
--     delivered afterwards, in order, so a listener only ever sees a model
--     that is consistent, and an error in one never reaches the scheduler.
--   * Differences between the fan and what the proxies were told are reported
--     only while the fan is online, or by the contact that makes it so (R7,
--     section 6.2); a command given up in the meantime never turns into a
--     second try (ECM P8).
--   * Beyond section 9.5 the model has on_idle(), which the transport calls
--     when its gap ends, request() for the Dev Request command, and follow(),
--     Use Selected Fan's read restricted to the pinned fan, for fan/follow.lua
--     (docs/address-follow-design.md 2.2).
--
-- Persistent keys (section 8): mf_identity, mf_info, mf_online (written here);
-- mf_preset_speed is the fan proxy's. Nothing private is ever kept: the
-- parser has dropped it before an answer gets here (V20), and the log carries
-- the last four hex digits of an id only (section 3.7).
--
-- Lua 5.1: no goto, no integer division, no bit operators.

local model = {}

-- Section 3.4 ---------------------------------------------------------------

model.POLL_DEFAULT_S = 15    -- Poll Interval (s), 10 to 120
model.POLL_MIN_S = 10
model.POLL_MAX_S = 120
model.FAST_POLL_MS = 2000    -- the poll while the fast window is open
model.FAST_WINDOW_MS = 20000
model.GAP_MS = 250           -- the transport's gap; the model waits for its on_idle
model.SETTLE_MS = 2500       -- a read that contradicts a just-answered command is held this long
model.BACKOFF_S = { 10, 20, 40, 60 }
model.OFFLINE_AFTER = 3      -- failures in a row
model.IDENTITY_POLL_S = 60   -- foreign, Gen 4 and not a fan
model.REBOOT_WINDOW_S = 120
model.REBOOT_POLL_S = 10
model.INFO_REFRESH_S = 21600 -- the static data again every 6 h
model.RAMP_STEP_MS = 500     -- the light's hold steps (its constant; exported with the others)

local Model = {}
Model.__index = Model

local GROUPS = { "fan", "direction", "light" }
local GROUP_FIELDS = {
	fan = { "fan_on", "speed" },
	direction = { "direction" },
	light = { "light_on", "level" },
}
local FIELDS = { "fan_on", "speed", "direction", "light_on", "level" }
-- Section 4.1's read-only rows, kept beside the five fields in the confirmed state.
local READ_ONLY = {
	"client_id", "generation", "wind", "wind_speed", "away", "learning", "schedule_set", "fan_timer",
	"light_timer", "fan_sleep_timer", "light_sleep_timer", "user_data",
}
-- The names the fan uses for the five fields (section 3.1), for "no <key>" refusals.
local FIELD_NAME = {
	fan_on = "fan", speed = "speed", direction = "direction", light_on = "light", level = "light level",
}
local IDENTITY_PHASES = { foreign = true, gen4 = true, notfan = true }
-- Section 6.1's offline-like phases: the only ones a follow starts from (address-follow-design F2).
local OFFLINE_LIKE = { offline = true, foreign = true, gen4 = true, notfan = true }

-- Helpers -------------------------------------------------------------------

local function noop() end

local QUIET_LOG = { debug = noop, info = noop, warn = noop, error = noop, always = noop }

-- The log argument is common/log.lua's shape; any level it lacks is silent.
local function normalize_log(l)
	if type(l) ~= "table" then
		return QUIET_LOG
	end
	return setmetatable({}, { __index = function(_, k)
		return l[k] or QUIET_LOG[k]
	end })
end

local function copy(t)
	if type(t) ~= "table" then
		return t
	end
	local out = {}
	for k, v in pairs(t) do
		out[k] = v
	end
	return out
end

local function trim(text)
	return (tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function upper(text)
	return text ~= nil and tostring(text):upper() or nil
end

-- "...5301": an id in the log shows its last four characters only (section 3.7).
local function suffix(id)
	local s = tostring(id or "")
	return "..." .. s:sub(-4)
end

local function hhmm(at)
	local ok, text = pcall(os.date, "%H:%M", at)
	return ok and text or "?"
end

local function default_date(at)
	local ok, text = pcall(os.date, "%Y-%m-%d", at)
	return ok and text or ""
end

local function memory_store()
	local data = {}
	return {
		get = function(key) return data[key] end,
		set = function(key, value) data[key] = value end,
	}
end

local function is_int(v, lo, hi)
	return type(v) == "number" and v >= lo and v <= hi and v == math.floor(v)
end

-- The value a proxy hears for a group (section 4.1): CURRENT_SPEED is the speed
-- when the fan is on and 0 when off; the light's level when on and 0 when off.
-- nil while the group's fields are not known, and then nothing is reported.
local function group_value(group, f)
	if group == "fan" then
		if f.fan_on == false then
			return 0
		end
		if f.fan_on == true and f.speed ~= nil then
			return f.speed
		end
		return nil
	elseif group == "direction" then
		return f.direction
	end
	if f.light_on == false then
		return 0
	end
	if f.light_on == true and f.level ~= nil then
		return f.level
	end
	return nil
end

-- The static data's names for the log, and a value as text ("none" for an empty one).
local INFO_NAME = {
	fan_type = "fan type", light_type = "light kit", motor_type = "motor", firmware = "firmware",
	mcu_firmware = "MCU firmware",
}

local function shown_text(v)
	if v == nil or v == "" then
		return "none"
	end
	return tostring(v)
end

-- A wanted group as a few words, for the log: "speed 3", "light off".
local function describe(group, w)
	if group == "fan" then
		if w.fan_on == false then
			return "fan off"
		end
		return "speed " .. tostring(w.speed)
	elseif group == "direction" then
		return "direction " .. tostring(w.direction)
	end
	if w.light_on == false then
		return "light off"
	end
	if w.level ~= nil then
		return "light " .. tostring(w.level)
	end
	return "light on"
end

local function show_value(field, v)
	if v == nil then
		return "nothing"
	end
	if field == "fan_on" or field == "light_on" then
		return v and "on" or "off"
	end
	return tostring(v)
end

-- Gen 3 timers count seconds down; the Fan Automations text rounds up to minutes,
-- so the model reports a change of the automations at that granularity.
local function automations_signature(st)
	local function minutes(s)
		if type(s) ~= "number" or s <= 0 then
			return 0
		end
		return math.ceil(s / 60)
	end
	local function running(s)
		return (type(s) == "number" and s > 0) and 1 or 0
	end
	return table.concat({
		tostring(st.away), tostring(st.learning), tostring(st.schedule_set), minutes(st.fan_timer),
		minutes(st.light_timer), running(st.fan_sleep_timer), running(st.light_sleep_timer),
	}, "|")
end

-- The state read as one log line: "fan on/3 forward, light off/100".
local function summary(c, has_light)
	local fan = c.fan_on == nil and "fan ?" or (c.fan_on and "fan on" or "fan off")
	if c.speed ~= nil then
		fan = fan .. "/" .. c.speed
	end
	if c.direction ~= nil then
		fan = fan .. " " .. c.direction
	end
	local light = "no light kit"
	if has_light ~= false then
		light = c.light_on == nil and "light ?" or (c.light_on and "light on" or "light off")
		if c.level ~= nil then
			light = light .. "/" .. c.level
		end
	end
	return fan .. ", " .. light
end

-- Construction --------------------------------------------------------------

-- opts: transport (section 9.4), wire (9.3), now() -> ms, clock() -> seconds
-- (default os.time), timer(ms, cb) -> object with :Cancel(), store = { get, set }
-- (default: in memory), log (common/log.lua's shape), listener (section 9.5),
-- date(seconds) -> "YYYY-MM-DD" (default os.date; for the firmware's "since").
-- The transport's on_idle must call m:on_idle() (the transport is built first).
function model.new(opts)
	assert(type(opts) == "table", "model.new needs options")
	local self = setmetatable({}, Model)
	self.t = assert(opts.transport, "model.new needs a transport")
	self.wire = assert(opts.wire, "model.new needs the wire module")
	self.now = assert(opts.now, "model.new needs now()")
	self.timer = assert(opts.timer, "model.new needs timer()")
	self.clock = opts.clock or os.time
	self.date = opts.date or default_date
	self.store = opts.store or memory_store()
	self.log = normalize_log(opts.log)
	self.listener = opts.listener or {}

	self.phase_ = nil           -- set by start()
	self.detail_ = {}
	self.address = nil          -- the address in use (a valid dotted quad)
	self.typed = ""             -- what the owner typed when it was not one
	self.pin = nil              -- { client_id, mac, generation, address, learned }
	self.pin_saved = false
	self.info_ = nil            -- mf_info; has_light is derived
	self.has_light = nil
	self.has_wind = nil
	self.shown_wind = nil       -- has_wind as the last info event had it (#59)
	self.conf = {}              -- confirmed: the five fields and section 4.1's read-only rows
	self.missing = nil          -- wire keys the last state lacked (S6)
	self.missing_set = {}
	self.known = false          -- a state was read in this run
	self.reported = false       -- the first contact's reports ("start") are done
	self.wanted, self.flight = {}, {}
	self.told = {}              -- group -> the value last reported
	self.settle, self.held = {}, {}
	self.was_busy = {}
	self.owed = {}              -- group -> the reason of a report a busy group postponed ("start", "online")
	self.leveled = false        -- a level of the current turn-on has been answered (V14)
	self.failures, self.json_streak = 0, 0
	self.fail_kind, self.first_failure_s = nil, nil
	self.fast_until = 0
	self.poll_s = model.POLL_DEFAULT_S
	self.poll_due = false
	self.poll_kind = nil
	self.last_answer_ms = nil
	self.info_at_ms = nil
	self.offline_at_ms = nil
	self.contact = nil
	self.inflight = nil
	self.use, self.off_req, self.reb, self.reboot_req = nil, nil, nil, false
	self.giving_up = false      -- a read under way is being given up: its callback runs
	self.reboot_expired = false
	self.timers = {}
	self.events, self.flushing, self.pumping = {}, false, false
	self.online_flag = false
	self.seq = 0
	self.last_ms = nil
	self.last_shown = {}
	self.auto_sig = nil
	self.clamped = {}
	self.stopped = false
	return self
end

-- Listener calls, timers, the store -----------------------------------------

function Model:emit(name, ...)
	if self.stopped then
		return
	end
	self.events[#self.events + 1] = { name = name, n = select("#", ...), ... }
end

-- The shown state is compared once the model's own changes are done, so the
-- listener hears one change however many steps made it.
function Model:queue_shown()
	local now_shown = self:shown()
	local last = self.last_shown
	for _, f in ipairs(FIELDS) do
		if now_shown[f] ~= last[f] then
			self.last_shown = now_shown
			self:emit("shown", copy(now_shown))
			return
		end
	end
end

-- Delivers the queued events. A listener may call back into the model; what
-- that queues is delivered by this same loop, after the call returns.
function Model:flush()
	self:queue_shown()
	if self.flushing then
		return
	end
	self.flushing = true
	while self.events[1] do
		local e = table.remove(self.events, 1)
		local fn = self.listener[e.name]
		if type(fn) == "function" then
			local ok, err = pcall(fn, unpack(e, 1, e.n))
			if not ok then
				self.log.error("listener %s failed: %s", e.name, tostring(err))
			end
		end
	end
	self.flushing = false
end

function Model:set_timer(name, ms, fn)
	self:cancel_timer(name)
	local rec = {}
	local ok, handle = pcall(self.timer, ms, function()
		if self.stopped or self.timers[name] ~= rec then
			return
		end
		self.timers[name] = nil
		fn()
	end)
	if not ok then
		self.log.error("could not arm the %s timer: %s", name, tostring(handle))
		return
	end
	rec.handle = handle
	self.timers[name] = rec
end

function Model:cancel_timer(name)
	local rec = self.timers[name]
	self.timers[name] = nil
	-- Director's timer object may be userdata, so it is not type-tested.
	if rec and rec.handle then
		pcall(function()
			rec.handle:Cancel()
		end)
	end
end

function Model:persist(key, value)
	local ok, err = pcall(self.store.set, key, value)
	if not ok then
		self.log.error("could not persist %s: %s", key, tostring(err))
	end
end

-- A read of the store never raises into Director either; what cannot be read is unknown.
function Model:recall(key)
	local ok, value = pcall(self.store.get, key)
	if not ok then
		self.log.error("could not read %s: %s", key, tostring(value))
		return nil
	end
	return value
end

local function debug_on(self)
	local enabled = self.log.enabled
	return enabled == nil or enabled("debug")
end

-- Phases (section 6.1) ------------------------------------------------------

-- Enters a phase. The Online variable's value and the event that goes with
-- the entry are worked out here and handed to the listener in `detail`:
--   detail.online  the value the Online variable takes (true/false), nil: unchanged
--   detail.event   "online" or "offline" when Fan Online or Fan Offline fires
-- A phase that keeps the flag (waiting, rebooting) leaves both nil; "unset" sets
-- the flag to false without an event (section 6.1's table).
function Model:set_phase(new, patch)
	patch = patch or {}
	local old, od = self.phase_, self.detail_
	local d = { address = self.address, since = patch.since }
	if d.since == nil then
		d.since = (old == new) and od.since or self.clock()
	end
	if new == "foreign" then
		d.other_client_id = patch.other_client_id or od.other_client_id
	elseif new == "offline" then
		d.failure = patch.failure or od.failure
	elseif new == "rebooting" then
		d.sent = patch.sent or od.sent
	end
	local target
	if new == "online" then
		target = true
	elseif new ~= "waiting" and new ~= "rebooting" then
		target = false
	end
	if target ~= nil and target ~= self.online_flag then
		self.online_flag = target
		self:persist("mf_online", target)
		if new ~= "unset" then
			d.event = target and "online" or "offline"
		end
	end
	d.online = target
	local changed = old ~= new or od.other_client_id ~= d.other_client_id or od.failure ~= d.failure
		or od.address ~= d.address or d.event ~= nil
	self.phase_, self.detail_ = new, d
	if changed then
		self:emit("phase", new, copy(d), old)
	end
end

-- State helpers -------------------------------------------------------------

function Model:group_present(group)
	return group ~= "light" or self.has_light ~= false
end

function Model:group_has_wanted(group)
	for _, f in ipairs(GROUP_FIELDS[group]) do
		if self.wanted[f] ~= nil then
			return true
		end
	end
	return false
end

function Model:busy(group)
	for _, f in ipairs(GROUP_FIELDS[group] or {}) do
		if self.wanted[f] ~= nil or self.flight[f] ~= nil then
			return true
		end
	end
	return false
end

function Model:has_commands()
	if self.off_req then
		return true
	end
	for _, g in ipairs(GROUPS) do
		if self:group_has_wanted(g) and self:group_present(g) then
			return true
		end
	end
	return false
end

-- Wanted over in flight over confirmed, per field (section 4.1).
function Model:shown()
	local s = {}
	for _, f in ipairs(FIELDS) do
		local v = self.wanted[f]
		if v == nil then
			v = self.flight[f]
		end
		if v == nil then
			v = self.conf[f]
		end
		s[f] = v
	end
	return s
end

function Model:confirmed()
	if not self.known then
		return nil
	end
	return copy(self.conf)
end

function Model:identity()
	return self.pin and copy(self.pin) or nil
end

function Model:info()
	if not self.info_ then
		return nil
	end
	local out = copy(self.info_)
	out.has_light = self.has_light
	out.has_wind = self.has_wind
	return out
end

function Model:phase()
	return self.phase_ or "unset", copy(self.detail_)
end

-- The table texts.status takes (section 9.6); the controller's OS and the build's
-- Find Fans are the driver's to add.
function Model:status_view()
	local d = self.detail_
	local missing
	if self.missing and #self.missing > 0 then
		missing = copy(self.missing)
	end
	return {
		phase = self.phase_ or "unset",
		address = self.address,
		typed = self.typed,
		since = d.since,
		now = self.clock(),
		failure = d.failure,
		known = self.known,
		other = d.other_client_id,
		sent = d.sent,
		st = self:confirmed(),
		has_light = self.has_light,
		has_wind = self.has_wind,
		missing = missing,
	}
end

-- What the Dev State line shows (section 12).
function Model:debug()
	local busy = {}
	for _, g in ipairs(GROUPS) do
		if self:busy(g) then
			busy[#busy + 1] = g
		end
	end
	return {
		seq = self.seq,
		phase = self.phase_ or "unset",
		told = copy(self.told),
		busy = busy,
		ms = self.last_ms,
		epoch = self.t.epoch,
		failures = self.failures,
	}
end

function Model:set_poll_interval(seconds)
	local n = tonumber(seconds)
	if not n or n ~= n then
		return self.poll_s
	end
	n = math.floor(n)
	n = math.max(model.POLL_MIN_S, math.min(model.POLL_MAX_S, n))
	self.poll_s = n
	-- A steady wait is measured again from the last answer.
	if self.poll_kind == "steady" and self.timers.poll and self.last_answer_ms then
		local elapsed = self.now() - self.last_answer_ms
		self:arm_poll(math.max(1, n * 1000 - elapsed), "steady")
	end
	return n
end

-- Identity ------------------------------------------------------------------

-- The pinned fan: the client id (case-insensitive) and, when both sides have one,
-- the station MAC (section 3.5).
function Model:same(pin, client_id, mac)
	if pin.client_id ~= nil and client_id ~= nil then
		if not self.wire.same_fan(pin, client_id) then
			return false
		end
	elseif not (pin.mac ~= nil and mac ~= nil) then
		return false
	end
	if pin.mac ~= nil and mac ~= nil and upper(pin.mac) ~= upper(mac) then
		return false
	end
	return true
end

function Model:announce_info()
	if self.pin then
		self.shown_wind = self.has_wind
		self:emit("info", self:identity(), self:info())
	end
end

-- Records the static data: the model, the types and the firmware with the date
-- it was first seen (ECM F1). Returns true when anything changed.
function Model:record_info(info)
	local prev = self.info_
	local new = {
		fan_type = info.fan_type,
		light_type = info.light_type,
		motor_type = info.motor_type,
		firmware = info.firmware,
		mcu_firmware = info.mcu_firmware,
	}
	if prev == nil then
		new.firmware_since = self.date(self.clock())
	elseif prev.firmware ~= nil and info.firmware ~= nil and prev.firmware ~= info.firmware then
		new.firmware_since = self.date(self.clock())
		new.firmware_was = prev.firmware
	else
		new.firmware_since, new.firmware_was = prev.firmware_since, prev.firmware_was
	end
	local changed = prev == nil
	if prev then
		local parts = {}
		for _, k in ipairs({ "fan_type", "light_type", "motor_type", "firmware", "mcu_firmware" }) do
			if prev[k] ~= new[k] then
				changed = true
				parts[#parts + 1] = string.format("%s %s -> %s", INFO_NAME[k], shown_text(prev[k]), shown_text(new[k]))
			end
		end
		if #parts > 0 then
			-- ECM H3: a fan that differs from the last contact is logged, whatever the cause.
			self.log.warn("The fan reports different static data: %s", table.concat(parts, ", "))
		end
	end
	self.info_ = new
	self.has_light = type(new.light_type) == "string" and new.light_type:find("%S") ~= nil
	if changed then
		self:persist("mf_info", copy(new))
	end
	return changed
end

-- Reports and the log -------------------------------------------------------

function Model:log_answer(rec, result, st)
	if not debug_on(self) then
		return
	end
	local secs = (result.ms or 0) / 1000
	if rec.kind == "info" then
		local gen = self.pin and self.pin.generation or "?"
		local info = self.info_ or {}
		self.log.debug("<- fan #%s info: Gen %s, firmware %s, light kit %s, id %s", tostring(rec.seq), gen,
			tostring(info.firmware or "?"), self.has_light and "yes" or "no",
			suffix(self.pin and self.pin.client_id or (self.contact and self.contact.info
				and self.contact.info.client_id)))
	else
		self.log.debug("<- fan #%s %s in %.2f s: %s", tostring(rec.seq), tostring(result.code or 200), secs,
			summary(st, self.has_light))
	end
end

-- Scheduler -----------------------------------------------------------------

-- Called by the transport GAP_MS after each result.
function Model:on_idle()
	self:pump()
	self:flush()
end

-- Something is due, and the slot is busy: look again after the gap, in case the
-- transport has no on_idle to say so (a result it dropped does not call it).
function Model:schedule_retry()
	if self.timers.retry then
		return
	end
	self:set_timer("retry", model.GAP_MS, function()
		self:pump()
		self:flush()
	end)
end

function Model:arm_poll(ms, kind)
	self.poll_due = false
	self.poll_kind = kind
	self:set_timer("poll", ms, function()
		self.poll_due = true
		self:pump()
		self:flush()
	end)
end

-- After a good answer: 2 s inside the fast window, else the poll interval.
function Model:arm_next_poll()
	if self.now() < self.fast_until then
		self:arm_poll(model.FAST_POLL_MS, "fast")
	else
		self:arm_poll(self.poll_s * 1000, "steady")
	end
end

function Model:open_fast_window()
	self.fast_until = self.now() + model.FAST_WINDOW_MS
end

function Model:has_work()
	if self.use and not self.use.sent then
		return true
	end
	if self.reboot_req then
		return true
	end
	local c = self.contact
	if c then
		return c.ready or c.probe or self.poll_due or self:has_commands()
	end
	return self.poll_due or self:has_commands()
end

-- A contact (section 3.5): the info read, then the state read. `why` is for the log.
local function new_contact(why)
	return { why = why, step = "info", ready = true, probe = false }
end

function Model:read_request()
	local w = self.wire
	if self.info_at_ms and self.now() - self.info_at_ms >= model.INFO_REFRESH_S * 1000 then
		return { kind = "info", path = w.PATH, body = w.QUERY_INFO }
	end
	return { kind = "state", path = w.PATH, body = w.QUERY_STATE }
end

function Model:contact_request(c)
	local w = self.wire
	if c.step == "state" then
		return { kind = "state", path = w.PATH, body = w.QUERY_STATE, contact = true }
	end
	return { kind = "info", path = w.PATH, body = w.QUERY_INFO, contact = true }
end

-- A command's fields and what the request covers (section 4.3): the wanted
-- fields of a group, turned into the one body to send now. The light's "on at
-- N" is the level first and then lightOn (V14), at most two requests: the level
-- is skipped when it is the kept one, and once a level of this turn-on has been
-- answered the next request is lightOn whatever the wanted level became (a
-- newer level then follows as a plain level change).
function Model:plan_group(g)
	local w = self.wanted
	if g == "fan" then
		if w.fan_on == false then
			return { fan_on = false }, { fan_on = false }
		end
		local speed = w.speed
		if speed == nil then
			speed = self.conf.speed
		end
		if not is_int(speed, 1, 6) then
			return nil
		end
		return { fan_on = true, speed = speed }, { fan_on = true, speed = speed }
	elseif g == "direction" then
		return { direction = w.direction }, { direction = w.direction }
	end
	if w.light_on == false then
		return { light_on = false }, { light_on = false }
	end
	local level = w.level
	if self.conf.light_on == true then
		if level ~= nil then
			return { level = level }, { level = level }
		end
		return { light_on = true }, { light_on = true }
	end
	if level ~= nil and level ~= self.conf.level and not self.leveled then
		return { level = level }, { level = level }, true
	end
	return { light_on = true }, { light_on = true, level = self.conf.level }
end

function Model:command_request()
	local w = self.wire
	for _, g in ipairs(GROUPS) do
		if self:group_has_wanted(g) and self:group_present(g) then
			local sent, covers, step1 = self:plan_group(g)
			local body, why
			if sent then
				body, why = w.body(sent)
			end
			if body then
				return { kind = "command", path = w.PATH, body = body, group = g, sent = sent, covers = covers,
					step1 = step1 }
			end
			self.log.error("%s: no body for the wanted fields (%s); dropped", g, tostring(why or "no speed"))
			self:release_group(g)
			self:reconcile({})
		end
	end
	if self.off_req then
		local o = self.off_req
		local fields = o.which == "away" and { away = false } or { learning = false }
		local body = w.body(fields)
		if body then
			return { kind = "command", tag = "off", path = w.PATH, body = body, sent = {}, covers = {} }
		end
		self:resolve_off("not_answering")
	end
	return nil
end

function Model:next_request()
	local w = self.wire
	if self.use then
		if self.use.sent then
			return nil
		end
		return { kind = "info", tag = "use", path = w.PATH, body = w.QUERY_INFO }
	end
	if self.reboot_req then
		return { kind = "reboot", tag = "reboot", path = w.PATH, body = w.REBOOT, timeout = 3 }
	end
	local c = self.contact
	if c then
		if c.probe then
			return { kind = "g4", path = w.G4_PATH, body = w.QUERY_G4, contact = true, probe = true }
		end
		if c.ready or self.poll_due or self:has_commands() then
			return self:contact_request(c)
		end
		return nil
	end
	local cmd = self:command_request()
	if cmd then
		return cmd
	end
	if self.poll_due then
		return self:read_request()
	end
	return nil
end

-- The commands wanted when a request that is not a command goes out: if it
-- fails they are dropped with it (tried once, ECM P8).
function Model:tied_snapshot()
	local tied
	for _, g in ipairs(GROUPS) do
		if self:group_has_wanted(g) then
			tied = tied or {}
			tied[g] = true
		end
	end
	if self.off_req then
		tied = tied or {}
		tied.off = true
	end
	return tied
end

function Model:send(req)
	local rec = {
		kind = req.kind,
		tag = req.tag,
		group = req.group,
		sent = req.sent or {},
		covers = req.covers or {},
		step1 = req.step1,
		contact = req.contact,
		probe = req.probe,
		epoch = self.t.epoch,
	}
	if req.kind ~= "command" then
		rec.tied = self:tied_snapshot()
	end
	self.inflight = rec
	local seq, why = self.t:send({ kind = req.kind, path = req.path, body = req.body, timeout = req.timeout },
		function(result)
			self:on_result(rec, result)
		end)
	if not seq then
		self.inflight = nil
		self.log.debug("request not sent (%s)", tostring(why))
		if why == "busy" then
			self:schedule_retry()
		end
		return false
	end
	rec.seq = seq
	self.seq = seq
	for f, v in pairs(rec.covers) do
		self.flight[f] = v
	end
	if req.contact and self.contact and not req.probe then
		self.contact.ready = false
	end
	if req.probe and self.contact then
		self.contact.probe = false
		self.contact.ready = false
	end
	if req.tag == "use" then
		self.use.sent = true
	end
	if req.tag == "reboot" then
		self.reboot_req = false
	end
	self.poll_due = false
	return true
end

function Model:pump_once()
	if self.t:busy() then
		-- A request of ours on the wire needs no look-again: its result comes back here.
		if not self.inflight and self:has_work() then
			self:schedule_retry()
		end
		return
	end
	self:cancel_timer("retry")
	local req = self:next_request()
	if req then
		self:send(req)
	end
end

function Model:pump()
	if self.stopped or self.pumping then
		return
	end
	local ph = self.phase_
	if (ph == nil or ph == "unset") and not self.use then
		-- With no address nothing goes out, except Use Selected Fan's one read: a fan can
		-- be picked while Fan Address is empty (section 3.5).
		return
	end
	self.pumping = true
	local ok, err = pcall(self.pump_once, self)
	self.pumping = false
	if not ok then
		self.log.error("scheduler failed: %s", tostring(err))
	end
end

-- Answers (section 4.2, 4.4) ------------------------------------------------

local function classify(result)
	if result.ok then
		return "ok"
	end
	local err = result.err
	if err == "timeout" or err == "connect" or err == "empty" or err == "json" then
		return err
	end
	if err == "http" then
		return result.code == 404 and "404" or "http"
	end
	return "connect"
end

-- The transport's result for the request in flight, nothing else: an answer of an
-- abandoned request, an older epoch or another seq is dropped unread (section 4.2).
function Model:on_result(rec, result)
	if self.stopped or self.inflight ~= rec or type(result) ~= "table" then
		self.log.debug("a late answer is dropped unread")
		return
	end
	if (result.seq ~= nil and result.seq ~= rec.seq)
		or (result.epoch ~= nil and rec.epoch ~= nil and result.epoch ~= rec.epoch) then
		self.log.debug("answer #%s of another epoch is dropped unread", tostring(result.seq))
		return
	end
	self.inflight = nil
	self.last_ms = result.ms
	local ok, err = pcall(self.handle_result, self, rec, result)
	if not ok then
		self.log.error("answer #%s could not be handled: %s", tostring(rec.seq), tostring(err))
	end
	self:pump()
	self:flush()
end

function Model:handle_result(rec, result)
	local outcome = classify(result)
	if rec.tag == "reboot" then
		return self:after_reboot_request(outcome)
	elseif rec.tag == "use" then
		return self:after_use(result, outcome)
	elseif rec.tag == "dev" then
		return self:after_dev(rec, result)
	elseif rec.probe then
		return self:after_probe(rec, result, outcome)
	end
	if outcome == "404" then
		return self:on_404(rec)
	elseif outcome ~= "ok" then
		return self:on_failure(rec, result, outcome)
	end
	if rec.kind == "info" then
		return self:on_info(rec, result)
	end
	return self:on_state(rec, result)
end

function Model:note_alive(result)
	self.failures, self.json_streak = 0, 0
	self.fail_kind, self.first_failure_s = nil, nil
	if result then
		self:emit("seen", self.clock(), result.ms)
	end
end

-- The static data answered (a contact's first step, or the 6-hourly refresh).
function Model:on_info(rec, result)
	local info = self.wire.info(result.json)
	if not info or not info.mac then
		return self:on_failure(rec, result, "json")
	end
	local pin = self.pin
	if pin and not self:same(pin, info.client_id, info.mac) then
		self:note_alive(result)
		return self:go_foreign(info.client_id, rec)
	end
	self:note_alive(result)
	self.info_at_ms = self.now()
	local changed = self:record_info(info)
	self:log_answer(rec, result)
	local c = self.contact
	if c then
		c.info = info
		c.step, c.ready = "state", true
		self:cancel_timer("poll")
		self.poll_due = false
	else
		self:arm_next_poll()
	end
	if changed then
		self:announce_info()
	end
end

-- A state answered (a contact's second step, a poll, or a command's answer).
function Model:on_state(rec, result)
	local st = self.wire.state(result.json)
	if not st then
		return self:on_failure(rec, result, "json")
	end
	local pin, c = self.pin, self.contact
	if pin then
		if not self.wire.same_fan(pin, st.client_id) then
			self:note_alive(result)
			return self:go_foreign(st.client_id, rec)
		end
	elseif not (c and c.info and self.wire.same_fan(c.info.client_id, st.client_id)) then
		return self:on_failure(rec, result, "json")
	end
	self:note_alive(result)
	self:log_answer(rec, result, self:normalize(st, true))
	self:apply_answer(rec, st)
end

-- Section 3.3: values outside their range are clamped (the parser has done it;
-- a state that still carries one is clamped here) and logged once per contact.
function Model:note_clamp(label)
	if self.clamped[label] then
		return
	end
	self.clamped[label] = true
	self.log.warn("the fan reports an out-of-range %s; clamped", label)
end

function Model:normalize(st, quiet)
	local n = {}
	for _, f in ipairs(READ_ONLY) do
		n[f] = st[f]
	end
	n.fan_on, n.direction, n.light_on = st.fan_on, st.direction, st.light_on
	n.speed, n.level = st.speed, st.level
	if type(n.speed) == "number" and (n.speed < 1 or n.speed > 6) then
		if not (n.speed == 0 and n.fan_on == false) and not quiet then
			self:note_clamp("fanSpeed " .. tostring(n.speed))
		end
		n.speed = (n.speed == 0 and n.fan_on == false) and nil or math.max(1, math.min(6, n.speed))
	end
	if type(n.level) == "number" and (n.level < 1 or n.level > 100) then
		if (n.level > 100 or n.light_on == true) and not quiet then
			self:note_clamp("lightBrightness " .. tostring(n.level))
		end
		n.level = (n.level < 1 and n.light_on ~= true) and nil or math.max(1, math.min(100, n.level))
	end
	if self.has_light == false then
		n.light_on, n.level = nil, nil
	end
	if not quiet and type(st.adjusted) == "table" then
		for _, label in ipairs(st.adjusted) do
			self:note_clamp(label)
		end
	end
	return n
end

-- The keys a state lacks (S6). A speed or a level that is nil while the fan or the
-- light is off may be a 0 the parser turned into "unknown", so it is not missing.
function Model:find_missing(st)
	local out = {}
	if st.fan_on == nil then
		out[#out + 1] = "fanOn"
	end
	if st.speed == nil and st.fan_on ~= false then
		out[#out + 1] = "fanSpeed"
	end
	if st.direction == nil then
		out[#out + 1] = "fanDirection"
	end
	if self.has_light ~= false then
		if st.light_on == nil then
			out[#out + 1] = "lightOn"
		end
		if st.level == nil and st.light_on ~= false then
			out[#out + 1] = "lightBrightness"
		end
	end
	return out
end

-- One field of a read (section 4.4): believed at once, except inside the settle
-- window of a command's answer, where a value that contradicts the command is
-- held until the next read agrees with it.
function Model:apply_read_value(f, r, now)
	local s = self.settle[f]
	if s and now >= s.until_ms then
		self.settle[f] = nil
		s = nil
	end
	if r == nil or s == nil then
		self.conf[f] = r
		self.held[f] = nil
		return
	end
	local held = self.held[f]
	if r == s.value then
		if held ~= nil then
			self.log.debug("%s: a read of %s was held; the next read agrees with the command (%s), so it is dropped",
				f, tostring(held), tostring(r))
			self.held[f] = nil
		end
		self.conf[f] = r
	elseif held ~= nil and held == r then
		self.conf[f] = r
		self.held[f] = nil
		self.settle[f] = nil
	else
		self.held[f] = r
		self.log.debug("%s: a read of %s inside the settle window is held (the command made it %s)", f,
			tostring(r), tostring(s.value))
	end
end

-- A command's answer is the full new shadow (section 4.4): the fields it set
-- take the answer's values, start a settle window and are compared with what
-- was sent; the rest is read as usual.
function Model:apply_command_fields(rec, norm, now)
	for _, f in ipairs(FIELDS) do
		local sent = rec.sent[f]
		if sent ~= nil then
			local got = norm[f]
			self.conf[f] = got
			self.held[f] = nil
			if got ~= nil then
				self.settle[f] = { value = got, until_ms = now + model.SETTLE_MS }
			else
				self.settle[f] = nil
			end
			if got ~= sent then
				self.log.warn("The fan did not take %s %s (reports %s)", FIELD_NAME[f], show_value(f, sent),
					show_value(f, got))
			end
		else
			self:apply_read_value(f, norm[f], now)
		end
	end
end

function Model:apply_answer(rec, st)
	local now = self.now()
	local c = rec.contact and self.contact or nil
	local norm = self:normalize(st)
	self.missing = self:find_missing(norm)
	self.missing_set = {}
	for _, key in ipairs(self.missing) do
		self.missing_set[key] = true
	end
	if st.wind ~= nil then
		self.has_wind = true
	end
	if c then
		-- A contact reads afresh: what an earlier command still held is not believed over it.
		self.settle, self.held = {}, {}
	end
	if rec.kind == "command" then
		self:apply_command_fields(rec, norm, now)
	else
		for _, f in ipairs(FIELDS) do
			self:apply_read_value(f, norm[f], now)
		end
	end
	for _, f in ipairs(READ_ONLY) do
		self.conf[f] = norm[f]
	end
	self.known = true
	self.last_answer_ms = now
	if rec.kind == "command" then
		self:finish_command(rec, norm)
	end
	local why
	if c then
		why = self:finish_contact(c, st)
	end
	if self.pin and self.has_wind ~= self.shown_wind then
		-- Breeze is learned from a state answer, after the info was announced: with an
		-- unchanged pin (a restart, an update) nothing else would show it again (#59).
		self:announce_info()
	end
	self:reconcile({ why = why, cmd = rec.group })
	if why == "start" then
		self.reported = true
	end
	self:check_automations()
	if rec.tag == "off" then
		self:resolve_off_answer()
	end
	if c then
		self:enter_online(c)
	elseif rec.kind == "command" then
		self:open_fast_window()
	end
	self:arm_next_poll()
end

function Model:check_automations()
	local sig = automations_signature(self.conf)
	if sig ~= self.auto_sig then
		self.auto_sig = sig
		self:emit("automations", copy(self.conf))
	end
end

-- Settled reports (section 4.5) ---------------------------------------------

-- After each answer or failure, per group that is not busy: the confirmed value
-- against what the proxies were told. settled(group, st, why) on a difference
-- ("start", "online", "command" or "outside"), then idle(group, st) when the
-- group has just stopped being busy (its st is {} while nothing has been read
-- yet); a change nobody commanded also opens the fast window and fires outside(...).
--
-- Differences are told only while the fan is online, or by the contact that is
-- about to make it so (ctx.why): a fan that is offline, foreign or being contacted
-- tells the proxies nothing (R7, section 6.2). A group that was busy when a
-- contact read it keeps the contact's reason (`owed`), so a command that is
-- dropped afterwards does not turn the fan's old change into an "outside" one.
function Model:reconcile(ctx)
	local outside = {}
	local may_tell = ctx.why ~= nil or self.phase_ == "online"
	for _, g in ipairs(GROUPS) do
		if not self:group_present(g) then
			self:reconcile_absent(g)
		elseif self:busy(g) then
			self.was_busy[g] = true
			if ctx.why then
				self.owed[g] = ctx.why
			end
		else
			self:reconcile_idle(g, ctx, may_tell, outside)
		end
	end
	if #outside > 0 then
		self:open_fast_window()
		self:emit("outside", outside, self.conf.user_data, self.clock())
	end
end

-- No light kit (H4): what was wanted of the group goes, and whoever waited for it
-- is told it is idle.
function Model:reconcile_absent(g)
	if self:group_has_wanted(g) then
		self:release_group(g, "No light kit")
	end
	if self.was_busy[g] then
		self.was_busy[g] = false
		self:emit("idle", g, self:confirmed() or {})
	end
end

function Model:reconcile_idle(g, ctx, may_tell, outside)
	local v = group_value(g, self.conf)
	if may_tell and v ~= nil and v ~= self.told[g] then
		local why = ctx.why or (ctx.cmd == g and "command") or self.owed[g] or "outside"
		self.told[g] = v
		if why == "outside" then
			outside[#outside + 1] = g
		end
		self:emit("settled", g, self:confirmed(), why)
	end
	if may_tell then
		self.owed[g] = nil
	end
	if self.was_busy[g] then
		self.was_busy[g] = false
		self:emit("idle", g, self:confirmed() or {})
	end
end

-- The command's request is answered: its fields leave flight and a wanted field
-- equal to what was sent is done (a repeated press costs nothing). The light's
-- target is also done when the answer shows it (section 4.3).
function Model:finish_command(rec, norm)
	for f, v in pairs(rec.covers) do
		self.flight[f] = nil
		if self.wanted[f] == v then
			self.wanted[f] = nil
		end
	end
	if rec.step1 then
		self.leveled = true
	end
	if rec.group == "light" then
		local w = self.wanted.light_on
		if w ~= nil and norm.light_on == w then
			self.wanted.light_on = nil
		end
		if self.wanted.light_on == nil then
			self.leveled = false
		end
	end
end

-- Commands dropped ----------------------------------------------------------

function Model:resolve_off(key)
	local o = self.off_req
	self.off_req = nil
	if o then
		local ok, err = pcall(o.cb, key, { which = o.which })
		if not ok then
			self.log.error("the %s callback failed: %s", o.which, tostring(err))
		end
	end
end

function Model:resolve_off_answer()
	local o = self.off_req
	if not o then
		return
	end
	local still = o.which == "away" and self.conf.away or self.conf.learning
	self:resolve_off(still == true and "not_taken" or (o.which == "away" and "away_off" or "learning_off"))
end

-- A group's wanted fields are dropped (the whole target: tried once, ECM P8).
function Model:release_group(g, reason)
	if not self:group_has_wanted(g) then
		return
	end
	local w = {}
	for _, f in ipairs(GROUP_FIELDS[g]) do
		w[f] = self.wanted[f]
		self.wanted[f] = nil
	end
	if g == "light" then
		self.leveled = false
	end
	if reason then
		self.log.warn("%s: %s not sent", reason, describe(g, w))
	end
end

function Model:drop_all(reason)
	for _, g in ipairs(GROUPS) do
		self:release_group(g, reason)
	end
	if self.off_req then
		self:resolve_off("not_answering")
	end
end

-- A request failed (or was given up): its flight ends, and the commands it stood
-- for are dropped (section 4.4).
function Model:release(rec, reason)
	for f in pairs(rec.covers) do
		self.flight[f] = nil
	end
	if rec.group then
		self:release_group(rec.group, reason)
	end
	if rec.tag == "off" and self.off_req then
		self:resolve_off("not_answering")
	end
	if rec.tied then
		for g in pairs(rec.tied) do
			if g == "off" then
				if self.off_req then
					self:resolve_off("not_answering")
				end
			else
				self:release_group(g, reason)
			end
		end
	end
end

-- Failures (section 3.4) ----------------------------------------------------

-- The request on the wire is given up (a new address, Use Selected Fan, a reboot, stop).
-- A command among them has had its one try (ECM P8), so it is dropped rather than left
-- wanted to go out again after the next contact; a read that tied commands to itself
-- leaves them wanted, because the contact that follows is their try.
function Model:abandon_inflight()
	local rec = self.inflight
	self.inflight = nil
	if rec and rec.kind == "command" then
		self:release(rec, "Request given up")
	end
	self.flight = {}
end

-- A request failed. A streak makes the next request a contact; the third failure
-- in a row makes the fan offline, or "not a fan" when they were all answers that
-- were no fan's (section 3.5).
function Model:on_failure(rec, result, outcome)
	local ph = self.phase_
	local down = outcome == "timeout" or outcome == "connect"
	self:release(rec, "Fan not answering")
	if ph == "rebooting" then
		-- Silence is expected here; the 120 s deadline decides (section 6.4).
		if self.reboot_expired then
			return self:expire_reboot()
		end
		self.contact = self.contact or new_contact("reboot")
		self.contact.step, self.contact.ready = "info", false
		self:arm_poll(model.REBOOT_POLL_S * 1000, "reboot")
		self:reconcile({})
		return
	end
	self.failures = self.failures + 1
	self.json_streak = outcome == "json" and (self.json_streak + 1) or 0
	self.fail_kind = down and "timeout" or "data"
	self.first_failure_s = self.first_failure_s or self.clock()
	self.log.warn("fan #%s failed: %s after %.1f s (%d in a row)", tostring(rec.seq),
		outcome == "http" and ("http " .. tostring(result.code)) or outcome, (result.ms or 0) / 1000, self.failures)
	if not self.contact then
		self.contact = new_contact("recover")
	end
	local c = self.contact
	c.step, c.ready, c.probe = "info", false, false
	if self.failures >= model.OFFLINE_AFTER then
		if self.json_streak >= model.OFFLINE_AFTER then
			self:go_verdict("notfan")
			return
		end
		if ph == "online" or ph == "waiting" or ph == "offline" or down then
			self:go_offline(self.fail_kind)
		end
	end
	local delay
	if IDENTITY_PHASES[self.phase_] then
		delay = model.IDENTITY_POLL_S
	else
		delay = model.BACKOFF_S[math.min(self.failures, #model.BACKOFF_S)]
	end
	self:arm_poll(delay * 1000, "backoff")
	self:reconcile({})
end

function Model:go_offline(kind)
	local was = self.phase_
	local since = self.first_failure_s or self.clock()
	self:drop_all("Fan not answering")
	if was ~= "offline" then
		self.offline_at_ms = self.now()
		self.log.warn("Fan offline: %d failures since %s", self.failures, hhmm(since))
	end
	self:set_phase("offline", { failure = kind, since = since })
end

-- Another fan answers at the address (section 3.5): nothing is sent to it, the
-- last state stays, and the identity is read again every 60 s.
function Model:go_foreign(other_id, rec)
	self:release(rec, "Another fan answers")
	self:drop_all("Another fan answers")
	local ph = self.phase_
	if ph ~= "foreign" or self.detail_.other_client_id ~= other_id then
		self.log.warn("Another fan (%s) answers at %s", suffix(other_id), tostring(self.address))
	end
	self.contact = new_contact("identity")
	self.contact.ready = false
	self:arm_poll(model.IDENTITY_POLL_S * 1000, "identity")
	self:set_phase("foreign", { other_client_id = other_id })
	self:reconcile({})
end

-- Gen 4 or not a fan: nothing is ever sent; /mf is read every 60 s without probing
-- again (section 3.6).
function Model:go_verdict(verdict)
	local ph = self.phase_
	self:note_alive()
	self:drop_all("Not a Gen 1-3 fan")
	if ph ~= verdict then
		self.log.warn("%s answers as %s; nothing is sent", tostring(self.address),
			verdict == "gen4" and "a Gen 4 fan" or "something that is not a Modern Forms fan")
	end
	self.contact = new_contact("identity")
	self.contact.ready = false
	self:arm_poll(model.IDENTITY_POLL_S * 1000, "identity")
	self:set_phase(verdict)
	self:reconcile({})
end

-- HTTP 404 on /mf: a Gen 4 fan (section 3.6). The probe goes once per contact; a
-- phase that already holds the verdict keeps it without probing again.
function Model:on_404(rec)
	local ph = self.phase_
	self:release(rec, "Fan not answering")
	if ph == "gen4" or ph == "notfan" then
		self:note_alive()
		self.contact = self.contact or new_contact("identity")
		self.contact.step, self.contact.ready = "info", false
		self:arm_poll(model.IDENTITY_POLL_S * 1000, "identity")
		self:reconcile({})
		return
	end
	self.log.debug("HTTP 404 on /mf: probing for a Gen 4 fan")
	self.contact = self.contact or new_contact("recover")
	self.contact.step, self.contact.ready, self.contact.probe = "info", true, true
	self:reconcile({})
end

function Model:after_probe(rec, result, outcome)
	if outcome == "timeout" or outcome == "connect" then
		return self:on_failure(rec, result, outcome)
	end
	if result.json ~= nil and self.wire.is_g4(result.json) then
		return self:go_verdict("gen4")
	end
	return self:go_verdict("notfan")
end

-- Contact completion --------------------------------------------------------

-- The contact's state step answered: the identity is settled (pinned, followed to
-- a new address, or confirmed) and the contact is over. Returns the `why` the
-- group reports carry ("start" the first time, "online" after a gap), or nil.
function Model:finish_contact(c, st)
	self.contact = nil
	self.clamped = {}
	local info = c.info or {}
	local changed = false
	if not self.pin and info.client_id then
		self.pin = {
			client_id = info.client_id,
			mac = info.mac,
			generation = st.generation,
			address = self.address,
			learned = self.clock(),
		}
		self.pin_saved = true
		self:persist("mf_identity", copy(self.pin))
		changed = true
		self:emit("result", "learned", { client_id = self.pin.client_id, generation = self.pin.generation,
			address = self.address, mac = self.pin.mac })
	else
		local pin = self.pin
		if pin.mac == nil and info.mac ~= nil then
			pin.mac, changed = info.mac, true
		end
		if st.generation ~= nil and pin.generation ~= st.generation then
			pin.generation, changed = st.generation, true
		end
		if pin.address ~= self.address then
			local moved = pin.address ~= nil
			pin.address, changed = self.address, true
			if moved then
				self:emit("result", "moved", { client_id = pin.client_id, address = self.address })
			end
		end
		if not self.pin_saved then
			changed = true
		end
		if changed then
			self.pin_saved = true
			self:persist("mf_identity", copy(pin))
		end
	end
	if changed then
		self:announce_info()
	end
	-- The first contact reports every group ("start", R6). Later, a contact that ends a gap
	-- (a new address, offline, another fan, a reboot) reports what changed meanwhile as
	-- "online" (R8); one that only follows a failure streak shorter than offline is an
	-- ordinary read, and a change it finds is somebody else's.
	if not self.reported then
		return "start"
	elseif self.phase_ ~= "online" then
		return "online"
	end
	return nil
end

function Model:enter_online(c)
	local old = self.phase_
	self:cancel_timer("reboot")
	self.reb, self.reboot_expired = nil, false
	if old == "offline" and self.offline_at_ms then
		local secs = math.floor((self.now() - self.offline_at_ms) / 1000)
		if secs < 60 then
			self.log.warn("Fan online again after %d s", secs)
		else
			self.log.warn("Fan online again after %d min", math.floor(secs / 60))
		end
	end
	self.offline_at_ms = nil
	self:set_phase("online", old ~= "online" and { since = self.clock() } or nil)
	if old ~= "online" and c then
		self:open_fast_window()
	end
end

-- Commands (section 4.3, 9.5) -----------------------------------------------

function Model:refusal()
	local ph = self.phase_
	if ph == nil or ph == "unset" then
		return self.typed ~= "" and "invalid address" or "unset"
	elseif ph == "foreign" or ph == "gen4" or ph == "notfan" or ph == "rebooting" then
		return ph
	end
	return nil
end

function Model:missing_key(...)
	for _, key in ipairs({ ... }) do
		if self.missing_set[key] then
			return key
		end
	end
	return nil
end

function Model:validate(fields)
	if type(fields) ~= "table" then
		return nil, "range"
	end
	local plan, any = {}, false
	if fields.fan_on ~= nil or fields.speed ~= nil then
		any = true
		local on = fields.fan_on
		if on == nil then
			on = true
		end
		if type(on) ~= "boolean" then
			return nil, "range"
		end
		if on and not is_int(fields.speed, 1, 6) then
			return nil, "range"
		end
		local key
		if on then
			key = self:missing_key("fanOn", "fanSpeed")
		else
			key = self:missing_key("fanOn")
		end
		if key then
			return nil, "no " .. key
		end
		plan.fan = on and { fan_on = true, speed = fields.speed } or { fan_on = false }
	end
	if fields.direction ~= nil then
		any = true
		if fields.direction ~= "forward" and fields.direction ~= "reverse" then
			return nil, "range"
		end
		local key = self:missing_key("fanDirection")
		if key then
			return nil, "no " .. key
		end
		plan.direction = { direction = fields.direction }
	end
	if fields.light_on ~= nil or fields.level ~= nil then
		any = true
		if self.has_light == false then
			return nil, "no light kit"
		end
		local on = fields.light_on
		if on == nil then
			on = true
		end
		if type(on) ~= "boolean" then
			return nil, "range"
		end
		if on and fields.level ~= nil and not is_int(fields.level, 1, 100) then
			return nil, "range"
		end
		local key = self:missing_key("lightOn")
		if on and fields.level ~= nil then
			key = key or self:missing_key("lightBrightness")
		end
		if key then
			return nil, "no " .. key
		end
		plan.light = on and { light_on = true, level = fields.level } or { light_on = false }
	end
	if not any then
		return nil, "range"
	end
	return plan
end

-- Wants fields of any of the three groups (section 9.5): { fan_on, speed } |
-- { direction } | { light_on, level }. The latest wanted fields of a group replace
-- the earlier ones; a wanted field is sent even when it equals the confirmed
-- state (V8). Returns true, or false and why.
function Model:want(fields)
	if self.stopped then
		return false, "unset"
	end
	local why = self:refusal()
	if why then
		return false, why
	end
	local plan, reason = self:validate(fields)
	if not plan then
		return false, reason
	end
	for g, p in pairs(plan) do
		for _, f in ipairs(GROUP_FIELDS[g]) do
			self.wanted[f] = p[f]
		end
		if g == "light" and p.light_on == false then
			self.leveled = false
		end
		self.was_busy[g] = true
	end
	self:pump()
	self:flush()
	return true
end

-- Starting, stopping, addresses ---------------------------------------------

-- Everything in flight or armed is given up: a new address, a stop.
function Model:abandon()
	self:abandon_inflight()
	for name in pairs(self.timers) do
		self:cancel_timer(name)
	end
	self.contact = nil
	self.poll_due = false
	self.reb, self.reboot_req, self.reboot_expired = nil, false, false
	local u = self.use
	self.use = nil
	if u then
		-- A follow given up by the owner's edit or stop() hears no_answer (ECA CA2).
		self:give_up_use(u, "no_answer")
	end
end

function Model:begin_at(text, why)
	text = trim(text)
	self:abandon()
	self.failures, self.json_streak = 0, 0
	self.fail_kind, self.first_failure_s = nil, nil
	self.clamped = {}
	self.settle, self.held = {}, {}
	self.leveled = false
	if text == "" or not self.wire.ipv4(text) then
		self.address = nil
		self.typed = text
		self.t:set_address(nil)
		self:drop_all("No fan address")
		self:set_phase("unset")
		self:reconcile({})
		return text ~= "" and "invalid" or nil
	end
	self.address = self.wire.ipv4(text)
	self.typed = ""
	self.t:set_address(self.address)
	self.contact = new_contact(why)
	self:set_phase("waiting")
	self:reconcile({})
	self:pump()
	return nil
end

local function pin_from(value)
	if type(value) ~= "table" or type(value.client_id) ~= "string" or value.client_id == "" then
		return nil
	end
	return {
		client_id = value.client_id,
		mac = value.mac,
		generation = value.generation,
		address = value.address,
		learned = value.learned,
	}
end

-- Late init: loads mf_identity (else the pin parsed from the Fan ID row, which is
-- checked at the first contact, ECC D10), mf_info and mf_online, then makes a
-- contact if the address is usable. Returns "invalid" for text that is not an address.
function Model:start(address, pin_from_row)
	self.stopped = false
	local stored = pin_from(self:recall("mf_identity"))
	if stored then
		self.pin, self.pin_saved = stored, true
	else
		self.pin, self.pin_saved = pin_from(pin_from_row), false
	end
	local info = self:recall("mf_info")
	if type(info) == "table" then
		self.info_ = copy(info)
		self.has_light = type(info.light_type) == "string" and info.light_type:find("%S") ~= nil
	end
	self.online_flag = self:recall("mf_online") == true
	local result = self:begin_at(address, "start")
	self:flush()
	return result
end

function Model:stop()
	if self.stopped then
		return
	end
	self:abandon()
	self.wanted, self.flight = {}, {}
	if self.off_req then
		self:resolve_off("not_answering")
	end
	self.stopped = true
	self.events = {}
	pcall(self.t.stop, self.t)
end

-- `Fan Address` edited (section 3.5): empty stops every request (the pin is kept,
-- typing the old address back resumes); text that is not an IPv4 address sends
-- nothing; otherwise a new epoch and a contact. Returns nil or "invalid".
function Model:set_address(text)
	local result = self:begin_at(text, "address")
	self:flush()
	return result
end

-- Use Selected Fan (section 3.5) --------------------------------------------

-- One info read at `address`, nothing else sent; cb(result_key, args) with L2-L7
-- and L21 (texts.result). `mac12` is the pick's MAC, when it was a pick.
function Model:use_fan(address, mac12, cb)
	cb = cb or noop
	local addr = type(address) == "string" and self.wire.ipv4(address) or nil
	if not addr or self.stopped then
		pcall(cb, "nothing_to_use", { find_fans = true })
		return
	end
	self:begin_use({ address = addr, mac12 = upper(mac12), cb = cb })
end

-- The one info read of Use Selected Fan, and of a follow (address-follow-design 2.2):
-- a read already under way is given up (a click takes a follow's place, ECA CA6), so is
-- the request on the wire, and the transport points at the target with a new epoch.
-- The read goes before anything else (next_request); nothing else goes while it is out.
function Model:begin_use(u)
	local old = self.use
	self.use = nil
	if old then
		self:give_up_use(old, old.follow and "busy" or "no_answer")
	end
	self:abandon_inflight()
	self:reconcile({})
	self:cancel_timer("poll")
	self:cancel_timer("retry")
	self.poll_due = false
	if self.reboot_req then
		-- A reboot that has not gone out yet must not follow the transport to another address.
		self.reboot_req, self.reb = false, nil
		self:cancel_timer("reboot")
		self.log.warn("Reboot Fan cancelled before it was sent: Use Selected Fan came first")
		self:set_phase("waiting")
	end
	u.prev_address, u.sent = self.address, false
	self.use = u
	self.t:set_address(u.address)
	self:pump()
	self:flush()
end

-- A read under way is given up (another click, the owner's edit, stop()): its callback
-- hears it once. A follow asked for from inside that callback is refused (busy): the
-- caller has not finished changing the model, and would leave such a read stranded.
function Model:give_up_use(u, key)
	local was = self.giving_up
	self.giving_up = true
	if u.follow then
		self:finish_use(u, key, { address = u.address })
	else
		pcall(u.cb, key, { address = u.address })
	end
	self.giving_up = was
end

function Model:finish_use(u, key, args)
	local ok, err = pcall(u.cb, key, args)
	if not ok then
		self.log.error("the %s callback failed: %s", u.follow and "follow" or "Use Selected Fan", tostring(err))
	end
end

-- Use Selected Fan's verdict on its read (section 3.5): L2 to L6 and L21.
function Model:use_verdict(u, result, outcome)
	local key, info
	local args = { address = u.address }
	if outcome == "timeout" or outcome == "connect" then
		key = "no_answer"
	elseif outcome ~= "ok" then
		key = "not_a_fan"
	else
		info = self.wire.info(result.json)
		if not info or not info.mac then
			key = "not_a_fan"
		elseif u.mac12 and upper(info.mac) ~= u.mac12 then
			key = "not_picked"
		else
			args.client_id, args.generation = info.client_id, self.pin and self.pin.generation
			if self.pin and self:same(self.pin, info.client_id, info.mac) then
				key = (u.address == u.prev_address) and "already" or "moved"
			else
				key = "now_using"
				args.was = self.pin and self.pin.client_id
			end
		end
	end
	return key, info, args
end

function Model:after_use(result, outcome)
	local u = self.use
	self.use = nil
	if not u then
		return
	end
	local key, info, args
	if u.follow then
		local ok, k, i, a = pcall(self.follow_verdict, self, u, result, outcome)
		if ok then
			key, info, args = k, i, a
		else
			-- An answer that cannot be read shows no pinned fan; the callback is still told once.
			self.log.error("the follow's answer could not be read: %s", tostring(k))
			key, args = "not_same", { address = u.address }
		end
	else
		key, info, args = self:use_verdict(u, result, outcome)
	end
	if key == "moved" or key == "now_using" or key == "followed" then
		-- A follow is adopted as the "moved" path is (address-follow-design F6), never re-pointed.
		self:adopt(u, key == "now_using" and key or "moved", info)
	else
		-- Nothing changes: the transport goes back to where it was, with a contact.
		self.t:set_address(u.prev_address)
		if u.prev_address ~= nil then
			self.contact = new_contact("resume")
		end
	end
	self:finish_use(u, key, args)
end

-- Use Selected Fan accepted the fan at the new address: the same fan followed
-- there (L2), or another fan (or the first) re-pointed to (L3). The device, its
-- links and its programming stay; the contact that follows reads the state.
function Model:adopt(u, key, info)
	self.address = u.address
	self.typed = ""
	self.failures, self.json_streak = 0, 0
	self.fail_kind, self.first_failure_s = nil, nil
	if key == "moved" then
		self.pin.address = u.address
	else
		self:drop_all("Another fan is in use")
		self.pin = { client_id = info.client_id, mac = info.mac, address = u.address, learned = self.clock() }
		self.info_ = nil
		self.conf, self.known, self.has_wind = {}, false, nil
		self.missing, self.missing_set = nil, {}
		self.settle, self.held, self.owed = {}, {}, {}
	end
	self.pin_saved = true
	self:persist("mf_identity", copy(self.pin))
	self:record_info(info)
	self.info_at_ms = self.now()
	self.contact = new_contact(key == "moved" and "address" or "repoint")
	self.contact.info, self.contact.step = info, "state"
	self:set_phase("waiting")
	self:reconcile({})
	self:announce_info()
end

-- Following the pinned fan (address-follow-design 2.2) -----------------------

-- RFC 1918's private blocks and the link-local block (RFC 3927): the only addresses a follow
-- reads (F8). discovery.candidates checks the same; this is the last step before the request.
local function private_address(addr)
	local a, b = addr:match("^(%d+)%.(%d+)%.%d+%.%d+$")
	a, b = tonumber(a), tonumber(b)
	if not a then
		return false
	end
	return a == 10 or (a == 172 and b >= 16 and b <= 31) or (a == 192 and b == 168) or (a == 169 and b == 254)
end

-- Use Selected Fan's one info read at `address`, restricted to the pinned fan, for
-- fan/follow.lua. `mac12` is the MAC the fan's multicast DNS answer carried there (F1).
-- cb(key, args), once, through pcall:
--   "followed"  { address, was, client_id }: the pinned fan answers there. Adopted as the
--               "moved" path does (F6): the transport stays at `address` on the epoch its
--               read began, pin.address, mf_identity and the firmware record are stored,
--               the phase is waiting, all before the callback; the contact follows.
--   "not_same"  { address, other_client_id }: another fan, a MAC that is not the pin's, an
--               answer that is no fan's (a 404, no client id or no MAC), or an address that
--               cannot be the pinned fan's new one (not IPv4, the one in use).
--   "no_answer" { address }: silence or an error (FA15: worth a read later), or the owner's
--               edit or stop() gave the read up (ECA CA2).
--   "busy"      { address }: refused at once (F2): stopped, a read under way, a phase that is
--               not offline-like (rebooting among them), no pin with a MAC; or a Use Selected
--               Fan click took the read's place (ECA CA6).
-- All but "followed" leave the model as a failed Use Selected Fan does: the previous address
-- back, with a contact. Never "now_using", never another fan pinned, never a Last Action:
-- the driver writes L30.
function Model:follow(address, mac12, cb)
	cb = type(cb) == "function" and cb or noop
	local addr = type(address) == "string" and self.wire.ipv4(address) or nil
	local args = { address = addr or address }
	local tell = { cb = cb, follow = true }
	local pin = self.pin
	if self.stopped or self.use or self.giving_up or not OFFLINE_LIKE[self.phase_] or not (pin and pin.mac) then
		return self:finish_use(tell, "busy", args)
	end
	local mac = self.wire.mac12(mac12)
	if not addr or not private_address(addr) or addr == self.address or not mac or mac ~= self.wire.mac12(pin.mac) then
		-- F4, F8: nothing is read where the pinned fan's own answer did not put it, and never
		-- outside the private and link-local blocks, whatever the caller was told.
		return self:finish_use(tell, "not_same", args)
	end
	self:begin_use({ address = addr, mac12 = mac, cb = cb, follow = true })
end

-- F4 (ECA 3.4 step 2): accepted only as the pinned fan, by its client id (case-insensitive)
-- and the pin's MAC, which must also be the one its announcement carried. Silence and an
-- error may pass (no_answer); a 404 (Gen 4 or no fan, FA14), an answer that is no fan's,
-- another fan and a mismatch will not (not_same).
function Model:follow_verdict(u, result, outcome)
	local args = { address = u.address }
	if outcome == "timeout" or outcome == "connect" or outcome == "http" or outcome == "empty" then
		return "no_answer", nil, args
	elseif outcome ~= "ok" then
		return "not_same", nil, args
	end
	local w, pin = self.wire, self.pin
	local info = w.info(result.json)
	if type(info) ~= "table" then
		return "not_same", nil, args
	end
	local mac = w.mac12(info.mac)
	local same = pin ~= nil and w.same_fan(pin, info.client_id)
	if not (same and mac ~= nil and mac == w.mac12(pin.mac) and mac == u.mac12) then
		if not same then
			args.other_client_id = info.client_id
		end
		return "not_same", nil, args
	end
	return "followed", info, { address = u.address, was = u.prev_address, client_id = pin.client_id }
end

-- Reboot Fan and the fan's automations (V22, V23) ---------------------------

-- Only while online (section 6.4): the reboot request goes first, the outcome is
-- ignored, and the info read every 10 s for 120 s is the way back.
function Model:reboot(cb)
	cb = cb or noop
	local ph = self.phase_
	local key, args = "reboot_refused", { address = self.address }
	-- With a Use Selected Fan read under way the transport may be about to point elsewhere,
	-- and a reboot must never reach a fan nobody has verified (L13).
	if ph == "online" and not self.use then
		local sent = self.clock()
		self:drop_all("Rebooting the fan")
		self:abandon_inflight()
		self:cancel_timer("poll")
		self.poll_due = false
		self.reb = { sent_s = sent }
		self.reboot_req, self.reboot_expired = true, false
		self.contact = new_contact("reboot")
		self.contact.ready = false
		self:set_phase("rebooting", { sent = sent, since = sent })
		self:reconcile({})
		self:set_timer("reboot", model.REBOOT_WINDOW_S * 1000, function()
			self:reboot_deadline()
		end)
		key, args = "reboot_sent", { at = sent, now = sent }
		self:pump()
	elseif ph == "rebooting" then
		key, args = "reboot_pending", { at = self.reb and self.reb.sent_s, now = self.clock() }
	elseif ph == "offline" then
		key, args = "reboot_offline", {}
	end
	local ok, err = pcall(cb, key, args)
	if not ok then
		self.log.error("the Reboot Fan callback failed: %s", tostring(err))
	end
	self:flush()
end

function Model:after_reboot_request(outcome)
	self.log.debug("the reboot request ended: %s (ignored)", outcome)
	if self.phase_ == "rebooting" then
		self.contact = self.contact or new_contact("reboot")
		self.contact.step, self.contact.ready = "info", false
		self:arm_poll(model.REBOOT_POLL_S * 1000, "reboot")
	end
end

function Model:reboot_deadline()
	if self.phase_ ~= "rebooting" then
		return
	end
	if self.inflight then
		-- Decided on its result: an answer in time still counts.
		self.reboot_expired = true
		return
	end
	self:expire_reboot()
	self:flush()
end

function Model:expire_reboot()
	local sent = self.reb and self.reb.sent_s or self.clock()
	self.reb, self.reboot_expired = nil, false
	self.failures = model.OFFLINE_AFTER
	self.first_failure_s = sent
	self.fail_kind = "timeout"
	self.contact = self.contact or new_contact("recover")
	self.contact.step, self.contact.ready, self.contact.probe = "info", false, false
	self:go_offline("timeout")
	self:arm_poll(model.BACKOFF_S[#model.BACKOFF_S] * 1000, "backoff")
	self:reconcile({})
end

-- Turn Off Away Mode / Turn Off Adaptive Learning: a click, never automatic.
-- cb(result_key, args): "away_off"/"learning_off", "away_already"/"learning_already",
-- "not_taken" (the answer still shows it on) or "not_answering".
function Model:turn_off(which, cb)
	cb = cb or noop
	if which ~= "away" and which ~= "learning" then
		pcall(cb, "not_answering", { which = which })
		return
	end
	local function answer(key)
		local ok, err = pcall(cb, key, { which = which })
		if not ok then
			self.log.error("the turn_off callback failed: %s", tostring(err))
		end
	end
	if self.phase_ ~= "online" then
		return answer("not_answering")
	end
	local current = which == "away" and self.conf.away or self.conf.learning
	if current == false then
		return answer(which .. "_already")
	end
	if self.off_req then
		self:resolve_off("not_answering")
	end
	self.off_req = { which = which, cb = cb }
	self:pump()
	self:flush()
end

-- Dev Request (section 12): one request through the model's slot, only while the
-- fan is online and nothing else is due. The answer goes to cb unread; a state
-- read follows soon, so the model sees what the request did.
function Model:request(req, cb)
	if type(req) ~= "table" or type(cb) ~= "function" then
		return nil, "bad request"
	end
	local ph = self.phase_
	if self.stopped or ph == nil or ph == "unset" then
		return nil, "no address"
	end
	if ph ~= "online" or self.contact or self.inflight or self.use or self.t:busy() or self:has_commands() then
		return nil, "busy"
	end
	local rec = { kind = req.kind, tag = "dev", sent = {}, covers = {}, epoch = self.t.epoch, dev_cb = cb }
	self.inflight = rec
	local seq, why = self.t:send({ kind = req.kind, path = req.path, body = req.body, timeout = req.timeout },
		function(result)
			self:on_result(rec, result)
		end)
	if not seq then
		self.inflight = nil
		return nil, why
	end
	rec.seq = seq
	self.seq = seq
	return seq
end

function Model:after_dev(rec, result)
	local ok, err = pcall(rec.dev_cb, result)
	if not ok then
		self.log.error("the Dev Request callback failed: %s", tostring(err))
	end
	self:open_fast_window()
	self:arm_next_poll()
end

return model
