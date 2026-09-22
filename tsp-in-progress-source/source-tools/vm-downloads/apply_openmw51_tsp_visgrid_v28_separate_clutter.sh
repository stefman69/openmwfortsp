#!/usr/bin/env bash
set -Eeuo pipefail

ACTION="${1:-install}"
CTR="${OPENMW_CONTAINER:-openmw_builder}"
DEV="${TSP_DEVICE:-root@192.168.1.25}"

SRC=/root/openmw-0.51-tsp-src
BUILD=/root/openmw-0.51-tsp-build
PACKAGE=/root/openmw-0.51-tsp-package
SCENE_CPP="$SRC/apps/openmw/mwworld/scene.cpp"
VIS_CPP="$SRC/apps/openmw/mwrender/interiorvisibility.cpp"
VIS_HPP="$SRC/apps/openmw/mwrender/interiorvisibility.hpp"
CAMERA="$SRC/apps/openmw/mwlua/camerabindings.cpp"
ANIM="$SRC/apps/openmw/mwrender/animation.cpp"
BUILT="$BUILD/openmw"
PACKAGED="$PACKAGE/bin/openmw-0.51"

ROOT=/mnt/SDCARD/data/ports/openmw51
REMOTE_BIN="$ROOT/bin/openmw-0.51"
LUA_DIR="$ROOT/mods/TSPInteriorVisGrid/scripts/TSPInteriorVisGrid"
LIVE_LUA="$LUA_DIR/visgrid.lua"
V27_PROFILE="$LUA_DIR/v27_profiles/visgrid-v27-adaptive-clutter.lua"
V28_DIR="$LUA_DIR/v28_profiles"
V28_PROFILE="$V28_DIR/visgrid-v28-separate-clutter.lua"
REMOTE_TMP_BIN=/tmp/openmw-0.51.v28-separate-clutter

DL="$HOME/Downloads"
HOST_BIN="$DL/openmw-0.51-v28-separate-clutter"
STATE="$DL/openmw51-visgrid-v28-separate-clutter.state"
STAMP="$(date +%Y%m%d-%H%M%S)"
LOG="$DL/openmw51-visgrid-v28-separate-clutter-$STAMP.log"
TMP="$(mktemp -d "$DL/.v28-separate-clutter.XXXXXX")"
SOURCE_BACKUP=""
DEVICE_BACKUP=""
DEVICE_DEPLOY_STARTED=0
LAUNCHER=""

cleanup(){ rm -rf "$TMP" 2>/dev/null || true; }
trap cleanup EXIT

die(){ echo "ERROR: $*" >&2; exit 1; }

ensure_docker(){
    command -v docker >/dev/null 2>&1 || die "docker not found"
    docker inspect "$CTR" >/dev/null 2>&1 || die "Docker container '$CTR' not found"
    if [ "$(docker inspect -f '{{.State.Running}}' "$CTR")" != true ]; then
        docker start "$CTR" >/dev/null
    fi
}

ensure_ssh(){
    command -v ssh >/dev/null 2>&1 || die "ssh not found"
    command -v scp >/dev/null 2>&1 || die "scp not found"
    ssh -o BatchMode=yes -o ConnectTimeout=8 "$DEV" true || die "cannot reach $DEV"
}

game_closed(){
    ! ssh "$DEV" "pgrep -af 'openmw-0\.51|/openmw([[:space:]]|$)' 2>/dev/null" | grep -v pgrep
}

locate_launcher(){
    ssh "$DEV" 'bash -s' <<'REMOTE'
for p in \
  /mnt/SDCARD/Roms/PORTS/Morrowind_51.sh \
  /mnt/SDCARD/Emus/PORTS/../../Roms/PORTS/Morrowind_51.sh \
  /mnt/SDCARD/roms/ports/Morrowind_51.sh
 do
   [ -f "$p" ] || continue
   readlink -f "$p" 2>/dev/null || printf '%s\n' "$p"
   exit 0
 done
exit 1
REMOTE
}

restore_source(){
    [ -n "${SOURCE_BACKUP:-}" ] || return 0
    docker exec "$CTR" bash -lc "set -e
      cp -pf '$SOURCE_BACKUP/scene.cpp' '$SCENE_CPP'
      cp -pf '$SOURCE_BACKUP/interiorvisibility.cpp' '$VIS_CPP'
      cp -pf '$SOURCE_BACKUP/interiorvisibility.hpp' '$VIS_HPP'
      cp -pf '$SOURCE_BACKUP/camerabindings.cpp' '$CAMERA'"
}

restore_device(){
    [ -n "${DEVICE_BACKUP:-}" ] || return 0
    ssh "$DEV" "bash -s" <<REMOTE
set -e
B='$DEVICE_BACKUP'

require_backup() {
  if [ ! -s "\$1" ]; then
    echo "FAIL rollback backup missing/empty: \$1" >&2
    exit 61
  fi
  echo "PASS rollback backup: \$1"
}

require_backup "\$B/openmw-0.51.before"
require_backup "\$B/visgrid.lua.before"
require_backup "\$B/launcher.before"

cp -pf "\$B/openmw-0.51.before" '$REMOTE_BIN'
cp -pf "\$B/visgrid.lua.before" '$LIVE_LUA'
cp -pf "\$B/launcher.before" '$LAUNCHER'
if [ -f "\$B/v28-profile.existed" ]; then
  mkdir -p '$V28_DIR'
  cp -pf "\$B/v28-profile.before" '$V28_PROFILE'
else
  rm -f '$V28_PROFILE'
fi
chmod 755 '$REMOTE_BIN' '$LAUNCHER'
sync
REMOTE
}

collect_latest(){
    ensure_ssh
    OUT="$DL/openmw51-visgrid-v28-separate-clutter-validation-$STAMP.txt"
    ssh "$DEV" "ROOT='$ROOT' bash -s" <<'REMOTE' > "$OUT"
set +e
printf '%s\n' '============================================================'
printf '%s\n' 'OPENMW 0.51 V28 SEPARATE CLUTTER MANUAL CAPTURE'
printf '%s\n' '============================================================'
date
printf '\n===== IDENTITY =====\n'
sha256sum "$ROOT/bin/openmw-0.51" \
  "$ROOT/mods/TSPInteriorVisGrid/scripts/TSPInteriorVisGrid/visgrid.lua" 2>/dev/null || true

RAW=/tmp/v28-manual-capture.$$
: > "$RAW"
for f in "$ROOT/openmw_051_log.txt" "$ROOT/config-0.51/openmw.log" "$ROOT/openmw.log"; do
  [ -s "$f" ] || continue
  tail -n 14000 "$f" >> "$RAW"
done

printf '\n===== V28 CLUTTER AUTHORITY =====\n'
grep -E '\[TSP_VISGRID_V28\] clutter|\[TSP_ROOMOBJ_V28\]|\[TSP_CLUTTER_V28\]' "$RAW" | tail -160 || true

printf '\n===== OLD STRUCTURAL / FOG STATE (SEPARATE ON PURPOSE) =====\n'
grep -E 'TSP_INTERIOR_VISGRID_051_V5_TOPO_PVS|TSP_INTERIOR_VISGRID_051_V3_PERCENTILE_FOG|TSP_INTERIOR_VISGRID_051_V4_CULLFOG|\[TSP_VISGRID_V24\]|\[TSP_VISGRID_V11\].*reject=' "$RAW" | tail -100 || true

printf '\n===== CELL / SECTOR EVENTS =====\n'
grep -E 'enter interior|topology sector=|sector switch|Unloading cell|unload-purge' "$RAW" | tail -140 || true

printf '\n===== ERRORS =====\n'
grep -Ei 'Bad LiveCellRef cast|failed to render|Lua.*error|segfault|fatal|exception|assert|TSP_VISGRID_V28.*error' "$RAW" | tail -120 || true

printf '\n===== EXIT TAIL =====\n'
for f in "$ROOT/openmw_051_log.txt" "$ROOT/config-0.51/openmw.log"; do
  [ -s "$f" ] || continue
  echo "--- $f ---"
  tail -n 60 "$f"
done

printf '\n===== PERF TAIL =====\n'
[ ! -f "$ROOT/openmw51_perf_latest.txt" ] || tail -100 "$ROOT/openmw51_perf_latest.txt"
rm -f "$RAW"
REMOTE
    echo "Saved: $OUT"
    echo
    grep -E '\[TSP_VISGRID_V28\] clutter|\[TSP_ROOMOBJ_V28\]|\[TSP_CLUTTER_V28\]' "$OUT" | tail -30 || true
}

rollback_all(){
    [ -s "$STATE" ] || die "state file missing: $STATE"
    # shellcheck disable=SC1090
    . "$STATE"
    ensure_docker
    ensure_ssh
    game_closed || die "OpenMW is running"
    restore_source
    restore_device
    echo "ROLLBACK COMPLETE"
}

case "$ACTION" in
    collect) collect_latest; exit 0 ;;
    rollback) rollback_all; exit 0 ;;
    install) ;;
    *) die "Usage: $0 [install|collect|rollback]" ;;
esac

exec > >(tee "$LOG") 2>&1

on_error(){
    rc="${1:-1}"
    failed_line="${2:-unknown}"
    failed_cmd="${3:-unknown}"
    trap - ERR
    set +e
    echo
    echo "===== V28 STOPPED SAFELY (rc=$rc) ====="
    echo "FAILED LINE: $failed_line"
    echo "FAILED COMMAND: $failed_cmd"
    if [ -n "$SOURCE_BACKUP" ]; then restore_source >/dev/null 2>&1 || true; fi
    if [ "$DEVICE_DEPLOY_STARTED" = 1 ] && [ -n "$DEVICE_BACKUP" ]; then
        restore_device >/dev/null 2>&1 || true
    fi
    echo "Log preserved: $LOG"
    exit "$rc"
}
trap 'on_error "$?" "$LINENO" "$BASH_COMMAND"' ERR

echo "============================================================"
echo "OPENMW 0.51 — VISGRID V28 SEPARATE CLUTTER RESIDENCY"
echo "============================================================"
echo "Fixes the V27 pvs=0 regression by giving clutter its own engine mask."
echo "Structural/fog PVS may fail open without resurrecting clutter."
echo "Vertical connector: current sector + at most ONE physically-close room."
echo "Physical 3-D AABB distance sorts before topology adjacency."
echo "V27 Balmora object ownership fallback is retained."
echo "Static structure / doors remain outside hard clutter parking."
echo "Normal-exit automatic capture remains removed."
echo "============================================================"

ensure_docker
ensure_ssh
LAUNCHER="$(locate_launcher)"
[ -n "$LAUNCHER" ] || die "could not locate Morrowind_51.sh"

echo
echo "===== 1/9 PRE-FLIGHT ====="
game_closed || die "OpenMW is running. Exit normally and rerun."

docker exec "$CTR" bash -lc "set -e
check_file() { test -s \"\$1\" || { echo \"FAIL preflight file: \$1\" >&2; exit 41; }; echo \"PASS file: \$1\"; }
check_has() { grep -Fq \"\$1\" \"\$2\" || { echo \"FAIL marker: \$1 in \$2\" >&2; exit 42; }; echo \"PASS marker: \$1\"; }
check_absent() { ! grep -Fq \"\$1\" \"\$2\" || { echo \"FAIL unexpected marker: \$1 in \$2\" >&2; exit 43; }; echo \"PASS absent: \$1\"; }

check_file '$SCENE_CPP'
check_file '$VIS_CPP'
check_file '$VIS_HPP'
check_file '$CAMERA'
check_file '$ANIM'
check_file '$BUILT'

check_has 'TSP_ROOM_OBJECT_ADAPTIVE_051_V27' '$SCENE_CPP'
check_has '[TSP_ROOMOBJ_V27]' '$SCENE_CPP'
check_has 'TSP_ROOM_OBJECT_ADAPTIVE_051_V27' '$VIS_CPP'
check_has 'fallbackOwnership = 260.f' '$VIS_CPP'
check_has 'constexpr float zSlack = 110.f;' '$VIS_CPP'
check_has 'sPvsVisibleMask' '$VIS_CPP'
check_has '!tspDiagActor && !tspDiagDoor && !tspIsStatic' '$ANIM'
check_has 'api[\"setInteriorTopologyPvs\"]' '$CAMERA'
check_has 'api[\"clearInteriorTopologyPvs\"]' '$CAMERA'

check_absent 'TSP_ROOM_OBJECT_SEPARATE_CLUTTER_051_V28' '$SCENE_CPP'
check_absent 'mPtr.get<ESM::Static>()' '$ANIM'"

ssh "$DEV" "bash -s" <<REMOTE_PREFLIGHT
set -e

check_file() {
    test -s "\$1" || {
        echo "FAIL device file: \$1" >&2
        exit 51
    }
    echo "PASS device file: \$1"
}

check_has() {
    grep -Fq "\$1" "\$2" || {
        echo "FAIL device marker: \$1 in \$2" >&2
        exit 52
    }
    echo "PASS device marker: \$1"
}

check_absent() {
    ! grep -Fq "\$1" "\$2" || {
        echo "FAIL unexpected device marker: \$1 in \$2" >&2
        exit 53
    }
    echo "PASS device absent: \$1"
}

check_file '$REMOTE_BIN'
check_file '$LIVE_LUA'
check_file '$LAUNCHER'

check_has 'TSP_VISGRID_LUA_V27_ADAPTIVE_CLUTTER' '$LIVE_LUA'
check_has 'v27_profiles/visgrid-v27-adaptive-clutter.lua' '$LAUNCHER'
check_absent '# >>> TSP_VISGRID_V24_AUTO_CAPTURE BEGIN' '$LAUNCHER'

# V28 consumes the LIVE V27 Lua, not the archived V27 profile.
# Therefore absence of the archived profile is not a fatal condition.
if [ -s '$V27_PROFILE' ]; then
    echo 'PASS optional stored V27 profile present'
else
    echo 'NOTE optional stored V27 profile absent; live Lua is authoritative'
fi
REMOTE_PREFLIGHT
PRE_SHA="$(ssh "$DEV" "sha256sum '$REMOTE_BIN'" | awk '{print $1}')"
PRE_LUA_SHA="$(ssh "$DEV" "sha256sum '$LIVE_LUA'" | awk '{print $1}')"
echo "Current binary SHA: $PRE_SHA"
echo "Current V27 Lua:    $PRE_LUA_SHA"

echo
echo "===== 2/9 BACKUP SOURCE + PULL LIVE V27 LUA / LAUNCHER ====="
SOURCE_BACKUP="$SRC/.tsp-051-source-backups/visgrid-v28-separate-clutter-$STAMP"
docker exec "$CTR" bash -lc "set -e
  mkdir -p '$SOURCE_BACKUP'
  cp -pf '$SCENE_CPP' '$SOURCE_BACKUP/scene.cpp'
  cp -pf '$VIS_CPP' '$SOURCE_BACKUP/interiorvisibility.cpp'
  cp -pf '$VIS_HPP' '$SOURCE_BACKUP/interiorvisibility.hpp'
  cp -pf '$CAMERA' '$SOURCE_BACKUP/camerabindings.cpp'
  sha256sum '$SOURCE_BACKUP/'*"
scp -q "$DEV:$LIVE_LUA" "$TMP/visgrid.v27.lua"
scp -q "$DEV:$LAUNCHER" "$TMP/Morrowind_51.v27.sh"
[ "$(sha256sum "$TMP/visgrid.v27.lua" | awk '{print $1}')" = "$PRE_LUA_SHA" ] || die "V27 Lua pull SHA mismatch"

echo
echo "===== 3/9 PATCH ENGINE: INDEPENDENT CLUTTER MASK ====="
base64 -d > "$TMP/v28_cpp_patch.py" <<'V28_CPP_B64'
IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwppbXBvcnQgc3lzCgpzY2VuZV9wYXRoLCB2aXNfY3BwX3BhdGgsIHZpc19ocHBfcGF0aCwgY2FtZXJhX3BhdGggPSBzeXMuYXJndlsxOjVdCgpkZWYgcmVhZChwYXRoKToKICAgIHdpdGggb3BlbihwYXRoLCAncicsIGVuY29kaW5nPSd1dGYtOCcsIG5ld2xpbmU9JycpIGFzIGY6CiAgICAgICAgcmV0dXJuIGYucmVhZCgpCgpkZWYgd3JpdGUocGF0aCwgdGV4dCk6CiAgICB3aXRoIG9wZW4ocGF0aCwgJ3cnLCBlbmNvZGluZz0ndXRmLTgnLCBuZXdsaW5lPSdcbicpIGFzIGY6CiAgICAgICAgZi53cml0ZSh0ZXh0KQoKc2MgPSByZWFkKHNjZW5lX3BhdGgpCnZjID0gcmVhZCh2aXNfY3BwX3BhdGgpCnZoID0gcmVhZCh2aXNfaHBwX3BhdGgpCmNiID0gcmVhZChjYW1lcmFfcGF0aCkKTUFSSyA9ICdUU1BfUk9PTV9PQkpFQ1RfU0VQQVJBVEVfQ0xVVFRFUl8wNTFfVjI4JwoKZm9yIHRva2VuIGluICgnVFNQX1JPT01fT0JKRUNUX0FEQVBUSVZFXzA1MV9WMjcnLCAnW1RTUF9ST09NT0JKX1YyN10nLAogICAgICAgICAgICAgICdpc0ludGVyaW9yVG9wb2xvZ3lPYmplY3RSZXNpZGVudCgnLCAndW5sb2FkLXB1cmdlIHBhcmtlZD0nKToKICAgIGlmIHRva2VuIG5vdCBpbiBzYzoKICAgICAgICByYWlzZSBSdW50aW1lRXJyb3IoJ3NjZW5lLmNwcCBtaXNzaW5nIFYyNyBiYXNlbGluZSB0b2tlbjogJyArIHRva2VuKQpmb3IgdG9rZW4gaW4gKCdUU1BfUk9PTV9PQkpFQ1RfQURBUFRJVkVfMDUxX1YyNycsICdmYWxsYmFja093bmVyc2hpcCA9IDI2MC5mJywKICAgICAgICAgICAgICAnY29uc3RleHByIGZsb2F0IHpTbGFjayA9IDExMC5mOycsICdzUHZzVmlzaWJsZU1hc2snKToKICAgIGlmIHRva2VuIG5vdCBpbiB2YzoKICAgICAgICByYWlzZSBSdW50aW1lRXJyb3IoJ2ludGVyaW9ydmlzaWJpbGl0eS5jcHAgbWlzc2luZyBWMjcgYmFzZWxpbmUgdG9rZW46ICcgKyB0b2tlbikKZm9yIHRva2VuIGluICgnaXNJbnRlcmlvclRvcG9sb2d5UHZzRW5hYmxlZCcsICdpc0ludGVyaW9yVG9wb2xvZ3lPYmplY3RSZXNpZGVudCcpOgogICAgaWYgdG9rZW4gbm90IGluIHZoOgogICAgICAgIHJhaXNlIFJ1bnRpbWVFcnJvcignaW50ZXJpb3J2aXNpYmlsaXR5LmhwcCBtaXNzaW5nIFYyNS9WMjcgQVBJOiAnICsgdG9rZW4pCmZvciB0b2tlbiBpbiAoJ2FwaVsic2V0SW50ZXJpb3JUb3BvbG9neVB2cyJdJywgJ2FwaVsiY2xlYXJJbnRlcmlvclRvcG9sb2d5UHZzIl0nKToKICAgIGlmIHRva2VuIG5vdCBpbiBjYjoKICAgICAgICByYWlzZSBSdW50aW1lRXJyb3IoJ2NhbWVyYWJpbmRpbmdzLmNwcCBtaXNzaW5nIHRvcG9sb2d5IGJyaWRnZTogJyArIHRva2VuKQppZiBhbnkoTUFSSyBpbiB4IGZvciB4IGluIChzYywgdmMsIHZoLCBjYikpOgogICAgcmFpc2UgUnVudGltZUVycm9yKCdWMjggbWFya2VyIGFscmVhZHkgcHJlc2VudDsgcmVmdXNpbmcgYW1iaWd1b3VzIHJlLWFwcGxpY2F0aW9uJykKCiMgLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLQojIDEuIERlZGljYXRlZCBjbHV0dGVyIHN0YXRlLiBUaGlzIHN0YXRlIGlzIGludGVudGlvbmFsbHkgTk9UIHRvdWNoZWQgYnkKIyAgICBjbGVhckludGVyaW9yVG9wb2xvZ3lQdnMoKSBvciBjbGVhckludGVyaW9yVmlzaWJpbGl0eUdyaWQoKS4KIyAtLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tCmdsb2JhbF9hbmNob3IgPSAnJycgICAgICAgIHN0ZDo6YXRvbWljPHN0ZDo6dWludDY0X3Q+IHNQdnNUZXN0ZWR7IDAgfTsKICAgICAgICBzdGQ6OmF0b21pYzxzdGQ6OnVpbnQ2NF90PiBzUHZzQ3VsbGVkeyAwIH07CicnJwpnbG9iYWxfbmV3ID0gZ2xvYmFsX2FuY2hvciArICcnJwogICAgICAgIC8vIFRTUF9ST09NX09CSkVDVF9TRVBBUkFURV9DTFVUVEVSXzA1MV9WMjgKICAgICAgICAvLyBJbmRlcGVuZGVudCByb29tIG1hc2sgZm9yIGhhcmQgc2NlbmUtc2lkZSBjbHV0dGVyIHJlc2lkZW5jeS4KICAgICAgICAvLyBTdHJ1Y3R1cmFsL2ZvZyBQVlMgbWF5IGZhaWwgb3BlbiB3aXRob3V0IHJlc3VycmVjdGluZyBldmVyeSBjbHV0dGVyIHJlZi4KICAgICAgICBzdGQ6OmF0b21pYzxib29sPiBzQ2x1dHRlckVuYWJsZWR7IGZhbHNlIH07CiAgICAgICAgc3RkOjphdG9taWM8aW50PiBzQ2x1dHRlclNlY3RvckNvdW50eyAwIH07CiAgICAgICAgc3RkOjphdG9taWM8aW50PiBzQ2x1dHRlckFjdGl2ZUNvdW50eyAwIH07CiAgICAgICAgc3RkOjphdG9taWM8c3RkOjp1aW50NjRfdD4gc0NsdXR0ZXJWaXNpYmxlTWFza3sgMCB9OwogICAgICAgIHN0ZDo6YXJyYXk8c3RkOjphdG9taWM8ZmxvYXQ+LCBzUHZzTWF4U2VjdG9ycyAqIHNQdnNCb3hTdHJpZGU+IHNDbHV0dGVyQm94ZXN7fTsKJycnCmlmIHZjLmNvdW50KGdsb2JhbF9hbmNob3IpICE9IDE6CiAgICByYWlzZSBSdW50aW1lRXJyb3IoJ1BWUyBnbG9iYWwgYW5jaG9yIGNvdW50PSVkLCBleHBlY3RlZCAxJyAlIHZjLmNvdW50KGdsb2JhbF9hbmNob3IpKQp2YyA9IHZjLnJlcGxhY2UoZ2xvYmFsX2FuY2hvciwgZ2xvYmFsX25ldywgMSkKCiMgUHVibGljIEFQSSBmb2xsb3dzIFYyNSdzIG1haW4tdGhyZWFkIHF1ZXJ5IGRlY2xhcmF0aW9ucy4KaHBwX2FuY2hvciA9ICcnJyAgICBib29sIGlzSW50ZXJpb3JUb3BvbG9neVB2c0VuYWJsZWQoKTsKICAgIGJvb2wgaXNJbnRlcmlvclRvcG9sb2d5T2JqZWN0UmVzaWRlbnQoCiAgICAgICAgY29uc3Qgb3NnOjpWZWMzZiYgb3JpZ2luLCBmbG9hdCByYWRpdXMsIGJvb2wgc3RydWN0dXJhbCA9IGZhbHNlKTsKCiAgICB2b2lkIGNsZWFySW50ZXJpb3JWaXNpYmlsaXR5R3JpZCgpOwonJycKaHBwX25ldyA9ICcnJyAgICBib29sIGlzSW50ZXJpb3JUb3BvbG9neVB2c0VuYWJsZWQoKTsKICAgIGJvb2wgaXNJbnRlcmlvclRvcG9sb2d5T2JqZWN0UmVzaWRlbnQoCiAgICAgICAgY29uc3Qgb3NnOjpWZWMzZiYgb3JpZ2luLCBmbG9hdCByYWRpdXMsIGJvb2wgc3RydWN0dXJhbCA9IGZhbHNlKTsKCiAgICAvLyBUU1BfUk9PTV9PQkpFQ1RfU0VQQVJBVEVfQ0xVVFRFUl8wNTFfVjI4CiAgICAvLyBJbmRlcGVuZGVudCBmcm9tIHN0cnVjdHVyYWwvZm9nIHRvcG9sb2d5IFBWUy4gTHVhIHB1Ymxpc2hlcyBvbmx5IHRoZQogICAgLy8gY2x1dHRlciByb29tcyB0aGF0IHNob3VsZCBiZSBwaHlzaWNhbGx5IG1hdGVyaWFsaXplZCBpbiB0aGUgc2NlbmUuCiAgICB2b2lkIHNldEludGVyaW9yQ2x1dHRlclJlc2lkZW5jeSgKICAgICAgICBzdGQ6OnNwYW48Y29uc3QgZmxvYXQ+IGJveGVzLCBzdGQ6OnNwYW48Y29uc3QgaW50PiBhY3RpdmVTZWN0b3JJZHMpOwogICAgdm9pZCBjbGVhckludGVyaW9yQ2x1dHRlclJlc2lkZW5jeSgpOwogICAgYm9vbCBpc0ludGVyaW9yQ2x1dHRlclJlc2lkZW5jeUVuYWJsZWQoKTsKICAgIGJvb2wgaXNJbnRlcmlvckNsdXR0ZXJPYmplY3RSZXNpZGVudChjb25zdCBvc2c6OlZlYzNmJiBvcmlnaW4pOwoKICAgIHZvaWQgY2xlYXJJbnRlcmlvclZpc2liaWxpdHlHcmlkKCk7CicnJwppZiB2aC5jb3VudChocHBfYW5jaG9yKSAhPSAxOgogICAgcmFpc2UgUnVudGltZUVycm9yKCdocHAgVjI1IEFQSSBhbmNob3IgY291bnQ9JWQsIGV4cGVjdGVkIDEnICUgdmguY291bnQoaHBwX2FuY2hvcikpCnZoID0gdmgucmVwbGFjZShocHBfYW5jaG9yLCBocHBfbmV3LCAxKQoKIyBJbXBsZW1lbnQgaW1tZWRpYXRlbHkgYmVmb3JlIGNsZWFySW50ZXJpb3JWaXNpYmlsaXR5R3JpZCgpLgphcGlfYW5jaG9yID0gJyAgICB2b2lkIGNsZWFySW50ZXJpb3JWaXNpYmlsaXR5R3JpZCgpXG4nCmlmIHZjLmNvdW50KGFwaV9hbmNob3IpICE9IDE6CiAgICByYWlzZSBSdW50aW1lRXJyb3IoJ2NsZWFySW50ZXJpb3JWaXNpYmlsaXR5R3JpZCBhbmNob3IgY291bnQ9JWQsIGV4cGVjdGVkIDEnICUgdmMuY291bnQoYXBpX2FuY2hvcikpCmFwaV9pbXBsID0gcicnJyAgICAvLyBUU1BfUk9PTV9PQkpFQ1RfU0VQQVJBVEVfQ0xVVFRFUl8wNTFfVjI4CiAgICB2b2lkIHNldEludGVyaW9yQ2x1dHRlclJlc2lkZW5jeSgKICAgICAgICBzdGQ6OnNwYW48Y29uc3QgZmxvYXQ+IGJveGVzLCBzdGQ6OnNwYW48Y29uc3QgaW50PiBhY3RpdmVTZWN0b3JJZHMpCiAgICB7CiAgICAgICAgaWYgKGJveGVzLmVtcHR5KCkgfHwgYm94ZXMuc2l6ZSgpICUgc1B2c0JveFN0cmlkZSAhPSAwKQogICAgICAgIHsKICAgICAgICAgICAgY2xlYXJJbnRlcmlvckNsdXR0ZXJSZXNpZGVuY3koKTsKICAgICAgICAgICAgcmV0dXJuOwogICAgICAgIH0KCiAgICAgICAgY29uc3QgaW50IHNlY3RvckNvdW50ID0gc3RhdGljX2Nhc3Q8aW50Pihib3hlcy5zaXplKCkgLyBzUHZzQm94U3RyaWRlKTsKICAgICAgICBpZiAoc2VjdG9yQ291bnQgPD0gMCB8fCBzZWN0b3JDb3VudCA+IHNQdnNNYXhTZWN0b3JzKQogICAgICAgIHsKICAgICAgICAgICAgY2xlYXJJbnRlcmlvckNsdXR0ZXJSZXNpZGVuY3koKTsKICAgICAgICAgICAgcmV0dXJuOwogICAgICAgIH0KCiAgICAgICAgc3RkOjp1aW50NjRfdCB2aXNpYmxlTWFzayA9IDA7CiAgICAgICAgaW50IGFjdGl2ZUNvdW50ID0gMDsKICAgICAgICBmb3IgKGludCBpZCA6IGFjdGl2ZVNlY3RvcklkcykKICAgICAgICB7CiAgICAgICAgICAgIGlmIChpZCA8PSAwIHx8IGlkID4gc2VjdG9yQ291bnQpCiAgICAgICAgICAgIHsKICAgICAgICAgICAgICAgIGNsZWFySW50ZXJpb3JDbHV0dGVyUmVzaWRlbmN5KCk7CiAgICAgICAgICAgICAgICByZXR1cm47CiAgICAgICAgICAgIH0KICAgICAgICAgICAgY29uc3Qgc3RkOjp1aW50NjRfdCBiaXQgPSBzdGQ6OnVpbnQ2NF90eyAxIH0gPDwgKGlkIC0gMSk7CiAgICAgICAgICAgIGlmICgodmlzaWJsZU1hc2sgJiBiaXQpID09IDApCiAgICAgICAgICAgIHsKICAgICAgICAgICAgICAgIHZpc2libGVNYXNrIHw9IGJpdDsKICAgICAgICAgICAgICAgICsrYWN0aXZlQ291bnQ7CiAgICAgICAgICAgIH0KICAgICAgICB9CiAgICAgICAgaWYgKHZpc2libGVNYXNrID09IDApCiAgICAgICAgewogICAgICAgICAgICBjbGVhckludGVyaW9yQ2x1dHRlclJlc2lkZW5jeSgpOwogICAgICAgICAgICByZXR1cm47CiAgICAgICAgfQoKICAgICAgICBmb3IgKGZsb2F0IHZhbHVlIDogYm94ZXMpCiAgICAgICAgewogICAgICAgICAgICBpZiAoIXN0ZDo6aXNmaW5pdGUodmFsdWUpKQogICAgICAgICAgICB7CiAgICAgICAgICAgICAgICBjbGVhckludGVyaW9yQ2x1dHRlclJlc2lkZW5jeSgpOwogICAgICAgICAgICAgICAgcmV0dXJuOwogICAgICAgICAgICB9CiAgICAgICAgfQoKICAgICAgICBjb25zdCBib29sIHdhc0VuYWJsZWQgPSBzQ2x1dHRlckVuYWJsZWQuZXhjaGFuZ2UoZmFsc2UsIHN0ZDo6bWVtb3J5X29yZGVyX2FjcV9yZWwpOwogICAgICAgIGZvciAoc3RkOjpzaXplX3QgaSA9IDA7IGkgPCBib3hlcy5zaXplKCk7ICsraSkKICAgICAgICAgICAgc0NsdXR0ZXJCb3hlc1tpXS5zdG9yZShib3hlc1tpXSwgc3RkOjptZW1vcnlfb3JkZXJfcmVsYXhlZCk7CiAgICAgICAgc0NsdXR0ZXJTZWN0b3JDb3VudC5zdG9yZShzZWN0b3JDb3VudCwgc3RkOjptZW1vcnlfb3JkZXJfcmVsYXhlZCk7CiAgICAgICAgc0NsdXR0ZXJBY3RpdmVDb3VudC5zdG9yZShhY3RpdmVDb3VudCwgc3RkOjptZW1vcnlfb3JkZXJfcmVsYXhlZCk7CiAgICAgICAgc0NsdXR0ZXJWaXNpYmxlTWFzay5zdG9yZSh2aXNpYmxlTWFzaywgc3RkOjptZW1vcnlfb3JkZXJfcmVsYXhlZCk7CiAgICAgICAgc0NsdXR0ZXJFbmFibGVkLnN0b3JlKHRydWUsIHN0ZDo6bWVtb3J5X29yZGVyX3JlbGVhc2UpOwoKICAgICAgICBpZiAoIXdhc0VuYWJsZWQpCiAgICAgICAgICAgIExvZyhEZWJ1Zzo6SW5mbykgPDwgIltUU1BfQ0xVVFRFUl9WMjhdIGFjdGl2ZSBzZWN0b3JzPSIgPDwgc2VjdG9yQ291bnQKICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8PCAiIHJlc2lkZW50PSIgPDwgYWN0aXZlQ291bnQ7CiAgICB9CgogICAgdm9pZCBjbGVhckludGVyaW9yQ2x1dHRlclJlc2lkZW5jeSgpCiAgICB7CiAgICAgICAgY29uc3QgYm9vbCB3YXNFbmFibGVkID0gc0NsdXR0ZXJFbmFibGVkLmV4Y2hhbmdlKGZhbHNlLCBzdGQ6Om1lbW9yeV9vcmRlcl9hY3FfcmVsKTsKICAgICAgICBzQ2x1dHRlclNlY3RvckNvdW50LnN0b3JlKDAsIHN0ZDo6bWVtb3J5X29yZGVyX3JlbGF4ZWQpOwogICAgICAgIHNDbHV0dGVyQWN0aXZlQ291bnQuc3RvcmUoMCwgc3RkOjptZW1vcnlfb3JkZXJfcmVsYXhlZCk7CiAgICAgICAgc0NsdXR0ZXJWaXNpYmxlTWFzay5zdG9yZSgwLCBzdGQ6Om1lbW9yeV9vcmRlcl9yZWxheGVkKTsKICAgICAgICBpZiAod2FzRW5hYmxlZCkKICAgICAgICAgICAgTG9nKERlYnVnOjpJbmZvKSA8PCAiW1RTUF9DTFVUVEVSX1YyOF0gaW5hY3RpdmUiOwogICAgfQoKICAgIGJvb2wgaXNJbnRlcmlvckNsdXR0ZXJSZXNpZGVuY3lFbmFibGVkKCkKICAgIHsKICAgICAgICByZXR1cm4gc0NsdXR0ZXJFbmFibGVkLmxvYWQoc3RkOjptZW1vcnlfb3JkZXJfYWNxdWlyZSk7CiAgICB9CgogICAgYm9vbCBpc0ludGVyaW9yQ2x1dHRlck9iamVjdFJlc2lkZW50KGNvbnN0IG9zZzo6VmVjM2YmIG9yaWdpbikKICAgIHsKICAgICAgICAvLyBPbmx5IHRoZSBkZWRpY2F0ZWQgY2x1dHRlciBicmlkZ2UgY29udHJvbHMgdGhpcyBmYWlsLW9wZW4uIFN0cnVjdHVyYWwKICAgICAgICAvLyBQVlMvZ3JpZC9mb2cgZW5hYmxlIHN0YXRlIGlzIGludGVudGlvbmFsbHkgaXJyZWxldmFudCBoZXJlLgogICAgICAgIGlmICghc0NsdXR0ZXJFbmFibGVkLmxvYWQoc3RkOjptZW1vcnlfb3JkZXJfYWNxdWlyZSkpCiAgICAgICAgICAgIHJldHVybiB0cnVlOwoKICAgICAgICBjb25zdCBpbnQgc2VjdG9yQ291bnQgPSBzQ2x1dHRlclNlY3RvckNvdW50LmxvYWQoc3RkOjptZW1vcnlfb3JkZXJfcmVsYXhlZCk7CiAgICAgICAgY29uc3Qgc3RkOjp1aW50NjRfdCB2aXNpYmxlTWFzayA9IHNDbHV0dGVyVmlzaWJsZU1hc2subG9hZChzdGQ6Om1lbW9yeV9vcmRlcl9yZWxheGVkKTsKICAgICAgICBpZiAoc2VjdG9yQ291bnQgPD0gMCB8fCBzZWN0b3JDb3VudCA+IHNQdnNNYXhTZWN0b3JzIHx8IHZpc2libGVNYXNrID09IDApCiAgICAgICAgICAgIHJldHVybiB0cnVlOwoKICAgICAgICBib29sIHRvdWNoZWRNYXBwZWRTZWN0b3IgPSBmYWxzZTsKICAgICAgICBpbnQgbmVhcmVzdFNlY3RvciA9IC0xOwogICAgICAgIGZsb2F0IG5lYXJlc3REMiA9IHN0ZDo6bnVtZXJpY19saW1pdHM8ZmxvYXQ+OjppbmZpbml0eSgpOwoKICAgICAgICBmb3IgKGludCBzZWN0b3IgPSAwOyBzZWN0b3IgPCBzZWN0b3JDb3VudDsgKytzZWN0b3IpCiAgICAgICAgewogICAgICAgICAgICBjb25zdCBpbnQgYmFzZSA9IHNlY3RvciAqIHNQdnNCb3hTdHJpZGU7CiAgICAgICAgICAgIGNvbnN0IGZsb2F0IG1pblggPSBzQ2x1dHRlckJveGVzW3N0YXRpY19jYXN0PHN0ZDo6c2l6ZV90PihiYXNlICsgMCldLmxvYWQoc3RkOjptZW1vcnlfb3JkZXJfcmVsYXhlZCk7CiAgICAgICAgICAgIGNvbnN0IGZsb2F0IG1pblkgPSBzQ2x1dHRlckJveGVzW3N0YXRpY19jYXN0PHN0ZDo6c2l6ZV90PihiYXNlICsgMSldLmxvYWQoc3RkOjptZW1vcnlfb3JkZXJfcmVsYXhlZCk7CiAgICAgICAgICAgIGNvbnN0IGZsb2F0IG1pblogPSBzQ2x1dHRlckJveGVzW3N0YXRpY19jYXN0PHN0ZDo6c2l6ZV90PihiYXNlICsgMildLmxvYWQoc3RkOjptZW1vcnlfb3JkZXJfcmVsYXhlZCk7CiAgICAgICAgICAgIGNvbnN0IGZsb2F0IG1heFggPSBzQ2x1dHRlckJveGVzW3N0YXRpY19jYXN0PHN0ZDo6c2l6ZV90PihiYXNlICsgMyldLmxvYWQoc3RkOjptZW1vcnlfb3JkZXJfcmVsYXhlZCk7CiAgICAgICAgICAgIGNvbnN0IGZsb2F0IG1heFkgPSBzQ2x1dHRlckJveGVzW3N0YXRpY19jYXN0PHN0ZDo6c2l6ZV90PihiYXNlICsgNCldLmxvYWQoc3RkOjptZW1vcnlfb3JkZXJfcmVsYXhlZCk7CiAgICAgICAgICAgIGNvbnN0IGZsb2F0IG1heFogPSBzQ2x1dHRlckJveGVzW3N0YXRpY19jYXN0PHN0ZDo6c2l6ZV90PihiYXNlICsgNSldLmxvYWQoc3RkOjptZW1vcnlfb3JkZXJfcmVsYXhlZCk7CiAgICAgICAgICAgIGlmICghc3RkOjppc2Zpbml0ZShtaW5YKSB8fCAhc3RkOjppc2Zpbml0ZShtaW5ZKSB8fCAhc3RkOjppc2Zpbml0ZShtaW5aKQogICAgICAgICAgICAgICAgfHwgIXN0ZDo6aXNmaW5pdGUobWF4WCkgfHwgIXN0ZDo6aXNmaW5pdGUobWF4WSkgfHwgIXN0ZDo6aXNmaW5pdGUobWF4WikpCiAgICAgICAgICAgICAgICBjb250aW51ZTsKCiAgICAgICAgICAgIC8vIFNhbWUgVjI3IG9iamVjdC10by1yb29tIG93bmVyc2hpcCB0aGF0IHJlc3RvcmVkIEJhbG1vcmEgY2x1dHRlcjoKICAgICAgICAgICAgLy8gWkVSTyBYWSBibGVlZCwgdmVydGljYWwgc2xhY2sgZm9yIHNoZWxmL3RhYmxldG9wIG9iamVjdHMuCiAgICAgICAgICAgIGNvbnN0ZXhwciBmbG9hdCB6U2xhY2sgPSAxMTAuZjsKICAgICAgICAgICAgY29uc3QgYm9vbCBvdmVybGFwcyA9IG9yaWdpbi54KCkgPj0gbWluWCAmJiBvcmlnaW4ueCgpIDw9IG1heFgKICAgICAgICAgICAgICAgICYmIG9yaWdpbi55KCkgPj0gbWluWSAmJiBvcmlnaW4ueSgpIDw9IG1heFkKICAgICAgICAgICAgICAgICYmIG9yaWdpbi56KCkgPj0gbWluWiAtIHpTbGFjayAmJiBvcmlnaW4ueigpIDw9IG1heFogKyB6U2xhY2s7CgogICAgICAgICAgICBjb25zdCBmbG9hdCBkeCA9IG9yaWdpbi54KCkgPCBtaW5YID8gbWluWCAtIG9yaWdpbi54KCkKICAgICAgICAgICAgICAgIDogKG9yaWdpbi54KCkgPiBtYXhYID8gb3JpZ2luLngoKSAtIG1heFggOiAwLmYpOwogICAgICAgICAgICBjb25zdCBmbG9hdCBkeSA9IG9yaWdpbi55KCkgPCBtaW5ZID8gbWluWSAtIG9yaWdpbi55KCkKICAgICAgICAgICAgICAgIDogKG9yaWdpbi55KCkgPiBtYXhZID8gb3JpZ2luLnkoKSAtIG1heFkgOiAwLmYpOwogICAgICAgICAgICBjb25zdCBmbG9hdCBsb1ogPSBtaW5aIC0gelNsYWNrOwogICAgICAgICAgICBjb25zdCBmbG9hdCBoaVogPSBtYXhaICsgelNsYWNrOwogICAgICAgICAgICBjb25zdCBmbG9hdCBkeiA9IG9yaWdpbi56KCkgPCBsb1ogPyBsb1ogLSBvcmlnaW4ueigpCiAgICAgICAgICAgICAgICA6IChvcmlnaW4ueigpID4gaGlaID8gb3JpZ2luLnooKSAtIGhpWiA6IDAuZik7CiAgICAgICAgICAgIGNvbnN0IGZsb2F0IGQyID0gZHggKiBkeCArIGR5ICogZHkgKyBkeiAqIGR6OwogICAgICAgICAgICBpZiAoZDIgPCBuZWFyZXN0RDIpCiAgICAgICAgICAgIHsKICAgICAgICAgICAgICAgIG5lYXJlc3REMiA9IGQyOwogICAgICAgICAgICAgICAgbmVhcmVzdFNlY3RvciA9IHNlY3RvcjsKICAgICAgICAgICAgfQoKICAgICAgICAgICAgaWYgKCFvdmVybGFwcykKICAgICAgICAgICAgICAgIGNvbnRpbnVlOwogICAgICAgICAgICB0b3VjaGVkTWFwcGVkU2VjdG9yID0gdHJ1ZTsKICAgICAgICAgICAgaWYgKCh2aXNpYmxlTWFzayAmIChzdGQ6OnVpbnQ2NF90eyAxIH0gPDwgc2VjdG9yKSkgIT0gMCkKICAgICAgICAgICAgICAgIHJldHVybiB0cnVlOwogICAgICAgIH0KCiAgICAgICAgaWYgKHRvdWNoZWRNYXBwZWRTZWN0b3IpCiAgICAgICAgICAgIHJldHVybiBmYWxzZTsKCiAgICAgICAgaWYgKG5lYXJlc3RTZWN0b3IgPj0gMCkKICAgICAgICB7CiAgICAgICAgICAgIGNvbnN0ZXhwciBmbG9hdCBmYWxsYmFja093bmVyc2hpcCA9IDI2MC5mOwogICAgICAgICAgICBpZiAobmVhcmVzdEQyIDw9IGZhbGxiYWNrT3duZXJzaGlwICogZmFsbGJhY2tPd25lcnNoaXApCiAgICAgICAgICAgICAgICByZXR1cm4gKHZpc2libGVNYXNrICYgKHN0ZDo6dWludDY0X3R7IDEgfSA8PCBuZWFyZXN0U2VjdG9yKSkgIT0gMDsKICAgICAgICB9CgogICAgICAgIC8vIEdlbnVpbmVseSB1bm1hcHBlZCBjb250ZW50IHN0aWxsIGZhaWxzIE9QRU4uIFRoZSBjcnVjaWFsIGRpZmZlcmVuY2UKICAgICAgICAvLyBmcm9tIFYyNyBpcyB0aGF0IGEgc3RydWN0dXJhbCBQVlMgY2xlYXIgbm8gbG9uZ2VyIGNhdXNlcyB0aGlzIHBhdGguCiAgICAgICAgcmV0dXJuIHRydWU7CiAgICB9CgonJycKdmMgPSB2Yy5yZXBsYWNlKGFwaV9hbmNob3IsIGFwaV9pbXBsICsgYXBpX2FuY2hvciwgMSkKCiMgLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLQojIDIuIFNjZW5lIGxpZmVjeWNsZSByZWFkcyBPTkxZIHRoZSBpbmRlcGVuZGVudCBjbHV0dGVyIG1hc2suCiMgLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLQpvbGQgPSAnICAgICAgICBjb25zdCBib29sIHB2c0VuYWJsZWQgPSBNV1JlbmRlcjo6aXNJbnRlcmlvclRvcG9sb2d5UHZzRW5hYmxlZCgpO1xuJwpuZXcgPSAnJycgICAgICAgIC8vIFRTUF9ST09NX09CSkVDVF9TRVBBUkFURV9DTFVUVEVSXzA1MV9WMjgKICAgICAgICBjb25zdCBib29sIGNsdXR0ZXJFbmFibGVkID0gTVdSZW5kZXI6OmlzSW50ZXJpb3JDbHV0dGVyUmVzaWRlbmN5RW5hYmxlZCgpOwonJycKaWYgc2MuY291bnQob2xkKSAhPSAxOgogICAgcmFpc2UgUnVudGltZUVycm9yKCdzY2VuZSBwdnNFbmFibGVkIGxpbmUgY291bnQ9JWQsIGV4cGVjdGVkIDEnICUgc2MuY291bnQob2xkKSkKc2MgPSBzYy5yZXBsYWNlKG9sZCwgbmV3LCAxKQoKb2xkID0gJycnICAgICAgICAgICAgY29uc3QgYm9vbCBzaG91bGRMaXZlID0gTVdSZW5kZXI6OmlzSW50ZXJpb3JUb3BvbG9neU9iamVjdFJlc2lkZW50KAogICAgICAgICAgICAgICAgb3JpZ2luLCAwLmYsIGZhbHNlKTsnJycKbmV3ID0gJycnICAgICAgICAgICAgLy8gVFNQX1JPT01fT0JKRUNUX1NFUEFSQVRFX0NMVVRURVJfMDUxX1YyOAogICAgICAgICAgICBjb25zdCBib29sIHNob3VsZExpdmUgPSBNV1JlbmRlcjo6aXNJbnRlcmlvckNsdXR0ZXJPYmplY3RSZXNpZGVudChvcmlnaW4pOycnJwppZiBzYy5jb3VudChvbGQpICE9IDE6CiAgICByYWlzZSBSdW50aW1lRXJyb3IoJ3NjZW5lIFYyNyByZXNpZGVudCBjYWxsIGNvdW50PSVkLCBleHBlY3RlZCAxJyAlIHNjLmNvdW50KG9sZCkpCnNjID0gc2MucmVwbGFjZShvbGQsIG5ldywgMSkKCmlmIHNjLmNvdW50KCdbVFNQX1JPT01PQkpfVjI3XSBwdnM9JykgIT0gMToKICAgIHJhaXNlIFJ1bnRpbWVFcnJvcignc2NlbmUgVjI3IHRlbGVtZXRyeSBwcmVmaXggY291bnQ9JWQsIGV4cGVjdGVkIDEnICUgc2MuY291bnQoJ1tUU1BfUk9PTU9CSl9WMjddIHB2cz0nKSkKc2MgPSBzYy5yZXBsYWNlKCdbVFNQX1JPT01PQkpfVjI3XSBwdnM9JywgJ1tUU1BfUk9PTU9CSl9WMjhdIGNsdXR0ZXI9JywgMSkKaWYgc2MuY291bnQoJyhwdnNFbmFibGVkID8gMSA6IDApJykgIT0gMToKICAgIHJhaXNlIFJ1bnRpbWVFcnJvcignc2NlbmUgcHZzRW5hYmxlZCB0ZWxlbWV0cnkgZXhwcmVzc2lvbiBjb3VudD0lZCwgZXhwZWN0ZWQgMScgJSBzYy5jb3VudCgnKHB2c0VuYWJsZWQgPyAxIDogMCknKSkKc2MgPSBzYy5yZXBsYWNlKCcocHZzRW5hYmxlZCA/IDEgOiAwKScsICcoY2x1dHRlckVuYWJsZWQgPyAxIDogMCknLCAxKQoKIyBDbGVhciBzdGFsZSBjbHV0dGVyIGF1dGhvcml0eSBpbW1lZGlhdGVseSBvbiBhIGN1cnJlbnQtY2VsbCBjaGFuZ2UuIEx1YSB3aWxsCiMgcmVwdWJsaXNoIHRoZSBkZXN0aW5hdGlvbiBjZWxsJ3MgbWFzayBvbiBpdHMgbmV4dCB0b3BvbG9neSB1cGRhdGUuCm9sZCA9ICcnJyAgICAgICAgaWYgKG1DdXJyZW50Q2VsbCAhPSBtVHNwUm9vbUxpZmVjeWNsZUNlbGwpCiAgICAgICAgewogICAgICAgICAgICBtVHNwUm9vbUxpZmVjeWNsZUNlbGwgPSBtQ3VycmVudENlbGw7CicnJwpuZXcgPSAnJycgICAgICAgIGlmIChtQ3VycmVudENlbGwgIT0gbVRzcFJvb21MaWZlY3ljbGVDZWxsKQogICAgICAgIHsKICAgICAgICAgICAgLy8gVFNQX1JPT01fT0JKRUNUX1NFUEFSQVRFX0NMVVRURVJfMDUxX1YyOAogICAgICAgICAgICBNV1JlbmRlcjo6Y2xlYXJJbnRlcmlvckNsdXR0ZXJSZXNpZGVuY3koKTsKICAgICAgICAgICAgbVRzcFJvb21MaWZlY3ljbGVDZWxsID0gbUN1cnJlbnRDZWxsOwonJycKaWYgc2MuY291bnQob2xkKSAhPSAxOgogICAgcmFpc2UgUnVudGltZUVycm9yKCdzY2VuZSBsaWZlY3ljbGUgY2VsbC1jaGFuZ2UgYW5jaG9yIGNvdW50PSVkLCBleHBlY3RlZCAxJyAlIHNjLmNvdW50KG9sZCkpCnNjID0gc2MucmVwbGFjZShvbGQsIG5ldywgMSkKCiMgVjI3IGFscmVhZHkgcHVyZ2VzIHRlbXBvcmFyeSBwYWdpbmcgYm9va2tlZXBpbmcgYmVmb3JlIHVubG9hZC4gQWxzbyBkaXNhcm0gdGhlCiMgZGVkaWNhdGVkIGNsdXR0ZXIgbWFzayBzbyBpdCBjYW5ub3QgYmxlZWQgdG8gdGhlIG5leHQgY2VsbC4Kb2xkID0gJycnICAgICAgICAgICAgbVRzcFJvb21MaWZlY3ljbGVBY2N1bXVsYXRvciA9IDAuZjsKICAgICAgICAgICAgbVRzcFJvb21Mb2dBY2N1bXVsYXRvciA9IDAuZjsKICAgICAgICAgICAgTG9nKERlYnVnOjpJbmZvKSA8PCAiW1RTUF9ST09NT0JKX1YyN10gdW5sb2FkLXB1cmdlIHBhcmtlZD0iIDw8IHRzcFBhcmtlZDsKJycnCm5ldyA9ICcnJyAgICAgICAgICAgIG1Uc3BSb29tTGlmZWN5Y2xlQWNjdW11bGF0b3IgPSAwLmY7CiAgICAgICAgICAgIG1Uc3BSb29tTG9nQWNjdW11bGF0b3IgPSAwLmY7CiAgICAgICAgICAgIE1XUmVuZGVyOjpjbGVhckludGVyaW9yQ2x1dHRlclJlc2lkZW5jeSgpOwogICAgICAgICAgICBMb2coRGVidWc6OkluZm8pIDw8ICJbVFNQX1JPT01PQkpfVjI4XSB1bmxvYWQtcHVyZ2UgcGFya2VkPSIgPDwgdHNwUGFya2VkOwonJycKaWYgc2MuY291bnQob2xkKSAhPSAxOgogICAgcmFpc2UgUnVudGltZUVycm9yKCdzY2VuZSBWMjcgdW5sb2FkLXB1cmdlIGJsb2NrIGNvdW50PSVkLCBleHBlY3RlZCAxJyAlIHNjLmNvdW50KG9sZCkpCnNjID0gc2MucmVwbGFjZShvbGQsIG5ldywgMSkKCiMgLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLQojIDMuIEx1YSBjYW1lcmEgYnJpZGdlLiBJdCBtaXJyb3JzIHRoZSBzdHJ1Y3R1cmFsIGJyaWRnZSdzIHZhbGlkYXRpb24gYnV0IHdyaXRlcwojICAgIGRlZGljYXRlZCBjbHV0dGVyIHN0YXRlLiBJdCBjYW5ub3QgYmUgY2xlYXJlZCBieSBzdHJ1Y3R1cmFsL2ZvZyBzYWZldHkuCiMgLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLQpjYW1lcmFfYW5jaG9yID0gJyAgICAgICAgYXBpWyJjbGVhckludGVyaW9yVG9wb2xvZ3lQdnMiXSA9IFtdIHsgTVdSZW5kZXI6OmNsZWFySW50ZXJpb3JUb3BvbG9neVB2cygpOyB9O1xuJwppZiBjYi5jb3VudChjYW1lcmFfYW5jaG9yKSAhPSAxOgogICAgcmFpc2UgUnVudGltZUVycm9yKCdjYW1lcmEgdG9wb2xvZ3kgY2xlYXIgYW5jaG9yIGNvdW50PSVkLCBleHBlY3RlZCAxJyAlIGNiLmNvdW50KGNhbWVyYV9hbmNob3IpKQpjYW1lcmFfYXBpID0gcicnJwoKICAgICAgICAvLyBUU1BfUk9PTV9PQkpFQ1RfU0VQQVJBVEVfQ0xVVFRFUl8wNTFfVjI4CiAgICAgICAgYXBpWyJzZXRJbnRlcmlvckNsdXR0ZXJSZXNpZGVuY3kiXQogICAgICAgICAgICA9IFtdKGNvbnN0IHNvbDo6dGFibGUmIGJveGVzLCBjb25zdCBzb2w6OnRhYmxlJiBhY3RpdmVJZHMpIHsKICAgICAgICAgICAgICAgICAgY29uc3Qgc3RkOjpzaXplX3QgYm94VmFsdWVDb3VudCA9IGJveGVzLnNpemUoKTsKICAgICAgICAgICAgICAgICAgaWYgKGJveFZhbHVlQ291bnQgPT0gMCB8fCBib3hWYWx1ZUNvdW50ICUgNiAhPSAwCiAgICAgICAgICAgICAgICAgICAgICB8fCBib3hWYWx1ZUNvdW50IC8gNiA+IDY0KQogICAgICAgICAgICAgICAgICB7CiAgICAgICAgICAgICAgICAgICAgICBNV1JlbmRlcjo6Y2xlYXJJbnRlcmlvckNsdXR0ZXJSZXNpZGVuY3koKTsKICAgICAgICAgICAgICAgICAgICAgIHJldHVybjsKICAgICAgICAgICAgICAgICAgfQoKICAgICAgICAgICAgICAgICAgc3RkOjp2ZWN0b3I8ZmxvYXQ+IGJveFZhbHVlczsKICAgICAgICAgICAgICAgICAgYm94VmFsdWVzLnJlc2VydmUoYm94VmFsdWVDb3VudCk7CiAgICAgICAgICAgICAgICAgIGZvciAoc3RkOjpzaXplX3QgaSA9IDE7IGkgPD0gYm94VmFsdWVDb3VudDsgKytpKQogICAgICAgICAgICAgICAgICB7CiAgICAgICAgICAgICAgICAgICAgICBjb25zdCBzb2w6Om9wdGlvbmFsPGZsb2F0PiB2ID0gYm94ZXMuZ2V0PHNvbDo6b3B0aW9uYWw8ZmxvYXQ+PihpKTsKICAgICAgICAgICAgICAgICAgICAgIGlmICghdiB8fCAhc3RkOjppc2Zpbml0ZSgqdikpCiAgICAgICAgICAgICAgICAgICAgICB7CiAgICAgICAgICAgICAgICAgICAgICAgICAgTVdSZW5kZXI6OmNsZWFySW50ZXJpb3JDbHV0dGVyUmVzaWRlbmN5KCk7CiAgICAgICAgICAgICAgICAgICAgICAgICAgcmV0dXJuOwogICAgICAgICAgICAgICAgICAgICAgfQogICAgICAgICAgICAgICAgICAgICAgYm94VmFsdWVzLnB1c2hfYmFjaygqdik7CiAgICAgICAgICAgICAgICAgIH0KCiAgICAgICAgICAgICAgICAgIHN0ZDo6dmVjdG9yPGludD4gaWRzOwogICAgICAgICAgICAgICAgICBpZHMucmVzZXJ2ZShhY3RpdmVJZHMuc2l6ZSgpKTsKICAgICAgICAgICAgICAgICAgZm9yIChzdGQ6OnNpemVfdCBpID0gMTsgaSA8PSBhY3RpdmVJZHMuc2l6ZSgpOyArK2kpCiAgICAgICAgICAgICAgICAgIHsKICAgICAgICAgICAgICAgICAgICAgIGNvbnN0IHNvbDo6b3B0aW9uYWw8aW50PiBpZCA9IGFjdGl2ZUlkcy5nZXQ8c29sOjpvcHRpb25hbDxpbnQ+PihpKTsKICAgICAgICAgICAgICAgICAgICAgIGlmICghaWQgfHwgKmlkIDw9IDAgfHwgKmlkID4gNjQpCiAgICAgICAgICAgICAgICAgICAgICB7CiAgICAgICAgICAgICAgICAgICAgICAgICAgTVdSZW5kZXI6OmNsZWFySW50ZXJpb3JDbHV0dGVyUmVzaWRlbmN5KCk7CiAgICAgICAgICAgICAgICAgICAgICAgICAgcmV0dXJuOwogICAgICAgICAgICAgICAgICAgICAgfQogICAgICAgICAgICAgICAgICAgICAgaWRzLnB1c2hfYmFjaygqaWQpOwogICAgICAgICAgICAgICAgICB9CgogICAgICAgICAgICAgICAgICBNV1JlbmRlcjo6c2V0SW50ZXJpb3JDbHV0dGVyUmVzaWRlbmN5KAogICAgICAgICAgICAgICAgICAgICAgc3RkOjpzcGFuPGNvbnN0IGZsb2F0Pihib3hWYWx1ZXMuZGF0YSgpLCBib3hWYWx1ZXMuc2l6ZSgpKSwKICAgICAgICAgICAgICAgICAgICAgIHN0ZDo6c3Bhbjxjb25zdCBpbnQ+KGlkcy5kYXRhKCksIGlkcy5zaXplKCkpKTsKICAgICAgICAgICAgICB9OwoKICAgICAgICBhcGlbImNsZWFySW50ZXJpb3JDbHV0dGVyUmVzaWRlbmN5Il0gPSBbXSB7IE1XUmVuZGVyOjpjbGVhckludGVyaW9yQ2x1dHRlclJlc2lkZW5jeSgpOyB9OwonJycKY2IgPSBjYi5yZXBsYWNlKGNhbWVyYV9hbmNob3IsIGNhbWVyYV9hbmNob3IgKyBjYW1lcmFfYXBpLCAxKQoKIyBTYWZldHkvcG9zdGNvbmRpdGlvbnMuCmZvciB0b2tlbiBpbiAoTUFSSywgJ1tUU1BfUk9PTU9CSl9WMjhdIGNsdXR0ZXI9JywgJ2lzSW50ZXJpb3JDbHV0dGVyT2JqZWN0UmVzaWRlbnQob3JpZ2luKScsCiAgICAgICAgICAgICAgJ2NsZWFySW50ZXJpb3JDbHV0dGVyUmVzaWRlbmN5KCk7JywgJ3VubG9hZC1wdXJnZSBwYXJrZWQ9Jyk6CiAgICBpZiB0b2tlbiBub3QgaW4gc2M6CiAgICAgICAgcmFpc2UgUnVudGltZUVycm9yKCdzY2VuZS5jcHAgVjI4IHBvc3Rjb25kaXRpb24gbWlzc2luZzogJyArIHRva2VuKQpmb3IgdG9rZW4gaW4gKE1BUkssICdzQ2x1dHRlckVuYWJsZWQnLCAnc0NsdXR0ZXJWaXNpYmxlTWFzaycsICdmYWxsYmFja093bmVyc2hpcCA9IDI2MC5mJywKICAgICAgICAgICAgICAnc2V0SW50ZXJpb3JDbHV0dGVyUmVzaWRlbmN5KCcsICdpc0ludGVyaW9yQ2x1dHRlck9iamVjdFJlc2lkZW50KCcpOgogICAgaWYgdG9rZW4gbm90IGluIHZjOgogICAgICAgIHJhaXNlIFJ1bnRpbWVFcnJvcignaW50ZXJpb3J2aXNpYmlsaXR5LmNwcCBWMjggcG9zdGNvbmRpdGlvbiBtaXNzaW5nOiAnICsgdG9rZW4pCmZvciB0b2tlbiBpbiAoTUFSSywgJ3NldEludGVyaW9yQ2x1dHRlclJlc2lkZW5jeSgnLCAnaXNJbnRlcmlvckNsdXR0ZXJSZXNpZGVuY3lFbmFibGVkJyk6CiAgICBpZiB0b2tlbiBub3QgaW4gdmg6CiAgICAgICAgcmFpc2UgUnVudGltZUVycm9yKCdpbnRlcmlvcnZpc2liaWxpdHkuaHBwIFYyOCBwb3N0Y29uZGl0aW9uIG1pc3Npbmc6ICcgKyB0b2tlbikKZm9yIHRva2VuIGluIChNQVJLLCAnYXBpWyJzZXRJbnRlcmlvckNsdXR0ZXJSZXNpZGVuY3kiXScsICdhcGlbImNsZWFySW50ZXJpb3JDbHV0dGVyUmVzaWRlbmN5Il0nKToKICAgIGlmIHRva2VuIG5vdCBpbiBjYjoKICAgICAgICByYWlzZSBSdW50aW1lRXJyb3IoJ2NhbWVyYWJpbmRpbmdzLmNwcCBWMjggcG9zdGNvbmRpdGlvbiBtaXNzaW5nOiAnICsgdG9rZW4pCgp3cml0ZShzY2VuZV9wYXRoLCBzYykKd3JpdGUodmlzX2NwcF9wYXRoLCB2YykKd3JpdGUodmlzX2hwcF9wYXRoLCB2aCkKd3JpdGUoY2FtZXJhX3BhdGgsIGNiKQpwcmludCgnUEFTUzogVjI4IGRlZGljYXRlZCBjbHV0dGVyLXJlc2lkZW5jeSBlbmdpbmUgc3RhdGUgYWRkZWQuJykKcHJpbnQoJ1BBU1M6IHN0cnVjdHVyYWwvZm9nIGNsZWFySW50ZXJpb3JUb3BvbG9neVB2cyBjYW5ub3QgZGlzYWJsZSBjbHV0dGVyIHJlc2lkZW5jeS4nKQpwcmludCgnUEFTUzogVjI3IEJhbG1vcmEgb3duZXJzaGlwIGZhbGxiYWNrIHJldGFpbmVkOiBYWT0wLCBaPTExMCwgbmVhcmVzdDw9MjYwLicpCnByaW50KCdQQVNTOiBTY2VuZSBsaWZlY3ljbGUgbm93IGtleXMgb25seSBmcm9tIHRoZSBpbmRlcGVuZGVudCBjbHV0dGVyIG1hc2suJykKcHJpbnQoJ1BBU1M6IGNsdXR0ZXIgc3RhdGUgaXMgY2xlYXJlZCBleHBsaWNpdGx5IG9uIGNlbGwgY2hhbmdlL3VubG9hZC4nKQo=
V28_CPP_B64
python3 -m py_compile "$TMP/v28_cpp_patch.py"
docker cp "$TMP/v28_cpp_patch.py" "$CTR:/tmp/v28_cpp_patch.py"
docker exec "$CTR" python3 /tmp/v28_cpp_patch.py "$SCENE_CPP" "$VIS_CPP" "$VIS_HPP" "$CAMERA"
docker exec -i "$CTR" bash -s --   "$SCENE_CPP" "$VIS_CPP" "$CAMERA" "$ANIM" <<'REMOTE_V28_CPP_VERIFY'
set -euo pipefail

SCENE_CPP="$1"
VIS_CPP="$2"
CAMERA="$3"
ANIM="$4"

check_has() {
  local token="$1"
  local file="$2"

  if ! grep -Fq -- "$token" "$file"; then
    echo "FAIL step3 marker: [$token]" >&2
    echo "FILE: $file" >&2
    echo "FOUND: 0 occurrences" >&2
    exit 71
  fi

  echo "PASS step3 marker: $token"
}

check_absent() {
  local token="$1"
  local file="$2"

  if grep -Fq -- "$token" "$file"; then
    echo "FAIL step3 forbidden marker survived: [$token]" >&2
    echo "FILE: $file" >&2
    exit 72
  fi

  echo "PASS step3 absent: $token"
}

check_has 'TSP_ROOM_OBJECT_SEPARATE_CLUTTER_051_V28' "$SCENE_CPP"
check_has '[TSP_ROOMOBJ_V28] clutter=' "$SCENE_CPP"
check_has 'sClutterEnabled' "$VIS_CPP"
check_has 'isInteriorClutterObjectResident' "$VIS_CPP"
check_has 'api["setInteriorClutterResidency"]' "$CAMERA"
check_has 'fallbackOwnership = 260.f' "$VIS_CPP"
check_absent 'mPtr.get<ESM::Static>()' "$ANIM"
REMOTE_V28_CPP_VERIFY

echo
echo "===== 4/9 GENERATE V28 LUA / PATCH LAUNCHER ====="
base64 -d > "$TMP/v28_lua_patch.py" <<'V28_LUA_B64'
IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwppbXBvcnQgc3lzCnNyY19wYXRoLCBkc3RfcGF0aCA9IHN5cy5hcmd2WzE6M10KCmRlZiByZWFkKHBhdGgpOgogICAgd2l0aCBvcGVuKHBhdGgsICdyJywgZW5jb2Rpbmc9J3V0Zi04JywgbmV3bGluZT0nJykgYXMgZjoKICAgICAgICByZXR1cm4gZi5yZWFkKCkKCmRlZiB3cml0ZShwYXRoLCB0ZXh0KToKICAgIHdpdGggb3BlbihwYXRoLCAndycsIGVuY29kaW5nPSd1dGYtOCcsIG5ld2xpbmU9J1xuJykgYXMgZjoKICAgICAgICBmLndyaXRlKHRleHQpCgpzID0gcmVhZChzcmNfcGF0aCkKTUFSSyA9ICdUU1BfVklTR1JJRF9MVUFfVjI4X1NFUEFSQVRFX0NMVVRURVInCmZvciB0b2tlbiBpbiAoCiAgICAnVFNQX1ZJU0dSSURfTFVBX1YyN19BREFQVElWRV9DTFVUVEVSJywKICAgICdtYXBTdGF0ZS51cGRhdGVUb3BvbG9neVB2cyA9IGZ1bmN0aW9uKGZvcmNlKScsCiAgICAndjI3U2VjdG9yRGlzdGFuY2UnLAogICAgImtpbmQgPT0gJ3ZlcnRpY2FsX2Nvbm5lY3RvciciLAogICAgJ2NhbWVyYS5zZXRJbnRlcmlvclRvcG9sb2d5UHZzJywKKToKICAgIGlmIHRva2VuIG5vdCBpbiBzOgogICAgICAgIHJhaXNlIFJ1bnRpbWVFcnJvcignVjI3IHByb2ZpbGUgdG9rZW4gbWlzc2luZzogJyArIHRva2VuKQppZiBNQVJLIGluIHM6CiAgICByYWlzZSBSdW50aW1lRXJyb3IoJ1YyOCBtYXJrZXIgYWxyZWFkeSBwcmVzZW50JykKCnN0YXJ0X21hcmtlciA9ICdcbi0tIFRTUF9WSVNHUklEX0xVQV9WMjdfQURBUFRJVkVfQ0xVVFRFUlxuJwplbmRfbWFya2VyID0gJ2xvY2FsIGZ1bmN0aW9uIG9uSW5pdCgpXG4nCmlmIHMuY291bnQoc3RhcnRfbWFya2VyKSAhPSAxIG9yIHMuY291bnQoZW5kX21hcmtlcikgIT0gMToKICAgIHJhaXNlIFJ1bnRpbWVFcnJvcignY291bGQgbm90IHVuaXF1ZWx5IGlzb2xhdGUgVjI3IG92ZXJyaWRlJykKYSA9IHMuaW5kZXgoc3RhcnRfbWFya2VyKSArIDEKYiA9IHMuaW5kZXgoZW5kX21hcmtlciwgYSkKCnYyOCA9IHInJyctLSBUU1BfVklTR1JJRF9MVUFfVjI4X1NFUEFSQVRFX0NMVVRURVIKLS0gSEFSRCBjbHV0dGVyIHJlc2lkZW5jeSBpcyBub3cgYW4gaW5kZXBlbmRlbnQgZW5naW5lIGNoYW5uZWwuIFRoZSBub3JtYWwKLS0gVklTR1JJRCBncmlkL2ZvZy9zdHJ1Y3R1cmFsIHNhZmV0eSBjb2RlIG1heSBjbGVhciBpdHMgb3duIHRvcG9sb2d5IFBWUyBhdCBhbnkKLS0gdGltZTsgdGhhdCBubyBsb25nZXIgcmVzdXJyZWN0cyBhbGwgY2x1dHRlci4KLS0KLS0gQ3VycmVudCByb29tIGlzIGFsd2F5cyByZXNpZGVudC4gRXh0cmEgY2x1dHRlciByb29tcyBhcmUgc2VsZWN0ZWQgc3RyaWN0bHkgYnkKLS0gMy1EIGRpc3RhbmNlIHRvIHRoZWlyIHNlY3RvciBBQUJCLiBUb3BvbG9naWNhbCBhZGphY2VuY3kgaXMgb25seSBhIHRpZS1icmVha2VyOwotLSBpdCBjYW4gbmV2ZXIga2VlcCBhIGRpc3RhbnQgbG93ZXIgZmxvb3IgYWxpdmUgbWVyZWx5IGJlY2F1c2UgYSBzdGFpcmNhc2Ugam9pbnMgaXQuCm1hcFN0YXRlLnYyOENsdXR0ZXJCcmlkZ2UgPSB0eXBlKGNhbWVyYS5zZXRJbnRlcmlvckNsdXR0ZXJSZXNpZGVuY3kpID09ICdmdW5jdGlvbicKICAgIGFuZCB0eXBlKGNhbWVyYS5jbGVhckludGVyaW9yQ2x1dHRlclJlc2lkZW5jeSkgPT0gJ2Z1bmN0aW9uJwptYXBTdGF0ZS52MjhDbHV0dGVyU2lnbmF0dXJlID0gJycKbWFwU3RhdGUudjI4QWN0aXZlSWRzID0gJycKbWFwU3RhdGUudjI4QWN0aXZlUmFuZ2UgPSAwCm1hcFN0YXRlLnYyOEFjdGl2ZUxpbWl0ID0gMAptYXBTdGF0ZS52MjhDdXJyZW50S2luZCA9ICd1bm1hcHBlZCcKbWFwU3RhdGUudjI4TGFzdFByaW50ID0gJycKbWFwU3RhdGUudjI4TmV4dFB1Ymxpc2ggPSAwLjAKCmxvY2FsIGZ1bmN0aW9uIHYyOEF4aXNHYXAodiwgbG8sIGhpKQogICAgaWYgdiA8IGxvIHRoZW4gcmV0dXJuIGxvIC0gdiBlbmQKICAgIGlmIHYgPiBoaSB0aGVuIHJldHVybiB2IC0gaGkgZW5kCiAgICByZXR1cm4gMC4wCmVuZAoKbG9jYWwgZnVuY3Rpb24gdjI4U2VjdG9yRGlzdGFuY2Uoc2VjLCB4LCB5LCB6KQogICAgaWYgc2VjID09IG5pbCBvciBzZWMuYmJveCA9PSBuaWwgdGhlbiByZXR1cm4gMS4wZTMwIGVuZAogICAgbG9jYWwgYiA9IHNlYy5iYm94CiAgICBsb2NhbCBkeCA9IHYyOEF4aXNHYXAoeCwgdG9udW1iZXIoYlsxXSBvciAwKSwgdG9udW1iZXIoYls0XSBvciAwKSkKICAgIGxvY2FsIGR5ID0gdjI4QXhpc0dhcCh5LCB0b251bWJlcihiWzJdIG9yIDApLCB0b251bWJlcihiWzVdIG9yIDApKQogICAgLS0gUGxheWVyLXRvLXJvb20gcHJlLXJlbmRlciBzZWxlY3Rpb24gdXNlcyBkZWxpYmVyYXRlbHkgdGlnaHRlciBaIGZvcmdpdmVuZXNzCiAgICAtLSB0aGFuIG9iamVjdCBvd25lcnNoaXAuIFRoaXMgaXMgd2hhdCBwcmV2ZW50cyBhIGxvd2VyLWZsb29yIHJvb20gZnJvbSBzdGF5aW5nCiAgICAtLSBsaXZlIHdoaWxlIHRoZSBwbGF5ZXIgc3RhbmRzIGF0IHRoZSBmYXIgZW5kL3RvcCBvZiBhIHZlcnRpY2FsIGNvbm5lY3Rvci4KICAgIGxvY2FsIGxveiA9IHRvbnVtYmVyKGJbM10gb3IgMCkgLSA0MC4wCiAgICBsb2NhbCBoaXogPSB0b251bWJlcihiWzZdIG9yIDApICsgNDAuMAogICAgbG9jYWwgZHogPSB2MjhBeGlzR2FwKHosIGxveiwgaGl6KQogICAgcmV0dXJuIG1hdGguc3FydChkeCpkeCArIGR5KmR5ICsgZHoqZHopCmVuZAoKbG9jYWwgZnVuY3Rpb24gdjI4UG9saWN5KGtpbmQsIHRvdGFsKQogICAgbG9jYWwgbWF4RXh0cmEsIHJhbmdlCiAgICBpZiBraW5kID09ICdzbWFsbF9yb29tJyB0aGVuCiAgICAgICAgbWF4RXh0cmEsIHJhbmdlID0gMSwgMjQwLjAKICAgIGVsc2VpZiBraW5kID09ICdsYXJnZV9vcGVuJyB0aGVuCiAgICAgICAgbWF4RXh0cmEsIHJhbmdlID0gMiwgNTYwLjAKICAgIGVsc2VpZiBraW5kID09ICdjb3JyaWRvcicgdGhlbgogICAgICAgIG1heEV4dHJhLCByYW5nZSA9IDIsIDUwMC4wCiAgICBlbHNlaWYga2luZCA9PSAndmVydGljYWxfY29ubmVjdG9yJyB0aGVuCiAgICAgICAgLS0gU3RhaXJjYXNlcyBhcmUgdGhlIGNyaXRpY2FsIHBlcmZvcm1hbmNlIGNhc2U6IGN1cnJlbnQgY29ubmVjdG9yIHBsdXMKICAgICAgICAtLSBPTkUgcGh5c2ljYWxseS1jbG9zZSBlbmRwb2ludCByb29tLCBuZXZlciBhbiBlbnRpcmUgY2hhaW4gb2YgZmxvb3JzLgogICAgICAgIG1heEV4dHJhLCByYW5nZSA9IDEsIDMwMC4wCiAgICBlbHNlCiAgICAgICAgbWF4RXh0cmEsIHJhbmdlID0gMSwgMzMwLjAKICAgIGVuZAoKICAgIC0tIFByZXNlcnZlIFYyNydzIEJhbG1vcmEgY29ycmVjdG5lc3Mgd2l0aG91dCBpdHMgNzAwLXVuaXQgc3RhaXJjYXNlIGxlYWsuCiAgICAtLSBDb2Fyc2UgPD0zLXNlY3RvciBtYXBzIG1heSBwcmVsb2FkIHR3byByb29tcyBvbmx5IHdoaWxlIHRoZSBwbGF5ZXIgaXMgaW4gYQogICAgLS0gcmVhbCByb29tOyBhIGNvbm5lY3RvciBzdGlsbCBnZXRzIGV4YWN0bHkgb25lIGNsb3NlIGVuZHBvaW50LgogICAgaWYgdG90YWwgPD0gMyB0aGVuCiAgICAgICAgaWYga2luZCA9PSAndmVydGljYWxfY29ubmVjdG9yJyB0aGVuCiAgICAgICAgICAgIHJhbmdlID0gbWF0aC5tYXgocmFuZ2UsIDM2MC4wKQogICAgICAgIGVsc2UKICAgICAgICAgICAgbWF4RXh0cmEgPSBtYXRoLm1heChtYXhFeHRyYSwgbWF0aC5taW4oMiwgbWF0aC5tYXgoMCwgdG90YWwgLSAxKSkpCiAgICAgICAgICAgIHJhbmdlID0gbWF0aC5tYXgocmFuZ2UsIDQ0MC4wKQogICAgICAgIGVuZAogICAgZW5kCiAgICByZXR1cm4gbWF4RXh0cmEsIHJhbmdlCmVuZAoKbG9jYWwgZnVuY3Rpb24gdjI4VGFyZ2V0Qm9vc3Qoa2luZCkKICAgIGlmIGtpbmQgPT0gJ2xhcmdlX29wZW4nIHRoZW4gcmV0dXJuIDEyMC4wIGVuZAogICAgaWYga2luZCA9PSAnY29ycmlkb3InIHRoZW4gcmV0dXJuIDgwLjAgZW5kCiAgICBpZiBraW5kID09ICd2ZXJ0aWNhbF9jb25uZWN0b3InIHRoZW4gcmV0dXJuIDQwLjAgZW5kCiAgICByZXR1cm4gMC4wCmVuZAoKbWFwU3RhdGUudXBkYXRlVG9wb2xvZ3lQdnMgPSBmdW5jdGlvbihmb3JjZSkKICAgIC0tIFRoaXMgZnVuY3Rpb24gbmFtZSBpcyByZXRhaW5lZCBiZWNhdXNlIHRoZSBleGlzdGluZyBWMjQgY2FsbCBzaXRlcyBhbHJlYWR5CiAgICAtLSBpbnZva2UgaXQgYXQgdGhlIHJpZ2h0IHRvcG9sb2d5IHJlZnJlc2ggcG9pbnRzLiBJdHMgVjI4IGpvYiBpcyBDTFVUVEVSIE9OTFkuCiAgICBpZiBub3QgbWFwU3RhdGUudjI4Q2x1dHRlckJyaWRnZSBvciBtYXBTdGF0ZS50b3BvQ2VsbCA9PSBuaWwKICAgICAgICBvciBtYXBTdGF0ZS5wdnNCb3hlcyA9PSBuaWwgdGhlbgogICAgICAgIGlmIG1hcFN0YXRlLnYyOENsdXR0ZXJCcmlkZ2UgdGhlbiBwY2FsbChjYW1lcmEuY2xlYXJJbnRlcmlvckNsdXR0ZXJSZXNpZGVuY3kpIGVuZAogICAgICAgIG1hcFN0YXRlLnYyOENsdXR0ZXJTaWduYXR1cmUgPSAnJwogICAgICAgIG1hcFN0YXRlLnYyOEFjdGl2ZUlkcyA9ICcnCiAgICAgICAgbWFwU3RhdGUudjI4TmV4dFB1Ymxpc2ggPSAwLjAKICAgICAgICBpZiBmb3JjZSBvciBtYXBTdGF0ZS52MjhMYXN0UHJpbnQgfj0gJ2JyaWRnZS1vZmYnIHRoZW4KICAgICAgICAgICAgbWFwU3RhdGUudjI4TGFzdFByaW50ID0gJ2JyaWRnZS1vZmYnCiAgICAgICAgICAgIHByaW50KCdbVFNQX1ZJU0dSSURfVjI4XSBjbHV0dGVyIGJyaWRnZS90b3BvbG9neSB1bmF2YWlsYWJsZSAtPiBmYWlsLW9wZW4nKQogICAgICAgIGVuZAogICAgICAgIHJldHVybgogICAgZW5kCgogICAgbG9jYWwgY3VycmVudCA9IHRvbnVtYmVyKG1hcFN0YXRlLnRvcG9TZWN0b3JJZCBvciAwKSBvciAwCiAgICBsb2NhbCB0b3RhbCA9IHRvbnVtYmVyKG1hcFN0YXRlLnB2c1NlY3RvckNvdW50IG9yIDApIG9yIDAKICAgIGxvY2FsIGN1cnJlbnRTZWMgPSBjdXJyZW50ID4gMCBhbmQgbWFwU3RhdGUudG9wb0NlbGwuc2VjdG9yc1tjdXJyZW50XSBvciBuaWwKICAgIGlmIGN1cnJlbnQgPD0gMCBvciBjdXJyZW50U2VjID09IG5pbCBvciB0b3RhbCA8PSAwIHRoZW4KICAgICAgICBwY2FsbChjYW1lcmEuY2xlYXJJbnRlcmlvckNsdXR0ZXJSZXNpZGVuY3kpCiAgICAgICAgbWFwU3RhdGUudjI4Q2x1dHRlclNpZ25hdHVyZSA9ICcnCiAgICAgICAgbWFwU3RhdGUudjI4QWN0aXZlSWRzID0gJycKICAgICAgICBtYXBTdGF0ZS52MjhOZXh0UHVibGlzaCA9IDAuMAogICAgICAgIGlmIGZvcmNlIG9yIG1hcFN0YXRlLnYyOExhc3RQcmludCB+PSAndW5tYXBwZWQnIHRoZW4KICAgICAgICAgICAgbWFwU3RhdGUudjI4TGFzdFByaW50ID0gJ3VubWFwcGVkJwogICAgICAgICAgICBwcmludChzdHJpbmcuZm9ybWF0KCdbVFNQX1ZJU0dSSURfVjI4XSBjbHV0dGVyIFVOTUFQUEVEIGN1cnJlbnQ9JWQgdG90YWw9JWQgLT4gZmFpbC1vcGVuJywKICAgICAgICAgICAgICAgIGN1cnJlbnQsIHRvdGFsKSkKICAgICAgICBlbmQKICAgICAgICByZXR1cm4KICAgIGVuZAoKICAgIGxvY2FsIGNjID0gY3VycmVudFNlYy5jZW50ZXIgb3IgezAsIDAsIDB9CiAgICBsb2NhbCB4ID0gdG9udW1iZXIobWFwU3RhdGUudG9wb1ggb3IgY2NbMV0gb3IgMCkgb3IgMAogICAgbG9jYWwgeSA9IHRvbnVtYmVyKG1hcFN0YXRlLnRvcG9ZIG9yIGNjWzJdIG9yIDApIG9yIDAKICAgIGxvY2FsIHogPSB0b251bWJlcihtYXBTdGF0ZS50b3BvWiBvciBjY1szXSBvciAwKSBvciAwCiAgICBsb2NhbCBraW5kID0gdG9zdHJpbmcoY3VycmVudFNlYy5raW5kIG9yICdyb29tJykKICAgIGxvY2FsIG1heEV4dHJhLCBiYXNlUmFuZ2UgPSB2MjhQb2xpY3koa2luZCwgdG90YWwpCgogICAgbG9jYWwgbmVpZ2hib3IgPSB7fQogICAgaWYgY3VycmVudFNlYy5uZWlnaGJvcnMgfj0gbmlsIHRoZW4KICAgICAgICBmb3IgaSA9IDEsICNjdXJyZW50U2VjLm5laWdoYm9ycyBkbwogICAgICAgICAgICBuZWlnaGJvclt0b251bWJlcihjdXJyZW50U2VjLm5laWdoYm9yc1tpXSBvciAwKSBvciAwXSA9IHRydWUKICAgICAgICBlbmQKICAgIGVuZAoKICAgIGxvY2FsIGNhbmRpZGF0ZXMgPSB7fQogICAgZm9yIHNpZCwgc2VjIGluIHBhaXJzKG1hcFN0YXRlLnRvcG9DZWxsLnNlY3RvcnMpIGRvCiAgICAgICAgc2lkID0gdG9udW1iZXIoc2lkIG9yIDApIG9yIDAKICAgICAgICBpZiBzaWQgPiAwIGFuZCBzaWQgfj0gY3VycmVudCBhbmQgc2VjIH49IG5pbCB0aGVuCiAgICAgICAgICAgIGNhbmRpZGF0ZXNbI2NhbmRpZGF0ZXMgKyAxXSA9IHsKICAgICAgICAgICAgICAgIGlkID0gc2lkLAogICAgICAgICAgICAgICAgZCA9IHYyOFNlY3RvckRpc3RhbmNlKHNlYywgeCwgeSwgeiksCiAgICAgICAgICAgICAgICBuZWFyID0gbmVpZ2hib3Jbc2lkXSA9PSB0cnVlLAogICAgICAgICAgICAgICAga2luZCA9IHRvc3RyaW5nKHNlYy5raW5kIG9yICdyb29tJyksCiAgICAgICAgICAgIH0KICAgICAgICBlbmQKICAgIGVuZAoKICAgIC0tIFBIWVNJQ0FMIERJU1RBTkNFIEZJUlNULiBBIGZhciBmaXJzdC1mbG9vciBuYXZtZXNoIG5laWdoYm9yIGNhbm5vdCBiZWF0IGEKICAgIC0tIGNsb3NlIHRoaXJkLWZsb29yIHJvb20gbWVyZWx5IGJlY2F1c2UgYm90aCBjb25uZWN0IHRvIHRoZSBzYW1lIHN0YWlyY2FzZS4KICAgIHRhYmxlLnNvcnQoY2FuZGlkYXRlcywgZnVuY3Rpb24oYSwgYikKICAgICAgICBpZiBhLmQgfj0gYi5kIHRoZW4gcmV0dXJuIGEuZCA8IGIuZCBlbmQKICAgICAgICBpZiBhLm5lYXIgfj0gYi5uZWFyIHRoZW4gcmV0dXJuIGEubmVhciBlbmQKICAgICAgICByZXR1cm4gYS5pZCA8IGIuaWQKICAgIGVuZCkKCiAgICBsb2NhbCBpZHMgPSB7IGN1cnJlbnQgfQogICAgbG9jYWwgZXh0cmEgPSAwCiAgICBmb3IgaSA9IDEsICNjYW5kaWRhdGVzIGRvCiAgICAgICAgaWYgZXh0cmEgPj0gbWF4RXh0cmEgdGhlbiBicmVhayBlbmQKICAgICAgICBsb2NhbCBjID0gY2FuZGlkYXRlc1tpXQogICAgICAgIGxvY2FsIGxpbWl0ID0gYmFzZVJhbmdlCiAgICAgICAgLS0gQ29ubmVjdG9yIGN1cnJlbnQgc2VjdG9ycyBkZWxpYmVyYXRlbHkgcmVjZWl2ZSBOTyBkZXN0aW5hdGlvbiBib29zdC4KICAgICAgICAtLSBUaGlzIGtlZXBzIHJlbW90ZSBzdGFpcmNhc2UgZW5kcG9pbnQgcm9vbXMgZGVhZCB1bnRpbCBhY3R1YWxseSBjbG9zZS4KICAgICAgICBpZiBraW5kIH49ICd2ZXJ0aWNhbF9jb25uZWN0b3InIHRoZW4KICAgICAgICAgICAgbGltaXQgPSBsaW1pdCArIHYyOFRhcmdldEJvb3N0KGMua2luZCkKICAgICAgICBlbmQKICAgICAgICBpZiBjLmQgPD0gbGltaXQgdGhlbgogICAgICAgICAgICBpZHNbI2lkcyArIDFdID0gYy5pZAogICAgICAgICAgICBleHRyYSA9IGV4dHJhICsgMQogICAgICAgIGVuZAogICAgZW5kCiAgICB0YWJsZS5zb3J0KGlkcykKCiAgICBsb2NhbCBzaWduYXR1cmUgPSAndjI4OicgLi4gdGFibGUuY29uY2F0KGlkcywgJywnKQogICAgLS0gUmVwdWJsaXNoIGF0IGxlYXN0IHR3aWNlL3NlY29uZCBldmVuIHdoZW4gdGhlIHJvb20gc2V0IGlzIHVuY2hhbmdlZC4gU2NlbmUKICAgIC0tIGRlbGliZXJhdGVseSBjbGVhcnMgY2x1dHRlciBhdXRob3JpdHkgb24gYSBDZWxsU3RvcmUgdHJhbnNpdGlvbjsgdGhpcwogICAgLS0gYm91bmRlZCBoZWFydGJlYXQgZ3VhcmFudGVlcyBhIGxhdGVyIEx1YSB1cGRhdGUgY2Fubm90IGxlYXZlIGl0IGF0IGNsdXR0ZXI9MAogICAgLS0gbWVyZWx5IGJlY2F1c2UgdGhlIHNlY3RvciBzaWduYXR1cmUgaGFwcGVuZWQgdG8gYmUgaWRlbnRpY2FsLgogICAgbG9jYWwgbm93ID0gdG9udW1iZXIoaW50ZXJpb3JFbGFwc2VkIG9yIDAuMCkgb3IgMC4wCiAgICBsb2NhbCBwdWJsaXNoID0gZm9yY2Ugb3Igc2lnbmF0dXJlIH49IG1hcFN0YXRlLnYyOENsdXR0ZXJTaWduYXR1cmUKICAgICAgICBvciBub3cgPj0gKG1hcFN0YXRlLnYyOE5leHRQdWJsaXNoIG9yIDAuMCkKICAgIGlmIHB1Ymxpc2ggdGhlbgogICAgICAgIGxvY2FsIG9rLCBlcnIgPSBwY2FsbChjYW1lcmEuc2V0SW50ZXJpb3JDbHV0dGVyUmVzaWRlbmN5LAogICAgICAgICAgICBtYXBTdGF0ZS5wdnNCb3hlcywgaWRzKQogICAgICAgIGlmIG9rIHRoZW4KICAgICAgICAgICAgbWFwU3RhdGUudjI4TmV4dFB1Ymxpc2ggPSBub3cgKyAwLjUwCiAgICAgICAgICAgIG1hcFN0YXRlLnYyOENsdXR0ZXJTaWduYXR1cmUgPSBzaWduYXR1cmUKICAgICAgICAgICAgbWFwU3RhdGUudjI4QWN0aXZlSWRzID0gdGFibGUuY29uY2F0KGlkcywgJywnKQogICAgICAgICAgICBtYXBTdGF0ZS52MjhBY3RpdmVSYW5nZSA9IGJhc2VSYW5nZQogICAgICAgICAgICBtYXBTdGF0ZS52MjhBY3RpdmVMaW1pdCA9IG1heEV4dHJhCiAgICAgICAgICAgIG1hcFN0YXRlLnYyOEN1cnJlbnRLaW5kID0ga2luZAogICAgICAgICAgICBpZiBmb3JjZSBvciBzaWduYXR1cmUgfj0gbWFwU3RhdGUudjI4TGFzdFByaW50IHRoZW4KICAgICAgICAgICAgICAgIG1hcFN0YXRlLnYyOExhc3RQcmludCA9IHNpZ25hdHVyZQogICAgICAgICAgICAgICAgcHJpbnQoc3RyaW5nLmZvcm1hdCgKICAgICAgICAgICAgICAgICAgICAnW1RTUF9WSVNHUklEX1YyOF0gY2x1dHRlciBjdXJyZW50PSVkLyVkIGtpbmQ9JXMgYWN0aXZlPSVkIGlkcz0lcyBleHRyYU1heD0lZCBuZWFyUmFuZ2U9JS4wZiBwb3M9KCUuMGYsJS4wZiwlLjBmKScsCiAgICAgICAgICAgICAgICAgICAgY3VycmVudCwgdG90YWwsIGtpbmQsICNpZHMsIG1hcFN0YXRlLnYyOEFjdGl2ZUlkcywKICAgICAgICAgICAgICAgICAgICBtYXhFeHRyYSwgYmFzZVJhbmdlLCB4LCB5LCB6KSkKICAgICAgICAgICAgZW5kCiAgICAgICAgZWxzZQogICAgICAgICAgICBwcmludCgnW1RTUF9WSVNHUklEX1YyOF0gY2x1dHRlciBicmlkZ2UgZXJyb3I6ICcgLi4gdG9zdHJpbmcoZXJyKSkKICAgICAgICAgICAgcGNhbGwoY2FtZXJhLmNsZWFySW50ZXJpb3JDbHV0dGVyUmVzaWRlbmN5KQogICAgICAgICAgICBtYXBTdGF0ZS52MjhDbHV0dGVyU2lnbmF0dXJlID0gJycKICAgICAgICAgICAgbWFwU3RhdGUudjI4TmV4dFB1Ymxpc2ggPSAwLjAKICAgICAgICBlbmQKICAgIGVuZAplbmQKCicnJwpzID0gc1s6YV0gKyB2MjggKyBzW2I6XQoKc3RhcnR1cCA9ICJwcmludCgnW1RTUF9WSVNHUklEX1YyN10gQURBUFRJVkUtQ0xVVFRFUiBzdHJ1Y3R1cmUtb3Blbj0xIGN1cnJlbnQtcGx1cy1uZWFyPTEgcmF5cz01LzYgZm9nPXJlc3RvcmVkJykiCmlmIHMuY291bnQoc3RhcnR1cCkgIT0gMToKICAgIHJhaXNlIFJ1bnRpbWVFcnJvcignVjI3IHN0YXJ0dXAgbWFya2VyIGNvdW50PSVkLCBleHBlY3RlZCAxJyAlIHMuY291bnQoc3RhcnR1cCkpCnMgPSBzLnJlcGxhY2UoCiAgICBzdGFydHVwLAogICAgc3RhcnR1cCArICJcbnByaW50KCdbVFNQX1ZJU0dSSURfVjI4XSBTRVBBUkFURS1DTFVUVEVSLU1BU0sgc3RydWN0dXJlLW9wZW49MSBjb25uZWN0b3I9MStuZWFyZXN0IHJheXM9NS82JykiLAogICAgMSkKCmZvciB0b2tlbiBpbiAoCiAgICBNQVJLLAogICAgJ2NhbWVyYS5zZXRJbnRlcmlvckNsdXR0ZXJSZXNpZGVuY3knLAogICAgJ2NhbWVyYS5jbGVhckludGVyaW9yQ2x1dHRlclJlc2lkZW5jeScsCiAgICAnbWFwU3RhdGUudjI4TmV4dFB1Ymxpc2ggPSBub3cgKyAwLjUwJywKICAgICJtYXhFeHRyYSwgcmFuZ2UgPSAxLCAzMDAuMCIsCiAgICAnaWYgYS5kIH49IGIuZCB0aGVuIHJldHVybiBhLmQgPCBiLmQgZW5kJywKICAgICJraW5kIH49ICd2ZXJ0aWNhbF9jb25uZWN0b3InIiwKICAgICdbVFNQX1ZJU0dSSURfVjI4XSBTRVBBUkFURS1DTFVUVEVSLU1BU0snLAopOgogICAgaWYgdG9rZW4gbm90IGluIHM6CiAgICAgICAgcmFpc2UgUnVudGltZUVycm9yKCdWMjggTHVhIHBvc3Rjb25kaXRpb24gbWlzc2luZzogJyArIHRva2VuKQppZiAnbWFwU3RhdGUucHZzQm94ZXMsIGlkcywgMC4wLCAwLjAnIGluIHNbYTphK2xlbih2MjgpKzIwMF06CiAgICByYWlzZSBSdW50aW1lRXJyb3IoJ1YyNyBzdHJ1Y3R1cmFsLVBWUyBjbHV0dGVyIHB1Ymxpc2ggc3Vydml2ZWQgb3ZlcnJpZGUgcmVwbGFjZW1lbnQnKQoKd3JpdGUoZHN0X3BhdGgsIHMpCnByaW50KCdQQVNTOiBWMjggTHVhIHVzZXMgaW5kZXBlbmRlbnQgY2x1dHRlciBicmlkZ2UsIG5vdCBzdHJ1Y3R1cmFsIFBWUy4nKQpwcmludCgnUEFTUzogcGh5c2ljYWwgQUFCQiBkaXN0YW5jZSBzb3J0cyBiZWZvcmUgdG9wb2xvZ3kgYWRqYWNlbmN5LicpCnByaW50KCdQQVNTOiB2ZXJ0aWNhbF9jb25uZWN0b3IgPSBjdXJyZW50ICsgYXQgbW9zdCBvbmUgY2xvc2Ugcm9vbSAoMzAwOyAzNjAgaW4gPD0zLXNlY3RvciBtYXBzKS4nKQpwcmludCgnUEFTUzogPD0zLXNlY3RvciBCYWxtb3JhIHNhZmV0eSByZXRhaW5lZCBvbmx5IGFzIGJvdW5kZWQgcm9vbS9jb2Fyc2UgZmFsbGJhY2ssIG5vdCA3MDAtdW5pdCBjb25uZWN0b3IgcmVhY2guJykK
V28_LUA_B64
base64 -d > "$TMP/v28_launcher_patch.py" <<'V28_LAUNCH_B64'
IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwppbXBvcnQgc3lzCnNyY19wYXRoLCBkc3RfcGF0aCA9IHN5cy5hcmd2WzE6M10KCmRlZiByZWFkKHBhdGgpOgogICAgd2l0aCBvcGVuKHBhdGgsICdyJywgZW5jb2Rpbmc9J3V0Zi04JywgbmV3bGluZT0nJykgYXMgZjoKICAgICAgICByZXR1cm4gZi5yZWFkKCkKCmRlZiB3cml0ZShwYXRoLCB0ZXh0KToKICAgIHdpdGggb3BlbihwYXRoLCAndycsIGVuY29kaW5nPSd1dGYtOCcsIG5ld2xpbmU9J1xuJykgYXMgZjoKICAgICAgICBmLndyaXRlKHRleHQpCgpzID0gcmVhZChzcmNfcGF0aCkKb2xkX3Byb2ZpbGUgPSAnJFRTUF9WSVNHUklEX0RJUi92MjdfcHJvZmlsZXMvdmlzZ3JpZC12MjctYWRhcHRpdmUtY2x1dHRlci5sdWEnCm5ld19wcm9maWxlID0gJyRUU1BfVklTR1JJRF9ESVIvdjI4X3Byb2ZpbGVzL3Zpc2dyaWQtdjI4LXNlcGFyYXRlLWNsdXR0ZXIubHVhJwppZiBzLmNvdW50KG9sZF9wcm9maWxlKSAhPSAxOgogICAgcmFpc2UgUnVudGltZUVycm9yKCdWMjcgc2VsZWN0ZWQtcHJvZmlsZSBwYXRoIGNvdW50PSVkLCBleHBlY3RlZCAxJyAlIHMuY291bnQob2xkX3Byb2ZpbGUpKQpzID0gcy5yZXBsYWNlKG9sZF9wcm9maWxlLCBuZXdfcHJvZmlsZSwgMSkKCnMgPSBzLnJlcGxhY2UoJ2V4cG9ydCBUU1BfT0JKRUNUX0RJQUc9MScsICdleHBvcnQgVFNQX09CSkVDVF9ESUFHPTAgICMgVjI4IGNvbXBhY3QgZGlhZ25vc3RpY3Mgb25seScpCnMgPSBzLnJlcGxhY2UoJ2V4cG9ydCBUU1BfT0JKRUNUX0RJQUc9MCAgIyBWMjcgY29tcGFjdCBkaWFnbm9zdGljcyBvbmx5JywKICAgICAgICAgICAgICAnZXhwb3J0IFRTUF9PQkpFQ1RfRElBRz0wICAjIFYyOCBjb21wYWN0IGRpYWdub3N0aWNzIG9ubHknKQpzID0gcy5yZXBsYWNlKCdWaXNncmlkIFByb2ZpbGU9djI3LWFkYXB0aXZlLWNsdXR0ZXInLCAnVmlzZ3JpZCBQcm9maWxlPXYyOC1zZXBhcmF0ZS1jbHV0dGVyJykKcyA9IHMucmVwbGFjZSgKICAgICdWaXNncmlkIHJvb20gcG9saWN5PWFkYXB0aXZlIGNsdXR0ZXIgcm9vbXM7IHN0YXRpYyBzdHJ1Y3R1cmUgb3BlbjsgVjI0IHJheXMvZm9nIHJlc3RvcmVkJywKICAgICdWaXNncmlkIHJvb20gcG9saWN5PWluZGVwZW5kZW50IGNsdXR0ZXIgbWFzazsgY29ubmVjdG9yIGN1cnJlbnQrbmVhcmVzdDsgc3RydWN0dXJlIG9wZW47IFYyNCByYXlzL2ZvZycpCgpiZWdpbiA9ICcjID4+PiBUU1BfVklTR1JJRF9WMjRfQVVUT19DQVBUVVJFIEJFR0lOJwplbmQgPSAnIyA8PDwgVFNQX1ZJU0dSSURfVjI0X0FVVE9fQ0FQVFVSRSBFTkQnCmlmIGJlZ2luIGluIHMgb3IgZW5kIGluIHM6CiAgICByYWlzZSBSdW50aW1lRXJyb3IoJ1YyNyBzaG91bGQgYWxyZWFkeSBoYXZlIHJlbW92ZWQgc3luY2hyb25vdXMgYXV0by1jYXB0dXJlJykKCmZvciB0b2tlbiBpbiAoJ3YyOF9wcm9maWxlcy92aXNncmlkLXYyOC1zZXBhcmF0ZS1jbHV0dGVyLmx1YScsICdWaXNncmlkIFByb2ZpbGU9djI4LXNlcGFyYXRlLWNsdXR0ZXInKToKICAgIGlmIHRva2VuIG5vdCBpbiBzOgogICAgICAgIHJhaXNlIFJ1bnRpbWVFcnJvcignbGF1bmNoZXIgVjI4IHBvc3Rjb25kaXRpb24gbWlzc2luZzogJyArIHRva2VuKQppZiAnZXhwb3J0IFRTUF9PQkpFQ1RfRElBRz0xJyBpbiBzOgogICAgcmFpc2UgUnVudGltZUVycm9yKCdlbmFibGVkIFRTUF9PQkpFQ1RfRElBRyBleHBvcnQgc3Vydml2ZWQnKQoKd3JpdGUoZHN0X3BhdGgsIHMpCnByaW50KCdQQVNTOiBsYXVuY2hlciBzZWxlY3RzIFYyOCBpbmRlcGVuZGVudCBjbHV0dGVyIHByb2ZpbGUuJykKcHJpbnQoJ1BBU1M6IGhlYXZ5IG9iamVjdCBkaWFnbm9zdGljcyByZW1haW4gZGlzYWJsZWQuJykKcHJpbnQoJ1BBU1M6IHN5bmNocm9ub3VzIG5vcm1hbC1leGl0IGNhcHR1cmUgcmVtYWlucyBhYnNlbnQuJykK
V28_LAUNCH_B64
python3 -m py_compile "$TMP/v28_lua_patch.py" "$TMP/v28_launcher_patch.py"
python3 "$TMP/v28_lua_patch.py" "$TMP/visgrid.v27.lua" "$TMP/visgrid.v28.lua"
python3 "$TMP/v28_launcher_patch.py" "$TMP/Morrowind_51.v27.sh" "$TMP/Morrowind_51.v28.sh"
chmod +x "$TMP/Morrowind_51.v28.sh"

if ! bash -n "$TMP/Morrowind_51.v28.sh"; then
  echo "FAIL step4 launcher syntax: $TMP/Morrowind_51.v28.sh" >&2
  exit 73
fi
echo "PASS step4 launcher bash syntax"

PARSER=""
for x in texlua lua luajit; do command -v "$x" >/dev/null 2>&1 && { PARSER="$x"; break; }; done
if [ -n "$PARSER" ]; then
  cat > "$TMP/parse.lua" <<'LUA'
local f,e=loadfile(arg[1]); if not f then error(e) end; print('LUA_PARSE_PASS '..arg[1])
LUA
  if ! "$PARSER" "$TMP/parse.lua" "$TMP/visgrid.v28.lua"; then
    echo "FAIL step4 Lua syntax: $TMP/visgrid.v28.lua (parser=$PARSER)" >&2
    exit 74
  fi
  echo "PASS step4 Lua syntax: parser=$PARSER"
fi
V28_LUA_SHA="$(sha256sum "$TMP/visgrid.v28.lua" | awk '{print $1}')"
echo "V28 Lua SHA: $V28_LUA_SHA"

echo
echo "===== 5/9 BUILD ====="
BUILD_LOG=/root/openmw51-visgrid-v28-separate-clutter-$STAMP.log
set +e
docker exec "$CTR" bash -lc "set -o pipefail; cd '$BUILD'; cmake --build . --target openmw --parallel '${OPENMW_JOBS:-2}' 2>&1 | tee '$BUILD_LOG'"
RC=$?
set -e
if [ "$RC" -ne 0 ]; then
    echo "BUILD FAILED — last 240 lines:"
    docker exec "$CTR" bash -lc "tail -n 240 '$BUILD_LOG' || true"
    false
fi

echo
echo "===== 6/9 PACKAGE / MULTI-VERIFY ====="
docker exec -i "$CTR" bash -s -- "$BUILT" "$PACKAGED" <<'REMOTE_V28_PACKAGE_VERIFY'
set -euo pipefail

BUILT="$1"
PACKAGED="$2"

if [ ! -s "$BUILT" ]; then
  echo "FAIL step6 built binary missing/empty: $BUILT" >&2
  exit 81
fi
echo "PASS step6 built binary present: $BUILT"

mkdir -p "$(dirname "$PACKAGED")"
install -m 755 "$BUILT" "$PACKAGED"

DESC="$(file "$PACKAGED")"
echo "$DESC"

if ! printf '%s
' "$DESC" | grep -Eq 'ARM aarch64|ARM64|AArch64'; then
  echo "FAIL step6 architecture: expected ARM64/AArch64" >&2
  echo "ACTUAL: $DESC" >&2
  exit 82
fi
echo "PASS step6 architecture: ARM64/AArch64"

sha256sum "$PACKAGED"

echo "INFO step6 embedded V28 strings:"
strings "$PACKAGED" |
  grep -E 'TSP_ROOMOBJ_V28|TSP_CLUTTER_V28|TSP_OBJECT_DIAG_051_V1' |
  sort -u | head -50 || true
REMOTE_V28_PACKAGE_VERIFY
NEW_SHA="$(docker exec "$CTR" sha256sum "$PACKAGED" | awk '{print $1}')"
[ "$NEW_SHA" != "$PRE_SHA" ] || die "rebuilt hash did not change"
docker cp "$CTR:$PACKAGED" "$HOST_BIN"
chmod +x "$HOST_BIN"
[ "$(sha256sum "$HOST_BIN" | awk '{print $1}')" = "$NEW_SHA" ] || die "Docker->Ubuntu SHA mismatch"
file "$HOST_BIN"
sha256sum "$HOST_BIN"

echo
echo "===== 7/9 VERIFY PROFILE / CLEAN EXIT PATH ====="
host_has() {
  local token="$1"
  local file="$2"

  if ! grep -Fq -- "$token" "$file"; then
    echo "FAIL step7 marker: [$token]" >&2
    echo "FILE: $file" >&2
    exit 91
  fi

  echo "PASS step7 marker: $token"
}

host_absent() {
  local token="$1"
  local file="$2"

  if grep -Fq -- "$token" "$file"; then
    echo "FAIL step7 forbidden marker: [$token]" >&2
    echo "FILE: $file" >&2
    exit 92
  fi

  echo "PASS step7 absent: $token"
}

host_has 'TSP_VISGRID_LUA_V28_SEPARATE_CLUTTER' "$TMP/visgrid.v28.lua"
host_has 'setInteriorClutterResidency' "$TMP/visgrid.v28.lua"
host_has 'v28_profiles/visgrid-v28-separate-clutter.lua' "$TMP/Morrowind_51.v28.sh"

host_absent '# >>> TSP_VISGRID_V24_AUTO_CAPTURE BEGIN' "$TMP/Morrowind_51.v28.sh"
host_absent 'export TSP_OBJECT_DIAG=1' "$TMP/Morrowind_51.v28.sh"

echo "PASS: independent clutter bridge selected."
echo "PASS: synchronous normal-exit capture remains absent."

echo
echo "===== 8/9 DEVICE BACKUP / INSTALL ====="
DEVICE_BACKUP="$ROOT/backups/visgrid-v28-separate-clutter-$STAMP"
ssh "$DEV" "bash -s" <<REMOTE_BACKUP
set -e
B='$DEVICE_BACKUP'
mkdir -p "\$B"
cp -pf '$REMOTE_BIN' "\$B/openmw-0.51.before"
cp -pf '$LIVE_LUA' "\$B/visgrid.lua.before"
cp -pf '$LAUNCHER' "\$B/launcher.before"
if [ -f '$V28_PROFILE' ]; then touch "\$B/v28-profile.existed"; cp -pf '$V28_PROFILE' "\$B/v28-profile.before"; fi
sha256sum "\$B/openmw-0.51.before" "\$B/visgrid.lua.before" "\$B/launcher.before"
REMOTE_BACKUP
DEVICE_DEPLOY_STARTED=1
scp -q "$HOST_BIN" "$DEV:$REMOTE_TMP_BIN"
scp -q "$TMP/visgrid.v28.lua" "$DEV:/tmp/visgrid-v28.lua"
scp -q "$TMP/Morrowind_51.v28.sh" "$DEV:/tmp/Morrowind_51.v28.sh"
ssh "$DEV" "bash -s -- '$V28_DIR' '$REMOTE_TMP_BIN' '$NEW_SHA' '$V28_LUA_SHA' '$REMOTE_BIN' '$V28_PROFILE' '$LIVE_LUA' '$LAUNCHER'" <<'REMOTE_INSTALL'
set -euo pipefail

V28_DIR="$1"
REMOTE_TMP_BIN="$2"
NEW_SHA="$3"
V28_LUA_SHA="$4"
REMOTE_BIN="$5"
V28_PROFILE="$6"
LIVE_LUA="$7"
LAUNCHER="$8"

mkdir -p "$V28_DIR"

check_sha() {
    local file="$1"
    local expected="$2"
    local label="$3"
    local actual

    if [ ! -s "$file" ]; then
        echo "FAIL step8 missing/empty file: $label" >&2
        echo "FILE: $file" >&2
        exit 101
    fi

    actual="$(sha256sum "$file" | awk '{print $1}')"

    if [ "$actual" != "$expected" ]; then
        echo "FAIL step8 SHA: $label" >&2
        echo "FILE: $file" >&2
        echo "EXPECTED: $expected" >&2
        echo "ACTUAL:   $actual" >&2
        exit 102
    fi

    echo "PASS step8 SHA: $label = $actual"
}

check_has() {
    local token="$1"
    local file="$2"

    if ! grep -Fq -- "$token" "$file"; then
        echo "FAIL step8 marker: [$token]" >&2
        echo "FILE: $file" >&2
        exit 103
    fi

    echo "PASS step8 marker: $token"
}

check_absent() {
    local token="$1"
    local file="$2"

    if grep -Fq -- "$token" "$file"; then
        echo "FAIL step8 forbidden marker: [$token]" >&2
        echo "FILE: $file" >&2
        exit 104
    fi

    echo "PASS step8 absent: $token"
}

check_sha "$REMOTE_TMP_BIN" "$NEW_SHA" \
    "uploaded binary before install"

check_sha /tmp/visgrid-v28.lua "$V28_LUA_SHA" \
    "uploaded Lua before install"

install -m 755 "$REMOTE_TMP_BIN" "$REMOTE_BIN"
install -m 644 /tmp/visgrid-v28.lua "$V28_PROFILE"
install -m 644 /tmp/visgrid-v28.lua "$LIVE_LUA"
install -m 755 /tmp/Morrowind_51.v28.sh "$LAUNCHER"

rm -f \
    "$REMOTE_TMP_BIN" \
    /tmp/visgrid-v28.lua \
    /tmp/Morrowind_51.v28.sh

sync

check_sha "$REMOTE_BIN" "$NEW_SHA" \
    "installed binary"

check_sha "$LIVE_LUA" "$V28_LUA_SHA" \
    "installed Lua"

if ! bash -n "$LAUNCHER"; then
    echo "FAIL step8 launcher syntax: $LAUNCHER" >&2
    exit 105
fi
echo "PASS step8 launcher bash syntax"

check_has \
    'v28_profiles/visgrid-v28-separate-clutter.lua' \
    "$LAUNCHER"

check_has \
    'TSP_VISGRID_LUA_V28_SEPARATE_CLUTTER' \
    "$LIVE_LUA"

check_absent \
    '# >>> TSP_VISGRID_V24_AUTO_CAPTURE BEGIN' \
    "$LAUNCHER"

check_absent \
    'export TSP_OBJECT_DIAG=1' \
    "$LAUNCHER"

echo "Installed binary:"
sha256sum "$REMOTE_BIN"

echo "Installed Lua:"
sha256sum "$LIVE_LUA"
REMOTE_INSTALL

echo
echo "===== 9/9 STATE ====="
cat > "$STATE" <<EOF_STATE
SOURCE_BACKUP='$SOURCE_BACKUP'
DEVICE_BACKUP='$DEVICE_BACKUP'
LAUNCHER='$LAUNCHER'
PRE_DEVICE_SHA='$PRE_SHA'
FIX_DEVICE_SHA='$NEW_SHA'
PRE_LUA_SHA='$PRE_LUA_SHA'
V28_LUA_SHA='$V28_LUA_SHA'
HOST_BIN='$HOST_BIN'
EOF_STATE

trap - ERR

echo
echo "============================================================"
echo "V28 SEPARATE CLUTTER RESIDENCY INSTALLED"
echo "============================================================"
echo "ENGINE AUTHORITY:"
echo "  clutter mask = independent of structural/fog PVS"
echo "  clearInteriorTopologyPvs() cannot wake all clutter"
echo "  cell change/unload explicitly clears clutter state"
echo
echo "CLUTTER ROOM POLICY:"
echo "  small_room         current + 1 within 240"
echo "  room               current + 1 within 330"
echo "  large_open         current + up to 2 within 560"
echo "  corridor           current + up to 2 within 500"
echo "  vertical_connector current + at most 1 within 300"
echo "  <=3-sector connector range may rise only to 360; still one extra"
echo "  <=3-sector real rooms may use up to 2 extras within 440"
echo "  candidates sort by physical 3-D AABB distance BEFORE adjacency"
echo
echo "OBJECT OWNERSHIP (V27 FIX RETAINED):"
echo "  direct XY bleed = 0"
echo "  object Z slack = 110"
echo "  nearest-sector ownership fallback = 260 (ownership only)"
echo "  truly unmapped clutter = fail OPEN"
echo
echo "STRUCTURE:"
echo "  ESM Static walls/floors/stairs = normal OpenMW rendering"
echo "  doors/actors = unchanged in this build"
echo "  Activators = never hard-parked"
echo
echo "EXIT:"
echo "  synchronous launcher capture = absent"
echo "  V27 unload purge retained"
echo
echo "FOCUSED TEST:"
echo "  1. Caldera Governor's Hall staircase: first floor -> third floor blank wall."
echo "  2. On third floor, V28 MUST log clutter=1 and park most remote clutter."
echo "  3. Quick Balmora shop check: clutter should still exist."
echo "  4. Exit once normally."
echo "  5. Then: ./$(basename "$0") collect"
echo
echo "Expected proof line:"
echo "  [TSP_ROOMOBJ_V28] clutter=1 eligible=103 resident=<small> inactive=<large> parked=<large>"
echo
echo "Rollback: ./$(basename "$0") rollback"
echo "============================================================"
