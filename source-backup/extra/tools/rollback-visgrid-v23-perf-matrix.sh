#!/usr/bin/env bash
set -Eeuo pipefail
DEV="${TSP_DEV:-root@192.168.1.25}"
ROOT='/mnt/SDCARD/data/ports/openmw51'
MOD='/mnt/SDCARD/data/ports/openmw51/mods/TSPInteriorVisGrid'
LUA='/mnt/SDCARD/data/ports/openmw51/mods/TSPInteriorVisGrid/scripts/TSPInteriorVisGrid/visgrid.lua'
LAUNCHER='/mnt/sdcard/mmcblk1p1/Roms/PORTS/Morrowind_51.sh'
BACKUP='/mnt/SDCARD/data/ports/openmw51/mods/TSPInteriorVisGrid/v23-backups/20260829-103656'
ssh -o BatchMode=yes -o ConnectTimeout=8 "$DEV" "
  set -e
  test -s '$BACKUP/visgrid.lua.before'
  test -s '$BACKUP/launcher.before'
  cp -p '$BACKUP/visgrid.lua.before' '$LUA.rollback-new'
  mv -f '$LUA.rollback-new' '$LUA'
  cp -p '$BACKUP/launcher.before' '$LAUNCHER.rollback-new'
  chmod +x '$LAUNCHER.rollback-new'
  mv -f '$LAUNCHER.rollback-new' '$LAUNCHER'
  sync
  echo 'Restored:'
  sha256sum '$LUA' '$LAUNCHER'
"
echo 'V23 live sensor + launcher rolled back. Staged v23_profiles are harmless and were left in place.'
