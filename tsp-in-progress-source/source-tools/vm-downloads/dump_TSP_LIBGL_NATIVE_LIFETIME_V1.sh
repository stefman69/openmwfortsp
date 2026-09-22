#!/usr/bin/env bash
# dump_TSP_LIBGL_NATIVE_LIFETIME_V1.sh
#
# Big read-only dumper for the TSP PowerVR/OpenMW/gl4es resource-lifetime issue.
# It does NOT patch/build/install anything and does NOT arm in-game diagnostics.
#
# Run on the Ubuntu VM:
#   cd ~/Downloads
#   chmod +x dump_TSP_LIBGL_NATIVE_LIFETIME_V1.sh
#   ./dump_TSP_LIBGL_NATIVE_LIFETIME_V1.sh
#
# If the TSP IP changed:
#   ./dump_TSP_LIBGL_NATIVE_LIFETIME_V1.sh root@192.168.1.37

if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
    echo "ERROR: do not source this script; run it with ./$(basename "${BASH_SOURCE[0]}")"
    return 1
fi

set -u
set -o pipefail

HOST="${1:-${TSP_HOST:-root@192.168.1.21}}"
CONTAINER="${TSP_CONTAINER:-openmw_builder}"
GLSRC="${TSP_GL4ES_SRC:-/root/gl4es-tsps}"
OMWSRC="${TSP_OPENMW_SRC:-/root/openmw-0.51-tsp-src}"
OMWBUILD="${TSP_OPENMW_BUILD:-/root/openmw-0.51-tsp-build}"
GITHUB_URL="https://github.com/stefman69/openmwfortsp.git"

DL="$HOME/Downloads"
STAMP="$(date +%Y%m%d-%H%M%S)"
WORK="$DL/.tsp_libgl_native_lifetime_dump_$STAMP"
OUT="$DL/tsp_libgl_native_lifetime_dump_$STAMP.tar"
SOCK="/tmp/tsp-libgl-dump-$PPID-$$"

say_fatal() {
    echo
    echo "============================================================"
    echo "DUMPER ERROR"
    echo "============================================================"
    echo "$1"
    echo "Nothing was patched or installed."
    echo "Your terminal should remain open."
    echo "============================================================"
}

cleanup() {
    if [ -S "$SOCK" ] || [ -e "$SOCK" ]; then
        ssh -S "$SOCK" -O exit "$HOST" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT INT TERM HUP

mkdir -p "$DL" || { say_fatal "Could not create $DL"; exit 10; }
rm -rf "$WORK" 2>/dev/null || true
mkdir -p \
    "$WORK/00-summary" \
    "$WORK/10-vm" \
    "$WORK/20-gl4es-source" \
    "$WORK/21-gl4es-git" \
    "$WORK/22-gl4es-targeted" \
    "$WORK/23-gl4es-build" \
    "$WORK/30-openmw-targeted" \
    "$WORK/31-openmw-git" \
    "$WORK/40-device" \
    "$WORK/41-device-files" \
    "$WORK/42-device-binary-analysis" \
    "$WORK/50-crosschecks" || { say_fatal "Could not create working directory"; exit 11; }

echo "================================================================"
echo "TSP LIBGL / NATIVE RESOURCE LIFETIME BIG DUMPER V1"
echo "================================================================"
echo "Output:    $OUT"
echo "Device:    $HOST"
echo "Container: $CONTAINER"
echo "gl4es:     $GLSRC"
echo "OpenMW:    $OMWSRC"
echo
echo "READ-ONLY: no patch, no build, no install, no runtime diagnostic arming."
echo

# ---------------------------------------------------------------------------
# 0. AUTH FIRST: no waiting through a source dump only to discover SSH is dead.
# ---------------------------------------------------------------------------
echo "[0/12] DEVICE NETWORK + AUTHENTICATION PRECHECK"
echo "If SSH needs a password, enter it now; there should be no second prompt."
echo

if ! ssh -M -S "$SOCK" \
    -o ControlMaster=yes \
    -o ControlPersist=yes \
    -o ConnectTimeout=6 \
    -o ServerAliveInterval=30 \
    -o ServerAliveCountMax=6 \
    "$HOST" 'printf "TSP_SSH_PRECHECK_OK\n"'
then
    echo
    echo "SSH PRECHECK FAILED: $HOST"
    echo "'Network is unreachable' means the VM has no LAN route to that address."
    echo "VM IPv4 routes:"
    ip -4 route 2>/dev/null || true
    echo
    echo "From already-authenticated LobiShell on the TSP, get the current IP with:"
    echo "  ip -4 -o addr show scope global"
    say_fatal "Device precheck failed before any large dump started."
    exit 12
fi

echo "SSH PRECHECK: PASS"
echo

rssh() {
    ssh -S "$SOCK" -o BatchMode=yes "$HOST" "$@"
}

# ---------------------------------------------------------------------------
# 1. VM identity/toolchain
# ---------------------------------------------------------------------------
echo "[1/12] VM + toolchain identity"
{
    echo "collected=$(date -Is 2>/dev/null || date)"
    echo "host=$(hostname 2>/dev/null)"
    echo "user=$(id 2>/dev/null)"
    echo
    echo "===== uname ====="; uname -a 2>/dev/null || true
    echo "===== os-release ====="; cat /etc/os-release 2>/dev/null || true
    echo "===== addresses ====="; ip -4 addr 2>/dev/null || true
    echo "===== routes ====="; ip -4 route 2>/dev/null || true
    echo "===== output filesystem ====="; df -h "$DL" 2>/dev/null || true
    echo "===== tools ====="
    for x in docker git cmake ninja make gcc g++ readelf objdump nm strings tar sha256sum; do
        printf "%-12s " "$x"
        command -v "$x" 2>/dev/null || echo MISSING
    done
} > "$WORK/10-vm/vm-identity.txt" 2>&1

command -v docker >/dev/null 2>&1 || { say_fatal "docker is unavailable on the VM"; exit 20; }
docker inspect "$CONTAINER" >/dev/null 2>&1 || { say_fatal "container not found: $CONTAINER"; exit 21; }
docker inspect "$CONTAINER" > "$WORK/10-vm/docker-inspect.json" 2>&1 || true

# ---------------------------------------------------------------------------
# 2. Current gl4es source snapshot
# ---------------------------------------------------------------------------
echo "[2/12] Current gl4es source snapshot"
if ! docker exec "$CONTAINER" test -d "$GLSRC"; then
    say_fatal "gl4es source missing in container: $GLSRC"
    exit 22
fi

if ! docker exec "$CONTAINER" bash -c '
    SRC="$1"; BASE="$(dirname "$SRC")"; NAME="$(basename "$SRC")"
    tar -cf - \
      --exclude="$NAME/.git" \
      --exclude="$NAME/build" \
      --exclude="$NAME/build-*" \
      --exclude="*.o" \
      --exclude="*.a" \
      --exclude="CMakeFiles" \
      -C "$BASE" "$NAME"
' _ "$GLSRC" > "$WORK/20-gl4es-source/gl4es-current-source.tar"
then
    say_fatal "failed to stream current gl4es source tree"
    exit 23
fi

docker exec "$CONTAINER" bash -c '
    cd "$1" || exit 1
    find . -type f -not -path "./.git/*" -print0 | sort -z | xargs -0 sha256sum 2>/dev/null
' _ "$GLSRC" > "$WORK/20-gl4es-source/gl4es-source-sha256-manifest.txt" 2>&1 || true

docker exec "$CONTAINER" bash -c '
    cd "$1" || exit 1
    find . -type f -not -path "./.git/*" -printf "%p\t%s bytes\n" 2>/dev/null | sort
' _ "$GLSRC" > "$WORK/20-gl4es-source/gl4es-source-size-manifest.txt" 2>&1 || true

# ---------------------------------------------------------------------------
# 3. Git state, all uncommitted changes, history bundle
# ---------------------------------------------------------------------------
echo "[3/12] gl4es git state + diffs + history"
docker exec "$CONTAINER" bash -c '
    cd "$1" || exit 1
    echo "===== HEAD ====="; git rev-parse HEAD 2>&1 || true
    echo "===== BRANCH ====="; git branch -vv 2>&1 || true
    echo "===== STATUS ====="; git status --short --branch 2>&1 || true
    echo "===== REMOTES ====="; git remote -v 2>&1 || true
    echo "===== DESCRIBE ====="; git describe --always --dirty --tags 2>&1 || true
    echo "===== LAST 100 COMMITS ====="; git log -100 --decorate --date=iso --pretty=fuller 2>&1 || true
' _ "$GLSRC" > "$WORK/21-gl4es-git/gl4es-git-state.txt" 2>&1 || true

docker exec "$CONTAINER" bash -c 'cd "$1" && git diff --no-ext-diff --full-index --binary 2>&1 || true' _ "$GLSRC" \
    > "$WORK/21-gl4es-git/gl4es-working-tree.diff" 2>&1 || true

docker exec "$CONTAINER" bash -c 'cd "$1" && git diff --cached --no-ext-diff --full-index --binary 2>&1 || true' _ "$GLSRC" \
    > "$WORK/21-gl4es-git/gl4es-index.diff" 2>&1 || true

docker exec "$CONTAINER" bash -c 'cd "$1" && git log -100 --stat --oneline 2>&1 || true' _ "$GLSRC" \
    > "$WORK/21-gl4es-git/gl4es-log-stat.txt" 2>&1 || true

# Preserve reachable git history if this is a real git checkout.
docker exec "$CONTAINER" bash -c '
    cd "$1" || exit 1
    git bundle create /tmp/tsp-gl4es-history.bundle --all >/dev/null 2>&1 || exit 0
    cat /tmp/tsp-gl4es-history.bundle
    rm -f /tmp/tsp-gl4es-history.bundle
' _ "$GLSRC" > "$WORK/21-gl4es-git/gl4es-history.bundle" 2>/dev/null || true
[ -s "$WORK/21-gl4es-git/gl4es-history.bundle" ] || rm -f "$WORK/21-gl4es-git/gl4es-history.bundle"

# Optional public reference fingerprint. Failure is harmless.
{
    echo "github_url=$GITHUB_URL"
    echo "queried=$(date -Is 2>/dev/null || date)"
    git ls-remote "$GITHUB_URL" 2>&1 || true
} > "$WORK/21-gl4es-git/openmwfortsp-github-lsremote.txt"

# ---------------------------------------------------------------------------
# 4. Targeted lifetime/FBO/texture/PBO source reports
# ---------------------------------------------------------------------------
echo "[4/12] gl4es lifetime/FBO/texture/PBO source reports"
docker exec "$CONTAINER" bash -c '
    cd "$1" || exit 1
    grep -RInE "glGenFramebuffers|glDeleteFramebuffers|glGenRenderbuffers|glDeleteRenderbuffers|glRenderbufferStorage|glGenTextures|glDeleteTextures|gles_glGenTextures|gles_glDeleteTextures|renderdepth|renderstencil|secondarybuffer|secondarytexture|free_framebuffer|free_renderbuffer|free_texture|FRAMEBUFFER_BINDING|RENDERBUFFER_BINDING|GL_COLOR_ATTACHMENT|GL_DEPTH_ATTACHMENT|GL_STENCIL_ATTACHMENT" src 2>/dev/null || true
' _ "$GLSRC" > "$WORK/22-gl4es-targeted/native-resource-call-sites.txt" 2>&1

docker exec "$CONTAINER" bash -c '
    cd "$1" || exit 1
    grep -RInE "TSP_[A-Za-z0-9_]+|LIBGL_TSP_[A-Za-z0-9_]+|getenv\\(\"LIBGL_" src 2>/dev/null || true
' _ "$GLSRC" > "$WORK/22-gl4es-targeted/all-tsp-hooks-and-env-gates.txt" 2>&1

docker exec "$CONTAINER" bash -c '
    cd "$1" || exit 1
    grep -RInE "PIXEL_UNPACK_BUFFER|PIXEL_PACK_BUFFER|glBufferData|glDeleteBuffers|glMapBuffer|unpack|pack" src/gl src/glx 2>/dev/null || true
' _ "$GLSRC" > "$WORK/22-gl4es-targeted/pbo-buffer-call-sites.txt" 2>&1

docker exec "$CONTAINER" bash -c '
    cd "$1" || exit 1
    grep -RInE "pvrsrv|IMGTEC|PowerVR|VEND_IMGTEC|EGL|GLES|dlopen|dlsym" src 2>/dev/null || true
' _ "$GLSRC" > "$WORK/22-gl4es-targeted/powervr-loader-call-sites.txt" 2>&1

TARGET_FILES='src/gl/framebuffers.c
src/gl/framebuffers.h
src/gl/texture.c
src/gl/texture.h
src/gl/glstate.c
src/gl/glstate.h
src/gl/buffers.c
src/gl/buffers.h
src/gl/init.c
src/gl/init.h
src/gl/loader.c
src/gl/loader.h
src/gl/wrap/gles.c
src/gl/gl_lookup.c
src/glx/hardext.c
src/glx/hardext.h
src/glx/glx.c
src/glx/glx.h
src/loader/loader.c
src/loader/loader.h
CMakeLists.txt
COMPILE.md
USAGE.md'
while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    safe="$(printf '%s' "$rel" | tr '/' '_')"
    docker exec "$CONTAINER" bash -c '[ -f "$1/$2" ] && cat "$1/$2"' _ "$GLSRC" "$rel" \
        > "$WORK/22-gl4es-targeted/$safe" 2>/dev/null || true
    [ -s "$WORK/22-gl4es-targeted/$safe" ] || rm -f "$WORK/22-gl4es-targeted/$safe"
done <<< "$TARGET_FILES"

# ---------------------------------------------------------------------------
# 5. Build configuration/current built lib candidates
# ---------------------------------------------------------------------------
echo "[5/12] gl4es build configuration + current built library hashes"
docker exec "$CONTAINER" bash -c '
    echo "===== rebuild scripts ====="
    find /root -maxdepth 2 -type f \( -name "*gl4es*.sh" -o -name "*GL4ES*.sh" -o -name "rebuild*.sh" \) -print 2>/dev/null | sort
    echo "===== cmake caches ====="
    find /root -maxdepth 5 -type f -name CMakeCache.txt -path "*gl4es*" -print 2>/dev/null | sort
    echo "===== compile_commands ====="
    find /root -maxdepth 5 -type f -name compile_commands.json -path "*gl4es*" -print 2>/dev/null | sort
    echo "===== libGL candidates ====="
    find /root -maxdepth 7 -type f \( -name "libGL.so" -o -name "libGL.so.1" -o -name "libGL.so.*" \) -print 2>/dev/null | sort
' > "$WORK/23-gl4es-build/build-paths.txt" 2>&1 || true

docker exec "$CONTAINER" bash -c '
    find /root -maxdepth 7 -type f \( -name "libGL.so" -o -name "libGL.so.1" -o -name "libGL.so.*" \) -print 2>/dev/null | sort | while read -r f; do
        printf "%s\t" "$f"; sha256sum "$f" 2>/dev/null | cut -d" " -f1
    done
' > "$WORK/23-gl4es-build/container-libgl-hashes.txt" 2>&1 || true

docker exec "$CONTAINER" bash -c '
    TMP=/tmp/tsp-gl4es-build-meta.$$
    rm -rf "$TMP"; mkdir -p "$TMP"
    n=0
    {
      find /root -maxdepth 2 -type f \( -name "*gl4es*.sh" -o -name "*GL4ES*.sh" -o -name "rebuild*.sh" \) 2>/dev/null
      find /root -maxdepth 5 -type f -name CMakeCache.txt -path "*gl4es*" 2>/dev/null
      find /root -maxdepth 5 -type f -name compile_commands.json -path "*gl4es*" 2>/dev/null
    } | sort -u | while read -r f; do
      [ -f "$f" ] || continue
      n=$((n+1)); cp -p "$f" "$TMP/$(printf "%03d" "$n")-$(basename "$f")" 2>/dev/null || true
      printf "%s\n" "$f" >> "$TMP/paths.txt"
    done
    tar -cf - -C "$TMP" .
    rm -rf "$TMP"
' > "$WORK/23-gl4es-build/gl4es-build-metadata.tar" 2>/dev/null || true

# ---------------------------------------------------------------------------
# 6. OpenMW reload/RTT/resource cleanup context
# ---------------------------------------------------------------------------
echo "[6/12] OpenMW reload/RTT/resource-lifetime source context"
if docker exec "$CONTAINER" test -d "$OMWSRC"; then
    docker exec "$CONTAINER" bash -c '
        cd "$1" || exit 1
        echo "===== HEAD ====="; git rev-parse HEAD 2>&1 || true
        echo "===== STATUS ====="; git status --short --branch 2>&1 || true
        echo "===== REMOTES ====="; git remote -v 2>&1 || true
        echo "===== LOG ====="; git log -40 --decorate --oneline 2>&1 || true
    ' _ "$OMWSRC" > "$WORK/31-openmw-git/openmw-git-state.txt" 2>&1 || true

    docker exec "$CONTAINER" bash -c 'cd "$1" && git diff --no-ext-diff --full-index 2>&1 || true' _ "$OMWSRC" \
        > "$WORK/31-openmw-git/openmw-working-tree.diff" 2>&1 || true

    docker exec "$CONTAINER" bash -c '
        cd "$1" || exit 1
        grep -RInE "TSP_LOADPURGE|TSP_NO_LOADPURGE|releaseGLObjects|clearCache|TSP_GMAP_|TSP_RTT_|mLocalMapRTTs|PixelBufferObject|createFogOfWarTexture|cleanupCameras|requestOverlayTextureUpdate" apps components 2>/dev/null || true
    ' _ "$OMWSRC" > "$WORK/30-openmw-targeted/openmw-reload-rtt-call-sites.txt" 2>&1 || true

    OMW_FILES='apps/openmw/mwstate/statemanager.cpp
apps/openmw/mwrender/localmap.cpp
apps/openmw/mwrender/localmap.hpp
apps/openmw/mwrender/globalmap.cpp
apps/openmw/mwrender/globalmap.hpp
apps/openmw/mwgui/mapwindow.cpp
components/sceneutil/rtt.cpp
components/sceneutil/rtt.hpp
components/resource/resourcesystem.cpp
components/resource/resourcesystem.hpp'
    while IFS= read -r rel; do
        [ -n "$rel" ] || continue
        safe="$(printf '%s' "$rel" | tr '/' '_')"
        docker exec "$CONTAINER" bash -c '[ -f "$1/$2" ] && cat "$1/$2"' _ "$OMWSRC" "$rel" \
            > "$WORK/30-openmw-targeted/$safe" 2>/dev/null || true
        [ -s "$WORK/30-openmw-targeted/$safe" ] || rm -f "$WORK/30-openmw-targeted/$safe"
    done <<< "$OMW_FILES"
else
    echo "MISSING: $OMWSRC" > "$WORK/30-openmw-targeted/OPENMW_SOURCE_MISSING.txt"
fi

# ---------------------------------------------------------------------------
# 7. TSP system/PVR/slab context
# ---------------------------------------------------------------------------
echo "[7/12] TSP kernel + PowerVR + allocator context"
rssh 'sh -s' > "$WORK/40-device/device-system.txt" 2>&1 <<'REMOTE'
echo "===== DATE ====="; date 2>/dev/null || true
echo "===== UNAME ====="; uname -a 2>/dev/null || true
echo "===== OS RELEASE ====="; cat /etc/os-release 2>/dev/null || true
echo "===== CPU ====="; cat /proc/cpuinfo 2>/dev/null || true
echo "===== MODULES ====="; cat /proc/modules 2>/dev/null || true
echo "===== PVR MODINFO ====="; modinfo pvrsrvkm 2>/dev/null || true
echo "===== ZRAM/ZSMALLOC MODINFO ====="; modinfo zram 2>/dev/null || true; modinfo zsmalloc 2>/dev/null || true
echo "===== SWAPS ====="; cat /proc/swaps 2>/dev/null || true
echo "===== ZRAM ====="; zramctl 2>/dev/null || true
echo "===== MEMINFO ====="; cat /proc/meminfo 2>/dev/null || true
echo "===== VMSTAT ====="; grep -E '^(pgmajfault|pswpin|pswpout|pgscan_|pgsteal_|allocstall|compact_|oom_kill)' /proc/vmstat 2>/dev/null || true
echo "===== BUDDYINFO ====="; cat /proc/buddyinfo 2>/dev/null || true
echo "===== ZONEINFO ====="; cat /proc/zoneinfo 2>/dev/null || true
echo "===== PAGETYPEINFO ====="; cat /proc/pagetypeinfo 2>/dev/null || true
echo "===== PVR-LIKE SLABS ====="; grep -Ei 'pvr|img|gpu|dma|drm|ion|buffer|page' /proc/slabinfo 2>/dev/null || true
echo "===== DMA-BUF / ION DEBUG ====="
for f in /sys/kernel/debug/dma_buf/bufinfo /proc/dma_buf/bufinfo /sys/kernel/debug/ion/heaps/* /proc/ion/*; do
  [ -r "$f" ] || continue
  echo "--- $f ---"
  head -c 1048576 "$f" 2>/dev/null || true
  echo
 done
echo "===== VMALLOC PVR/IMG/GPU ====="; grep -Ei 'pvr|img|gpu|dma|ion' /proc/vmallocinfo 2>/dev/null || true
echo "===== PVR MODULE PARAMETERS ====="
if [ -d /sys/module/pvrsrvkm/parameters ]; then
  for f in /sys/module/pvrsrvkm/parameters/*; do
    [ -f "$f" ] || continue
    printf "%s=" "$f"; cat "$f" 2>/dev/null || echo '<unreadable>'
  done
fi
echo "===== PVR PROC/SYS NODES ====="
find /proc /sys -maxdepth 5 \( -iname '*pvr*' -o -iname '*powervr*' -o -iname '*imgtec*' \) -print 2>/dev/null | head -n 2000 || true
echo "===== READABLE PVR PROC/SYS TEXT (CAPPED) ====="
find /proc /sys -maxdepth 6 -type f \( -ipath '*pvr*' -o -ipath '*powervr*' -o -ipath '*imgtec*' \) -print 2>/dev/null | head -n 500 | while read -r f; do
  [ -r "$f" ] || continue
  echo "--- $f ---"
  head -c 262144 "$f" 2>/dev/null || true
  echo
 done
echo "===== DMESG PVR/MEMORY ====="
dmesg 2>/dev/null | grep -Ei 'pvr|powervr|imgtec|gpu|dma|iommu|cma|zram|zsmalloc|oom|allocation|compact|migrate' | tail -n 5000 || true
REMOTE
rssh 'dmesg 2>/dev/null || true' > "$WORK/40-device/dmesg-full.txt" 2>&1 || true
rssh 'cat /proc/slabinfo 2>/dev/null || true' > "$WORK/40-device/slabinfo-full.txt" 2>&1 || true

# ---------------------------------------------------------------------------
# 8. Installed libGL, launchers, sidecars and native PVR/GLES userspace libs
# ---------------------------------------------------------------------------
echo "[8/12] Installed libGL + launchers + native GLES/PVR libraries"
rssh 'sh -s' > "$WORK/40-device/device-gl-inventory.txt" 2>&1 <<'REMOTE'
ROOT="/mnt/mmc/ports/openmw"
PORTS="/mnt/mmc/ROMS/Ports"
echo "===== OPENMW LIBGL FILES ====="
find "$ROOT" -maxdepth 3 \( -type f -o -type l \) -name 'libGL.so*' -print 2>/dev/null | sort | while read -r f; do
  ls -l "$f" 2>/dev/null || true; sha256sum "$f" 2>/dev/null || true; file "$f" 2>/dev/null || true; echo
done
echo "===== OPENMW BINARIES ====="
find "$ROOT/bin" -maxdepth 1 -type f -name 'openmw*' -print 2>/dev/null | sort | while read -r f; do
  ls -lh "$f" 2>/dev/null || true; sha256sum "$f" 2>/dev/null || true
done
echo "===== RELEVANT LAUNCHERS ====="
for f in \
 "$PORTS/Morrowind-AUTO-MONITOR-NATIVE-ZRAM-V4.sh" \
 "$PORTS/Morrowind-TSP-MAP-DIAG-AUTO-V8.sh" \
 "$PORTS/Morrowind-TSP-FOG-NOPBO-DIAG-V9.sh" \
 "$PORTS/Morrowind-TSP-LOADPURGE-DIAG-V10.sh"; do
  [ -f "$f" ] || continue; sha256sum "$f" 2>/dev/null || true; ls -lh "$f" 2>/dev/null || true
done
echo "===== RELEVANT LAUNCHER ENV EXPORTS ====="
for f in \
 "$PORTS/Morrowind-AUTO-MONITOR-NATIVE-ZRAM-V4.sh" \
 "$PORTS/Morrowind-TSP-MAP-DIAG-AUTO-V8.sh" \
 "$PORTS/Morrowind-TSP-FOG-NOPBO-DIAG-V9.sh" \
 "$PORTS/Morrowind-TSP-LOADPURGE-DIAG-V10.sh"; do
  [ -f "$f" ] || continue
  echo "--- $f ---"
  grep -nE '(^|[[:space:]])(export|unset)[[:space:]]+(LIBGL|TSP_|OPENMW_)|LD_LIBRARY_PATH|TSP_GL4ES_LIBRARY' "$f" 2>/dev/null || true
done
echo "===== NATIVE EGL/GLES/PVR CANDIDATES ====="
for base in /lib /usr/lib /usr/local/lib /opt /vendor/lib /system/lib; do
  [ -d "$base" ] || continue
  find "$base" -maxdepth 6 \( -type f -o -type l \) \
    \( -name 'libEGL.so*' -o -name 'libGLESv1_CM.so*' -o -name 'libGLESv2.so*' \
       -o -name 'libIMGegl.so*' -o -name 'libsrv_um.so*' -o -name 'libsrv_init.so*' \
       -o -name 'libusc.so*' -o -name 'libglslcompiler.so*' -o -name 'libpvr2d.so*' \
       -o -name 'libPVRScopeServices.so*' \) -print 2>/dev/null
done | sort -u | while read -r f; do
  ls -l "$f" 2>/dev/null || true; sha256sum "$f" 2>/dev/null || true; file "$f" 2>/dev/null || true; echo
done
echo "===== PVR KERNEL MODULE ====="
PVRKO="$(modinfo -n pvrsrvkm 2>/dev/null)"; [ -f "$PVRKO" ] && { ls -lh "$PVRKO"; sha256sum "$PVRKO"; }
REMOTE

# Stream selected device files directly; no persistent device-side archive.
if ! rssh 'sh -s' > "$WORK/41-device-files/device-selected-files.tar" <<'REMOTE'
ROOT="/mnt/mmc/ports/openmw"
PORTS="/mnt/mmc/ROMS/Ports"
LIST="/tmp/tsp_libgl_dump_list.$$"
: > "$LIST"
add_rel(){ p="$1"; [ -e "$p" ] || return 0; case "$p" in /*) printf '%s\n' "${p#/}" >> "$LIST";; esac; }
add_rel "$ROOT/lib/libGL.so.1"
add_rel "$ROOT/bin/openmw-0.51"
add_rel "$ROOT/bin/openmw-0.51.tsp-fog-nopbo-v1"
add_rel "$ROOT/tsp_zram_portable.sh"
add_rel "$ROOT/openmw_log.txt"
for d in "$ROOT"/lib.tsp-*; do [ -e "$d" ] && add_rel "$d"; done
for f in \
 "$PORTS/Morrowind-AUTO-MONITOR-NATIVE-ZRAM-V4.sh" \
 "$PORTS/Morrowind-TSP-MAP-DIAG-AUTO-V8.sh" \
 "$PORTS/Morrowind-TSP-FOG-NOPBO-DIAG-V9.sh" \
 "$PORTS/Morrowind-TSP-LOADPURGE-DIAG-V10.sh"; do add_rel "$f"; done
[ -d "$ROOT/tsp_map_diag/latest" ] && add_rel "$ROOT/tsp_map_diag/latest"
[ -d "$ROOT/tsp_freeze_monitor/latest" ] && add_rel "$ROOT/tsp_freeze_monitor/latest"
for base in /lib /usr/lib /usr/local/lib /opt /vendor/lib /system/lib; do
  [ -d "$base" ] || continue
  find "$base" -maxdepth 6 \( -type f -o -type l \) \
    \( -name 'libEGL.so*' -o -name 'libGLESv1_CM.so*' -o -name 'libGLESv2.so*' \
       -o -name 'libIMGegl.so*' -o -name 'libsrv_um.so*' -o -name 'libsrv_init.so*' \
       -o -name 'libusc.so*' -o -name 'libglslcompiler.so*' -o -name 'libpvr2d.so*' \
       -o -name 'libPVRScopeServices.so*' \) -print 2>/dev/null | while read -r f; do add_rel "$f"; done
done
PVRKO="$(modinfo -n pvrsrvkm 2>/dev/null)"; [ -f "$PVRKO" ] && add_rel "$PVRKO"
sort -u "$LIST" -o "$LIST"
cd / || { rm -f "$LIST"; exit 4; }
tar -cf - -T "$LIST"
rc=$?
rm -f "$LIST"
exit "$rc"
REMOTE
then
    echo "WARNING: selected device-file stream failed; metadata capture continues." >&2
fi

EX="$WORK/41-device-files/extracted"
mkdir -p "$EX"
if [ -s "$WORK/41-device-files/device-selected-files.tar" ]; then
    tar -xf "$WORK/41-device-files/device-selected-files.tar" -C "$EX" 2>/dev/null || true
else
    rm -f "$WORK/41-device-files/device-selected-files.tar"
fi

# ---------------------------------------------------------------------------
# 9. Local ELF analysis of captured installed libGL and PVR userspace libs
# ---------------------------------------------------------------------------
echo "[9/12] ELF/symbol/string analysis of captured libGL + driver libraries"
analyze_elf(){
    f="$1"; tag="$2"; od="$WORK/42-device-binary-analysis/$tag"; mkdir -p "$od"
    { echo "file=$f"; ls -lh "$f" 2>/dev/null || true; sha256sum "$f" 2>/dev/null || true; file "$f" 2>/dev/null || true; } > "$od/identity.txt" 2>&1
    readelf -h "$f" > "$od/readelf-header.txt" 2>&1 || true
    readelf -l "$f" > "$od/readelf-program-headers.txt" 2>&1 || true
    readelf -S "$f" > "$od/readelf-sections.txt" 2>&1 || true
    readelf -d "$f" > "$od/readelf-dynamic.txt" 2>&1 || true
    readelf -Ws "$f" > "$od/readelf-symbols.txt" 2>&1 || true
    readelf -r "$f" > "$od/readelf-relocations.txt" 2>&1 || true
    readelf -n "$f" > "$od/readelf-notes.txt" 2>&1 || true
    nm -D -a "$f" > "$od/nm-dynamic.txt" 2>&1 || true
    objdump -T "$f" > "$od/objdump-dynamic-symbols.txt" 2>&1 || true
    strings -a "$f" > "$od/strings.txt" 2>&1 || true
    grep -Ei 'TSP_|LIBGL_|Framebuffer|Renderbuffer|Texture|PowerVR|IMGTEC|pvrsrv|glDelete|glGen|EGL|GLES' "$od/strings.txt" > "$od/strings-relevant.txt" 2>/dev/null || true
    grep -Ei 'gl(Gen|Delete)(Framebuffers|Renderbuffers|Textures)|glRenderbufferStorage|glFramebuffer|glTexImage' "$od/readelf-symbols.txt" > "$od/resource-symbols.txt" 2>/dev/null || true
}

PROD_GL="$EX/mnt/mmc/ports/openmw/lib/libGL.so.1"
if [ -f "$PROD_GL" ]; then analyze_elf "$PROD_GL" production-libGL; fi

if [ -d "$EX/mnt/mmc/ports/openmw" ]; then
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    rel="${f#$EX/}"; tag="$(printf '%s' "$rel" | tr '/ ' '__')"; analyze_elf "$f" "$tag"
  done < <(find "$EX/mnt/mmc/ports/openmw" -maxdepth 4 -type f -name 'libGL.so*' 2>/dev/null | sort)
fi

while IFS= read -r f; do
  [ -f "$f" ] || continue
  rel="${f#$EX/}"; tag="driver-$(printf '%s' "$rel" | tr '/ ' '__')"; analyze_elf "$f" "$tag"
done < <(find "$EX" -type f \( -name 'libEGL.so*' -o -name 'libGLESv1_CM.so*' -o -name 'libGLESv2.so*' -o -name 'libIMGegl.so*' -o -name 'libsrv_um.so*' -o -name 'libusc.so*' -o -name 'libglslcompiler.so*' -o -name 'libpvr2d.so*' -o -name 'libPVRScopeServices.so*' \) 2>/dev/null | sort)

while IFS= read -r f; do
  [ -f "$f" ] || continue
  rel="${f#$EX/}"; tag="kernel-$(printf '%s' "$rel" | tr '/ ' '__')"; analyze_elf "$f" "$tag"
done < <(find "$EX" -type f -name 'pvrsrvkm*.ko*' 2>/dev/null | sort)

# ---------------------------------------------------------------------------
# 10. Crosschecks + fork contract
# ---------------------------------------------------------------------------
echo "[10/12] Crosschecks + isolated-fork contract"
{
  echo "===== DEVICE PRODUCTION LIBGL ====="
  [ -f "$PROD_GL" ] && { sha256sum "$PROD_GL"; file "$PROD_GL" 2>/dev/null || true; } || echo MISSING
  echo "===== CONTAINER LIBGL CANDIDATES ====="
  cat "$WORK/23-gl4es-build/container-libgl-hashes.txt" 2>/dev/null || true
  echo "===== CURRENT GL4ES HEAD/STATUS ====="
  sed -n '1,180p' "$WORK/21-gl4es-git/gl4es-git-state.txt" 2>/dev/null || true
  echo "===== IMPORTANT COMPILED MARKERS ====="
  grep -E 'TSP_FBO|TSP_DRAWFBO|TSP_ATTACH|TSP_MAXCOLOR|TSP_TEX|TSP_|LIBGL_TSP' "$WORK/42-device-binary-analysis/production-libGL/strings-relevant.txt" 2>/dev/null || true
} > "$WORK/50-crosschecks/source-vs-device-summary.txt" 2>&1

cat > "$WORK/00-summary/NEXT-FORK-CONTRACT.txt" <<'CONTRACT'
TSP POWER-VR LIBGL FORK CONTRACT
===============================

The next libGL patch must be a NEW TSP-only fork.

VM/source isolation
-------------------
Do not edit the production gl4es tree in place for the experiment.
Create a dedicated fork/worktree/copy, e.g.:
  /root/gl4es-tsp-pvr-lifetime-v1

Device isolation
----------------
Production (unchanged):
  /mnt/mmc/ports/openmw/lib/libGL.so.1

New original-TSP/PowerVR sidecar:
  /mnt/mmc/ports/openmw/lib.tsp-pvr-lifetime-v1/libGL.so.1

The launcher must positively identify original TSP / PowerVR before selecting
that sidecar. TSPS/Mali continues to use production lib/libGL.so.1.

Fix vs diagnostics
------------------
The actual TSP lifetime fix may stay enabled in the TSP fork.
Diagnostic logging/introspection must be separately launcher-gated.

Proposed runtime diagnostic gate:
  LIBGL_TSP_NATIVE_LIFE=1
  LIBGL_TSP_NATIVE_LIFE_PATH=<log path>

When LIBGL_TSP_NATIVE_LIFE is absent/0:
  - no diagnostic file writes
  - no native attachment queries
  - no per-draw diagnostic work
  - no hashes
  - no /proc or sysfs scans
  - at most a cached boolean check at RESOURCE CREATE/DELETE operations

When explicitly armed, track the native GLES boundary:
  glGenFramebuffers / glDeleteFramebuffers
  glGenRenderbuffers / glDeleteRenderbuffers
  glRenderbufferStorage dimensions/format/estimated bytes
  native glGenTextures / native glDeleteTextures
  gl4es-created renderdepth/renderstencil/secondarybuffer/secondarytexture

Maintain live counters and byte estimates so each OpenMW reload generation can
be compared with cleanup-done memory and SUnreclaim growth.

This branch is for code/resource lifetime repair in:
  OpenMW -> gl4es -> native PowerVR GLES -> pvrsrvkm
It is not a settings-tuning branch.
CONTRACT

# ---------------------------------------------------------------------------
# 11. Manifest
# ---------------------------------------------------------------------------
echo "[11/12] Manifest + summary"
cat > "$WORK/00-summary/README-FIRST.txt" <<EOF
TSP_LIBGL_NATIVE_LIFETIME_DUMP_V1
collected=$(date -Is 2>/dev/null || date)
device=$HOST
container=$CONTAINER
gl4es_source=$GLSRC
openmw_source=$OMWSRC
github_reference=$GITHUB_URL

No game runtime diagnostics were enabled by this dumper.
No TSP files were patched or installed.

Main contents:
  20-gl4es-source/gl4es-current-source.tar
  21-gl4es-git/              git state/history/diffs
  22-gl4es-targeted/         FBO/RB/texture/PBO source
  23-gl4es-build/            build configuration/hashes
  30-openmw-targeted/        reload/RTT/resource source
  40-device/                 kernel/PVR/slab context
  41-device-files/           installed libGL/PVR userspace libs
  42-device-binary-analysis/ readelf/nm/strings
  50-crosschecks/            source-vs-installed checks
  00-summary/NEXT-FORK-CONTRACT.txt
EOF
(
  cd "$WORK" || exit 1
  find . -type f -print0 | sort -z | xargs -0 sha256sum
) > "$WORK/00-summary/all-files-sha256.txt" 2>&1 || true
du -ah "$WORK" 2>/dev/null | sort -h > "$WORK/00-summary/all-files-sizes.txt" || true

# ---------------------------------------------------------------------------
# 12. Final archive
# ---------------------------------------------------------------------------
echo "[12/12] Building final archive"
rm -f "$OUT" 2>/dev/null || true
if ! tar -cf "$OUT" -C "$WORK" .; then
  say_fatal "Final tar creation failed. Working data remains at $WORK"
  exit 40
fi
if ! tar -tf "$OUT" >/dev/null 2>&1; then
  say_fatal "Final archive failed verification: $OUT"
  exit 41
fi
sync 2>/dev/null || true

echo
echo "================================================================"
echo "BIG DUMPER COMPLETE"
echo "================================================================"
echo "File:"
echo "$OUT"
echo
echo "SHA256:"
sha256sum "$OUT" 2>/dev/null || true
echo
echo "Size:"
ls -lh "$OUT" 2>/dev/null || true
echo
echo "Verification: PASS"
echo "No patch/build/install occurred and no in-game diagnostics were armed."
echo "Upload this one tar here."
echo "================================================================"
