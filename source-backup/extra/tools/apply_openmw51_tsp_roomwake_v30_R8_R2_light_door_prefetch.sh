#!/usr/bin/env bash
# OpenMW 0.51 / TrimUI Smart Pro
# V30 R8-R2: minimal R7 tuning for Ald-ruhn lights + doorway clutter reveal.
# Actions: install (default), collect, rollback.

set -u -o pipefail

ACTION="${1:-install}"
CTR="${OPENMW_CONTAINER:-openmw_builder}"
DEV="${TSP_DEVICE:-root@192.168.1.12}"

SRC="/root/openmw-0.51-tsp-src"
BUILD="/root/openmw-0.51-tsp-build"
PACKAGE="/root/openmw-0.51-tsp-package"
SCENE="$SRC/apps/openmw/mwworld/scene.cpp"
BUILT="$BUILD/openmw"
PACKAGED="$PACKAGE/bin/openmw-0.51"

ROOT="/mnt/SDCARD/data/ports/openmw51"
BIN="$ROOT/bin/openmw-0.51"
LUA="$ROOT/mods/TSPInteriorVisGrid/scripts/TSPInteriorVisGrid/visgrid.lua"
GAMELOG="$ROOT/openmw_051_log.txt"
PERF="$ROOT/openmw51_perf_latest.txt"
TMPBIN="/tmp/openmw-0.51.r8r2"
ARM="$ROOT/roomwake-r8r2-capture-start.line"

EXPECTED_R7_SHA="e453e211dae659e669449d4ac7348059170b875bdbe850d26a28ec7853988cc7"

DL="$HOME/Downloads"
STAMP="$(date +%Y%m%d-%H%M%S)"
RUNLOG="$DL/openmw51-roomwake-r8r2-$STAMP.log"
BUILDLOG="$DL/openmw51-roomwake-r8r2-build-$STAMP.log"
STATE="$DL/openmw51-roomwake-r8r2.state"
HOSTBIN="$DL/openmw-0.51-v30-r8r2-light-door-prefetch"
TMP="$(mktemp -d "$DL/.roomwake-r8r2.XXXXXX")"

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
        echo "FAIL source rollback path empty" >&2
        return 1
    fi
    if ! docker exec -i "$CTR" bash -s -- "$SOURCE_BACKUP" "$SCENE" "$BUILD" <<'REMOTE_RESTORE_SOURCE'
set -u
BACKUP="$1"
SCENE="$2"
BUILD="$3"
OBJ="$BUILD/apps/openmw/CMakeFiles/openmw-lib.dir/mwworld/scene.cpp.o"

if [ ! -s "$BACKUP/scene.cpp" ]; then
    echo "FAIL rollback source missing: $BACKUP/scene.cpp" >&2
    exit 1
fi
if ! cp -f "$BACKUP/scene.cpp" "$SCENE"; then
    echo "FAIL restoring R7 scene.cpp" >&2
    exit 2
fi
touch "$SCENE"
rm -f "$OBJ" "$OBJ.d"
echo "PASS source rollback restored pre-R8 R7 scene.cpp"
REMOTE_RESTORE_SOURCE
    then
        return 1
    fi
    return 0
}

restore_device() {
    if [ -z "$DEVICE_BACKUP" ]; then
        echo "FAIL device rollback path empty" >&2
        return 1
    fi
    if ! ssh "$DEV" 'bash -s' -- "$DEVICE_BACKUP" "$BIN" "$EXPECTED_R7_SHA" <<'REMOTE_RESTORE_DEVICE'
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
    echo "FAIL restoring R7 binary" >&2
    exit 3
fi
sync
FINAL="$(sha256sum "$BIN" | awk '{print $1}')"
if [ "$FINAL" != "$EXPECTED" ]; then
    echo "FAIL restored R7 SHA expected=$EXPECTED actual=$FINAL" >&2
    exit 4
fi
echo "PASS exact R7 device restored: $FINAL"
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
        echo "===== R8-R2 FAILURE RECOVERY ====="
        if [ "$DEVICE_DEPLOYED" -eq 1 ]; then
            echo "INFO: restoring exact R7 device binary..."
            restore_device || echo "WARNING: automatic device rollback failed" >&2
        fi
        if [ "$SOURCE_MUTATED" -eq 1 ]; then
            echo "INFO: restoring exact R7 Docker source..."
            restore_source || echo "WARNING: automatic source rollback failed" >&2
        fi
    fi
    cleanup
    exit "$rc"
}
trap on_exit EXIT

collect_action() {
    ensure_ssh
    local out="$DL/openmw51-roomwake-r8r2-validation-$STAMP.txt"

    if ! ssh "$DEV" 'bash -s' -- "$GAMELOG" "$PERF" "$BIN" "$LUA" "$ARM" > "$out" <<'REMOTE_COLLECT'
set -u
LOG="$1"
PERF="$2"
BIN="$3"
LUA="$4"
ARM="$5"

echo "===== OPENMW 0.51 V30 R8-R2 VALIDATION ====="
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
    | grep -E 'Loading cell|Changing to interior|\[TSP_ROOMOBJ_V30\]|\[TSP_VISGRID_V30_R4\]|\[TSP_ACTOR_V30\]|failed to render' \
    || true

echo
echo "===== PERF TAIL ====="
if [ -f "$PERF" ]; then tail -120 "$PERF" 2>/dev/null || true; fi
REMOTE_COLLECT
    then
        fail 20 "R8-R2 collect failed"
    fi

    echo "Saved: $out"
}

rollback_action() {
    ensure_docker
    ensure_ssh

    if [ ! -s "$STATE" ]; then
        fail 21 "rollback state missing: $STATE"
    fi

    # shellcheck disable=SC1090
    . "$STATE"

    if [ -z "${R8R2_SOURCE_BACKUP:-}" ] || [ -z "${R8R2_DEVICE_BACKUP:-}" ]; then
        fail 22 "rollback state incomplete: $STATE"
    fi
    if [ "${R8R2_OLD_SHA:-}" != "$EXPECTED_R7_SHA" ]; then
        fail 23 "rollback state was not created from exact R7"
    fi

    SOURCE_BACKUP="$R8R2_SOURCE_BACKUP"
    DEVICE_BACKUP="$R8R2_DEVICE_BACKUP"

    restore_source || fail 24 "manual source rollback failed"
    restore_device || fail 25 "manual device rollback failed"

    echo "PASS R8-R2 rollback complete; exact R7 restored."
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
    *)
        fail 2 "usage: $0 [install|collect|rollback]"
        ;;
esac

exec > >(tee "$RUNLOG") 2>&1

cat <<'BANNER'
============================================================
OPENMW 0.51 — ROOMWAKE V30 R8-R2
LIGHT RANGE + DOORWAY PREFETCH TUNING
============================================================
R4 Lua topology policy: unchanged.
Actors: unchanged.

LIGHT fallback:
  R7: XY 1560, |Z| 192
  R8: XY 2800, |Z| 384

ORDINARY eligible clutter:
  parked wake XY: 1100 -> 1450
  live hold XY:   1450 -> 1800
  Z bands remain 320 wake / 384 hold

No whole-room or whole-floor force-wake.
============================================================
BANNER

need python3
need sha256sum
need file
ensure_docker
ensure_ssh

if ssh "$DEV" "pgrep -af 'openmw-0\\.51|/openmw([[:space:]]|$)'" 2>/dev/null \
    | grep -v pgrep >/dev/null 2>&1; then
    fail 30 "OpenMW appears to be running; exit the game first"
fi

echo
echo "===== 1/7 VERIFY EXACT TESTED R7 BASELINE ====="

LIVE_SHA="$(ssh "$DEV" "sha256sum '$BIN' | awk '{print \$1}'" 2>/dev/null || true)"
if [ "$LIVE_SHA" != "$EXPECTED_R7_SHA" ]; then
    echo "EXPECTED R7: $EXPECTED_R7_SHA" >&2
    echo "ACTUAL:      $LIVE_SHA" >&2
    fail 31 "device is not on exact tested R7"
fi
echo "PASS exact R7 device SHA: $LIVE_SHA"

if ! ssh "$DEV" "grep -Fq 'TSP_VISGRID_V30_R4' '$LUA'"; then
    fail 32 "live Lua is not R4"
fi

LUA_SHA_BEFORE="$(ssh "$DEV" "sha256sum '$LUA' | awk '{print \$1}'" 2>/dev/null || true)"
if [ -z "$LUA_SHA_BEFORE" ]; then
    fail 33 "could not read live R4 Lua SHA"
fi
echo "PASS live R4 Lua SHA: $LUA_SHA_BEFORE"

if ! docker exec -i "$CTR" python3 - "$SCENE" <<'PY_PREFLIGHT'
import sys
p=sys.argv[1]
with open(p,'r',encoding='utf-8') as f:
    s=f.read()

required = [
    'TSP_ROOM_LIGHT_PLAYER_KEEP_051_V30_R6',
    'TSP_ROOM_NEARFIELD_CORRECTNESS_051_V30_R7',
    'tspRoomLightNearXY = 1560.f',
    'tspRoomLightNearZ = 192.f',
    'tspNearWakeXY = 1100.f',
    'tspNearWakeZ = 320.f',
    'tspNearHoldXY = 1450.f',
    'tspNearHoldZ = 384.f',
    'lightNearXY=1560 lightNearZ=192',
    'nearWake=',
    'nearHold=',
]
for token in required:
    if token not in s:
        raise SystemExit('FAIL missing R7 source token: '+token)

if 'TSP_ROOM_RANGE_TUNE_051_V30_R8R2' in s:
    raise SystemExit('FAIL R8-R2 already present')

for token in (
    'tspRoomLightNearXY = 1560.f',
    'tspRoomLightNearZ = 192.f',
    'tspNearWakeXY = 1100.f',
    'tspNearHoldXY = 1450.f',
    'lightNearXY=1560 lightNearZ=192',
):
    c=s.count(token)
    if c != 1:
        raise SystemExit('FAIL token count=%d expected 1: %s' % (c,token))

print('PASS exact R7 source shape for minimal R8-R2 tuning')
PY_PREFLIGHT
then
    fail 34 "Docker source is not expected R7"
fi

echo
echo "===== 2/7 BACK UP CURRENT R7 SOURCE + DEVICE ====="

SOURCE_BACKUP="$SRC/.tsp-051-source-backups/roomwake-v30-r8r2-$STAMP"

if ! docker exec -i "$CTR" bash -s -- "$SOURCE_BACKUP" "$SCENE" <<'REMOTE_BACKUP_SOURCE'
set -u
BACKUP="$1"
SCENE="$2"

if ! mkdir -p "$BACKUP"; then exit 1; fi
if ! cp -f "$SCENE" "$BACKUP/scene.cpp"; then exit 2; fi
sha256sum "$BACKUP/scene.cpp"
echo "PASS source backup: $BACKUP"
REMOTE_BACKUP_SOURCE
then
    fail 40 "source backup failed"
fi

DEVICE_BACKUP="$ROOT/backups/roomwake-v30-r8r2-$STAMP/openmw-0.51.before-r8r2"

if ! ssh "$DEV" 'bash -s' -- "$BIN" "$DEVICE_BACKUP" "$EXPECTED_R7_SHA" <<'REMOTE_BACKUP_DEVICE'
set -u
BIN="$1"
BACKUP="$2"
EXPECTED="$3"

if ! mkdir -p "$(dirname "$BACKUP")"; then exit 1; fi
LIVE="$(sha256sum "$BIN" | awk '{print $1}')"
if [ "$LIVE" != "$EXPECTED" ]; then exit 2; fi
if ! cp -f "$BIN" "$BACKUP"; then exit 3; fi
BACK="$(sha256sum "$BACKUP" | awk '{print $1}')"
if [ "$BACK" != "$EXPECTED" ]; then exit 4; fi
echo "PASS exact R7 device backup: $BACKUP"
REMOTE_BACKUP_DEVICE
then
    fail 41 "device backup failed"
fi

echo
echo "===== 3/7 APPLY MINIMAL R7 -> R8-R2 SOURCE TUNING ====="

SOURCE_MUTATED=1

if ! docker exec -i "$CTR" python3 - "$SCENE" <<'PY_PATCH'
import sys

p=sys.argv[1]
with open(p,'r',encoding='utf-8',newline='') as f:
    s=f.read()

changes = [
    ('tspRoomLightNearXY = 1560.f',
     'tspRoomLightNearXY = 2800.f'),
    ('tspRoomLightNearZ = 192.f',
     'tspRoomLightNearZ = 384.f'),
    ('tspNearWakeXY = 1100.f',
     'tspNearWakeXY = 1450.f'),
    ('tspNearHoldXY = 1450.f',
     'tspNearHoldXY = 1800.f'),
    ('lightNearXY=1560 lightNearZ=192',
     'lightNearXY=2800 lightNearZ=384'),
]

for old,new in changes:
    c=s.count(old)
    if c != 1:
        raise SystemExit(
            'FAIL replacement count=%d expected 1: %s' % (c,old)
        )
    s=s.replace(old,new,1)

anchor='TSP_ROOM_NEARFIELD_CORRECTNESS_051_V30_R7'
pos=s.find(anchor)
if pos < 0:
    raise SystemExit('FAIL R7 marker disappeared during patch')

line_start=s.rfind('\n',0,pos)+1
indent=s[line_start:pos]
if indent.strip():
    line=s[line_start:s.find('\n',pos)]
    indent=line[:len(line)-len(line.lstrip(' \t'))]

marker=indent+'// TSP_ROOM_RANGE_TUNE_051_V30_R8R2\n'
s=s[:line_start]+marker+s[line_start:]

required = [
    'TSP_ROOM_RANGE_TUNE_051_V30_R8R2',
    'tspRoomLightNearXY = 2800.f',
    'tspRoomLightNearZ = 384.f',
    'tspNearWakeXY = 1450.f',
    'tspNearWakeZ = 320.f',
    'tspNearHoldXY = 1800.f',
    'tspNearHoldZ = 384.f',
    'lightNearXY=2800 lightNearZ=384',
]
for token in required:
    if token not in s:
        raise SystemExit('FAIL R8-R2 postcondition missing: '+token)

for token in (
    'tspRoomLightNearXY = 1560.f',
    'tspRoomLightNearZ = 192.f',
    'tspNearWakeXY = 1100.f',
    'lightNearXY=1560 lightNearZ=192',
):
    if token in s:
        raise SystemExit('FAIL obsolete R7 token survived: '+token)

with open(p,'w',encoding='utf-8',newline='\n') as f:
    f.write(s)

print('PASS R8-R2 minimal source tuning applied')
PY_PATCH
then
    fail 42 "R8-R2 source patch failed"
fi

if ! docker exec -i "$CTR" python3 - "$SCENE" <<'PY_VERIFY'
import sys
with open(sys.argv[1],'r',encoding='utf-8') as f:
    s=f.read()

expected = [
    'TSP_ROOM_RANGE_TUNE_051_V30_R8R2',
    'tspRoomLightNearXY = 2800.f',
    'tspRoomLightNearZ = 384.f',
    'tspNearWakeXY = 1450.f',
    'tspNearWakeZ = 320.f',
    'tspNearHoldXY = 1800.f',
    'tspNearHoldZ = 384.f',
    'nearWake=',
    'nearHold=',
    'TSP_ROOM_LIGHT_PLAYER_KEEP_051_V30_R6',
    'TSP_ROOM_NEARFIELD_CORRECTNESS_051_V30_R7',
]
for token in expected:
    if token not in s:
        raise SystemExit('FAIL source verify missing: '+token)

print('PASS R8-R2 source verification')
PY_VERIFY
then
    fail 43 "R8-R2 source verification failed"
fi

echo
echo "===== 4/7 INVALIDATE ONLY scene.cpp.o + BUILD ====="

if ! docker exec -i "$CTR" bash -s -- "$BUILD" "$SCENE" <<'REMOTE_INVALIDATE'
set -u
BUILD="$1"
SCENE="$2"
OBJ="$BUILD/apps/openmw/CMakeFiles/openmw-lib.dir/mwworld/scene.cpp.o"

rm -f "$OBJ" "$OBJ.d"
touch "$SCENE"

if [ -e "$OBJ" ]; then
    echo "FAIL scene.cpp.o survived invalidation" >&2
    exit 1
fi

echo "PASS invalidated scene.cpp.o"
REMOTE_INVALIDATE
then
    fail 50 "scene.cpp.o invalidation failed"
fi

: > "$BUILDLOG"

if ! docker exec "$CTR" cmake --build "$BUILD" --target openmw --parallel 1 \
    2>&1 | tee "$BUILDLOG"; then
    tail -280 "$BUILDLOG" || true
    fail 51 "R8-R2 build failed: $BUILDLOG"
fi

if ! grep -Fq 'scene.cpp.o' "$BUILDLOG"; then
    fail 52 "build log does not prove scene.cpp.o rebuilt"
fi

echo "PASS build log proves scene.cpp.o recompiled"

echo
echo "===== 5/7 PACKAGE + COPY OUT + VERIFY ====="

if ! docker exec -i "$CTR" bash -s -- "$BUILT" "$PACKAGED" <<'REMOTE_PACKAGE'
set -u
BUILT="$1"
PACKAGED="$2"

if [ ! -s "$BUILT" ]; then exit 1; fi
if ! mkdir -p "$(dirname "$PACKAGED")"; then exit 2; fi
if ! install -m 755 "$BUILT" "$PACKAGED"; then exit 3; fi
file "$PACKAGED"
sha256sum "$PACKAGED"
REMOTE_PACKAGE
then
    fail 53 "R8-R2 package failed"
fi

if ! docker cp "$CTR:$PACKAGED" "$HOSTBIN" >/dev/null; then
    fail 54 "Docker -> Ubuntu copy failed"
fi

if [ ! -s "$HOSTBIN" ]; then
    fail 55 "host R8-R2 binary missing"
fi

DESC="$(file "$HOSTBIN" 2>/dev/null || true)"
echo "$DESC"

if ! printf '%s\n' "$DESC" | grep -Eq 'ARM aarch64|ARM64|AArch64'; then
    fail 56 "host binary is not ARM64/AArch64"
fi

NEW_SHA="$(sha256sum "$HOSTBIN" | awk '{print $1}')"
if [ -z "$NEW_SHA" ]; then
    fail 57 "could not hash R8-R2 binary"
fi

if [ "$NEW_SHA" = "$EXPECTED_R7_SHA" ]; then
    fail 58 "R8-R2 binary SHA unexpectedly equals R7"
fi

echo "PASS R8-R2 host SHA: $NEW_SHA"

echo
echo "===== 6/7 INSTALL EXACT SHA ====="

if ! scp -q "$HOSTBIN" "$DEV:$TMPBIN"; then
    fail 60 "R8-R2 upload failed"
fi

DEVICE_DEPLOYED=1

if ! ssh "$DEV" 'bash -s' -- "$TMPBIN" "$BIN" "$NEW_SHA" <<'REMOTE_INSTALL'
set -u
TMP="$1"
BIN="$2"
EXPECTED="$3"

if [ ! -s "$TMP" ]; then exit 1; fi
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

echo "PASS installed exact R8-R2 SHA: $FINAL"
REMOTE_INSTALL
then
    fail 61 "R8-R2 device install failed"
fi

FINAL_SHA="$(ssh "$DEV" "sha256sum '$BIN' | awk '{print \$1}'" 2>/dev/null || true)"
if [ "$FINAL_SHA" != "$NEW_SHA" ]; then
    fail 62 "final device SHA verification failed"
fi

LUA_SHA_AFTER="$(ssh "$DEV" "sha256sum '$LUA' | awk '{print \$1}'" 2>/dev/null || true)"
if [ "$LUA_SHA_AFTER" != "$LUA_SHA_BEFORE" ]; then
    fail 63 "R4 Lua changed unexpectedly"
fi

echo
echo "===== 7/7 ARM CAPTURE + SAVE ROLLBACK STATE ====="

if ! ssh "$DEV" 'bash -s' -- "$GAMELOG" "$ARM" <<'REMOTE_ARM'
set -u
LOG="$1"
ARM="$2"

if [ ! -f "$LOG" ]; then exit 1; fi
LINES="$(wc -l < "$LOG" | tr -d '[:space:]')"
case "$LINES" in
    ''|*[!0-9]*) exit 2 ;;
esac

if ! printf '%s\n' "$LINES" > "$ARM"; then exit 3; fi
echo "PASS capture armed after log line: $LINES"
REMOTE_ARM
then
    fail 64 "capture arm failed"
fi

cat > "$STATE" <<EOF_STATE
R8R2_SOURCE_BACKUP='$SOURCE_BACKUP'
R8R2_DEVICE_BACKUP='$DEVICE_BACKUP'
R8R2_OLD_SHA='$EXPECTED_R7_SHA'
R8R2_NEW_SHA='$NEW_SHA'
R8R2_HOST_BIN='$HOSTBIN'
R8R2_LUA_SHA='$LUA_SHA_AFTER'
EOF_STATE

if [ ! -s "$STATE" ]; then
    fail 65 "state file was not written"
fi

SOURCE_MUTATED=0
DEVICE_DEPLOYED=0

echo
echo "============================================================"
echo "V30 R8-R2 INSTALLED"
echo "============================================================"
echo "R7 SHA:  $EXPECTED_R7_SHA"
echo "R8 SHA:  $FINAL_SHA"
echo "Lua SHA: $LUA_SHA_AFTER"
echo
echo "Test once:"
echo "  1. Ald-ruhn Manor District main-area lights from farther away"
echo "  2. Ald-ruhn Arobar Guard Quarters room contents from doorway"
echo "  3. One previously-good R7 location"
echo
echo "Collect:"
echo "  cd ~/Downloads"
echo "  ./apply_openmw51_tsp_roomwake_v30_R8_R2_light_door_prefetch.sh collect"
echo
echo "Rollback:"
echo "  ./apply_openmw51_tsp_roomwake_v30_R8_R2_light_door_prefetch.sh rollback"
echo "============================================================"
