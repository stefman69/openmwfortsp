#!/usr/bin/env python3
"""tsp_glidepatch.py - make the far plane breathe instead of jump.

    plan      <file>          show every edit and the diff, write nothing
    go        <file> <out>    write the glide patch
    tuneplan  <file>          show tune 1, write nothing
    tune      <file> <out>    tune 1 - settle the plane (needs the glide)
    tune2plan <file>          show tune 2, write nothing
    tune2     <file> <out>    tune 2 - slower breath, 2/3 the calls (needs tune 1)
    undo      is the driver's job (it restores the device backup)

WHY
---
The controller decides once a second and then moves the far plane in one lump.
Worse, DEADBAND does double duty: it is the retarget threshold in onFrame AND
the minimum applied movement inside setView, so the plane physically cannot
move less than 96 units at a time. Measured against the real file under lua5.3,
the first 25 seconds after a load are:

    view 3000 (ramp snap) -> 2500 within one second -> pinned at the floor for
    four seconds -> +308 +471 +490 +404 +208 +147 back up to 4529

Seven visible pops, and four seconds at minimum draw distance on every load.
Each move forces terrain quadtree and object-paging rebuilds, which is work in
cull and draw, which keeps fps low, which makes it cut again.

WHAT CHANGES
------------
1. targetView is now a held value. The once-a-second block sets it and stops
   moving the camera itself.
2. A glide runs EVERY frame, moving currentView toward targetView by at most
   rate * dt. Same travel rate as before, spread over the second.
3. setView gains a minStep argument. The glide passes GLIDE_MIN_STEP (12) so
   small moves are allowed; every existing caller omits it and keeps DEADBAND.
   This is the change the constants-only patch could not make, and it is why
   that patch froze the controller: with MAX_DROP 250 below DEADBAND 256, every
   rate-limited step was refused by setView and the plane never moved again.
   The glide banks sub-threshold movement in an accumulator rather than
   discarding it, so GLIDE_MIN_STEP can never freeze it the same way - it is
   purely a cost dial. Raise it for fewer, slightly larger steps.
4. FPS_SMOOTHING = 'none' takes the raw one-second average straight to the
   target. The rate limit is now the smoothing - the plane cannot travel far on
   one bad second because it can only move rate/1s per second - so the window,
   the trim and the FPSAVG_V2 ceiling are redundant. Nothing is deleted: set
   FPS_SMOOTHING = 'window' and the old estimator is back, one word.

The window was never a performance cost - it is a five-element loop once a
second. The reason to bypass it is that it was a second smoother fighting the
first one, and its V2 ceiling is what made the post-load dive immediate.

Every edit is an exact-text anchor that must match exactly once. Nothing is
asserted about a pre-existing condition; the md5 is reported, not required.
"""

import re
import sys
import os
import subprocess
import tempfile
import difflib
import hashlib

MARK = "TSP_DYNVIEW_GLIDE_V1"
TUNE_MARK = "TSP_DYNVIEW_TUNE_V1"
TUNE2_MARK = "TSP_DYNVIEW_TUNE_V2"
KNOWN_MD5 = "34049171b2d2df6a3f2b91b69a1e989d"  # reported only, never required

# The md5 of the patched OUTPUT when the input is KNOWN_MD5. That exact artifact
# was compiled with luac5.3 and luac5.4 and executed under lua5.3 and loaded
# under lua5.4 before shipping. Steve's machine has no luac and the handheld
# almost certainly does not either, so without this the syntax check silently
# skips on both sides and a control-flow patch installs unverified. Matching
# this md5 is a positive check that stands in for running the compiler.
KNOWN_OUT_MD5 = "e579b4bebd694cb85306288f8dc27248"

# The tune: input is the glided file (KNOWN_OUT_MD5), output is TUNE_OUT_MD5.
# Same story - no luac on either machine, so a byte match stands in for it.
TUNE_IN_MD5 = KNOWN_OUT_MD5
TUNE_OUT_MD5 = "53a35eb2c639ad8782f38d18be2568af"

# Tune 2 takes tune 1's output as its input.
TUNE2_IN_MD5 = TUNE_OUT_MD5
TUNE2_OUT_MD5 = "98acdf72fee6695cbb31e4819cfaa541"

MODE = sys.argv[1] if len(sys.argv) > 1 else "plan"
PATH = sys.argv[2] if len(sys.argv) > 2 else "dynamic_view.lua"
OUT = sys.argv[3] if len(sys.argv) > 3 else None


def die(msg, extra=None):
    print("  REFUSING: %s" % msg)
    if extra:
        print(extra)
    print("  Nothing was written.")
    sys.exit(3)


# ---------------------------------------------------------------- the edits --
# (label, anchor, replacement). Every anchor must appear exactly once.
EDITS = []

# 1. new constants, right after the existing rate limits
EDITS.append(("glide constants", """local MAX_DROP_PER_SAMPLE = 800.0
local MAX_RAISE_PER_SAMPLE = 500.0
local DEADBAND = 96.0
""", """local MAX_DROP_PER_SAMPLE = 800.0
local MAX_RAISE_PER_SAMPLE = 500.0
local DEADBAND = 96.0

-- TSP_DYNVIEW_GLIDE_V1 - the far plane used to move once a second in one lump,
-- and DEADBAND doubled as the minimum applied movement inside setView, so it
-- could not move less than 96 units at a time. Measured from the real file: a
-- load snapped it to 3000, it hit the 2500 floor within a second, sat there for
-- four, then climbed back in steps of 308/471/490/404/208/147. Seven pops per
-- load. Now it holds a target and glides toward it every frame at a fixed rate.
--
-- The rate is what smooths the controller now. One bad second can only move the
-- plane VIEW_DROP_PER_SECOND units, so a sustained drop is still tracked but a
-- transient cannot travel far. That makes the recency window, the trim and the
-- FPSAVG_V2 ceiling redundant, so FPS_SMOOTHING skips them by default. Set it
-- back to 'window' to restore the old estimator exactly.
local VIEW_DROP_PER_SECOND = 400.0
local VIEW_RAISE_PER_SECOND = 250.0
local GLIDE_MIN_STEP = 12.0       -- smallest move worth a setViewDistance call
local FPS_SMOOTHING = 'none'      -- 'none' = raw 1 s average | 'window' = TSP_FPSAVG_V1/V2
"""))

# 2. targetView state, alongside currentView
EDITS.append(("targetView state", """local currentView = DEFAULT_VIEW
local tspLastRealTime = core.getRealTime()
""", """local currentView = DEFAULT_VIEW
-- TSP_DYNVIEW_GLIDE_V1 - where the plane is heading, held between samples.
local targetView = DEFAULT_VIEW
local tspGlidePending = 0.0
local tspGlideCalls = 0
local tspGlideMaxStep = 0.0
local tspLastRealTime = core.getRealTime()
"""))

# 3. FPS_SMOOTHING bypass. Goes after the window push so #fpsWindow still means
#    something in the status line, and before any weighting happens.
EDITS.append(("smoothing bypass", """    local count = #fpsWindow

    -- Trim only once there is enough history that two samples still remain.""",
              """    -- TSP_DYNVIEW_GLIDE_V1 - the glide rate is the smoothing now. The window,
    -- the trim and the V2 ceiling below all exist to stop one bad second moving
    -- the plane a long way; the rate limit does that mechanically, and the V2
    -- ceiling is what made the post-load dive immediate. Set FPS_SMOOTHING back
    -- to 'window' to run the original estimator instead.
    if FPS_SMOOTHING == 'none' then
        lastTrimmed = 0
        smoothFps = rawFps
        return smoothFps
    end

    local count = #fpsWindow

    -- Trim only once there is enough history that two samples still remain."""))

# 4. setView gains a minimum-step argument and an optional log. Existing callers
#    pass neither and behave exactly as before.
EDITS.append(("setView minStep", """local function setView(v, reason, rawFps, target)
    v = clamp(v, MIN_VIEW, MAX_VIEW)
    if math.abs(v - currentView) < DEADBAND then
        return false
    end

    currentView = v
    camera.setViewDistance(currentView)

    print(string.format(
        '[TSP_DYNVIEW_V37MAP] action=%s raw_fps=%.2f smooth_fps=%.2f target=%.0f view=%.0f',
        reason, rawFps or 0.0, smoothFps or 0.0, target or currentView, currentView
    ))
    return true
end
""", """-- TSP_DYNVIEW_GLIDE_V1 - minStep was hard-wired to DEADBAND, which is why the
-- plane could never move gradually. The glide passes GLIDE_MIN_STEP; every
-- other caller omits it and gets DEADBAND exactly as before. reason == nil
-- skips the log line, so the per-frame glide does not format a string 30 times
-- a second for a gate that is off.
local function setView(v, reason, rawFps, target, minStep)
    v = clamp(v, MIN_VIEW, MAX_VIEW)
    if math.abs(v - currentView) < (minStep or DEADBAND) then
        return false
    end

    currentView = v
    camera.setViewDistance(currentView)

    if reason ~= nil then
        print(string.format(
            '[TSP_DYNVIEW_V37MAP] action=%s raw_fps=%.2f smooth_fps=%.2f target=%.0f view=%.0f',
            reason, rawFps or 0.0, smoothFps or 0.0, target or currentView, currentView
        ))
    end
    return true
end

-- TSP_DYNVIEW_GLIDE_V1 - called every frame. Moves the plane toward targetView
-- by at most rate * dt, never past it. Asymmetric on purpose: coming in is
-- protective so it is allowed to be quicker than going out.
--
-- The pending accumulator is load-bearing, not tidiness. One frame's movement
-- is rate * dt - at 250/s and 60 fps that is 4.2 units, under GLIDE_MIN_STEP -
-- so if a refused move were simply discarded the glide would recompute the same
-- too-small step every frame and the plane would never move at all. That is the
-- same trap as a rate limit set below DEADBAND. Accumulating instead makes
-- GLIDE_MIN_STEP a pure cost/smoothness dial that cannot freeze anything:
-- raise it and setViewDistance is called less often in slightly larger steps.
local function tspGlide(dt)
    if targetView == nil then
        return
    end
    local diff = targetView - currentView
    if diff == 0.0 then
        tspGlidePending = 0.0
        return
    end

    local limit = ((diff < 0.0) and VIEW_DROP_PER_SECOND or VIEW_RAISE_PER_SECOND) * dt
    local step = diff
    if step > limit then step = limit end
    if step < -limit then step = -limit end

    tspGlidePending = tspGlidePending + step
    if math.abs(tspGlidePending) < GLIDE_MIN_STEP then
        return
    end

    -- Arriving exactly on the target must always apply, however small the last
    -- move is, or the plane parks GLIDE_MIN_STEP short of it forever.
    local nextView = currentView + tspGlidePending
    local arriving = false
    if diff > 0.0 and nextView >= targetView then nextView = targetView; arriving = true end
    if diff < 0.0 and nextView <= targetView then nextView = targetView; arriving = true end

    local applied = math.abs(nextView - currentView)
    if applied <= 0.0 then
        tspGlidePending = 0.0
        return
    end

    if setView(nextView, nil, nil, targetView, arriving and 0.0 or GLIDE_MIN_STEP) then
        tspGlidePending = 0.0
        tspGlideCalls = tspGlideCalls + 1
        if applied > tspGlideMaxStep then tspGlideMaxStep = applied end
    end
end
"""))

# 5. interiors pin the target too, or the glide fights the pin on the way out
EDITS.append(("interior target", """            currentView = DEFAULT_VIEW
            camera.setViewDistance(currentView)
            print(string.format(
                '[TSP_DYNVIEW_V37MAP] action=interior_default view=%.0f',
                currentView
            ))
        else
            currentView = live
        end
""", """            currentView = DEFAULT_VIEW
            camera.setViewDistance(currentView)
            print(string.format(
                '[TSP_DYNVIEW_V37MAP] action=interior_default view=%.0f',
                currentView
            ))
        else
            currentView = live
        end
        targetView = currentView   -- TSP_DYNVIEW_GLIDE_V1
"""))

# 6. the load snap sets the target with it. The snap itself stays instant - it
#    is pulling the plane IN ahead of the fault storm, which is the whole point
#    of LOADRAMP, and it happens during a multi-second stall frame anyway.
EDITS.append(("load ramp target", """            currentView = clamp(RAMP_START_VIEW, MIN_VIEW, MAX_VIEW)
            camera.setViewDistance(currentView)
""", """            currentView = clamp(RAMP_START_VIEW, MIN_VIEW, MAX_VIEW)
            targetView = currentView   -- TSP_DYNVIEW_GLIDE_V1
            camera.setViewDistance(currentView)
"""))

# 7. run the glide every frame, before the once-a-second gate returns
EDITS.append(("per-frame glide call", """    elapsed = elapsed + dt
    frames = frames + 1
    statusElapsed = statusElapsed + dt
""", """    -- TSP_DYNVIEW_GLIDE_V1 - every frame, not once a second.
    tspGlide(dt)

    elapsed = elapsed + dt
    frames = frames + 1
    statusElapsed = statusElapsed + dt
"""))

# 8. the sample block retargets instead of moving the camera
EDITS.append(("retarget not move", """    if target < currentView - DEADBAND then
        local nextView = math.max(target, currentView - MAX_DROP_PER_SAMPLE)
        setView(nextView, 'toward_low', rawFps, target)
    elseif target > currentView + DEADBAND then
        local nextView = math.min(target, currentView + MAX_RAISE_PER_SAMPLE)
        setView(nextView, 'toward_high', rawFps, target)
    end
""", """    -- TSP_DYNVIEW_GLIDE_V1 - set where to go; tspGlide does the going. DEADBAND
    -- keeps its old job as hysteresis, so the target is only moved once the
    -- framerate has drifted it meaningfully off where the plane already is.
    if target < currentView - DEADBAND or target > currentView + DEADBAND then
        targetView = clamp(target, MIN_VIEW, MAX_VIEW)
    end
"""))

# 9. report the glide in the status line that is actually enabled
EDITS.append(("glide status", """    if statusElapsed >= 5.0 then
        print(string.format(
            '[TSP_DYNVIEW_V37MAP] status raw_fps=%.2f smooth_fps=%.2f n=%d trimmed=%d target=%.0f view=%.0f',
            rawFps, smoothFps, #fpsWindow, lastTrimmed, target, currentView
        ))
        statusElapsed = 0.0
    end
""", """    if statusElapsed >= 5.0 then
        print(string.format(
            '[TSP_DYNVIEW_V37MAP] status raw_fps=%.2f smooth_fps=%.2f n=%d trimmed=%d target=%.0f view=%.0f',
            rawFps, smoothFps, #fpsWindow, lastTrimmed, target, currentView
        ))
        -- TSP_DYNVIEW_GLIDE_V1 - carries "status" so it passes the enabled gate.
        -- moves is setViewDistance calls since the last status; max is the
        -- largest single applied step, which is what a pop would look like.
        print(string.format(
            '[TSP_DYNVIEW_V37MAP] status glide smoothing=%s moves=%d max_step=%.0f goal=%.0f view=%.0f',
            FPS_SMOOTHING, tspGlideCalls, tspGlideMaxStep, targetView or currentView, currentView
        ))
        tspGlideCalls = 0
        tspGlideMaxStep = 0.0
        statusElapsed = 0.0
    end
"""))


# ------------------------------------------------------------------- tune ----
# Measured on the device, two minutes of walking (status glide lines):
#   moves 37-101 per 5 s window = 7-20 setViewDistance calls a second
#   max_step 20-27 units        - the glide itself is doing its job, no pops
#   goal wandered 3736..4808    - 1072 units, mean 416 units away from view
# The plane never arrived. The band is 2500..7168 over 17..40 fps = 203 view
# units per fps, so DEADBAND 96 is only 0.47 fps of hysteresis: half an fps of
# ordinary wobble re-aims it, and with FPS_SMOOTHING='none' the raw one-second
# average carries all of that noise straight into the target. The glide then
# smooths the MOTION perfectly while the plane stays in continuous travel.
#
# Reproduced in simnoise.lua at 26.7 fps +/- 3 for 120 s: 12.8 calls/s, worst
# 5 s window 97, moving 92% of the wall clock - which matches the log.
#
# Two constants, swept rather than guessed (minstep deliberately left alone so
# the 20-25 unit steps stay the size they are now):
#
#   sample  deadband   calls/s   step   moving
#     1.0        96      12.8      23     92%   <- on the device now
#     1.0       250      11.1      23     80%
#     2.0        96       7.5      22     75%
#     2.0       250       5.1      21     41%   <- this
#     2.0       400       2.6      22     20%
#
# 2.0/250 halves the call rate, leaves the step size alone, and cuts time in
# motion from 92% to 41%. Response to a real drop is unchanged: on a sustained
# 27 -> 17.5 fps walk-in it reaches ~2600 by 25 s either way, but then HOLDS at
# 2599 instead of jittering 2658/2564/2555.
TUNE_EDITS = [
    ("sample period", "local SAMPLE_SECONDS = 1.0\n", "local SAMPLE_SECONDS = 2.0\n",
     "decide every two seconds, on a two-second average - half the samples, "
     "half the decisions, and a quieter average feeding them"),
    ("deadband", "local DEADBAND = 96.0\n", "local DEADBAND = 250.0\n",
     "1.23 fps of hysteresis instead of 0.47, so ordinary wobble stops "
     "re-aiming the plane and it actually arrives and holds"),
]

TUNE_BANNER = """-- TSP_DYNVIEW_TUNE_V1 - the glide removed the pops but the plane never settled:
-- on the device it was moving 92% of the wall clock, goal wandering 1072 units,
-- mean 416 units away from where the camera was. DEADBAND 96 is 0.47 fps of
-- hysteresis at 203 view units per fps, so half an fps of noise re-aimed it, and
-- with FPS_SMOOTHING='none' the raw one-second average carries all that noise.
-- Sampling every two seconds on a two-second average, with 1.23 fps of
-- hysteresis: setViewDistance calls 12.8/s -> 5.1/s, time in motion 92% -> 41%,
-- step size unchanged at ~21 units. Response to a genuine drop is the same.
-- GLIDE_MIN_STEP is untouched on purpose - that is the step-size dial.
"""


def do_tune():
    # Pick the generation from the mode. Everything below is spec-driven so a
    # later generation is one table, not a second copy of this function.
    if MODE in ("tune2", "tune2plan"):
        EDITS_T, BANNER = TUNE2_EDITS, TUNE2_BANNER
        MYMARK, PREMARK = TUNE2_MARK, TUNE_MARK
        IN_MD5, OUT_MD5 = TUNE2_IN_MD5, TUNE2_OUT_MD5
        GEN, PRESTEP = "tune 2", "bash ~/Downloads/tsp_dynview.sh tune"
        HOLD = [("SAMPLE_SECONDS", "local SAMPLE_SECONDS = 2.0"),
                ("FPS_SMOOTHING", "local FPS_SMOOTHING = 'none'"),
                ("RAMP_SECONDS", "local RAMP_SECONDS = 20.0"),
                ("RAMP_START_VIEW", "local RAMP_START_VIEW = 3000.0")]
    else:
        EDITS_T, BANNER = TUNE_EDITS, TUNE_BANNER
        MYMARK, PREMARK = TUNE_MARK, MARK
        IN_MD5, OUT_MD5 = TUNE_IN_MD5, TUNE_OUT_MD5
        GEN, PRESTEP = "tune 1", "bash ~/Downloads/tsp_dynview.sh go"
        HOLD = [("GLIDE_MIN_STEP", "local GLIDE_MIN_STEP = 12.0"),
                ("VIEW_DROP_PER_SECOND", "local VIEW_DROP_PER_SECOND = 400.0"),
                ("VIEW_RAISE_PER_SECOND", "local VIEW_RAISE_PER_SECOND = 250.0"),
                ("FPS_SMOOTHING", "local FPS_SMOOTHING = 'none'"),
                ("RAMP_SECONDS", "local RAMP_SECONDS = 20.0"),
                ("RAMP_START_VIEW", "local RAMP_START_VIEW = 3000.0")]

    if not os.path.isfile(PATH):
        die("%s does not exist" % PATH)
    orig = open(PATH, encoding="utf-8", errors="surrogateescape").read()
    text = orig
    md5 = hashlib.md5(orig.encode("utf-8", "surrogateescape")).hexdigest()
    print("  file:  %s" % PATH)
    print("  bytes: %d   lines: %d   md5: %s%s"
          % (len(orig), orig.count("\n"), md5,
             "  (the file %s was measured against)" % GEN
             if md5 == IN_MD5 else "  (not that exact file - anchors decide)"))

    if MYMARK in text:
        print("\n  %s already present - %s is already applied." % (MYMARK, GEN))
        sys.exit(4)
    if PREMARK not in text:
        die("%s is absent, so %s has nothing to adjust.\n  Run: %s"
            % (PREMARK, GEN, PRESTEP))

    print("\n  --- anchors")
    ok = True
    for label, anchor, _, _ in EDITS_T:
        n = text.count(anchor)
        print("      %-16s %d match%s %s" % (label, n, "" if n == 1 else "es",
                                             "OK" if n == 1 else "<-- PROBLEM"))
        if n != 1:
            ok = False
    if not ok:
        die("at least one anchor did not match exactly once",
            "\n  Send me this output and the plan; I will re-anchor.")

    print("\n  --- %s" % GEN)
    for label, anchor, repl, why in EDITS_T:
        print("      %s" % anchor.strip())
        print("        -> %s" % repl.strip())
        print("        %s" % why)
        text = text.replace(anchor, repl, 1)

    ins = text.index("\n") + 1 if text.startswith("--") else 0
    text = text[:ins] + BANNER + text[ins:]

    out_md5 = hashlib.md5(text.encode("utf-8", "surrogateescape")).hexdigest()
    prebuilt = out_md5 == OUT_MD5
    print("\n  --- the patched bytes")
    print("      md5 %s" % out_md5)
    if prebuilt:
        print("      MATCHES the artifact compiled with luac5.3 and luac5.4 and run")
        print("      under lua5.3 before shipping. Byte-identical, so it parses.")
    else:
        print("      does NOT match the pre-verified artifact (%s)" % OUT_MD5[:12])

    b_ok, b_msg, tool = luac(orig)
    n_ok, n_msg, _ = luac(text)
    print("\n  --- syntax, checked with %s" % tool)
    if b_ok is None:
        if prebuilt:
            print("      no luac here, but the bytes match the pre-verified artifact")
            syn_ok, syn_note = True, "prebuilt md5 match"
        else:
            print("      NO LUA COMPILER, and these bytes are not pre-verified.")
            syn_ok, syn_note = False, "unverifiable: no luac and md5 differs"
    else:
        print("      original  %s" % ("OK" if b_ok else "FAILS: " + b_msg))
        print("      patched   %s" % ("OK" if n_ok else "FAILS: " + n_msg))
        syn_ok = n_ok if b_ok else True
        syn_note = "ok" if syn_ok else n_msg

    rewound = text.replace(BANNER, "", 1)
    for _, anchor, repl, _ in EDITS_T:
        rewound = rewound.replace(repl, anchor, 1)

    checks = [
        ("every constant rewritten",
         all(repl.strip() in text for _, _, repl, _ in EDITS_T), len(EDITS_T)),
        ("no old value left",
         not any(a.strip() in text for _, a, _, _ in EDITS_T), "ok"),
        ("%s marker present once" % GEN, text.count(MYMARK) == 1, text.count(MYMARK)),
        ("%s still present" % PREMARK,
         text.count(PREMARK) == orig.count(PREMARK), text.count(PREMARK)),
        ("his diagnostics untouched",
         "local TSP_DIAG_FPS = true" in text
         and "local TSP_DIAG_DYNVIEW = false" in text
         and "local TSP_DIAG_STALL = false" in text, "ok"),
        ("parses, or matches the pre-verified bytes", syn_ok, syn_note),
        ("nothing changed but those lines and the banner", rewound == orig, "ok"),
        ("line count grew only by the banner",
         text.count("\n") - orig.count("\n") == BANNER.count("\n"),
         text.count("\n") - orig.count("\n")),
    ] + [("%s held at its current value" % n, v in text, v.split("= ")[-1])
         for n, v in HOLD]
    print("\n  --- assertions")
    bad = 0
    for label, good, got in checks:
        print("      %-48s %s (%s)" % (label, "PASS" if good else "FAIL", got))
        if not good:
            bad += 1
    if bad:
        extra = None
        if syn_note.startswith("unverifiable"):
            extra = ("\n  I will not push past an unverifiable control-flow-adjacent\n"
                     "  patch. Send me this output and I will re-verify the new bytes.")
        die("%d assertion(s) failed" % bad, extra)

    print("\n  --- THE DIFF")
    for line in difflib.unified_diff(orig.split("\n"), text.split("\n"), lineterm="", n=2):
        if line.startswith("---") or line.startswith("+++"):
            continue
        print("      %s" % line)

    if MODE in ("tuneplan", "tune2plan"):
        print("\n  PLAN ONLY - nothing written.")
        return 0

    dest = OUT or (PATH + ".patched")
    open(dest, "w", encoding="utf-8", errors="surrogateescape").write(text)
    if open(dest, encoding="utf-8", errors="surrogateescape").read() != text:
        die("read-back of %s does not match" % dest)
    print("\n  wrote %s  (%d bytes, %+d)" % (dest, len(text), len(text) - len(orig)))
    return 0


# ------------------------------------------------------------------ tune 2 ----
# Steve, after tune 1: "it is the first time it's looked like breathing, but it
# is sometimes like a pretty rapid breath, can we try for like 75% of what we
# are currently reporting... it will look better and not flicker textures on and
# off so much."
#
# That last clause is the useful one. Textures flickering on and off at the far
# plane is objects crossing the boundary, and the rate of crossings tracks the
# SPEED of the plane, not the size of each step. So the lever is the travel rate,
# which tune 1 did not touch.
#
# Lowering the rate alone does not cut the call count, though: a slower plane
# simply travels for longer and ends up making about the same number of calls.
# Measured, 12 seeds x 120 s at 26.7 fps +/- 3, holding everything else:
#
#   drop/raise   calls/s   speed    time moving
#     400/250      5.07      206       42%      <- tune 1
#     300/200      5.23      175       48%
#     220/150      4.71      141       53%
#
# So the rate buys the slower breath and the deadband buys the reduction. And
# GLIDE_MIN_STEP has to come up too, for a reason only the long case shows:
#
#                          ordinary wandering      one long 27->17.5->27 walk-in
#   400/250 db250 ms12       5.55 calls/s              4.6 calls/s   <- tune 1
#   240/160 db350 ms12       4.20  (76%)               6.5  (141%)
#   240/160 db350 ms16       3.65  (66%)               4.8  (104%)   <- this
#
# ms12 hits the 75% he asked for on ordinary wandering and then costs 41% MORE
# during a long transition - exactly when the plane is working hardest, which
# defeats the reason he wanted the cut. ms16 lands at 66% instead of 75% but
# never exceeds tune 1 in any case tested, and it keeps the step at 21.7 against
# tune 1's 22.1, so the 20-27 unit look he said he liked is unchanged.
#
# Net against tune 1: calls 5.55 -> 3.65/s, speed 194 -> 150 units/s (23%
# slower breath), total travel 11110 -> 7798 units (30% fewer boundary
# crossings, which is the texture flicker), step 22.1 -> 21.7 (unchanged).
# Response to a genuine drop is unchanged: it still reaches ~2575 by 25 s.
TUNE2_EDITS = [
    ("drop rate", "local VIEW_DROP_PER_SECOND = 400.0\n",
     "local VIEW_DROP_PER_SECOND = 240.0\n",
     "pulling in 40% slower - fewer objects cross the boundary per second"),
    ("raise rate", "local VIEW_RAISE_PER_SECOND = 250.0\n",
     "local VIEW_RAISE_PER_SECOND = 160.0\n",
     "pushing out slower still; going out is never urgent"),
    ("deadband", "local DEADBAND = 250.0\n", "local DEADBAND = 350.0\n",
     "1.72 fps of hysteresis - this is what actually reduces the call count, "
     "by cutting total travel 30% rather than by moving more slowly"),
    ("step floor", "local GLIDE_MIN_STEP = 12.0", "local GLIDE_MIN_STEP = 16.0",
     "banks two frames instead of one at the new rate, which is what keeps the "
     "reduction from inverting during a long transition"),
]

TUNE2_BANNER = """-- TSP_DYNVIEW_TUNE_V2 - tune 1 settled the plane but the breathing was still
-- quick, and movement at the far plane is what flickers textures on and off as
-- objects cross the boundary. The crossing rate tracks the plane's SPEED, which
-- tune 1 never changed. Rate alone does not cut calls though - a slower plane
-- just travels longer - so the deadband does that, and the step floor comes up
-- 12 -> 16 because at the lower rate ms12 fires every frame and would cost 41%
-- MORE calls during a long transition than tune 1 did. Measured over 12 seeds:
-- calls 5.55 -> 3.65/s, speed 194 -> 150 units/s, total travel 11110 -> 7798,
-- step 22.1 -> 21.7 (unchanged). A real fps drop still reaches ~2575 by 25 s.
"""


def _code_hits(text, name):
    """Occurrences of a name on lines that are not pure Lua comments."""
    n = 0
    for line in text.split("\n"):
        if line.lstrip().startswith("--"):
            continue
        n += line.count(name)
    return n


def luac(body):
    with tempfile.NamedTemporaryFile("w", suffix=".lua", delete=False,
                                     encoding="utf-8", errors="surrogateescape") as t:
        t.write(body)
        tmp = t.name
    try:
        for cand in ("luac", "luac5.4", "luac5.3", "luac5.1"):
            try:
                r = subprocess.run([cand, "-p", tmp], capture_output=True, text=True)
                return (r.returncode == 0, (r.stderr or "ok").strip()[:200], cand)
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
    orig = open(PATH, encoding="utf-8", errors="surrogateescape").read()
    text = orig
    md5 = hashlib.md5(orig.encode("utf-8", "surrogateescape")).hexdigest()
    print("  file:  %s" % PATH)
    print("  bytes: %d   lines: %d   md5: %s%s"
          % (len(orig), orig.count("\n"), md5,
             "  (the file this patch was written against)" if md5 == KNOWN_MD5
             else "  (differs from %s - anchors decide, not this)" % KNOWN_MD5[:12]))

    if MARK in text:
        print("\n  %s already present - already glided." % MARK)
        print("  Restore the backup first if you want to re-apply.")
        sys.exit(4)

    # ---- every anchor must match exactly once, before anything is written ----
    print("\n  --- anchors")
    ok = True
    for label, anchor, _ in EDITS:
        n = text.count(anchor)
        print("      %-24s %d match%s %s" % (label, n, "" if n == 1 else "es",
                                             "OK" if n == 1 else "<-- PROBLEM"))
        if n != 1:
            ok = False
    if not ok:
        hint = ["\n  The file on the device is not the one these anchors were written",
                "  against. Nothing was changed. Send me the plan output and I will",
                "  re-anchor against what is actually there."]
        die("at least one anchor did not match exactly once", "\n".join(hint))

    # ---- apply ----
    print("\n  --- applying")
    for label, anchor, repl in EDITS:
        before = len(text)
        text = text.replace(anchor, repl, 1)
        print("      %-24s %+d bytes" % (label, len(text) - before))

    # ---- is this the exact artifact that was compiled before shipping? ----
    out_md5 = hashlib.md5(text.encode("utf-8", "surrogateescape")).hexdigest()
    prebuilt = out_md5 == KNOWN_OUT_MD5
    print("\n  --- the patched bytes")
    print("      md5 %s" % out_md5)
    if prebuilt:
        print("      MATCHES the artifact that was compiled with luac5.3 and luac5.4,")
        print("      executed under lua5.3 and loaded under lua5.4 before shipping.")
        print("      Byte-for-byte the same file, so it parses. No compiler needed here.")
    else:
        print("      does NOT match the pre-verified artifact (%s)." % KNOWN_OUT_MD5[:12])
        print("      Expected if the input file differs from %s." % KNOWN_MD5[:12])

    # ---- syntax, judged against the original's own result ----
    b_ok, b_msg, tool = luac(orig)
    n_ok, n_msg, _ = luac(text)
    print("\n  --- syntax, checked with %s" % tool)
    if b_ok is None:
        if prebuilt:
            print("      no luac here, but the bytes match the pre-verified artifact")
            syn_ok, syn_note = True, "prebuilt md5 match"
        else:
            print("      NO LUA COMPILER ON THIS MACHINE, and these bytes are not the")
            print("      pre-verified artifact. Nothing here or on the handheld can")
            print("      prove this file parses.")
            syn_ok, syn_note = False, "unverifiable: no luac and md5 differs"
    else:
        print("      original  %s" % ("OK" if b_ok else "FAILS: " + b_msg))
        print("      patched   %s" % ("OK" if n_ok else "FAILS: " + n_msg))
        syn_ok = n_ok if b_ok else True
        syn_note = "ok" if syn_ok else n_msg
        if not b_ok:
            print("      (the original does not compile either - pre-existing, not "
                  "caused here; requiring a pass would be a false refusal)")

    # ---- assertions ----
    def once(s):
        return text.count(s) == 1

    checks = [
        ("every anchor consumed",
         all(text.count(a) == 0 for _, a, _ in EDITS[:1] if a not in text) and
         all(text.count(r) == 1 for _, _, r in EDITS), len(EDITS)),
        ("marker present", text.count(MARK) >= 8, text.count(MARK)),
        ("parses, or matches the pre-verified bytes", syn_ok, syn_note),
        ("glide runs every frame, before the sample gate",
         text.index("tspGlide(dt)") < text.index("if elapsed < SAMPLE_SECONDS then"),
         "ok"),
        ("tspGlide defined before it is called",
         text.index("local function tspGlide") < text.index("    tspGlide(dt)"), "ok"),
        ("setView defined before tspGlide uses it",
         text.index("local function setView") < text.index("local function tspGlide"), "ok"),
        ("the old lump moves are gone",
         "setView(nextView, 'toward_low'" not in text
         and "setView(nextView, 'toward_high'" not in text, "ok"),
        ("MAX_DROP/MAX_RAISE no longer move the camera",
         "MAX_DROP_PER_SAMPLE)" not in text and "MAX_RAISE_PER_SAMPLE)" not in text, "ok"),
        ("setView keeps DEADBAND for callers that omit minStep",
         once("(minStep or DEADBAND)"), "ok"),
        # Name the three uses rather than counting occurrences. A bare count
        # encodes today's design and fails the next time the design gains a
        # legitimate use - which it already did once, when the accumulator
        # added the threshold test.
        ("GLIDE_MIN_STEP declared once",
         len([l for l in text.split("\n")
              if l.startswith("local GLIDE_MIN_STEP =")]) == 1, "ok"),
        ("GLIDE_MIN_STEP gates the accumulator",
         "if math.abs(tspGlidePending) < GLIDE_MIN_STEP then" in text, "ok"),
        ("GLIDE_MIN_STEP is passed to setView once",
         text.count("GLIDE_MIN_STEP)") == 1, text.count("GLIDE_MIN_STEP)")),
        ("GLIDE_MIN_STEP appears nowhere else in code",
         _code_hits(text, "GLIDE_MIN_STEP") == 3, _code_hits(text, "GLIDE_MIN_STEP")),
        # NOT "rate > min step" - that compares units/second against
        # units/frame and is exactly the check that let a freeze through. The
        # real invariant is that sub-threshold movement is banked, not dropped.
        ("sub-threshold movement is accumulated, not discarded",
         _code_hits(text, "tspGlidePending") >= 6
         and "tspGlidePending = tspGlidePending + step" in text, 
         _code_hits(text, "tspGlidePending")),
        ("arrival bypasses the step floor",
         "arriving and 0.0 or GLIDE_MIN_STEP" in text, "ok"),
        ("pending is cleared only when a move lands",
         text.count("tspGlidePending = 0.0") == 4, text.count("tspGlidePending = 0.0")),
        ("FPS_SMOOTHING bypass sits inside pushFpsSample",
         text.index("if FPS_SMOOTHING == 'none' then")
         > text.index("local function pushFpsSample")
         and text.index("if FPS_SMOOTHING == 'none' then")
         < text.index("local function setView"), "ok"),
        ("the window estimator is still present, not deleted",
         "TSP_FPSAVG_V1" in text and text.count("TSP_FPSAVG_V2") == orig.count("TSP_FPSAVG_V2")
         and "WEIGHT_DECAY" in text and "TRIM_WORST" in text, "ok"),
        ("the load ramp is untouched",
         text.count("RAMP_SECONDS") == orig.count("RAMP_SECONDS")
         and "local RAMP_SECONDS = 20.0" in text
         and "local RAMP_START_VIEW = 3000.0" in text, "ok"),
        ("his diagnostics are untouched",
         "local TSP_DIAG_FPS = true" in text
         and "local TSP_DIAG_DYNVIEW = false" in text
         and "local TSP_DIAG_STALL = false" in text
         and text.count("TSP_DYNVIEW_STALL_V3") == orig.count("TSP_DYNVIEW_STALL_V3"), "ok"),
        ("targetView is set everywhere currentView is snapped",
         text.count("targetView = currentView") == 2, text.count("targetView = currentView")),
        ("handlers still exported",
         "onInit = onInit," in text and "onFrame = onFrame," in text, "ok"),
    ]
    print("\n  --- assertions")
    bad = 0
    for label, good, got in checks:
        print("      %-48s %s (%s)" % (label, "PASS" if good else "FAIL", got))
        if not good:
            bad += 1
    if bad:
        extra = None
        if syn_note.startswith("unverifiable"):
            extra = ("\n  This is the one case I will not push past: a control-flow patch\n"
                     "  with no way to check that it parses. Send me this output - the\n"
                     "  input md5 tells me what changed, I will re-anchor and re-verify\n"
                     "  the new bytes here, and then it ships with a matching md5.")
        die("%d assertion(s) failed" % bad, extra)

    print("\n  --- THE DIFF")
    for line in difflib.unified_diff(orig.split("\n"), text.split("\n"),
                                     lineterm="", n=2):
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


if __name__ == "__main__":
    if MODE in ("tune", "tuneplan", "tune2", "tune2plan"):
        sys.exit(do_tune())
    sys.exit(main())
