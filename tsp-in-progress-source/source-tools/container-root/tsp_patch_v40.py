import sys, io, os, time

SRC = os.environ.get("TSPHELPER", "/root/tsp_openmw_controls.c")
MARK = "TSP_TEXT_REMAP_051_V40"
EDITS = []

EDITS.append(("defines", """#define TEXT_CHAR_TMP    "/tmp/openmw-tsp-text-char.tmp\"""",
"""#define TEXT_CHAR_TMP    "/tmp/openmw-tsp-text-char.tmp"

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
#define MOUSE_MODE_FLAG "/tmp/openmw-tsp-mouse-mode\""""))

EDITS.append(("pointing-mode functions", """static void leave_text_mode(void)
{
    log_line("SELECT: leave/cancel text entry (Escape).");""",
"""/* TSP_TEXT_REMAP_051_V40 -- MENU: hand the pad to OpenMW, keep text entry open. */
static void tsp_enter_pointing_mode(void)
{
    log_line("MENU: POINTING - pad yielded to OpenMW, text entry still open.");

    suppress_auto_text = true;

    FILE *file = fopen(MOUSE_MODE_FLAG, "w");
    if (file != NULL) {
        fputs("1\\n", file);
        fclose(file);
    } else if (log_file != NULL) {
        fprintf(log_file, "MENU: could not write %s: %s\\n",
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
    suppress_auto_text = false;
    sync_automatic_mode();
}

static void leave_text_mode(void)
{
    log_line("CANCEL: leave/cancel text entry (Escape).");"""))

EDITS.append(("leave_text_mode clears pointing flag", """    suppress_auto_text = true;
    tap_key(KEY_ESC);
    set_mode(MODE_GAME);
}""",
"""    suppress_auto_text = true;
    unlink(MOUSE_MODE_FLAG); /* TSP_TEXT_REMAP_051_V40 */
    tap_key(KEY_ESC);
    set_mode(MODE_GAME);
}"""))

EDITS.append(("GAME-mode MENU handler", """        if (event->code == KEY_TSP_MENU && pressed && suppress_auto_text) {
            suppress_auto_text = false;
            sync_automatic_mode();
        }
        return;""",
"""        /* TSP_TEXT_REMAP_051_V40 -- only meaningful while text entry is still
         * open and we yielded the pad; otherwise MENU belongs to OpenMW. */
        if (event->code == KEY_TSP_MENU && pressed && suppress_auto_text
            && openmw_text_active()) {
            tsp_leave_pointing_mode();
        }
        return;"""))

EDITS.append(("TEXT-mode dispatch", """    switch (event->code) {
        case KEY_TSP_A:
            type_character(selected_character());
            break;
        case KEY_TSP_B:
            tap_key(KEY_BACKSPACE);
            break;
        case KEY_TSP_X:
            toggle_alt_charset();
            break;
        case KEY_TSP_Y:
            toggle_case_or_return_to_letters();
            break;
        case KEY_TSP_START:
            tap_key(KEY_ENTER);
            break;
        case KEY_TSP_SELECT:
            /* TSP_TEXT_SELECT_CANCEL_051_V13 */
            leave_text_mode();
            break;
        case KEY_TSP_MENU:
            break;
        default:
            break;
    }""",
"""    /*
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
    }"""))

EDITS.append(("d-pad left = backspace", """        if (old_value == 0) {
            if (dpad_x > 0)
                tap_key(KEY_RIGHT);
            else if (dpad_x < 0)
                tap_key(KEY_LEFT);
        }
        return;""",
"""        if (old_value == 0) {
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
        return;"""))

EDITS.append(("startup: clear pointing flag", """    unlink(TEXT_ACTIVE_FLAG);
    unlink(TEXT_CHAR_FILE);
    unlink(TEXT_CHAR_TMP);

    controller_fd = find_controller();""",
"""    unlink(TEXT_ACTIVE_FLAG);
    unlink(TEXT_CHAR_FILE);
    unlink(TEXT_CHAR_TMP);
    unlink(MOUSE_MODE_FLAG); /* TSP_TEXT_REMAP_051_V40 */

    controller_fd = find_controller();"""))

EDITS.append(("shutdown: clear pointing flag", """    set_mode(MODE_GAME);
    unlink(TEXT_ACTIVE_FLAG);
    unlink(TEXT_CHAR_FILE);
    unlink(TEXT_CHAR_TMP);""",
"""    set_mode(MODE_GAME);
    unlink(TEXT_ACTIVE_FLAG);
    unlink(TEXT_CHAR_FILE);
    unlink(TEXT_CHAR_TMP);
    unlink(MOUSE_MODE_FLAG); /* TSP_TEXT_REMAP_051_V40 */"""))

EDITS.append(("help text", """    log_line("A: type selected character; B: backspace/delete.");
    log_line("X: Letters <-> Numbers/Alt/Space.");
    log_line("Y: uppercase/lowercase; from Alt return to Letters.");
    log_line("Start: Enter/finish text; Select: leave/cancel text mode.");""",
"""    log_line("A: type selected character; Left: backspace/delete.");
    log_line("X: Letters <-> Numbers/Alt/Space.");
    log_line("Y: uppercase/lowercase; from Alt return to Letters.");
    log_line("Start: Enter/finish text; B: leave/cancel text mode.");
    log_line("Menu: TYPING <-> POINTING (yields pad to OpenMW, text stays open).");
    log_line("TSP_TEXT_REMAP_051_V40 active.");"""))

# ---------------------------------------------------------------- engine
def balanced(text, label):
    for o, c in {'{': '}', '(': ')'}.items():
        if text.count(o) != text.count(c):
            print("FAIL: imbalance after %s: %s=%d %s=%d" % (label, o, text.count(o), c, text.count(c)))
            return False
    return True

if not os.path.exists(SRC):
    print("FAIL: missing %s" % SRC); sys.exit(1)
with io.open(SRC, encoding="utf-8") as fh:
    original = fh.read()

text = original
applied = skipped = 0
for label, old, new in EDITS:
    if new in text:
        print("SKIP (already applied): %s" % label); skipped += 1; continue
    n = text.count(old)
    if n != 1:
        print("FAIL: anchor for '%s' matched %d times (need exactly 1)" % (label, n)); sys.exit(1)
    text = text.replace(old, new, 1)
    print("OK: %s" % label); applied += 1

if not balanced(text, os.path.basename(SRC)):
    sys.exit(1)

if applied == 0:
    print("Nothing to do - all %d edits already present." % skipped)
else:
    bak = "%s.before-remap-v40-%s" % (SRC, time.strftime("%Y%m%d-%H%M%S"))
    with io.open(bak, "w", encoding="utf-8", newline="") as fh:
        fh.write(original)
    with io.open(SRC, "w", encoding="utf-8", newline="") as fh:
        fh.write(text)
    print("wrote %s (backup: %s)" % (SRC, os.path.basename(bak)))

with io.open(SRC, encoding="utf-8") as fh:
    if MARK not in fh.read():
        print("FAIL: marker missing after write"); sys.exit(1)
print("VERIFIED: helper remap v40 present (%d applied, %d already present)" % (applied, skipped))
