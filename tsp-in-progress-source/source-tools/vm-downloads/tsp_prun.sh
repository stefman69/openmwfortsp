#!/usr/bin/env bash
# TSP_PRUN_V1 - run the post-spike decay analysis on the dumps already on the card.
#
#   bash ~/Downloads/tsp_prun.sh
#
# READ ONLY except for copying tsp_post.sh over. No play session needed: the four
# dumps captured on 2026-09-10 at 18:59-19:01 are the current build and they contain
# the save load plus the gameplay after it.
#
# Rule Zero: file, not paste; r() uses -n, rin() takes the heredoc.

set -u

TSP="${TSP:-root@192.168.1.12}"
SSH_OPTS="-o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=6"
DL="${DL:-$HOME/Downloads}"
REP="$DL/tsp-post-$(date +%Y%m%d-%H%M%S).txt"
EXPP=a6e3ba90fbd63851985c79db7bcbda00

r()   { ssh -n $SSH_OPTS "$TSP" "$@"; }
rin() { ssh    $SSH_OPTS "$TSP" "$@"; }

r 'echo ok' >/dev/null 2>&1 || { echo "FAIL: cannot reach the TSP at $TSP" >&2; exit 1; }

LP="$(md5sum "$DL/tsp_post.sh" 2>/dev/null | cut -d' ' -f1)"
[ "${LP:-x}" = "$EXPP" ] || { echo "FAIL: $DL/tsp_post.sh md5 ${LP:-missing} != $EXPP"; exit 1; }
scp -q $SSH_OPTS "$DL/tsp_post.sh" "$TSP:/mnt/SDCARD/" </dev/null || exit 1
DP="$(r 'md5sum /mnt/SDCARD/tsp_post.sh' | cut -d' ' -f1)"
[ "$DP" = "$EXPP" ] || { echo "FAIL: landed as $DP"; exit 1; }
r 'chmod +x /mnt/SDCARD/tsp_post.sh'
echo "VERIFIED: tsp_post.sh on device at $DP"

rin 'sh -s' <<'REMOTE' > "$REP" 2>&1
# ---- TSP_PRUN_REMOTE_BEGIN ----
S="${S:-/mnt/SDCARD}"
G="${G:-$S/data/ports/openmw}"

echo "########## WHICH DUMPS, AND WHAT ARMED THEM ##########"
if ls "$S"/tsp_ring.[0-9]* >/dev/null 2>&1; then
    ls -la "$S"/tsp_ring.[0-9]*
else
    echo "no loose dumps; falling back to the newest archive"
fi
echo
grep -a 'TSP_RING_DUMP' "$G/openmw_log.txt" 2>/dev/null
echo

D="$(ls "$S"/tsp_ring.[0-9]* 2>/dev/null)"
if [ -z "$D" ]; then
    A="$(ls -td "$S"/tsp_hitch_archive_* 2>/dev/null | head -1)"
    [ -n "$A" ] && D="$(ls "$A"/tsp_ring.[0-9]* 2>/dev/null)"
fi
if [ -z "$D" ]; then echo "no dumps anywhere"; exit 0; fi

echo "########## POST-SPIKE DECAY, 5 s BUCKETS ##########"
# shellcheck disable=SC2086
TSP_BUCKET=5 sh "$S/tsp_post.sh" $D
echo

echo "########## SAME, 10 s BUCKETS (smoother, for the longer dumps) ##########"
# shellcheck disable=SC2086
TSP_BUCKET=10 sh "$S/tsp_post.sh" $D 2>&1 | grep -E '^=|^spike|^BEFORE|^ *[0-9]+-|^first bucket|DECAYING|FLAT|RISING|LOW fault'
echo

echo "########## HOW THE TEXTURES ARE STORED ##########"
echo "-- loose ktx files, which is what the conversion produced --"
printf 'count: %s\n' "$(find "$G/data/Data Files/textures" -name '*.ktx' 2>/dev/null | wc -l)"
printf 'bytes: %s\n' "$(find "$G/data/Data Files/textures" -name '*.ktx' -exec wc -c {} + 2>/dev/null | tail -1)"
echo "-- the archives they came from --"
ls -la "$G/data/Data Files"/*.bsa 2>/dev/null
echo
echo "-- readahead and memory right now --"
for d in mmcblk0 mmcblk1; do
    printf '%s read_ahead_kb=%s\n' "$d" "$(cat "/sys/block/$d/queue/read_ahead_kb" 2>/dev/null || echo '?')"
done
grep -E 'MemAvailable|MemFree|^Cached|SwapFree' /proc/meminfo
# ---- TSP_PRUN_REMOTE_END ----
REMOTE

cat "$REP"
echo
echo "full report: $REP"
