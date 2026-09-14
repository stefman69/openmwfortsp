#!/bin/bash
# OpenMW 0.51 TSP integrated manager Ports entry.
# TSP_MANAGER_V24_WRAPPER
set +e
set +u
set +o pipefail 2>/dev/null || true

ROOT="${OPENMW_GAMEDIR:-${OPENMW51_GAMEDIR:-/mnt/SDCARD/data/ports/openmw}}"
BIN="$ROOT/bin/openmw-manager-v2"
BACKEND="$ROOT/launcher/openmw-manager-action-v2.sh"
REQUEST="$ROOT/launcher/request"
RESULT="$ROOT/launcher/last-result.txt"
LOG="$ROOT/launcher/manager-v2.log"
READY="$ROOT/launcher/ui-ready"
PIDFILE="$ROOT/launcher/manager-v2-wrapper.pid"
CHILDPID="$ROOT/launcher/manager-v2-ui.pid"
PROGRESS="${OPENMW_MANAGER_PROGRESS:-/tmp/openmw-manager-progress}"
REPORT="$ROOT/launcher/pending-report"
LAUNCH_ENV="$ROOT/launcher/.launch-env"
PLAY=""
UI_PID=""

mkdir -p "$ROOT/launcher"

# TSP_MANAGER_V24_LAUNCH_ENV_SNAPSHOT
# Snapshot the environment this Ports entry was started with, BEFORE PortMaster
# control.txt/libgl_*.txt are sourced and before any manager SDL override. The
# standalone generator Ports entry is launched with exactly this environment,
# so restoring it is what makes the manager's navmesh build behave identically.
export -p > "$LAUNCH_ENV" 2>/dev/null || : > "$LAUNCH_ENV"

exec >>"$LOG" 2>&1
echo "===== OpenMW 0.51 Manager V2.5 started: $(date) ====="

cleanup_manager() {
    if [ -n "$UI_PID" ] && kill -0 "$UI_PID" 2>/dev/null; then
        kill "$UI_PID" 2>/dev/null || true
        sleep 0.2
        kill -9 "$UI_PID" 2>/dev/null || true
        wait "$UI_PID" 2>/dev/null || true
    fi
    if [ -f "$PIDFILE" ] && [ "$(cat "$PIDFILE" 2>/dev/null)" = "$$" ]; then
        rm -f "$PIDFILE"
    fi
    rm -f "$CHILDPID" "$READY" "$PROGRESS" "$PROGRESS.tmp" "$REPORT.tmp"
}
trap cleanup_manager EXIT
trap 'exit 130' HUP INT TERM

# TSP_MANAGER_V24_GENERATOR_HANDOFF
# Run a command with the snapshotted launch environment and nothing else, so a
# tool that owns the screen never inherits the manager's SDL settings, the
# PortMaster GL4ES exports, or the OpenMW port library path.
#
# V2.5: the navmesh build no longer comes through here - the manager runs the
# generator headless and draws its progress itself. This path stays as the
# fallback for a request file left behind by an older manager.
run_with_launch_env() {
    local snapshot="$1"
    shift
    env -i /bin/bash -c '
        if [ -f "$1" ]; then . "$1" >/dev/null 2>&1 || true; fi
        shift
        exec /bin/bash "$@"
    ' _ "$snapshot" "$@"
}

report() {
    printf 'heading=%s\nok=%s\ncode=%s\n' "$1" "$2" "$3" > "$REPORT.tmp" 2>/dev/null &&
        mv -f "$REPORT.tmp" "$REPORT" 2>/dev/null || true
}

if [ -s "$PIDFILE" ]; then
    old_wrapper="$(cat "$PIDFILE" 2>/dev/null)"
    case "$old_wrapper" in
        ''|*[!0-9]*) ;;
        *)
            if kill -0 "$old_wrapper" 2>/dev/null; then
                echo "Stopping prior Manager wrapper PID $old_wrapper"
                kill "$old_wrapper" 2>/dev/null || true
                sleep 0.3
                kill -9 "$old_wrapper" 2>/dev/null || true
            fi
            ;;
    esac
fi
printf '%s\n' "$$" > "$PIDFILE"

# Clean up a manager that hung before it could accept controller input.
for old_name in openmw-manager-v2 openmw51-manager-v2; do
    for old_ui in $(pidof "$old_name" 2>/dev/null); do
        case "$old_ui" in
            ''|*[!0-9]*) continue ;;
        esac
        echo "Stopping stale Manager UI PID $old_ui"
        kill "$old_ui" 2>/dev/null || true
        sleep 0.2
        kill -9 "$old_ui" 2>/dev/null || true
    done
done

export PORT_DIR="$ROOT"
export OPENMW_GAMEDIR="$ROOT"
export OPENMW_MANAGER_PROGRESS="$PROGRESS"
rm -f "$PROGRESS" "$PROGRESS.tmp"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/runtime-root}"
mkdir -p "$XDG_RUNTIME_DIR"
chmod 0700 "$XDG_RUNTIME_DIR" 2>/dev/null || true

XDG_DATA_HOME_PM="${XDG_DATA_HOME_PM:-$HOME/.local/share}"
controlfolder=""
for candidate in /mnt/SDCARD/Apps/PortMaster /opt/system/Tools/PortMaster /opt/tools/PortMaster "$XDG_DATA_HOME_PM/PortMaster" /mnt/SDCARD/data/ports/PortMaster /roms/ports/PortMaster; do
    if [ -f "$candidate/control.txt" ]; then controlfolder="$candidate"; break; fi
done
if [ -n "$controlfolder" ] && [ -f "$controlfolder/control.txt" ]; then
    source "$controlfolder/control.txt" || true
fi
if type get_controls >/dev/null 2>&1; then get_controls 2>/dev/null || true; fi
if [ -n "${CFW_NAME:-}" ] && [ -n "$controlfolder" ] && [ -f "$controlfolder/mod_${CFW_NAME}.txt" ]; then source "$controlfolder/mod_${CFW_NAME}.txt" || true; fi
if [ -n "${CFW_NAME:-}" ] && [ -n "$controlfolder" ] && [ -f "$controlfolder/libgl_${CFW_NAME}.txt" ]; then source "$controlfolder/libgl_${CFW_NAME}.txt" || true
elif [ -n "$controlfolder" ] && [ -f "$controlfolder/libgl_default.txt" ]; then source "$controlfolder/libgl_default.txt" || true
fi
if ! type pm_finish >/dev/null 2>&1; then pm_finish(){ true; }; fi

set -u
# Manager is self-contained apart from libc/libdl. Do not put OpenMW's GL4ES
# directory in this UI process: its accelerated KMSDRM teardown poisoned the
# next SDL initialization in the repeat-launch trace.
export LD_LIBRARY_PATH="/usr/trimui/lib:/mnt/SDCARD/System/lib:/usr/lib:/lib:/lib64"
export SDL_VIDEODRIVER="kmsdrm"
export SDL_RENDER_DRIVER="software"
unset LD_PRELOAD
unset LIBGL_FB
unset LIBGL_FBO
unset LIBGL_RECYCLEFBO

for candidate in /mnt/SDCARD/Roms/PORTS/Morrowind.sh /mnt/sdcard/mmcblk1p1/Roms/PORTS/Morrowind.sh; do
    if [ -f "$candidate" ]; then PLAY="$candidate"; break; fi
done

if [ ! -x "$BIN" ] || [ ! -x "$BACKEND" ]; then
    printf '%s\n' "ERROR manager runtime missing; see $LOG" > "$RESULT"
    echo "ERROR: manager runtime missing BIN=$BIN BACKEND=$BACKEND"
    pm_finish
    exit 10
fi

run_manager_ui() {
    rm -f "$READY" "$CHILDPID"
    "$BIN" &
    UI_PID=$!
    printf '%s\n' "$UI_PID" > "$CHILDPID"
    ready=0
    ticks=0
    while [ "$ticks" -lt 80 ]; do
        if [ -s "$READY" ]; then ready=1; break; fi
        if ! kill -0 "$UI_PID" 2>/dev/null; then break; fi
        sleep 0.1
        ticks=$((ticks + 1))
    done
    if [ "$ready" -ne 1 ] && kill -0 "$UI_PID" 2>/dev/null; then
        echo "ERROR manager SDL startup exceeded 8 seconds; terminating PID $UI_PID"
        kill "$UI_PID" 2>/dev/null || true
        sleep 0.3
        kill -9 "$UI_PID" 2>/dev/null || true
        wait "$UI_PID" 2>/dev/null || true
        UI_PID=""
        rm -f "$CHILDPID" "$READY"
        return 124
    fi
    wait "$UI_PID"
    rc=$?
    UI_PID=""
    rm -f "$CHILDPID" "$READY"
    return "$rc"
}

while true; do
    # V2.4: the UI publishes its first frame, then runs the status scan itself
    # behind a progress overlay. No blind pre-UI scan, so nothing is displayed
    # as a black screen while the device is being read.
    rm -f "$REQUEST" "$PROGRESS" "$PROGRESS.tmp"
    run_manager_ui
    ui_rc=$?
    if [ "$ui_rc" -eq 124 ]; then
        echo "INFO retrying Manager UI once after bounded SDL startup cleanup"
        sleep 0.5
        run_manager_ui
        ui_rc=$?
    fi
    if [ "$ui_rc" -ne 0 ]; then
        printf '%s\n' "ERROR manager UI exited $ui_rc" > "$RESULT"
        echo "ERROR: manager UI exited $ui_rc"
        pm_finish
        exit "$ui_rc"
    fi
    request="exit"
    if [ -s "$REQUEST" ]; then read -r request < "$REQUEST" || request="exit"; fi
    rm -f "$REQUEST"
    echo "Manager request: $request"
    case "$request" in
        play)
            "$BACKEND" activate-swap || true
            if [ -z "$PLAY" ]; then
                printf '%s\n' "ERROR working Morrowind.sh was not found in PORTS" > "$RESULT"
                report "PLAY MORROWIND" 0 0
                continue
            fi
            exec /bin/bash "$PLAY"
            ;;
        status) "$BACKEND" status || true ;;
        mods-scan) "$BACKEND" mods-scan || true ;;
        mods-apply) "$BACKEND" mods-apply || true ;;
        mod-toggle:*) "$BACKEND" mod-toggle "${request#mod-toggle:}" || true ;;
        mod-move:*)
            payload="${request#mod-move:}"
            ident="${payload%%:*}"
            delta="${payload##*:}"
            "$BACKEND" mod-move "$ident" "$delta" || true
            ;;
        install-navmesh) "$BACKEND" install-navmesh || true ;;
        install-swap) "$BACKEND" install-swap || true ;;
        setup-first-launch) "$BACKEND" setup-first-launch || true ;;
        build-navmesh)
            # Fallback only: V2.5 builds the navmesh inside the manager UI.
            # The generator is invoked through /bin/bash, so a missing execute
            # bit on an exFAT card can never make it look absent.
            generator=""
            for candidate in /mnt/SDCARD/Roms/PORTS/OpenMW_Generate_Full_Navmesh_3Worker.sh /mnt/sdcard/mmcblk1p1/Roms/PORTS/OpenMW_Generate_Full_Navmesh_3Worker.sh; do
                if [ -f "$candidate" ]; then generator="$candidate"; break; fi
            done
            if [ -z "$generator" ]; then
                printf '%s\n' "ERROR the three-worker navmesh generator was not found in the PORTS folder" > "$RESULT"
                report "NAVMESH BUILDER" 0 0
                continue
            fi
            echo "Handing the display to the standalone generator: $generator"
            rm -f "$PROGRESS" "$PROGRESS.tmp"
            # The manager UI has already exited and been reaped. Let KMS settle
            # before the generator's own SDL progress window starts.
            sleep 0.5
            run_with_launch_env "$LAUNCH_ENV" "$generator"
            nav_rc=$?
            echo "Generator exited: $nav_rc"
            if [ "$nav_rc" -eq 0 ]; then
                "$BACKEND" mark-navmesh || true
                printf '%s\n' "Navmesh build finished; profile recorded for the current data order" > "$RESULT"
                report "NAVMESH BUILDER" 1 0
            else
                printf '%s\n' "ERROR navmesh generator exited $nav_rc; existing database kept. See navmesh-generation-full-3worker.log" > "$RESULT"
                report "NAVMESH BUILDER" 0 "$nav_rc"
            fi
            ;;
        exit|"") pm_finish; exit 0 ;;
        *) printf '%s\n' "ERROR unknown UI request: $request" > "$RESULT" ;;
    esac
done
