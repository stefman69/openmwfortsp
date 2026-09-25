#!/usr/bin/env bash
set -Eeuo pipefail

trap 'rc=$?; echo; echo "ERROR: V72 recovery stopped at line $LINENO (status $rc)." >&2; echo "Your terminal remains open." >&2' ERR

CONTAINER="openmw_builder"
DEVICE_IP="192.168.1.12"
OUT="/home/bob-simpson/Downloads"
BIN="$OUT/openmw-0.51-v72"
LAYOUTS="$OUT/openmw-v72-layouts"
EXPECTED="9aeac6de3ebc1ce8b0fa13646ed672a11f12b6e4e95d900f768f129f57772bff"

echo "===== V72 RECOVERY ====="

DOCKER=(docker)
if ! docker info >/dev/null 2>&1; then
    echo "Docker needs elevated access; requesting it once."
    sudo -v
    DOCKER=(sudo docker)
fi

echo
echo "===== CHECKING DOCKER PAYLOAD ====="
"${DOCKER[@]}" inspect "$CONTAINER" >/dev/null 2>&1 || {
    echo "ERROR: Docker container '$CONTAINER' was not found." >&2
    exit 2
}

"${DOCKER[@]}" exec "$CONTAINER" test -s /root/tsp-v72-payload/openmw-0.51-v72 || {
    echo "ERROR: V72 binary is missing inside Docker." >&2
    exit 3
}

echo "Docker V72 binary found."

echo
echo "===== COPYING V72 TO VM DOWNLOADS ====="

rm -f "$BIN"
rm -rf "$LAYOUTS"
mkdir -p "$LAYOUTS"

"${DOCKER[@]}" cp \
    "$CONTAINER:/root/tsp-v72-payload/openmw-0.51-v72" \
    "$BIN"

for name in \
    openmw_chargen_class.layout \
    openmw_chargen_create_class.layout \
    openmw_chargen_race.layout \
    openmw_chargen_review.layout
do
    "${DOCKER[@]}" cp \
        "$CONTAINER:/root/tsp-v72-payload/layouts/$name" \
        "$LAYOUTS/$name"
done

chmod 755 "$BIN"

ACTUAL="$(sha256sum "$BIN" | awk '{print $1}')"

echo
echo "Binary:"
ls -lh "$BIN"
echo
echo "SHA256:"
echo "$ACTUAL"

if [ "$ACTUAL" != "$EXPECTED" ]; then
    echo "ERROR: V72 hash mismatch." >&2
    echo "Expected: $EXPECTED" >&2
    echo "Actual:   $ACTUAL" >&2
    exit 4
fi

echo "VM copy verified: PASS"

echo
echo "Layouts:"
ls -lh "$LAYOUTS"/*.layout

echo
echo "===== UPLOADING TO TSP ====="
echo "Device: $DEVICE_IP"
echo
echo "Your existing V71 backup in Downloads is NOT touched."

set +e

tar -C "$OUT" -cf - \
    openmw-0.51-v72 \
    openmw-v72-layouts \
| ssh "root@$DEVICE_IP" '
set -eu

EXPECTED="9aeac6de3ebc1ce8b0fa13646ed672a11f12b6e4e95d900f768f129f57772bff"

STAGE="/tmp/openmw-v72-recovery"
rm -rf "$STAGE"
mkdir -p "$STAGE"

tar -C "$STAGE" -xf -

ROOT=""
for candidate in \
    /mnt/SDCARD/Data/ports/openmw \
    /mnt/SDCARD/data/ports/openmw \
    /mnt/mmc/ports/openmw \
    /userdata/roms/ports/openmw
do
    if [ -d "$candidate/bin" ] && [ -d "$candidate/resources" ]; then
        ROOT="$candidate"
        break
    fi
done

if [ -z "$ROOT" ]; then
    echo "ERROR: OpenMW installation root was not found." >&2
    exit 20
fi

echo
echo "OpenMW root: $ROOT"

BIN="$ROOT/bin/openmw-0.51"

if [ -d "$BIN" ]; then
    echo "ERROR: $BIN is unexpectedly a directory." >&2
    exit 21
fi

if [ ! -s "$STAGE/openmw-0.51-v72" ]; then
    echo "ERROR: Uploaded V72 binary is missing." >&2
    exit 22
fi

HASH="$(sha256sum "$STAGE/openmw-0.51-v72" | awk "{print \$1}")"

if [ "$HASH" != "$EXPECTED" ]; then
    echo "ERROR: Uploaded binary hash mismatch." >&2
    echo "Expected: $EXPECTED" >&2
    echo "Actual:   $HASH" >&2
    exit 23
fi

STAMP="$(date +%Y%m%d-%H%M%S)"
BACK="$ROOT/v72-recovery-backup-$STAMP"

mkdir -p "$BACK/layouts"

echo
echo "===== BACKING UP CURRENT TSP FILES ====="
echo "Backup: $BACK"

if [ -e "$BIN" ] || [ -L "$BIN" ]; then
    cp -a "$BIN" "$BACK/openmw-0.51.before-v72"
    echo "Backed up current binary."
else
    echo "No current openmw-0.51 binary exists; continuing."
fi

for name in \
    openmw_chargen_class.layout \
    openmw_chargen_create_class.layout \
    openmw_chargen_race.layout \
    openmw_chargen_review.layout
do
    i=0

    find "$ROOT/resources" -type f -name "$name" -print 2>/dev/null |
    while IFS= read -r dst; do
        i=$((i + 1))
        cp -a "$dst" "$BACK/layouts/$name.$i"
        echo "Backed up: $dst"
    done
done

echo
echo "===== INSTALLING V72 BINARY ====="

# Write the new executable under a DIFFERENT filename first.
# Then rename it over the old executable. This avoids writing directly
# into a potentially running/busy OpenMW executable.
NEWTMP="$ROOT/bin/.openmw-0.51-v72-new-$$"

rm -f "$NEWTMP"
cp "$STAGE/openmw-0.51-v72" "$NEWTMP"
chmod 755 "$NEWTMP"

NEWHASH="$(sha256sum "$NEWTMP" | awk "{print \$1}")"

if [ "$NEWHASH" != "$EXPECTED" ]; then
    echo "ERROR: Binary changed while copying to the SD card." >&2
    rm -f "$NEWTMP"
    exit 24
fi

mv -f "$NEWTMP" "$BIN"

echo "V72 binary installed."

echo
echo "===== INSTALLING V72 LAYOUTS ====="

for name in \
    openmw_chargen_class.layout \
    openmw_chargen_create_class.layout \
    openmw_chargen_race.layout \
    openmw_chargen_review.layout
do
    SRC="$STAGE/openmw-v72-layouts/$name"

    if [ ! -s "$SRC" ]; then
        echo "ERROR: Staged layout missing: $name" >&2
        exit 25
    fi

    FOUND=0

    find "$ROOT/resources" -type f -name "$name" -print 2>/dev/null |
    while IFS= read -r dst; do
        tmp="${dst}.v72-new-$$"

        cp "$SRC" "$tmp"
        chmod 644 "$tmp"
        mv -f "$tmp" "$dst"

        echo "UPDATED: $dst"
    done

    if ! find "$ROOT/resources" -type f -name "$name" -print -quit 2>/dev/null | grep -q .; then
        echo "ERROR: Runtime layout was not found: $name" >&2
        exit 26
    fi
done

sync

echo
echo "===== FINAL V72 CHECK ====="

FINALHASH="$(sha256sum "$BIN" | awk "{print \$1}")"

echo "$FINALHASH  $BIN"

if [ "$FINALHASH" != "$EXPECTED" ]; then
    echo "ERROR: Final installed binary hash is wrong." >&2
    exit 27
fi

ls -lh "$BIN"

echo
echo "V72 RECOVERY INSTALL: PASS"
echo "Backup: $BACK"

rm -rf "$STAGE"
'

SSH_RC=${PIPESTATUS[1]}
set -e

echo

if [ "$SSH_RC" -ne 0 ]; then
    echo "ERROR: TSP upload/install failed with status $SSH_RC." >&2
    echo "The verified V72 binary is still safely stored at:"
    echo "  $BIN"
    exit "$SSH_RC"
fi

echo "=========================================="
echo " V72 RECOVERY COMPLETE"
echo "=========================================="
echo
echo "VM binary:"
echo "  $BIN"
echo
echo "VM layouts:"
echo "  $LAYOUTS"
echo
echo "TSP:"
echo "  $DEVICE_IP"
echo
echo "The V71 backup already in your Downloads was untouched."
