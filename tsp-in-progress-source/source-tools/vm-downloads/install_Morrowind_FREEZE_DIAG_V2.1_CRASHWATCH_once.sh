#!/usr/bin/env bash
set -euo pipefail

HOST="${TSP_HOST:-root@192.168.1.21}"
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/Morrowind-WATCHDOG-FREEZE-DIAG-V2.1-CRASHWATCH.sh"

SHA_BASE="8b6a3129bf37e5c39b0bee8572214ec72f32b8f750f7dd5b3910acd266ef1d38"
SHA_V2="838ade43608b4901c1a858328cf37976d49c3cbd9bccdf35401fdf0b6970e994"
SHA_NEW="adba24246b9524547b3142d9ab4deb797cedb96f176cc640357007e97db5f36f"

SOCK="${TMPDIR:-/tmp}/tsp-v21-crashwatch-$$.sock"

[ -f "$SRC" ] || { echo "ERROR: missing $SRC"; exit 1; }

cleanup() {
    ssh -S "$SOCK" -O exit "$HOST" >/dev/null 2>&1 || true
    rm -f "$SOCK" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "===== 1/5 AUTHENTICATE ONCE ====="
echo "One password prompt only. Everything else reuses this SSH connection."
ssh -M -S "$SOCK" -o ControlPersist=10m "$HOST" true

echo
echo "===== 2/4 UPLOAD ====="
scp -o ControlPath="$SOCK" "$SRC" "$HOST:/tmp/Morrowind-WATCHDOG-FREEZE-DIAG-V2.1-CRASHWATCH.sh"

echo
echo "===== 3/4 BACK UP + INSTALL ====="
ssh -S "$SOCK" "$HOST" sh -s -- "$SHA_BASE" "$SHA_V2" "$SHA_NEW" <<'REMOTE'
set -eu
SHA_BASE="$1"
SHA_V2="$2"
SHA_NEW="$3"

PLAY=""
for p in \
    /roms/ports/Morrowind.sh \
    /mnt/mmc/ROMS/Ports/Morrowind.sh \
    /mnt/mmc/Roms/PORTS/Morrowind.sh \
    /mnt/SDCARD/Roms/PORTS/Morrowind.sh \
    /userdata/roms/ports/Morrowind.sh \
    /storage/roms/ports/Morrowind.sh
do
    [ -f "$p" ] && { PLAY="$p"; break; }
done
[ -n "$PLAY" ] || { echo "ERROR: Morrowind.sh not found"; exit 30; }

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
    [ -x "$r/bin/openmw-0.51" ] && { ROOT="$r"; break; }
done
[ -n "$ROOT" ] || { echo "ERROR: OpenMW root not found"; exit 31; }

CUR="$(sha256sum "$PLAY" | awk '{print $1}')"

case "$CUR" in
    "$SHA_NEW")
        echo "Already installed."
        ;;
    "$SHA_BASE"|"$SHA_V2")
        mkdir -p "$ROOT/launcher-backups"
        STAMP="$(date +%Y%m%d-%H%M%S)"
        BACKUP="$ROOT/launcher-backups/Morrowind.sh.before-v21-crashwatch-$STAMP"
        cp -p "$PLAY" "$BACKUP"
        [ "$(sha256sum "$BACKUP" | awk '{print $1}')" = "$CUR" ] || {
            echo "ERROR: backup verification failed"
            exit 32
        }
        cat /tmp/Morrowind-WATCHDOG-FREEZE-DIAG-V2.1-CRASHWATCH.sh > "$PLAY"
        chmod +x "$PLAY"
        echo "Backup: $BACKUP"
        ;;
    *)
        echo "ERROR: unexpected launcher; refusing to overwrite it."
        echo "current_sha=$CUR"
        exit 33
        ;;
esac

rm -f /tmp/Morrowind-WATCHDOG-FREEZE-DIAG-V2.1-CRASHWATCH.sh

NEW="$(sha256sum "$PLAY" | awk '{print $1}')"
[ "$NEW" = "$SHA_NEW" ] || { echo "ERROR: final SHA mismatch"; exit 34; }

grep -q 'TSP_CRASHWATCH_REARM_V1' "$PLAY"
grep -q 'export TSP_CRASH_OUT' "$PLAY"
if grep -q '^unset TSP_CRASH_OUT$' "$PLAY"; then
    echo "ERROR: launcher still disables crashwatch"
    exit 35
fi

echo "PLAY=$PLAY"
echo "ROOT=$ROOT"
echo "sha256=$NEW"
REMOTE

echo
echo "===== 4/4 VERIFY ====="
ssh -S "$SOCK" "$HOST" 'sh -s' <<'REMOTE'
set -eu
PLAY=""
for p in \
    /roms/ports/Morrowind.sh \
    /mnt/mmc/ROMS/Ports/Morrowind.sh \
    /mnt/mmc/Roms/PORTS/Morrowind.sh \
    /mnt/SDCARD/Roms/PORTS/Morrowind.sh \
    /userdata/roms/ports/Morrowind.sh \
    /storage/roms/ports/Morrowind.sh
do
    [ -f "$p" ] && { PLAY="$p"; break; }
done
grep -q 'TSP_CRASH_OUT="$GAMEDIR/tsp_crashwatch_latest.txt"' "$PLAY"
grep -q 'TSP_CRASHWATCH_REARM_V1' "$PLAY"
echo "PASS: TSP_CRASH_OUT crashwatch is armed"
echo "Output: <OpenMW root>/tsp_crashwatch_latest.txt"
REMOTE

echo
echo "DONE."
