#!/bin/sh
# tsp_heapfix.sh - THE FIX for the first-load heap that never comes back.
#
#   plan   print every change, write nothing, build nothing
#   go     apply all three changes, build, back up, deploy    <-- THE ONE TO RUN
#   pull   read back whether it worked, from the log and from /proc
#   undo   revert all three and restore the previous binary
#
# ---------------------------------------------------------------------------
# WHAT IS ACTUALLY WRONG
#
# Measured, from the full smaps at the peak of a first load:
#
#     snapshot   [heap] reserved   Rss      Swap     committed
#     baseline             0.0     0.0       0.0        0.0 MB
#     peak1              347.1   317.1      25.2      342.3 MB
#     after              348.4   292.9      50.8      343.7 MB
#
# The heap does not shrink after the load. It is not in use - it is UNRETURNED.
# Those addresses are 64-bit (556edfe000-5574c77000), and on 64-bit glibc the
# mmap threshold is DYNAMIC: it starts at 128 kB and ratchets upward every time
# an mmap'd block is freed, all the way to 32 MB. Once it has ratcheted, every
# allocation up to 32 MB goes into the brk heap instead of its own mmap - and
# glibc only ever trims the TOP of brk, so one live allocation above a freed
# burst pins the entire region resident.
#
# 340 MB pinned on a 963 MB device forces the kernel to evict the page cache
# instead. Every later walk faults those assets back off the SD card one at a
# time. That is the hitch, and it is why it only happens on the first load and
# first walk: after that the working set is resident again.
#
# THREE CHANGES, ALL OF WHICH TARGET THAT ONE OBJECT
#
#  A. /mnt/SDCARD/tsp_intocc.env  (no rebuild)
#     Morrowind.sh line 5 sources this file unconditionally and it does not
#     exist. Setting MALLOC_MMAP_THRESHOLD_ explicitly PINS the threshold and
#     disables the dynamic ratchet, so large scene-construction allocations go
#     to their own mmap and are handed back to the kernel the moment they are
#     freed. This covers the whole process lifetime - the load AND the walk.
#     Proven deliverable: TSP_NO_LOADPURGE=1 is already visible in the running
#     game's /proc/<pid>/environ, so exports from a sourced conf do reach it.
#
#  B. settings.cfg  (no rebuild)
#     preload cell cache max  24 -> 16   (upstream default is 20)
#     preload cell expiry delay 20 -> 8  (upstream default is 5)
#     With "preload instances = true" every cached cell holds a CLONE of its
#     nodes and collision shapes, so those two numbers multiply directly into
#     the heap. preload instances itself is LEFT ON - turning it off would make
#     cell transitions worse, which is the thing being fixed.
#
#  C. apps/openmw/mwstate/statemanagerimp.cpp  (rebuild)
#     malloc_trim(0) at the end of loadGame, under the loading screen. Walks
#     every arena and madvises the interior free pages back. Verified on a
#     fragmented 324 MB heap: returned 260 MB, rc=1. Logged at Debug::Warning,
#     not Info, because the device runs OPENMW_DEBUG_LEVEL=warning and an Info
#     line would never reach any log file.
#
# NOT TOUCHED, DELIBERATELY: TSP_NO_LOADPURGE stays set. On a FIRST load there
# is no previous world to purge, so it is not part of this problem, and the
# 09-09 measurement that set it (purge reclaimed 9.5 MB, cost 13.4 MB) still
# stands for repeat loads.
# ---------------------------------------------------------------------------

set -u
DEV="root@192.168.1.12"
G="/mnt/SDCARD/data/ports/openmw"
CONT="openmw_builder"
SRC="/root/openmw-0.51-tsp-src"
ENVF="/mnt/SDCARD/tsp_intocc.env"
CFG="$G/config/settings.cfg"
BIN="$G/bin/openmw-0.51"
SSHO="-o ConnectTimeout=8 -o StrictHostKeyChecking=no -o BatchMode=yes"
STAMP="$(date +%Y%m%d-%H%M%S)"
PATCHER="$HOME/Downloads/tsp_heappatch.py"
LOCALBIN="/tmp/tsp_openmw_built_$STAMP"

MODE="${1:-plan}"
case "$MODE" in plan | go | pull | undo | dump | where | build) ;;
*) printf 'usage: %s dump | where | plan | go | build | pull | undo\n' "$0"; exit 2 ;; esac
DUMPF="$HOME/Downloads/tsp_heapfix_sections_$STAMP.txt"

say() { printf '  %s\n' "$*"; }
hr()  { printf '\n########## %s ##########\n' "$1"; }
r()   { ssh $SSHO -n "$DEV" "$1" 2>&1; }
rq()  { ssh $SSHO -n "$DEV" "$1" 2>/dev/null; }
rin() { ssh $SSHO "$DEV" "sh -s" 2>&1; }
d()   { docker exec "$CONT" sh -c "$1" 2>&1; }
dq()  { docker exec "$CONT" sh -c "$1" 2>/dev/null; }
din() { docker exec -i "$CONT" sh -s 2>&1; }

abort() { printf '\n  STOPPING: %s\n' "$*"; printf '  Nothing further was changed.\n\n'; exit 1; }

# ---------------------------------------------------------------- preflight --
ssh $SSHO -n "$DEV" "echo ok" 2>&1 | grep -q ok \
    || abort "cannot reach $DEV - is the handheld awake and on wifi?"

if [ "$MODE" != "pull" ]; then
    docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$CONT" \
        || abort "container $CONT is not running - start it and re-run"
fi

# ======================================================================= pull =
if [ "$MODE" = "pull" ]; then
    hr "DID IT WORK"
    rin <<'PEOF'
G="/mnt/SDCARD/data/ports/openmw"
echo "--- 1. THE TRIM ITSELF (this is the whole answer)"
grep -h 'TSP_HEAPTRIM_V1' "$G/openmw_log.txt" /mnt/SDCARD/tsp_prog.txt \
     "$G/config/openmw.log" 2>/dev/null | tail -12 | sed 's/^/    /'
if ! grep -qh 'TSP_HEAPTRIM_V1' "$G/openmw_log.txt" /mnt/SDCARD/tsp_prog.txt \
        "$G/config/openmw.log" 2>/dev/null; then
    echo "    NOT FOUND. Either the new binary is not the one that ran, or no"
    echo "    save was loaded yet. Load a save, quit, and re-run this."
fi

echo "--- 2. did the allocator tunables reach the game"
P="$(pidof openmw-0.51 2>/dev/null | awk '{print $1}')"
[ -n "$P" ] || P="$(ps -e 2>/dev/null | grep '[o]penmw-0.51' | awk '{print $1}' | head -1)"
[ -n "$P" ] || P="$(ps 2>/dev/null | grep '[o]penmw-0.51' | awk '{print $1}' | head -1)"
if [ -n "$P" ]; then
    echo "    pid $P"
    tr '\0' '\n' < "/proc/$P/environ" 2>/dev/null > /tmp/tspenv.$$
    for k in TSP_HEAPFIX_V1 MALLOC_MMAP_THRESHOLD_ MALLOC_TRIM_THRESHOLD_ GLIBC_TUNABLES; do
        v="$(grep "^$k=" /tmp/tspenv.$$ 2>/dev/null | head -1)"
        if [ -n "$v" ]; then printf "    PRESENT  %s\n" "$v"
        else                 printf "    absent   %s   <- the env file is not reaching the game\n" "$k"; fi
    done
    rm -f /tmp/tspenv.$$
    echo "--- 3. the heap RIGHT NOW"
    awk '/\[heap\]$/{h=1;next} h&&/^Size:/{s=$2} h&&/^Rss:/{r=$2} h&&/^Swap:/{w=$2;
         printf "    [heap] reserved %.1f MB   Rss %.1f MB   Swap %.1f MB   committed %.1f MB\n",
         s/1024, r/1024, w/1024, (r+w)/1024; h=0}' "/proc/$P/smaps" 2>/dev/null
    grep -e '^Rss:' -e '^Swap:' "/proc/$P/smaps_rollup" 2>/dev/null | sed 's/^/    whole process  /'
    grep VmRSS "/proc/$P/status" 2>/dev/null | sed 's/^/    /'
else
    echo "    game not running - start it for sections 2 and 3"
fi

echo "--- 4. what the settings say now"
grep -n -e 'preload cell cache max' -e 'preload cell expiry delay' -e 'preload instances' \
     "$G/config/settings.cfg" 2>/dev/null | sed 's/^/    /'

echo "--- 5. the env file"
[ -f /mnt/SDCARD/tsp_intocc.env ] && sed 's/^/    /' /mnt/SDCARD/tsp_intocc.env \
                                  || echo "    MISSING"

echo "--- 6. memory, and the last 25 log lines in case of a crash"
grep -e MemTotal -e MemAvailable -e ^Cached -e SwapFree /proc/meminfo | sed 's/^/    /'
tail -25 "$G/openmw_log.txt" 2>/dev/null | sed 's/^/    /'
PEOF
    cat <<'REOF'

  HOW TO READ SECTION 1

    returned_kb large (tens or hundreds of MB)  -> the fix is doing its job; the
      heap was full of freed-but-unreturned pages, exactly as measured, and they
      are now back with the kernel. Expect the walk to be smoother.

    returned_kb near 0 and rc=0                 -> the heap is genuinely LIVE,
      not fragmented waste. Then the allocation itself has to shrink, and the
      next lever is the preload working set - tell me and I will take cache max
      down further rather than guessing now.

REOF
    exit 0
fi

# ======================================================================= undo =
if [ "$MODE" = "undo" ]; then
    hr "REVERTING ALL THREE CHANGES"
    say "A. the env file"
    rin <<UEOF
E='$ENVF'
B=""
for c in \$(ls -1t "\$E".before-* 2>/dev/null); do
    grep -q 'TSP_HEAPFIX_V1' "\$c" 2>/dev/null || { B="\$c"; break; }
done
if [ -n "\$B" ]; then cp -p "\$B" "\$E" && printf '    restored from %s\n' "\$B"
elif [ -f "\$E" ]; then rm -f "\$E" && echo "    removed (there was no prior version)"
else echo "    nothing there"; fi
UEOF
    say "B. settings.cfg"
    rin <<SEOF
C='$CFG'
B="\$(ls -1tr "\$C".before-heapfix-* 2>/dev/null | head -1)"
if [ -n "\$B" ] && grep -q '^preload cell cache max = 16' "\$B" 2>/dev/null; then
    echo "    REFUSING: the oldest backup \$B already has the edit in it, so it"
    echo "    is not the original. Not restoring anything - tell me and I will"
    echo "    look at what is in that folder."
    B=""
fi
if [ -n "\$B" ]; then cp -p "\$B" "\$C" && printf '    restored from %s\n' "\$B"
else echo "    no heapfix backup - left alone"; fi
grep -n -e 'preload cell cache max' -e 'preload cell expiry delay' "\$C" | sed 's/^/    /'
SEOF
    say "C. the binary on the device"
    rin <<BEOF
BN='$BIN'
B="\$(ls -1tr "\$BN".before-heaptrim-* 2>/dev/null | head -1)"
if [ -n "\$B" ] && grep -aq 'TSP_HEAPTRIM_V1' "\$B" 2>/dev/null; then
    echo "    NOTE: the oldest backup \$B already contains TSP_HEAPTRIM_V1."
    echo "    Restoring it anyway - it is still the earliest binary on record -"
    echo "    but set TSP_NO_HEAPTRIM=1 in tsp_intocc.env to disable the trim."
fi
if [ -n "\$B" ]; then cp -p "\$B" "\$BN" && printf '    restored from %s\n' "\$B"
else echo "    no heaptrim binary backup - left alone"; fi
ls -l "\$BN" | sed 's/^/    /'
BEOF
    say "D. the source tree"
    d "cd $SRC && TSP_SRC=$SRC python3 /tmp/tsp_heappatch.py undo"
    printf '\n'
    say "Reverted. The source is back but NOT rebuilt - the device binary was"
    say "restored from its backup, so the running game is the old one either way."
    printf '\n'
    exit 0
fi


# ------------------------------------------------------------------- dump ----
# Writes the FULL text of every region any of the three changes reads or writes,
# to one txt file. `dump` does only this. `go` runs it first, so the file exists
# even if the patch later refuses - there is then no round trip to get it.
write_dump() {
    mkdir -p "$HOME/Downloads"
    {
        printf '# tsp_heapfix sections dump - %s\n' "$STAMP"
        printf '# every region the three changes touch, in full, verbatim.\n'

        printf '\n\n======================================================================\n'
        printf '== 1. THE LAUNCHER - /mnt/SDCARD/Roms/PORTS/Morrowind.sh, lines 1-40\n'
        printf '==    (change A depends on line 5 sourcing tsp_intocc.env)\n'
        printf '======================================================================\n'
        ssh $SSHO -n "$DEV" "sed -n '1,40p' /mnt/SDCARD/Roms/PORTS/Morrowind.sh | cat -n" 2>&1
        printf '\n-- every line in the whole launcher that mentions intocc, iotune or MALLOC --\n'
        ssh $SSHO -n "$DEV" "grep -n -e intocc -e iotune -e MALLOC -e GLIBC_TUNABLES /mnt/SDCARD/Roms/PORTS/Morrowind.sh" 2>&1
        printf '\n-- every file the launcher sources --\n'
        ssh $SSHO -n "$DEV" "grep -n '^[[:space:]]*\(\.\|source\)[[:space:]]' /mnt/SDCARD/Roms/PORTS/Morrowind.sh" 2>&1
        printf '\n-- the exec/launch line --\n'
        ssh $SSHO -n "$DEV" "grep -n -e 'openmw-0.51' /mnt/SDCARD/Roms/PORTS/Morrowind.sh | tail -12" 2>&1

        printf '\n\n======================================================================\n'
        printf '== 2. THE ENV FILE - %s (change A writes this)\n' "$ENVF"
        printf '======================================================================\n'
        ssh $SSHO -n "$DEV" "[ -f '$ENVF' ] && cat -n '$ENVF' || echo '(does not exist)'" 2>&1
        printf '\n-- and tsp_iotune.conf, which proves conf exports reach the game --\n'
        ssh $SSHO -n "$DEV" "[ -f /mnt/SDCARD/tsp_iotune.conf ] && cat -n /mnt/SDCARD/tsp_iotune.conf || echo '(absent)'" 2>&1

        printf '\n\n======================================================================\n'
        printf '== 3. SETTINGS - the whole [Cells] section (change B edits 2 lines here)\n'
        printf '======================================================================\n'
        ssh $SSHO -n "$DEV" "awk '/^\[Cells\]/{f=1} f&&/^\[/&&!/^\[Cells\]/{exit} f{printf \"%6d | %s\\n\", NR, \$0}' '$CFG'" 2>&1
        printf '\n-- and every preload / cache line anywhere in the file --\n'
        ssh $SSHO -n "$DEV" "grep -n -e preload -e 'cache ' -e 'cache=' '$CFG'" 2>&1

        printf '\n\n======================================================================\n'
        printf '== 4. THE SOURCE - every region change C reads or writes, in full\n'
        printf '======================================================================\n'
        docker exec "$CONT" sh -c "cd $SRC && TSP_SRC=$SRC python3 /tmp/tsp_heappatch.py dump" 2>&1
    } > "$DUMPF" 2>&1
    say "wrote $DUMPF  ($(wc -l < "$DUMPF") lines, $(wc -c < "$DUMPF") bytes)"
}

if [ "$MODE" = "dump" ]; then
    hr "DUMPING EVERY SECTION THESE CHANGES TOUCH"
    [ -f "$PATCHER" ] || abort "$PATCHER is missing - put it in ~/Downloads"
    docker cp "$PATCHER" "$CONT:/tmp/tsp_heappatch.py" >/dev/null 2>&1 \
        || abort "could not copy the patcher into $CONT"
    write_dump
    printf '\n'
    say "Nothing was changed. Send me that file."
    printf '\n'
    exit 0
fi


# ------------------------------------------------------- find the build dir --
# The first version of this took `find ... -name build.ninja | head -1` and got
# /root/mygui-3.4.3-openmw051-gcc13-build - MyGUI's build tree, not OpenMW's -
# then ran `ninja openmw` in it and failed with "unknown target". Taking head -1
# of a candidate list IS guessing a build layout. This asks each candidate two
# questions instead: what does its CMakeCache say the project is, and does ninja
# itself list an openmw target. Only a unique answer is accepted.
find_build() {
    BUILD=""
    TARGET=""
    din <<FBEOF
SRC='$SRC'
for R in "\$SRC" /root /opt /build /src /usr/src /home /workspace; do
    [ -d "\$R" ] || continue
    find "\$R" -maxdepth 4 -name build.ninja 2>/dev/null
done | sort -u > /tmp/tsp_cands
printf '  %s candidate ninja build dirs found\n' "\$(wc -l < /tmp/tsp_cands)"
printf '\n  %-52s %-14s %-16s %s\n' "directory" "project" "openmw target" "existing binary"
: > /tmp/tsp_openmw_builds
while read -r bn; do
    D="\$(dirname "\$bn")"
    PN="\$(grep -m1 '^CMAKE_PROJECT_NAME:STATIC=' "\$D/CMakeCache.txt" 2>/dev/null | cut -d= -f2)"
    ninja -C "\$D" -t targets all 2>/dev/null | cut -d: -f1 > /tmp/tsp_t
    # prefer the bare phony target CMake creates; fall back to the path target
    T="\$(grep -x 'openmw' /tmp/tsp_t 2>/dev/null | head -1)"
    [ -n "\$T" ] || T="\$(grep -E '/openmw\$' /tmp/tsp_t 2>/dev/null | head -1)"
    B="\$(find "\$D" -maxdepth 3 -type f -name openmw 2>/dev/null | head -1)"
    printf '  %-52s %-14s %-16s %s\n' "\$D" "\${PN:-?}" "\${T:-NONE}" "\${B:-none}"
    [ -n "\$T" ] && printf '%s\t%s\n' "\$D" "\$T" >> /tmp/tsp_openmw_builds
done < /tmp/tsp_cands
printf '\n  dirs that actually declare an openmw target: %s\n' "\$(wc -l < /tmp/tsp_openmw_builds)"
cat /tmp/tsp_openmw_builds | sed 's/^/    MATCH /'
FBEOF
    HITS="$(dq "cat /tmp/tsp_openmw_builds 2>/dev/null")"
    N="$(printf '%s\n' "$HITS" | grep -c '	' 2>/dev/null)"
    [ -n "$N" ] || N=0
    if [ "$N" -eq 0 ] 2>/dev/null; then
        say ""
        say "No ninja build directory declares an openmw target. I am NOT going to"
        say "pick one and hope. Send me the table above - the source is already"
        say "patched and waiting, so this is the only thing left."
        return 1
    fi
    if [ "$N" -gt 1 ] 2>/dev/null; then
        say ""
        say "$N build directories declare an openmw target. Send me the table"
        say "above and say which one you normally build in - I will not choose."
        return 1
    fi
    BUILD="$(printf '%s\n' "$HITS" | grep '	' | head -1 | cut -f1)"
    TARGET="$(printf '%s\n' "$HITS" | grep '	' | head -1 | cut -f2)"
    say ""
    say "-> build dir: $BUILD"
    say "-> ninja target: $TARGET"
    return 0
}

if [ "$MODE" = "where" ]; then
    hr "WHERE IS OPENMW ACTUALLY BUILT"
    find_build || exit 1
    printf '\n'
    say "Nothing was changed. If that looks right:"
    printf '\n      bash ~/Downloads/tsp_heapfix.sh build\n\n'
    exit 0
fi

# --------------------------------------------- build and deploy, on its own --
# For when A, B and C are already applied and only the build failed.
do_build_deploy() {
    find_build || return 1

    hr "BUILDING - full output, nothing truncated"
    say "target $TARGET in $BUILD"
    say "this is the long part; ninja prints its own progress as it goes"
    printf '\n'
    docker exec "$CONT" sh -c "cd '$BUILD' && ninja '$TARGET' 2>&1"
    BRC=$?
    printf '\n'
    if [ $BRC -ne 0 ]; then
        say "BUILD FAILED (rc=$BRC). The device binary was NOT touched - the game"
        say "still runs the old one. Send me the output above."
        return 1
    fi
    say "build OK"

    hr "DEPLOYING"
    NEW="$(dq "find '$BUILD' -maxdepth 3 -type f -name openmw -newermt '-40 minutes' 2>/dev/null | head -1")"
    [ -n "$NEW" ] || NEW="$(dq "find '$BUILD' -maxdepth 3 -type f -name openmw 2>/dev/null | head -1")"
    [ -n "$NEW" ] || { say "built fine but no openmw binary found under $BUILD"; return 1; }
    say "built binary: $NEW"
    d "ls -l '$NEW' | sed 's/^/    /'"
    d "grep -ac 'TSP_HEAPTRIM_V1' '$NEW' 2>/dev/null | sed 's/^/    TSP_HEAPTRIM_V1 in the fresh binary: /'"
    docker cp "$CONT:$NEW" "$LOCALBIN" >/dev/null 2>&1 || { say "could not copy the binary out of the container"; return 1; }
    say "local copy: $LOCALBIN  ($(wc -c < "$LOCALBIN") bytes)"
    rin <<BKEOF
BN='$BIN'
if ls "\$BN".before-heaptrim-* >/dev/null 2>&1; then
    printf '    pre-patch binary already preserved at %s - not re-backing up\n' \
      "\$(ls -1tr "\$BN".before-heaptrim-* | head -1)"
else
    cp -p "\$BN" "\$BN.before-heaptrim-$STAMP" \
      && printf '    device binary backed up to %s.before-heaptrim-%s\n' "\$BN" "$STAMP"
fi
BKEOF
    scp $SSHO "$LOCALBIN" "$DEV:$BIN.new" >/dev/null 2>&1 \
        || { say "scp of the new binary failed - the old one is untouched"; return 1; }
    rin <<DEOF
BN='$BIN'
[ -s "\$BN.new" ] || { echo "    uploaded file is empty - NOT installing"; exit 1; }
chmod 755 "\$BN.new"
mv "\$BN.new" "\$BN"
ls -l "\$BN" | sed 's/^/    installed: /'
if grep -aq 'TSP_HEAPTRIM_V1' "\$BN"; then
    echo "    VERIFIED: TSP_HEAPTRIM_V1 is a string inside the installed binary"
else
    echo "    WARNING: TSP_HEAPTRIM_V1 not found in the installed binary"
fi
DEOF
    return 0
}

if [ "$MODE" = "build" ]; then
    hr "BUILD AND DEPLOY ONLY - A, B and C are assumed already applied"
    say "checking the source really is patched before building it"
    d "grep -c 'TSP_HEAPTRIM_V1' '$SRC/apps/openmw/mwstate/statemanagerimp.cpp'" \
        | sed 's/^/    TSP_HEAPTRIM_V1 occurrences in the source: /'
    MARKS="$(dq "grep -c 'TSP_HEAPTRIM_V1' '$SRC/apps/openmw/mwstate/statemanagerimp.cpp' 2>/dev/null")"
    case "${MARKS:-0}" in
    3) say "-> patched. Building." ;;
    0|"") abort "the source is NOT patched - run 'go' instead of 'build'" ;;
    *) abort "expected 3 occurrences of the marker, found ${MARKS} - send me the dump" ;;
    esac
    do_build_deploy || exit 1
    hr "DONE"
    cat <<'FEOF'
    A  /mnt/SDCARD/tsp_intocc.env    allocator thresholds pinned, ratchet off
    B  settings.cfg                  cache max 24->16, expiry 20->8
    C  openmw-0.51                   malloc_trim(0) at the end of loadGame

  Now: launch the game, load the Balmora save, and walk the same route past
  Caius Cosades that has been hitching. Then quit and run the pull.

  Backed out in one step with:  bash ~/Downloads/tsp_heapfix.sh undo
FEOF
    printf '\n      bash ~/Downloads/tsp_heapfix.sh pull\n\n'
    exit 0
fi

# ================================================================ plan and go =
hr "A. THE ENV FILE - $ENVF"
HITS="$(rq "grep -n 'tsp_intocc\.env' '/mnt/SDCARD/Roms/PORTS/Morrowind.sh' 2>/dev/null")"
N="$(printf '%s\n' "$HITS" \
     | grep -c '^[0-9][0-9]*:[[:space:]]*\(\.\|source\)[[:space:]][[:space:]]*["'\'']*/mnt/SDCARD/tsp_intocc\.env' 2>/dev/null)"
[ -n "$N" ] || N=0
printf '%s\n' "$HITS" | sed 's/^/    /'
say "real source commands for it in the launcher: $N"
[ "$N" -ge 1 ] 2>/dev/null || abort "the launcher does not source $ENVF, so writing it would do nothing"
say "-> sourced. This file will reach the game."

hr "B. SETTINGS - $CFG"
r "grep -n -e 'preload cell cache max' -e 'preload cell expiry delay' -e 'preload instances' -e 'preload cell cache min' '$CFG' | sed 's/^/    /'"
say "will become:  preload cell cache max = 16   preload cell expiry delay = 8"
say "unchanged:    preload instances = true      preload cell cache min = 12"

hr "C. THE SOURCE PATCH"
[ -f "$PATCHER" ] || abort "$PATCHER is missing - it ships alongside this script, put it in ~/Downloads"
docker cp "$PATCHER" "$CONT:/tmp/tsp_heappatch.py" >/dev/null 2>&1 \
    || abort "could not copy the patcher into $CONT"
say "writing the full-source dump FIRST, so it exists even if the patch refuses"
write_dump
d "cd $SRC && TSP_SRC=$SRC python3 /tmp/tsp_heappatch.py plan"
PRC=$?
if [ $PRC -eq 4 ]; then
    say "(already applied - go will skip straight to the build)"
elif [ $PRC -ne 0 ]; then
    say "the dump is still at $DUMPF - send me that and I will fix the patcher."
    abort "the source patch refused. Nothing was written and no build started."
fi

hr "THE BUILD DIRECTORY"
find_build || abort "cannot identify the OpenMW build dir - see the table above"

if [ "$MODE" = "plan" ]; then
    printf '\n'
    say "PLAN ONLY. Nothing was written, nothing was built, nothing was deployed."
    printf '\n      bash ~/Downloads/tsp_heapfix.sh go\n\n'
    exit 0
fi

# ---------------------------------------------------------------------- go ---
hr "APPLYING A - THE ENV FILE"
rin <<EEOF
E='$ENVF'
if [ -f "\$E" ]; then
    if grep -q 'TSP_HEAPFIX_V1' "\$E" 2>/dev/null; then
        echo "    already written by this tool - not re-backing it up"
    else
        cp -p "\$E" "\$E.before-$STAMP" && printf '    backed up the pre-existing file to %s.before-%s\n' "\$E" "$STAMP"
    fi
fi
cat > "\$E" <<'INNER'
# tsp_intocc.env - sourced unconditionally by Morrowind.sh line 5.
# It did not exist before, so every TSP_INTOCC_ var ran on compiled defaults.

# --- glibc allocator, the whole point of this file.
# Those addresses are 64-bit, so the mmap threshold is DYNAMIC: it starts at
# 128 kB and ratchets up to 32 MB every time an mmapd block is freed. Once it
# has ratcheted, scene-construction allocations land in the brk heap instead of
# their own mmap, and glibc only trims the TOP of brk - so a freed burst under
# one live allocation stays resident forever. Setting these explicitly PINS the
# thresholds and turns the ratchet off.
export MALLOC_MMAP_THRESHOLD_=131072
export MALLOC_TRIM_THRESHOLD_=131072
export MALLOC_TOP_PAD_=131072
export GLIBC_TUNABLES=glibc.malloc.mmap_threshold=131072:glibc.malloc.trim_threshold=131072:glibc.malloc.top_pad=131072
# arena_max is deliberately NOT set: the 6 extra arenas hold ~0 resident and
# capping them would only add lock contention across 19 threads.

# --- marker, so /proc/<pid>/environ can prove this file reached the game
export TSP_HEAPFIX_V1=1
INNER
printf '    wrote %s bytes:\n' "\$(wc -c < "\$E")"
sed "s/^/      /" "\$E"
EEOF

hr "APPLYING B - SETTINGS"
rin <<SEOF
C='$CFG'
[ -f "\$C" ] || { echo "    $CFG missing - skipping settings"; exit 0; }
# FIRST BACKUP WINS. Running go twice used to back up its own output, and undo
# then "restored" the edit. The first .before-heapfix-* is the only true
# original, so once one exists no further backup is ever taken.
if ls "\$C".before-heapfix-* >/dev/null 2>&1; then
    printf '    original already preserved at %s - not re-backing up\n' \
      "\$(ls -1tr "\$C".before-heapfix-* | head -1)"
else
    cp -p "\$C" "\$C.before-heapfix-$STAMP" && printf '    backed up to %s.before-heapfix-%s\n' "\$C" "$STAMP"
fi
sed -i -e 's/^[[:space:]]*preload cell cache max[[:space:]]*=.*/preload cell cache max = 16/' \\
       -e 's/^[[:space:]]*preload cell expiry delay[[:space:]]*=.*/preload cell expiry delay = 8/' "\$C"
echo "    now reads:"
grep -n -e 'preload cell cache max' -e 'preload cell expiry delay' -e 'preload instances' "\$C" | sed 's/^/      /'
M="\$(grep -c '^preload cell cache max = 16' "\$C")"
X="\$(grep -c '^preload cell expiry delay = 8' "\$C")"
[ "\$M" = "1" ] && [ "\$X" = "1" ] && echo "    verified: both lines took" \\
                                  || echo "    WARNING: expected 1 of each, got max=\$M expiry=\$X"
SEOF

hr "APPLYING C - THE SOURCE PATCH"
d "cd $SRC && TSP_SRC=$SRC python3 /tmp/tsp_heappatch.py go"
PRC=$?
[ $PRC -eq 0 ] || [ $PRC -eq 4 ] || abort "the source patch failed (rc=$PRC). A and B are applied; run undo to back them out."

do_build_deploy || {
    say ""
    say "A and B are applied and are harmless on their own. Back the whole"
    say "thing out with:"
    printf '\n      bash ~/Downloads/tsp_heapfix.sh undo\n\n'
    exit 1
}

hr "DONE - ALL THREE APPLIED"
cat <<'FEOF'
    A  /mnt/SDCARD/tsp_intocc.env    allocator thresholds pinned, ratchet off
    B  settings.cfg                  cache max 24->16, expiry 20->8
    C  openmw-0.51                   malloc_trim(0) at the end of loadGame

  Now: launch the game, load the Balmora save, and walk the same route past
  Caius Cosades that has been hitching. Then quit and run the pull.

  Backed out in one step with:  bash ~/Downloads/tsp_heapfix.sh undo
FEOF
printf '\n      bash ~/Downloads/tsp_heapfix.sh pull\n\n'
