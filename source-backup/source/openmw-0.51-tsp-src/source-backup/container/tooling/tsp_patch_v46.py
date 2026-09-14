import io
import os
import sys
import time

SRC = os.environ.get("TSPSRC", "/root/openmw-0.51-tsp-src")
IM = os.environ.get("TSPIM", os.path.join(SRC, "apps/openmw/mwinput/inputmanagerimp.cpp"))

MARK = "TSP_SETTINGS_CURSOR_RESTORE_051_V46"

EDITS = []

EDITS.append(("disableControls path",
"""            MyGUI::PointerManager::getInstance().setVisible(
                windowManager->getCursorVisible()
                || mControllerManager->tspMouseUsableNow());""",
"""            // TSP_SETTINGS_CURSOR_RESTORE_051_V46 -- the settings term, lost when
            // the tree was reset and V38 re-anchored onto this design.
            MyGUI::PointerManager::getInstance().setVisible(
                windowManager->getCursorVisible()
                || (windowManager->isSettingsWindowVisible()
                       && SDL_IsTextInputActive() == SDL_FALSE)
                || mControllerManager->tspMouseUsableNow());"""))

EDITS.append(("normal path",
"""        MyGUI::PointerManager::getInstance().setVisible(
            windowManager->getCursorVisible()
            || mControllerManager->tspMouseUsableNow());""",
"""        // TSP_SETTINGS_CURSOR_RESTORE_051_V46 -- see the disableControls path.
        MyGUI::PointerManager::getInstance().setVisible(
            windowManager->getCursorVisible()
            || (windowManager->isSettingsWindowVisible()
                   && SDL_IsTextInputActive() == SDL_FALSE)
            || mControllerManager->tspMouseUsableNow());"""))

def survey(text, why):
    print("      %s" % why)
    print("      --- every PointerManager setVisible site ---")
    for num, line in enumerate(text.splitlines(), 1):
        if "PointerManager" in line or "tspMouseUsableNow" in line:
            print("      %5d | %s" % (num, line.rstrip()))
    print("      --- end survey ---")

def balanced(text):
    for open_ch, close_ch in (("{", "}"), ("(", ")")):
        if text.count(open_ch) != text.count(close_ch):
            print("FAIL: brace/paren imbalance: %s=%d %s=%d"
                  % (open_ch, text.count(open_ch), close_ch, text.count(close_ch)))
            return False
    return True

if not os.path.exists(IM):
    print("FAIL: missing %s" % IM)
    sys.exit(1)

with io.open(IM, encoding="utf-8") as fh:
    original = fh.read()

if "SDL_IsTextInputActive" not in original:
    print("FAIL: inputmanagerimp.cpp does not already call SDL_IsTextInputActive();")
    print("      SDL may not be included. Nothing written.")
    sys.exit(1)
print("OK: precondition - SDL_IsTextInputActive already used in this file")

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
        survey(original, "The file does not look the way V46 expects.")
        print("      Nothing written.")
        sys.exit(1)
    text = text.replace(old, new, 1)
    print("OK: %s" % label)
    applied += 1

if not balanced(text):
    print("      Nothing written.")
    sys.exit(1)

if text.count("isSettingsWindowVisible()") != 2:
    print("FAIL: expected exactly 2 isSettingsWindowVisible() calls, found %d"
          % text.count("isSettingsWindowVisible()"))
    sys.exit(1)
if text.count("mControllerManager->tspMouseUsableNow()") != 2:
    print("FAIL: expected exactly 2 tspMouseUsableNow() calls, found %d"
          % text.count("mControllerManager->tspMouseUsableNow()"))
    sys.exit(1)
if text.count("windowManager->getCursorVisible()") != 2:
    print("FAIL: expected exactly 2 getCursorVisible() calls, found %d"
          % text.count("windowManager->getCursorVisible()"))
    sys.exit(1)
print("OK: both pointer sites carry all three terms")

if applied == 0:
    print("VERIFIED: v46 already present, nothing written.")
    sys.exit(0)

backup = "%s.before-v46-%s" % (IM, time.strftime("%Y%m%d-%H%M%S"))
with io.open(backup, "w", encoding="utf-8", newline="") as fh:
    fh.write(original)
with io.open(IM, "w", encoding="utf-8", newline="") as fh:
    fh.write(text)
print("wrote %s (backup: %s)" % (IM, os.path.basename(backup)))

with io.open(IM, encoding="utf-8") as fh:
    if MARK not in fh.read():
        print("FAIL: marker missing after write")
        sys.exit(1)

print("VERIFIED: v46 present, settings pointer restored at both sites (%d applied, %d present)"
      % (applied, skipped))
