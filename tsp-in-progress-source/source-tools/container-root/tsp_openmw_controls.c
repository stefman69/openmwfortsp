#define _GNU_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <linux/input.h>
#include <linux/uinput.h>
#include <poll.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/time.h>
#include <unistd.h>

#define DEVICE_NAME "TRIMUI Player1"

#define KEY_TSP_A       305
#define KEY_TSP_B       304
#define KEY_TSP_X       308
#define KEY_TSP_Y       307
#define KEY_TSP_L1      310
#define KEY_TSP_R1      311
#define KEY_TSP_L3      317
#define KEY_TSP_R3      318

/* Corrected physical button identities on this TrimUI Smart Pro S. */
#define KEY_TSP_START   315
#define KEY_TSP_SELECT  314
#define KEY_TSP_MENU    316

#define ABS_TSP_DPAD_X  16
#define ABS_TSP_DPAD_Y  17

/* TSP_NO_STICKCLICK_MODES_051_V54 -- raw evdev left-stick axes. */
#define ABS_TSP_LEFT_X  ABS_X
#define ABS_TSP_LEFT_Y  ABS_Y

#define TICK_MS 10

#define TEXT_ACTIVE_FLAG "/tmp/openmw-tsp-text-active"
#define TEXT_CHAR_FILE   "/tmp/openmw-tsp-text-char"
#define TEXT_CHAR_TMP    "/tmp/openmw-tsp-text-char.tmp"
/* TSP_TEXT_INJECT_V64 -- queue of characters for the engine to inject. */
#define TEXT_INJECT_FILE "/tmp/openmw-tsp-text-inject"

/* TSP_NAME_TEXT_LOCK_051_V67 -- engine-owned mandatory text field flag. */
#define TEXT_REQUIRED_FLAG "/tmp/openmw-tsp-text-required"

/* TSP_TEXT_EXIT_CONTROLLER_051_V55
 * Shared with ControllerManager's existing sTspTextOffFlag. This file means:
 * "SDL may still have an EditBox focused, but the user intentionally selected
 * ordinary controller navigation, so the helper must not hold EVIOCGRAB."
 */
#define TEXT_OFF_FLAG    "/tmp/openmw-tsp-text-off"

/*
 * TSP_TEXT_REMAP_051_V40
 *
 * MENU no longer cancels text entry. It now switches between TYPING (helper
 * holds EVIOCGRAB) and POINTING (helper yields the pad so OpenMW can drive its
 * cursor), with text entry left open either way. OpenMW learns which state we
 * are in from MOUSE_MODE_FLAG.
 *
 * One-token retune: set TSP_TEXT_CANCEL_KEY to KEY_TSP_SELECT to put cancel
 * back on SELECT. B then automatically returns to being backspace.
 */
#define TSP_TEXT_CANCEL_KEY             KEY_TSP_B
#define TSP_TEXT_BACKSPACE_ON_DPAD_LEFT 1
#define MOUSE_MODE_FLAG "/tmp/openmw-tsp-mouse-mode"

/* TSP_NO_STICKCLICK_MODES_051_V54
 * Keep V51's yield flag meaning intact. Mouse request and mouse-active are
 * separate so MENU can reliably walk MOUSE -> CONTROLLER -> TEXT.
 */
#define MOUSE_REQUEST_FLAG "/tmp/openmw-tsp-mouse-request"
#define MOUSE_ACTIVE_FLAG  "/tmp/openmw-tsp-mouse-active"

/* TSP_EXPLICIT_UI_STATE_051_V58
 * B owns this request until InputManager observes SDL text input really end.
 */
#define FORCE_CONTROLLER_FLAG "/tmp/openmw-tsp-force-controller"

typedef enum {
    MODE_GAME = 0,
    MODE_TEXT = 1
} control_mode;

typedef enum {
    CHARSET_LETTERS = 0,
    CHARSET_ALT = 1
} charset_mode;

static volatile sig_atomic_t running = 1;
static int controller_fd = -1;
static int uinput_fd = -1;
static FILE *log_file = NULL;
static bool grabbed = false;
static bool suppress_auto_text = false;

/*
 * TSP_FACE_LAYOUT_051_V67
 *
 * Stock/CrossMix exposes the TSP face buttons in the historical swapped
 * evdev order used by this helper:
 *   physical A=305 B=304 X=308 Y=307
 *
 * muOS/Knulli use the standard Linux BTN_* identities:
 *   physical A=304 B=305 X=307 Y=308
 *
 * SDL already corrects this for ordinary OpenMW controller menus. This
 * helper bypasses SDL and reads evdev directly, so normalize standard
 * muOS/Knulli events back to the helper's existing logical identities.
 */
static bool tsp_standard_face_layout = false;

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

static int dpad_x = 0;
static int dpad_y = 0;

/* TSP_NO_STICKCLICK_MODES_051_V54 */
static int left_x = 0;
static int left_y = 0;
static int left_x_center = 0;
static int left_y_center = 0;
static int left_x_threshold = 8000;
static int left_y_threshold = 8000;

static control_mode mode = MODE_GAME;
static charset_mode charset = CHARSET_LETTERS;
static bool uppercase = true;
static size_t text_index = 0;

/* X toggles to this compact numbers / punctuation / space bank. */
static const char letters[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZ";
static const char alt_chars[] = " 0123456789!?.,'-_/():;@#$%&+";

static void handle_signal(int sig)
{
    (void)sig;
    running = 0;
}

static const char *mode_name(control_mode value)
{
    return value == MODE_TEXT ? "TEXT" : "GAME";
}

static void tsp_detect_face_layout(void)
{
    const char *override = getenv("OPENMW_TSP_FACE_LAYOUT");
    const char *reason = "stock/crossmix";

    if (override != NULL && strcmp(override, "standard") == 0)
    {
        tsp_standard_face_layout = true;
        reason = "OPENMW_TSP_FACE_LAYOUT=standard";
    }
    else if (override != NULL && strcmp(override, "legacy") == 0)
    {
        tsp_standard_face_layout = false;
        reason = "OPENMW_TSP_FACE_LAYOUT=legacy";
    }
    else if (access("/opt/muos", F_OK) == 0)
    {
        tsp_standard_face_layout = true;
        reason = "muOS";
    }
    else if (access("/userdata", F_OK) == 0)
    {
        tsp_standard_face_layout = true;
        reason = "Knulli/Batocera";
    }

    if (log_file != NULL)
    {
        fprintf(
            log_file,
            "TSP_FACE_LAYOUT_051_V67 layout=%s reason=%s "
            "logical-A=%d logical-B=%d logical-X=%d logical-Y=%d\n",
            tsp_standard_face_layout ? "standard-normalized" : "legacy",
            reason,
            KEY_TSP_A,
            KEY_TSP_B,
            KEY_TSP_X,
            KEY_TSP_Y);
        fflush(log_file);
    }
}

static unsigned int tsp_normalize_face_key(unsigned int code)
{
    if (!tsp_standard_face_layout)
        return code;

    switch (code)
    {
        case BTN_A:
            return KEY_TSP_A;
        case BTN_B:
            return KEY_TSP_B;
        case BTN_X:
            return KEY_TSP_X;
        case BTN_Y:
            return KEY_TSP_Y;
        default:
            return code;
    }
}

static const char *key_name(unsigned int code)
{
    switch (code) {
        case KEY_TSP_A: return "A";
        case KEY_TSP_B: return "B";
        case KEY_TSP_X: return "X";
        case KEY_TSP_Y: return "Y";
        case KEY_TSP_L1: return "L1";
        case KEY_TSP_R1: return "R1";
        case KEY_TSP_L3: return "L3";
        case KEY_TSP_R3: return "R3";
        case KEY_TSP_START: return "START";
        case KEY_TSP_SELECT: return "SELECT";
        case KEY_TSP_MENU: return "MENU";
        default: return "OTHER";
    }
}

static const char *abs_name(unsigned int code)
{
    switch (code) {
        case ABS_TSP_DPAD_X: return "DPAD_X";
        case ABS_TSP_DPAD_Y: return "DPAD_Y";
        case ABS_TSP_LEFT_X: return "LEFT_X";
        case ABS_TSP_LEFT_Y: return "LEFT_Y";
        default: return "OTHER";
    }
}

static void log_line(const char *message)
{
    if (log_file != NULL) {
        fprintf(log_file, "%s\n", message);
        fflush(log_file);
    }
}

static void log_raw_key(const struct input_event *event)
{
    if (log_file != NULL) {
        fprintf(
            log_file,
            "RAW KEY name=%s code=%u value=%d mode=%d(%s) grabbed=%d\n",
            key_name(event->code),
            event->code,
            event->value,
            (int)mode,
            mode_name(mode),
            grabbed ? 1 : 0);
        fflush(log_file);
    }
}

static void log_raw_abs(const struct input_event *event)
{
    if (log_file != NULL) {
        fprintf(
            log_file,
            "RAW ABS name=%s code=%u value=%d mode=%d(%s) grabbed=%d\n",
            abs_name(event->code),
            event->code,
            event->value,
            (int)mode,
            mode_name(mode),
            grabbed ? 1 : 0);
        fflush(log_file);
    }
}

static void emit_event(int type, int code, int value)
{
    struct input_event event;
    memset(&event, 0, sizeof(event));
    gettimeofday(&event.time, NULL);
    event.type = (uint16_t)type;
    event.code = (uint16_t)code;
    event.value = value;

    if (write(uinput_fd, &event, sizeof(event)) < 0 && errno != EAGAIN)
        perror("write uinput event");
}

static void sync_events(void)
{
    emit_event(EV_SYN, SYN_REPORT, 0);
}

static void tap_key(int keycode)
{
    emit_event(EV_KEY, keycode, 1);
    sync_events();
    emit_event(EV_KEY, keycode, 0);
    sync_events();
}

static void tap_shifted_key(int keycode)
{
    emit_event(EV_KEY, KEY_LEFTSHIFT, 1);
    emit_event(EV_KEY, keycode, 1);
    sync_events();
    emit_event(EV_KEY, keycode, 0);
    emit_event(EV_KEY, KEY_LEFTSHIFT, 0);
    sync_events();
}

/*
 * TSP_PAD_DISCOVERY_V66
 *
 * The helper used to require an evdev device named exactly "TRIMUI Player1".
 * That is what the stock/CrossMix kernel calls the pad. Knulli and other
 * batocera-derived images expose the SAME physical device under a different
 * name, so find_controller() returned -1, the helper exited during startup,
 * and the launcher treated that as fatal -- a black screen with no engine.
 *
 * A name is not a stable identifier for a piece of hardware. The set of
 * buttons the device reports is. This helper only ever reads a fixed set of
 * key codes, so the correct device is the one that reports them.
 *
 * Preference order, highest first:
 *   1. $OPENMW_TSP_PAD -- an explicit /dev/input/eventN path, or an exact name.
 *   2. a name in TSP_PAD_NAMES (this is what stock/CrossMix/TSPS hit, so their
 *      selection is bit-for-bit what it was before this change).
 *   3. the device reporting the most of the buttons this helper uses, provided
 *      it reports at least TSP_PAD_MIN_KEYS of them.
 *
 * Every device scanned is written to the helper log with its name and score,
 * so the next image that breaks this explains itself instead of dying mute.
 */
#define TSP_PAD_MIN_KEYS 8
#define TSP_UINPUT_NAME "TSP OpenMW 0.51 Automatic Text Input"

static const char *const TSP_PAD_NAMES[] = {
    DEVICE_NAME,
    "TRIMUI Player 1",
    "trimui-joypad",
    "retrogame_joypad",
    "Trimui Smart Pro Gamepad",
    NULL
};

static const int TSP_PAD_KEYS[] = {
    KEY_TSP_A, KEY_TSP_B, KEY_TSP_X, KEY_TSP_Y,
    KEY_TSP_L1, KEY_TSP_R1, KEY_TSP_L3, KEY_TSP_R3,
    KEY_TSP_START, KEY_TSP_SELECT, KEY_TSP_MENU
};
#define TSP_PAD_KEY_COUNT ((int)(sizeof(TSP_PAD_KEYS) / sizeof(TSP_PAD_KEYS[0])))

#define TSP_BITS_PER_LONG (8 * (int)sizeof(unsigned long))
#define TSP_NLONGS(x) (((x) + TSP_BITS_PER_LONG - 1) / TSP_BITS_PER_LONG)

static int tsp_bit_set(const unsigned long *bits, int bit)
{
    return (int)((bits[bit / TSP_BITS_PER_LONG] >> (bit % TSP_BITS_PER_LONG)) & 1UL);
}

/* How many of the buttons we actually use does this device report? */
static int tsp_pad_score(int fd)
{
    unsigned long keybits[TSP_NLONGS(KEY_MAX + 1)];

    memset(keybits, 0, sizeof(keybits));
    if (ioctl(fd, EVIOCGBIT(EV_KEY, sizeof(keybits)), keybits) < 0)
        return 0;

    int score = 0;
    for (int i = 0; i < TSP_PAD_KEY_COUNT; i++) {
        if (TSP_PAD_KEYS[i] >= 0 && TSP_PAD_KEYS[i] <= KEY_MAX &&
            tsp_bit_set(keybits, TSP_PAD_KEYS[i]))
            score++;
    }
    return score;
}

/* Pure ranking decision. Negative means "never use this device". */
static int tsp_pad_rank(const char *name, int score, const char *want)
{
    if (name == NULL)
        name = "";
    if (strcmp(name, TSP_UINPUT_NAME) == 0)
        return -1;
    if (want != NULL && want[0] != '\0' && strcmp(name, want) == 0)
        return 2000 + score;
    for (int i = 0; TSP_PAD_NAMES[i] != NULL; i++) {
        if (strcmp(name, TSP_PAD_NAMES[i]) == 0)
            return 1000 + score;
    }
    if (score >= TSP_PAD_MIN_KEYS)
        return score;
    return -1;
}

static int find_controller(void)
{
    char path[64];
    char name[256];
    const char *want = getenv("OPENMW_TSP_PAD");

    /* An explicit device path short-circuits the whole scan. */
    if (want != NULL && strncmp(want, "/dev/input/", 11) == 0) {
        int fd = open(want, O_RDONLY | O_NONBLOCK);
        if (fd >= 0) {
            if (log_file != NULL) {
                fprintf(log_file, "Controller: %s (OPENMW_TSP_PAD)\n", want);
                fflush(log_file);
            }
            return fd;
        }
        if (log_file != NULL) {
            fprintf(log_file, "OPENMW_TSP_PAD=%s could not be opened: %s\n",
                    want, strerror(errno));
            fflush(log_file);
        }
    }

    int best_fd = -1;
    int best_rank = -1;
    char best_path[64];
    char best_name[256];

    best_path[0] = '\0';
    best_name[0] = '\0';

    for (int index = 0; index < 64; index++) {
        snprintf(path, sizeof(path), "/dev/input/event%d", index);
        int fd = open(path, O_RDONLY | O_NONBLOCK);
        if (fd < 0)
            continue;

        memset(name, 0, sizeof(name));
        if (ioctl(fd, EVIOCGNAME(sizeof(name)), name) < 0)
            name[0] = '\0';

        int score = tsp_pad_score(fd);
        int rank = tsp_pad_rank(name, score, want);

        if (log_file != NULL) {
            fprintf(log_file, "  scan %s name=\"%s\" buttons=%d/%d rank=%d\n",
                    path, name, score, TSP_PAD_KEY_COUNT, rank);
            fflush(log_file);
        }

        if (rank > best_rank) {
            if (best_fd >= 0)
                close(best_fd);
            best_fd = fd;
            best_rank = rank;
            snprintf(best_path, sizeof(best_path), "%s", path);
            snprintf(best_name, sizeof(best_name), "%s", name);
            continue;
        }
        close(fd);
    }

    if (best_fd >= 0 && best_rank >= 0) {
        if (log_file != NULL) {
            fprintf(log_file, "Controller: %s | %s (rank %d)\n",
                    best_path, best_name, best_rank);
            fflush(log_file);
        }
        return best_fd;
    }

    if (best_fd >= 0)
        close(best_fd);
    return -1;
}


static int create_uinput_device(void)
{
    int fd = open("/dev/uinput", O_WRONLY | O_NONBLOCK);
    if (fd < 0) {
        perror("open /dev/uinput");
        return -1;
    }

    if (ioctl(fd, UI_SET_EVBIT, EV_KEY) < 0) {
        perror("configure uinput");
        close(fd);
        return -1;
    }

    for (int key = KEY_ESC; key <= KEY_MICMUTE; key++)
        ioctl(fd, UI_SET_KEYBIT, key);

    struct uinput_setup setup;
    memset(&setup, 0, sizeof(setup));
    snprintf(
        setup.name,
        UINPUT_MAX_NAME_SIZE,
        "TSP OpenMW 0.51 Automatic Text Input");
    setup.id.bustype = BUS_USB;
    setup.id.vendor = 0x1209;
    setup.id.product = 0x0512;
    setup.id.version = 1;

    if (ioctl(fd, UI_DEV_SETUP, &setup) < 0) {
        perror("UI_DEV_SETUP");
        close(fd);
        return -1;
    }

    if (ioctl(fd, UI_DEV_CREATE) < 0) {
        perror("UI_DEV_CREATE");
        close(fd);
        return -1;
    }

    usleep(250000);
    return fd;
}

static void set_grab(bool enable)
{
    if (controller_fd < 0 || grabbed == enable)
        return;

    if (ioctl(controller_fd, EVIOCGRAB, enable ? 1 : 0) < 0) {
        if (log_file != NULL) {
            fprintf(
                log_file,
                "EVIOCGRAB(%d) failed: %s\n",
                enable ? 1 : 0,
                strerror(errno));
            fflush(log_file);
        }
        return;
    }

    grabbed = enable;

    if (log_file != NULL) {
        fprintf(
            log_file,
            "CONTROLLER GRAB changed: grabbed=%d mode=%d(%s)\n",
            grabbed ? 1 : 0,
            (int)mode,
            mode_name(mode));
        fflush(log_file);
    }
}

static char selected_character(void)
{
    if (charset == CHARSET_ALT)
        return alt_chars[text_index % (sizeof(alt_chars) - 1)];

    char value = letters[text_index % (sizeof(letters) - 1)];
    if (!uppercase)
        value = (char)(value - 'A' + 'a');
    return value;
}

static const char *charset_name(void)
{
    return charset == CHARSET_ALT ? "ALT" : (uppercase ? "ABC" : "abc");
}

/* TSP_TEXT_INJECT_V64 -- hand the character to OpenMW directly.
 * A synthetic uinput keystroke only becomes a character if SDL can
 * translate it through the kernel console keymap, which some TrimUI OS
 * images do not provide: the keystroke is emitted correctly and nothing
 * is typed. Appending here is OS-independent. Append, not overwrite, so
 * fast presses are not lost between engine frames. */
static void tsp_queue_injected_char(char value)
{
    FILE *file = fopen(TEXT_INJECT_FILE, "a");
    if (file != NULL) {
        fputc(value, file);
        fclose(file);
    }
    if (log_file != NULL) {
        fprintf(log_file, "TSP_TEXT_INJECT_V64 queued=%d\n", (int)value);
        fflush(log_file);
    }
}

static void publish_selected_character(void)
{
    char value = selected_character();

    FILE *file = fopen(TEXT_CHAR_TMP, "w");
    if (file != NULL) {
        if (value == ' ')
            fprintf(file, "[ SPACE ]");
        else
            fprintf(file, "[ %c ]", value);
        fclose(file);
        rename(TEXT_CHAR_TMP, TEXT_CHAR_FILE);
    }

    if (log_file != NULL) {
        if (value == ' ')
            fprintf(log_file, "TEXT_CHAR=SPACE MODE=%s INDEX=%zu\n",
                    charset_name(), text_index);
        else
            fprintf(log_file, "TEXT_CHAR=%c MODE=%s INDEX=%zu\n",
                    value, charset_name(), text_index);
        fflush(log_file);
    }
}

static void set_mode(control_mode new_mode)
{
    if (new_mode == mode)
        return;

    mode = new_mode;

    if (mode == MODE_TEXT) {
        charset = CHARSET_LETTERS;
        uppercase = true;
        text_index = 0;
        set_grab(true);
        publish_selected_character();
        log_line("MODE=TEXT (automatic OpenMW text focus)");
    } else {
        set_grab(false);
        unlink(TEXT_CHAR_FILE);
        unlink(TEXT_CHAR_TMP);
        log_line("MODE=GAME (native OpenMW controller passthrough)");
    }
}

static bool openmw_text_active(void)
{
    return access(TEXT_ACTIVE_FLAG, F_OK) == 0;
}

static bool openmw_text_required(void)
{
    return access(TEXT_REQUIRED_FLAG, F_OK) == 0;
}

/* TSP_EXPLICIT_UI_STATE_051_V58 */
static bool openmw_mouse_active(void);

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
                fputs("1\n", file);
                fclose(file);
            } else if (log_file != NULL) {
                fprintf(log_file,
                        "TSP_TEXT_EXIT_CONTROLLER_051_V55 could not write %s: %s\n",
                        TEXT_OFF_FLAG, strerror(errno));
                fflush(log_file);
            }
        }
    } else {
        unlink(TEXT_OFF_FLAG);
    }

    if (changed && log_file != NULL) {
        fprintf(log_file,
                "TSP_TEXT_EXIT_CONTROLLER_051_V55 textSuppressed=%d\n",
                suppressed ? 1 : 0);
        fflush(log_file);
    }
}

static void sync_automatic_mode(void)
{
    const bool active = openmw_text_active();
    const bool required = openmw_text_required();
    const bool force_controller = access(FORCE_CONTROLLER_FLAG, F_OK) == 0;
    const bool mouse_active = openmw_mouse_active();

    // TSP_NAME_TEXT_LOCK_051_V67
    // The first-name screen must remain owned by TEXT until OpenMW accepts
    // the name. Do not permit B/MENU/left-stick handoff to strand the dialog.
    if (active && required)
    {
        menu_to_text_pending = false;
        menu_release_seen = false;
        left_stick_mouse_armed = true;

        unlink(MOUSE_MODE_FLAG);
        unlink(MOUSE_REQUEST_FLAG);
        set_text_suppressed(false);

        if (mode != MODE_TEXT)
            set_mode(MODE_TEXT);

        return;
    }

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
}

/* TSP_NO_STICKCLICK_MODES_051_V54 */
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
            "TSP_NO_STICKCLICK_MODES_051_V54 left-stick center=%d,%d threshold=%d,%d\n",
            left_x_center, left_y_center, left_x_threshold, left_y_threshold);
        fflush(log_file);
    }
}

static void tsp_request_mouse_mode(void)
{
    log_line("TSP_EXPLICIT_UI_STATE_051_V58 LEFT STICK: TEXT -> MOUSE request.");

    menu_to_text_pending = false;
    menu_release_seen = false;
    left_stick_mouse_armed = false;
    set_text_suppressed(true);

    FILE *request = fopen(MOUSE_REQUEST_FLAG, "w");
    if (request != NULL) {
        fputs("1\n", request);
        fclose(request);
    } else if (log_file != NULL) {
        fprintf(log_file, "LEFT STICK: could not write %s: %s\n",
                MOUSE_REQUEST_FLAG, strerror(errno));
        fflush(log_file);
    }

    unlink(MOUSE_MODE_FLAG);
    set_mode(MODE_GAME);
}

static void change_text_index(int direction)
{
    const size_t length = charset == CHARSET_ALT
        ? sizeof(alt_chars) - 1
        : sizeof(letters) - 1;

    if (direction > 0)
        text_index = (text_index + 1) % length;
    else
        text_index = (text_index + length - 1) % length;

    publish_selected_character();
}

static void toggle_alt_charset(void)
{
    charset = charset == CHARSET_LETTERS
        ? CHARSET_ALT
        : CHARSET_LETTERS;

    text_index = 0;
    publish_selected_character();
}

static void toggle_case_or_return_to_letters(void)
{
    if (charset == CHARSET_ALT) {
        charset = CHARSET_LETTERS;
        text_index = 0;
    } else {
        uppercase = !uppercase;
    }

    publish_selected_character();
}

static int letter_keycode(char lower)
{
    /*
     * Linux input KEY_* values follow physical keyboard scan-code order, not
     * alphabetical order. KEY_A + n therefore produces A,S,D,F,... rather
     * than A,B,C,D,... . Map every letter explicitly.
     */
    switch (lower) {
        case 'a': return KEY_A;
        case 'b': return KEY_B;
        case 'c': return KEY_C;
        case 'd': return KEY_D;
        case 'e': return KEY_E;
        case 'f': return KEY_F;
        case 'g': return KEY_G;
        case 'h': return KEY_H;
        case 'i': return KEY_I;
        case 'j': return KEY_J;
        case 'k': return KEY_K;
        case 'l': return KEY_L;
        case 'm': return KEY_M;
        case 'n': return KEY_N;
        case 'o': return KEY_O;
        case 'p': return KEY_P;
        case 'q': return KEY_Q;
        case 'r': return KEY_R;
        case 's': return KEY_S;
        case 't': return KEY_T;
        case 'u': return KEY_U;
        case 'v': return KEY_V;
        case 'w': return KEY_W;
        case 'x': return KEY_X;
        case 'y': return KEY_Y;
        case 'z': return KEY_Z;
        default: return -1;
    }
}

static void type_character(char ch)
{
    if (ch >= 'a' && ch <= 'z') {
        int keycode = letter_keycode(ch);
        if (keycode >= 0)
            tap_key(keycode);
        return;
    }

    if (ch >= 'A' && ch <= 'Z') {
        int keycode = letter_keycode((char)(ch - 'A' + 'a'));
        if (keycode >= 0)
            tap_shifted_key(keycode);
        return;
    }

    if (ch >= '1' && ch <= '9') {
        tap_key(KEY_1 + (ch - '1'));
        return;
    }

    switch (ch) {
        case '0': tap_key(KEY_0); break;
        case ' ': tap_key(KEY_SPACE); break;
        case '!': tap_shifted_key(KEY_1); break;
        case '?': tap_shifted_key(KEY_SLASH); break;
        case '.': tap_key(KEY_DOT); break;
        case ',': tap_key(KEY_COMMA); break;
        case '\'': tap_key(KEY_APOSTROPHE); break;
        case '-': tap_key(KEY_MINUS); break;
        case '_': tap_shifted_key(KEY_MINUS); break;
        case '/': tap_key(KEY_SLASH); break;
        case '(': tap_shifted_key(KEY_9); break;
        case ')': tap_shifted_key(KEY_0); break;
        case ':': tap_shifted_key(KEY_SEMICOLON); break;
        case ';': tap_key(KEY_SEMICOLON); break;
        case '@': tap_shifted_key(KEY_2); break;
        case '#': tap_shifted_key(KEY_3); break;
        case '$': tap_shifted_key(KEY_4); break;
        case '%': tap_shifted_key(KEY_5); break;
        case '&': tap_shifted_key(KEY_7); break;
        case '+': tap_shifted_key(KEY_EQUAL); break;
        default: break;
    }
}

/* TSP_TEXT_REMAP_051_V40 -- MENU: hand the pad to OpenMW, keep text entry open. */
static void tsp_enter_pointing_mode(void)
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

/* TSP_TEXT_REMAP_051_V40 -- MENU again: take the pad back for typing. */
static void tsp_leave_pointing_mode(void)
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

static void leave_text_mode(void)
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
        fputs("1\n", force);
        fclose(force);
    } else if (log_file != NULL) {
        fprintf(log_file, "B: could not write %s: %s\n",
                FORCE_CONTROLLER_FLAG, strerror(errno));
        fflush(log_file);
    }

    set_mode(MODE_GAME);
    tap_key(KEY_ESC);
}

static void handle_key_event(const struct input_event *event)
{
    // TSP_FACE_LAYOUT_051_V67
    // Normalize only the four face buttons. Start/Select/Menu, shoulders,
    // D-pad and axes keep their original raw identities.
    const unsigned int raw_code = event->code;
    struct input_event logical_event = *event;
    logical_event.code = tsp_normalize_face_key(raw_code);
    event = &logical_event;

    const bool pressed = event->value != 0;
    log_raw_key(event);

    if (raw_code != event->code && log_file != NULL)
    {
        fprintf(
            log_file,
            "TSP_FACE_LAYOUT_051_V67 raw=%u normalized=%u name=%s\n",
            raw_code,
            event->code,
            key_name(event->code));
        fflush(log_file);
    }

    if (mode != MODE_TEXT) {
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
    }

    if (!pressed)
        return;

    /*
     * TSP_TEXT_REMAP_051_V40 -- an if/else chain, not a switch: TSP_TEXT_CANCEL_KEY
     * is a #define that may alias KEY_TSP_B, and two case labels with the same
     * value will not compile.
     */
    if (event->code == KEY_TSP_A) {
        /* TSP_TEXT_INJECT_V64 */
        tsp_queue_injected_char(selected_character());
        /* TSP_TEXT_INJECT_V65 -- the uinput keystroke was removed here: the
         * engine injects this directly now, and emitting both typed
         * every character twice wherever SDL text synthesis works. */
    } else if (event->code == TSP_TEXT_CANCEL_KEY) {
        if (openmw_text_required())
        {
            // First-name entry cannot be cancelled. Give B a useful action
            // instead: delete the previous character.
            tsp_queue_injected_char((char)8);
            log_line("TSP_NAME_TEXT_LOCK_051_V67 B=backspace; cancel blocked.");
        }
        else
            leave_text_mode();
    } else if (event->code == KEY_TSP_X) {
        toggle_alt_charset();
    } else if (event->code == KEY_TSP_Y) {
        toggle_case_or_return_to_letters();
    } else if (event->code == KEY_TSP_START) {
        /* TSP_TEXT_INJECT_V64 */
        tsp_queue_injected_char((char)13);
        /* TSP_TEXT_INJECT_V65 -- the uinput keystroke was removed here: the
         * engine injects this directly now, and emitting both typed
         * every character twice wherever SDL text synthesis works. */
    } else if (event->code == KEY_TSP_MENU) {
        if (openmw_text_required())
            log_line("TSP_NAME_TEXT_LOCK_051_V67 MENU ignored; TEXT required.");
        else
            tsp_enter_pointing_mode();
#if TSP_TEXT_CANCEL_KEY != KEY_TSP_B
    } else if (event->code == KEY_TSP_B) {
        /* TSP_TEXT_INJECT_V64 */
        tsp_queue_injected_char((char)8);
        /* TSP_TEXT_INJECT_V65 -- the uinput keystroke was removed here: the
         * engine injects this directly now, and emitting both typed
         * every character twice wherever SDL text synthesis works. */
#endif
    }
}

static void handle_abs_event(const struct input_event *event)
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
            // TSP_NAME_TEXT_LOCK_051_V67
            // Do not allow first-name entry to transition TEXT -> MOUSE.
            if (openmw_text_required())
            {
                left_stick_mouse_armed = true;
                return;
            }

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
                /* TSP_TEXT_INJECT_V64 */
                tsp_queue_injected_char((char)8);
                /* TSP_TEXT_INJECT_V65 -- the uinput keystroke was removed here: the
                 * engine injects this directly now, and emitting both typed
                 * every character twice wherever SDL text synthesis works. */
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
}

int main(int argc, char **argv)
{
    const char *log_path =
        argc > 1 ? argv[1] : "/tmp/tsp_openmw_controls_051.log";

    log_file = fopen(log_path, "w");
    if (log_file == NULL)
        perror("open log");

    signal(SIGINT, handle_signal);
    signal(SIGTERM, handle_signal);
    signal(SIGHUP, handle_signal);

    // TSP_FACE_LAYOUT_051_V67
    tsp_detect_face_layout();

    /*
     * Clear crash leftovers before OpenMW starts. OpenMW will recreate the
     * active flag only when a real text-entry session begins.
     */
    unlink(TEXT_ACTIVE_FLAG);
    unlink(TEXT_CHAR_FILE);
    unlink(TEXT_CHAR_TMP);
    unlink(MOUSE_MODE_FLAG); /* TSP_TEXT_REMAP_051_V40 */
    /* TSP_NO_STICKCLICK_MODES_051_V54 */
    unlink(MOUSE_REQUEST_FLAG);
    unlink(MOUSE_ACTIVE_FLAG);
    /* TSP_TEXT_EXIT_CONTROLLER_051_V55 */
    unlink(TEXT_OFF_FLAG);
    /* TSP_EXPLICIT_UI_STATE_051_V58 */
    unlink(FORCE_CONTROLLER_FLAG);

    controller_fd = find_controller();
    if (controller_fd < 0) {
        log_line("ERROR: no usable gamepad found. Scanned devices are listed above.");
        log_line("       Set OPENMW_TSP_PAD to a /dev/input/eventN path or an exact device name to override.");
        if (log_file != NULL)
            fclose(log_file);
        return 1;
    }

    /* TSP_NO_STICKCLICK_MODES_051_V54 */
    init_left_stick_geometry();

    uinput_fd = create_uinput_device();
    if (uinput_fd < 0) {
        log_line("ERROR: Could not create virtual keyboard.");
        close(controller_fd);
        if (log_file != NULL)
            fclose(log_file);
        return 1;
    }

    log_line("TSP OpenMW 0.51 automatic text helper V5 started.");
    log_line("GAME: helper does not grab or remap the controller.");
    log_line("TEXT mode activates only while OpenMW reports active SDL text input.");
    log_line("Up/Down: previous/next character.");
    log_line("Left/Right: move backward/forward through typed text.");
    log_line("A: type selected character; Left: backspace/delete.");
    log_line("X: Letters <-> Numbers/Alt/Space.");
    log_line("Y: uppercase/lowercase; from Alt return to Letters.");
    log_line("Start: Enter/finish text; B: leave/cancel text mode.");
    log_line("Menu: TEXT -> CONTROLLER; CONTROLLER -> TEXT when text entry is active.");
    log_line("Left stick: TEXT/CONTROLLER -> MOUSE in cursor-capable menus.");
    log_line("Menu from MOUSE: returns to CONTROLLER before TEXT.");
    log_line("B from TEXT: cancels text and immediately restores controller D-pad.");
    log_line("TSP_TEXT_REMAP_051_V40 active.");
    log_line("TSP_NO_STICKCLICK_MODES_051_V54 active.");
    log_line("TSP_TEXT_EXIT_CONTROLLER_051_V55 active.");
    log_line("TSP_B_EXIT_MENU_HANDOFF_051_V57 active.");
    log_line("TSP_EXPLICIT_UI_STATE_051_V58 active.");
    log_line("TSP_FACE_LAYOUT_051_V67 active.");
    log_line("TSP_NAME_TEXT_LOCK_051_V67 active.");
    log_line("Menu cycle in text UI: MOUSE -> TEXT -> CONTROLLER -> TEXT.");
    log_line("B from TEXT: force CONTROLLER until SDL text focus ends.");
    log_line("Corrected physical codes: Start=315 Select=314 Menu=316.");

    while (running) {
        sync_automatic_mode();

        struct pollfd poll_fd;
        poll_fd.fd = controller_fd;
        poll_fd.events = POLLIN;
        poll_fd.revents = 0;

        const int result = poll(&poll_fd, 1, TICK_MS);

        if (result > 0 && (poll_fd.revents & POLLIN)) {
            struct input_event events[32];
            const ssize_t count =
                read(controller_fd, events, sizeof(events));

            if (count > 0) {
                const size_t event_count =
                    (size_t)count / sizeof(struct input_event);

                for (size_t index = 0; index < event_count; index++) {
                    if (events[index].type == EV_KEY)
                        handle_key_event(&events[index]);
                    else if (events[index].type == EV_ABS)
                        handle_abs_event(&events[index]);
                }
            }
        } else if (result < 0 && errno != EINTR) {
            if (log_file != NULL) {
                fprintf(log_file, "poll failed: %s\n", strerror(errno));
                fflush(log_file);
            }
            break;
        }
    }

    set_mode(MODE_GAME);
    unlink(TEXT_ACTIVE_FLAG);
    unlink(TEXT_CHAR_FILE);
    unlink(TEXT_CHAR_TMP);
    unlink(MOUSE_MODE_FLAG); /* TSP_TEXT_REMAP_051_V40 */
    /* TSP_NO_STICKCLICK_MODES_051_V54 */
    unlink(MOUSE_REQUEST_FLAG);
    unlink(MOUSE_ACTIVE_FLAG);
    /* TSP_TEXT_EXIT_CONTROLLER_051_V55 */
    unlink(TEXT_OFF_FLAG);
    /* TSP_EXPLICIT_UI_STATE_051_V58 */
    unlink(FORCE_CONTROLLER_FLAG);

    if (uinput_fd >= 0) {
        ioctl(uinput_fd, UI_DEV_DESTROY);
        close(uinput_fd);
    }

    if (controller_fd >= 0)
        close(controller_fd);

    log_line("TSP OpenMW 0.51 automatic text helper V5 stopped.");

    if (log_file != NULL)
        fclose(log_file);

    return 0;
}
