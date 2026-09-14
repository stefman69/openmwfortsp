"""TSP_TEXT_TOGGLE_051_V50 -- text is automatic again; MENU dismisses it.
Fixes the V49 regression that made text entry unreachable (and would have
made the character-name screen unusable). Helper gets the pad exactly when
SDL text input is live AND the user has not dismissed it with MENU.
L3 still owns the mouse.
"""

import io
import os
import sys
import time

SRC = os.environ.get("TSPSRC", "/root/openmw-0.51-tsp-src")
CM = os.environ.get("TSPCM", os.path.join(SRC, "apps/openmw/mwinput/controllermanager.cpp"))
IM = os.environ.get("TSPIM", os.path.join(SRC, "apps/openmw/mwinput/inputmanagerimp.cpp"))

MARK = "TSP_TEXT_TOGGLE_051_V50"

EDITS = []

EDITS.append((CM, "cpp: the 'controller nav here' bit",
"""        const char* const sTspHelperYieldFlag = "/tmp/openmw-tsp-mouse-mode";""",
"""        const char* const sTspHelperYieldFlag = "/tmp/openmw-tsp-mouse-mode";
        // TSP_TEXT_TOGGLE_051_V50 -- "the user asked for controller nav in this
        // menu". Text is automatic; this is the dismiss. Cleared whenever the
        // active window changes, so it never leaks between menus.
        const char* const sTspTextOffFlag = "/tmp/openmw-tsp-text-off";
        bool tspTextSuppressed()
        {
            if (std::FILE* tspFile = std::fopen(sTspTextOffFlag, "r"))
            {
                std::fclose(tspFile);
                return true;
            }
            return false;
        }
        void tspSetTextSuppressed(bool off)
        {
            if (off)
            {
                if (std::FILE* tspFile = std::fopen(sTspTextOffFlag, "w"))
                {
                    std::fputs("1\\n", tspFile);
                    std::fclose(tspFile);
                }
            }
            else
            {
                std::remove(sTspTextOffFlag);
            }
            Log(Debug::Info) << "TSP_TEXT_TOGGLE_051_V50 textSuppressed=" << (off ? 1 : 0);
        }"""))

EDITS.append((CM, "cpp: MENU flips the dismiss bit, not the helper flag",
"""                tspSetTextMode(!tspTextModeOn());""",
"""                // TSP_TEXT_TOGGLE_051_V50 -- MENU no longer writes the helper's
                // flag directly. It flips "controller nav here", and the per-frame
                // reconcile in inputmanagerimp decides who gets the pad. Writing
                // the helper flag from here fought that reconcile and text never
                // came up at all -- that was the V49 regression.
                tspSetTextSuppressed(!tspTextSuppressed());"""))

EDITS.append((CM, "cpp: a menu change also clears the dismiss bit",
"""                tspSetTextMode(false);
                std::remove(sTspHelperYieldFlag);""",
"""                // TSP_TEXT_TOGGLE_051_V50 -- clear the dismiss too, so each menu
                // starts from the game's own idea of whether it needs text.
                tspSetTextSuppressed(false);
                tspSetTextMode(false);
                std::remove(sTspHelperYieldFlag);"""))

EDITS.append((IM, "im: reconcile the helper flag every frame",
"""        static bool tspPreviousTextEntryActive = false;""",
"""        // TSP_TEXT_TOGGLE_051_V50 -- reconcile EVERY frame, not only when SDL's
        // text state changes. MENU can flip the dismiss bit at any moment, so the
        // flag has to be recomputed continuously rather than latched on an edge.
        // The helper holds EVIOCGRAB exactly while this file exists.
        {
            bool tspTextOff = false;
            if (std::FILE* tspOffFile = std::fopen("/tmp/openmw-tsp-text-off", "r"))
            {
                tspTextOff = true;
                std::fclose(tspOffFile);
            }
            const bool tspWantHelper = tspTextEntryActive && !tspTextOff;
            bool tspHaveFlag = false;
            if (std::FILE* tspFlagFile = std::fopen("/tmp/openmw-tsp-text-active", "r"))
            {
                tspHaveFlag = true;
                std::fclose(tspFlagFile);
            }
            if (tspWantHelper && !tspHaveFlag)
            {
                if (std::FILE* tspNewFlag = std::fopen("/tmp/openmw-tsp-text-active", "w"))
                {
                    std::fputs("1\\n", tspNewFlag);
                    std::fclose(tspNewFlag);
                }
            }
            else if (!tspWantHelper && tspHaveFlag)
            {
                std::remove("/tmp/openmw-tsp-text-active");
            }
        }
        static bool tspPreviousTextEntryActive = false;"""))

EDITS.append((IM, "im: a helper yield must set the dismiss bit",
"""                std::remove("/tmp/openmw-tsp-mouse-mode");
                std::remove("/tmp/openmw-tsp-text-active");""",
"""                std::remove("/tmp/openmw-tsp-mouse-mode");
                std::remove("/tmp/openmw-tsp-text-active");
                // TSP_TEXT_TOGGLE_051_V50 -- and record that the user asked for it.
                // Without this the per-frame reconcile above would hand the pad
                // straight back to the helper on the very next frame.
                if (std::FILE* tspOffWrite = std::fopen("/tmp/openmw-tsp-text-off", "w"))
                {
                    std::fputs("1\\n", tspOffWrite);
                    std::fclose(tspOffWrite);
                }"""))


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

if "TSP_INPUT_MODE_051_V49" not in files[CM] or "TSP_INPUT_MODE_051_V49" not in files[IM]:
    print("FAIL: V49 is not present in both files. Apply V49 first. Nothing written.")
    sys.exit(1)
print("OK: precondition - V49 present in both files")

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

if cm.count("tspSetTextSuppressed(!tspTextSuppressed());") != 1:
    print("FAIL: expected exactly 1 MENU dismiss toggle")
    sys.exit(1)
if "tspSetTextMode(!tspTextModeOn());" in cm:
    print("FAIL: MENU still writes the helper flag directly -- that is the V49 bug")
    sys.exit(1)
if "tspSetMouseMode(!mTspMouseMode);" not in cm:
    print("FAIL: the L3 mouse toggle disappeared")
    sys.exit(1)
if im.count('std::fopen("/tmp/openmw-tsp-text-active", "w")') != 1:
    print("FAIL: the engine no longer creates the text flag -- text would be")
    print("      unreachable, which is exactly the V49 regression.")
    sys.exit(1)
if im.count('std::fopen("/tmp/openmw-tsp-text-off", "w")') != 1:
    print("FAIL: a helper yield does not latch the dismiss bit")
    sys.exit(1)
if cm.count("tspSetTextSuppressed(false);") != 1:
    print("FAIL: the window-change reset does not clear the dismiss bit")
    sys.exit(1)
print("OK: text is automatic, MENU dismisses, L3 still owns the mouse")

if applied == 0:
    print("VERIFIED: v50 already present, nothing written.")
    sys.exit(0)

stamp = time.strftime("%Y%m%d-%H%M%S")
for path, text in pending.items():
    if text != files[path]:
        backup = "%s.before-v50-%s" % (path, stamp)
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

print("VERIFIED: v50 present in both files (%d applied, %d already present)"
      % (applied, skipped))
