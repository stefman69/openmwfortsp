#!/usr/bin/env bash
set -Eeuo pipefail

ACTION="${1:-install}"
CTR="${OPENMW_CONTAINER:-openmw_builder}"
DEV="${TSP_DEVICE:-root@192.168.1.25}"

SRC="/root/openmw-0.51-tsp-src"
BUILD="/root/openmw-0.51-tsp-build"
PACKAGE="/root/openmw-0.51-tsp-package"
SCENE_CPP="$SRC/apps/openmw/mwworld/scene.cpp"
SCENE_HPP="$SRC/apps/openmw/mwworld/scene.hpp"
VIS_CPP="$SRC/apps/openmw/mwrender/interiorvisibility.cpp"
VIS_HPP="$SRC/apps/openmw/mwrender/interiorvisibility.hpp"
CAMERA_CPP="$SRC/apps/openmw/mwlua/camerabindings.cpp"
ANIM_CPP="$SRC/apps/openmw/mwrender/animation.cpp"
BUILT="$BUILD/openmw"
PACKAGED="$PACKAGE/bin/openmw-0.51"

ROOT="/mnt/SDCARD/data/ports/openmw51"
REMOTE_BIN="$ROOT/bin/openmw-0.51"
LUA_DIR="$ROOT/mods/TSPInteriorVisGrid/scripts/TSPInteriorVisGrid"
LIVE_LUA="$LUA_DIR/visgrid.lua"
V29_PROFILE="$LUA_DIR/v29_profiles/visgrid-v29-door-prewake-hard.lua"
V30_DIR="$LUA_DIR/v30_profiles"
V30_PROFILE="$V30_DIR/visgrid-v30-floor-actor-roomwake.lua"
REMOTE_TMP_BIN="/tmp/openmw-0.51.v30-r5-lightkeep"

V30_R4_EXPECT_SHA="9203cc3dbdd4c0352c2e2db8c09a3ae10241972b5a1bb93c87b3e9f28ff0904d"

DL="$HOME/Downloads"
STAMP="$(date +%Y%m%d-%H%M%S)"
LOG="$DL/openmw51-roomwake-v30-r5-lightkeep-$STAMP.log"
BUILD_LOG="$DL/openmw51-roomwake-v30-r5-lightkeep-build-$STAMP.log"
STATE="$DL/openmw51-roomwake-v30-r5-lightkeep.state"
HOST_BIN="$DL/openmw-0.51-v30-r5-lightkeep"
TMP="$(mktemp -d "$DL/.roomwake-v30-r5.XXXXXX")"

SOURCE_BACKUP=""
V27_SOURCE_BASE=""
V27_AUX_BASE=""
DEVICE_BACKUP=""
LAUNCHER=""
SOURCE_MUTATED=0
DEVICE_DEPLOY_STARTED=0

cleanup() {
    rm -rf "$TMP" 2>/dev/null || true
}

on_exit() {
    local rc=$?
    trap - EXIT
    set +e

    if [ "$rc" -ne 0 ]; then
        echo
        echo "===== V30 FAILURE RECOVERY ====="

        if [ "$DEVICE_DEPLOY_STARTED" = 1 ]; then
            echo "INFO: restoring device backup after failed deployment..."
            if ! restore_device; then
                echo "WARNING: device rollback failed; inspect the preserved backup/log." >&2
            fi
        fi

        if [ "$SOURCE_MUTATED" = 1 ]; then
            echo "INFO: restoring clean six-file V27 source baseline after failure..."
            if ! restore_source; then
                echo "WARNING: source rollback failed; inspect Docker source before rerunning." >&2
            fi
        fi
    fi

    cleanup
    exit "$rc"
}
trap on_exit EXIT

fail() {
    local rc="${1:-1}"
    shift || true
    echo "ERROR: $*" >&2
    exit "$rc"
}

require_cmd() {
    local c="$1"
    if ! command -v "$c" >/dev/null 2>&1; then
        fail 10 "required command missing: $c"
    fi
    echo "PASS command: $c"
}

ensure_docker() {
    require_cmd docker
    if ! docker inspect "$CTR" >/dev/null 2>&1; then
        fail 11 "Docker container not found: $CTR"
    fi
    local running
    running="$(docker inspect -f '{{.State.Running}}' "$CTR" 2>/dev/null || true)"
    if [ "$running" != "true" ]; then
        if ! docker start "$CTR" >/dev/null; then
            fail 12 "failed to start Docker container: $CTR"
        fi
    fi
    echo "PASS Docker: $CTR"
}

ensure_ssh() {
    require_cmd ssh
    require_cmd scp
    require_cmd python3
    require_cmd sha256sum
    require_cmd file
    if ! ssh -o BatchMode=yes -o ConnectTimeout=8 "$DEV" true; then
        fail 13 "cannot reach $DEV with non-interactive SSH"
    fi
    echo "PASS SSH: $DEV"
}

game_closed() {
    if ssh "$DEV" "pgrep -af 'openmw-0\\.51|/openmw([[:space:]]|$)' 2>/dev/null" \
        | grep -v pgrep >/dev/null 2>&1; then
        return 1
    fi
    return 0
}

locate_launcher() {
    ssh "$DEV" 'bash -s' <<'REMOTE_LAUNCHER'
for p in \
  /mnt/SDCARD/Roms/PORTS/Morrowind_51.sh \
  /mnt/SDCARD/Emus/PORTS/../../Roms/PORTS/Morrowind_51.sh \
  /mnt/SDCARD/roms/ports/Morrowind_51.sh
do
    if [ -f "$p" ]; then
        readlink -f "$p" 2>/dev/null || printf '%s\n' "$p"
        exit 0
    fi
done
echo "FAIL launcher: Morrowind_51.sh not found" >&2
exit 1
REMOTE_LAUNCHER
}

find_v27_source_baseline() {
    docker exec -i "$CTR" bash -s -- "$SRC" <<'REMOTE_FIND_SOURCE'
set -u
SRC="$1"
BASE="$SRC/.tsp-051-source-backups"

if [ ! -d "$BASE" ]; then
    echo "FAIL source baseline directory missing: $BASE" >&2
    exit 31
fi

valid=""
while IFS= read -r d; do
    [ -n "$d" ] || continue
    ok=1
    for f in scene.cpp interiorvisibility.cpp interiorvisibility.hpp camerabindings.cpp; do
        if [ ! -s "$d/$f" ]; then
            ok=0
            break
        fi
    done
    [ "$ok" -eq 1 ] || continue

    if ! grep -Fq 'TSP_ROOM_OBJECT_ADAPTIVE_051_V27' "$d/scene.cpp"; then continue; fi
    if ! grep -Fq '[TSP_ROOMOBJ_V27]' "$d/scene.cpp"; then continue; fi
    if ! grep -Fq 'fallbackOwnership = 260.f' "$d/interiorvisibility.cpp"; then continue; fi
    if grep -Fq 'TSP_ROOM_OBJECT_SEPARATE_CLUTTER_051_V28' "$d/scene.cpp"; then continue; fi
    if grep -Fq 'setInteriorClutterResidency' "$d/camerabindings.cpp"; then continue; fi

    valid="$d"
    break
done < <(find "$BASE" -maxdepth 1 -type d -name 'visgrid-v28-separate-clutter-*' -print | sort -r)

if [ -z "$valid" ]; then
    echo "FAIL: no exact pre-V28 V27 source backup passed validation." >&2
    echo "Candidates:" >&2
    find "$BASE" -maxdepth 1 -type d -name 'visgrid-v28-separate-clutter-*' -print | sort -r | head -20 >&2
    exit 32
fi

printf '%s\n' "$valid"
REMOTE_FIND_SOURCE
}

find_v27_aux_baseline() {
    docker exec -i "$CTR" bash -s -- "$SRC" <<'REMOTE_FIND_AUX'
set -u
SRC="$1"
BASE="$SRC/.tsp-051-source-backups"

if [ ! -d "$BASE" ]; then
    echo "FAIL source baseline directory missing: $BASE" >&2
    exit 33
fi

valid=""
while IFS= read -r d; do
    [ -n "$d" ] || continue
    if [ ! -s "$d/scene.hpp" ] || [ ! -s "$d/animation.cpp" ]; then
        continue
    fi

    # scene.hpp must be the V25/V27 lifecycle shape, but completely pre-V30.
    if ! grep -Fq 'TSP_ROOM_OBJECT_LIFECYCLE_051_V25' "$d/scene.hpp"; then continue; fi
    if grep -Fq 'TSP_ROOM_ACTOR_HIBERNATE_051_V30' "$d/scene.hpp"; then continue; fi
    if grep -Fq 'TSP_ROOM_OBJECT_FLOOR_AUTHORITY_051_V30' "$d/scene.hpp"; then continue; fi
    if grep -Fq 'TSP_ROOM_OBJECT_SEPARATE_CLUTTER_051_V28' "$d/scene.hpp"; then continue; fi

    # animation.cpp must have the V27 static-structure bypass and no bad STAT cast.
    if ! grep -Fq '!tspDiagActor && !tspDiagDoor && !tspIsStatic' "$d/animation.cpp"; then continue; fi
    if grep -Fq 'mPtr.get<ESM::Static>()' "$d/animation.cpp"; then continue; fi

    valid="$d"
    break
done < <(find "$BASE" -maxdepth 1 -type d -print | sort -r)

if [ -z "$valid" ]; then
    echo "FAIL: no clean pre-V30 scene.hpp/animation.cpp baseline passed validation." >&2
    echo "Need scene.hpp marker TSP_ROOM_OBJECT_LIFECYCLE_051_V25, no V30 marker," >&2
    echo "and V27 animation static bypass." >&2
    exit 34
fi

printf '%s\n' "$valid"
REMOTE_FIND_AUX
}

restore_source() {
    if [ -z "$V27_SOURCE_BASE" ] || [ -z "$V27_AUX_BASE" ]; then
        echo "FAIL source rollback: clean V27 baseline paths are not resolved" >&2
        return 61
    fi

    docker exec -i "$CTR" bash -s -- \
        "$V27_SOURCE_BASE" "$V27_AUX_BASE" \
        "$SCENE_CPP" "$SCENE_HPP" "$VIS_CPP" "$VIS_HPP" "$CAMERA_CPP" "$ANIM_CPP" <<'REMOTE_RESTORE_SOURCE'
set -u
MAIN="$1"; AUX="$2"; SCENE="$3"; HPP="$4"; VIS="$5"; VH="$6"; CAM="$7"; ANIM="$8"

restore_one() {
    local src="$1" dst="$2" label="$3"
    if [ ! -s "$src" ]; then
        echo "FAIL source rollback baseline missing/empty: $label ($src)" >&2
        exit 61
    fi
    # Deliberately DO NOT preserve source timestamps. A restore must force Ninja
    # to see the source as newer than any object left by a failed experiment.
    cp -f "$src" "$dst"
    touch "$dst"
    echo "PASS rollback restored clean V27: $label"
}

restore_one "$MAIN/scene.cpp" "$SCENE" scene.cpp
restore_one "$AUX/scene.hpp" "$HPP" scene.hpp
restore_one "$MAIN/interiorvisibility.cpp" "$VIS" interiorvisibility.cpp
restore_one "$MAIN/interiorvisibility.hpp" "$VH" interiorvisibility.hpp
restore_one "$MAIN/camerabindings.cpp" "$CAM" camerabindings.cpp
restore_one "$AUX/animation.cpp" "$ANIM" animation.cpp

for f in "$SCENE" "$HPP" "$VIS" "$VH" "$CAM" "$ANIM"; do
    if grep -Eq 'TSP_ROOM_ACTOR_HIBERNATE_051_V30|TSP_ROOM_OBJECT_FLOOR_AUTHORITY_051_V30|TSP_ROOM_OBJECT_SEPARATE_CLUTTER_051_V28' "$f"; then
        echo "FAIL rollback contamination survived in: $f" >&2
        grep -nE 'TSP_ROOM_ACTOR_HIBERNATE_051_V30|TSP_ROOM_OBJECT_FLOOR_AUTHORITY_051_V30|TSP_ROOM_OBJECT_SEPARATE_CLUTTER_051_V28' "$f" | head -20 >&2 || true
        exit 62
    fi
done

if grep -Eq 'setInteriorClutterResidency|clearInteriorClutterResidency' "$CAM"; then
    echo "FAIL rollback stale V28 clutter API survived in camerabindings.cpp" >&2
    exit 63
fi

echo "PASS source rollback restored clean six-file V27 baseline"
REMOTE_RESTORE_SOURCE
}

restore_device() {
    if [ -z "$DEVICE_BACKUP" ] || [ -z "$LAUNCHER" ]; then
        return 0
    fi
    ssh "$DEV" bash -s -- "$DEVICE_BACKUP" "$REMOTE_BIN" "$LIVE_LUA" "$LAUNCHER" "$V30_PROFILE" <<'REMOTE_RESTORE_DEVICE'
set -u
B="$1"; BIN="$2"; LIVE="$3"; LAUNCHER="$4"; V30="$5"
need() {
    if [ ! -s "$1" ]; then
        echo "FAIL device rollback backup missing/empty: $1" >&2
        exit 62
    fi
}
need "$B/openmw-0.51.before"
need "$B/visgrid.lua.before"
need "$B/launcher.before"
install -m 755 "$B/openmw-0.51.before" "$BIN"
install -m 644 "$B/visgrid.lua.before" "$LIVE"
install -m 755 "$B/launcher.before" "$LAUNCHER"
if [ -f "$B/v30-profile.existed" ]; then
    need "$B/v30-profile.before"
    mkdir -p "$(dirname "$V30")"
    install -m 644 "$B/v30-profile.before" "$V30"
else
    rm -f "$V30"
fi
sync
echo "PASS device rollback restored: $B"
REMOTE_RESTORE_DEVICE
}

on_error() {
    local rc="${1:-1}"
    local line="${2:-unknown}"
    local cmd="${3:-unknown}"
    trap - ERR
    set +e
    echo
    echo "============================================================"
    echo "V30 STOPPED SAFELY"
    echo "============================================================"
    echo "rc=$rc"
    echo "FAILED LINE: $line"
    echo "FAILED COMMAND: $cmd"
    # EXIT trap owns rollback for both ordinary command failures and explicit
    # fail()/exit paths. Keep ERR trap diagnostic-only to avoid double restore.
    echo "Controller log: $LOG"
    if [ -s "$BUILD_LOG" ]; then
        echo "Build log:      $BUILD_LOG"
    fi
    exit "$rc"
}
trap 'on_error "$?" "$LINENO" "$BASH_COMMAND"' ERR

collect_latest() {
    ensure_ssh
    local out="$DL/openmw51-roomwake-v30-validation-$STAMP.txt"
    ssh "$DEV" bash -s -- "$ROOT" <<'REMOTE_COLLECT' > "$out"
set +e
ROOT="$1"
echo "============================================================"
echo "OPENMW 0.51 ROOMWAKE V30 R5 LIGHT KEEPALIVE VALIDATION"
echo "============================================================"
date
printf 'Binary:   '; sha256sum "$ROOT/bin/openmw-0.51" 2>/dev/null
printf 'Live Lua: '; sha256sum "$ROOT/mods/TSPInteriorVisGrid/scripts/TSPInteriorVisGrid/visgrid.lua" 2>/dev/null

echo
echo "===== V30 FLOOR / PORTAL AUTHORITY ====="
for f in "$ROOT/openmw_051_log.txt" "$ROOT/config-0.51/openmw.log" "$ROOT/openmw.log"; do
    [ -f "$f" ] || continue
    tail -n 50000 "$f" | grep -E '\[TSP_VISGRID_V30(_R[0-9]+)?\]|\[TSP_VISGRID_V15\] (topology sector|sector switch)' | tail -350 || true
done

echo
echo "===== V30 HARD OBJECT LIFECYCLE ====="
for f in "$ROOT/openmw_051_log.txt" "$ROOT/config-0.51/openmw.log" "$ROOT/openmw.log"; do
    [ -f "$f" ] || continue
    tail -n 50000 "$f" | grep -E '\[TSP_ROOMOBJ_V30\]' | tail -350 || true
done

echo
echo "===== V30 ACTOR HIBERNATION ====="
for f in "$ROOT/openmw_051_log.txt" "$ROOT/config-0.51/openmw.log" "$ROOT/openmw.log"; do
    [ -f "$f" ] || continue
    tail -n 50000 "$f" | grep -E '\[TSP_ACTOR_V30\]' | tail -350 || true
done

echo
echo "===== ERRORS ====="
for f in "$ROOT/openmw_051_log.txt" "$ROOT/config-0.51/openmw.log" "$ROOT/openmw.log"; do
    [ -f "$f" ] || continue
    tail -n 50000 "$f" | grep -E 'Bad LiveCellRef cast|failed to render|TSP_VISGRID_V30.*ERROR|Lua.*ERROR|Lua.*error|terminate called|Segmentation fault' | tail -180 || true
done

echo
echo "===== PERF TAIL ====="
[ ! -f "$ROOT/openmw51_perf_latest.txt" ] || tail -320 "$ROOT/openmw51_perf_latest.txt"
REMOTE_COLLECT
    echo "Saved: $out"
    echo
    grep -E '\[TSP_VISGRID_V30(_R[0-9]+)?\]|\[TSP_ROOMOBJ_V30\]|\[TSP_ACTOR_V30\]' "$out" | tail -120 || true
}

rollback_all() {
    if [ ! -s "$STATE" ]; then
        fail 20 "rollback state missing: $STATE"
    fi
    # shellcheck disable=SC1090
    . "$STATE"
    ensure_docker
    ensure_ssh
    if ! game_closed; then
        fail 21 "OpenMW is running; exit the game before rollback"
    fi
    restore_device
    restore_source
    echo "ROLLBACK COMPLETE"
    echo "Device: $DEVICE_BACKUP"
    echo "Source: $SOURCE_BACKUP"
}

case "$ACTION" in
    collect) collect_latest; exit 0 ;;
    rollback) rollback_all; exit 0 ;;
    install) ;;
    *) fail 2 "Usage: $0 [install|collect|rollback]" ;;
esac

exec > >(tee "$LOG") 2>&1

echo "============================================================"
echo "OPENMW 0.51 — ROOMWAKE V30 R5 LIGHT KEEPALIVE"
echo "CONTROLLER REVISION: V30-R5 LIGHT KEEPALIVE 3X / R4 PRESERVED"
echo "============================================================"
echo "Object core: proven V25/V26 real renderer+physics removal, V27 structure safety."
echo "Floor rule: normal rooms from other floors cannot remain active."
echo "Connector: staircase remains; only the room on the inferred player floor may prewake."
echo "Door prewake: slightly earlier than V29 to reduce visible pop."
echo "Actor stage 1: off-room AI/Mechanics sleeps + render node hidden; physics stays."
echo "Actor exceptions: active room, combat/pursuit, or current LOS+awareness of player."
echo "============================================================"

ensure_docker
ensure_ssh
if ! game_closed; then
    fail 22 "OpenMW is running; exit normally before installing V30"
fi
LAUNCHER="$(locate_launcher)"
if [ -z "$LAUNCHER" ]; then
    fail 23 "launcher resolver returned empty path"
fi
echo "PASS launcher: $LAUNCHER"

echo
echo "===== 1/8 VERIFY LIVE V30 R4 BASELINE ====="
ssh "$DEV" bash -s -- "$REMOTE_BIN" "$V30_R4_EXPECT_SHA" "$LIVE_LUA" "$V30_PROFILE" "$LAUNCHER" <<'REMOTE_PREFLIGHT'
set -u
BIN="$1"; EXPECT="$2"; LIVE="$3"; PROFILE="$4"; LAUNCHER="$5"
check_file() {
    if [ ! -s "$1" ]; then
        echo "FAIL preflight file missing/empty: $1" >&2
        exit 41
    fi
    echo "PASS file: $1"
}
check_has() {
    local token="$1" file="$2"
    if ! grep -Fq -- "$token" "$file"; then
        echo "FAIL preflight marker: [$token]" >&2
        echo "FILE: $file" >&2
        exit 42
    fi
    echo "PASS marker: $token"
}
check_absent() {
    local token="$1" file="$2"
    if grep -Fq -- "$token" "$file"; then
        echo "FAIL unexpected marker: [$token]" >&2
        echo "FILE: $file" >&2
        exit 43
    fi
    echo "PASS absent: $token"
}
check_file "$BIN"
actual="$(sha256sum "$BIN" | awk '{print $1}')"
if [ "$actual" != "$EXPECT" ]; then
    echo "FAIL current binary is not exact proven V30 actor/floor build" >&2
    echo "EXPECTED: $EXPECT" >&2
    echo "ACTUAL:   $actual" >&2
    exit 44
fi
echo "PASS exact V30 R4 binary SHA: $actual"
check_file "$LIVE"
check_file "$PROFILE"
check_file "$LAUNCHER"
check_has 'TSP_VISGRID_V30_R4' "$LIVE"
check_has 'TSP_VISGRID_V30_R4' "$PROFILE"
check_has 'v30_profiles/visgrid-v30-floor-actor-roomwake.lua' "$LAUNCHER"
check_has 'camera.setInteriorTopologyPvs' "$LIVE"
check_absent 'setInteriorClutterResidency' "$LIVE"
check_absent '# >>> TSP_VISGRID_V24_AUTO_CAPTURE BEGIN' "$LAUNCHER"
REMOTE_PREFLIGHT

PRE_BIN_SHA="$(ssh "$DEV" "sha256sum '$REMOTE_BIN'" | awk '{print $1}')"
PRE_LUA_SHA="$(ssh "$DEV" "sha256sum '$LIVE_LUA'" | awk '{print $1}')"
PRE_PROFILE_SHA="$(ssh "$DEV" "sha256sum '$V30_PROFILE'" | awk '{print $1}')"
echo "Current binary SHA:  $PRE_BIN_SHA"
echo "Current live Lua:    $PRE_LUA_SHA"
echo "Current R4 profile:  $PRE_PROFILE_SHA"

echo
echo "===== 2/8 FIND CLEAN V27 SOURCE BASELINE + BACKUP CURRENT SOURCE ====="
V27_SOURCE_BASE="$(find_v27_source_baseline)"
if [ -z "$V27_SOURCE_BASE" ]; then
    fail 30 "V27 source baseline resolver returned empty path"
fi
echo "PASS V27 source baseline: $V27_SOURCE_BASE"

V27_AUX_BASE="$(find_v27_aux_baseline)"
if [ -z "$V27_AUX_BASE" ]; then
    fail 35 "V27 auxiliary scene.hpp/animation baseline resolver returned empty path"
fi
echo "PASS clean pre-V30 aux baseline: $V27_AUX_BASE"

SOURCE_BACKUP="$SRC/.tsp-051-source-backups/roomwake-v30-preinstall-$STAMP"
docker exec -i "$CTR" bash -s -- \
    "$SOURCE_BACKUP" "$SCENE_CPP" "$SCENE_HPP" "$VIS_CPP" "$VIS_HPP" "$CAMERA_CPP" "$ANIM_CPP" <<'REMOTE_BACKUP_SOURCE'
set -u
B="$1"; SCENE="$2"; HPP="$3"; VIS="$4"; VH="$5"; CAM="$6"; ANIM="$7"
mkdir -p "$B"
copy_one() {
    local src="$1" name="$2"
    if [ ! -s "$src" ]; then
        echo "FAIL source backup input missing/empty: $src" >&2
        exit 51
    fi
    cp -pf "$src" "$B/$name"
    echo "PASS source backup: $src -> $B/$name"
}
copy_one "$SCENE" scene.cpp
copy_one "$HPP" scene.hpp
copy_one "$VIS" interiorvisibility.cpp
copy_one "$VH" interiorvisibility.hpp
copy_one "$CAM" camerabindings.cpp
copy_one "$ANIM" animation.cpp
sha256sum "$B"/*
REMOTE_BACKUP_SOURCE
SOURCE_MUTATED=1

echo
echo "===== 3/8 RESTORE CLEAN V27 + REAPPLY V30 + LIGHT KEEPALIVE ====="

# Restore all six files as one baseline. Do not trust the currently checked-out
# scene.hpp/animation.cpp after any failed V30 attempt.
if ! restore_source; then
    fail 52 "failed to restore complete clean V27 source baseline"
fi
SOURCE_MUTATED=1

# Explicit baseline postconditions before the patcher is allowed to run.
docker exec -i "$CTR" bash -s -- \
    "$SCENE_CPP" "$SCENE_HPP" "$VIS_CPP" "$VIS_HPP" "$CAMERA_CPP" "$ANIM_CPP" <<'REMOTE_VERIFY_CLEAN_BASE'
set -u
SCENE="$1"; HPP="$2"; VIS="$3"; VH="$4"; CAM="$5"; ANIM="$6"

check_has() {
    local token="$1" file="$2" label="$3"
    if ! grep -Fq -- "$token" "$file"; then
        echo "FAIL clean V27 baseline missing $label: [$token] in $file" >&2
        exit 64
    fi
    echo "PASS clean V27 marker: $label"
}
check_absent() {
    local token="$1" file="$2" label="$3"
    if grep -Fq -- "$token" "$file"; then
        echo "FAIL clean V27 baseline still contains $label: [$token] in $file" >&2
        exit 65
    fi
    echo "PASS clean V27 absent: $label"
}

check_has 'TSP_ROOM_OBJECT_ADAPTIVE_051_V27' "$SCENE" 'scene V27 lifecycle'
check_has '[TSP_ROOMOBJ_V27]' "$SCENE" 'scene V27 log marker'
check_has 'TSP_ROOM_OBJECT_LIFECYCLE_051_V25' "$HPP" 'scene.hpp lifecycle state'
check_has 'fallbackOwnership = 260.f' "$VIS" 'V27 ownership baseline'
check_has '!tspDiagActor && !tspDiagDoor && !tspIsStatic' "$ANIM" 'V27 static bypass'

for f in "$SCENE" "$HPP" "$VIS" "$VH" "$CAM" "$ANIM"; do
    check_absent 'TSP_ROOM_ACTOR_HIBERNATE_051_V30' "$f" 'V30 actor marker'
    check_absent 'TSP_ROOM_OBJECT_FLOOR_AUTHORITY_051_V30' "$f" 'V30 floor marker'
    check_absent 'TSP_ROOM_OBJECT_SEPARATE_CLUTTER_051_V28' "$f" 'V28 clutter marker'
done
check_absent 'setInteriorClutterResidency' "$CAM" 'V28 clutter setter API'
check_absent 'clearInteriorClutterResidency' "$CAM" 'V28 clutter clearer API'
check_absent 'mPtr.get<ESM::Static>()' "$ANIM" 'unsafe STAT cast'

echo "PASS exact six-file V27 source baseline proved clean before V30 patch"
REMOTE_VERIFY_CLEAN_BASE

# Invalidate translation units that were stale or are directly modified, and
# touch every restored file so Ninja cannot reuse objects from a failed V28/V30 run.
docker exec -i "$CTR" bash -s -- "$BUILD" \
    "$SCENE_CPP" "$SCENE_HPP" "$VIS_CPP" "$VIS_HPP" "$CAMERA_CPP" "$ANIM_CPP" <<'REMOTE_INVALIDATE_BUILD'
set -u
BUILD_DIR="$1"; shift
for src in "$@"; do
    touch "$src"
done

for rel in \
  'apps/openmw/CMakeFiles/openmw-lib.dir/mwworld/scene.cpp.o' \
  'apps/openmw/CMakeFiles/openmw-lib.dir/mwworld/scene.cpp.o.d' \
  'apps/openmw/CMakeFiles/openmw-lib.dir/mwrender/interiorvisibility.cpp.o' \
  'apps/openmw/CMakeFiles/openmw-lib.dir/mwrender/interiorvisibility.cpp.o.d' \
  'apps/openmw/CMakeFiles/openmw-lib.dir/mwlua/camerabindings.cpp.o' \
  'apps/openmw/CMakeFiles/openmw-lib.dir/mwlua/camerabindings.cpp.o.d' \
  'apps/openmw/CMakeFiles/openmw-lib.dir/mwrender/animation.cpp.o' \
  'apps/openmw/CMakeFiles/openmw-lib.dir/mwrender/animation.cpp.o.d'
do
    rm -f "$BUILD_DIR/$rel"
done

echo "PASS invalidated stale V28/V30 translation-unit objects"
REMOTE_INVALIDATE_BUILD

cat > "$TMP/patch_v30_cpp.py" <<'PY_CPP'
#!/usr/bin/env python3
import sys

scene_cpp_path, scene_hpp_path, vis_cpp_path = sys.argv[1:4]


def read(path):
    with open(path, 'r', encoding='utf-8', newline='') as f:
        return f.read()


def write(path, text):
    with open(path, 'w', encoding='utf-8', newline='\n') as f:
        f.write(text)


sc = read(scene_cpp_path)
sh = read(scene_hpp_path)
vc = read(vis_cpp_path)
MARK_ACTOR = 'TSP_ROOM_ACTOR_HIBERNATE_051_V30'
MARK_OBJECT = 'TSP_ROOM_OBJECT_FLOOR_AUTHORITY_051_V30'

for token in (
    'TSP_ROOM_OBJECT_ADAPTIVE_051_V27',
    '[TSP_ROOMOBJ_V27]',
    'tspUpdateRoomObjectLifecycle(duration);',
    'MWRender::isInteriorTopologyObjectResident(',
    'unload-purge parked=',
):
    if token not in sc:
        raise RuntimeError('scene.cpp missing required V27 token: ' + token)
for token in (
    'TSP_ROOM_OBJECT_LIFECYCLE_051_V25',
    'mTspRoomSuppressedRefs',
    'void tspUpdateRoomObjectLifecycle(float duration);',
):
    if token not in sh:
        raise RuntimeError('scene.hpp missing required V25/V27 token: ' + token)
for token in (
    'TSP_ROOM_OBJECT_ADAPTIVE_051_V27',
    'fallbackOwnership = 260.f',
    'nearestSector >= 0',
):
    if token not in vc:
        raise RuntimeError('interiorvisibility.cpp missing required V27 token: ' + token)
if MARK_ACTOR in sc or MARK_ACTOR in sh or MARK_OBJECT in vc:
    raise RuntimeError('V30 C++ marker already present; refusing ambiguous re-application')

# Scene actor hibernation needs full CreatureStats/AiSequence declarations.
include_anchor = '#include "../mwbase/world.hpp"\n'
include_line = '#include "../mwmechanics/creaturestats.hpp"\n'
if include_line not in sc:
    if sc.count(include_anchor) != 1:
        raise RuntimeError('scene.cpp world.hpp include anchor count=%d' % sc.count(include_anchor))
    sc = sc.replace(include_anchor, include_anchor + '\n' + include_line, 1)

# Add actor lifecycle state next to the already-proven V25/V27 object lifecycle state.
hpp_anchor = '''        void tspUpdateRoomObjectLifecycle(float duration);\n\n        std::vector<osg::ref_ptr<SceneUtil::WorkItem>> mWorkItems;\n'''
hpp_insert = '''        void tspUpdateRoomObjectLifecycle(float duration);\n\n        // TSP_ROOM_ACTOR_HIBERNATE_051_V30\n        // Same topology room authority as hard clutter parking. Sleeping actors keep\n        // their CellStore ref and Bullet collision, but leave Mechanics/AI and are\n        // hidden until their room wakes or combat/awareness requires them.\n        std::set<ESM::RefNum> mTspRoomSleepingActors;\n        CellStore* mTspRoomActorCell = nullptr;\n        float mTspRoomActorAccumulator = 0.f;\n        float mTspRoomActorSenseAccumulator = 0.25f;\n        float mTspRoomActorLogAccumulator = 0.f;\n        std::uint64_t mTspRoomActorSleepTotal = 0;\n        std::uint64_t mTspRoomActorWakeTotal = 0;\n\n        void tspWakeSleepingRoomActors(CellStore* cell, const char* reason);\n        void tspUpdateRoomActorLifecycle(float duration);\n\n        std::vector<osg::ref_ptr<SceneUtil::WorkItem>> mWorkItems;\n'''
if sh.count(hpp_anchor) != 1:
    raise RuntimeError('scene.hpp actor-state anchor count=%d, expected 1' % sh.count(hpp_anchor))
sh = sh.replace(hpp_anchor, hpp_insert, 1)

# Insert actor lifecycle implementation immediately before Scene::update.
update_anchor = '''    void Scene::update(float duration)\n    {\n'''
impl = r'''    // TSP_ROOM_ACTOR_HIBERNATE_051_V30
    void Scene::tspWakeSleepingRoomActors(CellStore* cell, const char* reason)
    {
        if (cell == nullptr || mTspRoomSleepingActors.empty())
            return;

        MWBase::MechanicsManager* const mechanics = MWBase::Environment::get().getMechanicsManager();
        const std::size_t requested = mTspRoomSleepingActors.size();
        std::size_t woke = 0;

        cell->forEach([&](const Ptr& ptr) {
            if (!ptr.getClass().isActor())
                return true;

            const ESM::RefNum refnum = ptr.getCellRef().getRefNum();
            const auto sleeping = mTspRoomSleepingActors.find(refnum);
            if (sleeping == mTspRoomSleepingActors.end())
                return true;

            mTspRoomSleepingActors.erase(sleeping);
            if (!ptr.mRef->isDeleted() && ptr.getRefData().isEnabled()
                && ptr.mRef->mRef.getCount() > 0 && ptr.getRefData().getBaseNode())
            {
                mechanics->add(ptr);
                ++mTspRoomActorWakeTotal;
                ++woke;
            }
            return true;
        });

        const std::size_t missing = mTspRoomSleepingActors.size();
        mTspRoomSleepingActors.clear();
        Log(Debug::Info)
            << "[TSP_ACTOR_V30] wake-all reason=" << reason
            << " requested=" << requested
            << " woke=" << woke
            << " missing=" << missing;
    }

    void Scene::tspUpdateRoomActorLifecycle(float duration)
    {
        if (mCurrentCell != mTspRoomActorCell)
        {
            if (mTspRoomActorCell != nullptr && !mTspRoomSleepingActors.empty())
                tspWakeSleepingRoomActors(mTspRoomActorCell, "cell-change");

            mTspRoomActorCell = mCurrentCell;
            mTspRoomSleepingActors.clear();
            mTspRoomActorAccumulator = 0.f;
            mTspRoomActorSenseAccumulator = 0.25f; // first pass evaluates awareness immediately
            mTspRoomActorLogAccumulator = 0.f;
        }

        if (mCurrentCell == nullptr || mCurrentCell->isExterior())
            return;

        mTspRoomActorAccumulator += std::max(0.f, duration);
        mTspRoomActorSenseAccumulator += std::max(0.f, duration);
        mTspRoomActorLogAccumulator += std::max(0.f, duration);
        if (mTspRoomActorAccumulator < 0.05f)
            return;
        mTspRoomActorAccumulator = 0.f;

        const bool pvsEnabled = MWRender::isInteriorTopologyPvsEnabled();
        if (!pvsEnabled)
        {
            if (!mTspRoomSleepingActors.empty())
                tspWakeSleepingRoomActors(mCurrentCell, "authority-off");
            return;
        }

        const bool senseDue = mTspRoomActorSenseAccumulator >= 0.25f;
        if (senseDue)
            mTspRoomActorSenseAccumulator = 0.f;

        MWBase::World* const world = MWBase::Environment::get().getWorld();
        MWBase::MechanicsManager* const mechanics = MWBase::Environment::get().getMechanicsManager();
        const Ptr player = world->getPlayerPtr();
        const osg::Vec3f playerPos = player.getRefData().getPosition().asVec3();

        std::vector<Ptr> toWake;
        std::vector<Ptr> toSleep;
        int eligible = 0;
        int roomAwake = 0;
        int offRoom = 0;
        int protectedCombat = 0;
        int protectedSense = 0;
        int senseHold = 0;
        int sleepingNow = 0;

        mCurrentCell->forEach([&](const Ptr& ptr) {
            if (!ptr.getClass().isActor() || ptr == player)
                return true;
            if (ptr.mRef->isDeleted() || !ptr.getRefData().isEnabled()
                || ptr.mRef->mRef.getCount() <= 0 || !ptr.getRefData().getBaseNode())
                return true;

            const ESM::RefNum refnum = ptr.getCellRef().getRefNum();
            if (!refnum.hasContentFile())
                return true; // dynamically-created actors fail open for safety

            MWMechanics::CreatureStats& stats = ptr.getClass().getCreatureStats(ptr);
            if (stats.isDead())
                return true; // never disturb corpse/death animation state in this first actor pass

            ++eligible;
            const bool isSleeping = mTspRoomSleepingActors.find(refnum) != mTspRoomSleepingActors.end();
            const osg::Vec3f origin = ptr.getRefData().getPosition().asVec3();
            const bool roomResident = MWRender::isInteriorTopologyObjectResident(origin, 0.f, false);

            if (roomResident)
            {
                ++roomAwake;
                if (isSleeping)
                    toWake.push_back(ptr);
                return true;
            }

            ++offRoom;
            const auto& ai = stats.getAiSequence();
            if (ai.isInCombat() || ai.isInPursuit())
            {
                ++protectedCombat;
                if (isSleeping)
                    toWake.push_back(ptr);
                return true;
            }

            if (senseDue)
            {
                // Only actors close enough to plausibly matter pay the LOS+awareness cost.
                // Physics remains present while sleeping, so this test still has real walls.
                constexpr float senseMax = 1800.f;
                const float dist2 = (playerPos - origin).length2();
                const bool sensesPlayer = dist2 <= senseMax * senseMax
                    && world->getLOS(ptr, player)
                    && mechanics->awarenessCheck(player, ptr, false);
                if (sensesPlayer)
                {
                    ++protectedSense;
                    if (isSleeping)
                        toWake.push_back(ptr);
                    return true;
                }
            }
            else if (!isSleeping)
            {
                // Do not put an awake actor to sleep between awareness samples.
                ++senseHold;
                return true;
            }

            if (isSleeping)
                ++sleepingNow;
            else
                toSleep.push_back(ptr);
            return true;
        });

        // Room/combat/awareness wakes are always processed before new sleeps.
        constexpr std::size_t wakeBudget = 128;
        constexpr std::size_t sleepBudget = 128;
        for (std::size_t i = 0; i < toWake.size() && i < wakeBudget; ++i)
        {
            const Ptr& ptr = toWake[i];
            const ESM::RefNum refnum = ptr.getCellRef().getRefNum();
            const auto sleeping = mTspRoomSleepingActors.find(refnum);
            if (sleeping == mTspRoomSleepingActors.end())
                continue;
            mTspRoomSleepingActors.erase(sleeping);
            mechanics->add(ptr);
            ++mTspRoomActorWakeTotal;
        }

        for (std::size_t i = 0; i < toSleep.size() && i < sleepBudget; ++i)
        {
            const Ptr& ptr = toSleep[i];
            const ESM::RefNum refnum = ptr.getCellRef().getRefNum();
            if (mTspRoomSleepingActors.find(refnum) != mTspRoomSleepingActors.end())
                continue;

            mechanics->remove(ptr, true);
            if (osg::Node* const node = ptr.getRefData().getBaseNode())
                node->setNodeMask(0u);
            mTspRoomSleepingActors.insert(refnum);
            ++mTspRoomActorSleepTotal;
        }

        if (mTspRoomActorLogAccumulator >= 1.f)
        {
            mTspRoomActorLogAccumulator = 0.f;
            Log(Debug::Info)
                << "[TSP_ACTOR_V30] authority=1"
                << " eligible=" << eligible
                << " roomAwake=" << roomAwake
                << " offRoom=" << offRoom
                << " sleeping=" << mTspRoomSleepingActors.size()
                << " sleepQ=" << toSleep.size()
                << " wakeQ=" << toWake.size()
                << " combat=" << protectedCombat
                << " sense=" << protectedSense
                << " senseHold=" << senseHold
                << " sleepTotal=" << mTspRoomActorSleepTotal
                << " wakeTotal=" << mTspRoomActorWakeTotal;
        }
    }

'''
if sc.count(update_anchor) != 1:
    raise RuntimeError('Scene::update anchor count=%d, expected 1' % sc.count(update_anchor))
sc = sc.replace(update_anchor, impl + update_anchor, 1)

# Run actor authority immediately after the existing hard-object lifecycle.
call_anchor = '''        // TSP_ROOM_OBJECT_LIFECYCLE_051_V25\n        tspUpdateRoomObjectLifecycle(duration);\n'''
call_replacement = call_anchor + '''\n        // TSP_ROOM_ACTOR_HIBERNATE_051_V30\n        tspUpdateRoomActorLifecycle(duration);\n'''
if sc.count(call_anchor) != 1:
    raise RuntimeError('Scene::update lifecycle call anchor count=%d, expected 1' % sc.count(call_anchor))
sc = sc.replace(call_anchor, call_replacement, 1)

# Wake sleeping actors before the ordinary mechanics drop/cell teardown owns cleanup.
unload_anchor = '''        // TSP_ROOM_OBJECT_ADAPTIVE_051_V27\n        // Parked V25/V26 refs borrowed mPagedRefs only as a scene-side sentinel.\n'''
unload_insert = '''        // TSP_ROOM_ACTOR_HIBERNATE_051_V30\n        // Re-register sleeping actors before normal cell teardown so MechanicsManager::drop\n        // remains the sole owner of unload-time temporary-effect cleanup.\n        if (cell == mTspRoomActorCell && !mTspRoomSleepingActors.empty())\n        {\n            tspWakeSleepingRoomActors(cell, "unload");\n            mTspRoomActorCell = nullptr;\n            mTspRoomActorAccumulator = 0.f;\n            mTspRoomActorSenseAccumulator = 0.25f;\n            mTspRoomActorLogAccumulator = 0.f;\n        }\n\n'''
if sc.count(unload_anchor) != 1:
    raise RuntimeError('Scene::unloadCell V27 anchor count=%d, expected 1' % sc.count(unload_anchor))
sc = sc.replace(unload_anchor, unload_insert + unload_anchor, 1)

# Give V30 its own hard-object telemetry marker without changing the proven suppress/wake implementation.
if sc.count('[TSP_ROOMOBJ_V27]') < 1:
    raise RuntimeError('scene.cpp V27 telemetry marker missing')
sc = sc.replace('[TSP_ROOMOBJ_V27]', '[TSP_ROOMOBJ_V30]')

# V27's 260-unit fallback can leave genuinely room-owned clutter permanently resident.
# V30 assigns every eligible clutter origin to the nearest valid topology sector when
# it misses the thin direct navmesh boxes.  The active room/floor mask then decides life.
old_ownership = '''        if (!structural && nearestSector >= 0)\n        {\n            constexpr float fallbackOwnership = 260.f;\n            if (nearestD2 <= fallbackOwnership * fallbackOwnership)\n                return (visibleMask & (std::uint64_t{ 1 } << nearestSector)) != 0;\n        }\n\n        // Truly unmapped clutter fails OPEN in V27. V26's fail-closed diagnostic\n        // was useful proof, but it could erase every object in a coarse topology.\n        return true;'''
new_ownership = '''        // TSP_ROOM_OBJECT_FLOOR_AUTHORITY_051_V30\n        // If this interior has valid topology boxes, every eligible clutter object\n        // belongs to its nearest room/connector sector even when its origin is high\n        // above the thin navmesh AABB. This removes V27's >260-unit permanent-resident\n        // escape hatch while avoiding V26's blanket fail-closed behavior in Balmora.\n        if (!structural && nearestSector >= 0)\n            return (visibleMask & (std::uint64_t{ 1 } << nearestSector)) != 0;\n\n        // No usable topology sector at all: fail open for safety.\n        return true;'''
if vc.count(old_ownership) != 1:
    raise RuntimeError('interiorvisibility.cpp V27 fallback ownership block count=%d, expected 1' % vc.count(old_ownership))
vc = vc.replace(old_ownership, new_ownership, 1)

# -------------------------------------------------------------------------
# V30 R5: light-only 3x keepalive.
# Ordinary clutter and actors stay radius=0. ESM Light refs alone pass 1560.
# Positive non-structural radius expands XY only; Z stays floor-tight.
# -------------------------------------------------------------------------
import re

call_pat = re.compile(
    r'(?m)^(?P<i>[ \\t]*)const bool shouldLive = MWRender::isInteriorTopologyObjectResident\\(\\n'
    r'(?P=i)[ \\t]+origin, 0\\.f, false\\);$'
)
call_matches = list(call_pat.finditer(sc))
if len(call_matches) != 1:
    candidates = [line for line in sc.splitlines()
                  if 'shouldLive' in line or 'isInteriorTopologyObjectResident' in line]
    raise RuntimeError(
        'V30 R5 object residency call matches=%d expected 1; candidates=%r'
        % (len(call_matches), candidates[-20:]))
cm = call_matches[0]
i = cm.group('i')
call_repl = (
    i + '// TSP_ROOM_LIGHT_KEEPALIVE_051_V30_R5\\n'
    + i + '// Lights get 3x R4 minimum inter-room distance; other objects remain radius 0.\\n'
    + i + 'const bool tspRoomExtendedLight = ptr.getType() == ESM::REC_LIGH;\\n'
    + i + 'const float tspRoomObjectRadius = tspRoomExtendedLight ? 1560.f : 0.f;\\n'
    + i + 'const bool shouldLive = MWRender::isInteriorTopologyObjectResident(\\n'
    + i + '    origin, tspRoomObjectRadius, false);'
)
sc = sc[:cm.start()] + call_repl + sc[cm.end():]

old_overlap = '''                constexpr float zSlack = 110.f;
                overlaps = origin.x() >= minX && origin.x() <= maxX
                    && origin.y() >= minY && origin.y() <= maxY
                    && origin.z() >= minZ - zSlack && origin.z() <= maxZ + zSlack;'''
new_overlap = '''                // TSP_ROOM_LIGHT_KEEPALIVE_051_V30_R5
                // radius=0 preserves exact V27/V30 clutter ownership. Positive radius
                // is used only by ESM Light refs and expands XY around active sectors.
                // Z remains tight to avoid waking lights on another floor.
                const float xyPad = radius > 0.f ? radius : 0.f;
                const float zSlack = radius > 0.f ? 100.f : 110.f;
                overlaps = origin.x() >= minX - xyPad && origin.x() <= maxX + xyPad
                    && origin.y() >= minY - xyPad && origin.y() <= maxY + xyPad
                    && origin.z() >= minZ - zSlack && origin.z() <= maxZ + zSlack;'''
if vc.count(old_overlap) != 1:
    nearby = [line for line in vc.splitlines()
              if 'zSlack' in line or 'origin.x() >= minX' in line]
    raise RuntimeError(
        'V30 R5 nonstructural overlap block count=%d expected 1; candidates=%r'
        % (vc.count(old_overlap), nearby[-20:]))
vc = vc.replace(old_overlap, new_overlap, 1)

if sc.count('[TSP_ROOMOBJ_V30]') < 1:
    raise RuntimeError('V30 R5 telemetry marker missing before light-tag patch')
sc = sc.replace('[TSP_ROOMOBJ_V30]', '[TSP_ROOMOBJ_V30] lightKeepXY=1560', 1)

for token in (
    MARK_ACTOR,
    '[TSP_ACTOR_V30]',
    '[TSP_ROOMOBJ_V30]',
    'mechanics->remove(ptr, true);',
    'node->setNodeMask(0u);',
    'mechanics->awarenessCheck(player, ptr, false)',
    'ai.isInCombat() || ai.isInPursuit()',
    'tspWakeSleepingRoomActors(cell, "unload")',
):
    if token not in sc:
        raise RuntimeError('scene.cpp V30 postcondition missing: ' + token)
for token in (
    MARK_ACTOR,
    'mTspRoomSleepingActors',
    'tspUpdateRoomActorLifecycle',
    'mTspRoomActorSenseAccumulator',
):
    if token not in sh:
        raise RuntimeError('scene.hpp V30 postcondition missing: ' + token)
for token in (
    'TSP_ROOM_LIGHT_KEEPALIVE_051_V30_R5',
    'tspRoomExtendedLight = ptr.getType() == ESM::REC_LIGH',
    'tspRoomObjectRadius = tspRoomExtendedLight ? 1560.f : 0.f',
    '[TSP_ROOMOBJ_V30] lightKeepXY=1560',
):
    if token not in sc:
        raise RuntimeError('scene.cpp V30 R5 light postcondition missing: ' + token)
for token in (
    'TSP_ROOM_LIGHT_KEEPALIVE_051_V30_R5',
    'const float xyPad = radius > 0.f ? radius : 0.f;',
    'const float zSlack = radius > 0.f ? 100.f : 110.f;',
):
    if token not in vc:
        raise RuntimeError('interiorvisibility.cpp V30 R5 light postcondition missing: ' + token)

for token in (
    MARK_OBJECT,
    'nearestSector >= 0',
    'No usable topology sector at all: fail open for safety.',
):
    if token not in vc:
        raise RuntimeError('interiorvisibility.cpp V30 postcondition missing: ' + token)
if 'fallbackOwnership = 260.f' in vc:
    raise RuntimeError('V27 260-unit permanent-resident fallback survived V30')

write(scene_cpp_path, sc)
write(scene_hpp_path, sh)
write(vis_cpp_path, vc)
print('PASS: V30 hard-object ownership assigns missed clutter to nearest topology sector.')
print('PASS: V30 actor room hibernation added: Mechanics/AI removed, render node hidden, physics retained.')
print('PASS: combat/pursuit actors stay awake; LOS+awareness is sampled every 0.25 s.')
print('PASS: sleeping actors are re-registered before normal cell unload.')
print('PASS: V30 R5 lights use 1560 XY keepalive; ordinary clutter/actors remain radius 0.')
PY_CPP

if ! python3 -m py_compile "$TMP/patch_v30_cpp.py"; then
    fail 60 "embedded V30 C++ patcher does not compile"
fi
if ! docker cp "$TMP/patch_v30_cpp.py" "$CTR:/tmp/patch_v30_cpp.py" >/dev/null; then
    fail 61 "failed to copy V30 C++ patcher into Docker"
fi
if ! docker exec "$CTR" python3 /tmp/patch_v30_cpp.py "$SCENE_CPP" "$SCENE_HPP" "$VIS_CPP"; then
    fail 62 "V30 C++ source patch failed"
fi
if ! docker exec "$CTR" rm -f /tmp/patch_v30_cpp.py; then
    fail 63 "failed to remove temporary Docker patcher"
fi

docker exec -i "$CTR" bash -s -- "$SCENE_CPP" "$SCENE_HPP" "$VIS_CPP" "$CAMERA_CPP" "$ANIM_CPP" <<'REMOTE_CPP_VERIFY'
set -u
SCENE="$1"; HPP="$2"; VIS="$3"; CAM="$4"; ANIM="$5"
check_has() {
    local token="$1" file="$2"
    if ! grep -Fq -- "$token" "$file"; then
        echo "FAIL V30 source marker: [$token]" >&2
        echo "FILE: $file" >&2
        exit 64
    fi
    echo "PASS V30 source marker: $token"
}
check_absent() {
    local token="$1" file="$2"
    if grep -Fq -- "$token" "$file"; then
        echo "FAIL V30 forbidden source marker: [$token]" >&2
        echo "FILE: $file" >&2
        exit 65
    fi
    echo "PASS V30 source absent: $token"
}
check_has 'TSP_ROOM_ACTOR_HIBERNATE_051_V30' "$SCENE"
check_has '[TSP_ACTOR_V30]' "$SCENE"
check_has '[TSP_ROOMOBJ_V30]' "$SCENE"
check_has 'TSP_ROOM_LIGHT_KEEPALIVE_051_V30_R5' "$SCENE"
check_has 'tspRoomObjectRadius = tspRoomExtendedLight ? 1560.f : 0.f' "$SCENE"
check_has 'mechanics->remove(ptr, true);' "$SCENE"
check_has 'mechanics->awarenessCheck(player, ptr, false)' "$SCENE"
check_has 'mTspRoomSleepingActors' "$HPP"
check_has 'TSP_ROOM_OBJECT_FLOOR_AUTHORITY_051_V30' "$VIS"
check_has 'TSP_ROOM_LIGHT_KEEPALIVE_051_V30_R5' "$VIS"
check_has 'const float zSlack = radius > 0.f ? 100.f : 110.f;' "$VIS"
check_absent 'fallbackOwnership = 260.f' "$VIS"
check_absent 'setInteriorClutterResidency' "$CAM"
check_absent 'mPtr.get<ESM::Static>()' "$ANIM"
REMOTE_CPP_VERIFY

echo
echo "===== 4/8 BUILD OPENMW V30 R5 ====="
: > "$BUILD_LOG"
if ! docker exec "$CTR" cmake --build "$BUILD" --target openmw --parallel 1 2>&1 | tee "$BUILD_LOG"; then
    echo
    echo "===== BUILD FAILURE TAIL ====="
    tail -260 "$BUILD_LOG" || true
    fail 70 "OpenMW V30 build failed; full build log preserved at $BUILD_LOG"
fi

# Do not merely assume invalidation worked. The build log must prove the
# cross-file V27/V30 translation units were rebuilt during THIS run.
for unit in camerabindings.cpp.o scene.cpp.o interiorvisibility.cpp.o; do
    if ! grep -Fq "$unit" "$BUILD_LOG"; then
        fail 71 "V30 build completed without recompiling $unit; refusing stale-object risk"
    fi
    echo "PASS build log proves recompile: $unit"
done

# Link/API consistency: no old V28 clutter API may survive anywhere in the
# rebuilt camera object/source path.
if grep -Eq 'undefined reference to .*InteriorClutterResidency' "$BUILD_LOG"; then
    fail 72 "V28 clutter-residency symbol survived into V30 link"
fi

echo
echo "===== 5/8 PACKAGE / COPY-OUT / VERIFY R5 BINARY ====="
docker exec -i "$CTR" bash -s -- "$BUILT" "$PACKAGED" <<'REMOTE_PACKAGE'
set -u
BUILT="$1"; PACKAGED="$2"
if [ ! -s "$BUILT" ]; then
    echo "FAIL rebuilt binary missing/empty: $BUILT" >&2
    exit 71
fi
mkdir -p "$(dirname "$PACKAGED")"
install -m 755 "$BUILT" "$PACKAGED"
desc="$(file "$PACKAGED")"
echo "$desc"
if ! printf '%s\n' "$desc" | grep -Eq 'ARM aarch64|ARM64|AArch64'; then
    echo "FAIL packaged architecture is not ARM64/AArch64" >&2
    exit 72
fi
sha256sum "$PACKAGED"
if command -v strings >/dev/null 2>&1; then
    if ! strings "$PACKAGED" | grep -Fq '[TSP_ACTOR_V30]'; then
        echo "FAIL compiled actor V30 telemetry string missing" >&2
        exit 73
    fi
    if ! strings "$PACKAGED" | grep -Fq '[TSP_ROOMOBJ_V30]'; then
        echo "FAIL compiled object V30 telemetry string missing" >&2
        exit 74
    fi
    if ! strings "$PACKAGED" | grep -Fq 'lightKeepXY=1560'; then
        echo "FAIL compiled V30 R5 light keepalive marker missing" >&2
        exit 75
    fi
    echo "PASS compiled V30 telemetry + R5 light keepalive marker"
fi
REMOTE_PACKAGE

if ! docker cp "$CTR:$PACKAGED" "$HOST_BIN"; then
    fail 75 "failed Docker -> Ubuntu binary copy-out"
fi
if [ ! -s "$HOST_BIN" ]; then
    fail 76 "host V30 binary missing/empty after copy-out: $HOST_BIN"
fi
HOST_DESC="$(file "$HOST_BIN")"
echo "$HOST_DESC"
if ! printf '%s\n' "$HOST_DESC" | grep -Eq 'ARM aarch64|ARM64|AArch64'; then
    fail 77 "host V30 binary architecture is not ARM64/AArch64"
fi
NEW_SHA="$(sha256sum "$HOST_BIN" | awk '{print $1}')"
echo "V30 binary SHA: $NEW_SHA"


echo
echo "===== 6/8 VERIFY R4 LUA STILL UNCHANGED ====="
NOW_LUA_SHA="$(ssh "$DEV" "sha256sum '$LIVE_LUA'" | awk '{print $1}')"
NOW_PROFILE_SHA="$(ssh "$DEV" "sha256sum '$V30_PROFILE'" | awk '{print $1}')"
NOW_BIN_SHA="$(ssh "$DEV" "sha256sum '$REMOTE_BIN'" | awk '{print $1}')"
if [ "$NOW_BIN_SHA" != "$PRE_BIN_SHA" ]; then
    fail 80 "device binary changed during build expected=$PRE_BIN_SHA actual=$NOW_BIN_SHA"
fi
if [ "$NOW_LUA_SHA" != "$PRE_LUA_SHA" ]; then
    fail 81 "live R4 Lua changed during build expected=$PRE_LUA_SHA actual=$NOW_LUA_SHA"
fi
if [ "$NOW_PROFILE_SHA" != "$PRE_PROFILE_SHA" ]; then
    fail 82 "R4 profile changed during build expected=$PRE_PROFILE_SHA actual=$NOW_PROFILE_SHA"
fi
if ! ssh "$DEV" bash -s -- "$LIVE_LUA" "$V30_PROFILE" <<'REMOTE_R4_VERIFY'
set -u
LIVE="$1"; PROFILE="$2"
for f in "$LIVE" "$PROFILE"; do
    if ! grep -Fq 'TSP_VISGRID_V30_R4' "$f"; then
        echo "FAIL R4 marker missing: $f" >&2
        exit 1
    fi
    if ! grep -Fq 'camera.setInteriorTopologyPvs' "$f"; then
        echo "FAIL topology bridge missing: $f" >&2
        exit 2
    fi
done
echo "PASS exact R4 Lua/profile markers preserved"
REMOTE_R4_VERIFY
then
    fail 83 "R4 Lua marker verification failed before binary install"
fi

echo
echo "===== 7/8 DEVICE BACKUP + INSTALL R5 BINARY ONLY ====="
DEVICE_BACKUP="$ROOT/backups/roomwake-v30-r5-lightkeep-$STAMP"
if ! ssh "$DEV" bash -s -- "$DEVICE_BACKUP" "$REMOTE_BIN" "$LIVE_LUA" "$LAUNCHER" "$V30_PROFILE" <<'REMOTE_DEVICE_BACKUP'
set -u
B="$1"; BIN="$2"; LIVE="$3"; LAUNCHER="$4"; PROFILE="$5"
mkdir -p "$B"
for f in "$BIN" "$LIVE" "$LAUNCHER" "$PROFILE"; do
    if [ ! -s "$f" ]; then
        echo "FAIL device backup input missing/empty: $f" >&2
        exit 1
    fi
done
install -m 755 "$BIN" "$B/openmw-0.51.before"
install -m 644 "$LIVE" "$B/visgrid.lua.before"
install -m 755 "$LAUNCHER" "$B/launcher.before"
touch "$B/v30-profile.existed"
install -m 644 "$PROFILE" "$B/v30-profile.before"
sha256sum "$B/openmw-0.51.before" "$B/visgrid.lua.before" "$B/v30-profile.before" "$B/launcher.before"
echo "PASS complete device backup: $B"
REMOTE_DEVICE_BACKUP
then
    fail 84 "failed to back up current V30 R4 device state"
fi

DEVICE_DEPLOY_STARTED=1
if ! scp -q "$HOST_BIN" "$DEV:$REMOTE_TMP_BIN"; then
    fail 85 "failed to upload R5 binary to device"
fi

if ! ssh "$DEV" bash -s -- \
    "$REMOTE_TMP_BIN" "$NEW_SHA" "$REMOTE_BIN" "$PRE_BIN_SHA" \
    "$LIVE_LUA" "$PRE_LUA_SHA" "$V30_PROFILE" "$PRE_PROFILE_SHA" <<'REMOTE_INSTALL_R5'
set -u
TMP="$1"; EXPECT_NEW="$2"; BIN="$3"; EXPECT_OLD="$4"
LIVE="$5"; EXPECT_LUA="$6"; PROFILE="$7"; EXPECT_PROFILE="$8"
check_sha() {
    local file="$1" expected="$2" label="$3"
    if [ ! -s "$file" ]; then
        echo "FAIL $label missing/empty: $file" >&2
        exit 1
    fi
    local got
    got="$(sha256sum "$file" | awk '{print $1}')"
    if [ "$got" != "$expected" ]; then
        echo "FAIL $label SHA expected=$expected actual=$got file=$file" >&2
        exit 2
    fi
    echo "PASS $label SHA: $got"
}
check_sha "$BIN" "$EXPECT_OLD" "preinstall V30 R4 binary"
check_sha "$LIVE" "$EXPECT_LUA" "live R4 Lua before install"
check_sha "$PROFILE" "$EXPECT_PROFILE" "R4 profile before install"
check_sha "$TMP" "$EXPECT_NEW" "uploaded R5 binary"
if ! grep -aFq 'lightKeepXY=1560' "$TMP"; then
    echo "FAIL uploaded R5 binary marker missing: lightKeepXY=1560" >&2
    exit 3
fi
install -m 755 "$TMP" "$BIN"
rm -f "$TMP"
sync
check_sha "$BIN" "$EXPECT_NEW" "installed R5 binary"
check_sha "$LIVE" "$EXPECT_LUA" "live R4 Lua after install"
check_sha "$PROFILE" "$EXPECT_PROFILE" "R4 profile after install"
if ! grep -Fq 'TSP_VISGRID_V30_R4' "$LIVE"; then
    echo "FAIL R4 live Lua marker disappeared" >&2
    exit 4
fi
if ! grep -aFq 'lightKeepXY=1560' "$BIN"; then
    echo "FAIL installed R5 binary marker missing" >&2
    exit 5
fi
echo "PASS installed R5 binary; R4 Lua/profile byte-identical"
REMOTE_INSTALL_R5
then
    fail 86 "R5 device install/verification failed"
fi
DEVICE_DEPLOY_STARTED=0

cat > "$STATE" <<EOF_STATE
V27_SOURCE_BASE='$V27_SOURCE_BASE'
V27_AUX_BASE='$V27_AUX_BASE'
SOURCE_BACKUP='$SOURCE_BACKUP'
DEVICE_BACKUP='$DEVICE_BACKUP'
LAUNCHER='$LAUNCHER'
PRE_BIN_SHA='$PRE_BIN_SHA'
PRE_LUA_SHA='$PRE_LUA_SHA'
NEW_SHA='$NEW_SHA'
HOST_BIN='$HOST_BIN'
EOF_STATE

echo
echo "===== 8/8 SUCCESS ====="
echo "============================================================"
echo "V30 R5 LIGHT KEEPALIVE INSTALLED"
echo "============================================================"
echo "Binary old: $PRE_BIN_SHA"
echo "Binary new: $NEW_SHA"
echo "R4 Lua unchanged: $PRE_LUA_SHA"
echo "Light XY keepalive: 1560 (3 x R4 minimum 520)"
echo "Light Z ownership slack: 100; ordinary clutter remains 110"
echo "Ordinary clutter radius: 0"
echo "Actors and R4 proximity policy: unchanged"
echo
echo "ONE run: test the upstairs open room and downstairs doorway/candles."
echo "Then: ./$(basename "$0") collect"
echo "Rollback: ./$(basename "$0") rollback"
echo "Log: $LOG"
echo "Build log: $BUILD_LOG"
echo "Host binary: $HOST_BIN"
echo "============================================================"
