#!/usr/bin/env bash
# OpenMW 0.51 / TrimUI Smart Pro
# V30 R11-R1: four-ray, five-tier XY + independent height authority.
#
# Starts from the exact tested R10-R1 build. R9's renderer alignment and R10's
# four-ray bridge remain intact; R11 replaces the combined three-range mode
# with separate five-tier horizontal and vertical authorities.
#
# Corrected 2026-09-02 after build log 115434: the six R10 Scene range
# declarations are separated by live lifecycle/control-flow code. R11 must
# replace each declaration independently and preserve exact counts of
# shouldLive/toWake/toSuppress/pvsEnabled. A separated-declaration compiler
# fixture prevents any future return to a contiguous-span replacement.
#
# R11 keeps exactly four Lua physics rays per 0.20-second sample. The true
# center ray stays fixed. Left, right, and upper rays sweep an eight-phase
# circular offset around their anchors. The three forward depths drive XY;
# the upward depth independently drives Z. Both are exponential moving
# authorities initialized from the live R4 navmesh sector AABB/kind. Large
# witnesses expand quickly; sustained small witnesses contract slowly. Every
# cell/topology change wipes both evidence slates.
#
# Horizontal tiers (0=open through 4=very-tight):
#   light XY:       2600, 2100, 1650, 1200, 750
#   ordinary wake: 1100,  925,  750,  575, 400
#   ordinary hold: 1450, 1235, 1025,  810, 600
#   render bypass: 1450, 1200,  950,  700, 450
# Vertical tiers (0=tall through 4=low):
#   light Z:         512, 416, 336, 256, 176
#   ordinary wake Z: 336, 288, 240, 192, 144
#   ordinary hold Z: 432, 368, 304, 240, 176
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
VISH="$SRC/apps/openmw/mwrender/interiorvisibility.hpp"
CAMBIND="$SRC/apps/openmw/mwlua/camerabindings.cpp"
BUILT="$BUILD/openmw"
PACKAGED="$PACKAGE/bin/openmw-0.51"

ROOT="/mnt/SDCARD/data/ports/openmw51"
BIN="$ROOT/bin/openmw-0.51"
LUA="$ROOT/mods/TSPInteriorVisGrid/scripts/TSPInteriorVisGrid/visgrid.lua"
PROFILE="$ROOT/mods/TSPInteriorVisGrid/scripts/TSPInteriorVisGrid/v30_profiles/visgrid-v30-floor-actor-roomwake.lua"
GAMELOG="$ROOT/openmw_051_log.txt"
PERF="$ROOT/openmw51_perf_latest.txt"
TMPBIN="/tmp/openmw-0.51.v30-r11-four-ray"
TMPLUA="/tmp/visgrid-v30-r11-four-ray.lua"
ARM="$ROOT/roomwake-r11-capture-start.line"

DL="$HOME/Downloads"
STAMP="$(date +%Y%m%d-%H%M%S)"
RUNLOG="$DL/openmw51-roomwake-r11-$STAMP.log"
BUILDLOG="$DL/openmw51-roomwake-r11-build-$STAMP.log"
STATE="$DL/openmw51-roomwake-r11.state"
HOSTBIN="$DL/openmw-0.51-v30-r11-four-ray-five-tier-xy-height"
TMP="$(mktemp -d "$DL/.roomwake-r11.XXXXXX")"

SOURCE_BACKUP=""
DEVICE_BACKUP=""
SOURCE_MUTATED=0
DEVICE_DEPLOYED=0
LUA_DEPLOYED=0
EXPECTED_R10_SHA="c0db9a6d683026c9bd2fdbf1c42cece22b978116f2720999ebedb6e3803f486b"
EXPECTED_R10_LUA_SHA="f379f3a5eee7cdba9c645576e60988414e476b69d256793451d19646b46c2984"

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
        echo "FAIL R11 source rollback path empty" >&2
        return 1
    fi
    if ! docker exec -i "$CTR" bash -s -- \
        "$SOURCE_BACKUP" "$SCENE" "$VIS" "$VISH" "$CAMBIND" "$BUILD" <<'REMOTE_RESTORE_SOURCE'
set -u
BACKUP="$1"
SCENE="$2"
VIS="$3"
VISH="$4"
CAMBIND="$5"
BUILD="$6"

for name in scene.cpp interiorvisibility.cpp interiorvisibility.hpp camerabindings.cpp; do
    if [ ! -s "$BACKUP/$name" ]; then
        echo "FAIL rollback source missing: $BACKUP/$name" >&2
        exit 1
    fi
done

if ! cp -f "$BACKUP/scene.cpp" "$SCENE"; then exit 2; fi
if ! cp -f "$BACKUP/interiorvisibility.cpp" "$VIS"; then exit 3; fi
if ! cp -f "$BACKUP/interiorvisibility.hpp" "$VISH"; then exit 4; fi
if ! cp -f "$BACKUP/camerabindings.cpp" "$CAMBIND"; then exit 5; fi

touch "$SCENE" "$VIS" "$VISH" "$CAMBIND"
rm -f \
    "$BUILD/apps/openmw/CMakeFiles/openmw-lib.dir/mwworld/scene.cpp.o" \
    "$BUILD/apps/openmw/CMakeFiles/openmw-lib.dir/mwworld/scene.cpp.o.d" \
    "$BUILD/apps/openmw/CMakeFiles/openmw-lib.dir/mwrender/interiorvisibility.cpp.o" \
    "$BUILD/apps/openmw/CMakeFiles/openmw-lib.dir/mwrender/interiorvisibility.cpp.o.d" \
    "$BUILD/apps/openmw/CMakeFiles/openmw-lib.dir/mwlua/camerabindings.cpp.o" \
    "$BUILD/apps/openmw/CMakeFiles/openmw-lib.dir/mwlua/camerabindings.cpp.o.d"

echo "PASS source rollback restored exact pre-R11 R10 source and invalidated all 3 translation units"
REMOTE_RESTORE_SOURCE
    then
        return 1
    fi
    return 0
}

restore_device() {
    if [ -z "$DEVICE_BACKUP" ]; then
        echo "FAIL R11 device rollback path empty" >&2
        return 1
    fi
    if ! ssh "$DEV" 'bash -s' -- "$DEVICE_BACKUP/openmw-0.51.before-r11" "$BIN" "$EXPECTED_R10_SHA" <<'REMOTE_RESTORE_DEVICE'
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
    echo "FAIL restoring R10 binary" >&2
    exit 3
fi
sync
FINAL="$(sha256sum "$BIN" | awk '{print $1}')"
if [ "$FINAL" != "$EXPECTED" ]; then
    echo "FAIL restored R10 SHA expected=$EXPECTED actual=$FINAL" >&2
    exit 4
fi
echo "PASS exact R10 device restored: $FINAL"
REMOTE_RESTORE_DEVICE
    then
        return 1
    fi
    return 0
}

restore_lua() {
    if [ -z "$DEVICE_BACKUP" ]; then
        echo "FAIL R11 Lua rollback path empty" >&2
        return 1
    fi
    if ! ssh "$DEV" 'bash -s' -- "$DEVICE_BACKUP" "$LUA" "$PROFILE" "$EXPECTED_R10_LUA_SHA" <<'REMOTE_RESTORE_LUA'
set -u
BACKUP="$1"
LIVE="$2"
PROFILE="$3"
EXPECTED="$4"
for f in "$BACKUP/visgrid.lua.before-r11" "$BACKUP/profile.lua.before-r11"; do
    if [ ! -s "$f" ]; then echo "FAIL Lua rollback backup missing: $f" >&2; exit 1; fi
done
for f in "$BACKUP/visgrid.lua.before-r11" "$BACKUP/profile.lua.before-r11"; do
    GOT="$(sha256sum "$f" | awk '{print $1}')"
    if [ "$GOT" != "$EXPECTED" ]; then
        echo "FAIL Lua rollback SHA expected=$EXPECTED actual=$GOT file=$f" >&2
        exit 2
    fi
done
install -m 644 "$BACKUP/visgrid.lua.before-r11" "$LIVE" || exit 3
install -m 644 "$BACKUP/profile.lua.before-r11" "$PROFILE" || exit 4
sync
for f in "$LIVE" "$PROFILE"; do
    GOT="$(sha256sum "$f" | awk '{print $1}')"
    if [ "$GOT" != "$EXPECTED" ]; then
        echo "FAIL restored R10 Lua SHA expected=$EXPECTED actual=$GOT file=$f" >&2
        exit 5
    fi
done
echo "PASS exact pre-R11 R10 Lua restored"
REMOTE_RESTORE_LUA
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
        echo "===== R11 FAILURE RECOVERY ====="
        if [ "$LUA_DEPLOYED" -eq 1 ]; then
            echo "INFO: restoring exact pre-R11 R10 Lua..."
            restore_lua || echo "WARNING: automatic R11 Lua rollback failed" >&2
        fi
        if [ "$DEVICE_DEPLOYED" -eq 1 ]; then
            echo "INFO: restoring exact R10 device binary..."
            restore_device || echo "WARNING: automatic R11 device rollback failed" >&2
        fi
        if [ "$SOURCE_MUTATED" -eq 1 ]; then
            echo "INFO: restoring exact R10 Docker source..."
            restore_source || echo "WARNING: automatic R11 source rollback failed" >&2
        fi
    fi
    cleanup
    exit "$rc"
}
trap on_exit EXIT

collect_action() {
    ensure_ssh
    local out="$DL/openmw51-roomwake-r11-validation-$STAMP.txt"

    if ! ssh "$DEV" 'bash -s' -- "$GAMELOG" "$PERF" "$BIN" "$LUA" "$ARM" > "$out" <<'REMOTE_COLLECT'
set -u
LOG="$1"
PERF="$2"
BIN="$3"
LUA="$4"
ARM="$5"

echo "===== OPENMW 0.51 V30 R11-R1 FOUR-RAY FIVE-TIER XY/HEIGHT VALIDATION ====="
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
if [ "$START" -ge "$TOTAL" ]; then
    echo "INFO capture marker exceeds current log; log rotated/truncated, using current tail"
    if [ "$TOTAL" -gt 4000 ]; then START=$((TOTAL-4000)); else START=0; fi
fi
FIRST=$((START+1))

echo "Log lines: total=$TOTAL capture=$FIRST..$TOTAL"
echo
sed -n "${FIRST},${TOTAL}p" "$LOG" 2>/dev/null \
    | grep -E 'Loading cell|Changing to interior|\[TSP_ROOMRAY_R11\]|\[TSP_ROOMOBJ_V30\]|\[TSP_VISGRID_V30_R4\]|\[TSP_ACTOR_V30\]|\[TSP_VISGRID_V11\]|failed to render|Lua.*error' \
    || true

echo
echo "===== PERF TAIL ====="
if [ -f "$PERF" ]; then tail -120 "$PERF" 2>/dev/null || true; fi
REMOTE_COLLECT
    then
        fail 20 "R11 collect failed"
    fi
    echo "Saved: $out"
}

rollback_action() {
    ensure_docker
    ensure_ssh
    if [ ! -s "$STATE" ]; then
        fail 21 "R11 rollback state missing: $STATE"
    fi
    # shellcheck disable=SC1090
    . "$STATE"
    if [ -z "${R11_SOURCE_BACKUP:-}" ] || [ -z "${R11_DEVICE_BACKUP:-}" ]; then
        fail 22 "R11 rollback state incomplete: $STATE"
    fi
    EXPECTED_R10_SHA="${R11_OLD_SHA:-}"
    EXPECTED_R10_LUA_SHA="${R11_OLD_LUA_SHA:-}"
    if ! printf '%s\n' "$EXPECTED_R10_SHA" | grep -Eq '^[0-9a-f]{64}$'; then fail 23 "invalid R11 old binary SHA"; fi
    if ! printf '%s\n' "$EXPECTED_R10_LUA_SHA" | grep -Eq '^[0-9a-f]{64}$'; then fail 24 "invalid R11 old Lua SHA"; fi
    SOURCE_BACKUP="$R11_SOURCE_BACKUP"
    DEVICE_BACKUP="$R11_DEVICE_BACKUP"
    restore_source || fail 25 "manual R11 source rollback failed"
    restore_device || fail 26 "manual R11 device rollback failed"
    restore_lua || fail 27 "manual R11 Lua rollback failed"
    echo "PASS R11 rollback complete; exact R10 binary + R10 Lua restored."
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
OPENMW 0.51 — ROOMWAKE V30 R11-R1
FOUR-RAY / FIVE-TIER XY/HEIGHT ADAPTIVE INTERIOR SAFETY
============================================================
Exactly four rays every 0.20 seconds: left, true center, right, up.
Left/right/up sweep an eight-phase circular offset; center stays fixed.

XY tiers: open 2600/1450, large 2100/1200, medium 1650/950,
          small 1200/700, very-tight 750/450 (light/render).
Z light tiers: tall 512, high 416, medium 336, low 256, very-low 176.

Three forward rays average XY with 65% authority from the longest.
The upward ray averages height independently. Expansion is fast; contraction
is slow. R4 navmesh kind + XY/Z AABB initialize both authorities.
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
echo "===== 1/9 VERIFY EXACT INSTALLED R10 BINARY / LUA / SOURCE SHAPE ====="

LIVE_SHA="$(ssh "$DEV" "sha256sum '$BIN' | awk '{print \$1}'" 2>/dev/null || true)"
if [ "$LIVE_SHA" != "$EXPECTED_R10_SHA" ]; then
    echo "EXPECTED TESTED R10: $EXPECTED_R10_SHA" >&2
    echo "ACTUAL DEVICE:  $LIVE_SHA" >&2
    fail 31 "device is not on the exact tested R10 baseline"
fi
echo "PASS exact tested R10 device SHA: $LIVE_SHA"

if ! ssh "$DEV" "grep -Fq 'TSP_ROOMRAY_LUA_V30_R10_THREE_RANGE' '$LUA' && cmp -s '$LUA' '$PROFILE'"; then
    fail 32 "live/profile Lua is not the exact matching R10 baseline"
fi
LUA_SHA_BEFORE="$(ssh "$DEV" "sha256sum '$LUA' | awk '{print \$1}'" 2>/dev/null || true)"
if [ "$LUA_SHA_BEFORE" != "$EXPECTED_R10_LUA_SHA" ]; then
    echo "EXPECTED TESTED R10 LUA:     $EXPECTED_R10_LUA_SHA" >&2
    echo "ACTUAL LIVE LUA:            $LUA_SHA_BEFORE" >&2
    fail 33 "live Lua differs from the exact tested R10 profile"
fi
echo "PASS exact tested R10 Lua SHA: $LUA_SHA_BEFORE"

if ! docker exec -i "$CTR" python3 - "$SCENE" "$ANIM" "$VIS" "$VISH" "$CAMBIND" <<'PY_PREFLIGHT'
import sys
scene_path, anim_path, vis_path, vish_path, cambind_path = sys.argv[1:6]

def read(p):
    with open(p, 'r', encoding='utf-8', newline='') as f:
        return f.read()

sc, an, vi, vh, cb = map(read, (scene_path, anim_path, vis_path, vish_path, cambind_path))

scene_required = [
    'TSP_ROOM_RENDER_SAFETY_051_V30_R9',
    'TSP_ROOM_ADAPTIVE_RANGE_051_V30_R10',
    'const int tspAdaptiveRangeMode = MWRender::getInteriorAdaptiveRangeMode();',
    'tspAdaptiveRangeMode >= 2 ? 850.f',
    'tspAdaptiveRangeMode == 1 ? 1700.f : 2600.f',
    'tspAdaptiveRangeMode >= 2 ? 450.f',
    'tspAdaptiveRangeMode >= 2 ? 650.f',
    '[TSP_ROOMOBJ_V30] adaptiveRangeMode=" << MWRender::getInteriorAdaptiveRangeMode()',
]
for token in scene_required:
    if token not in sc:
        raise SystemExit('FAIL R10 scene token missing: ' + token)

anim_required = [
    'TSP_ROOM_RENDER_SAFETY_051_V30_R9',
    'const bool tspIsLight = mPtr.getType() == ESM::Light::sRecordId;',
    'const bool tspPvsEligible = false;',
    '!tspDiagActor && !tspDiagDoor && !tspIsStatic && !tspIsLight',
]
for token in anim_required:
    if token not in an:
        raise SystemExit('FAIL R9 animation token missing: ' + token)
if 'mPtr.get<ESM::Static>()' in an:
    raise SystemExit('FAIL unsafe Static LiveCellRef cast exists in animation.cpp')

vis_required = [
    'TSP_ROOM_RENDER_SAFETY_051_V30_R9',
    'TSP_ROOM_OBJECT_FLOOR_AUTHORITY_051_V30',
    'TSP_ROOM_ADAPTIVE_RANGE_051_V30_R10',
    'void InteriorVisibilityCullCallback::operator()(osg::Node* node, osgUtil::CullVisitor* cv)',
    'tspAdaptiveRangeModeStorage()',
    'tspAdaptiveRangeMode >= 2 ? 500.0',
    'tspAdaptiveRangeMode == 1 ? 1000.0 : 1450.0',
    'tspGameplayNearSurface = std::max(0.0, center.length() - radius)',
    'const double nearestSurface=',
]
for token in vis_required:
    if token not in vi:
        raise SystemExit('FAIL R10 visibility token missing: ' + token)

for text, token, label in (
    (vh, 'void setInteriorAdaptiveRangeMode(int mode);', 'R10 range header setter'),
    (vh, 'int getInteriorAdaptiveRangeMode();', 'R10 range header getter'),
    (cb, 'api["setInteriorAdaptiveRangeMode"]', 'R10 camera range setter'),
    (cb, 'api["getInteriorAdaptiveRangeMode"]', 'R10 camera range getter'),
):
    if token not in text:
        raise SystemExit('FAIL missing %s: %s' % (label, token))

for token in ('TSP_ROOM_DUAL_AUTHORITY_051_V30_R11',
              'setInteriorAdaptiveHeightMode', 'getInteriorAdaptiveHeightMode'):
    if any(token in text for text in (sc, an, vi, vh, cb)):
        raise SystemExit('FAIL R11 token already present before patch: ' + token)

for text, token, label in (
    (sc, 'const int tspAdaptiveRangeMode = MWRender::getInteriorAdaptiveRangeMode();',
     'R10 scene range getter'),
    (sc, '[TSP_ROOMOBJ_V30] adaptiveRangeMode=', 'R10 aggregate range log prefix'),
    (vi, 'const int tspAdaptiveRangeMode = getInteriorAdaptiveRangeMode();',
     'R10 visibility range getter'),
    (vh, 'void setInteriorAdaptiveRangeMode(int mode);', 'R10 header setter'),
    (cb, 'api["setInteriorAdaptiveRangeMode"]', 'R10 camera setter'),
):
    count = text.count(token)
    if count != 1:
        raise SystemExit('FAIL %s count=%d expected 1' % (label, count))

print('PASS exact R10 C++ source shape and dual-authority anchors')
PY_PREFLIGHT
then
    fail 34 "source is not the exact expected R10 baseline; no source modified"
fi

echo
echo "===== 2/9 BACK UP FOUR SOURCE FILES + R10 DEVICE + R10 LUA ====="

SOURCE_BACKUP="$SRC/.tsp-051-source-backups/roomwake-v30-r11-four-ray-$STAMP"
if ! docker exec -i "$CTR" bash -s -- "$SOURCE_BACKUP" "$SCENE" "$VIS" "$VISH" "$CAMBIND" <<'REMOTE_BACKUP_SOURCE'
set -u
BACKUP="$1"
SCENE="$2"
VIS="$3"
VISH="$4"
CAMBIND="$5"

if ! mkdir -p "$BACKUP"; then
    echo "FAIL creating source backup: $BACKUP" >&2
    exit 1
fi
if ! cp -f "$SCENE" "$BACKUP/scene.cpp"; then exit 2; fi
if ! cp -f "$VIS" "$BACKUP/interiorvisibility.cpp"; then exit 3; fi
if ! cp -f "$VISH" "$BACKUP/interiorvisibility.hpp"; then exit 4; fi
if ! cp -f "$CAMBIND" "$BACKUP/camerabindings.cpp"; then exit 5; fi
sha256sum "$BACKUP/scene.cpp" "$BACKUP/interiorvisibility.cpp" \
    "$BACKUP/interiorvisibility.hpp" "$BACKUP/camerabindings.cpp"
echo "PASS R11 source backup: $BACKUP"
REMOTE_BACKUP_SOURCE
then
    fail 40 "R11 source backup failed"
fi

DEVICE_BACKUP="$ROOT/backups/roomwake-v30-r11-four-ray-$STAMP"
if ! ssh "$DEV" 'bash -s' -- "$BIN" "$LUA" "$PROFILE" "$DEVICE_BACKUP" "$EXPECTED_R10_SHA" "$EXPECTED_R10_LUA_SHA" <<'REMOTE_BACKUP_DEVICE'
set -u
BIN="$1"
LIVE_LUA="$2"
PROFILE="$3"
BACKUP="$4"
EXPECTED_BIN="$5"
EXPECTED_LUA="$6"

if ! mkdir -p "$BACKUP"; then exit 1; fi
LIVE="$(sha256sum "$BIN" | awk '{print $1}')"
if [ "$LIVE" != "$EXPECTED_BIN" ]; then
    echo "FAIL device changed before backup expected=$EXPECTED_BIN actual=$LIVE" >&2
    exit 2
fi
if ! cp -f "$BIN" "$BACKUP/openmw-0.51.before-r11"; then exit 3; fi
if ! cp -f "$LIVE_LUA" "$BACKUP/visgrid.lua.before-r11"; then exit 4; fi
if ! cp -f "$PROFILE" "$BACKUP/profile.lua.before-r11"; then exit 5; fi
if [ "$(sha256sum "$BACKUP/openmw-0.51.before-r11" | awk '{print $1}')" != "$EXPECTED_BIN" ]; then exit 6; fi
if [ "$(sha256sum "$BACKUP/visgrid.lua.before-r11" | awk '{print $1}')" != "$EXPECTED_LUA" ]; then exit 7; fi
if [ "$(sha256sum "$BACKUP/profile.lua.before-r11" | awk '{print $1}')" != "$EXPECTED_LUA" ]; then exit 8; fi
echo "PASS exact R10 binary + R10 Lua device backup: $BACKUP"
REMOTE_BACKUP_DEVICE
then
    fail 41 "R11 device backup failed"
fi

if ! scp -q "$DEV:$PROFILE" "$TMP/visgrid-r10.lua"; then
    fail 42 "could not pull exact R10 profile for R11 patching"
fi
if [ "$(sha256sum "$TMP/visgrid-r10.lua" | awk '{print $1}')" != "$EXPECTED_R10_LUA_SHA" ]; then
    fail 43 "pulled R10 profile SHA differs from exact tested baseline"
fi

echo
echo "===== 3/9 CREATE + SELFTEST STRUCTURAL R11 C++ PATCHER ====="

cat > "$TMP/patch_r11.py" <<'PY_PATCH'
#!/usr/bin/env python3
import sys

MARK = 'TSP_ROOM_DUAL_AUTHORITY_051_V30_R11'


def read(path):
    with open(path, 'r', encoding='utf-8', newline='') as f:
        return f.read()


def write(path, text):
    with open(path, 'w', encoding='utf-8', newline='\n') as f:
        f.write(text)


def replace_one(text, old, new, label):
    count = text.count(old)
    if count != 1:
        raise RuntimeError('%s count=%d expected 1 token=%r' % (label, count, old))
    return text.replace(old, new, 1)


def line_start(text, pos):
    return text.rfind('\n', 0, pos) + 1


def line_end(text, pos):
    end = text.find('\n', pos)
    return len(text) if end < 0 else end + 1


def indent_at(text, pos):
    start = line_start(text, pos)
    end = line_end(text, pos)
    line = text[start:end]
    return line[:len(line) - len(line.lstrip(' \t'))]


def patch_scene(sc):
    for token in (
        'TSP_ROOM_RENDER_SAFETY_051_V30_R9',
        'TSP_ROOM_ADAPTIVE_RANGE_051_V30_R10',
        'const int tspAdaptiveRangeMode = MWRender::getInteriorAdaptiveRangeMode();',
        'const float tspRoomLightNearXY = tspAdaptiveRangeMode >= 2 ? 850.f',
        'const float tspRoomLightNearZ = tspAdaptiveRangeMode >= 2 ? 192.f',
        'const float tspNearWakeXY = tspAdaptiveRangeMode >= 2 ? 450.f',
        'const float tspNearWakeZ = tspAdaptiveRangeMode >= 2 ? 160.f',
        'const float tspNearHoldXY = tspAdaptiveRangeMode >= 2 ? 650.f',
        'const float tspNearHoldZ = tspAdaptiveRangeMode >= 2 ? 192.f',
    ):
        if token not in sc:
            raise RuntimeError('R10 scene precondition missing: ' + token)
    if MARK in sc:
        raise RuntimeError('R11 scene marker already present')

    # These tokens belong to the lifecycle control flow between the range
    # declarations. Their counts must remain byte-for-byte unchanged.
    protected_counts = {
        token: sc.count(token)
        for token in ('shouldLive', 'toWake', 'toSuppress', 'pvsEnabled')
    }
    if protected_counts['shouldLive'] == 0:
        raise RuntimeError('R10 scene lifecycle sentinel shouldLive is missing')

    # R10 inserted these six declarations at different points in the real
    # lifecycle lambda. They are NOT one contiguous block: shouldLive and
    # light/object control flow sits between them. Replace each declaration
    # independently so no intervening gameplay code can ever be consumed.
    def replace_declaration(text, start_token, end_token, new_lines, label):
        if text.count(start_token) != 1:
            raise RuntimeError('%s start count=%d expected 1'
                               % (label, text.count(start_token)))
        pos = text.index(start_token)
        end_match = text.find(end_token, pos)
        if end_match < 0:
            raise RuntimeError('%s end token missing: %r' % (label, end_token))
        start = line_start(text, pos)
        end = line_end(text, end_match)
        old = text[start:end].rstrip('\n')
        indent = indent_at(text, pos)
        new = '\n'.join(indent + line for line in new_lines)
        return replace_one(text, old, new, label)

    marker = '// TSP_ROOM_ADAPTIVE_RANGE_051_V30_R10 THREE_RANGE_SCENE'
    marker_pos = sc.index(marker)
    head_start = line_start(sc, marker_pos)
    head_end_token = ': (tspAdaptiveRangeMode == 1 ? 1700.f : 2600.f);'
    head_end_match = sc.find(head_end_token, marker_pos)
    if head_end_match < 0:
        raise RuntimeError('R10 light XY declaration end missing')
    head_end = line_end(sc, head_end_match)
    old_head = sc[head_start:head_end].rstrip('\n')
    for token in (marker,
                  'const int tspAdaptiveRangeMode = MWRender::getInteriorAdaptiveRangeMode();',
                  'const float tspRoomLightNearXY = tspAdaptiveRangeMode >= 2 ? 850.f',
                  head_end_token):
        if token not in old_head:
            raise RuntimeError('R10 adaptive scene head token missing: ' + token)
    indent = indent_at(sc, sc.index('const int tspAdaptiveRangeMode', marker_pos))
    new_head = '\n'.join((
        indent + '// ' + MARK + ' FIVE_TIER_XY_HEIGHT_SCENE',
        indent + 'const int tspAdaptiveRangeMode = MWRender::getInteriorAdaptiveRangeMode();',
        indent + 'const int tspAdaptiveHeightMode = MWRender::getInteriorAdaptiveHeightMode();',
        indent + 'const float tspRoomLightNearXY = tspAdaptiveRangeMode >= 4 ? 750.f',
        indent + '    : (tspAdaptiveRangeMode == 3 ? 1200.f',
        indent + '    : (tspAdaptiveRangeMode == 2 ? 1650.f',
        indent + '    : (tspAdaptiveRangeMode == 1 ? 2100.f : 2600.f)));',
    ))
    sc = replace_one(sc, old_head, new_head, 'R10 scene marker/range/light-XY declaration')

    sc = replace_declaration(sc,
        'const float tspRoomLightNearZ = tspAdaptiveRangeMode >= 2 ? 192.f',
        ': (tspAdaptiveRangeMode == 1 ? 256.f : 320.f);',
        (
            'const float tspRoomLightNearZ = tspAdaptiveHeightMode >= 4 ? 176.f',
            '    : (tspAdaptiveHeightMode == 3 ? 256.f',
            '    : (tspAdaptiveHeightMode == 2 ? 336.f',
            '    : (tspAdaptiveHeightMode == 1 ? 416.f : 512.f)));',
        ), 'R10 light Z declaration')
    sc = replace_declaration(sc,
        'const float tspNearWakeXY = tspAdaptiveRangeMode >= 2 ? 450.f',
        ': (tspAdaptiveRangeMode == 1 ? 800.f : 1100.f);',
        (
            'const float tspNearWakeXY = tspAdaptiveRangeMode >= 4 ? 400.f',
            '    : (tspAdaptiveRangeMode == 3 ? 575.f',
            '    : (tspAdaptiveRangeMode == 2 ? 750.f',
            '    : (tspAdaptiveRangeMode == 1 ? 925.f : 1100.f)));',
        ), 'R10 ordinary wake XY declaration')
    sc = replace_declaration(sc,
        'const float tspNearWakeZ = tspAdaptiveRangeMode >= 2 ? 160.f',
        ': (tspAdaptiveRangeMode == 1 ? 256.f : 320.f);',
        (
            'const float tspNearWakeZ = tspAdaptiveHeightMode >= 4 ? 144.f',
            '    : (tspAdaptiveHeightMode == 3 ? 192.f',
            '    : (tspAdaptiveHeightMode == 2 ? 240.f',
            '    : (tspAdaptiveHeightMode == 1 ? 288.f : 336.f)));',
        ), 'R10 ordinary wake Z declaration')
    sc = replace_declaration(sc,
        'const float tspNearHoldXY = tspAdaptiveRangeMode >= 2 ? 650.f',
        ': (tspAdaptiveRangeMode == 1 ? 1050.f : 1450.f);',
        (
            'const float tspNearHoldXY = tspAdaptiveRangeMode >= 4 ? 600.f',
            '    : (tspAdaptiveRangeMode == 3 ? 810.f',
            '    : (tspAdaptiveRangeMode == 2 ? 1025.f',
            '    : (tspAdaptiveRangeMode == 1 ? 1235.f : 1450.f)));',
        ), 'R10 ordinary hold XY declaration')
    sc = replace_declaration(sc,
        'const float tspNearHoldZ = tspAdaptiveRangeMode >= 2 ? 192.f',
        ': (tspAdaptiveRangeMode == 1 ? 320.f : 384.f);',
        (
            'const float tspNearHoldZ = tspAdaptiveHeightMode >= 4 ? 176.f',
            '    : (tspAdaptiveHeightMode == 3 ? 240.f',
            '    : (tspAdaptiveHeightMode == 2 ? 304.f',
            '    : (tspAdaptiveHeightMode == 1 ? 368.f : 432.f)));',
        ), 'R10 ordinary hold Z declaration')

    for token, before in protected_counts.items():
        after = sc.count(token)
        if after != before:
            raise RuntimeError(
                'R11 declaration-only patch changed lifecycle token %s count %d -> %d'
                % (token, before, after))

    old_log = ('[TSP_ROOMOBJ_V30] adaptiveRangeMode="'
               ' << MWRender::getInteriorAdaptiveRangeMode() << "')
    new_log = ('[TSP_ROOMOBJ_V30] adaptiveXYTier="'
               ' << MWRender::getInteriorAdaptiveRangeMode()'
               ' << " adaptiveZTier=" << MWRender::getInteriorAdaptiveHeightMode() << "')
    sc = replace_one(sc, old_log, new_log, 'R10 aggregate range log prefix')

    for token in (
        MARK,
        'tspAdaptiveRangeMode >= 4 ? 750.f',
        'tspAdaptiveRangeMode == 1 ? 2100.f : 2600.f',
        'tspAdaptiveHeightMode >= 4 ? 176.f',
        'tspAdaptiveHeightMode == 1 ? 416.f : 512.f',
        'tspAdaptiveRangeMode >= 4 ? 400.f',
        'tspAdaptiveRangeMode >= 4 ? 600.f',
        '[TSP_ROOMOBJ_V30] adaptiveXYTier=',
        'adaptiveZTier=',
    ):
        if token not in sc:
            raise RuntimeError('R11 scene postcondition missing: ' + token)
    return sc


def patch_header(vh):
    if MARK in vh or 'setInteriorAdaptiveHeightMode' in vh:
        raise RuntimeError('R11 header patch already present')
    marker = '// TSP_ROOM_ADAPTIVE_RANGE_051_V30_R10 LUA_CPP_BRIDGE'
    start = line_start(vh, vh.index(marker))
    getter = 'int getInteriorAdaptiveRangeMode();'
    getter_pos = vh.index(getter, start)
    end = line_end(vh, getter_pos)
    old = vh[start:end].rstrip('\n')
    indent = indent_at(vh, getter_pos)
    for token in (marker, '0=open, 1=tight, 2=very-tight',
                  'void setInteriorAdaptiveRangeMode(int mode);', getter):
        if token not in old:
            raise RuntimeError('R10 header bridge token missing: ' + token)
    new = '\n'.join((
        indent + marker,
        indent + '// ' + MARK + ' FIVE_TIER_XY_HEIGHT_BRIDGE',
        indent + '// Both tiers use 0=largest/open through 4=smallest/tightest.',
        indent + 'void setInteriorAdaptiveRangeMode(int mode);',
        indent + 'int getInteriorAdaptiveRangeMode();',
        indent + 'void setInteriorAdaptiveHeightMode(int mode);',
        indent + 'int getInteriorAdaptiveHeightMode();',
    ))
    return replace_one(vh, old, new, 'bounded R10 header adaptive bridge block')


def patch_visibility(vi):
    for token in (
        'TSP_ROOM_RENDER_SAFETY_051_V30_R9',
        'TSP_ROOM_ADAPTIVE_RANGE_051_V30_R10',
        'tspAdaptiveRangeModeStorage()',
        'tspAdaptiveRangeMode >= 2 ? 500.0',
        'tspGameplayNearSurface = std::max(0.0, center.length() - radius)',
    ):
        if token not in vi:
            raise RuntimeError('R10 visibility precondition missing: ' + token)
    if MARK in vi or 'tspAdaptiveHeightModeStorage' in vi:
        raise RuntimeError('R11 visibility patch already present')

    old_bridge = '''    // TSP_ROOM_ADAPTIVE_RANGE_051_V30_R10 LUA_CPP_BRIDGE
    namespace
    {
        std::atomic<int>& tspAdaptiveRangeModeStorage()
        {
            static std::atomic<int> mode{ 0 };
            return mode;
        }
    }

    void setInteriorAdaptiveRangeMode(int mode)
    {
        if (mode < 0)
            mode = 0;
        else if (mode > 2)
            mode = 2;
        tspAdaptiveRangeModeStorage().store(mode, std::memory_order_relaxed);
    }

    int getInteriorAdaptiveRangeMode()
    {
        return tspAdaptiveRangeModeStorage().load(std::memory_order_relaxed);
    }
'''
    new_bridge = '''    // TSP_ROOM_ADAPTIVE_RANGE_051_V30_R10 LUA_CPP_BRIDGE
    // TSP_ROOM_DUAL_AUTHORITY_051_V30_R11 FIVE_TIER_XY_HEIGHT_BRIDGE
    namespace
    {
        std::atomic<int>& tspAdaptiveRangeModeStorage()
        {
            static std::atomic<int> mode{ 0 };
            return mode;
        }

        std::atomic<int>& tspAdaptiveHeightModeStorage()
        {
            static std::atomic<int> mode{ 0 };
            return mode;
        }
    }

    void setInteriorAdaptiveRangeMode(int mode)
    {
        if (mode < 0)
            mode = 0;
        else if (mode > 4)
            mode = 4;
        tspAdaptiveRangeModeStorage().store(mode, std::memory_order_relaxed);
    }

    int getInteriorAdaptiveRangeMode()
    {
        return tspAdaptiveRangeModeStorage().load(std::memory_order_relaxed);
    }

    void setInteriorAdaptiveHeightMode(int mode)
    {
        if (mode < 0)
            mode = 0;
        else if (mode > 4)
            mode = 4;
        tspAdaptiveHeightModeStorage().store(mode, std::memory_order_relaxed);
    }

    int getInteriorAdaptiveHeightMode()
    {
        return tspAdaptiveHeightModeStorage().load(std::memory_order_relaxed);
    }
'''
    vi = replace_one(vi, old_bridge, new_bridge, 'R10 visibility bridge block')

    old_render = '''// TSP_ROOM_ADAPTIVE_RANGE_051_V30_R10 THREE_RANGE_RENDER
        const int tspAdaptiveRangeMode = getInteriorAdaptiveRangeMode();
        const double tspGameplayCullBypass = tspAdaptiveRangeMode >= 2 ? 500.0
            : (tspAdaptiveRangeMode == 1 ? 1000.0 : 1450.0);'''
    pos = vi.index('// TSP_ROOM_ADAPTIVE_RANGE_051_V30_R10 THREE_RANGE_RENDER')
    indent = indent_at(vi, pos)
    old_lines = old_render.splitlines()
    old_live = '\n'.join(indent + line.lstrip() if i == 0 else indent + line[8:]
                         for i, line in enumerate(old_lines))
    new_render = '\n'.join((
        indent + '// ' + MARK + ' FIVE_TIER_XY_HEIGHT_RENDER',
        indent + 'const int tspAdaptiveRangeMode = getInteriorAdaptiveRangeMode();',
        indent + 'const double tspGameplayCullBypass = tspAdaptiveRangeMode >= 4 ? 450.0',
        indent + '    : (tspAdaptiveRangeMode == 3 ? 700.0',
        indent + '    : (tspAdaptiveRangeMode == 2 ? 950.0',
        indent + '    : (tspAdaptiveRangeMode == 1 ? 1200.0 : 1450.0)));',
    ))
    vi = replace_one(vi, old_live, new_render, 'R10 three-range render block')

    for token in (
        MARK,
        'setInteriorAdaptiveRangeMode(int mode)',
        'getInteriorAdaptiveRangeMode()',
        'setInteriorAdaptiveHeightMode(int mode)',
        'getInteriorAdaptiveHeightMode()',
        'tspAdaptiveRangeMode >= 4 ? 450.0',
        'tspAdaptiveRangeMode == 1 ? 1200.0 : 1450.0',
        'const double nearestSurface=',
    ):
        if token not in vi:
            raise RuntimeError('R11 visibility postcondition missing: ' + token)
    return vi


def patch_camera_binding(cb):
    for token in ('api["setInteriorAdaptiveRangeMode"]',
                  'api["getInteriorAdaptiveRangeMode"]'):
        if token not in cb:
            raise RuntimeError('camera binding precondition missing: ' + token)
    if MARK in cb or 'setInteriorAdaptiveHeightMode' in cb:
        raise RuntimeError('R11 camera binding already present')

    old = '''// TSP_ROOM_ADAPTIVE_RANGE_051_V30_R10 LUA_CPP_BRIDGE
        api["setInteriorAdaptiveRangeMode"] = [](int mode) {
            MWRender::setInteriorAdaptiveRangeMode(mode);
        };
        api["getInteriorAdaptiveRangeMode"] = []() {
            return MWRender::getInteriorAdaptiveRangeMode();
        };'''
    pos = cb.index('// TSP_ROOM_ADAPTIVE_RANGE_051_V30_R10 LUA_CPP_BRIDGE')
    indent = indent_at(cb, pos)
    old_lines = old.splitlines()
    old_live = '\n'.join(indent + line.lstrip() if i == 0 else indent + line[8:]
                         for i, line in enumerate(old_lines))
    new = '\n'.join((
        indent + '// TSP_ROOM_ADAPTIVE_RANGE_051_V30_R10 LUA_CPP_BRIDGE',
        indent + '// ' + MARK + ' FIVE_TIER_XY_HEIGHT_BRIDGE',
        indent + 'api["setInteriorAdaptiveRangeMode"] = [](int mode) {',
        indent + '    MWRender::setInteriorAdaptiveRangeMode(mode);',
        indent + '};',
        indent + 'api["getInteriorAdaptiveRangeMode"] = []() {',
        indent + '    return MWRender::getInteriorAdaptiveRangeMode();',
        indent + '};',
        indent + 'api["setInteriorAdaptiveHeightMode"] = [](int mode) {',
        indent + '    MWRender::setInteriorAdaptiveHeightMode(mode);',
        indent + '};',
        indent + 'api["getInteriorAdaptiveHeightMode"] = []() {',
        indent + '    return MWRender::getInteriorAdaptiveHeightMode();',
        indent + '};',
    ))
    return replace_one(cb, old_live, new, 'R10 camera adaptive bridge block')


def patch_all(sc, vi, vh, cb):
    return patch_scene(sc), patch_visibility(vi), patch_header(vh), patch_camera_binding(cb)


def sample_scene():
    return '''namespace MWRender
{
    int getInteriorAdaptiveRangeMode();
    int getInteriorAdaptiveHeightMode();
}
struct DummyLog
{
    template <class T> DummyLog& operator<<(const T&) { return *this; }
};
DummyLog Log();
// TSP_ROOM_RENDER_SAFETY_051_V30_R9
void f()
{
    {
                // TSP_ROOM_ADAPTIVE_RANGE_051_V30_R10 THREE_RANGE_SCENE
        const int tspAdaptiveRangeMode = MWRender::getInteriorAdaptiveRangeMode();
        const float tspRoomLightNearXY = tspAdaptiveRangeMode >= 2 ? 850.f
            : (tspAdaptiveRangeMode == 1 ? 1700.f : 2600.f);
        const float tspRoomLightNearZ = tspAdaptiveRangeMode >= 2 ? 192.f
            : (tspAdaptiveRangeMode == 1 ? 256.f : 320.f);
        bool shouldLive = tspRoomLightNearXY > 0.f && tspRoomLightNearZ > 0.f;
        const int tspR11LifecycleSentinel = 7;
        const float tspNearWakeXY = tspAdaptiveRangeMode >= 2 ? 450.f
            : (tspAdaptiveRangeMode == 1 ? 800.f : 1100.f);
        const float tspNearWakeZ = tspAdaptiveRangeMode >= 2 ? 160.f
            : (tspAdaptiveRangeMode == 1 ? 256.f : 320.f);
        const float tspNearHoldXY = tspAdaptiveRangeMode >= 2 ? 650.f
            : (tspAdaptiveRangeMode == 1 ? 1050.f : 1450.f);
        const float tspNearHoldZ = tspAdaptiveRangeMode >= 2 ? 192.f
            : (tspAdaptiveRangeMode == 1 ? 320.f : 384.f);
        shouldLive = shouldLive || tspNearWakeXY > 0.f || tspNearWakeZ > 0.f
            || tspNearHoldXY > 0.f || tspNearHoldZ > 0.f;
        if (shouldLive)
            Log() << tspR11LifecycleSentinel;
    }
    Log() << "[TSP_ROOMOBJ_V30] adaptiveRangeMode=" << MWRender::getInteriorAdaptiveRangeMode() << " ordinaryWakeXY=1100 ordinaryHoldXY=1450";
    Log() << "[TSP_ROOMOBJ_V30] unload-purge parked=0";
}
'''


def sample_visibility():
    return '''#include <atomic>
namespace MWRender
{
// TSP_ROOM_RENDER_SAFETY_051_V30_R9
    // TSP_ROOM_ADAPTIVE_RANGE_051_V30_R10 LUA_CPP_BRIDGE
    namespace
    {
        std::atomic<int>& tspAdaptiveRangeModeStorage()
        {
            static std::atomic<int> mode{ 0 };
            return mode;
        }
    }

    void setInteriorAdaptiveRangeMode(int mode)
    {
        if (mode < 0)
            mode = 0;
        else if (mode > 2)
            mode = 2;
        tspAdaptiveRangeModeStorage().store(mode, std::memory_order_relaxed);
    }

    int getInteriorAdaptiveRangeMode()
    {
        return tspAdaptiveRangeModeStorage().load(std::memory_order_relaxed);
    }

void f()
{
    // TSP_ROOM_ADAPTIVE_RANGE_051_V30_R10 THREE_RANGE_RENDER
    const int tspAdaptiveRangeMode = getInteriorAdaptiveRangeMode();
    const double tspGameplayCullBypass = tspAdaptiveRangeMode >= 2 ? 500.0
        : (tspAdaptiveRangeMode == 1 ? 1000.0 : 1450.0);
    const double tspGameplayNearSurface = std::max(0.0, center.length() - radius);
    const double nearestSurface=5.0;
}
}
'''


def sample_header():
    return '''namespace MWRender
{
    bool isInteriorTopologyPvsEnabled();

    // TSP_ROOM_ADAPTIVE_RANGE_051_V30_R10 LUA_CPP_BRIDGE
    // 0=open, 1=tight, 2=very-tight. Setter clamps invalid input.
    void setInteriorAdaptiveRangeMode(int mode);
    int getInteriorAdaptiveRangeMode();
}
'''


def sample_binding():
    return '''void init()
{
    api["setInteriorTopologyPvs"] = []() {};
    // TSP_ROOM_ADAPTIVE_RANGE_051_V30_R10 LUA_CPP_BRIDGE
    api["setInteriorAdaptiveRangeMode"] = [](int mode) {
        MWRender::setInteriorAdaptiveRangeMode(mode);
    };
    api["getInteriorAdaptiveRangeMode"] = []() {
        return MWRender::getInteriorAdaptiveRangeMode();
    };
    api["clearInteriorTopologyPvs"] = []() {};
}
'''


def selftest():
    sc, vi, vh, cb = patch_all(sample_scene(), sample_visibility(), sample_header(), sample_binding())
    assert '750.f' in sc and '2100.f : 2600.f' in sc
    assert '512.f' in sc and '416.f : 512.f' in sc
    assert '400.f' in sc and '600.f' in sc
    assert 'bool shouldLive = tspRoomLightNearXY > 0.f' in sc
    assert 'const int tspR11LifecycleSentinel = 7;' in sc
    assert 'Log() << tspR11LifecycleSentinel;' in sc
    assert '450.0' in vi and '1200.0 : 1450.0' in vi
    assert 'void setInteriorAdaptiveHeightMode(int mode);' in vh
    assert 'api["setInteriorAdaptiveHeightMode"]' in cb
    assert all(text.count(MARK) >= 1 for text in (sc, vi, vh, cb))
    # R11 replaces the R10 THREE_RANGE_SCENE block and its marker. The R10
    # bridge marker remains in interiorvisibility.cpp for API lineage. Keep
    # these assertions synchronized with the real post-patch verifier below.
    assert 'TSP_ROOM_ADAPTIVE_RANGE_051_V30_R10' not in sc
    assert 'TSP_ROOM_ADAPTIVE_RANGE_051_V30_R10' in vi
    assert '[TSP_ROOMOBJ_V30] adaptiveRangeMode=' not in sc
    assert '[TSP_ROOMOBJ_V30] adaptiveXYTier=" << MWRender::getInteriorAdaptiveRangeMode()' in sc
    assert 'adaptiveZTier=" << MWRender::getInteriorAdaptiveHeightMode()' in sc
    assert 'ordinaryWakeXY=1100 ordinaryHoldXY=1450' in sc
    aggregate_lines = [
        line for line in sc.splitlines()
        if '[TSP_ROOMOBJ_V30] adaptiveXYTier=' in line
    ]
    assert len(aggregate_lines) == 1
    assert sum('[TSP_ROOMOBJ_V30]' in line for line in sc.splitlines()) == 2
    log_line = aggregate_lines[0]
    assert '<< tspAdaptiveRangeMode' not in log_line
    assert '<< tspAdaptiveHeightMode' not in log_line
    assert '<< tspRoomLightNearXY' not in log_line
    assert '<< tspRoomLightNearZ' not in log_line
    print('PASS R11 C++ patcher selftest: five XY tiers + independent five Z tiers')


if len(sys.argv) == 2 and sys.argv[1] == '--selftest':
    selftest()
    raise SystemExit(0)
if len(sys.argv) == 3 and sys.argv[1] == '--emit-scene-selftest':
    write(sys.argv[2], patch_scene(sample_scene()))
    print('PASS emitted scope-accurate transformed scene fixture: ' + sys.argv[2])
    raise SystemExit(0)
if len(sys.argv) != 5:
    raise SystemExit('usage: patch_r11.py SCENE_CPP INTERIORVIS_CPP INTERIORVIS_HPP CAMERABIND_CPP | --selftest | --emit-scene-selftest PATH')

scene_path, vis_path, vish_path, cambind_path = sys.argv[1:5]
sc, vi, vh, cb = patch_all(read(scene_path), read(vis_path), read(vish_path), read(cambind_path))
write(scene_path, sc)
write(vis_path, vi)
write(vish_path, vh)
write(cambind_path, cb)
print('PASS R11 four-file C++ source patch applied')
PY_PATCH

if ! python3 -m py_compile "$TMP/patch_r11.py"; then
    fail 44 "embedded R11 C++ Python patcher does not compile"
fi
if ! python3 "$TMP/patch_r11.py" --selftest; then
    fail 45 "R11 C++ patcher selftest failed"
fi
if ! python3 "$TMP/patch_r11.py" --emit-scene-selftest "$TMP/r11-scene-scope-selftest.cpp"; then
    fail 73 "could not emit scope-accurate R11 C++ fixture"
fi
if ! docker cp "$TMP/r11-scene-scope-selftest.cpp" "$CTR:/tmp/r11-scene-scope-selftest.cpp" >/dev/null; then
    fail 74 "could not stage scope-accurate R11 C++ fixture"
fi
if ! docker exec "$CTR" bash -lc '
    CXX=""
    for candidate in g++-13 g++ c++; do
        if command -v "$candidate" >/dev/null 2>&1; then CXX="$candidate"; break; fi
    done
    if [ -z "$CXX" ]; then echo "FAIL no C++ compiler for R11 fixture" >&2; exit 1; fi
    "$CXX" -std=c++20 -fsyntax-only /tmp/r11-scene-scope-selftest.cpp
'; then
    fail 75 "scope-accurate transformed R11 scene fixture does not compile"
fi
echo "PASS R11 C++ patcher validated structurally and with scope-accurate compiler test"

echo
cat > "$TMP/patch_r11_lua.py" <<'PY_LUA'
#!/usr/bin/env python3
import re
import sys

MARK = 'TSP_ROOMRAY_LUA_V30_R11_FIVE_TIER_XY_HEIGHT'


def read(path):
    with open(path, 'r', encoding='utf-8', newline='') as f:
        return f.read()


def write(path, text):
    with open(path, 'w', encoding='utf-8', newline='\n') as f:
        f.write(text)


def patch_lua(src):
    for token in (
        'TSP_VISGRID_LUA_V30_R4_SAME_FLOOR_PROXIMITY',
        'TSP_ROOMRAY_LUA_V30_R10_THREE_RANGE',
        'camera.viewportToWorldVector',
        'nearby.castRay',
        'RAY_MASK',
        'mapState.updateTopologyPvs',
        'mapState.r10BaseOnFrame =',
        'mapState.r10OnFrame',
        'setInteriorAdaptiveRangeMode',
        'engineHandlers',
    ):
        if token not in src:
            raise RuntimeError('R10 Lua precondition missing: ' + token)
    if MARK in src or 'setInteriorAdaptiveHeightMode' in src:
        raise RuntimeError('R11 Lua already present')

    r10_marker = '-- TSP_ROOMRAY_LUA_V30_R10_THREE_RANGE'
    if src.count(r10_marker) != 1:
        raise RuntimeError('R10 Lua block marker count=%d expected 1'
                           % src.count(r10_marker))
    r10_start = src.index(r10_marker)
    base_match = re.search(
        r'(?m)^mapState\.r10BaseOnFrame[ \t]*=[ \t]*'
        r'(?P<base>mapState\.[A-Za-z_][A-Za-z0-9_]*)[ \t]*$',
        src[r10_start:])
    if base_match is None:
        raise RuntimeError('R10 base callback assignment not found')
    r10_base = base_match.group('base')

    engine_field_pattern = re.compile(
        r'(?m)^[ \t]*engineHandlers[ \t]*=[ \t]*\{[ \t]*$')
    engine_fields = list(engine_field_pattern.finditer(src))
    if len(engine_fields) != 1:
        raise RuntimeError('R10 engineHandlers field count=%d expected 1'
                           % len(engine_fields))
    return_pattern = re.compile(r'(?m)^return[ \t]*\{[ \t]*$')
    returns = [m for m in return_pattern.finditer(src)
               if r10_start < m.start() < engine_fields[0].start()]
    if len(returns) != 1:
        raise RuntimeError('R10 top-level return after adaptive block count=%d expected 1'
                           % len(returns))
    r10_end = returns[0].start()
    src = src[:r10_start] + src[r10_end:]

    old_handler_base = 'mapState.r10OnFrame'
    if src.count(old_handler_base) != 1:
        raise RuntimeError('R10 onFrame handler callback count=%d expected 1'
                           % src.count(old_handler_base))
    src = src.replace(old_handler_base, r10_base, 1)

    handler_pattern = re.compile(
        r"(?m)^(?P<indent>[ \t]*)onFrame[ \t]*=[ \t]*function[ \t]*"
        r"\([ \t]*dt[ \t]*\)[ \t]*guarded[ \t]*\([ \t]*"
        r"[\"']onFrame[\"'][ \t]*,[ \t]*"
        r"(?P<base>mapState\.[A-Za-z_][A-Za-z0-9_]*)[ \t]*,[ \t]*dt[ \t]*"
        r"\)[ \t]*end[ \t]*,?[ \t]*$"
    )
    matches = list(handler_pattern.finditer(src))
    if len(matches) != 1:
        candidates = [line for line in src.splitlines()
                      if 'onFrame' in line and 'guarded' in line]
        raise RuntimeError('R4 onFrame handler matches=%d expected 1 candidates=%r'
                           % (len(matches), candidates[-20:]))
    handler = matches[0]
    base = handler.group('base')
    indent = handler.group('indent')

    # R10 still returns engineHandlers as a field of its final module table:
    #     return {
    #         engineHandlers = {
    # Anchor the replacement before the unique top-level return table.
    engine_field_pattern = re.compile(
        r'(?m)^[ \t]*engineHandlers[ \t]*=[ \t]*\{[ \t]*$')
    engine_fields = list(engine_field_pattern.finditer(src))
    if len(engine_fields) != 1:
        candidates = [line for line in src.splitlines() if 'engineHandlers' in line]
        raise RuntimeError('R4 engineHandlers field matches=%d expected 1 candidates=%r'
                           % (len(engine_fields), candidates[-20:]))

    return_pattern = re.compile(r'(?m)^return[ \t]*\{[ \t]*$')
    returns = [m for m in return_pattern.finditer(src)
               if m.start() < engine_fields[0].start()]
    if len(returns) != 1:
        candidates = [line for line in src.splitlines()
                      if line.lstrip().startswith('return {')]
        raise RuntimeError('R4 top-level return anchor matches=%d expected 1 candidates=%r'
                           % (len(returns), candidates[-20:]))

    block = r'''-- TSP_ROOMRAY_LUA_V30_R11_FIVE_TIER_XY_HEIGHT
-- Four casts per 0.20-second sample. Center is fixed; left/right/up sweep an
-- eight-phase ring. Three forward rays drive a five-tier XY authority; the
-- upward ray independently drives a five-tier Z authority. Both start from
-- R4 navmesh kind/AABB priors. Long/open evidence expands rapidly while
-- sustained small evidence contracts slowly. EMA history becomes negligible
-- after movement and is wiped completely on cell/topology changes.
mapState.r11BaseOnFrame = BASE_CALLBACK
mapState.r11RayElapsed = 0.0
mapState.r11ReportElapsed = 0.0
mapState.r11RayPhase = 1
mapState.r11XYTier = -1
mapState.r11ZTier = -1
mapState.r11XYScore = 3.0
mapState.r11ZScore = 2.5
mapState.r11SampleCount = 0
mapState.r11WeightedXY = 2400.0
mapState.r11UpDepth = 2400.0
mapState.r11TopoXYPrior = 3.0
mapState.r11TopoZPrior = 2.5
mapState.r11TopoKind = 'unknown'
mapState.r11TopoXYSpan = 0.0
mapState.r11TopoZSpan = 0.0
mapState.r11LastCell = nil
mapState.r11LastTopoCell = nil
mapState.r11BridgeErrorPrinted = false
mapState.r11RayPeriod = 0.20
mapState.r11ReportPeriod = 2.0
mapState.r11RayLength = 2400.0
mapState.r11SweepRadius = 0.065
mapState.r11Phases = {
    { 1.0000,  0.0000 }, { 0.7071,  0.7071 },
    { 0.0000,  1.0000 }, {-0.7071,  0.7071 },
    {-1.0000,  0.0000 }, {-0.7071, -0.7071 },
    { 0.0000, -1.0000 }, { 0.7071, -0.7071 },
}

mapState.r11Clamp = function(value, low, high)
    return math.max(low, math.min(high, tonumber(value or low) or low))
end

mapState.r11TierName = function(tier)
    tier = math.floor(mapState.r11Clamp(tier, 0, 4) + 0.5)
    local names = {'open', 'large', 'medium', 'small', 'very-tight'}
    return names[tier + 1] or 'open'
end

mapState.r11ScoreToTier = function(score)
    return math.floor(mapState.r11Clamp(4.5 - score, 0.0, 4.0))
end

mapState.r11SetTiers = function(xyTier, zTier, reason, distances)
    xyTier = math.floor(mapState.r11Clamp(xyTier, 0, 4) + 0.5)
    zTier = math.floor(mapState.r11Clamp(zTier, 0, 4) + 0.5)
    if camera.setInteriorAdaptiveRangeMode == nil
        or camera.setInteriorAdaptiveHeightMode == nil then
        if not mapState.r11BridgeErrorPrinted then
            mapState.r11BridgeErrorPrinted = true
            print('[TSP_ROOMRAY_R11] BRIDGE ERROR dual adaptive setters unavailable')
        end
        return
    end
    if xyTier == mapState.r11XYTier and zTier == mapState.r11ZTier then return end
    local okXY, errXY = pcall(camera.setInteriorAdaptiveRangeMode, xyTier)
    local okZ, errZ = pcall(camera.setInteriorAdaptiveHeightMode, zTier)
    if not okXY or not okZ then
        if not mapState.r11BridgeErrorPrinted then
            mapState.r11BridgeErrorPrinted = true
            print('[TSP_ROOMRAY_R11] BRIDGE ERROR XY=' .. tostring(errXY)
                .. ' Z=' .. tostring(errZ))
        end
        return
    end
    mapState.r11XYTier = xyTier
    mapState.r11ZTier = zTier
    local detail = distances and string.format(' L=%.0f C=%.0f R=%.0f U=%.0f',
        distances[1] or -1, distances[2] or -1,
        distances[3] or -1, distances[4] or -1) or ''
    print(string.format(
        '[TSP_ROOMRAY_R11] tier-change XY=%d/%s Z=%d/%s reason=%s xyScore=%.2f zScore=%.2f topo=%s%s',
        xyTier, mapState.r11TierName(xyTier), zTier, mapState.r11TierName(zTier),
        tostring(reason or '?'),
        tonumber(mapState.r11XYScore or 0) or 0,
        tonumber(mapState.r11ZScore or 0) or 0,
        tostring(mapState.r11TopoKind or '?'),
        detail))
end

mapState.r11TopologyPrior = function()
    local tc = mapState.topoCell
    local sectors = tc and tc.sectors or nil
    local current = tonumber(mapState.topoSectorId or 0) or 0
    local sec = sectors and current > 0 and sectors[current] or nil
    if sec == nil then return 3.0, 2.5, 'unmapped', 0.0, 0.0 end

    local kind = tostring(sec.kind or 'room')
    local b = sec.bbox
    local xySpan = 0.0
    local zSpan = 0.0
    if b ~= nil and #b >= 6 then
        local sx = math.max(0.0, (tonumber(b[4] or 0) or 0) - (tonumber(b[1] or 0) or 0))
        local sy = math.max(0.0, (tonumber(b[5] or 0) or 0) - (tonumber(b[2] or 0) or 0))
        xySpan = math.max(sx, sy)
        zSpan = math.max(0.0, (tonumber(b[6] or 0) or 0) - (tonumber(b[3] or 0) or 0))
    end

    local xyPrior = 2.2
    local zPrior = 2.0
    if kind == 'large_open' then
        xyPrior = 4.0
        zPrior = 3.5
    elseif kind == 'corridor' then
        xyPrior = 1.6
        zPrior = 1.8
    elseif kind == 'small_room' then
        xyPrior = 0.8
        zPrior = 1.2
    elseif kind == 'vertical_connector' then
        xyPrior = 2.6
        zPrior = 4.0
    elseif xySpan >= 2200.0 then
        xyPrior = 3.8
    elseif xySpan >= 1600.0 then
        xyPrior = 3.0
    elseif xySpan >= 1000.0 then
        xyPrior = 2.0
    elseif xySpan > 0.0 then
        xyPrior = 1.0
    end

    -- Navmesh Z span mostly describes walkable-floor variation, not the
    -- ceiling, so it is only a weak reset prior. The upward ray rapidly owns
    -- the live height decision after the reset.
    if kind ~= 'vertical_connector' and kind ~= 'large_open' then
        if zSpan >= 1200.0 then zPrior = 3.5
        elseif zSpan >= 700.0 then zPrior = 2.8
        elseif zSpan >= 350.0 then zPrior = 2.2 end
    end

    local active = tonumber(mapState.pvsActiveCount or 0) or 0
    if active >= 4 then xyPrior = math.min(4.0, xyPrior + 0.25) end
    return xyPrior, zPrior, kind, xySpan, zSpan
end

mapState.r11ResetAuthority = function(reason)
    local xyPrior, zPrior, kind, xySpan, zSpan = mapState.r11TopologyPrior()
    mapState.r11TopoXYPrior = xyPrior
    mapState.r11TopoZPrior = zPrior
    mapState.r11TopoKind = kind
    mapState.r11TopoXYSpan = xySpan
    mapState.r11TopoZSpan = zSpan
    mapState.r11XYScore = xyPrior
    mapState.r11ZScore = zPrior
    mapState.r11SampleCount = 0
    mapState.r11ReportElapsed = 0.0
    local xyTier = mapState.r11ScoreToTier(xyPrior)
    local zTier = mapState.r11ScoreToTier(zPrior)
    mapState.r11SetTiers(xyTier, zTier,
        'authority-reset-' .. tostring(reason or '?'), nil)
    print(string.format(
        '[TSP_ROOMRAY_R11] authority-reset reason=%s XY=%d/%s Z=%d/%s topo=%s prior=%.2f/%.2f span=%.0f/%.0f active=%d',
        tostring(reason or '?'), xyTier, mapState.r11TierName(xyTier),
        zTier, mapState.r11TierName(zTier), kind, xyPrior, zPrior, xySpan, zSpan,
        tonumber(mapState.pvsActiveCount or 0) or 0))
end

mapState.r11CastDirection = function(eye, u, v)
    local okDir, dir = pcall(camera.viewportToWorldVector, util.vector2(u, v))
    if not okDir or dir == nil then return nil end
    local okLen, len = pcall(function() return dir:length() end)
    if not okLen or len == nil or len <= 0.0001 then return nil end
    local dest = eye + (dir / len) * mapState.r11RayLength
    local okRay, result = pcall(nearby.castRay, eye, dest, { collisionType = RAY_MASK })
    if not okRay or result == nil then return nil end
    if result.hit and result.hitPos ~= nil then
        local okDist, distance = pcall(function() return (result.hitPos - eye):length() end)
        if okDist and distance ~= nil then return distance end
        return nil
    end
    -- A clean miss is an OPEN witness, not an API failure.
    return mapState.r11RayLength
end

mapState.r11SampleFour = function()
    local eye = camera.getPosition()
    if eye == nil then return nil end
    eye = eye + util.vector3(0, 0, 16.0)
    local phase = mapState.r11Phases[mapState.r11RayPhase] or {1.0, 0.0}
    mapState.r11RayPhase = mapState.r11RayPhase % #mapState.r11Phases + 1
    local dx = phase[1] * mapState.r11SweepRadius
    local dy = phase[2] * mapState.r11SweepRadius
    -- Exactly four calls. The true center sample never rotates away from a door.
    local distances = {
        mapState.r11CastDirection(eye, 0.28 + dx, 0.50 + dy),
        mapState.r11CastDirection(eye, 0.50,      0.50),
        mapState.r11CastDirection(eye, 0.72 - dx, 0.50 - dy),
        mapState.r11CastDirection(eye, 0.50 + dy, 0.24 + dx),
    }
    for i = 1, 4 do
        if distances[i] == nil then return nil end
    end
    return distances
end

mapState.r11XYTarget = function(depth)
    depth = mapState.r11Clamp(depth, 0.0, mapState.r11RayLength)
    if depth <= 500.0 then return 0.0 end
    if depth <= 800.0 then return (depth - 500.0) / 300.0 end
    if depth <= 1200.0 then return 1.0 + (depth - 800.0) / 400.0 end
    if depth <= 1700.0 then return 2.0 + (depth - 1200.0) / 500.0 end
    return math.min(4.0, 3.0 + (depth - 1700.0) / 700.0)
end

mapState.r11ZTarget = function(depth)
    depth = mapState.r11Clamp(depth, 0.0, mapState.r11RayLength)
    if depth <= 400.0 then return 0.0 end
    if depth <= 700.0 then return (depth - 400.0) / 300.0 end
    if depth <= 1000.0 then return 1.0 + (depth - 700.0) / 300.0 end
    if depth <= 1500.0 then return 2.0 + (depth - 1000.0) / 500.0 end
    return math.min(4.0, 3.0 + (depth - 1500.0) / 900.0)
end

mapState.r11BlendAuthority = function(current, target, prior, strongOpen)
    local alpha = 0.055
    if target > current then alpha = strongOpen and 0.62 or 0.42 end
    local value = current + (target - current) * alpha
    value = value + (prior - value) * 0.008
    return mapState.r11Clamp(value, 0.0, 4.0)
end

mapState.r11AuthorityReport = function(distances)
    local detail = distances and string.format(' L=%.0f C=%.0f R=%.0f U=%.0f',
        distances[1] or -1, distances[2] or -1,
        distances[3] or -1, distances[4] or -1) or ''
    print(string.format(
        '[TSP_ROOMRAY_R11] authority XY=%d/%s Z=%d/%s score=%.2f/%.2f depth=%.0f/%.0f topo=%s prior=%.2f/%.2f span=%.0f/%.0f active=%d samples=%d%s',
        tonumber(mapState.r11XYTier or 0) or 0,
        mapState.r11TierName(mapState.r11XYTier),
        tonumber(mapState.r11ZTier or 0) or 0,
        mapState.r11TierName(mapState.r11ZTier),
        tonumber(mapState.r11XYScore or 0) or 0,
        tonumber(mapState.r11ZScore or 0) or 0,
        tonumber(mapState.r11WeightedXY or 0) or 0,
        tonumber(mapState.r11UpDepth or 0) or 0,
        tostring(mapState.r11TopoKind or '?'),
        tonumber(mapState.r11TopoXYPrior or 0) or 0,
        tonumber(mapState.r11TopoZPrior or 0) or 0,
        tonumber(mapState.r11TopoXYSpan or 0) or 0,
        tonumber(mapState.r11TopoZSpan or 0) or 0,
        tonumber(mapState.pvsActiveCount or 0) or 0,
        tonumber(mapState.r11SampleCount or 0) or 0, detail))
end

mapState.r11Classify = function(distances)
    if distances == nil then
        -- An API/direction failure is not geometric evidence. Fail fully open.
        mapState.r11XYScore = 4.0
        mapState.r11ZScore = 4.0
        mapState.r11SetTiers(0, 0, 'ray-api-failure', nil)
        return
    end

    local ordered = { distances[1], distances[2], distances[3] }
    table.sort(ordered)
    local weighted = ordered[1] * 0.10 + ordered[2] * 0.25 + ordered[3] * 0.65
    local up = distances[4]
    mapState.r11WeightedXY = weighted
    mapState.r11UpDepth = up
    mapState.r11SampleCount = mapState.r11SampleCount + 1

    local xyPrior, zPrior, kind, xySpan, zSpan = mapState.r11TopologyPrior()
    mapState.r11TopoXYPrior = xyPrior
    mapState.r11TopoZPrior = zPrior
    mapState.r11TopoKind = kind
    mapState.r11TopoXYSpan = xySpan
    mapState.r11TopoZSpan = zSpan

    local xyTarget = mapState.r11XYTarget(weighted)
    local zTarget = mapState.r11ZTarget(up)
    mapState.r11XYScore = mapState.r11BlendAuthority(
        mapState.r11XYScore, xyTarget, xyPrior, ordered[3] >= 1800.0)
    mapState.r11ZScore = mapState.r11BlendAuthority(
        mapState.r11ZScore, zTarget, zPrior, up >= 1500.0)

    mapState.r11SetTiers(mapState.r11ScoreToTier(mapState.r11XYScore),
        mapState.r11ScoreToTier(mapState.r11ZScore),
        'averaged-authority', distances)
end

mapState.r11RayUpdate = function(dt)
    local cell = self.cell
    if cell == nil or cell.isExterior then
        mapState.r11LastCell = cell
        mapState.r11LastTopoCell = nil
        mapState.r11XYScore = 4.0
        mapState.r11ZScore = 4.0
        mapState.r11SetTiers(0, 0, 'not-interior', nil)
        return
    end

    if mapState.r11LastCell ~= cell or mapState.r11LastTopoCell ~= mapState.topoCell then
        local reason = mapState.r11LastCell ~= cell and 'cell-change' or 'topology-change'
        mapState.r11LastCell = cell
        mapState.r11LastTopoCell = mapState.topoCell
        mapState.r11ResetAuthority(reason)
    end

    mapState.r11RayElapsed = mapState.r11RayElapsed + math.max(0.0, tonumber(dt or 0) or 0)
    if mapState.r11RayElapsed < mapState.r11RayPeriod then return end
    mapState.r11RayElapsed = 0.0
    local distances = mapState.r11SampleFour()
    mapState.r11Classify(distances)
    mapState.r11ReportElapsed = mapState.r11ReportElapsed + mapState.r11RayPeriod
    if mapState.r11ReportElapsed >= mapState.r11ReportPeriod then
        mapState.r11ReportElapsed = 0.0
        mapState.r11AuthorityReport(distances)
    end
end

mapState.r11OnFrame = function(dt)
    mapState.r11BaseOnFrame(dt)
    mapState.r11RayUpdate(dt)
end

print('[TSP_ROOMRAY_R11] enabled rays=4 period=0.20 phases=8 authority=dual-ema+topology XYtiers=5 Ztiers=5 long-weight=0.65')

'''.replace('BASE_CALLBACK', base)

    insert_pos = returns[0].start()
    src = src[:insert_pos] + block + src[insert_pos:]

    handler_matches = list(handler_pattern.finditer(src))
    if len(handler_matches) != 1:
        raise RuntimeError('onFrame handler changed unexpectedly after R11 insertion')
    handler = handler_matches[0]
    replacement = indent + "onFrame = function(dt) guarded('onFrame', mapState.r11OnFrame, dt) end,"
    src = src[:handler.start()] + replacement + src[handler.end():]

    required = (
        MARK,
        'mapState.r11RayPeriod = 0.20',
        'mapState.r11ReportPeriod = 2.0',
        'mapState.r11TopologyPrior = function()',
        'mapState.r11XYTarget = function(depth)',
        'mapState.r11ZTarget = function(depth)',
        'mapState.r11BlendAuthority = function(current, target, prior, strongOpen)',
        'camera.setInteriorAdaptiveHeightMode',
        'ordered[3] * 0.65',
        "'averaged-authority', distances",
        "'cell-change' or 'topology-change'",
        'mapState.r11CastDirection(eye, 0.50,      0.50)',
        "guarded('onFrame', mapState.r11OnFrame, dt)",
        'rays=4 period=0.20 phases=8 authority=dual-ema+topology',
    )
    for token in required:
        if token not in src:
            raise RuntimeError('R11 Lua postcondition missing: ' + token)
    if src.count('mapState.r11CastDirection(eye,') != 4:
        raise RuntimeError('R11 sample does not contain exactly four cast call sites')
    if 'TSP_ROOMRAY_LUA_V30_R10_THREE_RANGE' in src:
        raise RuntimeError('obsolete R10 Lua authority block survived replacement')
    return src


def sample():
    return '''local camera = require('openmw.camera')
local nearby = require('openmw.nearby')
local self = require('openmw.self')
local util = require('openmw.util')
local RAY_MASK = 1
local mapState = {}
-- TSP_VISGRID_LUA_V30_R4_SAME_FLOOR_PROXIMITY
camera.viewportToWorldVector(util.vector2(0.5,0.5))
nearby.castRay(a,b,{ collisionType = RAY_MASK })
mapState.updateTopologyPvs = function() end
mapState.base = function(dt) end
local function guarded(name, fn, dt) fn(dt) end
-- TSP_ROOMRAY_LUA_V30_R10_THREE_RANGE
mapState.r10BaseOnFrame = mapState.base
mapState.r10SetRangeMode = function(mode)
    camera.setInteriorAdaptiveRangeMode(mode)
end
mapState.r10OnFrame = function(dt)
    mapState.r10BaseOnFrame(dt)
end
return {
    engineHandlers = {
        onFrame = function(dt) guarded('onFrame', mapState.r10OnFrame, dt) end,
    },
}
'''


def selftest():
    out = patch_lua(sample())
    assert out.count('mapState.r11CastDirection(eye,') == 4
    assert 'r11XYTarget = function(depth)' in out
    assert 'r11ZTarget = function(depth)' in out
    assert 'r11XYTier = -1' in out and 'r11ZTier = -1' in out
    assert 'r11TopologyPrior = function()' in out
    assert 'ordered[3] * 0.65' in out
    assert 'camera.setInteriorAdaptiveHeightMode' in out
    assert 'TSP_ROOMRAY_LUA_V30_R10_THREE_RANGE' not in out
    assert out.index('TSP_ROOMRAY_LUA_V30_R11_FIVE_TIER_XY_HEIGHT') < out.index('return {')
    assert "guarded('onFrame', mapState.r11OnFrame, dt)" in out
    # Mirror the embedded EMA numerically: forty sustained small samples reach
    # very-tight, while one/three strong opening reports jump to medium/open.
    def blend(current, target, prior, strong_open=False):
        alpha = 0.055
        if target > current:
            alpha = 0.62 if strong_open else 0.42
        value = current + (target - current) * alpha
        value += (prior - value) * 0.008
        return max(0.0, min(4.0, value))
    def tier(score):
        return int(max(0.0, min(4.0, 4.5 - score)))
    score = 4.0
    for _ in range(40):
        score = blend(score, 0.0, 0.8)
    assert tier(score) == 4
    score = 0.0
    score = blend(score, 4.0, 4.0, True)
    assert tier(score) == 2
    score = blend(score, 4.0, 4.0, True)
    score = blend(score, 4.0, 4.0, True)
    assert tier(score) == 0
    print('PASS R11 Lua selftest: exact R10 replacement + four casts + dual five-tier EMA')


if len(sys.argv) == 2 and sys.argv[1] == '--selftest':
    selftest()
    raise SystemExit(0)
if len(sys.argv) == 3 and sys.argv[1] == '--emit-selftest':
    write(sys.argv[2], patch_lua(sample()))
    print('PASS emitted R11 Lua selftest fixture: ' + sys.argv[2])
    raise SystemExit(0)
if len(sys.argv) != 3:
    raise SystemExit('usage: patch_r11_lua.py INPUT_R10_LUA OUTPUT_R11_LUA | --selftest | --emit-selftest PATH')

write(sys.argv[2], patch_lua(read(sys.argv[1])))
print('PASS R11 four-ray five-tier-xy-height Lua generated')
PY_LUA

if ! python3 -m py_compile "$TMP/patch_r11_lua.py"; then
    fail 46 "embedded R11 Lua patcher does not compile"
fi
if ! python3 "$TMP/patch_r11_lua.py" --selftest; then
    fail 47 "R11 Lua patcher selftest failed"
fi
if ! python3 "$TMP/patch_r11_lua.py" "$TMP/visgrid-r10.lua" "$TMP/visgrid-r11.lua"; then
    fail 48 "R11 Lua generation failed"
fi

if ! docker cp "$TMP/visgrid-r11.lua" "$CTR:/tmp/visgrid-r11.lua" >/dev/null; then
    fail 49 "could not stage R11 Lua for syntax validation"
fi
LUA_PARSER="$(docker exec "$CTR" bash -lc 'for x in luajit lua texlua; do command -v "$x" >/dev/null 2>&1 && { echo "$x"; exit 0; }; done; exit 1' 2>/dev/null || true)"
if [ -n "$LUA_PARSER" ]; then
    if [ "$LUA_PARSER" = "texlua" ]; then
        # texlua is a LuaTeX launcher, not the standard lua CLI: it does not
        # accept lua/luajit's -e switch. --luaconly parses/compiles without
        # executing the OpenMW-only requires in the generated profile.
        if ! docker exec "$CTR" texlua --luaconly /tmp/visgrid-r11.lua; then
            fail 50 "generated R11 Lua syntax validation failed with texlua --luaconly"
        fi
        echo "LUA_PARSE_PASS /tmp/visgrid-r11.lua (texlua --luaconly)"
    else
        if ! docker exec -e R11_LUA_FILE=/tmp/visgrid-r11.lua "$CTR" "$LUA_PARSER" -e \
            'local p=os.getenv("R11_LUA_FILE"); local f,e=loadfile(p); assert(f,e); print("LUA_PARSE_PASS " .. p)'
        then
            fail 50 "generated R11 Lua syntax validation failed"
        fi
    fi
else
    echo "INFO: no Lua CLI in Docker; compiling a LuaJIT syntax checker."
    if ! docker exec -i "$CTR" bash -s <<'REMOTE_LUA_CHECK'
set -u
HEADER="$(find /usr/include /usr/local/include -type f -name lua.h -path '*luajit*' -print 2>/dev/null | head -1)"
if [ -z "$HEADER" ]; then echo "FAIL LuaJIT lua.h not found" >&2; exit 1; fi
INC="$(dirname "$HEADER")"
LIB="$(find /usr/lib /usr/local/lib \( -type f -o -type l \) -name 'libluajit-5.1.so*' -print 2>/dev/null | head -1)"
if [ -z "$LIB" ]; then echo "FAIL libluajit-5.1.so not found" >&2; exit 2; fi
CC=""
for c in gcc-13 gcc cc; do command -v "$c" >/dev/null 2>&1 && { CC="$c"; break; }; done
if [ -z "$CC" ]; then echo "FAIL no C compiler for LuaJIT checker" >&2; exit 3; fi
cat > /tmp/r11_lua_check.c <<'C_CHECK'
#include <stdio.h>
#include <lua.h>
#include <lauxlib.h>
int main(int argc, char **argv) {
    lua_State *L;
    int rc;
    if (argc != 2) return 2;
    L = luaL_newstate();
    if (!L) return 3;
    rc = luaL_loadfile(L, argv[1]);
    if (rc != 0) {
        const char *msg = lua_tostring(L, -1);
        fprintf(stderr, "LUA_PARSE_FAIL: %s\n", msg ? msg : "unknown");
        lua_close(L);
        return 4;
    }
    lua_close(L);
    printf("LUA_PARSE_PASS %s\n", argv[1]);
    return 0;
}
C_CHECK
"$CC" -O2 -I"$INC" /tmp/r11_lua_check.c "$LIB" -lm -ldl -pthread -o /tmp/r11_lua_check || exit 4
/tmp/r11_lua_check /tmp/visgrid-r11.lua || exit 5
REMOTE_LUA_CHECK
    then
        fail 51 "generated R11 Lua could not be syntax-validated"
    fi
fi
R11_LUA_SHA="$(sha256sum "$TMP/visgrid-r11.lua" | awk '{print $1}')"
echo "PASS R11 Lua SHA: $R11_LUA_SHA"

echo
echo "===== 5/9 APPLY R11 C++ PATCH + VERIFY SEMANTICS ====="

if ! docker cp "$TMP/patch_r11.py" "$CTR:/tmp/patch_r11.py" >/dev/null; then
    fail 52 "failed to copy R11 patcher into Docker"
fi
SOURCE_MUTATED=1
if ! docker exec "$CTR" python3 /tmp/patch_r11.py "$SCENE" "$VIS" "$VISH" "$CAMBIND"; then
    fail 53 "R11 source patch failed"
fi

if ! docker exec -i "$CTR" python3 - "$SCENE" "$ANIM" "$VIS" "$VISH" "$CAMBIND" <<'PY_VERIFY'
import sys
paths=sys.argv[1:6]
texts=[]
for p in paths:
    with open(p,'r',encoding='utf-8') as f:
        texts.append(f.read())
sc,an,vi,vh,cb=texts

checks = [
    (sc, 'TSP_ROOM_RENDER_SAFETY_051_V30_R9', 'scene R9 marker'),
    # patch_scene deliberately replaces the R10 THREE_RANGE_SCENE marker.
    # The R10 bridge marker is retained in visibility.cpp, not scene.cpp.
    (vi, 'TSP_ROOM_ADAPTIVE_RANGE_051_V30_R10', 'visibility R10 bridge marker retained'),
    (sc, 'TSP_ROOM_DUAL_AUTHORITY_051_V30_R11', 'scene R11 marker'),
    (sc, 'tspAdaptiveRangeMode >= 4 ? 750.f', 'very-tight light XY'),
    (sc, 'tspAdaptiveRangeMode == 1 ? 2100.f : 2600.f', 'large/open light XY'),
    (sc, 'tspAdaptiveHeightMode >= 4 ? 176.f', 'very-low light Z'),
    (sc, 'tspAdaptiveHeightMode == 1 ? 416.f : 512.f', 'high/tall light Z'),
    (sc, 'tspAdaptiveRangeMode >= 4 ? 400.f', 'very-tight ordinary wake'),
    (sc, 'tspAdaptiveRangeMode >= 4 ? 600.f', 'very-tight ordinary hold'),
    (sc, '[TSP_ROOMOBJ_V30] adaptiveXYTier=" << MWRender::getInteriorAdaptiveRangeMode()',
     'scope-safe aggregate range log'),
    (sc, 'adaptiveZTier=" << MWRender::getInteriorAdaptiveHeightMode()',
     'scope-safe aggregate height log'),
    (an, 'TSP_ROOM_RENDER_SAFETY_051_V30_R9', 'animation R9 marker'),
    (an, 'const bool tspIsLight = mPtr.getType() == ESM::Light::sRecordId;', 'light classification'),
    (an, 'const bool tspPvsEligible = false;', 'gameplay callback topology PVS disabled'),
    (vi, 'TSP_ROOM_DUAL_AUTHORITY_051_V30_R11', 'visibility R11 marker'),
    (vi, 'tspAdaptiveRangeMode >= 4 ? 450.0', 'very-tight gameplay safety'),
    (vi, 'tspAdaptiveRangeMode == 1 ? 1200.0 : 1450.0', 'large/open gameplay safety'),
    (vi, 'const double nearestSurface=', 'far screen-depth path retained'),
    (vh, 'void setInteriorAdaptiveRangeMode(int mode);', 'range bridge header setter'),
    (vh, 'int getInteriorAdaptiveRangeMode();', 'range bridge header getter'),
    (vh, 'void setInteriorAdaptiveHeightMode(int mode);', 'height bridge header setter'),
    (vh, 'int getInteriorAdaptiveHeightMode();', 'height bridge header getter'),
    (cb, 'api["setInteriorAdaptiveRangeMode"]', 'range bridge Lua setter'),
    (cb, 'api["getInteriorAdaptiveRangeMode"]', 'range bridge Lua getter'),
    (cb, 'api["setInteriorAdaptiveHeightMode"]', 'height bridge Lua setter'),
    (cb, 'api["getInteriorAdaptiveHeightMode"]', 'height bridge Lua getter'),
]
for text, token, label in checks:
    if token not in text:
        raise SystemExit('FAIL semantic verify missing %s: %s' % (label, token))

for text, token, label in (
    (sc, 'tspAdaptiveRangeMode >= 2 ? 850.f', 'obsolete R10 three-tier light XY'),
    (vi, 'tspAdaptiveRangeMode >= 2 ? 500.0', 'obsolete R10 three-tier gameplay bypass'),
    (an, 'const bool tspPvsEligible = std::isfinite(tspPvsRadius)', 'obsolete callback topology PVS eligibility'),
    (an, 'mPtr.get<ESM::Static>()', 'unsafe Static cast'),
):
    if token in text:
        raise SystemExit('FAIL forbidden token survived %s: %s' % (label, token))

roomobj_lines = [
    line for line in sc.splitlines()
    if '[TSP_ROOMOBJ_V30] adaptiveXYTier=' in line
]
if len(roomobj_lines) != 1:
    raise SystemExit('FAIL R11 aggregate room-object log line count=%d expected 1'
                     % len(roomobj_lines))
for token in ('<< tspAdaptiveRangeMode', '<< tspAdaptiveHeightMode',
              '<< tspRoomLightNearXY', '<< tspRoomLightNearZ'):
    if token in roomobj_lines[0]:
        raise SystemExit('FAIL out-of-scope local survived in R11 room-object log: ' + token)

print('PASS R11 semantics: independent five-tier XY/Z + 512 tall-light ceiling')
PY_VERIFY
then
    fail 54 "R11 post-patch semantic verification failed"
fi

echo
echo "===== 6/9 INVALIDATE EXACTLY THREE CHANGED TRANSLATION UNITS ====="

if ! docker exec -i "$CTR" bash -s -- "$BUILD" "$SCENE" "$VIS" "$VISH" "$CAMBIND" <<'REMOTE_INVALIDATE'
set -u
BUILD="$1"
SCENE="$2"
VIS="$3"
VISH="$4"
CAMBIND="$5"

SCENE_OBJ="$BUILD/apps/openmw/CMakeFiles/openmw-lib.dir/mwworld/scene.cpp.o"
VIS_OBJ="$BUILD/apps/openmw/CMakeFiles/openmw-lib.dir/mwrender/interiorvisibility.cpp.o"
CAMBIND_OBJ="$BUILD/apps/openmw/CMakeFiles/openmw-lib.dir/mwlua/camerabindings.cpp.o"

rm -f "$SCENE_OBJ" "$SCENE_OBJ.d" "$VIS_OBJ" "$VIS_OBJ.d" "$CAMBIND_OBJ" "$CAMBIND_OBJ.d"
touch "$SCENE" "$VIS" "$VISH" "$CAMBIND"

for obj in "$SCENE_OBJ" "$VIS_OBJ" "$CAMBIND_OBJ"; do
    if [ -e "$obj" ]; then
        echo "FAIL object survived invalidation: $obj" >&2
        exit 1
    fi
done

echo "PASS invalidated scene.cpp.o + interiorvisibility.cpp.o + camerabindings.cpp.o"
REMOTE_INVALIDATE
then
    fail 55 "R11 object invalidation failed"
fi

echo
echo "===== 7/9 BUILD + PROVE ALL THREE TRANSLATION UNITS RECOMPILED ====="

: > "$BUILDLOG"
if ! docker exec "$CTR" cmake --build "$BUILD" --target openmw --parallel 1 2>&1 | tee "$BUILDLOG"; then
    echo
    echo "===== R11 BUILD FAILURE TAIL ====="
    tail -320 "$BUILDLOG" || true
    fail 56 "R11 build failed; full log: $BUILDLOG"
fi

for needle in 'mwworld/scene.cpp.o' 'mwrender/interiorvisibility.cpp.o' 'mwlua/camerabindings.cpp.o'; do
    if ! grep -Fq "$needle" "$BUILDLOG"; then
        fail 57 "build log does not prove recompile: $needle"
    fi
    echo "PASS build log proves recompile: $needle"
done

echo
echo "===== 8/9 PACKAGE + ARM64/SHA VERIFY + INSTALL BINARY + LUA ====="

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
    fail 60 "R11 package failed"
fi

if ! docker cp "$CTR:$PACKAGED" "$HOSTBIN" >/dev/null; then
    fail 61 "Docker -> Ubuntu copy failed"
fi
if [ ! -s "$HOSTBIN" ]; then
    fail 62 "host R11 binary missing/empty"
fi
DESC="$(file "$HOSTBIN" 2>/dev/null || true)"
echo "$DESC"
if ! printf '%s\n' "$DESC" | grep -Eq 'ARM aarch64|ARM64|AArch64'; then
    fail 63 "host R11 binary is not ARM64/AArch64: $DESC"
fi
NEW_SHA="$(sha256sum "$HOSTBIN" | awk '{print $1}')"
if [ -z "$NEW_SHA" ]; then
    fail 64 "could not hash R11 host binary"
fi
if [ "$NEW_SHA" = "$EXPECTED_R10_SHA" ]; then
    fail 65 "R11 binary SHA unexpectedly equals R10 after verified semantic changes"
fi
echo "PASS R11 ARM64 host SHA: $NEW_SHA"

if ! scp -q "$HOSTBIN" "$DEV:$TMPBIN"; then
    fail 66 "R11 binary upload failed"
fi
if ! scp -q "$TMP/visgrid-r11.lua" "$DEV:$TMPLUA"; then
    fail 67 "R11 Lua upload failed"
fi
DEVICE_DEPLOYED=1
LUA_DEPLOYED=1
if ! ssh "$DEV" 'bash -s' -- "$TMPBIN" "$BIN" "$NEW_SHA" "$TMPLUA" "$LUA" "$PROFILE" "$R11_LUA_SHA" <<'REMOTE_INSTALL'
set -u
TMPBIN="$1"
BIN="$2"
EXPECTED_BIN="$3"
TMPLUA="$4"
LIVE_LUA="$5"
PROFILE="$6"
EXPECTED_LUA="$7"
if [ ! -s "$TMPBIN" ] || [ ! -s "$TMPLUA" ]; then echo "FAIL staged R11 input missing" >&2; exit 1; fi
INCOMING="$(sha256sum "$TMPBIN" | awk '{print $1}')"
if [ "$INCOMING" != "$EXPECTED_BIN" ]; then
    echo "FAIL binary upload SHA expected=$EXPECTED_BIN actual=$INCOMING" >&2
    exit 2
fi
INCOMING_LUA="$(sha256sum "$TMPLUA" | awk '{print $1}')"
if [ "$INCOMING_LUA" != "$EXPECTED_LUA" ]; then
    echo "FAIL Lua upload SHA expected=$EXPECTED_LUA actual=$INCOMING_LUA" >&2
    exit 3
fi
if ! install -m 755 "$TMPBIN" "$BIN"; then exit 4; fi
if ! install -m 644 "$TMPLUA" "$PROFILE"; then exit 5; fi
if ! install -m 644 "$TMPLUA" "$LIVE_LUA"; then exit 6; fi
rm -f "$TMPBIN" "$TMPLUA"
sync
FINAL="$(sha256sum "$BIN" | awk '{print $1}')"
if [ "$FINAL" != "$EXPECTED_BIN" ]; then
    echo "FAIL final binary SHA expected=$EXPECTED_BIN actual=$FINAL" >&2
    exit 7
fi
for f in "$PROFILE" "$LIVE_LUA"; do
    GOT="$(sha256sum "$f" | awk '{print $1}')"
    if [ "$GOT" != "$EXPECTED_LUA" ]; then
        echo "FAIL final Lua SHA expected=$EXPECTED_LUA actual=$GOT file=$f" >&2
        exit 8
    fi
    grep -Fq 'TSP_ROOMRAY_LUA_V30_R11_FIVE_TIER_XY_HEIGHT' "$f" || exit 9
done
echo "PASS installed exact R11 binary SHA: $FINAL"
echo "PASS installed exact R11 profile/live Lua SHA: $EXPECTED_LUA"
REMOTE_INSTALL
then
    fail 68 "R11 device install failed"
fi

FINAL_SHA="$(ssh "$DEV" "sha256sum '$BIN' | awk '{print \$1}'" 2>/dev/null || true)"
if [ "$FINAL_SHA" != "$NEW_SHA" ]; then
    fail 69 "final R11 device SHA verification failed"
fi
LUA_SHA_AFTER="$(ssh "$DEV" "sha256sum '$LUA' | awk '{print \$1}'" 2>/dev/null || true)"
if [ "$LUA_SHA_AFTER" != "$R11_LUA_SHA" ]; then
    echo "EXPECTED R11 LUA: $R11_LUA_SHA" >&2
    echo "ACTUAL R11 LUA:   $LUA_SHA_AFTER" >&2
    fail 70 "final R11 Lua SHA verification failed"
fi

echo
echo "===== 9/9 ARM CLEAN CAPTURE + SAVE EXACT R10 ROLLBACK STATE ====="

if ! ssh "$DEV" 'bash -s' -- "$GAMELOG" "$ARM" <<'REMOTE_ARM'
set -u
LOG="$1"
ARM="$2"
if [ ! -f "$LOG" ]; then echo "FAIL log missing: $LOG" >&2; exit 1; fi
LINES="$(wc -l < "$LOG" | tr -d '[:space:]')"
case "$LINES" in ''|*[!0-9]*) echo "FAIL invalid log line count: $LINES" >&2; exit 2;; esac
if ! printf '%s\n' "$LINES" > "$ARM"; then exit 3; fi
echo "PASS R11 capture armed after log line: $LINES"
REMOTE_ARM
then
    fail 71 "R11 capture arm failed"
fi

cat > "$STATE" <<EOF_STATE
R11_SOURCE_BACKUP='$SOURCE_BACKUP'
R11_DEVICE_BACKUP='$DEVICE_BACKUP'
R11_OLD_SHA='$EXPECTED_R10_SHA'
R11_NEW_SHA='$NEW_SHA'
R11_OLD_LUA_SHA='$EXPECTED_R10_LUA_SHA'
R11_NEW_LUA_SHA='$R11_LUA_SHA'
R11_HOST_BIN='$HOSTBIN'
EOF_STATE
if [ ! -s "$STATE" ]; then
    fail 72 "R11 state file was not written: $STATE"
fi

SOURCE_MUTATED=0
DEVICE_DEPLOYED=0
LUA_DEPLOYED=0

echo
echo "============================================================"
echo "V30 R11-R1 FOUR-RAY FIVE-TIER XY/HEIGHT CONTROLLER INSTALLED"
echo "============================================================"
echo "R10 SHA:    $EXPECTED_R10_SHA"
echo "R11 SHA:    $FINAL_SHA"
echo "R10 Lua:    $EXPECTED_R10_LUA_SHA"
echo "R11 Lua:    $LUA_SHA_AFTER"
echo "Host bin:  $HOSTBIN"
echo "State:     $STATE"
echo
echo "Test once:"
echo "  1. Tight corridor: confirm XY settles small/very-tight while FPS improves"
echo "  2. Open doorway: confirm a long forward witness expands XY immediately"
echo "  3. Ald-ruhn hall: confirm XY can stay economical while Z rises for lights"
echo "  4. Arobar doors: confirm nearby gameplay-object safety remains correct"
echo "  5. Validation should show independent XY/Z scores, tiers and raw depths"
echo
echo "Then collect:"
echo "  cd ~/Downloads"
echo "  ./apply_openmw51_tsp_roomwake_v30_R11_R1_five_tier_xy_height_authority.sh collect"
echo
echo "Rollback to exact R10 binary + R10 Lua:"
echo "  ./apply_openmw51_tsp_roomwake_v30_R11_R1_five_tier_xy_height_authority.sh rollback"
echo "============================================================"
