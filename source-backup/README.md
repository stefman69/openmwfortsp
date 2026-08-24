# OpenMW 0.51 — TrimUI Smart Pro port

Source snapshot of a working port of OpenMW 0.51 to the TrimUI Smart Pro:
Allwinner A133, Mali-G57, **986 MB RAM**, no desktop GL — everything goes through
[gl4es](https://github.com/ptitSeb/gl4es) translating GL to GLES2. Runs at 1280x720
native, ~22-27 fps in Balmora.

This repository is source only. Binaries are rebuilt from it; `manifests/DEPLOYED.txt`
records the sha256 of the build each snapshot corresponds to.

## Layout

| path | what |
|---|---|
| `container/openmw-0.51-tsp-src/` | every modified OpenMW source file, copied whole |
| `container/gl4es-tsps-src/` | the patched gl4es fork |
| `container/osg/` | modified OpenSceneGraph files |
| `container/standalone/` | `LD_PRELOAD` shims and the controller helper, built by hand |
| `container/tooling/` | build scripts and every idempotent patcher |
| `device/` | launcher, `settings.cfg`, `openmw.cfg`, controller DB as actually deployed |
| `manifests/` | file lists, git logs, uncommitted diffs, hashes, deployed-build markers |

Files are selected by two rules: anything with a sibling `.before-*` backup (the
convention every patch here follows), and anything containing a `TSP_` marker.

## Fixes worth stealing if you are porting to similar hardware

**gl4es + `LIBGL_NOTEST=1` silently breaks every render-to-texture.**
`LIBGL_NOTEST` skips `GetHardwareExtensions()`, which leaves `hardext.maxcolorattach`
at 0. `gl4es_glFramebufferTexture2D` then range-checks `GL_COLOR_ATTACHMENT0` against
`[GL_COLOR_ATTACHMENT0, GL_COLOR_ATTACHMENT0+0)`, fails, and returns `GL_INVALID_ENUM`
**before attaching anything**. Depth still attaches because it is matched by name. The
FBO ends up depth-only, Mali reports `GL_FRAMEBUFFER_COMPLETE`, nothing warns, and every
colour fragment is discarded — the local map, compass and inventory doll render into
nothing and display uninitialised GPU memory, differently on every launch. Marker
`TSP_MAXCOLORATTACH_FIX_20260824` in `src/glx/hardext.c`. Clamp it to at least 1.

**Render targets come back as garbage, not zeros.** Unwritten regions of an FBO colour
texture read as whatever was in the pool on this driver. OSG scissors its clear to the
camera viewport, so a target rendered into a sub-rect leaves the remainder undefined.
`TSP_RTT_INIT_TEXTURE_V55` in `components/sceneutil/rtt.cpp` zero-fills RTT colour
textures at creation.

**Do not purge GL objects on a timer.** `releaseGLObjects()` every ~90s reclaimed 0 kB
on all eight measured occasions and cost 6-9 `glLinkProgram` at ~60 ms each plus ~100
texture re-uploads. Worst gameplay frame went 1952 ms -> 71.8 ms with it disabled. Gate
any purge on real memory pressure, never on a clock. Same for `malloc_trim(0)` — it
buys a hitch now and a fault storm later.

**512 MB swap on internal storage.** Major faults 997 -> 2 per 10 s; the SD card is
exFAT over FUSE, so every evicted code page is a userspace round trip. With swap the
kernel evicts anonymous pages instead.

**Prebuilt navmesh on internal storage, read-only.** `OPENMW_TSP_NAVMESHDB` overrides
the hardcoded `<userdata>/navmesh.db`. Generating it offline and shipping it read-only
took central Balmora from 10-12 fps to 22-23. Note SQLite cannot open a `chmod 444`
file as a database — use 0644 and `write to navmeshdb = false`.

**Pin the main thread to the fastest core.** The process was landing on two little
cores at a fixed 1.416 GHz while a 2.16 GHz core sat idle. BusyBox `taskset` takes a
hex mask, not `-c <list>`.

## Rebuilding

```sh
# OpenMW, incremental
docker exec openmw_builder cmake --build /root/openmw-0.51-tsp-build --target openmw -- -j2
# gl4es (must be bash - the script uses `set -o pipefail`)
docker exec openmw_builder bash -c 'bash /root/rebuild_gl4es_tsps_o3.sh'
# the controller helper
docker exec openmw_builder gcc-13 -Wall -Wextra -O2 -o /root/tsp_openmw_controls /root/tsp_openmw_controls.c
```

## Licences

OpenMW is GPLv3, OpenSceneGraph is OSGPL, gl4es is MIT. Modifications here inherit the
licence of the project they modify. No Bethesda game data is included or required by
this repository.
