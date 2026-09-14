import sys, io, os, time

SRC = os.environ.get("TSPSRC", "/root/openmw-0.51-tsp-src")
CM  = os.path.join(SRC, "apps/openmw/mwinput/controllermanager.cpp")
CH  = os.path.join(SRC, "apps/openmw/mwinput/controllermanager.hpp")
IM  = os.path.join(SRC, "apps/openmw/mwinput/inputmanagerimp.cpp")
MM  = os.path.join(SRC, "apps/openmw/mwgui/mainmenu.cpp")

MARKS = ["TSP_MOUSE_MODE_051_V41", "TSP_MAINMENU_FOCUS_051_V41"]
EDITS = []

# ---- hpp -------------------------------------------------------------
EDITS.append((CH, "hpp: usable-now accessor", """        // TSP_MOUSE_MODE_051_V38
        bool tspMouseModeActive() const { return mTspMouseMode; }
        void tspSetMouseMode(bool on);""",
"""        // TSP_MOUSE_MODE_051_V38
        bool tspMouseModeActive() const { return mTspMouseMode; }
        void tspSetMouseMode(bool on);

        // TSP_MOUSE_MODE_051_V41
        // Mouse mode AND we are in a GUI AND the active window actually permits a
        // cursor. Not const: WindowBase::isGamepadCursorAllowed() is not const.
        bool tspMouseUsableNow();"""))

EDITS.append((CH, "hpp: v41 members", """        // TSP_MOUSE_MODE_051_V38
        bool mTspMouseMode;
    };""",
"""        // TSP_MOUSE_MODE_051_V38
        bool mTspMouseMode;
        // TSP_MOUSE_MODE_051_V41
        unsigned int mTspLastMenuTapMs;
        void* mTspLastTopWindow;
    };"""))

# ---- cpp -------------------------------------------------------------
EDITS.append((CM, "cpp: double-tap constant", """namespace MWInput
{
    ControllerManager::ControllerManager(""",
"""namespace MWInput
{
    namespace
    {
        // TSP_MOUSE_MODE_051_V41 -- longest gap between two MENU taps that still
        // counts as a double tap. Named constant so retuning is a one-token sed.
        constexpr unsigned int sTspMenuDoubleTapMs = 400;
    }

    ControllerManager::ControllerManager("""))

EDITS.append((CM, "cpp: ctor init", """        // TSP_MOUSE_MODE_051_V38
        , mTspMouseMode(false)
    {""",
"""        // TSP_MOUSE_MODE_051_V38
        , mTspMouseMode(false)
        // TSP_MOUSE_MODE_051_V41
        , mTspLastMenuTapMs(0)
        , mTspLastTopWindow(nullptr)
    {"""))

EDITS.append((CM, "cpp: tspMouseUsableNow + per-menu reset helper", """    // TSP_MOUSE_MODE_051_V38
    void ControllerManager::tspSetMouseMode(bool on)""",
"""    // TSP_MOUSE_MODE_051_V41
    bool ControllerManager::tspMouseUsableNow()
    {
        if (!mTspMouseMode)
            return false;

        MWBase::WindowManager* winMgr = MWBase::Environment::get().getWindowManager();
        if (!winMgr->isGuiMode())
            return false;

        // Honour the window's own opt-out. MainMenu sets mDisableGamepadCursor,
        // so the main and pause menus never get a pointer even in mouse mode.
        MWGui::WindowBase* topWin = winMgr->getActiveControllerWindow();
        if (topWin != nullptr && !topWin->isGamepadCursorAllowed())
            return false;

        return true;
    }

    // TSP_MOUSE_MODE_051_V38
    void ControllerManager::tspSetMouseMode(bool on)"""))

EDITS.append((CM, "cpp: reset mouse mode when the menu changes", """    void ControllerManager::update(float dt)
    {""",
"""    void ControllerManager::update(float dt)
    {
        // TSP_MOUSE_MODE_051_V41
        // Every menu starts in controller/text controls; mouse mode is opt-in per
        // menu rather than sticky. Keyed on the active controller window changing.
        {
            MWBase::WindowManager* tspResetWinMgr
                = MWBase::Environment::get().getWindowManager();
            void* tspTopNow = tspResetWinMgr->isGuiMode()
                ? static_cast<void*>(tspResetWinMgr->getActiveControllerWindow())
                : nullptr;

            if (tspTopNow != mTspLastTopWindow)
            {
                mTspLastTopWindow = tspTopNow;
                mTspLastMenuTapMs = 0;

                if (mTspMouseMode)
                {
                    Log(Debug::Info) << "TSP_MOUSE_MODE_051_V41 reset=window-change";
                    tspSetMouseMode(false);
                }
            }
        }
"""))

EDITS.append((CM, "cpp: gate A", """        // TSP_SETTINGS_ONLY_RAW_STICK_CURSOR_051_V13
        // TSP_MOUSE_MODE_051_V38 -- Settings window OR the MENU-toggled mouse mode.
        const bool tspSettingsMouseActive
            = (tspWinMgr->isSettingsWindowVisible()
                  || (mTspMouseMode && tspWinMgr->isGuiMode()))
            && SDL_IsTextInputActive() == SDL_FALSE;""",
"""        // TSP_SETTINGS_ONLY_RAW_STICK_CURSOR_051_V13
        // TSP_MOUSE_MODE_051_V41 -- in mouse mode the text helper has released the
        // pad, so text entry no longer has to suppress the pointer.
        const bool tspSettingsMouseActive
            = (tspWinMgr->isSettingsWindowVisible() && SDL_IsTextInputActive() == SDL_FALSE)
            || tspMouseUsableNow();"""))

EDITS.append((CM, "cpp: gate B", """        // TSP_SETTINGS_ONLY_BUTTON_MOUSE_051_V13
        // TSP_MOUSE_MODE_051_V38
        const bool tspSettingsMouseActive
            = (winMgr->isSettingsWindowVisible()
                  || (mTspMouseMode && winMgr->isGuiMode()))
            && SDL_IsTextInputActive() == SDL_FALSE;""",
"""        // TSP_SETTINGS_ONLY_BUTTON_MOUSE_051_V13
        // TSP_MOUSE_MODE_051_V41
        const bool tspSettingsMouseActive
            = (winMgr->isSettingsWindowVisible() && SDL_IsTextInputActive() == SDL_FALSE)
            || tspMouseUsableNow();"""))

EDITS.append((CM, "cpp: gate C", """        // TSP_SETTINGS_ONLY_AXIS_MOUSE_051_V13
        // TSP_MOUSE_MODE_051_V38
        const bool tspSettingsMouseActive
            = (winMgr->isSettingsWindowVisible()
                  || (mTspMouseMode && winMgr->isGuiMode()))
            && SDL_IsTextInputActive() == SDL_FALSE;""",
"""        // TSP_SETTINGS_ONLY_AXIS_MOUSE_051_V13
        // TSP_MOUSE_MODE_051_V41
        const bool tspSettingsMouseActive
            = (winMgr->isSettingsWindowVisible() && SDL_IsTextInputActive() == SDL_FALSE)
            || tspMouseUsableNow();"""))

EDITS.append((CM, "cpp: treatAsMouse honours window opt-out", """            bool treatAsMouse = winMgr->getCursorVisible() || mTspMouseMode;""",
"""            bool treatAsMouse = winMgr->getCursorVisible() || tspMouseUsableNow();"""))

EDITS.append((CM, "cpp: MENU double-tap reset", """            const bool tspGuiNow = MWBase::Environment::get().getWindowManager()->isGuiMode();
            if (tspGuiNow)
                tspSetMouseMode(!mTspMouseMode);
            else
                Log(Debug::Info) << "TSP_MOUSE_MODE_051_V38 menu=press action=gameplay-noop";
            return;""",
"""            const bool tspGuiNow = MWBase::Environment::get().getWindowManager()->isGuiMode();
            if (tspGuiNow)
            {
                // TSP_MOUSE_MODE_051_V41 -- first tap acts immediately (no input
                // lag); a second inside the window forces mouse mode off.
                const unsigned int tspNowMs = SDL_GetTicks();
                const bool tspDoubleTap = mTspLastMenuTapMs != 0
                    && (tspNowMs - mTspLastMenuTapMs) <= sTspMenuDoubleTapMs;

                if (tspDoubleTap)
                {
                    mTspLastMenuTapMs = 0;
                    tspSetMouseMode(false);
                    Log(Debug::Info) << "TSP_MOUSE_MODE_051_V41 menu=double-tap action=reset";
                }
                else
                {
                    mTspLastMenuTapMs = tspNowMs;
                    tspSetMouseMode(!mTspMouseMode);
                }
            }
            else
                Log(Debug::Info) << "TSP_MOUSE_MODE_051_V38 menu=press action=gameplay-noop";
            return;"""))

EDITS.append((CM, "cpp: drop the V39 per-button trace", """        // TSP_PROBE_V39 -- unconditional, before every gate, so silence is impossible
        // to reach: if OpenMW receives the button at all, this line is written.
        Log(Debug::Warning) << "TSP_PROBE_V39 buttonPressed=" << static_cast<int>(arg.button)
                            << " gui="
                            << (MWBase::Environment::get().getWindowManager()->isGuiMode() ? 1 : 0);

        if (!Settings::input().mEnableController || mBindingsManager->isDetectingBindingState())""",
"""        // TSP_MOUSE_MODE_051_V41 -- V39's per-button trace removed; it fired on
        // every press in the input hot path. The ctor mapping dump stays.
        if (!Settings::input().mEnableController || mBindingsManager->isDetectingBindingState())"""))

# ---- inputmanagerimp -------------------------------------------------
EDITS.append((IM, "im: gate D honours window opt-out", """            // TSP_SETTINGS_ONLY_MOUSE_051_V13
            // TSP_MOUSE_MODE_051_V38
            const bool shouldShow
                = (windowManager->isSettingsWindowVisible()
                      || (mControllerManager->tspMouseModeActive()
                          && windowManager->isGuiMode()))
                && SDL_IsTextInputActive() == SDL_FALSE;""",
"""            // TSP_SETTINGS_ONLY_MOUSE_051_V13
            // TSP_MOUSE_MODE_051_V41
            const bool shouldShow
                = (windowManager->isSettingsWindowVisible()
                       && SDL_IsTextInputActive() == SDL_FALSE)
                || mControllerManager->tspMouseUsableNow();"""))

EDITS.append((IM, "im: follow the helper's pointing flag", """        const bool tspTextEntryActive = SDL_IsTextInputActive() == SDL_TRUE;""",
"""        const bool tspTextEntryActive = SDL_IsTextInputActive() == SDL_TRUE;

        // TSP_MOUSE_MODE_051_V41
        // While the text helper owns the pad it decides who points. It creates
        // /tmp/openmw-tsp-mouse-mode when MENU makes it yield the grab, and removes
        // it when MENU takes the pad back. Only authoritative while text entry is
        // live -- outside that, MENU reaches us directly and the toggle is ours.
        {
            bool tspHelperPointing = false;
            if (std::FILE* tspFlag = std::fopen("/tmp/openmw-tsp-mouse-mode", "r"))
            {
                tspHelperPointing = true;
                std::fclose(tspFlag);
            }

            if ((tspTextEntryActive || tspHelperPointing)
                && tspHelperPointing != mControllerManager->tspMouseModeActive())
            {
                mControllerManager->tspSetMouseMode(tspHelperPointing);
                std::fprintf(stderr,
                    "TSP_MOUSE_MODE_051_V41 helperPointing=%d text=%d\\n",
                    tspHelperPointing ? 1 : 0,
                    tspTextEntryActive ? 1 : 0);
                std::fflush(stderr);
            }
        }"""))

# ---- mainmenu --------------------------------------------------------
EDITS.append((MM, "mainmenu: keep focus inside the button list", """        else if (arg.button == SDL_CONTROLLER_BUTTON_DPAD_UP)
        {
            MyGUI::InputManager::getInstance().injectKeyPress(MyGUI::KeyCode::LeftShift);
            MWBase::Environment::get().getWindowManager()->injectKeyPress(MyGUI::KeyCode::Tab, 0, false);
            MyGUI::InputManager::getInstance().injectKeyRelease(MyGUI::KeyCode::LeftShift);
        }
        else if (arg.button == SDL_CONTROLLER_BUTTON_DPAD_DOWN)
        {
            MWBase::Environment::get().getWindowManager()->injectKeyPress(MyGUI::KeyCode::Tab, 0, false);
        }""",
"""        else if (arg.button == SDL_CONTROLLER_BUTTON_DPAD_UP
            || arg.button == SDL_CONTROLLER_BUTTON_DPAD_DOWN)
        {
            // TSP_MAINMENU_FOCUS_051_V41
            // Stock injected Tab / Shift+Tab, which is generic MyGUI focus cycling
            // and does not stay inside this menu: past the last entry it lands on
            // some other key-focusable widget, and if that is an edit box MyGUI
            // turns on SDL text input, which hands the pad to the TSP text helper.
            // Walk our own visible buttons instead, wrapping at both ends.
            //
            // Order comes from the same list updateMenu() builds -- mButtons is a
            // std::map and therefore alphabetical, NOT display order.
            static const char* const tspOrder[]
                = { "return", "newgame", "savegame", "loadgame", "options", "credits", "exitgame" };

            std::vector<MyGUI::Widget*> tspVisible;
            for (const char* tspId : tspOrder)
            {
                auto tspIt = mButtons.find(std::string(tspId));
                if (tspIt != mButtons.end() && tspIt->second->getVisible())
                    tspVisible.push_back(tspIt->second);
            }

            if (tspVisible.empty())
                return true;

            MyGUI::Widget* tspFocus = MyGUI::InputManager::getInstance().getKeyFocusWidget();

            int tspIndex = -1;
            for (size_t tspI = 0; tspI < tspVisible.size(); ++tspI)
            {
                if (tspVisible[tspI] == tspFocus)
                {
                    tspIndex = static_cast<int>(tspI);
                    break;
                }
            }

            const int tspCount = static_cast<int>(tspVisible.size());
            const int tspStep = arg.button == SDL_CONTROLLER_BUTTON_DPAD_DOWN ? 1 : -1;
            const int tspNext = tspIndex < 0
                ? (tspStep > 0 ? 0 : tspCount - 1)
                : (((tspIndex + tspStep) % tspCount) + tspCount) % tspCount;

            MWBase::Environment::get().getWindowManager()->setKeyFocusWidget(tspVisible[tspNext]);
        }"""))

# ---------------------------------------------------------------- engine
def balanced(text, label):
    for o, c in {'{': '}', '(': ')'}.items():
        if text.count(o) != text.count(c):
            print("FAIL: imbalance after %s: %s=%d %s=%d" % (label, o, text.count(o), c, text.count(c)))
            return False
    return True

files = {}
for path, label, old, new in EDITS:
    if path not in files:
        if not os.path.exists(path):
            print("FAIL: missing file %s" % path); sys.exit(1)
        with io.open(path, encoding="utf-8") as fh:
            files[path] = fh.read()

pending = dict(files)
applied = skipped = 0
for path, label, old, new in EDITS:
    text = pending[path]
    if new in text:
        print("SKIP (already applied): %s" % label); skipped += 1; continue
    n = text.count(old)
    if n != 1:
        print("FAIL: anchor for '%s' matched %d times (need exactly 1) in %s"
              % (label, n, os.path.basename(path)))
        sys.exit(1)
    pending[path] = text.replace(old, new, 1)
    print("OK: %s" % label); applied += 1

for path, text in pending.items():
    if not balanced(text, os.path.basename(path)):
        sys.exit(1)

if applied == 0:
    print("Nothing to do - all %d edits already present." % skipped)
else:
    stamp = time.strftime("%Y%m%d-%H%M%S")
    for path, text in pending.items():
        if text != files[path]:
            bak = "%s.before-v41-%s" % (path, stamp)
            with io.open(bak, "w", encoding="utf-8", newline="") as fh:
                fh.write(files[path])
            with io.open(path, "w", encoding="utf-8", newline="") as fh:
                fh.write(text)
            print("wrote %s (backup: %s)" % (path, os.path.basename(bak)))

for path in pending:
    with io.open(path, encoding="utf-8") as fh:
        body = fh.read()
    if not any(m in body for m in MARKS):
        print("FAIL: no v41 marker in %s after write" % os.path.basename(path)); sys.exit(1)

with io.open(CM, encoding="utf-8") as fh:
    if "TSP_PROBE_V39 buttonPressed" in fh.read():
        print("FAIL: V39 per-button trace still present"); sys.exit(1)
print("VERIFIED: v41 present in all 4 files, V39 trace removed (%d applied, %d already present)"
      % (applied, skipped))
