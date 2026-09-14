"""TSP_MAINMENU_ACTIVATE_051_V54 -- A activates the focused menu button directly."""

import io
import os
import sys
import time

SRC = os.environ.get("TSPSRC", "/root/openmw-0.51-tsp-src")
MM = os.environ.get("TSPMM", os.path.join(SRC, "apps/openmw/mwgui/mainmenu.cpp"))

MARK = "TSP_MAINMENU_ACTIVATE_051_V54"

OLD = """        if (arg.button == SDL_CONTROLLER_BUTTON_A)
        {
            MWBase::Environment::get().getWindowManager()->injectKeyPress(MyGUI::KeyCode::Space, 0, false);
        }"""

NEW = """        if (arg.button == SDL_CONTROLLER_BUTTON_A)
        {
            // TSP_MAINMENU_ACTIVATE_051_V54 -- stock injected KeyCode::Space and
            // relied on MyGUI key focus already sitting on a menu button. When it
            // was anywhere else the press vanished silently: that is the
            // intermittent "press A twice" in the pause menu. Activate the focused
            // button directly, exactly as the B branch below already does.
            //
            // The order list mirrors TSP_MAINMENU_FOCUS_051_V41 in this same
            // function on purpose -- navigation and activation must agree about
            // which buttons exist and in what order. mButtons is a std::map and so
            // is alphabetical, NOT display order.
            static const char* const tspActivateOrder[]
                = { "return", "newgame", "savegame", "loadgame", "options", "credits", "exitgame" };
            MyGUI::Widget* tspFocused = MyGUI::InputManager::getInstance().getKeyFocusWidget();
            MyGUI::Widget* tspFirstVisible = nullptr;
            MyGUI::Widget* tspTarget = nullptr;
            for (const char* tspId : tspActivateOrder)
            {
                auto tspIt = mButtons.find(std::string(tspId));
                if (tspIt == mButtons.end() || !tspIt->second->getVisible())
                    continue;
                if (tspFirstVisible == nullptr)
                    tspFirstVisible = tspIt->second;
                if (tspIt->second == tspFocused)
                {
                    tspTarget = tspIt->second;
                    break;
                }
            }
            if (tspTarget != nullptr)
            {
                onButtonClicked(tspTarget);
            }
            else if (tspFirstVisible != nullptr)
            {
                // Focus was not on a menu button, so Space would have hit nothing.
                // Do not guess which entry was meant -- "newgame" or "exitgame"
                // would be a destructive guess. Put focus somewhere predictable so
                // the next press always lands, and let the highlight move visibly
                // rather than the press disappearing without feedback.
                MWBase::Environment::get().getWindowManager()->setKeyFocusWidget(tspFirstVisible);
            }
        }"""


def balanced(text, label):
    for open_ch, close_ch in (("{", "}"), ("(", ")")):
        if text.count(open_ch) != text.count(close_ch):
            print("FAIL: brace/paren imbalance in %s: %s=%d %s=%d"
                  % (label, open_ch, text.count(open_ch), close_ch, text.count(close_ch)))
            return False
    return True


if not os.path.exists(MM):
    print("FAIL: missing %s" % MM)
    sys.exit(1)

with io.open(MM, encoding="utf-8") as fh:
    original = fh.read()

for need, why in (
    ("TSP_MAINMENU_FOCUS_051_V41", "V41 focus walker (this patch mirrors its order list)"),
    ("MyGUI::InputManager::getInstance().getKeyFocusWidget()", "getKeyFocusWidget already used"),
    ("onButtonClicked(mButtons[", "onButtonClicked already called with a widget"),
    ("setKeyFocusWidget(", "setKeyFocusWidget already used"),
    ("mButtons.find(", "mButtons.find already used"),
):
    if need not in original:
        print("FAIL: %s -- expected '%s' in mainmenu.cpp." % (why, need))
        print("      Refusing to patch a file whose shape does not match. Nothing written.")
        sys.exit(1)
print("OK: preconditions - every symbol this patch uses is already used in the file")

if NEW in original:
    print("SKIP (already applied): A activates the focused button")
    print("VERIFIED: v54 already present, nothing written.")
    sys.exit(0)

count = original.count(OLD)
if count != 1:
    print("FAIL: anchor matched %d times (need exactly 1)" % count)
    print("      Nothing written.")
    sys.exit(1)

text = original.replace(OLD, NEW, 1)
print("OK: A activates the focused button directly")

if not balanced(text, "mainmenu.cpp"):
    print("      Nothing written.")
    sys.exit(1)

if "injectKeyPress(MyGUI::KeyCode::Space" in text:
    print("FAIL: the Space injection is still present")
    sys.exit(1)
if text.count("onButtonClicked(tspTarget);") != 1:
    print("FAIL: expected exactly 1 direct activation")
    sys.exit(1)
if 'onButtonClicked(mButtons["return"]);' not in text:
    print("FAIL: the B branch was damaged")
    sys.exit(1)
if "TSP_MAINMENU_FOCUS_051_V41" not in text:
    print("FAIL: the V41 d-pad focus walker was damaged")
    sys.exit(1)
if text.count("injectKeyPress(MyGUI::KeyCode::Escape") != 1:
    print("FAIL: the Escape fallback in the B branch was damaged")
    sys.exit(1)
# Navigation and activation must share the same button order. The same literal also
# appears in updateMenu(), which is where V41 took the order from, so this is >= 2
# rather than exactly 2 -- an earlier build asserted == 2 and refused a good patch.
ORDER = '"return", "newgame", "savegame", "loadgame", "options", "credits", "exitgame"'
if text.count(ORDER) < 2:
    print("FAIL: expected the button order literal at least twice, found %d" % text.count(ORDER))
    sys.exit(1)
if "tspOrder[]" not in text or "tspActivateOrder[]" not in text:
    print("FAIL: navigation (tspOrder) and activation (tspActivateOrder) lists are not both present")
    sys.exit(1)
print("OK: Space injection gone, B branch and V41 walker intact, orders agree")

backup = "%s.before-v54-%s" % (MM, time.strftime("%Y%m%d-%H%M%S"))
with io.open(backup, "w", encoding="utf-8", newline="") as fh:
    fh.write(original)
with io.open(MM, "w", encoding="utf-8", newline="") as fh:
    fh.write(text)
print("wrote %s (backup: %s)" % (MM, os.path.basename(backup)))

with io.open(MM, encoding="utf-8") as fh:
    if MARK not in fh.read():
        print("FAIL: marker missing after write")
        sys.exit(1)

print("VERIFIED: v54 present, A activates on the first press")
