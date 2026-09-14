import io, os, re, sys, time
SRC = os.environ.get("TSPSRC", "/root/openmw-0.51-tsp-src")
SET = os.path.join(SRC, "apps/openmw/mwgui/settingswindow.cpp")
DLG = os.path.join(SRC, "apps/openmw/mwgui/dialogue.cpp")
MARK = "TSP_DROPDOWN_FONT_051_V56"
set_txt = io.open(SET, encoding="utf-8").read()
dlg_txt = io.open(DLG, encoding="utf-8").read()
orig = (set_txt, dlg_txt)
if "MyGUI_ComboBox.h" not in set_txt:
    print("FAIL: no MyGUI_ComboBox.h"); sys.exit(1)
print("OK: preconditions")
if "components/settings/settings.hpp" in set_txt:
    print("SKIP: settings.hpp already included")
else:
    a = "#include <components/settings/values.hpp>"
    if set_txt.count(a) != 1:
        print("FAIL: values.hpp include not unique"); sys.exit(1)
    set_txt = set_txt.replace(a, "#include <components/settings/settings.hpp>\n" + a, 1)
    print("OK:   include settings.hpp")
HOOK = r'''\g<0>
\g<i>// TSP_DROPDOWN_FONT_051_V56 -- a ComboBox ignores FontHeight from the layout
\g<i>// and from its MW_ComboBox ResourceLayout template, so these drew at the
\g<i>// global font size. Runtime setFontHeight is what works. getOrDefault means
\g<i>// no gui.hpp and no defaults.bin entry.
\g<i>if (MyGUI::ComboBox* tspCombo = current->castType<MyGUI::ComboBox>(false))
\g<i>{
\g<i>    int tspComboFont = Settings::Manager::getOrDefault<int>("dropdown font size", "GUI", 18);
\g<i>    if (tspComboFont < 8)
\g<i>        tspComboFont = 8;
\g<i>    else if (tspComboFont > 40)
\g<i>        tspComboFont = 40;
\g<i>    tspCombo->setFontHeight(tspComboFont);
\g<i>}'''
if MARK in set_txt:
    print("SKIP: ComboBox hook already present")
else:
    A1 = (r'^(?P<i>[ \t]*)MyGUI::Widget\* current = widgets\.current\(\);[ \t\r]*\n'
          r'[ \t]*std::string_view type = getSettingType\(current\);[ \t\r]*$')
    A2 = r'^(?P<i>[ \t]*)MyGUI::Widget\* current = widgets\.current\(\);[ \t\r]*$'
    used = None
    for name, pat in (("two-line", A1), ("single-line", A2)):
        rx = re.compile(pat, re.M)
        n = len(rx.findall(set_txt))
        print("      anchor %-12s -> %d match(es)" % (name, n))
        if n == 1 and used is None:
            set_txt = rx.sub(HOOK, set_txt, count=1); used = name
    if used is None:
        print("FAIL: no usable anchor. Exact bytes of the candidate lines:")
        for i, ln in enumerate(set_txt.split("\n"), 1):
            if "widgets.current()" in ln or "getSettingType(current)" in ln:
                print("  %5d %r" % (i, ln))
        sys.exit(1)
    print("OK:   ComboBox hook via %s anchor" % used)
if 'sPersuasion")->mValue.getString(), 0, getTspDialogueFontSize())' in dlg_txt:
    print("SKIP: Persuasion already uses the setting")
else:
    a = 'sPersuasion")->mValue.getString(), 0, 20)'
    if dlg_txt.count(a) != 1:
        print("FAIL: sPersuasion literal matched %d" % dlg_txt.count(a)); sys.exit(1)
    dlg_txt = dlg_txt.replace(a, 'sPersuasion")->mValue.getString(), 0, getTspDialogueFontSize())', 1)
    print("OK:   Persuasion follows dialogue font size")
for txt, name in ((set_txt, "settingswindow.cpp"), (dlg_txt, "dialogue.cpp")):
    for o, c in (("{", "}"), ("(", ")")):
        if txt.count(o) != txt.count(c):
            print("FAIL: %s unbalanced %s%s" % (name, o, c)); sys.exit(1)
if set_txt.count("tspCombo->setFontHeight(tspComboFont);") != 1:
    print("FAIL: combo font call count wrong"); sys.exit(1)
if dlg_txt.count("getTspDialogueFontSize()") < 10:
    print("FAIL: dialogue call sites dropped"); sys.exit(1)
print("OK: balance + call-site counts")
if (set_txt, dlg_txt) == orig:
    print("VERIFIED: v56 already present"); sys.exit(0)
s = time.strftime("%Y%m%d-%H%M%S")
for p, t, o in ((SET, set_txt, orig[0]), (DLG, dlg_txt, orig[1])):
    if t != o:
        io.open("%s.before-v56-%s" % (p, s), "w", encoding="utf-8", newline="").write(o)
        io.open(p, "w", encoding="utf-8", newline="").write(t)
        print("wrote %s" % os.path.basename(p))
print("VERIFIED: v56 present")
