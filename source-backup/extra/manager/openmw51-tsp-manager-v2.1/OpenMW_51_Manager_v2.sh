#!/bin/bash
# OpenMW 0.51 TSP integrated manager Ports entry.
set +e
set +u
set +o pipefail 2>/dev/null || true

ROOT="${OPENMW51_GAMEDIR:-/mnt/SDCARD/data/ports/openmw51}"
BIN="$ROOT/bin/openmw51-manager-v2"
BACKEND="$ROOT/launcher/openmw51-manager-action-v2.sh"
REQUEST="$ROOT/launcher/request"
RESULT="$ROOT/launcher/last-result.txt"
LOG="$ROOT/launcher/manager-v2.log"
READY="$ROOT/launcher/ui-ready"
PIDFILE="$ROOT/launcher/manager-v2-wrapper.pid"
CHILDPID="$ROOT/launcher/manager-v2-ui.pid"
PLAY=""
UI_PID=""

mkdir -p "$ROOT/launcher"
exec >>"$LOG" 2>&1
echo "===== OpenMW 0.51 Manager V2.1 started: $(date) ====="

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
    rm -f "$CHILDPID" "$READY"
}
trap cleanup_manager EXIT
trap 'exit 130' HUP INT TERM

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

# Clean up a pre-repair manager that hung before it could accept controller input.
for old_ui in $(pidof openmw51-manager-v2 2>/dev/null); do
    case "$old_ui" in
        ''|*[!0-9]*) continue ;;
    esac
    echo "Stopping stale Manager UI PID $old_ui"
    kill "$old_ui" 2>/dev/null || true
    sleep 0.2
    kill -9 "$old_ui" 2>/dev/null || true
done

export PORT_DIR="$ROOT"
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

for candidate in /mnt/SDCARD/Roms/PORTS/Morrowind_51.sh /mnt/sdcard/mmcblk1p1/Roms/PORTS/Morrowind_51.sh; do
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
    "$BACKEND" status || true
    rm -f "$REQUEST"
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
                printf '%s\n' "ERROR working Morrowind_51.sh was not found" > "$RESULT"
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
        build-navmesh)
            generator=""
            for candidate in /mnt/SDCARD/Roms/PORTS/OpenMW_51_Generate_Full_Navmesh_3Worker.sh /mnt/sdcard/mmcblk1p1/Roms/PORTS/OpenMW_51_Generate_Full_Navmesh_3Worker.sh; do
                if [ -x "$candidate" ]; then generator="$candidate"; break; fi
            done
            if [ -z "$generator" ]; then
                printf '%s\n' "ERROR full three-worker navmesh generator is missing" > "$RESULT"
                continue
            fi
            /bin/bash "$generator"
            nav_rc=$?
            if [ "$nav_rc" -eq 0 ]; then
                "$BACKEND" mark-navmesh || true
            else
                printf '%s\n' "ERROR navmesh generator exited $nav_rc; existing DB retained" > "$RESULT"
            fi
            ;;
        exit|"") pm_finish; exit 0 ;;
        *) printf '%s\n' "ERROR unknown UI request: $request" > "$RESULT" ;;
    esac
done
