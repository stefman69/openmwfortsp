"""TSP_FONT_SIZES_051_V55 -- per-area font sizes, editable in settings.cfg.

Seven new [GUI] keys plus matching defaults. Anchors are regexes that capture
their own indentation, because six of these eight files have only ever been
grepped in this thread, never read. Every code hook is independent: one that
finds nothing is reported UNWIRED and skipped rather than aborting the rest.
Mandatory: the declaration/default pair (a declared key with no default is a
hard startup crash) and the two hooks Steve actually reported -- window titles
and item stack counts. Full rationale: claude/patch-ledger.md.
"""

import io
import os
import re
import sys
import time

SRC = os.environ.get("TSPSRC", "/root/openmw-0.51-tsp-src")


def P(rel):
    return os.environ.get("TSP_" + os.path.basename(rel).replace(".", "_"),
                          os.path.join(SRC, rel))


GUI = P("components/settings/categories/gui.hpp")
DEF = P("files/settings-default.cfg")
WB = P("apps/openmw/mwgui/windowbase.cpp")
IW = P("apps/openmw/mwgui/itemwidget.cpp")
SW = P("apps/openmw/mwgui/statswindow.cpp")
SET = P("apps/openmw/mwgui/settingswindow.cpp")
TT = P("apps/openmw/mwgui/tooltips.cpp")
LS = P("apps/openmw/mwgui/loadingscreen.cpp")

MARK = "TSP_FONT_SIZES_051_V55"

SOURCES = (WB, IW, SW, SET, TT, LS)
ALL_FILES = (GUI, DEF) + SOURCES

# key -> (setting member, default, human label)
KEYS = [
    ("window title font size", "mTspTitleFontSize", 18, "window captions"),
    ("item count font size", "mTspItemCountFontSize", 14, "item stack counts"),
    ("stats font size", "mTspStatsFontSize", 23, "stats name/value rows"),
    ("skill list font size", "mTspSkillListFontSize", 23, "skill list"),
    ("controls font size", "mTspControlsFontSize", 18, "key-binding list"),
    ("tooltip charge font size", "mTspTooltipChargeFontSize", 14, "tooltip charges"),
    ("loading font size", "mTspLoadingFontSize", 14, "loading screen"),
]

# ---------------------------------------------------------------- load ------

for path in ALL_FILES:
    if not os.path.exists(path):
        print("FAIL: missing %s" % path)
        sys.exit(1)

files = {}
for path in ALL_FILES:
    with io.open(path, encoding="utf-8") as fh:
        files[path] = fh.read()
pending = dict(files)

# Every .cpp this touches must already be able to see Settings::gui(), or the
# edit needs an include and this patcher will not guess at one.
for path in SOURCES:
    if "settings/values.hpp" not in files[path]:
        print("FAIL: %s does not include components/settings/values.hpp."
              % os.path.basename(path))
        print("      This patcher does not add includes blind. Nothing written.")
        sys.exit(1)
print("OK: precondition - all six sources already include settings/values.hpp")

if "makeClampSanitizerInt(12, 32)" not in files[GUI]:
    print("FAIL: gui.hpp does not carry TSP_LARGE_FONT_RANGE_051_V35_2 (12,32).")
    print("      Refusing to patch a gui.hpp whose shape does not match.")
    sys.exit(1)
print("OK: precondition - gui.hpp is the TSP-widened one")

wired = {}          # key -> number of call sites converted
notes = []


def sub_once(path, pattern, repl, label, flags=re.M):
    """Exactly-one-match replacement. Returns True if it landed."""
    rx = re.compile(pattern, flags)
    hits = rx.findall(pending[path])
    if len(hits) != 1:
        print("MISS: %-34s (%d matches, need 1) in %s"
              % (label, len(hits), os.path.basename(path)))
        notes.append((label, os.path.basename(path), len(hits)))
        return False
    pending[path] = rx.sub(repl, pending[path], count=1)
    print("OK:   %-34s in %s" % (label, os.path.basename(path)))
    return True


def sub_all(path, pattern, repl, label, flags=re.M):
    """Replace every match. Returns how many landed."""
    rx = re.compile(pattern, flags)
    n = len(rx.findall(pending[path]))
    if n == 0:
        print("MISS: %-34s (0 matches) in %s" % (label, os.path.basename(path)))
        notes.append((label, os.path.basename(path), 0))
        return 0
    pending[path] = rx.sub(repl, pending[path])
    print("OK:   %-34s x%d in %s" % (label, n, os.path.basename(path)))
    return n


# ---- 1. declare the settings (MANDATORY) -----------------------------------

DECL = "".join(
    '        SettingValue<int> %s{ mIndex, "GUI", "%s",\n'
    '            makeClampSanitizerInt(8, 40) };\n' % (member, key)
    for key, member, _default, _human in KEYS).rstrip("\n")

GUI_ANCHOR = (r'^(?P<i>[ \t]*)SettingValue<int> mFontSize\{ mIndex, "GUI", '
              r'"font size", makeClampSanitizerInt\(12, 32\) \};$')

if MARK in pending[GUI]:
    print("SKIP: gui.hpp declarations already present")
else:
    block = (
        r'\g<0>\n'
        '        // ' + MARK + ' -- per-area overrides. Every one of these MUST\n'
        '        // also exist in files/settings-default.cfg or OpenMW throws at\n'
        '        // startup (settings.cpp:200). The 8..40 range is deliberately\n'
        '        // wider than the global 12..32 so small UI furniture can go below\n'
        '        // the body-text minimum.\n' + DECL)
    if not sub_once(GUI, GUI_ANCHOR, block, "gui.hpp: seven font keys"):
        print("      The declaration block is mandatory. Nothing written.")
        sys.exit(1)

# ---- 2. defaults (MANDATORY, moves with the declarations) ------------------

DEFAULTS = "\n".join([
    "",
    "# " + MARK + " -- per-area font sizes.",
    "# These override the global \"font size\" for specific pieces of UI.",
    "",
    "# Caption bar at the top of windows (settings, inventory, map, spells, stats).",
    "# The caption bar itself is only 20px tall, so large values will clip.",
    "window title font size = 18",
    "",
    "# The stack count drawn on item icons.",
    "item count font size = 14",
    "",
    "# Attribute and stat rows in the stats window.",
    "stats font size = 23",
    "",
    "# The skill list in the stats window.",
    "skill list font size = 23",
    "",
    "# The key-binding list on the Controls page.",
    "controls font size = 18",
    "",
    "# \"Charges\" text on enchanted-item tooltips.",
    "tooltip charge font size = 14",
    "",
    "# Text on the loading screen.",
    "loading font size = 14",
])

if MARK in pending[DEF]:
    print("SKIP: settings-default.cfg already carries the defaults")
else:
    # [ \t]*$ not \s*$ -- \s matches newlines, so \s*$ swallows the blank line
    # after the key and the block lands glued to the next comment.
    if not sub_once(DEF, r'^font size[ \t]*=[ \t]*\d+[ \t]*$',
                    lambda m: m.group(0).rstrip() + "\n" + DEFAULTS,
                    "settings-default.cfg: defaults"):
        print("      Defaults are mandatory -- a declared key with no default is")
        print("      a hard startup crash. Nothing written.")
        sys.exit(1)

# ---- 3. window titles (MANDATORY -- this is a reported complaint) ----------

CAPTION = (
    r'\g<i>// ' + MARK + r' -- the caption on every window that has one, in a\n'
    r'\g<i>// single place. Same getSkinWidgetsByName call the "Action" lookup\n'
    r'\g<i>// below already uses; "Caption" is the name the skin gives it\n'
    r'\g<i>// (openmw_windows.skin.xml:581 and :852). setProperty rather than a\n'
    r'\g<i>// cast to TextBox so no new include is needed -- MyGUI logs a warning\n'
    r'\g<i>// instead of throwing if a widget cannot take the property.\n'
    r'\g<i>for (MyGUI::Widget* tspCaption : window->getSkinWidgetsByName("Caption"))\n'
    r'\g<i>    tspCaption->setProperty(\n'
    r'\g<i>        "FontHeight", std::to_string(static_cast<int>(Settings::gui().mTspTitleFontSize)));\n'
    r'\n'
    r'\g<0>')

if MARK in pending[WB]:
    print("SKIP: windowbase.cpp caption hook already present")
    wired["window title font size"] = 1
elif sub_once(WB,
              r'^(?P<i>[ \t]*)MyGUI::VectorWidgetPtr widgets '
              r'= window->getSkinWidgetsByName\("Action"\);$',
              CAPTION, "windowbase.cpp: caption font"):
    wired["window title font size"] = 1

# ---- 4. item stack counts (MANDATORY -- reported complaint) ---------------

# Anchored on the guarded early return, NOT on the setCaption call. In stock
# 0.51 that call can be the body of an unbraced `else`, and inserting a statement
# in front of it would silently move setCaption out of the else. Appending after
# a `return;` inside braces is safe in every shape the function can take.
COUNTHOOK = (
    r'\g<0>\n'
    r'\g<i>// ' + MARK + r' -- this never set a height at all, so stack counts\n'
    r'\g<i>// inherited the global font size (28 on this device).\n'
    r'\g<i>mText->setProperty(\n'
    r'\g<i>    "FontHeight", std::to_string(static_cast<int>(Settings::gui().mTspItemCountFontSize)));')

if MARK in pending[IW]:
    print("SKIP: itemwidget.cpp count hook already present")
    wired["item count font size"] = 1
else:
    GUARDS = [r'^(?P<i>[ \t]*)if \(!mText\)\n[ \t]*return;$',
              r'^(?P<i>[ \t]*)if \(mText == nullptr\)\n[ \t]*return;$']
    live = [g for g in GUARDS if re.search(g, pending[IW], re.M)]
    if len(live) == 1 and sub_once(IW, live[0], COUNTHOOK,
                                   "itemwidget.cpp: stack count font"):
        wired["item count font size"] = 1
    elif len(live) != 1:
        print("MISS: %-34s (no unique `if (!mText) return;` guard) in itemwidget.cpp"
              % "itemwidget.cpp: stack count font")
        notes.append(("itemwidget.cpp: stack count font", "itemwidget.cpp", len(live)))

for mandatory in ("window title font size", "item count font size"):
    if mandatory not in wired:
        print()
        print("FAIL: '%s' is the hook Steve actually asked for and it did not" % mandatory)
        print("      land. Not shipping a rebuild that fixes neither complaint.")
        print("      Nothing written. The grep dump above shows the real text.")
        sys.exit(1)

# ---- 5. stats rows --------------------------------------------------------
# An earlier TSP patch may have hoisted these into a constant. Handle both
# shapes without caring which, and without caring what scope the constant is in:
# delete the declaration, then rewrite every remaining use of the identifier.

statsn = 0
if "mTspSkillListFontSize" in pending[SW] or "mTspStatsFontSize" in pending[SW]:
    print("SKIP: statswindow.cpp already patched")
    wired["stats font size"] = 1
    wired["skill list font size"] = 1
else:
    if re.search(r'^[ \t]*constexpr int tspStatsFontHeight\s*=\s*\d+;\s*$',
                 pending[SW], re.M):
        sub_once(SW, r'^[ \t]*constexpr int tspStatsFontHeight\s*=\s*\d+;[ \t]*\n',
                 "", "statswindow.cpp: drop the stats constant")
        statsn = sub_all(SW, r'\btspStatsFontHeight\b',
                         "Settings::gui().mTspStatsFontSize",
                         "statswindow.cpp: stats rows", flags=0)
        if statsn:
            wired["stats font size"] = statsn
    else:
        print("NOTE: no tspStatsFontHeight constant -- stats rows are literal 23s")
        print("      and will follow 'skill list font size' instead.")

    # Everything still saying 23 in this file is the skill list.
    skilln = sub_all(SW, r'setFontHeight\(23\)',
                     "setFontHeight(Settings::gui().mTspSkillListFontSize)",
                     "statswindow.cpp: skill list", flags=0)
    if skilln:
        wired["skill list font size"] = skilln
    if statsn == 0 and skilln:
        wired["stats font size"] = 0  # declared, inert, covered by skill list

# ---- 6. controls list ------------------------------------------------------

if "mTspControlsFontSize" in pending[SET]:
    print("SKIP: settingswindow.cpp already patched")
    wired["controls font size"] = 1
else:
    n = sub_all(SET, r'setFontHeight\(18\)',
                "setFontHeight(Settings::gui().mTspControlsFontSize)",
                "settingswindow.cpp: controls list", flags=0)
    if n:
        wired["controls font size"] = n

# ---- 7. tooltip charge + loading screen ------------------------------------

if "mTspTooltipChargeFontSize" in pending[TT]:
    print("SKIP: tooltips.cpp already patched")
    wired["tooltip charge font size"] = 1
else:
    n = sub_all(TT, r'setFontHeight\(14\)',
                "setFontHeight(Settings::gui().mTspTooltipChargeFontSize)",
                "tooltips.cpp: charge text", flags=0)
    if n:
        wired["tooltip charge font size"] = n

if "mTspLoadingFontSize" in pending[LS]:
    print("SKIP: loadingscreen.cpp already patched")
    wired["loading font size"] = 1
else:
    n = sub_all(LS, r'setFontHeight\(14\)',
                "setFontHeight(Settings::gui().mTspLoadingFontSize)",
                "loadingscreen.cpp: loading text", flags=0)
    if n:
        wired["loading font size"] = n

# ------------------------------------------------------------- verify ------

print()


def balanced(text, label):
    for open_ch, close_ch in (("{", "}"), ("(", ")")):
        if text.count(open_ch) != text.count(close_ch):
            print("FAIL: brace/paren imbalance in %s: %s=%d %s=%d"
                  % (label, open_ch, text.count(open_ch), close_ch, text.count(close_ch)))
            return False
    return True


for path in SOURCES + (GUI,):
    if not balanced(pending[path], os.path.basename(path)):
        print("      Nothing written.")
        sys.exit(1)
print("OK: brace and paren balance unchanged in every touched source")

# The assertion that matters most: declarations and defaults must agree, or
# OpenMW throws at startup instead of misbehaving visibly.
for key, member, default, _human in KEYS:
    if ('"GUI", "%s"' % key) not in pending[GUI]:
        print("FAIL: '%s' is not declared in gui.hpp" % key)
        sys.exit(1)
    if not re.search(r'^%s\s*=\s*\d+\s*$' % re.escape(key), pending[DEF], re.M):
        print("FAIL: '%s' is declared but has NO DEFAULT." % key)
        print("      OpenMW would throw at startup. Nothing written.")
        sys.exit(1)
print("OK: all %d keys are both declared and defaulted" % len(KEYS))

# The global font size must survive untouched -- it is what every unhooked
# widget still follows.
if 'SettingValue<int> mFontSize{ mIndex, "GUI", "font size"' not in pending[GUI]:
    print("FAIL: the global font size setting was damaged")
    sys.exit(1)
if not re.search(r'^font size\s*=\s*\d+\s*$', pending[DEF], re.M):
    print("FAIL: the global font size default was damaged")
    sys.exit(1)
print("OK: the global 'font size' setting and default are intact")

# ------------------------------------------------------------- write -------

changed = [p for p in ALL_FILES if pending[p] != files[p]]
if not changed:
    print("VERIFIED: v55 already present, nothing written.")
    sys.exit(0)

stamp = time.strftime("%Y%m%d-%H%M%S")
for path in changed:
    backup = "%s.before-v55-%s" % (path, stamp)
    with io.open(backup, "w", encoding="utf-8", newline="") as fh:
        fh.write(files[path])
    with io.open(path, "w", encoding="utf-8", newline="") as fh:
        fh.write(pending[path])
    print("wrote %s (backup: %s)" % (path, os.path.basename(backup)))

for path in (GUI, DEF):
    with io.open(path, encoding="utf-8") as fh:
        if MARK not in fh.read():
            print("FAIL: marker missing from %s" % os.path.basename(path))
            sys.exit(1)

print()
print("=== settings.cfg keys, under [GUI] ===")
for key, member, default, human in KEYS:
    n = wired.get(key, None)
    if n is None:
        state = "UNWIRED (declared, nothing reads it yet)"
    elif n == 0:
        state = "covered by 'skill list font size'"
    else:
        state = "LIVE  %d call site(s)" % n
    print("  %-26s = %-3d  %-22s %s" % (key, default, human, state))

if notes:
    print()
    print("=== anchors that did not land ===")
    for label, base, n in notes:
        print("  %-40s %-24s %d matches" % (label, base, n))
    print("  These keys parse and clamp but change nothing. Send this block back")
    print("  with the grep dump above and they can be wired in the next pass.")

print()
print("VERIFIED: v55 present")
