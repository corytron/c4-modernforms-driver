-- Modern Forms Fan driver: the scaffold of docs/scaffold-design.md, section 7.
-- It proves the pipeline (lint, tests, the package, the Documentation tab)
-- and controls no fan: its rows are Driver Version and Debug Mode, and in a
-- dev build Dev Server, which starts the dev loop (docs/dev-loop.md). The v1
-- contract replaces it; it is never installed on the house.
--
-- Wired the way the owner's Hue drivers are (corytron/c4-hue-driver): the
-- DriverWorks entry points go through common/dispatch.lua, the log through
-- common/log.lua, and the dev loop hooks in as it does in the Hue Bridge
-- driver: a guarded require of common/devloop.lua, which only a dev build
-- ships, a Dev Server property handler, and the loop started last in late
-- init. The loop's reload runs OnDriverDestroyed, this file again, then
-- OnDriverInit and OnDriverLateInit("DIT_UPDATING"), so all of this may run
-- twice in one Lua state: handlers are registered at load into the fresh
-- dispatch module, and every timer armed here is cancelled in
-- OnDriverDestroyed.
--
-- UpdateProperty, SetTimer and GetDriverConfigInfo are not safe before
-- OnDriverLateInit [verified: API 22/_25.2], so OnDriverInit does nothing.

local log = require("common.log")
local dispatch = require("common.dispatch")

-- Prefix of every line this driver logs.
local LOG_PREFIX = "Modern Forms Fan"
log.set_prefix(LOG_PREFIX)

-- Dev builds only (tools/build.sh --dev ships common/devloop.lua): the
-- driver fetches its code from a server on the LAN and reloads itself.
-- See docs/dev-loop.md. Release builds have no such module, so this is nil.
local devloop_ok, devloop = pcall(require, "common.devloop")
if not devloop_ok then
	-- Absent in release builds (expected); anything else is a real error
	-- that must be visible, since the loop is how the controller gets tested.
	-- A missing module reads "not found" under busted and "An unknown error
	-- occurred" on the controller [hardware 2026-10-24, the Hue project].
	local reason = tostring(devloop):lower()
	if not (reason:find("not found", 1, true) or reason:find("unknown error", 1, true)) then
		print("[ERROR] " .. LOG_PREFIX .. ": dev loop failed to load: " .. tostring(devloop))
	end
	devloop = nil
end

local late_init_done = false

-- Properties ---------------------------------------------------------------

local function prop(name, value)
	C4:UpdateProperty(name, tostring(value == nil and "" or value))
end

-- Director answers the version lookup with nothing at the first init of a
-- device created by AddDevice [hardware 2026-10-24, the Hue project], so the
-- build's own stamp (common/build_version.lua, written by tools/build.sh) is
-- the fallback.
local build_version_ok, build_version = pcall(require, "common.build_version")
local function driver_version()
	local v = C4:GetDriverConfigInfo("version")
	if v == nil or tostring(v) == "" then
		v = build_version_ok and tostring(build_version) or ""
	end
	return v
end

-- Director fills a new device's property table late: at the first init of
-- a device created by AddDevice the replay of the properties reaches no
-- handler [hardware 2026-10-24, the Hue project], so late init writes the
-- read-only row itself (it has no property handler) and looks again twice
-- while it is empty. A late init run again starts over instead of adding a
-- second chain.
local version_timer = nil

local function show_driver_version(attempt)
	if version_timer then
		version_timer:Cancel()
		version_timer = nil
	end
	local v = driver_version()
	prop("Driver Version", v)
	if v == "" and attempt < 3 then
		version_timer = C4:SetTimer(5000 * attempt, function()
			version_timer = nil
			show_driver_version(attempt + 1)
		end)
	end
end

-- Debug Mode: On logs everything, Off (the default) warnings and errors.
dispatch.properties["Debug_Mode"] = function(value)
	log.set_debug(value == "On")
end

-- Dev loop -------------------------------------------------------------------

local function trimmed(value)
	return (value or ""):match("^%s*(.-)%s*$")
end

-- Dev Server (a DEV-ONLY row of driver.xml): host:port of tools/devserver.py;
-- empty stops the loop. A value set before late init (the replay of the
-- properties) waits for late init, which starts the loop last. A release
-- build registers no handler: it has neither the row nor the module.
if devloop then
	dispatch.properties["Dev_Server"] = function(value)
		local host = trimmed(value)
		if host == "" then
			devloop.stop()
		elseif late_init_done then
			log.always("dev loop: starting against %s", host)
			devloop.start(host)
		end
	end
end

-- Lifecycle ----------------------------------------------------------------

dispatch.install(_G)

function OnDriverInit()
end

function OnDriverLateInit()
	dispatch.replay_properties(Properties)
	show_driver_version(1)
	late_init_done = true
	-- Dev builds: the dev loop starts last, so a reload pushed through it
	-- sees a fully initialised driver.
	if devloop then
		local host = trimmed(Properties["Dev Server"])
		if host ~= "" then
			devloop.start(host)
		end
	end
end

-- The dev loop keeps running: its reload calls this before it loads the new
-- code, and its state outlives the reload; Director kills every timer of a
-- driver that is really destroyed [verified: API 22/_24].
function OnDriverDestroyed()
	if version_timer then
		version_timer:Cancel()
		version_timer = nil
	end
end
