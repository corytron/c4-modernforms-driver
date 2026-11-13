-- fan/transport.lua: the one-request-in-flight HTTP slot over C4:url
-- (docs/v1-design.md sections 9.4, 3.2, 3.3 and 4.2; V6). A fan's Wi-Fi module
-- has a tiny TCP stack that freezes under load (MFR 8), so there is never more
-- than one request in flight per fan, GAP_MS between the end of one and the
-- start of the next, and no retry of its own: the model decides what follows.
--
-- It knows the call, the answer's class and the clock; it knows nothing of the
-- fan's state (that is fan/wire.lua's and the model's) beyond whether an answer
-- on /mf names its fan at all. Everything that
-- touches Director comes in through new(): `url` (a factory for C4:url()),
-- `timer` and `now`, so a spec drives it with a virtual clock.
--
-- Cancel() is never relied on and never called: it does not end an active
-- transfer on OS 3.4.2 (section 3.2, the Hue project's measurement). A request
-- given up (a new address, stop()) is only forgotten: its answer, when it
-- comes, finds a newer epoch and is dropped unread (section 4.2; ECM P9).
--
-- What comes back is bounded before Director gathers it (#214): redirects are
-- refused (C4:url would follow them by itself), and so are a body over
-- wire.MAX_BODY_BYTES and a compressed one. OnHeaders and OnBodyChunk do it by
-- returning true, which aborts the transfer [verified: API 35_url/_9-OnHeaders,
-- 35_url/_7-OnBodyChunk; hardware OS 3.4.2 in the Hue project, whose event
-- stream aborts this way]. They start nothing: a transfer started from inside
-- OnHeaders fails at once (the Hue project's curl error 2).

local wire = require("fan.wire")

local transport = {}
transport.__index = transport

transport.GAP_MS = 250            -- section 3.4: ASSUMED, K13 times it
transport.TIMEOUT_S = 5           -- the whole transfer; AIO's 5 s (MFR 8)
transport.CONNECT_TIMEOUT_S = 3
transport.REBOOT_TIMEOUT_S = 3    -- the fan answers nothing (MFR 2.3)
transport.MAX_TIMEOUT_S = 30      -- a caller's mistake must not hold a Director slot for the default 300 s

local KINDS = { state = true, info = true, command = true, g4 = true, reboot = true }

-- The log argument may lack a level; a raising sink must not reach Director.
local function say(self, level, fmt, ...)
	local fn = self._log[level]
	if fn then
		pcall(fn, fmt, ...)
	end
end

-- opts: now() -> ms, timer(ms, cb) -> object with :Cancel(), url() -> C4:url()
-- (a new transfer object each call), on_idle() (optional), log (optional,
-- common/log.lua's shape). Fields to read: epoch, seq (the last number
-- issued), address.
function transport.new(opts)
	opts = opts or {}
	assert(type(opts.now) == "function", "transport.new: opts.now is required")
	assert(type(opts.timer) == "function", "transport.new: opts.timer is required")
	assert(type(opts.url) == "function", "transport.new: opts.url is required")
	return setmetatable({
		epoch = 0,
		seq = 0,
		address = nil,
		_now = opts.now,
		_timer = opts.timer,
		_url = opts.url,
		_on_idle = opts.on_idle,
		_log = opts.log or {},
		_stopped = false,
		_inflight = nil,
		_gap = false,
		_gap_gen = 0,
		_gap_timer = nil,
	}, transport)
end

-- Gives up the request in flight, if any, and starts a new epoch. Nothing a
-- request of an earlier epoch does afterwards reaches a callback or the slot.
local function abandon(self, why)
	self.epoch = self.epoch + 1
	local entry = self._inflight
	if entry then
		entry.abandoned = true
		self._inflight = nil
		say(self, "debug", "fan #%d abandoned: %s", entry.seq, why)
	end
end

local function cancel_gap(self)
	self._gap_gen = self._gap_gen + 1
	self._gap = false
	local timer = self._gap_timer
	self._gap_timer = nil
	if timer then
		pcall(timer.Cancel, timer)
	end
end

-- The Fan Address, trimmed ("" or nil: none). Always a new epoch, also when the
-- address is unchanged (Use Selected Fan; section 4.2), and it revives a stopped
-- transport (Fan Address typed back after it was cleared, section 3.5). Returns
-- true, or false and "invalid address" for text that is not a dotted IPv4
-- address (nothing is sent until a valid one is set). Does not touch the gap
-- after the last request: on_idle still follows it.
function transport:set_address(addr)
	local value
	local valid = true
	if type(addr) == "string" then
		if addr:find("%S") then
			value = wire.ipv4(addr)
			valid = value ~= nil
		end
	elseif addr ~= nil then
		valid = false
	end
	abandon(self, "the address changed")
	self.address = value
	self._stopped = false
	if valid then
		return true
	end
	return false, "invalid address"
end

-- A request in flight, or the gap after it not over.
function transport:busy()
	return self._inflight ~= nil or self._gap
end

-- OnDriverDestroyed or Fan Address cleared: nothing in flight counts any more,
-- no on_idle is called again, send() refuses until set_address() is called.
function transport:stop()
	self._stopped = true
	abandon(self, "stopped")
	cancel_gap(self)
end

-- Classifying an answer (section 3.3) ----------------------------------------------------

-- curl's code 28 is "operation timed out"; the message wording differs between
-- curl builds ("Timeout was reached", "Operation timed out after ...", and
-- "Connection timed out" under code 7 when the SYN is never answered).
local function timed_out(err_code, err_msg)
	if err_code == 28 then
		return true
	end
	local text = type(err_msg) == "string" and err_msg:lower() or ""
	return text:find("timed out", 1, true) ~= nil or text:find("timeout", 1, true) ~= nil
		or text:find("time out", 1, true) ~= nil
end

local function result_of(entry, now)
	return { seq = entry.seq, epoch = entry.epoch, kind = entry.kind, ok = false, ms = now - entry.t0 }
end

-- Every answer of /mf names its fan (section 3.3, last row; MFR 2.4): without a
-- clientId it is no fan's answer. The Gen 4 probe's answer on /device has none,
-- and a reboot's answer is not read, so they are exempt. This is the only field
-- the transport looks at; whose clientId it is, is the model's (wire.same_fan).
local NAMES_ITS_FAN = { state = true, info = true, command = true }

local function names_its_fan(obj)
	local id = obj.clientId
	return type(id) == "string" and id:find("%S") ~= nil
end

local function is_redirect(code)
	code = tonumber(code)
	return code ~= nil and code >= 300 and code <= 399
end

local function redirect_refused(code)
	return { err = "http", code = code,
		detail = string.format("the fan answered with a redirect; not followed (HTTP %d)", code) }
end

-- Why the answer is refused unread, or nil: the refusal recorded while it
-- arrived (OnHeaders, OnBodyChunk), else a redirect among the responses even
-- so, in case an abort was not honoured and the transfer went on.
local function refusal_of(entry, responses)
	if entry.refused then
		return entry.refused
	end
	if type(responses) == "table" then
		for _, response in ipairs(responses) do
			if type(response) == "table" and is_redirect(response.code) then
				return redirect_refused(tonumber(response.code))
			end
		end
	end
	return nil
end

-- The body as OnBodyChunk gathered it; response.body only if no chunk came
-- (Director leaves it out once OnBodyChunk is set, API 35_url/_6-OnBody), and
-- wire.decode caps that too.
local function body_of(entry, response)
	if entry.chunked then
		return table.concat(entry.parts)
	end
	return response.body
end

-- err_code 0 and a 200 whose body is a JSON object is ok; everything else is a
-- failure with one class (never both ok and err).
local function classify(entry, now, responses, err_code, err_msg)
	local result = result_of(entry, now)
	local refused = refusal_of(entry, responses)
	if refused then
		local last = type(responses) == "table" and responses[#responses] or nil
		result.err = refused.err
		result.code = refused.code or (type(last) == "table" and tonumber(last.code)) or nil
		result.detail = refused.detail
		return result
	end
	err_code = tonumber(err_code) or 0
	if err_code ~= 0 then
		result.err = timed_out(err_code, err_msg) and "timeout" or "connect"
		result.detail = string.format("transfer error %d: %s", err_code, wire.log_text(err_msg or ""))
		return result
	end
	local response = type(responses) == "table" and responses[#responses] or nil
	if type(response) ~= "table" or type(response.code) ~= "number" then
		result.err = "connect"
		result.detail = "no response"
		return result
	end
	result.code = response.code
	if response.code ~= 200 then
		result.err = "http"
		result.detail = "HTTP " .. tostring(response.code)
		return result
	end
	local obj, why, refusal = wire.decode(body_of(entry, response))
	if not obj then
		result.err = why
		result.detail = refusal or (why == "empty" and "empty body" or "not a JSON object")
		return result
	end
	if NAMES_ITS_FAN[entry.kind] and not names_its_fan(obj) then
		result.err = "json"
		result.detail = "no clientId"
		return result
	end
	result.ok = true
	result.json = obj
	return result
end

-- Delivering it ----------------------------------------------------------------------------

local function arm_gap(self, gap_ms)
	cancel_gap(self)
	self._gap = true
	local gen = self._gap_gen
	-- #141 LF-D7: a request may name its own gap (a fade step's). The contract
	-- keeps the rule that a timer's delay is above 0, so a gap of 0 becomes 1 ms
	-- [assumed: the SDK page of C4:SetTimer was not re-read for this; the rule is
	-- the contract's].
	local delay = gap_ms or transport.GAP_MS
	if delay < 1 then
		delay = 1
	end
	local ok, timer = pcall(self._timer, delay, function()
		if gen ~= self._gap_gen or self._stopped then
			return
		end
		self._gap = false
		self._gap_timer = nil
		if self._on_idle then
			local called, err = pcall(self._on_idle)
			if not called then
				say(self, "error", "fan transport: on_idle raised: %s", wire.log_text(err))
			end
		end
	end)
	if ok then
		self._gap_timer = timer
		return
	end
	-- No timer, no gap: better a request too soon than a slot that never opens.
	say(self, "error", "fan transport: could not arm the gap timer: %s", wire.log_text(timer))
	self._gap = false
	if self._on_idle then
		pcall(self._on_idle)
	end
end

-- The slot is free (and in its gap) before the callback runs, so a send() from
-- inside it is refused as busy; the gap is armed after it returns, unless it
-- stopped the transport.
local function finish(self, entry, result)
	if self._inflight == entry then
		self._inflight = nil
	end
	self._gap = true
	local ok, err = pcall(entry.cb, result)
	if not ok then
		say(self, "error", "fan #%d: the result handler raised: %s", entry.seq, wire.log_text(err))
	end
	if self._stopped then
		return
	end
	arm_gap(self, entry.gap_ms)
end

-- OnDone: once per transfer, dropped when its request was given up (new epoch,
-- stop()) or has been delivered already.
local function on_done(self, entry, responses, err_code, err_msg)
	if entry.abandoned or entry.finished then
		say(self, "debug", "fan #%d: a late or repeated answer is dropped", entry.seq)
		return
	end
	entry.finished = true
	local ok, result = pcall(function() return classify(entry, self._now(), responses, err_code, err_msg) end)
	entry.parts = nil
	if not ok then
		say(self, "error", "fan #%d: unreadable transfer result: %s", entry.seq, wire.log_text(result))
		result = result_of(entry, entry.t0)
		result.err = "connect"
		result.detail = "unreadable transfer result"
	end
	finish(self, entry, result)
end

-- Guarding what comes back (#214) ----------------------------------------------------------

-- A header's value by its name in any case, or nil. Without the
-- response_headers_duplicates option a value is a string [verified: API
-- 35_url/_13-SetOptions]; a list of them is read as its first.
local function header_of(headers, wanted)
	if type(headers) ~= "table" then
		return nil
	end
	for name, value in pairs(headers) do
		if type(name) == "string" and name:lower() == wanted then
			if type(value) == "table" then
				value = value[1]
			end
			if type(value) == "string" then
				return value
			end
			return nil
		end
	end
	return nil
end

local function too_big(code)
	return { err = "json", code = code,
		detail = string.format("the answer is over %d bytes; refused", wire.MAX_BODY_BYTES) }
end

-- OnHeaders, once per response [verified: API 35_url/_9-OnHeaders]: true
-- aborts the transfer. A 3xx is refused (C4:url would follow it by itself), so
-- is a Content-Length over the cap and a body that is not sent as it is (a
-- Content-Encoding other than identity; M0's answers carry none). Otherwise the
-- body of this response is gathered afresh.
local function check_headers(entry, response)
	if entry.refused then
		return true
	end
	local code = type(response) == "table" and tonumber(response.code) or nil
	if is_redirect(code) then
		entry.refused = redirect_refused(code)
		return true
	end
	local headers = type(response) == "table" and response.headers or nil
	-- White space is dropped with one gsub each: linear, whatever the value.
	local length = header_of(headers, "content-length")
	length = length and length:gsub("%s", "")
	if length and length:find("^%d+$") and tonumber(length) > wire.MAX_BODY_BYTES then
		entry.refused = too_big(code)
		return true
	end
	local encoding = header_of(headers, "content-encoding")
	encoding = encoding and encoding:gsub("%s", ""):lower()
	if encoding and encoding ~= "" and encoding ~= "identity" then
		entry.refused = { err = "json", code = code, detail = "the answer is compressed (Content-Encoding); refused" }
		return true
	end
	entry.parts, entry.bytes, entry.chunked = {}, 0, false
	return false
end

-- OnBodyChunk [verified: API 35_url/_7-OnBodyChunk]: with it set Director does
-- not gather the body, the transport does, and true aborts the transfer once
-- the bytes pass the cap. What is read of a response refused already is not
-- kept.
local function take_chunk(entry, response, chunk)
	if entry.refused then
		return true
	end
	if type(chunk) ~= "string" then
		return false
	end
	entry.bytes = (entry.bytes or 0) + #chunk
	if entry.bytes > wire.MAX_BODY_BYTES then
		entry.refused = too_big(type(response) == "table" and tonumber(response.code) or nil)
		entry.parts = nil
		return true
	end
	entry.parts = entry.parts or {}
	entry.parts[#entry.parts + 1] = chunk
	entry.chunked = true
	return false
end

-- A guard that raises must not reach Director, and must not let the answer
-- through unchecked: it aborts the transfer, which counts as refused.
local function guarded(self, entry, fn, ...)
	local ok, abort = pcall(fn, entry, ...)
	if ok then
		return abort == true
	end
	say(self, "error", "fan #%d: the answer guard raised: %s", entry.seq, wire.log_text(abort))
	entry.refused = entry.refused or { err = "connect", detail = "the answer could not be checked; refused" }
	return true
end

local function start_transfer(self, entry, request)
	local transfer = self._url()
	transfer:SetOptions({
		timeout = request.timeout,
		connect_timeout = transport.CONNECT_TIMEOUT_S,
		fail_on_error = false,
	})
	transfer:OnHeaders(function(_, response)
		return guarded(self, entry, check_headers, response)
	end)
	transfer:OnBodyChunk(function(_, response, chunk)
		return guarded(self, entry, take_chunk, response, chunk)
	end)
	transfer:OnDone(function(_, responses, err_code, err_msg)
		local ok, err = pcall(on_done, self, entry, responses, err_code, err_msg)
		if not ok then
			-- Whatever failed, the slot must not stay taken by this request.
			say(self, "error", "fan #%d: the transfer handler raised: %s", entry.seq, wire.log_text(err))
			if self._inflight == entry then
				self._inflight = nil
			end
		end
	end)
	entry.transfer = transfer
	local headers = {}
	for name, value in pairs(wire.HEADERS) do
		headers[name] = value
	end
	transfer:Post("http://" .. self.address .. request.path, request.body, headers)
end

-- The request as the slot will send it, or nil when it is not one of the five
-- kinds on their one path: the Gen 4 probe alone goes to /device, nothing goes
-- anywhere else (section 3.6).
local function checked(req, cb)
	if type(req) ~= "table" or type(cb) ~= "function" or not KINDS[req.kind] then
		return nil
	end
	if type(req.body) ~= "string" or req.body == "" then
		return nil
	end
	if req.path ~= (req.kind == "g4" and wire.G4_PATH or wire.PATH) then
		return nil
	end
	local timeout = tonumber(req.timeout)
	if not timeout or timeout <= 0 then
		timeout = req.kind == "reboot" and transport.REBOOT_TIMEOUT_S or transport.TIMEOUT_S
	end
	-- #141 LF-D7: the gap after this request's answer; anything that is not a
	-- number >= 0 is ignored and GAP_MS applies.
	local gap_ms = tonumber(req.gap_ms)
	if gap_ms ~= nil and (gap_ms ~= gap_ms or gap_ms < 0 or gap_ms == math.huge) then
		gap_ms = nil
	end
	return {
		kind = req.kind, path = req.path, body = req.body,
		timeout = math.min(timeout, transport.MAX_TIMEOUT_S), gap_ms = gap_ms,
	}
end

-- req = { kind = "state"|"info"|"command"|"g4"|"reboot", path = wire.PATH, or
-- wire.G4_PATH for "g4", body = string, timeout = seconds (default 5; 3 for a
-- reboot), gap_ms = the gap after this request's answer in ms (optional, >= 0,
-- default GAP_MS; #141 LF-D7, a fade step's) }. cb(result) runs once, from OnDone, never for a request of an
-- earlier epoch or after stop(), and never from inside send(). Returns the
-- request's number, or nil and why: "busy", "no address", "stopped",
-- "bad request" (not one of the five kinds with its path, or no body or
-- callback; nothing is sent) or "could not start" (the transfer failed to begin
-- and no timer could report that; a failure to begin that a timer can report
-- comes as a "connect" result instead).
--
-- result = { seq, epoch, kind, ok, code, json, err, detail, ms }: `code` the
-- HTTP status when one arrived; `json` the decoded object (wire.decode) when ok;
-- `err` nil, "timeout", "connect" (any other transfer error), "http" (a status
-- other than 200, the 404 on /mf that makes the model try the Gen 4 probe among
-- them, and a redirect, which is never followed: `code` the 3xx), "empty" or
-- "json" (the body is no JSON object, or on /mf it has no clientId, or it was
-- refused unread: over wire.MAX_BODY_BYTES, compressed, or nested deeper than
-- wire.MAX_DEPTH); `detail` a short text for the log, never part of an answer's
-- body, any transfer text in it cut (wire.log_text); `ms` the time from send()
-- to OnDone.
function transport:send(req, cb)
	if self._stopped then
		return nil, "stopped"
	end
	if not self.address then
		return nil, "no address"
	end
	if self:busy() then
		return nil, "busy"
	end
	local request = checked(req, cb)
	if not request then
		return nil, "bad request"
	end
	self.seq = self.seq + 1
	local entry = {
		seq = self.seq, epoch = self.epoch, kind = request.kind, cb = cb, t0 = self._now(),
		gap_ms = request.gap_ms,
	}
	self._inflight = entry
	say(self, "debug", "-> fan #%d %s %s", entry.seq, entry.kind, wire.log_text(request.body))
	local started, err = pcall(start_transfer, self, entry, request)
	if started then
		return entry.seq
	end
	-- The transfer could not begin: the usual failure, delivered from a timer so
	-- the caller gets its number first and send() never calls back.
	say(self, "warn", "fan #%d: could not start the transfer: %s", entry.seq, wire.log_text(err))
	local deferred = pcall(self._timer, 1, function()
		if entry.abandoned or entry.finished then
			return
		end
		entry.finished = true
		local result = result_of(entry, self._now())
		result.err = "connect"
		result.detail = "could not start the transfer"
		finish(self, entry, result)
	end)
	if not deferred then
		self._inflight = nil
		return nil, "could not start"
	end
	return entry.seq
end

return transport
