-- Dev loop: lets the development VM push Lua into a running driver and run
-- actions against it without Composer (docs/dev-loop.md). Dev builds only:
-- tools/build.sh packs this file into --dev builds and leaves it out of
-- release builds. Ported from the owner's Hue project (corytron/c4-hue-driver,
-- src/common/devloop.lua, Apache-2.0), with its trees made generic.
--
-- Polling side (devloop.start): a device whose Dev Server property holds the
-- host:port of tools/devserver.py polls that plain-HTTP server for its own
-- source tree, the one named after its driver file (modernforms_fan.c4z polls
-- for modernforms_fan, which the server reads from src/modernforms_fan with
-- src/common as common/). One repeating timer drives each tick as a chain of
-- C4:url transfers, each started from the previous one's OnDone:
--   GET /manifest?tree=<own> -> (GET /bundle?tree=<own>, verify, reload, POST /report) ->
--   for each forwarded tree of devloop.TREES (none by default):
--     GET /manifest?tree=<t> -> (GET /bundle?tree=<t> at a new version, verify,
--                               DEV_RELOAD to the bound devices that lack it) ->
--   GET /commands -> (verify, run each, POST /report command_done) ->
--   POST /log -> (POST /report heartbeat)
-- so no transfer ever starts inside OnHeaders or OnBodyChunk, which Director
-- fails with curl error 2. A tick that fires while the previous chain is
-- still in flight is skipped.
--
-- Forwarded side (dormant: every driver of this project polls for itself
-- today): a device of another driver, bound to the polling device as a
-- consumer on FORWARD_BINDING, never talks to the server. The polling device
-- hands it its tree's signed bundle as a DEV_RELOAD command, which the
-- handler from devloop.reload_handler verifies and applies with the same
-- reload sequence, and every non-debug line that device logs goes to the
-- polling device as DEV_LOG through the sink devloop.forward_logs installs.
-- devloop.start() is never called on such a device.
--
-- Signing (docs/dev-loop.md, "Security"): the controller acts only on what
-- the dev key signed. tools/build.sh --dev bakes the key into each dev
-- package as common/devkey.lua; bundles, command lists and forwarded bundles
-- carry an HMAC-SHA256 over their exact bytes, checked here before anything
-- is decoded, compiled or run. The key and the MACs this module computes are
-- never printed, reported or stored outside this file's locals.
--
-- A driver's development commands are not in its dispatch table:
-- ExecuteCommand has no sender, so any driver in the project could send them
-- there. They live in the table the driver hands to
-- devloop.set_signed_commands, which only a signed `execute` command reaches.
-- Every log line also passes the driver's redactor (devloop.set_redactor),
-- when it is buffered and again when it is shipped, so a secret the driver
-- holds never leaves in a line.
--
-- State lives in _G.__DEVLOOP so a reload of the rest of the driver cannot
-- lose the timer or the log buffer; package.loaded["common.devloop"] is the
-- one driver module a reload never clears.
--
-- Public API (the Hue loop's, unchanged in name and shape):
--   devloop.start(host_port)  idempotent for the same host; a different host
--                             restarts; an empty host stops
--   devloop.stop()            (start and stop called while a command from the
--                             server runs act once its command_done is sent)
--   devloop.running()         -> bool
--   devloop.version()         -> version of the code last loaded, or nil
--                                while the .c4z's own code is running
--   devloop.tree_version(t)   -> version of forwarded tree t last forwarded, or nil
--   devloop.light_version()   -> tree_version("light"), kept from the Hue loop's interface
--   devloop.own_tree()        -> this driver's tree from its driver file name, or nil
--   devloop.apply_forwarded(params)  a forwarded device's DEV_RELOAD handler
--                                -> true, version | false, "skipped" / "refused" / "failed"[, why]
--   devloop.reload_handler(log, tree)  the dispatch handler a forwarded device registers for DEV_RELOAD
--   devloop.forward_logs(log, prefix, get_parent, get_source)  a forwarded device's DEV_LOG sink -> flush
--   devloop.has_key()         -> whether this package carries a dev key
--   devloop.key_fingerprint() -> 16 hex characters naming the key, or nil
--   devloop.check_signature(label, payload, mac)  -> nil when the key signed it, else why not
--   devloop.split_envelope(body)  "<mac>\n<payload>" -> payload, mac
--   devloop.hmac_sha256(key, data)  -> lowercase hex, C4:HMAC or the Lua fallback
--   devloop.hmac_backend()    -> "C4:HMAC" or "Lua (<why>)"
--   devloop.lua_sha256(data), devloop.lua_hmac_sha256(key, data)  the fallback itself
--   devloop.set_signed_commands(handlers)  the driver's development commands, by
--                             dispatch name ("Fan_Request"); run for signed commands only
--   devloop.execute(command, params)  one signed `execute` command -> nil or the error text
--   devloop.set_redactor(fn)  fn(line) -> what of a log line may leave the controller
--   devloop.redacted(line)    -> that verdict, as the loop applies it (never raises)
-- and the fields devloop.TREES (the forwarded trees, {}) and
-- devloop.FORWARD_BINDING (the binding their devices are bound on, 1).

local devloop = {}

devloop.INTERVAL_MS = 3000
devloop.HEARTBEAT_MS = 30000
devloop.MAX_LOG_LINES = 500
devloop.STUCK_TICKS = 10        -- ticks before an unfinished chain is abandoned
devloop.LOG_BUFFER = 30         -- lines a forwarded device keeps while its polling device is unknown
devloop.REFUSED_RETRY_MS = 60000 -- a refused bundle version is fetched again at most this often

-- Every MAC covers DOMAIN .. label .. "\n" .. data; the labels are "bundle",
-- "commands", "admin-token", "fingerprint" and "nonce" (docs/dev-loop.md).
-- The domain is this project's own, so nothing the Hue project's loop signed
-- is ever valid here, whatever key signed it.
devloop.DOMAIN = "c4-mf-devloop/1\n"

-- The trees a polling device forwards to its bound devices: none, since every
-- driver of this project polls for its own tree. A driver whose devices get
-- child devices of another driver bound to them lists those drivers' trees
-- here before devloop.start ({ "modernforms_light" }, say); the children are
-- the consumer devices bound on FORWARD_BINDING whose driver file is
-- <tree>.c4z (docs/dev-loop.md, "Forwarded trees").
devloop.TREES = {}
devloop.FORWARD_BINDING = 1

-- What a forwarded device sends its log lines to its polling device as
-- (devloop.forward_logs); the polling driver's handler prints each one.
devloop.LOG_COMMAND = "DEV_LOG"

-- Shared state, created once per Lua state and reused across reloads. Created
-- at load time, so apply_forwarded works on a device where start() never runs.
local S = rawget(_G, "__DEVLOOP")
if not S then
	S = {
		host = nil,              -- "host:port" while running
		timer = nil,             -- the repeating C4LuaTimer
		gen = 0,                 -- bumped by start/stop; stale callbacks compare it
		busy = false,            -- a tick's chain is in flight
		busy_ticks = 0,
		unreachable = false,     -- server down; said once per transition
		tree = nil,              -- the tree this device polls for (own_tree(), or the server's only one)
		device_id = nil,         -- C4:GetDeviceID(), read at start, named in every report
		version = nil,           -- version last loaded, or attempted and failed
		bundle = nil,            -- files of the last bundle loaded (verified)
		trees = {},              -- forwarded tree -> { version, bundle = { payload, mac }, forwarded = { [id] = version } }
		driver_files = {},       -- bound device id -> driverFileName (false = unknown)
		no_tree = {},            -- tree name -> true once "server has no such tree" was said
		refused = {},            -- tree name -> { version, at } of the last refused bundle
		nonce_count = 0,         -- command requests made, for the nonces
		commands_refused = false, -- a refused command list was said; cleared by a good one
		last_command_id = 0,
		last_report_ms = 0,
		log = {},                -- { t = ms, line = string }, oldest first
		original_print = nil,
		wrapper = nil,           -- our print replacement, so we recognise it
		shadow = {},             -- values the driver set through C4:UpdateProperty
		wrapped_c4 = nil,        -- the C4 table whose UpdateProperty we wrapped
		original_update = nil,
		loader = nil,            -- our package.loaders entry
		signed_commands = nil,   -- the driver's development commands (set_signed_commands)
		redactor = nil,          -- the driver's log line filter (set_redactor)
		holding = false,         -- a command runs: start/stop only note where the loop should end up
		held = nil,              -- that note: the host:port to move to, "" to stop (run_command acts on it)
	}
	rawset(_G, "__DEVLOOP", S)
end
-- A copy of this module meeting a state another copy made (the specs do
-- this; on the controller the module loads once per Lua state) finds every
-- table and counter it needs.
for _, field in ipairs({ "trees", "driver_files", "no_tree", "refused", "log", "shadow" }) do
	if type(S[field]) ~= "table" then S[field] = {} end
end
S.gen = S.gen or 0
S.busy_ticks = S.busy_ticks or 0
S.nonce_count = S.nonce_count or 0
S.last_command_id = S.last_command_id or 0
S.last_report_ms = S.last_report_ms or 0

local compile = rawget(_G, "loadstring") or rawget(_G, "load")

-- Milliseconds since the epoch, as the server expects for log lines.
local function now_ms()
	local ok, t = pcall(function() return C4:GetTime() end)
	return ok and type(t) == "number" and t or os.time() * 1000
end

-- Log capture -------------------------------------------------------------

-- What stands in for a line the redactor could not vouch for.
devloop.WITHHELD = "devloop: a log line was withheld (the redactor failed on it)"

local redacting = false -- the redactor is running; a line it prints itself is not given back to it

-- What of `line` may leave the controller, as the driver's redactor
-- (devloop.set_redactor) decides; without one, all of it. A string is
-- kept and nil keeps nothing; a redactor that raises or answers anything
-- else withholds the line, since nothing then says it is clean. Never
-- raises: it runs inside capture, which runs inside print.
local function redacted(line)
	local fn = S.redactor
	if type(fn) ~= "function" then return line end
	if redacting then return devloop.WITHHELD end
	redacting = true
	local ok, kept = pcall(fn, line)
	redacting = false
	if ok and (kept == nil or type(kept) == "string") then return kept end
	return devloop.WITHHELD
end

local function capture(line)
	line = redacted(line)
	if line == nil then return end
	local log = S.log
	log[#log + 1] = { t = now_ms(), line = line }
	if #log > devloop.MAX_LOG_LINES then table.remove(log, 1) end
end

-- The loop's own messages: the original print so Composer shows them, and
-- the buffer so the server does too.
local function say(fmt, ...)
	local ok, msg = pcall(string.format, fmt, ...)
	local line = "devloop: " .. (ok and msg or tostring(fmt))
	local out = S.original_print or rawget(_G, "print")
	if out then pcall(out, line) end
	capture(line)
end

-- Every callback body runs through this, so one failure cannot stop the loop.
local function guarded(fn, ...)
	local ok, err = pcall(fn, ...)
	if not ok then say("error: %s", tostring(err)) end
	return ok
end

-- The dev key -------------------------------------------------------------

-- common/devkey.lua, which tools/build.sh --dev writes into each dev package
-- and nowhere else: 64 lowercase hex characters, used as they are (ASCII) to
-- key HMAC-SHA256. Read once, here, and kept in this local alone. Without
-- it (or with a malformed one) every bundle, command list and DEV_RELOAD is
-- refused. The require error is not kept: it could quote the file.
local KEY, KEY_PROBLEM
do
	local ok, value = pcall(require, "common.devkey")
	if not ok then
		KEY_PROBLEM = "this build has no dev key (common/devkey.lua; build with tools/build.sh --dev)"
	elseif type(value) ~= "string" or #value ~= 64 or not value:match("^[0-9a-f]+$") then
		KEY_PROBLEM = "common/devkey.lua is malformed (64 lowercase hex characters expected)"
	else
		KEY = value
	end
end

-- HMAC-SHA256: the pure-Lua fallback ----------------------------------------

-- Lua 5.1 has no bit operators, so 32-bit words are plain numbers: AND is a
-- byte table, XOR is a + b - 2 * (a AND b), and the rotations are
-- arithmetic. About 0.4 MB/s under PUC Lua 5.1 on the development VM (the
-- Hue project's measurement); it runs only when C4:HMAC is missing or fails
-- its self-test, and under the specs, which pin it to the RFC 4231 and
-- FIPS 180 vectors.

local TWO32 = 4294967296
local AND8 -- AND8[a * 256 + b] = a AND b for bytes a and b; built at first use

-- Each entry from the one at half both bytes: and(a, b) = 2 * and(a >> 1,
-- b >> 1) + (a & 1) * (b & 1). That entry has a smaller index, so the
-- ascending loop has already filled it.
local function and_table()
	local t = { [0] = 0 }
	for a = 0, 255 do
		local half_a, low_a = (a - a % 2) / 2 * 256, a % 2
		for b = 0, 255 do
			if a + b > 0 then
				t[a * 256 + b] = t[half_a + (b - b % 2) / 2] * 2 + low_a * (b % 2)
			end
		end
	end
	return t
end

local function band(x, y)
	local t = AND8
	local x0, y0 = x % 256, y % 256
	x, y = (x - x0) / 256, (y - y0) / 256
	local x1, y1 = x % 256, y % 256
	x, y = (x - x1) / 256, (y - y1) / 256
	local x2, y2 = x % 256, y % 256
	x, y = (x - x2) / 256, (y - y2) / 256
	return t[x0 * 256 + y0] + t[x1 * 256 + y1] * 256 + t[x2 * 256 + y2] * 65536 + t[x * 256 + y] * 16777216
end

local function bxor(x, y)
	return x + y - 2 * band(x, y)
end

local function rotr(x, n)
	local p = 2 ^ n
	local low = x % p
	return (x - low) / p + low * (TWO32 / p)
end

-- FIPS 180-4, 4.2.2 and 5.3.3.
local K = {
	0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
	0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
	0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
	0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
	0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
	0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
	0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
	0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}
local H0 = { 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19 }

-- One 64-byte block of `s` from offset `off` into the hash state H; W is
-- scratch. Ch is (e AND f) + (NOT e AND g) and Maj is (a AND b) + (c AND
-- (a XOR b)): in both the two terms share no bit, so the sum is the XOR.
local function compress(H, s, off, W)
	for j = 1, 16 do
		local b1, b2, b3, b4 = s:byte(off + 1, off + 4)
		W[j] = ((b1 * 256 + b2) * 256 + b3) * 256 + b4
		off = off + 4
	end
	for j = 17, 64 do
		local x, y = W[j - 15], W[j - 2]
		local s0 = bxor(bxor(rotr(x, 7), rotr(x, 18)), (x - x % 8) / 8)
		local s1 = bxor(bxor(rotr(y, 17), rotr(y, 19)), (y - y % 1024) / 1024)
		W[j] = (W[j - 16] + s0 + W[j - 7] + s1) % TWO32
	end
	local a, b, c, d, e, f, g, h = H[1], H[2], H[3], H[4], H[5], H[6], H[7], H[8]
	for j = 1, 64 do
		local sum1 = bxor(bxor(rotr(e, 6), rotr(e, 11)), rotr(e, 25))
		local ch = band(e, f) + band(4294967295 - e, g)
		local t1 = h + sum1 + ch + K[j] + W[j]
		local sum0 = bxor(bxor(rotr(a, 2), rotr(a, 13)), rotr(a, 22))
		local ab = band(a, b)
		local maj = ab + band(c, a + b - 2 * ab)
		h, g, f, e, d, c, b, a = g, f, e, (d + t1) % TWO32, c, b, a, (t1 + sum0 + maj) % TWO32
	end
	H[1], H[2], H[3], H[4] = (H[1] + a) % TWO32, (H[2] + b) % TWO32, (H[3] + c) % TWO32, (H[4] + d) % TWO32
	H[5], H[6], H[7], H[8] = (H[5] + e) % TWO32, (H[6] + f) % TWO32, (H[7] + g) % TWO32, (H[8] + h) % TWO32
end

-- In two halves: "%x" of a number of 2^31 or more is not portable across
-- Lua 5.1 builds.
local function word_hex(w)
	local low = w % 65536
	return string.format("%04x%04x", (w - low) / 65536, low)
end

-- SHA-256 of a byte string, as lowercase hex.
function devloop.lua_sha256(data)
	AND8 = AND8 or and_table()
	local bits, tail = #data * 8, {}
	for i = 8, 1, -1 do
		local byte = bits % 256
		tail[i] = string.char(byte)
		bits = (bits - byte) / 256
	end
	local padded = data .. "\128" .. string.rep("\0", (55 - #data) % 64) .. table.concat(tail)
	local H, W = { unpack(H0) }, {}
	for off = 0, #padded - 1, 64 do
		compress(H, padded, off, W)
	end
	local out = {}
	for i = 1, 8 do out[i] = word_hex(H[i]) end
	return table.concat(out)
end

local function from_hex(text)
	return (text:gsub("%x%x", function(pair) return string.char(tonumber(pair, 16)) end))
end

-- RFC 2104 with SHA-256 (block 64 bytes); a longer key is hashed first.
function devloop.lua_hmac_sha256(key, data)
	if #key > 64 then key = from_hex(devloop.lua_sha256(key)) end
	key = key .. string.rep("\0", 64 - #key)
	AND8 = AND8 or and_table()
	local inner, outer = {}, {}
	for i = 1, 64 do
		local k = key:byte(i)
		inner[i] = string.char(bxor(k, 0x36))
		outer[i] = string.char(bxor(k, 0x5c))
	end
	return devloop.lua_sha256(table.concat(outer) .. from_hex(devloop.lua_sha256(table.concat(inner) .. data)))
end

-- HMAC-SHA256: C4:HMAC first ---------------------------------------------------

-- C4:HMAC(digest, key, data, options) [verified: API docs, 6_encryption/_10-HMAC;
-- available from 1.6.0]. Trusted only after it answers RFC 4231 test case 2
-- correctly (on OS 3.4.2 it does: the Hue project's dev pass of 2026-10-25).
local SELF_TEST = { key = "Jefe", data = "what do ya want for nothing?",
	mac = "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843" }
local C4_HMAC_OPTIONS = { return_encoding = "HEX", key_encoding = "NONE", data_encoding = "NONE" }

local backend -- "C4:HMAC" or "Lua (<why>)", chosen at first use

local function c4_hmac(key, data)
	local mac, err = C4:HMAC("SHA256", key, data, C4_HMAC_OPTIONS)
	if type(mac) ~= "string" then error(tostring(err or "no result"), 0) end
	return mac:lower()
end

local function choose_backend()
	local found, fn = pcall(function() return C4.HMAC end)
	if not found or type(fn) ~= "function" then
		return "Lua (no C4:HMAC)"
	end
	local ok, mac = pcall(c4_hmac, SELF_TEST.key, SELF_TEST.data)
	if not ok then
		return "Lua (C4:HMAC raised: " .. tostring(mac) .. ")"
	elseif mac ~= SELF_TEST.mac then
		return "Lua (C4:HMAC failed the RFC 4231 self-test)"
	end
	return "C4:HMAC"
end

function devloop.hmac_backend()
	backend = backend or choose_backend()
	return backend
end

-- HMAC-SHA256 of `data` with `key`, lowercase hex. If C4:HMAC raises on a
-- real input the fallback takes over for good; its error text is not kept
-- (it could quote the arguments).
function devloop.hmac_sha256(key, data)
	if devloop.hmac_backend() == "C4:HMAC" then
		local ok, mac = pcall(c4_hmac, key, data)
		if ok then return mac end
		backend = "Lua (C4:HMAC raised on a real input)"
		say("C4:HMAC failed; checking signatures in Lua from now on")
	end
	return devloop.lua_hmac_sha256(key, data)
end

-- Signatures -------------------------------------------------------------------

local function mac_of(label, data)
	return devloop.hmac_sha256(KEY, devloop.DOMAIN .. label .. "\n" .. data)
end

-- Same length and the same characters, without stopping at the first
-- difference.
local function same(a, b)
	if #a ~= #b then return false end
	local differences = 0
	for i = 1, #a do
		if a:byte(i) ~= b:byte(i) then differences = differences + 1 end
	end
	return differences == 0
end

function devloop.has_key()
	return KEY ~= nil
end

local fingerprint -- of KEY, computed once

function devloop.key_fingerprint()
	if not KEY then return nil end
	fingerprint = fingerprint or mac_of("fingerprint", ""):sub(1, 16)
	return fingerprint
end

-- nil when `mac` (64 hex characters) signs `payload` under `label` with this
-- build's key, else why not. The MAC it expected is never returned or said:
-- whoever answers as the server could sign their own payloads with it.
function devloop.check_signature(label, payload, mac)
	if not KEY then
		return "this build has no dev key"
	end
	if type(payload) ~= "string" or type(mac) ~= "string" or #mac ~= 64 or not mac:match("^%x+$") then
		return "not signed"
	end
	if not same(mac:lower(), mac_of(label, payload)) then
		return "signature mismatch"
	end
	return nil
end

-- A signed answer is "<64 hex MAC>\n<payload>". Returns payload, mac; for
-- anything else the body and no MAC (check_signature then says "not signed").
function devloop.split_envelope(body)
	if type(body) == "string" and body:sub(65, 65) == "\n" then
		return body:sub(66), body:sub(1, 64)
	end
	return body, nil
end

-- A fresh nonce per command request, never repeated: a value of this load
-- and a counter, through the key so it is plain hex. Uniqueness is what
-- matters (docs/dev-loop.md, "Security").
local LOAD_MARK = table.concat({ tostring(now_ms()), tostring(os.clock()), tostring({}), tostring(math.random()) }, "/")

local function new_nonce()
	S.nonce_count = S.nonce_count + 1
	return mac_of("nonce", LOAD_MARK .. "/" .. tostring(S.nonce_count)):sub(1, 32)
end

-- Wrapped once; a reloaded common.log picks the wrapper up as its sink
-- because it reads the global print when it loads.
local function wrap_print()
	local current = rawget(_G, "print")
	if current == S.wrapper then return end
	S.original_print = current
	S.wrapper = function(...)
		if S.original_print then S.original_print(...) end
		local parts = {}
		for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
		pcall(capture, table.concat(parts, "\t"))
	end
	rawset(_G, "print", S.wrapper)
end

local function unwrap_print()
	if S.wrapper and rawget(_G, "print") == S.wrapper then rawset(_G, "print", S.original_print) end
	S.wrapper = nil
end

-- Properties snapshot -----------------------------------------------------

local function unwrap_update_property()
	if type(S.wrapped_c4) == "table" then S.wrapped_c4.UpdateProperty = S.original_update end
	S.wrapped_c4, S.original_update = nil, nil
end

-- Only possible when C4 is a Lua table (userdata on the controller, as far
-- as we know; the startup report says which).
local function wrap_update_property()
	local c4 = rawget(_G, "C4")
	if type(c4) ~= "table" or S.wrapped_c4 == c4 then return end
	unwrap_update_property()
	S.wrapped_c4, S.original_update = c4, c4.UpdateProperty
	c4.UpdateProperty = function(self, name, value, ...)
		S.shadow[tostring(name)] = value
		if S.original_update then return S.original_update(self, name, value, ...) end
	end
end

-- A copy of Properties with the shadowed values on top: Properties may lag
-- behind what the driver set through C4:UpdateProperty.
local function snapshot()
	local out = {}
	local props = rawget(_G, "Properties")
	if type(props) == "table" then
		for k, v in pairs(props) do out[tostring(k)] = v end
	end
	for k, v in pairs(S.shadow) do out[k] = v end
	return out
end

-- Which tree a driver file is: its name without .c4z (modernforms_fan.c4z ->
-- "modernforms_fan"), the directory under src/ that tools/build.sh packs it
-- from and the name tools/devserver.py serves it under. A path before the
-- name is ignored; nil for anything else.
local function tree_of_file(file)
	if type(file) ~= "string" then return nil end
	return file:match("^([%w_]+)%.[cC]4[zZ]$") or file:match("[/\\]([%w_]+)%.[cC]4[zZ]$")
end

local function driver_file()
	local ok, file = pcall(function() return C4:GetDriverFileName() end)
	return ok and file or nil
end

local function sandbox_facts()
	local jit = rawget(_G, "jit")
	local ok, driver_version = pcall(function() return C4:GetDriverConfigInfo("version") end)
	local file = driver_file()
	return {
		_VERSION = tostring(_VERSION),
		jit = type(jit),
		["jit.version"] = type(jit) == "table" and tostring(jit.version) or nil,
		loadstring = type(rawget(_G, "loadstring")),
		load = type(rawget(_G, "load")),
		setfenv = type(rawget(_G, "setfenv")),
		package = type(package),
		["package.loaders"] = type(package) == "table" and type(package.loaders) or "nil",
		C4 = type(rawget(_G, "C4")),
		bit = type(rawget(_G, "bit")),
		hmac = devloop.hmac_backend(),
		driver_version = ok and tostring(driver_version) or nil,
		-- What C4:GetDriverFileName answers, which the tree comes from [its
		-- shape on the controller is assumed: the first report shows it].
		driver_file = file ~= nil and tostring(file) or nil,
	}
end

-- HTTP ----------------------------------------------------------------------

-- One exchange with the dev server. `callback(result)` runs exactly once with
-- { ok, code, body, json, err }, never sees a raised error, and is dropped if
-- the loop was stopped or restarted meanwhile. With `raw` the body is not
-- decoded (a signed envelope is not JSON as a whole).
local function request(method, path, body, callback, raw)
	local gen = S.gen
	local function finish(result)
		if gen == S.gen then guarded(callback, result) end
	end
	local ok, err = pcall(function()
		local url = "http://" .. S.host .. path
		-- encodeArrays: Director's JsonEncode writes Lua arrays as objects
		-- unless told otherwise, and the server wants a JSON list of lines.
		local data = body and C4:JsonEncode(body, false, true) or nil
		local headers = data and { ["Content-Type"] = "application/json" } or {}
		local transfer = C4:url()
			:SetOptions({ fail_on_error = false, timeout = 10, connect_timeout = 3 })
			:OnDone(function(_, responses, err_code, err_msg)
				local result = { ok = false }
				local response = responses and responses[#responses]
				if err_code ~= 0 then
					result.err = string.format("transfer failed (%s): %s", tostring(err_code), tostring(err_msg))
				elseif not response then
					result.err = "no response"
				else
					result.code, result.body = response.code, response.body
					result.ok = response.code >= 200 and response.code < 300
					if not result.ok then
						result.err = "HTTP " .. tostring(response.code)
					elseif not raw and response.body and response.body ~= "" then
						local decoded, value = pcall(function() return C4:JsonDecode(response.body) end)
						result.json = decoded and value or nil
					end
				end
				finish(result)
			end)
		-- Get/Post can raise at start (the Hue project saw it with CA files).
		if method == "POST" then transfer:Post(url, data or "", headers) else transfer:Get(url, headers) end
	end)
	if not ok then finish({ ok = false, err = "could not start transfer: " .. tostring(err) }) end
end

-- tree name -> the version last forwarded, nil when nothing was.
local function forwarded_versions()
	local out, any = {}, false
	for tree, held in pairs(S.trees) do
		if held.version ~= nil then
			out[tree], any = held.version, true
		end
	end
	return any and out or nil
end

-- Every report names this device and its tree, carries the version of the
-- code running and of every tree forwarded so far (absent until the first
-- forward), so /status shows them, and the key's fingerprint, so the server
-- can tell a key mismatch at once.
local function report(event, extra, callback)
	local body = { version = S.version, tree = S.tree, device_id = S.device_id, forwarded = forwarded_versions(),
		event = event, properties = snapshot(), key_fingerprint = devloop.key_fingerprint() }
	for k, v in pairs(extra or {}) do body[k] = v end
	-- An error text can quote whatever a command saw: it passes the redactor
	-- like a log line.
	if type(body.error) == "string" then body.error = redacted(body.error) end
	S.last_report_ms = now_ms()
	request("POST", "/report", body, function(r)
		if not r.ok then say("report %s failed: %s", event, tostring(r.err)) end
		if callback then callback(r) end
	end)
end

-- Reload ----------------------------------------------------------------------

-- A package.loaders entry serving `a.b` from the bundle's "a/b.lua". Modules
-- the bundle lacks fall through to the normal loaders, i.e. the .c4z. The
-- previous entry is removed first so repeated reloads do not stack loaders.
local function install_loader(files)
	local loaders = type(package) == "table" and package.loaders
	if type(loaders) ~= "table" then
		error("package.loaders is " .. type(loaders) .. "; cannot serve modules from the bundle")
	end
	local function loader(name)
		local path = (string.gsub(name, "%.", "/")) .. ".lua"
		if type(files[path]) ~= "string" then return "\n\tno file '" .. path .. "' in the dev bundle" end
		local chunk, err = compile(files[path], "=" .. path)
		return chunk or ("\n\t" .. tostring(err))
	end
	for i = #loaders, 1, -1 do
		if loaders[i] == S.loader then table.remove(loaders, i) end
	end
	table.insert(loaders, 1, loader)
	S.loader = loader
end

-- The driver's own modules, cleared on reload so the bundle's copies load:
-- common.* except this one, and every module the old or the new bundle holds,
-- by the first part of its path (fan/http.lua makes every fan.* module the
-- driver's; a top-level x.lua the module x). Modules no bundle brought, the
-- runtime's and any library's, stay loaded.
local function owned_modules(...)
	local dirs, tops = { common = true }, {}
	for i = 1, select("#", ...) do
		local files = select(i, ...)
		if type(files) == "table" then
			for path in pairs(files) do
				path = tostring(path)
				local dir = path:match("^([^/]+)/")
				local top = path:match("^([^/]+)%.lua$")
				if dir then
					dirs[dir] = true
				elseif top and top ~= "driver" then
					tops[top] = true
				end
			end
		end
	end
	return function(name)
		if name == "common.devloop" then return false end
		local first = name:match("^([^%.]+)%.")
		return (first ~= nil and dirs[first] == true) or tops[name] == true
	end
end

-- Tear the running driver down and bring `files` up in its place. Returns
-- nil on success or the error text; the second value is a warning when
-- OnDriverDestroyed failed but the new code is running anyway (stopping
-- there would leave the old code in place, with every retry hitting the
-- same teardown bug). `files` must come from a verified bundle.
local function reload(files, version)
	local warning
	local destroy = rawget(_G, "OnDriverDestroyed")
	if type(destroy) == "function" then
		local ok, err = pcall(destroy)
		if not ok then
			warning = "OnDriverDestroyed failed: " .. tostring(err)
			say("%s", warning)
		end
	end
	local owned = owned_modules(S.bundle, files)
	for name in pairs(package.loaded) do
		if owned(name) then package.loaded[name] = nil end
	end
	-- Recorded before anything can fail: a failed version is not retried
	-- until the server has a different one.
	S.version, S.bundle = version, files
	local ok, err = pcall(install_loader, files)
	if not ok then return tostring(err) end
	if type(files["driver.lua"]) ~= "string" then return "bundle has no driver.lua" end
	local chunk, cerr = compile(files["driver.lua"], "=driver.lua")
	if not chunk then return tostring(cerr) end
	ok, err = pcall(chunk)
	if not ok then return "driver.lua: " .. tostring(err) end
	for _, entry in ipairs({ "OnDriverInit", "OnDriverLateInit" }) do
		local fn = rawget(_G, entry)
		if type(fn) == "function" then
			ok, err = pcall(fn, "DIT_UPDATING")
			if not ok then return entry .. " failed: " .. tostring(err) end
		end
	end
	return nil, warning
end

local function count_files(files)
	local count = 0
	for _ in pairs(files) do count = count + 1 end
	return count
end

-- Reload, report the outcome, then `done(err)`.
local function apply_bundle(files, version, done)
	say("reloading to version %s (%d files)", tostring(version), count_files(files))
	local err, warning = reload(files, version)
	if err then
		say("reload failed: %s", err)
		report("reload_failed", { error = err }, function() done(err) end)
	else
		say("reload complete: version %s", tostring(version))
		report("reload", { error = warning }, function() done(nil) end)
	end
end

-- GET /bundle?tree=<tree> and verify it before anything is decoded.
-- `callback(bundle, err, refused)`: `bundle` is { version, files, payload,
-- mac } when it verified; otherwise `err` says why, and `refused` is true
-- when the signature, or the tree it was signed for, was wrong rather than
-- the transfer.
local function fetch_bundle(tree, callback)
	request("GET", "/bundle?tree=" .. tree, nil, function(r)
		if not r.ok then
			return callback(nil, "bundle: " .. tostring(r.err))
		end
		local payload, mac = devloop.split_envelope(r.body)
		local why = devloop.check_signature("bundle", payload, mac)
		if why then
			return callback(nil, why, true)
		end
		local ok, j = pcall(function() return C4:JsonDecode(payload) end)
		if not ok or type(j) ~= "table" or type(j.files) ~= "table" then
			return callback(nil, "bundle: malformed payload")
		end
		if j.tree ~= tree then
			return callback(nil, "signed for the " .. tostring(j.tree) .. " tree", true)
		end
		callback({ version = tostring(j.version), files = j.files, payload = payload, mac = mac })
	end, true)
end

-- Refused bundles --------------------------------------------------------------

-- A bundle that did not verify: said once per version, with a `refused`
-- report so /status shows it, then `next_step()`. That version is not
-- fetched again for REFUSED_RETRY_MS (a retry that is refused again is
-- silent); a `reload` command forgets every refusal.
local function refuse(tree, version, why, next_step)
	local before = S.refused[tree]
	S.refused[tree] = { version = version, at = now_ms() }
	if before and before.version == version then return next_step() end
	say("%s bundle %s refused: %s", tree, tostring(version), why)
	report("refused", { refused_tree = tree, refused_version = version, error = why }, function() next_step() end)
end

local function recently_refused(tree, version)
	local r = S.refused[tree]
	return r ~= nil and r.version == version and now_ms() - r.at < devloop.REFUSED_RETRY_MS
end

-- Forwarded trees -------------------------------------------------------------

-- driverFileName per bound device, cached in S.driver_files; the ids not seen
-- yet are looked up with one C4:GetDevices (DeviceIds is a comma-separated
-- string [verified: API docs, 22_miscellaneous/_9-GetDevices; the Hue
-- project's hardware notes]). false = could not be read.
local function driver_files(bound)
	local missing = {}
	for id in pairs(bound) do
		if S.driver_files[id] == nil then missing[#missing + 1] = tostring(id) end
	end
	if #missing > 0 then
		local ok, devices = pcall(function() return C4:GetDevices({ DeviceIds = table.concat(missing, ",") }) end)
		if ok and type(devices) == "table" then
			for id, info in pairs(devices) do
				S.driver_files[tonumber(id) or id] = type(info) == "table" and info.driverFileName or false
			end
		end
		for _, id in ipairs(missing) do
			local key = tonumber(id) or id
			if S.driver_files[key] == nil then S.driver_files[key] = false end
		end
	end
	return S.driver_files
end

-- Hand a tree's signed bundle ({ payload, mac }, as the server sent it) to
-- every bound device running that tree's driver (<tree>.c4z, as C4:GetDevices
-- names it) that has not received this version, as one DEV_RELOAD command
-- { tree, version, bundle = payload, mac } each; the device verifies it and
-- reloads itself through devloop.apply_forwarded. A device whose driver file
-- cannot be read gets nothing. Runs every tick the server has the tree, from
-- the held bundle while the version is unchanged: S.trees[tree].forwarded
-- remembers, per bound device, the version it was last sent, so a device
-- bound after the version was first forwarded catches up on the next tick. A
-- device that leaves the bound set is forgotten. The version is recorded per
-- device before the send, so a device whose send fails is not retried until
-- the server has a different version.
local function forward_tree(tree, bundle, version)
	local held = S.trees[tree] or { forwarded = {} }
	S.trees[tree] = held
	local changed = held.version ~= version
	held.version, held.bundle = version, { payload = bundle.payload, mac = bundle.mac }
	local ok, err = pcall(function()
		local bound = C4:GetBoundConsumerDevices(S.device_id or C4:GetDeviceID(), devloop.FORWARD_BINDING)
		if type(bound) ~= "table" then bound = {} end
		local forwarded = held.forwarded
		for id in pairs(forwarded) do
			if bound[id] == nil then forwarded[id] = nil end
		end
		local kinds, wanted = driver_files(bound), tree .. ".c4z"
		local due, members = {}, 0
		for id in pairs(bound) do
			if kinds[id] == wanted then
				members = members + 1
				if forwarded[id] ~= version then due[#due + 1] = id end
			end
		end
		if changed and members == 0 then
			say("%s version %s: no bound %s devices", tree, tostring(version), tree)
			return
		end
		if #due == 0 then return end
		-- The server's text, unchanged: the device checks the very bytes the
		-- server signed. tree and version ride along unsigned.
		local params = { tree = tree, version = version, bundle = bundle.payload, mac = bundle.mac }
		local sent, failed = 0, 0
		for _, id in ipairs(due) do
			forwarded[id] = version
			-- Trailing args: allowEmptyValues = false, logCommand = false, so
			-- Director does not write the whole bundle to its log every reload
			-- [verified: API docs, 32_serial_network_device/_19-SendToDevice].
			local ok_send, serr = pcall(function()
				C4:SendToDevice(id, "DEV_RELOAD", params, false, false)
			end)
			if ok_send then
				sent = sent + 1
			else
				failed = failed + 1
				say("DEV_RELOAD to device %s failed: %s", tostring(id), tostring(serr))
			end
		end
		say("%s version %s forwarded to %d %s%s device(s)%s", tree, tostring(version), sent,
			changed and "" or "newly bound ", tree,
			failed > 0 and string.format(", %d failed", failed) or "")
	end)
	if not ok then say("%s forward failed: %s", tree, tostring(err)) end
	-- At a new version a heartbeat is due at the end of this tick, so /status
	-- sees it at once instead of up to HEARTBEAT_MS later.
	if changed then S.last_report_ms = 0 end
end

-- Tick chain ------------------------------------------------------------------

local function end_tick()
	if now_ms() - S.last_report_ms < devloop.HEARTBEAT_MS then
		S.busy = false
		return
	end
	report("heartbeat", nil, function() S.busy = false end)
end

-- Lines stay in the buffer until the server accepts them (the cap still
-- applies meanwhile), so a failed POST loses nothing. Each line passes the
-- redactor once more on its way out: one buffered before the redactor knew
-- the secret (a reload's new code learns it only at its late init, after its
-- first lines) leaves without it all the same.
local function step_log()
	if #S.log == 0 then return end_tick() end
	local entries, sent, lines = {}, {}, {}
	for i, entry in ipairs(S.log) do entries[i] = entry end
	for _, entry in ipairs(entries) do
		sent[entry] = true
		local line = redacted(entry.line)
		if line ~= nil then lines[#lines + 1] = { t = entry.t, line = line } end
	end
	local function forget_sent()
		local rest = {}
		for _, entry in ipairs(S.log) do
			if not sent[entry] then rest[#rest + 1] = entry end
		end
		S.log = rest
	end
	if #lines == 0 then
		forget_sent()
		return end_tick()
	end
	request("POST", "/log", { version = S.version, tree = S.tree, lines = lines }, function(r)
		if r.ok then forget_sent() end
		end_tick()
	end)
end

-- Signed commands -------------------------------------------------------------

-- The driver's development command for `command`, from the table it handed
-- to devloop.set_signed_commands, named the way common/dispatch.lua names
-- commands: LUA_ACTION unwrapped to its ACTION, each run of white space as
-- "_" (devctl's "Fan Request" finds Fan_Request). Returns the handler and
-- that name, or nil; ACTION leaves `params` only when a handler is found.
local function signed_handler(command, params)
	local handlers = S.signed_commands
	if type(handlers) ~= "table" then return nil end
	local name = command
	if name == "LUA_ACTION" and params.ACTION then name = params.ACTION end
	name = (string.gsub(tostring(name or ""), "%s+", "_"))
	local fn = handlers[name]
	if type(fn) ~= "function" then return nil end
	if command == "LUA_ACTION" then params.ACTION = nil end
	return fn, name
end

-- One signed `execute` command: the driver's development command of that
-- name when it has one, else the driver's ExecuteCommand as Director would
-- call it (Composer's actions, the messages devices send). Both are looked
-- up now, because a reload replaces them. Returns nil, or the error text
-- for the command_done report. No other driver can reach this: it is a
-- function of this Lua state, not an entry point Director calls.
function devloop.execute(command, params)
	params = type(params) == "table" and params or {}
	local fn, name = signed_handler(command, params)
	if fn then
		local ok, err = pcall(fn, params)
		if ok then return nil end
		say("signed command %s failed: %s", name, tostring(err))
		return tostring(err)
	end
	local entry = rawget(_G, "ExecuteCommand")
	if type(entry) ~= "function" then return "no ExecuteCommand" end
	local ok, err = pcall(entry, command, params)
	return (not ok) and tostring(err) or nil
end

-- A command can stop the loop or move it to another server: devctl.py set
-- "Dev Server" "" (or another host:port) reaches the driver's property
-- handler, which calls devloop.stop() (or devloop.start(host)). Stopping
-- there and then would drop the command's own command_done report, and the
-- server would keep the command pending for ever (the Hue project's issue
-- #239). So while `fn` runs the command, stop() and start() only note where
-- the loop should end up (S.held: the host, "" to stop), and run_command
-- acts on the note once the report has left. `fn` returns nil or the error
-- text; so does this, and a raise becomes the error text.
local function holding(fn)
	S.holding, S.held = true, nil
	local ok, err = pcall(fn)
	S.holding = false
	if not ok then return tostring(err) end
	return err
end

local function run_command(cmd, done)
	local started = now_ms()
	local function complete(err)
		S.last_command_id = math.max(S.last_command_id, tonumber(cmd.id) or 0)
		local extra = { command_id = cmd.id, error = err, elapsed_ms = now_ms() - started }
		local held = S.held
		S.held = nil
		if held == nil then return report("command_done", extra, done) end
		-- The command stopped the loop or moved it. Its report is on its way
		-- to the server it came from (the transfer has started; the loop's
		-- stop or move drops only its reply); the rest of the list stays
		-- queued there for the loop's next start.
		report("command_done", extra)
		devloop.start(held)
	end
	-- Entry points are looked up at call time: a reload replaces them.
	if cmd.type == "execute" then
		complete(holding(function() return devloop.execute(cmd.command, cmd.params) end))
	elseif cmd.type == "set_property" then
		local name = tostring(cmd.name)
		local value = cmd.value == nil and "" or tostring(cmd.value)
		complete(holding(function()
			C4:UpdateProperty(name, value)
			-- Director updates Properties before OnPropertyChanged; do the same.
			local props = rawget(_G, "Properties")
			if type(props) == "table" then props[name] = value end
			local fn = rawget(_G, "OnPropertyChanged")
			if type(fn) == "function" then fn(name) end
		end))
	elseif cmd.type == "reload" then
		-- Also a way to retry a refused version at once (a key fixed on the
		-- server, say): the next tick fetches it again.
		S.refused = {}
		if S.bundle then return apply_bundle(S.bundle, S.version, complete) end
		if not S.tree then return complete("this device's tree is not known yet") end
		fetch_bundle(S.tree, function(bundle, err)
			if not bundle then return complete(err) end
			apply_bundle(bundle.files, bundle.version, complete)
		end)
	else
		complete("unknown command type " .. tostring(cmd.type))
	end
end

-- Commands in order; one whose id is not above the last one run was run
-- already this load (or is replayed) and is skipped.
local function run_queue(commands, index)
	local cmd = commands[index]
	if type(cmd) ~= "table" then return step_log() end
	if (tonumber(cmd.id) or 0) <= S.last_command_id then return run_queue(commands, index + 1) end
	run_command(cmd, function() run_queue(commands, index + 1) end)
end

-- GET /commands with a fresh nonce; nothing runs unless the answer verifies
-- and carries that nonce, so a recorded answer cannot be replayed. A refused
-- answer is said once per streak. Without a key there is nothing to verify
-- with: no request (start() said so).
local function step_commands()
	if not KEY then return step_log() end
	local nonce = new_nonce()
	request("GET", "/commands?after=" .. tostring(S.last_command_id) .. "&nonce=" .. nonce, nil, function(r)
		if not r.ok then return step_log() end
		local payload, mac = devloop.split_envelope(r.body)
		local why = devloop.check_signature("commands", payload, mac)
		local list
		if not why then
			local ok, j = pcall(function() return C4:JsonDecode(payload) end)
			if not ok or type(j) ~= "table" then
				why = "malformed payload"
			elseif j.nonce ~= nonce then
				why = "the answer is for another request (replayed?)"
			else
				list = j.commands
			end
		end
		if why then
			if not S.commands_refused then say("commands refused: %s", why) end
			S.commands_refused = true
			return step_log()
		end
		S.commands_refused = false
		if type(list) ~= "table" then return step_log() end
		run_queue(list, 1)
	end, true)
end

-- Whether the server answered `tree` itself: a manifest with a version that
-- names the tree. Anything else (an unknown tree is a 400) is said once per
-- tree and streak, then ignored until the server has it.
local function served(tree, r, what)
	local j = r.json
	if r.ok and type(j) == "table" and j.version ~= nil and j.tree == tree then
		S.no_tree[tree] = false
		return j
	end
	if not S.no_tree[tree] then
		say("server has no %s tree (%s); %s", tree,
			tostring(r.err or (type(j) == "table" and j.tree) or "malformed manifest"), what)
		S.no_tree[tree] = true
	end
	return nil
end

-- One forwarded tree: fetch a changed version once and verify it, then
-- forward it (from the held bundle while the version stays the same) to the
-- bound devices running its driver that lack it.
local function step_tree(tree, next_step)
	request("GET", "/manifest?tree=" .. tree, nil, function(r)
		local j = served(tree, r, tree .. " devices are not updated")
		if not j then return next_step() end
		local version = tostring(j.version)
		local held = S.trees[tree]
		if held and held.bundle and version == held.version then
			forward_tree(tree, held.bundle, held.version)
			return next_step()
		end
		if recently_refused(tree, version) then return next_step() end
		fetch_bundle(tree, function(bundle, err, refused)
			if refused then return refuse(tree, version, err, next_step) end
			if not bundle then
				say("%s %s", tree, err)
				return next_step()
			end
			S.refused[tree] = nil
			forward_tree(tree, bundle, bundle.version)
			next_step()
		end)
	end)
end

-- The forwarded trees in turn (a well-formed name, never this device's
-- own), then the commands.
local function step_forwarded(index)
	local trees = type(devloop.TREES) == "table" and devloop.TREES or {}
	local tree = trees[index]
	if tree == nil then return step_commands() end
	if type(tree) ~= "string" or not tree:match("^[%w_]+$") or tree == S.tree then
		return step_forwarded(index + 1)
	end
	step_tree(tree, function() step_forwarded(index + 1) end)
end

local function step_rest()
	step_forwarded(1)
end

-- A device that could not tell its tree from its driver file name asks
-- without one and takes the tree the server names, which it does only while
-- it serves exactly one (tools/devserver.py answers 400 otherwise).
local function adopt_tree(r)
	local j = r.json
	if r.ok and type(j) == "table" and type(j.tree) == "string" and j.tree:match("^[%w_]+$") then
		S.tree = j.tree
		S.no_tree[""] = false
		say("polling for the %s tree, the server's only one", S.tree)
		return true
	end
	if not S.no_tree[""] then
		say("the server names no single tree to poll for (%s); this device is not updated", tostring(r.err or "no tree"))
		S.no_tree[""] = true
	end
	return false
end

-- This device's own tree. No answer at all, or a server error, is an
-- unreachable server (said once per change), and the tick ends there; a
-- server that answers without this tree (400) is said once and the tick goes
-- on to the commands and the log.
local function step_manifest()
	request("GET", S.tree and ("/manifest?tree=" .. S.tree) or "/manifest", nil, function(r)
		if r.code == nil or r.code >= 500 then
			if not S.unreachable then
				say("server %s unreachable: %s", S.host, tostring(r.err))
				S.unreachable = true
			end
			S.busy = false
			return
		end
		if S.unreachable then
			say("server %s reachable again", S.host)
			S.unreachable = false
		end
		if S.tree == nil and not adopt_tree(r) then return step_rest() end
		local j = served(S.tree, r, "this device is not updated")
		if not j then return step_rest() end
		local tree, version = S.tree, tostring(j.version)
		if version == S.version or recently_refused(tree, version) then return step_rest() end
		fetch_bundle(tree, function(bundle, err, refused)
			if refused then return refuse(tree, version, err, step_rest) end
			if not bundle then
				say("%s", err)
				return step_rest()
			end
			S.refused[tree] = nil
			apply_bundle(bundle.files, bundle.version, step_rest)
		end)
	end)
end

local function tick()
	if S.busy then
		S.busy_ticks = S.busy_ticks + 1
		if S.busy_ticks < devloop.STUCK_TICKS then return end
		say("previous tick still in flight after %d ticks; abandoning it", S.busy_ticks)
		S.gen = S.gen + 1 -- its callbacks are dropped from here on
	end
	S.busy, S.busy_ticks = true, 0
	step_manifest()
end

-- Public API ------------------------------------------------------------------

function devloop.stop()
	-- Called by a command the loop runs: its report goes first (holding).
	if S.holding then
		S.held = ""
		return
	end
	if S.timer then
		pcall(function() S.timer:Cancel() end)
		S.timer = nil
	end
	S.gen = S.gen + 1
	S.busy = false
	if S.host then
		say("stopped")
		S.host = nil
	end
	unwrap_print()
	unwrap_update_property()
end

-- Returns true when the loop is running afterwards. A package without a
-- dev key still runs the loop (log and reports reach the server, which can
-- then say what is wrong) but refuses every bundle and command.
function devloop.start(host_port)
	host_port = tostring(host_port or ""):match("^%s*(.-)%s*$")
	if host_port == "" then
		devloop.stop()
		return false
	end
	-- Called by a command the loop runs: its report goes first (holding).
	-- The same host as now cancels a stop the command asked for before.
	if S.holding then
		if S.timer and S.host == host_port then S.held = nil else S.held = host_port end
		return true
	end
	if S.timer and S.host == host_port then return true end
	devloop.stop()
	S.host = host_port
	S.gen = S.gen + 1
	S.busy, S.busy_ticks, S.unreachable = false, 0, false
	-- Read here, at late init or later: GetDeviceID must not be called
	-- during OnDriverInit [verified: API docs, 22_miscellaneous/_11-GetDeviceID],
	-- and the file name is available from OS 3.3.0
	-- [verified: API docs, 22_miscellaneous/_13.5-GetDriverFileName].
	S.tree = devloop.own_tree()
	local id_ok, id = pcall(function() return C4:GetDeviceID() end)
	S.device_id = id_ok and id or nil
	wrap_print()
	wrap_update_property()
	S.timer = C4:SetTimer(devloop.INTERVAL_MS, function() guarded(tick) end, true)
	say("started against http://%s", host_port)
	if not S.tree then
		say("the driver file name (%s) names no tree; asking the server for its only one", tostring(driver_file()))
	end
	if not KEY then say("%s: every bundle and command will be refused", KEY_PROBLEM) end
	-- The startup report is the first chain, so the first tick waits for it.
	S.busy = true
	report("startup", { sandbox = sandbox_facts() }, function() S.busy = false end)
	return true
end

function devloop.running()
	return S.timer ~= nil
end

-- The driver's development commands, keyed by dispatch name ("Fan_Request";
-- nil for none), which devloop.execute runs for signed `execute` commands.
-- The driver hands them over at every load of its driver.lua, a reload's
-- included, so they belong to the code running now; a reload that fails
-- before that keeps the previous ones, as it keeps the previous
-- ExecuteCommand. The driver's own code sets them; no message can.
function devloop.set_signed_commands(handlers)
	S.signed_commands = type(handlers) == "table" and handlers or nil
end

-- The driver's log line filter: fn(line) returns what of the line may leave
-- the controller, nil for nothing (see redacted() above); nil removes it.
-- Kept across a reload until the new code installs its own, so the secret
-- the old code held stays covered meanwhile.
function devloop.set_redactor(fn)
	S.redactor = type(fn) == "function" and fn or nil
end

-- What of `line` would leave the controller, as capture and the log
-- shipping decide it: the line itself, the redactor's version, nil, or
-- devloop.WITHHELD. Never raises.
function devloop.redacted(line)
	return redacted(line)
end

function devloop.version()
	return S.version
end

-- Version last forwarded for `tree`, nil while none was.
function devloop.tree_version(tree)
	local held = S.trees[tostring(tree)]
	return held and held.version or nil
end

-- The Hue loop's name for tree_version("light"), kept so its interface
-- stays whole.
function devloop.light_version()
	return devloop.tree_version("light")
end

-- This driver's tree: "modernforms_fan" for modernforms_fan.c4z; nil when
-- the driver file name says nothing usable.
function devloop.own_tree()
	return tree_of_file(driver_file())
end

-- A forwarded device's DEV_RELOAD handler: `params` are the strings the
-- polling device sent, { tree, version, bundle = "<signed JSON payload>",
-- mac = "<its MAC>" }. Verifies the bundle with this package's own key, then
-- runs the reload sequence at the signed version; the outcome goes through
-- print (the device has no server to report to). Returns true and the
-- version on success, else false and "skipped" (another tree), "refused"
-- (with why: unsigned, a wrong signature, signed for another tree, a device
-- that polls for itself) or "failed". A refusal tears nothing down, so a
-- DEV_RELOAD from any other driver changes nothing.
function devloop.apply_forwarded(params)
	params = type(params) == "table" and params or {}
	local own = devloop.own_tree()
	local kind = own or "device"
	-- Devices of several drivers can share the binding; a bundle for another
	-- driver's tree is not ours.
	if params.tree and own and params.tree ~= own then
		say("%s reload skipped: DEV_RELOAD carries the %s tree", kind, tostring(params.tree))
		return false, "skipped"
	end
	-- A device that runs the loop takes its code from the loop alone.
	if S.timer then
		local why = "this device polls the dev server itself"
		say("%s reload refused: %s", kind, why)
		return false, "refused", why
	end
	local why = devloop.check_signature("bundle", params.bundle, params.mac)
	if why then
		say("%s reload refused: %s", kind, why)
		return false, "refused", why
	end
	local ok, j = pcall(function() return C4:JsonDecode(params.bundle) end)
	if not ok or type(j) ~= "table" or type(j.files) ~= "table" then
		say("%s reload failed: the signed bundle does not decode", kind)
		return false, "failed"
	end
	-- The signed tree decides: this driver's own, and nothing when this
	-- driver cannot tell its tree.
	if not own then
		why = "this driver's tree is unknown"
	elseif j.tree ~= own then
		why = "signed for the " .. tostring(j.tree) .. " tree"
	end
	if why then
		say("%s reload refused: %s", kind, why)
		return false, "refused", why
	end
	local version = tostring(j.version)
	say("%s reloading to version %s (%d files)", kind, version, count_files(j.files))
	local err = reload(j.files, version)
	if err then
		say("%s reload failed: %s", kind, err)
		return false, "failed"
	end
	say("%s reload complete: version %s", kind, version)
	return true, version
end

-- A forwarded device's DEV_RELOAD handler (dispatch.commands["DEV_RELOAD"])
-- for the driver whose source tree is `tree`; `log` is the driver's
-- common.log. Release builds register none, since they have no devloop
-- module.
function devloop.reload_handler(log, tree)
	return function(params)
		params = params or {}
		-- Devices of several drivers can share the binding; a bundle for
		-- another tree is not ours.
		if params.tree and params.tree ~= tree then
			return log.debug("DEV_RELOAD for the %s tree ignored", tostring(params.tree))
		end
		-- On success the new code is already running; this handler and its
		-- log module are the old instance's, still good for one more line.
		-- The failure detail went through devloop's own print, which is not
		-- forwarded.
		local ok, outcome, why = devloop.apply_forwarded(params)
		if ok then
			log.always("%s reloaded to version %s", tree, tostring(outcome or params.version))
		elseif outcome == "refused" then
			log.warn("%s reload refused (%s); see this device's Lua output", tree, tostring(why))
		else
			log.warn("%s reload failed; see this device's Lua output", tree)
		end
	end
end

-- Forwarded-device log forwarding ---------------------------------------------

-- Dev builds: every line a forwarded device logs, debug excepted, also goes
-- to its polling device as DEV_LOG { source, line }, so the loop shows the
-- devices' output next to its own (docs/dev-loop.md). `log` is the driver's
-- common.log and `prefix` its log prefix; `get_parent` and `get_source`
-- answer the polling device's id and a short name for this device's lines,
-- nil while unknown. Lines logged before the polling device is known wait,
-- newest LOG_BUFFER kept, and go out when the returned flush function runs.
-- Release builds have no devloop module and leave log.sink alone.
function devloop.forward_logs(log, prefix, get_parent, get_source)
	local previous_sink = log.sink
	local original_print = print -- the driver's print as it is now, for a failure the sink must not see
	-- The driver's runtime as it is now: the one C4 for the life of the Lua
	-- state on the controller; in a test harness where drivers loaded one
	-- after another share common.log, the sink an earlier driver installed
	-- keeps sending through that driver's runtime, as its upvalues did.
	local c4 = C4
	local pending = {}
	local send_failed = false

	-- Only lines our own logger produced: "[LEVEL] <prefix>: ..." or, from
	-- log.always, "<prefix>: ...". On the controller that is every line; a
	-- test harness shares one common.log between drivers, where forwarding
	-- another driver's output would echo back and forth.
	local OWN_PLAIN = "^" .. prefix .. ": "
	local OWN_LEVELED = "^%[%u+%] " .. prefix .. ": "
	local function own_line(line)
		return line:find(OWN_PLAIN) ~= nil or line:find(OWN_LEVELED) ~= nil
	end

	-- A failing send is said once per failure streak, through print alone,
	-- so it cannot feed back into the forwarding.
	local function send_log(line)
		local ok, err = pcall(function()
			c4:SendToDevice(get_parent(), devloop.LOG_COMMAND, { source = get_source(), line = line }, false, false)
		end)
		if ok then
			send_failed = false
		elseif not send_failed then
			send_failed = true
			original_print("[WARN] " .. prefix .. ": log forwarding to the polling device failed: " .. tostring(err))
		end
	end

	log.sink = function(line)
		previous_sink(line)
		line = tostring(line)
		if line:sub(1, 7) == "[DEBUG]" or not own_line(line) then
			return
		end
		if get_parent() then
			send_log(line)
		else
			pending[#pending + 1] = line
			if #pending > devloop.LOG_BUFFER then
				table.remove(pending, 1)
			end
		end
	end

	return function()
		local lines = pending
		pending = {}
		for _, line in ipairs(lines) do
			send_log(line)
		end
	end
end

return devloop
