#!/bin/bash
set -eu

GAMEDIR="${OPENMW51_GAMEDIR:-/mnt/SDCARD/data/ports/openmw51}"
TOOL="$GAMEDIR/bin/openmw-navmeshtool"
MAIN_CFG="$GAMEDIR/openmw.cfg"
BIN_CFG="$GAMEDIR/bin/openmw.cfg"
CONFIG_DIR="$GAMEDIR/config-0.51"
USER_DATA="$GAMEDIR/savegame-0.51"

THREADS="${NAVMESH_THREADS:-1}"
INTERIORS="${NAVMESH_INTERIORS:-false}"
REMOVE_UNUSED="${NAVMESH_REMOVE_UNUSED:-true}"

if [ ! -x "$TOOL" ]; then
    echo "ERROR: openmw-navmeshtool is missing or not executable:"
    echo "  $TOOL"
    exit 1
fi

if [ ! -f "$MAIN_CFG" ]; then
    echo "ERROR: persistent OpenMW config is missing:"
    echo "  $MAIN_CFG"
    exit 1
fi

if [ ! -f "$CONFIG_DIR/openmw.cfg" ]; then
    echo "ERROR: user content config is missing:"
    echo "  $CONFIG_DIR/openmw.cfg"
    exit 1
fi

case "$THREADS" in
    ''|*[!0-9]*|0)
        echo "ERROR: NAVMESH_THREADS must be an integer >= 1."
        exit 1
        ;;
esac

mkdir -p "$GAMEDIR/bin" "$USER_DATA"
cp -f "$MAIN_CFG" "$BIN_CFG"

export LD_LIBRARY_PATH="$GAMEDIR/lib:$GAMEDIR/libs:$GAMEDIR/lib/aarch64:/mnt/SDCARD/System/lib:/usr/trimui/lib:${LD_LIBRARY_PATH:-}"
export OSG_LIBRARY_PATH="$GAMEDIR/osgPlugins-3.6.5"

echo "============================================================"
echo "OpenMW 0.51 optional navmesh pre-generator"
echo "============================================================"
echo "Game directory: $GAMEDIR"
echo "Database:       $USER_DATA/navmesh.db"
echo "Workers:        $THREADS"
echo "Interiors:      $INTERIORS"
echo "Remove stale:   $REMOVE_UNUSED"
echo
echo "This tool is NOT run automatically by the port."
echo "It uses the currently active OpenMW data/content/mod profile."
echo "============================================================"

exec "$TOOL" \
    --resources "$GAMEDIR/resources" \
    --config "$CONFIG_DIR" \
    --user-data "$USER_DATA" \
    --threads "$THREADS" \
    --process-interior-cells "$INTERIORS" \
    --remove-unused-tiles "$REMOVE_UNUSED" \
    "$@"
