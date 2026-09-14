#!/bin/bash
set -Eeuo pipefail

# ============================================================
# OpenMW 0.51 / TrimUI Smart Pro S
# COMPLETE NAVMESH GENERATOR — current-runtime isolated tool
#
# Canonical database:
#   /mnt/UDISK/openmw-nav/navmesh.db
#
# Tool runtime:
#   /mnt/SDCARD/data/ports/openmw/navmesh-tool-runtime
#
# That private runtime contains a navmeshtool + defaults.bin pair
# generated from the SAME current OpenMW source tree. It does not
# replace the game's working bin/defaults.bin.
#
# Existing DB -> cached tiles are reused/updated.
# Missing DB  -> complete exterior + interior DB is generated.
#
# TSP_NAVMESH_GENERATOR_V25
#   NAVMESH_UI=1 (default)  run the bundled SDL progress window, as the Ports
#                           entry has always done.
#   NAVMESH_UI=0            headless: no progress window, no requirement for
#                           bin/openmw-navmesh-progress. The OpenMW Manager
#                           uses this and draws progress from this log itself.
# ============================================================

if [ -z "${BASH_VERSION:-}" ]; then
    exec /bin/bash "$0" "$@"
fi

ROOT="${OPENMW_GAMEDIR:-${OPENMW51_GAMEDIR:-/mnt/SDCARD/data/ports/openmw}}"
RUNTIME="$ROOT/navmesh-tool-runtime"
TOOL="$RUNTIME/openmw-navmeshtool"
LOCAL_CFG="$RUNTIME/openmw.cfg"
DEFAULTS="$RUNTIME/defaults.bin"

PROGRESS="$ROOT/bin/openmw-navmesh-progress"
MAIN_CFG="$ROOT/openmw.cfg"
CFGDIR="$ROOT/config"

NAVDIR="${OPENMW_NAVMESH_DIR:-${OPENMW51_NAVMESH_DIR:-/mnt/UDISK/openmw-nav}}"
DB="$NAVDIR/navmesh.db"
BACKUP_DIR="$NAVDIR/backups"

LOG="$ROOT/navmesh-generation-full-3worker.log"
STATUS="$ROOT/navmesh-generation-full-3worker.status"
STATUS_TMP="$STATUS.tmp"

THREADS="${NAVMESH_THREADS:-3}"
REMOVE_UNUSED="${NAVMESH_REMOVE_UNUSED:-true}"
# One retained backup: UDISK also holds the ~890 MB working database and the
# 512 MB swapfile, so two extra copies could fill the partition mid-build.
KEEP_BACKUPS="${NAVMESH_KEEP_BACKUPS:-1}"
NAVMESH_UI="${NAVMESH_UI:-1}"

mkdir -p "$RUNTIME" "$NAVDIR" "$BACKUP_DIR"
rm -f "$STATUS" "$STATUS_TMP"
: > "$LOG"

fail() {
    rc=$?
    line="${1:-?}"
    cmd="${2:-?}"
    trap - ERR

    {
        echo
        echo "============================================================"
        echo "FULL NAVMESH GENERATION STOPPED"
        echo "============================================================"
        echo "Exit code: $rc"
        echo "Line:      $line"
        echo "Command:   $cmd"
        echo "Finished:  $(date)"
        echo
        echo "Log:"
        echo "  $LOG"
        echo
        echo "Database:"
        echo "  $DB"
        echo "============================================================"
    } | tee -a "$LOG"

    if [ -t 0 ]; then
        echo
        printf "Press Enter to exit..."
        read -r _unused || true
    fi

    exit "$rc"
}
trap 'fail "$LINENO" "$BASH_COMMAND"' ERR

exec > >(tee -a "$LOG") 2>&1

echo "============================================================"
echo "OpenMW 0.51 FULL Navmesh Generator"
echo "Current-runtime isolated navmeshtool"
echo "============================================================"
echo "Started:        $(date)"
echo "Tool runtime:   $RUNTIME"
echo "Database:       $DB"
echo "Workers:        $THREADS"
echo "Interiors:      true"
echo "Remove unused:  $REMOVE_UNUSED"
echo "Kept backups:   $KEEP_BACKUPS"
echo "Progress window: $NAVMESH_UI"
echo "============================================================"
echo

echo "===== 1/7 PREFLIGHT ====="

if pidof openmw-0.51 >/dev/null 2>&1 || pidof openmw >/dev/null 2>&1; then
    echo "ERROR: close Morrowind before generating navmesh tiles."
    exit 20
fi

for f in \
    "$TOOL" \
    "$DEFAULTS" \
    "$MAIN_CFG" \
    "$CFGDIR/openmw.cfg"
do
    if [ ! -e "$f" ]; then
        echo "ERROR: required navmesh runtime file is missing:"
        echo "  $f"
        exit 21
    fi
done

if [ ! -x "$TOOL" ]; then
    echo "ERROR: required helper is not executable:"
    echo "  $TOOL"
    exit 22
fi

if [ "$NAVMESH_UI" = "1" ]; then
    if [ ! -e "$PROGRESS" ]; then
        echo "ERROR: the progress window helper is missing:"
        echo "  $PROGRESS"
        echo "Run with NAVMESH_UI=0 to generate without it."
        exit 21
    fi
    if [ ! -x "$PROGRESS" ]; then
        echo "ERROR: the progress window helper is not executable:"
        echo "  $PROGRESS"
        exit 22
    fi
else
    echo "Headless mode: the bundled progress window is not used."
fi

case "$THREADS" in
    ''|*[!0-9]*|0)
        echo "ERROR: NAVMESH_THREADS must be an integer >= 1."
        exit 23
        ;;
esac

case "$REMOVE_UNUSED" in
    true|false) ;;
    *)
        echo "ERROR: NAVMESH_REMOVE_UNUSED must be true or false."
        exit 24
        ;;
esac

# Keep navmeshtool's executable-local config synchronized with the same
# content profile used by the current game launcher.
cp -f "$MAIN_CFG" "$LOCAL_CFG"
test -s "$LOCAL_CFG"

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/runtime-root}"
mkdir -p "$XDG_RUNTIME_DIR"
chmod 0700 "$XDG_RUNTIME_DIR" 2>/dev/null || true

export XDG_CONFIG_HOME="$CFGDIR"
export XDG_DATA_HOME="$CFGDIR"
export OPENMW_RESOURCES="$ROOT/resources"
export OSG_LIBRARY_PATH="$ROOT/osgPlugins-3.6.5"
export LD_LIBRARY_PATH="$ROOT/lib:$ROOT/libs:$ROOT/lib/aarch64:/mnt/SDCARD/System/lib:/usr/trimui/lib:${LD_LIBRARY_PATH:-}"

cd "$RUNTIME"

HELP="$("$TOOL" --help 2>&1 || true)"
printf '%s\n' "$HELP" | grep -q -- '--process-interior-cells' || {
    echo "ERROR: isolated navmeshtool lacks interior generation."
    exit 25
}

echo "PASS: isolated current-runtime navmeshtool is present."

echo
echo "===== 2/7 VERIFY MATCHING DEFAULTS + FULL INITIALIZATION ====="

base64 -d "$DEFAULTS" > /tmp/tsp-navmesh-defaults.cfg

for required_default in \
    "occlusion culling =" \
    "occlusion buffer width =" \
    "occlusion buffer height ="
do
    grep -Fq "$required_default" /tmp/tsp-navmesh-defaults.cfg || {
        echo "ERROR: navmeshtool private defaults.bin lacks:"
        echo "  $required_default"
        rm -f /tmp/tsp-navmesh-defaults.cfg
        exit 26
    }
done
rm -f /tmp/tsp-navmesh-defaults.cfg

# TSP_NAVMESH_BOUNDED_VERSION_CHECK_V25
#
# This build of navmeshtool does not stop after printing its version: given a
# config it goes on to run a COMPLETE generation pass. Measured on device that
# spent about two minutes here — against the canonical database, before any
# progress window exists, and before the real generation had even started.
#
# The identity check now runs against a throwaway user-data directory so it can
# never touch the canonical database, and it stops the moment the version line
# appears.
VERSION_LOG="/tmp/tsp-navmesh-version-check.txt"
VERSION_DIR="$NAVDIR/.version-check.$$"
VERSION_WAIT="${NAVMESH_VERSION_TIMEOUT:-45}"

rm -rf "$VERSION_DIR"
mkdir -p "$VERSION_DIR"
: > "$VERSION_LOG"

set +e

"$TOOL" \
    --resources "$ROOT/resources" \
    --config "$CFGDIR" \
    --user-data "$VERSION_DIR" \
    --version \
    > "$VERSION_LOG" 2>&1 &
VERSION_PID=$!

VERSION_FOUND=0
VERSION_WAITED=0

while [ "$VERSION_WAITED" -lt "$VERSION_WAIT" ]; do
    if grep -q 'OpenMW version 0.51.0' "$VERSION_LOG" 2>/dev/null; then
        VERSION_FOUND=1
        break
    fi
    if grep -q 'Fatal error:' "$VERSION_LOG" 2>/dev/null; then
        break
    fi
    kill -0 "$VERSION_PID" 2>/dev/null || break
    sleep 1
    VERSION_WAITED=$((VERSION_WAITED + 1))
done

# The ERR trap fires even while errexit is off, so every command that may
# legitimately return non-zero is guarded explicitly.
if kill -0 "$VERSION_PID" 2>/dev/null; then
    kill "$VERSION_PID" 2>/dev/null || true
    sleep 1 || true
    kill -9 "$VERSION_PID" 2>/dev/null || true
fi
wait "$VERSION_PID" 2>/dev/null || true

set -e

rm -rf "$VERSION_DIR"

echo "Identity probe output (first 40 lines, stopped after ${VERSION_WAITED}s):"
head -40 "$VERSION_LOG"

if grep -q 'Fatal error:' "$VERSION_LOG"; then
    echo "ERROR: isolated navmeshtool reported a fatal error while initializing."
    echo "Output preserved in:"
    echo "  $VERSION_LOG"
    exit 27
fi

if [ "$VERSION_FOUND" -ne 1 ]; then
    echo "ERROR: expected OpenMW 0.51.0 identity was not produced within ${VERSION_WAIT}s."
    echo "Output preserved in:"
    echo "  $VERSION_LOG"
    exit 28
fi

rm -f "$VERSION_LOG"
echo "PASS: current navmeshtool + private current defaults initialize together."

echo
echo "===== 3/7 BACK UP CURRENT CANONICAL DATABASE ====="

DB_BYTES=0
FREE_BYTES=0

if [ -s "$DB" ]; then
    DB_BYTES="$(stat -c %s "$DB" 2>/dev/null || echo 0)" || true
    FREE_BYTES="$(df -B1 "$NAVDIR" 2>/dev/null | awk 'NR==2 {print $4}')" || true
    case "$DB_BYTES" in ''|*[!0-9]*) DB_BYTES=0;; esac
    case "$FREE_BYTES" in ''|*[!0-9]*) FREE_BYTES=0;; esac
fi

if [ -s "$DB" ] && [ "$KEEP_BACKUPS" -lt 1 ] 2>/dev/null; then
    echo "Backups are disabled (NAVMESH_KEEP_BACKUPS=$KEEP_BACKUPS)."
    echo "The canonical database is left in place."
elif [ -s "$DB" ] && [ "$FREE_BYTES" -lt "$((DB_BYTES + 268435456))" ]; then
    echo "SKIPPING backup: UDISK does not have room for a safe copy."
    echo "  database: $DB_BYTES bytes"
    echo "  free:     $FREE_BYTES bytes"
    echo "The pristine copy on the SD card remains the recovery source."
elif [ -s "$DB" ]; then
    STAMP="$(date +%Y%m%d-%H%M%S)"
    BEFORE_SHA="$(sha256sum "$DB" | awk '{print $1}')"
    BACKUP="$BACKUP_DIR/navmesh-before-full-$STAMP.db"

    echo "Current DB:"
    ls -lh "$DB"
    echo "SHA256:"
    echo "  $BEFORE_SHA"
    echo
    echo "Creating verified backup:"
    echo "  $BACKUP"

    cp -p "$DB" "$BACKUP"

    test "$(sha256sum "$BACKUP" | awk '{print $1}')" = "$BEFORE_SHA"

    # Keep only the newest NAVMESH_KEEP_BACKUPS full-generator backups so the
    # 4.9 GB UDISK is not slowly filled by ~500 MB copies.
    if [ "$KEEP_BACKUPS" -ge 1 ] 2>/dev/null; then
        ls -1dt "$BACKUP_DIR"/navmesh-before-full-*.db 2>/dev/null |
        awk -v keep="$KEEP_BACKUPS" 'NR > keep' |
        while IFS= read -r old; do
            [ -n "$old" ] && rm -f "$old"
        done
    fi

    echo "PASS: DB backup SHA verified."
else
    echo "No existing navmesh.db."
    echo "The tool will generate a complete cache from scratch."
fi

echo
echo "===== 4/7 BUILD GENERATION COMMAND ====="

ARGS=(
    --resources "$ROOT/resources"
    --config "$CFGDIR"
    --user-data "$NAVDIR"
    --threads "$THREADS"
    --process-interior-cells true
)

if [ "$REMOVE_UNUSED" = "true" ]; then
    ARGS+=(--remove-unused-tiles)
fi

echo "Command:"
printf '  %q' "$TOOL" "${ARGS[@]}"
printf '\n'

echo
echo "===== 5/7 GENERATE / UPDATE EXTERIORS + ALL INTERIORS ====="

(
    set +e

    echo
    echo "============================================================"
    echo "NAVMESHTOOL STARTED: $(date)"
    echo "============================================================"

    "$TOOL" "${ARGS[@]}"
    rc=$?

    echo
    echo "============================================================"
    echo "NAVMESHTOOL EXIT CODE: $rc"
    echo "NAVMESHTOOL FINISHED:  $(date)"
    echo "============================================================"

    printf '%s\n' "$rc" > "$STATUS_TMP"
    mv -f "$STATUS_TMP" "$STATUS"
    exit "$rc"
) >> "$LOG" 2>&1 &

RUNNER_PID=$!

set +e
if [ "$NAVMESH_UI" = "1" ]; then
    UI_STARTED="$(date +%s)" || true
    "$PROGRESS" "$LOG" "$STATUS" "$DB" 2>> "$LOG"
    UI_RC=$?
    UI_NOW="$(date +%s)" || true
    UI_SECONDS=$(( UI_NOW - UI_STARTED ))

    if [ "$UI_SECONDS" -lt 3 ]; then
        echo
        echo "============================================================"
        echo "WARNING: the progress window exited after ${UI_SECONDS}s (code $UI_RC)."
        echo "Generation continues, but the screen stays black until it ends."
        echo "Helper: $PROGRESS"
        echo "============================================================"
        echo
    fi
else
    UI_RC=0
    echo "Headless generation: progress is being reported through this log."
fi

wait "$RUNNER_PID"
NAV_RC=$?
set -e

if [ -f "$STATUS" ]; then
    read -r FINAL_RC < "$STATUS" || FINAL_RC="$NAV_RC"
else
    FINAL_RC="$NAV_RC"
fi

echo
echo "Progress UI exit: $UI_RC"
echo "Navmeshtool exit: $FINAL_RC"

echo
echo "===== 6/7 VALIDATE DATABASE ====="

if [ ! -s "$DB" ]; then
    echo "ERROR: resulting database is missing or empty."
    exit 29
fi

ls -lh "$DB"
AFTER_SHA="$(sha256sum "$DB" | awk '{print $1}')"
echo "SHA256:"
echo "  $AFTER_SHA"

DB_OK=0
if command -v sqlite3 >/dev/null 2>&1; then
    INTEGRITY="$(sqlite3 "$DB" 'PRAGMA integrity_check;' 2>&1 || true)"
    echo "SQLite integrity:"
    echo "$INTEGRITY"

    if [ "$INTEGRITY" = "ok" ]; then
        DB_OK=1

        echo
        echo "Worldspaces / tiles:"
        sqlite3 -tabs "$DB" \
          'SELECT COUNT(DISTINCT worldspace), COUNT(*) FROM tiles;' \
          2>/dev/null || true
    fi
else
    echo "sqlite3 unavailable; database integrity could not be queried."
fi

if [ "$FINAL_RC" -ne 0 ]; then
    echo
    echo "WARNING: navmeshtool returned $FINAL_RC."

    # The original TSP generator could be killed during its final SQLite
    # VACUUM after writing all generated tiles. Preserve a clean DB rather
    # than automatically restoring over useful completed work.
    if [ "$DB_OK" = 1 ] && grep -q 'Generated navmesh for' "$LOG"; then
        echo "However:"
        echo "  - SQLite integrity is OK"
        echo "  - generation summary exists in the log"
        echo
        echo "The database is being PRESERVED for inspection instead of"
        echo "automatically rolling it back."
    else
        echo "Generation did not meet the safe completed-work criteria."
        exit "$FINAL_RC"
    fi
fi

echo
echo "===== 7/7 COMPLETE ====="

echo "Canonical runtime DB:"
echo "  $DB"
echo
echo "Log:"
echo "  $LOG"
echo
echo "============================================================"
echo "FULL NAVMESH GENERATION FINISHED"
echo "============================================================"

if [ -t 0 ]; then
    echo
    printf "Press Enter to exit..."
    read -r _unused || true
fi
