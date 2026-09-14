#!/bin/bash

# Force Bash even if the frontend invokes this script through /bin/sh.
if [ -z "${BASH_VERSION:-}" ]; then
    exec /bin/bash "$0" "$@"
fi

# Start an emergency log before doing anything else.
EARLY_LOG="/mnt/SDCARD/data/ports/openmw/launcher_early.log"
mkdir -p "/mnt/SDCARD/data/ports/openmw" 2>/dev/null || true
: > "$EARLY_LOG" 2>/dev/null || EARLY_LOG="/tmp/openmw_launcher_early.log"
exec >> "$EARLY_LOG" 2>&1

echo "Launcher entered at: $(date)"
echo "Shell: $0"
echo "Bash version: ${BASH_VERSION:-unknown}"
echo "Arguments: $*"

# 1. Locate the OpenMW port directory
if [ -d "/mnt/SDCARD/data/ports/openmw" ]; then
    GAMEDIR="/mnt/SDCARD/data/ports/openmw"
elif [ -d "/mnt/SDCARD/Roms/PORTS/openmw" ]; then
    GAMEDIR="/mnt/SDCARD/Roms/PORTS/openmw"
else
    echo "ERROR: OpenMW game directory was not found."
    exit 1
fi

if ! cd "$GAMEDIR"; then
    echo "ERROR: Could not enter $GAMEDIR"
    exit 1
fi

# 2. Logging
LOG_FILE="$GAMEDIR/log.txt"

rm -f "$LOG_FILE"
exec >> "$LOG_FILE" 2>&1

echo "Early launcher output:"
cat "$EARLY_LOG" 2>/dev/null || true
echo ""
echo "=========================================="
echo "Starting OpenMW on TrimUI Smart Pro..."
echo "OPENMW TSP BUILD: RESTORED_GRAPHICS_4800_PERSISTENT_SETTINGS_V5"
echo "Date: $(date)"
echo "Game Directory: $GAMEDIR"
echo "=========================================="

# 3. Runtime, config, and save directories
export XDG_RUNTIME_DIR="/tmp/runtime-root"

CONFIG_DIR="$GAMEDIR/config"

# Permanent save location on the SD card.
SD_SAVE_DIR="$GAMEDIR/savegame"

# OpenMW can directly load saves from the SD card, but this build does not
# enumerate them in the Load menu. Use a native Linux runtime directory for
# OpenMW's user-data path and copy only saves/screenshots between it and SD.
SAVE_DIR="/tmp/openmw-savegame"

mkdir -p "$XDG_RUNTIME_DIR"
chmod 0700 "$XDG_RUNTIME_DIR"

mkdir -p "$CONFIG_DIR"
mkdir -p "$CONFIG_DIR/openmw"

mkdir -p "$SD_SAVE_DIR"
mkdir -p "$SD_SAVE_DIR/saves"
mkdir -p "$SD_SAVE_DIR/data"
mkdir -p "$SD_SAVE_DIR/screenshots"
mkdir -p "$GAMEDIR/texcache"

# Always begin with a clean runtime tree so deleted/renamed saves do not
# survive from a previous launch.
rm -rf "$SAVE_DIR"
mkdir -p "$SAVE_DIR/saves"
mkdir -p "$SAVE_DIR/screenshots"

# Stage existing saves onto the native /tmp filesystem for menu enumeration.
cp -R "$SD_SAVE_DIR/saves/." "$SAVE_DIR/saves/" 2>/dev/null || true
cp -R "$SD_SAVE_DIR/screenshots/." "$SAVE_DIR/screenshots/" 2>/dev/null || true

echo ""
echo "=========================================="
echo "Save menu staging"
echo "=========================================="
echo "Permanent saves: $SD_SAVE_DIR/saves"
echo "Runtime saves:   $SAVE_DIR/saves"
echo "Staged save count:"
find "$SAVE_DIR/saves" -type f -iname '*.omwsave' 2>/dev/null | wc -l
echo "Staged character folders:"
find "$SAVE_DIR/saves" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort || true
echo "=========================================="

export XDG_DATA_HOME="$CONFIG_DIR"
export XDG_CONFIG_HOME="$CONFIG_DIR"
export OPENMW_RESOURCES="$GAMEDIR/resources"

# Remove bundled SDL libraries so the TrimUI system SDL is used
rm -f "$GAMEDIR/lib"/libSDL2* 2>/dev/null
rm -f "$GAMEDIR/libs"/libSDL2* 2>/dev/null

# 4. PortMaster integration
XDG_DATA_HOME_PM=${XDG_DATA_HOME_PM:-$HOME/.local/share}

if [ -f "/mnt/SDCARD/Apps/PortMaster/control.txt" ]; then
    controlfolder="/mnt/SDCARD/Apps/PortMaster"
elif [ -f "/opt/system/Tools/PortMaster/control.txt" ]; then
    controlfolder="/opt/system/Tools/PortMaster"
elif [ -f "/opt/tools/PortMaster/control.txt" ]; then
    controlfolder="/opt/tools/PortMaster"
elif [ -f "$XDG_DATA_HOME_PM/PortMaster/control.txt" ]; then
    controlfolder="$XDG_DATA_HOME_PM/PortMaster"
elif [ -f "/mnt/SDCARD/data/ports/PortMaster/control.txt" ]; then
    controlfolder="/mnt/SDCARD/data/ports/PortMaster"
else
    controlfolder="/roms/ports/PortMaster"
fi

echo "PortMaster control folder: $controlfolder"
echo "PortMaster candidate check:"
for candidate in     "/mnt/SDCARD/Apps/PortMaster"     "/opt/system/Tools/PortMaster"     "/opt/tools/PortMaster"     "$XDG_DATA_HOME_PM/PortMaster"     "/mnt/SDCARD/data/ports/PortMaster"     "/roms/ports/PortMaster"
do
    if [ -f "$candidate/control.txt" ]; then
        echo "FOUND: $candidate/control.txt"
    fi
done

if [ -f "$controlfolder/control.txt" ]; then
    source "$controlfolder/control.txt"
else
    echo "WARNING: PortMaster control.txt was not found."
fi

if type get_controls >/dev/null 2>&1; then
    get_controls 2>/dev/null || true
fi

echo "After loading PortMaster:"
echo "CFW_NAME=${CFW_NAME:-unknown}"
echo "DEVICE_NAME=${DEVICE_NAME:-unknown}"
echo "DEVICE_CPU=${DEVICE_CPU:-unknown}"
echo "DEVICE_ARCH=${DEVICE_ARCH:-unknown}"

if type pm_platform_helper >/dev/null 2>&1; then
    echo "pm_platform_helper: available"
else
    echo "pm_platform_helper: unavailable"
fi

if [ -n "${CFW_NAME:-}" ] &&
   [ -f "${controlfolder}/mod_${CFW_NAME}.txt" ]; then
    source "${controlfolder}/mod_${CFW_NAME}.txt"
fi

if ! type pm_finish >/dev/null 2>&1; then
    pm_finish() {
        true
    }
fi

if ! type pm_gptokeyb_finish >/dev/null 2>&1; then
    pm_gptokeyb_finish() {
        GPTOKEY_PID="$(pidof gptokeyb 2>/dev/null || true)"

        if [ -n "$GPTOKEY_PID" ]; then
            ${ESUDO:-} kill -9 $GPTOKEY_PID 2>/dev/null || true
        fi
    }
fi

# 5. Platform and library setup
export DEVICE_ARCH="${DEVICE_ARCH:-aarch64}"
export PATH="$GAMEDIR:$GAMEDIR/bin.${DEVICE_ARCH}:$PATH"

# Patched OSG and other bundled dependencies.
# GL4ES should not be stored in $GAMEDIR/lib for this test.
export LD_LIBRARY_PATH="$GAMEDIR:$GAMEDIR/lib:$GAMEDIR/libs:$GAMEDIR/lib/aarch64:${LD_LIBRARY_PATH:-}"

if [ -d "$GAMEDIR/libs.${DEVICE_ARCH}" ]; then
    export LD_LIBRARY_PATH="$GAMEDIR/libs.${DEVICE_ARCH}:$LD_LIBRARY_PATH"
fi

if [ -n "${CFW_NAME:-}" ] &&
   [ -d "$GAMEDIR/libs.${CFW_NAME}.${DEVICE_ARCH}" ]; then
    export LD_LIBRARY_PATH="$GAMEDIR/libs.${CFW_NAME}.${DEVICE_ARCH}:$LD_LIBRARY_PATH"
fi

if [ -n "${CFW_NAME:-}" ] &&
   [ -d "$GAMEDIR/libs.${CFW_NAME}" ]; then
    export LD_LIBRARY_PATH="$GAMEDIR/libs.${CFW_NAME}:$LD_LIBRARY_PATH"
fi

export OSG_LIBRARY_PATH="$GAMEDIR/osgPlugins-3.6.5"

# OpenMW/GL4ES settings used by the official PortMaster launcher.
#
# Exact TrimUI Smart Pro controller mapping.
#
# The physical labels do not match SDL's assumed face-button layout:
#   Physical A = Linux BTN_EAST
#   Physical B = Linux BTN_SOUTH
#   Physical X = Linux BTN_WEST
#   Physical Y = Linux BTN_NORTH
#
# The measured event ordering is:
#   b0=B, b1=A, b2=Y, b3=X
#   b4=L1, b5=R1, b6=Start, b7=Select
#   b9=L3, b10=R3
#
# gptokeyb2 is explicitly given a controller database file. This is
# important because relying only on the inline SDL variable left Start
# and Select reversed inside the mapper on this device.
# gptokeyb2 must see the physical Menu button as SDL Guide so it can
# use Menu as the advanced-control modifier and Menu+Start exit combo.
MAPPER_CONTROLLER_DB_FILE="$GAMEDIR/gamecontrollerdb_tsp_mapper.txt"

cat > "$MAPPER_CONTROLLER_DB_FILE" <<'EOF_MAPPER_CONTROLLER_DB'
0300a3845e0400008e02000014010000,TRIMUI Player1,a:b1,b:b0,x:b3,y:b2,back:b7,start:b6,guide:b8,leftstick:b9,rightstick:b10,leftshoulder:b4,rightshoulder:b5,lefttrigger:a2,righttrigger:a5,leftx:a0,lefty:a1,rightx:a3,righty:a4,dpup:h0.1,dpdown:h0.4,dpleft:h0.8,dpright:h0.2,platform:Linux,
EOF_MAPPER_CONTROLLER_DB

# OpenMW must not see b8 as SDL Guide. OpenMW binds Guide to Quick Save,
# which caused every Menu press to save even when it was only being used
# as the gptokeyb2 modifier.
OPENMW_CONTROLLER_DB_FILE="$GAMEDIR/gamecontrollerdb_tsp_openmw.txt"

cat > "$OPENMW_CONTROLLER_DB_FILE" <<'EOF_OPENMW_CONTROLLER_DB'
0300a3845e0400008e02000014010000,TRIMUI Player1,a:b1,x:b3,y:b2,back:b7,leftstick:b9,rightshoulder:b5,lefttrigger:a2,righttrigger:a5,leftx:a0,lefty:a1,rightx:a3,righty:a4,dpup:h0.1,dpdown:h0.4,dpleft:h0.8,dpright:h0.2,platform:Linux,
EOF_OPENMW_CONTROLLER_DB

# Start with the mapper mapping. This environment is inherited by
# gptokeyb2 when it starts.
export SDL_GAMECONTROLLERCONFIG_FILE="$MAPPER_CONTROLLER_DB_FILE"
export SDL_GAMECONTROLLERCONFIG="$(cat "$MAPPER_CONTROLLER_DB_FILE")"
CONTROLLER_DB="$MAPPER_CONTROLLER_DB_FILE"

export OPENMW_DECOMPRESS_TEXTURES=1

export LIBGL_STREAM=1
export LIBGL_NOTEST=1
export LIBGL_FORCENPOT=1
export LIBGL_MIPMAP=3

export LIBGL_TEXPATH="$GAMEDIR/texcache/"
export LIBGL_RECOMPTEX=0
export LIBGL_NOMIPMAPS=0
export LIBGL_FORCE16BITS=1
export LIBGL_SHRINK=2

# Let PortMaster choose the correct CFW-specific GL4ES configuration.
echo ""
echo "=========================================="
echo "PortMaster graphics setup"
echo "=========================================="
echo "CFW_NAME=${CFW_NAME:-unknown}"
echo "CFW_VERSION=${CFW_VERSION:-unknown}"
echo "DEVICE_NAME=${DEVICE_NAME:-unknown}"
echo "DEVICE_CPU=${DEVICE_CPU:-unknown}"
echo "DEVICE_ARCH=${DEVICE_ARCH:-unknown}"

if [ -n "${CFW_NAME:-}" ] &&
   [ -f "${controlfolder}/libgl_${CFW_NAME}.txt" ]; then
    echo "Sourcing ${controlfolder}/libgl_${CFW_NAME}.txt"
    source "${controlfolder}/libgl_${CFW_NAME}.txt"
elif [ -f "${controlfolder}/libgl_default.txt" ]; then
    echo "Sourcing ${controlfolder}/libgl_default.txt"
    source "${controlfolder}/libgl_default.txt"
else
    echo "WARNING: No PortMaster GL4ES configuration file was found."
fi

echo ""
echo "LD_LIBRARY_PATH after PortMaster graphics setup:"
echo "$LD_LIBRARY_PATH"
echo "=========================================="

# Keep useful OpenMW output but reduce unrelated OSG verbosity
export OSG_NOTIFY_LEVEL=WARN
export OPENMW_DEBUG_LEVEL=warning
export OPENMW_RECAST_MAX_LOG_LEVEL=warning

# 6. Locate Morrowind data
TARGET_DATA_DIR="$GAMEDIR/data"

if [ -d "$GAMEDIR/data/Data Files" ]; then
    TARGET_DATA_DIR="$GAMEDIR/data/Data Files"
fi

# 7. Generate the main OpenMW config
BASE_CFG="$GAMEDIR/openmw.base.cfg"
LOCAL_CFG="$GAMEDIR/openmw.cfg"

if [ ! -f "$BASE_CFG" ]; then
    echo "ERROR: Missing complete OpenMW base config:"
    echo "$BASE_CFG"

    pm_gptokeyb_finish
    pm_finish
    exit 1
fi

# Create the portable main config only when it is missing. Once created, it is
# user-owned and is never replaced at launch, so manual edits remain intact.
if [ ! -f "$LOCAL_CFG" ]; then
    cp -f "$BASE_CFG" "$LOCAL_CFG"

    sed -i '/^resources=/d' "$LOCAL_CFG"
    sed -i '/^data-local=/d' "$LOCAL_CFG"
    sed -i '/^user-data=/d' "$LOCAL_CFG"
    sed -i '/^config=/d' "$LOCAL_CFG"
    sed -i '/^data=/d' "$LOCAL_CFG"

    cat << EOF >> "$LOCAL_CFG"

# TrimUI Smart Pro portable paths
resources=$GAMEDIR/resources
data=$GAMEDIR/resources/vfs
data=$TARGET_DATA_DIR
user-data=$SAVE_DIR
data-local=$SD_SAVE_DIR/data
config=$CONFIG_DIR
EOF

    echo "Created persistent main config: $LOCAL_CFG"
else
    echo "Keeping existing persistent main config: $LOCAL_CFG"
fi

# 8. Generate the user content config
write_user_cfg() {
    CFG_FILE="$1"

    mkdir -p "$(dirname "$CFG_FILE")"

    cat << EOF > "$CFG_FILE"
fallback-archive=Morrowind.bsa
content=Morrowind.esm
EOF

    if [ -f "$TARGET_DATA_DIR/Tribunal.esm" ]; then
        if [ -f "$TARGET_DATA_DIR/Tribunal.bsa" ]; then
            echo "fallback-archive=Tribunal.bsa" >> "$CFG_FILE"
        fi

        echo "content=Tribunal.esm" >> "$CFG_FILE"
    fi

    if [ -f "$TARGET_DATA_DIR/Bloodmoon.esm" ]; then
        if [ -f "$TARGET_DATA_DIR/Bloodmoon.bsa" ]; then
            echo "fallback-archive=Bloodmoon.bsa" >> "$CFG_FILE"
        fi

        echo "content=Bloodmoon.esm" >> "$CFG_FILE"
    fi
}

# Create user content configs only once. OpenMW and the user may update these
# files later; subsequent launches must not erase content or archive changes.
if [ ! -f "$CONFIG_DIR/openmw.cfg" ]; then
    write_user_cfg "$CONFIG_DIR/openmw.cfg"
    echo "Created persistent user content config: $CONFIG_DIR/openmw.cfg"
else
    echo "Keeping existing user content config: $CONFIG_DIR/openmw.cfg"
fi

if [ ! -f "$CONFIG_DIR/openmw/openmw.cfg" ]; then
    write_user_cfg "$CONFIG_DIR/openmw/openmw.cfg"
    echo "Created compatibility user config: $CONFIG_DIR/openmw/openmw.cfg"
else
    echo "Keeping existing compatibility user config: $CONFIG_DIR/openmw/openmw.cfg"
fi

# 8B. Override the OpenMW save-dialog character ComboBox.
#
# The saves are discovered correctly, but on this MyGUI/handheld build the
# character dropdown opens with an almost zero-height popup. OpenMW 0.48 can
# load GUI layout overrides from a later VFS data directory, so copy the
# version-matched layout into data-local and force a usable list height.
SAVE_DIALOG_SOURCE=""
SAVE_DIALOG_OVERRIDE_DIR="$SD_SAVE_DIR/data/mygui"
SAVE_DIALOG_OVERRIDE="$SAVE_DIALOG_OVERRIDE_DIR/openmw_savegame_dialog.layout"

for candidate in \
    "$GAMEDIR/resources/vfs/mygui/openmw_savegame_dialog.layout" \
    "$GAMEDIR/resources/mygui/openmw_savegame_dialog.layout" \
    "$GAMEDIR/openmw/resources/vfs/mygui/openmw_savegame_dialog.layout"
do
    if [ -f "$candidate" ]; then
        SAVE_DIALOG_SOURCE="$candidate"
        break
    fi
done

echo ""
echo "=========================================="
echo "Save-dialog dropdown override"
echo "=========================================="
echo "Source layout: ${SAVE_DIALOG_SOURCE:-not found}"
echo "Override layout: $SAVE_DIALOG_OVERRIDE"

if [ -n "$SAVE_DIALOG_SOURCE" ]; then
    mkdir -p "$SAVE_DIALOG_OVERRIDE_DIR"

    python3 - \
        "$SAVE_DIALOG_SOURCE" \
        "$SAVE_DIALOG_OVERRIDE" <<'PY_SAVE_DIALOG'
import os
import re
import sys

source_path = sys.argv[1]
output_path = sys.argv[2]

with open(source_path, "r", encoding="utf-8", errors="replace") as handle:
    text = handle.read()

combo_pattern = re.compile(
    r'(<Widget\b[^>]*\btype="ComboBox"[^>]*>)(.*?)(</Widget>)',
    re.IGNORECASE | re.DOTALL,
)

matched = 0

def patch_combo(match):
    global matched
    matched += 1

    opening = match.group(1)
    body = match.group(2)
    closing = match.group(3)

    max_length_pattern = re.compile(
        r'<Property\b[^>]*\bkey="MaxListLength"[^>]*/>',
        re.IGNORECASE,
    )

    forced_property = (
        '\n'
        '        <Property key="MaxListLength" value="260"/>'
    )

    if max_length_pattern.search(body):
        body = max_length_pattern.sub(
            '<Property key="MaxListLength" value="260"/>',
            body,
        )
    else:
        body = forced_property + body

    return opening + body + closing

patched = combo_pattern.sub(patch_combo, text)

if matched == 0:
    raise SystemExit(
        "ERROR: No ComboBox widget was found in the save-dialog layout."
    )

temporary_path = output_path + ".tmp"

with open(
    temporary_path,
    "w",
    encoding="utf-8",
    newline="\n",
) as handle:
    handle.write(patched)

os.replace(temporary_path, output_path)

print(
    "Patched ComboBox widgets:",
    matched,
)
print(
    "Forced MaxListLength:",
    260,
)
PY_SAVE_DIALOG

    SAVE_DIALOG_RESULT=$?

    if [ "$SAVE_DIALOG_RESULT" -ne 0 ]; then
        echo "ERROR: Failed to create the save-dialog dropdown override."
        pm_gptokeyb_finish
        pm_finish
        exit 1
    fi

    echo "Created save-dialog dropdown override."
    grep -n -E \
        'type="ComboBox"|MaxListLength' \
        "$SAVE_DIALOG_OVERRIDE" || true
else
    echo "ERROR: The version-matched save-dialog layout was not found."
    echo "Expected under the OpenMW resources directory."
    pm_gptokeyb_finish
    pm_finish
    exit 1
fi

echo "=========================================="

echo "=========================================="
echo "Generated user OpenMW config:"
echo "=========================================="
cat "$CONFIG_DIR/openmw.cfg"

echo ""
echo "BSA archive check:"

for archive in Morrowind.bsa Tribunal.bsa Bloodmoon.bsa; do
    if [ -f "$TARGET_DATA_DIR/$archive" ]; then
        echo "FOUND: $TARGET_DATA_DIR/$archive"
    else
        echo "MISSING: $TARGET_DATA_DIR/$archive"
    fi
done

echo "=========================================="

# 9. Copy defaults.bin to supported config locations
if [ -f "$GAMEDIR/resources/defaults.bin" ]; then
    cp -f "$GAMEDIR/resources/defaults.bin" \
        "$CONFIG_DIR/defaults.bin"

    cp -f "$GAMEDIR/resources/defaults.bin" \
        "$CONFIG_DIR/openmw/defaults.bin"
fi

# 10. Keep one persistent settings profile mirrored at both locations used by
# this custom OpenMW 0.48 build.
#
# The custom config directory passed on the command line is:
#   $CONFIG_DIR/settings.cfg
#
# OpenMW's normal XDG user-config location is:
#   $CONFIG_DIR/openmw/settings.cfg
#
# Earlier launchers deleted one of these files at startup, which discarded
# graphics tweaks and in-game menu changes. This launcher never deletes either
# copy. It synchronizes them before launch and detects which copy OpenMW changed
# when the game exits.
SETTINGS_FILE="$CONFIG_DIR/settings.cfg"
OPENMW_SETTINGS_FILE="$CONFIG_DIR/openmw/settings.cfg"
SETTINGS_BACKUP_DIR="$CONFIG_DIR/settings-backups"

mkdir -p "$CONFIG_DIR/openmw"
mkdir -p "$SETTINGS_BACKUP_DIR"

write_restored_settings_profile() {
    OUTPUT_FILE="$1"

    mkdir -p "$(dirname "$OUTPUT_FILE")"

    cat > "$OUTPUT_FILE" <<'EOF_RESTORED_SETTINGS'
# OpenMW 0.48 TrimUI Smart Pro S
# Restored working graphics profile plus 4800-unit fog.

[Camera]
viewing distance = 4800
reverse z = false
small feature culling = false

[Fog]
use distant fog = true
distant land fog start = 1600
distant land fog end = 4600
distant underwater fog start = 0
distant underwater fog end = 2048
distant interior fog start = 0
distant interior fog end = 4096

[General]
texture mag filter = linear
texture min filter = linear
texture mipmap = nearest

[Shaders]
force per pixel lighting = false
lighting method = legacy
clamp lighting = true
antialias alpha test = false
adjust coverage for alpha test = true
auto use object normal maps = false
auto use object specular maps = false
auto use terrain normal maps = false
auto use terrain specular maps = false
apply lighting to environment maps = false

[Water]
shader = false
refraction = false
rtt size = 256
reflection detail = 0

[Shadows]
enable shadows = false
actor shadows = false
player shadows = false
terrain shadows = false
object shadows = false
indoor shadows = false

[Post Processing]
enabled = false

[Video]
antialiasing = 0
vsync = false
resolution x = 1280
resolution y = 720
fullscreen = true
window border = false

[Terrain]
distant terrain = true
object paging = true
object paging active grid = false
object paging merge factor = 250

[Groundcover]
enabled = false
density = 0.25
rendering distance = 2048
stomp mode = 0

[Input]
enable controller = true
gamepad cursor speed = 0.35
joystick dead zone = 0.05
grab cursor = false
EOF_RESTORED_SETTINGS
}

settings_checksum() {
    TARGET_FILE="$1"

    if [ -f "$TARGET_FILE" ]; then
        cksum "$TARGET_FILE" 2>/dev/null | awk '{print $1 ":" $2}'
    else
        echo "missing"
    fi
}

backup_settings_copy() {
    TARGET_FILE="$1"
    LABEL="$2"

    if [ ! -f "$TARGET_FILE" ]; then
        return
    fi

    TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
    BACKUP_PATH="$SETTINGS_BACKUP_DIR/${LABEL}-${TIMESTAMP}.cfg"
    COUNTER=1

    while [ -e "$BACKUP_PATH" ]; do
        BACKUP_PATH="$SETTINGS_BACKUP_DIR/${LABEL}-${TIMESTAMP}-${COUNTER}.cfg"
        COUNTER=$((COUNTER + 1))
    done

    cp -p "$TARGET_FILE" "$BACKUP_PATH" 2>/dev/null || \
        cp "$TARGET_FILE" "$BACKUP_PATH"

    echo "Backed up settings:"
    echo "$TARGET_FILE"
    echo "to:"
    echo "$BACKUP_PATH"
}

echo ""
echo "=========================================="
echo "Persistent settings synchronization"
echo "=========================================="
echo "Profile settings: $SETTINGS_FILE"
echo "OpenMW settings:  $OPENMW_SETTINGS_FILE"

if [ ! -f "$SETTINGS_FILE" ] &&
   [ ! -f "$OPENMW_SETTINGS_FILE" ]; then
    write_restored_settings_profile "$SETTINGS_FILE"
    cp -f "$SETTINGS_FILE" "$OPENMW_SETTINGS_FILE"
    echo "Created the restored graphics profile at both settings locations."
elif [ -f "$SETTINGS_FILE" ] &&
     [ ! -f "$OPENMW_SETTINGS_FILE" ]; then
    cp -f "$SETTINGS_FILE" "$OPENMW_SETTINGS_FILE"
    echo "Created the OpenMW settings copy from the persistent profile."
elif [ ! -f "$SETTINGS_FILE" ] &&
     [ -f "$OPENMW_SETTINGS_FILE" ]; then
    cp -f "$OPENMW_SETTINGS_FILE" "$SETTINGS_FILE"
    echo "Recovered the persistent profile from OpenMW's settings copy."
elif ! cmp -s "$SETTINGS_FILE" "$OPENMW_SETTINGS_FILE"; then
    # On a fresh install, the newly copied config/settings.cfg will normally be
    # newest and therefore wins. After a game run, whichever file OpenMW wrote
    # most recently wins. Both originals are backed up before synchronization.
    backup_settings_copy "$SETTINGS_FILE" "profile-before-startup-sync"
    backup_settings_copy "$OPENMW_SETTINGS_FILE" "openmw-before-startup-sync"

    if [ "$OPENMW_SETTINGS_FILE" -nt "$SETTINGS_FILE" ]; then
        cp -f "$OPENMW_SETTINGS_FILE" "$SETTINGS_FILE"
        echo "OpenMW's newer settings copy became authoritative."
    else
        cp -f "$SETTINGS_FILE" "$OPENMW_SETTINGS_FILE"
        echo "The persistent profile became authoritative."
    fi
else
    echo "Both settings copies already match."
fi

# Record the common state so shutdown synchronization can determine which file
# OpenMW actually changed during this run.
SETTINGS_BASELINE_CHECKSUM="$(settings_checksum "$SETTINGS_FILE")"

echo "Baseline checksum: $SETTINGS_BASELINE_CHECKSUM"
echo ""
echo "Active graphics settings:"

grep -E \
    '^\[(Camera|Fog|General|Shaders|Water|Shadows|Post Processing|Video|Terrain|Groundcover)\]|^(viewing distance|use distant fog|distant land fog start|distant land fog end|anisotropy|texture mag filter|texture min filter|texture mipmap|force shaders|force per pixel lighting|lighting method|clamp lighting|antialias alpha test|adjust coverage for alpha test|shader|refraction|reflection detail|enable shadows|enabled|antialiasing|vsync|resolution x|resolution y|fullscreen|window border|distant terrain|object paging|object paging active grid|object paging merge factor)[[:space:]]*=' \
    "$SETTINGS_FILE" || true

echo "=========================================="

CONTROLLER_PROFILE_MARKER="$CONFIG_DIR/.tsp-controller-profile-v1"

if [ ! -f "$CONTROLLER_PROFILE_MARKER" ]; then
    if [ -f "$CONFIG_DIR/input_v3.xml" ]; then
        mv -f             "$CONFIG_DIR/input_v3.xml"             "$CONFIG_DIR/input_v3.before-tsp-controller.xml"
    fi

    if [ -f "$CONFIG_DIR/openmw/input_v3.xml" ]; then
        mv -f             "$CONFIG_DIR/openmw/input_v3.xml"             "$CONFIG_DIR/openmw/input_v3.before-tsp-controller.xml"
    fi

    touch "$CONTROLLER_PROFILE_MARKER"
    echo "Reset OpenMW controller bindings for the TSP profile."
fi

echo ""
echo "=========================================="
echo "Active OpenMW graphics settings:"
echo "=========================================="
echo "$SETTINGS_FILE"
echo ""

grep -E \
    '^\[(Shaders|Water|Shadows|Post Processing|Video|Terrain)\]|^(force shaders|force per pixel lighting|shader|refraction|reflection detail|enable shadows|enabled|antialiasing|vsync|resolution x|resolution y|fullscreen|window border|distant terrain)[[:space:]]*=' \
    "$SETTINGS_FILE" || true

echo "=========================================="

# 11. Validate the executable and bundled OSG libraries
if [ ! -f "$GAMEDIR/openmw" ]; then
    echo "ERROR: OpenMW executable is missing:"
    echo "$GAMEDIR/openmw"

    pm_gptokeyb_finish
    pm_finish
    exit 1
fi

chmod +x "$GAMEDIR/openmw"

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
    LIB_PATH="$GAMEDIR/lib/$required_lib"

    if [ ! -s "$LIB_PATH" ]; then
        echo "ERROR: Missing or invalid bundled library:"
        echo "$LIB_PATH"

        pm_gptokeyb_finish
        pm_finish
        exit 1
    fi

    LIB_SIZE="$(wc -c < "$LIB_PATH")"

    if [ "$LIB_SIZE" -lt 10000 ]; then
        echo "ERROR: Bundled library is too small:"
        echo "$LIB_PATH"
        echo "Size: $LIB_SIZE bytes"

        pm_gptokeyb_finish
        pm_finish
        exit 1
    fi
done

# 12. Start gptokeyb2 controller mapper
GPTOKEYB2_BIN=""

for candidate in \
    "$GAMEDIR/gptokeyb2.aarch64" \
    "$GAMEDIR/gptokeyb2" \
    "$controlfolder/gptokeyb2" \
    "$controlfolder/gptokeyb2.aarch64" \
    "/mnt/SDCARD/data/ports/PortMaster/gptokeyb2" \
    "/mnt/SDCARD/data/ports/PortMaster/gptokeyb2.aarch64" \
    "/mnt/SDCARD/Apps/PortMaster/gptokeyb2" \
    "/mnt/SDCARD/Apps/PortMaster/gptokeyb2.aarch64" \
    "/mnt/SDCARD/System/bin/gptokeyb2" \
    "/mnt/SDCARD/System/bin/gptokeyb2.aarch64" \
    "/usr/trimui/bin/gptokeyb2" \
    "/usr/bin/gptokeyb2" \
    "/roms/ports/PortMaster/gptokeyb2"
do
    if [ -x "$candidate" ]; then
        GPTOKEYB2_BIN="$candidate"
        break
    fi
done

GPTOKEYB_PID=""

echo ""
echo "=========================================="
echo "Controller mapper setup"
echo "=========================================="
echo "Profile: $GAMEDIR/openmw.ini"
echo "Controller DB: ${CONTROLLER_DB:-not found}"
echo "SDL_GAMECONTROLLERCONFIG_FILE: ${SDL_GAMECONTROLLERCONFIG_FILE:-not supplied}"
echo "SDL controller mapping: ${SDL_GAMECONTROLLERCONFIG:-not supplied}"

if [ -f "${SDL_GAMECONTROLLERCONFIG_FILE:-}" ]; then
    echo "Controller database contents:"
    cat "$SDL_GAMECONTROLLERCONFIG_FILE"
fi

if [ ! -f "$GAMEDIR/openmw.ini" ]; then
    echo "ERROR: openmw.ini was not found."
    pm_finish
    exit 1
elif [ -z "$GPTOKEYB2_BIN" ]; then
    echo "ERROR: gptokeyb2 was not found."
    echo "The multi-profile openmw.ini cannot be used with legacy gptokeyb."
    pm_finish
    exit 1
else
    echo "gptokeyb2: $GPTOKEYB2_BIN"
    echo "PortMaster hotkey: physical Menu / SDL guide"
    echo "Exit combination: Menu + Start"

    chmod +x "$GPTOKEYB2_BIN" 2>/dev/null || true
    ${ESUDO:-} chmod 666 /dev/uinput 2>/dev/null || true

    # Stop both PortMaster mappers and any older custom TSP helper so
    # only this gptokeyb2 profile can process the controller.
    killall -9 gptokeyb2 gptokeyb 2>/dev/null || true
    pkill -9 -f "$GAMEDIR/tsp_openmw_controls" 2>/dev/null || true
    sleep 0.2

    HOTKEY=guide \
    LD_LIBRARY_PATH="$GAMEDIR:$LD_LIBRARY_PATH" \
    "$GPTOKEYB2_BIN" \
        "openmw" \
        -H guide \
        -c "$GAMEDIR/openmw.ini" &

    GPTOKEYB_PID=$!

    echo "gptokeyb2 PID: $GPTOKEYB_PID"

    sleep 0.8

    if ! kill -0 "$GPTOKEYB_PID" 2>/dev/null; then
        echo "ERROR: gptokeyb2 exited before OpenMW started."
        wait "$GPTOKEYB_PID" 2>/dev/null || true
        pm_finish
        exit 1
    fi
fi

echo "=========================================="

# gptokeyb2 has already opened the controller with the mapper database.
# Switch the environment now so OpenMW opens the same controller without
# mapping the physical Menu button to SDL Guide/Quick Save.
export SDL_GAMECONTROLLERCONFIG_FILE="$OPENMW_CONTROLLER_DB_FILE"
export SDL_GAMECONTROLLERCONFIG="$(cat "$OPENMW_CONTROLLER_DB_FILE")"
CONTROLLER_DB="$OPENMW_CONTROLLER_DB_FILE"

echo ""
echo "=========================================="
echo "OpenMW controller isolation"
echo "=========================================="
echo "Mapper DB retained Guide/Menu:"
echo "$MAPPER_CONTROLLER_DB_FILE"
echo "OpenMW DB hides Guide/Menu:"
echo "$OPENMW_CONTROLLER_DB_FILE"
echo "Menu quicksave is supplied only by the cursor profile."
echo "=========================================="

# 13. Launch OpenMW directly using the previously stable path.
# No Westonpack, custom mapper, libinterpose, or cursor preload is used.
echo ""
echo "=========================================="
echo "Final launch environment"
echo "=========================================="
echo "Executable: $GAMEDIR/openmw"
echo "Launcher mode: direct stock gptokeyb2"
echo "CFW_NAME: ${CFW_NAME:-unknown}"
echo "DEVICE_ARCH: ${DEVICE_ARCH:-unknown}"
echo "SDL_VIDEODRIVER: ${SDL_VIDEODRIVER:-unset}"
echo "LD_LIBRARY_PATH:"
echo "$LD_LIBRARY_PATH"
echo "Permanent SD user data: $SD_SAVE_DIR"
echo "Runtime OpenMW user data: $SAVE_DIR"
echo "OPENMW_DECOMPRESS_TEXTURES=$OPENMW_DECOMPRESS_TEXTURES"
echo "LIBGL_STREAM=$LIBGL_STREAM"
echo "LIBGL_TEXPATH=$LIBGL_TEXPATH"
echo "SDL_GAMECONTROLLERCONFIG_FILE=${SDL_GAMECONTROLLERCONFIG_FILE:-unset}"
echo "SDL_GAMECONTROLLERCONFIG=${SDL_GAMECONTROLLERCONFIG:-unset}"
echo "=========================================="

if type pm_platform_helper >/dev/null 2>&1; then
    echo "Running PortMaster platform helper for:"
    echo "$GAMEDIR/openmw"

    pm_platform_helper "$GAMEDIR/openmw"
else
    echo "WARNING: pm_platform_helper is unavailable."
fi

sleep 0.6

echo ""
echo "Launching ./openmw binary directly..."

./openmw \
    --user-data-dir "$SAVE_DIR" \
    --config "$CONFIG_DIR" &

OPENMW_PID=$!

# Keep the launcher active while OpenMW is running. Without this wait,
# CrossMix returns to its own menu and both interfaces receive input.
wait "$OPENMW_PID"
OPENMW_EXIT_CODE=$?

echo ""
echo "OpenMW exited with code: $OPENMW_EXIT_CODE"

# Preserve settings changed through the in-game Options menu. The custom build
# may write either settings location, so compare both copies with the baseline
# captured immediately before launch.
echo ""
echo "=========================================="
echo "Saving persistent OpenMW settings"
echo "=========================================="

PROFILE_AFTER_CHECKSUM="$(settings_checksum "$SETTINGS_FILE")"
OPENMW_AFTER_CHECKSUM="$(settings_checksum "$OPENMW_SETTINGS_FILE")"

echo "Baseline:       $SETTINGS_BASELINE_CHECKSUM"
echo "Profile after:  $PROFILE_AFTER_CHECKSUM"
echo "OpenMW after:   $OPENMW_AFTER_CHECKSUM"

if [ "$PROFILE_AFTER_CHECKSUM" = "missing" ] &&
   [ "$OPENMW_AFTER_CHECKSUM" != "missing" ]; then
    cp -f "$OPENMW_SETTINGS_FILE" "$SETTINGS_FILE"
    echo "Recovered missing profile settings from OpenMW's saved copy."
elif [ "$OPENMW_AFTER_CHECKSUM" = "missing" ] &&
     [ "$PROFILE_AFTER_CHECKSUM" != "missing" ]; then
    cp -f "$SETTINGS_FILE" "$OPENMW_SETTINGS_FILE"
    echo "Recreated OpenMW's settings copy from the persistent profile."
elif [ "$PROFILE_AFTER_CHECKSUM" != "$OPENMW_AFTER_CHECKSUM" ]; then
    PROFILE_CHANGED=0
    OPENMW_CHANGED=0

    if [ "$PROFILE_AFTER_CHECKSUM" != "$SETTINGS_BASELINE_CHECKSUM" ]; then
        PROFILE_CHANGED=1
    fi

    if [ "$OPENMW_AFTER_CHECKSUM" != "$SETTINGS_BASELINE_CHECKSUM" ]; then
        OPENMW_CHANGED=1
    fi

    backup_settings_copy "$SETTINGS_FILE" "profile-before-shutdown-sync"
    backup_settings_copy "$OPENMW_SETTINGS_FILE" "openmw-before-shutdown-sync"

    if [ "$OPENMW_CHANGED" -eq 1 ] &&
       [ "$PROFILE_CHANGED" -eq 0 ]; then
        cp -f "$OPENMW_SETTINGS_FILE" "$SETTINGS_FILE"
        echo "Saved in-game changes from OpenMW's settings copy."
    elif [ "$PROFILE_CHANGED" -eq 1 ] &&
         [ "$OPENMW_CHANGED" -eq 0 ]; then
        cp -f "$SETTINGS_FILE" "$OPENMW_SETTINGS_FILE"
        echo "Saved changes from the persistent profile."
    elif [ "$OPENMW_SETTINGS_FILE" -nt "$SETTINGS_FILE" ]; then
        cp -f "$OPENMW_SETTINGS_FILE" "$SETTINGS_FILE"
        echo "Both changed; kept the newer OpenMW settings copy."
    else
        cp -f "$SETTINGS_FILE" "$OPENMW_SETTINGS_FILE"
        echo "Both changed; kept the newer persistent profile."
    fi
else
    echo "No settings synchronization was needed."
fi

sync
echo "=========================================="

echo ""
echo "=========================================="
echo "Saving runtime saves back to SD"
echo "=========================================="

mkdir -p "$SD_SAVE_DIR/saves"
mkdir -p "$SD_SAVE_DIR/screenshots"

if [ -d "$SAVE_DIR/saves" ]; then
    cp -R "$SAVE_DIR/saves/." "$SD_SAVE_DIR/saves/" 2>/dev/null || {
        echo "ERROR: One or more save files could not be copied back to SD."
    }
fi

if [ -d "$SAVE_DIR/screenshots" ]; then
    cp -R "$SAVE_DIR/screenshots/." "$SD_SAVE_DIR/screenshots/" 2>/dev/null || true
fi

sync

echo "Permanent save count after sync:"
find "$SD_SAVE_DIR/saves" -type f -iname '*.omwsave' 2>/dev/null | wc -l
echo "=========================================="

if [ -n "$GPTOKEYB_PID" ]; then
    kill "$GPTOKEYB_PID" 2>/dev/null || true
    wait "$GPTOKEYB_PID" 2>/dev/null || true
fi

pm_gptokeyb_finish
pm_finish

exit "$OPENMW_EXIT_CODE"
