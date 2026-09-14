# TrimUI Smart Pro - OpenMW 0.51 port

When I saw that someone had made a portmaster port for Morrowind I was really excited to put it on my TSPS, but then I found out it likely would not work on the TSP or even if I did install Knulli OS to be able to run it that it would not run very well. Morrowind is my favorite game of all time though, so I thought there has to be a way to get this working. What I initially thought would be just a reworking of the SH launcher file for the game turned into a massive undertaking of retuning the source code for OpenMW and building a binary that actually ran well on this system. Currently this game is playable only on the TrimUI Smart Pro and TrimUI Smart Pro S running either stock OS or Crossmix, though it will likely work on other OS's when I have the time and money to buy new SD cards and patch for them (it may work already, but I can't garauntee that). Instructions for installing the game and a full list of all major changes to stock OpenMW 0.51 is listed below.


## What changed, and why

### Rendering path

- **Legacy direct framebuffer.** OpenMW 0.49+ routes the scene through a post-processing FBO
  chain — scene colour target, opaque-depth copy, normals RT, ping-pong canvases. On GLES2 most
  of that either does not work or costs more than it returns. The port recreates 0.48's
  behaviour and renders straight to the default framebuffer, with the opaque-depth texture,
  normals RT, soft particles and weather particle occlusion all disabled behind one
  `constexpr bool`. *(`mwrender/postprocessor.cpp`, `mwrender/renderingmanager.cpp`)*
- **Resolution split.** The panel and EGL drawable are permanently 1280×720, so
  `[Video] resolution x/y` is repurposed as the **internal render size** and the window is
  hardcoded. The settings menu offers a fixed allow-list of internal targets rather than SDL
  display modes, and the resize handler no longer copies the physical drawable back over the
  setting. *(Worth 1–2 fps; it stays because it carries the fps overlay.)*
- **Depth buffer fallback ladder.** 32 → 24 → 16 → stencil 0, retried against SDL window
  creation, with full diagnostics of what the driver actually granted. Plus an optional
  near/far depth-partition camera (`OPENMW_TSP_DEPTH_PARTITION`, default off).
- **Water rebuilt for GLES2.** A 16-cell plane at 64×96 subdivisions instead of 150 cells at
  40×900; `GL_QUADS` replaced with indexed triangles and VBOs; `GL_DEPTH_CLAMP` and the
  camera-relative fudge callback removed; fixed-function fog instead of a water shader.
- **Framebuffer completeness.** GLES2 rejects colour-only FBOs that desktop GL accepts. The
  global map now keeps its implicit depth attachment; the terrain composite-map renderer went
  through six revisions removing things that caused flickering blue/white blocks and solid red
  distant terrain. Complete framebuffers went from **14 to 440**, worth **3–4 fps**.
- **Shadows** gained temporal reuse (skip N cascade culls, recompute only the shadow-space
  matrix, with a 40 ms staleness cap, frustum inflation and texel-grid snapping). Unused in the
  shipped config — all shadow settings are off — but correct if you want them.

### The shader compile stall

Mali charged roughly **137 ms inside `glLinkProgram` plus ~236 ms deferred into the first draw**
— about 375 ms per new program, in the same frame. That is what made the first swing at each
creature type and the first cast of each status effect freeze the game.

- **`TSP_SHADER_DEDUP`** — a second shader cache keyed on the *generated source text* rather
  than the define map, because many different define maps produce byte-identical GLSL. Programs
  15 → 13.
- **`TSP_SHADER_PRECOMPILE`** — hands every new program to OSG's incremental compile operation
  during the loading screen.
- **`TSP_SHADER_WARMDRAW`** — OSG only *links*; the other 236 ms needs a real draw. So each new
  program gets a throwaway 3-vertex degenerate triangle with colour and depth writes masked,
  released one per frame from a warm-up group attached to the scene root. Each warm draw is an
  atomic ~240 ms `glDrawArrays` that cannot be subdivided, only spaced apart.
- **`TSP_LOAD_FREEZE`** — holds simulation and input (via the engine's own `disableControls`)
  while the warm draws burn off, releasing early once the group drains. Measured: armed for 300
  frames, released after ~38.
- **`TSP_NO_ENVMAP`** — environment mapping forced off, cutting one whole shader variant.
  Programs 13 → 12. Costs the reflective sheen on metal, glass and Dwemer surfaces.
  `TSP_KEEP_ENVMAP=1` restores it without a rebuild.

Alongside these, gl4es gained a **program-binary disk cache** (link 50 ms → **1.0–1.2 ms** warm,
`hit=32 miss=0 reject=0` on a second run) and a **GLSL conversion cache** (0.2–27.7 ms →
0.1–1.0 ms). The in-combat stall is gone.

### Memory

The device has 986 MB, no swap by default, and a page cache that collapses to 26–46 MB during
play. Almost everything that looked like a GPU problem was a memory problem.

- **ASTC/KTX textures.** The single largest win: 30 lines across two `.cpp` files, no header
  change. `correctTexturePath` prefers a `.ktx` when the VFS has one; gl4es passes non-DXT
  compressed formats straight through to the driver untouched. **138.3 MB of DDS → 51.3 MB of
  KTX** (3,663 textures converted, 892 small ones skipped). Measured A/B: MemAvailable floor
  **105 → 192 MB**, RSS peak **646 → 584 MB**, page cache peak 245 → 302 MB. No visual change.
- **Save-reload leak, fixed.** Retention went from **+7,863 kB per load to +15 kB per load**.
  Two causes: clearing the resource cache on load reclaimed 9.5 MB and cost 13.4 MB
  re-instantiating from cold; and `GlobalMap::read()` orphaned a 3.3 MB render-to-texture camera
  on *every* save load, because the only caller of `cleanupCameras()` is on the map-explore
  path. Draining both vectors in `GlobalMap::clear()` took `globalmap_read_kb` **3,223 → 3**.
  Save-scumming is now safe indefinitely.
- **The same orphaned cameras were the world-map corruption**, because they keep re-rendering
  onto the live overlay texture and `exploreCell` reads the result back into the save. A repair
  pass scores each map cell by roughness and zeroes the damaged ones; the overlay PNG went
  63,436 → 45,202 bytes, 24 bad cells → 0.
- **Periodic `releaseGLObjects` removed.** A 90-second timer was dropping every GL object on a
  cell change. The purge was cheap; the recovery was 6–9 `glLinkProgram` at ~60 ms each plus
  100+ texture uploads. All eight logged purges reclaimed **0 kB**. Turning it off took the
  worst gameplay frame in a 900-frame window from **1952 ms to 71.8 ms**.
- **Incremental compile budget.** OSG's ICO was capped at **one GL object per frame** during
  gameplay, so every streamed-in texture and mesh trickled out one per frame after every cell
  transition. Raising it to 4 produced, on three of the worst known spots, *"next to no frame
  hitching."*

### Cell streaming

- **`TSP_TERRAIN_STREAM_V2`** — `changeCellGrid` was calling a *blocking* terrain preload from
  inside `mWorld->update()` while the player was simply walking. One frame measured
  `total=574.3 cpu=254.5 world=396.2` — **320 ms of the main thread doing nothing**. And it was
  waiting on the wrong item, because `setTerrainPreloadPositions` silently discards its argument
  when a preload is already in flight. The port blocks only on teleports and loads, where a
  loading screen is already up.
- **`TSP_TERRAIN_LEAD_V2`** — a second preload position aimed at the cell the player is about to
  walk into, clamped under one cell size. Upstream's warning distance at walking speed is about
  750 units; this gives ~4,000.

### Saves, autosave and stability

- **Door autosave.** Upstream-style periodic autosave cost ~310 ms per fire and, in an exterior,
  fired while sliding across an invisible cell line. `MWWorld::Cell::getWorldSpace()` changes
  *exactly* on a door or teleport and never on a walk, so the port saves there — hidden behind a
  loading screen that is already happening — into five rotating slots whose index lives in a
  file so rotation survives a relaunch. There is deliberately **no periodic backstop**.
- **Optional exec-based save reload** (`tspRestartForSaveLoad`) that replaces the process image
  rather than loading into a live one, controlled by `[TSP] safe reload`, with every non-stdio
  descriptor marked close-on-exec so stale EGL, DRM and audio handles cannot cross. Now off by
  default, but it doubles as a memory backstop.
- **Player animation lifetime.** Inventory listeners are detached in `World::clear()` while both
  the old animation and the old player record are still valid, and `renderPlayer()` constructs
  the new animation, points the camera at it, and *then* releases the old one.
- **Full load-phase tracing** — 23 named phases, a per-record-type census, byte-offset progress,
  content-file index mapping, and a post-load survival watch at 250 ms through 20 s. This is
  what eventually localised the memory growth to a single unlabelled 191.8 MB step inside
  `Scene::changeCellGrid`.

### Controls

The pad has 11 buttons, crossed START/SELECT in its own controller database, and a MENU key that
upstream binds to quicksave. The port rebuilds the whole input layer around that:

- **An explicit mouse mode**, opt-in per menu rather than sticky, resetting on any change of
  active window, with the SDL hardware cursor (invisible through gl4es) permanently hidden and
  MyGUI's in-engine pointer mirroring the engine's own cursor state.
- **A MENU chord layer.** MENU arms on press and acts on release, so one button means three
  things without them fighting: held + input is a chord, a bare release toggles the mouse, and
  two releases inside 400 ms is a hard reset. Quick slots 1–9 on the face buttons, right stick
  and R3; quicksave/quickload on the triggers; screenshot and the quick-keys menu on the
  shoulders; and **quit on MENU + START, which works everywhere including menus** — the escape
  hatch for a UI you cannot get out of, with a 3-second hard-kill deadline behind it.
- **Continuous right-stick scrolling** in dialogue, journal and topic lists, which stock 0.51's
  indirect mouse-wheel path does not deliver.
- **Main-menu focus** walks the menu's own visible button list instead of injecting Tab, which
  used to land focus on an edit box, turn on SDL text input and hand the pad to the text helper.
- **An on-screen text entry helper** — a separate uinput process coordinating with the engine
  through four files in `/tmp`, with an in-engine indicator widget showing the current letter.

### Readability on a 5-inch screen

The global UI font is 28 px, which no upstream layout expects, and MyGUI clips text taller than
its widget — so most of this is widget *heights*, not font sizes. Stats and skill rows, magic
effect rows, the controls list, tooltips, the loading screen, book and dialogue typesetting
(which needed a font size threaded through `BookTypesetter`), per-item list fonts, a widened
`[GUI] font size` clamp (12–18 → 12–32) and several new `[GUI]` keys. The HUD is hidden during
dialogue, because at 28 px the two collided.

### Occlusion culling

A CPU software-rasterised occlusion culler built on Intel's Masked Occlusion Culling (vendored
with `sse2neon.h` for aarch64), with terrain occluders generated from the heightmap, occluder
meshes simplified from building-sized statics, a precomputed occluder database, and 18 new
`[Camera]` settings.

**Worth +7 fps on open exterior sightlines.** Indoors it is a clean failure and the falsification
is documented in full: the final version removed 27 % of submitted drawables and the framerate
did not move, because deciding what to cut costs 2–4 ms per frame — exactly what the cut saves.

### gl4es

The most important change in the whole port is four lines. The device blue-screens if gl4es
probes hardware capabilities at init, so the launcher must set `LIBGL_NOTEST=1` — and
`GetHardwareExtensions()` begins with `if (tested) return;`, which sets the flag **without any
detection running**, leaving every capability at 0. A Mali-G57 was being driven as the weakest
GLES2 device that exists.

`tsp_late_hardext()` runs detection at first shader compile from the real extension string.
That one function fixed:

- **the long-standing texture wobble** on static world geometry (NPOT and highp reported absent);
- **the compass, local map and inventory doll rendering as garbage** — `hardext.maxcolorattach`
  was 0, so `gl4es_glFramebufferTexture2D` range-checked `GL_COLOR_ATTACHMENT0` against an empty
  range and returned `GL_INVALID_ENUM` **before attaching anything**, while the driver still
  reported `GL_FRAMEBUFFER_COMPLETE` because depth alone is legal. Every render-to-texture in
  the game was drawing with its colour output discarded;
- **the program-binary cache**, which needs `hardext.prgbinary` and `prgbin_n` set.

> `LIBGL_TSP_LATEDETECT=1` in the launcher reads like a debug flag. It gates all of the above.
> Removing it silently undoes the texture-wobble fix and the shader cache together.

Also in gl4es: read/draw framebuffer target normalisation (GLES2 has no split) and a bind-sync
fix that took complete framebuffers from 211 to 440; 24-bit RTT depth instead of a hardcoded 16;
`highp` forced on unqualified varyings; `invariant gl_Position` inserted into every vertex shader
(two passes computing position differently is z-fighting on a tiled GPU); the three unrelated
behaviours bundled into `LIBGL_NOTEXMAT` split apart so fixing building UVs no longer breaks
night lighting; display-list merge correctness; a client-buffer fix so transient render lists
cannot inherit the application's bound array buffer; and an internal-render-size /
forced-output-rect pair for the resolution split.

### SDL2 and gptokeyb2

SDL2: `precision mediump float` → `highp` in the GLES2 renderer's shader includes — six lines,
because mediump is not enough for SDL's own 2D blits at 1280×720 on this driver.

gptokeyb2: checked return values on two `write()` calls, and a new `mouse_speed_down` /
`mouse_speed_up` action pair so pointer speed is adjustable from the pad.

### Outside the engine

- **A 512 MB swapfile on eMMC with `swappiness=150`** — measured directly: swappiness 150 gives
  25.1 major faults/s, swappiness 1 gives 91.9/s. Page-cache thrash took a healthy window from
  0 major faults to **997 per 10 seconds** before this; it is 2 now.
- **`read_ahead_kb` 128 → 512** on both block devices, which was the entire benefit of a
  three-knob "IO tune" block whose other two knobs were wrong.
- **A pre-baked navmesh database on internal eMMC** (172 MB/s vs the SD card's 41). Centre of
  Balmora went **10–12 fps → 22–23 fps**. `write to navmeshdb = false` is deliberate: it stops
  persisting, not generating, and with a baked database there is nothing to generate.
- **CPU and GPU clock recovery.** The Mali sat at **150 MHz for its entire uptime** against an
  888 MHz ceiling, because `simple_ondemand` gets no utilisation data from the driver. The stock
  TSP's four cores sat at **1.2 GHz flat** against a 2.0 GHz ceiling at 52 °C. Pinning both —
  and restoring platform defaults on exit — is where the last several fps came from (5–6 on the
  stock unit).
- **Daemon scheduling hygiene.** Every system daemon ran at `nice=0 cpus=0-7`, sharing the
  game's main-thread core; `trimui_osdd` alone had 6,151 CPU-seconds. Pinning them to a
  background mask, and the exFAT FUSE daemon to `nice -5`, took hitches **210 → 56**.
- **An idle guard.** CrossMix's idle timeout takes the backlight to 0 and stops; the SoC keeps
  running and the game keeps rendering at full clock behind a dark panel indefinitely. The
  launcher SIGSTOPs the game on a dark→lit state transition and SIGCONTs on wake. (Real deep
  suspend was tried; under a live GLES context it hung the device hard enough to need a PMIC
  power-off, and must never be revived.)
- **Adaptive draw distance** — a Lua controller mapping smoothed framerate onto view distance,
  with a trimmed recency window and a per-frame glide so the far plane breathes instead of
  stepping. Largest step went from 500 units to 24.
- **Weather fallback data.** A census found **Ashstorm and Blight had zero fallback keys** in the
  entire config chain — all 17 colours, fog depths, wind speed, the cloud texture, everything —
  against 26–41 for every other weather. OpenMW ships no defaults for these, so every ashstorm
  and blight in the game had been running on default-constructed values, and the permanently
  empty cloud texture name is what made the Ald-ruhn sky render flat magenta. Both blocks are
  now generated from the device's own `Morrowind.ini`.
- **ASTC texture conversion**, on host or on device, driven from a bundled game manager that
  also handles mod install, navmesh building and storage setup.

---

## Results

**Smart Pro S** — median **26.7 fps** on the Balmora route, ~40 fps in open exteriors, 28–35 in
Ald-ruhn, 11.7 % of frames under 20 fps. Worst frame 7.7 fps, ~3 % of frames under 10.
**Smart Pro (stock)** — median 21.3 fps with the frame hitching eliminated.

Where it started: multi-second 0–1 fps freezes from page-cache thrash, a ~375 ms stall on the
first swing at every creature, a 1,952 ms worst frame, a save-load leak of 7.8 MB per load,
magenta skies, black compass and inventory doll, swimming textures, and no distant terrain.

## Layout of this repository

```
sources/    source trees (no build dirs, no .before-* backups)
scripts/    build and patch scripts
patches/    git diff per repo — the record of local modifications
manifests/  git HEADs, TSP marker map, tree listing, toolchain info
```

`patches/tsp-openmw-0.51.patch` is the full diff against upstream `f4bec41`.
`manifests/TSP_MARKERS.txt` lists every marker in the tree;
`manifests/TSP_MARKERS_BINARY.txt` lists the ones that survive into the binary.

## Credits and licences

OpenMW is GPL-3.0. gl4es is MIT. SDL2 is zlib. gptokeyb2 is GPL-3.0. Intel Masked Occlusion
Culling is vendored under Apache-2.0 (`extern/maskedoc/license.txt`); `sse2neon.h` is MIT.

