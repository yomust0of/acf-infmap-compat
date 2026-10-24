-- Bullet effects (client): keeps ACF's simulated bullets alive past the engine's placement limit, shows their tracer there, and
-- says what is wrong when a bullet model is not drawn.
--
-- ACF simulates every bullet on the client (ACF.BulletEffect[Index], moved each tick by EFFECT:ApplyMovement) and the effect
-- entity is only the thing that draws it. Three things go wrong under InfMap, and this file handles each of them:
--
--  1. ACF kills the effect when the bullet is more than 16380 units from the frame origin (ApplyMovement, SEEN). Under InfMap the
--     frame origin is the CENTRE of your chunk, so a shell leaves that box after about one chunk. The hit message that arrives
--     later ("Update", Scale > 0) finds no entry and creates nothing: no AP impact, no penetration, no ricochet. That is the
--     "hit effects stop one chunk away" half that is not about drawing. Fix: from the window edge on, ApplyMovement is replaced
--     for that bullet: the simulation keeps running, the engine entity is hidden, and the tracer is added to the replay renderer
--     (cl_replay.lua) instead of an engine emitter. Inside the window ACF's own code runs untouched.
--  2. The engine will not place or draw anything outside that box (see cl_replay.lua), so the tracer beyond it needs the replay
--     renderer anyway.
--  3. A bullet model that never appears. The cause is not known (see below), so this file measures instead of guessing: it counts
--     how often the engine really calls the effect's Render, and when a bullet inside the window gets no Render calls at all it
--     draws the model itself from ACF's own simulation state and reports that it did. `acf_infmap_bulletdebug` and
--     `acf_infmap_status` show the counters; `acf_infmap_bullettest` creates a harmless test shell through ACF's real effect.
--
-- Evidence labels: SEEN = read in source / run in the mock, KNOWN = standard GMod behaviour not re-checked, GUESS = needs a game.
--   SEEN:  ApplyMovement kills at |x| or |y| > 16380 or z < -16380, otherwise SetPos + tracer particles; Think keeps the effect for
--          45 s unless Kill is set; the hit message sets Kill itself (effects/acf_bullet_effect.lua).
--   SEEN:  ACF's own missile code replaces Effect.ApplyMovement per instance in the ACF_OnCreateBulletEffect hook
--          (missiles/acfm_effects_cl.lua). This file uses the same hook and the same replacement. The hook order between two
--          addons is not defined, so the replacement is re-checked every tick.
--   SEEN:  the tracer is one stretched sprite per tick (sprites/acf_tracer.vmt, alpha 255) plus two smoke puffs that start at alpha
--          10 and size 1. Far away only the sprite can be seen, so only it is replayed.
--   GUESS: that the engine calls a per-instance Render function. If it does not, the Render counter stays 0, this addon draws the
--          model as well, and the two copies sit in the same place and look like one. The counter then proves nothing about the
--          engine, and the status line says so.
--   GUESS: that a stretched particle sprite is drawn from its position back along its direction.
--   GUESS: that ACF's Init runs inside util.Effect (the test command checks it and prints the answer).
--
-- Version 5 additions (from a real play-test, see README):
--   SEEN (play-test): ACF's own Data:GetEntity() already returned the crate before this addon set it (crate-valid-before-fix=yes,
--          EntityFixed=0): the engine DOES resolve SetEntIndex on a client-made EffectData. The crate fix is only a fallback.
--   SEEN (play-test): `tracer-emitter=NO` for a real cannon bullet, and the test shell found no tracer crate. ACF only makes a
--          tracer when Crate:GetNW2Float("Tracer") > 0 (effects/acf_bullet_effect.lua), and the crate's Tracer value is
--          Caliber * 0.15 when the "Tracer" tick box of the ammo is on and 0 when it is off (core/round_functions.lua). The debug
--          lines now print that value, so "no tracer" is a number and not a guess.
--   SEEN (play-test): bullets 1-8 were gone from the client table with no hit message received for any of them. Nothing in this
--          file or ACF explains that by reading, so every bullet that leaves the table is now logged with the reason this code can
--          observe: range limit (this file), hit message (cl_effects.lua), ACF's own limit, 45 s timeout, or "unknown".
--
-- Version 6 additions (a second play-test: cannon shells and their tracers were still not seen, no console output with it):
--   Nothing in ACF's or this addon's code, read line by line, stops a real shell from being drawn inside the window, and the one
--   shell that was followed in the play-test was drawn by the engine once. Three facts together explain "I cannot see it" without
--   any defect, and none of them can be told from the armchair: how fast the shell is (a 800 m/s shell crosses 100 m in 0.12 s,
--   about 7 frames at 60 fps), whether the crate's Tracer is on (no emitter is made when it is 0), and whether the server marked
--   the bullet hidden (Attachment 0). So every real shot now writes ONE line to the console when its bullet ends, with those facts
--   as numbers: acf_infmap_cl_shot_report (default 1, at most 8 lines per 10 s, the rest are counted). And
--   acf_infmap_cl_force_tracer (default 0) gives every real shell a tracer through ACF's own tracer code, to separate "the tracer
--   does not render" from "the crate has no tracer".
--   SEEN:  ACF reads the tracer from the crate once, when the bullet is created (Tracer = Crate:GetNW2Float("Tracer") > 0), and the
--          draw flag from EffectData:GetAttachment() (the server sends 0 for Bullet.Hide, which only the piledriver and one special
--          shell set). Changing the crate's tick box later does not change shells that are already in flight.
--   GUESS: that a fast shell is simply too brief to notice. The line prints the frames the engine drew it, so this is a number.
--   GUESS: that EyePos() answers with the last view origin when it is called outside a render hook (the distances in the line and
--          the far-distance kill above use it from the effect's Think). If it answered with something else the distances would be
--          off; the speed, the frame counts, the lifetime and the tracer facts do not depend on it.

local Compat = ACFInfMapCompat
local Stats  = Compat.Stats

local On      = CreateClientConVar("acf_infmap_cl_bullets", "1", true, false, "1 = keep ACF bullets alive past the engine's placement limit and draw their tracers there. 0 = stock behaviour.", 0, 1)
local OwnDraw = CreateClientConVar("acf_infmap_cl_bullet_draw", "1", true, false, "1 = if the engine never draws a bullet's model, draw it from ACF's own simulation state.", 0, 1)

local Report      = CreateClientConVar("acf_infmap_cl_shot_report", "1", true, false, "1 = print one line to the console for every real shot when its bullet ends: tracer setting, speed, distances, frames drawn, why it ended.", 0, 1)
local ForceTracer = CreateClientConVar("acf_infmap_cl_force_tracer", "0", true, false, "1 = give every real shell a tracer even if its crate's Tracer is off (diagnostic: ACF's own tracer code, the crate's colour).", 0, 1)

local Bullets = {}

Compat.Bullets = Bullets
Bullets.Errors = Bullets.Errors or 0

local FramesBeforeDiagnosis = 3 -- rendered frames a new bullet gets before "never drawn" is concluded

local function Alive(Effect) return Effect ~= nil and IsValid(Effect) end

-- ---------------------------------------------------------------------------------------------------- life log
-- Every bullet this client has simulated, and why each one stopped. `Seen[Index]` is what was last observed of a live bullet,
-- `Ended` is a ring of the last EndedSize bullets that left ACF.BulletEffect.
Bullets.Seen  = Bullets.Seen or {}
Bullets.Ended = Bullets.Ended or {}
Bullets.Hits  = Bullets.Hits or {} -- [Index] = {Time, Type}: the last hit message received for that index

local EndedSize = 12

--- Called by the effect receiver for every "Update" (hit) message, before ACF handles it.
function Compat.NoteBulletHit(Index, Type)
	if isnumber(Index) then Bullets.Hits[Index] = {Time = CurTime(), Type = Type} end
end

local function EndReason(Seen)
	local Effect = Seen.Effect
	local Hit    = Bullets.Hits[Seen.Index]

	if Effect and Effect.ACFInfMapEnd then return "range", Effect.ACFInfMapEnd end

	if Hit and Hit.Time >= Seen.Born - 0.001 then return "hit", string.format("a hit message of type %s arrived %.2f s after the bullet was created", tostring(Hit.Type), Hit.Time - Seen.Born) end

	if Seen.Pos and (math.abs(Seen.Pos.x) > 16380 or math.abs(Seen.Pos.y) > 16380 or Seen.Pos.z < -16380) then
		return "other", "ACF's own 16380 limit (this addon should have stopped that from happening)"
	end

	if CurTime() - Seen.Born >= 44 then return "other", "ACF's 45 s limit" end

	if Effect and Effect.Kill then return "other", "ACF set Kill on it for a reason this addon does not know" end

	return "other", "the entry vanished from ACF.BulletEffect without a visible cause"
end

-- ---------------------------------------------------------------------------------------------------- shot report
local ReportWindow, ReportLimit = 10, 8 -- at most this many lines in any window of this many seconds

Bullets.Printed = Bullets.Printed or {} -- times of the last printed lines
Bullets.Pending = Bullets.Pending or 0  -- shots not printed since the last line

local function TracerText(F)
	local Value = F.Value

	if F.Forced then
		return string.format("tracer FORCED by acf_infmap_cl_force_tracer (the crate's Tracer box is %s)", (Value and Value > 0) and "ON" or "OFF")
	end

	if Value == nil then return "crate Tracer unknown (no crate)" end

	if Value > 0 then
		return string.format("crate Tracer box ON (%g)%s", Value, F.Emitter and "" or " but ACF made no tracer emitter")
	end

	return "crate Tracer box OFF (0): ACF makes no tracer for this shell"
end

--- One line for one ended shot. `E` is an entry of Bullets.Ended.
function Bullets.ShotLine(E)
	local F = E.Facts or {}
	local M = Compat.MeterToUnit
	local Out = {}

	local function Add(Text) Out[#Out + 1] = Text end

	Add(string.format("shot #%s", tostring(E.Index)))
	Add(TracerText(F))

	if F.Draw == false then Add("the server marked it HIDDEN (no model, no tracer)") end

	Add(E.Speed and string.format("%.0f m/s", E.Speed) or "speed ?")
	Add(string.format("%s from you at the start, closest %s, %s at the end", F.Start and string.format("%.0f m", F.Start / M) or "?",
		E.Closest and string.format("%.0f m", E.Closest / M) or "?", E.LastDist and string.format("%.0f m", E.LastDist / M) or "?"))
	Add(string.format("engine drew it %d frame(s), this addon %d", E.Renders or 0, E.OwnFrames or 0))
	Add(string.format("lived %.2f s", E.Ended - E.Born))
	Add(string.format("ended: %s - %s", E.Kind, tostring(E.Why)))

	return table.concat(Out, " | ")
end

--- Prints the line, within the rate limit. Called for every bullet that ends (test shells are not passed in).
function Bullets.ReportShot(E)
	if not Report:GetBool() then return end

	local Now, Kept = CurTime(), {}

	for _, T in ipairs(Bullets.Printed) do
		if Now - T < ReportWindow and T <= Now then Kept[#Kept + 1] = T end
	end

	Bullets.Printed = Kept

	if #Kept >= ReportLimit then
		Bullets.Pending = Bullets.Pending + 1
		Stats.ShotsNotPrinted = Stats.ShotsNotPrinted + 1

		return
	end

	Kept[#Kept + 1] = Now
	Stats.ShotsReported = Stats.ShotsReported + 1

	local Line = Bullets.ShotLine(E)

	if Bullets.Pending > 0 then
		Line = string.format("(%d more shot(s) not printed: more than %d in %d s; acf_infmap_bulletdebug lists the last 12) ", Bullets.Pending, ReportLimit, ReportWindow) .. Line
		Bullets.Pending = 0
	end

	Compat.Say(Line)
end

--- Compares what was seen last tick with what is there now; records every bullet that is gone.
local function TrackLife()
	local Now = CurTime()
	local Seen, Table = Bullets.Seen, ACF.BulletEffect or {}
	local Eye = EyePos()

	for Index, S in pairs(Seen) do
		local Bullet = Table[Index]

		if not Bullet or Bullet.Effect ~= S.Effect then
			local Kind, Why = EndReason(S)

			Seen[Index] = nil

			if Index < 1000000 then -- test shells (acf_infmap_bullettest) are not interesting
				local Counter = Kind == "range" and "BulletEndRange" or Kind == "hit" and "BulletEndHit" or "BulletEndOther"

				Stats[Counter] = Stats[Counter] + 1

				local Entry = {Index = Index, Born = S.Born, Ended = Now, Kind = Kind, Why = Why, Pos = S.Pos, Far = S.Far, Speed = S.Speed, Renders = S.Renders,
					Facts = S.Facts, Closest = S.Closest, LastDist = S.LastDist, OwnFrames = S.OwnFrames}

				Bullets.Ended[#Bullets.Ended + 1] = Entry

				if #Bullets.Ended > EndedSize then table.remove(Bullets.Ended, 1) end

				Bullets.ReportShot(Entry)
			end
		end
	end

	for Index, Bullet in pairs(Table) do
		local Effect = Bullet.Effect

		if Alive(Effect) then
			local S = Seen[Index]

			if not S or S.Effect ~= Effect then
				S = {Index = Index, Effect = Effect, Born = Effect.ACFInfMapBorn or Now, Facts = Effect.ACFInfMapFacts}
				Seen[Index] = S
			end

			S.Pos       = Bullet.SimPos
			S.Far       = Effect.ACFInfMapFar and true or false
			S.Renders   = Effect.ACFInfMapRenders or 0
			S.OwnFrames = Effect.ACFInfMapOwnFrames or 0

			if isvector(Bullet.SimPos) then
				local Dist = Bullet.SimPos:Distance(Eye)

				S.LastDist = Dist
				S.Closest  = S.Closest and math.min(S.Closest, Dist) or Dist
			end

			S.Speed   = isvector(Bullet.SimFlight) and Bullet.SimFlight:Length() / Compat.MeterToUnit or nil
		end
	end
end

-- ---------------------------------------------------------------------------------------------------- far tracer
--- The tracer sprite ACF would add this tick, added to the replay renderer. Same values as effects/acf_bullet_effect.lua.
local function FarTracer(Effect, Bullet)
	local Replay = Compat.Replay

	if not Replay or not Bullet.Tracer or not IsValid(Bullet.Tracer) or not Bullet.Color then return end

	local Emitter = Effect.ACFInfMapFarEmitter

	if not Emitter then
		Emitter = Replay.NewEmitter(Bullet.SimPos, true)
		Effect.ACFInfMapFarEmitter = Emitter
	end

	local Length = math.max((Bullet.SimPos - Bullet.SimPosLast):Length() * 2, 1)
	local Color  = Bullet.Color
	local Light  = Emitter:Add("sprites/acf_tracer.vmt", Bullet.SimPosLast)

	if not Light then return end

	Light:SetAngles(Bullet.SimFlight:Angle())
	Light:SetVelocity(Bullet.SimFlight:GetNormalized())
	Light:SetColor(Color.r, Color.g, Color.b)
	Light:SetDieTime(0.075)
	Light:SetStartAlpha(255)
	Light:SetEndAlpha(0)
	Light:SetStartSize(Bullet.Caliber * 15)
	Light:SetEndSize(Bullet.Caliber * 15)
	Light:SetStartLength(Length)
	Light:SetEndLength(Length)
end

-- ---------------------------------------------------------------------------------------------------- movement
local function EnterFar(Effect, Bullet)
	Effect.ACFInfMapFar = true

	if not Effect.ACFInfMapCounted then
		Effect.ACFInfMapCounted = true
		Stats.BulletsKeptAlive = Stats.BulletsKeptAlive + 1
	end

	-- The entity stays where ACF last put it, at the edge of the box, so it must not be drawn there
	Effect:SetNoDraw(true)
end

local function LeaveFar(Effect)
	Effect.ACFInfMapFar = false

	Effect:SetNoDraw(false)
end

--- Replacement for Effect.ApplyMovement. Inside the window it is ACF's function, called unchanged.
local function MakeMovement(Original)
	return function(self, Bullet)
		if not On:GetBool() or Bullet.AmmoType == "FLR" then return Original(self, Bullet) end -- flares have their own limit (16000)

		local Pos = Bullet.SimPos

		if Compat.InWindow(Pos) then
			if self.ACFInfMapFar then LeaveFar(self) end

			return Original(self, Bullet)
		end

		-- Beyond the cap nobody would be sent the hit anyway (the server sends to its effect range), so the bullet ends here
		local Replay = Compat.Replay
		local Eye    = EyePos()

		if Replay and Pos:Distance(Eye) > Replay.Range() then
			self.ACFInfMapEnd = string.format("it was %.0f m from your eye, beyond the far distance of %.0f m (acf_infmap_cl_replay_distance)", Pos:Distance(Eye) / Compat.MeterToUnit, Replay.Range() / Compat.MeterToUnit)
			self.Kill = true

			return
		end

		if not self.ACFInfMapFar then EnterFar(self, Bullet) end

		if self.DrawEffect then FarTracer(self, Bullet) end
	end
end

--- Makes sure the instance carries the replacement and the Render counter. Called when the effect is created and again every tick.
local function Ensure(Effect)
	if Effect.ApplyMovement ~= Effect.ACFInfMapMove then
		local Wrapped = MakeMovement(Effect.ApplyMovement)

		Effect.ACFInfMapMove = Wrapped
		Effect.ApplyMovement = Wrapped
	end

	if Effect.Render ~= Effect.ACFInfMapRender then
		local Original = Effect.Render
		local Counted  = function(self)
			self.ACFInfMapRenders = (self.ACFInfMapRenders or 0) + 1

			return Original(self)
		end

		Effect.ACFInfMapRender = Counted
		Effect.Render = Counted
	end
end

--- What this shell is made of, read once when ACF creates it (the same moment ACF reads the crate), for the shot report.
local function Facts(Effect, Bullet)
	local Crate = Bullet and Bullet.Crate
	local Value = IsValid(Crate) and Crate.GetNW2Float and Crate:GetNW2Float("Tracer") or nil
	local Pos   = Bullet and Bullet.SimPos

	return {
		Value   = Value,
		Emitter = Bullet ~= nil and Bullet.Tracer ~= nil and IsValid(Bullet.Tracer),
		Draw    = Effect.DrawEffect and true or false,
		Start   = isvector(Pos) and Pos:Distance(EyePos()) or nil,
		Forced  = false,
	}
end

--- acf_infmap_cl_force_tracer: ACF's own tracer code needs Bullet.Tracer (an emitter) and Bullet.Color; the crate's colour is what ACF uses.
local function ForceOne(Effect, Bullet, Made)
	if not ForceTracer:GetBool() or Made.Emitter or not Bullet or (Bullet.Index or 0) >= 1000000 or not IsValid(Bullet.Crate) then return end

	local Emitter = ParticleEmitter(Bullet.SimPos)

	if not Emitter then return end

	Bullet.Tracer = Emitter
	Bullet.Color  = Bullet.Crate.GetColor and Bullet.Crate:GetColor() or Color(255, 160, 0)

	Made.Emitter = true
	Made.Forced  = true

	Stats.TracersForced = Stats.TracersForced + 1
end

hook.Add("ACF_OnCreateBulletEffect", "ACFInfMapCompat_Bullets", function(Effect, Bullet)
	if not Alive(Effect) then return end

	Effect.ACFInfMapBorn    = CurTime()
	Effect.ACFInfMapRenders = 0
	Effect.ACFInfMapFrames  = 0

	Bullet = Bullet or (ACF.BulletEffect and ACF.BulletEffect[Effect.Index])

	local OK, Err = pcall(function()
		Effect.ACFInfMapFacts = Facts(Effect, Bullet)

		ForceOne(Effect, Bullet, Effect.ACFInfMapFacts)
	end)

	if not OK then Compat.WarnOnce("shotfacts", "The shot report could not read a bullet: ", tostring(Err)) end

	Ensure(Effect)
end)

hook.Add("ACF_OnTick", "ACFInfMapCompat_BulletKeep", function()
	if Bullets.Disabled then return end

	local OK, Err = pcall(function()
		for _, Bullet in pairs(ACF.BulletEffect or {}) do
			local Effect = Bullet.Effect

			if Alive(Effect) then Ensure(Effect) end
		end

		TrackLife()
	end)

	if OK then return end

	Bullets.Errors = Bullets.Errors + 1

	if Bullets.Errors == 1 then Compat.Warn("Bullet keep-alive raised an error: ", tostring(Err)) end

	if Bullets.Errors >= 5 then
		Bullets.Disabled = true

		Compat.Warn("Bullet keep-alive raised errors five times and switched itself off. Reload the map to retry.")
	end
end)

-- ---------------------------------------------------------------------------------------------------- own drawing
local Csents = {}

local function Model(Path)
	local Ent = Csents[Path]

	if not IsValid(Ent) then
		Ent = ClientsideModel(Path, RENDERGROUP_OPAQUE)

		if not IsValid(Ent) then return nil end

		Ent:SetNoDraw(true)

		Csents[Path] = Ent
	end

	return Ent
end

--- Draws one bullet's model from ACF's simulation state (position, direction, model, scale).
local function DrawBullet(Effect, Bullet)
	local Path = Effect:GetModel()

	if not Path or Path == "" then return end

	local Ent = Model(Path)

	if not Ent then return end

	Ent:SetModelScale(Effect:GetModelScale() or 1, 0)
	Ent:SetPos(Bullet.SimPos)
	Ent:SetAngles(Bullet.SimFlight:Angle())
	Ent:SetupBones()
	Ent:DrawModel()
end

hook.Add("PostDrawOpaqueRenderables", "ACFInfMapCompat_BulletDraw", function(_, Skybox, Skybox3D)
	if Skybox or Skybox3D or Bullets.Disabled or not On:GetBool() then return end

	local OK, Err = pcall(function()
		for _, Bullet in pairs(ACF.BulletEffect or {}) do
			local Effect = Bullet.Effect

			if Alive(Effect) and not Effect.ACFInfMapFar then
				Effect.ACFInfMapFrames = (Effect.ACFInfMapFrames or 0) + 1

				-- The engine draws opaque entities before this hook, so a drawn bullet has been counted by now
				if (Effect.ACFInfMapRenders or 0) > 0 then
					Effect.ACFInfMapOwn = false
				elseif Effect.ACFInfMapFrames >= FramesBeforeDiagnosis and Effect.DrawEffect and OwnDraw:GetBool() then
					if not Effect.ACFInfMapOwn then
						Effect.ACFInfMapOwn = true
						Stats.BulletNeverDrawn = Stats.BulletNeverDrawn + 1

						Compat.WarnOnce("neverdrawn", "The engine did not draw ACF's bullet model (bullet #", Bullet.Index,
							") although the bullet is inside the placeable area. This addon is drawing the model itself from ACF's simulation. ",
							"If the Render counter is not trustworthy on your install, the model may now be drawn twice in the same place, which looks the same. Run acf_infmap_bulletdebug.")
					end
				end

				if Effect.ACFInfMapOwn and Effect.DrawEffect and Bullet.SimPos and Bullet.SimFlight then
					Effect.ACFInfMapOwnFrames = (Effect.ACFInfMapOwnFrames or 0) + 1

					DrawBullet(Effect, Bullet)
				end
			end
		end
	end)

	if OK then return end

	Bullets.Errors = Bullets.Errors + 1

	if Bullets.Errors == 1 then Compat.Warn("Bullet drawing raised an error: ", tostring(Err)) end

	if Bullets.Errors >= 5 then
		Bullets.Disabled = true

		Compat.Warn("Bullet drawing raised errors five times and switched itself off. Reload the map to retry.")
	end
end)

-- ---------------------------------------------------------------------------------------------------- test
--- A harmless shell made through ACF's real effect (util.Effect("acf_bullet_effect")), 300 units in front of you, flying away.
---   acf_infmap_bullettest [speed in m/s] [tracer] [self] [<n>mm]
--- The nearest ammo crate within 5000 units is used as the shell's crate (so model, size and tracer come from a real crate), else
--- you are the crate. "self" skips the crate search (you are the crate: ACF's default caliber of 10 cm = 100 mm, no tracer). "<n>mm" (for
--- example 100mm) sets the caliber of this one shell, whatever the crate says; ACF's own formulas then size the model and the tracer.
--- "tracer" forces a tracer on this one shell even if the crate has none, which separates "the tracer does not
--- render" from "the crate has no tracer". Default speed 15 m/s (slow enough to see); try 800 for a real shell.
--- Example: acf_infmap_bullettest 100 100mm tracer self    (100 m/s, 100 mm, tracer, no crate involved)
--- It answers "does ACF's own bullet effect draw here at all?" without the server, the network or a gun.
local TestIndex = 1000000 -- real bullet indexes stay below 2000 (ballistics_sv.lua, IndexLimit)

local function CrateFacts(Crate)
	if not IsValid(Crate) or not Crate.GetNW2Float then return "no crate" end

	local Tracer = Crate:GetNW2Float("Tracer")

	return string.format("Tracer=%g (%s), Caliber=%g cm, ammo=%s, flight model=%s", Tracer, Tracer > 0 and "ON" or "OFF", Crate:GetNW2Float("Caliber", 10), tostring(Crate:GetNW2String("AmmoType", "AP")), tostring(Crate:GetNW2String("FlightModel", "")) == "" and "(default)" or Crate:GetNW2String("FlightModel", ""))
end

Compat.CrateFacts = CrateFacts

concommand.Add("acf_infmap_bullettest", function(_, _, Args)
	local Speed, Force, SelfOnly, Cal = 15, false, false, nil

	for _, Word in ipairs(Args or {}) do
		local Lower = string.lower(Word)
		local Mm    = string.match(Lower, "^(%d+%.?%d*)mm$")

		if Lower == "tracer" then Force = true
		elseif Lower == "self" then SelfOnly = true
		elseif Mm then Cal = math.Clamp(tonumber(Mm), 1, 1000)
		elseif tonumber(Word) then Speed = math.Clamp(tonumber(Word), 1, 4000) end
	end

	local Eye   = EyePos()
	local Aim   = EyeAngles():Forward()
	local Pos   = Eye + Aim * 300
	local Crate = LocalPlayer()
	local Mine  = "yourself"
	local Best  = 5000 * 5000

	for _, Ent in ipairs(SelfOnly and {} or ents.FindByClass("acf_ammo")) do
		if IsValid(Ent) then
			local D = Ent:GetPos():DistToSqr(Eye)

			if D < Best then
				Best  = D
				Crate = Ent
				Mine  = "the nearest ammo crate"
			end
		end
	end

	TestIndex = TestIndex + 1

	local Data = EffectData()

	Data:SetDamageType(TestIndex)
	Data:SetStart(Aim * (Speed * Compat.MeterToUnit * 0.1)) -- ACF multiplies it by 10 (in units per second)
	Data:SetAttachment(1)
	Data:SetOrigin(Pos)
	Data:SetScale(0)
	Data:SetEntity(Crate)

	util.Effect("acf_bullet_effect", Data, true, true)

	local Entry   = ACF.BulletEffect and ACF.BulletEffect[TestIndex]
	local Created = Entry ~= nil
	local Natural = Created and Entry.Tracer ~= nil and IsValid(Entry.Tracer)

	Compat.Say(string.format("test shell, %g m/s, 300 units ahead of you. Crate = %s: %s.", Speed, Mine, CrateFacts(Crate)))
	Compat.Say("Init ran inside util.Effect: ", Created and "yes" or "NO", ". ACF gave the shell a tracer by itself: ", Natural and "yes" or "no", ".")

	if not Created then
		Compat.Warn("ACF's bullet effect did not register the shell. That means its Init gave up before building the bullet. Run acf_infmap_status and send me the output.")

		return
	end

	-- Size: ACF reads the caliber (in cm) from the crate and scales the model by Caliber * 0.1; its tracer sprite is Caliber * 15 wide.
	-- A crate that reports no caliber (you, with "self") gives ACF's default of 10 cm = 100 mm = model scale 1.
	local CrateCal = Entry.Caliber or 10

	if Cal and math.abs(Cal - CrateCal * 10) > 1e-6 then
		Entry.Caliber = Cal * 0.1

		if Alive(Entry.Effect) then Entry.Effect:SetModelScale(Entry.Caliber * 0.1, 0) end

		Compat.Say(string.format("test shell caliber: %g mm (OVERRIDDEN by you; the crate said %g mm). Model scale %g and tracer sprite width %g are ACF's own formulas applied to that.", Cal, CrateCal * 10, Entry.Caliber * 0.1, Entry.Caliber * 15))
	else
		Compat.Say(string.format("test shell caliber: %g mm (%s). Model scale %g and tracer sprite width %g, from ACF's own formulas.", CrateCal * 10, Mine == "yourself" and "no crate used, so ACF's default for a crate that reports none" or "read from the crate", CrateCal * 0.1, CrateCal * 15))
	end

	if Force and not Natural then
		local Own = Crate.GetColor and Crate:GetColor() or nil

		Entry.Tracer = ParticleEmitter(Pos)
		Entry.Color  = Own or Color(255, 160, 0)

		Compat.Say("tracer FORCED on for this shell (ACF's own tracer code, ACF's own sprite). If you see a tracer now, tracers render fine here and the crate's Tracer tick box is what is off.")
	end

	timer.Simple(1, function()
		local Now = ACF.BulletEffect and ACF.BulletEffect[TestIndex]

		if not Now or not Alive(Now.Effect) then
			Compat.Warn("test shell: already gone after 1 s (killed or removed).")

			return
		end

		local Effect = Now.Effect

		Compat.Say(string.format("test shell after 1 s: engine called Render %d time(s), %d frame(s) seen, this addon draws it itself: %s, far: %s",
			Effect.ACFInfMapRenders or 0, Effect.ACFInfMapFrames or 0, Effect.ACFInfMapOwn and "yes" or "no", Effect.ACFInfMapFar and "yes" or "no"))
	end)

	timer.Simple(4, function()
		local Now = ACF.BulletEffect and ACF.BulletEffect[TestIndex]

		if Now and Alive(Now.Effect) then Now.Effect.Kill = true end
	end)
end)

Compat.Register("cl_bullets", function()
	Compat.Status["bullet effects (keep-alive, far tracer)"] = "active"
end)

Compat.StatusLines.cl_bullets = function()
	local Far, Own, Drawn, Total = 0, 0, 0, 0

	for _, Bullet in pairs(ACF.BulletEffect or {}) do
		local Effect = Bullet.Effect

		if Alive(Effect) then
			Total = Total + 1

			if Effect.ACFInfMapFar then Far = Far + 1 end
			if Effect.ACFInfMapOwn then Own = Own + 1 end
			if (Effect.ACFInfMapRenders or 0) > 0 then Drawn = Drawn + 1 end
		end
	end

	return {
		string.format("bullets: keep-alive %s, %d simulated now (%d beyond the window, %d drawn by the engine, %d drawn by this addon)", (On:GetBool() and not Bullets.Disabled) and "ON" or "OFF", Total, Far, Drawn, Own),
		string.format("bullets: kept alive past the limit %d, model never drawn by the engine %d, new bullets refused by ACF %d", Stats.BulletsKeptAlive, Stats.BulletNeverDrawn, Stats.BulletRefused),
		string.format("bullets: ended by the far distance %d, by a hit message %d, other %d (acf_infmap_bulletdebug lists the last ones with the reason)", Stats.BulletEndRange, Stats.BulletEndHit, Stats.BulletEndOther),
		string.format("bullets: shot report %s (acf_infmap_cl_shot_report): %d line(s) printed, %d not printed (rate limit). Forced tracer %s (acf_infmap_cl_force_tracer): %d shell(s)", Report:GetBool() and "ON" or "OFF", Stats.ShotsReported, Stats.ShotsNotPrinted, ForceTracer:GetBool() and "ON" or "OFF", Stats.TracersForced),
	}
end
