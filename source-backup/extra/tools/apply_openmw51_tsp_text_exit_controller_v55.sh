#!/usr/bin/env bash
set -euo pipefail
set -o pipefail

C="${TSP_DOCKER:-openmw_builder}"
DEV="${TSP_DEV:-root@192.168.1.25}"
SRC=/root/openmw-0.51-tsp-src
BUILD=/root/openmw-0.51-tsp-build
STAMP="$(date +%Y%m%d-%H%M%S)"
PKG="$HOME/Downloads/openmw51-text-exit-controller-v55-$STAMP"

REMOTE_ROOT=/mnt/SDCARD/data/ports/openmw51
REMOTE_BIN="$REMOTE_ROOT/bin/openmw-0.51"
REMOTE_HELPER="$REMOTE_ROOT/tsp_openmw_controls"
REMOTE_BACKUP="$REMOTE_ROOT/backups/text-exit-controller-v55-$STAMP"

PATCH_LOG="$PKG/v55-patch.log"
HELPER_BUILD_LOG="$PKG/v55-helper-build.log"
OPENMW_BUILD_LOG="$PKG/v55-openmw-build.log"

mkdir -p \
    "$PKG/patched-source/apps/openmw/mwinput" \
    "$PKG/patched-source/helper" \
    "$PKG/source-backup" \
    "$PKG/device-backup"

fail_report() {
    rc=$?
    echo
    echo "=================================================================="
    echo "V55 FAILED (exit $rc)"
    echo "=================================================================="
    for f in "$PATCH_LOG" "$HELPER_BUILD_LOG" "$OPENMW_BUILD_LOG"; do
        if [ -f "$f" ]; then
            echo
            echo "----- $(basename "$f") : LAST 160 LINES -----"
            tail -160 "$f" || true
        fi
    done
    echo
    echo "All preserved output:"
    echo "  $PKG"
    exit "$rc"
}
trap fail_report ERR

echo "=================================================================="
echo "OPENMW 0.51 TSP TEXT-EXIT -> CONTROLLER V55"
echo "=================================================================="
echo "Docker : $C"
echo "Device : $DEV"
echo "Package: $PKG"
echo
echo "Target behavior:"
echo "  TEXT + B          -> cancel/leave TEXT -> CONTROLLER immediately"
echo "  TEXT + MENU       -> CONTROLLER"
echo "  CONTROLLER + MENU -> TEXT when text input exists"
echo "  text focus ends   -> helper state automatically resets"
echo "  D-pad works in controller mode even if SDL EditBox focus lingers"
echo
echo "Preserve:"
echo "  V54 left-stick -> mouse"
echo "  TSP S L3/R3 shortcuts"
echo "  MENU-held chord layer"
echo "  V52 text indicator"
echo

echo "===== 1/11 VERIFY EXACT POST-V54 SOURCE ====="

docker exec -i "$C" python3 <<'PYVERIFY' | tee "$PATCH_LOG"
from pathlib import Path

root = Path("/root/openmw-0.51-tsp-src")
cm = root / "apps/openmw/mwinput/controllermanager.cpp"
helper = Path("/root/tsp_openmw_controls.c")

for p in (cm, helper):
    if not p.is_file():
        raise SystemExit("ERROR: required source missing: %s" % p)

c = cm.read_text()
h = helper.read_text()

cm_need = [
    "TSP_NO_STICKCLICK_MODES_051_V54",
    "TSP_TEXT_HANDOFF_051_V51",
    "TSP_A_DOUBLE_PRESS_051_V53",
    'const char* const sTspTextOffFlag = "/tmp/openmw-tsp-text-off";',
    "bool tspTextSuppressed()",
    "if (SDL_IsTextInputActive())",
    "tspSetMouseMode(!mTspMouseMode);",
    "r3=force-text-reset",
    "TSP_CHORD_051_V43",
]

helper_need = [
    "TSP_NO_STICKCLICK_MODES_051_V54",
    "#define MOUSE_REQUEST_FLAG",
    "#define MOUSE_ACTIVE_FLAG",
    "static bool suppress_auto_text = false;",
    "static void sync_automatic_mode(void)",
    "static void tsp_request_mouse_mode(void)",
    "static void tsp_enter_pointing_mode(void)",
    "static void tsp_leave_pointing_mode(void)",
    "static void leave_text_mode(void)",
    "EVIOCGRAB",
]

for x in cm_need:
    if x not in c:
        raise SystemExit("ERROR: controllermanager.cpp missing V55 precondition: %s" % x)

for x in helper_need:
    if x not in h:
        raise SystemExit("ERROR: helper source missing V55 precondition: %s" % x)

if "TSP_TEXT_EXIT_CONTROLLER_051_V55" in c or "TSP_TEXT_EXIT_CONTROLLER_051_V55" in h:
    raise SystemExit("ERROR: V55 is already present; refusing a second application.")

print("PASS: exact V54 controller preconditions")
print("PASS: exact V54 helper preconditions")
print("PASS: V51/V52/V53/V54 lineage present")
print("PASS: V55 not already applied")
PYVERIFY

echo
echo "===== 2/11 BACK UP EVERY SOURCE FILE BEFORE ANY EDIT ====="

SOURCE_BACKUP="$SRC/.tsp-051-source-backups/text-exit-controller-v55-$STAMP"

docker exec -i "$C" python3 - "$SOURCE_BACKUP" <<'PYBACKUP' | tee -a "$PATCH_LOG"
from pathlib import Path
import hashlib
import shutil
import sys

root = Path("/root/openmw-0.51-tsp-src")
backup = Path(sys.argv[1])

pairs = [
    (
        root / "apps/openmw/mwinput/controllermanager.cpp",
        backup / "apps/openmw/mwinput/controllermanager.cpp",
    ),
    (
        Path("/root/tsp_openmw_controls.c"),
        backup / "root/tsp_openmw_controls.c",
    ),
]

def sha256(p):
    h = hashlib.sha256()
    with p.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()

for src, dst in pairs:
    if not src.is_file():
        raise SystemExit("ERROR: source vanished before backup: %s" % src)
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src, dst)

for src, dst in pairs:
    a = sha256(src)
    b = sha256(dst)
    if a != b:
        raise SystemExit("ERROR: BACKUP HASH MISMATCH: %s" % src)
    print("BACKUP PASS:", src, a)

Path("/root/openmw51-v55-source-backup-path.txt").write_text(str(backup) + "\n")
print("VERIFIED BACKUP:", backup)
PYBACKUP

docker exec "$C" test -d "$SOURCE_BACKUP"

echo
echo "===== 3/11 APPLY V55 PATCH AGAINST VERIFIED SOURCE ====="

docker exec -i "$C" python3 <<'PYPATCH' | tee -a "$PATCH_LOG"
from pathlib import Path

root = Path("/root/openmw-0.51-tsp-src")
CM = root / "apps/openmw/mwinput/controllermanager.cpp"
HELPER = Path("/root/tsp_openmw_controls.c")

MARK = "TSP_TEXT_EXIT_CONTROLLER_051_V55"

def once(text, old, new, label):
    count = text.count(old)
    if count != 1:
        raise SystemExit(
            "ERROR: %s anchor matched %d times; expected exactly 1. "
            "NO PATCHED FILES HAVE BEEN WRITTEN." % (label, count)
        )
    return text.replace(old, new, 1)

c0 = CM.read_text()
h0 = HELPER.read_text()
c = c0
h = h0

c = once(
    c,
'''        // Some keys will work even when Text Input windows/modals are in focus.
        if (SDL_IsTextInputActive())
            return false;

        winMgr->injectKeyPress(key, 0, false);''',
'''        // Some keys will work even when Text Input windows/modals are in focus.
        // TSP_TEXT_EXIT_CONTROLLER_051_V55
        // SDL text focus is not the same thing as helper TEXT ownership. B and
        // MENU can deliberately release EVIOCGRAB while the EditBox still owns
        // SDL focus. In that controller-suppressed state, allow D-pad / GUI key
        // navigation immediately instead of leaving the menu apparently dead.
        if (SDL_IsTextInputActive() && !tspTextSuppressed())
            return false;

        winMgr->injectKeyPress(key, 0, false);''',
    "engine lingering SDL text-focus guard",
)

h = once(
    h,
'''#define TEXT_ACTIVE_FLAG "/tmp/openmw-tsp-text-active"
#define TEXT_CHAR_FILE   "/tmp/openmw-tsp-text-char"
#define TEXT_CHAR_TMP    "/tmp/openmw-tsp-text-char.tmp"''',
'''#define TEXT_ACTIVE_FLAG "/tmp/openmw-tsp-text-active"
#define TEXT_CHAR_FILE   "/tmp/openmw-tsp-text-char"
#define TEXT_CHAR_TMP    "/tmp/openmw-tsp-text-char.tmp"

/* TSP_TEXT_EXIT_CONTROLLER_051_V55
 * Shared with ControllerManager's existing sTspTextOffFlag. This file means:
 * "SDL may still have an EditBox focused, but the user intentionally selected
 * ordinary controller navigation, so the helper must not hold EVIOCGRAB."
 */
#define TEXT_OFF_FLAG    "/tmp/openmw-tsp-text-off"''',
    "helper TEXT_OFF_FLAG define",
)

h = once(
    h,
'''static bool openmw_text_active(void)
{
    return access(TEXT_ACTIVE_FLAG, F_OK) == 0;
}

static void sync_automatic_mode(void)
{
    const bool active = openmw_text_active();

    if (!active) {
        /*
         * TSP_TEXT_REMAP_051_V43
         *
         * V40 bug: the pointing flag was cleared on cancel, on reclaim, at startup
         * and at shutdown -- but NOT when text entry simply ended. Closing a menu
         * while in POINTING mode orphaned the file for the rest of the session, and
         * OpenMW kept forcing mouse mode back on in every menu afterwards.
         */
        unlink(MOUSE_MODE_FLAG);
        suppress_auto_text = false;
        if (mode != MODE_GAME)
            set_mode(MODE_GAME);
        return;
    }

    if (active && !suppress_auto_text && mode != MODE_TEXT)
        set_mode(MODE_TEXT);
}''',
'''static bool openmw_text_active(void)
{
    return access(TEXT_ACTIVE_FLAG, F_OK) == 0;
}

/* TSP_TEXT_EXIT_CONTROLLER_051_V55
 * Keep helper-local suppress_auto_text and the engine-visible TEXT_OFF_FLAG
 * synchronized. The file is the cross-process state; the bool is the helper's
 * fast local copy.
 */
static void set_text_suppressed(bool suppressed)
{
    const bool changed = suppress_auto_text != suppressed;
    suppress_auto_text = suppressed;

    if (suppressed) {
        if (access(TEXT_OFF_FLAG, F_OK) != 0) {
            FILE *file = fopen(TEXT_OFF_FLAG, "w");
            if (file != NULL) {
                fputs("1\\n", file);
                fclose(file);
            } else if (log_file != NULL) {
                fprintf(log_file,
                        "TSP_TEXT_EXIT_CONTROLLER_051_V55 could not write %s: %s\\n",
                        TEXT_OFF_FLAG, strerror(errno));
                fflush(log_file);
            }
        }
    } else {
        unlink(TEXT_OFF_FLAG);
    }

    if (changed && log_file != NULL) {
        fprintf(log_file,
                "TSP_TEXT_EXIT_CONTROLLER_051_V55 textSuppressed=%d\\n",
                suppressed ? 1 : 0);
        fflush(log_file);
    }
}

static void sync_automatic_mode(void)
{
    const bool active = openmw_text_active();

    /*
     * ControllerManager clears TEXT_OFF_FLAG when the active controller window
     * changes. Mirror that here so suppression cannot leak into the next menu,
     * even if SDL switches EditBoxes too quickly for this 10 ms helper poll to
     * observe TEXT_ACTIVE_FLAG disappear for a full tick.
     */
    const bool shared_suppressed = access(TEXT_OFF_FLAG, F_OK) == 0;
    if (suppress_auto_text != shared_suppressed)
        suppress_auto_text = shared_suppressed;

    if (!active) {
        /*
         * TSP_TEXT_REMAP_051_V43 + TSP_TEXT_EXIT_CONTROLLER_051_V55
         * No active text field means TEXT controls are impossible. Release the
         * pad, clear every text/controller suppression marker, and start clean.
         */
        unlink(MOUSE_MODE_FLAG);
        set_text_suppressed(false);
        if (mode != MODE_GAME)
            set_mode(MODE_GAME);
        return;
    }

    if (!suppress_auto_text && mode != MODE_TEXT)
        set_mode(MODE_TEXT);
}''',
    "helper shared suppression state",
)

h = once(
    h,
'''static void tsp_request_mouse_mode(void)
{
    log_line("TSP_NO_STICKCLICK_MODES_051_V54 LEFT STICK: TEXT -> MOUSE.");
    suppress_auto_text = true;''',
'''static void tsp_request_mouse_mode(void)
{
    log_line("TSP_NO_STICKCLICK_MODES_051_V54 LEFT STICK: TEXT -> MOUSE.");
    // TSP_TEXT_EXIT_CONTROLLER_051_V55
    set_text_suppressed(true);''',
    "helper TEXT->mouse suppression",
)

h = once(
    h,
'''static void tsp_enter_pointing_mode(void)
{
    log_line("MENU: POINTING - pad yielded to OpenMW, text entry still open.");

    suppress_auto_text = true;''',
'''static void tsp_enter_pointing_mode(void)
{
    log_line("MENU: POINTING - pad yielded to OpenMW, text entry still open.");

    // TSP_TEXT_EXIT_CONTROLLER_051_V55
    // This is CONTROLLER suppression now; publish it so OpenMW permits D-pad
    // navigation even while the EditBox continues to own SDL text focus.
    set_text_suppressed(true);''',
    "helper TEXT->controller suppression",
)

h = once(
    h,
'''static void tsp_leave_pointing_mode(void)
{
    log_line("MENU: TYPING - pad reclaimed by helper.");
    unlink(MOUSE_MODE_FLAG);
    suppress_auto_text = false;
    sync_automatic_mode();
}''',
'''static void tsp_leave_pointing_mode(void)
{
    log_line("MENU: TYPING - pad reclaimed by helper.");
    unlink(MOUSE_MODE_FLAG);
    // TSP_TEXT_EXIT_CONTROLLER_051_V55
    set_text_suppressed(false);
    sync_automatic_mode();
}''',
    "helper controller->TEXT unsuppress",
)

h = once(
    h,
'''static void leave_text_mode(void)
{
    log_line("CANCEL: leave/cancel text entry (Escape).");
    suppress_auto_text = true;
    unlink(MOUSE_MODE_FLAG); /* TSP_TEXT_REMAP_051_V40 */
    tap_key(KEY_ESC);
    set_mode(MODE_GAME);
}''',
'''static void leave_text_mode(void)
{
    log_line("CANCEL: leave/cancel text entry (Escape).");

    // TSP_TEXT_EXIT_CONTROLLER_051_V55
    // B means TEXT -> CONTROLLER immediately. Publish suppression BEFORE
    // injecting Escape so OpenMW can accept the very next D-pad event even if
    // the EditBox keeps SDL text focus for several frames (or indefinitely).
    set_text_suppressed(true);
    unlink(MOUSE_MODE_FLAG); /* TSP_TEXT_REMAP_051_V40 */
    tap_key(KEY_ESC);
    set_mode(MODE_GAME);
    log_line("TSP_TEXT_EXIT_CONTROLLER_051_V55 B: TEXT -> CONTROLLER.");
}''',
    "helper B exit",
)

h = once(
    h,
'''    unlink(TEXT_ACTIVE_FLAG);
    unlink(TEXT_CHAR_FILE);
    unlink(TEXT_CHAR_TMP);
    unlink(MOUSE_MODE_FLAG); /* TSP_TEXT_REMAP_051_V40 */
    /* TSP_NO_STICKCLICK_MODES_051_V54 */
    unlink(MOUSE_REQUEST_FLAG);
    unlink(MOUSE_ACTIVE_FLAG);

    controller_fd = find_controller();''',
'''    unlink(TEXT_ACTIVE_FLAG);
    unlink(TEXT_CHAR_FILE);
    unlink(TEXT_CHAR_TMP);
    unlink(MOUSE_MODE_FLAG); /* TSP_TEXT_REMAP_051_V40 */
    /* TSP_NO_STICKCLICK_MODES_051_V54 */
    unlink(MOUSE_REQUEST_FLAG);
    unlink(MOUSE_ACTIVE_FLAG);
    /* TSP_TEXT_EXIT_CONTROLLER_051_V55 */
    unlink(TEXT_OFF_FLAG);

    controller_fd = find_controller();''',
    "helper startup cleanup",
)

h = once(
    h,
'''    log_line("Menu from MOUSE: returns to CONTROLLER before TEXT.");
    log_line("TSP_TEXT_REMAP_051_V40 active.");
    log_line("TSP_NO_STICKCLICK_MODES_051_V54 active.");''',
'''    log_line("Menu from MOUSE: returns to CONTROLLER before TEXT.");
    log_line("B from TEXT: cancels text and immediately restores controller D-pad.");
    log_line("TSP_TEXT_REMAP_051_V40 active.");
    log_line("TSP_NO_STICKCLICK_MODES_051_V54 active.");
    log_line("TSP_TEXT_EXIT_CONTROLLER_051_V55 active.");''',
    "helper startup marker",
)

h = once(
    h,
'''    unlink(TEXT_ACTIVE_FLAG);
    unlink(TEXT_CHAR_FILE);
    unlink(TEXT_CHAR_TMP);
    unlink(MOUSE_MODE_FLAG); /* TSP_TEXT_REMAP_051_V40 */
    /* TSP_NO_STICKCLICK_MODES_051_V54 */
    unlink(MOUSE_REQUEST_FLAG);
    unlink(MOUSE_ACTIVE_FLAG);

    if (uinput_fd >= 0) {''',
'''    unlink(TEXT_ACTIVE_FLAG);
    unlink(TEXT_CHAR_FILE);
    unlink(TEXT_CHAR_TMP);
    unlink(MOUSE_MODE_FLAG); /* TSP_TEXT_REMAP_051_V40 */
    /* TSP_NO_STICKCLICK_MODES_051_V54 */
    unlink(MOUSE_REQUEST_FLAG);
    unlink(MOUSE_ACTIVE_FLAG);
    /* TSP_TEXT_EXIT_CONTROLLER_051_V55 */
    unlink(TEXT_OFF_FLAG);

    if (uinput_fd >= 0) {''',
    "helper shutdown cleanup",
)

if MARK not in c or MARK not in h:
    raise SystemExit("ERROR: V55 marker missing after transform")

if c.count("SDL_IsTextInputActive() && !tspTextSuppressed()") != 1:
    raise SystemExit("ERROR: engine V55 SDL/text-suppression gate incorrect")

if h.count("#define TEXT_OFF_FLAG") != 1:
    raise SystemExit("ERROR: helper TEXT_OFF_FLAG count incorrect")

if h.count("set_text_suppressed(true)") != 3:
    raise SystemExit(
        "ERROR: expected exactly 3 helper suppress transitions "
        "(TEXT->mouse, TEXT->controller, B->controller)"
    )

if h.count("set_text_suppressed(false)") != 2:
    raise SystemExit(
        "ERROR: expected exactly 2 helper unsuppress paths "
        "(natural text end, controller->TEXT)"
    )

preserve = [
    (c, "TSP_NO_STICKCLICK_MODES_051_V54", "V54 engine"),
    (c, "TSP_CHORD_051_V43", "MENU chord watchdog"),
    (c, "r3=force-text-reset", "R3 helper reset"),
    (c, "tspSetMouseMode(!mTspMouseMode);", "L3 mouse toggle"),
    (h, "TSP_NO_STICKCLICK_MODES_051_V54", "V54 helper"),
    (h, "tsp_request_mouse_mode();", "TEXT left-stick mouse path"),
    (h, "tsp_leave_pointing_mode();", "controller->TEXT MENU path"),
    (h, "EVIOCGRAB", "helper grab"),
]

for text, needle, label in preserve:
    if needle not in text:
        raise SystemExit("ERROR: preserved behavior lost: %s" % label)

for label, text in (("controllermanager.cpp", c), ("tsp_openmw_controls.c", h)):
    if text.count("{") != text.count("}"):
        raise SystemExit("ERROR: brace imbalance in %s" % label)
    if text.count("(") != text.count(")"):
        raise SystemExit("ERROR: paren imbalance in %s" % label)

CM.write_text(c)
HELPER.write_text(h)

print("PATCH PASS:", CM)
print("PATCH PASS:", HELPER)
print("V55 behavior:")
print("  B TEXT -> CONTROLLER publishes /tmp/openmw-tsp-text-off")
print("  MENU TEXT -> CONTROLLER publishes same state")
print("  ControllerManager ignores lingering SDL text focus while suppressed")
print("  natural text end clears suppression automatically")
print("  new controller window clears suppression through existing V50 reset")
PYPATCH

echo
echo "===== 4/11 VERIFY PRE-PATCH BACKUPS DIFFER FROM PATCHED SOURCES ====="

docker exec -i "$C" python3 - "$SOURCE_BACKUP" <<'PYDIFF' | tee -a "$PATCH_LOG"
from pathlib import Path
import hashlib
import sys

backup = Path(sys.argv[1])
root = Path("/root/openmw-0.51-tsp-src")

def sha256(p):
    h = hashlib.sha256()
    with p.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()

pairs = [
    (
        backup / "apps/openmw/mwinput/controllermanager.cpp",
        root / "apps/openmw/mwinput/controllermanager.cpp",
    ),
    (
        backup / "root/tsp_openmw_controls.c",
        Path("/root/tsp_openmw_controls.c"),
    ),
]

for old, new in pairs:
    if not old.is_file() or not new.is_file():
        raise SystemExit("ERROR: verification file missing")
    oh = sha256(old)
    nh = sha256(new)
    if oh == nh:
        raise SystemExit("ERROR: patched source did not change: %s" % new)
    print("PASS:", new)
    print("  before:", oh)
    print("  after :", nh)
PYDIFF

echo
echo "===== 5/11 BUILD AARCH64 HELPER ====="

set +e
docker exec "$C" bash -lc '
set -euo pipefail

SRC=/root/tsp_openmw_controls.c
OUT=/root/tsp_openmw_controls-v55

CC=""
for c in gcc-13 aarch64-linux-gnu-gcc gcc cc; do
    if command -v "$c" >/dev/null 2>&1; then
        CC="$(command -v "$c")"
        break
    fi
done

[ -n "$CC" ] || {
    echo "ERROR: no C compiler available"
    exit 1
}

echo "Compiler: $CC"
"$CC" -O2 -std=gnu11 -Wall -Wextra "$SRC" -o "$OUT"
chmod 755 "$OUT"

echo
echo "ELF:"
readelf -h "$OUT" | grep -E "Class:|Machine:|Type:"
readelf -h "$OUT" | grep -q "AArch64" || {
    echo "ERROR: helper output is not AArch64"
    exit 1
}

grep -a -q "TSP_TEXT_EXIT_CONTROLLER_051_V55 active" "$OUT" || {
    echo "ERROR: helper runtime V55 marker missing"
    exit 1
}

echo
echo "SHA256:"
sha256sum "$OUT"
' 2>&1 | tee "$HELPER_BUILD_LOG"
HELPER_RC=${PIPESTATUS[0]}
set -e

if [ "$HELPER_RC" -ne 0 ]; then
    exit "$HELPER_RC"
fi

echo
echo "===== 6/11 FORCE CONTROLLERMANAGER RECOMPILE + RELINK OPENMW ====="

OLD_BUILD_SHA="$(
docker exec "$C" bash -lc '
B=/root/openmw-0.51-tsp-build/openmw
[ -x "$B" ] && sha256sum "$B" | awk "{print \$1}" || true
'
)"

docker exec "$C" bash -lc '
set -euo pipefail
B=/root/openmw-0.51-tsp-build
S=/root/openmw-0.51-tsp-src

find "$B" -type f -name "controllermanager.cpp.o" -print -delete
rm -fv "$B/openmw" "$B/apps/openmw/openmw"
touch "$S/apps/openmw/mwinput/controllermanager.cpp"
'

set +e
docker exec "$C" bash -lc '
set -o pipefail
cmake --build /root/openmw-0.51-tsp-build \
    --target openmw \
    -- -j4
' 2>&1 | tee "$OPENMW_BUILD_LOG"
OPENMW_RC=${PIPESTATUS[0]}
set -e

if [ "$OPENMW_RC" -ne 0 ]; then
    exit "$OPENMW_RC"
fi

echo
echo "===== 7/11 VERIFY NEW OPENMW + OLD FEATURES ====="

docker exec "$C" bash -lc '
set -euo pipefail
B=/root/openmw-0.51-tsp-build/openmw

test -x "$B"

echo "OpenMW ELF:"
readelf -h "$B" | grep -E "Class:|Machine:|Type:"
readelf -h "$B" | grep -q "AArch64"

echo
echo "New V55:"
grep -a -q "TSP_TEXT_EXIT_CONTROLLER_051_V55" "$B"
echo "PASS: V55 engine marker"

echo
echo "Required preserved markers:"
grep -a -q "TSP_NO_STICKCLICK_MODES_051_V54" "$B"
echo "PASS: V54 no-stick-click"
grep -a -q "TSP_CHORD_051_V43" "$B"
echo "PASS: V43 chord layer"
grep -a -q "r3=force-text-reset" "$B"
echo "PASS: V51 R3 reset"
grep -a -q "tx_cursor.dds" "$B"
echo "PASS: V48 cursor"

echo
echo "SHA256:"
sha256sum "$B"
'

NEW_BUILD_SHA="$(
docker exec "$C" sha256sum /root/openmw-0.51-tsp-build/openmw |
awk '{print $1}'
)"

echo "Previous build SHA: ${OLD_BUILD_SHA:-none}"
echo "New build SHA     : $NEW_BUILD_SHA"

if [ -n "$OLD_BUILD_SHA" ] && [ "$OLD_BUILD_SHA" = "$NEW_BUILD_SHA" ]; then
    echo "ERROR: OpenMW hash did not change after forced recompile."
    exit 1
fi

echo "PASS: OpenMW executable changed."

echo
echo "===== 8/11 PACKAGE EVERYTHING TO ~/Downloads ====="

docker cp \
    "$C:/root/openmw-0.51-tsp-build/openmw" \
    "$PKG/openmw-0.51"

docker cp \
    "$C:/root/tsp_openmw_controls-v55" \
    "$PKG/tsp_openmw_controls"

docker cp \
    "$C:$SRC/apps/openmw/mwinput/controllermanager.cpp" \
    "$PKG/patched-source/apps/openmw/mwinput/controllermanager.cpp"

docker cp \
    "$C:/root/tsp_openmw_controls.c" \
    "$PKG/patched-source/helper/tsp_openmw_controls.c"

docker cp \
    "$C:$SOURCE_BACKUP/." \
    "$PKG/source-backup/"

printf '%s\n' "$SOURCE_BACKUP" > "$PKG/SOURCE_BACKUP_PATH.txt"

cat > "$PKG/BEHAVIOR.txt" <<'EOFBEHAVIOR'
TSP_TEXT_EXIT_CONTROLLER_051_V55

TEXT + B
  Cancel/leave text and immediately restore ordinary controller navigation.
  D-pad works even if the EditBox keeps SDL text focus.

TEXT + MENU
  Helper yields the controller and publishes text-suppressed state.

CONTROLLER + MENU
  Helper may reclaim TEXT if OpenMW still has a live text field.

TEXT/CONTROLLER + left stick
  V54 mouse behavior preserved.

When text focus genuinely ends
  Helper releases its grab and clears text suppression automatically.

TSP S:
  Existing L3/R3 conveniences are preserved.

MENU-held chords:
  Preserved.
EOFBEHAVIOR

(
    cd "$PKG"
    sha256sum openmw-0.51 tsp_openmw_controls > SHA256SUMS.txt
)

echo "Downloads package:"
find "$PKG" -maxdepth 6 -type f -printf '  %P\n'

echo
echo "===== 9/11 SSH CONNECT + BACK UP CURRENT DEVICE FILES ====="

ssh -o BatchMode=yes -o ConnectTimeout=8 "$DEV" '
echo "SSH OK: $(hostname)"
echo "Date: $(date)"
'

if ssh -o BatchMode=yes "$DEV" '
pidof openmw-0.51 >/dev/null 2>&1 ||
pidof openmw >/dev/null 2>&1
'
then
    echo "ERROR: OpenMW is currently running."
    echo "Exit the game normally and rerun this script."
    exit 1
fi

DEV_BIN_BEFORE="$(
ssh "$DEV" "sha256sum '$REMOTE_BIN' | awk '{print \$1}'"
)"
DEV_HELPER_BEFORE="$(
ssh "$DEV" "sha256sum '$REMOTE_HELPER' | awk '{print \$1}'"
)"

echo "Device OpenMW before: $DEV_BIN_BEFORE"
echo "Device helper before: $DEV_HELPER_BEFORE"

ssh "$DEV" "
set -e
test -s '$REMOTE_BIN'
test -s '$REMOTE_HELPER'
mkdir -p '$REMOTE_BACKUP'
cp -p '$REMOTE_BIN' '$REMOTE_BACKUP/openmw-0.51'
cp -p '$REMOTE_HELPER' '$REMOTE_BACKUP/tsp_openmw_controls'
sha256sum \
    '$REMOTE_BACKUP/openmw-0.51' \
    '$REMOTE_BACKUP/tsp_openmw_controls' \
    > '$REMOTE_BACKUP/SHA256SUMS.txt'
sync
"

scp -q "$DEV:$REMOTE_BIN" "$PKG/device-backup/openmw-0.51"
scp -q "$DEV:$REMOTE_HELPER" "$PKG/device-backup/tsp_openmw_controls"

(
    cd "$PKG/device-backup"
    sha256sum openmw-0.51 tsp_openmw_controls > SHA256SUMS.txt
)

echo
echo "===== 10/11 SSH INSTALL OPENMW + HELPER TOGETHER ====="

scp -q "$PKG/openmw-0.51" "$DEV:/tmp/openmw-0.51-v55"
scp -q "$PKG/tsp_openmw_controls" "$DEV:/tmp/tsp_openmw_controls-v55"

ssh "$DEV" "
set -e

test -s /tmp/openmw-0.51-v55
test -s /tmp/tsp_openmw_controls-v55

cp /tmp/openmw-0.51-v55 '$REMOTE_BIN.new'
cp /tmp/tsp_openmw_controls-v55 '$REMOTE_HELPER.new'

chmod 755 '$REMOTE_BIN.new' '$REMOTE_HELPER.new'

mv -f '$REMOTE_BIN.new' '$REMOTE_BIN'
mv -f '$REMOTE_HELPER.new' '$REMOTE_HELPER'

rm -f \
    /tmp/openmw-0.51-v55 \
    /tmp/tsp_openmw_controls-v55 \
    /tmp/openmw-tsp-text-active \
    /tmp/openmw-tsp-text-char \
    /tmp/openmw-tsp-text-char.tmp \
    /tmp/openmw-tsp-text-off \
    /tmp/openmw-tsp-mouse-mode \
    /tmp/openmw-tsp-mouse-request \
    /tmp/openmw-tsp-mouse-active \
    /tmp/openmw-tsp-text-reset

sync
"

echo
echo "===== 11/11 VERIFY REMOTE HASHES + CREATE TRACE COLLECTOR ====="

LOCAL_BIN_SHA="$(sha256sum "$PKG/openmw-0.51" | awk '{print $1}')"
LOCAL_HELPER_SHA="$(sha256sum "$PKG/tsp_openmw_controls" | awk '{print $1}')"

REMOTE_BIN_SHA="$(
ssh "$DEV" "sha256sum '$REMOTE_BIN' | awk '{print \$1}'"
)"
REMOTE_HELPER_SHA="$(
ssh "$DEV" "sha256sum '$REMOTE_HELPER' | awk '{print \$1}'"
)"

echo "OpenMW local : $LOCAL_BIN_SHA"
echo "OpenMW remote: $REMOTE_BIN_SHA"
echo "Helper local : $LOCAL_HELPER_SHA"
echo "Helper remote: $REMOTE_HELPER_SHA"

[ "$LOCAL_BIN_SHA" = "$REMOTE_BIN_SHA" ] || {
    echo "ERROR: remote OpenMW SHA mismatch."
    exit 1
}

[ "$LOCAL_HELPER_SHA" = "$REMOTE_HELPER_SHA" ] || {
    echo "ERROR: remote helper SHA mismatch."
    exit 1
}

cat > "$PKG/collect-v55-text-exit-trace.sh" <<'EOFTRACE'
#!/usr/bin/env bash
set -euo pipefail

DEV="${TSP_DEV:-root@192.168.1.25}"
OUT="${1:-$HOME/Downloads/openmw51-v55-text-exit-trace-$(date +%Y%m%d-%H%M%S).txt}"

{
    echo "=================================================================="
    echo "OPENMW V55 TEXT EXIT TRACE"
    echo "=================================================================="
    ssh "$DEV" 'hostname; date'

    echo
    echo "===== LIVE HELPER STATE ====="
    ssh "$DEV" '
        if [ -f /tmp/tsp_controls_051.log ]; then
            grep -E \
              "TSP_TEXT_EXIT_CONTROLLER_051_V55|TSP_NO_STICKCLICK_MODES_051_V54|CANCEL:|MENU:|MODE=|CONTROLLER GRAB" \
              /tmp/tsp_controls_051.log | tail -240
        else
            echo "/tmp/tsp_controls_051.log absent. Run this while OpenMW is still open for the helper trace."
        fi
    '

    echo
    echo "===== ENGINE EVENTS ====="
    ssh "$DEV" '
        grep -hE \
          "TSP_TEXT_EXIT_CONTROLLER_051_V55|TSP_NO_STICKCLICK_MODES_051_V54|TSP_TEXT_HANDOFF_051_V51|TSP_MOUSE_MODE_051_V38" \
          /mnt/SDCARD/data/ports/openmw51/config-0.51/openmw.log \
          /mnt/SDCARD/tsp_prog.txt \
          2>/dev/null | tail -240 || true
    '

    echo
    echo "===== CURRENT HANDSHAKE FILES ====="
    ssh "$DEV" '
        for f in \
          /tmp/openmw-tsp-text-active \
          /tmp/openmw-tsp-text-char \
          /tmp/openmw-tsp-text-off \
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

chmod +x "$PKG/collect-v55-text-exit-trace.sh"

cat > "$PKG/INSTALL_REPORT.txt" <<EOFREPORT
OpenMW 0.51 TSP text-exit/controller V55

Created:
$(date)

Device:
$DEV

Source backup made BEFORE patch:
$SOURCE_BACKUP

Device rollback directory:
$REMOTE_BACKUP

OpenMW before device SHA:
$DEV_BIN_BEFORE

Helper before device SHA:
$DEV_HELPER_BEFORE

Installed OpenMW SHA:
$REMOTE_BIN_SHA

Installed helper SHA:
$REMOTE_HELPER_SHA

Behavior:
- B while TEXT is active cancels/leaves TEXT and publishes controller mode.
- D-pad controller navigation is allowed if SDL text focus lingers.
- MENU TEXT -> controller uses the same shared suppression state.
- Controller MENU -> TEXT remains available.
- Natural loss of text focus clears suppression automatically.
- V54 left-stick mouse transitions retained.
- TSP S L3/R3 shortcuts retained.
- MENU chord layer retained.
EOFREPORT

echo
echo "=================================================================="
echo "V55 SUCCESS"
echo "=================================================================="
echo
echo "Source backup:"
echo "  $SOURCE_BACKUP"
echo
echo "Downloads package:"
echo "  $PKG"
echo
echo "Device rollback:"
echo "  $REMOTE_BACKUP"
echo
echo "Installed OpenMW SHA:"
echo "  $REMOTE_BIN_SHA"
echo
echo "Installed helper SHA:"
echo "  $REMOTE_HELPER_SHA"
echo
echo "Test this sequence in a text-capable menu:"
echo "  1. enter TEXT controls"
echo "  2. press B"
echo "  3. immediately press D-pad several times"
echo "  4. verify D-pad works without touching MENU"
echo
echo "Then, WHILE THE GAME IS STILL RUNNING, preserve the trace with:"
echo "  $PKG/collect-v55-text-exit-trace.sh"
echo
echo "For the base TSP later, the deployable pair is:"
echo "  $PKG/openmw-0.51"
echo "  $PKG/tsp_openmw_controls"
echo "=================================================================="
