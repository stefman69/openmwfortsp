#!/usr/bin/env bash
set -euo pipefail
set -o pipefail

C=openmw_builder
DEV="${TSP_DEV:-root@192.168.1.25}"
SRC=/root/openmw-0.51-tsp-src
BUILD=/root/openmw-0.51-tsp-build
STAMP="$(date +%Y%m%d-%H%M%S)"
PKG="$HOME/Downloads/openmw51-no-stickclick-v54-$STAMP"
REMOTE_ROOT=/mnt/SDCARD/data/ports/openmw51
REMOTE_BIN="$REMOTE_ROOT/bin/openmw-0.51"
REMOTE_HELPER="$REMOTE_ROOT/tsp_openmw_controls"
REMOTE_BACKUP="$REMOTE_ROOT/backups/no-stickclick-v54-$STAMP"

mkdir -p \
  "$PKG/patched-source/apps/openmw/mwinput" \
  "$PKG/patched-source/helper" \
  "$PKG/source-backup" \
  "$PKG/device-backup"

BUILD_LOG="$PKG/openmw51-no-stickclick-v54-build.log"
PATCH_LOG="$PKG/openmw51-no-stickclick-v54-patch.log"

fail_tail() {
    rc=$?
    echo
    echo "=================================================================="
    echo "FAILED (exit $rc)"
    echo "=================================================================="
    if [ -f "$BUILD_LOG" ]; then
        echo
        echo "----- LAST 180 BUILD LINES -----"
        tail -180 "$BUILD_LOG" || true
    fi
    echo
    echo "Package / preserved traces:"
    echo "  $PKG"
    exit "$rc"
}
trap fail_tail ERR

echo "=================================================================="
echo "OPENMW 0.51 TSP NO-STICK-CLICK CONTROL MODES V54"
echo "=================================================================="
echo "Docker:  $C"
echo "Device:  $DEV"
echo "Package: $PKG"
echo
echo "State machine:"
echo "  TEXT + MENU       -> CONTROLLER"
echo "  TEXT + LEFT STICK -> MOUSE"
echo "  MOUSE + MENU      -> CONTROLLER"
echo "  CONTROLLER + MENU -> TEXT (only when SDL text entry exists)"
echo "  CONTROLLER + LEFT STICK -> MOUSE (cursor-capable GUI only)"
echo "  TSP S L3/R3 shortcuts remain unchanged"
echo "  MENU-held chord layer remains unchanged"
echo

echo "===== 1/11 VERIFY CURRENT SOURCE + CREATE VERIFIED BACKUPS ====="

docker exec -i "$C" python3 - "$STAMP" <<'PYBACKUP' | tee "$PATCH_LOG"
from pathlib import Path
import hashlib
import shutil
import sys

stamp = sys.argv[1]
root = Path("/root/openmw-0.51-tsp-src")
files = [
    root / "apps/openmw/mwinput/controllermanager.cpp",
    root / "apps/openmw/mwinput/inputmanagerimp.cpp",
    Path("/root/tsp_openmw_controls.c"),
]

def sha256(path):
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()

for path in files:
    if not path.is_file():
        raise SystemExit("ERROR: required file missing: %s" % path)

cm = files[0].read_text()
im = files[1].read_text()
helper = files[2].read_text()

required_cm = [
    "TSP_CHORD_051_V43",
    "TSP_TEXT_HANDOFF_051_V51",
    "TSP_A_DOUBLE_PRESS_051_V53",
    "void ControllerManager::tspSetMouseMode(bool on)",
    "SDL_CONTROLLER_BUTTON_LEFTSTICK",
    "SDL_CONTROLLER_BUTTON_RIGHTSTICK",
]
required_im = [
    "TSP_TEXT_HANDOFF_051_V51",
    "TSP_TEXT_INDICATOR_051_V52",
    '"/tmp/openmw-tsp-mouse-mode"',
]
required_helper = [
    "TSP_TEXT_REMAP_051_V40",
    "tsp_enter_pointing_mode",
    "tsp_leave_pointing_mode",
    "EVIOCGRAB",
    "#define KEY_TSP_MENU    316",
]

for needle in required_cm:
    if needle not in cm:
        raise SystemExit("ERROR: controllermanager.cpp missing precondition: %s" % needle)
for needle in required_im:
    if needle not in im:
        raise SystemExit("ERROR: inputmanagerimp.cpp missing precondition: %s" % needle)
for needle in required_helper:
    if needle not in helper:
        raise SystemExit("ERROR: helper source missing precondition: %s" % needle)

marker = "TSP_NO_STICKCLICK_MODES_051_V54"
if marker in cm or marker in im or marker in helper:
    raise SystemExit(
        "ERROR: V54 marker already exists. This controller is for a clean first application."
    )

backup = root / ".tsp-051-source-backups" / ("controller-no-stickclick-v54-" + stamp)
for src in files[:2]:
    dst = backup / src.relative_to(root)
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src, dst)

helper_dst = backup / "root/tsp_openmw_controls.c"
helper_dst.parent.mkdir(parents=True, exist_ok=True)
shutil.copy2(files[2], helper_dst)

print("Backup directory:", backup)
for src in files[:2]:
    dst = backup / src.relative_to(root)
    if sha256(src) != sha256(dst):
        raise SystemExit("ERROR: backup hash mismatch: %s" % src)
    print("BACKUP PASS:", src.relative_to(root), sha256(src))

if sha256(files[2]) != sha256(helper_dst):
    raise SystemExit("ERROR: helper backup hash mismatch")
print("BACKUP PASS: /root/tsp_openmw_controls.c", sha256(files[2]))

Path("/root/openmw51-no-stickclick-v54-backup-path.txt").write_text(str(backup) + "\n")
PYBACKUP

SOURCE_BACKUP="$(docker exec "$C" cat /root/openmw51-no-stickclick-v54-backup-path.txt | tr -d '\r\n')"
docker exec "$C" test -d "$SOURCE_BACKUP"

echo
echo "===== 2/11 APPLY ENGINE + HELPER PATCH ====="

docker exec -i "$C" python3 <<'PYPATCH' | tee -a "$PATCH_LOG"
from pathlib import Path

SRC = Path("/root/openmw-0.51-tsp-src")
CM = SRC / "apps/openmw/mwinput/controllermanager.cpp"
IM = SRC / "apps/openmw/mwinput/inputmanagerimp.cpp"
HELPER = Path("/root/tsp_openmw_controls.c")
MARK = "TSP_NO_STICKCLICK_MODES_051_V54"

def replace_once(text, old, new, label):
    count = text.count(old)
    if count != 1:
        raise SystemExit(
            "ERROR: %s anchor matched %d times (expected exactly 1). NOTHING WRITTEN."
            % (label, count)
        )
    return text.replace(old, new, 1)

cm0 = CM.read_text()
im0 = IM.read_text()
h0 = HELPER.read_text()
cm = cm0
im = im0
h = h0

cm = replace_once(
    cm,
'''        const char* const sTspHelperYieldFlag = "/tmp/openmw-tsp-mouse-mode";''',
'''        const char* const sTspHelperYieldFlag = "/tmp/openmw-tsp-mouse-mode";

        // TSP_NO_STICKCLICK_MODES_051_V54
        // V51 deliberately made sTspHelperYieldFlag mean only "the helper
        // yielded the controller". Do not overload that flag with mouse state
        // again. These two files give the no-stick-click path an explicit,
        // one-way request plus an engine-owned acknowledgement.
        const char* const sTspMouseRequestFlag = "/tmp/openmw-tsp-mouse-request";
        const char* const sTspMouseActiveFlag = "/tmp/openmw-tsp-mouse-active";
        constexpr Sint16 sTspMouseWakeAxisThreshold = 8000;''',
    "CM flags",
)

cm = replace_once(
    cm,
'''                std::remove(sTspHelperYieldFlag);

                if (mTspMouseMode)''',
'''                std::remove(sTspHelperYieldFlag);
                // TSP_NO_STICKCLICK_MODES_051_V54
                std::remove(sTspMouseRequestFlag);

                if (mTspMouseMode)''',
    "CM window-change request cleanup",
)

cm = replace_once(
    cm,
'''                Log(Debug::Info) << "TSP_TEXT_HANDOFF_051_V51 menu=tap action=helper-owned";''',
'''                // TSP_NO_STICKCLICK_MODES_051_V54
                // When the engine currently owns a mouse-capable GUI, bare MENU
                // means MOUSE -> CONTROLLER. If mouse mode is already off, keep
                // V51's ownership rule: the helper may use this same MENU press
                // to reclaim TEXT when a text field is actually active.
                if (mTspMouseMode)
                {
                    tspSetMouseMode(false);
                    Log(Debug::Info)
                        << "TSP_NO_STICKCLICK_MODES_051_V54 menu=mouse-to-controller";
                }
                else
                {
                    Log(Debug::Info)
                        << "TSP_TEXT_HANDOFF_051_V51 menu=tap action=helper-owned";
                }''',
    "CM MENU mouse->controller",
)

cm = replace_once(
    cm,
'''            if (topWin && topWin->isVisible())
            {
                // Update cursor state
                mGamepadGuiCursorEnabled
                    = tspSettingsMouseActive && topWin->isGamepadCursorAllowed();''',
'''            if (topWin && topWin->isVisible())
            {
                // TSP_NO_STICKCLICK_MODES_051_V54
                // Base TSP has no L3. In native/controller GUI mode, a deliberate
                // left-stick movement is therefore the intuitive request for the
                // pointer. Only windows that already permit OpenMW's gamepad cursor
                // can wake it; main/pause/loading opt-outs stay untouched.
                if (!tspSettingsMouseActive
                    && topWin->isGamepadCursorAllowed()
                    && (arg.axis == SDL_CONTROLLER_AXIS_LEFTX
                        || arg.axis == SDL_CONTROLLER_AXIS_LEFTY)
                    && std::abs(static_cast<int>(arg.value))
                        >= static_cast<int>(sTspMouseWakeAxisThreshold))
                {
                    mGamepadGuiCursorEnabled = true;
                    tspSetMouseMode(true);
                    winMgr->setControllerTooltipVisible(false);
                    Log(Debug::Info)
                        << "TSP_NO_STICKCLICK_MODES_051_V54"
                        << " left-stick=controller-to-mouse"
                        << " axis=" << static_cast<int>(arg.axis)
                        << " value=" << static_cast<int>(arg.value);
                    return true;
                }

                // Update cursor state
                mGamepadGuiCursorEnabled
                    = tspSettingsMouseActive && topWin->isGamepadCursorAllowed();''',
    "CM native controller left-stick wake",
)

cm = replace_once(
    cm,
'''    void ControllerManager::tspSetMouseMode(bool on)
    {
        mTspMouseMode = on;

        MWBase::WindowManager* winMgr = MWBase::Environment::get().getWindowManager();
        winMgr->setCursorActive(on);
        winMgr->setCursorVisible(on);

        Log(Debug::Info) << "TSP_MOUSE_MODE_051_V38 mouseMode=" << (on ? 1 : 0)
                         << " gui=" << (winMgr->isGuiMode() ? 1 : 0);
    }''',
'''    void ControllerManager::tspSetMouseMode(bool on)
    {
        mTspMouseMode = on;

        // TSP_NO_STICKCLICK_MODES_051_V54
        // The helper consults this only when it has already yielded the pad.
        // MENU while this file exists must be left to the engine so the first
        // tap performs MOUSE -> CONTROLLER instead of jumping straight to TEXT.
        if (on)
        {
            if (std::FILE* tspMouseActive = std::fopen(sTspMouseActiveFlag, "w"))
            {
                std::fputs("1\\n", tspMouseActive);
                std::fclose(tspMouseActive);
            }
            else
                Log(Debug::Warning)
                    << "TSP_NO_STICKCLICK_MODES_051_V54 mouse-active-flag=write-failed";
        }
        else
            std::remove(sTspMouseActiveFlag);

        MWBase::WindowManager* winMgr = MWBase::Environment::get().getWindowManager();
        winMgr->setCursorActive(on);
        winMgr->setCursorVisible(on);

        Log(Debug::Info) << "TSP_MOUSE_MODE_051_V38 mouseMode=" << (on ? 1 : 0)
                         << " gui=" << (winMgr->isGuiMode() ? 1 : 0);
    }''',
    "CM tspSetMouseMode active flag",
)

im = replace_once(
    im,
'''            bool tspHelperPointing = false;
            if (std::FILE* tspFlag = std::fopen("/tmp/openmw-tsp-mouse-mode", "r"))
            {
                tspHelperPointing = true;
                std::fclose(tspFlag);
            }

            // TSP_VISIBLE_CURSOR_051_V47 -- the old condition called''',
'''            // TSP_NO_STICKCLICK_MODES_051_V54
            // A left-stick move while TEXT owns EVIOCGRAB cannot reach SDL/OpenMW.
            // The helper therefore publishes a dedicated mouse request, releases
            // the grab, and this side turns the engine pointer on. V51's older
            // /tmp/openmw-tsp-mouse-mode remains a pure "helper yielded" signal.
            bool tspHelperMouseRequest = false;
            if (std::FILE* tspRequest
                = std::fopen("/tmp/openmw-tsp-mouse-request", "r"))
            {
                tspHelperMouseRequest = true;
                std::fclose(tspRequest);
            }

            if (tspHelperMouseRequest)
            {
                std::remove("/tmp/openmw-tsp-mouse-request");
                std::remove("/tmp/openmw-tsp-mouse-mode");

                if (tspTextEntryActive && windowManager->isGuiMode())
                {
                    mControllerManager->tspSetMouseMode(true);
                    std::fprintf(stderr,
                        "TSP_NO_STICKCLICK_MODES_051_V54 helper-left-stick=text-to-mouse\\n");
                }
                else
                {
                    std::fprintf(stderr,
                        "TSP_NO_STICKCLICK_MODES_051_V54 helper-left-stick=ignored-no-text-gui\\n");
                }
                std::fflush(stderr);
            }

            bool tspHelperPointing = false;
            if (std::FILE* tspFlag = std::fopen("/tmp/openmw-tsp-mouse-mode", "r"))
            {
                tspHelperPointing = true;
                std::fclose(tspFlag);
            }

            // TSP_VISIBLE_CURSOR_051_V47 -- the old condition called''',
    "IM helper mouse request",
)

im = replace_once(
    im,
'''                std::remove("/tmp/openmw-tsp-text-active");
                std::remove("/tmp/openmw-tsp-text-char");''',
'''                std::remove("/tmp/openmw-tsp-text-active");
                std::remove("/tmp/openmw-tsp-text-char");
                // TSP_NO_STICKCLICK_MODES_051_V54
                std::remove("/tmp/openmw-tsp-mouse-request");''',
    "IM text-end request cleanup",
)

h = replace_once(
    h,
'''#define ABS_TSP_DPAD_X  16
#define ABS_TSP_DPAD_Y  17''',
'''#define ABS_TSP_DPAD_X  16
#define ABS_TSP_DPAD_Y  17

/* TSP_NO_STICKCLICK_MODES_051_V54 -- raw evdev left-stick axes. */
#define ABS_TSP_LEFT_X  ABS_X
#define ABS_TSP_LEFT_Y  ABS_Y''',
    "helper left axis definitions",
)

h = replace_once(
    h,
'''#define MOUSE_MODE_FLAG "/tmp/openmw-tsp-mouse-mode"''',
'''#define MOUSE_MODE_FLAG "/tmp/openmw-tsp-mouse-mode"

/* TSP_NO_STICKCLICK_MODES_051_V54
 * Keep V51's yield flag meaning intact. Mouse request and mouse-active are
 * separate so MENU can reliably walk MOUSE -> CONTROLLER -> TEXT.
 */
#define MOUSE_REQUEST_FLAG "/tmp/openmw-tsp-mouse-request"
#define MOUSE_ACTIVE_FLAG  "/tmp/openmw-tsp-mouse-active"''',
    "helper request flags",
)

h = replace_once(
    h,
'''static int dpad_x = 0;
static int dpad_y = 0;''',
'''static int dpad_x = 0;
static int dpad_y = 0;

/* TSP_NO_STICKCLICK_MODES_051_V54 */
static int left_x = 0;
static int left_y = 0;
static int left_x_center = 0;
static int left_y_center = 0;
static int left_x_threshold = 8000;
static int left_y_threshold = 8000;''',
    "helper left state",
)

h = replace_once(
    h,
'''    switch (code) {
        case ABS_TSP_DPAD_X: return "DPAD_X";
        case ABS_TSP_DPAD_Y: return "DPAD_Y";
        default: return "OTHER";
    }''',
'''    switch (code) {
        case ABS_TSP_DPAD_X: return "DPAD_X";
        case ABS_TSP_DPAD_Y: return "DPAD_Y";
        case ABS_TSP_LEFT_X: return "LEFT_X";
        case ABS_TSP_LEFT_Y: return "LEFT_Y";
        default: return "OTHER";
    }''',
    "helper abs names",
)

h = replace_once(
    h,
'''static void change_text_index(int direction)
{''',
'''/* TSP_NO_STICKCLICK_MODES_051_V54 */
static bool openmw_mouse_active(void)
{
    return access(MOUSE_ACTIVE_FLAG, F_OK) == 0;
}

static void init_left_stick_geometry(void)
{
    struct input_absinfo info;

    if (ioctl(controller_fd, EVIOCGABS(ABS_TSP_LEFT_X), &info) == 0) {
        const int span = info.maximum - info.minimum;
        left_x_center = info.minimum + span / 2;
        left_x_threshold = span / 8;
        if (left_x_threshold < 2048)
            left_x_threshold = 2048;
    }

    if (ioctl(controller_fd, EVIOCGABS(ABS_TSP_LEFT_Y), &info) == 0) {
        const int span = info.maximum - info.minimum;
        left_y_center = info.minimum + span / 2;
        left_y_threshold = span / 8;
        if (left_y_threshold < 2048)
            left_y_threshold = 2048;
    }

    if (log_file != NULL) {
        fprintf(log_file,
            "TSP_NO_STICKCLICK_MODES_051_V54 left-stick center=%d,%d threshold=%d,%d\\n",
            left_x_center, left_y_center, left_x_threshold, left_y_threshold);
        fflush(log_file);
    }
}

static void tsp_request_mouse_mode(void)
{
    log_line("TSP_NO_STICKCLICK_MODES_051_V54 LEFT STICK: TEXT -> MOUSE.");
    suppress_auto_text = true;

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
}

static void change_text_index(int direction)
{''',
    "helper mouse request helpers",
)

h = replace_once(
    h,
'''        if (event->code == KEY_TSP_MENU && pressed && suppress_auto_text
            && openmw_text_active()) {
            tsp_leave_pointing_mode();
        }
        return;''',
'''        if (event->code == KEY_TSP_MENU && pressed && suppress_auto_text
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
        return;''',
    "helper MENU state distinction",
)

old_abs = r'''static void handle_abs_event(const struct input_event *event)
{
    if (event->code != ABS_TSP_DPAD_X &&
        event->code != ABS_TSP_DPAD_Y)
        return;

    log_raw_abs(event);

    if (mode != MODE_TEXT)
        return;

    if (event->code == ABS_TSP_DPAD_X) {
        const int old_value = dpad_x;
        dpad_x = event->value;

        if (old_value == 0) {
            if (dpad_x > 0)
                tap_key(KEY_RIGHT);
            else if (dpad_x < 0)
#if TSP_TEXT_BACKSPACE_ON_DPAD_LEFT
                /* TSP_TEXT_REMAP_051_V40 -- left is backspace; cancel took B. */
                tap_key(KEY_BACKSPACE);
#else
                tap_key(KEY_LEFT);
#endif
        }
        return;
    }

    if (event->code == ABS_TSP_DPAD_Y) {
        const int old_value = dpad_y;
        dpad_y = event->value;

        if (old_value == 0) {
            if (dpad_y > 0)
                change_text_index(1);
            else if (dpad_y < 0)
                change_text_index(-1);
        }
    }
}'''

new_abs = r'''static void handle_abs_event(const struct input_event *event)
{
    /* TSP_NO_STICKCLICK_MODES_051_V54
     * TEXT owns EVIOCGRAB, so only the helper can see the first analog movement.
     * A deliberate left-stick deflection releases the grab and asks OpenMW to
     * enter pointer mode. Do not raw-log every analog sample.
     */
    if (event->code == ABS_TSP_LEFT_X || event->code == ABS_TSP_LEFT_Y) {
        if (event->code == ABS_TSP_LEFT_X)
            left_x = event->value;
        else
            left_y = event->value;

        if (mode == MODE_TEXT) {
            const int dx = abs(left_x - left_x_center);
            const int dy = abs(left_y - left_y_center);

            if (dx >= left_x_threshold || dy >= left_y_threshold)
                tsp_request_mouse_mode();
        }
        return;
    }

    if (event->code != ABS_TSP_DPAD_X &&
        event->code != ABS_TSP_DPAD_Y)
        return;

    log_raw_abs(event);

    if (mode != MODE_TEXT)
        return;

    if (event->code == ABS_TSP_DPAD_X) {
        const int old_value = dpad_x;
        dpad_x = event->value;

        if (old_value == 0) {
            if (dpad_x > 0)
                tap_key(KEY_RIGHT);
            else if (dpad_x < 0)
#if TSP_TEXT_BACKSPACE_ON_DPAD_LEFT
                /* TSP_TEXT_REMAP_051_V40 -- left is backspace; cancel took B. */
                tap_key(KEY_BACKSPACE);
#else
                tap_key(KEY_LEFT);
#endif
        }
        return;
    }

    if (event->code == ABS_TSP_DPAD_Y) {
        const int old_value = dpad_y;
        dpad_y = event->value;

        if (old_value == 0) {
            if (dpad_y > 0)
                change_text_index(1);
            else if (dpad_y < 0)
                change_text_index(-1);
        }
    }
}'''

h = replace_once(h, old_abs, new_abs, "helper handle_abs_event")

h = replace_once(
    h,
'''    unlink(TEXT_CHAR_TMP);
    unlink(MOUSE_MODE_FLAG); /* TSP_TEXT_REMAP_051_V40 */

    controller_fd = find_controller();''',
'''    unlink(TEXT_CHAR_TMP);
    unlink(MOUSE_MODE_FLAG); /* TSP_TEXT_REMAP_051_V40 */
    /* TSP_NO_STICKCLICK_MODES_051_V54 */
    unlink(MOUSE_REQUEST_FLAG);
    unlink(MOUSE_ACTIVE_FLAG);

    controller_fd = find_controller();''',
    "helper startup cleanup",
)

h = replace_once(
    h,
'''    if (controller_fd < 0) {
        log_line("ERROR: TRIMUI Player1 was not found.");
        if (log_file != NULL)
            fclose(log_file);
        return 1;
    }

    uinput_fd = create_uinput_device();''',
'''    if (controller_fd < 0) {
        log_line("ERROR: TRIMUI Player1 was not found.");
        if (log_file != NULL)
            fclose(log_file);
        return 1;
    }

    /* TSP_NO_STICKCLICK_MODES_051_V54 */
    init_left_stick_geometry();

    uinput_fd = create_uinput_device();''',
    "helper geometry initialization",
)

h = replace_once(
    h,
'''    log_line("Menu: TYPING <-> POINTING (yields pad to OpenMW, text stays open).");
    log_line("TSP_TEXT_REMAP_051_V40 active.");''',
'''    log_line("Menu: TEXT -> CONTROLLER; CONTROLLER -> TEXT when text entry is active.");
    log_line("Left stick: TEXT/CONTROLLER -> MOUSE in cursor-capable menus.");
    log_line("Menu from MOUSE: returns to CONTROLLER before TEXT.");
    log_line("TSP_TEXT_REMAP_051_V40 active.");
    log_line("TSP_NO_STICKCLICK_MODES_051_V54 active.");''',
    "helper startup description",
)

h = replace_once(
    h,
'''    unlink(TEXT_CHAR_TMP);
    unlink(MOUSE_MODE_FLAG); /* TSP_TEXT_REMAP_051_V40 */

    if (uinput_fd >= 0) {''',
'''    unlink(TEXT_CHAR_TMP);
    unlink(MOUSE_MODE_FLAG); /* TSP_TEXT_REMAP_051_V40 */
    /* TSP_NO_STICKCLICK_MODES_051_V54 */
    unlink(MOUSE_REQUEST_FLAG);
    unlink(MOUSE_ACTIVE_FLAG);

    if (uinput_fd >= 0) {''',
    "helper shutdown cleanup",
)

checks = [
    (cm, MARK, 8, "CM V54 marker"),
    (im, MARK, 4, "IM V54 marker"),
    (h, MARK, 11, "helper V54 marker"),
]
for text, needle, minimum, label in checks:
    got = text.count(needle)
    if got < minimum:
        raise SystemExit("ERROR: %s count=%d" % (label, got))

if cm.count("tspSetMouseMode(!mTspMouseMode);") < 1:
    raise SystemExit("ERROR: L3 mouse toggle was lost")
if "r3=force-text-reset" not in cm:
    raise SystemExit("ERROR: R3 text-reset shortcut was lost")
if "TSP_CHORD_051_V43" not in cm:
    raise SystemExit("ERROR: MENU chord watchdog was lost")
if h.count("tsp_enter_pointing_mode();") != 1:
    raise SystemExit("ERROR: helper TEXT->controller MENU path changed unexpectedly")
if h.count("tsp_leave_pointing_mode();") != 1:
    raise SystemExit("ERROR: helper controller->TEXT MENU path changed unexpectedly")
if "MOUSE_REQUEST_FLAG" not in h or "MOUSE_ACTIVE_FLAG" not in h:
    raise SystemExit("ERROR: helper request/active handshake missing")

for label, text in (("controllermanager.cpp", cm), ("inputmanagerimp.cpp", im), ("helper", h)):
    if text.count("{") != text.count("}"):
        raise SystemExit("ERROR: brace imbalance in %s" % label)

CM.write_text(cm)
IM.write_text(im)
HELPER.write_text(h)

print("PATCH PASS:", CM)
print("PATCH PASS:", IM)
print("PATCH PASS:", HELPER)
print("Preserved: L3, R3, MENU chords, V51 yield semantics")
print("Added: TEXT/CONTROLLER left-stick -> mouse; MOUSE MENU -> controller")
PYPATCH

echo
echo "===== 3/11 VERIFY BACKUP STILL MATCHES PRE-PATCH SOURCE ====="

docker exec "$C" python3 - "$SOURCE_BACKUP" <<'PYVERIFY'
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
    (backup / "apps/openmw/mwinput/controllermanager.cpp", root / "apps/openmw/mwinput/controllermanager.cpp"),
    (backup / "apps/openmw/mwinput/inputmanagerimp.cpp", root / "apps/openmw/mwinput/inputmanagerimp.cpp"),
    (backup / "root/tsp_openmw_controls.c", Path("/root/tsp_openmw_controls.c")),
]
for old, new in pairs:
    if not old.is_file() or not new.is_file():
        raise SystemExit("ERROR: backup/current file missing")
    if sha256(old) == sha256(new):
        raise SystemExit("ERROR: patched file did not change: %s" % new)
    print("PASS: backup differs from patched:", new)
PYVERIFY

echo
echo "===== 4/11 BUILD NEW HELPER ====="

docker exec "$C" bash -lc '
set -euo pipefail
SRC=/root/tsp_openmw_controls.c
OUT=/root/tsp_openmw_controls-v54
CC=""
for c in gcc-13 aarch64-linux-gnu-gcc gcc cc; do
    if command -v "$c" >/dev/null 2>&1; then
        CC="$(command -v "$c")"
        break
    fi
done
[ -n "$CC" ] || { echo "ERROR: no C compiler found"; exit 1; }
echo "Helper compiler: $CC"
"$CC" -O2 -std=gnu11 -Wall -Wextra "$SRC" -lm -o "$OUT"
chmod 755 "$OUT"
readelf -h "$OUT" | grep -E "Class:|Machine:|Type:"
readelf -h "$OUT" | grep -q "AArch64" || { echo "ERROR: helper is not AArch64"; exit 1; }
grep -a -q "TSP_NO_STICKCLICK_MODES_051_V54 active" "$OUT" || { echo "ERROR: helper marker absent"; exit 1; }
sha256sum "$OUT"
'

echo
echo "===== 5/11 FORCE ONLY THE TWO INPUT OBJECTS TO RECOMPILE ====="

docker exec "$C" bash -lc '
set -euo pipefail
B=/root/openmw-0.51-tsp-build
S=/root/openmw-0.51-tsp-src
find "$B" -type f \( -name "controllermanager.cpp.o" -o -name "inputmanagerimp.cpp.o" \) -print -delete
rm -fv "$B/openmw" "$B/apps/openmw/openmw"
touch "$S/apps/openmw/mwinput/controllermanager.cpp" "$S/apps/openmw/mwinput/inputmanagerimp.cpp"
'

echo
echo "===== 6/11 BUILD OPENMW + PRESERVE FULL TRACE ====="

set +e
docker exec "$C" bash -lc '
set -o pipefail
cmake --build /root/openmw-0.51-tsp-build --target openmw -- -j4
' 2>&1 | tee "$BUILD_LOG"
BUILD_RC=${PIPESTATUS[0]}
set -e
if [ "$BUILD_RC" -ne 0 ]; then
    echo "BUILD FAILED. Full trace: $BUILD_LOG"
    tail -180 "$BUILD_LOG"
    exit "$BUILD_RC"
fi

echo
echo "===== 7/11 VERIFY BOTH NEW BINARIES ====="

docker exec "$C" bash -lc '
set -euo pipefail
B=/root/openmw-0.51-tsp-build/openmw
H=/root/tsp_openmw_controls-v54
test -x "$B"; test -x "$H"
readelf -h "$B" | grep -E "Class:|Machine:|Type:"
readelf -h "$B" | grep -q "AArch64"
readelf -h "$H" | grep -q "AArch64"
grep -a -q "TSP_NO_STICKCLICK_MODES_051_V54 menu=mouse-to-controller" "$B"
grep -a -q "TSP_NO_STICKCLICK_MODES_051_V54 active" "$H"
grep -a -q "TSP_CHORD_051_V43" "$B"
grep -a -q "r3=force-text-reset" "$B"
grep -a -q "tx_cursor.dds" "$B"
echo "PASS: V54 + chords + R3 + cursor retained"
sha256sum "$B" "$H"
'

echo
echo "===== 8/11 BUILD DOWNLOADS PACKAGE ====="

docker cp "$C:/root/openmw-0.51-tsp-build/openmw" "$PKG/openmw-0.51"
docker cp "$C:/root/tsp_openmw_controls-v54" "$PKG/tsp_openmw_controls"
for F in apps/openmw/mwinput/controllermanager.cpp apps/openmw/mwinput/inputmanagerimp.cpp; do
    docker cp "$C:$SRC/$F" "$PKG/patched-source/$F"
done
docker cp "$C:/root/tsp_openmw_controls.c" "$PKG/patched-source/helper/tsp_openmw_controls.c"
docker cp "$C:$SOURCE_BACKUP/." "$PKG/source-backup/"

cat > "$PKG/CONTROL_BEHAVIOR.txt" <<'EOF'
OpenMW 0.51 TSP no-stick-click controls V54

Base TSP:
  TEXT + MENU             -> CONTROLLER
  TEXT + LEFT STICK       -> MOUSE
  MOUSE + MENU            -> CONTROLLER
  CONTROLLER + MENU       -> TEXT, only when a text field is active
  CONTROLLER + LEFT STICK -> MOUSE, only in cursor-capable GUI windows

TrimUI Smart Pro S:
  Same behavior, plus existing L3/R3 shortcuts remain available.

Preserved:
  MENU-held chord layer / quick slots / quit
  V51 helper-yield semantics
  V52 text indicator
  V53 A-button routing fix
EOF
(
    cd "$PKG"
    sha256sum openmw-0.51 tsp_openmw_controls > SHA256SUMS.txt
)
echo "Source backup: $SOURCE_BACKUP" > "$PKG/SOURCE_BACKUP_PATH.txt"
find "$PKG" -maxdepth 6 -type f -printf '  %P\n'

echo
echo "===== 9/11 CONNECT + BACK UP CURRENT TSP S ====="

ssh -o BatchMode=yes -o ConnectTimeout=8 "$DEV" 'echo "SSH OK: $(hostname)"; date'
if ssh -o BatchMode=yes "$DEV" 'pidof openmw-0.51 >/dev/null 2>&1 || pidof openmw >/dev/null 2>&1'; then
    echo "ERROR: OpenMW is still running. Exit it normally and rerun this controller."
    exit 1
fi

ssh "$DEV" "
set -e
test -s '$REMOTE_BIN'
test -s '$REMOTE_HELPER'
mkdir -p '$REMOTE_BACKUP'
cp -p '$REMOTE_BIN' '$REMOTE_BACKUP/openmw-0.51'
cp -p '$REMOTE_HELPER' '$REMOTE_BACKUP/tsp_openmw_controls'
sha256sum '$REMOTE_BACKUP/openmw-0.51' '$REMOTE_BACKUP/tsp_openmw_controls' > '$REMOTE_BACKUP/SHA256SUMS.txt'
sync
"
scp -q "$DEV:$REMOTE_BIN" "$PKG/device-backup/openmw-0.51"
scp -q "$DEV:$REMOTE_HELPER" "$PKG/device-backup/tsp_openmw_controls"
(
    cd "$PKG/device-backup"
    sha256sum openmw-0.51 tsp_openmw_controls > SHA256SUMS.txt
)

echo
echo "===== 10/11 INSTALL BOTH FILES ATOMICALLY ====="

scp -q "$PKG/openmw-0.51" "$DEV:/tmp/openmw-0.51-v54"
scp -q "$PKG/tsp_openmw_controls" "$DEV:/tmp/tsp_openmw_controls-v54"
ssh "$DEV" "
set -e
test -s /tmp/openmw-0.51-v54
test -s /tmp/tsp_openmw_controls-v54
cp /tmp/openmw-0.51-v54 '$REMOTE_BIN.new'
cp /tmp/tsp_openmw_controls-v54 '$REMOTE_HELPER.new'
chmod 755 '$REMOTE_BIN.new' '$REMOTE_HELPER.new'
mv -f '$REMOTE_BIN.new' '$REMOTE_BIN'
mv -f '$REMOTE_HELPER.new' '$REMOTE_HELPER'
rm -f /tmp/openmw-0.51-v54 /tmp/tsp_openmw_controls-v54 \
  /tmp/openmw-tsp-mouse-request /tmp/openmw-tsp-mouse-active \
  /tmp/openmw-tsp-mouse-mode /tmp/openmw-tsp-text-off \
  /tmp/openmw-tsp-text-reset /tmp/openmw-tsp-text-char \
  /tmp/openmw-tsp-text-char.tmp
sync
"

echo
echo "===== 11/11 VERIFY REMOTE HASHES + WRITE TEST TRACE COLLECTOR ====="

LOCAL_BIN_SHA="$(sha256sum "$PKG/openmw-0.51" | awk '{print $1}')"
LOCAL_HELPER_SHA="$(sha256sum "$PKG/tsp_openmw_controls" | awk '{print $1}')"
REMOTE_BIN_SHA="$(ssh "$DEV" "sha256sum '$REMOTE_BIN' | awk '{print \$1}'")"
REMOTE_HELPER_SHA="$(ssh "$DEV" "sha256sum '$REMOTE_HELPER' | awk '{print \$1}'")"

echo "OpenMW local : $LOCAL_BIN_SHA"
echo "OpenMW remote: $REMOTE_BIN_SHA"
echo "Helper local : $LOCAL_HELPER_SHA"
echo "Helper remote: $REMOTE_HELPER_SHA"
[ "$LOCAL_BIN_SHA" = "$REMOTE_BIN_SHA" ] || { echo "ERROR: OpenMW remote hash mismatch"; exit 1; }
[ "$LOCAL_HELPER_SHA" = "$REMOTE_HELPER_SHA" ] || { echo "ERROR: helper remote hash mismatch"; exit 1; }

cat > "$PKG/collect-v54-control-trace.sh" <<'EOFTRACE'
#!/usr/bin/env bash
set -euo pipefail
DEV="${TSP_DEV:-root@192.168.1.25}"
OUT="${1:-$HOME/Downloads/openmw51-v54-control-trace-$(date +%Y%m%d-%H%M%S).txt}"
{
    echo "===== DEVICE / TIME ====="
    ssh "$DEV" 'hostname; date'
    echo
    echo "===== OPENMW V54 EVENTS ====="
    ssh "$DEV" '
        grep -hE "TSP_NO_STICKCLICK_MODES_051_V54|TSP_TEXT_HANDOFF_051_V51|TSP_MOUSE_MODE_051_V38" \
          /mnt/SDCARD/data/ports/openmw51/config-0.51/openmw.log \
          /mnt/SDCARD/tsp_prog.txt 2>/dev/null | tail -200 || true
    '
    echo
    echo "===== LIVE HELPER LOG (if game is still running) ====="
    ssh "$DEV" '
        if [ -f /tmp/tsp_controls_051.log ]; then
            grep -E "TSP_NO_STICKCLICK_MODES_051_V54|MODE=|MENU:|LEFT STICK|CONTROLLER GRAB" \
              /tmp/tsp_controls_051.log | tail -200
        else
            echo "/tmp/tsp_controls_051.log absent (launcher removes it after game exit)."
        fi
    '
    echo
    echo "===== HANDSHAKE FILES ====="
    ssh "$DEV" '
        for f in /tmp/openmw-tsp-text-active /tmp/openmw-tsp-text-char \
                 /tmp/openmw-tsp-mouse-mode /tmp/openmw-tsp-mouse-request \
                 /tmp/openmw-tsp-mouse-active; do
            if [ -e "$f" ]; then
                printf "EXISTS  %s  " "$f"; cat "$f" 2>/dev/null || true
            else
                echo "absent  $f"
            fi
        done
    '
} 2>&1 | tee "$OUT"
echo
echo "Trace preserved: $OUT"
EOFTRACE
chmod +x "$PKG/collect-v54-control-trace.sh"

cat > "$PKG/INSTALL_REPORT.txt" <<EOFREPORT
OpenMW 0.51 TSP no-stick-click controls V54
Created: $(date)
Source branch: tsp-clean-pre-interior
Base source commit: 0901ea884fd59a7067424b5b9ac16bc7b30344dd
Source backup: $SOURCE_BACKUP
Device rollback directory: $REMOTE_BACKUP
OpenMW SHA256: $REMOTE_BIN_SHA
Helper SHA256: $REMOTE_HELPER_SHA
EOFREPORT

echo
echo "=================================================================="
echo "SUCCESS"
echo "=================================================================="
echo "Package:"
echo "  $PKG"
echo "Device rollback:"
echo "  $REMOTE_BACKUP"
echo "After testing, preserve/print the controller trace with:"
echo "  $PKG/collect-v54-control-trace.sh"
echo "For the base TSP, copy BOTH:"
echo "  $PKG/openmw-0.51"
echo "  $PKG/tsp_openmw_controls"
echo "=================================================================="
