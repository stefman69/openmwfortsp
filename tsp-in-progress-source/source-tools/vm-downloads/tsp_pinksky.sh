#!/bin/bash
# tsp_pinksky.sh - read-only dump for the Ald-ruhn sandstorm pink-sky bug.
# Nothing is written on the device or in the container. Host output goes to
# ~/Downloads/tsp_pinksky_<stamp>.txt ; a short summary prints in the terminal.
#
# Modes: (none) = full dump.  log = device log section only (fast, no container).
#
# Reads:
#   device    openmw.log image failures, TSP_KTX lines, env, sky/storm texture files
#   container the current text of every function on the pink-sky path
#
# TSP_PINKSKY_V1

set -u

TSP=root@192.168.1.12
SSH_OPTS="-o BatchMode=yes -o ConnectTimeout=8 -o ServerAliveInterval=15"
G=/mnt/SDCARD/data/ports/openmw
CTR=openmw_builder
SRC=/root/openmw-0.51-tsp-src
MODE="${1:-all}"

STAMP=$(date +%Y%m%d-%H%M%S)
OUT="$HOME/Downloads/tsp_pinksky_$STAMP.txt"
mkdir -p "$HOME/Downloads"

# --- the only two ssh wrappers. bare ssh is a bug (working agreement 28). ---
r()   { ssh -n $SSH_OPTS "$TSP" "$@"; }          # command string, no stdin
rin() { ssh    $SSH_OPTS "$TSP" "$@"; }          # heredoc callers only
d()   { docker exec "$CTR" "$@" </dev/null; }    # container, never takes stdin

say()  { echo "$*"; }
head2(){ printf '\n========== %s ==========\n' "$*" >> "$OUT"; }
note() { printf '%s\n' "$*" >> "$OUT"; }

say "TSP_PINKSKY_V1  mode=$MODE"
say "writing -> $OUT"
{
  echo "TSP_PINKSKY_V1 dump $STAMP"
  echo "device $TSP   gameroot $G"
  echo "container $CTR   src $SRC"
} > "$OUT"

# ---------------------------------------------------------------- preflight
DEV_OK=0
say "[1/9] preflight: device"
if r 'echo tsp_ok' 2>/dev/null | grep -q tsp_ok; then
  DEV_OK=1
  say "      device reachable"
else
  say "      DEVICE UNREACHABLE - skipping every device section"
  note "DEVICE UNREACHABLE"
fi

CTR_OK=0
if [ "$MODE" = "log" ]; then
  say "[2/9] preflight: container skipped (mode=log)"
else
  say "[2/9] preflight: container"
  if d test -d "$SRC" >/dev/null 2>&1; then
    CTR_OK=1
    say "      container up, source tree present"
  else
    say "      CONTAINER OR SOURCE TREE NOT AVAILABLE - skipping source sections"
    note "CONTAINER UNAVAILABLE"
  fi
fi

if [ "$DEV_OK" = "0" ] && [ "$CTR_OK" = "0" ]; then
  say "nothing reachable - stopping"
  exit 1
fi

# ------------------------------------------------------------ device: log
if [ "$DEV_OK" = "1" ]; then
  say "[3/9] device: openmw.log (image failures, KTX, sky, weather)"
  head2 "DEVICE openmw.log"
  rin 'sh -s' >> "$OUT" 2>&1 <<'REMOTE'
G=/mnt/SDCARD/data/ports/openmw
L="$G/config/openmw.log"
if [ -f "$L" ]; then
  echo "--- log file"
  ls -l "$L"
  echo ""
  echo "--- EVERY error and warning, deduped with counts"
  grep -E '\[[0-9:.]+ [EW]\]' "$L" | sed 's/^\[[0-9:.]* [EW]\] //' \
    | grep -Evi 'savegame screenshot|audio device|Bullet was not compiled' \
    | sort | uniq -c | sort -rn | head -60
  echo ""
  echo "--- image load failures, in time order, NOT deduped"
  grep -nE 'Failed to open image|Error loading|no readerwriter|no S3TC|cannot flip|pixel format' "$L" \
    | sed 's/^/PINKSKY_IMGFAIL /' | head -40
  echo ""
  echo "--- TSP_KTX lines (the first-8-loads reporter)"
  grep -n 'TSP_KTX' "$L" | head -20
  echo ""
  echo "--- load / teardown markers, in time order"
  grep -nE 'TSP_LOAD_TRACE|TSP_WORLDCLEAR_MEM|TSP_GMAP_MEM|TSP_MEMGATE|LOADPURGE|Loading cell|Loading content file' "$L" | head -60
  echo ""
  echo "--- anything naming a sky or weather texture"
  grep -niE 'sky|cloud|storm|blight|ashstorm|weather' "$L" | head -40
else
  echo "NO LOG at $L"
fi
REMOTE

  # ------------------------------------------------------- device: env/config
  say "[4/9] device: env and switches"
  head2 "DEVICE env and switches"
  rin 'sh -s' >> "$OUT" 2>&1 <<'REMOTE'
G=/mnt/SDCARD/data/ports/openmw
for f in /mnt/SDCARD/tsp_iotune.conf /mnt/SDCARD/tsp_intocc.env; do
  echo "--- $f"
  if [ -f "$f" ]; then cat "$f"; else echo "(does not exist)"; fi
  echo ""
done
echo "--- switch files present under /mnt/SDCARD"
ls -1 /mnt/SDCARD 2>/dev/null | grep -i '^tsp' | sed 's/^/    /'
echo ""
echo "--- settings.cfg texture and cache keys"
S="$G/config/settings.cfg"
if [ -f "$S" ]; then
  grep -niE 'cache|texture|mipmap|anisotropy|preload|shrink' "$S" | head -40
else
  echo "NO settings.cfg at $S"
fi
echo ""
echo "--- live process environ (only if the game is running)"
P=$(ps 2>/dev/null | grep 'openmw-0.51' | grep -v grep | awk '{print $1}' | head -1)
if [ -n "$P" ]; then
  tr '\0' '\n' < /proc/$P/environ 2>/dev/null | grep -iE 'TSP|LIBGL|OPENMW' | sort
else
  echo "(game not running - launch it and re-run this if you want the live env)"
fi
REMOTE

  # --------------------------------------------------- device: sky textures
  say "[5/9] device: sky / storm texture files, ktx vs dds"
  head2 "DEVICE sky and storm texture files"
  rin 'sh -s' >> "$OUT" 2>&1 <<'REMOTE'
T="/mnt/SDCARD/data/ports/openmw/data/Data Files/textures"
echo "--- textures dir"
if [ -d "$T" ]; then
  echo "$T"
  echo "    total files: $(find "$T" -maxdepth 1 -type f | wc -l)"
  echo "    ktx:         $(find "$T" -maxdepth 1 -type f -name '*.ktx' | wc -l)"
  echo "    dds:         $(find "$T" -maxdepth 1 -type f -name '*.dds' | wc -l)"
  echo ""
  echo "--- every loose file whose name looks like sky / cloud / storm / blight"
  find "$T" -maxdepth 1 -type f \
    \( -name '*sky*' -o -name '*cloud*' -o -name '*storm*' -o -name '*blight*' -o -name '*ashcloud*' -o -name '*bm_*' \) \
    -exec ls -l {} + 2>/dev/null | sed 's/^/    /' | head -60
else
  echo "NO textures dir at $T"
fi
echo ""
echo "--- same names inside the BSAs (name table grep, no extraction)"
B="/mnt/SDCARD/data/ports/openmw/data/Data Files"
for a in Morrowind.bsa Tribunal.bsa Bloodmoon.bsa; do
  if [ -f "$B/$a" ]; then
    echo "    $a: $(ls -l "$B/$a" | awk '{print $5}') bytes"
  fi
done
REMOTE
fi

# ------------------------------------------------- container: source dumps
if [ "$CTR_OK" = "1" ]; then

  say "[6/9] container: imagemanager.cpp in full"
  head2 "SRC components/resource/imagemanager.cpp (FULL, numbered)"
  d sh -c "nl -ba $SRC/components/resource/imagemanager.cpp" >> "$OUT" 2>&1

  say "[7/9] container: resourcehelpers, sky, weather"
  head2 "SRC components/misc/resourcehelpers.cpp - TSP_KTX and correctTexturePath"
  d sh -c "grep -n 'TSP_KTX\|tspKtx\|tspPreferKtx\|correctTexturePath\|correctIconPath\|correctBookartPath\|changeExtension' $SRC/components/misc/resourcehelpers.cpp" >> "$OUT" 2>&1
  note ""
  note "--- context around every one of those hits"
  d sh -c "grep -n -B 6 -A 18 -E 'TSP_KTX|tspKtx|tspPreferKtx|correctTexturePath' $SRC/components/misc/resourcehelpers.cpp" >> "$OUT" 2>&1

  head2 "SRC apps/openmw/mwrender/sky* - where sky textures are requested"
  note "--- sky source files present"
  d sh -c "ls -1 $SRC/apps/openmw/mwrender/ | grep -i sky" >> "$OUT" 2>&1
  note ""
  note "--- texture requests in every sky* file"
  d sh -c "grep -n 'getImage\|ImageManager\|setTexture\|Texture2D\|mTexture\|createTexture\|\\.dds\|\\.tga\|tx_' $SRC/apps/openmw/mwrender/sky*.cpp $SRC/apps/openmw/mwrender/sky*.hpp" >> "$OUT" 2>&1

  head2 "SRC apps/openmw/mwworld/weather.cpp - storm and cloud texture names"
  d sh -c "grep -n 'CloudTexture\|mCloudTexture\|Texture\|tx_\|\\.tga\|\\.dds\|Ashstorm\|Blight\|ashstorm\|blight\|storm' $SRC/apps/openmw/mwworld/weather.cpp | head -80" >> "$OUT" 2>&1

  say "[8/9] container: cache lifetime and the load path"
  head2 "SRC cache lifetime - who clears, who releases, who expires"
  note "--- every clearCache / releaseGLObjects / updateCache call site in apps+components"
  d sh -c "grep -rn 'clearCache(\|releaseGLObjects(\|updateCache(\|setExpiryDelay\|removeExpired' $SRC/apps $SRC/components --include=*.cpp --include=*.hpp | head -60" >> "$OUT" 2>&1
  note ""
  note "--- every TSP_NO_LOADPURGE / LOADPURGE reference"
  d sh -c "grep -rn 'LOADPURGE\|loadpurge' $SRC/apps $SRC/components --include=*.cpp --include=*.hpp" >> "$OUT" 2>&1
  note ""
  note "--- every mWarningImage reference"
  d sh -c "grep -rn 'mWarningImage\|WarningImage' $SRC/apps $SRC/components --include=*.cpp --include=*.hpp" >> "$OUT" 2>&1
  note ""
  note "--- resourcesystem.cpp in full"
  d sh -c "nl -ba $SRC/components/resource/resourcesystem.cpp" >> "$OUT" 2>&1
  note ""
  note "--- objectcache expiry"
  d sh -c "grep -n 'ExpiryDelay\|removeExpired\|update(\|erase_if\|addEntryToObjectCache\|getRefFromObjectCache' $SRC/components/resource/objectcache.hpp" >> "$OUT" 2>&1

  head2 "SRC statemanagerimp.cpp - cleanup and the reload path"
  d sh -c "grep -n 'cleanup\|clearCache\|releaseGLObjects\|tspRestartForSaveLoad\|TSP_' $SRC/apps/openmw/mwstate/statemanagerimp.cpp | head -60" >> "$OUT" 2>&1

  say "[9/9] container: TSP marker census on the texture path"
  head2 "SRC TSP markers in the files this bug can live in"
  for f in components/resource/imagemanager.cpp components/misc/resourcehelpers.cpp \
           apps/openmw/mwrender/sky.cpp apps/openmw/mwworld/weather.cpp \
           components/resource/resourcesystem.cpp apps/openmw/mwstate/statemanagerimp.cpp; do
    note "--- $f"
    d sh -c "grep -o 'TSP_[A-Za-z0-9_]*' $SRC/$f 2>/dev/null | sort -u" >> "$OUT" 2>&1
    d sh -c "md5sum $SRC/$f 2>/dev/null" >> "$OUT" 2>&1
  done
else
  say "[6/9]..[9/9] container sections skipped"
fi

# ------------------------------------------------------------------ summary
say ""
say "===== SUMMARY ====="
if [ "$DEV_OK" = "1" ]; then
  IMGFAIL=$(grep -c '^PINKSKY_IMGFAIL' "$OUT" ; true)
  say "image-failure lines captured : $IMGFAIL"
  say ""
  say "the image failures, verbatim:"
  grep '^PINKSKY_IMGFAIL' "$OUT" | sed 's/^PINKSKY_IMGFAIL /    /' | head -20
  if [ "$IMGFAIL" = "0" ]; then
    say "    (none - so nothing failed to LOAD, and the magenta is coming from"
    say "     a cached warning image or from somewhere other than ImageManager)"
  fi
fi
say ""
say "full dump: $OUT"
say "size:      $(wc -c < "$OUT") bytes"
