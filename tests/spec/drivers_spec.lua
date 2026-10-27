-- Every driver this project ships, one per src/*/driver.xml (the list
-- tools/build.sh builds): what Composer, the packager and the build read from
-- its driver.xml and Documentation tab, and that it loads, starts, stops and
-- starts again on the fake runtime. A second driver joins these checks by
-- existing; what one driver does is its own spec's (fan_driver_spec.lua).

local lfs = require("lfs")
local fake = require("helpers.fake_c4")
local log = require("common.log")

local function read(path)
	local file = assert(io.open(path))
	local text = file:read("*a")
	file:close()
	return text
end

-- The drivers: every directory under src/ holding a driver.xml, sorted.
local function drivers()
	local out = {}
	for name in lfs.dir("src") do
		if name:sub(1, 1) ~= "." and lfs.attributes("src/" .. name .. "/driver.xml", "mode") == "file" then
			out[#out + 1] = name
		end
	end
	table.sort(out)
	return out
end

-- The file without its comments, which may quote element names.
local function without_comments(xml)
	return (xml:gsub("<!%-%-.-%-%->", ""))
end

local function field(body, tag)
	return body and body:match("<" .. tag .. ">(.-)</" .. tag .. ">")
end

local function each(xml, tag)
	local out = {}
	for body in xml:gmatch("<" .. tag .. ">(.-)</" .. tag .. ">") do
		out[#out + 1] = body
	end
	return out
end

-- The attributes of the first <tag .../> or <tag ...>, as a table.
local function attributes(xml, tag)
	local raw = xml:match("<" .. tag .. "%s([^>]-)/?>")
	if not raw then
		return nil
	end
	local out = {}
	for k, v in raw:gmatch('([%w_]+)%s*=%s*"([^"]*)"') do
		out[k] = v
	end
	return out
end

-- name -> { type, default, readonly, items } for every <property>, and the
-- names in file order.
local function properties(xml)
	local by_name, names = {}, {}
	for _, body in ipairs(each(without_comments(xml), "property")) do
		local name = field(body, "name")
		names[#names + 1] = name
		local items = field(body, "items") and each(field(body, "items"), "item") or nil
		by_name[name] = { type = field(body, "type"), default = field(body, "default"),
			readonly = field(body, "readonly"), items = items }
	end
	return by_name, names
end

-- What tools/build.sh makes of a driver.xml for a release build: every line
-- from one holding "<!-- DEV-ONLY BEGIN" through one holding
-- "<!-- DEV-ONLY END -->" dropped (its awk rule).
local function release_xml(xml)
	local out, skip = {}, false
	for line in (xml .. "\n"):gmatch("(.-)\n") do
		if line:find("<!-- DEV-ONLY BEGIN", 1, true) then skip = true end
		if not skip then out[#out + 1] = line end
		if line:find("<!-- DEV-ONLY END -->", 1, true) then skip = false end
	end
	return table.concat(out, "\n")
end

local function count(text, plain)
	local n, from = 0, 1
	while true do
		local at = text:find(plain, from, true)
		if not at then return n end
		n, from = n + 1, at + #plain
	end
end

-- Every log line from here on.
local function capture_log()
	local lines = {}
	log.sink = function(line) lines[#lines + 1] = line end
	return lines
end

describe("every driver (src/*/driver.xml)", function()
	before_each(function() log.sink = function() end end)
	after_each(function()
		log.set_debug(false)
		log.set_prefix(nil)
	end)

	it("includes the fan driver, so the checks below run at all", function()
		local list = drivers()
		assert.truthy(#list >= 1)
		local found = false
		for _, name in ipairs(list) do found = found or name == "modernforms_fan" end
		assert.is_true(found, table.concat(list, ", "))
	end)

	it("gives every driver its own Composer name", function()
		local seen = {}
		for _, driver in ipairs(drivers()) do
			local name = field(without_comments(read("src/" .. driver .. "/driver.xml")), "name")
			assert.is_nil(seen[name], name .. ": also the name of " .. tostring(seen[name]))
			seen[name] = driver
		end
	end)

	for _, driver in ipairs(drivers()) do
		describe(driver, function()
			local dir = "src/" .. driver .. "/"
			local xml = read(dir .. "driver.xml")
			local bare = without_comments(xml)

			it("has the header Composer and the packager read", function()
				assert.truthy(bare:match("^%s*<devicedata>"), "the root element is devicedata")
				assert.truthy(bare:match("</devicedata>%s*$"))
				assert.equal(1, count(bare, "<devicedata>"))
				local copyright = field(bare, "copyright")
				assert.truthy(copyright:find("Apache License, Version 2.0", 1, true), copyright)
				assert.truthy(copyright:find("Not affiliated with", 1, true), copyright)
				assert.equal("Cory Fair", field(bare, "creator"))
				for _, tag in ipairs({ "name", "manufacturer", "model", "controlmethod" }) do
					assert.truthy((field(bare, tag) or ""):match("%S"), tag)
				end
				for _, tag in ipairs({ "created", "modified" }) do
					assert.truthy((field(bare, tag) or ""):match("^%d%d/%d%d/%d%d%d%d %d%d?:%d%d"), tag)
				end
				-- The packager refuses an empty <version>; tools/build.sh stamps it.
				assert.truthy((field(bare, "version") or ""):match("^%d+$"), "version")
				assert.equal("lua_gen", field(bare, "control"))
				assert.equal("DriverWorks", field(bare, "driver"))
				assert.truthy((field(bare, "minimum_os_version") or ""):match("^%d+%.%d+%.%d+$"), "minimum_os_version")
			end)

			it("runs driver.lua under LuaJIT and shows www/documentation.html with the changelog marker", function()
				local script = attributes(bare, "script")
				assert.same({ jit = "1", file = "driver.lua" }, script)
				assert.equal("file", lfs.attributes(dir .. "driver.lua", "mode"))
				assert.same({ file = "www/documentation.html" }, attributes(bare, "documentation"))
				local doc = read(dir .. "www/documentation.html")
				-- tools/build.sh replaces exactly one such line with the changelog.
				local markers = 0
				for line in (doc .. "\n"):gmatch("(.-)\r?\n") do
					if line == "<!-- CHANGELOG -->" then markers = markers + 1 end
				end
				assert.equal(1, markers)
				assert.truthy(doc:find(field(bare, "name"), 1, true), "the manual names its driver")
				assert.truthy(doc:find("Apache License, Version 2.0", 1, true))
				assert.truthy(doc:find("not affiliated with", 1, true))
			end)

			it("declares Driver Version and Debug Mode, which every install reads back", function()
				local props = properties(xml)
				assert.same({ type = "STRING", default = "", readonly = "true" }, props["Driver Version"])
				assert.same({ type = "LIST", default = "Off", readonly = "false", items = { "Off", "On" } },
					props["Debug Mode"])
			end)

			it("declares each property once, with a type, and a LIST's default among its items", function()
				local props, names = properties(xml)
				local seen = {}
				for _, name in ipairs(names) do
					assert.truthy(name and name:match("%S"), "a property without a name")
					assert.is_nil(seen[name], name .. " declared twice")
					seen[name] = true
					local p = props[name]
					assert.truthy((p.type or ""):match("^[A-Z_]+$"), name .. ": type " .. tostring(p.type))
					if p.type == "LIST" then
						assert.truthy(p.items and #p.items > 0, name .. ": a LIST without items")
						local found = false
						for _, item in ipairs(p.items) do found = found or item == p.default end
						assert.is_true(found, name .. ": default " .. tostring(p.default) .. " is no item")
					end
					assert.truthy(p.readonly == nil or p.readonly == "true" or p.readonly == "false", name .. ": readonly")
				end
			end)

			it("pairs its DEV-ONLY markers, and its release build is complete without them", function()
				local order = {}
				for kind in xml:gmatch("<!%-%- DEV%-ONLY (%u+)") do order[#order + 1] = kind end
				for i, kind in ipairs(order) do
					assert.equal(i % 2 == 1 and "BEGIN" or "END", kind, "DEV-ONLY markers alternate, BEGIN first")
				end
				assert.equal(0, #order % 2, "every DEV-ONLY BEGIN has its END")
				local release = release_xml(xml)
				assert.is_nil(release:find("DEV-ONLY", 1, true))
				local props = properties(release)
				assert.truthy(props["Driver Version"])
				assert.truthy(props["Debug Mode"])
				assert.is_nil(props["Dev Server"], "the dev loop's row is in a DEV-ONLY block")
			end)

			it("names its proxy consistently: a combo driver's one proxy is the driver itself", function()
				local proxies = {}
				for attrs, name in bare:gmatch("<proxy%s*([^>]*)>(.-)</proxy>") do
					proxies[#proxies + 1] = { attrs = attrs, name = name }
				end
				assert.truthy(#proxies >= 1, "a <proxies> entry, the driver's own for a combo driver")
				if field(bare, "combo") == "true" then
					assert.equal(1, #proxies)
					assert.equal(driver, proxies[1].name)
					assert.truthy(proxies[1].attrs:find('name="' .. field(bare, "name") .. '"', 1, true))
				else
					for _, proxy in ipairs(proxies) do
						assert.truthy(proxy.attrs:find('proxybindingid="%d+"'), proxy.name .. ": a proxybindingid")
					end
				end
			end)

			it("loads, starts and stops as Director runs it, logging no error", function()
				local lines = capture_log()
				local env, c4 = fake.load_driver(driver, {})
				assert.has_no.errors(function()
					if env.OnDriverInit then env.OnDriverInit("DIT_ADDING") end
					env.OnDriverLateInit("DIT_ADDING")
				end)
				assert.equal("1", env.Properties["Driver Version"])
				for _, line in ipairs(lines) do
					assert.is_nil(line:find("^%[ERROR%]"), line)
				end
				env.Properties["Debug Mode"] = "On"
				env.OnPropertyChanged("Debug Mode")
				assert.is_true(log.enabled("debug"))
				env.Properties["Debug Mode"] = "Off"
				env.OnPropertyChanged("Debug Mode")
				assert.is_false(log.enabled("debug"))
				-- The dev loop's reload runs OnDriverDestroyed before the new
				-- code: a timer left armed would run beside the new one's.
				c4.config_info.version = ""
				env.OnDriverLateInit("DIT_STARTUP")
				env.OnDriverDestroyed("DIT_UPDATING")
				assert.same({}, c4.active_timers())
			end)

			it("starts again in the same Lua state, as the dev loop's reload runs it", function()
				local env, c4 = fake.load_driver(driver, {})
				env.OnDriverInit("DIT_STARTUP")
				env.OnDriverLateInit("DIT_STARTUP")
				-- The reload: OnDriverDestroyed, the driver's modules cleared
				-- (common.log kept here so the spec stays quiet), driver.lua
				-- run again in the same environment, then both inits.
				env.OnDriverDestroyed("DIT_UPDATING")
				for name in pairs(package.loaded) do
					if name:match("^common%.") and name ~= "common.log" and name ~= "common.devloop" then
						package.loaded[name] = nil
					end
				end
				local chunk = assert(loadfile(dir .. "driver.lua"))
				setfenv(chunk, env)
				assert.has_no.errors(function()
					chunk()
					env.OnDriverInit("DIT_UPDATING")
					env.OnDriverLateInit("DIT_UPDATING")
				end)
				c4.config_info.version = "2"
				env.OnDriverLateInit("DIT_UPDATING")
				assert.equal("2", env.Properties["Driver Version"])
				env.Properties["Debug Mode"] = "On"
				env.OnPropertyChanged("Debug Mode")
				assert.is_true(log.enabled("debug"), "the new code's handlers answer")
				env.OnDriverDestroyed("DIT_UPDATING")
				assert.same({}, c4.active_timers())
			end)
		end)
	end
end)
