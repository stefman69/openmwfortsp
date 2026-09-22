"""TSP_PAD_DISCOVERY_V66 -- find the gamepad by what it reports, not what it is called.

find_controller() required an evdev device named exactly "TRIMUI Player1".
Stock/CrossMix/TSPS call the pad that. Knulli exposes the SAME hardware under a
different name, so the lookup failed, the helper exited during startup, and the
launcher treated that as fatal: black screen, no engine, no explanation.

This replaces the name test with a preference ladder -- explicit override, known
name, then capability match -- so stock/CrossMix/TSPS keep selecting exactly the
device they always did (they hit the name branch, which is checked first and
outranks everything below it), while an image that renames the pad still works.

Refuses to write anything unless the source is the CURRENT one (V64/V65 markers
present) and find_controller() is byte-identical to what is expected.
"""

import io
import os
import sys
import time

SRC = os.environ.get("TSPHELPERSRC", "/root/tsp_openmw_controls.c")
BLOCK = os.environ.get("TSPNEWBLOCK", "/root/new_block.c")

OLD = '''static int find_controller(void)
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
                fprintf(log_file, "Controller: %s | %s\\n", path, name);
                fflush(log_file);
            }
            return fd;
        }
        close(fd);
    }

    return -1;
}'''

OLDERR = '        log_line("ERROR: TRIMUI Player1 was not found.");'
NEWERR = (
    '        log_line("ERROR: no usable gamepad found. Scanned devices are listed above.");\n'
    '        log_line("       Set OPENMW_TSP_PAD to a /dev/input/eventN path or an exact device name to override.");'
)

for path, what in ((SRC, "helper source"), (BLOCK, "replacement block")):
    if not os.path.exists(path):
        print("FAIL: missing %s: %s" % (what, path))
        sys.exit(1)

original = io.open(SRC, encoding="utf-8").read()
new_block = io.open(BLOCK, encoding="utf-8").read()

if "TSP_PAD_DISCOVERY_V66" in original:
    print("SKIP (already applied): v66 pad discovery is present")
    sys.exit(0)

# --- preconditions -------------------------------------------------------
# This must be the CURRENT helper, not an older copy. Shipping a rebuild from a
# stale source would silently revert the V64/V65 text-injection work.
for need, why in (
    ("TSP_TEXT_INJECT", "V64 text injection queue -- proves this is the current source"),
    ("DEVICE_NAME", "the name macro the new code still uses for the known-name list"),
    ("EVIOCGNAME", "evdev name ioctl already used"),
    ("KEY_TSP_MENU", "the button defines the capability match scores against"),
    ("log_file", "the helper log handle the scan lines are written to"),
):
    if need not in original:
        print("FAIL: expected '%s' in the source (%s)." % (need, why))
        print("      This does not look like the current helper. Nothing written.")
        sys.exit(1)
print("OK: preconditions -- current source, every symbol the new code needs is present")

if original.count(OLD) != 1:
    print("FAIL: find_controller() matched %d times (need exactly 1)." % original.count(OLD))
    print("      The function has changed since this patch was written.")
    print("      Nothing written. Send the .c file back for a hand edit instead.")
    sys.exit(1)

if original.count(OLDERR) != 1:
    print("FAIL: the error message matched %d times (need exactly 1)." % original.count(OLDERR))
    print("      Nothing written.")
    sys.exit(1)

text = original.replace(OLD, new_block.rstrip() + "\n", 1)
text = text.replace(OLDERR, NEWERR, 1)

# --- postconditions ------------------------------------------------------
for ch_open, ch_close in (("{", "}"), ("(", ")")):
    if text.count(ch_open) != text.count(ch_close):
        print("FAIL: brace/paren imbalance: %s=%d %s=%d"
              % (ch_open, text.count(ch_open), ch_close, text.count(ch_close)))
        sys.exit(1)

checks = (
    ("TSP_PAD_DISCOVERY_V66", 1, "the new discovery block"),
    ("static int find_controller(void)", 1, "exactly one find_controller"),
    ("tsp_pad_rank", 3, "rank helper: defined once, used once, plus its own prototype line"),
    ("OPENMW_TSP_PAD", 4, "the override env var"),
    ("TSP_UINPUT_NAME", 2, "the self-exclusion guard"),
)
for needle, want, why in checks:
    got = text.count(needle)
    if got < 1:
        print("FAIL: '%s' missing after patch (%s)" % (needle, why))
        sys.exit(1)
print("OK: new block present, braces balanced, one find_controller")

if "TSP_TEXT_INJECT" not in text:
    print("FAIL: the V64 text injection code was damaged")
    sys.exit(1)
if 'strcmp(name, DEVICE_NAME) == 0' in text:
    print("FAIL: the old exact-name test is still present")
    sys.exit(1)
print("OK: V64 text injection intact, old exact-name test gone")

backup = "%s.before-v66-%s" % (SRC, time.strftime("%Y%m%d-%H%M%S"))
io.open(backup, "w", encoding="utf-8", newline="").write(original)
io.open(SRC, "w", encoding="utf-8", newline="").write(text)
print("wrote %s (backup: %s)" % (SRC, os.path.basename(backup)))
print("VERIFIED: v66 pad discovery applied")
