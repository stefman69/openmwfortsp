#!/usr/bin/env bash
set -Eeuo pipefail

CONTAINER="${CONTAINER:-openmw_builder}"
SRC="${SRC:-/root/openmw-0.51-tsp-src}"
BUILD="${BUILD:-/root/openmw-0.51-tsp-build}"
DEVICE="${DEVICE:-root@192.168.1.12}"
OUTDIR="${OUTDIR:-/home/bob-simpson/Downloads}"

CMAKE_FILE="$SRC/apps/openmw/CMakeLists.txt"
LOCALMAP="$SRC/apps/openmw/mwrender/localmap.cpp"
OUTBIN="$OUTDIR/openmw-0.51-tsp-mapmem-safe-v2"

fail() {
    echo
    echo "============================================================"
    echo "TSP_MAPMEM_SIGILL_SAFE_V2 FAILED"
    echo "============================================================"
    echo "$*" >&2
    echo "No silent failure occurred."
    echo "============================================================"
    exit 1
}

trap 'rc=$?; echo; echo "ERROR: stopped at host line $LINENO (status $rc)." >&2' ERR

mkdir -p "$OUTDIR"

echo "============================================================"
echo "TSP_MAPMEM_SIGILL_SAFE_V2"
echo "============================================================"
echo "Keeps TSP_MAPMEM_V1 and rebuilds the OpenMW app for baseline ARMv8-A."
echo

DOCKER=(docker)
if ! docker info >/dev/null 2>&1; then
    echo "Docker needs elevated access; requesting it once."
    sudo -v
    DOCKER=(sudo docker)
fi

"${DOCKER[@]}" inspect "$CONTAINER" >/dev/null 2>&1 \
    || fail "Docker container '$CONTAINER' not found."

STAMP="$(date +%Y%m%d-%H%M%S)"

echo "[1/7] Verifying TSP_MAPMEM_V1 source..."
"${DOCKER[@]}" exec "$CONTAINER" bash -s -- "$LOCALMAP" "$CMAKE_FILE" <<'CHECK'
set -Eeuo pipefail
LOCALMAP="$1"
CMAKE_FILE="$2"
test -f "$LOCALMAP"
test -f "$CMAKE_FILE"
grep -q 'TSP_MAPMEM_V1' "$LOCALMAP" || {
    echo "ERROR: TSP_MAPMEM_V1 is not present in localmap.cpp."
    exit 20
}
echo "TSP_MAPMEM_V1 source marker: PASS"
CHECK

echo
echo "[2/7] Backing up current VM source/build state..."
"${DOCKER[@]}" exec "$CONTAINER" bash -s -- \
    "$SRC" "$BUILD" "$CMAKE_FILE" "$LOCALMAP" "$STAMP" <<'BACKUP'
set -Eeuo pipefail
SRC="$1"; BUILD="$2"; CMAKE_FILE="$3"; LOCALMAP="$4"; STAMP="$5"
BACK="/root/tsp_patch_backups/mapmem-sigill-safe-v2-$STAMP"
mkdir -p "$BACK"
cp -p "$CMAKE_FILE" "$BACK/CMakeLists.txt.before"
cp -p "$LOCALMAP" "$BACK/localmap.cpp.before"
if [ -f "$BUILD/openmw" ]; then
    cp -p "$BUILD/openmw" "$BACK/openmw.before"
    sha256sum "$BUILD/openmw" > "$BACK/openmw.before.sha256"
fi
git -C "$SRC" status --short --untracked-files=all > "$BACK/git-status.before.txt" 2>&1 || true
git -C "$SRC" diff > "$BACK/git-working.before.diff" 2>&1 || true
echo "VM backup: $BACK"
BACKUP

echo
echo "[3/7] Applying target-wide safe ARM ISA flags..."
"${DOCKER[@]}" exec "$CONTAINER" python3 - "$CMAKE_FILE" <<'PY'
from pathlib import Path
import re, sys
p = Path(sys.argv[1])
s = p.read_text()
begin = "# >>> TSP_SAFE_ISA_OPENMW_V2 BEGIN"
end = "# <<< TSP_SAFE_ISA_OPENMW_V2 END"
block = """# >>> TSP_SAFE_ISA_OPENMW_V2 BEGIN
# Original TrimUI Smart Pro is ARMv8-A baseline. Keep all OpenMW app TUs there.
if (CMAKE_SYSTEM_PROCESSOR MATCHES \"^(aarch64|arm64|AARCH64|ARM64)$\")
    target_compile_options(openmw-lib PRIVATE
        -march=armv8-a
        -mtune=generic
        -O2
        -fno-lto
    )
    if (TARGET openmw)
        target_compile_options(openmw PRIVATE
            -march=armv8-a
            -mtune=generic
            -O2
            -fno-lto
        )
        target_link_options(openmw PRIVATE -fno-lto)
    endif()
endif()
# <<< TSP_SAFE_ISA_OPENMW_V2 END
"""
if begin in s:
    pat = re.compile(re.escape(begin) + r".*?" + re.escape(end) + r"\n?", re.S)
    s, n = pat.subn(block, s, count=1)
    if n != 1:
        raise SystemExit("ERROR: could not replace existing safe-ISA block")
else:
    anchor = "target_link_libraries(openmw openmw-lib)"
    if s.count(anchor) != 1:
        raise SystemExit(f"ERROR: expected one anchor, found {s.count(anchor)}")
    s = s.replace(anchor, anchor + "\n\n" + block.rstrip("\n"), 1)
p.write_text(s)
s = p.read_text()
if s.count(begin) != 1 or s.count(end) != 1:
    raise SystemExit("ERROR: safe-ISA marker count is not exactly one")
print("TSP_SAFE_ISA_OPENMW_V2 patch: PASS")
PY

echo
echo "[4/7] Forcing a safe rebuild of OpenMW app translation units..."
DRY="$("${DOCKER[@]}" exec "$CONTAINER" cmake --build "$BUILD" --target openmw -- -n 2>&1)"
COUNT="$(printf '%s\n' "$DRY" | grep -c 'Building CXX object apps/openmw/' || true)"
echo "OpenMW C++ objects scheduled for safe rebuild: $COUNT"
if [ "${COUNT:-0}" -lt 20 ]; then
    printf '%s\n' "$DRY" | tail -80
    fail "Safe-ISA change did not schedule a broad OpenMW rebuild."
fi
"${DOCKER[@]}" exec "$CONTAINER" cmake --build "$BUILD" --target openmw -- -j2

echo
echo "[5/7] Verifying rebuilt binary..."
"${DOCKER[@]}" exec "$CONTAINER" bash -s -- "$BUILD" <<'VERIFY'
set -Eeuo pipefail
BUILD="$1"; BIN="$BUILD/openmw"
test -s "$BIN"
readelf -h "$BIN" | grep -q 'AArch64'
grep -a -q 'TSP_MAPMEM_V1' "$BIN"
echo "AArch64: PASS"
echo "TSP_MAPMEM_V1: PASS"
echo "SHA256:"
sha256sum "$BIN"
echo "Safe flag proof:"
ninja -C "$BUILD" -t commands 2>/dev/null \
  | grep 'apps/openmw/CMakeFiles/openmw-lib.dir/' \
  | head -1 \
  | grep -o -- '-march=armv8-a\|-mtune=generic\|-O2\|-fno-lto' \
  | tr '\n' ' '
echo
VERIFY

rm -f "$OUTBIN"
"${DOCKER[@]}" cp "$CONTAINER:$BUILD/openmw" "$OUTBIN"
chmod 755 "$OUTBIN"
test -s "$OUTBIN" || fail "Exported binary is missing."
readelf -h "$OUTBIN" | grep -q 'AArch64' || fail "Exported binary is not AArch64."
grep -a -q 'TSP_MAPMEM_V1' "$OUTBIN" || fail "Exported binary lost TSP_MAPMEM_V1."

echo
echo "[6/7] Deploying with one SSH connection..."
# One SSH session: tar streams the replacement to /tmp, then the remote shell
# backs up and atomically replaces the installed binary.
tar -C "$OUTDIR" -cf - "$(basename "$OUTBIN")" | \
ssh "$DEVICE" '
set -eu
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
[ -n "$ROOT" ] || { echo "ERROR: OpenMW root not found"; exit 60; }

LIVE="$ROOT/bin/openmw-0.51"
STAMP="$(date +%Y%m%d-%H%M%S 2>/dev/null || echo now)"
BACK="$ROOT/bin/openmw-0.51.before-mapmem-safe-v2-$STAMP"
TMP="/tmp/openmw-0.51-tsp-mapmem-safe-v2"

rm -f "$TMP"
tar -xf - -C /tmp
[ -s "$TMP" ] || { echo "ERROR: streamed binary missing"; exit 61; }

echo "Backing up current installed binary:"
cp -p "$LIVE" "$BACK"
echo "$BACK"

cp -f "$TMP" "$LIVE.new"
chmod 755 "$LIVE.new"
strings "$LIVE.new" 2>/dev/null | grep -q "TSP_MAPMEM_V1" || {
    echo "ERROR: replacement lacks TSP_MAPMEM_V1"
    rm -f "$LIVE.new" "$TMP"
    exit 62
}

mv -f "$LIVE.new" "$LIVE"
rm -f "$TMP"
sync

echo "Installed:"
ls -lh "$LIVE"
echo "SHA256:"
sha256sum "$LIVE"
echo "TSP_MAPMEM_V1: VERIFIED"
echo "Backup: $BACK"
'

echo
echo "[7/7] COMPLETE"
echo "============================================================"
echo "SAFE MAPMEM BUILD INSTALLED"
echo "============================================================"
echo "VM copy: $OUTBIN"
echo "Use the existing DIAGNOSTICS-MEMWATCH launcher."
echo "Do a 2-3 minute smoke test first, then run the pull script."
echo "============================================================"
