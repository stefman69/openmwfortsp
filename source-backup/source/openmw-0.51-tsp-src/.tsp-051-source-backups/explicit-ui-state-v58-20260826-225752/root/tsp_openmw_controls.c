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

static int find_controller(void)
{
    char path[64];
    char name[256];

    for (int index = 0; index < 64; index++) {
        snprintf(path, sizeof(path), "/dev/input/event%d", index);
        int fd = open(path, O_RDONLY | O_NONBLOCK);
        if (fd < 0)
            continue;

        memset(name, 0, sizeof(name));
        if (ioctl(fd, EVIOCGNAME(sizeof(name)), name) >= 0 &&
            strcmp(name, DEVICE_NAME) == 0) {
            if (log_file != NULL) {
                fprintf(log_file, "Controller: %s | %s\n", path, name);
                fflush(log_file);
            }
            return fd;
        }
        close(fd);
    }

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
    log_line("TSP_NO_STICKCLICK_MODES_051_V54 LEFT STICK: TEXT -> MOUSE.");
    // TSP_TEXT_EXIT_CONTROLLER_051_V55
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

    FILE *yield = fopen(MOUSE_MODE_FLAG, "w");
    if (yield != NULL) {
        fputs("1\n", yield);
        fclose(yield);
    }

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
    log_line("MENU: POINTING - pad yielded to OpenMW, text entry still open.");

    // TSP_TEXT_EXIT_CONTROLLER_051_V55
    // This is CONTROLLER suppression now; publish it so OpenMW permits D-pad
    // navigation even while the EditBox continues to own SDL text focus.
    set_text_suppressed(true);

    FILE *file = fopen(MOUSE_MODE_FLAG, "w");
    if (file != NULL) {
        fputs("1\n", file);
        fclose(file);
    } else if (log_file != NULL) {
        fprintf(log_file, "MENU: could not write %s: %s\n",
                MOUSE_MODE_FLAG, strerror(errno));
        fflush(log_file);
    }

    /* Releases EVIOCGRAB. Deliberately does NOT send Escape - that is cancel. */
    set_mode(MODE_GAME);
}

/* TSP_TEXT_REMAP_051_V40 -- MENU again: take the pad back for typing. */
static void tsp_leave_pointing_mode(void)
{
    log_line("MENU: TYPING - pad reclaimed by helper.");
    unlink(MOUSE_MODE_FLAG);
    // TSP_TEXT_EXIT_CONTROLLER_051_V55
    set_text_suppressed(false);
    sync_automatic_mode();
}

static void leave_text_mode(void)
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
}

static void handle_key_event(const struct input_event *event)
{
    const bool pressed = event->value != 0;
    log_raw_key(event);

    if (mode != MODE_TEXT) {
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
    }

    if (!pressed)
        return;

    /*
     * TSP_TEXT_REMAP_051_V40 -- an if/else chain, not a switch: TSP_TEXT_CANCEL_KEY
     * is a #define that may alias KEY_TSP_B, and two case labels with the same
     * value will not compile.
     */
    if (event->code == KEY_TSP_A) {
        type_character(selected_character());
    } else if (event->code == TSP_TEXT_CANCEL_KEY) {
        leave_text_mode();
    } else if (event->code == KEY_TSP_X) {
        toggle_alt_charset();
    } else if (event->code == KEY_TSP_Y) {
        toggle_case_or_return_to_letters();
    } else if (event->code == KEY_TSP_START) {
        tap_key(KEY_ENTER);
    } else if (event->code == KEY_TSP_MENU) {
        tsp_enter_pointing_mode();
#if TSP_TEXT_CANCEL_KEY != KEY_TSP_B
    } else if (event->code == KEY_TSP_B) {
        tap_key(KEY_BACKSPACE);
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

    controller_fd = find_controller();
    if (controller_fd < 0) {
        log_line("ERROR: TRIMUI Player1 was not found.");
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
