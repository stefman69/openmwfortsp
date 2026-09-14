#include <errno.h>
#include <fcntl.h>
#include <linux/input.h>
#include <linux/uinput.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <time.h>
#include <unistd.h>

static void sleep_ms(long milliseconds)
{
    struct timespec duration;

    duration.tv_sec = milliseconds / 1000;
    duration.tv_nsec = (milliseconds % 1000) * 1000000L;

    while (nanosleep(&duration, &duration) == -1 && errno == EINTR) {
    }
}

static int send_event(int fd, unsigned short type, unsigned short code, int value)
{
    struct input_event event;

    memset(&event, 0, sizeof(event));

    event.type = type;
    event.code = code;
    event.value = value;

    if (write(fd, &event, sizeof(event)) != sizeof(event)) {
        perror("write input event");
        return -1;
    }

    return 0;
}

static int send_sync(int fd)
{
    return send_event(fd, EV_SYN, SYN_REPORT, 0);
}

int main(int argc, char **argv)
{
    int delay_seconds = 15;
    int fd;
    struct uinput_setup setup;

    if (argc >= 2) {
        delay_seconds = atoi(argv[1]);

        if (delay_seconds < 0) {
            delay_seconds = 0;
        }
    }

    printf("Virtual F12 helper waiting %d seconds...\n", delay_seconds);
    fflush(stdout);

    sleep((unsigned int)delay_seconds);

    fd = open("/dev/uinput", O_WRONLY | O_NONBLOCK);

    if (fd < 0) {
        perror("open /dev/uinput");
        return 1;
    }

    if (ioctl(fd, UI_SET_EVBIT, EV_KEY) < 0) {
        perror("UI_SET_EVBIT EV_KEY");
        close(fd);
        return 1;
    }

    if (ioctl(fd, UI_SET_EVBIT, EV_SYN) < 0) {
        perror("UI_SET_EVBIT EV_SYN");
        close(fd);
        return 1;
    }

    if (ioctl(fd, UI_SET_KEYBIT, KEY_F12) < 0) {
        perror("UI_SET_KEYBIT KEY_F12");
        close(fd);
        return 1;
    }

    memset(&setup, 0, sizeof(setup));

    setup.id.bustype = BUS_USB;
    setup.id.vendor = 0x1234;
    setup.id.product = 0x5678;
    setup.id.version = 1;

    snprintf(
        setup.name,
        UINPUT_MAX_NAME_SIZE,
        "OpenMW Virtual F12"
    );

    if (ioctl(fd, UI_DEV_SETUP, &setup) < 0) {
        perror("UI_DEV_SETUP");
        close(fd);
        return 1;
    }

    if (ioctl(fd, UI_DEV_CREATE) < 0) {
        perror("UI_DEV_CREATE");
        close(fd);
        return 1;
    }

    sleep_ms(500);

    printf("Sending F12 keypress...\n");
    fflush(stdout);

    if (send_event(fd, EV_KEY, KEY_F12, 1) < 0 ||
        send_sync(fd) < 0) {
        ioctl(fd, UI_DEV_DESTROY);
        close(fd);
        return 1;
    }

    sleep_ms(150);

    if (send_event(fd, EV_KEY, KEY_F12, 0) < 0 ||
        send_sync(fd) < 0) {
        ioctl(fd, UI_DEV_DESTROY);
        close(fd);
        return 1;
    }

    sleep_ms(500);

    if (ioctl(fd, UI_DEV_DESTROY) < 0) {
        perror("UI_DEV_DESTROY");
    }

    close(fd);

    printf("F12 keypress sent successfully.\n");
    fflush(stdout);

    return 0;
}
