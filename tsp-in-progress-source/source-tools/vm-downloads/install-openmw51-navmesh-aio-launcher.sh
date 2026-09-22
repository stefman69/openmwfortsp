#!/usr/bin/env bash
set -Eeuo pipefail

cd "$HOME/Downloads"

DEV="${TSP_DEV:-root@192.168.1.25}"

ROOT="/mnt/SDCARD/data/ports/openmw51"
RUNTIME="$ROOT/navmesh-tool-runtime"
NAVTOOL="$RUNTIME/openmw-navmeshtool"
PRIVATE_DEFAULTS="$RUNTIME/defaults.bin"
PRIVATE_CFG="$RUNTIME/openmw.cfg"
CONFIG_DIR="$ROOT/config-0.51"

PROGRESS_UI="$ROOT/bin/openmw-navmesh-progress"
PROGRESS_REAL="$ROOT/bin/openmw-navmesh-progress.sdl"

NAVDIR="/mnt/UDISK/openmw51-nav"
DB="$NAVDIR/navmesh.db"

PORTS="/mnt/SDCARD/Roms/PORTS"
LAUNCHER="$PORTS/OpenMW_51_Generate_Full_Navmesh_3Worker.sh"

EXPECTED_TOOL_SHA="eac7e0e01ed7507ee32da113c46f36511dd8a3f1f56aa1b684545924b1083229"

STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="$HOME/Downloads/navmesh-aio-launcher-$STAMP"
mkdir -p "$OUT"

exec > >(tee "$OUT/install.log") 2>&1

echo "=================================================================="
echo "OPENMW 0.51 NAVMESH — PERMANENT AIO PORTS LAUNCHER"
echo "=================================================================="
echo
echo "One Ports entry will:"
echo "  1. verify the navmesh runtime"
echo "  2. start current-source navmeshtool with 3 workers"
echo "  3. immediately open the working system-SDL progress UI"
echo "  4. keep the launcher alive until navmeshtool finishes"
echo "  5. return to Ports when the UI/finalization is complete"
echo
echo "No second navmesh DB."
echo "No automatic DB backup."
echo "No generation is started by THIS installer."
echo "=================================================================="

echo
echo "===== 1/5 CHECK CURRENT GENERATION ====="

RUNNING="$(
ssh "$DEV" '
ps w 2>/dev/null | grep "[o]penmw-navmeshtool" || true
'
)"

if [ -n "$RUNNING" ]; then
    echo
    echo "A navmeshtool is STILL RUNNING:"
    echo "$RUNNING"
    echo
    echo "Nothing will be changed while generation is active."
    echo "Run this installer again after it finishes."
    exit 40
fi

ssh "$DEV" "
ROOT='$ROOT'
LOG='\$ROOT/navmesh-generation-full-3worker.log'
STATUS='\$ROOT/navmesh-generation-full-3worker.status'
DB='$DB'

echo 'No navmeshtool process is running.'

echo
echo 'Previous run status:'
if [ -s \"\$STATUS\" ]; then
    cat \"\$STATUS\"
else
    echo 'status file missing (possible older/orphaned launcher run)'
fi

echo
echo 'Latest completed worldspace:'
grep -E 'Processed worldspace \\([0-9]+/[0-9]+\\)' \"\$LOG\" 2>/dev/null |
tail -1 || true

echo
echo 'Latest generator ending lines:'
grep -E 'NAVMESHTOOL EXIT CODE|NAVMESHTOOL FINISHED|Vacuuming the database|Generated navmesh for' \
    \"\$LOG\" 2>/dev/null |
tail -8 || true

echo
echo 'Current DB:'
ls -lh \"\$DB\" 2>/dev/null || true
"

echo
echo "===== 2/5 VERIFY WORKING UI + NAVTOOL ====="

ssh "$DEV" "
set -e

test -x '$NAVTOOL'
test -s '$PRIVATE_DEFAULTS'
test -s '$PRIVATE_CFG'
test -s '$CONFIG_DIR/openmw.cfg'

test -x '$PROGRESS_UI'
test -x '$PROGRESS_REAL'

# The working wrapper must explicitly prioritize TrimUI's native SDL.
grep -q '/usr/trimui/lib' '$PROGRESS_UI'

TOOL_SHA=\$(sha256sum '$NAVTOOL' | awk '{print \$1}')

if [ \"\$TOOL_SHA\" != '$EXPECTED_TOOL_SHA' ]; then
    echo 'ERROR: unexpected navmeshtool SHA:'
    echo \"  \$TOOL_SHA\"
    exit 41
fi

echo 'PASS: current rebuilt navmeshtool verified.'
echo 'PASS: system-SDL progress wrapper verified.'

echo
echo 'Progress helper resolves SDL as:'
LD_LIBRARY_PATH='/usr/trimui/lib:/mnt/SDCARD/System/lib:$ROOT/lib:$ROOT/libs:$ROOT/lib/aarch64' \
ldd '$PROGRESS_REAL' |
grep 'libSDL2' || true
"

echo
echo "===== 3/5 WRITE PERMANENT AIO LAUNCHER ====="

cat > "$OUT/OpenMW_51_Generate_Full_Navmesh_3Worker.sh" <<'LAUNCHER_EOF'
#!/bin/bash
set -u

# ============================================================
# OpenMW 0.51 / TrimUI Smart Pro
# PERMANENT AIO NAVMESH GENERATOR
#
# One Ports entry:
#   - starts current-source openmw-navmeshtool
#   - updates /mnt/UDISK/openmw51-nav/navmesh.db in place
#   - generates exterior + ALL interior worldspaces
#   - uses 3 workers by default
#   - opens the system-SDL progress/ETA UI immediately
#   - waits for navmeshtool through final database processing
#
# The graphical helper has its own TrimUI-system-SDL wrapper.
# Navmeshtool itself keeps the OpenMW runtime library environment.
#
# No second/work DB.
# No automatic DB backup.
# ============================================================

ROOT="${OPENMW51_GAMEDIR:-/mnt/SDCARD/data/ports/openmw51}"

RUNTIME="$ROOT/navmesh-tool-runtime"
NAVTOOL="$RUNTIME/openmw-navmeshtool"
PRIVATE_DEFAULTS="$RUNTIME/defaults.bin"
PRIVATE_CFG="$RUNTIME/openmw.cfg"

CONFIG_DIR="$ROOT/config-0.51"

PROGRESS_UI="$ROOT/bin/openmw-navmesh-progress"

NAVDIR="${OPENMW51_NAVMESH_DIR:-/mnt/UDISK/openmw51-nav}"
DB="$NAVDIR/navmesh.db"

LOG="$ROOT/navmesh-generation-full-3worker.log"
STATUS="$ROOT/navmesh-generation-full-3worker.status"
STATUS_TMP="$STATUS.tmp"

THREADS="${NAVMESH_THREADS:-3}"
PROCESS_INTERIORS="${NAVMESH_INTERIORS:-true}"

# Permanent/update behavior:
# remove tiles that no longer belong to the CURRENT content profile.
# This keeps removed/replaced mod cells from accumulating stale cache data.
REMOVE_UNUSED="${NAVMESH_REMOVE_UNUSED:-true}"

EXPECTED_TOOL_SHA="eac7e0e01ed7507ee32da113c46f36511dd8a3f1f56aa1b684545924b1083229"

mkdir -p "$NAVDIR" "$ROOT"

write_status() {
    rc="$1"
    printf '%s\n' "$rc" > "$STATUS_TMP"
    mv -f "$STATUS_TMP" "$STATUS"
    sync
}

display_status_and_exit() {
    rc="$1"

    write_status "$rc"

    if [ -x "$PROGRESS_UI" ]; then
        "$PROGRESS_UI" "$LOG" "$STATUS" "$DB" 2>>"$LOG" || true
    fi

    exit "$rc"
}

# ------------------------------------------------------------
# Fresh run state
# ------------------------------------------------------------

rm -f "$STATUS" "$STATUS_TMP"
: > "$LOG"

{
    echo "============================================================"
    echo "OpenMW 0.51 COMPLETE Navmesh Generator"
    echo "AIO system-SDL progress launcher"
    echo "============================================================"
    echo "Started:      $(date)"
    echo "Navmeshtool:  $NAVTOOL"
    echo "Database:     $DB"
    echo "Workers:      $THREADS"
    echo "Interiors:    $PROCESS_INTERIORS"
    echo "Prune stale:  $REMOVE_UNUSED"
    echo "============================================================"
} >>"$LOG"

# ------------------------------------------------------------
# Fast preflight — intentionally no giant SHA of navmesh.db and
# no full SQLite integrity scan before the UI can appear.
# ------------------------------------------------------------

if pidof openmw-0.51 >/dev/null 2>&1 || pidof openmw >/dev/null 2>&1; then
    echo "ERROR: close Morrowind before generating navmesh." >>"$LOG"
    display_status_and_exit 22
fi

if pidof openmw-navmeshtool >/dev/null 2>&1; then
    {
        echo "ERROR: openmw-navmeshtool is already running."
        ps w 2>/dev/null | grep '[o]penmw-navmeshtool' || true
        echo "Refusing to start a second generator."
    } >>"$LOG"
    display_status_and_exit 23
fi

for required in \
    "$NAVTOOL" \
    "$PRIVATE_DEFAULTS" \
    "$PRIVATE_CFG" \
    "$PROGRESS_UI" \
    "$CONFIG_DIR/openmw.cfg"
do
    if [ ! -e "$required" ]; then
        echo "ERROR: required file is missing: $required" >>"$LOG"
        display_status_and_exit 24
    fi
done

for executable in "$NAVTOOL" "$PROGRESS_UI"; do
    if [ ! -x "$executable" ]; then
        echo "ERROR: required file is not executable: $executable" >>"$LOG"
        display_status_and_exit 25
    fi
done

case "$THREADS" in
    ''|*[!0-9]*|0)
        echo "ERROR: NAVMESH_THREADS must be an integer >= 1." >>"$LOG"
        display_status_and_exit 26
        ;;
esac

case "$PROCESS_INTERIORS" in
    true|false) ;;
    *)
        echo "ERROR: NAVMESH_INTERIORS must be true or false." >>"$LOG"
        display_status_and_exit 27
        ;;
esac

case "$REMOVE_UNUSED" in
    true|false) ;;
    *)
        echo "ERROR: NAVMESH_REMOVE_UNUSED must be true or false." >>"$LOG"
        display_status_and_exit 28
        ;;
esac

TOOL_SHA="$(sha256sum "$NAVTOOL" | awk '{print $1}')"

if [ "$TOOL_SHA" != "$EXPECTED_TOOL_SHA" ]; then
    {
        echo "ERROR: wrong navmeshtool build."
        echo "Expected: $EXPECTED_TOOL_SHA"
        echo "Found:    $TOOL_SHA"
    } >>"$LOG"
    display_status_and_exit 29
fi

if grep -n '\$ROOT\|\${ROOT}' "$PRIVATE_CFG" >>"$LOG" 2>&1; then
    echo "ERROR: unresolved ROOT token exists in private openmw.cfg." >>"$LOG"
    display_status_and_exit 30
fi

# ------------------------------------------------------------
# Navmeshtool environment
# ------------------------------------------------------------

export LD_LIBRARY_PATH="$ROOT/lib:$ROOT/libs:$ROOT/lib/aarch64:/mnt/SDCARD/System/lib:/usr/trimui/lib:${LD_LIBRARY_PATH:-}"
export OSG_LIBRARY_PATH="$ROOT/osgPlugins-3.6.5"

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/runtime-root}"
export XDG_CONFIG_HOME="$CONFIG_DIR"
export XDG_DATA_HOME="$CONFIG_DIR"
export OPENMW_RESOURCES="$ROOT/resources"

mkdir -p "$XDG_RUNTIME_DIR"
chmod 0700 "$XDG_RUNTIME_DIR" 2>/dev/null || true

unset OPENMW_TSP_ENABLE_NAVIGATOR 2>/dev/null || true

ARGS=(
    --resources "$ROOT/resources"
    --config "$CONFIG_DIR"
    --user-data "$NAVDIR"
    --threads "$THREADS"
    --process-interior-cells "$PROCESS_INTERIORS"
    --remove-unused-tiles "$REMOVE_UNUSED"
)

{
    echo
    echo "Database before run:"
    ls -lh "$DB" 2>/dev/null || echo "  new database"
    echo
    echo "Command:"
    printf '  %q' "$NAVTOOL" "${ARGS[@]}"
    printf '\n'
    echo
    echo "NAVMESHTOOL STARTING..."
} >>"$LOG"

# ------------------------------------------------------------
# Generator = background child.
# Progress UI = foreground process visible to the end user.
# ------------------------------------------------------------

(
    set +e

    cd "$RUNTIME" || {
        echo "ERROR: could not enter $RUNTIME" >>"$LOG"
        write_status 90
        exit 90
    }

    {
        echo
        echo "============================================================"
        echo "NAVMESHTOOL STARTED: $(date)"
        echo "============================================================"
    } >>"$LOG"

    "$NAVTOOL" "${ARGS[@]}" >>"$LOG" 2>&1
    rc=$?

    {
        echo
        echo "============================================================"
        echo "NAVMESHTOOL EXIT CODE: $rc"
        echo "NAVMESHTOOL FINISHED:  $(date)"
        echo "============================================================"
    } >>"$LOG"

    write_status "$rc"
    exit "$rc"
) &

RUNNER_PID=$!

# Immediately hand the LCD to the working system-SDL helper.
# It watches LOG + STATUS + DB and remains visible through finalization.
#
# If the helper ever exits unexpectedly while navmeshtool is still alive,
# automatically reopen it. The end user should never need Attach Progress
# during a normal run.
UI_RC=0

while kill -0 "$RUNNER_PID" 2>/dev/null; do
    set +e
    "$PROGRESS_UI" "$LOG" "$STATUS" "$DB" 2>>"$LOG"
    UI_RC=$?
    set -e

    if kill -0 "$RUNNER_PID" 2>/dev/null; then
        {
            echo
            echo "WARNING: progress UI exited early with code $UI_RC."
            echo "Navmeshtool is still running; reopening the UI."
        } >>"$LOG"

        sleep 0.25
    fi
done

# Reap the generator and obtain its real exit status.
set +e
wait "$RUNNER_PID"
NAV_RC=$?
set -e

if [ -s "$STATUS" ]; then
    read -r FINAL_RC <"$STATUS" || FINAL_RC="$NAV_RC"
else
    FINAL_RC="$NAV_RC"
fi

{
    echo
    echo "Progress UI exit code: $UI_RC"
    echo "Navmeshtool exit code: $FINAL_RC"
    echo
    echo "Database after run:"
    ls -lh "$DB" 2>/dev/null || true

    if command -v sqlite3 >/dev/null 2>&1 && [ -s "$DB" ]; then
        echo
        echo "Final DB totals:"
        sqlite3 -tabs "$DB" \
          'SELECT COUNT(DISTINCT worldspace), COUNT(*) FROM tiles;' \
          2>/dev/null || true
    fi

    echo
    echo "Finished: $(date)"
} >>"$LOG"

# If the graphical helper somehow exited before the generator, STATUS now
# contains the real final result. Show the final state once more.
if [ "$UI_RC" -ne 0 ] && [ -x "$PROGRESS_UI" ]; then
    "$PROGRESS_UI" "$LOG" "$STATUS" "$DB" 2>>"$LOG" || true
fi

exit "$FINAL_RC"
LAUNCHER_EOF

chmod +x "$OUT/OpenMW_51_Generate_Full_Navmesh_3Worker.sh"
bash -n "$OUT/OpenMW_51_Generate_Full_Navmesh_3Worker.sh"

echo "PASS: local launcher syntax."

echo
echo "===== 4/5 INSTALL ON TRIMUI ====="

ssh "$DEV" "
set -e

# Race protection: do not replace launcher if a generation started since the
# first check.
if pidof openmw-navmeshtool >/dev/null 2>&1; then
    echo 'ERROR: navmeshtool started while installer was running.'
    echo 'Launcher left unchanged.'
    exit 42
fi

if [ -e '$LAUNCHER' ]; then
    cp -p '$LAUNCHER' '$LAUNCHER.before-aio-$STAMP'
fi
"

scp -q \
    "$OUT/OpenMW_51_Generate_Full_Navmesh_3Worker.sh" \
    "$DEV:$LAUNCHER.new"

ssh "$DEV" "
set -e

chmod +x '$LAUNCHER.new'
bash -n '$LAUNCHER.new'

grep -q 'PERMANENT AIO NAVMESH GENERATOR' '$LAUNCHER.new'
grep -q 'NAVMESH_THREADS:-3' '$LAUNCHER.new'
grep -q 'process-interior-cells' '$LAUNCHER.new'
grep -q 'remove-unused-tiles' '$LAUNCHER.new'
grep -q '/mnt/UDISK/openmw51-nav' '$LAUNCHER.new'
grep -q 'openmw-navmesh-progress' '$LAUNCHER.new'

mv -f '$LAUNCHER.new' '$LAUNCHER'
sync

echo 'Installed AIO launcher:'
ls -lh '$LAUNCHER'
"

echo
echo "===== 5/5 FINAL VERIFICATION ====="

ssh "$DEV" "
set -e

echo '--- launcher markers ---'
grep -nE \
'PERMANENT AIO|THREADS=|PROCESS_INTERIORS=|REMOVE_UNUSED=|PROGRESS_UI=' \
'$LAUNCHER'

echo
echo '--- UI wrapper ---'
head -18 '$PROGRESS_UI'

echo
echo '--- navmeshtool ---'
sha256sum '$NAVTOOL'

echo
echo '--- DB ---'
ls -lh '$DB'

echo
echo '--- running generator ---'
ps w 2>/dev/null | grep '[o]penmw-navmeshtool' || echo none
"

echo
echo "=================================================================="
echo "AIO LAUNCHER INSTALLED"
echo "=================================================================="
echo
echo "Normal end-user use is now ONE Ports entry:"
echo
echo "  OpenMW_51_Generate_Full_Navmesh_3Worker.sh"
echo
echo "One tap starts:"
echo "  navmeshtool (3 workers, exterior + interiors)"
echo "  + the working system-SDL progress/ETA UI"
echo
echo "This installer did NOT start generation."
echo
echo "Installer log:"
echo "  $OUT/install.log"
echo "=================================================================="
