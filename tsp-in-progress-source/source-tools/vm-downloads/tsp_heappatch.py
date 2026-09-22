#!/usr/bin/env python3
"""tsp_heappatch.py - insert TSP_HEAPTRIM_V1 at the end of StateManager::loadGame.

Runs INSIDE the builder container against the real source tree. Refuses to
write anything unless every anchor resolves exactly once, and prints the full
before/after of every region it touches.

Why this patch exists
---------------------
The first load grows [heap] from 0 to 317.1 MB Rss (+25.2 MB swap). After the
load it reads 292.9 MB Rss + 50.8 MB swap - the same committed total. The memory
is not in use, it is *unreturned*: glibc trims only the top of the brk heap, so a
freed burst sitting under one live allocation pins the whole region, and the
kernel evicts the page cache instead. Every later walk then faults assets back in
one at a time, which is the hitch.

malloc_trim(0) walks every arena and madvises the interior free pages back to the
kernel. It runs at the end of the load, while the loading screen is still up, so
its cost is not visible as a frame hitch.

Logged at Debug::Warning ON PURPOSE. The device runs OPENMW_DEBUG_LEVEL=warning,
so a Debug::Info line would never reach any log file - that trap is already
recorded in SHIP-STATE-switches-and-config.
"""

import re
import sys
import os

SRC = os.environ.get("TSP_SRC", "/root/openmw-0.51-tsp-src")
FILE = os.path.join(SRC, "apps/openmw/mwstate/statemanagerimp.cpp")
MARK = "TSP_HEAPTRIM_V1"
HEADERS = ("<malloc.h>", "<cstdio>", "<unistd.h>", "<cstdlib>")
MODE = sys.argv[1] if len(sys.argv) > 1 else "plan"

FN_SIG = re.compile(
    r"^void\s+MWState::StateManager::loadGame\s*\(\s*const\s+Character\s*\*\s*\w+\s*,"
    r"\s*const\s+std::filesystem::path\s*&\s*\w+\s*\)\s*$",
    re.M,
)

HELPER = """
/* TSP_HEAPTRIM_V1: resident-set reader that needs no allocator helper, so this
   block does not depend on anything else in this file staying where it is. */
namespace
{
    long tspHeapTrimRssKb()
    {
        long rssPages = 0;
        FILE* f = std::fopen("/proc/self/statm", "r");
        if (f == nullptr)
            return -1;
        long totalPages = 0;
        const int got = std::fscanf(f, "%ld %ld", &totalPages, &rssPages);
        std::fclose(f);
        if (got != 2)
            return -1;
        return rssPages * (static_cast<long>(::sysconf(_SC_PAGESIZE)) / 1024);
    }
}
"""

TRIM = """
    /* TSP_HEAPTRIM_V1: see tsp_heappatch.py. The load burst is freed but not
       returned - glibc trims only the top of brk. This hands the interior free
       pages back. Runs under the loading screen, so the cost is not a hitch.
       TSP_NO_HEAPTRIM=1 disables it. */
#if defined(__GLIBC__)
    if (std::getenv("TSP_NO_HEAPTRIM") == nullptr)
    {
        const long tspTrimRssBefore = tspHeapTrimRssKb();
        const int tspTrimRc = malloc_trim(0);
        const long tspTrimRssAfter = tspHeapTrimRssKb();
        Log(Debug::Warning) << "TSP_HEAPTRIM_V1 rc=" << tspTrimRc
                            << " rss_before_kb=" << tspTrimRssBefore
                            << " rss_after_kb=" << tspTrimRssAfter
                            << " returned_kb=" << (tspTrimRssBefore - tspTrimRssAfter);
    }
#endif
"""


def die(msg):
    print("  REFUSING: %s" % msg)
    print("  Nothing was written. No build was started.")
    sys.exit(3)


def find_body_end(text, open_brace_idx):
    """Brace-match from the function's opening brace to its closing brace.
    Skips braces inside strings, chars and comments."""
    i = open_brace_idx
    depth = 0
    n = len(text)
    while i < n:
        c = text[i]
        if c == "/" and i + 1 < n and text[i + 1] == "/":
            i = text.find("\n", i)
            if i < 0:
                break
            continue
        if c == "/" and i + 1 < n and text[i + 1] == "*":
            i = text.find("*/", i + 2)
            if i < 0:
                break
            i += 2
            continue
        if c == '"':
            i += 1
            while i < n and text[i] != '"':
                i += 2 if text[i] == "\\" else 1
            i += 1
            continue
        if c == "'":
            i += 1
            while i < n and text[i] != "'":
                i += 2 if text[i] == "\\" else 1
            i += 1
            continue
        if c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                return i
        i += 1
    return -1


def undo():
    bak = FILE + ".before-heaptrim"
    if not os.path.isfile(bak):
        print("  no %s - nothing to restore" % bak)
        return 1
    orig = open(bak, encoding="utf-8", errors="surrogateescape").read()
    if MARK in orig:
        print("  REFUSING: the backup itself contains %s, so it is not the" % MARK)
        print("  original. Restoring it would not undo anything.")
        return 3
    open(FILE, "w", encoding="utf-8", errors="surrogateescape").write(orig)
    now = open(FILE, encoding="utf-8", errors="surrogateescape").read()
    print("  restored %s from %s (%d bytes)" % (FILE, bak, len(now)))
    print("  %s occurrences now: %d" % (MARK, now.count(MARK)))
    return 0 if now.count(MARK) == 0 else 3


def dump():
    """Print the FULL text of every region this patch reads or writes."""
    if not os.path.isfile(FILE):
        print("  %s does not exist" % FILE)
        return 1
    text = open(FILE, encoding="utf-8", errors="surrogateescape").read()
    lines = text.split("\n")
    print("=" * 70)
    print("== SOURCE FILE: %s" % FILE)
    print("== %d bytes, %d lines" % (len(text), len(lines)))
    print("=" * 70)

    print("\n----- SECTION 1: the include block, lines 1-70 (verbatim) -----")
    for i, ln in enumerate(lines[:70], 1):
        print("%5d | %s" % (i, ln))

    print("\n----- SECTION 2: every malloc / mallinfo / allocator line -----")
    for i, ln in enumerate(lines, 1):
        if re.search(r"malloc|mallinfo|mallopt|MallocInuse|M_MMAP|M_TRIM", ln):
            print("%5d | %s" % (i, ln))

    sigs = list(FN_SIG.finditer(text))
    print("\n----- SECTION 3: loadGame(const Character*, const path&) -----")
    print("  signatures matched: %d" % len(sigs))
    if len(sigs) == 1:
        sig = sigs[0]
        brace = text.find("{", sig.end())
        end = find_body_end(text, brace)
        a = text[: sig.start()].count("\n") + 1
        b = text[: end].count("\n") + 1
        print("  lines %d-%d, plus 30 lines of context above (VERBATIM, whole body)" % (a, b))
        lo = max(1, a - 30)
        for i in range(lo, b + 3):
            if i - 1 < len(lines):
                mark = ">>" if i == a or i == b else "  "
                print("%5d |%s %s" % (i, mark, lines[i - 1]))
    else:
        print("  cannot show the body - the signature did not resolve to exactly one")
        for i, ln in enumerate(lines, 1):
            if "loadGame" in ln:
                print("%5d | %s" % (i, ln))

    print("\n----- SECTION 4: the OTHER loadGame overload and endGame, for scope -----")
    for i, ln in enumerate(lines, 1):
        if re.match(r"^\s*(void|bool|int)\s+MWState::StateManager::", ln) or re.match(r"^namespace", ln) or re.match(r"^\s*#\s*(if|endif|else)", ln):
            print("%5d | %s" % (i, ln))
    return 0


def main():
    if MODE == "undo":
        return undo()
    if MODE == "dump":
        return dump()
    if not os.path.isfile(FILE):
        die("%s does not exist" % FILE)
    text = open(FILE, encoding="utf-8", errors="surrogateescape").read()
    orig = text

    print("  file:  %s" % FILE)
    print("  bytes: %d, lines: %d" % (len(text), text.count("\n") + 1))

    # ---- idempotence -------------------------------------------------------
    already = text.count(MARK)
    if already:
        print("  %s already present %d time(s) - this patch is already applied."
              % (MARK, already))
        print("  Nothing to do. Use the undo mode to remove it.")
        sys.exit(4)

    # ---- anchor 1: the function ------------------------------------------
    sigs = list(FN_SIG.finditer(text))
    if len(sigs) != 1:
        die("expected exactly 1 loadGame(const Character*, const path&) "
            "signature, found %d" % len(sigs))
    sig = sigs[0]
    brace = text.find("{", sig.end())
    if brace < 0:
        die("no opening brace after the loadGame signature")
    end = find_body_end(text, brace)
    if end < 0:
        die("could not brace-match the end of loadGame")
    sigline = text[: sig.start()].count("\n") + 1
    endline = text[: end].count("\n") + 1
    print("  loadGame(const Character*, const path&): lines %d-%d (%d lines)"
          % (sigline, endline, endline - sigline + 1))
    if endline - sigline < 10:
        die("that function body is only %d lines - the brace match is wrong"
            % (endline - sigline))

    # ---- context: what is immediately above the insertion point ----------
    # The helper goes in at namespace scope just before the function. If that
    # spot were inside an "#if" or an open namespace, the helper would be
    # conditional or misplaced - so print it and check it.
    pre = text[:sig.start()].split("\n")[-26:-1]
    print("\n  --- the 25 lines immediately above the insertion point")
    for i, ln in enumerate(pre):
        print("      %5d | %s" % (sigline - len(pre) + i, ln))
    opens = sum(1 for ln in pre if re.match(r"^\s*#\s*if", ln))
    closes = sum(1 for ln in pre if re.match(r"^\s*#\s*endif", ln))
    print("      preprocessor #if/#endif in that window: %d / %d%s"
          % (opens, closes, "  <- LOOK AT THIS" if opens != closes else "  (balanced)"))

    # ---- anchor 2: headers ------------------------------------------------
    need = []
    for hdr in HEADERS:
        if ("#include %s" % hdr) not in text:
            need.append(hdr)
    print("  headers to add: %s" % (", ".join(need) if need else "(none)"))

    inc = re.search(r"^#include .*$", text, re.M)
    if inc is None:
        die("no #include line at all in this file")

    # ---- build the new text ----------------------------------------------
    add = "".join("#include %s\n" % h for h in need)
    if add:
        text = text[: inc.start()] + add + text[inc.start():]
        shift = len(add)
    else:
        shift = 0

    # helper goes just before the function, at namespace scope
    ins_helper = sig.start() + shift
    text = text[:ins_helper] + HELPER + "\n" + text[ins_helper:]
    shift += len(HELPER) + 1

    # trim goes just before the function's closing brace
    ins_trim = end + shift
    text = text[:ins_trim] + TRIM + text[ins_trim:]

    # ---- assertions -------------------------------------------------------
    # Header accounting. The REAL statemanagerimp.cpp already carries
    # "#include <malloc.h>" TWICE - a pre-existing duplicate from an older
    # non-idempotent patch (the prepend-then-splice doubling recorded in
    # SHIP-STATE-switches-and-config). Demanding exactly one made this script
    # refuse over something it neither caused nor intends to change. The real
    # requirement is: every header is present at least once, and this patch did
    # not add a second copy of one that was already there.
    hdr_ok = True
    hdr_detail = []
    for hdr in HEADERS:
        inc_s = "#include %s" % hdr
        before = orig.count(inc_s)
        after = text.count(inc_s)
        want = 1 if before == 0 else before
        hdr_detail.append("%s %d->%d" % (hdr.strip("<>"), before, after))
        if after < 1 or after != want:
            hdr_ok = False

    # Derive the expected marker count from the templates themselves - a
    # hardcoded number here drifts the moment the comment text is edited.
    want_marks = (HELPER + TRIM).count(MARK)
    checks = [
        ("marker appears exactly %dx" % want_marks,
         text.count(MARK) == want_marks, text.count(MARK)),
        ("malloc_trim called exactly once", text.count("malloc_trim(0)") == 1,
         text.count("malloc_trim(0)")),
        ("helper defined exactly once",
         text.count("long tspHeapTrimRssKb()") == 1,
         text.count("long tspHeapTrimRssKb()")),
        ("every header present, none duplicated by me", hdr_ok,
         "; ".join(hdr_detail)),
        ("braces still balanced",
         text.count("{") - text.count("}") == orig.count("{") - orig.count("}"),
         text.count("{") - text.count("}")),
        ("file grew by a sane amount",
         0 < len(text) - len(orig) < 4000, len(text) - len(orig)),
    ]
    print("\n  --- assertions")
    bad = 0
    for name, ok, got in checks:
        print("      %-36s %s (got %s)" % (name, "PASS" if ok else "FAIL", got))
        if not ok:
            bad += 1
    if bad:
        die("%d assertion(s) failed" % bad)

    # ---- show every changed region ---------------------------------------
    print("\n  --- EVERY LINE THIS ADDS, with its new line number")
    ol = orig.split("\n")
    nl = text.split("\n")
    import difflib
    for line in difflib.unified_diff(ol, nl, lineterm="", n=3):
        if line.startswith("---") or line.startswith("+++"):
            continue
        print("      %s" % line)

    if MODE == "plan":
        print("\n  PLAN ONLY - nothing written.")
        return 0

    bak = FILE + ".before-heaptrim"
    if not os.path.exists(bak):
        open(bak, "w", encoding="utf-8", errors="surrogateescape").write(orig)
        print("\n  backed up original to %s" % bak)
    else:
        print("\n  %s already exists - keeping the ORIGINAL one" % bak)
    open(FILE, "w", encoding="utf-8", errors="surrogateescape").write(text)
    print("  wrote %d bytes (%+d)" % (len(text), len(text) - len(orig)))

    back = open(FILE, encoding="utf-8", errors="surrogateescape").read()
    if back != text:
        die("read-back does not match what was written")
    print("  read-back verified identical.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
