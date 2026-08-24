# Where the source is and how to build it — OpenMW 0.51, TrimUI Smart Pro

## The three machines

| where | what | how to reach it |
|---|---|---|
| the PC | where commands are pasted | — |
| **the container** | Docker `openmw_builder` (ubuntu:20.04), holds every source tree and build | `docker exec openmw_builder …` (no sudo) |
| **the device** | TrimUI Smart Pro | `ssh root@192.168.1.25 …` |

`/root/*` paths are inside the container and are NOT visible from the PC's shell. Wrap every
command for the host it runs on.

## Source trees (inside the container)

| path | what | git |
|---|---|---|
| `/root/openmw-0.51-tsp-src` | OpenMW 0.51, patched | yes |
| `/root/gl4es-tsps` | the gl4es fork actually used | yes |
| `/root/tsp_diag.c`, `tsp_warm.c`, `tsp_fullscreen_scaler_v35.c`, `tsp_files.c` | LD_PRELOAD shims | no |
| `/root/tsp_openmw_controls.c` | controller/text helper, built by hand | no |
| `/root/tsp_patch_*.py` | idempotent patchers, replayable as a restore | no |
| `/root/rebuild_gl4es_tsps_o3.sh` | gl4es build | — |
| `/root/build_openmw_051_tsp_v4.sh` | full build — almost never the right tool | — |

**OpenSceneGraph is NOT patched.** Verified 2026-08-24: `/root/osg` has zero source
differences against `/root/osg.before-polygon-offset-patch` and contains no `TSP_` markers,
and `CMakeCache.txt` shows OpenMW linking `/usr/local/include` + `/usr/local/lib/libosg*.so`
— `/root/osg` is not in the build path at all. To reproduce this build you need **stock OSG
3.6.5 installed to `/usr/local`**.

Several decoy gl4es trees exist (`/root/gl4es`, `-export`, `-export-o3`, `-libbackup`, …).
**`/root/gl4es-tsps` is the live one.** Always grep it with `--include=*.c`; it is full of
`.before-<name>` backups whose stale content reads like live code.

## Finding what was changed

- Every patched file has a sibling `<file>.before-<name>-<stamp>` backup.
- Every change carries a `TSP_` marker, e.g. `TSP_MAXCOLORATTACH_FIX_20260824`,
  `TSP_RTT_INIT_TEXTURE_V55`, `TSP_NAVMESHDB_PATH_V54`.

## Building

OpenMW — incremental, and commit BEFORE building:

```sh
docker exec openmw_builder sh -c 'cd /root/openmw-0.51-tsp-src && git add -A && \
  (git diff --cached --quiet && echo "nothing to commit" || git commit -q -m "MARKER: what changed")'
docker exec openmw_builder cmake --build /root/openmw-0.51-tsp-build --target openmw -- -j2
```

Do not run the full build script, delete the build dir, or re-run cmake configure unless a
`CMakeLists.txt` changed or a file was added/removed.

gl4es — must be `bash`, not `sh` (uses `set -o pipefail`; the container's `sh` is dash and it
fails almost silently):

```sh
docker exec openmw_builder bash -c 'export MAKEFLAGS=-j4; bash /root/rebuild_gl4es_tsps_o3.sh'
```

Controller helper:

```sh
docker exec openmw_builder gcc-13 -Wall -Wextra -O2 -o /root/tsp_openmw_controls /root/tsp_openmw_controls.c
```

## Deploying

| artefact | built at | goes to |
|---|---|---|
| OpenMW | `/root/openmw-0.51-tsp-build/openmw` | `/mnt/SDCARD/data/ports/openmw51/bin/openmw-0.51` |
| gl4es | `/root/gl4es-tsps/lib/libGL.so.1` | `/mnt/SDCARD/data/ports/openmw51/lib/libGL.so.1` |
| helper | `/root/tsp_openmw_controls` | `/mnt/SDCARD/data/ports/openmw51/tsp_openmw_controls` |

`docker cp` out, grep the staged artefact for a string only the new behaviour produces, then
`ssh "cat > ….new"`, back up on the device, `mv` into place, `chmod +x`, re-verify. Chain
with `&&` so a failed build cannot reach the deploy.

`TSP_GL4ES_OVERRIDE` selects the libGL for one launcher entry only (`Morrowind_51.sh` ~943),
so an experimental library never has to replace `libGL.so.1`.

## Launchers

Main entry is `Morrowind_51`. Instrumented entries alongside it: `Morrowind_51_FBOSNAP`,
`_SNAP2`, `_FBODUMP`, `_NAVTEST`, plus a bisect ladder `GLA_aug04`…`GLH_aug18`. Always state
in words which entry to launch. A brand-new `.sh` filename may not appear in the device menu
— prefer overwriting an entry already there, backing it up first.

## Logs

- `config-0.51/openmw.log` — OpenMW `Log(Debug::*)`. Truncated every launch.
- `/mnt/SDCARD/tsp_prog.txt` — stdout/stderr, append mode.
- `$GAMEDIR/openmw_051_log.txt` — launcher's combined log.
- gl4es diagnostics go to `LIBGL_TSP_FBOPATH`.

**Never use `std::cerr`/`printf` for a liveness marker in OpenMW code** — OpenMW replaces
`std::cerr`'s stream buffer at startup and the line disappears. Use `Log(Debug::Warning)`.

## Proving what is running

```sh
ssh root@192.168.1.25 'cd /mnt/SDCARD/data/ports/openmw51
 grep -a -c TSP_MAXCOLORATTACH lib/libGL.so.1
 grep -a -c TSP_RTT_INIT_TEXTURE_V55 bin/openmw-0.51
 sha256sum bin/openmw-0.51 lib/libGL.so.1 tsp_openmw_controls'
```

Do not grep a binary for a build banner: `__DATE__`/`__TIME__` are separate string literals
from the format string, so `grep "built on Aug"` returns 0 on a library that prints exactly
that.

## Backup

`~/tsp_source_backup.sh` stages every edited file plus device config, docs and manifests into
`~/tsp-source-backup`. The push block re-stages only if that snapshot is over an hour old,
then pushes to `github.com/stefman69/openmwfortsp` branch `source-backup`. To force a fresh
capture: `rm -f ~/tsp-source-backup/manifests/SHA256SUMS.txt` first.
