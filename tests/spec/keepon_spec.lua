-- fan.keepon: is a room light kept on by Control4 programming? (#247, docs/ignored-lights-design.md: section 2's
-- interface, IL-D1 to IL-D3). The module is pure, so plain tables are the whole rig.
--
-- measured() rebuilds what C4:GetCodeItems(proxy, 5101) returned for a relay on the house (OS 3.4.3, 2026-11-15;
-- docs/keep-on-design.md section 3), with placeholders: the relay is proxy 123 and the notification's text is
-- made up. The variable ids (1206 Relay Maintenance, 1207 the re-on count), the variables agent (100001), the Else
-- pseudo-device (100000) and the notification agent (6, its template 4) are as measured. The dump cut each line at
-- 160 characters, so the notification's XML is completed by hand after "<static>4</s"; and it cannot show an empty
-- table, so the leaves carry subitems = {} as the SDK's example does (API 9_helper/_5.9-GETCODEITEMS.md).
--
--   container (type 1, device 0)
--     If Relay Maintenance is False (type 2)
--       Relay Maintenance count + 1 (type 1)
--       If count >= 3 (type 2): set Relay Maintenance True; send a push notification
--       Else (type 4, device 100000): ON to the relay itself (type 1, device 123)

local keepon = require("fan.keepon")

local PROXY = 123
local OTHER = 456
local ON_XML = '<devicecommand owneridtype="" owneriditem="-1"><command>ON</command><params/></devicecommand>'

local function item(id, typ, device, xml, display, subitems)
	return {
		cmdcond = { xml = xml }, creator = 0, creatorstate = "", device = device, display = display,
		enabled = true, id = id, type = typ, subitems = subitems or {},
	}
end

local function measured(proxy)
	local on = item(6, 1, proxy or PROXY, ON_XML, "Turn on the NAME")
	local notify = item(7, 1, 6, '<devicecommand owneridtype="agent" owneriditem="4"><command>SEND_NOTIFICATION'
		.. '</command><params><param><name>TEMPLATE_ID</name><value type="INTEGER"><static>4</static></value>'
		.. '</param></params></devicecommand>', 'Send Push Notification "Example notification"')
	local set_true = item(4, 1, 100001, '<devicecommand owneridtype="variable" owneriditem="1206" name="=">'
		.. '<param name="value" type="int">1</param></devicecommand>', '#!"{VNAME} = True";VNAME="VNAME:100001,1206"')
	local cap = item(3, 2, 100001, '<deviceconditional owneridtype="variable" owneriditem="1207" name="&gt;=">'
		.. '<param name="value" type="int">3</param></deviceconditional>',
		'#!"If {VNAME} GREATER THAN OR EQUAL TO 3";VNAME="VNAME:100001,1207"', { set_true, notify })
	local count = item(2, 1, 100001, '<devicecommand owneridtype="variable" owneriditem="1207" name="+">'
		.. '<param name="value" type="int">1</param></devicecommand>', '#!"{VNAME} = {VNAME} + 1";VNAME="VNAME:100001,1207"')
	local otherwise = item(5, 4, 100000, "", "Else", { on })
	local maintenance = item(1, 2, 100001, '<deviceconditional owneridtype="variable" owneriditem="1206" name="==">'
		.. '<param name="value" type="int">0</param></deviceconditional>',
		'#!"If {VNAME} is False";VNAME="VNAME:100001,1206"', { count, cap, otherwise })
	local root = item(0, 1, 0, "", "", { maintenance })
	return { codeitems = { root } }
end

-- The items of measured() by name.
local function parts(t)
	local root = t.codeitems[1]
	local maintenance = root.subitems[1]
	local otherwise = maintenance.subitems[3]
	return {
		root = root, maintenance = maintenance, count = maintenance.subitems[1], cap = maintenance.subitems[2],
		set_true = maintenance.subitems[2].subitems[1], notify = maintenance.subitems[2].subitems[2],
		otherwise = otherwise, on = otherwise.subitems[1],
	}
end

-- measured() with the On item's XML (or one of its fields) changed.
local function with_on(change)
	local t = measured()
	change(parts(t).on)
	return t
end

-- A chain of enabled containers, the On item at depth (the items of codeitems are depth 1).
local function chain(depth)
	local node = item(depth, 1, PROXY, ON_XML, "Turn on the NAME")
	for d = depth - 1, 1, -1 do
		node = item(d, 1, 0, "", "", { node })
	end
	return { codeitems = { node } }
end

-- n items in all: a container holding n - 2 other commands and the On item.
local function sized(n)
	local children = {}
	for i = 1, n - 2 do
		children[i] = item(i, 1, OTHER, '<devicecommand><command>OFF</command></devicecommand>', "Turn off")
	end
	children[#children + 1] = item(n, 1, PROXY, ON_XML, "Turn on the NAME")
	return { codeitems = { item(0, 1, 0, "", "", children) } }
end

describe("fan.keepon", function()
	it("names the light_v2 Turned Off event", function()
		assert.are.equal(5101, keepon.EVENT_TURNED_OFF)
	end)

	describe("kept_on", function()
		it("is true for the measured keep-on programming", function()
			assert.is_true(keepon.kept_on(measured(), PROXY))
		end)

		it("is false with the On item disabled", function()
			assert.is_false(keepon.kept_on(with_on(function(on) on.enabled = false end), PROXY))
		end)

		for _, name in ipairs({ "root", "maintenance", "otherwise" }) do
			it("is false with the enclosing item " .. name .. " disabled", function()
				local t = measured()
				parts(t)[name].enabled = false
				assert.is_false(keepon.kept_on(t, PROXY))
			end)
		end

		for _, name in ipairs({ "count", "cap", "set_true", "notify" }) do
			it("is still true with " .. name .. ", which does not enclose the On, disabled", function()
				local t = measured()
				parts(t)[name].enabled = false
				assert.is_true(keepon.kept_on(t, PROXY))
			end)
		end

		it("is false when an enclosing item has no enabled flag, or one that is not true", function()
			for _, value in ipairs({ "false", 1, 0, "yes", "" }) do
				local t = measured()
				parts(t).otherwise.enabled = value
				assert.is_false(keepon.kept_on(t, PROXY), tostring(value))
			end
			local t = measured()
			parts(t).maintenance.enabled = nil
			assert.is_false(keepon.kept_on(t, PROXY))
		end)

		it("takes enabled as the string true, in any case", function()
			local t = measured()
			local p = parts(t)
			p.root.enabled, p.maintenance.enabled, p.otherwise.enabled, p.on.enabled = "true", "TRUE", "True", "true"
			assert.is_true(keepon.kept_on(t, PROXY))
		end)

		it("is false for another light: the On aimed at another device, or asked about another proxy", function()
			assert.is_false(keepon.kept_on(with_on(function(on) on.device = OTHER end), PROXY))
			assert.is_false(keepon.kept_on(measured(), OTHER))
			assert.is_false(keepon.kept_on(with_on(function(on) on.device = 0 end), PROXY))
			assert.is_false(keepon.kept_on(with_on(function(on) on.device = nil end), PROXY))
		end)

		it("is false for OFF, TOGGLE and other commands on the light", function()
			for _, command in ipairs({ "OFF", "TOGGLE", "ONE", "ON_OFF", "RAMP_TO_LEVEL", "SET_LEVEL", "" }) do
				local t = with_on(function(on)
					on.cmdcond.xml = '<devicecommand owneridtype="" owneriditem="-1"><command>' .. command
						.. '</command><params/></devicecommand>'
				end)
				assert.is_false(keepon.kept_on(t, PROXY), command)
			end
		end)

		it("matches ON in any case and with white space inside the tags", function()
			for _, xml in ipairs({
				"<devicecommand><command>on</command></devicecommand>",
				"<devicecommand><COMMAND>On</COMMAND></devicecommand>",
				"<devicecommand>< command > ON\n</ command ></devicecommand>",
				"<devicecommand><command>\tON </command><params/></devicecommand>",
			}) do
				assert.is_true(keepon.kept_on(with_on(function(on) on.cmdcond.xml = xml end), PROXY), xml)
			end
		end)

		it("is false when the On item has no XML", function()
			assert.is_false(keepon.kept_on(with_on(function(on) on.cmdcond = nil end), PROXY))
			assert.is_false(keepon.kept_on(with_on(function(on) on.cmdcond = { xml = 5 } end), PROXY))
			assert.is_false(keepon.kept_on(with_on(function(on) on.cmdcond = ON_XML end), PROXY))
		end)

		it("reads the XML under the flat key cmdcond.xml too", function()
			local t = with_on(function(on)
				on.cmdcond = nil
				on["cmdcond.xml"] = ON_XML
			end)
			assert.is_true(keepon.kept_on(t, PROXY))
		end)

		it("is false when the On item is not a command", function()
			for _, typ in ipairs({ 0, 2, 3, 4, 5, 6, "2", "command", 1.5 }) do
				assert.is_false(keepon.kept_on(with_on(function(on) on.type = typ end), PROXY), tostring(typ))
			end
			assert.is_false(keepon.kept_on(with_on(function(on) on.type = nil end), PROXY))
		end)

		it("takes the device, the type and the proxy as numeric strings", function()
			assert.is_true(keepon.kept_on(with_on(function(on) on.device = "123" end), PROXY))
			assert.is_true(keepon.kept_on(with_on(function(on) on.type = "1" end), PROXY))
			assert.is_true(keepon.kept_on(measured(), "123"))
			assert.is_false(keepon.kept_on(with_on(function(on) on.device = "123abc" end), PROXY))
			assert.is_false(keepon.kept_on(with_on(function(on) on.device = " 123" end), PROXY))
			assert.is_false(keepon.kept_on(with_on(function(on) on.device = 123.5 end), 123.5))
		end)

		it("is false for a proxy that is not an id", function()
			for _, proxy in ipairs({ 0, -123, 1.5, "abc", "", true, {}, 1 / 0, -(1 / 0) }) do
				assert.is_false(keepon.kept_on(measured(), proxy), tostring(proxy))
			end
			assert.is_false(keepon.kept_on(measured(), nil))
			assert.is_false(keepon.kept_on(measured(), 0 / 0))
		end)

		it("finds an enabled On beside a disabled one, and one deeper in another branch", function()
			local t = measured()
			local p = parts(t)
			p.on.enabled = false
			p.otherwise.subitems[2] = item(8, 1, PROXY, ON_XML, "Turn on the NAME")
			assert.is_true(keepon.kept_on(t, PROXY))
			t = measured()
			parts(t).on.enabled = false
			t.codeitems[2] = item(9, 1, 0, "", "", { item(10, 2, 100001, "", "If", { item(11, 1, PROXY, ON_XML, "On") }) })
			assert.is_true(keepon.kept_on(t, PROXY))
		end)

		it("takes leaves with no subitems at all", function()
			local t = measured()
			local p = parts(t)
			p.on.subitems, p.count.subitems, p.notify.subitems = nil, nil, nil
			assert.is_true(keepon.kept_on(t, PROXY))
		end)

		it("is false without error for answers of the wrong shape", function()
			assert.is_false(keepon.kept_on({ codeitems = {} }, PROXY))
			assert.is_false(keepon.kept_on(nil, PROXY))
			assert.is_false(keepon.kept_on("codeitems", PROXY))
			assert.is_false(keepon.kept_on(42, PROXY))
			assert.is_false(keepon.kept_on({}, PROXY))
			assert.is_false(keepon.kept_on({ items = measured().codeitems }, PROXY))
			assert.is_false(keepon.kept_on({ codeitems = "items" }, PROXY))
			assert.is_false(keepon.kept_on(measured().codeitems, PROXY)) -- the list without its wrapper
			assert.is_false(keepon.kept_on(parts(measured()).on, PROXY)) -- one item without its wrapper
		end)

		it("is false when anything in the answer is malformed, even beside a good On", function()
			local t = measured()
			parts(t).maintenance.subitems[4] = "stray"
			assert.is_false(keepon.kept_on(t, PROXY))
			t = measured()
			t.codeitems[2] = 7
			assert.is_false(keepon.kept_on(t, PROXY))
			t = measured()
			parts(t).notify.subitems = ""
			assert.is_false(keepon.kept_on(t, PROXY))
			t = measured()
			parts(t).count.subitems = false
			assert.is_false(keepon.kept_on(t, PROXY))
		end)

		it("is false without error for cycles and shared items", function()
			local t = measured()
			local p = parts(t)
			p.on.subitems = { p.root } -- a cycle below the On, which was found first
			assert.is_false(keepon.kept_on(t, PROXY))
			t = measured()
			p = parts(t)
			p.cap.subitems[3] = p.maintenance -- a cycle above the On
			assert.is_false(keepon.kept_on(t, PROXY))
			t = measured()
			p = parts(t)
			p.count.subitems = p.maintenance.subitems -- a list that holds itself
			assert.is_false(keepon.kept_on(t, PROXY))
			t = measured()
			p = parts(t)
			p.cap.subitems[3] = p.on -- the On in two places, no cycle
			assert.is_false(keepon.kept_on(t, PROXY))
			t = measured()
			p = parts(t)
			p.on.subitems = nil
			p.cap.subitems[3] = p.on -- the same, with no subitems list to meet twice
			assert.is_false(keepon.kept_on(t, PROXY))
			t = { codeitems = {} }
			t.codeitems[1] = { enabled = true, type = 1, device = 0, subitems = t.codeitems }
			assert.is_false(keepon.kept_on(t, PROXY))
		end)

		it("walks 32 levels and is false without error beyond them", function()
			assert.is_true(keepon.kept_on(chain(4), PROXY))
			assert.is_true(keepon.kept_on(chain(32), PROXY))
			assert.is_false(keepon.kept_on(chain(33), PROXY))
			assert.is_false(keepon.kept_on(chain(5000), PROXY))
		end)

		it("walks 2000 items and is false without error beyond them", function()
			assert.is_true(keepon.kept_on(sized(2000), PROXY))
			assert.is_false(keepon.kept_on(sized(2001), PROXY))
			assert.is_false(keepon.kept_on(sized(20000), PROXY))
		end)

		it("is false without error when a table raises on reading", function()
			local hostile = setmetatable({}, { __index = function() error("no such field") end })
			assert.is_false(keepon.kept_on(hostile, PROXY))
			local t = measured()
			setmetatable(parts(t).on, { __index = function() error("no such field") end })
			parts(t).on.cmdcond = nil -- read through __index, which raises
			assert.is_false(keepon.kept_on(t, PROXY))
		end)

		it("does not change the answer it reads", function()
			local t = measured()
			keepon.kept_on(t, PROXY)
			assert.are.same(measured(), t)
		end)
	end)

	describe("check", function()
		it("calls get once with the proxy and the Turned Off event", function()
			local get = spy.new(function()
				return measured()
			end)
			keepon.check(PROXY, get)
			assert.spy(get).was.called(1)
			assert.spy(get).was.called_with(PROXY, 5101)
		end)

		it("says kept for the measured programming", function()
			local kept, why = keepon.check(PROXY, function()
				return measured()
			end)
			assert.are.same({ true, "kept on by Control4 programming" }, { kept, why })
		end)

		it("says no keep-on programming for a script without one, or of the wrong shape", function()
			for _, answer in ipairs({ { codeitems = {} }, {}, with_on(function(on) on.enabled = false end) }) do
				local kept, why = keepon.check(PROXY, function()
					return answer
				end)
				assert.are.same({ false, "no keep-on programming" }, { kept, why })
			end
			local kept, why = keepon.check(OTHER, function()
				return measured()
			end)
			assert.are.same({ false, "no keep-on programming" }, { kept, why })
		end)

		it("says unreadable with the error, cut to 80 characters, when get raises", function()
			local long = string.rep("x", 200)
			local kept, why = keepon.check(PROXY, function()
				error(long, 0)
			end)
			assert.are.same({ false, "programming unreadable: " .. string.rep("x", 80) }, { kept, why })
			kept, why = keepon.check(PROXY, function()
				error("Director refused", 0)
			end)
			assert.are.same({ false, "programming unreadable: Director refused" }, { kept, why })
		end)

		it("says unreadable for an error that is not a string, and for a get that is not a function", function()
			local kept, why = keepon.check(PROXY, function()
				error(42, 0)
			end)
			assert.are.same({ false, "programming unreadable: 42" }, { kept, why })
			kept, why = keepon.check(PROXY, function()
				error(setmetatable({}, { __tostring = function() error("worse") end }))
			end)
			assert.are.same({ false, "programming unreadable: (no message)" }, { kept, why })
			kept, why = keepon.check(PROXY, nil)
			assert.is_false(kept)
			assert.truthy(why:find("^programming unreadable: "))
			assert.is_true(#why <= #"programming unreadable: " + 80)
		end)

		it("says not a table when get returns nil, nothing or a value that is not a table", function()
			for _, get in ipairs({
				function() return nil end,
				function() end,
				function() return "codeitems" end,
				function() return 5101 end,
				function() return true end,
				function() return nil, measured() end,
			}) do
				local kept, why = keepon.check(PROXY, get)
				assert.are.same({ false, "programming unreadable: not a table" }, { kept, why })
			end
		end)
	end)
end)
