#!/usr/bin/env bash
set -Eeuo pipefail
set -o pipefail

C="${TSP_DOCKER:-openmw_builder}"
DEV="${TSP_DEV:-root@192.168.1.25}"

SRC="/root/openmw-0.51-tsp-src"
BUILD="/root/openmw-0.51-tsp-build"

CM="$SRC/apps/openmw/mwinput/controllermanager.cpp"
HELPER_SRC="/root/tsp_openmw_controls.c"

OPENMW_BIN="$BUILD/openmw"
HELPER_BIN="/root/tsp_openmw_controls-v57"

STAMP="$(date +%Y%m%d-%H%M%S)"
PKG="$HOME/Downloads/openmw51-v57-resume-$STAMP"

REMOTE_ROOT="/mnt/SDCARD/data/ports/openmw51"
REMOTE_BIN="$REMOTE_ROOT/bin/openmw-0.51"
REMOTE_HELPER="$REMOTE_ROOT/tsp_openmw_controls"
REMOTE_BACKUP="$REMOTE_ROOT/backups/v57-resume-$STAMP"

VERIFY_LOG="$PKG/logs/v57-source-verify.log"
HELPER_BUILD_LOG="$PKG/logs/v57-helper-build.log"
OPENMW_BUILD_LOG="$PKG/logs/v57-openmw-build.log"

mkdir -p \
    "$PKG/logs" \
    "$PKG/patched-source/apps/openmw/mwinput" \
    "$PKG/patched-source/helper" \
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
        echo "V57 RESUME STOPPED SAFELY"
        echo "=================================================================="
        echo "Date: $(date)"
        echo "Exit code: $rc"
        echo "Script line: $line"
        echo "Failing command:"
        echo "  $cmd"
        echo

        for f in \
            "$VERIFY_LOG" \
            "$HELPER_BUILD_LOG" \
            "$OPENMW_BUILD_LOG"
        do
            if [ -f "$f" ]; then
                echo
                echo "----- $(basename "$f") : LAST 180 LINES -----"
                tail -180 "$f" || true
            fi
        done

        echo
        echo "No later install/deploy step was intentionally run after this error."
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
echo "OPENMW 0.51 TSP V57 RESUME / VERIFY / DEPLOY"
echo "=================================================================="
echo
echo "This script DOES NOT PATCH SOURCE."
echo
echo "It is for the state where V57 already changed source before"
echo "the previous terminal/build interruption."
echo
echo "Workflow:"
echo "  verify existing V57 source"
echo "  rebuild helper from exact current source"
echo "  let Ninja finish only remaining OpenMW work"
echo "  verify binaries"
echo "  package"
echo "  back up current TSP S files"
echo "  install"
echo "  verify remote SHA256"
echo
echo "Package:"
echo "  $PKG"
echo

echo "===== 1/9 VERIFY EXISTING V57 SOURCE IS COMPLETE ====="

set +e
docker exec -i "$C" python3 <<'PYVERIFY' 2>&1 | tee "$VERIFY_LOG"
from pathlib import Path

root = Path("/root/openmw-0.51-tsp-src")
cm = root / "apps/openmw/mwinput/controllermanager.cpp"
helper = Path("/root/tsp_openmw_controls.c")

for path in (cm, helper):
    if not path.is_file():
        raise SystemExit("ERROR: required source missing: %s" % path)

c = cm.read_text()
h = helper.read_text()

required_engine = [
    "TSP_B_EXIT_MENU_HANDOFF_051_V57",
    "TSP_TEXT_EXIT_CONTROLLER_051_V55",
    "TSP_NO_STICKCLICK_MODES_051_V54",
    "TSP_TEXT_HANDOFF_051_V51",
    "TSP_CHORD_051_V43",
    "SDL_IsTextInputActive() && !tspTextSuppressed()",
    "tspSetTextSuppressed(false);",
    "tspSetTextMode(false);",
    "tspSetMouseMode(!mTspMouseMode);",
    "r3=force-text-reset",
]

required_helper = [
    "TSP_B_EXIT_MENU_HANDOFF_051_V57",
    "TSP_TEXT_EXIT_CONTROLLER_051_V55",
    "TSP_NO_STICKCLICK_MODES_051_V54",
    'log_line("TSP_B_EXIT_MENU_HANDOFF_051_V57 active.");',
    "static void tsp_enter_pointing_mode(void)",
    "static void tsp_leave_pointing_mode(void)",
    "static void leave_text_mode(void)",
    "tsp_request_mouse_mode();",
    "EVIOCGRAB",
]

for needle in required_engine:
    if needle not in c:
        raise SystemExit(
            "ERROR: current controllermanager.cpp is NOT complete V57 source.\n"
            "Missing: %s\n"
            "NO SOURCE WAS MODIFIED." % needle
        )

for needle in required_helper:
    if needle not in h:
        raise SystemExit(
            "ERROR: current helper source is NOT complete V57 source.\n"
            "Missing: %s\n"
            "NO SOURCE WAS MODIFIED." % needle
        )

for forbidden in ("sTspTextExitLatchFlag", "tspTextExitLatched"):
    if forbidden in c:
        raise SystemExit(
            "ERROR: mixed V56/V57 engine source detected: %s remains.\n"
            "NO SOURCE WAS MODIFIED." % forbidden
        )

if "TEXT_EXIT_LATCH_FLAG" in h:
    raise SystemExit(
        "ERROR: mixed V56/V57 helper source detected: TEXT_EXIT_LATCH_FLAG remains.\n"
        "NO SOURCE WAS MODIFIED."
    )

start = h.find("static void leave_text_mode(void)")
end = h.find("static void handle_key_event", start)

if start < 0 or end < 0:
    raise SystemExit("ERROR: could not isolate V57 leave_text_mode().")

bfunc = h[start:end]

if bfunc.count("tsp_enter_pointing_mode();") != 1:
    raise SystemExit(
        "ERROR: V57 B function does not call tsp_enter_pointing_mode exactly once."
    )

if bfunc.count("tap_key(KEY_ESC);") != 1:
    raise SystemExit(
        "ERROR: V57 B function does not inject Escape exactly once."
    )

if bfunc.index("tsp_enter_pointing_mode();") > bfunc.index("tap_key(KEY_ESC);"):
    raise SystemExit(
        "ERROR: V57 B ordering is wrong: MENU handoff must occur BEFORE Escape."
    )

menu_text_path = (
    "    } else if (event->code == KEY_TSP_MENU) {\n"
    "        tsp_enter_pointing_mode();"
)

if menu_text_path not in h:
    raise SystemExit(
        "ERROR: original MENU TEXT->CONTROLLER path is missing."
    )

if "tsp_leave_pointing_mode();" not in h:
    raise SystemExit(
        "ERROR: MENU CONTROLLER->TEXT route is missing."
    )

for label, text in (
    ("controllermanager.cpp", c),
    ("tsp_openmw_controls.c", h),
):
    if text.count("{") != text.count("}"):
        raise SystemExit("ERROR: brace imbalance in %s" % label)

    if text.count("(") != text.count(")"):
        raise SystemExit("ERROR: parenthesis imbalance in %s" % label)

print("PASS: complete V57 engine source")
print("PASS: complete V57 helper source")
print("PASS: failed V56 latch removed")
print("PASS: B calls exact MENU TEXT->CONTROLLER handoff")
print("PASS: B injects Escape AFTER controller handoff")
print("PASS: MENU TEXT<->CONTROLLER routes retained")
print("PASS: V54 left-stick mouse route retained")
print("PASS: TSP S L3/R3/controller chord lineage retained")
print()
print("NO SOURCE MODIFICATION WAS PERFORMED.")
PYVERIFY

VERIFY_RC=${PIPESTATUS[0]}
set -e

if [ "$VERIFY_RC" -ne 0 ]; then
    exit "$VERIFY_RC"
fi

echo
echo "===== 2/9 REBUILD HELPER FROM CURRENT VERIFIED V57 SOURCE ====="
echo
echo "The helper compile is fast and guarantees the deployed helper matches"
echo "the exact V57 source just verified."

set +e
docker exec "$C" bash -lc '
set -euo pipefail

SRC=/root/tsp_openmw_controls.c
OUT=/root/tsp_openmw_controls-v57

CC=""

for c in gcc-13 aarch64-linux-gnu-gcc gcc cc; do
    if command -v "$c" >/dev/null 2>&1; then
        CC="$(command -v "$c")"
        break
    fi
done

[ -n "$CC" ] || {
    echo "ERROR: no suitable C compiler found."
    exit 1
}

echo "Compiler: $CC"

"$CC" \
    -O2 \
    -std=gnu11 \
    -Wall \
    -Wextra \
    "$SRC" \
    -o "$OUT"

chmod 755 "$OUT"

echo
echo "Helper ELF:"
readelf -h "$OUT" |
    grep -E "Class:|Machine:|Type:"

readelf -h "$OUT" |
    grep -q "AArch64" || {
        echo "ERROR: helper output is not AArch64."
        exit 1
    }

grep -a -q \
    "TSP_B_EXIT_MENU_HANDOFF_051_V57 active" \
    "$OUT" || {
        echo "ERROR: V57 helper runtime marker missing."
        exit 1
    }

grep -a -q \
    "TSP_TEXT_EXIT_CONTROLLER_051_V55 active" \
    "$OUT" || {
        echo "ERROR: V55 helper runtime support missing."
        exit 1
    }

if grep -a -q \
    "TSP_TEXT_EXIT_LATCH_051_V56 active" \
    "$OUT"
then
    echo "ERROR: old V56 helper runtime marker remains."
    exit 1
fi

echo
echo "Helper SHA256:"
sha256sum "$OUT"
' 2>&1 | tee "$HELPER_BUILD_LOG"

HELPER_RC=${PIPESTATUS[0]}
set -e

if [ "$HELPER_RC" -ne 0 ]; then
    exit "$HELPER_RC"
fi

echo
echo "===== 3/9 LET NINJA FINISH ONLY REMAINING OPENMW WORK ====="
echo
echo "No clean rebuild and no object deletion."
echo "If the previous V57 run finished, Ninja should report no work."
echo "If it stopped during compile/link, Ninja will finish only what remains."
echo

OLD_OPENMW_SHA="$(
docker exec "$C" bash -lc '
B=/root/openmw-0.51-tsp-build/openmw
if [ -x "$B" ]; then
    sha256sum "$B" | awk "{print \$1}"
fi
'
)"

set +e
docker exec "$C" bash -lc '
set -o pipefail

cmake --build \
    /root/openmw-0.51-tsp-build \
    --target openmw \
    -- -j4
' 2>&1 | tee "$OPENMW_BUILD_LOG"

OPENMW_RC=${PIPESTATUS[0]}
set -e

if [ "$OPENMW_RC" -ne 0 ]; then
    exit "$OPENMW_RC"
fi

echo
echo "===== 4/9 VERIFY OPENMW BUILD AGAINST CURRENT V57 SOURCE ====="

docker exec "$C" bash -lc '
set -euo pipefail

B=/root/openmw-0.51-tsp-build/openmw
S=/root/openmw-0.51-tsp-src/apps/openmw/mwinput/controllermanager.cpp

test -x "$B"

echo "--- OpenMW ELF ---"
readelf -h "$B" |
    grep -E "Class:|Machine:|Type:"

readelf -h "$B" |
    grep -q "AArch64" || {
        echo "ERROR: OpenMW is not AArch64."
        exit 1
    }

echo
echo "--- Functional source verification ---"

grep -F -q \
    "TSP_B_EXIT_MENU_HANDOFF_051_V57" \
    "$S"
echo "PASS: V57 source"

grep -F -q \
    "SDL_IsTextInputActive() && !tspTextSuppressed()" \
    "$S"
echo "PASS: V55 lingering-SDL-focus controller gate"

if grep -F -q \
    "tspTextExitLatched" \
    "$S"
then
    echo "ERROR: V56 engine latch remains."
    exit 1
fi

echo "PASS: V56 engine latch absent"

echo
echo "--- Runtime invariants that genuinely survive compilation ---"

for marker in \
    TSP_NO_STICKCLICK_MODES_051_V54 \
    TSP_CHORD_051_V43
do
    grep -a -q "$marker" "$B" || {
        echo "ERROR: missing runtime marker $marker"
        exit 1
    }

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

NEW_OPENMW_SHA="$(
docker exec "$C" \
    sha256sum "$OPENMW_BIN" |
    awk '{print $1}'
)"

echo
echo "OpenMW SHA before resume build:"
echo "  ${OLD_OPENMW_SHA:-none}"
echo "OpenMW SHA after resume build:"
echo "  $NEW_OPENMW_SHA"

if [ -n "$OLD_OPENMW_SHA" ] && [ "$OLD_OPENMW_SHA" = "$NEW_OPENMW_SHA" ]; then
    echo
    echo "INFO: OpenMW SHA did not change."
    echo "The previous V57 run had already completed the OpenMW build."
else
    echo
    echo "INFO: OpenMW SHA changed because Ninja finished remaining work."
fi

echo
echo "===== 5/9 PACKAGE VERIFIED V57 ====="

docker cp \
    "$C:$OPENMW_BIN" \
    "$PKG/openmw-0.51"

docker cp \
    "$C:$HELPER_BIN" \
    "$PKG/tsp_openmw_controls"

docker cp \
    "$C:$CM" \
    "$PKG/patched-source/apps/openmw/mwinput/controllermanager.cpp"

docker cp \
    "$C:$HELPER_SRC" \
    "$PKG/patched-source/helper/tsp_openmw_controls.c"

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
TSP_B_EXIT_MENU_HANDOFF_051_V57

Recovered/resumed from an already-patched V57 source tree.

B while helper TEXT mode owns the controller:

  1. tsp_enter_pointing_mode()
     - exact same function MENU uses for TEXT -> CONTROLLER
     - publishes controller suppression
     - releases EVIOCGRAB
     - returns pad to native OpenMW controller handling

  2. tap_key(KEY_ESC)
     - closes/cancels the text dialog

Ordering:
  controller handoff occurs BEFORE Escape/window teardown.

Expected test:
  barter
  -> stacked item
  -> MENU controller
  -> MENU text
  -> type or do not type
  -> B
  -> parent barter menu
  -> D-pad should immediately use normal controller navigation

Removed:
  V56 B-specific exit latch

Preserved:
  V55 lingering SDL text-focus controller support
  V54 left-stick mouse mode
  TSP S L3/R3 shortcuts
  MENU-held chords
  custom cursor
EOFBEHAVIOR

echo "Package contents:"
find "$PKG" \
    -maxdepth 6 \
    -type f \
    -printf '  %P\n'

echo
echo "===== 6/9 CONNECT TO TSP S ====="

ssh \
    -o BatchMode=yes \
    -o ConnectTimeout=8 \
    "$DEV" '
echo "SSH PASS"
echo "Host: $(hostname)"
echo "Date: $(date)"
'

echo
echo "Checking that OpenMW is closed..."

if ssh "$DEV" '
pidof openmw-0.51 >/dev/null 2>&1 ||
pidof openmw >/dev/null 2>&1
'
then
    echo
    echo "ERROR: OpenMW is currently running."
    echo
    echo "The verified V57 package is preserved at:"
    echo "  $PKG"
    echo
    echo "Exit Morrowind normally and rerun this SAME resume script."
    exit 20
fi

echo "PASS: OpenMW is closed."

ssh "$DEV" '
killall tsp_openmw_controls 2>/dev/null || true
'

echo
echo "===== 7/9 BACK UP CURRENT DEVICE OPENMW + HELPER ====="

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

echo
echo "PASS: device rollback created:"
echo "  $REMOTE_BACKUP"

echo
echo "===== 8/9 UPLOAD + INSTALL V57 ====="

scp -q \
    "$PKG/openmw-0.51" \
    "$DEV:/tmp/openmw-0.51-v57"

scp -q \
    "$PKG/tsp_openmw_controls" \
    "$DEV:/tmp/tsp_openmw_controls-v57"

ssh "$DEV" "
set -e

test -s /tmp/openmw-0.51-v57
test -s /tmp/tsp_openmw_controls-v57

cp \
    /tmp/openmw-0.51-v57 \
    '$REMOTE_BIN.new'

cp \
    /tmp/tsp_openmw_controls-v57 \
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
    /tmp/openmw-0.51-v57 \
    /tmp/tsp_openmw_controls-v57 \
    /tmp/openmw-tsp-text-active \
    /tmp/openmw-tsp-text-char \
    /tmp/openmw-tsp-text-char.tmp \
    /tmp/openmw-tsp-text-off \
    /tmp/openmw-tsp-text-exit-latch \
    /tmp/openmw-tsp-mouse-mode \
    /tmp/openmw-tsp-mouse-request \
    /tmp/openmw-tsp-mouse-active \
    /tmp/openmw-tsp-text-reset

sync
"

echo
echo "===== 9/9 VERIFY INSTALLED HASHES ====="

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
    'TSP_B_EXIT_MENU_HANDOFF_051_V57 active' \
    '$REMOTE_HELPER'

if grep -a -q \
    'TSP_TEXT_EXIT_LATCH_051_V56 active' \
    '$REMOTE_HELPER'
then
    echo 'ERROR: V56 helper latch runtime is still installed.'
    exit 1
fi

echo 'PASS: V57 helper runtime marker present.'
echo 'PASS: old V56 helper runtime marker absent.'
"

cat > "$PKG/collect-v57-controller-trace.sh" <<'EOFTRACE'
#!/usr/bin/env bash
set -Eeuo pipefail

DEV="${TSP_DEV:-root@192.168.1.25}"
OUT="${1:-$HOME/Downloads/openmw51-v57-controller-trace-$(date +%Y%m%d-%H%M%S).txt}"

{
    echo "=================================================================="
    echo "OPENMW V57 B-EXIT / MENU-HANDOFF TRACE"
    echo "=================================================================="

    ssh "$DEV" '
        hostname
        date
    '

    echo
    echo "===== HELPER EVENTS ====="

    ssh "$DEV" '
        if [ -f /tmp/tsp_controls_051.log ]; then
            grep -E \
              "TSP_B_EXIT_MENU_HANDOFF_051_V57|TSP_TEXT_EXIT_CONTROLLER_051_V55|TSP_NO_STICKCLICK_MODES_051_V54|MENU:|MODE=|CONTROLLER GRAB|RAW KEY name=B|RAW ABS name=DPAD" \
              /tmp/tsp_controls_051.log |
              tail -360
        else
            echo "/tmp/tsp_controls_051.log absent."
            echo "Run this collector while OpenMW is still running."
        fi
    '

    echo
    echo "===== ENGINE EVENTS ====="

    ssh "$DEV" '
        grep -hE \
          "TSP_NO_STICKCLICK_MODES_051_V54|TSP_TEXT_HANDOFF_051_V51|TSP_MOUSE_MODE_051_V38|TSP_CHORD_051_V43" \
          /mnt/SDCARD/data/ports/openmw51/config-0.51/openmw.log \
          /mnt/SDCARD/tsp_prog.txt \
          2>/dev/null |
          tail -300 || true
    '

    echo
    echo "===== HANDSHAKE FILES ====="

    ssh "$DEV" '
        for f in \
          /tmp/openmw-tsp-text-active \
          /tmp/openmw-tsp-text-char \
          /tmp/openmw-tsp-text-off \
          /tmp/openmw-tsp-text-exit-latch \
          /tmp/openmw-tsp-mouse-mode \
          /tmp/openmw-tsp-mouse-request \
          /tmp/openmw-tsp-mouse-active \
          /tmp/openmw-tsp-text-reset
        do
            if [ -e "$f" ]; then
                printf "EXISTS: %s = " "$f"
                cat "$f" 2>/dev/null || true
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
echo "Trace preserved:"
echo "  $OUT"
EOFTRACE

chmod +x \
    "$PKG/collect-v57-controller-trace.sh"

cat > "$PKG/INSTALL_REPORT.txt" <<EOFREPORT
OpenMW 0.51 TSP V57 resume/deploy

Created:
$(date)

Device:
$DEV

Source:
Existing V57 source was verified.
NO source patch was performed by this resume script.

Previous device OpenMW:
$DEV_OPENMW_SHA

Previous device helper:
$DEV_HELPER_SHA

Installed OpenMW:
$REMOTE_OPENMW_SHA

Installed helper:
$REMOTE_HELPER_SHA

Device rollback:
$REMOTE_BACKUP

Expected behavior:
barter
-> stacked item
-> MENU controller
-> MENU text
-> type or do not type
-> B
-> parent barter menu
-> D-pad immediately uses normal controller navigation
EOFREPORT

echo
echo "=================================================================="
echo "V57 RESUME + DEPLOY SUCCESS"
echo "=================================================================="
echo
echo "No source was patched during this recovery run."
echo
echo "Package:"
echo "  $PKG"
echo
echo "Device rollback:"
echo "  $REMOTE_BACKUP"
echo
echo "Installed OpenMW SHA:"
echo "  $REMOTE_OPENMW_SHA"
echo
echo "Installed helper SHA:"
echo "  $REMOTE_HELPER_SHA"
echo
echo "Test:"
echo "  barter -> stacked item -> MENU -> MENU -> B -> D-pad"
echo
echo "If it still fails, while OpenMW is still running:"
echo "  $PKG/collect-v57-controller-trace.sh"
echo "=================================================================="
