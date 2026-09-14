#!/usr/bin/env bash
set -euo pipefail
set -o pipefail

C="${TSP_DOCKER:-openmw_builder}"
DEV="${TSP_DEV:-root@192.168.1.25}"
SRC=/root/openmw-0.51-tsp-src
BUILD=/root/openmw-0.51-tsp-build
STAMP="$(date +%Y%m%d-%H%M%S)"
PKG="$HOME/Downloads/openmw51-text-exit-latch-v56-$STAMP"

REMOTE_ROOT=/mnt/SDCARD/data/ports/openmw51
REMOTE_BIN="$REMOTE_ROOT/bin/openmw-0.51"
REMOTE_HELPER="$REMOTE_ROOT/tsp_openmw_controls"
REMOTE_BACKUP="$REMOTE_ROOT/backups/text-exit-latch-v56-$STAMP"

PATCH_LOG="$PKG/v56-patch.log"
HELPER_BUILD_LOG="$PKG/v56-helper-build.log"
OPENMW_BUILD_LOG="$PKG/v56-openmw-build.log"

mkdir -p \
    "$PKG/patched-source/apps/openmw/mwinput" \
    "$PKG/patched-source/helper" \
    "$PKG/source-backup" \
    "$PKG/device-backup"

fail_report() {
    rc=$?
    echo
    echo "=================================================================="
    echo "V56 FAILED (exit $rc)"
    echo "=================================================================="
    for f in "$PATCH_LOG" "$HELPER_BUILD_LOG" "$OPENMW_BUILD_LOG"; do
        if [ -f "$f" ]; then
            echo
            echo "----- $(basename "$f") : LAST 180 LINES -----"
            tail -180 "$f" || true
        fi
    done
    echo
    echo "Preserved package/log directory:"
    echo "  $PKG"
    exit "$rc"
}
trap fail_report ERR

echo "=================================================================="
echo "OPENMW 0.51 TSP TEXT-EXIT LATCH V56"
echo "=================================================================="
echo "Docker : $C"
echo "Device : $DEV"
echo "Package: $PKG"
echo
echo "Fix:"
echo "  B from TEXT creates an exit latch."
echo "  Window changes may NOT clear text suppression while that latch exists."
echo "  TEXT may NOT re-grab while the latch exists."
echo "  The latch clears only when OpenMW genuinely reports no active text field."
echo
echo "Preserved:"
echo "  V54 left-stick -> mouse"
echo "  V55 D-pad-with-lingering-SDL-focus fix"
echo "  MENU TEXT <-> CONTROLLER behavior"
echo "  TSP S L3/R3 shortcuts"
echo "  MENU-held chord layer"
echo

echo "===== 1/11 VERIFY EXACT POST-V55 SOURCE ====="

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
    "TSP_TEXT_EXIT_CONTROLLER_051_V55",
    "TSP_NO_STICKCLICK_MODES_051_V54",
    "TSP_TEXT_HANDOFF_051_V51",
    "TSP_CHORD_051_V43",
    'const char* const sTspTextOffFlag = "/tmp/openmw-tsp-text-off";',
    "SDL_IsTextInputActive() && !tspTextSuppressed()",
    "tspSetMouseMode(!mTspMouseMode);",
    "r3=force-text-reset",
]

helper_need = [
    "TSP_TEXT_EXIT_CONTROLLER_051_V55",
    "TSP_NO_STICKCLICK_MODES_051_V54",
    '#define TEXT_OFF_FLAG    "/tmp/openmw-tsp-text-off"',
    "static void set_text_suppressed(bool suppressed)",
    "static void sync_automatic_mode(void)",
    "static void leave_text_mode(void)",
    'log_line("TSP_TEXT_EXIT_CONTROLLER_051_V55 B: TEXT -> CONTROLLER.");',
]

for x in cm_need:
    if x not in c:
        raise SystemExit("ERROR: controllermanager.cpp missing V56 precondition: %s" % x)

for x in helper_need:
    if x not in h:
        raise SystemExit("ERROR: helper source missing V56 precondition: %s" % x)

if "TSP_TEXT_EXIT_LATCH_051_V56" in c or "TSP_TEXT_EXIT_LATCH_051_V56" in h:
    raise SystemExit("ERROR: V56 already present; refusing second application.")

print("PASS: exact post-V55 engine lineage")
print("PASS: exact post-V55 helper lineage")
print("PASS: V56 not already applied")
PYVERIFY

echo
echo "===== 2/11 BACK UP ALL TOUCHED SOURCE BEFORE PATCHING ====="

SOURCE_BACKUP="$SRC/.tsp-051-source-backups/text-exit-latch-v56-$STAMP"

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

def sha256(path):
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()

for src, dst in pairs:
    if not src.is_file():
        raise SystemExit("ERROR: source missing before backup: %s" % src)
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src, dst)

for src, dst in pairs:
    a = sha256(src)
    b = sha256(dst)
    if a != b:
        raise SystemExit("ERROR: backup hash mismatch: %s" % src)
    print("BACKUP PASS:", src)
    print("  SHA256:", a)

Path("/root/openmw51-v56-source-backup-path.txt").write_text(str(backup) + "\n")
print("VERIFIED SOURCE BACKUP:", backup)
PYBACKUP

docker exec "$C" test -d "$SOURCE_BACKUP"

echo
echo "===== 3/11 APPLY V56 EXIT-LATCH PATCH ====="

docker exec -i "$C" python3 <<'PYPATCH' | tee -a "$PATCH_LOG"
from pathlib import Path

root = Path("/root/openmw-0.51-tsp-src")
CM = root / "apps/openmw/mwinput/controllermanager.cpp"
HELPER = Path("/root/tsp_openmw_controls.c")
MARK = "TSP_TEXT_EXIT_LATCH_051_V56"

def once(text, old, new, label):
    count = text.count(old)
    if count != 1:
        raise SystemExit(
            "ERROR: %s anchor matched %d times (expected exactly 1). "
            "NOTHING WRITTEN." % (label, count)
        )
    return text.replace(old, new, 1)

c0 = CM.read_text()
h0 = HELPER.read_text()
c = c0
h = h0

c = once(
    c,
'''        const char* const sTspTextOffFlag = "/tmp/openmw-tsp-text-off";
        bool tspTextSuppressed()
        {''',
'''        const char* const sTspTextOffFlag = "/tmp/openmw-tsp-text-off";

        // TSP_TEXT_EXIT_LATCH_051_V56
        // B from helper TEXT creates this stronger latch. Unlike an ordinary
        // MENU suppression, it survives the immediate controller-window change
        // and is released only after the text field genuinely stops being active.
        const char* const sTspTextExitLatchFlag = "/tmp/openmw-tsp-text-exit-latch";
        bool tspTextExitLatched()
        {
            if (std::FILE* tspFile = std::fopen(sTspTextExitLatchFlag, "r"))
            {
                std::fclose(tspFile);
                return true;
            }
            return false;
        }

        bool tspTextSuppressed()
        {''',
    "engine exit-latch helper",
)

c = once(
    c,
'''                // TSP_INPUT_MODE_051_V49 -- every menu opens in CONTROLLER with the
                // pointer hidden. Leaving and coming back starts clean.
                // TSP_TEXT_TOGGLE_051_V50 -- clear the dismiss too, so each menu
                // starts from the game's own idea of whether it needs text.
                tspSetTextSuppressed(false);
                tspSetTextMode(false);
                std::remove(sTspHelperYieldFlag);
                // TSP_NO_STICKCLICK_MODES_051_V54
                std::remove(sTspMouseRequestFlag);''',
'''                // TSP_INPUT_MODE_051_V49 -- every menu normally starts clean.
                //
                // TSP_TEXT_EXIT_LATCH_051_V56
                // EXCEPTION: B from helper TEXT has stronger semantics than an
                // ordinary MENU mode switch. If the B-exit latch exists, do NOT
                // clear TEXT_OFF or TEXT_ACTIVE here. The helper must see the real
                // text-active edge disappear before another TEXT grab is allowed.
                // Clearing these files here was the race that made:
                // TEXT -> controller -> TEXT -> B
                // immediately fall back into TEXT after returning to the parent UI.
                if (!tspTextExitLatched())
                {
                    tspSetTextSuppressed(false);
                    tspSetTextMode(false);
                }
                else
                {
                    Log(Debug::Info)
                        << "TSP_TEXT_EXIT_LATCH_051_V56"
                        << " window-change=preserve-controller-latch";
                }

                std::remove(sTspHelperYieldFlag);
                // TSP_NO_STICKCLICK_MODES_051_V54
                std::remove(sTspMouseRequestFlag);''',
    "engine window-change race",
)

h = once(
    h,
'''#define TEXT_OFF_FLAG    "/tmp/openmw-tsp-text-off"''',
'''#define TEXT_OFF_FLAG    "/tmp/openmw-tsp-text-off"

/* TSP_TEXT_EXIT_LATCH_051_V56
 * Only B creates this file. It means the user exited the current text dialog
 * and controller mode must remain authoritative until OpenMW reports that the
 * text field is genuinely gone.
 */
#define TEXT_EXIT_LATCH_FLAG "/tmp/openmw-tsp-text-exit-latch"''',
    "helper exit-latch define",
)

h = once(
    h,
'''static void sync_automatic_mode(void)
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
'''static void sync_automatic_mode(void)
{
    const bool active = openmw_text_active();
    const bool exit_latched = access(TEXT_EXIT_LATCH_FLAG, F_OK) == 0;

    /*
     * TSP_TEXT_EXIT_LATCH_051_V56
     *
     * B-exit is authoritative until the real text-active signal disappears.
     * This prevents a nested text dialog from re-grabbing the pad when its
     * EditBox/SDL focus lingers for a few frames after B closes the dialog.
     */
    if (exit_latched) {
        if (!active) {
            unlink(TEXT_EXIT_LATCH_FLAG);
            unlink(MOUSE_MODE_FLAG);
            set_text_suppressed(false);
            if (mode != MODE_GAME)
                set_mode(MODE_GAME);
            log_line("TSP_TEXT_EXIT_LATCH_051_V56 cleared: text field ended.");
            return;
        }

        /*
         * The field is still reported active, so B's controller decision wins.
         * Re-publish TEXT_OFF if anything else removed it and never re-enter TEXT.
         */
        set_text_suppressed(true);
        if (mode != MODE_GAME)
            set_mode(MODE_GAME);
        return;
    }

    /*
     * Ordinary MENU suppression remains reversible. In the non-B case, mirror
     * the shared state so MENU can still switch CONTROLLER -> TEXT normally.
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
    "helper latch-dominant automatic mode",
)

h = once(
    h,
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
'''static void leave_text_mode(void)
{
    log_line("CANCEL: leave/cancel text entry (Escape).");

    // TSP_TEXT_EXIT_CONTROLLER_051_V55
    // B means TEXT -> CONTROLLER immediately.
    set_text_suppressed(true);

    // TSP_TEXT_EXIT_LATCH_051_V56
    // Publish a stronger B-only latch BEFORE Escape/window teardown. The helper
    // will hold ordinary controller mode until TEXT_ACTIVE_FLAG genuinely falls.
    FILE *exit_latch = fopen(TEXT_EXIT_LATCH_FLAG, "w");
    if (exit_latch != NULL) {
        fputs("1\\n", exit_latch);
        fclose(exit_latch);
    } else if (log_file != NULL) {
        fprintf(log_file,
                "TSP_TEXT_EXIT_LATCH_051_V56 could not write %s: %s\\n",
                TEXT_EXIT_LATCH_FLAG, strerror(errno));
        fflush(log_file);
    }

    unlink(MOUSE_MODE_FLAG); /* TSP_TEXT_REMAP_051_V40 */
    tap_key(KEY_ESC);
    set_mode(MODE_GAME);
    log_line("TSP_TEXT_EXIT_LATCH_051_V56 B: TEXT -> CONTROLLER latched.");
}''',
    "helper B exit latch",
)

h = once(
    h,
'''    /* TSP_TEXT_EXIT_CONTROLLER_051_V55 */
    unlink(TEXT_OFF_FLAG);

    controller_fd = find_controller();''',
'''    /* TSP_TEXT_EXIT_CONTROLLER_051_V55 */
    unlink(TEXT_OFF_FLAG);
    /* TSP_TEXT_EXIT_LATCH_051_V56 */
    unlink(TEXT_EXIT_LATCH_FLAG);

    controller_fd = find_controller();''',
    "helper startup latch cleanup",
)

h = once(
    h,
'''    log_line("TSP_TEXT_EXIT_CONTROLLER_051_V55 active.");''',
'''    log_line("TSP_TEXT_EXIT_CONTROLLER_051_V55 active.");
    log_line("TSP_TEXT_EXIT_LATCH_051_V56 active.");''',
    "helper runtime marker",
)

h = once(
    h,
'''    /* TSP_TEXT_EXIT_CONTROLLER_051_V55 */
    unlink(TEXT_OFF_FLAG);

    if (uinput_fd >= 0) {''',
'''    /* TSP_TEXT_EXIT_CONTROLLER_051_V55 */
    unlink(TEXT_OFF_FLAG);
    /* TSP_TEXT_EXIT_LATCH_051_V56 */
    unlink(TEXT_EXIT_LATCH_FLAG);

    if (uinput_fd >= 0) {''',
    "helper shutdown latch cleanup",
)

if MARK not in c or MARK not in h:
    raise SystemExit("ERROR: V56 marker missing after transform")

if c.count("tspTextExitLatched()") != 2:
    raise SystemExit("ERROR: engine exit-latch helper/call count unexpected")

if h.count("#define TEXT_EXIT_LATCH_FLAG") != 1:
    raise SystemExit("ERROR: helper latch define count incorrect")

if h.count("TEXT_EXIT_LATCH_FLAG") < 6:
    raise SystemExit("ERROR: helper latch not wired through lifecycle")

preserve = [
    (c, "TSP_TEXT_EXIT_CONTROLLER_051_V55", "V55 engine"),
    (c, "SDL_IsTextInputActive() && !tspTextSuppressed()", "V55 D-pad gate"),
    (c, "TSP_NO_STICKCLICK_MODES_051_V54", "V54 engine"),
    (c, "TSP_CHORD_051_V43", "MENU chord watchdog"),
    (c, "tspSetMouseMode(!mTspMouseMode);", "L3 mouse toggle"),
    (c, "r3=force-text-reset", "R3 text reset"),
    (h, "TSP_TEXT_EXIT_CONTROLLER_051_V55", "V55 helper"),
    (h, "TSP_NO_STICKCLICK_MODES_051_V54", "V54 helper"),
    (h, "tsp_request_mouse_mode();", "left-stick TEXT->mouse"),
    (h, "tsp_leave_pointing_mode();", "MENU controller->TEXT"),
    (h, "EVIOCGRAB", "helper controller grab"),
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
print()
print("V56 logic:")
print("  B creates /tmp/openmw-tsp-text-exit-latch")
print("  engine window change preserves B suppression while latch exists")
print("  helper refuses TEXT re-grab while latch + text-active coexist")
print("  latch clears only after text-active genuinely disappears")
print("  ordinary MENU cycling remains reversible")
PYPATCH

echo
echo "===== 4/11 VERIFY BACKUPS REMAIN PRE-PATCH AND SOURCES CHANGED ====="

docker exec -i "$C" python3 - "$SOURCE_BACKUP" <<'PYDIFF' | tee -a "$PATCH_LOG"
from pathlib import Path
import hashlib
import sys

backup = Path(sys.argv[1])
root = Path("/root/openmw-0.51-tsp-src")

def sha256(path):
    h = hashlib.sha256()
    with path.open("rb") as f:
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
    print("  pre-patch:", oh)
    print("  patched  :", nh)
PYDIFF

echo
echo "===== 5/11 BUILD AARCH64 HELPER ====="

set +e
docker exec "$C" bash -lc '
set -euo pipefail
SRC=/root/tsp_openmw_controls.c
OUT=/root/tsp_openmw_controls-v56

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
    echo "ERROR: helper is not AArch64"
    exit 1
}

grep -a -q "TSP_TEXT_EXIT_LATCH_051_V56 active" "$OUT" || {
    echo "ERROR: V56 helper runtime marker missing"
    exit 1
}

grep -a -q "TSP_TEXT_EXIT_CONTROLLER_051_V55 active" "$OUT" || {
    echo "ERROR: V55 helper marker was lost"
    exit 1
}

echo
echo "SHA256:"
sha256sum "$OUT"
' 2>&1 | tee "$HELPER_BUILD_LOG"
HELPER_RC=${PIPESTATUS[0]}
set -e
[ "$HELPER_RC" -eq 0 ]

echo
echo "===== 6/11 FORCE INPUT OBJECT RECOMPILE + OPENMW RELINK ====="

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
echo "===== 7/11 VERIFY NEW OPENMW + PRESERVED CONTROLLER FEATURES ====="

docker exec "$C" bash -lc '
set -euo pipefail
B=/root/openmw-0.51-tsp-build/openmw
test -x "$B"

echo "OpenMW ELF:"
readelf -h "$B" | grep -E "Class:|Machine:|Type:"
readelf -h "$B" | grep -q "AArch64"

echo
grep -a -q "TSP_TEXT_EXIT_LATCH_051_V56" "$B"
echo "PASS: V56 latch"
grep -a -q "TSP_TEXT_EXIT_CONTROLLER_051_V55" "$B"
echo "PASS: V55 text-exit controller"
grep -a -q "TSP_NO_STICKCLICK_MODES_051_V54" "$B"
echo "PASS: V54 no-stick-click modes"
grep -a -q "TSP_CHORD_051_V43" "$B"
echo "PASS: V43 chord layer"
grep -a -q "r3=force-text-reset" "$B"
echo "PASS: R3 text reset"
grep -a -q "tx_cursor.dds" "$B"
echo "PASS: custom cursor"

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
    echo "ERROR: OpenMW hash did not change after forced V56 recompile."
    exit 1
fi

echo "PASS: OpenMW binary changed."

echo
echo "===== 8/11 PACKAGE BUILD + SOURCE + BACKUPS TO ~/Downloads ====="

docker cp "$C:/root/openmw-0.51-tsp-build/openmw" "$PKG/openmw-0.51"
docker cp "$C:/root/tsp_openmw_controls-v56" "$PKG/tsp_openmw_controls"

docker cp \
    "$C:$SRC/apps/openmw/mwinput/controllermanager.cpp" \
    "$PKG/patched-source/apps/openmw/mwinput/controllermanager.cpp"

docker cp \
    "$C:/root/tsp_openmw_controls.c" \
    "$PKG/patched-source/helper/tsp_openmw_controls.c"

docker cp "$C:$SOURCE_BACKUP/." "$PKG/source-backup/"
printf '%s\n' "$SOURCE_BACKUP" > "$PKG/SOURCE_BACKUP_PATH.txt"

cat > "$PKG/BEHAVIOR.txt" <<'EOFBEHAVIOR'
TSP_TEXT_EXIT_LATCH_051_V56

Reproduction fixed:
  barter
    -> stacked-item text dialog
    -> TEXT
    -> MENU -> CONTROLLER
    -> MENU -> TEXT
    -> B
    -> parent barter menu stays CONTROLLER

Rule:
  B from TEXT creates a B-only exit latch.
  The latch survives immediate nested-window changes.
  The helper cannot re-enter TEXT while that latch exists.
  The latch clears automatically only when OpenMW reports that the text
  field genuinely ended.

Preserved:
  ordinary MENU TEXT <-> CONTROLLER cycling
  V54 left-stick -> mouse
  V55 D-pad controller navigation with lingering SDL EditBox focus
  TSP S L3/R3 shortcuts
  MENU-held chord layer
EOFBEHAVIOR

(
    cd "$PKG"
    sha256sum openmw-0.51 tsp_openmw_controls > SHA256SUMS.txt
)

echo
echo "===== 9/11 SSH CONNECT + BACK UP CURRENT TSP S FILES ====="

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
    echo "Exit Morrowind normally, then rerun this V56 controller."
    exit 1
fi

DEV_BIN_BEFORE="$(
ssh "$DEV" "sha256sum '$REMOTE_BIN' | awk '{print \$1}'"
)"
DEV_HELPER_BEFORE="$(
ssh "$DEV" "sha256sum '$REMOTE_HELPER' | awk '{print \$1}'"
)"

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
echo "===== 10/11 INSTALL V56 OPENMW + HELPER TOGETHER ====="

scp -q "$PKG/openmw-0.51" "$DEV:/tmp/openmw-0.51-v56"
scp -q "$PKG/tsp_openmw_controls" "$DEV:/tmp/tsp_openmw_controls-v56"

ssh "$DEV" "
set -e
test -s /tmp/openmw-0.51-v56
test -s /tmp/tsp_openmw_controls-v56

cp /tmp/openmw-0.51-v56 '$REMOTE_BIN.new'
cp /tmp/tsp_openmw_controls-v56 '$REMOTE_HELPER.new'
chmod 755 '$REMOTE_BIN.new' '$REMOTE_HELPER.new'
mv -f '$REMOTE_BIN.new' '$REMOTE_BIN'
mv -f '$REMOTE_HELPER.new' '$REMOTE_HELPER'

rm -f \
    /tmp/openmw-0.51-v56 \
    /tmp/tsp_openmw_controls-v56 \
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

cat > "$PKG/collect-v56-text-exit-trace.sh" <<'EOFTRACE'
#!/usr/bin/env bash
set -euo pipefail
DEV="${TSP_DEV:-root@192.168.1.25}"
OUT="${1:-$HOME/Downloads/openmw51-v56-text-exit-trace-$(date +%Y%m%d-%H%M%S).txt}"

{
    echo "=================================================================="
    echo "OPENMW V56 TEXT EXIT LATCH TRACE"
    echo "=================================================================="
    ssh "$DEV" 'hostname; date'

    echo
    echo "===== LIVE HELPER EVENTS ====="
    ssh "$DEV" '
        if [ -f /tmp/tsp_controls_051.log ]; then
            grep -E \
              "TSP_TEXT_EXIT_LATCH_051_V56|TSP_TEXT_EXIT_CONTROLLER_051_V55|TSP_NO_STICKCLICK_MODES_051_V54|CANCEL:|MENU:|MODE=|CONTROLLER GRAB" \
              /tmp/tsp_controls_051.log | tail -300
        else
            echo "/tmp/tsp_controls_051.log absent; run while OpenMW is still running."
        fi
    '

    echo
    echo "===== ENGINE EVENTS ====="
    ssh "$DEV" '
        grep -hE \
          "TSP_TEXT_EXIT_LATCH_051_V56|TSP_TEXT_EXIT_CONTROLLER_051_V55|TSP_NO_STICKCLICK_MODES_051_V54|TSP_TEXT_HANDOFF_051_V51|TSP_MOUSE_MODE_051_V38" \
          /mnt/SDCARD/data/ports/openmw51/config-0.51/openmw.log \
          /mnt/SDCARD/tsp_prog.txt \
          2>/dev/null | tail -300 || true
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
chmod +x "$PKG/collect-v56-text-exit-trace.sh"

cat > "$PKG/INSTALL_REPORT.txt" <<EOFREPORT
OpenMW 0.51 TSP Text Exit Latch V56
Created: $(date)
Device: $DEV

Source backup:
$SOURCE_BACKUP

Device rollback:
$REMOTE_BACKUP

OpenMW before:
$DEV_BIN_BEFORE

Helper before:
$DEV_HELPER_BEFORE

Installed OpenMW:
$REMOTE_BIN_SHA

Installed helper:
$REMOTE_HELPER_SHA

Primary fix:
TEXT -> MENU/controller -> MENU/TEXT -> B can no longer re-enter TEXT
during nested-dialog teardown. B remains controller-latched until the
real text-active signal disappears.
EOFREPORT

echo
echo "=================================================================="
echo "V56 SUCCESS"
echo "=================================================================="
echo "Package:"
echo "  $PKG"
echo
echo "Source rollback:"
echo "  $SOURCE_BACKUP"
echo
echo "Device rollback:"
echo "  $REMOTE_BACKUP"
echo
echo "Test EXACTLY:"
echo "  barter -> stacked item -> MENU -> MENU -> B -> D-pad"
echo
echo "Expected:"
echo "  regular controller navigation immediately; no MENU recovery needed."
echo
echo "Trace collector:"
echo "  $PKG/collect-v56-text-exit-trace.sh"
echo "=================================================================="
