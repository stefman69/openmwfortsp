"""TSP_TEXT_INDICATOR_051_V52 -- the letter box follows the helper, not SDL."""

import io
import os
import sys
import time

SRC = os.environ.get("TSPSRC", "/root/openmw-0.51-tsp-src")
IM = os.environ.get("TSPIM", os.path.join(SRC, "apps/openmw/mwinput/inputmanagerimp.cpp"))

MARK = "TSP_TEXT_INDICATOR_051_V52"

EDITS = []

EDITS.append(("im: the indicator follows the helper's char file",
"""        if (tspTextEntryActive)
        {
            if (tspTextIndicator == nullptr)""",
"""        // TSP_TEXT_INDICATOR_051_V52 -- the on-screen letter box follows the
        // HELPER, not SDL. /tmp/openmw-tsp-text-char exists exactly while the
        // helper is in MODE_TEXT: set_mode(MODE_GAME) unlinks it (helper line
        // 358). Gating on SDL text input instead left the box on screen after
        // MENU dismissed text, because the edit box still held SDL focus.
        bool tspHelperTyping = false;
        if (std::FILE* tspCharProbe = std::fopen("/tmp/openmw-tsp-text-char", "r"))
        {
            tspHelperTyping = true;
            std::fclose(tspCharProbe);
        }
        if (tspHelperTyping)
        {
            if (tspTextIndicator == nullptr)"""))

EDITS.append(("im: destroy it every frame it is not wanted",
"""            if (captionBuffer[0] != '\\0')
            {
                const std::string caption(captionBuffer);
                if (caption != tspLastIndicatorCaption)
                {
                    tspTextIndicator->setCaption(caption);
                    tspLastIndicatorCaption = caption;
                }
            }
        }""",
"""            if (captionBuffer[0] != '\\0')
            {
                const std::string caption(captionBuffer);
                if (caption != tspLastIndicatorCaption)
                {
                    tspTextIndicator->setCaption(caption);
                    tspLastIndicatorCaption = caption;
                }
            }
        }
        else if (tspTextIndicator != nullptr)
        {
            // TSP_TEXT_INDICATOR_051_V52 -- hide the moment the helper stops
            // typing. The old code only destroyed the widget on an SDL text-input
            // edge, so a MENU dismiss left it floating over the menu.
            MyGUI::Gui::getInstance().destroyWidget(tspTextIndicator);
            tspTextIndicator = nullptr;
            tspLastIndicatorCaption.clear();
        }"""))


def balanced(text, label):
    for open_ch, close_ch in (("{", "}"), ("(", ")")):
        if text.count(open_ch) != text.count(close_ch):
            print("FAIL: brace/paren imbalance in %s: %s=%d %s=%d"
                  % (label, open_ch, text.count(open_ch), close_ch, text.count(close_ch)))
            return False
    return True


if not os.path.exists(IM):
    print("FAIL: missing %s" % IM)
    sys.exit(1)

with io.open(IM, encoding="utf-8") as fh:
    original = fh.read()

if "TSP_TEXT_HANDOFF_051_V51" not in original:
    print("FAIL: V51 is not present. Apply V51 first. Nothing written.")
    sys.exit(1)
if "tspTextIndicator" not in original:
    print("FAIL: the text indicator does not exist in this file. Nothing written.")
    sys.exit(1)
print("OK: preconditions - V51 present, indicator present")

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

if not balanced(text, "inputmanagerimp.cpp"):
    print("      Nothing written.")
    sys.exit(1)

if text.count("tspHelperTyping") != 3:
    print("FAIL: expected 3 tspHelperTyping references, found %d" % text.count("tspHelperTyping"))
    sys.exit(1)
if text.count("destroyWidget(tspTextIndicator)") != 2:
    print("FAIL: expected 2 destroy sites, found %d" % text.count("destroyWidget(tspTextIndicator)"))
    sys.exit(1)
if "if (tspTextEntryActive)\n        {\n            if (tspTextIndicator == nullptr)" in text:
    print("FAIL: the indicator still keys off SDL text input")
    sys.exit(1)
if text.count('std::fopen("/tmp/openmw-tsp-text-active", "w")') != 1:
    print("FAIL: the engine no longer creates the text flag")
    sys.exit(1)
print("OK: indicator follows the helper, destroyed whenever it is not typing")

if applied == 0:
    print("VERIFIED: v52 already present, nothing written.")
    sys.exit(0)

backup = "%s.before-v52-%s" % (IM, time.strftime("%Y%m%d-%H%M%S"))
with io.open(backup, "w", encoding="utf-8", newline="") as fh:
    fh.write(original)
with io.open(IM, "w", encoding="utf-8", newline="") as fh:
    fh.write(text)
print("wrote %s (backup: %s)" % (IM, os.path.basename(backup)))

with io.open(IM, encoding="utf-8") as fh:
    if MARK not in fh.read():
        print("FAIL: marker missing after write")
        sys.exit(1)

print("VERIFIED: v52 present (%d applied, %d already present)" % (applied, skipped))
