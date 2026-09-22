#!/usr/bin/env bash
# arm-interior-scan.sh
#
# WHY THE V11 INSTALLER FAILED TO ARM THE SCAN
#   Step 6/11 reads ONE config file:
#       /mnt/SDCARD/data/ports/openmw51/config-0.51/openmw.cfg
#   but on this install that is the USER content config. The config that
#   actually carries data=/content= is the main one:
#       /mnt/SDCARD/data/ports/openmw51/openmw.cfg   (synced to bin/openmw.cfg)
#   With no data= lines it found no ESMs, printed "content files unreadable",
#   and disarmed the scan.
#
# WHAT THIS DOES
#   Reads EVERY candidate config, parses them properly (OpenMW's &-escaping
#   included), falls back to globbing the Data Files directory if the configs
#   yield nothing, pulls the ESM/ESP files, builds the interior-cell name
#   list, installs it on the card and arms the one-shot scan.
#
#   No rebuild. The binary already carries TSP_INTERIOR_SCAN_051_V1.
#   The sensor is NOT touched - your V11a load-safe hold stays installed.
#
# DO NOT rerun the V11 installer to fix this: it would reinstall the stock
# V11 sensor and wipe the V11a hold.
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
LUA="$MOD/scripts/TSPInteriorVisGrid/visgrid.lua"
DATADIR_DEFAULT="$ROOT/data/Data Files"
TOOLS="$HOME/Downloads/visgrid-tools"
PKG="$HOME/Downloads/openmw51-interior-scan-arm-$STAMP"
LOG="$PKG/arm.log"
mkdir -p "$PKG/esm" "$TOOLS"

fail() {
    local rc="${1:-1}" line="${2:-unknown}" cmd="${3:-unknown}"
    trap - ERR
    set +e
    {
        echo
        echo "=================================================================="
        echo "ARM-INTERIOR-SCAN STOPPED SAFELY"
        echo "=================================================================="
        echo "Date: $(date)"; echo "Exit code: $rc"; echo "Line: $line"; echo "Command: $cmd"
        echo
        [ -f "$LOG" ] && { echo "----- arm.log tail -----"; tail -160 "$LOG"; }
        echo
        echo "Nothing was rebuilt and the sensor was not touched."
        echo "Preserved at: $PKG"
    } | tee "$PKG/STOPPED_ERROR.txt"
    exit "$rc"
}
trap 'fail "$?" "$LINENO" "$BASH_COMMAND"' ERR
exec > >(tee "$LOG") 2>&1

echo "=================================================================="
echo "ARM THE ONE-SHOT INTERIOR SCAN"
echo "=================================================================="
echo "Device: $DEV"
echo

echo "===== 1/6 PRECONDITIONS ====="
if ssh "$DEV" 'pidof openmw-0.51 >/dev/null 2>&1 || pidof openmw >/dev/null 2>&1'; then
    echo "ERROR: OpenMW is running. Exit it normally, then rerun this script."
    exit 20
fi
ssh "$DEV" "
set -e
test -s '$BIN'
grep -a -q 'TSP_INTERIOR_SCAN_051_V1' '$BIN'
echo 'PASS: binary carries the interior scanner.'
"
if ssh "$DEV" "grep -Fq 'TSP_VISGRID_V11_LOADSAFE_12S' '$LUA'"; then
    echo "PASS: V11a load-safe sensor is the active one (it will not be touched)."
else
    echo "NOTE: active sensor does NOT carry the V11a hold. This script still works,"
    echo "      but you may want to rerun apply_visgrid_v11a_loadsafe.sh afterwards."
fi

echo
echo "===== 2/6 PULL EVERY CANDIDATE CONFIG ====="
CFGS=(
    "$ROOT/openmw.cfg"
    "$ROOT/bin/openmw.cfg"
    "$ROOT/config-0.51/openmw.cfg"
    "$ROOT/config-0.51/openmw/openmw.cfg"
)
i=0
for c in "${CFGS[@]}"; do
    i=$((i+1))
    if ssh "$DEV" "test -f '$c'"; then
        ssh "$DEV" "cat '$c'" > "$PKG/esm/cfg$i.cfg" 2>/dev/null || true
        n_data=$(grep -c '^data=' "$PKG/esm/cfg$i.cfg" 2>/dev/null || true)
        n_cont=$(grep -c '^content=' "$PKG/esm/cfg$i.cfg" 2>/dev/null || true)
        printf '  %-52s data=%-3s content=%s\n' "$c" "$n_data" "$n_cont"
    else
        printf '  %-52s MISSING\n' "$c"
    fi
done

echo
echo "===== 3/6 RESOLVE DATA DIRS + CONTENT FILES ====="
python3 - "$PKG/esm" > "$PKG/esm/resolved.txt" <<'PYCFG'
import sys, os, glob

d = sys.argv[1]

def unescape(v):
    # OpenMW config: a value may be wrapped in double quotes, and inside a
    # quoted value '&' is the escape character ('&&' -> '&', '&"' -> '"').
    v = v.strip()
    if v.startswith('"'):
        out, i, n = [], 1, len(v)
        while i < n:
            ch = v[i]
            if ch == '&' and i + 1 < n:
                out.append(v[i+1]); i += 2; continue
            if ch == '"':
                break
            out.append(ch); i += 1
        return ''.join(out)
    return v

datadirs, content = [], []
for path in sorted(glob.glob(os.path.join(d, 'cfg*.cfg'))):
    try:
        lines = open(path, encoding='utf-8', errors='replace').read().splitlines()
    except Exception:
        continue
    for raw in lines:
        raw = raw.rstrip('\r')
        if raw.startswith('data='):
            v = unescape(raw[5:])
            if v and v not in datadirs:
                datadirs.append(v)
        elif raw.startswith('content='):
            v = unescape(raw[8:])
            if v and v not in content:
                content.append(v)

for x in datadirs:
    print('DATA\t' + x)
for x in content:
    print('CONTENT\t' + x)
PYCFG

mapfile -t DATADIRS < <(sed -n 's/^DATA\t//p' "$PKG/esm/resolved.txt")
mapfile -t CONTENT  < <(sed -n 's/^CONTENT\t//p' "$PKG/esm/resolved.txt")

# Always consider the launcher-verified location, even if no config named it.
DATADIRS+=("$DATADIR_DEFAULT")

echo "  data dirs from configs:"
for d in "${DATADIRS[@]}"; do echo "    $d"; done
echo "  content entries from configs: ${#CONTENT[@]}"
for c in "${CONTENT[@]}"; do echo "    $c"; done

# Fallback: if the configs named no content files, glob the data dir.
if [ "${#CONTENT[@]}" -eq 0 ]; then
    echo "  configs named no content files - globbing the data directory instead."
    mapfile -t CONTENT < <(ssh "$DEV" "ls -1 '$DATADIR_DEFAULT' 2>/dev/null" \
        | tr -d '\r' | grep -iE '\.(esm|esp)$' || true)
    echo "  found ${#CONTENT[@]} ESM/ESP file(s) in $DATADIR_DEFAULT"
    for c in "${CONTENT[@]}"; do echo "    $c"; done
fi

[ "${#CONTENT[@]}" -gt 0 ] || {
    echo
    echo "ERROR: no ESM/ESP files found in any config or in:"
    echo "  $DATADIR_DEFAULT"
    echo "Device listing of that directory:"
    ssh "$DEV" "ls -la '$DATADIR_DEFAULT' 2>&1 | head -40" || true
    exit 30
}

echo
echo "===== 4/6 PULL THE CONTENT FILES ====="
PULLED=()
for cf in "${CONTENT[@]}"; do
    case "$cf" in *.esm|*.ESM|*.esp|*.ESP|*.Esm|*.Esp) ;; *) continue ;; esac
    found=0
    for dd in "${DATADIRS[@]}"; do
        if ssh "$DEV" "test -f \"$dd/$cf\""; then
            sz=$(ssh "$DEV" "stat -c %s \"$dd/$cf\" 2>/dev/null || wc -c < \"$dd/$cf\"" | tr -d '\r ')
            echo "  pulling $cf  (${sz} bytes) from $dd"
            ssh "$DEV" "cat \"$dd/$cf\"" > "$PKG/esm/$cf"
            if [ -s "$PKG/esm/$cf" ]; then
                PULLED+=("$PKG/esm/$cf")
                found=1
            fi
            break
        fi
    done
    [ "$found" -eq 1 ] || echo "  NOT FOUND in any data dir: $cf"
done
[ "${#PULLED[@]}" -gt 0 ] || { echo "ERROR: pulled zero content files."; exit 31; }
echo "PASS: pulled ${#PULLED[@]} content file(s)."

echo
echo "===== 5/6 BUILD THE INTERIOR CELL LIST ====="
cat > "$PKG/esm/esm_list_interiors.py" <<'EOF_ESMPY'
#!/usr/bin/env python3
# Parses ESM3 content files and prints every INTERIOR cell name, one per line.
# Reads CELL record headers + NAME/DATA subrecords only - no refs, no meshes.
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
                if sub == b'NAME':
                    raw = data[sdata:sdata+ssize]
                    name = raw.split(b'\x00')[0].decode('cp1252', 'replace')
                elif sub == b'DATA' and ssize >= 4:
                    (flags,) = struct.unpack_from('<I', data, sdata)
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

python3 "$PKG/esm/esm_list_interiors.py" "${PULLED[@]}" > "$PKG/interior_cells.txt"
NCELLS=$(wc -l < "$PKG/interior_cells.txt")
echo "PASS: $NCELLS interior cells listed."
[ "$NCELLS" -ge 1 ] || { echo "ERROR: zero interiors parsed."; exit 32; }
echo "  first 5:"; head -5 "$PKG/interior_cells.txt" | sed 's/^/    /'
echo "  last 5:";  tail -5 "$PKG/interior_cells.txt" | sed 's/^/    /'
if [ "$NCELLS" -lt 50 ]; then
    echo "  NOTE: fewer than 50 interiors - low for full Morrowind, check the list above."
fi

echo
echo "===== 6/6 INSTALL THE LIST + ARM THE SCAN ====="
LIST_SHA="$(sha256sum "$PKG/interior_cells.txt" | awk '{print $1}')"
scp -q "$PKG/interior_cells.txt" "$DEV:/tmp/tsp_interior_scan_cells.txt"
ssh "$DEV" "
set -e
test -s /tmp/tsp_interior_scan_cells.txt
test \"\$(sha256sum /tmp/tsp_interior_scan_cells.txt | awk '{print \$1}')\" = '$LIST_SHA'
mv -f /tmp/tsp_interior_scan_cells.txt '$ROOT/tsp_interior_scan_cells.txt'
rm -f '$ROOT/tsp_interior_scan.txt'
touch '$ROOT/tsp_scan_interiors.flag'
sync
test -s '$ROOT/tsp_interior_scan_cells.txt'
test -f '$ROOT/tsp_scan_interiors.flag'
echo \"PASS: \$(wc -l < '$ROOT/tsp_interior_scan_cells.txt') cells on card, scan armed.\"
"

cat > "$TOOLS/disarm-interior-scan.sh" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
if [ -f "\$HOME/Downloads/visgrid-tools/device.env" ]; then . "\$HOME/Downloads/visgrid-tools/device.env" || true; fi
if [ -n "\${TSP_IP:-}" ]; then DEV="root@\$TSP_IP"; else DEV="\${TSP_DEV:-root@192.168.1.25}"; fi
ssh "\$DEV" "rm -f '$ROOT/tsp_scan_interiors.flag'; sync; echo 'scan disarmed'"
EOF
chmod +x "$TOOLS/disarm-interior-scan.sh"

echo
echo "=================================================================="
echo "SCAN ARMED - $NCELLS INTERIORS"
echo "=================================================================="
echo
echo "  1. Launch Morrowind_51. It will scan for a few seconds and CLOSE"
echo "     ITSELF. That is the scan finishing, not a crash. You do not"
echo "     need to reach the menu or load a save."
echo
echo "  2. Then run:"
echo "       ~/Downloads/visgrid-tools/finish-interior-map.sh"
echo
echo "  3. Then launch again and play normally. Expect:"
echo "       [TSP_VISGRID_V11] interior map loaded: <N> cells"
echo "       [TSP_VISGRID_V11] map: \"<cell>\" cap=<n>"
echo
echo "  Changed your mind before launching:"
echo "       ~/Downloads/visgrid-tools/disarm-interior-scan.sh"
echo
echo "  DO NOT rerun the V11 installer to arm this - it would reinstall the"
echo "  stock V11 sensor and wipe the V11a load-safe hold."
echo "=================================================================="
