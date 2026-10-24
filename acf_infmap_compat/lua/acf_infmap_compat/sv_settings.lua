-- Server settings setter for the client menu (cl_menu.lua).
--
-- The server-side convars of this addon are replicated, so every client can READ them, but a client cannot WRITE a server
-- convar from its own console. The menu therefore sends one small net message per change and the server applies it, after
-- checking that the sender is a superadmin and that the name is one of the addon's own settings (Compat.ServerSettings).
--
-- Evidence labels: SEEN = read in source / run in the mock, KNOWN = standard GMod behaviour not re-checked, GUESS = needs a game.
--   KNOWN: net.Receive callbacks get (length, player) on the server; Player:IsSuperAdmin(); RunConsoleCommand on the server
--          sets the server's convar; replicated convars are readable on the client.
--   SEEN:  every value is clamped to the bounds in Compat.ServerSettings (sh_core.lua); booleans become 0 or 1.
--   GUESS: that FCVAR_ARCHIVE + FCVAR_REPLICATED together behave on a dedicated server (saved on the server, copied to clients).
--          The console variables themselves also work if you would rather type them.

local Compat = ACFInfMapCompat

util.AddNetworkString("ACFInfMapCompat_Setting")

--- Validates and applies one setting. Returns the value that was set, or nil and the reason. Exposed for tests.
function Compat.ApplySetting(Name, Value)
	local Def = Compat.ServerSettingByName[Name]

	if not Def then return nil, "unknown setting" end
	if not isnumber(Value) or Value ~= Value or Value == math.huge or Value == -math.huge then return nil, "not a number" end

	if Def.Kind == "bool" then
		Value = Value ~= 0 and 1 or 0
	else
		Value = math.Clamp(Value, Def.Min, Def.Max)
	end

	RunConsoleCommand(Name, tostring(Value))

	return Value
end

Compat.Register("sv_settings", function()
	-- Nothing to wrap: the receiver below is registered once at load.
	Compat.Status["Menu setter"] = "ready"
end)

net.Receive("ACFInfMapCompat_Setting", function(_, Ply)
	local Name  = net.ReadString()
	local Value = net.ReadFloat()

	if not IsValid(Ply) or not Ply:IsSuperAdmin() then return end

	local Set, Why = Compat.ApplySetting(Name, Value)

	if Set then
		Compat.Say(Ply:Nick(), " set ", Name, " = ", Set)
	else
		Compat.Warn(Ply:Nick(), " sent a bad setting (", tostring(Name), "): ", Why)
	end
end)
