-- Client half of the sound fix.
--
-- Problem: on the client, an entity in another chunk keeps its chunk-LOCAL engine origin; InfMap only changes how it is
-- drawn (it moves the camera). So Entity:EmitSound() on such an entity plays from where the entity would be if it were in
-- YOUR chunk, which is the wrong place. InfMap's own sound module covers sounds the SERVER emits, but ACF emits its
-- one-shot sounds on the client, so that never applies to them.
--
-- Fix: for an entity in a different chunk, play the one-shot at the entity's client-side GetPos(), which InfMap already
-- converts into the local player's frame. Everything else goes through ACF unchanged. Looping sounds (engines) are not
-- touched: ACF's CreateSound is already redirected by InfMap to a client prop that follows the entity.
--
-- Evidence labels: SEEN = read in source / run in the mock, KNOWN = standard GMod behaviour not re-checked, GUESS = needs a game.
--   SEEN:  other-chunk entities are not moved: InfMap gives them a RenderOverride that wraps the draw in
--          cam.Start3D(EyePos() - visual_offset)                                         (infmap/cl_inf_chunks.lua)
--   SEEN:  client Entity:GetPos() is relative to the local player's chunk                (infmap/cl_inf_detours.lua)
--   SEEN:  ACF plays entity one-shots with Origin:EmitSound                              (acf/core/utilities/sounds/sounds_cl.lua)
--   SEEN:  InfMap clamps its own sound props to +-100000 units, which this file copies  (infmap/sh_inf_sound.lua)
--   KNOWN: EmitSound on an entity uses the entity's engine origin.
--   GUESS: sound.Play at a position that far from the world origin is audible and correctly placed. InfMap does the same
--          with its props, so it is plausible, but it has not been heard.

local Compat = ACFInfMapCompat
local LIMIT  = 100000

-- The entity's position in the local player's frame, clamped the way InfMap does
local function FramePos(Ent)
	local Pos = Ent:GetPos()

	return Vector(math.Clamp(Pos.x, -LIMIT, LIMIT), math.Clamp(Pos.y, -LIMIT, LIMIT), math.Clamp(Pos.z, -LIMIT, LIMIT))
end

local function InOtherChunk(Ent)
	local Player = LocalPlayer()

	if not IsValid(Player) then return false end

	local EntChunk, PlayerChunk = Ent.CHUNK_OFFSET, Player.CHUNK_OFFSET

	return EntChunk ~= nil and PlayerChunk ~= nil and EntChunk ~= PlayerChunk
end

Compat.Register("cl_sounds", function()
	if Compat.GlueInstalled() then return Compat.SoundsStepAside("cl_sounds") end

	Compat.Wrap(ACF.Utilities.Sounds, "PlaySound", function(Original)
		return function(Origin, Path, Level, Pitch, Volume, UseBASS)
			if isentity(Origin) and IsValid(Origin) and InOtherChunk(Origin) then
				sound.Play(Path, FramePos(Origin), Level, Pitch, ACF.Volume * Volume)

				return
			end

			return Original(Origin, Path, Level, Pitch, Volume, UseBASS)
		end
	end, "Sounds.PlaySound")
end)

-- `acf_infmap_sounddebug_cl` in your console near a running engine
concommand.Add("acf_infmap_sounddebug_cl", function()
	local Player = LocalPlayer()

	print(string.format("[ACF-InfMap] you: chunk %s", Compat.ChunkText(Player)))

	for _, Class in ipairs({"acf_engine", "acf_waterjet", "acf_turret"}) do
		for _, Ent in ipairs(ents.FindByClass(Class)) do
			local Loop = Ent.Sound

			print(string.format("  %s [%d] chunk %s, frame pos %s, %.0f units away, loop %s",
				Class, Ent:EntIndex(), Compat.ChunkText(Ent), tostring(Ent:GetPos()),
				Ent:GetPos():Distance(Player:GetPos()),
				Loop and (Loop:IsPlaying() and "playing" or "created, not playing") or "none"))
		end
	end
end)
