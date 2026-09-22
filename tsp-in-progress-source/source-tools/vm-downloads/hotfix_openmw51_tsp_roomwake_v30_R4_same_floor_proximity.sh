#!/usr/bin/env bash
# OpenMW 0.51 TSP — V30 R4 same-floor proximity hotfix
# Lua/profile-only. NO OPENMW REBUILD.

set -u

DL="$HOME/Downloads"
DEV="${TSP_DEVICE:-root@192.168.1.25}"
CTR="${OPENMW_CONTAINER:-openmw_builder}"
ROOT="/mnt/SDCARD/data/ports/openmw51"
BIN="$ROOT/bin/openmw-0.51"
LUA_DIR="$ROOT/mods/TSPInteriorVisGrid/scripts/TSPInteriorVisGrid"
LIVE_LUA="$LUA_DIR/visgrid.lua"
PROFILE="$LUA_DIR/v30_profiles/visgrid-v30-floor-actor-roomwake.lua"
STATE="$DL/openmw51-roomwake-v30-r4-same-floor-proximity.state"
EXPECTED_BIN_SHA="9203cc3dbdd4c0352c2e2db8c09a3ae10241972b5a1bb93c87b3e9f28ff0904d"
STAMP="$(date +%Y%m%d-%H%M%S)"
TMP="$(mktemp -d "$DL/.roomwake-v30-r4.XXXXXX")"

cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

die() {
    code="$1"
    shift
    echo "ERROR: $*" >&2
    exit "$code"
}

need_cmd() {
    name="$1"
    if ! command -v "$name" >/dev/null 2>&1; then
        die 10 "required command missing: $name"
    fi
    echo "PASS command: $name"
}

remote_sha() {
    path="$1"
    ssh "$DEV" bash -s -- "$path" <<'REMOTE_SHA'
P="$1"
if [ ! -f "$P" ]; then
    echo "MISSING"
    exit 0
fi
sha256sum "$P" | awk '{print $1}'
REMOTE_SHA
}

resolve_launcher() {
    ssh "$DEV" bash -s <<'REMOTE_LAUNCHER'
for p in \
  /mnt/SDCARD/Roms/PORTS/Morrowind_51.sh \
  /mnt/sdcard/mmcblk1p1/Roms/PORTS/Morrowind_51.sh \
  /mnt/SDCARD/Emus/PORTS/../../Roms/PORTS/Morrowind_51.sh \
  /mnt/SDCARD/roms/ports/Morrowind_51.sh
do
    if [ -f "$p" ]; then
        readlink -f "$p" 2>/dev/null || printf '%s\n' "$p"
        exit 0
    fi
done
exit 1
REMOTE_LAUNCHER
}

collect_logs() {
    out="$DL/openmw51-roomwake-v30-r4-same-floor-proximity-validation-$(date +%Y%m%d-%H%M%S).txt"
    if ! ssh "$DEV" bash -s -- "$ROOT" >"$out" <<'REMOTE_COLLECT'
ROOT="$1"
for f in "$ROOT/openmw_051_log.txt" "$ROOT/config-0.51/openmw.log" "$ROOT/openmw.log"; do
    if [ -f "$f" ]; then
        tail -n 18000 "$f" |
            grep -E '\[TSP_VISGRID_V30_R4\]|\[TSP_VISGRID_V30_R3\]|\[TSP_VISGRID_V30\]|\[TSP_ROOMOBJ_V30\]|\[TSP_ACTOR_V30\]|BRIDGE ERROR|Bad LiveCellRef cast|failed to render' |
            tail -900
    fi
done
REMOTE_COLLECT
    then
        rm -f "$out"
        die 20 "failed to collect V30 R4 validation log"
    fi
    echo "Saved: $out"
    echo
    tail -100 "$out" 2>/dev/null || true
}

rollback() {
    if [ ! -f "$STATE" ]; then
        die 21 "rollback state missing: $STATE"
    fi
    . "$STATE"
    if [ -z "${DEVICE_BACKUP:-}" ] || [ -z "${LAUNCHER:-}" ]; then
        die 22 "rollback state is incomplete: $STATE"
    fi
    if ! ssh "$DEV" bash -s -- "$DEVICE_BACKUP" "$LIVE_LUA" "$PROFILE" "$LAUNCHER" <<'REMOTE_ROLLBACK'
B="$1"
LIVE="$2"
PROFILE="$3"
LAUNCH="$4"

for f in "$B/visgrid.lua.before" "$B/profile.before" "$B/launcher.before"; do
    if [ ! -f "$f" ]; then
        echo "FAIL rollback backup missing: $f" >&2
        exit 2
    fi
done

install -m 644 "$B/profile.before" "$PROFILE"
install -m 644 "$B/visgrid.lua.before" "$LIVE"
install -m 755 "$B/launcher.before" "$LAUNCH"
sync

if grep -Fq 'TSP_VISGRID_LUA_V30_R4_SAME_FLOOR_PROXIMITY' "$LIVE"; then
    echo "FAIL R4 marker survived rollback in live Lua" >&2
    exit 3
fi
if ! grep -Fq 'TSP_VISGRID_LUA_V30_R3_OPEN_SPACE_CLUSTER' "$LIVE"; then
    echo "FAIL rollback did not restore R3 baseline" >&2
    exit 4
fi

echo "PASS V30 R4 rollback restored prior R3 profile/live Lua/launcher"
REMOTE_ROLLBACK
    then
        die 23 "V30 R4 rollback failed"
    fi
    echo "Rollback complete."
}

case "${1:-install}" in
    collect)
        need_cmd ssh
        collect_logs
        exit 0
        ;;
    rollback)
        need_cmd ssh
        rollback
        exit 0
        ;;
    install) ;;
    *) die 2 "usage: $0 [install|collect|rollback]" ;;
esac

echo "============================================================"
echo "OPENMW 0.51 — V30 R4 SAME-FLOOR PROXIMITY HOTFIX"
echo "============================================================"
echo "NO OPENMW REBUILD."
echo "Fix target: disconnected navmesh islands inside one visual room."
echo "Current sector remains authoritative, plus at most TWO nearby"
echo "same-floor ordinary fragments selected by physical AABB distance."
echo "Known real-door edges remain barriers; other floors remain hard-off."
echo "============================================================"

need_cmd ssh
need_cmd scp
need_cmd python3
need_cmd sha256sum
need_cmd docker

if ! docker inspect "$CTR" >/dev/null 2>&1; then
    die 29 "Docker container not found: $CTR"
fi
if ! ssh -o BatchMode=yes -o ConnectTimeout=8 "$DEV" true; then
    die 30 "SSH failed: $DEV"
fi
echo "PASS SSH: $DEV"

LAUNCHER="$(resolve_launcher)" || die 31 "could not resolve Morrowind_51.sh on device"
if [ -z "$LAUNCHER" ]; then die 32 "resolved launcher path is empty"; fi
echo "PASS launcher: $LAUNCHER"

echo
echo "===== 1/5 VERIFY INSTALLED R3 BASELINE ====="

BIN_SHA="$(remote_sha "$BIN")" || die 33 "failed to hash installed V30 binary"
if [ "$BIN_SHA" != "$EXPECTED_BIN_SHA" ]; then
    echo "EXPECTED: $EXPECTED_BIN_SHA" >&2
    echo "GOT:      $BIN_SHA" >&2
    die 34 "installed binary is not the proven V30 actor/floor build"
fi
echo "PASS exact V30 binary SHA: $BIN_SHA"

if ! ssh "$DEV" bash -s -- "$LIVE_LUA" "$PROFILE" "$LAUNCHER" <<'REMOTE_VERIFY'
LIVE="$1"
PROFILE="$2"
LAUNCH="$3"

for f in "$LIVE" "$PROFILE" "$LAUNCH"; do
    if [ ! -f "$f" ]; then
        echo "FAIL required file missing: $f" >&2
        exit 2
    fi
done

for f in "$LIVE" "$PROFILE"; do
    if ! grep -Fq 'TSP_VISGRID_LUA_V30_FLOOR_ACTOR_ROOMWAKE' "$f"; then
        echo "FAIL V30 marker missing: $f" >&2
        exit 3
    fi
    if ! grep -Fq 'TSP_VISGRID_LUA_V30_R3_OPEN_SPACE_CLUSTER' "$f"; then
        echo "FAIL R3 baseline marker missing: $f" >&2
        exit 4
    fi
    if grep -Fq 'TSP_VISGRID_LUA_V30_R4_SAME_FLOOR_PROXIMITY' "$f"; then
        echo "FAIL R4 marker already present; refusing ambiguous reapplication: $f" >&2
        exit 5
    fi
    if grep -Fq 'setInteriorClutterResidency' "$f"; then
        echo "FAIL dead V28 clutter bridge found: $f" >&2
        exit 6
    fi
done

if ! grep -Fq 'v30_profiles/visgrid-v30-floor-actor-roomwake.lua' "$LAUNCH"; then
    echo "FAIL launcher does not select the V30 profile: $LAUNCH" >&2
    exit 7
fi

echo "PASS working V30 R3 Lua/profile/launcher baseline"
REMOTE_VERIFY
then
    die 35 "device R3 baseline verification failed"
fi

echo
echo "===== 2/5 BACKUP + PULL CURRENT R3 LUA ====="

DEVICE_BACKUP="$ROOT/backups/roomwake-v30-r4-same-floor-proximity-$STAMP"

if ! ssh "$DEV" bash -s -- "$DEVICE_BACKUP" "$LIVE_LUA" "$PROFILE" "$LAUNCHER" <<'REMOTE_BACKUP'
B="$1"
LIVE="$2"
PROFILE="$3"
LAUNCH="$4"

if ! mkdir -p "$B"; then
    echo "FAIL could not create backup directory: $B" >&2
    exit 2
fi
if ! install -m 644 "$LIVE" "$B/visgrid.lua.before"; then
    echo "FAIL backup live Lua: $LIVE" >&2
    exit 3
fi
if ! install -m 644 "$PROFILE" "$B/profile.before"; then
    echo "FAIL backup profile: $PROFILE" >&2
    exit 4
fi
if ! install -m 755 "$LAUNCH" "$B/launcher.before"; then
    echo "FAIL backup launcher: $LAUNCH" >&2
    exit 5
fi
sha256sum "$B/visgrid.lua.before" "$B/profile.before" "$B/launcher.before"
REMOTE_BACKUP
then
    die 40 "device backup failed"
fi

if ! scp -q "$DEV:$PROFILE" "$TMP/visgrid.v30.r3.lua"; then
    die 41 "failed to pull current R3 profile"
fi
echo "PASS pulled current R3 profile"

cat > "$STATE" <<EOF_STATE
DEVICE_BACKUP='$DEVICE_BACKUP'
LAUNCHER='$LAUNCHER'
EOF_STATE
echo "PASS rollback state: $STATE"

echo
echo "===== 3/5 GENERATE R4 SAME-FLOOR PROXIMITY LUA ====="

cat > "$TMP/r4_payload.lua" <<'LUA_R4'
-- TSP_VISGRID_LUA_V30_R4_SAME_FLOOR_PROXIMITY
-- R3's portal graph is insufficient when one visible room is split into
-- disconnected navmesh islands. Keep a bounded number of physically nearby
-- same-floor ordinary sectors active even when there is no topology edge.
print('[TSP_VISGRID_V30_R4] SAME-FLOOR-PROXIMITY near-fragments=2 floor-hardoff=1 door-barrier=1')

mapState.v30R4LastSignature = ''

mapState.v30R4NearRange = function(kind)
    kind = tostring(kind or 'room')
    if kind == 'large_open' then return 760.0 end
    if kind == 'corridor' then return 680.0 end
    if kind == 'small_room' then return 520.0 end
    return 600.0
end

mapState.v30R4AabbDistance = function(sec, x, y)
    local b = sec and sec.bbox or nil
    if b == nil or #b < 6 then return math.huge end
    local xmin = tonumber(b[1] or 0) or 0
    local ymin = tonumber(b[2] or 0) or 0
    local xmax = tonumber(b[4] or xmin) or xmin
    local ymax = tonumber(b[5] or ymin) or ymin
    local dx = 0.0
    local dy = 0.0
    if x < xmin then dx = xmin - x elseif x > xmax then dx = x - xmax end
    if y < ymin then dy = ymin - y elseif y > ymax then dy = y - ymax end
    return math.sqrt(dx*dx + dy*dy)
end

mapState.v30R4DirectDoorBarrier = function(seen, sid)
    local tc = mapState.topoCell
    local sectors = tc and tc.sectors or nil
    local portals = tc and tc.portals or nil
    local sec = sectors and sectors[sid] or nil
    if sec == nil or sec.portals == nil or portals == nil then return false end
    for i = 1, #sec.portals do
        local pid = tonumber(sec.portals[i] or 0) or 0
        local p = portals[pid]
        if p ~= nil and tostring(p.kind or 'boundary') == 'door' then
            local a = tonumber(p.a or 0) or 0
            local b = tonumber(p.b or 0) or 0
            local other = 0
            if a == sid then other = b elseif b == sid then other = a end
            if other > 0 and seen[other] then return true end
        end
    end
    return false
end

mapState.v30R4AddNearbyFragments = function(ids, seen, playerFloor, x, y, currentKind)
    local tc = mapState.topoCell
    local sectors = tc and tc.sectors or nil
    local candidates = {}
    local detail = {}
    if sectors == nil or playerFloor == nil then return detail end

    local limit = mapState.v30R4NearRange(currentKind)
    for sid, sec in pairs(sectors) do
        sid = tonumber(sid or 0) or 0
        if sid > 0 and sec ~= nil and not seen[sid] then
            local kind = tostring(sec.kind or 'room')
            local floorId = tonumber(sec.floor)
            if kind ~= 'vertical_connector' and floorId ~= nil and floorId == playerFloor
                and not mapState.v30R4DirectDoorBarrier(seen, sid) then
                local d = mapState.v30R4AabbDistance(sec, x, y)
                if d <= limit then
                    candidates[#candidates + 1] = { id=sid, d=d, kind=kind }
                end
            end
        end
    end

    table.sort(candidates, function(a, b)
        if a.d ~= b.d then return a.d < b.d end
        return a.id < b.id
    end)

    local n = math.min(2, #candidates)
    for i = 1, n do
        local c = candidates[i]
        if not seen[c.id] then
            seen[c.id] = true
            ids[#ids + 1] = c.id
            detail[#detail + 1] = string.format('%d@%.0f:%s', c.id, c.d, c.kind)
        end
    end
    return detail
end

mapState.v30R4AttachNearbyConnectors = function(ids, seen, x, y)
    local tc = mapState.topoCell
    local sectors = tc and tc.sectors or nil
    local portals = tc and tc.portals or nil
    if sectors == nil or portals == nil then return {} end

    local candidates = {}
    local candidateSeen = {}
    for i = 1, #ids do
        local sid = ids[i]
        local sec = sectors[sid]
        if sec ~= nil and tostring(sec.kind or 'room') ~= 'vertical_connector'
            and sec.portals ~= nil then
            for j = 1, #sec.portals do
                local pid = tonumber(sec.portals[j] or 0) or 0
                local p = portals[pid]
                if p ~= nil and tostring(p.kind or 'boundary') == 'boundary' then
                    local a = tonumber(p.a or 0) or 0
                    local b = tonumber(p.b or 0) or 0
                    local other = 0
                    if a == sid then other = b elseif b == sid then other = a end
                    local target = other > 0 and sectors[other] or nil
                    if target ~= nil and not seen[other] and not candidateSeen[other]
                        and tostring(target.kind or 'room') == 'vertical_connector' then
                        local d = mapState.v30R4AabbDistance(target, x, y)
                        if d <= 360.0 then
                            candidateSeen[other] = true
                            candidates[#candidates + 1] = { id=other, d=d }
                        end
                    end
                end
            end
        end
    end

    table.sort(candidates, function(a, b)
        if a.d ~= b.d then return a.d < b.d end
        return a.id < b.id
    end)

    local detail = {}
    local n = math.min(2, #candidates)
    for i = 1, n do
        local c = candidates[i]
        if not seen[c.id] then
            seen[c.id] = true
            ids[#ids + 1] = c.id
            detail[#detail + 1] = string.format('%d@%.0f', c.id, c.d)
        end
    end
    return detail
end

mapState.updateTopologyPvs = function(force)
    if not mapState.pvsBridge or mapState.topoCell == nil or mapState.pvsBoxes == nil then
        if mapState.pvsBridge then pcall(camera.clearInteriorTopologyPvs) end
        mapState.pvsSignature = nil
        mapState.pvsActiveCount = 0
        return
    end

    local current = tonumber(mapState.topoSectorId or 0) or 0
    local sectors = mapState.topoCell.sectors
    local portals = mapState.topoCell.portals
    local sec = current > 0 and sectors[current] or nil
    if current <= 0 or sec == nil then
        pcall(camera.clearInteriorTopologyPvs)
        mapState.pvsSignature = nil
        mapState.pvsActiveCount = 0
        if force or mapState.v30LastLine ~= 'r4-unmapped' then
            mapState.v30LastLine = 'r4-unmapped'
            print(string.format('[TSP_VISGRID_V30_R4] UNMAPPED current=%d total=%d',
                current, tonumber(mapState.pvsSectorCount or 0) or 0))
        end
        return
    end

    local cc = sec.center or {0,0,0}
    local x = tonumber(mapState.topoX or cc[1] or 0) or 0
    local y = tonumber(mapState.topoY or cc[2] or 0) or 0
    local z = tonumber(mapState.topoZ or cc[3] or 0) or 0
    local currentKind = tostring(sec.kind or 'room')
    local playerFloor = mapState.v30InferFloor(x, y, z, sec)
    local ids, seen, openCount, connectorCount =
        mapState.v30R3BuildOpenCluster(current, playerFloor)

    local nearDetail = {}
    local nearConnectorDetail = {}
    if currentKind ~= 'vertical_connector' then
        nearDetail = mapState.v30R4AddNearbyFragments(
            ids, seen, playerFloor, x, y, currentKind)
        nearConnectorDetail = mapState.v30R4AttachNearbyConnectors(ids, seen, x, y)
    end

    local candidates = {}
    local candidateSeen = {}
    local scanIds = {}

    if currentKind == 'vertical_connector' then
        scanIds[1] = current
    else
        for i = 1, #ids do
            local sid = ids[i]
            local s = sectors[sid]
            if s ~= nil and tostring(s.kind or 'room') ~= 'vertical_connector' then
                scanIds[#scanIds + 1] = sid
            end
        end
    end

    for si = 1, #scanIds do
        local sid = scanIds[si]
        local src = sectors[sid]
        if src ~= nil and src.portals ~= nil and portals ~= nil then
            for i = 1, #src.portals do
                local pid = tonumber(src.portals[i] or 0) or 0
                local p = portals[pid]
                if p ~= nil and p.center ~= nil then
                    local a = tonumber(p.a or 0) or 0
                    local b = tonumber(p.b or 0) or 0
                    local other = 0
                    if a == sid then other = b elseif b == sid then other = a end

                    local target = other > 0 and sectors[other] or nil
                    if target ~= nil and not seen[other] and not candidateSeen[other] then
                        local targetKind = tostring(target.kind or 'room')
                        local targetFloor = tonumber(target.floor)
                        local pkind = tostring(p.kind or 'boundary')
                        local allowed = false

                        if currentKind == 'vertical_connector' then
                            allowed = targetKind == 'vertical_connector'
                                or (playerFloor ~= nil and targetFloor ~= nil
                                    and targetFloor == playerFloor)
                        else
                            allowed = pkind == 'door'
                                and (targetKind == 'vertical_connector'
                                    or (playerFloor ~= nil and targetFloor ~= nil
                                        and targetFloor == playerFloor))
                        end

                        if allowed then
                            local px = tonumber(p.center[1] or 0) or 0
                            local py = tonumber(p.center[2] or 0) or 0
                            local pz = tonumber(p.center[3] or 0) or 0
                            local dx, dy, dz = px-x, py-y, pz-z
                            local d = math.sqrt(dx*dx + dy*dy + dz*dz)
                            local limit = mapState.v30WakeRange(currentKind, targetKind, pkind)
                            if d <= limit then
                                candidateSeen[other] = true
                                candidates[#candidates + 1] = {
                                    id=other, d=d, limit=limit, portal=pid,
                                    pkind=pkind, tkind=targetKind, floor=targetFloor,
                                }
                            end
                        end
                    end
                end
            end
        end
    end

    table.sort(candidates, function(a,b)
        if a.d ~= b.d then return a.d < b.d end
        return a.id < b.id
    end)

    local maxExtra = mapState.v30MaxExtra(currentKind)
    local doorDetail = {}
    local n = math.min(maxExtra, #candidates)
    for i = 1, n do
        local c = candidates[i]
        if not seen[c.id] then
            seen[c.id] = true
            ids[#ids + 1] = c.id
            doorDetail[#doorDetail + 1] = string.format('%d@%.0f/%.0f:%s:f%s',
                c.id, c.d, c.limit, tostring(c.pkind), tostring(c.floor or '?'))
        end
    end

    table.sort(ids)
    local signature = 'v30r4:f' .. tostring(playerFloor or '?')
        .. ':o' .. tostring(openCount)
        .. ':n' .. table.concat(nearDetail, '|')
        .. ':c' .. table.concat(nearConnectorDetail, '|')
        .. ':' .. table.concat(ids, ',')

    if force or signature ~= mapState.pvsSignature then
        local ok, err = pcall(camera.setInteriorTopologyPvs,
            mapState.pvsBoxes, ids, 0.0, 0.0)
        if ok then
            mapState.pvsSignature = signature
            mapState.pvsActiveCount = #ids
            if force or signature ~= mapState.v30R4LastSignature then
                mapState.v30R4LastSignature = signature
                local ns = #nearDetail > 0 and table.concat(nearDetail, ',') or '-'
                local cs = #nearConnectorDetail > 0 and table.concat(nearConnectorDetail, ',') or '-'
                local ds = #doorDetail > 0 and table.concat(doorDetail, ',') or '-'
                print(string.format(
                    '[TSP_VISGRID_V30_R4] current=%d/%d kind=%s floor=%s open=%d near=%s nearConn=%s active=%d ids=%s doorWake=%s',
                    current, tonumber(mapState.pvsSectorCount or 0) or 0,
                    currentKind, tostring(playerFloor or '?'), openCount,
                    ns, cs, #ids, table.concat(ids, ','), ds))
            end
        else
            print('[TSP_VISGRID_V30_R4] BRIDGE ERROR: ' .. tostring(err))
            pcall(camera.clearInteriorTopologyPvs)
            mapState.pvsSignature = nil
            mapState.pvsActiveCount = 0
        end
    end
end

LUA_R4

cat > "$TMP/patch_r4.py" <<'PY_PATCH'
#!/usr/bin/env python3
import sys

src, dst, payload_path = sys.argv[1:4]
with open(src, 'r', encoding='utf-8', newline='') as f:
    s = f.read()
with open(payload_path, 'r', encoding='utf-8', newline='') as f:
    payload = f.read()

required = (
    'TSP_VISGRID_LUA_V30_FLOOR_ACTOR_ROOMWAKE',
    'TSP_VISGRID_LUA_V30_R3_OPEN_SPACE_CLUSTER',
    'mapState.v30R3BuildOpenCluster',
    'mapState.v30InferFloor',
    'mapState.v30WakeRange',
    'mapState.v30MaxExtra',
    'mapState.v30BaseOnFrame = ',
    'camera.setInteriorTopologyPvs',
)
for token in required:
    if token not in s:
        raise RuntimeError('R3 profile missing required token: ' + token)

mark = 'TSP_VISGRID_LUA_V30_R4_SAME_FLOOR_PROXIMITY'
if mark in s:
    raise RuntimeError('R4 marker already present; refusing reapplication')
if 'setInteriorClutterResidency' in s:
    raise RuntimeError('dead V28 clutter bridge present in R3 baseline')
if mark not in payload:
    raise RuntimeError('R4 payload marker missing')

anchor = 'mapState.v30BaseOnFrame = '
if s.count(anchor) != 1:
    candidates = [line for line in s.splitlines() if 'v30BaseOnFrame' in line]
    raise RuntimeError(
        'V30 frame-wrapper anchor count=%d, expected 1; candidates=%r'
        % (s.count(anchor), candidates[-20:])
    )

pos = s.index(anchor)
s = s[:pos] + payload + s[pos:]

for token in (
    mark,
    'mapState.v30R4AddNearbyFragments',
    'mapState.v30R4AabbDistance',
    'math.min(2, #candidates)',
    'floorId == playerFloor',
    'mapState.v30R4DirectDoorBarrier',
    'mapState.pvsBoxes, ids, 0.0, 0.0',
    '[TSP_VISGRID_V30_R4] current=',
):
    if token not in s:
        raise RuntimeError('R4 postcondition missing: ' + token)

with open(dst, 'w', encoding='utf-8', newline='\n') as f:
    f.write(s)

print('PASS: V30 R4 same-floor proximity profile generated.')
print('PASS: disconnected same-floor islands may contribute at most two nearby ordinary fragments.')
print('PASS: explicit direct door edges remain barriers to proximity merging.')
print('PASS: other floors remain excluded from proximity merging.')
PY_PATCH

if ! python3 -m py_compile "$TMP/patch_r4.py"; then
    die 50 "embedded R4 patcher does not compile under host Python"
fi
if ! python3 "$TMP/patch_r4.py" \
    "$TMP/visgrid.v30.r3.lua" "$TMP/visgrid.v30.r4.lua" "$TMP/r4_payload.lua"
then
    die 51 "R4 Lua transformation failed"
fi

PARSER=""
for x in texlua lua luajit; do
    if command -v "$x" >/dev/null 2>&1; then
        PARSER="$x"
        break
    fi
done

if [ -n "$PARSER" ]; then
    cat > "$TMP/check.lua" <<'LUA_CHECK'
local f,e=loadfile(arg[1])
if not f then error(e) end
print('LUA_PARSE_PASS ' .. arg[1])
LUA_CHECK
    if ! "$PARSER" "$TMP/check.lua" "$TMP/visgrid.v30.r4.lua"; then
        die 52 "generated R4 Lua failed host parser: $PARSER"
    fi
    echo "PASS generated R4 Lua syntax: host $PARSER"
else
    if ! docker cp "$TMP/visgrid.v30.r4.lua" "$CTR:/tmp/visgrid.v30.r4.lua" >/dev/null; then
        die 53 "failed to stage generated R4 Lua in Docker for syntax validation"
    fi
    DOCKER_PARSER="$(docker exec "$CTR" bash -lc 'for x in luajit texlua lua; do if command -v "$x" >/dev/null 2>&1; then echo "$x"; exit 0; fi; done; exit 1' 2>/dev/null || true)"
    if [ -n "$DOCKER_PARSER" ]; then
        if ! docker exec "$CTR" "$DOCKER_PARSER" -e 'local f,e=loadfile(arg[1]); assert(f,e); print("LUA_PARSE_PASS " .. arg[1])' /tmp/visgrid.v30.r4.lua; then
            die 54 "generated R4 Lua failed Docker CLI parser: $DOCKER_PARSER"
        fi
        echo "PASS generated R4 Lua syntax: Docker $DOCKER_PARSER"
    else
        echo "INFO: no Lua CLI executable; compiling syntax checker against installed LuaJIT library."
        if ! docker exec -i "$CTR" bash -s <<'REMOTE_LUA_CHECK'
HEADER="$(find /usr/include /usr/local/include -type f -name lua.h -path '*luajit*' -print 2>/dev/null | head -1)"
if [ -z "$HEADER" ]; then echo "FAIL LuaJIT lua.h not found" >&2; exit 1; fi
INC="$(dirname "$HEADER")"
LIB="$(find /usr/lib /usr/local/lib \( -type f -o -type l \) -name 'libluajit-5.1.so*' -print 2>/dev/null | head -1)"
if [ -z "$LIB" ]; then echo "FAIL libluajit-5.1.so not found" >&2; exit 2; fi
CC=""
for c in gcc-13 gcc cc; do
    if command -v "$c" >/dev/null 2>&1; then CC="$c"; break; fi
done
if [ -z "$CC" ]; then echo "FAIL no C compiler for LuaJIT syntax checker" >&2; exit 3; fi
cat > /tmp/v30_r4_lua_check.c <<'C_CHECK'
#include <stdio.h>
#include <lua.h>
#include <lauxlib.h>
int main(int argc, char **argv) {
    lua_State *L;
    int rc;
    if (argc != 2) return 2;
    L = luaL_newstate();
    if (!L) return 3;
    rc = luaL_loadfile(L, argv[1]);
    if (rc != 0) {
        const char *msg = lua_tostring(L, -1);
        fprintf(stderr, "LUA_PARSE_FAIL: %s\n", msg ? msg : "unknown");
        lua_close(L);
        return 4;
    }
    lua_close(L);
    printf("LUA_PARSE_PASS %s\n", argv[1]);
    return 0;
}
C_CHECK
if ! "$CC" -O2 -I"$INC" /tmp/v30_r4_lua_check.c "$LIB" -lm -ldl -pthread -o /tmp/v30_r4_lua_check; then
    echo "FAIL compiling LuaJIT syntax checker" >&2
    exit 4
fi
if ! /tmp/v30_r4_lua_check /tmp/visgrid.v30.r4.lua; then exit 5; fi
echo "PASS generated R4 Lua syntax via compiled LuaJIT checker"
REMOTE_LUA_CHECK
        then
            die 55 "generated R4 Lua could not be validated"
        fi
    fi
    docker exec "$CTR" rm -f /tmp/visgrid.v30.r4.lua /tmp/v30_r4_lua_check /tmp/v30_r4_lua_check.c >/dev/null 2>&1 || true
fi

R4_SHA="$(sha256sum "$TMP/visgrid.v30.r4.lua" | awk '{print $1}')"
echo "V30 R4 Lua SHA: $R4_SHA"

for token in \
  TSP_VISGRID_LUA_V30_R4_SAME_FLOOR_PROXIMITY \
  mapState.v30R4AddNearbyFragments \
  mapState.v30R4DirectDoorBarrier \
  'floorId == playerFloor' \
  'math.min(2, #candidates)' \
  'mapState.pvsBoxes, ids, 0.0, 0.0'
do
    if ! grep -Fq -- "$token" "$TMP/visgrid.v30.r4.lua"; then
        die 56 "generated R4 Lua missing required token: $token"
    fi
done
echo "PASS generated R4 structural postconditions"

echo
echo "===== 4/5 STAGE + INSTALL LUA-ONLY R4 ====="

REMOTE_TMP="/tmp/visgrid-v30-r4-same-floor-proximity.lua"
if ! scp -q "$TMP/visgrid.v30.r4.lua" "$DEV:$REMOTE_TMP"; then
    die 60 "failed to upload staged R4 Lua"
fi

if ! ssh "$DEV" bash -s -- \
    "$REMOTE_TMP" "$R4_SHA" "$PROFILE" "$LIVE_LUA" "$LAUNCHER" "$BIN" "$EXPECTED_BIN_SHA" <<'REMOTE_INSTALL'
TMP_LUA="$1"
EXPECTED_LUA="$2"
PROFILE="$3"
LIVE="$4"
LAUNCH="$5"
BIN="$6"
EXPECTED_BIN="$7"

sha() { sha256sum "$1" | awk '{print $1}'; }

if [ ! -f "$TMP_LUA" ]; then echo "FAIL staged R4 Lua missing: $TMP_LUA" >&2; exit 2; fi
GOT="$(sha "$TMP_LUA")"
if [ "$GOT" != "$EXPECTED_LUA" ]; then
    echo "FAIL staged R4 Lua SHA expected=$EXPECTED_LUA actual=$GOT" >&2
    exit 3
fi
BIN_SHA="$(sha "$BIN")"
if [ "$BIN_SHA" != "$EXPECTED_BIN" ]; then
    echo "FAIL V30 binary changed before R4 install expected=$EXPECTED_BIN actual=$BIN_SHA" >&2
    exit 4
fi

install -m 644 "$TMP_LUA" "$PROFILE"
install -m 644 "$TMP_LUA" "$LIVE"
rm -f "$TMP_LUA"
sync

for f in "$PROFILE" "$LIVE"; do
    GOT="$(sha "$f")"
    if [ "$GOT" != "$EXPECTED_LUA" ]; then
        echo "FAIL installed R4 Lua SHA mismatch: $f expected=$EXPECTED_LUA actual=$GOT" >&2
        exit 5
    fi
    if ! grep -Fq 'TSP_VISGRID_LUA_V30_R4_SAME_FLOOR_PROXIMITY' "$f"; then
        echo "FAIL installed R4 marker missing: $f" >&2
        exit 6
    fi
    if ! grep -Fq 'TSP_VISGRID_LUA_V30_R3_OPEN_SPACE_CLUSTER' "$f"; then
        echo "FAIL underlying R3 marker missing after R4 install: $f" >&2
        exit 7
    fi
    if grep -Fq 'setInteriorClutterResidency' "$f"; then
        echo "FAIL dead V28 clutter bridge found after R4 install: $f" >&2
        exit 8
    fi
done
if ! grep -Fq 'v30_profiles/visgrid-v30-floor-actor-roomwake.lua' "$LAUNCH"; then
    echo "FAIL launcher V30 profile selection changed unexpectedly: $LAUNCH" >&2
    exit 9
fi

echo "PASS installed V30 R4 profile/live Lua"
echo "PASS V30 actor/floor binary unchanged"
REMOTE_INSTALL
then
    echo
    echo "INSTALL FAILED — restoring previous R3 Lua/profile/launcher..."
    rollback || true
    die 61 "V30 R4 install/verification failed"
fi

echo
echo "===== 5/5 FINAL VERIFY ====="

FINAL_BIN_SHA="$(remote_sha "$BIN")" || die 70 "failed final binary hash"
FINAL_LUA_SHA="$(remote_sha "$LIVE_LUA")" || die 71 "failed final live Lua hash"
if [ "$FINAL_BIN_SHA" != "$EXPECTED_BIN_SHA" ]; then die 72 "final binary SHA changed unexpectedly: $FINAL_BIN_SHA"; fi
if [ "$FINAL_LUA_SHA" != "$R4_SHA" ]; then die 73 "final live Lua SHA mismatch: $FINAL_LUA_SHA"; fi

echo "PASS final V30 binary SHA unchanged: $FINAL_BIN_SHA"
echo "PASS final V30 R4 Lua SHA: $FINAL_LUA_SHA"

echo
echo "============================================================"
echo "V30 R4 SAME-FLOOR PROXIMITY INSTALLED — NO REBUILD"
echo "============================================================"
echo "Test the exact 14 -> 13 -> 11 open-room path once."
echo "R4 should show near=<sector@distance> before you cross islands."
echo "Objects should no longer collapse to resident=0 in sector 14."
echo
echo "Collect:"
echo "  cd ~/Downloads"
echo "  ./hotfix_openmw51_tsp_roomwake_v30_R4_same_floor_proximity.sh collect"
echo
echo "Rollback:"
echo "  ./hotfix_openmw51_tsp_roomwake_v30_R4_same_floor_proximity.sh rollback"
echo "============================================================"
