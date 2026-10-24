-- ACF effects (client half): receives the message from sv_effects.lua and creates the effect in the local player's frame.
--
-- What it does:
--   1. Converts the effect's global Origin into the local player's chunk frame (Origin - chunk * 20000, in doubles).
--   2. An Origin inside the placeable window (Compat.Window, 16000 units from the frame origin) becomes a normal util.Effect, so
--      ACF's own effect code runs on an ordinary local position. An Origin outside it goes to cl_replay.lua, which runs the same
--      ACF effect code but draws its particles itself (the engine cannot place an effect that far out).
--   3. Resolves EntIndex to a real entity (see FixEntity): this is what makes ACF's bullet / tracer effect work.
--   4. When the local player crosses into another chunk, moves every tracer ACF is simulating (and every replayed particle) by
--      one chunk, so nothing jumps.
--
-- Evidence labels: SEEN = read in source / run in the mock, KNOWN = standard GMod behaviour not re-checked, GUESS = needs a game.
--   SEEN:  client Entity:GetPos() is relative to the local player's chunk, and the player's chunk is LocalPlayer().CHUNK_OFFSET
--          (infmap/cl_inf_detours.lua, cl_inf_chunks.lua)
--   SEEN:  ACF's tracer effect (effects/acf_bullet_effect.lua) finds the ammo crate with Data:GetEntity() and gives up (no tracer,
--          no model, and the later hit message finds nothing to update, so no impact either) when that entity is not valid.
--          The server sets the crate as `EntIndex` (a number: ballistics_sv.lua, `Bullet.Crate = Entity:EntIndex()`).
--   SEEN:  GMod wiki: CEffectData:SetEntIndex and GetEntIndex are SERVER-only; SetEntity and GetEntity exist on both realms.
--          So a client-made EffectData cannot carry the crate by index. FixEntity sets it with SetEntity.
--   SEEN (play-test 6.6 and 6.7): the game hands out an EffectData that still holds the values of an earlier effect ("it still held:
--          Normal, Origin, Scale" was printed by 6.7). The muzzle flash before a shell carries `Entity = gun`, and a shell built from
--          an EffectData that was not blanked got the GUN as its ammo crate: no tracer, drag 1 (the shell flew off), no filler (no
--          HE explosion). Every EffectData is therefore blanked (FreshEffect) and the crate is always set explicitly. This fixed it.
--   SEEN:  ACF simulates every tracer on the client from the Origin it was sent, in ACF.BulletEffect[Index].SimPos
--          (ballistics_cl.lua, effects/acf_bullet_effect.lua)
--   SEEN:  chunk-to-chunk frame shift is Full = 2 * InfMap.chunk_size per chunk, from InfMap.unlocalize_vector
--   KNOWN: util.Effect called on the client creates the effect locally and runs its Init at once.
--   GUESS: that LocalPlayer().CHUNK_OFFSET is already updated on the client at the moment this message arrives after a chunk
--          change. If it lags by a tick, effects created in that tick are off by one chunk, visibly only while crossing.

local Compat = ACFInfMapCompat
local Stats  = Compat.Stats
local Tag    = Compat.EffectTag
local Fields = Compat.EffectFields

-- Effects that must always be created natively, whatever their position (cl_bullets.lua decides what to do when they are far)
local SelfManaged = {acf_bullet_effect = true}

local function ReadValue(Kind, Field)
	if Kind == Tag.Number then
		return net.ReadDouble()
	elseif Kind == Tag.Vector then
		local X, Y, Z = net.ReadDouble(), net.ReadDouble(), net.ReadDouble()

		-- Origin stays three plain numbers until it has been converted, because a Vector holds 32-bit floats
		if Field == "Origin" then return {X, Y, Z} end

		return Vector(X, Y, Z)
	elseif Kind == Tag.Angle then
		return Angle(net.ReadFloat(), net.ReadFloat(), net.ReadFloat())
	elseif Kind == Tag.Entity then
		return net.ReadEntity()
	end

	return net.ReadBool()
end

--- Converts a global position (three numbers) into the local player's frame.
--- @return Vector # the local-frame position
--- @return boolean # whether it is inside the window where native effects can be placed
local function ToLocalFrame(Global)
	local _, Full = Compat.ChunkSizes()
	local Player  = LocalPlayer()
	local Offset  = IsValid(Player) and Player.CHUNK_OFFSET or nil
	local X, Y, Z = Global[1], Global[2], Global[3]

	if Offset then
		X, Y, Z = X - Offset.x * Full, Y - Offset.y * Full, Z - Offset.z * Full
	end

	local Local = Vector(X, Y, Z)

	return Local, Compat.InWindow(Local)
end

Compat.ToLocalFrame = ToLocalFrame

-- The neutral value of every EffectData field (what a brand-new CEffectData holds): 0, a zero vector, a zero angle, no entity
local Neutral = {
	Angles = function() return Angle(0, 0, 0) end,
	Normal = function() return Vector(0, 0, 0) end,
	Origin = function() return Vector(0, 0, 0) end,
	Start  = function() return Vector(0, 0, 0) end,
	Entity = function() return NULL end,
}

--- An EffectData with every field set to its neutral value, so that only what the server sent ends up in it.
--- A field is skipped when `Skip` (a table keyed by field name) is about to give it a value anyway.
--- @param Skip table? Field names that will be set by the caller
--- @return table # the EffectData
local function FreshEffect(Skip)
	local Effect = EffectData()

	for _, Field in ipairs(Fields) do
		local Set = Effect["Set" .. Field]

		if Set and not (Skip and Skip[Field] ~= nil) then
			local Make = Neutral[Field]

			pcall(Set, Effect, Make and Make() or 0)
		end
	end

	return Effect
end

Compat.FreshEffect = FreshEffect

--- Sets the effect's entity to the real entity. A server effect carries the entity as an index (`EntIndex`); ACF's tracer effect
--- reads it back with Data:GetEntity(), so the entity has to be set explicitly on a client-made EffectData. An entity the server
--- sent as an entity (the `Entity` field, e.g. a muzzle flash) was already set when the fields were applied. When this client does
--- not know the entity (not streamed in yet) the effect keeps no entity at all, and ACF's bullet effect then gives up on that shell.
local function FixEntity(Effect, Values)
	local Index = Values.EntIndex

	if not isnumber(Index) or Index <= 0 then return end

	local Ent = Entity(Index)

	if IsValid(Ent) then Effect:SetEntity(Ent) end
end

Compat.FixEntity = FixEntity

local Told = {}

--- Prints a warning once per kind per session
function Compat.WarnOnce(Kind, ...)
	if Told[Kind] then return end

	Told[Kind] = true
	Compat.Warn(...)
end

net.Receive("ACFInfMapCompat_Effect", function()
	local Name   = net.ReadString()
	local Allow  = net.ReadBool()
	local Ignore = net.ReadBool()
	local Values = {}

	-- Read the whole message first, so a dropped effect never leaves unread bytes behind
	for _ = 1, net.ReadUInt(5) do
		local Field = Fields[net.ReadUInt(5)]
		local Value = ReadValue(net.ReadUInt(3), Field)

		if Field then Values[Field] = Value end
	end

	local Inside = true

	if Values.Origin then
		local Local
		Local, Inside = ToLocalFrame(Values.Origin)

		Values.Origin = Local
	end

	local Effect = FreshEffect(Values)

	for Field, Value in pairs(Values) do
		local Set = Effect["Set" .. Field]

		if Set then Set(Effect, Value) end
	end

	FixEntity(Effect, Values)

	-- Too far out for the engine: ACF's effect code still runs, but its particles are drawn by cl_replay.lua.
	-- Bullet effects are handled by cl_bullets.lua (the hit message must always reach them: without it the impact at the end
	-- of the flight has nothing to update).
	if not Inside and not SelfManaged[string.lower(Name)] then
		if Compat.Replay and Compat.Replay.Dispatch(Name, Values, Effect, Allow, Ignore) then return end

		Stats.EffectsDropped = Stats.EffectsDropped + 1

		return
	end

	util.Effect(Name, Effect, Allow, Ignore)

	Stats.EffectsShown = Stats.EffectsShown + 1
end)

-- Keeps ACF's own tracer simulation (and the replayed particles) in step with the player's chunk
local LastChunk

hook.Add("ACF_OnTick", "ACFInfMapCompat_BulletFrame", function()
	local Player = LocalPlayer()

	if not IsValid(Player) then return end

	local Now = Player.CHUNK_OFFSET

	if not Now then return end

	if LastChunk and (LastChunk.x ~= Now.x or LastChunk.y ~= Now.y or LastChunk.z ~= Now.z) then
		local _, Full = Compat.ChunkSizes()
		local Shift   = Vector((LastChunk.x - Now.x) * Full, (LastChunk.y - Now.y) * Full, (LastChunk.z - Now.z) * Full)

		for _, Bullet in pairs(ACF.BulletEffect or {}) do
			if Bullet.SimPos then Bullet.SimPos = Bullet.SimPos + Shift end
			if Bullet.SimPosLast then Bullet.SimPosLast = Bullet.SimPosLast + Shift end

			if IsValid(Bullet.Effect) and Bullet.SimPos and not Bullet.Effect.ACFInfMapFar then Bullet.Effect:SetPos(Bullet.SimPos) end
			if Bullet.Tracer and IsValid(Bullet.Tracer) and Bullet.SimPos and Bullet.Tracer.SetPos then Bullet.Tracer:SetPos(Bullet.SimPos) end
		end

		if Compat.Replay then Compat.Replay.Shift(Shift) end
	end

	LastChunk = Vector(Now.x, Now.y, Now.z)
end)

Compat.StatusLines.cl_effects = function()
	local Count = 0

	for _ in pairs(ACF.BulletEffect or {}) do Count = Count + 1 end

	return {
		string.format("effects: you are in chunk %s, %d tracer(s) simulated", Compat.ChunkText(LocalPlayer()), Count),
	}
end
