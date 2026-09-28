#include "spellbuyingwindow.hpp"

#include <vector>
#include <algorithm>
#include <MyGUI_Button.h>
#include <MyGUI_Gui.h>
#include <MyGUI_ScrollView.h>

#include <components/esm3/loadgmst.hpp>
#include <components/esm3/loadrace.hpp>
#include <components/settings/values.hpp>

#include "../mwbase/environment.hpp"
#include "../mwbase/inputmanager.hpp"
#include "../mwbase/mechanicsmanager.hpp"
#include "../mwbase/windowmanager.hpp"

#include "../mwworld/class.hpp"
#include "../mwworld/containerstore.hpp"
#include "../mwworld/esmstore.hpp"

#include "../mwmechanics/actorutil.hpp"
#include "../mwmechanics/creaturestats.hpp"
#include "../mwmechanics/spells.hpp"
#include "../mwmechanics/spellutil.hpp"

namespace MWGui
{
    SpellBuyingWindow::SpellBuyingWindow()
        : WindowBase("openmw_spell_buying_window.layout")
        , mCurrentY(0)
        , mControllerFocus(0)
    {
        getWidget(mCancelButton, "CancelButton");
        getWidget(mPlayerGold, "PlayerGold");
        getWidget(mSpellsView, "SpellsView");

        // TSP_SPELLBUY_LAYOUT_POLISH_051_V2
        //
        // The TSP UI font is larger than the stock layout was designed for.
        // Widen the list so prices cannot sit underneath the scrollbar, then
        // extend its height ONLY enough to end on a complete text row.
        {
            // TSP_UI_POLISH_REFINEMENT_051_V3
            constexpr int tspExtraWidth = 30;

            const int tspLineHeight
                = std::max(1, Settings::gui().mFontSize + 2);

            const int tspViewHeight
                = std::max(1, mSpellsView->getViewCoord().height);

            const int tspRemainder
                = tspViewHeight % tspLineHeight;

            // TSP_UI_POLISH_REFINEMENT_051_V3
            // Do not create a partial empty row at the bottom.
            // Shrink to the previous complete row instead.
            const int tspExtraHeight
                = (tspRemainder == 0
                    ? 0
                    : -tspRemainder) - 4;

            MyGUI::Widget* tspFrame = mSpellsView->getParent();

            if (tspFrame != nullptr)
            {
                std::vector<std::pair<MyGUI::Widget*, MyGUI::IntCoord>>
                    tspRootCoords;

                for (size_t i = 0;
                     i < mMainWidget->getChildCount();
                     ++i)
                {
                    MyGUI::Widget* child
                        = mMainWidget->getChildAt(i);

                    tspRootCoords.emplace_back(
                        child, child->getCoord());
                }

                const MyGUI::IntCoord tspScrollCoord
                    = mSpellsView->getCoord();

                mMainWidget->setSize(
                    mMainWidget->getWidth() + tspExtraWidth,
                    mMainWidget->getHeight() + tspExtraHeight);

                for (auto& entry : tspRootCoords)
                {
                    MyGUI::Widget* child = entry.first;
                    MyGUI::IntCoord coord = entry.second;

                    if (child == mCancelButton)
                    {
                        coord.left += tspExtraWidth;
                        coord.top += tspExtraHeight;
                    }
                    else if (child == mPlayerGold)
                    {
                        coord.width += tspExtraWidth;
                        coord.top += tspExtraHeight;
                    }
                    else
                    {
                        coord.width += tspExtraWidth;

                        if (child == tspFrame)
                            coord.height += tspExtraHeight;
                    }

                    child->setCoord(coord);
                }

                mSpellsView->setCoord(
                    tspScrollCoord.left,
                    tspScrollCoord.top,
                    // TSP_UI_POLISH_REFINEMENT_051_V3
                    // Put the scrollbar at the actual right edge of
                    // the enclosing list frame instead of leaving the
                    // large unused black column from V2.
                    std::max(
                        1,
                        tspFrame->getWidth()
                            - tspScrollCoord.left - 1),
                    tspScrollCoord.height + tspExtraHeight);
            }

            mMainWidget->setUserString(
                "TSP_SPELLBUY_LAYOUT_POLISH_051_V2", "1");
        }

        // TSP_SPELLBUY_GEOMETRY_FINAL_051_V10
        //
        // Keep the existing wider window. Fit the ScrollView to the real
        // enclosing frame and remove only the fractional-row remainder.
        {
            MyGUI::Widget* tspFrame = mSpellsView->getParent();

            if (tspFrame != nullptr)
            {
                const int tspLineHeight
                    = std::max(
                        1,
                        static_cast<int>(Settings::gui().mFontSize) + 2);

                const MyGUI::IntCoord tspFrameCoord
                    = tspFrame->getCoord();

                const MyGUI::IntCoord tspScrollCoord
                    = mSpellsView->getCoord();

                const MyGUI::IntCoord tspGoldCoord
                    = mPlayerGold->getCoord();

                const MyGUI::IntCoord tspCancelCoord
                    = mCancelButton->getCoord();

                // Difference between outer ScrollView height and its usable
                // inner viewport: scrollbar/skin/border overhead.
                const int tspSkinHeight
                    = std::max(
                        0,
                        tspScrollCoord.height
                            - mSpellsView->getViewCoord().height);

                constexpr int tspRightPadding = 1;
                constexpr int tspBottomPadding = 5;

                // Fill all horizontal space inside the existing frame.
                const int tspOuterWidth
                    = std::max(
                        1,
                        tspFrameCoord.width
                            - tspScrollCoord.left
                            - tspRightPadding);

                // Maximum ScrollView height that already fits this frame.
                const int tspAvailableOuterHeight
                    = std::max(
                        1,
                        tspFrameCoord.height
                            - tspScrollCoord.top
                            - tspBottomPadding);

                const int tspAvailableInnerHeight
                    = std::max(
                        tspLineHeight,
                        tspAvailableOuterHeight
                            - tspSkinHeight);

                // Largest WHOLE number of spell rows that fits.
                const int tspVisibleRows
                    = std::max(
                        1,
                        tspAvailableInnerHeight
                            / tspLineHeight);

                const int tspTargetInnerHeight
                    = tspVisibleRows * tspLineHeight;

                const int tspTargetOuterHeight
                    = tspTargetInnerHeight + tspSkinHeight;

                const int tspTargetFrameHeight
                    = tspScrollCoord.top
                        + tspTargetOuterHeight
                        + tspBottomPadding;

                const int tspTrim
                    = std::max(
                        0,
                        tspFrameCoord.height
                            - tspTargetFrameHeight);

                // Only remove the fractional-row remainder. No extra row
                // is added and no guessed 5/6/7-row window height is used.
                if (tspTrim > 0)
                {
                    mMainWidget->setSize(
                        mMainWidget->getWidth(),
                        std::max(
                            1,
                            mMainWidget->getHeight() - tspTrim));
                }

                tspFrame->setCoord(
                    tspFrameCoord.left,
                    tspFrameCoord.top,
                    tspFrameCoord.width,
                    tspTargetFrameHeight);

                mSpellsView->setCoord(
                    tspScrollCoord.left,
                    tspScrollCoord.top,
                    tspOuterWidth,
                    tspTargetOuterHeight);

                if (tspTrim > 0)
                {
                    mPlayerGold->setCoord(
                        tspGoldCoord.left,
                        tspGoldCoord.top - tspTrim,
                        tspGoldCoord.width,
                        tspGoldCoord.height);

                    mCancelButton->setCoord(
                        tspCancelCoord.left,
                        tspCancelCoord.top - tspTrim,
                        tspCancelCoord.width,
                        tspCancelCoord.height);
                }

                mSpellsView->setUserString(
                    "TSP_SPELLBUY_GEOMETRY_FINAL_051_V10",
                    MyGUI::utility::toString(tspVisibleRows));
            }
        }

        mCancelButton->eventMouseButtonClick += MyGUI::newDelegate(this, &SpellBuyingWindow::onCancelButtonClicked);

        if (Settings::gui().mControllerMenus)
        {
            mDisableGamepadCursor = true;
            mControllerButtons.mA = "#{Interface:Buy}";
            mControllerButtons.mB = "#{Interface:Cancel}";
            mControllerButtons.mR3 = "#{Interface:Info}";
        }
    }

    bool SpellBuyingWindow::sortSpells(const ESM::Spell* left, const ESM::Spell* right)
    {
        return Misc::StringUtils::ciLess(left->mName, right->mName);
    }

    void SpellBuyingWindow::addSpell(const ESM::Spell& spell)
    {
        const MWWorld::ESMStore& store = *MWBase::Environment::get().getESMStore();

        int price = std::max(1,
            static_cast<int>(MWMechanics::calcSpellCost(spell)
                * store.get<ESM::GameSetting>().find("fSpellValueMult")->mValue.getFloat()));
        price = MWBase::Environment::get().getMechanicsManager()->getBarterOffer(mPtr, price, true);

        MWWorld::Ptr player = MWMechanics::getPlayer();
        int playerGold = player.getClass().getContainerStore(player).count(MWWorld::ContainerStore::sGoldId);

        // TODO: refactor to use MyGUI::ListBox

        const int lineHeight = Settings::gui().mFontSize + 2;

        MyGUI::Button* toAdd = mSpellsView->createWidget<MyGUI::Button>(price <= playerGold
                ? "SandTextButton"
                : "SandTextButtonDisabled", // can't use setEnabled since that removes tooltip
            0, mCurrentY, 200, lineHeight, MyGUI::Align::Default);

        mCurrentY += lineHeight;

        toAdd->setUserData(price);
        toAdd->setCaptionWithReplacing(spell.mName + "  - " + MyGUI::utility::toString(price) + "#{sgp}");
        toAdd->setSize(mSpellsView->getWidth(), lineHeight);
        toAdd->eventMouseWheel += MyGUI::newDelegate(this, &SpellBuyingWindow::onMouseWheel);
        toAdd->setUserString("ToolTipType", "Spell");
        toAdd->setUserString("Spell", spell.mId.serialize());
        toAdd->setUserString("SpellCost", "true");
        toAdd->eventMouseButtonClick += MyGUI::newDelegate(this, &SpellBuyingWindow::onSpellButtonClick);
        mSpellsWidgetMap.insert(std::make_pair(toAdd, spell.mId));
        if (price <= playerGold)
            mSpellButtons.emplace_back(std::make_pair(toAdd, mSpellsWidgetMap.size()));
    }

    void SpellBuyingWindow::clearSpells()
    {
        mSpellsView->setViewOffset(MyGUI::IntPoint(0, 0));
        mCurrentY = 0;
        while (mSpellsView->getChildCount())
            MyGUI::Gui::getInstance().destroyWidget(mSpellsView->getChildAt(0));
        mSpellsWidgetMap.clear();
        mSpellButtons.clear();
    }

    void SpellBuyingWindow::setPtr(const MWWorld::Ptr& actor)
    {
        setPtr(actor, 0);
    }

    void SpellBuyingWindow::setPtr(const MWWorld::Ptr& actor, int startOffset)
    {
        if (actor.isEmpty() || !actor.getClass().isActor())
            throw std::runtime_error("Invalid argument in SpellBuyingWindow::setPtr");

        center();
        mPtr = actor;
        clearSpells();

        MWMechanics::Spells& merchantSpells = actor.getClass().getCreatureStats(actor).getSpells();

        std::vector<const ESM::Spell*> spellsToSort;

        for (const ESM::Spell* spell : merchantSpells)
        {
            if (spell->mData.mType != ESM::Spell::ST_Spell)
                continue; // don't try to sell diseases, curses or powers

            if (actor.getClass().isNpc())
            {
                const ESM::Race* race = MWBase::Environment::get().getESMStore()->get<ESM::Race>().find(
                    actor.get<ESM::NPC>()->mBase->mRace);
                if (race->mPowers.exists(spell->mId))
                    continue;
            }

            if (playerHasSpell(spell->mId))
                continue;

            spellsToSort.push_back(spell);
        }

        std::stable_sort(spellsToSort.begin(), spellsToSort.end(), sortSpells);

        for (const ESM::Spell* spell : spellsToSort)
        {
            addSpell(*spell);
        }

        spellsToSort.clear();

        updateLabels();

        if (Settings::gui().mControllerMenus)
        {
            mControllerFocus = 0;
            if (mSpellButtons.size() > 0)
            {
                mSpellButtons[0].first->setStateSelected(true);

                MWBase::WindowManager* winMgr = MWBase::Environment::get().getWindowManager();
                winMgr->setControllerTooltipVisible(Settings::gui().mControllerTooltips);
                if (winMgr->getControllerTooltipVisible())
                    MWBase::Environment::get().getInputManager()->warpMouseToWidget(mSpellButtons[0].first);
            }
        }

        // Canvas size must be expressed with VScroll disabled, otherwise MyGUI would expand the scroll area when the
        // scrollbar is hidden
        mSpellsView->setVisibleVScroll(false);
        mSpellsView->setCanvasSize(
            MyGUI::IntSize(mSpellsView->getWidth(), std::max(
                // TSP_SPELLBUY_CANVAS_RANGE_051_V11
                mSpellsView->getViewCoord().height,
                mCurrentY)));
        mSpellsView->setVisibleVScroll(true);
        mSpellsView->setViewOffset(MyGUI::IntPoint(0, startOffset));
    }

    bool SpellBuyingWindow::playerHasSpell(const ESM::RefId& id)
    {
        MWWorld::Ptr player = MWMechanics::getPlayer();
        return player.getClass().getCreatureStats(player).getSpells().hasSpell(id);
    }

    void SpellBuyingWindow::onSpellButtonClick(MyGUI::Widget* sender)
    {
        int price = *sender->getUserData<int>();

        MWWorld::Ptr player = MWMechanics::getPlayer();
        if (price > player.getClass().getContainerStore(player).count(MWWorld::ContainerStore::sGoldId))
            return;

        MWMechanics::CreatureStats& stats = player.getClass().getCreatureStats(player);
        MWMechanics::Spells& spells = stats.getSpells();
        auto spell = mSpellsWidgetMap.find(sender);
        assert(spell != mSpellsWidgetMap.end());

        spells.add(spell->second);
        player.getClass().getContainerStore(player).remove(MWWorld::ContainerStore::sGoldId, price);

        // add gold to NPC trading gold pool
        MWMechanics::CreatureStats& npcStats = mPtr.getClass().getCreatureStats(mPtr);
        npcStats.setGoldPool(npcStats.getGoldPool() + price);

        setPtr(mPtr, mSpellsView->getViewOffset().top);

        MWBase::Environment::get().getWindowManager()->playSound(ESM::RefId::stringRefId("Item Gold Up"));
    }

    void SpellBuyingWindow::onCancelButtonClicked(MyGUI::Widget* /*sender*/)
    {
        MWBase::Environment::get().getWindowManager()->removeGuiMode(MWGui::GM_SpellBuying);
    }

    void SpellBuyingWindow::updateLabels()
    {
        MWWorld::Ptr player = MWMechanics::getPlayer();
        int playerGold = player.getClass().getContainerStore(player).count(MWWorld::ContainerStore::sGoldId);

        mPlayerGold->setCaptionWithReplacing("#{sGold}: " + MyGUI::utility::toString(playerGold));
        mPlayerGold->setCoord(8, mPlayerGold->getTop(), mPlayerGold->getTextSize().width, mPlayerGold->getHeight());
    }

    void SpellBuyingWindow::onReferenceUnavailable()
    {
        // remove both Spells and Dialogue (since you always trade with the NPC/creature that you have previously talked
        // to)
        MWBase::Environment::get().getWindowManager()->removeGuiMode(GM_SpellBuying);
        MWBase::Environment::get().getWindowManager()->exitCurrentGuiMode();
    }

    void SpellBuyingWindow::onMouseWheel(MyGUI::Widget* /*sender*/, int rel)
    {
        if (mSpellsView->getViewOffset().top + rel * 0.3 > 0)
            mSpellsView->setViewOffset(MyGUI::IntPoint(0, 0));
        else
            mSpellsView->setViewOffset(
                MyGUI::IntPoint(0, static_cast<int>(mSpellsView->getViewOffset().top + rel * 0.3f)));
    }

    bool SpellBuyingWindow::onControllerButtonEvent(const SDL_ControllerButtonEvent& arg)
    {
        MWBase::WindowManager* winMgr = MWBase::Environment::get().getWindowManager();

        if (arg.button == SDL_CONTROLLER_BUTTON_A)
        {
            if (mControllerFocus < mSpellButtons.size())
                onSpellButtonClick(mSpellButtons[mControllerFocus].first);
        }
        else if (arg.button == SDL_CONTROLLER_BUTTON_B)
        {
            onCancelButtonClicked(mCancelButton);
            return true;
        }
        else if (arg.button == SDL_CONTROLLER_BUTTON_RIGHTSTICK)
        {
            // Toggle info tooltip
            winMgr->setControllerTooltipEnabled(!winMgr->getControllerTooltipEnabled());
        }
        else if (arg.button == SDL_CONTROLLER_BUTTON_DPAD_UP)
        {
            winMgr->restoreControllerTooltips();

            if (mSpellButtons.size() <= 1)
                return true;

            mSpellButtons[mControllerFocus].first->setStateSelected(false);
            mControllerFocus = wrap(mControllerFocus, mSpellButtons.size(), -1);
            mSpellButtons[mControllerFocus].first->setStateSelected(true);
        }
        else if (arg.button == SDL_CONTROLLER_BUTTON_DPAD_DOWN)
        {
            winMgr->restoreControllerTooltips();

            if (mSpellButtons.size() <= 1)
                return true;

            mSpellButtons[mControllerFocus].first->setStateSelected(false);
            mControllerFocus = wrap(mControllerFocus, mSpellButtons.size(), 1);
            mSpellButtons[mControllerFocus].first->setStateSelected(true);
        }
        else if (arg.button == SDL_CONTROLLER_BUTTON_LEFTSHOULDER
            || arg.button == SDL_CONTROLLER_BUTTON_RIGHTSHOULDER)
        {
            // TSP_SPELLBUY_FORCE_REAL_SCROLL_051_V12
            //
            // The window/frame geometry is already correct. Do not resize it.
            //
            // Make the controller focus authoritative for scrolling:
            //   1. rebuild the canvas from the REAL content height;
            //   2. determine the focused widget's physical row;
            //   3. keep that row inside the current viewport;
            //   4. move both the real ScrollView canvas and scrollbar.
            //
            // This deliberately does not depend on the historical hard-coded
            // 5/6/7-row assumptions.
            MyGUI::Widget* tspFocusedV12
                = mSpellButtons[mControllerFocus].first;

            if (tspFocusedV12 != nullptr)
            {
                const int tspLineHeightV12
                    = std::max(
                        1,
                        tspFocusedV12->getHeight());

                const int tspViewHeightV12
                    = std::max(
                        tspLineHeightV12,
                        mSpellsView->getViewCoord().height);

                const int tspVisibleRowsV12
                    = std::max(
                        1,
                        tspViewHeightV12
                            / tspLineHeightV12);

                // mCurrentY is advanced for EVERY visible spell row,
                // including rows which are not controller-selectable.
                // It is therefore the authoritative physical content height.
                const int tspContentHeightV12
                    = std::max(
                        tspViewHeightV12,
                        mCurrentY);

                MyGUI::IntSize tspCanvasV12
                    = mSpellsView->getCanvasSize();

                tspCanvasV12.width
                    = std::max(
                        tspCanvasV12.width,
                        mSpellsView->getViewCoord().width);

                tspCanvasV12.height
                    = tspContentHeightV12;

                // Force MyGUI to recalculate mVRange from the real content.
                mSpellsView->setCanvasSize(
                    tspCanvasV12);

                const int tspItemRowV12
                    = std::max(
                        0,
                        tspFocusedV12->getTop()
                            / tspLineHeightV12);

                int tspCurrentTopV12
                    = -mSpellsView->getViewOffset().top;

                if (tspCurrentTopV12 < 0)
                    tspCurrentTopV12 = 0;

                int tspCurrentTopRowV12
                    = tspCurrentTopV12
                        / tspLineHeightV12;

                int tspTargetTopRowV12
                    = tspCurrentTopRowV12;

                // Focus moved above the visible page.
                if (tspItemRowV12 < tspCurrentTopRowV12)
                {
                    tspTargetTopRowV12
                        = tspItemRowV12;
                }
                // Focus moved below the visible page.
                else if (
                    tspItemRowV12
                    >= tspCurrentTopRowV12
                        + tspVisibleRowsV12)
                {
                    tspTargetTopRowV12
                        = tspItemRowV12
                            - tspVisibleRowsV12
                            + 1;
                }

                const int tspTotalRowsV12
                    = std::max(
                        1,
                        (tspContentHeightV12
                            + tspLineHeightV12 - 1)
                            / tspLineHeightV12);

                const int tspMaxTopRowV12
                    = std::max(
                        0,
                        tspTotalRowsV12
                            - tspVisibleRowsV12);

                if (tspTargetTopRowV12 < 0)
                    tspTargetTopRowV12 = 0;

                if (tspTargetTopRowV12 > tspMaxTopRowV12)
                    tspTargetTopRowV12 = tspMaxTopRowV12;

                const int tspTargetTopV12
                    = tspTargetTopRowV12
                        * tspLineHeightV12;

                // Normal MyGUI route first. With the corrected canvas this
                // should now have a non-zero vertical range.
                mSpellsView->setViewOffset(
                    MyGUI::IntPoint(
                        0,
                        -tspTargetTopV12));

                // Belt-and-suspenders fallback:
                // If this MyGUI build still refuses to move the ScrollView,
                // move the real client canvas directly. This is the object
                // ScrollView::setViewOffset() normally moves internally.
                if (
                    mSpellsView->getViewOffset().top
                    != -tspTargetTopV12)
                {
                    MyGUI::Widget* tspCanvasWidgetV12
                        = mSpellsView->getClientWidget();

                    if (tspCanvasWidgetV12 != nullptr)
                    {
                        MyGUI::IntPoint tspCanvasPosV12
                            = tspCanvasWidgetV12->getPosition();

                        tspCanvasPosV12.top
                            = -tspTargetTopV12;

                        tspCanvasWidgetV12->setPosition(
                            tspCanvasPosV12);
                    }

                }
            }

            // Warp the mouse to the selected spell to show the tooltip
            if (MWBase::Environment::get().getWindowManager()->getControllerTooltipVisible())
                MWBase::Environment::get().getInputManager()->warpMouseToWidget(mSpellButtons[mControllerFocus].first);
        }

        return true;
    }
}
