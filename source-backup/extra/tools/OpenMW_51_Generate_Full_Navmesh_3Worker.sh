#!/bin/bash
set -Eeuo pipefail

# ============================================================
# OpenMW 0.51 / TrimUI Smart Pro
# COMPLETE NAVMESH GENERATOR — Exterior + ALL Interiors
#
# Uses:
#   CURRENT rebuilt navmeshtool:
#     /mnt/SDCARD/data/ports/openmw51/navmesh-tool-runtime/openmw-navmeshtool
#
# Updates IN PLACE:
#     /mnt/UDISK/openmw51-nav/navmesh.db
#
# The existing SDL2 progress UI stays in the foreground.
# Default workers: 3
#
# IMPORTANT:
#   - NO second/work navmesh database is created.
#   - NO automatic navmesh.db backup is created.
#   - Existing user backups are left untouched.
# ============================================================

if [ -z "${BASH_VERSION:-}" ]; then
    exec /bin/bash "$0" "$@"
fi

GAMEDIR="${OPENMW51_GAMEDIR:-/mnt/SDCARD/data/ports/openmw51}"

RUNTIME="$GAMEDIR/navmesh-tool-runtime"
NAVTOOL="$RUNTIME/openmw-navmeshtool"
PRIVATE_DEFAULTS="$RUNTIME/defaults.bin"
PRIVATE_CFG="$RUNTIME/openmw.cfg"

PROGRESS_UI="$GAMEDIR/bin/openmw-navmesh-progress"
CONFIG_DIR="$GAMEDIR/config-0.51"

NAVDIR="/mnt/UDISK/openmw51-nav"
DB="$NAVDIR/navmesh.db"

LOG="$GAMEDIR/navmesh-generation-full-3worker.log"
STATUS="$GAMEDIR/navmesh-generation-full-3worker.status"
STATUS_TMP="$STATUS.tmp"

THREADS="${NAVMESH_THREADS:-3}"
PROCESS_INTERIORS="${NAVMESH_INTERIORS:-true}"

EXPECTED_TOOL_SHA="eac7e0e01ed7507ee32da113c46f36511dd8a3f1f56aa1b684545924b1083229"

case "$THREADS" in
    ''|*[!0-9]*|0)
        echo "ERROR: NAVMESH_THREADS must be an integer >= 1."
        exit 20
        ;;
esac

case "$PROCESS_INTERIORS" in
    true|false) ;;
    *)
        echo "ERROR: NAVMESH_INTERIORS must be true or false."
        exit 21
        ;;
esac

mkdir -p "$NAVDIR" "$GAMEDIR"
rm -f "$STATUS" "$STATUS_TMP"
: > "$LOG"

export LD_LIBRARY_PATH="$GAMEDIR/lib:$GAMEDIR/libs:$GAMEDIR/lib/aarch64:/mnt/SDCARD/System/lib:/usr/trimui/lib:${LD_LIBRARY_PATH:-}"
export OSG_LIBRARY_PATH="$GAMEDIR/osgPlugins-3.6.5"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/runtime-root}"
export XDG_CONFIG_HOME="$CONFIG_DIR"
export XDG_DATA_HOME="$CONFIG_DIR"
export OPENMW_RESOURCES="$GAMEDIR/resources"

mkdir -p "$XDG_RUNTIME_DIR"
chmod 0700 "$XDG_RUNTIME_DIR" 2>/dev/null || true

# Do not inherit the game's optional navigator switch.
unset OPENMW_TSP_ENABLE_NAVIGATOR 2>/dev/null || true

# TSP_NAVMESH_PORTMASTER_DISPLAY_V1
# Give the SDL progress helper the same CrossMix/PortMaster graphical
# initialization used by the normal working Morrowind launcher.

XDG_DATA_HOME_PM="${XDG_DATA_HOME_PM:-$HOME/.local/share}"
controlfolder=""

for candidate in \
    "/mnt/SDCARD/Apps/PortMaster" \
    "/opt/system/Tools/PortMaster" \
    "/opt/tools/PortMaster" \
    "$XDG_DATA_HOME_PM/PortMaster" \
    "/mnt/SDCARD/data/ports/PortMaster" \
    "/roms/ports/PortMaster"
do
    if [ -f "$candidate/control.txt" ]; then
        controlfolder="$candidate"
        break
    fi
done

if [ -z "$controlfolder" ]; then
    controlfolder="/roms/ports/PortMaster"
fi

export PORT_DIR="$GAMEDIR"

{
    echo "PortMaster control folder: $controlfolder"
    echo "PORT_DIR before loading PortMaster: $PORT_DIR"
} >> "$LOG"

if [ -f "$controlfolder/control.txt" ]; then
    set +e
    set +u
    set +o pipefail 2>/dev/null || true

    source "$controlfolder/control.txt" >>"$LOG" 2>&1
    CONTROL_TXT_RESULT=$?

    # TSP_NAVMESH_PORTMASTER_NOUNSET_FIX_V2
    #
    # PortMaster get_controls/mod scripts reference optional positional
    # parameters such as $1. Keep nounset and pipefail disabled until all
    # PortMaster initialization has completed, matching the working
    # Morrowind launcher.
    set -e

    echo "PortMaster control.txt returned: $CONTROL_TXT_RESULT" >> "$LOG"
else
    echo "WARNING: PortMaster control.txt was not found." >> "$LOG"
fi

if type get_controls >/dev/null 2>&1; then
    get_controls >>"$LOG" 2>&1 || true
fi

if [ -n "${CFW_NAME:-}" ] &&
   [ -f "${controlfolder}/mod_${CFW_NAME}.txt" ]
then
    set +e
    set +u
    set +o pipefail 2>/dev/null || true

    source "${controlfolder}/mod_${CFW_NAME}.txt" >>"$LOG" 2>&1
    MOD_RESULT=$?

    # Keep nounset disabled through the entire PortMaster initialization.
    set -e

    echo "PortMaster mod_${CFW_NAME}.txt returned: $MOD_RESULT" >> "$LOG"
fi

# PortMaster initialization is complete. Restore launcher strict mode now.
set -Eeuo pipefail

if ! type pm_finish >/dev/null 2>&1; then
    pm_finish() { true; }
fi

PROGRESS_PLATFORM_READY=0

prepare_progress_platform() {
    if [ "$PROGRESS_PLATFORM_READY" -eq 1 ]; then
        return 0
    fi

    {
        echo
        echo "===== PORTMASTER PROGRESS DISPLAY SETUP ====="
        echo "CFW_NAME=${CFW_NAME:-unknown}"
        echo "DEVICE_NAME=${DEVICE_NAME:-unknown}"
        echo "DEVICE_ARCH=${DEVICE_ARCH:-unknown}"
    } >> "$LOG"

    if type pm_platform_helper >/dev/null 2>&1; then
        set +e
        pm_platform_helper "$PROGRESS_UI" >>"$LOG" 2>&1
        PM_HELPER_RC=$?
        set -e

        echo "pm_platform_helper(progress) rc=$PM_HELPER_RC" >> "$LOG"
    else
        echo "WARNING: pm_platform_helper unavailable." >> "$LOG"
    fi

    PROGRESS_PLATFORM_READY=1
}

run_progress_ui() {
    prepare_progress_platform
    "$PROGRESS_UI" "$LOG" "$STATUS" "$DB" 2>>"$LOG"
}

write_status() {
    rc="$1"
    printf '%s\n' "$rc" > "$STATUS_TMP"
    mv -f "$STATUS_TMP" "$STATUS"
    sync
}

show_failure() {
    rc="$1"

    {
        echo
        echo "============================================================"
        echo "NAVMESH GENERATOR STOPPED"
        echo "Exit code: $rc"
        echo "Finished:  $(date)"
        echo "Database:  $DB"
        echo "Log:       $LOG"
        echo "============================================================"
    } >> "$LOG"

    write_status "$rc" || true

    # Reuse the same SDL UI for preflight/runtime errors.
    if [ -x "$PROGRESS_UI" ]; then
        run_progress_ui || true
    fi
}

fail() {
    rc=$?
    line="${1:-?}"
    cmd="${2:-?}"
    trap - ERR

    {
        echo
        echo "ERROR:"
        echo "  line:    $line"
        echo "  command: $cmd"
    } >> "$LOG"

    show_failure "$rc"
    exit "$rc"
}
trap 'fail "$LINENO" "$BASH_COMMAND"' ERR

{
    echo "============================================================"
    echo "OpenMW 0.51 COMPLETE Navmesh Generator"
    echo "CURRENT-SOURCE navmeshtool"
    echo "============================================================"
    echo "Started:      $(date)"
    echo "Navmeshtool:  $NAVTOOL"
    echo "Database:     $DB"
    echo "Workers:      $THREADS"
    echo "Interiors:    $PROCESS_INTERIORS"
    echo
    grep -E '^(MemTotal|MemAvailable|SwapTotal|SwapFree|CmaFree):' \
        /proc/meminfo 2>/dev/null || true
    echo "============================================================"
    echo
    echo "===== 1/6 PREFLIGHT ====="
} >> "$LOG"

# Never generate while the game is running.
if pidof openmw-0.51 >/dev/null 2>&1 || pidof openmw >/dev/null 2>&1; then
    echo "ERROR: close Morrowind before generating navmesh." >> "$LOG"
    show_failure 22
    exit 22
fi

# The previous detached --version test may still exist if its Ubuntu poll was
# interrupted. Never start a second navmeshtool on top of it.
if pidof openmw-navmeshtool >/dev/null 2>&1; then
    {
        echo "ERROR: an openmw-navmeshtool process is already running."
        echo
        ps w 2>/dev/null | grep '[o]penmw-navmeshtool' || true
        echo
        echo "Refusing to start a second generator."
    } >> "$LOG"

    show_failure 23
    exit 23
fi

for required in \
    "$NAVTOOL" \
    "$PRIVATE_DEFAULTS" \
    "$PRIVATE_CFG" \
    "$PROGRESS_UI" \
    "$CONFIG_DIR/openmw.cfg"
do
    if [ ! -e "$required" ]; then
        echo "ERROR: required file is missing: $required" >> "$LOG"
        show_failure 24
        exit 24
    fi
done

for executable in "$NAVTOOL" "$PROGRESS_UI"; do
    if [ ! -x "$executable" ]; then
        echo "ERROR: required file is not executable: $executable" >> "$LOG"
        show_failure 25
        exit 25
    fi
done

TOOL_SHA="$(sha256sum "$NAVTOOL" | awk '{print $1}')"

{
    echo "Navmeshtool SHA256:"
    echo "  $TOOL_SHA"
} >> "$LOG"

if [ "$TOOL_SHA" != "$EXPECTED_TOOL_SHA" ]; then
    {
        echo "ERROR: launcher expected the freshly rebuilt current-source tool:"
        echo "  $EXPECTED_TOOL_SHA"
        echo "but found:"
        echo "  $TOOL_SHA"
    } >> "$LOG"

    show_failure 26
    exit 26
fi

# Make sure the private config has not regressed to the literal $ROOT problem.
if grep -n '\$ROOT\|\${ROOT}' "$PRIVATE_CFG" >>"$LOG" 2>&1; then
    echo "ERROR: unresolved ROOT token exists in private openmw.cfg." >> "$LOG"
    show_failure 27
    exit 27
fi

echo "PASS: current rebuilt tool and private runtime verified." >> "$LOG"
echo >> "$LOG"

echo "===== 2/6 EXISTING DATABASE =====" >> "$LOG"

if [ -s "$DB" ]; then
    DB_SHA_BEFORE="$(sha256sum "$DB" | awk '{print $1}')"
    DB_BYTES_BEFORE="$(stat -c %s "$DB" 2>/dev/null || echo 0)"

    {
        echo "Updating the EXISTING game navmesh database IN PLACE."
        ls -lh "$DB"
        echo "Starting SHA256:"
        echo "  $DB_SHA_BEFORE"
        echo "Starting bytes:"
        echo "  $DB_BYTES_BEFORE"
    } >> "$LOG"

    if command -v sqlite3 >/dev/null 2>&1; then
        BEFORE_INTEGRITY="$(sqlite3 "$DB" 'PRAGMA integrity_check;' 2>&1 || true)"
        echo "Pre-run SQLite integrity: $BEFORE_INTEGRITY" >> "$LOG"

        if [ "$BEFORE_INTEGRITY" != "ok" ]; then
            echo "ERROR: existing navmesh.db is not healthy. Refusing to modify it." >> "$LOG"
            show_failure 28
            exit 28
        fi

        {
            echo "Pre-run DB totals:"
            sqlite3 -tabs "$DB" \
              'SELECT COUNT(DISTINCT worldspace), COUNT(*) FROM tiles;' \
              2>/dev/null || true
        } >> "$LOG"
    fi
else
    DB_SHA_BEFORE=""
    DB_BYTES_BEFORE=0
    echo "No existing navmesh.db found; navmeshtool will create it here:" >> "$LOG"
    echo "  $DB" >> "$LOG"
fi

echo >> "$LOG"

echo "===== 3/6 BUILD COMMAND =====" >> "$LOG"

ARGS=(
    --resources "$GAMEDIR/resources"
    --config "$CONFIG_DIR"
    --user-data "$NAVDIR"
    --threads "$THREADS"
    --process-interior-cells "$PROCESS_INTERIORS"
)

# Deliberately do NOT pass --remove-unused-tiles on this first complete
# current-source run. We want to add/update interior geometry without asking
# the tool to delete anything from the existing exterior cache.

{
    echo "Stale-tile removal: DISABLED"
    echo "Command:"
    printf '  %q' "$NAVTOOL" "${ARGS[@]}"
    printf '\n'
    echo
    echo "===== 4/6 START GENERATOR ====="
} >> "$LOG"

# Navmeshtool runs in a background child so the SDL progress helper owns the
# screen. All navmeshtool output is preserved verbatim in LOG.
(
    set +e
    cd "$RUNTIME" || exit 90

    {
        echo
        echo "============================================================"
        echo "NAVMESHTOOL STARTED: $(date)"
        echo "Workers: $THREADS"
        echo "Database: $DB"
        echo "============================================================"
    } >> "$LOG"

    "$NAVTOOL" "${ARGS[@]}" >> "$LOG" 2>&1
    rc=$?

    {
        echo
        echo "============================================================"
        echo "NAVMESHTOOL EXIT CODE: $rc"
        echo "NAVMESHTOOL FINISHED:  $(date)"
        echo "============================================================"
    } >> "$LOG"

    write_status "$rc"
    exit "$rc"
) &

RUNNER_PID=$!

# Existing SDL progress helper displays:
#   current/total tiles
#   percentage
#   rolling tiles/sec
#   elapsed time
#   ETA
#   DB size
#
# It remains foregrounded on the TrimUI while navmeshtool works.
set +e
run_progress_ui
UI_RC=$?
set -e

# Progress UI normally waits for STATUS before returning. Waiting here keeps
# launcher lifecycle coherent even if the UI exits unexpectedly.
set +e
wait "$RUNNER_PID"
NAV_RC=$?
set -e

if [ -s "$STATUS" ]; then
    read -r FINAL_RC < "$STATUS" || FINAL_RC="$NAV_RC"
else
    FINAL_RC="$NAV_RC"
fi

{
    echo
    echo "Progress UI exit code: $UI_RC"
    echo "Navmeshtool exit code: $FINAL_RC"
    echo
    echo "===== 5/6 VERIFY DATABASE ====="
} >> "$LOG"

if [ ! -s "$DB" ]; then
    echo "ERROR: resulting navmesh.db is missing or empty." >> "$LOG"
    show_failure 29
    exit 29
fi

DB_SHA_AFTER="$(sha256sum "$DB" | awk '{print $1}')"
DB_BYTES_AFTER="$(stat -c %s "$DB" 2>/dev/null || echo 0)"

{
    ls -lh "$DB"
    echo "Final SHA256:"
    echo "  $DB_SHA_AFTER"
    echo "Final bytes:"
    echo "  $DB_BYTES_AFTER"
} >> "$LOG"

if command -v sqlite3 >/dev/null 2>&1; then
    AFTER_INTEGRITY="$(sqlite3 "$DB" 'PRAGMA integrity_check;' 2>&1 || true)"
    echo "Post-run SQLite integrity: $AFTER_INTEGRITY" >> "$LOG"

    if [ "$AFTER_INTEGRITY" != "ok" ]; then
        echo "ERROR: resulting navmesh.db failed integrity_check." >> "$LOG"
        show_failure 30
        exit 30
    fi

    {
        echo
        echo "Post-run DB totals:"
        sqlite3 -tabs "$DB" \
          'SELECT COUNT(DISTINCT worldspace), COUNT(*) FROM tiles;' \
          2>/dev/null || true
    } >> "$LOG"
fi

{
    echo
    echo "===== 6/6 FINAL STATUS ====="
    echo "Database:"
    echo "  $DB"
    echo
    echo "No second navmesh DB was created."
    echo "No automatic DB backup was created."
    echo
} >> "$LOG"

if [ -n "$DB_SHA_BEFORE" ]; then
    if [ "$DB_SHA_AFTER" = "$DB_SHA_BEFORE" ]; then
        echo "Database SHA unchanged." >> "$LOG"
    else
        echo "Database SHA changed: navmesh cache was updated." >> "$LOG"
    fi
fi

if [ "$FINAL_RC" -ne 0 ]; then
    {
        echo
        echo "WARNING: openmw-navmeshtool returned $FINAL_RC."
        echo "Review:"
        echo "  $LOG"
    } >> "$LOG"

    # Status already contains the tool's result; show it again if needed.
    run_progress_ui || true
    exit "$FINAL_RC"
fi

{
    echo "============================================================"
    echo "COMPLETE NAVMESH GENERATION FINISHED"
    echo "============================================================"
    echo "Exterior + interior DB:"
    echo "  $DB"
    echo
    echo "Workers:"
    echo "  $THREADS"
    echo
    echo "Log:"
    echo "  $LOG"
    echo "============================================================"
} >> "$LOG"

exit 0
