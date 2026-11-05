-- fan/rename.lua: names the driver's two Composer items after the fan's
-- product name (docs/fan-name-design.md, decisions N4, N5 and N7 and section
-- 2.2; the rules are docs/edge-cases-rename.md, section 5).
--
-- Only an owner's click starts a run, and a run is one of two kinds:
--   guarded  Use Selected Fan. Both items are renamed only while both are ours,
--            that is while each still carries a name a build shipped or the one
--            this job last wrote and Director confirmed (ECR 5.3). A name anyone
--            typed is never overwritten, and neither item is renamed then.
--   forced   Name Items After Fan (ECR 5.6). Both items are renamed whatever
--            they are called.
-- In both kinds an item that already has its target name gets no call, and
-- nothing is renamed unless the fan type has a name (N1).
--
-- Everything that touches Director is an option (section 9.1 of
-- docs/v1-design.md), so the spec runs on hand-made fakes. Each option is called
-- in pcall, one that is missing counts as one that failed, and nothing in here
-- raises into Director:
--
--   rename.new({
--       ids = fn() -> fan_id, light_id,       -- the two proxy ids (ECR RC18); nil for one not found
--       display_name = fn(id) -> string|nil,  -- C4:GetDeviceDisplayName [API 32/_6]
--       rename = fn(id, name),                -- C4:RenameDevice [API 22/_32]; it returns nothing
--       fan_type = fn() -> string|nil,        -- the stored fan type, so known while the fan is silent
--       pinned = fn() -> bool,                -- a fan is set up
--       lookup = fn(fan_type) -> name|nil,    -- fan/names.lua: the product name of that exact type
--       light = fn(name) -> name,             -- fan/names.lua: the light item's name
--       defaults = { { fan = ..., light = ... }, ... },    -- every pair of names a build shipped
--       timer = fn(ms, cb) -> object with :Cancel(),
--       store = { get = fn(key), set = fn(key, value) },   -- the record, under rename.KEY
--       now = fn() -> epoch seconds,          -- default os.time
--       log = log,                            -- default common.log
--       confirm_ms = 2000,                    -- how long after the calls the names are read back
--   })
--
--   job:run(mode, done)   mode "guarded" or "forced" (anything else is taken as guarded: never
--                         forced by accident); done(outcome, args) is called exactly once:
--
--       outcome      args                                   when
--       renamed      { fan, light }                         both items read back with their new names
--       same         { fan, light }                         both already had them; nothing was called
--       kept         { fan_live, fan_to, light_live, light_to }
--                                                           guarded: an item is not ours; nothing was called
--       no_name      { fan_type }                           no name for this fan type
--       no_type      {}                                     no fan type is known yet
--       no_ids       {}                                     the two items were not found
--       unconfirmed  {}                                     the read-back did not show every new name (also a
--                                                           run that could not start: no timer; see below)
--       no_pin       {}                                     no fan is set up
--       busy         {}                                     another run is pending; it is not disturbed
--
--   job:plan(mode)        what a run would decide now, with no rename, no timer and no record:
--                         { mode, outcome, fan_type, fan_id, light_id, fan_live, light_live,
--                           fan_to, light_to, fan_ours, light_ours, fan_call, light_call }
--                         (Dev Names Plan). Its outcome is the one a run ends in if Director
--                         confirms every call; "busy" while a run is pending.
--   job:busy()            a run is pending
--   job:stop()            cancels every timer and forgets the pending run: its done is never called
--                         and nothing is recorded (OnDriverDestroyed)
--
-- Timing (ECR RC19). The job never runs inside the call that asks for it: run()
-- only arms a timer of START_MS, and every decision and every done() comes from a
-- timer callback, the busy answer included. The calls are made in that callback,
-- the fan item first and the light item right after it, each in pcall, and
-- confirm_ms later the names are read back. Only what Director shows is recorded
-- (one record, {fan, light, at}, an item that did not confirm keeping what it had),
-- and the outcome is renamed or unconfirmed. Only when no timer can be armed is
-- done() called inside run(): a busy answer is then given at once, and a run that
-- could not start ends unconfirmed with nothing renamed. A timer that cannot be armed
-- for the read-back reads the names back at once instead.

local rename = {}
rename.__index = rename

rename.KEY = "mf_names" -- the one persisted value (ECR 5.3, section 8 of docs/v1-design.md)
rename.START_MS = 1 -- the job starts from a timer, never inside the click's call (ECR RC19)
rename.CONFIRM_MS = 2000 -- the read-back (ECR 5.7, step 5)
rename.OUTCOMES = { "renamed", "same", "kept", "no_name", "no_type", "no_ids", "unconfirmed", "no_pin", "busy" }

local NAME_SHOWN = 60 -- a name is cut to this many characters in a log line
local TYPE_SHOWN = 40 -- so is the fan type, which the fan itself supplies

-- Small helpers ---------------------------------------------------------------------

local function trim(text)
	return (text:match("^%s*(.-)%s*$"))
end

-- fn(...) in pcall; a function that is not there fails like one that raises.
local function try(fn, ...)
	if type(fn) ~= "function" then
		return false, "not given"
	end
	return pcall(fn, ...)
end

-- Control characters out, so nothing the fan or an owner typed can forge a second
-- log line or break a row of Composer; cut at `max`.
local function plain(text, max)
	text = text:gsub("%c", "?")
	if #text > max then
		text = text:sub(1, max) .. "..."
	end
	return text
end

-- A name as a log line shows it: in quotes; a bare ? when Director gave none.
local function shown(value)
	if type(value) ~= "string" then
		return "?"
	end
	return '"' .. plain(value, NAME_SHOWN) .. '"'
end

local function id_text(id)
	return id ~= nil and tostring(id) or "none"
end

-- A device id: a positive whole number, given as a number or as digits. nil for
-- anything else, so a wrong shape is "not found", never a guess.
local function id_of(value)
	if type(value) == "string" then
		value = value:match("^%s*(%d+)%s*$")
	end
	local n = tonumber(value)
	if n == nil or n ~= n or n < 1 or n == math.huge or n ~= math.floor(n) then
		return nil
	end
	return n
end

-- A name Director may be handed: not blank, no control character, no blank at
-- either end. fan/names.lua is the authority on ECR 5.4; this only keeps a bad
-- string from reaching C4:RenameDevice or a log line if it ever fails.
local function usable(name)
	return type(name) == "string" and name:find("%S") ~= nil and not name:find("%c") and name == trim(name)
end

-- The instance ------------------------------------------------------------------------

function rename.new(opts)
	opts = type(opts) == "table" and opts or {}
	local confirm = tonumber(opts.confirm_ms)
	if confirm == nil or confirm ~= confirm or confirm < 1 then
		confirm = rename.CONFIRM_MS
	end
	return setmetatable({
		ids = opts.ids,
		display_name = opts.display_name,
		do_rename = opts.rename,
		fan_type = opts.fan_type,
		pinned = opts.pinned,
		lookup = opts.lookup,
		light = opts.light,
		defaults = type(opts.defaults) == "table" and opts.defaults or {},
		timer = opts.timer,
		store = opts.store,
		now = opts.now or os.time,
		log = opts.log or require("common.log"),
		confirm_ms = confirm,
		active = nil, -- the run in progress: { mode, done, plan }
		timers = {}, -- armed and not yet fired: [entry] = true, entry.handle:Cancel()
		gen = 0, -- stop() moves it on; a timer armed before then does nothing
	}, rename)
end

local function say(self, level, template, ...)
	local sink = self.log
	local fn = type(sink) == "table" and sink[level] or nil
	if type(fn) ~= "function" then
		return
	end
	local ok, text = pcall(string.format, template, ...)
	pcall(fn, "%s", ok and text or tostring(template))
end

-- A one-shot timer for fn that stop() makes void even if the timer fires anyway.
-- false when none could be armed.
local function arm(self, ms, fn)
	local gen = self.gen
	local entry = {}
	local ok, handle = try(self.timer, ms, function()
		entry.fired = true
		self.timers[entry] = nil
		if self.gen == gen then
			fn()
		end
	end)
	if not ok then
		say(self, "warn", "names: no timer for %d ms: %s", ms, tostring(handle))
		return false
	end
	-- A timer that fired inside its own arming call has nothing left to cancel.
	if not entry.fired then
		entry.handle = handle
		self.timers[entry] = true
	end
	return true
end

local function clock(self)
	local ok, value = try(self.now)
	if ok and type(value) == "number" and value == value then
		return value
	end
	return os.time()
end

-- What the job knows of the two items (ECR 5.3) ----------------------------------------

-- The name Composer shows for an item, trimmed; nil when it cannot be read.
local function live(self, id)
	local ok, name = try(self.display_name, id)
	if not ok then
		say(self, "debug", "names: the name of item %s could not be read: %s", tostring(id), tostring(name))
		return nil
	end
	if type(name) ~= "string" then
		return nil
	end
	return trim(name)
end

-- The record of what this job last wrote and Director confirmed: { fan, light } of
-- what was stored, only the fields that are strings (a record of another shape counts
-- as none: the guard then trusts the shipped names alone, the safe direction).
local function record(self)
	local store = self.store
	if type(store) ~= "table" then
		return nil
	end
	local ok, value = try(store.get, rename.KEY)
	if not ok then
		say(self, "warn", "names: the record could not be read: %s", tostring(value))
		return nil
	end
	if type(value) ~= "table" then
		return nil
	end
	local out = {}
	if type(value.fan) == "string" then
		out.fan = value.fan
	end
	if type(value.light) == "string" then
		out.light = value.light
	end
	return out
end

-- Ours (ECR 5.3): the live name equals that item's name in any shipped pair, or the
-- name in the record. An exact match: a numbered default, another case or a
-- neighbouring name is the owner's (ECR RC26).
local function ours(self, live_name, item, saved)
	if live_name == nil then
		return false
	end
	if saved and saved[item] == live_name then
		return true
	end
	for _, pair in ipairs(self.defaults) do
		if type(pair) == "table" and pair[item] == live_name then
			return true
		end
	end
	return false
end

-- The decision (ECR 5.7, steps 1 to 3) ---------------------------------------------------

-- What a run would do now. No call, no timer, no write: run() acts on this table in
-- its timer, plan() hands it out. Everything it learned stays in it, so a refusal can
-- say how far it got.
local function evaluate(self, mode)
	local plan = { mode = mode }

	local ok, pinned = try(self.pinned)
	if not ok then
		say(self, "warn", "names: whether a fan is set up could not be read: %s", tostring(pinned))
	end
	if not (ok and pinned) then
		plan.outcome = "no_pin"
		return plan
	end

	local got, raw = try(self.fan_type)
	local fan_type = got and type(raw) == "string" and trim(raw) or ""
	if fan_type == "" then
		plan.outcome = "no_type"
		return plan
	end
	-- The type is the fan's own text: it is shown and logged cleaned, but looked up as it is.
	plan.fan_type = plain(fan_type:sub(1, TYPE_SHOWN), TYPE_SHOWN)

	local named, name = try(self.lookup, raw)
	if not named then
		say(self, "warn", "names: the name table failed for fan type %s: %s", plan.fan_type, tostring(name))
	end
	local lit, light_name
	if named and usable(name) then
		lit, light_name = try(self.light, name)
		if not lit then
			say(self, "warn", "names: the light item's name failed for %s: %s", shown(name), tostring(light_name))
		end
	end
	if not (named and usable(name) and lit and usable(light_name)) then
		plan.outcome = "no_name"
		return plan
	end
	plan.fan_to, plan.light_to = name, light_name
	say(self, "debug", "names: fan type %s is named %s, the light %s", plan.fan_type, shown(name), shown(light_name))

	local found, fan_id, light_id = try(self.ids)
	if found then
		plan.fan_id, plan.light_id = id_of(fan_id), id_of(light_id)
	end
	say(self, "debug", "names: items found: fan %s, light %s", id_text(plan.fan_id), id_text(plan.light_id))
	if not plan.fan_id or not plan.light_id or plan.fan_id == plan.light_id then
		plan.outcome = "no_ids"
		return plan
	end

	plan.fan_live, plan.light_live = live(self, plan.fan_id), live(self, plan.light_id)
	local saved = record(self)
	plan.fan_ours = ours(self, plan.fan_live, "fan", saved)
	plan.light_ours = ours(self, plan.light_live, "light", saved)
	say(self, "debug", "names: fan item %s is %s (%s), light item %s is %s (%s)", id_text(plan.fan_id),
		shown(plan.fan_live), plan.fan_ours and "ours" or "not ours", id_text(plan.light_id), shown(plan.light_live),
		plan.light_ours and "ours" or "not ours")

	-- An item that has its target name needs no call, ours or not. Both of them: nothing to do.
	local fan_same, light_same = plan.fan_live == plan.fan_to, plan.light_live == plan.light_to
	if fan_same and light_same then
		plan.outcome = "same"
		return plan
	end
	-- Both or neither (N5): one name that is not ours keeps both items as they are.
	if mode == "guarded" and not (plan.fan_ours and plan.light_ours) then
		plan.outcome = "kept"
		return plan
	end
	plan.outcome = "renamed"
	plan.fan_call, plan.light_call = not fan_same, not light_same
	return plan
end

-- What done is told (the table in the header).
local function args_of(plan)
	local outcome = plan.outcome
	if outcome == "renamed" or outcome == "same" then
		return { fan = plan.fan_to, light = plan.light_to }
	elseif outcome == "kept" then
		return { fan_live = plan.fan_live, fan_to = plan.fan_to, light_live = plan.light_live, light_to = plan.light_to }
	elseif outcome == "no_name" then
		return { fan_type = plan.fan_type }
	end
	return {}
end

-- The log (ECR 5.5) --------------------------------------------------------------------------

-- A change as the log writes it: old -> new, or the name alone when no call is due.
local function change(live_name, target, called)
	if called then
		return shown(live_name) .. " -> " .. shown(target)
	end
	return shown(live_name) .. " (unchanged)"
end

-- The text of the run's one always-on line, after "names (mode): ". The old names are
-- the owner's own words and the way back from a forced run; the redactor of a dev
-- build is the place that withholds them (ECR 5.5).
local function describe(plan)
	local outcome = plan.outcome
	if outcome == "renamed" then
		return string.format("fan item %s %s; light item %s %s", id_text(plan.fan_id),
			change(plan.fan_live, plan.fan_to, plan.fan_call), id_text(plan.light_id),
			change(plan.light_live, plan.light_to, plan.light_call))
	elseif outcome == "same" then
		return string.format("nothing to change: fan item %s is %s, light item %s is %s", id_text(plan.fan_id),
			shown(plan.fan_live), id_text(plan.light_id), shown(plan.light_live))
	elseif outcome == "kept" then
		local items = {}
		if not plan.fan_ours then
			items[#items + 1] = string.format("fan item %s is %s", id_text(plan.fan_id), shown(plan.fan_live))
		end
		if not plan.light_ours then
			items[#items + 1] = string.format("light item %s is %s", id_text(plan.light_id), shown(plan.light_live))
		end
		return string.format("kept: %s, not a default or a name the driver set; fan type %s would be %s",
			table.concat(items, ", "), plan.fan_type, shown(plan.fan_to))
	elseif outcome == "no_name" then
		return string.format("no name known for fan type %s; nothing renamed", plan.fan_type)
	elseif outcome == "no_type" then
		return "the fan type is not read yet; nothing renamed"
	elseif outcome == "no_ids" then
		return string.format("this device's two items were not found (fan item %s, light item %s); nothing renamed",
			id_text(plan.fan_id), id_text(plan.light_id))
	elseif outcome == "no_pin" then
		return "no fan is set up yet; nothing renamed"
	end
	return tostring(outcome)
end

-- The run ---------------------------------------------------------------------------------------

-- done(outcome, args), in pcall: the caller's own failure must not leave the job pending.
local function call_done(self, done, outcome, args)
	if type(done) ~= "function" then
		return
	end
	local ok, err = pcall(done, outcome, args)
	if not ok then
		say(self, "error", "names: the callback for %s failed: %s", outcome, tostring(err))
	end
end

-- The one way out of a run: reached once per run, from its start timer, its read-back
-- or run() itself. The pending state is cleared first, so done can ask for another run.
local function finish(self, run, outcome, args)
	if self.active == run then
		self.active = nil
	end
	call_done(self, run.done, outcome, args)
end

-- A timer step of a run (start or confirm). Nothing in them is meant to raise, since every
-- option is called in pcall; but if something does, the run ends unconfirmed instead of
-- staying pending for good (every later click would be answered busy) or raising into Director.
local function step(self, run, fn)
	return function()
		local ok, err = pcall(fn, self, run)
		if not ok then
			say(self, "error", "names (%s): the job failed: %s", run.mode, tostring(err))
			finish(self, run, "unconfirmed", {})
		end
	end
end

-- confirm_ms after the calls: the names are read back, the confirmed ones recorded.
local function confirm(self, run)
	local plan = run.plan
	local fan_now, light_now = live(self, plan.fan_id), live(self, plan.light_id)
	local fan_ok, light_ok = fan_now == plan.fan_to, light_now == plan.light_to
	say(self, "debug", "names: read back: fan item %s is %s (wanted %s), light item %s is %s (wanted %s)",
		id_text(plan.fan_id), shown(fan_now), shown(plan.fan_to), id_text(plan.light_id), shown(light_now),
		shown(plan.light_to))
	-- ECR N3: only what Director shows is recorded, and an item that did not confirm keeps
	-- the record it had.
	if fan_ok or light_ok then
		local store = self.store
		if type(store) ~= "table" then
			say(self, "warn", "names: there is no store; the new names are not recorded")
		else
			local old = record(self) or {}
			local wrote, err = try(store.set, rename.KEY, {
				fan = fan_ok and plan.fan_to or old.fan,
				light = light_ok and plan.light_to or old.light,
				at = clock(self),
			})
			if not wrote then
				say(self, "warn", "names: the record could not be written: %s", tostring(err))
			end
		end
	end
	if fan_ok and light_ok then
		finish(self, run, "renamed", { fan = plan.fan_to, light = plan.light_to })
		return
	end
	say(self, "warn", "names (%s): not confirmed: fan item %s is %s (wanted %s), light item %s is %s (wanted %s)",
		run.mode, id_text(plan.fan_id), shown(fan_now), shown(plan.fan_to), id_text(plan.light_id), shown(light_now),
		shown(plan.light_to))
	finish(self, run, "unconfirmed", {})
end

-- One C4:RenameDevice, in pcall. Whether it took is the read-back's to say.
local function call_rename(self, which, id, name)
	local ok, err = try(self.do_rename, id, name)
	if not ok then
		say(self, "warn", "names: renaming the %s item %s failed: %s", which, id_text(id), tostring(err))
	end
end

-- The start timer's callback: decide, and when a rename is due make the calls.
local function start(self, run)
	local plan = evaluate(self, run.mode)
	say(self, "always", "names (%s): %s", run.mode, describe(plan))
	if plan.outcome ~= "renamed" then
		finish(self, run, plan.outcome, args_of(plan))
		return
	end
	run.plan = plan
	if plan.fan_call then
		call_rename(self, "fan", plan.fan_id, plan.fan_to)
	end
	if plan.light_call then
		call_rename(self, "light", plan.light_id, plan.light_to)
	end
	if not arm(self, self.confirm_ms, step(self, run, confirm)) then
		say(self, "warn", "names: no timer for the read-back; reading the names back at once")
		confirm(self, run)
	end
end

-- The public surface --------------------------------------------------------------------------------

function rename:run(mode, done)
	if mode ~= "guarded" and mode ~= "forced" then
		say(self, "warn", "names: mode %s is neither guarded nor forced; taken as guarded", tostring(mode))
		mode = "guarded"
	end
	if self.active then
		say(self, "always", "names (%s): busy: another naming is pending; nothing changed", mode)
		local function answer()
			call_done(self, done, "busy", {})
		end
		if not arm(self, rename.START_MS, answer) then
			answer()
		end
		return
	end
	local run = { mode = mode, done = done }
	self.active = run
	if not arm(self, rename.START_MS, step(self, run, start)) then
		say(self, "always", "names (%s): no timer to run the job; nothing renamed", mode)
		finish(self, run, "unconfirmed", {})
	end
end

function rename:plan(mode)
	local plan = evaluate(self, mode == "forced" and "forced" or "guarded")
	if self.active then
		plan.outcome = "busy"
	end
	return plan
end

function rename:busy()
	return self.active ~= nil
end

function rename:stop()
	self.gen = self.gen + 1
	self.active = nil
	local timers = self.timers
	self.timers = {}
	for entry in pairs(timers) do
		local handle = entry.handle
		if handle ~= nil then
			pcall(function() handle:Cancel() end)
		end
	end
end

return rename
