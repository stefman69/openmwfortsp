#!/usr/bin/env bash
set -Eeuo pipefail
set -o pipefail

C="${TSP_DOCKER:-openmw_builder}"
DEV="${TSP_DEV:-root@192.168.1.25}"
SRC="/root/openmw-0.51-tsp-src"
BUILD="/root/openmw-0.51-tsp-build"

STAMP="$(date +%Y%m%d-%H%M%S)"
PKG="$HOME/Downloads/openmw51-b-exit-menu-handoff-v57-$STAMP"

CM="$SRC/apps/openmw/mwinput/controllermanager.cpp"
HELPER_SRC="/root/tsp_openmw_controls.c"

OPENMW_BIN="$BUILD/openmw"
HELPER_BIN="/root/tsp_openmw_controls-v57"

REMOTE_ROOT="/mnt/SDCARD/data/ports/openmw51"
REMOTE_BIN="$REMOTE_ROOT/bin/openmw-0.51"
REMOTE_HELPER="$REMOTE_ROOT/tsp_openmw_controls"
REMOTE_BACKUP="$REMOTE_ROOT/backups/b-exit-menu-handoff-v57-$STAMP"

PATCH_LOG="$PKG/v57-patch.log"
HELPER_BUILD_LOG="$PKG/v57-helper-build.log"
OPENMW_BUILD_LOG="$PKG/v57-openmw-build.log"

mkdir -p \
    "$PKG/patched-source/apps/openmw/mwinput" \
    "$PKG/patched-source/helper" \
    "$PKG/source-backup" \
    "$PKG/device-backup" \
    "$PKG/logs"

fail_report() {
    local rc="${1:-1}"
    local line="${2:-unknown}"
    local cmd="${3:-unknown}"

    # TSP_TERMINAL_SAFE_ERROR_V1
    # Never let the error reporter recursively trigger itself.
    trap - ERR
    set +e

    local report="$PKG/STOPPED_ERROR.txt"

    {
        echo
        echo "=================================================================="
        echo "V57 STOPPED SAFELY"
        echo "=================================================================="
        echo "Date: $(date)"
        echo "Exit code: $rc"
        echo "Script line: $line"
        echo "Failing command:"
        echo "  $cmd"
        echo

        for f in "$PATCH_LOG" "$HELPER_BUILD_LOG" "$OPENMW_BUILD_LOG"; do
            if [ -f "$f" ]; then
                echo
                echo "----- $(basename "$f") : LAST 180 LINES -----"
                tail -180 "$f" || true
            fi
        done

        echo
        echo "Nothing after the failed step will be run."
        echo
        echo "Everything produced so far is preserved at:"
        echo "  $PKG"
        echo
        echo "Error report:"
        echo "  $report"
        echo "=================================================================="
    } 2>&1 | tee "$report"

    echo
    echo "SCRIPT STOPPED. THE TERMINAL WILL BE LEFT OPEN."

    if [ -t 0 ]; then
        echo
        read -r -p "Press Enter to return to the shell... " _ || true
    fi

    exit "$rc"
}

trap 'fail_report "$?" "$LINENO" "$BASH_COMMAND"' ERR

echo "=================================================================="
echo "OPENMW 0.51 TSP B-EXIT + MENU-HANDOFF V57"
echo "=================================================================="
echo
echo "This replaces the failed V56 B-exit latch."
echo
echo "New B behavior while helper TEXT controls own the pad:"
echo
echo "  1. run the EXACT existing MENU TEXT->CONTROLLER transition"
echo "     (tsp_enter_pointing_mode)"
echo "  2. inject Escape to close/cancel the text dialog"
echo
echo "Therefore B means:"
echo "  TEXT -> CONTROLLER -> close text dialog"
echo
echo "The parent menu is left in ordinary controller navigation."
echo
echo "V56 latch logic is removed."
echo "V55 lingering-SDL-focus controller navigation is retained."
echo "V54 left-stick mouse behavior is retained."
echo

echo "===== 1/11 VERIFY EXACT CURRENT POST-V56 SOURCE ====="

docker exec -i "$C" python3 <<'PYVERIFY' | tee "$PATCH_LOG"
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
    "TSP_TEXT_EXIT_LATCH_051_V56",
    "TSP_TEXT_EXIT_CONTROLLER_051_V55",
    "TSP_NO_STICKCLICK_MODES_051_V54",
    "TSP_TEXT_HANDOFF_051_V51",
    "TSP_CHORD_051_V43",
    'const char* const sTspTextExitLatchFlag = "/tmp/openmw-tsp-text-exit-latch";',
    "bool tspTextExitLatched()",
    "if (!tspTextExitLatched())",
    "SDL_IsTextInputActive() && !tspTextSuppressed()",
]

required_helper = [
    "TSP_TEXT_EXIT_LATCH_051_V56",
    "TSP_TEXT_EXIT_CONTROLLER_051_V55",
    "TSP_NO_STICKCLICK_MODES_051_V54",
    '#define TEXT_EXIT_LATCH_FLAG "/tmp/openmw-tsp-text-exit-latch"',
    "const bool exit_latched = access(TEXT_EXIT_LATCH_FLAG, F_OK) == 0;",
    'log_line("TSP_TEXT_EXIT_LATCH_051_V56 B: TEXT -> CONTROLLER latched.");',
    "static void tsp_enter_pointing_mode(void)",
    "static void leave_text_mode(void)",
]

for needle in required_engine:
    if needle not in c:
        raise SystemExit(
            "ERROR: controllermanager.cpp does not match expected post-V56 source:\n"
            "  missing: %s\n"
            "NO SOURCE HAS BEEN MODIFIED." % needle
        )

for needle in required_helper:
    if needle not in h:
        raise SystemExit(
            "ERROR: tsp_openmw_controls.c does not match expected post-V56 source:\n"
            "  missing: %s\n"
            "NO SOURCE HAS BEEN MODIFIED." % needle
        )

if "TSP_B_EXIT_MENU_HANDOFF_051_V57" in c or "TSP_B_EXIT_MENU_HANDOFF_051_V57" in h:
    raise SystemExit(
        "ERROR: V57 already appears in source. Refusing a second application."
    )

print("PASS: controllermanager.cpp is the expected post-V56 source")
print("PASS: tsp_openmw_controls.c is the expected post-V56 source")
print("PASS: V55/V54/controller lineage is present")
print("PASS: V57 is not already applied")
PYVERIFY

echo
echo "===== 2/11 CREATE + VERIFY PRE-PATCH SOURCE BACKUPS ====="

SOURCE_BACKUP="$SRC/.tsp-051-source-backups/b-exit-menu-handoff-v57-$STAMP"

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
        raise SystemExit("ERROR: source vanished before backup: %s" % src)

    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src, dst)

for src, dst in pairs:
    src_hash = sha256(src)
    dst_hash = sha256(dst)

    if src_hash != dst_hash:
        raise SystemExit(
            "ERROR: backup hash mismatch for %s.\n"
            "PATCH ABORTED BEFORE SOURCE EDIT." % src
        )

    print("BACKUP PASS:", src)
    print("  SHA256:", src_hash)

Path("/root/openmw51-v57-source-backup-path.txt").write_text(str(backup) + "\n")
print()
print("VERIFIED SOURCE BACKUP:")
print(backup)
PYBACKUP

docker exec "$C" test -d "$SOURCE_BACKUP"

echo
echo "===== 3/11 APPLY V57 ====="

docker exec -i "$C" python3 <<'PYPATCH' | tee -a "$PATCH_LOG"
from pathlib import Path

root = Path("/root/openmw-0.51-tsp-src")
CM = root / "apps/openmw/mwinput/controllermanager.cpp"
HELPER = Path("/root/tsp_openmw_controls.c")

MARK = "TSP_B_EXIT_MENU_HANDOFF_051_V57"

def replace_once(text, old, new, label):
    count = text.count(old)

    if count != 1:
        raise SystemExit(
            "ERROR: %s anchor matched %d times; expected exactly 1.\n"
            "NOTHING HAS BEEN WRITTEN." % (label, count)
        )

    return text.replace(old, new, 1)

c0 = CM.read_text()
h0 = HELPER.read_text()
c = c0
h = h0

# ================================================================
# ENGINE
#
# Remove V56's special B latch. Return the window-change reset to
# the V55 behavior. B will no longer depend on engine-side latch state.
# ================================================================

engine_latch_helper = '''        const char* const sTspTextOffFlag = "/tmp/openmw-tsp-text-off";

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
        {'''

engine_latch_helper_replacement = '''        const char* const sTspTextOffFlag = "/tmp/openmw-tsp-text-off";

        bool tspTextSuppressed()
        {'''

c = replace_once(
    c,
    engine_latch_helper,
    engine_latch_helper_replacement,
    "remove V56 engine latch helper",
)

engine_window_v56 = '''                // TSP_INPUT_MODE_051_V49 -- every menu normally starts clean.
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
                std::remove(sTspMouseRequestFlag);'''

engine_window_v57 = '''                // TSP_INPUT_MODE_051_V49 -- every menu opens in CONTROLLER with the
                // pointer hidden. Leaving and coming back starts clean.
                // TSP_TEXT_TOGGLE_051_V50 -- clear the dismiss too, so each menu
                // starts from the game's own idea of whether it needs text.
                //
                // TSP_B_EXIT_MENU_HANDOFF_051_V57
                // B no longer needs a special engine latch. The helper performs
                // the same TEXT->CONTROLLER handoff as MENU before it injects
                // Escape, so the newly exposed parent window may use this normal
                // clean-window reset again.
                tspSetTextSuppressed(false);
                tspSetTextMode(false);
                std::remove(sTspHelperYieldFlag);
                // TSP_NO_STICKCLICK_MODES_051_V54
                std::remove(sTspMouseRequestFlag);'''

c = replace_once(
    c,
    engine_window_v56,
    engine_window_v57,
    "restore ordinary engine window-change reset",
)

# ================================================================
# HELPER
#
# Remove V56 latch declaration and automatic-mode logic.
# Restore V55 automatic reconciliation.
# ================================================================

helper_latch_define = '''#define TEXT_OFF_FLAG    "/tmp/openmw-tsp-text-off"

/* TSP_TEXT_EXIT_LATCH_051_V56
 * Only B creates this file. It means the user exited the current text dialog
 * and controller mode must remain authoritative until OpenMW reports that the
 * text field is genuinely gone.
 */
#define TEXT_EXIT_LATCH_FLAG "/tmp/openmw-tsp-text-exit-latch"'''

helper_latch_define_replacement = '''#define TEXT_OFF_FLAG    "/tmp/openmw-tsp-text-off"'''

h = replace_once(
    h,
    helper_latch_define,
    helper_latch_define_replacement,
    "remove helper V56 latch define",
)

helper_sync_v56 = '''static void sync_automatic_mode(void)
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
}'''

helper_sync_v55 = '''static void sync_automatic_mode(void)
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
}'''

h = replace_once(
    h,
    helper_sync_v56,
    helper_sync_v55,
    "restore V55 helper automatic reconciliation",
)

# ================================================================
# B behavior:
#
# THIS is the real V57 change.
#
# Instead of manually manufacturing a B-specific mode, call the exact
# function MENU uses in TEXT mode. That function:
#   - set_text_suppressed(true)
#   - writes MOUSE_MODE_FLAG
#   - releases EVIOCGRAB via set_mode(MODE_GAME)
#
# Then inject Escape to close the text dialog.
#
# Controller state exists BEFORE the dialog/window is torn down.
# ================================================================

helper_b_v56 = '''static void leave_text_mode(void)
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
}'''

helper_b_v57 = '''static void leave_text_mode(void)
{
    /*
     * TSP_B_EXIT_MENU_HANDOFF_051_V57
     *
     * B is deliberately TWO operations:
     *
     *   1. do exactly what MENU does while TEXT owns the pad:
     *          tsp_enter_pointing_mode()
     *      This publishes controller suppression, yields EVIOCGRAB and enters
     *      normal OpenMW controller passthrough.
     *
     *   2. inject Escape to close/cancel the text dialog.
     *
     * The ordering matters. Controller mode is established BEFORE the dialog
     * changes windows, so the parent barter/menu UI is exposed with the normal
     * controller scheme already active.
     *
     * This intentionally replaces V56's B-specific kill/latch mechanism.
     */
    log_line("TSP_B_EXIT_MENU_HANDOFF_051_V57 B: MENU handoff -> Escape.");

    tsp_enter_pointing_mode();
    tap_key(KEY_ESC);
}'''

h = replace_once(
    h,
    helper_b_v56,
    helper_b_v57,
    "replace V56 B latch with exact MENU handoff + Escape",
)

# Remove V56 startup latch cleanup.
h = replace_once(
    h,
'''    /* TSP_TEXT_EXIT_CONTROLLER_051_V55 */
    unlink(TEXT_OFF_FLAG);
    /* TSP_TEXT_EXIT_LATCH_051_V56 */
    unlink(TEXT_EXIT_LATCH_FLAG);

    controller_fd = find_controller();''',
'''    /* TSP_TEXT_EXIT_CONTROLLER_051_V55 */
    unlink(TEXT_OFF_FLAG);

    controller_fd = find_controller();''',
    "remove V56 startup latch cleanup",
)

# Replace startup marker so runtime binary proves V57 is installed.
h = replace_once(
    h,
'''    log_line("TSP_TEXT_EXIT_CONTROLLER_051_V55 active.");
    log_line("TSP_TEXT_EXIT_LATCH_051_V56 active.");''',
'''    log_line("TSP_TEXT_EXIT_CONTROLLER_051_V55 active.");
    log_line("TSP_B_EXIT_MENU_HANDOFF_051_V57 active.");''',
    "replace V56 runtime marker with V57",
)

# Remove V56 shutdown latch cleanup.
h = replace_once(
    h,
'''    /* TSP_TEXT_EXIT_CONTROLLER_051_V55 */
    unlink(TEXT_OFF_FLAG);
    /* TSP_TEXT_EXIT_LATCH_051_V56 */
    unlink(TEXT_EXIT_LATCH_FLAG);

    if (uinput_fd >= 0) {''',
'''    /* TSP_TEXT_EXIT_CONTROLLER_051_V55 */
    unlink(TEXT_OFF_FLAG);

    if (uinput_fd >= 0) {''',
    "remove V56 shutdown latch cleanup",
)

# ================================================================
# VERIFY COMPLETE TRANSFORM BEFORE WRITING EITHER FILE
# ================================================================

required_after_engine = [
    "TSP_B_EXIT_MENU_HANDOFF_051_V57",
    "TSP_TEXT_EXIT_CONTROLLER_051_V55",
    "TSP_NO_STICKCLICK_MODES_051_V54",
    "TSP_CHORD_051_V43",
    "SDL_IsTextInputActive() && !tspTextSuppressed()",
    "tspSetTextSuppressed(false);",
    "tspSetTextMode(false);",
]

required_after_helper = [
    "TSP_B_EXIT_MENU_HANDOFF_051_V57",
    "TSP_TEXT_EXIT_CONTROLLER_051_V55",
    "TSP_NO_STICKCLICK_MODES_051_V54",
    'log_line("TSP_B_EXIT_MENU_HANDOFF_051_V57 active.");',
    "tsp_enter_pointing_mode();",
    "tap_key(KEY_ESC);",
    "set_text_suppressed(true);",
    "EVIOCGRAB",
]

for needle in required_after_engine:
    if needle not in c:
        raise SystemExit("ERROR: transformed engine missing: %s" % needle)

for needle in required_after_helper:
    if needle not in h:
        raise SystemExit("ERROR: transformed helper missing: %s" % needle)

# V56 must be completely gone from active source, not just disabled.
if "TSP_TEXT_EXIT_LATCH_051_V56" in c:
    raise SystemExit("ERROR: V56 engine latch marker remains after transform")

if "sTspTextExitLatchFlag" in c or "tspTextExitLatched" in c:
    raise SystemExit("ERROR: V56 engine latch code remains after transform")

if "TEXT_EXIT_LATCH_FLAG" in h:
    raise SystemExit("ERROR: V56 helper latch code remains after transform")

if "TSP_TEXT_EXIT_LATCH_051_V56" in h:
    raise SystemExit("ERROR: V56 helper marker remains after transform")

# The new B function must call MENU handoff BEFORE Escape.
start = h.index("static void leave_text_mode(void)")
end = h.index("static void handle_key_event", start)
b_func = h[start:end]

if b_func.count("tsp_enter_pointing_mode();") != 1:
    raise SystemExit("ERROR: V57 B function does not call MENU handoff exactly once")

if b_func.count("tap_key(KEY_ESC);") != 1:
    raise SystemExit("ERROR: V57 B function does not inject Escape exactly once")

if b_func.index("tsp_enter_pointing_mode();") > b_func.index("tap_key(KEY_ESC);"):
    raise SystemExit("ERROR: V57 B ordering is wrong; controller handoff must precede Escape")

# Preserve MENU's own TEXT path.
menu_path = '''    } else if (event->code == KEY_TSP_MENU) {
        tsp_enter_pointing_mode();'''

if menu_path not in h:
    raise SystemExit("ERROR: original MENU TEXT->CONTROLLER path was lost")

# Preserve controller->TEXT MENU route.
if "tsp_leave_pointing_mode();" not in h:
    raise SystemExit("ERROR: MENU controller->TEXT route was lost")

# Preserve V54 mouse path.
if "tsp_request_mouse_mode();" not in h:
    raise SystemExit("ERROR: V54 left-stick mouse path was lost")

# Basic syntax structure checks.
for label, text in (
    ("controllermanager.cpp", c),
    ("tsp_openmw_controls.c", h),
):
    if text.count("{") != text.count("}"):
        raise SystemExit("ERROR: brace imbalance in %s" % label)

    if text.count("(") != text.count(")"):
        raise SystemExit("ERROR: parenthesis imbalance in %s" % label)

# Only now write both transformed files.
CM.write_text(c)
HELPER.write_text(h)

print("PATCH PASS:", CM)
print("PATCH PASS:", HELPER)
print()
print("V57:")
print("  removed failed V56 B-specific latch")
print("  retained V55 controller/text suppression support")
print("  B now invokes exact existing MENU TEXT->CONTROLLER function")
print("  B then injects Escape")
print("  MENU cycling remains unchanged")
print("  V54 left-stick mouse remains unchanged")
PYPATCH

echo
echo "===== 4/11 VERIFY PATCHED FILES AGAINST PRE-PATCH BACKUPS ====="

docker exec -i "$C" python3 - "$SOURCE_BACKUP" <<'PYDIFF' | tee -a "$PATCH_LOG"
from pathlib import Path
import hashlib
import sys

root = Path("/root/openmw-0.51-tsp-src")
backup = Path(sys.argv[1])

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

def sha256(path):
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()

for old, new in pairs:
    if not old.is_file() or not new.is_file():
        raise SystemExit("ERROR: verification file missing")

    old_hash = sha256(old)
    new_hash = sha256(new)

    if old_hash == new_hash:
        raise SystemExit("ERROR: patched source did not change: %s" % new)

    print("PASS:", new)
    print("  before:", old_hash)
    print("  after :", new_hash)

c = (root / "apps/openmw/mwinput/controllermanager.cpp").read_text()
h = Path("/root/tsp_openmw_controls.c").read_text()

if "TSP_B_EXIT_MENU_HANDOFF_051_V57" not in c:
    raise SystemExit("ERROR: engine V57 marker absent")

if "TSP_B_EXIT_MENU_HANDOFF_051_V57" not in h:
    raise SystemExit("ERROR: helper V57 marker absent")

if "TEXT_EXIT_LATCH_FLAG" in h:
    raise SystemExit("ERROR: old helper V56 latch remains")

if "tspTextExitLatched" in c:
    raise SystemExit("ERROR: old engine V56 latch remains")

print()
print("PASS: V57 source is internally consistent.")
PYDIFF

echo
echo "===== 5/11 BUILD V57 AARCH64 HELPER ====="

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
    echo "ERROR: no C compiler available."
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
echo "ELF:"
readelf -h "$OUT" |
    grep -E "Class:|Machine:|Type:"

readelf -h "$OUT" |
    grep -q "AArch64" || {
        echo "ERROR: helper is not AArch64."
        exit 1
    }

grep -a -q \
    "TSP_B_EXIT_MENU_HANDOFF_051_V57 active" \
    "$OUT" || {
        echo "ERROR: helper V57 runtime marker missing."
        exit 1
    }

grep -a -q \
    "TSP_TEXT_EXIT_CONTROLLER_051_V55 active" \
    "$OUT" || {
        echo "ERROR: helper V55 support was lost."
        exit 1
    }

if grep -a -q \
    "TSP_TEXT_EXIT_LATCH_051_V56 active" \
    "$OUT"
then
    echo "ERROR: old V56 runtime latch marker remains in helper."
    exit 1
fi

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
echo "===== 6/11 FORCE CONTROLLER RECOMPILE + OPENMW RELINK ====="

OLD_OPENMW_SHA="$(
docker exec "$C" bash -lc '
B=/root/openmw-0.51-tsp-build/openmw
if [ -x "$B" ]; then
    sha256sum "$B" | awk "{print \$1}"
fi
'
)"

docker exec "$C" bash -lc '
set -euo pipefail

B=/root/openmw-0.51-tsp-build
S=/root/openmw-0.51-tsp-src

find "$B" \
    -type f \
    -name "controllermanager.cpp.o" \
    -print \
    -delete

rm -fv \
    "$B/openmw" \
    "$B/apps/openmw/openmw"

touch \
    "$S/apps/openmw/mwinput/controllermanager.cpp"
'

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
    echo
    echo "OPENMW BUILD FAILED."
    echo
    echo "Last 180 lines:"
    tail -180 "$OPENMW_BUILD_LOG"
    exit "$OPENMW_RC"
fi

echo
echo "===== 7/11 VERIFY NEW OPENMW + PRESERVED FEATURES ====="

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
echo "--- V57 source/build lineage ---"

grep -F -q \
    "TSP_B_EXIT_MENU_HANDOFF_051_V57" \
    "$S"
echo "PASS: V57 source"

grep -F -q \
    "SDL_IsTextInputActive() && !tspTextSuppressed()" \
    "$S"
echo "PASS: V55 functional controller/text gate"

if grep -F -q \
    "tspTextExitLatched" \
    "$S"
then
    echo "ERROR: V56 engine latch remains."
    exit 1
fi
echo "PASS: V56 engine latch removed"

echo
echo "--- preserved runtime markers ---"

for marker in \
    TSP_B_EXIT_MENU_HANDOFF_051_V57 \
    TSP_NO_STICKCLICK_MODES_051_V54 \
    TSP_CHORD_051_V43
do
    grep -a -q "$marker" "$B" || {
        echo "FAIL: missing runtime marker $marker"
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
echo "--- SHA256 ---"
sha256sum "$B"
'

NEW_OPENMW_SHA="$(
docker exec "$C" \
    sha256sum "$OPENMW_BIN" |
    awk '{print $1}'
)"

echo
echo "Previous OpenMW SHA: ${OLD_OPENMW_SHA:-none}"
echo "New OpenMW SHA:      $NEW_OPENMW_SHA"

if [ -n "$OLD_OPENMW_SHA" ] && [ "$OLD_OPENMW_SHA" = "$NEW_OPENMW_SHA" ]; then
    echo "ERROR: OpenMW SHA did not change after forced V57 rebuild."
    exit 1
fi

echo "PASS: rebuilt OpenMW binary changed."

echo
echo "===== 8/11 PACKAGE V57 TO ~/Downloads ====="

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

docker cp \
    "$C:$SOURCE_BACKUP/." \
    "$PKG/source-backup/"

printf '%s\n' \
    "$SOURCE_BACKUP" \
    > "$PKG/SOURCE_BACKUP_PATH.txt"

cat > "$PKG/BEHAVIOR.txt" <<'EOFBEHAVIOR'
TSP_B_EXIT_MENU_HANDOFF_051_V57

Purpose
-------

Fix this exact sequence:

  barter
  -> stacked-item text dialog
  -> TEXT
  -> MENU to normal controller controls
  -> MENU back to TEXT
  -> optionally type
  -> B to exit the text dialog
  -> parent barter menu

Expected parent state:
  NORMAL CONTROLLER CONTROLS

Implementation
--------------

B while helper TEXT mode is active performs exactly two operations:

  1. tsp_enter_pointing_mode()

     This is the exact existing function used by MENU for the
     TEXT -> CONTROLLER transition. It publishes suppression,
     yields EVIOCGRAB and restores native OpenMW controller input.

  2. tap_key(KEY_ESC)

     This closes/cancels the text dialog.

The controller transition happens BEFORE Escape/window teardown.

Removed
-------

TSP_TEXT_EXIT_LATCH_051_V56
  The failed B-specific latch is removed from both OpenMW and helper source.

Preserved
---------

TSP_TEXT_EXIT_CONTROLLER_051_V55
TSP_NO_STICKCLICK_MODES_051_V54
MENU TEXT <-> CONTROLLER cycling
left-stick mouse path
TSP S L3/R3 behavior
MENU-held quick-key/chord layer
custom cursor
EOFBEHAVIOR

(
    cd "$PKG"

    sha256sum \
        openmw-0.51 \
        tsp_openmw_controls \
        > SHA256SUMS.txt
)

echo "Package:"
find "$PKG" \
    -maxdepth 6 \
    -type f \
    -printf '  %P\n'

echo
echo "===== 9/11 CONNECT + BACK UP CURRENT TSP S FILES ====="

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
    echo "ERROR: OpenMW is still running."
    echo
    echo "V57 is already patched, built, verified and packaged at:"
    echo "  $PKG"
    echo
    echo "Exit Morrowind normally and rerun THIS V57 script."
    echo "It will stop at the already-applied source guard, so use the"
    echo "package/deploy resume described in the output package instead."
    exit 4
fi

echo "PASS: OpenMW is closed."

# Stop stale helper safely by process name only.
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
echo
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
echo "Device rollback:"
echo "  $REMOTE_BACKUP"

echo
echo "===== 10/11 INSTALL V57 OPENMW + HELPER ====="

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
echo "===== 11/11 REMOTE HASH VERIFICATION + TRACE COLLECTOR ====="

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
echo "  local : $LOCAL_OPENMW_SHA"
echo "  remote: $REMOTE_OPENMW_SHA"

echo
echo "Helper:"
echo "  local : $LOCAL_HELPER_SHA"
echo "  remote: $REMOTE_HELPER_SHA"

[ "$LOCAL_OPENMW_SHA" = "$REMOTE_OPENMW_SHA" ] || {
    echo "ERROR: remote OpenMW SHA mismatch."
    exit 1
}

[ "$LOCAL_HELPER_SHA" = "$REMOTE_HELPER_SHA" ] || {
    echo "ERROR: remote helper SHA mismatch."
    exit 1
}

ssh "$DEV" "
set -e

grep -a -q \
    'TSP_B_EXIT_MENU_HANDOFF_051_V57' \
    '$REMOTE_BIN'

grep -a -q \
    'TSP_B_EXIT_MENU_HANDOFF_051_V57 active' \
    '$REMOTE_HELPER'

if grep -a -q \
    'TSP_TEXT_EXIT_LATCH_051_V56 active' \
    '$REMOTE_HELPER'
then
    echo 'ERROR: old V56 helper latch is still installed.'
    exit 1
fi

echo 'PASS: V57 installed markers verified.'
"

cat > "$PKG/collect-v57-controller-trace.sh" <<'EOFTRACE'
#!/usr/bin/env bash
set -euo pipefail

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
          "TSP_B_EXIT_MENU_HANDOFF_051_V57|TSP_TEXT_EXIT_CONTROLLER_051_V55|TSP_NO_STICKCLICK_MODES_051_V54|TSP_TEXT_HANDOFF_051_V51|TSP_MOUSE_MODE_051_V38" \
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
echo "Trace saved:"
echo "  $OUT"
EOFTRACE

chmod +x \
    "$PKG/collect-v57-controller-trace.sh"

cat > "$PKG/INSTALL_REPORT.txt" <<EOFREPORT
OpenMW 0.51 TSP B-Exit + Menu-Handoff V57

Created:
$(date)

Device:
$DEV

Source backup made BEFORE V57:
$SOURCE_BACKUP

Device backup made BEFORE V57:
$REMOTE_BACKUP

Previous device OpenMW:
$DEV_OPENMW_SHA

Previous device helper:
$DEV_HELPER_SHA

Installed OpenMW:
$REMOTE_OPENMW_SHA

Installed helper:
$REMOTE_HELPER_SHA

Behavior:
B while TEXT owns the controller now performs the exact existing MENU
TEXT->CONTROLLER handoff first, then injects Escape to close the text dialog.

V56 B-specific exit latch:
REMOVED

V55 controller/text suppression:
PRESERVED

V54 no-stick-click/mouse behavior:
PRESERVED
EOFREPORT

echo
echo "=================================================================="
echo "V57 SUCCESS"
echo "=================================================================="
echo
echo "Package:"
echo "  $PKG"
echo
echo "Source rollback:"
echo "  $SOURCE_BACKUP"
echo
echo "Device rollback:"
echo "  $REMOTE_BACKUP"
echo
echo "Installed OpenMW:"
echo "  $REMOTE_OPENMW_SHA"
echo
echo "Installed helper:"
echo "  $REMOTE_HELPER_SHA"
echo
echo "Test this exact sequence:"
echo
echo "  barter"
echo "  -> stacked item text dialog"
echo "  -> MENU to controller"
echo "  -> MENU back to text"
echo "  -> type or do not type"
echo "  -> B"
echo "  -> immediately use D-pad in barter"
echo
echo "Expected:"
echo "  B performed MENU's normal controller handoff BEFORE Escape,"
echo "  so the barter menu is already on normal controller bindings."
echo
echo "If not, WHILE OPENMW IS STILL RUNNING:"
echo "  $PKG/collect-v57-controller-trace.sh"
echo "=================================================================="
