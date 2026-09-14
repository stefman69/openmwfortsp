import sys, io, os, time

SRC = os.environ.get("TSPHELPER", "/root/tsp_openmw_controls.c")
MARK = "TSP_TEXT_REMAP_051_V43"
EDITS = []

EDITS.append(("clear the pointing flag when text entry ends", """    if (!active) {
        suppress_auto_text = false;
        if (mode != MODE_GAME)
            set_mode(MODE_GAME);
        return;
    }""",
"""    if (!active) {
        /*
         * TSP_TEXT_REMAP_051_V43
         *
         * V40 bug: the pointing flag was cleared on cancel, on reclaim, at startup
         * and at shutdown -- but NOT when text entry simply ended. Closing a menu
         * while in POINTING mode orphaned the file for the rest of the session, and
         * OpenMW kept forcing mouse mode back on in every menu afterwards.
         */
        unlink(MOUSE_MODE_FLAG);
        suppress_auto_text = false;
        if (mode != MODE_GAME)
            set_mode(MODE_GAME);
        return;
    }"""))

def balanced(text, label):
    for o, c in {'{': '}', '(': ')'}.items():
        if text.count(o) != text.count(c):
            print("FAIL: imbalance after %s: %s=%d %s=%d" % (label, o, text.count(o), c, text.count(c)))
            return False
    return True

if not os.path.exists(SRC):
    print("FAIL: missing %s" % SRC); sys.exit(1)
with io.open(SRC, encoding="utf-8") as fh:
    original = fh.read()

text = original
applied = skipped = 0
for label, old, new in EDITS:
    if new in text:
        print("SKIP (already applied): %s" % label); skipped += 1; continue
    n = text.count(old)
    if n != 1:
        print("FAIL: anchor for '%s' matched %d times (need exactly 1)" % (label, n)); sys.exit(1)
    text = text.replace(old, new, 1)
    print("OK: %s" % label); applied += 1

if not balanced(text, os.path.basename(SRC)):
    sys.exit(1)

if applied == 0:
    print("Nothing to do - all %d edits already present." % skipped)
else:
    bak = "%s.before-v43-%s" % (SRC, time.strftime("%Y%m%d-%H%M%S"))
    with io.open(bak, "w", encoding="utf-8", newline="") as fh:
        fh.write(original)
    with io.open(SRC, "w", encoding="utf-8", newline="") as fh:
        fh.write(text)
    print("wrote %s (backup: %s)" % (SRC, os.path.basename(bak)))

with io.open(SRC, encoding="utf-8") as fh:
    body = fh.read()
if MARK not in body:
    print("FAIL: marker missing after write"); sys.exit(1)
if body.count("unlink(MOUSE_MODE_FLAG)") < 4:
    print("FAIL: expected the pointing flag to be cleared in at least 4 places, found %d"
          % body.count("unlink(MOUSE_MODE_FLAG)"))
    sys.exit(1)
print("VERIFIED: helper v43 present, pointing flag cleared in %d places (%d applied, %d present)"
      % (body.count("unlink(MOUSE_MODE_FLAG)"), applied, skipped))
