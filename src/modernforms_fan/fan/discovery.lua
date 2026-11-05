-- fan.discovery: Find Fans, the mDNS side (docs/v1-design.md section 9.10, V5a; K10 in section 11.1).
--
-- Three parts, none of which touches Director, so a spec runs them as they are:
--
--   * discovery.query() and discovery.parse(): the one DNS question the driver asks and the reader of the answers.
--     The wire format is RFC 1035 section 4 as multicast DNS (RFC 6762) uses it, written for the few records this
--     driver needs. parse reads datagrams that anyone on the LAN may have sent (the MULTICAST binding hears every
--     mDNS packet of the house, not only the fan's), so every read is bounds checked and nothing in it raises.
--   * discovery.candidates(): which addresses of a window's answers a follow may read (docs/address-follow-design.md
--     F4, 2.1).
--   * discovery.new(): the Find Fans window over four functions the driver wires to a dynamic network binding
--     (C4:CreateNetworkConnection, C4:NetConnect(binding, 5353, "MULTICAST") to 224.0.0.251, C4:SendToNetwork,
--     K10) and to C4:SetTimer. Find Fans and the follower share it.
--
-- What it does not do: adopt a fan. The list only offers fans; Use Selected Fan checks the identity (section 3.5),
-- and a follow reads the fan at a candidate address before anything moves (address-follow-design F4).

local discovery = {}

local SERVICE = { "_easylink", "_tcp", "local" } -- the service the fans announce on port 80 (MFR section 7)
local PROTOCOL = "com.modernforms.fan"           -- the TXT Protocol of a Modern Forms fan (M0, K10)

local TYPE_A, TYPE_PTR, TYPE_TXT, TYPE_SRV = 1, 12, 16, 33
local CLASS_IN = 1

local GROUP, PORT = "224.0.0.251", 5353 -- where mDNS queries go and where the answers come from (RFC 6762)

local MAX_HOPS = 16       -- compression pointers followed in one name (section 9.10)
local MAX_NAME = 255      -- octets of a name on the wire (RFC 1035 section 2.3.4)
local MAX_DATAGRAM = 9000 -- the largest multicast DNS message (RFC 6762 section 17)
local MAX_FOUND = 64      -- fans kept in one window; Found Fans lists 16 of them (section 7.3)
local MAX_HEARD = 8       -- (instance, address) pairs kept in one window for the follower (address-follow-design 2.1)
local MAX_CANDIDATES = 3  -- addresses a follow reads after one window (address-follow-design F4)
local HTTP_PORT = 80      -- the SRV port of a fan's /mf interface, the only one a follow reads (F4; MFR section 7)
local REPEAT_MS = 1000    -- the query goes out a second time this long after the first (section 9.10)
local WINDOW_MS = 3000    -- answers are collected this long after the first query (section 2.6)

discovery.GROUP, discovery.PORT = GROUP, PORT
discovery.MAX_HOPS, discovery.MAX_DATAGRAM, discovery.MAX_FOUND = MAX_HOPS, MAX_DATAGRAM, MAX_FOUND
discovery.MAX_HEARD, discovery.MAX_CANDIDATES = MAX_HEARD, MAX_CANDIDATES
discovery.REPEAT_MS, discovery.WINDOW_MS = REPEAT_MS, WINDOW_MS

-- The question ---------------------------------------------------------------------------------------------------

local function u16_bytes(n)
	return string.char(math.floor(n / 256) % 256, n % 256)
end

-- Id 0 and no flags, as RFC 6762 section 18.1 wants a multicast query (K10 sent an id of its own and was answered
-- all the same; the answers carried id 0). One question, PTR of the service, class IN with the top bit clear:
-- multicast answers, "QM" (K10; a unicast-response "QU" question was not tried).
local function build_query()
	local parts = { u16_bytes(0), u16_bytes(0), u16_bytes(1), u16_bytes(0), u16_bytes(0), u16_bytes(0) }
	for _, label in ipairs(SERVICE) do
		parts[#parts + 1] = string.char(#label) .. label
	end
	parts[#parts + 1] = "\0"
	parts[#parts + 1] = u16_bytes(TYPE_PTR)
	parts[#parts + 1] = u16_bytes(CLASS_IN)
	return table.concat(parts)
end

local QUERY = build_query()

function discovery.query()
	return QUERY
end

-- Reading a datagram ---------------------------------------------------------------------------------------------
-- Positions are 1-based string positions (a wire offset plus one). Past the end, reads give nil; none raises.

local function u16(s, i)
	local a, b = s:byte(i, i + 1)
	if not b then
		return nil
	end
	return a * 256 + b
end

-- Where the name that starts at pos ends in the record stream: after its root label, or after the compression
-- pointer that finishes it. Pointers are not followed, since the stream does not go on there (RFC 1035 4.1.4).
local function skip_name(s, pos)
	while true do
		local b = s:byte(pos)
		if not b then
			return nil
		elseif b == 0 then
			return pos + 1
		elseif b >= 192 then
			return s:byte(pos + 1) and pos + 2 or nil
		elseif b >= 64 then
			return nil -- 01 and 10 are reserved label types
		end
		pos = pos + 1 + b
	end
end

-- The name that starts at pos, as the list of its labels, and the position where the record stream goes on. nil
-- and a reason for anything that is not a name: a label or the name running past the datagram, a name over 255
-- octets, a reserved label type, a pointer into the header or past the end, more than MAX_HOPS pointers (which is
-- also what a pointer loop comes to). Work is bounded by the 255 octets and the 16 hops.
local function read_name(s, pos)
	local labels, count, total = {}, 0, 1 -- total counts the root's octet
	local resume, hops = nil, 0
	local size = #s
	while true do
		local b = s:byte(pos)
		if not b then
			return nil, "short"
		elseif b == 0 then
			return labels, resume or (pos + 1)
		elseif b < 64 then
			if pos + b > size then
				return nil, "short"
			end
			total = total + b + 1
			if total > MAX_NAME then
				return nil, "long"
			end
			count = count + 1
			labels[count] = s:sub(pos + 1, pos + b)
			pos = pos + b + 1
		elseif b >= 192 then
			local low = s:byte(pos + 1)
			if not low then
				return nil, "short"
			end
			hops = hops + 1
			if hops > MAX_HOPS then
				return nil, "loop"
			end
			resume = resume or (pos + 2)
			local target = (b - 192) * 256 + low
			if target < 12 or target >= size then
				return nil, "pointer"
			end
			pos = target + 1
		else
			return nil, "label"
		end
	end
end

-- A name compares without regard to case (RFC 1035 section 2.3.3) and by its labels, not by dots, since an
-- instance label may hold any byte: each label is length-prefixed in the key.
local function key_of(labels)
	local parts = {}
	for i, label in ipairs(labels) do
		parts[i] = string.char(#label) .. label:lower()
	end
	return table.concat(parts)
end

-- "<instance>._easylink._tcp.local": one instance label, then the service (RFC 6763 section 4.1).
local function is_instance(labels)
	if #labels ~= #SERVICE + 1 then
		return false
	end
	for i, part in ipairs(SERVICE) do
		if labels[i + 1]:lower() ~= part then
			return false
		end
	end
	return true
end

-- The strings of a TXT record's data as attributes (RFC 6763 section 6): the key is what comes before the first
-- "=", compared without regard to case, and the first of a key wins; a string without "=" is a key without a
-- value. nil when a string runs past the record's data. Data first..last, both inclusive.
local function read_txt(s, first, last)
	local attrs = {}
	local pos = first
	while pos <= last do
		local length = s:byte(pos)
		if pos + length > last then
			return nil
		end
		local text = s:sub(pos + 1, pos + length)
		pos = pos + 1 + length
		local eq = text:find("=", 1, true)
		local key = (eq and text:sub(1, eq - 1) or text):lower()
		if key ~= "" and attrs[key] == nil then
			attrs[key] = eq and text:sub(eq + 1) or true
		end
	end
	return attrs
end

-- Walks `count` resource records from pos (RFC 1035 section 4.1.3) and hands each to visit(type, class, ttl,
-- name_at, first, last) with the data at first..last. The cache-flush bit of the class (RFC 6762 section 10.2) is
-- cut off. Returns the position after them, or nil and why when the stream breaks off.
local function walk(s, pos, count, visit)
	for _ = 1, count do
		local after = skip_name(s, pos)
		if not after then
			return nil, "name"
		end
		local t1, t2, c1, c2, l1, l2, l3, l4, d1, d2 = s:byte(after, after + 9)
		if not d2 then
			return nil, "short"
		end
		local first = after + 10
		local last = first + d1 * 256 + d2 - 1
		if last > #s then
			return nil, "short"
		end
		if visit then
			local ttl = ((l1 * 256 + l2) * 256 + l3) * 256 + l4
			visit(t1 * 256 + t2, (c1 * 256 + c2) % 32768, ttl, pos, first, last)
		end
		pos = last + 1
	end
	return pos
end

-- 12 uppercase hex digits from a MAC, by the rule of wire.mac12 (section 9.3), kept here so this module needs no
-- other: white space trimmed, then 12 hex digits, or six pairs joined by one and the same ":" or "-".
local function mac12(text)
	-- A MAC is at most 17 characters; anything much longer is refused before the
	-- trim, whose pattern would rescan a long run of blanks (the text is a TXT
	-- record off the network).
	if type(text) ~= "string" or #text > 64 then
		return nil
	end
	local mac = text:match("^%s*(.-)%s*$")
	if mac:find("^%x%x%x%x%x%x%x%x%x%x%x%x$") then
		return mac:upper()
	end
	local a, _, b, c, d, e, f = mac:match("^(%x%x)([:%-])(%x%x)%2(%x%x)%2(%x%x)%2(%x%x)%2(%x%x)$")
	if not a then
		return nil
	end
	return (a .. b .. c .. d .. e .. f):upper()
end

-- Printable ASCII without the comma, cut to `limit`: a DYNAMIC_LIST item holds no comma (section 2.5), and what a
-- stranger's responder sends must not reach a Composer row or a log line as it is.
local function clean(text, limit)
	text = text:sub(1, limit)
	text = text:gsub("[^\32-\43\45-\126]", "?")
	return text
end

-- Unspecified, loopback, multicast and reserved addresses are no fan's; nothing here could reach them.
local function ipv4(a, b, c, d)
	if a == 0 or a == 127 or a >= 224 then
		return nil
	end
	return string.format("%d.%d.%d.%d", a, b, c, d)
end

-- One fan is a TXT record that says Protocol=com.modernforms.fan, the SRV record of the same instance and the A
-- record of the SRV's target, all in one datagram (K10: every answer held all four). PTR records are walked past:
-- the instance is named by the owner of its SRV and TXT records, so a PTR adds nothing they do not say.
local function parse_datagram(datagram)
	local found = {}
	if type(datagram) ~= "string" then
		return found, "type"
	end
	local size = #datagram
	if size < 12 then
		return found, "short"
	elseif size > MAX_DATAGRAM then
		return found, "large"
	end
	-- Only a plain response counts (RFC 6762 sections 18.2, 18.3, 18.11); the other flags are to be ignored.
	local flags = u16(datagram, 3)
	if flags < 32768 then
		return found, "query"
	elseif math.floor(flags / 2048) % 16 ~= 0 then
		return found, "opcode"
	elseif flags % 16 ~= 0 then
		return found, "rcode"
	end

	local txts, srvs, addrs = {}, {}, {}
	local function visit(rtype, class, ttl, name_at, first, last)
		-- A time to live of 0 withdraws a record (RFC 6762 section 10.1).
		if class ~= CLASS_IN or ttl == 0 or (rtype ~= TYPE_TXT and rtype ~= TYPE_SRV and rtype ~= TYPE_A) then
			return
		end
		local labels = read_name(datagram, name_at)
		if not labels then
			return
		end
		local key = key_of(labels)
		if rtype == TYPE_A then
			if last - first == 3 and not addrs[key] then
				addrs[key] = ipv4(datagram:byte(first, last))
			end
		elseif not is_instance(labels) then
			return
		elseif rtype == TYPE_SRV then
			local target, after = nil, nil
			if last - first >= 6 then
				target, after = read_name(datagram, first + 6)
			end
			if target and after <= last + 1 and not srvs[key] then
				srvs[key] = { port = u16(datagram, first + 4), host = key_of(target) }
			end
		else
			local attrs = read_txt(datagram, first, last)
			local protocol = attrs and attrs.protocol
			if type(protocol) == "string" and protocol:lower() == PROTOCOL then
				txts[#txts + 1] = { key = key, instance = labels[1], attrs = attrs }
			end
		end
	end

	-- Questions are skipped (a legacy unicast answer repeats them), then answers, authority and additional records
	-- alike; the section a record sits in does not matter here. A break in the stream ends the reading, and what
	-- was complete before it stays.
	local pos, why = 13, nil
	for _ = 1, u16(datagram, 5) do
		local after = skip_name(datagram, pos)
		if not after or after + 3 > size then
			pos, why = nil, "malformed"
			break
		end
		pos = after + 4
	end
	if pos then
		pos, why = walk(datagram, pos, u16(datagram, 7), visit)
	end
	if pos then
		pos, why = walk(datagram, pos, u16(datagram, 9), nil)
	end
	if pos then
		local _
		_, why = walk(datagram, pos, u16(datagram, 11), visit)
	end

	local seen = {}
	for _, txt in ipairs(txts) do
		local srv = srvs[txt.key]
		local address = srv and addrs[srv.host]
		if address and not seen[txt.key] then
			seen[txt.key] = true
			local firmware = txt.attrs["firmware rev"]
			found[#found + 1] = {
				instance = clean(txt.instance, 63),
				address = address,
				port = srv.port,
				mac = mac12(txt.attrs["mac"]),
				firmware = type(firmware) == "string" and firmware ~= "" and clean(firmware, 32) or nil,
			}
		end
	end
	return found, why
end

-- discovery.parse(datagram) -> list, why. The list is every Modern Forms fan the datagram describes, in the order
-- of their TXT records: { instance = "MF_Fan_005301", address = "10.0.2.151", port = 80, mac = "00005E005301",
-- firmware = "02.00.0052" } (mac and firmware nil when the TXT record lacks them or they are malformed). why is
-- nil for a well-formed response, even one about other services (an empty list), and a short reason for
-- anything else: "type", "short", "large", "query" (a question, such as our own echoed back), "opcode", "rcode",
-- "name", "malformed" (the stream broke off; the list holds what was complete before), "error". Never raises.
function discovery.parse(datagram)
	local ok, found, why = pcall(parse_datagram, datagram)
	if not ok then
		return {}, "error"
	end
	return found, why
end

-- What a follow may read -----------------------------------------------------------------------------------------

-- The four numbers of a dotted quad in the one spelling wire.ipv4 accepts (section 9.3) and ipv4() above writes:
-- decimal octets of 0 to 255 without a leading zero (a resolver may read "010" as octal). nil for anything else.
local function octets(text)
	if type(text) ~= "string" then
		return nil
	end
	local parts = { text:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$") }
	if #parts ~= 4 then
		return nil
	end
	for i, part in ipairs(parts) do
		if #part > 3 or (#part > 1 and part:sub(1, 1) == "0") or tonumber(part) > 255 then
			return nil
		end
		parts[i] = tonumber(part)
	end
	return parts
end

-- RFC 1918's private blocks (10/8, 172.16/12, 192.168/16) and the link-local block (169.254/16, RFC 3927): the
-- only addresses a follow reads (address-follow-design F4, F8). Any other, a public one above all, is what a
-- forged or lying answer would name (ECA FA11, 3.7).
local function private(o)
	local a, b = o[1], o[2]
	return a == 10 or (a == 172 and b >= 16 and b <= 31) or (a == 192 and b == 168) or (a == 169 and b == 254)
end

-- discovery.candidates(heard, mac12, current) -> { address, ... }: the addresses a follow reads after one window,
-- F4's first step (address-follow-design 2.1; ECA 3.4 step 1). From find's heard list, the entries whose TXT MAC
-- is the pinned MAC (12 hex digits, case aside; a MAC with ":" or "-" is read as parse reads one), whose SRV port
-- is 80 and whose address is a private or link-local IPv4 address other than `current` (the Fan Address in use):
-- their distinct addresses, in the order heard, at most MAX_CANDIDATES. Pure: heard is left as it was and nothing
-- is kept. A heard that is not a list, a pin without a MAC and entries that are not records give nothing; a nil
-- or empty current takes nothing away (the follower does not search then, F5). Never raises.
function discovery.candidates(heard, pin_mac, current)
	local found = {}
	local pin = mac12(pin_mac)
	if type(heard) ~= "table" or not pin then
		return found
	end
	if type(current) == "string" then
		current = current:match("^%s*(.-)%s*$") -- as the model trims a typed address (wire.ipv4)
	end
	local taken = {}
	for _, entry in ipairs(heard) do
		if #found >= MAX_CANDIDATES then
			break
		end
		if type(entry) == "table" and entry.port == HTTP_PORT and mac12(entry.mac) == pin then
			local address = entry.address
			local o = octets(address)
			if o and private(o) and address ~= current and not taken[address] then
				taken[address] = true
				found[#found + 1] = address
			end
		end
	end
	return found
end

-- The Find Fans window -------------------------------------------------------------------------------------------

local Finder = {}
Finder.__index = Finder

-- opts: open() makes the binding (an error or false says it could not; anything else is success), send(bytes)
-- sends one datagram to 224.0.0.251:5353 (false or an error: not sent), close() ends the binding, timer(ms, fn)
-- is C4:SetTimer (an object with :Cancel()), log is common.log. A missing or failing one lands on the same
-- paths as a refusal, so building a finder never raises.
function discovery.new(opts)
	opts = opts or {}
	return setmetatable({
		open = opts.open,
		send = opts.send,
		close = opts.close,
		timer = opts.timer,
		log = opts.log,
		window = nil,
	}, Finder)
end

function Finder:say(level, fmt, ...)
	local write = self.log and self.log[level]
	if type(write) == "function" then
		pcall(write, fmt, ...)
	end
end

local function cancel(timer)
	if timer ~= nil then
		pcall(function() timer:Cancel() end)
	end
end

local function tail(mac)
	return mac and ("..." .. mac:sub(-4)) or "...????"
end

-- Is a window open? (Find Fans while one runs joins it.)
function Finder:busy()
	return self.window ~= nil
end

function Finder:send_query(w)
	if self.window ~= w then
		return
	end
	local ok, result = pcall(self.send, QUERY)
	if ok and result ~= false then
		w.sent = w.sent + 1
	else
		self:say("warn", "Find Fans: the query was not sent (%s)", ok and "refused" or tostring(result))
	end
end

-- Closes the window: the binding once, the timers, then the callbacks with the list, an error word that is nil
-- unless nothing could be done: "open" (no binding), "timer" (no window possible) or "send" (no query went out and
-- no fan was heard), each a case for text L10 (section 7.2), and the heard list. Callbacks run after the window is
-- gone, so one may call find again.
function Finder:finish(w, err)
	if self.window ~= w then
		return
	end
	self.window = nil
	cancel(w.again)
	cancel(w.over)
	pcall(self.close)
	if err == nil and w.sent == 0 and #w.list == 0 then
		err = "send"
	end
	local tally = w.tally
	self:say("debug", "Find Fans: window over: sent=%d answers=%d other=%d queries=%d unparsed=%d fans=%d%s",
		w.sent, tally.answer, tally.other, tally.query, tally.unparsed, #w.list, err and (" failed=" .. err) or "")
	for _, callback in ipairs(w.callbacks) do
		local ok, problem = pcall(callback, w.list, err, w.heard)
		if not ok then
			self:say("error", "Find Fans: the callback failed: %s", tostring(problem))
		end
	end
end

-- find(callback): opens the binding, sends the query at once and again REPEAT_MS later, collects answers for
-- WINDOW_MS, closes the binding and calls callback(list, err, heard) once: the fans as parse describes them,
-- de-duplicated by instance (the first answer wins: what Find Fans shows), err as finish says, and heard, every
-- distinct (instance, address) pair of the window, up to MAX_HEARD, in the order heard, each { instance, address,
-- mac, port } (mac nil when the TXT record has none), for the follower (address-follow-design 2.1). Both lists
-- are empty when the window could not open. The callback also runs, at once, when the window cannot open. A find
-- while one runs adds its callback to that window: one binding, two queries, every callback told the same. Returns
-- false for a callback that is not a function. The first query goes out as soon as open returns; if a controller
-- drops it because the binding is not yet ONLINE (K10 saw 7 ms), the second one, a second later, answers that.
function Finder:find(callback)
	if type(callback) ~= "function" then
		return false, "callback"
	end
	local w = self.window
	if w then
		w.callbacks[#w.callbacks + 1] = callback
		return true
	end
	w = {
		callbacks = { callback },
		list = {},
		seen = {},
		heard = {},
		heard_seen = {},
		sent = 0,
		tally = { answer = 0, other = 0, query = 0, unparsed = 0 },
	}
	self.window = w

	local ok, result = pcall(self.open)
	if not ok or result == false then
		self:say("warn", "Find Fans: the network binding did not open (%s)", ok and "refused" or tostring(result))
		self:finish(w, "open")
		return true
	end
	-- The end of the window first, so that nothing below can leave it open.
	local armed, over = pcall(self.timer, WINDOW_MS, function() self:finish(w) end)
	if not armed then
		self:say("warn", "Find Fans: no timer for the window (%s)", tostring(over))
		self:finish(w, "timer")
		return true
	end
	w.over = over
	self:send_query(w)
	local again_ok, again = pcall(self.timer, REPEAT_MS, function() self:send_query(w) end)
	if again_ok then
		w.again = again
	end
	return true
end

-- stop(): OnDriverDestroyed. Ends an open window without calling its callbacks (as transport.stop does).
function Finder:stop()
	local w = self.window
	if not w then
		return
	end
	self.window = nil
	cancel(w.again)
	cancel(w.over)
	pcall(self.close)
end

-- One answer's pair for the heard list: kept when the window has not heard this instance at this address before
-- and holds fewer than MAX_HEARD. The list keeps an instance's first answer only, so a stale address heard first
-- would hide the fresh one (ECA FA11, 3.9); this keeps both. The instance compares as the list's does, the first
-- spelling is kept, and each entry is a record of its own, so the list's records stay the list's. `known` says
-- the instance was in the list before this answer: the one case the list's debug line does not cover.
local function hear(finder, w, key, fan, known)
	local pair = key .. "\0" .. fan.address -- neither a cleaned instance nor an address holds a NUL
	if w.heard_seen[pair] or #w.heard >= MAX_HEARD then
		return
	end
	w.heard_seen[pair] = true
	w.heard[#w.heard + 1] = { instance = fan.instance, address = fan.address, mac = fan.mac, port = fan.port }
	if known then
		finder:say("debug", "Find Fans: %s also at %s", tail(fan.mac), fan.address)
	end
end

-- received(binding, port, data, from): ReceivedFromNetwork for the discovery binding. The sender (`from`) comes
-- only from OS 4.0.0 (API 32_serial_network_device/_15-ReceivedFromNetwork.md) and is not needed: the A record
-- carries the fan's address. Everything outside a window, the controller's own query echoed back, other
-- services' records and what is not DNS is dropped. Returns what it made of the datagram, for the specs and the
-- debug line: "closed", "query", "answer", "other" or "unparsed".
function Finder:received(_binding, _port, data, _from)
	local w = self.window
	if not w then
		return "closed"
	end
	local tally = w.tally
	if data == QUERY then
		tally.query = tally.query + 1
		return "query"
	end
	local list, why = discovery.parse(data)
	if #list > 0 then
		tally.answer = tally.answer + 1
		for _, fan in ipairs(list) do
			local key = fan.instance:lower()
			local known = w.seen[key]
			if not known and #w.list < MAX_FOUND then
				w.seen[key] = true
				w.list[#w.list + 1] = fan
				self:say("debug", "Find Fans: %s at %s", tail(fan.mac), fan.address)
			end
			hear(self, w, key, fan, known)
		end
		return "answer"
	elseif why == "query" then
		tally.query = tally.query + 1
		return "query"
	elseif why then
		tally.unparsed = tally.unparsed + 1
		return "unparsed"
	end
	tally.other = tally.other + 1
	return "other"
end

return discovery
