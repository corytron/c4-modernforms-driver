-- Controller drivers run under LuaJIT (5.1 semantics): <script jit="1"> in
-- every driver.xml [verified: XML reference, 15_common_xml/_71-script.md;
-- Fundamentals 7/_1: LuaJIT holds drivers to the Lua 5.1 language standard].
-- tools/check.sh lints src, tests and tools with this file; tools has no
-- section of its own, so any Lua there gets the defaults below.
std = "lua51"
max_line_length = 120

-- Globals the DriverWorks runtime provides to every driver.
read_globals = {
	"C4",
	"Properties",
	"C4SystemEvents",
}

files["src/modernforms_fan/driver.lua"] = {
	-- DriverWorks entry points are globals the controller calls by name
	-- (common/dispatch.lua sets ExecuteCommand, ReceivedFromProxy and
	-- OnPropertyChanged; the driver defines the rest it needs).
	globals = {
		"OnDriverInit", "OnDriverLateInit", "OnDriverDestroyed", "OnDriverRemovedFromProject",
		"ExecuteCommand", "OnPropertyChanged", "ReceivedFromProxy", "OnBindingChanged", "OnBindingValidate",
		"OnSystemEvent",
	},
}

files["tests"] = {
	std = "+busted",
	globals = { "C4", "Properties" },
	-- The fake C4 methods mirror the real colon-call signatures.
	self = false,
}
