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
REMOTE_TMP_BIN="/tmp/openmw-0.51.v30-floor-actor-roomwake"

V27_EXPECT_SHA="08d8cac100d12b1ab5c04d8efe6e2da1b00c1f29407de8cad5417dd5b75ce699"

DL="$HOME/Downloads"
STAMP="$(date +%Y%m%d-%H%M%S)"
LOG="$DL/openmw51-roomwake-v30-$STAMP.log"
BUILD_LOG="$DL/openmw51-roomwake-v30-build-$STAMP.log"
STATE="$DL/openmw51-roomwake-v30.state"
HOST_BIN="$DL/openmw-0.51-v30-floor-actor-roomwake"
TMP="$(mktemp -d "$DL/.roomwake-v30.XXXXXX")"

SOURCE_BACKUP=""
V27_SOURCE_BASE=""
DEVICE_BACKUP=""
LAUNCHER=""
SOURCE_MUTATED=0
DEVICE_DEPLOY_STARTED=0

cleanup() {
    rm -rf "$TMP" 2>/dev/null || true
}
trap cleanup EXIT

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

restore_source() {
    if [ -z "$SOURCE_BACKUP" ]; then
        return 0
    fi
    docker exec -i "$CTR" bash -s -- \
        "$SOURCE_BACKUP" "$SCENE_CPP" "$SCENE_HPP" "$VIS_CPP" "$VIS_HPP" "$CAMERA_CPP" "$ANIM_CPP" <<'REMOTE_RESTORE_SOURCE'
set -u
B="$1"; SCENE="$2"; HPP="$3"; VIS="$4"; VH="$5"; CAM="$6"; ANIM="$7"
restore_one() {
    local src="$1" dst="$2"
    if [ ! -s "$src" ]; then
        echo "FAIL source rollback backup missing/empty: $src" >&2
        exit 61
    fi
    cp -pf "$src" "$dst"
}
restore_one "$B/scene.cpp" "$SCENE"
restore_one "$B/scene.hpp" "$HPP"
restore_one "$B/interiorvisibility.cpp" "$VIS"
restore_one "$B/interiorvisibility.hpp" "$VH"
restore_one "$B/camerabindings.cpp" "$CAM"
restore_one "$B/animation.cpp" "$ANIM"
echo "PASS source rollback restored: $B"
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
    if [ "$DEVICE_DEPLOY_STARTED" = 1 ]; then
        restore_device || true
    fi
    if [ "$SOURCE_MUTATED" = 1 ]; then
        restore_source || true
    fi
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
echo "OPENMW 0.51 ROOMWAKE V30 FLOOR + ACTOR VALIDATION"
echo "============================================================"
date
printf 'Binary:   '; sha256sum "$ROOT/bin/openmw-0.51" 2>/dev/null
printf 'Live Lua: '; sha256sum "$ROOT/mods/TSPInteriorVisGrid/scripts/TSPInteriorVisGrid/visgrid.lua" 2>/dev/null

echo
echo "===== V30 FLOOR / PORTAL AUTHORITY ====="
for f in "$ROOT/openmw_051_log.txt" "$ROOT/config-0.51/openmw.log" "$ROOT/openmw.log"; do
    [ -f "$f" ] || continue
    tail -n 50000 "$f" | grep -E '\[TSP_VISGRID_V30\]|\[TSP_VISGRID_V15\] (topology sector|sector switch)' | tail -350 || true
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
    grep -E '\[TSP_VISGRID_V30\]|\[TSP_ROOMOBJ_V30\]|\[TSP_ACTOR_V30\]' "$out" | tail -100 || true
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
echo "OPENMW 0.51 — ROOMWAKE V30 FLOOR AUTHORITY + ACTOR HIBERNATION"
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
echo "===== 1/10 VERIFY WORKING V29 DEVICE BASELINE ====="
ssh "$DEV" bash -s -- "$REMOTE_BIN" "$V27_EXPECT_SHA" "$LIVE_LUA" "$V29_PROFILE" "$LAUNCHER" <<'REMOTE_PREFLIGHT'
set -u
BIN="$1"; EXPECT="$2"; LIVE="$3"; V29="$4"; LAUNCHER="$5"
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
    echo "FAIL current binary is not the proven V27/V29 hard-delete core" >&2
    echo "EXPECTED: $EXPECT" >&2
    echo "ACTUAL:   $actual" >&2
    exit 44
fi
echo "PASS proven binary SHA: $actual"
check_file "$LIVE"
check_file "$V29"
check_file "$LAUNCHER"
check_has 'TSP_VISGRID_LUA_V29_DOOR_PREWAKE_HARD' "$LIVE"
check_has 'camera.setInteriorTopologyPvs' "$LIVE"
check_has 'v29_profiles/visgrid-v29-door-prewake-hard.lua' "$LAUNCHER"
check_absent 'setInteriorClutterResidency' "$LIVE"
check_absent '# >>> TSP_VISGRID_V24_AUTO_CAPTURE BEGIN' "$LAUNCHER"
REMOTE_PREFLIGHT

PRE_BIN_SHA="$(ssh "$DEV" "sha256sum '$REMOTE_BIN'" | awk '{print $1}')"
PRE_LUA_SHA="$(ssh "$DEV" "sha256sum '$LIVE_LUA'" | awk '{print $1}')"
echo "Current binary SHA: $PRE_BIN_SHA"
echo "Current live Lua:   $PRE_LUA_SHA"

echo
echo "===== 2/10 FIND EXACT PRE-V28 V27 SOURCE + BACKUP CURRENT SOURCE ====="
V27_SOURCE_BASE="$(find_v27_source_baseline)"
if [ -z "$V27_SOURCE_BASE" ]; then
    fail 30 "V27 source baseline resolver returned empty path"
fi
echo "PASS V27 source baseline: $V27_SOURCE_BASE"

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
echo "===== 3/10 RESTORE V27 SOURCE BASELINE, THEN APPLY V30 C++ ====="
docker exec -i "$CTR" bash -s -- \
    "$V27_SOURCE_BASE" "$SCENE_CPP" "$SCENE_HPP" "$VIS_CPP" "$VIS_HPP" "$CAMERA_CPP" "$ANIM_CPP" <<'REMOTE_RESTORE_V27'
set -u
B="$1"; SCENE="$2"; HPP="$3"; VIS="$4"; VH="$5"; CAM="$6"; ANIM="$7"
copy_required() {
    local src="$1" dst="$2" label="$3"
    if [ ! -s "$src" ]; then
        echo "FAIL V27 baseline file missing/empty: $label ($src)" >&2
        exit 52
    fi
    cp -pf "$src" "$dst"
    echo "PASS restored V27: $label"
}
copy_required "$B/scene.cpp" "$SCENE" scene.cpp
copy_required "$B/interiorvisibility.cpp" "$VIS" interiorvisibility.cpp
copy_required "$B/interiorvisibility.hpp" "$VH" interiorvisibility.hpp
copy_required "$B/camerabindings.cpp" "$CAM" camerabindings.cpp

# V28 never modified scene.hpp or animation.cpp. They must still carry the V25/V27 state.
if ! grep -Fq 'TSP_ROOM_OBJECT_LIFECYCLE_051_V25' "$HPP"; then
    echo "FAIL scene.hpp lost V25/V27 lifecycle state: $HPP" >&2
    exit 53
fi
if grep -Fq 'TSP_ROOM_OBJECT_SEPARATE_CLUTTER_051_V28' "$HPP"; then
    echo "FAIL unexpected V28 scene.hpp marker: $HPP" >&2
    exit 54
fi
if ! grep -Fq '!tspDiagActor && !tspDiagDoor && !tspIsStatic' "$ANIM"; then
    echo "FAIL animation.cpp is not the V27 static-structure bypass baseline: $ANIM" >&2
    exit 55
fi
if grep -Fq 'mPtr.get<ESM::Static>()' "$ANIM"; then
    echo "FAIL unsafe Static cast exists in animation.cpp" >&2
    exit 56
fi
if ! grep -Fq 'TSP_ROOM_OBJECT_ADAPTIVE_051_V27' "$SCENE"; then
    echo "FAIL restored scene.cpp lacks V27 marker" >&2
    exit 57
fi
if ! grep -Fq 'fallbackOwnership = 260.f' "$VIS"; then
    echo "FAIL restored interiorvisibility.cpp lacks V27 ownership marker" >&2
    exit 58
fi
if grep -Fq 'setInteriorClutterResidency' "$CAM"; then
    echo "FAIL broken V28 clutter API survived restored camera source" >&2
    exit 59
fi
echo "PASS exact V27 source shape restored before V30 patch"
REMOTE_RESTORE_V27

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
check_has 'mechanics->remove(ptr, true);' "$SCENE"
check_has 'mechanics->awarenessCheck(player, ptr, false)' "$SCENE"
check_has 'mTspRoomSleepingActors' "$HPP"
check_has 'TSP_ROOM_OBJECT_FLOOR_AUTHORITY_051_V30' "$VIS"
check_absent 'fallbackOwnership = 260.f' "$VIS"
check_absent 'setInteriorClutterResidency' "$CAM"
check_absent 'mPtr.get<ESM::Static>()' "$ANIM"
REMOTE_CPP_VERIFY

echo
echo "===== 4/10 BUILD OPENMW V30 ====="
: > "$BUILD_LOG"
if ! docker exec "$CTR" cmake --build "$BUILD" --target openmw --parallel 1 2>&1 | tee "$BUILD_LOG"; then
    echo
    echo "===== BUILD FAILURE TAIL ====="
    tail -260 "$BUILD_LOG" || true
    fail 70 "OpenMW V30 build failed; full build log preserved at $BUILD_LOG"
fi

echo
echo "===== 5/10 PACKAGE / COPY-OUT / VERIFY BINARY ====="
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
    echo "PASS compiled V30 telemetry strings"
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
echo "===== 6/10 PULL WORKING V29 PROFILE + GENERATE FLOOR-AWARE V30 ====="
if ! scp -q "$DEV:$LIVE_LUA" "$TMP/visgrid.v29.lua"; then
    fail 80 "failed to pull working live V29 Lua"
fi
if ! scp -q "$DEV:$LAUNCHER" "$TMP/Morrowind_51.v29.sh"; then
    fail 81 "failed to pull current launcher"
fi
if [ "$(sha256sum "$TMP/visgrid.v29.lua" | awk '{print $1}')" != "$PRE_LUA_SHA" ]; then
    fail 82 "pulled V29 Lua SHA differs from preflight live SHA"
fi

cat > "$TMP/patch_v30_profile.py" <<'PY_PROFILE'
#!/usr/bin/env python3
import re
import sys

src_path, lua_out, launcher_in, launcher_out = sys.argv[1:5]


def read(path):
    with open(path, 'r', encoding='utf-8', newline='') as f:
        return f.read()


def write(path, text):
    with open(path, 'w', encoding='utf-8', newline='\n') as f:
        f.write(text)


s = read(src_path)
required = (
    'TSP_VISGRID_LUA_V29_DOOR_PREWAKE_HARD',
    'mapState.v29BaseOnFrame = ',
    'mapState.v29BaseOnFrame(dt)',
    'mapState.updateTopologyPvs = function(force)',
    'camera.setInteriorTopologyPvs',
    '-- No ray learning/prewarm in this diagnostic.',
)
for token in required:
    if token not in s:
        raise RuntimeError('V29 profile missing required token: ' + token)
if 'TSP_VISGRID_LUA_V30_FLOOR_ACTOR_ROOMWAKE' in s:
    raise RuntimeError('V30 marker already present; refusing ambiguous re-application')
if 'setInteriorClutterResidency' in s:
    raise RuntimeError('broken V28 clutter bridge reference exists in V29 source')

base_pat = re.compile(r'(?m)^mapState\.v29BaseOnFrame\s*=\s*(?P<base>mapState\.[A-Za-z_][A-Za-z0-9_]*)\s*$')
base_matches = list(base_pat.finditer(s))
if len(base_matches) != 1:
    candidates = [line for line in s.splitlines() if 'v29BaseOnFrame' in line]
    raise RuntimeError('V29 base frame callback matches=%d, expected 1; candidates=%r'
                       % (len(base_matches), candidates[-20:]))
base_callback = base_matches[0].group('base')
print('PASS: captured V29 original frame callback: ' + base_callback)

start = s.index('-- TSP_VISGRID_LUA_V29_DOOR_PREWAKE_HARD')
end = s.index('-- No ray learning/prewarm in this diagnostic.', start)

block = r'''-- TSP_VISGRID_LUA_V30_FLOOR_ACTOR_ROOMWAKE
-- V26/V29 hard topology-PVS authority, now with explicit FLOOR authority.
-- Current sector always lives. A vertical connector itself may prewake, but a
-- normal room on another floor is never admitted merely because a staircase
-- portal is physically nearby. On a connector, the player's effective floor is
-- inferred from the nearest NON-connector sector AABB.
mapState.v30LastSignature = ''
mapState.v30LastLine = ''

mapState.v30BoxDistance2 = function(x, y, z, b)
    if b == nil then return math.huge end
    local minX = tonumber(b[1] or 0) or 0
    local minY = tonumber(b[2] or 0) or 0
    local minZ = tonumber(b[3] or 0) or 0
    local maxX = tonumber(b[4] or 0) or 0
    local maxY = tonumber(b[5] or 0) or 0
    local maxZ = tonumber(b[6] or 0) or 0
    local dx = x < minX and (minX - x) or (x > maxX and (x - maxX) or 0)
    local dy = y < minY and (minY - y) or (y > maxY and (y - maxY) or 0)
    local dz = z < minZ and (minZ - z) or (z > maxZ and (z - maxZ) or 0)
    return dx*dx + dy*dy + dz*dz
end

mapState.v30InferFloor = function(x, y, z, currentSec)
    if currentSec == nil then return nil end
    local currentKind = tostring(currentSec.kind or 'room')
    local currentFloor = tonumber(currentSec.floor)
    if currentKind ~= 'vertical_connector' and currentFloor ~= nil then
        return currentFloor
    end

    local bestFloor = nil
    local bestD2 = math.huge
    local sectors = mapState.topoCell and mapState.topoCell.sectors or nil
    if sectors ~= nil then
        for id, candidate in pairs(sectors) do
            if tonumber(id) ~= tonumber(mapState.topoSectorId or 0)
                and candidate ~= nil
                and tostring(candidate.kind or 'room') ~= 'vertical_connector'
                and tonumber(candidate.floor) ~= nil then
                local d2 = mapState.v30BoxDistance2(x, y, z, candidate.bbox)
                if d2 < bestD2 then
                    bestD2 = d2
                    bestFloor = tonumber(candidate.floor)
                end
            end
        end
    end
    return bestFloor ~= nil and bestFloor or currentFloor
end

mapState.v30WakeRange = function(currentKind, targetKind, portalKind)
    local range
    if targetKind == 'small_room' then
        range = 240.0
    elseif targetKind == 'large_open' then
        range = 380.0
    elseif targetKind == 'corridor' then
        range = 340.0
    elseif targetKind == 'vertical_connector' then
        range = 280.0
    else
        range = 300.0
    end

    if portalKind == 'door' then range = range + 60.0 end

    -- Staircase/connector is still the critical performance case. Wake the one
    -- room on the player's inferred floor earlier than V29, but never a remote
    -- room from another floor.
    if currentKind == 'vertical_connector' then
        range = math.min(range, 320.0)
    end
    return range
end

mapState.v30MaxExtra = function(kind)
    if kind == 'vertical_connector' then return 1 end
    if kind == 'small_room' then return 1 end
    if kind == 'large_open' then return 3 end
    if kind == 'corridor' then return 2 end
    return 2
end

mapState.updateTopologyPvs = function(force)
    if not mapState.pvsBridge or mapState.topoCell == nil
        or mapState.pvsBoxes == nil then
        if mapState.pvsBridge then pcall(camera.clearInteriorTopologyPvs) end
        mapState.pvsSignature = nil
        mapState.pvsActiveCount = 0
        return
    end

    local current = tonumber(mapState.topoSectorId or 0) or 0
    local sec = current > 0 and mapState.topoCell.sectors[current] or nil
    if current <= 0 or sec == nil then
        pcall(camera.clearInteriorTopologyPvs)
        mapState.pvsSignature = nil
        mapState.pvsActiveCount = 0
        if force or mapState.v30LastLine ~= 'unmapped' then
            mapState.v30LastLine = 'unmapped'
            print(string.format('[TSP_VISGRID_V30] UNMAPPED current=%d total=%d',
                current, tonumber(mapState.pvsSectorCount or 0) or 0))
        end
        return
    end

    local cc = sec.center or {0, 0, 0}
    local x = tonumber(mapState.topoX or cc[1] or 0) or 0
    local y = tonumber(mapState.topoY or cc[2] or 0) or 0
    local z = tonumber(mapState.topoZ or cc[3] or 0) or 0
    local currentKind = tostring(sec.kind or 'room')
    local playerFloor = mapState.v30InferFloor(x, y, z, sec)
    local maxExtra = mapState.v30MaxExtra(currentKind)
    local candidates = {}
    local seen = {}

    local portals = mapState.topoCell.portals
    if sec.portals ~= nil and portals ~= nil then
        for i = 1, #sec.portals do
            local pid = tonumber(sec.portals[i] or 0) or 0
            local p = portals[pid]
            if p ~= nil and p.center ~= nil then
                local a = tonumber(p.a or 0) or 0
                local b = tonumber(p.b or 0) or 0
                local other = 0
                if a == current then other = b
                elseif b == current then other = a end

                local target = other > 0 and mapState.topoCell.sectors[other] or nil
                if target ~= nil and other ~= current and not seen[other] then
                    local targetKind = tostring(target.kind or 'room')
                    local targetFloor = tonumber(target.floor)

                    -- Floor is stronger than portal proximity. Connectors are the
                    -- only cross-floor structure allowed to stay live. Normal rooms
                    -- must match the player's inferred floor exactly.
                    local floorAllowed = targetKind == 'vertical_connector'
                        or (playerFloor ~= nil and targetFloor ~= nil and targetFloor == playerFloor)

                    if floorAllowed then
                        local px = tonumber(p.center[1] or 0) or 0
                        local py = tonumber(p.center[2] or 0) or 0
                        local pz = tonumber(p.center[3] or 0) or 0
                        local dx, dy, dz = px - x, py - y, pz - z
                        local d = math.sqrt(dx*dx + dy*dy + dz*dz)
                        local pkind = tostring(p.kind or 'boundary')
                        local limit = mapState.v30WakeRange(currentKind, targetKind, pkind)
                        if d <= limit then
                            seen[other] = true
                            candidates[#candidates + 1] = {
                                id = other, d = d, limit = limit,
                                portal = pid, pkind = pkind, tkind = targetKind,
                                floor = targetFloor,
                            }
                        end
                    end
                end
            end
        end
    end

    table.sort(candidates, function(a, b)
        if a.d ~= b.d then return a.d < b.d end
        return a.id < b.id
    end)

    local ids = { current }
    local detail = {}
    local n = math.min(maxExtra, #candidates)
    for i = 1, n do
        local c = candidates[i]
        ids[#ids + 1] = c.id
        detail[#detail + 1] = string.format('%d@%.0f/%.0f:f%s',
            c.id, c.d, c.limit, tostring(c.floor or '?'))
    end
    table.sort(ids)

    local signature = 'v30:f' .. tostring(playerFloor or '?') .. ':' .. table.concat(ids, ',')
    if force or signature ~= mapState.pvsSignature then
        local ok, err = pcall(camera.setInteriorTopologyPvs,
            mapState.pvsBoxes, ids, 0.0, 0.0)
        if ok then
            mapState.pvsSignature = signature
            mapState.pvsActiveCount = #ids
            if force or signature ~= mapState.v30LastSignature then
                mapState.v30LastSignature = signature
                local ds = #detail > 0 and table.concat(detail, ',') or '-'
                print(string.format(
                    '[TSP_VISGRID_V30] current=%d/%d kind=%s floor=%s active=%d ids=%s portalWake=%s',
                    current, tonumber(mapState.pvsSectorCount or 0) or 0,
                    currentKind, tostring(playerFloor or '?'), #ids,
                    table.concat(ids, ','), ds))
            end
        else
            print('[TSP_VISGRID_V30] BRIDGE ERROR: ' .. tostring(err))
            pcall(camera.clearInteriorTopologyPvs)
            mapState.pvsSignature = nil
            mapState.pvsActiveCount = 0
        end
    end
end

'''

frame_wrapper = (
    "\nmapState.v30BaseOnFrame = %s\n"
    "%s = function(dt)\n"
    "    mapState.v30BaseOnFrame(dt)\n"
    "    mapState.updateTopologyPvs(false)\n"
    "end\n\n"
) % (base_callback, base_callback)
block = block + frame_wrapper
s = s[:start] + block + s[end:]

# Replace V29 runtime identity with V30. Preserve V26 historical startup marker.
startup_pat = re.compile(r"(?m)^[ \t]*print\(['\"]\[TSP_VISGRID_V29\] DOOR-PREWAKE-HARD[^\n]*\)[ \t]*$")
startup_matches = list(startup_pat.finditer(s))
if len(startup_matches) != 1:
    candidates = [line for line in s.splitlines() if '[TSP_VISGRID_V29]' in line]
    raise RuntimeError('V29 startup marker matches=%d, expected 1; candidates=%r'
                       % (len(startup_matches), candidates[-10:]))
sm = startup_matches[0]
s = (s[:sm.start()]
     + "print('[TSP_VISGRID_V30] FLOOR-AUTHORITY earlier-door-wake=1 actor-room-mask=1')"
     + s[sm.end():])

for token in (
    'TSP_VISGRID_LUA_V30_FLOOR_ACTOR_ROOMWAKE',
    'mapState.v30InferFloor',
    "targetKind == 'vertical_connector'",
    'targetFloor == playerFloor',
    'mapState.pvsBoxes, ids, 0.0, 0.0',
    'mapState.v30BaseOnFrame = ' + base_callback,
    base_callback + ' = function(dt)',
    '[TSP_VISGRID_V30] FLOOR-AUTHORITY',
):
    if token not in s:
        raise RuntimeError('V30 Lua postcondition missing: ' + token)
if 'TSP_VISGRID_LUA_V29_DOOR_PREWAKE_HARD' in s:
    raise RuntimeError('old V29 policy block marker survived V30 replacement')
if 'setInteriorClutterResidency' in s:
    raise RuntimeError('broken V28 clutter bridge leaked into V30')
write(lua_out, s)

l = read(launcher_in)
profile_pat = re.compile(r"\$TSP_VISGRID_DIR/v(?:26|27|28|29|30)_profiles/visgrid-[^'\"\n]+\.lua")
profile_matches = list(profile_pat.finditer(l))
if len(profile_matches) != 1:
    candidates = [line for line in l.splitlines() if 'TSP_VISGRID_SELECTED=' in line or '_profiles/visgrid-' in line]
    raise RuntimeError('launcher selected-profile structure matches=%d, expected 1; candidates=%r'
                       % (len(profile_matches), candidates[-20:]))
pm = profile_matches[0]
new_profile = '$TSP_VISGRID_DIR/v30_profiles/visgrid-v30-floor-actor-roomwake.lua'
l = l[:pm.start()] + new_profile + l[pm.end():]

l, n_profile = re.subn(
    r"(?m)^([ \t]*echo[ \t]+['\"]Visgrid Profile=)[^'\"]*(['\"][ \t]*)$",
    r"\1v30-floor-actor-roomwake\2",
    l,
    count=1,
)
if n_profile != 1:
    raise RuntimeError('launcher Visgrid Profile label matches=%d, expected 1' % n_profile)

l, n_policy = re.subn(
    r"(?m)^[ \t]*echo[ \t]+['\"]Visgrid room policy=[^'\"]*['\"][ \t]*$",
    'echo "Visgrid room policy=V26 hard delete; FLOOR authority + earlier same-floor portal prewake + actor hibernation"',
    l,
    count=1,
)
if n_policy != 1:
    raise RuntimeError('launcher Visgrid room policy matches=%d, expected 1' % n_policy)

for token in (
    'v30_profiles/visgrid-v30-floor-actor-roomwake.lua',
    'Visgrid Profile=v30-floor-actor-roomwake',
):
    if token not in l:
        raise RuntimeError('V30 launcher postcondition missing: ' + token)
if 'export TSP_OBJECT_DIAG=1' in l:
    raise RuntimeError('heavy object diagnostics survived V30 launcher patch')
if '# >>> TSP_VISGRID_V24_AUTO_CAPTURE BEGIN' in l:
    raise RuntimeError('synchronous auto-capture survived V30 launcher patch')
write(launcher_out, l)

print('PASS: V30 floor authority generated directly from working V29 profile.')
print('PASS: normal destination rooms must match inferred player floor; connector is the only cross-floor exception.')
print('PASS: doorway prewake ranges increased while connector current remains capped at 320.')
print('PASS: proven setInteriorTopologyPvs bridge remains the only room authority.')
PY_PROFILE

if ! python3 -m py_compile "$TMP/patch_v30_profile.py"; then
    fail 83 "embedded V30 profile patcher does not compile"
fi
if ! python3 "$TMP/patch_v30_profile.py" \
    "$TMP/visgrid.v29.lua" "$TMP/visgrid.v30.lua" \
    "$TMP/Morrowind_51.v29.sh" "$TMP/Morrowind_51.v30.sh"; then
    fail 84 "V30 Lua/launcher generation failed"
fi
if ! bash -n "$TMP/Morrowind_51.v30.sh"; then
    fail 85 "generated V30 launcher has invalid Bash syntax"
fi
echo "PASS generated V30 launcher Bash syntax"

PARSER=""
for x in luajit texlua lua; do
    if command -v "$x" >/dev/null 2>&1; then
        PARSER="$x"
        break
    fi
done
if [ -n "$PARSER" ]; then
    cat > "$TMP/check-v30.lua" <<'LUA_CHECK'
local f,e=loadfile(arg[1])
if not f then error(e) end
print('LUA_PARSE_PASS ' .. arg[1])
LUA_CHECK
    if ! "$PARSER" "$TMP/check-v30.lua" "$TMP/visgrid.v30.lua"; then
        fail 86 "generated V30 Lua failed parser=$PARSER"
    fi
    echo "PASS generated V30 Lua syntax: $PARSER"
else
    if ! docker cp "$TMP/visgrid.v30.lua" "$CTR:/tmp/visgrid.v30.lua" >/dev/null; then
        fail 87 "no host Lua parser and failed to copy Lua into Docker"
    fi
    DOCKER_PARSER="$(docker exec "$CTR" bash -lc 'for x in luajit texlua lua; do command -v "$x" >/dev/null 2>&1 && { echo "$x"; exit 0; }; done; exit 1' 2>/dev/null || true)"
    if [ -z "$DOCKER_PARSER" ]; then
        fail 88 "no Lua parser available on Ubuntu or Docker; refusing unparsed V30 profile"
    fi
    if ! docker exec "$CTR" "$DOCKER_PARSER" -e 'local f,e=loadfile(arg[1]); assert(f,e)' /tmp/visgrid.v30.lua; then
        fail 89 "generated V30 Lua failed Docker parser=$DOCKER_PARSER"
    fi
    if ! docker exec "$CTR" rm -f /tmp/visgrid.v30.lua; then
        fail 90 "failed to remove Docker Lua parse temp"
    fi
    echo "PASS generated V30 Lua syntax: Docker $DOCKER_PARSER"
fi

V30_LUA_SHA="$(sha256sum "$TMP/visgrid.v30.lua" | awk '{print $1}')"
V30_LAUNCH_SHA="$(sha256sum "$TMP/Morrowind_51.v30.sh" | awk '{print $1}')"
echo "V30 Lua SHA:      $V30_LUA_SHA"
echo "V30 launcher SHA: $V30_LAUNCH_SHA"

echo
echo "===== 7/10 KNOWN-BUILD-MISTAKE REGRESSION SCAN ====="
python3 - "$0" "$TMP/visgrid.v30.lua" "$TMP/Morrowind_51.v30.sh" <<'PY_SCAN'
from pathlib import Path
import re
import sys

controller, lua_path, launcher_path = sys.argv[1:4]
c = Path(controller).read_text(encoding='utf-8')
lua = Path(lua_path).read_text(encoding='utf-8')
launcher = Path(launcher_path).read_text(encoding='utf-8')
problems = []

# Do not let this regression scanner detect the literal examples in its own
# source as if they were controller bugs.
scan_c = re.sub(
    r"(?ms)^python3[^\n]*<<'PY_SCAN'\n.*?^PY_SCAN\n",
    '',
    c,
)

# 1/3. Wrong-shell positional expansion in unquoted heredocs.
for m in re.finditer(r'(?m)<<-?\s*([A-Z][A-Z0-9_]*)\s*$', scan_c):
    delim = m.group(1)
    body_start = scan_c.find('\n', m.end())
    if body_start < 0:
        continue
    body_start += 1
    em = re.search(r'(?m)^' + re.escape(delim) + r'[ \t]*$', scan_c[body_start:])
    if not em:
        problems.append('unterminated unquoted heredoc: ' + delim)
        continue
    body = scan_c[body_start:body_start + em.start()]
    pm = re.search(r'(?<!\\)\$(?:[0-9]+|[@*#?!-])|(?<!\\)\$\{(?:[0-9]+|[@*#?!-])\}', body)
    if pm:
        line = scan_c.count('\n', 0, body_start + pm.start()) + 1
        problems.append('unsafe positional expansion in unquoted heredoc line %d: %s' % (line, pm.group(0)))

# 4. Python 3.8 Path.write_text(newline=...) mistake.
if re.search(r'\.write_text\s*\([^)]*newline\s*=', scan_c, re.S):
    problems.append('Python 3.8-incompatible Path.write_text(..., newline=...)')

# 7. Never assume a historical handler name.
for bad in ('onFrameBody, dt', "(?P<base>onFrameBody)"):
    if bad in scan_c:
        problems.append('hard-coded historical onFrame callback assumption: ' + bad)

# 1. Bare verifier commands under set -e: reject new naked grep/test/cmp lines.
for lineno, line in enumerate(scan_c.splitlines(), 1):
    st = line.strip()
    if re.match(r'^(grep|test|cmp)\b', st) and '|| true' not in st:
        # Collection-only grep pipelines are allowed only when explicitly guarded with || true.
        problems.append('bare verifier-like command at controller line %d: %s' % (lineno, st[:100]))

# 6. V30 must not add top-level Lua locals to the already-large profile.
block_start = lua.find('-- TSP_VISGRID_LUA_V30_FLOOR_ACTOR_ROOMWAKE')
block_end = lua.find('-- No ray learning/prewarm in this diagnostic.', block_start)
if block_start < 0 or block_end < 0:
    problems.append('V30 Lua block boundaries missing')
else:
    for line in lua[block_start:block_end].splitlines():
        if line.startswith('local '):
            problems.append('V30 added top-level Lua local: ' + line)

for token in (
    'TSP_VISGRID_LUA_V30_FLOOR_ACTOR_ROOMWAKE',
    'mapState.v30InferFloor',
    'targetFloor == playerFloor',
    'mapState.pvsBoxes, ids, 0.0, 0.0',
):
    if token not in lua:
        problems.append('generated V30 Lua missing: ' + token)
if 'setInteriorClutterResidency' in lua:
    problems.append('broken V28 clutter bridge leaked into V30 Lua')
for token in (
    'v30_profiles/visgrid-v30-floor-actor-roomwake.lua',
    'Visgrid Profile=v30-floor-actor-roomwake',
):
    if token not in launcher:
        problems.append('generated V30 launcher missing: ' + token)

if problems:
    print('FAIL known-build-mistake regression scan:')
    for p in problems:
        print('  - ' + p)
    raise SystemExit(1)

print('PASS known mistake #1: no naked grep/test/cmp verifier under set -e.')
print('PASS known mistake #3: no positional expansion in unquoted heredocs.')
print('PASS known mistake #4: no brittle callback-name assumption.')
print('PASS known mistake #5: no Python 3.8 Path.write_text(newline=...).')
print('PASS known mistake #6: V30 adds no top-level Lua locals.')
print('PASS known mistake #7: existing frame callback is captured dynamically.')
print('PASS known mistake #8: this is a downloadable controller, not a giant terminal paste.')
PY_SCAN

echo
echo "===== 8/10 BACKUP DEVICE / UPLOAD / VERIFY STAGING ====="
DEVICE_BACKUP="$ROOT/backups/roomwake-v30-floor-actor-$STAMP"
ssh "$DEV" bash -s -- "$DEVICE_BACKUP" "$REMOTE_BIN" "$LIVE_LUA" "$LAUNCHER" "$V30_PROFILE" <<'REMOTE_BACKUP_DEVICE'
set -u
B="$1"; BIN="$2"; LIVE="$3"; LAUNCHER="$4"; V30="$5"
mkdir -p "$B"
backup_one() {
    local src="$1" dst="$2" mode="$3"
    if [ ! -s "$src" ]; then
        echo "FAIL device backup input missing/empty: $src" >&2
        exit 101
    fi
    install -m "$mode" "$src" "$dst"
    echo "PASS device backup: $src"
}
backup_one "$BIN" "$B/openmw-0.51.before" 755
backup_one "$LIVE" "$B/visgrid.lua.before" 644
backup_one "$LAUNCHER" "$B/launcher.before" 755
if [ -f "$V30" ]; then
    touch "$B/v30-profile.existed"
    backup_one "$V30" "$B/v30-profile.before" 644
fi
sha256sum "$B/openmw-0.51.before" "$B/visgrid.lua.before" "$B/launcher.before"
REMOTE_BACKUP_DEVICE

if ! scp -q "$HOST_BIN" "$DEV:$REMOTE_TMP_BIN"; then
    fail 102 "failed to upload V30 binary"
fi
if ! scp -q "$TMP/visgrid.v30.lua" "$DEV:/tmp/visgrid-v30-floor-actor-roomwake.lua"; then
    fail 103 "failed to upload V30 Lua"
fi
if ! scp -q "$TMP/Morrowind_51.v30.sh" "$DEV:/tmp/Morrowind_51.v30.sh"; then
    fail 104 "failed to upload V30 launcher"
fi

ssh "$DEV" bash -s -- \
    "$REMOTE_TMP_BIN" "$NEW_SHA" \
    /tmp/visgrid-v30-floor-actor-roomwake.lua "$V30_LUA_SHA" \
    /tmp/Morrowind_51.v30.sh "$V30_LAUNCH_SHA" <<'REMOTE_STAGE_VERIFY'
set -u
BIN="$1"; BINSHA="$2"; LUA="$3"; LUASHA="$4"; LAUNCH="$5"; LAUNCHSHA="$6"
check_sha() {
    local f="$1" expect="$2" label="$3"
    if [ ! -s "$f" ]; then
        echo "FAIL staged file missing/empty: $label ($f)" >&2
        exit 105
    fi
    local got
    got="$(sha256sum "$f" | awk '{print $1}')"
    if [ "$got" != "$expect" ]; then
        echo "FAIL staged SHA: $label" >&2
        echo "EXPECTED: $expect" >&2
        echo "ACTUAL:   $got" >&2
        exit 106
    fi
    echo "PASS staged SHA: $label = $got"
}
check_sha "$BIN" "$BINSHA" 'V30 binary'
check_sha "$LUA" "$LUASHA" 'V30 Lua'
check_sha "$LAUNCH" "$LAUNCHSHA" 'V30 launcher'
if ! bash -n "$LAUNCH"; then
    echo "FAIL staged launcher Bash syntax" >&2
    exit 107
fi
echo "PASS staged launcher syntax"
REMOTE_STAGE_VERIFY

echo
echo "===== 9/10 INSTALL V30 + VERIFY DEVICE STATE ====="
DEVICE_DEPLOY_STARTED=1
ssh "$DEV" bash -s -- \
    "$REMOTE_TMP_BIN" "$NEW_SHA" "$REMOTE_BIN" \
    /tmp/visgrid-v30-floor-actor-roomwake.lua "$V30_LUA_SHA" "$V30_PROFILE" "$LIVE_LUA" "$V30_DIR" \
    /tmp/Morrowind_51.v30.sh "$V30_LAUNCH_SHA" "$LAUNCHER" <<'REMOTE_INSTALL'
set -u
TMPBIN="$1"; BINSHA="$2"; BIN="$3"
TMPLUA="$4"; LUASHA="$5"; PROFILE="$6"; LIVE="$7"; V30DIR="$8"
TMPLAUNCH="$9"; LAUNCHSHA="${10}"; LAUNCHER="${11}"

check_sha() {
    local f="$1" expect="$2" label="$3"
    if [ ! -s "$f" ]; then
        echo "FAIL install file missing/empty: $label ($f)" >&2
        exit 111
    fi
    local got
    got="$(sha256sum "$f" | awk '{print $1}')"
    if [ "$got" != "$expect" ]; then
        echo "FAIL install SHA: $label" >&2
        echo "EXPECTED: $expect" >&2
        echo "ACTUAL:   $got" >&2
        exit 112
    fi
    echo "PASS install SHA: $label = $got"
}
check_has() {
    local token="$1" file="$2"
    if ! grep -Fq -- "$token" "$file"; then
        echo "FAIL installed marker: [$token]" >&2
        echo "FILE: $file" >&2
        exit 113
    fi
    echo "PASS installed marker: $token"
}
check_absent() {
    local token="$1" file="$2"
    if grep -Fq -- "$token" "$file"; then
        echo "FAIL installed forbidden marker: [$token]" >&2
        echo "FILE: $file" >&2
        exit 114
    fi
    echo "PASS installed absent: $token"
}

check_sha "$TMPBIN" "$BINSHA" 'staged binary before install'
check_sha "$TMPLUA" "$LUASHA" 'staged Lua before install'
check_sha "$TMPLAUNCH" "$LAUNCHSHA" 'staged launcher before install'

mkdir -p "$V30DIR"
install -m 755 "$TMPBIN" "$BIN"
install -m 644 "$TMPLUA" "$PROFILE"
install -m 644 "$TMPLUA" "$LIVE"
install -m 755 "$TMPLAUNCH" "$LAUNCHER"
sync

check_sha "$BIN" "$BINSHA" 'installed V30 binary'
check_sha "$PROFILE" "$LUASHA" 'installed V30 profile'
check_sha "$LIVE" "$LUASHA" 'installed live V30 Lua'
check_sha "$LAUNCHER" "$LAUNCHSHA" 'installed V30 launcher'
check_has 'TSP_VISGRID_LUA_V30_FLOOR_ACTOR_ROOMWAKE' "$LIVE"
check_has 'camera.setInteriorTopologyPvs' "$LIVE"
check_has 'v30_profiles/visgrid-v30-floor-actor-roomwake.lua' "$LAUNCHER"
check_absent 'setInteriorClutterResidency' "$LIVE"
check_absent '# >>> TSP_VISGRID_V24_AUTO_CAPTURE BEGIN' "$LAUNCHER"
check_absent 'export TSP_OBJECT_DIAG=1' "$LAUNCHER"
if ! bash -n "$LAUNCHER"; then
    echo "FAIL installed launcher Bash syntax" >&2
    exit 115
fi
echo "PASS installed launcher syntax"

rm -f "$TMPBIN" "$TMPLUA" "$TMPLAUNCH"
sync
REMOTE_INSTALL

echo
echo "===== 10/10 SAVE STATE / FINAL HASHES ====="
{
    printf 'SOURCE_BACKUP=%q\n' "$SOURCE_BACKUP"
    printf 'DEVICE_BACKUP=%q\n' "$DEVICE_BACKUP"
    printf 'LAUNCHER=%q\n' "$LAUNCHER"
    printf 'REMOTE_BIN=%q\n' "$REMOTE_BIN"
    printf 'LIVE_LUA=%q\n' "$LIVE_LUA"
    printf 'V30_PROFILE=%q\n' "$V30_PROFILE"
    printf 'PRE_BIN_SHA=%q\n' "$PRE_BIN_SHA"
    printf 'PRE_LUA_SHA=%q\n' "$PRE_LUA_SHA"
    printf 'NEW_SHA=%q\n' "$NEW_SHA"
    printf 'V30_LUA_SHA=%q\n' "$V30_LUA_SHA"
} > "$STATE"

trap - ERR
SOURCE_MUTATED=0
DEVICE_DEPLOY_STARTED=0

echo "Installed binary:"
ssh "$DEV" "sha256sum '$REMOTE_BIN'"
echo "Installed Lua:"
ssh "$DEV" "sha256sum '$LIVE_LUA'"

echo
echo "============================================================"
echo "ROOMWAKE V30 INSTALLED"
echo "============================================================"
echo "OBJECT/FLOOR AUTHORITY:"
echo "  current room/connector = live"
echo "  normal rooms on other floors = hard OFF"
echo "  staircase connector itself may remain live across floors"
echo "  doorway prewake = earlier than V29, but normal target must match inferred floor"
echo "  missed clutter origins = nearest topology sector (no V27 >260 permanent-resident escape)"
echo
echo "ACTOR HIBERNATION (FIRST SAFE STAGE):"
echo "  active-room actor = awake"
echo "  off-room actor = removed from Mechanics/AI + render node hidden"
echo "  Bullet actor/collision = retained"
echo "  combat or pursuit = always awake"
echo "  LOS + awareness of player = awake (sampled every 0.25 s)"
echo "  dead/dynamic actors = fail open / untouched"
echo
echo "ONE TEST RUN:"
echo "  1. Caldera staircase: first -> second -> third floor."
echo "  2. At upper blank wall, lower-floor rooms should not appear in V30 active ids."
echo "  3. Approach a same-floor doorway: destination should wake a little earlier than V29."
echo "  4. In an NPC interior, confirm off-room NPCs sleep and current/combat/aware NPCs stay awake."
echo "  5. Exit normally once."
echo
echo "Expected proof lines:"
echo "  [TSP_VISGRID_V30] ... floor=<n> active=..."
echo "  [TSP_ROOMOBJ_V30] pvs=1 ... parked=<large>"
echo "  [TSP_ACTOR_V30] authority=1 ... sleeping=<nonzero> ..."
echo
echo "Collect:"
echo "  cd ~/Downloads"
echo "  ./$(basename "$0") collect"
echo
echo "Rollback: ./$(basename "$0") rollback"
echo "Build log: $BUILD_LOG"
echo "Controller log: $LOG"
echo "============================================================"
