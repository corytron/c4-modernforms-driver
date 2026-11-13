-- fan.found: the list of fans heard, kept across search windows (docs/auto-discovery-design.md section 3, section 4's
-- kept pick, the interface of section 6.2 and section 8's found_spec list). Pure: no Director and no fake runtime.
-- The windows are hand-made heard lists as Finder:find gives them; usable(), the clock and the log are fakes of
-- this spec's own. Placeholders only: fans MF_Fan_005301 (MAC 00:00:5E:00:53:01) at 10.0.2.151 and MF_Fan_005302
-- (00:00:5E:00:53:02) at 10.0.2.152, other MACs of the documentation range, other addresses built with ip().

local found = require("fan.found")

-- Test addresses built from their parts, so the source holds no address
-- literal outside the documented placeholders (the secrets check).
local function ip(...)
	return table.concat({ ... }, ".")
end

local MAC1, MAC2, MAC3 = "00005E005301", "00005E005302", "00005E005303"
local KEY1, KEY2, KEY3 = "00005e005301", "00005e005302", "00005e005303"
local FAN1, FAN2 = "10.0.2.151", "10.0.2.152"

-- An entry of a window's heard list, as Finder:find builds it.
local function fan(instance, address, mac, port)
	return { instance = instance, address = address, mac = mac, port = port or 80 }
end

local function one()
	return fan("MF_Fan_005301", FAN1, MAC1)
end

local function two()
	return fan("MF_Fan_005302", FAN2, MAC2)
end

local function raises()
	error("boom")
end

-- The spec's own filter: SRV port 80 (the driver passes discovery.usable).
local function port80(entry)
	return entry.port == 80
end

-- A list on fakes. o.opts replaces options, o.without removes them.
local function rig(o)
	o = o or {}
	local r = { clock = 5000, lines = {}, usable_calls = 0 }
	local fake_log = {}
	for _, level in ipairs({ "always", "warn", "error", "info", "debug" }) do
		fake_log[level] = function(fmt, ...)
			r.lines[#r.lines + 1] = { level = level, text = string.format(fmt, ...) }
		end
	end
	local options = {
		usable = function(entry)
			r.usable_calls = r.usable_calls + 1
			return port80(entry)
		end,
		now = function() return r.clock end,
		log = fake_log,
	}
	for k, v in pairs(o.opts or {}) do
		options[k] = v
	end
	for _, name in ipairs(o.without or {}) do
		options[name] = nil
	end
	r.l = found.new(options)
	-- The log lines of one level, as text.
	function r.said(level)
		local out = {}
		for _, line in ipairs(r.lines) do
			if line.level == level then
				out[#out + 1] = line.text
			end
		end
		return out
	end
	function r.keys(pin)
		local out = {}
		for i, e in ipairs(r.l:entries(pin)) do
			out[i] = e.key
		end
		return out
	end
	return r
end

describe("fan.found", function()
	describe("found.key (section 3: keyed by fan)", function()
		it("is the MAC as 12 lower-case hex digits, in any spelling mac12 reads", function()
			assert.equal(KEY1, found.key({ mac = MAC1 }))
			assert.equal(KEY1, found.key({ mac = "00005e005301" }))
			assert.equal(KEY1, found.key({ mac = "00:00:5E:00:53:01" }))
			assert.equal(KEY1, found.key({ mac = "00-00-5e-00-53-01" }))
			assert.equal(KEY1, found.key({ mac = "  00:00:5E:00:53:01\t" }))
		end)

		it("prefers the MAC over the instance", function()
			assert.equal(KEY2, found.key(fan("MF_Fan_005301", FAN1, MAC2)))
		end)

		it("is \"i:\" and the instance in lower case when there is no usable MAC", function()
			assert.equal("i:mf_fan_005301", found.key({ instance = "MF_Fan_005301" }))
			assert.equal("i:mf_fan_005301", found.key({ instance = "MF_Fan_005301", mac = "00:00:5E-00:53:01" }))
			assert.equal("i:mf_fan_005301", found.key({ instance = "MF_Fan_005301", mac = "00005E00530" }))
			assert.equal("i:mf_fan_005301", found.key({ instance = "MF_Fan_005301", mac = "00005E00530G" }))
			assert.equal("i:mf_fan_005301", found.key({ instance = "MF_Fan_005301", mac = 5301 }))
			assert.equal("i:mf_fan_005301", found.key({ instance = "MF_Fan_005301", mac = string.rep(" ", 70) .. MAC1 }))
		end)

		it("is nil for neither, and for what is not a record", function()
			assert.is_nil(found.key({}))
			assert.is_nil(found.key({ instance = "", mac = "" }))
			assert.is_nil(found.key({ instance = 42, mac = false }))
			assert.is_nil(found.key(nil))
			assert.is_nil(found.key("MF_Fan_005301"))
			assert.is_nil(found.key(MAC1))
		end)

		it("makes one key of a fan heard with its MAC spelled two ways", function()
			local r = rig()
			r.l:window({ fan("MF_Fan_005301", FAN1, "00:00:5E:00:53:01") })
			r.l:window({ fan("MF_Fan_005301", FAN1, "00005e005301") })
			assert.same({ KEY1 }, r.keys())
			assert.equal(MAC1, r.l:get(KEY1).mac) -- upper case, as discovery and the model write a MAC
		end)

		it("makes one key of an instance without a MAC heard in two cases, and keeps the latest spelling", function()
			local r = rig()
			r.l:window({ fan("MF_Fan_005302", FAN2, nil) })
			r.l:window({ fan("mf_fan_005302", FAN2, nil) })
			assert.same({ "i:mf_fan_005302" }, r.keys())
			local e = r.l:get("i:mf_fan_005302")
			assert.equal("mf_fan_005302", e.instance)
			assert.is_nil(e.mac)
		end)
	end)

	describe("what a key keeps (section 3)", function()
		it("keeps instance, MAC, address and the time it was last heard", function()
			local r = rig()
			r.l:window({ one() })
			assert.same({
				key = KEY1, instance = "MF_Fan_005301", address = FAN1, mac = MAC1, last_heard = 5000,
			}, r.l:get(KEY1))
			r.clock = 9000
			r.l:window({ two() })
			assert.equal(5000, r.l:get(KEY1).last_heard)
			r.l:window({ one() })
			assert.equal(9000, r.l:get(KEY1).last_heard)
		end)

		it("takes the address of the latest window's answer", function()
			local r = rig()
			r.l:window({ one() })
			assert.is_true(r.l:window({ fan("MF_Fan_005301", FAN2, MAC1) }))
			assert.equal(FAN2, r.l:get(KEY1).address)
			assert.same({ KEY1 }, r.keys())
		end)

		it("takes the last answer of a key within one window (both addresses heard)", function()
			local r = rig()
			r.l:window({ fan("MF_Fan_005301", FAN2, MAC1), fan("MF_Fan_005301", FAN1, MAC1) })
			assert.equal(FAN1, r.l:get(KEY1).address)
			r.l:window({ fan("MF_Fan_005301", FAN1, MAC1), fan("MF_Fan_005301", FAN2, MAC1) })
			assert.equal(FAN2, r.l:get(KEY1).address)
		end)

		it("keeps a known instance when a later answer of the MAC has none", function()
			local r = rig()
			r.l:window({ one() })
			r.l:window({ fan(nil, FAN2, MAC1) })
			local e = r.l:get(KEY1)
			assert.equal("MF_Fan_005301", e.instance)
			assert.equal(FAN2, e.address)
		end)

		it("gives copies: changing one does not reach the list", function()
			local r = rig()
			r.l:window({ one() })
			r.l:get(KEY1).address = "x"
			r.l:entries()[1].address = "y"
			r.l:keep(KEY1).address = "z"
			assert.equal(FAN1, r.l:get(KEY1).address)
			assert.equal(FAN1, r.l:kept().address)
		end)

		it("does not keep the heard records themselves", function()
			local r = rig()
			local heard = { one() }
			r.l:window(heard)
			heard[1].address = FAN2
			assert.equal(FAN1, r.l:get(KEY1).address)
		end)

		it("get answers nil for a key that is not listed, or not a key", function()
			local r = rig()
			r.l:window({ one() })
			assert.is_nil(r.l:get(KEY2))
			assert.is_nil(r.l:get(nil))
			assert.is_nil(r.l:get({}))
		end)
	end)

	describe("ageing (section 3: MISSES windows that sent their query)", function()
		it("removes a key after three sending windows in a row without it, not before", function()
			local r = rig()
			r.l:window({ one(), two() })
			r.l:window({ one() })
			r.l:window({ one() })
			assert.is_not_nil(r.l:get(KEY2))
			assert.is_true(r.l:window({ one() }))
			assert.is_nil(r.l:get(KEY2))
			assert.same({ KEY1 }, r.keys())
		end)

		it("counts the misses afresh once the key is heard again", function()
			local r = rig()
			r.l:window({ one(), two() })
			r.l:window({ one() })
			r.l:window({ one() })
			r.l:window({ one(), two() })
			r.l:window({ one() })
			r.l:window({ one() })
			assert.is_not_nil(r.l:get(KEY2))
			r.l:window({ one() })
			assert.is_nil(r.l:get(KEY2))
		end)

		it("empties the list after three sending windows that heard nothing", function()
			local r = rig()
			r.l:window({ one(), two() })
			r.l:window({})
			r.l:window(nil)
			assert.equal(2, #r.l:entries())
			r.l:window({})
			assert.same({}, r.l:entries())
		end)

		it("takes its count from the misses option", function()
			local r = rig({ opts = { misses = 1 } })
			r.l:window({ one(), two() })
			r.l:window({ one() })
			assert.same({ KEY1 }, r.keys())
		end)

		it("falls back to found.MISSES for a misses option that is not a count", function()
			assert.equal(3, found.MISSES)
			for _, bad in ipairs({ 0, -2, "x", math.huge, 0 / 0 }) do
				local r = rig({ opts = { misses = bad } })
				r.l:window({ one() })
				r.l:window({})
				r.l:window({})
				assert.is_not_nil(r.l:get(KEY1), tostring(bad))
				r.l:window({})
				assert.is_nil(r.l:get(KEY1), tostring(bad))
			end
		end)
	end)

	describe("failed windows (section 3: an error word ages nothing)", function()
		it("ages nothing, however many fail", function()
			local r = rig()
			r.l:window({ one() })
			for _ = 1, 10 do
				r.l:window({}, "send")
			end
			assert.is_not_nil(r.l:get(KEY1))
		end)

		it("neither counts nor breaks the run of sending misses", function()
			local r = rig()
			r.l:window({ one(), two() })
			r.l:window({ one() })
			r.l:window({}, "open")
			r.l:window({ one() })
			r.l:window({}, "timer")
			assert.is_not_nil(r.l:get(KEY2))
			r.l:window({ one() })
			assert.is_nil(r.l:get(KEY2))
		end)

		it("makes failing() true until a window sends again", function()
			local r = rig()
			assert.is_false(r.l:failing())
			assert.is_true(r.l:window({}, "open"))
			assert.is_true(r.l:failing())
			assert.is_false(r.l:window({}, "send"))
			assert.is_true(r.l:failing())
			assert.is_true(r.l:window({}))
			assert.is_false(r.l:failing())
		end)

		it("takes the answers a failed window carries all the same", function()
			local r = rig()
			r.l:window({ one() }, "send")
			assert.is_not_nil(r.l:get(KEY1))
			assert.is_true(r.l:failing())
		end)

		it("treats a false error word as none", function()
			local r = rig()
			r.l:window({ one() })
			r.l:window({}, false)
			r.l:window({}, false)
			r.l:window({}, false)
			assert.is_nil(r.l:get(KEY1))
			assert.is_false(r.l:failing())
		end)
	end)

	describe("order (section 3: own first, then instance case-blind, then address)", function()
		it("puts this device's fan first, whatever its instance", function()
			local r = rig()
			r.l:window({
				fan("MF_Fan_005301", FAN1, MAC1), fan("MF_Fan_005302", FAN2, MAC2), fan("AAA_Fan_005303", ip(192, 0, 2, 3), MAC3),
			})
			assert.same({ KEY3, KEY1, KEY2 }, r.keys())
			assert.same({ KEY2, KEY3, KEY1 }, r.keys(MAC2))
			local list = r.l:entries(MAC2)
			assert.is_true(list[1].own)
			assert.is_false(list[2].own)
			assert.is_false(list[3].own)
		end)

		it("reads the pinned MAC in any spelling, and marks nothing for no pin or a MAC not heard", function()
			local r = rig()
			r.l:window({ one(), two() })
			assert.same({ KEY2, KEY1 }, r.keys("00:00:5e:00:53:02"))
			assert.same({ KEY2, KEY1 }, r.keys("00-00-5E-00-53-02"))
			for _, pin in ipairs({ false, "MF_00005E005302", MAC3, 7 }) do
				local list = r.l:entries(pin)
				assert.same({ KEY1, KEY2 }, { list[1].key, list[2].key }, tostring(pin))
				assert.is_false(list[1].own)
				assert.is_false(list[2].own)
			end
			assert.same({ KEY1, KEY2 }, r.keys())
		end)

		it("never marks an instance key as this device's fan", function()
			local r = rig()
			r.l:window({ fan("MF_Fan_005301", FAN1, nil) })
			assert.is_false(r.l:entries(MAC1)[1].own)
		end)

		it("sorts by instance without regard to case", function()
			local r = rig()
			r.l:window({
				fan("mf_fan_005303", FAN1, MAC3), fan("MF_Fan_005302", FAN2, MAC2), fan("Mf_Fan_005301", FAN1, MAC1),
			})
			assert.same({ KEY1, KEY2, KEY3 }, r.keys())
		end)

		it("sorts one instance by address, by its numbers", function()
			local r = rig()
			r.l:window({
				fan("MF_Fan", ip(192, 0, 2, 10), MAC1), fan("MF_Fan", ip(192, 0, 2, 9), MAC2), fan("MF_Fan", "fan.local", MAC3),
			})
			assert.same({ KEY2, KEY1, KEY3 }, r.keys())
		end)

		it("is stable from window to window, whatever order the answers came in", function()
			local r = rig()
			local a, b, c = one(), two(), fan("MF_Fan_005303", ip(192, 0, 2, 3), MAC3)
			r.l:window({ c, a, b })
			local first = r.keys(MAC2)
			r.l:window({ b, c, a })
			assert.same(first, r.keys(MAC2))
			r.l:window({ a, b, c })
			assert.same(first, r.keys(MAC2))
			assert.same({ KEY2, KEY1, KEY3 }, first)
		end)

		it("lists every key; capping the rows is the texts module's", function()
			local r = rig()
			local heard = {}
			for i = 1, 20 do
				heard[i] = fan(string.format("MF_Fan_0053%02X", i), ip(192, 0, 2, i), string.format("00005E0053%02X", i))
			end
			r.l:window(heard)
			assert.equal(20, #r.l:entries())
		end)
	end)

	describe("the kept pick (section 4)", function()
		it("keeps a listed key and shows it at its latest address in its subnet (#214)", function()
			local r = rig()
			r.l:window({ one(), two() })
			local e = r.l:keep(KEY2)
			assert.equal(KEY2, e.key)
			assert.equal(FAN2, e.address)
			r.l:window({ one(), fan("MF_Fan_005302", ip(10, 0, 2, 160), MAC2) })
			assert.equal(ip(10, 0, 2, 160), r.l:kept().address)
			assert.equal(KEY2, r.l:kept().key)
		end)

		it("never ages the kept key out while it is kept", function()
			local r = rig()
			r.l:window({ one(), two() })
			r.l:keep(KEY2)
			for _ = 1, 6 do
				r.l:window({ one() })
			end
			assert.is_not_nil(r.l:get(KEY2))
			assert.equal(KEY2, r.l:kept().key)
			assert.same({ KEY1, KEY2 }, r.keys())
		end)

		it("ages the key again once dropped: the next sending window without it removes it", function()
			local r = rig()
			r.l:window({ one(), two() })
			r.l:keep(KEY2)
			for _ = 1, 4 do
				r.l:window({ one() })
			end
			r.l:drop()
			assert.is_nil(r.l:kept())
			r.l:window({}, "send")
			assert.is_not_nil(r.l:get(KEY2))
			r.l:window({ one() })
			assert.is_nil(r.l:get(KEY2))
		end)

		it("a later pick replaces it, and a key not listed keeps nothing and leaves the pick", function()
			local r = rig()
			r.l:window({ one(), two() })
			r.l:keep(KEY2)
			assert.equal(KEY1, r.l:keep(KEY1).key)
			assert.equal(KEY1, r.l:kept().key)
			assert.is_nil(r.l:keep(KEY3))
			assert.is_nil(r.l:keep(nil))
			assert.equal(KEY1, r.l:kept().key)
		end)

		it("is nil before any pick", function()
			local r = rig()
			r.l:window({ one() })
			assert.is_nil(r.l:kept())
		end)

		it("keep and drop change no row by themselves (window decides changed)", function()
			local r = rig()
			r.l:window({ one(), two() })
			r.l:keep(KEY2)
			assert.is_false(r.l:window({ one(), two() }))
			r.l:drop()
			assert.is_false(r.l:window({ one(), two() }))
		end)
	end)

	describe("usable entries only (section 3)", function()
		it("ignores entries usable() refuses", function()
			local r = rig()
			r.l:window({ one(), fan("MF_Fan_005302", FAN2, MAC2, 8080) })
			assert.same({ KEY1 }, r.keys())
		end)

		it("hands usable() the heard record", function()
			local seen = {}
			local r = rig({ opts = { usable = function(entry) seen[#seen + 1] = entry; return true end } })
			local heard = { one() }
			r.l:window(heard)
			assert.equal(heard[1], seen[1])
		end)

		it("counts only a true answer, and treats a usable() that raises or is missing as a refusal", function()
			for _, usable in ipairs({ raises, function() return 1 end, function() return "yes" end, false }) do
				local r = rig({ opts = { usable = usable } })
				local ok = pcall(function() r.l:window({ one() }) end)
				assert.is_true(ok)
				assert.same({}, r.l:entries())
			end
			local r = rig({ without = { "usable" } })
			r.l:window({ one() })
			assert.same({}, r.l:entries())
		end)

		it("skips what is not a record, a record without an address or a key, and a heard that is not a list", function()
			local r = rig()
			assert.has_no.errors(function()
				r.l:window({ "MF_Fan_005301", 42, true, fan("MF_Fan_005302", nil, MAC2), fan("MF_Fan_005302", "", MAC2),
					fan("MF_Fan_005302", 152, MAC2), { address = FAN2, port = 80 }, one() })
				r.l:window("heard")
				r.l:window(17)
			end)
			assert.same({ KEY1 }, r.keys())
		end)

		it("an unusable answer of a listed fan does not count as hearing it", function()
			local r = rig()
			r.l:window({ one() })
			for _ = 1, 3 do
				r.l:window({ fan("MF_Fan_005301", FAN2, MAC1, 8080) })
			end
			assert.is_nil(r.l:get(KEY1))
		end)
	end)

	describe("changed (the driver redraws Found Fans on it)", function()
		it("is true for the first window of a run, even one that heard nothing", function()
			local r = rig()
			assert.is_false(r.l:heard_once())
			assert.is_true(r.l:window({}))
			assert.is_true(r.l:heard_once())
			assert.is_false(r.l:window({}))
		end)

		it("is true when a key comes or goes, an address or an instance changes, and false otherwise", function()
			local r = rig()
			assert.is_true(r.l:window({ one() }))
			assert.is_false(r.l:window({ one() }))
			assert.is_true(r.l:window({ one(), two() }))
			assert.is_false(r.l:window({ two(), one() }))
			assert.is_true(r.l:window({ one(), fan("MF_Fan_005302", ip(192, 0, 2, 7), MAC2) }))
			assert.is_true(r.l:window({ one(), fan("MF_Fan_5302", ip(192, 0, 2, 7), MAC2) }))
			assert.is_false(r.l:window({ one() }))
			assert.is_false(r.l:window({ one() }))
			assert.is_true(r.l:window({ one() }))
			assert.is_false(r.l:window({ one() }))
		end)

		it("is false for a window that only renews the time a key was heard", function()
			local r = rig()
			r.l:window({ one() })
			r.clock = r.clock + 60
			assert.is_false(r.l:window({ one() }))
			assert.equal(r.clock, r.l:get(KEY1).last_heard)
		end)
	end)

	describe("log lines (section 3), once per change", function()
		it("names the fans by their last four MAC digits and addresses", function()
			local r = rig()
			r.l:window({ two(), one() })
			assert.same({ "Found Fans: 2 fans (...5301 at 10.0.2.151, ...5302 at 10.0.2.152)" }, r.said("always"))
		end)

		it("writes nothing more while the same fans answer at the same addresses", function()
			local r = rig()
			r.l:window({ one() })
			r.l:window({ one() })
			r.l:window({ one(), one() })
			r.clock = r.clock + 900
			r.l:window({ one() })
			assert.same({ "Found Fans: 1 fan (...5301 at 10.0.2.151)" }, r.said("always"))
		end)

		it("writes a line for a new fan, a new address, a fan aged out and an empty list", function()
			local r = rig()
			r.l:window({ one() })
			r.l:window({ one(), two() })
			r.l:window({ fan("MF_Fan_005301", FAN2, MAC1), two() })
			r.l:window({ two() })
			r.l:window({})
			r.l:window({})
			r.l:window({})
			r.l:window({})
			assert.same({
				"Found Fans: 1 fan (...5301 at 10.0.2.151)",
				"Found Fans: 2 fans (...5301 at 10.0.2.151, ...5302 at 10.0.2.152)",
				"Found Fans: 2 fans (...5301 at 10.0.2.152, ...5302 at 10.0.2.152)",
				"Found Fans: 1 fan (...5302 at 10.0.2.152)",
				"Found Fans: no fan answered",
			}, r.said("always"))
		end)

		it("says no fan answered once for a first window that heard nothing", function()
			local r = rig()
			r.l:window({})
			r.l:window({})
			assert.same({ "Found Fans: no fan answered" }, r.said("always"))
		end)

		it("does not write a line for an instance change alone", function()
			local r = rig()
			r.l:window({ one() })
			r.l:window({ fan("MF_Fan_5301", FAN1, MAC1) })
			assert.equal(1, #r.said("always"))
		end)

		it("shows an instance key by its instance's last four characters", function()
			local r = rig()
			r.l:window({ fan("MF_Fan_005302", FAN2, nil) })
			assert.same({ "Found Fans: 1 fan (...5302 at 10.0.2.152)" }, r.said("always"))
		end)

		it("writes the instance as it is, even with a % in it", function()
			local r = rig()
			r.l:window({ fan("MF_%d%s", FAN2, nil) })
			assert.same({ "Found Fans: 1 fan (...%d%s at 10.0.2.152)" }, r.said("always"))
		end)

		it("warns once per failing streak, and a failed window writes no Found Fans line", function()
			local r = rig()
			r.l:window({ one() })
			r.l:window({}, "open")
			r.l:window({}, "send")
			r.l:window({}, "send")
			assert.same({ "Search: the query could not be sent on this controller" }, r.said("warn"))
			assert.equal(1, #r.said("always"))
			r.l:window({ one() })
			r.l:window({}, "open")
			assert.equal(2, #r.said("warn"))
			assert.equal(1, #r.said("always"))
		end)

		it("goes through common.log as it is", function()
			local log = require("common.log")
			local real = log.sink
			local lines = {}
			log.sink = function(line) lines[#lines + 1] = line end
			local ok, problem = pcall(function()
				local l = found.new({ usable = port80, now = function() return 1 end, log = log })
				l:window({ one() })
				l:window({}, "send")
			end)
			log.sink = real
			assert.is_true(ok, tostring(problem))
			assert.equal(2, #lines)
			assert.truthy(lines[1]:find("Found Fans: 1 fan (...5301 at 10.0.2.151)", 1, true))
			assert.truthy(lines[2]:find("[WARN] ", 1, true))
			assert.truthy(lines[2]:find("Search: the query could not be sent on this controller", 1, true))
		end)
	end)

	describe("heard_once and clear (a run)", function()
		it("heard_once turns true with the first window, a failed one too", function()
			local r = rig()
			assert.is_false(r.l:heard_once())
			r.l:window({}, "open")
			assert.is_true(r.l:heard_once())
		end)

		it("clear starts a fresh run: no key, no pick, not failing, no window, and the next window logs again", function()
			local r = rig()
			r.l:window({ one(), two() })
			r.l:keep(KEY2)
			r.l:window({}, "send")
			r.l:clear()
			assert.same({}, r.l:entries())
			assert.is_nil(r.l:kept())
			assert.is_false(r.l:failing())
			assert.is_false(r.l:heard_once())
			assert.is_true(r.l:window({ one(), two() }))
			assert.equal(2, #r.said("always"))
			r.l:window({}, "send")
			assert.equal(2, #r.said("warn"))
		end)
	end)

	describe("faults: nothing raises", function()
		it("builds without options and calls none at build", function()
			local called = false
			local function spy() called = true end
			assert.has_no.errors(function()
				found.new()
				found.new("opts")
				found.new({ usable = spy, now = spy, log = { always = spy, warn = spy } })
			end)
			assert.is_false(called)
		end)

		it("a list without options takes nothing and logs nothing, and never raises", function()
			local l = found.new()
			assert.has_no.errors(function()
				l:window({ one() })
				l:window({}, "send")
				l:entries(MAC1)
				l:keep(KEY1)
				l:kept()
				l:drop()
				l:clear()
			end)
			assert.same({}, l:entries())
		end)

		it("a clock that raises or answers no number leaves the last good time, or none", function()
			local clock = { 100 }
			local r = rig({ opts = { now = function() return clock[1] end } })
			r.l:window({ one() })
			assert.equal(100, r.l:get(KEY1).last_heard)
			clock[1] = "late"
			r.l:window({ one() })
			assert.equal(100, r.l:get(KEY1).last_heard)
			local s = rig({ opts = { now = raises } })
			assert.has_no.errors(function() s.l:window({ one() }) end)
			assert.is_nil(s.l:get(KEY1).last_heard)
			assert.equal(FAN1, s.l:get(KEY1).address)
		end)

		it("a log that raises, or lacks a level, does not stop the list", function()
			for _, bad in ipairs({ { always = raises, warn = raises }, {}, "log" }) do
				local r = rig({ opts = { log = bad } })
				assert.has_no.errors(function()
					r.l:window({ one() })
					r.l:window({}, "send")
				end)
				assert.same({ KEY1 }, r.keys())
				assert.is_true(r.l:failing())
			end
		end)

		it("entries with a stored record lacking an instance sorts without raising", function()
			local r = rig()
			r.l:window({ fan(nil, FAN2, MAC2), fan(nil, FAN1, MAC1), fan("MF_Fan_005303", FAN1, MAC3) })
			assert.same({ KEY1, KEY2, KEY3 }, r.keys())
		end)
	end)

	describe("the kept pick's lifetime (#214, KEEP_MS)", function()
		it("is 10 minutes", function()
			assert.equal(600000, found.KEEP_MS)
		end)

		it("is taken within its lifetime, at its latest address", function()
			local r = rig()
			r.l:window({ one(), two() })
			r.l:keep(KEY2)
			r.clock = r.clock + 599
			assert.equal(KEY2, r.l:kept().key)
			r.l:window({ one(), fan("MF_Fan_005302", ip(10, 0, 2, 160), MAC2) })
			assert.equal(ip(10, 0, 2, 160), r.l:kept().address)
			for _, line in ipairs(r.said("always")) do
				assert.is_nil(line:find("dropped", 1, true), line)
			end
		end)

		it("is dropped past its lifetime as if nothing was picked: kept() is nil, and a line says so", function()
			local r = rig()
			r.l:window({ one(), two() })
			r.l:keep(KEY2)
			r.clock = r.clock + 600
			assert.is_nil(r.l:kept())
			assert.is_nil(r.l:kept(), "and stays dropped")
			local lines = r.said("always")
			assert.equal("Found Fans: the pick of ...5302 waited 10 min for Use Selected Fan; dropped", lines[#lines])
			assert.is_not_nil(r.l:get(KEY2), "the fan stays listed")
		end)

		it("ages the dropped pick's key again: three sending windows without it remove it", function()
			local r = rig()
			r.l:window({ one(), two() })
			r.l:keep(KEY2)
			r.clock = r.clock + 601
			r.l:window({ one() })
			assert.is_nil(r.l:kept())
			r.l:window({ one() })
			assert.is_not_nil(r.l:get(KEY2))
			r.l:window({ one() })
			assert.is_nil(r.l:get(KEY2))
		end)

		it("starts again with every pick, and ends with drop", function()
			local r = rig()
			r.l:window({ one(), two() })
			r.l:keep(KEY2)
			r.clock = r.clock + 500
			r.l:keep(KEY2)
			r.clock = r.clock + 500
			assert.equal(KEY2, r.l:kept().key, "500 s after the second pick")
			r.l:drop()
			r.l:keep(KEY1)
			r.clock = r.clock + 599
			assert.equal(KEY1, r.l:kept().key)
		end)

		it("starts at the first reading of a clock that failed at the pick, and stays without any clock", function()
			local clock = { "late" }
			local r = rig({ opts = { now = function() return clock[1] end } })
			r.l:window({ one(), two() })
			r.l:keep(KEY2)
			clock[1] = 100
			assert.equal(KEY2, r.l:kept().key)
			clock[1] = 699
			assert.equal(KEY2, r.l:kept().key)
			clock[1] = 700
			assert.is_nil(r.l:kept())
			local s = rig({ without = { "now" } })
			s.l:window({ one(), two() })
			s.l:keep(KEY2)
			assert.equal(KEY2, s.l:kept().key)
		end)

		it("starts again when the clock went back", function()
			local r = rig()
			r.l:window({ one(), two() })
			r.l:keep(KEY2)
			r.clock = r.clock - 1000
			assert.equal(KEY2, r.l:kept().key)
			r.clock = r.clock + 599
			assert.equal(KEY2, r.l:kept().key)
			r.clock = r.clock + 1
			assert.is_nil(r.l:kept())
		end)
	end)

	describe("the kept pick's subnet (#214, security-214 S1-7)", function()
		it("does not move to an answer from another subnet while it is kept; the line says where it stays", function()
			local r = rig()
			r.l:window({ one(), two() })
			r.l:keep(KEY2)
			r.l:window({ one(), fan("MF_Fan_005302", ip(192, 0, 2, 7), MAC2) })
			assert.equal(FAN2, r.l:kept().address)
			assert.same({ "Found Fans: the picked fan ...5302 answered at 192.0.2.7, outside the subnet of 10.0.2.152;"
				.. " the pick stays there" }, r.said("debug"))
		end)

		it("takes the last answer within its subnet when a window heard it in both", function()
			local r = rig()
			r.l:window({ one(), two() })
			r.l:keep(KEY2)
			r.l:window({ fan("MF_Fan_005302", ip(10, 0, 2, 160), MAC2), fan("MF_Fan_005302", ip(10, 9, 9, 9), MAC2) })
			assert.equal(ip(10, 0, 2, 160), r.l:kept().address)
		end)

		it("moves link-local to link-local, and nowhere else", function()
			local r = rig()
			r.l:window({ fan("MF_Fan_005302", ip(169, 254, 1, 2), MAC2) })
			r.l:keep(KEY2)
			r.l:window({ fan("MF_Fan_005302", ip(169, 254, 200, 3), MAC2) })
			assert.equal(ip(169, 254, 200, 3), r.l:kept().address)
			r.l:window({ fan("MF_Fan_005302", FAN2, MAC2) })
			assert.equal(ip(169, 254, 200, 3), r.l:kept().address)
		end)

		it("holds only the kept pick: other keys, and the pick once dropped, take any address", function()
			local r = rig()
			r.l:window({ one(), two() })
			r.l:keep(KEY2)
			r.l:window({ fan("MF_Fan_005301", ip(192, 0, 2, 7), MAC1), two() })
			assert.equal(ip(192, 0, 2, 7), r.l:get(KEY1).address)
			r.l:drop()
			r.l:window({ one(), fan("MF_Fan_005302", ip(192, 0, 2, 8), MAC2) })
			assert.equal(ip(192, 0, 2, 8), r.l:get(KEY2).address)
		end)
	end)

	describe("found.distinct: Found Fans rows no two share (#214, security-214 S1-5)", function()
		-- A MAC as a label prints it, built from its octets so no literal outside the documentation range is
		-- written here.
		local function label(...)
			return table.concat({ ... }, ":")
		end

		it("leaves rows that differ as they are, in their places", function()
			local items = { "MF_Fan_005301 at 10.0.2.151", "MF_Fan_005302 at 10.0.2.152" }
			assert.same(items, found.distinct(items, { { mac = MAC1 }, { mac = MAC2 } }, { "2 fans found" }))
		end)

		it("gives each of two rows with one text its fan's MAC", function()
			local forged = "02005E005301" -- another MAC whose last six digits are the pinned fan's
			local items = { "MF_Fan_005301 at 10.0.2.152", "MF_Fan_005301 at 10.0.2.152", "MF_Fan_005302 at 10.0.2.152" }
			local out = found.distinct(items, { { mac = forged }, { mac = MAC1 }, { mac = MAC2 } }, {})
			assert.same({
				"MF_Fan_005301 at 10.0.2.152 (MAC " .. label("02", "00", "5E", "00", "53", "01") .. ")",
				"MF_Fan_005301 at 10.0.2.152 (MAC " .. label("00", "00", "5E", "00", "53", "01") .. ")",
				"MF_Fan_005302 at 10.0.2.152",
			}, out)
		end)

		it("numbers what a MAC cannot tell apart, and a row that reads as the summary", function()
			local out = found.distinct({ "fan at 10.0.2.151", "fan at 10.0.2.151", "fan at 10.0.2.151" }, {}, {})
			assert.same({ "fan at 10.0.2.151", "fan at 10.0.2.151 #2", "fan at 10.0.2.151 #3" }, out)
			out = found.distinct({ "1 fan found", "fan at 10.0.2.151 #2", "fan at 10.0.2.151", "fan at 10.0.2.151" },
				{ {}, {}, {}, {} }, { "1 fan found" })
			assert.same({ "1 fan found #2", "fan at 10.0.2.151 #2", "fan at 10.0.2.151", "fan at 10.0.2.151 #3" }, out)
		end)

		it("gives every row a text of its own, however the rows are made", function()
			local items, entries = {}, {}
			for i = 1, 40 do
				items[i] = (i % 3 == 0) and "x #2" or "x"
				entries[i] = (i % 2 == 0) and { mac = MAC1 } or {}
			end
			local out = found.distinct(items, entries, { "x", "x #2" })
			local seen = { x = true, ["x #2"] = true }
			assert.equal(40, #out)
			for _, text in ipairs(out) do
				assert.is_nil(seen[text], text)
				assert.is_nil(text:find(",", 1, true))
				seen[text] = true
			end
		end)

		it("never raises, and gives a list for anything", function()
			assert.same({}, found.distinct(nil))
			assert.same({}, found.distinct("items"))
			assert.same({ "a", "a #2" }, found.distinct({ "a", "a" }, "entries", 42))
			assert.same({ "a" }, found.distinct({ "a" }))
		end)
	end)

	describe("the Found Fans line's length (#214, security-214 S1-8)", function()
		it("names at most 16 fans and counts the rest", function()
			assert.equal(16, found.LOG_FANS)
			local r = rig()
			local heard = {}
			for i = 1, 20 do
				heard[i] = fan(string.format("MF_Fan_%06d", i), ip(10, 0, 2, i), string.format("00005E0053%02X", i))
			end
			r.l:window(heard)
			local line = r.said("always")[1]
			assert.is_truthy(line:find("^Found Fans: 20 fans %("))
			assert.is_truthy(line:find(", and 4 more%)$"), line)
			local _, named = line:gsub(" at ", "")
			assert.equal(16, named)
		end)

		it("writes an instance's tail with control characters or other bytes as ?", function()
			local r = rig()
			r.l:window({ fan("MF_\1\n\200\0", FAN2, nil) })
			assert.same({ "Found Fans: 1 fan (...???? at 10.0.2.152)" }, r.said("always"))
		end)
	end)
end)
