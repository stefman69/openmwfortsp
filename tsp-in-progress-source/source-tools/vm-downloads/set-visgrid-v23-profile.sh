#!/usr/bin/env bash
set -Eeuo pipefail
DEV="${TSP_DEV:-root@192.168.1.25}"
LAUNCHER='/mnt/sdcard/mmcblk1p1/Roms/PORTS/Morrowind_51.sh'
mode="${1:-}"
case "$mode" in
  baseline) b=1; t=0; p=0 ;;
  current0) b=0; t=0; p=0 ;;
  current1) b=0; t=0; p=1 ;;
  macro0)   b=0; t=1; p=0 ;;
  macro1)   b=0; t=1; p=1 ;;
  *) echo "Usage: $0 baseline|current0|current1|macro0|macro1"; exit 2 ;;
esac
ssh -o BatchMode=yes -o ConnectTimeout=8 "$DEV" "
  set -e
  test -s '$LAUNCHER'
  grep -Fq '# >>> TSP_VISGRID_V23_PROFILE BEGIN' '$LAUNCHER'
  sed -i 's/^VISGRID_BASELINE=[01].*/VISGRID_BASELINE=$b/' '$LAUNCHER'
  sed -i 's/^VISGRID_TOPOLOGY=[01].*/VISGRID_TOPOLOGY=$t/' '$LAUNCHER'
  sed -i 's/^VISGRID_PERFORMANCE=[01].*/VISGRID_PERFORMANCE=$p/' '$LAUNCHER'
  bash -n '$LAUNCHER'
  grep -E '^VISGRID_(BASELINE|TOPOLOGY|PERFORMANCE)=' '$LAUNCHER'
"
echo "Selected $mode. It takes effect the next time Morrowind_51 is launched."
