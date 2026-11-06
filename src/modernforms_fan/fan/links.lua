-- The fan's nine Button Links, 300 to 308 (Off, Speed 1 to 6, Toggle, Cycle),
-- their keypad LEDs, and the Keypad Links bookkeeping of all twelve links
-- (docs/v1-design.md sections 5.1, 5.3 and 9.8).
--
-- What a keypad sends over a link, as measured on the house (K6 and K7, 2026-11-04,
-- OS 3.4.3): a tap is DO_PUSH, then DO_CLICK 0.15 to 0.25 s later; a hold is
-- DO_PUSH, then DO_RELEASE and no click; a double tap is two push and click
-- pairs and no message of its own; every bind is followed, 3 to 4 ms later,
-- by REQUEST_BUTTON_COLORS, and a button whose request is not answered stays
-- dark. So:
--   * DO_PUSH acts at once (Control4's advice when hold and click mean the
--     same, KP 62_keypad_button_link_bindings). DO_CLICK acts only when no
--     DO_PUSH arrived on that link in the last 10 s (a keypad that sends
--     clicks alone); DO_RELEASE does nothing. No hold, no repeat. A double
--     tap is two pushes and acts twice (V12); the model coalesces them.
--   * The LED follows the shown state, wanted over in flight over confirmed
--     (V10), by MATCH_LED_STATE to the links whose lit state changed. It is
--     also answered whole, for one link, when a keypad binds it and when the
--     keypad asks with REQUEST_BUTTON_COLORS.
--   * Colours: none are sent unless Speed LED Colors is "per_speed" (V27); the
--     button then shows the colours set on the keypad itself.
--
-- Everything that touches Director is an argument (section 9.1):
--
--   links.new({
--       model = m,        -- fan/model.lua: shown() (section 9.5)
--       fan = fp,         -- fan/fanproxy.lua: off, speed, toggle, cycle (section 9.7)
--       on = fn(binding, command, handler),    -- handler(binding, params)
--       send = fn(binding, command, params, kind),
--                         -- C4:SendToProxy; kind is "COMMAND" for MATCH_LED_STATE and
--                         -- "NOTIFY" for BUTTON_COLORS, as common/device.lua sends them
--       now = fn() -> ms, -- a clock; only differences are used
--       timer = fn(ms, cb) -> object with :Cancel(),   -- the 5 s second look
--       bound = fn(link) -> C4:GetBoundConsumerDevices(C4:GetDeviceID(), link), a table or nil,
--       display = fn(device_id) -> C4:GetDeviceDisplayName(device_id),
--       list = fn(items),       -- writes the Keypad Links property
--       texts = fan/texts.lua (default: required when the list is first written),
--       log = log,              -- default common.log
--   })

local links = {}
links.__index = links

links.LINKS = {
	[300] = "Fan Off",
	[301] = "Fan Speed 1", [302] = "Fan Speed 2", [303] = "Fan Speed 3",
	[304] = "Fan Speed 4", [305] = "Fan Speed 5", [306] = "Fan Speed 6",
	[307] = "Fan Toggle",
	[308] = "Fan Cycle",
}

-- The light's links belong to common/device.lua; here they are bookkeeping only.
links.LIGHT_LINKS = { [200] = "Light Top", [201] = "Light Bottom", [202] = "Light Toggle" }

links.CLICK_WINDOW_MS = 10000 -- a click this soon after a push on its link is the same tap
links.SECOND_LOOK_MS = 5000 -- a link that answered nil at late init is read once more (ECC C15)
links.REREAD_MS = 3000 -- after an unbind whose keypad may have another button on the link (#92)

-- A keypad Director's table lists on a link, with no binding event for it yet:
-- it is bound there by a button (or buttons) not known by number.
local UNKNOWN = "?"

local SPEEDS = 6
local FAN_IDS = { 300, 301, 302, 303, 304, 305, 306, 307, 308 }
local ALL_IDS = { 200, 201, 202, 300, 301, 302, 303, 304, 305, 306, 307, 308 }

-- Parsing ------------------------------------------------------------------

local function whole(value, lo, hi)
	local n = tonumber(value)
	if n == nil or n ~= math.floor(n) or n < lo or n > hi then
		return nil
	end
	return n
end

-- "0000ff" from a 6-digit hex string, nil for anything else.
local function hex6(value)
	value = value ~= nil and tostring(value) or ""
	if value:match("^%x%x%x%x%x%x$") then
		return value:lower()
	end
	return nil
end

-- A Keypad Links row. Section 9.6 writes it as the field list { link_name,
-- keypad_name, device_id }, so it carries both the names and the positions.
local function row(link_name, keypad_name, device_id)
	return {
		link_name, keypad_name, device_id,
		link_name = link_name, keypad_name = keypad_name, device_id = device_id,
	}
end

local function sorted_keys(set)
	local keys = {}
	for key in pairs(set) do
		keys[#keys + 1] = key
	end
	table.sort(keys)
	return keys
end

-- The instance -----------------------------------------------------------------

function links.new(opts)
	assert(opts and opts.model and opts.fan and opts.on and opts.send and opts.now,
		"links.new needs model, fan, on, send and now")
	local self = setmetatable({
		model = opts.model,
		fan = opts.fan,
		send = opts.send,
		now = opts.now,
		timer = opts.timer,
		bound = opts.bound,
		display = opts.display,
		list = opts.list,
		texts = opts.texts,
		log = opts.log or require("common.log"),
		led = {}, -- [link] = the STATE last sent
		led_speed = {}, -- [link] = the speed whose colours went with that STATE (per speed only)
		also = {}, -- [speed] = the one other speed that lights that speed's link (V26)
		mode = "keypad", -- or "per_speed" (V27)
		colors = {}, -- [speed] = "rrggbb"
		off_color = "000000",
		last_push = {}, -- [link] = the clock of its last DO_PUSH
		consumers = {}, -- [link] = { [device_id] = name } once read; nil while unknown
		buttons = {}, -- [link] = { [device_id] = { [its binding id, or UNKNOWN] = true } } (#92)
		rereads = {}, -- [link] = the pending timer of an unbind's second read (#92)
		touched = {}, -- [link] = true once OnBindingChanged told something about it
		published = nil, -- the Keypad Links items last written, as one string
		second_look = nil, -- the pending timer
	}, links)

	for _, link in ipairs(FAN_IDS) do
		opts.on(link, "DO_PUSH", function() self:push(link) end)
		opts.on(link, "DO_CLICK", function() self:click(link) end)
		opts.on(link, "DO_RELEASE", function() self:release(link) end)
		opts.on(link, "REQUEST_BUTTON_COLORS", function() self:answer(link) end)
		opts.on(link, "SET_BUTTON_COLOR", function() self:set_button_color(link) end)
	end
	return self
end

-- Presses (section 5.1) -------------------------------------------------------------

function links:push(link)
	self.last_push[link] = self.now()
	self:act(link, "push")
end

function links:click(link)
	local at = self.last_push[link]
	if at ~= nil then
		local age = self.now() - at
		-- A clock that went backwards says nothing about this click.
		if age >= 0 and age < links.CLICK_WINDOW_MS then
			self.log.debug("link %d: click %d ms after a push; that push acted", link, age)
			return
		end
	end
	self:act(link, "click")
end

function links:release(link)
	self.log.debug("link %d: release; nothing to do", link)
end

-- KP 62_keypad_button_link_bindings documents SET_BUTTON_COLOR without saying
-- who sends it or what its button id means on a fan link; the fan links'
-- colours are the keypad's own or Speed LED Colors', so it is ignored.
function links:set_button_color(link)
	self.log.debug("link %d: SET_BUTTON_COLOR ignored; the fan links take their colours elsewhere", link)
end

-- The link's intent. The Cycle link stops at 6, as the proxy's does (V11, #77).
function links:act(link, how)
	local ok, why
	if link == 300 then
		ok, why = self.fan:off()
	elseif link == 307 then
		ok, why = self.fan:toggle()
	elseif link == 308 then
		ok, why = self.fan:cycle(1)
	else
		ok, why = self.fan:speed(link - 300)
	end
	if ok == false then
		self.log.debug("link %d (%s): %s refused: %s", link, links.LINKS[link], how, tostring(why))
	end
end

-- LEDs (sections 5.1 and 4.5) ---------------------------------------------------------

-- Whether a link is lit by a shown state, and for a lit speed link the speed
-- (it names the colour). nil: not known, and nothing is sent then.
function links:lit(link, shown)
	local on, speed = shown.fan_on, shown.speed
	if on == nil then
		return nil
	elseif link == 300 then
		return on == false
	elseif link == 307 or link == 308 then
		return on == true
	elseif on == false then
		return false
	elseif speed == nil then
		return nil
	end
	local own = link - 300
	local lit = speed == own or (self.also[own] ~= nil and speed == self.also[own])
	return lit, lit and speed or nil
end

-- A speed link lit at `speed` has a colour of its own only with Per speed
-- and a colour set for that speed; the Off, Toggle and Cycle links never do.
function links:colour_for(link, speed)
	if self.mode ~= "per_speed" or speed == nil or link < 301 or link > 306 then
		return nil
	end
	return self.colors[speed]
end

function links:deliver(link, command, params, kind)
	local ok, err = pcall(self.send, link, command, params, kind)
	if not ok then
		self.log.error("link %d %s failed: %s", link, command, tostring(err))
	end
	return ok
end

function links:send_led(link, lit)
	self.log.debug("-> link %d MATCH_LED_STATE %s", link, tostring(lit))
	if self:deliver(link, "MATCH_LED_STATE", { STATE = lit }, "COMMAND") then
		self.led[link] = lit
	end
end

function links:send_colors(link, colour)
	self.log.debug("-> link %d BUTTON_COLORS on %s off %s", link, colour, self.off_color)
	self:deliver(link, "BUTTON_COLORS", { ON_COLOR = colour, OFF_COLOR = self.off_color, CURRENT_COLOR = colour },
		"NOTIFY")
end

-- One link from a shown state: when its lit state changed (or, with Per
-- speed, the colour it is lit in), or always with `force`. Colours go just
-- before the state. true when something was sent.
function links:push_led(link, shown, force)
	local lit, speed = self:lit(link, shown)
	if lit == nil then
		return false
	end
	local colour = lit and self:colour_for(link, speed) or nil
	local colour_speed = colour and speed or nil
	if not force and lit == self.led[link] and colour_speed == self.led_speed[link] then
		return false
	end
	if colour then
		self:send_colors(link, colour)
	end
	self:send_led(link, lit)
	self.led_speed[link] = colour_speed
	return true
end

-- The model's listener.shown: the links whose lit state changed.
function links:shown(shown)
	for _, link in ipairs(FAN_IDS) do
		self:push_led(link, shown or {}, false)
	end
end

-- All nine, whether they changed or not (the first contact).
function links:refresh()
	local shown = self.model:shown() or {}
	for _, link in ipairs(FAN_IDS) do
		self:push_led(link, shown, true)
	end
end

-- One link, whole: a keypad just bound it, or asked with
-- REQUEST_BUTTON_COLORS (hardware K6: without an answer the button stays
-- dark). While the state is unknown the answer is dark (ECC C14).
function links:answer(link)
	if self:push_led(link, self.model:shown() or {}, true) then
		return
	end
	self:send_led(link, false)
	self.led_speed[link] = nil
end

-- Speed N Link Also Lit At (V26): speed 1..6, also 1..6 or nil. The link's
-- own speed as the other one is no other speed. The link's LED is sent again
-- at once (nothing while the state is unknown).
function links:set_also(speed, also)
	local own = whole(speed, 1, SPEEDS)
	local other = whole(also, 1, SPEEDS)
	if own == nil or (also ~= nil and other == nil) then
		self.log.warn("Speed %s Link Also Lit At %s ignored: speeds are 1 to %d", tostring(speed), tostring(also), SPEEDS)
		return
	end
	if other == own then
		other = nil
	end
	self.also[own] = other
	self:push_led(300 + own, self.model:shown() or {}, true)
end

-- Speed LED Colors (V27): mode "keypad" (the default: no colours sent) or
-- "per_speed", colors[1..6] and off as "rrggbb". With Per speed the links lit
-- now are sent their colours again. Going back to "keypad" sends nothing: the
-- keypad keeps the last colours it took until the owner sets its own.
function links:set_colors(mode, colors, off)
	if mode ~= "keypad" and mode ~= "per_speed" then
		self.log.warn("Speed LED Colors %s ignored: keypad or per_speed", tostring(mode))
		return
	end
	self.mode = mode
	self.colors = {}
	for speed = 1, SPEEDS do
		local given = colors and colors[speed]
		self.colors[speed] = hex6(given)
		if given ~= nil and self.colors[speed] == nil then
			self.log.warn("Speed %d LED Color %s is not a 6-digit hex colour; ignored", speed, tostring(given))
		end
	end
	self.off_color = hex6(off) or "000000"
	if mode == "per_speed" then
		local shown = self.model:shown() or {}
		for own = 1, SPEEDS do
			if self:lit(300 + own, shown) then
				self:push_led(300 + own, shown, true)
			end
		end
	end
end

-- Keypad Links (section 5.3) -----------------------------------------------------------

-- { [device_id] = name } of the keypads bound to a link, or nil when the
-- lookup failed or answered nothing (Director answers nil for a link with
-- nothing bound and may answer nil once for a bound one, ECC C15).
function links:read_bound(link)
	if not self.bound then
		return nil
	end
	local ok, result = pcall(self.bound, link)
	if not ok then
		self.log.warn("link %d: the bound keypads could not be read: %s", link, tostring(result))
		return nil
	end
	if type(result) ~= "table" then
		return nil
	end
	local set = {}
	for id, name in pairs(result) do
		local device_id = tonumber(id)
		if device_id then
			set[device_id] = name ~= nil and tostring(name) or ""
		end
	end
	return set
end

-- The keypad's name as Composer shows it (C4:GetDeviceDisplayName), else the
-- name the binding table gave, else "": texts.keypad_links words a row
-- without a name itself.
function links:keypad_name(device_id, fallback)
	if self.display then
		local ok, name = pcall(self.display, device_id)
		if ok and name ~= nil and name ~= "" then
			return tostring(name)
		end
	end
	return fallback or ""
end

-- One row per bound keypad, in link order and then device order.
function links:rows()
	local rows = {}
	for _, link in ipairs(ALL_IDS) do
		local set = self.consumers[link]
		if set then
			local name = links.LINKS[link] or links.LIGHT_LINKS[link]
			for _, device_id in ipairs(sorted_keys(set)) do
				rows[#rows + 1] = row(name, self:keypad_name(device_id, set[device_id]), device_id)
			end
		end
	end
	return rows
end

function links:texts_module()
	if self.texts == nil then
		local ok, module = pcall(require, "fan.texts")
		if not ok then
			self.log.warn("Keypad Links: fan.texts could not be loaded: %s", tostring(module))
			return nil
		end
		self.texts = module
	end
	return self.texts
end

-- Writes the Keypad Links property when its items changed.
function links:publish()
	if not self.list then
		return
	end
	local texts = self:texts_module()
	if not texts then
		return
	end
	local ok, items = pcall(texts.keypad_links, self:rows())
	if not ok or type(items) ~= "table" then
		self.log.warn("Keypad Links: the text could not be built: %s", tostring(items))
		return
	end
	local parts = {}
	for i, item in ipairs(items) do
		parts[i] = tostring(item)
	end
	local key = table.concat(parts, "\n")
	if key == self.published then
		return
	end
	local wrote, err = pcall(self.list, items)
	if wrote then
		self.published = key
	else
		self.log.error("Keypad Links could not be written: %s", tostring(err))
	end
end

-- OnBindingChanged for any of the twelve links. The event names the keypad;
-- Director's own table may still lag behind it (a Bind is asynchronous), so
-- the table says who else is bound and the event settles the one it names.
-- A fan link that was bound is answered at once (K6: the button is dark
-- until it is).
function links:binding_changed(id, bound, other_device, other_binding)
	local link = tonumber(id)
	local name = links.LINKS[link] or links.LIGHT_LINKS[link]
	if not name then
		self.log.debug("OnBindingChanged on binding %s: not one of the twelve links", tostring(id))
		return
	end
	bound = bound and true or false
	local device_id = tonumber(other_device)
	local set = self:read_bound(link) or {}
	-- A keypad is one device whatever number of its buttons a link has, so the
	-- buttons are counted per keypad: an unbind takes the keypad off the link
	-- only with its last button (#92).
	local before = self.consumers[link] and self.consumers[link][device_id]
	local buttons = self:merge(link, set)
	if device_id and device_id ~= 0 then
		local mine = {}
		for key in pairs(buttons[device_id] or {}) do
			mine[key] = true
		end
		local button = tonumber(other_binding)
		if button then
			mine[button] = bound or nil
		elseif bound then
			mine[UNKNOWN] = true
		else
			mine = {} -- an unbind that names no button is believed for the keypad
		end
		local left, unknown_only = next(mine) ~= nil, true
		for key in pairs(mine) do
			if key ~= UNKNOWN then
				unknown_only = false
			end
		end
		if not bound and left and unknown_only and not self.timer then
			-- With no timer for a second read, the event is believed over
			-- Director's table, which may still lag behind it.
			left = false
		end
		if left then
			buttons[device_id] = mine
			set[device_id] = set[device_id] or before or ""
			if not bound and unknown_only then
				-- Another button of this keypad may still be bound here, or the
				-- table lags behind the unbind: the next read settles it.
				self:reread_later(link)
			end
		else
			buttons[device_id], set[device_id] = nil, nil
		end
	end
	self.buttons[link] = buttons
	self.consumers[link], self.touched[link] = set, true
	self.log.debug("%s: keypad %s %s (its binding %s)", name, tostring(device_id), bound and "bound" or "unbound",
		tostring(other_binding))
	self:publish()
	if bound and links.LINKS[link] then
		self:answer(link)
	end
end

-- Director's table for a link, with what the events told: a keypad in the
-- table keeps the buttons the events named (else one unknown button), and a
-- keypad an event bound a named button of stays though the table lags behind,
-- until its own unbind. Adds those keypads to set; returns the buttons.
function links:merge(link, set)
	local known = self.buttons[link] or {}
	local before = self.consumers[link] or {}
	local buttons = {}
	for dev in pairs(set) do
		buttons[dev] = known[dev] or { [UNKNOWN] = true }
	end
	for dev, keys in pairs(known) do
		if not buttons[dev] then
			for key in pairs(keys) do
				if key ~= UNKNOWN then
					buttons[dev], set[dev] = keys, before[dev] or ""
					break
				end
			end
		end
	end
	return buttons
end

-- An unbind left a keypad whose other buttons on the link are not known: the
-- link is read again REREAD_MS later, and Director's table is believed then.
function links:reread_later(link)
	local old = self.rereads[link]
	if old and old.Cancel then
		pcall(function() old:Cancel() end)
	end
	local ok, t = pcall(self.timer, links.REREAD_MS, function()
		self.rereads[link] = nil
		local set = self:read_bound(link)
		if not set then
			return
		end
		self.buttons[link] = self:merge(link, set)
		self.consumers[link] = set
		self:publish()
	end)
	if ok then
		self.rereads[link] = t
	else
		self.log.warn("Keypad Links: link %d could not be read again: %s", link, tostring(t))
	end
end

function links:cancel_second_look()
	local t = self.second_look
	self.second_look = nil
	if t and t.Cancel then
		pcall(function() t:Cancel() end)
	end
end

-- The second look: a link that answered nil twice, five seconds apart, has
-- nothing bound. A link an event has told about since is not read again.
function links:look_again(unknown)
	for _, link in ipairs(unknown) do
		if not self.touched[link] then
			self.consumers[link] = self:read_bound(link) or {}
		end
	end
	self:publish()
end

-- OnDriverLateInit: every link read once; the ones that answered nil are
-- read again 5 s later (one nil is "unknown", ECC C15).
function links:late_init()
	self:cancel_second_look()
	local unknown = {}
	for _, link in ipairs(ALL_IDS) do
		local set = self:read_bound(link)
		if set then
			self.consumers[link] = set
		else
			unknown[#unknown + 1] = link
		end
	end
	self:publish()
	if #unknown > 0 and self.timer then
		local ok, t = pcall(self.timer, links.SECOND_LOOK_MS, function()
			self.second_look = nil
			self:look_again(unknown)
		end)
		if ok then
			self.second_look = t
		else
			self.log.warn("Keypad Links: the second look could not be scheduled: %s", tostring(t))
		end
	end
end

function links:stop()
	self:cancel_second_look()
	for link, t in pairs(self.rereads) do
		self.rereads[link] = nil
		if t and t.Cancel then
			pcall(function() t:Cancel() end)
		end
	end
end

-- Dev State (section 12): the LED each fan link was last sent (nil: never)
-- and how many of the twelve links have a keypad bound.
function links:debug()
	local leds, count = {}, 0
	for _, link in ipairs(FAN_IDS) do
		leds[link] = self.led[link]
	end
	for _, link in ipairs(ALL_IDS) do
		if self.consumers[link] and next(self.consumers[link]) ~= nil then
			count = count + 1
		end
	end
	return { leds = leds, bound = count }
end

return links
