#!/usr/bin/env bash
set -Eeuo pipefail

ACTION="${1:-install}"
DEV="${TSP_DEVICE:-root@192.168.1.25}"
ROOT="/mnt/SDCARD/data/ports/openmw51"
LUA_DIR="$ROOT/mods/TSPInteriorVisGrid/scripts/TSPInteriorVisGrid"
LIVE_LUA="$LUA_DIR/visgrid.lua"
V28_PROFILE="$LUA_DIR/v28_profiles/visgrid-v28-separate-clutter.lua"
LOG_MAIN="$ROOT/openmw_051_log.txt"
DL="$HOME/Downloads"
STATE="$DL/openmw51-visgrid-v28-force-room-publish.state"
STAMP="$(date +%Y%m%d-%H%M%S)"
LOG="$DL/openmw51-visgrid-v28-force-room-publish-$STAMP.log"
TMP="$(mktemp -d "$DL/.v28-force-room-publish.XXXXXX")"
REMOTE_BACKUP=""

cleanup() { rm -rf "$TMP" 2>/dev/null || true; }
trap cleanup EXIT

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

on_error() {
    local rc="${1:-1}"
    local line="${2:-unknown}"
    local cmd="${3:-unknown}"
    trap - ERR
    set +e
    echo
    echo "===== V28 FORCE-PUBLISH HOTFIX STOPPED (rc=$rc) ====="
    echo "FAILED LINE: $line"
    echo "FAILED COMMAND: $cmd"
    echo "Log preserved: $LOG"
    exit "$rc"
}
trap 'on_error "$?" "$LINENO" "$BASH_COMMAND"' ERR

exec > >(tee -a "$LOG") 2>&1

need_cmd() {
    local c="$1"
    if ! command -v "$c" >/dev/null 2>&1; then
        fail "required command not found: $c"
    fi
    echo "PASS command: $c"
}

need_cmd ssh
need_cmd scp
need_cmd python3
need_cmd sha256sum

ssh_ok() {
    if ! ssh -o BatchMode=yes -o ConnectTimeout=8 "$DEV" true; then
        fail "cannot reach $DEV with non-interactive SSH"
    fi
    echo "PASS SSH: $DEV"
}

game_closed() {
    if ssh "$DEV" "pgrep -af 'openmw-0\\.51|/openmw([[:space:]]|$)' 2>/dev/null" | grep -v pgrep >/dev/null 2>&1; then
        fail "OpenMW is running. Exit the game normally before applying/rolling back the Lua profile."
    fi
    echo "PASS: OpenMW is not running"
}

collect() {
    ssh_ok
    local out="$DL/openmw51-visgrid-v28-force-room-publish-validation-$STAMP.txt"
    local raw="$TMP/run.log"

    if ! ssh "$DEV" "tail -n 60000 '$LOG_MAIN' 2>/dev/null || true" > "$raw"; then
        fail "could not read $LOG_MAIN"
    fi

    {
        echo "============================================================"
        echo "OPENMW 0.51 V28 FORCE ROOM PUBLISH VALIDATION"
        echo "============================================================"
        date
        echo
        echo "===== V28F AUTHORITY ====="
        grep -E '\[TSP_VISGRID_V28F\]|\[TSP_VISGRID_V28\] clutter' "$raw" | tail -240 || true
        echo
        echo "===== HARD OBJECT LIFECYCLE ====="
        grep -E '\[TSP_ROOMOBJ_V28\]' "$raw" | tail -240 || true
        echo
        echo "===== ERRORS ====="
        grep -Ei 'Bad LiveCellRef cast|failed to render|Lua.*(error|ERROR)|V28.*bridge error' "$raw" | tail -120 || true
    } > "$out"

    echo "Saved: $out"
    echo
    grep -E '\[TSP_VISGRID_V28F\]|\[TSP_VISGRID_V28\] clutter|\[TSP_ROOMOBJ_V28\]' "$out" | tail -40 || true
}

rollback() {
    ssh_ok
    game_closed

    if [ ! -s "$STATE" ]; then
        fail "rollback state not found: $STATE"
    fi

    # shellcheck disable=SC1090
    source "$STATE"

    : "${REMOTE_BACKUP:?rollback state missing REMOTE_BACKUP}"
    : "${PRE_PROFILE_SHA:?rollback state missing PRE_PROFILE_SHA}"
    : "${PRE_LIVE_SHA:?rollback state missing PRE_LIVE_SHA}"

    ssh "$DEV" bash -s -- \
        "$REMOTE_BACKUP" "$V28_PROFILE" "$LIVE_LUA" \
        "$PRE_PROFILE_SHA" "$PRE_LIVE_SHA" <<'REMOTE_ROLLBACK'
set -Eeuo pipefail
B="$1"
PROFILE="$2"
LIVE="$3"
EXPECT_PROFILE="$4"
EXPECT_LIVE="$5"

check_file() {
    local f="$1"
    if [ ! -s "$f" ]; then
        echo "FAIL rollback missing/empty: $f" >&2
        exit 31
    fi
    echo "PASS rollback file: $f"
}

check_sha() {
    local f="$1"
    local expected="$2"
    local actual
    actual="$(sha256sum "$f" | awk '{print $1}')"
    if [ "$actual" != "$expected" ]; then
        echo "FAIL rollback SHA: $f" >&2
        echo "EXPECTED: $expected" >&2
        echo "ACTUAL:   $actual" >&2
        exit 32
    fi
    echo "PASS rollback SHA: $f = $actual"
}

check_file "$B/visgrid.profile.before"
check_file "$B/visgrid.live.before"
install -m 644 "$B/visgrid.profile.before" "$PROFILE"
install -m 644 "$B/visgrid.live.before" "$LIVE"
sync
check_sha "$PROFILE" "$EXPECT_PROFILE"
check_sha "$LIVE" "$EXPECT_LIVE"
REMOTE_ROLLBACK

    echo "Rollback complete."
}

case "$ACTION" in
    collect) collect; exit 0 ;;
    rollback) rollback; exit 0 ;;
    install) ;;
    *) fail "usage: $(basename "$0") [install|collect|rollback]" ;;
esac

ssh_ok
game_closed

echo "============================================================"
echo "OPENMW 0.51 — V28 FORCE ROOM PUBLISH HOTFIX"
echo "============================================================"
echo "Keeps the exact V25/V26 hard object remove/wake code already in the V28 binary."
echo "Fixes only the authority path: V28 room publishing is forced from onFrame."
echo "No C++ rebuild. No new object-removal implementation."
echo "============================================================"

echo
echo "===== 1/6 VERIFY CURRENT V28 PROFILE ====="

ssh "$DEV" bash -s -- "$V28_PROFILE" "$LIVE_LUA" <<'REMOTE_PREFLIGHT'
set -Eeuo pipefail
PROFILE="$1"
LIVE="$2"

check_file() {
    local f="$1"
    if [ ! -s "$f" ]; then
        echo "FAIL preflight file: $f" >&2
        exit 41
    fi
    echo "PASS file: $f"
}

check_has() {
    local token="$1"
    local f="$2"
    if ! grep -Fq -- "$token" "$f"; then
        echo "FAIL preflight marker: [$token]" >&2
        echo "FILE: $f" >&2
        exit 42
    fi
    echo "PASS marker: $token"
}

check_absent() {
    local token="$1"
    local f="$2"
    if grep -Fq -- "$token" "$f"; then
        echo "FAIL already patched marker: [$token]" >&2
        echo "FILE: $f" >&2
        exit 43
    fi
    echo "PASS absent: $token"
}

check_file "$PROFILE"
check_file "$LIVE"
check_has 'TSP_VISGRID_LUA_V28_SEPARATE_CLUTTER' "$PROFILE"
check_has 'TSP_VISGRID_LUA_V28_SEPARATE_CLUTTER' "$LIVE"
check_has 'mapState.updateTopologyPvs = function(force)' "$PROFILE"
check_has 'camera.setInteriorClutterResidency' "$PROFILE"
check_has 'local function onInit()' "$PROFILE"
check_absent 'TSP_VISGRID_V28_FORCE_ROOM_PUBLISH_051' "$PROFILE"
REMOTE_PREFLIGHT

PRE_PROFILE_SHA="$(ssh "$DEV" "sha256sum '$V28_PROFILE'" | awk '{print $1}')"
PRE_LIVE_SHA="$(ssh "$DEV" "sha256sum '$LIVE_LUA'" | awk '{print $1}')"
echo "Current profile SHA: $PRE_PROFILE_SHA"
echo "Current live SHA:    $PRE_LIVE_SHA"

echo
echo "===== 2/6 BACKUP PROFILE + LIVE LUA ====="
REMOTE_BACKUP="$ROOT/backups/visgrid-v28-force-room-publish-$STAMP"
ssh "$DEV" bash -s -- "$REMOTE_BACKUP" "$V28_PROFILE" "$LIVE_LUA" <<'REMOTE_BACKUP_BLOCK'
set -Eeuo pipefail
B="$1"
PROFILE="$2"
LIVE="$3"
mkdir -p "$B"
install -m 644 "$PROFILE" "$B/visgrid.profile.before"
install -m 644 "$LIVE" "$B/visgrid.live.before"
sha256sum "$B/visgrid.profile.before" "$B/visgrid.live.before"
REMOTE_BACKUP_BLOCK

if ! scp -q "$DEV:$V28_PROFILE" "$TMP/visgrid.v28.lua"; then
    fail "failed to pull $V28_PROFILE"
fi

if [ "$(sha256sum "$TMP/visgrid.v28.lua" | awk '{print $1}')" != "$PRE_PROFILE_SHA" ]; then
    fail "pulled V28 profile SHA does not match device profile"
fi
echo "PASS: pulled exact V28 profile"

echo
echo "===== 3/6 PATCH ONLY THE ROOM-AUTHORITY CALL SITE ====="
python3 - "$TMP/visgrid.v28.lua" "$TMP/visgrid.v28f.lua" <<'PY_PATCH'
import sys

src_path, dst_path = sys.argv[1:3]
with open(src_path, "r", encoding="utf-8", newline="") as f:
    s = f.read()

MARK = "TSP_VISGRID_V28_FORCE_ROOM_PUBLISH_051"
required = [
    "TSP_VISGRID_LUA_V28_SEPARATE_CLUTTER",
    "mapState.updateTopologyPvs = function(force)",
    "camera.setInteriorClutterResidency",
    "camera.clearInteriorClutterResidency",
    "local function onInit()\n",
]
for token in required:
    if token not in s:
        raise RuntimeError("required V28 token missing: " + token)
if MARK in s:
    raise RuntimeError("V28 force-publish marker already present")

# Sol/openmw bound functions need only be present. Do not require Lua type() to
# report exactly 'function'; that guard can incorrectly disable a valid binding.
old_bridge = """mapState.v28ClutterBridge = type(camera.setInteriorClutterResidency) == 'function'\n    and type(camera.clearInteriorClutterResidency) == 'function'"""
new_bridge = """-- TSP_VISGRID_V28_FORCE_ROOM_PUBLISH_051\nmapState.v28ClutterBridge = camera.setInteriorClutterResidency ~= nil\n    and camera.clearInteriorClutterResidency ~= nil"""
if s.count(old_bridge) != 1:
    raise RuntimeError(
        "V28 bridge declaration count=%d, expected 1" % s.count(old_bridge)
    )
s = s.replace(old_bridge, new_bridge, 1)

anchor = "local function onInit()\n"
if s.count(anchor) != 1:
    raise RuntimeError("onInit anchor count=%d, expected 1" % s.count(anchor))

wrapper = r'''-- TSP_VISGRID_V28_FORCE_ROOM_PUBLISH_051
-- The V28 heartbeat lived *inside* updateTopologyPvs(), but the function itself
-- was not guaranteed to run after Scene cleared its room authority on cell load.
-- Wrap the real per-frame handler so the adaptive room publisher runs every frame,
-- AFTER the existing fog/ray/topology work. The C++ V25/V26 hard remove/wake path
-- remains unchanged.
local tspV28ForcePublishBaseOnFrame = onFrame
mapState.v28ForcePublishNextLog = 0.0
onFrame = function(dt)
    tspV28ForcePublishBaseOnFrame(dt)

    -- Always run the actual room publisher. V28 is forced with force=true here for the proof run; this guarantees the
    -- engine mask is republished after any CellStore clear and cannot remain
    -- at clutter=0 because a signature/heartbeat call site went idle.
    mapState.updateTopologyPvs(true)

    local now = tonumber(interiorElapsed or 0.0) or 0.0
    if now >= (mapState.v28ForcePublishNextLog or 0.0) then
        mapState.v28ForcePublishNextLog = now + 1.0
        print(string.format(
            '[TSP_VISGRID_V28F] frame-publish bridge=%d topo=%d boxes=%d sector=%d active=%s',
            mapState.v28ClutterBridge and 1 or 0,
            mapState.topoCell ~= nil and 1 or 0,
            mapState.pvsBoxes ~= nil and 1 or 0,
            tonumber(mapState.topoSectorId or 0) or 0,
            tostring(mapState.v28ActiveIds or '')))
    end
end

'''
s = s.replace(anchor, wrapper + anchor, 1)

for token in (
    MARK,
    "local tspV28ForcePublishBaseOnFrame = onFrame",
    "mapState.updateTopologyPvs(true)",
    "[TSP_VISGRID_V28F] frame-publish",
    "mapState.v28ClutterBridge = camera.setInteriorClutterResidency ~= nil",
):
    if token not in s:
        raise RuntimeError("postcondition missing: " + token)

with open(dst_path, "w", encoding="utf-8", newline="\n") as f:
    f.write(s)

print("PASS: exact V28 room algorithm retained.")
print("PASS: exact V25/V26 C++ hard removal remains untouched.")
print("PASS: room publisher is now FORCED after EVERY real onFrame.")
print("PASS: bridge detection no longer depends on type(...) == 'function'.")
PY_PATCH

if command -v texlua >/dev/null 2>&1; then
    cat > "$TMP/parse-v28f.lua" <<'LUA_PARSE'
local f, e = loadfile(arg[1])
if not f then error(e) end
print("LUA_PARSE_PASS " .. arg[1])
LUA_PARSE
    if ! texlua "$TMP/parse-v28f.lua" "$TMP/visgrid.v28f.lua"; then
        fail "patched Lua failed texlua parse"
    fi
    echo "PASS: patched Lua parses with texlua"
elif command -v luac >/dev/null 2>&1; then
    if ! luac -p "$TMP/visgrid.v28f.lua"; then
        fail "patched Lua failed luac parse"
    fi
    echo "PASS: patched Lua parses with luac"
else
    echo "NOTE: no host Lua parser found; Python structural verification passed"
fi

PATCHED_SHA="$(sha256sum "$TMP/visgrid.v28f.lua" | awk '{print $1}')"
if [ "$PATCHED_SHA" = "$PRE_PROFILE_SHA" ]; then
    fail "patched Lua SHA did not change"
fi
echo "Patched Lua SHA: $PATCHED_SHA"

echo
echo "===== 4/6 INSTALL PATCHED PROFILE + LIVE LUA ====="
if ! scp -q "$TMP/visgrid.v28f.lua" "$DEV:/tmp/visgrid-v28f.lua"; then
    fail "failed to upload patched Lua"
fi

ssh "$DEV" bash -s -- \
    /tmp/visgrid-v28f.lua "$PATCHED_SHA" "$V28_PROFILE" "$LIVE_LUA" <<'REMOTE_INSTALL'
set -Eeuo pipefail
TMPFILE="$1"
EXPECTED="$2"
PROFILE="$3"
LIVE="$4"

check_sha() {
    local f="$1"
    local expected="$2"
    local label="$3"
    local actual
    if [ ! -s "$f" ]; then
        echo "FAIL install missing/empty: $label ($f)" >&2
        exit 51
    fi
    actual="$(sha256sum "$f" | awk '{print $1}')"
    if [ "$actual" != "$expected" ]; then
        echo "FAIL install SHA: $label" >&2
        echo "EXPECTED: $expected" >&2
        echo "ACTUAL:   $actual" >&2
        exit 52
    fi
    echo "PASS install SHA: $label = $actual"
}

check_has() {
    local token="$1"
    local f="$2"
    if ! grep -Fq -- "$token" "$f"; then
        echo "FAIL install marker: [$token]" >&2
        echo "FILE: $f" >&2
        exit 53
    fi
    echo "PASS install marker: $token"
}

check_sha "$TMPFILE" "$EXPECTED" "uploaded patched Lua"
check_has 'TSP_VISGRID_V28_FORCE_ROOM_PUBLISH_051' "$TMPFILE"
check_has '[TSP_VISGRID_V28F] frame-publish' "$TMPFILE"

install -m 644 "$TMPFILE" "$PROFILE"
install -m 644 "$TMPFILE" "$LIVE"
rm -f "$TMPFILE"
sync

check_sha "$PROFILE" "$EXPECTED" "installed V28 profile"
check_sha "$LIVE" "$EXPECTED" "installed live Lua"
check_has 'TSP_VISGRID_V28_FORCE_ROOM_PUBLISH_051' "$PROFILE"
check_has 'TSP_VISGRID_V28_FORCE_ROOM_PUBLISH_051' "$LIVE"
REMOTE_INSTALL

echo
echo "===== 5/6 SAVE ROLLBACK STATE ====="
cat > "$STATE" <<EOF_STATE
REMOTE_BACKUP='$REMOTE_BACKUP'
PRE_PROFILE_SHA='$PRE_PROFILE_SHA'
PRE_LIVE_SHA='$PRE_LIVE_SHA'
PATCHED_SHA='$PATCHED_SHA'
EOF_STATE
chmod 600 "$STATE"
echo "PASS state: $STATE"

echo
echo "===== 6/6 STATIC SCRIPT-SAFETY CHECK ====="
python3 - "$0" <<'PY_SCAN'
import re
import sys
from pathlib import Path

s = Path(sys.argv[1]).read_text(encoding="utf-8")
problems = []

# Reject positional parameters inside UNQUOTED heredocs. This is the exact class
# that caused the previous V28 install failure.
opener = re.compile(r"<<-?\s*([A-Za-z_][A-Za-z0-9_]*)")
for m in opener.finditer(s):
    delim = m.group(1)
    line_end = s.find("\n", m.end())
    if line_end < 0:
        continue
    body_start = line_end + 1
    em = re.search(r"(?m)^" + re.escape(delim) + r"[ \t]*$", s[body_start:])
    if not em:
        problems.append("unterminated unquoted heredoc " + delim)
        continue
    body = s[body_start:body_start + em.start()]
    pm = re.search(r"(?<!\\)\$(?:[0-9]+|[@*#?!-])|(?<!\\)\$\{(?:[0-9]+|[@*#?!-])\}", body)
    if pm:
        problems.append("unsafe positional expansion %s in unquoted heredoc %s" % (pm.group(0), delim))

if problems:
    for p in problems:
        print("FAIL script safety:", p)
    raise SystemExit(1)

print("PASS: no unsafe positional parameters in unquoted heredocs.")
PY_SCAN

echo
echo "============================================================"
echo "V28 FORCE-PUBLISH HOTFIX INSTALLED"
echo "============================================================"
echo "This did NOT replace the proven C++ object deletion mechanism."
echo "It only guarantees the existing adaptive room authority runs every frame."
echo
echo "Test Caldera staircase first. Within ~1 second you should see:"
echo "  [TSP_VISGRID_V28F] frame-publish bridge=1 topo=1 boxes=1 sector=<nonzero> ..."
echo "and then:"
echo "  [TSP_ROOMOBJ_V28] clutter=1 ... parked=<nonzero>"
echo
echo "Collect after one run:"
echo "  ./$(basename "$0") collect"
echo
echo "Rollback:"
echo "  ./$(basename "$0") rollback"
echo "============================================================"
