-- Far effects (client): ACF's own effect code runs, its particles are drawn by this file.
--
-- Why this exists. The engine places and draws things only inside about +-16384 units of the frame origin, and under InfMap that
-- origin is the CENTRE of your chunk (not you). A hit effect, explosion or tracer more than that far from the chunk centre is
-- created but never drawn. That is about one chunk from you, and it is the reason hit effects stopped there.
--
-- What it does instead of giving up (or drawing a made-up picture, which version 3 did):
--   1. The effect is created through util.Effect exactly as before, so ACF's real effect code runs (acf_explosion.lua,
--      acf_smoke.lua, acf_penetration.lua ...), with the real random numbers, counts, sizes, velocities and materials.
--   2. While it runs, the global ParticleEmitter is replaced by a recorder. Every particle the effect adds, with every setting
--      ACF gives it (colour, size, alpha, velocity, gravity, air resistance, roll, length, life time), is kept in a list.
--   3. Each frame the particles are moved (gravity, drag) and drawn with render.DrawQuadEasy / render.DrawBeam. Those are
--      immediate-mode draw calls: they are not placed in the map's visibility tree, so the +-16384 box does not apply to them.
--      This is the same reason InfMap can draw its terrain through a camera at global coordinates (sh_inf_obj.lua).
--   4. A particle farther than `Near` from your eye is drawn on the same line of sight at `Near`, with its size, length and
--      offset shrunk by the same factor. Perspective makes that the same picture on screen (the particle is 12000 units away
--      instead of 60000, and 5 times smaller). It keeps the draw inside the camera's far plane.
--
-- Evidence labels: SEEN = read in source / run in the mock, KNOWN = standard GMod behaviour not re-checked, GUESS = needs a game.
--   SEEN:  every ACF effect that makes particles does it in Init with the GLOBAL ParticleEmitter (not a cached local) and
--          then only calls Add, Finish and the particle setters below (grep of lua/effects/*.lua). acf_bullet_effect keeps its
--          emitter and calls Add every tick.
--   SEEN:  InfMap draws its terrain with cam.Start3D at global coordinates (sh_inf_obj.lua) and the comment in cl_inf_chunks.lua
--          "when bounding box is outside of world bounds the object isn't rendered" is why other-chunk props use a shifted
--          camera and shrunken render bounds.
--   KNOWN: render.DrawQuadEasy(pos, normal, w, h, colour, rotation) and render.DrawBeam(start, end, width, u0, u1, colour) exist.
--   GUESS: that these immediate-mode calls draw at such positions. The shortening in point 4 keeps them within 12000 units of the
--          eye, which is inside the engine box when you are within 4384 units of your chunk's centre, and otherwise relies on
--          immediate-mode drawing not being clipped by the box. `acf_infmap_fartest` shows it in 5 seconds.
--   GUESS: the particle physics. GMod's exact air-resistance formula is not documented; `DragRate` is my guess. Particle
--          sprites, sizes, colours, counts and timing are ACF's own, so only how far a puff drifts can differ.
--   GUESS: a replayed particle is not hidden by terrain between you and it (it is drawn closer than it is). The same limit
--          applies to any far drawing here.
--   GUESS: effects that use a model or their own Render (the explosion's refraction sphere) show nothing far away. Only particles
--          are replayed. Engine-only effects (cball_explode) get a small generic puff (Synths below).

local Compat = ACFInfMapCompat
local Stats  = Compat.Stats

local On    = CreateClientConVar("acf_infmap_cl_replay", "1", true, false, "1 = draw ACF effects that are too far out for the engine (replayed particles). 0 = drop them.", 0, 1)
local Dist  = CreateClientConVar("acf_infmap_cl_replay_distance", "3000", true, false, "Metres. Far effects are drawn up to this distance from you.", 0, 10000)
local Scale = CreateClientConVar("acf_infmap_cl_replay_scale", "1", true, false, "Size multiplier for replayed particles.", 0.1, 5)

local Replay = Compat.Replay or {}

Compat.Replay = Replay
Replay.List   = Replay.List or {}
Replay.Errors = Replay.Errors or 0

local Near         = 12000 -- a particle farther than this is drawn at this distance (smaller). Stays inside the camera's far plane
local MaxParticles = 1500  -- all effects together
local MaxPerEffect = 400   -- one emitter
local MaxLife      = 30    -- seconds
local DragRate     = 0.015 -- GUESS: velocity is multiplied by (1 - AirResistance * DragRate * dt) each step

Replay.Near = Near

--- How far from the eye a far effect or tracer is still shown, in units.
function Replay.Range() return Dist:GetFloat() * Compat.MeterToUnit end

local function Noop() end

-- ---------------------------------------------------------------------------------------------------- particle recorder
local ParticleMT = {}

ParticleMT.__index = ParticleMT

-- Anything ACF (or a later ACF) calls on a particle that is not listed is accepted and ignored
setmetatable(ParticleMT, {__index = function(_, Key)
	if isstring(Key) and string.sub(Key, 1, 3) == "Set" then return Noop end
end})

function ParticleMT:SetColor(R, G, B) self.R, self.G, self.B = R or 255, G or 255, B or 255 end
function ParticleMT:SetStartAlpha(A) self.SA = A or 255 end
function ParticleMT:SetEndAlpha(A) self.EA = A or 0 end
function ParticleMT:SetStartSize(S) self.SS = S or 1 end
function ParticleMT:SetEndSize(S) self.ES = S or 1 end
function ParticleMT:SetStartLength(L) self.SL = L or 0 end
function ParticleMT:SetEndLength(L) self.EL = L or 0 end
function ParticleMT:SetDieTime(T) self.Die = math.min(T or 1, MaxLife) end
function ParticleMT:SetLifeTime(T) self.Age = T or 0 end -- negative: the particle starts later
function ParticleMT:SetRoll(R) self.Roll = R or 0 end
function ParticleMT:SetRollDelta(R) self.RollD = R or 0 end
function ParticleMT:SetAirResistance(A) self.Air = A or 0 end
function ParticleMT:SetVelocity(V) if isvector(V) then self.Vel = Vector(V.x, V.y, V.z) end end
function ParticleMT:SetGravity(V) if isvector(V) then self.Grav = Vector(V.x, V.y, V.z) end end
function ParticleMT:SetAngles(A) self.Ang = A end
function ParticleMT:SetPos(V) if isvector(V) then self.Pos = Vector(V.x, V.y, V.z) end end
function ParticleMT:GetPos() return self.Pos end
function ParticleMT:GetVelocity() return self.Vel end
function ParticleMT:GetDieTime() return self.Die end
function ParticleMT:GetLifeTime() return self.Age end

local EmitterMT = {}

EmitterMT.__index = EmitterMT

setmetatable(EmitterMT, {__index = function(_, Key)
	if isstring(Key) and (string.sub(Key, 1, 3) == "Set" or string.sub(Key, 1, 3) == "Get") then return Noop end
end})

--- Adds a particle. Returns nil when a limit is reached, like the real emitter does when it has no room.
function EmitterMT:Add(Material, Pos)
	if not self.valid or not isvector(Pos) then return nil end

	if (not self.Persistent and self.Count >= MaxPerEffect) or #Replay.List >= MaxParticles then
		Stats.ReplayDropped = Stats.ReplayDropped + 1

		return nil
	end

	local P = setmetatable({
		Mat = Material, Pos = Vector(Pos.x, Pos.y, Pos.z), Vel = Vector(0, 0, 0), Grav = Vector(0, 0, 0),
		R = 255, G = 255, B = 255, SA = 255, EA = 0, SS = 1, ES = 1, SL = 0, EL = 0,
		Die = 1, Age = 0, Roll = 0, RollD = 0, Air = 0,
	}, ParticleMT)

	Replay.List[#Replay.List + 1] = P
	self.Count = self.Count + 1
	Stats.ReplayParticles = Stats.ReplayParticles + 1

	return P
end

function EmitterMT:Finish() self.valid = false end
function EmitterMT:IsValid() return self.valid end
function EmitterMT:GetPos() return self.Pos end
function EmitterMT:SetPos(V) if isvector(V) then self.Pos = V end end
function EmitterMT:GetNumActiveParticles() return self.Count end

--- A recording emitter. `valid` is the field GMod's IsValid reads; IsValid() is the method it calls.
--- A persistent emitter (a bullet's tracer) adds particles for as long as the bullet lives, so only the global cap limits it.
local function NewEmitter(Pos, Persistent)
	return setmetatable({valid = true, Count = 0, Pos = Pos, Persistent = Persistent and true or false}, EmitterMT)
end

Replay.NewEmitter = NewEmitter

-- ---------------------------------------------------------------------------------------------------- running ACF's effect
--- The position the engine would have used if it clamped an out-of-range origin to its limit.
local function Clamped(Pos)
	local M = Compat.MaxEngine

	return Vector(math.Clamp(Pos.x, -M, M), math.Clamp(Pos.y, -M, M), math.Clamp(Pos.z, -M, M))
end

--- If the engine (or the effect) clamped the origin, every particle of the effect sits near the clamped point instead of the real one.
--- That is detected from where the new particles ended up and corrected, so a wrong guess about the engine cannot misplace effects.
local function Correct(First, True)
	local Last  = #Replay.List
	local Count = Last - First + 1

	if Count < 1 then return end

	local Fake = Clamped(True)

	if True:Distance(Fake) < 2000 then return end -- nothing to tell apart

	local Sum = Vector(0, 0, 0)

	for I = First, Last do Sum = Sum + Replay.List[I].Pos end

	local Centre = Sum / Count

	if Centre:Distance(Fake) >= Centre:Distance(True) then return end

	local Shift = True - Fake

	for I = First, Last do Replay.List[I].Pos = Replay.List[I].Pos + Shift end

	Stats.ReplayCorrected = Stats.ReplayCorrected + 1

	Compat.WarnOnce("clamped", "The engine clamped the position of a far effect to its limit; the particles were moved to the real position. (Counted as ReplayCorrected.)")
end

--- Creates the effect with util.Effect while the recorder stands in for ParticleEmitter.
--- Decals are switched off for the duration: an effect traces from its origin to find a surface, and out here that finds nothing
--- or, worse, a surface at the clamped position; a decal there would be a mark in the wrong place.
--- @param True Vector? # the real origin (for the clamp check)
--- @return boolean # whether the effect ran
function Replay.Run(Name, Data, AllowOverride, Ignore, True)
	if Replay.Disabled then return false end

	local RealEmitter  = _G.ParticleEmitter
	local RealDecalEx  = util.DecalEx
	local RealDecal    = util.Decal
	local Before       = Stats.ReplayParticles
	local First        = #Replay.List + 1

	_G.ParticleEmitter = function(Pos) return NewEmitter(Pos) end
	util.DecalEx       = Noop
	util.Decal         = Noop

	local OK, Err = pcall(util.Effect, Name, Data, AllowOverride, Ignore)

	-- always put the real ones back, even after an error
	_G.ParticleEmitter = RealEmitter
	util.DecalEx       = RealDecalEx
	util.Decal         = RealDecal

	if not OK then
		Stats.ReplayErrors = Stats.ReplayErrors + 1

		Compat.Warn("A far effect (", tostring(Name), ") raised an error while it was being recorded: ", tostring(Err))

		return false
	end

	if Stats.ReplayParticles == Before then
		Stats.ReplayEmpty = Stats.ReplayEmpty + 1
	elseif isvector(True) then
		Correct(First, True)
	end

	Stats.ReplayShown = Stats.ReplayShown + 1

	return true
end

-- Engine-only effects have no Lua code to run. A small generic puff stands in for them (GUESS: the look is mine).
local Synths = {}

Synths.cball_explode = function(F)
	local Pos = isvector(F.Origin) and F.Origin or F.Start

	if not isvector(Pos) then return false end

	local Cal    = math.Clamp(isnumber(F.Radius) and F.Radius or 10, 2, 60) -- the projectile's calibre in cm
	local Normal = isvector(F.Normal) and F.Normal or Vector(0, 0, 1)
	local Em     = NewEmitter(Pos)

	for _ = 1, 5 do
		local P = Em:Add("particle/smokesprites_000" .. math.random(1, 9), Pos)

		if P then
			P:SetVelocity((Normal + VectorRand() * 0.6) * Cal * 10)
			P:SetDieTime(math.Rand(0.8, 1.4))
			P:SetStartAlpha(150)
			P:SetEndAlpha(0)
			P:SetStartSize(Cal * 4)
			P:SetEndSize(Cal * 14)
			P:SetRoll(math.Rand(0, 6.28))
			P:SetRollDelta(math.Rand(-0.5, 0.5))
			P:SetAirResistance(60)
			P:SetGravity(Vector(0, 0, 15))
			P:SetColor(150, 140, 125)
		end
	end

	local Flash = Em:Add("effects/muzzleflash" .. math.random(1, 4), Pos)

	if Flash then
		Flash:SetDieTime(0.12)
		Flash:SetStartAlpha(220)
		Flash:SetEndAlpha(0)
		Flash:SetStartSize(Cal * 6)
		Flash:SetEndSize(Cal * 18)
		Flash:SetRoll(math.Rand(0, 6.28))
		Flash:SetColor(255, 255, 255)
	end

	for _ = 1, 4 do
		local Spark = Em:Add("effects/spark", Pos)

		if Spark then
			Spark:SetVelocity((Normal + VectorRand()) * Cal * 60)
			Spark:SetDieTime(math.Rand(0.2, 0.4))
			Spark:SetStartAlpha(255)
			Spark:SetEndAlpha(0)
			Spark:SetStartSize(Cal * 0.4)
			Spark:SetEndSize(0)
			Spark:SetStartLength(Cal * 3)
			Spark:SetEndLength(0)
			Spark:SetGravity(Vector(0, 0, -300))
			Spark:SetColor(255, 220, 160)
		end
	end

	Em:Finish()

	return true
end

Replay.Synths = Synths

--- The position an effect table is about: Origin, or Start for the few effects that keep their position there.
local function EffectPos(Table)
	if isvector(Table.Origin) then return Table.Origin end
	if isvector(Table.Start) then return Table.Start end
end

--- Handles an effect that is out of the engine's reach, once its EffectData exists.
--- @param Name string
--- @param Data CEffectData # already filled
--- @param Fields table # the same values by name (for engine-only effects)
--- @return boolean # whether something was done (false: nothing will be shown)
function Replay.Show(Name, Data, AllowOverride, Ignore, Fields)
	if not On:GetBool() or Replay.Disabled then return false end

	local Lower = string.lower(Name)
	local Synth = Synths[Lower]

	if Synth then
		Stats.ReplayShown = Stats.ReplayShown + 1

		return Synth(Fields) ~= false
	end

	-- Lua effects of ACF: run their code. Other addons' effects are not ours to replay.
	if string.sub(Lower, 1, 4) ~= "acf_" then
		Stats.ReplayDropped = Stats.ReplayDropped + 1

		return false
	end

	return Replay.Run(Name, Data, AllowOverride, Ignore, EffectPos(Fields))
end

--- The path for an effect the server sent (cl_effects.lua): range check, then Show.
function Replay.Dispatch(Name, Values, Data, AllowOverride, Ignore)
	local Pos = Values.Origin

	if not isvector(Pos) then return false end

	if Pos:Distance(EyePos()) > Dist:GetFloat() * Compat.MeterToUnit then
		Stats.ReplayDropped = Stats.ReplayDropped + 1

		return false
	end

	return Replay.Show(Name, Data, AllowOverride, Ignore, Values)
end

--- Same as ACF's Effects.CreateEffect for an effect whose position is out of the engine's reach.
function Replay.Create(Name, Table, AllowOverride, Filter)
	local NewName, NewTable = hook.Run("ACF_PreCreateEffect", Name, Table)

	Name  = NewName or Name
	Table = NewTable or Table

	local Data = EffectData()

	for Field, Value in pairs(Table) do
		local Set = Data["Set" .. Field]

		if Set then Set(Data, Value) end
	end

	local Pos = EffectPos(Table)

	-- The hook may have moved it back inside
	if not Pos or Compat.InWindow(Pos) then return util.Effect(Name, Data, AllowOverride, Filter) end

	if Pos:Distance(EyePos()) > Dist:GetFloat() * Compat.MeterToUnit then
		Stats.ReplayDropped = Stats.ReplayDropped + 1

		return
	end

	Replay.Show(Name, Data, AllowOverride, Filter, Table)
end

-- ---------------------------------------------------------------------------------------------------- simulation and drawing
function Replay.Clear() Replay.List = {} Replay.Last = nil end

--- Moves every replayed particle (the player crossed a chunk border: the frame origin moved).
function Replay.Shift(Delta)
	for _, P in ipairs(Replay.List) do P.Pos = P.Pos + Delta end
end

--- One simulation step for every particle. Dead ones are removed.
function Replay.Step(Dt)
	local List = Replay.List

	for I = #List, 1, -1 do
		local P = List[I]

		P.Age = P.Age + Dt

		if P.Age >= P.Die then
			List[I] = List[#List]
			List[#List] = nil
		elseif P.Age >= 0 and Dt > 0 then
			P.Vel = (P.Vel + P.Grav * Dt) * math.max(0, 1 - P.Air * DragRate * Dt)
			P.Pos = P.Pos + P.Vel * Dt
		end
	end
end

hook.Add("Think", "ACFInfMapCompat_ReplayStep", function()
	if not Replay.List[1] then Replay.Last = nil return end

	local Now = CurTime()
	local Dt  = Replay.Last and math.Clamp(Now - Replay.Last, 0, 0.1) or 0

	Replay.Last = Now

	Replay.Step(Dt)
end)

local Materials = {}

local function GetMaterial(Path)
	if not isstring(Path) then return Path end -- an IMaterial passes through

	local Mat = Materials[Path]

	if Mat == nil then
		Mat = Material((string.gsub(Path, "%.vmt$", ""))) or false
		Materials[Path] = Mat
	end

	return Mat or nil
end

local DrawColor = Color(255, 255, 255, 255)

--- Draws every particle once. `Eye` is the camera position.
function Replay.Draw(Eye)
	local List = Replay.List

	if not List[1] then return end

	local Mul = Scale:GetFloat()
	local Fwd = EyeAngles():Forward()

	for I = 1, #List do
		local P = List[I]

		if P.Age >= 0 and P.Age < P.Die then
			local Dir = P.Pos - Eye
			local D   = Dir:Length()

			if D > 0 and Dir:Dot(Fwd) > 0 then
				local K    = D > Near and Near / D or 1
				local At   = Eye + Dir * K
				local T    = P.Age / P.Die
				local Size = (P.SS + (P.ES - P.SS) * T) * Mul * K
				local Mat  = GetMaterial(P.Mat)

				if Mat and Size > 0 then
					DrawColor.r, DrawColor.g, DrawColor.b = P.R, P.G, P.B
					DrawColor.a = math.Clamp(P.SA + (P.EA - P.SA) * T, 0, 255)

					render.SetMaterial(Mat)

					local Len = (P.SL + (P.EL - P.SL) * T) * K

					if Len > 0 then
						local Heading = P.Vel:Length() > 0.001 and P.Vel:GetNormalized() or (P.Ang and P.Ang:Forward() or Fwd)

						render.DrawBeam(At - Heading * Len, At, Size, 0, 1, DrawColor)
					else
						render.DrawQuadEasy(At, (Eye - At):GetNormalized(), Size, Size, DrawColor, math.deg(P.Roll + P.RollD * P.Age))
					end
				end
			end
		end
	end
end

hook.Add("PostDrawTranslucentRenderables", "ACFInfMapCompat_Replay", function(_, Skybox, Skybox3D)
	if Skybox or Skybox3D or Replay.Disabled or not Replay.List[1] then return end

	local OK, Err = pcall(Replay.Draw, EyePos())

	if OK then return end

	Replay.Errors = Replay.Errors + 1

	if Replay.Errors == 1 then Compat.Warn("Far effect drawing raised an error: ", tostring(Err)) end

	if Replay.Errors >= 5 then
		Replay.Disabled = true

		Compat.Warn("Far effect drawing raised errors five times and switched itself off. `lua_run` is not needed: reload the map to retry.")
	end
end)

-- ---------------------------------------------------------------------------------------------------- installer, commands
Compat.Register("cl_replay", function()
	-- ACF's client-side impact effects are created with Effects.CreateEffect from the bullet's simulated position. When that
	-- position is outside the window, ACF's effect code runs through the recorder instead of the engine.
	Compat.Wrap(ACF.Utilities.Effects, "CreateEffect", function(Original)
		return function(Name, Table, AllowOverride, Filter)
			if On:GetBool() and Name and istable(Table) then
				local Pos = EffectPos(Table)

				if Pos and not Compat.InWindow(Pos) then return Replay.Create(Name, Table, AllowOverride, Filter) end
			end

			return Original(Name, Table, AllowOverride, Filter)
		end
	end, "Effects.CreateEffect (client)")
end)

--- A real ACF explosion `Meters` metres ahead of you. Inside the window it is an ordinary engine effect, outside it is replayed.
concommand.Add("acf_infmap_fartest", function(_, _, Args)
	local Meters = tonumber(Args and Args[1]) or 1500
	local Pos    = EyePos() + EyeAngles():Forward() * Meters * Compat.MeterToUnit
	local Before = Stats.ReplayShown

	ACF.Utilities.Effects.CreateEffect("ACF_Explosion", {Origin = Pos, Normal = Vector(0, 0, 1), Scale = 400})

	if Stats.ReplayShown > Before then
		Compat.Say("explosion ", Meters, " m ahead: replayed (beyond the engine's reach), ", #Replay.List, " particles live")
	elseif Compat.InWindow(Pos) then
		Compat.Say("explosion ", Meters, " m ahead: that is inside the area the engine can draw, so it is an ordinary engine effect. Try a larger distance.")
	elseif not On:GetBool() then
		Compat.Say("explosion ", Meters, " m ahead: far effects are switched off (acf_infmap_cl_replay 0), so nothing is shown.")
	else
		Compat.Say("explosion ", Meters, " m ahead: farther than your far effect distance (", Dist:GetFloat(), " m, acf_infmap_cl_replay_distance), so nothing is shown.")
	end
end)

concommand.Add("acf_infmap_replaydebug", function()
	print(string.format("[ACF-InfMap] replay: %s, %d particle(s) live, %d recorded in total, %d effects replayed, %d effects empty, %d dropped, %d errors",
		(On:GetBool() and not Replay.Disabled) and "ON" or "OFF", #Replay.List, Stats.ReplayParticles, Stats.ReplayShown, Stats.ReplayEmpty, Stats.ReplayDropped, Stats.ReplayErrors))

	for I = 1, math.min(#Replay.List, 10) do
		local P = Replay.List[I]

		print(string.format("  %s pos=(%.0f %.0f %.0f) age=%.2f/%.2f size=%.1f->%.1f", tostring(P.Mat), P.Pos.x, P.Pos.y, P.Pos.z, P.Age, P.Die, P.SS, P.ES))
	end
end)

Compat.StatusLines.cl_replay = function()
	return {
		string.format("far effects: %s, up to %g m, %d particle(s) live, %d replayed, %d dropped", (On:GetBool() and not Replay.Disabled) and "ON" or "OFF", Dist:GetFloat(), #Replay.List, Stats.ReplayShown, Stats.ReplayDropped),
	}
end
