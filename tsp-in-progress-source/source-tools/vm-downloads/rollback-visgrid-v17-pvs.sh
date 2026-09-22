#!/usr/bin/env bash
set -Eeuo pipefail

ENV="$HOME/Downloads/v17-last-backup.env"
test -s "$ENV"
# shellcheck disable=SC1090
. "$ENV"

SSH=(-o BatchMode=yes -o ConnectTimeout=8)

if ssh "${SSH[@]}" "$DEV" \
    'pidof openmw-0.51 >/dev/null 2>&1 || pidof openmw >/dev/null 2>&1'
then
    echo "ERROR: exit OpenMW normally before rollback."
    exit 20
fi

ssh "${SSH[@]}" "$DEV" "
  set -e
  test -s '$REMOTE_BACKUP/openmw-0.51.before-v17'
  test -s '$REMOTE_BACKUP/visgrid.lua.before-v17'
  cp -p '$REMOTE_BACKUP/openmw-0.51.before-v17' '$BIN'
  cp -p '$REMOTE_BACKUP/visgrid.lua.before-v17' '$LUA'
  chmod +x '$BIN'
  sync
  sha256sum '$BIN' '$LUA'
"

echo "PASS: exact pre-V17 binary + sensor restored."

