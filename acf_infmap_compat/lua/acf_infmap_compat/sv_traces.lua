-- Bullet traces (server): makes ACF.trace behave under InfMap.
--
-- What goes wrong without this (all SEEN in source unless a label says otherwise):
--   1. A trace only sees entities in the chunk it STARTS in. InfMap localizes the start point, moves the end point into the
--      same frame, and filters out every entity whose CHUNK_OFFSET differs.        (infmap/sv_inf_detours.lua, modify_trace_data)
--      A shot that crosses a chunk border therefore never tests the next chunk's real props or terrain.
--   2. InfMap shows props that overhang a border to the neighbour chunk as `infmap_clone` entities. When a trace hits one,
--      InfMap tries to swap in the real prop with `hit_data.REFERENCE_DATA[1]`. A trace result never has a REFERENCE_DATA
--      field, so the swap never happens and the result still names the clone.     (same function, "if hit_data.REFERENCE_DATA")
--   3. ACF treats an entity that has no owner as "World". A clone has no owner, so a shot that hits a clone is handled as a
--      world impact: the prop takes no damage. (GetImpactType in ballistics_sv.lua uses CPPIGetOwner; GUESS: that a clone
--      really reports no owner. CPPI is added by the prop-protection addon and a clone has none of its parent's fields.)
--   4. The clone of the SHOOTER's own gun, or of anything on the bullet's filter, is not on that filter. A shot fired near
--      a border could hit its own gun's clone.                                       (ACF.GlobalFilter has no infmap_clone)
--
-- What this module does:
--   * While ACF.trace runs, util.TraceLine is replaced with a version that
--       - cuts the line at chunk borders and traces each piece in its own chunk (first hit wins; Fraction is rescaled to
--         the whole line, StartPos is the original start), and
--       - turns a hit on an infmap_clone into a hit on its real parent, unless the parent is on the trace's filter, in which
--         case the clone is ignored and the trace is repeated.
--   * The result is copied into TraceData.output when that table is not the one that came back, because ACF.trace reads it.
--   * util.TraceLine is put back when ACF.trace returns, even when it errors. Nothing else on the server ever sees the
--     replacement.
--
-- What it does NOT touch: ACF files that copy ACF.trace into a local variable when they load (explosion line-of-sight,
-- missile sensors and fuzes, radio and laser guidance, the radar; file list in sh_core.lua). Those keep calling the stock
-- function. See README.
--
-- Evidence labels: SEEN = read in source / run in the mock, KNOWN = standard GMod behaviour not re-checked, GUESS = needs a game.
--   SEEN:  bullets are traced with `ACF.trace(FlightTr)` looked up on the ACF table at call time   (ballistics_sv.lua)
--   SEEN:  ACF.trace calls the global util.TraceLine and reads the table it set in TraceData.output (traces_sh.lua)
--   SEEN:  ACF replaces util.TraceLine with a zero-size TraceHull captured at ACF's load time       (compatibility/trace_workaround.lua)
--   SEEN:  chunk n spans [n*2cs - cs, n*2cs + cs) on every axis, cs = InfMap.chunk_size = 10000   (infmap/sh_inf_functions.lua)
--   SEEN:  server Entity:GetPos() / Player:GetShootPos() are global; clone global position equals its parent's
--          (infmap/sv_inf_detours.lua, entities/infmap_clone.lua)
--   SEEN:  clones carry REFERENCE_DATA.parent on the server and a networked ReferenceParent     (entities/infmap_clone.lua)
--   KNOWN: a trace given an `output` table fills that table and also returns it. If it returns a different table the
--          copy step below covers it, and `OutputCopied` in `acf_infmap_status` counts how often that happened.
--   KNOWN: filter may be nil, an entity, a table of entities, a class-name string or a function(ent) returning true to hit.
--   GUESS: that tracing each chunk piece in its own frame reproduces what the shot should hit. It matches how InfMap
--          itself handles every other trace in the chunk, but nobody has fired across a border in the real game yet.
--   GUESS: that props near a border have usable clones and real chunk-local collision. If InfMap's clones are missing, a prop
--          overhanging a border is still only hit from its own chunk side.
--   KNOWN: a Vector holds 32-bit floats, so far from the origin positions are coarse: about 2 units around x = 2e7
--          (chunk 1000) and about 128 around x = 2e9 (chunk 100000).
--   SEEN (mock with float32 rounding): the next piece starts at the first of 0, 0.05, 0.5, 2, 8, 32, 128, 512 units past the
--          border that InfMap's own chunk formula puts in the next chunk. So the shot skips a sliver no wider than the
--          spacing of positions at that distance. If none of them lands there, that piece is dropped.
--   GUESS: that a hit on the border-crossing piece has a correct HitNormal. The normal comes from the engine unchanged.

local Compat = ACFInfMapCompat
local Stats  = Compat.Stats

local Fix = CreateConVar("acf_infmap_fix_traces", "1", Compat.ServerFlags, "1 = make ACF bullet traces chunk-aware and resolve infmap_clone hits. 0 = stock ACF behaviour.", 0, 1)

local MaxPieces = 12                  -- A line that would cross more borders than this gets its tail traced as one piece
local MaxClones = 4                   -- Retries after hitting clones on one piece
local Nudges    = {0, 0.05, 0.5, 2, 8, 32, 128, 512} -- Units to push a piece's start along the line until it is inside the next chunk
local floor     = math.floor

local Active     = false -- True while our util.TraceLine replacement is installed (also stops nesting)
local Underlying        -- util.TraceLine as it was before the replacement. Set for the duration of one ACF.trace call.
local LoggedSwap, LoggedSplit = false, false

Compat.LastPieces = 0

--------------------------------------------------------------------------------------------------------------------------
-- Filters

--- Whether a trace with this filter could hit Ent. Mirrors the engine's rules.
local function Accepts(Filter, Ent)
	if Filter == nil then return true end

	if isentity(Filter) then return Ent ~= Filter end

	if isstring(Filter) then return Ent:GetClass() ~= Filter end

	if isfunction(Filter) then return Filter(Ent) and true or false end

	if istable(Filter) then
		for _, Value in ipairs(Filter) do
			if Value == Ent then return false end
			if isstring(Value) and Ent:GetClass() == Value then return false end
		end

		return true
	end

	return true
end

local function GetParent(Clone)
	local Data = Clone.REFERENCE_DATA

	if Data and IsValid(Data.parent) then return Data.parent end

	if Clone.GetReferenceParent then
		local Parent = Clone:GetReferenceParent()

		if IsValid(Parent) then return Parent end
	end
end

local function IsClone(Ent)
	return IsValid(Ent) and Ent:GetClass() == "infmap_clone"
end

--- A filter that accepts what Old accepts, except clones whose real prop Old rejects (or whose prop is gone).
local function ParentAwareFilter(Old)
	return function(Ent)
		if Ent:GetClass() == "infmap_clone" then
			local Parent = GetParent(Ent)

			if not Parent or not Accepts(Old, Parent) then return false end
		end

		return Accepts(Old, Ent)
	end
end

--------------------------------------------------------------------------------------------------------------------------
-- Trace pieces

--- Shallow copy of the trace data, with new endpoints and filter. `output` is dropped so each piece gets a fresh result.
local function CopyData(Data, Start, End, Filter)
	local Copy = {}

	for Key, Value in pairs(Data) do Copy[Key] = Value end

	Copy.start, Copy.endpos, Copy.filter, Copy.output = Start, End, Filter, nil

	return Copy
end

--- Hit on a clone -> hit on its parent. Returns the (possibly new) result.
local function Resolve(Data, Filter, Start, End, Result)
	for _ = 1, MaxClones do
		local Hit = Result.Entity

		if not IsClone(Hit) then return Result end

		local Parent = GetParent(Hit)

		if Parent and Accepts(Filter, Parent) then
			Result.Entity = Parent
			Stats.Swapped = Stats.Swapped + 1

			if not LoggedSwap then
				LoggedSwap = true
				Compat.Say("trace: a hit on an infmap_clone was turned into a hit on its ", Parent:GetClass(), " (first time this session)")
			end

			return Result
		end

		-- The real prop is filtered (own gun, an entity the bullet already went through) or gone: ignore this clone
		Stats.Skipped = Stats.Skipped + 1
		Filter        = ParentAwareFilter(Filter)
		Result        = Underlying(CopyData(Data, Start, End, Filter))
	end

	return Result
end

local function Index(Pos, Half, Full)
	return floor((Pos.x + Half) / Full), floor((Pos.y + Half) / Full), floor((Pos.z + Half) / Full)
end

--- Pushes the point at time T along the line forward until it is inside chunk (X, Y, Z). Returns the point and its time.
local function Nudge(Start, Dir, Length, T, NextT, X, Y, Z, Half, Full)
	local Base = Start + Dir * T
	local Unit = Dir * (1 / Length)

	for _, Push in ipairs(Nudges) do
		local Pos = Base + Unit * Push
		local PX, PY, PZ = Index(Pos, Half, Full)

		if PX == X and PY == Y and PZ == Z then
			local Time = T + Push / Length

			if Time < NextT then return Pos, Time end

			return nil
		end
	end
end

--- Cuts Start->End at chunk borders. Returns nil when the line stays in one chunk, otherwise a list of
--- {Start, End, T0, T1} that follow each other without gaps.
local function SplitSegment(Start, End)
	local Half, Full = Compat.ChunkSizes()
	local SX, SY, SZ = Index(Start, Half, Full)
	local EX, EY, EZ = Index(End, Half, Full)

	if SX == EX and SY == EY and SZ == EZ then return nil end

	local Dir    = End - Start
	local Length = Dir:Length()

	if Length <= 0 then return nil end

	-- Time (0..1) at which the line crosses each border it has to cross
	local Times = {}

	for _, Axis in ipairs({{"x", SX, EX}, {"y", SY, EY}, {"z", SZ, EZ}}) do
		local Name, From, To = Axis[1], Axis[2], Axis[3]
		local Step           = Dir[Name]

		if From ~= To and Step ~= 0 then
			local Up = To > From

			for K = 1, math.abs(To - From) do
				-- Chunk i spans [i*Full - Half, i*Full + Half): going up we leave chunk From+K-1 through its top, going down chunk From-K+1 through its bottom
				local Border = Up and ((From + K) * Full - Half) or ((From - K + 1) * Full - Half)
				local Time   = (Border - Start[Name]) / Step

				if Time >= 0 and Time < 1 then Times[#Times + 1] = Time end
			end
		end
	end

	table.sort(Times)

	local Starts   = {{Pos = Start, T = 0}}
	local LastX, LastY, LastZ = SX, SY, SZ

	for I, Time in ipairs(Times) do
		if #Starts >= MaxPieces then break end

		local NextT = Times[I + 1] or 1
		local Mid   = Start + Dir * ((Time + NextT) * 0.5)
		local X, Y, Z = Index(Mid, Half, Full)

		if X ~= LastX or Y ~= LastY or Z ~= LastZ then
			local Pos, T = Nudge(Start, Dir, Length, Time, NextT, X, Y, Z, Half, Full)

			if Pos then
				Starts[#Starts + 1] = {Pos = Pos, T = T}
				LastX, LastY, LastZ = X, Y, Z
			end
		end
	end

	if #Starts < 2 then return nil end

	local Pieces = {}

	for I, From in ipairs(Starts) do
		local To = Starts[I + 1]

		Pieces[I] = {Start = From.Pos, End = To and To.Pos or End, T0 = From.T, T1 = To and To.T or 1}
	end

	return Pieces
end

Compat.SplitSegment = SplitSegment -- Exposed for the test harness and for other addons

--------------------------------------------------------------------------------------------------------------------------
-- The replacement util.TraceLine

--- Makes sure the caller's `output` table holds the result
local function Fill(Data, Result)
	local Out = Data.output

	if istable(Out) and Out ~= Result then
		for Key in pairs(Out) do Out[Key] = nil end
		for Key, Value in pairs(Result) do Out[Key] = Value end

		Stats.OutputCopied = Stats.OutputCopied + 1

		return Out
	end

	return Result
end

local function ScopedTraceLine(Data)
	if not (istable(Data) and isvector(Data.start) and isvector(Data.endpos)) then return Underlying(Data) end

	local Pieces = SplitSegment(Data.start, Data.endpos)

	if not Pieces then
		Compat.LastPieces = 1

		return Fill(Data, Resolve(Data, Data.filter, Data.start, Data.endpos, Underlying(Data)))
	end

	Stats.Split       = Stats.Split + 1
	Compat.LastPieces = #Pieces

	if not LoggedSplit then
		LoggedSplit = true
		Compat.Say("trace: a line crossed a chunk border and was traced in ", #Pieces, " pieces (first time this session)")
	end

	local Result

	for I, Piece in ipairs(Pieces) do
		Result = Resolve(Data, Data.filter, Piece.Start, Piece.End, Underlying(CopyData(Data, Piece.Start, Piece.End, Data.filter)))

		if Result.Hit or I == #Pieces then
			-- Back to a fraction of the whole line. A line that hit nothing ends at T1 of the last piece, which is 1.
			Result.Fraction = Piece.T0 + (Result.Fraction or 1) * (Piece.T1 - Piece.T0)
			Result.StartPos = Data.start

			break
		end
	end

	return Fill(Data, Result)
end

--- Chunk-aware util.TraceLine for other addons (the ACF laser mod, for one). Same behaviour as the replacement ACF.trace
--- gets, without ACF's clip handling.
function Compat.TraceLine(Data)
	if not Fix:GetBool() then return util.TraceLine(Data) end

	if Active then return ScopedTraceLine(Data) end

	Underlying = util.TraceLine

	return ScopedTraceLine(Data)
end

Compat.Register("sv_traces", function()
	Compat.Wrap(ACF, "trace", function(Original)
		Compat.StockTrace = Original

		return function(Data)
			if Active or not Fix:GetBool() or not istable(Data) then return Original(Data) end

			local Previous = util.TraceLine

			Underlying     = Previous
			Active         = true
			util.TraceLine = ScopedTraceLine

			local OK, Result = pcall(Original, Data)

			util.TraceLine = Previous
			Active         = false

			if not OK then error(Result, 0) end

			return Result
		end
	end, "ACF.trace")
end)

--------------------------------------------------------------------------------------------------------------------------
-- Status and debugging

Compat.StatusLines.sv_traces = function()
	return {
		string.format("traces: fix %s, last trace used %d piece(s)", Fix:GetBool() and "ON" or "OFF", Compat.LastPieces or 0),
	}
end

local function Describe(Result)
	if not Result.Hit then return "no hit" end

	local Ent  = Result.Entity
	local Text = "world"

	if IsValid(Ent) then
		Text = string.format("%s [%d] chunk %s", Ent:GetClass(), Ent:EntIndex(), Compat.ChunkText(Ent))

		if IsClone(Ent) then
			local Parent = GetParent(Ent)

			Text = Text .. " (a CLONE of " .. (Parent and Parent:GetClass() or "nothing valid") .. ")"
		end
	elseif Result.HitSky then
		Text = "sky"
	end

	local _, Chunk = InfMap.localize_vector(Result.HitPos)

	return string.format("%s, hit pos %s (chunk %d,%d,%d), fraction %.4f", Text, tostring(Result.HitPos), Chunk.x, Chunk.y, Chunk.z, Result.Fraction or 0)
end

-- `acf_infmap_tracedebug [distance]` in the server console, or as a superadmin: fires a line from your eyes along your aim,
-- once through stock ACF.trace and once through the fixed one, and prints both. Aim it across a chunk border at a prop.
concommand.Add("acf_infmap_tracedebug", function(Ply, _, Args)
	local function Say(...)
		local Text = string.format(...)

		if IsValid(Ply) then Ply:PrintMessage(HUD_PRINTCONSOLE, Text .. "\n") else print(Text) end
	end

	if not IsValid(Ply) then return Say("[ACF-InfMap] tracedebug needs a player to aim from: run it from your own console.") end
	if not Ply:IsSuperAdmin() then return end
	if not Compat.StockTrace then return Say("[ACF-InfMap] ACF.trace is not wrapped (see acf_infmap_status).") end

	local Distance = tonumber(Args[1]) or 30000
	local Start    = Ply:GetShootPos()
	local End      = Start + Ply:GetAimVector() * Distance

	local function Data() return {start = Start, endpos = End, filter = {Ply}, mask = MASK_SOLID} end

	local _, StartChunk = InfMap.localize_vector(Start)
	local Pieces        = SplitSegment(Start, End)

	Say("[ACF-InfMap] trace from %s (chunk %d,%d,%d), %g units along your aim, would be cut into %d piece(s)",
		tostring(Start), StartChunk.x, StartChunk.y, StartChunk.z, Distance, Pieces and #Pieces or 1)

	Say("  stock ACF.trace : %s", Describe(Compat.StockTrace(Data())))

	local Fixed = ACF.trace(Data())

	Say("  fixed ACF.trace : %s (used %d piece(s))", Describe(Fixed), Compat.LastPieces or 0)
end)
