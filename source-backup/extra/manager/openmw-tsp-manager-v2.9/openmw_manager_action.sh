#!/bin/bash
# Runtime action backend for OpenMW 0.51 TSP Manager V2.5.
# TSP_MANAGER_V24_PROGRESS_BACKEND
#
# V2.4 changes:
#   - every long operation publishes live progress to $PROGRESS_FILE so the
#     manager UI can draw a progress bar instead of leaving a black screen;
#   - SETUP GAME FOR FIRST LAUNCH is storage only: base navmesh + swap.
#     Mod data roots and load order come from openmw.cfg and are never
#     rewritten by first-launch setup.
#
# V2.5 changes:
#   - the navmesh build runs the standalone generator headless (NAVMESH_UI=0)
#     and this backend draws the progress from the generator log, so the whole
#     build is visible in the manager instead of handing over to a screen that
#     stays black through the generator's own preflight, identity probe and
#     database backup;
#   - a startup action activates the UDISK swapfile before the first scan.
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
GENLOG="$ROOT/navmesh-generation-full-3worker.log"
TEXCONV_LOG="$ROOT/tsp-texconv.log"
TEXCONV_DATA="$ROOT/data/Data Files"
TEXCONV_TOOL="$ROOT/tools/tsp_texconv"
TEXCONV_MARK="$TEXCONV_DATA/tsp_texconv.done"
TEXCONV_TIERS="8x8+6x6"
LAUNCH_ENV="$ROOT/launcher/.launch-env"
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
    # Optional second track: overall stays on bar one, the current unit of work
    # goes on bar two. Empty phase2 means the UI draws a single bar.
    local phase2="${4:-}" pct2="${5:--1}" detail2="${6:-}"
    {
        printf 'phase=%s\npct=%s\ndetail=%s\nstep=%s\nsteps=%s\nphase2=%s\npct2=%s\ndetail2=%s\n' \
            "$phase" "$pct" "$detail" "$STEP" "$STEPS" "$phase2" "$pct2" "$detail2" \
            > "$PROGRESS_FILE.tmp" 2>/dev/null &&
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

# ---------------------------------------------------------------------------
# TSP_MANAGER_V25_NAVMESH_PROGRESS
# Turn the tail of the generator log into one "pct|phase|detail" line. Only the
# tail is read, so the cost stays flat as the log grows.
# ---------------------------------------------------------------------------
navmesh_progress_snapshot() {
    tail -n 200 "${1:-/dev/null}" 2>/dev/null | awk '
        function counter(line,   i, value) {
            for (i = 1; i <= NF; i++)
                if ($i ~ /^\([0-9]+\/[0-9]+\)$/)
                    value = substr($i, 2, length($i) - 2)
            return value
        }
        /Processed .* cell \(/          { cells = counter($0) }
        /Processed worldspace \(/       { worlds = counter($0) }
        /navmesh tiles are generated/ {
            for (i = 1; i <= NF; i++)
                if ($i ~ /^[0-9]+\/[0-9]+$/)
                    tiles = $i
        }
        /Generating navmesh tiles for "/ {
            unit = $0
            sub(/.*Generating navmesh tiles for "/, "", unit)
            sub(/".*/, "", unit)
        }
        /cells from worldspace "/ {
            unit = $0
            sub(/.*cells from worldspace "/, "", unit)
            sub(/".*/, "", unit)
        }
        /^===== [0-9]\/7 / {
            header = $0
            sub(/^===== [0-9]\/7 /, "", header)
            sub(/ =====$/, "", header)
        }
        /^NAVMESHTOOL EXIT CODE/ { finishing = 1 }
        /^===== 6\/7/           { finishing = 1 }
        END {
            pct = -1; phase = "WORKING"; detail = ""
            pct2 = -1; phase2 = ""; detail2 = ""
            if (header != "") phase = header

            # Overall: exterior cells first, then one step per worldspace.
            if (cells != "") {
                split(cells, c, "/")
                if (c[2] > 0) pct = 8 + int(27 * c[1] / c[2])
                phase = "GENERATING NAVMESH"
                detail = c[1] " / " c[2] " exterior cells"
            }
            if (worlds != "") {
                split(worlds, w, "/")
                if (w[2] > 0) pct = 35 + int(57 * w[1] / w[2])
                phase = "GENERATING NAVMESH"
                detail = w[1] " / " w[2] " worldspaces"
            }

            # Current unit of work: the per-worldspace tile counter, which
            # restarts at every worldspace and must not drive the overall bar.
            if (tiles != "") {
                split(tiles, t, "/")
                if (t[2] > 0) pct2 = int(100 * t[1] / t[2])
                phase2 = (unit != "" ? unit : "CURRENT WORLDSPACE")
                detail2 = t[1] " / " t[2] " tiles"
            } else if (cells != "" && worlds == "") {
                split(cells, c, "/")
                if (c[2] > 0) pct2 = int(100 * c[1] / c[2])
                phase2 = "EXTERIOR CELLS"
                detail2 = c[1] " / " c[2] " cells"
            }

            if (finishing) {
                pct = 95
                phase = "VALIDATING DATABASE"
                pct2 = -1; phase2 = ""; detail2 = ""
            }
            printf "%d|%s|%s|%d|%s|%s\n", pct, phase, detail, pct2, phase2, detail2
        }'
}

# Run the standalone generator headless, with the environment this Ports entry
# was launched with, so it behaves exactly as it does from the Ports menu apart
# from its own progress window being off.
run_generator_headless() {
    local generator="$1"
    if [ -s "$LAUNCH_ENV" ]; then
        env -i /bin/bash -c '
            if [ -f "$1" ]; then . "$1" >/dev/null 2>&1 || true; fi
            shift
            NAVMESH_UI=0
            OPENMW_GAMEDIR="$1"
            OPENMW_NAVMESH_DIR="$2"
            export NAVMESH_UI OPENMW_GAMEDIR OPENMW_NAVMESH_DIR
            shift 2
            exec /bin/bash "$@"
        ' _ "$LAUNCH_ENV" "$ROOT" "$NAVDIR" "$generator"
    else
        NAVMESH_UI=0 OPENMW_GAMEDIR="$ROOT" OPENMW_NAVMESH_DIR="$NAVDIR" /bin/bash "$generator"
    fi
}

build_navmesh() {
    local generator="" candidate done_file rc snapshot phase detail pct phase2 detail2 pct2 reason
    # V2.9: the generator ships inside the game build. The Ports copies remain
    # only as a fallback for an install that still has the standalone entry.
    for candidate in \
        "$ROOT/tools/OpenMW_Generate_Full_Navmesh_3Worker.sh" \
        /mnt/SDCARD/Roms/PORTS/OpenMW_Generate_Full_Navmesh_3Worker.sh \
        /mnt/sdcard/mmcblk1p1/Roms/PORTS/OpenMW_Generate_Full_Navmesh_3Worker.sh
    do
        if [ -f "$candidate" ]; then generator="$candidate"; break; fi
    done
    if [ -z "$generator" ]; then
        say "ERROR the three-worker navmesh generator was not found in $ROOT/tools or the PORTS folder"
        return 70
    fi

    say "Starting navmesh generation: $generator"
    progress "STARTING NAVMESH GENERATOR" 0 "3 workers, exteriors and interiors"
    : > "$GENLOG" 2>/dev/null || true

    done_file="$PROGRESS_FILE.gen.$$"
    rm -f "$done_file"
    ( run_generator_headless "$generator"; printf '%s\n' "$?" > "$done_file" ) &

    while [ ! -s "$done_file" ]; do
        snapshot="$(navmesh_progress_snapshot "$GENLOG")"
        IFS='|' read -r pct phase detail pct2 phase2 detail2 <<SNAPSHOT_EOF
$snapshot
SNAPSHOT_EOF
        case "$pct" in ''|*[!0-9-]*) pct=-1 ;; esac
        case "$pct2" in ''|*[!0-9-]*) pct2=-1 ;; esac
        progress "${phase:-WORKING}" "$pct" "$detail" "$phase2" "$pct2" "$detail2"
        sleep "$SLEEP_TICK"
    done

    read -r rc < "$done_file"
    rm -f "$done_file"
    wait 2>/dev/null || true
    case "$rc" in ''|*[!0-9]*) rc=1 ;; esac

    if [ "$rc" -ne 0 ]; then
        reason="$(grep -E '^(ERROR|WARNING)' "$GENLOG" 2>/dev/null | tail -n 1)"
        progress "NAVMESH BUILD FAILED" 100 ""
        say "ERROR navmesh generator exited $rc; existing database kept. ${reason:-See navmesh-generation-full-3worker.log}"
        return "$rc"
    fi

    progress "RECORDING NAVMESH PROFILE" 97 ""
    run_python mark-navmesh || {
        say "ERROR navmesh built but the profile could not be recorded: $(last_reason)"
        return 71
    }
    progress "NAVMESH BUILD COMPLETE" 100 "$NAVDB"
    say "Navmesh build finished and the profile was recorded for the current data order"
}

# Swap is not persistent across a reboot or a force quit. Activating it before
# the first scan keeps the manager and the generator off the page-cache cliff.
startup() {
    progress "ACTIVATING SWAP" 4 "$SWAP"
    activate_swap || true
    progress "SCANNING DEVICE" 10 "mods, navmesh, swap"
    run_python status
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

# ---------------------------------------------------------------------------
# TSP_MANAGER_V30_TEXCONV
# One-time conversion of the game's DDS textures to ASTC .ktx, which gl4es
# uploads without a CPU decompress. Measured +87 MB MemAvailable and -62 MB RSS.
# The tool writes new filenames beside the originals, so no config is touched
# and the whole thing is undone by deleting the .ktx files.
# ---------------------------------------------------------------------------

# The archives the conversion was made from. A changed game install must read as
# stale rather than silently keeping textures that no longer match it.
texconv_fingerprint() {
    local f out=""
    for f in Morrowind.bsa Tribunal.bsa Bloodmoon.bsa; do
        if [ -f "$TEXCONV_DATA/$f" ]; then
            out="$out$f:$(stat -c %s "$TEXCONV_DATA/$f" 2>/dev/null || printf '0') "
        fi
    done
    printf '%s' "$out"
}

texconv_count() {
    find "$TEXCONV_DATA/textures" -name '*.ktx' 2>/dev/null | wc -l | tr -d ' '
}

# Turn the tail of the converter log into one "pct|phase|detail|pct2|phase2|detail2"
# line, the same shape build_navmesh uses. Only the tail is read.
texconv_progress_snapshot() {
    tail -n 40 "${1:-/dev/null}" 2>/dev/null | awk '
        /^TSP_TEXCONV_V1 start/ {
            for (i = 1; i <= NF; i++) if ($i ~ /^total=/) total = substr($i, 7)
        }
        /^TSP_TEXCONV_V1 progress/ {
            for (i = 1; i <= NF; i++) {
                if ($i ~ /^done=/)  done  = substr($i, 6)
                if ($i ~ /^total=/) total = substr($i, 7)
                if ($i ~ /^ok=/)    ok    = substr($i, 4)
                if ($i ~ /^fail=/)  fail  = substr($i, 6)
                if ($i ~ /^pct=/)   pct   = substr($i, 5)
                if ($i ~ /^rate=/)  rate  = substr($i, 6)
                if ($i ~ /^eta=/)   eta   = substr($i, 5)
            }
        }
        /^TSP_TEXCONV_V1 done/ { finished = 1 }
        END {
            p = -1; phase = "CONVERTING TEXTURES"; detail = ""
            if (pct != "") p = pct + 0
            if (done != "" && total != "") detail = done " / " total
            if (ok != "") detail = detail "  OK " ok
            if (fail != "" && fail + 0 > 0) detail = detail "  FAIL " fail
            if (rate != "") detail = detail "  " rate "/S"
            if (eta != "" && eta + 0 > 0) detail = detail "  ETA " int((eta + 59) / 60) " MIN"
            if (finished) { p = 100; phase = "TEXTURE CONVERSION COMPLETE" }
            printf "%d|%s|%s|-1||\n", p, phase, detail
        }'
}

# One pass of the converter over a size band. The tool skips any .ktx that already
# exists, so a pass is resumable and a second run over a done band costs seconds.
#
# Each pass writes its own log and only that log is parsed for progress. Sharing one
# log would leave the previous band's "done" line inside the parser's tail window,
# which pins the bar at 100% for most of the next band. The pass log is folded into
# the main log when the pass ends, so completion accounting still sees both bands.
texconv_run_pass() {
    local label="$1" tmin="$2" tmax="$3" block="$4"
    local done_file passlog rc snapshot pct phase detail pct2 phase2 detail2 f
    done_file="$PROGRESS_FILE.tex.$$"
    passlog="$TEXCONV_LOG.pass"
    rm -f "$done_file"
    : > "$passlog" 2>/dev/null || true
    progress "$label" 0 "reading the game archives"
    (
        trap - ERR
        set +e
        # Build the archive arguments by appending to the positional parameters. The
        # paths contain a space ("Data Files"), so they must never go through word
        # splitting; an earlier version packed them into one string and split on "|",
        # which produced a leading-space " --bsa" and made the tool exit 2 on every
        # run before converting anything.
        set --
        for f in Morrowind.bsa Tribunal.bsa Bloodmoon.bsa; do
            [ -f "$TEXCONV_DATA/$f" ] && set -- "$@" --bsa "$TEXCONV_DATA/$f"
        done
        rc=0
        "$TEXCONV_TOOL" "$@" --out "$TEXCONV_DATA" --threads 4 --report-every 25 \
            --min-size "$tmin" --max-size "$tmax" --block "$block" >> "$passlog" 2>&1 || rc=$?
        printf '%s\n' "$rc" > "$done_file"
    ) &
    while [ ! -s "$done_file" ]; do
        snapshot="$(texconv_progress_snapshot "$passlog")"
        IFS='|' read -r pct phase detail pct2 phase2 detail2 <<TEXCONV_EOF
$snapshot
TEXCONV_EOF
        case "$pct" in ''|*[!0-9-]*) pct=-1 ;; esac
        progress "${label}" "$pct" "$detail" "" -1 ""
        sleep "$SLEEP_TICK"
    done
    read -r rc < "$done_file"
    rm -f "$done_file"
    wait 2>/dev/null || true
    cat "$passlog" >> "$TEXCONV_LOG" 2>/dev/null || true
    rm -f "$passlog"
    case "$rc" in ''|*[!0-9]*) rc=1 ;; esac
    return "$rc"
}

convert_textures() {
    local rc1 rc2 before after fp failed reason
    [ -f "$TEXCONV_TOOL" ] || { say "ERROR the texture converter is missing: $TEXCONV_TOOL"; return 80; }
    [ -d "$TEXCONV_DATA" ] || { say "ERROR the game data folder was not found: $TEXCONV_DATA"; return 81; }

    fp="$(texconv_fingerprint)"
    [ -n "$fp" ] || { say "ERROR no game archives found in $TEXCONV_DATA"; return 82; }
    before="$(texconv_count)"

    # Both bands done for this game data: nothing to do. A marker without the tiers
    # line was written before the small-texture band existed, so it does not count.
    if [ -f "$TEXCONV_MARK" ] \
       && grep -Fqx "fingerprint=$fp" "$TEXCONV_MARK" 2>/dev/null \
       && grep -Fqx "tiers=$TEXCONV_TIERS" "$TEXCONV_MARK" 2>/dev/null; then
        progress "TEXTURES ALREADY CONVERTED" 100 "$before files"
        say "Textures are already converted for this game data ($before files); nothing to do"
        return 0
    fi

    say "Converting textures to ASTC. Two size bands, resumable, about an hour from scratch."
    : > "$TEXCONV_LOG" 2>/dev/null || true

    # Band 1: 128 px and larger at 8x8 (2 bpp). This is where the memory is.
    STEPS=2
    STEP=1
    texconv_run_pass "CONVERTING LARGE TEXTURES" 128 0 8x8
    rc1=$?

    # Band 2: everything smaller at 6x6 (~3.6-4.8 bpp), which is about what their DXT1
    # source already costs, so no meaningful quality change and no CPU decompress.
    STEP=2
    texconv_run_pass "CONVERTING SMALL TEXTURES" 0 127 6x6
    rc2=$?

    STEP=0
    STEPS=0
    after="$(texconv_count)"

    # Completed work: the tool returns 1 when individual textures failed but the run
    # finished. Only a band with no completion line is genuinely incomplete, and
    # re-running resumes because existing .ktx files are skipped.
    if [ "$(grep -c '^TSP_TEXCONV_V1 done' "$TEXCONV_LOG" 2>/dev/null || printf '0')" -ge 2 ]; then
        failed="$(sed -n 's/^TSP_TEXCONV_V1 done .*fail=\([0-9]*\).*/\1/p' "$TEXCONV_LOG" \
            | awk '{t+=$1} END {print t+0}')"
        case "$failed" in ''|*[!0-9]*) failed=0 ;; esac
        # The converter rewrites this marker per pass, so its own converted= counts only
        # the last band, and counts nothing at all on a resumed pass that skipped
        # everything. The home page reads converted=, so state the real number of .ktx
        # files on disk instead.
        grep -v -e '^tiers=' -e '^converted=' -e '^fingerprint=' "$TEXCONV_MARK" \
            2>/dev/null > "$TEXCONV_MARK.tmp" || true
        printf 'converted=%s\nfingerprint=%s\ntiers=%s\n' \
            "$after" "$fp" "$TEXCONV_TIERS" >> "$TEXCONV_MARK.tmp"
        mv -f "$TEXCONV_MARK.tmp" "$TEXCONV_MARK" 2>/dev/null || true
        progress "TEXTURE CONVERSION COMPLETE" 100 "$after files"
        if [ "$failed" -gt 0 ]; then
            say "Texture conversion finished: $after textures converted, $failed could not be read and were left as they were"
        else
            say "Texture conversion finished: $after textures converted"
        fi
        return 0
    fi

    # Surface the converter's own reason. Exit 2 is always an argument or archive
    # problem and it says which on its first line, so quote it rather than making
    # the next person pull the log.
    reason="$(grep -m1 '^TSP_TEXCONV_V1 fatal' "$TEXCONV_LOG" 2>/dev/null \
        | sed 's/^TSP_TEXCONV_V1 fatal //')"
    progress "TEXTURE CONVERSION STOPPED" 100 "$after files done"
    if [ -n "$reason" ]; then
        say "ERROR texture conversion stopped early (large band $rc1, small band $rc2) after $after textures: $reason"
    else
        say "ERROR texture conversion stopped early (large band $rc1, small band $rc2) after $after textures; run it again to carry on from there"
    fi
    return 1
}

run_selftest() {
    local work src dst rc phase pct total pct2 phase2 detail detail2
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

    # --- navmesh log -> progress parser ------------------------------------
    local genlog="$work/gen.log" snap
    printf '%s\n' \
        '===== 1/7 PREFLIGHT =====' \
        'PASS: isolated current-runtime navmeshtool is present.' > "$genlog"
    snap="$(navmesh_progress_snapshot "$genlog")"
    [ "$snap" = "-1|PREFLIGHT||-1||" ] || { echo "FAIL header phase: $snap"; return 97; }

    printf '%s\n' '[22:05:40.035 I] Processed exterior cell (1240/1559) West Gash Region (-9, 9) with 131 objects' >> "$genlog"
    snap="$(navmesh_progress_snapshot "$genlog")"
    [ "$snap" = "29|GENERATING NAVMESH|1240 / 1559 exterior cells|79|EXTERIOR CELLS|1240 / 1559 cells" ] \
        || { echo "FAIL cell progress: $snap"; return 97; }

    # A per-worldspace tile counter must move the second bar only.
    printf '%s\n' \
        '[22:49:14.318 I] Generating navmesh tiles for "Yakin" worldspace...' \
        '[22:49:14.370 I] 51/102 (50%) navmesh tiles are generated' \
        '[22:49:14.370 I] Processed worldspace (664/1329) "Yakin"' >> "$genlog"
    snap="$(navmesh_progress_snapshot "$genlog")"
    [ "$snap" = "63|GENERATING NAVMESH|664 / 1329 worldspaces|50|Yakin|51 / 102 tiles" ] \
        || { echo "FAIL two-track progress: $snap"; return 97; }

    printf '%s\n' '===== 6/7 VALIDATE DATABASE =====' >> "$genlog"
    snap="$(navmesh_progress_snapshot "$genlog")"
    [ "$snap" = "95|VALIDATING DATABASE|664 / 1329 worldspaces|-1||" ] \
        || { echo "FAIL validate phase: $snap"; return 97; }

    snap="$(navmesh_progress_snapshot "$work/no-such-log")"
    [ "$snap" = "-1|WORKING||-1||" ] || { echo "FAIL empty log: $snap"; return 97; }

    # The two-track fields must survive the read that the build loop uses.
    IFS='|' read -r pct phase detail pct2 phase2 detail2 <<PARSE_EOF
63|GENERATING NAVMESH|664 / 1329 worldspaces|50|Yakin|51 / 102 tiles
PARSE_EOF
    [ "$pct" = "63" ] && [ "$phase" = "GENERATING NAVMESH" ] && [ "$detail" = "664 / 1329 worldspaces" ] \
        && [ "$pct2" = "50" ] && [ "$phase2" = "Yakin" ] && [ "$detail2" = "51 / 102 tiles" ] \
        || { echo "FAIL snapshot field split"; return 97; }
    progress "OVERALL" 63 "664 / 1329 worldspaces" "Yakin" 50 "51 / 102 tiles"
    grep -Fqx 'phase2=Yakin' "$PROGRESS_FILE" || { echo "FAIL second track not published"; return 97; }
    grep -Fqx 'pct2=50' "$PROGRESS_FILE" || { echo "FAIL second track percent"; return 97; }

    # --- texture converter log -> progress parser ---------------------------
    local texlog="$work/tex.log" tsnap
    printf '%s\n' 'TSP_TEXCONV_V1 archive Morrowind.bsa entries=11090 eligible=3694' > "$texlog"
    tsnap="$(texconv_progress_snapshot "$texlog")"
    [ "$tsnap" = "-1|CONVERTING TEXTURES||-1||" ] || { echo "FAIL texconv idle: $tsnap"; return 98; }

    printf '%s\n' 'TSP_TEXCONV_V1 start total=4555 unique=4555 threads=4 block=8x8 quality=medium out=/x' >> "$texlog"
    printf '%s\n' 'TSP_TEXCONV_V1 progress done=1200 total=4555 ok=1000 small=200 fail=0 pct=26 rate=1.80 eta=1863' >> "$texlog"
    tsnap="$(texconv_progress_snapshot "$texlog")"
    [ "$tsnap" = "26|CONVERTING TEXTURES|1200 / 4555  OK 1000  1.80/S  ETA 32 MIN|-1||" ] \
        || { echo "FAIL texconv progress: $tsnap"; return 98; }

    printf '%s\n' 'TSP_TEXCONV_V1 progress done=2400 total=4555 ok=2000 small=397 fail=3 pct=52 rate=2.00 eta=1077' >> "$texlog"
    tsnap="$(texconv_progress_snapshot "$texlog")"
    [ "$tsnap" = "52|CONVERTING TEXTURES|2400 / 4555  OK 2000  FAIL 3  2.00/S  ETA 18 MIN|-1||" ] \
        || { echo "FAIL texconv failure count: $tsnap"; return 98; }

    printf '%s\n' 'TSP_TEXCONV_V1 done ok=3663 small=892 fail=0 in=145 out=53 secs=2240.0' >> "$texlog"
    tsnap="$(texconv_progress_snapshot "$texlog")"
    case "$tsnap" in
        "100|TEXTURE CONVERSION COMPLETE|"*) : ;;
        *) echo "FAIL texconv completion: $tsnap"; return 98 ;;
    esac

    tsnap="$(texconv_progress_snapshot "$work/no-such-texlog")"
    [ "$tsnap" = "-1|CONVERTING TEXTURES||-1||" ] || { echo "FAIL texconv empty log: $tsnap"; return 98; }

    # The parser output must survive the same field split the run loop uses.
    IFS='|' read -r pct phase detail pct2 phase2 detail2 <<TEXPARSE_EOF
26|CONVERTING TEXTURES|1200 / 4555 textures   converted 1000|-1||
TEXPARSE_EOF
    [ "$pct" = "26" ] && [ "$phase" = "CONVERTING TEXTURES" ] && [ "$pct2" = "-1" ] \
        || { echo "FAIL texconv field split"; return 98; }

    # A missing tool must fail cleanly, not run anything.
    TEXCONV_TOOL="$work/absent-tool" TEXCONV_DATA="$work" convert_textures >/dev/null 2>&1
    rc=$?
    [ "$rc" -eq 80 ] || { echo "FAIL missing converter not reported: $rc"; return 98; }

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
    convert-textures) convert_textures ;;
    build-navmesh) build_navmesh ;;
    startup) startup ;;
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
