-- fan.rename: the job that names the driver's two Composer items after the fan's
-- product name (docs/fan-name-design.md, section 2.2; docs/edge-cases-rename.md,
-- section 5) on hand-made fakes of what Director answers (GetDeviceDisplayName,
-- RenameDevice), of the name table, the store, the clock and the timers. None of
-- the sibling modules is loaded: a two-entry table stands in for fan/names.lua.
--
-- Placeholders only: the house fan's type is 1811-5-54 (named Aviator 5 by the
-- contract), a made-up type 0000-0-00 is named Sample, the items are 1205 (the fan)
-- and 1206 (the light), and what an owner typed is "Example Room Fan".

local rename = require("fan.rename")
local common_log = require("common.log")

local FAN_ID, LIGHT_ID = 1205, 1206
local NOW = 1793793600
local DEFAULT_FAN, DEFAULT_LIGHT = "Modern Forms Fan", "Modern Forms Fan Light"
local DEFAULTS = { { fan = DEFAULT_FAN, light = DEFAULT_LIGHT } }
local TARGET_FAN, TARGET_LIGHT = "Aviator 5", "Aviator 5 Light"
local TYPED_FAN, TYPED_LIGHT = "Example Room Fan", "Example Room Light"
local OLD_FAN, OLD_LIGHT = "Old Fan", "Old Fan Light"

-- Fakes -------------------------------------------------------------------------------------

local TYPES = { ["1811-5-54"] = TARGET_FAN, ["0000-0-00"] = "Sample" }

-- fan/names.lua's lookup and light: a trimmed exact match, and the name plus " Light".
local function lookup(fan_type)
	if type(fan_type) ~= "string" then
		return nil
	end
	return TYPES[fan_type:match("^%s*(.-)%s*$")]
end

local function light(name)
	return name .. " Light"
end

-- A logger that keeps what it is told: { level, text } in order.
local function fake_log()
	local log = { lines = {} }
	local function add(level)
		return function(fmt, ...)
			local ok, text = pcall(string.format, fmt, ...)
			log.lines[#log.lines + 1] = { level = level, text = ok and text or tostring(fmt) }
		end
	end
	log.always, log.warn, log.info, log.debug, log.error = add("always"), add("warn"), add("info"), add("debug"),
		add("error")
	-- The texts logged at `level` (all levels when nil).
	function log.texts(level)
		local out = {}
		for _, line in ipairs(log.lines) do
			if level == nil or line.level == level then
				out[#out + 1] = line.text
			end
		end
		return out
	end
	return log
end

-- A clock the spec moves: make(ms, cb) is C4:SetTimer's stand-in, with the :Cancel()
-- of a C4LuaTimer. advance(ms) fires what falls due, in due order (arming order
-- among equals), including timers armed meanwhile.
local function fake_timers()
	local clock = { list = {}, now = 0 }
	function clock.make(ms, cb)
		local timer = { at = clock.now + ms, cb = cb, ms = ms }
		function timer:Cancel() self.cancelled = true end
		clock.list[#clock.list + 1] = timer
		return timer
	end
	function clock.advance(ms)
		local target = clock.now + ms
		while true do
			local next_timer
			for _, timer in ipairs(clock.list) do
				if not timer.fired and not timer.cancelled and timer.at <= target
					and (not next_timer or timer.at < next_timer.at) then
					next_timer = timer
				end
			end
			if not next_timer then
				break
			end
			clock.now = next_timer.at
			next_timer.fired = true
			next_timer.cb()
		end
		clock.now = target
	end
	-- Timers armed and neither fired nor cancelled.
	function clock.waiting()
		local n = 0
		for _, timer in ipairs(clock.list) do
			if not timer.fired and not timer.cancelled then
				n = n + 1
			end
		end
		return n
	end
	return clock
end

-- A job on fakes. `over` may hold (everything is optional):
--   names          { [id] = the item's live name }
--   fan_type       the stored type; false for none
--   pinned         false for no fan set up
--   record         what the store holds under mf_names
--   confirm_ms     the read-back delay
--   ignore         { [id] = true }  RenameDevice is called and changes nothing
--   explode        { [id] = true }  RenameDevice raises, changing nothing
--   explode_after  { [id] = true }  RenameDevice changes the name, then raises
--   unreadable     { [id] = "raise" | "number" }  what GetDeviceDisplayName does for that item
--   fail_reads_after  n  GetDeviceDisplayName raises from its (n + 1)th call
--   timer_fails_at    n  the nth call of the timer function raises
--   handle         fn(timer) -> what the timer function hands back (nil: no handle)
--   opts           options that replace the rig's (false removes one)
-- The rig keeps: calls (every RenameDevice, with the clock), dones, events (always-on
-- log lines and renames, in order), stored, writes (every store.set), reads, log, clock, job.
local function rig(over)
	over = over or {}
	local r = {
		log = fake_log(), clock = fake_timers(), calls = {}, dones = {}, events = {}, writes = {}, reads = 0,
		timer_calls = 0, stored = {},
		names = over.names or { [FAN_ID] = DEFAULT_FAN, [LIGHT_ID] = DEFAULT_LIGHT },
		fan_type = over.fan_type == nil and "1811-5-54" or over.fan_type,
		pinned = over.pinned ~= false,
		ignore = over.ignore or {}, explode = over.explode or {}, explode_after = over.explode_after or {},
		unreadable = over.unreadable or {},
	}
	r.stored.mf_names = over.record
	local always = r.log.always
	r.log.always = function(fmt, ...)
		always(fmt, ...)
		r.events[#r.events + 1] = "log"
	end
	r.store = {
		get = function(key)
			return r.stored[key]
		end,
		set = function(key, value)
			r.writes[#r.writes + 1] = { key = key, value = value }
			r.stored[key] = value
		end,
	}
	r.opts = {
		ids = function()
			return FAN_ID, LIGHT_ID
		end,
		display_name = function(id)
			r.reads = r.reads + 1
			if over.fail_reads_after and r.reads > over.fail_reads_after then
				error("GetDeviceDisplayName kaput")
			end
			local how = r.unreadable[id]
			if how == "raise" then
				error("GetDeviceDisplayName kaput")
			elseif how == "number" then
				return 42
			end
			return r.names[id]
		end,
		rename = function(id, name)
			r.calls[#r.calls + 1] = { id = id, name = name, at = r.clock.now }
			r.events[#r.events + 1] = "rename"
			if r.explode[id] then
				error("RenameDevice kaput")
			end
			if not r.ignore[id] then
				r.names[id] = name
			end
			if r.explode_after[id] then
				error("RenameDevice raised after the change")
			end
		end,
		fan_type = function()
			if r.fan_type == false then
				return nil
			end
			return r.fan_type
		end,
		pinned = function()
			return r.pinned
		end,
		lookup = lookup, light = light, defaults = DEFAULTS,
		timer = function(ms, cb)
			r.timer_calls = r.timer_calls + 1
			if over.timer_fails_at and r.timer_calls == over.timer_fails_at then
				error("no timer")
			end
			local timer = r.clock.make(ms, cb)
			if over.handle then
				return over.handle(timer)
			end
			return timer
		end,
		store = r.store,
		now = function()
			return NOW
		end,
		log = r.log,
		confirm_ms = over.confirm_ms,
	}
	for key, value in pairs(over.opts or {}) do
		if value == false then
			r.opts[key] = nil
		else
			r.opts[key] = value
		end
	end
	r.job = rename.new(r.opts)
	function r.run(mode)
		r.job:run(mode, function(outcome, args)
			r.dones[#r.dones + 1] = { outcome = outcome, args = args }
		end)
	end
	function r.advance(ms)
		r.clock.advance(ms)
	end
	-- A run to its end: the start timer and the read-back have both fired.
	function r:settle(mode)
		self.run(mode)
		self.advance(5000)
		return self
	end
	return r
end

local function names_of(fan, light_item)
	return { [FAN_ID] = fan, [LIGHT_ID] = light_item }
end

-- The RenameDevice calls as { id, name }.
local function calls_of(r)
	local out = {}
	for _, call in ipairs(r.calls) do
		out[#out + 1] = { call.id, call.name }
	end
	return out
end

local function has(text, needle)
	return text:find(needle, 1, true) ~= nil
end

local function warnings(r)
	return table.concat(r.log.texts("warn"), "\n")
end

describe("fan.rename", function()
	describe("its constants", function()
		it("keeps the record under mf_names, starts at 1 ms and reads back at 2000 ms", function()
			assert.equal("mf_names", rename.KEY)
			assert.equal(1, rename.START_MS)
			assert.equal(2000, rename.CONFIRM_MS)
		end)

		it("lists the nine outcomes of section 2.2", function()
			local sorted = {}
			for _, outcome in ipairs(rename.OUTCOMES) do
				sorted[#sorted + 1] = outcome
			end
			table.sort(sorted)
			assert.same({ "busy", "kept", "no_ids", "no_name", "no_pin", "no_type", "renamed", "same", "unconfirmed" },
				sorted)
		end)
	end)

	describe("a guarded run on the shipped names", function()
		it("starts from a timer, never inside the call that asks", function()
			local r = rig()
			r.run("guarded")
			assert.same({}, r.calls)
			assert.same({}, r.dones)
			assert.is_true(r.job:busy())
			assert.equal(1, r.clock.waiting())
			assert.equal(1, r.clock.list[1].ms)
		end)

		it("calls RenameDevice for the fan item first and the light item right after it, in one tick", function()
			local r = rig()
			r.run("guarded")
			r.advance(1)
			assert.same({ { FAN_ID, TARGET_FAN }, { LIGHT_ID, TARGET_LIGHT } }, calls_of(r))
			assert.equal(1, r.calls[1].at)
			assert.equal(1, r.calls[2].at)
			assert.same({}, r.dones)
		end)

		it("reads the names back confirm_ms later, and only then records them and calls done", function()
			local r = rig()
			r.run("guarded")
			r.advance(1)
			assert.equal(1, r.clock.waiting())
			assert.equal(2000, r.clock.list[2].ms)
			r.advance(1999)
			assert.same({}, r.dones)
			assert.same({}, r.writes)
			assert.is_true(r.job:busy())
			r.advance(1)
			assert.equal(1, #r.dones)
			assert.equal("renamed", r.dones[1].outcome)
			assert.same({ fan = TARGET_FAN, light = TARGET_LIGHT }, r.dones[1].args)
			assert.equal(1, #r.writes)
			assert.equal("mf_names", r.writes[1].key)
			assert.same({ fan = TARGET_FAN, light = TARGET_LIGHT, at = NOW }, r.stored.mf_names)
			assert.is_false(r.job:busy())
			assert.equal(0, r.clock.waiting())
		end)

		it("takes another read-back delay when given one", function()
			local r = rig({ confirm_ms = 500 })
			r.run("guarded")
			r.advance(1)
			assert.equal(500, r.clock.list[2].ms)
			r.advance(499)
			assert.same({}, r.dones)
			r.advance(1)
			assert.equal("renamed", r.dones[1].outcome)
		end)

		it("falls back to 2000 ms for a delay that is no use", function()
			for _, bad in ipairs({ 0, -5, "soon", true }) do
				local r = rig({ confirm_ms = bad })
				r.run("guarded")
				r.advance(1)
				assert.equal(2000, r.clock.list[2].ms, tostring(bad))
			end
		end)

		it("takes an unknown or missing mode as guarded, never as forced, and says so", function()
			for _, mode in ipairs({ "typed", 5 }) do
				local r = rig({ names = names_of(TYPED_FAN, DEFAULT_LIGHT) })
				r.run(mode)
				r.advance(5000)
				assert.equal("kept", r.dones[1].outcome, tostring(mode))
				assert.same({}, r.calls)
				assert.is_true(has(r.log.texts("warn")[1], "taken as guarded"))
				assert.is_true(has(r.log.texts("always")[1], "names (guarded): "))
			end
			local r = rig({ names = names_of(TYPED_FAN, DEFAULT_LIGHT) })
			r.job:run(nil, function(outcome)
				r.dones[#r.dones + 1] = { outcome = outcome }
			end)
			r.advance(5000)
			assert.equal("kept", r.dones[1].outcome)
		end)
	end)

	describe("the guard of a guarded run", function()
		-- A run that leaves things as they are: no call, no record, one answer.
		local function assert_kept(r)
			assert.equal(1, #r.dones)
			assert.equal("kept", r.dones[1].outcome)
			assert.same({}, r.calls)
			assert.same({}, r.writes)
			assert.equal(0, r.clock.waiting())
			assert.is_false(r.job:busy())
		end

		it("renames while both items carry the shipped names, however padded", function()
			local r = rig({ names = names_of("  " .. DEFAULT_FAN .. " ", "\t" .. DEFAULT_LIGHT) }):settle("guarded")
			assert.equal("renamed", r.dones[1].outcome)
			assert.same({ { FAN_ID, TARGET_FAN }, { LIGHT_ID, TARGET_LIGHT } }, calls_of(r))
		end)

		it("renames while both carry the names the record holds (the last fan's names follow the new model)", function()
			local r = rig({ names = names_of(OLD_FAN, OLD_LIGHT), record = { fan = OLD_FAN, light = OLD_LIGHT, at = 1 } })
				:settle("guarded")
			assert.equal("renamed", r.dones[1].outcome)
			assert.same({ { FAN_ID, TARGET_FAN }, { LIGHT_ID, TARGET_LIGHT } }, calls_of(r))
			assert.same({ fan = TARGET_FAN, light = TARGET_LIGHT, at = NOW }, r.stored.mf_names)
		end)

		it("renames while one item has a shipped name and the other the recorded one", function()
			local r = rig({ names = names_of(OLD_FAN, DEFAULT_LIGHT), record = { fan = OLD_FAN, light = OLD_LIGHT } })
				:settle("guarded")
			assert.equal("renamed", r.dones[1].outcome)
			assert.equal(2, #r.calls)
		end)

		it("takes the shipped name of any pair, item by item", function()
			local older = { { fan = "Older Fan", light = "Older Fan Light" }, { fan = DEFAULT_FAN, light = DEFAULT_LIGHT } }
			local r = rig({ names = names_of("Older Fan", DEFAULT_LIGHT), opts = { defaults = older } }):settle("guarded")
			assert.equal("renamed", r.dones[1].outcome)
			assert.equal(2, #r.calls)
		end)

		it("keeps both items when the fan item was typed, and says which names it saw", function()
			local r = rig({ names = names_of(TYPED_FAN, DEFAULT_LIGHT) }):settle("guarded")
			assert_kept(r)
			assert.same({ fan_live = TYPED_FAN, fan_to = TARGET_FAN, light_live = DEFAULT_LIGHT, light_to = TARGET_LIGHT },
				r.dones[1].args)
		end)

		it("keeps both items when only the light item was typed: the fan item is not renamed alone", function()
			local r = rig({ names = names_of(DEFAULT_FAN, TYPED_LIGHT) }):settle("guarded")
			assert_kept(r)
			assert.equal(TYPED_LIGHT, r.dones[1].args.light_live)
			assert.equal(DEFAULT_FAN, r.names[FAN_ID])
		end)

		it("keeps both items when both were typed", function()
			assert_kept(rig({ names = names_of(TYPED_FAN, TYPED_LIGHT) }):settle("guarded"))
		end)

		it("keeps the names of a project whose items were named before (the cutover's, a dealer's)", function()
			assert_kept(rig({ names = names_of("Fan (new)", "Fan Light (new)") }):settle("guarded"))
			assert_kept(rig({ names = names_of("Fan", "Fan Light") }):settle("guarded"))
		end)

		it("takes a numbered default, another case and a neighbouring name for the owner's", function()
			assert_kept(rig({ names = names_of("Modern Forms Fan 2", DEFAULT_LIGHT) }):settle("guarded"))
			assert_kept(rig({ names = names_of(DEFAULT_FAN:lower(), DEFAULT_LIGHT) }):settle("guarded"))
			assert_kept(rig({ names = names_of(DEFAULT_FAN .. " X", DEFAULT_LIGHT) }):settle("guarded"))
			assert_kept(rig({ names = names_of(DEFAULT_FAN, DEFAULT_LIGHT:upper()) }):settle("guarded"))
		end)

		it("does not take the light's shipped name for the fan item, nor the other way round", function()
			assert_kept(rig({ names = names_of(DEFAULT_LIGHT, DEFAULT_FAN) }):settle("guarded"))
		end)

		it("does not take the record of the other item either", function()
			assert_kept(rig({ names = names_of(OLD_LIGHT, DEFAULT_LIGHT), record = { fan = OLD_FAN, light = OLD_LIGHT } })
				:settle("guarded"))
		end)

		it("takes a name it cannot read for the owner's: kept, and nothing is called", function()
			assert_kept(rig({ unreadable = { [FAN_ID] = "raise" } }):settle("guarded"))
			assert_kept(rig({ unreadable = { [LIGHT_ID] = "number" } }):settle("guarded"))
			assert_kept(rig({ names = { [FAN_ID] = DEFAULT_FAN } }):settle("guarded"))
			assert_kept(rig({ opts = { display_name = false } }):settle("guarded"))
		end)

		it("takes a record of another shape, or one the store cannot give, for none", function()
			assert_kept(rig({ names = names_of(OLD_FAN, OLD_LIGHT), record = "Old Fan" }):settle("guarded"))
			assert_kept(rig({ names = names_of(OLD_FAN, OLD_LIGHT), record = { fan = 5, light = {} } }):settle("guarded"))
			local failing = { get = function() error("store kaput") end, set = function() end }
			local r = rig({ names = names_of(OLD_FAN, OLD_LIGHT), opts = { store = failing } }):settle("guarded")
			assert_kept(r)
			assert.is_true(has(warnings(r), "store kaput"))
			assert_kept(rig({ names = names_of(OLD_FAN, OLD_LIGHT), opts = { store = false } }):settle("guarded"))
		end)

		it("renames over the shipped names with no store at all, and says nothing is recorded", function()
			local r = rig({ opts = { store = false } }):settle("guarded")
			assert.equal("renamed", r.dones[1].outcome)
			assert.is_true(has(warnings(r), "no store"))
		end)
	end)

	describe("a run that finds nothing to change", function()
		it("answers same, with no call, no record and no timer left", function()
			local r = rig({ names = names_of(TARGET_FAN, TARGET_LIGHT), record = { fan = TARGET_FAN, light = TARGET_LIGHT } })
				:settle("guarded")
			assert.equal(1, #r.dones)
			assert.equal("same", r.dones[1].outcome)
			assert.same({ fan = TARGET_FAN, light = TARGET_LIGHT }, r.dones[1].args)
			assert.same({}, r.calls)
			assert.same({}, r.writes)
			assert.equal(0, r.clock.waiting())
		end)

		it("answers same also when the names are not ours: they are what the guard would write", function()
			local r = rig({ names = names_of(TARGET_FAN, TARGET_LIGHT) }):settle("guarded")
			assert.equal("same", r.dones[1].outcome)
			assert.same({}, r.calls)
			assert.same({}, r.writes)
		end)

		it("compares the trimmed names", function()
			local r = rig({ names = names_of(" " .. TARGET_FAN, TARGET_LIGHT .. "  ") }):settle("forced")
			assert.equal("same", r.dones[1].outcome)
			assert.same({}, r.calls)
		end)

		it("answers same in a forced run too", function()
			local r = rig({ names = names_of(TARGET_FAN, TARGET_LIGHT) }):settle("forced")
			assert.equal("same", r.dones[1].outcome)
			assert.same({}, r.calls)
			assert.same({}, r.writes)
		end)

		it("calls only the item whose name differs, and records both once they read back right", function()
			local r = rig({ names = names_of(TARGET_FAN, DEFAULT_LIGHT), record = { fan = TARGET_FAN, light = OLD_LIGHT } })
				:settle("guarded")
			assert.equal("renamed", r.dones[1].outcome)
			assert.same({ { LIGHT_ID, TARGET_LIGHT } }, calls_of(r))
			assert.same({ fan = TARGET_FAN, light = TARGET_LIGHT, at = NOW }, r.stored.mf_names)
		end)

		it("keeps both when the fan item was typed with exactly the target and the light item is still shipped", function()
			-- the fan item is not ours (no record), so the guard keeps both items as they are
			local r = rig({ names = names_of(TARGET_FAN, DEFAULT_LIGHT) }):settle("guarded")
			assert.equal("kept", r.dones[1].outcome)
			assert.same({}, r.calls)
		end)
	end)

	describe("a forced run", function()
		it("renames both items whatever they are called, and records both", function()
			local r = rig({ names = names_of(TYPED_FAN, TYPED_LIGHT) }):settle("forced")
			assert.equal(1, #r.dones)
			assert.equal("renamed", r.dones[1].outcome)
			assert.same({ fan = TARGET_FAN, light = TARGET_LIGHT }, r.dones[1].args)
			assert.same({ { FAN_ID, TARGET_FAN }, { LIGHT_ID, TARGET_LIGHT } }, calls_of(r))
			assert.same({ fan = TARGET_FAN, light = TARGET_LIGHT, at = NOW }, r.stored.mf_names)
		end)

		it("renames the shipped names the same way", function()
			local r = rig():settle("forced")
			assert.equal("renamed", r.dones[1].outcome)
			assert.equal(2, #r.calls)
		end)

		it("leaves an item alone that already has its target name, and records it with the other", function()
			local r = rig({ names = names_of(TARGET_FAN, TYPED_LIGHT) }):settle("forced")
			assert.equal("renamed", r.dones[1].outcome)
			assert.same({ { LIGHT_ID, TARGET_LIGHT } }, calls_of(r))
			assert.same({ fan = TARGET_FAN, light = TARGET_LIGHT, at = NOW }, r.stored.mf_names)
		end)

		it("renames a name it cannot read, and then cannot confirm it", function()
			local r = rig({ unreadable = { [FAN_ID] = "raise" } }):settle("forced")
			assert.equal(2, #r.calls)
			assert.equal("unconfirmed", r.dones[1].outcome)
			assert.equal(TARGET_LIGHT, r.stored.mf_names.light)
			assert.is_nil(r.stored.mf_names.fan)
		end)

		it("renames items Director gives no name for", function()
			local r = rig({ names = {} }):settle("forced")
			assert.equal("renamed", r.dones[1].outcome)
			assert.equal(2, #r.calls)
		end)

		it("makes the names ours again: a later guarded run for another model renames them", function()
			local r = rig({ names = names_of(TYPED_FAN, TYPED_LIGHT) }):settle("forced")
			r.fan_type = "0000-0-00"
			r:settle("guarded")
			assert.equal("renamed", r.dones[2].outcome)
			assert.same({ fan = "Sample", light = "Sample Light" }, r.dones[2].args)
			assert.same({ fan = "Sample", light = "Sample Light", at = NOW }, r.stored.mf_names)
			assert.equal("Sample", r.names[FAN_ID])
		end)

		it("leaves a name typed after it to the owner: a later guarded run keeps both", function()
			local r = rig():settle("forced")
			r.names[LIGHT_ID] = TYPED_LIGHT
			r.fan_type = "0000-0-00"
			r:settle("guarded")
			assert.equal("kept", r.dones[2].outcome)
			assert.equal(TARGET_FAN, r.names[FAN_ID])
			assert.equal(2, #r.calls)
		end)
	end)

	describe("a run with nothing to name", function()
		-- Each refusal: one answer from the start timer, no call, no record, no timer left.
		local function assert_refused(r, outcome, args)
			assert.same({}, r.dones)
			r.advance(1)
			assert.equal(1, #r.dones)
			assert.equal(outcome, r.dones[1].outcome)
			assert.same(args or {}, r.dones[1].args)
			assert.same({}, r.calls)
			assert.same({}, r.writes)
			assert.equal(0, r.clock.waiting())
			assert.is_false(r.job:busy())
			r.advance(10000)
			assert.equal(1, #r.dones)
		end

		local function refused(over, mode, outcome, args)
			local r = rig(over)
			r.run(mode)
			assert_refused(r, outcome, args)
			return r
		end

		it("answers no_pin when no fan is set up, in either mode", function()
			refused({ pinned = false }, "guarded", "no_pin")
			refused({ pinned = false }, "forced", "no_pin")
		end)

		it("answers no_pin when it cannot find out", function()
			local r = refused({ opts = { pinned = function() error("model kaput") end } }, "forced", "no_pin")
			assert.is_true(has(warnings(r), "model kaput"))
			refused({ opts = { pinned = false } }, "guarded", "no_pin")
		end)

		it("answers no_type while the fan type is not known: nil, blank, not text, or unreadable", function()
			for _, fan_type in ipairs({ false, "", "  \t", 5, {} }) do
				refused({ fan_type = fan_type }, "forced", "no_type")
			end
			refused({ opts = { fan_type = function() error("model kaput") end } }, "guarded", "no_type")
			refused({ opts = { fan_type = false } }, "guarded", "no_type")
		end)

		it("answers no_name for a type the table does not know, naming the type it saw", function()
			refused({ fan_type = "  9999-9-99 " }, "guarded", "no_name", { fan_type = "9999-9-99" })
		end)

		it("matches the type exactly: no prefix, no longer type, no neighbour", function()
			for _, fan_type in ipairs({ "1811-5-5", "1811-5-540", "1811-5", "1811-5-54X", "x1811-5-54" }) do
				refused({ fan_type = fan_type }, "forced", "no_name", { fan_type = fan_type })
			end
		end)

		it("hands the type to the table as the fan gave it, and shows it cleaned of control characters", function()
			local seen
			local spy = function(fan_type)
				seen = fan_type
				return nil
			end
			local r = rig({ fan_type = " 1811-5-54 ", opts = { lookup = spy } })
			r.run("guarded")
			r.advance(1)
			assert.equal(" 1811-5-54 ", seen)
			assert.same({ fan_type = "1811-5-54" }, r.dones[1].args)
			refused({ fan_type = "99\n99" }, "guarded", "no_name", { fan_type = "99?99" })
			refused({ fan_type = string.rep("9", 80) }, "guarded", "no_name", { fan_type = string.rep("9", 40) })
		end)

		it("answers no_name when the table fails", function()
			local r = refused({ opts = { lookup = function() error("table kaput") end } }, "forced", "no_name",
				{ fan_type = "1811-5-54" })
			assert.is_true(has(warnings(r), "table kaput"))
			refused({ opts = { lookup = false } }, "forced", "no_name", { fan_type = "1811-5-54" })
		end)

		it("answers no_name when the table gives a name that is not usable", function()
			for _, bad in ipairs({ "", "  ", " Aviator 5", "Aviator 5 ", "Avia\ntor", 5, true }) do
				refused({ opts = { lookup = function() return bad end } }, "forced", "no_name", { fan_type = "1811-5-54" })
			end
		end)

		it("answers no_name when the light item's name cannot be made or is not usable", function()
			local r = refused({ opts = { light = function() error("light kaput") end } }, "forced", "no_name",
				{ fan_type = "1811-5-54" })
			assert.is_true(has(warnings(r), "light kaput"))
			refused({ opts = { light = false } }, "forced", "no_name", { fan_type = "1811-5-54" })
			for _, bad in ipairs({ "", " x", "x ", "x\ty", false, {} }) do
				refused({ opts = { light = function() return bad end } }, "forced", "no_name", { fan_type = "1811-5-54" })
			end
		end)

		it("answers no_ids when an item was not found, or the answer is no id", function()
			local cases = {
				function() return nil, nil end,
				function() return FAN_ID, nil end,
				function() return nil, LIGHT_ID end,
				function() return FAN_ID, FAN_ID end,
				function() return 0, LIGHT_ID end,
				function() return FAN_ID, -3 end,
				function() return 12.5, LIGHT_ID end,
				function() return FAN_ID, "abc" end,
				function() return FAN_ID, "12.5" end,
				function() return FAN_ID, "0x10" end,
				function() return FAN_ID, {} end,
				function() return FAN_ID, true end,
				function() return FAN_ID, math.huge end,
				function() return 0 / 0, LIGHT_ID end,
				function() error("bindings kaput") end,
			}
			for _, ids in ipairs(cases) do
				local r = refused({ opts = { ids = ids } }, "forced", "no_ids")
				assert.equal(1, #r.log.texts("always"))
			end
			refused({ opts = { ids = false } }, "guarded", "no_ids")
		end)

		it("takes ids given as digits, and hands Director the number", function()
			local r = rig({ opts = { ids = function() return "1205", " 1206 " end } }):settle("guarded")
			assert.equal("renamed", r.dones[1].outcome)
			assert.same({ { FAN_ID, TARGET_FAN }, { LIGHT_ID, TARGET_LIGHT } }, calls_of(r))
			assert.equal("number", type(r.calls[1].id))
		end)

		it("looks at the pin before the type, the type before the name, the name before the items", function()
			refused({ pinned = false, fan_type = false }, "forced", "no_pin")
			refused({ fan_type = "", opts = { ids = function() return nil, nil end } }, "forced", "no_type")
			refused({ fan_type = "9999-9-99", opts = { ids = function() return nil, nil end } }, "forced", "no_name",
				{ fan_type = "9999-9-99" })
		end)

		it("reads no item's name before the target and the items are settled", function()
			local r = rig({ fan_type = "9999-9-99" })
			r.run("guarded")
			r.advance(1)
			assert.equal(0, r.reads)
			local no_ids = rig({ opts = { ids = function() return nil, nil end } })
			no_ids.run("guarded")
			no_ids.advance(1)
			assert.equal(0, no_ids.reads)
		end)
	end)

	describe("a rename Director does not confirm", function()
		it("answers unconfirmed and records only the item that read back right", function()
			local r = rig({ ignore = { [LIGHT_ID] = true } }):settle("guarded")
			assert.equal(1, #r.dones)
			assert.equal("unconfirmed", r.dones[1].outcome)
			assert.same({}, r.dones[1].args)
			assert.equal(2, #r.calls)
			assert.same({ fan = TARGET_FAN, at = NOW }, r.stored.mf_names)
			assert.equal(1, #r.writes)
		end)

		it("keeps an item's earlier record when only the other one was confirmed", function()
			local record = function() return { fan = OLD_FAN, light = OLD_LIGHT, at = 1 } end
			local r = rig({ names = names_of(OLD_FAN, OLD_LIGHT), record = record(), ignore = { [LIGHT_ID] = true } })
				:settle("guarded")
			assert.equal("unconfirmed", r.dones[1].outcome)
			assert.same({ fan = TARGET_FAN, light = OLD_LIGHT, at = NOW }, r.stored.mf_names)
			local other = rig({ names = names_of(OLD_FAN, OLD_LIGHT), record = record(), ignore = { [FAN_ID] = true } })
				:settle("guarded")
			assert.equal("unconfirmed", other.dones[1].outcome)
			assert.same({ fan = OLD_FAN, light = TARGET_LIGHT, at = NOW }, other.stored.mf_names)
		end)

		it("writes no record at all when neither name took", function()
			local r = rig({ names = names_of(OLD_FAN, OLD_LIGHT), record = { fan = OLD_FAN, light = OLD_LIGHT, at = 1 },
				ignore = { [FAN_ID] = true, [LIGHT_ID] = true } }):settle("guarded")
			assert.equal("unconfirmed", r.dones[1].outcome)
			assert.same({}, r.writes)
			assert.same({ fan = OLD_FAN, light = OLD_LIGHT, at = 1 }, r.stored.mf_names)
		end)

		it("contains a RenameDevice that raises: the other item is still tried, and nothing raises", function()
			local r = rig({ explode = { [FAN_ID] = true } })
			assert.has_no.errors(function()
				r:settle("guarded")
			end)
			assert.equal("unconfirmed", r.dones[1].outcome)
			assert.same({ { FAN_ID, TARGET_FAN }, { LIGHT_ID, TARGET_LIGHT } }, calls_of(r))
			assert.same({ light = TARGET_LIGHT, at = NOW }, r.stored.mf_names)
			assert.is_true(has(warnings(r), "RenameDevice kaput"))
		end)

		it("contains a RenameDevice that raises for both items", function()
			local r = rig({ explode = { [FAN_ID] = true, [LIGHT_ID] = true } }):settle("forced")
			assert.equal(1, #r.dones)
			assert.equal("unconfirmed", r.dones[1].outcome)
			assert.same({}, r.writes)
		end)

		it("answers unconfirmed with no RenameDevice to call", function()
			local r = rig({ opts = { rename = false } }):settle("forced")
			assert.equal("unconfirmed", r.dones[1].outcome)
			assert.same({}, r.writes)
		end)

		it("lets the read-back decide: a call that raised after the change is confirmed by what Director shows", function()
			local r = rig({ explode_after = { [FAN_ID] = true } }):settle("guarded")
			assert.equal("renamed", r.dones[1].outcome)
			assert.same({ fan = TARGET_FAN, light = TARGET_LIGHT, at = NOW }, r.stored.mf_names)
		end)

		it("answers unconfirmed when the read-back cannot read the names", function()
			local r = rig({ fail_reads_after = 2 }):settle("guarded")
			assert.equal(2, #r.calls)
			assert.equal("unconfirmed", r.dones[1].outcome)
			assert.same({}, r.writes)
		end)

		it("answers unconfirmed when a name reads back as something else (the owner was quicker)", function()
			local r = rig()
			r.run("guarded")
			r.advance(1)
			r.names[LIGHT_ID] = TYPED_LIGHT
			r.advance(5000)
			assert.equal("unconfirmed", r.dones[1].outcome)
			assert.same({ fan = TARGET_FAN, at = NOW }, r.stored.mf_names)
		end)

		it("tries again at the next click, and ends renamed once Director takes the names", function()
			local r = rig({ ignore = { [FAN_ID] = true, [LIGHT_ID] = true } }):settle("guarded")
			assert.equal("unconfirmed", r.dones[1].outcome)
			r.ignore[FAN_ID], r.ignore[LIGHT_ID] = nil, nil
			r:settle("guarded")
			assert.equal("renamed", r.dones[2].outcome)
			assert.equal(4, #r.calls)
		end)

		it("still answers renamed when the record cannot be written, and says so", function()
			local failing = { get = function() end, set = function() error("store kaput") end }
			local r = rig({ opts = { store = failing } }):settle("guarded")
			assert.equal("renamed", r.dones[1].outcome)
			assert.is_true(has(warnings(r), "store kaput"))
		end)

		it("takes the time of the record from the clock, else from os.time", function()
			local r = rig({ opts = { now = function() error("clock kaput") end } }):settle("guarded")
			assert.equal("number", type(r.stored.mf_names.at))
			assert.is_true(math.abs(os.time() - r.stored.mf_names.at) <= 5)
			local odd = rig({ opts = { now = function() return "noon" end } }):settle("guarded")
			assert.is_true(math.abs(os.time() - odd.stored.mf_names.at) <= 5)
			local default = rig({ opts = { now = false } }):settle("guarded")
			assert.is_true(math.abs(os.time() - default.stored.mf_names.at) <= 5)
		end)

		it("writes a new table: the one the store gave is not changed", function()
			local kept = { fan = OLD_FAN, light = OLD_LIGHT, at = 1 }
			local r = rig({ names = names_of(OLD_FAN, OLD_LIGHT), record = kept }):settle("guarded")
			assert.not_equal(kept, r.stored.mf_names)
			assert.same({ fan = OLD_FAN, light = OLD_LIGHT, at = 1 }, kept)
		end)

		it("does not carry a malformed field of the old record into the new one", function()
			-- the fan item has its shipped name, so the run goes ahead; its rename does not take, and the
			-- record held a number for it: that must not be written back
			local r = rig({ record = { fan = 5, light = TARGET_LIGHT }, ignore = { [FAN_ID] = true } })
				:settle("guarded")
			assert.equal("unconfirmed", r.dones[1].outcome)
			assert.same({ light = TARGET_LIGHT, at = NOW }, r.stored.mf_names)
			local other = rig({ record = { fan = TARGET_FAN, light = {} }, ignore = { [LIGHT_ID] = true } })
				:settle("guarded")
			assert.equal("unconfirmed", other.dones[1].outcome)
			assert.same({ fan = TARGET_FAN, at = NOW }, other.stored.mf_names)
		end)
	end)

	describe("a second request, stop() and the timers", function()
		it("answers busy to a request made while the start timer is pending, from a timer of its own", function()
			local r = rig()
			r.run("guarded")
			local second = {}
			r.job:run("forced", function(outcome, args)
				second[#second + 1] = { outcome, args }
			end)
			assert.same({}, second)
			assert.same({}, r.dones)
			r.advance(1)
			assert.same({ { "busy", {} } }, second)
			r.advance(5000)
			assert.equal(1, #r.dones)
			assert.equal("renamed", r.dones[1].outcome)
			assert.equal(2, #r.calls)
			assert.equal(1, #second)
		end)

		it("answers busy to a request made between the calls and the read-back, and disturbs nothing", function()
			local r = rig()
			r.run("guarded")
			r.advance(1)
			local second = {}
			r.job:run("guarded", function(outcome)
				second[#second + 1] = outcome
			end)
			assert.same({}, second)
			assert.is_true(r.job:busy())
			r.advance(1)
			assert.same({ "busy" }, second)
			assert.same({}, r.dones)
			assert.is_true(r.job:busy())
			r.advance(5000)
			assert.same({ "busy" }, second)
			assert.equal(1, #r.dones)
			assert.equal("renamed", r.dones[1].outcome)
			assert.equal(2, #r.calls)
			assert.equal(1, #r.writes)
		end)

		it("is busy from run() until done is called, and not inside done", function()
			local r = rig()
			assert.is_false(r.job:busy())
			local busy_inside
			r.job:run("guarded", function()
				busy_inside = r.job:busy()
			end)
			assert.is_true(r.job:busy())
			r.advance(1)
			assert.is_true(r.job:busy())
			r.advance(5000)
			assert.is_false(busy_inside)
			assert.is_false(r.job:busy())
		end)

		it("lets done ask for another run", function()
			local r = rig({ names = names_of(TYPED_FAN, TYPED_LIGHT) })
			local outcomes = {}
			local function again(outcome)
				outcomes[#outcomes + 1] = outcome
				if #outcomes == 1 then
					r.job:run("forced", again)
				end
			end
			r.job:run("guarded", again)
			r.advance(5000)
			assert.same({ "kept", "renamed" }, outcomes)
			assert.is_false(r.job:busy())
		end)

		it("stop() before the start timer fires cancels it: no call, no done, no record", function()
			local r = rig()
			r.run("guarded")
			r.job:stop()
			assert.is_true(r.clock.list[1].cancelled)
			assert.is_false(r.job:busy())
			r.advance(10000)
			assert.same({}, r.calls)
			assert.same({}, r.dones)
			assert.same({}, r.writes)
			assert.same({}, r.log.texts("always"))
		end)

		it("stop() before the read-back cancels it: the calls were made, but no done and no record", function()
			local r = rig()
			r.run("guarded")
			r.advance(1)
			assert.equal(2, #r.calls)
			r.job:stop()
			assert.is_true(r.clock.list[2].cancelled)
			assert.is_false(r.job:busy())
			r.advance(10000)
			assert.same({}, r.dones)
			assert.same({}, r.writes)
			assert.equal(0, r.clock.waiting())
		end)

		it("stop() cancels a busy answer that is still waiting", function()
			local r = rig()
			r.run("guarded")
			local second = {}
			r.job:run("forced", function(outcome)
				second[#second + 1] = outcome
			end)
			r.job:stop()
			r.advance(10000)
			assert.same({}, second)
			assert.same({}, r.dones)
		end)

		it("stop() cancels a timer once, and not one that has fired", function()
			local cancels = 0
			local r = rig({ handle = function(timer)
				local cancel = timer.Cancel
				timer.Cancel = function(self)
					cancels = cancels + 1
					cancel(self)
				end
				return timer
			end })
			r.run("guarded")
			r.advance(1)
			-- the start timer has fired; only the read-back is waiting
			r.job:stop()
			r.job:stop()
			assert.equal(1, cancels)
			assert.is_nil(r.clock.list[1].cancelled)
			assert.is_true(r.clock.list[2].cancelled)
			local done = rig():settle("guarded")
			done.job:stop()
			for _, timer in ipairs(done.clock.list) do
				assert.is_nil(timer.cancelled)
			end
		end)

		it("stop() can be called twice, or with nothing pending", function()
			local r = rig()
			assert.has_no.errors(function()
				r.job:stop()
				r.job:stop()
			end)
			r.run("guarded")
			r.job:stop()
			r.job:stop()
			r.advance(10000)
			assert.same({}, r.dones)
		end)

		it("works again after stop()", function()
			local r = rig()
			r.run("guarded")
			r.job:stop()
			r.run("guarded")
			r.advance(5000)
			assert.equal(1, #r.dones)
			assert.equal("renamed", r.dones[1].outcome)
			assert.equal(2, #r.calls)
		end)

		it("ignores a timer that stop() cannot cancel because no handle came back", function()
			local r = rig({ handle = function() return nil end })
			r.run("guarded")
			r.advance(1)
			assert.equal(2, #r.calls)
			r.job:stop()
			r.advance(10000)
			assert.equal(2, #r.calls)
			assert.same({}, r.dones)
			assert.same({}, r.writes)
		end)

		it("ignores a busy answer that stop() could not cancel either", function()
			local r = rig({ handle = function() return nil end })
			r.run("guarded")
			local second = {}
			r.job:run("forced", function(outcome)
				second[#second + 1] = outcome
			end)
			r.job:stop()
			r.advance(10000)
			assert.same({}, second)
			assert.same({}, r.dones)
			assert.same({}, r.calls)
		end)

		it("ignores a timer whose Cancel raises", function()
			local r = rig({ handle = function(timer)
				timer.Cancel = function() error("cancel kaput") end
				return timer
			end })
			r.run("guarded")
			r.advance(1)
			assert.has_no.errors(function()
				r.job:stop()
			end)
			r.clock.list[2].cancelled = nil -- as if the cancel had not stopped it
			r.advance(10000)
			assert.same({}, r.dones)
			assert.same({}, r.writes)
		end)

		it("ignores the late timer of a stopped run even after a new run has started", function()
			local r = rig()
			r.run("guarded")
			local old = r.clock.list[1]
			r.job:stop()
			r.run("guarded")
			old.cancelled = nil -- as if Cancel had not stopped it
			r.advance(5000)
			assert.equal(1, #r.dones)
			assert.equal(2, #r.calls)
		end)

		it("copes with a timer that fires inside the call that arms it: the run is over when run() returns", function()
			local r = rig({ opts = { timer = function(_, cb)
				cb()
				return { Cancel = function() end }
			end } })
			r.run("guarded")
			assert.equal(1, #r.dones)
			assert.equal("renamed", r.dones[1].outcome)
			assert.same({ fan = TARGET_FAN, light = TARGET_LIGHT, at = NOW }, r.stored.mf_names)
			assert.is_false(r.job:busy())
			assert.has_no.errors(function()
				r.job:stop()
			end)
		end)

		it("with no timer function, a run ends unconfirmed at once and renames nothing", function()
			for _, over in ipairs({ { opts = { timer = false } }, { timer_fails_at = 1 } }) do
				local r = rig(over)
				r.run("forced")
				assert.equal(1, #r.dones)
				assert.equal("unconfirmed", r.dones[1].outcome)
				assert.same({}, r.calls)
				assert.is_false(r.job:busy())
				assert.equal(1, #r.log.texts("always"))
				assert.is_true(#r.log.texts("warn") >= 1)
				assert.is_true(has(r.log.texts("always")[1], "no timer"))
			end
		end)

		it("with no timer function, a busy answer is given at once", function()
			local r = rig({ timer_fails_at = 2 })
			r.run("guarded")
			local second = {}
			r.job:run("forced", function(outcome)
				second[#second + 1] = outcome
			end)
			assert.same({ "busy" }, second)
			r.advance(5000)
			assert.equal("renamed", r.dones[1].outcome)
		end)

		it("reads the names back at once when the read-back timer cannot be armed", function()
			local r = rig({ timer_fails_at = 2 })
			r.run("guarded")
			r.advance(1)
			assert.equal(1, #r.dones)
			assert.equal("renamed", r.dones[1].outcome)
			assert.is_true(has(warnings(r), "reading the names back at once"))
			assert.is_false(r.job:busy())
		end)
	end)

	describe("the plan", function()
		local function assert_untouched(r)
			assert.same({}, r.calls)
			assert.same({}, r.writes)
			assert.equal(0, r.timer_calls)
			assert.equal(0, r.clock.waiting())
			assert.same({}, r.log.texts("always"))
			assert.is_false(r.job:busy())
		end

		it("says what a guarded run would rename, with the ids, the live names and the targets", function()
			local r = rig()
			local plan = r.job:plan("guarded")
			assert.equal("renamed", plan.outcome)
			assert.equal("guarded", plan.mode)
			assert.equal("1811-5-54", plan.fan_type)
			assert.equal(FAN_ID, plan.fan_id)
			assert.equal(LIGHT_ID, plan.light_id)
			assert.equal(DEFAULT_FAN, plan.fan_live)
			assert.equal(DEFAULT_LIGHT, plan.light_live)
			assert.equal(TARGET_FAN, plan.fan_to)
			assert.equal(TARGET_LIGHT, plan.light_to)
			assert.is_true(plan.fan_ours)
			assert.is_true(plan.light_ours)
			assert.is_true(plan.fan_call)
			assert.is_true(plan.light_call)
			assert_untouched(r)
		end)

		it("says kept for names the owner typed, and which of them are not ours", function()
			local r = rig({ names = names_of(TYPED_FAN, DEFAULT_LIGHT) })
			local plan = r.job:plan("guarded")
			assert.equal("kept", plan.outcome)
			assert.is_false(plan.fan_ours)
			assert.is_true(plan.light_ours)
			assert.equal(TYPED_FAN, plan.fan_live)
			assert_untouched(r)
		end)

		it("says renamed for the same names in a forced run, and takes no or an odd mode for guarded", function()
			local r = rig({ names = names_of(TYPED_FAN, TYPED_LIGHT) })
			assert.equal("renamed", r.job:plan("forced").outcome)
			assert.equal("forced", r.job:plan("forced").mode)
			assert.equal("kept", r.job:plan("guarded").outcome)
			assert.equal("kept", r.job:plan().outcome)
			assert.equal("guarded", r.job:plan("typed").mode)
			assert_untouched(r)
		end)

		it("says which item a run would call", function()
			local r = rig({ names = names_of(TARGET_FAN, TYPED_LIGHT) })
			local plan = r.job:plan("forced")
			assert.equal("renamed", plan.outcome)
			assert.is_false(plan.fan_call)
			assert.is_true(plan.light_call)
		end)

		it("says same, and stops where a run would refuse, with what it learned on the way", function()
			assert.equal("same", rig({ names = names_of(TARGET_FAN, TARGET_LIGHT) }).job:plan("guarded").outcome)
			assert.equal("no_pin", rig({ pinned = false }).job:plan("forced").outcome)
			assert.equal("no_type", rig({ fan_type = "" }).job:plan("forced").outcome)
			local plan = rig({ fan_type = "9999-9-99" }).job:plan("forced")
			assert.equal("no_name", plan.outcome)
			assert.equal("9999-9-99", plan.fan_type)
			assert.is_nil(plan.fan_to)
			local no_ids = rig({ opts = { ids = function() return FAN_ID, nil end } })
			plan = no_ids.job:plan("forced")
			assert.equal("no_ids", plan.outcome)
			assert.equal(FAN_ID, plan.fan_id)
			assert.is_nil(plan.light_id)
			assert.equal(TARGET_FAN, plan.fan_to)
			assert.is_nil(plan.fan_live)
			assert.equal(0, no_ids.reads)
		end)

		it("decides what the run does, in every case", function()
			-- builders: a case's names and flags are changed by its run, so each rig gets fresh ones
			local cases = {
				{ "guarded", function() return {} end },
				{ "guarded", function() return { names = names_of(TYPED_FAN, TYPED_LIGHT) } end },
				{ "forced", function() return { names = names_of(TYPED_FAN, TYPED_LIGHT) } end },
				{ "guarded", function() return { names = names_of(TARGET_FAN, TARGET_LIGHT) } end },
				{ "guarded", function() return { names = names_of(TARGET_FAN, DEFAULT_LIGHT) } end },
				{ "forced", function() return { names = names_of(TARGET_FAN, DEFAULT_LIGHT) } end },
				{ "forced", function() return { pinned = false } end },
				{ "guarded", function() return { fan_type = false } end },
				{ "guarded", function() return { fan_type = "9999-9-99" } end },
				{ "guarded", function() return { unreadable = { [FAN_ID] = "raise" } } end },
				{ "forced", function() return { unreadable = { [FAN_ID] = "raise" } } end },
				{ "forced", function() return { opts = { ids = function() return nil, nil end } } end },
			}
			for index, case in ipairs(cases) do
				local r = rig(case[2]())
				local plan = r.job:plan(case[1])
				r:settle(case[1])
				local ended = r.dones[1].outcome
				if plan.outcome == "renamed" then
					-- the plan assumes Director confirms every call
					assert.is_true(ended == "renamed" or ended == "unconfirmed", "case " .. index)
				else
					assert.equal(plan.outcome, ended, "case " .. index)
				end
			end
		end)

		it("says busy while a run is pending, and still tells the rest", function()
			local r = rig()
			r.run("guarded")
			local plan = r.job:plan("guarded")
			assert.equal("busy", plan.outcome)
			assert.equal(TARGET_FAN, plan.fan_to)
			assert.equal(FAN_ID, plan.fan_id)
			r.advance(5000)
			assert.equal("renamed", r.dones[1].outcome)
			assert.equal(2, #r.calls)
			assert.equal("same", r.job:plan("guarded").outcome)
		end)
	end)

	describe("the log", function()
		it("writes one always-on line per run, whatever the outcome", function()
			local cases = {
				{ "guarded", {} },
				{ "forced", { names = names_of(TYPED_FAN, TYPED_LIGHT) } },
				{ "guarded", { names = names_of(TARGET_FAN, TARGET_LIGHT) } },
				{ "guarded", { names = names_of(TYPED_FAN, DEFAULT_LIGHT) } },
				{ "guarded", { fan_type = "9999-9-99" } },
				{ "guarded", { fan_type = false } },
				{ "guarded", { opts = { ids = function() return nil, nil end } } },
				{ "forced", { pinned = false } },
				{ "guarded", { ignore = { [FAN_ID] = true } } },
				{ "forced", { explode = { [FAN_ID] = true, [LIGHT_ID] = true } } },
				{ "guarded", { timer_fails_at = 1 } },
			}
			for index, case in ipairs(cases) do
				local r = rig(case[2]):settle(case[1])
				local lines = r.log.texts("always")
				assert.equal(1, #lines, "case " .. index)
				assert.is_true(lines[1]:find("^names %(" .. case[1] .. "%): ") ~= nil, lines[1])
			end
			local r = rig()
			r.run("guarded")
			r.job:run("forced", function() end)
			r.advance(5000)
			assert.equal(2, #r.log.texts("always"))
			assert.is_true(has(r.log.texts("always")[1], "names (forced): busy"))
		end)

		it("shows the ids and old -> new for a rename, before the calls are made", function()
			local r = rig():settle("guarded")
			assert.same({ 'names (guarded): fan item 1205 "Modern Forms Fan" -> "Aviator 5"; '
				.. 'light item 1206 "Modern Forms Fan Light" -> "Aviator 5 Light"' }, r.log.texts("always"))
			assert.same({ "log", "rename", "rename" }, r.events)
		end)

		it("shows the old names of a forced run too, and which item is unchanged", function()
			local r = rig({ names = names_of(TARGET_FAN, TYPED_LIGHT) }):settle("forced")
			assert.same({ 'names (forced): fan item 1205 "Aviator 5" (unchanged); '
				.. 'light item 1206 "Example Room Light" -> "Aviator 5 Light"' }, r.log.texts("always"))
		end)

		it("shows a decline with the live name and the target, as ECR 5.5 words it", function()
			local r = rig({ names = names_of(TYPED_FAN, DEFAULT_LIGHT) }):settle("guarded")
			assert.same({ 'names (guarded): kept: fan item 1205 is "Example Room Fan", '
				.. 'not a default or a name the driver set; fan type 1811-5-54 would be "Aviator 5"' },
				r.log.texts("always"))
			local both = rig({ names = names_of(TYPED_FAN, TYPED_LIGHT) }):settle("guarded")
			assert.same({ 'names (guarded): kept: fan item 1205 is "Example Room Fan", '
				.. 'light item 1206 is "Example Room Light", not a default or a name the driver set; '
				.. 'fan type 1811-5-54 would be "Aviator 5"' }, both.log.texts("always"))
		end)

		it("shows same, and every refusal with its reason", function()
			local function line(over, mode)
				return rig(over):settle(mode or "forced").log.texts("always")[1]
			end
			assert.equal('names (forced): nothing to change: fan item 1205 is "Aviator 5", '
				.. 'light item 1206 is "Aviator 5 Light"', line({ names = names_of(TARGET_FAN, TARGET_LIGHT) }))
			assert.equal("names (forced): no fan is set up yet; nothing renamed", line({ pinned = false }))
			assert.equal("names (forced): the fan type is not read yet; nothing renamed", line({ fan_type = false }))
			assert.equal("names (forced): no name known for fan type 9999-9-99; nothing renamed",
				line({ fan_type = "9999-9-99" }))
			assert.equal("names (forced): this device's two items were not found (fan item 1205, light item none); "
				.. "nothing renamed", line({ opts = { ids = function() return FAN_ID, nil end } }))
			local busy = rig()
			busy.run("guarded")
			busy.job:run("guarded", function() end)
			assert.equal("names (guarded): busy: another naming is pending; nothing changed",
				busy.log.texts("always")[1])
		end)

		it("writes a name it could not read as a bare ? and an empty one as quotes", function()
			local r = rig({ unreadable = { [FAN_ID] = "raise" } }):settle("forced")
			assert.is_true(has(r.log.texts("always")[1], 'fan item 1205 ? -> "Aviator 5"'))
			local empty = rig({ names = names_of("", "") }):settle("forced")
			assert.is_true(has(empty.log.texts("always")[1], 'fan item 1205 "" -> "Aviator 5"'))
		end)

		it("cannot be made to forge a line by an owner's name or the fan's type", function()
			local r = rig({ names = names_of("Bad\nnames (forced): fake\r\tline", TYPED_LIGHT) }):settle("forced")
			assert.equal(1, #r.log.texts("always"))
			assert.is_nil(r.log.texts("always")[1]:find("%c"))
			assert.is_true(has(r.log.texts("always")[1], "Bad?names (forced): fake??line"))
			local typed = rig({ fan_type = "99\n99" }):settle("guarded")
			assert.is_nil(typed.log.texts("always")[1]:find("%c"))
			assert.is_true(has(typed.log.texts("always")[1], "fan type 99?99"))
		end)

		it("cuts a long name", function()
			local r = rig({ names = names_of(string.rep("n", 100), TYPED_LIGHT) }):settle("forced")
			assert.is_true(has(r.log.texts("always")[1], '"' .. string.rep("n", 60) .. '..."'))
			assert.is_false(has(r.log.texts("always")[1], string.rep("n", 61)))
		end)

		it("keeps the lookups and the read-back at the debug level", function()
			local r = rig():settle("guarded")
			local text = table.concat(r.log.texts("debug"), "\n")
			assert.is_true(has(text, "fan type 1811-5-54 is named"))
			assert.is_true(has(text, "items found: fan 1205, light 1206"))
			assert.is_true(has(text, "(ours)"))
			assert.is_true(has(text, "read back"))
			assert.same({}, r.log.texts("warn"))
			assert.same({}, r.log.texts("error"))
		end)

		it("warns when a rename is not confirmed, with the names it read and wanted", function()
			local r = rig({ ignore = { [LIGHT_ID] = true } }):settle("guarded")
			assert.equal(1, #r.log.texts("warn"))
			assert.is_true(has(r.log.texts("warn")[1], "names (guarded): not confirmed"))
			assert.is_true(has(r.log.texts("warn")[1],
				'light item 1206 is "Modern Forms Fan Light" (wanted "Aviator 5 Light")'))
		end)

		it("survives a logger that raises, one with no such level, and none that is given", function()
			local function kaput()
				error("log kaput")
			end
			local loud = rig({ opts = { log = { always = kaput, warn = kaput, debug = kaput, error = kaput } } })
			assert.has_no.errors(function()
				loud:settle("guarded")
			end)
			assert.equal("renamed", loud.dones[1].outcome)
			local bare = rig({ opts = { log = {} } })
			assert.has_no.errors(function()
				bare:settle("guarded")
			end)
			assert.equal("renamed", bare.dones[1].outcome)
		end)

		it("falls back to common.log when no logger is given", function()
			local saved = common_log.sink
			local seen = {}
			common_log.sink = function(line)
				seen[#seen + 1] = line
			end
			local ok, err = pcall(function()
				local r = rig({ opts = { log = false } })
				r:settle("guarded")
				assert.equal("renamed", r.dones[1].outcome)
			end)
			common_log.sink = saved
			assert(ok, err)
			assert.is_true(#seen >= 1)
			assert.is_true(has(seen[1], "names (guarded): fan item 1205"))
		end)
	end)

	describe("done", function()
		-- name, builder of the rig's options, mode, the outcome. Builders, because a run changes the
		-- names and flags it was given.
		local SCENARIOS = {
			{ "a rename", function() return {} end, "guarded", "renamed" },
			{ "a forced rename of typed names", function() return { names = names_of(TYPED_FAN, TYPED_LIGHT) } end,
				"forced", "renamed" },
			{ "nothing to change", function() return { names = names_of(TARGET_FAN, TARGET_LIGHT) } end, "guarded",
				"same" },
			{ "a decline", function() return { names = names_of(TYPED_FAN, DEFAULT_LIGHT) } end, "guarded", "kept" },
			{ "an unknown type", function() return { fan_type = "9999-9-99" } end, "guarded", "no_name" },
			{ "no type", function() return { fan_type = false } end, "guarded", "no_type" },
			{ "no ids", function() return { opts = { ids = function() return nil, nil end } } end, "guarded", "no_ids" },
			{ "no pin", function() return { pinned = false } end, "forced", "no_pin" },
			{ "a name that did not take", function() return { ignore = { [FAN_ID] = true } } end, "guarded",
				"unconfirmed" },
			{ "a rename that raises", function() return { explode = { [LIGHT_ID] = true } } end, "forced",
				"unconfirmed" },
			{ "an unreadable read-back", function() return { fail_reads_after = 2 } end, "guarded", "unconfirmed" },
			{ "no timer", function() return { timer_fails_at = 1 } end, "guarded", "unconfirmed" },
			{ "a timer that fires at once", function()
				return { opts = { timer = function(_, cb)
					cb()
					return nil
				end } }
			end, "guarded", "renamed" },
		}

		it("is called exactly once per run, however it ends, and nothing is pending afterwards", function()
			for _, case in ipairs(SCENARIOS) do
				local r = rig(case[2]()):settle(case[3])
				assert.equal(1, #r.dones, case[1])
				assert.equal(case[4], r.dones[1].outcome, case[1])
				assert.equal("table", type(r.dones[1].args), case[1])
				r.advance(100000)
				assert.equal(1, #r.dones, case[1])
				assert.is_false(r.job:busy(), case[1])
				assert.equal(0, r.clock.waiting(), case[1])
			end
		end)

		it("is called once per run when runs follow one another", function()
			local r = rig({ names = names_of(TYPED_FAN, TYPED_LIGHT) })
			r:settle("guarded")
			r:settle("forced")
			r:settle("forced")
			r:settle("guarded")
			local outcomes = {}
			for _, done in ipairs(r.dones) do
				outcomes[#outcomes + 1] = done.outcome
			end
			-- kept; renamed (and now ours); same; same
			assert.same({ "kept", "renamed", "same", "same" }, outcomes)
		end)

		it("is still called once when the job itself fails: the run ends unconfirmed and is no longer pending", function()
			-- a pair of shipped names that cannot be read makes the decision raise
			local broken = { setmetatable({}, { __index = function() error("pair kaput") end }) }
			local r = rig({ opts = { defaults = broken } })
			assert.has_no.errors(function()
				r:settle("guarded")
			end)
			assert.equal(1, #r.dones)
			assert.equal("unconfirmed", r.dones[1].outcome)
			assert.same({}, r.calls)
			assert.is_false(r.job:busy())
			assert.equal(1, #r.log.texts("error"))
			assert.is_true(has(r.log.texts("error")[1], "pair kaput"))
			-- the next click is not answered busy: it fails the same way, and is answered
			r:settle("guarded")
			assert.equal("unconfirmed", r.dones[2].outcome)
			assert.equal(2, #r.dones)
		end)

		it("is still called once when the job fails after the calls were made", function()
			-- the record is read twice, before the calls and after them; the second answer raises when read
			local reads = 0
			local hostile = setmetatable({}, { __index = function() error("record kaput") end })
			local store = { set = function() end, get = function()
				reads = reads + 1
				if reads == 1 then
					return nil
				end
				return hostile
			end }
			local r = rig({ opts = { store = store } })
			assert.has_no.errors(function()
				r:settle("forced")
			end)
			assert.equal(2, #r.calls)
			assert.equal(1, #r.dones)
			assert.equal("unconfirmed", r.dones[1].outcome)
			assert.is_false(r.job:busy())
			assert.equal(1, #r.log.texts("error"))
			assert.is_true(has(r.log.texts("error")[1], "record kaput"))
		end)

		it("is never called inside run(), except where no timer can be armed", function()
			for _, case in ipairs(SCENARIOS) do
				if case[1] ~= "no timer" and case[1] ~= "a timer that fires at once" then
					local r = rig(case[2]())
					r.run(case[3])
					assert.same({}, r.dones, case[1])
				end
			end
		end)

		it("may be missing: the run goes on and ends without one", function()
			local r = rig()
			assert.has_no.errors(function()
				r.job:run("guarded")
				r.advance(5000)
			end)
			assert.equal(2, #r.calls)
			assert.same({ fan = TARGET_FAN, light = TARGET_LIGHT, at = NOW }, r.stored.mf_names)
			assert.is_false(r.job:busy())
		end)

		it("may raise: the failure is logged, the job is no longer pending, and the record stands", function()
			local r = rig()
			r.job:run("guarded", function()
				error("callback kaput")
			end)
			assert.has_no.errors(function()
				r.advance(5000)
			end)
			assert.is_false(r.job:busy())
			assert.equal(1, #r.log.texts("error"))
			assert.is_true(has(r.log.texts("error")[1], "callback kaput"))
			assert.is_not_nil(r.stored.mf_names)
			r.run("guarded")
			r.advance(5000)
			assert.equal("same", r.dones[1].outcome)
		end)

		it("hands every outcome its args, as section 2.2 lists them", function()
			local by_name = {}
			for _, case in ipairs(SCENARIOS) do
				by_name[case[1]] = case
			end
			local function args_of(name)
				local case = by_name[name]
				return rig(case[2]()):settle(case[3]).dones[1].args
			end
			assert.same({ fan = TARGET_FAN, light = TARGET_LIGHT }, args_of("a rename"))
			assert.same({ fan = TARGET_FAN, light = TARGET_LIGHT }, args_of("nothing to change"))
			assert.same({ fan_live = TYPED_FAN, fan_to = TARGET_FAN, light_live = DEFAULT_LIGHT, light_to = TARGET_LIGHT },
				args_of("a decline"))
			assert.same({ fan_type = "9999-9-99" }, args_of("an unknown type"))
			for _, name in ipairs({ "no type", "no ids", "no pin", "a name that did not take" }) do
				assert.same({}, args_of(name), name)
			end
		end)
	end)

	describe("a job with nothing wired", function()
		it("answers instead of raising: no pin, and no timer to run a request", function()
			local saved = common_log.sink
			common_log.sink = function() end
			local ok, err = pcall(function()
				local job = rename.new()
				assert.is_false(job:busy())
				assert.equal("no_pin", job:plan("guarded").outcome)
				local outcome
				job:run("forced", function(o)
					outcome = o
				end)
				assert.equal("unconfirmed", outcome)
				assert.has_no.errors(function()
					job:stop()
					rename.new({}):stop()
					rename.new({ log = false })
				end)
			end)
			common_log.sink = saved
			assert(ok, err)
		end)
	end)
end)
