"""TSP_TEXT_HANDOFF_051_V51 -- the engine stops fighting the helper's MENU toggle."""

import io
import os
import sys
import time

SRC = os.environ.get("TSPSRC", "/root/openmw-0.51-tsp-src")
CM = os.environ.get("TSPCM", os.path.join(SRC, "apps/openmw/mwinput/controllermanager.cpp"))
IM = os.environ.get("TSPIM", os.path.join(SRC, "apps/openmw/mwinput/inputmanagerimp.cpp"))

MARK = "TSP_TEXT_HANDOFF_051_V51"

EDITS = []

EDITS.append((CM, "cpp: MENU hands the text toggle back to the helper",
"""                tspSetTextSuppressed(!tspTextSuppressed());""",
"""                // TSP_TEXT_HANDOFF_051_V51 -- the helper owns MENU in BOTH
                // directions. It eats the button while it holds the pad, and it
                // still sees it after yielding (line 564 of the helper). The
                // engine running its own toggle over the top is what made text
                // impossible to re-enable. Engine: hands off.
                Log(Debug::Info) << "TSP_TEXT_HANDOFF_051_V51 menu=tap action=helper-owned";"""))

EDITS.append((CM, "cpp: bare R3 forces text back",
"""        if (arg.button == SDL_CONTROLLER_BUTTON_LEFTSTICK)
        {
            tspSetMouseMode(!mTspMouseMode);
            return true;
        }""",
"""        if (arg.button == SDL_CONTROLLER_BUTTON_LEFTSTICK)
        {
            tspSetMouseMode(!mTspMouseMode);
            return true;
        }
        // TSP_TEXT_HANDOFF_051_V51 -- bare R3 forces the text controls back.
        // Safe: the chord layer only reads buttons while MENU is HELD, so this
        // cannot collide with MENU+R3 = quick slot 9.
        if (arg.button == SDL_CONTROLLER_BUTTON_RIGHTSTICK)
        {
            if (std::FILE* tspReset = std::fopen("/tmp/openmw-tsp-text-reset", "w"))
            {
                std::fputs("1\\n", tspReset);
                std::fclose(tspReset);
            }
            Log(Debug::Info) << "TSP_TEXT_HANDOFF_051_V51 r3=force-text-reset";
            return true;
        }"""))

EDITS.append((IM, "im: the flag means only 'the game wants text', plus the R3 blackout",
"""            bool tspTextOff = false;
            if (std::FILE* tspOffFile = std::fopen("/tmp/openmw-tsp-text-off", "r"))
            {
                tspTextOff = true;
                std::fclose(tspOffFile);
            }
            const bool tspWantHelper = tspTextEntryActive && !tspTextOff;""",
"""            // TSP_TEXT_HANDOFF_051_V51 -- the flag now means ONLY "the game wants
            // text here". Dismissal is the helper's suppress_auto_text, which is
            // where it always lived. The engine no longer has a competing bit.
            //
            // R3 blackout: hold the flag away for a few frames so the helper,
            // which polls every TICK_MS (10ms), actually observes !active and
            // resets. Removing and recreating within one frame is invisible to it.
            static int tspTextResetFrames = 0;
            if (std::FILE* tspResetFile = std::fopen("/tmp/openmw-tsp-text-reset", "r"))
            {
                std::fclose(tspResetFile);
                std::remove("/tmp/openmw-tsp-text-reset");
                tspTextResetFrames = 15;
                std::fprintf(stderr, "TSP_TEXT_HANDOFF_051_V51 blackout=start\\n");
                std::fflush(stderr);
            }
            if (tspTextResetFrames > 0)
                --tspTextResetFrames;
            const bool tspWantHelper = tspTextEntryActive && tspTextResetFrames == 0;"""))

EDITS.append((IM, "im: a yield consumes only the mouse flag",
"""                tspMouseModeOwnedByHelper = false;
                std::remove("/tmp/openmw-tsp-mouse-mode");
                std::remove("/tmp/openmw-tsp-text-active");
                // TSP_TEXT_TOGGLE_051_V50 -- and record that the user asked for it.
                // Without this the per-frame reconcile above would hand the pad
                // straight back to the helper on the very next frame.
                if (std::FILE* tspOffWrite = std::fopen("/tmp/openmw-tsp-text-off", "w"))
                {
                    std::fputs("1\\n", tspOffWrite);
                    std::fclose(tspOffWrite);
                }""",
"""                // TSP_TEXT_HANDOFF_051_V51 -- consume the yield flag ONLY, so a
                // yield can never turn the pointer on (the V49 fix). Deleting the
                // text flag here as well is what disabled the helper's own route
                // back into TEXT: its guard at line 564 requires that flag.
                tspMouseModeOwnedByHelper = false;
                std::remove("/tmp/openmw-tsp-mouse-mode");"""))


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

if "TSP_TEXT_TOGGLE_051_V50" not in files[CM] or "TSP_TEXT_TOGGLE_051_V50" not in files[IM]:
    print("FAIL: V50 is not present in both files. Apply V50 first. Nothing written.")
    sys.exit(1)
print("OK: precondition - V50 present in both files")

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

if "tspSetTextSuppressed(!tspTextSuppressed());" in cm:
    print("FAIL: the engine still runs a competing MENU text toggle")
    sys.exit(1)
if "tspSetMouseMode(!mTspMouseMode);" not in cm:
    print("FAIL: the L3 mouse toggle disappeared")
    sys.exit(1)
if cm.count("SDL_CONTROLLER_BUTTON_RIGHTSTICK") < 2:
    print("FAIL: expected R3 in both the chord layer and the new reset branch")
    sys.exit(1)
if cm.count('"/tmp/openmw-tsp-text-reset"') != 1:
    print("FAIL: expected exactly 1 R3 reset write")
    sys.exit(1)
yield_start = im.index("TSP_TEXT_HANDOFF_051_V51 -- consume the yield flag ONLY")
yield_end = im.index("std::fflush(stderr);", yield_start)
if 'openmw-tsp-text-active' in im[yield_start:yield_end]:
    print("FAIL: the yield branch still deletes the text flag -- that is the bug")
    sys.exit(1)
if im.count('std::fopen("/tmp/openmw-tsp-text-active", "w")') != 1:
    print("FAIL: the engine no longer creates the text flag")
    sys.exit(1)
if im.count("tspTextResetFrames") != 5:
    print("FAIL: the R3 blackout counter is not wired correctly (found %d refs)"
          % im.count("tspTextResetFrames"))
    sys.exit(1)
print("OK: helper owns MENU, engine owns L3 and R3, text flag survives a yield")

if applied == 0:
    print("VERIFIED: v51 already present, nothing written.")
    sys.exit(0)

stamp = time.strftime("%Y%m%d-%H%M%S")
for path, text in pending.items():
    if text != files[path]:
        backup = "%s.before-v51-%s" % (path, stamp)
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

print("VERIFIED: v51 present in both files (%d applied, %d already present)"
      % (applied, skipped))
