#!/bin/bash
set -euo pipefail

MARKER="TSP_SOFTWARE_CURSOR_V1"
SOURCE_DIR="${1:-}"

if [ -z "$SOURCE_DIR" ]; then
    for candidate in \
        /root/openmw-0.48.0 \
        /root/openmw-0.48 \
        /root/OpenMW-0.48.0 \
        /root/openmw \
        /root/OpenMW
    do
        if [ -f "$candidate/apps/openmw/mwinput/inputmanagerimp.cpp" ]; then
            SOURCE_DIR="$candidate"
            break
        fi
    done
fi

if [ -z "$SOURCE_DIR" ]; then
    MATCH="$(find /root -maxdepth 5 -type f \
        -path '*/apps/openmw/mwinput/inputmanagerimp.cpp' \
        -print -quit 2>/dev/null || true)"

    if [ -n "$MATCH" ]; then
        SOURCE_DIR="${MATCH%/apps/openmw/mwinput/inputmanagerimp.cpp}"
    fi
fi

if [ -z "$SOURCE_DIR" ]; then
    echo "ERROR: Could not locate the OpenMW source directory."
    echo "Run:"
    echo "/root/apply_openmw_048_tsp_cursor.sh /path/to/openmw-source"
    exit 1
fi

CPP="$SOURCE_DIR/apps/openmw/mwinput/inputmanagerimp.cpp"
HPP="$SOURCE_DIR/apps/openmw/mwinput/inputmanagerimp.hpp"

if [ ! -f "$CPP" ] || [ ! -f "$HPP" ]; then
    echo "ERROR: This does not look like an OpenMW source directory:"
    echo "$SOURCE_DIR"
    exit 1
fi

echo "=========================================="
echo "Applying OpenMW 0.48 TSP software cursor"
echo "=========================================="
echo "Source directory: $SOURCE_DIR"

if grep -q "$MARKER" "$CPP"; then
    echo "The cursor patch is already applied."
    exit 0
fi

cp -f "$CPP" "$CPP.before-tsp-software-cursor"
cp -f "$HPP" "$HPP.before-tsp-software-cursor"

python3 - "$CPP" "$HPP" <<'PY'
from pathlib import Path
import sys

cpp_path = Path(sys.argv[1])
hpp_path = Path(sys.argv[2])

cpp = cpp_path.read_text(encoding="utf-8")
hpp = hpp_path.read_text(encoding="utf-8")

def replace_once(text, old, new, label):
    count = text.count(old)
    if count != 1:
        raise RuntimeError(
            "{} replacement expected exactly once, found {}".format(label, count)
        )
    return text.replace(old, new, 1)

cpp = replace_once(
    cpp,
    '#include <osgViewer/ViewerEventHandlers>\n',
    '''#include <osgViewer/ViewerEventHandlers>

#include <MyGUI_Gui.h>
#include <MyGUI_ImageBox.h>
#include <MyGUI_InputManager.h>
''',
    "MyGUI includes",
)

cpp = replace_once(
    cpp,
    '''namespace MWInput
{
    InputManager::InputManager(
''',
    '''namespace MWInput
{
    // TSP_SOFTWARE_CURSOR_V1
    namespace
    {
        bool ensureTspSoftwareCursor(MyGUI::ImageBox*& cursor)
        {
            if (cursor != nullptr)
                return true;

            if (MyGUI::Gui::getInstancePtr() == nullptr)
                return false;

            constexpr int cursorWidth = 40;
            constexpr int cursorHeight = 40;

            cursor = MyGUI::Gui::getInstance().createWidget<MyGUI::ImageBox>(
                "ImageBox",
                0,
                0,
                cursorWidth,
                cursorHeight,
                MyGUI::Align::Default,
                "Pointer");

            cursor->setImageTexture("textures\\\\tsp_cursor.png");
            cursor->setImageCoord(
                MyGUI::IntCoord(0, 0, cursorWidth, cursorHeight));
            cursor->setNeedMouseFocus(false);
            cursor->setNeedKeyFocus(false);
            cursor->setVisible(false);

            return true;
        }

        void updateTspSoftwareCursor(
            MyGUI::ImageBox* cursor,
            bool visible)
        {
            if (cursor == nullptr)
                return;

            cursor->setVisible(visible);

            if (!visible)
                return;

            constexpr int cursorWidth = 40;
            constexpr int cursorHeight = 40;
            constexpr int hotspotX = 4;
            constexpr int hotspotY = 3;

            const MyGUI::IntPoint position
                = MyGUI::InputManager::getInstance().getMousePosition();

            cursor->setCoord(
                position.left - hotspotX,
                position.top - hotspotY,
                cursorWidth,
                cursorHeight);
        }
    }

    InputManager::InputManager(
''',
    "software cursor implementation",
)

cpp = replace_once(
    cpp,
    '    InputManager::~InputManager() {}\n',
    '''    InputManager::~InputManager()
    {
        if (mTspSoftwareCursor != nullptr
            && MyGUI::Gui::getInstancePtr() != nullptr)
        {
            MyGUI::Gui::getInstance().destroyWidget(mTspSoftwareCursor);
        }

        mTspSoftwareCursor = nullptr;
    }
''',
    "destructor",
)

old_update = '''    void InputManager::update(float dt, bool disableControls, bool disableEvents)
    {
        mControlsDisabled = disableControls;
        mInputWrapper->setMouseVisible(MWBase::Environment::get().getWindowManager()->getCursorVisible());
        mInputWrapper->capture(disableEvents);

        if (disableControls)
        {
            mMouseManager->updateCursorMode();
            return;
        }

        mBindingsManager->update(dt);

        mMouseManager->updateCursorMode();
        bool controllerMove = mControllerManager->update(dt);
        mMouseManager->update(dt);
        mSensorManager->update(dt);
        mActionManager->update(dt, controllerMove);
        if (mGyroManager->isEnabled())
        {
            bool controllerAvailable = mControllerManager->isGyroAvailable();
            bool sensorAvailable = mSensorManager->isGyroAvailable();
            if (controllerAvailable || sensorAvailable)
            {
                mGyroManager->update(dt,
                    controllerAvailable ? mControllerManager->getGyroValues() : mSensorManager->getGyroValues());
            }
        }
    }
'''

new_update = '''    void InputManager::update(float dt, bool disableControls, bool disableEvents)
    {
        mControlsDisabled = disableControls;

        MWBase::WindowManager* windowManager
            = MWBase::Environment::get().getWindowManager();

        mInputWrapper->setMouseVisible(windowManager->getCursorVisible());
        mInputWrapper->capture(disableEvents);

        const bool selectPressed
            = mControllerManager->isButtonPressed(
                SDL_CONTROLLER_BUTTON_BACK);

        const bool leftShoulderPressed
            = mControllerManager->isButtonPressed(
                SDL_CONTROLLER_BUTTON_LEFTSHOULDER);

        if (leftShoulderPressed
            && !mTspLeftShoulderWasPressed
            && mTspMouseModeEnabled)
        {
            mTspTextModeEnabled = true;
        }

        if (selectPressed && !mTspSelectWasPressed)
        {
            if (mTspTextModeEnabled)
            {
                // Select leaves text entry and returns to mouse mode.
                mTspTextModeEnabled = false;
            }
            else
            {
                // Select toggles normal gameplay and mouse mode.
                mTspMouseModeEnabled = !mTspMouseModeEnabled;
            }
        }

        mTspSelectWasPressed = selectPressed;
        mTspLeftShoulderWasPressed = leftShoulderPressed;

        const bool wantSoftwareCursor
            = mTspMouseModeEnabled && windowManager->isGuiMode();

        const bool softwareCursorActive
            = wantSoftwareCursor
            && ensureTspSoftwareCursor(mTspSoftwareCursor);

        mInputWrapper->setMouseVisible(
            windowManager->getCursorVisible()
            && !softwareCursorActive);

        if (disableControls)
        {
            mMouseManager->updateCursorMode();
            updateTspSoftwareCursor(
                mTspSoftwareCursor,
                softwareCursorActive);
            return;
        }

        mBindingsManager->update(dt);

        mMouseManager->updateCursorMode();
        bool controllerMove = mControllerManager->update(dt);
        mMouseManager->update(dt);
        mSensorManager->update(dt);
        mActionManager->update(dt, controllerMove);
        if (mGyroManager->isEnabled())
        {
            bool controllerAvailable = mControllerManager->isGyroAvailable();
            bool sensorAvailable = mSensorManager->isGyroAvailable();
            if (controllerAvailable || sensorAvailable)
            {
                mGyroManager->update(dt,
                    controllerAvailable ? mControllerManager->getGyroValues() : mSensorManager->getGyroValues());
            }
        }

        updateTspSoftwareCursor(
            mTspSoftwareCursor,
            softwareCursorActive);
    }
'''

cpp = replace_once(
    cpp,
    old_update,
    new_update,
    "InputManager::update",
)

hpp = replace_once(
    hpp,
    '''namespace SDLUtil
{
    class InputWrapper;
}

struct SDL_Window;
''',
    '''namespace SDLUtil
{
    class InputWrapper;
}

namespace MyGUI
{
    class ImageBox;
}

struct SDL_Window;
''',
    "MyGUI forward declaration",
)

hpp = replace_once(
    hpp,
    '''        std::unique_ptr<ControllerManager> mControllerManager;
        std::unique_ptr<SensorManager> mSensorManager;
        std::unique_ptr<GyroManager> mGyroManager;
''',
    '''        std::unique_ptr<ControllerManager> mControllerManager;
        std::unique_ptr<SensorManager> mSensorManager;
        std::unique_ptr<GyroManager> mGyroManager;

        MyGUI::ImageBox* mTspSoftwareCursor = nullptr;
        bool mTspMouseModeEnabled = false;
        bool mTspTextModeEnabled = false;
        bool mTspSelectWasPressed = false;
        bool mTspLeftShoulderWasPressed = false;
''',
    "cursor member fields",
)

with open(cpp_path, "w", encoding="utf-8", newline="\n") as handle:
    handle.write(cpp)

with open(hpp_path, "w", encoding="utf-8", newline="\n") as handle:
    handle.write(hpp)

print("Patched:")
print(cpp_path)
print(hpp_path)
PY

echo ""
echo "Patch applied successfully."
echo ""
echo "Copy tsp_cursor.png to:"
echo "/mnt/SDCARD/data/ports/openmw/resources/vfs/textures/tsp_cursor.png"
echo ""
echo "Then rebuild OpenMW normally."
