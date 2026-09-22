#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="/mnt/SDCARD/data/ports/openmw51"
if [ -f "$HOME/Downloads/visgrid-tools/device.env" ]; then
  . "$HOME/Downloads/visgrid-tools/device.env" || true
fi
if [ -n "${TSP_DEV:-}" ]; then DEV="$TSP_DEV"
elif [ -n "${TSP_IP:-}" ]; then DEV="root@$TSP_IP"
else DEV="root@192.168.1.25"; fi
SSH=(-o BatchMode=yes -o ConnectTimeout=8)
if ssh "${SSH[@]}" "$DEV" \
  'pidof openmw-0.51 >/dev/null 2>&1 || pidof openmw >/dev/null 2>&1'
then
  echo "ERROR: exit OpenMW normally before rollback."
  exit 20
fi
BACKUP="$(ssh "${SSH[@]}" "$DEV" \
  "ls -1dt '$ROOT'/backups/visgrid-v19-ray-authority-* 2>/dev/null | head -1")"
test -n "$BACKUP"
ssh "${SSH[@]}" "$DEV" "
  set -e
  test -s '$BACKUP/visgrid.lua.before-v19'
  cp -p '$BACKUP/visgrid.lua.before-v19' \
    '$ROOT/mods/TSPInteriorVisGrid/scripts/TSPInteriorVisGrid/visgrid.lua'
  sync
  sha256sum \
    '$ROOT/bin/openmw-0.51' \
    '$ROOT/mods/TSPInteriorVisGrid/scripts/TSPInteriorVisGrid/visgrid.lua'
"
echo "PASS: exact pre-V19 sensor restored."
echo "V17 PVS binary was never changed."

