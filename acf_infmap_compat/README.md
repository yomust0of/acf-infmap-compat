# ACF3 <-> InfMap compatibility (standalone addon), version 6.1

One addon folder. It edits neither ACF, InfMap, Visual Clip nor Prop2Mesh: it wraps their functions at runtime, keeps the originals, and does nothing on maps that are not InfMap maps. Delete the folder and you are back to stock behaviour.

Built for the **original InfMap** (meetric1's "Infinite Map Base", the Workshop one, `chunk_size = 10000`) and ACF-3 master.

Labels used everywhere (here and in the headers of every `.lua` file):

- **SEEN** = read in the real source, or run in the test harness against the real files.
- **KNOWN** = standard GMod / Source behaviour that I did not re-check.
- **GUESS** = inference. Only a real game can confirm it.

## What changed in version 6.1 (only the test command and one menu button)

`acf_infmap_bullettest` took its size from the nearest ammo crate within 5000 units, so next to a machinegun it always made a machinegun-sized shell. It now also takes:

- `self`: do not look for a crate; you are the crate. ACF then uses its own default caliber for a crate that reports none, 10 cm = **100 mm**, model scale 1.
- `<n>mm` (for example `100mm`, `7.62mm`): set the caliber of this one shell. ACF's own formulas then size the model (`Caliber(cm) * 0.1`) and the tracer sprite (`Caliber(cm) * 15` wide). The output says whether the number was **overridden** and what the crate said.

`acf_infmap_bullettest 100 100mm tracer self` = 100 m/s, 100 mm, a tracer, flying away from where you look, no crate involved. There is a button for it in the tool menu. Nothing else changed: the fixes are the same as version 6. Tests: 13 new checks, and 7 of 8 deliberately broken variants of the new code fail them (the eighth is equivalent code, not a gap).

## What changed in version 6

Your reports after version 5: the lazer entities themselves (not their damage) vanish when they are not in your chunk, and you still see no bullets or tracers from a real cannon. You sent the lazer addon (`Acf_LaZers`), so the first part comes from its real code. No band-aids; where I could not find a cause I say so.

### 1. Lazers (and any scripted entity with a beam, glow or overlay) in other chunks: four causes

What the lazer does (SEEN, `acf_lazer/cl_init.lua`, `shared.lua`): the model is an invisible emitter; the beam and the glow are drawn in `DrawTranslucent` with `render.DrawBeam` / `render.DrawSprite` from `GetMuzzlePos()` (= `LocalToWorld`), and every `Think` it sets its render box with `SetRenderBoundsWS`.

| # | Cause (SEEN in the source of InfMap, ACF and the lazer) | Effect |
|---|---|---|
| 1 | InfMap draws an entity of another chunk through a wrapper that calls `self:DrawModel()` (or the entity's old `RenderOverride`). The beam lives in `DrawTranslucent`, which is not `DrawModel`. | In another chunk the model is drawn and the beam and glow are never drawn. "The lazer disappears." |
| 2 | Even if the beam were drawn, its position comes from `LocalToWorld`, which InfMap detours to answer in **your** chunk's frame, while the camera is shifted into the **entity's** frame. | The beam would sit one chunk-offset away from the lazer |
| 3 | ACF's `acf/contraption/overrides_cl.lua` clears `RenderOverride` one second after any `IsACFEntity` is created. The lazer inherits `IsACFEntity` from `acf_base_scalable`. | If the lazer is in another chunk when it is created (a dupe pasted away from you, you joining the server), InfMap's wrapper is removed from it a second later and the raw, unshifted draw comes back. A lazer you simply walk away from is wrapped after that second and is not hit by this |
| 4 | The lazer calls `SetRenderBoundsWS` with positions from `LocalToWorld`, i.e. in your frame. The engine stores the box relative to the lazer's **real** position, so in another chunk the stored box is one chunk-difference off. InfMap's per-frame hook `!infinite_update_visbounds` caches `GetRenderBounds()` **once**, lazily, as `ent.RENDER_BOUNDS`, and shrinks that cached box toward your eye. | The cached box is wrong (in the harness: a box centred 60000 units from the lazer), so the shrunk box ends up outside the +-16384 box in which the engine renders anything |

What the fix does (`cl_render.lua`, all of it switchable):

- **Draw route** (`acf_infmap_cl_render_draw`, default 1). In another chunk, a scripted entity (`IsScripted()`) that has no `RenderOverride` of its own gets one that behaves like the engine would without InfMap: the opaque pass runs its `Draw`, the translucent pass runs its `DrawTranslucent`. It runs with your `CHUNK_OFFSET` temporarily set to the entity's (the same chunk context as version 5), so `LocalToWorld` answers in the frame of the shifted camera and the beam sits on the lazer (cause 2). Entities that bring their own `RenderOverride` are left alone. In your own chunk nothing is added.
- **Which pass it is** comes from two independent signals, either is enough: the pass hooks (`PreDrawOpaqueRenderables`, `PreDrawTranslucentRenderables`, `PostDrawTranslucentRenderables`; KNOWN) and the flags the engine hands to `RenderOverride` (`STUDIO_DRAWTRANSLUCENTSUBMODELS`, bit value 4; GUESS whether the engine sets it for every translucent draw, which is why "opaque" in the flags never overrules the hooks).
- **The guard** puts InfMap's wrapper back when ACF's `overrides_cl.lua` (or anything else) removes it, in the same frame, and gives wrapped scripted entities the route if they lack it (cause 3).
- **Render box correction** (`acf_infmap_cl_render_bounds`, default 1). `Entity:SetRenderBoundsWS` is wrapped. A call on an entity in another chunk that does **not** come from InfMap's own hook is shifted by the chunk difference, so the stored box is in the entity's own frame again (cause 4). InfMap's own calls pass through untouched: that hook is wrapped so the detour can tell them apart. If InfMap's hook is not there when this file loads the correction stays off and `acf_infmap_status` says so; the half-second scan starts it as soon as the hook shows up, and wraps a hook InfMap registers again after a Lua refresh.
- `acf_infmap_entdebug lazer` (any part of a class name) prints, for the nearest few entities of that class: chunk, whether it is scripted, whether `Draw` / `DrawTranslucent` exist, render group, hidden, **InfMap's stored local render box and how far its centre is from the entity's origin**, whether InfMap's wrapper is on it and intact, the Draw route, and how often the engine called it.

**What the harness shows** (real InfMap, ACF and Visual Clip files, the lazer's draw code reproduced from its `cl_init.lua`): STOCK, a lazer three chunks away loses its beam, loses its wrapper after one second, and while it fires its cached box lands outside the world box; FIXED, it is drawn with the beam on it in all of those cases. **What it cannot show** is the engine: how the real culling treats the corrected box is a GUESS (see the list).

**Known limits.** Culling uses the lazer's body box, not the beam: a beam that crosses your view while the lazer itself is off-screen is not drawn (and beyond 4 chunks InfMap uses a single point as the box, so the beam can only show while that point is on-screen). A lazer that sits right at a chunk border and fires toward you can still have its box inflated by InfMap's shrink factor. If you want the beam visible whenever it crosses your view, the lazer's own `UpdateBeamBounds` would have to give a box that is honest about the beam; that is a change in the lazer, not here.

### 2. Bullets and tracers from a real cannon: no defect found, so the shots now report themselves

I re-read every step between the server's `BulletClient` and the engine drawing the shell: the message, the conversion, ACF's `Init`, `ApplyMovement`, my keep-alive, the draw fallback. **I found nothing that stops a real shell from being drawn inside the window**, and the one shell I could follow in your v5 output was drawn by the engine once. Three facts, together or alone, explain "I cannot see it" without any bug, and none of them can be read from here:

- **Speed.** An 800 m/s shell crosses 100 m in 0.125 s: about 7 frames at 60 fps. A test shell at 15 m/s stays for seconds. (KNOWN arithmetic; GUESS that this is your case.)
- **The crate's Tracer box.** ACF reads `Crate:GetNW2Float("Tracer")` once, when the bullet is created; no tracer is made when it is 0 (SEEN, `effects/acf_bullet_effect.lua`). The crate holds `Caliber * 0.15` when the ammo menu's Tracer box was ticked when the crate was made or updated (SEEN, `core/round_functions.lua`). Ticking it later does not change a crate that was not updated, and does not change shells already in flight.
- **Hidden bullets.** The server sends Attachment 0 for `Bullet.Hide`, which ACF sets only for the piledriver and one special shell (SEEN). A hidden bullet has no model and no tracer.

So every real shot now writes **one line to your console when its bullet ends** (`acf_infmap_cl_shot_report`, default 1; at most 8 lines per 10 s, the rest are counted and announced on the next line; the test shells are never reported). Example (from the harness):

```
[ACF-InfMap] shot #5 | crate Tracer box ON (1) | 762 m/s | 3 m from you at the start, closest 38 m, 76 m at the end | engine drew it 0 frame(s), this addon 2 | lived 0.40 s | ended: hit - a hit message of type 1 arrived 0.40 s after the bullet was created
```

How to read it: **the Tracer box** says whether ACF made a tracer at all; **m/s** and **lived** tell how long you had to see it; **closest** is sampled once per tick, so it is within about one tick of flight of the true value; **engine drew it N frame(s)** is the number of times the engine really called the shell's `Render`, and **this addon M** the frames this addon had to draw it itself because the engine did not. `engine drew it 0` with `this addon 0` on a shell that lived long enough to be seen is the line I need most.

`acf_infmap_cl_force_tracer` (default 0, diagnostic) gives every real shell a tracer made by ACF's own tracer code (an emitter, the crate's colour) even if the crate's Tracer is 0. If shells then show tracers, tracers render and the tick box is what is off; if they still do not, send me the lines.

### Earlier versions

#### Version 5 (still in this addon)

Your report after version 4: lasers work (nothing to do there), the bullet test shows the model but no tracer, bullets from your cannon are not visible, and a dupe pasted away from you loses parts: visual-clipped props and Prop2Mesh meshes. No band-aids.

##### Parts of a pasted dupe missing (visual clips, Prop2Mesh): six root causes, one fix

I ran the **real** InfMap, Visual Clip and Prop2Mesh files together in a test harness (only the engine is modelled) and the failures reproduce without this addon. Six separate causes (SEEN in the source; what the engine does with them is GUESS where marked). The full text is the header of `cl_render.lua`.

| # | Cause | Effect |
|---|---|---|
| 1 | InfMap draws a prop from another chunk by wrapping its `RenderOverride` **once** (it moves the camera by the chunk difference). Visual Clip and Prop2Mesh assign `RenderOverride` on their own schedule, and whoever writes second wins. InfMap's remembered "old" override also goes stale. | The prop is drawn at its raw chunk-local position seen from your chunk (wrong place), and the clip is lost the next time the chunk is updated |
| 2 | Clip planes are computed with `LocalToWorld`, which InfMap detours to answer in **your** chunk's frame; the model is drawn through the shifted camera, i.e. in the **entity's** frame. Same for Prop2Mesh's clipped meshes (`Ent_GetPos`) | The clip plane sits one chunk-offset away from the model |
| 3 | Prop2Mesh meshes are **client-side child entities**. InfMap only gives children a chunk and a wrapper if they exist at the moment their parent's chunk is updated | A mesh made later is drawn unshifted |
| 4 | **The position bug you described.** `refresh()` computes the mesh position from `Ent_GetPos(parent)`, which is InfMap's detour (your frame), and applies it with `Ent_SetPos` on a parented child. The engine turns a world position on a parented entity into a parent-local one with the parent's real transform (KNOWN, Source SDK), so the local offset comes out as "linkpos + chunk difference", clamped | The mesh sits far from its parent. In the harness: 14334 units off for a player outside the dupe's chunk, correct for a player inside it. That is "the guy next to the dupe sees it fine" |
| 5 | Complex meshes (more than one IMesh) are drawn by the child's own `Draw`, not `DrawModel`; InfMap's wrapper only calls `DrawModel` | For a wrapped mesh the big part is never drawn |
| 6 | Visual Clip announces a clip with `net.Broadcast` and `net.WriteEntity`. A client that does not know the prop yet reads NULL and drops it; the server only re-sends at join | Props that reach you later never get their clips |

What the fix does (`cl_render.lua`, `sv_visclip.lua`). **It never reloads a model, a mesh or a clip**; the loops are a few table reads per entity.

- Wraps `InfMap.prop_update_chunk`. A replaced wrapper is moved back into InfMap's "old override" slot; after InfMap runs, that old override is run with your `CHUNK_OFFSET` temporarily set to the **entity's**, so every detoured position function answers in the frame the shifted camera draws in (fixes 1 and 2). The value is restored even if the override errors, and the error is swallowed once and counted, so InfMap's `cam.End3D()` still runs.
- A `PreRender` guard looks at every wrapped entity; if its override is no longer the one InfMap installed it goes through the step above again **in the same frame, before anything is drawn**. An entity that rewrites its override every frame is put back at most about 20 times a second.
- Prop2Mesh children are found through `prop2mesh_controllers` (Prop2Mesh's own table): the local position is put back to `linkpos` (cause 4), the child gets its parent's chunk and wrapper if it lacks them (cause 3), and a wrapped child without an override of its own gets one that calls the child's `Draw` (cause 5). The wrapper's variant is chosen when InfMap builds it, so InfMap is run on the child again after that change. This runs every frame, so it does not matter in which order InfMap, Prop2Mesh and this addon got to the child.
- Other client-side children of chunked entities get the same adoption (every half second). Wrapped entities that `ents.GetAll()` does not list are added to `InfMap.all_ents`, because InfMap only shrinks render bounds for entities in that list.
- **Visual clip resync.** When a prop with a chunk first comes within `acf_infmap_cl_visclip_range` chunks of you and your client holds no clips for it, your client asks the server once; the server answers with Visual Clip's **own** "send all clips of this prop" message, only to you, 8 answers per tick at most. Requests are capped (255 props per message, 10 messages per second per player, 4096 waiting per player).

**How this differs from what you asked for.** You asked for "within 6 chunks of a contraption, its visclips and meshes reload". It is not a reload, on purpose (no lag spikes), and it is not tied to a 6-chunk radius: the position, wrapper and `Draw` repairs are continuous and apply to every wrapped entity at any distance InfMap still draws it. Only the clip **request** has a radius, and its default is **12 chunks** (slider 1 to 100 in the menu), not 6: it costs one tiny message per prop, ever, and the earlier a prop has its clips the less pop-in. Say if you want 6.

**Not covered.** InfMap draws a plain box farther than its 10-chunk level of detail, so nothing clip-related can show there. Prop2Mesh meshes **with clips** draw only their first mesh part (stock Prop2Mesh, also in a normal map). If Prop2Mesh's `LinkEntRemoved` moves a mesh to its parent's origin, this addon puts it back at `linkpos`, which is what the next refresh would do. Two clip messages crossing (the Broadcast and the resync answer) can give a prop the same plane twice: drawn identically, it only uses the per-prop plane cap faster (GUESS: rare).

**The repository you asked about.** I looked. I found **no InfMap-aware Visual Clip fix**. The only related thing is the Workshop addon "Visual Clip - Additional Fixes" (792356000, SammyT291), which re-sends clips to players who join late. It does not touch chunks, render overrides or clip-plane space, so it addresses cause 6 for a join, and nothing else. (From its Workshop page; I did not read its code.)

##### Bullets from the cannon, and the tracer (version 5 findings)

What the play-test output you pasted shows, and what I do and do not know:

- **Not the crate.** `crate-valid-before-fix=yes` and `EntityFixed=0`: the engine already resolved the crate on the client-made effect, so the crate fix of version 4 is only a fallback (SEEN, your output).
- **The missing tracer is, most likely, the crate's Tracer tick box.** ACF makes a tracer only when the crate's `Tracer` NW2 float is above 0 (`effects/acf_bullet_effect.lua`), and the crate sets it to `Caliber * 0.15` when the tick box is on and 0 when off (`core/round_functions.lua`). Your cannon bullets showed `tracer-emitter=NO`, and the test shell found no tracer crate. (GUESS, high: I cannot see your crate's value.) The debug lines now **print that number**, so it is a reading and not a guess: `acf_infmap_bullettest` and `acf_infmap_bulletdebug` print `Tracer=0.9 (ON)` or `Tracer=0 (OFF)` for the crate used.
- **Why your cannon's bullets are not visible: not found.** In your `acf_infmap_bulletdebug` output the first bullets were gone from the client table with no hit message received for any of them. Nothing I can read in ACF or in this addon explains that, and I am not going to invent a cause. Version 5 **logs how every bullet ends**: range limit (this addon's own keep-alive), hit message, ACF's own limit, 45 s timeout, or "unknown", with lifetime, last position, speed and engine render count. That turns "they vanish" into a reason.
- `acf_infmap_bullettest [speed in m/s] [tracer]` now takes a speed (default 15; `800` is a real shell's speed) and `tracer`, which forces ACF's own tracer on that one shell. "I see a tracer now" means tracers render and the crate's tick box is what is off. It uses the nearest ammo crate within 5000 units when there is one.

#### Versions 3 and 4 (still in this addon)

Version 4 replaced version 3's invented far effects with ACF's own effect code replayed through recorded particles, and kept bullets alive past ACF's 16380-unit limit so impacts work; see "What it fixes" below.

## What it fixes (all versions)

| Area | Problem under InfMap | Fix |
|---|---|---|
| Sounds | ACF picks who hears a sound with `net.SendPAS(GetPos())`, and InfMap's server `GetPos()` is a global position. Engines in other chunks are silent or heard in the wrong place. | Sounds go to every player within a range (global distance), loops are created for players who drive into range and stopped for players who leave. Client plays one-shots of other-chunk entities at their local-frame position. |
| Bullet traces | A trace only sees entities in the chunk it starts in. A shot that crosses a border can tunnel through a prop right behind it. | While `ACF.trace` runs, the line is cut at chunk borders and each piece is traced in its own chunk. First hit wins. |
| Clone hits | A hit on an `infmap_clone` names the clone, not the prop. ACF then treats the hit as World, so the prop takes no damage. | The clone hit is turned into a hit on the real prop. If the real prop is on the bullet's filter (your own gun), the clone is ignored and the shot continues. |
| Stray bullets | Nothing removes a bullet that hits nothing, so misses pile up in ACF's 2000 bullet slots and guns stop firing. | A bullet older than `acf_infmap_bullet_lifetime` seconds (default 180) is removed with ACF's own `RemoveBullet`. |
| Effects | Tracers, muzzle flashes, impacts and explosions carry a global position that the effect system cannot store, and the engine picks the audience from that position. | Server effects go out in this addon's own message with the exact position; the client converts it into its own chunk frame and calls `util.Effect` itself, so ACF's own effect code runs on an ordinary local position. A `util.Effect` call that names an ACF effect goes the same way. Effects of other addons are untouched. |
| Tracer crate | ACF's tracer effect finds its crate with `Data:GetEntity()`; `SetEntIndex` / `GetEntIndex` are server-only (GMod wiki). | The client sets the entity itself if it is missing. In your game it was not missing (see above). |
| Far effects and bullets | The engine places and draws effects only inside about +-16384 units of the frame origin, which under InfMap is the **centre of your chunk**; ACF kills a bullet's client effect past 16380 units. | ACF's own effect code runs and its particles are replayed with immediate-mode draw calls; bullets are kept alive past the limit. Details in the headers of `cl_replay.lua` and `cl_bullets.lua`. |
| Visual clips and Prop2Mesh in other chunks | See version 5 above. | See version 5 above. |

Hit-effect range: the server sends effects to players within 120000 units (about 3 km, six chunks, adjustable to 400000); your far distance is 3000 m (adjustable to 10000 m).

## Install

1. Delete any older `acf_infmap_compat` folder (versions 1 to 5 used the same name).
2. If you installed the "ACF InfMap sound glue" (the `infmap_sounds_sv.lua` / `infmap_sounds_cl.lua` files inside ACF's `lua/acf/compatibility/`), delete those two files. If you leave them, this addon notices, prints a warning and turns its own sound fix off so nothing is done twice.
3. Put the `acf_infmap_compat` folder in `garrysmod/addons/` on the **server** (listen server: your own addons folder).
4. Restart the map. Clients get the client files automatically (the autorun calls `AddCSLuaFile`).

Everyone who should see the repaired meshes and clips needs the addon **on the server** (so clients download it); the visual clip resync also needs it on the server because the server answers the requests.

Load order: GMod runs autorun files alphabetically, and `zz_` sorts after InfMap's `!!inf_init` and ACF's loader (KNOWN). After every `acf_reload` the addon re-wraps ACF through ACF's own `ACF_OnLoadAddon` hook. If this addon happens to load **after** InfMap has already wrapped entities, the first sight of a wrapped entity is not taken for a replaced wrapper (tested).

## Settings

The menu (Spawn menu, Utilities, ACF InfMap, Settings) shows all of these. **Your settings** are saved on your computer. **Server settings** are changed by a superadmin (the menu sends the change to the server, which checks who sent it and clamps the value); everyone else sees them read-only. Every one is also a plain console variable. 1 metre = 39.37 units; a chunk is 20000 units (508 m).

| Name | Where | Default | Meaning |
|---|---|---|---|
| `acf_infmap_cl_render_fix` | you | 1 | 1 = keep visual clips and Prop2Mesh meshes right in other chunks. 0 = stock behaviour (also switches the context fix off) |
| `acf_infmap_cl_visclip_resync` | you | 1 | 1 = ask the server for the visual clips of props that came into range without any |
| `acf_infmap_cl_visclip_range` | you | 12 | Chunks (1 to 100). A prop this close to you is checked once for missing clips |
| `acf_infmap_cl_render_draw` | you | 1 | 1 = in other chunks, run a scripted entity's own `Draw` / `DrawTranslucent` (lazer beams, glows, overlays). 0 = InfMap's `DrawModel`-only wrapper |
| `acf_infmap_cl_render_bounds` | you | 1 | 1 = shift render boxes that entities in other chunks set in world coordinates back into their own frame. 0 = stock |
| `acf_infmap_cl_shot_report` | you | 1 | 1 = one console line per real shot when its bullet ends |
| `acf_infmap_cl_force_tracer` | you | 0 | 1 = give every real shell a tracer, even if its crate's Tracer is off (diagnostic) |
| `acf_infmap_fix_visclip` | server | 1 | 0 = the server ignores clip requests (stock Visual Clip) |
| `acf_infmap_cl_replay` | you | 1 | 1 = show effects the engine cannot place (replayed from ACF's own effect code). 0 = drop them |
| `acf_infmap_cl_replay_distance` | you | 3000 | Metres. Far effects and far tracers are shown up to this distance from you (0 to 10000) |
| `acf_infmap_cl_replay_scale` | you | 1 | Size multiplier of far particles (0.1 to 5) |
| `acf_infmap_cl_bullets` | you | 1 | 1 = keep bullets alive past the engine's limit and draw their tracers there. 0 = stock |
| `acf_infmap_cl_bullet_draw` | you | 1 | 1 = draw a bullet's model yourself when the engine never does |
| `acf_infmap_verbose` | you | 0 | 1 = print a line for every ACF effect this client receives |
| `acf_infmap_effect_range` | server | 120000 | Units (global distance) within which players are sent an effect. Keep it at least your far distance (3000 m = 118110 units) |
| `acf_infmap_fix_effects` | server | 1 | 0 = stock effect path |
| `acf_infmap_sound_range` | server | 20000 | Units within which players receive ACF sounds |
| `acf_infmap_fix_sounds` | server | 1 | 0 = stock ACF sound routing |
| `acf_infmap_fix_traces` | server | 1 | 0 = stock `ACF.trace` |
| `acf_infmap_bullet_lifetime` | server | 180 | Seconds a bullet may fly; 0 = never remove (stock) |

Each fix has its own switch, so a misbehaving session can be bisected: turn one off, repeat the test. If the render fix raises an error five times it switches itself off and says so once in the console.

## Commands

| Where | Command | Shows |
|---|---|---|
| server + client | `acf_infmap_status` | Which functions are wrapped, counters, settings, bullets in flight, far-effect, render and visual clip state |
| client | `acf_infmap_renderdebug` | The render fix: how many entities it watches, the nearest wrapped ones with their own override, each Prop2Mesh mesh (its local offset from `linkpos`, chunk, override, engine draws), how many meshes are at the wrong position or in another chunk but unwrapped right now, how many props were asked about |
| client | `acf_infmap_entdebug <part of a class name>` | For the nearest entities of that class (try `lazer`): chunk, Draw / DrawTranslucent, render group, InfMap's stored render box and how far off-centre it is, wrapper state, Draw route, engine calls |
| client | `acf_infmap_bullettest [m/s] [tracer] [self] [<n>mm]` | A test shell through ACF's real bullet effect, 300 units ahead, flying along your aim; prints the crate's Tracer value, the caliber used, whether ACF's `Init` accepted it, and after 1 s how often the engine drew it. `self` = do not use a nearby ammo crate; `100mm` = set this shell's caliber. Example: `acf_infmap_bullettest 100 100mm tracer self` |
| client | `acf_infmap_bulletdebug` | The last bullet effects this client received, every bullet it is simulating (with the crate's Tracer value), and **how each bullet that stopped being simulated ended** |
| client | `acf_infmap_fartest [metres]` | A real ACF explosion that far ahead of you (default 1500) |
| client | `acf_infmap_replaydebug` | Far particles live / recorded, effects empty / dropped / errored |
| server (superadmin) | `acf_infmap_sounddebug` | Per player: chunk, global position. Per engine/turret/waterjet: how many players stock ACF would have sent to vs how many this addon sends to |
| client | `acf_infmap_sounddebug_cl` | Your chunk, each engine's chunk, local position, distance, loop state |
| server (superadmin, from your own console) | `acf_infmap_tracedebug [distance]` | Fires a line through **stock** `ACF.trace` and through the **fixed** one and prints both |

## Your next session

1. **Is it running?** Server and client console: `acf_infmap_status`. On the client you should see `render:` with "render boxes converted ... (ready)", a `visclip:` line and a `bullets: shot report ON` line; on the server a `visual clip resync ... ready` line.
2. **The lazers.** Stand in a chunk away from a firing lazer, look at it, and run `acf_infmap_entdebug lazer`. Paste the output if the beam or the lazer is still missing. The line to watch is "InfMap's stored local render box": a centre more than a few thousand units from the lazer means cause 4 is happening in your game (GUESS until then).
3. **The cannon.** Fire five or six real rounds, one at a time, with different ammo if you have it, and paste the `shot #` lines from the console. Then turn the Tracer box on in the ammo menu, **update the crate**, and fire again. If you still see nothing, set `acf_infmap_cl_force_tracer 1` and fire again.
4. **The dupe test** from version 5 is unchanged.

## What was tested, and how

Two harnesses, both kept in my workspace (not in this zip), both running **real** third-party files against a mock of the GMod API.

- **`test_render_compat.lua`** runs the real InfMap files (`sh_inf_functions`, `sh_inf_networking`, `cl_inf_detours`, `cl_inf_chunks`), the real Visual Clip client and server files, the real Prop2Mesh `cl_init.lua` and ACF's real `overrides_cl.lua`, translated from GLua syntax to Lua only (no behaviour change), against an engine model (entities, parenting with the SDK's world-to-local rule, render bounds and culling against the +-16384 box, opaque and translucent passes with or without flags, camera and clip stacks, networked entities and NULL for unknown ones, hooks, timers). Every scenario runs **twice: STOCK (the addons alone) and FIXED (plus this addon)**. The STOCK runs reproduce each root cause from the real code (for example a Prop2Mesh child at engine position (16384, 0, 20) instead of (2050, 0, 20), a lazer three chunks away with no beam, a firing lazer whose cached box is 60000 units off). The lazer is a stand-in written from the draw code in your `cl_init.lua` (model in `Draw`, beam and glow in `DrawTranslucent`, box set in `Think`), not the file itself. **195 checks pass.**
- **`test_acf_infmap_compat.lua`** runs this addon's files with ACF's real traces, ballistics, sounds, effects (`acf_bullet_effect`, `acf_explosion`, `acf_impact`) and loader. It now includes the shot report: what each line contains, the switch, the burst limit, the forced tracer and the test shells. **366 checks pass** (13 of them are version 6.1's test-shell options).
- **Mutation testing:** I broke the addon on purpose and ran the checks against each broken copy: 63 breaks in the render and clip code and 79 in the rest. **All are caught by at least one check, except one break I marked as equivalent** (running the Prop2Mesh sweep before the override guard: since version 5.1 the guard routes wrapped entities itself, so both orders end in the same state in the same frame). Re-running the suites after the version 5.1 edits also showed that six of my own breaks no longer matched the code (they were being skipped, not caught) and that one new check passed only some of the time because two hooks of the same tick have no defined order. I rewrote the breaks and made the check order-independent before counting anything.

What that proves: the logic does what the headers say against the real source of all three addons, in the cases above. What it cannot prove: that real GMod's engine behaves the way the model assumes (list below), that your Workshop versions equal the sources I read, and nothing about how anything looks.

## GUESS list (confirm in game)

Render and clips (new):

1. That the engine converts a world position set on a parented client-side entity to a parent-local one with the parent's real transform (this is what puts the mesh far away; KNOWN as Source SDK behaviour, but the exact numbers in game are not seen). `acf_infmap_renderdebug` prints each mesh's offset from `linkpos`.
2. That `PreRender` runs before the engine draws the entities of the same frame. If not, a repaired entity may be culled for one frame, nothing worse.
3. That clip planes given to `render.PushCustomClipPlane` live in the same world space as the camera set by `cam.Start3D`.
4. That `ents.GetAll()` includes client-side entities (the code does not depend on it).
5. That `GetClass()` already answers inside `OnEntityCreated` on the client (otherwise a new Prop2Mesh entity waits at most half a second for the scan).
6. That the Workshop InfMap, Visual Clip and Prop2Mesh equal the sources I read.
7. That the cannon's missing tracer is the crate's Tracer tick box (the number is now printed).

Earlier versions:

8. That the engine does not place or draw effects and particles outside +-16384 of the chunk centre. If it does, you lose nothing (the replay is only used outside the placeable area).
9. That `render.DrawQuadEasy` / `render.DrawBeam` draw at the shortened positions (within 12000 units of the eye). `acf_infmap_fartest` shows it in five seconds.
10. The particle physics. GMod's exact air-resistance formula is not documented; `DragRate` (0.015) in `cl_replay.lua` is my guess.
11. That a particle created with a negative life time is not drawn until it is born, and that a stretched sprite is drawn from its position back along its direction.
12. That ACF's `Init` runs inside `util.Effect` (the bullet test checks it).
13. That the engine calls a per-instance `Render` function (if it does not, the addon draws a second copy in the same place, which looks the same).
14. That a model on the client can be drawn through `ClientsideModel` plus `DrawModel` in `PostDrawOpaqueRenderables` under InfMap.
15. Who stock `net.SendPAS` reaches for a point outside the real map. The sound fix does not depend on the answer.
16. That a hit on a clone really has no `CPPIGetOwner`, which is why ACF handles it as a World hit.
17. That a trace given an `output` table fills and returns that same table (the addon copies the result when it is not).
18. That 180 s is a good bullet lifetime. High lobbed shells (almost vertical, 1500 m/s) take about 197 s without drag.
19. That the materials ACF names can be loaded with `Material()` at draw time exactly as `ParticleEmitter:Add` loads them.

Version 6:

20. That the engine really skips an entity whose render box is outside the +-16384 world box (InfMap's own comment says so), and that the corrected box is what brings the lazer back. The Draw route (causes 1 to 3) does not depend on this.
21. That `GetRenderBounds` on the client returns what `SetRenderBoundsWS` stored, converted with the entity's raw position (this is what makes the stored box one chunk-difference off).
22. That a Lua call `ent:SetRenderBoundsWS(...)` goes through the `Entity` metatable entry this addon replaced (InfMap's own `GetPos` / `LocalToWorld` detours rely on the same lookup).
23. That the engine sets `STUDIO_DRAWTRANSLUCENTSUBMODELS` (4) in the flags of every translucent-pass draw. The addon does not rely on it: the pass hooks are the other signal, and "opaque" in the flags never overrules them.
24. That your cannon's rounds are simply too fast and too short-lived to notice, or have no tracer because of the crate's Tracer value. The per-shot lines decide.

## Not covered (SEEN unless marked)

- **Why your cannon's bullets are not visible** (see version 6 above): no defect found by reading; every shot now reports the numbers that decide it.
- **A lazer beam that crosses your view while the lazer's body is off-screen** is not drawn (the engine culls with the body's box). Beyond 4 chunks InfMap reduces the box to a single point.
- **Bullets fired from farther than `acf_infmap_effect_range` away** (about 3 km by default) are never sent to you, and a hit from such a bullet shows no impact.
- **Far impact sounds** are played where ACF's trace ends, not at the impact.
- **Far effects with a model or their own shape** (the explosion's refraction sphere) are not shown. Muzzle flashes use the gun entity, not a position, so they are not routed.
- **Far particles are not hidden by terrain** between you and them.
- **ACF code that copies `ACF.trace` into a local variable when it loads** keeps calling the stock function: explosion line-of-sight, missile sensors, optical fuzes, radio and laser guidance, the radar. (You report that lasers work; I did not check why, so I do not know which path they use.)
- **Explosion and burn damage across chunks**: InfMap itself cancels it with an `EntityTakeDamage` hook. Not touched.
- **Client-side traces** (the client's own `util.TraceLine` calls) are not touched. Decals are not made for far effects.
- **`ScreenShake`**, sounds that the server emits itself, and anything outside ACF.
- A piece of a shot that starts so far from the origin that the next chunk cannot be told apart in float32 (beyond about chunk 100000) may skip a sliver of up to 128 units at the border.

## Files

```
lua/autorun/zz_acf_infmap_compat.lua   entry point, install + reload hooks
lua/acf_infmap_compat/sh_core.lua      wrap helper, counters, settings list, status command
lua/acf_infmap_compat/sv_sounds.lua    server sound routing + loop tracking
lua/acf_infmap_compat/cl_sounds.lua    client one-shots for other-chunk entities
lua/acf_infmap_compat/sv_traces.lua    chunk-aware ACF.trace + clone resolution + tracedebug
lua/acf_infmap_compat/sv_bullets.lua   stray bullet cap
lua/acf_infmap_compat/sv_effects.lua   effect messages with exact positions
lua/acf_infmap_compat/sv_settings.lua  server side of the menu (superadmin-only setter)
lua/acf_infmap_compat/sv_visclip.lua   answers clients' "I have this prop but no clips for it" with Visual Clip's own message   (new in 5)
lua/acf_infmap_compat/cl_effects.lua   effect receiver, crate fix, tracer frame shift, bulletdebug
lua/acf_infmap_compat/cl_replay.lua    far effects: records ACF's effect particles and draws them, fartest, replaydebug
lua/acf_infmap_compat/cl_bullets.lua   keep-alive, far tracers, render counter, bullet life log, per-shot report, forced tracer, bullettest   (shot report new in 6)
lua/acf_infmap_compat/cl_render.lua    visual clips, Prop2Mesh and scripted entities (lazers) in other chunks: override guard, chunk context, mesh position, Draw route with pass detection, render box correction, clip resync, renderdebug, entdebug   (new in 5, extended in 6)
lua/acf_infmap_compat/cl_menu.lua      the settings panel
```
