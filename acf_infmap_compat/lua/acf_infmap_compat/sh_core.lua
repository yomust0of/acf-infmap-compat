-- Shared core: wrapping helper, installer registry, counters, status command. Runs on both server and client.
--
-- Evidence labels: SEEN = read in source / run in the mock, KNOWN = standard GMod behaviour not re-checked, GUESS = needs a game.
--   SEEN:  ACF's public functions are looked up through their tables at call time by the call sites this addon cares
--          about (Sounds.*, ACF.trace in ballistics_sv.lua, Ballistics.CalcBulletFlight, Effects.CreateEffect), so
--          replacing the table field is enough for them.
--   SEEN:  some ACF files copy ACF.trace into a local variable when they load: damage/explosion_sv.lua, entities/sensors/
--          receivers/receivers.lua, entities/fuzes/optical.lua, entities/guidance/radio_mclos.lua, entities/guidance/laser.lua
--          and entities/acf_radar/init.lua. A wrapper installed later cannot reach those copies.
--   SEEN:  the other ACF.trace call sites look the function up on the ACF table when they run, so the wrapper does reach them:
--          bullets (ballistics_sv.lua), HEAT jets, acf_missile, acf_glatgm, acf_gun, overpressure_sv.lua, computers.lua, core/laser/laser_sh.lua.

local Compat = ACFInfMapCompat

Compat.Wrapped    = Compat.Wrapped or {} -- [Table][Name] = the wrapper this addon installed, so it never wraps twice
Compat.Status     = Compat.Status or {}  -- [Label] = "wrapped" | "missing"
Compat.Installers = {}                   -- rebuilt on every include: [Name] = function
Compat.Stats      = Compat.Stats or {}   -- counters that prove the fixes actually ran
Compat.StatusLines = Compat.StatusLines or {} -- [Module] = function returning extra lines for `acf_infmap_status`

local Stats = Compat.Stats

for _, Name in ipairs({"Swapped", "Skipped", "Split", "OutputCopied", "Killed", "EffectsSent", "EffectsShown", "EffectsDropped",
                       "BulletsKeptAlive", "ReplayShown", "ReplayDropped", "ReplayEmpty", "ReplayErrors", "ReplayParticles", "ReplayCorrected", "WireTraces", "E2Traces", "OriginCalls", "OriginErrors"}) do
	Stats[Name] = Stats[Name] or 0
end

-- The engine can only place and draw things inside +-16384 units of the frame origin, which under InfMap is the CENTRE of the
-- local player's chunk (not the player). Anything past this many units on an axis is "far": a native effect cannot be shown there.
--   SEEN:  InfMap's own render code (cl_inf_chunks.lua) says "when bounding box is outside of world bounds the object isn't
--          rendered" and works around it by drawing through a shifted camera. The GMod wiki says the same limit (+-16386) for
--          an effect's Origin. Under it, a hit effect is only drawn up to the edge of that box, which is about one chunk from you.
--   SEEN:  ACF's own flare code stops at 16000 (acf/missiles/acfm_effects_cl.lua), the bullet effect at 16380.
Compat.MaxEngine = 16384
Compat.Window = 16000 -- 16384 minus a margin
Compat.MeterToUnit = 39.3701 -- ACF's own ACF.MeterToInch

--- Whether a LOCAL-frame position (Vector) is inside the window where native effects work.
function Compat.InWindow(Pos)
	local W = Compat.Window

	return math.abs(Pos.x) <= W and math.abs(Pos.y) <= W and math.abs(Pos.z) <= W
end

-- Settings of the server half. One list, read by both realms: the server turns it into a whitelist for the menu's setter, the
-- client menu builds its sliders from it. They are replicated, so clients can read the current values.
-- Unit/Factor: the menu shows `Unit`, the convar holds units (1 metre = 39.37 units).
Compat.ServerFlags = FCVAR_ARCHIVE + FCVAR_REPLICATED
Compat.ServerSettings = {
	{Name = "acf_infmap_fix_sounds",      Kind = "bool", Label = "Fix ACF sounds"},
	{Name = "acf_infmap_sound_range",     Kind = "num", Min = 1000, Max = 400000, Unit = "m", Factor = Compat.MeterToUnit, Label = "Sound range (metres)"},
	{Name = "acf_infmap_fix_traces",      Kind = "bool", Label = "Chunk-aware bullet traces"},
	{Name = "acf_infmap_fix_effects",     Kind = "bool", Label = "Send ACF effects with exact positions"},
	{Name = "acf_infmap_effect_range",    Kind = "num", Min = 1000, Max = 400000, Unit = "m", Factor = Compat.MeterToUnit, Label = "Effect range (metres): who is sent effects"},
	{Name = "acf_infmap_fix_visclip",     Kind = "bool", Label = "Resend visual clips to props whose clips a client missed"},
}
Compat.ServerSettingByName = {}

for _, Def in ipairs(Compat.ServerSettings) do Compat.ServerSettingByName[Def.Name] = Def end

local Yellow, Cyan = Color(255, 200, 80), Color(120, 200, 255)

-- `...` only expands when it is the LAST argument of a call, so the pieces are joined first
local function Join(...)
	local Parts = {}

	for I = 1, select("#", ...) do Parts[I] = tostring((select(I, ...))) end

	return table.concat(Parts)
end

function Compat.Warn(...)
	MsgC(Yellow, "[ACF-InfMap] ", color_white, Join(...) .. "\n")
end

function Compat.Say(...)
	MsgC(Cyan, "[ACF-InfMap] ", color_white, Join(...) .. "\n")
end

-- SEEN (play-test 6.7): "DLL_MessageEnd: Refusing to send user message TextMsg of 256 bytes to client, user message size limit is 255
-- bytes". Ply:PrintMessage is one user message, so a longer line is DROPPED, not cut: `acf_infmap_status` on the server lost its whole
-- "counters:" line (411 bytes even when every counter is 0). Every line a command prints to a player goes through Compat.Tell.
Compat.TellLimit = 200

--- Prints one line to a player's console, in pieces that fit a user message. A piece ends at a space or a comma when there is one in
--- its second half, and never inside a UTF-8 character. Without a player (the server console, or a client) it is a plain print.
--- @param Ply Player? The player to print to
--- @param Text string One line, without a newline
function Compat.Tell(Ply, Text)
	if not (SERVER and IsValid(Ply)) then return print(Text) end

	local Limit, Pos, Length = Compat.TellLimit, 1, #Text

	while Length - Pos + 1 > Limit do
		local Cut  = Pos + Limit - 1
		local Soft = Cut

		while Soft > Pos + Limit * 0.5 and not string.find(string.sub(Text, Soft, Soft), "[ ,]") do Soft = Soft - 1 end

		if Soft > Pos + Limit * 0.5 then
			Cut = Soft
		else
			local Next = string.byte(Text, Cut + 1)

			while Cut > Pos and Next and Next >= 0x80 and Next < 0xC0 do
				Cut  = Cut - 1
				Next = string.byte(Text, Cut + 1)
			end
		end

		Ply:PrintMessage(HUD_PRINTCONSOLE, string.sub(Text, Pos, Cut))
		Pos = Cut + 1
	end

	Ply:PrintMessage(HUD_PRINTCONSOLE, string.sub(Text, Pos) .. "\n")
end

--- Replaces Table[Name] with Make(Original). Safe to call again and again (acf_reload, Lua refresh):
--- if the current function is already our wrapper it is left alone, and if ACF reloaded and put a new function
--- there, that new function gets wrapped.
--- @param Table table The table that holds the function
--- @param Name string The key of the function
--- @param Make function Receives the original function, returns the replacement
--- @param Label string? Name used in messages and in `acf_infmap_status`
--- @return boolean # Whether the function is wrapped after the call
function Compat.Wrap(Table, Name, Make, Label)
	Label = Label or Name

	local Current = Table[Name]

	if not isfunction(Current) then
		Compat.Status[Label] = "missing"
		Compat.Warn("Could not wrap ", Label, ": ACF no longer defines it. This addon needs an update.")

		return false
	end

	local Wrapped = Compat.Wrapped[Table]

	if not Wrapped then
		Wrapped = {}
		Compat.Wrapped[Table] = Wrapped
	end

	if Wrapped[Name] ~= Current then
		local Replacement = Make(Current)

		Wrapped[Name] = Replacement
		Table[Name]   = Replacement
	end

	Compat.Status[Label] = "wrapped"

	return true
end

--- Registers an installer. Each one runs on every Install() and must be idempotent (Wrap already is).
function Compat.Register(Name, Fn)
	Compat.Installers[Name] = Fn
end

--- True when the older "ACF InfMap sound glue" (acf/compatibility/infmap_sounds_*.lua inside ACF) is installed. It does the
--- same job as this addon's sound modules, and two copies would send every engine loop twice, so this addon steps aside.
function Compat.GlueInstalled()
	local Glue = ACF and ACF.InfMapCompat

	return istable(Glue) and istable(Glue.Wrapped) and true or false
end

local Told = false

function Compat.SoundsStepAside(Label)
	Compat.Status[Label] = "skipped (ACF sound glue is installed)"

	if not Told then
		Told = true

		Compat.Warn("The ACF sound glue (lua/acf/compatibility/infmap_sounds_*.lua) is installed in ACF. This addon's sound fix is switched off to avoid doing it twice; delete the glue files to use this addon's version.")
	end
end

local Order = {"sv_sounds", "sv_traces", "sv_wire", "sv_e2ranger", "sv_bullets", "sv_effects", "sv_settings", "sv_visclip", "cl_sounds", "cl_effects", "cl_replay", "cl_bullets", "cl_render", "cl_origin"}

--- Runs every installer once ACF's tables exist. One failing module does not stop the others.
function Compat.Install()
	if not InfMap then return end

	-- ACF's loader deletes a library table that ends up empty, and the client has no ballistics functions, so
	-- ACF.Ballistics is only required on the server (SEEN: includes/gloader.lua, shouldClear).
	if not (ACF and ACF.Utilities and ACF.Utilities.Sounds) then return end
	if SERVER and not ACF.Ballistics then return end

	for _, Name in ipairs(Order) do
		local Fn = Compat.Installers[Name]

		if Fn then
			local OK, Err = pcall(Fn)

			if not OK then
				Compat.Status[Name] = "error"
				Compat.Warn("Installer ", Name, " failed: ", tostring(Err))
			end
		end
	end
end

-- The EffectData fields ACF effect tables can use, in a fixed order that both realms share (the effect message sends an
-- id instead of the name). Value types: 1 number, 2 vector, 3 angle, 4 entity, 5 boolean.
Compat.EffectFields = {"Angles", "Attachment", "Color", "DamageType", "EntIndex", "Entity", "Flags", "HitBox", "Magnitude", "MaterialIndex", "Normal", "Origin", "Radius", "Scale", "Start", "SurfaceProp"}
Compat.EffectFieldId = {}

for Id, Field in ipairs(Compat.EffectFields) do Compat.EffectFieldId[Field] = Id end

Compat.EffectTag = {Number = 1, Vector = 2, Angle = 3, Entity = 4, Bool = 5}

--- Size of one chunk in units (InfMap's chunk_size is the half-width) and its half-width.
function Compat.ChunkSizes()
	local Half = InfMap.chunk_size

	return Half, Half * 2
end

--- A position in the frame of the chunk `Chunk` (chunk offsets are Vectors of integers, as InfMap stores them).
function Compat.ToFrame(GlobalPos, Chunk)
	local _, Full = Compat.ChunkSizes()

	return GlobalPos - Chunk * Full
end

local function Chunk(Ent)
	local Offset = Ent and Ent.CHUNK_OFFSET

	return Offset and string.format("%d,%d,%d", Offset.x, Offset.y, Offset.z) or "?"
end

Compat.ChunkText = Chunk

-- Prints which wrappers are in place and the counters. Server and client each print their own half.
concommand.Add("acf_infmap_status", function(Ply)
	if SERVER and IsValid(Ply) and not Ply:IsSuperAdmin() then return end

	local Lines = {}
	local Names = {}

	for Label in pairs(Compat.Status) do Names[#Names + 1] = Label end

	table.sort(Names)

	Lines[#Lines + 1] = string.format("[ACF-InfMap] %s status. InfMap chunk_size = %s", SERVER and "SERVER" or "CLIENT", tostring(InfMap and InfMap.chunk_size))

	for _, Label in ipairs(Names) do
		Lines[#Lines + 1] = string.format("  %-40s %s", Label, Compat.Status[Label])
	end

	local Counters = {}

	for Name, Value in pairs(Stats) do Counters[#Counters + 1] = string.format("%s=%d", Name, Value) end

	table.sort(Counters)

	Lines[#Lines + 1] = "  counters: " .. table.concat(Counters, ", ")

	local Modules = {}

	for Name in pairs(Compat.StatusLines) do Modules[#Modules + 1] = Name end

	table.sort(Modules)

	for _, Name in ipairs(Modules) do
		local OK, Extra = pcall(Compat.StatusLines[Name])

		if OK and istable(Extra) then
			for _, Line in ipairs(Extra) do Lines[#Lines + 1] = "  " .. Line end
		end
	end

	for _, Line in ipairs(Lines) do
		Compat.Tell(Ply, Line)
	end
end)

Compat.Say(SERVER and "server" or "client", " compatibility core loaded")
