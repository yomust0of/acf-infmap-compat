-- Stray bullets (server): gives every ACF bullet a maximum lifetime that depends on its caliber.
--
-- Problem: ACF only removes a bullet that hits something, passes its KillTime, or reaches the sky / the edge of the world.
-- Under InfMap there is no edge of the world (util.IsInWorld is always true) and a shot that hits nothing keeps flying through
-- chunk after chunk. Every such bullet is traced on every tick for as long as it flies (a trace that crosses a chunk border is
-- traced in pieces) and keeps one of ACF's 2000 bullet slots, so a machinegun fired for a while piles up hundreds of them: the
-- server falls behind and guns stop firing ("Too many bullets in the air").
--
-- Fix: a bullet that has been in flight longer than its allowed time is removed with ACF's own RemoveBullet. The time comes from
-- the bullet's caliber and from lua/acf_infmap_compat/config.lua: SmallSeconds up to SmallCaliber, LargeSeconds from LargeCaliber,
-- a straight line in between. No effect message is sent: the client's tracer stops by itself after 45 s or when it is more than
-- 16380 units from the origin (and beyond the far distance, see cl_bullets.lua).
--
-- Cost: the allowed time is worked out once, the first time ACF steps the bullet; after that each step is one number compared.
--
-- Evidence labels: SEEN = read in source / run in the mock, KNOWN = standard GMod behaviour not re-checked, GUESS = needs a game.
--   SEEN:  util.IsInWorld always returns true under InfMap                                      (infmap/sv_inf_detours.lua)
--   SEEN:  bullets are only removed by RemoveBullet, which hit handling, KillTime and the sky checks call  (ballistics_sv.lua)
--   SEEN:  bullet slots are capped at 2000 (IndexLimit) and CreateBullet returns nothing when none is free  (ballistics_sv.lua)
--   SEEN:  CalcBulletFlight is called through the Ballistics table by IterateBullets and CreateBullet       (ballistics_sv.lua)
--   SEEN:  the client tracer ends by itself after 45 s and beyond 16380 units from the origin               (effects/acf_bullet_effect.lua)
--   SEEN:  bullets flagged HandlesOwnIteration are not stepped by IterateBullets, so they are left alone here
--   SEEN:  a bullet's Caliber is in CENTIMETRES (13.2 mm machinegun = 1.32, 85 mm cannon = 8.5): the ammo crate shows
--          math.Round(BulletData.Caliber * 10, 2) as millimetres (acf_ammo/modules/spawning.lua), and the trace mask test
--          `Bullet.Caliber < 3` (ballistics_sv.lua) means "under 30 mm". Fragments made by spalling carry their small FragSize.
--   KNOWN: without drag, time of flight = 2 * v * sin(angle) / g. A 1000 m/s shell at 45 degrees is in the air about 93 s,
--          a 1500 m/s shell fired almost straight up about 197 s. (Arithmetic, not a measurement.) With ACF's drag these
--          times are shorter; the defaults (150 s for large calibers) were chosen for mortars and howitzers.
--   GUESS: that the picture of a bullet on the client needs nothing from the server when the server removes it (the client
--          simulates it alone from the message it got when it was created).

local Compat = ACFInfMapCompat
local Stats  = Compat.Stats

-- The built-in numbers: used for anything config.lua leaves out or gets wrong
local Defaults = {Enabled = true, SmallCaliber = 40, SmallSeconds = 20, LargeCaliber = 70, LargeSeconds = 150}

Compat.BulletLifetimeDefaults = Defaults

--- What `acf_infmap_config_reload` prints for this section
local function Report(Config)
	if not Config.Enabled then return {"  bullet lifetime: OFF (Enabled = false): bullets are never removed by time"} end

	local Parts = {}

	for _, Mm in ipairs({13.2, 20, 30, 40, 55, 70, 85, 120, 155}) do
		Parts[#Parts + 1] = string.format("%g mm = %g s", Mm, math.Round(Compat.BulletLifeFor(Mm / 10, Config), 1))
	end

	return {
		"  bullet lifetime: " .. table.concat(Parts, ", "),
		"  (bullets already in the air keep the time they were given)",
	}
end

Compat.DefineConfig("BulletLifetime", Defaults, function(Out, Problems)
	if Out.LargeCaliber <= Out.SmallCaliber then
		Problems[#Problems + 1] = "BulletLifetime.LargeCaliber must be bigger than SmallCaliber. The built-in calibers (" .. Defaults.SmallCaliber .. " and " .. Defaults.LargeCaliber .. " mm) are used"
		Out.SmallCaliber, Out.LargeCaliber = Defaults.SmallCaliber, Defaults.LargeCaliber
	end
end, Report)

--- How many seconds a bullet of this caliber may fly.
--- @param CaliberCm number? The bullet's Caliber (centimetres, as ACF holds it)
--- @param Config table? The section to use (default: the numbers now in use)
--- @return number? # seconds; nil when the cap is switched off
function Compat.BulletLifeFor(CaliberCm, Config)
	Config = Config or Compat.Live.BulletLifetime

	if not Config.Enabled then return nil end

	-- A bullet without a caliber is not one of ACF's shells: it gets the long time, so nothing is removed earlier than it should be
	if not isnumber(CaliberCm) then return Config.LargeSeconds end

	local Mm = CaliberCm * 10

	if Mm <= Config.SmallCaliber then return Config.SmallSeconds end
	if Mm >= Config.LargeCaliber then return Config.LargeSeconds end

	local Part = (Mm - Config.SmallCaliber) / (Config.LargeCaliber - Config.SmallCaliber)

	return Config.SmallSeconds + Part * (Config.LargeSeconds - Config.SmallSeconds)
end

Compat.Register("sv_bullets", function()
	Compat.Wrap(ACF.Ballistics, "CalcBulletFlight", function(Original)
		return function(Bullet)
			if not Bullet.HandlesOwnIteration then
				local Die = Bullet.InfMapDie
				local Now = ACF.Utilities.Clock.CurTime

				if not Die then
					-- first step of this bullet: the time it may live is worked out here, once
					local Life = Compat.BulletLifeFor(Bullet.Caliber)

					Bullet.InfMapDie = Life and (Now + Life) or math.huge
				elseif Now > Die then
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

	local Config = Compat.Live.BulletLifetime

	return {
		string.format("bullets: lifetime %s (config.lua), %d in flight now, %d removed by it so far",
			Config.Enabled and string.format("%g s up to %g mm, %g s from %g mm", Config.SmallSeconds, Config.SmallCaliber, Config.LargeSeconds, Config.LargeCaliber) or "cap OFF",
			Count, Stats.Killed),
	}
end
