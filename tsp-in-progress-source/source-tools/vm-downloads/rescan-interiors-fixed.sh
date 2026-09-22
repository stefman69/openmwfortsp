#!/usr/bin/env bash
# rescan-interiors-fixed.sh
#
# THE BUG IN THE CELL LIST
#   The installer's esm_list_interiors.py walks a CELL record's subrecords and
#   does:
#       if sub == b'NAME':  name = ...
#       elif sub == b'DATA': flags = ...
#   without stopping. But an ESM3 CELL record is laid out as:
#       NAME  <- the cell's own name
#       DATA  <- the cell's own 12 bytes: flags, gridX, gridY
#       FRMR / NAME / DATA(24) / ...   <- one block PER OBJECT REFERENCE
#   Every reference carries its OWN NAME (an object id) and its own 24-byte
#   position DATA. So the loop ends up holding the LAST reference's object id
#   as the "cell name", and the last reference's float position bits as the
#   "flags". Whether a record survived the (flags & 1) test then came down to
#   whether bit 0 of a float happened to be set.
#
#   That is exactly what the scan reported:
#       SKIP  Ex_T_menhir_L_01   Interior cell is not found
#       SKIP  Flora_kelp_02      Interior cell is not found
#       # scanned=7 skipped=502 listed=509
#   The 7 that worked are cells with no references, where the only NAME in the
#   record IS the cell name.
#
#   Fix: take the FIRST NAME, take the FIRST 12-byte DATA, then stop.
#
# No rebuild. The sensor is not touched. Safe to rerun.
set -Eeuo pipefail

if [ -f "$HOME/Downloads/visgrid-tools/device.env" ]; then
    # shellcheck disable=SC1091
    . "$HOME/Downloads/visgrid-tools/device.env" || true
fi
if [ -n "${TSP_IP:-}" ]; then DEV="root@$TSP_IP"; else DEV="${TSP_DEV:-root@192.168.1.25}"; fi

STAMP="$(date +%Y%m%d-%H%M%S)"
ROOT="/mnt/SDCARD/data/ports/openmw51"
BIN="$ROOT/bin/openmw-0.51"
MOD="$ROOT/mods/TSPInteriorVisGrid"
DATADIR_DEFAULT="$ROOT/data/Data Files"
TOOLS="$HOME/Downloads/visgrid-tools"
PKG="$HOME/Downloads/openmw51-interior-rescan-$STAMP"
mkdir -p "$PKG/esm" "$TOOLS"
exec > >(tee "$PKG/rescan.log") 2>&1

echo "=================================================================="
echo "REBUILD THE INTERIOR CELL LIST WITH THE CORRECTED ESM PARSER"
echo "=================================================================="
echo "Device: $DEV"
echo

if ssh "$DEV" 'pidof openmw-0.51 >/dev/null 2>&1 || pidof openmw >/dev/null 2>&1'; then
    echo "ERROR: OpenMW is running. Exit it normally, then rerun."
    exit 20
fi
ssh "$DEV" "grep -a -q 'TSP_INTERIOR_SCAN_051_V1' '$BIN'"
echo "PASS: binary carries the scanner."

echo
echo "===== 1/4 REUSE THE ESMs ALREADY PULLED, OR PULL THEM AGAIN ====="
PREV="$(ls -1dt "$HOME"/Downloads/openmw51-interior-scan-arm-*/esm 2>/dev/null | head -1 || true)"
PULLED=()
if [ -n "$PREV" ] && [ -n "$(ls -1 "$PREV"/*.esm "$PREV"/*.esp 2>/dev/null || true)" ]; then
    echo "  reusing content files from $PREV"
    for f in "$PREV"/*.esm "$PREV"/*.esp; do
        [ -s "$f" ] || continue
        cp -f "$f" "$PKG/esm/"
        PULLED+=("$PKG/esm/$(basename "$f")")
        echo "    $(basename "$f")  ($(stat -c %s "$f") bytes)"
    done
else
    echo "  no previous pull found - pulling from the device"
    mapfile -t FILES < <(ssh "$DEV" "ls -1 '$DATADIR_DEFAULT' 2>/dev/null" | tr -d '\r' | grep -iE '\.(esm|esp)$' || true)
    [ "${#FILES[@]}" -gt 0 ] || { echo "ERROR: no ESM/ESP in $DATADIR_DEFAULT"; exit 30; }
    for cf in "${FILES[@]}"; do
        echo "    pulling $cf"
        ssh "$DEV" "cat \"$DATADIR_DEFAULT/$cf\"" > "$PKG/esm/$cf"
        [ -s "$PKG/esm/$cf" ] && PULLED+=("$PKG/esm/$cf")
    done
fi
[ "${#PULLED[@]}" -gt 0 ] || { echo "ERROR: no content files available."; exit 31; }

echo
echo "===== 2/4 PARSE WITH THE CORRECTED PARSER ====="
cat > "$PKG/esm/esm_list_interiors_fixed.py" <<'EOF_ESMPY'
#!/usr/bin/env python3
# TSP interior-cell name lister - CORRECTED.
# ESM3 CELL layout:  NAME(cell) DATA(12: flags,gridX,gridY)  then, per object
# reference, FRMR NAME(object id) ... DATA(24: position). Taking anything but
# the FIRST NAME and the FIRST 12-byte DATA yields object ids and float garbage.
import sys, struct

def list_interiors(path):
    names = []
    with open(path, 'rb') as f:
        data = f.read()
    n = len(data)
    off = 0
    while off + 16 <= n:
        rec = data[off:off+4]
        (size,) = struct.unpack_from('<I', data, off+4)
        body = off + 16
        if body + size > n:
            break
        if rec == b'CELL':
            name = None
            flags = None
            s = body
            end = body + size
            while s + 8 <= end:
                sub = data[s:s+4]
                (ssize,) = struct.unpack_from('<I', data, s+4)
                sdata = s + 8
                if sdata + ssize > end:
                    break
                if sub == b'NAME' and name is None:
                    raw = data[sdata:sdata+ssize]
                    name = raw.split(b'\x00')[0].decode('cp1252', 'replace')
                elif sub == b'DATA' and flags is None and ssize == 12:
                    (flags,) = struct.unpack_from('<I', data, sdata)
                if name is not None and flags is not None:
                    break
                s = sdata + ssize
            if name and flags is not None and (flags & 0x01):
                names.append(name)
        off = body + size
    return names

seen, order = {}, []
for p in sys.argv[1:]:
    try:
        for nm in list_interiors(p):
            if nm not in seen:
                seen[nm] = True
                order.append(nm)
    except Exception as e:
        print("ERROR parsing %s: %s" % (p, e), file=sys.stderr)
        sys.exit(1)
for nm in order:
    print(nm)
print("TOTAL_INTERIORS=%d" % len(order), file=sys.stderr)
EOF_ESMPY

python3 "$PKG/esm/esm_list_interiors_fixed.py" "${PULLED[@]}" > "$PKG/interior_cells.txt"
NCELLS=$(wc -l < "$PKG/interior_cells.txt")
echo "  interiors found: $NCELLS"

echo
echo "===== 3/4 SANITY-CHECK THE NAMES ====="
# Object ids look like Flora_kelp_02 / ex_t_rock_coastal_01: underscores, no
# spaces. Real interior cell names are overwhelmingly prose with spaces and
# commas. If this list is still object ids, stop before touching the card.
WITHSPACE=$(grep -c ' ' "$PKG/interior_cells.txt" || true)
UNDERSCORE=$(grep -c '_' "$PKG/interior_cells.txt" || true)
echo "  names containing a space     : $WITHSPACE / $NCELLS"
echo "  names containing underscore  : $UNDERSCORE / $NCELLS"
echo "  first 8:"; head -8 "$PKG/interior_cells.txt" | sed 's/^/    /'
echo "  a known cell from your log:"
if grep -Fq "Caldera, Governor's Hall" "$PKG/interior_cells.txt"; then
    echo "    FOUND \"Caldera, Governor's Hall\""
else
    echo "    NOT FOUND - \"Caldera, Governor's Hall\""
    echo
    echo "ERROR: the cell you were standing in is missing from the list."
    echo "Nothing was changed on the device. Send $PKG/interior_cells.txt"
    exit 32
fi
if [ "$NCELLS" -lt 200 ]; then
    echo
    echo "ERROR: only $NCELLS interiors - full Morrowind has roughly a thousand."
    echo "Nothing was changed on the device. Send $PKG/interior_cells.txt"
    exit 33
fi
if [ "$WITHSPACE" -lt $((NCELLS / 2)) ]; then
    echo
    echo "ERROR: fewer than half the names contain a space - these still look"
    echo "like object ids. Nothing was changed. Send $PKG/interior_cells.txt"
    exit 34
fi
echo "PASS: the list looks like real interior cell names."

echo
echo "===== 4/4 INSTALL + RE-ARM ====="
LIST_SHA="$(sha256sum "$PKG/interior_cells.txt" | awk '{print $1}')"
scp -q "$PKG/interior_cells.txt" "$DEV:/tmp/tsp_interior_scan_cells.txt"
ssh "$DEV" "
set -e
test \"\$(sha256sum /tmp/tsp_interior_scan_cells.txt | awk '{print \$1}')\" = '$LIST_SHA'
mv -f /tmp/tsp_interior_scan_cells.txt '$ROOT/tsp_interior_scan_cells.txt'
# retire the bad scan + the 7-cell map built from it
[ -f '$ROOT/tsp_interior_scan.txt' ] && mv -f '$ROOT/tsp_interior_scan.txt' '$ROOT/tsp_interior_scan.txt.bad-$STAMP' || true
[ -f '$MOD/scripts/TSPInteriorVisGrid/interiormap.lua' ] && mv -f '$MOD/scripts/TSPInteriorVisGrid/interiormap.lua' '$MOD/scripts/TSPInteriorVisGrid/interiormap.lua.bad-$STAMP' || true
touch '$ROOT/tsp_scan_interiors.flag'
sync
echo \"PASS: \$(wc -l < '$ROOT/tsp_interior_scan_cells.txt') cells on card, scan re-armed.\"
echo 'PASS: the 7-cell map and the bad scan were set aside (.bad-$STAMP).'
"

echo
echo "=================================================================="
echo "RE-ARMED WITH $NCELLS INTERIORS"
echo "=================================================================="
echo
echo "  1. Launch Morrowind_51. It scans and CLOSES ITSELF (expected)."
echo "     This pass walks ~$NCELLS cells instead of 7, so give it longer."
echo "  2. Check the result before building the map:"
echo "       . ~/Downloads/visgrid-tools/device.env 2>/dev/null; \\"
echo "       ssh \"root@\${TSP_IP:-192.168.1.25}\" 'tail -1 $ROOT/tsp_interior_scan.txt'"
echo "     You want scanned close to $NCELLS and skipped near zero."
echo "  3. Then:  ~/Downloads/visgrid-tools/finish-interior-map.sh"
echo
echo "  Note: the map you have RIGHT NOW covers 7 cells, so it is almost"
echo "  certainly doing nothing in Caldera. Whatever changed the fog and the"
echo "  frame rate was not the map."
echo "=================================================================="
