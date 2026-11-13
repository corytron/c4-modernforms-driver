-- fan.discovery: the multicast DNS side of finding fans (docs/auto-discovery-design.md section 6.3; the wire in
-- docs/v1-design.md section 9.10; K10 in section 11.1).
--
-- Four parts, none of which touches Director, so a spec runs them as they are:
--
--   * discovery.query() and discovery.parse(): the one DNS question the driver asks and the reader of the answers.
--     The wire format is RFC 1035 section 4 as multicast DNS (RFC 6762) uses it, written for the few records this
--     driver needs. parse reads datagrams that anyone on the LAN may have sent (the MULTICAST binding hears every
--     mDNS packet of the house, not only the fan's), so every read is bounds checked and nothing in it raises.
--   * discovery.usable(): which answers are worth anything: SRV port 80 and a private or link-local IPv4 address.
--     The list keeps only these (auto-discovery-design section 3), and a follow reads only these.
--   * discovery.candidates(): which addresses of a window's answers a follow may read (docs/address-follow-design.md
--     F4, 2.1): the usable answers of the pinned MAC in the subnet of the address the fan last answered at
--     (discovery.same_subnet, #214).
--   * discovery.new(): the Finder, the one owner of the search window, over four functions the driver wires to a
--     dynamic network binding (C4:CreateNetworkConnection, C4:NetConnect(binding, 5353, "MULTICAST") to
--     224.0.0.251, C4:SendToNetwork, K10) and to C4:SetTimer. Two callers open windows through Finder:find: the
--     scheduler (fan/search.lua: a search at every load and, while no fan is set up or the set-up fan is away and
--     not followed, on a schedule) and the follower (fan/follow.lua: the pinned MAC, once the fan left Fan Address).
--     A find while a window is open joins it, so they never hold two at once. Every closed window, whoever opened
--     it, goes to on_window, which the driver wires to the list (fan/found.lua, the Found Fans property), and
--     Finder:last_closed() tells the scheduler when the last one ended (its floor, auto-discovery-design section 2).
--
-- What it does not do: adopt a fan. The list only offers fans; a pick or Use Selected Fan checks the identity
-- (v1-design section 3.5), and a follow reads the fan at a candidate address before anything moves
-- (address-follow-design F4).

local discovery = {}

local SERVICE = { "_easylink", "_tcp", "local" } -- the service the fans announce on port 80 (MFR section 7)
local PROTOCOL = "com.modernforms.fan"           -- the TXT Protocol of a Modern Forms fan (M0, K10)

local TYPE_A, TYPE_PTR, TYPE_TXT, TYPE_SRV = 1, 12, 16, 33
local CLASS_IN = 1

local GROUP, PORT = "224.0.0.251", 5353 -- where mDNS queries go and where the answers come from (RFC 6762)

local MAX_HOPS = 16       -- compression pointers followed in one name (section 9.10)
local MAX_NAME = 255      -- octets of a name on the wire (RFC 1035 section 2.3.4)
local MAX_DATAGRAM = 9000 -- the largest multicast DNS message (RFC 6762 section 17)
local MAX_RECORDS = 64    -- resource records read from one datagram, its sections together (#214). A fan's answer
                          -- holds four (K10: PTR, SRV, TXT, A); past 64 the reading stops as at a break, keeping
                          -- what was complete
local MAX_NAME_OCTETS = 2048 -- octets of names read from one datagram, a pointer hop counting 2 (#214): eight names
                             -- of the longest, where a fan's answer reads 116 to 176 (the K10 and Gen 1/2 layouts);
                             -- past it the reading stops as past MAX_RECORDS, however the names are built
-- The new names one window accepts (#214), the pinned fan's apart (MAX_PINNED). 32 instances and 32 (instance,
-- address, MAC) entries: Found Fans shows 16 rows (texts.MAX_FOUND), so 32 instances list every fan the owner can
-- see twice over, and 32 entries hold those 16 fans each at two addresses (a stale one and the fresh one, ECA FA11).
-- What comes after is not kept, whoever sent it: one window of forged answers can put no more than this into the
-- list (fan/found.lua) and its log line.
local MAX_FOUND = 32      -- instances kept in one window, the first answer of each
local MAX_HEARD = 32      -- entries kept in one window for the follower and the list (address-follow-design 2.1)
local MAX_PINNED = 4      -- entries (and instances) of the pinned MAC kept in one window beside those, so answers of
                          -- other MACs, forged or not, never crowd the pinned fan out (#214, review of #48): its
                          -- current address and the MAX_CANDIDATES a follow may read
local MAX_CANDIDATES = 3  -- addresses a follow reads after one window (address-follow-design F4)
-- What one window may spend on datagrams (#214). The binding hears every mDNS packet of the house while a window is
-- open, and anyone may send them; a fan answers each query with one datagram of about 300 bytes (K10) that parses in
-- far less than a millisecond, so the fans of a house and the usual chatter of other devices stay well below all
-- three. Past any of them the rest of the window's datagrams are dropped unread and counted (dropped= in the tally).
local WINDOW_DATAGRAMS = 256 -- datagrams parsed in one window
local WINDOW_BYTES = 262144  -- bytes parsed in one window: 256 datagrams of 1 KB, or 29 of the largest
local WINDOW_PARSE_MS = 250  -- now() spent parsing in one window: a twelfth of it
local HTTP_PORT = 80      -- the SRV port of a fan's /mf interface, the only one a follow reads (F4; MFR section 7)
local REPEAT_MS = 1000    -- the query goes out a second time this long after the first (section 9.10)
local WINDOW_MS = 3000    -- answers are collected this long after the first query (section 2.6)

discovery.GROUP, discovery.PORT = GROUP, PORT
discovery.MAX_HOPS, discovery.MAX_DATAGRAM, discovery.MAX_FOUND = MAX_HOPS, MAX_DATAGRAM, MAX_FOUND
discovery.MAX_RECORDS, discovery.MAX_NAME_OCTETS, discovery.MAX_PINNED = MAX_RECORDS, MAX_NAME_OCTETS, MAX_PINNED
discovery.MAX_HEARD, discovery.MAX_CANDIDATES = MAX_HEARD, MAX_CANDIDATES
discovery.WINDOW_DATAGRAMS, discovery.WINDOW_BYTES, discovery.WINDOW_PARSE_MS =
	WINDOW_DATAGRAMS, WINDOW_BYTES, WINDOW_PARSE_MS
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
-- also what a pointer loop comes to). Work is bounded by the 255 octets and the 16 hops, and by the datagram's
-- budget (MAX_NAME_OCTETS, #214): every label takes its octets from budget.octets and every hop 2; with none left
-- the name is not read ("budget") and budget.left (the records) is emptied, so the reading stops.
local function read_name(s, pos, budget)
	local labels, count, total = {}, 0, 1 -- total counts the root's octet
	local resume, hops = nil, 0
	local size = #s
	while true do
		if budget.octets <= 0 then
			budget.left = 0
			return nil, "budget"
		end
		local b = s:byte(pos)
		if not b then
			return nil, "short"
		elseif b == 0 then
			budget.octets = budget.octets - 1
			return labels, resume or (pos + 1)
		elseif b < 64 then
			if pos + b > size then
				return nil, "short"
			end
			total = total + b + 1
			if total > MAX_NAME then
				return nil, "long"
			end
			budget.octets = budget.octets - (b + 1)
			count = count + 1
			labels[count] = s:sub(pos + 1, pos + b)
			pos = pos + b + 1
		elseif b >= 192 then
			local low = s:byte(pos + 1)
			if not low then
				return nil, "short"
			end
			budget.octets = budget.octets - 2
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
-- cut off. Each record takes one of budget.left (the datagram's MAX_RECORDS, shared by its sections, and emptied
-- once its names have read MAX_NAME_OCTETS); with none left the walk stops ("records"). Returns the position after
-- them, or nil and why when the stream breaks off.
local function walk(s, pos, count, visit, budget)
	for _ = 1, count do
		if budget.left <= 0 then
			return nil, "records"
		end
		budget.left = budget.left - 1
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

-- Linear: "^%s*(.-)%s*$" rescans a long run of inner blanks at every step (#49).
local function trim(text)
	local first = text:find("%S")
	if not first then
		return ""
	end
	local last = #text
	while last > first and text:find("^%s", last) do
		last = last - 1
	end
	return text:sub(first, last)
end

-- 12 uppercase hex digits from a MAC, by the rule of wire.mac12 (section 9.3), kept here so this module needs no
-- other: white space trimmed, then 12 hex digits, or six pairs joined by one and the same ":" or "-".
local function mac12(text)
	-- A MAC is at most 17 characters; anything much longer is refused before the
	-- trim (the text is a TXT record off the network).
	if type(text) ~= "string" or #text > 64 then
		return nil
	end
	local mac = trim(text)
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

	-- What the datagram may still cost (#214): records (MAX_RECORDS) and octets of names (MAX_NAME_OCTETS).
	local budget = { left = MAX_RECORDS, octets = MAX_NAME_OCTETS }
	local txts, srvs, addrs = {}, {}, {}
	local function visit(rtype, class, ttl, name_at, first, last)
		-- A time to live of 0 withdraws a record (RFC 6762 section 10.1).
		if class ~= CLASS_IN or ttl == 0 or (rtype ~= TYPE_TXT and rtype ~= TYPE_SRV and rtype ~= TYPE_A) then
			return
		end
		local labels = read_name(datagram, name_at, budget)
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
				target, after = read_name(datagram, first + 6, budget)
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
	-- was complete before it stays; so does the end of the budget ("records", #214). Skipping questions reads each
	-- octet once at most, since a question's name is never followed through a pointer.
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
		pos, why = walk(datagram, pos, u16(datagram, 7), visit, budget)
	end
	if pos then
		pos, why = walk(datagram, pos, u16(datagram, 9), nil, budget)
	end
	if pos then
		local _
		_, why = walk(datagram, pos, u16(datagram, 11), visit, budget)
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
-- "name", "malformed" (the stream broke off; the list holds what was complete before), "records" (more than
-- MAX_RECORDS records, or more than MAX_NAME_OCTETS of names; the list holds what was complete before), "error".
-- Never raises.
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

-- discovery.usable(entry) -> bool: an answer worth anything, the filter of both the list (auto-discovery-design
-- section 3) and candidates below: a record whose SRV port is the number 80 (a fan's /mf interface; MFR section 7)
-- and whose address is a private or link-local IPv4 address in the one spelling parse writes. true or false, for
-- anything at all; never raises.
local function usable(entry)
	if type(entry) ~= "table" or entry.port ~= HTTP_PORT then
		return false
	end
	local o = octets(entry.address)
	return o ~= nil and private(o)
end

discovery.usable = usable

-- discovery.same_subnet(a, b) -> bool: two addresses in the one spelling parse writes, in one subnet (#214): the
-- same /24, or both in 169.254/16 (RFC 3927: the link-local block is one link). No documented API gives a driver
-- the LAN's netmask: C4:GetControllerNetworkAddress returns the controller's address alone
-- (API 32_serial_network_device/_5-GetControllerNetworkAddress.md), and GetMyNetworkAddress a binding's
-- (_9-GetMyNetworkAddress.md); so /24, the netmask of nearly every home LAN. false for anything else; never raises.
local function same_subnet(a, b)
	local x, y = octets(a), octets(b)
	if not x or not y then
		return false
	end
	if x[1] == 169 and x[2] == 254 then
		return y[1] == 169 and y[2] == 254
	end
	return x[1] == y[1] and x[2] == y[2] and x[3] == y[3]
end

discovery.same_subnet = same_subnet

-- discovery.candidates(heard, mac12, current, anchor) -> { address, ... }: the addresses a follow reads after one
-- window, F4's first step (address-follow-design 2.1; ECA 3.4 step 1). From find's heard list, the usable entries
-- (above: SRV port 80, a private or link-local IPv4 address) whose TXT MAC is the pinned MAC (12 hex digits, case
-- aside; a MAC with ":" or "-" is read as parse reads one), whose address is in the subnet of `anchor` (the address
-- the pinned fan last answered at; `current` when anchor is nil; same_subnet above, #214) and is not `current` (the
-- Fan Address in use): their distinct addresses, in the order heard, at most MAX_CANDIDATES. Pure: heard is left as
-- it was and nothing is kept. A heard that is not a list, a pin without a MAC, an anchor that is no address and
-- entries that are not records give nothing; a nil or empty current takes nothing away (the follower does not
-- search then, F5). Never raises.
function discovery.candidates(heard, pin_mac, current, anchor)
	local found = {}
	local pin = mac12(pin_mac)
	if type(heard) ~= "table" or not pin then
		return found
	end
	if type(current) == "string" then
		current = trim(current) -- as the model trims a typed address (wire.ipv4)
	end
	if anchor == nil then
		anchor = current
	elseif type(anchor) == "string" then
		anchor = trim(anchor)
	end
	if not octets(anchor) then
		return found -- no subnet known: nothing is read (#214)
	end
	local taken = {}
	for _, entry in ipairs(heard) do
		if #found >= MAX_CANDIDATES then
			break
		end
		if usable(entry) and mac12(entry.mac) == pin and same_subnet(anchor, entry.address) then
			local address = entry.address
			if address ~= current and not taken[address] then
				taken[address] = true
				found[#found + 1] = address
			end
		end
	end
	return found
end

-- The window -----------------------------------------------------------------------------------------------------

local Finder = {}
Finder.__index = Finder

-- opts: open() makes the binding (an error or false says it could not; anything else is success), send(bytes)
-- sends one datagram to 224.0.0.251:5353 (false or an error: not sent), close() ends the binding, timer(ms, fn)
-- is C4:SetTimer (an object with :Cancel()), now() is the clock in milliseconds (for last_closed and the parse
-- budget), on_window(list, err, heard) hears every closed window (see finish), pin() is the pinned fan's MAC (any
-- spelling mac12 reads; nil for none), whose answers keep places of their own (MAX_PINNED, #214), log is common.log.
-- A missing or failing one lands on the same paths as a refusal (no pin: no places kept apart; no clock: no time
-- budget), so building a finder never raises.
function discovery.new(opts)
	opts = opts or {}
	return setmetatable({
		open = opts.open,
		send = opts.send,
		close = opts.close,
		timer = opts.timer,
		now = opts.now,
		on_window = opts.on_window,
		pin = opts.pin,
		log = opts.log,
		window = nil,
		closed_at = nil,                -- now() when the last window ended (last_closed)
		notices = { draining = false }, -- closed windows waiting for on_window, in the order they closed (notify)
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

-- now() as a number, or nil when there is no clock or it gives none.
function Finder:clock()
	local ok, ms = pcall(self.now)
	if ok and type(ms) == "number" then
		return ms
	end
	return nil
end

-- The pinned fan's MAC as parse writes one (12 upper-case hex digits), or nil: no pin option, no pin, a pin without
-- a MAC, or an option that raises.
function Finder:pinned()
	if self.pin == nil then
		return nil
	end
	local ok, mac = pcall(self.pin)
	if not ok then
		return nil
	end
	return mac12(mac)
end

-- Is a window open? (A find while one runs joins it.)
function Finder:busy()
	return self.window ~= nil
end

-- last_closed() -> ms or nil: now() when the last window ended, whoever opened it, stop() included; nil before
-- any window has ended, without now, or when now gave no number then. The scheduler's floor (auto-discovery-design
-- section 2): no window of its own sooner than 30 s after any window of this device.
function Finder:last_closed()
	return self.closed_at
end

-- A window that could not open or send is logged here at debug only: the list warns once per streak, and the
-- follower too (auto-discovery-design section 2, "Failures"; ECA FA17), and the windows go on by themselves.
function Finder:send_query(w)
	if self.window ~= w then
		return
	end
	local ok, result = pcall(self.send, QUERY)
	if ok and result ~= false then
		w.sent = w.sent + 1
	else
		self:say("debug", "Search: the query was not sent (%s)", ok and "refused" or tostring(result))
	end
end

-- Hands the closed windows of `notices` to on_window, each once its callbacks are done and in the order they
-- closed: a callback or a listener that opens a window that ends at once (open refused) queues it behind the one
-- being told, rather than having it told first. stop() puts a new queue in place, so nothing queued before it
-- reaches on_window afterwards, and a drain stops there. A listener that raises is logged; the next is told.
function Finder:notify(notices)
	if self.notices ~= notices or notices.draining then
		return
	end
	notices.draining = true
	while self.notices == notices and notices[1] and notices[1].ready do
		local notice = table.remove(notices, 1)
		if self.on_window ~= nil then
			local ok, problem = pcall(self.on_window, notice.list, notice.err, notice.heard)
			if not ok then
				self:say("error", "Search: the window listener failed: %s", tostring(problem))
			end
		end
	end
	notices.draining = false
end

-- Closes the window: the binding once, the timers, the time it ended (last_closed), then the callbacks with the
-- list, an error word that is nil unless nothing could be done: "open" (no binding), "timer" (no window possible)
-- or "send" (no query went out and no fan was heard), each marking the list failing (auto-discovery-design
-- section 3) and a step not done for the follower (ECA FA17), and the heard list. Callbacks run after the window
-- is gone, so one may call find again. Then on_window, once for the window however many callers joined it, with
-- the same three values (the same tables the callbacks were given), unless stop() came first (notify).
function Finder:finish(w, err)
	if self.window ~= w then
		return
	end
	self.window = nil
	cancel(w.again)
	cancel(w.over)
	pcall(self.close)
	self.closed_at = self:clock()
	if err == nil and w.sent == 0 and #w.list == 0 then
		err = "send"
	end
	local tally = w.tally
	self:say("debug", "Search: window over: sent=%d answers=%d other=%d queries=%d unparsed=%d fans=%d%s%s",
		w.sent, tally.answer, tally.other, tally.query, tally.unparsed, #w.list,
		tally.dropped > 0 and (" dropped=" .. tally.dropped) or "", err and (" failed=" .. err) or "")
	-- The window's turn with on_window is taken before the callbacks run (notify says why).
	local notices = self.notices
	local notice = { list = w.list, err = err, heard = w.heard, ready = false }
	notices[#notices + 1] = notice
	for _, callback in ipairs(w.callbacks) do
		local ok, problem = pcall(callback, w.list, err, w.heard)
		if not ok then
			self:say("error", "Search: the callback failed: %s", tostring(problem))
		end
	end
	notice.ready = true
	self:notify(notices)
end

-- find(callback): opens the binding, sends the query at once and again REPEAT_MS later, collects answers for
-- WINDOW_MS, closes the binding and calls callback(list, err, heard) once: the fans as parse describes them,
-- de-duplicated by instance (the first answer wins), up to MAX_FOUND, err as finish says, and heard, every distinct
-- (instance, address, MAC) of the window, up to MAX_HEARD, in the order heard, each { instance, address, mac, port }
-- (mac nil when the TXT record has none), for the follower (address-follow-design 2.1) and the list. Answers of the
-- pinned MAC (pin(), read when the window opens and when a find joins it) take places of their own, MAX_PINNED in
-- each list, so no other answer crowds them out (#214). Both lists are empty when the window could not open. The
-- callback also runs, at once, when the window cannot open. A find while one runs adds its callback to that window:
-- one binding, two queries, every callback told the same. Returns false for a callback that is not a function. The
-- first query goes out as soon as open returns; if a controller drops it because the binding is not yet ONLINE (K10
-- saw 7 ms), the second one, a second later, answers that.
function Finder:find(callback)
	if type(callback) ~= "function" then
		return false, "callback"
	end
	local w = self.window
	if w then
		w.callbacks[#w.callbacks + 1] = callback
		w.pin = self:pinned() or w.pin
		return true
	end
	w = {
		callbacks = { callback },
		list = {},
		seen = {},
		heard = {},
		heard_seen = {},
		pin = self:pinned(),
		places = { list = { own = 0, other = 0 }, heard = { own = 0, other = 0 } },
		parsed = 0, bytes = 0, spent = 0, -- the window's budget used so far (WINDOW_*)
		exhausted = nil,                 -- the budget that ran out: what comes after is dropped unread
		sent = 0,
		tally = { answer = 0, other = 0, query = 0, unparsed = 0, dropped = 0 },
	}
	self.window = w

	local ok, result = pcall(self.open)
	if not ok or result == false then
		self:say("debug", "Search: the network binding did not open (%s)", ok and "refused" or tostring(result))
		self:finish(w, "open")
		return true
	end
	-- The end of the window first, so that nothing below can leave it open.
	local armed, over = pcall(self.timer, WINDOW_MS, function() self:finish(w) end)
	if not armed then
		self:say("debug", "Search: no timer for the window (%s)", tostring(over))
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

-- stop(): OnDriverDestroyed. Ends an open window without calling its callbacks (as transport.stop does), and
-- nothing reaches on_window after it: not that window, nor one whose callbacks or listener are running now.
-- A find after stop() starts afresh and is heard as usual.
function Finder:stop()
	self.notices = { draining = false }
	local w = self.window
	if not w then
		return
	end
	self.window = nil
	cancel(w.again)
	cancel(w.over)
	pcall(self.close)
	self.closed_at = self:clock()
end

-- Takes one of the window's places in `kind` ("list" or "heard") for an answer of the pinned MAC (own) or of any
-- other: false when that side is full. The pinned MAC's places are counted apart, MAX_PINNED of them, so answers of
-- other MACs never take them (#214).
local function take_place(w, kind, own)
	local places = w.places[kind]
	local side = own and "own" or "other"
	local cap = MAX_PINNED
	if not own then
		cap = kind == "list" and MAX_FOUND or MAX_HEARD
	end
	if places[side] >= cap then
		return false
	end
	places[side] = places[side] + 1
	return true
end

-- One answer's entry for the heard list: kept when the window has not heard this instance at this address with
-- this MAC before and its side (take_place) has room. The list keeps an instance's first answer only, so a stale
-- address heard first would hide the fresh one (ECA FA11, 3.9); this keeps both. The MAC is part of what compares,
-- so another MAC's answer for the pinned fan's instance and address cannot hide the pinned fan's own (#214). The
-- instance compares as the list's does, the first spelling is kept, and each entry is a record of its own, so the
-- list's records stay the list's. `known` says the instance was in the list before this answer: the one case the
-- list's debug line does not cover.
local function hear(finder, w, key, fan, known, own)
	-- Neither a cleaned instance, an address nor a MAC holds a NUL.
	local pair = key .. "\0" .. fan.address .. "\0" .. (fan.mac or "")
	if w.heard_seen[pair] or not take_place(w, "heard", own) then
		return
	end
	w.heard_seen[pair] = true
	w.heard[#w.heard + 1] = { instance = fan.instance, address = fan.address, mac = fan.mac, port = fan.port }
	if known then
		finder:say("debug", "Search: %s also at %s", tail(fan.mac), fan.address)
	end
end

-- The budget of the window that ran out before this datagram (WINDOW_*, #214), or nil. `size` is what parse would
-- read of it. Once one has run out, every later datagram of the window is dropped, whatever its size.
local function spent(w, size)
	if w.exhausted then
		return w.exhausted
	elseif w.parsed >= WINDOW_DATAGRAMS then
		return "datagrams"
	elseif w.bytes + size > WINDOW_BYTES then
		return "bytes"
	elseif w.spent >= WINDOW_PARSE_MS then
		return "time"
	end
	return nil
end

-- received(binding, port, data, from): ReceivedFromNetwork for the discovery binding. The sender (`from`) comes
-- only from OS 4.0.0 (API 32_serial_network_device/_15-ReceivedFromNetwork.md) and is not needed: the A record
-- carries the fan's address. Everything outside a window, the controller's own query echoed back, other
-- services' records and what is not DNS is dropped, and so, unread, is every datagram after the window's budget
-- ran out (WINDOW_DATAGRAMS, WINDOW_BYTES, WINDOW_PARSE_MS of now(); #214). Returns what it made of the datagram,
-- for the specs and the debug line: "closed", "query", "dropped", "answer", "other" or "unparsed".
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
	local size = type(data) == "string" and #data or 0
	if size > MAX_DATAGRAM then
		size = 0 -- parse refuses it unread ("large")
	end
	local over = spent(w, size)
	if over then
		tally.dropped = tally.dropped + 1
		if not w.exhausted then
			w.exhausted = over
			self:say("debug", "Search: this window's %s budget is spent; the rest of its datagrams are dropped unread",
				over)
		end
		return "dropped"
	end
	w.parsed = w.parsed + 1
	w.bytes = w.bytes + size
	local started = self:clock()
	local made = self:take(w, data)
	local ended = started and self:clock()
	-- A clock that went back, or jumped further than a whole window, measured no parsing.
	if ended and ended >= started and ended - started <= WINDOW_MS then
		w.spent = w.spent + (ended - started)
	end
	return made
end

-- One datagram of the window, within its budget: parsed, its fans into the list and the heard list.
function Finder:take(w, data)
	local tally = w.tally
	local list, why = discovery.parse(data)
	if #list > 0 then
		tally.answer = tally.answer + 1
		for _, fan in ipairs(list) do
			local key = fan.instance:lower()
			local own = w.pin ~= nil and fan.mac == w.pin
			local known = w.seen[key]
			if not known and take_place(w, "list", own) then
				w.seen[key] = true
				w.list[#w.list + 1] = fan
				self:say("debug", "Search: %s at %s", tail(fan.mac), fan.address)
			end
			hear(self, w, key, fan, known, own)
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
