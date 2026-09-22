"""TSP_BARTER_CONTROLLER_DEFAULT_051_V61 -- same rule for the player's inventory.

V60 scoped the controller-default to GM_Barter/GM_Container. Using the mouse on a
stack in the PLAYER's inventory opens the same CountDialog, but the mode stack is
GM_Inventory, so the edge never fired and text came up automatically. The
occasional controller case is when a container/barter mode was still on the stack.

Adds GM_Inventory and GM_Companion (the same two-panel transfer window).
GM_Name, save, spellmaking and enchanting still get automatic text.
"""
import io, os, re, sys, time
SRC = os.environ.get("TSPSRC", "/root/openmw-0.51-tsp-src")
IM = os.path.join(SRC, "apps/openmw/mwinput/inputmanagerimp.cpp")
MARK = "TSP_BARTER_CONTROLLER_DEFAULT_051_V61"
im = io.open(IM, encoding="utf-8").read()
orig = im
if "TSP_BARTER_CONTROLLER_DEFAULT_051_V60" not in im:
    print("FAIL: V60 is not present. Apply V60 first."); sys.exit(1)
print("OK: precondition - V60 present")
if MARK in im:
    print("SKIP: already applied")
else:
    rx = re.compile(
        r'^(?P<i>[ \t]*)&& \(windowManager->containsMode\(MWGui::GM_Barter\)[ \t\r]*\n'
        r'[ \t]*\|\| windowManager->containsMode\(MWGui::GM_Container\)\);[ \t\r]*$', re.M)
    n = len(rx.findall(im))
    if n != 1:
        print("FAIL: V60 mode condition matched %d (need 1)" % n); sys.exit(1)
    NEW = (r'\g<i>// ' + MARK + r' -- the player inventory reaches the same'
           '\n' r'\g<i>// CountDialog through the mouse, but its mode stack is GM_Inventory,'
           '\n' r'\g<i>// so V60 never fired there. Companion is the same transfer window.'
           '\n' r'\g<i>&& (windowManager->containsMode(MWGui::GM_Barter)'
           '\n' r'\g<i>       || windowManager->containsMode(MWGui::GM_Container)'
           '\n' r'\g<i>       || windowManager->containsMode(MWGui::GM_Inventory)'
           '\n' r'\g<i>       || windowManager->containsMode(MWGui::GM_Companion));')
    im = rx.sub(NEW, im, count=1)
    print("OK:   inventory + companion added to the controller-default scope")
for o, c in (("{", "}"), ("(", ")")):
    if im.count(o) != im.count(c):
        print("FAIL: unbalanced %s%s" % (o, c)); sys.exit(1)
for m in ("GM_Barter", "GM_Container", "GM_Inventory", "GM_Companion"):
    if im.count("containsMode(MWGui::%s)" % m) != 1:
        print("FAIL: %s count wrong" % m); sys.exit(1)
if "containsMode(MWGui::GM_Name)" in im:
    print("FAIL: name creation must NOT be in scope"); sys.exit(1)
if im.count('std::fopen("/tmp/openmw-tsp-force-controller", "w")') != 1:
    print("FAIL: writer count"); sys.exit(1)
if im.count('std::fopen("/tmp/openmw-tsp-text-active", "w")') != 1:
    print("FAIL: engine cannot create text flag"); sys.exit(1)
print("OK: balance, four modes in scope, name creation excluded, text flag intact")
if im == orig:
    print("VERIFIED: v61 already present, nothing written."); sys.exit(0)
s = time.strftime("%Y%m%d-%H%M%S")
io.open("%s.before-v61-%s" % (IM, s), "w", encoding="utf-8", newline="").write(orig)
io.open(IM, "w", encoding="utf-8", newline="").write(im)
print("wrote inputmanagerimp.cpp")
print("VERIFIED: v61 present")
