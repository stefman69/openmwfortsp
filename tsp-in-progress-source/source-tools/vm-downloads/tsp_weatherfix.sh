#!/bin/bash
# tsp_weatherfix.sh - TSP_WEATHERFIX_V1
#
# Modes: find (default) | go | verify | rollback
#
# Ashstorm and Blight have ZERO fallback keys in openmw.cfg; every other weather
# has 26-41. Those values are Morrowind's own data, imported from Morrowind.ini -
# OpenMW does not ship them, so they must be recovered, never invented.
#
# This mode only LOOKS. It writes nothing, on the device or in the container.
# Four candidate sources, best first:
#   1. a Backups copy of openmw.cfg that still has the block  (already transformed)
#   2. Morrowind.ini on the device                            (authoritative raw)
#   3. Morrowind.ini on this VM                               (authoritative raw)
#   4. openmw-iniimporter in the build                        (the correct converter)
# Plus validate.cpp, which is the engine's own list of the keys that should exist.

set -u
MODE="${1:-find}"
STAMP=$(date +%Y%m%d-%H%M%S)

TSP=root@192.168.1.12
SSH_OPTS="-o BatchMode=yes -o ConnectTimeout=8 -o ServerAliveInterval=15"
G="${G:-/mnt/SDCARD/data/ports/openmw}"
BACKUPS=/mnt/SDCARD/data/ports/Backups
CTR=openmw_builder
SRC=/root/openmw-0.51-tsp-src
BLD=/root/openmw-0.51-tsp-build

r()   { ssh -n $SSH_OPTS "$TSP" "$@"; }
rin() { ssh    $SSH_OPTS "$TSP" "$@"; }
d()   { docker exec "$CTR" "$@" </dev/null; }

say() { echo "$*"; }


say "TSP_WEATHERFIX_V1 mode=$MODE stamp=$STAMP"

if [ "$MODE" = "go" ] || [ "$MODE" = "verify" ] || [ "$MODE" = "rollback" ]; then
  if r 'echo tsp_ok' 2>/dev/null | grep -q tsp_ok; then : ; else
    say "device not reachable - stopping"; exit 1
  fi
fi

# ============================================================== rollback
if [ "$MODE" = "rollback" ]; then
  say "restoring the newest backup that is NOT itself already patched"
  rin 'sh -s' <<'REMOTE'
G="${G:-/mnt/SDCARD/data/ports/openmw}"
RC=1
for dir in "$G" "$G/bin" "$G/config" "$G/config/openmw"; do
  if [ -d "$dir" ]; then
    for f in $(find "$dir" -maxdepth 1 -name '*.cfg' 2>/dev/null); do
      chosen=""
      for c in $(ls -t "$f".before-weatherfix-* 2>/dev/null); do
        if grep -q '^fallback=Weather_Ashstorm_Cloud_Texture' "$c"; then : ; else chosen="$c"; break; fi
      done
      if [ -n "$chosen" ]; then cp "$chosen" "$f"; echo "   restored $f from $chosen"; RC=0; fi
    done
  fi
done
if [ "$RC" != "0" ]; then echo "   no clean backup found for any config"; fi
exit $RC
REMOTE
  RRC=$?
  say ""
  if [ "$RRC" = "0" ]; then
    say "Relaunch Morrowind from PORTS to pick it up."
  else
    say "NOTHING WAS RESTORED - there is no pre-patch backup to go back to."
  fi
  exit $RRC
fi

# ============================================================== verify
if [ "$MODE" = "verify" ]; then
  rin 'sh -s' <<'REMOTE'
G="${G:-/mnt/SDCARD/data/ports/openmw}"
for dir in "$G" "$G/bin" "$G/config" "$G/config/openmw"; do
  if [ -d "$dir" ]; then
    for f in $(find "$dir" -maxdepth 1 -name '*.cfg' 2>/dev/null); do
      if grep -q '^fallback=Weather_Clear_Cloud_Texture' "$f" 2>/dev/null; then
        echo "--- $f"
        for w in Clear Cloudy Foggy Overcast Rain Thunderstorm Ashstorm Blight Snow Blizzard; do
          n=$(grep -c "^fallback=Weather_${w}_" "$f" ; true)
          t=$(grep "^fallback=Weather_${w}_Cloud_Texture," "$f" | tail -1 | sed 's/.*,//')
          printf "    %-13s %2s keys   cloud=%s\n" "$w" "$n" "${t:-NONE}"
        done
      fi
    done
  fi
done
L="$G/config/openmw.log"
if [ -f "$L" ]; then
  echo ""
  echo "--- the sky guard, which should now fire ZERO times"
  grep -n 'TSP_EMPTY_CLOUDTEX_V1' "$L" | head -10
  echo "    count: $(grep -c TSP_EMPTY_CLOUDTEX_V1 "$L" ; true)"
  echo "--- cached-magenta hits, should be zero"
  echo "    count: $(grep -c TSP_WARNCACHE_V1 "$L" ; true)"
  echo "--- image failures, should be zero"
  grep -nE 'Failed to open image|Error loading' "$L" | head -10
  echo "    count: $(grep -cE 'Failed to open image|Error loading' "$L" ; true)"
fi
REMOTE
  exit 0
fi

# ============================================================== go
if [ "$MODE" = "go" ]; then
  say "recovering both weather blocks from Morrowind.ini and inserting them"
  say ""
  rin "STAMP=$STAMP sh -s" <<'REMOTE'
G="${G:-/mnt/SDCARD/data/ports/openmw}"
BACKUPS="${BACKUPS:-/mnt/SDCARD/data/ports/Backups}"
STAMP="${STAMP:-manual}"
REQ="Sky_Sunrise_Color Sky_Day_Color Sky_Sunset_Color Sky_Night_Color Fog_Sunrise_Color Fog_Day_Color Fog_Sunset_Color Fog_Night_Color Ambient_Sunrise_Color Ambient_Day_Color Ambient_Sunset_Color Ambient_Night_Color Sun_Sunrise_Color Sun_Day_Color Sun_Sunset_Color Sun_Night_Color Sun_Disc_Sunset_Color Transition_Delta Land_Fog_Day_Depth Land_Fog_Night_Depth Clouds_Maximum_Percent Wind_Speed Cloud_Speed Glare_View Cloud_Texture Ambient_Loop_Sound_ID"

gen() {
awk -v w="$2" 'BEGIN{hdr="[Weather " w "]"; p=0}
index($0,hdr)==1 {p=1; next}
substr($0,1,1)=="[" {p=0}
p && index($0,"=")>0 {
  line=$0; sub(/\r$/,"",line);
  eq=index(line,"="); k=substr(line,1,eq-1); v=substr(line,eq+1);
  gsub(/^[ \t]+/,"",k); gsub(/[ \t]+$/,"",k); gsub(/ /,"_",k);
  gsub(/^[ \t]+/,"",v); gsub(/[ \t]+$/,"",v);
  if (k != "" && v != "") printf "fallback=Weather_%s_%s,%s\n", w, k, v
}' "$1"
}

echo "== 1. locate Morrowind.ini"
INI=""
for dir in "$G/data" "$G/data/Data Files" "$G" "$G/config"; do
  if [ -d "$dir" ]; then
    c=$(find "$dir" -maxdepth 2 -iname 'Morrowind.ini' 2>/dev/null | head -1)
    if [ -n "$c" ]; then INI="$c"; break; fi
  fi
done
if [ -z "$INI" ]; then echo "GATE: no Morrowind.ini found - stopping"; exit 1; fi
echo "   using $INI"

echo ""
echo "== 2. generate the two blocks from it"
gen "$INI" Ashstorm > /tmp/tsp_wa.txt
gen "$INI" Blight   > /tmp/tsp_wb.txt
NA=$(wc -l < /tmp/tsp_wa.txt | tr -d ' ')
NB=$(wc -l < /tmp/tsp_wb.txt | tr -d ' ')
echo "   Ashstorm $NA lines, Blight $NB lines"

echo ""
echo "== 3. gate: every required key must be present in both"
MISS=0
for w in Ashstorm Blight; do
  if [ "$w" = "Ashstorm" ]; then F=/tmp/tsp_wa.txt; else F=/tmp/tsp_wb.txt; fi
  for k in $REQ; do
    if grep -q "^fallback=Weather_${w}_${k}," "$F"; then : ; else
      echo "   MISSING Weather_${w}_${k}"
      MISS=$((MISS+1))
    fi
  done
done
if [ "$MISS" != "0" ]; then echo "GATE: $MISS required keys missing - NOTHING WRITTEN"; exit 1; fi
echo "   VERIFIED: all 26 required keys present for both weathers"

echo ""
echo "== 4. which config files carry the weather fallback block"
: > /tmp/tsp_targets.txt
for dir in "$G" "$G/bin" "$G/config" "$G/config/openmw"; do
  if [ -d "$dir" ]; then
    for f in $(find "$dir" -maxdepth 1 -name '*.cfg' 2>/dev/null); do
      if grep -q '^fallback=Weather_Clear_Cloud_Texture' "$f" 2>/dev/null; then echo "$f" >> /tmp/tsp_targets.txt; fi
    done
  fi
done
sort -u /tmp/tsp_targets.txt -o /tmp/tsp_targets.txt
NT=$(wc -l < /tmp/tsp_targets.txt | tr -d ' ')
echo "   $NT file(s):"
sed 's/^/      /' /tmp/tsp_targets.txt
if [ "$NT" = "0" ]; then echo "GATE: no config carries the weather block - stopping"; exit 1; fi

echo ""
echo "== 5. insert, with a per-file gate"
RC=0
while read -r f; do
  if grep -q '^fallback=Weather_Ashstorm_Cloud_Texture' "$f"; then
    echo "   -- $f : already patched, untouched"
    continue
  fi
  LB=$(wc -l < "$f" | tr -d ' ')
  CB=$(grep -c '^fallback=' "$f" ; true)
  CLB=$(grep -c '^fallback=Weather_Clear_' "$f" ; true)
  LAST=$(grep -n '^fallback=Weather_' "$f" | tail -1 | cut -d: -f1)
  if [ -z "$LAST" ]; then echo "   GATE: $f has no Weather_ anchor line"; RC=1; continue; fi
  cp "$f" "$f.before-weatherfix-$STAMP"
  head -n "$LAST" "$f" > "$f.tsptmp"
  echo "# TSP_WEATHERFIX_V1 - Ashstorm and Blight had ZERO fallback keys; recovered verbatim from $INI" >> "$f.tsptmp"
  cat /tmp/tsp_wa.txt >> "$f.tsptmp"
  cat /tmp/tsp_wb.txt >> "$f.tsptmp"
  tail -n +$((LAST+1)) "$f" >> "$f.tsptmp"
  LA=$(wc -l < "$f.tsptmp" | tr -d ' ')
  CA=$(grep -c '^fallback=' "$f.tsptmp" ; true)
  CLA=$(grep -c '^fallback=Weather_Clear_' "$f.tsptmp" ; true)
  AA=$(grep -c '^fallback=Weather_Ashstorm_' "$f.tsptmp" ; true)
  AB=$(grep -c '^fallback=Weather_Blight_' "$f.tsptmp" ; true)
  WANT_L=$((LB + NA + NB + 1))
  WANT_C=$((CB + NA + NB))
  if [ "$LA" = "$WANT_L" ] && [ "$CA" = "$WANT_C" ] && [ "$CLA" = "$CLB" ] && [ "$AA" = "$NA" ] && [ "$AB" = "$NB" ]; then
    mv "$f.tsptmp" "$f"
    echo "   VERIFIED: $f  lines $LB -> $LA   fallback= $CB -> $CA   ashstorm $AA   blight $AB   clear $CLA unchanged"
    echo "             backup $f.before-weatherfix-$STAMP"
  else
    rm -f "$f.tsptmp"
    echo "   GATE FAIL: $f  lines $LB -> $LA (want $WANT_L)  fallback= $CB -> $CA (want $WANT_C)  clear $CLB -> $CLA  ashstorm $AA/$NA  blight $AB/$NB"
    echo "   GATE FAIL: NOTHING WRITTEN to this file"
    RC=1
  fi
done < /tmp/tsp_targets.txt

echo ""
echo "== 6. census after, PER FILE (aggregating would double-count a bin/ copy)"
while read -r f; do
  echo "   --- $f"
  for w in Clear Cloudy Foggy Overcast Rain Thunderstorm Ashstorm Blight Snow Blizzard; do
    n=$(grep -c "^fallback=Weather_${w}_" "$f" ; true)
    t=$(grep "^fallback=Weather_${w}_Cloud_Texture," "$f" | tail -1 | sed 's/.*,//')
    printf "       %-13s %2s keys   cloud=%s\n" "$w" "$n" "${t:-NONE}"
  done
done < /tmp/tsp_targets.txt

echo ""
echo "== 7. rollback command"
while read -r f; do
  if [ -f "$f.before-weatherfix-$STAMP" ]; then echo "    cp \"$f.before-weatherfix-$STAMP\" \"$f\""; fi
done < /tmp/tsp_targets.txt
exit $RC
REMOTE
  GRC=$?
  say ""
  if [ "$GRC" = "0" ]; then
    say "===== DONE ====="
    say "Launch  Morrowind  from PORTS, find an ashstorm around Ald-ruhn, quit, then:"
    say ""
    say "    bash ~/Downloads/tsp_weatherfix.sh verify"
    say ""
    say "Expect the sky guard to fire ZERO times now, and the ashstorm haze to be"
    say "reddish-brown (124,073,058 by day) rather than flat grey."
  else
    say "finished with failures - read the GATE lines above. Nothing was left half-applied."
  fi
  exit $GRC
fi

# ============================================================== find
say "mode=find - read only, writes nothing"


say ""
say "[1/5] engine: which keys SHOULD Ashstorm and Blight have"
if d test -d "$SRC" >/dev/null 2>&1; then
  d sh -c "grep -n 'Ashstorm\|Blight' $SRC/components/fallback/validate.cpp | head -60" 2>&1 | sed 's/^/    /'
  say "    -- total distinct Weather_ keys the validator knows about:"
  d sh -c "grep -o 'Weather_[A-Za-z0-9_]*' $SRC/components/fallback/validate.cpp | sed 's/^Weather_[A-Za-z]*_//' | sort -u | wc -l" 2>&1 | sed 's/^/       /'
else
  say "    container not up - skipped"
fi

say ""
say "[2/5] build: is openmw-iniimporter available (the correct converter)"
if d test -d "$BLD" >/dev/null 2>&1; then
  d sh -c "ls -l $BLD/openmw-iniimporter 2>/dev/null; find $BLD -maxdepth 2 -iname '*iniimport*' 2>/dev/null; find $SRC/apps -maxdepth 1 -iname '*iniimport*' 2>/dev/null" 2>&1 | sed 's/^/    /'
else
  say "    build dir not reachable - skipped"
fi

say ""
say "[3/5] this VM: any Morrowind.ini"
find "$HOME" -maxdepth 5 -iname 'Morrowind.ini' 2>/dev/null | head -10 | sed 's/^/    /'
if [ -z "$(find "$HOME" -maxdepth 5 -iname 'Morrowind.ini' 2>/dev/null | head -1)" ]; then
  say "    none under $HOME"
fi

say ""
say "[4/5] device: Morrowind.ini, and Backups copies of openmw.cfg that still have the block"
if r 'echo tsp_ok' 2>/dev/null | grep -q tsp_ok; then
  rin 'sh -s' 2>&1 <<'REMOTE' | sed 's/^/    /'
G="${G:-/mnt/SDCARD/data/ports/openmw}"
BACKUPS=/mnt/SDCARD/data/ports/Backups
echo "--- Morrowind.ini candidates (bounded search, never the whole card)"
FOUND=""
for dir in "$G/data/Data Files" "$G/data" "$G" "$G/config" /mnt/SDCARD/Roms/PORTS "$BACKUPS"; do
  if [ -d "$dir" ]; then
    hits=$(find "$dir" -maxdepth 3 -iname 'Morrowind.ini' 2>/dev/null | head -5)
    if [ -n "$hits" ]; then echo "$hits" | sed 's/^/    /'; FOUND="$FOUND $hits"; fi
  fi
done
if [ -z "$FOUND" ]; then echo "    none found in the searched directories"; fi
echo ""
echo "--- if one was found, what it says for the two weathers"
for f in $FOUND; do
  echo "    === $f"
  echo "    lines in [Weather Ashstorm]:"
  awk '/^\[Weather Ashstorm\]/{p=1;next} /^\[/{p=0} p' "$f" 2>/dev/null | head -40 | sed 's/^/       /'
  echo "    lines in [Weather Blight]:"
  awk '/^\[Weather Blight\]/{p=1;next} /^\[/{p=0} p' "$f" 2>/dev/null | head -40 | sed 's/^/       /'
done
echo ""
echo "--- Backups copies of a config that still carries Weather_Ashstorm_"
if [ -d "$BACKUPS" ]; then
  find "$BACKUPS" -maxdepth 4 -name '*openmw*cfg*' 2>/dev/null | head -40 > /tmp/tsp_cfgcands
  echo "    candidate config files in Backups: $(wc -l < /tmp/tsp_cfgcands | tr -d ' ')"
  while read -r c; do
    n=$(grep -c '^fallback=Weather_Ashstorm_' "$c" 2>/dev/null ; true)
    b=$(grep -c '^fallback=Weather_Blight_' "$c" 2>/dev/null ; true)
    if [ "$n" != "0" ] || [ "$b" != "0" ]; then
      echo "    HIT  ashstorm=$n blight=$b  $c"
    fi
  done < /tmp/tsp_cfgcands
  echo "    (no HIT lines above means no backup carries the block either)"
else
  echo "    $BACKUPS does not exist"
fi
echo ""
echo "--- and the live config, for comparison"
echo "    ashstorm keys live: $(grep -c '^fallback=Weather_Ashstorm_' $G/openmw.cfg 2>/dev/null ; true)"
echo "    blight   keys live: $(grep -c '^fallback=Weather_Blight_' $G/openmw.cfg 2>/dev/null ; true)"
echo "    clear    keys live: $(grep -c '^fallback=Weather_Clear_' $G/openmw.cfg 2>/dev/null ; true)"
REMOTE
else
  say "    device not reachable - skipped"
fi

say ""
say "[5/5] summary"
say "    Best source wins in this order:"
say "      1 a Backups openmw.cfg with a non-zero ashstorm count - lift it verbatim"
say "      2 a Morrowind.ini with [Weather Ashstorm] - convert it with openmw-iniimporter"
say "      3 neither - the values have to come from a stock Morrowind.ini elsewhere"
say ""
say "    Nothing was written. Send this output and the patch comes next."
