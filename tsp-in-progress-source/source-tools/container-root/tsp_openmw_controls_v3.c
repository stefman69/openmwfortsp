#define _GNU_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <linux/input.h>
#include <linux/uinput.h>
#include <math.h>
#include <poll.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/time.h>
#include <time.h>
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
#define KEY_TSP_START   314
#define KEY_TSP_SELECT  315

#define ABS_TSP_LX      0
#define ABS_TSP_LY      1
#define ABS_TSP_L2      2
#define ABS_TSP_RX      3
#define ABS_TSP_RY      4
#define ABS_TSP_R2      5
#define ABS_TSP_DPAD_X  16
#define ABS_TSP_DPAD_Y  17

#define TRIGGER_THRESHOLD 128
#define STICK_DEADZONE 4000
#define STICK_MAX 32760
#define TICK_MS 10

typedef enum {
    MODE_GAME = 0,
    MODE_MOUSE = 1,
    MODE_TEXT = 2
} control_mode;

static volatile sig_atomic_t running = 1;
static int controller_fd = -1;
static int uinput_fd = -1;
static FILE *log_file = NULL;
static bool grabbed = false;

static int lx = 0;
static int ly = 0;
static int rx = 0;
static int ry = 0;
static int dpad_x = 0;
static int dpad_y = 0;
static bool r2_down = false;

static control_mode mode = MODE_GAME;
static const char text_charset[] =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz 0123456789!?";
static size_t text_index = 0;

static void handle_signal(int sig)
{
    (void)sig;
    running = 0;
}

static const char *mode_name(control_mode value)
{
    switch (value) {
        case MODE_GAME:
            return "GAME";
        case MODE_MOUSE:
            return "MOUSE";
        case MODE_TEXT:
            return "TEXT";
        default:
            return "UNKNOWN";
    }
}

static const char *key_name(unsigned int code)
{
    switch (code) {
        case KEY_TSP_A:
            return "A";
        case KEY_TSP_B:
            return "B";
        case KEY_TSP_X:
            return "X";
        case KEY_TSP_Y:
            return "Y";
        case KEY_TSP_L1:
            return "L1";
        case KEY_TSP_R1:
            return "R1";
        case KEY_TSP_L3:
            return "L3";
        case KEY_TSP_R3:
            return "R3";
        case KEY_TSP_START:
            return "START";
        case KEY_TSP_SELECT:
            return "SELECT";
        default:
            return "OTHER";
    }
}

static const char *abs_name(unsigned int code)
{
    switch (code) {
        case ABS_TSP_L2:
            return "L2";
        case ABS_TSP_R2:
            return "R2";
        case ABS_TSP_DPAD_X:
            return "DPAD_X";
        case ABS_TSP_DPAD_Y:
            return "DPAD_Y";
        default:
            return "OTHER";
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
            grabbed ? 1 : 0
        );
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
            grabbed ? 1 : 0
        );
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

    if (write(uinput_fd, &event, sizeof(event)) < 0 && errno != EAGAIN) {
        perror("write uinput event");
    }
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

static void set_mouse_button(int button, int pressed)
{
    emit_event(EV_KEY, button, pressed ? 1 : 0);
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

static void type_character(char ch)
{
    if (ch >= 'a' && ch <= 'z') {
        tap_key(KEY_A + (ch - 'a'));
        return;
    }

    if (ch >= 'A' && ch <= 'Z') {
        tap_shifted_key(KEY_A + (ch - 'A'));
        return;
    }

    if (ch >= '1' && ch <= '9') {
        tap_key(KEY_1 + (ch - '1'));
        return;
    }

    switch (ch) {
        case '0':
            tap_key(KEY_0);
            break;
        case ' ':
            tap_key(KEY_SPACE);
            break;
        case '!':
            tap_shifted_key(KEY_1);
            break;
        case '?':
            tap_shifted_key(KEY_SLASH);
            break;
        default:
            break;
    }
}

static int find_controller(void)
{
    char path[64];
    char name[256];

    for (int index = 0; index < 64; index++) {
        snprintf(path, sizeof(path), "/dev/input/event%d", index);

        int fd = open(path, O_RDONLY | O_NONBLOCK);
        if (fd < 0) {
            continue;
        }

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

    if (ioctl(fd, UI_SET_EVBIT, EV_KEY) < 0 ||
        ioctl(fd, UI_SET_EVBIT, EV_REL) < 0 ||
        ioctl(fd, UI_SET_RELBIT, REL_X) < 0 ||
        ioctl(fd, UI_SET_RELBIT, REL_Y) < 0 ||
        ioctl(fd, UI_SET_KEYBIT, BTN_LEFT) < 0 ||
        ioctl(fd, UI_SET_KEYBIT, BTN_RIGHT) < 0) {
        perror("configure uinput");
        close(fd);
        return -1;
    }

    for (int key = KEY_ESC; key <= KEY_MICMUTE; key++) {
        ioctl(fd, UI_SET_KEYBIT, key);
    }

    struct uinput_setup setup;
    memset(&setup, 0, sizeof(setup));
    snprintf(setup.name, UINPUT_MAX_NAME_SIZE, "TSP OpenMW Mouse Keyboard");
    setup.id.bustype = BUS_USB;
    setup.id.vendor = 0x1209;
    setup.id.product = 0x0510;
    setup.id.version = 2;

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
    if (controller_fd < 0 || grabbed == enable) {
        return;
    }

    if (ioctl(controller_fd, EVIOCGRAB, enable ? 1 : 0) < 0) {
        if (log_file != NULL) {
            fprintf(
                log_file,
                "EVIOCGRAB(%d) failed: %s\n",
                enable ? 1 : 0,
                strerror(errno)
            );
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
            mode_name(mode)
        );
        fflush(log_file);
    }
}

static void reset_virtual_buttons(void)
{
    set_mouse_button(BTN_LEFT, 0);
    set_mouse_button(BTN_RIGHT, 0);
}

static void set_mode(control_mode new_mode)
{
    reset_virtual_buttons();

    mode = new_mode;

    if (mode == MODE_GAME) {
        set_grab(false);
        log_line("MODE=GAME");
    } else if (mode == MODE_MOUSE) {
        set_grab(true);
        log_line("MODE=MOUSE");
    } else {
        set_grab(true);
        log_line("MODE=TEXT");
    }
}

static int scaled_axis(int value, bool slow)
{
    int magnitude = abs(value);

    if (magnitude <= STICK_DEADZONE) {
        return 0;
    }

    double normalized =
        (double)(magnitude - STICK_DEADZONE) /
        (double)(STICK_MAX - STICK_DEADZONE);

    if (normalized > 1.0) {
        normalized = 1.0;
    }

    double speed = normalized * normalized * 18.0;

    if (slow) {
        speed *= 0.25;
    }

    int result = (int)lrint(speed);
    if (result < 1) {
        result = 1;
    }

    return value < 0 ? -result : result;
}

static int stronger_axis(int first, int second)
{
    return abs(first) >= abs(second) ? first : second;
}

static void update_mouse(void)
{
    if (mode != MODE_MOUSE) {
        return;
    }

    int x_axis = stronger_axis(lx, rx);
    int y_axis = stronger_axis(ly, ry);

    int dx = scaled_axis(x_axis, false);
    int dy = scaled_axis(y_axis, false);

    if (dpad_x != 0) {
        dx = dpad_x * 7;
    }

    if (dpad_y != 0) {
        dy = dpad_y * 7;
    }

    if (dx != 0 || dy != 0) {
        emit_event(EV_REL, REL_X, dx);
        emit_event(EV_REL, REL_Y, dy);
        sync_events();
    }
}

static void change_text_index(int direction)
{
    size_t length = strlen(text_charset);

    if (direction > 0) {
        text_index = (text_index + 1) % length;
    } else {
        text_index = (text_index + length - 1) % length;
    }

    if (log_file != NULL) {
        fprintf(
            log_file,
            "TEXT_CHAR=%c INDEX=%zu\n",
            text_charset[text_index],
            text_index
        );
        fflush(log_file);
    }
}

static void toggle_text_case(void)
{
    char current = text_charset[text_index];

    if (current >= 'A' && current <= 'Z') {
        char target = (char)(current - 'A' + 'a');
        const char *position = strchr(text_charset, target);
        if (position != NULL) {
            text_index = (size_t)(position - text_charset);
        }
    } else if (current >= 'a' && current <= 'z') {
        char target = (char)(current - 'a' + 'A');
        const char *position = strchr(text_charset, target);
        if (position != NULL) {
            text_index = (size_t)(position - text_charset);
        }
    }

    if (log_file != NULL) {
        fprintf(log_file, "TEXT_CHAR=%c\n", text_charset[text_index]);
        fflush(log_file);
    }
}

static void handle_key_event(const struct input_event *event)
{
    bool pressed = event->value != 0;
    bool released = event->value == 0;

    log_raw_key(event);

    if (event->code == KEY_TSP_SELECT && released) {
        log_line("PHYSICAL SELECT released: code 315");

        if (mode == MODE_GAME) {
            set_mode(MODE_MOUSE);
        } else {
            set_mode(MODE_GAME);
        }

        return;
    }

    if (event->code == KEY_TSP_START) {
        if (pressed) {
            log_line("PHYSICAL START pressed: code 314");
        }

        if (released) {
            log_line("PHYSICAL START released: code 314");
        }
    }

    if (mode == MODE_GAME) {
        return;
    }

    if (event->code == KEY_TSP_L1 && pressed) {
        log_line("PHYSICAL L1 pressed: switching to TEXT mode");
        set_mode(MODE_TEXT);
        return;
    }

    if (event->code == KEY_TSP_R1 && pressed) {
        log_line("PHYSICAL R1 pressed: switching to MOUSE mode");
        set_mode(MODE_MOUSE);
        return;
    }

    if (mode == MODE_MOUSE) {
        switch (event->code) {
            case KEY_TSP_A:
                set_mouse_button(BTN_LEFT, pressed);
                break;
            case KEY_TSP_B:
                set_mouse_button(BTN_RIGHT, pressed);
                break;
            case KEY_TSP_X:
                if (pressed) {
                    tap_key(KEY_ESC);
                }
                break;
            case KEY_TSP_Y:
            case KEY_TSP_START:
                if (pressed) {
                    tap_key(KEY_ENTER);
                }
                break;
            default:
                break;
        }
        return;
    }

    if (mode == MODE_TEXT && pressed) {
        switch (event->code) {
            case KEY_TSP_A:
                type_character(text_charset[text_index]);
                break;
            case KEY_TSP_B:
                tap_key(KEY_BACKSPACE);
                break;
            case KEY_TSP_X:
                tap_key(KEY_ESC);
                break;
            case KEY_TSP_Y:
                toggle_text_case();
                break;
            case KEY_TSP_START:
                tap_key(KEY_ENTER);
                break;
            default:
                break;
        }
    }
}

static void handle_abs_event(const struct input_event *event)
{
    if (
        event->code == ABS_TSP_L2 ||
        event->code == ABS_TSP_R2 ||
        event->code == ABS_TSP_DPAD_X ||
        event->code == ABS_TSP_DPAD_Y
    ) {
        log_raw_abs(event);
    }

    switch (event->code) {
        case ABS_TSP_LX:
            lx = event->value;
            break;
        case ABS_TSP_LY:
            ly = event->value;
            break;
        case ABS_TSP_RX:
            rx = event->value;
            break;
        case ABS_TSP_RY:
            ry = event->value;
            break;
        case ABS_TSP_DPAD_X: {
            int old_value = dpad_x;
            dpad_x = event->value;

            if (mode == MODE_TEXT && old_value == 0) {
                if (dpad_x > 0) {
                    type_character(text_charset[text_index]);
                } else if (dpad_x < 0) {
                    tap_key(KEY_BACKSPACE);
                }
            }
            break;
        }
        case ABS_TSP_DPAD_Y: {
            int old_value = dpad_y;
            dpad_y = event->value;

            if (mode == MODE_TEXT && old_value == 0) {
                if (dpad_y > 0) {
                    change_text_index(1);
                } else if (dpad_y < 0) {
                    change_text_index(-1);
                }
            }
            break;
        }
        case ABS_TSP_R2: {
            bool new_r2_down = event->value >= TRIGGER_THRESHOLD;

            r2_down = new_r2_down;
            break;
        }
        default:
            break;
    }
}

int main(int argc, char **argv)
{
    const char *log_path =
        argc > 1 ? argv[1] : "/tmp/tsp_openmw_controls.log";

    log_file = fopen(log_path, "w");
    if (log_file == NULL) {
        perror("open log");
    }

    signal(SIGINT, handle_signal);
    signal(SIGTERM, handle_signal);
    signal(SIGHUP, handle_signal);

    controller_fd = find_controller();
    if (controller_fd < 0) {
        log_line("ERROR: TRIMUI Player1 was not found.");
        return 1;
    }

    uinput_fd = create_uinput_device();
    if (uinput_fd < 0) {
        log_line("ERROR: Could not create virtual mouse/keyboard.");
        close(controller_fd);
        return 1;
    }

    log_line("TSP OpenMW control helper v3 started.");
    log_line("Diagnostic logging enabled.");
    log_line("Mode values: 0=GAME 1=MOUSE 2=TEXT");
    log_line("Select release: GAME -> MOUSE; MOUSE/TEXT -> GAME");
    log_line("L1 press in special modes: TEXT; R1 press in special modes: MOUSE");
    set_mode(MODE_GAME);

    struct pollfd poll_fd;
    poll_fd.fd = controller_fd;
    poll_fd.events = POLLIN;
    poll_fd.revents = 0;

    while (running) {
        int result = poll(&poll_fd, 1, TICK_MS);

        if (result > 0 && (poll_fd.revents & POLLIN)) {
            struct input_event events[32];
            ssize_t count = read(controller_fd, events, sizeof(events));

            if (count > 0) {
                size_t event_count = (size_t)count / sizeof(struct input_event);

                for (size_t index = 0; index < event_count; index++) {
                    if (events[index].type == EV_KEY) {
                        handle_key_event(&events[index]);
                    } else if (events[index].type == EV_ABS) {
                        handle_abs_event(&events[index]);
                    }
                }
            }
        } else if (result < 0 && errno != EINTR) {
            if (log_file != NULL) {
                fprintf(log_file, "poll failed: %s\n", strerror(errno));
                fflush(log_file);
            }
            break;
        }

        update_mouse();
    }

    reset_virtual_buttons();
    set_grab(false);

    if (uinput_fd >= 0) {
        ioctl(uinput_fd, UI_DEV_DESTROY);
        close(uinput_fd);
    }

    if (controller_fd >= 0) {
        close(controller_fd);
    }

    log_line("TSP OpenMW control helper v3 stopped.");

    if (log_file != NULL) {
        fclose(log_file);
    }

    return 0;
}
