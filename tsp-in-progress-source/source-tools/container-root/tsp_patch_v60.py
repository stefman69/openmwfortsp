"""TSP_BARTER_CONTROLLER_DEFAULT_051_V60 -- barter/loot open in CONTROLLER.

TradeWindow has no onOpen and never calls setKeyFocusWidget. The pad is seized by
CountDialog::openCountDialog (countdialog.cpp:51), which focuses mItemEdit -> SDL
text goes live -> the reconcile in inputmanagerimp writes the helper flag -> the
helper takes EVIOCGRAB. That is the stack-number dialog.

Reuse V58's /tmp/openmw-tsp-force-controller ("suppress the helper even though SDL
text is live"): assert it on the text edge while a barter/container GUI is up, and
have MENU's release handler clear it. Focus stays on mItemEdit -- if it were
removed, SDL text would never be active and MENU could never bring text back.

Scoped to GM_Barter/GM_Container only; name creation, save, spellmaking and
enchanting keep automatic text.
"""
import io, os, re, sys, time
SRC = os.environ.get("TSPSRC", "/root/openmw-0.51-tsp-src")
IM = os.path.join(SRC, "apps/openmw/mwinput/inputmanagerimp.cpp")
CM = os.path.join(SRC, "apps/openmw/mwinput/controllermanager.cpp")
MARK = "TSP_BARTER_CONTROLLER_DEFAULT_051_V60"
im = io.open(IM, encoding="utf-8").read()
cm = io.open(CM, encoding="utf-8").read()
orig = (im, cm)
for need, where, txt in (
    ("TSP_EXPLICIT_UI_STATE_051_V58", "inputmanagerimp.cpp", im),
    ("MWGui::GM_MainMenu", "inputmanagerimp.cpp", im),
    ('std::fopen("/tmp/openmw-tsp-force-controller", "r")', "inputmanagerimp.cpp", im),
    ("TSP_NO_STICKCLICK_MODES_051_V54", "controllermanager.cpp", cm),
    ('std::fopen("/tmp/openmw-tsp-text-reset", "w")', "controllermanager.cpp", cm),
):
    if need not in txt:
        print("FAIL: %s missing from %s" % (need, where)); sys.exit(1)
print("OK: preconditions - V58 present, mode.hpp in use, cstdio in use in both files")
BLOCK = r'''\g<i>// ''' + MARK + r''' -- barter and loot open in CONTROLLER.
\g<i>// CountDialog::openCountDialog focuses mItemEdit, SDL text goes live and the
\g<i>// reconcile below hands the pad to the helper the instant a stack dialog
\g<i>// appears. Assert V58's force-controller on that edge instead, so the dialog
\g<i>// opens in controller nav; MENU clears the file and text arrives next frame.
\g<i>// Focus is deliberately NOT removed: SDL text must stay active or MENU would
\g<i>// have nothing to re-enable. Scoped to these two modes on purpose -- name
\g<i>// creation, save, spellmaking and enchanting keep automatic text.
\g<i>{
\g<i>    static bool tspBarterTextWas = false;
\g<i>    const bool tspBarterText = tspTextEntryActive
\g<i>        && (windowManager->containsMode(MWGui::GM_Barter)
\g<i>               || windowManager->containsMode(MWGui::GM_Container));
\g<i>    if (tspBarterText && !tspBarterTextWas)
\g<i>    {
\g<i>        if (std::FILE* tspBarterFlag
\g<i>            = std::fopen("/tmp/openmw-tsp-force-controller", "w"))
\g<i>        {
\g<i>            std::fputs("1\\n", tspBarterFlag);
\g<i>            std::fclose(tspBarterFlag);
\g<i>        }
\g<i>        std::fprintf(stderr, "''' + MARK + r''' barter-text=controller-default\\n");
\g<i>        std::fflush(stderr);
\g<i>    }
\g<i>    tspBarterTextWas = tspBarterText;
\g<i>}
\g<0>'''
if MARK in im:
    print("SKIP: inputmanagerimp already patched")
else:
    rx = re.compile(r'^(?P<i>[ \t]*)bool tspForceController = false;[ \t\r]*$', re.M)
    n = len(rx.findall(im))
    if n != 1:
        print("FAIL: tspForceController anchor matched %d (need 1)" % n); sys.exit(1)
    im = rx.sub(BLOCK, im, count=1)
    print("OK:   inputmanagerimp - force-controller asserted on barter text edge")
NEWELSE = r'''\g<i>else
\g<i>{
\g<i>    // ''' + MARK + r'''
\g<i>    // MENU in CONTROLLER asks for TEXT. V58's force-controller file is what
\g<i>    // suppresses the helper (asserted when a barter/loot stack dialog opened,
\g<i>    // or by helper B). Clearing it lets the reconcile in inputmanagerimp
\g<i>    // recreate the helper flag next frame. If it is not set, nothing changes
\g<i>    // and V51 stands: the helper owns MENU while it holds the pad.
\g<i>    bool tspForced = false;
\g<i>    if (std::FILE* tspForceProbe
\g<i>        = std::fopen("/tmp/openmw-tsp-force-controller", "r"))
\g<i>    {
\g<i>        tspForced = true;
\g<i>        std::fclose(tspForceProbe);
\g<i>    }
\g<i>    if (tspForced)
\g<i>    {
\g<i>        std::remove("/tmp/openmw-tsp-force-controller");
\g<i>        Log(Debug::Info)
\g<i>            << "''' + MARK + r''' menu=controller-to-text";
\g<i>    }
\g<i>    else
\g<i>    {
\g<i>        Log(Debug::Info)
\g<i>            << "TSP_TEXT_HANDOFF_051_V51 menu=tap action=helper-owned";
\g<i>    }
\g<i>}'''
if MARK in cm:
    print("SKIP: controllermanager already patched")
else:
    rx = re.compile(
        r'^(?P<i>[ \t]*)else[ \t\r]*\n'
        r'[ \t]*\{[ \t\r]*\n'
        r'[ \t]*Log\(Debug::Info\)[ \t\r]*\n'
        r'[ \t]*<< "TSP_TEXT_HANDOFF_051_V51 menu=tap action=helper-owned";[ \t\r]*\n'
        r'[ \t]*\}[ \t\r]*$', re.M)
    n = len(rx.findall(cm))
    if n != 1:
        print("FAIL: MENU else-branch anchor matched %d (need 1)" % n); sys.exit(1)
    cm = rx.sub(NEWELSE, cm, count=1)
    print("OK:   controllermanager - MENU clears force-controller")
for txt, name in ((im, "inputmanagerimp.cpp"), (cm, "controllermanager.cpp")):
    for o, c in (("{", "}"), ("(", ")")):
        if txt.count(o) != txt.count(c):
            print("FAIL: %s unbalanced %s%s" % (name, o, c)); sys.exit(1)
if im.count('std::fopen("/tmp/openmw-tsp-force-controller", "w")') != 1: print("FAIL: writer count"); sys.exit(1)
if cm.count('std::remove("/tmp/openmw-tsp-force-controller")') != 1: print("FAIL: clear count"); sys.exit(1)
if cm.count("TSP_NO_STICKCLICK_MODES_051_V54 menu=mouse-to-controller") != 1: print("FAIL: MOUSE->CONTROLLER damaged"); sys.exit(1)
if cm.count("TSP_TEXT_HANDOFF_051_V51 menu=tap action=helper-owned") != 1: print("FAIL: helper-owned fallback lost"); sys.exit(1)
if cm.count('std::fopen("/tmp/openmw-tsp-text-reset", "w")') != 1: print("FAIL: R3 force-text damaged"); sys.exit(1)
if im.count('std::fopen("/tmp/openmw-tsp-text-active", "w")') != 1: print("FAIL: engine cannot create text flag"); sys.exit(1)
if im.count("containsMode(MWGui::GM_Barter)") != 1 or im.count("containsMode(MWGui::GM_Container)") != 1: print("FAIL: scope"); sys.exit(1)
print("OK: balance, both MENU branches intact, R3 + text flag untouched")
if (im, cm) == orig:
    print("VERIFIED: v60 already present, nothing written."); sys.exit(0)
s = time.strftime("%Y%m%d-%H%M%S")
for p, t, o in ((IM, im, orig[0]), (CM, cm, orig[1])):
    if t != o:
        io.open("%s.before-v60-%s" % (p, s), "w", encoding="utf-8", newline="").write(o)
        io.open(p, "w", encoding="utf-8", newline="").write(t)
        print("wrote %s" % os.path.basename(p))
print("VERIFIED: v60 present")
