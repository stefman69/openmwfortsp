"""
TSP_CONTROL_STACK_051_V45 -- delta patch (revision B).

Revision B exists because revision A shipped a multi-line anchor through a paste
path that stripped blank lines, so the anchor described text that does not exist
and matched 0 times. B uses SINGLE-LINE anchors only, and is delivered base64
encoded, so no amount of whitespace mangling in transit can alter it.

WHAT IT DOES. Both gamepadToGuiControl overloads (button path and axis path) do:

    mGamepadGuiCursorEnabled = topWin->isGamepadCursorAllowed();

which enables the cursor for every window that merely PERMITS one -- the reported
"pointer appears in inventory, barter and spellmaking uninvited". Routing both
through tspMouseUsableNow() (added by V41; it already folds in
isGamepadCursorAllowed()) makes the cursor opt-in per menu. The new condition is
strictly narrower than the old one, never wider.

There is a THIRD assignment to mGamepadGuiCursorEnabled in this file --
`mGamepadGuiCursorEnabled = !mGamepadGuiCursorEnabled;`, the stock toggle. It is
deliberately untouched; the anchor below cannot match it.

  TSPSRC=/root/openmw-0.51-tsp-src python3 patch_v45b.py
"""

import io
import os
import sys
import time

SRC = os.environ.get("TSPSRC", "/root/openmw-0.51-tsp-src")
CM = os.path.join(SRC, "apps/openmw/mwinput/controllermanager.cpp")
CH = os.path.join(SRC, "apps/openmw/mwinput/controllermanager.hpp")

MARK = "TSP_CONTROL_STACK_051_V45"

OLD_LINE = "mGamepadGuiCursorEnabled = topWin->isGamepadCursorAllowed();"
NEW_LINE = ("mGamepadGuiCursorEnabled = tspMouseUsableNow();"
            "  // TSP_CONTROL_STACK_051_V45 cursor is opt-in per menu")
EXPECT = 2


def survey(text, why):
    """Print every mGamepadGuiCursorEnabled assignment with a line number.

    A failed anchor that says only 'matched 0 times' costs a whole round trip.
    This makes any miss diagnosable from the first run.
    """
    print("      %s" % why)
    print("      --- every 'mGamepadGuiCursorEnabled =' in the file ---")
    for num, line in enumerate(text.splitlines(), 1):
        if "mGamepadGuiCursorEnabled =" in line:
            print("      %5d | %s" % (num, line.rstrip()))
    print("      --- end survey ---")


def balanced(text):
    for open_ch, close_ch in (("{", "}"), ("(", ")")):
        if text.count(open_ch) != text.count(close_ch):
            print("FAIL: brace/paren imbalance: %s=%d %s=%d"
                  % (open_ch, text.count(open_ch), close_ch, text.count(close_ch)))
            return False
    return True


# --- preconditions ----------------------------------------------------------
# V45 calls tspMouseUsableNow(). If V41 is not in the header this cannot
# compile, and a failed build after a long qemu rebuild is the expensive way to
# find that out.
for path in (CM, CH):
    if not os.path.exists(path):
        print("FAIL: missing %s" % path)
        sys.exit(1)

with io.open(CH, encoding="utf-8") as fh:
    if "bool tspMouseUsableNow();" not in fh.read():
        print("FAIL: controllermanager.hpp does not declare tspMouseUsableNow().")
        print("      V45 depends on TSP_MOUSE_MODE_051_V41. Nothing written.")
        sys.exit(1)
print("OK: precondition - tspMouseUsableNow() is declared (V41 present)")

with io.open(CM, encoding="utf-8") as fh:
    original = fh.read()

if "ControllerManager::tspMouseUsableNow" not in original:
    print("FAIL: controllermanager.cpp has no tspMouseUsableNow definition.")
    print("      Nothing written.")
    sys.exit(1)
print("OK: precondition - tspMouseUsableNow() is defined")

# --- apply ------------------------------------------------------------------
already = original.count(NEW_LINE)
found = original.count(OLD_LINE)

if already == EXPECT and found == 0:
    print("SKIP: both cursor assignments already route through tspMouseUsableNow().")
    print("Nothing to do.")
    text = original
    applied = 0
else:
    if found != EXPECT:
        print("FAIL: found %d occurrence(s) of the cursor assignment, expected %d."
              % (found, EXPECT))
        survey(original, "The tree does not look the way V45 expects.")
        print("      Nothing written.")
        sys.exit(1)

    text = original.replace(OLD_LINE, NEW_LINE)
    applied = EXPECT
    print("OK: rewrote %d cursor assignment(s) to tspMouseUsableNow()" % applied)

# --- post-transform assertions, all before any write ------------------------
if not balanced(text):
    print("      Nothing written.")
    sys.exit(1)

stray = text.count(OLD_LINE)
if stray != 0:
    print("FAIL: %d direct isGamepadCursorAllowed() cursor assignment(s) remain." % stray)
    survey(text, "Half-applied state; refusing to write.")
    sys.exit(1)

if text.count(NEW_LINE) != EXPECT:
    print("FAIL: expected %d tspMouseUsableNow() cursor assignments, found %d."
          % (EXPECT, text.count(NEW_LINE)))
    survey(text, "Half-applied state; refusing to write.")
    sys.exit(1)

# The stock toggle must survive untouched. If this vanished, the replace was
# too greedy and MENU/L3 toggling would be broken in a way that only shows up
# on device.
if text.count("mGamepadGuiCursorEnabled = !mGamepadGuiCursorEnabled;") != 1:
    print("FAIL: the stock 'mGamepadGuiCursorEnabled = !mGamepadGuiCursorEnabled;' "
          "toggle is no longer present exactly once.")
    survey(text, "Refusing to write.")
    sys.exit(1)
print("OK: stock toggle untouched")

# --- write -------------------------------------------------------------------
if applied == 0:
    print("VERIFIED: v45 already present, nothing written.")
    sys.exit(0)

backup = "%s.before-v45-%s" % (CM, time.strftime("%Y%m%d-%H%M%S"))
with io.open(backup, "w", encoding="utf-8", newline="") as fh:
    fh.write(original)
with io.open(CM, "w", encoding="utf-8", newline="") as fh:
    fh.write(text)
print("wrote %s (backup: %s)" % (CM, os.path.basename(backup)))

with io.open(CM, encoding="utf-8") as fh:
    check = fh.read()
if MARK not in check:
    print("FAIL: marker missing after write")
    sys.exit(1)
if check.count(OLD_LINE) != 0 or check.count(NEW_LINE) != EXPECT:
    print("FAIL: on-disk file does not match what was written")
    sys.exit(1)

print("VERIFIED: v45 present, cursor is opt-in on both paths (%d rewritten)" % applied)
