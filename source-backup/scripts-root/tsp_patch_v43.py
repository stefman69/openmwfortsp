import sys, io, os, time

SRC = os.environ.get("TSPSRC", "/root/openmw-0.51-tsp-src")
CM  = os.path.join(SRC, "apps/openmw/mwinput/controllermanager.cpp")

MARK = "TSP_CHORD_051_V43"
EDITS = []

EDITS.append((CM, "release: move the controlsDisabled guard below MENU", """        if (!Settings::input().mEnableController || MWBase::Environment::get().getInputManager()->controlsDisabled())
            return;

        mJoystickLastUsed = true;

        // TSP_CHORD_051_V42 -- MENU acts here, not on press.""",
"""        // TSP_CHORD_051_V43 -- the controlsDisabled() guard moved BELOW the MENU
        // handling. During a save load it is true, and the old ordering swallowed
        // MENU's release, leaving the chord layer armed: every button then became a
        // chord and nothing worked until MENU was tapped again. buttonPressed has no
        // such guard, so press and release were not symmetric.
        mJoystickLastUsed = true;

        // TSP_CHORD_051_V42 -- MENU acts here, not on press."""))

EDITS.append((CM, "release: reinstate the guard after MENU handling", """        // TSP_CHORD_051_V42 -- swallow the release of a chorded button too, or the
        // bindings manager sees a release for a press it never got.
        if (mTspMenuHeld)
            return;""",
"""        // TSP_CHORD_051_V42 -- swallow the release of a chorded button too, or the
        // bindings manager sees a release for a press it never got.
        if (mTspMenuHeld)
            return;

        // TSP_CHORD_051_V43 -- guard reinstated here, after MENU has been handled.
        if (!Settings::input().mEnableController || MWBase::Environment::get().getInputManager()->controlsDisabled())
            return;"""))

EDITS.append((CM, "update: never stay armed", """        // TSP_CHORD_051_V42 -- right stick / triggers while MENU is held.
        tspUpdateChordAxes();""",
"""        // TSP_CHORD_051_V43 -- belt and braces for the above: if we think MENU is
        // held but SDL says the physical button is up, we missed a release. Mark it
        // chord-consumed so a late release cannot also toggle the mouse.
        if (mTspMenuHeld && !isButtonPressed(SDL_CONTROLLER_BUTTON_GUIDE))
        {
            Log(Debug::Warning) << "TSP_CHORD_051_V43 menu=stuck-armed action=cleared";
            mTspMenuHeld = false;
            mTspChordConsumed = true;
            mTspChordStickDir = 0;
            mTspChordLtLatched = false;
            mTspChordRtLatched = false;
        }

        // TSP_CHORD_051_V42 -- right stick / triggers while MENU is held.
        tspUpdateChordAxes();"""))

EDITS.append((CM, "chord: R3 = quick slot 9", """            case SDL_CONTROLLER_BUTTON_LEFTSHOULDER:
                tspFireChordAction(A_Screenshot, "screenshot-LB");
                return;""",
"""            case SDL_CONTROLLER_BUTTON_LEFTSHOULDER:
                tspFireChordAction(A_Screenshot, "screenshot-LB");
                return;
            // TSP_CHORD_051_V43 -- OpenMW has ten quick keys; R3 takes slot 9.
            // Slot 10 has no home while L3 is reserved for the mouse.
            case SDL_CONTROLLER_BUTTON_RIGHTSTICK:
                tspFireChordAction(A_QuickKey9, "quickslot9-R3");
                return;"""))

def balanced(text, label):
    for o, c in {'{': '}', '(': ')'}.items():
        if text.count(o) != text.count(c):
            print("FAIL: imbalance after %s: %s=%d %s=%d" % (label, o, text.count(o), c, text.count(c)))
            return False
    return True

if not os.path.exists(CM):
    print("FAIL: missing %s" % CM); sys.exit(1)
with io.open(CM, encoding="utf-8") as fh:
    original = fh.read()

text = original
applied = skipped = 0
for path, label, old, new in EDITS:
    if new in text:
        print("SKIP (already applied): %s" % label); skipped += 1; continue
    n = text.count(old)
    if n != 1:
        print("FAIL: anchor for '%s' matched %d times (need exactly 1)" % (label, n))
        print("      (v43 patches ON TOP of v42)")
        sys.exit(1)
    text = text.replace(old, new, 1)
    print("OK: %s" % label); applied += 1

if not balanced(text, "controllermanager.cpp"):
    sys.exit(1)

# The guard must end up exactly once, and below the MENU handler.
if text.count("controlsDisabled())\n            return;") != 1:
    print("FAIL: controlsDisabled guard is not present exactly once in buttonReleased"); sys.exit(1)
gi = text.find("TSP_CHORD_051_V43 -- guard reinstated here")
mi = text.find("TSP_CHORD_051_V42 -- MENU acts here, not on press.")
if gi < 0 or mi < 0 or gi < mi:
    print("FAIL: guard did not end up below the MENU release handler"); sys.exit(1)

if applied == 0:
    print("Nothing to do - all %d edits already present." % skipped)
else:
    bak = "%s.before-v43-%s" % (CM, time.strftime("%Y%m%d-%H%M%S"))
    with io.open(bak, "w", encoding="utf-8", newline="") as fh:
        fh.write(original)
    with io.open(CM, "w", encoding="utf-8", newline="") as fh:
        fh.write(text)
    print("wrote %s (backup: %s)" % (CM, os.path.basename(bak)))

with io.open(CM, encoding="utf-8") as fh:
    if MARK not in fh.read():
        print("FAIL: marker missing after write"); sys.exit(1)
print("VERIFIED: v43 present, guard below MENU (%d applied, %d already present)" % (applied, skipped))
