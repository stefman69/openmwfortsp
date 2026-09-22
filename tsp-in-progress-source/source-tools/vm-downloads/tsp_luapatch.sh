#!/usr/bin/env bash
# TSP_LUAPATCH_V1 - actually apply TSP_FPSAVG_V2 to dynamic_view.lua, and bring back
# the part of the file needed to write the post-load ramp.
#
#   bash ~/Downloads/tsp_luapatch.sh
#
# There is exactly ONE dynamic_view.lua on the card and nothing overwrites it. Every
# earlier "TSP_FPSAVG_V2: NOT PRESENT" meant the patch had never been written: the arm
# script decided whether to patch with $(grep -c ... || echo 0), which yields "0\n0",
# so the branch never fired and the script then aborted on its own verify. This uses
# grep -q only.
#
# Rule Zero: file, not paste; r() uses -n, rin() takes the heredoc (NEVER -n).

set -u

TSP="${TSP:-root@192.168.1.12}"
SSH_OPTS="-o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=6"
DL="${DL:-$HOME/Downloads}"
STAMP="$(date +%Y%m%d-%H%M%S)"
W="$DL/tsp-luapatch"; mkdir -p "$W"
LUA='/mnt/SDCARD/data/ports/openmw/mods/TSPPerformance/scripts/TSPPerformance/dynamic_view.lua'
SRC_MD5=c45bb6c10e08caec16c7714132ebd021

r()   { ssh -n $SSH_OPTS "$TSP" "$@"; }
rin() { ssh    $SSH_OPTS "$TSP" "$@"; }
die() { printf '\nFAIL: %s\n' "$*" >&2; exit 1; }

r 'echo ok' >/dev/null 2>&1 || die "cannot reach the TSP at $TSP"

echo "########## 1. CURRENT STATE ##########"
r "ls -l '$LUA'; md5sum '$LUA'; printf 'lines: '; wc -l < '$LUA'"
echo

if r "grep -q TSP_FPSAVG_V2 '$LUA'"; then
    echo "TSP_FPSAVG_V2 already present - skipping the patch"
else
    echo "########## 2. PATCH ##########"
    r "cp -p '$LUA' '$LUA.before-fpsavgv2-$STAMP'" || die "device backup failed"
    echo "backed up to dynamic_view.lua.before-fpsavgv2-$STAMP"
    scp -q $SSH_OPTS "$TSP:$LUA" "$W/dynamic_view.lua" </dev/null || die "scp down failed"

    SRC_MD5="$SRC_MD5" python3 - "$W/dynamic_view.lua" <<'PYEOF' || die "patch refused; device untouched"
import hashlib, os, sys
p = sys.argv[1]
src = open(p, encoding='utf-8').read()
h = hashlib.md5(src.encode()).hexdigest()
want = os.environ['SRC_MD5']
if h != want:
    print('source md5 %s != %s - this is not the file I wrote the anchor against' % (h, want))
    sys.exit(1)

ANCHOR = ("    if weightSum <= 0.0 then\n"
          "        smoothFps = rawFps\n"
          "    else\n"
          "        smoothFps = sum / weightSum\n"
          "    end\n\n"
          "    return smoothFps\n")

INSERT = ("    if weightSum <= 0.0 then\n"
          "        smoothFps = rawFps\n"
          "    else\n"
          "        smoothFps = sum / weightSum\n"
          "    end\n\n"
          "    -- TSP_FPSAVG_V2 - a confirmed drop must not be averaged away. The trimmed mean\n"
          "    -- above deliberately ignores a single bad second, which is what stopped the\n"
          "    -- flicker; but it also ignored two bad seconds for several more, holding the\n"
          "    -- far plane long through real load. The better of the last two samples is a\n"
          "    -- ceiling: one bad second still moves nothing, two move immediately.\n"
          "    if count >= 2 then\n"
          "        local confirmed = fpsWindow[1]\n"
          "        if fpsWindow[2] > confirmed then confirmed = fpsWindow[2] end\n"
          "        if confirmed < smoothFps then smoothFps = confirmed end\n"
          "    end\n\n"
          "    return smoothFps\n")

n = src.count(ANCHOR)
print('anchor matched: %d (must be 1)' % n)
if n != 1:
    print('--- every line mentioning smoothFps, for a new anchor ---')
    for i, line in enumerate(src.splitlines(), 1):
        if 'smoothFps' in line or 'weightSum' in line:
            print('  %4d: %s' % (i, line))
    sys.exit(1)

out = src.replace(ANCHOR, INSERT, 1)
before, after = len(src.splitlines()), len(out.splitlines())
checks = [
    ('line delta matches the insert',
        after - before == len(INSERT.splitlines()) - len(ANCHOR.splitlines())),
    ('283 -> 294',                 before == 283 and after == 294),
    ('marker present once',        out.count('TSP_FPSAVG_V2') == 1),
    ('ceiling is the BETTER of two',
        out.count('if fpsWindow[2] > confirmed then confirmed = fpsWindow[2] end') == 1),
    ('trim loop untouched',        out.count('for i = 1, count do') == src.count('for i = 1, count do')),
    ('newest still trim-eligible', 'for i = 2, count do' not in out),
    ('constants unchanged',        all(s in out for s in (
                                       'WINDOW_SAMPLES = 5', 'WEIGHT_DECAY = 0.80', 'TRIM_WORST = 1',
                                       'LOW_FPS = 17.0', 'HIGH_FPS = 40.0',
                                       'MAX_DROP_PER_SAMPLE = 800.0', 'MAX_RAISE_PER_SAMPLE = 500.0',
                                       'DEADBAND = 96.0'))),
    ('TSP_DIAG_FPS still true',    out.count('TSP_DIAG_FPS = true') == 1),
    ('log tag unchanged',          out.count('TSP_DYNVIEW_V37MAP') == src.count('TSP_DYNVIEW_V37MAP')),
    ('nothing else moved',         src.replace(ANCHOR, '', 1) == out.replace(INSERT, '', 1)),
]
bad = False
for label, ok in checks:
    print('      %-4s %s' % ('OK' if ok else 'FAIL', label))
    bad = bad or not ok
if bad:
    print('INVARIANT FAILED - device untouched'); sys.exit(1)
open(p, 'w', encoding='utf-8').write(out)
print('patched locally: %d -> %d lines, md5 %s' % (before, after, hashlib.md5(out.encode()).hexdigest()))
PYEOF

    if command -v luac5.3 >/dev/null 2>&1; then
        luac5.3 -p "$W/dynamic_view.lua" && echo "luac5.3: syntax OK"
    elif command -v luac >/dev/null 2>&1; then
        luac -p "$W/dynamic_view.lua" && echo "luac: syntax OK"
    else
        echo "(no luac on this VM; the patched function was executed under lua5.3 before delivery)"
    fi

    NEW="$(md5sum "$W/dynamic_view.lua" | cut -d' ' -f1)"
    scp -q $SSH_OPTS "$W/dynamic_view.lua" "$TSP:$LUA" </dev/null || die "scp up failed"
    echo "deployed; VM md5 was $NEW"
fi

echo
echo "########## 3. VERIFY ON DEVICE ##########"
r "grep -q TSP_FPSAVG_V2 '$LUA'" || die "marker STILL absent after deploy"
r "md5sum '$LUA'; printf 'lines: '; wc -l < '$LUA'; printf 'marker count: '; grep -c TSP_FPSAVG_V2 '$LUA' ; true"
echo "VERIFIED: TSP_FPSAVG_V2 is on the device"
echo
echo "-- the patched function, as it now reads on the card --"
rin "sh -s" <<REMOTE
sed -n '/^-- TSP_FPSAVG_V1 - newest sample first/,/^end\$/p' '$LUA' | sed -n '1,70p'
REMOTE

echo
echo "########## 4. WHAT I NEED FOR THE POST-LOAD RAMP ##########"
scp -q $SSH_OPTS "$TSP:$LUA" "$W/dynamic_view.deployed.lua" </dev/null \
    && echo "full file saved to $W/dynamic_view.deployed.lua"
echo
echo "-- engine handlers and the tail of the file --"
rin "sh -s" <<REMOTE
awk 'NR >= 170 { printf "%4d  %s\n", NR, \$0 }' '$LUA'
REMOTE
