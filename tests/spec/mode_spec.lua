-- fan.mode: the three states of one motor (docs/breeze-design.md section 11,
-- BF-D1 and the interface of 11.1): stopped, fan mode and Breeze mode, the
-- speed the main fan device shows, and the fields a fan-mode command adds to
-- leave Breeze (BF-D3, BF-D4). Pure functions, so plain tables are the whole
-- rig.

local mode = require("fan.mode")

-- Every state of the motor the model can show, by name.
local STATES = {
	unknown = {},
	stopped = { fan_on = false, speed = 3 },
	stopped_stored = { fan_on = false, speed = 3, wind = true }, -- the remote's power off during Breeze (BF98)
	stopped_clear = { fan_on = false, speed = 3, wind = false },
	fan_no_breeze = { fan_on = true, speed = 4 }, -- Gen 1/2, Gen 3 without Breeze: `wind` nil
	fan_mode = { fan_on = true, speed = 4, wind = false },
	breeze = { fan_on = true, speed = 4, wind = true, wind_speed = 2 },
	breeze_no_speed = { fan_on = true, wind = true },
	on_no_speed = { fan_on = true, wind = false },
	wind_only = { wind = true }, -- fan_on not known yet
}

describe("fan.mode", function()
	describe("fan_on (BF-D1, BF-D3: \"on\" means on in fan mode)", function()
		it("is true in fan mode, with `wind` false or with no `wind` at all", function()
			assert.is_true(mode.fan_on(STATES.fan_mode))
			assert.is_true(mode.fan_on(STATES.fan_no_breeze))
			assert.is_true(mode.fan_on(STATES.on_no_speed), "on without a speed is still fan mode")
		end)

		it("is false while Breeze blows: the main fan device is off then", function()
			assert.is_false(mode.fan_on(STATES.breeze))
			assert.is_false(mode.fan_on(STATES.breeze_no_speed))
		end)

		it("is false when the motor is stopped, whatever `wind` says", function()
			assert.is_false(mode.fan_on(STATES.stopped))
			assert.is_false(mode.fan_on(STATES.stopped_stored))
			assert.is_false(mode.fan_on(STATES.stopped_clear))
		end)

		it("is nil while fan_on is not known, even with `wind` known, and for no state at all", function()
			assert.is_nil(mode.fan_on(STATES.unknown))
			assert.is_nil(mode.fan_on(STATES.wind_only))
			assert.is_nil(mode.fan_on(nil))
		end)

		it("takes only true as `wind`: anything else is fan mode", function()
			assert.is_true(mode.fan_on({ fan_on = true, speed = 2, wind = "true" }))
			assert.is_true(mode.fan_on({ fan_on = true, speed = 2, wind = 1 }))
		end)
	end)

	describe("speed (BF-D2: the main fan device shows fan mode only)", function()
		it("is the fan's speed in fan mode", function()
			assert.equal(4, mode.speed(STATES.fan_mode))
			assert.equal(4, mode.speed(STATES.fan_no_breeze))
		end)

		it("is 0 in Breeze mode, whatever speed the fan reports (gusts never reach the main tile, BF76)", function()
			assert.equal(0, mode.speed(STATES.breeze))
			assert.equal(0, mode.speed(STATES.breeze_no_speed))
		end)

		it("is 0 when the motor is stopped, with or without a stored `wind`", function()
			assert.equal(0, mode.speed(STATES.stopped))
			assert.equal(0, mode.speed(STATES.stopped_stored))
			assert.equal(0, mode.speed(STATES.stopped_clear))
		end)

		it("is nil while the state is not known, and in fan mode while the speed is not", function()
			assert.is_nil(mode.speed(STATES.unknown))
			assert.is_nil(mode.speed(STATES.wind_only))
			assert.is_nil(mode.speed(nil))
			assert.is_nil(mode.speed(STATES.on_no_speed))
		end)

		it("hands the speed back as the state holds it: the range is the fan proxy's to check", function()
			assert.equal(9, mode.speed({ fan_on = true, speed = 9 }))
		end)
	end)

	describe("stopped and breeze", function()
		it("stopped is fan_on false, and only that", function()
			assert.is_true(mode.stopped(STATES.stopped))
			assert.is_true(mode.stopped(STATES.stopped_stored), "a stored `wind` does not turn the motor")
			assert.is_true(mode.stopped(STATES.stopped_clear))
			assert.is_false(mode.stopped(STATES.fan_mode))
			assert.is_false(mode.stopped(STATES.fan_no_breeze))
			assert.is_false(mode.stopped(STATES.breeze), "Breeze mode: the motor turns")
			assert.is_false(mode.stopped(STATES.unknown))
			assert.is_false(mode.stopped(STATES.wind_only))
			assert.is_false(mode.stopped(nil))
		end)

		it("breeze is fan_on and `wind` both true (BZ1), and only that", function()
			assert.is_true(mode.breeze(STATES.breeze))
			assert.is_true(mode.breeze(STATES.breeze_no_speed))
			assert.is_false(mode.breeze(STATES.stopped_stored), "a stored `wind` with the motor stopped is not Breeze")
			assert.is_false(mode.breeze(STATES.fan_mode))
			assert.is_false(mode.breeze(STATES.fan_no_breeze))
			assert.is_false(mode.breeze(STATES.stopped))
			assert.is_false(mode.breeze(STATES.unknown))
			assert.is_false(mode.breeze(STATES.wind_only))
			assert.is_false(mode.breeze(nil))
		end)

		it("every known state is exactly one of stopped, fan mode and Breeze mode (BF-D1)", function()
			for name, st in pairs(STATES) do
				if st.fan_on ~= nil then
					local count = 0
					for _, yes in ipairs({ mode.stopped(st), mode.fan_on(st) == true, mode.breeze(st) }) do
						if yes then
							count = count + 1
						end
					end
					assert.equal(1, count, name)
				end
			end
		end)
	end)

	describe("exit (BF-D3, BF-D4: a fan-mode command leaves Breeze)", function()
		it("adds wind = false while Breeze blows", function()
			assert.same({ fan_on = true, speed = 3, wind = false }, mode.exit({ fan_on = true, speed = 3 }, STATES.breeze))
			assert.same({ fan_on = false, wind = false }, mode.exit({ fan_on = false }, STATES.breeze))
		end)

		it("adds wind = false for a stored `wind` with the motor stopped, so the next start is fan mode (BF83, BF84)",
			function()
				assert.same({ fan_on = true, speed = 3, wind = false },
					mode.exit({ fan_on = true, speed = 3 }, STATES.stopped_stored))
				assert.same({ fan_on = false, wind = false }, mode.exit({ fan_on = false }, STATES.stopped_stored))
			end)

		it("adds nothing while `wind` is false (BF72)", function()
			assert.same({ fan_on = true, speed = 3 }, mode.exit({ fan_on = true, speed = 3 }, STATES.fan_mode))
			assert.same({ fan_on = false }, mode.exit({ fan_on = false }, STATES.stopped_clear))
		end)

		it("never adds `wind` for a fan without Breeze (BF71: `wind` nil)", function()
			assert.same({ fan_on = true, speed = 3 }, mode.exit({ fan_on = true, speed = 3 }, STATES.fan_no_breeze))
			assert.same({ fan_on = false }, mode.exit({ fan_on = false }, STATES.stopped))
			assert.same({ fan_on = false }, mode.exit({ fan_on = false }, STATES.unknown))
			assert.same({ fan_on = false }, mode.exit({ fan_on = false }, nil))
		end)

		it("reads `wind` alone: a `wind` known while fan_on is not still adds it", function()
			assert.same({ fan_on = true, speed = 3, wind = false },
				mode.exit({ fan_on = true, speed = 3 }, STATES.wind_only))
		end)

		it("takes only true as `wind`", function()
			assert.same({ fan_on = false }, mode.exit({ fan_on = false }, { fan_on = true, wind = "true" }))
		end)

		it("keeps a `wind` the caller put in the fields itself", function()
			assert.same({ wind = true, wind_speed = 2 }, mode.exit({ wind = true, wind_speed = 2 }, STATES.breeze))
			assert.same({ fan_on = false, wind = false }, mode.exit({ fan_on = false, wind = false }, STATES.breeze))
		end)

		it("hands back a copy and never changes the fields or the state it was given", function()
			local fields = { fan_on = true, speed = 3 }
			local st = { fan_on = true, speed = 4, wind = true }
			local out = mode.exit(fields, st)
			assert.same({ fan_on = true, speed = 3 }, fields)
			assert.same({ fan_on = true, speed = 4, wind = true }, st)
			assert.are_not.equal(fields, out)
			local same = mode.exit(fields, STATES.fan_mode)
			assert.are_not.equal(fields, same, "a copy even when nothing is added")
			assert.same(fields, same)
		end)

		it("takes no fields as none", function()
			assert.same({ wind = false }, mode.exit(nil, STATES.breeze))
			assert.same({}, mode.exit(nil, STATES.fan_mode))
		end)
	end)
end)
