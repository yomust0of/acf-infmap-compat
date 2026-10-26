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

local Hold = CreateClientConVar("acf_infmap_cl_render_hold", "", true, false, "Diagnostics. Parts of this file NOT to install, read when they are installed (use retry after changing it): passhooks scenehook boundswrap chunkwrap frame created timer, or all. Empty = install everything.")

local PassMode = CreateClientConVar("acf_infmap_cl_render_passmode", "gamemode", true, false, "Diagnostics. How this file learns which draw pass the engine is in. gamemode = wrap the gamemode's PreDraw/PostDraw functions (adds no hook). hooks = add three hooks (version 7.4 and earlier; on gm_infmap_kirovskoe they made the terrain invisible). Read when installed: retry after changing it.")

local Render = Compat.Render or {}

Compat.Render = Render

-- ---------------------------------------------------------------------------------------------------- hold-back switch
-- WHY THIS EXISTS: on one map (gm_infmap_kirovskoe, whose own Lua builds its terrain and buildings) the terrain and buildings near
-- you disappear while this file is loaded, and are fine when it is not. The switches above (`acf_infmap_cl_render_fix`, `_draw`,
-- `_bounds`) only turn the WORK off; the hooks and wrappers stay installed, and "which of those installed parts does it" cannot be
-- told from reading. This setting leaves a part out of the game altogether, so a bisect is possible without editing the file:
--
--     acf_infmap_cl_render_hold "passhooks scenehook"     (names separated by spaces or commas, any case)
--     retry
--
--   passhooks   the draw-pass detection (see "Which pass the engine is in" below; the part that made the terrain invisible on Kirovskoe
--               when it was three hooks)
--   scenehook   the wrapper around InfMap's RenderScene hook (and with it the render box correction, which needs the wrapper)
--   boundswrap  the replacement of Entity:SetRenderBoundsWS (the wrapper of InfMap's hook stays)
--   chunkwrap   the replacement of InfMap.prop_update_chunk
--   frame       the PreRender hook (override guard, Prop2Mesh sweep, render list top-up)
--   created     the OnEntityCreated hook
--   timer       the half-second scan (also re-installs the render box correction when InfMap's hook shows up late)
--   all         every part above
--
-- It is read when a part is installed, which is at load; a part that is already installed stays until the next retry. Nothing here
-- changes what the parts do. Held parts are listed in the load message, `acf_infmap_status` and `acf_infmap_renderdebug`.
Render.Pieces = {"passhooks", "scenehook", "boundswrap", "chunkwrap", "frame", "created", "timer"}

--- The names in the setting, lower case. Anything that is not a name of a part is kept here and simply holds nothing back.
local function HeldNames()
	local Names = {}
	local Text  = string.lower(Hold:GetString() or "")

	for Word in string.gmatch(Text, "[^%s,;]+") do Names[Word] = true end

	return Names
end

--- Is this part held back (left uninstalled)?
local function Held(Piece)
	local Names = HeldNames()

	return Names.all == true or Names[Piece] == true
end

--- The held parts, in the order of Render.Pieces. Exposed for the harness and the diagnostics.
function Render.HeldList()
	local Out = {}

	for _, Piece in ipairs(Render.Pieces) do
		if Held(Piece) then Out[#Out + 1] = Piece end
	end

	return Out
end

if #Render.HeldList() > 0 then
	Compat.Warn("cl_render: holding back ", table.concat(Render.HeldList(), ", "), " (acf_infmap_cl_render_hold = '", Hold:GetString(), "'). This is a diagnostic setting; set it to '' and retry for the normal behaviour.")
end

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
for _, Name in ipairs({"RenderRescued", "RenderThrottled", "RenderErrors", "RenderContextErrors", "ChildrenAdopted", "MeshRepositioned", "DrawRouted", "ClipRequests", "BoundsConverted", "RenderStuck", "BoxRepaired"}) do
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
--   * the engine runs the opaque renderables, then PreDrawTranslucentRenderables, the translucent ones, PostDrawTranslucentRenderables
--     (KNOWN). This file learns of those three moments from the GAMEMODE's own functions of those names, not from hooks (see below);
--   * the flags the engine hands to RenderOverride: STUDIO_DRAWTRANSLUCENTSUBMODELS (4; the GMod wiki words it "current render is
--     for translucent renderables only"). GUESS: whether the engine sets it for every translucent-pass draw or only for two-pass
--     models, which is why a flags value that says "opaque" never overrules the pass tracking. STUDIO_TRANSPARENCY (0x80000000) is NOT
--     read: in the Source SDK's studio.h it marks a non-sorting brush model, not a pass.
--
-- WHY NOT HOOKS (SEEN in play-test 7.4): with three hook.Add calls here (PreDrawOpaqueRenderables, PreDrawTranslucentRenderables,
-- PostDrawTranslucentRenderables, name "ACFInfMapCompat_Pass", bodies that return nothing), the terrain and buildings of
-- gm_infmap_kirovskoe vanished near the player; `acf_infmap_cl_render_hold passhooks` (these three and nothing else left out) made the
-- map right again, and every other part of this file was installed in both runs. A hook that returns nothing cannot change what other
-- hooks draw, so the effect has to come from the table the hooks live in:
--   KNOWN: hook.Call walks the event's table with pairs(), i.e. in table order, which Lua does not define, and a new key can move the
--          others (a table that gets one key too many is rebuilt).
--   GUESS: that the map (or something it loads) draws in more than one hook on one of these events and works only in the order it
--          happened to get, so that three more keys put it in the other order. `acf_infmap_hooklist` prints the order; set
--          `acf_infmap_cl_render_passmode hooks` (and retry) to bring the old behaviour back and compare the two prints.
-- The gamemode's function of the same name is called by hook.Call after all hooks, if no hook returned a value, and it is a field of
-- the gamemode table, not a key of any hook table, so wrapping it adds nothing to the tables whose order the map may depend on.
-- If a hook returns a value the gamemode function is not called, but then the engine skips that pass too, so there is nothing to
-- classify. KNOWN: hook.Call in GMod's lua/includes/modules/hook.lua; not re-read in this session.
local PassEvents   = {{"PreDrawOpaqueRenderables", false}, {"PreDrawTranslucentRenderables", true}, {"PostDrawTranslucentRenderables", false}}
local PassWrappers = Render.PassWrappers or setmetatable({}, {__mode = "k"}) -- [our wrapper function] = true

Render.PassWrappers = PassWrappers

--- Starts (or checks again, it is idempotent) the tracking of the draw pass. Needs the gamemode, so it can be too early at load.
local function InstallPass()
	local Label = "draw pass detection"

	if Held("passhooks") then
		Compat.Status[Label] = "held back (acf_infmap_cl_render_hold)"

		return
	end

	if string.lower(PassMode:GetString()) == "hooks" then
		for _, Event in ipairs(PassEvents) do
			local Value = Event[2]

			hook.Add(Event[1], "ACFInfMapCompat_Pass", function() Render.Translucent = Value end)
		end

		Compat.Status[Label] = "hooks (diagnostic mode, acf_infmap_cl_render_passmode)"

		return
	end

	local Gm = GAMEMODE

	if not istable(Gm) then
		Compat.Status[Label] = "waiting for the gamemode"

		return
	end

	for _, Event in ipairs(PassEvents) do
		local Name, Value = Event[1], Event[2]
		local Current     = Gm[Name]

		-- Wrapped again only when somebody put another function there since
		if not (isfunction(Current) and PassWrappers[Current]) then
			local Wrapper = function(Self, ...)
				Render.Translucent = Value

				if isfunction(Current) then return Current(Self, ...) end
			end

			PassWrappers[Wrapper] = true
			Gm[Name] = Wrapper
		end
	end

	Compat.Status[Label] = "wrapped (gamemode functions, no hook added)"
end

Render.InstallPass = InstallPass

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

--- Re-runs InfMap for every wrapped entity whose RenderOverride was replaced since, and for every entity that InfMap still holds
--- wrapped although it is in YOUR chunk.
---
--- The second rule is InfMap's own contract (cl_inf_chunks.lua, prop_update_chunk): an entity in the player's chunk is drawn by the
--- engine, not through a wrapper that moves the camera by a chunk difference. When the wrapper is still on it, the entity is drawn one
--- chunk (20000 units) away from where it is, i.e. it is invisible. InfMap restores every entity in one loop when the local player's
--- chunk changes, and that loop is one unprotected Lua call: an error raised for any entity in it ends the loop, and everything after
--- that entity keeps its wrapper. GUESS: that this is not what happens in the game; the counter `RenderStuck` (acf_infmap_status) says
--- how often this rule found something, and `acf_infmap_visdebug` names an example. The rule costs one comparison per watched entity.
local function Guard()
	local LP   = LocalPlayer()
	local Mine = IsValid(LP) and LP.CHUNK_OFFSET
	local I    = 1

	while I <= #List do
		local Ent = List[I]

		if not IsValid(Ent) or Ent.ValidRenderOverride == nil or not Ent.CHUNK_OFFSET then
			if IsValid(Ent) then
				Ent.ACFInfMapListed     = nil
				Ent.ACFInfMapStuckTried = nil
			end

			List[I] = List[#List]
			List[#List] = nil
		else
			-- Replaced since InfMap installed it, or wrapped without a Draw route that the entity would use (the addon was
			-- loaded after InfMap wrapped it, or the switch was turned on since)
			local Replaced = Ent.RenderOverride ~= Ent.ACFInfMapInstalled
			local Unrouted = Ent.ValidRenderOverride == false and Ent.OldRenderOverride == nil and Routable(Ent)
			local Stuck    = Mine and Ent.CHUNK_OFFSET == Mine

			-- The one attempt belongs to the situation "in your chunk and still wrapped"; once the entity is seen in another chunk (or
			-- put right) the next time is a new situation
			if not Stuck then Ent.ACFInfMapStuckTried = nil end

			Stuck = Stuck and Ent.ACFInfMapStuckTried ~= Mine

			if (Replaced or Unrouted or Stuck) and not Throttled(Ent) then
				if Stuck then
					-- One attempt per entity and chunk: if InfMap itself fails on it, asking every frame would not help
					Ent.ACFInfMapStuckTried = Mine
					Stats.RenderStuck       = Stats.RenderStuck + 1
					Render.LastStuck        = string.format("%s #%d", Ent:GetClass(), Ent:EntIndex())
				end

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

-- ---------------------------------------------------------------------------------------------------- Prop2Mesh render boxes
-- InfMap takes the render box of an entity in another chunk away (it shrinks it in front of your eye every frame) and gives it back
-- when you enter that chunk. What it gives back is the box it copied the first time it shrank it: `ent.RENDER_BOUNDS`
-- (cl_inf_chunks.lua). InfMap keeps that copy current when the box is changed through Entity:SetRenderBounds, because it detours
-- that function (cl_inf_detours.lua). A script that changed the box through ANOTHER route after the copy was made (a function it
-- captured before InfMap's detour existed, or the engine's own function) is not noticed, and walking into the chunk gives back the
-- old, smaller box. A mesh child of Prop2Mesh has the box of its model, a 47-unit plate, until the mesh data is there; with that box
-- left, the mesh is drawn only while the plate's own origin is on your screen, which for a vehicle you stand next to is almost never.
--   SEEN:  Prop2Mesh sets the box of a mesh child with Ent_SetRenderBounds, a local it captures from Entity.SetRenderBounds when its
--          file loads (sent_prop2mesh/cl_init.lua, line 46 and setRenderBounds), from refresh() and from the mesh-done hook.
--   SEEN:  in the test world, with Prop2Mesh loaded BEFORE InfMap's detours (so that it holds the engine's function), the box that
--          InfMap gives back on entering the chunk is the plate's, and the mesh is culled (tools/fuzz_render.lua, P2MRAW=1).
--   GUESS: that the game loads InfMap's detours before Prop2Mesh. Autorun files load before scripted entities (KNOWN), and InfMap's
--          autorun file includes its detours at once, so Prop2Mesh should hold InfMap's function and this rule should never act.
--          `acf_infmap_visdebug` reads the captured function out of Prop2Mesh and says which one it is.
-- The rule below does not depend on the answer: in your own chunk, a mesh child must have the box Prop2Mesh computed from the mesh
-- data (Prop2Mesh's own numbers: the data's bounds times the child's scale). If it has another one, it gets that one.
local function MeshBox(Info, Child)
	local Store = istable(prop2mesh) and prop2mesh.recycle
	local Entry = istable(Store) and Info.crc and Store[Info.crc]
	local Mesh  = istable(Entry) and istable(Entry.meshes) and Entry.meshes[Info.uniqueID]

	if not (istable(Mesh) and Mesh.ready and isvector(Mesh.vmins) and isvector(Mesh.vmaxs)) then return end

	local Scale = Child.scale

	if isvector(Scale) and (Scale.x ~= 1 or Scale.y ~= 1 or Scale.z ~= 1) then
		return Vector(Mesh.vmins.x * Scale.x, Mesh.vmins.y * Scale.y, Mesh.vmins.z * Scale.z), Vector(Mesh.vmaxs.x * Scale.x, Mesh.vmaxs.y * Scale.y, Mesh.vmaxs.z * Scale.z)
	end

	return Mesh.vmins, Mesh.vmaxs
end

local function RepairBoxes()
	local LP   = LocalPlayer()
	local Mine = IsValid(LP) and LP.CHUNK_OFFSET

	if not Mine then return end

	for _, Ent in ipairs(Render.P2M) do
		if IsValid(Ent) and istable(Ent.prop2mesh_controllers) then
			for _, Info in pairs(Ent.prop2mesh_controllers) do
				local Child = Info.ent

				-- Only where InfMap leaves the box alone: the child is in your chunk, not wrapped, and InfMap keeps no copy of its box
				if IsValid(Child) and Child.CHUNK_OFFSET == Mine and Child.ValidRenderOverride == nil and Child.RENDER_BOUNDS == nil then
					local Min, Max = MeshBox(Info, Child)

					if Min then
						local Has, Hasmax = Child:GetRenderBounds()

						if Has:DistToSqr(Min) > 0.25 or Hasmax:DistToSqr(Max) > 0.25 then
							Child:SetRenderBounds(Min, Max)

							Stats.BoxRepaired = Stats.BoxRepaired + 1
						end
					end
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
	-- The clipping-state probe of acf_infmap_visdebug runs even when the fix is switched off; its own error ends the probe, nothing else
	if Render.Probe and Render.Probe.Until > SysTime() and Render.SampleClip then
		local POK, PErr = pcall(Render.SampleClip)

		if not POK then
			Render.Probe.Until = 0
			Render.Probe.Error = tostring(PErr)
		end
	end

	if Render.Disabled or not On:GetBool() then return end

	local LP = LocalPlayer()

	if not IsValid(LP) or not LP.CHUNK_OFFSET or not InfMap.prop_update_chunk then return end

	for _, Step in ipairs(Steps) do
		local OK, Err = pcall(Step[2])

		if not OK then Fail(Step[1], Err) end
	end
end

if not Held("frame") then hook.Add("PreRender", "ACFInfMapCompat_Render", Frame) end

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
if not Held("created") then
	hook.Add("OnEntityCreated", "ACFInfMapCompat_Render", function(Ent)
		if IsValid(Ent) and Ent:GetClass() == "sent_prop2mesh" then Render.P2M[#Render.P2M + 1] = Ent end
	end)
end

if not Held("timer") then
	timer.Create("ACFInfMapCompat_RenderSlow", 0.5, 0, function()
		if Render.Disabled or not On:GetBool() then return end

		local OK, Err = pcall(function()
			Render.P2M = ents.FindByClass("sent_prop2mesh")

			Render.InstallBounds() -- InfMap may have registered its hook after us, or again (a Lua refresh)
			InstallPass()         -- somebody may have replaced a gamemode function since
			Scan()
			Flush()

			local BoxOK, BoxErr = pcall(RepairBoxes) -- its own protected call: a failure here must not stop the scan above

			if not BoxOK then Fail("the Prop2Mesh render box check", BoxErr) end
		end)

		if not OK then Fail("the slow render scan", Err) end
	end)
end

-- ---------------------------------------------------------------------------------------------------- install
--- The render box correction: InfMap's hook first (the detour only acts once the hook is wrapped), then the detour. Idempotent, so the
--- half-second scan calls it too: when InfMap's hook shows up after this file ran, the correction starts then.
function Render.InstallBounds()
	local Label = "render bounds (Entity:SetRenderBoundsWS)"

	-- Without the wrapper of InfMap's hook the correction cannot tell InfMap's own calls from the others, so it never acts
	if Held("scenehook") then
		Render.BoundsReady = false
		Compat.Status[Label] = "held back (acf_infmap_cl_render_hold)"

		return
	end

	if WrapBoundsHook() then
		if Held("boundswrap") then
			Compat.Status[Label] = "held back (acf_infmap_cl_render_hold)"
		else
			Compat.Wrap(EntityMT, "SetRenderBoundsWS", MakeBoundsDetour, Label)
		end
	else
		Compat.Status[Label] = "InfMap's RenderScene hook not found: left alone"
	end
end

local function Install()
	if not (InfMap and isfunction(InfMap.prop_update_chunk)) then
		Compat.Status["render guard (InfMap.prop_update_chunk)"] = "missing"

		return
	end

	if Held("chunkwrap") then
		Compat.Status["render guard (InfMap.prop_update_chunk)"] = "held back (acf_infmap_cl_render_hold)"
	else
		Compat.Wrap(InfMap, "prop_update_chunk", WrapChunkUpdate, "render guard (InfMap.prop_update_chunk)")
	end

	Render.InstallBounds()
	InstallPass()
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
	local Held_ = Render.HeldList()

	Lines[#Lines + 1] = #Held_ > 0 and ("HELD BACK by acf_infmap_cl_render_hold (not installed): " .. table.concat(Held_, ", ")) or "nothing held back (acf_infmap_cl_render_hold is empty)"
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

--- Lines for `acf_infmap_hooklist`: the hook names of the events this addon and the map's rendering care about, in the order GMod runs
--- them (the order of pairs over the table, which is what hook.Call uses; the table is not changed between the two walks). Exposed for the harness.
local ListedEvents = {"PreDrawOpaqueRenderables", "PostDrawOpaqueRenderables", "PreDrawTranslucentRenderables", "PostDrawTranslucentRenderables", "RenderScene", "PreRender"}

function Render.HookLines()
	local Lines = {}
	local Set   = hook.GetTable() or {}

	Lines[1] = "hook names per event, in the order GMod runs them. Names starting with ACFInfMapCompat_ are this addon's."

	for _, Event in ipairs(ListedEvents) do
		local Names = {}

		for Name in pairs(Set[Event] or {}) do Names[#Names + 1] = tostring(Name) end

		Lines[#Lines + 1] = string.format("%s (%d): %s", Event, #Names, #Names > 0 and table.concat(Names, ", ") or "-")
	end

	local Wrapped = {}

	if istable(GAMEMODE) then
		for _, Event in ipairs(PassEvents) do
			if PassWrappers[GAMEMODE[Event[1]]] then Wrapped[#Wrapped + 1] = Event[1] end
		end
	end

	Lines[#Lines + 1] = "gamemode functions this addon wraps to see the draw pass: " .. (#Wrapped > 0 and table.concat(Wrapped, ", ") or "none")
	Lines[#Lines + 1] = "draw pass detection: " .. tostring(Compat.Status["draw pass detection"]) .. "; acf_infmap_cl_render_passmode = " .. PassMode:GetString()

	return Lines
end

concommand.Add("acf_infmap_hooklist", function()
	for _, Line in ipairs(Render.HookLines()) do print("[ACF-InfMap] " .. Line) end
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

-- ---------------------------------------------------------------------------------------------------- acf_infmap_visdebug
-- One command that prints everything needed to tell WHY a visual clip prop or a Prop2Mesh mesh is not shown in a chunk, in one paste:
--   * which versions of InfMap, Visual Clip and Prop2Mesh the game really runs (size and line count of the files, compared with the
--     sources this addon was written against; the assumption "the Workshop versions equal the sources I read" was a GUESS until now);
--   * which function each addon captured when its file loaded (InfMap's detour or the engine's own), read out of the addons'
--     closures with debug.getupvalue; this decides whether the position and render-box rules of this file apply at all;
--   * whether InfMap holds wrappers on entities in YOUR chunk, or leaves entities of other chunks unwrapped;
--   * the state of the nearest visual clip props and Prop2Mesh meshes (override, saved box, engine box, hidden, alpha, distance);
--   * whether clipping is already switched on at the start of a frame, which some other addon would have to cause: every entity that
--     switches clipping on itself (Visual Clip props, clipped meshes) then clips against planes meant for something else.
-- Nothing here changes any entity. The probe runs for two seconds after the command, then the lines are printed.
local Known = {
	{Label = "InfMap cl_inf_chunks.lua",     Path = "infmap/cl_inf_chunks.lua",     Versions = {{"the original InfMap I read", 8982, 248}, {"the raphael fork I read", 9239, 254}}},
	{Label = "InfMap cl_inf_detours.lua",    Path = "infmap/cl_inf_detours.lua",    Versions = {{"the original InfMap I read", 6142, 181}, {"the raphael fork I read", 6075, 177}}},
	{Label = "InfMap sh_inf_networking.lua", Path = "infmap/sh_inf_networking.lua", Versions = {{"the original InfMap I read", 2295, 62}, {"the raphael fork I read", 2136, 57}}},
	{Label = "InfMap sh_inf_functions.lua",  Path = "infmap/sh_inf_functions.lua",  Versions = {{"the original InfMap I read", 12329, 348}, {"the raphael fork I read", 12284, 346}}},
	{Label = "Visual Clip clipping.lua",     Path = "autorun/client/clipping.lua",  Versions = {{"the Visual Clip I read", 3554, 148}}},
	{Label = "Prop2Mesh cl_init.lua",        Path = "entities/sent_prop2mesh/cl_init.lua", Versions = {{"the Prop2Mesh I read", 20816, 871}}},
}

Render.Known = Known
Render.Probe = Render.Probe or {Until = 0, Samples = 0, Enabled = 0}

local Probe = Render.Probe

--- Is clipping already enabled when the frame starts? (EnableClipping returns the state it replaced.) Called by Frame while armed.
local function SampleClip()
	local Was = render.EnableClipping(false)

	render.EnableClipping(Was)

	Probe.Samples = Probe.Samples + 1

	if Was then Probe.Enabled = Probe.Enabled + 1 end
end

Render.SampleClip = SampleClip

--- A Lua source file as the game has it; nil when it cannot be read
local function ReadSource(Path)
	local Text = file.Read(Path, "LUA")

	if not isstring(Text) then Text = file.Read("lua/" .. Path, "GAME") end

	return isstring(Text) and Text or nil
end

local function FingerprintLine(Entry)
	local Text = ReadSource(Entry.Path)

	if not Text then return Entry.Label .. ": not readable from Lua here" end

	local Size, Lines = #Text, select(2, string.gsub(Text, "\n", ""))
	local Match, All  = nil, {}

	for _, V in ipairs(Entry.Versions) do
		if V[2] == Size and V[3] == Lines then Match = V[1] end

		All[#All + 1] = string.format("%s: %d bytes %d lines", V[1], V[2], V[3])
	end

	return string.format("%s: %d bytes, %d lines, crc %s -> %s", Entry.Label, Size, Lines, tostring(isfunction(util.CRC) and util.CRC(Text) or "?"),
		Match and ("same size and line count as " .. Match) or ("DIFFERENT from every version I read (" .. table.concat(All, "; ") .. ")"))
end

--- The value of an upvalue of a Lua function, by name
local function Upvalue(Fn, Name)
	if not (isfunction(Fn) and istable(debug) and isfunction(debug.getupvalue)) then return nil end

	for I = 1, 200 do
		local N, V = debug.getupvalue(Fn, I)

		if not N then return nil end
		if N == Name then return V end
	end
end

--- Which function is this: InfMap's detour (what the Entity table holds now), the engine's own function (InfMap keeps it as
--- InfMap_<name>), or something else?
local function WhichFunction(Value, Name)
	if Value == nil then return "not found" end

	local Raw = EntityMT["InfMap_" .. Name]

	if Raw ~= nil and Value == Raw and Raw ~= EntityMT[Name] then return "the ENGINE's own function (InfMap's detour is not used by it)" end
	if Value == EntityMT[Name] then return Raw ~= nil and "InfMap's detour" or "the function now in the Entity table (InfMap keeps no InfMap_" .. Name .. ")" end

	return "some other function"
end

local function Try(Ent, Name, ...)
	local Fn = Ent[Name]

	if not isfunction(Fn) then return "?" end

	local OK, A, B = pcall(Fn, Ent, ...)

	if not OK then return "?" end

	return A, B
end

local function BoxText(Min, Max)
	if not (isvector(Min) and isvector(Max)) then return "none" end

	return string.format("[%.0f %.0f %.0f]..[%.0f %.0f %.0f]", Min.x, Min.y, Min.z, Max.x, Max.y, Max.z)
end

--- The lines for one entity
local function Describe(Ent, Mine, Indent)
	local Lines  = {}
	local Parent = Try(Ent, "GetParent")
	local Min, Max = Try(Ent, "GetRenderBounds")
	local Same   = Mine and Ent.CHUNK_OFFSET == Mine
	local Colour = Try(Ent, "GetColor")
	local Wrapped = Ent.ValidRenderOverride ~= nil

	Lines[#Lines + 1] = string.format("%s%s #%d [%s]: model %s, hidden %s, alpha %s, dormant %s, parent %s", Indent, Ent:GetClass(), Ent:EntIndex(), Chunks(Ent, Mine),
		tostring((Try(Ent, "GetModel"))), tostring((Try(Ent, "GetNoDraw"))), tostring(istable(Colour) and Colour.a or (Colour and Colour.a) or "?"), tostring((Try(Ent, "IsDormant"))),
		(isentity(Parent) and IsValid(Parent)) and (Parent:GetClass() .. " #" .. Parent:EntIndex()) or "none")

	Lines[#Lines + 1] = string.format("%s    override now: %s. Wrapped by InfMap: %s (the entity's own override under it: %s). InfMap's saved box: %s. Engine box: %s.", Indent,
		Kind(Ent, Ent.RenderOverride), Wrapped and "YES" or "no", Wrapped and Kind(Ent, Ent.OldRenderOverride) or "-", Ent.RENDER_BOUNDS and BoxText(Ent.RENDER_BOUNDS[1], Ent.RENDER_BOUNDS[2]) or "none", BoxText(Min, Max))

	if Same and Wrapped then Lines[#Lines + 1] = Indent .. "    !! InfMap still holds a wrapper on this entity although it is in YOUR chunk: it is drawn one chunk away." end

	if Same and isvector(Min) and isvector(Max) and isfunction(Ent.LocalToWorld) then
		local Centre = Ent:LocalToWorld((Min + Max) * 0.5)
		local Off    = Centre - EyePos()
		local Bound  = InfMap.source_bounds and InfMap.source_bounds.x or 16384

		Lines[#Lines + 1] = string.format("%s    engine box centre is %.0f units from your eye, %s the +-%d world box (culled by the engine when it is outside).", Indent, Off:Length(),
			(math.abs(Centre.x) <= Bound and math.abs(Centre.y) <= Bound and math.abs(Centre.z) <= Bound) and "inside" or "OUTSIDE", Bound)
	end

	if Ent.MaxClips ~= nil and isfunction(Ent.OBBCenter) and isfunction(Ent.LocalToWorld) then
		local Centre = Ent:OBBCenter()
		local A      = Ent:LocalToWorld(Centre)
		local B      = isfunction(Ent.InfMap_LocalToWorld) and Ent:InfMap_LocalToWorld(Centre) or A

		Lines[#Lines + 1] = string.format("%s    visual clip: %s plane(s) in use. LocalToWorld of its centre is %.2f chunk(s) from the engine's own answer (0 expected in YOUR chunk).", Indent, tostring(Ent.MaxClips), (A - B):Length() / (InfMap.chunk_size * 2))
	end

	return Lines
end

--- Distance from your eye, in the frame InfMap's GetPos answers in (your chunk's). Entities that cannot say come last.
local function EyeDistance(Ent)
	local OK, Pos = pcall(Ent.GetPos, Ent)

	return (OK and isvector(Pos)) and Pos:DistToSqr(EyePos()) or math.huge
end

--- Nearest first: by chunk, and inside a chunk by distance from your eye (a chunk can hold hundreds of clipped props; the dump
--- lists only a few, and they have to be the ones next to you)
local function ByDistance(Mine)
	return function(A, B)
		local DA = (Mine and A.CHUNK_OFFSET) and (A.CHUNK_OFFSET - Mine):LengthSqr() or math.huge
		local DB = (Mine and B.CHUNK_OFFSET) and (B.CHUNK_OFFSET - Mine):LengthSqr() or math.huge

		if DA ~= DB then return DA < DB end

		local EA, EB = EyeDistance(A), EyeDistance(B)

		if EA ~= EB then return EA < EB end

		return A:EntIndex() < B:EntIndex()
	end
end

--- Lines for `acf_infmap_visdebug`. Exposed for the harness.
function Render.VisLines()
	local Lines = {}
	local LP    = LocalPlayer()
	local Mine  = IsValid(LP) and LP.CHUNK_OFFSET or nil
	local All   = ents.GetAll()

	Lines[#Lines + 1] = string.format("visual contraption dump. You are in chunk %s. Render fix %s.", Mine and Compat.ChunkText(LP) or "?", (On:GetBool() and not Render.Disabled) and "ON" or "OFF")
	Lines[#Lines + 1] = "-- 1. the files the game really runs (compared with the sources this addon was written against)"

	for _, Entry in ipairs(Known) do Lines[#Lines + 1] = "   " .. FingerprintLine(Entry) end

	-- InfMap.prop_update_chunk: ours wraps it; the wrapper holds the original in the upvalue Original
	local Current = InfMap and InfMap.prop_update_chunk
	local Own     = Upvalue(Current, "Original") or Current
	local Info    = (istable(debug) and isfunction(debug.getinfo) and isfunction(Own)) and debug.getinfo(Own, "S") or nil

	Lines[#Lines + 1] = string.format("   InfMap.prop_update_chunk: %s; defined at %s lines %s-%s (original InfMap: 127-248, raphael fork: 134-254)", Upvalue(Current, "Original") and "wrapped by this addon" or "NOT wrapped by this addon",
		Info and tostring(Info.short_src) or "?", Info and tostring(Info.linedefined) or "?", Info and tostring(Info.lastlinedefined) or "?")

	Lines[#Lines + 1] = "-- 2. which function each addon captured when its file loaded"

	local Refresh = istable(prop2mesh) and prop2mesh.refresh
	local SetBox  = Upvalue(Upvalue(Refresh, "setRenderBounds"), "Ent_SetRenderBounds")

	Lines[#Lines + 1] = "   Prop2Mesh SetRenderBounds: " .. (Refresh and WhichFunction(SetBox, "SetRenderBounds") or "Prop2Mesh not loaded")
	Lines[#Lines + 1] = "   Prop2Mesh GetPos: " .. (Refresh and WhichFunction(Upvalue(Refresh, "Ent_GetPos"), "GetPos") or "Prop2Mesh not loaded")
	Lines[#Lines + 1] = "   Prop2Mesh SetPos: " .. (Refresh and WhichFunction(Upvalue(Refresh, "Ent_SetPos"), "SetPos") or "Prop2Mesh not loaded")

	local Clipped = {}
	local Sample

	for _, Ent in ipairs(All) do
		if IsValid(Ent) and Ent:EntIndex() > 0 and Ent.MaxClips ~= nil then
			Clipped[#Clipped + 1] = Ent

			if not Sample then
				local Fn = Ent.ValidRenderOverride ~= nil and Ent.OldRenderOverride or Ent.RenderOverride

				Sample = Unwrap[Fn] or Fn
			end
		end
	end

	Lines[#Lines + 1] = "   Visual Clip LocalToWorld: " .. (Sample and WhichFunction(Upvalue(Sample, "ent_LocalToWorld"), "LocalToWorld") or "no clipped prop to read it from")

	Lines[#Lines + 1] = "-- 3. InfMap's contract"

	local Stuck, Unwrapped = {}, {}

	if Mine then
		for _, Ent in ipairs(All) do
			if IsValid(Ent) and Ent.CHUNK_OFFSET and Ent:EntIndex() > 0 then
				if Ent.CHUNK_OFFSET == Mine then
					if Ent.ValidRenderOverride ~= nil then Stuck[#Stuck + 1] = Ent end
				elseif (Ent.CHUNK_OFFSET - Mine):LengthSqr() <= 100 and Ent.ValidRenderOverride == nil and not Ent:IsPlayer() and not InfMap.filter_entities(Ent) then
					Unwrapped[#Unwrapped + 1] = Ent
				end
			end
		end
	end

	table.sort(Stuck, ByDistance(Mine))
	table.sort(Unwrapped, ByDistance(Mine))

	Lines[#Lines + 1] = string.format("   entities InfMap holds wrapped although they are in your chunk: %d (this addon has put %d right so far%s)", #Stuck, Stats.RenderStuck, Render.LastStuck and (", the last was " .. Render.LastStuck) or "")

	for I = 1, math.min(#Stuck, 5) do
		for _, Line in ipairs(Describe(Stuck[I], Mine, "   ")) do Lines[#Lines + 1] = Line end
	end

	Lines[#Lines + 1] = string.format("   entities within 10 chunks that are NOT wrapped although they are in another chunk: %d", #Unwrapped)

	for I = 1, math.min(#Unwrapped, 3) do Lines[#Lines + 1] = string.format("      %s #%d [%s]", Unwrapped[I]:GetClass(), Unwrapped[I]:EntIndex(), Chunks(Unwrapped[I], Mine)) end

	Lines[#Lines + 1] = string.format("   Prop2Mesh render boxes put right so far: %d", Stats.BoxRepaired)
	Lines[#Lines + 1] = "-- 4. clipping state at the start of a frame"
	Lines[#Lines + 1] = Probe.Error and ("   the probe raised an error: " .. Probe.Error) or string.format("   sampled %d frame(s): clipping was already enabled at the start of %d of them%s", Probe.Samples, Probe.Enabled,
		Probe.Enabled > 0 and " -> somebody leaves clipping on; every entity that switches it on itself will clip against whatever plane is still pushed" or "")

	Lines[#Lines + 1] = "-- 5. nearest visual clip props"

	table.sort(Clipped, ByDistance(Mine))

	if #Clipped == 0 then Lines[#Lines + 1] = "   none (no prop holds a visual clip on this client)" end

	for I = 1, math.min(#Clipped, 5) do
		for _, Line in ipairs(Describe(Clipped[I], Mine, "   ")) do Lines[#Lines + 1] = Line end
	end

	Lines[#Lines + 1] = "-- 6. nearest Prop2Mesh entities and their meshes"

	local Meshes = {}

	for _, Ent in ipairs(Render.P2M) do
		if IsValid(Ent) then Meshes[#Meshes + 1] = Ent end
	end

	table.sort(Meshes, ByDistance(Mine))

	if #Meshes == 0 then Lines[#Lines + 1] = "   none" end

	for I = 1, math.min(#Meshes, 3) do
		local Ent = Meshes[I]

		for _, Line in ipairs(Describe(Ent, Mine, "   ")) do Lines[#Lines + 1] = Line end

		local Shown = 0

		for K, Inf in pairs(istable(Ent.prop2mesh_controllers) and Ent.prop2mesh_controllers or {}) do
			local Child = Inf.ent

			if IsValid(Child) and Shown < 3 then
				Shown = Shown + 1

				for _, Line in ipairs(Describe(Child, Mine, "      mesh " .. tostring(K) .. ": ")) do Lines[#Lines + 1] = Line end

				local Min, Max = MeshBox(Inf, Child)
				local Local    = Try(Child, "GetLocalPos")
				local Link     = Inf.linkpos or vector_origin

				Lines[#Lines + 1] = string.format("         mesh data box: %s; local offset from linkpos: %s", Min and BoxText(Min, Max) or "no mesh data yet",
					isvector(Local) and string.format("%.1f units", Local:Distance(Link)) or "?")
			end
		end
	end

	return Lines
end

concommand.Add("acf_infmap_visdebug", function()
	Probe.Until, Probe.Samples, Probe.Enabled, Probe.Error = SysTime() + 2, 0, 0, nil

	print("[ACF-InfMap] collecting for 2 seconds; keep the vehicle's parts in view (the clipping-state sample needs frames)")

	timer.Simple(2.2, function()
		for _, Line in ipairs(Render.VisLines()) do print("[ACF-InfMap] " .. Line) end
	end)
end)

Compat.StatusLines.cl_render = function()
	return {
		string.format("render: guard %s, %d entities watched, overrides put back %d, meshes repositioned %d, children adopted %d, drawn through Draw %d, render boxes converted %d (%s), wrappers left in your own chunk put right %d, Prop2Mesh boxes put right %d, errors %d (acf_infmap_renderdebug, acf_infmap_entdebug and acf_infmap_visdebug list them)",
			(On:GetBool() and not Render.Disabled) and "ON" or "OFF", #List, Stats.RenderRescued, Stats.MeshRepositioned, Stats.ChildrenAdopted, Stats.DrawRouted, Stats.BoundsConverted, Render.BoundsReady and "ready" or "NOT ACTIVE: InfMap's RenderScene hook not found", Stats.RenderStuck, Stats.BoxRepaired, Stats.RenderErrors),
		string.format("visclip: resync %s, %d request(s) sent, server side %s", Resync:GetBool() and "ON" or "OFF", Stats.ClipRequests, CanAsk() and "present" or "ABSENT"),
		(#Render.HeldList() > 0) and ("render parts HELD BACK (diagnostic): " .. table.concat(Render.HeldList(), ", ")) or "render parts held back: none",
	}
end
