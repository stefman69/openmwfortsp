import io
import os
import sys
import time

SRC = os.environ.get("TSPSRC", "/root/openmw-0.51-tsp-src")
IM = os.environ.get("TSPIM", os.path.join(SRC, "apps/openmw/mwinput/inputmanagerimp.cpp"))

MARK = "TSP_CURSOR_POLICY_051_V48"

SPAN_START = "        // TSP_VISIBLE_CURSOR_051_V47 -- all one-token retunable."
SPAN_END = "            tspCursor->setVisible(true);"

REPLACEMENT = """        // TSP_CURSOR_POLICY_051_V48 -- all one-token retunable.
        // Morrowind's own arrow: the same texture OpenMW's ArrowPointerImage
        // resource uses. 32x32, hot spot (7,0) per openmw_pointer.xml, so the
        // widget is offset by -7 in x to put the tip on the point.
        const char* const sTspCursorTexture = "textures\\\\tx_cursor.dds";
        constexpr int sTspCursorSize = 32;
        constexpr int sTspCursorHotX = -7;
        constexpr int sTspCursorHotY = 0;
        // TSP_CURSOR_POLICY_051_V48 -- where a pointer may exist at all.
        bool tspCursorAllowed(MWBase::WindowManager* windowManager)
        {
            // Never outside a GUI. getCursorVisible() stays true after a menu
            // closes, which is why a dead pointer sat on the gameplay screen.
            if (!windowManager->isGuiMode())
                return false;
            // Settings FIRST: it is opened through the pause menu, so the
            // main-menu test below would otherwise kill the one place Steve
            // most wants a pointer.
            if (windowManager->isSettingsWindowVisible())
                return true;
            if (windowManager->containsMode(MWGui::GM_Loading)
                || windowManager->containsMode(MWGui::GM_LoadingWallpaper))
                return false;
            if (windowManager->containsMode(MWGui::GM_MainMenu))
                return false;
            return true;
        }
        // TSP_CURSOR_POLICY_051_V48
        void tspDrawCursor(MWBase::WindowManager* windowManager, bool wanted)
        {
            static MyGUI::ImageBox* tspCursor = nullptr;
            if (!wanted || !tspCursorAllowed(windowManager))
            {
                if (tspCursor != nullptr)
                    tspCursor->setVisible(false);
                return;
            }
            if (tspCursor == nullptr)
            {
                tspCursor = MyGUI::Gui::getInstance().createWidget<MyGUI::ImageBox>(
                    "ImageBox",
                    MyGUI::IntCoord(0, 0, sTspCursorSize, sTspCursorSize),
                    MyGUI::Align::Default,
                    "Popup");
                tspCursor->setImageTexture(sTspCursorTexture);
                // Without this the cursor widget swallows the clicks it is
                // supposed to be pointing at.
                tspCursor->setNeedMouseFocus(false);
            }
            int tspMouseX = 0;
            int tspMouseY = 0;
            windowManager->getMousePosition(tspMouseX, tspMouseY);
            tspCursor->setPosition(
                tspMouseX + sTspCursorHotX, tspMouseY + sTspCursorHotY);
            tspCursor->setVisible(true);"""

INCLUDE_OLD = "#include <MyGUI_PointerManager.h>"
INCLUDE_NEW = """#include <MyGUI_PointerManager.h>
#include <MyGUI_ImageBox.h>
#include "../mwgui/mode.hpp\""""

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

if "tspDrawCursor" not in original:
    print("FAIL: V47 is not present in this file. Apply V47 first. Nothing written.")
    sys.exit(1)
print("OK: precondition - V47 cursor helper present")

text = original
applied = 0

if "MyGUI_ImageBox.h" in text and "mwgui/mode.hpp" in text:
    print("SKIP (already applied): includes")
else:
    if text.count(INCLUDE_OLD) != 1:
        print("FAIL: include anchor matched %d times (need exactly 1)" % text.count(INCLUDE_OLD))
        sys.exit(1)
    text = text.replace(INCLUDE_OLD, INCLUDE_NEW, 1)
    print("OK: includes (MyGUI_ImageBox.h, mwgui/mode.hpp)")
    applied += 1

if MARK in text:
    print("SKIP (already applied): cursor block")
else:
    if text.count(SPAN_START) != 1:
        print("FAIL: span start matched %d times (need exactly 1)" % text.count(SPAN_START))
        sys.exit(1)
    if text.count(SPAN_END) != 1:
        print("FAIL: span end matched %d times (need exactly 1)" % text.count(SPAN_END))
        sys.exit(1)
    start = text.index(SPAN_START)
    end = text.index(SPAN_END) + len(SPAN_END)
    if end <= start:
        print("FAIL: span end precedes span start")
        sys.exit(1)
    text = text[:start] + REPLACEMENT + text[end:]
    print("OK: cursor block replaced (%d chars -> %d chars)" % (end - start, len(REPLACEMENT)))
    applied += 1

if not balanced(text):
    print("      Nothing written.")
    sys.exit(1)

checks = [
    ("MyGUI::ImageBox* tspCursor", 1, "cursor is an ImageBox"),
    ("MyGUI::TextBox* tspCursor", 0, "no TextBox cursor left behind"),
    ("sTspCursorGlyph", 0, "the old + glyph constant is gone"),
    ("tspDrawCursor(windowManager,", 2, "both call sites still present"),
    ("void tspDrawCursor(", 1, "exactly one definition"),
    ("bool tspCursorAllowed(", 1, "policy function defined"),
    ("!tspCursorAllowed(windowManager)", 1, "policy actually called from the draw"),
    ("setNeedMouseFocus(false)", 1, "click passthrough kept"),
    ("containsMode(MWGui::GM_LoadingWallpaper)", 1, "loading screens excluded"),
    ("containsMode(MWGui::GM_MainMenu)", 1, "main and pause menu excluded"),
]
for needle, want, why in checks:
    got = text.count(needle)
    if got != want:
        print("FAIL: %s -- expected %d occurrence(s) of '%s', found %d" % (why, want, needle, got))
        sys.exit(1)
print("OK: all %d post-transform checks passed" % len(checks))

if text.index("isSettingsWindowVisible()") > text.index("containsMode(MWGui::GM_MainMenu)"):
    print("FAIL: the Settings check must come before the main-menu check")
    sys.exit(1)
print("OK: Settings is checked before the main-menu exclusion")

if applied == 0:
    print("VERIFIED: v48 already present, nothing written.")
    sys.exit(0)

backup = "%s.before-v48-%s" % (IM, time.strftime("%Y%m%d-%H%M%S"))
with io.open(backup, "w", encoding="utf-8", newline="") as fh:
    fh.write(original)
with io.open(IM, "w", encoding="utf-8", newline="") as fh:
    fh.write(text)
print("wrote %s (backup: %s)" % (IM, os.path.basename(backup)))

with io.open(IM, encoding="utf-8") as fh:
    if MARK not in fh.read():
        print("FAIL: marker missing after write")
        sys.exit(1)

print("VERIFIED: v48 present, real cursor + placement policy (%d edits)" % applied)
