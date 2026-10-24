-- ACF3 <-> InfMap compatibility: the numbers you may want to change. SERVER side only (never sent to players).
--
-- Edit a value, save the file, then either restart the server / change the map, or type  acf_infmap_config_reload  in the server
-- console (or as a superadmin in your own console). That re-reads this file and prints what each section now says.
-- If this file has a typing mistake the addon says so in the server console and uses the built-in numbers shown here.

ACFInfMapCompat = ACFInfMapCompat or {}

ACFInfMapCompat.Config = {
	-- How long a bullet may stay in the air before the SERVER removes it. Under InfMap there is no edge of the world, so a shot that
	-- hits nothing flies on through chunk after chunk, is traced every tick the whole time, and keeps one of ACF's 2000 bullet slots.
	--
	-- The time depends on the bullet's caliber (the bullet's own caliber, which for a gun's shell is the gun's caliber):
	--   caliber at or below SmallCaliber   -> SmallSeconds
	--   caliber at or above LargeCaliber   -> LargeSeconds
	--   in between                         -> a straight line between the two (40 mm = 20 s, 55 mm = 85 s, 70 mm = 150 s)
	--
	-- A bullet that has gone past its time is removed without any effect. The picture of it on your screen ends earlier anyway:
	-- ACF's own client code ends every tracer after 45 seconds.
	BulletLifetime = {
		Enabled      = true, -- false = never remove bullets by time (stock ACF behaviour)

		SmallCaliber = 40,   -- millimetres
		SmallSeconds = 20,   -- seconds a small-caliber bullet may fly (machineguns, autocannons)

		LargeCaliber = 70,   -- millimetres, must be bigger than SmallCaliber
		LargeSeconds = 150,  -- seconds a large-caliber bullet may fly (cannons, howitzers, mortars)
	},

	-- Wire camera controller: its HitPos and Trace outputs (what an E2 hologram aim indicator reads).
	-- Under InfMap Wire's own trace only sees props and terrain in the chunk the camera is in, and it is a billion units long.
	-- With this on, that one trace is cut to MaxDistance and traced chunk by chunk, so it hits props and terrain in other chunks.
	-- A line that hits nothing now ends at MaxDistance (stock Wire: a billion units away). 1 chunk = 508 m; values above
	-- about 50 km (100 chunks) count as 50 km.
	WireCamera = {
		Enabled     = true, -- false = stock Wire behaviour
		MaxDistance = 5000, -- metres
	},

	-- Expression 2 rangers: ranger(), rangerOffset(), rangerAngle() and the rangerHull family (what an E2 hologram aim indicator calls).
	-- Same problem and same cure as the camera controller above: under InfMap an E2 ranger only sees props in the chunk it starts in.
	-- With this on, every E2 ranger is cut to MaxDistance and traced chunk by chunk, so it hits props in other chunks.
	-- A ranger that hits nothing now ends at MaxDistance (stock: wherever the E2 pointed it). Chips that were uploaded BEFORE this addon
	-- was installed keep the stock ranger until they are uploaded again. Not covered: rangerOffsetHull(entity, ...), eyeTrace().
	E2Ranger = {
		Enabled     = true, -- false = stock Wire behaviour
		MaxDistance = 5000, -- metres
	},
}
