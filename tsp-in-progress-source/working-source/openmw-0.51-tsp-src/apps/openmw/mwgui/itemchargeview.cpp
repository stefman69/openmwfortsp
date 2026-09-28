#include "itemchargeview.hpp"

#include <algorithm>
#include <SDL_gamecontroller.h>
#include <set>

#include <MyGUI_FactoryManager.h>
#include <MyGUI_Gui.h>
#include <MyGUI_ScrollView.h>

#include <components/esm3/loadench.hpp>
#include <components/settings/values.hpp>

#include "../mwbase/environment.hpp"
#include "../mwbase/windowmanager.hpp"

#include "../mwmechanics/spellutil.hpp"

#include "../mwworld/class.hpp"
#include "../mwworld/esmstore.hpp"

#include "itemmodel.hpp"
#include "itemwidget.hpp"
#include "textcolours.hpp"
#include "windowbase.hpp"

namespace MWGui
{
    ItemChargeView::ItemChargeView()
        : mScrollView(nullptr)
        , mDisplayMode(DisplayMode_Health)
    {
    }

    void ItemChargeView::registerComponents()
    {
        MyGUI::FactoryManager::getInstance().registerFactory<ItemChargeView>("Widget");
    }

    void ItemChargeView::initialiseOverride()
    {
        Base::initialiseOverride();

        assignWidget(mScrollView, "ScrollView");
        if (mScrollView == nullptr)
            throw std::runtime_error("Item charge view needs a scroll view");

        mScrollView->setCanvasAlign(MyGUI::Align::Left | MyGUI::Align::Top);
        mScrollView->setUserString(
            "TSP_HAMMER_REPAIR_FONT_051_V2", "1");
    }

    void ItemChargeView::setModel(ItemModel* model)
    {
        mModel.reset(model);
    }

    void ItemChargeView::setDisplayMode(ItemChargeView::DisplayMode type)
    {
        mDisplayMode = type;
        update();
    }

    void ItemChargeView::update()
    {
        if (!mModel.get())
        {
            layoutWidgets();
            return;
        }

        mModel->update();

        Lines lines;
        std::set<Lines::const_iterator> visitedLines;

        for (size_t i = 0; i < mModel->getItemCount(); ++i)
        {
            ItemStack stack = mModel->getItem(static_cast<ItemModel::ModelIndex>(i));

            bool found = false;
            for (Lines::const_iterator iter = mLines.begin(); iter != mLines.end(); ++iter)
            {
                if (iter->mItemPtr == stack.mBase)
                {
                    found = true;
                    visitedLines.insert(iter);

                    // update line widgets
                    updateLine(*iter);
                    lines.push_back(*iter);
                    break;
                }
            }

            if (!found)
            {
                // add line widgets
                Line line;
                line.mItemPtr = stack.mBase;

                line.mText
                    = mScrollView->createWidget<MyGUI::TextBox>("SandText", MyGUI::IntCoord(), MyGUI::Align::Default);
                line.mText->setNeedMouseFocus(false);

                line.mIcon = mScrollView->createWidget<ItemWidget>(
                    "MW_ItemIconSmall", MyGUI::IntCoord(), MyGUI::Align::Default);
                line.mIcon->setItem(line.mItemPtr);
                line.mIcon->setUserString("ToolTipType", "ItemPtr");
                line.mIcon->setUserData(MWWorld::Ptr(line.mItemPtr));
                line.mIcon->eventMouseButtonClick += MyGUI::newDelegate(this, &ItemChargeView::onIconClicked);
                line.mIcon->eventMouseWheel += MyGUI::newDelegate(this, &ItemChargeView::onMouseWheelMoved);

                line.mCharge = mScrollView->createWidget<Widgets::MWDynamicStat>(
                    "MW_ChargeBar", MyGUI::IntCoord(), MyGUI::Align::Default);
                line.mCharge->setNeedMouseFocus(false);

                updateLine(line);

                lines.push_back(line);
            }
        }

        for (Lines::iterator iter = mLines.begin(); iter != mLines.end(); ++iter)
        {
            if (visitedLines.count(iter))
                continue;

            // remove line widgets
            MyGUI::Gui::getInstance().destroyWidget(iter->mText);
            MyGUI::Gui::getInstance().destroyWidget(iter->mIcon);
            MyGUI::Gui::getInstance().destroyWidget(iter->mCharge);
        }

        mLines.swap(lines);

        std::stable_sort(mLines.begin(), mLines.end(),
            [](const MWGui::ItemChargeView::Line& a, const MWGui::ItemChargeView::Line& b) {
                return Misc::StringUtils::ciLess(a.mText->getCaption(), b.mText->getCaption());
            });

        layoutWidgets();
    }

    void ItemChargeView::layoutWidgets()
    {
        int currentY = 0;

        for (Line& line : mLines)
        {
            // TSP_HAMMER_REPAIR_FONT_051_V2
            //
            // The repair-hammer list uses an 18px-high text row. Keep the
            // larger global TSP UI font everywhere else, but cap this one
            // health/repair list at 17px so names fit the existing row.
            if (mDisplayMode == DisplayMode_Health)
                line.mText->setFontHeight(
                    std::min(17, Settings::gui().mFontSize.get()));
            else
                line.mText->setFontHeight(0);

            line.mText->setCoord(8, currentY, mScrollView->getWidth() - 8, 18);
            currentY += 19;

            line.mIcon->setCoord(16, currentY, 32, 32);
            line.mCharge->setCoord(72, currentY + 2, std::max(199, mScrollView->getWidth() - 72 - 38), 20);
            currentY += 32 + 4;
        }

        // Canvas size must be expressed with VScroll disabled, otherwise MyGUI would expand the scroll area when the
        // scrollbar is hidden
        mScrollView->setVisibleVScroll(false);
        mScrollView->setCanvasSize(
            MyGUI::IntSize(mScrollView->getWidth(), std::max(mScrollView->getHeight(), currentY)));
        mScrollView->setVisibleVScroll(true);

        if (Settings::gui().mControllerMenus)
            updateControllerFocus(mLines.size(), mControllerFocus);
    }

    void ItemChargeView::resetScrollbars()
    {
        mScrollView->setViewOffset(MyGUI::IntPoint(0, 0));

        if (Settings::gui().mControllerMenus)
        {
            updateControllerFocus(mControllerFocus, 0);
            mControllerFocus = 0;
        }
    }

    void ItemChargeView::setSize(const MyGUI::IntSize& value)
    {
        bool changed = (value.width != getWidth() || value.height != getHeight());
        Base::setSize(value);
        if (changed)
            layoutWidgets();
    }

    void ItemChargeView::setCoord(const MyGUI::IntCoord& value)
    {
        bool changed = (value.width != getWidth() || value.height != getHeight());
        Base::setCoord(value);
        if (changed)
            layoutWidgets();
    }

    void ItemChargeView::updateLine(const ItemChargeView::Line& line)
    {
        std::string_view name = line.mItemPtr.getClass().getName(line.mItemPtr);
        line.mText->setCaption(MyGUI::UString(name));

        line.mCharge->setVisible(false);
        switch (mDisplayMode)
        {
            case DisplayMode_Health:
                if (!line.mItemPtr.getClass().hasItemHealth(line.mItemPtr))
                    break;

                line.mCharge->setVisible(true);
                line.mCharge->setValue(line.mItemPtr.getClass().getItemHealth(line.mItemPtr),
                    line.mItemPtr.getClass().getItemMaxHealth(line.mItemPtr));
                break;
            case DisplayMode_EnchantmentCharge:
                const ESM::RefId& enchId = line.mItemPtr.getClass().getEnchantment(line.mItemPtr);
                if (enchId.empty())
                    break;
                const ESM::Enchantment* ench
                    = MWBase::Environment::get().getESMStore()->get<ESM::Enchantment>().search(enchId);
                if (!ench)
                    break;

                line.mCharge->setVisible(true);
                line.mCharge->setValue(static_cast<int>(line.mItemPtr.getCellRef().getEnchantmentCharge()),
                    MWMechanics::getEnchantmentCharge(*ench));
                break;
        }
    }

    void ItemChargeView::onIconClicked(MyGUI::Widget* sender)
    {
        eventItemClicked(this, *sender->getUserData<MWWorld::Ptr>());
    }

    void ItemChargeView::onMouseWheelMoved(MyGUI::Widget* /*sender*/, int rel)
    {
        if (mScrollView->getViewOffset().top + rel * 0.3f > 0)
            mScrollView->setViewOffset(MyGUI::IntPoint(0, 0));
        else
            mScrollView->setViewOffset(
                MyGUI::IntPoint(0, static_cast<int>(mScrollView->getViewOffset().top + rel * 0.3f)));
    }

    void ItemChargeView::onControllerButton(const unsigned char button)
    {
        if (mLines.empty())
            return;

        size_t prevFocus = mControllerFocus;

        if (button == SDL_CONTROLLER_BUTTON_A)
        {
            // Select the focused item, if any.
            if (mControllerFocus < mLines.size())
                onIconClicked(mLines[mControllerFocus].mIcon);
        }
        else if (button == SDL_CONTROLLER_BUTTON_DPAD_UP)
            mControllerFocus = wrap(mControllerFocus, mLines.size(), -1);
        else if (button == SDL_CONTROLLER_BUTTON_DPAD_DOWN)
            mControllerFocus = wrap(mControllerFocus, mLines.size(), 1);
        else if (button == SDL_CONTROLLER_BUTTON_LEFTSHOULDER
            || button == SDL_CONTROLLER_BUTTON_RIGHTSHOULDER)
        {
            // TSP_ITEMCHARGE_VISIBLE_PAGE_051_V1
            // Page by the number of complete rows that actually fit in the
            // current viewport instead of assuming a stock font/row count.
            const int tspViewHeight
                = std::max(1, mScrollView->getViewCoord().height);

            int tspRowStep = 55;

            if (mLines.size() > 1)
            {
                tspRowStep
                    = mLines[1].mText->getTop()
                    - mLines[0].mText->getTop();
            }

            if (tspRowStep <= 0)
            {
                tspRowStep = std::max(
                    1,
                    std::max(
                        mLines[mControllerFocus].mText->getHeight(),
                        mLines[mControllerFocus].mIcon->getHeight() + 4));
            }

            const size_t tspPage = static_cast<size_t>(
                std::max(1, tspViewHeight / tspRowStep));

            if (button == SDL_CONTROLLER_BUTTON_LEFTSHOULDER)
            {
                if (mControllerFocus > tspPage)
                    mControllerFocus -= tspPage;
                else
                    mControllerFocus = 0;
            }
            else
            {
                mControllerFocus = std::min(
                    mLines.size() - 1,
                    mControllerFocus + tspPage);
            }
        }

        if (prevFocus != mControllerFocus)
            updateControllerFocus(prevFocus, mControllerFocus);
    }

    void ItemChargeView::updateControllerFocus(size_t prevFocus, size_t newFocus)
    {
        if (mLines.empty())
            return;

        const TextColours& textColours{ MWBase::Environment::get().getWindowManager()->getTextColours() };

        if (prevFocus < mLines.size())
        {
            mLines[prevFocus].mText->setTextColour(textColours.normal);
            mLines[prevFocus].mIcon->setControllerFocus(false);
        }

        if (newFocus < mLines.size())
        {
            mLines[newFocus].mText->setTextColour(textColours.link);
            mLines[newFocus].mIcon->setControllerFocus(true);

            // TSP_ITEMCHARGE_VISIBLE_PAGE_051_V1
            // Keep the full selected repair/recharge row inside the actual
            // viewport. The old <=3 / 55px calculation was one row wrong
            // after the TSP font increase.
            const int tspViewHeight
                = mScrollView->getViewCoord().height;

            if (tspViewHeight > 0)
            {
                const int tspCurrentTop
                    = std::max(0, -mScrollView->getViewOffset().top);

                const int tspItemTop = std::min(
                    mLines[newFocus].mText->getTop(),
                    mLines[newFocus].mIcon->getTop());

                const int tspItemBottom = std::max(
                    mLines[newFocus].mText->getTop()
                        + mLines[newFocus].mText->getHeight(),
                    mLines[newFocus].mIcon->getTop()
                        + mLines[newFocus].mIcon->getHeight() + 4);

                int tspNewTop = tspCurrentTop;

                if (tspItemTop < tspCurrentTop)
                    tspNewTop = tspItemTop;
                else if (tspItemBottom > tspCurrentTop + tspViewHeight)
                    tspNewTop = tspItemBottom - tspViewHeight;

                const int tspMaxTop = std::max(
                    0,
                    mScrollView->getCanvasSize().height - tspViewHeight);

                tspNewTop = std::clamp(
                    tspNewTop, 0, tspMaxTop);

                mScrollView->setViewOffset(
                    MyGUI::IntPoint(0, -tspNewTop));
            }
        }
    }
}
