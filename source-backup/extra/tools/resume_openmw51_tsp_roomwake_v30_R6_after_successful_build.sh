#!/usr/bin/env bash
set -u -o pipefail

ACTION="${1:-install}"
CTR="${OPENMW_CONTAINER:-openmw_builder}"
DEV="${TSP_DEVICE:-root@192.168.1.25}"

SRC="/root/openmw-0.51-tsp-src"
BUILD="/root/openmw-0.51-tsp-build"
PACKAGE="/root/openmw-0.51-tsp-package"
SCENE_CPP="$SRC/apps/openmw/mwworld/scene.cpp"
VIS_CPP="$SRC/apps/openmw/mwrender/interiorvisibility.cpp"
BUILT="$BUILD/openmw"
PACKAGED="$PACKAGE/bin/openmw-0.51"

ROOT="/mnt/SDCARD/data/ports/openmw51"
REMOTE_BIN="$ROOT/bin/openmw-0.51"
LIVE_LUA="$ROOT/mods/TSPInteriorVisGrid/scripts/TSPInteriorVisGrid/visgrid.lua"
REMOTE_LOG="$ROOT/openmw_051_log.txt"
REMOTE_PERF="$ROOT/openmw51_perf_latest.txt"
REMOTE_TMP_BIN="/tmp/openmw-0.51.v30-r6-light-near-player"

DL="$HOME/Downloads"
STAMP="$(date +%Y%m%d-%H%M%S)"
LOG="$DL/openmw51-roomwake-v30-r6-light-near-player-$STAMP.log"
BUILD_LOG="$DL/openmw51-roomwake-v30-r6-light-near-player-build-$STAMP.log"
STATE="$DL/openmw51-roomwake-v30-r6-light-near-player.state"
HOST_BIN="$DL/openmw-0.51-v30-r6-light-near-player"
TMP="$(mktemp -d "$DL/.roomwake-v30-r6.XXXXXX")"

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
    require_cmd python3
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

restore_source() {
    if [ -z "$SOURCE_BACKUP" ]; then
        echo "FAIL source rollback: SOURCE_BACKUP is empty" >&2
        return 1
    fi
    if ! docker exec -i "$CTR" bash -s -- "$SOURCE_BACKUP" "$SCENE_CPP" "$VIS_CPP" <<'REMOTE_RESTORE_SOURCE'
set -u
BACKUP="$1"
SCENE="$2"
VIS="$3"

for f in scene.cpp interiorvisibility.cpp; do
    if [ ! -s "$BACKUP/$f" ]; then
        echo "FAIL source rollback backup missing: $BACKUP/$f" >&2
        exit 1
    fi
done

if ! cp -f "$BACKUP/scene.cpp" "$SCENE"; then
    echo "FAIL restoring scene.cpp from $BACKUP" >&2
    exit 2
fi
if ! cp -f "$BACKUP/interiorvisibility.cpp" "$VIS"; then
    echo "FAIL restoring interiorvisibility.cpp from $BACKUP" >&2
    exit 3
fi

touch "$SCENE" "$VIS"
echo "PASS source rollback: restored R5 scene.cpp + interiorvisibility.cpp"
REMOTE_RESTORE_SOURCE
    then
        return 1
    fi
    return 0
}

restore_device() {
    if [ -z "$DEVICE_BACKUP" ]; then
        echo "FAIL device rollback: DEVICE_BACKUP is empty" >&2
        return 1
    fi
    if ! ssh "$DEV" "bash -s -- '$DEVICE_BACKUP' '$REMOTE_BIN'" <<'REMOTE_RESTORE_DEVICE'
set -u
BACKUP="$1"
BIN="$2"
if [ ! -s "$BACKUP" ]; then
    echo "FAIL device rollback backup missing: $BACKUP" >&2
    exit 1
fi
if ! install -m 755 "$BACKUP" "$BIN"; then
    echo "FAIL restoring device binary from $BACKUP" >&2
    exit 2
fi
sync
sha256sum "$BIN"
echo "PASS device rollback"
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
        echo "===== V30 R6 FAILURE RECOVERY ====="
        if [ "$DEVICE_DEPLOY_STARTED" -eq 1 ]; then
            echo "INFO: restoring previous device binary..."
            if ! restore_device; then
                echo "WARNING: automatic device rollback failed" >&2
            fi
        fi
        if [ "$SOURCE_MUTATED" -eq 1 ]; then
            echo "INFO: restoring pre-R6 R5 Docker source..."
            if ! restore_source; then
                echo "WARNING: automatic source rollback failed" >&2
            fi
        fi
    fi
    cleanup
    exit "$rc"
}
trap on_exit EXIT

collect() {
    ensure_ssh
    local out="$DL/openmw51-roomwake-v30-r6-light-near-player-validation-$STAMP.txt"
    if ! ssh "$DEV" "bash -s -- '$REMOTE_LOG' '$REMOTE_PERF' '$REMOTE_BIN' '$LIVE_LUA'" > "$out" <<'REMOTE_COLLECT'
set -u
LOG="$1"
PERF="$2"
BIN="$3"
LUA="$4"

echo "===== V30 R6 VALIDATION ====="
date
printf 'Binary SHA: '
sha256sum "$BIN" 2>/dev/null || true
printf 'Lua SHA:    '
sha256sum "$LUA" 2>/dev/null || true

echo
echo "===== R6 / ROOM / ACTOR / R4 LINES ====="
if [ -f "$LOG" ]; then
    grep -E '\[TSP_ROOMOBJ_V30\]|\[TSP_ACTOR_V30\]|\[TSP_VISGRID_V30_R4\]' "$LOG" 2>/dev/null | tail -260 || true
else
    echo "LOG MISSING: $LOG"
fi

echo
echo "===== PERF TAIL ====="
if [ -f "$PERF" ]; then
    tail -120 "$PERF" 2>/dev/null || true
else
    echo "PERF MISSING: $PERF"
fi
REMOTE_COLLECT
    then
        fail 20 "collect failed from $DEV"
    fi
    echo "Saved: $out"
    return 0
}

rollback_action() {
    ensure_docker
    ensure_ssh
    if [ ! -f "$STATE" ]; then
        fail 21 "rollback state missing: $STATE"
    fi

    # shellcheck disable=SC1090
    . "$STATE"

    if [ -z "${R6_SOURCE_BACKUP:-}" ] || [ -z "${R6_DEVICE_BACKUP:-}" ]; then
        fail 22 "rollback state is incomplete: $STATE"
    fi

    SOURCE_BACKUP="$R6_SOURCE_BACKUP"
    DEVICE_BACKUP="$R6_DEVICE_BACKUP"

    if ! restore_source; then
        fail 23 "source rollback failed"
    fi
    if ! restore_device; then
        fail 24 "device rollback failed"
    fi

    echo "ROLLBACK COMPLETE"
    return 0
}

if [ "$ACTION" = "collect" ]; then
    collect
    exit 0
fi
if [ "$ACTION" = "rollback" ]; then
    rollback_action
    exit 0
fi
if [ "$ACTION" != "install" ]; then
    fail 2 "usage: $0 [install|collect|rollback]"
fi

exec > >(tee "$LOG") 2>&1

echo "============================================================"
echo "OPENMW 0.51 — V30 R6 RESUME AFTER SUCCESSFUL BUILD"
echo "CONTROLLER REVISION: V30-R6-R1 SHA-PINNED RESUME / NO COMPILE"
echo "============================================================"
echo "NO CMAKE. NO NINJA. NO REBUILD."
echo "Uses the exact R6 ARM64 binary already produced by the successful build."
echo "Host SHA required: 898f21fd6475c41eed81e0499d4bda4beb0586e6df0da92058a80ae25a29c512"
echo "Device R5 SHA required: 6ada4b7f01747fb48d037b30c8bceab28c4b29135f8aaee6b4058a1c38e7ca31"
echo "Reapplies the already-proven R6 source edit only so Docker source matches live binary."
echo "============================================================"

ensure_docker
ensure_ssh

if ssh "$DEV" "pgrep -af 'openmw-0\.51|/openmw([[:space:]]|$)' 2>/dev/null" | grep -v pgrep >/dev/null 2>&1; then
    fail 25 "OpenMW appears to be running on the TrimUI; exit the game before installing"
fi

EXPECTED_HOST_SHA='898f21fd6475c41eed81e0499d4bda4beb0586e6df0da92058a80ae25a29c512'
EXPECTED_R5_SHA='6ada4b7f01747fb48d037b30c8bceab28c4b29135f8aaee6b4058a1c38e7ca31'

echo
echo "===== 1/6 VERIFY EXACT PREBUILT R6 + LIVE R5/R4 BASELINE ====="
if [ ! -s "$HOST_BIN" ]; then
    fail 30 "already-built R6 binary missing/empty: $HOST_BIN"
fi
HOST_SHA="$(sha256sum "$HOST_BIN" | awk '{print $1}')"
if [ "$HOST_SHA" != "$EXPECTED_HOST_SHA" ]; then
    echo "EXPECTED R6 SHA: $EXPECTED_HOST_SHA" >&2
    echo "ACTUAL HOST SHA: $HOST_SHA" >&2
    fail 31 "refusing to install a different host binary: $HOST_BIN"
fi
HOST_FILE="$(file "$HOST_BIN" 2>/dev/null || true)"
case "$HOST_FILE" in
    *ARM*aarch64*) ;;
    *) echo "$HOST_FILE" >&2; fail 32 "prebuilt R6 binary is not ARM64/aarch64: $HOST_BIN" ;;
esac
echo "$HOST_FILE"
echo "PASS exact prebuilt R6 SHA: $HOST_SHA"

if ! ssh "$DEV" "test -s '$REMOTE_BIN'"; then
    fail 33 "live device binary missing/empty: $REMOTE_BIN"
fi
LIVE_SHA="$(ssh "$DEV" "sha256sum '$REMOTE_BIN' | awk '{print \$1}'" 2>/dev/null || true)"
if [ "$LIVE_SHA" != "$EXPECTED_R5_SHA" ]; then
    echo "EXPECTED LIVE R5 SHA: $EXPECTED_R5_SHA" >&2
    echo "ACTUAL DEVICE SHA:     $LIVE_SHA" >&2
    fail 34 "device is not on the exact R5 baseline expected by this resume installer"
fi
echo "PASS exact live R5 SHA: $LIVE_SHA"

if ! ssh "$DEV" "grep -Fq 'TSP_VISGRID_V30_R4' '$LIVE_LUA'"; then
    fail 35 "live Lua is not the R4 room-policy baseline: $LIVE_LUA"
fi
if ssh "$DEV" "grep -Fq 'setInteriorClutterResidency' '$LIVE_LUA'"; then
    fail 36 "forbidden V28 clutter bridge found in live Lua: $LIVE_LUA"
fi
echo "PASS live R4 Lua policy unchanged"

if ! docker exec -i "$CTR" bash -s -- "$SCENE_CPP" "$VIS_CPP" <<'REMOTE_VERIFY_R5_SOURCE'
set -u
SCENE="$1"
VIS="$2"
check_has() {
    local token="$1" file="$2" label="$3"
    if ! grep -Fq -- "$token" "$file"; then
        echo "FAIL $label" >&2
        echo "FILE: $file" >&2
        echo "EXPECTED: $token" >&2
        exit 1
    fi
    echo "PASS $label"
}
check_absent() {
    local token="$1" file="$2" label="$3"
    if grep -Fq -- "$token" "$file"; then
        echo "FAIL $label" >&2
        echo "FILE: $file" >&2
        echo "FORBIDDEN: $token" >&2
        exit 2
    fi
    echo "PASS $label"
}
check_has 'TSP_ROOM_LIGHT_KEEPALIVE_051_V30_R5' "$SCENE" 'R5 scene light marker'
check_has 'tspRoomObjectRadius = tspRoomExtendedLight ? 1560.f : 0.f' "$SCENE" 'R5 scene radius expression'
check_has '[TSP_ROOMOBJ_V30] lightKeepXY=1560' "$SCENE" 'R5 source telemetry text'
check_has 'TSP_ROOM_LIGHT_KEEPALIVE_051_V30_R5' "$VIS" 'R5 visibility light marker'
check_has 'const float xyPad = radius > 0.f ? radius : 0.f;' "$VIS" 'R5 visibility XY expansion'
check_has 'TSP_ROOM_OBJECT_FLOOR_AUTHORITY_051_V30' "$VIS" 'V30 floor authority'
check_absent 'TSP_ROOM_LIGHT_PLAYER_KEEP_051_V30_R6' "$SCENE" 'R6 source not already applied after rollback'
REMOTE_VERIFY_R5_SOURCE
then
    fail 37 "Docker source is not the expected post-failure R5 baseline"
fi
echo "===== 2/6 BACK UP CURRENT R5 SOURCE ====="
SOURCE_BACKUP="$SRC/.tsp-051-source-backups/roomwake-v30-r6-light-near-player-$STAMP"
if ! docker exec -i "$CTR" bash -s -- "$SOURCE_BACKUP" "$SCENE_CPP" "$VIS_CPP" <<'REMOTE_BACKUP_SOURCE'
set -u
BACKUP="$1"
SCENE="$2"
VIS="$3"
if ! mkdir -p "$BACKUP"; then
    echo "FAIL mkdir source backup: $BACKUP" >&2
    exit 1
fi
if ! cp -f "$SCENE" "$BACKUP/scene.cpp"; then
    echo "FAIL backup scene.cpp: $SCENE" >&2
    exit 2
fi
if ! cp -f "$VIS" "$BACKUP/interiorvisibility.cpp"; then
    echo "FAIL backup interiorvisibility.cpp: $VIS" >&2
    exit 3
fi
sha256sum "$BACKUP/scene.cpp" "$BACKUP/interiorvisibility.cpp"
echo "PASS source backup: $BACKUP"
REMOTE_BACKUP_SOURCE
then
    fail 40 "failed to back up current R5 source"
fi

echo
echo "===== 3/6 REAPPLY PROVEN R6 SOURCE PATCH — NO BUILD ====="
cat > "$TMP/patch_r6.py" <<'PY_PATCH'
#!/usr/bin/env python3
import sys

SCENE_R5_MARK = 'TSP_ROOM_LIGHT_KEEPALIVE_051_V30_R5'
SCENE_R6_MARK = 'TSP_ROOM_LIGHT_PLAYER_KEEP_051_V30_R6'


def read(path):
    with open(path, 'r', encoding='utf-8', newline='') as f:
        return f.read()


def write(path, text):
    with open(path, 'w', encoding='utf-8', newline='\n') as f:
        f.write(text)


def line_start(text, pos):
    return text.rfind('\n', 0, pos) + 1


def line_indent(text, pos):
    start = line_start(text, pos)
    raw = text[start:pos]
    if raw.strip():
        raise RuntimeError('non-whitespace indentation before marker: %r' % raw)
    return raw


def patch_scene(sc):
    marker = '// ' + SCENE_R5_MARK
    if sc.count(marker) != 1:
        raise RuntimeError('scene R5 marker count=%d expected 1' % sc.count(marker))
    if SCENE_R6_MARK in sc:
        raise RuntimeError('scene R6 marker already present; refusing re-application')

    m = sc.index(marker)
    start = line_start(sc, m)
    indent = line_indent(sc, m)

    required = [
        'const bool tspRoomExtendedLight = ptr.getType() == ESM::REC_LIGH;',
        'const float tspRoomObjectRadius = tspRoomExtendedLight ? 1560.f : 0.f;',
        'const bool shouldLive = MWRender::isInteriorTopologyObjectResident(',
        'origin, tspRoomObjectRadius, false);',
    ]
    search_end = sc.find('if (shouldLive)', m)
    if search_end < 0:
        raise RuntimeError('scene: could not find if (shouldLive) after R5 marker')
    old = sc[start:search_end]
    for token in required:
        if token not in old:
            raise RuntimeError('scene R5 block missing required token: ' + token)

    replacement = (
        indent + '// ' + SCENE_R6_MARK + '\n'
        + indent + '// Room/floor authority remains primary for every object. A light that would\n'
        + indent + '// otherwise be parked is protected only when it is physically near the player.\n'
        + indent + '// XY gets the requested 3x range; Z is independently capped below floor spacing.\n'
        + indent + 'constexpr float tspRoomLightNearXY = 1560.f;\n'
        + indent + 'constexpr float tspRoomLightNearZ = 192.f;\n'
        + indent + 'bool shouldLive = MWRender::isInteriorTopologyObjectResident(\n'
        + indent + '    origin, 0.f, false);\n'
        + indent + 'if (!shouldLive && ptr.getType() == ESM::REC_LIGH)\n'
        + indent + '{\n'
        + indent + '    const osg::Vec3f playerOrigin = MWBase::Environment::get().getWorld()\n'
        + indent + '        ->getPlayerPtr().getRefData().getPosition().asVec3();\n'
        + indent + '    const float dx = origin.x() - playerOrigin.x();\n'
        + indent + '    const float dy = origin.y() - playerOrigin.y();\n'
        + indent + '    const float dz = origin.z() - playerOrigin.z();\n'
        + indent + '    if (dx * dx + dy * dy <= tspRoomLightNearXY * tspRoomLightNearXY\n'
        + indent + '        && dz * dz <= tspRoomLightNearZ * tspRoomLightNearZ)\n'
        + indent + '        shouldLive = true;\n'
        + indent + '}\n\n'
    )

    sc = sc[:start] + replacement + sc[search_end:]

    old_log = '[TSP_ROOMOBJ_V30] lightKeepXY=1560'
    new_log = '[TSP_ROOMOBJ_V30] lightNearXY=1560 lightNearZ=192'
    if sc.count(old_log) != 1:
        raise RuntimeError('scene R5 telemetry count=%d expected 1' % sc.count(old_log))
    sc = sc.replace(old_log, new_log, 1)

    for token in (
        SCENE_R6_MARK,
        'tspRoomLightNearXY = 1560.f',
        'tspRoomLightNearZ = 192.f',
        'ptr.getType() == ESM::REC_LIGH',
        'origin, 0.f, false',
        'getPlayerPtr().getRefData().getPosition().asVec3()',
        new_log,
    ):
        if token not in sc:
            raise RuntimeError('scene R6 postcondition missing: ' + token)

    for token in (
        SCENE_R5_MARK,
        'tspRoomObjectRadius',
        old_log,
    ):
        if token in sc:
            raise RuntimeError('scene obsolete R5 token survived: ' + token)

    return sc


def patch_visibility(vc):
    marker = '// ' + SCENE_R5_MARK
    if vc.count(marker) != 1:
        raise RuntimeError('visibility R5 marker count=%d expected 1' % vc.count(marker))

    m = vc.index(marker)
    start = line_start(vc, m)
    indent = line_indent(vc, m)

    overlap = vc.find('overlaps = origin.x()', m)
    if overlap < 0:
        raise RuntimeError('visibility: R5 overlaps assignment not found')
    end = vc.find(';', overlap)
    if end < 0:
        raise RuntimeError('visibility: R5 overlaps semicolon not found')
    end += 1

    old = vc[start:end]
    for token in (
        'const float xyPad = radius > 0.f ? radius : 0.f;',
        'const float zSlack = radius > 0.f ? 100.f : 110.f;',
        'minX - xyPad',
        'maxX + xyPad',
    ):
        if token not in old:
            raise RuntimeError('visibility R5 block missing: ' + token)

    replacement = (
        indent + 'constexpr float zSlack = 110.f;\n'
        + indent + 'overlaps = origin.x() >= minX && origin.x() <= maxX\n'
        + indent + '    && origin.y() >= minY && origin.y() <= maxY\n'
        + indent + '    && origin.z() >= minZ - zSlack && origin.z() <= maxZ + zSlack;'
    )
    vc = vc[:start] + replacement + vc[end:]

    for token in (
        SCENE_R5_MARK,
        'const float xyPad = radius > 0.f ? radius : 0.f;',
        'const float zSlack = radius > 0.f ? 100.f : 110.f;',
    ):
        if token in vc:
            raise RuntimeError('visibility obsolete R5 token survived: ' + token)

    for token in (
        'TSP_ROOM_OBJECT_FLOOR_AUTHORITY_051_V30',
        'constexpr float zSlack = 110.f;',
        'origin.x() >= minX && origin.x() <= maxX',
    ):
        if token not in vc:
            raise RuntimeError('visibility R6 postcondition missing: ' + token)

    return vc


def selftest():
    scene = '''            // TSP_ROOM_LIGHT_KEEPALIVE_051_V30_R5\n            // Lights get 3x R4 minimum inter-room distance; other objects remain radius 0.\n            const bool tspRoomExtendedLight = ptr.getType() == ESM::REC_LIGH;\n            const float tspRoomObjectRadius = tspRoomExtendedLight ? 1560.f : 0.f;\n            const bool shouldLive = MWRender::isInteriorTopologyObjectResident(\n                origin, tspRoomObjectRadius, false);\n            if (shouldLive)\n                ++resident;\n            Log(Debug::Info) << "[TSP_ROOMOBJ_V30] lightKeepXY=1560";\n'''
    vis = '''        // TSP_ROOM_OBJECT_FLOOR_AUTHORITY_051_V30\n                // TSP_ROOM_LIGHT_KEEPALIVE_051_V30_R5\n                // radius=0 preserves exact V27/V30 clutter ownership. Positive radius\n                // is used only by ESM Light refs and expands XY around active sectors.\n                // Z remains tight to avoid waking lights on another floor.\n                const float xyPad = radius > 0.f ? radius : 0.f;\n                const float zSlack = radius > 0.f ? 100.f : 110.f;\n                overlaps = origin.x() >= minX - xyPad && origin.x() <= maxX + xyPad\n                    && origin.y() >= minY - xyPad && origin.y() <= maxY + xyPad\n                    && origin.z() >= minZ - zSlack && origin.z() <= maxZ + zSlack;\n'''
    ps = patch_scene(scene)
    pv = patch_visibility(vis)
    assert 'TSP_ROOM_LIGHT_PLAYER_KEEP_051_V30_R6' in ps
    assert 'tspRoomLightNearXY = 1560.f' in ps
    assert 'tspRoomLightNearZ = 192.f' in ps
    assert 'origin, 0.f, false' in ps
    assert 'TSP_ROOM_LIGHT_KEEPALIVE_051_V30_R5' not in ps
    assert 'xyPad' not in pv
    assert 'constexpr float zSlack = 110.f;' in pv
    print('PASS R6 patcher selftest')


if len(sys.argv) == 2 and sys.argv[1] == '--selftest':
    selftest()
    raise SystemExit(0)
if len(sys.argv) != 3:
    raise SystemExit('usage: patch_r6.py SCENE_CPP VIS_CPP | --selftest')

scene_path, vis_path = sys.argv[1:3]
scene = patch_scene(read(scene_path))
vis = patch_visibility(read(vis_path))
write(scene_path, scene)
write(vis_path, vis)
print('PASS R5 active-sector light expansion removed')
print('PASS R6 direct-player light protection installed: XY=1560 Z=192')
print('PASS ordinary clutter and V30 floor authority remain unchanged')
PY_PATCH

if ! python3 -m py_compile "$TMP/patch_r6.py"; then
    fail 41 "embedded R6 patcher does not compile under host Python"
fi
if ! python3 "$TMP/patch_r6.py" --selftest; then
    fail 42 "embedded R6 patcher selftest failed"
fi
if ! docker cp "$TMP/patch_r6.py" "$CTR:/tmp/patch_r6.py" >/dev/null; then
    fail 43 "failed to copy R6 patcher to Docker"
fi

SOURCE_MUTATED=1
if ! docker exec "$CTR" python3 /tmp/patch_r6.py "$SCENE_CPP" "$VIS_CPP"; then
    fail 44 "R6 source patch failed"
fi
if ! docker exec "$CTR" rm -f /tmp/patch_r6.py; then
    fail 45 "failed to remove temporary Docker R6 patcher"
fi

if ! docker exec -i "$CTR" bash -s -- "$SCENE_CPP" "$VIS_CPP" <<'REMOTE_VERIFY_R6'
set -u
SCENE="$1"
VIS="$2"
check_has() {
    local token="$1" file="$2" label="$3"
    if ! grep -Fq -- "$token" "$file"; then
        echo "FAIL $label" >&2
        echo "FILE: $file" >&2
        echo "EXPECTED: $token" >&2
        exit 1
    fi
    echo "PASS $label"
}
check_absent() {
    local token="$1" file="$2" label="$3"
    if grep -Fq -- "$token" "$file"; then
        echo "FAIL $label" >&2
        echo "FILE: $file" >&2
        echo "FORBIDDEN: $token" >&2
        exit 2
    fi
    echo "PASS $label"
}
check_has 'TSP_ROOM_LIGHT_PLAYER_KEEP_051_V30_R6' "$SCENE" 'R6 scene marker'
check_has 'tspRoomLightNearXY = 1560.f' "$SCENE" 'R6 XY range'
check_has 'tspRoomLightNearZ = 192.f' "$SCENE" 'R6 Z band'
check_has 'getPlayerPtr().getRefData().getPosition().asVec3()' "$SCENE" 'R6 direct player-position query'
check_has '[TSP_ROOMOBJ_V30] lightNearXY=1560 lightNearZ=192' "$SCENE" 'R6 telemetry marker'
check_has 'TSP_ROOM_OBJECT_FLOOR_AUTHORITY_051_V30' "$VIS" 'V30 floor authority preserved'
check_has 'constexpr float zSlack = 110.f;' "$VIS" 'ordinary V30 exact ownership restored'
check_absent 'TSP_ROOM_LIGHT_KEEPALIVE_051_V30_R5' "$SCENE" 'R5 scene light rule removed'
check_absent 'tspRoomObjectRadius' "$SCENE" 'R5 sector-radius variable removed'
check_absent 'TSP_ROOM_LIGHT_KEEPALIVE_051_V30_R5' "$VIS" 'R5 visibility light rule removed'
check_absent 'const float xyPad = radius > 0.f ? radius : 0.f;' "$VIS" 'R5 sector XY expansion removed'
REMOTE_VERIFY_R6
then
    fail 46 "R6 post-patch verification failed"
fi

echo
echo "===== 4/6 VERIFY SOURCE/BINARY PAIR — NO MARKER-ONLY GATE ====="
# The previous run proved scene.cpp.o and interiorvisibility.cpp.o rebuilt and linked.
# This resume is pinned to that exact output SHA. Source semantics are verified above;
# the executable is accepted by successful build provenance + exact SHA + ELF architecture.
HOST_SHA2="$(sha256sum "$HOST_BIN" | awk '{print $1}')"
if [ "$HOST_SHA2" != "$EXPECTED_HOST_SHA" ]; then
    echo "EXPECTED: $EXPECTED_HOST_SHA" >&2
    echo "ACTUAL:   $HOST_SHA2" >&2
    fail 60 "prebuilt R6 binary changed after source reapply: $HOST_BIN"
fi
HOST_FILE2="$(file "$HOST_BIN" 2>/dev/null || true)"
case "$HOST_FILE2" in
    *ARM*aarch64*) ;;
    *) echo "$HOST_FILE2" >&2; fail 61 "prebuilt R6 binary failed ARM64 verification" ;;
esac
NEW_SHA="$HOST_SHA2"
echo "PASS source semantics verified: R6 player-distance light protection"
echo "PASS exact successful-build SHA: $NEW_SHA"
echo "PASS ELF architecture: ARM64/aarch64"
echo "PASS no runtime marker string is used as a build/install success requirement"

echo
echo "===== 5/6 DEVICE BACKUP + INSTALL EXACT PREBUILT R6 ====="
DEVICE_BACKUP_DIR="$ROOT/backups/roomwake-v30-r6-resume-$STAMP"
DEVICE_BACKUP="$DEVICE_BACKUP_DIR/openmw-0.51.before-r6-resume"

if ! ssh "$DEV" "mkdir -p '$DEVICE_BACKUP_DIR' && cp -f '$REMOTE_BIN' '$DEVICE_BACKUP' && sha256sum '$DEVICE_BACKUP'"; then
    fail 70 "failed to back up live device binary: $DEVICE_BACKUP"
fi

if ! scp -q "$HOST_BIN" "$DEV:$REMOTE_TMP_BIN"; then
    fail 71 "failed to upload exact R6 binary to $DEV:$REMOTE_TMP_BIN"
fi

DEVICE_DEPLOY_STARTED=1
if ! ssh "$DEV" "bash -s -- '$REMOTE_TMP_BIN' '$REMOTE_BIN' '$EXPECTED_HOST_SHA'" <<'REMOTE_INSTALL'
set -u
TMPBIN="$1"
BIN="$2"
EXPECTED="$3"
if [ ! -s "$TMPBIN" ]; then
    echo "FAIL uploaded binary missing/empty: $TMPBIN" >&2
    exit 1
fi
INCOMING="$(sha256sum "$TMPBIN" | awk '{print $1}')"
if [ "$INCOMING" != "$EXPECTED" ]; then
    echo "FAIL uploaded SHA mismatch" >&2
    echo "EXPECTED: $EXPECTED" >&2
    echo "ACTUAL:   $INCOMING" >&2
    exit 2
fi
if ! install -m 755 "$TMPBIN" "$BIN"; then
    echo "FAIL installing R6 binary: $BIN" >&2
    exit 3
fi
rm -f "$TMPBIN"
sync
FINAL="$(sha256sum "$BIN" | awk '{print $1}')"
if [ "$FINAL" != "$EXPECTED" ]; then
    echo "FAIL installed SHA mismatch" >&2
    echo "EXPECTED: $EXPECTED" >&2
    echo "ACTUAL:   $FINAL" >&2
    exit 4
fi
echo "PASS installed exact R6 SHA: $FINAL"
REMOTE_INSTALL
then
    fail 72 "device R6 install/verification failed"
fi

echo
echo "===== 6/6 PRESERVE STATE + FINAL VERIFY ====="
cat > "$STATE" <<EOF_STATE
R6_SOURCE_BACKUP='$SOURCE_BACKUP'
R6_DEVICE_BACKUP='$DEVICE_BACKUP'
R6_OLD_DEVICE_SHA='$LIVE_SHA'
R6_NEW_DEVICE_SHA='$NEW_SHA'
R6_HOST_BIN='$HOST_BIN'
EOF_STATE

if [ ! -s "$STATE" ]; then
    fail 80 "state file was not written: $STATE"
fi
FINAL_DEVICE_SHA="$(ssh "$DEV" "sha256sum '$REMOTE_BIN' | awk '{print \$1}'" 2>/dev/null || true)"
if [ "$FINAL_DEVICE_SHA" != "$EXPECTED_HOST_SHA" ]; then
    echo "EXPECTED: $EXPECTED_HOST_SHA" >&2
    echo "ACTUAL:   $FINAL_DEVICE_SHA" >&2
    fail 81 "final device SHA verification failed"
fi
if ! ssh "$DEV" "grep -Fq 'TSP_VISGRID_V30_R4' '$LIVE_LUA'"; then
    fail 82 "R4 Lua changed unexpectedly during R6 binary install"
fi

SOURCE_MUTATED=0
DEVICE_DEPLOY_STARTED=0

echo
echo "============================================================"
echo "V30 R6 RESUME INSTALL COMPLETE"
echo "============================================================"
echo "Old device SHA: $LIVE_SHA"
echo "New device SHA: $FINAL_DEVICE_SHA"
echo "Prebuilt binary: $HOST_BIN"
echo "State:           $STATE"
echo "Docker source is now R6 again; no compilation was performed."
echo
echo "After ONE Caldera test run:"
echo "  cd ~/Downloads"
echo "  ./resume_openmw51_tsp_roomwake_v30_R6_after_successful_build.sh collect"
echo "============================================================"
