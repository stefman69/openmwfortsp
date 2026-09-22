"""TSP_DIALOGUE_TOPIC_SCROLL_051_V62 -- topics list scrolls by real geometry.

setControllerFocus scrolled with a hand-rolled sum that assumed (a) the first six
entries always fit on screen (for i = 6), (b) every item carries sVerticalPadding
-- the service topics at dialogue.cpp:622-646 are added with 0 -- and (c) the
focused item can always be placed at the very top, with no clamp against canvas or
viewport. A topic wrapping to two lines breaks all three.

MWList::ensureItemVisible (list.cpp:190, TSP_JOURNAL_SCROLL_V3) already solves
this with real widget geometry, clamped to [0, canvas - viewport]. Call-site fix;
list.cpp untouched, so the journal keeps its tested behaviour.
"""
import io, os, re, sys, time
SRC = os.environ.get("TSPSRC", "/root/openmw-0.51-tsp-src")
DLG = os.environ.get("TSPDLG", os.path.join(SRC, "apps/openmw/mwgui/dialogue.cpp"))
MARK = "TSP_DIALOGUE_TOPIC_SCROLL_051_V62"
t = io.open(DLG, encoding="utf-8").read()
orig = t
if "ensureItemVisible" not in io.open(
        os.environ.get("TSPLIST", os.path.join(SRC, "components/widgets/list.hpp")),
        encoding="utf-8").read():
    print("FAIL: MWList::ensureItemVisible not declared in list.hpp"); sys.exit(1)
print("OK: precondition - MWList::ensureItemVisible exists (TSP_JOURNAL_SCROLL_V3)")
if MARK in t:
    print("SKIP: already applied")
else:
    rx = re.compile(
        r'^(?P<i>[ \t]*)if \(focused\)[ \t\r]*\n'
        r'[ \t]*\{[ \t\r]*\n'
        r'[ \t]*// Scroll the side bar to keep the active item in view[ \t\r]*\n'
        r'[ \t]*int offset = 0;[ \t\r]*\n'
        r'[ \t]*for \(int i = 6; i < static_cast<int>\(index\); i\+\+\)[ \t\r]*\n'
        r'(?:.*?\n)*?'
        r'[ \t]*mTopicsList->setViewOffset\(-offset\);[ \t\r]*\n'
        r'[ \t]*\}[ \t\r]*$', re.M)
    n = len(rx.findall(t))
    if n != 1:
        print("FAIL: setControllerFocus scroll block matched %d (need 1)" % n); sys.exit(1)
    NEW = (r'\g<i>if (focused)'
           '\n' r'\g<i>{'
           '\n' r'\g<i>    // ' + MARK + r' -- was a hand-rolled offset sum that started'
           '\n' r'\g<i>    // at i = 6 (assuming six entries always fit), added'
           '\n' r'\g<i>    // sVerticalPadding to service topics that were added with 0, and'
           '\n' r'\g<i>    // never clamped. Any topic wrapping to two lines pushed the'
           '\n' r'\g<i>    // highlight out of view. MWList::ensureItemVisible already does'
           '\n' r'\g<i>    // this from real widget geometry, clamped to the canvas.'
           '\n' r'\g<i>    if (index < mTopicsList->getItemCount())'
           '\n' r'\g<i>    {'
           '\n' r'\g<i>        const std::string& tspFocusKeyword = mTopicsList->getItemNameAt(index);'
           '\n' r'\g<i>        if (!tspFocusKeyword.empty())'
           '\n' r'\g<i>            mTopicsList->ensureItemVisible('
           '\n' r'\g<i>                mTopicsList->getItemWidget(tspFocusKeyword));'
           '\n' r'\g<i>    }'
           '\n' r'\g<i>}')
    t = rx.sub(NEW, t, count=1)
    print("OK:   topics list scrolls via ensureItemVisible")
for o, c in (("{", "}"), ("(", ")")):
    if t.count(o) != t.count(c):
        print("FAIL: unbalanced %s%s" % (o, c)); sys.exit(1)
if "for (int i = 6; i < static_cast<int>(index); i++)" in t: print("FAIL: i=6 loop survived"); sys.exit(1)
if "mTopicsList->setViewOffset(-offset)" in t: print("FAIL: unclamped setViewOffset survived"); sys.exit(1)
if t.count("mTopicsList->ensureItemVisible(") != 1: print("FAIL: ensureItemVisible count"); sys.exit(1)
if t.count("mGoodbyeButton->setStateSelected(focused);") != 1: print("FAIL: Goodbye branch damaged"); sys.exit(1)
if t.count("button->setStateSelected(focused);") != 1: print("FAIL: topic highlight damaged"); sys.exit(1)
if t.count("mTopicsList->scrollToTop()") != 1: print("FAIL: scrollToTop damaged"); sys.exit(1)
print("OK: i=6 loop gone, unclamped offset gone, both highlight branches intact")
if t == orig:
    print("VERIFIED: v62 already present, nothing written."); sys.exit(0)
s = time.strftime("%Y%m%d-%H%M%S")
io.open("%s.before-v62-%s" % (DLG, s), "w", encoding="utf-8", newline="").write(orig)
io.open(DLG, "w", encoding="utf-8", newline="").write(t)
print("wrote dialogue.cpp")
print("VERIFIED: v62 present")
