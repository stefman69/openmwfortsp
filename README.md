# TrimUI Smart Pro - OpenMW 0.51 port

Exported from the `openmw_builder` container on 20260816-155353.

## Layout

- `sources/`    source trees (no build dirs, no `.before-*` backups)
- `scripts/`    build and patch scripts from `/root`
- `patches/`    `git diff` per repo - the record of local modifications
- `manifests/`  git HEADs, TSP marker map, tree listing, toolchain info

## Key fixes in this build

**Texture wobble (resolved).** `gl4es` `GetHardwareExtensions()` begins with
`if(tested) return;`. With `LIBGL_NOTEST=1` - which this device requires, since
probing at init blue-screens it - the flag was set without any detection
running, leaving every `hardext` capability at 0. A Mali-G57 was being driven
as the weakest possible GLES2 device: no depth24, no packed depth stencil, no
derivatives, no NPOT. `TSP_EXTFLAGS` in `src/glx/hardext.c` sets the flags from
the real extension string at first shader compile.

**Distant terrain (partial).** Composite-map FBOs were reporting
`GL_FRAMEBUFFER_INCOMPLETE_MISSING_ATTACHMENT`. Fixed so far: renderable colour
format, depth attachment, read/draw target normalisation, `fbo_read` sync.
Complete framebuffers went 14 -> 440; roughly 25% of terrain renders. The
remainder is still under investigation.

## Env toggles

| var | effect |
|---|---|
| `LIBGL_NOTEST=1` | required - probing at init blue-screens the device |
| `LIBGL_TSP_LATEDETECT=1` | run detection at first shader compile |
| `LIBGL_TSP_RTTDEPTH=0` | 16-bit RTT depth (original) |
| `LIBGL_TSP_NODOWNGRADE=1` | bypass the IMGTEC DEPTH24_STENCIL8 downgrade |
| `LIBGL_TSP_FBNORM=0` | disable read/draw target normalisation |
| `LIBGL_TSP_BINDSYNC=0` | disable `fbo_read` sync |
