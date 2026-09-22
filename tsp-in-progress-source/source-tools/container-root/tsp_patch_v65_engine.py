"""TSP_MENU_TAP_RACE_051_V65 -- MENU's bare tap stops being eaten by its own watchdog.

From the .21 engine log, EVERY MENU press produced:
    TSP_CHORD_051_V43 menu=stuck-armed action=cleared
    TSP_CHORD_051_V42 menu=release action=chord-consumed
V43's watchdog fires when mTspMenuHeld is set but SDL reports GUIDE up -- which
is true for the update() between the press event and the release event. It then
asserted chord-consumed, so the real release saw tspWasChord and returned before
the bare-tap branch. That branch is what clears force-controller, which is why
MENU could not summon text in barter/inventory except by mashing.

Require several CONSECUTIVE up frames (a genuinely missed release stays up, a tap
does not) and do not claim a chord that never fired -- a real chord already sets
mTspChordConsumed in tspFireChordAction/tspFireChordButton.

Local static rather than a new member: one translation unit, no header edit.
"""
import io, os, re, sys, time
SRC = os.environ.get("TSPSRC", "/root/openmw-0.51-tsp-src")
CM = os.environ.get("TSPCM", os.path.join(SRC, "apps/openmw/mwinput/controllermanager.cpp"))
MARK = "TSP_MENU_TAP_RACE_051_V65"
t = io.open(CM, encoding="utf-8").read()
orig = t
if "menu=stuck-armed" not in t:
    print("FAIL: the V43 watchdog is not in this file"); sys.exit(1)
print("OK: preconditions - V43 watchdog present")
if MARK in t:
    print("SKIP: already applied")
else:
    rx = re.compile(
        r'^(?P<i>[ \t]*)// TSP_CHORD_051_V43 -- belt and braces: if we think MENU is held but SDL[ \t\r]*\n'
        r'(?:.*?\n)*?'
        r'[ \t]*mTspChordRtLatched = false;[ \t\r]*\n'
        r'[ \t]*\}[ \t\r]*$', re.M)
    n = len(rx.findall(t))
    if n != 1:
        print("FAIL: watchdog block matched %d (need 1)" % n); sys.exit(1)
    NEW = (
        r'\g<i>// TSP_CHORD_051_V43 -- belt and braces: if we think MENU is held but SDL'
        '\n' r'\g<i>// says the physical button is up, we missed a release.'
        '\n' r'\g<i>//'
        '\n' r'\g<i>// ' + MARK + r' -- this used to fire on ORDINARY TAPS. SDL'
        '\n' r'\g<i>// button state can already read up in the update() that runs between the'
        '\n' r'\g<i>// press event and the release event, so a tap tripped the watchdog, which'
        '\n' r'\g<i>// asserted chord-consumed, and the real release then returned early without'
        '\n' r'\g<i>// running the bare-tap branch. Every MENU press in the .21 log shows the'
        '\n' r'\g<i>// pair "stuck-armed" then "release action=chord-consumed". That'
        '\n' r'\g<i>// is why MENU could not summon text in barter/inventory except by mashing.'
        '\n' r'\g<i>//'
        '\n' r'\g<i>// Require several CONSECUTIVE up frames -- a genuinely missed release'
        '\n' r'\g<i>// stays up, a tap does not -- and do not claim a chord that never fired;'
        '\n' r'\g<i>// a real chord already sets mTspChordConsumed itself.'
        '\n' r'\g<i>static int tspMenuUpFrames = 0;'
        '\n' r'\g<i>if (mTspMenuHeld && !isButtonPressed(SDL_CONTROLLER_BUTTON_GUIDE))'
        '\n' r'\g<i>    ++tspMenuUpFrames;'
        '\n' r'\g<i>else'
        '\n' r'\g<i>    tspMenuUpFrames = 0;'
        '\n' r'\g<i>if (mTspMenuHeld && tspMenuUpFrames >= 10)'
        '\n' r'\g<i>{'
        '\n' r'\g<i>    Log(Debug::Warning) << "TSP_CHORD_051_V43 menu=stuck-armed action=cleared"'
        '\n' r'\g<i>                        << " frames=" << tspMenuUpFrames;'
        '\n' r'\g<i>    mTspMenuHeld = false;'
        '\n' r'\g<i>    mTspChordStickDir = 0;'
        '\n' r'\g<i>    mTspChordLtLatched = false;'
        '\n' r'\g<i>    mTspChordRtLatched = false;'
        '\n' r'\g<i>    tspMenuUpFrames = 0;'
        '\n' r'\g<i>}')
    t = rx.sub(NEW, t, count=1)
    print("OK:   watchdog needs 10 consecutive up frames, no invented chord")
for o, c in (("{", "}"), ("(", ")")):
    if t.count(o) != t.count(c):
        print("FAIL: unbalanced %s%s (%d/%d)" % (o, c, t.count(o), t.count(c))); sys.exit(1)
if t.count("tspMenuUpFrames") != 6: print("FAIL: expected 6 tspMenuUpFrames refs, got %d" % t.count("tspMenuUpFrames")); sys.exit(1)
if t.count('<< "TSP_CHORD_051_V43 menu=stuck-armed action=cleared"') != 1: print("FAIL: watchdog log count"); sys.exit(1)
if t.count("mTspChordConsumed = true;") != 4:
    print("FAIL: expected 4 real chord-consumed sites, got %d" % t.count("mTspChordConsumed = true;")); sys.exit(1)
if t.count("const bool tspWasChord = mTspChordConsumed;") != 1: print("FAIL: release branch damaged"); sys.exit(1)
if t.count("TSP_BARTER_CONTROLLER_DEFAULT_051_V60") < 1: print("FAIL: V60 MENU handling damaged"); sys.exit(1)
print("OK: balance, 4 genuine chord sites remain, V60 intact")
if t == orig:
    print("VERIFIED: v65 already present, nothing written."); sys.exit(0)
s = time.strftime("%Y%m%d-%H%M%S")
io.open("%s.before-v65-%s" % (CM, s), "w", encoding="utf-8", newline="").write(orig)
io.open(CM, "w", encoding="utf-8", newline="").write(t)
print("wrote controllermanager.cpp")
print("VERIFIED: v65 present")
