#!/usr/bin/env bash
# OpenMW 0.51 / TrimUI Smart Pro
# V30 R9-R2: align BOTH renderer rejection layers with R7/R8 scene residency.
#
# Latest R8-R2 evidence showed resident=93, inactive=0, parked=0 while objects
# were still visibly popping. Therefore the scene lifecycle is not the remaining
# rejection layer. R9-R2 fixes the per-object InteriorVisibilityCullCallback:
#   * ESM3 Light roots bypass that callback entirely. Their existing R8 scene
#     lifecycle still limits residency to room authority or XY 2800 / |Z| 384.
#   * Gameplay callback topology-PVS is disabled. V30/R4 hard scene residency is
#     already the authoritative gameplay room/floor topology layer; running a
#     second callback PVS can hide an object that Scene correctly kept resident.
#   * The remaining screen-depth curtain may not reject a gameplay object whose
#     eye-space nearest surface is <= 1600 units. Far gameplay still uses it.
#   * Ordinary scene-lifecycle XY ranges are restored from R8-R2 to the proven
#     R7 values (wake 1100 / hold 1450) to offset renderer-side safety work.
#   * R4 Lua, floor authority, actors, static architecture and light lifecycle
#     ranges remain unchanged.
#
# Actions: install (default), collect, rollback

set -u -o pipefail

ACTION="${1:-install}"
CTR="${OPENMW_CONTAINER:-openmw_builder}"
DEV="${TSP_DEVICE:-root@192.168.1.12}"

SRC="/root/openmw-0.51-tsp-src"
BUILD="/root/openmw-0.51-tsp-build"
PACKAGE="/root/openmw-0.51-tsp-package"
SCENE="$SRC/apps/openmw/mwworld/scene.cpp"
ANIM="$SRC/apps/openmw/mwrender/animation.cpp"
VIS="$SRC/apps/openmw/mwrender/interiorvisibility.cpp"
BUILT="$BUILD/openmw"
PACKAGED="$PACKAGE/bin/openmw-0.51"

ROOT="/mnt/SDCARD/data/ports/openmw51"
BIN="$ROOT/bin/openmw-0.51"
LUA="$ROOT/mods/TSPInteriorVisGrid/scripts/TSPInteriorVisGrid/visgrid.lua"
GAMELOG="$ROOT/openmw_051_log.txt"
PERF="$ROOT/openmw51_perf_latest.txt"
TMPBIN="/tmp/openmw-0.51.v30-r9-render-safety"
ARM="$ROOT/roomwake-r9-capture-start.line"

EXPECTED_R8_SHA="96de4ac652ffc3dbb4a27d0848881764a43c274c4958c3d430b3684886d6e72a"

DL="$HOME/Downloads"
STAMP="$(date +%Y%m%d-%H%M%S)"
RUNLOG="$DL/openmw51-roomwake-r9-$STAMP.log"
BUILDLOG="$DL/openmw51-roomwake-r9-build-$STAMP.log"
STATE="$DL/openmw51-roomwake-r9.state"
HOSTBIN="$DL/openmw-0.51-v30-r9-render-safety-alignment"
TMP="$(mktemp -d "$DL/.roomwake-r9.XXXXXX")"

SOURCE_BACKUP=""
DEVICE_BACKUP=""
SOURCE_MUTATED=0
DEVICE_DEPLOYED=0

fail() {
    local rc="${1:-1}"
    shift || true
    echo "ERROR: $*" >&2
    exit "$rc"
}

need() {
    if ! command -v "$1" >/dev/null 2>&1; then
        fail 10 "required command missing: $1"
    fi
    echo "PASS command: $1"
}

ensure_docker() {
    need docker
    if ! docker inspect "$CTR" >/dev/null 2>&1; then
        fail 11 "Docker container not found: $CTR"
    fi
    local running
    running="$(docker inspect -f '{{.State.Running}}' "$CTR" 2>/dev/null || true)"
    if [ "$running" != "true" ]; then
        if ! docker start "$CTR" >/dev/null; then
            fail 12 "failed to start Docker: $CTR"
        fi
    fi
    echo "PASS Docker: $CTR"
}

ensure_ssh() {
    need ssh
    need scp
    if ! ssh -o BatchMode=yes -o ConnectTimeout=8 "$DEV" true >/dev/null 2>&1; then
        fail 13 "SSH failed: $DEV"
    fi
    echo "PASS SSH: $DEV"
}

cleanup() {
    rm -rf "$TMP"
}

restore_source() {
    if [ -z "$SOURCE_BACKUP" ]; then
        echo "FAIL R9 source rollback path empty" >&2
        return 1
    fi
    if ! docker exec -i "$CTR" bash -s -- \
        "$SOURCE_BACKUP" "$SCENE" "$ANIM" "$VIS" "$BUILD" <<'REMOTE_RESTORE_SOURCE'
set -u
BACKUP="$1"
SCENE="$2"
ANIM="$3"
VIS="$4"
BUILD="$5"

for name in scene.cpp animation.cpp interiorvisibility.cpp; do
    if [ ! -s "$BACKUP/$name" ]; then
        echo "FAIL rollback source missing: $BACKUP/$name" >&2
        exit 1
    fi
done

if ! cp -f "$BACKUP/scene.cpp" "$SCENE"; then exit 2; fi
if ! cp -f "$BACKUP/animation.cpp" "$ANIM"; then exit 3; fi
if ! cp -f "$BACKUP/interiorvisibility.cpp" "$VIS"; then exit 4; fi

touch "$SCENE" "$ANIM" "$VIS"
rm -f \
    "$BUILD/apps/openmw/CMakeFiles/openmw-lib.dir/mwworld/scene.cpp.o" \
    "$BUILD/apps/openmw/CMakeFiles/openmw-lib.dir/mwworld/scene.cpp.o.d" \
    "$BUILD/apps/openmw/CMakeFiles/openmw-lib.dir/mwrender/animation.cpp.o" \
    "$BUILD/apps/openmw/CMakeFiles/openmw-lib.dir/mwrender/animation.cpp.o.d" \
    "$BUILD/apps/openmw/CMakeFiles/openmw-lib.dir/mwrender/interiorvisibility.cpp.o" \
    "$BUILD/apps/openmw/CMakeFiles/openmw-lib.dir/mwrender/interiorvisibility.cpp.o.d"

echo "PASS source rollback restored exact pre-R9 R8-R2 source and invalidated all 3 objects"
REMOTE_RESTORE_SOURCE
    then
        return 1
    fi
    return 0
}

restore_device() {
    if [ -z "$DEVICE_BACKUP" ]; then
        echo "FAIL R9 device rollback path empty" >&2
        return 1
    fi
    if ! ssh "$DEV" 'bash -s' -- "$DEVICE_BACKUP" "$BIN" "$EXPECTED_R8_SHA" <<'REMOTE_RESTORE_DEVICE'
set -u
BACKUP="$1"
BIN="$2"
EXPECTED="$3"

if [ ! -s "$BACKUP" ]; then
    echo "FAIL rollback binary missing: $BACKUP" >&2
    exit 1
fi
BACK_SHA="$(sha256sum "$BACKUP" | awk '{print $1}')"
if [ "$BACK_SHA" != "$EXPECTED" ]; then
    echo "FAIL rollback backup SHA expected=$EXPECTED actual=$BACK_SHA" >&2
    exit 2
fi
if ! install -m 755 "$BACKUP" "$BIN"; then
    echo "FAIL restoring R8-R2 binary" >&2
    exit 3
fi
sync
FINAL="$(sha256sum "$BIN" | awk '{print $1}')"
if [ "$FINAL" != "$EXPECTED" ]; then
    echo "FAIL restored R8-R2 SHA expected=$EXPECTED actual=$FINAL" >&2
    exit 4
fi
echo "PASS exact R8-R2 device restored: $FINAL"
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
        echo "===== R9 FAILURE RECOVERY ====="
        if [ "$DEVICE_DEPLOYED" -eq 1 ]; then
            echo "INFO: restoring exact R8-R2 device binary..."
            restore_device || echo "WARNING: automatic R9 device rollback failed" >&2
        fi
        if [ "$SOURCE_MUTATED" -eq 1 ]; then
            echo "INFO: restoring exact R8-R2 Docker source..."
            restore_source || echo "WARNING: automatic R9 source rollback failed" >&2
        fi
    fi
    cleanup
    exit "$rc"
}
trap on_exit EXIT

collect_action() {
    ensure_ssh
    local out="$DL/openmw51-roomwake-r9-validation-$STAMP.txt"

    if ! ssh "$DEV" 'bash -s' -- "$GAMELOG" "$PERF" "$BIN" "$LUA" "$ARM" > "$out" <<'REMOTE_COLLECT'
set -u
LOG="$1"
PERF="$2"
BIN="$3"
LUA="$4"
ARM="$5"

echo "===== OPENMW 0.51 V30 R9-R2 RENDER-SAFETY VALIDATION ====="
date
if [ -s "$BIN" ]; then echo "Binary SHA: $(sha256sum "$BIN" | awk '{print $1}')"; fi
if [ -s "$LUA" ]; then echo "Lua SHA:    $(sha256sum "$LUA" | awk '{print $1}')"; fi

if [ ! -f "$LOG" ]; then
    echo "ERROR log missing: $LOG"
    exit 1
fi

TOTAL="$(wc -l < "$LOG" | tr -d '[:space:]')"
START=""
if [ -s "$ARM" ]; then START="$(tr -dc '0-9' < "$ARM")"; fi
case "$START" in
    ''|*[!0-9]*)
        if [ "$TOTAL" -gt 2200 ]; then START=$((TOTAL-2200)); else START=0; fi
        ;;
esac
FIRST=$((START+1))

echo "Log lines: total=$TOTAL capture=$FIRST..$TOTAL"
echo
sed -n "${FIRST},${TOTAL}p" "$LOG" 2>/dev/null \
    | grep -E 'Loading cell|Changing to interior|\[TSP_ROOMOBJ_V30\]|\[TSP_VISGRID_V30_R4\]|\[TSP_ACTOR_V30\]|\[TSP_VISGRID_V11\]|failed to render' \
    || true

echo
echo "===== PERF TAIL ====="
if [ -f "$PERF" ]; then tail -120 "$PERF" 2>/dev/null || true; fi
REMOTE_COLLECT
    then
        fail 20 "R9 collect failed"
    fi
    echo "Saved: $out"
}

rollback_action() {
    ensure_docker
    ensure_ssh
    if [ ! -s "$STATE" ]; then
        fail 21 "R9 rollback state missing: $STATE"
    fi
    # shellcheck disable=SC1090
    . "$STATE"
    if [ -z "${R9_SOURCE_BACKUP:-}" ] || [ -z "${R9_DEVICE_BACKUP:-}" ]; then
        fail 22 "R9 rollback state incomplete: $STATE"
    fi
    if [ "${R9_OLD_SHA:-}" != "$EXPECTED_R8_SHA" ]; then
        fail 23 "R9 rollback state was not created from exact R8-R2"
    fi
    SOURCE_BACKUP="$R9_SOURCE_BACKUP"
    DEVICE_BACKUP="$R9_DEVICE_BACKUP"
    restore_source || fail 24 "manual R9 source rollback failed"
    restore_device || fail 25 "manual R9 device rollback failed"
    echo "PASS R9 rollback complete; exact R8-R2 restored."
}

case "$ACTION" in
    collect)
        collect_action
        exit 0
        ;;
    rollback)
        rollback_action
        exit 0
        ;;
    install) ;;
    *) fail 2 "usage: $0 [install|collect|rollback]" ;;
esac

exec > >(tee "$RUNLOG") 2>&1

cat <<'BANNER'
============================================================
OPENMW 0.51 — ROOMWAKE V30 R9-R2 RENDER-SAFETY ALIGNMENT
CONTROLLER REVISION: V30-R9-R2 SECOND-LAYER POP FIX
============================================================
Latest R8-R2 capture proved the bad visual state can occur with:
  resident=93 inactive=0 parked=0
so scene lifecycle distance is NOT the remaining rejection layer.

R9-R2:
  - keeps R8 light lifecycle: XY 2800 / |Z| 384
  - restores ordinary lifecycle to proven R7 XY: wake 1100 / hold 1450
  - LIGHTS bypass InteriorVisibilityCullCallback entirely
  - gameplay callback topology-PVS is disabled; V30/R4 Scene owns topology
  - remaining screen-depth callback cannot reject gameplay inside 1600
  - far gameplay clutter still uses the existing screen-depth curtain
  - R4 Lua / actors / static architecture unchanged
============================================================
BANNER

need python3
need sha256sum
need file
ensure_docker
ensure_ssh

if ssh "$DEV" "pgrep -af 'openmw-0\\.51|/openmw([[:space:]]|$)' 2>/dev/null" \
    | grep -v pgrep >/dev/null 2>&1; then
    fail 30 "OpenMW appears to be running; exit the game first"
fi

echo
echo "===== 1/8 VERIFY EXACT R8-R2 DEVICE / R4 LUA / SOURCE SHAPE ====="

LIVE_SHA="$(ssh "$DEV" "sha256sum '$BIN' | awk '{print \$1}'" 2>/dev/null || true)"
if [ "$LIVE_SHA" != "$EXPECTED_R8_SHA" ]; then
    echo "EXPECTED R8-R2: $EXPECTED_R8_SHA" >&2
    echo "ACTUAL DEVICE:  $LIVE_SHA" >&2
    fail 31 "device is not on the exact tested R8-R2 baseline"
fi
echo "PASS exact R8-R2 device SHA: $LIVE_SHA"

if ! ssh "$DEV" "grep -Fq 'TSP_VISGRID_V30_R4' '$LUA'"; then
    fail 32 "live Lua is not R4"
fi
LUA_SHA_BEFORE="$(ssh "$DEV" "sha256sum '$LUA' | awk '{print \$1}'" 2>/dev/null || true)"
if [ -z "$LUA_SHA_BEFORE" ]; then
    fail 33 "could not read live R4 Lua SHA"
fi
echo "PASS live R4 Lua SHA: $LUA_SHA_BEFORE"

if ! docker exec -i "$CTR" python3 - "$SCENE" "$ANIM" "$VIS" <<'PY_PREFLIGHT'
import sys
scene_path, anim_path, vis_path = sys.argv[1:4]

def read(p):
    with open(p, 'r', encoding='utf-8', newline='') as f:
        return f.read()

sc, an, vi = read(scene_path), read(anim_path), read(vis_path)

scene_required = [
    'TSP_ROOM_RANGE_TUNE_051_V30_R8R2',
    'TSP_ROOM_LIGHT_PLAYER_KEEP_051_V30_R6',
    'TSP_ROOM_NEARFIELD_CORRECTNESS_051_V30_R7',
    'tspRoomLightNearXY = 2800.f',
    'tspRoomLightNearZ = 384.f',
    'tspNearWakeXY = 1450.f',
    'tspNearWakeZ = 320.f',
    'tspNearHoldXY = 1800.f',
    'tspNearHoldZ = 384.f',
]
for token in scene_required:
    if token not in sc:
        raise SystemExit('FAIL R8-R2 scene token missing: ' + token)

anim_required = [
    'TSP_VISGRID_OBJECT_CLASS_FIX_051_V1',
    'TSP_VISGRID_CLUTTER_CULL_051_V1',
    'TSP_VISGRID_ROOM_RESIDENCY_051_V24',
    'const bool tspIsStatic = mPtr.getType() == ESM::Static::sRecordId;',
    'const bool tspPvsEligible = std::isfinite(tspPvsRadius)',
    'tspPvsRadius > 0.f && tspPvsRadius <= 900.f;',
    '!tspDiagActor && !tspDiagDoor && !tspIsStatic',
    'new InteriorVisibilityCullCallback',
]
for token in anim_required:
    if token not in an:
        raise SystemExit('FAIL animation baseline token missing: ' + token)
if 'mPtr.get<ESM::Static>()' in an:
    raise SystemExit('FAIL unsafe Static LiveCellRef cast exists in animation.cpp')

vis_required = [
    'TSP_ROOM_OBJECT_FLOOR_AUTHORITY_051_V30',
    'void InteriorVisibilityCullCallback::operator()(osg::Node* node, osgUtil::CullVisitor* cv)',
    'SceneUtil::transformBoundingSphere(*cv->getModelViewMatrix(), bound);',
    'const osg::Vec3d center(bound.center());',
    'const double radius = static_cast<double>(bound.radius());',
    'const double nearestSurface=',
    'sCulled.fetch_add(1,std::memory_order_relaxed);',
]
for token in vis_required:
    if token not in vi:
        raise SystemExit('FAIL interiorvisibility baseline token missing: ' + token)

for token in (
    'TSP_ROOM_RENDER_SAFETY_051_V30_R9',
    'tspGameplayCullBypass',
    'tspIsLight',
):
    if token in sc or token in an or token in vi:
        raise SystemExit('FAIL R9 token already present before patch: ' + token)

for text, token, label in (
    (sc, 'tspNearWakeXY = 1450.f', 'R8 ordinary wake XY'),
    (sc, 'tspNearHoldXY = 1800.f', 'R8 ordinary hold XY'),
    (an, '!tspDiagActor && !tspDiagDoor && !tspIsStatic', 'V27 callback gate'),
    (an, 'const bool tspIsStatic = mPtr.getType() == ESM::Static::sRecordId;', 'Static classifier'),
    (an, 'const bool tspPvsEligible = std::isfinite(tspPvsRadius)', 'V24 gameplay PVS eligibility'),
    (vi, 'const double radius = static_cast<double>(bound.radius());', 'callback radius line'),
):
    count = text.count(token)
    if count != 1:
        raise SystemExit('FAIL %s count=%d expected 1' % (label, count))

print('PASS exact R8-R2 / V27 callback / V30 visibility source shape')
PY_PREFLIGHT
then
    fail 34 "source is not the expected R8-R2 baseline; no source modified"
fi

echo
echo "===== 2/8 BACK UP ALL THREE SOURCE FILES + EXACT R8-R2 DEVICE ====="

SOURCE_BACKUP="$SRC/.tsp-051-source-backups/roomwake-v30-r9-render-safety-$STAMP"
if ! docker exec -i "$CTR" bash -s -- "$SOURCE_BACKUP" "$SCENE" "$ANIM" "$VIS" <<'REMOTE_BACKUP_SOURCE'
set -u
BACKUP="$1"
SCENE="$2"
ANIM="$3"
VIS="$4"

if ! mkdir -p "$BACKUP"; then
    echo "FAIL creating source backup: $BACKUP" >&2
    exit 1
fi
if ! cp -f "$SCENE" "$BACKUP/scene.cpp"; then exit 2; fi
if ! cp -f "$ANIM" "$BACKUP/animation.cpp"; then exit 3; fi
if ! cp -f "$VIS" "$BACKUP/interiorvisibility.cpp"; then exit 4; fi
sha256sum "$BACKUP/scene.cpp" "$BACKUP/animation.cpp" "$BACKUP/interiorvisibility.cpp"
echo "PASS R9 source backup: $BACKUP"
REMOTE_BACKUP_SOURCE
then
    fail 40 "R9 source backup failed"
fi

DEVICE_BACKUP="$ROOT/backups/roomwake-v30-r9-render-safety-$STAMP/openmw-0.51.before-r9"
if ! ssh "$DEV" 'bash -s' -- "$BIN" "$DEVICE_BACKUP" "$EXPECTED_R8_SHA" <<'REMOTE_BACKUP_DEVICE'
set -u
BIN="$1"
BACKUP="$2"
EXPECTED="$3"

if ! mkdir -p "$(dirname "$BACKUP")"; then exit 1; fi
LIVE="$(sha256sum "$BIN" | awk '{print $1}')"
if [ "$LIVE" != "$EXPECTED" ]; then
    echo "FAIL device changed before backup expected=$EXPECTED actual=$LIVE" >&2
    exit 2
fi
if ! cp -f "$BIN" "$BACKUP"; then exit 3; fi
BACK="$(sha256sum "$BACKUP" | awk '{print $1}')"
if [ "$BACK" != "$EXPECTED" ]; then
    echo "FAIL device backup SHA expected=$EXPECTED actual=$BACK" >&2
    exit 4
fi
echo "PASS exact R8-R2 device backup: $BACKUP"
REMOTE_BACKUP_DEVICE
then
    fail 41 "R9 device backup failed"
fi

echo
echo "===== 3/8 CREATE + SELFTEST STRUCTURAL R9 PATCHER ====="

cat > "$TMP/patch_r9.py" <<'PY_PATCH'
#!/usr/bin/env python3
import sys

MARK = 'TSP_ROOM_RENDER_SAFETY_051_V30_R9'
VIS_SIG = 'void InteriorVisibilityCullCallback::operator()(osg::Node* node, osgUtil::CullVisitor* cv)'


def read(path):
    with open(path, 'r', encoding='utf-8', newline='') as f:
        return f.read()


def write(path, text):
    with open(path, 'w', encoding='utf-8', newline='\n') as f:
        f.write(text)


def line_start(text, pos):
    return text.rfind('\n', 0, pos) + 1


def line_end(text, pos):
    e = text.find('\n', pos)
    return len(text) if e < 0 else e + 1


def leading_indent(text, pos):
    s = line_start(text, pos)
    e = line_end(text, pos)
    line = text[s:e]
    return line[:len(line) - len(line.lstrip(' \t'))]


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
    return start, closing + 1


def replace_one(text, old, new, label):
    count = text.count(old)
    if count != 1:
        raise RuntimeError('%s count=%d expected 1 token=%r' % (label, count, old))
    return text.replace(old, new, 1)


def patch_scene(sc):
    for token in (
        'TSP_ROOM_RANGE_TUNE_051_V30_R8R2',
        'TSP_ROOM_NEARFIELD_CORRECTNESS_051_V30_R7',
        'tspRoomLightNearXY = 2800.f',
        'tspRoomLightNearZ = 384.f',
        'tspNearWakeXY = 1450.f',
        'tspNearHoldXY = 1800.f',
    ):
        if token not in sc:
            raise RuntimeError('scene precondition missing: ' + token)
    if MARK in sc:
        raise RuntimeError('R9 scene marker already present')

    sc = replace_one(sc,
        'tspNearWakeXY = 1450.f',
        'tspNearWakeXY = 1100.f',
        'restore R7 ordinary wake XY')
    sc = replace_one(sc,
        'tspNearHoldXY = 1800.f',
        'tspNearHoldXY = 1450.f',
        'restore R7 ordinary hold XY')

    anchor = 'TSP_ROOM_RANGE_TUNE_051_V30_R8R2'
    p = sc.index(anchor)
    ls = line_start(sc, p)
    indent = leading_indent(sc, p)
    sc = sc[:ls] + indent + '// ' + MARK + ' SCENE_R7_RANGES\n' + sc[ls:]

    for token in (
        MARK,
        'tspRoomLightNearXY = 2800.f',
        'tspRoomLightNearZ = 384.f',
        'tspNearWakeXY = 1100.f',
        'tspNearWakeZ = 320.f',
        'tspNearHoldXY = 1450.f',
        'tspNearHoldZ = 384.f',
    ):
        if token not in sc:
            raise RuntimeError('scene postcondition missing: ' + token)
    if 'tspNearHoldXY = 1800.f' in sc:
        raise RuntimeError('R8 ordinary hold XY survived R9')
    return sc


def patch_anim(an):
    for token in (
        'TSP_VISGRID_OBJECT_CLASS_FIX_051_V1',
        'TSP_VISGRID_CLUTTER_CULL_051_V1',
        'TSP_VISGRID_ROOM_RESIDENCY_051_V24',
        'const bool tspIsStatic = mPtr.getType() == ESM::Static::sRecordId;',
        'const bool tspPvsEligible = std::isfinite(tspPvsRadius)',
        'tspPvsRadius > 0.f && tspPvsRadius <= 900.f;',
        '!tspDiagActor && !tspDiagDoor && !tspIsStatic',
        'new InteriorVisibilityCullCallback',
    ):
        if token not in an:
            raise RuntimeError('animation precondition missing: ' + token)
    if MARK in an or 'tspIsLight' in an:
        raise RuntimeError('R9 animation patch already present')
    if 'mPtr.get<ESM::Static>()' in an:
        raise RuntimeError('unsafe Static cast exists before R9')

    # Make ESM::Light::sRecordId explicit instead of relying on an indirect include.
    light_include = '#include <components/esm3/loadligh.hpp>'
    if light_include not in an:
        include_anchor = '#include "interiorvisibility.hpp"'
        if an.count(include_anchor) != 1:
            raise RuntimeError('animation interiorvisibility include anchor count=%d expected 1' % an.count(include_anchor))
        pos = an.index(include_anchor)
        eol = line_end(an, pos)
        an = an[:eol] + light_include + '\n' + an[eol:]

    static_line = 'const bool tspIsStatic = mPtr.getType() == ESM::Static::sRecordId;'
    if an.count(static_line) != 1:
        raise RuntimeError('Static classifier count=%d expected 1' % an.count(static_line))
    sp = an.index(static_line)
    se = line_end(an, sp)
    indent = leading_indent(an, sp)
    insert = (
        indent + '// ' + MARK + ' LIGHT_CALLBACK_BYPASS\n'
        + indent + '// Light residency is controlled by Scene R8. Do not let the older\n'
        + indent + '// screen-depth curtain make a resident light source disappear.\n'
        + indent + 'const bool tspIsLight = mPtr.getType() == ESM::Light::sRecordId;\n'
    )
    an = an[:se] + insert + an[se:]

    # V24 made gameplay roots independently topology-PVS eligible inside this
    # callback. V30/R4 now owns gameplay topology in Scene and physically parks
    # nonresident clutter, so callback PVS is redundant and can contradict Scene.
    pvs_start_token = 'const bool tspPvsEligible = std::isfinite(tspPvsRadius)'
    if an.count(pvs_start_token) != 1:
        raise RuntimeError('gameplay PVS eligibility start count=%d expected 1' % an.count(pvs_start_token))
    pp = an.index(pvs_start_token)
    ps = line_start(an, pp)
    semi = an.find(';', pp)
    if semi < 0:
        raise RuntimeError('gameplay PVS eligibility statement has no semicolon')
    pe = line_end(an, semi)
    old_pvs = an[ps:pe]
    if 'tspPvsRadius > 0.f' not in old_pvs or 'tspPvsRadius <= 900.f' not in old_pvs:
        raise RuntimeError('unexpected gameplay PVS eligibility statement: ' + old_pvs.strip())
    pi = leading_indent(an, pp)
    pvs_replacement = (
        pi + '// ' + MARK + ' CALLBACK_PVS_DISABLED\n'
        + pi + '// V30/R4 Scene residency is the sole gameplay room/floor topology authority.\n'
        + pi + 'const bool tspPvsEligible = false;\n'
    )
    an = an[:ps] + pvs_replacement + an[pe:]

    an = replace_one(an,
        '!tspDiagActor && !tspDiagDoor && !tspIsStatic',
        '!tspDiagActor && !tspDiagDoor && !tspIsStatic && !tspIsLight',
        'animation callback gate')

    for token in (
        MARK,
        light_include,
        'const bool tspIsLight = mPtr.getType() == ESM::Light::sRecordId;',
        'const bool tspPvsEligible = false;',
        'CALLBACK_PVS_DISABLED',
        '!tspDiagActor && !tspDiagDoor && !tspIsStatic && !tspIsLight',
        'new InteriorVisibilityCullCallback',
    ):
        if token not in an:
            raise RuntimeError('animation postcondition missing: ' + token)
    if 'mPtr.get<ESM::Static>()' in an:
        raise RuntimeError('unsafe Static cast appeared during R9')
    return an


def patch_vis(vi):
    for token in (
        'TSP_ROOM_OBJECT_FLOOR_AUTHORITY_051_V30',
        VIS_SIG,
        'SceneUtil::transformBoundingSphere(*cv->getModelViewMatrix(), bound);',
        'const osg::Vec3d center(bound.center());',
        'const double radius = static_cast<double>(bound.radius());',
        'const double nearestSurface=',
    ):
        if token not in vi:
            raise RuntimeError('interiorvisibility precondition missing: ' + token)
    if MARK in vi or 'tspGameplayCullBypass' in vi:
        raise RuntimeError('R9 visibility patch already present')

    fs, fe = function_range(vi, VIS_SIG)
    func = vi[fs:fe]
    radius_line = 'const double radius = static_cast<double>(bound.radius());'
    if func.count(radius_line) != 1:
        raise RuntimeError('callback radius line count=%d expected 1' % func.count(radius_line))
    rp = func.index(radius_line)
    re = line_end(func, rp)
    indent = leading_indent(func, rp)

    safety = (
        '\n'
        + indent + '// ' + MARK + ' NEAR_GAMEPLAY_BYPASS\n'
        + indent + '// V27 attaches this callback only to non-static gameplay roots.\n'
        + indent + '// Scene room/floor residency remains authoritative for existence; this\n'
        + indent + '// prevents the older screen-depth curtain from hiding local gameplay\n'
        + indent + '// that is already resident, especially just beyond an opened doorway.\n'
        + indent + 'constexpr double tspGameplayCullBypass = 1600.0;\n'
        + indent + 'const double tspGameplayNearSurface = std::max(0.0, center.length() - radius);\n'
        + indent + 'if (tspGameplayNearSurface <= tspGameplayCullBypass)\n'
        + indent + '{\n'
        + indent + '    traverse(node, cv);\n'
        + indent + '    return;\n'
        + indent + '}\n'
    )
    func = func[:re] + safety + func[re:]
    vi = vi[:fs] + func + vi[fe:]

    for token in (
        MARK,
        'tspGameplayCullBypass = 1600.0',
        'tspGameplayNearSurface = std::max(0.0, center.length() - radius)',
        'if (tspGameplayNearSurface <= tspGameplayCullBypass)',
        'const double nearestSurface=',
    ):
        if token not in vi:
            raise RuntimeError('interiorvisibility postcondition missing: ' + token)
    return vi


def patch_all(sc, an, vi):
    return patch_scene(sc), patch_anim(an), patch_vis(vi)


def sample_scene():
    return '''\n// TSP_ROOM_RANGE_TUNE_051_V30_R8R2\n// TSP_ROOM_LIGHT_PLAYER_KEEP_051_V30_R6\n// TSP_ROOM_NEARFIELD_CORRECTNESS_051_V30_R7\nconstexpr float tspRoomLightNearXY = 2800.f;\nconstexpr float tspRoomLightNearZ = 384.f;\nconstexpr float tspNearWakeXY = 1450.f;\nconstexpr float tspNearWakeZ = 320.f;\nconstexpr float tspNearHoldXY = 1800.f;\nconstexpr float tspNearHoldZ = 384.f;\n'''


def sample_anim(include_light=False):
    includes = '#include "animation.hpp"\n#include "interiorvisibility.hpp" // TSP_INTERIOR_VISGRID_051_V1\n'
    if include_light:
        includes += '#include <components/esm3/loadligh.hpp>\n'
    return includes + '''\nvoid f()\n{\n    // TSP_VISGRID_OBJECT_CLASS_FIX_051_V1\n    // TSP_VISGRID_CLUTTER_CULL_051_V1\n    // TSP_VISGRID_ROOM_RESIDENCY_051_V24\n    const bool tspDiagActor = false;\n    const bool tspDiagDoor = false;\n    const bool tspIsStatic = mPtr.getType() == ESM::Static::sRecordId;\n    float tspPvsRadius = 100.f;\n    const bool tspPvsEligible = std::isfinite(tspPvsRadius)\n        && tspPvsRadius > 0.f && tspPvsRadius <= 900.f;\n    if (!tspDiagActor && !tspDiagDoor && !tspIsStatic)\n    {\n        mObjectRoot->addCullCallback(new InteriorVisibilityCullCallback(\n            tspPvsOrigin, tspPvsRadius, tspPvsEligible));\n    }\n}\n'''


def sample_vis():
    return '''\n// TSP_ROOM_OBJECT_FLOOR_AUTHORITY_051_V30\nvoid InteriorVisibilityCullCallback::operator()(osg::Node* node, osgUtil::CullVisitor* cv)\n{\n    osg::BoundingSphere bound = node->getBound();\n    SceneUtil::transformBoundingSphere(*cv->getModelViewMatrix(), bound);\n    const osg::Vec3d center(bound.center());\n    const double radius = static_cast<double>(bound.radius());\n    const double nearestSurface=std::max(0.0, center.length()-radius);\n    if (nearestSurface > 5.0)\n    {\n        sCulled.fetch_add(1,std::memory_order_relaxed);\n        return;\n    }\n    traverse(node, cv);\n}\n'''


def selftest():
    for have_light_include in (False, True):
        sc, an, vi = patch_all(sample_scene(), sample_anim(have_light_include), sample_vis())
        assert 'tspNearWakeXY = 1100.f' in sc
        assert 'tspNearHoldXY = 1450.f' in sc
        assert 'tspRoomLightNearXY = 2800.f' in sc
        assert an.count('#include <components/esm3/loadligh.hpp>') == 1
        assert 'tspIsLight = mPtr.getType() == ESM::Light::sRecordId' in an
        assert 'const bool tspPvsEligible = false;' in an
        assert 'const bool tspPvsEligible = std::isfinite(tspPvsRadius)' not in an
        assert '!tspDiagActor && !tspDiagDoor && !tspIsStatic && !tspIsLight' in an
        assert 'tspGameplayCullBypass = 1600.0' in vi
        assert vi.index('tspGameplayCullBypass') < vi.index('const double nearestSurface=')
    print('PASS R9-R2 patcher selftest: light include absent/present + three-file transformation')


if len(sys.argv) == 2 and sys.argv[1] == '--selftest':
    selftest()
    raise SystemExit(0)
if len(sys.argv) != 4:
    raise SystemExit('usage: patch_r9.py SCENE_CPP ANIMATION_CPP INTERIORVISIBILITY_CPP | --selftest')

scene_path, anim_path, vis_path = sys.argv[1:4]
sc, an, vi = patch_all(read(scene_path), read(anim_path), read(vis_path))
write(scene_path, sc)
write(anim_path, an)
write(vis_path, vi)
print('PASS R9-R2 three-file source patch applied')
PY_PATCH

if ! python3 -m py_compile "$TMP/patch_r9.py"; then
    fail 42 "embedded R9 Python patcher does not compile"
fi
if ! python3 "$TMP/patch_r9.py" --selftest; then
    fail 43 "R9 patcher selftest failed"
fi
echo "PASS R9 patcher validated before source mutation"

echo
echo "===== 4/8 APPLY R9 PATCH + VERIFY SEMANTICS ====="

if ! docker cp "$TMP/patch_r9.py" "$CTR:/tmp/patch_r9.py" >/dev/null; then
    fail 44 "failed to copy R9 patcher into Docker"
fi
SOURCE_MUTATED=1
if ! docker exec "$CTR" python3 /tmp/patch_r9.py "$SCENE" "$ANIM" "$VIS"; then
    fail 45 "R9 source patch failed"
fi

if ! docker exec -i "$CTR" python3 - "$SCENE" "$ANIM" "$VIS" <<'PY_VERIFY'
import sys
paths=sys.argv[1:4]
texts=[]
for p in paths:
    with open(p,'r',encoding='utf-8') as f:
        texts.append(f.read())
sc,an,vi=texts

checks = [
    (sc, 'TSP_ROOM_RENDER_SAFETY_051_V30_R9', 'scene R9 marker'),
    (sc, 'tspRoomLightNearXY = 2800.f', 'R8 light XY retained'),
    (sc, 'tspRoomLightNearZ = 384.f', 'R8 light Z retained'),
    (sc, 'tspNearWakeXY = 1100.f', 'ordinary wake restored to R7'),
    (sc, 'tspNearHoldXY = 1450.f', 'ordinary hold restored to R7'),
    (an, 'TSP_ROOM_RENDER_SAFETY_051_V30_R9', 'animation R9 marker'),
    (an, 'const bool tspIsLight = mPtr.getType() == ESM::Light::sRecordId;', 'light classification'),
    (an, 'const bool tspPvsEligible = false;', 'gameplay callback topology PVS disabled'),
    (an, 'CALLBACK_PVS_DISABLED', 'gameplay callback PVS marker'),
    (an, '!tspDiagActor && !tspDiagDoor && !tspIsStatic && !tspIsLight', 'light callback bypass gate'),
    (vi, 'TSP_ROOM_RENDER_SAFETY_051_V30_R9', 'visibility R9 marker'),
    (vi, 'tspGameplayCullBypass = 1600.0', 'near gameplay screen-depth bypass'),
    (vi, 'const double nearestSurface=', 'far screen-depth path retained'),
    (vi, 'TSP_ROOM_OBJECT_FLOOR_AUTHORITY_051_V30', 'V30 floor authority retained'),
]
for text, token, label in checks:
    if token not in text:
        raise SystemExit('FAIL semantic verify missing %s: %s' % (label, token))

for text, token, label in (
    (sc, 'tspNearHoldXY = 1800.f', 'R8 ordinary hold'),
    (an, 'const bool tspPvsEligible = std::isfinite(tspPvsRadius)', 'obsolete callback topology PVS eligibility'),
    (an, 'mPtr.get<ESM::Static>()', 'unsafe Static cast'),
):
    if token in text:
        raise SystemExit('FAIL forbidden token survived %s: %s' % (label, token))

print('PASS R9-R2 semantic verification: lifecycle + light bypass + callback-PVS removal + 1600 near-render safety')
PY_VERIFY
then
    fail 46 "R9 post-patch semantic verification failed"
fi

echo
echo "===== 5/8 INVALIDATE EXACTLY THREE CHANGED OBJECTS ====="

if ! docker exec -i "$CTR" bash -s -- "$BUILD" "$SCENE" "$ANIM" "$VIS" <<'REMOTE_INVALIDATE'
set -u
BUILD="$1"
SCENE="$2"
ANIM="$3"
VIS="$4"

SCENE_OBJ="$BUILD/apps/openmw/CMakeFiles/openmw-lib.dir/mwworld/scene.cpp.o"
ANIM_OBJ="$BUILD/apps/openmw/CMakeFiles/openmw-lib.dir/mwrender/animation.cpp.o"
VIS_OBJ="$BUILD/apps/openmw/CMakeFiles/openmw-lib.dir/mwrender/interiorvisibility.cpp.o"

rm -f "$SCENE_OBJ" "$SCENE_OBJ.d" "$ANIM_OBJ" "$ANIM_OBJ.d" "$VIS_OBJ" "$VIS_OBJ.d"
touch "$SCENE" "$ANIM" "$VIS"

for obj in "$SCENE_OBJ" "$ANIM_OBJ" "$VIS_OBJ"; do
    if [ -e "$obj" ]; then
        echo "FAIL object survived invalidation: $obj" >&2
        exit 1
    fi
done

echo "PASS invalidated scene.cpp.o + animation.cpp.o + interiorvisibility.cpp.o"
REMOTE_INVALIDATE
then
    fail 50 "R9 object invalidation failed"
fi

echo
echo "===== 6/8 BUILD + PROVE ALL THREE TRANSLATION UNITS RECOMPILED ====="

: > "$BUILDLOG"
if ! docker exec "$CTR" cmake --build "$BUILD" --target openmw --parallel 1 2>&1 | tee "$BUILDLOG"; then
    echo
    echo "===== R9 BUILD FAILURE TAIL ====="
    tail -320 "$BUILDLOG" || true
    fail 51 "R9 build failed; full log: $BUILDLOG"
fi

for needle in 'mwworld/scene.cpp.o' 'mwrender/animation.cpp.o' 'mwrender/interiorvisibility.cpp.o'; do
    if ! grep -Fq "$needle" "$BUILDLOG"; then
        fail 52 "build log does not prove recompile: $needle"
    fi
    echo "PASS build log proves recompile: $needle"
done

echo
echo "===== 7/8 PACKAGE + ARM64/SHA VERIFY + INSTALL EXACT COPY ====="

if ! docker exec -i "$CTR" bash -s -- "$BUILT" "$PACKAGED" <<'REMOTE_PACKAGE'
set -u
BUILT="$1"
PACKAGED="$2"
if [ ! -s "$BUILT" ]; then echo "FAIL rebuilt binary missing" >&2; exit 1; fi
if ! mkdir -p "$(dirname "$PACKAGED")"; then exit 2; fi
if ! install -m 755 "$BUILT" "$PACKAGED"; then exit 3; fi
file "$PACKAGED"
sha256sum "$PACKAGED"
REMOTE_PACKAGE
then
    fail 53 "R9 package failed"
fi

if ! docker cp "$CTR:$PACKAGED" "$HOSTBIN" >/dev/null; then
    fail 54 "Docker -> Ubuntu copy failed"
fi
if [ ! -s "$HOSTBIN" ]; then
    fail 55 "host R9 binary missing/empty"
fi
DESC="$(file "$HOSTBIN" 2>/dev/null || true)"
echo "$DESC"
if ! printf '%s\n' "$DESC" | grep -Eq 'ARM aarch64|ARM64|AArch64'; then
    fail 56 "host R9 binary is not ARM64/AArch64: $DESC"
fi
NEW_SHA="$(sha256sum "$HOSTBIN" | awk '{print $1}')"
if [ -z "$NEW_SHA" ]; then
    fail 57 "could not hash R9 host binary"
fi
if [ "$NEW_SHA" = "$EXPECTED_R8_SHA" ]; then
    fail 58 "R9 binary SHA unexpectedly equals R8-R2 after three semantic source changes"
fi
echo "PASS R9 ARM64 host SHA: $NEW_SHA"

if ! scp -q "$HOSTBIN" "$DEV:$TMPBIN"; then
    fail 60 "R9 upload failed"
fi
DEVICE_DEPLOYED=1
if ! ssh "$DEV" 'bash -s' -- "$TMPBIN" "$BIN" "$NEW_SHA" <<'REMOTE_INSTALL'
set -u
TMP="$1"
BIN="$2"
EXPECTED="$3"
if [ ! -s "$TMP" ]; then echo "FAIL uploaded binary missing" >&2; exit 1; fi
INCOMING="$(sha256sum "$TMP" | awk '{print $1}')"
if [ "$INCOMING" != "$EXPECTED" ]; then
    echo "FAIL upload SHA expected=$EXPECTED actual=$INCOMING" >&2
    exit 2
fi
if ! install -m 755 "$TMP" "$BIN"; then exit 3; fi
rm -f "$TMP"
sync
FINAL="$(sha256sum "$BIN" | awk '{print $1}')"
if [ "$FINAL" != "$EXPECTED" ]; then
    echo "FAIL final SHA expected=$EXPECTED actual=$FINAL" >&2
    exit 4
fi
echo "PASS installed exact R9 SHA: $FINAL"
REMOTE_INSTALL
then
    fail 61 "R9 device install failed"
fi

FINAL_SHA="$(ssh "$DEV" "sha256sum '$BIN' | awk '{print \$1}'" 2>/dev/null || true)"
if [ "$FINAL_SHA" != "$NEW_SHA" ]; then
    fail 62 "final device SHA verification failed"
fi
LUA_SHA_AFTER="$(ssh "$DEV" "sha256sum '$LUA' | awk '{print \$1}'" 2>/dev/null || true)"
if [ "$LUA_SHA_AFTER" != "$LUA_SHA_BEFORE" ]; then
    echo "LUA BEFORE: $LUA_SHA_BEFORE" >&2
    echo "LUA AFTER:  $LUA_SHA_AFTER" >&2
    fail 63 "R4 Lua changed unexpectedly during R9"
fi

echo
echo "===== 8/8 ARM CLEAN CAPTURE + SAVE R8-R2 ROLLBACK STATE ====="

if ! ssh "$DEV" 'bash -s' -- "$GAMELOG" "$ARM" <<'REMOTE_ARM'
set -u
LOG="$1"
ARM="$2"
if [ ! -f "$LOG" ]; then echo "FAIL log missing: $LOG" >&2; exit 1; fi
LINES="$(wc -l < "$LOG" | tr -d '[:space:]')"
case "$LINES" in ''|*[!0-9]*) echo "FAIL invalid log line count: $LINES" >&2; exit 2;; esac
if ! printf '%s\n' "$LINES" > "$ARM"; then exit 3; fi
echo "PASS R9 capture armed after log line: $LINES"
REMOTE_ARM
then
    fail 64 "R9 capture arm failed"
fi

cat > "$STATE" <<EOF_STATE
R9_SOURCE_BACKUP='$SOURCE_BACKUP'
R9_DEVICE_BACKUP='$DEVICE_BACKUP'
R9_OLD_SHA='$EXPECTED_R8_SHA'
R9_NEW_SHA='$NEW_SHA'
R9_HOST_BIN='$HOSTBIN'
R9_LUA_SHA='$LUA_SHA_AFTER'
EOF_STATE
if [ ! -s "$STATE" ]; then
    fail 65 "R9 state file was not written: $STATE"
fi

SOURCE_MUTATED=0
DEVICE_DEPLOYED=0

echo
echo "============================================================"
echo "V30 R9-R2 RENDER-SAFETY ALIGNMENT INSTALLED"
echo "============================================================"
echo "R8-R2 SHA: $EXPECTED_R8_SHA"
echo "R9 SHA:    $FINAL_SHA"
echo "R4 Lua:    $LUA_SHA_AFTER"
echo "Host bin:  $HOSTBIN"
echo "State:     $STATE"
echo
echo "Test once:"
echo "  1. Ald-ruhn Manor District: front door -> main-hall lights"
echo "  2. Ald-ruhn Arobar Guard Quarters: open every small-room door"
echo "  3. Balmora Mages Guild staircase: R7 regression check"
echo
echo "Then collect:"
echo "  cd ~/Downloads"
echo "  ./apply_openmw51_tsp_roomwake_v30_R9_R2_render_safety_alignment.sh collect"
echo
echo "Rollback to exact R8-R2:"
echo "  ./apply_openmw51_tsp_roomwake_v30_R9_R2_render_safety_alignment.sh rollback"
echo "============================================================"
