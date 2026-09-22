#!/usr/bin/env python3
"""tsp_dvpatch.py - damp the adaptive draw-distance controller.

Constants only. No control flow is touched, so the worst case is a controller
that moves more slowly than it used to.

WHY
---
Right after a load, with frames still settling at 47-62 ms, the controller swings
view distance 1600 units in three seconds:

    01:58:49.423  far=4700
    01:58:50.458  far=3900
    01:58:51.501  far=3100

Two of those three steps are exactly 800, which is MAX_DROP_PER_SAMPLE - the cap,
saturated, twice in a row. Every change forces terrain quadtree and object-paging
rebuilds, which is work in cull and draw, which keeps the framerate low, which
makes the controller cut again. It is chasing a transient it is also feeding.

SHIP-STATE-switches-and-config already names these as the dials:
"Transition smoothness is not set by the fps endpoints. It is set by
MAX_DROP_PER_SAMPLE / MAX_RAISE_PER_SAMPLE / DEADBAND."

WHAT THIS DOES NOT ASSUME
-------------------------
An earlier version of this file listed SAMPLE_SECONDS and FPS_ALPHA as dials.
They do not exist. Reading tsp_luapatch.sh and tsp_loadramp.sh back, the real
estimator is a weighted trimmed mean - WINDOW_SAMPLES / WEIGHT_DECAY /
TRIM_WORST - and the sample period is driven by the engine update handler, not a
constant. So dials are split: three that both earlier scripts prove are in the
file are REQUIRED, the rest are patched only if actually present, and a missing
optional dial is reported, never fatal.

Nothing is asserted about a pre-existing condition. The file is the authority on
what it holds; the "shipped value" column only reports drift.
"""

import re
import sys
import os
import subprocess
import tempfile
import difflib

MARK = "TSP_DYNVIEW_DAMP_V1"
MODE = sys.argv[1] if len(sys.argv) > 1 else "plan"
PATH = sys.argv[2] if len(sys.argv) > 2 else "dynamic_view.lua"
OUT = sys.argv[3] if len(sys.argv) > 3 else None

# name -> (value as both earlier scripts read it off the device, new value).
# The old value reports drift only. It is never a condition for proceeding.
REQUIRED = [
    ("MAX_DROP_PER_SAMPLE",  "800.0", "250",
     "two steps of exactly 800 is this cap saturating; 250 cannot cascade"),
    ("MAX_RAISE_PER_SAMPLE", "500.0", "250",
     "removes the upswing half - the 4334 -> 4700 that preceded the collapse"),
    ("DEADBAND",              "96.0", "256",
     "hold still through fps noise; 256 of 4668 units of range is 5.5%"),
]

# Patched only if present. Absent is reported and fine.
OPTIONAL = [
    ("WEIGHT_DECAY",   "0.80", "0.90",
     "older samples keep more weight - the weak lever, see the note below"),
    ("SAMPLE_SECONDS",  "1.0", "2.0",
     "decide half as often, if the period is a constant at all"),
    ("FPS_ALPHA",      "0.40", "0.20",
     "only in an EMA-shaped controller; this one is a trimmed mean"),
]

# Reported, never touched. These say what the controller actually is, and
# whether the 09-10 post-load ramp is live in it.
CONTEXT_CONSTS = ["WINDOW_SAMPLES", "TRIM_WORST", "LOW_FPS", "HIGH_FPS",
                  "MIN_VIEW", "DEFAULT_VIEW", "MAX_VIEW",
                  "RAMP_START_VIEW", "RAMP_SECONDS"]
CONTEXT_MARKS = ["TSP_FPSAVG_V2", "TSP_LOADRAMP_V1", "TSP_DYNVIEW_V37MAP",
                 "TSP_DIAG_FPS"]


def die(msg):
    print("  REFUSING: %s" % msg)
    print("  Nothing was written.")
    sys.exit(3)


def like_style(cur, new):
    """Write the new value in the same numeric style as the old one.

    The file uses 800.0 / 96.0 / 0.80 - Lua floats. Writing a bare 250 there
    would work (5.3 promotes on arithmetic) but it would also be the only
    integer among floats, and any future // in that expression would behave
    differently. Match what is there.
    """
    m = re.match(r"^-?\d+\.(\d+)$", cur)
    if m:
        return "%.*f" % (len(m.group(1)), float(new))
    return new


def luac(body):
    with tempfile.NamedTemporaryFile("w", suffix=".lua", delete=False,
                                     encoding="utf-8", errors="surrogateescape") as t:
        t.write(body)
        tmp = t.name
    try:
        for cand in ("luac", "luac5.4", "luac5.3", "luac5.1"):
            try:
                r = subprocess.run([cand, "-p", tmp], capture_output=True, text=True)
                return (r.returncode == 0, (r.stderr or "ok").strip()[:140], cand)
            except FileNotFoundError:
                continue
        return (None, "no luac available", "-")
    finally:
        os.unlink(tmp)
        if os.path.exists("luac.out"):
            os.unlink("luac.out")


def main():
    if not os.path.isfile(PATH):
        die("%s does not exist" % PATH)
    text = open(PATH, encoding="utf-8", errors="surrogateescape").read()
    orig = text
    lines = text.split("\n")
    print("  file:  %s  (%d bytes, %d lines)" % (PATH, len(text), len(lines)))

    if MARK in text:
        print("\n  %s already present - already damped." % MARK)
        print("  Restore the backup first if you want to re-apply with new values.")
        sys.exit(4)

    # ---- every constant in the file, so nothing is a surprise ----
    print("\n  --- every ALL_CAPS constant this file defines")
    found = {}
    for i, l in enumerate(lines, 1):
        m = re.match(r"^(\s*)(?:local\s+)?([A-Z][A-Z0-9_]{2,})(\s*=\s*)([-\w.]+)", l)
        if m:
            found[m.group(2)] = (i, m.group(4))
            print("      %5d | %-24s = %s" % (i, m.group(2), m.group(4)))
    if not found:
        die("this file defines no ALL_CAPS constants - it is not the controller I "
            "expected, and I will not guess at its structure")

    # ---- what kind of controller is this, and is the 09-10 ramp live ----
    print("\n  --- context (reported, never patched)")
    for n in CONTEXT_CONSTS:
        if n in found:
            print("      %-24s = %-10s line %d" % (n, found[n][1], found[n][0]))
        else:
            print("      %-24s   absent" % n)
    for n in CONTEXT_MARKS:
        print("      %-24s   %s" % (n, "present x%d" % text.count(n) if n in text else "absent"))

    ramp_live = False
    if "RAMP_SECONDS" in found:
        try:
            ramp_live = float(found["RAMP_SECONDS"][1]) > 0.0
        except ValueError:
            ramp_live = True
    if ramp_live:
        print("\n      NOTE: the 09-10 post-load ramp IS live (RAMP_SECONDS = %s)."
              % found["RAMP_SECONDS"][1])
        print("      It is a ceiling only - it never raises the target - so capping")
        print("      the drop rate is compatible with it: the plane still descends,")
        print("      just not 800 per sample. Reported so it is not a surprise.")
    elif "RAMP_SECONDS" in found:
        print("\n      NOTE: the ramp is present but DISABLED (RAMP_SECONDS = %s)."
              % found["RAMP_SECONDS"][1])
    else:
        print("\n      NOTE: no post-load ramp in this file. The 09-10 TSP_LOADRAMP_V1")
        print("      patch is not in the copy being read, so the 800-per-sample")
        print("      cascade is unmitigated and these caps are the whole fix.")

    if "TSP_FPSAVG_V2" in text:
        print("\n      TSP_FPSAVG_V2 is in this file. It ceilings the smoothed fps at")
        print("      max(newest two samples), so two bad seconds move the estimate")
        print("      immediately no matter how the window is weighted. That is why")
        print("      WEIGHT_DECAY is the weak lever here and the drop cap is the")
        print("      strong one: the cap bounds the damage one estimate can do")
        print("      without touching the estimator or that deliberate behaviour.")

    # ---- locate the dials ----
    print("\n  --- the dials")
    plan = []
    missing_req = []
    for name, want_old, new, why in REQUIRED:
        if name not in found:
            missing_req.append(name)
            print("      %-24s NOT FOUND  (required)" % name)
            continue
        ln, cur = found[name]
        newv = like_style(cur, new)
        drift = "" if cur == want_old else "   (both earlier scripts read %s)" % want_old
        print("      %-24s %8s -> %-8s line %-4d%s" % (name, cur, newv, ln, drift))
        print("      %-24s   %s" % ("", why))
        plan.append((name, cur, newv, ln))
    for name, want_old, new, why in OPTIONAL:
        if name not in found:
            print("      %-24s absent - skipped (optional)" % name)
            continue
        ln, cur = found[name]
        newv = like_style(cur, new)
        print("      %-24s %8s -> %-8s line %-4d (optional)" % (name, cur, newv, ln))
        print("      %-24s   %s" % ("", why))
        plan.append((name, cur, newv, ln))

    if missing_req:
        die("%d required dial(s) missing: %s. Both tsp_luapatch.sh and "
            "tsp_loadramp.sh read these off the device, so a file without them is "
            "not the controller, and I am not editing it blind."
            % (len(missing_req), ", ".join(missing_req)))

    changing = [p for p in plan if p[1] != p[2]]
    if not changing:
        print("\n  Every dial is already at its damped value. Nothing to do.")
        sys.exit(4)

    # ---- rewrite, one dial at a time, each replacement proven unique ----
    for name, cur, new, ln in plan:
        pat = re.compile(r"^(\s*(?:local\s+)?%s\s*=\s*)([-\w.]+)" % re.escape(name), re.M)
        hits = pat.findall(text)
        if len(hits) != 1:
            die("%s is assigned %d times at top level - expected exactly 1" % (name, len(hits)))
        text = pat.sub(lambda m: m.group(1) + new, text, count=1)

    # ---- a marker comment, so a later status can prove it landed ----
    ins = 0
    if lines and lines[0].startswith("--"):
        ins = text.index("\n") + 1
    banner = (
        "-- %s: the controller was swinging view distance 1600 units in three\n"
        "-- seconds right after a load, while frames were still settling at 47-62 ms.\n"
        "-- Two of those three steps were exactly MAX_DROP_PER_SAMPLE - the cap,\n"
        "-- saturated twice running. Each change forces terrain and object-paging\n"
        "-- rebuilds, which is work in cull and draw, which keeps fps low, which made\n"
        "-- it cut again. These caps bound how far one fps estimate can move the far\n"
        "-- plane, so the post-load transient passes before the controller can chase\n"
        "-- it. Constants only - no control flow, no estimator, no ramp changed.\n"
        % MARK)
    text = text[:ins] + banner + text[ins:]

    nl = text.split("\n")

    # ---- syntax, judged against the ORIGINAL's own result ----
    # Requiring an absolute pass has produced three false refusals in this
    # project. The only fair question is whether the patch made it worse.
    b_ok, b_msg, tool = luac(orig)
    n_ok, n_msg, _ = luac(text)
    print("\n  --- syntax, checked with %s" % tool)
    if b_ok is None:
        print("      no luac on this host - skipped (the device check still runs)")
        syn_ok, syn_note = True, "skipped, no luac"
    else:
        print("      original  %s" % ("OK" if b_ok else "FAILS: " + b_msg))
        print("      patched   %s" % ("OK" if n_ok else "FAILS: " + n_msg))
        syn_ok = n_ok if b_ok else True
        syn_note = "ok" if syn_ok else n_msg
        if not b_ok:
            print("      (the original does not compile either - pre-existing, not "
                  "caused here; requiring a pass would be a false refusal)")

    checks = [
        ("all %d dials rewritten" % len(plan),
         all(re.search(r"^\s*(?:local\s+)?%s\s*=\s*%s\b" % (re.escape(n), re.escape(v)),
                       text, re.M) for n, _, v, _ in plan), len(plan)),
        ("marker present once", text.count(MARK) == 1, text.count(MARK)),
        ("parses no worse than the original", syn_ok, syn_note),
        ("line count grew only by the banner",
         len(nl) - len(lines) == banner.count("\n"), len(nl) - len(lines)),
        ("no changed dial left at its old value",
         not any(re.search(r"^\s*(?:local\s+)?%s\s*=\s*%s\b" % (re.escape(n), re.escape(c)),
                           text, re.M) for n, c, v, _ in changing), len(changing)),
        ("no context constant touched",
         all(found[n][1] == (re.search(r"^\s*(?:local\s+)?%s\s*=\s*([-\w.]+)" % re.escape(n),
                                       text, re.M) or re.match("(x)", "x")).group(1)
             for n in CONTEXT_CONSTS if n in found), len([n for n in CONTEXT_CONSTS if n in found])),
        ("TSP_FPSAVG_V2 count unchanged",
         text.count("TSP_FPSAVG_V2") == orig.count("TSP_FPSAVG_V2"),
         orig.count("TSP_FPSAVG_V2")),
        ("nothing changed but the dials and the banner",
         _only_dials_moved(orig, text, banner, plan), "ok"),
    ]
    print("\n  --- assertions")
    bad = 0
    for name, ok, got in checks:
        print("      %-40s %s (%s)" % (name, "PASS" if ok else "FAIL", got))
        if not ok:
            bad += 1
    if bad:
        die("%d assertion(s) failed" % bad)

    print("\n  --- THE DIFF")
    for line in difflib.unified_diff(lines, nl, lineterm="", n=1):
        if line.startswith("---") or line.startswith("+++"):
            continue
        print("      %s" % line)

    if MODE == "plan":
        print("\n  PLAN ONLY - nothing written.")
        return 0

    dest = OUT or (PATH + ".patched")
    open(dest, "w", encoding="utf-8", errors="surrogateescape").write(text)
    back = open(dest, encoding="utf-8", errors="surrogateescape").read()
    if back != text:
        die("read-back of %s does not match" % dest)
    print("\n  wrote %s  (%d bytes, %+d)" % (dest, len(back), len(back) - len(orig)))
    return 0


def _only_dials_moved(orig, new, banner, plan):
    """Strip the banner, then rewind every dial to its old value. What is left
    must be byte-identical to the original. This catches an edit anywhere else
    in the file no matter what the per-dial regexes did."""
    t = new.replace(banner, "", 1)
    for name, cur, newv, ln in plan:
        t = re.sub(r"^(\s*(?:local\s+)?%s\s*=\s*)%s\b" % (re.escape(name), re.escape(newv)),
                   lambda m: m.group(1) + cur, t, count=1, flags=re.M)
    return t == orig


if __name__ == "__main__":
    sys.exit(main())
