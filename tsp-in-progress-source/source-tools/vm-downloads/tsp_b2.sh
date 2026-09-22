#!/usr/bin/env bash
# TSP_B2_V1 - the whole B2 "12 ms swap floor" plan behind one-line subcommands.
#
#   bash ~/Downloads/tsp_b2.sh probe        read-only: GPU clock, governors, DRM, thermal
#   bash ~/Downloads/tsp_b2.sh bench        build + install the display-path bench (no play session)
#   bash ~/Downloads/tsp_b2.sh clock on     pin the Mali clock at max + start the 1 Hz sampler
#   bash ~/Downloads/tsp_b2.sh clock off    restore the clock and stop the sampler
#   bash ~/Downloads/tsp_b2.sh cpu read     read-only: cpufreq on BOTH consoles
#   bash ~/Downloads/tsp_b2.sh cpu on       lift the cpufreq cap to the silicon max
#   bash ~/Downloads/tsp_b2.sh cpu off      put cpufreq back exactly as it was
#   bash ~/Downloads/tsp_b2.sh scaler       install a "Morrowind NoScaler" entry (scaler shim dropped)
#   bash ~/Downloads/tsp_b2.sh why          read-only: why the bench got no window
#   bash ~/Downloads/tsp_b2.sh read         pull and score everything collected so far
#   bash ~/Downloads/tsp_b2.sh clean        undo all of it
#
# Run them in that order. probe and bench need no play session at all.
#
# WHAT THIS IS FOR
#   The steady frame is cull ~10 + draw ~13 + swap ~12 ms, and the swap 12 ms is
#   BLOCKED, not CPU. Under KMSDRM + Mali, SDL_GL_SwapWindow does: wait for the
#   previous page flip -> eglSwapBuffers -> gbm_surface_lock_front_buffer (which
#   blocks until THIS frame`s fragment jobs finish on the GPU) -> drmModePageFlip.
#   So the 12 ms is one of exactly three things:
#     A  the GPU is stuck at 150 MHz, so its work is slow and lands inside swap
#     B  swap interval 0 is ignored, so every flip waits for a vblank (16.7 ms)
#     C  the fullscreen scaler shim is doing a real full-screen pass at native res
#   B1 already told us it is NOT texture-fetch bound: ASTC halved per-texel
#   bandwidth and swap did not move.
#
# WHAT THIS SCRIPT DOES NOT DO
#   It never edits Morrowind.sh. The clock experiment is applied over ssh and
#   reverted over ssh; the scaler experiment is a SEPARATE copied Ports entry.
#   That is a deliberate change from the outline, which wanted a launcher block
#   with a trap - I cannot see the launcher`s existing exit hook from here, and a
#   second trap would silently replace the one that restores the CPU governor.
#   It also never touches the ring profiler, which stays off.

set -u

# Device address, in order: an explicit TSP= in the environment, then $TSP_DEV
# as `tsp_net.sh each` sets it, then ~/.tsp_dev as `tsp_net.sh use` writes it,
# then the old hardcoded default. Two cards do not share an address, and a tool
# pointed at the wrong one reports that card state as if it were this one.
# Every line here returns 0, so a missing ~/.tsp_dev cannot trip set -e.
TSP="${TSP:-${TSP_DEV:-}}"
if [ -z "${TSP}" ] && [ -r "$HOME/.tsp_dev" ]; then TSP="$(cat "$HOME/.tsp_dev")"; fi
[ -n "${TSP}" ] || TSP="root@192.168.1.12"
# WHICH CONSOLE THIS IS. Printed on EVERY run, and it goes into the saved log
# too. With two consoles in play, output that does not name the device it
# touched is not a result - `tsp_verdict.sh arm` printed an arm confirmation
# with no device on it, which is worse than useless because it looks complete.
[ -n "${TSP_NAME:-}" ] || TSP_NAME="$(awk -F'\t' -v h="$TSP" '$2==h {print $1}' "$HOME/.tsp_hosts" 2>/dev/null | head -1)"
printf '\n  ==================  DEVICE: %s  (%s)  ==================\n' "${TSP_NAME:-UNNAMED}" "$TSP"
# $TSP_NAME is set by `tsp_net.sh each`. It goes in the filename because
# $STAMP has one-second resolution: two cards finishing inside the same second
# wrote the same file and the second overwrote the first.
DEVTAG=""
[ -n "${TSP_NAME:-}" ] && DEVTAG="-$(printf '%s' "$TSP_NAME" | tr -c 'A-Za-z0-9._-' '_')"
SSH_OPTS="-o ConnectTimeout=8 -o StrictHostKeyChecking=no -o BatchMode=yes -o LogLevel=ERROR"
CONT="openmw_builder"
GAME="/mnt/SDCARD/data/ports/openmw"
CARD="/mnt/SDCARD"
PORTS="$CARD/Roms/PORTS"
LAUNCHER="$PORTS/Morrowind.sh"
BENCH="$CARD/tsp_swapbench"
BENCH_ENTRY="$PORTS/TSP Swap Bench.sh"
NOSCALER_ENTRY="$PORTS/Morrowind NoScaler.sh"
PROG="$CARD/tsp_prog.txt"
GPUWATCH="/tmp/tsp_gpuwatch.txt"
SAVED="$CARD/tsp_gpu_perf.saved"
CSRC_MD5="7e987632b9c637e60a52f5c0efe65452"
STAMP="$(date +%Y%m%d-%H%M%S)"

# Rule Zero #3: exactly two ssh wrappers. Nothing else in this file calls ssh.
r()   { ssh -n $SSH_OPTS "$TSP" "$@"; }
rin() { ssh    $SSH_OPTS "$TSP" "$@"; }
# rbg: fire and forget. A detached child can keep the ssh channel open even with
# every fd redirected, so this one is bounded. Exit 124 means the timeout fired,
# which is not the same as failure - the caller checks for the effect instead.
rbg() {
    if command -v timeout >/dev/null 2>&1; then timeout 12 ssh -n $SSH_OPTS "$TSP" "$@"
    else ssh -n $SSH_OPTS "$TSP" "$@"; fi
}

die()  { echo; echo "ABORT: $*"; exit 1; }
head2() { echo; echo "########## $* ##########"; }

need_device() {
    r "test -d $GAME" || die "cannot reach $GAME on $TSP - device off, asleep, or off the network"
}
need_container() {
    command -v docker >/dev/null 2>&1 || die "docker not on PATH"
    docker ps --format '{{.Names}}' | grep -q "^${CONT}$" || die "container $CONT is not running"
}

usage() {
    sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
}

# Device-side GPU node discovery, used by more than one subcommand. Prints shell
# assignments on stdout: GPUNODE=..., MALI=..., MAXF=...
#
# It goes over a QUOTED heredoc, not `sh -c '...'`. The body contains a '' empty
# string in the case pattern, and a single-quoted -c argument would have been
# terminated by it - the same class of bug as the mmap'd apostrophe that got
# shipped twice inside an awk program.
#
# Every sysfs read uses cat, never `read -r x < file`. On busybox AND dash a
# single-value sysfs file read with `read` returns only the FIRST CHARACTER -
# "1" for "150000000". The B2 outline's 1 Hz sampler has exactly that bug and
# would have logged a column of 1s and 8s instead of frequencies.
discover() {
    rin "sh -s" <<'DISCEOF'
MALI=""
for p in /sys/class/misc/mali0/device /sys/devices/platform/*gpu* /sys/devices/platform/*mali*; do
    [ -e "$p/power_policy" ] && { MALI="$p"; break; }
done

# NOT "highest max_freq wins". That is what this used to do, and on the real
# device it chose 3120000.dmcfreq - the DDR memory controller at 1.2 GHz - over
# 1800000.gpu, the Mali at 888 MHz. Pinning the DMC would have done nothing (it
# is already performance/1.2 GHz) and reported success: another "raised it,
# changed nothing" false verdict, which is the exact failure this script exists
# to avoid. A frequency is not an identity.
#
# Identity, strongest first:
#   1. the devfreq that hangs off the Mali platform device itself
#   2. a devfreq whose ->device resolves to the same platform device as mali0
#   3. a devfreq whose own name says gpu
# and then it REFUSES, rather than picking something.
GPUNODE=""; WHY=""
if [ -n "$MALI" ] && [ -d "$MALI/devfreq" ]; then
    for d in "$MALI"/devfreq/*; do
        [ -e "$d/max_freq" ] || continue
        GPUNODE="$d"; WHY="it is the Mali platform device own devfreq"; break
    done
fi
if [ -z "$GPUNODE" ] && [ -n "$MALI" ]; then
    MREAL=$(cd "$MALI" 2>/dev/null && pwd -P)
    for d in /sys/class/devfreq/*; do
        [ -e "$d/max_freq" ] || continue
        DREAL=$(cd "$d/device" 2>/dev/null && pwd -P)
        [ -n "$DREAL" ] && [ "$DREAL" = "$MREAL" ] && {
            GPUNODE="$d"; WHY="its device resolves to the same node as mali0"; break; }
    done
fi
if [ -z "$GPUNODE" ]; then
    for d in /sys/class/devfreq/*; do
        [ -e "$d/max_freq" ] || continue
        case "${d##*/}" in
            *dmc*|*ddr*|*mbus*|*cpu*) continue;;
            *gpu*|*mali*) GPUNODE="$d"; WHY="its devfreq name says gpu"; break;;
        esac
    done
fi
MAXF=""
[ -n "$GPUNODE" ] && MAXF=$(cat "$GPUNODE/max_freq" 2>/dev/null)
# Every value is QUOTED. This file is read with `.` in five places, and
# GPUWHY carries a sentence: unquoted, "GPUWHY=it is the Mali..." sources as an
# assignment followed by `is` as a command, which is the "is: command not found"
# on line 4 of the read output. A sourced key=value file has no optional quotes.
echo "GPUNODE='$GPUNODE'"
echo "MALI='$MALI'"
echo "MAXF='$MAXF'"
echo "GPUWHY='$WHY'"
DISCEOF
}

################################################################################
MODE="${1:-help}"
SUB="${2:-}"
case "$MODE" in help|-h|--help) usage;; esac

################################################################################
# probe - read only, nothing is changed anywhere
################################################################################
if [ "$MODE" = "probe" ]; then
    need_device
    OUT="$HOME/Downloads/tsp-b2-probe${DEVTAG}-$STAMP.txt"
    {
    head2 "0. WHAT THIS ANSWERS"
    echo "  Which devfreq node is the GPU, what OPPs it has, how long it has spent"
    echo "  at each one, whether a performance governor exists, whether the Mali"
    echo "  power policy can be pinned always_on, and who else on this OS might be"
    echo "  resetting the governor behind us. Nothing here is written."

    head2 "1. DEVFREQ NODES"
    rin "sh -s" <<'REMOTE'
for d in /sys/class/devfreq/*; do
    [ -e "$d/cur_freq" ] || continue
    echo "  $d"
    echo "    governor=$(cat $d/governor 2>/dev/null)"
    echo "    cur=$(cat $d/cur_freq 2>/dev/null)  min=$(cat $d/min_freq 2>/dev/null)  max=$(cat $d/max_freq 2>/dev/null)"
    echo "    available_governors=$(cat $d/available_governors 2>/dev/null)"
    echo "    available_frequencies=$(cat $d/available_frequencies 2>/dev/null)"
    if [ -w "$d/governor" ]; then echo "    governor is WRITABLE"; else echo "    governor is NOT writable"; fi
    if [ -w "$d/min_freq" ]; then echo "    min_freq is WRITABLE"; else echo "    min_freq is NOT writable"; fi
    echo "    -- trans_stat: time-in-state. The 150 MHz row is the story --"
    cat "$d/trans_stat" 2>/dev/null | head -14 | sed 's/^/      /'
done
REMOTE

    head2 "2. THE GPU NODE THIS SCRIPT WILL USE"
    discover | sed 's/^/  /'

    head2 "3. MALI KBASE"
    rin "sh -s" <<'REMOTE'
FOUND=0
for p in /sys/class/misc/mali0/device /sys/devices/platform/*gpu* /sys/devices/platform/*mali*; do
    [ -d "$p" ] || continue
    echo "  $p"
    for f in power_policy gpuinfo dvfs_period core_mask js_scheduling_period; do
        [ -e "$p/$f" ] && echo "    $f: $(cat $p/$f 2>/dev/null)"
    done
    FOUND=1
done
[ "$FOUND" = "1" ] || echo "  no kbase node with power_policy found"
echo "  (power_policy prints the list with the ACTIVE one in brackets. coarse_demand"
echo "   power-gates between frames; always_on does not.)"
REMOTE

    head2 "4. THERMAL"
    r "for t in /sys/class/thermal/thermal_zone*; do echo \"  \$t \$(cat \$t/type 2>/dev/null) \$(cat \$t/temp 2>/dev/null)\"; done"

    head2 "5. DRM / DISPLAY"
    rin "sh -s" <<'REMOTE'
echo "  /dev/dri:"; ls -la /dev/dri/ 2>/dev/null | sed 's/^/    /'
echo "  card0 driver:"; cat /sys/class/drm/card0/device/uevent 2>/dev/null | head -6 | sed 's/^/    /'
echo "  modes:"
for c in /sys/class/drm/card0-*/; do
    [ -e "$c/status" ] || continue
    echo "    $(basename $c) status=$(cat $c/status 2>/dev/null) enabled=$(cat $c/enabled 2>/dev/null)"
    cat "$c/modes" 2>/dev/null | head -3 | sed 's/^/      mode /'
done
REMOTE
    echo "  NOTE: DRM_CAP_ASYNC_PAGE_FLIP is not exposed in sysfs. The bench answers"
    echo "  it directly - if it prints 'interval req=0 got=1' then SDL could not turn"
    echo "  vsync off and candidate B is confirmed without another measurement."

    head2 "6. WHO ELSE TOUCHES DEVFREQ (the reason a past attempt 'changed nothing')"
    rin "sh -s" <<'REMOTE'
for d in /etc/init.d /usr/trimui /mnt/SDCARD/.tmp_update /mnt/SDCARD/System; do
    [ -d "$d" ] || continue
    echo "  -- $d --"
    find "$d" -type f 2>/dev/null | head -400 | while read -r f; do
        if grep -l -e devfreq -e power_policy -e cur_freq "$f" >/dev/null 2>&1; then echo "    $f"; fi
    done
done
echo "  (busybox grep -r silently matches nothing, so this walks with find instead)"
REMOTE

    head2 "7. THE SWAP TIMING SHIMS - is anything already collecting"
    r "for f in $CARD/tsp_state.txt $CARD/tsp_gltime.txt; do if [ -f \"\$f\" ]; then echo \"  \$f  \$(wc -l < \$f) lines  \$(ls -l \$f | awk '{print \$5}') bytes\"; else echo \"  \$f  absent\"; fi; done"
    r "if [ -f $CARD/tsp_ring_off ]; then echo '  ring profiler: OFF (correct, leave it)'; else echo '  ring profiler: ARMED - it halves the framerate and will void every number below'; fi"

    head2 "8. NEXT"
    echo "  bash ~/Downloads/tsp_b2.sh bench"
    echo "  That builds the display-path bench and installs it as its own Ports entry."
    echo "  It needs no OpenMW rebuild and no play session - it runs in about 10 seconds."
    } 2>&1 | tee "$OUT"
    echo
    echo "full report: $OUT"
    exit 0
fi

################################################################################
# bench - build the display-path bench, install it as its own Ports entry
################################################################################
if [ "$MODE" = "bench" ]; then
    need_container
    need_device
    # Same transcript pattern probe and read already use. The container build is
    # the one output here that can get long (a compiler error dump), and that is
    # exactly the output I need in full - so it goes to a file to upload rather
    # than a wall of terminal to paste. Nothing is truncated either way.
    OUT="$HOME/Downloads/tsp-b2-bench${DEVTAG}-$STAMP.txt"
    {
    head2 "1. SHIP THE SOURCE INTO THE CONTAINER"
    docker exec -i "$CONT" sh -c 'base64 -d > /root/tsp_swapbench.c' <<'B64EOF'
LyogdHNwX3N3YXBiZW5jaC5jIC0gVFNQX1NXQVBCRU5DSF9WMgogKgogKiBNZWFzdXJlcyB0aGUg
c3dhcCAvIGRpc3BsYXkgZmxvb3Igd2l0aCBPcGVuTVcgY29tcGxldGVseSBvdXQgb2YgdGhlIHBp
Y3R1cmUuCiAqCiAqICAgdHNwX3N3YXBiZW5jaCA8bW9kZSAwLTM+IFtmcmFtZXM9MzAwXSBbcXVh
ZHM9NF0KICoKICogICAgIG1vZGUgMCAgZ2xDbGVhciArIFNETF9HTF9Td2FwV2luZG93LCBpbnRl
cnZhbCAwICAgdGhlIHJhdyBmbGlwIGZsb29yCiAqICAgICBtb2RlIDEgIE4gYmxlbmRlZCBmdWxs
LXNjcmVlbiB0ZXh0dXJlZCBxdWFkcyArIHN3YXAgICAgR1BVIGZpbGwgKyBmbGlwCiAqICAgICBt
b2RlIDIgIHRoZSBzYW1lIGZpbGwgKyBnbEZpbmlzaCwgTk8gc3dhcCAgICAgICAgICAgICBHUFUg
ZmlsbCBhbG9uZQogKiAgICAgbW9kZSAzICBhcyBtb2RlIDAgYnV0IGludGVydmFsIDEgICAgICAg
ICAgICAgICAgICAgICAgd2hhdCB2c3luYyBsb29rcyBsaWtlCiAqCiAqIFRIRSBBTlNXRVIgVEhJ
UyBFWElTVFMgRk9SIGlzIHRoZSBmaXJzdCBsaW5lIGl0IHByaW50cy4gSWYgaXQgc2F5cwogKiAi
aW50ZXJ2YWwgcmVxPTAgZ290PTEiLCBTREwgY291bGQgbm90IHR1cm4gdnN5bmMgb2ZmIG9uIHRo
aXMgS01TRFJNLCBldmVyeQogKiBzd2FwIHdhaXRzIGZvciBhIHZibGFuaywgYW5kIGZyYW1lIHRp
bWVzIGFyZSBxdWFudGlzZWQgdG8gbXVsdGlwbGVzIG9mCiAqIDE2LjcgbXMuIFRoYXQgc2luZ2xl
IGxpbmUgZGVjaWRlcyB0aGUgd2hvbGUgQjIgbGluZSBvZiBpbnZlc3RpZ2F0aW9uLgogKgogKiBX
SFkgVjIgRE9FUyBOT1QgI2luY2x1ZGUgPFNETC5oPgogKiAtLS0tLS0tLS0tLS0tLS0tLS0tLS0t
LS0tLS0tLS0tLQogKiBWMSBuZWVkZWQgU0RMMiBoZWFkZXJzIGFuZCBsaWJTREwyIGF0IGxpbmsg
dGltZS4gT24gdGhlIHJlYWwgYnVpbGQgY29udGFpbmVyCiAqIHRoZXJlIGFyZSBubyBTREwyIGhl
YWRlcnMgYW55d2hlcmUgdGhlIHNlYXJjaCBsb29rZWQsIGFuZCBiZW5jaCBhYm9ydGVkCiAqIGJl
Zm9yZSBpdCBjb3VsZCBtZWFzdXJlIGFueXRoaW5nLiBIdW50aW5nIGZvciB0aGUgaGVhZGVycyB3
b3VsZCBoYXZlIGZpeGVkCiAqIHRoYXQgb25lIHJ1bjsgdGhpcyByZW1vdmVzIHRoZSBkZXBlbmRl
bmN5IGZvciBnb29kLgogKgogKiBJbnN0ZWFkIGl0IGRsb3BlbigpcyB0aGUgU0RMMiBhbmQgbGli
R0wgdGhlIEdBTUUgSVRTRUxGIGxvYWRzLCBhbmQgZGVjbGFyZXMKICogdGhlIGZvdXJ0ZWVuIFNE
TCBlbnRyeSBwb2ludHMgYW5kIHNldmVudGVlbiBHTCBlbnRyeSBwb2ludHMgaXQgdXNlcyB3aXRo
IGl0cwogKiBvd24gcHJvdG90eXBlcy4gTm90aGluZyBpcyBndWVzc2VkOiBldmVyeSBwcm90b3R5
cGUgYW5kIGV2ZXJ5IGNvbnN0YW50IGJlbG93CiAqIGlzIHBhcnQgb2YgdGhlIFNETDIgLyBPcGVu
R0wgQUJJLCB3aGljaCBpcyBmcm96ZW4gZm9yIHRoZSBsaWZlIG9mIFNETDIsIGFuZAogKiBlYWNo
IGNvbnN0YW50IGNhcnJpZXMgdGhlIGhlYWRlciBpdCBjb21lcyBmcm9tLgogKgogKiBUaGF0IG1h
a2VzIHRoaXMgc3RyaWN0bHkgQkVUVEVSIHRoYW4gVjEsIG5vdCBqdXN0IGVhc2llciB0byBidWls
ZDoKICogICAtIGl0IGNvbXBpbGVzIHdpdGggYGdjYyAtTzIgdHNwX3N3YXBiZW5jaC5jIC1sZGwg
LWxtYCBhbmQgbm90aGluZyBlbHNlLCBzbwogKiAgICAgbm8gaGVhZGVyIG9yIGxpYnJhcnkgc2Vh
cmNoIGNhbiBmYWlsOwogKiAgIC0gaXQgbWVhc3VyZXMgdGhlIGV4YWN0IGxpYlNETDIgdGhlIGdh
bWUgcnVucyBhZ2FpbnN0LCBub3Qgd2hhdGV2ZXIKICogICAgIHZlcnNpb24ncyBoZWFkZXJzIGhh
cHBlbmVkIHRvIGJlIGluIHRoZSBjb250YWluZXI7CiAqICAgLSBhIG1pc3Npbmcgb3IgdW5leHBl
Y3RlZCBzeW1ib2wgaXMgcmVwb3J0ZWQgYnkgbmFtZSBpbnN0ZWFkIG9mIGZhaWxpbmcgYXQKICog
ICAgIGxpbmsgdGltZSBpbiB0aGUgY29udGFpbmVyLCB3aGVyZSB0aGUgZXJyb3Igd291bGQgYmUg
bGVzcyBsZWdpYmxlLgogKgogKiBCdWlsZCAobm8gaW5jbHVkZSBwYXRoLCBubyAtbFNETDIsIG5v
IC1sR0wpOgogKiAgIGdjYy0xMyAtTzIgLVdhbGwgLVdleHRyYSAtbyB0c3Bfc3dhcGJlbmNoIHRz
cF9zd2FwYmVuY2guYyAtbGRsIC1sbQogKiBHYXRlOiB0aGUgYmluYXJ5IG11c3QgY29udGFpbiB0
aGUgc3RyaW5nIFRTUF9TV0FQQkVOQ0guCiAqLwoKI2RlZmluZSBfR05VX1NPVVJDRQojaW5jbHVk
ZSA8ZGxmY24uaD4KI2luY2x1ZGUgPHN0ZGlvLmg+CiNpbmNsdWRlIDxzdGRsaWIuaD4KI2luY2x1
ZGUgPHN0cmluZy5oPgojaW5jbHVkZSA8c3RkaW50Lmg+CiNpbmNsdWRlIDx0aW1lLmg+CgovKiAt
LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
LS0tLS0tLS0gQUJJIC0tLQogKiBTREwyLCBmcm9tIFNETC5oIC8gU0RMX3ZpZGVvLmguIFRoZXNl
IHZhbHVlcyBhcmUgQUJJIC0gU0RMMiBjYW5ub3QgY2hhbmdlCiAqIHRoZW0gd2l0aG91dCBicmVh
a2luZyBldmVyeSBjb21waWxlZCBiaW5hcnkgb24gZWFydGguCiAqLwojZGVmaW5lIFNETF9JTklU
X1ZJREVPICAgICAgICAgICAgMHgwMDAwMDAyMHUgIC8qIFNETC5oICovCiNkZWZpbmUgU0RMX1dJ
TkRPV19GVUxMU0NSRUVOICAgICAweDAwMDAwMDAxdSAgLyogU0RMX3ZpZGVvLmggU0RMX1dpbmRv
d0ZsYWdzICovCiNkZWZpbmUgU0RMX1dJTkRPV19PUEVOR0wgICAgICAgICAweDAwMDAwMDAydQoj
ZGVmaW5lIFNETF9XSU5ET1dfU0hPV04gICAgICAgICAgMHgwMDAwMDAwNHUKI2RlZmluZSBTRExf
R0xfRE9VQkxFQlVGRkVSICAgICAgIDUgICAgICAgICAgICAvKiBTRExfdmlkZW8uaCBTRExfR0xh
dHRyICovCiNkZWZpbmUgU0RMX0dMX0RFUFRIX1NJWkUgICAgICAgICA2CgovKiBPcGVuR0wgMS54
IC8gR0xFUyBlbnVtcywgZnJvbSBHTC9nbC5oLiBBbHNvIGZyb3plbiBBQkkuICovCiNkZWZpbmUg
R0xfREVQVEhfQlVGRkVSX0JJVCAgICAgICAweDAwMDAwMTAwdQojZGVmaW5lIEdMX0NPTE9SX0JV
RkZFUl9CSVQgICAgICAgMHgwMDAwNDAwMHUKI2RlZmluZSBHTF9RVUFEUyAgICAgICAgICAgICAg
ICAgIDB4MDAwNwojZGVmaW5lIEdMX1NSQ19BTFBIQSAgICAgICAgICAgICAgMHgwMzAyCiNkZWZp
bmUgR0xfT05FX01JTlVTX1NSQ19BTFBIQSAgICAweDAzMDMKI2RlZmluZSBHTF9CTEVORCAgICAg
ICAgICAgICAgICAgIDB4MEJFMgojZGVmaW5lIEdMX1RFWFRVUkVfMkQgICAgICAgICAgICAgMHgw
REUxCiNkZWZpbmUgR0xfVU5TSUdORURfQllURSAgICAgICAgICAweDE0MDEKI2RlZmluZSBHTF9N
T0RFTFZJRVcgICAgICAgICAgICAgIDB4MTcwMAojZGVmaW5lIEdMX1BST0pFQ1RJT04gICAgICAg
ICAgICAgMHgxNzAxCiNkZWZpbmUgR0xfVkVORE9SICAgICAgICAgICAgICAgICAweDFGMDAKI2Rl
ZmluZSBHTF9SRU5ERVJFUiAgICAgICAgICAgICAgIDB4MUYwMQojZGVmaW5lIEdMX1ZFUlNJT04g
ICAgICAgICAgICAgICAgMHgxRjAyCiNkZWZpbmUgR0xfTElORUFSICAgICAgICAgICAgICAgICAw
eDI2MDEKI2RlZmluZSBHTF9URVhUVVJFX01BR19GSUxURVIgICAgIDB4MjgwMAojZGVmaW5lIEdM
X1RFWFRVUkVfTUlOX0ZJTFRFUiAgICAgMHgyODAxCiNkZWZpbmUgR0xfUkdCQSAgICAgICAgICAg
ICAgICAgICAweDE5MDgKCnR5cGVkZWYgdm9pZCAgU0RMX1dpbmRvdzsKdHlwZWRlZiB2b2lkKiBT
RExfR0xDb250ZXh0OwoKLyogU0RMX0V2ZW50IGlzIGEgdW5pb24gd2hvc2Ugc2l6ZSBTREwyIHBp
bnMgYXQgNTYgYnl0ZXMgKFNETF9ldmVudHMuaCBlbmRzIGl0CiAqIHdpdGggYFVpbnQ4IHBhZGRp
bmdbNTZdYCkuIDI1NiBpcyB1c2VkIGhlcmUgc28gbm8gZnV0dXJlIG1lbWJlciBjYW4gb3ZlcmZs
b3cKICogdGhlIGJ1ZmZlciBTRExfUG9sbEV2ZW50IHdyaXRlcyBpbnRvIC0gdGhlIGNvbnRlbnRz
IGFyZSBuZXZlciByZWFkLiAqLwp0eXBlZGVmIHVuaW9uIHsgdW5zaWduZWQgY2hhciByYXdbMjU2
XTsgdWludDMyX3QgdHlwZTsgfSBUU1BfRXZlbnQ7CgovKiAtLS0tLS0tLS0tLS0tLS0tLS0tLS0t
LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tIHJlc29sdmVkIHN5bWJvbHMgLS0tKi8K
c3RhdGljIGludCAgICAgICAgICAoKnBfU0RMX0luaXQpKHVpbnQzMl90KTsKc3RhdGljIGNvbnN0
IGNoYXIqICAoKnBfU0RMX0dldEVycm9yKSh2b2lkKTsKc3RhdGljIGludCAgICAgICAgICAoKnBf
U0RMX0dMX1NldEF0dHJpYnV0ZSkoaW50LCBpbnQpOwpzdGF0aWMgU0RMX1dpbmRvdyogICgqcF9T
RExfQ3JlYXRlV2luZG93KShjb25zdCBjaGFyKiwgaW50LCBpbnQsIGludCwgaW50LCB1aW50MzJf
dCk7CnN0YXRpYyBTRExfR0xDb250ZXh0KCpwX1NETF9HTF9DcmVhdGVDb250ZXh0KShTRExfV2lu
ZG93Kik7CnN0YXRpYyBpbnQgICAgICAgICAgKCpwX1NETF9HTF9TZXRTd2FwSW50ZXJ2YWwpKGlu
dCk7CnN0YXRpYyBpbnQgICAgICAgICAgKCpwX1NETF9HTF9HZXRTd2FwSW50ZXJ2YWwpKHZvaWQp
OwpzdGF0aWMgdm9pZCAgICAgICAgICgqcF9TRExfR0xfU3dhcFdpbmRvdykoU0RMX1dpbmRvdyop
OwpzdGF0aWMgY29uc3QgY2hhciogICgqcF9TRExfR2V0Q3VycmVudFZpZGVvRHJpdmVyKSh2b2lk
KTsKc3RhdGljIGludCAgICAgICAgICAoKnBfU0RMX1BvbGxFdmVudCkoVFNQX0V2ZW50Kik7CnN0
YXRpYyB2b2lkICAgICAgICAgKCpwX1NETF9HTF9EZWxldGVDb250ZXh0KShTRExfR0xDb250ZXh0
KTsKc3RhdGljIHZvaWQgICAgICAgICAoKnBfU0RMX0Rlc3Ryb3lXaW5kb3cpKFNETF9XaW5kb3cq
KTsKc3RhdGljIHZvaWQgICAgICAgICAoKnBfU0RMX1F1aXQpKHZvaWQpOwpzdGF0aWMgdm9pZCog
ICAgICAgICgqcF9TRExfR0xfR2V0UHJvY0FkZHJlc3MpKGNvbnN0IGNoYXIqKTsKCnN0YXRpYyB2
b2lkICAoKnBfZ2xDbGVhcikodW5zaWduZWQgaW50KTsKc3RhdGljIHZvaWQgICgqcF9nbENsZWFy
Q29sb3IpKGZsb2F0LCBmbG9hdCwgZmxvYXQsIGZsb2F0KTsKc3RhdGljIGNvbnN0IHVuc2lnbmVk
IGNoYXIqICgqcF9nbEdldFN0cmluZykodW5zaWduZWQgaW50KTsKc3RhdGljIHZvaWQgICgqcF9n
bFZpZXdwb3J0KShpbnQsIGludCwgaW50LCBpbnQpOwpzdGF0aWMgdm9pZCAgKCpwX2dsRmluaXNo
KSh2b2lkKTsKc3RhdGljIHZvaWQgICgqcF9nbEVuYWJsZSkodW5zaWduZWQgaW50KTsKc3RhdGlj
IHZvaWQgICgqcF9nbEJsZW5kRnVuYykodW5zaWduZWQgaW50LCB1bnNpZ25lZCBpbnQpOwpzdGF0
aWMgdm9pZCAgKCpwX2dsR2VuVGV4dHVyZXMpKGludCwgdW5zaWduZWQgaW50Kik7CnN0YXRpYyB2
b2lkICAoKnBfZ2xCaW5kVGV4dHVyZSkodW5zaWduZWQgaW50LCB1bnNpZ25lZCBpbnQpOwpzdGF0
aWMgdm9pZCAgKCpwX2dsVGV4UGFyYW1ldGVyaSkodW5zaWduZWQgaW50LCB1bnNpZ25lZCBpbnQs
IGludCk7CnN0YXRpYyB2b2lkICAoKnBfZ2xUZXhJbWFnZTJEKSh1bnNpZ25lZCBpbnQsIGludCwg
aW50LCBpbnQsIGludCwgaW50LCB1bnNpZ25lZCBpbnQsIHVuc2lnbmVkIGludCwgY29uc3Qgdm9p
ZCopOwpzdGF0aWMgdm9pZCAgKCpwX2dsRGVsZXRlVGV4dHVyZXMpKGludCwgY29uc3QgdW5zaWdu
ZWQgaW50Kik7CnN0YXRpYyB2b2lkICAoKnBfZ2xNYXRyaXhNb2RlKSh1bnNpZ25lZCBpbnQpOwpz
dGF0aWMgdm9pZCAgKCpwX2dsTG9hZElkZW50aXR5KSh2b2lkKTsKc3RhdGljIHZvaWQgICgqcF9n
bE9ydGhvKShkb3VibGUsIGRvdWJsZSwgZG91YmxlLCBkb3VibGUsIGRvdWJsZSwgZG91YmxlKTsK
c3RhdGljIHZvaWQgICgqcF9nbEJlZ2luKSh1bnNpZ25lZCBpbnQpOwpzdGF0aWMgdm9pZCAgKCpw
X2dsRW5kKSh2b2lkKTsKc3RhdGljIHZvaWQgICgqcF9nbENvbG9yNGYpKGZsb2F0LCBmbG9hdCwg
ZmxvYXQsIGZsb2F0KTsKc3RhdGljIHZvaWQgICgqcF9nbFRleENvb3JkMmYpKGZsb2F0LCBmbG9h
dCk7CnN0YXRpYyB2b2lkICAoKnBfZ2xWZXJ0ZXgyZikoZmxvYXQsIGZsb2F0KTsKCnN0YXRpYyBp
bnQgbWlzc2luZyA9IDA7CgpzdGF0aWMgdm9pZCogcGljayh2b2lkKiBoLCBjb25zdCBjaGFyKiBu
YW1lLCBpbnQgcmVxdWlyZWQpCnsKICAgIHZvaWQqIHMgPSBkbHN5bShoLCBuYW1lKTsKICAgIGlm
IChzID09IE5VTEwgJiYgcmVxdWlyZWQpCiAgICB7CiAgICAgICAgcHJpbnRmKCJUU1BfU1dBUEJF
TkNIIEZBSUwgbWlzc2luZyBzeW1ib2wgJXNcbiIsIG5hbWUpOwogICAgICAgIG1pc3NpbmcrKzsK
ICAgIH0KICAgIHJldHVybiBzOwp9CgovKiBUaGUgZ2FtZSdzIG93biBTREwyIGFuZCBsaWJHTCwg
Ynkgc29uYW1lLCBmb3VuZCB0aHJvdWdoIExEX0xJQlJBUllfUEFUSCB3aGljaAogKiB0aGUgUG9y
dHMgZW50cnkgcG9pbnRzIGF0IHRoZSBnYW1lJ3MgbGliIGRpcmVjdG9yeS4gRWFjaCBjYW5kaWRh
dGUgaXMgdHJpZWQgaW4KICogdHVybiBhbmQgdGhlIG9uZSB0aGF0IGxvYWRzIGlzIHJlcG9ydGVk
LCBzbyB0aGUgbG9nIHNheXMgZXhhY3RseSB3aGljaAogKiBsaWJyYXJpZXMgd2VyZSBtZWFzdXJl
ZC4gKi8Kc3RhdGljIHZvaWQqIGxvYWRfYW55KGNvbnN0IGNoYXIqIGNvbnN0KiBuYW1lcywgY29u
c3QgY2hhciogd2hhdCkKewogICAgZm9yIChpbnQgaSA9IDA7IG5hbWVzW2ldICE9IE5VTEw7ICsr
aSkKICAgIHsKICAgICAgICB2b2lkKiBoID0gZGxvcGVuKG5hbWVzW2ldLCBSVExEX05PVyB8IFJU
TERfR0xPQkFMKTsKICAgICAgICBpZiAoaCAhPSBOVUxMKQogICAgICAgIHsKICAgICAgICAgICAg
cHJpbnRmKCJUU1BfU1dBUEJFTkNIIGxpYiAlcyA9ICVzXG4iLCB3aGF0LCBuYW1lc1tpXSk7CiAg
ICAgICAgICAgIHJldHVybiBoOwogICAgICAgIH0KICAgIH0KICAgIHByaW50ZigiVFNQX1NXQVBC
RU5DSCBGQUlMIGNvdWxkIG5vdCBkbG9wZW4gJXM6ICVzXG4iLCB3aGF0LCBkbGVycm9yKCkpOwog
ICAgcmV0dXJuIE5VTEw7Cn0KCnN0YXRpYyBkb3VibGUgbm93X21zKHZvaWQpCnsKICAgIHN0cnVj
dCB0aW1lc3BlYyB0OwogICAgY2xvY2tfZ2V0dGltZShDTE9DS19NT05PVE9OSUMsICZ0KTsKICAg
IHJldHVybiAoZG91YmxlKXQudHZfc2VjICogMWUzICsgKGRvdWJsZSl0LnR2X25zZWMgLyAxZTY7
Cn0KCnN0YXRpYyBpbnQgY21wZChjb25zdCB2b2lkKiBhLCBjb25zdCB2b2lkKiBiKQp7CiAgICBk
b3VibGUgeCA9ICooY29uc3QgZG91YmxlKilhLCB5ID0gKihjb25zdCBkb3VibGUqKWI7CiAgICBy
ZXR1cm4gKHggPiB5KSAtICh4IDwgeSk7Cn0KCnN0YXRpYyBjb25zdCBjaGFyKiBncyh1bnNpZ25l
ZCBpbnQgZSkKewogICAgaWYgKHBfZ2xHZXRTdHJpbmcgPT0gTlVMTCkgcmV0dXJuICI/IjsKICAg
IGNvbnN0IHVuc2lnbmVkIGNoYXIqIHYgPSBwX2dsR2V0U3RyaW5nKGUpOwogICAgcmV0dXJuICh2
ICE9IE5VTEwpID8gKGNvbnN0IGNoYXIqKXYgOiAiKG51bGwpIjsgICAvKiBuZXZlciBwcmludGYg
YSBOVUxMICovCn0KCmludCBtYWluKGludCBhcmdjLCBjaGFyKiogYXJndikKewogICAgaW50IG1v
ZGUgICA9IChhcmdjID4gMSkgPyBhdG9pKGFyZ3ZbMV0pIDogMDsKICAgIGludCBmcmFtZXMgPSAo
YXJnYyA+IDIpID8gYXRvaShhcmd2WzJdKSA6IDMwMDsKICAgIGludCBxdWFkcyAgPSAoYXJnYyA+
IDMpID8gYXRvaShhcmd2WzNdKSA6IDQ7CiAgICBpZiAobW9kZSA8IDAgfHwgbW9kZSA+IDMpIHsg
cHJpbnRmKCJUU1BfU1dBUEJFTkNIIEZBSUwgbW9kZSAlZCBvdXQgb2YgcmFuZ2UgMC0zXG4iLCBt
b2RlKTsgcmV0dXJuIDI7IH0KICAgIGlmIChmcmFtZXMgPCAxMCkgZnJhbWVzID0gMTA7CiAgICBp
ZiAoZnJhbWVzID4gNTAwMCkgZnJhbWVzID0gNTAwMDsKICAgIGlmIChxdWFkcyA8IDApIHF1YWRz
ID0gMDsKCiAgICBzdGF0aWMgY29uc3QgY2hhciogY29uc3Qgc2RsX25hbWVzW10gPSB7CiAgICAg
ICAgImxpYlNETDItMi4wLnNvLjAiLCAibGliU0RMMi0yLjAuc28iLCAibGliU0RMMi5zby4wIiwg
ImxpYlNETDIuc28iLCBOVUxMIH07CiAgICBzdGF0aWMgY29uc3QgY2hhciogY29uc3QgZ2xfbmFt
ZXNbXSA9IHsKICAgICAgICAibGliR0wuc28uMSIsICJsaWJHTC5zbyIsICJsaWJHTEVTdjIuc28u
MiIsICJsaWJHTEVTdjIuc28iLCBOVUxMIH07CgogICAgdm9pZCogaHMgPSBsb2FkX2FueShzZGxf
bmFtZXMsICJTREwyIik7CiAgICBpZiAoaHMgPT0gTlVMTCkgcmV0dXJuIDE7CgogICAgcF9TRExf
SW5pdCAgICAgICAgICAgICAgICA9IChpbnQgKCopKHVpbnQzMl90KSkgICAgICAgICAgICAgICBw
aWNrKGhzLCAiU0RMX0luaXQiLCAxKTsKICAgIHBfU0RMX0dldEVycm9yICAgICAgICAgICAgPSAo
Y29uc3QgY2hhciogKCopKHZvaWQpKSAgICAgICAgICAgcGljayhocywgIlNETF9HZXRFcnJvciIs
IDEpOwogICAgcF9TRExfR0xfU2V0QXR0cmlidXRlICAgICA9IChpbnQgKCopKGludCwgaW50KSkg
ICAgICAgICAgICAgICBwaWNrKGhzLCAiU0RMX0dMX1NldEF0dHJpYnV0ZSIsIDEpOwogICAgcF9T
RExfQ3JlYXRlV2luZG93ICAgICAgICA9IChTRExfV2luZG93KiAoKikoY29uc3QgY2hhciosIGlu
dCwgaW50LCBpbnQsIGludCwgdWludDMyX3QpKQogICAgICAgICAgICAgICAgICAgICAgICAgICAg
ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBwaWNrKGhzLCAiU0RMX0NyZWF0
ZVdpbmRvdyIsIDEpOwogICAgcF9TRExfR0xfQ3JlYXRlQ29udGV4dCAgICA9IChTRExfR0xDb250
ZXh0ICgqKShTRExfV2luZG93KikpICBwaWNrKGhzLCAiU0RMX0dMX0NyZWF0ZUNvbnRleHQiLCAx
KTsKICAgIHBfU0RMX0dMX1NldFN3YXBJbnRlcnZhbCAgPSAoaW50ICgqKShpbnQpKSAgICAgICAg
ICAgICAgICAgICAgcGljayhocywgIlNETF9HTF9TZXRTd2FwSW50ZXJ2YWwiLCAxKTsKICAgIHBf
U0RMX0dMX0dldFN3YXBJbnRlcnZhbCAgPSAoaW50ICgqKSh2b2lkKSkgICAgICAgICAgICAgICAg
ICAgcGljayhocywgIlNETF9HTF9HZXRTd2FwSW50ZXJ2YWwiLCAxKTsKICAgIHBfU0RMX0dMX1N3
YXBXaW5kb3cgICAgICAgPSAodm9pZCAoKikoU0RMX1dpbmRvdyopKSAgICAgICAgICAgcGljayho
cywgIlNETF9HTF9Td2FwV2luZG93IiwgMSk7CiAgICBwX1NETF9HZXRDdXJyZW50VmlkZW9Ecml2
ZXIgPSAoY29uc3QgY2hhciogKCopKHZvaWQpKSAgICAgICAgIHBpY2soaHMsICJTRExfR2V0Q3Vy
cmVudFZpZGVvRHJpdmVyIiwgMSk7CiAgICBwX1NETF9Qb2xsRXZlbnQgICAgICAgICAgID0gKGlu
dCAoKikoVFNQX0V2ZW50KikpICAgICAgICAgICAgIHBpY2soaHMsICJTRExfUG9sbEV2ZW50Iiwg
MSk7CiAgICBwX1NETF9HTF9EZWxldGVDb250ZXh0ICAgID0gKHZvaWQgKCopKFNETF9HTENvbnRl
eHQpKSAgICAgICAgIHBpY2soaHMsICJTRExfR0xfRGVsZXRlQ29udGV4dCIsIDEpOwogICAgcF9T
RExfRGVzdHJveVdpbmRvdyAgICAgICA9ICh2b2lkICgqKShTRExfV2luZG93KikpICAgICAgICAg
ICBwaWNrKGhzLCAiU0RMX0Rlc3Ryb3lXaW5kb3ciLCAxKTsKICAgIHBfU0RMX1F1aXQgICAgICAg
ICAgICAgICAgPSAodm9pZCAoKikodm9pZCkpICAgICAgICAgICAgICAgICAgcGljayhocywgIlNE
TF9RdWl0IiwgMSk7CiAgICBwX1NETF9HTF9HZXRQcm9jQWRkcmVzcyAgID0gKHZvaWQqICgqKShj
b25zdCBjaGFyKikpICAgICAgICAgIHBpY2soaHMsICJTRExfR0xfR2V0UHJvY0FkZHJlc3MiLCAx
KTsKICAgIGlmIChtaXNzaW5nKSB7IHByaW50ZigiVFNQX1NXQVBCRU5DSCBGQUlMICVkIFNETCBz
eW1ib2wocykgbWlzc2luZ1xuIiwgbWlzc2luZyk7IHJldHVybiAxOyB9CgogICAgaWYgKHBfU0RM
X0luaXQoU0RMX0lOSVRfVklERU8pICE9IDApCiAgICB7CiAgICAgICAgcHJpbnRmKCJUU1BfU1dB
UEJFTkNIIEZBSUwgU0RMX0luaXQ6ICVzXG4iLCBwX1NETF9HZXRFcnJvcigpKTsKICAgICAgICBy
ZXR1cm4gMTsKICAgIH0KCiAgICBwX1NETF9HTF9TZXRBdHRyaWJ1dGUoU0RMX0dMX0RPVUJMRUJV
RkZFUiwgMSk7CiAgICBwX1NETF9HTF9TZXRBdHRyaWJ1dGUoU0RMX0dMX0RFUFRIX1NJWkUsIDI0
KTsKCiAgICBTRExfV2luZG93KiB3ID0gcF9TRExfQ3JlYXRlV2luZG93KCJ0c3Bfc3dhcGJlbmNo
IiwgMCwgMCwgMTI4MCwgNzIwLAogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg
ICBTRExfV0lORE9XX09QRU5HTCB8IFNETF9XSU5ET1dfRlVMTFNDUkVFTiB8IFNETF9XSU5ET1df
U0hPV04pOwogICAgaWYgKHcgPT0gTlVMTCkgeyBwcmludGYoIlRTUF9TV0FQQkVOQ0ggRkFJTCBT
RExfQ3JlYXRlV2luZG93OiAlc1xuIiwgcF9TRExfR2V0RXJyb3IoKSk7IHJldHVybiAxOyB9Cgog
ICAgU0RMX0dMQ29udGV4dCBjdHggPSBwX1NETF9HTF9DcmVhdGVDb250ZXh0KHcpOwogICAgaWYg
KGN0eCA9PSBOVUxMKSB7IHByaW50ZigiVFNQX1NXQVBCRU5DSCBGQUlMIFNETF9HTF9DcmVhdGVD
b250ZXh0OiAlc1xuIiwgcF9TRExfR2V0RXJyb3IoKSk7IHJldHVybiAxOyB9CgogICAgLyogR0wg
ZW50cnkgcG9pbnRzIGNvbWUgZnJvbSBTRExfR0xfR2V0UHJvY0FkZHJlc3MgZmlyc3QgLSB0aGF0
IGlzIHRoZQogICAgICogY29udGV4dCdzIG93biBsb2FkZXIgYW5kIGlzIHdoYXQgdGhlIGdhbWUg
aXRzZWxmIHJlc29sdmVzIHRocm91Z2ggLSBhbmQKICAgICAqIGZyb20gYSBkbG9wZW4nZCBsaWJH
TCBvbmx5IGFzIGEgZmFsbGJhY2suIE9uIGdsNGVzIGJvdGggbGFuZCBvbiB0aGUgc2FtZQogICAg
ICogbGlicmFyeTsgYXNraW5nIHRoZSBjb250ZXh0IGZpcnN0IGlzIHdoYXQgbWFrZXMgdGhpcyBj
b3JyZWN0IGlmIHRoZSBnYW1lCiAgICAgKiBpcyBldmVyIHJ1biBvbiBhIGRpZmZlcmVudCBHTC4g
Ki8KICAgIHZvaWQqIGhnID0gTlVMTDsKICAgICNkZWZpbmUgR0xTWU0odiwgbiwgdCkgZG8geyBc
CiAgICAgICAgdm9pZCogcyA9IHBfU0RMX0dMX0dldFByb2NBZGRyZXNzID8gcF9TRExfR0xfR2V0
UHJvY0FkZHJlc3MobikgOiBOVUxMOyBcCiAgICAgICAgaWYgKHMgPT0gTlVMTCkgeyBpZiAoaGcg
PT0gTlVMTCkgaGcgPSBsb2FkX2FueShnbF9uYW1lcywgIkdMIik7IHMgPSBoZyA/IGRsc3ltKGhn
LCBuKSA6IE5VTEw7IH0gXAogICAgICAgIGlmIChzID09IE5VTEwpIHsgcHJpbnRmKCJUU1BfU1dB
UEJFTkNIIEZBSUwgbWlzc2luZyBHTCBzeW1ib2wgJXNcbiIsIG4pOyBtaXNzaW5nKys7IH0gXAog
ICAgICAgIHYgPSAodClzOyB9IHdoaWxlICgwKQoKICAgIEdMU1lNKHBfZ2xDbGVhciwgICAgICAg
ICJnbENsZWFyIiwgICAgICAgIHZvaWQgKCopKHVuc2lnbmVkIGludCkpOwogICAgR0xTWU0ocF9n
bENsZWFyQ29sb3IsICAgImdsQ2xlYXJDb2xvciIsICAgdm9pZCAoKikoZmxvYXQsIGZsb2F0LCBm
bG9hdCwgZmxvYXQpKTsKICAgIEdMU1lNKHBfZ2xHZXRTdHJpbmcsICAgICJnbEdldFN0cmluZyIs
ICAgIGNvbnN0IHVuc2lnbmVkIGNoYXIqICgqKSh1bnNpZ25lZCBpbnQpKTsKICAgIEdMU1lNKHBf
Z2xWaWV3cG9ydCwgICAgICJnbFZpZXdwb3J0IiwgICAgIHZvaWQgKCopKGludCwgaW50LCBpbnQs
IGludCkpOwogICAgR0xTWU0ocF9nbEZpbmlzaCwgICAgICAgImdsRmluaXNoIiwgICAgICAgdm9p
ZCAoKikodm9pZCkpOwogICAgaWYgKG1pc3NpbmcpIHsgcHJpbnRmKCJUU1BfU1dBUEJFTkNIIEZB
SUwgJWQgR0wgc3ltYm9sKHMpIG1pc3NpbmdcbiIsIG1pc3NpbmcpOyByZXR1cm4gMTsgfQoKICAg
IGludCB3YW50ID0gKG1vZGUgPT0gMykgPyAxIDogMDsKICAgIGludCBzZXRyYyA9IHBfU0RMX0dM
X1NldFN3YXBJbnRlcnZhbCh3YW50KTsKICAgIGludCBnb3QgICA9IHBfU0RMX0dMX0dldFN3YXBJ
bnRlcnZhbCgpOwoKICAgIHByaW50ZigiVFNQX1NXQVBCRU5DSCBlbnYgZHJpdmVyPSVzIHJlbmRl
cmVyPSVzIHZlbmRvcj0lcyB2ZXJzaW9uPSVzXG4iLAogICAgICAgICAgIHBfU0RMX0dldEN1cnJl
bnRWaWRlb0RyaXZlcigpID8gcF9TRExfR2V0Q3VycmVudFZpZGVvRHJpdmVyKCkgOiAiKG51bGwp
IiwKICAgICAgICAgICBncyhHTF9SRU5ERVJFUiksIGdzKEdMX1ZFTkRPUiksIGdzKEdMX1ZFUlNJ
T04pKTsKICAgIHByaW50ZigiVFNQX1NXQVBCRU5DSCBpbnRlcnZhbCByZXE9JWQgZ290PSVkIHNl
dHJjPSVkJXNcbiIsIHdhbnQsIGdvdCwgc2V0cmMsCiAgICAgICAgICAgKHdhbnQgPT0gMCAmJiBn
b3QgIT0gMCkKICAgICAgICAgICAgID8gIiAgIDwtLSBpbnRlcnZhbCAwIFJFRlVTRUQ6IGV2ZXJ5
IHN3YXAgd2FpdHMgZm9yIGEgdmJsYW5rIgogICAgICAgICAgICAgOiAiIik7CiAgICBmZmx1c2go
c3Rkb3V0KTsKCiAgICB1bnNpZ25lZCBpbnQgdGV4ID0gMDsKICAgIGlmIChtb2RlID09IDEgfHwg
bW9kZSA9PSAyKQogICAgewogICAgICAgIEdMU1lNKHBfZ2xFbmFibGUsICAgICAgICAiZ2xFbmFi
bGUiLCAgICAgICAgdm9pZCAoKikodW5zaWduZWQgaW50KSk7CiAgICAgICAgR0xTWU0ocF9nbEJs
ZW5kRnVuYywgICAgICJnbEJsZW5kRnVuYyIsICAgICB2b2lkICgqKSh1bnNpZ25lZCBpbnQsIHVu
c2lnbmVkIGludCkpOwogICAgICAgIEdMU1lNKHBfZ2xHZW5UZXh0dXJlcywgICAiZ2xHZW5UZXh0
dXJlcyIsICAgdm9pZCAoKikoaW50LCB1bnNpZ25lZCBpbnQqKSk7CiAgICAgICAgR0xTWU0ocF9n
bEJpbmRUZXh0dXJlLCAgICJnbEJpbmRUZXh0dXJlIiwgICB2b2lkICgqKSh1bnNpZ25lZCBpbnQs
IHVuc2lnbmVkIGludCkpOwogICAgICAgIEdMU1lNKHBfZ2xUZXhQYXJhbWV0ZXJpLCAiZ2xUZXhQ
YXJhbWV0ZXJpIiwgdm9pZCAoKikodW5zaWduZWQgaW50LCB1bnNpZ25lZCBpbnQsIGludCkpOwog
ICAgICAgIEdMU1lNKHBfZ2xUZXhJbWFnZTJELCAgICAiZ2xUZXhJbWFnZTJEIiwgICAgdm9pZCAo
KikodW5zaWduZWQgaW50LCBpbnQsIGludCwgaW50LCBpbnQsIGludCwgdW5zaWduZWQgaW50LCB1
bnNpZ25lZCBpbnQsIGNvbnN0IHZvaWQqKSk7CiAgICAgICAgR0xTWU0ocF9nbERlbGV0ZVRleHR1
cmVzLCJnbERlbGV0ZVRleHR1cmVzIix2b2lkICgqKShpbnQsIGNvbnN0IHVuc2lnbmVkIGludCop
KTsKICAgICAgICBHTFNZTShwX2dsTWF0cml4TW9kZSwgICAgImdsTWF0cml4TW9kZSIsICAgIHZv
aWQgKCopKHVuc2lnbmVkIGludCkpOwogICAgICAgIEdMU1lNKHBfZ2xMb2FkSWRlbnRpdHksICAi
Z2xMb2FkSWRlbnRpdHkiLCAgdm9pZCAoKikodm9pZCkpOwogICAgICAgIEdMU1lNKHBfZ2xPcnRo
bywgICAgICAgICAiZ2xPcnRobyIsICAgICAgICAgdm9pZCAoKikoZG91YmxlLCBkb3VibGUsIGRv
dWJsZSwgZG91YmxlLCBkb3VibGUsIGRvdWJsZSkpOwogICAgICAgIEdMU1lNKHBfZ2xCZWdpbiwg
ICAgICAgICAiZ2xCZWdpbiIsICAgICAgICAgdm9pZCAoKikodW5zaWduZWQgaW50KSk7CiAgICAg
ICAgR0xTWU0ocF9nbEVuZCwgICAgICAgICAgICJnbEVuZCIsICAgICAgICAgICB2b2lkICgqKSh2
b2lkKSk7CiAgICAgICAgR0xTWU0ocF9nbENvbG9yNGYsICAgICAgICJnbENvbG9yNGYiLCAgICAg
ICB2b2lkICgqKShmbG9hdCwgZmxvYXQsIGZsb2F0LCBmbG9hdCkpOwogICAgICAgIEdMU1lNKHBf
Z2xUZXhDb29yZDJmLCAgICAiZ2xUZXhDb29yZDJmIiwgICAgdm9pZCAoKikoZmxvYXQsIGZsb2F0
KSk7CiAgICAgICAgR0xTWU0ocF9nbFZlcnRleDJmLCAgICAgICJnbFZlcnRleDJmIiwgICAgICB2
b2lkICgqKShmbG9hdCwgZmxvYXQpKTsKICAgICAgICBpZiAobWlzc2luZykgeyBwcmludGYoIlRT
UF9TV0FQQkVOQ0ggRkFJTCAlZCBHTCBzeW1ib2wocykgbWlzc2luZyBmb3IgbW9kZSAlZFxuIiwg
bWlzc2luZywgbW9kZSk7IHJldHVybiAxOyB9CgogICAgICAgIGNvbnN0IGludCBOID0gMTAyNDsK
ICAgICAgICB1bnNpZ25lZCBjaGFyKiBweCA9ICh1bnNpZ25lZCBjaGFyKiltYWxsb2MoKHNpemVf
dClOICogTiAqIDQpOwogICAgICAgIGlmIChweCA9PSBOVUxMKSB7IHByaW50ZigiVFNQX1NXQVBC
RU5DSCBGQUlMIG91dCBvZiBtZW1vcnkgZm9yIHRoZSB0ZXN0IHRleHR1cmVcbiIpOyByZXR1cm4g
MTsgfQogICAgICAgIGZvciAoc2l6ZV90IGkgPSAwOyBpIDwgKHNpemVfdClOICogTiAqIDQ7ICsr
aSkKICAgICAgICAgICAgcHhbaV0gPSAodW5zaWduZWQgY2hhcikoKGkgKiAyNjU0NDM1NzYxdSkg
Pj4gMTMpOwogICAgICAgIHBfZ2xHZW5UZXh0dXJlcygxLCAmdGV4KTsKICAgICAgICBwX2dsQmlu
ZFRleHR1cmUoR0xfVEVYVFVSRV8yRCwgdGV4KTsKICAgICAgICBwX2dsVGV4UGFyYW1ldGVyaShH
TF9URVhUVVJFXzJELCBHTF9URVhUVVJFX01JTl9GSUxURVIsIEdMX0xJTkVBUik7CiAgICAgICAg
cF9nbFRleFBhcmFtZXRlcmkoR0xfVEVYVFVSRV8yRCwgR0xfVEVYVFVSRV9NQUdfRklMVEVSLCBH
TF9MSU5FQVIpOwogICAgICAgIHBfZ2xUZXhJbWFnZTJEKEdMX1RFWFRVUkVfMkQsIDAsIEdMX1JH
QkEsIE4sIE4sIDAsIEdMX1JHQkEsIEdMX1VOU0lHTkVEX0JZVEUsIHB4KTsKICAgICAgICBmcmVl
KHB4KTsKICAgICAgICBwX2dsRW5hYmxlKEdMX1RFWFRVUkVfMkQpOwogICAgICAgIHBfZ2xFbmFi
bGUoR0xfQkxFTkQpOwogICAgICAgIHBfZ2xCbGVuZEZ1bmMoR0xfU1JDX0FMUEhBLCBHTF9PTkVf
TUlOVVNfU1JDX0FMUEhBKTsgIC8qIGJsZW5kZWQsIGxpa2UgdGhlIFVJICovCiAgICAgICAgcF9n
bE1hdHJpeE1vZGUoR0xfUFJPSkVDVElPTik7IHBfZ2xMb2FkSWRlbnRpdHkoKTsKICAgICAgICBw
X2dsT3J0aG8oMCwgMSwgMCwgMSwgLTEsIDEpOwogICAgICAgIHBfZ2xNYXRyaXhNb2RlKEdMX01P
REVMVklFVyk7ICBwX2dsTG9hZElkZW50aXR5KCk7CiAgICB9CiAgICBwX2dsVmlld3BvcnQoMCwg
MCwgMTI4MCwgNzIwKTsKCiAgICBkb3VibGUqIHQgPSAoZG91YmxlKiljYWxsb2MoKHNpemVfdClm
cmFtZXMsIHNpemVvZihkb3VibGUpKTsKICAgIGlmICh0ID09IE5VTEwpIHsgcHJpbnRmKCJUU1Bf
U1dBUEJFTkNIIEZBSUwgb3V0IG9mIG1lbW9yeSBmb3IgJWQgdGltaW5nc1xuIiwgZnJhbWVzKTsg
cmV0dXJuIDE7IH0KCiAgICBmb3IgKGludCBmID0gMDsgZiA8IGZyYW1lczsgKytmKQogICAgewog
ICAgICAgIGRvdWJsZSB0MCA9IG5vd19tcygpOwogICAgICAgIHBfZ2xDbGVhckNvbG9yKDAuMWYs
IDAuMmYsIDAuM2YsIDEuMGYpOwogICAgICAgIHBfZ2xDbGVhcihHTF9DT0xPUl9CVUZGRVJfQklU
IHwgR0xfREVQVEhfQlVGRkVSX0JJVCk7CiAgICAgICAgaWYgKG1vZGUgPT0gMSB8fCBtb2RlID09
IDIpCiAgICAgICAgewogICAgICAgICAgICBmb3IgKGludCBxID0gMDsgcSA8IHF1YWRzOyArK3Ep
CiAgICAgICAgICAgIHsKICAgICAgICAgICAgICAgIGZsb2F0IG8gPSAwLjAwMmYgKiAoZmxvYXQp
cTsgIC8qIG9mZnNldCBzbyB0aGUgZHJpdmVyIGNhbm5vdCBtZXJnZSB0aGVtICovCiAgICAgICAg
ICAgICAgICBwX2dsQ29sb3I0ZigxLjBmLCAxLjBmLCAxLjBmLCAwLjlmKTsKICAgICAgICAgICAg
ICAgIHBfZ2xCZWdpbihHTF9RVUFEUyk7CiAgICAgICAgICAgICAgICBwX2dsVGV4Q29vcmQyZigw
LCAwKTsgcF9nbFZlcnRleDJmKDAgKyBvLCAwKTsKICAgICAgICAgICAgICAgIHBfZ2xUZXhDb29y
ZDJmKDEsIDApOyBwX2dsVmVydGV4MmYoMSwgMCArIG8pOwogICAgICAgICAgICAgICAgcF9nbFRl
eENvb3JkMmYoMSwgMSk7IHBfZ2xWZXJ0ZXgyZigxIC0gbywgMSk7CiAgICAgICAgICAgICAgICBw
X2dsVGV4Q29vcmQyZigwLCAxKTsgcF9nbFZlcnRleDJmKDAsIDEgLSBvKTsKICAgICAgICAgICAg
ICAgIHBfZ2xFbmQoKTsKICAgICAgICAgICAgfQogICAgICAgIH0KICAgICAgICBpZiAobW9kZSA9
PSAyKSBwX2dsRmluaXNoKCk7IGVsc2UgcF9TRExfR0xfU3dhcFdpbmRvdyh3KTsKICAgICAgICB0
W2ZdID0gbm93X21zKCkgLSB0MDsKICAgICAgICBUU1BfRXZlbnQgZTsKICAgICAgICB3aGlsZSAo
cF9TRExfUG9sbEV2ZW50KCZlKSkgeyB9CiAgICB9CgogICAgLyogRHJvcCB0aGUgZmlyc3QgMzAg
ZnJhbWVzOiBzaGFkZXIvcGlwZWxpbmUgd2FybS11cCBhbmQgdGhlIGZpcnN0IGZsaXAgYXJlCiAg
ICAgKiBub3QgdGhlIHN0ZWFkeSBzdGF0ZSBiZWluZyBtZWFzdXJlZC4gKi8KICAgIGludCBza2lw
ID0gKGZyYW1lcyA+IDYwKSA/IDMwIDogMDsKICAgIGludCBuID0gZnJhbWVzIC0gc2tpcDsKICAg
IGRvdWJsZSBzdW0gPSAwLjA7CiAgICBmb3IgKGludCBpID0gc2tpcDsgaSA8IGZyYW1lczsgKytp
KSBzdW0gKz0gdFtpXTsKICAgIHFzb3J0KHQgKyBza2lwLCAoc2l6ZV90KW4sIHNpemVvZihkb3Vi
bGUpLCBjbXBkKTsKICAgIHByaW50ZigiVFNQX1NXQVBCRU5DSCBtb2RlPSVkIGZyYW1lcz0lZCBx
dWFkcz0lZCBtaW49JS4yZiBwNTA9JS4yZiBwOTA9JS4yZiBtYXg9JS4yZiBtZWFuPSUuMmYgbXNc
biIsCiAgICAgICAgICAgbW9kZSwgbiwgcXVhZHMsIHRbc2tpcF0sIHRbc2tpcCArIG4gLyAyXSwg
dFtza2lwICsgKG4gKiA5KSAvIDEwXSwKICAgICAgICAgICB0W2ZyYW1lcyAtIDFdLCBzdW0gLyAo
ZG91YmxlKW4pOwogICAgZmZsdXNoKHN0ZG91dCk7CgogICAgZnJlZSh0KTsKICAgIGlmICh0ZXgg
IT0gMCAmJiBwX2dsRGVsZXRlVGV4dHVyZXMgIT0gTlVMTCkgcF9nbERlbGV0ZVRleHR1cmVzKDEs
ICZ0ZXgpOwogICAgcF9TRExfR0xfRGVsZXRlQ29udGV4dChjdHgpOwogICAgcF9TRExfRGVzdHJv
eVdpbmRvdyh3KTsKICAgIHBfU0RMX1F1aXQoKTsKICAgIHJldHVybiAwOwp9Cg==
B64EOF
    GOT="$(docker exec "$CONT" md5sum /root/tsp_swapbench.c | cut -d' ' -f1)"
    echo "  expected md5: $CSRC_MD5"
    echo "  in container: $GOT"
    [ "$GOT" = "$CSRC_MD5" ] || die "source md5 mismatch - the payload was mangled in transit"
    echo "  VERIFIED: source arrived intact"

    head2 "2. BUILD (full output, not truncated)"
    echo "  TSP_SWAPBENCH_V2 needs no SDL2 headers and no -lSDL2/-lGL. It dlopen()s"
    echo "  the SDL2 and libGL the GAME loads and declares the ABI itself, so this"
    echo "  compiles with -ldl -lm and nothing else. V1 aborted here because the"
    echo "  container has no SDL.h anywhere the search looked; that dependency is"
    echo "  gone rather than worked around, and the bench now measures the exact"
    echo "  libSDL2 the game runs against instead of whatever headers were present."
    echo
    docker exec "$CONT" sh -c "cd /root && gcc-13 -O2 -Wall -Wextra -o tsp_swapbench tsp_swapbench.c -ldl -lm 2>&1"
    BS=$?
    if [ "$BS" -ne 0 ]; then
        echo
        echo "  gcc-13 failed with $BS. Trying plain gcc in case gcc-13 is not present."
        docker exec "$CONT" sh -c "cd /root && gcc -O2 -Wall -Wextra -o tsp_swapbench tsp_swapbench.c -ldl -lm 2>&1" \
            || die "build failed. Nothing was deployed. The compiler output above is the whole story - send it to me."
    fi
    docker exec "$CONT" test -f /root/tsp_swapbench || die "no binary produced"
    docker exec "$CONT" sh -c "grep -a -q TSP_SWAPBENCH /root/tsp_swapbench" \
        || die "binary gate: TSP_SWAPBENCH string is not in the built binary"
    echo "  VERIFIED: TSP_SWAPBENCH present in the built binary"
    echo "  It should link against libc only:"
    docker exec "$CONT" sh -c "ldd /root/tsp_swapbench 2>&1 | sed 's/^/    /'" || true

    head2 "3. DEPLOY THE BINARY"
    rm -f /tmp/tsp_swapbench
    docker cp "$CONT:/root/tsp_swapbench" /tmp/tsp_swapbench || die "docker cp failed"
    rin "cat > $BENCH" < /tmp/tsp_swapbench || die "upload failed"
    r "chmod +x $BENCH" || die "chmod failed"
    r "if grep -a -q TSP_SWAPBENCH $BENCH; then echo '  DEVICE VERIFIED: TSP_SWAPBENCH'; else echo '  DEVICE FAIL'; exit 1; fi" \
        || die "the uploaded binary does not contain the marker"

    head2 "4. HOW THE LAUNCHER TAKES THE DISPLAY"
    echo "  NOTHING is copied out of Morrowind.sh any more. The previous version"
    echo "  grepped its single-line 'export LIBGL_*/SDL_*' statements and spliced"
    echo "  them verbatim into the generated entry. On the real launcher that:"
    echo "    - copied a COMMAND SUBSTITUTION, export SDL_GAMECONTROLLERCONFIG="
    echo "      \"\$(cat \"\$CONTROLLER_DB_FILE\")\", which then ran cat \"\" here;"
    echo "    - copied \$TEXCACHE_DIR and \$GAMEDIR, undefined in this context;"
    echo "    - copied two contradictory LIBGL_SHRINK lines from two different"
    echo "      conditional branches, last one winning;"
    echo "    - and still never set SDL_VIDEODRIVER, because the launcher does not"
    echo "      set it as a plain export - which is why the bench got"
    echo "      'EGL not initialized' six times."
    echo
    echo "  None of the LIBGL_* tuning affects whether a flip waits for a vblank."
    echo "  Mode 0 is glClear plus swap: no textures, no shaders. So the entry now"
    echo "  sets only LD_LIBRARY_PATH and sweeps SDL_VIDEODRIVER until one gets a"
    echo "  window. What IS needed is whatever the launcher does to take the"
    echo "  display from MainUI, and that is what this section is for."
    echo
    r "test -f '$LAUNCHER'" || die "launcher not found at $LAUNCHER"
    echo "  -- lines that mention the display, DRM, the framebuffer or the UI --"
    r "grep -n -i -e 'mainui' -e 'kill' -e 'drm' -e 'fb0' -e 'framebuffer' \
            -e 'vsync' -e 'VIDEODRIVER' -e 'SDL_VIDEO' -e 'trimui_' \
            '$LAUNCHER' | head -40" | sed 's/^/    /'
    echo
    echo "  -- the exec line and the 40 lines before it --"
    r "awk '/^[[:space:]]*exec[[:space:]]/ { hit = NR } END { print hit }' '$LAUNCHER'" > /tmp/tsp_b2_exec.txt 2>/dev/null
    EL="$(cat /tmp/tsp_b2_exec.txt 2>/dev/null)"
    case "$EL" in ''|*[!0-9]*) EL=0 ;; esac
    if [ "$EL" -gt 0 ]; then
        FROM=$((EL - 40)); [ "$FROM" -lt 1 ] && FROM=1
        r "awk 'NR >= $FROM && NR <= $((EL + 4)) { printf \"%5d  %s\\n\", NR, \$0 }' '$LAUNCHER'" | sed 's/^/    /'
    else
        echo "    could not find an 'exec' line - sending the last 40 lines instead"
        r "awk 'END { n = NR } { l[NR] = \$0 } END { for (i = n - 39; i <= n; i++) if (i > 0) printf \"%5d  %s\\n\", i, l[i] }' '$LAUNCHER'" | sed 's/^/    /'
    fi

    head2 "5. INSTALL THE PORTS ENTRY"
    rin "cat > '$BENCH_ENTRY'" <<ENTEOF
#!/bin/sh
# TSP_SWAPBENCH_V2 runner. Generated by tsp_b2.sh on $STAMP.
# Nothing is copied out of Morrowind.sh - see section 4 of the bench transcript
# for why. Only LD_LIBRARY_PATH is set, plus an SDL_VIDEODRIVER sweep, because
# no LIBGL_* tuning can change whether a page flip waits for a vblank.
PROG="$PROG"
GAME="$GAME"
BENCH="$BENCH"
echo "===== TSP_SWAPBENCH run $STAMP =====" >> "\$PROG"
export LD_LIBRARY_PATH="\$GAME/lib:\$LD_LIBRARY_PATH"
echo "TSP_SWAPBENCH envdump LD_LIBRARY_PATH=\$LD_LIBRARY_PATH" >> "\$PROG"

# Who owns the display. "EGL not initialized" is what SDL says when it cannot
# get a KMS/EGL display at all, and the commonest reason on this OS is that
# MainUI still holds DRM master on card0. If that is it, no video driver in the
# sweep below can succeed and this pair of lines is the answer.
DRMPIDS="\$(fuser /dev/dri/card0 2>/dev/null | tr -d ':')"
echo "TSP_SWAPBENCH drmowner \$DRMPIDS" >> "\$PROG"
# Name the holders. The previous version printed a name-filtered ps | head -4
# and missed the only PID that mattered, because the holder was not called
# anything with "trimui" in it and sorted after the four that were.
for dp in \$DRMPIDS; do
    echo "TSP_SWAPBENCH drmpid \$dp = \$(tr '\\0' ' ' < /proc/\$dp/cmdline 2>/dev/null)" >> "\$PROG"
done

# Sweep until one driver actually returns a window. Each attempt is 40 frames,
# and its own FAIL or mode=0 line goes in the log, so a total failure says which
# drivers were tried rather than just going quiet.
PICK="none"
for drv in kmsdrm "" wayland x11; do
    if [ -n "\$drv" ]; then export SDL_VIDEODRIVER="\$drv"; else unset SDL_VIDEODRIVER; fi
    echo "TSP_SWAPBENCH try SDL_VIDEODRIVER=\${drv:-<unset>}" >> "\$PROG"
    O="\$("\$BENCH" 0 40 4 2>&1)"
    echo "\$O" >> "\$PROG"
    case "\$O" in *"mode=0"*) PICK="\${drv:-<unset>}"; break;; esac
done
echo "TSP_SWAPBENCH driverpick \$PICK" >> "\$PROG"

if [ "\$PICK" = "none" ]; then
    echo "TSP_SWAPBENCH FAIL no video driver produced a window - read the drmowner and procs lines above" >> "\$PROG"
else
    for m in 0 3 1 2; do
        "\$BENCH" \$m 300 4 >> "\$PROG" 2>&1
    done
    "\$BENCH" 2 300 16 >> "\$PROG" 2>&1
    "\$BENCH" 1 300 16 >> "\$PROG" 2>&1
fi
echo "===== TSP_SWAPBENCH done =====" >> "\$PROG"
ENTEOF
    r "chmod +x '$BENCH_ENTRY'" || die "could not chmod the Ports entry"
    r "ls -la '$BENCH_ENTRY'" | sed 's/^/  /'
    echo "  -- the entry as written, so nothing in it is a surprise --"
    r "cat '$BENCH_ENTRY'" | sed 's/^/    /'

    head2 "6. WHAT TO DO"
    cat <<'NOTE'
  Refresh the ROM list in the TrimUI menu (no reboot needed), then launch the
  entry called:

      TSP Swap Bench

  It runs for about ten seconds, writes its results, and drops you back at the
  menu. It does NOT start Morrowind. Then:

      bash ~/Downloads/tsp_b2.sh read

  If "TSP Swap Bench" does not appear in the menu after a refresh, say so and I
  will overwrite an entry that is already there instead - a brand new .sh
  filename is not guaranteed to show up.
NOTE
    } 2>&1 | tee "$OUT"
    printf '\n  Saved to: %s\n  Upload that file rather than pasting it.\n\n' "$OUT"
    exit 0
fi

################################################################################
# why - read-only. Why the bench cannot get a window, and whether the swap
# question can be answered from data already on the device instead.
################################################################################
if [ "$MODE" = "why" ]; then
    need_device
    OUT="$HOME/Downloads/tsp-b2-why${DEVTAG}-$STAMP.txt"
    {
    head2 "0. WHAT THIS IS FOR"
    cat <<'NOTE'
  Two bench runs have produced no measurement. Before a third, this asks the
  device four read-only questions. Nothing is written and nothing is launched.

  It may also make the bench unnecessary. probe reported tsp_gltime.txt at 425
  lines / 79701 bytes - that is real swap timing from the real game - and the
  read parser said "no swap samples", which means the parser is wrong about the
  format, not that the data is missing. If those samples cluster tightly at
  ~16.7 ms, vsync is on and the question is answered without a bench at all.
NOTE

    head2 "1. WHO HOLDS /dev/dri/card0, BY NAME"
    echo "  The last run said PID 1719 holds it, and the ps filter missed that PID"
    echo "  entirely - it printed four processes, none of them 1719."
    rin "sh -s" <<'REMOTE'
P="$(fuser /dev/dri/card0 2>/dev/null | tr -d ':')"
echo "  holders: ${P:-<none>}"
for p in $P; do
    echo "  pid $p: $(tr '\0' ' ' < /proc/$p/cmdline 2>/dev/null)"
    echo "     exe: $(readlink /proc/$p/exe 2>/dev/null)"
done
echo "  -- every process, unfiltered, so nothing is cut off this time --"
ps w 2>/dev/null | sed 's/^/    /'
REMOTE

    head2 "2. THE SWAP SAMPLES ALREADY ON THE DEVICE"
    echo "  Exact line shapes, so the parser can be written against the real format"
    echo "  instead of against what I assumed it was."
    rin "sh -s" <<'REMOTE'
for f in /mnt/SDCARD/tsp_gltime.txt /mnt/SDCARD/tsp_state.txt; do
    if [ -s "$f" ]; then
        echo "  -- $f: $(wc -l < "$f") lines, $(wc -c < "$f") bytes"
        echo "     first 4:"; head -4 "$f" | sed 's/^/       /'
        echo "     last 4:";  tail -4 "$f" | sed 's/^/       /'
        echo "     distinct field counts: $(awk '{print NF}' "$f" | sort -u | tr '\n' ' ')"
        echo "     lines containing swap/Swap: $(grep -c -i swap "$f")"
    else
        echo "  -- $f: absent or empty"
    fi
done
REMOTE

    head2 "3. HOW OPENMW IS ACTUALLY LAUNCHED"
    echo "  There is no exec of the game to anchor on: the launcher's own lines"
    echo "  765-769 use kill -0 \"\$OPENMW_PID\", so it is backgrounded with \$!"
    echo "  captured. My exec anchor found the log redirection at line 78 instead"
    echo "  and dumped the top of the file, which told me nothing."
    r "grep -n -e 'openmw-0.51' -e 'OPENMW_PID=' -e 'LIBGL_TSP_NOPRELOAD' \
            -e 'LD_PRELOAD' '$LAUNCHER' | head -24" | sed 's/^/    /'
    echo
    echo "  -- the 25 lines around where OPENMW_PID is assigned --"
    r "awk '/OPENMW_PID=\\\$!/ { print NR; exit }' '$LAUNCHER'" > /tmp/tsp_b2_pidline.txt 2>/dev/null
    PL="$(cat /tmp/tsp_b2_pidline.txt 2>/dev/null)"
    case "$PL" in ''|*[!0-9]*) PL=0 ;; esac
    if [ "$PL" -gt 0 ]; then
        F=$((PL - 20)); [ "$F" -lt 1 ] && F=1
        r "awk 'NR >= $F && NR <= $((PL + 4)) { printf \"%5d  %s\\n\", NR, \$0 }' '$LAUNCHER'" | sed 's/^/    /'
    else
        echo "    no 'OPENMW_PID=\$!' line found - widening:"
        r "grep -n -B2 -A6 'openmw-0.51' '$LAUNCHER' | head -40" | sed 's/^/    /'
    fi

    head2 "4. THE LAUNCHER ALREADY SAYS VSYNC IS OFF"
    echo "  Section 4 of the bench transcript found two lines worth reading in full:"
    echo "    631:        \"vsync\": \"false\","
    echo "    2032: #     with vsync confirmed off. The resolution-lowering patch is kept, just"
    echo "  If that 'confirmed' is sound, candidate B is already dead and the 12 ms"
    echo "  is GPU work - which the 150 MHz time-in-state makes very plausible."
    r "awk 'NR >= 620 && NR <= 645 { printf \"%5d  %s\\n\", NR, \$0 }' '$LAUNCHER'" | sed 's/^/    /'
    echo
    r "awk 'NR >= 2020 && NR <= 2045 { printf \"%5d  %s\\n\", NR, \$0 }' '$LAUNCHER'" | sed 's/^/    /'

    head2 "5. WHAT GL/EGL THE PORT ACTUALLY SHIPS"
    echo "  I claimed no LIBGL_* variable could matter here. That was right about"
    echo "  the MEASUREMENT and wrong about whether a context can be created at"
    echo "  all: gl4es initialises EGL itself, so if it needs configuring to come"
    echo "  up, 'EGL not initialized' is exactly what a bare environment gets."
    r "ls -la '$GAME/lib' 2>/dev/null | grep -i -e egl -e libgl -e gles -e sdl" | sed 's/^/    /'
    echo
    echo "  -- and what the system has --"
    r "ls -la /usr/lib/libEGL* /usr/lib/libGL* /usr/lib/libmali* 2>/dev/null" | sed 's/^/    /'

    head2 "6. NEXT"
    cat <<'NOTE'
  Send this file. Depending on what section 2 shows, the next step is either a
  corrected parser over data already collected - no bench, no play session - or
  one more bench run with the GL environment section 5 says it needs.
NOTE
    } 2>&1 | tee "$OUT"
    printf '\n  Saved to: %s\n  Upload that file rather than pasting it.\n\n' "$OUT"
    exit 0
fi

################################################################################
# clock - pin the Mali clock at max, or restore it. No launcher edit.
################################################################################
# ====================================================================== cpu ===
# THE ONE LEVER THAT EXISTS ON BOTH CONSOLES.
#
# `clock` pins the Mali devfreq, and the stock card has no devfreq at all - no
# node, no kbase, no power_policy - so that fix can only ever serve one of the
# two machines. cpufreq is not a GPU driver. It is present on the A55 card and
# on the A53 card, so this is hardware-agnostic by construction rather than by
# hope.
#
# And it is not theoretical. The A523 card reported:
#     cpu0 hw max:   1416000 kHz
#     cpu0 allowed:  1128000 kHz   gov=ondemand
#     thermal_zone0=48692
# The governor was capped 20% under the silicon while the chip sat at 48 C.
# The remaining frame problem is 51 ms OUTSIDE GL (total=59.5 gl=8.0), which is
# CPU and IO, so CPU headroom is aimed at the right thing for once.
#
# What this does NOT do: bring parked cores online. Five of eight are offline on
# the A523 card and that is a bigger, hotter change with its own failure mode.
# One lever at a time, each with a number.
if [ "$MODE" = "cpu" ]; then
    need_device
    case "$SUB" in
    read | "")
        head2 "CPUFREQ AS IT IS NOW"
        rin "sh -s" <<'CPUREAD'
for c in /sys/devices/system/cpu/cpu[0-9]*; do
    n="${c##*/}"
    o="1"; [ -f "$c/online" ] && o="$(cat "$c/online" 2>/dev/null)"
    if [ ! -d "$c/cpufreq" ]; then
        printf '  %-6s online=%s  (no cpufreq node)\n' "$n" "$o"; continue
    fi
    printf '  %-6s online=%s gov=%-12s cur=%-9s allowed_max=%-9s hw_max=%-9s\n' \
      "$n" "$o" \
      "$(cat "$c/cpufreq/scaling_governor" 2>/dev/null)" \
      "$(cat "$c/cpufreq/scaling_cur_freq" 2>/dev/null)" \
      "$(cat "$c/cpufreq/scaling_max_freq" 2>/dev/null)" \
      "$(cat "$c/cpufreq/cpuinfo_max_freq" 2>/dev/null)"
done
echo "  governors available: $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors 2>/dev/null)"
echo "  OPPs:                $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_frequencies 2>/dev/null)"
printf '  thermal:'
for t in /sys/class/thermal/thermal_zone*; do
    [ -r "$t/temp" ] && printf ' %s=%s' "${t##*/}" "$(cat "$t/temp" 2>/dev/null)"
done
echo
if [ -f /mnt/SDCARD/tsp_b2_cpu_saved ]; then
    echo "  SAVED STATE PRESENT, so 'cpu on' has been run here:"
    sed 's/^/    /' /mnt/SDCARD/tsp_b2_cpu_saved
else
    echo "  no saved state - 'cpu on' has not been run on this card"
fi
CPUREAD
        echo
        echo "  Lift it with:   bash ~/Downloads/tsp_b2.sh cpu on"
        echo
        ;;
    on)
        head2 "LIFT THE CPUFREQ CAP TO THE SILICON MAX"
        rin "sh -s" <<'CPUON'
S=/mnt/SDCARD/tsp_b2_cpu_saved
# Save ONCE. A second 'cpu on' must not overwrite the originals with the
# pinned values - the same trap the GPU clock mode already guards against.
if [ ! -f "$S" ]; then
    TMP="$S.building"
    : > "$TMP"
    BAD=0
    for c in /sys/devices/system/cpu/cpu[0-9]*; do
        [ -d "$c/cpufreq" ] || continue
        n="${c##*/}"
        g="$(cat "$c/cpufreq/scaling_governor" 2>/dev/null)"
        m="$(cat "$c/cpufreq/scaling_max_freq" 2>/dev/null)"
        # An empty read must never be saved: restoring it later would write an
        # empty string into governor/scaling_max_freq.
        # all-digits or refuse. My first version of this test was a
        # parameter-expansion trick that did not mean what it read like.
        case "$m" in ''|*[!0-9]*) g="" ;; esac
        if [ -z "$g" ]; then
            echo "  REFUSING: $n gave governor=[$(cat "$c/cpufreq/scaling_governor" 2>/dev/null)] scaling_max=[$m]"
            BAD=1; break
        fi
        printf '%s %s %s\n' "$n" "$g" "$m" >> "$TMP"
    done
    if [ "$BAD" = "1" ] || [ ! -s "$TMP" ]; then
        rm -f "$TMP"
        echo "  Nothing was changed - without a readable original there is"
        echo "  nothing to restore to."
        exit 1
    fi
    mv "$TMP" "$S"
    echo "  saved the original governor and cap for each cpu to $S"
else
    echo "  original already saved at $S - not re-saving"
fi
sed 's/^/    /' "$S"

echo "  -- applying --"
PERF=0
case "$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors 2>/dev/null)" in
    *performance*) PERF=1 ;;
esac
[ "$PERF" = "1" ] || echo "    no performance governor on this card - leaving the governor alone"
for c in /sys/devices/system/cpu/cpu[0-9]*; do
    [ -d "$c/cpufreq" ] || continue
    n="${c##*/}"
    hw="$(cat "$c/cpufreq/cpuinfo_max_freq" 2>/dev/null)"
    [ -n "$hw" ] || { echo "    $n: no cpuinfo_max_freq, skipped"; continue; }
    printf '%s' "$hw" > "$c/cpufreq/scaling_max_freq" 2>/dev/null
    [ "$PERF" = "1" ] && printf 'performance' > "$c/cpufreq/scaling_governor" 2>/dev/null
    printf '    %-6s gov=%-12s allowed_max=%-9s cur=%s\n' "$n" \
      "$(cat "$c/cpufreq/scaling_governor" 2>/dev/null)" \
      "$(cat "$c/cpufreq/scaling_max_freq" 2>/dev/null)" \
      "$(cat "$c/cpufreq/scaling_cur_freq" 2>/dev/null)"
done
printf '  thermal now:'
for t in /sys/class/thermal/thermal_zone*; do
    [ -r "$t/temp" ] && printf ' %s=%s' "${t##*/}" "$(cat "$t/temp" 2>/dev/null)"
done
echo
CPUON
        echo
        echo "  This does not survive a reboot. That is deliberate: if it makes"
        echo "  the console run hot, power-cycling is the way out."
        echo
        echo "  Back out now with:  bash ~/Downloads/tsp_b2.sh cpu off"
        echo
        ;;
    off)
        head2 "PUT CPUFREQ BACK EXACTLY AS IT WAS"
        rin "sh -s" <<'CPUOFF'
S=/mnt/SDCARD/tsp_b2_cpu_saved
[ -f "$S" ] || { echo "  no saved state on this card - nothing to restore"; exit 0; }
while read -r n g m; do
    [ -n "$n" ] || continue
    c="/sys/devices/system/cpu/$n/cpufreq"
    [ -d "$c" ] || { echo "  $n: no cpufreq node any more, skipped"; continue; }
    printf '%s' "$g" > "$c/scaling_governor" 2>/dev/null
    printf '%s' "$m" > "$c/scaling_max_freq" 2>/dev/null
    printf '  %-6s restored gov=%-12s allowed_max=%s\n' "$n" \
      "$(cat "$c/scaling_governor" 2>/dev/null)" \
      "$(cat "$c/scaling_max_freq" 2>/dev/null)"
done < "$S"
rm -f "$S" && echo "  saved state removed"
CPUOFF
        echo
        ;;
    *)  die "cpu takes: read | on | off" ;;
    esac
    exit 0
fi

if [ "$MODE" = "clock" ]; then
    need_device
    case "$SUB" in
    on)
        head2 "PIN THE GPU CLOCK AT MAX + START THE 1 Hz SAMPLER"
        discover > /tmp/tsp_b2_gpu.txt || die "discovery failed"
        cat /tmp/tsp_b2_gpu.txt | sed 's/^/  /'
        . /tmp/tsp_b2_gpu.txt
        [ -n "${GPUNODE:-}" ] || die "no devfreq node found - run 'probe' and send me section 1"
        [ "${MAXF:-0}" -gt 0 ] || die "could not read a max_freq - run 'probe' and send me section 1"

        rin "sh -s" <<CLK2EOF
set -e
GPUNODE="$GPUNODE"; MALI="$MALI"; MAXF="$MAXF"; SAVED="$SAVED"

# Save the current state ONCE, so repeated 'clock on' cannot overwrite the
# original values with the pinned ones.
if [ ! -f "\$SAVED" ]; then
    # A failed sysfs read must never be saved as an empty value - restoring it
    # later would write an empty string into governor/min_freq. Same class as the
    # sampler that wrote 0 for a failed read and produced own/s = -10203.
    CURGOV=\$(cat "\$GPUNODE/governor" 2>/dev/null)
    CURMIN=\$(cat "\$GPUNODE/min_freq" 2>/dev/null)
    if [ -z "\$CURGOV" ] || [ -z "\$CURMIN" ]; then
        echo "  REFUSING: cannot read the current governor/min_freq from \$GPUNODE"
        echo "    governor=[\$CURGOV] min_freq=[\$CURMIN]"
        echo "    Without a readable original there is nothing to restore to, so"
        echo "    nothing has been changed. Run 'probe' and send me section 1."
        exit 1
    fi
    {
      echo "GOV=\$CURGOV"
      echo "MINF=\$CURMIN"
      if [ -n "\$MALI" ]; then
        echo "POLICY=\$(sed 's/.*\[\(.*\)\].*/\1/' \$MALI/power_policy 2>/dev/null)"
      fi
    } > "\$SAVED"
    echo "  saved original state to \$SAVED"
else
    echo "  \$SAVED already exists, keeping the original values it holds:"
fi
cat "\$SAVED" | sed 's/^/    /'

HOW="none"
if cat "\$GPUNODE/available_governors" 2>/dev/null | grep -q performance; then
    echo performance > "\$GPUNODE/governor" 2>/dev/null && HOW="governor=performance"
fi
if [ "\$HOW" = "none" ]; then
    echo "\$MAXF" > "\$GPUNODE/min_freq" 2>/dev/null && HOW="min_freq=max"
fi
if [ "\$HOW" = "none" ] && [ -e "\$GPUNODE/set_freq" ]; then
    echo userspace > "\$GPUNODE/governor" 2>/dev/null
    echo "\$MAXF" > "\$GPUNODE/set_freq" 2>/dev/null && HOW="userspace+set_freq"
fi
[ "\$HOW" = "none" ] && { echo "  COULD NOT PIN THE CLOCK - no performance governor, min_freq not writable, no set_freq"; exit 1; }

if [ -n "\$MALI" ] && cat "\$MALI/power_policy" 2>/dev/null | grep -q always_on; then
    echo always_on > "\$MALI/power_policy" 2>/dev/null && echo "  power_policy -> always_on (no power-gating between frames)"
fi

sleep 1
echo "  method: \$HOW"
echo "  governor now: \$(cat \$GPUNODE/governor 2>/dev/null)"
echo "  cur_freq now: \$(cat \$GPUNODE/cur_freq 2>/dev/null)   max: \$MAXF"
if [ -n "\$MALI" ]; then echo "  power_policy now: \$(cat \$MALI/power_policy 2>/dev/null)"; fi

CLK2EOF
        [ $? -eq 0 ] || die "could not pin the clock - see above. Nothing was left half-applied; run 'clock off' to be sure."

        # The 1 Hz sampler is written, started and verified in three SEPARATE
        # calls. Backgrounding it inside the heredoc above hung the ssh channel:
        # ssh does not return while any child still holds the channel, so the
        # whole subcommand blocked forever. Caught by running this, not reading it.
        # cat, not `read` - see the note at the top of this file.
        echo
        echo "  -- 1 Hz clock sampler --"
        r "rm -f $CARD/tsp_gpuwatch_off && : > $GPUWATCH" || die "could not clear the sampler log"
        rin "cat > /tmp/tsp_gpuwatch.sh" <<'WEOF'
#!/bin/sh
# TSP_GPUWATCH_V1 - one line per second. Exits when the off switch appears.
N="$1"
while [ ! -e /mnt/SDCARD/tsp_gpuwatch_off ]; do
    C=$(cat "$N/cur_freq" 2>/dev/null)
    G=$(cat "$N/governor" 2>/dev/null)
    T=$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null)
    echo "$(date +%s) cur=$C gov=$G temp=$T" >> /tmp/tsp_gpuwatch.txt
    sleep 1
done
WEOF
        [ $? -eq 0 ] || die "could not write the sampler to the device"
        r "chmod +x /tmp/tsp_gpuwatch.sh" || die "could not chmod the sampler"
        rbg "setsid /bin/sh /tmp/tsp_gpuwatch.sh '$GPUNODE' </dev/null >/dev/null 2>&1 &"
        BGRC=$?
        if [ "$BGRC" = "124" ]; then
            echo "  (the start call had to be timed out - that is expected on some busybox"
            echo "   ssh builds and does not mean the sampler failed. Checking for ticks.)"
        fi
        sleep 4
        TICKS="$(r "wc -l < $GPUWATCH 2>/dev/null" | tr -d ' ')"
        case "$TICKS" in
            ''|0) echo "  SAMPLER NOT RUNNING - 0 ticks after 4 s."
                  echo "  The clock IS pinned, but without the sampler a clock A/B cannot be"
                  echo "  trusted, so do not spend a play session on it yet. Send me this and"
                  echo "  I will start it a different way."
                  ;;
            *)    echo "  sampler: $TICKS ticks after 4 s (expect 3-4)"
                  r "tail -2 $GPUWATCH" | sed 's/^/    /'
                  ;;
        esac

        head2 "NOW PLAY"
        cat <<'NOTE'
  Launch MORROWIND from your ports menu - the main entry.

  Do the SAME fixed route twice, once with the clock pinned (now) and once after
  running 'clock off'. Same save, same walk, same duration. Two uncontrolled runs
  are not an A/B.

  Then: bash ~/Downloads/tsp_b2.sh read

  The sampler is checked first. If the max OPP does not own at least 95% of the
  ticks, the run is VOID and something on the OS is resetting the governor - that
  is almost certainly why this "changed nothing" the last time it was tried.

  The clock stays pinned until you run 'clock off'. That costs battery and heat,
  so do not leave it on overnight.
NOTE
        exit 0
        ;;
    off)
        head2 "RESTORE THE GPU CLOCK + STOP THE SAMPLER"
        r "touch $CARD/tsp_gpuwatch_off"
        discover > /tmp/tsp_b2_gpu.txt || die "discovery failed"
        . /tmp/tsp_b2_gpu.txt
        rin "sh -s" <<RSTEOF
GPUNODE="$GPUNODE"; MALI="$MALI"; SAVED="$SAVED"
if [ ! -f "\$SAVED" ]; then
    echo "  no saved state at \$SAVED - nothing to restore. Current values:"
    echo "    governor=\$(cat \$GPUNODE/governor 2>/dev/null) cur=\$(cat \$GPUNODE/cur_freq 2>/dev/null) min=\$(cat \$GPUNODE/min_freq 2>/dev/null)"
    exit 0
fi
. "\$SAVED"
[ -n "\${MINF:-}" ] && echo "\$MINF" > "\$GPUNODE/min_freq" 2>/dev/null
[ -n "\${GOV:-}" ]  && echo "\$GOV"  > "\$GPUNODE/governor" 2>/dev/null
if [ -n "\$MALI" ] && [ -n "\${POLICY:-}" ]; then echo "\$POLICY" > "\$MALI/power_policy" 2>/dev/null; fi
sleep 1
echo "  restored: governor=\$(cat \$GPUNODE/governor 2>/dev/null) min=\$(cat \$GPUNODE/min_freq 2>/dev/null) cur=\$(cat \$GPUNODE/cur_freq 2>/dev/null)"
if [ -n "\$MALI" ]; then echo "  power_policy=\$(cat \$MALI/power_policy 2>/dev/null)"; fi
rm -f "\$SAVED"
RSTEOF
        echo "  sampler stopped (tsp_gpuwatch_off placed). Its log is kept for 'read'."
        exit 0
        ;;
    *)
        die "clock takes 'on' or 'off':  bash ~/Downloads/tsp_b2.sh clock on"
        ;;
    esac
fi

################################################################################
# scaler - a separate Ports entry with the fullscreen scaler shim dropped
################################################################################
if [ "$MODE" = "scaler" ]; then
    need_device
    head2 "1. FIND THE SCALER IN THE PRELOAD CHAIN"
    r "test -f '$LAUNCHER'" || die "launcher not found at $LAUNCHER"
    r "grep -n fullscreen_scaler '$LAUNCHER'" > /tmp/tsp_b2_scaler.txt 2>/dev/null
    if [ -s /tmp/tsp_b2_scaler.txt ]; then
        sed 's/^/  /' /tmp/tsp_b2_scaler.txt
    else
        echo "  NOTHING MATCHED 'fullscreen_scaler' in the launcher."
        echo "  Survey - every preload-looking line, so I can fix the pattern:"
        r "grep -n -i -e preload -e '\.so' '$LAUNCHER' | head -30" | sed 's/^/    /'
        die "cannot build the NoScaler variant without knowing which line loads it"
    fi

    head2 "2. WRITE 'Morrowind NoScaler.sh' - A COPY, THE ORIGINAL IS UNTOUCHED"
    rin "sh -s" <<SCLEOF
set -e
SRC="$LAUNCHER"
DST="$NOSCALER_ENTRY"
awk '
  /fullscreen_scaler/ {
      before = \$0
      line = \$0
      # strip the scaler .so token and any colon that joined it to its neighbours
      gsub(/[^:"'"'"' \t=]*fullscreen_scaler[^:"'"'"' \t]*/, "", line)
      gsub(/::+/, ":", line)
      gsub(/=:/, "=", line)
      gsub(/:"/, "\"", line)
      printf "BEFORE %s\n", before > "/tmp/tsp_noscaler_diff.txt"
      printf "AFTER  %s\n", line   > "/tmp/tsp_noscaler_diff.txt"
      print line
      next
  }
  { print }
' "\$SRC" > "\$DST.tmp"

# Refuse on anything that looks like damage.
SB=\$(wc -l < "\$SRC"); DB=\$(wc -l < "\$DST.tmp")
if [ "\$SB" != "\$DB" ]; then rm -f "\$DST.tmp"; echo "REFUSING: line count changed \$SB -> \$DB"; exit 1; fi
if grep -q fullscreen_scaler "\$DST.tmp"; then rm -f "\$DST.tmp"; echo "REFUSING: the scaler is still referenced after the edit"; exit 1; fi
mv "\$DST.tmp" "\$DST"
chmod +x "\$DST"
echo "  wrote \$DST  (\$DB lines, same as the original)"
echo "  -- the only lines that differ --"
cat /tmp/tsp_noscaler_diff.txt 2>/dev/null | sed 's/^/    /'
SCLEOF
    [ $? -eq 0 ] || die "the NoScaler variant was refused and not written. The original launcher was never touched."

    head2 "3. WHAT TO DO"
    cat <<'NOTE'
  Refresh the ROM list, then run the SAME fixed route twice:

      Morrowind             (the normal entry, scaler on)
      Morrowind NoScaler    (the new entry, scaler dropped from the preload chain)

  Then: bash ~/Downloads/tsp_b2.sh read

  If swap p50 drops with the scaler gone, its "identity blit" at 1280x720 was a
  real full-screen pass and it should only be preloaded for non-native output.
  The shim already logs scale=0 source=1280x720 requested_output=1280x720, so
  dropping it at native resolution is known-safe.
NOTE
    exit 0
fi

################################################################################
# read - pull everything and score it
################################################################################
if [ "$MODE" = "read" ]; then
    need_device
    OUT="$HOME/Downloads/tsp-b2-read${DEVTAG}-$STAMP.txt"
    RAW="/tmp/tsp_b2_raw.$$"
    {
    head2 "1. GPU CLOCK SAMPLER - THE GATE ON EVERY CLOCK RESULT"
    # The ceiling comes from the NODE, never from the log. Taking the highest
    # frequency that appears in the log would score a clock stuck at 150 MHz as
    # "the max OPP held 100% of the time" - the exact inversion that makes a void
    # run look valid.
    discover > /tmp/tsp_b2_gpu.txt 2>/dev/null
    NODEMAX=0
    if [ -s /tmp/tsp_b2_gpu.txt ]; then
        . /tmp/tsp_b2_gpu.txt
        NODEMAX="${MAXF:-0}"
    fi
    echo "  node ceiling (max_freq): $NODEMAX Hz"
    r "cat $GPUWATCH 2>/dev/null" > "$RAW.gpu"
    if [ -s "$RAW.gpu" ]; then
        awk -v nodemax="$NODEMAX" '{
              for (i=1;i<=NF;i++) {
                if ($i ~ /^cur=/)  { split($i,a,"="); if (a[2] != "") { c[a[2]]++; n++ } }
                if ($i ~ /^gov=/)  { split($i,a,"="); if (a[2] != "") g[a[2]]++ }
                if ($i ~ /^temp=/) { split($i,a,"="); if (a[2] != "") { t=a[2]+0; if (t>tmax) tmax=t; ts+=t; tn++ } }
              }
            }
            END {
              if (n==0) { print "  no cur= samples in the log"; exit }
              printf "  %d ticks\n", n
              printf "  time at each OPP:\n"
              for (k in c) printf "    %14s Hz  %5d ticks  %5.1f%%%s\n", k, c[k], 100*c[k]/n, (k+0==nodemax+0 ? "   <== the node ceiling" : "")
              printf "  governors seen:"; for (k in g) printf " %s(%d)", k, g[k]; printf "\n"
              if (tn>0) printf "  temp: mean %.1f C  max %.1f C\n", ts/tn/1000, tmax/1000
              if (nodemax+0 <= 0) { print "  VERDICT: could not read the node ceiling, so this cannot be scored. Run probe."; exit }
              atmax = (nodemax in c) ? c[nodemax] : 0
              share = 100*atmax/n
              top=0; for (k in c) if (k+0 > top+0) top=k
              if (share >= 95) {
                  printf "  VERDICT: the ceiling %s Hz held %.1f%% of the time - a clock A/B taken now is VALID\n", nodemax, share
              } else {
                  printf "  VERDICT: the ceiling %s Hz held only %.1f%% of the time. ANY CLOCK RESULT IS VOID.\n", nodemax, share
                  printf "           The highest frequency actually seen was %s Hz.\n", top
                  if (top+0 < nodemax+0)
                      print  "           The clock never reached the ceiling at all, so the pin did not take"
                  print  "           effect or something is resetting it. See probe section 6 before"
                  print  "           spending another play session on this."
              }
            }' "$RAW.gpu"
    else
        echo "  no sampler log on the device. Either 'clock on' was never run, or the"
        echo "  sampler died. Without it a clock A/B cannot be trusted - that is the"
        echo "  check the earlier 'raised it, changed nothing' verdict never had."
    fi

    head2 "2. DISPLAY-PATH BENCH"
    r "grep -a TSP_SWAPBENCH $PROG 2>/dev/null | tail -44" > "$RAW.bench"
    if [ -s "$RAW.bench" ]; then
        sed 's/^/  /' "$RAW.bench"
        echo
        echo "  -- reading it --"
        awk '
          /interval req=0 got=/ { for(i=1;i<=NF;i++) if ($i ~ /^got=/) { split($i,a,"="); if (a[2]+0 != 0) vsync=1 } }
          /TSP_SWAPBENCH FAIL/     { fails++; lastfail = $0
                                     if ($0 ~ /EGL not initialized/) egl = 1 }
          /TSP_SWAPBENCH try /     { tried = tried $NF " " }
          /TSP_SWAPBENCH driverpick/ { pick = $NF }
          /TSP_SWAPBENCH drmowner/ { drm = $0; sub(/.*drmowner /, "", drm) }
          /TSP_SWAPBENCH procs/    { procs = $0; sub(/.*procs /, "", procs) }
          /mode=/ {
              md=""; p50=""
              for (i=1;i<=NF;i++) {
                if ($i ~ /^mode=/)  { split($i,a,"="); md=a[2] }
                if ($i ~ /^quads=/) { split($i,a,"="); qd=a[2] }
                if ($i ~ /^p50=/)   { split($i,a,"="); p50=a[2] }
              }
              if (md != "" && p50 != "") { key = md "/" qd; v[key]=p50+0; seen[key]=1 }
          }
          END {
            m0=v["0/4"]; m3=v["3/4"]; m1=v["1/4"]; m2=v["2/4"]; m1b=v["1/16"]; m2b=v["2/16"]
            if (!seen["0/4"]) {
              if (fails > 0) {
                printf "    THE ENTRY RAN AND GOT NO WINDOW: %d failures, no mode line.\n", fails
                printf "    last failure : %s\n", lastfail
                if (tried != "") printf "    drivers tried: %s\n", tried
                if (pick != "")  printf "    driverpick   : %s\n", pick
                if (drm != "")   printf "    card0 held by: %s\n", drm
                if (procs != "") printf "    UI processes : %s\n", procs
                print  ""
                if (egl) {
                  print "    \"EGL not initialized\" is SDL failing to get a KMS/EGL display at"
                  print "    all. Either no video driver was named - the old entry spliced the"
                  print "    launcher exports and still left SDL_VIDEODRIVER empty - or MainUI"
                  print "    still holds DRM master on card0, in which case the card0/UI lines"
                  print "    above say so and the entry has to take the display the way the"
                  print "    launcher does. Section 4 of the bench transcript dumps that."
                }
              } else {
                print "    no mode 0 line yet - launch the TSP Swap Bench entry first"
              }
              exit
            }
            if (pick != "") printf "    video driver that worked    : %s\n", pick
            printf "    mode 0 (clear+swap)          p50 %6.2f ms\n", m0
            if (seen["3/4"])  printf "    mode 3 (clear+swap, vsync)  p50 %6.2f ms\n", m3
            if (seen["1/4"])  printf "    mode 1 (4 quads + swap)     p50 %6.2f ms\n", m1
            if (seen["2/4"])  printf "    mode 2 (4 quads + finish)   p50 %6.2f ms\n", m2
            if (seen["1/16"]) printf "    mode 1 (16 quads + swap)    p50 %6.2f ms\n", m1b
            if (seen["2/16"]) printf "    mode 2 (16 quads + finish)  p50 %6.2f ms\n", m2b
            print ""
            if (vsync) {
              print "    CANDIDATE B CONFIRMED: SDL reported got!=0 after asking for interval 0."
              print "    Interval 0 is not honoured, so every swap waits for a vblank. That is a"
              print "    hard 16.7 ms cadence and no amount of GPU clock will move it."
              print "    Next: the port builds its own SDL 2.30.12 - KMSDRM_GLES_SwapWindow can be"
              print "    patched to skip KMSDRM_WaitPageflip at interval 0. That trades tearing for"
              print "    frame rate, which is your call on screen, not mine."
            } else if (m0 <= 2.0) {
              print "    The display path is FREE (mode 0 p50 <= 2 ms) and interval 0 is honoured."
              print "    So the 12 ms in OpenMW is not the flip - it is GPU work being serialised"
              print "    into swap by gbm_surface_lock_front_buffer. CANDIDATE A: the clock."
              if (seen["2/16"] && seen["2/4"] && m2b > m2) {
                printf "    12 extra 720p blended fills cost %.2f ms -> %.3f ms per full-screen fill.\n", m2b-m2, (m2b-m2)/12
                print "    Re-run this with the clock pinned: if that per-fill number drops roughly"
                print "    in proportion to the clock, the GPU really moved and candidate A is live."
              }
            } else if (seen["3/4"] && m0 > 5.0 && (m0/m3) > 0.8) {
              printf "    mode 0 (%.2f) is close to mode 3 (%.2f) and both are large: the flip is\n", m0, m3
              print "    vblank-synced in practice even though SDL accepted interval 0. Same"
              print "    conclusion as candidate B above."
            } else {
              printf "    mode 0 p50 is %.2f ms - between free and vblank-bound. ", m0
              print "Send me this block and I will read it properly rather than guess a rule for it."
            }
            if (seen["1/4"] && seen["2/4"]) {
              d = m1 - m2
              if (d > 2.0) printf "    mode1-mode2 = %.2f ms: the flip/lock step itself carries real cost.\n", d
              else         printf "    mode1-mode2 = %.2f ms: the flip adds little once the GPU work is done.\n", d
            }
          }' "$RAW.bench"
    else
        echo "  no bench results on the device yet."
        echo "  Refresh the ROM list and launch the 'TSP Swap Bench' entry - 10 seconds."
    fi

    head2 "3. SWAP TIMING FROM THE GAME - THE ANSWER"
    cat <<'NOTE'
  The old parser here looked for a field starting "SwapWindow=" and found
  nothing, so it printed "no swap samples". The real field is
  SDL_GL_SwapWindow=9.91ms/1 - an SDL_GL_ prefix, an ms suffix and a /count
  tail - so the pattern never matched. The data was there the whole time.

  Two line shapes, and they answer different questions:
    TSP_GLT MEAN over N frames | SDL_GL_SwapWindow=..ms/1 ...   steady state
    TSP_GLT SLOW frame=N total=.. gl=.. shim=.. | ...           frames over
                                                                thresh_ms
NOTE
    for f in "$CARD/tsp_gltime.txt" "$CARD/tsp_state.txt"; do
        echo
        echo "  -- $f --"
        r "cat '$f' 2>/dev/null" > "$RAW.sw"
        if [ ! -s "$RAW.sw" ]; then echo "     absent or empty"; continue; fi
        awk '
          # strip name=, a trailing ms, and a /count tail. Written against the
          # real lines, not against an assumed shape.
          function val(tok) {
              sub(/^[A-Za-z_0-9]*=/, "", tok)
              p = index(tok, "/"); if (p > 0) tok = substr(tok, 1, p - 1)
              sub(/ms$/, "", tok)
              return tok + 0
          }
          /TSP_GLT MEAN/ {
              fr = 0
              for (i = 1; i <= NF; i++) {
                  if ($i == "over") fr = $(i+1) + 0
                  if ($i ~ /SwapWindow=/) {
                      sw = val($i); mn++
                      if (mn == 1) { first = sw; frfirst = fr }
                      last = sw; frlast = fr
                      if (sw > swmax) swmax = sw
                      if (swmin == 0 || sw < swmin) swmin = sw
                  }
              }
              next
          }
          /TSP_GLT SLOW/ {
              slow++; t = 0; g = 0; sw = 0; top = ""; topv = 0
              for (i = 1; i <= NF; i++) {
                  if ($i ~ /^total=/) { t = val($i) }
                  if ($i ~ /^gl=/)    { g = val($i) }
                  if ($i ~ /SwapWindow=/) { sw = val($i) }
                  if ($i ~ /^gl[A-Z]/ && val($i) > topv) { topv = val($i); top = $i }
              }
              tsum += t; if (t > tmax) tmax = t
              gsum += g
              swsum += sw; if (sw > swmaxslow) swmaxslow = sw
              # gl= is the SUM OF PER-CALL TIMES, not the gl share of the frame,
              # it can exceed total: frame 1 on the device is total=60.8 gl=150.6.
              # Subtracting it from total is therefore undefined, and doing it
              # anyway printed "-19.1 ms of the mean frame is NOT in GL". Same
              # error class as ratioing pswpin pages against pgmajfault events.
              # So classify only where the subtraction is defined.
              if (g > t) over++
              else if (t - g > 20.0) outside++
              else inside++
              next
          }
          /swap_us=/ {
              d = 0; su = -1
              for (i = 1; i <= NF; i++) {
                  if ($i ~ /^draws=/)   { d = val($i) }
                  if ($i ~ /^swap_us=/) { su = val($i) / 1000.0 }
              }
              if (d >= 100 && su >= 0) { usn++; ussum += su; if (su > usmax) usmax = su }
              next
          }
          END {
              if (mn == 0 && slow == 0 && usn == 0) {
                  print "     no recognisable swap samples in this file"
                  exit
              }
              if (mn > 0) {
                  printf "     STEADY STATE, %d MEAN lines over frames %d..%d\n", mn, frfirst, frlast
                  printf "       SDL_GL_SwapWindow  %.2f -> %.2f ms per frame (range %.2f..%.2f)\n",
                         first, last, swmin, swmax
                  print  "       a vsync-locked swap would sit at 16.67 ms or a multiple of it."
                  if (swmax < 14.0) {
                      print  "       IT DOES NOT. Interval 0 IS honoured, vsync is off, and"
                      print  "       CANDIDATE B IS DEAD - no SDL patch is needed."
                      print  "       So this is GPU work serialised into swap by"
                      print  "       gbm_surface_lock_front_buffer, which is candidate A: the clock."
                  } else if (swmin > 15.5 && swmax < 18.0) {
                      print  "       IT DOES. That is vblank-bound - candidate B confirmed."
                  } else {
                      print  "       Neither cleanly. Send me this block rather than let me"
                      print  "       guess a rule for it."
                  }
              }
              if (slow > 0) {
                  printf "\n     SLOW FRAMES (over the shim own thresh_ms): %d\n", slow
                  printf "       mean total %.1f ms, worst %.1f ms\n", tsum/slow, tmax
                  printf "       mean of the gl= field: %.1f ms\n", gsum/slow
                  print  "         gl= sums the per-call times, so it can exceed total and is"
                  print  "         NOT the frame share - frame 1 here is total=60.8 gl=150.6."
                  print  "         total - gl is therefore only meaningful where gl < total."
                  printf "       swap within them: mean %.1f ms, worst %.1f ms\n", swsum/slow, swmaxslow
                  printf "       %d stalled OUTSIDE gl (total - gl > 20 ms)\n", outside
                  printf "       %d accounted for inside gl\n", inside
                  printf "       %d had gl > total, so the per-call sums overlap and no\n", over
                  print  "         split can be taken from those lines at all"
                  if (outside > 0) {
                      print  "       The OUTSIDE ones are the external stall already on record in"
                      print  "       RESULT-the-hitch-is-not-sound-phase-hopping. Those are the"
                      print  "       hitches, and they are not a GL or a clock problem."
                  }
                  if (inside > 0 || over > 0)
                      print  "       The rest are texture upload and shader compile, i.e. load."
              }
              if (usn > 0)
                  printf "\n     state shim: n=%d mean=%.2f max=%.2f ms (draws>=100 only)\n",
                         usn, ussum/usn, usmax
          }' "$RAW.sw"
    done

    head2 "4. SANITY"
    r "if [ -f $CARD/tsp_ring_off ]; then echo '  ring profiler: OFF (correct)'; else echo '  ring profiler: ARMED - it halves the framerate and voids everything above'; fi"
    r "if [ -f $SAVED ]; then echo '  GPU clock: still PINNED. Run: bash ~/Downloads/tsp_b2.sh clock off'; else echo '  GPU clock: not pinned'; fi"
    r "for t in /sys/class/thermal/thermal_zone*; do echo \"  \$(cat \$t/type 2>/dev/null) \$(cat \$t/temp 2>/dev/null)\"; done"

    head2 "5. THE SOUND PATCH, CHECKED FROM THE RIGHT FILE"
    echo "  The first pull grepped config-0.51/openmw.log and got nothing, while the"
    echo "  same lines were sitting in openmw_log.txt. So that file is where OpenMW"
    echo "  Log() output actually lands here, and TSP_SOUNDPHASE_V1 coming back empty"
    echo "  from openmw.log proved nothing at all."
    r "grep -a -c TSP_SOUNDPHASE_V1 $GAME/openmw_log.txt 2>/dev/null ; true" | sed 's/^/  TSP_SOUNDPHASE_V1 lines in openmw_log.txt: /'
    r "grep -a 'TSP_SOUNDPHASE_V1' $GAME/openmw_log.txt 2>/dev/null | tail -12" | sed 's/^/    /'
    r "grep -a 'No unused sound buffers' $GAME/openmw_log.txt 2>/dev/null | tail -5" | sed 's/^/    /'
    } 2>&1 | tee "$OUT"
    rm -f "$RAW".*
    echo
    echo "full report: $OUT"
    exit 0
fi

################################################################################
# clean - undo everything
################################################################################
if [ "$MODE" = "clean" ]; then
    need_device
    head2 "UNDO EVERYTHING THIS SCRIPT INSTALLED"
    echo "  Morrowind.sh was never modified, so there is nothing to restore there."
    r "touch $CARD/tsp_gpuwatch_off"
    discover > /tmp/tsp_b2_gpu.txt 2>/dev/null
    . /tmp/tsp_b2_gpu.txt 2>/dev/null || true
    rin "sh -s" <<CLNEOF
GPUNODE="${GPUNODE:-}"; MALI="${MALI:-}"; SAVED="$SAVED"
if [ -f "\$SAVED" ] && [ -n "\$GPUNODE" ]; then
    . "\$SAVED"
    [ -n "\${MINF:-}" ] && echo "\$MINF" > "\$GPUNODE/min_freq" 2>/dev/null
    [ -n "\${GOV:-}" ]  && echo "\$GOV"  > "\$GPUNODE/governor" 2>/dev/null
    if [ -n "\$MALI" ] && [ -n "\${POLICY:-}" ]; then echo "\$POLICY" > "\$MALI/power_policy" 2>/dev/null; fi
    rm -f "\$SAVED"
    echo "  GPU clock restored"
else
    echo "  GPU clock was not pinned"
fi
for f in "$BENCH_ENTRY" "$NOSCALER_ENTRY" "$BENCH" /tmp/tsp_gpuwatch.sh; do
    if [ -e "\$f" ]; then rm -f "\$f" && echo "  removed \$f"; fi
done
echo "  kept: $GPUWATCH and $PROG so 'read' still works"
CLNEOF
    echo
    echo "  Refresh the ROM list to drop the two entries from the menu."
    exit 0
fi

die "unknown subcommand '$MODE'. Run with no arguments for the list."
