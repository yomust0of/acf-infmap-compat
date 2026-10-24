-- Expression 2 rangers (server): ranger, rangerAngle, rangerOffset and the hull versions see props in other chunks.
--
-- What goes wrong without this (SEEN in source unless a label says otherwise):
--   An E2 ranger is one util.TraceLine (or util.TraceHull) made for the chip                      (Wire: core/ranger.lua, `ranger`)
--   and under InfMap such a trace only sees entities in the chunk it STARTS in                   (infmap/sv_inf_detours.lua, modify_trace_data)
--   so a ranger from a camera to a prop two chunks away passes through the prop, and a hologram placed at R:pos() ends up at the far
--   end of the line. It is the same fault as the Wire camera controller's (sv_wire.lua), and the same cure is used.
--
-- What this module does:
--   * Every ranger function that E2 registers (ranger, rangerAngle, rangerOffset, rangerHull, rangerAngleHull, rangerOffsetHull, all
--     signatures) is wrapped in wire_expression2_funcs[<signature>][3].
--   * While one of them runs, util.TraceLine and util.TraceHull are replaced by versions that hand the trace to Compat.TraceFar: the
--     line is cut to MaxDistance (config.lua, E2Ranger section), traced chunk by chunk, a hit on an infmap_clone becomes a hit on the
--     real prop. Both are put back when the function returns, also when it errors. Nothing else on the server sees the replacement.
--   * A trace that stays in one chunk costs one extra function call and a few comparisons; the engine is called once, as before.
--   * Not covered: rangerOffsetHull(entity, from, to) (util.TraceEntity), entity:eyeTrace() and eyeTraceCursor() (the engine's own
--     player trace), the Wire ranger entity (gmod_wire_ranger).
--
-- Why the registry and not the function inside ranger.lua:
--   SEEN: the E2 compiler reads `fn[3]` of wire_expression2_funcs[signature] while it compiles a chip and keeps that function
--         (base/compiler.lua, GetFunction: `op = fn[3]`). So the entry must be replaced BEFORE a chip compiles; a chip that
--         compiled earlier keeps the stock function until it is uploaded again. At server start this addon is installed long
--         before any chip exists, and after an E2 reload every chip compiles again.
--   SEEN: `ranger` inside ranger.lua is a file-local function. Changing it would mean debug.setupvalue on a closure, which does not
--         reach traces LuaJIT has already compiled (GUESS). The registry entry is public API and has no such problem.
--   SEEN: E2 runs the hook "Expression2_PostLoadExtensions" after it has loaded (and after every wire_expression2_reload)
--         (core/e2lib.lua), with wire_expression2_funcs filled. The wrapping is done again there, so a reload never loses it.
--
-- Evidence labels: SEEN = read in source / run in the mock, KNOWN = standard GMod behaviour not re-checked, GUESS = needs a game.
--   SEEN:  the three traces of ranger() are util.TraceLine, util.TraceHull and util.TraceEntity, looked up in the global table at call
--          time, and the tracedata table is a new table per call.                                    (core/ranger.lua)
--   SEEN:  a ranger with water and entities makes two traces with different masks (entitiesAndWaterTrace); both go through the
--          replacement.
--   SEEN:  InfMap turns a table filter into an EXCLUSION list and ignores `whitelist` (modify_trace_data). So rangerWhitelist(1) with
--          rangerFilter(...) behaves as a blacklist under InfMap, with or without this addon. This module does not change that.
--   KNOWN: the E2 chip catches errors thrown by its functions (`self:throw`, the ops limit) with pcall; the wrapper below rethrows
--          the same error value.
--   GUESS: that terrain in a chunk with no props is hit. The terrain collider only exists in chunks that hold an entity
--          (infmap/sv_terrain_collision.lua), so a ranger over empty ground in an empty chunk still misses. Props there make it work.

local Compat = ACFInfMapCompat
local Stats  = Compat.Stats

local Label = "E2 rangers"

local Defaults = {Enabled = true, MaxDistance = 5000}

Compat.E2RangerDefaults = Defaults

Compat.DefineConfig("E2Ranger", Defaults, nil, function(Config)
	if not Config.Enabled then return {"  E2 rangers: OFF (Enabled = false): stock Wire behaviour"} end

	return {string.format("  E2 rangers: traces reach %g m (%d chunks)", Config.MaxDistance, math.ceil(Config.MaxDistance * Compat.MeterToUnit / (InfMap.chunk_size * 2)))}
end)

-- The E2 functions that make a trace through ranger(). The names are public E2 API.
local Names = {ranger = true, rangerAngle = true, rangerOffset = true, rangerHull = true, rangerAngleHull = true, rangerOffsetHull = true}

Compat.E2RangerNames = Names -- exposed for the test harness, which compares it with the e2function lines of Wire's ranger.lua

local Wrappers = setmetatable({}, {__mode = "k"}) -- [our wrapper] = the function it wraps
local Active   = false                            -- true while the replacement traces are installed (also stops nesting)
local PrevLine, PrevHull                          -- util.TraceLine and util.TraceHull as they were when the wrapper started

local function Reach() return Compat.Live.E2Ranger.MaxDistance * Compat.MeterToUnit end

local function ReplacementLine(Data)
	Stats.E2Traces = Stats.E2Traces + 1

	return Compat.TraceFar(PrevLine, Data, Reach())
end

local function ReplacementHull(Data)
	Stats.E2Traces = Stats.E2Traces + 1

	return Compat.TraceFar(PrevHull, Data, Reach())
end

--- Puts the traces back, then hands on what the wrapped function returned (or throws what it threw).
local function Finish(Line, Hull, OK, ...)
	util.TraceLine, util.TraceHull = Line, Hull
	Active = false

	if not OK then error((...), 0) end

	return ...
end

local function Wrap(Original)
	return function(...)
		if Active or not Compat.Live.E2Ranger.Enabled then return Original(...) end

		PrevLine, PrevHull = util.TraceLine, util.TraceHull
		Active = true
		util.TraceLine, util.TraceHull = ReplacementLine, ReplacementHull

		return Finish(PrevLine, PrevHull, pcall(Original, ...))
	end
end

--- Calls Do(Signature, Entry) for every registered E2 function that is a ranger function.
local function EachRanger(Do)
	if not istable(wire_expression2_funcs) then return end

	for Signature, Entry in pairs(wire_expression2_funcs) do
		local Name = isstring(Signature) and string.match(Signature, "^([%w_]+)%(")

		if Name and Names[Name] and istable(Entry) and isfunction(Entry[3]) then Do(Signature, Entry) end
	end
end

local function Install()
	if not istable(wire_expression2_funcs) then
		Compat.Status[Label] = "not installed (Expression 2 is not loaded yet)"

		return
	end

	local Count = 0

	EachRanger(function(_, Entry)
		Count = Count + 1

		if not Wrappers[Entry[3]] then
			local Wrapper = Wrap(Entry[3])

			Wrappers[Wrapper] = Entry[3]
			Entry[3]          = Wrapper
		end
	end)

	Compat.Status[Label] = Count > 0 and "wrapped" or "not installed (no ranger functions registered: the ranger extension is off or Wire changed)"
end

Compat.Register("sv_e2ranger", Install)

-- E2 fills wire_expression2_funcs after the autorun files have run, and fills it again on every reload
hook.Add("Expression2_PostLoadExtensions", "ACFInfMapCompat_E2Ranger", function()
	local OK, Err = pcall(Install)

	if not OK then
		Compat.Status[Label] = "error"
		Compat.Warn("Installer sv_e2ranger failed: ", tostring(Err))
	end
end)

Compat.StatusLines.sv_e2ranger = function()
	local Config      = Compat.Live.E2Ranger
	local Mine, Total = 0, 0

	EachRanger(function(_, Entry)
		Total = Total + 1

		if Wrappers[Entry[3]] then Mine = Mine + 1 end
	end)

	return {
		string.format("e2 rangers: fix %s, reach %g m, %d of %d ranger function(s) use it, %d trace(s) done so far", Config.Enabled and "ON" or "OFF", Config.MaxDistance, Mine, Total, Stats.E2Traces),
	}
end
