-- fan/mode.lua: the three states of one motor (#121, docs/breeze-design.md
-- section 11, BF-D1 and the interface of 11.1).
--
--   stopped      fan_on false (whatever `wind` says: a stored Breeze)
--   fan mode     fan_on true and `wind` not true (false, or nil on a fan
--                without Breeze)
--   Breeze mode  fan_on true and `wind` true ("Breeze blows", BZ1)
--
-- The fan speed does not matter in Breeze mode. The main fan device shows fan
-- mode only (BF-D2): fan/fanproxy.lua reports its speed from mode.speed() and
-- decides "on" from mode.fan_on(), fan/links.lua lights the speed, Toggle and
-- Cycle links from fan mode and the Off link from mode.stopped(), and a
-- fan-mode command leaves Breeze through mode.exit() (BF-D3, BF-D4).
--
-- Pure functions of a state table of fan/model.lua's shape (shown() or
-- confirmed(): fan_on, speed, wind, ...); a nil state reads as nothing known.
-- Nothing here touches Director, the model or the log.
--
--   mode.fan_on(st)        true in fan mode, false stopped or in Breeze mode, nil while fan_on is unknown
--   mode.speed(st)         the fan-mode speed, 0 stopped or in Breeze mode, nil while unknown
--   mode.stopped(st)       fan_on == false
--   mode.breeze(st)        fan_on and wind both true
--   mode.exit(fields, st)  a copy of fields, with wind = false added while st.wind == true

local mode = {}

-- true in fan mode; false when the motor is stopped or blows Breeze; nil
-- while fan_on is not known (nothing is decided from an unknown state).
function mode.fan_on(st)
	local on = st and st.fan_on
	if on == true then
		return st.wind ~= true
	elseif on == false then
		return false
	end
	return nil
end

-- The speed the main fan device shows: the fan's speed in fan mode, 0 when
-- stopped or in Breeze mode, nil while the state or the fan-mode speed is not
-- known. The speed is handed back as the state holds it; fan/fanproxy.lua
-- checks the range.
function mode.speed(st)
	local on = mode.fan_on(st)
	if on == nil then
		return nil
	elseif on == false then
		return 0
	end
	return st.speed
end

-- The motor is stopped (a stored `wind` does not change that).
function mode.stopped(st)
	return st ~= nil and st.fan_on == false
end

-- Breeze mode: the motor turns and `wind` is true ("Breeze blows", BZ1).
function mode.breeze(st)
	return st ~= nil and st.fan_on == true and st.wind == true
end

-- A fan-mode command's fields, leaving Breeze: a copy of `fields` with
-- `wind = false` added while the state's `wind` is true (blowing, or stored
-- with the motor stopped), so the next start from anywhere is fan mode
-- (BF-D3, BF-D4). A fan without Breeze (`wind` nil) and a fan whose `wind`
-- is false get nothing added (BF71: `wind` is never sent to a fan without
-- it). A `wind` the caller put in `fields` itself is kept. `fields` is never
-- changed.
function mode.exit(fields, st)
	local out = {}
	for k, v in pairs(fields or {}) do
		out[k] = v
	end
	if st ~= nil and st.wind == true and out.wind == nil then
		out.wind = false
	end
	return out
end

return mode
