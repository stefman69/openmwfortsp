#!/usr/bin/env bash
set -Eeuo pipefail
DEV="${TSP_DEV:-root@192.168.1.25}"
LIVE="/mnt/SDCARD/data/ports/openmw51/mods/TSPInteriorVisGrid/scripts/TSPInteriorVisGrid/visgrid.lua"
BACKUP="/mnt/SDCARD/data/ports/openmw51/mods/TSPInteriorVisGrid/visgrid-backups/v22-1e-20260829-012527/visgrid-v22.1d.lua"
EXPECTED="65d068f66936e4ee48a0747c403ead58151d61c6b0c320d745c2fac5e00dc866"
BACKUP_SHA="$(ssh "$DEV" "sha256sum '$BACKUP'" | awk '{print $1}')"
[ "$BACKUP_SHA" = "$EXPECTED" ]
ssh "$DEV" "set -e; cp -p '$BACKUP' '$LIVE'; sync"
LIVE_SHA="$(ssh "$DEV" "sha256sum '$LIVE'" | awk '{print $1}')"
echo "$LIVE_SHA  $LIVE"
[ "$LIVE_SHA" = "$EXPECTED" ]
echo "PASS: exact V22.1D restored. Restart OpenMW."
