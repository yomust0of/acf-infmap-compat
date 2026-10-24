-- Wire camera controller (server): makes its HitPos and Trace outputs see props and terrain in other chunks.
--
-- What goes wrong without this (SEEN in source unless a label says otherwise):
--   1. The controller computes its outputs in ENT:UpdateOutputs (every 0.1 s while a player is in the camera) with ONE call:
--        util.TraceLine({start = curpos, endpos = curpos + curang:Forward() * 999999999, filter = self.Entities})
--      (wire/lua/entities/gmod_wire_cameracontroller.lua). HitPos, and the Trace output an E2 reads, come from it.
--   2. Under InfMap that call is InfMap's detour (infmap/sv_inf_detours.lua, modify_trace_data): it moves the line into the chunk
--      it STARTS in and filters out every entity whose CHUNK_OFFSET is another chunk's. So the line passes through every prop in
--      the next chunks, and a line that hits nothing ends 999999999 units away. A hologram placed at HitPos "goes through
--      things" and shows nothing or sits somewhere meaningless.
--   3. The line is also a billion units long, so it cannot simply be cut at chunk borders (50000 chunks).
--
-- What this module does:
--   * Wraps ENT:UpdateOutputs of gmod_wire_cameracontroller. While it runs, util.TraceLine is replaced by a function that
--     handles ONE kind of call differently: the call whose filter is the controller's own `self.Entities` table (the call
--     above). That call is cut to WireCamera.MaxDistance (config.lua, metres, default 5000), traced piece by piece through the
--     chunks it crosses (the same piece tracing ACF.trace uses for bullets, see sv_traces.lua) and a hit on an infmap_clone
--     becomes a hit on the real prop. Every other util.TraceLine call, including ones an E2 chip makes while the outputs are
--     triggered, goes to the function that was installed before, untouched.
--   * util.TraceLine is put back when UpdateOutputs returns, even if it errors. Each call puts back exactly what it found, so two
--     controllers updating inside each other (they cannot today) would still unwind in order.
--   * Entities that already exist are patched too (see Patch).
--
-- What changes for scripts (SEEN): HitPos of a line that hits nothing is the END OF THE CUT LINE (default 5000 m away), not
-- 999999999 units away. The Trace output's Fraction refers to the cut line. AutoUnclip's hull trace and the client's camera
-- movement are not touched (they start and end next to the camera).
--
-- Cost: one trace of up to ~3 pieces per chunk of reach, every 0.1 s, only while a player is in the camera.
--
-- Evidence labels: SEEN = read in source / run in the mock, KNOWN = standard GMod behaviour not re-checked, GUESS = needs a game.
--   SEEN:  UpdateOutputs reads `self.Entities` itself (rebuilt every 5 s by GetCameraFilterEntities from Think), so the check
--          compares against the table the entity holds at the moment of the call.
--   SEEN:  gmod_wire_ranger (wire/lua/entities/gmod_wire_ranger.lua) and gmod_wire_user also call util.TraceLine; they are NOT
--          touched here (a ranger is short, its default range is 1500 units).
--   KNOWN: scripted entities are registered with scripted_ents.Register; scripted_ents.GetStored(Class).t is the ENT table.
--   GUESS: that an entity that already exists holds its own COPY of the class's functions (the engine merges the class table
--          into the entity's table when it is created), which is why existing entities are patched as well as the class table.
--   GUESS: what the engine does with a trace whose end is 999999999 units away (stock). The mock shows HitPos = the end.

local Compat = ACFInfMapCompat
local Stats  = Compat.Stats

local Class = "gmod_wire_cameracontroller"

local Defaults = {Enabled = true, MaxDistance = 5000}

Compat.WireCameraDefaults = Defaults

Compat.DefineConfig("WireCamera", Defaults, nil, function(Config)
	if not Config.Enabled then return {"  wire camera controller: OFF (Enabled = false): stock Wire behaviour"} end

	return {string.format("  wire camera controller: HitPos and Trace reach %g m (%d chunks)", Config.MaxDistance, math.ceil(Config.MaxDistance * Compat.MeterToUnit / (InfMap.chunk_size * 2)))}
end)

--- Hands back what the wrapped function returned, after util.TraceLine is back.
local function Finish(Previous, OK, ...)
	util.TraceLine = Previous

	if not OK then error((...), 0) end

	return ...
end

local function Wrap(Original)
	return function(self, ...)
		local Config = Compat.Live.WireCamera

		if not Config.Enabled then return Original(self, ...) end

		local Previous = util.TraceLine
		local Reach    = Config.MaxDistance * Compat.MeterToUnit

		util.TraceLine = function(Data)
			-- only the camera's own aim line: its filter is the table the entity holds
			if istable(Data) and Data.filter ~= nil and Data.filter == self.Entities then
				Stats.WireTraces = Stats.WireTraces + 1

				return Compat.TraceFar(Previous, Data, Reach)
			end

			return Previous(Data)
		end

		return Finish(Previous, pcall(Original, self, ...))
	end
end

--- Entities that exist already hold their own copy of the old function (GUESS, see the header); the new one goes in.
local function Patch(Old, New)
	if Old == New then return 0 end

	local Count = 0

	for _, Ent in ipairs(ents.FindByClass(Class)) do
		local Fields = Ent:GetTable()

		if Fields and rawget(Fields, "UpdateOutputs") == Old then
			Fields.UpdateOutputs = New
			Count = Count + 1
		end
	end

	return Count
end

local Current -- the replacement now in the class table

Compat.Register("sv_wire", function()
	local Stored = scripted_ents and scripted_ents.GetStored(Class)
	local Table  = Stored and Stored.t

	if not Table then
		Compat.Status["Wire camera controller"] = "not installed (no " .. Class .. ")"

		return
	end

	local Old = Table.UpdateOutputs

	if Compat.Wrap(Table, "UpdateOutputs", Wrap, "Wire camera controller") then
		Current = Table.UpdateOutputs

		Patch(Old, Current)
	end
end)

Compat.StatusLines.sv_wire = function()
	local Config = Compat.Live.WireCamera
	local Mine, Total = 0, 0

	for _, Ent in ipairs(ents.FindByClass(Class)) do
		Total = Total + 1

		local Fields = Ent:GetTable()

		if Current and Fields and Fields.UpdateOutputs == Current then Mine = Mine + 1 end
	end

	return {
		string.format("wire camera: fix %s, reach %g m, %d of %d controller(s) use it, %d trace(s) done so far", Config.Enabled and "ON" or "OFF", Config.MaxDistance, Mine, Total, Stats.WireTraces),
	}
end
