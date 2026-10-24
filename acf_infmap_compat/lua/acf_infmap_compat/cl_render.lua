-- Render fixes (client): Visual Clip props and Prop2Mesh meshes that sit in another chunk than you.
--
-- WHAT YOU SEE: a dupe pasted far from you (another chunk) is missing parts: visual-clipped props, and the meshes of Prop2Mesh
-- entities, show up in the wrong place or not at all, while a player standing next to the dupe sees them fine. Walking up to the
-- dupe does not fix it.
--
-- WHY (root causes, each one read in the real source; what the ENGINE does with them is GUESS where marked):
--
--  1. InfMap draws an entity that lives in another chunk by wrapping its RenderOverride: the wrapper moves the camera by the
--     chunk difference (cam.Start3D(EyePos() - offset)) and then draws the model, so the model's raw engine position lands where
--     it should look. InfMap installs that wrapper ONCE, from the NW2 "CHUNK_OFFSET" change and from your own chunk change
--     (cl_inf_chunks.lua, InfMap.prop_update_chunk), and it remembers the entity's earlier override in OldRenderOverride.
--     Visual Clip (clipping.lua: AddPropClip, clipping_remove_*) and Prop2Mesh (cl_init.lua: refresh) assign
--     `ent.RenderOverride = ...` on their own schedule. Whoever writes second wins: the camera shift is gone, the entity is drawn
--     at its raw chunk-local position seen from your chunk, i.e. in the wrong place. And InfMap's remembered "old" override is
--     now stale, so the next chunk update restores or re-wraps the wrong thing and the clip is lost.
--  2. Even when the order is the lucky one (clip first, InfMap's wrapper second), the clip planes are computed with
--     Entity:LocalToWorld, which InfMap detours to return a position in YOUR chunk's frame, while the model is drawn through the
--     shifted camera, i.e. in the ENTITY's chunk frame. The clip plane lands one chunk-offset away from the model. Same story
--     for Prop2Mesh's clipped meshes (Ent_GetPos is the detoured GetPos).
--  3. Prop2Mesh's meshes are CLIENT-SIDE child entities (ents.CreateClientside("base_anim")), created whenever the mesh data
--     is ready. InfMap only gives clientside children a CHUNK_OFFSET and a wrapper for children that exist at the moment their
--     parent's chunk is updated (the GetChildren loop). A child created later has neither: it is drawn unshifted.
--  4. THE POSITION BUG, the "mesh gets put way far away" one: refresh() computes the child's position as
--     LocalToWorld(linkpos, linkang, Ent_GetPos(parent), ...) and applies it with Ent_SetPos on a PARENTED child. Ent_GetPos is
--     captured when Prop2Mesh loads, and by then it is InfMap's detour: it returns the parent's position in YOUR chunk's frame
--     (raw position + chunk difference * 20000). Ent_SetPos is InfMap's clamping SetPos (+-16384). The engine turns a world
--     position set on a parented entity into a parent-local one using the parent's REAL (raw) transform, so the local offset
--     comes out as "linkpos + chunk difference" (clamped), and the mesh sits miles from its parent. It is right only when the
--     parent is in your own chunk. Nothing in Prop2Mesh refreshes it again, so it stays wrong. That is exactly "the guy next to
--     the dupe sees it, I do not": he is in the dupe's chunk, you are not.
--  5. Complex Prop2Mesh meshes (more than one IMesh) are drawn by the child's own `Draw` function, not by DrawModel. InfMap's
--     wrapper calls self:DrawModel(), so for a child InfMap wrapped the big part of the mesh is never drawn.
--  6. Visual Clip messages (clipping_new_clip) name the entity with net.WriteEntity. A client that does not have the entity yet
--     reads NULL and drops the clip. The server only re-sends at join (InitPostEntity + 5 s). Props that reach you later (the
--     dupe was pasted outside your PVS, or you were in another chunk) never get their clips: they show unclipped.
--
-- WHAT THIS FILE DOES (it never reloads a model or a mesh; the loops below are a few table reads per entity):
--   a. Wraps InfMap.prop_update_chunk. Before InfMap runs: if somebody replaced InfMap's wrapper, their function is moved back into
--      InfMap's "old override" slot (root cause 1). After InfMap ran: that old override is wrapped so that, while it runs, the
--      local player's CHUNK_OFFSET is the ENTITY's, which makes every detoured position function answer in the entity's frame, the
--      frame the shifted camera draws in (root cause 2). The value is put back afterwards, also when the override errors.
--   b. A PreRender guard looks at every entity InfMap has wrapped: if its RenderOverride is no longer the function InfMap installed,
--      the entity goes through (a) again within the same frame, before anything is drawn (root cause 1, the Visual Clip order).
--   c. Prop2Mesh children are found through the entities' prop2mesh_controllers (the same table Prop2Mesh itself uses):
--      - their parent-local position is put back to linkpos, which is what refresh() meant (root cause 4);
--      - they get the parent's CHUNK_OFFSET and InfMap's wrapper if they lack it (root cause 3);
--      - a wrapped child that has no override of its own gets one that calls the child's Draw, and InfMap is run on it again so
--        that it builds its wrapper around it (InfMap chooses the wrapper's variant when it builds it, so changing the old override
--        is not enough). Complex meshes are drawn again (root cause 5). This runs every frame, so it does not matter in which
--        order InfMap, Prop2Mesh and this file got to the child; the guard in (b) runs first, so a Prop2Mesh refresh (which clears
--        the child's override) is put right in the same frame.
--   d. Clientside children of other chunked entities get the same adoption (a slower scan), and are added to InfMap.all_ents if
--      ents.GetAll() does not list them, because InfMap only shrinks the render bounds of entities in that list.
--   e. Visual Clip resync: the first time a prop with a CHUNK_OFFSET is within `acf_infmap_cl_visclip_range` chunks of you, this
--      client asks the server (sv_visclip.lua) for that prop's clips if it has not received any. One small request per prop,
--      ever; the server answers with Visual Clip's own "send all clips of this entity" message.
--
-- Evidence labels: SEEN = read in source / run in the mock, KNOWN = standard GMod behaviour not re-checked, GUESS = needs a game.
--   SEEN:  InfMap.prop_update_chunk is looked up through the InfMap table by every caller (the EntityNetworkedVarChanged hook, the
--          InitPostEntity hook, its own recursion), so replacing the table field intercepts all of them (sh_inf_networking.lua,
--          cl_inf_chunks.lua).
--   SEEN:  the wrapper calls self:OldRenderOverride() / self:DrawModel() and cam.Start3D(EyePos() - visual_offset) (cl_inf_chunks.lua).
--   SEEN:  Visual Clip and Prop2Mesh assign RenderOverride directly (clipping.lua, sent_prop2mesh/cl_init.lua).
--   SEEN:  Prop2Mesh captures entMeta.GetPos / SetPos at load, after InfMap's detours exist (autorun runs before entities load).
--          KNOWN: autorun files load before scripted entity files.
--   SEEN:  Prop2Mesh's own `info.linkpos` / `info.linkang` / `info.ent` / `info.linkent` fields; parent = linkent or the entity.
--   KNOWN: C_BaseEntity::SetAbsOrigin on a parented entity converts the world position to parent-local with the parent's real
--          transform (Source SDK). Entity:SetLocalPos / GetLocalPos exist on the client.
--   GUESS: that these two statements together are what puts the mesh far away in game (the arithmetic is in the harness, using the
--          real InfMap and Prop2Mesh files with an engine model that follows the SDK rule above). Only `acf_infmap_renderdebug`
--          in game can confirm it: it prints each mesh's local position next to what refresh() meant.
--   GUESS: that PreRender runs before RenderScene in the same frame. If it is the other way round a repaired entity is culled for one
--          frame, nothing worse.
--   GUESS: that clip planes given to render.PushCustomClipPlane live in the same world space as the camera set by cam.Start3D.
--   GUESS: that ents.GetAll() includes clientside entities. Step d does not depend on it: it adds them to InfMap.all_ents itself.
--   GUESS: that the Workshop versions of InfMap, Visual Clip and Prop2Mesh equal the sources read here.
--
-- Not covered: Visual Clip's clip planes are drawn through the entity's chunk only while the entity is wrapped by InfMap (up to
-- InfMap's own 10-chunk level of detail; farther away InfMap draws a plain box). Prop2Mesh meshes with clips draw only the first mesh
-- part (stock Prop2Mesh behaviour, also in a normal map). If Prop2Mesh's LinkEntRemoved moved a mesh to its parent's origin, this
-- file puts it back at linkpos, which is what the next refresh would do anyway.

local Compat = ACFInfMapCompat
local Stats  = Compat.Stats

local On     = CreateClientConVar("acf_infmap_cl_render_fix", "1", true, false, "1 = keep visual clips and Prop2Mesh meshes right in other chunks. 0 = stock behaviour.", 0, 1)
local Resync = CreateClientConVar("acf_infmap_cl_visclip_resync", "1", true, false, "1 = ask the server for the visual clips of props that came into range without any.", 0, 1)
local Range  = CreateClientConVar("acf_infmap_cl_visclip_range", "12", true, false, "Chunks. A prop this close to you is checked once for missing visual clips.", 1, 100)
local Bounds = CreateClientConVar("acf_infmap_cl_render_bounds", "1", true, false, "1 = a render box that a script sets in world coordinates (SetRenderBoundsWS) is converted into the entity's own chunk frame before it is stored. 0 = stock.", 0, 1)
local Scripted = CreateClientConVar("acf_infmap_cl_render_draw", "1", true, false, "1 = in other chunks, run a scripted entity's own Draw / DrawTranslucent (beams, glows, overlays) as well as its model. 0 = stock InfMap (model only).", 0, 1)

local Render = Compat.Render or {}

Compat.Render = Render

Render.Errors  = Render.Errors or 0
Render.Unwrap  = Render.Unwrap or setmetatable({}, {__mode = "k"}) -- [our wrapper function] = the override it wraps
Render.List    = Render.List or {}                                    -- entities InfMap has wrapped (array)
Render.P2M     = Render.P2M or {}                                     -- sent_prop2mesh entities (array), refreshed twice a second
Render.Pending = Render.Pending or {}                                 -- entity indices to ask the server about
Render.Asked   = Render.Asked or 0
Render.Translucent = false -- true between PreDrawTranslucentRenderables and PostDrawTranslucentRenderables

local Unwrap  = Render.Unwrap
local List    = Render.List
local Pending = Render.Pending

local MaxPerMessage = 255 -- entity indices per request (8 bits for the count)
local MaxPending    = 8192

-- Counters this file adds to the shared list (sh_core.lua declares them too; this keeps the file usable on its own)
for _, Name in ipairs({"RenderRescued", "RenderThrottled", "RenderErrors", "RenderContextErrors", "ChildrenAdopted", "MeshRepositioned", "DrawRouted", "ClipRequests", "BoundsConverted"}) do
	Stats[Name] = Stats[Name] or 0
end

local function Fail(Where, Err)
	Render.Errors = Render.Errors + 1
	Stats.RenderErrors = Stats.RenderErrors + 1

	if Render.Errors == 1 then Compat.Warn("Render fix raised an error in ", Where, ": ", tostring(Err)) end

	if Render.Errors >= 5 then
		Render.Disabled = true

		Compat.Warn("Render fix raised errors five times and switched itself off. Reload the map to retry.")
	end
end

-- ---------------------------------------------------------------------------------------------------- chunk context
--- Wraps an override so that, while it runs, the local player's CHUNK_OFFSET is the entity's. InfMap's detours of GetPos,
--- LocalToWorld, WorldSpaceCenter, WorldSpaceAABB and GetBonePosition then return the entity's own (raw) frame, which is the frame
--- the shifted camera draws in. The previous value is restored in every case.
local function Contextualize(Fn)
	if Unwrap[Fn] then return Fn end

	local Run

	Run = function(Ent, ...)
		local Me   = LocalPlayer()
		local Mine = Ent.CHUNK_OFFSET

		Ent.ACFInfMapDraws = (Ent.ACFInfMapDraws or 0) + 1

		if not (IsValid(Me) and Mine) then return Fn(Ent, ...) end

		local Saved = Me.CHUNK_OFFSET

		Me.CHUNK_OFFSET = Mine

		local OK, Err = pcall(Fn, Ent, ...)

		Me.CHUNK_OFFSET = Saved

		if not OK then
			Stats.RenderContextErrors = Stats.RenderContextErrors + 1

			-- Not re-thrown: InfMap's wrapper would then skip its cam.End3D() and leave the camera stack broken. Reported once.
			if Stats.RenderContextErrors == 1 then Compat.Warn("An entity's RenderOverride raised an error while it was drawn in another chunk: ", tostring(Err)) end
		end
	end

	Unwrap[Run] = Fn

	return Run
end

-- Which pass the engine is in. Two independent signals, and either one is enough:
--   * the hooks below (KNOWN: the engine runs the opaque renderables, then PreDrawTranslucentRenderables, the translucent ones,
--     PostDrawTranslucentRenderables);
--   * the flags the engine hands to RenderOverride: STUDIO_DRAWTRANSLUCENTSUBMODELS (4; the GMod wiki words it "current render is
--     for translucent renderables only"). GUESS: whether the engine sets it for every translucent-pass draw or only for two-pass
--     models, which is why a flags value that says "opaque" never overrules the hooks. STUDIO_TRANSPARENCY (0x80000000) is NOT read:
--     in the Source SDK's studio.h it marks a non-sorting brush model, not a pass.
hook.Add("PreDrawOpaqueRenderables", "ACFInfMapCompat_Pass", function() Render.Translucent = false end)
hook.Add("PreDrawTranslucentRenderables", "ACFInfMapCompat_Pass", function() Render.Translucent = true end)
hook.Add("PostDrawTranslucentRenderables", "ACFInfMapCompat_Pass", function() Render.Translucent = false end)

local function FlagBit(Flags, Index)
	-- Lua numbers are doubles here: a flag word can arrive signed or unsigned, so it is brought into 0..2^32-1 first
	return math.floor((Flags % 4294967296) / 2 ^ Index) % 2 == 1
end

local function InTranslucentPass(Flags)
	if Render.Translucent then return true end

	return isnumber(Flags) and FlagBit(Flags, 2)
end

-- Draws an entity the way the engine would without a RenderOverride: the opaque pass calls its Draw, the translucent pass its
-- DrawTranslucent (which is Draw unless the entity defines its own). Prop2Mesh's complex meshes live in Draw; a beam or a glow
-- (a laser) lives in DrawTranslucent. InfMap's wrapper calls DrawModel only, so neither ever ran in another chunk.
local function DrawThroughDraw(Self, Flags)
	local Fn = InTranslucentPass(Flags) and Self.DrawTranslucent

	if isfunction(Fn) then
		Self.ACFInfMapTranslucentDraws = (Self.ACFInfMapTranslucentDraws or 0) + 1

		return Fn(Self, Flags)
	end

	return Self:Draw(Flags)
end

local DrawCtx = Contextualize(DrawThroughDraw)

Render.DrawCtx = DrawCtx

-- ---------------------------------------------------------------------------------------------------- InfMap.prop_update_chunk
--- Is this entity drawn by its own Draw function (so that InfMap's DrawModel-only wrapper hides part of it)?
local function Routable(Ent)
	if not isfunction(Ent.Draw) then return false end

	-- Prop2Mesh meshes are flagged by the sweep below; they are scripted entities too, but this must not depend on the switch
	if Ent.ACFInfMapMesh then return true end

	return Scripted:GetBool() and isfunction(Ent.IsScripted) and Ent:IsScripted() == true
end

--- Called before InfMap's function: moves a replaced override back where InfMap looks for it, and gives a scripted entity its Draw route.
local function Before(Ent)
	if Ent.ValidRenderOverride ~= nil then
		local Installed = Ent.ACFInfMapInstalled
		local Current   = Ent.RenderOverride

		if Installed == nil then
			-- first time this file sees the entity: assume the current function is InfMap's own
			Ent.ACFInfMapInstalled = Current
		elseif Current ~= Installed then
			Ent.OldRenderOverride   = Current
			Ent.ValidRenderOverride = Current ~= nil

			Stats.RenderRescued = Stats.RenderRescued + 1
		end
	end

	-- An entity that is drawn by its own Draw / DrawTranslucent and has no RenderOverride of its own gets ours, so that InfMap's
	-- wrapper (which calls Old, or DrawModel when there is none) runs them. If InfMap does not wrap it after all (your own
	-- chunk), After takes it off again.
	if Routable(Ent) then
		if Ent.ValidRenderOverride == nil then
			if Ent.RenderOverride == nil then Ent.RenderOverride = DrawCtx end
		elseif Ent.OldRenderOverride == nil then
			Ent.OldRenderOverride   = DrawCtx
			Ent.ValidRenderOverride = true
		end
	end
end

--- Called after InfMap's function.
local function After(Ent)
	if Ent.ValidRenderOverride == nil then
		-- InfMap does not wrap the entity (same chunk as you, or filtered). When it just stopped wrapping it, it put the entity's
		-- old override back as its RenderOverride: that must be the entity's own function again, not one of ours.
		local Fn = Ent.RenderOverride

		if Fn ~= nil then
			if Fn == DrawCtx then
				Ent.RenderOverride = nil
			elseif Unwrap[Fn] then
				Ent.RenderOverride = Unwrap[Fn]
			end
		end

		Ent.ACFInfMapInstalled = nil
		Ent.ACFInfMapRouted    = nil

		return
	end

	Ent.ACFInfMapInstalled = Ent.RenderOverride

	local Old = Ent.OldRenderOverride

	if Old == DrawCtx and not Ent.ACFInfMapRouted then
		Ent.ACFInfMapRouted = true
		Stats.DrawRouted    = Stats.DrawRouted + 1
	end

	-- InfMap's wrapper reads this field every time it draws, so changing it now is enough
	if Old ~= nil and not Unwrap[Old] then Ent.OldRenderOverride = Contextualize(Old) end

	if not Ent.ACFInfMapListed then
		Ent.ACFInfMapListed = true
		List[#List + 1] = Ent
	end
end

local function WrapChunkUpdate(Original)
	return function(Ent, Chunk, ...)
		if Render.Disabled or not On:GetBool() or not IsValid(Ent) then return Original(Ent, Chunk, ...) end

		local OK, Err = pcall(Before, Ent)

		if not OK then Fail("the step before InfMap.prop_update_chunk", Err) end

		-- Not protected on purpose: an error inside InfMap stays an InfMap error, as in stock
		local Result = Original(Ent, Chunk, ...)

		OK, Err = pcall(After, Ent)

		if not OK then Fail("the step after InfMap.prop_update_chunk", Err) end

		return Result
	end
end

-- ---------------------------------------------------------------------------------------------------- per-frame work
local function Throttled(Ent)
	local Now   = SysTime()
	local Start = Ent.ACFInfMapRescueT

	if not Start or Now - Start > 1 then
		Ent.ACFInfMapRescueT = Now
		Ent.ACFInfMapRescueN = 0
	end

	Ent.ACFInfMapRescueN = Ent.ACFInfMapRescueN + 1

	if Ent.ACFInfMapRescueN > 20 then
		Stats.RenderThrottled = Stats.RenderThrottled + 1

		return true
	end

	return false
end

--- Re-runs InfMap for every wrapped entity whose RenderOverride was replaced since.
local function Guard()
	local I = 1

	while I <= #List do
		local Ent = List[I]

		if not IsValid(Ent) or Ent.ValidRenderOverride == nil or not Ent.CHUNK_OFFSET then
			if IsValid(Ent) then Ent.ACFInfMapListed = nil end

			List[I] = List[#List]
			List[#List] = nil
		else
			-- Replaced since InfMap installed it, or wrapped without a Draw route that the entity would use (the addon was
			-- loaded after InfMap wrapped it, or the switch was turned on since)
			local Replaced = Ent.RenderOverride ~= Ent.ACFInfMapInstalled
			local Unrouted = Ent.ValidRenderOverride == false and Ent.OldRenderOverride == nil and Routable(Ent)

			if (Replaced or Unrouted) and not Throttled(Ent) then
				InfMap.prop_update_chunk(Ent, Ent.CHUNK_OFFSET)
			end

			I = I + 1
		end
	end
end

--- InfMap only shrinks the render bounds of the entities in InfMap.all_ents, a table it replaces every half second with
--- ents.GetAll(). Entities InfMap wrapped that ents.GetAll() does not return would be dropped from it.
local function TopUp()
	local All = InfMap.all_ents

	if All == Render.LastAll or not istable(All) then return end

	Render.LastAll = All

	local Has = {}

	for _, Ent in ipairs(All) do Has[Ent] = true end

	for _, Ent in ipairs(List) do
		if not Has[Ent] and IsValid(Ent) and Ent.RenderOverride then All[#All + 1] = Ent end
	end
end

local function Adopt(Child, Chunk)
	if not Chunk or Child.CHUNK_OFFSET == Chunk then return end

	InfMap.prop_update_chunk(Child, Chunk)

	Stats.ChildrenAdopted = Stats.ChildrenAdopted + 1
end

--- Prop2Mesh: one mesh child. `Info` is the controller table Prop2Mesh keeps for it.
local function SweepMesh(Info, Child)
	local Parent = Child:GetParent()

	if not IsValid(Parent) then return end

	-- What refresh() meant: the child sits at linkpos in its parent's frame. The engine frame is the parent's own, so this does not
	-- depend on which chunk the PLAYER is in.
	local Want = Info.linkpos or vector_origin

	Child.ACFInfMapMesh = true

	if Child:GetLocalPos():DistToSqr(Want) > 0.25 then
		Child:SetLocalPos(Want)

		Stats.MeshRepositioned = Stats.MeshRepositioned + 1
	end

	local Chunk = Parent.CHUNK_OFFSET

	if not Chunk then return end

	-- A child made after its parent's chunk update has no chunk and no wrapper
	if Child.CHUNK_OFFSET ~= Chunk then
		InfMap.prop_update_chunk(Child, Chunk)

		Stats.ChildrenAdopted = Stats.ChildrenAdopted + 1
	end

	-- A child InfMap wrapped without an override of its own is drawn with DrawModel only. Prop2Mesh draws complex meshes in the
	-- child's Draw function. Running InfMap on it again gives it the Draw route (Before) and makes InfMap build its wrapper around
	-- that: the wrapper's variant is chosen when InfMap builds it, so changing the old override alone would not be enough.
	if Child.ValidRenderOverride ~= nil and Child.OldRenderOverride == nil then
		InfMap.prop_update_chunk(Child, Chunk)
	end
end

local function SweepMeshes()
	for _, Ent in ipairs(Render.P2M) do
		if IsValid(Ent) then
			local Controllers = Ent.prop2mesh_controllers

			if istable(Controllers) then
				for _, Info in pairs(Controllers) do
					local Child = Info.ent

					if IsValid(Child) then SweepMesh(Info, Child) end
				end
			end
		end
	end
end

-- ---------------------------------------------------------------------------------------------------- render bounds
-- A script that sets its render box in WORLD coordinates (Entity:SetRenderBoundsWS) with positions it got from GetPos, LocalToWorld,
-- WorldSpaceCenter... gets them in YOUR chunk's frame, because InfMap detours those getters (cl_inf_detours.lua). The engine stores the
-- box as entity-local bounds, subtracting the entity's REAL position, which is in ITS chunk's frame. In another chunk the stored
-- local box is therefore off by the chunk difference (20000 units per chunk). InfMap's own code reads that box back
-- (cl_inf_chunks.lua: `ent.RENDER_BOUNDS = {ent:GetRenderBounds()}`, once, when it first shrinks the entity's bounds) and expects
-- entity-local extents, because it scales them by sub_size / distance and places them in front of your eye. With the chunk
-- difference still inside, the shrunk box ends up about twice as far out as InfMap meant, which for a player standing near the
-- edge of his chunk is outside the +-16384 box that InfMap says the engine does not render.
-- InfMap detours SetRenderBounds (local coordinates) for this reason; SetRenderBoundsWS is the one it left out.
--   SEEN:  the acf_lazer of github.com/yomust0of/Acf_LaZers calls SetRenderBoundsWS every Think while it fires, with
--          self:GetMuzzlePos() (= self:LocalToWorld(...)), so it is exactly this case (cl_init.lua, UpdateBeamBounds).
--   SEEN:  InfMap calls SetRenderBoundsWS itself every frame, with positions around the EYE (also this frame). Those calls must not
--          be touched, so this file wraps InfMap's RenderScene hook and ignores every call made while it runs.
--   SEEN:  sub_size = (source_bounds - chunk_size) / 2 = 3192: the margin InfMap leaves between a chunk's edge and the world box.
--   GUESS: that the engine really culls an entity whose box is outside the world box (InfMap's comment says it does).
--   GUESS: that GetRenderBounds on the client returns what SetRenderBoundsWS stored, converted with the entity's raw position.
-- The conversion is switched on only when InfMap's hook was found and wrapped (Render.BoundsReady), so a different InfMap version
-- leaves the engine function alone.
local EntityMT = FindMetaTable("Entity")

local BoundsHook = "!infinite_update_visbounds"
local InInfMap   = false

local function MakeBoundsDetour(Original)
	return function(Self, Min, Max, ...)
		if InInfMap or Render.Disabled or not Render.BoundsReady or not Bounds:GetBool() or not On:GetBool() then return Original(Self, Min, Max, ...) end

		local Chunk = Self.CHUNK_OFFSET
		local Me    = LocalPlayer()
		local Mine  = IsValid(Me) and Me.CHUNK_OFFSET

		if not Chunk or not Mine or Chunk == Mine or not isvector(Min) or not isvector(Max) then return Original(Self, Min, Max, ...) end

		if InfMap.filter_entities and InfMap.filter_entities(Self) then return Original(Self, Min, Max, ...) end

		local Shift = InfMap.unlocalize_vector(vector_origin, Chunk - Mine)

		Stats.BoundsConverted = Stats.BoundsConverted + 1

		return Original(Self, Min - Shift, Max - Shift, ...)
	end
end

--- Wraps InfMap's RenderScene hook so that the detour above can tell InfMap's own calls from everybody else's.
local function WrapBoundsHook()
	local Set = hook.GetTable and hook.GetTable().RenderScene
	local Fn  = Set and Set[BoundsHook]

	if not isfunction(Fn) then
		Render.BoundsReady = false

		return false
	end

	if Fn ~= Render.BoundsWrapper then
		local Wrapper = function(...)
			InInfMap = true

			local OK, A, B = pcall(Fn, ...)

			InInfMap = false

			-- Not swallowed: an error in InfMap stays an InfMap error
			if not OK then error(A, 0) end

			return A, B
		end

		Render.BoundsWrapper = Wrapper

		hook.Add("RenderScene", BoundsHook, Wrapper)
	end

	Set = hook.GetTable().RenderScene
	Render.BoundsReady = Set ~= nil and Set[BoundsHook] == Render.BoundsWrapper

	return Render.BoundsReady
end

-- Separate protected calls: one failing step must not stop the others
-- The guard comes first: a Prop2Mesh refresh clears its child's override, the guard puts InfMap's wrapper back, and the sweep then
-- routes that wrapper through Draw, all before anything is drawn. (Since the guard also routes wrapped entities that lack the route,
-- swapping the two steps reaches the same state in the same frame: the test run with them swapped passes. The order is kept because
-- it is the one that was reasoned through.)
local Steps = {
	{"the override guard", Guard},
	{"the Prop2Mesh sweep", SweepMeshes},
	{"the render-bounds list", TopUp},
}

local function Frame()
	if Render.Disabled or not On:GetBool() then return end

	local LP = LocalPlayer()

	if not IsValid(LP) or not LP.CHUNK_OFFSET or not InfMap.prop_update_chunk then return end

	for _, Step in ipairs(Steps) do
		local OK, Err = pcall(Step[2])

		if not OK then Fail(Step[1], Err) end
	end
end

hook.Add("PreRender", "ACFInfMapCompat_Render", Frame)

-- ---------------------------------------------------------------------------------------------------- slower work
local function CanAsk()
	return util.NetworkStringToID("ACFInfMapCompat_ClipRequest") ~= 0 and util.NetworkStringToID("clipping_all_prop_clips") ~= 0
end

local function Wanted(Ent)
	if Ent:EntIndex() <= 0 or Ent:IsPlayer() or Ent:IsWeapon() then return false end

	return not InfMap.filter_entities(Ent)
end

--- Clientside children of chunked entities that InfMap never saw (not only Prop2Mesh's), and the visual clip resync.
local function Scan()
	local LP   = LocalPlayer()
	local Mine = IsValid(LP) and LP.CHUNK_OFFSET

	if not Mine then return end

	local Ask   = Resync:GetBool() and CanAsk()
	local Limit = Range:GetFloat() ^ 2

	for _, Ent in ipairs(ents.GetAll()) do
		local Chunk = Ent.CHUNK_OFFSET

		if Chunk then
			-- Wrapped by InfMap before this file was loaded (so the guard does not know it): take it over, once
			if Ent.ValidRenderOverride ~= nil and not Ent.ACFInfMapListed then InfMap.prop_update_chunk(Ent, Chunk) end

			if Ask and not Ent.ACFInfMapClipAsked and (Chunk - Mine):LengthSqr() <= Limit and Wanted(Ent) then
				Ent.ACFInfMapClipAsked = true

				-- A prop that already holds clips (Visual Clip sets MaxClips) needs nothing; asking would only duplicate them
				if Ent.MaxClips == nil and #Pending < MaxPending then Pending[#Pending + 1] = Ent:EntIndex() end
			end
		elseif Ent:EntIndex() == -1 then
			local Parent = Ent:GetParent()

			if IsValid(Parent) and Parent.CHUNK_OFFSET and not Parent:IsPlayer() and not Parent:IsWeapon() then Adopt(Ent, Parent.CHUNK_OFFSET) end
		end
	end
end

local function Flush()
	if #Pending == 0 or not CanAsk() then return end

	local Count = math.min(#Pending, MaxPerMessage)

	net.Start("ACFInfMapCompat_ClipRequest")
		net.WriteUInt(Count, 8)

		for I = 1, Count do net.WriteUInt(Pending[I], 14) end
	net.SendToServer()

	for I = 1, Count do table.remove(Pending, 1) end

	Render.Asked = Render.Asked + Count
	Stats.ClipRequests = Stats.ClipRequests + Count
end

-- A Prop2Mesh entity is known the moment it is created, so its first mesh is repaired before it is ever drawn. The half-second
-- scan below is the catch-all (it also drops entities that are gone).
--   GUESS: that GetClass() already answers inside OnEntityCreated on the client. If it does not, a new entity waits for the scan.
hook.Add("OnEntityCreated", "ACFInfMapCompat_Render", function(Ent)
	if IsValid(Ent) and Ent:GetClass() == "sent_prop2mesh" then Render.P2M[#Render.P2M + 1] = Ent end
end)

timer.Create("ACFInfMapCompat_RenderSlow", 0.5, 0, function()
	if Render.Disabled or not On:GetBool() then return end

	local OK, Err = pcall(function()
		Render.P2M = ents.FindByClass("sent_prop2mesh")

		Render.InstallBounds() -- InfMap may have registered its hook after us, or again (a Lua refresh)
		Scan()
		Flush()
	end)

	if not OK then Fail("the slow render scan", Err) end
end)

-- ---------------------------------------------------------------------------------------------------- install
--- The render box correction: InfMap's hook first (the detour only acts once the hook is wrapped), then the detour. Idempotent, so the
--- half-second scan calls it too: when InfMap's hook shows up after this file ran, the correction starts then.
function Render.InstallBounds()
	if WrapBoundsHook() then
		Compat.Wrap(EntityMT, "SetRenderBoundsWS", MakeBoundsDetour, "render bounds (Entity:SetRenderBoundsWS)")
	else
		Compat.Status["render bounds (Entity:SetRenderBoundsWS)"] = "InfMap's RenderScene hook not found: left alone"
	end
end

local function Install()
	if not (InfMap and isfunction(InfMap.prop_update_chunk)) then
		Compat.Status["render guard (InfMap.prop_update_chunk)"] = "missing"

		return
	end

	Compat.Wrap(InfMap, "prop_update_chunk", WrapChunkUpdate, "render guard (InfMap.prop_update_chunk)")

	Render.InstallBounds()
end

Render.Install = Install

-- This module does not need ACF, so it installs itself instead of waiting for Compat.Install
Install()

hook.Add("Initialize", "ACFInfMapCompat_Render", Install)
hook.Add("InitPostEntity", "ACFInfMapCompat_Render", Install)

Compat.Register("cl_render", Install)

-- ---------------------------------------------------------------------------------------------------- diagnostics
local function Kind(Ent, Fn)
	if Fn == nil then return "none" end
	if Fn == DrawCtx then return "this file's Draw route (the entity's own Draw / DrawTranslucent)" end
	if Fn == Ent.ACFInfMapInstalled then return "InfMap wrapper" end
	if Unwrap[Fn] then return "foreign override, run in the entity's chunk" end

	return "foreign override (not wrapped)"
end

local function Chunks(Ent, Mine)
	local Chunk = Ent.CHUNK_OFFSET

	if not Chunk then return "no CHUNK_OFFSET" end
	if not Mine then return "?" end

	local D = Chunk - Mine

	return string.format("%d,%d,%d chunks away", D.x, D.y, D.z)
end

--- Lines for `acf_infmap_renderdebug`. Exposed for the harness.
function Render.DebugLines()
	local Lines = {}
	local LP    = LocalPlayer()
	local Mine  = IsValid(LP) and LP.CHUNK_OFFSET or nil

	Lines[#Lines + 1] = string.format("fix %s, visclip resync %s (range %g chunks, server side %s), disabled by errors: %s",
		On:GetBool() and "ON" or "OFF", Resync:GetBool() and "ON" or "OFF", Range:GetFloat(), CanAsk() and "present" or "ABSENT", Render.Disabled and "YES" or "no")
	Lines[#Lines + 1] = string.format("you are in chunk %s", Mine and Compat.ChunkText(LP) or "?")
	Lines[#Lines + 1] = string.format("entities InfMap wrapped and this file watches: %d", #List)

	-- The wrapped entities nearest to you whose override is not plain InfMap
	local Shown = 0

	for _, Ent in ipairs(List) do
		if IsValid(Ent) and Ent.OldRenderOverride ~= nil and Ent.OldRenderOverride ~= DrawCtx and Shown < 8 then
			Shown = Shown + 1

			Lines[#Lines + 1] = string.format("  wrapped %s %s [%s]: own override = %s, wrapper intact = %s, draws by the engine = %d",
				Ent:GetClass(), tostring(Ent:EntIndex()), Chunks(Ent, Mine), Kind(Ent, Ent.OldRenderOverride), tostring(Ent.RenderOverride == Ent.ACFInfMapInstalled), Ent.ACFInfMapDraws or 0)
		end
	end

	-- Prop2Mesh
	local Meshes, Wrong, Unwrapped, Total = 0, 0, 0, #Render.P2M

	for _, Ent in ipairs(Render.P2M) do
		if IsValid(Ent) and istable(Ent.prop2mesh_controllers) then
			for _, Info in pairs(Ent.prop2mesh_controllers) do
				local Child = Info.ent

				if IsValid(Child) then
					Meshes = Meshes + 1

					local Parent = Child:GetParent()
					local Off    = IsValid(Parent) and Child:GetLocalPos():Distance(Info.linkpos or vector_origin) or -1

					if Off > 0.5 or Off < 0 then Wrong = Wrong + 1 end
					if Child.ValidRenderOverride == nil and Parent and IsValid(Parent) and Mine and Parent.CHUNK_OFFSET ~= Mine then Unwrapped = Unwrapped + 1 end

					if Meshes <= 6 then
						Lines[#Lines + 1] = string.format("  mesh of p2m %s [%s]: parent %s, local offset from linkpos %.1f units, chunk %s, override = %s, draws = %d",
							tostring(Ent:EntIndex()), Chunks(Ent, Mine), IsValid(Parent) and Parent:GetClass() or "NONE", Off, Child.CHUNK_OFFSET and Compat.ChunkText(Child) or "none",
							Kind(Child, Child.ValidRenderOverride ~= nil and Child.OldRenderOverride or Child.RenderOverride), Child.ACFInfMapDraws or 0)
					end
				end
			end
		end
	end

	Lines[#Lines + 1] = string.format("prop2mesh entities %d, mesh children %d (%d at the wrong position right now, %d in another chunk but not wrapped)", Total, Meshes, Wrong, Unwrapped)
	Lines[#Lines + 1] = string.format("visclip: asked about %d prop(s), %d waiting to be sent", Render.Asked, #Pending)

	return Lines
end

concommand.Add("acf_infmap_renderdebug", function()
	for _, Line in ipairs(Render.DebugLines()) do print("[ACF-InfMap] " .. Line) end
end)

--- Lines for `acf_infmap_entdebug <part of a class name>`: what this addon and InfMap are doing to the entities of that class (at most
--- 10, nearest chunk first). Exposed for the harness.
function Render.EntityLines(Pattern)
	local Lines   = {}
	local LP      = LocalPlayer()
	local Mine    = IsValid(LP) and LP.CHUNK_OFFSET
	local Found   = {}
	local Pattern = string.lower(Pattern or "")

	if Pattern == "" then
		Lines[1] = "give part of a class name, for example: acf_infmap_entdebug lazer"

		return Lines
	end

	for _, Ent in ipairs(ents.GetAll()) do
		if IsValid(Ent) and Ent:EntIndex() > 0 and string.find(string.lower(Ent:GetClass()), Pattern, 1, true) then
			Found[#Found + 1] = {Ent = Ent, Far = (Mine and Ent.CHUNK_OFFSET) and (Ent.CHUNK_OFFSET - Mine):LengthSqr() or math.huge}
		end
	end

	table.sort(Found, function(A, B) return A.Far < B.Far end)

	Lines[1] = string.format("%d entit%s with '%s' in the class name%s. You are in chunk %s. Render fix %s, Draw route switch %s.", #Found, #Found == 1 and "y" or "ies", Pattern,
		#Found > 10 and " (the nearest 10 are listed)" or "", Mine and Compat.ChunkText(LP) or "?", (On:GetBool() and not Render.Disabled) and "ON" or "OFF", Scripted:GetBool() and "ON" or "OFF")

	for I = 1, math.min(#Found, 10) do
		local Ent     = Found[I].Ent
		local Wrapped = Ent.ValidRenderOverride ~= nil
		local Group   = isfunction(Ent.GetRenderGroup) and Ent:GetRenderGroup() or "?"

		Lines[#Lines + 1] = string.format("%s #%d [%s]: scripted %s, Draw %s, DrawTranslucent %s, render group %s, hidden %s",
			Ent:GetClass(), Ent:EntIndex(), Chunks(Ent, Mine), tostring(isfunction(Ent.IsScripted) and Ent:IsScripted()), isfunction(Ent.Draw) and "yes" or "NO",
			isfunction(Ent.DrawTranslucent) and "yes" or "no", tostring(Group), tostring(isfunction(Ent.GetNoDraw) and Ent:GetNoDraw()))

		local Cached = Ent.RENDER_BOUNDS
		local Size   = Cached and (Cached[2] - Cached[1]) * 0.5
		local Centre = Cached and (Cached[2] + Cached[1]) * 0.5

		Lines[#Lines + 1] = string.format("    InfMap's stored local render box: %s. A box centred more than a few thousand units from the entity's own origin was stored in the wrong frame.",
			Cached and string.format("half-size %.0f x %.0f x %.0f, centre %.0f %.0f %.0f from the origin", Size.x, Size.y, Size.z, Centre.x, Centre.y, Centre.z) or "none (not stored: your own chunk, or not wrapped yet)")
		Lines[#Lines + 1] = string.format("    InfMap wrapper: %s. Its own override: %s. Draw route: %s. Called by the engine %d time(s), %d of them through DrawTranslucent.",
			Wrapped and (Ent.RenderOverride == Ent.ACFInfMapInstalled and "yes, intact" or "yes, REPLACED since") or "no (your own chunk, or not wrapped)",
			Kind(Ent, Wrapped and Ent.OldRenderOverride or Ent.RenderOverride), (Wrapped and Ent.OldRenderOverride == DrawCtx) and "yes" or "no",
			Ent.ACFInfMapDraws or 0, Ent.ACFInfMapTranslucentDraws or 0)

		-- cl_origin.lua: is the position the engine keeps for the entity the one the server networked? (a whole chunk of difference
		-- draws the entity that far from where it is)
		if Compat.Origin and isfunction(Compat.Origin.Describe) then
			local OK, Text = pcall(Compat.Origin.Describe, Ent)

			Lines[#Lines + 1] = "    " .. (OK and Text or ("engine position check failed: " .. tostring(Text)))
		end
	end

	return Lines
end

concommand.Add("acf_infmap_entdebug", function(_, _, Args)
	for _, Line in ipairs(Render.EntityLines(Args and Args[1])) do print("[ACF-InfMap] " .. Line) end
end)

Compat.StatusLines.cl_render = function()
	return {
		string.format("render: guard %s, %d entities watched, overrides put back %d, meshes repositioned %d, children adopted %d, drawn through Draw %d, render boxes converted %d (%s), errors %d (acf_infmap_renderdebug and acf_infmap_entdebug list them)",
			(On:GetBool() and not Render.Disabled) and "ON" or "OFF", #List, Stats.RenderRescued, Stats.MeshRepositioned, Stats.ChildrenAdopted, Stats.DrawRouted, Stats.BoundsConverted, Render.BoundsReady and "ready" or "NOT ACTIVE: InfMap's RenderScene hook not found", Stats.RenderErrors),
		string.format("visclip: resync %s, %d request(s) sent, server side %s", Resync:GetBool() and "ON" or "OFF", Stats.ClipRequests, CanAsk() and "present" or "ABSENT"),
	}
end
