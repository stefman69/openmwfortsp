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
PKG="$HOME/Downloads/openmw51-menu-mouse-off-v59-$STAMP"

REMOTE_ROOT="/mnt/SDCARD/data/ports/openmw51"
REMOTE_BIN="$REMOTE_ROOT/bin/openmw-0.51"
REMOTE_HELPER="$REMOTE_ROOT/tsp_openmw_controls"
REMOTE_BACKUP="$REMOTE_ROOT/backups/menu-mouse-off-v59-$STAMP"

STATE_LOG="$PKG/logs/v59-state.log"
PATCH_LOG="$PKG/logs/v59-patch.log"
BUILD_LOG="$PKG/logs/v59-openmw-build.log"

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
        echo "V59 STOPPED SAFELY"
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
echo "OPENMW 0.51 TSP MENU-MOUSE-OFF V59"
echo "=================================================================="
echo
echo "Purpose:"
echo "  Make a single MENU press turn explicit TSP mouse mode OFF"
echo "  immediately, before the unreliable MENU-release path."
echo
echo "State behavior:"
echo
echo "  any ordinary GUI + explicit mouse + MENU"
echo "      -> mouse OFF immediately"
echo "      -> consume that MENU press/release"
echo "      -> return to that GUI's non-mouse control state"
echo
echo "  text GUI + mouse + MENU"
echo "      -> mouse OFF on press"
echo "      -> V58 helper sees the full MENU release"
echo "      -> TEXT"
echo
echo "  TEXT + MENU"
echo "      -> CONTROLLER (unchanged)"
echo
echo "  CONTROLLER + MENU"
echo "      -> TEXT (unchanged)"
echo
echo "Settings:"
echo "  Settings' built-in cursor exception is not removed."
echo
echo "This script is rerun-safe and terminal-safe."
echo

echo "===== 1/10 VERIFY CURRENT SOURCE STATE ====="

set +e
docker exec -i "$C" python3 <<'PYSTATE' 2>&1 | tee "$STATE_LOG"
from pathlib import Path

p = Path("/root/openmw-0.51-tsp-src/apps/openmw/mwinput/controllermanager.cpp")
if not p.is_file():
    raise SystemExit("ERROR: controllermanager.cpp missing")

s = p.read_text()

v58 = "TSP_EXPLICIT_UI_STATE_051_V58"
v59 = "TSP_MOUSE_MENU_OFF_051_V59"

required_v58 = [
    v58,
    "window-change=preserve-text-owner",
    "TSP_NO_STICKCLICK_MODES_051_V54",
    "TSP_CHORD_051_V43",
    "tspSetMouseMode(true);",
    "left-stick=controller-to-mouse",
    "if (arg.button == SDL_CONTROLLER_BUTTON_GUIDE)",
]

for needle in required_v58:
    if needle not in s:
        raise SystemExit(
            "ERROR: current ControllerManager is not the expected V58/V59 lineage.\n"
            "Missing: %s\n"
            "NO SOURCE MODIFIED." % needle
        )

if v59 in s:
    required_v59 = [
        "menu=press action=mouse-off-consumed",
        "if (mTspMouseMode",
        "mTspChordConsumed = true;",
        "mTspLastMenuTapMs = 0;",
    ]

    for needle in required_v59:
        if needle not in s:
            raise SystemExit(
                "ERROR: partial/corrupt V59 source. Missing: %s" % needle
            )

    print("PASS: complete V59 source already present.")
    print("STATE=V59_ALREADY_PATCHED")
else:
    exact_press = '''        if (arg.button == SDL_CONTROLLER_BUTTON_GUIDE)
        {
            // TSP_CHORD_051_V42 -- MENU now ARMS on press and acts on release, so
            // one button can mean three things without them fighting:
            //   held + another input -> chord   (consumed here)
            //   released, nothing else pressed -> mouse-mode toggle
            //   two such releases inside sTspMenuDoubleTapMs -> hard reset
            mTspMenuHeld = true;
            mTspChordConsumed = false;
            return;
        }'''

    if s.count(exact_press) != 1:
        raise SystemExit(
            "ERROR: expected V58 MENU-press block not found exactly once.\n"
            "Refusing to guess. NO SOURCE MODIFIED."
        )

    print("PASS: expected V58 MENU-press block found exactly once.")
    print("STATE=V58_PATCH_NEEDED")
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

if [ "$SOURCE_STATE" = "V58_PATCH_NEEDED" ]; then

    echo
    echo "===== 2/10 BACK UP CONTROLLERMANAGER BEFORE PATCH ====="

    SOURCE_BACKUP="$SRC/.tsp-051-source-backups/menu-mouse-off-v59-$STAMP"

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
        "ERROR: backup hash mismatch. PATCH ABORTED BEFORE EDIT."
    )

Path("/root/openmw51-v59-source-backup-path.txt").write_text(
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
    echo "===== 3/10 APPLY V59 ONE-SHOT MENU MOUSE-OFF ====="

    docker exec -i "$C" python3 <<'PYPATCH' | tee -a "$PATCH_LOG"
from pathlib import Path

p = Path("/root/openmw-0.51-tsp-src/apps/openmw/mwinput/controllermanager.cpp")
s = p.read_text()

old = '''        if (arg.button == SDL_CONTROLLER_BUTTON_GUIDE)
        {
            // TSP_CHORD_051_V42 -- MENU now ARMS on press and acts on release, so
            // one button can mean three things without them fighting:
            //   held + another input -> chord   (consumed here)
            //   released, nothing else pressed -> mouse-mode toggle
            //   two such releases inside sTspMenuDoubleTapMs -> hard reset
            mTspMenuHeld = true;
            mTspChordConsumed = false;
            return;
        }'''

new = '''        if (arg.button == SDL_CONTROLLER_BUTTON_GUIDE)
        {
            // TSP_CHORD_051_V42 -- MENU still arms the chord layer on press.
            mTspMenuHeld = true;

            // TSP_MOUSE_MENU_OFF_051_V59
            //
            // mTspMouseMode is already the authoritative state set by both TSP
            // left-stick mouse wake paths (and L3). Do not wait for MENU release
            // to disable it: the TSP input path can lose/miss that release while
            // control ownership changes. Turn the pointer off on the press that
            // OpenMW definitely received, then mark this MENU as consumed so its
            // release cannot perform a second MENU transition.
            //
            // In a live text dialog the V58 helper is simultaneously watching the
            // raw MENU press/release while yielded. After this press removes
            // sTspMouseActiveFlag, the helper waits for physical MENU release and
            // then reclaims TEXT: MOUSE -> TEXT in one MENU.
            //
            // In non-text GUI windows this simply lands in CONTROLLER.
            //
            // Settings keeps its separate stock/settings cursor exception, because
            // that exception does not depend solely on mTspMouseMode.
            if (mTspMouseMode
                && MWBase::Environment::get().getWindowManager()->isGuiMode())
            {
                mTspChordConsumed = true;
                mTspLastMenuTapMs = 0;
                tspSetMouseMode(false);

                Log(Debug::Info)
                    << "TSP_MOUSE_MENU_OFF_051_V59"
                    << " menu=press action=mouse-off-consumed";
                return;
            }

            mTspChordConsumed = false;
            return;
        }'''

count = s.count(old)

if count != 1:
    raise SystemExit(
        "ERROR: V58 MENU-press anchor matched %d times; expected 1.\n"
        "NO SOURCE MODIFIED." % count
    )

candidate = s.replace(old, new, 1)

required = [
    "TSP_MOUSE_MENU_OFF_051_V59",
    "menu=press action=mouse-off-consumed",
    "mTspChordConsumed = true;",
    "mTspLastMenuTapMs = 0;",
    "tspSetMouseMode(false);",
    "TSP_EXPLICIT_UI_STATE_051_V58",
    "TSP_NO_STICKCLICK_MODES_051_V54",
    "TSP_CHORD_051_V43",
    "left-stick=controller-to-mouse",
    "r3=force-text-reset",
]

for needle in required:
    if needle not in candidate:
        raise SystemExit(
            "ERROR: candidate missing required behavior: %s" % needle
        )

if candidate.count("{") != candidate.count("}"):
    raise SystemExit("ERROR: brace imbalance in V59 candidate")

if candidate.count("(") != candidate.count(")"):
    raise SystemExit("ERROR: parenthesis imbalance in V59 candidate")

tmp = Path("/tmp/v59-controllermanager.cpp")
tmp.write_text(candidate)
tmp.replace(p)

print("PATCH PASS:", p)
print()
print("V59 behavior:")
print("  explicit mouse + MENU press -> mouse OFF immediately")
print("  MENU press/release marked consumed for engine")
print("  V58 helper remains responsible for MOUSE -> TEXT in text dialogs")
print("  non-text mouse menus land in CONTROLLER")
print("  Settings stock cursor exception retained")
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
    raise SystemExit("ERROR: verification source/backup missing")

a = sha256(old)
b = sha256(src)

if a == b:
    raise SystemExit("ERROR: ControllerManager did not change")

s = src.read_text()

for needle in (
    "TSP_MOUSE_MENU_OFF_051_V59",
    "menu=press action=mouse-off-consumed",
    "TSP_EXPLICIT_UI_STATE_051_V58",
    "TSP_CHORD_051_V43",
):
    if needle not in s:
        raise SystemExit("ERROR: missing postpatch marker: %s" % needle)

print("PASS: source changed from verified backup")
print("  before:", a)
print("  after :", b)
PYVERIFY

else

    echo
    echo "===== 2-4/10 PATCH SKIPPED: COMPLETE V59 SOURCE ALREADY PRESENT ====="

    SOURCE_BACKUP="$(
        docker exec "$C" bash -lc '
        cat /root/openmw51-v59-source-backup-path.txt 2>/dev/null || true
        '
    )"

    echo "Original V59 source backup:"
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

echo "PASS: existing V58 helper is AArch64 and has V58 runtime marker."
sha256sum "$H"
'

echo
echo "===== 6/10 BUILD OR RESUME OPENMW V59 ====="
echo
echo "Ninja will build only changed/missing work."
echo "If this script was interrupted after patching, rerun it and it resumes."
echo

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
    'TSP_MOUSE_MENU_OFF_051_V59' \
    "$OPENMW_BIN"
then
    echo
    echo "V59 marker not present after normal Ninja build."
    echo "Forcing only controllermanager.cpp.o + final OpenMW link..."

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
echo "===== 7/10 VERIFY OPENMW V59 + V58 CONTROLLER INVARIANTS ====="

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
echo "--- V59 ---"

grep -a -q \
    "TSP_MOUSE_MENU_OFF_051_V59" \
    "$B"
echo "PASS: V59 runtime marker"

grep -a -q \
    "menu=press action=mouse-off-consumed" \
    "$B"
echo "PASS: V59 mouse-off action string"

grep -F -q \
    "if (mTspMouseMode" \
    "$S"
echo "PASS: V59 uses existing explicit mouse state"

echo
echo "--- preserved V58/V54/chord behavior ---"

for marker in \
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
echo "===== 8/10 PACKAGE V59 ====="

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
TSP_MOUSE_MENU_OFF_051_V59

Problem
-------
OpenMW previously disabled explicit TSP mouse mode on MENU RELEASE.

The TSP helper/OpenMW handoff can change controller ownership around the
same MENU event, and release is the unreliable half of that event. Runtime
traces showed repeated:
  TSP_CHORD_051_V43 menu=stuck-armed action=cleared

V59
---
When OpenMW receives MENU PRESS while:
  mTspMouseMode == true
and:
  GUI mode == true

it immediately:
  1. sets the MENU as consumed
  2. resets the MENU double-tap timestamp
  3. calls tspSetMouseMode(false)
  4. returns

The corresponding MENU release therefore cannot perform a second engine
MENU transition.

Result
------
Non-text GUI:
  MOUSE + MENU -> CONTROLLER

Text GUI:
  MOUSE + MENU
      -> engine turns mouse OFF on press
      -> V58 helper waits for physical MENU release
      -> TEXT

Then:
  TEXT + MENU -> CONTROLLER
  CONTROLLER + MENU -> TEXT
  TEXT/CONTROLLER + left stick -> MOUSE

Settings
--------
The Settings window has a separate built-in cursor exception. V59 does not
remove that exception. Therefore normal Settings cursor behavior should be
preserved.

Preserved
---------
V58 B force-controller fix
V58 text/controller/mouse state machine
V58 neutral-stick mouse re-arm
V54 left-stick mouse wake
L3 mouse toggle
R3 text reset
MENU-held chord layer
custom cursor
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
    echo "V59 has already been built and packaged:"
    echo "  $PKG"
    echo
    echo "Exit Morrowind normally and rerun this SAME V59 script."
    echo "It will detect V59 source and skip patching."
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
echo "===== 10/10 INSTALL + VERIFY V59 ====="

scp -q \
    "$PKG/openmw-0.51" \
    "$DEV:/tmp/openmw-0.51-v59"

scp -q \
    "$PKG/tsp_openmw_controls" \
    "$DEV:/tmp/tsp_openmw_controls-v59"

ssh "$DEV" "
set -e

test -s /tmp/openmw-0.51-v59
test -s /tmp/tsp_openmw_controls-v59

cp \
    /tmp/openmw-0.51-v59 \
    '$REMOTE_BIN.new'

cp \
    /tmp/tsp_openmw_controls-v59 \
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
    /tmp/openmw-0.51-v59 \
    /tmp/tsp_openmw_controls-v59 \
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
    'TSP_MOUSE_MENU_OFF_051_V59' \
    '$REMOTE_BIN'

grep -a -q \
    'TSP_EXPLICIT_UI_STATE_051_V58 active' \
    '$REMOTE_HELPER'

echo 'PASS: V59 OpenMW marker installed.'
echo 'PASS: V58 helper marker installed.'
"

cat > "$PKG/collect-v59-menu-mouse-trace.sh" <<'EOFTRACE'
#!/usr/bin/env bash
set -Eeuo pipefail

DEV="${TSP_DEV:-root@192.168.1.25}"
OUT="${1:-$HOME/Downloads/openmw51-v59-menu-mouse-trace-$(date +%Y%m%d-%H%M%S).txt}"

{
    echo "=================================================================="
    echo "OPENMW V59 MENU MOUSE-OFF TRACE"
    echo "=================================================================="

    ssh "$DEV" '
        hostname
        date
    '

    echo
    echo "===== ENGINE EVENTS ====="

    ssh "$DEV" '
        grep -hE \
          "TSP_MOUSE_MENU_OFF_051_V59|TSP_EXPLICIT_UI_STATE_051_V58|TSP_MOUSE_MODE_051_V38|TSP_NO_STICKCLICK_MODES_051_V54|TSP_CHORD_051_V43" \
          /mnt/SDCARD/data/ports/openmw51/config-0.51/openmw.log \
          /mnt/SDCARD/tsp_prog.txt \
          2>/dev/null |
          tail -700 || true
    '

    echo
    echo "===== HELPER LOG ====="

    ssh "$DEV" '
        for f in \
          /tmp/tsp_controls_051.log \
          /tmp/tsp_openmw_controls_051.log
        do
            if [ -f "$f" ]; then
                echo "--- $f ---"
                cat "$f"
            fi
        done
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
    "$PKG/collect-v59-menu-mouse-trace.sh"

cat > "$PKG/INSTALL_REPORT.txt" <<EOFREPORT
OpenMW 0.51 TSP Menu Mouse-Off V59

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
echo "V59 SUCCESS"
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
echo "TEST A — TEXT MENU"
echo "  TEXT -> stick -> MOUSE -> MENU"
echo "  Expected: TEXT immediately after that one MENU."
echo
echo "  MENU again -> CONTROLLER"
echo "  MENU again -> TEXT"
echo
echo "TEST B — ORDINARY GUI"
echo "  inventory/barter/dialogue -> stick -> MOUSE -> MENU"
echo "  Expected: mouse OFF, controller navigation."
echo
echo "TEST C — B"
echo "  Repeat the previously fixed B-exit sequence."
echo "  Expected: V58 B fix unchanged."
echo
echo "If mouse-off is wrong, while the game is still open:"
echo "  $PKG/collect-v59-menu-mouse-trace.sh"
echo "=================================================================="
