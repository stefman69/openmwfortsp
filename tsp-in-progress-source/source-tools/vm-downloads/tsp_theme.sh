#!/bin/sh
# ===========================================================================
# tsp_theme.sh  -  TSP_THEME_V1
#
# Read-only. Answers the three questions that decide whether the manager can
# be re-skinned with the game's own font, a paper background and menu music:
#
#   A. IS THE BUILD CHAIN WHERE I THINK IT IS?
#      SETTLED: the V3.0/v31 controller rebuilds exactly, from
#      apply_openmw_tsp_manager_v29...sh + tsp_mgr_v30_patch.py +
#      tsp_mgr_v31_full.py. All four artifacts it emits are byte-identical to
#      the files on the card. This section just confirms those three files are
#      on the VM and that the builder container still runs.
#
#   B. WHAT FONTS DOES THE CARD ACTUALLY HAVE?
#      Morrowind's own .fnt/.tex bitmap fonts, and OpenMW's TrueType
#      replacements (MysticCards / DemonicLetters) which are what the game
#      menus are drawn with.
#
#   C. WHAT CAN PLAY AUDIO ON THE CARD?
#      The manager has no audio code at all, so music has to come from the
#      wrapper. That needs either a player binary or a library to build one.
#
# It also PULLS BACK the manager binary and the font files, so the rebuilt
# binary can be checked string-for-string against the one actually running.
#
# MODES
#   probe          everything above   (default)
#   vm             the VM side only, no device needed
#   help
#
# POINTING IT AT A CARD  -  first match wins:
#   TSP=root@192.168.1.21 sh tsp_theme.sh probe
#   $TSP_DEV / ~/.tsp_dev / root@192.168.1.12
# ===========================================================================

MODE="${1:-probe}"

if ! grep -q '^# TSP_THEME_V1 END OF FILE$' "$0" 2>/dev/null; then
    echo "tsp_theme: this copy of the script is truncated - download it again" >&2
    exit 1
fi

# --- device resolution (CONSTRAINT-two-cards-are-addressed-by-name) --------
DEVICE=""
[ -n "${TSP:-}" ] && DEVICE="$TSP"
[ -z "$DEVICE" ] && [ -n "${DEV:-}" ] && DEVICE="$DEV"
[ -z "$DEVICE" ] && [ -n "${TSP_DEV:-}" ] && DEVICE="$TSP_DEV"
[ -z "$DEVICE" ] && [ -f "$HOME/.tsp_dev" ] && DEVICE="$(cat "$HOME/.tsp_dev" 2>/dev/null)"
[ -z "$DEVICE" ] && DEVICE="root@192.168.1.12"
true

HOSTPART="${DEVICE#*@}"
LABEL=""
if [ -f "$HOME/.tsp_hosts" ]; then
    LABEL="$(awk -v d="$DEVICE" '$2 == d { print $1; exit }' "$HOME/.tsp_hosts" 2>/dev/null)"
fi
[ -n "$LABEL" ] || LABEL="$(echo "$HOSTPART" | tr '.' '-')"

DL="$HOME/Downloads"
[ -d "$DL" ] || DL="$HOME"
TS="$(date +%Y%m%d-%H%M%S)"
OUT="$DL/tsp-theme-$LABEL-$TS.txt"
PULL="$DL/tsp-theme-pull-$LABEL-$TS"
SSHOPTS="-o ConnectTimeout=10 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
ROOT="/mnt/SDCARD/data/ports/openmw"

step() { echo "[$1] $2"; }
die()  { echo "tsp_theme: $*" >&2; exit 1; }
usage() { sed -n '2,35p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }
case "$MODE" in help|-h|--help) usage ;; esac

echo "tsp_theme V1  -  can the manager be re-skinned?"
echo "device: $DEVICE   label: $LABEL"
echo

mkdir -p "$PULL" 2>/dev/null
: > "$OUT"

# ===========================================================================
# A. THE VM SIDE  -  is there anything left to rebuild from?
# ===========================================================================
step 1/5 "looking for the manager controller lineage on this machine"
{
echo "TSP_THEME_V1"
echo "run at: $(date)"
echo
echo "===== A1. CONTROLLER LINEAGE ON THIS VM ====="
echo "(the three that matter: apply_openmw_tsp_manager_v29...sh,"
echo " tsp_mgr_v30_patch.py, tsp_mgr_v31_full.py - that chain reproduces the"
echo " card's current files byte for byte)"
echo
} >> "$OUT"

# Bounded search only - never a recursive sweep of the whole home directory.
FOUND=0
for spec in "$HOME/Downloads:3" "$HOME:2" "$HOME/openmw:3" "$HOME/tsp:3" "/tmp:2"; do
    d="${spec%:*}"; depth="${spec##*:}"
    [ -d "$d" ] || continue
    find "$d" -maxdepth "$depth" \
         \( -name 'apply_openmw_tsp_manager*' \
         -o -name '*before-v30*' \
         -o -name 'tsp_mgr_v3*' \
         -o -name 'build_install_openmw_tsp_manager*' \
         -o -name 'openmw_launcher_manager*.cpp' \
         -o -name 'openmw-tsp-manager-v2*' \) 2>/dev/null
done | sort -u > "$PULL/.lineage.list"

while IFS= read -r f; do
    [ -e "$f" ] || continue
    FOUND=$((FOUND + 1))
    if [ -d "$f" ]; then
        printf '  DIR   %-64s %s entries\n' "$f" "$(ls -1 "$f" 2>/dev/null | wc -l | tr -d ' ')" >> "$OUT"
        continue
    fi
    sz=$(wc -c < "$f" 2>/dev/null | tr -d ' ')
    m5=$(md5sum "$f" 2>/dev/null | cut -c1-8)
    ver=$(grep -a -o 'INTEGRATED V[0-9.]*' "$f" 2>/dev/null | sort -u | tr '\n' ' ')
    cpp=$(grep -a -c 'openmw_launcher_manager\|Framebuffer\|drawText' "$f" 2>/dev/null)
    printf '  FILE  %-64s %9s B  %s\n' "$f" "$sz" "$m5" >> "$OUT"
    printf '        carries C++: %-4s   version strings: %s\n' \
        "$( [ "${cpp:-0}" -gt 0 ] && echo yes || echo no )" "${ver:-none}" >> "$OUT"
done < "$PULL/.lineage.list"
[ "$FOUND" -gt 0 ] || echo "  NOTHING FOUND - the manager source may be gone from this machine" >> "$OUT"
echo "      $FOUND candidate file(s)/dir(s)"

step 2/5 "checking the build container"
{
echo
echo "===== A2. BUILD ENVIRONMENT ====="
} >> "$OUT"
DOCKER=""
if command -v docker >/dev/null 2>&1; then
    if docker ps >/dev/null 2>&1; then DOCKER="docker"
    elif sudo -n true 2>/dev/null && sudo -n docker ps >/dev/null 2>&1; then DOCKER="sudo -n docker"
    fi
fi
if [ -z "$DOCKER" ]; then
    echo "  docker: not usable without a password from this shell" >> "$OUT"
    echo "          (run: sudo docker ps   and re-run this script if it works)" >> "$OUT"
    echo "      docker not reachable without sudo password"
else
    {
    echo "  docker command: $DOCKER"
    echo "  containers:"
    $DOCKER ps -a --format '    {{.Names}}  {{.Status}}  {{.Image}}' 2>/dev/null
    if $DOCKER ps -a --format '{{.Names}}' 2>/dev/null | grep -qx openmw_builder; then
        echo "  openmw_builder: PRESENT"
        echo "  g++-13 inside:  $($DOCKER exec openmw_builder g++-13 --version 2>&1 | head -1)"
        echo "  arch inside:    $($DOCKER exec openmw_builder uname -m 2>&1 | head -1)"
        echo "  source tree:"
        $DOCKER exec openmw_builder sh -c 'ls -la /root/ 2>/dev/null | head -30' 2>&1 | sed 's/^/    /'
    else
        echo "  openmw_builder: ABSENT"
    fi
    } >> "$OUT" 2>&1
    echo "      container inventory captured"
fi

if [ "$MODE" = "vm" ]; then
    echo
    echo "VM REPORT: $OUT"
    sed -n '/A1\./,$p' "$OUT"
    exit 0
fi

# ===========================================================================
# B + C. THE CARD
# ===========================================================================
step 3/5 "checking $DEVICE is reachable"
rout="$(ssh -n $SSHOPTS "$DEVICE" 'echo THEME_SSH_OK; uname -n' 2>&1)"
case "$rout" in
    *THEME_SSH_OK*) echo "      reachable: $(echo "$rout" | tail -1)" ;;
    *)
        echo "      $rout" | head -4
        echo "      If the key is not on this card yet:"
        echo "         sh ~/Downloads/tsp_net.sh key $DEVICE"
        die "cannot reach $DEVICE"
        ;;
esac

step 4/5 "inventorying fonts, music and audio support on the card"
ssh $SSHOPTS "$DEVICE" "ROOT='$ROOT' sh -s" >> "$OUT" 2>&1 <<'THEME_CARD_EOF'
echo
echo "===== B1. FONT FILES ON THE CARD ====="
echo "Morrowind's own bitmap fonts (.fnt + .tex):"
n=0
for d in "$ROOT/data/Data Files/Fonts" "$ROOT/data/Fonts" "$ROOT/resources/mygui"; do
    [ -d "$d" ] || continue
    ls -la "$d" 2>/dev/null | sed 's/^/  /'
    n=$((n + 1))
done
[ "$n" -gt 0 ] || echo "  no font directory found at the usual places"
echo
echo "OpenMW TrueType replacements (this is what the game menus draw with):"
for f in "$ROOT/resources/mygui/MysticCards.ttf" \
         "$ROOT/resources/mygui/DemonicLetters.ttf" \
         "$ROOT/resources/mygui/DejaVuLGCSansMono.ttf"; do
    if [ -f "$f" ]; then printf '  PRESENT  %9s B  %s\n' "$(wc -c < "$f" | tr -d ' ')" "$f"
    else printf '  absent            %s\n' "$f"; fi
done
echo
echo "anything else that looks like a font, bounded search:"
for d in "$ROOT/resources" "$ROOT/data"; do
    [ -d "$d" ] || continue
    find "$d" -maxdepth 3 -type f \( -name '*.ttf' -o -name '*.otf' -o -name '*.fnt' -o -name '*.tex' \) 2>/dev/null \
        | head -40 | while IFS= read -r f; do printf '  %9s B  %s\n' "$(wc -c < "$f" | tr -d ' ')" "$f"; done
done

echo
echo "===== C1. MUSIC FILES ====="
MUS="$ROOT/data/Data Files/Music"
if [ -d "$MUS" ]; then
    echo "  $MUS"
    for sub in Special Explore Battle; do
        [ -d "$MUS/$sub" ] || continue
        echo "  --- $sub ---"
        ls -la "$MUS/$sub" 2>/dev/null | sed 's/^/    /' | head -25
    done
else
    echo "  no Music directory at $MUS"
    find "$ROOT/data" -maxdepth 3 -type d -name 'Music*' 2>/dev/null | sed 's/^/  found: /'
fi

echo
echo "===== C2. WHAT CAN PLAY AUDIO ====="
echo "player binaries on PATH or in the usual places:"
for p in mpg123 mpg321 madplay ffplay ffmpeg aplay paplay sox play ogg123 mplayer; do
    w="$(command -v "$p" 2>/dev/null)"
    if [ -n "$w" ]; then printf '  %-10s %s\n' "$p" "$w"
    else
        hit=""
        for d in /usr/bin /bin /mnt/SDCARD/System/bin /mnt/SDCARD/Apps/PortMaster/PortMaster \
                 /mnt/SDCARD/App/PortMaster "$ROOT/bin" "$ROOT/tools"; do
            [ -x "$d/$p" ] && { hit="$d/$p"; break; }
        done
        if [ -n "$hit" ]; then printf '  %-10s %s (not on PATH)\n' "$p" "$hit"
        else printf '  %-10s -\n' "$p"; fi
    fi
done
echo
echo "audio libraries (a small player can be built against any of these):"
# Match by PREFIX, not an exact filename: these ship version-suffixed
# (libavcodec.so.58, libopenal.so.1.21.1), and an exact-name test would
# report a library that is right there as absent.
for lib in libSDL2_mixer libSDL2-2.0 libopenal libmpg123 libavcodec libavformat \
           libavutil libswresample libvorbisfile libvorbis libogg libsndfile libasound; do
    hit=""
    for d in "$ROOT/lib" /usr/trimui/lib /mnt/SDCARD/System/lib /usr/lib /lib \
             /usr/lib/aarch64-linux-gnu /mnt/SDCARD/Apps/PortMaster/PortMaster/libs; do
        [ -d "$d" ] || continue
        for c in "$d/$lib"*; do
            [ -e "$c" ] || continue
            hit="$c"
            break
        done
        [ -n "$hit" ] && break
    done
    if [ -n "$hit" ]; then printf '  %-16s %s\n' "$lib" "$hit"
    else printf '  %-16s -\n' "$lib"; fi
done
echo
echo "SDL2 audio drivers this card's SDL2 carries:"
SDL2=""
for d in /usr/trimui/lib /mnt/SDCARD/System/lib "$ROOT/lib" /usr/lib /lib; do
    [ -f "$d/libSDL2-2.0.so.0" ] && { SDL2="$d/libSDL2-2.0.so.0"; break; }
done
if [ -n "$SDL2" ]; then
    echo "  $SDL2"
    for drv in alsa pulseaudio sndio dsp oss jack pipewire dummy; do
        grep -a -q -F -e "$drv" "$SDL2" 2>/dev/null && printf '    carries: %s\n' "$drv"
    done
else
    echo "  no libSDL2 found"
fi
echo
echo "ALSA:"
cat /proc/asound/cards 2>/dev/null | sed 's/^/  /' || echo "  /proc/asound/cards not readable"
ls -la /dev/snd 2>/dev/null | sed 's/^/  /' | head -12

echo
echo "===== C3. THE MANAGER BINARY ====="
B="$ROOT/bin/openmw-manager-v2"
if [ -f "$B" ]; then
    printf '  %s\n  %s bytes  md5=%s\n' "$B" "$(wc -c < "$B" | tr -d ' ')" "$(md5sum "$B" | cut -d' ' -f1)"
    echo "  version markers:"
    for m in 'INTEGRATED V3.0' 'INTEGRATED V2.9' 'CONVERT TEXTURES FOR LOW MEMORY' 'ASTC TEXTURES'; do
        printf '    %-34s %s\n' "$m" "$(grep -a -c -F -e "$m" "$B" 2>/dev/null)"
    done
else
    echo "  MISSING: $B"
fi
THEME_CARD_EOF
echo "      $(wc -l < "$OUT" | tr -d ' ') lines captured"

step 5/5 "pulling the manager binary and the font files back"
for f in "$ROOT/bin/openmw-manager-v2" \
         "$ROOT/resources/mygui/MysticCards.ttf" \
         "$ROOT/resources/mygui/DemonicLetters.ttf" \
         "$ROOT/resources/mygui/DejaVuLGCSansMono.ttf" \
         "$ROOT/data/Data Files/Fonts/magic_cards_regular_font.fnt" \
         "$ROOT/data/Data Files/Fonts/magic_cards_regular_font.tex" \
         "$ROOT/data/Data Files/Fonts/century_gothic_font.fnt" \
         "$ROOT/data/Data Files/Fonts/century_gothic_font.tex" \
         "$ROOT/data/Data Files/Fonts/daedric_font.fnt" \
         "$ROOT/data/Data Files/Fonts/daedric_font.tex"; do
    base="$(basename "$f")"
    if scp $SSHOPTS "$DEVICE:$f" "$PULL/$base" >/dev/null 2>&1; then
        printf '      got  %-38s %s bytes\n' "$base" "$(wc -c < "$PULL/$base" | tr -d ' ')"
    else
        printf '      --   %-38s not present\n' "$base"
    fi
done
rm -f "$PULL/.lineage.list"

echo
echo "--------------------------------------------------------------"
sed -n '/A1\. CONTROLLER LINEAGE/,/A2\./p' "$OUT" | head -40
echo "--------------------------------------------------------------"
sed -n '/OpenMW TrueType replacements/,/anything else/p' "$OUT"
echo "--------------------------------------------------------------"
sed -n '/C2\. WHAT CAN PLAY AUDIO/,/audio libraries/p' "$OUT"
echo "--------------------------------------------------------------"
echo
echo "FULL REPORT : $OUT"
echo "PULLED FILES: $PULL"
echo
echo "Send me the report and the pulled folder and I will build the re-skin"
echo "against what this card actually has."

# TSP_THEME_V1 END OF FILE
