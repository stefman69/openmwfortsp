#!/usr/bin/env bash
# TSP_LOADENV_V1 - deliver the two switches openmw actually needs.
#
#   bash ~/Downloads/tsp_loadfix.sh check     read-only: is the purge code even in the binary
#   bash ~/Downloads/tsp_loadfix.sh apply     patch the launcher (runs check first, refuses if it fails)
#   bash ~/Downloads/tsp_loadfix.sh verify    run WHILE the game is up: did the vars arrive
#   bash ~/Downloads/tsp_loadfix.sh revert    restore the launcher backup
#
# WHAT WAS PROVEN, not guessed:
#
#   /proc/<pid>/environ of two live games - one on the old launcher, one on the
#   current one - came back with the SAME 34 variables, zero differences. And not
#   one `export` line from /mnt/SDCARD/tsp_iotune.conf is among them:
#   TSP_NO_LOADPURGE, TSP_RELOAD_MEM_FLOOR_KB, TSP_CRASH_OUT, TSP_SNDWARM_MAX,
#   TSP_SNDWARM_LOG, TSP_KTX, LIBGL_TSP_LOG, LIBGL_NOBANNER, TSP_AUTOSLEEP - all
#   ABSENT. Where the conf and the launcher disagree, the launcher wins
#   (conf OPENMW_DEBUG_LEVEL=INFO vs process warning; conf TSP_FPS_OVERLAY=0 vs
#   process 1). A bounded search of Roms/PORTS, /mnt/SDCARD, .tmp_update, System,
#   the game dir, /etc/init.d and /usr/trimui found NOTHING that reads that file.
#
#   The file looked like it worked because two of its entries are sysctl-shaped.
#   TSP_RA_KB and TSP_SWAPPINESS land in kernel state, which is global and
#   persists; every `export` in the same file dies with whatever process read it.
#   swappiness also happens to be hardcoded at launcher line 1900, so it was
#   never evidence of anything.
#
# WHY ONLY TWO VARIABLES ARE TAKEN
#
#   Sourcing the whole conf would switch on ~15 lines that have never once been
#   live, including OPENMW_DEBUG_LEVEL=INFO (engine logging during play),
#   LIBGL_TSP_LOG=1 and TSP_FPS_OVERLAY=0 (which would turn your fps counter
#   off). That is not one change. These two are taken by name; the rest of that
#   file stays inert until we decide otherwise, deliberately.
#
# AND ONE RESTORATION, NOT AN EXPERIMENT
#
#   read_ahead_kb reads 512 on both block devices right now, but NOTHING on the
#   card writes it - no file references TSP_RA_KB or tsp_iotune. That 512 is a
#   stale kernel value with no writer, and it dies at the next reboot, taking the
#   09-07 readahead fix (3.7x fewer faulting frames) with it. One line re-applies
#   it in the launch chain where it belongs.

set -u

TSP="root@192.168.1.12"
SSH_OPTS="-o ConnectTimeout=8 -o StrictHostKeyChecking=no -o BatchMode=yes"
GAME="/mnt/SDCARD/data/ports/openmw"
BIN="$GAME/bin/openmw-0.51"
LAUNCHER="/mnt/SDCARD/Roms/PORTS/Morrowind.sh"
MARK="TSP_LOADENV_V1"
STAMP="$(date +%Y%m%d-%H%M%S)"
LOCAL="/tmp/tsp_loadfix.$$"

r()   { ssh -n $SSH_OPTS "$TSP" "$@"; }
rin() { ssh    $SSH_OPTS "$TSP" "$@"; }

die()  { echo; echo "ABORT: $*"; rm -f "$LOCAL".*; exit 1; }
head2() { echo; echo "########## $* ##########"; }

MODE="${1:-check}"
case "$MODE" in check|apply|verify|revert) ;; *) die "unknown mode '$MODE'. Use check, apply, verify or revert." ;; esac

r "test -f $BIN" || die "cannot reach $BIN on $TSP - device off, asleep or off the network"

# ---------------------------------------------------------------------- verify -
if [ "$MODE" = "verify" ]; then
    head2 "DID THE VARIABLES REACH THE PROCESS"
    rin "sh -s" <<'REMOTE'
P=""
if command -v pidof >/dev/null 2>&1; then P=$(pidof openmw-0.51 2>/dev/null | cut -d' ' -f1); fi
if [ -z "$P" ]; then P=$(ps 2>/dev/null | grep openmw-0.51 | grep -v grep | tr -s ' ' | cut -d' ' -f2 | head -1); fi
if [ -z "$P" ] || [ ! -d "/proc/$P" ]; then
    echo "  openmw is NOT running. Launch Morrowind, get into the world, then run this again."
    exit 0
fi
echo "  pid $P"
for k in TSP_NO_LOADPURGE TSP_RELOAD_MEM_FLOOR_KB; do
    V=$(tr '\0' '\n' < "/proc/$P/environ" 2>/dev/null | grep "^$k=")
    if [ -n "$V" ]; then echo "  ARRIVED   $V"; else echo "  MISSING   $k  <== the patch is not reaching the launch chain"; fi
done
echo "  readahead: mmcblk0=$(cat /sys/block/mmcblk0/queue/read_ahead_kb 2>/dev/null) mmcblk1=$(cat /sys/block/mmcblk1/queue/read_ahead_kb 2>/dev/null)"
echo
echo "  -- the launcher block firing --"
grep -a TSP_LOADENV_V1 /mnt/SDCARD/tsp_prog.txt 2>/dev/null | tail -4 | sed 's/^/    /'
echo
echo "  -- the purge liveness line, if the binary has it --"
grep -a -e TSP_PURGE_CONFIG -e GLRELEASE_CONFIG /mnt/SDCARD/data/ports/openmw/openmw_log.txt 2>/dev/null | tail -4 | sed 's/^/    /'
echo
echo "  -- the proof number: ~199 on loads 2+ means the purge is OFF, ~13648 means ON --"
grep -a TSP_PLAYERANIM_MEM_V1 /mnt/SDCARD/data/ports/openmw/openmw_log.txt 2>/dev/null | tail -8 | sed 's/^/    /'
REMOTE
    exit 0
fi

# ---------------------------------------------------------------------- revert -
if [ "$MODE" = "revert" ]; then
    head2 "RESTORE THE LAUNCHER"
    r "ls -t $LAUNCHER.bak-loadenv-* 2>/dev/null | head -8" | sed 's/^/    /'
    # Pick the newest backup that does NOT already contain the marker. Taking the
    # newest unconditionally restored a patched backup in testing - a second
    # `apply` used to snapshot the already-patched launcher.
    CAND="$(rin "sh -s" <<PICKEOF
for b in \$(ls -t $LAUNCHER.bak-loadenv-* 2>/dev/null); do
    if ! grep -q "$MARK" "\$b"; then echo "\$b"; break; fi
done
PICKEOF
)"
    CAND="$(echo "$CAND" | head -1)"
    if [ -z "$CAND" ]; then
        echo "    Every backup already contains $MARK, so none of them is a clean"
        echo "    pre-patch copy. Nothing was changed. Use the off switch instead:"
        echo "        touch /mnt/SDCARD/tsp_loadenv_off"
        die "no clean pre-patch backup to restore"
    fi
    echo "  restoring the newest backup WITHOUT the marker: $CAND"
    rin "sh -s" <<RVEOF
set -e
cp -p "$CAND" "$LAUNCHER"
if grep -q "$MARK" "$LAUNCHER"; then echo "  FAILED: the marker is still present"; exit 1; fi
echo "  restored $LAUNCHER from $CAND"
bash -n "$LAUNCHER" && echo "  bash -n OK"
RVEOF
    [ $? -eq 0 ] || die "revert failed"
    echo "  Or leave the patch in place and just disable it: touch /mnt/SDCARD/tsp_loadenv_off"
    exit 0
fi

# ----------------------------------------------------------------------- check -
head2 "1. IS THE PURGE CODE EVEN IN THE DEPLOYED BINARY"
echo "  TSP_PURGE_CONFIG has never printed to openmw_log.txt. Two reasons are"
echo "  possible and they need completely different fixes: the switch is not"
echo "  reaching the process (a launcher fix), or the code is not in the binary"
echo "  (a rebuild). An empty log grep cannot tell them apart - the binary can."
GATE="$(rin "sh -s" <<GEOF
B="$BIN"; HIT=0
for m in TSP_PURGE_CONFIG TSP_NO_LOADPURGE TSP_CELL_GLRELEASE_CONFIG OPENMW_TSP_MALLOC_TRIM_SECS OPENMW_TSP_GLRELEASE_FLOOR_KB TSP_RELOAD_MEM_FLOOR_KB TSP_PLAYERANIM_MEM_V1; do
    if grep -a -q "\$m" "\$B"; then echo "  has     \$m"; HIT=1; else echo "  MISSING \$m"; fi
done
echo "GATEHIT=\$HIT"
GEOF
)"
echo "$GATE" | grep -v GATEHIT
PURGE_IN_BIN="$(r "if grep -a -q TSP_NO_LOADPURGE $BIN; then echo yes; else echo no; fi")"
echo
if [ "$PURGE_IN_BIN" = "yes" ]; then
    echo "  VERDICT: the binary reads TSP_NO_LOADPURGE. Delivering it is a launcher fix."
else
    echo "  VERDICT: TSP_NO_LOADPURGE is NOT a string in the deployed binary."
    echo "  So the engine never reads it and no launcher edit can help. The loading"
    echo "  fix was never compiled into this binary, or was compiled out, and the"
    echo "  repair is a source patch and rebuild - not a config change."
    echo
    echo "  Send me this output. Do not run 'apply'; it would change nothing."
fi

if [ "$MODE" = "check" ]; then
    echo
    echo "  Next, if the verdict above says launcher fix:"
    echo "      bash ~/Downloads/tsp_loadfix.sh apply"
    exit 0
fi

# ----------------------------------------------------------------------- apply -
[ "$PURGE_IN_BIN" = "yes" ] || die "refusing to patch the launcher - the binary does not read TSP_NO_LOADPURGE"

head2 "2. PULL THE LAUNCHER AND PATCH IT HERE, NOT ON THE DEVICE"
r "cat $LAUNCHER" > "$LOCAL.orig" || die "could not read $LAUNCHER"
[ -s "$LOCAL.orig" ] || die "$LAUNCHER came back empty"
echo "  pulled $(wc -l < "$LOCAL.orig") lines"
command -v python3 >/dev/null 2>&1 || die "python3 not on this VM - needed to patch safely"

python3 - "$LOCAL.orig" "$LOCAL.new" > "$LOCAL.log" 2>&1 <<'PYEOF'
import sys

src, dst = sys.argv[1], sys.argv[2]
text = open(src, encoding="utf-8", errors="surrogateescape").read()

MARK = "TSP_LOADENV_V1"
ANCHOR = ("# TSP_INTOCC_V1 mode file: 0/absent = upstream, "
          "1 = interior occluders, 2 = 1 plus large-object tests\n")

BLOCK = '''# TSP_LOADENV_V1 - the two switches openmw needs, delivered IN the launch chain.
# /mnt/SDCARD/tsp_iotune.conf has carried both for days and NOTHING sources that
# file: a bounded search found no reader, and /proc/<pid>/environ of a live game
# showed neither variable. Its sysctl-shaped entries only looked effective because
# kernel state is global and persists; every export in it was inert.
# Deliberately only these two. That conf also sets OPENMW_DEBUG_LEVEL=INFO,
# LIBGL_TSP_LOG=1 and TSP_FPS_OVERLAY=0, and switching ~15 never-live lines on at
# once is not one change.
# Off: touch /mnt/SDCARD/tsp_loadenv_off
if [ ! -f /mnt/SDCARD/tsp_loadenv_off ]; then
  export TSP_NO_LOADPURGE=1
  export TSP_RELOAD_MEM_FLOOR_KB=120000
  # read_ahead_kb reads 512 now but has NO writer on the card - it is a stale
  # kernel value that dies at the next reboot, taking the 09-07 readahead fix
  # (3.7x fewer faulting frames) with it. Re-apply it where it belongs.
  for tsp_raq in /sys/block/mmcblk0/queue/read_ahead_kb /sys/block/mmcblk1/queue/read_ahead_kb; do
    if [ -w "$tsp_raq" ]; then echo 512 > "$tsp_raq" 2>/dev/null; fi
  done
  echo "TSP_LOADENV_V1 armed NO_LOADPURGE=1 RELOAD_MEM_FLOOR_KB=120000 ra0=$(cat /sys/block/mmcblk0/queue/read_ahead_kb 2>/dev/null) ra1=$(cat /sys/block/mmcblk1/queue/read_ahead_kb 2>/dev/null)" >> /mnt/SDCARD/tsp_prog.txt
else
  echo "TSP_LOADENV_V1 disabled by /mnt/SDCARD/tsp_loadenv_off" >> /mnt/SDCARD/tsp_prog.txt
fi

'''


def die(msg):
    print("REFUSING: %s" % msg)
    print("NOTHING WAS WRITTEN.")
    sys.exit(1)


if MARK in text:
    print("  ALREADY APPLIED - the marker is present. Nothing to do.")
    open(dst, "w", encoding="utf-8", errors="surrogateescape").write(text)
    print("  VERIFIED: %s" % MARK)
    sys.exit(0)

n = text.count(ANCHOR)
if n != 1:
    print("  anchor matched %d times, need exactly 1. Survey:" % n)
    for i, line in enumerate(text.splitlines(), 1):
        if "TSP_INTOCC" in line:
            print("    %6d  %s" % (i, line))
    die("cannot place the block safely")

out = text.replace(ANCHOR, BLOCK + ANCHOR, 1)

if out.count("\n") - text.count("\n") != BLOCK.count("\n"):
    die("line-count delta is wrong")
if MARK not in out:
    die("post-write check: marker missing")
for kw, need in (("if ", None), ("fi", None)):
    pass
# balance check on the inserted block only: one if/fi pair plus one for/done pair
b = BLOCK
if b.count("\nif ") + b.startswith("if ") != 1 or b.count("\nfi\n") != 1:
    die("the inserted block is not a single balanced if/fi")
if b.count("\n  for ") != 1 or b.count("\n  done\n") != 1:
    die("the inserted block is not a single balanced for/done")

open(dst, "w", encoding="utf-8", errors="surrogateescape").write(out)
print("  inserted %d lines before the TSP_INTOCC_V1 mode-file comment" % BLOCK.count("\n"))
print("  VERIFIED: %s" % MARK)
PYEOF
cat "$LOCAL.log"
[ -s "$LOCAL.new" ] || die "the patcher refused or produced nothing - see above. The device was not touched."

# A second apply must not back up the already-patched launcher, or `revert` later
# restores a patched copy. Caught in testing; stop here instead.
if grep -q "ALREADY APPLIED" "$LOCAL.log"; then
    echo
    echo "  The launcher already carries $MARK. Nothing to back up, nothing to send."
    r "grep -a $MARK /mnt/SDCARD/tsp_prog.txt 2>/dev/null | tail -2" | sed 's/^/    /'
    echo
    echo "  Launch Morrowind, then while it is running:"
    echo "      bash ~/Downloads/tsp_loadfix.sh verify"
    rm -f "$LOCAL".*
    exit 0
fi

head2 "3. CHECK THE PATCHED FILE BEFORE IT GOES ANYWHERE"
bash -n "$LOCAL.new" || die "the patched launcher does not parse - refusing to deploy"
echo "  bash -n OK"
sh -n "$LOCAL.new" 2>/dev/null && echo "  sh -n OK (also POSIX clean)" || echo "  (sh -n complains, expected: the launcher is bash and uses 'source')"
echo "  -- exactly what changed --"
diff -u "$LOCAL.orig" "$LOCAL.new" | sed -n '1,60p' | sed 's/^/    /'
if grep -q "$MARK" "$LOCAL.new"; then echo "  marker present"; else die "marker missing from the patched file"; fi

head2 "4. BACK UP AND DEPLOY"
r "cp -p $LAUNCHER $LAUNCHER.bak-loadenv-$STAMP" || die "device backup failed - nothing deployed"
echo "  backup: $LAUNCHER.bak-loadenv-$STAMP"
rin "cat > $LAUNCHER.new" < "$LOCAL.new" || die "upload failed - $LAUNCHER untouched"
rin "sh -s" <<DEOF
set -e
L="$LAUNCHER"
bash -n "\$L.new" || { echo "  DEVICE REFUSED: the uploaded file does not parse"; rm -f "\$L.new"; exit 1; }
mv "\$L.new" "\$L"
chmod +x "\$L"
if grep -q "$MARK" "\$L"; then echo "  DEVICE VERIFIED: $MARK in \$L"; else echo "  DEVICE FAIL"; exit 1; fi
echo "  lines: \$(wc -l < "\$L")"
DEOF
[ $? -eq 0 ] || die "device verification failed - restore with: bash ~/Downloads/tsp_loadfix.sh revert"

head2 "5. WHAT TO DO NOW"
cat <<'NOTE'
  Launch MORROWIND from your ports menu - the main entry.

  Load a save. Then load again. The second load is the test: with the purge off
  the resource cache survives the reload, so it should not rebuild from cold.

  Then, WHILE THE GAME IS STILL RUNNING:

      bash ~/Downloads/tsp_loadfix.sh verify

  That reads /proc/<pid>/environ and tells you whether the two variables actually
  arrived - the same check that proved they were missing in the first place. It
  also prints TSP_PLAYERANIM_MEM_V1 phase=constructed, which is the number that
  settles it: ~199 on loads 2+ means the purge is off, ~13648 means it is on.

  If it made things worse:
      bash ~/Downloads/tsp_loadfix.sh revert
  or just:  touch /mnt/SDCARD/tsp_loadenv_off

  One thing this does NOT claim to fix: the 27-30 -> 20-22 fps drop you saw
  between the two launchers. Both launchers hand the game the SAME 34 environment
  variables, byte for byte, and the one block they differ by has been disabled by
  its own off switch for 23 launches. There is no mechanism in the launcher for
  that difference, so I am not going to pretend I explained it.
NOTE
rm -f "$LOCAL".*
echo
echo "done."
