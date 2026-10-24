-- Stray bullets (server): gives every ACF bullet a maximum lifetime.
--
-- Problem: ACF only removes a bullet that hits something, passes its KillTime, or reaches the sky / the edge of the world.
-- Under InfMap there is no edge of the world (util.IsInWorld is always true) and a shot that hits nothing keeps flying through
-- chunk after chunk. Each such bullet keeps one of ACF's 2000 bullet slots, so enough misses and guns stop firing
-- ("Too many bullets in the air").
--
-- Fix: when a bullet has been in flight longer than `acf_infmap_bullet_lifetime` seconds it is removed with ACF's own
-- RemoveBullet. No effect message is sent: the client's tracer stops by itself after 45 s or when it is more than 16380
-- units from the world origin, whichever comes first.
--
-- Evidence labels: SEEN = read in source / run in the mock, KNOWN = standard GMod behaviour not re-checked, GUESS = needs a game.
--   SEEN:  util.IsInWorld always returns true under InfMap                                      (infmap/sv_inf_detours.lua)
--   SEEN:  bullets are only removed by RemoveBullet, which hit handling, KillTime and the sky checks call  (ballistics_sv.lua)
--   SEEN:  bullet slots are capped at 2000 (IndexLimit) and CreateBullet returns nothing when none is free  (ballistics_sv.lua)
--   SEEN:  CalcBulletFlight is called through the Ballistics table by IterateBullets and CreateBullet       (ballistics_sv.lua)
--   SEEN:  the client tracer ends by itself after 45 s and beyond 16380 units from the origin               (effects/acf_bullet_effect.lua)
--   SEEN:  bullets flagged HandlesOwnIteration are not stepped by IterateBullets, so they are left alone here
--   GUESS: that stray bullets really do pile up in game. This is deduced from the code, not observed. The counter `Killed`
--          in `acf_infmap_status` shows whether the cap ever fires.
--   SEEN:  ACF.Gravity is -sv_gravity (600 u/s^2 by default)                                  (core/globals.lua)
--   KNOWN: without drag, time of flight = 2 * v * sin(angle) / g. A 1000 m/s shell at 45 degrees is in the air about 93 s,
--          a 1500 m/s shell fired almost straight up about 197 s. (Arithmetic, not a measurement.)
--   GUESS: 180 s is a good default: long enough for normal artillery, short enough that a stray bullet frees its slot.
--          Lower it if bullets pile up, raise it if very high lobbed shells vanish. 0 turns the cap off.

local Compat = ACFInfMapCompat
local Stats  = Compat.Stats

local Lifetime = CreateConVar("acf_infmap_bullet_lifetime", "180", Compat.ServerFlags, "Seconds an ACF bullet may stay in flight before it is removed. 0 = never (stock behaviour).", 0)

Compat.Register("sv_bullets", function()
	Compat.Wrap(ACF.Ballistics, "CalcBulletFlight", function(Original)
		return function(Bullet)
			local Max = Lifetime:GetFloat()

			if Max > 0 and not Bullet.HandlesOwnIteration then
				local Now  = ACF.Utilities.Clock.CurTime
				local Born = Bullet.InfMapBorn

				if not Born then
					Bullet.InfMapBorn = Now
				elseif Now - Born > Max then
					Stats.Killed = Stats.Killed + 1

					return ACF.Ballistics.RemoveBullet(Bullet)
				end
			end

			return Original(Bullet)
		end
	end, "Ballistics.CalcBulletFlight")
end)

Compat.StatusLines.sv_bullets = function()
	local Count = 0

	for _ in pairs(ACF.Ballistics.Bullets or {}) do Count = Count + 1 end

	return {
		string.format("bullets: lifetime cap %s, %d in flight now", Lifetime:GetFloat() > 0 and (Lifetime:GetFloat() .. " s") or "OFF", Count),
	}
end
