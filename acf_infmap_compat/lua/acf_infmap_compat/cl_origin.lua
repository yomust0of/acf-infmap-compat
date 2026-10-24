-- Engine origin (client): ENT:CalcAbsolutePosition of ACF's scalable entities must answer in the ENTITY's chunk frame, not in yours.
--
-- WHAT YOU SEE: an ACF entity that sits in another chunk is drawn twice as far away as it should be: one chunk away it shows up
-- two chunks away (so it "disappears across the border"), a laser beam goes with it. Other props in the same chunk are right.
--
-- WHY (each step read in the real source; what the ENGINE does with it is GUESS where marked):
--
--  1. ACF's scalable base (entities/base_scalable/cl_init.lua), which every ACF gun, laser, crate, engine ... inherits from, defines
--        function ENT:CalcAbsolutePosition() -- Faking sync
--            ...
--            local Position = self:GetPos()
--            local Angles   = self:GetAngles()
--            ...
--            return Position, Angles
--        end
--     The GMod wiki: ENTITY:CalcAbsolutePosition(pos, ang) "lets you adjust the position and angles the engine uses for an entity",
--     "Called whenever the entity's position changes", and what it returns is "the new position". So the position the ENGINE
--     keeps for the entity is whatever this function returns.
--  2. InfMap detours Entity:GetPos on the client (cl_inf_detours.lua). For an entity in another chunk it does not return the
--     engine's position, it returns that position plus (entity chunk - your chunk) * 20000: the position IN YOUR CHUNK'S FRAME.
--  3. So when the engine recalculates the position of an ACF entity that sits in another chunk, ACF hands it back
--     "raw position + chunk difference", and the engine stores THAT as the entity's origin. The origin is now wrong by one chunk
--     difference, and it stays wrong (it is not recalculated again until the entity moves, and it was made for the chunk you were in
--     at that moment).
--  4. InfMap draws an entity of another chunk through a camera that it moved by the chunk difference (cl_inf_chunks.lua,
--     cam.Start3D(EyePos() - visual_offset)), because it expects the entity's origin to be its raw position. With the origin
--     already carrying one chunk difference, the model lands two chunk differences away. DrawModel, the beam a Draw function draws
--     from LocalToWorld (the origin is in there too), the wires, the render box InfMap shrinks around the origin: all of it.
--     That is the "moved twice as far" of a laser (and it applies to a gun the same way whenever the engine recalculates its position
--     while you are in another chunk).
--
-- WHAT THIS FILE DOES:
--   * Wraps ENT:CalcAbsolutePosition of every scripted entity class that defines it (today: base_scalable), and of the entities that
--     exist already. While the wrapped function runs for an entity that sits in another chunk, the local player's CHUNK_OFFSET is
--     the entity's own (the same trick cl_render.lua uses for draw functions), so InfMap's GetPos answers in the entity's frame, which
--     is what the function gets in a normal map: the engine's own position. The value is put back afterwards, also when the function
--     errors. In your own chunk (or for an entity without a chunk) the original runs untouched.
--   * Nothing else changes: the function does what ACF wrote, its answer is the same as in a map without InfMap.
--   * `acf_infmap_entdebug <class>` (cl_render.lua) prints, for each entity, the engine's position next to the position the server
--     networked, so a wrong origin shows as a difference of whole chunks.
--
-- Evidence labels: SEEN = read in source / run in the mock, KNOWN = standard GMod behaviour not re-checked, GUESS = needs a game.
--   SEEN:  base_scalable's CalcAbsolutePosition returns self:GetPos(), self:GetAngles() (the harness cuts the function out of ACF's
--          file, so a change there is noticed). No other file of ACF, Wire, the lazer addon, InfMap or this addon defines one.
--   SEEN:  cl_inf_detours.lua: Entity:GetPos answers unlocalize_vector(InfMap_GetPos(), entity chunk - local player's chunk).
--   SEEN:  the GMod wiki text quoted above (wiki.facepunch.com/gmod/ENTITY:CalcAbsolutePosition).
--   GUESS: that the position the function returns is stored as the entity's engine origin as the wiki says, and how often the engine
--          calls it. This is why the file does not depend on it: if the engine never calls it for these entities nothing here runs.
--   GUESS: that inside the function GetPos() is the position the engine has just worked out (stock behaviour with no InfMap), so that
--          returning it unchanged is a no-op. The wrapper makes InfMap's detour answer exactly like that.
--   GUESS: that an entity which already exists holds its own copy of the function, which is why existing entities are patched too, with
--          an assignment on the entity itself (the wiki says the function must be defined "in the entity itself").
--   GUESS: that this is what a laser and a gun look different by. Both inherit the same function. What differs is when the engine
--          recalculates the position (after the chunk is known, or while you stand in another chunk), which can only be seen in a game.
--
-- Not covered: an entity whose origin was already stored wrong BEFORE this file wrapped the function (a Lua refresh while you stand in
-- another chunk) stays wrong until the server moves it or you reconnect. At a normal start the wrapper exists before any entity does.

local Compat = ACFInfMapCompat
local Stats  = Compat.Stats

local On = CreateClientConVar("acf_infmap_cl_origin_fix", "1", true, false, "1 = ENT:CalcAbsolutePosition of scripted entities (ACF's scalable base) answers in the entity's own chunk frame, so the engine keeps the right origin. 0 = stock.", 0, 1)

for _, Name in ipairs({"OriginCalls", "OriginErrors"}) do
	Stats[Name] = Stats[Name] or 0
end

local Origin = Compat.Origin or {}

Compat.Origin = Origin

Origin.Wrappers   = Origin.Wrappers   or setmetatable({}, {__mode = "k"}) -- [our wrapper] = the function it wraps
Origin.ByOriginal = Origin.ByOriginal or setmetatable({}, {__mode = "k"}) -- [original function] = its wrapper (one per function)
Origin.Classes    = Origin.Classes    or 0                                -- class tables wrapped so far
Origin.Entities   = Origin.Entities   or 0                                -- entities patched so far

local Wrappers   = Origin.Wrappers
local ByOriginal = Origin.ByOriginal

local Label = "engine origin (ENT:CalcAbsolutePosition)"

--- Puts the local player's chunk back, then hands on what the wrapped function returned (or throws what it threw).
local function Finish(Me, Saved, OK, ...)
	Me.CHUNK_OFFSET = Saved

	if not OK then
		Stats.OriginErrors = Stats.OriginErrors + 1

		error((...), 0)
	end

	return ...
end

--- One wrapper per original function: the class table and every entity that holds a copy of it share it.
local function WrapOnce(Original)
	local Known = ByOriginal[Original]

	if Known then return Known end

	local Wrapper = function(Self, ...)
		if not On:GetBool() then return Original(Self, ...) end

		local Mine  = Self.CHUNK_OFFSET
		local Me    = LocalPlayer()
		local Yours = IsValid(Me) and Me.CHUNK_OFFSET

		-- Your own chunk (or no chunk known yet): InfMap's detour already answers in the entity's frame
		if not Mine or not Yours or Mine == Yours then return Original(Self, ...) end

		Stats.OriginCalls = Stats.OriginCalls + 1

		Me.CHUNK_OFFSET = Mine

		return Finish(Me, Yours, pcall(Original, Self, ...))
	end

	Wrappers[Wrapper]    = Original
	ByOriginal[Original] = Wrapper

	return Wrapper
end

--- Wraps the function in a scripted entity class table. Returns whether it changed anything.
local function WrapClass(Table)
	local Current = istable(Table) and rawget(Table, "CalcAbsolutePosition")

	if not isfunction(Current) or Wrappers[Current] then return false end

	Table.CalcAbsolutePosition = WrapOnce(Current)
	Origin.Classes = Origin.Classes + 1

	return true
end

--- Every scripted entity class that defines the function itself. Returns how many class tables were wrapped just now.
local function WrapClasses()
	local List = scripted_ents and isfunction(scripted_ents.GetList) and scripted_ents.GetList()
	local Done = 0

	if not istable(List) then return Done end

	for _, Data in pairs(List) do
		if istable(Data) and WrapClass(Data.t) then Done = Done + 1 end
	end

	return Done
end

--- Entities that exist already hold their own copy of the function (GUESS, see the header).
local function PatchEntities()
	for _, Ent in ipairs(ents.GetAll()) do
		if IsValid(Ent) then
			local Fn = Ent.CalcAbsolutePosition

			if isfunction(Fn) and not Wrappers[Fn] then
				Ent.CalcAbsolutePosition = WrapOnce(Fn)
				Origin.Entities = Origin.Entities + 1
			end
		end
	end
end

--- `Everything` also looks at every entity; the once-a-second scan does that only when it has just wrapped a class table (an entity
--- made before the wrap holds the old function), so an idle scan costs one pass over the class list.
local function Scan(Everything)
	local Changed = WrapClasses() > 0

	if Everything or Changed then PatchEntities() end

	if Origin.Classes + Origin.Entities > 0 then
		Compat.Status[Label] = string.format("wrapped (%d class table(s), %d entit%s)", Origin.Classes, Origin.Entities, Origin.Entities == 1 and "y" or "ies")
	else
		Compat.Status[Label] = "nothing to wrap yet (no scripted entity defines CalcAbsolutePosition)"
	end
end

local function Install() Scan(true) end

Origin.Install = Install

Install()

-- Scripted entity classes are registered after autorun files run, entities after that: the class tables are wrapped as soon as they
-- exist, and once a second after that (a Lua refresh registers a class again; an entity made before the wrap is patched).
hook.Add("Initialize", "ACFInfMapCompat_Origin", Install)
hook.Add("InitPostEntity", "ACFInfMapCompat_Origin", Install)

timer.Create("ACFInfMapCompat_Origin", 1, 0, function()
	local OK, Err = pcall(Scan, false)

	if not OK then Compat.Warn("The engine origin scan failed: ", tostring(Err)) end
end)

Compat.Register("cl_origin", Install)

-- ---------------------------------------------------------------------------------------------------- diagnostics
--- Text for `acf_infmap_entdebug`: the engine's position of an entity next to the position the server networked.
--- Exposed for the harness.
function Origin.Describe(Ent)
	local Defines = isfunction(Ent.CalcAbsolutePosition)
	local Own     = Defines and (Wrappers[Ent.CalcAbsolutePosition] and "yes, wrapped by this addon" or "yes, NOT wrapped") or "no"

	if not (isfunction(Ent.InfMap_GetPos) and isfunction(Ent.GetNetworkOrigin)) then
		return string.format("CalcAbsolutePosition: %s. Engine position vs networked position: cannot compare here.", Own)
	end

	if IsValid(Ent:GetParent()) then
		return string.format("CalcAbsolutePosition: %s. Engine position vs networked position: not compared (the entity has a parent).", Own)
	end

	local Diff = Ent:InfMap_GetPos() - Ent:GetNetworkOrigin()
	local Full = InfMap and InfMap.chunk_size and InfMap.chunk_size * 2 or 20000
	local Far  = Full * 0.1

	if math.abs(Diff.x) <= Far and math.abs(Diff.y) <= Far and math.abs(Diff.z) <= Far then
		return string.format("CalcAbsolutePosition: %s. Engine position vs networked position: the same (within %.0f units), as it should be.", Own, math.max(math.abs(Diff.x), math.abs(Diff.y), math.abs(Diff.z)))
	end

	return string.format("CalcAbsolutePosition: %s. Engine position vs networked position: DIFFERENT by %.0f %.0f %.0f units = %.2f %.2f %.2f chunks. The entity is drawn that far from where it is.",
		Own, Diff.x, Diff.y, Diff.z, Diff.x / Full, Diff.y / Full, Diff.z / Full)
end

Compat.StatusLines.cl_origin = function()
	return {
		string.format("origin: fix %s, %d class table(s) and %d entit%s wrapped, %d call(s) answered in the entity's own frame, errors %d",
			On:GetBool() and "ON" or "OFF", Origin.Classes, Origin.Entities, Origin.Entities == 1 and "y" or "ies", Stats.OriginCalls, Stats.OriginErrors),
	}
end
