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
--          So a client-made EffectData cannot carry the crate by index. FixEntity sets it with SetEntity, and `EntityFixed`
--          counts the times it was needed.
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

local Verbose = CreateClientConVar("acf_infmap_verbose", "0", true, false, "1 = print a line for every ACF effect this client receives from the server.", 0, 1)

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

--- Makes sure the effect's entity is the real entity. A server effect carries the entity as an index (`EntIndex`); ACF's tracer
--- effect reads it back with Data:GetEntity(), so the entity has to be set explicitly on a client-made EffectData.
--- @return boolean? # whether GetEntity already returned a valid entity before the fix (nil: the effect has no EntIndex)
--- @return boolean? # whether it does now
local function FixEntity(Effect, Values)
	local Index = Values.EntIndex

	if not isnumber(Index) or Index <= 0 then return end

	local Has = false

	if Effect.GetEntity then
		local OK, Ent = pcall(Effect.GetEntity, Effect)

		Has = OK and IsValid(Ent)
	end

	if Has then return true, true end

	local Ent = Entity(Index)

	if IsValid(Ent) then
		Effect:SetEntity(Ent)
		Stats.EntityFixed = Stats.EntityFixed + 1

		return false, true
	end

	Stats.EntityMissing = Stats.EntityMissing + 1 -- the client does not know that entity (yet): nothing can be done here

	return false, false
end

Compat.FixEntity = FixEntity

-- The last few bullet effects this client received, for `acf_infmap_bulletdebug`. Lives on the addon table.
Compat.BulletLog = Compat.BulletLog or {}

local LogSize = 12

local function LogBullet(Name, Values, Inside, Before, After, Created)
	local Log = Compat.BulletLog
	local Speed

	if isvector(Values.Start) then Speed = Values.Start:Length() * 10 / Compat.MeterToUnit end -- ACF: Flight = Start * 10, units per second

	local Crate = isnumber(Values.EntIndex) and Values.EntIndex > 0 and Entity(Values.EntIndex) or nil

	Log[#Log + 1] = {
		Time = CurTime(), Name = Name, Index = Values.DamageType, Hit = Values.Scale, Attachment = Values.Attachment, Origin = Values.Origin,
		Inside = Inside, EntIndex = Values.EntIndex, Before = Before, After = After, Created = Created, Speed = Speed,
		Crate = (Compat.CrateFacts and IsValid(Crate)) and Compat.CrateFacts(Crate) or nil,
	}

	if #Log > LogSize then table.remove(Log, 1) end
end

local Told = {}

--- Prints a warning once per kind per session (and always when acf_infmap_verbose is on)
function Compat.WarnOnce(Kind, ...)
	if Told[Kind] and not Verbose:GetBool() then return end

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

	local Effect = EffectData()

	for Field, Value in pairs(Values) do
		local Set = Effect["Set" .. Field]

		if Set then Set(Effect, Value) end
	end

	local Lower  = string.lower(Name)
	local Before, After = FixEntity(Effect, Values)
	local IsBullet = SelfManaged[Lower]

	if Verbose:GetBool() then
		local O = Values.Origin

		print(string.format("[ACF-InfMap] effect %s origin %s inside-window=%s", Name,
			O and string.format("(%.0f %.0f %.0f)", O.x, O.y, O.z) or "-", tostring(Inside)))
	end

	-- Too far out for the engine: ACF's effect code still runs, but its particles are drawn by cl_replay.lua.
	-- Bullet effects are handled by cl_bullets.lua (the hit message must always reach them: without it the impact at the end
	-- of the flight has nothing to update).
	if not Inside and not IsBullet then
		if Compat.Replay and Compat.Replay.Dispatch(Name, Values, Effect, Allow, Ignore) then return end

		Stats.EffectsDropped = Stats.EffectsDropped + 1

		return
	end

	-- A hit / end-of-flight message ("Update", Scale > 0): remember it, so the life log can say why a bullet ended
	if IsBullet and (Values.Scale or 0) > 0 and Compat.NoteBulletHit then Compat.NoteBulletHit(Values.DamageType, Values.Scale) end

	util.Effect(Name, Effect, Allow, Ignore)

	Stats.EffectsShown = Stats.EffectsShown + 1

	-- A new bullet (Scale 0) has to exist in ACF's table right after its Init ran, else ACF refused it (Init is synchronous)
	if IsBullet and (Values.Scale or 0) == 0 and isnumber(Values.DamageType) then
		local Created = ACF.BulletEffect ~= nil and ACF.BulletEffect[Values.DamageType] ~= nil

		LogBullet(Name, Values, Inside, Before, After, Created)

		if not Created then
			Stats.BulletRefused = Stats.BulletRefused + 1

			Compat.WarnOnce("refused", "ACF refused a new bullet effect (#", Values.DamageType, "): ",
				After == false and ("the ammo crate (entity " .. tostring(Values.EntIndex) .. ") is not known to this client.")
				or "its Init gave up. Run acf_infmap_bulletdebug for the details.")
		end
	elseif IsBullet then
		LogBullet(Name, Values, Inside, Before, After, nil)
	end
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

-- What did this client receive and what is it simulating? The first thing to run if a tracer or a hit effect is missing.
local function Num(Value) return isnumber(Value) and string.format("%g", Value) or "-" end
local function Pos(Vec) return isvector(Vec) and string.format("(%.0f %.0f %.0f)", Vec.x, Vec.y, Vec.z) or "-" end
local function Flag(Value) if Value == nil then return "n/a" end return Value and "yes" or "NO" end

concommand.Add("acf_infmap_bulletdebug", function()
	print(string.format("[ACF-InfMap] bullet effects this client received (oldest first, last %d). Chunk %s. Time now t=%.1f (if this does not move between two runs, the game was paused)", LogSize, Compat.ChunkText(LocalPlayer()), CurTime()))

	for _, E in ipairs(Compat.BulletLog) do
		print(string.format("  t=%.1f index=%s hit=%s attachment=%s origin=%s inside-window=%s crate-index=%s crate-valid-before-fix=%s after=%s created=%s speed=%s m/s",
			E.Time, Num(E.Index), Num(E.Hit), Num(E.Attachment), Pos(E.Origin), Flag(E.Inside), Num(E.EntIndex), Flag(E.Before), Flag(E.After), Flag(E.Created),
			E.Speed and string.format("%.0f", E.Speed) or "-"))

		if E.Crate then print("      crate: " .. E.Crate) end
	end

	print("  simulated right now:")

	local Any = false

	for Index, Bullet in pairs(ACF.BulletEffect or {}) do
		Any = true

		local Effect = Bullet.Effect

		print(string.format("  #%s pos=%s inside-window=%s draws=%s tracer-emitter=%s far=%s effect-valid=%s renders=%s age=%.2fs",
			tostring(Index), Pos(Bullet.SimPos), Flag(isvector(Bullet.SimPos) and Compat.InWindow(Bullet.SimPos)), Flag(Effect and Effect.DrawEffect and true or false),
			Flag(Bullet.Tracer ~= nil and IsValid(Bullet.Tracer)), Flag(Effect and Effect.ACFInfMapFar and true or false), Flag(IsValid(Effect)),
			Num(Effect and Effect.ACFInfMapRenders), Effect and Effect.ACFInfMapBorn and CurTime() - Effect.ACFInfMapBorn or 0))

		print(string.format("      speed %s m/s, model %s at scale %s, crate: %s",
			isvector(Bullet.SimFlight) and string.format("%.0f", Bullet.SimFlight:Length() / Compat.MeterToUnit) or "-",
			Effect and Effect.GetModel and tostring(Effect:GetModel()) or "-", Effect and Effect.GetModelScale and Num(Effect:GetModelScale()) or "-",
			Compat.CrateFacts and Compat.CrateFacts(Bullet.Crate) or "-"))
	end

	if not Any then print("  (none)") end

	local Ended = Compat.Bullets and Compat.Bullets.Ended or {}

	print("  bullets that stopped being simulated (oldest first, last 12):")

	for _, E in ipairs(Ended) do
		print(string.format("  #%s lived %.2f s, last position %s%s, engine renders %s, speed %s m/s, ended by: %s - %s",
			tostring(E.Index), E.Ended - E.Born, Pos(E.Pos), E.Far and " (beyond the window)" or "", Num(E.Renders), E.Speed and string.format("%.0f", E.Speed) or "-", E.Kind, tostring(E.Why)))
	end

	if #Ended == 0 then print("  (none yet)") end
end)

Compat.StatusLines.cl_effects = function()
	local Count = 0

	for _ in pairs(ACF.BulletEffect or {}) do Count = Count + 1 end

	return {
		string.format("effects: you are in chunk %s, %d tracer(s) simulated", Compat.ChunkText(LocalPlayer()), Count),
	}
end
