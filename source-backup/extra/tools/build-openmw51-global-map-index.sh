#!/usr/bin/env bash
set -Eeuo pipefail

STAMP="$(date +%Y%m%d-%H%M%S)"
CTR="${TSP_BUILDER:-openmw_builder}"
ROOT="/mnt/SDCARD/data/ports/openmw51"
CFG="$ROOT/config-0.51/openmw.cfg"
CACHE="$HOME/Downloads/openmw51-global-map-cache"
OUTDIR="$HOME/Downloads/openmw51-global-map-$STAMP"
LOG="$OUTDIR/collect.log"

mkdir -p "$CACHE/content" "$OUTDIR"

if [ -f "$HOME/Downloads/visgrid-tools/device.env" ]; then
    . "$HOME/Downloads/visgrid-tools/device.env" || true
fi
if [ -n "${TSP_DEV:-}" ]; then DEV="$TSP_DEV"
elif [ -n "${TSP_IP:-}" ]; then DEV="root@$TSP_IP"
else DEV="root@192.168.1.25"; fi

SSH=(-o BatchMode=yes -o ConnectTimeout=8)

fail() {
    rc=$?
    line=$1
    cmd=$2
    trap - ERR
    {
      echo
      echo "=================================================================="
      echo "GLOBAL MAP COLLECTOR STOPPED"
      echo "=================================================================="
      echo "Exit code: $rc"
      echo "Line: $line"
      echo "Command: $cmd"
      [ -f "$LOG" ] && tail -180 "$LOG" || true
      echo "Partial output preserved: $OUTDIR"
    } | tee "$OUTDIR/STOPPED_ERROR.txt"
    exit "$rc"
}
trap 'fail "$LINENO" "$BASH_COMMAND"' ERR
exec > >(tee "$LOG") 2>&1

echo "=================================================================="
echo "OPENMW 0.51 — GLOBAL CELL / DOOR / NAVMESH INDEX"
echo "=================================================================="
echo "READ-ONLY on the TrimUI."
echo "Actual ESM/ESP door refs provide cell/world transitions."
echo "Existing navmesh.db provides topology-worldspace coverage."
echo "No navmesh regeneration is requested."
echo

echo "===== 1/7 FETCH ACTIVE OPENMW CONFIG ====="
ssh "${SSH[@]}" "$DEV" "test -s '$CFG'"
ssh "${SSH[@]}" "$DEV" "cat '$CFG'" > "$OUTDIR/openmw.cfg"
test -s "$OUTDIR/openmw.cfg"

python3 - "$OUTDIR/openmw.cfg" "$OUTDIR/content-list.tsv" <<'PY_CFG'
from pathlib import Path
import sys

cfg = Path(sys.argv[1]).read_text(errors='replace').splitlines()
out = Path(sys.argv[2])
data = []
content = []
for raw in cfg:
    line = raw.strip()
    if not line or line.startswith('#'):
        continue
    if line.startswith('data=') or line.startswith('data-local='):
        v = line.split('=', 1)[1].strip()
        if len(v) >= 2 and v[0] == '"' and v[-1] == '"':
            v = v[1:-1]
        data.append(v)
    elif line.startswith('content='):
        content.append(line.split('=', 1)[1].strip())

with out.open('w') as f:
    f.write("# load_index\tcontent\n")
    for i, c in enumerate(content):
        f.write(f"{i}\t{c}\n")
Path(str(out) + ".datadirs").write_text("\n".join(data) + "\n")
print(f"data_dirs={len(data)} content_entries={len(content)}")
PY_CFG

mapfile -t DATADIRS < "$OUTDIR/content-list.tsv.datadirs"
mapfile -t CONTENT < <(awk -F $'\t' '!/^#/ {print $2}' "$OUTDIR/content-list.tsv")
echo "PASS: ${#DATADIRS[@]} data dirs, ${#CONTENT[@]} content entries."

echo
echo "===== 2/7 PULL/CACHE ESM3 CONTENT FILES ====="
: > "$OUTDIR/local-content.tsv"

DOCKER_OK=0
if command -v docker >/dev/null 2>&1 \
    && docker inspect "$CTR" >/dev/null 2>&1; then
    if [ "$(docker inspect -f '{{.State.Running}}' "$CTR" 2>/dev/null || true)" != "true" ]; then
        docker start "$CTR" >/dev/null
    fi
    DOCKER_OK=1
    echo "Docker content source available: $CTR"
else
    echo "Docker content source unavailable; device fallback remains enabled."
fi

DEVICE_DATA_DIRS=(
    "/mnt/sdcard/mmcblk1p1/Data/ports/openmw51/data/Data Files"
    "/mnt/SDCARD/mmcblk1p1/Data/ports/openmw51/data/Data Files"
)

for dd in "${DATADIRS[@]}"; do
    [ -n "$dd" ] && DEVICE_DATA_DIRS+=("$dd")
done

find_docker_content() {
    local cf="$1"
    [ "$DOCKER_OK" = 1 ] || return 1

    local p

    for p in \
        "/root/$cf" \
        "/root/Data Files/$cf" \
        "/root/openmw-data/Data Files/$cf" \
        "/root/openmw-0.51-tsp-data/Data Files/$cf" \
        "/root/openmw-0.51-tsp-src/Data Files/$cf" \
        "/root/openmw-0.51-tsp-package/Data Files/$cf"
    do
        if docker exec "$CTR" test -f "$p" 2>/dev/null; then
            printf '%s\n' "$p"
            return 0
        fi
    done

    docker exec "$CTR" bash -lc '
      cf="$1"
      find /root /mnt /tmp /opt /workspace \
        -type f -iname "$cf" -print -quit 2>/dev/null
    ' _ "$cf" 2>/dev/null | head -1
}

find_device_content() {
    local cf="$1"
    local dd path qpath

    for dd in "${DEVICE_DATA_DIRS[@]}"; do
        [ -n "$dd" ] || continue

        path="$dd/$cf"
        printf -v qpath '%q' "$path"

        if ssh "${SSH[@]}" "$DEV" "test -f $qpath"; then
            printf '%s\n' "$path"
            return 0
        fi
    done

    return 1
}

LOAD_INDEX=0
FOUND_ESM3=0

for cf in "${CONTENT[@]}"; do
    case "$cf" in
        *.esm|*.ESM|*.esp|*.ESP) ;;
        *)
            echo "SKIP non-ESM3 content in first graph pass: $cf"
            LOAD_INDEX=$((LOAD_INDEX+1))
            continue
            ;;
    esac

    SAFE="$(printf '%s' "$cf" | tr '/ ' '__')"
    SOURCE_KIND=""
    SOURCE_PATH=""
    SHA=""

    # --------------------------------------------------------------
    # FIRST CHOICE:
    # reuse the ESM/ESP copies already present in Docker.
    # --------------------------------------------------------------
    SOURCE_PATH="$(find_docker_content "$cf" || true)"

    if [ -n "$SOURCE_PATH" ]; then
        SOURCE_KIND="DOCKER"
        SHA="$(
            docker exec "$CTR" sha256sum "$SOURCE_PATH" \
                | awk '{print $1}'
        )"
    else
        # ----------------------------------------------------------
        # SECOND CHOICE:
        # actual TrimUI Data Files path, then configured data paths.
        # ----------------------------------------------------------
        SOURCE_PATH="$(find_device_content "$cf" || true)"

        if [ -n "$SOURCE_PATH" ]; then
            SOURCE_KIND="DEVICE"
            printf -v QSOURCE '%q' "$SOURCE_PATH"

            SHA="$(
                ssh "${SSH[@]}" "$DEV" "sha256sum $QSOURCE" \
                    | awk '{print $1}'
            )"
        fi
    fi

    if [ -z "$SOURCE_PATH" ] || [ -z "$SHA" ]; then
        echo "MISSING $cf"
        echo "  Docker searched:"
        echo "    /root /mnt /tmp /opt /workspace"
        echo "  Device first path:"
        echo "    /mnt/sdcard/mmcblk1p1/Data/ports/openmw51/data/Data Files/$cf"

        LOAD_INDEX=$((LOAD_INDEX+1))
        continue
    fi

    LOCAL="$CACHE/content/${SHA}-${SAFE}"

    if [ -s "$LOCAL" ] \
        && [ "$(sha256sum "$LOCAL" | awk '{print $1}')" = "$SHA" ]; then

        echo "CACHE  $cf"
        echo "  source=$SOURCE_KIND:$SOURCE_PATH"

    else
        TMP="$LOCAL.partial"
        rm -f "$TMP"

        if [ "$SOURCE_KIND" = "DOCKER" ]; then

            echo "DOCKER $cf"
            echo "  $CTR:$SOURCE_PATH"

            docker cp \
                "$CTR:$SOURCE_PATH" \
                "$TMP" \
                >/dev/null

        else

            echo "DEVICE $cf"
            echo "  $SOURCE_PATH"

            printf -v QSOURCE '%q' "$SOURCE_PATH"

            ssh "${SSH[@]}" "$DEV" \
                "cat $QSOURCE" \
                > "$TMP"
        fi

        test -s "$TMP"

        test "$(
            sha256sum "$TMP" | awk '{print $1}'
        )" = "$SHA"

        mv -f "$TMP" "$LOCAL"

        echo "  cached=$LOCAL"
    fi

    printf '%d\t%s\t%s\t%s\n' \
        "$LOAD_INDEX" \
        "$cf" \
        "$SHA" \
        "$LOCAL" \
        >> "$OUTDIR/local-content.tsv"

    FOUND_ESM3=$((FOUND_ESM3+1))
    LOAD_INDEX=$((LOAD_INDEX+1))
done

if [ "$FOUND_ESM3" -eq 0 ]; then
    echo "ERROR: zero ESM3 content files found in Docker or on the device."
    exit 30
fi

echo
echo "ESM3 source summary:"

awk -F $'\t' \
    '!/^#/ {printf "  load=%s  %s  sha=%s\n",$1,$2,$3}' \
    "$OUTDIR/local-content.tsv"

echo "PASS: $FOUND_ESM3 active ESM3 content file(s) cached."
echo

echo "===== 3/7 EXTRACT ACTUAL DOOR REFERENCES + CELL LINKS ====="
cat > "$OUTDIR/extract_esm3_door_graph.py" <<'PY_DOORS'
#!/usr/bin/env python3
import csv
import json
import math
import struct
import sys
from pathlib import Path

manifest = Path(sys.argv[1])
out_tsv = Path(sys.argv[2])
out_json = Path(sys.argv[3])

entries = []
with manifest.open(newline='') as f:
    for row in csv.reader(f, delimiter='\t'):
        if row:
            entries.append((int(row[0]), row[1], row[2], Path(row[3])))

def records(path):
    data = path.read_bytes()
    off = 0
    n = len(data)
    while off + 16 <= n:
        typ = data[off:off+4]
        size = struct.unpack_from('<I', data, off+4)[0]
        body = off + 16
        end = body + size
        if end > n:
            break
        yield typ, memoryview(data)[body:end]
        off = end

def subs(body):
    off = 0
    n = len(body)
    while off + 8 <= n:
        typ = bytes(body[off:off+4])
        size = struct.unpack_from('<I', body, off+4)[0]
        pos = off + 8
        end = pos + size
        if end > n:
            break
        yield typ, bytes(body[pos:end])
        off = end

def zstr(b):
    return b.split(b'\0', 1)[0].decode('cp1252', 'replace')

# First pass: identify every DOOR base record and every named interior.
door_ids = set()
interior_names = set()

for load_i, cf, sha, path in entries:
    for typ, body in records(path):
        if typ == b'DOOR':
            rid = None
            deleted = False
            for st, sb in subs(body):
                if st == b'NAME':
                    rid = zstr(sb)
                elif st == b'DELE':
                    deleted = True
            if rid and not deleted:
                door_ids.add(rid.lower())

        elif typ == b'CELL':
            name = ""
            flags = None
            for st, sb in subs(body):
                if st == b'FRMR':
                    break
                if st == b'NAME':
                    name = zstr(sb)
                elif st == b'DATA' and len(sb) >= 12:
                    flags = struct.unpack_from('<i', sb, 0)[0]
            if name and flags is not None and (flags & 1):
                interior_names.add(name.lower())

rows = []

def finish_ref(cell, ref, load_i, cf):
    if ref is None or ref.get('deleted'):
        return
    base = ref.get('base', '')
    if not base or base.lower() not in door_ids:
        return

    src_pos = ref.get('pos')
    dest_pos = ref.get('dest_pos')
    dnam = ref.get('dest_cell', '')
    teleport = dest_pos is not None

    if cell['interior']:
        src_kind = 'interior'
        src_key = 'I:' + cell['name']
    else:
        src_kind = 'exterior'
        src_key = f"E:{cell['x']},{cell['y']}:{cell['name']}"

    dest_kind = 'local'
    dest_key = src_key
    dest_gx = None
    dest_gy = None

    if teleport:
        dx, dy, dz = dest_pos[:3]
        if dnam and dnam.lower() in interior_names:
            dest_kind = 'interior'
            dest_key = 'I:' + dnam
        else:
            dest_kind = 'exterior'
            dest_gx = math.floor(dx / 8192.0)
            dest_gy = math.floor(dy / 8192.0)
            dest_key = f"E:{dest_gx},{dest_gy}:{dnam}"

    rows.append({
        'load_index': load_i,
        'content': cf,
        'source_kind': src_kind,
        'source_key': src_key,
        'source_cell': cell['name'],
        'source_grid_x': cell['x'],
        'source_grid_y': cell['y'],
        'refnum': ref.get('refnum', 0),
        'door_id': base,
        'src_x': None if src_pos is None else src_pos[0],
        'src_y': None if src_pos is None else src_pos[1],
        'src_z': None if src_pos is None else src_pos[2],
        'teleport': 1 if teleport else 0,
        'dest_kind': dest_kind,
        'dest_key': dest_key,
        'dest_cell': dnam,
        'dest_grid_x': dest_gx,
        'dest_grid_y': dest_gy,
        'dest_x': None if dest_pos is None else dest_pos[0],
        'dest_y': None if dest_pos is None else dest_pos[1],
        'dest_z': None if dest_pos is None else dest_pos[2],
        'dest_rx': None if dest_pos is None else dest_pos[3],
        'dest_ry': None if dest_pos is None else dest_pos[4],
        'dest_rz': None if dest_pos is None else dest_pos[5],
    })

# Second pass: placed door refs inside CELL records.
for load_i, cf, sha, path in entries:
    for typ, body in records(path):
        if typ != b'CELL':
            continue

        cell = {'name':'', 'flags':0, 'x':0, 'y':0, 'interior':False}
        ref = None
        in_refs = False

        for st, sb in subs(body):
            if st == b'FRMR':
                finish_ref(cell, ref, load_i, cf)
                in_refs = True
                ref = {
                    'refnum': struct.unpack_from('<I', sb, 0)[0] if len(sb) >= 4 else 0,
                    'base':'',
                    'pos':None,
                    'dest_pos':None,
                    'dest_cell':'',
                    'deleted':False,
                }
                continue

            if not in_refs:
                if st == b'NAME':
                    cell['name'] = zstr(sb)
                elif st == b'DATA' and len(sb) >= 12:
                    flags, x, y = struct.unpack_from('<iii', sb, 0)
                    cell['flags'], cell['x'], cell['y'] = flags, x, y
                    cell['interior'] = bool(flags & 1)
                continue

            if ref is None:
                continue
            if st == b'NAME':
                ref['base'] = zstr(sb)
            elif st == b'DATA' and len(sb) >= 24:
                ref['pos'] = struct.unpack_from('<6f', sb, 0)
            elif st == b'DODT' and len(sb) >= 24:
                ref['dest_pos'] = struct.unpack_from('<6f', sb, 0)
            elif st == b'DNAM':
                ref['dest_cell'] = zstr(sb)
            elif st == b'DELE':
                ref['deleted'] = True

        finish_ref(cell, ref, load_i, cf)

# Collapse exact spatial duplicates, preferring the latest-loaded occurrence.
# Conservative union is intentional for non-identical overrides: a duplicate
# graph edge costs file size, while deleting a legitimate world exit is unsafe.
def q(v):
    if v is None:
        return None
    return round(float(v), 1)

dedup = {}
for r in rows:
    key = (
        r['source_key'],
        r['door_id'].lower(),
        q(r['src_x']), q(r['src_y']), q(r['src_z']),
        r['teleport'],
        r['dest_key'],
        q(r['dest_x']), q(r['dest_y']), q(r['dest_z']),
    )
    prev = dedup.get(key)
    if prev is None or r['load_index'] >= prev['load_index']:
        dedup[key] = r

rows = sorted(
    dedup.values(),
    key=lambda r: (
        r['source_key'].lower(),
        r['door_id'].lower(),
        r['src_x'] or 0,
        r['src_y'] or 0,
        r['src_z'] or 0,
    )
)

fields = [
    'load_index','content','source_kind','source_key','source_cell',
    'source_grid_x','source_grid_y','refnum','door_id',
    'src_x','src_y','src_z','teleport',
    'dest_kind','dest_key','dest_cell','dest_grid_x','dest_grid_y',
    'dest_x','dest_y','dest_z','dest_rx','dest_ry','dest_rz'
]
with out_tsv.open('w', newline='') as f:
    w = csv.DictWriter(
        f, fieldnames=fields, delimiter='\t', lineterminator='\n')
    w.writeheader()
    w.writerows(rows)

summary = {
    'format': 'TSP_GLOBAL_DOOR_GRAPH_V1',
    'content_files': len(entries),
    'known_door_ids': len(door_ids),
    'interior_names': len(interior_names),
    'door_refs': len(rows),
    'teleport_doors': sum(r['teleport'] for r in rows),
    'interior_to_interior': sum(
        1 for r in rows if r['source_kind']=='interior'
        and r['dest_kind']=='interior' and r['teleport']),
    'interior_to_exterior': sum(
        1 for r in rows if r['source_kind']=='interior'
        and r['dest_kind']=='exterior' and r['teleport']),
    'exterior_to_interior': sum(
        1 for r in rows if r['source_kind']=='exterior'
        and r['dest_kind']=='interior' and r['teleport']),
}
out_json.write_text(
    json.dumps({'summary':summary, 'doors':rows},
               indent=2, ensure_ascii=False))
print(json.dumps(summary, indent=2))
PY_DOORS
chmod +x "$OUTDIR/extract_esm3_door_graph.py"

python3 "$OUTDIR/extract_esm3_door_graph.py" \
  "$OUTDIR/local-content.tsv" \
  "$OUTDIR/door_graph.tsv" \
  "$OUTDIR/door_graph.json" | tee "$OUTDIR/door_graph_summary.json"

test -s "$OUTDIR/door_graph.tsv"
echo "PASS: actual door/cell graph extracted."

echo
echo "===== 4/7 GOVERNOR'S HALL REAL-DOOR CHECK ====="
python3 - "$OUTDIR/door_graph.tsv" "$OUTDIR/governors_hall_doors.tsv" <<'PY_GOV'
import csv
import sys

src, dst = sys.argv[1], sys.argv[2]
with open(src, newline='') as f:
    rows = list(csv.DictReader(f, delimiter='\t'))

sel = [
    r for r in rows
    if r['source_cell'].lower() == "caldera, governor's hall"
]

with open(dst, 'w', newline='') as f:
    if rows:
        w = csv.DictWriter(
            f, fieldnames=rows[0].keys(),
            delimiter='\t', lineterminator='\n')
        w.writeheader()
        w.writerows(sel)

print("Governor's Hall real door refs:", len(sel))
print("Teleport/load exits:", sum(int(r['teleport']) for r in sel))
for r in sel:
    if r['teleport'] == '1':
        print(
            "EXIT", r['door_id'],
            "at", r['src_x'], r['src_y'], r['src_z'],
            "->", r['dest_kind'], r['dest_key'])
PY_GOV

echo
echo "===== 5/7 INVENTORY EXISTING NAVMESH.DB WORLDSPACES ====="
NAVDB=""
for candidate in \
  /mnt/UDISK/openmw51-nav/navmesh.db \
  "$ROOT/savegame-0.51/navmesh.db"
do
    if ssh "${SSH[@]}" "$DEV" "test -e '$candidate'"; then
        NAVDB="$candidate"
        break
    fi
done

if [ -n "$NAVDB" ]; then
    echo "Navmesh DB: $NAVDB"
    ssh "${SSH[@]}" "$DEV" \
      "ls -lh '$NAVDB'; readlink -f '$NAVDB' 2>/dev/null || true" \
      > "$OUTDIR/navmesh_db_info.txt"

    if ssh "${SSH[@]}" "$DEV" 'command -v sqlite3 >/dev/null 2>&1'; then
        ssh "${SSH[@]}" "$DEV" "
          sqlite3 -tabs '$NAVDB' '
            SELECT worldspace,
                   COUNT(*) AS tiles,
                   MIN(tile_position_x), MAX(tile_position_x),
                   MIN(tile_position_y), MAX(tile_position_y)
            FROM tiles
            GROUP BY worldspace
            ORDER BY worldspace;
          '
        " > "$OUTDIR/navmesh_worldspaces.tsv"
        echo "PASS: $(wc -l < "$OUTDIR/navmesh_worldspaces.tsv") navmesh worldspaces inventoried."
    else
        echo "WARNING: sqlite3 is not installed on device." \
          | tee "$OUTDIR/navmesh_worldspaces.WARNING.txt"
        echo "The large DB was NOT copied automatically."
    fi
else
    echo "WARNING: persistent navmesh.db not found." \
      | tee "$OUTDIR/navmesh_db.WARNING.txt"
fi

echo
echo "===== 6/7 BUILD GLOBAL LINK SUMMARY ====="
python3 - "$OUTDIR/door_graph.tsv" \
           "$OUTDIR/navmesh_worldspaces.tsv" \
           "$OUTDIR/global_map_summary.txt" <<'PY_SUM'
import csv
import sys
from pathlib import Path

doors = Path(sys.argv[1])
nav = Path(sys.argv[2])
out = Path(sys.argv[3])

with doors.open(newline='') as f:
    rows = list(csv.DictReader(f, delimiter='\t'))

nav_rows = []
if nav.exists():
    for line in nav.read_text(errors='replace').splitlines():
        if line.strip():
            nav_rows.append(line.split('\t'))

src_interiors = {
    r['source_cell'] for r in rows if r['source_kind']=='interior'
}
dst_interiors = {
    r['dest_cell'] for r in rows
    if r['teleport']=='1' and r['dest_kind']=='interior'
}
worldspaces = {r[0] for r in nav_rows if r}

with out.open('w') as f:
    f.write("TSP GLOBAL MAP INDEX V1\n")
    f.write("=======================\n")
    f.write(f"door refs: {len(rows)}\n")
    f.write(f"source interior cells with doors: {len(src_interiors)}\n")
    f.write(f"interior destinations: {len(dst_interiors)}\n")
    f.write(f"navmesh worldspaces in DB: {len(worldspaces)}\n")
    f.write(
        "interior->exterior exits: "
        f"{sum(1 for r in rows if r['source_kind']=='interior' and r['dest_kind']=='exterior' and r['teleport']=='1')}\n")
    f.write(
        "exterior->interior entrances: "
        f"{sum(1 for r in rows if r['source_kind']=='exterior' and r['dest_kind']=='interior' and r['teleport']=='1')}\n")
    f.write("\nARCHITECTURE\n")
    f.write("  Navmesh worldspace -> floors/sectors/stairs/local openings\n")
    f.write("  ESM door graph     -> real doors + cell/worldspace transitions\n")
    f.write("  Merge source door XYZ -> nearest source navmesh sector\n")
    f.write("  Interior target     -> destination cell + nearest destination sector\n")
    f.write("  Exterior target     -> WORLD_EXIT, never interior-PVS culled\n")
    f.write("  Missing topology    -> conservative VISGRID-only fallback\n")
PY_SUM

cat "$OUTDIR/global_map_summary.txt"

echo
echo "===== 7/7 PACKAGE ====="
cp -p "$OUTDIR/extract_esm3_door_graph.py" \
      "$HOME/Downloads/extract_esm3_door_graph.py"
chmod +x "$HOME/Downloads/extract_esm3_door_graph.py"

tar -C "$HOME/Downloads" -czf \
  "$HOME/Downloads/openmw51-global-map-$STAMP.tar.gz" \
  "$(basename "$OUTDIR")"

echo
echo "=================================================================="
echo "GLOBAL MAP INDEX COMPLETE"
echo "=================================================================="
echo "Directory:"
echo "  $OUTDIR"
echo
echo "Most useful files:"
echo "  $OUTDIR/governors_hall_doors.tsv"
echo "  $OUTDIR/door_graph.tsv"
echo "  $OUTDIR/door_graph.json"
echo "  $OUTDIR/navmesh_worldspaces.tsv"
echo "  $OUTDIR/global_map_summary.txt"
echo
echo "Archive:"
echo "  $HOME/Downloads/openmw51-global-map-$STAMP.tar.gz"
echo "=================================================================="
