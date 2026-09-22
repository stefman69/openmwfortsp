#!/usr/bin/env python3
"""tsp_abpatch.py - insert TSP_AB_SWITCH_V1 into Morrowind.sh.

Runs on the HOST against a fetched copy of the launcher, so it can be tested
before anything is uploaded. Refuses unless every anchor resolves exactly once.

Two flag-file switches, inserted immediately before the line that execs the
game, so they are the last word on TSP_LD_PRELOAD:

  /mnt/SDCARD/tsp_noscaler  drop the swap-scaler .so from TSP_LD_PRELOAD.
  /mnt/SDCARD/tsp_texsd     move the eMMC texture root aside so every texture
                            read falls through to the SD copy.

Both arms log what they did, either way, so a run can never be misattributed.

The flags live on the SD card on purpose: if removing the scaler leaves a blank
screen, the flag can still be deleted over ssh with the handheld in that state.
"""

import re
import sys
import os
import difflib
import subprocess
import tempfile

MARK = "TSP_AB_SWITCH_V1"
MODE = sys.argv[1] if len(sys.argv) > 1 else "plan"
PATH = sys.argv[2] if len(sys.argv) > 2 else "launcher.sh"

# The exec line, as seen in the crash tail:
#   LD_PRELOAD="$TSP_LD_PRELOAD" "$OPENMW_BIN" --resources "$OPENMW_RESOURCES" ...
EXEC_RE = re.compile(r'^\s*LD_PRELOAD="\$\{?TSP_LD_PRELOAD\}?"\s+"\$\{?OPENMW_BIN\}?"', re.M)

BLOCK = r'''
# ===================== TSP_AB_SWITCH_V1 ======================================
# Two A/B flips, each driven by a flag file, so switching arms never needs a
# script edit. Both branches log, so a run can never be misattributed.
#
#  /mnt/SDCARD/tsp_noscaler  -> drop the swap-scaler .so from TSP_LD_PRELOAD.
#     TSP_SWAPSCALER_051_V35 logs scale=0 source=1280x720
#     requested_output=1280x720 - a full-screen pass whose output equals its
#     input - and tsp_gltime measured SwapWindow=11.5 ms of a 46.5 ms frame
#     with vsync confirmed off. The resolution-lowering patch is kept, just
#     bypassed while scale=0. In this launcher the entry is
#     $GAMEDIR/lib/libtsp_fullscreen_scaler.so, assembled at line 1064 next to
#     libtsp_warm.so and $TSP_GL4ES_LIBRARY - only the *scaler*.so entry is
#     dropped, and every dropped entry is named in the log line.
#
#  /mnt/SDCARD/tsp_texsd     -> move /mnt/UDISK/openmw-tex/textures aside, so
#     the data= root still exists (no missing-directory warning) but holds
#     nothing, and every texture falls through to the SD copy. Touches NO
#     config, so the mod manager never sees an out-of-sync openmw.cfg.
#     The eMMC already carries the 891 MB navmesh and the 512 MB swapfile, and
#     benched 2787 KB/s against the SD card's 5213.
#
# Flags are on the SD card so they can be removed over ssh even if a blank
# screen makes the handheld unusable.

if [ -f /mnt/SDCARD/tsp_noscaler ]; then
  tsp_ab_before="$TSP_LD_PRELOAD"
  tsp_ab_keep=""
  tsp_ab_drop=""
  tsp_ab_ifs="$IFS"
  IFS=':'
  for tsp_ab_p in $tsp_ab_before; do
    [ -n "$tsp_ab_p" ] || continue
    case "$tsp_ab_p" in
      *scaler*.so|*Scaler*.so|*SCALER*.so)
        tsp_ab_drop="$tsp_ab_drop $tsp_ab_p"; continue ;;
    esac
    if [ -n "$tsp_ab_keep" ]; then tsp_ab_keep="$tsp_ab_keep:$tsp_ab_p"
    else tsp_ab_keep="$tsp_ab_p"; fi
  done
  IFS="$tsp_ab_ifs"
  TSP_LD_PRELOAD="$tsp_ab_keep"
  export TSP_LD_PRELOAD
  echo "TSP_AB_SWITCH_V1 scaler=OFF dropped=[$tsp_ab_drop] preload=[$TSP_LD_PRELOAD]"
  echo "TSP_AB_SWITCH_V1 scaler=OFF dropped=[$tsp_ab_drop] preload=[$TSP_LD_PRELOAD]" >> /mnt/SDCARD/tsp_prog.txt
else
  echo "TSP_AB_SWITCH_V1 scaler=ON preload=[$TSP_LD_PRELOAD]"
  echo "TSP_AB_SWITCH_V1 scaler=ON preload=[$TSP_LD_PRELOAD]" >> /mnt/SDCARD/tsp_prog.txt
fi

if [ -f /mnt/SDCARD/tsp_texsd ]; then
  [ -d /mnt/UDISK/openmw-tex/textures ] \
    && mv /mnt/UDISK/openmw-tex/textures /mnt/UDISK/openmw-tex/textures.off 2>/dev/null
  tsp_ab_arm="SD"
else
  [ -d /mnt/UDISK/openmw-tex/textures.off ] \
    && mv /mnt/UDISK/openmw-tex/textures.off /mnt/UDISK/openmw-tex/textures 2>/dev/null
  tsp_ab_arm="UDISK"
fi
if [ -d /mnt/UDISK/openmw-tex/textures ]; then tsp_ab_live="present"; else tsp_ab_live="movedAside"; fi
echo "TSP_AB_SWITCH_V1 texroot=$tsp_ab_arm udisk_textures=$tsp_ab_live"
echo "TSP_AB_SWITCH_V1 texroot=$tsp_ab_arm udisk_textures=$tsp_ab_live" >> /mnt/SDCARD/tsp_prog.txt
# =================== end TSP_AB_SWITCH_V1 ====================================
'''


def die(msg):
    print("  REFUSING: %s" % msg)
    print("  Nothing was written.")
    sys.exit(3)


def dump():
    """Print everything about this launcher that any patch of it could need."""
    if not os.path.isfile(PATH):
        print("  %s does not exist" % PATH)
        return 1
    text = open(PATH, encoding="utf-8", errors="surrogateescape").read()
    lines = text.split("\n")
    print("=" * 72)
    print("== LAUNCHER: %s" % PATH)
    print("== %d bytes, %d lines, shebang %r" % (len(text), len(lines), lines[0] if lines else ""))
    print("=" * 72)

    import subprocess as sp, tempfile as tf2
    for shell in ("bash", "sh"):
        with tf2.NamedTemporaryFile("w", suffix=".sh", delete=False,
                                    encoding="utf-8", errors="surrogateescape") as t:
            t.write(text); tmp = t.name
        r = sp.run([shell, "-n", tmp], capture_output=True, text=True)
        os.unlink(tmp)
        print("\n-- %s -n : %s" % (shell, "OK" if r.returncode == 0 else r.stderr.strip()[:200]))
        if r.returncode != 0:
            m = re.search(r":\s*(\d+):", r.stderr)
            if m:
                n = int(m.group(1))
                print("   the offending region, %d-%d:" % (max(1, n - 4), n + 4))
                for i in range(max(1, n - 4), min(len(lines), n + 5)):
                    print("   %5d |%s %s" % (i, ">>" if i == n else "  ", lines[i - 1]))

    def region(title, pat, before=6, after=14, limit=6):
        print("\n" + "-" * 72)
        print("-- %s" % title)
        print("-" * 72)
        hits = [i for i, l in enumerate(lines, 1) if re.search(pat, l)]
        if not hits:
            print("   (no match for %s)" % pat)
            return
        shown = set()
        for h in hits[:limit]:
            lo, hi = max(1, h - before), min(len(lines), h + after)
            if any(i in shown for i in range(lo, hi + 1)):
                continue
            print("   ... lines %d-%d ..." % (lo, hi))
            for i in range(lo, hi + 1):
                shown.add(i)
                print("   %5d |%s %s" % (i, ">>" if i == h else "  ", lines[i - 1]))
            print("")

    region("EVERY LD_PRELOAD / TSP_LD_PRELOAD line, with context",
           r"LD_PRELOAD", before=4, after=6, limit=8)
    region("THE EXEC INVOCATION (may be line-continued)",
           r'^\s*LD_PRELOAD="\$\{?TSP_LD_PRELOAD', before=3, after=16, limit=2)
    region("THE SCALER / RESOLUTION BLOCK",
           r"FULLSCREEN_SCALE|fullscreen_scaler|SCALE_SOURCE|SCALE_OUTPUT",
           before=4, after=8, limit=5)
    region("WHAT THE LAUNCHER SOURCES",
           r'^\s*(\.|source)\s+\S', before=2, after=3, limit=6)

    print("\n" + "-" * 72)
    print("-- EVERY tsp_ marker block already in this launcher (do not collide)")
    print("-" * 72)
    for i, l in enumerate(lines, 1):
        if re.search(r"TSP_[A-Z0-9_]+_V\d+|# TSP_[A-Z]", l):
            print("   %5d | %s" % (i, l.strip()[:130]))
    return 0


def main():
    if MODE == "dump":
        return dump()
    if not os.path.isfile(PATH):
        die("%s does not exist" % PATH)
    text = open(PATH, encoding="utf-8", errors="surrogateescape").read()
    orig = text
    lines = text.split("\n")
    print("  launcher: %s  (%d bytes, %d lines)" % (PATH, len(text), len(lines)))

    # ---- how is TSP_LD_PRELOAD actually built? print it, never guess ----
    print("\n  --- every line that mentions TSP_LD_PRELOAD")
    pre = [(i + 1, l) for i, l in enumerate(lines) if "TSP_LD_PRELOAD" in l]
    for n, l in pre:
        print("      %5d | %s" % (n, l.strip()[:150]))
    if not pre:
        die("the launcher never mentions TSP_LD_PRELOAD - I will not guess how "
            "the preload list is built")

    print("\n  --- every line that mentions a scaler")
    sc = [(i + 1, l) for i, l in enumerate(lines)
          if re.search(r"scal", l, re.I) and "TSP_AB_SWITCH" not in l]
    for n, l in sc[:20]:
        print("      %5d | %s" % (n, l.strip()[:150]))
    if not sc:
        print("      (none - the swap-scaler may not be preloaded at all; the "
              "switch would then be a no-op and say so in its log line)")

    # ---- idempotence -------------------------------------------------------
    if MARK in text:
        print("\n  %s already present %d time(s) - already installed."
              % (MARK, text.count(MARK)))
        print("  Flip arms with the flag files; no re-patch needed.")
        sys.exit(4)

    # ---- anchor: the exec line --------------------------------------------
    hits = list(EXEC_RE.finditer(text))
    if len(hits) != 1:
        print("\n  --- candidate exec lines")
        for i, l in enumerate(lines):
            if "OPENMW_BIN" in l:
                print("      %5d | %s" % (i + 1, l.strip()[:150]))
        die("expected exactly 1 line matching LD_PRELOAD=\"$TSP_LD_PRELOAD\" "
            "\"$OPENMW_BIN\", found %d" % len(hits))
    h = hits[0]
    execline = text[: h.start()].count("\n") + 1
    print("\n  exec line: %d" % execline)
    print("      %s" % lines[execline - 1].strip()[:160])

    # the block must land at the START of that line, after the preceding newline
    ins = text.rfind("\n", 0, h.start()) + 1
    text = text[:ins] + BLOCK.lstrip("\n") + "\n" + text[ins:]

    # ---- assertions -------------------------------------------------------
    nl = text.split("\n")

    # BASELINE-RELATIVE syntax checks. The first version required `sh -n` to
    # pass on the patched file - but this launcher is #!/bin/bash and its own
    # line 422 does not parse under dash, so the check failed on a pre-existing
    # property the patch never touches. Same class of bug as asserting
    # "#include <malloc.h> exactly once" on a file that already had two.
    # The rule: assert the patched file is NO WORSE than the original, under
    # the interpreter the shebang actually names.
    def parses(shell, body):
        with tempfile.NamedTemporaryFile("w", suffix=".sh", delete=False,
                                         encoding="utf-8", errors="surrogateescape") as tf:
            tf.write(body)
            tmp = tf.name
        try:
            r = subprocess.run([shell, "-n", tmp], capture_output=True, text=True)
            return (r.returncode == 0, (r.stderr or "ok").strip()[:110])
        finally:
            os.unlink(tmp)

    shebang = lines[0] if lines and lines[0].startswith("#!") else ""
    interp = "bash"
    for cand in ("bash", "sh", "dash", "ksh"):
        if cand in shebang:
            interp = cand
            break
    print("\n  shebang: %s   -> checking with %s"
          % (shebang or "(none, assuming bash)", interp))

    base_i = parses(interp, orig)
    new_i = parses(interp, text)
    base_sh = parses("sh", orig)
    new_sh = parses("sh", text)
    print("      original under %-5s %s" % (interp, "OK" if base_i[0] else "FAILS: " + base_i[1]))
    print("      original under sh    %s" % ("OK" if base_sh[0] else "FAILS: " + base_sh[1]))
    if not base_sh[0]:
        print("      (that sh failure is pre-existing - the launcher is not a POSIX"
              " script and never was)")

    icheck = (new_i[0] if base_i[0] else True,
              ("%s: %s" % (interp, new_i[1])) if not new_i[0] else "ok")
    shcheck = (new_sh[0] or not base_sh[0],
               "no worse than baseline" if (new_sh[0] or not base_sh[0]) else new_sh[1])
    want_marks = BLOCK.count(MARK)
    checks = [
        ("marker appears exactly %dx" % want_marks,
         text.count(MARK) == want_marks, text.count(MARK)),
        ("the exec line still exists once",
         len(EXEC_RE.findall(text)) == 1, len(EXEC_RE.findall(text))),
        ("block sits BEFORE the exec line",
         text.index(MARK) < EXEC_RE.search(text).start(), "ok"),
        # Ask a shell, do not count keywords. The first version of this counted
        # "if" and "fi" at line starts and failed on a legitimate single-line
        # "if ...; then ...; else ...; fi" - a heuristic where an authoritative
        # check was one subprocess away.
        ("parses under its own shebang interpreter", icheck[0], icheck[1]),
        ("sh -n no worse than the original", shcheck[0], shcheck[1]),
        ("line count grew by the block's size",
         len(nl) - len(lines) == BLOCK.lstrip("\n").count("\n") + 1,
         len(nl) - len(lines)),
        ("nothing else changed",
         orig.replace("\n", "") in text.replace("\n", "")
         or all(l in nl for l in lines if l.strip()), "ok"),
    ]
    print("\n  --- assertions")
    bad = 0
    for name, ok, got in checks:
        print("      %-38s %s (%s)" % (name, "PASS" if ok else "FAIL", got))
        if not ok:
            bad += 1
    if bad:
        die("%d assertion(s) failed" % bad)

    print("\n  --- EVERY LINE THIS ADDS")
    for line in difflib.unified_diff(lines, nl, lineterm="", n=2):
        if line.startswith("---") or line.startswith("+++"):
            continue
        print("      %s" % line)

    if MODE == "plan":
        print("\n  PLAN ONLY - nothing written.")
        return 0

    out = sys.argv[3] if len(sys.argv) > 3 else PATH + ".patched"
    open(out, "w", encoding="utf-8", errors="surrogateescape").write(text)
    back = open(out, encoding="utf-8", errors="surrogateescape").read()
    if back != text:
        die("read-back of %s does not match" % out)
    print("\n  wrote %s  (%d bytes, %+d)" % (out, len(back), len(back) - len(orig)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
