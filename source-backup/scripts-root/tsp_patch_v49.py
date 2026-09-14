"""TSP_INPUT_MODE_051_V49 -- MENU owns TEXT<->CONTROLLER, L3 owns the mouse.
The TEXT/CONTROLLER mode IS /tmp/openmw-tsp-text-active: the helper grabs the pad
only while it exists, so the engine drives the helper by writing/removing it.
No new member, no header edit, no helper rebuild.
"""

import io
import os
import sys
import time

SRC = os.environ.get("TSPSRC", "/root/openmw-0.51-tsp-src")
CM = os.environ.get("TSPCM", os.path.join(SRC, "apps/openmw/mwinput/controllermanager.cpp"))
IM = os.environ.get("TSPIM", os.path.join(SRC, "apps/openmw/mwinput/inputmanagerimp.cpp"))

MARK = "TSP_INPUT_MODE_051_V49"

EDITS = []

EDITS.append((CM, "cpp: text-mode helpers in the existing anonymous namespace",
"""        constexpr unsigned int sTspMenuDoubleTapMs = 400;""",
"""        constexpr unsigned int sTspMenuDoubleTapMs = 400;
        // TSP_INPUT_MODE_051_V49 -- the TEXT/CONTROLLER mode IS this file. The
        // text helper holds EVIOCGRAB only while it exists, so writing and
        // removing it is how the engine drives the helper. One copy of the state,
        // shared by both processes, so they cannot disagree about the mode.
        const char* const sTspTextFlag = "/tmp/openmw-tsp-text-active";
        const char* const sTspHelperYieldFlag = "/tmp/openmw-tsp-mouse-mode";
        bool tspTextModeOn()
        {
            if (std::FILE* tspFile = std::fopen(sTspTextFlag, "r"))
            {
                std::fclose(tspFile);
                return true;
            }
            return false;
        }
        void tspSetTextMode(bool on)
        {
            if (on)
            {
                if (std::FILE* tspFile = std::fopen(sTspTextFlag, "w"))
                {
                    std::fputs("1\\n", tspFile);
                    std::fclose(tspFile);
                }
            }
            else
            {
                std::remove(sTspTextFlag);
            }
            Log(Debug::Info) << "TSP_INPUT_MODE_051_V49 textMode=" << (on ? 1 : 0);
        }"""))

EDITS.append((CM, "cpp: MENU switches TEXT <-> CONTROLLER instead of the mouse",
"""                mTspLastMenuTapMs = tspNowMs;
                tspSetMouseMode(!mTspMouseMode);""",
"""                mTspLastMenuTapMs = tspNowMs;
                // TSP_INPUT_MODE_051_V49 -- MENU switches TEXT <-> CONTROLLER and
                // never touches the mouse. L3 owns the mouse, exclusively.
                tspSetTextMode(!tspTextModeOn());"""))

EDITS.append((CM, "cpp: a menu change resets to CONTROLLER with no pointer",
"""                mTspLastTopWindow = tspTopNow;
                mTspLastMenuTapMs = 0;""",
"""                mTspLastTopWindow = tspTopNow;
                mTspLastMenuTapMs = 0;
                // TSP_INPUT_MODE_051_V49 -- every menu opens in CONTROLLER with the
                // pointer hidden. Leaving and coming back starts clean.
                tspSetTextMode(false);
                std::remove(sTspHelperYieldFlag);"""))

EDITS.append((IM, "im: stop auto-creating the text flag",
"""            if (tspTextEntryActive)
            {
                if (std::FILE* flag = std::fopen(
                        "/tmp/openmw-tsp-text-active", "w"))
                {
                    std::fputs("1\\n", flag);
                    std::fclose(flag);
                }
            }""",
"""            if (tspTextEntryActive)
            {
                // TSP_INPUT_MODE_051_V49 -- deliberately does NOT create the flag.
                // Every menu that focuses an edit box turns SDL text input on, and
                // auto-writing the flag here is what made spell making, enchanting
                // and the save dialog seize the pad the moment they opened. Menus
                // now start in CONTROLLER; MENU asks for text.
            }"""))

EDITS.append((IM, "im: the helper's flag means 'leave TEXT', not 'mouse on'",
"""            if (tspHelperPointing && !mControllerManager->tspMouseModeActive())
            {
                tspMouseModeOwnedByHelper = true;
                mControllerManager->tspSetMouseMode(true);""",
"""            if (tspHelperPointing)
            {
                // TSP_INPUT_MODE_051_V49 -- the helper writes this file when MENU
                // was pressed while IT held the grab: the one MENU press the engine
                // cannot see. That means "leave TEXT", NOT "turn on the mouse".
                // Consume both flags and fall back to CONTROLLER. Treating it as a
                // mouse request is what stuck the pointer on after a text menu.
                tspMouseModeOwnedByHelper = false;
                std::remove("/tmp/openmw-tsp-mouse-mode");
                std::remove("/tmp/openmw-tsp-text-active");"""))


def balanced(text, label):
    for open_ch, close_ch in (("{", "}"), ("(", ")")):
        if text.count(open_ch) != text.count(close_ch):
            print("FAIL: brace/paren imbalance in %s: %s=%d %s=%d"
                  % (label, open_ch, text.count(open_ch), close_ch, text.count(close_ch)))
            return False
    return True


for path in (CM, IM):
    if not os.path.exists(path):
        print("FAIL: missing %s" % path)
        sys.exit(1)

files = {}
for path, label, old, new in EDITS:
    if path not in files:
        with io.open(path, encoding="utf-8") as fh:
            files[path] = fh.read()

if "#include <cstdio>" not in files[CM]:
    print("FAIL: controllermanager.cpp does not include <cstdio>. Nothing written.")
    sys.exit(1)
if "tspMouseModeOwnedByHelper" not in files[IM]:
    print("FAIL: V47 is not present in inputmanagerimp.cpp. Nothing written.")
    sys.exit(1)
if "SDL_CONTROLLER_BUTTON_LEFTSTICK" not in files[CM]:
    print("FAIL: the L3 mouse toggle is missing. Nothing written.")
    sys.exit(1)
print("OK: preconditions - <cstdio>, V47, and the L3 toggle are all present")

pending = dict(files)
applied = skipped = 0

for path, label, old, new in EDITS:
    text = pending[path]
    if new in text:
        print("SKIP (already applied): %s" % label)
        skipped += 1
        continue
    count = text.count(old)
    if count != 1:
        print("FAIL: anchor for '%s' matched %d times (need exactly 1) in %s"
              % (label, count, os.path.basename(path)))
        print("      Nothing written.")
        sys.exit(1)
    pending[path] = text.replace(old, new, 1)
    print("OK: %s" % label)
    applied += 1

for path, text in pending.items():
    if not balanced(text, os.path.basename(path)):
        print("      Nothing written.")
        sys.exit(1)

cm = pending[CM]
im = pending[IM]

if "tspSetMouseMode(!mTspMouseMode);" not in cm:
    print("FAIL: the L3 mouse toggle disappeared")
    sys.exit(1)
if cm.count("tspSetTextMode(!tspTextModeOn());") != 1:
    print("FAIL: expected exactly 1 MENU text toggle")
    sys.exit(1)
if cm.count("tspSetTextMode(false);") != 1:
    print("FAIL: expected exactly 1 window-change reset")
    sys.exit(1)
if im.count('mControllerManager->tspSetMouseMode(true);') != 0:
    print("FAIL: the helper flag can still force mouse mode on")
    sys.exit(1)
if im.count('std::remove("/tmp/openmw-tsp-text-active")') < 2:
    print("FAIL: the text flag is no longer removed on menu close")
    sys.exit(1)
print("OK: MENU owns text, L3 owns the mouse, neither owns the other")

if applied == 0:
    print("VERIFIED: v49 already present, nothing written.")
    sys.exit(0)

stamp = time.strftime("%Y%m%d-%H%M%S")
for path, text in pending.items():
    if text != files[path]:
        backup = "%s.before-v49-%s" % (path, stamp)
        with io.open(backup, "w", encoding="utf-8", newline="") as fh:
            fh.write(files[path])
        with io.open(path, "w", encoding="utf-8", newline="") as fh:
            fh.write(text)
        print("wrote %s (backup: %s)" % (path, os.path.basename(backup)))

for path in pending:
    with io.open(path, encoding="utf-8") as fh:
        if MARK not in fh.read():
            print("FAIL: marker missing from %s after write" % os.path.basename(path))
            sys.exit(1)

print("VERIFIED: v49 present in both files (%d applied, %d already present)"
      % (applied, skipped))
