#!/usr/bin/env bash
set -Eeuo pipefail
cd "$HOME/Downloads"
ROOT="/mnt/SDCARD/data/ports/openmw51"
LUA="$ROOT/mods/TSPInteriorVisGrid/scripts/TSPInteriorVisGrid/visgrid.lua"
BASE="$HOME/Downloads/visgrid-tools/visgrid-v22.1-exact.lua"
EXPECTED="6dabab5641894968b51c2a8399ac206926662d4182d8445bb710ef7a0e2a7c45"
if [ -f "$HOME/Downloads/visgrid-tools/device.env" ]; then
    . "$HOME/Downloads/visgrid-tools/device.env" || true
fi
if [ -n "${TSP_DEV:-}" ]; then DEV="$TSP_DEV"
elif [ -n "${TSP_IP:-}" ]; then DEV="root@$TSP_IP"
else DEV="root@192.168.1.25"; fi
SSH=(-o BatchMode=yes -o ConnectTimeout=8)
[ -s "$BASE" ]
[ "$(sha256sum "$BASE" | awk '{print $1}')" = "$EXPECTED" ]
STAMP="$(date +%Y%m%d-%H%M%S)"
scp -q "${SSH[@]}" "$BASE" "$DEV:$ROOT/visgrid-v22.1-restore.lua"
ssh "${SSH[@]}" "$DEV" "
set -e
mkdir -p '$ROOT/mods/TSPInteriorVisGrid/visgrid-backups'
cp -p '$LUA' '$ROOT/mods/TSPInteriorVisGrid/visgrid-backups/visgrid-before-clean-v22.1-restore-$STAMP.lua'
mv '$ROOT/visgrid-v22.1-restore.lua' '$LUA'
sync
sha256sum '$LUA'
"
ACTUAL="$(ssh "${SSH[@]}" "$DEV" "sha256sum '$LUA'" | awk '{print $1}')"
[ "$ACTUAL" = "$EXPECTED" ]
echo "PASS: exact clean V22.1 restored. Restart OpenMW."
