-- The busted output handler of tools/busted_parallel.py (#183): busted runs one spec file per process,
-- in parallel, and this handler makes the pieces add up to what one `busted` run prints. It is
-- loaded with `busted -o tools/busted_parallel.lua` and wraps busted's own terminal handler (the
-- one busted would pick: utfTerminal on a terminal, else plainTerminal), so every character it
-- prints is printed by busted's code. BUSTED_PARALLEL_MODE says which part it plays:
--
--   discover  registers no file and writes the spec files busted would run, in busted's order (its
--             own discovery: roots, .busted pattern, sorted), one per line, to BUSTED_PARALLEL_DUMP;
--             a file that does not compile is listed too, its run reports the error
--   shard     runs its files and prints what busted prints while tests run (the status characters
--             and anything the tests print), then writes the summary's inputs (counts, duration,
--             pendings, failures and errors) to BUSTED_PARALLEL_DUMP instead of printing them
--   render    runs an empty spec file, then at the end of the suite reads from stdin a duration (in
--             seconds) and the shards' dump files, one a line in file order, and lets busted's
--             handler print the summary of all of them, as one serial run would
--
-- BUSTED_PARALLEL_OUTPUT names the wrapped handler (plainTerminal or utfTerminal).
local mode = os.getenv("BUSTED_PARALLEL_MODE")
local inner_name = os.getenv("BUSTED_PARALLEL_OUTPUT") or "plainTerminal"
local dump_path = os.getenv("BUSTED_PARALLEL_DUMP")

local stdio = io

-- A Lua table constructor for a value made of strings, numbers, booleans and tables (anything else,
-- and a table met again inside itself, becomes nil).
local function serialize(value, out, seen)
	local kind = type(value)
	if kind == "string" then
		out[#out + 1] = string.format("%q", value)
	elseif kind == "number" then
		if value ~= value then
			out[#out + 1] = "0/0"
		elseif value == math.huge then
			out[#out + 1] = "1/0"
		elseif value == -math.huge then
			out[#out + 1] = "-1/0"
		else
			out[#out + 1] = string.format("%.17g", value)
		end
	elseif kind == "boolean" then
		out[#out + 1] = tostring(value)
	elseif kind == "table" and not seen[value] then
		seen[value] = true
		out[#out + 1] = "{"
		for key, item in pairs(value) do
			local key_kind = type(key)
			if key_kind == "string" or key_kind == "number" or key_kind == "boolean" then
				out[#out + 1] = "["
				serialize(key, out, seen)
				out[#out + 1] = "]="
				serialize(item, out, seen)
				out[#out + 1] = ","
			end
		end
		out[#out + 1] = "}"
		seen[value] = nil
	else
		out[#out + 1] = "nil"
	end
end

local function write_file(path, text)
	local file = assert(stdio.open(path, "wb"))
	assert(file:write(text))
	assert(file:close())
end

-- What a terminal handler reads of a debug trace.
local function project_trace(trace)
	if type(trace) ~= "table" then
		return nil
	end
	return {
		short_src = trace.short_src,
		currentline = trace.currentline,
		traceback = trace.traceback,
		message = trace.message,
	}
end

-- One entry of handler.pendings, .failures or .errors as the terminal handlers read it. A message
-- that is not a string is rendered here as the handlers render it (pl.pretty.write), so the summary
-- prints the same text without the original value.
local function project_entry(entry)
	local message = entry.message
	if message ~= nil and type(message) ~= "string" then
		message = require("pl.pretty").write(message)
	end
	local element = nil
	if type(entry.element) == "table" then
		element = {
			name = entry.element.name,
			descriptor = entry.element.descriptor,
			trace = project_trace(entry.element.trace),
		}
	end
	return {
		name = entry.name,
		message = message,
		randomseed = entry.randomseed,
		isError = entry.isError,
		trace = project_trace(entry.trace),
		element = element,
	}
end

local function project_list(list)
	local out = {}
	for index, entry in ipairs(list) do
		out[index] = project_entry(entry)
	end
	return out
end

local function load_dump(path)
	local chunk, err = loadfile(path)
	if not chunk then
		error("busted_parallel: cannot read " .. path .. ": " .. tostring(err), 0)
	end
	setfenv(chunk, {})
	return chunk()
end

return function(options)
	local busted = require("busted")

	if mode == "discover" then
		-- One line per file, "file\t<path>" or, for a file that does not compile, "error\t<path>";
		-- "problem\t<message>" for anything else busted reports (a root that does not exist, no
		-- spec file at all), which the runner leaves to a serial busted run to print.
		local lines = {}
		local discover = {}
		function discover.subscribe()
			-- First in line for every file busted is about to register: note it, and stop it there,
			-- so nothing runs.
			busted.subscribe({ "register", "file" }, function(name)
				lines[#lines + 1] = "file\t" .. name
				return nil, false
			end, { priority = 1 })
			busted.subscribe({ "error" }, function(element, _, message)
				if type(element) == "table" and element.descriptor == "file" and element.name then
					lines[#lines + 1] = "error\t" .. element.name
				else
					lines[#lines + 1] = "problem\t" .. tostring(message):gsub("[\r\n]", " ")
				end
				return nil, true
			end)
			busted.subscribe({ "suite", "end" }, function()
				write_file(assert(dump_path, "BUSTED_PARALLEL_DUMP is not set"), table.concat(lines, "\n") .. "\n")
				return nil, true
			end)
		end
		return discover
	end

	-- The wrapped handler keeps a local copy of io.write, taken when its module loads: hand it a gate,
	-- so a shard can silence the summary the handler prints at the end of the suite.
	-- (luacheck 122: io.write is replaced on purpose, for as long as that module takes to load.)
	local real_write = stdio.write
	local quiet = false
	stdio.write = function(...) -- luacheck: ignore 122
		if quiet then
			return stdio.output()
		end
		return real_write(...)
	end
	local ok, inner = pcall(require, "busted.outputHandlers." .. inner_name)
	stdio.write = real_write -- luacheck: ignore 122
	if not ok then
		error(inner, 0)
	end
	local handler = inner(options)

	local wrapper = {}
	function wrapper.subscribe(_, subscribe_options)
		handler:subscribe(subscribe_options)
		if mode == "shard" then
			-- Inserted first: silence the handler's summary; appended last: write its inputs.
			busted.subscribe({ "suite", "end" }, function()
				quiet = true
				return nil, true
			end, { priority = 1 })
			busted.subscribe({ "suite", "end" }, function()
				quiet = false
				local out = {}
				serialize({
					successesCount = handler.successesCount,
					pendingsCount = handler.pendingsCount,
					failuresCount = handler.failuresCount,
					errorsCount = handler.errorsCount,
					duration = handler.getDuration(),
					pendings = project_list(handler.pendings),
					failures = project_list(handler.failures),
					errors = project_list(handler.errors),
				}, out, {})
				write_file(assert(dump_path, "BUSTED_PARALLEL_DUMP is not set"), "return " .. table.concat(out) .. "\n")
				return nil, true
			end)
		elseif mode == "render" then
			-- Inserted first: replace what the handler counted (nothing) with the shards' totals.
			busted.subscribe({ "suite", "end" }, function()
				local duration = tonumber(stdio.read("*l"))
				local merged = { pendings = {}, failures = {}, errors = {} }
				local counts = { successesCount = 0, pendingsCount = 0, failuresCount = 0, errorsCount = 0 }
				for path in stdio.lines() do
					if path ~= "" then
						local dump = load_dump(path)
						for key in pairs(counts) do
							counts[key] = counts[key] + (dump[key] or 0)
						end
						for key, list in pairs(merged) do
							for _, entry in ipairs(dump[key] or {}) do
								list[#list + 1] = entry
							end
						end
					end
				end
				for key, value in pairs(counts) do
					handler[key] = value
				end
				for key, list in pairs(merged) do
					handler[key] = list
				end
				handler.getDuration = function()
					return duration or 0
				end
				return nil, true
			end, { priority = 1 })
		else
			error("busted_parallel.lua: BUSTED_PARALLEL_MODE must be discover, shard or render", 0)
		end
		return wrapper
	end
	return wrapper
end
