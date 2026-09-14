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
PLAY=""

mkdir -p "$ROOT/launcher"
exec >>"$LOG" 2>&1
echo "===== OpenMW 0.51 Manager V2.1 started: $(date) ====="

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
# Exact display environment proven by openmw-navmesh-progress.
export LD_LIBRARY_PATH="/usr/trimui/lib:/mnt/SDCARD/System/lib:$ROOT/lib:$ROOT/libs:$ROOT/lib/aarch64"
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

while true; do
    "$BACKEND" status || true
    rm -f "$REQUEST"
    "$BIN"
    ui_rc=$?
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
