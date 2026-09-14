#!/bin/bash
# Runtime action backend for OpenMW 0.51 TSP Manager V2.
set -u -o pipefail

ROOT="${OPENMW51_GAMEDIR:-/mnt/SDCARD/data/ports/openmw51}"
PY="$ROOT/launcher/openmw51-launcher-backend-v2.py"
LOG="$ROOT/launcher/manager-v2.log"
RESULT="$ROOT/launcher/last-result.txt"
NAVDIR="${OPENMW51_NAVMESH_DIR:-/mnt/UDISK/openmw51-nav}"
NAVDB="$NAVDIR/navmesh.db"
SWAP=/mnt/UDISK/openmw51-swapfile
ACTION="${1:-status}"
CLEANUP_FILE=""

mkdir -p "$ROOT/launcher"
exec >>"$LOG" 2>&1

cleanup_temp() {
    if [ -n "$CLEANUP_FILE" ] && [ -f "$CLEANUP_FILE" ]; then
        rm -f "$CLEANUP_FILE"
    fi
}
trap cleanup_temp EXIT INT TERM

say() {
    printf '%s\n' "$*"
    printf '%s\n' "$*" > "$RESULT"
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
        local free need incoming
        free="$(df -k /mnt/UDISK 2>/dev/null | awk 'NR==2 {print $4}')"
        case "$free" in ''|*[!0-9]*) free=0;; esac
        need=$((mb * 1024 * 2))
        [ "$free" -ge "$need" ] || { say "ERROR UDISK needs ${need} KB free for safe swap creation"; return 27; }
        incoming="$SWAP.incoming.$$"
        CLEANUP_FILE="$incoming"
        say "Creating ${mb} MB swapfile on UDISK"
        dd if=/dev/zero of="$incoming" bs=1M count="$mb" conv=fsync 2>>"$LOG" || { say "ERROR swapfile write failed"; return 28; }
        chmod 600 "$incoming" || { say "ERROR swapfile chmod failed"; return 29; }
        mkswap "$incoming" >/dev/null 2>&1 || { say "ERROR mkswap failed"; return 30; }
        mv -f "$incoming" "$SWAP" || { say "ERROR swapfile publish failed"; return 31; }
        CLEANUP_FILE=""
        sync
    fi
    activate_swap
}

install_navmesh() {
    [ -d /mnt/UDISK ] || { say "ERROR UDISK is not mounted"; return 40; }
    local source size free need incoming src_sha dst_sha
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
    cp -p "$source" "$incoming" || { say "ERROR navmesh copy failed"; return 47; }
    src_sha="$(sha256sum "$source" | awk '{print $1}')"
    dst_sha="$(sha256sum "$incoming" | awk '{print $1}')"
    [ -n "$src_sha" ] && [ "$src_sha" = "$dst_sha" ] || { say "ERROR staged navmesh SHA mismatch"; return 48; }
    if command -v sqlite3 >/dev/null 2>&1; then
        [ "$(sqlite3 "$incoming" 'PRAGMA integrity_check;' 2>/dev/null)" = ok ] \
            || { say "ERROR staged navmesh failed SQLite integrity_check"; return 48; }
    fi
    # One canonical database only. Intentionally no automatic DB backup.
    mv -f "$incoming" "$NAVDB" || { say "ERROR navmesh publish failed"; return 49; }
    CLEANUP_FILE=""
    sync
    run_python mark-default || return 50
    say "Base navmesh installed and verified: $src_sha"
}

echo "============================================================"
echo "Manager V2 action: $ACTION"
echo "Started: $(date)"
echo "============================================================"

case "$ACTION" in
    status) run_python status ;;
    mods-scan) run_python scan ;;
    mods-apply) run_python apply ;;
    mod-toggle) [ "$#" -eq 2 ] || { say "ERROR toggle needs an id"; exit 2; }; run_python toggle "$2" ;;
    mod-move) [ "$#" -eq 3 ] || { say "ERROR move needs id and delta"; exit 2; }; run_python move "$2" "$3" ;;
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
