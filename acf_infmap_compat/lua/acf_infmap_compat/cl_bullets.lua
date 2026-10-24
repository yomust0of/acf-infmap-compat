-- Bullet effects (client): keeps ACF's simulated bullets alive past the engine's placement limit and shows their tracer there.
--
-- ACF simulates every bullet on the client (ACF.BulletEffect[Index], moved each tick by EFFECT:ApplyMovement) and the effect
-- entity is only the thing that draws it. Under InfMap two things go wrong, and this file handles both:
--
--  1. ACF kills the effect when the bullet is more than 16380 units from the frame origin (ApplyMovement, SEEN). Under InfMap the
--     frame origin is the CENTRE of your chunk, so a shell leaves that box after about one chunk. The hit message that arrives
--     later ("Update", Scale > 0) finds no entry and creates nothing: no AP impact, no penetration, no ricochet. That is the
--     "hit effects stop one chunk away" problem. Fix: from the window edge on, ApplyMovement is replaced for that bullet: the
--     simulation keeps running, the engine entity is hidden, and the tracer is added to the replay renderer (cl_replay.lua)
--     instead of an engine emitter. Inside the window ACF's own code runs untouched.
--  2. The engine will not place or draw anything outside that box (see cl_replay.lua), so the tracer beyond it needs the replay
--     renderer anyway. A bullet farther from you than the far distance (acf_infmap_cl_replay_distance) is ended: nothing would be
--     sent to you about it anyway.
--
-- Cost: nothing runs per bullet per frame or per tick. A bullet is touched when it is created, once more on the next tick, and
-- (beyond the window) when ACF moves it.
--
-- Evidence labels: SEEN = read in source / run in the mock, KNOWN = standard GMod behaviour not re-checked, GUESS = needs a game.
--   SEEN:  ApplyMovement kills at |x| or |y| > 16380 or z < -16380, otherwise SetPos + tracer particles; Think keeps the effect for
--          45 s unless Kill is set; the hit message sets Kill itself (effects/acf_bullet_effect.lua).
--   SEEN:  ACF's own missile code replaces Effect.ApplyMovement per instance in the ACF_OnCreateBulletEffect hook
--          (missiles/acfm_effects_cl.lua). This file uses the same hook and the same replacement. The hook order between two
--          addons is not defined, so the replacement is checked again on the next tick.
--   SEEN:  the tracer is one stretched sprite per tick (sprites/acf_tracer.vmt, alpha 255) plus two smoke puffs that start at alpha
--          10 and size 1. Far away only the sprite can be seen, so only it is replayed.
--   SEEN (play-test 6.7): the engine draws the bullet model by itself (every shot line said 20 to 130 frames drawn by the engine and
--          0 by this addon), so the fallback that drew it from ACF's state was removed in 7.0.
--   GUESS: that a stretched particle sprite is drawn from its position back along its direction.

local Compat = ACFInfMapCompat
local Stats  = Compat.Stats

local On = CreateClientConVar("acf_infmap_cl_bullets", "1", true, false, "1 = keep ACF bullets alive past the engine's placement limit and draw their tracers there. 0 = stock behaviour.", 0, 1)

local function Alive(Effect) return Effect ~= nil and IsValid(Effect) end

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
local function EnterFar(Effect)
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

		if Replay and Pos:Distance(EyePos()) > Replay.Range() then
			self.Kill = true

			return
		end

		if not self.ACFInfMapFar then EnterFar(self) end

		if self.DrawEffect then FarTracer(self, Bullet) end
	end
end

--- Makes sure the instance carries the replacement
local function Ensure(Effect)
	if Effect.ApplyMovement ~= Effect.ACFInfMapMove then
		local Wrapped = MakeMovement(Effect.ApplyMovement)

		Effect.ACFInfMapMove = Wrapped
		Effect.ApplyMovement = Wrapped
	end
end

-- Effects created since the last tick. Their ApplyMovement is checked once more, because another addon's hook for the same event
-- (ACF's missiles replace ApplyMovement there) may have run after ours.
local Fresh = {}

hook.Add("ACF_OnCreateBulletEffect", "ACFInfMapCompat_Bullets", function(Effect)
	if not Alive(Effect) then return end

	Ensure(Effect)

	Fresh[#Fresh + 1] = Effect
end)

hook.Add("ACF_OnTick", "ACFInfMapCompat_BulletKeep", function()
	if not Fresh[1] then return end

	for I = #Fresh, 1, -1 do
		local Effect = Fresh[I]

		if Alive(Effect) then Ensure(Effect) end

		Fresh[I] = nil
	end
end)

Compat.Register("cl_bullets", function()
	Compat.Status["bullet effects (keep-alive, far tracer)"] = "active"
end)

Compat.StatusLines.cl_bullets = function()
	local Far, Total = 0, 0

	for _, Bullet in pairs(ACF.BulletEffect or {}) do
		local Effect = Bullet.Effect

		if Alive(Effect) then
			Total = Total + 1

			if Effect.ACFInfMapFar then Far = Far + 1 end
		end
	end

	return {
		string.format("bullets: keep-alive %s, %d simulated now (%d beyond the window), %d kept alive past the limit so far", On:GetBool() and "ON" or "OFF", Total, Far, Stats.BulletsKeptAlive),
	}
end
