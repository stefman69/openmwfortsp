#include "inputmanagerimp.hpp"

#include <osgViewer/ViewerEventHandlers>

#include <components/esm3/esmreader.hpp>
#include <components/esm3/esmwriter.hpp>
#include <components/sdlutil/sdlinputwrapper.hpp>
#include <components/settings/values.hpp>

#include "../mwbase/environment.hpp"
#include "../mwbase/windowmanager.hpp"
#include "../mwbase/world.hpp"

#include "../mwworld/esmstore.hpp"

#include "actionmanager.hpp"
#include "bindingsmanager.hpp"
#include "controllermanager.hpp"
#include "controlswitch.hpp"
#include "gyromanager.hpp"
#include "keyboardmanager.hpp"
#include "mousemanager.hpp"
#include "sensormanager.hpp"
#include <algorithm>
#include <string>
#include <MyGUI_Gui.h>
#include <MyGUI_KeyCode.h>
#include <MyGUI_RenderManager.h>
#include <MyGUI_TextBox.h>
#include <cstdio>
#include <cstring>
#include <MyGUI_PointerManager.h>
#include <MyGUI_ImageBox.h>
#include "../mwgui/mode.hpp"

namespace MWInput
{
    namespace
    {
        // TSP_CURSOR_POLICY_051_V48 -- all one-token retunable.
        // Morrowind's own arrow: the same texture OpenMW's ArrowPointerImage
        // resource uses. 32x32, hot spot (7,0) per openmw_pointer.xml, so the
        // widget is offset by -7 in x to put the tip on the point.
        const char* const sTspCursorTexture = "textures\\tx_cursor.dds";
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
            tspCursor->setVisible(true);
        }
    }
    InputManager::InputManager(SDL_Window* window, osg::ref_ptr<osgViewer::Viewer> viewer,
        osg::ref_ptr<osgViewer::ScreenCaptureHandler> screenCaptureHandler, const std::filesystem::path& userFile,
        bool userFileExists, const std::filesystem::path& userControllerBindingsFile,
        const std::filesystem::path& controllerBindingsFile, bool grab)
        : mControlsDisabled(false)
        , mInputWrapper(std::make_unique<SDLUtil::InputWrapper>(window, viewer, grab))
        , mBindingsManager(std::make_unique<BindingsManager>(userFile, userFileExists))
        , mControlSwitch(std::make_unique<ControlSwitch>())
        , mActionManager(std::make_unique<ActionManager>(mBindingsManager.get(), viewer, screenCaptureHandler))
        , mKeyboardManager(std::make_unique<KeyboardManager>(mBindingsManager.get()))
        , mMouseManager(std::make_unique<MouseManager>(mBindingsManager.get(), mInputWrapper.get(), window))
        , mControllerManager(std::make_unique<ControllerManager>(
              mBindingsManager.get(), mMouseManager.get(), userControllerBindingsFile, controllerBindingsFile))
        , mSensorManager(std::make_unique<SensorManager>())
        , mGyroManager(std::make_unique<GyroManager>())
    {
        mInputWrapper->setWindowEventCallback(MWBase::Environment::get().getWindowManager());
        mInputWrapper->setKeyboardEventCallback(mKeyboardManager.get());
        mInputWrapper->setMouseEventCallback(mMouseManager.get());
        mInputWrapper->setControllerEventCallback(mControllerManager.get());
        mInputWrapper->setSensorEventCallback(mSensorManager.get());
    }

    void InputManager::clear()
    {
        // Enable all controls
        mControlSwitch->clear();
    }

    InputManager::~InputManager() {}

    // TSP_AUTO_TEXT_ENTRY_051_V5
    void InputManager::update(float dt, bool disableControls, bool disableEvents)
    {
        mControlsDisabled = disableControls;

        MWBase::WindowManager* windowManager
            = MWBase::Environment::get().getWindowManager();

        // Stock OpenMW 0.51 already knows exactly when a GUI cursor should be
        // visible, including controller-driven mouse menus such as Settings.
        // SDL's hardware cursor moves but is invisible through this TSP/GL4ES
        // display path, so keep the SDL cursor hidden and mirror OpenMW's own
        // cursor-visible state to MyGUI's in-engine pointer.
        mInputWrapper->setMouseVisible(false);

        mInputWrapper->capture(disableEvents);

        // SDL text-input state is controlled by OpenMW/MyGUI when an EditBox
        // actually owns text focus. This gives the helper an automatic,
        // context-sensitive trigger instead of stealing game/menu controls.
        const bool tspTextEntryActive = SDL_IsTextInputActive() == SDL_TRUE;

        // TSP_TEXT_INJECT_051_V64 -- the helper hands us the chosen character in a
        // file instead of relying on its synthetic uinput keystroke being
        // translated by SDL. That translation needs the kernel console keymap
        // and is absent on some TrimUI OS images: the helper emits a correct
        // Shift+A and no character ever appears. Injecting into MyGUI here
        // removes the dependency on the host OS entirely.
        {
            if (std::FILE* tspInjectFile
                = std::fopen("/tmp/openmw-tsp-text-inject", "r"))
            {
                char tspInjectBuf[64] = {};
                const std::size_t tspInjectCount
                    = std::fread(tspInjectBuf, 1, sizeof(tspInjectBuf) - 1, tspInjectFile);
                std::fclose(tspInjectFile);
                std::remove("/tmp/openmw-tsp-text-inject");
                for (std::size_t tspI = 0; tspI < tspInjectCount; ++tspI)
                {
                    const unsigned char tspCh
                        = static_cast<unsigned char>(tspInjectBuf[tspI]);
                    if (tspCh == 8)
                        windowManager->injectKeyPress(MyGUI::KeyCode::Backspace, 0, false);
                    else if (tspCh == 13 || tspCh == 10)
                        windowManager->injectKeyPress(MyGUI::KeyCode::Return, 0, false);
                    else if (tspCh >= 32 && tspCh < 127)
                        windowManager->injectKeyPress(MyGUI::KeyCode::None, tspCh, false);
                    else
                        continue;
                    std::fprintf(stderr, "TSP_TEXT_INJECT_051_V64 injected=%u\n", tspCh);
                }
                std::fflush(stderr);
            }
        }

        // TSP_EXPLICIT_UI_STATE_051_V58
        // B from helper TEXT writes this file before Escape. Keep it asserted
        // until SDL itself reports that the text field genuinely ended. While
        // asserted, the helper-availability flag must not be recreated.
        // TSP_BARTER_CONTROLLER_DEFAULT_051_V60 -- barter and loot open in CONTROLLER.
        // CountDialog::openCountDialog focuses mItemEdit, SDL text goes live and the
        // reconcile below hands the pad to the helper the instant a stack dialog
        // appears. Assert V58's force-controller on that edge instead, so the dialog
        // opens in controller nav; MENU clears the file and text arrives next frame.
        // Focus is deliberately NOT removed: SDL text must stay active or MENU would
        // have nothing to re-enable. Scoped to these two modes on purpose -- name
        // creation, save, spellmaking and enchanting keep automatic text.
        {
            static bool tspBarterTextWas = false;
            const bool tspBarterText = tspTextEntryActive
                // TSP_BARTER_CONTROLLER_DEFAULT_051_V61 -- the player inventory reaches the same
                // CountDialog through the mouse, but its mode stack is GM_Inventory,
                // so V60 never fired there. Companion is the same transfer window.
                && (windowManager->containsMode(MWGui::GM_Barter)
                       || windowManager->containsMode(MWGui::GM_Container)
                       || windowManager->containsMode(MWGui::GM_Inventory)
                       || windowManager->containsMode(MWGui::GM_Companion));
            if (tspBarterText && !tspBarterTextWas)
            {
                if (std::FILE* tspBarterFlag
                    = std::fopen("/tmp/openmw-tsp-force-controller", "w"))
                {
                    std::fputs("1\n", tspBarterFlag);
                    std::fclose(tspBarterFlag);
                }
                std::fprintf(stderr, "TSP_BARTER_CONTROLLER_DEFAULT_051_V60 barter-text=controller-default\n");
                std::fflush(stderr);
            }
            tspBarterTextWas = tspBarterText;
        }
        bool tspForceController = false;
        if (std::FILE* tspForceFile
            = std::fopen("/tmp/openmw-tsp-force-controller", "r"))
        {
            tspForceController = true;
            std::fclose(tspForceFile);
        }

        if (tspForceController && !tspTextEntryActive)
        {
            std::remove("/tmp/openmw-tsp-force-controller");
            tspForceController = false;
            std::fprintf(stderr,
                "TSP_EXPLICIT_UI_STATE_051_V58 force-controller=cleared-text-ended\n");
            std::fflush(stderr);
        }

        static bool tspForceControllerWasActive = false;
        if (tspForceController && !tspForceControllerWasActive)
        {
            std::remove("/tmp/openmw-tsp-mouse-request");
            std::remove("/tmp/openmw-tsp-mouse-mode");
            mControllerManager->tspSetMouseMode(false);
            std::fprintf(stderr,
                "TSP_EXPLICIT_UI_STATE_051_V58 force-controller=active\n");
            std::fflush(stderr);
        }
        tspForceControllerWasActive = tspForceController;

        // TSP_MOUSE_MODE_051_V41
        // While the text helper owns the pad it decides who points. It creates
        // /tmp/openmw-tsp-mouse-mode when MENU makes it yield the grab, and removes
        // it when MENU takes the pad back. Only authoritative while text entry is
        // live -- outside that, MENU reaches us directly and the toggle is ours.
        {
            // TSP_NO_STICKCLICK_MODES_051_V54
            // A left-stick move while TEXT owns EVIOCGRAB cannot reach SDL/OpenMW.
            // The helper therefore publishes a dedicated mouse request, releases
            // the grab, and this side turns the engine pointer on. V51's older
            // /tmp/openmw-tsp-mouse-mode remains a pure "helper yielded" signal.
            bool tspHelperMouseRequest = false;
            if (std::FILE* tspRequest
                = std::fopen("/tmp/openmw-tsp-mouse-request", "r"))
            {
                tspHelperMouseRequest = true;
                std::fclose(tspRequest);
            }

            if (tspHelperMouseRequest)
            {
                std::remove("/tmp/openmw-tsp-mouse-request");
                std::remove("/tmp/openmw-tsp-mouse-mode");

                if (!tspForceController && tspTextEntryActive && windowManager->isGuiMode())
                {
                    mControllerManager->tspSetMouseMode(true);
                    std::fprintf(stderr,
                        "TSP_EXPLICIT_UI_STATE_051_V58 helper-left-stick=text-to-mouse\n");
                }
                else
                {
                    std::fprintf(stderr,
                        "TSP_EXPLICIT_UI_STATE_051_V58 helper-left-stick=ignored force=%d text=%d gui=%d\n",
                        tspForceController ? 1 : 0,
                        tspTextEntryActive ? 1 : 0,
                        windowManager->isGuiMode() ? 1 : 0);
                }
                std::fflush(stderr);
            }

            bool tspHelperPointing = false;
            if (std::FILE* tspFlag = std::fopen("/tmp/openmw-tsp-mouse-mode", "r"))
            {
                tspHelperPointing = true;
                std::fclose(tspFlag);
            }

            // TSP_VISIBLE_CURSOR_051_V47 -- the old condition called
            // tspSetMouseMode(false) on EVERY frame whenever text entry was live
            // and the flag was absent, so MENU could never turn the mouse on
            // inside a save / enchanting / sell-stack menu.
            static bool tspMouseModeOwnedByHelper = false;
            if (tspHelperPointing)
            {
                // TSP_INPUT_MODE_051_V49 -- the helper writes this file when MENU
                // was pressed while IT held the grab: the one MENU press the engine
                // cannot see. That means "leave TEXT", NOT "turn on the mouse".
                // Consume both flags and fall back to CONTROLLER. Treating it as a
                // mouse request is what stuck the pointer on after a text menu.
                // TSP_TEXT_HANDOFF_051_V51 -- consume the yield flag ONLY, so a
                // yield can never turn the pointer on (the V49 fix). Deleting the
                // text flag here as well is what disabled the helper's own route
                // back into TEXT: its guard at line 564 requires that flag.
                tspMouseModeOwnedByHelper = false;
                std::remove("/tmp/openmw-tsp-mouse-mode");
                std::fprintf(stderr,
                    "TSP_MOUSE_MODE_051_V41 helperPointing=%d text=%d\n",
                    tspHelperPointing ? 1 : 0,
                    tspTextEntryActive ? 1 : 0);
                std::fflush(stderr);
            }
            else if (!tspHelperPointing && tspMouseModeOwnedByHelper)
            {
                // TSP_VISIBLE_CURSOR_051_V47 -- the helper reclaimed the pad.
                tspMouseModeOwnedByHelper = false;
                mControllerManager->tspSetMouseMode(false);
                std::fprintf(stderr, "TSP_VISIBLE_CURSOR_051_V47 helperReleased\n");
                std::fflush(stderr);
            }
        }

        // TSP_TEXT_TOGGLE_051_V50 -- reconcile EVERY frame, not only when SDL's
        // text state changes. MENU can flip the dismiss bit at any moment, so the
        // flag has to be recomputed continuously rather than latched on an edge.
        // The helper holds EVIOCGRAB exactly while this file exists.
        {
            // TSP_TEXT_HANDOFF_051_V51 -- the flag now means ONLY "the game wants
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
                std::fprintf(stderr, "TSP_TEXT_HANDOFF_051_V51 blackout=start\n");
                std::fflush(stderr);
            }
            if (tspTextResetFrames > 0)
                --tspTextResetFrames;
            const bool tspWantHelper
                = tspTextEntryActive && !tspForceController && tspTextResetFrames == 0;
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
                    std::fputs("1\n", tspNewFlag);
                    std::fclose(tspNewFlag);
                }
            }
            else if (!tspWantHelper && tspHaveFlag)
            {
                std::remove("/tmp/openmw-tsp-text-active");
            }
        }
        static bool tspPreviousTextEntryActive = false;
        static MyGUI::TextBox* tspTextIndicator = nullptr;
        static std::string tspLastIndicatorCaption;

        if (tspTextEntryActive != tspPreviousTextEntryActive)
        {
            if (tspTextEntryActive)
            {
                // TSP_INPUT_MODE_051_V49 -- deliberately does NOT create the flag.
                // Every menu that focuses an edit box turns SDL text input on, and
                // auto-writing the flag here is what made spell making, enchanting
                // and the save dialog seize the pad the moment they opened. Menus
                // now start in CONTROLLER; MENU asks for text.
            }
            else
            {
                std::remove("/tmp/openmw-tsp-text-active");
                std::remove("/tmp/openmw-tsp-text-char");
                // TSP_NO_STICKCLICK_MODES_051_V54
                std::remove("/tmp/openmw-tsp-mouse-request");

                if (tspTextIndicator != nullptr)
                {
                    MyGUI::Gui::getInstance().destroyWidget(tspTextIndicator);
                    tspTextIndicator = nullptr;
                    tspLastIndicatorCaption.clear();
                }
            }

            tspPreviousTextEntryActive = tspTextEntryActive;
        }

        // TSP_TEXT_INDICATOR_051_V52 -- the on-screen letter box follows the
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
            if (tspTextIndicator == nullptr)
            {
                const MyGUI::IntSize viewSize
                    = MyGUI::RenderManager::getInstance().getViewSize();

                const int indicatorWidth = 260;
                const int indicatorHeight = 48;
                const int indicatorX
                    = std::max(0, (viewSize.width - indicatorWidth) / 2);
                const int indicatorY
                    = std::max(0, viewSize.height - indicatorHeight - 46);

                tspTextIndicator
                    = MyGUI::Gui::getInstance().createWidget<MyGUI::TextBox>(
                        "ProgressText",
                        MyGUI::IntCoord(
                            indicatorX,
                            indicatorY,
                            indicatorWidth,
                            indicatorHeight),
                        MyGUI::Align::Default,
                        "Popup");

                tspTextIndicator->setTextAlign(MyGUI::Align::Center);
                tspTextIndicator->setFontHeight(28);
                tspTextIndicator->setCaption("[ A ]");
                tspLastIndicatorCaption = "[ A ]";
            }

            char captionBuffer[128] = {};
            if (std::FILE* captionFile
                = std::fopen("/tmp/openmw-tsp-text-char", "r"))
            {
                if (std::fgets(
                        captionBuffer,
                        static_cast<int>(sizeof(captionBuffer)),
                        captionFile)
                    != nullptr)
                {
                    const std::size_t length = std::strlen(captionBuffer);
                    if (length > 0 && captionBuffer[length - 1] == '\n')
                        captionBuffer[length - 1] = '\0';
                }
                std::fclose(captionFile);
            }

            if (captionBuffer[0] != '\0')
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
        }

        if (disableControls)
        {
            mMouseManager->updateCursorMode();
            mInputWrapper->setMouseVisible(false);
            // TSP_VISIBLE_CURSOR_051_V47 -- computes all three terms itself, so
            // this is independent of whether V46 widened PointerManager's call.
            tspDrawCursor(windowManager,
                windowManager->getCursorVisible()
                    || (windowManager->isSettingsWindowVisible()
                           && SDL_IsTextInputActive() == SDL_FALSE)
                    || mControllerManager->tspMouseUsableNow());
            // TSP_MOUSE_MODE_051_V41
            // TSP_SETTINGS_CURSOR_RESTORE_051_V46 -- the settings term, lost when
            // the tree was reset and V38 re-anchored onto this design.
            MyGUI::PointerManager::getInstance().setVisible(
                windowManager->getCursorVisible()
                || (windowManager->isSettingsWindowVisible()
                       && SDL_IsTextInputActive() == SDL_FALSE)
                || mControllerManager->tspMouseUsableNow());
            return;
        }

        // Preserve the stock OpenMW 0.51 input update sequence.
        mBindingsManager->update(dt);
        mMouseManager->updateCursorMode();
        mControllerManager->update(dt);
        mMouseManager->update(dt);
        mSensorManager->update(dt);
        mActionManager->update(dt);

        // updateCursorMode can request SDL cursor visibility. Override it after
        // the stock 0.51 input update and render the same state with MyGUI.
        mInputWrapper->setMouseVisible(false);
        // TSP_MOUSE_MODE_051_V38 -- re-anchored. This tree mirrors the engine's own
        // cursor state into MyGUI instead of computing a separate shouldShow, so the
        // V13 anchor the original patcher used does not exist here. Widening the same
        // expression is the faithful port: tspSetMouseMode already calls
        // setCursorVisible(on), and this covers the paths that clear it behind us.
        // TSP_MOUSE_MODE_051_V41 -- now honours the active window's own opt-out.
        // TSP_SETTINGS_CURSOR_RESTORE_051_V46 -- see the disableControls path.
        MyGUI::PointerManager::getInstance().setVisible(
            windowManager->getCursorVisible()
            || (windowManager->isSettingsWindowVisible()
                   && SDL_IsTextInputActive() == SDL_FALSE)
            || mControllerManager->tspMouseUsableNow());

        // TSP_VISIBLE_CURSOR_051_V47
        tspDrawCursor(windowManager,
            windowManager->getCursorVisible()
                || (windowManager->isSettingsWindowVisible()
                       && SDL_IsTextInputActive() == SDL_FALSE)
                || mControllerManager->tspMouseUsableNow());
        if (Settings::input().mEnableGyroscope)
        {
            bool controllerAvailable = mControllerManager->isGyroAvailable();
            bool sensorAvailable = mSensorManager->isGyroAvailable();
            if (controllerAvailable || sensorAvailable)
            {
                mGyroManager->update(
                    dt,
                    controllerAvailable
                        ? mControllerManager->getGyroValues()
                        : mSensorManager->getGyroValues());
            }
        }
    }

    void InputManager::setDragDrop(bool dragDrop)
    {
        mBindingsManager->setDragDrop(dragDrop);
    }

    void InputManager::setGamepadGuiCursorEnabled(bool enabled)
    {
        mControllerManager->setGamepadGuiCursorEnabled(enabled);
    }

    bool InputManager::isGamepadGuiCursorEnabled()
    {
        return mControllerManager->gamepadGuiCursorEnabled();
    }

    void InputManager::changeInputMode(bool guiMode)
    {
        mControllerManager->setGuiCursorEnabled(guiMode);
        mMouseManager->setGuiCursorEnabled(guiMode);
        mGyroManager->setGuiCursorEnabled(guiMode);
        mMouseManager->setMouseLookEnabled(!guiMode);
        if (guiMode)
            MWBase::Environment::get().getWindowManager()->showCrosshair(false);

        bool isCursorVisible
            = guiMode && (!mControllerManager->joystickLastUsed() || mControllerManager->gamepadGuiCursorEnabled());
        MWBase::Environment::get().getWindowManager()->setCursorVisible(isCursorVisible);
        // if not in gui mode, the camera decides whether to show crosshair or not.
    }

    void InputManager::processChangedSettings(const Settings::CategorySettingVector& changed)
    {
        mSensorManager->processChangedSettings(changed);
    }

    bool InputManager::getControlSwitch(std::string_view sw)
    {
        return mControlSwitch->get(sw);
    }

    void InputManager::toggleControlSwitch(std::string_view sw, bool value)
    {
        mControlSwitch->set(sw, value);
    }

    void InputManager::resetIdleTime()
    {
        mActionManager->resetIdleTime();
    }

    bool InputManager::isIdle() const
    {
        return mActionManager->getIdleTime() > 0.5;
    }

    std::string_view InputManager::getActionDescription(int action) const
    {
        return mBindingsManager->getActionDescription(action);
    }

    std::string InputManager::getActionKeyBindingName(int action) const
    {
        return mBindingsManager->getActionKeyBindingName(action);
    }

    std::string InputManager::getActionControllerBindingName(int action) const
    {
        return mBindingsManager->getActionControllerBindingName(action);
    }

    bool InputManager::actionIsActive(int action) const
    {
        return mBindingsManager->actionIsActive(action);
    }

    float InputManager::getActionValue(int action) const
    {
        return mBindingsManager->getActionValue(action);
    }

    bool InputManager::isControllerButtonPressed(SDL_GameControllerButton button) const
    {
        return mControllerManager->isButtonPressed(button);
    }

    float InputManager::getControllerAxisValue(SDL_GameControllerAxis axis) const
    {
        return mControllerManager->getAxisValue(axis);
    }

    int InputManager::getMouseMoveX() const
    {
        return mMouseManager->getMouseMoveX();
    }

    int InputManager::getMouseMoveY() const
    {
        return mMouseManager->getMouseMoveY();
    }

    void InputManager::warpMouseToWidget(MyGUI::Widget* widget)
    {
        // This is currently used to simulate mouse movement when the gamepad UI is used.
        // Sometimes this is called in reaction to layout changes.
        // It's a bad idea to do this if the user triggered one with the actual mouse.

        // Don't warp if a gamepad wasn't in use when this was triggered.
        if (!joystickLastUsed())
            return;

        // Don't warp if the mouse button is actively being held.
        // TODO: this should be a method somewhere so that it can be reused in, e.g., Lua bindings
        if (SDL_GetMouseState(nullptr, nullptr) & SDL_BUTTON_LMASK)
            return;

        // Don't warp if an emulated mouse press is occurring.
        if (isGamepadGuiCursorEnabled() && isControllerButtonPressed(SDL_CONTROLLER_BUTTON_A))
            return;

        MWBase::Environment::get().getWindowManager()->setCursorVisible(false);
        mMouseManager->warpMouseToWidget(widget);
        mMouseManager->injectMouseMove(1, 0, 0);
        MWBase::Environment::get().getWindowManager()->setCursorActive(true);
    }

    const std::initializer_list<int>& InputManager::getActionKeySorting()
    {
        return mBindingsManager->getActionKeySorting();
    }

    const std::initializer_list<int>& InputManager::getActionControllerSorting()
    {
        return mBindingsManager->getActionControllerSorting();
    }

    void InputManager::enableDetectingBindingMode(int action, bool keyboard)
    {
        mBindingsManager->enableDetectingBindingMode(action, keyboard);
    }

    size_t InputManager::countSavedGameRecords() const
    {
        return mControlSwitch->countSavedGameRecords();
    }

    void InputManager::write(ESM::ESMWriter& writer, Loading::Listener& progress)
    {
        mControlSwitch->write(writer, progress);
    }

    void InputManager::readRecord(ESM::ESMReader& reader, uint32_t type)
    {
        if (type == ESM::REC_INPU)
        {
            mControlSwitch->readRecord(reader, type);
        }
    }

    void InputManager::resetToDefaultKeyBindings()
    {
        mBindingsManager->loadKeyDefaults(true);
    }

    void InputManager::resetToDefaultControllerBindings()
    {
        mBindingsManager->loadControllerDefaults(true);
    }

    void InputManager::setJoystickLastUsed(bool enabled)
    {
        mControllerManager->setJoystickLastUsed(enabled);
    }

    bool InputManager::joystickLastUsed()
    {
        return mControllerManager->joystickLastUsed();
    }

    std::string InputManager::getControllerButtonIcon(int button)
    {
        return mControllerManager->getControllerButtonIcon(button);
    }

    std::string InputManager::getControllerAxisIcon(int axis)
    {
        return mControllerManager->getControllerAxisIcon(axis);
    }

    void InputManager::executeAction(int action)
    {
        mActionManager->executeAction(action);
    }

    void InputManager::saveBindings()
    {
        mBindingsManager->saveBindings();
    }
}
