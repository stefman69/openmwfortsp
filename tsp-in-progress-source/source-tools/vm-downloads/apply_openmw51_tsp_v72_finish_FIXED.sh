#!/usr/bin/env bash
set -Eeuo pipefail

CONTAINER="${CONTAINER:-openmw_builder}"
SRC="${SRC:-/root/openmw-0.51-tsp-src}"
BUILD="${BUILD:-/root/openmw-0.51-tsp-build}"
DEVICE_IP="${DEVICE_IP:-192.168.1.12}"
DEPLOY="${DEPLOY:-1}"

fail() {
    echo "ERROR: $*" >&2
    return 1
}

trap 'rc=$?; echo; echo "ERROR: V72 stopped at host-script line $LINENO (status $rc)." >&2; echo "Your terminal remains open." >&2' ERR

echo "===== TSP V72 FINISHING PASS ====="
echo "Container: $CONTAINER"
echo "Device:    $DEVICE_IP"
echo

DOCKER=(docker)
if ! docker info >/dev/null 2>&1; then
    echo "Docker needs elevated access; requesting it once."
    sudo -v
    DOCKER=(sudo docker)
fi

"${DOCKER[@]}" inspect "$CONTAINER" >/dev/null 2>&1 || fail "container '$CONTAINER' not found"

STAMP="$(date +%Y%m%d-%H%M%S)"
PATCHER="/tmp/tsp_v72_patch_$$.py"
trap 'rm -f "$PATCHER"' EXIT

cat > "$PATCHER" <<'PYV72'
from pathlib import Path
import re
import sys

root = Path(sys.argv[1])

def p(rel): return root / rel
def rd(rel): return p(rel).read_text(encoding="utf-8")
def wr(rel, s): p(rel).write_text(s, encoding="utf-8")
def need(cond, msg):
    if not cond:
        raise RuntimeError(msg)

def replace_once(s, old, new, label):
    if new in s:
        return s
    n = s.count(old)
    need(n == 1, f"{label}: expected one anchor, found {n}")
    return s.replace(old, new, 1)

# ------------------------------------------------------------------
# Reusable widget font controls.
# ------------------------------------------------------------------
rel = "apps/openmw/mwgui/widgets.hpp"
s = rd(rel)

# Add unique V72 methods, avoiding collisions with any V70 methods.
skill_cls = s.find("class MWSkill final")
attr_cls = s.find("class MWAttribute final")
spell_cls = s.find("class MWSpell final")
need(skill_cls >= 0 and attr_cls > skill_cls and spell_cls > attr_cls,
     "widgets.hpp class anchors missing")

skill_part = s[skill_cls:attr_cls]
if "tspV72SetFontHeight" not in skill_part:
    anchor = "            void setSkillValue(const SkillValue& value);\n"
    need(anchor in skill_part, "MWSkill declaration anchor missing")
    pos = s.find(anchor, skill_cls, attr_cls)
    s = s[:pos+len(anchor)] + "            void tspV72SetFontHeight(int height);\n" + s[pos+len(anchor):]

attr_cls = s.find("class MWAttribute final")
spell_cls = s.find("class MWSpell final")
attr_part = s[attr_cls:spell_cls]
if "tspV72SetFontHeight" not in attr_part:
    anchor = "            void setAttributeValue(const AttributeValue& value);\n"
    need(anchor in attr_part, "MWAttribute declaration anchor missing")
    pos = s.find(anchor, attr_cls, spell_cls)
    s = s[:pos+len(anchor)] + "            void tspV72SetFontHeight(int height);\n" + s[pos+len(anchor):]

spell_cls = s.find("class MWSpell final")
spell_part = s[spell_cls:]
if "tspV72SetNameFontHeight" not in spell_part:
    anchor = "            void setSpellId(const ESM::RefId& id);\n"
    need(anchor in spell_part, "MWSpell declaration anchor missing")
    pos = s.find(anchor, spell_cls)
    s = s[:pos+len(anchor)] + "            void tspV72SetNameFontHeight(int height);\n" + s[pos+len(anchor):]

wr(rel, s)

rel = "apps/openmw/mwgui/widgets.cpp"
s = rd(rel)

if "void MWSkill::tspV72SetFontHeight(int height)" not in s:
    anchor = "    void MWSkill::setStateSelected(bool selected)\n"
    need(anchor in s, "MWSkill implementation anchor missing")
    block = '''    // TSP_CONFIGURED_CHARGEN_FONTS_051_V72
    void MWSkill::tspV72SetFontHeight(int height)
    {
        if (mSkillNameWidget)
            mSkillNameWidget->setFontHeight(height);
        if (mSkillValueWidget)
            mSkillValueWidget->setFontHeight(height);
    }

'''
    s = s.replace(anchor, block + anchor, 1)

if "void MWAttribute::tspV72SetFontHeight(int height)" not in s:
    anchor = "    void MWAttribute::setStateSelected(bool selected)\n"
    need(anchor in s, "MWAttribute implementation anchor missing")
    block = '''    void MWAttribute::tspV72SetFontHeight(int height)
    {
        if (mAttributeNameWidget)
            mAttributeNameWidget->setFontHeight(height);
        if (mAttributeValueWidget)
            mAttributeValueWidget->setFontHeight(height);
    }

'''
    s = s.replace(anchor, block + anchor, 1)

if "void MWSpell::tspV72SetNameFontHeight(int height)" not in s:
    anchor = "    void MWSpell::setStateSelected(bool selected)\n"
    need(anchor in s, "MWSpell implementation anchor missing")
    block = '''    void MWSpell::tspV72SetNameFontHeight(int height)
    {
        if (mSpellNameWidget)
            mSpellNameWidget->setFontHeight(height);
    }

'''
    s = s.replace(anchor, block + anchor, 1)

wr(rel, s)

# ------------------------------------------------------------------
# InputManager: cursor, focused EditBox detection, real key taps.
# ------------------------------------------------------------------
rel = "apps/openmw/mwinput/inputmanagerimp.cpp"
s = rd(rel)

if "#include <MyGUI_InputManager.h>" not in s:
    anchor = "#include <MyGUI_Gui.h>\n"
    need(anchor in s, "inputmanager MyGUI include anchor missing")
    s = s.replace(anchor, anchor + "#include <MyGUI_InputManager.h>\n", 1)
if "#include <MyGUI_EditBox.h>" not in s:
    anchor = "#include <MyGUI_Gui.h>\n"
    need(anchor in s, "inputmanager MyGUI include anchor missing")
    s = s.replace(anchor, anchor + "#include <MyGUI_EditBox.h>\n", 1)
if '#include "../mwgui/windowbase.hpp"' not in s:
    anchor = '#include "../mwgui/mode.hpp"\n'
    need(anchor in s, "inputmanager windowbase include anchor missing")
    s = s.replace(anchor, anchor + '#include "../mwgui/windowbase.hpp"\n', 1)

if "TSP_SAVELOAD_CURSOR_MODAL_051_V72" not in s:
    pat = re.compile(
        r'        // TSP_CURSOR_POLICY_051_V48 -- where a pointer may exist at all\.\n'
        r'        bool tspCursorAllowed\(MWBase::WindowManager\* windowManager\)\n'
        r'        \{.*?\n        \}\n'
        r'        // TSP_CURSOR_POLICY_051_V48',
        re.S,
    )
    repl = '''        // TSP_SAVELOAD_CURSOR_MODAL_051_V72
        // Save/Load is modal over GM_MainMenu. V48 hid the software cursor
        // merely because GM_MainMenu remained anywhere in the mode stack.
        // The pointer still moved, which is why save rows highlighted.
        // Judge the active controller window instead.
        bool tspCursorAllowed(MWBase::WindowManager* windowManager)
        {
            if (!windowManager->isGuiMode())
                return false;

            if (windowManager->containsMode(MWGui::GM_Loading)
                || windowManager->containsMode(MWGui::GM_LoadingWallpaper))
                return false;

            if (MWGui::WindowBase* top = windowManager->getActiveControllerWindow())
            {
                if (!top->isGamepadCursorAllowed()
                    && !windowManager->isSettingsWindowVisible())
                    return false;
            }

            return true;
        }
        // TSP_CURSOR_POLICY_051_V48'''
    s, n = pat.subn(repl, s, count=1)
    need(n == 1, "could not replace tspCursorAllowed")

old = "        const bool tspTextEntryActive = SDL_IsTextInputActive() == SDL_TRUE;\n"
if "TSP_FOCUSED_EDITBOX_TEXT_051_V72" not in s:
    need(old in s, "text-entry active anchor missing")
    new = '''        // TSP_FOCUSED_EDITBOX_TEXT_051_V72
        // On this port SDL text state can lag behind MyGUI focus. A real
        // focused EditBox is therefore also an authoritative text target.
        bool tspFocusedEditBoxV72 = false;
        for (MyGUI::Widget* tspFocusV72
                 = MyGUI::InputManager::getInstance().getKeyFocusWidget();
             tspFocusV72 != nullptr;
             tspFocusV72 = tspFocusV72->getParent())
        {
            if (tspFocusV72->castType<MyGUI::EditBox>(false) != nullptr)
            {
                tspFocusedEditBoxV72 = true;
                break;
            }
        }

        const bool tspTextEntryActive
            = SDL_IsTextInputActive() == SDL_TRUE || tspFocusedEditBoxV72;
'''
    s = s.replace(old, new, 1)

if "TSP_TEXT_TAP_RELEASE_051_V72" not in s:
    old = '''                    if (tspCh == 8)
                        windowManager->injectKeyPress(MyGUI::KeyCode::Backspace, 0, false);
                    else if (tspCh == 13 || tspCh == 10)
                        windowManager->injectKeyPress(MyGUI::KeyCode::Return, 0, false);'''
    new = '''                    if (tspCh == 8)
                    {
                        windowManager->injectKeyPress(MyGUI::KeyCode::Backspace, 0, false);
                        windowManager->injectKeyRelease(MyGUI::KeyCode::Backspace);
                        // TSP_TEXT_TAP_RELEASE_051_V72
                    }
                    else if (tspCh == 13 || tspCh == 10)
                    {
                        windowManager->injectKeyPress(MyGUI::KeyCode::Return, 0, false);
                        windowManager->injectKeyRelease(MyGUI::KeyCode::Return);
                    }'''
    s = replace_once(s, old, new, "Backspace/Return press-release")

wr(rel, s)

# ------------------------------------------------------------------
# ControllerManager: clicking a focused EditBox with controller-mouse
# hands control straight to the text helper.
# ------------------------------------------------------------------
rel = "apps/openmw/mwinput/controllermanager.cpp"
s = rd(rel)

if "#include <MyGUI_InputManager.h>" not in s:
    anchor = "#include <MyGUI_Button.h>\n"
    need(anchor in s, "controllermanager include anchor missing")
    s = s.replace(anchor, anchor + "#include <MyGUI_InputManager.h>\n", 1)
if "#include <MyGUI_EditBox.h>" not in s:
    anchor = "#include <MyGUI_Button.h>\n"
    need(anchor in s, "controllermanager include anchor missing")
    s = s.replace(anchor, anchor + "#include <MyGUI_EditBox.h>\n", 1)

if "TSP_CLICK_EDITBOX_TO_TEXT_051_V72" not in s:
    old = '''                    bool mousePressSuccess = mMouseManager->injectMouseButtonRelease(SDL_BUTTON_LEFT);
                    mGamepadMousePressed = false;
                    if (mBindingsManager->isDetectingBindingState()) // If the player just triggered binding, don't let
                                                                     // button release bind.
                        return;

                    mBindingsManager->setPlayerControlsEnabled(!mousePressSuccess);'''
    need(old in s, "controller mouse-release anchor missing")
    new = '''                    bool mousePressSuccess = mMouseManager->injectMouseButtonRelease(SDL_BUTTON_LEFT);
                    mGamepadMousePressed = false;

                    // TSP_CLICK_EDITBOX_TO_TEXT_051_V72
                    // Finish the click first. If it put keyboard focus on a
                    // MyGUI EditBox, leave explicit mouse/controller mode and
                    // let InputManager publish the text helper next frame.
                    bool tspClickedEditV72 = false;
                    for (MyGUI::Widget* tspFocusV72
                             = MyGUI::InputManager::getInstance().getKeyFocusWidget();
                         tspFocusV72 != nullptr;
                         tspFocusV72 = tspFocusV72->getParent())
                    {
                        if (tspFocusV72->castType<MyGUI::EditBox>(false) != nullptr)
                        {
                            tspClickedEditV72 = true;
                            break;
                        }
                    }

                    if (tspClickedEditV72)
                    {
                        std::remove("/tmp/openmw-tsp-force-controller");
                        tspSetTextSuppressed(false);
                        tspSetMouseMode(false);
                        Log(Debug::Info)
                            << "TSP_CLICK_EDITBOX_TO_TEXT_051_V72 action=mouse-to-text";
                    }

                    if (mBindingsManager->isDetectingBindingState()) // If the player just triggered binding, don't let
                                                                     // button release bind.
                        return;

                    mBindingsManager->setPlayerControlsEnabled(!mousePressSuccess);'''
    s = s.replace(old, new, 1)

wr(rel, s)

# ------------------------------------------------------------------
# Class screens: final font values come from the existing GUI settings.
# These blocks run after V70s hardcoded 16px assignments if present.
# ------------------------------------------------------------------
rel = "apps/openmw/mwgui/class.cpp"
s = rd(rel)

if "TSP_PICK_CLASS_CONFIGURED_FONT_051_V72" not in s:
    anchor = "        updateClasses();\n        updateStats();\n"
    need(anchor in s, "PickClass end anchor missing")
    block = '''        // TSP_PICK_CLASS_CONFIGURED_FONT_051_V72
        const int tspStatsFontV72 = Settings::gui().mTspStatsFontSize.get();
        const int tspSkillFontV72 = Settings::gui().mTspSkillListFontSize.get();
        mSpecializationName->setFontHeight(tspStatsFontV72);
        mFavoriteAttribute[0]->tspV72SetFontHeight(tspStatsFontV72);
        mFavoriteAttribute[1]->tspV72SetFontHeight(tspStatsFontV72);
        for (int tspI = 0; tspI < 5; ++tspI)
        {
            mMajorSkill[tspI]->tspV72SetFontHeight(tspSkillFontV72);
            mMinorSkill[tspI]->tspV72SetFontHeight(tspSkillFontV72);
        }

'''
    s = s.replace(anchor, block + anchor, 1)

if "TSP_CREATE_CLASS_CONFIGURED_FONT_051_V72" not in s:
    anchor = "        setSpecialization(0);\n        update();\n"
    need(anchor in s, "CreateClass end anchor missing")
    block = '''        // TSP_CREATE_CLASS_CONFIGURED_FONT_051_V72
        const int tspStatsFontV72 = Settings::gui().mTspStatsFontSize.get();
        const int tspSkillFontV72 = Settings::gui().mTspSkillListFontSize.get();
        mEditName->setFontHeight(tspStatsFontV72);
        mSpecializationName->setFontHeight(tspStatsFontV72);
        mFavoriteAttribute0->tspV72SetFontHeight(tspStatsFontV72);
        mFavoriteAttribute1->tspV72SetFontHeight(tspStatsFontV72);
        for (int tspI = 0; tspI < 5; ++tspI)
        {
            mMajorSkill[tspI]->tspV72SetFontHeight(tspSkillFontV72);
            mMinorSkill[tspI]->tspV72SetFontHeight(tspSkillFontV72);
        }

'''
    s = s.replace(anchor, block + anchor, 1)

wr(rel, s)

# ------------------------------------------------------------------
# Race: make widget height match the configured font; this fixes the
# giant-overlap shown in the screenshot without shrinking global GUI text.
# ------------------------------------------------------------------
rel = "apps/openmw/mwgui/race.cpp"
s = rd(rel)

if "TSP_RACE_SKILL_ROWS_051_V72" not in s:
    old = '''        Widgets::MWSkillPtr skillWidget;
        const int lineHeight = Settings::gui().mFontSize + 2;
        MyGUI::IntCoord coord1(0, 0, mSkillList->getWidth(), 18);
'''
    new = '''        Widgets::MWSkillPtr skillWidget;
        // TSP_RACE_SKILL_ROWS_051_V72
        const int lineHeight = Settings::gui().mTspSkillListFontSize.get() + 4;
        MyGUI::IntCoord coord1(0, 0, mSkillList->getWidth(), lineHeight);
'''
    s = replace_once(s, old, new, "Race skill rows")

    old = '''            skillWidget->setSkillId(skill);
            skillWidget->setSkillValue(Widgets::MWSkill::SkillValue(static_cast<float>(bonus.mBonus), 0.f));
'''
    new = '''            skillWidget->setSkillId(skill);
            skillWidget->tspV72SetFontHeight(Settings::gui().mTspSkillListFontSize.get());
            skillWidget->setSkillValue(Widgets::MWSkill::SkillValue(static_cast<float>(bonus.mBonus), 0.f));
'''
    s = replace_once(s, old, new, "Race skill font")

if "TSP_RACE_POWER_ROWS_051_V72" not in s:
    # Scope replacement to updateSpellPowers by finding it first.
    start = s.find("    void RaceDialog::updateSpellPowers()")
    need(start >= 0, "Race updateSpellPowers missing")
    pos = s.find("        const int lineHeight = Settings::gui().mFontSize + 2;\n", start)
    need(pos >= 0, "Race power lineHeight anchor missing")
    old = "        const int lineHeight = Settings::gui().mFontSize + 2;\n"
    new = "        // TSP_RACE_POWER_ROWS_051_V72\n        const int lineHeight = Settings::gui().mTspStatsFontSize.get() + 4;\n"
    s = s[:pos] + new + s[pos+len(old):]

    old = "            spellPowerWidget->setSpellId(spellpower);\n"
    new = '''            spellPowerWidget->setSpellId(spellpower);
            spellPowerWidget->tspV72SetNameFontHeight(Settings::gui().mTspStatsFontSize.get());
'''
    # first occurrence after updateSpellPowers only
    pos = s.find(old, start)
    need(pos >= 0, "Race power widget font anchor missing")
    s = s[:pos] + new + s[pos+len(old):]

wr(rel, s)

# ------------------------------------------------------------------
# Birthsign: keep its good small ability names and direct lower-pane RS.
# ------------------------------------------------------------------
rel = "apps/openmw/mwgui/birth.cpp"
s = rd(rel)

if "TSP_BIRTH_DIRECT_SCROLL_051_V72" not in s:
    anchor = '        getWidget(mSpellArea, "SpellArea");\n'
    need(anchor in s, "Birth SpellArea anchor missing")
    add = '''        getWidget(mSpellArea, "SpellArea");
        // TSP_BIRTH_DIRECT_SCROLL_051_V72
        mControllerScrollWidget = mSpellArea;
        mSpellArea->setUserString("TSPDirectControllerScroll", "1");
'''
    s = s.replace(anchor, add, 1)

    old = '            mControllerButtons.mLStick = "#{Interface:Mouse}";\n'
    if 'mControllerButtons.mRStick' not in s:
        need(old in s, "Birth controller overlay anchor missing")
        s = s.replace(old, old + '            mControllerButtons.mRStick = "#{Interface:ScrollUp}";\n', 1)

if "TSP_BIRTH_NAME_FONT_051_V72" not in s:
    old = '''                    spellWidget->setSpellId(spellId);

                    mSpellItems.push_back(spellWidget);
'''
    # If V70 already inserted its setter, replace that local area instead.
    if old in s:
        new = '''                    spellWidget->setSpellId(spellId);
                    // TSP_BIRTH_NAME_FONT_051_V72
                    spellWidget->tspV72SetNameFontHeight(18);

                    mSpellItems.push_back(spellWidget);
'''
        s = s.replace(old, new, 1)
    else:
        # V70/V71 source likely has a setNameFontHeight line. Preserve behavior
        # but ensure our final setter comes immediately before push_back.
        anchor = "                    mSpellItems.push_back(spellWidget);\n"
        need(anchor in s, "Birth spell push anchor missing")
        s = s.replace(anchor,
                      "                    // TSP_BIRTH_NAME_FONT_051_V72\n"
                      "                    spellWidget->tspV72SetNameFontHeight(18);\n\n"
                      + anchor, 1)

wr(rel, s)

# ------------------------------------------------------------------
# Review: configured fonts and matching rows, plus direct RS scroll.
# ------------------------------------------------------------------
rel = "apps/openmw/mwgui/review.cpp"
s = rd(rel)

if "TSP_REVIEW_CONFIGURED_FONT_051_V72" not in s:
    old = "        MyGUI::IntCoord coord{ 8, 4, 250, 18 };\n"
    need(old in s, "Review attribute coord anchor missing")
    s = s.replace(old,
        "        // TSP_REVIEW_CONFIGURED_FONT_051_V72\n"
        "        const int tspReviewStatRowV72 = Settings::gui().mTspStatsFontSize.get() + 4;\n"
        "        MyGUI::IntCoord coord{ 8, 4, 310, tspReviewStatRowV72 };\n", 1)

    # V71 already inserted a 16px call here. Put the configured call AFTER it.
    anchor = "            coord.top += coord.height;\n"
    pos = s.find(anchor, s.find("mAttributeWidgets.emplace"))
    need(pos >= 0, "Review attribute final-font anchor missing")
    s = s[:pos] + (
        "            widget->tspV72SetFontHeight(Settings::gui().mTspStatsFontSize.get());\n"
    ) + s[pos:]

# Ensure RS targets SkillView regardless of V71 state.
if "TSP_REVIEW_DIRECT_SCROLL_051_V72" not in s:
    if "mControllerScrollWidget = mSkillView;" in s:
        old = "        mControllerScrollWidget = mSkillView;\n"
        s = s.replace(old,
            "        // TSP_REVIEW_DIRECT_SCROLL_051_V72\n" + old, 1)
    else:
        anchor = '        getWidget(mSkillView, "SkillView");\n'
        need(anchor in s, "Review SkillView anchor missing")
        s = s.replace(anchor, anchor +
            '        // TSP_REVIEW_DIRECT_SCROLL_051_V72\n'
            '        mControllerScrollWidget = mSkillView;\n'
            '        mSkillView->setUserString("TSPDirectControllerScroll", "1");\n', 1)

    if 'mSkillView->setUserString("TSPDirectControllerScroll", "1");' not in s:
        anchor = "        mControllerScrollWidget = mSkillView;\n"
        s = s.replace(anchor, anchor +
            '        mSkillView->setUserString("TSPDirectControllerScroll", "1");\n', 1)

    if 'mControllerButtons.mRStick' not in s:
        old = '            mControllerButtons.mA = "#{Interface:Select}";\n'
        need(old in s, "Review controller overlay anchor missing")
        s = s.replace(old, '            mControllerButtons.mRStick = "#{Interface:ScrollUp}";\n' + old, 1)

# V71 changed these to constexpr 18; older source used global font+2.
s = s.replace(
    "        const int lineHeight = Settings::gui().mFontSize + 2;\n",
    "        const int lineHeight = Settings::gui().mTspSkillListFontSize.get() + 4;\n",
)
s = s.replace(
    "        constexpr int lineHeight = 18;\n",
    "        const int lineHeight = Settings::gui().mTspSkillListFontSize.get() + 4;\n",
)

if "TSP_REVIEW_ROW_FONTS_051_V72" not in s:
    # Group heading: no V71 16px setter here.
    anchor = "        mSkillWidgets.push_back(groupWidget);\n"
    pos = s.find(anchor, s.find("void ReviewDialog::addGroup"))
    need(pos >= 0, "Review group font anchor missing")
    s = s[:pos] + (
        "        // TSP_REVIEW_ROW_FONTS_051_V72\n"
        "        groupWidget->setFontHeight(Settings::gui().mTspSkillListFontSize.get());\n"
    ) + s[pos:]

    # Value row: insert after any V71 16px setters, immediately before events/state.
    start_value = s.find("MyGUI::TextBox* ReviewDialog::addValueItem")
    need(start_value >= 0, "Review addValueItem missing")

    anchor = "        skillNameWidget->eventMouseWheel += MyGUI::newDelegate(this, &ReviewDialog::onMouseWheel);\n"
    pos = s.find(anchor, start_value)
    need(pos >= 0, "Review skill-name final-font anchor missing")
    s = s[:pos] + (
        "        skillNameWidget->setFontHeight(Settings::gui().mTspSkillListFontSize.get());\n"
    ) + s[pos:]

    anchor = "        skillValueWidget->_setWidgetState(state);\n"
    pos = s.find(anchor, start_value)
    need(pos >= 0, "Review skill-value final-font anchor missing")
    s = s[:pos] + (
        "        skillValueWidget->setFontHeight(Settings::gui().mTspSkillListFontSize.get());\n"
    ) + s[pos:]

    # Plain string item.
    start_item = s.find("void ReviewDialog::addItem(const std::string& text")
    need(start_item >= 0, "Review string addItem missing")
    anchor = "        skillNameWidget->eventMouseWheel += MyGUI::newDelegate(this, &ReviewDialog::onMouseWheel);\n"
    pos = s.find(anchor, start_item)
    need(pos >= 0, "Review plain-item final-font anchor missing")
    s = s[:pos] + (
        "        skillNameWidget->setFontHeight(Settings::gui().mTspSkillListFontSize.get());\n"
    ) + s[pos:]

    # Spell item: insert after any old/V71 font setter, just before tooltip setup.
    start_spell = s.find("void ReviewDialog::addItem(const ESM::Spell* spell")
    need(start_spell >= 0, "Review spell addItem missing")
    anchor = '        widget->setUserString("ToolTipType", "Spell");\n'
    pos = s.find(anchor, start_spell)
    need(pos >= 0, "Review spell final-font anchor missing")
    s = s[:pos] + (
        "        widget->tspV72SetNameFontHeight(Settings::gui().mTspSkillListFontSize.get());\n"
    ) + s[pos:]

# Match the initial widget height to the configured skill font.
old = "        MyGUI::IntCoord coord1(10, 0, mSkillView->getWidth() - (10 + valueSize) - 24, 18);\n"
if old in s:
    s = s.replace(old,
        "        const int tspReviewSkillRowV72 = Settings::gui().mTspSkillListFontSize.get() + 4;\n"
        "        MyGUI::IntCoord coord1(10, 0, mSkillView->getWidth() - (10 + valueSize) - 24,\n"
        "            tspReviewSkillRowV72);\n", 1)

wr(rel, s)

# ------------------------------------------------------------------
# Replace the problematic chargen layouts. These are intentionally bigger.
# V70s previous runtime-layout failure happened because the installer guessed
# resources/mygui; deployment below finds the real runtime path instead.
# ------------------------------------------------------------------
layouts = {}

layouts["files/data/mygui/openmw_chargen_class.layout"] = '''<?xml version="1.0" encoding="UTF-8"?>
<MyGUI type="Layout">
    <Widget type="Window" skin="MW_Dialog" layer="Modal" position="0 0 760 430" align="Center" name="_Main">
        <Widget type="ListBox" skin="MW_List" position="8 8 260 150" name="ClassList"/>
        <Widget type="Widget" skin="MW_Box" position="278 8 466 150" align="Left Top">
            <Widget type="ImageBox" skin="ImageBox" position="2 2 462 146" name="ClassImage" align="Stretch"/>
        </Widget>
        <Widget type="Widget" skin="" position="8 170 736 190" align="Left Top">
            <Widget type="TextBox" skin="HeaderText" position="0 0 238 34" name="SpecializationT"><Property key="Caption" value="#{sChooseClassMenu1}"/><Property key="TextAlign" value="Left VCenter"/></Widget>
            <Widget type="TextBox" skin="SandText" position="0 34 238 30" name="SpecializationName"><Property key="TextAlign" value="Left VCenter"/></Widget>
            <Widget type="TextBox" skin="HeaderText" position="0 70 238 34" name="FavoriteAttributesT"><Property key="Caption" value="#{sChooseClassMenu2}"/><Property key="TextAlign" value="Left VCenter"/></Widget>
            <Widget type="MWAttribute" skin="MW_StatNameButton" position="0 106 238 30" name="FavoriteAttribute0"/>
            <Widget type="MWAttribute" skin="MW_StatNameButton" position="0 138 238 30" name="FavoriteAttribute1"/>
            <Widget type="TextBox" skin="HeaderText" position="248 0 238 34" name="MajorSkillT"><Property key="Caption" value="#{sChooseClassMenu3}"/><Property key="TextAlign" value="Left VCenter"/></Widget>
            <Widget type="MWSkill" skin="MW_StatName" position="248 34 238 30" name="MajorSkill0"/>
            <Widget type="MWSkill" skin="MW_StatName" position="248 64 238 30" name="MajorSkill1"/>
            <Widget type="MWSkill" skin="MW_StatName" position="248 94 238 30" name="MajorSkill2"/>
            <Widget type="MWSkill" skin="MW_StatName" position="248 124 238 30" name="MajorSkill3"/>
            <Widget type="MWSkill" skin="MW_StatName" position="248 154 238 30" name="MajorSkill4"/>
            <Widget type="TextBox" skin="HeaderText" position="496 0 238 34" name="MinorSkillT"><Property key="Caption" value="#{sChooseClassMenu4}"/><Property key="TextAlign" value="Left VCenter"/></Widget>
            <Widget type="MWSkill" skin="MW_StatName" position="496 34 238 30" name="MinorSkill0"/>
            <Widget type="MWSkill" skin="MW_StatName" position="496 64 238 30" name="MinorSkill1"/>
            <Widget type="MWSkill" skin="MW_StatName" position="496 94 238 30" name="MinorSkill2"/>
            <Widget type="MWSkill" skin="MW_StatName" position="496 124 238 30" name="MinorSkill3"/>
            <Widget type="MWSkill" skin="MW_StatName" position="496 154 238 30" name="MinorSkill4"/>
        </Widget>
        <Widget type="HBox" position="0 382 744 34">
            <Widget type="Spacer"/>
            <Widget type="AutoSizedButton" skin="MW_Button" name="BackButton"><Property key="Caption" value="#{sBack}"/></Widget>
            <Widget type="AutoSizedButton" skin="MW_Button" name="OKButton"><Property key="Caption" value="#{Interface:OK}"/></Widget>
        </Widget>
    </Widget>
</MyGUI>
'''

layouts["files/data/mygui/openmw_chargen_create_class.layout"] = '''<?xml version="1.0" encoding="UTF-8"?>
<MyGUI type="Layout">
    <Widget type="Window" skin="MW_Dialog" layer="Modal" position="0 0 760 330" align="Center" name="_Main">
        <Widget type="TextBox" skin="NormalText" position="8 8 80 34" name="LabelT"><Property key="Caption" value="#{sName}:"/><Property key="TextAlign" value="Left VCenter"/></Widget>
        <Widget type="EditBox" skin="MW_TextEdit" position="96 8 648 34" name="EditName" align="HStretch Top"><Property key="Caption" value="#{sCustomClassName}"/></Widget>
        <Widget type="Widget" skin="" position="8 54 736 190" align="Stretch">
            <Widget type="TextBox" skin="HeaderText" position="0 0 238 34" name="SpecializationT"><Property key="Caption" value="#{sChooseClassMenu1}"/><Property key="TextAlign" value="Left VCenter"/></Widget>
            <Widget type="Button" skin="SandTextButton" position="0 34 238 30" name="SpecializationName"><Property key="TextAlign" value="Left VCenter"/></Widget>
            <Widget type="TextBox" skin="HeaderText" position="0 70 238 34" name="FavoriteAttributesT"><Property key="Caption" value="#{sChooseClassMenu2}"/><Property key="TextAlign" value="Left VCenter"/></Widget>
            <Widget type="MWAttribute" skin="MW_StatNameButton" position="0 106 238 30" name="FavoriteAttribute0"/>
            <Widget type="MWAttribute" skin="MW_StatNameButton" position="0 138 238 30" name="FavoriteAttribute1"/>
            <Widget type="TextBox" skin="HeaderText" position="248 0 238 34" name="MajorSkillT"><Property key="Caption" value="#{sChooseClassMenu3}"/><Property key="TextAlign" value="Left VCenter"/></Widget>
            <Widget type="MWSkill" skin="MW_StatNameButton" position="248 34 238 30" name="MajorSkill0"/>
            <Widget type="MWSkill" skin="MW_StatNameButton" position="248 64 238 30" name="MajorSkill1"/>
            <Widget type="MWSkill" skin="MW_StatNameButton" position="248 94 238 30" name="MajorSkill2"/>
            <Widget type="MWSkill" skin="MW_StatNameButton" position="248 124 238 30" name="MajorSkill3"/>
            <Widget type="MWSkill" skin="MW_StatNameButton" position="248 154 238 30" name="MajorSkill4"/>
            <Widget type="TextBox" skin="HeaderText" position="496 0 238 34" name="MinorSkillT"><Property key="Caption" value="#{sChooseClassMenu4}"/><Property key="TextAlign" value="Left VCenter"/></Widget>
            <Widget type="MWSkill" skin="MW_StatNameButton" position="496 34 238 30" name="MinorSkill0"/>
            <Widget type="MWSkill" skin="MW_StatNameButton" position="496 64 238 30" name="MinorSkill1"/>
            <Widget type="MWSkill" skin="MW_StatNameButton" position="496 94 238 30" name="MinorSkill2"/>
            <Widget type="MWSkill" skin="MW_StatNameButton" position="496 124 238 30" name="MinorSkill3"/>
            <Widget type="MWSkill" skin="MW_StatNameButton" position="496 154 238 30" name="MinorSkill4"/>
        </Widget>
        <Widget type="HBox" position="0 274 744 38">
            <Widget type="Spacer"/>
            <Widget type="AutoSizedButton" skin="MW_Button" name="DescriptionButton"><Property key="Caption" value="#{sCreateClassMenu1}"/></Widget>
            <Widget type="AutoSizedButton" skin="MW_Button" name="BackButton"><Property key="Caption" value="#{sBack}"/></Widget>
            <Widget type="AutoSizedButton" skin="MW_Button" name="OKButton"><Property key="Caption" value="#{Interface:OK}"/></Widget>
        </Widget>
    </Widget>
</MyGUI>
'''

layouts["files/data/mygui/openmw_chargen_race.layout"] = '''<?xml version="1.0" encoding="UTF-8"?>
<MyGUI type="Layout">
    <Widget type="Window" skin="MW_Dialog" layer="Modal" position="0 0 800 560" align="Center" name="_Main">
        <Widget type="TextBox" skin="HeaderText" position="8 8 300 34" name="AppearanceT"><Property key="Caption" value="Appearance"/><Property key="TextAlign" value="Left VCenter"/></Widget>
        <Widget type="Widget" skin="MW_Box" position="8 46 300 246"><Widget type="ImageBox" skin="ImageBox" position="2 2 296 242" align="Stretch" name="PreviewImage"/></Widget>
        <Widget type="ScrollBar" skin="MW_HScroll" position="8 302 300 16" name="HeadRotate"/>
        <Widget type="Widget" skin="MW_Box" position="8 332 20 28"><Widget type="Button" skin="MW_ArrowLeft" position="3 3 14 22" name="PrevGenderButton"/></Widget>
        <Widget type="TextBox" skin="HeaderText" position="34 328 240 34" name="GenderChoiceT"><Property key="TextAlign" value="Left VCenter"/></Widget>
        <Widget type="Widget" skin="MW_Box" position="282 332 20 28"><Widget type="Button" skin="MW_ArrowRight" position="3 3 14 22" name="NextGenderButton"/></Widget>
        <Widget type="Widget" skin="MW_Box" position="8 372 20 28"><Widget type="Button" skin="MW_ArrowLeft" position="3 3 14 22" name="PrevFaceButton"/></Widget>
        <Widget type="TextBox" skin="HeaderText" position="34 368 240 34" name="FaceChoiceT"><Property key="TextAlign" value="Left VCenter"/></Widget>
        <Widget type="Widget" skin="MW_Box" position="282 372 20 28"><Widget type="Button" skin="MW_ArrowRight" position="3 3 14 22" name="NextFaceButton"/></Widget>
        <Widget type="Widget" skin="MW_Box" position="8 412 20 28"><Widget type="Button" skin="MW_ArrowLeft" position="3 3 14 22" name="PrevHairButton"/></Widget>
        <Widget type="TextBox" skin="HeaderText" position="34 408 240 34" name="HairChoiceT"><Property key="TextAlign" value="Left VCenter"/></Widget>
        <Widget type="Widget" skin="MW_Box" position="282 412 20 28"><Widget type="Button" skin="MW_ArrowRight" position="3 3 14 22" name="NextHairButton"/></Widget>
        <Widget type="TextBox" skin="HeaderText" position="324 8 214 34" name="RaceT"><Property key="TextAlign" value="Left VCenter"/></Widget>
        <Widget type="ListBox" skin="MW_List" position="324 46 214 190" name="RaceList"/>
        <Widget type="TextBox" skin="HeaderText" position="324 248 224 34" name="SpellPowerT"><Property key="TextAlign" value="Left VCenter"/></Widget>
        <Widget type="Widget" skin="" position="324 286 224 214" name="SpellPowerList"/>
        <Widget type="TextBox" skin="HeaderText" position="560 8 230 34" name="SkillsT"><Property key="TextAlign" value="Left VCenter"/></Widget>
        <Widget type="Widget" skin="" position="560 46 230 454" name="SkillList"/>
        <Widget type="HBox" position="0 510 784 36"><Widget type="Spacer"/><Widget type="AutoSizedButton" skin="MW_Button" name="BackButton"><Property key="Caption" value="#{sBack}"/></Widget><Widget type="AutoSizedButton" skin="MW_Button" name="OKButton"><Property key="Caption" value="#{Interface:OK}"/></Widget></Widget>
    </Widget>
</MyGUI>
'''

layouts["files/data/mygui/openmw_chargen_review.layout"] = '''<?xml version="1.0" encoding="UTF-8"?>
<MyGUI type="Layout">
    <Widget type="Window" skin="MW_Dialog" layer="Modal" position="0 0 760 600" align="Center" name="_Main">
        <Widget type="Widget" skin="MW_Box" position="8 8 350 140">
            <Widget type="Button" skin="MW_Button" position="8 8 100 28" name="NameButton"><Property key="Caption" value="#{sName}"/></Widget>
            <Widget type="Button" skin="MW_Button" position="8 40 100 28" name="RaceButton"><Property key="Caption" value="#{sRace}"/></Widget>
            <Widget type="Button" skin="MW_Button" position="8 72 100 28" name="ClassButton"><Property key="Caption" value="#{sClass}"/></Widget>
            <Widget type="Button" skin="MW_Button" position="8 104 100 28" name="SignButton"><Property key="Caption" value="#{sBirthSign}"/></Widget>
            <Widget type="TextBox" skin="SandTextRight" position="118 8 224 28" name="NameText"/>
            <Widget type="TextBox" skin="SandTextRight" position="118 40 224 28" name="RaceText"/>
            <Widget type="TextBox" skin="SandTextRight" position="118 72 224 28" name="ClassText"/>
            <Widget type="TextBox" skin="SandTextRight" position="118 104 224 28" name="SignText"/>
        </Widget>
        <Widget type="Widget" skin="MW_Box" position="8 156 350 100">
            <Widget type="MWDynamicStat" skin="MW_DynamicStat_Red" position="8 8 334 26" name="Health"><UserString key="ToolTipType" value="Layout"/><UserString key="ToolTipLayout" value="HealthToolTip"/><UserString key="ImageTexture_HealthImage" value="icons\\k\\health.dds"/><Property key="Caption" value="#{sHealth}"/></Widget>
            <Widget type="MWDynamicStat" skin="MW_DynamicStat_Blue" position="8 37 334 26" name="Magicka"><UserString key="ToolTipType" value="Layout"/><UserString key="ToolTipLayout" value="HealthToolTip"/><UserString key="ImageTexture_HealthImage" value="icons\\k\\magicka.dds"/><Property key="Caption" value="#{sMagic}"/></Widget>
            <Widget type="MWDynamicStat" skin="MW_DynamicStat_Green" position="8 66 334 26" name="Fatigue"><UserString key="ToolTipType" value="Layout"/><UserString key="ToolTipLayout" value="HealthToolTip"/><UserString key="ImageTexture_HealthImage" value="icons\\k\\fatigue.dds"/><Property key="Caption" value="#{sFatigue}"/></Widget>
        </Widget>
        <Widget type="Widget" skin="MW_Box" position="8 264 350 280" name="Attributes"/>
        <Widget type="Widget" skin="MW_Box" position="366 8 378 536" name="Skills"><Widget type="ScrollView" skin="MW_ScrollView" position="8 6 362 522" align="Stretch" name="SkillView"/></Widget>
        <Widget type="HBox" position="0 552 744 34"><Widget type="Spacer"/><Widget type="AutoSizedButton" skin="MW_Button" name="BackButton"><Property key="Caption" value="#{sBack}"/></Widget><Widget type="AutoSizedButton" skin="MW_Button" name="OKButton"><Property key="Caption" value="#{Interface:OK}"/></Widget></Widget>
    </Widget>
</MyGUI>
'''

for rel, content in layouts.items():
    wr(rel, content)

# Refuse to rebuild if the old actor-hibernation source somehow returned.
scene = rd("apps/openmw/mwworld/scene.cpp")
need("TSP_ROOM_ACTOR_HIBERNATE_051_V30" not in scene,
     "old actor hibernation code is present; refusing to rebuild")

# Verify important V72 source markers.
for rel, markers in {
    "apps/openmw/mwinput/inputmanagerimp.cpp": [
        "TSP_SAVELOAD_CURSOR_MODAL_051_V72",
        "TSP_FOCUSED_EDITBOX_TEXT_051_V72",
        "TSP_TEXT_TAP_RELEASE_051_V72",
    ],
    "apps/openmw/mwinput/controllermanager.cpp": [
        "TSP_CLICK_EDITBOX_TO_TEXT_051_V72",
    ],
    "apps/openmw/mwgui/class.cpp": [
        "TSP_PICK_CLASS_CONFIGURED_FONT_051_V72",
        "TSP_CREATE_CLASS_CONFIGURED_FONT_051_V72",
    ],
    "apps/openmw/mwgui/race.cpp": [
        "TSP_RACE_SKILL_ROWS_051_V72",
        "TSP_RACE_POWER_ROWS_051_V72",
    ],
    "apps/openmw/mwgui/review.cpp": [
        "TSP_REVIEW_CONFIGURED_FONT_051_V72",
        "TSP_REVIEW_DIRECT_SCROLL_051_V72",
    ],
}.items():
    data = rd(rel)
    for marker in markers:
        need(marker in data, f"{rel}: missing {marker}")

print("V72 source patch: PASS")
PYV72

"${DOCKER[@]}" cp "$PATCHER" "$CONTAINER:/root/tsp_v72_patch.py"

"${DOCKER[@]}" exec -i \
    -e V72_SRC="$SRC" \
    -e V72_BUILD="$BUILD" \
    -e V72_STAMP="$STAMP" \
    "$CONTAINER" bash -s <<'CONTAINER_V72'
set -Eeuo pipefail
trap 'rc=$?; echo "ERROR: V72 container step stopped at line $LINENO (status $rc)." >&2' ERR

SRC="$V72_SRC"
BUILD="$V72_BUILD"
STAMP="$V72_STAMP"
BACK="/root/.tsp-v72-backups/$STAMP"

test -d "$SRC" || { echo "ERROR: source tree missing: $SRC" >&2; exit 2; }
test -d "$BUILD" || { echo "ERROR: build tree missing: $BUILD" >&2; exit 2; }

mkdir -p "$BACK"

FILES=(
  "$SRC/apps/openmw/mwinput/inputmanagerimp.cpp"
  "$SRC/apps/openmw/mwinput/controllermanager.cpp"
  "$SRC/apps/openmw/mwgui/widgets.hpp"
  "$SRC/apps/openmw/mwgui/widgets.cpp"
  "$SRC/apps/openmw/mwgui/class.cpp"
  "$SRC/apps/openmw/mwgui/race.cpp"
  "$SRC/apps/openmw/mwgui/birth.cpp"
  "$SRC/apps/openmw/mwgui/review.cpp"
  "$SRC/files/data/mygui/openmw_chargen_class.layout"
  "$SRC/files/data/mygui/openmw_chargen_create_class.layout"
  "$SRC/files/data/mygui/openmw_chargen_race.layout"
  "$SRC/files/data/mygui/openmw_chargen_review.layout"
)

for f in "${FILES[@]}"; do
    test -e "$f" || { echo "ERROR: missing source file: $f" >&2; exit 3; }
    cp -a "$f" "$BACK/$(basename "$f").before-v72"
done

echo "Source backup: $BACK"

python3 /root/tsp_v72_patch.py "$SRC"

echo
echo "===== BUILD OPENMW ====="
cmake --build "$BUILD" --target openmw --parallel 2

test -s "$BUILD/openmw" || { echo "ERROR: OpenMW binary missing after build." >&2; exit 4; }
readelf -h "$BUILD/openmw" | grep -E "Class:|Machine:|Type:"
readelf -h "$BUILD/openmw" | grep -q "AArch64" || {
    echo "ERROR: built OpenMW is not AArch64." >&2
    exit 4
}

echo "OpenMW V72 build: PASS"

PAYLOAD="/root/tsp-v72-payload"
rm -rf "$PAYLOAD"
mkdir -p "$PAYLOAD/layouts"
cp -a "$BUILD/openmw" "$PAYLOAD/openmw-0.51-v72"
chmod 755 "$PAYLOAD/openmw-0.51-v72"

for name in \
    openmw_chargen_class.layout \
    openmw_chargen_create_class.layout \
    openmw_chargen_race.layout \
    openmw_chargen_review.layout
do
    cp -a "$SRC/files/data/mygui/$name" "$PAYLOAD/layouts/$name"
done

echo
echo "===== CONTAINER PAYLOAD ====="
ls -lh "$PAYLOAD/openmw-0.51-v72" "$PAYLOAD"/layouts/*.layout
sha256sum "$PAYLOAD/openmw-0.51-v72"
CONTAINER_V72

if [ "$DEPLOY" != "1" ]; then
    echo
    echo "DEPLOY=$DEPLOY: build complete; handheld untouched."
    echo "Payload remains inside container at /root/tsp-v72-payload"
    exit 0
fi

echo
echo "===== DEPLOY TO $DEVICE_IP ====="
echo "Streaming directly from Docker to the handheld; no VM binary backup/copy is created."
echo "This does NOT touch launcher, helper, libGL, settings.cfg, openmw.cfg, mods, or saves."

set +e
"${DOCKER[@]}" exec "$CONTAINER" tar -C /root/tsp-v72-payload -cf - . \
| ssh "root@$DEVICE_IP" '
set -eu

STAGE="/tmp/openmw-v72-stage"
rm -rf "$STAGE"
mkdir -p "$STAGE"
tar -C "$STAGE" -xf -

ROOT=""
for candidate in \
    /mnt/SDCARD/Data/ports/openmw \
    /mnt/SDCARD/data/ports/openmw \
    /mnt/mmc/ports/openmw \
    /userdata/roms/ports/openmw
do
    if [ -e "$candidate/bin/openmw-0.51" ]; then
        ROOT="$candidate"
        break
    fi
done

[ -n "$ROOT" ] || {
    echo "ERROR: live OpenMW root not found." >&2
    exit 20
}

BIN="$ROOT/bin/openmw-0.51"
[ -s "$STAGE/openmw-0.51-v72" ] || {
    echo "ERROR: staged V72 binary missing." >&2
    exit 21
}

find_layouts() {
    find "$ROOT/resources" -type f -name "$1" -print 2>/dev/null || true
}

CLASS="$(find_layouts openmw_chargen_class.layout)"
CREATE="$(find_layouts openmw_chargen_create_class.layout)"
RACE="$(find_layouts openmw_chargen_race.layout)"
REVIEW="$(find_layouts openmw_chargen_review.layout)"

for spec in \
    "openmw_chargen_class.layout:$CLASS" \
    "openmw_chargen_create_class.layout:$CREATE" \
    "openmw_chargen_race.layout:$RACE" \
    "openmw_chargen_review.layout:$REVIEW"
do
    name="${spec%%:*}"
    paths="${spec#*:}"
    [ -n "$paths" ] || {
        echo "ERROR: runtime layout not found under $ROOT/resources: $name" >&2
        exit 22
    }
done

STAMP="$(date +%Y%m%d-%H%M%S)"
BACK="$ROOT/v72-backup-$STAMP"
mkdir -p "$BACK/layouts"

cp -a "$BIN" "$BACK/openmw-0.51"

backup_and_replace_all() {
    name="$1"
    src="$2"
    i=0
    find "$ROOT/resources" -type f -name "$name" -print 2>/dev/null |
    while IFS= read -r dst; do
        i=$((i+1))
        cp -a "$dst" "$BACK/layouts/$name.$i"
        install -m 644 "$src" "$dst"
        echo "UPDATED LAYOUT: $dst"
    done
}

install -m 755 "$STAGE/openmw-0.51-v72" "$BIN"
backup_and_replace_all openmw_chargen_class.layout "$STAGE/layouts/openmw_chargen_class.layout"
backup_and_replace_all openmw_chargen_create_class.layout "$STAGE/layouts/openmw_chargen_create_class.layout"
backup_and_replace_all openmw_chargen_race.layout "$STAGE/layouts/openmw_chargen_race.layout"
backup_and_replace_all openmw_chargen_review.layout "$STAGE/layouts/openmw_chargen_review.layout"

sync

echo
echo "===== V72 INSTALLED ====="
echo "ROOT:   $ROOT"
echo "BACKUP: $BACK"
sha256sum "$BIN"

echo
echo "UNCHANGED:"
echo "  $ROOT/tsp_openmw_controls"
echo "  $ROOT/lib/libGL.so.1"
echo "  launcher"
echo "  settings.cfg / openmw.cfg"
echo "  mods / saves"
'

SSH_RC=${PIPESTATUS[1]}
set -e

echo
if [ "$SSH_RC" -eq 0 ]; then
    echo "PASS: V72 installed on $DEVICE_IP."
else
    echo "ERROR: handheld install failed with status $SSH_RC."
    echo "Your VM terminal remains open."
    exit "$SSH_RC"
fi
