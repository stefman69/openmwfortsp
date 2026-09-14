#!/usr/bin/env bash
# OpenMW 0.51 / TrimUI Smart Pro
# V30 R7: topology-independent near-field correctness floor for ordinary clutter.
#
# Purpose:
#   Keep the proven R4/V30 room/floor authority for aggressive distant culling,
#   but NEVER allow a nearby ordinary clutter object to disappear solely because
#   navmesh topology ownership is fragmented or wrong.
#
# R7 behavior:
#   - existing R4 Lua room/floor policy unchanged
#   - existing R6 light rule unchanged: XY 1560, |Z| 192
#   - ordinary non-light clutter gets a direct player-distance safety net:
#       parked object wakes at XY <= 1100 and |Z| <= 320
#       already-live object stays live until XY > 1450 or |Z| > 384
#   - two-threshold hysteresis prevents threshold flicker
#   - actors/doors/statics/activators are unaffected because this operates only
#     inside the already-existing hard-object lifecycle eligibility path
#
# If R6D1 diagnostic is currently installed, this controller automatically
# preserves the diagnostic text, restores exact R6 source+device, then builds R7.
#
# Actions:
#   install  (default)
#   collect  collect R7 runtime lines after install
#   rollback restore exact pre-R7 R6 binary/source

set -u -o pipefail

ACTION="${1:-install}"
CTR="${OPENMW_CONTAINER:-openmw_builder}"
DEV="${TSP_DEVICE:-root@192.168.1.12}"

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
REMOTE_TMP_BIN="/tmp/openmw-0.51.v30-r7-nearfield"
R7_ARM_FILE="$ROOT/roomwake-r7-capture-start.line"
R6D1_ARM_FILE="$ROOT/roomobj-r6d1-capture-start.line"

EXPECTED_R6_SHA="898f21fd6475c41eed81e0499d4bda4beb0586e6df0da92058a80ae25a29c512"

DL="$HOME/Downloads"
STAMP="$(date +%Y%m%d-%H%M%S)"
LOG="$DL/openmw51-roomwake-r7-$STAMP.log"
BUILD_LOG="$DL/openmw51-roomwake-r7-build-$STAMP.log"
STATE="$DL/openmw51-roomwake-r7.state"
R6D1_STATE="$DL/openmw51-roomobj-r6d1.state"
HOST_BIN="$DL/openmw-0.51-v30-r7-nearfield-correctness"
TMP="$(mktemp -d "$DL/.roomwake-r7.XXXXXX")"

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
    if ! ssh -o BatchMode=yes -o ConnectTimeout=8 "$DEV" true >/dev/null 2>&1; then
        fail 13 "SSH failed: $DEV"
    fi
    echo "PASS SSH: $DEV"
}

cleanup() {
    rm -rf "$TMP"
}

restore_r7_source() {
    if [ -z "$SOURCE_BACKUP" ]; then
        echo "FAIL R7 source rollback: SOURCE_BACKUP empty" >&2
        return 1
    fi
    if ! docker exec -i "$CTR" bash -s -- "$SOURCE_BACKUP" "$SCENE_CPP" "$BUILD" <<'REMOTE_RESTORE_R7_SOURCE'
set -u
BACKUP="$1"
SCENE="$2"
BUILD="$3"
SRCFILE="$BACKUP/scene.cpp"
OBJ="$BUILD/apps/openmw/CMakeFiles/openmw-lib.dir/mwworld/scene.cpp.o"
if [ ! -s "$SRCFILE" ]; then
    echo "FAIL R7 source rollback backup missing: $SRCFILE" >&2
    exit 1
fi
if ! cp -f "$SRCFILE" "$SCENE"; then
    echo "FAIL restoring R7 source: $SCENE" >&2
    exit 2
fi
touch "$SCENE"
rm -f "$OBJ" "$OBJ.d"
echo "PASS R7 source rollback: restored pre-R7 scene.cpp and invalidated scene.cpp.o"
REMOTE_RESTORE_R7_SOURCE
    then
        return 1
    fi
    return 0
}

restore_r7_device() {
    if [ -z "$DEVICE_BACKUP" ]; then
        echo "FAIL R7 device rollback: DEVICE_BACKUP empty" >&2
        return 1
    fi
    if ! ssh "$DEV" 'bash -s' -- "$DEVICE_BACKUP" "$REMOTE_BIN" "$EXPECTED_R6_SHA" <<'REMOTE_RESTORE_R7_DEVICE'
set -u
BACKUP="$1"
BIN="$2"
EXPECTED="$3"
if [ ! -s "$BACKUP" ]; then
    echo "FAIL R7 device rollback backup missing: $BACKUP" >&2
    exit 1
fi
BACK_SHA="$(sha256sum "$BACKUP" | awk '{print $1}')"
if [ "$BACK_SHA" != "$EXPECTED" ]; then
    echo "FAIL R7 rollback backup is not exact R6" >&2
    echo "EXPECTED: $EXPECTED" >&2
    echo "ACTUAL:   $BACK_SHA" >&2
    exit 2
fi
if ! install -m 755 "$BACKUP" "$BIN"; then
    echo "FAIL restoring R6 device binary: $BIN" >&2
    exit 3
fi
sync
FINAL="$(sha256sum "$BIN" | awk '{print $1}')"
if [ "$FINAL" != "$EXPECTED" ]; then
    echo "FAIL restored R6 device SHA mismatch" >&2
    echo "EXPECTED: $EXPECTED" >&2
    echo "ACTUAL:   $FINAL" >&2
    exit 4
fi
echo "PASS R7 device rollback SHA: $FINAL"
REMOTE_RESTORE_R7_DEVICE
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
        echo "===== R7 FAILURE RECOVERY ====="
        if [ "$DEVICE_DEPLOY_STARTED" -eq 1 ]; then
            echo "INFO: restoring exact pre-R7 R6 device binary..."
            if ! restore_r7_device; then
                echo "WARNING: automatic R7 device rollback failed" >&2
            fi
        fi
        if [ "$SOURCE_MUTATED" -eq 1 ]; then
            echo "INFO: restoring exact pre-R7 R6 source..."
            if ! restore_r7_source; then
                echo "WARNING: automatic R7 source rollback failed" >&2
            fi
        fi
    fi
    cleanup
    exit "$rc"
}
trap on_exit EXIT

collect_r7() {
    ensure_ssh
    local out="$DL/openmw51-roomwake-r7-validation-$STAMP.txt"
    if ! ssh "$DEV" 'bash -s' -- "$REMOTE_LOG" "$REMOTE_PERF" "$REMOTE_BIN" "$LIVE_LUA" "$R7_ARM_FILE" > "$out" <<'REMOTE_COLLECT_R7'
set -u
LOG="$1"
PERF="$2"
BIN="$3"
LUA="$4"
ARM="$5"

echo "===== OPENMW 0.51 V30 R7 NEAR-FIELD VALIDATION ====="
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
        if [ "$TOTAL" -gt 1800 ]; then START=$((TOTAL-1800)); else START=0; fi
        echo "WARN invalid/missing R7 arm point; using log tail from line $((START+1))"
        ;;
esac
FIRST=$((START+1))
echo "Log lines: total=$TOTAL capture=$FIRST..$TOTAL"
echo
echo "===== CELL / R7 OBJECT / ROOM / ACTOR LINES ====="
sed -n "${FIRST},${TOTAL}p" "$LOG" 2>/dev/null \
    | grep -E 'Loading cell|Changing to interior|\[TSP_ROOMOBJ_V30\]|\[TSP_VISGRID_V30_R4\]|\[TSP_ACTOR_V30\]|failed to render' \
    || true

echo
echo "===== PERF TAIL ====="
if [ -f "$PERF" ]; then tail -120 "$PERF" 2>/dev/null || true; else echo "PERF MISSING: $PERF"; fi
REMOTE_COLLECT_R7
    then
        fail 20 "R7 collect failed from $DEV"
    fi
    echo "Saved: $out"
}

rollback_r7() {
    ensure_docker
    ensure_ssh
    if [ ! -s "$STATE" ]; then
        fail 21 "R7 rollback state missing: $STATE"
    fi
    # State is generated by this controller and contains shell-quoted paths/hashes.
    # shellcheck disable=SC1090
    . "$STATE"
    if [ -z "${R7_SOURCE_BACKUP:-}" ]; then fail 22 "state missing R7_SOURCE_BACKUP: $STATE"; fi
    if [ -z "${R7_DEVICE_BACKUP:-}" ]; then fail 23 "state missing R7_DEVICE_BACKUP: $STATE"; fi
    if [ "${R7_OLD_DEVICE_SHA:-}" != "$EXPECTED_R6_SHA" ]; then
        fail 24 "R7 state old SHA is not exact R6: ${R7_OLD_DEVICE_SHA:-EMPTY}"
    fi
    SOURCE_BACKUP="$R7_SOURCE_BACKUP"
    DEVICE_BACKUP="$R7_DEVICE_BACKUP"
    if ! restore_r7_source; then fail 25 "manual R7 source rollback failed"; fi
    if ! restore_r7_device; then fail 26 "manual R7 device rollback failed"; fi
    echo "PASS R7 rollback complete; exact R6 restored."
}

case "$ACTION" in
    collect)
        collect_r7
        exit 0
        ;;
    rollback)
        rollback_r7
        exit 0
        ;;
    install) ;;
    *) fail 2 "usage: $0 [install|collect|rollback]" ;;
esac

exec > >(tee "$LOG") 2>&1

cat <<'BANNER'
============================================================
OPENMW 0.51 — ROOMWAKE V30 R7 NEAR-FIELD CORRECTNESS
CONTROLLER REVISION: V30-R7-R1 STRUCTURAL LOG PATCH + NEAR-FIELD
============================================================
R4 topology room/floor authority: unchanged.
R6 lights: unchanged (XY 1560, |Z| 192).
Ordinary eligible clutter safety net:
  PARKED -> wake:  XY <= 1100, |Z| <= 320
  LIVE   -> hold:  XY <= 1450, |Z| <= 384
This safety net is player-relative and ignores broken topology ownership.
It does NOT wake actors and does NOT activate whole topology sectors.
============================================================
BANNER

require_cmd python3
require_cmd sha256sum
require_cmd file
ensure_docker
ensure_ssh

if ssh "$DEV" "pgrep -af 'openmw-0\\.51|/openmw([[:space:]]|$)' 2>/dev/null" | grep -v pgrep >/dev/null 2>&1; then
    fail 30 "OpenMW appears to be running on the TrimUI; exit the game before installing R7"
fi

# ---------------------------------------------------------------------------
# If the diagnostic build is still live, preserve its text and restore exact R6.
# ---------------------------------------------------------------------------
echo
echo "===== 1/8 NORMALIZE R6D1 DIAGNOSTIC -> EXACT R6 BASELINE ====="
LIVE_SHA="$(ssh "$DEV" "sha256sum '$REMOTE_BIN' | awk '{print \$1}'" 2>/dev/null || true)"
if [ -z "$LIVE_SHA" ]; then
    fail 31 "could not read live device SHA: $REMOTE_BIN"
fi

if [ "$LIVE_SHA" != "$EXPECTED_R6_SHA" ]; then
    if [ ! -s "$R6D1_STATE" ]; then
        echo "EXPECTED R6 SHA: $EXPECTED_R6_SHA" >&2
        echo "ACTUAL DEVICE:  $LIVE_SHA" >&2
        fail 32 "device is not exact R6 and R6D1 rollback state is missing: $R6D1_STATE"
    fi

    # shellcheck disable=SC1090
    . "$R6D1_STATE"
    if [ -z "${R6D1_SOURCE_BACKUP:-}" ] || [ -z "${R6D1_DEVICE_BACKUP:-}" ] || [ -z "${R6D1_DIAG_DEVICE_SHA:-}" ]; then
        fail 33 "R6D1 state incomplete: $R6D1_STATE"
    fi
    if [ "$LIVE_SHA" != "$R6D1_DIAG_DEVICE_SHA" ]; then
        echo "STATE DIAG SHA: $R6D1_DIAG_DEVICE_SHA" >&2
        echo "LIVE SHA:       $LIVE_SHA" >&2
        fail 34 "live binary is neither exact R6 nor the R6D1 diagnostic recorded in state"
    fi

    # Preserve the diagnostic text before replacing the diagnostic binary/source.
    R6D1_SALVAGE="$DL/openmw51-roomobj-r6d1-before-r7-$STAMP.txt"
    if ssh "$DEV" 'bash -s' -- "$REMOTE_LOG" "$R6D1_ARM_FILE" > "$R6D1_SALVAGE" <<'REMOTE_SALVAGE_R6D1'
set -u
LOG="$1"
ARM="$2"
if [ ! -f "$LOG" ]; then echo "LOG MISSING: $LOG"; exit 0; fi
TOTAL="$(wc -l < "$LOG" | tr -d '[:space:]')"
START=""
if [ -s "$ARM" ]; then START="$(tr -dc '0-9' < "$ARM")"; fi
case "$START" in
  ''|*[!0-9]*) if [ "$TOTAL" -gt 2400 ]; then START=$((TOTAL-2400)); else START=0; fi ;;
esac
FIRST=$((START+1))
echo "===== SALVAGED R6D1 BEFORE R7 ====="
echo "Log lines: total=$TOTAL capture=$FIRST..$TOTAL"
sed -n "${FIRST},${TOTAL}p" "$LOG" 2>/dev/null \
  | grep -E 'Loading cell|Changing to interior|\[TSP_ROOMOBJ_SNAP_R6D1\]|\[TSP_ROOMOBJ_NEAR_R6D1\]|\[TSP_ROOMOBJ_V30\]|\[TSP_VISGRID_V30_R4\]|\[TSP_ACTOR_V30\]|failed to render' \
  || true
REMOTE_SALVAGE_R6D1
    then
        echo "PASS preserved existing R6D1 diagnostic text: $R6D1_SALVAGE"
    else
        echo "WARNING: could not preserve R6D1 diagnostic text; continuing with exact rollback" >&2
        rm -f "$R6D1_SALVAGE"
    fi

    if ! docker exec -i "$CTR" bash -s -- "$R6D1_SOURCE_BACKUP" "$SCENE_CPP" "$BUILD" <<'REMOTE_RESTORE_R6D1_SOURCE'
set -u
BACKUP="$1"
SCENE="$2"
BUILD="$3"
SRCFILE="$BACKUP/scene.cpp"
OBJ="$BUILD/apps/openmw/CMakeFiles/openmw-lib.dir/mwworld/scene.cpp.o"
if [ ! -s "$SRCFILE" ]; then echo "FAIL R6D1 source backup missing: $SRCFILE" >&2; exit 1; fi
if ! grep -Fq 'TSP_ROOM_LIGHT_PLAYER_KEEP_051_V30_R6' "$SRCFILE"; then
    echo "FAIL R6D1 source backup is not R6: $SRCFILE" >&2; exit 2
fi
if grep -Fq 'TSP_ROOM_OBJECT_SNAPSHOT_DIAG_051_R6D1' "$SRCFILE"; then
    echo "FAIL R6D1 source backup already contains diagnostic marker: $SRCFILE" >&2; exit 3
fi
if ! cp -f "$SRCFILE" "$SCENE"; then echo "FAIL restoring R6 scene.cpp" >&2; exit 4; fi
touch "$SCENE"
rm -f "$OBJ" "$OBJ.d"
echo "PASS restored exact pre-diagnostic R6 scene.cpp"
REMOTE_RESTORE_R6D1_SOURCE
    then
        fail 35 "failed to restore R6 source from R6D1 state"
    fi

    if ! ssh "$DEV" 'bash -s' -- "$R6D1_DEVICE_BACKUP" "$REMOTE_BIN" "$EXPECTED_R6_SHA" <<'REMOTE_RESTORE_R6D1_DEVICE'
set -u
BACKUP="$1"
BIN="$2"
EXPECTED="$3"
if [ ! -s "$BACKUP" ]; then echo "FAIL R6D1 device backup missing: $BACKUP" >&2; exit 1; fi
SHA="$(sha256sum "$BACKUP" | awk '{print $1}')"
if [ "$SHA" != "$EXPECTED" ]; then
    echo "FAIL R6D1 backup not exact R6" >&2; echo "EXPECTED: $EXPECTED" >&2; echo "ACTUAL: $SHA" >&2; exit 2
fi
if ! install -m 755 "$BACKUP" "$BIN"; then echo "FAIL restoring R6 device binary" >&2; exit 3; fi
sync
FINAL="$(sha256sum "$BIN" | awk '{print $1}')"
if [ "$FINAL" != "$EXPECTED" ]; then
    echo "FAIL R6 device restore SHA mismatch" >&2; echo "EXPECTED: $EXPECTED" >&2; echo "ACTUAL: $FINAL" >&2; exit 4
fi
echo "PASS exact R6 device restored: $FINAL"
REMOTE_RESTORE_R6D1_DEVICE
    then
        fail 36 "failed to restore exact R6 device from R6D1 state"
    fi
else
    echo "PASS device already exact R6 SHA: $LIVE_SHA"

    # Device may be R6 while source still has diagnostic instrumentation. Normalize source if needed.
    if docker exec "$CTR" grep -Fq 'TSP_ROOM_OBJECT_SNAPSHOT_DIAG_051_R6D1' "$SCENE_CPP" 2>/dev/null; then
        if [ ! -s "$R6D1_STATE" ]; then
            fail 37 "Docker source is R6D1 diagnostic but R6D1 state is missing: $R6D1_STATE"
        fi
        # shellcheck disable=SC1090
        . "$R6D1_STATE"
        if [ -z "${R6D1_SOURCE_BACKUP:-}" ]; then fail 38 "R6D1 state missing source backup"; fi
        if ! docker exec -i "$CTR" bash -s -- "$R6D1_SOURCE_BACKUP" "$SCENE_CPP" "$BUILD" <<'REMOTE_SOURCE_ONLY_R6'
set -u
BACKUP="$1"; SCENE="$2"; BUILD="$3"
SRCFILE="$BACKUP/scene.cpp"
OBJ="$BUILD/apps/openmw/CMakeFiles/openmw-lib.dir/mwworld/scene.cpp.o"
if [ ! -s "$SRCFILE" ]; then echo "FAIL source-only R6 backup missing: $SRCFILE" >&2; exit 1; fi
if ! grep -Fq 'TSP_ROOM_LIGHT_PLAYER_KEEP_051_V30_R6' "$SRCFILE"; then echo "FAIL source-only backup not R6" >&2; exit 2; fi
if ! cp -f "$SRCFILE" "$SCENE"; then echo "FAIL source-only R6 restore" >&2; exit 3; fi
touch "$SCENE"; rm -f "$OBJ" "$OBJ.d"
echo "PASS normalized Docker source back to exact R6"
REMOTE_SOURCE_ONLY_R6
        then
            fail 39 "failed to normalize Docker source to R6"
        fi
    fi
fi

# Verify exact R6 baseline semantically after normalization.
if ! docker exec -i "$CTR" bash -s -- "$SCENE_CPP" "$VIS_CPP" <<'REMOTE_VERIFY_R6_BASE'
set -u
SCENE="$1"
VIS="$2"
check_has() {
    local token="$1" file="$2" label="$3"
    if ! grep -Fq -- "$token" "$file"; then
        echo "FAIL $label" >&2; echo "FILE: $file" >&2; echo "EXPECTED: $token" >&2; exit 1
    fi
    echo "PASS $label"
}
check_absent() {
    local token="$1" file="$2" label="$3"
    if grep -Fq -- "$token" "$file"; then
        echo "FAIL $label" >&2; echo "FILE: $file" >&2; echo "FORBIDDEN: $token" >&2; exit 2
    fi
    echo "PASS $label"
}
check_has 'TSP_ROOM_LIGHT_PLAYER_KEEP_051_V30_R6' "$SCENE" 'R6 light marker'
check_has 'tspRoomLightNearXY = 1560.f' "$SCENE" 'R6 light XY'
check_has 'tspRoomLightNearZ = 192.f' "$SCENE" 'R6 light Z'
check_has '[TSP_ROOMOBJ_V30] lightNearXY=1560 lightNearZ=192' "$SCENE" 'R6 object log source'
check_has 'TSP_ROOM_OBJECT_FLOOR_AUTHORITY_051_V30' "$VIS" 'V30 floor authority'
check_has 'constexpr float zSlack = 110.f;' "$VIS" 'R6 ordinary exact ownership'
check_absent 'TSP_ROOM_OBJECT_SNAPSHOT_DIAG_051_R6D1' "$SCENE" 'R6D1 diagnostic source removed'
check_absent 'TSP_ROOM_NEARFIELD_CORRECTNESS_051_V30_R7' "$SCENE" 'R7 not already present'
REMOTE_VERIFY_R6_BASE
then
    fail 40 "Docker source is not the expected exact R6 baseline"
fi

LIVE_SHA="$(ssh "$DEV" "sha256sum '$REMOTE_BIN' | awk '{print \$1}'" 2>/dev/null || true)"
if [ "$LIVE_SHA" != "$EXPECTED_R6_SHA" ]; then
    echo "EXPECTED R6 SHA: $EXPECTED_R6_SHA" >&2
    echo "ACTUAL DEVICE:  $LIVE_SHA" >&2
    fail 41 "device failed exact R6 normalization"
fi
if ! ssh "$DEV" "grep -Fq 'TSP_VISGRID_V30_R4' '$LIVE_LUA'"; then
    fail 42 "live Lua is not R4 baseline: $LIVE_LUA"
fi
LUA_SHA_BEFORE="$(ssh "$DEV" "sha256sum '$LIVE_LUA' | awk '{print \$1}'" 2>/dev/null || true)"
if [ -z "$LUA_SHA_BEFORE" ]; then fail 43 "could not calculate live R4 Lua SHA"; fi
echo "PASS exact R6 + R4 baseline normalized"

# ---------------------------------------------------------------------------
# Backup R6 before R7.
# ---------------------------------------------------------------------------
echo
echo "===== 2/8 BACK UP EXACT R6 SOURCE + DEVICE ====="
SOURCE_BACKUP="$SRC/.tsp-051-source-backups/roomwake-v30-r7-nearfield-$STAMP"
if ! docker exec -i "$CTR" bash -s -- "$SOURCE_BACKUP" "$SCENE_CPP" <<'REMOTE_BACKUP_R6_SOURCE'
set -u
BACKUP="$1"; SCENE="$2"
if ! mkdir -p "$BACKUP"; then echo "FAIL creating R7 source backup dir: $BACKUP" >&2; exit 1; fi
if ! cp -f "$SCENE" "$BACKUP/scene.cpp"; then echo "FAIL backing up R6 scene.cpp" >&2; exit 2; fi
sha256sum "$BACKUP/scene.cpp"
echo "PASS R7 source backup: $BACKUP"
REMOTE_BACKUP_R6_SOURCE
then
    fail 44 "failed to back up exact R6 source"
fi

DEVICE_BACKUP_DIR="$ROOT/backups/roomwake-v30-r7-nearfield-$STAMP"
DEVICE_BACKUP="$DEVICE_BACKUP_DIR/openmw-0.51.before-r7"
if ! ssh "$DEV" 'bash -s' -- "$REMOTE_BIN" "$DEVICE_BACKUP_DIR" "$DEVICE_BACKUP" "$EXPECTED_R6_SHA" <<'REMOTE_BACKUP_R6_DEVICE'
set -u
BIN="$1"; DIR="$2"; BACKUP="$3"; EXPECTED="$4"
if ! mkdir -p "$DIR"; then echo "FAIL creating R7 device backup dir: $DIR" >&2; exit 1; fi
LIVE="$(sha256sum "$BIN" | awk '{print $1}')"
if [ "$LIVE" != "$EXPECTED" ]; then echo "FAIL device changed before R7 backup" >&2; exit 2; fi
if ! cp -f "$BIN" "$BACKUP"; then echo "FAIL copying R7 device backup" >&2; exit 3; fi
BACK="$(sha256sum "$BACKUP" | awk '{print $1}')"
if [ "$BACK" != "$EXPECTED" ]; then echo "FAIL R7 device backup SHA mismatch" >&2; exit 4; fi
echo "PASS exact R6 device backup: $BACKUP"
REMOTE_BACKUP_R6_DEVICE
then
    fail 45 "failed to back up exact R6 device"
fi

# ---------------------------------------------------------------------------
# Generate and validate structural patcher BEFORE mutating source.
# ---------------------------------------------------------------------------
echo
echo "===== 3/8 VALIDATE R7 PATCHER BEFORE SOURCE MUTATION ====="
cat > "$TMP/patch_r7.py" <<'PY_PATCH'
#!/usr/bin/env python3
import sys

R6_MARK = 'TSP_ROOM_LIGHT_PLAYER_KEEP_051_V30_R6'
R7_MARK = 'TSP_ROOM_NEARFIELD_CORRECTNESS_051_V30_R7'
R6D1_MARK = 'TSP_ROOM_OBJECT_SNAPSHOT_DIAG_051_R6D1'
FUNC_SIG = 'void Scene::tspUpdateRoomObjectLifecycle(float duration)'
LOG_TOKEN = '[TSP_ROOMOBJ_V30] lightNearXY=1560 lightNearZ=192'


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
            if ch == '\n': line_comment = False
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
            if escaped: escaped = False
            elif ch == '\\': escaped = True
            elif ch == '"': in_string = False
            i += 1
            continue
        if in_char:
            if escaped: escaped = False
            elif ch == '\\': escaped = True
            elif ch == "'": in_char = False
            i += 1
            continue
        if ch == '/' and nxt == '/':
            line_comment = True; i += 2; continue
        if ch == '/' and nxt == '*':
            block_comment = True; i += 2; continue
        if ch == '"': in_string = True; i += 1; continue
        if ch == "'": in_char = True; i += 1; continue
        if ch == '{': depth += 1
        elif ch == '}':
            depth -= 1
            if depth == 0: return i
        i += 1
    raise RuntimeError('matching closing brace not found')


def function_range(text, signature):
    count = text.count(signature)
    if count != 1:
        raise RuntimeError('%s count=%d expected 1' % (signature, count))
    start = text.index(signature)
    opening = text.find('{', start + len(signature))
    if opening < 0:
        raise RuntimeError('function opening brace not found')
    closing = matching_brace(text, opening)
    return start, closing + 1


def line_start(text, pos):
    return text.rfind('\n', 0, pos) + 1


def line_end(text, pos):
    e = text.find('\n', pos)
    return len(text) if e < 0 else e + 1


def indent_at(text, pos):
    s = line_start(text, pos)
    raw = text[s:pos]
    if raw.strip():
        # pos may point inside a token; derive leading whitespace from whole line.
        line = text[s:line_end(text, pos)]
        return line[:len(line) - len(line.lstrip(' \t'))]
    return raw


def patch_scene(sc):
    if sc.count(R6_MARK) != 1:
        raise RuntimeError('R6 marker count=%d expected 1' % sc.count(R6_MARK))
    if R6D1_MARK in sc:
        raise RuntimeError('R6D1 diagnostic marker still present; restore exact R6 first')
    if R7_MARK in sc:
        raise RuntimeError('R7 marker already present; refusing ambiguous re-application')
    if sc.count(LOG_TOKEN) != 1:
        raise RuntimeError('R6 aggregate log token count=%d expected 1' % sc.count(LOG_TOKEN))

    fs, fe = function_range(sc, FUNC_SIG)
    func = sc[fs:fe]
    if R6_MARK not in func:
        raise RuntimeError('R6 light block is not inside object lifecycle function')

    # Add function-local player position and telemetry counters after inactive counter.
    counter_token = 'int inactive = 0;'
    positions = []
    p = 0
    while True:
        p = func.find(counter_token, p)
        if p < 0: break
        positions.append(p)
        p += len(counter_token)
    if len(positions) != 1:
        raise RuntimeError('inactive counter matches=%d expected 1' % len(positions))
    cp = positions[0]
    ce = line_end(func, cp)
    ci = indent_at(func, cp)
    setup = (
        ci + '// ' + R7_MARK + '\n'
        + ci + '// Topology remains the primary culling authority, but nearby ordinary clutter\n'
        + ci + '// gets a direct player-relative correctness floor. Hysteresis keeps a live\n'
        + ci + '// object resident farther than the distance required to wake a parked object.\n'
        + ci + 'const osg::Vec3f tspRoomNearFieldPlayer = MWBase::Environment::get().getWorld()\n'
        + ci + '    ->getPlayerPtr().getRefData().getPosition().asVec3();\n'
        + ci + 'int tspRoomNearWakeProtect = 0;\n'
        + ci + 'int tspRoomNearHoldProtect = 0;\n'
    )
    func = func[:ce] + setup + func[ce:]

    r6pos = func.find('// ' + R6_MARK)
    if r6pos < 0:
        raise RuntimeError('R6 marker line not found after setup insertion')

    # Find the FINAL lifecycle if (shouldLive) without assuming indentation.
    decision_token = func.find('if (shouldLive)', r6pos)
    if decision_token < 0:
        raise RuntimeError('final if (shouldLive) not found after R6 light block')
    decision_line = line_start(func, decision_token)
    di = indent_at(func, decision_token)

    safety = (
        di + '// ' + R7_MARK + '\n'
        + di + 'if (!shouldLive && ptr.getType() != ESM::REC_LIGH)\n'
        + di + '{\n'
        + di + '    constexpr float tspNearWakeXY = 1100.f;\n'
        + di + '    constexpr float tspNearWakeZ = 320.f;\n'
        + di + '    constexpr float tspNearHoldXY = 1450.f;\n'
        + di + '    constexpr float tspNearHoldZ = 384.f;\n'
        + di + '    const bool tspWasParked\n'
        + di + '        = mTspRoomSuppressedRefs.find(refnum) != mTspRoomSuppressedRefs.end();\n'
        + di + '    const float tspNearXY = tspWasParked ? tspNearWakeXY : tspNearHoldXY;\n'
        + di + '    const float tspNearZ = tspWasParked ? tspNearWakeZ : tspNearHoldZ;\n'
        + di + '    const float tspDx = origin.x() - tspRoomNearFieldPlayer.x();\n'
        + di + '    const float tspDy = origin.y() - tspRoomNearFieldPlayer.y();\n'
        + di + '    const float tspDz = origin.z() - tspRoomNearFieldPlayer.z();\n'
        + di + '    if (tspDx * tspDx + tspDy * tspDy <= tspNearXY * tspNearXY\n'
        + di + '        && tspDz >= -tspNearZ && tspDz <= tspNearZ)\n'
        + di + '    {\n'
        + di + '        shouldLive = true;\n'
        + di + '        if (tspWasParked)\n'
        + di + '            ++tspRoomNearWakeProtect;\n'
        + di + '        else\n'
        + di + '            ++tspRoomNearHoldProtect;\n'
        + di + '    }\n'
        + di + '}\n\n'
    )
    func = func[:decision_line] + safety + func[decision_line:]

    # Append counts to the aggregate Log(Debug::Info) statement structurally.
    # Do not assume the R6 marker occupies an entire C++ string literal.
    marker_count = func.count(LOG_TOKEN)
    if marker_count != 1:
        raise RuntimeError(
            'aggregate log token matches=%d expected 1 inside lifecycle function'
            % marker_count
        )

    mp = func.index(LOG_TOKEN)

    log_start = func.rfind('Log(Debug::Info)', 0, mp)
    if log_start < 0:
        raise RuntimeError(
            'aggregate Log(Debug::Info) start not found before R6 object marker'
        )

    log_end = func.find(';', mp)
    if log_end < 0:
        raise RuntimeError(
            'aggregate Log(Debug::Info) semicolon not found after R6 object marker'
        )

    li = indent_at(func, log_start)
    log_extra = (
        '\n' + li + '    << " nearWake=" << tspRoomNearWakeProtect'
        + '\n' + li + '    << " nearHold=" << tspRoomNearHoldProtect'
    )

    func = func[:log_end] + log_extra + func[log_end:]

    sc = sc[:fs] + func + sc[fe:]

    required = (
        R6_MARK,
        R7_MARK,
        'tspNearWakeXY = 1100.f',
        'tspNearWakeZ = 320.f',
        'tspNearHoldXY = 1450.f',
        'tspNearHoldZ = 384.f',
        'ptr.getType() != ESM::REC_LIGH',
        'mTspRoomSuppressedRefs.find(refnum)',
        'tspRoomNearWakeProtect',
        'tspRoomNearHoldProtect',
        'nearWake=',
        'nearHold=',
        '[TSP_ROOMOBJ_V30] lightNearXY=1560 lightNearZ=192',
    )
    for token in required:
        if token not in sc:
            raise RuntimeError('R7 postcondition missing: ' + token)
    if sc.count(R7_MARK) != 2:
        raise RuntimeError('R7 marker count=%d expected 2' % sc.count(R7_MARK))
    return sc


def sample(final_indent):
    f = final_indent
    return '''\n    void Scene::tspUpdateRoomObjectLifecycle(float duration)\n    {\n        int eligible = 0;\n        int resident = 0;\n        int inactive = 0;\n\n        mCurrentCell->forEach([&](const Ptr& ptr) {\n            const ESM::RefNum refnum = ptr.getCellRef().getRefNum();\n            const osg::Vec3f origin = ptr.getRefData().getPosition().asVec3();\n            // TSP_ROOM_LIGHT_PLAYER_KEEP_051_V30_R6\n            constexpr float tspRoomLightNearXY = 1560.f;\n            constexpr float tspRoomLightNearZ = 192.f;\n            bool shouldLive = MWRender::isInteriorTopologyObjectResident(\n                origin, 0.f, false);\n            if (!shouldLive && ptr.getType() == ESM::REC_LIGH)\n            {\n                const osg::Vec3f playerOrigin = MWBase::Environment::get().getWorld()\n                    ->getPlayerPtr().getRefData().getPosition().asVec3();\n                const float dx = origin.x() - playerOrigin.x();\n                const float dy = origin.y() - playerOrigin.y();\n                const float dz = origin.z() - playerOrigin.z();\n                if (dx * dx + dy * dy <= tspRoomLightNearXY * tspRoomLightNearXY\n                    && dz * dz <= tspRoomLightNearZ * tspRoomLightNearZ)\n                    shouldLive = true;\n            }\n\n''' + f + '''if (shouldLive)\n                ++resident;\n            else\n                ++inactive;\n            return true;\n        });\n        Log(Debug::Info)\n            << "[TSP_ROOMOBJ_V30] lightNearXY=1560 lightNearZ=192 pvs=" << 1;\n    }\n'''


def selftest():
    # Test both normal indentation and the real R6 splice shape that may place
    # the final if (shouldLive) at column zero.
    for final_indent in ('            ', ''):
        patched = patch_scene(sample(final_indent))
        assert patched.count(R7_MARK) == 2
        assert 'tspNearWakeXY = 1100.f' in patched
        assert 'tspNearHoldXY = 1450.f' in patched
        assert 'ptr.getType() != ESM::REC_LIGH' in patched
        assert 'nearWake=' in patched and 'nearHold=' in patched
        assert '"[TSP_ROOMOBJ_V30] lightNearXY=1560 lightNearZ=192"' not in sample(final_indent)
        assert patched.index(R7_MARK) < patched.index('if (shouldLive)', patched.index(R6_MARK))
    print('PASS R7 structural patcher selftest: indented + column-zero final decision')


if len(sys.argv) == 2 and sys.argv[1] == '--selftest':
    selftest()
    raise SystemExit(0)
if len(sys.argv) != 2:
    raise SystemExit('usage: patch_r7.py SCENE_CPP | --selftest')

path = sys.argv[1]
text = patch_scene(read(path))
write(path, text)
print('PASS R7 near-field correctness patch applied')
PY_PATCH

if ! python3 -m py_compile "$TMP/patch_r7.py"; then
    fail 46 "embedded R7 Python patcher does not compile"
fi
if ! python3 "$TMP/patch_r7.py" --selftest; then
    fail 47 "R7 structural patcher selftest failed"
fi
echo "PASS R7 patcher validated before touching Docker source"

# ---------------------------------------------------------------------------
# Apply and source-verify.
# ---------------------------------------------------------------------------
echo
echo "===== 4/8 APPLY R7 SOURCE PATCH ====="
if ! docker cp "$TMP/patch_r7.py" "$CTR:/tmp/patch_r7.py" >/dev/null; then
    fail 48 "failed to copy R7 patcher into Docker"
fi
SOURCE_MUTATED=1
if ! docker exec "$CTR" python3 /tmp/patch_r7.py "$SCENE_CPP"; then
    fail 49 "R7 C++ source patch failed"
fi

if ! docker exec -i "$CTR" bash -s -- "$SCENE_CPP" "$VIS_CPP" <<'REMOTE_VERIFY_R7_SOURCE'
set -u
SCENE="$1"; VIS="$2"
check_has() {
    local token="$1" file="$2" label="$3"
    if ! grep -Fq -- "$token" "$file"; then
        echo "FAIL $label" >&2; echo "FILE: $file" >&2; echo "EXPECTED: $token" >&2; exit 1
    fi
    echo "PASS $label"
}
check_absent() {
    local token="$1" file="$2" label="$3"
    if grep -Fq -- "$token" "$file"; then
        echo "FAIL $label" >&2; echo "FILE: $file" >&2; echo "FORBIDDEN: $token" >&2; exit 2
    fi
    echo "PASS $label"
}
check_has 'TSP_ROOM_NEARFIELD_CORRECTNESS_051_V30_R7' "$SCENE" 'R7 source marker'
check_has 'tspNearWakeXY = 1100.f' "$SCENE" 'R7 wake XY'
check_has 'tspNearWakeZ = 320.f' "$SCENE" 'R7 wake Z'
check_has 'tspNearHoldXY = 1450.f' "$SCENE" 'R7 hold XY'
check_has 'tspNearHoldZ = 384.f' "$SCENE" 'R7 hold Z'
check_has 'ptr.getType() != ESM::REC_LIGH' "$SCENE" 'R7 ordinary-only safety net'
check_has 'mTspRoomSuppressedRefs.find(refnum)' "$SCENE" 'R7 hysteresis parked-state check'
check_has 'TSP_ROOM_LIGHT_PLAYER_KEEP_051_V30_R6' "$SCENE" 'R6 light rule preserved'
check_has 'tspRoomLightNearXY = 1560.f' "$SCENE" 'R6 light XY preserved'
check_has 'tspRoomLightNearZ = 192.f' "$SCENE" 'R6 light Z preserved'
check_has 'TSP_ROOM_OBJECT_FLOOR_AUTHORITY_051_V30' "$VIS" 'V30 floor authority preserved'
check_absent 'TSP_ROOM_OBJECT_SNAPSHOT_DIAG_051_R6D1' "$SCENE" 'R6D1 heavy diagnostics absent from R7'
REMOTE_VERIFY_R7_SOURCE
then
    fail 50 "R7 post-patch source verification failed"
fi

# ---------------------------------------------------------------------------
# Rebuild exactly one directly changed TU.
# ---------------------------------------------------------------------------
echo
echo "===== 5/8 INVALIDATE SCENE OBJECT + BUILD ====="
if ! docker exec -i "$CTR" bash -s -- "$BUILD" "$SCENE_CPP" <<'REMOTE_INVALIDATE_R7'
set -u
BUILD="$1"; SCENE="$2"
OBJ="$BUILD/apps/openmw/CMakeFiles/openmw-lib.dir/mwworld/scene.cpp.o"
rm -f "$OBJ" "$OBJ.d"
touch "$SCENE"
if [ -e "$OBJ" ]; then echo "FAIL scene.cpp.o survived R7 invalidation: $OBJ" >&2; exit 1; fi
echo "PASS invalidated scene.cpp.o"
REMOTE_INVALIDATE_R7
then
    fail 51 "failed to invalidate scene.cpp.o for R7"
fi

: > "$BUILD_LOG"
if ! docker exec "$CTR" cmake --build "$BUILD" --target openmw --parallel 1 2>&1 | tee "$BUILD_LOG"; then
    echo
    echo "===== R7 BUILD FAILURE TAIL ====="
    tail -280 "$BUILD_LOG" || true
    fail 52 "R7 build failed; full log: $BUILD_LOG"
fi
if ! grep -Fq 'scene.cpp.o' "$BUILD_LOG"; then
    fail 53 "R7 build log does not prove scene.cpp.o recompiled: $BUILD_LOG"
fi
echo "PASS build log proves recompile: scene.cpp.o"

# ---------------------------------------------------------------------------
# Package / copy / verify with multiple non-marker checks.
# ---------------------------------------------------------------------------
echo
echo "===== 6/8 PACKAGE + COPY OUT + MULTI-VERIFY ====="
if ! docker exec -i "$CTR" bash -s -- "$BUILT" "$PACKAGED" <<'REMOTE_PACKAGE_R7'
set -u
BUILT="$1"; PACKAGED="$2"
if [ ! -s "$BUILT" ]; then echo "FAIL rebuilt R7 binary missing/empty: $BUILT" >&2; exit 1; fi
if ! mkdir -p "$(dirname "$PACKAGED")"; then echo "FAIL cannot create package dir" >&2; exit 2; fi
if ! install -m 755 "$BUILT" "$PACKAGED"; then echo "FAIL packaging R7 binary: $PACKAGED" >&2; exit 3; fi
file "$PACKAGED"
sha256sum "$PACKAGED"
REMOTE_PACKAGE_R7
then
    fail 54 "failed to package R7 binary"
fi

if ! docker cp "$CTR:$PACKAGED" "$HOST_BIN" >/dev/null; then
    fail 55 "Docker -> Ubuntu copy failed: $HOST_BIN"
fi
if [ ! -s "$HOST_BIN" ]; then fail 56 "Ubuntu R7 binary missing/empty: $HOST_BIN"; fi
DESC="$(file "$HOST_BIN" 2>/dev/null || true)"
echo "$DESC"
if ! printf '%s\n' "$DESC" | grep -Eq 'ARM aarch64|ARM64|AArch64'; then
    fail 57 "Ubuntu R7 binary is not ARM64/AArch64: $DESC"
fi
NEW_SHA="$(sha256sum "$HOST_BIN" | awk '{print $1}')"
if [ -z "$NEW_SHA" ]; then fail 58 "could not calculate R7 host SHA"; fi
if [ "$NEW_SHA" = "$EXPECTED_R6_SHA" ]; then
    fail 59 "R7 rebuilt binary SHA unexpectedly equals R6 despite semantic source change"
fi
echo "PASS R7 ARM64 binary SHA: $NEW_SHA"

# ---------------------------------------------------------------------------
# Install exact copied binary; no marker-only binary gate.
# ---------------------------------------------------------------------------
echo
echo "===== 7/8 UPLOAD + INSTALL EXACT R7 SHA ====="
if ! scp -q "$HOST_BIN" "$DEV:$REMOTE_TMP_BIN"; then
    fail 60 "failed to upload R7 binary: $REMOTE_TMP_BIN"
fi
DEVICE_DEPLOY_STARTED=1
if ! ssh "$DEV" 'bash -s' -- "$REMOTE_TMP_BIN" "$REMOTE_BIN" "$NEW_SHA" <<'REMOTE_INSTALL_R7'
set -u
TMPBIN="$1"; BIN="$2"; EXPECTED="$3"
if [ ! -s "$TMPBIN" ]; then echo "FAIL uploaded R7 binary missing: $TMPBIN" >&2; exit 1; fi
INCOMING="$(sha256sum "$TMPBIN" | awk '{print $1}')"
if [ "$INCOMING" != "$EXPECTED" ]; then
    echo "FAIL uploaded R7 SHA mismatch" >&2; echo "EXPECTED: $EXPECTED" >&2; echo "ACTUAL: $INCOMING" >&2; exit 2
fi
if ! install -m 755 "$TMPBIN" "$BIN"; then echo "FAIL installing R7 binary: $BIN" >&2; exit 3; fi
rm -f "$TMPBIN"
sync
FINAL="$(sha256sum "$BIN" | awk '{print $1}')"
if [ "$FINAL" != "$EXPECTED" ]; then
    echo "FAIL installed R7 SHA mismatch" >&2; echo "EXPECTED: $EXPECTED" >&2; echo "ACTUAL: $FINAL" >&2; exit 4
fi
echo "PASS installed exact R7 SHA: $FINAL"
REMOTE_INSTALL_R7
then
    fail 61 "R7 device install/verification failed"
fi

FINAL_DEVICE_SHA="$(ssh "$DEV" "sha256sum '$REMOTE_BIN' | awk '{print \$1}'" 2>/dev/null || true)"
if [ "$FINAL_DEVICE_SHA" != "$NEW_SHA" ]; then
    echo "EXPECTED R7: $NEW_SHA" >&2; echo "DEVICE R7:   $FINAL_DEVICE_SHA" >&2
    fail 62 "final device SHA verification failed"
fi
LUA_SHA_AFTER="$(ssh "$DEV" "sha256sum '$LIVE_LUA' | awk '{print \$1}'" 2>/dev/null || true)"
if [ "$LUA_SHA_AFTER" != "$LUA_SHA_BEFORE" ]; then
    echo "LUA BEFORE: $LUA_SHA_BEFORE" >&2; echo "LUA AFTER:  $LUA_SHA_AFTER" >&2
    fail 63 "R4 Lua changed unexpectedly during R7 binary install"
fi

# Arm a clean runtime collection window.
if ! ssh "$DEV" 'bash -s' -- "$REMOTE_LOG" "$R7_ARM_FILE" <<'REMOTE_ARM_R7'
set -u
LOG="$1"; ARM="$2"
if [ ! -f "$LOG" ]; then echo "FAIL R7 arm log missing: $LOG" >&2; exit 1; fi
LINES="$(wc -l < "$LOG" | tr -d '[:space:]')"
case "$LINES" in ''|*[!0-9]*) echo "FAIL invalid R7 arm line count: $LINES" >&2; exit 2;; esac
if ! printf '%s\n' "$LINES" > "$ARM"; then echo "FAIL writing R7 arm file: $ARM" >&2; exit 3; fi
echo "PASS R7 capture armed after log line: $LINES"
REMOTE_ARM_R7
then
    fail 64 "failed to arm R7 runtime collection"
fi

# ---------------------------------------------------------------------------
# Save rollback state only after successful exact deployment.
# ---------------------------------------------------------------------------
echo
echo "===== 8/8 SAVE STATE + FINAL REPORT ====="
cat > "$STATE" <<EOF_STATE
R7_SOURCE_BACKUP='$SOURCE_BACKUP'
R7_DEVICE_BACKUP='$DEVICE_BACKUP'
R7_OLD_DEVICE_SHA='$EXPECTED_R6_SHA'
R7_NEW_DEVICE_SHA='$NEW_SHA'
R7_HOST_BIN='$HOST_BIN'
R7_LUA_SHA='$LUA_SHA_AFTER'
EOF_STATE
if [ ! -s "$STATE" ]; then fail 65 "R7 state file was not written: $STATE"; fi

SOURCE_MUTATED=0
DEVICE_DEPLOY_STARTED=0

echo "============================================================"
echo "V30 R7 NEAR-FIELD CORRECTNESS INSTALLED"
echo "============================================================"
echo "R6 baseline SHA: $EXPECTED_R6_SHA"
echo "R7 binary SHA:   $NEW_SHA"
echo "R4 Lua SHA:      $LUA_SHA_AFTER"
echo "Host binary:     $HOST_BIN"
echo "State:           $STATE"
echo
echo "Test the SAME three bad locations once:"
echo "  1. Moonmoth Legion Fort, Prison Towers chest from the entrance hall"
echo "  2. Balmora Guild of Mages staircase clutter"
echo "  3. Balmora Guild of Mages apothecary room clutter"
echo
echo "Then collect:"
echo "  cd ~/Downloads"
echo "  ./apply_openmw51_tsp_roomwake_v30_R7_nearfield_correctness.sh collect"
echo
echo "Rollback:"
echo "  ./apply_openmw51_tsp_roomwake_v30_R7_nearfield_correctness.sh rollback"
echo "============================================================"
