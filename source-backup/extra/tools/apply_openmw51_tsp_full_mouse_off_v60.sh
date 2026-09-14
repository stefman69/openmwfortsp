#!/usr/bin/env bash
set -Eeuo pipefail
set -o pipefail

C="${TSP_DOCKER:-openmw_builder}"
DEV="${TSP_DEV:-root@192.168.1.25}"

SRC="/root/openmw-0.51-tsp-src"
BUILD="/root/openmw-0.51-tsp-build"

CM="$SRC/apps/openmw/mwinput/controllermanager.cpp"
OPENMW_BIN="$BUILD/openmw"
HELPER_BIN="/root/tsp_openmw_controls-v58"

STAMP="$(date +%Y%m%d-%H%M%S)"
PKG="$HOME/Downloads/openmw51-full-mouse-off-v60-$STAMP"

REMOTE_ROOT="/mnt/SDCARD/data/ports/openmw51"
REMOTE_BIN="$REMOTE_ROOT/bin/openmw-0.51"
REMOTE_HELPER="$REMOTE_ROOT/tsp_openmw_controls"
REMOTE_BACKUP="$REMOTE_ROOT/backups/full-mouse-off-v60-$STAMP"

STATE_LOG="$PKG/logs/v60-state.log"
PATCH_LOG="$PKG/logs/v60-patch.log"
BUILD_LOG="$PKG/logs/v60-openmw-build.log"

mkdir -p \
    "$PKG/logs" \
    "$PKG/patched-source/apps/openmw/mwinput" \
    "$PKG/source-backup" \
    "$PKG/device-backup"

fail_report() {
    local rc="${1:-1}"
    local line="${2:-unknown}"
    local cmd="${3:-unknown}"

    trap - ERR
    set +e

    local report="$PKG/STOPPED_ERROR.txt"

    {
        echo
        echo "=================================================================="
        echo "V60 STOPPED SAFELY"
        echo "=================================================================="
        echo "Date: $(date)"
        echo "Exit code: $rc"
        echo "Script line: $line"
        echo "Failing command:"
        echo "  $cmd"
        echo

        for f in "$STATE_LOG" "$PATCH_LOG" "$BUILD_LOG"; do
            if [ -f "$f" ]; then
                echo
                echo "----- $(basename "$f") : LAST 200 LINES -----"
                tail -200 "$f" || true
            fi
        done

        echo
        echo "No later deploy step was intentionally run after this failure."
        echo
        echo "Everything produced so far is preserved at:"
        echo "  $PKG"
        echo
        echo "Error report:"
        echo "  $report"
        echo "=================================================================="
    } 2>&1 | tee "$report"

    echo
    echo "SCRIPT STOPPED. TERMINAL REMAINS OPEN."

    if [ -t 0 ]; then
        echo
        read -r -p "Press Enter to return to the shell... " _ || true
    fi

    exit "$rc"
}

trap 'fail_report "$?" "$LINENO" "$BASH_COMMAND"' ERR

echo "=================================================================="
echo "OPENMW 0.51 TSP FULL MOUSE-OFF V60"
echo "=================================================================="
echo
echo "V59 already makes MENU turn explicit mouse mode off."
echo
echo "V60 clears the second persistent cursor state at the same time:"
echo
echo "  mTspMouseMode=false"
echo "  mGamepadGuiCursorEnabled=false"
echo "  mGamepadMousePressed=false"
echo "  cursor active=false"
echo "  cursor visible=false"
echo
echo "Expected:"
echo "  inventory/map/etc + stick -> MOUSE -> MENU"
echo "      -> mouse/cursor completely gone"
echo "      -> ordinary controller navigation"
echo "      -> no stale mouse-hover item remaining authoritative"
echo
echo "V58 text/B behavior and V59 MENU handling remain unchanged."
echo "Settings retains its separate cursor exception."
echo
echo "This script is rerun-safe and terminal-safe."
echo

echo "===== 1/10 VERIFY CURRENT V59/V60 SOURCE STATE ====="

set +e
docker exec -i "$C" python3 <<'PYSTATE' 2>&1 | tee "$STATE_LOG"
from pathlib import Path

p = Path("/root/openmw-0.51-tsp-src/apps/openmw/mwinput/controllermanager.cpp")

if not p.is_file():
    raise SystemExit("ERROR: controllermanager.cpp missing")

s = p.read_text()

required_lineage = [
    "TSP_EXPLICIT_UI_STATE_051_V58",
    "TSP_MOUSE_MENU_OFF_051_V59",
    "menu=press action=mouse-off-consumed",
    "TSP_NO_STICKCLICK_MODES_051_V54",
    "TSP_CHORD_051_V43",
    "void ControllerManager::tspSetMouseMode(bool on)",
]

for needle in required_lineage:
    if needle not in s:
        raise SystemExit(
            "ERROR: source is not the expected V59 lineage.\n"
            "Missing: %s\n"
            "NO SOURCE MODIFIED." % needle
        )

if "TSP_MOUSE_CURSOR_CLEAR_051_V60" in s:
    required_v60 = [
        "mGamepadGuiCursorEnabled = false;",
        "mGamepadMousePressed = false;",
        "cursor-state=cleared",
    ]

    for needle in required_v60:
        if needle not in s:
            raise SystemExit(
                "ERROR: partial/corrupt V60 source. Missing: %s" % needle
            )

    print("PASS: complete V60 source already present.")
    print("STATE=V60_ALREADY_PATCHED")
else:
    anchor = '''        else
            std::remove(sTspMouseActiveFlag);

        MWBase::WindowManager* winMgr = MWBase::Environment::get().getWindowManager();
        winMgr->setCursorActive(on);
        winMgr->setCursorVisible(on);'''

    if s.count(anchor) != 1:
        raise SystemExit(
            "ERROR: expected tspSetMouseMode(false) anchor matched %d times; expected 1.\n"
            "Refusing to guess. NO SOURCE MODIFIED." % s.count(anchor)
        )

    print("PASS: exact V59 tspSetMouseMode anchor found once.")
    print("STATE=V59_PATCH_NEEDED")
PYSTATE

STATE_RC=${PIPESTATUS[0]}
set -e

if [ "$STATE_RC" -ne 0 ]; then
    exit "$STATE_RC"
fi

SOURCE_STATE="$(
grep '^STATE=' "$STATE_LOG" |
tail -1 |
cut -d= -f2-
)"

[ -n "$SOURCE_STATE" ] || {
    echo "ERROR: state detector did not return STATE=..."
    exit 1
}

echo
echo "Detected:"
echo "  $SOURCE_STATE"

SOURCE_BACKUP=""

if [ "$SOURCE_STATE" = "V59_PATCH_NEEDED" ]; then

    echo
    echo "===== 2/10 BACK UP CONTROLLERMANAGER BEFORE PATCH ====="

    SOURCE_BACKUP="$SRC/.tsp-051-source-backups/full-mouse-off-v60-$STAMP"

    docker exec -i "$C" python3 - "$SOURCE_BACKUP" <<'PYBACKUP' | tee "$PATCH_LOG"
from pathlib import Path
import hashlib
import shutil
import sys

src = Path("/root/openmw-0.51-tsp-src/apps/openmw/mwinput/controllermanager.cpp")
backup_root = Path(sys.argv[1])
dst = backup_root / "apps/openmw/mwinput/controllermanager.cpp"

def sha256(path):
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()

if not src.is_file():
    raise SystemExit("ERROR: source disappeared before backup")

dst.parent.mkdir(parents=True, exist_ok=True)
shutil.copy2(src, dst)

a = sha256(src)
b = sha256(dst)

if a != b:
    raise SystemExit(
        "ERROR: backup SHA mismatch. PATCH ABORTED BEFORE EDIT."
    )

Path("/root/openmw51-v60-source-backup-path.txt").write_text(
    str(backup_root) + "\n"
)

print("BACKUP PASS")
print("  source:", src)
print("  backup:", dst)
print("  SHA256:", a)
print()
print("Verified source backup:")
print(backup_root)
PYBACKUP

    docker exec "$C" test -d "$SOURCE_BACKUP"

    echo
    echo "===== 3/10 APPLY V60 COMPLETE CURSOR SHUTDOWN ====="

    docker exec -i "$C" python3 <<'PYPATCH' | tee -a "$PATCH_LOG"
from pathlib import Path

p = Path("/root/openmw-0.51-tsp-src/apps/openmw/mwinput/controllermanager.cpp")
s = p.read_text()

old = '''        else
            std::remove(sTspMouseActiveFlag);

        MWBase::WindowManager* winMgr = MWBase::Environment::get().getWindowManager();
        winMgr->setCursorActive(on);
        winMgr->setCursorVisible(on);'''

new = '''        else
        {
            std::remove(sTspMouseActiveFlag);

            // TSP_MOUSE_CURSOR_CLEAR_051_V60
            //
            // Explicit TSP mouse mode has two pieces of controller state:
            //   mTspMouseMode
            //   mGamepadGuiCursorEnabled
            //
            // V59 correctly turns mTspMouseMode off on MENU press, but inventory,
            // map and similar controller menus can retain the second bit. That
            // leaves MyGUI's gamepad cursor/hover route alive even though ordinary
            // controller navigation has already resumed.
            //
            // Clear both pieces atomically whenever explicit mouse mode turns off.
            // Also drop a stale emulated A-click latch if mouse mode was disabled
            // between press/release.
            mGamepadGuiCursorEnabled = false;
            mGamepadMousePressed = false;
        }

        MWBase::WindowManager* winMgr = MWBase::Environment::get().getWindowManager();
        winMgr->setCursorActive(on);
        winMgr->setCursorVisible(on);

        if (!on)
        {
            // Repeat after the persistent state is cleared so a controller menu
            // cannot revive the old pointer/hover state on the same transition.
            winMgr->setCursorActive(false);
            winMgr->setCursorVisible(false);

            Log(Debug::Info)
                << "TSP_MOUSE_CURSOR_CLEAR_051_V60"
                << " mouseMode=0 cursor-state=cleared";
        }'''

count = s.count(old)

if count != 1:
    raise SystemExit(
        "ERROR: V59 tspSetMouseMode anchor matched %d times; expected 1.\n"
        "NO SOURCE MODIFIED." % count
    )

candidate = s.replace(old, new, 1)

required = [
    "TSP_MOUSE_CURSOR_CLEAR_051_V60",
    "mGamepadGuiCursorEnabled = false;",
    "mGamepadMousePressed = false;",
    "mouseMode=0 cursor-state=cleared",
    "TSP_MOUSE_MENU_OFF_051_V59",
    "TSP_EXPLICIT_UI_STATE_051_V58",
    "TSP_NO_STICKCLICK_MODES_051_V54",
    "TSP_CHORD_051_V43",
    "r3=force-text-reset",
]

for needle in required:
    if needle not in candidate:
        raise SystemExit(
            "ERROR: candidate missing required behavior: %s" % needle
        )

if candidate.count("{") != candidate.count("}"):
    raise SystemExit("ERROR: brace imbalance in V60 candidate")

if candidate.count("(") != candidate.count(")"):
    raise SystemExit("ERROR: parenthesis imbalance in V60 candidate")

tmp = Path("/tmp/v60-controllermanager.cpp")
tmp.write_text(candidate)
tmp.replace(p)

print("PATCH PASS:", p)
print()
print("V60:")
print("  mouse OFF also clears mGamepadGuiCursorEnabled")
print("  mouse OFF clears stale mGamepadMousePressed")
print("  cursor active/visible explicitly forced false")
print("  V59 MENU one-shot mouse-off preserved")
print("  V58 B/text state machine preserved")
PYPATCH

    echo
    echo "===== 4/10 VERIFY PATCH AGAINST PREPATCH BACKUP ====="

    docker exec -i "$C" python3 - "$SOURCE_BACKUP" <<'PYVERIFY' | tee -a "$PATCH_LOG"
from pathlib import Path
import hashlib
import sys

src = Path("/root/openmw-0.51-tsp-src/apps/openmw/mwinput/controllermanager.cpp")
old = Path(sys.argv[1]) / "apps/openmw/mwinput/controllermanager.cpp"

def sha256(path):
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()

if not src.is_file() or not old.is_file():
    raise SystemExit("ERROR: source/backup missing")

a = sha256(old)
b = sha256(src)

if a == b:
    raise SystemExit("ERROR: ControllerManager did not change")

s = src.read_text()

for needle in (
    "TSP_MOUSE_CURSOR_CLEAR_051_V60",
    "mGamepadGuiCursorEnabled = false;",
    "mGamepadMousePressed = false;",
    "TSP_MOUSE_MENU_OFF_051_V59",
    "TSP_EXPLICIT_UI_STATE_051_V58",
):
    if needle not in s:
        raise SystemExit("ERROR: missing postpatch marker: %s" % needle)

print("PASS: source changed from verified backup")
print("  before:", a)
print("  after :", b)
PYVERIFY

else

    echo
    echo "===== 2-4/10 PATCH SKIPPED: COMPLETE V60 SOURCE ALREADY PRESENT ====="

    SOURCE_BACKUP="$(
        docker exec "$C" bash -lc '
        cat /root/openmw51-v60-source-backup-path.txt 2>/dev/null || true
        '
    )"

    echo "Original V60 source backup:"
    echo "  ${SOURCE_BACKUP:-not recorded}"

fi

echo
echo "===== 5/10 VERIFY EXISTING V58 HELPER ====="

docker exec "$C" bash -lc '
set -euo pipefail

H=/root/tsp_openmw_controls-v58

test -x "$H"

readelf -h "$H" |
    grep -E "Class:|Machine:|Type:"

readelf -h "$H" |
    grep -q "AArch64"

grep -a -q \
    "TSP_EXPLICIT_UI_STATE_051_V58 active" \
    "$H"

echo "PASS: existing V58 helper is AArch64 and unchanged."
sha256sum "$H"
'

echo
echo "===== 6/10 BUILD OR RESUME OPENMW V60 ====="

set +e
docker exec "$C" bash -lc '
set -o pipefail

cmake --build \
    /root/openmw-0.51-tsp-build \
    --target openmw \
    -- -j4
' 2>&1 | tee "$BUILD_LOG"

BUILD_RC=${PIPESTATUS[0]}
set -e

if [ "$BUILD_RC" -ne 0 ]; then
    exit "$BUILD_RC"
fi

if ! docker exec "$C" \
    grep -a -q \
    'TSP_MOUSE_CURSOR_CLEAR_051_V60' \
    "$OPENMW_BIN"
then
    echo
    echo "V60 marker absent after normal Ninja build."
    echo "Forcing only controllermanager.cpp.o + final link..."

    docker exec "$C" bash -lc '
    set -euo pipefail

    B=/root/openmw-0.51-tsp-build

    find "$B" \
        -type f \
        -name "controllermanager.cpp.o" \
        -print \
        -delete

    rm -fv \
        "$B/openmw" \
        "$B/apps/openmw/openmw"
    '

    set +e

    docker exec "$C" bash -lc '
    set -o pipefail

    cmake --build \
        /root/openmw-0.51-tsp-build \
        --target openmw \
        -- -j4
    ' 2>&1 | tee -a "$BUILD_LOG"

    BUILD_RC=${PIPESTATUS[0]}
    set -e

    if [ "$BUILD_RC" -ne 0 ]; then
        exit "$BUILD_RC"
    fi
fi

echo
echo "===== 7/10 VERIFY V60 + PRESERVED V59/V58 FEATURES ====="

docker exec "$C" bash -lc '
set -euo pipefail

B=/root/openmw-0.51-tsp-build/openmw
S=/root/openmw-0.51-tsp-src/apps/openmw/mwinput/controllermanager.cpp

test -x "$B"

echo "--- ELF ---"
readelf -h "$B" |
    grep -E "Class:|Machine:|Type:"

readelf -h "$B" |
    grep -q "AArch64"

echo
echo "--- V60 ---"

grep -a -q \
    "TSP_MOUSE_CURSOR_CLEAR_051_V60" \
    "$B"
echo "PASS: V60 runtime marker"

grep -a -q \
    "mouseMode=0 cursor-state=cleared" \
    "$B"
echo "PASS: V60 full mouse-off runtime action"

grep -F -q \
    "mGamepadGuiCursorEnabled = false;" \
    "$S"
echo "PASS: persistent GUI cursor state cleared"

grep -F -q \
    "mGamepadMousePressed = false;" \
    "$S"
echo "PASS: stale mouse-click latch cleared"

echo
echo "--- preserved ---"

for marker in \
    TSP_MOUSE_MENU_OFF_051_V59 \
    TSP_EXPLICIT_UI_STATE_051_V58 \
    TSP_NO_STICKCLICK_MODES_051_V54 \
    TSP_CHORD_051_V43
do
    grep -a -q "$marker" "$B"
    echo "PASS: $marker"
done

grep -a -q \
    "r3=force-text-reset" \
    "$B"
echo "PASS: R3 text reset"

grep -a -q \
    "tx_cursor.dds" \
    "$B"
echo "PASS: custom cursor"

echo
echo "OpenMW SHA256:"
sha256sum "$B"
'

echo
echo "===== 8/10 PACKAGE V60 ====="

docker cp \
    "$C:$OPENMW_BIN" \
    "$PKG/openmw-0.51"

docker cp \
    "$C:$HELPER_BIN" \
    "$PKG/tsp_openmw_controls"

docker cp \
    "$C:$CM" \
    "$PKG/patched-source/apps/openmw/mwinput/controllermanager.cpp"

if [ -n "${SOURCE_BACKUP:-}" ] && \
   docker exec "$C" test -d "$SOURCE_BACKUP"
then
    docker cp \
        "$C:$SOURCE_BACKUP/." \
        "$PKG/source-backup/"
    printf '%s\n' "$SOURCE_BACKUP" > "$PKG/SOURCE_BACKUP_PATH.txt"
fi

chmod 755 \
    "$PKG/openmw-0.51" \
    "$PKG/tsp_openmw_controls"

(
    cd "$PKG"

    sha256sum \
        openmw-0.51 \
        tsp_openmw_controls \
        > SHA256SUMS.txt
)

cat > "$PKG/BEHAVIOR.txt" <<'EOFBEHAVIOR'
TSP_MOUSE_CURSOR_CLEAR_051_V60

V59 already made:
  explicit TSP mouse + MENU -> mouse mode OFF immediately

V60 completes that transition by clearing:
  mGamepadGuiCursorEnabled
  mGamepadMousePressed
  cursor active
  cursor visible

This is needed in inventory/map/etc because the persistent gamepad GUI cursor
state could survive after mTspMouseMode was disabled, leaving the stale mouse
pointer/hover description active while controller navigation had already resumed.

Expected:
  inventory/map/barter/dialogue
    -> left stick wakes mouse
    -> MENU
    -> cursor disappears
    -> controller navigation works
    -> stale mouse hover is no longer the active cursor route

Text menus:
  V58/V59 behavior unchanged.

B exit:
  V58 force-controller behavior unchanged.

Settings:
  Settings' separate cursor exception remains unchanged and can recompute its
  controller cursor independently.
EOFBEHAVIOR

cat "$PKG/SHA256SUMS.txt"

echo
echo "===== 9/10 CONNECT + BACK UP DEVICE ====="

ssh \
    -o BatchMode=yes \
    -o ConnectTimeout=8 \
    "$DEV" '
echo "SSH PASS"
echo "Host: $(hostname)"
echo "Date: $(date)"
'

if ssh "$DEV" '
pidof openmw-0.51 >/dev/null 2>&1 ||
pidof openmw >/dev/null 2>&1
'
then
    echo
    echo "ERROR: OpenMW is currently running."
    echo
    echo "V60 has already been built and packaged:"
    echo "  $PKG"
    echo
    echo "Exit Morrowind normally and rerun this SAME V60 script."
    echo "It will detect V60 source and skip patching."
    exit 20
fi

echo "PASS: OpenMW is closed."

ssh "$DEV" '
killall tsp_openmw_controls 2>/dev/null || true
'

DEV_OPENMW_SHA="$(
ssh "$DEV" \
    "sha256sum '$REMOTE_BIN' | awk '{print \$1}'"
)"

DEV_HELPER_SHA="$(
ssh "$DEV" \
    "sha256sum '$REMOTE_HELPER' | awk '{print \$1}'"
)"

echo "Current device OpenMW:"
echo "  $DEV_OPENMW_SHA"
echo "Current device helper:"
echo "  $DEV_HELPER_SHA"

ssh "$DEV" "
set -e

test -s '$REMOTE_BIN'
test -s '$REMOTE_HELPER'

mkdir -p '$REMOTE_BACKUP'

cp -p \
    '$REMOTE_BIN' \
    '$REMOTE_BACKUP/openmw-0.51'

cp -p \
    '$REMOTE_HELPER' \
    '$REMOTE_BACKUP/tsp_openmw_controls'

sha256sum \
    '$REMOTE_BACKUP/openmw-0.51' \
    '$REMOTE_BACKUP/tsp_openmw_controls' \
    > '$REMOTE_BACKUP/SHA256SUMS.txt'

sync
"

scp -q \
    "$DEV:$REMOTE_BIN" \
    "$PKG/device-backup/openmw-0.51"

scp -q \
    "$DEV:$REMOTE_HELPER" \
    "$PKG/device-backup/tsp_openmw_controls"

(
    cd "$PKG/device-backup"

    sha256sum \
        openmw-0.51 \
        tsp_openmw_controls \
        > SHA256SUMS.txt
)

echo "PASS: device rollback:"
echo "  $REMOTE_BACKUP"

echo
echo "===== 10/10 INSTALL + VERIFY V60 ====="

scp -q \
    "$PKG/openmw-0.51" \
    "$DEV:/tmp/openmw-0.51-v60"

scp -q \
    "$PKG/tsp_openmw_controls" \
    "$DEV:/tmp/tsp_openmw_controls-v60"

ssh "$DEV" "
set -e

test -s /tmp/openmw-0.51-v60
test -s /tmp/tsp_openmw_controls-v60

cp \
    /tmp/openmw-0.51-v60 \
    '$REMOTE_BIN.new'

cp \
    /tmp/tsp_openmw_controls-v60 \
    '$REMOTE_HELPER.new'

chmod 755 \
    '$REMOTE_BIN.new' \
    '$REMOTE_HELPER.new'

mv -f \
    '$REMOTE_BIN.new' \
    '$REMOTE_BIN'

mv -f \
    '$REMOTE_HELPER.new' \
    '$REMOTE_HELPER'

rm -f \
    /tmp/openmw-0.51-v60 \
    /tmp/tsp_openmw_controls-v60 \
    /tmp/openmw-tsp-text-active \
    /tmp/openmw-tsp-text-char \
    /tmp/openmw-tsp-text-char.tmp \
    /tmp/openmw-tsp-text-off \
    /tmp/openmw-tsp-force-controller \
    /tmp/openmw-tsp-text-exit-latch \
    /tmp/openmw-tsp-request-controller \
    /tmp/openmw-tsp-mouse-mode \
    /tmp/openmw-tsp-mouse-request \
    /tmp/openmw-tsp-mouse-active \
    /tmp/openmw-tsp-text-reset

sync
"

LOCAL_OPENMW_SHA="$(
sha256sum "$PKG/openmw-0.51" |
awk '{print $1}'
)"

LOCAL_HELPER_SHA="$(
sha256sum "$PKG/tsp_openmw_controls" |
awk '{print $1}'
)"

REMOTE_OPENMW_SHA="$(
ssh "$DEV" \
    "sha256sum '$REMOTE_BIN' | awk '{print \$1}'"
)"

REMOTE_HELPER_SHA="$(
ssh "$DEV" \
    "sha256sum '$REMOTE_HELPER' | awk '{print \$1}'"
)"

echo
echo "OpenMW:"
echo "  package: $LOCAL_OPENMW_SHA"
echo "  device : $REMOTE_OPENMW_SHA"

echo
echo "Helper:"
echo "  package: $LOCAL_HELPER_SHA"
echo "  device : $REMOTE_HELPER_SHA"

[ "$LOCAL_OPENMW_SHA" = "$REMOTE_OPENMW_SHA" ] || {
    echo "ERROR: installed OpenMW SHA mismatch."
    exit 1
}

[ "$LOCAL_HELPER_SHA" = "$REMOTE_HELPER_SHA" ] || {
    echo "ERROR: installed helper SHA mismatch."
    exit 1
}

ssh "$DEV" "
set -e

grep -a -q \
    'TSP_MOUSE_CURSOR_CLEAR_051_V60' \
    '$REMOTE_BIN'

grep -a -q \
    'TSP_MOUSE_MENU_OFF_051_V59' \
    '$REMOTE_BIN'

grep -a -q \
    'TSP_EXPLICIT_UI_STATE_051_V58 active' \
    '$REMOTE_HELPER'

echo 'PASS: V60 OpenMW marker installed.'
echo 'PASS: V59 MENU mouse-off preserved.'
echo 'PASS: V58 helper preserved.'
"

cat > "$PKG/collect-v60-mouse-off-trace.sh" <<'EOFTRACE'
#!/usr/bin/env bash
set -Eeuo pipefail

DEV="${TSP_DEV:-root@192.168.1.25}"
OUT="${1:-$HOME/Downloads/openmw51-v60-mouse-off-trace-$(date +%Y%m%d-%H%M%S).txt}"

{
    echo "=================================================================="
    echo "OPENMW V60 FULL MOUSE-OFF TRACE"
    echo "=================================================================="

    ssh "$DEV" '
        hostname
        date
    '

    echo
    echo "===== ENGINE EVENTS ====="

    ssh "$DEV" '
        grep -hE \
          "TSP_MOUSE_CURSOR_CLEAR_051_V60|TSP_MOUSE_MENU_OFF_051_V59|TSP_EXPLICIT_UI_STATE_051_V58|TSP_MOUSE_MODE_051_V38|TSP_NO_STICKCLICK_MODES_051_V54|TSP_CHORD_051_V43" \
          /mnt/SDCARD/data/ports/openmw51/config-0.51/openmw.log \
          /mnt/SDCARD/tsp_prog.txt \
          2>/dev/null |
          tail -700 || true
    '

    echo
    echo "===== CURRENT FLAGS ====="

    ssh "$DEV" '
        for f in \
          /tmp/openmw-tsp-text-active \
          /tmp/openmw-tsp-text-off \
          /tmp/openmw-tsp-force-controller \
          /tmp/openmw-tsp-mouse-mode \
          /tmp/openmw-tsp-mouse-request \
          /tmp/openmw-tsp-mouse-active
        do
            if [ -e "$f" ]; then
                printf "EXISTS: %s = " "$f"
                cat "$f" 2>/dev/null || true
                echo
            else
                echo "absent: $f"
            fi
        done
    '

    echo
    echo "===== INSTALLED HASHES ====="

    ssh "$DEV" '
        sha256sum \
          /mnt/SDCARD/data/ports/openmw51/bin/openmw-0.51 \
          /mnt/SDCARD/data/ports/openmw51/tsp_openmw_controls
    '
} 2>&1 | tee "$OUT"

echo
echo "Trace saved:"
echo "  $OUT"
EOFTRACE

chmod +x \
    "$PKG/collect-v60-mouse-off-trace.sh"

cat > "$PKG/INSTALL_REPORT.txt" <<EOFREPORT
OpenMW 0.51 TSP Full Mouse-Off V60

Created:
$(date)

Source state:
$SOURCE_STATE

Source backup:
${SOURCE_BACKUP:-not recorded on this resume run}

Device rollback:
$REMOTE_BACKUP

Previous device OpenMW:
$DEV_OPENMW_SHA

Previous device helper:
$DEV_HELPER_SHA

Installed OpenMW:
$REMOTE_OPENMW_SHA

Installed helper:
$REMOTE_HELPER_SHA
EOFREPORT

echo
echo "=================================================================="
echo "V60 SUCCESS"
echo "=================================================================="
echo
echo "Package:"
echo "  $PKG"
echo
echo "Source rollback:"
echo "  ${SOURCE_BACKUP:-not recorded on this resume run}"
echo
echo "Device rollback:"
echo "  $REMOTE_BACKUP"
echo
echo "FINAL TEST:"
echo "  inventory/map -> left stick -> MOUSE -> MENU"
echo
echo "Expected:"
echo "  cursor disappears immediately"
echo "  controller navigation works"
echo "  stale mouse-hover description no longer remains as active cursor state"
echo
echo "Also recheck:"
echo "  text MOUSE -> MENU -> TEXT"
echo "  stacked-item B exit -> CONTROLLER"
echo
echo "If this one remaining case is wrong, while OpenMW is still open run:"
echo "  $PKG/collect-v60-mouse-off-trace.sh"
echo "=================================================================="
