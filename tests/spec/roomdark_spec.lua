-- fan.roomdark on fakes: the LED animations pause in a dark room at night (#233, revised by #240;
-- docs/room-dark-pause-design.md, RD-D3 to RD-D8 and RD-D11, the edge cases RE1 to RE14 and the interface of
-- section 3). The pause is a condition, not a latch: paused exactly while enabled, inside the window (set_night(true),
-- sunset to 30 minutes after sunrise as the driver computes it), with at least one light and every light known off;
-- nothing is saved. The fakes stand in for Director: lights() returns the room as { [proxy_id] = name }, listen(id)
-- records the listener and, like Director, reports the light's Light State at once from inside the call
-- (r.values), unlisten(id) records the removal, and on_change records every change with its why.
--
-- Unless a spec says otherwise: two lights in the room, Example Lamp (123) and Ceiling (456), both reporting
-- off ("0") when they are listened to; the module enabled; "at night" means inside the window.

local roomdark = require("fan.roomdark")

local function fake_log()
	local l = { lines = {} }
	for _, level in ipairs({ "always", "error", "warn", "info", "debug" }) do
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
	function l.count(level, needle)
		local n = 0
		for _, line in ipairs(l.lines) do
			if line.level == level and (needle == nil or line.text:find(needle, 1, true)) then
				n = n + 1
			end
		end
		return n
	end
	function l.texts(level)
		local out = {}
		for _, line in ipairs(l.lines) do
			if line.level == level then
				out[#out + 1] = line.text
			end
		end
		return out
	end
	function l.clear()
		l.lines = {}
	end
	return l
end

-- The module on fakes. r.room: what lights() returns; r.values: [id] = what Director reports from inside
-- listen(id) (nil: no report); r.calls: { "lights" }, { "listen", id }, { "unlisten", id } in order;
-- r.listening: [id] = true while listened; r.changes: { paused, why } per on_change. r.load and r.save are busted
-- spies passed as opts.load and opts.save, as build 244's driver passed them (r.load says a pause was saved): the
-- module must never call them (RD-D8, #240). Hooks: r.fail_lights (fn returning lights()'s results, or raising),
-- r.fail_listen(id) -> nil | "false" | "raise", r.fail_unlisten, r.fail_change, r.on_change_hook(paused, why).
local function rig(opts)
	opts = opts or {}
	local r = {
		room = { [123] = "Example Lamp", [456] = "Ceiling" },
		values = { [123] = "0", [456] = "0" },
		calls = {}, listening = {}, changes = {}, log = fake_log(),
		load = spy.new(function()
			return true
		end),
		save = spy.new(function() end),
	}
	local o = {
		lights = function()
			r.calls[#r.calls + 1] = { "lights" }
			if r.fail_lights then
				return r.fail_lights()
			end
			return r.room
		end,
		listen = function(id)
			r.calls[#r.calls + 1] = { "listen", id }
			local how = r.fail_listen and r.fail_listen(id)
			if r.values[id] ~= nil then
				r.rd:light(id, r.values[id]) -- Director reports at once, inside the register call
			end
			if how == "raise" then
				error("register refused")
			elseif how == "false" then
				return false, "no such device"
			end
			r.listening[id] = true
			if opts.listen_returns_nothing then
				return
			end
			return true
		end,
		unlisten = function(id)
			r.calls[#r.calls + 1] = { "unlisten", id }
			r.listening[id] = nil
			if r.fail_unlisten then
				error("unregister refused")
			end
		end,
		load = r.load,
		save = r.save,
		on_change = function(paused, why)
			r.changes[#r.changes + 1] = { paused, why }
			if r.on_change_hook then
				r.on_change_hook(paused, why)
			end
			if r.fail_change then
				error("driver broke")
			end
		end,
		log = r.log,
	}
	for _, name in ipairs(opts.without or {}) do
		o[name] = nil
	end
	r.rd = roomdark.new(o)
	function r.count(kind, id)
		local n = 0
		for _, call in ipairs(r.calls) do
			if call[1] == kind and (id == nil or call[2] == id) then
				n = n + 1
			end
		end
		return n
	end
	return r
end

-- A rig started at night (or by day with night = false), enabled unless told otherwise.
local function started(opts)
	opts = opts or {}
	local r = rig(opts)
	if opts.room then
		r.room = opts.room
	end
	if opts.values then
		r.values = opts.values
	end
	if opts.enabled ~= nil then
		r.rd:configure({ enabled = opts.enabled })
	end
	r.rd:set_night(opts.night ~= false)
	r.rd:start()
	return r
end

local function counts(rd)
	return { rd:counts() }
end

-- RD-D8 (#240): the load and save build 244's driver passed are never called.
local function untouched(r)
	assert.spy(r.load).was_not_called()
	assert.spy(r.save).was_not_called()
end

-- No line about a saved or restored pause, at any level (RD-D8, #240).
local function no_restore_lines(r)
	for _, line in ipairs(r.log.lines) do
		assert.is_nil(line.text:find("saved", 1, true), line.text)
		assert.is_nil(line.text:find("restor", 1, true), line.text)
	end
end

describe("fan.roomdark", function()
	describe("value parsing (RD-D4)", function()
		local cases = {
			{ "1", "on" }, { "true", "on" }, { "TRUE", "on" }, { "True", "on" }, { " 1 ", "on" }, { "100", "on" },
			{ "0.5", "on" }, { 1, "on" }, { 42, "on" }, { 0.01, "on" }, { true, "on" },
			{ "0", "off" }, { "false", "off" }, { "FALSE", "off" }, { "False", "off" }, { "0.0", "off" },
			{ " 0 ", "off" }, { 0, "off" }, { false, "off" },
			{ "", "unknown" }, { "on", "unknown" }, { "yes", "unknown" }, { "-1", "unknown" }, { -1, "unknown" },
			{ "nan", "unknown" }, { 0 / 0, "unknown" }, { {}, "unknown" },
		}
		for _, case in ipairs(cases) do
			it(("reads %s as %s"):format(type(case[1]) == "string" and ('"' .. case[1] .. '"') or tostring(case[1]),
				case[2]), function()
				local r = started({ night = false, values = {} })
				r.rd:light(123, case[1])
				local state
				for _, entry in ipairs(r.rd:debug().list) do
					if entry.id == 123 then
						state = entry.state
					end
				end
				assert.are.equal(case[2], state)
			end)
		end

		it("reads nil as unknown and keeps an unreported light unknown", function()
			local r = started({ night = false, values = { [456] = "0" } })
			assert.are.same({ 2, 0, 1 }, counts(r.rd))
			r.rd:light(456, nil)
			assert.are.same({ 2, 0, 2 }, counts(r.rd))
		end)

		it("takes an id given as a numeric string", function()
			local r = started({ night = false, values = {} })
			r.rd:light("123", "1")
			assert.are.same({ 2, 1, 1 }, counts(r.rd))
		end)

		it("ignores a report for an id not watched", function()
			local r = started()
			assert.is_true(r.rd:paused())
			r.rd:light(789, "1")
			r.rd:light("junk", "1")
			assert.is_true(r.rd:paused())
			assert.are.same({ 2, 0, 0 }, counts(r.rd))
			assert.is_true(r.log.has("debug", "a report from device 789, not watched; ignored"))
		end)
	end)

	describe("before start()", function()
		it("calls nothing: no lights read, no listener, no on_change, no load or save", function()
			local r = rig()
			r.rd:configure({ enabled = true })
			r.rd:set_night(true)
			r.rd:scan("sunset")
			r.rd:light(123, "1")
			r.rd:set_night(false)
			r.rd:configure({ enabled = false })
			r.rd:configure({ enabled = true })
			assert.are.same({}, r.calls)
			assert.are.same({}, r.changes)
			untouched(r)
			assert.is_false(r.rd:paused())
			assert.are.same({ 0, 0, 0 }, counts(r.rd))
		end)

		it("keeps configure and set_night for the start", function()
			local r = rig()
			r.rd:configure({ enabled = false })
			r.rd:set_night(true)
			r.rd:start()
			assert.is_false(r.rd:paused())
			assert.are.same({}, r.changes)
			local d = r.rd:debug()
			assert.is_false(d.enabled)
			assert.is_true(d.night)
			assert.is_true(d.started)
		end)

		it("keeps only the last set_night for the start", function()
			local r = rig()
			r.rd:set_night(true)
			r.rd:set_night(false)
			r.rd:start()
			assert.is_false(r.rd:paused())
			assert.are.same({}, r.changes)
			assert.is_false(r.rd:debug().night)
			local again = rig()
			again.rd:set_night(false)
			again.rd:set_night(true)
			again.rd:start()
			assert.is_true(again.rd:paused())
		end)

		it("starts enabled (the property's default) when configure never came", function()
			local r = rig()
			assert.is_true(r.rd:debug().enabled)
			r.rd:set_night(true)
			r.rd:start()
			assert.is_true(r.rd:paused())
		end)

		it("is harmless to start twice", function()
			local r = started()
			r.rd:start()
			assert.are.equal(1, #r.changes)
			assert.are.equal(1, r.count("lights"))
			assert.are.equal(2, r.count("listen"))
		end)
	end)

	describe("the pause starts (RD-D6)", function()
		it("at the start when every light reports off at night from inside listen: once", function()
			local r = started()
			assert.is_true(r.rd:paused())
			assert.are.same({ { true, "both lights in the room are off after sunset" } }, r.changes)
			assert.are.equal(1, r.log.count("always"))
			assert.is_true(r.log.has("always", "LED animations paused: both lights in the room are off after sunset"))
		end)

		it("names one light and many lights in plain English", function()
			local one = started({ room = { [7] = "Lamp" }, values = { [7] = "0" } })
			assert.are.same({ true, "the only light in the room is off after sunset" }, one.changes[1])
			local four = started({
				room = { [1] = "A", [2] = "B", [3] = "C", [4] = "D" },
				values = { [1] = "0", [2] = "0", [3] = "0", [4] = "0" },
			})
			assert.are.same({ true, "all 4 lights in the room are off after sunset" }, four.changes[1])
		end)

		it("when the last light reports off at night (RE5)", function()
			local r = started({ values = { [123] = "1", [456] = "0" } })
			assert.is_false(r.rd:paused())
			assert.are.same({}, r.changes)
			r.rd:light(123, "0")
			assert.is_true(r.rd:paused())
			assert.are.same({ { true, "both lights in the room are off after sunset" } }, r.changes)
		end)

		it("at sunset when every light was off by day (RE7), not by day (RE11)", function()
			local r = started({ night = false })
			assert.is_false(r.rd:paused())
			r.rd:light(123, "0")
			assert.is_false(r.rd:paused())
			r.rd:set_night(true)
			assert.is_true(r.rd:paused())
			assert.are.equal(1, #r.changes)
		end)

		it("at a later look of the sun at night only when not yet paused, never twice", function()
			local r = started()
			r.rd:set_night(true)
			r.rd:set_night(true)
			assert.are.equal(1, #r.changes)
			assert.are.equal(1, r.log.count("always"))
		end)

		it("when the property is set back to Room lights off after sunset at night", function()
			local r = started({ enabled = false })
			assert.is_false(r.rd:paused())
			r.rd:configure({ enabled = true })
			assert.is_true(r.rd:paused())
			assert.are.same({ { true, "both lights in the room are off after sunset" } }, r.changes)
		end)

		it("not while a light is unknown, and once it reports off (RE13)", function()
			local r = started({ values = { [123] = "0" } })
			assert.is_false(r.rd:paused())
			assert.are.same({ 2, 0, 1 }, counts(r.rd))
			r.rd:light(456, "unavailable")
			assert.is_false(r.rd:paused())
			r.rd:light(456, "0")
			assert.is_true(r.rd:paused())
		end)

		it("not while disabled, and repeated off reports while paused change nothing", function()
			local r = started({ enabled = false })
			r.rd:light(123, "0")
			assert.is_false(r.rd:paused())
			r.rd:configure({ enabled = true })
			r.rd:light(123, "0")
			r.rd:light(456, "false")
			assert.are.equal(1, #r.changes)
		end)

		it("when a scan drops the only light that was on", function()
			local r = started({ values = { [123] = "0", [456] = "1" } })
			assert.is_false(r.rd:paused())
			r.room = { [123] = "Example Lamp" }
			r.rd:scan("6-hourly")
			assert.are.equal(1, r.count("unlisten", 456))
			assert.is_true(r.rd:paused())
			assert.are.same({ true, "the only light in the room is off after sunset" }, r.changes[1])
		end)
	end)

	describe("the pause ends (RD-D7)", function()
		it("when a light reports on, naming it", function()
			local r = started()
			r.rd:light(456, "1")
			assert.is_false(r.rd:paused())
			assert.are.same({ false, "Ceiling (456) came on" }, r.changes[2])
			assert.are.equal(2, #r.changes)
			assert.is_true(r.log.has("always", "LED animations resumed: Ceiling (456) came on"))
		end)

		it("once: a second light on, or the same again, does nothing more", function()
			local r = started()
			r.rd:light(456, "1")
			r.rd:light(456, "1")
			r.rd:light(123, "100")
			assert.are.equal(2, #r.changes)
		end)

		it("does nothing when a light reports on while not paused", function()
			local r = started({ values = { [123] = "1", [456] = "0" } })
			r.rd:light(123, "1")
			r.rd:light(456, "true")
			assert.are.same({}, r.changes)
		end)

		it("inside the window, a light on then off pauses again, as often as it happens", function()
			local r = started()
			r.rd:light(123, "1")
			r.rd:light(123, "0")
			assert.is_true(r.rd:paused())
			r.rd:light(456, "1")
			r.rd:light(456, "0")
			assert.is_true(r.rd:paused())
			assert.are.same({
				{ true, "both lights in the room are off after sunset" },
				{ false, "Example Lamp (123) came on" },
				{ true, "both lights in the room are off after sunset" },
				{ false, "Ceiling (456) came on" },
				{ true, "both lights in the room are off after sunset" },
			}, r.changes)
		end)

		it("not when a light turns unknown during a pause (RE13)", function()
			local r = started()
			r.rd:light(123, "garbage")
			r.rd:light(456, nil)
			assert.is_true(r.rd:paused())
			assert.are.same({ 2, 0, 2 }, counts(r.rd))
			assert.are.equal(1, #r.changes)
		end)

		it("not when a scan finds a new light that has not reported, and its first report of off is no blip (RE13)",
			function()
				local r = started()
				r.room = { [123] = "Example Lamp", [456] = "Ceiling", [789] = "Desk" }
				r.rd:scan("6-hourly") -- Desk has no value: listened, no report from inside listen
				assert.are.equal(1, r.count("listen", 789))
				assert.are.same({ 3, 0, 1 }, counts(r.rd))
				assert.is_true(r.rd:paused())
				r.rd:light(789, "0")
				assert.is_true(r.rd:paused())
				assert.are.same({ 3, 0, 0 }, counts(r.rd))
				assert.are.equal(1, #r.changes)
				assert.are.equal(1, r.log.count("always"))
			end)

		it("when the property is set to Never while paused (RE14)", function()
			local r = started()
			r.rd:configure({ enabled = false })
			assert.is_false(r.rd:paused())
			assert.are.same({ false, "Pause LED Animations is Never" }, r.changes[2])
			assert.is_true(r.log.has("always", "LED animations resumed: Pause LED Animations is Never"))
			r.rd:configure({ enabled = false })
			assert.are.equal(2, #r.changes)
		end)

		it("ignores a configure without an enabled key, and anything but true disables", function()
			local r = started()
			r.rd:configure({})
			r.rd:configure(nil)
			assert.is_true(r.rd:paused())
			r.rd:configure({ enabled = "Room lights off after sunset" })
			assert.is_false(r.rd:paused())
		end)

		it("when a scan finds no light in the room (RE8)", function()
			local r = started()
			r.room = {}
			r.rd:scan("6-hourly")
			assert.is_false(r.rd:paused())
			assert.are.same({ false, "no light in the room" }, r.changes[2])
			assert.are.equal(1, r.count("unlisten", 123))
			assert.are.equal(1, r.count("unlisten", 456))
			assert.is_true(r.log.has("always", "LED animations resumed: no light in the room"))
		end)
	end)

	describe("the window closes (RD-D5, RD-D7, #240)", function()
		it("resumes at once with every light still off: 30 minutes after sunrise", function()
			local r = started()
			assert.is_true(r.rd:paused())
			r.rd:set_night(false)
			assert.is_false(r.rd:paused())
			assert.are.same({ 2, 0, 0 }, counts(r.rd))
			assert.are.same({
				{ true, "both lights in the room are off after sunset" },
				{ false, "30 minutes after sunrise" },
			}, r.changes)
			assert.is_true(r.log.has("always", "LED animations resumed: 30 minutes after sunrise"))
			assert.are.equal(1, r.log.count("always", "resumed"))
		end)

		it("once: later looks of the sun outside the window change nothing more", function()
			local r = started()
			r.rd:set_night(false)
			r.rd:set_night(false)
			r.rd:set_night(nil)
			assert.is_false(r.rd:paused())
			assert.are.equal(2, #r.changes)
			assert.are.equal(1, r.log.count("always", "resumed"))
		end)

		it("does nothing while not paused: no on_change, no log line", function()
			local lit = started({ values = { [123] = "1", [456] = "0" } })
			assert.is_false(lit.rd:paused())
			lit.log.clear()
			lit.rd:set_night(false)
			lit.rd:set_night(false)
			assert.are.same({}, lit.changes)
			assert.are.same({}, lit.log.lines)
			local day = started({ night = false })
			day.log.clear()
			day.rd:set_night(false)
			assert.are.same({}, day.changes)
			assert.are.same({}, day.log.lines)
			local never = started({ enabled = false })
			never.log.clear()
			never.rd:set_night(false)
			assert.are.same({}, never.changes)
			assert.are.same({}, never.log.lines)
		end)

		it("afterwards a light on and off does not pause (RE6), nor does a scan or the property set", function()
			local r = started()
			r.rd:set_night(false)
			r.rd:light(123, "1")
			assert.is_false(r.rd:paused())
			r.rd:light(123, "0")
			assert.is_false(r.rd:paused())
			r.rd:scan("sunrise")
			r.rd:configure({ enabled = true })
			assert.is_false(r.rd:paused())
			assert.are.same({ 2, 0, 0 }, counts(r.rd))
			assert.are.equal(2, #r.changes)
		end)

		it("the next set_night(true) with every light off pauses again (RE7)", function()
			local r = started()
			r.rd:set_night(false)
			r.rd:light(123, "1")
			r.rd:light(123, "0")
			r.rd:set_night(true)
			assert.is_true(r.rd:paused())
			assert.are.same({
				{ true, "both lights in the room are off after sunset" },
				{ false, "30 minutes after sunrise" },
				{ true, "both lights in the room are off after sunset" },
			}, r.changes)
		end)

		it("the next set_night(true) with a light on does not pause; that light off then does", function()
			local r = started()
			r.rd:set_night(false)
			r.rd:light(456, "1")
			r.rd:set_night(true)
			assert.is_false(r.rd:paused())
			r.rd:light(456, "0")
			assert.is_true(r.rd:paused())
			assert.are.equal(3, #r.changes)
		end)

		it("ends a pause at once when it closes inside a scan, and the scan's end does not pause again", function()
			local r = started()
			r.room = { [123] = "Example Lamp", [456] = "Ceiling", [789] = "Desk" }
			r.values[789] = "0"
			r.fail_listen = function(id)
				if id == 789 then
					r.rd:set_night(false)
				end
			end
			r.rd:scan("sunrise")
			assert.is_false(r.rd:paused())
			assert.are.same({ 3, 0, 0 }, counts(r.rd))
			assert.are.same({ false, "30 minutes after sunrise" }, r.changes[2])
			assert.are.equal(2, #r.changes)
		end)

		it("ends a pause the property's Never would have ended: Never afterwards changes nothing", function()
			local r = started()
			r.rd:set_night(false)
			r.rd:configure({ enabled = false })
			r.rd:configure({ enabled = true })
			assert.is_false(r.rd:paused())
			assert.are.equal(2, #r.changes)
			assert.are.equal(0, r.log.count("always", "Pause LED Animations is Never"))
		end)
	end)

	describe("nothing is saved (RD-D8, #240)", function()
		it("start() never calls a load or save passed in opts, and pauses as the scan decides", function()
			local r = rig()
			r.rd:set_night(true)
			r.rd:start()
			assert.is_true(r.rd:paused())
			assert.are.same({ { true, "both lights in the room are off after sunset" } }, r.changes)
			assert.are.same({ { "lights" }, { "listen", 123 }, { "listen", 456 } }, r.calls)
			untouched(r)
			no_restore_lines(r)
			-- nor does anything later
			r.rd:light(123, "1")
			r.rd:light(123, "0")
			r.rd:set_night(false)
			r.rd:configure({ enabled = false })
			r.rd:scan("6-hourly")
			r.rd:stop()
			untouched(r)
		end)

		it("restores nothing: a restart outside the window with every light off does not pause (RE11)", function()
			local r = rig() -- r.load would say a pause was saved
			r.rd:set_night(false)
			r.rd:start()
			assert.is_false(r.rd:paused())
			assert.are.same({}, r.changes)
			untouched(r)
			no_restore_lines(r)
			r.rd:set_night(true) -- sunset
			assert.is_true(r.rd:paused())
		end)

		it("a restart inside the window with a light on does not pause (RE10)", function()
			local r = rig()
			r.values = { [123] = "0", [456] = "1" }
			r.rd:set_night(true)
			r.rd:start()
			assert.is_false(r.rd:paused())
			assert.are.same({}, r.changes)
		end)

		it("a restart inside the window pauses once the last light that had not reported reports off (RE10)", function()
			local r = rig()
			r.values = {}
			r.rd:set_night(true)
			r.rd:start()
			assert.is_false(r.rd:paused())
			r.rd:light(123, "0")
			assert.is_false(r.rd:paused())
			r.rd:light(456, "0")
			assert.is_true(r.rd:paused())
			assert.are.same({ { true, "both lights in the room are off after sunset" } }, r.changes)
		end)

		it("a restart under Never: nothing, and no line about a saved pause", function()
			local r = rig()
			r.rd:configure({ enabled = false })
			r.rd:set_night(true)
			r.rd:start()
			assert.is_false(r.rd:paused())
			assert.are.same({}, r.changes)
			untouched(r)
			no_restore_lines(r)
		end)
	end)

	describe("scans (RD-D3, RD-D4)", function()
		it("listens to every light, ascending, marking it watched before listen reports", function()
			local r = started({ night = false })
			assert.are.same({ { "lights" }, { "listen", 123 }, { "listen", 456 } }, r.calls)
			assert.are.same({ 2, 0, 0 }, counts(r.rd))
		end)

		it("adds a light the room gained (RE1) and drops one it lost (RE2), unlistening it", function()
			local r = started({ night = false })
			r.room = { [123] = "Example Lamp", [789] = "Desk" }
			r.values[789] = "1"
			r.rd:scan("sunset")
			assert.are.equal(1, r.count("unlisten", 456))
			assert.are.equal(1, r.count("listen", 789))
			assert.are.equal(1, r.count("listen", 123)) -- a kept light is not listened again
			assert.is_nil(r.listening[456])
			assert.are.same({ 2, 1, 0 }, counts(r.rd))
			r.rd:light(456, "1") -- a late report from the dropped light is ignored
			assert.are.same({ 2, 1, 0 }, counts(r.rd))
		end)

		it("reads the new room when the fan moved (RE3)", function()
			local r = started()
			assert.is_true(r.rd:paused())
			r.room = { [901] = "Kitchen Pendant", [902] = "Kitchen Island" }
			r.values = { [901] = "0", [902] = "1" }
			r.rd:scan("property")
			assert.are.equal(1, r.count("unlisten", 123))
			assert.are.equal(1, r.count("unlisten", 456))
			assert.are.equal(1, r.count("listen", 901))
			assert.are.equal(1, r.count("listen", 902))
			assert.is_false(r.rd:paused())
			assert.are.same({ false, "Kitchen Island (902) came on" }, r.changes[2])
			r.rd:light(902, "0")
			assert.is_true(r.rd:paused())
			assert.are.same({ true, "both lights in the room are off after sunset" }, r.changes[3])
		end)

		it("keeps a moved-out light's last state until the scan, unknown lights included (RE2, RE4)", function()
			local r = started({ values = { [123] = "0", [456] = "1" } })
			r.room = { [123] = "Example Lamp" } -- moved, but no scan yet
			r.rd:light(123, "0")
			assert.is_false(r.rd:paused())
		end)

		it("takes a rename at the next scan and names it in the why", function()
			local r = started()
			r.room = { [123] = "Reading Lamp", [456] = "Ceiling" }
			r.rd:scan("6-hourly")
			r.rd:light(123, "1")
			assert.are.same({ false, "Reading Lamp (123) came on" }, r.changes[2])
			assert.are.equal(1, r.count("listen", 123))
		end)

		it("takes ids given as numeric strings, skips keys that are not ids, and names a nameless light Light", function()
			local r = started({ night = false, room = { ["123"] = "Lamp", [456] = 7, nope = "X", [-3] = "Y", [1.5] = "Z" } })
			local list = r.rd:debug().list
			assert.are.same({ { id = 123, name = "Lamp", state = "off" }, { id = 456, name = "Light", state = "off" } },
				list)
		end)

		it("does nothing before start, and ignores a scan started inside a scan", function()
			local r = rig()
			r.rd:scan("early")
			assert.are.equal(0, r.count("lights"))
			r.fail_listen = function(id)
				if id == 123 then
					r.rd:scan("nested")
				end
			end
			r.rd:set_night(true)
			r.rd:start()
			assert.are.equal(1, r.count("lights"))
			assert.is_true(r.log.has("debug", "a scan (nested) during a scan; ignored"))
			assert.is_true(r.rd:paused())
			assert.are.equal(1, #r.changes)
		end)

		it("a scan that changes nothing keeps the pause and calls nothing", function()
			local r = started()
			r.rd:scan("6-hourly")
			r.rd:scan("sunrise")
			assert.are.equal(3, r.count("lights"))
			assert.are.equal(2, r.count("listen"))
			assert.are.equal(0, r.count("unlisten"))
			assert.are.equal(1, #r.changes)
		end)

		it("works without unlisten, load, save or on_change given", function()
			local r = rig({ without = { "unlisten", "load", "save", "on_change" } })
			r.rd:set_night(true)
			r.rd:start()
			assert.is_true(r.rd:paused())
			r.room = {}
			r.rd:scan("6-hourly")
			assert.is_false(r.rd:paused())
			assert.are.equal(0, r.log.count("warn"))
		end)
	end)

	describe("listen failing (RD-D4, RE13)", function()
		it("leaves the light out with one warning and tries again at the next scan", function()
			local r = rig()
			r.fail_listen = function(id)
				return id == 456 and "false" or nil
			end
			r.rd:set_night(false)
			r.rd:start()
			assert.are.same({ 1, 0, 0 }, counts(r.rd))
			assert.are.equal(1, r.log.count("warn", "could not watch Ceiling (456): no such device"))
			r.rd:scan("6-hourly")
			assert.are.equal(2, r.count("listen", 456))
			assert.are.equal(1, r.log.count("warn", "could not watch")) -- a retry that fails again logs at debug
			assert.is_true(r.log.has("debug", "could not watch Ceiling (456)"))
			r.fail_listen = nil
			r.rd:scan("sunset")
			assert.are.equal(3, r.count("listen", 456))
			assert.are.same({ 2, 0, 0 }, counts(r.rd))
		end)

		it("discards a report made inside a listen that then fails", function()
			local r = rig()
			r.values = { [123] = "0", [456] = "1" }
			r.fail_listen = function(id)
				return id == 456 and "raise" or nil
			end
			r.rd:set_night(true)
			r.rd:start()
			-- the only light watched is off: it pauses; the failed one does not count
			assert.is_true(r.rd:paused())
			assert.are.same({ { true, "the only light in the room is off after sunset" } }, r.changes)
			assert.is_true(r.log.has("warn", "could not watch Ceiling (456)"))
			assert.is_true(r.log.has("warn", "register refused"))
		end)

		it("does not let a failed listen's report of on end a pause", function()
			local r = started()
			r.room = { [123] = "Example Lamp", [456] = "Ceiling", [789] = "Desk" }
			r.values[789] = "1"
			r.fail_listen = function(id)
				return id == 789 and "false" or nil
			end
			r.rd:scan("6-hourly")
			assert.is_true(r.rd:paused())
			assert.are.equal(1, #r.changes)
			assert.are.same({ 2, 0, 0 }, counts(r.rd))
		end)

		it("keeps the pause and starts none when every listen fails", function()
			local r = started()
			r.room = { [901] = "Example Sconce", [902] = "Desk" }
			r.fail_listen = function()
				return "false"
			end
			r.rd:scan("property")
			assert.is_true(r.rd:paused())
			assert.are.same({ 0, 0, 0 }, counts(r.rd))
			assert.are.equal(1, #r.changes)
			assert.is_true(r.log.has("info", "Room lights: none of the 2 in this room could be watched"))
			local fresh = rig()
			fresh.fail_listen = function()
				return "false"
			end
			fresh.rd:set_night(true)
			fresh.rd:start()
			assert.is_false(fresh.rd:paused())
			assert.are.same({}, fresh.changes)
		end)

		it("counts a listen that returns nothing as success", function()
			local r = rig({ listen_returns_nothing = true })
			r.rd:set_night(true)
			r.rd:start()
			assert.are.same({ 2, 0, 0 }, counts(r.rd))
			assert.is_true(r.rd:paused())
		end)
	end)

	describe("lights() failing", function()
		it("keeps the list and the pause when it returns nil and an error", function()
			local r = started()
			r.fail_lights = function()
				return nil, "no room"
			end
			r.rd:scan("6-hourly")
			assert.is_true(r.rd:paused())
			assert.are.same({ 2, 0, 0 }, counts(r.rd))
			assert.are.equal(0, r.count("unlisten"))
			assert.is_true(r.log.has("warn",
				"Room lights: could not read the room's lights (6-hourly): no room; the last list of 2 is kept"))
			r.rd:light(123, "1")
			assert.is_false(r.rd:paused())
		end)

		it("keeps the list and the pause when it raises or returns no table", function()
			local r = started()
			r.fail_lights = function()
				error("director busy")
			end
			r.rd:scan("sunset")
			assert.is_true(r.rd:paused())
			assert.is_true(r.log.has("warn", "director busy"))
			r.fail_lights = function()
				return "nonsense"
			end
			r.rd:scan("sunrise")
			assert.is_true(r.rd:paused())
			assert.are.same({ 2, 0, 0 }, counts(r.rd))
			assert.are.equal(1, #r.changes)
		end)

		it("keeps the pause through a failed read, and the window closing still ends it", function()
			local r = started()
			r.fail_lights = function()
				return nil, "no room"
			end
			r.rd:scan("sunrise")
			assert.is_true(r.rd:paused())
			r.rd:set_night(false)
			assert.is_false(r.rd:paused())
			assert.are.same({ false, "30 minutes after sunrise" }, r.changes[2])
		end)

		it("decides nothing when the start's read fails; the next scan decides", function()
			local r = rig()
			r.fail_lights = function()
				return nil, "too early"
			end
			r.rd:set_night(true)
			r.rd:start()
			assert.is_false(r.rd:paused())
			assert.are.same({}, r.changes)
			assert.is_false(r.rd:debug().read)
			r.fail_lights = nil
			r.rd:scan("6-hourly")
			assert.is_true(r.rd:paused()) -- every light off inside the window
			assert.are.same({ { true, "both lights in the room are off after sunset" } }, r.changes)
			assert.is_true(r.rd:debug().read)
		end)
	end)

	describe("an empty room (RE8)", function()
		it("logs it at the scan and never pauses", function()
			local r = started({ room = {} })
			assert.is_false(r.rd:paused())
			assert.are.same({}, r.changes)
			assert.is_true(r.log.has("info", "Room lights: none in this room; the LED animations never pause"))
			r.rd:set_night(true)
			r.rd:configure({ enabled = true })
			assert.is_false(r.rd:paused())
			assert.are.same({ 0, 0, 0 }, counts(r.rd))
		end)

		it("logs the empty room once, not at every scan", function()
			local r = started({ room = {} })
			r.rd:scan("6-hourly")
			r.rd:scan("sunrise")
			assert.are.equal(1, r.log.count("info", "none in this room"))
		end)
	end)

	describe("stop()", function()
		it("unlistens every light, and afterwards nothing is called", function()
			local r = started({ night = false })
			r.rd:stop()
			assert.are.equal(1, r.count("unlisten", 123))
			assert.are.equal(1, r.count("unlisten", 456))
			local before = #r.calls
			r.rd:set_night(true)
			r.rd:light(123, "0")
			r.rd:scan("sunset")
			r.rd:configure({ enabled = true })
			r.rd:set_night(false)
			r.rd:start()
			r.rd:stop()
			assert.are.equal(before, #r.calls)
			assert.are.same({}, r.changes)
			untouched(r)
			assert.is_false(r.rd:paused())
			assert.are.same({ 0, 0, 0 }, counts(r.rd))
			assert.is_true(r.rd:debug().stopped)
		end)

		it("keeps paused() as it was and calls no callback when a paused module stops", function()
			local r = started()
			r.rd:stop()
			r.rd:light(123, "1")
			r.rd:set_night(false)
			r.rd:configure({ enabled = false })
			assert.is_true(r.rd:paused())
			assert.are.equal(1, #r.changes)
		end)

		it("goes on when unlisten raises", function()
			local r = started({ night = false })
			r.fail_unlisten = true
			r.rd:stop()
			assert.are.equal(2, r.count("unlisten"))
			assert.are.equal(2, r.log.count("warn", "could not stop watching"))
		end)

		it("before start: nothing to unlisten, and start does nothing after it", function()
			local r = rig()
			r.rd:stop()
			r.rd:start()
			assert.are.same({}, r.calls)
		end)

		it("inside on_change: a change still waiting and every later callback are dropped", function()
			local r = rig()
			r.on_change_hook = function(paused)
				if paused then
					r.rd:set_night(false) -- waits for this on_change to return
					r.rd:stop()
				end
			end
			r.rd:set_night(true)
			r.rd:start()
			assert.are.same({ { true, "both lights in the room are off after sunset" } }, r.changes)
			assert.are.equal(2, r.count("unlisten"))
			untouched(r)
		end)
	end)

	describe("callbacks", function()
		it("contains an error in on_change: logged at warn, the state right", function()
			local r = rig()
			r.fail_change = true
			r.rd:set_night(true)
			r.rd:start()
			assert.is_true(r.rd:paused())
			assert.is_true(r.log.has("warn", "Room lights: passing on the pause failed"))
			assert.is_true(r.log.has("warn", "driver broke"))
			r.rd:light(123, "1")
			assert.is_false(r.rd:paused())
			assert.are.equal(2, #r.changes)
			assert.is_true(r.log.has("warn", "Room lights: passing on the resume failed"))
		end)

		it("passes on a change made inside on_change after it returns, in order", function()
			local r = rig()
			local inside = {}
			r.on_change_hook = function(paused)
				if paused then
					r.rd:configure({ enabled = false })
					inside[#inside + 1] = #r.changes -- the nested change has not been passed on yet
				end
			end
			r.rd:set_night(true)
			r.rd:start()
			assert.are.same({ 1 }, inside)
			assert.are.same({
				{ true, "both lights in the room are off after sunset" },
				{ false, "Pause LED Animations is Never" },
			}, r.changes)
			assert.is_false(r.rd:paused())
		end)

		it("passes on the window closing inside on_change after it returns, in order", function()
			local r = rig()
			local inside = {}
			r.on_change_hook = function(paused)
				if paused then
					r.rd:set_night(false)
					inside[#inside + 1] = #r.changes
				end
			end
			r.rd:set_night(true)
			r.rd:start()
			assert.are.same({ 1 }, inside)
			assert.are.same({
				{ true, "both lights in the room are off after sunset" },
				{ false, "30 minutes after sunrise" },
			}, r.changes)
			assert.is_false(r.rd:paused())
		end)

		it("survives a log table that raises or is missing", function()
			local raising = {}
			for _, level in ipairs({ "always", "warn", "info", "debug" }) do
				raising[level] = function()
					error("log broke")
				end
			end
			local function listen()
				return true
			end
			local r = roomdark.new({
				lights = function()
					return { [1] = "A" }
				end,
				listen = listen,
				log = raising,
			})
			r:set_night(true)
			r:start()
			r:light(1, "0")
			assert.is_true(r:paused())
			local quiet = roomdark.new({
				lights = function()
					return { [1] = "A" }
				end,
				listen = listen,
			})
			quiet:set_night(true)
			quiet:start()
			quiet:light(1, "0")
			assert.is_true(quiet:paused())
			assert.is_true(roomdark.new():debug().enabled) -- no options at all
		end)
	end)

	describe("the log (RD-D11)", function()
		it("writes the pause and its end at always, whatever else is logged", function()
			local r = started()
			r.rd:light(123, "1")
			r.rd:light(123, "0")
			r.rd:set_night(false)
			r.rd:configure({ enabled = false })
			r.rd:configure({ enabled = true })
			r.rd:set_night(true)
			r.rd:configure({ enabled = false })
			r.rd:configure({ enabled = true })
			r.room = {}
			r.rd:scan("6-hourly")
			assert.are.same({
				"LED animations paused: both lights in the room are off after sunset",
				"LED animations resumed: Example Lamp (123) came on",
				"LED animations paused: both lights in the room are off after sunset",
				"LED animations resumed: 30 minutes after sunrise",
				"LED animations paused: both lights in the room are off after sunset",
				"LED animations resumed: Pause LED Animations is Never",
				"LED animations paused: both lights in the room are off after sunset",
				"LED animations resumed: no light in the room",
			}, r.log.texts("always"))
		end)

		it("writes the list at info, sorted by id, when it changes; nothing when it does not", function()
			local r = started({ night = false, room = { [456] = "Ceiling", [123] = "Example Lamp" } })
			assert.are.same({ "Room lights: 2 in this room (Example Lamp 123, Ceiling 456)" }, r.log.texts("info"))
			r.log.clear()
			r.rd:scan("6-hourly")
			assert.are.same({}, r.log.texts("info"))
			r.room = { [123] = "Example Lamp", [456] = "Ceiling Fan Light" }
			r.rd:scan("sunset")
			assert.are.same({ "Room lights: 2 in this room (Example Lamp 123, Ceiling Fan Light 456)" },
				r.log.texts("info"))
		end)

		it("caps the list at 8 names and shortens long names", function()
			local room, values = {}, {}
			for i = 1, 10 do
				room[i] = "Light number " .. i
				values[i] = "0"
			end
			room[1] = string.rep("x", 60)
			local r = started({ night = false, room = room, values = values })
			local line = r.log.texts("info")[1]
			assert.are.equal("Room lights: 10 in this room (" .. string.rep("x", 37) .. "... 1, Light number 2 2, "
				.. "Light number 3 3, Light number 4 4, Light number 5 5, Light number 6 6, Light number 7 7, "
				.. "Light number 8 8 and 2 more)", line)
			assert.is_true(#line < 300)
			-- the why phrase keeps the full name
			r.rd:set_night(true)
			r.rd:light(1, "1")
			r.rd:light(1, "0")
			assert.is_true(r.rd:paused())
		end)

		it("says which lights are watched when a listen failed", function()
			local r = rig()
			r.fail_listen = function(id)
				return id == 456 and "false" or nil
			end
			r.rd:start()
			assert.is_true(r.log.has("info",
				"Room lights: 1 of 2 in this room watched (Example Lamp 123); the rest are tried again at the next scan"))
		end)

		it("writes each light's report at debug", function()
			local r = started({ night = false })
			assert.is_true(r.log.has("debug", 'Room light Example Lamp (123) reports "0": off'))
			r.rd:light(456, 1)
			assert.is_true(r.log.has("debug", "Room light Ceiling (456) reports 1: on"))
			r.rd:light(456, "dim")
			assert.is_true(r.log.has("debug", 'Room light Ceiling (456) reports "dim": unknown'))
		end)

		it("writes no info or always line while nothing changes", function()
			local r = started()
			r.log.clear()
			r.rd:scan("6-hourly")
			r.rd:set_night(true)
			r.rd:light(123, "0")
			assert.are.equal(0, r.log.count("info"))
			assert.are.equal(0, r.log.count("always"))
			assert.are.equal(0, r.log.count("warn"))
		end)
	end)

	describe("counts() and debug()", function()
		it("counts lights, on and unknown as three numbers", function()
			local r = started({ night = false, room = { [1] = "A", [2] = "B", [3] = "C" }, values = { [1] = "1" } })
			local lights, on, unknown = r.rd:counts()
			assert.are.equal(3, lights)
			assert.are.equal(1, on)
			assert.are.equal(2, unknown)
		end)

		it("shows the state as a plain table", function()
			local r = started({ values = { [123] = "0", [456] = "1" } })
			assert.are.same({
				enabled = true, night = true, started = true, paused = false, stopped = false, read = true,
				lights = 2, on = 1, unknown = 0,
				list = {
					{ id = 123, name = "Example Lamp", state = "off" },
					{ id = 456, name = "Ceiling", state = "on" },
				},
			}, r.rd:debug())
		end)
	end)
end)
