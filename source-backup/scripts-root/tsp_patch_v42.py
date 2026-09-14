import sys, io, os, time

SRC = os.environ.get("TSPSRC", "/root/openmw-0.51-tsp-src")
CM  = os.path.join(SRC, "apps/openmw/mwinput/controllermanager.cpp")
CH  = os.path.join(SRC, "apps/openmw/mwinput/controllermanager.hpp")

MARK = "TSP_CHORD_051_V42"
EDITS = []

EDITS.append((CM, "cpp: includes for the hard-kill fallback", """#include <SDL.h>""",
"""#include <SDL.h>

// TSP_CHORD_051_V42 -- std::_Exit / std::fflush for the exit-chord fallback.
#include <cstdio>
#include <cstdlib>"""))

EDITS.append((CM, "cpp: chord constants", """        // TSP_MOUSE_MODE_051_V41 -- longest gap between two MENU taps that still
        // counts as a double tap. Named constant so retuning is a one-token sed.
        constexpr unsigned int sTspMenuDoubleTapMs = 400;
    }""",
"""        // TSP_MOUSE_MODE_051_V41 -- longest gap between two MENU taps that still
        // counts as a double tap. Named constant so retuning is a one-token sed.
        constexpr unsigned int sTspMenuDoubleTapMs = 400;

        // TSP_CHORD_051_V42 -- MENU-hold chord layer. All one-token retunable.
        //
        // NOTE ON THE EXIT BUTTON: this pad's gamecontrollerdb crosses START and
        // SELECT (back:b7 where b7 = evdev 315 = physical START). So
        // SDL_CONTROLLER_BUTTON_BACK is the physical START key. If exit ends up on
        // the wrong physical button, swap this to SDL_CONTROLLER_BUTTON_START --
        // every chord logs its SDL button number, so the log names the culprit.
        constexpr int sTspChordExitButton = SDL_CONTROLLER_BUTTON_BACK;

        // Steve's choice: quick slots / save / load / screenshot are gameplay-only
        // so they cannot collide with menu controls. The exit chord ignores this.
        constexpr bool sTspChordsInMenus = false;

        constexpr float sTspChordStickThreshold = 0.6f;
        constexpr float sTspChordTriggerThreshold = 0.5f;

        // Clean quit first; if the main loop has not torn down by then, hard exit.
        constexpr unsigned int sTspChordExitKillMs = 3000;
    }"""))

EDITS.append((CH, "hpp: chord methods", """        // TSP_MOUSE_MODE_051_V41
        // Mouse mode AND we are in a GUI AND the active window actually permits a
        // cursor. Not const: WindowBase::isGamepadCursorAllowed() is not const.
        bool tspMouseUsableNow();""",
"""        // TSP_MOUSE_MODE_051_V41
        // Mouse mode AND we are in a GUI AND the active window actually permits a
        // cursor. Not const: WindowBase::isGamepadCursorAllowed() is not const.
        bool tspMouseUsableNow();

        // TSP_CHORD_051_V42
        void tspFireChordAction(int action, const char* what);
        void tspFireChordButton(int sdlButton);
        void tspUpdateChordAxes();"""))

EDITS.append((CH, "hpp: chord members", """        // TSP_MOUSE_MODE_051_V41
        unsigned int mTspLastMenuTapMs;
        void* mTspLastTopWindow;
    };""",
"""        // TSP_MOUSE_MODE_051_V41
        unsigned int mTspLastMenuTapMs;
        void* mTspLastTopWindow;
        // TSP_CHORD_051_V42
        bool mTspMenuHeld;
        bool mTspChordConsumed;
        int mTspChordStickDir;
        bool mTspChordLtLatched;
        bool mTspChordRtLatched;
        unsigned int mTspQuitDeadlineMs;
    };"""))

EDITS.append((CM, "cpp: ctor init", """        // TSP_MOUSE_MODE_051_V41
        , mTspLastMenuTapMs(0)
        , mTspLastTopWindow(nullptr)
    {""",
"""        // TSP_MOUSE_MODE_051_V41
        , mTspLastMenuTapMs(0)
        , mTspLastTopWindow(nullptr)
        // TSP_CHORD_051_V42
        , mTspMenuHeld(false)
        , mTspChordConsumed(false)
        , mTspChordStickDir(0)
        , mTspChordLtLatched(false)
        , mTspChordRtLatched(false)
        , mTspQuitDeadlineMs(0)
    {"""))

EDITS.append((CM, "cpp: chord implementations", """    // TSP_MOUSE_MODE_051_V41
    bool ControllerManager::tspMouseUsableNow()""",
"""    // TSP_CHORD_051_V42 -- fire one chord action.
    void ControllerManager::tspFireChordAction(int action, const char* what)
    {
        mTspChordConsumed = true;

        if (MWBase::Environment::get().getWindowManager()->isGuiMode() && !sTspChordsInMenus)
        {
            Log(Debug::Info) << "TSP_CHORD_051_V42 chord=" << what << " action=ignored-in-gui";
            return;
        }

        Log(Debug::Info) << "TSP_CHORD_051_V42 chord=" << what << " action=fired";
        MWBase::Environment::get().getInputManager()->executeAction(action);
    }

    // TSP_CHORD_051_V42 -- MENU + face button / shoulder.
    void ControllerManager::tspFireChordButton(int sdlButton)
    {
        // The exit chord is the one that works everywhere, menus included: it is
        // the escape hatch for a UI you cannot get out of.
        if (sdlButton == sTspChordExitButton)
        {
            mTspChordConsumed = true;
            Log(Debug::Warning) << "TSP_CHORD_051_V42 chord=exit sdlButton=" << sdlButton
                                << " action=requestQuit";
            MWBase::Environment::get().getStateManager()->requestQuit();
            mTspQuitDeadlineMs = SDL_GetTicks() + sTspChordExitKillMs;
            return;
        }

        switch (sdlButton)
        {
            case SDL_CONTROLLER_BUTTON_A:
                tspFireChordAction(A_QuickKey1, "quickslot1-A");
                return;
            case SDL_CONTROLLER_BUTTON_B:
                tspFireChordAction(A_QuickKey2, "quickslot2-B");
                return;
            case SDL_CONTROLLER_BUTTON_X:
                tspFireChordAction(A_QuickKey3, "quickslot3-X");
                return;
            case SDL_CONTROLLER_BUTTON_Y:
                tspFireChordAction(A_QuickKey4, "quickslot4-Y");
                return;
            case SDL_CONTROLLER_BUTTON_RIGHTSHOULDER:
                tspFireChordAction(A_QuickKeysMenu, "quickkeysmenu-RB");
                return;
            case SDL_CONTROLLER_BUTTON_LEFTSHOULDER:
                tspFireChordAction(A_Screenshot, "screenshot-LB");
                return;
            default:
                break;
        }

        // Still consumed: MENU+<anything> must never reach the game.
        mTspChordConsumed = true;
        Log(Debug::Info) << "TSP_CHORD_051_V42 chord=sdlButton" << sdlButton << " action=unmapped";
    }

    // TSP_CHORD_051_V42 -- MENU + right stick (slots 5-8) and MENU + triggers.
    // Read from SDL state rather than events so a held stick fires exactly once.
    void ControllerManager::tspUpdateChordAxes()
    {
        if (!mTspMenuHeld)
        {
            mTspChordStickDir = 0;
            mTspChordLtLatched = false;
            mTspChordRtLatched = false;
            return;
        }

        const float tspRx = getAxisValue(SDL_CONTROLLER_AXIS_RIGHTX);
        const float tspRy = getAxisValue(SDL_CONTROLLER_AXIS_RIGHTY);

        int tspDir = 0;
        if (tspRy <= -sTspChordStickThreshold)
            tspDir = 1;
        else if (tspRy >= sTspChordStickThreshold)
            tspDir = 3;
        else if (tspRx <= -sTspChordStickThreshold)
            tspDir = 2;
        else if (tspRx >= sTspChordStickThreshold)
            tspDir = 4;

        if (tspDir != mTspChordStickDir)
        {
            mTspChordStickDir = tspDir;
            switch (tspDir)
            {
                case 1: tspFireChordAction(A_QuickKey5, "quickslot5-RS-up"); break;
                case 2: tspFireChordAction(A_QuickKey6, "quickslot6-RS-left"); break;
                case 3: tspFireChordAction(A_QuickKey7, "quickslot7-RS-down"); break;
                case 4: tspFireChordAction(A_QuickKey8, "quickslot8-RS-right"); break;
                default: break;
            }
        }

        const bool tspLtNow
            = getAxisValue(SDL_CONTROLLER_AXIS_TRIGGERLEFT) >= sTspChordTriggerThreshold;
        const bool tspRtNow
            = getAxisValue(SDL_CONTROLLER_AXIS_TRIGGERRIGHT) >= sTspChordTriggerThreshold;

        if (tspLtNow && !mTspChordLtLatched)
            tspFireChordAction(A_QuickSave, "quicksave-LT");
        if (tspRtNow && !mTspChordRtLatched)
            tspFireChordAction(A_QuickLoad, "quickload-RT");

        mTspChordLtLatched = tspLtNow;
        mTspChordRtLatched = tspRtNow;
    }

    // TSP_MOUSE_MODE_051_V41
    bool ControllerManager::tspMouseUsableNow()"""))

EDITS.append((CM, "cpp: chord axes + quit watchdog in update()", """    void ControllerManager::update(float dt)
    {
        // TSP_MOUSE_MODE_051_V41""",
"""    void ControllerManager::update(float dt)
    {
        // TSP_CHORD_051_V42 -- right stick / triggers while MENU is held.
        tspUpdateChordAxes();

        // TSP_CHORD_051_V42 -- the exit chord asked for a clean quit; if the main
        // loop has not torn down by the deadline, leave hard. (An in-engine
        // watchdog cannot rescue a fully hung main loop -- update() would not be
        // running either. This covers "the UI is stuck", not "the process is wedged".)
        if (mTspQuitDeadlineMs != 0 && SDL_GetTicks() >= mTspQuitDeadlineMs)
        {
            Log(Debug::Warning) << "TSP_CHORD_051_V42 exit=hard-kill reason=clean-quit-timeout";
            std::fflush(nullptr);
            std::_Exit(0);
        }

        // TSP_MOUSE_MODE_051_V41"""))

EDITS.append((CM, "cpp: MENU arms the chord layer instead of acting on press", """        if (arg.button == SDL_CONTROLLER_BUTTON_GUIDE)
        {
            const bool tspGuiNow = MWBase::Environment::get().getWindowManager()->isGuiMode();
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
            return;
        }

        if (MWBase::Environment::get().getWindowManager()->isGuiMode())""",
"""        if (arg.button == SDL_CONTROLLER_BUTTON_GUIDE)
        {
            // TSP_CHORD_051_V42 -- MENU now ARMS on press and acts on release, so
            // one button can mean three things without them fighting:
            //   held + another input -> chord   (consumed here)
            //   released, nothing else pressed -> mouse-mode toggle
            //   two such releases inside sTspMenuDoubleTapMs -> hard reset
            // Acting on release costs only the length of the tap, which beats
            // delaying every tap by the double-tap window.
            mTspMenuHeld = true;
            mTspChordConsumed = false;
            return;
        }

        // TSP_CHORD_051_V42 -- any other button while MENU is held is a chord and
        // must never also reach the game.
        if (mTspMenuHeld)
        {
            tspFireChordButton(arg.button);
            return;
        }

        if (MWBase::Environment::get().getWindowManager()->isGuiMode())"""))

EDITS.append((CM, "cpp: MENU acts on release", """        // TSP_MOUSE_MODE_051_V38
        if (arg.button == SDL_CONTROLLER_BUTTON_GUIDE)
        {
            Log(Debug::Info) << "TSP_MOUSE_MODE_051_V38 menu=release action=consumed";
            return;
        }""",
"""        // TSP_CHORD_051_V42 -- MENU acts here, not on press.
        if (arg.button == SDL_CONTROLLER_BUTTON_GUIDE)
        {
            const bool tspWasChord = mTspChordConsumed;
            mTspMenuHeld = false;
            mTspChordConsumed = false;
            mTspChordStickDir = 0;
            mTspChordLtLatched = false;
            mTspChordRtLatched = false;

            if (tspWasChord)
            {
                Log(Debug::Info) << "TSP_CHORD_051_V42 menu=release action=chord-consumed";
                return;
            }

            if (!MWBase::Environment::get().getWindowManager()->isGuiMode())
            {
                Log(Debug::Info) << "TSP_MOUSE_MODE_051_V38 menu=release action=gameplay-noop";
                return;
            }

            // TSP_MOUSE_MODE_051_V41 -- bare tap: toggle, or reset on a double tap.
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
            return;
        }

        // TSP_CHORD_051_V42 -- swallow the release of a chorded button too, or the
        // bindings manager sees a release for a press it never got.
        if (mTspMenuHeld)
            return;"""))

EDITS.append((CM, "cpp: axes belong to the chord layer while MENU is held", """        mJoystickLastUsed = true;
        if (MWBase::Environment::get().getWindowManager()->isGuiMode())
        {
            if (gamepadToGuiControl(arg))
                return;
        }
        else if (mBindingsManager->actionIsActive(A_TogglePOV)""",
"""        // TSP_CHORD_051_V42 -- while MENU is held the sticks and triggers drive
        // chords (read from SDL state in update()), so they must not also move the
        // player or the GUI cursor.
        if (mTspMenuHeld)
            return;

        mJoystickLastUsed = true;
        if (MWBase::Environment::get().getWindowManager()->isGuiMode())
        {
            if (gamepadToGuiControl(arg))
                return;
        }
        else if (mBindingsManager->actionIsActive(A_TogglePOV)"""))

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
        print("      (v42 patches ON TOP of v41 -- if v41 was never applied, that is why)")
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
            bak = "%s.before-v42-%s" % (path, stamp)
            with io.open(bak, "w", encoding="utf-8", newline="") as fh:
                fh.write(files[path])
            with io.open(path, "w", encoding="utf-8", newline="") as fh:
                fh.write(text)
            print("wrote %s (backup: %s)" % (path, os.path.basename(bak)))

for path in pending:
    with io.open(path, encoding="utf-8") as fh:
        if MARK not in fh.read():
            print("FAIL: no v42 marker in %s after write" % os.path.basename(path)); sys.exit(1)

# Removal-style assertion (agreement #7): the old press-time toggle must be gone.
with io.open(CM, encoding="utf-8") as fh:
    body = fh.read()
if "menu=press action=gameplay-noop" in body:
    print("FAIL: MENU still acts on press; the arm-on-press rewrite did not land"); sys.exit(1)
print("VERIFIED: chord layer v42 present, MENU now arms on press (%d applied, %d already present)"
      % (applied, skipped))
