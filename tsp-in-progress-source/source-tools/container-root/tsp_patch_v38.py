import sys, io, os, time

SRC = os.environ.get("TSPSRC", "/root/openmw-0.51-tsp-src")
CM  = os.path.join(SRC, "apps/openmw/mwinput/controllermanager.cpp")
CH  = os.path.join(SRC, "apps/openmw/mwinput/controllermanager.hpp")
IM  = os.path.join(SRC, "apps/openmw/mwinput/inputmanagerimp.cpp")

MARK = "TSP_MOUSE_MODE_051_V38"

# ---------------------------------------------------------------- edits
# (file, label, old, new)
EDITS = []

EDITS.append((CH, "hpp: public accessors", """        std::string getControllerButtonIcon(int button);
        std::string getControllerAxisIcon(int axis);

    private:""", """        std::string getControllerButtonIcon(int button);
        std::string getControllerAxisIcon(int axis);

        // TSP_MOUSE_MODE_051_V38
        bool tspMouseModeActive() const { return mTspMouseMode; }
        void tspSetMouseMode(bool on);

    private:"""))

EDITS.append((CH, "hpp: member", """        bool mLeftTriggerGuiPressed;
        bool mRightTriggerGuiPressed;
    };""", """        bool mLeftTriggerGuiPressed;
        bool mRightTriggerGuiPressed;
        // TSP_MOUSE_MODE_051_V38
        bool mTspMouseMode;
    };"""))

EDITS.append((CM, "ctor init list", """        , mLeftTriggerGuiPressed(false)
        , mRightTriggerGuiPressed(false)
    {""", """        , mLeftTriggerGuiPressed(false)
        , mRightTriggerGuiPressed(false)
        // TSP_MOUSE_MODE_051_V38
        , mTspMouseMode(false)
    {"""))

EDITS.append((CM, "gate A: update() raw stick", """        // TSP_SETTINGS_ONLY_RAW_STICK_CURSOR_051_V13
        const bool tspSettingsMouseActive
            = tspWinMgr->isSettingsWindowVisible() && SDL_IsTextInputActive() == SDL_FALSE;""",
"""        // TSP_SETTINGS_ONLY_RAW_STICK_CURSOR_051_V13
        // TSP_MOUSE_MODE_051_V38 -- Settings window OR the MENU-toggled mouse mode.
        const bool tspSettingsMouseActive
            = (tspWinMgr->isSettingsWindowVisible()
                  || (mTspMouseMode && tspWinMgr->isGuiMode()))
            && SDL_IsTextInputActive() == SDL_FALSE;"""))

EDITS.append((CM, "gate B: button path", """        // TSP_SETTINGS_ONLY_BUTTON_MOUSE_051_V13
        const bool tspSettingsMouseActive
            = winMgr->isSettingsWindowVisible() && SDL_IsTextInputActive() == SDL_FALSE;""",
"""        // TSP_SETTINGS_ONLY_BUTTON_MOUSE_051_V13
        // TSP_MOUSE_MODE_051_V38
        const bool tspSettingsMouseActive
            = (winMgr->isSettingsWindowVisible()
                  || (mTspMouseMode && winMgr->isGuiMode()))
            && SDL_IsTextInputActive() == SDL_FALSE;"""))

EDITS.append((CM, "gate C: axis path", """        // TSP_SETTINGS_ONLY_AXIS_MOUSE_051_V13
        const bool tspSettingsMouseActive
            = winMgr->isSettingsWindowVisible() && SDL_IsTextInputActive() == SDL_FALSE;""",
"""        // TSP_SETTINGS_ONLY_AXIS_MOUSE_051_V13
        // TSP_MOUSE_MODE_051_V38
        const bool tspSettingsMouseActive
            = (winMgr->isSettingsWindowVisible()
                  || (mTspMouseMode && winMgr->isGuiMode()))
            && SDL_IsTextInputActive() == SDL_FALSE;"""))

EDITS.append((CM, "treatAsMouse", """            bool treatAsMouse = winMgr->getCursorVisible();
            winMgr->setCursorActive(false);""",
"""            // TSP_MOUSE_MODE_051_V38 -- in mouse mode A always falls through to a click,
            // independent of the engine's own cursor-visibility bookkeeping.
            bool treatAsMouse = winMgr->getCursorVisible() || mTspMouseMode;
            winMgr->setCursorActive(false);"""))

# MENU consumed in buttonPressed BEFORE anything else can eat it.
EDITS.append((CM, "buttonPressed: consume MENU", """        mJoystickLastUsed = true;
        if (MWBase::Environment::get().getWindowManager()->isGuiMode())
        {
            if (gamepadToGuiControl(arg))
                return;

            if (mGamepadGuiCursorEnabled)""",
"""        mJoystickLastUsed = true;

        // TSP_MOUSE_MODE_051_V38
        // The TSP MENU button (physical BTN_MODE / js b8, mapped as guide:b8) is
        // consumed here so it can never reach the bindings manager, where stock
        // 0.51 has A_QuickSave sitting on GUIDE.
        if (arg.button == SDL_CONTROLLER_BUTTON_GUIDE)
        {
            const bool tspGuiNow = MWBase::Environment::get().getWindowManager()->isGuiMode();
            if (tspGuiNow)
                tspSetMouseMode(!mTspMouseMode);
            else
                Log(Debug::Info) << "TSP_MOUSE_MODE_051_V38 menu=press action=gameplay-noop";
            return;
        }

        if (MWBase::Environment::get().getWindowManager()->isGuiMode())
        {
            if (gamepadToGuiControl(arg))
                return;

            if (mGamepadGuiCursorEnabled)"""))

EDITS.append((CM, "buttonReleased: consume MENU", """        mJoystickLastUsed = true;
        if (MWBase::Environment::get().getWindowManager()->isGuiMode())
        {
            if (mGamepadGuiCursorEnabled && (!Settings::gui().mControllerMenus || mGamepadMousePressed))""",
"""        mJoystickLastUsed = true;

        // TSP_MOUSE_MODE_051_V38
        if (arg.button == SDL_CONTROLLER_BUTTON_GUIDE)
        {
            Log(Debug::Info) << "TSP_MOUSE_MODE_051_V38 menu=release action=consumed";
            return;
        }

        if (MWBase::Environment::get().getWindowManager()->isGuiMode())
        {
            if (mGamepadGuiCursorEnabled && (!Settings::gui().mControllerMenus || mGamepadMousePressed))"""))

# L3 toggle, placed ABOVE the mControllerMenus block so per-window handlers
# (which all return true) cannot swallow it.
EDITS.append((CM, "gamepadToGuiControl: L3 toggle above window dispatch", """        // TSP_SETTINGS_ONLY_BUTTON_MOUSE_051_V13""",
"""        // TSP_MOUSE_MODE_051_V38
        // Must sit above the mControllerMenus dispatch: MainMenu, CountDialog and
        // SaveGameDialog all return true unconditionally from onControllerButtonEvent,
        // so anything handled below this point never sees these buttons.
        if (arg.button == SDL_CONTROLLER_BUTTON_LEFTSTICK)
        {
            tspSetMouseMode(!mTspMouseMode);
            return true;
        }
        if (arg.button == SDL_CONTROLLER_BUTTON_GUIDE)
        {
            tspSetMouseMode(!mTspMouseMode);
            return true;
        }

        // TSP_SETTINGS_ONLY_BUTTON_MOUSE_051_V13"""))

EDITS.append((CM, "tspSetMouseMode definition", """    float ControllerManager::getAxisValue(SDL_GameControllerAxis axis) const
    {""",
"""    // TSP_MOUSE_MODE_051_V38
    void ControllerManager::tspSetMouseMode(bool on)
    {
        mTspMouseMode = on;

        MWBase::WindowManager* winMgr = MWBase::Environment::get().getWindowManager();
        winMgr->setCursorActive(on);
        winMgr->setCursorVisible(on);

        Log(Debug::Info) << "TSP_MOUSE_MODE_051_V38 mouseMode=" << (on ? 1 : 0)
                         << " gui=" << (winMgr->isGuiMode() ? 1 : 0);
    }

    float ControllerManager::getAxisValue(SDL_GameControllerAxis axis) const
    {"""))

EDITS.append((IM, "gate D: software cursor widget", """            // TSP_SETTINGS_ONLY_MOUSE_051_V13
            const bool shouldShow
                = windowManager->isSettingsWindowVisible()
                && SDL_IsTextInputActive() == SDL_FALSE;""",
"""            // TSP_SETTINGS_ONLY_MOUSE_051_V13
            // TSP_MOUSE_MODE_051_V38
            const bool shouldShow
                = (windowManager->isSettingsWindowVisible()
                      || (mControllerManager->tspMouseModeActive()
                          && windowManager->isGuiMode()))
                && SDL_IsTextInputActive() == SDL_FALSE;"""))

# ---------------------------------------------------------------- engine
def balanced(text, label):
    pairs = {'{': '}', '(': ')'}
    for o, c in pairs.items():
        if text.count(o) != text.count(c):
            print("FAIL: brace/paren imbalance after %s: %s=%d %s=%d"
                  % (label, o, text.count(o), c, text.count(c)))
            return False
    return True

# Precondition: inputmanagerimp.cpp must already include controllermanager.hpp,
# because gate D calls mControllerManager->tspMouseModeActive().
with io.open(IM, encoding="utf-8") as fh:
    if 'include "controllermanager.hpp"' not in fh.read():
        print("FAIL: inputmanagerimp.cpp does not include controllermanager.hpp; "
              "gate D would not compile. Nothing written.")
        sys.exit(1)
print("OK: precondition - inputmanagerimp.cpp includes controllermanager.hpp")

files = {}
for path, label, old, new in EDITS:
    if path not in files:
        if not os.path.exists(path):
            print("FAIL: missing file %s" % path); sys.exit(1)
        with io.open(path, encoding="utf-8") as fh:
            files[path] = fh.read()

pending = {p: t for p, t in files.items()}
applied, skipped = 0, 0

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
            bak = "%s.before-mousemode-v38-%s" % (path, stamp)
            with io.open(bak, "w", encoding="utf-8", newline="") as fh:
                fh.write(files[path])
            with io.open(path, "w", encoding="utf-8", newline="") as fh:
                fh.write(text)
            print("wrote %s (backup: %s)" % (path, os.path.basename(bak)))

for path in pending:
    with io.open(path, encoding="utf-8") as fh:
        if MARK not in fh.read():
            print("FAIL: marker missing from %s after write" % path); sys.exit(1)

print("VERIFIED: mouse-mode v38 patch present in all 3 files (%d applied, %d already present)"
      % (applied, skipped))
