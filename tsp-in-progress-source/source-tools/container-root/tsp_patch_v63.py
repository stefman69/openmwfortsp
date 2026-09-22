"""TSP_LEVELUP_LAYOUT_051_V63 -- level-up rows sized for the actual font.

Every metric in LevelupDialog's constructor is a literal 20 chosen for the stock
16px font: row pitch (20 * row), row height (20), and the gap reserved for the
"xN" multiplier before the attribute name (offset + 20). sColumnOffsets puts the
second column at 218, i.e. 186px for "x2 Intelligence 42". At 28 the rows overlap
vertically AND the multiplier runs into the name.

1. Row pitch, row height, multiplier gap and canvas height are derived from the
   font height instead of hardcoded.
2. A "levelup font size" [GUI] key (getOrDefault, default 18 -- near the stock 16
   the 32/218 columns were designed for) drives the three text widgets.

getOrDefault means no gui.hpp and no defaults.bin entry. sColumnOffsets is
deliberately unchanged: moving column 2 needs the dialog width from the layout.
"""
import io, os, re, sys, time
SRC = os.environ.get("TSPSRC", "/root/openmw-0.51-tsp-src")
LV = os.environ.get("TSPLV", os.path.join(SRC, "apps/openmw/mwgui/levelupdialog.cpp"))
MARK = "TSP_LEVELUP_LAYOUT_051_V63"
t = io.open(LV, encoding="utf-8").read()
orig = t
if "components/settings/values.hpp" not in t:
    print("FAIL: no settings/values.hpp"); sys.exit(1)
if "sColumnOffsets[] = { 32, 218 }" not in t:
    print("FAIL: sColumnOffsets is not the expected shape"); sys.exit(1)
print("OK: preconditions")
if MARK in t:
    print("SKIP: already applied")
else:
    if "components/settings/settings.hpp" not in t:
        a = "#include <components/settings/values.hpp>"
        if t.count(a) != 1: print("FAIL: values.hpp include not unique"); sys.exit(1)
        t = t.replace(a, "#include <components/settings/settings.hpp>\n" + a, 1)
        print("OK:   include settings.hpp")
    rx = re.compile(r'^(?P<i>[ \t]*)constexpr int sColumnOffsets\[\] = \{ 32, 218 \};[ \t\r]*$', re.M)
    if len(rx.findall(t)) != 1: print("FAIL: sColumnOffsets anchor not unique"); sys.exit(1)
    t = rx.sub(
        r'\g<0>'
        '\n' r'\g<i>// ' + MARK + r' -- every 20 below was chosen for the stock 16px'
        '\n' r'\g<i>// font. Derive them instead so rows stop overlapping when the font grows.'
        '\n' r'\g<i>// sColumnOffsets stays as-is: moving column 2 needs the dialog width,'
        '\n' r'\g<i>// which lives in the layout, so the font key keeps the columns fitting.'
        '\n' r'\g<i>int tspLevelupFontSize()'
        '\n' r'\g<i>{'
        '\n' r'\g<i>    int size = Settings::Manager::getOrDefault<int>("levelup font size", "GUI", 18);'
        '\n' r'\g<i>    if (size < 8)'
        '\n' r'\g<i>        size = 8;'
        '\n' r'\g<i>    else if (size > 32)'
        '\n' r'\g<i>        size = 32;'
        '\n' r'\g<i>    return size;'
        '\n' r'\g<i>}'
        '\n' r'\g<i>int tspLevelupRowStep()'
        '\n' r'\g<i>{'
        '\n' r'\g<i>    return tspLevelupFontSize() + 6;'
        '\n' r'\g<i>}'
        '\n' r'\g<i>int tspLevelupMultiplierGap()'
        '\n' r'\g<i>{'
        '\n' r'\g<i>    return tspLevelupFontSize() + 6;'
        '\n' r'\g<i>}', t, count=1)
    print("OK:   font/row helpers added")
    rx = re.compile(
        r'^(?P<i>[ \t]*)widgets\.mMultiplier = mAssignWidget->createWidget<MyGUI::TextBox>\([ \t\r]*\n'
        r'[ \t]*"SandTextVCenter", \{ offset, 20 \* row, 100, 20 \}, MyGUI::Align::Default\);[ \t\r]*\n'
        r'[ \t]*auto\* hbox = mAssignWidget->createWidget<Gui::HBox>\([ \t\r]*\n'
        r'[ \t]*\{\}, \{ offset \+ 20, 20 \* row, 200, 20 \}, MyGUI::Align::Default\);[ \t\r]*$', re.M)
    if len(rx.findall(t)) != 1: print("FAIL: createWidget block not unique"); sys.exit(1)
    t = rx.sub(
        r'\g<i>// ' + MARK
        + '\n' r'\g<i>const int tspRowStep = tspLevelupRowStep();'
        '\n' r'\g<i>const int tspGap = tspLevelupMultiplierGap();'
        '\n' r'\g<i>widgets.mMultiplier = mAssignWidget->createWidget<MyGUI::TextBox>('
        '\n' r'\g<i>    "SandTextVCenter", { offset, tspRowStep * row, 100, tspRowStep },'
        '\n' r'\g<i>    MyGUI::Align::Default);'
        '\n' r'\g<i>widgets.mMultiplier->setFontHeight(tspLevelupFontSize());'
        '\n' r'\g<i>auto* hbox = mAssignWidget->createWidget<Gui::HBox>('
        '\n' r'\g<i>    {}, { offset + tspGap, tspRowStep * row, 200, tspRowStep },'
        '\n' r'\g<i>    MyGUI::Align::Default);', t, count=1)
    print("OK:   multiplier + hbox use the derived pitch")
    a = 'widgets.mButton->setCaption(attribute.mName);'
    if t.count(a) != 1: print("FAIL: button caption anchor not unique"); sys.exit(1)
    t = t.replace(a, a + '\n                widgets.mButton->setFontHeight(tspLevelupFontSize());', 1)
    rx = re.compile(r'^(?P<i>[ \t]*)widgets\.mValue = hbox->createWidget<Gui::AutoSizedTextBox>\("SandText", \{\}, MyGUI::Align::Default\);[ \t\r]*$', re.M)
    if len(rx.findall(t)) != 1: print("FAIL: mValue anchor not unique"); sys.exit(1)
    t = rx.sub(r'\g<0>' '\n' r'\g<i>widgets.mValue->setFontHeight(tspLevelupFontSize());', t, count=1)
    print("OK:   attribute name + value follow the same size")
    a = 'std::max(mAssignWidget->getHeight(), static_cast<int>(20 * mPerCol))'
    if t.count(a) != 1: print("FAIL: canvas anchor not unique"); sys.exit(1)
    t = t.replace(a, 'std::max(mAssignWidget->getHeight(), static_cast<int>(tspLevelupRowStep() * mPerCol))', 1)
    print("OK:   scroll canvas height follows the pitch")
    a = 'const int xdiff = widgets.mMultiplier->getCaption().empty() ? 0 : 20;'
    if t.count(a) != 1: print("FAIL: coin xdiff anchor not unique"); sys.exit(1)
    t = t.replace(a, 'const int xdiff\n                = widgets.mMultiplier->getCaption().empty() ? 0 : tspLevelupMultiplierGap();', 1)
    print("OK:   coin offset follows the multiplier gap")
for o, c in (("{", "}"), ("(", ")")):
    if t.count(o) != t.count(c): print("FAIL: unbalanced %s%s" % (o, c)); sys.exit(1)
if "20 * row" in t: print("FAIL: hardcoded row pitch survived"); sys.exit(1)
if "20 * mPerCol" in t: print("FAIL: hardcoded canvas height survived"); sys.exit(1)
if "offset + 20," in t: print("FAIL: hardcoded multiplier gap survived"); sys.exit(1)
if t.count("sColumnOffsets[] = { 32, 218 }") != 1: print("FAIL: column offsets changed"); sys.exit(1)
if t.count("setFontHeight(tspLevelupFontSize())") != 3: print("FAIL: expected 3 font applications"); sys.exit(1)
print("OK: no hardcoded 20s left, columns untouched, 3 widgets sized")
if t == orig:
    print("VERIFIED: v63 already present, nothing written."); sys.exit(0)
s = time.strftime("%Y%m%d-%H%M%S")
io.open("%s.before-v63-%s" % (LV, s), "w", encoding="utf-8", newline="").write(orig)
io.open(LV, "w", encoding="utf-8", newline="").write(t)
print("wrote levelupdialog.cpp")
print("VERIFIED: v63 present")
