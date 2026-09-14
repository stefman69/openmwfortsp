"""TSP_A_DOUBLE_PRESS_051_V53 -- A works on the first press."""

import io
import os
import sys
import time

SRC = os.environ.get("TSPSRC", "/root/openmw-0.51-tsp-src")
CM = os.environ.get("TSPCM", os.path.join(SRC, "apps/openmw/mwinput/controllermanager.cpp"))

MARK = "TSP_A_DOUBLE_PRESS_051_V53"

EDITS = []

EDITS.append(("cpp: A clicks only when the cursor is genuinely active",
"""            bool treatAsMouse = winMgr->getCursorVisible() || tspMouseUsableNow();""",
"""            // TSP_A_DOUBLE_PRESS_051_V53 -- was:
            //     winMgr->getCursorVisible() || tspMouseUsableNow()
            // getCursorVisible() is transient state left over from earlier, and
            // setCursorActive(false) on the next line clears it as a side effect of
            // the very press being judged. So a first A could be converted into an
            // emulated click at a stale pointer position, hit nothing, and only the
            // second A would reach onControllerButtonEvent. Use the same predicate
            // the cursor itself is gated on, which has no per-press hysteresis.
            bool treatAsMouse = tspSettingsMouseActive;"""))

EDITS.append(("cpp: log every A decision in a menu",
"""                // Fall through to mouse click
                if (mGamepadGuiCursorEnabled && treatAsMouse && arg.button == SDL_CONTROLLER_BUTTON_A)
                    return false;""",
"""                // TSP_A_DOUBLE_PRESS_051_V53 -- measurement only. If a double
                // press is ever seen again, this names the branch that took it.
                if (arg.button == SDL_CONTROLLER_BUTTON_A)
                {
                    Log(Debug::Info)
                        << "TSP_A_DOUBLE_PRESS_051_V53 a=press"
                        << " asMouse=" << (treatAsMouse ? 1 : 0)
                        << " cursorEnabled=" << (mGamepadGuiCursorEnabled ? 1 : 0)
                        << " settingsMouse=" << (tspSettingsMouseActive ? 1 : 0)
                        << " cursorVisible=" << (winMgr->getCursorVisible() ? 1 : 0)
                        << " mouseUsable=" << (tspMouseUsableNow() ? 1 : 0)
                        << " route=" << ((mGamepadGuiCursorEnabled && treatAsMouse)
                                             ? "emulated-click"
                                             : "widget-activate");
                }
                // Fall through to mouse click
                if (mGamepadGuiCursorEnabled && treatAsMouse && arg.button == SDL_CONTROLLER_BUTTON_A)
                    return false;"""))


def balanced(text, label):
    for open_ch, close_ch in (("{", "}"), ("(", ")")):
        if text.count(open_ch) != text.count(close_ch):
            print("FAIL: brace/paren imbalance in %s: %s=%d %s=%d"
                  % (label, open_ch, text.count(open_ch), close_ch, text.count(close_ch)))
            return False
    return True


if not os.path.exists(CM):
    print("FAIL: missing %s" % CM)
    sys.exit(1)

with io.open(CM, encoding="utf-8") as fh:
    original = fh.read()

if "TSP_TEXT_HANDOFF_051_V51" not in original:
    print("FAIL: V51 is not present. Apply V51 first. Nothing written.")
    sys.exit(1)
print("OK: precondition - V51 present")

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

if "bool treatAsMouse = winMgr->getCursorVisible()" in text:
    print("FAIL: treatAsMouse still keys off getCursorVisible()")
    sys.exit(1)
if text.count("bool treatAsMouse = tspSettingsMouseActive;") != 1:
    print("FAIL: expected exactly 1 rewritten treatAsMouse")
    sys.exit(1)
if text.count("if (topWin->onControllerButtonEvent(arg))") != 1:
    print("FAIL: the widget-activation branch is missing")
    sys.exit(1)
if text.count("if (mGamepadGuiCursorEnabled && treatAsMouse && arg.button == SDL_CONTROLLER_BUTTON_A)") != 1:
    print("FAIL: the emulated-click branch is missing")
    sys.exit(1)
if "winMgr->getControllerTooltipVisible()" not in text:
    print("FAIL: the tooltip exception was lost")
    sys.exit(1)
if text.count("TSP_A_DOUBLE_PRESS_051_V53 a=press") != 1:
    print("FAIL: expected exactly 1 probe site")
    sys.exit(1)
print("OK: A routes on a stable predicate, both branches intact, tooltip kept")

if applied == 0:
    print("VERIFIED: v53 already present, nothing written.")
    sys.exit(0)

backup = "%s.before-v53-%s" % (CM, time.strftime("%Y%m%d-%H%M%S"))
with io.open(backup, "w", encoding="utf-8", newline="") as fh:
    fh.write(original)
with io.open(CM, "w", encoding="utf-8", newline="") as fh:
    fh.write(text)
print("wrote %s (backup: %s)" % (CM, os.path.basename(backup)))

with io.open(CM, encoding="utf-8") as fh:
    if MARK not in fh.read():
        print("FAIL: marker missing after write")
        sys.exit(1)

print("VERIFIED: v53 present (%d applied, %d already present)" % (applied, skipped))
