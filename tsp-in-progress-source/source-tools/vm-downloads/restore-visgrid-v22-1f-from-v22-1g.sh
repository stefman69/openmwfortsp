#!/usr/bin/env bash
set -Eeuo pipefail
DEV="${TSP_DEV:-root@192.168.1.25}"
LIVE_LUA="/mnt/SDCARD/data/ports/openmw51/mods/TSPInteriorVisGrid/scripts/TSPInteriorVisGrid/visgrid.lua"
BACKUP="/mnt/SDCARD/data/ports/openmw51/mods/TSPInteriorVisGrid/scripts/TSPInteriorVisGrid/visgrid.lua.v22-1f-before-v22-1g-20260829-094352"
EXPECTED="8b2db68de598febff9559cb248e509a99d8c3abdda29c54b42447f6970b0f7fc"
ssh -o BatchMode=yes -o ConnectTimeout=8 "$DEV" "
    set -e
    test -s '$BACKUP'
    cp -p '$BACKUP' '$LIVE_LUA'
    sync
    test \"$(sha256sum '$LIVE_LUA' | awk '{print $1}')\" = '$EXPECTED'
"
echo "PASS: exact V22.1F restored."
