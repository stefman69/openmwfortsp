import io
import os
import sys
import time

SRC = os.environ.get("TSPSRC", "/root/openmw-0.51-tsp-src")
CM = os.path.join(SRC, "apps/openmw/mwinput/controllermanager.cpp")
CH = os.path.join(SRC, "apps/openmw/mwinput/controllermanager.hpp")

MARK = "TSP_CONTROL_STACK_051_V45"

EDITS = []

EDITS.append(("cpp: cursor is opt-in, button path",
"""                mGamepadGuiCursorEnabled = topWin->isGamepadCursorAllowed();

                // Fall through to mouse click""",
"""                // TSP_CONTROL_STACK_051_V45 -- stock enabled the cursor for every
                // window that merely ALLOWS one, which is why the pointer appeared in
                // inventory, spells and barter uninvited. Now it is opt-in per menu:
                // tspMouseUsableNow() already folds in isGamepadCursorAllowed(), so
                // this is strictly narrower than what it replaces -- never wider.
                mGamepadGuiCursorEnabled = tspMouseUsableNow();

                // Fall through to mouse click"""))

EDITS.append(("cpp: cursor is opt-in, axis path",
"""                // Update cursor state
                mGamepadGuiCursorEnabled = topWin->isGamepadCursorAllowed();
                if (!mGamepadGuiCursorEnabled)""",
"""                // Update cursor state
                // TSP_CONTROL_STACK_051_V45 -- opt-in per menu; see the button path.
                mGamepadGuiCursorEnabled = tspMouseUsableNow();
                if (!mGamepadGuiCursorEnabled)"""))


def balanced(text, label):
    for open_ch, close_ch in (("{", "}"), ("(", ")")):
        if text.count(open_ch) != text.count(close_ch):
            print("FAIL: brace/paren imbalance in %s: %s=%d %s=%d"
                  % (label, open_ch, text.count(open_ch),
                     close_ch, text.count(close_ch)))
            return False
    return True


# --- preconditions ----------------------------------------------------------
# V45 calls tspMouseUsableNow(). If V41 is not in the header this will not
# compile, and a failed build after a long qemu rebuild is the expensive way
# to learn that. Check it here instead.
for path in (CM, CH):
    if not os.path.exists(path):
        print("FAIL: missing %s" % path)
        sys.exit(1)

with io.open(CH, encoding="utf-8") as fh:
    header = fh.read()
if "bool tspMouseUsableNow();" not in header:
    print("FAIL: controllermanager.hpp does not declare tspMouseUsableNow().")
    print("      V45 depends on TSP_MOUSE_MODE_051_V41. Apply patch_v41.py first.")
    print("      Nothing written.")
    sys.exit(1)
print("OK: precondition - tspMouseUsableNow() is declared (V41 present)")

with io.open(CM, encoding="utf-8") as fh:
    original = fh.read()

if "tspMouseUsableNow" not in original:
    print("FAIL: controllermanager.cpp has no tspMouseUsableNow definition.")
    print("      Nothing written.")
    sys.exit(1)
print("OK: precondition - tspMouseUsableNow() is defined")

# --- apply ------------------------------------------------------------------
text = original
applied = skipped = 0

for label, old, new in EDITS:
    if new in text:
        print("SKIP (already applied): %s" % label)
        skipped += 1
        continue
    count = text.count(old)
    if count != 1:
        print("FAIL: anchor for '%s' matched %d times (need exactly 1)" % (label, count))
        print("      Nothing written.")
        sys.exit(1)
    text = text.replace(old, new, 1)
    print("OK: %s" % label)
    applied += 1

if not balanced(text, "controllermanager.cpp"):
    print("      Nothing written.")
    sys.exit(1)

# Post-transform assertions. The point of V45 is that NEITHER cursor assignment
# still reads isGamepadCursorAllowed() directly -- if one survives, the menu it
# governs keeps showing the uninvited pointer and the patch looks half-applied.
stray = text.count("mGamepadGuiCursorEnabled = topWin->isGamepadCursorAllowed();")
if stray != 0:
    print("FAIL: %d direct isGamepadCursorAllowed() cursor assignment(s) remain." % stray)
    print("      Nothing written.")
    sys.exit(1)
if text.count("mGamepadGuiCursorEnabled = tspMouseUsableNow();") != 2:
    print("FAIL: expected exactly 2 tspMouseUsableNow() cursor assignments.")
    print("      Nothing written.")
    sys.exit(1)

if applied == 0:
    print("Nothing to do - all %d edits already present." % skipped)
else:
    backup = "%s.before-v45-%s" % (CM, time.strftime("%Y%m%d-%H%M%S"))
    with io.open(backup, "w", encoding="utf-8", newline="") as fh:
        fh.write(original)
    with io.open(CM, "w", encoding="utf-8", newline="") as fh:
        fh.write(text)
    print("wrote %s (backup: %s)" % (CM, os.path.basename(backup)))

with io.open(CM, encoding="utf-8") as fh:
    if MARK not in fh.read():
        print("FAIL: marker missing after write")
        sys.exit(1)

print("VERIFIED: v45 present, cursor is opt-in on both paths (%d applied, %d already present)"
      % (applied, skipped))
