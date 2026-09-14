#!/usr/bin/env bash
# TSP_NOMEMGATE_V1 - the thing that actually re-parses your ESM files.
#
#   bash ~/Downloads/tsp_nomemgate.sh evidence     read-only: is it restarting
#   bash ~/Downloads/tsp_nomemgate.sh floor 80000  set the floor (THE FIX)
#   bash ~/Downloads/tsp_nomemgate.sh on           restore the 120000 line
#   bash ~/Downloads/tsp_nomemgate.sh disarm       comment the line out (DO NOT: see below)
#
# WHY THIS AND NOT THE PURGE
#
# You said "reloading all esm files like a fresh boot". I chased the resource
# cache purge because a 09-09 doc pointed there. That was the wrong read: the
# purge re-instantiates scene objects from an already-parsed ESM store. It does
# not re-read Morrowind.esm. The ONE mechanism in this build that re-parses ESM
# content files mid-session is TSP_MEMGATE_V1 calling tspRestartForSaveLoad(),
# which re-execs the process when MemAvailable drops below
# TSP_RELOAD_MEM_FLOOR_KB. A re-exec is not "like a fresh boot" - it is one.
#
# And the purge numbers back that up rather than contradicting it. Your verify
# run printed alloc_kb=1232 and 1231 on two consecutive loads. The 09-09 proof
# series is:
#     purge ON:   1231, 13648, 13648, 13650 ...
#     purge OFF:  1231,   199,   199,   198 ...
# Neither of your loads is 13648, so the purge is not running hot. But both read
# ~1231, which in that series is the FIRST construction of a session - and seeing
# a first construction twice is what a restart looks like.
#
# MY OWN RISK, STATED PLAINLY
#
# Before tsp_loadfix.sh, TSP_RELOAD_MEM_FLOOR_KB was absent from the process
# environment entirely, so the engine used whatever it compiles in. My patch set
# it to 120000 for the first time. If the compiled default is lower or disabled,
# I armed this gate tonight. Section 1 below measures whether it is firing; the
# disarm removes only that one export and keeps TSP_NO_LOADPURGE=1.

set -u

TSP="root@192.168.1.12"
SSH_OPTS="-o ConnectTimeout=8 -o StrictHostKeyChecking=no -o BatchMode=yes"
GAME="/mnt/SDCARD/data/ports/openmw"
BIN="$GAME/bin/openmw-0.51"
LAUNCHER="/mnt/SDCARD/Roms/PORTS/Morrowind.sh"
FLOORLINE="  export TSP_RELOAD_MEM_FLOOR_KB=120000"
STAMP="$(date +%Y%m%d-%H%M%S)"

r()   { ssh -n $SSH_OPTS "$TSP" "$@"; }
rin() { ssh    $SSH_OPTS "$TSP" "$@"; }

die()  { echo; echo "ABORT: $*"; exit 1; }
head2() { echo; echo "########## $* ##########"; }

MODE="${1:-evidence}"
NEWFLOOR=""
case "$MODE" in
    evidence|on|disarm) ;;
    floor)
        NEWFLOOR="${2:-}"
        case "$NEWFLOOR" in
            ''|*[!0-9]*) die "floor needs a positive integer in kB, e.g. floor 80000" ;;
        esac
        [ "$NEWFLOOR" -gt 0 ] || die "0 does NOT disable the gate - see the note below. Use 1 for effectively-off."
        ;;
    *) die "unknown mode '$MODE'. Use evidence, floor <kB>, on, or disarm." ;;
esac

r "test -f $BIN" || die "cannot reach $BIN on $TSP - device off, asleep or off the network"
r "test -f $LAUNCHER" || die "launcher not found at $LAUNCHER"

################################################################################
# 1. EVIDENCE - is the process actually restarting
################################################################################
head2 "1. IS THE PROCESS RESTARTING ON A LOAD - THE DIRECT MEASUREMENT"
echo "  This does not infer from memory numbers. It counts how many times the"
echo "  engine parsed your content files. Once per launch is normal. Twice in one"
echo "  launcher session means it restarted, and that IS your symptom."
rin "sh -s" <<'REMOTE'
G=/mnt/SDCARD/data/ports/openmw
L="$G/openmw_log.txt"
if [ ! -f "$L" ]; then echo "  $L absent"; exit 0; fi

echo "  -- every ESM/content parse, with timestamps --"
grep -a -n -e 'Loading content file' -e 'Loading ESM' -e 'Loading master' -e 'Loading plugin' "$L" 2>/dev/null | tail -24 | sed 's/^/    /'
C=$(grep -a -c 'Loading content file' "$L" 2>/dev/null ; true)
echo "    total 'Loading content file' lines in this log: $C"
echo
echo "  -- engine startup banners. More than one per launcher session = a restart --"
grep -a -n -e 'OpenMW version' -e 'Using config' -e 'Loading settings' "$L" 2>/dev/null | tail -12 | sed 's/^/    /'
echo
echo "  -- the memgate itself --"
grep -a -e 'TSP_MEMGATE' -e 'RestartForSaveLoad' -e 'tspRestart' -e 'RELOAD_MEM_FLOOR' "$L" 2>/dev/null | tail -12 | sed 's/^/    /'
echo "    (any line here on a load is the gate firing)"
echo
echo "  -- MemAvailable now. The COMPILED default floor is 204800 kB --"
grep -e MemTotal -e MemAvailable -e MemFree -e Cached -e SwapFree /proc/meminfo | sed 's/^/    /'
A=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo)
if [ -n "$A" ]; then
    if [ "$A" -lt 204800 ]; then
        echo "    MemAvailable $A kB is BELOW the 204800 compiled default."
        echo "    With no env override the gate FIRES and the process re-execs."
    else
        echo "    MemAvailable $A kB clears the 204800 compiled default by $(( A - 204800 )) kB"
        echo "    Note: this is measured at the MENU, not at the peak of a load. A load"
        echo "    adds ~193 MB, so headroom here does not mean headroom there."
    fi
fi
echo
echo "  -- is the gate armed in the launcher right now --"
if grep -q 'TSP_RELOAD_MEM_FLOOR_KB' /mnt/SDCARD/Roms/PORTS/Morrowind.sh; then
    grep -n 'TSP_RELOAD_MEM_FLOOR_KB' /mnt/SDCARD/Roms/PORTS/Morrowind.sh | sed 's/^/    /'
else
    echo "    not exported by the launcher - the engine is on its compiled default"
fi
REMOTE

if [ "$MODE" = "evidence" ]; then
    echo
    echo "  Nothing was changed."
    echo "  If the line above says action=fresh, THAT is the ESM re-parse. The fix"
    echo "  is to set the floor below MemAvailable at load time:"
    echo "      bash ~/Downloads/tsp_nomemgate.sh floor 80000"
    exit 0
fi

################################################################################
# 2. ARM / DISARM
################################################################################
if [ "$MODE" = "on" ]; then
    head2 "2. RE-ARM THE GATE"
    rin "sh -s" <<ONEOF
set -e
L="$LAUNCHER"
if grep -q '^  export TSP_RELOAD_MEM_FLOOR_KB=' "\$L"; then
    echo "  already armed: \$(grep -h 'TSP_RELOAD_MEM_FLOOR_KB' "\$L" | head -1)"
    exit 0
fi
if ! grep -q '^  # TSP_NOMEMGATE_V1 disarmed: ' "\$L"; then
    echo "  REFUSING: no disarmed marker found, so there is nothing to re-arm."
    exit 1
fi
cp -p "\$L" "\$L.bak-nomemgate-$STAMP"
sed -i 's|^  # TSP_NOMEMGATE_V1 disarmed: export TSP_RELOAD_MEM_FLOOR_KB=\(.*\)$|  export TSP_RELOAD_MEM_FLOOR_KB=\1|' "\$L"
bash -n "\$L" || { echo "  REFUSING: the edit broke the launcher, restoring"; cp -p "\$L.bak-nomemgate-$STAMP" "\$L"; exit 1; }
grep -n 'TSP_RELOAD_MEM_FLOOR_KB' "\$L" | sed 's/^/    /'
echo "  re-armed. backup: \$L.bak-nomemgate-$STAMP"
ONEOF
    [ $? -eq 0 ] || die "re-arm refused, nothing changed"
    exit 0
fi

if [ "$MODE" = "floor" ]; then
    head2 "2. SET THE MEMGATE FLOOR TO $NEWFLOOR kB"
    echo "  The engine's COMPILED default is 204800 kB (statemanagerimp.cpp,"
    echo "  tspReloadMemLow). Anything at or below MemAvailable at load time means"
    echo "  action=warm and no restart; anything above it means action=fresh and a"
    echo "  full re-exec with an ESM re-parse."
    echo
    echo "  A LANDMINE, from the same function: a value of 0 does NOT disable the"
    echo "  gate. The override is guarded by 'if (tspParsed > 0)', so 0 falls"
    echo "  straight back to 204800 - the worst case. Use 1 for effectively-off."
    rin "sh -s" <<FLEOF
set -e
L="$LAUNCHER"
if ! grep -q 'TSP_LOADENV_V1' "\$L"; then
    echo "  REFUSING: no TSP_LOADENV_V1 block in the launcher. Run tsp_loadfix.sh apply first."
    exit 1
fi
N=\$(grep -c 'TSP_RELOAD_MEM_FLOOR_KB' "\$L" || true)
if [ "\$N" != "1" ]; then
    echo "  REFUSING: expected exactly 1 TSP_RELOAD_MEM_FLOOR_KB line, found \$N. Survey:"
    grep -n 'TSP_RELOAD_MEM_FLOOR_KB' "\$L" | sed 's/^/      /'
    exit 1
fi
cp -p "\$L" "\$L.bak-nomemgate-$STAMP"
sed -i 's|^  *#* *\(# TSP_NOMEMGATE_V1 disarmed: \)\{0,1\}export TSP_RELOAD_MEM_FLOOR_KB=.*\$|  export TSP_RELOAD_MEM_FLOOR_KB=$NEWFLOOR|' "\$L"
bash -n "\$L" || { echo "  REFUSING: the edit broke the launcher, restoring"; cp -p "\$L.bak-nomemgate-$STAMP" "\$L"; exit 1; }
if ! grep -q "^  export TSP_RELOAD_MEM_FLOOR_KB=$NEWFLOOR\$" "\$L"; then
    echo "  FAILED: the new value is not active, restoring"; cp -p "\$L.bak-nomemgate-$STAMP" "\$L"; exit 1
fi
if ! grep -q 'TSP_NO_LOADPURGE=1' "\$L"; then
    echo "  FAILED: the purge fix was lost, restoring"; cp -p "\$L.bak-nomemgate-$STAMP" "\$L"; exit 1
fi
echo "  DEVICE VERIFIED:"
grep -n -e 'TSP_NO_LOADPURGE' -e 'TSP_RELOAD_MEM_FLOOR_KB' "\$L" | sed 's/^/    /'
echo "  backup: \$L.bak-nomemgate-$STAMP"
FLEOF
    [ $? -eq 0 ] || die "the floor change was refused - nothing changed"
    echo
    echo "  Launch MORROWIND, load a save, load again, then:"
    echo "      bash ~/Downloads/tsp_nomemgate.sh evidence"
    echo "  You want action=warm on the TSP_MEMGATE_V1 line and ONE set of"
    echo "  'Loading content file' lines per launch."
    exit 0
fi

head2 "2. DISARM THE RESTART GATE, KEEP THE PURGE FIX"
echo "  Comments out ONLY the TSP_RELOAD_MEM_FLOOR_KB export inside the"
echo "  TSP_LOADENV_V1 block. TSP_NO_LOADPURGE=1 and the readahead line stay."
echo "  The engine falls back to whatever it compiles in, which is what it was"
echo "  using for every session before tonight."
rin "sh -s" <<OFFEOF
set -e
L="$LAUNCHER"
if grep -q '^  # TSP_NOMEMGATE_V1 disarmed: ' "\$L"; then
    echo "  ALREADY DISARMED:"
    grep -n 'TSP_NOMEMGATE_V1 disarmed' "\$L" | sed 's/^/    /'
    exit 0
fi
N=\$(grep -c '^  export TSP_RELOAD_MEM_FLOOR_KB=' "\$L" || true)
if [ "\$N" != "1" ]; then
    echo "  REFUSING: expected exactly 1 floor export, found \$N. Survey:"
    grep -n 'TSP_RELOAD_MEM_FLOOR_KB' "\$L" | sed 's/^/      /'
    exit 1
fi
if ! grep -q 'TSP_NO_LOADPURGE=1' "\$L"; then
    echo "  REFUSING: TSP_NO_LOADPURGE is not in the launcher - wrong file or the"
    echo "  loadfix patch is not applied. Nothing changed."
    exit 1
fi
cp -p "\$L" "\$L.bak-nomemgate-$STAMP"
sed -i 's|^  export TSP_RELOAD_MEM_FLOOR_KB=\(.*\)\$|  # TSP_NOMEMGATE_V1 disarmed: export TSP_RELOAD_MEM_FLOOR_KB=\1|' "\$L"
bash -n "\$L" || { echo "  REFUSING: the edit broke the launcher, restoring"; cp -p "\$L.bak-nomemgate-$STAMP" "\$L"; exit 1; }
if grep -q '^  export TSP_RELOAD_MEM_FLOOR_KB=' "\$L"; then echo "  FAILED: the export is still active"; exit 1; fi
if ! grep -q 'TSP_NO_LOADPURGE=1' "\$L"; then echo "  FAILED: the purge fix was lost, restoring"; cp -p "\$L.bak-nomemgate-$STAMP" "\$L"; exit 1; fi
echo "  DEVICE VERIFIED: floor export disarmed, TSP_NO_LOADPURGE=1 intact"
grep -n -e 'TSP_NO_LOADPURGE' -e 'TSP_RELOAD_MEM_FLOOR_KB' "\$L" | sed 's/^/    /'
echo "  backup: \$L.bak-nomemgate-$STAMP"
echo "  lines: \$(wc -l < "\$L")"
OFFEOF
[ $? -eq 0 ] || die "the disarm was refused - nothing changed. Send me the survey above."

head2 "3. WHAT TO DO NOW"
cat <<'NOTE'
  Launch MORROWIND from your ports menu. Load a save, play a minute, load again.

  Then:
      bash ~/Downloads/tsp_nomemgate.sh evidence

  Read it like this, and it is a yes/no, not a judgement call:

    "Loading content file" appears ONCE per launch
        -> no restart. The ESM re-parse is gone. That was the bug.

    "Loading content file" appears TWICE or more in one launch
        -> it is still restarting, and the memgate is not what is doing it.
           The startup-banner count in section 1 says the same thing a second
           way. Send me both and I stop guessing at mechanisms and instrument
           the restart path itself.

  To put the gate back:
      bash ~/Downloads/tsp_nomemgate.sh on

  What I am NOT claiming: that this is definitely it. What I am claiming is that
  it is the only code path in this build that re-parses ESM content files, that
  its threshold reached the engine for the first time tonight because of my
  patch, and that section 1 measures the answer directly instead of inferring it
  from a memory number.
NOTE
echo
echo "done."
