# ACF3 <-> InfMap compatibility (standalone addon), version 7.3

One addon folder. It edits neither ACF, InfMap, Visual Clip nor Prop2Mesh: it wraps their functions at runtime, keeps the originals, and does nothing on maps that are not InfMap maps. Delete the folder and you are back to stock behaviour.

Built for the **original InfMap** (meetric1's "Infinite Map Base", the Workshop one, `chunk_size = 10000`) and ACF-3 master.

Labels used everywhere (here and in the headers of every `.lua` file):

- **SEEN** = read in the real source, or run in the test harness against the real files.
- **KNOWN** = standard GMod / Source behaviour that I did not re-check.
- **GUESS** = inference. Only a real game can confirm it.

## What changed in version 7.3 (ACF entities in other chunks were drawn too far away: the engine origin)

**Your finding:** a lazer in another chunk is drawn twice as far away as a gun, so it "disappears across borders".

**What I did not do: halve the offset.** Halving fixes one number for one situation. The offset the lazer is drawn with is the real chunk difference plus a second, stale copy of a chunk difference (cause below); halving is right only while the two are equal, goes wrong as soon as you walk to another chunk (the stale copy was made for the chunk you stood in earlier), and would shift every entity that is already drawn correctly. The fix removes the extra copy instead.

**The cause (each step SEEN in the real source; what the engine does with it is GUESS where marked):**

1. ACF's scalable base (`entities/base_scalable/cl_init.lua`), which every ACF gun, lazer, crate and engine inherits from, defines `ENT:CalcAbsolutePosition()` as `local Position = self:GetPos() ... return Position, Angles`. The GMod wiki says this hook "lets you adjust the position and angles the engine uses for an entity" and is "called whenever the entity's position changes": what it returns is kept as the entity's origin (GUESS that the engine really does this for these entities).
2. InfMap detours `Entity:GetPos` on the client (`cl_inf_detours.lua`). For an entity in another chunk it does not return the engine's position but that position **plus the chunk difference** (the position in your chunk's frame).
3. So the engine is handed "raw position + chunk difference" and stores that as the origin.
4. InfMap then draws an entity of another chunk through a camera moved by the chunk difference (`cl_inf_chunks.lua`), because it expects the origin to be the raw position. The model, the beam (drawn from `LocalToWorld`), the wires and the render box InfMap shrinks around the origin all land **two** chunk differences away: "moved twice as far". The stored origin also goes stale whenever you change chunk.

**The fix (`cl_origin.lua`, new):** while `CalcAbsolutePosition` runs for an entity in another chunk, your `CHUNK_OFFSET` is set to the entity's own (the same trick `cl_render.lua` uses for draw functions), so InfMap's `GetPos` answers in the entity's frame, which is what the function gets on a map without InfMap. The value is put back afterwards, also after an error. In your own chunk the original runs untouched. The class tables that define the function and the entities that already exist are wrapped, and a once-a-second scan wraps classes that are registered again. Nothing in ACF or InfMap is edited.

**What I could not find out (GUESS): why a lazer and not a gun.** Both inherit the same function. What differs must be *when* the engine recalculates the position (while you stand in another chunk, or before the chunk is known). Candidates: the lazer thinks on every server tick and is always transmitted (`TRANSMIT_ALWAYS`), so its position is rewritten more often. Only a game can tell. The fix does not depend on the answer.

**How to check it in the game:** `acf_infmap_entdebug acf_lazer` and `acf_infmap_entdebug acf_gun` now print a line per entity: `CalcAbsolutePosition: yes, wrapped by this addon. Engine position vs networked position: the same (within N units)` or `DIFFERENT by X Y Z units = a b c chunks. The entity is drawn that far from where it is.` A lazer that was off by a chunk difference before the fix shows the difference in whole chunks. **If both lines say "the same" and the lazer is still drawn too far, the cause is somewhere else: paste the output and I will look again.**

**Settings and status:** `acf_infmap_cl_origin_fix` (you, default 1; 0 = stock). `acf_infmap_status` on the client shows `engine origin (ENT:CalcAbsolutePosition)  wrapped (N class table(s), M entities)` and a line `origin: fix ON, ..., K call(s) answered in the entity's own frame, errors E`. K counts only the calls for entities in another chunk.

**Not covered:** an entity whose origin was stored wrong **before** this file wrapped the function (a Lua refresh while you stand in another chunk) stays wrong until the server moves it or you reconnect. At a normal start the wrapper exists before any entity does.

## What changed in version 7.2 (E2 rangers see props in other chunks; small-caliber bullets live 20 s)

**1. E2 rangers (`ranger`, `rangerAngle`, `rangerOffset` and the hull versions).**

**Your problem:** 7.1 fixed the camera controller's `HitPos`, but the hologram still went to the wrong spot because the hologram's position comes from an E2 ranger, not from the controller's output.

**The cause (SEEN, read in Wire's and InfMap's source):** the same as in 7.1. Every E2 ranger function ends in the file-local `ranger()` of `core/ranger.lua`, which makes **one** `util.TraceLine` (or `util.TraceHull`) from the chip's side. Under InfMap that call is InfMap's detour (`modify_trace_data`): the line is moved into the chunk it starts in and only entities of that chunk can be hit. A ranger from the camera to a prop two chunks away passes through the prop, and `R:pos()` is the far end of the line.

**Why the fix sits where it does (SEEN):** the E2 compiler reads `wire_expression2_funcs[signature][3]` while it compiles a chip and keeps that function (`base/compiler.lua`, `GetFunction`: `op = fn[3]`). So this addon replaces that field, for every ranger function, before any chip compiles. (`ranger()` itself is a file-local function; changing it would need `debug.setupvalue`, which LuaJIT may not honour in code it has already compiled, GUESS. The registry entry is public API.) E2 runs the hook `Expression2_PostLoadExtensions` after it has loaded and after every `wire_expression2_reload`, with the registry filled; the addon wraps again there, so an E2 reload never loses the fix.

**What 7.2 does (`sv_e2ranger.lua`, `sv_traces.lua`):**

- Wraps every ranger function that E2 registers: `ranger` (3 forms), `rangerAngle`, `rangerOffset` (2), `rangerHull` (4), `rangerAngleHull` (2) and `rangerOffsetHull` (5, one of them the entity form): **17 signatures** (SEEN: counted in Wire's `core/ranger.lua`, and a check compares the six names the addon wraps with the file's). Names are matched, not signatures, so a signature Wire adds later under one of these names is covered; a new name is not.
- While one of them runs, `util.TraceLine` and `util.TraceHull` are replaced by functions that give the trace to `Compat.TraceFar` (the helper 7.1 added): the line is cut to `E2Ranger.MaxDistance` (default **5000 m**, about 10 chunks), traced **chunk by chunk**, a hit on an `infmap_clone` becomes a hit on the real prop (unless that prop is on the ranger's filter, then the clone is skipped). A hull ranger keeps its size in every piece. Both functions are put back when the ranger function returns, **also when it throws**, and the error value reaches the chip unchanged. Every other trace made at any other time is the stock one.
- A ranger that stays inside one chunk costs one extra function call and a few comparisons; the engine is called once, as before.
- Water plus entities (two traces with different masks) and `rangerDefaultZero` work as before, because Wire's own code runs around the replaced traces.

**What changes for your scripts (SEEN in the code and the tests):**

- A ranger that hits nothing now ends at `MaxDistance`, not wherever the chip pointed it. So `R:position()` of a miss is that end point and `R:distance()` of a miss is at most `MaxDistance` (a `rangerOffset(from, vec(1e9,0,0))` is cut at 5000 m). `Fraction` and `StartPos` refer to the cut line (Fraction 1 on a miss). Wire's `RealStartPos` is still set.
- `E2Ranger` in `config.lua` (`Enabled`, `MaxDistance` in metres, ceiling 50 km). `Enabled = false` or `acf_infmap_fix_traces 0` gives stock behaviour. `acf_infmap_config_reload` prints `E2 rangers: traces reach 5000 m (10 chunks)`.
- `acf_infmap_status` on the server has a line `e2 rangers: fix ON, reach 5000 m, 17 of 17 ranger function(s) use it, K trace(s) done so far`.
- **A chip that was uploaded before this addon was installed keeps the stock function until it is uploaded again** (or `wire_expression2_reload` is run). At a normal server start the addon is installed before any chip exists, so this only matters when you add the addon to a server that is already running.

**What this does NOT fix:**

- `rangerOffsetHull(entity, from, to)` (uses `util.TraceEntity`), `entity:eyeTrace()` and `eyeTraceCursor()` (the engine's own player trace), the Wire ranger entity (`gmod_wire_ranger`) and `gmod_wire_user`.
- Terrain in a chunk that holds nothing solid (same limit as in 7.1, read it there): a ranger over empty ground in an empty chunk still misses. A prop in that chunk makes the terrain there hit-able.
- **Found while reading, not changed:** `rangerWhitelist(1)` with `rangerFilter(...)` does not work as a whitelist under InfMap, with or without this addon. InfMap's detour turns a table filter into an exclusion list and never looks at the `whitelist` flag (SEEN, `sv_inf_detours.lua`, `modify_trace_data`; GUESS how the engine treats the flag together with a function filter). If your scripts use the whitelist mode, say so and I will look at it.

**Tests:** Wire's real `ResetRanger`, `addDefaultEntityToFilter`, `entitiesAndWaterTrace` and `ranger` are cut out of `core/ranger.lua` (the file from Wire's GitHub master) and run in the mock under the real InfMap trace detour port; the E2 functions of the test are written like the real file's (`return ranger(self, 2, 0, from, to)` and the others) and registered in a registry laid out like Wire's `registerFunction` makes it (11 of the 17 signatures, at least one of every name and of every kind: the test does not write the other six). STOCK: a ranger two chunks across passes through the prop with one engine trace. FIXED: each of those 11 hits the prop's near face; hull rangers use only `util.TraceHull` with their size in every piece and line rangers only `util.TraceLine`; the entity form still uses `util.TraceEntity` as Wire wrote it; water plus entities; a nearer prop in the chip's own chunk wins; `rangerFilter` is honoured; a hit on a clone gives the real prop and a clone of a filtered prop is skipped; a miss ends at 5000 m with about one engine trace per chunk (also for hulls); a ranger inside one chunk costs one engine trace; `rangerDefaultZero`; the config distance, ceiling and switches; an error (a table, like `self:throw` makes, and a Lua error) reaches the chip unchanged and puts both traces back, and the next call works; a ranger called inside another keeps the replacement for the outer one; a trace made outside a ranger call is the stock one; Install again and again never stacks wrappers; an E2 reload (a fresh registry) is re-wrapped by the hook; registry entries without a function or not tables are skipped; Expression 2 missing; Expression 2 without the ranger extension; a chip that kept the function from before the install; the config reader and the reload report. **504 checks pass** in total (430 in 7.1). Mutation testing: 52 deliberately broken copies of the new code (including the 20 s change put back to 60 and to 21). 48 were caught at once. 4 survived: a line trace sent to the hull function (the mock treats both alike until a check looks at which one was called), a hull ranger whose reach was ignored, a status line that counted every function as wrapped, and one change that renames the table key of the status line, which changes no behaviour (equivalent). I wrote the three missing checks and they are now caught: 51 of 52 are caught, the 52nd is the equivalent one.

**2. Small-caliber bullets live 20 s instead of 60 s** (`SmallSeconds` in `config.lua` and the built-in default).

- Up to 40 mm: **20 s**. From 70 mm: 150 s. In between a straight line: 41 mm = 24.3 s, 55 mm = **85 s**, 70 mm = 150 s. 13.2 mm machineguns, 20 mm and 30 mm autocannons: 20 s. 85 mm, 120 mm, 155 mm and mortars: 150 s. Edit `config.lua` to change any of it; `acf_infmap_config_reload` prints the table.
- By arithmetic (not a measurement), a gun firing 600 rounds a minute that hits nothing now keeps at most about 200 bullets alive (10 per second times 20 s); at 60 s it was 600 and at the old 180 s about 1800.
- **A side effect to know about (SEEN in ACF's code, no message is sent when the server removes a bullet):** ACF's client ends a bullet picture only after 45 s (`effects/acf_bullet_effect.lua`), and `RemoveBullet` sends the client nothing (`ballistics_sv.lua`). So a small-caliber tracer can keep flying on your screen for up to 25 s after the server dropped the bullet. It does no damage, and it is already out of sight in practice: the client stops drawing a bullet beyond `acf_infmap_cl_replay_distance` (3000 m by default, SEEN in your 6.7.1 paste), and a 600 m/s bullet is 3000 m away after 5 s. If you ever see tracers hanging in the air, that is this.
- Bullets already in the air when the server is changed keep the time they were given.

**Not tested in the game yet (GUESS):** item 35 (nothing else caches the E2 ranger functions), item 36 (the registry replacement reaches chips compiled after the install in the real E2, not only in the mock), item 37 (the engine accepts hull pieces that start where the previous one ended; the same assumption as item 33), item 38 (your hologram script uses the ranger functions listed above and not `eyeTrace()`).

## What changed in version 7.1 (Wire camera controller: HitPos and Trace see props in other chunks)

**Your problem:** the hologram that shows the camera controller's HitPos passes through things in other chunks.

**The cause (SEEN, read in Wire's and InfMap's source):**

1. The controller computes `HitPos` and the `Trace` output in `ENT:UpdateOutputs` (every 0.1 s while a player is in the camera) with **one call**: `util.TraceLine({start = curpos, endpos = curpos + curang:Forward() * 999999999, filter = self.Entities})`.
2. Under InfMap that call is InfMap's detour (`modify_trace_data`, `sv_inf_detours.lua`). It moves the line into the chunk it **starts** in and lets the engine see only entities whose `CHUNK_OFFSET` is that chunk. So the line passes through every prop in the next chunks, and a line that hits nothing ends 999999999 units away. A hologram placed at HitPos then shows nothing or sits somewhere meaningless.
3. The line is a billion units long, so it cannot just be cut at chunk borders (50 000 of them). The fix has to cut it to a sensible length first.
4. `ACF.trace` is not involved (Wire calls `util.TraceLine` directly), so the bullet trace fix of version 3 did not help.

**What 7.1 does (`sv_wire.lua`, `sv_traces.lua`):**

- Wraps `ENT:UpdateOutputs` of `gmod_wire_cameracontroller`. While it runs, `util.TraceLine` is replaced by a function that treats **one** call differently: the call whose `filter` is the controller's own `self.Entities` table, i.e. the aim line. Every other `util.TraceLine` call made in that time (an E2 chip that reacts to the HitPos output and traces by itself, say) goes to the previous function untouched. `util.TraceLine` is put back when `UpdateOutputs` returns, even if it errors.
- That one call is cut to `WireCamera.MaxDistance` (default **5000 m**, about 10 chunks) and traced **chunk by chunk** with the same piece tracing the bullets use: each piece in its own chunk, first hit wins, a hit on an `infmap_clone` becomes a hit on the real prop (unless the real prop is part of the camera's contraption, then the clone is skipped). Up to 3 pieces per chunk of reach (limit 64); a diagonal line through chunk corners needs fewer.
- Controllers that already exist are patched as well as the class (see the GUESS list, item 31).

**What changes for your scripts (SEEN in the code and the tests):**

- A line that hits nothing now ends at `MaxDistance` (5000 m by default), not 999999999 units away. HitPos of a miss is that end point. Raise or lower the distance in `config.lua`, `WireCamera.MaxDistance` (metres; values above about 50 km count as 50 km).
- The `Trace` output's `Fraction` and `StartPos` refer to the cut line (Fraction 1 on a miss). Wire's own `RealStartPos` is still set.
- `Enabled = false` in the `WireCamera` section of `config.lua`, or `acf_infmap_fix_traces 0`, gives stock Wire behaviour again.
- `acf_infmap_status` on the server has a line `wire camera: fix ON, reach 5000 m, N of M controller(s) use it, K trace(s) done so far`. `acf_infmap_config_reload` reads `config.lua` again (both sections) and prints what each says.

**What this does NOT fix (SEEN in InfMap's source) - read this, it decides whether your indicator is right everywhere:** InfMap's terrain collision (`infmap_terrain_collider`) only exists in chunks that **contain at least one solid entity** (`sv_terrain_collision.lua` creates it when an entity enters a chunk and removes it when the chunk is empty). A line that crosses an **empty chunk** has nothing to hit there, so it still passes through the ground in empty chunks. With 7.1 the line hits props and terrain in chunks that have something in them, and goes through the terrain of chunks that have nothing. If that is your next symptom, the way out is a software trace against `InfMap.height_function` (it is a shared function; InfMap's own E2 extension uses it) for chunks without a collider. I have not written that; it is a separate piece of work and I would test it before offering it.

Other things left alone: AutoUnclip's hull trace (it starts and ends next to the camera), the client's own camera movement, `gmod_wire_ranger` and `gmod_wire_user` (they also call `util.TraceLine`; a ranger is short, its default range is 1500 units, so it only fails near a border; the same helper (`Compat.TraceFar`) can be applied to them), and E2 rangers (done in 7.2).

**Config reader (`sv_config.lua`):** `config.lua` has two sections in 7.1 (`BulletLifetime`, `WireCamera`; 7.2 adds `E2Ranger`) and one reader for both. A section that is missing takes its built-in values without a message (so a `config.lua` from 7.0 still works); a key that is not a setting (a typo) or a section that does not exist is reported and ignored; the rest of the checks are as in 7.0.

**Tests:** Wire's real `doRotate` and `UpdateOutputs` are cut out of `gmod_wire_cameracontroller.lua` (the file from Wire's GitHub master) and run in the mock under the real InfMap trace detour port. STOCK: HitPos is about 1e9 units away and the prop two chunks out is missed. FIXED: HitPos is on the prop's near face, the Trace output names the prop; a nearer prop in the camera's own chunk wins; the contraption's own props are ignored; a hit on a clone gives the real prop and a clone of a contraption prop is skipped; a diagonal line across two axes; a miss ends at 5000 m with about one engine trace per chunk (10, 8 along the 45-degree diagonal, at most 34 at other angles); a prop beyond the reach is not hit, one inside is; the three config switches; a trace made by another script while the outputs trigger is left alone (including one with no filter while the controller's own filter table is nil); an error inside the outputs puts `util.TraceLine` back; an entity that looks the function up in the class, one that holds its own copy, one that holds someone else's function, and one created later; Wire missing; Wire without `UpdateOutputs`; `TraceFar` on its own (cut copy, output table, Fraction, non-trace data, a line across borders on three axes). **430 checks pass** in total. Mutation testing: 61 deliberately broken copies of the new code; 54 were caught at once, 7 survived and showed missing tests (the InitPostEntity install, the status count, the output table of a cut line, the built-in values of a new section, the report built from a given table, the Enabled = false report); I wrote those tests and all 7 are now caught.

**Not tested in the game yet (GUESS):** item 31 (existing controllers hold their own copy of the function), item 32 (what the engine does with the stock billion-unit line), item 33 (that the engine accepts a trace piece that starts exactly where the previous one ended; the same assumption the bullet trace has made since version 3).

## What changed in version 7.0 (bullet lifetime by caliber in an editable file; the diagnostics that ran on every shot are gone)

**1. Bullets are removed after a time that depends on their caliber, and you set the numbers in a file.**

Open `lua/acf_infmap_compat/config.lua` (server side only, never sent to players):

```lua
BulletLifetime = {
	Enabled      = true,
	SmallCaliber = 40,   -- millimetres
	SmallSeconds = 20,   -- a bullet of this caliber or smaller may fly 20 s (7.0 shipped 60; 7.2 lowered it)
	LargeCaliber = 70,   -- millimetres, must be bigger than SmallCaliber
	LargeSeconds = 150,  -- a bullet of this caliber or bigger may fly 150 s (2.5 min)
},
```

- Up to 40 mm: 20 s (7.0 shipped 60 s). From 70 mm: 150 s. In between a straight line: 55 mm = 85 s, 41 mm = 24.3 s. A 13.2 mm machinegun, 20 mm and 30 mm autocannons: 20 s. 85 mm, 120 mm, 155 mm and mortars: 150 s.
- The caliber is the **bullet's own** caliber, which for a gun's shell is the gun's caliber. SEEN in ACF's source: `Bullet.Caliber` is in centimetres (13.2 mm = 1.32; the ammo crate shows `Caliber * 10` as millimetres; the trace code's `Caliber < 3` means "under 30 mm"), and the addon multiplies by 10 before it compares with your millimetre numbers. Fragments made by spalling carry their small fragment size, so they get the short time.
- The time is worked out **once**, when ACF first steps the bullet, and stored on the bullet (`InfMapDie`). After that each step compares one number. Bullets that handle their own iteration (missiles) are not touched. A bullet past its time is removed with ACF's own `RemoveBullet`, with no effect message.
- **After editing:** restart the server or change the map, **or** type `acf_infmap_config_reload` in the server console (or as a superadmin in your own console). It re-reads the file and prints what each caliber now gets. Bullets already in the air keep the time they were given.
- **A mistake in the file never stops the addon.** A value that is missing, not a number, negative, zero, NaN or infinite takes the built-in value (the numbers above) and the server console says which one. `LargeCaliber` not above `SmallCaliber` puts both calibers back to 40 and 70. A typing mistake that stops the file from running at all prints the error and uses the built-in numbers. `Enabled = false` turns the removal off completely (stock ACF behaviour).
- The old server setting `acf_infmap_bullet_lifetime` (one number, 180 s for every caliber) and its menu row are **gone**; the menu has a line saying the lifetime is in `config.lua`.

**What this does not do (SEEN in ACF's client code, `effects/acf_bullet_effect.lua`):** ACF's own client code ends the picture of every bullet after **45 s** (its `Think`), whatever the server does. So a mortar shell that flies longer than 45 s is still simulated and still damages on the server (up to the 150 s above), but the tracer and the impact effect on your screen are already gone: the hit message finds no bullet to update. That limit is in ACF, not in this addon; I did not change it. A time that depends on the shell's velocity instead of its caliber (your idea) is also not done; it would be the next step if the caliber rule proves too coarse.

**2. Everything that ran per shot for diagnosis is removed**, to cut compute:

- Server: the ring that recorded every new shell (`Bullet.Crate`, who fired it, what the gun's crate was), the wrapper around `Ballistics.BulletClient`, the record of every crate number sent in an effect, and their commands `acf_infmap_cratesv`, `acf_infmap_bulletsv`, `acf_infmap_fire` (the command that fired a real round).
- Client: the per-bullet life log, the per-shot console line, the per-frame draw fallback for the bullet model (the engine draws it; SEEN in your 6.7 paste), the forced-tracer switch, the per-effect verbose line, the checks that compared the crate ACF held with the crate the server named (`CrateMismatch`, `EffectDataStale`, `EntityFixed`, `EntityMissing`, `BulletNoCrate`, `BulletRefused`, and the ones behind them), and the commands `acf_infmap_cratedebug`, `acf_infmap_bulletdebug`, `acf_infmap_bullettest`.
- Convars removed: `acf_infmap_cl_shot_report`, `acf_infmap_cl_force_tracer`, `acf_infmap_cl_bullet_draw`, `acf_infmap_verbose`, `acf_infmap_bullet_lifetime`. Their menu rows and the six test and debug buttons in the menu are gone too. Saved values of these convars are simply ignored.
- What stays on the shot path, because it is the fix itself and not diagnosis: the chunk-aware `ACF.trace`, the effect message with exact positions, the blanking of every client `EffectData` and the explicit crate (`FreshEffect` / `FixEntity`, the 6.7 fix you confirmed), the client bullet wrapper (keep-alive and far tracer), and the new lifetime check.
- On the client nothing runs per bullet per frame or per tick. A bullet is touched when it is created, once more on the next tick (another addon's hook for the same event may run after ours), and, beyond the 16000-unit window, when ACF moves it.
- Two things you may still read as "error tracking" on the shot path, left in on purpose: (a) `ACF.trace` runs ACF's trace under a `pcall` so that `util.TraceLine` is put back even if something throws (without it a single error would leave every later trace on the server running through this addon's replacement); the same pattern wraps `net.SendPAS` in the sound code and the stock effect fallback; (b) a few counters (`Swapped`, `Skipped`, `Split`, `OutputCopied`, `EffectsSent`, `EffectsShown`, `Killed`, `BulletsKeptAlive`) are plain additions that `acf_infmap_status` prints. Both cost almost nothing (KNOWN, not measured). Say so if you want them out too.
- `acf_infmap_status` still works. It prints the lifetime numbers in use on the server (`bullets: lifetime 20 s up to 40 mm, 150 s from 70 mm (config.lua), N in flight now, K removed by it so far`).

**The shell fix is unchanged** (6.7: every client `EffectData` is blanked, the crate is set explicitly). The receiver is now shorter; it no longer reports staleness or mismatches. If tracers or HE explosions disappear again after 7.0, tell me: the old 6.7.1 zip still has all the reports.

Tests: the suite shrank because the removed features' tests went with them, and 60 new or reworded checks cover the lifetime (13.2, 20, 30, 40, 41, 55, 70, 85, 120, 155 mm; both boundaries; no caliber; the stamp is made once; half a second before death the bullet lives, after it it is removed; a 120 mm shell is alive at 100 s and gone after 150 s; `Enabled = false`; missiles are never capped), the config reader (every kind of bad value, equal and reversed calibers, a file that fails to run, a file that sets nothing, a failing file never keeps the numbers of the file before it), the reload command (permission, the table it prints, a changed file is picked up), the client bullet wrapper (own wrapper never stacked) and the crate fix (index 0 is the world and is never taken as the crate). **358 checks pass.** Mutation testing: 57 deliberately broken copies of the new code. 53 are caught by at least one check. 4 are equivalent changes that cannot be caught: `<` for `<=` at the two caliber boundaries (the straight line gives the same seconds exactly at the boundary), allowing NaN in the number test (`NaN > 0` is false in Lua, so it is refused anyway), and skipping the "do not set a field twice" shortcut in the blanking (only saves a call). Six breaks first survived and showed missing tests (zero seconds, a stale config after a failed file, the reload not re-reading the file, own-wrapper stacking, the neutral entity value, the index-0 check); I wrote the tests and they are now caught. The mock `SetEntity` now throws on anything that is not an entity, like the real binding (KNOWN), which is what made the neutral-entity break visible.

**Not tested in the game yet (GUESS):** that `include("acf_infmap_compat/config.lua")` run from the console command re-reads the edited file from disk and does not return a cached copy (if it does, the file takes effect on the next restart, and the command prints the old numbers: compare them with your file); that machinegun fire in your server no longer builds up bullets as fast. By arithmetic (not a measurement) a gun firing 600 rounds a minute that hits nothing kept at most about 600 bullets alive at 60 s (7.0), where the old 180 s allowed about 1800 (7.2: about 200 at 20 s); one gun can still hold hundreds of bullets, so if your client still lerps, lower `SmallSeconds` in `config.lua`. Check `acf_infmap_status` on the server after a minute of firing: "N in flight now".

**Older sections below describe commands that no longer exist** (`cratesv`, `cratedebug`, `bulletsv`, `bullettest`, `bulletdebug`, `fire`) and counters that were removed; they stay as the history of how the shell bug was found.

## What changed in version 6.7.1 (console lines that were too long for the game; plus what the 6.7 play-test showed)

**6.7 worked (SEEN, your paste):** every `shot #` line now says `crate = acf_ammo #210` / `#194` / `#225` with 9 or 10 networked values, the right drag (0.0044 for the MG, 0.00099 for the 85 mm AP, 0.00041 for the HE), real speeds (601 m/s, 252 m/s, 365 m/s) and `Tracer box ON`; you saw tracers, bullets and HE explosions, and no "wrong ammo crate" line appeared. The washing machine took AP and HE damage (your observation; HE damage was backburnered, this is the first sign it works, I did not test it).

**The engine guess is confirmed in part (SEEN):** the console printed "The game gave this addon an EffectData that was not empty (it still held: Normal, Origin, Scale)". So the game hands out an `EffectData` that still holds an earlier effect's values. This line lists the first time only; it does not show which earlier effect left them (ACF's own impact and explosion effects set exactly Origin, Normal and Scale). That the leftover entity was the gun is still the explanation for the 6.6 logs, not something this line shows.

**A bug in my status command, found in the same paste:** `DLL_MessageEnd: Refusing to send user message TextMsg of 256 bytes to client, user message size limit is 255 bytes`. `Player:PrintMessage` is one user message, and a longer one is dropped, not cut. The server's `acf_infmap_status` printed `counters:` as one line (411 bytes even with every counter at 0), so that line never reached your console (it was missing from the paste). It is not new in 6.7: it has been that long since the counters list passed ~250 bytes. Fix: every line a command prints to a player now goes through `Compat.Tell`, which sends it in pieces of at most 200 bytes, cut at a space or comma when there is one and never inside a UTF-8 character; the last piece carries the newline. All commands that print to a player use it (`acf_infmap_status`, `cratesv`, `bulletsv`, `fire`, `tracedebug`, `sounddebug`). Client-side output was never limited.

Reading the shot lines you pasted (SEEN): the shells that end with `range - it was 3000 m from your eye, beyond the far distance of 3000 m` are not removed from the game. The server keeps flying them; only the client stops drawing them at `acf_infmap_cl_replay_distance` (default 3000 m, up to 10000). The 84 m/s shells that lived 36 s are MG shells that slowed down from 601 m/s by drag over 3000 m.

Tests: 11 new checks (the server status delivers the counters line in full, the mock drops any message over 255 bytes like the game, the pieces rejoin to the original, no word is cut, no UTF-8 character is cut, a very long gun name in `cratesv`); 9 of 9 deliberately broken variants of the new code fail them. The mock now refuses over-long messages, so the same bug cannot come back unnoticed.

## What changed in version 6.7 (the cause: the shell's "crate" was the gun that fired it; every effect the client builds is now blanked first)

What the 6.6 play-test showed (SEEN, all in your pastes):

- **Server**: `acf_infmap_cratesv` on the fresh vehicle: every shell says `Bullet.Crate = 252 = acf_ammo #252 on the server | sent: 252 | fired by acf_gun #187 | that gun's current crate: acf_ammo #252 | fine`. The number is right at the source and right in the message.
- **Client**: `acf_infmap_cratedebug` resolves #252 to the right `acf_ammo` (AP, caliber 1.32, DragCoef 0.0044, Tracer 0.2). The client knows the crate.
- **And yet** every `shot #` line of the MG says `crate = acf_gun #186 with 5 networked value(s)`, `Tracer box OFF`, `drag 1 (the crate reports none)`, and speeds from 1 000 000 to 800 000 000 m/s (48 lines of 48). The effect ACF made held the **firing gun** as its ammo crate. A gun has no `Tracer`, `DragCoef` or `FillerMass`, so ACF used its defaults: no tracer, drag 1 (its own step then flips the velocity and the shell flies off), `AmmoType` "AP" and `FillerMass` 0. That last pair is why **the HE shells showed only the generic impact and no explosion**: ACF's HE impact draws `ACF_Explosion` sized from the filler mass, and from the gun's data the filler is 0 and the type is AP.
- The server's ring alternates shells that name a crate with shells that name **none** (`Bullet.Crate = nil`, drag 0.0137), and the client's `shot #` lines are gun-crates in 48 of 48 cases, so the shells sent without any crate held the gun too (GUESS about which line is which ring entry: the lines carry ACF's shell number, which cycles). A crate that was never sent cannot be looked up wrongly, so the gun did not come from the number.

**The cause (SEEN in the code, the mechanism of the engine is a GUESS):** ACF sends the muzzle flash first (`Entity = gun`), then the shell (`EntIndex = crate`). This addon builds the client's effect with `EffectData()` and sets only the fields the server sent. A field it does not set keeps whatever that object held. So the shell's `EffectData` still held the gun from the flash. My own `FixEntity` then made it worse: it asked "does `GetEntity()` already return a valid entity?" and, finding the gun, concluded the crate was already set and **left it alone**. The version 5 note in `cl_bullets.lua` ("the engine DOES resolve `SetEntIndex`, the fix is only a fallback", `EntityFixed=0`) read that same leftover gun as success. That reading was wrong; the counter stayed at 0 because the gun was always there.

What 6.7 does (`cl_effects.lua`):

- **Every EffectData is blanked first** (`FreshEffect`): all 16 fields are set to their neutral value (0, a zero vector, a zero angle, no entity), then the fields the server sent are applied. Nothing is read from a field this addon did not set. `acf_infmap_bullettest` uses the same blanking.
- **The crate is set only when `GetEntity()` returns exactly the entity the server named**; any other valid entity (a leftover) is replaced by `Entity(EntIndex)`. An engine on which `SetEntity(NULL)` does not clear is covered by the same rule (tested).
- **A shell the server sent with no crate** (`Bullet.Crate = nil`, the ricochet-looking shells in your ring) now holds no entity, so ACF's `Init` refuses it, as stock ACF does. SEEN: `Init` returns when the crate is not valid. These shells were drawn before, as gun-shells, with drag 1: they were the ghosts that flew off. They are counted as `BulletNoCrate`, not as errors. What they are (ricochets or fragments, GUESS) is unchanged by this.
- **If the fix does not work, it says so.** After a new shell is created, the addon checks that ACF holds the crate the server named. If not: counter `CrateMismatch` and one console line "A new shell (#n) was given the wrong ammo crate by ACF: the server named entity #…, ACF holds …". The `shot #` line now says `(NOT an ammo crate: the server named #252)` or `(the server named #252)` instead of the misleading "the index the server sent now belongs to another entity here" of 6.4 to 6.6 (the server sent the right index; the old wording blamed the wrong thing).
- **It also tells you whether the GUESS about the engine is right.** The first time the game hands this addon an EffectData that is not empty, it prints once "The game gave this addon an EffectData that was not empty (it still held: Entity (acf_gun #187), Attachment, Origin, ...)" and counts `EffectDataStale`. If you never see that line and `EffectDataStale=0`, the engine gives a new object each time and the cause was elsewhere (then `CrateMismatch` would still be the thing to look at).

What should change in your game: the MG and cannon shells have their tracer (if the crate's Tracer box is on), the right drag (the `shot #` lines show `drag 0.0044` for the 13.2 mm and no `TOO HIGH`), real speeds, and the HE shell shows its explosion at the hit. Shells with no crate are not drawn.

Not changed: ACF's own client effects (muzzle flash, impact, explosion) are made by ACF's code with its own `EffectData()` and are not blanked. If the engine really recycles one object, ACF has that quirk on its own; an effect that sets all the fields it reads is not affected.

Tests: 31 new checks (the stale gun is replaced by the named crate; the shell then has the crate's drag, tracer, filler mass and ammo type; the HE hit makes an explosion sized from the filler; a shell with no crate is not turned into a gun-shell; an unknown crate does not fall back to the gun; fields the server did not send are neutral; a failing setter does not break the receiver; an engine that ignores `SetEntity`, or `SetEntity(NULL)`, is handled or reported; another ammo crate in the gun's place is reported with the named one; a new object per call gives the same result and no stale report). One check models the guess without this addon and shows ACF's real `Init` taking the gun. 22 of 22 deliberately broken variants of the new code fail at least one check.

## What changed in version 6.6 (a command that fires a real round)

Play-test of 6.5, on a freshly spawned vehicle (guns #166, #246, #225; the earlier test had #207, #270, #293): `acf_infmap_cratesv` shows every shell naming the right crate (`Bullet.Crate = 221 = acf_ammo #221`, sent unchanged, fired by acf_gun #166 whose current crate is #221, verdict `fine`), with the right data on the server (13.2mm AP: `DragCoef` 0.0044). **So on this vehicle the server side is correct.** Why the vehicle of the 6.4 test produced shells naming an `acf_gun` and an E2 chip is still unexplained: the server record did not exist yet, so only the client side was seen. The record stays in, so if it happens again `acf_infmap_cratesv` shows where the wrong number is made.

The test shells of `acf_infmap_bullettest` and `acf_infmap_bulletsv` have no damage on purpose: they only call the client's (and ACF's `BulletClient`) picture code, the server never simulates them (SEEN in `cl_bullets.lua` and `sv_bullets.lua`).

- **`acf_infmap_fire [m/s] [crate=<entity index>]`** (console, superadmin; menu button): fires a **real** ACF round from the nearest ammo crate within 5000 units, or the crate with that entity index, 60 units in front of your eye along your aim. The crate's `BulletData` is copied (type, caliber, drag, tracer and muzzle velocity are the crate's, as for a gun loaded from it), the owner is you, the crate is the "gun" (the pattern ACF's cooking-off crates use), and the ammo type's own `Create` is called. The default speed is the crate's muzzle velocity; a number replaces it (1 to 4000 m/s). No ammo is used. The server traces it across chunks, it hits things and does damage as you, and the client gets the normal shell messages, so the `shot #` line and the shell record cover it too.
- A caliber other than the crate's is not possible with a real round (the caliber is the crate's); use the crate you want, `crate=<index>` from `acf_infmap_cratesv`.
- GUESS: that every ammo type's `Create` accepts the crate as its "gun". AP, HE, HEAT and GLATGM do in the source; flechette and flare rounds were not run.

Tests: 23 new checks (the round exists in ACF's own table with the right owner, filter, speed and position; it leaves the crate's shared table alone; it crosses the chunk border in the harness and hits a prop there; options, limits, refusals, permissions); 16 of 16 deliberately broken variants of the new code fail them.

## What changed in version 6.5 (the cause is narrowed down: the shells name the wrong entity; this version records who sends the wrong number)

Play-test of 6.4, what the console showed (SEEN, not guessed):

- **Server (`acf_infmap_cratesv`)**: every crate has correct data (13.2mm AP: `DragCoef` 0.0044, `Tracer` 0.2; 85mm AP about 0.001).
- **Client (`acf_infmap_cratedebug`)**: the same five crates (#266, #250, #282, #168, #153) are known, each with 9 or 10 networked values (`AmmoType`, `Caliber`, `DragCoef`, `Tracer`, ...). **The version 6.4 text above was wrong to say the values might be missing: they are there.**
- **The shells**: their `shot #` lines say the "crate" is `acf_gun #204` / `acf_gun #290` (5 networked values: the gun's own length, caliber, breech index...) and the cratedebug list names `gmod_wire_expression2 #263`. A gun or a chip has no `DragCoef`, `Tracer` or `ProjMass`, so ACF's bullet effect falls back to drag 1, no tracer, 10 cm, and its own step blows the shell up (the part version 6.3 explained). The E2 number is the number received in this addon's effect message (SEEN: the log keeps the received `EntIndex`), and this addon looks a received number up unchanged (`Entity(index)`, SEEN in `cl_effects.lua`). That the gun numbers #204 / #290 are also received numbers is a GUESS: those come from the `shot #` lines, which show the entity ACF resolved.
- A detail nobody has explained yet (GUESS only): the guns the server lists are #207 and #293, the "crates" the client resolved are #204 and #290, each exactly 3 lower. It may be a coincidence.

What is NOT known: whether ACF's own `Bullet.Crate` is wrong on the server (stale or copied from a dupe, say), or whether something between ACF and the net message changes it. The `cratesv` run of 6.4 could not say, because the guns were empty at that moment and an empty gun's `BulletData` is a placeholder.

New in this version:

- **The server now records every new shell**, in a ring of the last 12: the number ACF holds in `Bullet.Crate`, which entity that number is **on the server**, which gun fired it, which crate that gun is using, and the number that was finally put in the message. `acf_infmap_cratesv` prints it ("the last N shells sent to clients"), with `<-- NOT an ammo crate` on every shell whose number is not an `acf_ammo`. Fire a burst, then run it at once.
- Reading it: `Bullet.Crate` is an acf_gun / E2 and `sent` is the same number -> ACF's own data is wrong at the source. `Bullet.Crate` is the right crate but `sent` differs -> something between them changes it. Both right but the client still shows a gun -> the client resolves it wrongly.
- **Display fix in `acf_infmap_cratedebug`**: the values printed as `table: 0x...` because `GetNW2VarTable()` holds tables; they now come from the typed getters (`GetNW2Float`, `GetNW2String`) and the table is only used for the names.
- Wrapping `Ballistics.BulletClient` costs one small table per new shell; a failure of the record is caught, said once, and never stops a shell.

Tests: 13 new checks (and one old check changed to the realistic table-valued `GetNW2VarTable`); 11 of 11 deliberately broken variants of the new code are caught. A test I wrote for the "record fails" path found a real bug in my first version of this code (`Compat.WarnOnce` exists on the client only, so a failing record would have thrown inside every gun shot on the server); it is fixed.

## What changed in version 6.4 (find out why the machinegun's crate gives your game no data; the life log was blaming the wrong thing)

Play-test of 6.3: test shells fly (drag 0 forced), real machinegun shells still die within 0.04 s. Their `shot #` lines say the crate "reports no drag" (so ACF's own client simulation assumes drag 1 and blows the shell up) and that its Tracer box is "OFF (0)". **Nothing in this version hides that**: if the crate's data does not reach the client, the shell would also have the wrong size, no tracer and the wrong impact effect, so covering up only the explosion would be a bandage. This version makes the cause readable instead.

What is SEEN in the source: ACF's bullet effect gives up (`Kill`, no bullet entry) when the crate entity is not valid on the client (`effects/acf_bullet_effect.lua`, `if not IsValid(Crate)`). The MG shells **did** create entries, so the crate is a valid entity on your client; only its networked values (`DragCoef`, `Tracer`, `Caliber`, `AmmoType`, set by `Ammo:Network` on the server with `SetNW2*`) are missing or the index names another entity. ACF's own source has the comment `TODO: Force crates to network and store this information on the client when they're created` right there. What is NOT known: which of "never set on the server", "set but never reached the client", or "the index is another entity here" it is. The two new commands separate them.

- **`acf_infmap_cratedebug`** (client console; button in the menu): every `acf_ammo` this client knows (nearest first, up to 10) with entity index, model, chunk, dormant or not, `AmmoType`/`Caliber`/`DragCoef`/`Tracer`/`ProjMass`, and the names of all networked values; then, for each entity the last bullets named as their crate, the same line (or "NULL: this client does not know that entity at all"). Fire the gun first.
- **`acf_infmap_cratesv`** (server, superadmin, in your own console; button in the menu): the guns near you (nearest 5), each one's current and linked crates **as the server holds them** (`DragCoef`, `Tracer`, `Caliber`, `AmmoType`, number of networked values), and the gun's `BulletData.Crate` against the crate's real entity index (flagged **DIFFERENT** when they disagree).
- Reading them together: server has `DragCoef`, client line shows `-` -> the value never reached your client (networking). Server shows `-1`/0 values -> the crate never set it (an ACF-side problem). `DIFFERENT` -> the shells name the wrong entity. The `shot #` line now starts with `crate = acf_ammo #123 with 6 networked value(s)` (or `crate = prop_physics #123 (NOT an acf_ammo ...)`).
- **Life log fix.** The MG lines said "ended: other - ACF's own 16380 limit (this addon should have stopped that)" although the shell had jumped far beyond your far distance. Cause (SEEN in this addon's code, GUESS about GMod): the reason was read from the effect entity **after** the engine had removed it, and a removed entity answers nil. The notes now live on ACF's plain bullet table (`Removed` is set there by ACF's own `Think`), which survives. Those shells now read as ended by distance, with their absurd speed named ("which no real shell reaches: ACF's own simulation had blown it up").
- **Test shells now say why they ended**, in one console line (`test shell #1 ended after 4.01 s: ...`), so a shell that "is being deleted" always comes with a reason. They still do not enter the life log.

Tests: 25 new checks, and 14 of 14 deliberately broken variants of the new code fail them (a first attempt at the superadmin variant was a no-op and survived; it was rewritten and then failed the tests as it should).

## What changed in version 6.3 (the test shells were wrong above ~120 m/s; real shots now report their drag)

Play-test of 6.2: a test shell at 400 m/s went backwards, 600 and 1000 m/s ones vanished at once, 100 m/s ones were fine. **This was the test, not InfMap.** ACF reads a shell's drag coefficient from its crate (`effects/acf_bullet_effect.lua`: `Crate:GetNW2Float("DragCoef", 1)`) and assumes **1** when the crate reports none. You carry no drag coefficient, so a test shell with you as its crate had a coefficient hundreds of times a real shell's (about 0.001). ACF's own client step (`ballistics_cl.lua`: `Flight = Flight + (Accel - Drag) * dt`, `Drag = DragCoef * speed^2 / 80`) then overshoots: when `DragCoef * speed * dt / 80` passes 1 the velocity changes sign (about 120 m/s at 60 fps), and above 2 it grows on every tick, which throws the shell out of the window in a few frames. A 100 m/s shell has a factor below 1, so it only slowed to a crawl and looked fine. (SEEN: ACF's real simulation run in the harness reproduces the flip: factor 1, 400 m/s, three ticks.)

- `acf_infmap_bullettest` (and `acf_infmap_bulletsv self`): a crate that reports no drag coefficient now gets 0 for the test shell, and the console says so. A crate that reports one keeps it and the console prints it.
- **Real shots**: the `shot #` line now shows the drag coefficient, says when the crate reported none, and says **TOO HIGH for this speed** when ACF's own simulation would flip that shell. If your cannon or machinegun shows that, this is the cause of the vanishing shells, and the fix is in the crate's data, not in InfMap. If it does not show it, drag is ruled out for real shells.
- `acf_infmap_bulletdebug` prints the drag coefficient of each crate.

Tests: 12 new checks; 7 of 7 deliberately broken variants of the new code fail them.

## What changed in version 6.2 (one new test command and one menu button)

Play-test of 6.1: `acf_infmap_bullettest 100 100mm tracer self` showed the shell **and** the tracer. That proves ACF's bullet effect, the engine drawing it and the tracer all work here. It does **not** say the positions are right, because that shell starts at your own eye and never uses the network, which is the one step a real shot has.

`acf_infmap_bulletsv` (console, superadmin) makes that step testable: it calls ACF's own `Ballistics.BulletClient`, the function `CreateBullet` calls, with a made-up bullet 300 units in front of you, so the position goes server -> this addon's message -> client conversion -> ACF's effect, exactly like a gun shot. 4 s later it sends the end-of-flight update the way a hit would. It uses the nearest ammo crate within 5000 units (its Tracer value, caliber and model) or you (`self`). Run both and compare. Version 6's `acf_infmap_cl_force_tracer 1` and the per-shot `shot #` lines also work for this shell.

Tests: 18 new checks (the whole road in chunk 0 and in chunk 1000 with float32 positions, `self`, limits, refusals); 9 deliberately broken variants of the new code all fail them.

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
| Stray bullets | Nothing removes a bullet that hits nothing, so misses pile up in ACF's 2000 bullet slots and guns stop firing. | A bullet older than its allowed time is removed with ACF's own `RemoveBullet`: 20 s up to 40 mm, 150 s from 70 mm, a straight line between. The numbers are in `lua/acf_infmap_compat/config.lua`. |
| E2 rangers | `ranger`, `rangerOffset`, `rangerAngle` and the hull versions are one trace from the chip; under InfMap it only sees the chunk it starts in, so a hologram placed at `R:pos()` ends up at the far end of the line. | Each ranger function is cut to a distance set in `config.lua` (5000 m) and traced chunk by chunk, the same way as the camera. Terrain in chunks with nothing solid in them is still not hit. `rangerOffsetHull(entity, ...)` and `eyeTrace()` are not covered. |
| Wire camera controller | Its HitPos / Trace output is one trace of a billion units; under InfMap it only sees the chunk the camera is in. | That one trace is cut to a distance set in `config.lua` (5000 m) and traced chunk by chunk. Terrain in chunks with nothing solid in them is still not hit (InfMap has no collision there). |
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
| `acf_infmap_cl_origin_fix` | you | 1 | 1 = `ENT:CalcAbsolutePosition` of ACF's scalable entities answers in the entity's own chunk frame, so the engine keeps the right origin (lazers drawn too far away, version 7.3). 0 = stock |
| `acf_infmap_fix_visclip` | server | 1 | 0 = the server ignores clip requests (stock Visual Clip) |
| `acf_infmap_cl_replay` | you | 1 | 1 = show effects the engine cannot place (replayed from ACF's own effect code). 0 = drop them |
| `acf_infmap_cl_replay_distance` | you | 3000 | Metres. Far effects and far tracers are shown up to this distance from you (0 to 10000) |
| `acf_infmap_cl_replay_scale` | you | 1 | Size multiplier of far particles (0.1 to 5) |
| `acf_infmap_cl_bullets` | you | 1 | 1 = keep bullets alive past the engine's limit and draw their tracers there. 0 = stock |
| `acf_infmap_effect_range` | server | 120000 | Units (global distance) within which players are sent an effect. Keep it at least your far distance (3000 m = 118110 units) |
| `acf_infmap_fix_effects` | server | 1 | 0 = stock effect path |
| `acf_infmap_sound_range` | server | 20000 | Units within which players receive ACF sounds |
| `acf_infmap_fix_sounds` | server | 1 | 0 = stock ACF sound routing |
| `acf_infmap_fix_traces` | server | 1 | 0 = stock `ACF.trace`, and stock Wire camera controller and E2 rangers (their fixes use the same piece tracing) |

The bullet lifetime is no longer a console variable: see `lua/acf_infmap_compat/config.lua` (version 7.0 above).

Each fix has its own switch, so a misbehaving session can be bisected: turn one off, repeat the test. If the render fix raises an error five times it switches itself off and says so once in the console.

## Commands

| Where | Command | Shows |
|---|---|---|
| server + client | `acf_infmap_status` | Which functions are wrapped, counters, settings, bullets in flight, far-effect, render and visual clip state |
| client | `acf_infmap_renderdebug` | The render fix: how many entities it watches, the nearest wrapped ones with their own override, each Prop2Mesh mesh (its local offset from `linkpos`, chunk, override, engine draws), how many meshes are at the wrong position or in another chunk but unwrapped right now, how many props were asked about |
| client | `acf_infmap_entdebug <part of a class name>` | For the nearest entities of that class (try `lazer` or `gun`): chunk, Draw / DrawTranslucent, render group, InfMap's stored render box and how far off-centre it is, wrapper state, Draw route, engine calls, and (7.3) whether `CalcAbsolutePosition` is wrapped and how far the engine's position is from the one the server networked |
| server (superadmin, or the server console) | `acf_infmap_config_reload` | Re-reads `lua/acf_infmap_compat/config.lua` and prints what each section now says: the seconds each caliber gets (13.2, 20, 30, 40, 55, 70, 85, 120, 155 mm) and the Wire camera and E2 ranger reach, and any mistake it found in the file |
| client | `acf_infmap_fartest [metres]` | A real ACF explosion that far ahead of you (default 1500) |
| client | `acf_infmap_replaydebug` | Far particles live / recorded, effects empty / dropped / errored |
| server (superadmin) | `acf_infmap_sounddebug` | Per player: chunk, global position. Per engine/turret/waterjet: how many players stock ACF would have sent to vs how many this addon sends to |
| client | `acf_infmap_sounddebug_cl` | Your chunk, each engine's chunk, local position, distance, loop state |
| server (superadmin, from your own console) | `acf_infmap_tracedebug [distance]` | Fires a line through **stock** `ACF.trace` and through the **fixed** one and prints both |

## Your next session

1. **Is it running?** Server and client console: `acf_infmap_status`. On the client you should see `render:` with "render boxes converted ... (ready)", a `visclip:` line and a `bullets: shot report ON` line; on the server a `visual clip resync ... ready` line.
2. **The lazers.** Stand in a chunk away from a firing lazer, look at it, and run `acf_infmap_entdebug lazer`. Paste the output if the beam or the lazer is still missing. The line to watch is "InfMap's stored local render box": a centre more than a few thousand units from the lazer means cause 4 is happening in your game (GUESS until then).
3. **Version 7.0, machineguns and mortars.** On the server run `acf_infmap_status` and look for `bullets: lifetime 20 s up to 40 mm, 150 s from 70 mm (config.lua)`. Fire a machinegun for a minute and run it again: `N in flight now` should stay bounded (about the gun's rate of fire times 20 s) and `removed by it so far` should grow after the first 20 seconds. Lob a mortar shell and check it still lands. If your client still lerps, paste `acf_infmap_status` from the server.
4. **Editing the lifetime.** Change a number in `lua/acf_infmap_compat/config.lua`, then `acf_infmap_config_reload` in the server console and read the printed table. If it prints the old numbers, restart the server (GUESS list, item 28).
5. **The dupe test** from version 5 is unchanged.
6. **Version 7.3, the lazers.** Stand a chunk or two away from a firing lazer and a gun, run `acf_infmap_entdebug acf_lazer` and `acf_infmap_entdebug acf_gun` and look at the `CalcAbsolutePosition` line of each. `the same` and a lazer that is now where it should be: done. `DIFFERENT by ... chunks`: paste it. `the same` and still too far: the cause is elsewhere, paste the whole output.

## What was tested, and how

Two harnesses, both kept in my workspace (not in this zip), both running **real** third-party files against a mock of the GMod API.

- **`test_render_compat.lua`** runs the real InfMap files (`sh_inf_functions`, `sh_inf_networking`, `cl_inf_detours`, `cl_inf_chunks`), the real Visual Clip client and server files, the real Prop2Mesh `cl_init.lua` and ACF's real `overrides_cl.lua`, translated from GLua syntax to Lua only (no behaviour change), against an engine model (entities, parenting with the SDK's world-to-local rule, render bounds and culling against the +-16384 box, opaque and translucent passes with or without flags, camera and clip stacks, networked entities and NULL for unknown ones, hooks, timers). Every scenario runs **twice: STOCK (the addons alone) and FIXED (plus this addon)**. The STOCK runs reproduce each root cause from the real code (for example a Prop2Mesh child at engine position (16384, 0, 20) instead of (2050, 0, 20), a lazer three chunks away with no beam, a firing lazer whose cached box is 60000 units off). The lazer is a stand-in written from the draw code in your `cl_init.lua` (model in `Draw`, beam and glow in `DrawTranslucent`, box set in `Think`), not the file itself. **277 checks pass** in version 7.3 (195 in 7.2: 67 new for the engine origin, 15 more written after the mutation run below).
- **`test_acf_infmap_compat.lua`** runs this addon's files with ACF's real traces, ballistics, sounds, effects (`acf_bullet_effect`, `acf_explosion`, `acf_impact`) and loader. **509 checks pass** in version 7.3 (504 in 7.2, 430 in 7.1, 359 in 7.0) (it was 499 in 6.7.1; the checks of the removed shot report, test shells, crate diagnostics and mismatch reports were removed with them; version 7.0 adds the lifetime, config and reload checks listed above).
- **Mutation testing:** I broke the addon on purpose and ran the checks against each broken copy: 63 breaks in the render and clip code and 79 in the rest for versions up to 6.7.1, 57 for the 7.0 code, 61 for the 7.1 code 52 for the 7.2 code and 63 for the 7.3 code (54 in `cl_origin.lua`, 9 in its wiring: autorun, install order, menu, `entdebug`; all listed above; the 7.0 config reader moved into `sv_config.lua` in 7.1 and its breaks were redone there). **All are caught by at least one check, except one break I marked as equivalent** (running the Prop2Mesh sweep before the override guard: since version 5.1 the guard routes wrapped entities itself, so both orders end in the same state in the same frame). Re-running the suites after the version 5.1 edits also showed that six of my own breaks no longer matched the code (they were being skipped, not caught) and that one new check passed only some of the time because two hooks of the same tick have no defined order. I rewrote the breaks and made the check order-independent before counting anything.

**Version 7.3 mutation result, as it happened:** of the 63 breaks, 44 were caught by the first run and **19 survived**. For 16 of them I wrote new checks (a table error value thrown on unchanged; your chunk not known yet; one wrapper per function shared by class table and entity; an invalid entity left alone; the `Initialize` and `InitPostEntity` hooks; a scan that fails does not escape the timer; the status counting entities; the report on the y and z axes and for an entity without the function; `entdebug` surviving a failing report; the installer running again after `acf_reload`) and re-ran those 16: all are now caught. **3 remain, which I judge equivalent:** (a) `IsValid(Me) and Me.CHUNK_OFFSET` without the `IsValid` (KNOWN, not re-checked: indexing a NULL entity gives nil, so the result is the same); (b) `cl_origin` listed before `cl_render` in the install order (the two installers do not depend on each other); (c) the counter names `OriginCalls`/`OriginErrors` declared in `sh_core.lua` (`cl_origin.lua` declares them itself; the shared list only adds two zeros to the server's counters line).

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
18. That 150 s (large calibers) is long enough for your mortars and howitzers. Without drag a 1000 m/s shell at 45 degrees is in the air about 93 s and a 1500 m/s shell fired almost straight up about 197 s (arithmetic, not a measurement); with ACF's drag the times are shorter. Raise `LargeSeconds` in `config.lua` if a shell you fire is removed before it lands.
19. That the materials ACF names can be loaded with `Material()` at draw time exactly as `ParticleEmitter:Add` loads them.

Version 6:

20. That the engine really skips an entity whose render box is outside the +-16384 world box (InfMap's own comment says so), and that the corrected box is what brings the lazer back. The Draw route (causes 1 to 3) does not depend on this.
21. That `GetRenderBounds` on the client returns what `SetRenderBoundsWS` stored, converted with the entity's raw position (this is what makes the stored box one chunk-difference off).
22. That a Lua call `ent:SetRenderBoundsWS(...)` goes through the `Entity` metatable entry this addon replaced (InfMap's own `GetPos` / `LocalToWorld` detours rely on the same lookup).
23. That the engine sets `STUDIO_DRAWTRANSLUCENTSUBMODELS` (4) in the flags of every translucent-pass draw. The addon does not rely on it: the pass hooks are the other signal, and "opaque" in the flags never overrules them.
24. That your cannon's rounds are simply too fast and too short-lived to notice, or have no tracer because of the crate's Tracer value. The per-shot lines decide.

Version 6.7:

25. That the leftover in the engine's `EffectData()` was the firing gun. CONFIRMED in part by your 6.7 console: the object does arrive non-empty (Normal, Origin, Scale). The gun itself is still the explanation for the 6.6 shot lines, and 6.7 fixed them.
26. That `SetEntity(NULL)` clears the entity. If it does not, the explicit crate replaces the leftover (tested with an engine that ignores NULL).
27. That the shells with `Bullet.Crate = nil` (drag 0.0137 in your ring, one after each real shot) are ricochets or fragments. Not read from the source; they are no longer drawn, like in stock ACF.

Version 7.0:

28. That `include("acf_infmap_compat/config.lua")`, run from `acf_infmap_config_reload`, reads the file from disk again (KNOWN that `include` is a plain file read on the server; I did not confirm that nothing caches it). If it does not, restart the server after editing.
29. That removing a bullet by time without any message to the clients is invisible: the client picture of the bullet ends by itself (45 s, or past the far distance), so it should be. With the 20 s of version 7.2 the server drops a small-caliber bullet before the client picture ends by itself, so a tracer can fly on for up to 25 s on your screen (version 7.2 section; out of sight in practice).
30. That the machinegun lerp you saw was the server falling behind because of stray bullets (the cause this cap targets). It fits the mechanism (SEEN in `ballistics_sv.lua`: every bullet is traced every tick, and under InfMap a miss never ends), but I did not see your server's tick time.

Version 7.1:

31. That an entity that already exists holds its own copy of the class's functions (the engine merges the class table into the entity's table when it is created). The addon patches both the class table and the existing entities, so it works whichever is true; what I cannot tell is which one the engine does.
32. What the engine does with the stock trace of 999999999 units. In the mock a miss gives HitPos = the end of the line. If the real engine instead clamps or returns something else, stock behaviour was even worse than described; the fix does not depend on it, because it never traces such a line.
33. That the engine accepts a trace piece that starts exactly where the previous one ended (the next chunk's frame). The bullet trace has relied on this since version 3 and you reported hits across borders work; the camera uses the same code.
34. That your E2 reads `HitPos` / `Trace` from the camera controller and not from its own `rangerOffset`. It did not: it used its own ranger, which is why 7.1 did not move the hologram (fixed in 7.2).

Version 7.2:

35. That nothing else keeps a copy of the E2 ranger functions. SEEN: the compiler copies `wire_expression2_funcs[signature][3]` when it compiles a chip, and the addon replaces that field. Another addon that copies a ranger function itself, or an E2 extension that calls `ranger()` through its own reference, would bypass the fix.
36. That the real E2 behaves like the mock for chips compiled after the install (SEEN in the compiler source; not run in a game).
37. That the engine accepts a hull piece that starts exactly where the previous one ended, like item 33 does for lines.
38. That the hologram script uses the ranger functions listed above (`ranger`, `rangerOffset`, `rangerAngle`, the hull versions) and not `entity:eyeTrace()` or `entity:eyeTraceCursor()`. If it still goes wrong, paste its ranger lines.

Version 7.3:

39. That the engine calls `ENT:CalcAbsolutePosition` for ACF entities and stores what it returns as the entity's origin, as the GMod wiki describes (the mock does exactly that). If it does not, `cl_origin.lua` has nothing to change and the cause of the too-far lazers is elsewhere (the `entdebug` line tells you).
40. That inside that function `GetPos()` is the position the engine has just worked out, so returning it unchanged is a no-op on a map without InfMap. The wrapper makes InfMap's detour answer like that.
41. Why lazers show the fault and guns do not (see the 7.3 section; candidates only).
42. That an entity that exists before the wrapper holds its own copy of the function (like item 31), which is why existing entities are patched too.

## Not covered (SEEN unless marked)

- **Two console lines reported while flying a ship at about 10,000 units/s** (`Out-of-range value (30076.365234) in SendPropFloat 'm_vOrigin[1]', clamping` for class `kir_collider`, and `Clamping SetLocalVelocity(-204.8, 9997.9, 0) on physgun_beam`): this addon's server code never sets a position, velocity or parent (SEEN), `kir_collider` is not in any source I have, and the cause is open. 30076.365 = 20000 + 10076.365, which is one chunk width plus 76 units past the border at the moment of a crossing (arithmetic; GUESS that it is a crossing). Needs the `kir_collider` addon and the E2's impact check.
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
lua/acf_infmap_compat/sv_traces.lua    chunk-aware ACF.trace + clone resolution + tracedebug + TraceFar for long lines
lua/acf_infmap_compat/config.lua       the numbers you may edit: bullet lifetime by caliber, camera reach, E2 ranger reach (server only)   (new in 7.0)
lua/acf_infmap_compat/sv_config.lua    reads config.lua (all sections), checks every value, acf_infmap_config_reload   (new in 7.1)
lua/acf_infmap_compat/sv_wire.lua      Wire camera controller: HitPos / Trace across chunks   (new in 7.1)
lua/acf_infmap_compat/sv_e2ranger.lua  E2 rangers (ranger, rangerOffset, rangerAngle, the hull versions) across chunks   (new in 7.2)
lua/acf_infmap_compat/sv_bullets.lua   stray bullet cap by caliber
lua/acf_infmap_compat/sv_effects.lua   effect messages with exact positions
lua/acf_infmap_compat/sv_settings.lua  server side of the menu (superadmin-only setter)
lua/acf_infmap_compat/sv_visclip.lua   answers clients' "I have this prop but no clips for it" with Visual Clip's own message   (new in 5)
lua/acf_infmap_compat/cl_effects.lua   effect receiver (blanked EffectData, explicit crate), tracer frame shift
lua/acf_infmap_compat/cl_replay.lua    far effects: records ACF's effect particles and draws them, fartest, replaydebug
lua/acf_infmap_compat/cl_bullets.lua   keep-alive and far tracers (the diagnostics of versions 6 to 6.7.1 were removed in 7.0)
lua/acf_infmap_compat/cl_render.lua    visual clips, Prop2Mesh and scripted entities (lazers) in other chunks: override guard, chunk context, mesh position, Draw route with pass detection, render box correction, clip resync, renderdebug, entdebug   (new in 5, extended in 6)
lua/acf_infmap_compat/cl_origin.lua    ACF entities in other chunks: the engine origin kept in the entity's own frame (ENT:CalcAbsolutePosition), origin report for entdebug   (new in 7.3)
lua/acf_infmap_compat/cl_menu.lua      the settings panel
```
