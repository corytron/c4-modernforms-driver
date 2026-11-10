-- `luacheck -j N` without LuaLanes (#183): luacheck checks files in parallel through one function,
-- luacheck.multithreading.pmap, which it takes from LuaLanes threads when that C module is
-- installed. This file supplies the same function with processes instead, so nothing needs
-- installing. Load it through the Lua interpreter's LUA_INIT, which runs before luacheck does:
--
--   LUA_INIT=@tools/luacheck_jobs.lua luacheck -j 32 src tests tools
--
-- Everything else is luacheck's own: options, configuration, file order, formatting, exit status.
-- pmap maps luacheck.get_report (source text -> report) over the files' sources; this one splits
-- the sources across up to `jobs` child interpreters (the biggest first, each to the least loaded
-- child), which return each report in luacheck's cache format (luacheck.serializer), and puts the
-- reports back in their places. A report that does not come back is computed here instead, so the
-- result is the serial one either way. Without -j, luacheck uses JOBS when set, else every core
-- (nproc). Run as a script, the file is the child: `lua luacheck_jobs.lua --worker IN OUT`.
local WORKER_FLAG = "--luacheck-jobs-worker"

local function shell_quote(text)
	return "'" .. text:gsub("'", "'\\''") .. "'"
end

local function write_file(path, text)
	local file = assert(io.open(path, "wb"))
	assert(file:write(text))
	assert(file:close())
end

-- A chunk that returns the given strings, keyed by their numbers.
local function dump_strings(items)
	local out = { "return {" }
	for key, text in pairs(items) do
		out[#out + 1] = string.format("[%d]=%q,", key, text)
	end
	out[#out + 1] = "}\n"
	return table.concat(out)
end

local function load_strings(path)
	local chunk = loadfile(path)
	if not chunk then
		return nil
	end
	setfenv(chunk, {})
	local ok, items = pcall(chunk)
	if ok and type(items) == "table" then
		return items
	end
	return nil
end

local function core_count()
	local jobs = tonumber(os.getenv("JOBS") or "")
	if jobs and jobs >= 1 then
		return math.floor(jobs)
	end
	for _, command in ipairs({ "nproc 2>/dev/null", "getconf _NPROCESSORS_ONLN 2>/dev/null" }) do
		local pipe = io.popen(command)
		if pipe then
			local count = tonumber((pipe:read("*a") or ""):match("%d+"))
			pipe:close()
			if count and count >= 1 then
				return count
			end
		end
	end
	return 1
end

-- The child: compute the report of every source in IN, write them to OUT.
if arg and arg[1] == WORKER_FLAG then
	local luacheck = require("luacheck")
	local serializer = require("luacheck.serializer")
	local sources = assert(load_strings(arg[2]), "luacheck_jobs: cannot read " .. tostring(arg[2]))
	local reports = {}
	for index, source in pairs(sources) do
		local ok, report = pcall(luacheck.get_report, source)
		if ok then
			reports[index] = serializer.dump_check_result(report)
		end
	end
	write_file(arg[3], dump_strings(reports))
	return
end

package.preload["luacheck.multithreading"] = function()
	-- luacheck --version reads lanes.ABOUT.version.
	local multithreading = {
		has_lanes = true,
		default_jobs = core_count(),
		lanes = { ABOUT = { version = "not used (tools/luacheck_jobs.lua checks in processes)" } },
	}

	-- The command that starts a child interpreter with this one's module paths.
	local function child_command()
		local first = 0
		while arg and arg[first - 1] do
			first = first - 1
		end
		local interpreter = arg and arg[first] or "lua"
		local paths = string.format("package.path=%q;package.cpath=%q", package.path, package.cpath)
		local script = debug.getinfo(1, "S").source:gsub("^@", "")
		return "LUA_INIT= " .. shell_quote(interpreter) .. " -e " .. shell_quote(paths) .. " "
			.. shell_quote(script) .. " " .. WORKER_FLAG
	end

	function multithreading.pmap(func, array, jobs)
		local utils = require("luacheck.utils")
		jobs = math.min(jobs or multithreading.default_jobs, #array)
		if jobs < 2 or func ~= require("luacheck").get_report then
			return utils.map(func, array)
		end

		-- The biggest sources first, each to the child with the fewest bytes so far.
		local order = {}
		for index = 1, #array do
			order[index] = index
		end
		table.sort(order, function(a, b)
			if #array[a] ~= #array[b] then
				return #array[a] > #array[b]
			end
			return a < b
		end)
		local shares, loads = {}, {}
		for child = 1, jobs do
			shares[child], loads[child] = {}, 0
		end
		for _, index in ipairs(order) do
			local lightest = 1
			for child = 2, jobs do
				if loads[child] < loads[lightest] then
					lightest = child
				end
			end
			shares[lightest][index] = array[index]
			loads[lightest] = loads[lightest] + #array[index]
		end

		-- Start every child, then wait for each; they run at the same time.
		local command = child_command()
		local children = {}
		for child = 1, jobs do
			local input, output = os.tmpname(), os.tmpname()
			write_file(input, dump_strings(shares[child]))
			local pipe = io.popen(command .. " " .. shell_quote(input) .. " " .. shell_quote(output))
			children[child] = { input = input, output = output, pipe = pipe }
		end
		local serializer = require("luacheck.serializer")
		local results = {}
		for child = 1, jobs do
			local state = children[child]
			if state.pipe then
				state.pipe:read("*a")
				state.pipe:close()
			end
			local reports = load_strings(state.output) or {}
			for index in pairs(shares[child]) do
				local dumped = reports[index]
				results[index] = dumped and serializer.load_check_result(dumped)
			end
			os.remove(state.input)
			os.remove(state.output)
		end
		for index = 1, #array do
			if results[index] == nil then
				results[index] = func(array[index])
			end
		end
		return results
	end

	return multithreading
end
