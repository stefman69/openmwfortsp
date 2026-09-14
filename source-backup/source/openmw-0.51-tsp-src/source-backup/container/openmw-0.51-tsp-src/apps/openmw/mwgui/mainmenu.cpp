#include "mainmenu.hpp"

#include <MyGUI_Gui.h>
#include <MyGUI_InputManager.h>
#include <MyGUI_RenderManager.h>
#include <MyGUI_TextBox.h>

#include <components/misc/frameratelimiter.hpp>
#include <components/settings/values.hpp>
#include <components/vfs/manager.hpp>
#include <components/vfs/pathutil.hpp>
#include <components/widgets/imagebutton.hpp>

#include "../mwbase/environment.hpp"
#include "../mwbase/statemanager.hpp"
#include "../mwbase/windowmanager.hpp"
#include "../mwbase/world.hpp"

#include "../mwworld/globals.hpp"

#include "backgroundimage.hpp"
#include "confirmationdialog.hpp"
#include "savegamedialog.hpp"
#include "settingswindow.hpp"
#include "videowidget.hpp"

namespace MWGui
{
    void MenuVideo::run()
    {
        Misc::FrameRateLimiter frameRateLimiter
            = Misc::makeFrameRateLimiter(MWBase::Environment::get().getFrameRateLimit());
        const MWBase::WindowManager& windowManager = *MWBase::Environment::get().getWindowManager();
        bool paused = false;
        while (mRunning)
        {
            if (windowManager.isWindowVisible())
            {
                if (paused)
                {
                    mVideo->resume();
                    paused = false;
                }
                // If finished playing, start again
                if (!mVideo->update())
                    mVideo->playVideo("video\\menu_background.bik");
            }
            else if (!paused)
            {
                paused = true;
                mVideo->pause();
            }
            frameRateLimiter.limit();
        }
    }

    MenuVideo::MenuVideo(const VFS::Manager* vfs)
        : mRunning(true)
    {
        // Use black background to correct aspect ratio
        mVideoBackground = MyGUI::Gui::getInstance().createWidgetReal<MyGUI::ImageBox>(
            "ImageBox", 0, 0, 1, 1, MyGUI::Align::Default, "MainMenuBackground");
        mVideoBackground->setImageTexture("black");

        mVideo = mVideoBackground->createWidget<VideoWidget>(
            "ImageBox", 0, 0, 1, 1, MyGUI::Align::Stretch, "MainMenuBackground");
        mVideo->setVFS(vfs);

        mVideo->playVideo("video\\menu_background.bik");
        mThread = std::thread([this] { run(); });
    }

    void MenuVideo::resize(int screenWidth, int screenHeight)
    {
        const bool stretch = Settings::gui().mStretchMenuBackground;
        mVideoBackground->setSize(screenWidth, screenHeight);
        mVideo->autoResize(stretch);
        mVideo->setVisible(true);
    }

    MenuVideo::~MenuVideo()
    {
        mRunning = false;
        mThread.join();
        try
        {
            MyGUI::Gui::getInstance().destroyWidget(mVideoBackground);
        }
        catch (const MyGUI::Exception& e)
        {
            Log(Debug::Error) << "Error in the destructor: " << e.what();
        }
    }

    MainMenu::MainMenu(int w, int h, const VFS::Manager* vfs, const std::string& versionDescription)
        : WindowBase("openmw_mainmenu.layout")
        , mWidth(w)
        , mHeight(h)
        , mVFS(vfs)
        , mButtonBox(nullptr)
        , mBackground(nullptr)
    {
        getWidget(mVersionText, "VersionText");
        mVersionText->setCaption(versionDescription);

        constexpr VFS::Path::NormalizedView menuBackgroundVideo("video/menu_background.bik");

        mHasAnimatedMenu = mVFS->exists(menuBackgroundVideo);
        mDisableGamepadCursor = Settings::gui().mControllerMenus;

        updateMenu();
    }

    void MainMenu::onResChange(int w, int h)
    {
        mWidth = w;
        mHeight = h;

        updateMenu();
        if (mVideo)
            mVideo->resize(w, h);
    }

    void MainMenu::setVisible(bool visible)
    {
        if (visible)
            updateMenu();

        bool isMainMenu = MWBase::Environment::get().getWindowManager()->containsMode(MWGui::GM_MainMenu)
            && MWBase::Environment::get().getStateManager()->getState() == MWBase::StateManager::State_NoGame;

        showBackground(isMainMenu);

        if (visible)
        {
            if (isMainMenu)
            {
                if (mButtons["loadgame"]->getVisible())
                    MWBase::Environment::get().getWindowManager()->setKeyFocusWidget(mButtons["loadgame"]);
                else
                    MWBase::Environment::get().getWindowManager()->setKeyFocusWidget(mButtons["newgame"]);
            }
            else
                MWBase::Environment::get().getWindowManager()->setKeyFocusWidget(mButtons["return"]);
        }

        Layout::setVisible(visible);
    }

    void MainMenu::onNewGameConfirmed()
    {
        MWBase::Environment::get().getWindowManager()->removeGuiMode(MWGui::GM_MainMenu);
        MWBase::Environment::get().getStateManager()->newGame();
    }

    void MainMenu::onExitConfirmed()
    {
        MWBase::Environment::get().getStateManager()->requestQuit();
    }

    void MainMenu::onButtonClicked(MyGUI::Widget* sender)
    {
        MWBase::WindowManager* winMgr = MWBase::Environment::get().getWindowManager();

        const std::string& name = *sender->getUserData<std::string>();
        winMgr->playSound(ESM::RefId::stringRefId("Menu Click"));
        if (name == "return")
            winMgr->removeGuiMode(GM_MainMenu);
        else if (name == "credits")
            winMgr->playVideo("mw_credits.bik", true);
        else if (name == "exitgame")
        {
            if (MWBase::Environment::get().getStateManager()->getState() == MWBase::StateManager::State_NoGame)
                onExitConfirmed();
            else
            {
                ConfirmationDialog* dialog = winMgr->getConfirmationDialog();
                dialog->askForConfirmation("#{OMWEngine:QuitGameConfirmation}");
                dialog->eventOkClicked.clear();
                dialog->eventOkClicked += MyGUI::newDelegate(this, &MainMenu::onExitConfirmed);
                dialog->eventCancelClicked.clear();
            }
        }
        else if (name == "newgame")
        {
            if (MWBase::Environment::get().getStateManager()->getState() == MWBase::StateManager::State_NoGame)
                onNewGameConfirmed();
            else
            {
                ConfirmationDialog* dialog = winMgr->getConfirmationDialog();
                dialog->askForConfirmation("#{OMWEngine:NewGameConfirmation}");
                dialog->eventOkClicked.clear();
                dialog->eventOkClicked += MyGUI::newDelegate(this, &MainMenu::onNewGameConfirmed);
                dialog->eventCancelClicked.clear();
            }
        }
        else if (name == "loadgame" || name == "savegame")
        {
            if (!mSaveGameDialog)
                mSaveGameDialog = std::make_unique<SaveGameDialog>();
            mSaveGameDialog->setLoadOrSave(name == "loadgame");
            mSaveGameDialog->setVisible(true);
        }

        if (winMgr->isSettingsWindowVisible() || name == "options")
        {
            winMgr->toggleSettingsWindow();
        }
    }

    bool MainMenu::onControllerButtonEvent(const SDL_ControllerButtonEvent& arg)
    {
        if (arg.button == SDL_CONTROLLER_BUTTON_A)
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
        }
        else if (arg.button == SDL_CONTROLLER_BUTTON_B || arg.button == SDL_CONTROLLER_BUTTON_START)
        {
            if (mButtons["return"]->getVisible())
                onButtonClicked(mButtons["return"]);
            else
                MWBase::Environment::get().getWindowManager()->injectKeyPress(MyGUI::KeyCode::Escape, 0, false);
        }
        else if (arg.button == SDL_CONTROLLER_BUTTON_DPAD_UP
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
        }
        return true;
    }

    void MainMenu::showBackground(bool show)
    {
        if (mVideo && !show)
        {
            mVideo.reset();
        }
        if (mBackground && !show)
        {
            MyGUI::Gui::getInstance().destroyWidget(mBackground);
            mBackground = nullptr;
        }

        if (!show)
            return;

        const bool stretch = Settings::gui().mStretchMenuBackground;

        if (mHasAnimatedMenu)
        {
            if (!mVideo)
                mVideo.emplace(mVFS);

            const auto& viewSize = MyGUI::RenderManager::getInstance().getViewSize();
            int screenWidth = viewSize.width;
            int screenHeight = viewSize.height;
            mVideo->resize(screenWidth, screenHeight);
        }
        else
        {
            if (!mBackground)
            {
                mBackground = MyGUI::Gui::getInstance().createWidgetReal<BackgroundImage>(
                    "ImageBox", 0, 0, 1, 1, MyGUI::Align::Stretch, "MainMenuBackground");
                mBackground->setBackgroundImage("textures\\menu_morrowind.dds", true, stretch);
            }
            mBackground->setVisible(true);
        }
    }

    bool MainMenu::exit()
    {
        if (MWBase::Environment::get().getWindowManager()->isSettingsWindowVisible())
        {
            MWBase::Environment::get().getWindowManager()->toggleSettingsWindow();
            return false;
        }

        return MWBase::Environment::get().getStateManager()->getState() == MWBase::StateManager::State_Running;
    }

    void MainMenu::updateMenu()
    {
        setCoord(0, 0, mWidth, mHeight);

        if (!mButtonBox)
            mButtonBox
                = mMainWidget->createWidget<MyGUI::Widget>({}, MyGUI::IntCoord(0, 0, 0, 0), MyGUI::Align::Default);

        int curH = 0;

        MWBase::StateManager::State state = MWBase::Environment::get().getStateManager()->getState();

        mVersionText->setVisible(state == MWBase::StateManager::State_NoGame);

        std::vector<std::string> buttons;

        if (state == MWBase::StateManager::State_Running)
            buttons.emplace_back("return");

        buttons.emplace_back("newgame");

        if (state == MWBase::StateManager::State_Running
            && MWBase::Environment::get().getWorld()->getGlobalInt(MWWorld::Globals::sCharGenState) == -1
            && MWBase::Environment::get().getWindowManager()->isSavingAllowed())
            buttons.emplace_back("savegame");

        if (MWBase::Environment::get().getStateManager()->characterBegin()
            != MWBase::Environment::get().getStateManager()->characterEnd())
            buttons.emplace_back("loadgame");

        buttons.emplace_back("options");

        if (state == MWBase::StateManager::State_NoGame)
            buttons.emplace_back("credits");

        buttons.emplace_back("exitgame");

        // Create new buttons if needed
        for (std::string_view id : { "return", "newgame", "savegame", "loadgame", "options", "credits", "exitgame" })
        {
            if (mButtons.find(id) == mButtons.end())
            {
                Gui::ImageButton* button = mButtonBox->createWidget<Gui::ImageButton>(
                    "ImageBox", MyGUI::IntCoord(0, curH, 0, 0), MyGUI::Align::Default);
                const std::string& buttonId = mButtons.emplace(id, button).first->first;
                button->setProperty("ImageHighlighted", "textures\\menu_" + buttonId + "_over.dds");
                button->setProperty("ImageNormal", "textures\\menu_" + buttonId + ".dds");
                button->setProperty("ImagePushed", "textures\\menu_" + buttonId + "_pressed.dds");
                button->eventMouseButtonClick += MyGUI::newDelegate(this, &MainMenu::onButtonClicked);
                button->setUserData(buttonId);
            }
        }

        // Start by hiding all buttons
        int maxwidth = 0;
        for (const auto& buttonPair : mButtons)
        {
            buttonPair.second->setVisible(false);
            MyGUI::IntSize requested = buttonPair.second->getRequestedSize();
            if (requested.width > maxwidth)
                maxwidth = requested.width;
        }

        // Now show and position the ones we want
        for (const std::string& buttonId : buttons)
        {
            auto it = mButtons.find(buttonId);
            assert(it != mButtons.end());
            Gui::ImageButton* button = it->second;
            button->setVisible(true);

            // By default, assume that all menu buttons textures should have 64 height.
            // If they have a different resolution, scale them.
            MyGUI::IntSize requested = button->getRequestedSize();
            float scale = requested.height / 64.f;

            button->setImageCoord(MyGUI::IntCoord(0, 0, requested.width, requested.height));
            // Trim off some of the excessive padding
            // TODO: perhaps do this within ImageButton?
            int height = requested.height;
            button->setImageTile(MyGUI::IntSize(requested.width, static_cast<int>(requested.height - 16 * scale)));
            button->setCoord(static_cast<int>((maxwidth - requested.width / scale) / 2), curH,
                static_cast<int>(requested.width / scale), static_cast<int>(height / scale - 16));
            curH += static_cast<int>(height / scale - 16);
        }

        if (state == MWBase::StateManager::State_NoGame)
        {
            // Align with the background image
            int bottomPadding = 24;
            mButtonBox->setCoord(mWidth / 2 - maxwidth / 2, mHeight - curH - bottomPadding, maxwidth, curH);
        }
        else
            mButtonBox->setCoord(mWidth / 2 - maxwidth / 2, mHeight / 2 - curH / 2, maxwidth, curH);
    }
}
