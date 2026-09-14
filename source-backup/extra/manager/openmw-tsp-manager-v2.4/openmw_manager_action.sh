#!/bin/bash
# Runtime action backend for OpenMW 0.51 TSP Manager V2.4.
# TSP_MANAGER_V24_PROGRESS_BACKEND
#
# V2.4 changes:
#   - every long operation publishes live progress to $PROGRESS_FILE so the
#     manager UI can draw a progress bar instead of leaving a black screen;
#   - SETUP GAME FOR FIRST LAUNCH is storage only: base navmesh + swap.
#     Mod data roots and load order come from openmw.cfg and are never
#     rewritten by first-launch setup.
set -u -o pipefail

ACTION="${1:-status}"
SELFTEST=0
[ "$ACTION" = "selftest" ] && SELFTEST=1

if [ "$SELFTEST" -eq 1 ]; then
    ROOT="$(mktemp -d "${TMPDIR:-/tmp}/openmw-manager-action-selftest.XXXXXX")" || exit 90
    PROGRESS_FILE="$ROOT/progress"
else
    ROOT="${OPENMW_GAMEDIR:-${OPENMW51_GAMEDIR:-/mnt/SDCARD/data/ports/openmw}}"
    PROGRESS_FILE="${OPENMW_MANAGER_PROGRESS:-/tmp/openmw-manager-progress}"
fi

PY="$ROOT/launcher/openmw-launcher-backend-v2.py"
LOG="$ROOT/launcher/manager-v2.log"
RESULT="$ROOT/launcher/last-result.txt"
NAVDIR="${OPENMW_NAVMESH_DIR:-${OPENMW51_NAVMESH_DIR:-/mnt/UDISK/openmw-nav}}"
NAVDB="$NAVDIR/navmesh.db"
SWAP=/mnt/UDISK/openmw-swapfile
DEFAULT_SWAP="$ROOT/defaults/base-swapfile"
CLEANUP_FILE=""
STEP=0
STEPS=0

# Fractional sleep keeps the bar smooth; fall back to whole seconds if the
# device shell cannot do it.
SLEEP_TICK=0.5
sleep 0.1 >/dev/null 2>&1 || SLEEP_TICK=1

mkdir -p "$ROOT/launcher"
[ "$SELFTEST" -eq 1 ] || exec >>"$LOG" 2>&1

cleanup_temp() {
    if [ -n "$CLEANUP_FILE" ] && [ -f "$CLEANUP_FILE" ]; then
        rm -f "$CLEANUP_FILE"
    fi
    rm -f "$PROGRESS_FILE.tmp"
}
trap cleanup_temp EXIT INT TERM

say() {
    printf '%s\n' "$*"
    printf '%s\n' "$*" > "$RESULT"
}

# The most specific failure text already published by the failing step, so a
# multi-step wrapper never hides why it stopped.
last_reason() {
    head -n 1 "$RESULT" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# TSP_MANAGER_V24_PROGRESS_CONTRACT
# phase/pct/detail/step/steps, published atomically. pct=-1 means the UI should
# draw an indeterminate bar (hashing, mkswap, sync: no measurable byte count).
# ---------------------------------------------------------------------------
progress() {
    local phase="${1:-}" pct="${2:--1}" detail="${3:-}"
    {
        printf 'phase=%s\npct=%s\ndetail=%s\nstep=%s\nsteps=%s\n' \
            "$phase" "$pct" "$detail" "$STEP" "$STEPS" > "$PROGRESS_FILE.tmp" 2>/dev/null &&
        mv -f "$PROGRESS_FILE.tmp" "$PROGRESS_FILE" 2>/dev/null
    } || true
}

human_bytes() {
    awk -v n="${1:-0}" 'BEGIN {
        split("B KB MB GB TB", unit, " ")
        i = 1
        while (n >= 1024 && i < 5) { n /= 1024; i++ }
        if (i >= 4) printf "%.1f %s", n, unit[i]
        else printf "%.0f %s", n, unit[i]
    }'
}

# run_with_size_progress <phase> <watched file> <total bytes> <pct from> <pct to> <command...>
# Runs the command in the background and reports real byte progress by watching
# the growing output file. A completion file carries the exact child status, so
# the poll loop can never be confused by an unreaped process.
run_with_size_progress() {
    local phase="$1" watch="$2" total="$3" from="$4" to="$5"
    shift 5
    local done_file rc copied pct
    case "$total" in ''|*[!0-9]*) total=0 ;; esac
    done_file="$PROGRESS_FILE.done.$$"
    rm -f "$done_file"
    progress "$phase" "$from" "0 B / $(human_bytes "$total")"
    ( "$@"; printf '%s\n' "$?" > "$done_file" ) &
    while [ ! -s "$done_file" ]; do
        copied="$(stat -c %s "$watch" 2>/dev/null || printf '0')"
        case "$copied" in ''|*[!0-9]*) copied=0 ;; esac
        if [ "$total" -gt 0 ]; then
            pct=$(( from + ((to - from) * copied) / total ))
            [ "$pct" -le "$to" ] || pct="$to"
        else
            pct=-1
        fi
        progress "$phase" "$pct" "$(human_bytes "$copied") / $(human_bytes "$total")"
        sleep "$SLEEP_TICK"
    done
    read -r rc < "$done_file"
    rm -f "$done_file"
    wait 2>/dev/null || true
    case "$rc" in ''|*[!0-9]*) rc=1 ;; esac
    if [ "$rc" -eq 0 ]; then
        progress "$phase" "$to" "$(human_bytes "$total") / $(human_bytes "$total")"
    fi
    return "$rc"
}

run_python() {
    [ -x "$PY" ] || { say "ERROR backend missing: $PY"; return 10; }
    "$PY" "$@"
}

udisk_fs() {
    awk '$2=="/mnt/UDISK" {print $3; exit}' /proc/mounts 2>/dev/null
}

valid_udisk() {
    [ -d /mnt/UDISK ] || { say "ERROR UDISK is not mounted"; return 1; }
    case "$(udisk_fs)" in
        ext2|ext3|ext4|f2fs|btrfs|xfs) return 0 ;;
        *) say "ERROR UDISK filesystem cannot safely host swap: $(udisk_fs)"; return 1 ;;
    esac
}

tune_swap() {
    [ -w /proc/sys/vm/swappiness ] && printf '%s\n' 150 > /proc/sys/vm/swappiness 2>/dev/null || true
    [ -w /proc/sys/vm/vfs_cache_pressure ] && printf '%s\n' 50 > /proc/sys/vm/vfs_cache_pressure 2>/dev/null || true
}

activate_swap() {
    [ -e /proc/swaps ] || { say "ERROR kernel swap support unavailable"; return 20; }
    if grep -q "^$SWAP " /proc/swaps 2>/dev/null; then
        tune_swap
        say "Swap already active: $SWAP"
        return 0
    fi
    [ -f "$SWAP" ] || { say "ERROR swapfile is not installed"; return 21; }
    command -v swapon >/dev/null 2>&1 || { say "ERROR swapon is unavailable"; return 22; }
    chmod 600 "$SWAP" 2>/dev/null || true
    if swapon "$SWAP" 2>/dev/null; then
        tune_swap
        say "Swap activated: $SWAP"
        return 0
    fi
    say "ERROR swapon failed for $SWAP"
    return 23
}

install_swap() {
    progress "CHECKING UDISK" 0 "$SWAP"
    valid_udisk || return
    local mb=512 cfg=""
    if [ -r "$ROOT/tsp_swap_mb.txt" ]; then
        read -r cfg < "$ROOT/tsp_swap_mb.txt" || true
        case "$cfg" in ''|*[!0-9]*) ;; *) mb="$cfg" ;; esac
    fi
    case "$mb" in ''|*[!0-9]*|0) say "ERROR invalid swap size: $mb"; return 24;; esac
    command -v mkswap >/dev/null 2>&1 || { say "ERROR mkswap is unavailable"; return 25; }
    command -v swapon >/dev/null 2>&1 || { say "ERROR swapon is unavailable"; return 26; }
    if [ ! -f "$SWAP" ]; then
        local free need incoming source_size src_sha copied_sha
        progress "CHECKING FREE SPACE" 3 ""
        free="$(df -k /mnt/UDISK 2>/dev/null | awk 'NR==2 {print $4}')"
        case "$free" in ''|*[!0-9]*) free=0;; esac
        if [ -f "$DEFAULT_SWAP" ]; then
            source_size="$(stat -c %s "$DEFAULT_SWAP" 2>/dev/null || true)"
            case "$source_size" in ''|*[!0-9]*) say "ERROR invalid default swap size"; return 27;; esac
            [ "$source_size" -ge 67108864 ] || { say "ERROR default swap is smaller than 64 MB"; return 27; }
            need=$(((source_size / 1024) + 65536))
        else
            source_size=$((mb * 1024 * 1024))
            need=$((mb * 1024 * 2))
        fi
        [ "$free" -ge "$need" ] || { say "ERROR UDISK needs ${need} KB free for safe swap creation"; return 27; }
        incoming="$SWAP.incoming.$$"
        CLEANUP_FILE="$incoming"
        mkdir -p "$(dirname "$SWAP")" || { say "ERROR cannot create swap target directory"; return 28; }
        if [ -f "$DEFAULT_SWAP" ]; then
            say "Installing default swapfile on UDISK"
            run_with_size_progress "COPYING SWAP FILE TO UDISK" "$incoming" "$source_size" 5 60 \
                cp -p "$DEFAULT_SWAP" "$incoming" || { say "ERROR default swap copy failed"; return 28; }
            progress "VERIFYING SWAP CHECKSUM" -1 "$(human_bytes "$source_size")"
            src_sha="$(sha256sum "$DEFAULT_SWAP" | awk '{print $1}')"
            copied_sha="$(sha256sum "$incoming" | awk '{print $1}')"
            [ -n "$src_sha" ] && [ "$src_sha" = "$copied_sha" ] || { say "ERROR staged swap SHA mismatch"; return 28; }
        else
            say "Creating ${mb} MB swapfile on UDISK"
            run_with_size_progress "CREATING ${mb} MB SWAP FILE" "$incoming" "$source_size" 5 70 \
                dd if=/dev/zero of="$incoming" bs=1M count="$mb" conv=fsync || { say "ERROR swapfile write failed"; return 28; }
        fi
        progress "PREPARING SWAP FILE" 78 "mkswap"
        chmod 600 "$incoming" || { say "ERROR swapfile chmod failed"; return 29; }
        mkswap "$incoming" >/dev/null 2>&1 || { say "ERROR mkswap failed"; return 30; }
        progress "PUBLISHING SWAP FILE" 85 "$SWAP"
        mv -f "$incoming" "$SWAP" || { say "ERROR swapfile publish failed"; return 31; }
        CLEANUP_FILE=""
        progress "FLUSHING TO UDISK" -1 "sync"
        sync
    fi
    progress "ACTIVATING SWAP" 92 "$SWAP"
    activate_swap || return
    progress "SWAP READY" 100 "$SWAP"
}

install_navmesh() {
    progress "CHECKING UDISK" 0 "$NAVDB"
    [ -d /mnt/UDISK ] || { say "ERROR UDISK is not mounted"; return 40; }
    local source size free need incoming src_sha dst_sha
    progress "LOCATING BASE NAVMESH" 2 "$ROOT/defaults/base-navmesh.db"
    source="$(run_python default-path)" || return 41
    [ -s "$source" ] || { say "ERROR selected base navmesh is missing"; return 42; }
    [ "$source" != "$NAVDB" ] || { say "ERROR source and canonical navmesh are the same file"; return 43; }
    size="$(stat -c %s "$source" 2>/dev/null || true)"
    free="$(df -B1 /mnt/UDISK 2>/dev/null | awk 'NR==2 {print $4}')"
    case "$size" in ''|*[!0-9]*) say "ERROR invalid base navmesh size"; return 44;; esac
    case "$free" in ''|*[!0-9]*) free=0;; esac
    need=$((size + 67108864))
    [ "$free" -ge "$need" ] || { say "ERROR UDISK lacks space for verified navmesh staging"; return 45; }
    mkdir -p "$NAVDIR" || { say "ERROR cannot create $NAVDIR"; return 46; }
    incoming="$NAVDB.incoming.$$"
    CLEANUP_FILE="$incoming"
    say "Installing verified base-game navmesh"
    run_with_size_progress "COPYING NAVMESH TO UDISK" "$incoming" "$size" 4 62 \
        cp -p "$source" "$incoming" || { say "ERROR navmesh copy failed"; return 47; }
    progress "VERIFYING SOURCE CHECKSUM" -1 "$(human_bytes "$size")"
    src_sha="$(sha256sum "$source" | awk '{print $1}')"
    progress "VERIFYING COPIED CHECKSUM" -1 "$(human_bytes "$size")"
    dst_sha="$(sha256sum "$incoming" | awk '{print $1}')"
    [ -n "$src_sha" ] && [ "$src_sha" = "$dst_sha" ] || { say "ERROR staged navmesh SHA mismatch"; return 48; }
    if command -v sqlite3 >/dev/null 2>&1; then
        progress "SQLITE INTEGRITY CHECK" -1 "PRAGMA integrity_check"
        [ "$(sqlite3 "$incoming" 'PRAGMA integrity_check;' 2>/dev/null)" = ok ] \
            || { say "ERROR staged navmesh failed SQLite integrity_check"; return 48; }
    fi
    # One canonical database only. Intentionally no automatic DB backup.
    progress "PUBLISHING DATABASE" 92 "$NAVDB"
    mv -f "$incoming" "$NAVDB" || { say "ERROR navmesh publish failed"; return 49; }
    CLEANUP_FILE=""
    progress "FLUSHING TO UDISK" -1 "sync"
    sync
    progress "RECORDING NAVMESH PROFILE" 97 ""
    run_python mark-default || return 50
    progress "NAVMESH INSTALLED" 100 "$NAVDB"
    say "Base navmesh installed and verified: $src_sha"
}

# TSP_MANAGER_V24_FIRST_LAUNCH
# Storage only. No openmw.cfg write, no mod validation, no mod re-ordering.
setup_first_launch() {
    STEPS=3
    STEP=1
    install_navmesh || {
        STEP=0; STEPS=0
        say "ERROR setup stopped at the navmesh step; swap and configuration unchanged: $(last_reason)"
        return 61
    }
    STEP=2
    install_swap || {
        STEP=0; STEPS=0
        say "ERROR navmesh installed but setup stopped at the swap step: $(last_reason)"
        return 62
    }
    STEP=3
    progress "RECORDING NAVMESH PROFILE" 20 "current enabled data order"
    run_python mark-navmesh || {
        STEP=0; STEPS=0
        say "ERROR navmesh and swap installed but the navmesh profile could not be recorded: $(last_reason)"
        return 63
    }
    progress "REFRESHING DEVICE STATUS" 70 ""
    run_python status || {
        STEP=0; STEPS=0
        say "ERROR navmesh and swap installed but the final status refresh failed"
        return 64
    }
    progress "FIRST LAUNCH SETUP COMPLETE" 100 ""
    STEP=0
    STEPS=0
    say "First-launch setup complete: base navmesh installed, UDISK swap active, mod order untouched"
}

run_selftest() {
    local work src dst rc phase pct total
    work="$ROOT/selftest"
    mkdir -p "$work" || return 91

    [ "$(human_bytes 1048576)" = "1 MB" ] || { echo "FAIL human_bytes MB"; return 92; }
    [ "$(human_bytes 0)" = "0 B" ] || { echo "FAIL human_bytes zero"; return 92; }

    STEP=2
    STEPS=3
    progress "PHASE TEST" 55 "detail text"
    [ -s "$PROGRESS_FILE" ] || { echo "FAIL progress file was not published"; return 93; }
    [ ! -e "$PROGRESS_FILE.tmp" ] || { echo "FAIL progress temp file was left behind"; return 93; }
    grep -Fqx 'phase=PHASE TEST' "$PROGRESS_FILE" || { echo "FAIL progress phase"; return 93; }
    grep -Fqx 'pct=55' "$PROGRESS_FILE" || { echo "FAIL progress pct"; return 93; }
    grep -Fqx 'step=2' "$PROGRESS_FILE" || { echo "FAIL progress step"; return 93; }
    grep -Fqx 'steps=3' "$PROGRESS_FILE" || { echo "FAIL progress steps"; return 93; }
    STEP=0
    STEPS=0

    src="$work/source.bin"
    dst="$work/target.bin"
    dd if=/dev/zero of="$src" bs=1024 count=3072 >/dev/null 2>&1 || { echo "FAIL fixture create"; return 94; }
    total="$(stat -c %s "$src")"
    run_with_size_progress "COPY TEST" "$dst" "$total" 10 90 cp -p "$src" "$dst" || { echo "FAIL copy progress rc"; return 94; }
    [ "$(sha256sum "$src" | awk '{print $1}')" = "$(sha256sum "$dst" | awk '{print $1}')" ] \
        || { echo "FAIL copied bytes differ"; return 94; }
    grep -Fqx 'pct=90' "$PROGRESS_FILE" || { echo "FAIL copy progress did not finish at its end percent"; return 94; }

    run_with_size_progress "SLOW TEST" "$work/never" 4096 10 90 \
        bash -c 'sleep 1; exit 5'
    rc=$?
    [ "$rc" -eq 5 ] || { echo "FAIL nonzero child status not propagated: $rc"; return 95; }
    phase="$(sed -n 's/^phase=//p' "$PROGRESS_FILE" | tail -n 1)"
    [ "$phase" = "SLOW TEST" ] || { echo "FAIL live polling did not publish during the child run: $phase"; return 95; }
    pct="$(sed -n 's/^pct=//p' "$PROGRESS_FILE" | tail -n 1)"
    [ "$pct" != "90" ] || { echo "FAIL failed command was reported complete"; return 95; }

    run_with_size_progress "UNMEASURED TEST" "$work/never" 0 10 90 true || { echo "FAIL indeterminate rc"; return 96; }
    printf '%s\n' "OPENMW_MANAGER_V24_ACTION_SELFTEST_PASS"
    rm -rf "$ROOT"
    return 0
}

if [ "$SELFTEST" -eq 1 ]; then
    run_selftest
    exit $?
fi

echo "============================================================"
echo "Manager V2.4 action: $ACTION"
echo "Started: $(date)"
echo "============================================================"

case "$ACTION" in
    status) run_python status ;;
    mods-scan) run_python scan ;;
    mods-apply) run_python apply ;;
    mod-toggle) [ "$#" -eq 2 ] || { say "ERROR toggle needs an id"; exit 2; }; run_python toggle "$2" ;;
    mod-move) [ "$#" -eq 3 ] || { say "ERROR move needs id and delta"; exit 2; }; run_python move "$2" "$3" ;;
    setup-first-launch) setup_first_launch ;;
    install-navmesh) install_navmesh ;;
    install-swap) install_swap ;;
    activate-swap) activate_swap ;;
    mark-navmesh) run_python mark-navmesh ;;
    diagnostics)
        run_python status
        echo "--- mounts ---"; grep -E ' /mnt/(UDISK|SDCARD) ' /proc/mounts || true
        echo "--- swap ---"; cat /proc/swaps 2>/dev/null || true
        echo "--- navmesh ---"; ls -lh "$NAVDB" 2>/dev/null || true
        echo "--- candidates ---"; cat "$ROOT/launcher/default-navmesh-candidates.txt" 2>/dev/null || true
        ;;
    *) say "ERROR unknown manager action: $ACTION"; exit 2 ;;
esac
