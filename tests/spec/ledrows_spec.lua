-- fan.ledrows on fakes: the keypad LED rows shown only while a keypad can use them (#178,
-- docs/keypad-leds-visibility-design.md: KL-D1 to KL-D10, the interface of section 2.1, the tests of section 3).
-- set_hidden records every call with the clock; the timer records its ms and callback, and advance() moves the fake
-- clock, firing every timer that falls due on the way in the order it falls due. changed() records its arguments.
--
-- The clock starts at 1,000 ms; start() is late init.

local ledrows = require("fan.ledrows")

local ROWS = ledrows.ROWS
local HIDE_MS = 8000
local BREEZE_ONLY = { "Breeze LED Animation", "Breeze LED Step (ms)", "Breeze LED Night Brightness (%)" }

local function fake_log()
	local l = { lines = {} }
	for _, level in ipairs({ "error", "warn", "info", "debug" }) do
		l[level] = function(fmt, ...)
			l.lines[#l.lines + 1] = { level = level, text = string.format(fmt, ...) }
		end
	end
	function l.has(level, needle)
		for _, line in ipairs(l.lines) do
			if line.level == level and line.text:find(needle, 1, true) then
				return true
			end
		end
		return false
	end
	return l
end

-- The module on fakes. r.calls: { name, hidden, at } per set_hidden; r.rows: [name] = the last state sent;
-- r.timers: every arm, { ms, cb, at, due, cancelled, fired }; r.changes: { shown, cause, at } per changed.
local function rig(opts)
	opts = opts or {}
	local r = { calls = {}, rows = {}, timers = {}, changes = {}, clock = 1000, log = fake_log() }
	r.l = ledrows.new({
		set_hidden = function(name, hidden)
			r.calls[#r.calls + 1] = { name = name, hidden = hidden, at = r.clock }
			if r.fail_set and r.fail_set(name) then
				error("refused")
			end
			r.rows[name] = hidden
		end,
		timer = function(ms, cb)
			if r.fail_timer then
				error("no timer")
			end
			local t = { ms = ms, cb = cb, at = r.clock, due = r.clock + ms, cancelled = false, fired = false }
			function t:Cancel()
				if r.fail_cancel then
					error("cannot cancel")
				end
				self.cancelled = true
			end
			r.timers[#r.timers + 1] = t
			return t
		end,
		now = not opts.no_clock and function()
			return r.clock
		end or nil,
		changed = not opts.no_changed and function(shown, cause)
			r.changes[#r.changes + 1] = { shown = shown, cause = cause, at = r.clock }
			if r.fail_changed then
				error("changed refused")
			end
		end or nil,
		log = r.log,
	})
	return r
end

-- Moves the clock `ms` on, firing every live timer due by then, earliest first (one armed while firing too).
local function advance(r, ms)
	local target = r.clock + ms
	while true do
		local nxt
		for _, t in ipairs(r.timers) do
			if not t.cancelled and not t.fired and t.due <= target and (nxt == nil or t.due < nxt.due) then
				nxt = t
			end
		end
		if nxt == nil then
			break
		end
		r.clock = nxt.due
		nxt.fired = true
		nxt.cb()
	end
	r.clock = target
end

local function live(r)
	local out = {}
	for _, t in ipairs(r.timers) do
		if not t.cancelled and not t.fired then
			out[#out + 1] = t
		end
	end
	return out
end

-- The set_hidden calls since the last take.
local function take(r)
	local calls = r.calls
	r.calls = {}
	return calls
end

-- The calls grouped by the clock they were made at: { { at, calls }, ... } in order.
local function sends(calls)
	local out = {}
	for _, call in ipairs(calls) do
		local last = out[#out]
		if last == nil or last.at ~= call.at then
			last = { at = call.at, calls = {} }
			out[#out + 1] = last
		end
		last.calls[#last.calls + 1] = call
	end
	return out
end

-- Asserts one send: every row once, in ROWS order, hidden per `hidden(name)`.
local function full_send(send, hidden)
	assert.equal(#ROWS, #send.calls)
	for i, name in ipairs(ROWS) do
		assert.equal(name, send.calls[i].name)
		assert.equal(hidden(name), send.calls[i].hidden, name)
	end
end

local function all_shown()
	return false
end

local function all_hidden()
	return true
end

local function breeze_hidden(name)
	return ledrows.BREEZE[name] == true
end

local function count(t)
	local n = 0
	for _ in pairs(t) do
		n = n + 1
	end
	return n
end

-- A rig started with `view`, its first two sends played and taken.
local function started(view, opts)
	local r = rig(opts)
	r.l:update(view)
	r.l:start()
	advance(r, 1500)
	take(r)
	return r
end

describe("fan.ledrows", function()
	describe("the rows (KL-D1)", function()
		local function xml_rows()
			local file = assert(io.open("src/modernforms_fan/driver.xml"))
			local text = file:read("*a")
			file:close()
			text = text:gsub("<!%-%-.-%-%->", "")
			local props = assert(text:match("<properties>(.-)</properties>"))
			local names = {}
			for body in props:gmatch("<property>(.-)</property>") do
				names[#names + 1] = body:match("<name>(.-)</name>")
			end
			return names
		end

		it("are the 20 rows after Keypad Links, in driver.xml's order", function()
			local names = xml_rows()
			local first
			for i, name in ipairs(names) do
				if name == ROWS[1] then
					first = i
					break
				end
			end
			assert.is_not_nil(first)
			assert.equal("Keypad Links", names[first - 1])
			assert.equal(20, #ROWS)
			for i, name in ipairs(ROWS) do
				assert.equal(names[first + i - 1], name)
			end
			assert.equal("Debug Mode", names[first + #ROWS])
		end)

		it("are each declared once, Keypad Links never among them", function()
			local seen = {}
			for _, name in ipairs(xml_rows()) do
				seen[name] = (seen[name] or 0) + 1
			end
			local mine = {}
			for _, name in ipairs(ROWS) do
				assert.equal(1, seen[name], name)
				assert.is_nil(mine[name], name)
				mine[name] = true
				assert.are_not.equal("Keypad Links", name)
			end
		end)

		it("include the three Breeze-only rows (KL-D3), Breeze LED Bottom not among them", function()
			assert.equal(3, count(ledrows.BREEZE))
			local in_rows = {}
			for _, name in ipairs(ROWS) do
				in_rows[name] = true
			end
			for _, name in ipairs(BREEZE_ONLY) do
				assert.is_true(ledrows.BREEZE[name], name)
				assert.is_true(in_rows[name], name)
			end
			assert.is_nil(ledrows.BREEZE["Breeze LED Bottom"])
		end)

		it("hide after 8 s and are sent at 400 ms and 1,500 ms (KL-D4, KL-D6)", function()
			assert.equal(8000, ledrows.HIDE_MS)
			assert.same({ 400, 1500 }, ledrows.SEND_MS)
		end)
	end)

	describe("before start", function()
		it("only records: nothing sent, no timer, no changed", function()
			local r = rig()
			r.l:update({ speed_bound = true, has_breeze = true })
			r.l:update({ speed_bound = false, has_breeze = false })
			r.l:update({ speed_bound = true })
			advance(r, 20000)
			assert.same({}, r.calls)
			assert.equal(0, #r.timers)
			assert.same({}, r.changes)
			assert.is_true(r.l:shown()) -- as driver.xml shows the rows (KF3)
			assert.is_false(r.l:debug().started)
		end)
	end)

	describe("start (late init, KL-D6)", function()
		it("sends every row at 400 ms and again at 1,500 ms with its state, no changed", function()
			local r = rig()
			r.l:update({ speed_bound = true, has_breeze = true })
			r.l:start()
			assert.same({}, r.calls) -- nothing in the burst of late init's texts (KF4)
			advance(r, 399)
			assert.same({}, r.calls)
			advance(r, 1)
			advance(r, 1099)
			advance(r, 1)
			advance(r, 20000)
			local s = sends(take(r))
			assert.equal(2, #s)
			assert.equal(1400, s[1].at)
			assert.equal(2500, s[2].at)
			full_send(s[1], all_shown)
			full_send(s[2], all_shown)
			assert.same({}, r.changes)
			assert.equal(0, #live(r))
			assert.is_true(r.l:shown())
		end)

		it("hides the Breeze-only rows of a fan without Breeze (KL-D3)", function()
			local r = rig()
			r.l:update({ speed_bound = true, has_breeze = false })
			r.l:start()
			advance(r, 20000)
			local s = sends(take(r))
			assert.equal(2, #s)
			full_send(s[1], breeze_hidden)
			full_send(s[2], breeze_hidden)
			assert.same({}, r.changes)
			assert.is_true(r.l:shown())
		end)

		it("shows the Breeze-only rows while Breeze is not known yet (nil)", function()
			local r = rig()
			r.l:update({ speed_bound = true })
			r.l:start()
			advance(r, 20000)
			local s = sends(take(r))
			assert.equal(2, #s)
			full_send(s[1], all_shown)
			full_send(s[2], all_shown)
		end)

		it("with nothing bound fails open, then hides 8 s after late init without a Last Action (KV1)", function()
			local r = rig()
			r.l:update({ speed_bound = false })
			r.l:start()
			advance(r, 1500)
			local s = sends(take(r))
			assert.equal(2, #s)
			full_send(s[1], all_shown)
			full_send(s[2], all_shown)
			assert.is_true(r.l:shown())
			assert.equal("start", r.l:debug().hide.cause)
			advance(r, HIDE_MS - 1500 - 1)
			assert.same({}, r.calls)
			assert.same({}, r.changes)
			advance(r, 1) -- 8 s after start
			assert.same({ { shown = false, cause = "start", at = 1000 + HIDE_MS } }, r.changes)
			assert.is_false(r.l:shown())
			assert.same({}, r.calls) -- the sends come 400 ms after the texts `changed` writes
			advance(r, 20000)
			s = sends(take(r))
			assert.equal(2, #s)
			assert.equal(1000 + HIDE_MS + 400, s[1].at)
			assert.equal(1000 + HIDE_MS + 1500, s[2].at)
			full_send(s[1], all_hidden)
			full_send(s[2], all_hidden)
			assert.equal(1, #r.changes)
		end)

		it("keeps the rows of a keypad the first read missed and the second look found (KV21)", function()
			local r = rig()
			r.l:start() -- nothing recorded: nothing bound
			advance(r, 5000)
			take(r)
			r.l:update({ speed_bound = true }) -- the links' second look at 5 s
			advance(r, 20000)
			assert.same({}, r.calls)
			assert.same({}, r.changes)
			assert.is_true(r.l:shown())
			assert.is_nil(r.l:debug().hide)
		end)

		it("a second start sends the applied state again, nothing else", function()
			local r = started({ speed_bound = true, has_breeze = false })
			r.l:start()
			advance(r, 20000)
			local s = sends(take(r))
			assert.equal(2, #s)
			full_send(s[1], breeze_hidden)
			full_send(s[2], breeze_hidden)
			assert.same({}, r.changes)
		end)
	end)

	describe("bindings after start (KL-D4)", function()
		it("an unbind hides only after 8 s of nothing bound, then changed(false, binding)", function()
			local r = started({ speed_bound = true })
			r.l:update({ speed_bound = false })
			assert.equal(1, #live(r))
			assert.equal(HIDE_MS, live(r)[1].ms)
			advance(r, HIDE_MS - 1)
			assert.same({}, r.calls)
			assert.same({}, r.changes)
			assert.is_true(r.l:shown())
			advance(r, 1)
			assert.same({ { shown = false, cause = "binding", at = r.clock } }, r.changes)
			assert.is_false(r.l:shown())
			local t0 = r.clock
			advance(r, 20000)
			local s = sends(take(r))
			assert.equal(2, #s)
			assert.equal(t0 + 400, s[1].at)
			assert.equal(t0 + 1500, s[2].at)
			full_send(s[1], all_hidden)
			full_send(s[2], all_hidden)
		end)

		it("a bind inside the 8 s cancels the hide: nothing sent, no changed (KV4)", function()
			local r = started({ speed_bound = true })
			r.l:update({ speed_bound = false })
			local hide = live(r)[1]
			advance(r, 3000)
			r.l:update({ speed_bound = true })
			assert.is_true(hide.cancelled)
			advance(r, 20000)
			assert.same({}, r.calls)
			assert.same({}, r.changes)
			assert.is_true(r.l:shown())
		end)

		it("waits for 8 s without a break: a bind in between starts the wait again", function()
			local r = started({ speed_bound = true })
			r.l:update({ speed_bound = false })
			advance(r, 3000)
			r.l:update({ speed_bound = true })
			advance(r, 2000)
			r.l:update({ speed_bound = false })
			local t0 = r.clock
			advance(r, HIDE_MS - 1)
			assert.same({}, r.changes)
			advance(r, 1)
			assert.same({ { shown = false, cause = "binding", at = t0 + HIDE_MS } }, r.changes)
		end)

		it("a show is at once: changed(true, binding), then both sends", function()
			local r = started({ speed_bound = false }) -- the hide is due at 9,000
			advance(r, HIDE_MS)
			take(r)
			r.changes = {}
			assert.is_false(r.l:shown())
			r.l:update({ speed_bound = true })
			assert.same({ { shown = true, cause = "binding", at = r.clock } }, r.changes)
			assert.is_true(r.l:shown())
			local t0 = r.clock
			assert.same({}, r.calls)
			advance(r, 20000)
			local s = sends(take(r))
			assert.equal(2, #s)
			assert.equal(t0 + 400, s[1].at)
			assert.equal(t0 + 1500, s[2].at)
			full_send(s[1], all_shown)
			full_send(s[2], all_shown)
			assert.equal(1, #r.changes)
		end)

		it("a show follows the Breeze known at that moment", function()
			local r = started({ speed_bound = false })
			advance(r, HIDE_MS)
			take(r)
			r.l:update({ speed_bound = false, has_breeze = false }) -- recorded while hidden: nothing sent
			advance(r, 20000)
			assert.same({}, r.calls)
			r.l:update({ speed_bound = true, has_breeze = false })
			advance(r, 20000)
			local s = sends(take(r))
			assert.equal(2, #s)
			full_send(s[1], breeze_hidden)
			full_send(s[2], breeze_hidden)
		end)

		it("a bind after a start whose hide was cancelled and an unbind is a binding hide", function()
			local r = rig()
			r.l:start()
			advance(r, 2000)
			r.l:update({ speed_bound = true })
			advance(r, 1000)
			r.l:update({ speed_bound = false })
			assert.equal("binding", r.l:debug().hide.cause)
			advance(r, HIDE_MS)
			assert.same({ { shown = false, cause = "binding", at = r.clock } }, r.changes)
		end)
	end)

	describe("Breeze (KL-D3, has_breeze alone)", function()
		it("false while shown hides the three Breeze rows at once, no changed, no hide timer", function()
			local r = started({ speed_bound = true })
			r.l:update({ speed_bound = true, has_breeze = false })
			assert.equal(1, #live(r)) -- the first send only
			advance(r, 20000)
			local s = sends(take(r))
			assert.equal(2, #s)
			full_send(s[1], breeze_hidden)
			full_send(s[2], breeze_hidden)
			assert.same({}, r.changes)
			assert.is_true(r.l:shown())
			assert.is_false(r.l:debug().breeze_shown)
		end)

		local function back_to(view)
			local r = started({ speed_bound = true, has_breeze = false })
			r.l:update(view)
			advance(r, 20000)
			local s = sends(take(r))
			assert.equal(2, #s)
			full_send(s[1], all_shown)
			full_send(s[2], all_shown)
			assert.same({}, r.changes)
		end

		it("true again shows them at once", function()
			back_to({ speed_bound = true, has_breeze = true })
		end)

		it("nil (not known) again shows them at once", function()
			back_to({ speed_bound = true })
		end)

		it("nil to true changes no row: nothing sent", function()
			local r = started({ speed_bound = true })
			r.l:update({ speed_bound = true, has_breeze = true })
			advance(r, 20000)
			assert.same({}, r.calls)
			assert.equal(2, #r.timers) -- the start's two sends only
		end)

		it("a change while the hide is pending leaves it where it was", function()
			local r = started({ speed_bound = true })
			r.l:update({ speed_bound = false })
			local t0 = r.clock
			advance(r, 4000)
			r.l:update({ speed_bound = false, has_breeze = false })
			r.l:update({ speed_bound = false, has_breeze = true })
			assert.same({}, r.calls)
			advance(r, HIDE_MS - 4000)
			assert.same({ { shown = false, cause = "binding", at = t0 + HIDE_MS } }, r.changes)
			advance(r, 20000)
			local s = sends(take(r))
			assert.equal(2, #s)
			full_send(s[1], all_hidden)
		end)
	end)

	describe("sends (KL-D6)", function()
		it("the same inputs again send nothing", function()
			local r = started({ speed_bound = true, has_breeze = false })
			r.l:update({ speed_bound = true, has_breeze = false })
			r.l:update({ speed_bound = true, has_breeze = false, other = 1 })
			advance(r, 20000)
			assert.same({}, r.calls)
			assert.equal(2, #r.timers)
		end)

		it("reads anything but true as not bound and anything but true or false as Breeze unknown", function()
			local r = started({ speed_bound = true, has_breeze = nil })
			r.l:update({ speed_bound = true, has_breeze = "yes" })
			advance(r, 20000)
			assert.same({}, r.calls)
			r.l:update({ speed_bound = 1 })
			assert.equal("binding", r.l:debug().hide.cause)
			local r2 = started({ speed_bound = true })
			r2.l:update("not a table")
			assert.is_false(r2.l:debug().speed_bound)
			assert.is_not_nil(r2.l:debug().hide)
		end)

		it("an apply in the middle of the sends replaces them: no send with the old state", function()
			local r = rig()
			r.l:update({ speed_bound = true })
			r.l:start()
			local first = live(r)[1]
			advance(r, 200)
			r.l:update({ speed_bound = true, has_breeze = false })
			assert.is_true(first.cancelled)
			advance(r, 20000)
			local s = sends(take(r))
			assert.equal(2, #s)
			assert.equal(1200 + 400, s[1].at)
			assert.equal(1200 + 1500, s[2].at)
			full_send(s[1], breeze_hidden)
			full_send(s[2], breeze_hidden)
		end)

		it("each send carries every row, so a dropped one heals at the next", function()
			local r = started({ speed_bound = true })
			r.l:update({ speed_bound = true, has_breeze = false })
			advance(r, 400)
			r.rows = {} -- Composer dropped the first send
			advance(r, 1100)
			assert.equal(#ROWS, count(r.rows))
			for _, name in ipairs(ROWS) do
				assert.equal(breeze_hidden(name), r.rows[name], name)
			end
		end)

		it("one send timer at a time beside the hide", function()
			local r = rig()
			r.l:start() -- nothing bound: the sends and the hide
			assert.equal(2, #live(r))
			advance(r, 400)
			assert.equal(2, #live(r))
			advance(r, 1100)
			assert.equal(1, #live(r))
			assert.equal(HIDE_MS, live(r)[1].ms)
		end)
	end)

	describe("stop", function()
		it("cancels every timer and sends nothing, then ignores everything", function()
			local r = rig()
			r.l:start()
			advance(r, 100)
			r.l:stop()
			for _, t in ipairs(r.timers) do
				assert.is_true(t.cancelled)
			end
			r.l:update({ speed_bound = true, has_breeze = false })
			r.l:start()
			r.l:stop()
			advance(r, 20000)
			assert.same({}, r.calls)
			assert.same({}, r.changes)
			assert.is_true(r.l:debug().stopped)
		end)

		it("cancels a pending hide", function()
			local r = started({ speed_bound = true })
			r.l:update({ speed_bound = false })
			r.l:stop()
			advance(r, 20000)
			assert.same({}, r.calls)
			assert.same({}, r.changes)
			assert.is_true(r.l:shown())
		end)
	end)

	describe("failures (every callback through pcall)", function()
		it("a throwing set_hidden is survived: the other rows are sent, a warning logged", function()
			local r = rig()
			r.fail_set = function(name)
				return name == "Speed LED Colors"
			end
			r.l:update({ speed_bound = true })
			r.l:start()
			advance(r, 20000)
			local s = sends(take(r))
			assert.equal(2, #s)
			assert.equal(#ROWS, #s[1].calls)
			assert.equal(#ROWS, #s[2].calls)
			assert.equal(#ROWS - 1, count(r.rows))
			assert.is_true(r.log.has("warn", "send 1: 1 of 20 rows could not be set (Speed LED Colors"))
			assert.equal(2, r.l:debug().failures)
		end)

		it("a throwing changed is survived and the rows still go out", function()
			local r = started({ speed_bound = true })
			r.fail_changed = true
			r.l:update({ speed_bound = false })
			advance(r, HIDE_MS)
			assert.is_true(r.log.has("warn", "changed(false, binding) failed"))
			advance(r, 20000)
			local s = sends(take(r))
			assert.equal(2, #s)
			full_send(s[2], all_hidden)
		end)

		it("without a timer the sends go out at once and the hide is not armed (fail open)", function()
			local r = rig()
			r.fail_timer = true
			r.l:start()
			local s = sends(take(r))
			assert.equal(1, #s) -- both sends, at once
			assert.equal(2 * #ROWS, #s[1].calls)
			for _, call in ipairs(s[1].calls) do
				assert.is_false(call.hidden)
			end
			assert.is_nil(r.l:debug().hide)
			assert.is_true(r.l:shown())
			assert.is_true(r.log.has("warn", "no timer for the hide"))
			assert.is_true(r.log.has("warn", "no timer for send 1"))
		end)

		it("a Cancel that raises is warned and its timer's callback ignored", function()
			local r = started({ speed_bound = true })
			r.l:update({ speed_bound = false })
			r.fail_cancel = true
			r.l:update({ speed_bound = true })
			assert.is_true(r.log.has("warn", "the hide could not be cancelled"))
			advance(r, 20000) -- the hide's timer fires, not cancelled
			assert.same({}, r.calls)
			assert.same({}, r.changes)
			assert.is_true(r.l:shown())
		end)

		it("a stale send callback after a Cancel that raised sends nothing old", function()
			local r = rig()
			r.l:update({ speed_bound = true })
			r.l:start()
			r.fail_cancel = true
			advance(r, 100)
			r.l:update({ speed_bound = true, has_breeze = false })
			advance(r, 20000)
			assert.is_true(r.log.has("warn", "a pending send could not be cancelled"))
			local s = sends(take(r))
			assert.equal(2, #s) -- the old chain's 400 ms callback fired and was ignored
			full_send(s[1], breeze_hidden)
			full_send(s[2], breeze_hidden)
		end)

		it("works with no options at all", function()
			local log = require("common.log")
			local sink = log.sink
			log.sink = function() end
			finally(function()
				log.sink = sink
			end)
			local l = ledrows.new()
			assert.has_no.errors(function()
				l:update({ speed_bound = true })
				l:start()
				l:update({ speed_bound = false })
				l:debug()
				l:stop()
			end)
		end)

		it("works without changed and without a clock", function()
			local r = rig({ no_changed = true, no_clock = true })
			r.l:start()
			assert.is_nil(r.l:debug().hide.left)
			advance(r, HIDE_MS)
			assert.is_false(r.l:shown())
		end)
	end)

	describe("debug", function()
		it("tells the inputs, the rows as applied, the pending hide and the counts", function()
			local r = rig()
			r.l:update({ speed_bound = false, has_breeze = false })
			r.l:start()
			advance(r, 3000)
			local d = r.l:debug()
			assert.is_true(d.started)
			assert.is_false(d.stopped)
			assert.is_false(d.speed_bound)
			assert.is_false(d.has_breeze)
			assert.is_true(d.shown)
			assert.is_false(d.breeze_shown)
			assert.equal(3, d.hidden)
			assert.equal(20, d.rows)
			assert.same({ cause = "start", since = 1000, left = HIDE_MS - 3000 }, d.hide)
			assert.is_nil(d.send)
			assert.equal(1, d.applies)
			assert.equal(2, d.sends)
			assert.equal(0, d.failures)
			advance(r, HIDE_MS)
			d = r.l:debug()
			assert.is_false(d.shown)
			assert.equal(20, d.hidden)
			assert.is_nil(d.hide)
			assert.equal(2, d.applies)
		end)
	end)
end)
