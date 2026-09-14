#!/usr/bin/env python3
# Removes the TSP sound warm from the source. No heuristics, no line classifier.
#
# Two kinds of change, and which kind each file gets is decided by how big its
# diff against its own backup is:
#
#   soundmanagerimp.cpp   SURGERY. 189 lines differ from the 09-10 backup, and
#                         some of those lines are TSP_SOUNDPHASE_V1 and other
#                         work that has to stay. So this file is never restored.
#                         One brace-matched function, plus the comment block
#                         directly above it, is cut out. Nothing else is touched.
#
#   the other five        RESTORE from backup. Each differs from its backup by
#                         3 to 6 lines total, so there is nothing else in them
#                         to lose. The whole diff is printed - it is short
#                         enough to read - instead of being scored by a filter.
#
# Refuses only on facts, never on a guess:
#   - the function signature must occur exactly once
#   - the cut span must be brace balanced and must contain mSoundBuffers.load
#   - whole-file brace balance must be unchanged by the cut
#   - after the change, no reference to the warm may remain anywhere in apps/
#   - anything the file had before that is not the warm must still be there

import difflib
import glob
import os
import re
import sys

ROOT = sys.argv[1] if len(sys.argv) > 1 else "/root/openmw-0.51-tsp-src"
MODE = sys.argv[2] if len(sys.argv) > 2 else "plan"
STAMP = os.environ.get("TSP_STAMP", "soundkill")

SMI = "apps/openmw/mwsound/soundmanagerimp.cpp"

# (path, which backup suffix to restore from)
V2 = ".before-sndwarmv2"
RESTORES = [
    ("apps/openmw/mwsound/soundbuffer.hpp", V2),
    ("apps/openmw/mwsound/soundbuffer.cpp", V2),
    ("apps/openmw/mwsound/soundmanagerimp.hpp", None),   # None = V1 stamp, found on disk
    ("apps/openmw/mwbase/soundmanager.hpp", None),
    ("apps/openmw/mwworld/scene.cpp", None),
]

SIG = "void SoundManager::tspWarmCellSounds("

# Identifiers that exist ONLY because of the warm. After the change, none of
# these may appear anywhere under apps/ - that is what proves the removal is
# complete and that the build will still link.
WARM_IDS = ["tspWarmCellSounds", "tspGetCacheSize", "tspGetCacheMin",
            "tspGetCacheMax", "mTspWarmedWeather", "TSP_SNDWARM",
            "TSP_SNDCACHE_WARN", "TSP_NO_SNDWARM"]

# Markers that must SURVIVE. Checked per file against that file's own before
# state, so a marker that was never in the file cannot make this pass by
# accident, and one that was there and vanishes fails.
KEEP = ["TSP_SOUNDPHASE_V1", "TSP_LOAD_TRACE_051", "TSP_MEMGATE_V1",
        "TSP_GMAP_MEM_V1", "TSP_NO_LOADPURGE", "TSP_PLAYERANIM_MEM_V1"]

FAILED = []


def die(msg):
    print("")
    print("REFUSING: %s" % msg)
    print("NOTHING WAS WRITTEN.")
    sys.exit(1)


def read(p):
    with open(p, "r", encoding="utf-8", errors="replace") as fh:
        return fh.read()


def write(p, text):
    bak = "%s.before-%s" % (p, STAMP)
    if not os.path.exists(bak):
        with open(bak, "w", encoding="utf-8") as fh:
            fh.write(read(p))
    with open(p, "w", encoding="utf-8") as fh:
        fh.write(text)
    return bak


def v1_stamp():
    """Read the V1 backup stamp off the disk instead of assuming it."""
    pat = os.path.join(ROOT, "apps/openmw/mwsound/soundmanagerimp.hpp.before-sndwarm-*")
    found = sorted(glob.glob(pat))
    if len(found) != 1:
        die("expected exactly one soundmanagerimp.hpp.before-sndwarm-* backup, found %d"
            % len(found))
    return found[0].split(".before-", 1)[1]


# --------------------------------------------------------------- the cut ------
def comment_start(text, at):
    """Walk backwards from `at` over the comment block that introduces the
    function, so the /* TSP_SNDWARM_V2 ... */ prose goes with it. Stops at the
    first line that is neither blank, nor a // line, nor part of a /* */ block."""
    lines = text[:at].split("\n")
    # lines[-1] is the (possibly indented) start of the signature line
    i = len(lines) - 2
    first = len(lines) - 1
    while i >= 0:
        s = lines[i].strip()
        if s == "":
            break
        if s.startswith("//"):
            first = i
            i -= 1
            continue
        if s.endswith("*/"):
            # walk back to the opening /* of this block
            j = i
            while j >= 0 and "/*" not in lines[j]:
                j -= 1
            if j < 0:
                break
            first = j
            i = j - 1
            continue
        break
    return len("\n".join(lines[:first])) + (1 if first > 0 else 0)


def cut_member_uses(text):
    """V1 also put mTspWarmedWeather in the constructor's initialiser list. The
    member goes away when soundmanagerimp.hpp is restored, so that initialiser
    has to go too or the file will not compile.

    Only two exact shapes are allowed to be removed. Anything else mentioning
    the member is reported and refused, rather than guessed at."""
    INIT = re.compile(r"^(\s*)([:,])(\s*)mTspWarmedWeather\s*\([^()]*\)\s*,?\s*$")
    ASSIGN = re.compile(r"^\s*mTspWarmedWeather\s*=\s*(true|false)\s*;\s*$")
    lines = text.split("\n")
    out = []
    removed = []
    i = 0
    while i < len(lines):
        line = lines[i]
        m = INIT.match(line)
        if m:
            removed.append((i + 1, line))
            # If this was the FIRST initialiser, the next one has to take over
            # the ':' or the file will not parse.
            if m.group(2) == ":":
                j = i + 1
                while j < len(lines) and lines[j].strip() == "":
                    j += 1
                if j < len(lines) and lines[j].lstrip().startswith(","):
                    ind = lines[j][:len(lines[j]) - len(lines[j].lstrip())]
                    lines[j] = ind + ":" + lines[j].lstrip()[1:]
                else:
                    die("mTspWarmedWeather is the only initialiser on the "
                        "constructor at line %d and I will not guess how to "
                        "rewrite that. Send me lines %d-%d of %s."
                        % (i + 1, max(1, i - 3), i + 4, SMI))
            i += 1
            continue
        if ASSIGN.match(line):
            removed.append((i + 1, line))
            i += 1
            continue
        if "mTspWarmedWeather" in line:
            die("line %d of %s mentions mTspWarmedWeather in a shape I do not "
                "recognise, so I am not touching it:\n    %s" % (i + 1, SMI, line))
        out.append(line)
        i += 1
    return "\n".join(out), removed


def cut_function(text):
    hits = text.count(SIG)
    if hits != 1:
        for n, line in enumerate(text.split("\n"), 1):
            if "tspWarmCellSounds" in line:
                print("    %6d  %s" % (n, line))
        die("'%s' occurs %d times in %s, need exactly 1" % (SIG, hits, SMI))
    at = text.find(SIG)

    i = at + len(SIG)
    # skip the parameter list
    depth = 0
    while i < len(text):
        if text[i] == "(":
            depth += 1
        elif text[i] == ")":
            if depth == 0:
                i += 1
                break
            depth -= 1
        i += 1
    while i < len(text) and text[i] != "{":
        if text[i] not in " \t\r\n":
            die("unexpected text between the signature and its opening brace: %r"
                % text[i:i + 40])
        i += 1
    if i >= len(text):
        die("no opening brace after the signature")

    depth = 0
    end = None
    while i < len(text):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                end = i + 1
                if end < len(text) and text[end] == "\n":
                    end += 1
                break
        i += 1
    if end is None:
        die("unterminated function body - refusing to cut")

    start = comment_start(text, at)
    span = text[start:end]
    if span.count("{") != span.count("}"):
        die("the span I matched is not brace balanced (%d open, %d close)"
            % (span.count("{"), span.count("}")))
    if "mSoundBuffers.load" not in span:
        die("the matched span does not contain mSoundBuffers.load - wrong span, refusing")
    return start, end, span


# ------------------------------------------------------------------ report ----
def show_diff(path, bak, label):
    cur = read(path).split("\n")
    old = read(bak).split("\n")
    d = [l for l in difflib.unified_diff(cur, old, "now", "after restore", n=0, lineterm="")]
    body = [l for l in d if l[:1] in "+-" and l[:3] not in ("+++", "---")]
    print("  %s   (%d lines change)" % (label, len(body)))
    for l in d:
        if l.startswith("@@"):
            print("      %s" % l)
        elif l[:3] in ("+++", "---"):
            continue
        elif l.startswith("-"):
            print("      remove | %s" % l[1:].rstrip())
        elif l.startswith("+"):
            print("      keep   | %s" % l[1:].rstrip())
    if not body:
        print("      (already reverted - nothing to do)")
    return len(body)


def main():
    if MODE not in ("plan", "apply"):
        die("mode must be plan or apply")
    os.chdir(ROOT)

    stamp1 = v1_stamp()
    print("  V1 backup stamp read off disk: .before-%s" % stamp1)
    print("")

    # ---- gather ---------------------------------------------------------------
    smi_before = read(SMI)
    if SIG not in smi_before and "tspWarmCellSounds" not in smi_before:
        print("ALREADY REVERTED: %s has no warm in it." % SMI)
        left = []
        for rel, suffix in RESTORES:
            t = read(rel)
            for w in WARM_IDS:
                if w in t:
                    left.append("%s (%s)" % (rel, w))
                    break
        if left:
            print("  but these still carry warm code, so the revert is half done:")
            for l in left:
                print("    %s" % l)
            die("half-reverted tree - send me the list above rather than "
                "running this again")
        print("  and none of the other five files do either. Nothing to do.")
        sys.exit(3)   # 3 = already done; the wrapper stops without building
    start, end, span = cut_function(smi_before)
    smi_cut = smi_before[:start] + smi_before[end:]
    smi_after, member_lines = cut_member_uses(smi_cut)

    sl = smi_before[:start].count("\n") + 1
    el = smi_before[:end].count("\n")
    span_lines = span.rstrip("\n").split("\n")

    print("========== SURGERY: %s ==========" % SMI)
    print("  cutting lines %d-%d (%d lines). This file is NOT restored from a"
          % (sl, el, el - sl + 1))
    print("  backup, so nothing else in it moves.")
    print("")
    for l in span_lines[:4]:
        print("      cut | %s" % l.rstrip())
    print("      cut | ... %d more lines ..." % max(0, len(span_lines) - 8))
    for l in span_lines[-4:]:
        print("      cut | %s" % l.rstrip())
    print("")

    if member_lines:
        print("  and these lines, because the member they touch goes away with")
        print("  the header restore:")
        for n, line in member_lines:
            print("      cut | %6d  %s" % (n, line.rstrip()))
        print("")

    # brace balance of the file must be unchanged by the cut
    bb = (smi_before.count("{") - smi_before.count("}"))
    ba = (smi_after.count("{") - smi_after.count("}"))
    if bb != ba:
        die("the cut changed whole-file brace balance (%+d -> %+d)" % (bb, ba))
    print("  brace balance unchanged (%+d)" % ba)

    # everything that was in this file and is not the warm must still be there
    for k in KEEP:
        if k in smi_before:
            if k not in smi_after:
                die("the cut would remove %s from %s" % (k, SMI))
            print("  %-24s still present after the cut" % k)
    print("")

    # ---- the five restores ---------------------------------------------------
    print("========== RESTORES: the whole diff, not a score ==========")
    print("  Each of these differs from its own backup by a handful of lines.")
    print("  Read them. If every 'remove' line below is sound-warm code, the")
    print("  restore loses nothing - which is the only thing the old gate was")
    print("  ever trying to work out, badly.")
    print("")
    plan = []
    total = 0
    for rel, suffix in RESTORES:
        sfx = suffix if suffix else ".before-" + stamp1
        bak = rel + sfx
        if not os.path.isfile(rel):
            die("missing source file %s" % rel)
        if not os.path.isfile(bak):
            die("missing backup %s" % bak)
        n = show_diff(rel, bak, "%-26s <- %s" % (os.path.basename(rel), sfx))
        # a restore must not drop a marker that has to survive
        oldtext = read(bak)
        curtext = read(rel)
        for k in KEEP:
            if k in curtext and k not in oldtext:
                die("restoring %s would remove %s - refusing" % (rel, k))
        total += n
        plan.append((rel, bak, oldtext))
        print("")
    print("  restore lines in total: %d" % total)
    print("")

    # ---- residual check (this is the real gate) ------------------------------
    after = {SMI: smi_after}
    for rel, bak, oldtext in plan:
        after[rel] = oldtext

    print("========== WOULD ANY WARM REFERENCE SURVIVE ==========")
    resid = []
    for dirpath, dirnames, filenames in os.walk("apps"):
        dirnames[:] = [d for d in dirnames if d != ".git"]
        for fn in filenames:
            if not fn.endswith((".cpp", ".hpp", ".h", ".cxx")):
                continue
            if ".before-" in fn:
                continue
            p = os.path.join(dirpath, fn)
            text = after.get(p, None)
            if text is None:
                text = read(p)
            for n, line in enumerate(text.split("\n"), 1):
                for w in WARM_IDS:
                    if w in line:
                        resid.append((p, n, w, line.strip()))
                        break
    if resid:
        for p, n, w, line in resid[:40]:
            print("    %s:%d  (%s)  %s" % (p, n, w, line[:110]))
        die("%d warm reference(s) would survive the change - the removal is "
            "incomplete and the build would break. Send me the lines above."
            % len(resid))
    print("  none. Every warm identifier is gone from apps/ after this change.")
    print("")

    if MODE == "plan":
        print("PLAN ONLY - nothing was written.")
        return

    # ---- write ---------------------------------------------------------------
    print("========== WRITING ==========")
    b = write(SMI, smi_after)
    print("  cut   %-44s (backup %s)" % (SMI, os.path.basename(b)))
    for rel, bak, oldtext in plan:
        b = write(rel, oldtext)
        print("  rstor %-44s (backup %s)" % (rel, os.path.basename(b)))
    print("")
    for rel in [SMI] + [p for p, _, _ in plan]:
        t = read(rel)
        for w in WARM_IDS:
            if w in t:
                die("post-write: %s still contains %s" % (rel, w))
    print("VERIFIED: the warm is out of the source, %s backups written." % STAMP)


if __name__ == "__main__":
    main()
