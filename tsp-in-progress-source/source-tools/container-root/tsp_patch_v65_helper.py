"""TSP_TEXT_INJECT_V65 (helper) -- stop sending the keystroke as well.

V64 added the file queue and deliberately LEFT the uinput keystroke in place
(V49 lesson: do not remove a working path while adding a new one). That was the
right call and it did its job: on the TSPS, where SDL text synthesis works, every
character now types TWICE. Injection is confirmed on both consoles, so the
keystroke is pure duplication for type, backspace and Enter. Remove exactly those
emissions -- the ones immediately following a queue call.

Escape is NOT touched: leave_text_mode()'s tap is a different path with no
injected equivalent.
"""
import io, os, re, sys, time
C = os.environ.get("TSPHELPER", "/root/tsp_openmw_controls.c")
MARK = "TSP_TEXT_INJECT_V65"
t = io.open(C, encoding="utf-8").read()
orig = t
if "tsp_queue_injected_char" not in t:
    print("FAIL: V64 is not applied to this helper source"); sys.exit(1)
print("OK: precondition - V64 present")
if MARK in t:
    print("SKIP: already applied")
else:
    rx = re.compile(
        r'^(?P<i>[ \t]*)tsp_queue_injected_char\((?P<arg>[^;]*)\);[ \t\r]*\n'
        r'[ \t]*(?P<emit>type_character\([^;]*\)|tap_key\(KEY_ENTER\)|tap_key\(KEY_BACKSPACE\));[ \t\r]*\n',
        re.M)
    hits = rx.findall(t)
    if len(hits) < 3:
        print("FAIL: expected at least 3 queue+emit pairs, found %d" % len(hits)); sys.exit(1)
    for h in hits:
        print("   removing duplicate emission: %s" % h[2])
    t = rx.sub(r'\g<i>tsp_queue_injected_char(\g<arg>);' '\n'
               r'\g<i>/* ' + MARK + r' -- the uinput keystroke was removed here: the'
               '\n' r'\g<i> * engine injects this directly now, and emitting both typed'
               '\n' r'\g<i> * every character twice wherever SDL text synthesis works. */'
               '\n', t)
    print("OK:   removed %d duplicate emission(s)" % len(hits))
# Only statements are deleted, never blocks: brace counts must be identical.
for ch in "{}":
    if t.count(ch) != orig.count(ch):
        print("FAIL: '%s' count changed %d -> %d" % (ch, orig.count(ch), t.count(ch))); sys.exit(1)
for gone in ("type_character(selected_character())", "tap_key(KEY_ENTER);", "tap_key(KEY_BACKSPACE);"):
    if gone in t:
        print("FAIL: duplicate emission survived: %s" % gone); sys.exit(1)
if "tap_key(KEY_LEFT);" not in t:
    print("FAIL: the non-backspace d-pad-left path was damaged"); sys.exit(1)
if t.count("tsp_queue_injected_char(selected_character());") != 1:
    print("FAIL: the character queue call was lost"); sys.exit(1)
if t.count("static void tsp_queue_injected_char(char value)") != 1:
    print("FAIL: queue function count"); sys.exit(1)
if "rename(TEXT_CHAR_TMP, TEXT_CHAR_FILE)" not in t:
    print("FAIL: on-screen indicator publisher damaged"); sys.exit(1)
if "leave_text_mode" not in t:
    print("FAIL: cancel path damaged"); sys.exit(1)
print("OK: balance, queue intact, indicator + cancel untouched")
if t == orig:
    print("VERIFIED: already present, nothing written."); sys.exit(0)
s = time.strftime("%Y%m%d-%H%M%S")
io.open("%s.before-v65-%s" % (C, s), "w", encoding="utf-8", newline="").write(orig)
io.open(C, "w", encoding="utf-8", newline="").write(t)
print("wrote %s" % os.path.basename(C))
print("VERIFIED: helper v65 present")
