#!/bin/bash

# OpenMW 0.51 fixed separate port root.
# Do not auto-create alternate game roots; a bad path should fail instead of
# silently creating an empty phantom directory.
GAMEDIR="/mnt/SDCARD/data/ports/openmw51"

if [ ! -d "$GAMEDIR" ]; then
    FALLBACK_LOG="/tmp/openmw_051_log.txt"
    {
        echo "Launcher entered at: $(date)"
        echo "ERROR: OpenMW 0.51 game directory does not exist:"
        echo "  $GAMEDIR"
    } > "$FALLBACK_LOG" 2>&1
    exit 1
fi

LOG_FILE="$GAMEDIR/openmw_051_log.txt"
: > "$LOG_FILE"
exec >> "$LOG_FILE" 2>&1

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
CONFIG_DIR="$GAMEDIR/config-0.51"
SAVE_DIR="$GAMEDIR/savegame-0.51"
TEXCACHE_DIR="$GAMEDIR/texcache-0.51"
CONTROL_HELPER="$GAMEDIR/tsp_openmw_controls"
CONTROL_HELPER_LOG="/tmp/tsp_controls_051.log"
CONTROL_HELPER_PID=""
OPENMW_PID=""

# TSP_INTERNAL_RESOLUTION_RESTART_MARKER_051_V20R4
RESOLUTION_RESTART_MARKER="$GAMEDIR/.openmw51-resolution-restart"
export OPENMW_TSP_RESTART_MARKER="$RESOLUTION_RESTART_MARKER"
# Logging already started at the top of the launcher and remains on the
# same root-level text file for the entire run.

echo
echo "=========================================="
echo "Starting OpenMW 0.51 on TrimUI Smart Pro"
echo "Launcher: Morrowind_51.sh"
echo "Mode: native OpenMW controller + hybrid mouse/text helper"
echo "Date: $(date)"
echo "Game directory: $GAMEDIR"
echo "Runtime: $RUNTIME"
echo "=========================================="

export XDG_RUNTIME_DIR="/tmp/runtime-root"
export OSG_THREADING=SingleThreaded

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

echo "Launcher revision: openmw51-hybrid-controls-2026-08-07-v7"
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

export OSG_LIBRARY_PATH="$GAMEDIR/osgPlugins-3.6.5"

CONTROLLER_DB_FILE="$GAMEDIR/gamecontrollerdb_tsp_0.51.txt"

cat > "$CONTROLLER_DB_FILE" <<'EOF_CONTROLLER_DB'
0300a3845e0400008e02000014010000,TRIMUI Player1,a:b1,b:b0,x:b3,y:b2,back:b7,start:b6,leftstick:b9,rightstick:b10,leftshoulder:b4,rightshoulder:b5,lefttrigger:a2,righttrigger:a5,leftx:a0,lefty:a1,rightx:a3,righty:a4,dpup:h0.1,dpdown:h0.4,dpleft:h0.8,dpright:h0.2,platform:Linux,
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

required_paths=(
    "$OPENMW_BIN"
    "$CONTROL_HELPER"
    "$OPENMW_RESOURCES"
    "$OPENMW_RESOURCES/defaults.bin"
    "$OPENMW_RESOURCES/vfs"
    "$OPENMW_RESOURCES/vfs-mw"
    "$OPENMW_LIB/libMyGUIEngine.so.3.4.3"
    "$OPENMW_LIB/libstdc++.so.6"
    "$OPENMW_LIB/libgcc_s.so.1"
)

for required in "${required_paths[@]}"; do
    if [ ! -e "$required" ]; then
        echo "ERROR: Required OpenMW 0.51 runtime item is missing:"
        echo "  $required"
        pm_gptokeyb_finish
        pm_finish
        exit 1
    fi
done

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
CURSOR_DEBUG_LOG="$GAMEDIR/cursor-launcher-debug.log"

{
    echo
    echo "============================================================"
    echo "TSP CURSOR DIAGNOSTICS"
    echo "============================================================"
    echo "Date: $(date)"
    echo

    echo "----- PATHS -----"
    echo "GAMEDIR=${GAMEDIR:-unset}"
    echo "OPENMW_BIN=${OPENMW_BIN:-unset}"
    echo "OPENMW_RESOURCES=${OPENMW_RESOURCES:-unset}"
    echo "OPENMW_LIB=${OPENMW_LIB:-unset}"
    echo "CONFIG_DIR=${CONFIG_DIR:-unset}"
    echo "SAVE_DIR=${SAVE_DIR:-unset}"
    echo "SETTINGS_FILE=${SETTINGS_FILE:-unset}"
    echo

    echo "----- OPENMW BINARY -----"

    if [ -f "${OPENMW_BIN:-}" ]; then
        ls -lh "$OPENMW_BIN" || true
        file "$OPENMW_BIN" || true
        sha256sum "$OPENMW_BIN" || true

        echo
        echo "Cursor debug marker inside binary:"

        if command -v strings >/dev/null 2>&1; then
            if strings "$OPENMW_BIN" | grep -F 'TSP_CURSOR_DEBUG' ; then
                echo "FOUND diagnostic cursor code in binary."
            else
                echo "WARNING: TSP_CURSOR_DEBUG string NOT FOUND in binary."
            fi
        else
            echo "strings command unavailable."
        fi
    else
        echo "ERROR: OpenMW binary not found."
    fi

    echo
    echo "----- SDL / GL / DISPLAY ENVIRONMENT -----"

    env | grep -E \
        '^(SDL|LIBGL|DISPLAY|WAYLAND|XDG|OPENMW|OSG)_' \
        | sort || true

    echo
    echo "----- CONTROLLER -----"
    echo "SDL_GAMECONTROLLERCONFIG_FILE=${SDL_GAMECONTROLLERCONFIG_FILE:-unset}"
    echo "CONTROL_HELPER=${CONTROL_HELPER:-unset}"
    echo "CONTROL_HELPER_PID=${CONTROL_HELPER_PID:-unset}"

    if [ -n "${CONTROL_HELPER_PID:-}" ]; then
        if kill -0 "$CONTROL_HELPER_PID" 2>/dev/null; then
            echo "Helper process: RUNNING"
        else
            echo "Helper process: NOT RUNNING"
        fi
    fi

    echo
    echo "----- SETTINGS: GUI / HUD / INPUT -----"

    if [ -f "${SETTINGS_FILE:-}" ]; then
        awk '
            /^\[(GUI|HUD|Input)\]$/ {
                show = 1
                print
                next
            }

            /^\[/ {
                show = 0
            }

            show {
                print
            }
        ' "$SETTINGS_FILE"
    else
        echo "settings.cfg not found."
    fi

    echo
    echo "----- CURSOR / POINTER RESOURCE FILES -----"

    if [ -d "${OPENMW_RESOURCES:-}" ]; then
        find "$OPENMW_RESOURCES" -type f 2>/dev/null \
            | grep -Ei '(cursor|pointer)' \
            | sort \
            | head -100 || true
    else
        echo "Resources directory not found."
    fi

    echo
    echo "----- ResourceImageSetPointerFix -----"

    if [ -d "${OPENMW_RESOURCES:-}" ]; then
        grep -Rsn \
            'ResourceImageSetPointerFix' \
            "$OPENMW_RESOURCES" \
            2>/dev/null \
            | head -100 || true
    fi

    echo
    echo "----- ARROW POINTER DEFINITIONS -----"

    if [ -d "${OPENMW_RESOURCES:-}" ]; then
        grep -RsnE \
            'name="arrow"|name=.arrow.' \
            "$OPENMW_RESOURCES" \
            2>/dev/null \
            | head -100 || true
    fi

    echo
    echo "----- MyGUI / SDL LIBRARIES -----"

    if [ -d "${OPENMW_LIB:-}" ]; then
        ls -lh \
            "$OPENMW_LIB"/libMyGUI* \
            "$OPENMW_LIB"/libSDL2* \
            2>/dev/null || true
    fi

    if command -v ldd >/dev/null 2>&1 && [ -f "${OPENMW_BIN:-}" ]; then
        echo
        echo "Runtime-linked libraries:"
        ldd "$OPENMW_BIN" 2>/dev/null \
            | grep -Ei 'MyGUI|SDL|libGL|libEGL|GLES' \
            || true
    fi

    echo
    echo "----- TEXT HELPER FLAGS BEFORE OPENMW -----"

    if [ -e /tmp/openmw-tsp-text-active ]; then
        echo "/tmp/openmw-tsp-text-active EXISTS"
    else
        echo "/tmp/openmw-tsp-text-active absent"
    fi

    if [ -e /tmp/openmw-tsp-text-char ]; then
        echo "/tmp/openmw-tsp-text-char EXISTS"
        cat /tmp/openmw-tsp-text-char 2>/dev/null || true
    else
        echo "/tmp/openmw-tsp-text-char absent"
    fi

    echo
    echo "============================================================"
    echo "END PRE-LAUNCH CURSOR DIAGNOSTICS"
    echo "============================================================"
    echo

} 2>&1 | tee "$CURSOR_DEBUG_LOG"


echo "Launching OpenMW 0.51..."








# >>> TSP_V19_RUNTIME_PROFILE BEGIN

# Normal gameplay: expensive diagnostic samplers OFF.
export OPENMW_TSP_DEEP_DEBUG=0

# Keep FPS visible for initial benchmarking.
export OPENMW_TSP_SHOW_FPS=1

# Failed GL4ES intermediary framebuffer experiment stays OFF.
unset LIBGL_FB
unset LIBGL_FBO
unset LIBGL_RECYCLEFBO

# >>> Deep diagnostics can temporarily be restored with:
# export OPENMW_TSP_DEEP_DEBUG=1

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

    export LD_PRELOAD="$GAMEDIR/lib/libtsp_fullscreen_scaler.so:$TSP_GL4ES_LIBRARY"

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
unset OPENMW_TSP_LOADING_BYPASS

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

python3 - "$GAMEDIR/config-0.51/settings.cfg" "$TSP_UI_FONT_SIZE" <<'TSP_FONT_PY'
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

TSP_PERF_LOG="$GAMEDIR/openmw51_perf_latest.txt"
TSP_PERF_PREVIOUS="$GAMEDIR/openmw51_perf_previous.txt"
TSP_PERF_SETTINGS="$GAMEDIR/config-0.51/settings.cfg"
TSP_PERF_MONITOR_PID=""

export OPENMW_TSP_DEEP_DEBUG=0
export OPENMW_TSP_SHOW_FPS=1

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
            "OPENMW_TSP_DEEP_DEBUG=" \
            "${OPENMW_TSP_DEEP_DEBUG:-unset}"

        echo \
            "OPENMW_TSP_SHOW_FPS=" \
            "${OPENMW_TSP_SHOW_FPS:-unset}"

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

        ELAPSED=$(
            SECONDS - START_SECONDS
        )

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

# <<< TSP_V36_PERF_TELEMETRY END
export LIBGL_TSP_NORGBFIX=1
export LIBGL_TSP_NODEPTHFIX=1

export LIBGL_TSP_WATCH=/mnt/SDCARD/tsp_watch.txt
export LIBGL_TSP_WATCH_FBONLY=1
export LIBGL_TSP_FBFLUSH=flush
export LIBGL_TSP_DT=/mnt/SDCARD/tsp_dt.txt
export LIBGL_TSP_LATEDETECT=1
export LIBGL_NOTEXMAT=0
export LIBGL_TSP_DEPTH=24
export LIBGL_TSP_DERIVATIVES=1
export LIBGL_FBCONVERT=1
    "$OPENMW_BIN" \
        --resources "$OPENMW_RESOURCES" \
        --user-data-dir "$SAVE_DIR" \
        --config "$CONFIG_DIR" &

    OPENMW_PID=$!
# >>> TSP_V36_PERF_MONITOR_START BEGIN
tsp_perf_monitor "$OPENMW_PID" &
TSP_PERF_MONITOR_PID=$!

echo "Performance telemetry: $TSP_PERF_LOG"
echo "Performance monitor pid: $TSP_PERF_MONITOR_PID"
# <<< TSP_V36_PERF_MONITOR_START END
    echo "OpenMW pid: $OPENMW_PID"

    wait "$OPENMW_PID"
    OPENMW_EXIT_CODE=$?
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
