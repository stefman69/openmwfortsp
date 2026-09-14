#!/usr/bin/env bash
set -Eeuo pipefail
set -o pipefail

C="${TSP_DOCKER:-openmw_builder}"
DEV="${TSP_DEV:-root@192.168.1.25}"

SRC="/root/openmw-0.51-tsp-src"
BUILD="/root/openmw-0.51-tsp-build"

CM="$SRC/apps/openmw/mwinput/controllermanager.cpp"
IM="$SRC/apps/openmw/mwinput/inputmanagerimp.cpp"
HELPER_SRC="/root/tsp_openmw_controls.c"

OPENMW_BIN="$BUILD/openmw"
HELPER_BIN="/root/tsp_openmw_controls-v58"

STAMP="$(date +%Y%m%d-%H%M%S)"
PKG="$HOME/Downloads/openmw51-explicit-ui-state-v58-$STAMP"

REMOTE_ROOT="/mnt/SDCARD/data/ports/openmw51"
REMOTE_BIN="$REMOTE_ROOT/bin/openmw-0.51"
REMOTE_HELPER="$REMOTE_ROOT/tsp_openmw_controls"
REMOTE_BACKUP="$REMOTE_ROOT/backups/explicit-ui-state-v58-$STAMP"

STATE_LOG="$PKG/logs/v58-state.log"
PATCH_LOG="$PKG/logs/v58-patch.log"
HELPER_BUILD_LOG="$PKG/logs/v58-helper-build.log"
OPENMW_BUILD_LOG="$PKG/logs/v58-openmw-build.log"

mkdir -p \
    "$PKG/logs" \
    "$PKG/patched-source/apps/openmw/mwinput" \
    "$PKG/patched-source/helper" \
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
        echo "V58 STOPPED SAFELY"
        echo "=================================================================="
        echo "Date: $(date)"
        echo "Exit code: $rc"
        echo "Script line: $line"
        echo "Failing command:"
        echo "  $cmd"
        echo

        for f in \
            "$STATE_LOG" \
            "$PATCH_LOG" \
            "$HELPER_BUILD_LOG" \
            "$OPENMW_BUILD_LOG"
        do
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
echo "OPENMW 0.51 TSP EXPLICIT TEXT / CONTROLLER / MOUSE STATE V58"
echo "=================================================================="
echo
echo "Target state machine in a live text-entry dialog:"
echo
echo "  MOUSE + MENU        -> TEXT"
echo "  TEXT + MENU         -> CONTROLLER"
echo "  CONTROLLER + MENU   -> TEXT"
echo
echo "  TEXT + left stick   -> MOUSE"
echo "  CONTROLLER + stick  -> MOUSE"
echo
echo "  TEXT + B            -> FORCE CONTROLLER + Escape"
echo "                         and stay CONTROLLER until SDL text focus ends"
echo
echo "Important:"
echo "  - no V56 timer/latch"
echo "  - no V57 MENU-yield trick for B"
echo "  - InputManager owns text availability"
echo "  - helper owns TEXT vs CONTROLLER"
echo "  - OpenMW owns MOUSE"
echo "  - MOUSE -> TEXT requires stick neutral before mouse can wake again"
echo
echo "This script is RERUN-SAFE."
echo "If V58 source already exists after an interrupted run, it verifies it,"
echo "skips patching, resumes build, packages, and deploys."
echo

echo "===== 1/12 IDENTIFY EXACT SOURCE STATE ====="

set +e
docker exec -i "$C" python3 <<'PYSTATE' 2>&1 | tee "$STATE_LOG"
from pathlib import Path
import hashlib

cm = Path("/root/openmw-0.51-tsp-src/apps/openmw/mwinput/controllermanager.cpp")
im = Path("/root/openmw-0.51-tsp-src/apps/openmw/mwinput/inputmanagerimp.cpp")
hp = Path("/root/tsp_openmw_controls.c")

paths = (cm, im, hp)

for p in paths:
    if not p.is_file():
        raise SystemExit("ERROR: required source missing: %s" % p)

def sha256(path):
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()

hashes = [sha256(p) for p in paths]
texts = [p.read_text() for p in paths]

print("Current source SHA256:")
for p, digest in zip(paths, hashes):
    print(" ", digest, p)

expected_v57 = [
    "91eb121b6102624ea09b3d4882b63cf9e3c051be55894f09caf251e9366b336d",
    "0e0e2079e881e5d2fea1779992633eef24ba79735f891cd92ae2e40149914572",
    "a1b4acb22d028c3e23fa6cf0c336bd362048f64a171c9a47ce926f21fa5ae3b7",
]

marker = "TSP_EXPLICIT_UI_STATE_051_V58"
v58 = [marker in t for t in texts]

if all(v58):
    c, i, h = texts

    required = [
        (c, "window-change=preserve-text-owner", "engine window ownership"),
        (i, "/tmp/openmw-tsp-force-controller", "InputManager force-controller"),
        (i, "!tspForceController", "InputManager helper gate"),
        (h, "#define FORCE_CONTROLLER_FLAG", "helper force-controller"),
        (h, "menu_to_text_pending", "helper MENU pending state"),
        (h, "menu_release_seen", "helper MENU release state"),
        (h, "left_stick_mouse_armed", "helper neutral mouse guard"),
        (h, "B: FORCE CONTROLLER -> Escape", "helper B force path"),
        (h, "MOUSE -> TEXT pending", "helper mouse-to-text path"),
    ]

    for text, needle, label in required:
        if needle not in text:
            raise SystemExit(
                "ERROR: partial/corrupt V58 source: missing %s (%s)"
                % (needle, label)
            )

    print()
    print("PASS: complete V58 source already present.")
    print("STATE=V58_ALREADY_PATCHED")

elif any(v58):
    raise SystemExit(
        "ERROR: PARTIAL V58 SOURCE DETECTED.\n"
        "One or two files contain V58 but not all three.\n"
        "No automatic patch/build will run on a mixed source state."
    )

elif hashes == expected_v57:
    print()
    print("PASS: exact captured V57 source hashes match.")
    print("STATE=V57_PATCH_NEEDED")

else:
    print()
    print("ERROR: source is neither exact captured V57 nor complete V58.")
    print("Expected V57:")
    for digest, p in zip(expected_v57, paths):
        print(" ", digest, p)
    raise SystemExit(
        "Refusing to guess against unexpected source. No source modified."
    )
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

if [ -z "$SOURCE_STATE" ]; then
    echo "ERROR: state detector did not produce STATE=..."
    exit 1
fi

echo
echo "Detected:"
echo "  $SOURCE_STATE"

SOURCE_BACKUP=""

if [ "$SOURCE_STATE" = "V57_PATCH_NEEDED" ]; then

    echo
    echo "===== 2/12 BACK UP ALL THREE TOUCHED SOURCES BEFORE PATCH ====="

    SOURCE_BACKUP="$SRC/.tsp-051-source-backups/explicit-ui-state-v58-$STAMP"

    docker exec -i "$C" python3 - "$SOURCE_BACKUP" <<'PYBACKUP' | tee -a "$PATCH_LOG"
from pathlib import Path
import hashlib
import shutil
import sys

backup = Path(sys.argv[1])

pairs = [
    (
        Path("/root/openmw-0.51-tsp-src/apps/openmw/mwinput/controllermanager.cpp"),
        backup / "apps/openmw/mwinput/controllermanager.cpp",
    ),
    (
        Path("/root/openmw-0.51-tsp-src/apps/openmw/mwinput/inputmanagerimp.cpp"),
        backup / "apps/openmw/mwinput/inputmanagerimp.cpp",
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
    a = sha256(src)
    b = sha256(dst)

    if a != b:
        raise SystemExit(
            "ERROR: backup SHA mismatch for %s. PATCH ABORTED." % src
        )

    print("BACKUP PASS:")
    print(" ", src)
    print(" ", a)

Path("/root/openmw51-v58-source-backup-path.txt").write_text(
    str(backup) + "\n"
)

print()
print("VERIFIED SOURCE BACKUP:")
print(backup)
PYBACKUP

    docker exec "$C" test -d "$SOURCE_BACKUP"

    echo
    echo "===== 3/12 APPLY V58 AGAINST EXACT VERIFIED V57 ====="

    docker exec -i "$C" python3 <<'PYPATCH' | tee -a "$PATCH_LOG"
from pathlib import Path

CM = Path("/root/openmw-0.51-tsp-src/apps/openmw/mwinput/controllermanager.cpp")
IM = Path("/root/openmw-0.51-tsp-src/apps/openmw/mwinput/inputmanagerimp.cpp")
HP = Path("/root/tsp_openmw_controls.c")

c = CM.read_text()
i = IM.read_text()
h = HP.read_text()

MARK = "TSP_EXPLICIT_UI_STATE_051_V58"

def once(text, old, new, label):
    count = text.count(old)

    if count != 1:
        raise SystemExit(
            "ERROR: %s anchor matched %d times; expected exactly 1.\n"
            "NO V58 FILES HAVE BEEN WRITTEN."
            % (label, count)
        )

    return text.replace(old, new, 1)

# ------------------------------------------------------------------
# ControllerManager
# Stop window changes from rewriting text ownership. InputManager/helper
# are now the only owners of availability/selection.
# ------------------------------------------------------------------
c = once(
    c,
'''                // TSP_INPUT_MODE_051_V49 -- every menu opens in CONTROLLER with the
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
                std::remove(sTspMouseRequestFlag);''',
'''                // TSP_EXPLICIT_UI_STATE_051_V58
                // InputManager owns text availability and the helper owns the
                // TEXT/CONTROLLER selection. Do not rewrite either merely because
                // the active controller window changed; that race could undo B's
                // controller handoff before the child EditBox dropped SDL focus.
                //
                // Mouse requests are per-window and may still be discarded here.
                std::remove(sTspHelperYieldFlag);
                std::remove(sTspMouseRequestFlag);
                Log(Debug::Info)
                    << "TSP_EXPLICIT_UI_STATE_051_V58 window-change=preserve-text-owner";''',
    "ControllerManager window-change owner reset",
)

# ------------------------------------------------------------------
# InputManager
# B's force-controller file is authoritative until actual SDL text focus ends.
# ------------------------------------------------------------------
i = once(
    i,
'''        const bool tspTextEntryActive = SDL_IsTextInputActive() == SDL_TRUE;

        // TSP_MOUSE_MODE_051_V41''',
'''        const bool tspTextEntryActive = SDL_IsTextInputActive() == SDL_TRUE;

        // TSP_EXPLICIT_UI_STATE_051_V58
        // B from helper TEXT writes this file before Escape. Keep it asserted
        // until SDL itself reports that the text field genuinely ended. While
        // asserted, the helper-availability flag must not be recreated.
        bool tspForceController = false;
        if (std::FILE* tspForceFile
            = std::fopen("/tmp/openmw-tsp-force-controller", "r"))
        {
            tspForceController = true;
            std::fclose(tspForceFile);
        }

        if (tspForceController && !tspTextEntryActive)
        {
            std::remove("/tmp/openmw-tsp-force-controller");
            tspForceController = false;
            std::fprintf(stderr,
                "TSP_EXPLICIT_UI_STATE_051_V58 force-controller=cleared-text-ended\\n");
            std::fflush(stderr);
        }

        static bool tspForceControllerWasActive = false;
        if (tspForceController && !tspForceControllerWasActive)
        {
            std::remove("/tmp/openmw-tsp-mouse-request");
            std::remove("/tmp/openmw-tsp-mouse-mode");
            mControllerManager->tspSetMouseMode(false);
            std::fprintf(stderr,
                "TSP_EXPLICIT_UI_STATE_051_V58 force-controller=active\\n");
            std::fflush(stderr);
        }
        tspForceControllerWasActive = tspForceController;

        // TSP_MOUSE_MODE_051_V41''',
    "InputManager force-controller ownership",
)

i = once(
    i,
'''                if (tspTextEntryActive && windowManager->isGuiMode())
                {
                    mControllerManager->tspSetMouseMode(true);
                    std::fprintf(stderr,
                        "TSP_NO_STICKCLICK_MODES_051_V54 helper-left-stick=text-to-mouse\\n");
                }
                else
                {
                    std::fprintf(stderr,
                        "TSP_NO_STICKCLICK_MODES_051_V54 helper-left-stick=ignored-no-text-gui\\n");
                }''',
'''                if (!tspForceController && tspTextEntryActive && windowManager->isGuiMode())
                {
                    mControllerManager->tspSetMouseMode(true);
                    std::fprintf(stderr,
                        "TSP_EXPLICIT_UI_STATE_051_V58 helper-left-stick=text-to-mouse\\n");
                }
                else
                {
                    std::fprintf(stderr,
                        "TSP_EXPLICIT_UI_STATE_051_V58 helper-left-stick=ignored force=%d text=%d gui=%d\\n",
                        tspForceController ? 1 : 0,
                        tspTextEntryActive ? 1 : 0,
                        windowManager->isGuiMode() ? 1 : 0);
                }''',
    "InputManager helper mouse request gate",
)

i = once(
    i,
'''            const bool tspWantHelper = tspTextEntryActive && tspTextResetFrames == 0;''',
'''            const bool tspWantHelper
                = tspTextEntryActive && !tspForceController && tspTextResetFrames == 0;''',
    "InputManager text availability gate",
)

# ------------------------------------------------------------------
# Helper IPC + local transition state.
# ------------------------------------------------------------------
h = once(
    h,
'''#define MOUSE_REQUEST_FLAG "/tmp/openmw-tsp-mouse-request"
#define MOUSE_ACTIVE_FLAG  "/tmp/openmw-tsp-mouse-active"''',
'''#define MOUSE_REQUEST_FLAG "/tmp/openmw-tsp-mouse-request"
#define MOUSE_ACTIVE_FLAG  "/tmp/openmw-tsp-mouse-active"

/* TSP_EXPLICIT_UI_STATE_051_V58
 * B owns this request until InputManager observes SDL text input really end.
 */
#define FORCE_CONTROLLER_FLAG "/tmp/openmw-tsp-force-controller"''',
    "helper force-controller flag",
)

h = once(
    h,
'''static bool grabbed = false;
static bool suppress_auto_text = false;

static int dpad_x = 0;''',
'''static bool grabbed = false;
static bool suppress_auto_text = false;

/* TSP_EXPLICIT_UI_STATE_051_V58
 * GAME-mode MENU transitions wait for the physical release so SDL/OpenMW sees
 * a complete MENU press/release pair before TEXT reclaims EVIOCGRAB.
 */
static bool menu_to_text_pending = false;
static bool menu_release_seen = false;

/* Require a neutral stick after entering TEXT by MENU, otherwise the same
 * still-held deflection that was moving the pointer immediately wakes MOUSE.
 */
static bool left_stick_mouse_armed = true;

static int dpad_x = 0;''',
    "helper explicit transition globals",
)

h = once(
    h,
'''static bool openmw_text_active(void)
{
    return access(TEXT_ACTIVE_FLAG, F_OK) == 0;
}

/* TSP_TEXT_EXIT_CONTROLLER_051_V55''',
'''static bool openmw_text_active(void)
{
    return access(TEXT_ACTIVE_FLAG, F_OK) == 0;
}

/* TSP_EXPLICIT_UI_STATE_051_V58 */
static bool openmw_mouse_active(void);

/* TSP_TEXT_EXIT_CONTROLLER_051_V55''',
    "helper mouse-state forward declaration",
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
    const bool force_controller = access(FORCE_CONTROLLER_FLAG, F_OK) == 0;
    const bool mouse_active = openmw_mouse_active();

    // TSP_EXPLICIT_UI_STATE_051_V58
    // B's force-controller request is stronger than every other text-menu state.
    // InputManager removes it only after SDL text input genuinely ends.
    if (force_controller) {
        menu_to_text_pending = false;
        menu_release_seen = false;
        set_text_suppressed(true);
        if (mode != MODE_GAME)
            set_mode(MODE_GAME);
        return;
    }

    if (!active) {
        // No live text field: ordinary controller passthrough. Clear local mode
        // selection so the next real text field starts in TEXT normally.
        menu_to_text_pending = false;
        menu_release_seen = false;
        left_stick_mouse_armed = true;
        unlink(MOUSE_MODE_FLAG);
        set_text_suppressed(false);
        if (mode != MODE_GAME)
            set_mode(MODE_GAME);
        return;
    }

    // A single MENU from either MOUSE or CONTROLLER means -> TEXT.
    // Wait for release, and for engine mouse-off acknowledgement, before grab.
    if (menu_to_text_pending) {
        set_text_suppressed(true);
        if (mode != MODE_GAME)
            set_mode(MODE_GAME);

        if (menu_release_seen && !mouse_active) {
            menu_to_text_pending = false;
            menu_release_seen = false;
            left_stick_mouse_armed
                = abs(left_x - left_x_center) <= left_x_threshold / 2
                && abs(left_y - left_y_center) <= left_y_threshold / 2;
            set_text_suppressed(false);
            set_mode(MODE_TEXT);
            log_line("TSP_EXPLICIT_UI_STATE_051_V58 MENU: -> TEXT complete.");
        }
        return;
    }

    // Engine-owned mouse mode wins while active.
    if (mouse_active) {
        set_text_suppressed(true);
        if (mode != MODE_GAME)
            set_mode(MODE_GAME);
        return;
    }

    // No force and no mouse: TEXT_OFF_FLAG selects TEXT vs CONTROLLER.
    if (!suppress_auto_text) {
        if (mode != MODE_TEXT)
            set_mode(MODE_TEXT);
    } else if (mode != MODE_GAME) {
        set_mode(MODE_GAME);
    }
}''',
    "helper automatic explicit state reconcile",
)

h = once(
    h,
'''static void tsp_request_mouse_mode(void)
{
    log_line("TSP_NO_STICKCLICK_MODES_051_V54 LEFT STICK: TEXT -> MOUSE.");
    // TSP_TEXT_EXIT_CONTROLLER_051_V55
    set_text_suppressed(true);

    FILE *request = fopen(MOUSE_REQUEST_FLAG, "w");
    if (request != NULL) {
        fputs("1\\n", request);
        fclose(request);
    } else if (log_file != NULL) {
        fprintf(log_file, "LEFT STICK: could not write %s: %s\\n",
                MOUSE_REQUEST_FLAG, strerror(errno));
        fflush(log_file);
    }

    FILE *yield = fopen(MOUSE_MODE_FLAG, "w");
    if (yield != NULL) {
        fputs("1\\n", yield);
        fclose(yield);
    }

    set_mode(MODE_GAME);
}''',
'''static void tsp_request_mouse_mode(void)
{
    log_line("TSP_EXPLICIT_UI_STATE_051_V58 LEFT STICK: TEXT -> MOUSE request.");

    menu_to_text_pending = false;
    menu_release_seen = false;
    left_stick_mouse_armed = false;
    set_text_suppressed(true);

    FILE *request = fopen(MOUSE_REQUEST_FLAG, "w");
    if (request != NULL) {
        fputs("1\\n", request);
        fclose(request);
    } else if (log_file != NULL) {
        fprintf(log_file, "LEFT STICK: could not write %s: %s\\n",
                MOUSE_REQUEST_FLAG, strerror(errno));
        fflush(log_file);
    }

    unlink(MOUSE_MODE_FLAG);
    set_mode(MODE_GAME);
}''',
    "helper TEXT-to-MOUSE request",
)

# Replace whole helper TEXT -> CONTROLLER routine.
start = h.find("static void tsp_enter_pointing_mode(void)")
end = h.find("/* TSP_TEXT_REMAP_051_V40 -- MENU again", start)
if start < 0 or end < 0:
    raise SystemExit("ERROR: could not isolate tsp_enter_pointing_mode")
old = h[start:end]
new = '''static void tsp_enter_pointing_mode(void)
{
    // TSP_EXPLICIT_UI_STATE_051_V58
    // TEXT + MENU -> CONTROLLER. MOUSE_MODE_FLAG is no longer used as a
    // pseudo-state; TEXT_OFF_FLAG plus EVIOCGRAB release are sufficient.
    log_line("TSP_EXPLICIT_UI_STATE_051_V58 MENU: TEXT -> CONTROLLER.");

    menu_to_text_pending = false;
    menu_release_seen = false;
    set_text_suppressed(true);
    unlink(MOUSE_MODE_FLAG);
    set_mode(MODE_GAME);
}

'''
h = once(h, old, new, "helper TEXT-to-CONTROLLER routine")

# Keep the utility but make it explicit-state aware.
start = h.find("static void tsp_leave_pointing_mode(void)")
end = h.find("static void leave_text_mode(void)", start)
if start < 0 or end < 0:
    raise SystemExit("ERROR: could not isolate tsp_leave_pointing_mode")
old = h[start:end]
new = '''static void tsp_leave_pointing_mode(void)
{
    // TSP_EXPLICIT_UI_STATE_051_V58
    log_line("TSP_EXPLICIT_UI_STATE_051_V58 MENU: reclaim TEXT.");
    menu_to_text_pending = false;
    menu_release_seen = false;
    left_stick_mouse_armed
        = abs(left_x - left_x_center) <= left_x_threshold / 2
        && abs(left_y - left_y_center) <= left_y_threshold / 2;
    unlink(MOUSE_MODE_FLAG);
    set_text_suppressed(false);
    sync_automatic_mode();
}

'''
h = once(h, old, new, "helper reclaim TEXT routine")

# B: explicit force-controller request, not MENU/yield imitation.
start = h.find("static void leave_text_mode(void)")
end = h.find("static void handle_key_event", start)
if start < 0 or end < 0:
    raise SystemExit("ERROR: could not isolate leave_text_mode")
old = h[start:end]
new = '''static void leave_text_mode(void)
{
    // TSP_EXPLICIT_UI_STATE_051_V58
    // B is an explicit cross-process FORCE CONTROLLER request plus Escape.
    // InputManager keeps the request asserted until SDL text focus really ends,
    // so no child->parent window race can invite the helper back into TEXT.
    log_line("TSP_EXPLICIT_UI_STATE_051_V58 B: FORCE CONTROLLER -> Escape.");

    menu_to_text_pending = false;
    menu_release_seen = false;
    set_text_suppressed(true);
    unlink(MOUSE_MODE_FLAG);
    unlink(MOUSE_REQUEST_FLAG);

    FILE *force = fopen(FORCE_CONTROLLER_FLAG, "w");
    if (force != NULL) {
        fputs("1\\n", force);
        fclose(force);
    } else if (log_file != NULL) {
        fprintf(log_file, "B: could not write %s: %s\\n",
                FORCE_CONTROLLER_FLAG, strerror(errno));
        fflush(log_file);
    }

    set_mode(MODE_GAME);
    tap_key(KEY_ESC);
}

'''
h = once(h, old, new, "helper B force-controller exit")

h = once(
    h,
'''    if (mode != MODE_TEXT) {
        /*
         * Native OpenMW receives the physical controller because EVIOCGRAB is
         * off. The helper intentionally does not remap anything in GAME mode.
         */
        /* TSP_TEXT_REMAP_051_V40 -- only meaningful while text entry is still
         * open and we yielded the pad; otherwise MENU belongs to OpenMW. */
        if (event->code == KEY_TSP_MENU && pressed && suppress_auto_text
            && openmw_text_active()) {
            /* TSP_NO_STICKCLICK_MODES_051_V54
             * If OpenMW says the pointer is currently active, this first MENU
             * belongs to the engine: MOUSE -> CONTROLLER. Stay yielded. The next
             * MENU, with the active flag gone, reclaims TEXT through V51.
             */
            if (openmw_mouse_active()) {
                log_line("TSP_NO_STICKCLICK_MODES_051_V54 MENU: MOUSE -> CONTROLLER owned by engine.");
            } else {
                tsp_leave_pointing_mode();
            }
        }
        return;
    }''',
'''    if (mode != MODE_TEXT) {
        /*
         * TSP_EXPLICIT_UI_STATE_051_V58
         * Native OpenMW receives the physical controller because EVIOCGRAB is
         * off. For a live text field, one bare MENU from either CONTROLLER or
         * MOUSE means -> TEXT. Do not grab on press: let SDL/OpenMW receive the
         * complete MENU release first. In MOUSE, that release turns mouse mode
         * off; sync_automatic_mode then reclaims TEXT.
         */
        if (event->code == KEY_TSP_MENU && openmw_text_active()
            && access(FORCE_CONTROLLER_FLAG, F_OK) != 0) {
            if (pressed) {
                menu_to_text_pending = true;
                menu_release_seen = false;
                set_text_suppressed(true);

                if (openmw_mouse_active())
                    log_line("TSP_EXPLICIT_UI_STATE_051_V58 MENU: MOUSE -> TEXT pending.");
                else
                    log_line("TSP_EXPLICIT_UI_STATE_051_V58 MENU: CONTROLLER -> TEXT pending.");
            } else if (menu_to_text_pending) {
                menu_release_seen = true;
                log_line("TSP_EXPLICIT_UI_STATE_051_V58 MENU: release seen.");
            }
        }
        return;
    }''',
    "helper GAME-mode MENU state transition",
)

h = once(
    h,
'''        if (mode == MODE_TEXT) {
            const int dx = abs(left_x - left_x_center);
            const int dy = abs(left_y - left_y_center);

            if (dx >= left_x_threshold || dy >= left_y_threshold)
                tsp_request_mouse_mode();
        }
        return;''',
'''        if (mode == MODE_TEXT) {
            const int dx = abs(left_x - left_x_center);
            const int dy = abs(left_y - left_y_center);
            const int neutral_x = left_x_threshold / 2;
            const int neutral_y = left_y_threshold / 2;

            // TSP_EXPLICIT_UI_STATE_051_V58
            // After MENU returns from MOUSE/CONTROLLER to TEXT, a previously
            // held deflection must return near center before another movement
            // may wake MOUSE. This removes immediate TEXT<->MOUSE bouncing.
            if (!left_stick_mouse_armed) {
                if (dx <= neutral_x && dy <= neutral_y) {
                    left_stick_mouse_armed = true;
                    log_line("TSP_EXPLICIT_UI_STATE_051_V58 left-stick=neutral-armed.");
                }
                return;
            }

            if (dx >= left_x_threshold || dy >= left_y_threshold)
                tsp_request_mouse_mode();
        }
        return;''',
    "helper mouse neutral re-arm",
)

h = once(
    h,
'''    /* TSP_TEXT_EXIT_CONTROLLER_051_V55 */
    unlink(TEXT_OFF_FLAG);

    controller_fd = find_controller();''',
'''    /* TSP_TEXT_EXIT_CONTROLLER_051_V55 */
    unlink(TEXT_OFF_FLAG);
    /* TSP_EXPLICIT_UI_STATE_051_V58 */
    unlink(FORCE_CONTROLLER_FLAG);

    controller_fd = find_controller();''',
    "helper startup force cleanup",
)

h = once(
    h,
'''    log_line("TSP_B_EXIT_MENU_HANDOFF_051_V57 active.");
    log_line("Corrected physical codes: Start=315 Select=314 Menu=316.");''',
'''    log_line("TSP_B_EXIT_MENU_HANDOFF_051_V57 active.");
    log_line("TSP_EXPLICIT_UI_STATE_051_V58 active.");
    log_line("Menu cycle in text UI: MOUSE -> TEXT -> CONTROLLER -> TEXT.");
    log_line("B from TEXT: force CONTROLLER until SDL text focus ends.");
    log_line("Corrected physical codes: Start=315 Select=314 Menu=316.");''',
    "helper V58 runtime marker",
)

h = once(
    h,
'''    /* TSP_TEXT_EXIT_CONTROLLER_051_V55 */
    unlink(TEXT_OFF_FLAG);

    if (uinput_fd >= 0) {''',
'''    /* TSP_TEXT_EXIT_CONTROLLER_051_V55 */
    unlink(TEXT_OFF_FLAG);
    /* TSP_EXPLICIT_UI_STATE_051_V58 */
    unlink(FORCE_CONTROLLER_FLAG);

    if (uinput_fd >= 0) {''',
    "helper shutdown force cleanup",
)

# ------------------------------------------------------------------
# Verify complete transform BEFORE writing any source.
# ------------------------------------------------------------------
required = [
    (c, "TSP_EXPLICIT_UI_STATE_051_V58", "ControllerManager marker"),
    (c, "window-change=preserve-text-owner", "window owner rule"),
    (i, "TSP_EXPLICIT_UI_STATE_051_V58", "InputManager marker"),
    (i, "tspForceController", "InputManager force state"),
    (i, "!tspForceController", "InputManager helper gate"),
    (h, "#define FORCE_CONTROLLER_FLAG", "helper force flag"),
    (h, "menu_to_text_pending", "MENU pending"),
    (h, "menu_release_seen", "MENU release"),
    (h, "left_stick_mouse_armed", "neutral mouse guard"),
    (h, "B: FORCE CONTROLLER -> Escape", "B force path"),
    (h, "MOUSE -> TEXT pending", "mouse MENU path"),
    (h, "CONTROLLER -> TEXT pending", "controller MENU path"),
]

for text, needle, label in required:
    if needle not in text:
        raise SystemExit("ERROR: transformed source missing %s: %s" % (label, needle))

preserve = [
    (c, "TSP_CHORD_051_V43", "MENU chord watchdog"),
    (c, "TSP_NO_STICKCLICK_MODES_051_V54", "V54 engine"),
    (c, "tspSetMouseMode(!mTspMouseMode);", "L3 mouse toggle"),
    (c, "r3=force-text-reset", "R3 text reset"),
    (i, "TSP_TEXT_INDICATOR_051_V52", "text indicator"),
    (h, "TSP_NO_STICKCLICK_MODES_051_V54", "V54 helper"),
    (h, "EVIOCGRAB", "helper grab"),
    (h, "TSP_TEXT_CANCEL_KEY", "B text cancel mapping"),
]

for text, needle, label in preserve:
    if needle not in text:
        raise SystemExit("ERROR: preserved behavior lost: %s" % label)

if "TSP_TEXT_EXIT_LATCH_051_V56" in c or "tspTextExitLatched" in c:
    raise SystemExit("ERROR: V56 engine latch unexpectedly present")

if "TEXT_EXIT_LATCH_FLAG" in h:
    raise SystemExit("ERROR: V56 helper latch unexpectedly present")

for label, text in (
    ("controllermanager.cpp", c),
    ("inputmanagerimp.cpp", i),
    ("tsp_openmw_controls.c", h),
):
    if text.count("{") != text.count("}"):
        raise SystemExit("ERROR: brace imbalance in %s" % label)

    if text.count("(") != text.count(")"):
        raise SystemExit("ERROR: parenthesis imbalance in %s" % label)

# Write candidates first, then replace originals.
candidate_cm = Path("/tmp/v58-controllermanager.cpp")
candidate_im = Path("/tmp/v58-inputmanagerimp.cpp")
candidate_hp = Path("/tmp/v58-tsp_openmw_controls.c")

candidate_cm.write_text(c)
candidate_im.write_text(i)
candidate_hp.write_text(h)

candidate_cm.replace(CM)
candidate_im.replace(IM)
candidate_hp.replace(HP)

print("PATCH PASS:", CM)
print("PATCH PASS:", IM)
print("PATCH PASS:", HP)
print()
print("V58 ownership:")
print("  InputManager = text availability + B force lifetime")
print("  helper       = TEXT/CONTROLLER selection + MENU pending state")
print("  OpenMW       = MOUSE")
print()
print("V58 transitions:")
print("  MOUSE + MENU       -> TEXT")
print("  TEXT + MENU        -> CONTROLLER")
print("  CONTROLLER + MENU  -> TEXT")
print("  TEXT + stick       -> MOUSE")
print("  CONTROLLER + stick -> MOUSE")
print("  TEXT + B           -> FORCE CONTROLLER + Escape")
PYPATCH

    echo
    echo "===== 4/12 VERIFY PATCHED SOURCE + PREPATCH BACKUP HASHES ====="

    docker exec -i "$C" python3 - "$SOURCE_BACKUP" <<'PYVERIFY' | tee -a "$PATCH_LOG"
from pathlib import Path
import hashlib
import sys

backup = Path(sys.argv[1])

current = [
    Path("/root/openmw-0.51-tsp-src/apps/openmw/mwinput/controllermanager.cpp"),
    Path("/root/openmw-0.51-tsp-src/apps/openmw/mwinput/inputmanagerimp.cpp"),
    Path("/root/tsp_openmw_controls.c"),
]

saved = [
    backup / "apps/openmw/mwinput/controllermanager.cpp",
    backup / "apps/openmw/mwinput/inputmanagerimp.cpp",
    backup / "root/tsp_openmw_controls.c",
]

def sha256(path):
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()

for old, new in zip(saved, current):
    if not old.is_file() or not new.is_file():
        raise SystemExit("ERROR: backup/current verification file missing")

    old_hash = sha256(old)
    new_hash = sha256(new)

    if old_hash == new_hash:
        raise SystemExit("ERROR: expected patched source did not change: %s" % new)

    print("PASS:", new)
    print("  backup :", old_hash)
    print("  current:", new_hash)

texts = [p.read_text() for p in current]

if not all("TSP_EXPLICIT_UI_STATE_051_V58" in t for t in texts):
    raise SystemExit("ERROR: V58 marker missing from one or more current sources")

print()
print("PASS: all three current sources are V58.")
PYVERIFY

else

    echo
    echo "===== 2-4/12 PATCH SKIPPED: COMPLETE V58 SOURCE ALREADY PRESENT ====="

    SOURCE_BACKUP="$(
        docker exec "$C" bash -lc '
        cat /root/openmw51-v58-source-backup-path.txt 2>/dev/null || true
        '
    )"

    echo "Source backup from original V58 application:"
    echo "  ${SOURCE_BACKUP:-not recorded}"

fi

echo
echo "===== 5/12 BUILD/VERIFY V58 HELPER ====="

set +e
docker exec "$C" bash -lc '
set -euo pipefail

SRC=/root/tsp_openmw_controls.c
OUT=/root/tsp_openmw_controls-v58

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
    "TSP_EXPLICIT_UI_STATE_051_V58 active" \
    "$OUT" || {
        echo "ERROR: V58 helper runtime marker missing."
        exit 1
    }

grep -a -q \
    "B from TEXT: force CONTROLLER until SDL text focus ends." \
    "$OUT" || {
        echo "ERROR: V58 B behavior runtime string missing."
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
echo "===== 6/12 BUILD OR RESUME OPENMW ====="
echo
echo "Ninja will compile only changed/missing work."
echo "If a prior V58 run stopped during build, rerunning this script resumes it."
echo

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

# If timestamps somehow allowed an old V57 executable to survive, force only
# the two changed input objects plus final link and try once more.
if ! docker exec "$C" \
    grep -a -q \
    'TSP_EXPLICIT_UI_STATE_051_V58' \
    "$OPENMW_BIN"
then
    echo
    echo "V58 runtime marker not found after normal Ninja build."
    echo "Forcing only controllermanager/inputmanager objects + final link..."

    docker exec "$C" bash -lc '
    set -euo pipefail
    B=/root/openmw-0.51-tsp-build

    find "$B" -type f \
        \( -name "controllermanager.cpp.o" -o -name "inputmanagerimp.cpp.o" \) \
        -print -delete

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
    ' 2>&1 | tee -a "$OPENMW_BUILD_LOG"

    OPENMW_RC=${PIPESTATUS[0]}
    set -e

    if [ "$OPENMW_RC" -ne 0 ]; then
        exit "$OPENMW_RC"
    fi
fi

echo
echo "===== 7/12 VERIFY V58 OPENMW + PRESERVED CONTROLLER FEATURES ====="

docker exec "$C" bash -lc '
set -euo pipefail

B=/root/openmw-0.51-tsp-build/openmw
CM=/root/openmw-0.51-tsp-src/apps/openmw/mwinput/controllermanager.cpp
IM=/root/openmw-0.51-tsp-src/apps/openmw/mwinput/inputmanagerimp.cpp

test -x "$B"

echo "--- ELF ---"
readelf -h "$B" |
    grep -E "Class:|Machine:|Type:"

readelf -h "$B" |
    grep -q "AArch64"

echo
echo "--- V58 runtime ---"

grep -a -q \
    "TSP_EXPLICIT_UI_STATE_051_V58" \
    "$B"
echo "PASS: V58 runtime marker"

grep -a -q \
    "force-controller=active" \
    "$B"
echo "PASS: InputManager B force runtime"

grep -a -q \
    "window-change=preserve-text-owner" \
    "$B"
echo "PASS: ControllerManager owner-preservation runtime"

echo
echo "--- V58 functional source ---"

grep -F -q \
    "SDL_IsTextInputActive() && !tspTextSuppressed()" \
    "$CM"
echo "PASS: lingering SDL focus controller navigation"

grep -F -q \
    "tspTextEntryActive && !tspForceController" \
    "$IM"
echo "PASS: force-controller blocks text helper availability"

echo
echo "--- preserved behavior ---"

for marker in \
    TSP_NO_STICKCLICK_MODES_051_V54 \
    TSP_CHORD_051_V43
do
    grep -a -q "$marker" "$B"
    echo "PASS: $marker"
done

grep -a -q \
    "r3=force-text-reset" \
    "$B"
echo "PASS: R3 reset"

grep -a -q \
    "tx_cursor.dds" \
    "$B"
echo "PASS: custom cursor"

echo
echo "OpenMW SHA256:"
sha256sum "$B"
'

echo
echo "===== 8/12 PACKAGE V58 TO ~/Downloads ====="

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
    "$C:$IM" \
    "$PKG/patched-source/apps/openmw/mwinput/inputmanagerimp.cpp"

docker cp \
    "$C:$HELPER_SRC" \
    "$PKG/patched-source/helper/tsp_openmw_controls.c"

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
TSP_EXPLICIT_UI_STATE_051_V58

Ownership
---------
InputManager:
  says whether a real SDL text field is available.
  owns B's FORCE CONTROLLER lifetime.

Helper:
  owns TEXT vs CONTROLLER and EVIOCGRAB.

OpenMW ControllerManager:
  owns MOUSE.

Text-menu state machine
-----------------------
MOUSE + MENU
  -> engine receives full MENU press/release and disables mouse
  -> helper then reclaims TEXT

TEXT + MENU
  -> CONTROLLER

CONTROLLER + MENU
  -> helper waits for complete MENU release
  -> TEXT

TEXT + left-stick movement
  -> MOUSE

CONTROLLER + left-stick movement
  -> MOUSE

TEXT + B
  -> helper writes FORCE CONTROLLER
  -> helper releases EVIOCGRAB
  -> helper injects Escape
  -> InputManager refuses to recreate text-helper availability
     until SDL text input genuinely reports false
  -> parent menu remains normal CONTROLLER

Mouse neutral guard
-------------------
After MENU returns to TEXT, a still-held left-stick deflection cannot
immediately bounce back to MOUSE. The stick must return near center before
a new deflection may wake MOUSE.

Removed failure mechanism
-------------------------
ControllerManager no longer clears TEXT_OFF/TEXT_ACTIVE just because the
active controller window changes. That was racing the helper and undoing
the intended control state.

Preserved
---------
TSP S L3 mouse convenience
TSP S R3 text reset
MENU-held chord layer
V54 left-stick mouse wake
V55 lingering SDL-focus D-pad allowance
V52 text indicator
custom cursor
EOFBEHAVIOR

cat "$PKG/SHA256SUMS.txt"

echo
echo "===== 9/12 CONNECT TO TSP S ====="

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
    echo "V58 is already patched/built/packaged at:"
    echo "  $PKG"
    echo
    echo "Exit Morrowind normally, then rerun this SAME V58 script."
    echo "It will detect V58 source and skip patching."
    exit 20
fi

echo "PASS: OpenMW is closed."

ssh "$DEV" '
killall tsp_openmw_controls 2>/dev/null || true
'

echo
echo "===== 10/12 BACK UP CURRENT DEVICE FILES ====="

DEV_OPENMW_SHA="$(
ssh "$DEV" \
    "sha256sum '$REMOTE_BIN' | awk '{print \$1}'"
)"

DEV_HELPER_SHA="$(
ssh "$DEV" \
    "sha256sum '$REMOTE_HELPER' | awk '{print \$1}'"
)"

echo "Device OpenMW before:"
echo "  $DEV_OPENMW_SHA"
echo "Device helper before:"
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
echo "PASS: device rollback:"
echo "  $REMOTE_BACKUP"

echo
echo "===== 11/12 UPLOAD + INSTALL V58 ====="

scp -q \
    "$PKG/openmw-0.51" \
    "$DEV:/tmp/openmw-0.51-v58"

scp -q \
    "$PKG/tsp_openmw_controls" \
    "$DEV:/tmp/tsp_openmw_controls-v58"

ssh "$DEV" "
set -e

test -s /tmp/openmw-0.51-v58
test -s /tmp/tsp_openmw_controls-v58

cp \
    /tmp/openmw-0.51-v58 \
    '$REMOTE_BIN.new'

cp \
    /tmp/tsp_openmw_controls-v58 \
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
    /tmp/openmw-0.51-v58 \
    /tmp/tsp_openmw_controls-v58 \
    /tmp/openmw-tsp-text-active \
    /tmp/openmw-tsp-text-char \
    /tmp/openmw-tsp-text-char.tmp \
    /tmp/openmw-tsp-text-off \
    /tmp/openmw-tsp-text-exit-latch \
    /tmp/openmw-tsp-force-controller \
    /tmp/openmw-tsp-request-controller \
    /tmp/openmw-tsp-mouse-mode \
    /tmp/openmw-tsp-mouse-request \
    /tmp/openmw-tsp-mouse-active \
    /tmp/openmw-tsp-text-reset

sync
"

echo
echo "===== 12/12 VERIFY DEVICE HASHES + WRITE TRACE COLLECTOR ====="

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
    'TSP_EXPLICIT_UI_STATE_051_V58' \
    '$REMOTE_BIN'

grep -a -q \
    'TSP_EXPLICIT_UI_STATE_051_V58 active' \
    '$REMOTE_HELPER'

echo 'PASS: V58 engine marker installed.'
echo 'PASS: V58 helper marker installed.'
"

cat > "$PKG/collect-v58-ui-state-trace.sh" <<'EOFTRACE'
#!/usr/bin/env bash
set -Eeuo pipefail

DEV="${TSP_DEV:-root@192.168.1.25}"
OUT="${1:-$HOME/Downloads/openmw51-v58-ui-state-trace-$(date +%Y%m%d-%H%M%S).txt}"

{
    echo "=================================================================="
    echo "OPENMW V58 EXPLICIT UI STATE TRACE"
    echo "=================================================================="

    ssh "$DEV" '
        hostname
        date
    '

    echo
    echo "===== LIVE HELPER EVENTS ====="

    ssh "$DEV" '
        if [ -f /tmp/tsp_controls_051.log ]; then
            grep -E \
              "TSP_EXPLICIT_UI_STATE_051_V58|MODE=|CONTROLLER GRAB|RAW KEY name=(MENU|B)|RAW ABS name=DPAD" \
              /tmp/tsp_controls_051.log |
              tail -500
        else
            echo "/tmp/tsp_controls_051.log absent."
            echo "Run this collector while OpenMW is still running."
        fi
    '

    echo
    echo "===== ENGINE EVENTS ====="

    ssh "$DEV" '
        grep -hE \
          "TSP_EXPLICIT_UI_STATE_051_V58|TSP_NO_STICKCLICK_MODES_051_V54|TSP_TEXT_HANDOFF_051_V51|TSP_MOUSE_MODE_051_V38|TSP_CHORD_051_V43" \
          /mnt/SDCARD/data/ports/openmw51/config-0.51/openmw.log \
          /mnt/SDCARD/tsp_prog.txt \
          2>/dev/null |
          tail -500 || true
    '

    echo
    echo "===== HANDSHAKE FILES ====="

    ssh "$DEV" '
        for f in \
          /tmp/openmw-tsp-text-active \
          /tmp/openmw-tsp-text-char \
          /tmp/openmw-tsp-text-off \
          /tmp/openmw-tsp-force-controller \
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
    "$PKG/collect-v58-ui-state-trace.sh"

cat > "$PKG/INSTALL_REPORT.txt" <<EOFREPORT
OpenMW 0.51 TSP Explicit UI State V58

Created:
$(date)

Source state at start:
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

Required text-menu sequence:
MOUSE -> MENU -> TEXT -> MENU -> CONTROLLER -> MENU -> TEXT
TEXT/CONTROLLER -> left stick -> MOUSE
TEXT -> B -> parent menu CONTROLLER
EOFREPORT

echo
echo "=================================================================="
echo "V58 SUCCESS"
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
echo "Installed OpenMW:"
echo "  $REMOTE_OPENMW_SHA"
echo
echo "Installed helper:"
echo "  $REMOTE_HELPER_SHA"
echo
echo "TEST 1 — B EXIT"
echo "  barter -> stacked item -> MENU -> MENU -> B -> D-pad"
echo "  Expected: parent barter menu is CONTROLLER immediately."
echo
echo "TEST 2 — THREE-STATE CYCLE"
echo "  TEXT -> move left stick -> MOUSE"
echo "       -> MENU -> TEXT"
echo "       -> MENU -> CONTROLLER"
echo "       -> MENU -> TEXT"
echo "       -> new stick movement -> MOUSE"
echo
echo "If either fails, WHILE OPENMW IS STILL RUNNING:"
echo "  $PKG/collect-v58-ui-state-trace.sh"
echo
echo "On any future script failure, STOPPED_ERROR.txt is preserved and"
echo "the script pauses for Enter instead of intentionally closing the terminal."
echo "=================================================================="
