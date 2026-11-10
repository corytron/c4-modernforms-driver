-- fan.ledhub on stub engines (#159, docs/speed-leds-design.md 3.2, SL-D2, section 5). Both stubs write every
-- call into one ordered list ("speed:update", "breeze:held", ...). The scripted stubs model when each engine
-- takes and lets go of pixels, and every change of a hold checks at once that no link is held by both, so an
-- overlap is caught even inside a single hub call, not only in debug().both afterwards.

local ledhub = require("fan.ledhub")
local log = require("common.log")

local HOUSE = { 302, 303, 304, 305 } -- Low, Medium, Med-High, High

local function fake_log()
	local l = { lines = {} }
	function l.warn(fmt, ...)
		l.lines[#l.lines + 1] = string.format(fmt, ...)
	end
	function l.has(...)
		for _, line in ipairs(l.lines) do
			local all = true
			for _, needle in ipairs({ ... }) do
				all = all and line:find(needle, 1, true) ~= nil
			end
			if all then
				return true
			end
		end
		return false
	end
	return l
end

-- A stub engine with the method names of contract 3.1 and breezeleds.lua.
local function stub(name, w)
	local e = { hold = {}, pixels = {}, info = { engine = name } }
	local function note(method, ...)
		w.calls[#w.calls + 1] = { name = name, method = method, args = { ... } }
	end
	function e:held(link)
		note("held", link)
		return self.hold[link] == true
	end
	function e:repaint(link)
		note("repaint", link)
		return name .. " repainted " .. link
	end
	function e:set_pixels(list)
		note("set_pixels", list)
		self.pixels = list
	end
	function e:stop()
		note("stop")
		self:only({})
	end
	function e:update(view)
		note("update", view)
		if self.script then
			self:script(view)
		end
	end
	function e:debug()
		note("debug")
		return self.info
	end
	-- Holds exactly these links: lets go of the rest first, then takes each, checking after every change.
	function e:only(links)
		local keep = {}
		for _, link in ipairs(links) do
			keep[link] = true
		end
		for link in pairs(self.hold) do
			if not keep[link] then
				self.hold[link] = nil
			end
		end
		for _, link in ipairs(links) do
			self.hold[link] = true
			w.check()
		end
	end
	return e
end

local function world(opts)
	opts = opts or {}
	local w = { calls = {}, overlaps = {}, log = fake_log() }
	w.breeze, w.speed = stub("breeze", w), stub("speed", w)
	function w.check()
		for link = 301, 306 do
			if w.breeze.hold[link] and w.speed.hold[link] then
				w.overlaps[#w.overlaps + 1] = link
			end
		end
	end
	-- The speed engine's blocked(link), as the coordinator wires it: Breeze holds the link (not recorded).
	function w.blocked(link)
		return w.breeze.hold[link] == true
	end
	if opts.scripted then
		-- Breeze: every pixel while it blows; during the leave wipe only those view.leave lists; else none.
		function w.breeze:script(view)
			self:only(view.breeze and self.pixels or view.leave or {})
		end
		-- The chase: only while told to chase in fan mode (SL-D3, SL-D9), and never a blocked pixel.
		function w.speed:script(view)
			local take = {}
			if view.fan_mode == true and view.chase then
				for _, link in ipairs(self.pixels) do
					if not w.blocked(link) then
						take[#take + 1] = link
					end
				end
			end
			self:only(take)
		end
	end
	w.hub = ledhub.new({ breeze = w.breeze, speed = w.speed, log = w.log })
	-- The calls in order; without `all`, the queries (held, debug) are left out.
	function w.trace(all)
		local out = {}
		for _, c in ipairs(w.calls) do
			if all or (c.method ~= "held" and c.method ~= "debug") then
				out[#out + 1] = c.name .. ":" .. c.method
			end
		end
		return out
	end
	function w.clear()
		w.calls = {}
	end
	return w
end

local function holders(w)
	local out = {}
	for _, link in ipairs(HOUSE) do
		out[link] = w.breeze.hold[link] and "breeze" or w.speed.hold[link] and "speed" or "-"
	end
	return out
end

-- One hub:update, then nothing held by both, during the call or after it.
local function step(w, breeze_view, speed_view)
	w.hub:update(breeze_view, speed_view)
	assert.are.same({}, w.overlaps)
	assert.are.same({}, w.hub:debug().both)
end

describe("fan.ledhub", function()
	describe("held", function()
		it("is false when neither engine holds the link", function()
			local w = world()
			assert.is_false(w.hub:held(303))
			assert.are.same({ "breeze:held", "speed:held" }, w.trace(true))
		end)

		it("is true when Breeze holds it, without asking the speed engine", function()
			local w = world()
			w.breeze.hold[303] = true
			assert.is_true(w.hub:held(303))
			assert.are.same({ "breeze:held" }, w.trace(true))
			assert.are.equal(303, w.calls[1].args[1])
		end)

		it("is true when the speed engine holds it, Breeze asked first", function()
			local w = world()
			w.speed.hold[304] = true
			assert.is_true(w.hub:held(304))
			assert.are.same({ "breeze:held", "speed:held" }, w.trace(true))
		end)

		it("counts only a true answer", function()
			local w = world()
			w.breeze.held = function() return "yes" end
			w.speed.held = function() return 1 end
			assert.is_false(w.hub:held(302))
		end)
	end)

	describe("repaint", function()
		it("goes to Breeze when Breeze holds the link", function()
			local w = world()
			w.breeze.hold[302] = true
			assert.are.equal("breeze repainted 302", w.hub:repaint(302))
			assert.are.same({ "breeze:repaint" }, w.trace())
		end)

		it("goes to the speed engine when it holds the link", function()
			local w = world()
			w.speed.hold[305] = true
			assert.are.equal("speed repainted 305", w.hub:repaint(305))
			assert.are.same({ "speed:repaint" }, w.trace())
		end)

		it("calls nobody when neither holds the link", function()
			local w = world()
			assert.is_false(w.hub:repaint(303))
			assert.are.same({}, w.trace())
		end)

		it("goes to Breeze alone if both ever held it (Breeze wins, SL-D2)", function()
			local w = world()
			w.breeze.hold[303], w.speed.hold[303] = true, true
			w.hub:repaint(303)
			assert.are.same({ "breeze:repaint" }, w.trace())
		end)
	end)

	describe("set_pixels, stop and update", function()
		it("hand both engines the list, the speed engine first, each its own copy", function()
			local w = world()
			local list = { 305, 302, 303 }
			w.hub:set_pixels(list)
			assert.are.same({ "speed:set_pixels", "breeze:set_pixels" }, w.trace())
			assert.are.same(list, w.speed.pixels)
			assert.are.same(list, w.breeze.pixels)
			table.sort(w.speed.pixels) -- an engine ordering its list in place touches nobody else's
			assert.are.same({ 305, 302, 303 }, w.breeze.pixels)
			assert.are.same({ 305, 302, 303 }, list)
		end)

		it("stop both engines, the speed engine first", function()
			local w = world()
			w.hub:stop()
			assert.are.same({ "speed:stop", "breeze:stop" }, w.trace())
		end)

		it("update the speed engine first, then Breeze, each with its own view (SL-D2)", function()
			local w = world()
			local bview, sview = { breeze = true }, { fan_mode = false }
			w.hub:update(bview, sview)
			assert.are.same({ "speed:update", "breeze:update" }, w.trace(true))
			assert.are.equal(sview, w.calls[1].args[1])
			assert.are.equal(bview, w.calls[2].args[1])
		end)
	end)

	describe("debug", function()
		it("carries both engines' tables and an empty both", function()
			local w = world()
			w.breeze.hold[302], w.speed.hold[304] = true, true
			local d = w.hub:debug()
			assert.are.equal(w.breeze.info, d.breeze)
			assert.are.equal(w.speed.info, d.speed)
			assert.are.same({}, d.both)
		end)

		it("lists the links held by both, ascending", function()
			local w = world()
			for _, link in ipairs({ 306, 303, 301 }) do
				w.breeze.hold[link], w.speed.hold[link] = true, true
			end
			w.speed.hold[304] = true
			assert.are.same({ 301, 303, 306 }, w.hub:debug().both)
		end)
	end)

	describe("one owner per pixel (SL-D2)", function()
		it("a chase holds the pixels only while it plays", function()
			local w = world({ scripted = true })
			w.hub:set_pixels(HOUSE)
			step(w, { breeze = false }, { fan_mode = true })
			assert.is_false(w.hub:held(303))
			step(w, { breeze = false }, { fan_mode = true, chase = true })
			assert.are.same({ [302] = "speed", [303] = "speed", [304] = "speed", [305] = "speed" }, holders(w))
			assert.is_true(w.hub:held(303))
			w.clear()
			w.hub:repaint(303)
			assert.are.same({ "speed:repaint" }, w.trace())
			step(w, { breeze = false }, { fan_mode = true })
			assert.are.same({ [302] = "-", [303] = "-", [304] = "-", [305] = "-" }, holders(w))
		end)

		it("a Breeze start mid-chase: the chase lets go before Breeze takes the pixels", function()
			local w = world({ scripted = true })
			w.hub:set_pixels(HOUSE)
			step(w, { breeze = false }, { fan_mode = true, chase = true })
			w.clear()
			step(w, { breeze = true }, { fan_mode = false })
			assert.are.same({ "speed:update", "breeze:update" }, w.trace())
			assert.are.same({ [302] = "breeze", [303] = "breeze", [304] = "breeze", [305] = "breeze" }, holders(w))
			w.clear()
			w.hub:repaint(304)
			assert.are.same({ "breeze:repaint" }, w.trace())
		end)

		it("the stubs catch Breeze updated first (what the hub's order prevents)", function()
			local w = world({ scripted = true })
			w.hub:set_pixels(HOUSE)
			w.hub:update({ breeze = false }, { fan_mode = true, chase = true })
			w.breeze:update({ breeze = true })
			w.speed:update({ fan_mode = false })
			assert.are_not.same({}, w.overlaps)
		end)

		it("Breeze's leave wipe: the chase stays off the pixels Breeze still holds", function()
			local w = world({ scripted = true })
			w.hub:set_pixels(HOUSE)
			step(w, { breeze = true }, { fan_mode = false })
			-- A speed press: the wipe starts; the chase is due but every pixel is still blocked.
			local wipe = { breeze = false, leave = { 304, 305 } }
			step(w, wipe, { fan_mode = true, chase = true })
			assert.are.same({ [302] = "-", [303] = "-", [304] = "breeze", [305] = "breeze" }, holders(w))
			-- The retry (SL-D14) while the wipe still holds the top two.
			step(w, wipe, { fan_mode = true, chase = true })
			assert.are.same({ [302] = "speed", [303] = "speed", [304] = "breeze", [305] = "breeze" }, holders(w))
			w.clear()
			w.hub:repaint(305)
			w.hub:repaint(302)
			assert.are.same({ "breeze:repaint", "speed:repaint" }, w.trace())
			-- The wipe ends: the chase updates first, while 304 and 305 are still Breeze's.
			step(w, { breeze = false }, { fan_mode = true, chase = true })
			assert.are.same({ [302] = "speed", [303] = "speed", [304] = "-", [305] = "-" }, holders(w))
			step(w, { breeze = false }, { fan_mode = true, chase = true })
			assert.are.same({ [302] = "speed", [303] = "speed", [304] = "speed", [305] = "speed" }, holders(w))
			-- And Breeze again mid-chase.
			step(w, { breeze = true }, { fan_mode = false })
			assert.are.same({ [302] = "breeze", [303] = "breeze", [304] = "breeze", [305] = "breeze" }, holders(w))
		end)

		it("stop leaves nothing held", function()
			local w = world({ scripted = true })
			w.hub:set_pixels(HOUSE)
			step(w, { breeze = false }, { fan_mode = true, chase = true })
			w.hub:stop()
			assert.are.same({ [302] = "-", [303] = "-", [304] = "-", [305] = "-" }, holders(w))
			assert.are.same({}, w.overlaps)
		end)
	end)

	describe("a failing engine", function()
		local function boom()
			error("boom")
		end

		it("held: an erroring engine holds nothing; the other still answers", function()
			local w = world()
			w.breeze.held = boom
			w.speed.hold[302] = true
			assert.is_true(w.hub:held(302))
			assert.is_false(w.hub:held(303))
			assert.is_true(w.log.has("breeze", "held()", "boom"))
		end)

		it("update: either engine failing still updates the other", function()
			local w = world()
			w.speed.update = boom
			w.hub:update({ breeze = true }, { fan_mode = false })
			assert.are.same({ "breeze:update" }, w.trace())
			assert.is_true(w.log.has("speed", "update()", "boom"))
			w = world()
			w.breeze.update = boom
			w.hub:update({ breeze = true }, { fan_mode = false })
			w.hub:update({ breeze = true }, { fan_mode = false })
			assert.are.same({ "speed:update", "speed:update" }, w.trace())
			assert.is_true(w.log.has("breeze", "update()", "boom"))
		end)

		it("set_pixels and stop: the speed engine failing still reaches Breeze", function()
			local w = world()
			w.speed.set_pixels, w.speed.stop = boom, boom
			w.hub:set_pixels(HOUSE)
			w.hub:stop()
			assert.are.same({ "breeze:set_pixels", "breeze:stop" }, w.trace())
			assert.is_true(w.log.has("speed", "set_pixels()"))
			assert.is_true(w.log.has("speed", "stop()"))
		end)

		it("repaint: past a Breeze that cannot answer held; a failing repaint answers false", function()
			local w = world()
			w.breeze.held = boom
			w.speed.hold[303] = true
			assert.are.equal("speed repainted 303", w.hub:repaint(303))
			w = world()
			w.breeze.hold[303] = true
			w.breeze.repaint = boom
			assert.is_false(w.hub:repaint(303))
			assert.are.same({}, w.trace()) -- the speed engine is not asked to repaint Breeze's pixel
			assert.is_true(w.log.has("breeze", "repaint()", "boom"))
		end)

		it("debug: the failing engine's table says why; the other is whole", function()
			local w = world()
			w.breeze.debug = boom
			local d = w.hub:debug()
			assert.is_truthy(d.breeze.error:find("boom", 1, true))
			assert.are.equal(w.speed.info, d.speed)
			assert.are.same({}, d.both)
		end)

		it("a missing engine is logged and the other carries on", function()
			local l = fake_log()
			local w = world()
			local hub = ledhub.new({ speed = w.speed, log = l })
			w.speed.hold[304] = true
			assert.is_true(hub:held(304))
			hub:update({ breeze = true }, { fan_mode = true })
			hub:set_pixels(HOUSE)
			hub:stop()
			assert.are.same({ "speed:update", "speed:set_pixels", "speed:stop" }, w.trace())
			assert.is_true(l.has("breeze", "not given"))
			assert.has_no.errors(function() ledhub.new({ log = l }):debug() end)
		end)

		it("a log that raises is survived too", function()
			local w = world()
			w.hub = ledhub.new({ breeze = w.breeze, speed = w.speed, log = { warn = boom } })
			w.speed.update = boom
			assert.has_no.errors(function() w.hub:update({}, {}) end)
			assert.are.same({ "breeze:update" }, w.trace())
		end)

		it("logs at warn through common.log when no log is given", function()
			local real, lines = log.sink, {}
			log.sink = function(line) lines[#lines + 1] = line end
			finally(function() log.sink = real end)
			local w = world()
			w.speed.stop = boom
			ledhub.new({ breeze = w.breeze, speed = w.speed }):stop()
			assert.are.equal(1, #lines)
			assert.is_truthy(lines[1]:find("[WARN]", 1, true))
			assert.is_truthy(lines[1]:find("speed engine's stop()", 1, true))
		end)
	end)
end)
