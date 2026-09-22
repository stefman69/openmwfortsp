#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/input.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <time.h>
#include <unistd.h>

#define MAX_DEVICES 64

struct input_device {
    int fd;
    char path[128];
    char name[256];
};

static const char *event_type_name(unsigned short type)
{
    switch (type) {
        case EV_KEY: return "KEY";
        case EV_ABS: return "ABS";
        case EV_REL: return "REL";
        case EV_SYN: return "SYN";
        default: return "OTHER";
    }
}

int main(int argc, char **argv)
{
    int duration = 30;
    struct input_device devices[MAX_DEVICES];
    struct pollfd pollfds[MAX_DEVICES];
    int device_count = 0;
    DIR *directory;
    struct dirent *entry;
    time_t end_time;

    if (argc >= 2) {
        duration = atoi(argv[1]);
        if (duration < 5) {
            duration = 5;
        }
    }

    directory = opendir("/dev/input");

    if (!directory) {
        perror("opendir /dev/input");
        return 1;
    }

    while ((entry = readdir(directory)) != NULL &&
           device_count < MAX_DEVICES) {
        int fd;
        char path[128];
        char name[256];

        if (strncmp(entry->d_name, "event", 5) != 0) {
            continue;
        }

        snprintf(
            path,
            sizeof(path),
            "/dev/input/%s",
            entry->d_name
        );

        fd = open(path, O_RDONLY | O_NONBLOCK);

        if (fd < 0) {
            continue;
        }

        memset(name, 0, sizeof(name));

        if (ioctl(fd, EVIOCGNAME(sizeof(name)), name) < 0) {
            snprintf(name, sizeof(name), "unknown");
        }

        devices[device_count].fd = fd;

        snprintf(
            devices[device_count].path,
            sizeof(devices[device_count].path),
            "%s",
            path
        );

        snprintf(
            devices[device_count].name,
            sizeof(devices[device_count].name),
            "%s",
            name
        );

        pollfds[device_count].fd = fd;
        pollfds[device_count].events = POLLIN;
        pollfds[device_count].revents = 0;

        printf(
            "DEVICE %d: %s | %s\n",
            device_count,
            path,
            name
        );

        device_count++;
    }

    closedir(directory);

    if (device_count == 0) {
        fprintf(stderr, "No readable input devices found.\n");
        return 1;
    }

    printf("\n");
    printf("Recording input for %d seconds.\n", duration);
    printf("Press each control one at a time in this order:\n");
    printf("A B X Y L1 R1 L2 R2 L3 R3 Start Select\n");
    printf("D-pad Up Down Left Right\n");
    printf("Left stick Up Down Left Right\n");
    printf("Right stick Up Down Left Right\n");
    printf("\n");
    fflush(stdout);

    end_time = time(NULL) + duration;

    while (time(NULL) < end_time) {
        int ready;
        int i;

        ready = poll(pollfds, device_count, 250);

        if (ready < 0) {
            if (errno == EINTR) {
                continue;
            }

            perror("poll");
            break;
        }

        if (ready == 0) {
            continue;
        }

        for (i = 0; i < device_count; i++) {
            struct input_event events[32];
            ssize_t bytes;
            size_t event_count;
            size_t event_index;

            if (!(pollfds[i].revents & POLLIN)) {
                continue;
            }

            bytes = read(
                devices[i].fd,
                events,
                sizeof(events)
            );

            if (bytes <= 0) {
                continue;
            }

            event_count = (size_t)bytes / sizeof(struct input_event);

            for (event_index = 0;
                 event_index < event_count;
                 event_index++) {
                struct input_event *event = &events[event_index];

                if (event->type != EV_KEY &&
                    event->type != EV_ABS &&
                    event->type != EV_REL) {
                    continue;
                }

                printf(
                    "%s | %s | type=%s(%u) code=%u value=%d\n",
                    devices[i].path,
                    devices[i].name,
                    event_type_name(event->type),
                    event->type,
                    event->code,
                    event->value
                );
            }
        }

        fflush(stdout);
    }

    printf("\nInput recording finished.\n");

    for (int i = 0; i < device_count; i++) {
        close(devices[i].fd);
    }

    return 0;
}
