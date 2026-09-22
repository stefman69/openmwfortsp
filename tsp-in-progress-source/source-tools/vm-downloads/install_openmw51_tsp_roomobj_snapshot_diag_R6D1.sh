#!/usr/bin/env bash
set -u -o pipefail

# OpenMW 0.51 / TrimUI Smart Pro
# R6D1 DIAGNOSTIC ONLY: per-object nearby room-residency snapshots.
# Does NOT change the culling policy. It only adds logging once per existing
# ~1 second room-object telemetry cycle, then rebuilds scene.cpp only.
#
# Actions:
#   install  (default) build/install diagnostic binary and arm capture
#   arm               start a fresh capture window without rebuilding
#   collect           pull diagnostics from the armed capture window
#   rollback          restore the exact pre-diagnostic R6 binary + source

ACTION="${1:-install}"
CTR="${OPENMW_CONTAINER:-openmw_builder}"
DEV="${TSP_DEVICE:-root@192.168.1.25}"

SRC="/root/openmw-0.51-tsp-src"
BUILD="/root/openmw-0.51-tsp-build"
PACKAGE="/root/openmw-0.51-tsp-package"
SCENE_CPP="$SRC/apps/openmw/mwworld/scene.cpp"
BUILT="$BUILD/openmw"
PACKAGED="$PACKAGE/bin/openmw-0.51"

ROOT="/mnt/SDCARD/data/ports/openmw51"
REMOTE_BIN="$ROOT/bin/openmw-0.51"
LIVE_LUA="$ROOT/mods/TSPInteriorVisGrid/scripts/TSPInteriorVisGrid/visgrid.lua"
REMOTE_LOG="$ROOT/openmw_051_log.txt"
REMOTE_PERF="$ROOT/openmw51_perf_latest.txt"
MOD_SCRIPT_DIR="$ROOT/mods/TSPInteriorVisGrid/scripts/TSPInteriorVisGrid"
ARM_FILE="$ROOT/roomobj-r6d1-capture-start.line"
REMOTE_TMP_BIN="/tmp/openmw-0.51.r6d1-roomobj-snapshot"

EXPECTED_R6_SHA="898f21fd6475c41eed81e0499d4bda4beb0586e6df0da92058a80ae25a29c512"

DL="$HOME/Downloads"
STAMP="$(date +%Y%m%d-%H%M%S)"
LOG="$DL/openmw51-roomobj-r6d1-$STAMP.log"
BUILD_LOG="$DL/openmw51-roomobj-r6d1-build-$STAMP.log"
STATE="$DL/openmw51-roomobj-r6d1.state"
HOST_BIN="$DL/openmw-0.51-v30-r6d1-roomobj-snapshot"
TMP="$(mktemp -d "$DL/.roomobj-r6d1.XXXXXX")"

SOURCE_BACKUP=""
DEVICE_BACKUP=""
SOURCE_MUTATED=0
DEVICE_DEPLOY_STARTED=0

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
    require_cmd sha256sum
    require_cmd file
    if ! ssh -o BatchMode=yes -o ConnectTimeout=8 "$DEV" true; then
        fail 13 "cannot reach $DEV with non-interactive SSH"
    fi
    echo "PASS SSH: $DEV"
}

cleanup() {
    rm -rf "$TMP" 2>/dev/null || true
}

restore_source_from() {
    local backup="$1"
    if [ -z "$backup" ]; then
        echo "FAIL source rollback: backup path is empty" >&2
        return 1
    fi
    if ! docker exec -i "$CTR" bash -s -- "$backup" "$SCENE_CPP" "$BUILD" <<'REMOTE_RESTORE_SOURCE'
set -u
BACKUP="$1"
SCENE="$2"
BUILD="$3"
if [ ! -s "$BACKUP/scene.cpp" ]; then
    echo "FAIL source rollback backup missing: $BACKUP/scene.cpp" >&2
    exit 1
fi
if ! cp -f "$BACKUP/scene.cpp" "$SCENE"; then
    echo "FAIL restoring scene.cpp from: $BACKUP/scene.cpp" >&2
    exit 2
fi
touch "$SCENE"
OBJ="$BUILD/apps/openmw/CMakeFiles/openmw-lib.dir/mwworld/scene.cpp.o"
rm -f "$OBJ" "$OBJ.d"
echo "PASS source rollback: restored pre-R6D1 scene.cpp and invalidated scene.cpp.o"
REMOTE_RESTORE_SOURCE
    then
        return 1
    fi
    return 0
}

restore_device_from() {
    local backup="$1"
    local expected="$2"
    if [ -z "$backup" ]; then
        echo "FAIL device rollback: backup path is empty" >&2
        return 1
    fi
    if ! ssh "$DEV" 'bash -s' -- "$backup" "$REMOTE_BIN" "$expected" <<'REMOTE_RESTORE_DEVICE'
set -u
BACKUP="$1"
BIN="$2"
EXPECTED="$3"
if [ ! -s "$BACKUP" ]; then
    echo "FAIL device rollback backup missing: $BACKUP" >&2
    exit 1
fi
if ! install -m 755 "$BACKUP" "$BIN"; then
    echo "FAIL restoring device binary from: $BACKUP" >&2
    exit 2
fi
sync
ACTUAL="$(sha256sum "$BIN" | awk '{print $1}')"
if [ "$ACTUAL" != "$EXPECTED" ]; then
    echo "FAIL restored device SHA mismatch" >&2
    echo "EXPECTED: $EXPECTED" >&2
    echo "ACTUAL:   $ACTUAL" >&2
    exit 3
fi
echo "PASS device rollback SHA: $ACTUAL"
REMOTE_RESTORE_DEVICE
    then
        return 1
    fi
    return 0
}

on_exit() {
    local rc=$?
    trap - EXIT
    if [ "$rc" -ne 0 ]; then
        echo
        echo "===== R6D1 FAILURE RECOVERY ====="
        if [ "$DEVICE_DEPLOY_STARTED" -eq 1 ]; then
            echo "INFO: restoring pre-diagnostic device binary..."
            if ! restore_device_from "$DEVICE_BACKUP" "$EXPECTED_R6_SHA"; then
                echo "WARNING: automatic device rollback failed" >&2
            fi
        fi
        if [ "$SOURCE_MUTATED" -eq 1 ]; then
            echo "INFO: restoring pre-diagnostic R6 source..."
            if ! restore_source_from "$SOURCE_BACKUP"; then
                echo "WARNING: automatic source rollback failed" >&2
            fi
        fi
    fi
    cleanup
    exit "$rc"
}
trap on_exit EXIT

arm_capture() {
    ensure_ssh
    if ! ssh "$DEV" 'bash -s' -- "$REMOTE_LOG" "$ARM_FILE" <<'REMOTE_ARM'
set -u
LOG="$1"
ARM="$2"
if [ ! -f "$LOG" ]; then
    echo "FAIL log file missing: $LOG" >&2
    exit 1
fi
LINES="$(wc -l < "$LOG" | tr -d '[:space:]')"
case "$LINES" in
    ''|*[!0-9]*)
        echo "FAIL invalid log line count for: $LOG" >&2
        echo "VALUE: $LINES" >&2
        exit 2
        ;;
esac
if ! printf '%s\n' "$LINES" > "$ARM"; then
    echo "FAIL could not write capture start: $ARM" >&2
    exit 3
fi
echo "PASS capture armed after log line: $LINES"
echo "ARM_FILE: $ARM"
REMOTE_ARM
    then
        fail 20 "failed to arm R6D1 capture"
    fi
}

collect_capture() {
    ensure_ssh
    local out="$DL/openmw51-roomobj-r6d1-capture-$STAMP.txt"
    local context="$DL/openmw51-roomobj-r6d1-context-$STAMP.tar.gz"
    local remote_context="/tmp/openmw51-roomobj-r6d1-context-$STAMP.tar.gz"

    if ! ssh "$DEV" 'bash -s' -- \
        "$REMOTE_LOG" "$REMOTE_PERF" "$REMOTE_BIN" "$LIVE_LUA" "$ARM_FILE" > "$out" <<'REMOTE_COLLECT'
set -u
LOG="$1"
PERF="$2"
BIN="$3"
LUA="$4"
ARM="$5"

echo "===== OPENMW 0.51 R6D1 ROOM-OBJECT CAPTURE ====="
date
if [ -s "$BIN" ]; then
    echo "Binary SHA: $(sha256sum "$BIN" | awk '{print $1}')"
else
    echo "WARN binary missing: $BIN"
fi
if [ -s "$LUA" ]; then
    echo "Lua SHA:    $(sha256sum "$LUA" | awk '{print $1}')"
else
    echo "WARN Lua missing: $LUA"
fi

if [ ! -f "$LOG" ]; then
    echo "ERROR log missing: $LOG"
    exit 1
fi
TOTAL="$(wc -l < "$LOG" | tr -d '[:space:]')"
START=""
if [ -s "$ARM" ]; then
    START="$(tr -dc '0-9' < "$ARM")"
fi
case "$START" in
    ''|*[!0-9]*)
        if [ "$TOTAL" -gt 2200 ]; then START=$((TOTAL - 2200)); else START=0; fi
        echo "WARN no valid arm point; using last capture window from line $START"
        ;;
    *)
        if [ "$START" -gt "$TOTAL" ]; then
            echo "WARN arm point $START is beyond current log length $TOTAL; using last 2200 lines"
            if [ "$TOTAL" -gt 2200 ]; then START=$((TOTAL - 2200)); else START=0; fi
        fi
        ;;
esac
FIRST=$((START + 1))
echo "Log lines: total=$TOTAL capture=$FIRST..$TOTAL"
echo

echo "===== FILTERED ROOM / OBJECT / ACTOR / CELL EVENTS ====="
MATCHES="$(sed -n "${FIRST},${TOTAL}p" "$LOG" | grep -E '\[TSP_ROOMOBJ_SNAP_R6D1\]|\[TSP_ROOMOBJ_NEAR_R6D1\]|\[TSP_ROOMOBJ_V30\]|\[TSP_ACTOR_V30\]|\[TSP_VISGRID_V30_R4\]|Loading cell|Unloading cell|failed to render|[Ee][Rr][Rr][Oo][Rr]' || true)"
if [ -n "$MATCHES" ]; then
    printf '%s\n' "$MATCHES"
else
    echo "WARN no matching diagnostic lines were found in the armed window."
fi

echo
echo "===== PERFORMANCE TAIL ====="
if [ -f "$PERF" ]; then
    tail -160 "$PERF" || true
else
    echo "WARN perf file missing: $PERF"
fi
REMOTE_COLLECT
    then
        fail 21 "failed to collect R6D1 diagnostics"
    fi

    if ! ssh "$DEV" 'bash -s' -- "$MOD_SCRIPT_DIR" "$remote_context" <<'REMOTE_CONTEXT'
set -u
DIR="$1"
OUT="$2"
if [ ! -d "$DIR" ]; then
    echo "WARN context source directory missing: $DIR" >&2
    exit 0
fi
cd "$DIR" || exit 0
set --
for item in visgrid.lua topology.lua topology_cells doorgraph.lua doorgraph_cells; do
    if [ -e "$item" ]; then
        set -- "$@" "$item"
    fi
done
if [ "$#" -eq 0 ]; then
    echo "WARN no topology context files found under: $DIR" >&2
    exit 0
fi
rm -f "$OUT"
if ! tar -czf "$OUT" "$@" 2>/dev/null; then
    echo "WARN could not create topology context archive: $OUT" >&2
    rm -f "$OUT"
    exit 0
fi
echo "PASS topology context archive: $OUT" >&2
REMOTE_CONTEXT
    then
        echo "WARNING: topology context archive command failed; text capture is still valid" >&2
    fi

    if ssh "$DEV" "test -s '$remote_context'" >/dev/null 2>&1; then
        if ! scp -q "$DEV:$remote_context" "$context"; then
            echo "WARNING: could not copy topology context archive" >&2
        else
            echo "Saved topology context: $context"
        fi
        ssh "$DEV" "rm -f '$remote_context'" >/dev/null 2>&1 || true
    fi

    echo "Saved diagnostic text: $out"
    echo "Send me the diagnostic text file; send the context tar.gz too if convenient."
}

rollback_action() {
    ensure_docker
    ensure_ssh
    if [ ! -s "$STATE" ]; then
        fail 22 "rollback state missing: $STATE"
    fi
    # State is generated by this controller and contains only shell-quoted paths/hashes.
    # shellcheck disable=SC1090
    . "$STATE"

    if [ -z "${R6D1_SOURCE_BACKUP:-}" ]; then
        fail 23 "state missing R6D1_SOURCE_BACKUP: $STATE"
    fi
    if [ -z "${R6D1_DEVICE_BACKUP:-}" ]; then
        fail 24 "state missing R6D1_DEVICE_BACKUP: $STATE"
    fi
    if [ "${R6D1_OLD_DEVICE_SHA:-}" != "$EXPECTED_R6_SHA" ]; then
        fail 25 "state old SHA is not the expected R6 SHA; state=$STATE value=${R6D1_OLD_DEVICE_SHA:-EMPTY}"
    fi

    if ! restore_source_from "$R6D1_SOURCE_BACKUP"; then
        fail 26 "manual source rollback failed"
    fi
    if ! restore_device_from "$R6D1_DEVICE_BACKUP" "$EXPECTED_R6_SHA"; then
        fail 27 "manual device rollback failed"
    fi
    echo "PASS R6D1 rollback complete; exact R6 binary restored."
}

case "$ACTION" in
    arm)
        arm_capture
        exit 0
        ;;
    collect)
        collect_capture
        exit 0
        ;;
    rollback)
        rollback_action
        exit 0
        ;;
    install)
        ;;
    *)
        fail 2 "unknown action '$ACTION'; expected install, arm, collect, or rollback"
        ;;
esac

exec > >(tee "$LOG") 2>&1

echo "============================================================"
echo "OPENMW 0.51 — R6D1 ROOM-OBJECT SNAPSHOT DIAGNOSTIC"
echo "CONTROLLER REVISION: R6D1 NEARBY OBJECT OWNERSHIP SNAPSHOT"
echo "============================================================"
echo "Culling policy: UNCHANGED from installed R6 + R4 Lua."
echo "Diagnostic: once per existing ~1s object log cycle."
echo "Nearby capture: XY <= 2200, |Z| <= 700."
echo "Logs parked/inactive objects plus wake transitions."
echo "Do NOT use this diagnostic build for FPS benchmarking."
echo "============================================================"

ensure_docker
ensure_ssh
require_cmd python3

if ! ssh "$DEV" "test -s '$REMOTE_BIN'"; then
    fail 30 "live OpenMW binary missing: $REMOTE_BIN"
fi
LIVE_SHA="$(ssh "$DEV" "sha256sum '$REMOTE_BIN' | awk '{print \$1}'" 2>/dev/null || true)"
if [ "$LIVE_SHA" != "$EXPECTED_R6_SHA" ]; then
    fail 31 "live binary is not the exact R6 baseline; expected=$EXPECTED_R6_SHA actual=${LIVE_SHA:-EMPTY} path=$REMOTE_BIN"
fi
echo "PASS exact live R6 binary SHA: $LIVE_SHA"

if ! ssh "$DEV" "grep -Fq 'TSP_VISGRID_V30_R4' '$LIVE_LUA'"; then
    fail 32 "live Lua is not the expected R4 room policy: $LIVE_LUA"
fi
echo "PASS live R4 Lua policy"

if ! docker exec -i "$CTR" bash -s -- "$SCENE_CPP" <<'REMOTE_PREFLIGHT'
set -u
SCENE="$1"
check_has() {
    local token="$1" label="$2"
    if ! grep -Fq -- "$token" "$SCENE"; then
        echo "FAIL $label" >&2
        echo "FILE: $SCENE" >&2
        echo "EXPECTED: $token" >&2
        exit 1
    fi
    echo "PASS $label"
}
check_absent() {
    local token="$1" label="$2"
    if grep -Fq -- "$token" "$SCENE"; then
        echo "FAIL $label" >&2
        echo "FILE: $SCENE" >&2
        echo "FORBIDDEN: $token" >&2
        exit 2
    fi
    echo "PASS $label"
}
check_has 'TSP_ROOM_LIGHT_PLAYER_KEEP_051_V30_R6' 'R6 direct-player light source marker'
check_has 'tspRoomLightNearXY = 1560.f' 'R6 light XY source rule'
check_has 'tspRoomLightNearZ = 192.f' 'R6 light Z source rule'
check_has '[TSP_ROOMOBJ_V30] lightNearXY=1560 lightNearZ=192' 'R6 aggregate object telemetry source'
check_has 'void Scene::tspUpdateRoomObjectLifecycle(float duration)' 'room-object lifecycle function'
check_absent 'TSP_ROOM_OBJECT_SNAPSHOT_DIAG_051_R6D1' 'R6D1 diagnostic not already applied'
REMOTE_PREFLIGHT
then
    fail 33 "Docker source is not the exact expected R6 shape"
fi

SOURCE_BACKUP="$SRC/.tsp-051-source-backups/roomobj-r6d1-$STAMP"
echo
echo "===== 1/6 BACK UP EXACT R6 SOURCE ====="
if ! docker exec -i "$CTR" bash -s -- "$SOURCE_BACKUP" "$SCENE_CPP" <<'REMOTE_BACKUP'
set -u
BACKUP="$1"
SCENE="$2"
if ! mkdir -p "$BACKUP"; then
    echo "FAIL creating source backup directory: $BACKUP" >&2
    exit 1
fi
if ! cp -f "$SCENE" "$BACKUP/scene.cpp"; then
    echo "FAIL backing up scene.cpp: $SCENE" >&2
    exit 2
fi
sha256sum "$BACKUP/scene.cpp"
echo "PASS source backup: $BACKUP/scene.cpp"
REMOTE_BACKUP
then
    fail 40 "failed to back up R6 scene.cpp"
fi

echo
echo "===== 2/6 APPLY DIAGNOSTIC-ONLY SOURCE PATCH ====="
cat > "$TMP/patch_r6d1.py" <<'PY_PATCH'
#!/usr/bin/env python3
import sys

MARK = 'TSP_ROOM_OBJECT_SNAPSHOT_DIAG_051_R6D1'
R6_MARK = 'TSP_ROOM_LIGHT_PLAYER_KEEP_051_V30_R6'
FUNC_SIG = 'void Scene::tspUpdateRoomObjectLifecycle(float duration)'


def read(path):
    with open(path, 'r', encoding='utf-8', newline='') as f:
        return f.read()


def write(path, text):
    with open(path, 'w', encoding='utf-8', newline='\n') as f:
        f.write(text)


def matching_brace(text, opening):
    depth = 0
    i = opening
    in_string = False
    in_char = False
    escaped = False
    line_comment = False
    block_comment = False
    while i < len(text):
        ch = text[i]
        nxt = text[i + 1] if i + 1 < len(text) else ''
        if line_comment:
            if ch == '\n':
                line_comment = False
            i += 1
            continue
        if block_comment:
            if ch == '*' and nxt == '/':
                block_comment = False
                i += 2
            else:
                i += 1
            continue
        if in_string:
            if escaped:
                escaped = False
            elif ch == '\\':
                escaped = True
            elif ch == '"':
                in_string = False
            i += 1
            continue
        if in_char:
            if escaped:
                escaped = False
            elif ch == '\\':
                escaped = True
            elif ch == "'":
                in_char = False
            i += 1
            continue
        if ch == '/' and nxt == '/':
            line_comment = True
            i += 2
            continue
        if ch == '/' and nxt == '*':
            block_comment = True
            i += 2
            continue
        if ch == '"':
            in_string = True
            i += 1
            continue
        if ch == "'":
            in_char = True
            i += 1
            continue
        if ch == '{':
            depth += 1
        elif ch == '}':
            depth -= 1
            if depth == 0:
                return i
        i += 1
    raise RuntimeError('matching closing brace not found')


def function_range(text, signature):
    count = text.count(signature)
    if count != 1:
        raise RuntimeError('%s count=%d expected 1' % (signature, count))
    start = text.index(signature)
    opening = text.find('{', start + len(signature))
    if opening < 0:
        raise RuntimeError('function opening brace not found: ' + signature)
    closing = matching_brace(text, opening)
    return start, opening, closing + 1


def patch_scene(sc):
    if sc.count(R6_MARK) != 1:
        raise RuntimeError('R6 source marker count=%d expected 1' % sc.count(R6_MARK))
    if MARK in sc:
        raise RuntimeError('R6D1 marker already present; refusing re-application')
    if '[TSP_ROOMOBJ_V30] lightNearXY=1560 lightNearZ=192' not in sc:
        raise RuntimeError('R6 aggregate telemetry source token missing')

    fs, fo, fe = function_range(sc, FUNC_SIG)
    func = sc[fs:fe]

    counters = '        int inactive = 0;\n'
    if func.count(counters) != 1:
        raise RuntimeError('object lifecycle inactive-counter anchor count=%d expected 1' % func.count(counters))
    setup = '''        int inactive = 0;\n\n        // TSP_ROOM_OBJECT_SNAPSHOT_DIAG_051_R6D1\n        // Reuse the existing once-per-second aggregate telemetry cadence. No culling\n        // decision is changed by this block.\n        const bool tspRoomObjectDiagSnapshot = mTspRoomLogAccumulator >= 1.f;\n        const osg::Vec3f tspRoomObjectDiagPlayer = MWBase::Environment::get().getWorld()\n            ->getPlayerPtr().getRefData().getPosition().asVec3();\n        if (tspRoomObjectDiagSnapshot)\n        {\n            Log(Debug::Info)\n                << "[TSP_ROOMOBJ_SNAP_R6D1]"\n                << " playerX=" << tspRoomObjectDiagPlayer.x()\n                << " playerY=" << tspRoomObjectDiagPlayer.y()\n                << " playerZ=" << tspRoomObjectDiagPlayer.z()\n                << " nearXY=2200 nearZ=700";\n        }\n'''
    func = func.replace(counters, setup, 1)

    r6pos = func.find('// ' + R6_MARK)
    if r6pos < 0:
        raise RuntimeError('R6 light block not found inside object lifecycle function')
    decision_token = func.find('if (shouldLive)', r6pos)
    if decision_token < 0:
        raise RuntimeError('final if (shouldLive) not found after R6 light block')
    decision = func.rfind('\n', 0, decision_token) + 1

    diag = '''            // TSP_ROOM_OBJECT_SNAPSHOT_DIAG_051_R6D1\n            if (tspRoomObjectDiagSnapshot)\n            {\n                const float tspDiagDx = origin.x() - tspRoomObjectDiagPlayer.x();\n                const float tspDiagDy = origin.y() - tspRoomObjectDiagPlayer.y();\n                const float tspDiagDz = origin.z() - tspRoomObjectDiagPlayer.z();\n                constexpr float tspDiagNearXY = 2200.f;\n                constexpr float tspDiagNearZ = 700.f;\n                const bool tspDiagNear = tspDiagDx * tspDiagDx + tspDiagDy * tspDiagDy\n                        <= tspDiagNearXY * tspDiagNearXY\n                    && tspDiagDz >= -tspDiagNearZ && tspDiagDz <= tspDiagNearZ;\n                const bool tspDiagWasParked\n                    = mTspRoomSuppressedRefs.find(refnum) != mTspRoomSuppressedRefs.end();\n                if (tspDiagNear && (tspDiagWasParked || !shouldLive))\n                {\n                    const bool tspDiagBaseRoom\n                        = MWRender::isInteriorTopologyObjectResident(origin, 0.f, false);\n                    Log(Debug::Info)\n                        << "[TSP_ROOMOBJ_NEAR_R6D1]"\n                        << " id=" << ptr.getCellRef().getRefId()\n                        << " objX=" << origin.x()\n                        << " objY=" << origin.y()\n                        << " objZ=" << origin.z()\n                        << " dx=" << tspDiagDx\n                        << " dy=" << tspDiagDy\n                        << " dz=" << tspDiagDz\n                        << " room=" << (tspDiagBaseRoom ? 1 : 0)\n                        << " final=" << (shouldLive ? 1 : 0)\n                        << " parked=" << (tspDiagWasParked ? 1 : 0)\n                        << " light=" << (ptr.getType() == ESM::REC_LIGH ? 1 : 0);\n                }\n            }\n\n'''
    func = func[:decision] + diag + func[decision:]
    sc = sc[:fs] + func + sc[fe:]

    required = (
        MARK,
        '[TSP_ROOMOBJ_SNAP_R6D1]',
        '[TSP_ROOMOBJ_NEAR_R6D1]',
        'tspRoomObjectDiagSnapshot = mTspRoomLogAccumulator >= 1.f',
        'tspDiagNearXY = 2200.f',
        'tspDiagNearZ = 700.f',
        'mTspRoomSuppressedRefs.find(refnum)',
        'isInteriorTopologyObjectResident(origin, 0.f, false)',
        'TSP_ROOM_LIGHT_PLAYER_KEEP_051_V30_R6',
        '[TSP_ROOMOBJ_V30] lightNearXY=1560 lightNearZ=192',
    )
    for token in required:
        if token not in sc:
            raise RuntimeError('R6D1 postcondition missing: ' + token)
    if sc.count(MARK) != 2:
        raise RuntimeError('R6D1 marker count=%d expected 2' % sc.count(MARK))
    return sc


def selftest():
    sample = '''\n    void Scene::tspUpdateRoomObjectLifecycle(float duration)\n    {\n        int eligible = 0;\n        int resident = 0;\n        int inactive = 0;\n\n        mCurrentCell->forEach([&](const Ptr& ptr) {\n            const ESM::RefNum refnum = ptr.getCellRef().getRefNum();\n            const osg::Vec3f origin = ptr.getRefData().getPosition().asVec3();\n            // TSP_ROOM_LIGHT_PLAYER_KEEP_051_V30_R6\n            constexpr float tspRoomLightNearXY = 1560.f;\n            constexpr float tspRoomLightNearZ = 192.f;\n            bool shouldLive = MWRender::isInteriorTopologyObjectResident(\n                origin, 0.f, false);\n            if (!shouldLive && ptr.getType() == ESM::REC_LIGH)\n            {\n                const osg::Vec3f playerOrigin = MWBase::Environment::get().getWorld()\n                    ->getPlayerPtr().getRefData().getPosition().asVec3();\n                const float dx = origin.x() - playerOrigin.x();\n                const float dy = origin.y() - playerOrigin.y();\n                const float dz = origin.z() - playerOrigin.z();\n                if (dx * dx + dy * dy <= tspRoomLightNearXY * tspRoomLightNearXY\n                    && dz * dz <= tspRoomLightNearZ * tspRoomLightNearZ)\n                    shouldLive = true;\n            }\n\n            if (shouldLive)\n                ++resident;\n            else\n                ++inactive;\n            return true;\n        });\n        Log(Debug::Info) << "[TSP_ROOMOBJ_V30] lightNearXY=1560 lightNearZ=192";\n    }\n'''
    patched = patch_scene(sample)
    assert patched.count(MARK) == 2
    assert '[TSP_ROOMOBJ_NEAR_R6D1]' in patched
    assert '[TSP_ROOMOBJ_SNAP_R6D1]' in patched
    assert patched.index('[TSP_ROOMOBJ_NEAR_R6D1]') < patched.index('if (shouldLive)', patched.index(R6_MARK))
    print('PASS R6D1 patcher structural selftest')


if len(sys.argv) == 2 and sys.argv[1] == '--selftest':
    selftest()
    raise SystemExit(0)
if len(sys.argv) != 2:
    raise SystemExit('usage: patch_r6d1.py SCENE_CPP | --selftest')

path = sys.argv[1]
text = patch_scene(read(path))
write(path, text)
print('PASS R6D1 diagnostic source patch applied')
print('PASS culling policy unchanged; logging only')
PY_PATCH

if ! python3 -m py_compile "$TMP/patch_r6d1.py"; then
    fail 41 "embedded R6D1 Python patcher failed host py_compile"
fi
if ! python3 "$TMP/patch_r6d1.py" --selftest; then
    fail 42 "embedded R6D1 structural patcher selftest failed"
fi
if ! docker cp "$TMP/patch_r6d1.py" "$CTR:/tmp/patch_r6d1.py" >/dev/null; then
    fail 43 "failed to copy diagnostic patcher into Docker"
fi

SOURCE_MUTATED=1
if ! docker exec "$CTR" python3 /tmp/patch_r6d1.py "$SCENE_CPP"; then
    fail 44 "R6D1 source patch failed"
fi
if ! docker exec "$CTR" rm -f /tmp/patch_r6d1.py; then
    fail 45 "failed to remove temporary Docker patcher"
fi

if ! docker exec -i "$CTR" bash -s -- "$SCENE_CPP" <<'REMOTE_VERIFY_PATCH'
set -u
SCENE="$1"
check_has() {
    local token="$1" label="$2"
    if ! grep -Fq -- "$token" "$SCENE"; then
        echo "FAIL $label" >&2
        echo "FILE: $SCENE" >&2
        echo "EXPECTED: $token" >&2
        exit 1
    fi
    echo "PASS $label"
}
check_has 'TSP_ROOM_OBJECT_SNAPSHOT_DIAG_051_R6D1' 'diagnostic marker'
check_has '[TSP_ROOMOBJ_SNAP_R6D1]' 'snapshot header logging'
check_has '[TSP_ROOMOBJ_NEAR_R6D1]' 'nearby per-object logging'
check_has 'tspDiagNearXY = 2200.f' 'diagnostic XY radius'
check_has 'tspDiagNearZ = 700.f' 'diagnostic Z radius'
check_has 'TSP_ROOM_LIGHT_PLAYER_KEEP_051_V30_R6' 'R6 light behavior preserved'
check_has '[TSP_ROOMOBJ_V30] lightNearXY=1560 lightNearZ=192' 'R6 aggregate telemetry preserved'
REMOTE_VERIFY_PATCH
then
    fail 46 "R6D1 post-patch source verification failed"
fi

echo
echo "===== 3/6 INVALIDATE SCENE OBJECT + BUILD ====="
if ! docker exec -i "$CTR" bash -s -- "$BUILD" "$SCENE_CPP" <<'REMOTE_INVALIDATE'
set -u
BUILD="$1"
SCENE="$2"
OBJ="$BUILD/apps/openmw/CMakeFiles/openmw-lib.dir/mwworld/scene.cpp.o"
rm -f "$OBJ" "$OBJ.d"
touch "$SCENE"
if [ -e "$OBJ" ]; then
    echo "FAIL scene.cpp.o survived invalidation: $OBJ" >&2
    exit 1
fi
echo "PASS invalidated scene.cpp.o"
REMOTE_INVALIDATE
then
    fail 50 "failed to invalidate scene.cpp.o"
fi

: > "$BUILD_LOG"
if ! docker exec "$CTR" cmake --build "$BUILD" --target openmw --parallel 1 2>&1 | tee "$BUILD_LOG"; then
    echo
    echo "===== BUILD FAILURE TAIL ====="
    tail -280 "$BUILD_LOG" || true
    fail 51 "R6D1 diagnostic build failed; full log: $BUILD_LOG"
fi
if ! grep -Fq 'scene.cpp.o' "$BUILD_LOG"; then
    fail 52 "build log does not prove scene.cpp.o recompiled; log=$BUILD_LOG"
fi
echo "PASS build log proves recompile: scene.cpp.o"

if ! docker exec -i "$CTR" bash -s -- "$BUILT" "$PACKAGED" <<'REMOTE_PACKAGE'
set -u
BUILT="$1"
PACKAGED="$2"
if [ ! -s "$BUILT" ]; then
    echo "FAIL rebuilt binary missing/empty: $BUILT" >&2
    exit 1
fi
if ! mkdir -p "$(dirname "$PACKAGED")"; then
    echo "FAIL cannot create package bin directory: $(dirname "$PACKAGED")" >&2
    exit 2
fi
if ! install -m 755 "$BUILT" "$PACKAGED"; then
    echo "FAIL packaging diagnostic binary: $PACKAGED" >&2
    exit 3
fi
file "$PACKAGED"
sha256sum "$PACKAGED"
REMOTE_PACKAGE
then
    fail 53 "failed to package R6D1 diagnostic binary"
fi

echo
echo "===== 4/6 COPY OUT + MULTI-VERIFY ====="
if ! docker cp "$CTR:$PACKAGED" "$HOST_BIN" >/dev/null; then
    fail 60 "Docker -> Ubuntu copy failed: $HOST_BIN"
fi
if [ ! -s "$HOST_BIN" ]; then
    fail 61 "Ubuntu diagnostic binary missing/empty: $HOST_BIN"
fi
DESC="$(file "$HOST_BIN")"
echo "$DESC"
if ! printf '%s\n' "$DESC" | grep -Eq 'ARM aarch64|ARM64|AArch64'; then
    fail 62 "diagnostic binary is not ARM64/AArch64: $DESC"
fi
NEW_SHA="$(sha256sum "$HOST_BIN" | awk '{print $1}')"
if [ -z "$NEW_SHA" ]; then
    fail 63 "could not calculate diagnostic binary SHA: $HOST_BIN"
fi
if [ "$NEW_SHA" = "$EXPECTED_R6_SHA" ]; then
    fail 64 "diagnostic rebuild SHA unexpectedly equals R6 baseline; expected a changed executable SHA=$NEW_SHA"
fi
echo "PASS diagnostic ARM64 binary SHA: $NEW_SHA"
echo "PASS verification uses build success + recompiled TU + ELF architecture + exact SHA; no marker-only binary gate"

DEVICE_BACKUP_DIR="$ROOT/backups/roomobj-r6d1-$STAMP"
DEVICE_BACKUP="$DEVICE_BACKUP_DIR/openmw-0.51.before-r6d1"

echo
echo "===== 5/6 BACK UP R6 + INSTALL DIAGNOSTIC BINARY ====="
if ! ssh "$DEV" 'bash -s' -- "$REMOTE_BIN" "$DEVICE_BACKUP_DIR" "$DEVICE_BACKUP" "$EXPECTED_R6_SHA" <<'REMOTE_DEVICE_BACKUP'
set -u
BIN="$1"
DIR="$2"
BACKUP="$3"
EXPECTED="$4"
if [ ! -s "$BIN" ]; then
    echo "FAIL live binary missing: $BIN" >&2
    exit 1
fi
ACTUAL="$(sha256sum "$BIN" | awk '{print $1}')"
if [ "$ACTUAL" != "$EXPECTED" ]; then
    echo "FAIL live R6 SHA changed before backup" >&2
    echo "EXPECTED: $EXPECTED" >&2
    echo "ACTUAL:   $ACTUAL" >&2
    exit 2
fi
if ! mkdir -p "$DIR"; then
    echo "FAIL creating device backup directory: $DIR" >&2
    exit 3
fi
if ! cp -f "$BIN" "$BACKUP"; then
    echo "FAIL backing up live binary to: $BACKUP" >&2
    exit 4
fi
BACKUP_SHA="$(sha256sum "$BACKUP" | awk '{print $1}')"
if [ "$BACKUP_SHA" != "$EXPECTED" ]; then
    echo "FAIL device backup SHA mismatch: $BACKUP" >&2
    exit 5
fi
echo "PASS device R6 backup SHA: $BACKUP_SHA"
REMOTE_DEVICE_BACKUP
then
    fail 70 "device R6 backup failed"
fi

if ! scp -q "$HOST_BIN" "$DEV:$REMOTE_TMP_BIN"; then
    fail 71 "failed to upload diagnostic binary: $REMOTE_TMP_BIN"
fi
DEVICE_DEPLOY_STARTED=1
if ! ssh "$DEV" 'bash -s' -- "$REMOTE_TMP_BIN" "$REMOTE_BIN" "$NEW_SHA" <<'REMOTE_INSTALL'
set -u
TMPBIN="$1"
BIN="$2"
EXPECTED="$3"
if [ ! -s "$TMPBIN" ]; then
    echo "FAIL uploaded diagnostic binary missing: $TMPBIN" >&2
    exit 1
fi
INCOMING="$(sha256sum "$TMPBIN" | awk '{print $1}')"
if [ "$INCOMING" != "$EXPECTED" ]; then
    echo "FAIL uploaded diagnostic SHA mismatch" >&2
    echo "EXPECTED: $EXPECTED" >&2
    echo "ACTUAL:   $INCOMING" >&2
    exit 2
fi
if ! install -m 755 "$TMPBIN" "$BIN"; then
    echo "FAIL installing diagnostic binary: $BIN" >&2
    exit 3
fi
rm -f "$TMPBIN"
sync
FINAL="$(sha256sum "$BIN" | awk '{print $1}')"
if [ "$FINAL" != "$EXPECTED" ]; then
    echo "FAIL installed diagnostic SHA mismatch" >&2
    echo "EXPECTED: $EXPECTED" >&2
    echo "ACTUAL:   $FINAL" >&2
    exit 4
fi
echo "PASS installed diagnostic SHA: $FINAL"
REMOTE_INSTALL
then
    fail 72 "diagnostic device installation failed"
fi

echo
echo "===== 6/6 SAVE STATE + ARM CAPTURE ====="
cat > "$STATE" <<EOF_STATE
R6D1_SOURCE_BACKUP='$SOURCE_BACKUP'
R6D1_DEVICE_BACKUP='$DEVICE_BACKUP'
R6D1_OLD_DEVICE_SHA='$EXPECTED_R6_SHA'
R6D1_DIAG_DEVICE_SHA='$NEW_SHA'
R6D1_HOST_BIN='$HOST_BIN'
EOF_STATE
if [ ! -s "$STATE" ]; then
    fail 80 "diagnostic state file was not written: $STATE"
fi

SOURCE_MUTATED=0
DEVICE_DEPLOY_STARTED=0

arm_capture

echo
echo "============================================================"
echo "R6D1 DIAGNOSTIC INSTALLED — CULLING POLICY UNCHANGED"
echo "============================================================"
echo "R6 baseline SHA:   $EXPECTED_R6_SHA"
echo "Diagnostic SHA:    $NEW_SHA"
echo "Diagnostic binary: $HOST_BIN"
echo "State:             $STATE"
echo
echo "Test the broken locations; do NOT judge FPS on this logging build."
echo "At each bad spot, stand still about 3 seconds, then move until objects pop."
echo "You can test several locations in the same run."
echo
echo "Collect afterward:"
echo "  cd ~/Downloads"
echo "  ./install_openmw51_tsp_roomobj_snapshot_diag_R6D1.sh collect"
echo
echo "For a fresh second capture later:"
echo "  ./install_openmw51_tsp_roomobj_snapshot_diag_R6D1.sh arm"
echo
echo "Restore normal R6 after capturing:"
echo "  ./install_openmw51_tsp_roomobj_snapshot_diag_R6D1.sh rollback"
echo "============================================================"
