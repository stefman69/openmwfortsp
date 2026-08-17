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
#include <MyGUI_RenderManager.h>
#include <MyGUI_TextBox.h>
#include <cstdio>
#include <cstring>
#include <MyGUI_PointerManager.h>
#include <MyGUI_ImageBox.h>
#include <cstdlib>

namespace MWInput
{
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

        // TSP_CURSOR_RUNTIME_DEBUG_051_V10
        // Diagnostic only. No input/cursor state is modified here.
        auto tspLogCursorState = [&]()
        {
            // TSP_PERF_QUIET_CURSOR_GATE_051_V20
            static const bool tspV20CursorDebugEnabled = [] {
                const char* value = std::getenv("OPENMW_TSP_DEEP_DEBUG");

                if (value == nullptr || *value == '\0')
                    return false;

                return !(std::strcmp(value, "0") == 0
                    || std::strcmp(value, "false") == 0
                    || std::strcmp(value, "off") == 0
                    || std::strcmp(value, "no") == 0);
            }();

            if (!tspV20CursorDebugEnabled)
                return;

            static bool initialized = false;
            static bool lastGui = false;
            static bool lastWindowCursor = false;
            static bool lastMyGuiVisible = false;
            static bool lastText = false;
            static int lastSdlCursor = -999;
            static unsigned int frames = 0;

            int mouseX = 0;
            int mouseY = 0;
            SDL_GetMouseState(&mouseX, &mouseY);

            const bool gui = windowManager->isGuiMode();
            const bool windowCursor = windowManager->getCursorVisible();
            const bool myGuiVisible
                = MyGUI::PointerManager::getInstance().isVisible();
            const bool textActive = SDL_IsTextInputActive() == SDL_TRUE;
            const int sdlCursor = SDL_ShowCursor(SDL_QUERY);

            ++frames;

            const bool changed
                = !initialized
                || gui != lastGui
                || windowCursor != lastWindowCursor
                || myGuiVisible != lastMyGuiVisible
                || textActive != lastText
                || sdlCursor != lastSdlCursor;

            if (changed || (frames % 120u) == 0u)
            {
                std::fprintf(
                    stderr,
                    "TSP_CURSOR_DEBUG "
                    "gui=%d windowCursor=%d myguiVisible=%d "
                    "sdlCursor=%d text=%d mouse=%d,%d\n",
                    gui ? 1 : 0,
                    windowCursor ? 1 : 0,
                    myGuiVisible ? 1 : 0,
                    sdlCursor,
                    textActive ? 1 : 0,
                    mouseX,
                    mouseY);
                std::fflush(stderr);

                initialized = true;
                lastGui = gui;
                lastWindowCursor = windowCursor;
                lastMyGuiVisible = myGuiVisible;
                lastText = textActive;
                lastSdlCursor = sdlCursor;
            }
        };

        // TSP_ORDINARY_MYGUI_TEST_CURSOR_051_V11
        // Ordinary widget diagnostic cursor. This bypasses PointerManager's
        // special pointer rendering and uses the same general widget path as
        // normal OpenMW menu text.
        // TSP_ORDINARY_MYGUI_TEST_CURSOR_051_V11
        // TSP_ORDINARY_MYGUI_IMAGE_CURSOR_051_V12
        auto tspUpdateOrdinaryTestCursor = [&]()
        {
            static MyGUI::ImageBox* testCursor = nullptr;
            static bool lastVisible = false;

            int mouseX = 0;
            int mouseY = 0;
            SDL_GetMouseState(&mouseX, &mouseY);

            // TSP_SETTINGS_ONLY_MOUSE_051_V13
            const bool shouldShow
                = windowManager->isSettingsWindowVisible()
                && SDL_IsTextInputActive() == SDL_FALSE;

            if (testCursor == nullptr)
            {
                testCursor
                    = MyGUI::Gui::getInstance().createWidget<MyGUI::ImageBox>(
                        "ImageBox",
                        MyGUI::IntCoord(0, 0, 40, 40),
                        MyGUI::Align::Default,
                        "Popup");

                testCursor->setImageTexture("tsp_cursor.png");
                testCursor->setNeedMouseFocus(false);
                testCursor->setVisible(false);

                std::fprintf(
                    stderr,
                    "TSP_REAL_CURSOR created=1 texture=tsp_cursor.png "
                    "layer=Popup size=40x40 hotspot=1,0\n");
                std::fflush(stderr);
            }

            const int x = mouseX > 0 ? mouseX - 1 : 0;
            const int y = mouseY >= 0 ? mouseY : 0;

            testCursor->setPosition(x, y);
            testCursor->setVisible(shouldShow);

            if (shouldShow != lastVisible)
            {
                std::fprintf(
                    stderr,
                    "TSP_REAL_CURSOR visible=%d mouse=%d,%d widget=%d,%d\n",
                    shouldShow ? 1 : 0,
                    mouseX,
                    mouseY,
                    x,
                    y);
                std::fflush(stderr);
                lastVisible = shouldShow;
            }
        };

        // TSP_MYGUI_CURSOR_INPUT_FORCE_051_V9
        // Use the same layer that produced the working OpenMW 0.48
        // TSP cursor: InputManager owns the final software-pointer
        // visibility decision. In GUI mode the MyGUI pointer is always
        // visible, independent of SDL hardware-cursor state.
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

        static bool tspPreviousTextEntryActive = false;
        static MyGUI::TextBox* tspTextIndicator = nullptr;
        static std::string tspLastIndicatorCaption;

        if (tspTextEntryActive != tspPreviousTextEntryActive)
        {
            if (tspTextEntryActive)
            {
                if (std::FILE* flag = std::fopen(
                        "/tmp/openmw-tsp-text-active", "w"))
                {
                    std::fputs("1\n", flag);
                    std::fclose(flag);
                }
            }
            else
            {
                std::remove("/tmp/openmw-tsp-text-active");
                std::remove("/tmp/openmw-tsp-text-char");

                if (tspTextIndicator != nullptr)
                {
                    MyGUI::Gui::getInstance().destroyWidget(tspTextIndicator);
                    tspTextIndicator = nullptr;
                    tspLastIndicatorCaption.clear();
                }
            }

            tspPreviousTextEntryActive = tspTextEntryActive;
        }

        if (tspTextEntryActive)
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

        if (disableControls)
        {
            mMouseManager->updateCursorMode();
            mInputWrapper->setMouseVisible(false);
            MyGUI::PointerManager::getInstance().setVisible(windowManager->isGuiMode());
            tspLogCursorState();
            tspUpdateOrdinaryTestCursor();
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
        MyGUI::PointerManager::getInstance().setVisible(windowManager->isGuiMode());
        tspLogCursorState();
        tspUpdateOrdinaryTestCursor();

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
