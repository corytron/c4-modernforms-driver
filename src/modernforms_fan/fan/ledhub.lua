-- The speed links' one owner (#159, docs/speed-leds-design.md 3.2): the Breeze engine (fan/breezeleds.lua) and
-- the speed chase (fan/speedleds.lua) behind a single held / repaint / pixels for fan/links.lua.
-- SL-D2, one owner per pixel and Breeze wins: held() and repaint() ask Breeze first; update() runs the speed
-- engine before Breeze, so the chase lets go before Breeze takes the pixels; set_pixels() (each engine gets its
-- own copy) and stop() go to both, the speed engine first too. debug().both lists the links held by both.
-- Pure: no timers, no C4 calls, no state beyond the engines. Every engine call runs in pcall; a failure is
-- logged at warn (opts.log, default common.log), the other engine is still called, and an engine whose held()
-- fails holds nothing. Lua 5.1.

local ledhub = {}

ledhub.FIRST_LINK = 301 -- the speed links, the only pixels either engine holds (BL-D2)
ledhub.LAST_LINK = 306

local BREEZE_FIRST = { "breeze", "speed" } -- SL-D2

local Hub = {}
Hub.__index = Hub

function ledhub.new(opts)
	opts = type(opts) == "table" and opts or {}
	return setmetatable({ breeze = opts.breeze, speed = opts.speed, log = opts.log or require("common.log") }, Hub)
end

-- self[name]:method(...) in pcall: ok and its first result. A failure is logged at warn, never raised.
function Hub:call(name, method, ...)
	local engine = self[name]
	local fn = type(engine) == "table" and engine[method] or nil
	local ok, result = false, "not given"
	if type(fn) == "function" then
		ok, result = pcall(fn, engine, ...)
	end
	local warn = type(self.log) == "table" and self.log.warn or nil
	if not ok and type(warn) == "function" then
		pcall(warn, "LED hub: the %s engine's %s() failed: %s", name, method, tostring(result))
	end
	return ok, result
end

function Hub:holds(name, link)
	local ok, held = self:call(name, "held", link)
	return ok and held == true
end

function Hub:held(link)
	return self:holds("breeze", link) or self:holds("speed", link)
end

function Hub:repaint(link)
	for _, name in ipairs(BREEZE_FIRST) do
		if self:holds(name, link) then
			local ok, answer = self:call(name, "repaint", link)
			return ok and answer
		end
	end
	return false
end

local function copy(list)
	if type(list) ~= "table" then
		return list
	end
	local out = {}
	for i, v in ipairs(list) do
		out[i] = v
	end
	return out
end

function Hub:set_pixels(list)
	self:call("speed", "set_pixels", copy(list))
	self:call("breeze", "set_pixels", copy(list))
end

function Hub:stop()
	self:call("speed", "stop")
	self:call("breeze", "stop")
end

function Hub:update(breeze_view, speed_view)
	self:call("speed", "update", speed_view) -- SL-D2: the chase lets go first
	self:call("breeze", "update", breeze_view)
end

function Hub:debug()
	local both = {}
	for link = ledhub.FIRST_LINK, ledhub.LAST_LINK do
		if self:holds("breeze", link) and self:holds("speed", link) then
			both[#both + 1] = link
		end
	end
	local out = { both = both }
	for _, name in ipairs(BREEZE_FIRST) do
		local ok, result = self:call(name, "debug")
		if not ok then
			result = { error = tostring(result) }
		end
		out[name] = result
	end
	return out
end

return ledhub
