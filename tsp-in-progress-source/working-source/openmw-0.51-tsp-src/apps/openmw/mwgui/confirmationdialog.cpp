#include <components/debug/debuglog.hpp>
#include <cstdio>
#include "confirmationdialog.hpp"

#include <MyGUI_Button.h>
#include <MyGUI_EditBox.h>

#include <components/settings/values.hpp>

#include "../mwbase/environment.hpp"
#include "../mwbase/windowmanager.hpp"

namespace MWGui
{
    ConfirmationDialog::ConfirmationDialog()
        : WindowModal("openmw_confirmation_dialog.layout")
    {
        getWidget(mMessage, "Message");
        getWidget(mOkButton, "OkButton");
        getWidget(mCancelButton, "CancelButton");

        mCancelButton->eventMouseButtonClick += MyGUI::newDelegate(this, &ConfirmationDialog::onCancelButtonClicked);
        mOkButton->eventMouseButtonClick += MyGUI::newDelegate(this, &ConfirmationDialog::onOkButtonClicked);

        if (Settings::gui().mControllerMenus)
        {
            mDisableGamepadCursor = true;
            mControllerButtons.mA = "#{Interface:OK}";
            mControllerButtons.mB = "#{Interface:Cancel}";
        }
    }

    void ConfirmationDialog::askForConfirmation(const std::string& message)
    {
        setVisible(true);

        mMessage->setCaptionWithReplacing(message);

        int height = mMessage->getTextSize().height + 60;

        int width = mMessage->getTextSize().width + 24;

        mMainWidget->setSize(width, height);

        mMessage->setSize(mMessage->getWidth(), mMessage->getTextSize().height + 24);

        MWBase::Environment::get().getWindowManager()->setKeyFocusWidget(mOkButton);

        if (Settings::gui().mControllerMenus)
        {
            mOkButtonFocus = true;
            mOkButton->setStateSelected(true);
            mCancelButton->setStateSelected(false);
        }

        center();
    }

    bool ConfirmationDialog::exit()
    {
        setVisible(false);
        eventCancelClicked();
        return true;
    }

    void ConfirmationDialog::onCancelButtonClicked(MyGUI::Widget* /*sender*/)
    {

        // TSP_A_CONFIRM_CANCEL_V16
        if (std::FILE* tspFlagV16
            = std::fopen("/tmp/openmw-tsp-a-debug", "r"))
        {
            std::fclose(tspFlagV16);

            Log(Debug::Warning)
                << "TSP_A_CONFIRM_CANCEL_V16";
        }

        exit();
    }

    void ConfirmationDialog::onOkButtonClicked(MyGUI::Widget* /*sender*/)
    {

        // TSP_A_CONFIRM_OK_V16
        if (std::FILE* tspFlagV16
            = std::fopen("/tmp/openmw-tsp-a-debug", "r"))
        {
            std::fclose(tspFlagV16);

            Log(Debug::Warning)
                << "TSP_A_CONFIRM_OK_V16";
        }

        setVisible(false);

        eventOkClicked();
    }

    bool ConfirmationDialog::onControllerButtonEvent(const SDL_ControllerButtonEvent& arg)
    {
        if (arg.button == SDL_CONTROLLER_BUTTON_A)
        {

            // TSP_A_CONFIRM_CHILD_V16
            if (std::FILE* tspFlagV16
                = std::fopen("/tmp/openmw-tsp-a-debug", "r"))
            {
                std::fclose(tspFlagV16);

                Log(Debug::Warning)
                    << "TSP_A_CONFIRM_CHILD_V16"
                    << " okFocus="
                    << (mOkButtonFocus ? 1 : 0);
            }

            if (mOkButtonFocus)
                onOkButtonClicked(mOkButton);
            else
                onCancelButtonClicked(mCancelButton);
        }
        else if (arg.button == SDL_CONTROLLER_BUTTON_B)
        {
            onCancelButtonClicked(mCancelButton);
        }
        else if ((arg.button == SDL_CONTROLLER_BUTTON_DPAD_LEFT && !mOkButtonFocus)
            || (arg.button == SDL_CONTROLLER_BUTTON_DPAD_RIGHT && mOkButtonFocus))
        {
            mOkButtonFocus = !mOkButtonFocus;
            mOkButton->setStateSelected(mOkButtonFocus);
            mCancelButton->setStateSelected(!mOkButtonFocus);
        }

        return true;
    }
}
