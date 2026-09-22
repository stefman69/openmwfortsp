#!/usr/bin/env bash
set -o pipefail

LOG="$HOME/Downloads/TSP_input_investigation.txt"
REMOTE_CMD="$*"

if [ -z "$REMOTE_CMD" ]; then
  echo "Usage: $0 'remote command'"
  exit 2
fi

{
  printf '\n\n============================================================\n'
  printf 'CHECK %s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')"
  printf '$ ssh root@192.168.1.21 %q\n' "$REMOTE_CMD"
  printf '%s\n' '============================================================'
  ssh root@192.168.1.21 "$REMOTE_CMD"
  rc=$?
  printf '\n[SSH exit status: %d]\n' "$rc"
  exit "$rc"
} 2>&1 | tee -a "$LOG"

exit ${PIPESTATUS[0]}
