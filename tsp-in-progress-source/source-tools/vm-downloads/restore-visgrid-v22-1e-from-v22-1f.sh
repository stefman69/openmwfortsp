#!/usr/bin/env bash
set -Eeuo pipefail
DEV="${TSP_DEV:-root@192.168.1.25}"
LIVE_LUA="/mnt/SDCARD/data/ports/openmw51/mods/TSPInteriorVisGrid/scripts/TSPInteriorVisGrid/visgrid.lua"
BACKUP="/mnt/SDCARD/data/ports/openmw51/mods/TSPInteriorVisGrid/scripts/TSPInteriorVisGrid/visgrid.lua.v22-1e-before-v22-1f-20260829-015842"
EXPECTED="bf5097ae5a5a668eb38802b8b9b67dc9ec3620e73d9b0a3fe0c2c5c19a524df4"
ssh -o BatchMode=yes -o ConnectTimeout=8 "$DEV" "
    set -e
    test -s '$BACKUP'
    cp -p '$BACKUP' '$LIVE_LUA'
    sync
    test \"$(sha256sum '$LIVE_LUA' | awk '{print $1}')\" = '$EXPECTED'
"
echo "PASS: exact V22.1E restored."
