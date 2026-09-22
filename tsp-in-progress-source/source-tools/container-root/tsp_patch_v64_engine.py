"""TSP_TEXT_INJECT_051_V64 -- characters reach MyGUI without SDL text synthesis.

PROVEN 2026-09-14 on the base TSP (.21): the helper receives A
(RAW KEY name=A code=305 mode=1(TEXT) grabbed=1) and emits correctly -- reading
its own uinput node shows code=42 (LEFTSHIFT) + code=30 (KEY_A) per press -- and
no character appears. Engine, helper and launcher md5s are identical to the TSPS
where it works. So it is the OS: SDL only turns a keycode into a character via
the kernel console keymap it reads from a tty, and that is not present on every
TrimUI image. Unfixable from inside the game, and unknowable on a shipped port.

FIX: the helper appends the character to /tmp/openmw-tsp-text-inject; this drains
the queue every frame and injects straight into MyGUI. No keymap, no evdev
enumeration, no SDL text synthesis. Identical on both consoles.

The helper's uinput emission is deliberately LEFT IN PLACE (V49 lesson: do not
remove a working path while adding a new one). If characters ever double up on
the TSPS, that is the line to cut.
"""
import io, os, re, sys, time
SRC = os.environ.get("TSPSRC", "/root/openmw-0.51-tsp-src")
IM = os.environ.get("TSPIM", os.path.join(SRC, "apps/openmw/mwinput/inputmanagerimp.cpp"))
MARK = "TSP_TEXT_INJECT_051_V64"
t = io.open(IM, encoding="utf-8").read()
orig = t
if "MyGUI_Gui.h" not in t:
    print("FAIL: MyGUI is not in use in this file"); sys.exit(1)
print("OK: preconditions")
if MARK in t:
    print("SKIP: already applied")
else:
    if "MyGUI_KeyCode.h" not in t:
        a = "#include <MyGUI_Gui.h>"
        if t.count(a) != 1:
            print("FAIL: MyGUI_Gui.h include not unique"); sys.exit(1)
        t = t.replace(a, a + "\n#include <MyGUI_KeyCode.h>", 1)
        print("OK:   include MyGUI_KeyCode.h")
    rx = re.compile(
        r'^(?P<i>[ \t]*)const bool tspTextEntryActive = SDL_IsTextInputActive\(\) == SDL_TRUE;[ \t\r]*$',
        re.M)
    n = len(rx.findall(t))
    if n != 1:
        print("FAIL: tspTextEntryActive anchor matched %d (need 1)" % n); sys.exit(1)
    NEW = (r'\g<0>'
        '\n'
        '\n' r'\g<i>// ' + MARK + r' -- the helper hands us the chosen character in a'
        '\n' r'\g<i>// file instead of relying on its synthetic uinput keystroke being'
        '\n' r'\g<i>// translated by SDL. That translation needs the kernel console keymap'
        '\n' r'\g<i>// and is absent on some TrimUI OS images: the helper emits a correct'
        '\n' r'\g<i>// Shift+A and no character ever appears. Injecting into MyGUI here'
        '\n' r'\g<i>// removes the dependency on the host OS entirely.'
        '\n' r'\g<i>{'
        '\n' r'\g<i>    if (std::FILE* tspInjectFile'
        '\n' r'\g<i>        = std::fopen("/tmp/openmw-tsp-text-inject", "r"))'
        '\n' r'\g<i>    {'
        '\n' r'\g<i>        char tspInjectBuf[64] = {};'
        '\n' r'\g<i>        const std::size_t tspInjectCount'
        '\n' r'\g<i>            = std::fread(tspInjectBuf, 1, sizeof(tspInjectBuf) - 1, tspInjectFile);'
        '\n' r'\g<i>        std::fclose(tspInjectFile);'
        '\n' r'\g<i>        std::remove("/tmp/openmw-tsp-text-inject");'
        '\n' r'\g<i>        for (std::size_t tspI = 0; tspI < tspInjectCount; ++tspI)'
        '\n' r'\g<i>        {'
        '\n' r'\g<i>            const unsigned char tspCh'
        '\n' r'\g<i>                = static_cast<unsigned char>(tspInjectBuf[tspI]);'
        '\n' r'\g<i>            if (tspCh == 8)'
        '\n' r'\g<i>                windowManager->injectKeyPress(MyGUI::KeyCode::Backspace, 0, false);'
        '\n' r'\g<i>            else if (tspCh == 13 || tspCh == 10)'
        '\n' r'\g<i>                windowManager->injectKeyPress(MyGUI::KeyCode::Return, 0, false);'
        '\n' r'\g<i>            else if (tspCh >= 32 && tspCh < 127)'
        '\n' r'\g<i>                windowManager->injectKeyPress(MyGUI::KeyCode::None, tspCh, false);'
        '\n' r'\g<i>            else'
        '\n' r'\g<i>                continue;'
        '\n' r'\g<i>            std::fprintf(stderr, "' + MARK + r' injected=%u\\n", tspCh);'
        '\n' r'\g<i>        }'
        '\n' r'\g<i>        std::fflush(stderr);'
        '\n' r'\g<i>    }'
        '\n' r'\g<i>}')
    t = rx.sub(NEW, t, count=1)
    print("OK:   per-frame injection queue")
for o, c in (("{", "}"), ("(", ")")):
    if t.count(o) != t.count(c):
        print("FAIL: unbalanced %s%s" % (o, c)); sys.exit(1)
if t.count('std::fopen("/tmp/openmw-tsp-text-inject", "r")') != 1: print("FAIL: reader count"); sys.exit(1)
if t.count("injectKeyPress(MyGUI::KeyCode::None") != 1: print("FAIL: char inject missing"); sys.exit(1)
if t.count("injectKeyPress(MyGUI::KeyCode::Backspace") != 1: print("FAIL: backspace missing"); sys.exit(1)
if t.count("injectKeyPress(MyGUI::KeyCode::Return") != 1: print("FAIL: return missing"); sys.exit(1)
if t.count('std::fopen("/tmp/openmw-tsp-text-active", "w")') != 1: print("FAIL: text flag writer damaged"); sys.exit(1)
if t.count('std::fopen("/tmp/openmw-tsp-force-controller", "w")') != 1: print("FAIL: V60 writer damaged"); sys.exit(1)
if t.count("containsMode(MWGui::GM_Barter)") != 1: print("FAIL: V60/61 scope damaged"); sys.exit(1)
print("OK: balance, 3 inject kinds, V51/V60/V61 untouched")
if t == orig:
    print("VERIFIED: v64 already present, nothing written."); sys.exit(0)
s = time.strftime("%Y%m%d-%H%M%S")
io.open("%s.before-v64-%s" % (IM, s), "w", encoding="utf-8", newline="").write(orig)
io.open(IM, "w", encoding="utf-8", newline="").write(t)
print("wrote inputmanagerimp.cpp")
print("VERIFIED: v64 present")
