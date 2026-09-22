#!/usr/bin/env bash
set -euo pipefail

# Host-side installer for Morrowind-TSP-GPU-DIAG-V1.sh.
# Default current TSP address from the recent install logs; override if needed:
#   TSP_HOST=root@192.168.1.99 ./install_TSP_GPU_DIAG_V1.sh
TSP_HOST="${TSP_HOST:-root@192.168.1.21}"
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="${1:-$HERE/Morrowind-TSP-GPU-DIAG-V1.sh}"

if [ ! -f "$SRC" ]; then
    echo "ERROR: diagnostic launcher not found: $SRC" >&2
    exit 2
fi

echo "Installing: $SRC"
echo "Device:     $TSP_HOST"

scp "$SRC" "$TSP_HOST:/tmp/Morrowind-TSP-GPU-DIAG-V1.sh"

ssh "$TSP_HOST" 'sh -s' <<'REMOTE'
set -eu

PLAY=""
for p in \
    /mnt/SDCARD/Roms/PORTS/Morrowind.sh \
    /mnt/sdcard/mmcblk1p1/Roms/PORTS/Morrowind.sh \
    /userdata/roms/ports/Morrowind.sh \
    /roms/ports/Morrowind.sh \
    /storage/roms/ports/Morrowind.sh \
    /mnt/mmc/ROMS/Ports/Morrowind.sh
do
    if [ -f "$p" ]; then PLAY="$p"; break; fi
done

if [ -z "$PLAY" ]; then
    echo "ERROR: could not find active Morrowind.sh" >&2
    exit 10
fi

ROOT=""
for r in \
    /mnt/SDCARD/data/ports/openmw \
    /mnt/sdcard/mmcblk1p1/data/ports/openmw \
    /userdata/roms/ports/openmw \
    /mnt/mmc/ports/openmw \
    /mnt/sdcard/ports/openmw \
    /roms/ports/openmw \
    /storage/roms/ports/openmw
do
    if [ -x "$r/bin/openmw-0.51" ]; then ROOT="$r"; break; fi
done

if [ -z "$ROOT" ]; then
    echo "ERROR: could not find OpenMW runtime root" >&2
    exit 11
fi

STAMP="$(date +%Y%m%d-%H%M%S 2>/dev/null || echo now)"
BACKUP="$PLAY.before-tsp-gpu-diag-v1-$STAMP"
cp -p "$PLAY" "$BACKUP"
install -m 755 /tmp/Morrowind-TSP-GPU-DIAG-V1.sh "$PLAY"
printf 'core\n' > "$ROOT/tsp_gpu_diag_mode.txt"

# Verification: syntax where supported, marker count, and exact installed paths.
if command -v sh >/dev/null 2>&1; then sh -n "$PLAY"; fi
COUNT="$(grep -c 'TSP_GPU_DIAG_BUNDLE_V1' "$PLAY" 2>/dev/null || true)"
[ "${COUNT:-0}" -gt 0 ] || { echo "ERROR: diagnostic marker missing after install" >&2; exit 12; }

echo "PASS: diagnostic launcher installed"
echo "PLAY=$PLAY"
echo "ROOT=$ROOT"
echo "BACKUP=$BACKUP"
echo "MODE=$(cat "$ROOT/tsp_gpu_diag_mode.txt")"
echo "MARKER_COUNT=$COUNT"
echo "Run Morrowind normally and reproduce the exterior-cell freeze."
echo "Diagnostics will be written to: $ROOT/tsp_diag/latest"
REMOTE
