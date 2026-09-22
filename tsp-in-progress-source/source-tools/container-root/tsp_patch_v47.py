import io
import os
import sys
import time

SRC = os.environ.get("TSPSRC", "/root/openmw-0.51-tsp-src")
IM = os.environ.get("TSPIM", os.path.join(SRC, "apps/openmw/mwinput/inputmanagerimp.cpp"))

MARK = "TSP_VISIBLE_CURSOR_051_V47"

EDITS = []

EDITS.append(("cursor helper in an anonymous namespace",
"""namespace MWInput
{
    InputManager::InputManager(SDL_Window* window,""",
"""namespace MWInput
{
    namespace
    {
        // TSP_VISIBLE_CURSOR_051_V47 -- all one-token retunable.
        // A TextBox with the "ProgressText" skin, not an ImageBox with
        // tsp_cursor.png: that skin is already known to render in this file, and
        // it cannot fail on a texture that did not survive the tree reset.
        const char* const sTspCursorGlyph = "+";
        constexpr int sTspCursorFontHeight = 30;
        constexpr int sTspCursorBoxSize = 48;
        constexpr int sTspCursorOffsetX = -9;
        constexpr int sTspCursorOffsetY = -17;
        // TSP_VISIBLE_CURSOR_051_V47
        void tspDrawCursor(MWBase::WindowManager* windowManager, bool wanted)
        {
            static MyGUI::TextBox* tspCursor = nullptr;
            if (!wanted)
            {
                if (tspCursor != nullptr)
                    tspCursor->setVisible(false);
                return;
            }
            if (tspCursor == nullptr)
            {
                tspCursor = MyGUI::Gui::getInstance().createWidget<MyGUI::TextBox>(
                    "ProgressText",
                    MyGUI::IntCoord(0, 0, sTspCursorBoxSize, sTspCursorBoxSize),
                    MyGUI::Align::Default,
                    "Popup");
                tspCursor->setTextAlign(MyGUI::Align::Left | MyGUI::Align::Top);
                tspCursor->setFontHeight(sTspCursorFontHeight);
                tspCursor->setCaption(sTspCursorGlyph);
                // Without this the cursor widget swallows the clicks it is
                // supposed to be pointing at.
                tspCursor->setNeedMouseFocus(false);
            }
            int tspMouseX = 0;
            int tspMouseY = 0;
            windowManager->getMousePosition(tspMouseX, tspMouseY);
            tspCursor->setPosition(
                tspMouseX + sTspCursorOffsetX, tspMouseY + sTspCursorOffsetY);
            tspCursor->setVisible(true);
        }
    }
    InputManager::InputManager(SDL_Window* window,"""))

EDITS.append(("draw cursor: disableControls path",
"""            mMouseManager->updateCursorMode();
            mInputWrapper->setMouseVisible(false);""",
"""            mMouseManager->updateCursorMode();
            mInputWrapper->setMouseVisible(false);
            // TSP_VISIBLE_CURSOR_051_V47 -- computes all three terms itself, so
            // this is independent of whether V46 widened PointerManager's call.
            tspDrawCursor(windowManager,
                windowManager->getCursorVisible()
                    || (windowManager->isSettingsWindowVisible()
                           && SDL_IsTextInputActive() == SDL_FALSE)
                    || mControllerManager->tspMouseUsableNow());"""))

EDITS.append(("draw cursor: normal path",
"""        if (Settings::input().mEnableGyroscope)""",
"""        // TSP_VISIBLE_CURSOR_051_V47
        tspDrawCursor(windowManager,
            windowManager->getCursorVisible()
                || (windowManager->isSettingsWindowVisible()
                       && SDL_IsTextInputActive() == SDL_FALSE)
                || mControllerManager->tspMouseUsableNow());
        if (Settings::input().mEnableGyroscope)"""))

EDITS.append(("helper flag turns mouse mode ON, and only owns turning it OFF",
"""            if ((tspTextEntryActive || tspHelperPointing)
                && tspHelperPointing != mControllerManager->tspMouseModeActive())
            {
                mControllerManager->tspSetMouseMode(tspHelperPointing);""",
"""            // TSP_VISIBLE_CURSOR_051_V47 -- the old condition called
            // tspSetMouseMode(false) on EVERY frame whenever text entry was live
            // and the flag was absent, so MENU could never turn the mouse on
            // inside a save / enchanting / sell-stack menu.
            static bool tspMouseModeOwnedByHelper = false;
            if (tspHelperPointing && !mControllerManager->tspMouseModeActive())
            {
                tspMouseModeOwnedByHelper = true;
                mControllerManager->tspSetMouseMode(true);"""))

EDITS.append(("close out the reworked handshake",
"""                std::fprintf(stderr,
                    "TSP_MOUSE_MODE_051_V41 helperPointing=%d text=%d\\n",
                    tspHelperPointing ? 1 : 0,
                    tspTextEntryActive ? 1 : 0);
                std::fflush(stderr);
            }
        }""",
"""                std::fprintf(stderr,
                    "TSP_MOUSE_MODE_051_V41 helperPointing=%d text=%d\\n",
                    tspHelperPointing ? 1 : 0,
                    tspTextEntryActive ? 1 : 0);
                std::fflush(stderr);
            }
            else if (!tspHelperPointing && tspMouseModeOwnedByHelper)
            {
                // TSP_VISIBLE_CURSOR_051_V47 -- the helper reclaimed the pad.
                tspMouseModeOwnedByHelper = false;
                mControllerManager->tspSetMouseMode(false);
                std::fprintf(stderr, "TSP_VISIBLE_CURSOR_051_V47 helperReleased\\n");
                std::fflush(stderr);
            }
        }"""))

def survey(text, why):
    print("      %s" % why)
    for num, line in enumerate(text.splitlines(), 1):
        if ("PointerManager" in line or "tspMouseUsableNow" in line
                or "tspHelperPointing" in line or "mEnableGyroscope" in line):
            print("      %5d | %s" % (num, line.rstrip()))

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

for need, why in (
    ("SDL_IsTextInputActive", "SDL not reachable here"),
    ("MyGUI_TextBox.h", "MyGUI::TextBox not included"),
    ("MyGUI_Gui.h", "MyGUI::Gui not included"),
    ("tspMouseUsableNow", "V41 not present"),
):
    if need not in original:
        print("FAIL: %s (%s). Nothing written." % (why, need))
        sys.exit(1)
print("OK: preconditions - SDL, MyGUI::Gui, MyGUI::TextBox and V41 all present")

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
        survey(original, "The file does not look the way V47 expects.")
        print("      Nothing written.")
        sys.exit(1)
    text = text.replace(old, new, 1)
    print("OK: %s" % label)
    applied += 1

if not balanced(text):
    print("      Nothing written.")
    sys.exit(1)

if text.count("tspDrawCursor(windowManager,") != 2:
    print("FAIL: expected 2 tspDrawCursor call sites, found %d"
          % text.count("tspDrawCursor(windowManager,"))
    sys.exit(1)
if text.count("void tspDrawCursor(") != 1:
    print("FAIL: expected exactly 1 tspDrawCursor definition")
    sys.exit(1)
if "&& tspHelperPointing != mControllerManager->tspMouseModeActive())" in text:
    print("FAIL: the old every-frame force-off condition is still present")
    sys.exit(1)
if text.count("setNeedMouseFocus(false)") != 1:
    print("FAIL: cursor widget would swallow its own clicks")
    sys.exit(1)
print("OK: cursor drawn on both paths, force-off removed, click passthrough set")

if applied == 0:
    print("VERIFIED: v47 already present, nothing written.")
    sys.exit(0)

backup = "%s.before-v47-%s" % (IM, time.strftime("%Y%m%d-%H%M%S"))
with io.open(backup, "w", encoding="utf-8", newline="") as fh:
    fh.write(original)
with io.open(IM, "w", encoding="utf-8", newline="") as fh:
    fh.write(text)
print("wrote %s (backup: %s)" % (IM, os.path.basename(backup)))

with io.open(IM, encoding="utf-8") as fh:
    if MARK not in fh.read():
        print("FAIL: marker missing after write")
        sys.exit(1)

print("VERIFIED: v47 present, cursor is drawn (%d applied, %d present)" % (applied, skipped))
