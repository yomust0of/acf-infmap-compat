-- Server half of the sound fix.
--
-- Problem: ACF decides who hears a sound with net.SendPAS(Origin:GetPos()). Under InfMap, GetPos() is a GLOBAL position
-- (chunk offset * 20000 + local), which is not a point in the real map.
--
-- Fix: while ACF's own send functions run, net.SendPAS is swapped for "every player within a range, measured in global
-- space". ACF keeps its message format, its rate limit and its client code. On top of that this module remembers who
-- holds each looping sound, so players who drive into range get the loop created and players who leave get it stopped.
--
-- Evidence labels: SEEN = read in source / run in the mock, KNOWN = standard GMod behaviour not re-checked, GUESS = needs a game.
--   SEEN:  ACF sends with net.SendPAS(Origin:GetPos())                         (acf/core/utilities/sounds/sounds_sv.lua)
--   SEEN:  InfMap makes server Entity:GetPos() global                           (infmap/sv_inf_detours.lua)
--   SEEN:  InfMap's own range check uses GetPos() on players and props         (infmap/sh_inf_sound.lua, CheckDistance)
--   SEEN:  engines, waterjets and turrets use CreateAdjustableSound / SendAdjustableSound   (grep over lua/)
--   SEEN:  stock SendSound also accepts a vector origin. Every call site I grepped passes an entity-named variable.
--   KNOWN: the PAS lookup works in real-map coordinates and is compared against players' own (chunk-local) positions.
--   GUESS: who a SendPAS aimed at a point outside the real map reaches. `acf_infmap_sounddebug` prints stock against
--          range counts, so one look in game settles it. The fix does not depend on the answer.
--   GUESS: that nothing sends SendSound a vector origin. If something does, it is range-filtered correctly here, but the
--          client would play it at the raw global vector.
--   GUESS: 20000 units is a good default range, and a half-second audience check is frequent enough.
--   GUESS: the two messages rebuilt by hand below (create, stop) keep ACF's layout after an ACF update. Not detectable.

local Compat = ACFInfMapCompat

local Fix         = CreateConVar("acf_infmap_fix_sounds", "1", Compat.ServerFlags, "1 = route ACF sounds by global distance under InfMap. 0 = stock ACF behaviour.", 0, 1)
local Range       = CreateConVar("acf_infmap_sound_range", "20000", Compat.ServerFlags, "Players within this many units (global space) of a sound source are sent its ACF sounds.", 0)
local LeaveFactor = 1.1 -- A listener only loses a loop beyond Range * this, so walking along the edge does not flap

-- [Entity] = {Path, Pitch, Volume, Heard = {[Player] = true}}. Lives on the addon table so it survives acf_reload.
Compat.Loops = Compat.Loops or {}

local Loops = Compat.Loops

-- Players within Distance (default: the convar) of Pos. Both sides are global positions.
local function PlayersInRange(Pos, Distance)
	local Limit = (Distance or Range:GetFloat()) ^ 2
	local Found = {}

	for _, Ply in ipairs(player.GetAll()) do
		if Ply:GetPos():DistToSqr(Pos) <= Limit then
			Found[#Found + 1] = Ply
		end
	end

	return Found
end

Compat.PlayersInRange = PlayersInRange -- The effect module reuses it

local function ToSet(List)
	local Set = {}

	for _, Value in ipairs(List) do Set[Value] = true end

	return Set
end

--- Runs Fn with net.SendPAS redirected to a global-space range check, and returns the players it reached.
--- net.SendPAS is always restored, even if Fn errors.
local function WithRangeAudience(Fn, ...)
	local RealSendPAS = net.SendPAS
	local Reached     = {}

	net.SendPAS = function(Pos)
		Reached = PlayersInRange(Pos)

		if Reached[1] then net.Send(Reached) else net.Abort() end
	end

	local OK, Err = pcall(Fn, ...)

	net.SendPAS = RealSendPAS

	if not OK then error(Err, 0) end

	return Reached
end

-- Same names and field order as ACF's own messages (sounds_sv.lua), so ACF's client receivers handle them unchanged.
local function SendCreateTo(Ply, Ent, Loop)
	net.Start("ACF_Sounds_AdjustableCreate")
		net.WriteEntity(Ent)
		net.WriteString(Loop.Path)
		net.WriteUInt(Loop.Pitch, 8)
		net.WriteFloat(Loop.Volume)
	net.Send(Ply)
end

local function SendStopTo(Ply, Ent)
	net.Start("ACF_Sounds_Adjustable") -- Reliable, unlike the stock update messages: a lost stop would leave the loop playing
		net.WriteEntity(Ent)
		net.WriteBool(true)
	net.Send(Ply)
end

local function TrackLoop(Ent)
	local Loop = Loops[Ent]

	if Loop then return Loop end

	Loop = {Heard = {}}
	Loops[Ent] = Loop

	Ent:CallOnRemove("ACFInfMapCompat_Loop", function() Loops[Ent] = nil end)

	return Loop
end

Compat.Register("sv_sounds", function()
	if Compat.GlueInstalled() then return Compat.SoundsStepAside("sv_sounds") end

	local Sounds = ACF.Utilities.Sounds

	Compat.Wrap(Sounds, "CreateAdjustableSound", function(Original)
		return function(Origin, Path, Pitch, Volume)
			if not Fix:GetBool() then return Original(Origin, Path, Pitch, Volume) end
			if not IsValid(Origin) then return end

			local Reached = WithRangeAudience(Original, Origin, Path, Pitch, Volume)
			local Loop    = TrackLoop(Origin)

			Loop.Path, Loop.Pitch, Loop.Volume = Path, Pitch, Volume
			Loop.Heard = ToSet(Reached)
		end
	end, "Sounds.CreateAdjustableSound")

	Compat.Wrap(Sounds, "SendAdjustableSound", function(Original)
		return function(Origin, ShouldStop, Pitch, Volume)
			if not Fix:GetBool() or not IsValid(Origin) then return Original(Origin, ShouldStop, Pitch, Volume) end

			local Loop = Loops[Origin]

			if ShouldStop then
				local Reached = ToSet(WithRangeAudience(Original, Origin, true))

				-- Anyone who still holds the loop but is out of range was not reached above, so stop theirs directly
				if Loop then
					for Ply in pairs(Loop.Heard) do
						if IsValid(Ply) and not Reached[Ply] then SendStopTo(Ply, Origin) end
					end

					Loops[Origin] = nil
				end

				return
			end

			if Loop then Loop.Pitch, Loop.Volume = Pitch, Volume end

			WithRangeAudience(Original, Origin, false, Pitch, Volume)
		end
	end, "Sounds.SendAdjustableSound")

	Compat.Wrap(Sounds, "SendSound", function(Original)
		return function(Origin, ...)
			if not Fix:GetBool() then return Original(Origin, ...) end

			WithRangeAudience(Original, Origin, ...)
		end
	end, "Sounds.SendSound")
end)

-- Keeps the audience of each loop current. Created once; timer.Create with the same id just replaces it.
timer.Create("ACFInfMapCompat_Audience", 0.5, 0, function()
	if not Fix:GetBool() then return end

	local Enter = Range:GetFloat()
	local Leave = Enter * LeaveFactor

	for Ent, Loop in pairs(Loops) do
		if not IsValid(Ent) then
			Loops[Ent] = nil
		elseif Loop.Path then
			local Pos = Ent:GetPos()

			for _, Ply in ipairs(player.GetAll()) do
				local Distance = Ply:GetPos():Distance(Pos)

				if not Loop.Heard[Ply] and Distance <= Enter then
					SendCreateTo(Ply, Ent, Loop)

					Loop.Heard[Ply] = true
				elseif Loop.Heard[Ply] and Distance > Leave then
					SendStopTo(Ply, Ent)

					Loop.Heard[Ply] = nil
				end
			end

			for Ply in pairs(Loop.Heard) do
				if not IsValid(Ply) then Loop.Heard[Ply] = nil end
			end
		end
	end
end)

-- `acf_infmap_sounddebug` in the server console (or as a superadmin) beside a running engine, ideally in a chunk other than
-- 0,0,0. "stock PAS" is who stock ACF would have sent to; "range" is who this addon sends to.
concommand.Add("acf_infmap_sounddebug", function(Ply)
	if IsValid(Ply) and not Ply:IsSuperAdmin() then return end

	local function Say(...)
		local Text = string.format(...)

		Compat.Tell(Ply, Text)
	end

	Say("[ACF-InfMap] sounds: fix %s, range = %g units, %d tracked loops", Fix:GetBool() and "ON" or "OFF", Range:GetFloat(), table.Count(Loops))

	for _, Player in ipairs(player.GetAll()) do
		Say("  player %s chunk %s global pos %s", Player:Nick(), Compat.ChunkText(Player), tostring(Player:GetPos()))
	end

	for _, Class in ipairs({"acf_engine", "acf_waterjet", "acf_turret"}) do
		for _, Ent in ipairs(ents.FindByClass(Class)) do
			local Pos    = Ent:GetPos()
			local Filter = RecipientFilter()
			local Loop   = Loops[Ent]
			local Heard  = 0

			Filter:AddPAS(Pos)

			if Loop then
				for Player in pairs(Loop.Heard) do if IsValid(Player) then Heard = Heard + 1 end end
			end

			Say("  %s [%d] chunk %s global pos %s: stock PAS reaches %d, range reaches %d, holding loop %d",
				Class, Ent:EntIndex(), Compat.ChunkText(Ent), tostring(Pos),
				#Filter:GetPlayers(), #PlayersInRange(Pos), Heard)
		end
	end
end)
