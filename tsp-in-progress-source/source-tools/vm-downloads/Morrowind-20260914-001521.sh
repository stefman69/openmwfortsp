#!/bin/bash
# >>> TSP_QUIET_V1 BEGIN
# Shipping: every proof line the launcher used to scatter over the SD card (tsp_prog.txt) goes into the one
# game log, the perf sampler (openmw_perf_latest.txt) and the stall ring dumps (tsp_ring/) stay off.
# quiet=off in $GAMEDIR/tsp_drawthread_policy.txt, or touch /mnt/SDCARD/tsp_quiet_off, brings them back.
TSP_QUIET=1
if grep -qs '^quiet=off' "/mnt/SDCARD/data/ports/openmw/tsp_drawthread_policy.txt" || [ -f /mnt/SDCARD/tsp_quiet_off ]; then TSP_QUIET=0; fi
if [ "$TSP_QUIET" = 1 ]; then TSP_PROG=/tmp/tsp_prog_early.$$; TSP_PROG_TEE=/dev/null; else TSP_PROG=/mnt/SDCARD/tsp_prog.txt; TSP_PROG_TEE=/mnt/SDCARD/tsp_prog.txt; fi
# <<< TSP_QUIET_V1 END
# TSP_INTOCC_ENV_V2 - every interior-occlusion knob from one file. Runs before the
# TSP_INTOCC_V1 block, which is inert while /mnt/SDCARD/tsp_intocc is absent.
if [ -f /mnt/SDCARD/tsp_intocc.env ]; then
  . /mnt/SDCARD/tsp_intocc.env
  echo "TSP_INTOCC_ENV: TSP_INTOCC=$TSP_INTOCC MINRMUL=$TSP_INTOCC_MINRMUL MAXOCC=$TSP_INTOCC_MAXOCC MAXTRI=$TSP_INTOCC_MAXTRI BUDGET=$TSP_INTOCC_BUDGET"
else
  echo "TSP_INTOCC_ENV: no /mnt/SDCARD/tsp_intocc.env, defaults apply"
fi
# TSP_LOADENV_V1 - the two switches openmw needs, delivered IN the launch chain.
# /mnt/SDCARD/tsp_iotune.conf has carried both for days and NOTHING sources that
# file: a bounded search found no reader, and /proc/<pid>/environ of a live game
# showed neither variable. Its sysctl-shaped entries only looked effective because
# kernel state is global and persists; every export in it was inert.
# Deliberately only these two. That conf also sets OPENMW_DEBUG_LEVEL=INFO,
# LIBGL_TSP_LOG=1 and TSP_FPS_OVERLAY=0, and switching ~15 never-live lines on at
# once is not one change.
# Off: touch /mnt/SDCARD/tsp_loadenv_off
if [ ! -f /mnt/SDCARD/tsp_loadenv_off ]; then
  export TSP_NO_LOADPURGE=1
  export TSP_RELOAD_MEM_FLOOR_KB=80000
  # read_ahead_kb reads 512 now but has NO writer on the card - it is a stale
  # kernel value that dies at the next reboot, taking the 09-07 readahead fix
  # (3.7x fewer faulting frames) with it. Re-apply it where it belongs.
  for tsp_raq in /sys/block/mmcblk0/queue/read_ahead_kb /sys/block/mmcblk1/queue/read_ahead_kb; do
    if [ -w "$tsp_raq" ]; then echo 512 > "$tsp_raq" 2>/dev/null; fi
  done
  echo "TSP_LOADENV_V1 armed NO_LOADPURGE=1 RELOAD_MEM_FLOOR_KB=120000 ra0=$(cat /sys/block/mmcblk0/queue/read_ahead_kb 2>/dev/null) ra1=$(cat /sys/block/mmcblk1/queue/read_ahead_kb 2>/dev/null)" >> "$TSP_PROG"
else
  echo "TSP_LOADENV_V1 disabled by /mnt/SDCARD/tsp_loadenv_off" >> "$TSP_PROG"
fi

# TSP_INTOCC_V1 mode file: 0/absent = upstream, 1 = interior occluders, 2 = 1 plus large-object tests
if [ -f /mnt/SDCARD/tsp_intocc ]; then
  TSP_INTOCC=$(cat /mnt/SDCARD/tsp_intocc)
  export TSP_INTOCC
  echo "TSP_INTOCC: mode $TSP_INTOCC"
else
  echo "TSP_INTOCC: unset, mode 0 (upstream behaviour)"
fi
# TSP_VBOHINT_V1 measurement only. No-op unless the arm file exists.
if [ -f /mnt/SDCARD/tsp_vbo_on ]; then
  OSG_VERTEX_BUFFER_HINT=VERTEX_BUFFER_OBJECT
  export OSG_VERTEX_BUFFER_HINT
  echo "TSP_VBOHINT: ARMED - forcing VBO for all drawables"
else
  echo "TSP_VBOHINT: disarmed - OSG default vertex path"
fi
# TSP_OSGSTATS_V1 measurement only. No-op unless the arm file exists.
if [ -f /mnt/SDCARD/tsp_osgstats_on ]; then
  OPENMW_OSG_STATS_FILE=/tmp/tsp_osgstats.txt
  OPENMW_OSG_STATS_LIST="rendering;cameraobjects;frame_rate;engine"
  export OPENMW_OSG_STATS_FILE OPENMW_OSG_STATS_LIST
  echo "TSP_OSGSTATS: ARMED -> $OPENMW_OSG_STATS_FILE"
else
  echo "TSP_OSGSTATS: disarmed (touch /mnt/SDCARD/tsp_osgstats_on to arm)"
fi
export OPENMW_TSP_NAVMESHDB=/mnt/UDISK/openmw-nav/navmesh.db
export OPENMW_TSP_ENABLE_NAVIGATOR=1

# OpenMW 0.51 fixed separate port root.
# Do not auto-create alternate game roots; a bad path should fail instead of
# silently creating an empty phantom directory.
GAMEDIR="/mnt/SDCARD/data/ports/openmw"

if [ ! -d "$GAMEDIR" ]; then
    FALLBACK_LOG="/tmp/openmw_log.txt"
    {
        echo "Launcher entered at: $(date)"
        echo "ERROR: OpenMW 0.51 game directory does not exist:"
        echo "  $GAMEDIR"
    } > "$FALLBACK_LOG" 2>&1
    exit 1
fi

LOG_FILE="$GAMEDIR/openmw_log.txt"
: > "$LOG_FILE"
exec >> "$LOG_FILE" 2>&1
if [ "$TSP_QUIET" = 1 ]; then [ -f "$TSP_PROG" ] && { cat "$TSP_PROG"; rm -f "$TSP_PROG"; }; TSP_PROG="$LOG_FILE"; echo "TSP_QUIET_V1 on: proof lines in this log only, perf sampler off, ring dumps off"; else echo "TSP_QUIET_V1 off (policy): side files as before"; fi   # TSP_QUIET_V1 OPEN

echo "Launcher entered at: $(date)"
echo "Shell: $0"
echo "Bash version: ${BASH_VERSION:-unknown}"
echo "Arguments: $*"
echo "Log file: $LOG_FILE"

cd "$GAMEDIR"

# Flattened OpenMW 0.51 layout: the port root itself is the runtime root.
RUNTIME="$GAMEDIR"
OPENMW_BIN="$GAMEDIR/bin/openmw-0.51"
OPENMW_RESOURCES="$GAMEDIR/resources"
OPENMW_LIB="$GAMEDIR/lib"
CONFIG_DIR="$GAMEDIR/config"
SAVE_DIR="$GAMEDIR/savegame"
TEXCACHE_DIR="$GAMEDIR/texcache"
PATH_MIGRATOR="$GAMEDIR/launcher/openmw-clean-path-migrate.py"
CONTROL_HELPER="$GAMEDIR/tsp_openmw_controls"
CONTROL_HELPER_LOG="/tmp/tsp_openmw_controls.log"
CONTROL_HELPER_PID=""
OPENMW_PID=""

# TSP_INTERNAL_RESOLUTION_RESTART_MARKER_051_V20R4
RESOLUTION_RESTART_MARKER="$GAMEDIR/.openmw-resolution-restart"
# Logging already started at the top of the launcher and remains on the
# same root-level text file for the entire run.

echo
echo "=========================================="
echo "Starting OpenMW 0.51 on TrimUI Smart Pro"
echo "Launcher: Morrowind.sh"
echo "Mode: native OpenMW controller + hybrid mouse/text helper"
echo "Date: $(date)"
echo "Game directory: $GAMEDIR"
echo "Runtime: $RUNTIME"
echo "=========================================="

export XDG_RUNTIME_DIR="/tmp/runtime-root"
# >>> TSP_DRAWTHREAD_V1 MODEL BEGIN (was: export OSG_THREADING=SingleThreaded)
# OSG draw traversal on its own thread - upstream OpenMW desktop default; SingleThreaded serialised
# update+cull+draw on one core. Policy $GAMEDIR/tsp_drawthread_policy.txt: model=single = old model,
# core=off = do not bring a second fast core online, pin=off = leave thread placement alone,
# idle=main = park SCHED_IDLE threads (navmesh updater) on the main core so they only get its leftover cycles.
if grep -qs '^model=single' "$GAMEDIR/tsp_drawthread_policy.txt"; then
    export OSG_THREADING=SingleThreaded
else
    export OSG_THREADING=DrawThreadPerContext
fi
echo "TSP_DRAWTHREAD_V1 model=$OSG_THREADING policy=[$(cat "$GAMEDIR/tsp_drawthread_policy.txt" 2>/dev/null | tr '\n' ' ')]"
# <<< TSP_DRAWTHREAD_V1 MODEL END

mkdir -p \
    "$XDG_RUNTIME_DIR" \
    "$CONFIG_DIR" \
    "$CONFIG_DIR/openmw" \
    "$SAVE_DIR" \
    "$SAVE_DIR/data" \
    "$SAVE_DIR/screenshots" \
    "$TEXCACHE_DIR"

chmod 0700 "$XDG_RUNTIME_DIR"

export XDG_DATA_HOME="$CONFIG_DIR"
export XDG_CONFIG_HOME="$CONFIG_DIR"
export OPENMW_RESOURCES="$OPENMW_RESOURCES"

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

echo "PortMaster control folder: $controlfolder"

# control.txt references ${PORT_DIR} immediately. Define it before sourcing.
export PORT_DIR="$GAMEDIR"

echo "Launcher revision: openmw-clean-layout-2026-09-06-v29-sdl-sensor-fallback"
echo "PORT_DIR before loading PortMaster: $PORT_DIR"

if [ -f "$controlfolder/control.txt" ]; then
    # PortMaster probes unset variables and tests whether sudo exists.
    # Source it with errexit/nounset disabled so those probes can complete.
    set +e
    set +u
    set +o pipefail 2>/dev/null || true

    source "$controlfolder/control.txt"
    CONTROL_TXT_RESULT=$?

    echo "PortMaster control.txt returned: $CONTROL_TXT_RESULT"
else
    echo "WARNING: PortMaster control.txt was not found."
fi

if type get_controls >/dev/null 2>&1; then
    get_controls 2>/dev/null || true
fi

if [ -n "${CFW_NAME:-}" ] && [ -f "${controlfolder}/mod_${CFW_NAME}.txt" ]; then
    source "${controlfolder}/mod_${CFW_NAME}.txt"
fi

if ! type pm_finish >/dev/null 2>&1; then
    pm_finish() { true; }
fi

if ! type pm_gptokeyb_finish >/dev/null 2>&1; then
    pm_gptokeyb_finish() {
        killall -9 gptokeyb2 gptokeyb 2>/dev/null || true
    }
fi

echo "CFW_NAME=${CFW_NAME:-unknown}"
echo "DEVICE_NAME=${DEVICE_NAME:-unknown}"
echo "DEVICE_CPU=${DEVICE_CPU:-unknown}"
echo "DEVICE_ARCH=${DEVICE_ARCH:-unknown}"

killall -9 gptokeyb2 gptokeyb 2>/dev/null || true
pkill -9 -f "$GAMEDIR/tsp_openmw_controls" 2>/dev/null || true
pkill -9 -f "$GAMEDIR/openmw_cursor" 2>/dev/null || true

# TSP_SYSTEM_SDL_051
# The working OpenMW 0.48 TSP launcher deliberately avoids bundled SDL.
# CrossMix/TrimUI provides the SDL build configured for the handheld display.
rm -f "$OPENMW_LIB"/libSDL2* 2>/dev/null || true
rm -f "$GAMEDIR/lib"/libSDL2* 2>/dev/null || true
rm -f "$GAMEDIR/libs"/libSDL2* 2>/dev/null || true

export DEVICE_ARCH="${DEVICE_ARCH:-aarch64}"
export PATH="$RUNTIME/bin:$GAMEDIR:$GAMEDIR/bin.${DEVICE_ARCH}:$PATH"
export LD_LIBRARY_PATH="$OPENMW_LIB:$GAMEDIR/libs:$GAMEDIR/lib/aarch64:${LD_LIBRARY_PATH:-}"

if [ -d "$GAMEDIR/libs.${DEVICE_ARCH}" ]; then
    export LD_LIBRARY_PATH="$GAMEDIR/libs.${DEVICE_ARCH}:$LD_LIBRARY_PATH"
fi

if [ -n "${CFW_NAME:-}" ] && [ -d "$GAMEDIR/libs.${CFW_NAME}.${DEVICE_ARCH}" ]; then
    export LD_LIBRARY_PATH="$GAMEDIR/libs.${CFW_NAME}.${DEVICE_ARCH}:$LD_LIBRARY_PATH"
fi

if [ -n "${CFW_NAME:-}" ] && [ -d "$GAMEDIR/libs.${CFW_NAME}" ]; then
    export LD_LIBRARY_PATH="$GAMEDIR/libs.${CFW_NAME}:$LD_LIBRARY_PATH"
fi

# TSP_SDL2_OVERRIDE_051_V29
# Drop-in location for a sensor-capable SDL2. It is never purged by the block
# above, so a replacement library survives relaunches. Only active if present.
TSP_SDL2_DIR="$GAMEDIR/lib.sdl2"

if [ -d "$TSP_SDL2_DIR" ]; then
    export LD_LIBRARY_PATH="$TSP_SDL2_DIR:$LD_LIBRARY_PATH"
    echo "SDL2 override directory active: $TSP_SDL2_DIR"
fi

export OSG_LIBRARY_PATH="$GAMEDIR/osgPlugins-3.6.5"

CONTROLLER_DB_FILE="$GAMEDIR/gamecontrollerdb_tsp.txt"

cat > "$CONTROLLER_DB_FILE" <<'EOF_CONTROLLER_DB'
0300a3845e0400008e02000014010000,TRIMUI Player1,a:b1,b:b0,x:b3,y:b2,back:b7,start:b6,guide:b8,leftstick:b9,rightstick:b10,leftshoulder:b4,rightshoulder:b5,lefttrigger:a2,righttrigger:a5,leftx:a0,lefty:a1,rightx:a3,righty:a4,dpup:h0.1,dpdown:h0.4,dpleft:h0.8,dpright:h0.2,platform:Linux,
EOF_CONTROLLER_DB

export SDL_GAMECONTROLLERCONFIG_FILE="$CONTROLLER_DB_FILE"
export SDL_GAMECONTROLLERCONFIG="$(cat "$CONTROLLER_DB_FILE")"

export OPENMW_DECOMPRESS_TEXTURES=1
export LIBGL_STREAM=1
export LIBGL_NOTEST=1
export LIBGL_FORCENPOT=0
export LIBGL_MIPMAP=5
export LIBGL_TEXPATH="$TEXCACHE_DIR/"
export LIBGL_RECOMPTEX=0
export LIBGL_NOMIPMAPS=0
export LIBGL_SHRINK=0

echo
echo "=========================================="
echo "PortMaster graphics setup"
echo "=========================================="

if [ -n "${CFW_NAME:-}" ] && [ -f "${controlfolder}/libgl_${CFW_NAME}.txt" ]; then
    source "${controlfolder}/libgl_${CFW_NAME}.txt"
elif [ -f "${controlfolder}/libgl_default.txt" ]; then
    source "${controlfolder}/libgl_default.txt"
else
    echo "WARNING: No PortMaster GL4ES configuration file was found."
fi

echo "LD_LIBRARY_PATH:"
echo "$LD_LIBRARY_PATH"
echo "OSG_LIBRARY_PATH:"
echo "$OSG_LIBRARY_PATH"
echo "=========================================="

# ==========================================================================
# TSP_SDL_SENSOR_FALLBACK_051_V29
#
# OpenMW 0.49+ calls SDL_Init(... | SDL_INIT_SENSOR). CrossMix ships an SDL2
# built WITH sensor support, so that succeeds. Stock TrimUI OS falls back to
# /usr/trimui/lib, whose SDL2 is built WITHOUT it, and the engine aborts:
#     Fatal error: Could not initialize SDL! SDL not built with sensor support
#
# SDL2 only embeds that message when compiled with SDL_SENSOR_DISABLED, so its
# presence in the library the loader will actually pick is a reliable "this
# device needs the shim" signal. When it is there, lib/libtsp_sdl_sensor_shim.so
# is preloaded ahead of everything else and masks the flag out of SDL_Init.
#
#   TSP_SDL_SENSOR_SHIM=1  force the shim on
#   TSP_SDL_SENSOR_SHIM=0  force it off
#   unset                  decide from the library itself (default)
# ==========================================================================
TSP_SDL_SHIM="$GAMEDIR/lib/libtsp_sdl_sensor_shim.so"
TSP_SDL_SHIM_ACTIVE=0
TSP_SDL2_PATH=""

tsp_sdl2_lacks_sensor() {
    [ -e "$1" ] || return 1
    if grep -q 'SDL not built with sensor support' "$1" 2>/dev/null; then
        return 0
    fi
    strings "$1" 2>/dev/null | grep -q 'SDL not built with sensor support'
}

tsp_find_sdl2() {
    TSP_OLD_IFS="$IFS"
    IFS=:
    for d in $LD_LIBRARY_PATH; do
        [ -n "$d" ] || continue
        if [ -e "$d/libSDL2-2.0.so.0" ]; then
            IFS="$TSP_OLD_IFS"
            printf '%s\n' "$d/libSDL2-2.0.so.0"
            return 0
        fi
    done
    IFS="$TSP_OLD_IFS"

    for d in /usr/trimui/lib /mnt/SDCARD/System/lib /usr/lib /lib /lib64; do
        if [ -e "$d/libSDL2-2.0.so.0" ]; then
            printf '%s\n' "$d/libSDL2-2.0.so.0"
            return 0
        fi
    done
    return 1
}

echo
echo "=========================================="
echo "SDL2 SENSOR SUPPORT"
echo "=========================================="

TSP_SDL2_PATH="$(tsp_find_sdl2)"

if [ -z "$TSP_SDL2_PATH" ]; then
    echo "SDL2 in use:      NOT FOUND on any library path"
else
    echo "SDL2 in use:      $TSP_SDL2_PATH"
fi

case "${TSP_SDL_SENSOR_SHIM:-auto}" in
    1)
        TSP_SDL_SHIM_ACTIVE=1
        echo "Sensor support:   forced shim (TSP_SDL_SENSOR_SHIM=1)"
        ;;
    0)
        TSP_SDL_SHIM_ACTIVE=0
        echo "Sensor support:   shim disabled (TSP_SDL_SENSOR_SHIM=0)"
        ;;
    *)
        if [ -n "$TSP_SDL2_PATH" ] && tsp_sdl2_lacks_sensor "$TSP_SDL2_PATH"; then
            TSP_SDL_SHIM_ACTIVE=1
            echo "Sensor support:   MISSING from this SDL2 (stock OS build)"
        else
            TSP_SDL_SHIM_ACTIVE=0
            echo "Sensor support:   present (CrossMix-style SDL2)"
        fi
        ;;
esac

if [ "$TSP_SDL_SHIM_ACTIVE" = "1" ]; then
    if [ -f "$TSP_SDL_SHIM" ]; then
        echo "SDL sensor shim:  ACTIVE ($TSP_SDL_SHIM)"
    else
        TSP_SDL_SHIM_ACTIVE=0
        echo "SDL sensor shim:  MISSING -- $TSP_SDL_SHIM"
        echo "This device's SDL2 has no sensor support, so OpenMW will abort with"
        echo "  Could not initialize SDL! SDL not built with sensor support"
        echo "Reinstall the port, or drop a sensor-capable libSDL2-2.0.so.0 into"
        echo "  $GAMEDIR/lib.sdl2/"
    fi
else
    echo "SDL sensor shim:  not needed"
fi
echo "=========================================="

export OSG_NOTIFY_LEVEL=FATAL
export OPENMW_DEBUG_LEVEL=warning
export OPENMW_RECAST_MAX_LOG_LEVEL=warning

# OpenMW 0.51 uses its own isolated copy of the Morrowind game data.
TARGET_DATA_DIR="$GAMEDIR/data/Data Files"

# Support a flattened data folder as a fallback, but prefer the normal
# Morrowind "Data Files" directory when it exists.
if [ ! -d "$TARGET_DATA_DIR" ] && [ -d "$GAMEDIR/data" ]; then
    TARGET_DATA_DIR="$GAMEDIR/data"
fi

if [ ! -d "$TARGET_DATA_DIR" ]; then
    echo "ERROR: OpenMW 0.51 Morrowind data directory was not found."
    echo "Expected one of:"
    echo "  $GAMEDIR/data/Data Files"
    echo "  $GAMEDIR/data"
    pm_gptokeyb_finish
    pm_finish
    exit 1
fi

if [ ! -f "$TARGET_DATA_DIR/Morrowind.esm" ]; then
    echo "ERROR: Morrowind.esm was not found in:"
    echo "  $TARGET_DATA_DIR"
    pm_gptokeyb_finish
    pm_finish
    exit 1
fi

if [ ! -f "$TARGET_DATA_DIR/Morrowind.bsa" ]; then
    echo "ERROR: Morrowind.bsa was not found in:"
    echo "  $TARGET_DATA_DIR"
    pm_gptokeyb_finish
    pm_finish
    exit 1
fi

echo "Morrowind data directory: $TARGET_DATA_DIR"
echo "Verified Morrowind.esm: $TARGET_DATA_DIR/Morrowind.esm"
echo "Verified Morrowind.bsa: $TARGET_DATA_DIR/Morrowind.bsa"

# TSP_POSIX_V1 - was a bash array, which busybox ash cannot parse: the stock-OS
# card runs this launcher under ash, not bash, and died here with
# "line 422: syntax error: unexpected \"(\"" before the game ever started.
#
# Fed by a heredoc, NOT a pipe. A pipe would put the loop in a subshell and the
# exit 1 below would leave the launcher running with a missing runtime file.
# The heredoc keeps the loop in the current shell, and read -r with IFS unset
# keeps paths containing spaces intact.
while IFS= read -r required; do
    [ -n "$required" ] || continue
    if [ ! -e "$required" ]; then
        echo "ERROR: Required OpenMW 0.51 runtime item is missing:"
        echo "  $required"
        pm_gptokeyb_finish
        pm_finish
        exit 1
    fi
done <<TSP_REQEOF
$OPENMW_BIN
$CONTROL_HELPER
$OPENMW_RESOURCES
$OPENMW_RESOURCES/defaults.bin
$OPENMW_RESOURCES/vfs
$OPENMW_RESOURCES/vfs-mw
$OPENMW_LIB/libMyGUIEngine.so.3.4.3
$OPENMW_LIB/libstdc++.so.6
$OPENMW_LIB/libgcc_s.so.1
TSP_REQEOF

for required_lib in \
    libOpenThreads.so.21 \
    libosg.so.162 \
    libosgDB.so.162 \
    libosgGA.so.162 \
    libosgParticle.so.162 \
    libosgShadow.so.162 \
    libosgText.so.162 \
    libosgUtil.so.162 \
    libosgViewer.so.162
do
    if [ ! -s "$OPENMW_LIB/$required_lib" ]; then
        echo "ERROR: Missing or invalid OpenMW 0.51 OSG library:"
        echo "  $OPENMW_LIB/$required_lib"
        pm_gptokeyb_finish
        pm_finish
        exit 1
    fi
done

chmod +x "$OPENMW_BIN" "$CONTROL_HELPER"

BASE_CFG="$GAMEDIR/openmw.base.cfg"
ACTIVE_CFG="$GAMEDIR/openmw.cfg"
LOCAL_CFG="$GAMEDIR/bin/openmw.cfg"
USER_CFG="$CONFIG_DIR/openmw.cfg"
COMPAT_USER_CFG="$CONFIG_DIR/openmw/openmw.cfg"

if [ ! -f "$BASE_CFG" ]; then
    echo "ERROR: Missing complete OpenMW 0.51 base config:"
    echo "  $BASE_CFG"
    pm_gptokeyb_finish
    pm_finish
    exit 1
fi

if [ ! -f "$ACTIVE_CFG" ]; then
    echo "ERROR: Missing persistent OpenMW 0.51 main config:"
    echo "  $ACTIVE_CFG"
    pm_gptokeyb_finish
    pm_finish
    exit 1
fi

# TSP_CLEAN_LAYOUT_CONFIG_MIGRATION_V1
# The directory rename also has to update absolute paths persisted inside the
# main/user configurations.  Perform that exact, transactional migration before
# copying the executable-local config; otherwise OpenMW sees the new launcher
# root but still searches the retired openmw51 tree for data and saves.
if [ ! -x "$PATH_MIGRATOR" ]; then
    echo "ERROR: Clean-layout configuration migrator is missing or not executable:"
    echo "  $PATH_MIGRATOR"
    pm_gptokeyb_finish
    pm_finish
    exit 1
fi

if ! python3 "$PATH_MIGRATOR" "$GAMEDIR"; then
    echo "ERROR: Persistent OpenMW paths could not be migrated safely."
    echo "No game process was started. Any partial migration was rolled back."
    pm_gptokeyb_finish
    pm_finish
    exit 1
fi

# OpenMW loads a config beside the executable. Keep that runtime-local copy
# synchronized from the persistent top-level 0.51 main config.
# OpenMW 0.51 loads builtin.omwscripts internally. An explicit content= entry
# from older OpenMW configs makes 0.51 abort as a duplicate.
sed -i '/^[[:space:]]*content=builtin\.omwscripts[[:space:]]*$/d' "$ACTIVE_CFG"
sed -i '/^[[:space:]]*script-blacklist=/d' "$ACTIVE_CFG"

cp -f "$ACTIVE_CFG" "$LOCAL_CFG"

echo "Synchronized persistent main config:"
echo "  $ACTIVE_CFG"
echo "to executable-local config:"
echo "  $LOCAL_CFG"

echo "Main config fallback count:"
grep -c '^fallback=' "$LOCAL_CFG" 2>/dev/null || true
echo "FontColor_color_header:"
grep -n '^fallback=FontColor_color_header,' "$LOCAL_CFG" 2>/dev/null | head -1 || true

write_initial_user_cfg() {
    CFG_FILE="$1"
    mkdir -p "$(dirname "$CFG_FILE")"

    cat > "$CFG_FILE" <<EOF_USER_CFG
fallback-archive=Morrowind.bsa
content=Morrowind.esm
EOF_USER_CFG

    if [ -f "$TARGET_DATA_DIR/Tribunal.esm" ]; then
        [ -f "$TARGET_DATA_DIR/Tribunal.bsa" ] && \
            echo "fallback-archive=Tribunal.bsa" >> "$CFG_FILE"
        echo "content=Tribunal.esm" >> "$CFG_FILE"
    fi

    if [ -f "$TARGET_DATA_DIR/Bloodmoon.esm" ]; then
        [ -f "$TARGET_DATA_DIR/Bloodmoon.bsa" ] && \
            echo "fallback-archive=Bloodmoon.bsa" >> "$CFG_FILE"
        echo "content=Bloodmoon.esm" >> "$CFG_FILE"
    fi
}

# USER_CFG is the canonical persistent content/mod list.
# The full main/base config already contains content=builtin.omwscripts.
# It must not also appear in a user/content config.
if [ ! -f "$USER_CFG" ]; then
    write_initial_user_cfg "$USER_CFG"
    echo "Created persistent user content config:"
    echo "  $USER_CFG"
else
    echo "Keeping existing persistent user content config:"
    echo "  $USER_CFG"
fi

# Repair the exact stale entry that caused:
# "Content file specified more than once: builtin.omwscripts"
sed -i '/^[[:space:]]*content=builtin\.omwscripts[[:space:]]*$/d' "$USER_CFG"

# The nested location is compatibility-only. Keep it identical to USER_CFG so
# an old full/base config cannot remain there and reintroduce duplicate content.
mkdir -p "$(dirname "$COMPAT_USER_CFG")"
cp -f "$USER_CFG" "$COMPAT_USER_CFG"

echo "Synchronized compatibility user content config:"
echo "  $COMPAT_USER_CFG"

echo "Explicit builtin.omwscripts counts (OpenMW 0.51 expects zero):"
echo -n "  main: "
grep -c '^content=builtin\.omwscripts$' "$LOCAL_CFG" 2>/dev/null || true
echo -n "  user: "
grep -c '^content=builtin\.omwscripts$' "$USER_CFG" 2>/dev/null || true
echo -n "  compat: "
grep -c '^content=builtin\.omwscripts$' "$COMPAT_USER_CFG" 2>/dev/null || true

cp -f "$OPENMW_RESOURCES/defaults.bin" "$CONFIG_DIR/defaults.bin"
cp -f "$OPENMW_RESOURCES/defaults.bin" "$CONFIG_DIR/openmw/defaults.bin"

SETTINGS_FILE="$CONFIG_DIR/settings.cfg"

python3 - "$SETTINGS_FILE" <<'PY'
import configparser
import os
import sys

path = sys.argv[1]
config = configparser.ConfigParser(interpolation=None, strict=False, empty_lines_in_values=False)
config.optionxform = str

if os.path.isfile(path):
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as handle:
            config.read_file(handle)
    except Exception as exc:
        print("Warning: could not parse existing settings.cfg:", exc)

values = {
    "Shaders": {
        "force shaders": "false",
        "force per pixel lighting": "false",
        "clamp lighting": "false",
        "auto use object normal maps": "false",
        "auto use object specular maps": "false",
        "auto use terrain normal maps": "false",
        "auto use terrain specular maps": "false",
        "apply lighting to environment maps": "false",
    },
    "Water": {
        "refraction": "false",
        "refraction": "false",
        "rtt size": "128",
        "reflection detail": "0",
    },
    "Shadows": {
        "enable shadows": "false",
        "actor shadows": "false",
        "player shadows": "false",
        "terrain shadows": "false",
        "object shadows": "false",
        "indoor shadows": "false",
    },
    "Post Processing": {"enabled": "false"},
    "Video": {
        "antialiasing": "0",
        "vsync": "false",
        "fullscreen": "true",
        "window border": "false",
    },
    "Terrain": {"distant terrain": "true"},
    "Input": {
        "enable controller": "true",
        "gamepad cursor speed": "0.35",
        "joystick dead zone": "0.05",
        "grab cursor": "true",
    },
    "GUI": {
        "controller menus": "true",
        "controller tooltips": "true",
    },
}

for section, settings in values.items():
    if not config.has_section(section):
        config.add_section(section)
    for key, value in settings.items():
        config.set(section, key, value)

# TSP_INTERNAL_RESOLUTION_PERSIST_051_V20R4
#
# Keep the internal resolution already stored in settings.cfg.
# Only resolutions supplied by the TSP V20 build are considered valid.
allowed_resolutions = {
    ("1280", "720"),
    ("1152", "648"),
    ("1024", "576"),
    ("960", "540"),
    ("800", "450"),
    ("640", "360"),
}

if not config.has_section("Video"):
    config.add_section("Video")

resolution_x = config.get(
    "Video",
    "resolution x",
    fallback="1280",
).strip()

resolution_y = config.get(
    "Video",
    "resolution y",
    fallback="720",
).strip()

selected_resolution = (resolution_x, resolution_y)

if selected_resolution not in allowed_resolutions:
    print(
        "TSP resolution persistence: invalid",
        resolution_x + "x" + resolution_y,
        "-> using 1280x720",
    )
    selected_resolution = ("1280", "720")
else:
    print(
        "TSP resolution persistence: preserving",
        selected_resolution[0] + "x" + selected_resolution[1],
    )

config.set(
    "Video",
    "resolution x",
    selected_resolution[0],
)

config.set(
    "Video",
    "resolution y",
    selected_resolution[1],
)

os.makedirs(os.path.dirname(path), exist_ok=True)
tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8", newline="\n") as handle:
    config.write(handle, space_around_delimiters=True)
os.replace(tmp, path)
print("Applied OpenMW 0.51 settings:", path)
PY

rm -f "$CONFIG_DIR/openmw/settings.cfg"

CONTROLLER_PROFILE_MARKER="$CONFIG_DIR/.tsp-native-controller-profile-v1"

if [ ! -f "$CONTROLLER_PROFILE_MARKER" ]; then
    [ -f "$CONFIG_DIR/input_v3.xml" ] && mv -f "$CONFIG_DIR/input_v3.xml" "$CONFIG_DIR/input_v3.before-native-controller.xml"
    [ -f "$CONFIG_DIR/openmw/input_v3.xml" ] && mv -f "$CONFIG_DIR/openmw/input_v3.xml" "$CONFIG_DIR/openmw/input_v3.before-native-controller.xml"
    touch "$CONTROLLER_PROFILE_MARKER"
    echo "Reset OpenMW 0.51 controller bindings."
fi

echo
echo "=========================================="
echo "Final OpenMW 0.51 launch environment"
echo "=========================================="
echo "Executable: $OPENMW_BIN"
echo "Resources: $OPENMW_RESOURCES"
echo "Libraries: $OPENMW_LIB"
echo "Config: $CONFIG_DIR"
echo "Save directory: $SAVE_DIR"
echo "Combined log: $LOG_FILE"
echo "Controller mode: native OpenMW 0.51 + TSP hybrid helper"
echo "gptokeyb2: disabled"
echo "TSP hybrid helper: $CONTROL_HELPER"
echo "TSP helper log: $CONTROL_HELPER_LOG"
echo "SDL_GAMECONTROLLERCONFIG_FILE=$SDL_GAMECONTROLLERCONFIG_FILE"
echo "LD_LIBRARY_PATH=$LD_LIBRARY_PATH"
echo "=========================================="

if type pm_platform_helper >/dev/null 2>&1; then
    pm_platform_helper "$OPENMW_BIN"
else
    echo "WARNING: pm_platform_helper is unavailable."
fi

cleanup_helper() {
    if [ -n "${CONTROL_HELPER_PID:-}" ] && kill -0 "$CONTROL_HELPER_PID" 2>/dev/null; then
        echo "Stopping TSP hybrid controller helper (pid $CONTROL_HELPER_PID)..."
        kill "$CONTROL_HELPER_PID" 2>/dev/null || true
        sleep 0.1
        kill -9 "$CONTROL_HELPER_PID" 2>/dev/null || true
        wait "$CONTROL_HELPER_PID" 2>/dev/null || true
    fi
}

cleanup_children() {
    tsp_cpu_governor_restore 2>/dev/null || true
    [ -n "${TSP_DRAW_ONLINED:-}" ] && { echo 0 > "$TSP_SYS_CPU/cpu$TSP_DRAW_ONLINED/online" 2>/dev/null; echo "TSP_DRAWTHREAD_V1 cpu$TSP_DRAW_ONLINED back offline (signal path)"; }   # TSP_DRAWTHREAD_V1 CLEAN
    tsp_cpuclock_restore 2>/dev/null || true   # TSP_CPUCLOCK_V1 CLEAN
    tsp_lever_restore 2>/dev/null || true
    cleanup_helper
    if [ -n "${OPENMW_PID:-}" ] && kill -0 "$OPENMW_PID" 2>/dev/null; then
        echo "Stopping OpenMW child process (pid $OPENMW_PID)..."
        kill "$OPENMW_PID" 2>/dev/null || true
        sleep 0.2
        kill -9 "$OPENMW_PID" 2>/dev/null || true
        wait "$OPENMW_PID" 2>/dev/null || true
    fi
}

handle_launcher_signal() {
    echo "Launcher received a termination signal."
    cleanup_children
    exit 143
}

trap handle_launcher_signal INT TERM HUP

# Remove any stale helper left behind by an interrupted previous launch.
pkill -9 -f "$CONTROL_HELPER" 2>/dev/null || true
rm -f "$CONTROL_HELPER_LOG" 2>/dev/null || true

echo "Starting TSP hybrid controller helper..."
"$CONTROL_HELPER" "$CONTROL_HELPER_LOG" &
CONTROL_HELPER_PID=$!

sleep 0.4

if ! kill -0 "$CONTROL_HELPER_PID" 2>/dev/null; then
    echo "ERROR: TSP hybrid controller helper exited during startup."
    if [ -f "$CONTROL_HELPER_LOG" ]; then
        echo "----- TSP helper log -----"
        cat "$CONTROL_HELPER_LOG"
        echo "----- end TSP helper log -----"
    fi
    pm_gptokeyb_finish
    pm_finish
    exit 1
fi

echo "TSP hybrid helper running as pid: $CONTROL_HELPER_PID"
echo "Controls:"
echo "  MENU+START = toggle hybrid mouse/text mode"
echo "  START+SELECT held 2 seconds = emergency terminate OpenMW"

sleep 0.2


# TSP_CURSOR_LAUNCHER_DEBUG_V1
# Disabled for V23 macro1 performance/raycast validation.
# Cursor functionality itself is unchanged.


# >>> TSP_VISGRID_V24_ROOM_RESIDENCY BEGIN
# Fixed V24 profile: raw navmesh-sector room residency + continuous 5/6-ray learning.
TSP_VISGRID_DIR="$GAMEDIR/mods/TSPInteriorVisGrid/scripts/TSPInteriorVisGrid"
TSP_VISGRID_LIVE="$TSP_VISGRID_DIR/visgrid.lua"
TSP_VISGRID_SELECTED="$TSP_VISGRID_DIR/v30_profiles/visgrid-v30-floor-actor-roomwake.lua"
if [ ! -s "$TSP_VISGRID_SELECTED" ]; then
    echo "ERROR: V24 room-residency profile is missing:"
    echo "  $TSP_VISGRID_SELECTED"
    exit 72
fi
TSP_VISGRID_SELECTED_SHA="$(sha256sum "$TSP_VISGRID_SELECTED" | awk 'NF {print $1; exit}')"
TSP_VISGRID_LIVE_SHA=""
[ -s "$TSP_VISGRID_LIVE" ] && TSP_VISGRID_LIVE_SHA="$(sha256sum "$TSP_VISGRID_LIVE" | awk 'NF {print $1; exit}')"
if [ "$TSP_VISGRID_SELECTED_SHA" != "$TSP_VISGRID_LIVE_SHA" ]; then
    cp -f "$TSP_VISGRID_SELECTED" "$TSP_VISGRID_LIVE.v24-new"
    chmod 644 "$TSP_VISGRID_LIVE.v24-new" 2>/dev/null || true
    mv -f "$TSP_VISGRID_LIVE.v24-new" "$TSP_VISGRID_LIVE"
    sync
fi
export TSP_OBJECT_DIAG=0  # V26 compact diagnostics only
echo "Visgrid Profile=v30-floor-actor-roomwake"
echo "Visgrid SHA=$(sha256sum "$TSP_VISGRID_LIVE" | awk 'NF {print $1; exit}')"
echo "Visgrid room policy=V26 hard delete; FLOOR authority + earlier same-floor portal prewake + actor hibernation"
# <<< TSP_VISGRID_V24_ROOM_RESIDENCY END

echo "Launching OpenMW 0.51..."








# >>> TSP_V19_RUNTIME_PROFILE BEGIN

# >>> TSP_V23_QUIET_DIAGNOSTICS BEGIN
#
# Retained while profiling:
#   - TSP_VISGRID_V23PERF Lua ray/performance telemetry
#   - low-overhead tsp_perf_sampler
#   - on-screen FPS overlay
#
# Unrelated diagnostic systems are forced OFF.
export TSP_TEXTURE_DEBUG=0
export TSP_OBJECT_DIAG=0  # V26 compact diagnostics only  # TSP_OBJECT_DIAG_051_V1 temporary object/render/pick trace
unset OPENMW_OSG_STATS_FILE OPENMW_OSG_STATS_LIST
# <<< TSP_V23_QUIET_DIAGNOSTICS END


# Normal gameplay: expensive diagnostic samplers OFF.

# Keep FPS visible for initial benchmarking.

# Failed GL4ES intermediary framebuffer experiment stays OFF.
unset LIBGL_FB
unset LIBGL_FBO
unset LIBGL_RECYCLEFBO

# >>> Deep diagnostics can temporarily be restored with:

# <<< TSP_V19_RUNTIME_PROFILE END

# TSP_GL4ES_DYNAMIC_INTERNAL_SCALE_051_V21
#
# OpenMW/SDL stays physically 1280x720.
# The selected Video resolution controls GL4ES's intermediary framebuffer.
tsp_apply_internal_render_scale() {
    # TSP_V33_FPS_TEXTURE_BENCHMARK

    TSP_INTERNAL_X="$(
        awk -F= '
            /^\[Video\]/ {
                video=1
                next
            }

            /^\[/ {
                video=0
            }

            video {
                key=$1
                gsub(/^[ \t]+/, "", key)
                gsub(/[ \t]+$/, "", key)

                if (key == "resolution x") {
                    value=$2
                    gsub(/^[ \t]+/, "", value)
                    gsub(/[ \t]+$/, "", value)
                    print value
                    exit
                }
            }
        ' "$SETTINGS_FILE"
    )"

    TSP_INTERNAL_Y="$(
        awk -F= '
            /^\[Video\]/ {
                video=1
                next
            }

            /^\[/ {
                video=0
            }

            video {
                key=$1
                gsub(/^[ \t]+/, "", key)
                gsub(/[ \t]+$/, "", key)

                if (key == "resolution y") {
                    value=$2
                    gsub(/^[ \t]+/, "", value)
                    gsub(/[ \t]+$/, "", value)

                    print value
                    exit
                }
            }
        ' "$SETTINGS_FILE"
    )"

    TSP_INTERNAL_RESOLUTION="${TSP_INTERNAL_X}x${TSP_INTERNAL_Y}"

    case "$TSP_INTERNAL_RESOLUTION" in
        1280x720|1152x648|1024x576|960x540|800x450|640x360)
            ;;
        *)
            TSP_INTERNAL_X=1280
            TSP_INTERNAL_Y=720
            TSP_INTERNAL_RESOLUTION=1280x720
            ;;
    esac

    # --------------------------------------------------------
    # Switchable texture benchmark.
    #
    # 0 = no geometric shrink
    # 3 = any texture dimension >256 gets /2
    # 4 = >256 gets /2, >1024 gets /4
    # --------------------------------------------------------

    TSP_TEXTURE_PROFILE_FILE="$GAMEDIR/tsp_texture_shrink_mode.txt"
    TSP_TEXTURE_SHRINK=0

    if [ -f "$TSP_TEXTURE_PROFILE_FILE" ]; then
        TSP_TEXTURE_SHRINK="$(
            tr -cd '0-9' < "$TSP_TEXTURE_PROFILE_FILE" |
                head -c 2
        )"
    fi

    case "$TSP_TEXTURE_SHRINK" in
        0|3|4)
            ;;
        *)
            TSP_TEXTURE_SHRINK=0
            ;;
    esac

    # TSP_V34_TEXTURE_DEBUG_HOOK
    if [ "${TSP_TEXTURE_DEBUG:-0}" = "1" ]; then
        TSP_TEXTURE_SHRINK=12
    fi

    export LIBGL_SHRINK="$TSP_TEXTURE_SHRINK"

    # Preserve the currently-good mipmap behavior.
    export LIBGL_FORCENPOT=0
    export LIBGL_MIPMAP=5
    export LIBGL_AVOID16BITS=1

    # Deprecated DXT bit-depth switch; it is not geometric scaling.
    unset LIBGL_NODOWNSAMPLING

    # --------------------------------------------------------
    # Keep the proven V32 direct framebuffer + swap scaler.
    # --------------------------------------------------------

    unset LIBGL_FB
    unset LIBGL_FBO
    unset LIBGL_RECYCLEFBO
    unset LIBGL_TSP_OUTPUT

    # V33 draws FPS after final presentation.
    export TSP_FPS_OVERLAY=1
    export TSP_SCALE_OUTPUT=1280x720
    export TSP_SCALE_FILTER=linear

    # Keep V33 loaded even at native resolution so FPS stays visible.
    TSP_GL4ES_LIBRARY="${TSP_GL4ES_OVERRIDE:-$GAMEDIR/lib/libGL.so.1}"

#export MALLOC_CHECK_=3
#export MALLOC_PERTURB_=170
unset TSP_MPW_OUT
unset TSP_MPW_SECS
export OPENMW_TSP_FIX_NULL_VIEWPORT=1
# TSP_RINGARM_V2 - restored 2026-09-11. V1 was lost and the launcher had reverted to
# the three unset lines, so the profiler ran on compiled defaults: trigger 0, meaning
# it armed a capture on EVERY frame. Everything below refuses to export a junk value.
if [ -f /mnt/SDCARD/tsp_ring_off ] || [ "$TSP_QUIET" = 1 ]; then   # TSP_QUIET_V1 RING
    unset OPENMW_TSP_RING
    unset OPENMW_TSP_RING_TRIGGER_MS
    unset OPENMW_TSP_RING_MAX_DUMPS
    echo "TSP_RINGARM_V2 disabled by /mnt/SDCARD/tsp_ring_off" >> "$TSP_PROG"
else
    if [ -f /mnt/SDCARD/tsp_ring.conf ]; then . /mnt/SDCARD/tsp_ring.conf; fi
    case "${TSP_RING_TRIG:-}" in ''|*[!0-9]*) TSP_RING_TRIG=60 ;; esac
    case "${TSP_RING_MAX:-}"  in ''|*[!0-9]*) TSP_RING_MAX=12 ;; esac
    if [ "$TSP_RING_TRIG" -lt 20 ] 2>/dev/null; then TSP_RING_TRIG=60; fi
    if [ "$TSP_RING_MAX" -lt 1 ] 2>/dev/null;  then TSP_RING_MAX=12; fi
    export OPENMW_TSP_RING=/mnt/SDCARD/tsp_ring
    export OPENMW_TSP_RING_TRIGGER_MS="$TSP_RING_TRIG"
    export OPENMW_TSP_RING_MAX_DUMPS="$TSP_RING_MAX"
    echo "TSP_RINGARM_V2 armed trigger=$TSP_RING_TRIG max=$TSP_RING_MAX out=/mnt/SDCARD/tsp_ring" >> "$TSP_PROG"
fi

# TSP_KTXWARM_V1 - the ASTC conversion turned 3 sequential .bsa reads into 4555 loose
# ~12 KB .ktx files. Measured 2026-09-10: the first 5 s after a save load ran 51.9
# major faults/sec with 34.2% of frames faulting, against 3.6% later in the session.
# 56 MB of textures against ~540 MB MemAvailable, so read the tree into the page cache
# in the background while the menu is up. Off: touch /mnt/SDCARD/tsp_ktxwarm_off
TSP_KTXDIR="/mnt/SDCARD/data/ports/openmw/data/Data Files/textures"
if [ ! -f /mnt/SDCARD/tsp_ktxwarm_off ] && [ -d "$TSP_KTXDIR" ]; then
    (
        TSP_KTXT0=$(date +%s)
        TSP_KTXHOW=tar
        if ! tar -cf /dev/null -C "$TSP_KTXDIR" . >/dev/null 2>&1; then
            TSP_KTXHOW=cat
            find "$TSP_KTXDIR" -name '*.ktx' 2>/dev/null | while IFS= read -r tsp_t; do
                cat "$tsp_t"
            done >/dev/null 2>&1
        fi
        echo "TSP_KTXWARM_V1 done via=$TSP_KTXHOW secs=$(( $(date +%s) - TSP_KTXT0 )) cached_kb=$(awk '/^Cached:/{print $2}' /proc/meminfo)" >> "$TSP_PROG"
    ) &
    echo "TSP_KTXWARM_V1 started dir=$TSP_KTXDIR cached_kb=$(awk '/^Cached:/{print $2}' /proc/meminfo)" >> "$TSP_PROG"
else
    echo "TSP_KTXWARM_V1 skipped (off switch present or dir missing)" >> "$TSP_PROG"
fi
unset TSP_STATE
unset TSP_STATE_OUT
unset TSP_STATE_MAX
    export TSP_NO_CELL_GLRELEASE=1
unset TSP_CRASH_OUT
    TSP_LD_PRELOAD="$GAMEDIR/lib/libtsp_warm.so:$GAMEDIR/lib/libtsp_fullscreen_scaler.so:$TSP_GL4ES_LIBRARY"

    # TSP_SDL_SENSOR_FALLBACK_051_V29: the shim has to interpose SDL_Init
    # before anything else pulls SDL in.
    if [ "${TSP_SDL_SHIM_ACTIVE:-0}" = "1" ]; then
        TSP_LD_PRELOAD="$TSP_SDL_SHIM:$TSP_LD_PRELOAD"
    fi

    if [ "${TSP_TEXTURE_DEBUG:-0}" = "1" ]; then
        echo "Texture debug:    ON"
        echo "Texture GL4ES:    $TSP_GL4ES_LIBRARY"
        echo "Near/base scale:  1/2 dimensions (>128px)"
        echo "Distant mip 1:    ~1/4 original dimensions"
    else
        echo "Texture debug:    OFF"
    fi

    if [ "$TSP_INTERNAL_RESOLUTION" = "1280x720" ]; then
        export TSP_FULLSCREEN_SCALE=0
        export TSP_SCALE_SOURCE=1280x720

        echo
        echo "=========================================="
        echo "TSP V33 FPS + TEXTURE BENCHMARK"
        echo "=========================================="
        echo "Internal raster: 1280x720"
        echo "Physical output: 1280x720"
        echo "Fullscreen scale: OFF"
        echo "FPS counter:      ON"
        echo "Texture shrink:   $TSP_TEXTURE_SHRINK"
        echo "=========================================="
    else
        export TSP_FULLSCREEN_SCALE=1
        export TSP_SCALE_SOURCE="$TSP_INTERNAL_RESOLUTION"

        echo
        echo "=========================================="
        echo "TSP V33 FPS + TEXTURE BENCHMARK"
        echo "=========================================="
        echo "Internal raster: $TSP_INTERNAL_RESOLUTION"
        echo "Physical output: 1280x720"
        echo "Fullscreen scale: ON"
        echo "FPS counter:      ON"
        echo "Texture shrink:   $TSP_TEXTURE_SHRINK"
        echo "GL4ES FBO mode:   OFF"
        echo "Weston/X11:       OFF"
        echo "=========================================="
    fi
}

# TSP_INTERNAL_RESOLUTION_AUTORESTART_LAUNCHER_051_V20R4
#
# A marker must only survive long enough to request one immediate restart.
rm -f "$RESOLUTION_RESTART_MARKER" 2>/dev/null || true

while :
do
    # TSP_GL4ES_DYNAMIC_INTERNAL_SCALE_CALL_051_V21
    tsp_apply_internal_render_scale

# TSP_V35_2_TEXT_SCALE_LOADING_POLICY

#
# LOADING:
#
# Keep V35's one-shot framebuffer-capture fix inside OpenMW,
# but do NOT create the loading-bypass marker.
#
# Therefore the V35 fullscreen scaler keeps stretching loading
# frames just like gameplay instead of exposing their raw
# internal-resolution framebuffer.
#
rm -f /tmp/openmw-tsp-loading-active 2>/dev/null || true

#
# TEXT SIZE:
#
# Separate from whole-GUI scaling.
#
TSP_UI_FONT_PROFILE="$GAMEDIR/tsp_ui_font_size.txt"

TSP_UI_FONT_SIZE="$(
    tr -cd '0-9' < "$TSP_UI_FONT_PROFILE" 2>/dev/null |
    head -c 2
)"

case "$TSP_UI_FONT_SIZE" in
    12|13|14|15|16|17|18|19|20|21|22|23|24|25|26|27|28|29|30|31|32)
        ;;
    *)
        TSP_UI_FONT_SIZE=28
        echo 28 > "$TSP_UI_FONT_PROFILE"
        ;;
esac

python3 - "$CONFIG_DIR/settings.cfg" "$TSP_UI_FONT_SIZE" <<'TSP_FONT_PY'
import configparser
import os
import sys

path = sys.argv[1]
font_size = sys.argv[2]

cfg = configparser.ConfigParser(
    interpolation=None,
    strict=False,
    empty_lines_in_values=False,
)

cfg.optionxform = str

if os.path.isfile(path):
    with open(
        path,
        "r",
        encoding="utf-8",
        errors="replace",
    ) as f:
        cfg.read_file(f)

if not cfg.has_section("GUI"):
    cfg.add_section("GUI")

cfg.set("GUI", "scaling factor", "1.0")
cfg.set("GUI", "font size", font_size)

tmp = path + ".font.tmp"

with open(
    tmp,
    "w",
    encoding="utf-8",
    newline="\n",
) as f:
    cfg.write(
        f,
        space_around_delimiters=True,
    )

os.replace(tmp, path)
TSP_FONT_PY

echo "Text-only UI scale:"
echo "  GUI geometry = 1.0"
echo "  font size    = $TSP_UI_FONT_SIZE"
echo "Loading:"
echo "  fullscreen scaler remains ON during loading"


    echo "TSP resolution launcher: starting OpenMW"

    # TSP_PORT_LOCAL_GL4ES_PRELOAD_051_V22
# >>> TSP_V36_PERF_TELEMETRY BEGIN
# Low-overhead 2-second TSP performance sampler.
# Expensive engine debug remains OFF during benchmarks.

TSP_PERF_LOG="$GAMEDIR/openmw_perf_latest.txt"
TSP_PERF_PREVIOUS="$GAMEDIR/openmw_perf_previous.txt"
TSP_PERF_SETTINGS="$CONFIG_DIR/settings.cfg"
TSP_PERF_MONITOR_PID=""


# Normal launch: no GL4ES geometric texture shrinking.
# TextureDebug may still explicitly opt into its own debug path.
if [ "${TSP_TEXTURE_DEBUG:-0}" != "1" ]; then
    TSP_TEXTURE_SHRINK=0
    export LIBGL_SHRINK=0
    printf '0\n' > "$GAMEDIR/tsp_texture_shrink_mode.txt"
fi

tsp_perf_setting_dump() {
    echo "----- Relevant OpenMW settings -----"

    awk '
        BEGIN {
            section=""
        }

        /^\[/ {
            section=$0
        }

        {
            line=tolower($0)

            if (
                line ~ /^[[:space:]]*(resolution x|resolution y|viewing distance|small feature culling|small feature culling pixel size|distant terrain|vertex lod mod|lod factor|composite map level|composite map resolution|max composite geometry size|object paging|object paging active grid|object paging merge factor|object paging min size|water culling|actors processing range|async num threads|async nav mesh updater threads|min update interval ms|preload enabled|preload num threads|target framerate|anisotropy|texture mag filter|texture min filter|texture mipmap)[[:space:]]*=/
            ) {
                print section
                print $0
            }
        }
    ' "$TSP_PERF_SETTINGS" \
        2>/dev/null |
        awk '!seen[$0]++'
}

tsp_perf_monitor() {
    PERF_PID="$1"

    set +e

    if [ -f "$TSP_PERF_LOG" ]; then
        cp -f \
            "$TSP_PERF_LOG" \
            "$TSP_PERF_PREVIOUS" \
            2>/dev/null ||
            true
    fi

    CPU_COUNT="$(
        getconf _NPROCESSORS_ONLN \
            2>/dev/null ||
        true
    )"

    case "$CPU_COUNT" in
        ''|*[!0-9]*)
            CPU_COUNT=1
            ;;
    esac

    [ "$CPU_COUNT" -gt 0 ] \
        2>/dev/null ||
        CPU_COUNT=1

    GPU_FREQ_FILES=""

    for f in /sys/class/devfreq/*/cur_freq; do
        [ -r "$f" ] || continue

        GPU_FREQ_FILES="$GPU_FREQ_FILES $f"
    done

    {
        echo \
            "============================================================"
        echo \
            "OPENMW 0.51 TSP PERFORMANCE TELEMETRY"
        echo \
            "============================================================"

        echo "Started: $(date)"
        echo "OpenMW PID: $PERF_PID"
        echo "CPU cores online: $CPU_COUNT"

        echo \
            "Internal resolution: " \
            "${TSP_INTERNAL_RESOLUTION:-unknown}"

        echo \
            "TSP_FULLSCREEN_SCALE=" \
            "${TSP_FULLSCREEN_SCALE:-0}"

        echo \
            "TSP_SCALE_SOURCE=" \
            "${TSP_SCALE_SOURCE:-unset}"

        echo \
            "TSP_SCALE_OUTPUT=" \
            "${TSP_SCALE_OUTPUT:-unset}"

        echo \
            "TSP_SCALE_FILTER=" \
            "${TSP_SCALE_FILTER:-unset}"

        echo \
            "LIBGL_SHRINK=" \
            "${LIBGL_SHRINK:-unset}"

        echo \
            "TSP_TEXTURE_DEBUG=" \
            "${TSP_TEXTURE_DEBUG:-0}"

        echo \

        echo \

        echo \
            "OSG_THREADING=" \
            "${OSG_THREADING:-unset}"

        echo \
            "LIBGL_MIPMAP=" \
            "${LIBGL_MIPMAP:-unset}"

        echo \
            "LIBGL_FORCENPOT=" \
            "${LIBGL_FORCENPOT:-unset}"

        echo \
            "LIBGL_AVOID16BITS=" \
            "${LIBGL_AVOID16BITS:-unset}"

        echo \
            "LIBGL_STREAM=" \
            "${LIBGL_STREAM:-unset}"

        echo \
            "OPENMW_DECOMPRESS_TEXTURES=" \
            "${OPENMW_DECOMPRESS_TEXTURES:-unset}"

        echo
        tsp_perf_setting_dump
        echo

        echo \
            "Samples every 2 seconds; " \
            "proc_cpu_pct: 100%=one fully busy core."

        echo \
            "psi10 = CPU/memory/I/O Linux pressure avg10."

        echo \
            "============================================================"
    } > "$TSP_PERF_LOG"

    PREV_TOTAL=""
    PREV_PROC=""
    START_SECONDS="$SECONDS"

    while kill -0 "$PERF_PID" 2>/dev/null; do
        NOW="$(
            date '+%H:%M:%S' \
                2>/dev/null ||
            echo time
        )"

        ELAPSED=$((
            SECONDS - START_SECONDS
        ))

        TOTAL="$(
            awk '
                /^cpu / {
                    s=0

                    for(i=2; i<=NF; i++)
                        s += $i

                    print s
                    exit
                }
            ' /proc/stat \
                2>/dev/null
        )"

        PROC="$(
            awk \
                '{print $14+$15}' \
                "/proc/$PERF_PID/stat" \
                2>/dev/null
        )"

        PROC_CPU="n/a"

        if [ -n "$PREV_TOTAL" ] &&
           [ -n "$PREV_PROC" ] &&
           [ -n "$TOTAL" ] &&
           [ -n "$PROC" ]
        then
            PROC_CPU="$(
                awk \
                    -v p="$PROC" \
                    -v pp="$PREV_PROC" \
                    -v t="$TOTAL" \
                    -v pt="$PREV_TOTAL" \
                    -v n="$CPU_COUNT" \
                    'BEGIN {
                        dt=t-pt
                        dp=p-pp

                        if(dt>0)
                            printf "%.1f", (100.0*dp*n)/dt
                        else
                            print "0.0"
                    }'
            )"
        fi

        PREV_TOTAL="$TOTAL"
        PREV_PROC="$PROC"

        RSS_KB="$(
            awk \
                '/^VmRSS:/ {print $2; exit}' \
                "/proc/$PERF_PID/status" \
                2>/dev/null
        )"

        VSZ_KB="$(
            awk \
                '/^VmSize:/ {print $2; exit}' \
                "/proc/$PERF_PID/status" \
                2>/dev/null
        )"

        THREADS="$(
            awk \
                '/^Threads:/ {print $2; exit}' \
                "/proc/$PERF_PID/status" \
                2>/dev/null
        )"

        VOL="$(
            awk \
                '/^voluntary_ctxt_switches:/ {print $2; exit}' \
                "/proc/$PERF_PID/status" \
                2>/dev/null
        )"

        NONVOL="$(
            awk \
                '/^nonvoluntary_ctxt_switches:/ {print $2; exit}' \
                "/proc/$PERF_PID/status" \
                2>/dev/null
        )"

        READ_B="$(
            awk \
                '/^read_bytes:/ {print $2; exit}' \
                "/proc/$PERF_PID/io" \
                2>/dev/null
        )"

        WRITE_B="$(
            awk \
                '/^write_bytes:/ {print $2; exit}' \
                "/proc/$PERF_PID/io" \
                2>/dev/null
        )"

        MEM_AVAIL="$(
            awk \
                '/^MemAvailable:/ {print $2; exit}' \
                /proc/meminfo \
                2>/dev/null
        )"

        LOAD1="$(
            awk \
                '{print $1}' \
                /proc/loadavg \
                2>/dev/null
        )"

        PSI_CPU="$(
            awk '
                /^some / {
                    for(i=1; i<=NF; i++) {
                        if($i ~ /^avg10=/) {
                            sub(/^avg10=/, "", $i)
                            print $i
                            exit
                        }
                    }
                }
            ' /proc/pressure/cpu \
                2>/dev/null
        )"

        PSI_MEM="$(
            awk '
                /^some / {
                    for(i=1; i<=NF; i++) {
                        if($i ~ /^avg10=/) {
                            sub(/^avg10=/, "", $i)
                            print $i
                            exit
                        }
                    }
                }
            ' /proc/pressure/memory \
                2>/dev/null
        )"

        PSI_IO="$(
            awk '
                /^some / {
                    for(i=1; i<=NF; i++) {
                        if($i ~ /^avg10=/) {
                            sub(/^avg10=/, "", $i)
                            print $i
                            exit
                        }
                    }
                }
            ' /proc/pressure/io \
                2>/dev/null
        )"

        CPU_MIN=""
        CPU_MAX=""

        for f in \
            /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_cur_freq
        do
            [ -r "$f" ] || continue

            V="$(
                cat "$f" \
                    2>/dev/null
            )"

            case "$V" in
                ''|*[!0-9]*)
                    continue
                    ;;
            esac

            if [ -z "$CPU_MIN" ] ||
               [ "$V" -lt "$CPU_MIN" ]
            then
                CPU_MIN="$V"
            fi

            if [ -z "$CPU_MAX" ] ||
               [ "$V" -gt "$CPU_MAX" ]
            then
                CPU_MAX="$V"
            fi
        done

        MAX_TEMP=""

        for f in \
            /sys/class/thermal/thermal_zone*/temp
        do
            [ -r "$f" ] || continue

            V="$(
                cat "$f" \
                    2>/dev/null
            )"

            case "$V" in
                ''|*[!0-9-]*)
                    continue
                    ;;
            esac

            if [ -z "$MAX_TEMP" ] ||
               [ "$V" -gt "$MAX_TEMP" ]
            then
                MAX_TEMP="$V"
            fi
        done

        DEVFREQ=""

        for f in $GPU_FREQ_FILES; do
            [ -r "$f" ] || continue

            V="$(
                cat "$f" \
                    2>/dev/null
            )"

            D="$(
                basename \
                    "$(dirname "$f")"
            )"

            DEVFREQ="${
                DEVFREQ
            }${
                DEVFREQ:+,
            }${D}:${V}"
        done

        printf \
            '%s elapsed=%ss proc_cpu_pct=%s rss_kb=%s vsz_kb=%s threads=%s load1=%s memavail_kb=%s psi10=%s/%s/%s cpu_khz=%s-%s temp_mC=%s ctxt=%s/%s io_bytes=%s/%s devfreq=%s\n' \
            "$NOW" \
            "$ELAPSED" \
            "$PROC_CPU" \
            "${RSS_KB:-na}" \
            "${VSZ_KB:-na}" \
            "${THREADS:-na}" \
            "${LOAD1:-na}" \
            "${MEM_AVAIL:-na}" \
            "${PSI_CPU:-na}" \
            "${PSI_MEM:-na}" \
            "${PSI_IO:-na}" \
            "${CPU_MIN:-na}" \
            "${CPU_MAX:-na}" \
            "${MAX_TEMP:-na}" \
            "${VOL:-na}" \
            "${NONVOL:-na}" \
            "${READ_B:-na}" \
            "${WRITE_B:-na}" \
            "${DEVFREQ:-na}" \
            >> "$TSP_PERF_LOG"

        sleep 2
    done

    {
        echo \
            "============================================================"

        echo \
            "Monitor stopped: $(date)"

        echo \
            "============================================================"
    } >> "$TSP_PERF_LOG"
}


# TSP_PERF_SAMPLER_V1
# Replaces tsp_perf_monitor. The old one spawned ~20 processes per 2-second
# sample (date, a dozen awks, cats over cpufreq/thermal). With LD_PRELOAD
# exported those each loaded gl4es plus five shims - roughly 50,000 process
# spawns and library mappings over a 45-minute session, against an SD card
# that is already the bottleneck. It also produced zero rows on device.
#
# This one spawns NOTHING per sample: pure shell reads of /proc.
tsp_perf_sampler() {
    PERF_PID="$1"

    # One-shot header. Everything after this is pure shell reads of /proc -
    # no awk, no cat, no command substitution in the sampling loop, so the
    # sampler spawns exactly zero processes per sample instead of ~20.
    {
        printf '# openmw perf sampler  pid=%s\n' "$PERF_PID"
        printf '# t=seconds rss/vsz/memavail/memfree in kB, psi=avg10 pressure\n'
        printf '# t rss_kb vsz_kb threads memavail_kb memfree_kb psi_cpu psi_mem psi_io utime stime majflt\n'
    } > "$TSP_PERF_LOG"

    T=0
    while kill -0 "$PERF_PID" 2>/dev/null; do
        RSS=na; VSZ=na; THR=na
        while read -r k v _; do
            case "$k" in
                VmRSS:)   RSS=$v ;;
                VmSize:)  VSZ=$v ;;
                Threads:) THR=$v ;;
            esac
        done < "/proc/$PERF_PID/status"

        MA=na; MF=na
        while read -r k v _; do
            case "$k" in
                MemAvailable:) MA=$v ;;
                MemFree:)      MF=$v ;;
            esac
        done < /proc/meminfo

        PC=na; PM=na; PI=na
        if [ -r /proc/pressure/cpu ]; then
            while read -r kind rest; do
                case "$kind" in some) set -- $rest; PC=${1#avg10=} ;; esac
            done < /proc/pressure/cpu
        fi
        if [ -r /proc/pressure/memory ]; then
            while read -r kind rest; do
                case "$kind" in some) set -- $rest; PM=${1#avg10=} ;; esac
            done < /proc/pressure/memory
        fi
        if [ -r /proc/pressure/io ]; then
            while read -r kind rest; do
                case "$kind" in some) set -- $rest; PI=${1#avg10=} ;; esac
            done < /proc/pressure/io
        fi

        UT=na; ST=na; MJ=na
        read -r _ _ _ _ _ _ _ _ _ _ _ MJ _ UT ST _ < "/proc/$PERF_PID/stat"

        printf '%s %s %s %s %s %s %s %s %s %s %s %s\n' \
            "$T" "$RSS" "$VSZ" "$THR" "$MA" "$MF" \
            "$PC" "$PM" "$PI" "$UT" "$ST" "$MJ" >> "$TSP_PERF_LOG"

        T=$((T + 2))
        sleep 2
    done

    printf '# sampler stopped at t=%s\n' "$T" >> "$TSP_PERF_LOG"
}

# TSP_CPU_OPTIMIZE_V2
# Measured: OpenMW ran with Cpus_allowed_list=0-1 - two little cores at a
# fixed 1.416 GHz - while cpu4 sat online at up to 2.16 GHz and unused. The
# root cpuset permits 0-1,4 and a plain process gets 0-7, so nothing in the
# kernel was enforcing that; something in the launch chain set it.
#
# v1 died because BusyBox taskset takes a HEX MASK, not "-c <list>", and I
# never probed it before putting it in front of the game - so its failure
# meant OpenMW never started. v2 probes first and can only ever be a no-op.
#
# Layout, portable across both devices:
#   main thread  -> the fastest single core   (cpu4 on the S, cpu0 on a
#                                              4-core Smart Pro)
#   every other  -> the remaining online cores
#
# Threads inherit the affinity of whoever created them, so pinning the main
# thread at exec would drag every worker onto the fast core too. The split is
# therefore applied a few times AFTER launch, once the workers exist.
#
# $GAMEDIR/tsp_cpu_policy.txt:  auto (default) | off

tsp_cpu_mask() {
    # cpu list "0,1,4" -> hex mask "13"
    _m=0
    _OI=$IFS; IFS=,
    for _c in $1; do
        case "$_c" in ''|*[!0-9]*) continue ;; esac
        _m=$(( _m | (1 << _c) ))
    done
    IFS=$_OI
    printf '%x' "$_m"
}

tsp_cpu_optimize() {
    TSP_CPU_MAIN_MASK=""
    TSP_CPU_BG_MASK=""
    TSP_CPU_POLICY=auto

    if [ -r "$GAMEDIR/tsp_cpu_policy.txt" ]; then
        read -r TSP_CPU_POLICY < "$GAMEDIR/tsp_cpu_policy.txt" 2>/dev/null
    fi
    case "$TSP_CPU_POLICY" in auto|off) ;; *) TSP_CPU_POLICY=auto ;; esac
    if [ "$TSP_CPU_POLICY" = "off" ]; then
        echo "CPU policy:   off"
        return 0
    fi
    command -v taskset >/dev/null 2>&1 || { echo "CPU policy:   no taskset - skipping"; return 0; }

    # Enumerate online CPUs and find the fastest.
    TSP_CPU_ALL=""; TSP_CPU_FAST=""; TSP_CPU_BEST=0
    for d in /sys/devices/system/cpu/cpu[0-9]*; do
        n=${d##*/cpu}
        case "$n" in ''|*[!0-9]*) continue ;; esac
        on=1; [ -r "$d/online" ] && read -r on < "$d/online"
        [ "$on" = "1" ] || continue
        TSP_CPU_ALL="${TSP_CPU_ALL}${TSP_CPU_ALL:+,}$n"
        khz=0; [ -r "$d/cpufreq/cpuinfo_max_freq" ] && read -r khz < "$d/cpufreq/cpuinfo_max_freq"
        case "$khz" in ''|*[!0-9]*) khz=0 ;; esac
        if [ "$khz" -gt "$TSP_CPU_BEST" ]; then
            TSP_CPU_BEST=$khz; TSP_CPU_FAST=$n
        elif [ "$khz" -eq "$TSP_CPU_BEST" ]; then
            TSP_CPU_FAST="${TSP_CPU_FAST}${TSP_CPU_FAST:+,}$n"
        fi
    done
    [ -n "$TSP_CPU_ALL" ] || { echo "CPU policy:   no online CPUs - skipping"; return 0; }

    # One core for the main thread: the first of the fastest tier.
    TSP_CPU_MAIN=${TSP_CPU_FAST%%,*}

    # Everything else for background work. If that would be empty (single
    # core machine) fall back to giving background threads everything.
    TSP_CPU_BG=""
    _OI=$IFS; IFS=,
    for n in $TSP_CPU_ALL; do
        [ "$n" = "$TSP_CPU_MAIN" ] && continue
        TSP_CPU_BG="${TSP_CPU_BG}${TSP_CPU_BG:+,}$n"
    done
    IFS=$_OI
    [ -n "$TSP_CPU_BG" ] || TSP_CPU_BG="$TSP_CPU_ALL"

    TSP_CPU_ALL_MASK=$(tsp_cpu_mask "$TSP_CPU_ALL")
    TSP_CPU_MAIN_MASK=$(tsp_cpu_mask "$TSP_CPU_MAIN")
    TSP_CPU_BG_MASK=$(tsp_cpu_mask "$TSP_CPU_BG")

    # PROBE. BusyBox taskset wants a hex mask; util-linux accepts one too.
    # If this fails for any reason we print why and change nothing.
    if ! taskset "$TSP_CPU_ALL_MASK" true 2>/dev/null; then
        echo "CPU policy:   taskset rejected mask $TSP_CPU_ALL_MASK - leaving affinity alone"
        taskset "$TSP_CPU_ALL_MASK" true 2>&1 | head -1
        TSP_CPU_MAIN_MASK=""; TSP_CPU_BG_MASK=""
        return 0
    fi

    echo "CPU policy:   auto"
    echo "  online     : $TSP_CPU_ALL  (mask $TSP_CPU_ALL_MASK)"
    echo "  fastest    : $TSP_CPU_FAST @ ${TSP_CPU_BEST} kHz"
    echo "  main thread: cpu$TSP_CPU_MAIN  (mask $TSP_CPU_MAIN_MASK)"
    echo "  background : $TSP_CPU_BG  (mask $TSP_CPU_BG_MASK)"
}

# Governor control. cpu4-7 sit on "ondemand" with a 2.16 GHz ceiling they
# rarely reach - cpu4 was measured at 1.2 GHz mid-stall. Pinning the main
# thread to a core the governor keeps at half clock wastes the point, so the
# fastest tier is switched to "performance" while the game runs and put back
# exactly as it was on exit. Originals are saved per-cpu, so this restores
# correctly whatever profile the firmware had set.
TSP_GOV_SAVE="/tmp/tsp-governors.saved"

tsp_cpu_governor_boost() {
    [ "$TSP_CPU_POLICY" = "off" ] && return 0
    [ -n "$TSP_CPU_FAST" ] || return 0
    : > "$TSP_GOV_SAVE" 2>/dev/null || return 0
    _changed=""
    _OI=$IFS; IFS=,
    for n in $TSP_CPU_FAST; do
        g="/sys/devices/system/cpu/cpu$n/cpufreq/scaling_governor"
        [ -r "$g" ] || continue
        read -r _old < "$g"
        [ "$_old" = "performance" ] && continue
        if [ -w "$g" ] && echo performance > "$g" 2>/dev/null; then
            echo "$n $_old" >> "$TSP_GOV_SAVE"
            _changed="${_changed}${_changed:+,}cpu$n:$_old->performance"
        fi
    done
    IFS=$_OI
    if [ -n "$_changed" ]; then
        echo "  governor   : $_changed"
    else
        echo "  governor   : unchanged (already performance, or not writable)"
    fi
}

tsp_cpu_governor_restore() {
    [ -r "$TSP_GOV_SAVE" ] || return 0
    while read -r n old; do
        [ -n "$n" ] || continue
        g="/sys/devices/system/cpu/cpu$n/cpufreq/scaling_governor"
        [ -w "$g" ] && echo "$old" > "$g" 2>/dev/null
    done < "$TSP_GOV_SAVE"
    rm -f "$TSP_GOV_SAVE"
    echo "CPU policy:   governors restored"
}

# Applied after launch: workers inherit whoever spawned them, so this has to
# run once they exist. Three passes covers OpenMW's and the GL driver's
# thread creation without polling forever.
# =================== TSP_LEVER_V1 ===========================================
# Three levers that share one off-switch file, $GAMEDIR/tsp_lever_policy.txt:
#   orphan=off    do not export LIBGL_TSP_ORPHAN=1 (gl4es TSP_VBO_ORPHAN_V1 stays dormant)
#   gpuclock=off  leave the GPU clock / power policy alone
#   hygiene=off   leave the TrimUI daemons alone
# No file = all three on. Everything applied here is saved and put back on exit.
# Proof lines: TSP_VBO_ORPHAN_V1 / TSP_GPUCLOCK_V1 / TSP_HYGIENE_V1 in the log,
# one TSP_LEVER_V1 line per launch in /mnt/SDCARD/tsp_prog.txt.
TSP_HYG_SAVE="/tmp/tsp-hygiene.saved"
TSP_GPU_SAVE="/tmp/tsp-gpuclock.saved"
tsp_lever_policy() {
    if [ -r "$GAMEDIR/tsp_lever_policy.txt" ] && grep -q "^$1=off" "$GAMEDIR/tsp_lever_policy.txt" 2>/dev/null; then echo off; else echo on; fi
}
tsp_proc_nice() {
    _pp=$1; _s=$(cat /proc/$_pp/stat 2>/dev/null) || return 1
    _r=${_s##*) }; set -- $_r; echo "${17}"
}
tsp_proc_cpus() { grep Cpus_allowed_list /proc/$1/status 2>/dev/null | cut -f2; }

# TSP_HYGIENE_V1: the launcher UI and its daemons (trimui_osdd alone had 6151 CPU-s of
# uptime on the S) run at nice 0 on every core, including the one the game's main
# thread is pinned to. Pin them to the background mask, drop their priority, keep
# input responsive (trimui_inputd: pinned, not reniced) and give the FUSE exfat
# daemon that serves every asset read a small edge (-5) off the main core.
tsp_hygiene_apply() {
    if [ "$(tsp_lever_policy hygiene)" = off ]; then echo "TSP_HYGIENE_V1 off (policy)"; return 0; fi
    if [ -z "${TSP_CPU_BG_MASK:-}" ]; then echo "TSP_HYGIENE_V1 skipped (no background mask - CPU policy off or taskset rejected)"; return 0; fi
    command -v renice >/dev/null 2>&1 || { echo "TSP_HYGIENE_V1 skipped (no renice)"; return 0; }
    : > "$TSP_HYG_SAVE"
    _n=0
    for _spec in MainUI:10 keymon:10 trimui_scened:10 trimui_osdd:10 musicserver:10 hardwareservice:10 ledc:10 trimui_inputd:0 mount.exfat:-5; do
        _name=${_spec%%:*}; _adj=${_spec##*:}
        for _p in $(pidof "$_name" 2>/dev/null); do
            _on=$(tsp_proc_nice "$_p") || continue
            _om=$(taskset -p "$_p" 2>/dev/null | sed 's/.*: *//')
            [ -n "$_om" ] || continue
            printf '%s\t%s\t%s\t%s\n' "$_p" "$_name" "$_on" "$_om" >> "$TSP_HYG_SAVE"
            taskset -ap "$TSP_CPU_BG_MASK" "$_p" >/dev/null 2>&1 || true
            [ "$_adj" != 0 ] && { renice "$_adj" -p "$_p" >/dev/null 2>&1 || true; }
            _n=$((_n+1))
        done
    done
    echo "TSP_HYGIENE_V1 on bg_mask=$TSP_CPU_BG_MASK main_mask=${TSP_CPU_MAIN_MASK:-?} touched=$_n"
    while IFS="$(printf '\t')" read -r _p _name _on _om; do
        [ -n "$_p" ] || continue
        echo "  $_name pid=$_p nice=$(tsp_proc_nice "$_p") cpus=$(tsp_proc_cpus "$_p")  (was nice=$_on mask=$_om)"
    done < "$TSP_HYG_SAVE"
}
tsp_hygiene_restore() {
    [ -r "$TSP_HYG_SAVE" ] || return 0
    _n=0
    while IFS="$(printf '\t')" read -r _p _name _on _om; do
        [ -n "$_p" ] || continue
        [ "$(cat /proc/$_p/comm 2>/dev/null)" = "$_name" ] || continue
        taskset -ap "$_om" "$_p" >/dev/null 2>&1 || true
        renice "$_on" -p "$_p" >/dev/null 2>&1 || true
        _n=$((_n+1))
    done < "$TSP_HYG_SAVE"
    rm -f "$TSP_HYG_SAVE"
    echo "TSP_HYGIENE_V1 restored $_n daemon(s)"
}

# TSP_GPUCLOCK_V1: the S's Mali sits at 150 MHz of an 888 MHz range under
# simple_ondemand for its whole uptime; hold it at the top while the game runs
# (min_freq=max_freq, performance governor when offered, kbase power_policy
# always_on). The base TSP has no devfreq for the PowerVR; Allwinner's scenectrl
# node is the only runtime knob there and is tried if present. Saved + restored.
tsp_gpuclock_apply() {
    if [ "$(tsp_lever_policy gpuclock)" = off ]; then echo "TSP_GPUCLOCK_V1 off (policy)"; return 0; fi
    rm -f "$TSP_GPU_SAVE"
    _d=""; for _c in /sys/class/devfreq/*gpu*; do [ -e "$_c/cur_freq" ] && { _d=$_c; break; }; done
    if [ -n "$_d" ]; then
        _gov=$(cat $_d/governor 2>/dev/null); _min=$(cat $_d/min_freq 2>/dev/null); _max=$(cat $_d/max_freq 2>/dev/null)
        printf 'devfreq\t%s\t%s\t%s\n' "$_d" "$_gov" "$_min" >> "$TSP_GPU_SAVE"
        grep -qw performance $_d/available_governors 2>/dev/null && { echo performance > $_d/governor 2>/dev/null || true; }
        echo "$_max" > $_d/min_freq 2>/dev/null || true
        _pp=/sys/class/misc/mali0/device/power_policy
        if [ -w "$_pp" ]; then
            _old=$(sed 's/.*\[\(.*\)\].*/\1/' $_pp 2>/dev/null)
            printf 'mali_pp\t%s\t%s\n' "$_pp" "$_old" >> "$TSP_GPU_SAVE"
            echo always_on > $_pp 2>/dev/null || true
        fi
        sleep 1
        echo "TSP_GPUCLOCK_V1 on node=$_d gov=$(cat $_d/governor 2>/dev/null) min=$(cat $_d/min_freq 2>/dev/null) cur=$(cat $_d/cur_freq 2>/dev/null) max=$_max power_policy=$(cat $_pp 2>/dev/null | tr -d '\n')  (was gov=$_gov min=$_min)"
    elif [ -e /sys/devices/platform/gpu/scenectrl/command ]; then
        _sc=/sys/devices/platform/gpu/scenectrl
        _old=$(cat $_sc/command 2>/dev/null)
        printf 'scenectrl\t%s\t%s\n' "$_sc/command" "$_old" >> "$TSP_GPU_SAVE"
        echo 1 > $_sc/command 2>/dev/null || true
        echo "TSP_GPUCLOCK_V1 on scenectrl command=$(cat $_sc/command 2>/dev/null) status=$(cat $_sc/status 2>/dev/null)  (was $_old) nodes=[$(ls $_sc 2>/dev/null | tr '\n' ' ')]"
    else
        echo "TSP_GPUCLOCK_V1 skipped (no devfreq gpu node and no scenectrl on this card)"
    fi
}
tsp_gpuclock_restore() {
    [ -r "$TSP_GPU_SAVE" ] || return 0
    while IFS="$(printf '\t')" read -r _k _a _b _c; do
        case "$_k" in
            devfreq) [ -n "$_c" ] && { echo "$_c" > $_a/min_freq 2>/dev/null || true; }; [ -n "$_b" ] && { echo "$_b" > $_a/governor 2>/dev/null || true; } ;;
            mali_pp|scenectrl) [ -n "$_b" ] && { echo "$_b" > "$_a" 2>/dev/null || true; } ;;
        esac
    done < "$TSP_GPU_SAVE"
    rm -f "$TSP_GPU_SAVE"
    echo "TSP_GPUCLOCK_V1 restored"
}
tsp_lever_prelaunch() {
    echo "# TSP_LEVER_V1 ----------------------------------------------------"
    if [ "$(tsp_lever_policy orphan)" = off ]; then
        unset LIBGL_TSP_ORPHAN; echo "TSP_VBO_ORPHAN_V1 env off (policy)"
    else
        export LIBGL_TSP_ORPHAN=1
        echo "TSP_VBO_ORPHAN_V1 env on LIBGL_TSP_ORPHAN=1 lib_marker=$(grep -a -c TSP_VBO_ORPHAN_V1 "$GAMEDIR/lib/libGL.so.1" 2>/dev/null)"
    fi
    tsp_gpuclock_apply
    tsp_hygiene_apply
    echo "TSP_LEVER_V1 armed $(date '+%Y-%m-%d %H:%M:%S') orphan=$(tsp_lever_policy orphan) gpuclock=$(tsp_lever_policy gpuclock) hygiene=$(tsp_lever_policy hygiene) bg_mask=${TSP_CPU_BG_MASK:-none}" >> "$TSP_PROG"
}
tsp_lever_restore() { tsp_hygiene_restore; tsp_gpuclock_restore; }
# =================== end TSP_LEVER_V1 =======================================

tsp_cpu_apply_split() {
    _pid="$1"
    [ -n "$TSP_CPU_MAIN_MASK" ] || return 0
    for _delay in 8 25 60; do
        sleep "$_delay"
        kill -0 "$_pid" 2>/dev/null || return 0
        taskset -ap "$TSP_CPU_BG_MASK" "$_pid" >/dev/null 2>&1
        taskset -p  "$TSP_CPU_MAIN_MASK" "$_pid" >/dev/null 2>&1
    done
}

# TSP_SWAP_V1
# The 0-1 fps stalls on this port are page-cache thrash, confirmed by
# measurement: 997 major faults in a 10-second window during a stall versus 0
# while healthy, with CPU utilisation going DOWN because the process was
# blocked in the fault path rather than computing.
#
# Cause: ~684 MB RSS plus a ~230 MB Mali pool on a 986 MB device with NO SWAP.
# With no swap the kernel's only reclaimable memory is file-backed pages, so
# it evicts the game's own executable and libraries and faults them straight
# back off the SD card - which is a fuseblk (exFAT) mount, so every fault is a
# round trip through a userspace filesystem daemon.
#
# Adding 512 MB of swap on the internal ext4 partition took the fault count
# from 997 to 166 per 10 s and the same fast-travel spot from 0 fps to ~5.
# swappiness is raised so the kernel prefers evicting anonymous pages (which
# now have somewhere to go) over file pages (which are the expensive ones).
#
# THIS CREATES A PERSISTENT FILE ON THE USER'S INTERNAL STORAGE.
# Default 512 MB at /mnt/UDISK/openmw-swapfile. Remove it with
# tsp_swap_remove.sh. Size is overridable in $GAMEDIR/tsp_swap_mb.txt;
# "0" or "off" disables the whole feature and the game runs exactly as before.
tsp_setup_swap() {
    TSP_SWAP_MB=512
    TSP_SWAPPINESS=150
    TSP_VFS_PRESSURE=50
    TSP_SWAP_DIR=/mnt/UDISK
    TSP_SWAP_FILE="$TSP_SWAP_DIR/openmw-swapfile"

    if [ -r "$GAMEDIR/tsp_swap_mb.txt" ]; then
        read -r TSP_SWAP_CFG < "$GAMEDIR/tsp_swap_mb.txt" 2>/dev/null
        case "$TSP_SWAP_CFG" in
            off|OFF|0) echo "Swap:         disabled by tsp_swap_mb.txt"; return 0 ;;
            ''|*[!0-9]*) ;;
            *) TSP_SWAP_MB=$TSP_SWAP_CFG ;;
        esac
    fi

    [ -e /proc/swaps ] || { echo "Swap:         kernel has no swap support - skipping"; return 0; }

    if grep -q "^$TSP_SWAP_FILE " /proc/swaps 2>/dev/null; then
        echo "Swap:         already active ($TSP_SWAP_FILE)"
        tsp_swap_tune
        return 0
    fi

    command -v mkswap >/dev/null 2>&1 || { echo "Swap:         mkswap unavailable - skipping"; return 0; }
    command -v swapon >/dev/null 2>&1 || { echo "Swap:         swapon unavailable - skipping"; return 0; }
    [ -d "$TSP_SWAP_DIR" ] || { echo "Swap:         $TSP_SWAP_DIR not present - skipping"; return 0; }

    # Refuse anything that cannot back a swapfile. FUSE and FAT cannot.
    TSP_SWAP_FSTYPE=""
    while read -r _dev _mp _fs _rest; do
        [ "$_mp" = "$TSP_SWAP_DIR" ] && TSP_SWAP_FSTYPE=$_fs
    done < /proc/mounts
    case "$TSP_SWAP_FSTYPE" in
        ext2|ext3|ext4|f2fs|btrfs|xfs) ;;
        *) echo "Swap:         $TSP_SWAP_DIR is '$TSP_SWAP_FSTYPE', cannot host a swapfile - skipping"; return 0 ;;
    esac

    if [ ! -f "$TSP_SWAP_FILE" ]; then
        # Never fill the partition: require 2x the swap size free.
        TSP_SWAP_FREE_KB=$(df -k "$TSP_SWAP_DIR" 2>/dev/null | tail -1 | tr -s ' ' | cut -d' ' -f4)
        case "$TSP_SWAP_FREE_KB" in ''|*[!0-9]*) TSP_SWAP_FREE_KB=0 ;; esac
        TSP_SWAP_NEED_KB=$(( TSP_SWAP_MB * 1024 * 2 ))
        if [ "$TSP_SWAP_FREE_KB" -lt "$TSP_SWAP_NEED_KB" ]; then
            echo "Swap:         only ${TSP_SWAP_FREE_KB} kB free on $TSP_SWAP_DIR, need ${TSP_SWAP_NEED_KB} kB - skipping"
            return 0
        fi

        echo "Swap:         creating ${TSP_SWAP_MB} MB at $TSP_SWAP_FILE (one time, ~15s)"
        if ! dd if=/dev/zero of="$TSP_SWAP_FILE" bs=1M count="$TSP_SWAP_MB" 2>/dev/null; then
            echo "Swap:         could not write swapfile - skipping"
            rm -f "$TSP_SWAP_FILE"
            return 0
        fi
        chmod 600 "$TSP_SWAP_FILE" 2>/dev/null
        if ! mkswap "$TSP_SWAP_FILE" >/dev/null 2>&1; then
            echo "Swap:         mkswap failed - removing and skipping"
            rm -f "$TSP_SWAP_FILE"
            return 0
        fi
    fi

    chmod 600 "$TSP_SWAP_FILE" 2>/dev/null
    if swapon "$TSP_SWAP_FILE" 2>/dev/null; then
        echo "Swap:         active, ${TSP_SWAP_MB} MB at $TSP_SWAP_FILE"
        tsp_swap_tune
    else
        echo "Swap:         swapon failed - continuing without swap"
    fi
}

tsp_swap_tune() {
    [ -w /proc/sys/vm/swappiness ] && echo "$TSP_SWAPPINESS" > /proc/sys/vm/swappiness 2>/dev/null
    [ -w /proc/sys/vm/vfs_cache_pressure ] && echo "$TSP_VFS_PRESSURE" > /proc/sys/vm/vfs_cache_pressure 2>/dev/null
    echo "  swappiness : $(cat /proc/sys/vm/swappiness 2>/dev/null) (prefer swapping heap over evicting code)"
    echo "  vfs_cache  : $(cat /proc/sys/vm/vfs_cache_pressure 2>/dev/null)"
}

# <<< TSP_V36_PERF_TELEMETRY END
export LIBGL_TSP_NORGBFIX=1
export LIBGL_TSP_NODEPTHFIX=1

unset LIBGL_TSP_WATCH
unset LIBGL_TSP_WATCH_FBONLY
unset LIBGL_TSP_FBFLUSH
unset LIBGL_TSP_DT
export LIBGL_TSP_LATEDETECT=1
export LIBGL_NOTEXMAT=0
export LIBGL_TSP_DEPTH=24
unset LIBGL_TSP_DIAG_OUT
unset LIBGL_TSP_SHADERDUMP
export OPENMW_TSP_INCREMENTAL_COMPILE=1
export LIBGL_TSP_NOPRELOAD=1
unset LIBGL_TSP_DIAG
unset LIBGL_TSP_DIAG_MEMSECS
unset LIBGL_TSP_DIAG_MEMEVENT_KB
export LIBGL_TSP_SHADERCACHE="$GAMEDIR/shadercache"
unset LIBGL_TSP_DIAG_MAX
export LIBGL_TSP_DERIVATIVES=1
export LIBGL_FBCONVERT=1
    tsp_setup_swap
# >>> TSP_DRAWTHREAD_V1 CORE BEGIN
# With DrawThreadPerContext the OSG draw thread is as hot as the main thread and needs a fast core of its
# own. On the S CrossMix leaves cpu5-7 offline, so only cpu4 of the 2.16 GHz tier exists to the scheduler:
# bring the next core of that tier online for the run (put back on exit) BEFORE TSP_CPU_OPTIMIZE_V2
# enumerates, so its masks include it. A 4-core card already has a second core in the tier.
TSP_SYS_CPU="${TSP_SYS_CPU:-/sys/devices/system/cpu}"
TSP_DRAW_CPU=""; TSP_DRAW_ONLINED=""; TSP_MAIN_GUESS=""
if [ "$OSG_THREADING" = DrawThreadPerContext ] && ! grep -qs '^core=off' "$GAMEDIR/tsp_drawthread_policy.txt"; then
    _best=0; _tier=""
    for _d in "$TSP_SYS_CPU"/cpu[0-9]*; do
        _n=${_d##*/cpu}; case "$_n" in ''|*[!0-9]*) continue ;; esac
        _k=0; [ -r "$_d/cpufreq/cpuinfo_max_freq" ] && read -r _k < "$_d/cpufreq/cpuinfo_max_freq"
        case "$_k" in ''|*[!0-9]*) _k=0 ;; esac
        if [ "$_k" -gt "$_best" ]; then _best=$_k; _tier=$_n
        elif [ "$_k" -eq "$_best" ]; then _tier="$_tier $_n"; fi
    done
    # main = first ONLINE core of the tier (what TSP_CPU_OPTIMIZE_V2 picks); draw = the next one, online or brought online
    for _n in $_tier; do
        _on=1; [ -r "$TSP_SYS_CPU/cpu$_n/online" ] && read -r _on < "$TSP_SYS_CPU/cpu$_n/online"
        if [ -z "$TSP_MAIN_GUESS" ]; then [ "$_on" = 1 ] && TSP_MAIN_GUESS=$_n; continue; fi
        if [ "$_on" = 1 ]; then TSP_DRAW_CPU=$_n; break; fi
        if [ -w "$TSP_SYS_CPU/cpu$_n/online" ] && echo 1 > "$TSP_SYS_CPU/cpu$_n/online" 2>/dev/null; then
            sleep 1; read -r _on < "$TSP_SYS_CPU/cpu$_n/online"
            [ "$_on" = 1 ] && { TSP_DRAW_CPU=$_n; TSP_DRAW_ONLINED=$_n; break; }
        fi
    done
    # fallback: an offline sibling has no cpufreq node on some kernels - try main+1, keep it only if it is as fast
    if [ -z "$TSP_DRAW_CPU" ] && [ -n "$TSP_MAIN_GUESS" ]; then
        _n=$((TSP_MAIN_GUESS + 1)); _o="$TSP_SYS_CPU/cpu$_n/online"
        if [ -w "$_o" ] && [ "$(cat "$_o" 2>/dev/null)" = 0 ] && echo 1 > "$_o" 2>/dev/null; then
            sleep 1; _k=0; [ -r "$TSP_SYS_CPU/cpu$_n/cpufreq/cpuinfo_max_freq" ] && read -r _k < "$TSP_SYS_CPU/cpu$_n/cpufreq/cpuinfo_max_freq"
            if [ "${_k:-0}" -ge "$_best" ] 2>/dev/null; then TSP_DRAW_CPU=$_n; TSP_DRAW_ONLINED=$_n; _tier="$_tier +$_n"; else echo 0 > "$_o" 2>/dev/null; fi
        fi
    fi
    echo "TSP_DRAWTHREAD_V1 core tier=[$_tier] @ ${_best} kHz main=cpu${TSP_MAIN_GUESS:-?} draw=cpu${TSP_DRAW_CPU:-none} onlined=${TSP_DRAW_ONLINED:-none} online_now=$(cat "$TSP_SYS_CPU/online" 2>/dev/null)" | tee -a "$TSP_PROG_TEE"
fi
# <<< TSP_DRAWTHREAD_V1 CORE END
    tsp_cpu_optimize
    tsp_cpu_governor_boost
# >>> TSP_CPUCLOCK_V1 BEGIN
# tsp_gpuprobe read every A133 core at 1,200,000 kHz for a whole run with the governor already on
# performance; the silicon ceiling (cpuinfo_max_freq) is 2,000,000. Lift scaling_max_freq to the ceiling on
# every online core (saved, put back on exit), enable the cpufreq boost knob where the driver has one, and log
# the cooling-device state so a thermally throttled run is recognisable from the log alone.
# clock=off in $GAMEDIR/tsp_drawthread_policy.txt skips it. Cores already at their ceiling are left alone.
TSP_CLOCK_SAVE=/tmp/tsp-maxfreq.saved
tsp_cpuclock_restore() {
    [ -r "$TSP_CLOCK_SAVE" ] || return 0
    while read -r _n _v; do
        [ -n "$_n" ] || continue
        if [ "$_n" = boost ]; then echo "$_v" > "$TSP_SYS_CPU/cpufreq/boost" 2>/dev/null; else echo "$_v" > "$TSP_SYS_CPU/cpu$_n/cpufreq/scaling_max_freq" 2>/dev/null; fi
    done < "$TSP_CLOCK_SAVE"
    rm -f "$TSP_CLOCK_SAVE"; echo "TSP_CPUCLOCK_V1 restored"
}
if grep -qs '^clock=off' "$GAMEDIR/tsp_drawthread_policy.txt"; then
    echo "TSP_CPUCLOCK_V1 off (policy)" | tee -a "$TSP_PROG_TEE"
else
    : > "$TSP_CLOCK_SAVE"; _cl=""
    for _d in "$TSP_SYS_CPU"/cpu[0-9]*; do
        _n=${_d##*/cpu}; case "$_n" in ''|*[!0-9]*) continue ;; esac
        [ -r "$_d/cpufreq/scaling_max_freq" ] || continue
        _on=1; [ -r "$_d/online" ] && read -r _on < "$_d/online"; [ "$_on" = 1 ] || continue
        read -r _smax < "$_d/cpufreq/scaling_max_freq"; _hmax=0; [ -r "$_d/cpufreq/cpuinfo_max_freq" ] && read -r _hmax < "$_d/cpufreq/cpuinfo_max_freq"
        if [ "$_smax" -lt "$_hmax" ] 2>/dev/null; then
            echo "$_n $_smax" >> "$TSP_CLOCK_SAVE"
            if echo "$_hmax" > "$_d/cpufreq/scaling_max_freq" 2>/dev/null; then _cl="$_cl cpu$_n:$_smax->$(cat "$_d/cpufreq/scaling_max_freq" 2>/dev/null)"; else _cl="$_cl cpu$_n:$_smax->REFUSED"; fi
        else
            _cl="$_cl cpu$_n:$_smax=ceiling"
        fi
    done
    if [ -w "$TSP_SYS_CPU/cpufreq/boost" ]; then _b0=$(cat "$TSP_SYS_CPU/cpufreq/boost" 2>/dev/null); [ "$_b0" = 1 ] || { echo "boost $_b0" >> "$TSP_CLOCK_SAVE"; echo 1 > "$TSP_SYS_CPU/cpufreq/boost" 2>/dev/null; }; _cl="$_cl boost:$_b0->$(cat "$TSP_SYS_CPU/cpufreq/boost" 2>/dev/null)"; fi
    _cool=""; for _c in /sys/class/thermal/cooling_device*; do [ -r "$_c/type" ] || continue; _ct=$(cat "$_c/type"); case "$_ct" in *cpu*|*cluster*) _cool="$_cool $_ct:$(cat "$_c/cur_state" 2>/dev/null)/$(cat "$_c/max_state" 2>/dev/null)";; esac; done
    echo "TSP_CPUCLOCK_V1 armed$_cl avail=[$(cat "$TSP_SYS_CPU/cpu0/cpufreq/scaling_available_frequencies" 2>/dev/null | tr -s ' ' ',')] cooling=[$_cool] temp=$(for _z in /sys/class/thermal/thermal_zone*/temp; do cat "$_z" 2>/dev/null; done | sort -n | tail -1)" | tee -a "$TSP_PROG_TEE"
fi
# <<< TSP_CPUCLOCK_V1 END
    tsp_lever_prelaunch
# ===================== TSP_AB_SWITCH_V1 ======================================
# Two A/B flips, each driven by a flag file, so switching arms never needs a
# script edit. Both branches log, so a run can never be misattributed.
#
#  /mnt/SDCARD/tsp_noscaler  -> drop the swap-scaler .so from TSP_LD_PRELOAD.
#     TSP_SWAPSCALER_051_V35 logs scale=0 source=1280x720
#     requested_output=1280x720 - a full-screen pass whose output equals its
#     input - and tsp_gltime measured SwapWindow=11.5 ms of a 46.5 ms frame
#     with vsync confirmed off. The resolution-lowering patch is kept, just
#     bypassed while scale=0. In this launcher the entry is
#     $GAMEDIR/lib/libtsp_fullscreen_scaler.so, assembled at line 1064 next to
#     libtsp_warm.so and $TSP_GL4ES_LIBRARY - only the *scaler*.so entry is
#     dropped, and every dropped entry is named in the log line.
#
#  /mnt/SDCARD/tsp_texsd     -> move /mnt/UDISK/openmw-tex/textures aside, so
#     the data= root still exists (no missing-directory warning) but holds
#     nothing, and every texture falls through to the SD copy. Touches NO
#     config, so the mod manager never sees an out-of-sync openmw.cfg.
#     The eMMC already carries the 891 MB navmesh and the 512 MB swapfile, and
#     benched 2787 KB/s against the SD card's 5213.
#
# Flags are on the SD card so they can be removed over ssh even if a blank
# screen makes the handheld unusable.

if [ -f /mnt/SDCARD/tsp_noscaler ]; then
  tsp_ab_before="$TSP_LD_PRELOAD"
  tsp_ab_keep=""
  tsp_ab_drop=""
  tsp_ab_ifs="$IFS"
  IFS=':'
  for tsp_ab_p in $tsp_ab_before; do
    [ -n "$tsp_ab_p" ] || continue
    case "$tsp_ab_p" in
      *scaler*.so|*Scaler*.so|*SCALER*.so)
        tsp_ab_drop="$tsp_ab_drop $tsp_ab_p"; continue ;;
    esac
    if [ -n "$tsp_ab_keep" ]; then tsp_ab_keep="$tsp_ab_keep:$tsp_ab_p"
    else tsp_ab_keep="$tsp_ab_p"; fi
  done
  IFS="$tsp_ab_ifs"
  TSP_LD_PRELOAD="$tsp_ab_keep"
  export TSP_LD_PRELOAD
  echo "TSP_AB_SWITCH_V1 scaler=OFF dropped=[$tsp_ab_drop] preload=[$TSP_LD_PRELOAD]"
  echo "TSP_AB_SWITCH_V1 scaler=OFF dropped=[$tsp_ab_drop] preload=[$TSP_LD_PRELOAD]" >> "$TSP_PROG"
else
  echo "TSP_AB_SWITCH_V1 scaler=ON preload=[$TSP_LD_PRELOAD]"
  echo "TSP_AB_SWITCH_V1 scaler=ON preload=[$TSP_LD_PRELOAD]" >> "$TSP_PROG"
fi

if [ -f /mnt/SDCARD/tsp_texsd ]; then
  [ -d /mnt/UDISK/openmw-tex/textures ] \
    && mv /mnt/UDISK/openmw-tex/textures /mnt/UDISK/openmw-tex/textures.off 2>/dev/null
  tsp_ab_arm="SD"
else
  [ -d /mnt/UDISK/openmw-tex/textures.off ] \
    && mv /mnt/UDISK/openmw-tex/textures.off /mnt/UDISK/openmw-tex/textures 2>/dev/null
  tsp_ab_arm="UDISK"
fi
if [ -d /mnt/UDISK/openmw-tex/textures ]; then tsp_ab_live="present"; else tsp_ab_live="movedAside"; fi
echo "TSP_AB_SWITCH_V1 texroot=$tsp_ab_arm udisk_textures=$tsp_ab_live"
echo "TSP_AB_SWITCH_V1 texroot=$tsp_ab_arm udisk_textures=$tsp_ab_live" >> "$TSP_PROG"
# =================== end TSP_AB_SWITCH_V1 ====================================

    LD_PRELOAD="$TSP_LD_PRELOAD" "$OPENMW_BIN" \
        --resources "$OPENMW_RESOURCES" \
        --user-data-dir "$SAVE_DIR" \
        --config "$CONFIG_DIR" &

    OPENMW_PID=$!
# >>> TSP_DRAWTHREAD_V1 KEEPER BEGIN
# Main thread stays where TSP_CPU_OPTIMIZE_V2 puts it. The hottest non-main thread (= the OSG draw thread once
# the world is up; 10% hysteresis so a loading worker does not steal the core) is pinned to cpu$TSP_DRAW_CPU and
# every other thread kept off it, re-checked every 5s: tsp_cpu_apply_split scatters them at 8/25/60s and OSG
# re-creates the draw thread with an all-CPU mask on settings changes. Every 60s a sample line (per-thread CPU
# over 10s) goes to this log and tsp_prog.txt. pin=off in the policy file = samples only. Onlined core goes back.
TSP_DRAW_MASK=""; TSP_REST_MASK=""; TSP_IDLE_PARK=0
grep -qs '^idle=main' "$GAMEDIR/tsp_drawthread_policy.txt" && [ -n "${TSP_CPU_MAIN_MASK:-}" ] && TSP_IDLE_PARK=1
if [ -n "$TSP_DRAW_CPU" ] && [ -n "${TSP_CPU_BG_MASK:-}" ] && ! grep -qs '^pin=off' "$GAMEDIR/tsp_drawthread_policy.txt"; then
    TSP_DRAW_MASK=$(printf '%x' $(( 1 << TSP_DRAW_CPU )))
    TSP_REST_MASK=$(printf '%x' $(( 0x$TSP_CPU_BG_MASK & ~(1 << TSP_DRAW_CPU) )))
    [ "$TSP_REST_MASK" = 0 ] && TSP_REST_MASK=$TSP_CPU_BG_MASK
fi
echo "TSP_DRAWTHREAD_V1 armed model=$OSG_THREADING main=cpu${TSP_CPU_MAIN:-?}/${TSP_CPU_MAIN_MASK:-none} draw=cpu${TSP_DRAW_CPU:-none}/${TSP_DRAW_MASK:-none} rest=${TSP_REST_MASK:-${TSP_CPU_BG_MASK:-none}} idle_park=$TSP_IDLE_PARK pid=$OPENMW_PID $(date '+%F %T')" | tee -a "$TSP_PROG_TEE"
tsp_dt_snap() {   # one line per thread: tid ticks lastcpu allowed policy(0=normal 5=SCHED_IDLE)
    for _t in /proc/"$OPENMW_PID"/task/[0-9]*; do
        _s=$(cat "$_t/stat" 2>/dev/null) || continue; _r="${_s##*) }"; set -- $_r
        echo "${_t##*/} $(( ${12} + ${13} )) ${37} $(grep Cpus_allowed_list "$_t/status" 2>/dev/null | cut -f2) ${39}"
    done
}
tsp_dt_mask() { taskset -p "$1" 2>/dev/null | sed 's/.*: *//'; }   # current hex mask of a tid
tsp_dt_wait() {   # 20 samples over ~2s of one tid: R/S/D counts + the two commonest kernel wait channels
    _wt=$1; _wf=/tmp/tsp_dt_w.$OPENMW_PID; : > "$_wf"; _wn=0
    while [ $_wn -lt 20 ]; do
        _ws=$(cat /proc/$OPENMW_PID/task/$_wt/stat 2>/dev/null) || break; _wr="${_ws##*) }"; set -- $_wr
        echo "$1 $(cat /proc/$OPENMW_PID/task/$_wt/wchan 2>/dev/null)" >> "$_wf"; _wn=$((_wn+1)); sleep 0.1 2>/dev/null || sleep 1
    done
    echo "$(cut -c1 "$_wf" | sort | uniq -c | sort -rn | awk '{printf "%s%s,", $2, $1}')$(awk '$1!="R" && NF>1 && $2!="0" {print $2}' "$_wf" | sort | uniq -c | sort -rn | head -2 | awk '{printf " %s(%s)", $2, $1}')"
    rm -f "$_wf"
}
tsp_dt_env() {   # freq of the main and draw cores + hottest thermal zone
    _e="khz=main:$(cat "$TSP_SYS_CPU/cpu${TSP_CPU_MAIN:-0}/cpufreq/scaling_cur_freq" 2>/dev/null)"
    [ -n "$TSP_DRAW_CPU" ] && _e="$_e/draw:$(cat "$TSP_SYS_CPU/cpu$TSP_DRAW_CPU/cpufreq/scaling_cur_freq" 2>/dev/null)"
    _tmax=0; for _z in /sys/class/thermal/thermal_zone*/temp; do _tv=$(cat "$_z" 2>/dev/null); case "$_tv" in ''|*[!0-9]*) continue;; esac; [ "$_tv" -gt "$_tmax" ] && _tmax=$_tv; done
    [ "$_tmax" -gt 1000 ] && _tmax=$((_tmax / 1000))
    echo "$_e temp=$_tmax"
}
(
    _i=0; _draw=""; _A=/tmp/tsp_dt_a.$OPENMW_PID; _P=/tmp/tsp_dt_p.$OPENMW_PID; _S1=/tmp/tsp_dt_s1.$OPENMW_PID; _S2=/tmp/tsp_dt_s2.$OPENMW_PID
    tsp_dt_snap > "$_P"
    while kill -0 "$OPENMW_PID" 2>/dev/null; do
        _i=$((_i+1))
        if [ -n "$TSP_DRAW_MASK" ] && [ $((_i % 5)) = 0 ]; then
            tsp_dt_snap > "$_A"
            set -- $(awk -v main="$OPENMW_PID" -v cur="$_draw" 'NR==FNR { t0[$1]=$2; next } ($1 in t0 && $1!=main && $5!=5) { d=$2-t0[$1]; if ($1==cur) cd=d; if (d>best) { best=d; tid=$1 } } END { if (best>=75) printf "%s %d %d\n", tid, best/5, cd/5 }' "$_P" "$_A")
            cp "$_A" "$_P"
            if [ -n "${1:-}" ] && [ "$1" != "$_draw" ] && { [ -z "$_draw" ] || [ "$2" -ge $(( ${3:-0} + 10 )) ]; }; then
                [ -n "$_draw" ] && taskset -p "$TSP_REST_MASK" "$_draw" >/dev/null 2>&1
                taskset -p "$TSP_DRAW_MASK" "$1" >/dev/null 2>&1 && echo "TSP_DRAWTHREAD_V1 pin draw tid=$1 (${2}%, was tid=${_draw:-none} ${3:-0}%) -> cpu$TSP_DRAW_CPU at +${_i}s"
                _draw=$1
            fi
            if [ -n "$_draw" ]; then
                for _t in /proc/"$OPENMW_PID"/task/[0-9]*; do
                    _tid=${_t##*/}; _m=$(tsp_dt_mask "$_tid"); [ -n "$_m" ] || continue
                    if [ "$TSP_IDLE_PARK" = 1 ] && [ "$(awk -v t="$_tid" '$1==t {print $5}' "$_A")" = 5 ]; then
                        [ $(( 0x$_m )) = $(( 0x$TSP_CPU_MAIN_MASK )) ] || { taskset -p "$TSP_CPU_MAIN_MASK" "$_tid" >/dev/null 2>&1 && echo "TSP_DRAWTHREAD_V1 park SCHED_IDLE tid=$_tid was $_m -> cpu$TSP_CPU_MAIN (idle=main) at +${_i}s"; }
                    elif [ "$_tid" = "$_draw" ]; then
                        [ $(( 0x$_m )) = $(( 0x$TSP_DRAW_MASK )) ] || { taskset -p "$TSP_DRAW_MASK" "$_tid" >/dev/null 2>&1 && echo "TSP_DRAWTHREAD_V1 re-pin draw tid=$_tid was $_m -> cpu$TSP_DRAW_CPU at +${_i}s"; }
                    elif [ "$_tid" = "$OPENMW_PID" ]; then
                        [ $(( 0x$_m )) = $(( 0x$TSP_CPU_MAIN_MASK )) ] || taskset -p "$TSP_CPU_MAIN_MASK" "$_tid" >/dev/null 2>&1
                    elif [ $(( 0x$_m & (1 << TSP_DRAW_CPU) )) != 0 ]; then
                        taskset -p "$TSP_REST_MASK" "$_tid" >/dev/null 2>&1
                    fi
                done
            fi
        fi
        case $((_i % 60)) in
            20) tsp_dt_snap > "$_S1" ;;
            30) tsp_dt_snap > "$_S2"
                _wm=$(tsp_dt_wait "$OPENMW_PID"); _wd=""; [ -n "$_draw" ] && _wd=$(tsp_dt_wait "$_draw")
                awk -v main="$OPENMW_PID" -v at="$_i" -v model="$OSG_THREADING" -v env="$(tsp_dt_env)" -v wm="$_wm" -v wd="$_wd" -v draw="$_draw" 'NR==FNR { t0[$1]=$2; next } ($1 in t0) { d=($2-t0[$1])/10.0; if (d>=20) hot++; tot+=d; if (d>=5) top=top " " $1 ($1==main ? "(main)" : ($1==draw ? "(draw)" : "")) "=" int(d+0.5) "%@cpu" $3 "/" $4 ($5==5 ? "/IDLE" : "") } END { printf "TSP_DRAWTHREAD_V1 sample +%ss model=%s hot(>=20%%)=%d total=%.0f%% %s threads:%s | wait main=%s draw=%s\n", at, model, hot, tot, env, top, wm, wd }' "$_S1" "$_S2" | tee -a "$TSP_PROG_TEE" ;;
        esac
        sleep 1
    done
    rm -f "$_A" "$_P" "$_S1" "$_S2"
    [ -n "$TSP_DRAW_ONLINED" ] && { echo 0 > "$TSP_SYS_CPU/cpu$TSP_DRAW_ONLINED/online" 2>/dev/null; echo "TSP_DRAWTHREAD_V1 cpu$TSP_DRAW_ONLINED back offline: online_now=$(cat "$TSP_SYS_CPU/online" 2>/dev/null)"; }
    tsp_cpuclock_restore 2>/dev/null || true
) &
TSP_DRAWTHREAD_KEEPER_PID=$!
# <<< TSP_DRAWTHREAD_V1 KEEPER END
    tsp_cpu_apply_split "$OPENMW_PID" &
# >>> TSP_V36_PERF_MONITOR_START BEGIN
if [ "$TSP_QUIET" = 1 ]; then TSP_PERF_MONITOR_PID=""; else   # TSP_QUIET_V1 PERF
tsp_perf_sampler "$OPENMW_PID" &
TSP_PERF_MONITOR_PID=$!
fi

echo "Performance telemetry: $TSP_PERF_LOG"
echo "Performance monitor pid: $TSP_PERF_MONITOR_PID"
# <<< TSP_V36_PERF_MONITOR_START END
    echo "OpenMW pid: $OPENMW_PID"

    wait "$OPENMW_PID"
    OPENMW_EXIT_CODE=$?
    tsp_lever_restore 2>/dev/null || true
# >>> TSP_V36_PERF_MONITOR_STOP BEGIN
if [ -n "${TSP_PERF_MONITOR_PID:-}" ]; then
    kill         "$TSP_PERF_MONITOR_PID"         2>/dev/null ||
        true

    wait         "$TSP_PERF_MONITOR_PID"         2>/dev/null ||
        true

    TSP_PERF_MONITOR_PID=""
fi
# <<< TSP_V36_PERF_MONITOR_STOP END
    OPENMW_PID=""

    echo "OpenMW 0.51 exited with code: $OPENMW_EXIT_CODE"

    if [ -f "$RESOLUTION_RESTART_MARKER" ]; then
        REQUESTED_RESOLUTION="$(
            tr -d '\r\n' < "$RESOLUTION_RESTART_MARKER" 2>/dev/null
        )"

        rm -f "$RESOLUTION_RESTART_MARKER" 2>/dev/null || true

        echo
        echo "============================================================"
        echo "TSP AUTOMATIC INTERNAL-RESOLUTION RESTART"
        echo "============================================================"
        echo "Requested: ${REQUESTED_RESOLUTION:-unknown}"
        echo "OpenMW saved settings.cfg successfully."
        echo "Restarting OpenMW now..."
        echo "============================================================"
        echo

        sync
        sleep 1
        continue
    fi

    echo "TSP resolution launcher: normal game exit"
    break
done

cleanup_helper
CONTROL_HELPER_PID=""

# TSP text helper logging is no longer persisted now that input is verified.
rm -f "$CONTROL_HELPER_LOG" 2>/dev/null || true

pm_gptokeyb_finish
pm_finish

exit "$OPENMW_EXIT_CODE"

# TSP_V16_GL4ES_TEXTURE_WATERFIX
