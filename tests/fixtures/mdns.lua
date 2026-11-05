-- Fixtures for fan.discovery (docs/v1-design.md section 9.10, V5a): multicast DNS datagrams, built here by a
-- small DNS encoder (RFC 1035 section 4, RFC 6762) from the placeholder fans only. What K10 saw on the house
-- (section 11.1) taught the record structure and the two layouts below; no value of that log is copied.
--
-- The fan answers a PTR question for _easylink._tcp.local with a multicast response of id 0 and flags
-- 0x8400 (response, authoritative): PTR, SRV (priority 0, weight 0, port 80, target <instance>.local) and TXT
-- (Protocol, MAC, Firmware Rev) as answers, the A record of the target as an additional record. It sent two
-- layouts of the same records, 250 and 299 bytes for an instance label of 13 octets, and so does this file:
--   K10_FIRST   the service name written once, the instance's names pointing to it, the A record pointing into
--               the SRV record's target;
--   K10_SECOND  only the last label ("local") shared, the other names written out.
-- A Gen 1/2 fan announces itself in a third layout (GEN12_ANNOUNCEMENT, docs/edge-cases-address.md E4), and
-- K10_MOVED is the first layout from the fan at another address, for the follower (docs/address-follow-design.md).

local M = {}

M.FAN_ONE = {
	instance = "MF_Fan_005301", address = "10.0.2.151", port = 80, mac = "00005E005301", firmware = "02.00.0052",
}
M.FAN_TWO = {
	instance = "MF_Fan_005302", address = "10.0.2.152", port = 80, mac = "00005E005302", firmware = "02.00.0060",
}
-- Another device that announces the same service type with a protocol of its own.
M.OTHER = {
	instance = "Other_Device_1234", address = "192.0.2.50", port = 80, mac = "00005E005399", firmware = "1.2.3",
}
-- FAN_ONE answering from the second address: the same instance and MAC (ECA FA1, FA11).
M.FAN_ONE_MOVED = {
	instance = "MF_Fan_005301", address = "10.0.2.152", port = 80, mac = "00005E005301", firmware = "02.00.0052",
}
-- A Gen 1/2 fan with FAN_ONE's MAC at the second address (ECA E4): its instance is "WAC Windermier Fan#" and the
-- last six digits of the MAC, its firmware a Gen 1/2 version (MFR section 1).
M.GEN12_FAN = {
	instance = "WAC Windermier Fan#005301", address = "10.0.2.152", port = 80, mac = "00005E005301",
	firmware = "01.03.0025",
}

local TYPE_A, TYPE_NS, TYPE_PTR, TYPE_TXT, TYPE_SRV = 1, 2, 12, 16, 33
M.TYPE = { A = TYPE_A, NS = TYPE_NS, PTR = TYPE_PTR, TXT = TYPE_TXT, SRV = TYPE_SRV }

-- The encoder ----------------------------------------------------------------------------------------------------

local enc = {}
M.encode = enc

function enc.u16(n)
	return string.char(math.floor(n / 256) % 256, n % 256)
end

function enc.u32(n)
	return enc.u16(math.floor(n / 65536)) .. enc.u16(n % 65536)
end

-- No length check: the specs build oversized labels on purpose.
function enc.label(text)
	return string.char(#text) .. text
end

-- A name written out in full, from its labels.
function enc.name(...)
	local parts = {}
	for i, text in ipairs({ ... }) do
		parts[i] = enc.label(text)
	end
	parts[#parts + 1] = "\0"
	return table.concat(parts)
end

-- A compression pointer (RFC 1035 section 4.1.4) to the byte offset `offset` from the start of the message.
function enc.ptr(offset)
	return enc.u16(0xC000 + offset)
end

function enc.header(spec)
	return enc.u16(spec.id or 0) .. enc.u16(spec.flags or 0) .. enc.u16(spec.qd or 0) .. enc.u16(spec.an or 0)
		.. enc.u16(spec.ns or 0) .. enc.u16(spec.ar or 0)
end

-- The data of a TXT record: each string with its length octet.
function enc.txt(...)
	local parts = {}
	for i, text in ipairs({ ... }) do
		parts[i] = enc.label(text)
	end
	return table.concat(parts)
end

function enc.srv(priority, weight, port, target)
	return enc.u16(priority) .. enc.u16(weight) .. enc.u16(port) .. target
end

function enc.a(address)
	local a, b, c, d = address:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
	return string.char(tonumber(a), tonumber(b), tonumber(c), tonumber(d))
end

-- A growing message: put(bytes) appends and returns the offset the bytes start at, which is what a pointer
-- needs; size() is the offset of the next byte.
function enc.buffer()
	local parts, size = {}, 0
	local buf = {}
	function buf.put(bytes)
		parts[#parts + 1] = bytes
		size = size + #bytes
		return size - #bytes
	end
	function buf.size()
		return size
	end
	function buf.bytes()
		return table.concat(parts)
	end
	return buf
end

-- A resource record (RFC 1035 section 4.1.3) appended to buf. `rdata` is a string, or a function that takes the
-- offset the data will start at and returns it (for data that points at itself). Returns the offset of the
-- owner and the offset of the data.
function enc.rr(buf, owner, rtype, class, ttl, rdata)
	local owner_at = buf.put(owner)
	local rdata_at = buf.size() + 10
	if type(rdata) == "function" then
		rdata = rdata(rdata_at)
	end
	buf.put(enc.u16(rtype) .. enc.u16(class) .. enc.u32(ttl) .. enc.u16(#rdata))
	buf.put(rdata)
	return owner_at, rdata_at
end

-- 00005E005301 -> 00:00:5E:00:53:01, the spelling of the TXT record.
local function colon(mac)
	local text = mac:gsub("(%x%x)", "%1:")
	return text:sub(1, -2)
end

local function txt_strings(fan)
	return { "Protocol=com.modernforms.fan", "MAC=" .. colon(fan.mac), "Firmware Rev=" .. fan.firmware }
end

-- A Gen 1/2 fan's TXT strings: the keys of a Gen 3 fan's and Hardware Rev, MICO OS Rev, Model, Manufacturer and
-- Seed (ECA E4, MFR section 7), the MAC spelled as a Gen 3 fan spells it. ECA records no order and copies no
-- value: the order is this file's, with Protocol not first, and the values of the added keys are placeholders.
local function gen12_strings(fan)
	return { "MAC=" .. colon(fan.mac), "Firmware Rev=" .. fan.firmware, "Hardware Rev=example",
		"MICO OS Rev=example", "Model=example", "Protocol=com.modernforms.fan", "Manufacturer=example", "Seed=1" }
end

local SERVICE = { "_easylink", "_tcp", "local" }

-- One fan's records in the first layout (PTR, SRV, TXT as answers, A as an additional record), any part of
-- which a spec can change. With no options this is K10_FIRST, 250 bytes.
--   fan        { instance, address, port, mac, firmware } (FAN_ONE)
--   service    the service labels (_easylink _tcp local)
--   strings    the TXT strings (Protocol, MAC, Firmware Rev of the fan)
--   host       the labels of the SRV target and of the A record's owner (<instance> local)
--   a_host     other labels for the A record's owner only
--   address    dotted quad of the A record;  a_data: the A record's data as bytes instead;  port: the SRV port
--   ttl        one time to live for all four records;  class: one class for all four (0x8001: cache flush)
--   flags, id  the header's (0x8400, 0)
--   omit       { ptr = true, srv = true, txt = true, a = true } leaves records out
--   question   true: the question that was asked is repeated first (the answer of a legacy unicast resolver)
--   authority  true: an NS record sits between the answers and the additional record
--   a_section  "authority": the A record is counted in the authority section instead of the additional one
--   counts     { qd =, an =, ns =, ar = } replaces the header's counts (to lie about them)
function M.fan_message(opts)
	opts = opts or {}
	local fan = opts.fan or M.FAN_ONE
	local service = opts.service or SERVICE
	local host = opts.host or { fan.instance, "local" }
	local omit = opts.omit or {}
	local class = opts.class or 1
	local function ttl(default)
		return opts.ttl or default
	end
	local counts = {
		qd = opts.question and 1 or 0,
		an = (omit.ptr and 0 or 1) + (omit.srv and 0 or 1) + (omit.txt and 0 or 1),
		ns = (opts.authority and 1 or 0) + ((opts.a_section == "authority" and not omit.a) and 1 or 0),
		ar = (omit.a or opts.a_section == "authority") and 0 or 1,
	}
	for key, value in pairs(opts.counts or {}) do
		counts[key] = value
	end

	local buf = enc.buffer()
	buf.put(enc.header({ id = opts.id, flags = opts.flags or 0x8400, qd = counts.qd, an = counts.an, ns = counts.ns,
		ar = counts.ar }))
	local service_at = nil
	if opts.question then
		service_at = buf.put(enc.name(unpack(service)) .. enc.u16(TYPE_PTR) .. enc.u16(1))
	end
	local function instance_owner() -- the service name is a pointer once something has written it
		if service_at then
			return enc.label(fan.instance) .. enc.ptr(service_at)
		end
		return enc.name(fan.instance, unpack(service))
	end

	if not omit.ptr then
		local owner = service_at and enc.ptr(service_at) or enc.name(unpack(service))
		service_at = service_at or buf.size()
		enc.rr(buf, owner, TYPE_PTR, class, ttl(4500), enc.label(fan.instance) .. enc.ptr(service_at))
	end
	local host_at = nil
	if not omit.srv then
		local _, rdata_at = enc.rr(buf, instance_owner(), TYPE_SRV, class, ttl(120),
			enc.srv(0, 0, opts.port or fan.port or 80, enc.name(unpack(host))))
		host_at = rdata_at + 6
	end
	if not omit.txt then
		enc.rr(buf, enc.name(fan.instance, unpack(service)), TYPE_TXT, class, ttl(4500),
			enc.txt(unpack(opts.strings or txt_strings(fan))))
	end
	if opts.authority then
		enc.rr(buf, enc.name("example", "local"), TYPE_NS, 1, ttl(120), enc.name("ns", "local"))
	end
	if not omit.a then
		local owner = opts.a_host and enc.name(unpack(opts.a_host)) or host_at and enc.ptr(host_at)
			or enc.name(unpack(host))
		enc.rr(buf, owner, TYPE_A, class, ttl(120), opts.a_data or enc.a(opts.address or fan.address))
	end
	return buf.bytes()
end

-- The second layout K10 saw (299 bytes): PTR, SRV, TXT, A with only "local" shared.
local function second_layout(fan)
	local buf = enc.buffer()
	buf.put(enc.header({ flags = 0x8400, an = 3, ar = 1 }))
	local service_at = buf.size()
	local local_at = service_at + 1 + #SERVICE[1] + 1 + #SERVICE[2]
	local suffix = enc.label(SERVICE[1]) .. enc.label(SERVICE[2]) .. enc.ptr(local_at)
	enc.rr(buf, enc.name(unpack(SERVICE)), TYPE_PTR, 1, 4500, enc.label(fan.instance) .. suffix)
	enc.rr(buf, enc.label(fan.instance) .. suffix, TYPE_SRV, 1, 120,
		enc.srv(0, 0, 80, enc.name(fan.instance, "local")))
	enc.rr(buf, enc.name(fan.instance, unpack(SERVICE)), TYPE_TXT, 1, 4500, enc.txt(unpack(txt_strings(fan))))
	enc.rr(buf, enc.name(fan.instance, "local"), TYPE_A, 1, 120, enc.a(fan.address))
	return buf.bytes()
end

-- The same records in another order and other sections: the A record first, the TXT record, the SRV record
-- pointing back to both, the PTR record last as an additional record; the cache-flush bit on the class of the
-- records that have one (RFC 6762 section 10.2), names compressed against what came before.
local function reordered(fan)
	local buf = enc.buffer()
	buf.put(enc.header({ flags = 0x8400, an = 3, ar = 1 }))
	local host_at = buf.size()
	enc.rr(buf, enc.name(fan.instance, "local"), TYPE_A, 0x8001, 120, enc.a(fan.address))
	local local_at = host_at + 1 + #fan.instance
	local txt_at = buf.size()
	enc.rr(buf, enc.label(fan.instance) .. enc.label(SERVICE[1]) .. enc.label(SERVICE[2]) .. enc.ptr(local_at),
		TYPE_TXT, 0x8001, 4500, enc.txt(unpack(txt_strings(fan))))
	enc.rr(buf, enc.ptr(txt_at), TYPE_SRV, 0x8001, 120, enc.srv(0, 0, 80, enc.ptr(host_at)))
	enc.rr(buf, enc.ptr(txt_at + 1 + #fan.instance), TYPE_PTR, 1, 4500, enc.ptr(txt_at))
	return buf.bytes()
end

-- Two fans in one datagram, interleaved, with their A records in the opposite order.
local function two_fans(first, second)
	local buf = enc.buffer()
	buf.put(enc.header({ flags = 0x8400, an = 6, ar = 2 }))
	local service_at = buf.size()
	local function owner(fan)
		return enc.label(fan.instance) .. enc.ptr(service_at)
	end
	enc.rr(buf, enc.name(unpack(SERVICE)), TYPE_PTR, 1, 4500, owner(first))
	enc.rr(buf, enc.ptr(service_at), TYPE_PTR, 1, 4500, owner(second))
	local _, first_srv = enc.rr(buf, owner(first), TYPE_SRV, 1, 120,
		enc.srv(0, 0, 80, enc.name(first.instance, "local")))
	enc.rr(buf, owner(first), TYPE_TXT, 1, 4500, enc.txt(unpack(txt_strings(first))))
	local _, second_srv = enc.rr(buf, owner(second), TYPE_SRV, 1, 120,
		enc.srv(0, 0, 80, enc.name(second.instance, "local")))
	enc.rr(buf, owner(second), TYPE_TXT, 1, 4500, enc.txt(unpack(txt_strings(second))))
	enc.rr(buf, enc.ptr(second_srv + 6), TYPE_A, 1, 120, enc.a(second.address))
	enc.rr(buf, enc.ptr(first_srv + 6), TYPE_A, 1, 120, enc.a(first.address))
	return buf.bytes()
end

-- Every name loops: the owners of the SRV and A records point at themselves, the owner of the TXT record and
-- the SRV target at a pair of pointers that point at each other (kept in the PTR record's data).
local function looping(fan)
	local buf = enc.buffer()
	buf.put(enc.header({ flags = 0x8400, an = 3, ar = 1 }))
	local _, cycle_at = enc.rr(buf, enc.name(unpack(SERVICE)), TYPE_PTR, 1, 4500, function(at)
		return enc.ptr(at + 2) .. enc.ptr(at)
	end)
	enc.rr(buf, enc.ptr(buf.size()), TYPE_SRV, 1, 120, enc.srv(0, 0, 80, enc.ptr(cycle_at)))
	enc.rr(buf, enc.ptr(cycle_at), TYPE_TXT, 1, 4500, enc.txt(unpack(txt_strings(fan))))
	enc.rr(buf, enc.ptr(buf.size()), TYPE_A, 1, 120, enc.a(fan.address))
	return buf.bytes()
end

-- Pointers past the end of the datagram: the TXT owner, the SRV target and the A owner.
local function out_of_bounds(fan)
	local buf = enc.buffer()
	buf.put(enc.header({ flags = 0x8400, an = 3, ar = 1 }))
	local service_at = buf.size()
	enc.rr(buf, enc.name(unpack(SERVICE)), TYPE_PTR, 1, 4500, enc.label(fan.instance) .. enc.ptr(service_at))
	enc.rr(buf, enc.label(fan.instance) .. enc.ptr(service_at), TYPE_SRV, 1, 120, enc.srv(0, 0, 80, enc.ptr(1000)))
	enc.rr(buf, enc.ptr(16383), TYPE_TXT, 1, 4500, enc.txt(unpack(txt_strings(fan))))
	enc.rr(buf, enc.ptr(4000), TYPE_A, 1, 120, enc.a(fan.address))
	return buf.bytes()
end

-- The TXT record's owner starts with a 65-octet label, which no name may (labels are 63 octets at most, and a
-- length octet of 64 to 191 is a reserved label type, RFC 1035 section 4.1.4).
local function oversized_label(fan)
	local buf = enc.buffer()
	buf.put(enc.header({ flags = 0x8400, an = 3, ar = 1 }))
	local service_at = buf.size()
	enc.rr(buf, enc.name(unpack(SERVICE)), TYPE_PTR, 1, 4500, enc.label(fan.instance) .. enc.ptr(service_at))
	local _, srv_at = enc.rr(buf, enc.label(fan.instance) .. enc.ptr(service_at), TYPE_SRV, 1, 120,
		enc.srv(0, 0, 80, enc.name(fan.instance, "local")))
	enc.rr(buf, enc.label(string.rep("x", 65)) .. enc.name(unpack(SERVICE)), TYPE_TXT, 1, 4500,
		enc.txt(unpack(txt_strings(fan))))
	enc.rr(buf, enc.ptr(srv_at + 6), TYPE_A, 1, 120, enc.a(fan.address))
	return buf.bytes()
end

-- A Gen 1/2 fan's announcement (ECA E4): sent unprompted, not as an answer, so no question and id 0; PTR, SRV,
-- TXT and A all in the answer section, each with a time to live of 1500 s, the cache-flush bit on the SRV, TXT
-- and A records (RFC 6762 sections 8.3, 10.2), not on the shared PTR record. SRV port 80 (MFR section 7). ECA
-- records neither the order of the records, nor the SRV target, nor the compression: here the target is
-- <instance>.local as a Gen 3 fan names it (E1), and each name points back to what came before it.
local function gen12_announcement(fan)
	local buf = enc.buffer()
	buf.put(enc.header({ flags = 0x8400, an = 4 }))
	local service_at = buf.size()
	local local_at = service_at + 1 + #SERVICE[1] + 1 + #SERVICE[2]
	local _, instance_at = enc.rr(buf, enc.name(unpack(SERVICE)), TYPE_PTR, 1, 1500,
		enc.label(fan.instance) .. enc.ptr(service_at))
	local _, srv_at = enc.rr(buf, enc.ptr(instance_at), TYPE_SRV, 0x8001, 1500,
		enc.srv(0, 0, fan.port, enc.label(fan.instance) .. enc.ptr(local_at)))
	enc.rr(buf, enc.ptr(instance_at), TYPE_TXT, 0x8001, 1500, enc.txt(unpack(gen12_strings(fan))))
	enc.rr(buf, enc.ptr(srv_at + 6), TYPE_A, 0x8001, 1500, enc.a(fan.address))
	return buf.bytes()
end

-- The fixtures, by name; M.NAMES lists them in this order for a spec that runs over all of them. ------------------

M.K10_FIRST = M.fan_message()
M.K10_SECOND = second_layout(M.FAN_ONE)
M.REORDERED = reordered(M.FAN_ONE)
M.TWO_FANS = two_fans(M.FAN_ONE, M.FAN_TWO)
M.FAN_TWO_ALONE = M.fan_message({ fan = M.FAN_TWO })
M.OTHER_EASYLINK = M.fan_message({
	fan = M.OTHER,
	strings = { "Protocol=com.example.gadget", "MAC=" .. colon(M.OTHER.mac), "Firmware Rev=" .. M.OTHER.firmware },
})
M.TXT_NO_PROTOCOL = M.fan_message({
	strings = { "MAC=" .. colon(M.FAN_ONE.mac), "Firmware Rev=" .. M.FAN_ONE.firmware },
})
M.TRUNCATED = M.K10_FIRST:sub(1, 200) -- cut inside the TXT record's data
M.LOOP = looping(M.FAN_ONE)
M.POINTER_OUT_OF_BOUNDS = out_of_bounds(M.FAN_ONE)
M.OVERSIZED_LABEL = oversized_label(M.FAN_ONE)
M.GEN12_ANNOUNCEMENT = gen12_announcement(M.GEN12_FAN)
M.K10_MOVED = M.fan_message({ fan = M.FAN_ONE_MOVED })

M.NAMES = {
	"K10_FIRST", "K10_SECOND", "REORDERED", "TWO_FANS", "FAN_TWO_ALONE", "OTHER_EASYLINK", "TXT_NO_PROTOCOL",
	"TRUNCATED", "LOOP", "POINTER_OUT_OF_BOUNDS", "OVERSIZED_LABEL", "GEN12_ANNOUNCEMENT", "K10_MOVED",
}

return M
