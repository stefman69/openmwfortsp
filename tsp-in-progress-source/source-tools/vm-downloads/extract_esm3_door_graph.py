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
