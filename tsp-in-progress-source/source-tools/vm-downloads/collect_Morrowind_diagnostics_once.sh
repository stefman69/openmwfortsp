#!/usr/bin/env bash
set -euo pipefail
HOST="${TSP_HOST:-root@192.168.1.21}"
OUT="${1:-$HOME/Downloads/tsp_morrowind_diagnostics_$(date +%Y%m%d-%H%M%S).tar}"
echo 'One password prompt only. The archive is streamed directly over this single SSH connection.'
ssh "$HOST" 'sh -s' <<'EOF_REMOTE' > "$OUT"
set -e
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
[ -n "$ROOT" ] || { echo 'ERROR: OpenMW root not found' >&2; exit 21; }
cd "$ROOT"
set --
[ -d tsp_diag/latest ] && set -- "$@" tsp_diag/latest
[ -d tsp_ring ] && set -- "$@" tsp_ring
[ -f openmw_log.txt ] && set -- "$@" openmw_log.txt
[ -f openmw_051_log.txt ] && set -- "$@" openmw_051_log.txt
[ -f config/openmw.log ] && set -- "$@" config/openmw.log
[ -f openmw_perf_latest.txt ] && set -- "$@" openmw_perf_latest.txt
[ -f openmw_perf_previous.txt ] && set -- "$@" openmw_perf_previous.txt
[ "$#" -gt 0 ] || { echo 'ERROR: no diagnostic files found' >&2; exit 44; }
exec tar -cf - "$@"
EOF_REMOTE

tar -tf "$OUT" >/dev/null
echo "PASS: $OUT"
