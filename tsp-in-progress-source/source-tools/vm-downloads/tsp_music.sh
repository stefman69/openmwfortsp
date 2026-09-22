#!/bin/sh
# ===========================================================================
# tsp_music.sh  -  TSP_MUSIC_V1
#
# Installs the Morrowind title theme as the OpenMW Manager's menu music, on
# every card, and needs no rebuild: the manager binary has no audio code, so
# the wrapper loops the track (that part ships with the V3.3 controller).
#
# WHY A WAV AND NOT THE MP3
#   aplay is the only player BOTH cards have. The CrossMix card also has
#   mpg123 and ffmpeg; the stock TrimUI card has no mp3 decoder at all. So the
#   theme is decoded once, on whichever machine can do it, and the same WAV is
#   copied to every card.
#
# MODES
#   install        decode once, copy to every card, verify   (default)
#   status         what is installed on each card, read-only
#   remove         delete the WAV from every card
#   help
#
# WHICH CARDS  -  first match wins:
#   TSP=root@192.168.1.21 sh tsp_music.sh install    one card only
#   ~/.tsp_hosts                                     every card listed there
#   otherwise                                        root@192.168.1.21 and .12
# ===========================================================================

MODE="${1:-install}"

if ! grep -q '^# TSP_MUSIC_V1 END OF FILE$' "$0" 2>/dev/null; then
    echo "tsp_music: this copy of the script is truncated - download it again" >&2
    exit 1
fi

DEVICES=""
if   [ -n "${TSP:-}" ]; then DEVICES="$TSP"
elif [ -n "${DEV:-}" ]; then DEVICES="$DEV"
elif [ -f "$HOME/.tsp_hosts" ]; then
    DEVICES="$(awk 'NF >= 2 && $1 !~ /^#/ { print $2 }' "$HOME/.tsp_hosts" 2>/dev/null | sort -u | tr '\n' ' ')"
fi
[ -n "$DEVICES" ] || DEVICES="root@192.168.1.21 root@192.168.1.12"

label_for() {
    _l=""
    if [ -f "$HOME/.tsp_hosts" ]; then
        _l="$(awk -v d="$1" '$2 == d { print $1; exit }' "$HOME/.tsp_hosts" 2>/dev/null)"
    fi
    [ -n "$_l" ] || _l="$(echo "${1#*@}" | tr '.' '-')"
    printf '%s' "$_l"
}

SSHOPTS="-o ConnectTimeout=10 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
ROOT="/mnt/SDCARD/data/ports/openmw"
WAV="$ROOT/launcher/manager-theme.wav"
WORK="${TMPDIR:-/tmp}/tsp-music.$$"
LOCAL_WAV="$WORK/manager-theme.wav"
mkdir -p "$WORK" 2>/dev/null
cleanup() { rm -rf "$WORK" 2>/dev/null; }

step() { echo "[$1] $2"; }
die()  { echo "tsp_music: $*" >&2; cleanup; exit 1; }
usage() { sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; cleanup; exit 0; }
case "$MODE" in help|-h|--help) usage ;; esac

echo "tsp_music V1  -  manager menu music"
printf 'cards:'
for d in $DEVICES; do printf ' %s (%s)' "$d" "$(label_for "$d")"; done
echo; echo

# The theme, in the two spellings the cards actually use.
SRC_CANDIDATES="$ROOT/data/Data Files/Music/Special/morrowind title.mp3
$ROOT/data/Data Files/Music/Explore/Morrowind Title.mp3"

# ---------------------------------------------------------------------------
reachable() { ssh -n $SSHOPTS "$1" 'echo MUSIC_SSH_OK' 2>/dev/null | grep -q MUSIC_SSH_OK; }

LIVE=""
step 1/5 "checking the cards"
for d in $DEVICES; do
    if reachable "$d"; then
        echo "      $(label_for "$d") reachable"
        LIVE="$LIVE $d"
    else
        echo "      $(label_for "$d") UNREACHABLE - skipping"
    fi
done
[ -n "$LIVE" ] || die "no card is reachable"

# ---------------------------------------------------------------------------
case "$MODE" in
status)
    step 2/5 "reading"
    for d in $LIVE; do
        echo "  --- $(label_for "$d") ---"
        ssh $SSHOPTS "$d" "WAV='$WAV' sh -s" <<'MUSIC_STATUS_EOF'
if [ -s "$WAV" ]; then
    printf '    WAV present  %s bytes\n' "$(wc -c < "$WAV" | tr -d ' ')"
    printf '    header       %s\n' "$(head -c 4 "$WAV")"
else
    echo "    WAV MISSING: $WAV"
fi
printf '    aplay        %s\n' "$(command -v aplay 2>/dev/null || echo 'NOT PRESENT')"
printf '    wrapper hook %s\n' \
    "$(grep -c tsp_music_start /mnt/SDCARD/Roms/PORTS/OpenMW_Manager.sh 2>/dev/null)"
MUSIC_STATUS_EOF
    done
    cleanup; exit 0
    ;;
remove)
    step 2/5 "removing"
    for d in $LIVE; do
        ssh -n $SSHOPTS "$d" "rm -f '$WAV' '$ROOT/launcher/.music-aplay.pid'" 2>/dev/null
        echo "      $(label_for "$d") cleared"
    done
    cleanup; exit 0
    ;;
esac

# ---------------------------------------------------------------------------
# 2. does any card already have it?
# ---------------------------------------------------------------------------
step 2/5 "looking for a copy that already exists"
HAVE=""
NEED=""
for d in $LIVE; do
    if ssh -n $SSHOPTS "$d" "[ -s '$WAV' ]" 2>/dev/null; then
        echo "      $(label_for "$d") already has it"
        HAVE="$HAVE $d"
    else
        NEED="$NEED $d"
    fi
done
if [ -z "$NEED" ]; then
    echo
    echo "Every card already has the theme. Nothing to do."
    echo "  (force a rebuild with: sh $0 remove   then run install again)"
    cleanup
    exit 0
fi

# ---------------------------------------------------------------------------
# 3. get one WAV, from wherever it can be made
# ---------------------------------------------------------------------------
step 3/5 "producing one WAV"
GOT=0

# 3a. a card that already has it - just pull it down
for d in $HAVE; do
    if scp $SSHOPTS "$d:$WAV" "$LOCAL_WAV" >/dev/null 2>&1 && [ -s "$LOCAL_WAV" ]; then
        echo "      copied the existing WAV off $(label_for "$d")"
        GOT=1
        break
    fi
done

# 3b. decode on a card that has a decoder - this is the CrossMix card
if [ "$GOT" -eq 0 ]; then
    for d in $LIVE; do
        echo "      trying to decode on $(label_for "$d")"
        out="$(ssh $SSHOPTS "$d" "ROOT='$ROOT' WAV='$WAV' sh -s" 2>&1 <<'MUSIC_DECODE_EOF'
# Some of these tools are PortMaster builds that want the port's own libs.
LD_LIBRARY_PATH="$ROOT/lib:${LD_LIBRARY_PATH:-}"
export LD_LIBRARY_PATH

SRC=""
for c in "$ROOT/data/Data Files/Music/Special/morrowind title.mp3" \
         "$ROOT/data/Data Files/Music/Explore/Morrowind Title.mp3"; do
    [ -s "$c" ] && { SRC="$c"; break; }
done
if [ -z "$SRC" ]; then
    echo "NO_SOURCE"
    echo "  looked in $ROOT/data/Data Files/Music/{Special,Explore}"
    ls -la "$ROOT/data/Data Files/Music" 2>&1 | head -10
    exit 1
fi
echo "  source: $SRC ($(wc -c < "$SRC" | tr -d ' ') bytes)"

mkdir -p "$(dirname "$WAV")" 2>/dev/null
TMPW="$WAV.incoming"
FOUND=0

# Try EVERY decoder in turn, not the first one that merely exists: a stripped
# ffmpeg with no mp3 decoder used to mean mpg123 was never reached. And keep
# the stderr - throwing it away is what made the last failure undiagnosable.
for tool in mpg123 ffmpeg; do
    command -v "$tool" >/dev/null 2>&1 || { echo "  $tool: not present"; continue; }
    FOUND=1
    rm -f "$TMPW"
    echo "  trying $tool ($(command -v "$tool"))"
    case "$tool" in
        mpg123) mpg123 -w "$TMPW" "$SRC" 2>&1 | tail -4 | sed 's/^/    /' ;;
        ffmpeg) ffmpeg -nostdin -y -loglevel warning -i "$SRC" \
                       -ar 44100 -ac 2 -c:a pcm_s16le "$TMPW" 2>&1 | tail -6 | sed 's/^/    /' ;;
    esac
    if [ -s "$TMPW" ] && [ "$(head -c 4 "$TMPW")" = "RIFF" ]; then
        mv -f "$TMPW" "$WAV"
        echo "DECODED $(wc -c < "$WAV" | tr -d ' ') via $tool"
        exit 0
    fi
    echo "    $tool produced no usable WAV"
done
rm -f "$TMPW"
[ "$FOUND" -eq 1 ] || { echo "NO_DECODER"; exit 1; }
echo "DECODE_FAILED"
exit 1
MUSIC_DECODE_EOF
)" || true
        case "$out" in
            *DECODED*)
                sz="$(echo "$out" | sed -n 's/^DECODED \([0-9]*\).*/\1/p')"
                echo "      decoded on $(label_for "$d"): $sz bytes"
                if scp $SSHOPTS "$d:$WAV" "$LOCAL_WAV" >/dev/null 2>&1 && [ -s "$LOCAL_WAV" ]; then
                    GOT=1
                    NEED="$(echo "$NEED" | sed "s#$d##")"
                    break
                fi
                echo "      but could not copy it back off $(label_for "$d")"
                ;;
            *NO_DECODER*) echo "      $(label_for "$d") has no mp3 decoder" ;;
            *NO_SOURCE*)
                echo "      $(label_for "$d") has no title theme on it:"
                echo "$out" | sed 's/^/        /'
                ;;
            *)
                # Never hide this again.
                echo "      $(label_for "$d") could not decode - what it said:"
                echo "$out" | sed 's/^/        /'
                ;;
        esac
    done
fi

# 3c. decode on this machine
if [ "$GOT" -eq 0 ]; then
    for d in $LIVE; do
        for c in "$ROOT/data/Data Files/Music/Special/morrowind title.mp3" \
                 "$ROOT/data/Data Files/Music/Explore/Morrowind Title.mp3"; do
            if scp $SSHOPTS "$d:$c" "$WORK/theme.mp3" >/dev/null 2>&1 && [ -s "$WORK/theme.mp3" ]; then
                break 2
            fi
        done
    done
    if [ -s "$WORK/theme.mp3" ]; then
        echo "      pulled the mp3 to this machine ($(wc -c < "$WORK/theme.mp3" | tr -d ' ') bytes)"
        for tool in mpg123 ffmpeg sox; do
            command -v "$tool" >/dev/null 2>&1 || { echo "      $tool: not on this machine"; continue; }
            echo "      trying $tool here"
            rm -f "$LOCAL_WAV"
            case "$tool" in
                mpg123) mpg123 -w "$LOCAL_WAV" "$WORK/theme.mp3" 2>&1 | tail -3 | sed 's/^/        /' ;;
                ffmpeg) ffmpeg -nostdin -y -loglevel warning -i "$WORK/theme.mp3" \
                               -ar 44100 -ac 2 -c:a pcm_s16le "$LOCAL_WAV" 2>&1 | tail -4 | sed 's/^/        /' ;;
                sox)    sox "$WORK/theme.mp3" -r 44100 -c 2 -b 16 "$LOCAL_WAV" 2>&1 | tail -3 | sed 's/^/        /' ;;
            esac
            if [ -s "$LOCAL_WAV" ] && [ "$(head -c 4 "$LOCAL_WAV")" = "RIFF" ]; then
                GOT=1
                break
            fi
            echo "        $tool produced no usable WAV"
        done
    else
        echo "      could not pull the mp3 off any card either"
    fi
fi

if [ "$GOT" -eq 0 ] || [ ! -s "$LOCAL_WAV" ]; then
    echo
    echo "      Could not produce a WAV anywhere. Install a decoder on this VM:"
    echo "         sudo apt-get install -y ffmpeg"
    die "no decoder on any card or on this machine"
fi
if [ "$(head -c 4 "$LOCAL_WAV")" != "RIFF" ]; then
    die "the decoded file is not a WAV"
fi
WAVSZ="$(wc -c < "$LOCAL_WAV" | tr -d ' ')"
echo "      WAV ready: $WAVSZ bytes"

# ---------------------------------------------------------------------------
step 4/5 "copying to the cards that need it"
for d in $NEED; do
    [ -n "$d" ] || continue
    printf '      %s ... ' "$(label_for "$d")"
    ssh -n $SSHOPTS "$d" "mkdir -p '$ROOT/launcher'" >/dev/null 2>&1
    if scp $SSHOPTS "$LOCAL_WAV" "$d:$WAV.incoming" >/dev/null 2>&1 &&
       ssh -n $SSHOPTS "$d" "mv -f '$WAV.incoming' '$WAV'" >/dev/null 2>&1; then
        echo "sent"
    else
        echo "FAILED"
    fi
done

# ---------------------------------------------------------------------------
step 5/5 "verifying on every card"
OK=0
BAD=0
for d in $LIVE; do
    res="$(ssh $SSHOPTS "$d" "WAV='$WAV' sh -s" 2>/dev/null <<'MUSIC_VERIFY_EOF'
[ -s "$WAV" ] || { echo "MISSING"; exit 0; }
[ "$(head -c 4 "$WAV")" = "RIFF" ] || { echo "NOT_A_WAV"; exit 0; }
command -v aplay >/dev/null 2>&1 || { echo "NO_APLAY"; exit 0; }
printf 'OK %s\n' "$(wc -c < "$WAV" | tr -d ' ')"
MUSIC_VERIFY_EOF
)"
    case "$res" in
        OK*) echo "      $(label_for "$d")  ready, $(echo "$res" | awk '{print $2}') bytes"; OK=$((OK+1)) ;;
        *)   echo "      $(label_for "$d")  $res"; BAD=$((BAD+1)) ;;
    esac
done

echo
echo "ready on $OK card(s), problems on $BAD"
echo
echo "The music starts with the manager and stops before the game launches."
echo "To turn it off for one run:  TSP_MANAGER_MUSIC=0"
echo "To remove it entirely:       sh $0 remove"
cleanup
exit 0

# TSP_MUSIC_V1 END OF FILE
