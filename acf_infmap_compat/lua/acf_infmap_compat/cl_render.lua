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

local Compat = InfmapCompat or ACFInfMapCompat
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

local function ForceRenderVisibility(Ent)
	if not IsValid(Ent) then return end
	
	-- Clear out any forced fade distances that hide complex architecture up close
	if isfunction(Ent.SetNoDraw) and Ent:GetNoDraw() then
		Ent:SetNoDraw(false)
	end

	-- Force RENDERGROUP_BOTH so complex map assets aren't culled by local PVS checks
	if isfunction(Ent.SetRenderGroup) then
		Ent:SetRenderGroup(RENDERGROUP_BOTH)
	end
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
		local Mine = IsValid(Me) and Me.CHUNK_OFFSET
		local MineEnt = Ent.CHUNK_OFFSET

		-- FIX: If we are in the same local chunk, skip forcing wrapper offsets entirely
		if not (IsValid(Me) and MineEnt) or (Mine and MineEnt == Mine) then 
			return Fn(Ent, ...) 
		end

		Ent.ACFInfMapDraws = (Ent.ACFInfMapDraws or 0) + 1

		local Saved = Me.CHUNK_OFFSET
		Me.CHUNK_OFFSET = MineEnt

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
hook.Add("PreDrawTranslucentRenderables", "ACFInfMap