"""TSP_TEXT_INJECT_V64 (helper) -- publish typed characters to a file queue.

Keeps the uinput keystroke (harmless where SDL translates it) and ADDITIONALLY
appends the character to /tmp/openmw-tsp-text-inject for the engine to inject.
Character typing is MANDATORY. Backspace and Enter are independent optional
hooks: if their anchors miss they report UNWIRED and the character fix ships.
"""
import io, os, re, sys, time
C = os.environ.get("TSPHELPER", "/root/tsp_openmw_controls.c")
MARK = "TSP_TEXT_INJECT_V64"
t = io.open(C, encoding="utf-8").read()
orig = t
for need in ('#define TEXT_CHAR_TMP', 'publish_selected_character', 'KEY_TSP_A'):
    if need not in t:
        print("FAIL: %s missing from the helper source" % need); sys.exit(1)
print("OK: preconditions")
notes = []
if MARK in t:
    print("SKIP: already applied")
else:
    rx = re.compile(r'^#define TEXT_CHAR_TMP[ \t]+"[^"]*"[ \t\r]*$', re.M)
    if len(rx.findall(t)) != 1:
        print("FAIL: TEXT_CHAR_TMP define not unique"); sys.exit(1)
    t = rx.sub(r'\g<0>' '\n'
               r'/* ' + MARK + r' -- queue of characters for the engine to inject. */'
               '\n' r'#define TEXT_INJECT_FILE "/tmp/openmw-tsp-text-inject"', t, count=1)
    print("OK:   TEXT_INJECT_FILE define")
    rx = re.compile(r'^static void publish_selected_character\(void\)[ \t\r]*$', re.M)
    if len(rx.findall(t)) != 1:
        print("FAIL: publish_selected_character not unique"); sys.exit(1)
    FUNC = ('/* ' + MARK + r' -- hand the character to OpenMW directly.'
        '\n' r' * A synthetic uinput keystroke only becomes a character if SDL can'
        '\n' r' * translate it through the kernel console keymap, which some TrimUI OS'
        '\n' r' * images do not provide: the keystroke is emitted correctly and nothing'
        '\n' r' * is typed. Appending here is OS-independent. Append, not overwrite, so'
        '\n' r' * fast presses are not lost between engine frames. */'
        '\n' r'static void tsp_queue_injected_char(char value)'
        '\n' r'{'
        '\n' r'    FILE *file = fopen(TEXT_INJECT_FILE, "a");'
        '\n' r'    if (file != NULL) {'
        '\n' r'        fputc(value, file);'
        '\n' r'        fclose(file);'
        '\n' r'    }'
        '\n' r'    if (log_file != NULL) {'
        '\n' r'        fprintf(log_file, "' + MARK + r' queued=%d\\n", (int)value);'
        '\n' r'        fflush(log_file);'
        '\n' r'    }'
        '\n' r'}'
        '\n'
        '\n' r'\g<0>')
    t = rx.sub(FUNC, t, count=1)
    print("OK:   tsp_queue_injected_char()")
    rx = re.compile(r'^(?P<i>[ \t]*)if \(event->code == KEY_TSP_A\) \{[ \t\r]*$', re.M)
    n = len(rx.findall(t))
    if n != 1:
        print("FAIL: KEY_TSP_A branch matched %d (need 1)" % n); sys.exit(1)
    t = rx.sub(r'\g<0>' '\n' r'\g<i>    /* ' + MARK + r' */'
               '\n' r'\g<i>    tsp_queue_injected_char(selected_character());', t, count=1)
    print("OK:   A queues the character (MANDATORY)")
    for label, pat, ch in (
        ("backspace", r'^(?P<i>[ \t]*)tap_key\(KEY_BACKSPACE\);[ \t\r]*$', "8"),
        ("enter", r'^(?P<i>[ \t]*)tap_key\(KEY_ENTER\);[ \t\r]*$', "13"),
    ):
        rx = re.compile(pat, re.M)
        k = len(rx.findall(t))
        if k == 0:
            print("MISS: %s hook -- UNWIRED, character fix still ships" % label)
            notes.append(label); continue
        t = rx.sub(r'\g<i>/* ' + MARK + r' */' '\n'
                   r'\g<i>tsp_queue_injected_char((char)' + ch + r');' '\n' r'\g<0>', t)
        print("OK:   %s queues %s x%d" % (label, ch, k))
for o, c in (("{", "}"), ("(", ")")):
    if t.count(o) != t.count(c):
        print("FAIL: unbalanced %s%s" % (o, c)); sys.exit(1)
if t.count("tsp_queue_injected_char(selected_character());") != 1: print("FAIL: queue call count"); sys.exit(1)
if t.count("static void tsp_queue_injected_char(char value)") != 1: print("FAIL: function count"); sys.exit(1)
if "rename(TEXT_CHAR_TMP, TEXT_CHAR_FILE)" not in t: print("FAIL: indicator publisher damaged"); sys.exit(1)
print("OK: balance, one queue call, indicator intact")
if t == orig:
    print("VERIFIED: already present, nothing written."); sys.exit(0)
s = time.strftime("%Y%m%d-%H%M%S")
io.open("%s.before-v64-%s" % (C, s), "w", encoding="utf-8", newline="").write(orig)
io.open(C, "w", encoding="utf-8", newline="").write(t)
print("wrote %s" % os.path.basename(C))
if notes: print("UNWIRED: %s" % ", ".join(notes))
print("VERIFIED: helper v64 present")
