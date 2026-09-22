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
