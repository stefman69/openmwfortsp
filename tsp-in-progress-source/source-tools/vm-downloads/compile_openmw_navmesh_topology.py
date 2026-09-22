#!/usr/bin/env python3
"""
OpenMW / Detour MSET -> compact VISGRID topology compiler.

Dependency-free. Parses OpenMW's built-in all_tiles_navmesh.bin debug dump.
The output is a Lua data module. It is deliberately a TOPOLOGY HINT, never a
render-distance clamp.

Coordinate conversion for this OpenMW 0.51 build:
    nav.x = world.x * recast_scale
    nav.y = world.z * recast_scale
    nav.z = -world.y * recast_scale

The scale is inferred from dtMeshHeader.walkableHeight against OpenMW's
canonical actor-height constant. For this captured build it resolves to 34
world units per navmesh unit.
"""
from __future__ import annotations
import argparse
import collections
import math
import struct
from pathlib import Path

MSET_MAGIC = (ord('M') << 24) | (ord('S') << 16) | (ord('E') << 8) | ord('T')
DNAV_MAGIC = (ord('D') << 24) | (ord('N') << 16) | (ord('A') << 8) | ord('V')
GROUND_AREA = 63
DOOR_AREA = 2
PATHGRID_AREA = 3
NAV_POLY_TYPE_GROUND = 0
NAV_POLY_TYPE_OFFMESH = 1

def read_mset(path: Path):
    b = path.read_bytes()
    off = 0
    magic, version, num_tiles = struct.unpack_from("<iii", b, off)
    off += 12
    if magic != MSET_MAGIC:
        raise SystemExit(f"ERROR: not Detour MSET magic: 0x{magic:08x}")
    if version != 1:
        raise SystemExit(f"ERROR: unsupported MSET version {version}")
    params = struct.unpack_from("<5f2i", b, off)
    off += 28

    tiles = []
    for _ in range(num_tiles):
        tile_ref, size = struct.unpack_from("<II", b, off)
        off += 8
        tb = b[off:off+size]
        off += size
        if len(tb) != size:
            raise SystemExit("ERROR: truncated tile")
        hdr_i = struct.unpack_from("<15i", tb, 0)
        hdr_f = struct.unpack_from("<10f", tb, 60)
        if hdr_i[0] != DNAV_MAGIC:
            raise SystemExit(f"ERROR: bad DNAV magic 0x{hdr_i[0]:08x}")
        tiles.append(parse_tile(tile_ref, tb, hdr_i, hdr_f))
    if off != len(b):
        raise SystemExit(f"ERROR: trailing bytes: parsed={off} total={len(b)}")
    return params, tiles

def parse_tile(tile_ref, tb, hi, hf):
    (magic, version, tx, ty, layer, user_id, poly_count, vert_count,
     max_link_count, detail_mesh_count, detail_vert_count, detail_tri_count,
     bv_node_count, offmesh_count, offmesh_base) = hi

    off = 100
    verts = [struct.unpack_from("<3f", tb, off+i*12) for i in range(vert_count)]
    off += vert_count * 12

    polys = []
    for i in range(poly_count):
        base = off + i*32
        pv = struct.unpack_from("<6H", tb, base+4)
        neis = struct.unpack_from("<6H", tb, base+16)
        flags = struct.unpack_from("<H", tb, base+28)[0]
        vc = tb[base+30]
        at = tb[base+31]
        polys.append({
            "verts": pv[:vc],
            "neis": neis[:vc],
            "flags": flags,
            "count": vc,
            "area": at & 0x3f,
            "type": at >> 6,
        })
    off += poly_count * 32

    # dtLink = 12; dtPolyDetail = 12; detail vert = 12;
    # detail tri = 4; dtBVNode = 16; dtOffMeshConnection = 36.
    off += max_link_count * 12
    off += detail_mesh_count * 12
    off += detail_vert_count * 12
    off += detail_tri_count * 4
    off += bv_node_count * 16

    offmesh = []
    for i in range(offmesh_count):
        base = off + i*36
        pos = struct.unpack_from("<6f", tb, base)
        rad = struct.unpack_from("<f", tb, base+24)[0]
        poly = struct.unpack_from("<H", tb, base+28)[0]
        flags = tb[base+30]
        side = tb[base+31]
        uid = struct.unpack_from("<I", tb, base+32)[0]
        offmesh.append({
            "pos": pos, "rad": rad, "poly": poly,
            "flags": flags, "side": side, "uid": uid,
        })
    off += offmesh_count * 36

    if off != len(tb):
        raise SystemExit(
            f"ERROR: tile ({tx},{ty}) structure mismatch: parsed={off} bytes={len(tb)}"
        )

    return {
        "ref": tile_ref, "x": tx, "y": ty, "layer": layer,
        "verts": verts, "polys": polys, "offmesh": offmesh,
        "offmesh_base": offmesh_base,
        "walkable_height": hf[0],
        "walkable_radius": hf[1],
        "walkable_climb": hf[2],
        "bmin": hf[3:6], "bmax": hf[6:9],
    }

def qv(v):
    return tuple(round(x, 4) for x in v)

def area_xz(coords):
    s = 0.0
    for i, a in enumerate(coords):
        b = coords[(i+1) % len(coords)]
        s += a[0] * b[2] - b[0] * a[2]
    return abs(s) * 0.5

def detect_scale(tiles):
    # OpenMW's player navigation height in this build yields exactly 133 world
    # units / 3.9117646 nav units = 34. This also matches the known recast
    # scale factor 1/34. Use nearest integer only when the ratio is very close.
    h = next(t["walkable_height"] for t in tiles if t["walkable_height"] > 0)
    estimate = 133.0 / h
    rounded = round(estimate)
    if abs(estimate - rounded) < 0.05 and 16 <= rounded <= 128:
        return float(rounded)
    return 34.0

def nav_to_world(v, scale):
    return (v[0]*scale, -v[2]*scale, v[1]*scale)

def build_ground(tiles):
    ground = []
    for ti, t in enumerate(tiles):
        for pi, p in enumerate(t["polys"]):
            if p["type"] != NAV_POLY_TYPE_GROUND or p["area"] != GROUND_AREA:
                continue
            coords = [t["verts"][vi] for vi in p["verts"]]
            c = tuple(sum(v[k] for v in coords)/len(coords) for k in range(3))
            ground.append({
                "ti": ti, "pi": pi, "coords": coords, "c": c,
                "yrange": max(v[1] for v in coords)-min(v[1] for v in coords),
            })
    return ground

def build_adjacency(ground):
    edges = collections.defaultdict(list)
    for gi, p in enumerate(ground):
        c = p["coords"]
        for i in range(len(c)):
            a, b = qv(c[i]), qv(c[(i+1) % len(c)])
            edges[tuple(sorted((a,b)))].append(gi)
    adj = [set() for _ in ground]
    for members in edges.values():
        if len(members) >= 2:
            for a in members:
                for b in members:
                    if a != b:
                        adj[a].add(b)
    return adj

def find_floor_peaks(ground):
    hist = collections.Counter(round(p["c"][1]*2.0)/2.0 for p in ground)
    min_support = max(10, round(len(ground)*0.03))
    cands = [(n, y) for y, n in hist.items() if n >= min_support]
    cands.sort(reverse=True)
    peaks = []
    for n, y in cands:
        if all(abs(y-z) >= 3.0 for z in peaks):
            peaks.append(y)
    peaks.sort()
    if not peaks:
        peaks = [round(sum(p["c"][1] for p in ground)/len(ground)*2)/2]
    return peaks, hist

def components(nodes, adj):
    nodes = set(nodes)
    seen = set()
    out = []
    for start in sorted(nodes):
        if start in seen:
            continue
        seen.add(start)
        stack = [start]
        comp = []
        while stack:
            u = stack.pop()
            comp.append(u)
            for v in adj[u]:
                if v in nodes and v not in seen:
                    seen.add(v)
                    stack.append(v)
        out.append(comp)
    return out

def make_sectors(ground, adj, peaks, scale):
    # A polygon belongs to a plateau when its centroid is close to a strong
    # height mode. Everything between plateaus becomes a vertical connector.
    assign = {}
    for i,p in enumerate(ground):
        nearest = min(range(len(peaks)), key=lambda k: abs(p["c"][1]-peaks[k]))
        dist = abs(p["c"][1]-peaks[nearest])
        if dist <= 2.0:
            assign[i] = ("floor", nearest)
        else:
            assign[i] = ("connector", -1)

    raw = []
    for fi in range(len(peaks)):
        ns = [i for i,a in assign.items() if a == ("floor", fi)]
        for comp in components(ns, adj):
            raw.append({"kind0":"floor", "floor":fi, "polys":comp})
    ns = [i for i,a in assign.items() if a[0] == "connector"]
    for comp in components(ns, adj):
        raw.append({"kind0":"connector", "floor":-1, "polys":comp})

    # Tiny islands inherit the nearest adjacent larger sector where possible.
    poly_to_raw = {}
    for si,s in enumerate(raw):
        for p in s["polys"]:
            poly_to_raw[p] = si
    for si,s in enumerate(raw):
        if len(s["polys"]) >= 3:
            continue
        votes = collections.Counter()
        for p in s["polys"]:
            for q in adj[p]:
                sj = poly_to_raw.get(q)
                if sj is not None and sj != si and len(raw[sj]["polys"]) >= 3:
                    votes[sj] += 1
        if votes:
            target = votes.most_common(1)[0][0]
            raw[target]["polys"].extend(s["polys"])
            s["polys"] = []

    raw = [s for s in raw if s["polys"]]
    poly_to_sector = {}
    sectors = []
    for sid0,s in enumerate(raw, start=1):
        ps = [ground[i] for i in s["polys"]]
        world_pts = [nav_to_world(v, scale) for p in ps for v in p["coords"]]
        xs=[v[0] for v in world_pts]; ys=[v[1] for v in world_pts]; zs=[v[2] for v in world_pts]
        area = sum(area_xz(p["coords"]) for p in ps) * scale * scale
        bx=max(xs)-min(xs); by=max(ys)-min(ys)
        bbox_area=max(1.0,bx*by)
        aspect=max(bx,by)/max(1.0,min(bx,by))
        fill=area/bbox_area
        zspan=max(zs)-min(zs)

        if s["kind0"] == "connector" or zspan > 150:
            kind="vertical_connector"
        elif area >= 180000:
            kind="large_open"
        elif aspect >= 3.2 and fill < 0.45:
            kind="corridor"
        elif area < 45000:
            kind="small_room"
        else:
            kind="room"

        cxs=[]; cys=[]; czs=[]
        for p in ps:
            wc=nav_to_world(p["c"],scale)
            cxs.append(wc[0]); cys.append(wc[1]); czs.append(wc[2])

        sector={
            "id":sid0, "floor":s["floor"]+1 if s["floor"]>=0 else 0,
            "kind":kind, "poly_count":len(ps), "area":round(area),
            "bbox":[round(min(xs),1),round(min(ys),1),round(min(zs),1),
                    round(max(xs),1),round(max(ys),1),round(max(zs),1)],
            "center":[round(sum(cxs)/len(cxs),1),round(sum(cys)/len(cys),1),round(sum(czs)/len(czs),1)],
            "neighbors":set(), "portals":[],
            "_polys":list(s["polys"]),
        }
        sectors.append(sector)
        for gi in s["polys"]:
            poly_to_sector[gi]=sid0

    # structural adjacency across polygon edges
    for a in range(len(ground)):
        sa=poly_to_sector.get(a)
        if sa is None: continue
        for b in adj[a]:
            sb=poly_to_sector.get(b)
            if sb is not None and sb != sa:
                sectors[sa-1]["neighbors"].add(sb)
                sectors[sb-1]["neighbors"].add(sa)

    return sectors, poly_to_sector

def nearest_ground_sector(pt, ground, poly_to_sector):
    best=(float("inf"),None)
    for gi,p in enumerate(ground):
        sid=poly_to_sector.get(gi)
        if sid is None: continue
        c=p["c"]
        d=(c[0]-pt[0])**2+(c[1]-pt[1])**2+(c[2]-pt[2])**2
        if d<best[0]:
            best=(d,sid)
    return best[1]

def make_portals(tiles, ground, poly_to_sector, scale):
    raw=[]
    for t in tiles:
        for om in t["offmesh"]:
            poly=t["polys"][om["poly"]]
            if poly["type"] != NAV_POLY_TYPE_OFFMESH:
                continue
            # Runtime visual topology uses explicit doors only. Pathgrid
            # off-mesh links are AI-routing hints, not guaranteed sight portals.
            if poly["area"] != DOOR_AREA:
                continue
            p=om["pos"]
            a=(p[0],p[1],p[2]); b=(p[3],p[4],p[5])
            raw.append((poly["area"],a,b))

    # Deduplicate the bidirectional copies by rounded unordered endpoints.
    uniq={}
    for area,a,b in raw:
        ka=tuple(round(x,3) for x in a)
        kb=tuple(round(x,3) for x in b)
        key=(area,tuple(sorted((ka,kb))))
        uniq[key]=(area,a,b)

    portals=[]
    for pid,(area,a,b) in enumerate(uniq.values(),start=1):
        sa=nearest_ground_sector(a,ground,poly_to_sector)
        sb=nearest_ground_sector(b,ground,poly_to_sector)
        wa=nav_to_world(a,scale); wb=nav_to_world(b,scale)
        center=tuple((wa[i]+wb[i])*0.5 for i in range(3))
        portals.append({
            "id":pid,
            "kind":"door" if area==DOOR_AREA else "pathgrid",
            "a_sector":sa or 0, "b_sector":sb or 0,
            "a":[round(x,1) for x in wa], "b":[round(x,1) for x in wb],
            "center":[round(x,1) for x in center],
        })
    return portals


def make_boundary_portals(ground, adj, poly_to_sector, scale, start_id):
    """Create portal hints at shared edges that cross our sector partition."""
    groups = collections.defaultdict(list)
    seen = set()
    for a in range(len(ground)):
        sa = poly_to_sector.get(a)
        if sa is None:
            continue
        ca = ground[a]["coords"]
        edges_a = {}
        for i in range(len(ca)):
            va, vb = qv(ca[i]), qv(ca[(i+1)%len(ca)])
            edges_a[tuple(sorted((va,vb)))] = (ca[i], ca[(i+1)%len(ca)])
        for b in adj[a]:
            if b <= a:
                continue
            sb = poly_to_sector.get(b)
            if sb is None or sb == sa:
                continue
            cb = ground[b]["coords"]
            edges_b = {}
            for i in range(len(cb)):
                va, vb = qv(cb[i]), qv(cb[(i+1)%len(cb)])
                edges_b[tuple(sorted((va,vb)))] = (cb[i], cb[(i+1)%len(cb)])
            common = set(edges_a).intersection(edges_b)
            for key in common:
                va,vb = edges_a[key]
                mid = tuple((va[k]+vb[k])*0.5 for k in range(3))
                groups[tuple(sorted((sa,sb)))].append(mid)

    portals=[]
    pid=start_id
    for (sa,sb), mids in sorted(groups.items()):
        # Average all neighboring shared-edge midpoints into one coarse portal
        # hint between the two sectors.
        m=tuple(sum(v[k] for v in mids)/len(mids) for k in range(3))
        w=nav_to_world(m,scale)
        portals.append({
            "id":pid, "kind":"boundary",
            "a_sector":sa, "b_sector":sb,
            "a":[round(x,1) for x in w], "b":[round(x,1) for x in w],
            "center":[round(x,1) for x in w],
        })
        pid += 1
    return portals

def build_buckets(ground, poly_to_sector, scale, bucket=384):
    buckets=collections.defaultdict(list)
    for gi,p in enumerate(ground):
        sid=poly_to_sector.get(gi)
        if sid is None: continue
        w=nav_to_world(p["c"],scale)
        bx=math.floor(w[0]/bucket); by=math.floor(w[1]/bucket); bz=math.floor(w[2]/bucket)
        buckets[f"{bx},{by},{bz}"].append((round(w[0],1),round(w[1],1),round(w[2],1),sid))
    return buckets

def emit_lua(cell, source_sha, scale, peaks, sectors, portals, buckets, out_path):
    for s in sectors:
        s["neighbors"]=sorted(s["neighbors"])
    for p in portals:
        for sid in (p["a_sector"],p["b_sector"]):
            if sid and p["id"] not in sectors[sid-1]["portals"]:
                sectors[sid-1]["portals"].append(p["id"])

    def q(s):
        return '"' + s.replace("\\","\\\\").replace('"','\\"') + '"'
    lines=[]
    lines.append("-- TSP_VISGRID_TOPOLOGY_V1")
    lines.append("-- Generated from OpenMW live Detour all_tiles_navmesh.bin.")
    lines.append("-- TOPOLOGY HINT ONLY: never a hard render-distance clamp.")
    lines.append("local T = {")
    lines.append("  version = 1,")
    lines.append(f"  source_sha256 = {q(source_sha)},")
    lines.append(f"  world_per_nav = {scale:.6f},")
    lines.append("  bucket_size = 384,")
    lines.append("  cells = {")
    lines.append(f"    [{q(cell)}] = {{")
    lines.append("      floors = {" + ",".join(f"{p*scale:.1f}" for p in peaks) + "},")
    lines.append("      sectors = {")
    for s in sectors:
        b=s["bbox"]; c=s["center"]
        neigh="{" + ",".join(map(str,s["neighbors"])) + "}"
        ports="{" + ",".join(map(str,s["portals"])) + "}"
        lines.append(
            f"        [{s['id']}] = {{ id={s['id']}, floor={s['floor']}, kind={q(s['kind'])}, "
            f"area={s['area']}, polys={s['poly_count']}, "
            f"bbox={{{','.join(map(str,b))}}}, center={{{','.join(map(str,c))}}}, "
            f"neighbors={neigh}, portals={ports} }},"
        )
    lines.append("      },")
    lines.append("      portals = {")
    for p in portals:
        c=p["center"]
        lines.append(
            f"        [{p['id']}] = {{ id={p['id']}, kind={q(p['kind'])}, "
            f"a={p['a_sector']}, b={p['b_sector']}, center={{{','.join(map(str,c))}}} }},"
        )
    lines.append("      },")
    lines.append("      buckets = {")
    for key in sorted(buckets):
        samples=",".join(
            "{" + ",".join(map(str,s)) + "}" for s in buckets[key]
        )
        lines.append(f"        [{q(key)}] = {{{samples}}},")
    lines.append("      },")
    lines.append("    },")
    lines.append("  },")
    lines.append("}")
    lines.extend(r"""
function T.findSector(cellName, x, y, z)
    local tc = T.cells[cellName]
    if tc == nil then return nil, nil end
    local bs = T.bucket_size or 384
    local bx, by, bz = math.floor(x / bs), math.floor(y / bs), math.floor(z / bs)
    local bestSid, bestD2 = nil, 1.0e30

    for dzb = -1, 1 do
        for dyb = -1, 1 do
            for dxb = -1, 1 do
                local key = tostring(bx + dxb) .. ',' .. tostring(by + dyb)
                    .. ',' .. tostring(bz + dzb)
                local samples = tc.buckets[key]
                if samples ~= nil then
                    for i = 1, #samples do
                        local q = samples[i]
                        local dx, dy, dz = x - q[1], y - q[2], z - q[3]
                        local d2 = dx * dx + dy * dy + dz * dz
                        if d2 < bestD2 then
                            bestD2 = d2
                            bestSid = q[4]
                        end
                    end
                end
            end
        end
    end

    if bestSid == nil then
        for sid, sec in pairs(tc.sectors) do
            local b = sec.bbox
            local zPad = (sec.kind == 'vertical_connector') and 220.0 or 120.0
            if x >= b[1] - 220 and x <= b[4] + 220
                and y >= b[2] - 220 and y <= b[5] + 220
                and z >= b[3] - zPad and z <= b[6] + zPad then
                local c = sec.center
                local dx, dy, dz = x - c[1], y - c[2], z - c[3]
                local d2 = dx * dx + dy * dy + dz * dz
                if d2 < bestD2 then
                    bestD2 = d2
                    bestSid = sid
                end
            end
        end
    end

    return bestSid, bestSid ~= nil and tc.sectors[bestSid] or nil
end

function T.cacheKey(cellName, sectorId)
    if sectorId ~= nil and sectorId > 0 then
        return tostring(cellName) .. '#topo' .. tostring(sectorId)
    end
    return cellName
end

function T.getCell(cellName)
    return T.cells[cellName]
end

return T
""".strip("\n").splitlines())
    out_path.write_text("\n".join(lines)+"\n")

def main():
    ap=argparse.ArgumentParser()
    ap.add_argument("navmesh")
    ap.add_argument("--cell", default="Caldera, Governor's Hall")
    ap.add_argument("--output", required=True)
    args=ap.parse_args()

    path=Path(args.navmesh)
    import hashlib
    sha=hashlib.sha256(path.read_bytes()).hexdigest()
    params,tiles=read_mset(path)
    scale=detect_scale(tiles)
    ground=build_ground(tiles)
    adj=build_adjacency(ground)
    peaks,hist=find_floor_peaks(ground)
    sectors,p2s=make_sectors(ground,adj,peaks,scale)
    portals=make_portals(tiles,ground,p2s,scale)
    portals.extend(make_boundary_portals(
        ground, adj, p2s, scale,
        1 + max([p["id"] for p in portals], default=0)))
    buckets=build_buckets(ground,p2s,scale)

    # Attach adjacency via portals.
    for p in portals:
        a,b=p["a_sector"],p["b_sector"]
        if a and b and a!=b:
            sectors[a-1]["neighbors"].add(b)
            sectors[b-1]["neighbors"].add(a)

    out=Path(args.output)
    emit_lua(args.cell,sha,scale,peaks,sectors,portals,buckets,out)

    door=sum(1 for p in portals if p["kind"]=="door")
    pathgrid=0
    print(f"PASS: {len(tiles)} tiles; {len(ground)} ground polygons")
    print(f"floors/plateaus: {len(peaks)} -> " + ", ".join(f"{p*scale:.1f}" for p in peaks))
    print(f"sectors: {len(sectors)}")
    for s in sectors:
        print(f"  S{s['id']:02d} floor={s['floor']} kind={s['kind']:<18} "
              f"polys={s['poly_count']:3d} area={s['area']:7d} "
              f"neighbors={sorted(s['neighbors'])}")
    print(f"portals: {len(portals)} ({door} door, {pathgrid} pathgrid)")
    print(f"output: {out}")

if __name__ == "__main__":
    main()
