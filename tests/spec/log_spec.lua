-- common.log: the levels Debug Mode switches, the prefix, the line format and
-- log.always, on a captured sink.

local log = require("common.log")

describe("common.log", function()
	local lines, real_sink

	before_each(function()
		lines = {}
		real_sink = log.sink
		log.sink = function(line) lines[#lines + 1] = line end
	end)

	after_each(function()
		log.sink = real_sink
		log.set_debug(false)
		log.set_prefix(nil)
	end)

	it("keeps warnings and errors by default and drops info and debug", function()
		log.set_debug(false)
		log.error("e %d", 1)
		log.warn("w %d", 2)
		log.info("i %d", 3)
		log.debug("d %d", 4)
		assert.same({ "[ERROR] e 1", "[WARN] w 2" }, lines)
		assert.is_true(log.enabled("error"))
		assert.is_true(log.enabled("warn"))
		assert.is_false(log.enabled("info"))
		assert.is_false(log.enabled("debug"))
	end)

	it("logs every level while Debug Mode is On, and stops again when it is Off", function()
		log.set_debug(true)
		log.info("i")
		log.debug("d")
		assert.same({ "[INFO] i", "[DEBUG] d" }, lines)
		assert.is_true(log.enabled("debug"))
		log.set_debug(false)
		log.debug("gone")
		assert.equal(2, #lines)
	end)

	it("puts the prefix after the level, and none when it is cleared", function()
		log.set_prefix("Modern Forms Fan")
		log.warn("hello")
		log.set_prefix(nil)
		log.warn("plain")
		assert.same({ "[WARN] Modern Forms Fan: hello", "[WARN] plain" }, lines)
	end)

	it("always logs, whatever the level, without a level tag", function()
		log.set_prefix("Modern Forms Fan")
		log.set_debug(false)
		log.always("Driver Version %s", "12")
		assert.same({ "Modern Forms Fan: Driver Version 12" }, lines)
	end)

	it("logs the format itself when the arguments do not fit it, and never raises", function()
		assert.has_no.errors(function()
			log.warn("value %d", "not a number")
			log.always("count %d", {})
			log.error("%s and %s", "only one")
		end)
		assert.same({ "[WARN] value %d", "count %d", "[ERROR] %s and %s" }, lines)
	end)

	it("sends every line to the sink in force when the line is logged", function()
		local first, second = {}, {}
		log.sink = function(line) first[#first + 1] = line end
		log.warn("one")
		log.sink = function(line) second[#second + 1] = line end
		log.warn("two")
		assert.same({ "[WARN] one" }, first)
		assert.same({ "[WARN] two" }, second)
	end)
end)
