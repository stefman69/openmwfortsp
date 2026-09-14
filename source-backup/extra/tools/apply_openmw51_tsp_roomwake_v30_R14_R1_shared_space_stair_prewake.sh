#!/usr/bin/env bash
# OpenMW 0.51 / TrimUI Smart Pro
# V30 R14-R1: widen proven giant shared-space topology authority and add a
# connector-bounded staircase transition prewake.
#
# LUA/PROFILE ONLY. No C++ source edit, rebuild, binary replacement, or launcher.
# Exact R13 input is discovered from the state written by the R13 controller,
# then verified against both live Lua copies before any mutation.
#
# Actions: install (default), collect, rollback, selftest

set -u -o pipefail

ACTION="${1:-install}"
CTR="${OPENMW_CONTAINER:-openmw_builder}"
DEV="${TSP_DEVICE:-root@192.168.1.12}"
ROOT="/mnt/SDCARD/data/ports/openmw51"
BIN="$ROOT/bin/openmw-0.51"
LUA="$ROOT/mods/TSPInteriorVisGrid/scripts/TSPInteriorVisGrid/visgrid.lua"
PROFILE="$ROOT/mods/TSPInteriorVisGrid/scripts/TSPInteriorVisGrid/v30_profiles/visgrid-v30-floor-actor-roomwake.lua"
GAMELOG="$ROOT/openmw_051_log.txt"
PERF="$ROOT/openmw51_perf_latest.txt"
ARM="$ROOT/roomwake-r14-capture-start.line"
EXPECTED_BIN_SHA="e25f6edfe90c6610be94b285a243d7d2b673a7412ac504a026f14976332a3fab"

DL="${OPENMW_DOWNLOADS_DIR:-$HOME/Downloads}"
R13_STATE="$DL/openmw51-roomwake-r13.state"
R14_STATE="$DL/openmw51-roomwake-r14.state"
STAMP="$(date +%Y%m%d-%H%M%S)"
RUNLOG="$DL/openmw51-roomwake-r14-$STAMP.log"
[ -d "$DL" ] || { echo "ERROR: downloads directory missing: $DL" >&2; exit 9; }
TMP="$(mktemp -d "$DL/.roomwake-r14.XXXXXX")" \
    || { echo "ERROR: could not create R14 temporary directory" >&2; exit 9; }
[ -n "$TMP" ] && [ -d "$TMP" ] \
    || { echo "ERROR: invalid R14 temporary directory" >&2; exit 9; }
DEVICE_BACKUP=""

cleanup() {
    if [ -n "$TMP" ] && [ -d "$TMP" ]; then rm -rf "$TMP"; fi
}
trap cleanup EXIT

fail() {
    local rc="${1:-1}"
    shift || true
    echo "ERROR: $*" >&2
    exit "$rc"
}

need() {
    command -v "$1" >/dev/null 2>&1 || fail 10 "required command missing: $1"
    echo "PASS command: $1"
}

ensure_ssh() {
    need ssh
    need scp
    ssh -o BatchMode=yes -o ConnectTimeout=8 "$DEV" true >/dev/null 2>&1 \
        || fail 11 "SSH failed: $DEV"
    echo "PASS SSH: $DEV"
}

remote_sha() {
    ssh "$DEV" 'bash -s' -- "$1" <<'REMOTE_SHA' 2>/dev/null || true
P="$1"
if [ -f "$P" ]; then sha256sum "$P" | awk '{print $1}'; fi
REMOTE_SHA
}

state_value() {
    local file="$1" key="$2"
    sed -n "s/^${key}='\([^']*\)'$/\1/p" "$file" | tail -n 1
}

valid_sha() {
    case "$1" in
        *[!0-9a-f]*|'') return 1 ;;
    esac
    [ "${#1}" -eq 64 ]
}

make_patcher() {
cat > "$TMP/patch_r14.py" <<'PY_R14'
from pathlib import Path
import sys

MARK13 = 'TSP_ROOMRAY_LUA_V30_R13_GIANT_SHARED_SPACE'
MARK14 = 'TSP_ROOMRAY_LUA_V30_R14_SHARED_SPACE_STAIR_PREWAKE'

INSERT_ANCHOR = 'mapState.r13BaseAuthorityReport = mapState.r11AuthorityReport'
START13 = "print('[TSP_ROOMRAY_R13] enabled giant=up+forward+nav crossFloorMax=12 sealedSnap=10 giantRelease=20')"
START14 = START13 + "\nprint('[TSP_ROOMRAY_R14] enabled sharedMax=20 sameFloor=bounded stair=connector+signedZ stairMax=8')"

R14 = r'''-- TSP_ROOMRAY_LUA_V30_R14_SHARED_SPACE_STAIR_PREWAKE
-- R14 does not cast another ray and does not enlarge ordinary/tight modes.
-- Giant mode broadens only the topology authority already proven by R13.
-- Stair mode is driven by signed player-Z travel near a navmesh
-- vertical_connector, then admits only boundary-linked connector endpoints and
-- one boundary-linked landing neighbor. Door portals are never traversed.
mapState.r14GiantMaxExtra = 20
mapState.r14GiantXYRadius = 2400.0
mapState.r14GiantCrossGap = 720.0
mapState.r14GiantSameGap = 360.0
mapState.r14StairMaxExtra = 8
mapState.r14StairConnectorRange = 520.0
mapState.r14StairLandingRange = 1650.0
mapState.r14StairTravelEnter = 24.0
mapState.r14StairTravelRefresh = 8.0
mapState.r14StairHoldSamples = 15
mapState.r14StairActive = false
mapState.r14StairDirection = 0
mapState.r14StairHold = 0
mapState.r14ZHistory = {}
mapState.r14PvsOverrideApplied = false
mapState.r14PvsSignature = nil
mapState.r14SharedExtra = 0
mapState.r14StairExtra = 0
mapState.r14ConnectorIds = {}

mapState.r14R13ResetSpaceAuthority = mapState.r13ResetSpaceAuthority
mapState.r13ResetSpaceAuthority = function()
    mapState.r14R13ResetSpaceAuthority()
    mapState.r14StairActive = false
    mapState.r14StairDirection = 0
    mapState.r14StairHold = 0
    mapState.r14ZHistory = {}
    mapState.r14PvsSignature = nil
    mapState.r14SharedExtra = 0
    mapState.r14StairExtra = 0
    mapState.r14ConnectorIds = {}
    -- Preserve this bit until updateTopologyPvs restores the exact R13 mask.
end

mapState.r14CopyBaseIds = function()
    local ids, seen = {}, {}
    for i = 1, #(mapState.r13BasePvsIds or {}) do
        local sid = tonumber(mapState.r13BasePvsIds[i] or 0) or 0
        if sid > 0 and not seen[sid] then
            seen[sid] = true
            ids[#ids + 1] = sid
        end
    end
    local current = tonumber(mapState.topoSectorId or 0) or 0
    if current > 0 and not seen[current] then
        seen[current] = true
        ids[#ids + 1] = current
    end
    return ids, seen
end

mapState.r14PortalOther = function(p, sid)
    if p == nil then return 0 end
    local a = tonumber(p.a or 0) or 0
    local b = tonumber(p.b or 0) or 0
    if a == sid then return b end
    if b == sid then return a end
    return 0
end

mapState.r14NearbyConnectors = function(x, y)
    local tc = mapState.topoCell
    local sectors = tc and tc.sectors or nil
    if sectors == nil then return {} end
    local out, seen = {}, {}
    local function consider(sid)
        sid = tonumber(sid or 0) or 0
        local sec = sid > 0 and sectors[sid] or nil
        if sec ~= nil and not seen[sid]
            and tostring(sec.kind or 'room') == 'vertical_connector' then
            local d = mapState.v30R4AabbDistance(sec, x, y)
            if d <= mapState.r14StairConnectorRange then
                seen[sid] = true
                out[#out + 1] = {id=sid, d=d}
            end
        end
    end
    consider(mapState.topoSectorId)
    for i = 1, #(mapState.r13BasePvsIds or {}) do
        consider(mapState.r13BasePvsIds[i])
    end
    table.sort(out, function(a, b)
        if a.d ~= b.d then return a.d < b.d end
        return a.id < b.id
    end)
    local ids = {}
    for i = 1, math.min(2, #out) do ids[#ids + 1] = out[i].id end
    return ids
end

mapState.r14ObserveStair = function(distances, kind)
    local z = tonumber(mapState.topoZ)
    local x = tonumber(mapState.topoX)
    local y = tonumber(mapState.topoY)
    if z == nil or x == nil or y == nil or mapState.topoCell == nil then
        return
    end

    local hist = mapState.r14ZHistory or {}
    hist[#hist + 1] = z
    while #hist > 7 do table.remove(hist, 1) end
    mapState.r14ZHistory = hist
    local travel = #hist >= 2 and (z - hist[1]) or 0.0
    local connectors = mapState.r14NearbyConnectors(x, y)
    mapState.r14ConnectorIds = connectors
    local onConnector = tostring(kind or '') == 'vertical_connector'
    local nearConnector = #connectors > 0
    local moving = math.abs(travel) >= mapState.r14StairTravelEnter

    if not mapState.r14StairActive and nearConnector and moving then
        mapState.r14StairActive = true
        mapState.r14StairDirection = travel > 0.0 and 1 or -1
        mapState.r14StairHold = mapState.r14StairHoldSamples
        mapState.r14PvsSignature = nil
        print(string.format(
            '[TSP_ROOMRAY_R14] STAIR-ENTER direction=%s travel=%.0f topo=%s connectors=%s',
            mapState.r14StairDirection > 0 and 'up' or 'down', travel,
            tostring(kind or '?'), table.concat(connectors, ',')))
        mapState.updateTopologyPvs(true)
        return
    end

    if mapState.r14StairActive then
        if nearConnector and (onConnector
            or math.abs(travel) >= mapState.r14StairTravelRefresh) then
            if math.abs(travel) >= mapState.r14StairTravelRefresh then
                mapState.r14StairDirection = travel > 0.0 and 1 or -1
            end
            mapState.r14StairHold = mapState.r14StairHoldSamples
        else
            mapState.r14StairHold = math.max(0, mapState.r14StairHold - 1)
        end
        if mapState.r14StairHold <= 0 then
            mapState.r14StairActive = false
            mapState.r14StairDirection = 0
            mapState.r14ConnectorIds = {}
            mapState.r14PvsSignature = nil
            print('[TSP_ROOMRAY_R14] STAIR-EXIT reason=connector-hold-expired')
            mapState.updateTopologyPvs(true)
        end
    end
end

mapState.r14AddGiant = function(ids, seen, sectors, currentSec,
    playerFloor, x, y)
    local candidates = {}
    local currentKind = tostring(currentSec.kind or 'room')
    for sid, target in pairs(sectors) do
        sid = tonumber(sid or 0) or 0
        if sid > 0 and target ~= nil and not seen[sid]
            and not mapState.v30R4DirectDoorBarrier(seen, sid) then
            local targetFloor = tonumber(target.floor)
            local targetKind = tostring(target.kind or 'room')
            local cross = playerFloor ~= nil and targetFloor ~= nil
                and targetFloor ~= playerFloor
            local connector = targetKind == 'vertical_connector'
            local d = mapState.v30R4AabbDistance(target, x, y)
            local gap = mapState.r13AabbXYGap(currentSec, target)
            local sameShared = not cross and not connector
                and (currentKind == 'large_open' or targetKind == 'large_open'
                    or gap <= mapState.r14GiantSameGap)
            local crossShared = cross and gap <= mapState.r14GiantCrossGap
            if d <= mapState.r14GiantXYRadius
                and (connector or sameShared or crossShared) then
                candidates[#candidates + 1] = {
                    id=sid, d=d, gap=gap, cross=cross and 1 or 0,
                    connector=connector and 1 or 0,
                }
            end
        end
    end
    table.sort(candidates, function(a, b)
        if a.connector ~= b.connector then return a.connector > b.connector end
        if a.d ~= b.d then return a.d < b.d end
        if a.gap ~= b.gap then return a.gap < b.gap end
        return a.id < b.id
    end)
    local n = math.min(mapState.r14GiantMaxExtra, #candidates)
    for i = 1, n do
        local sid = candidates[i].id
        if not seen[sid] then
            seen[sid] = true
            ids[#ids + 1] = sid
        end
    end
    return n
end

mapState.r14AddStair = function(ids, seen, sectors, portals, x, y, z)
    local candidates, candidateSeen = {}, {}
    local direction = tonumber(mapState.r14StairDirection or 0) or 0
    local connectors = mapState.r14ConnectorIds or {}

    local function addCandidate(sid, depth, source)
        sid = tonumber(sid or 0) or 0
        local target = sid > 0 and sectors[sid] or nil
        if target == nil or seen[sid] or candidateSeen[sid] then return end
        local d = mapState.v30R4AabbDistance(target, x, y)
        if d > mapState.r14StairLandingRange then return end
        local cc = target.center or {x, y, z}
        local dz = (tonumber(cc[3] or z) or z) - z
        local wrong = direction ~= 0 and dz * direction < -96.0
        candidateSeen[sid] = true
        candidates[#candidates + 1] = {
            id=sid, d=d, dz=dz, depth=depth, source=source,
            wrong=wrong and 1 or 0,
        }
    end

    -- Connector sectors themselves plus all non-door endpoint sectors. Both
    -- endpoints are cheap and prevent a pause/reversal from producing a pop.
    for i = 1, #connectors do
        local cid = tonumber(connectors[i] or 0) or 0
        local csec = cid > 0 and sectors[cid] or nil
        if csec ~= nil then
            if not seen[cid] then
                seen[cid] = true
                ids[#ids + 1] = cid
            end
            for j = 1, #(csec.portals or {}) do
                local pid = tonumber(csec.portals[j] or 0) or 0
                local p = portals and portals[pid] or nil
                if p ~= nil and tostring(p.kind or 'boundary') == 'boundary' then
                    addCandidate(mapState.r14PortalOther(p, cid), 0, cid)
                end
            end
        end
    end

    table.sort(candidates, function(a, b)
        if a.wrong ~= b.wrong then return a.wrong < b.wrong end
        if a.depth ~= b.depth then return a.depth < b.depth end
        if a.d ~= b.d then return a.d < b.d end
        return a.id < b.id
    end)

    local landingIds = {}
    local firstN = math.min(4, #candidates)
    for i = 1, firstN do
        local c = candidates[i]
        if not seen[c.id] then
            seen[c.id] = true
            ids[#ids + 1] = c.id
            landingIds[#landingIds + 1] = c.id
        end
    end

    -- One boundary-only hop beyond each landing. A door is a hard stop.
    for i = 1, #landingIds do
        local sid = landingIds[i]
        local sec = sectors[sid]
        for j = 1, #(sec and sec.portals or {}) do
            local pid = tonumber(sec.portals[j] or 0) or 0
            local p = portals and portals[pid] or nil
            if p ~= nil and tostring(p.kind or 'boundary') == 'boundary' then
                addCandidate(mapState.r14PortalOther(p, sid), 1, sid)
            end
        end
    end

    table.sort(candidates, function(a, b)
        if a.wrong ~= b.wrong then return a.wrong < b.wrong end
        if a.depth ~= b.depth then return a.depth < b.depth end
        if a.d ~= b.d then return a.d < b.d end
        return a.id < b.id
    end)
    local added = #landingIds
    for i = 1, #candidates do
        if added >= mapState.r14StairMaxExtra then break end
        local c = candidates[i]
        if not seen[c.id] then
            seen[c.id] = true
            ids[#ids + 1] = c.id
            added = added + 1
        end
    end
    return added
end

mapState.r14R13UpdateTopologyPvs = mapState.updateTopologyPvs
mapState.updateTopologyPvs = function(force)
    local restoring = mapState.r14PvsOverrideApplied
        and not mapState.r13GiantActive and not mapState.r14StairActive
    mapState.r14R13UpdateTopologyPvs(force or restoring)

    local cell = self.cell
    local giant = mapState.r13GiantActive and mapState.r13GiantCell == cell
    local stair = mapState.r14StairActive
    if not giant and not stair then
        mapState.r14PvsOverrideApplied = false
        mapState.r14PvsSignature = nil
        mapState.r14SharedExtra = 0
        mapState.r14StairExtra = 0
        return
    end

    local tc = mapState.topoCell
    local sectors = tc and tc.sectors or nil
    local portals = tc and tc.portals or nil
    local current = tonumber(mapState.topoSectorId or 0) or 0
    local currentSec = sectors and current > 0 and sectors[current] or nil
    if currentSec == nil or mapState.pvsBoxes == nil then return end

    local cc = currentSec.center or {0, 0, 0}
    local x = tonumber(mapState.topoX or cc[1] or 0) or 0
    local y = tonumber(mapState.topoY or cc[2] or 0) or 0
    local z = tonumber(mapState.topoZ or cc[3] or 0) or 0
    local playerFloor = mapState.v30InferFloor(x, y, z, currentSec)
    local ids, seen = mapState.r14CopyBaseIds()
    local sharedExtra, stairExtra = 0, 0
    if giant then
        sharedExtra = mapState.r14AddGiant(
            ids, seen, sectors, currentSec, playerFloor, x, y)
    end
    if stair then
        stairExtra = mapState.r14AddStair(ids, seen, sectors, portals, x, y, z)
    end
    table.sort(ids)

    local signature = tostring(mapState.pvsSignature or '?')
        .. ':r14:g' .. (giant and '1' or '0')
        .. ':s' .. (stair and tostring(mapState.r14StairDirection) or '0')
        .. ':c' .. tostring(current)
        .. ':q' .. tostring(math.floor(x / 128.0))
        .. ',' .. tostring(math.floor(y / 128.0))
        .. ':' .. table.concat(ids, ',')
    if force or signature ~= mapState.r14PvsSignature then
        local ok, err = pcall(camera.setInteriorTopologyPvs,
            mapState.pvsBoxes, ids, 0.0, 0.0)
        if ok then
            mapState.r14PvsOverrideApplied = true
            mapState.r14PvsSignature = signature
            mapState.r14SharedExtra = sharedExtra
            mapState.r14StairExtra = stairExtra
            mapState.pvsActiveCount = #ids
            print(string.format(
                '[TSP_ROOMRAY_R14] PVS giant=%d stair=%d direction=%d shared=%d landing=%d active=%d ids=%s',
                giant and 1 or 0, stair and 1 or 0,
                tonumber(mapState.r14StairDirection or 0) or 0,
                sharedExtra, stairExtra, #ids, table.concat(ids, ',')))
        else
            print('[TSP_ROOMRAY_R14] PVS ERROR ' .. tostring(err))
        end
    end
end

mapState.r14R13ObserveSpace = mapState.r13ObserveSpace
mapState.r13ObserveSpace = function(distances, kind)
    local action = mapState.r14R13ObserveSpace(distances, kind)
    mapState.r14ObserveStair(distances, kind)
    return action
end

mapState.r14BaseAuthorityReport = mapState.r11AuthorityReport
mapState.r11AuthorityReport = function(distances)
    mapState.r14BaseAuthorityReport(distances)
    print(string.format(
        '[TSP_ROOMRAY_R14] state giant=%d stair=%d direction=%d hold=%d shared=%d landing=%d connectors=%s',
        mapState.r13GiantActive and 1 or 0,
        mapState.r14StairActive and 1 or 0,
        tonumber(mapState.r14StairDirection or 0) or 0,
        tonumber(mapState.r14StairHold or 0) or 0,
        tonumber(mapState.r14SharedExtra or 0) or 0,
        tonumber(mapState.r14StairExtra or 0) or 0,
        table.concat(mapState.r14ConnectorIds or {}, ',')))
end'''

def replace_once(src, old, new, label):
    count = src.count(old)
    if count != 1:
        raise RuntimeError(f'{label} matches={count} expected=1')
    return src.replace(old, new, 1)

def patch(src):
    for token in (MARK13, INSERT_ANCHOR, START13,
                  'mapState.r13BasePvsIds = {}',
                  'mapState.r13AabbXYGap = function(a, b)',
                  'mapState.r13ObserveSpace = function(distances, kind)',
                  'mapState.v30R4DirectDoorBarrier'):
        if token not in src:
            raise RuntimeError('R13 precondition missing: ' + token)
    if MARK14 in src:
        raise RuntimeError('R14 marker already present')
    before_rays = src.count('mapState.r11CastDirection(eye,')
    src = replace_once(src, INSERT_ANCHOR, R14 + '\n\n' + INSERT_ANCHOR,
                       'R13 authority-report insertion anchor')
    src = replace_once(src, START13, START14, 'R13 startup anchor')
    for token in (MARK14, 'mapState.r14GiantMaxExtra = 20',
                  'mapState.r14StairMaxExtra = 8',
                  'mapState.r14ObserveStair', 'mapState.r14AddGiant',
                  'mapState.r14AddStair',
                  "tostring(p.kind or 'boundary') == 'boundary'",
                  '[TSP_ROOMRAY_R14] STAIR-ENTER',
                  '[TSP_ROOMRAY_R14] STAIR-EXIT',
                  '[TSP_ROOMRAY_R14] PVS'):
        if token not in src:
            raise RuntimeError('R14 postcondition missing: ' + token)
    if src.count('mapState.r11CastDirection(eye,') != before_rays:
        raise RuntimeError('R14 changed exact ray call-site count')
    return src

def fixture():
    return r'''mapState = {}
self = {cell='fixture'}
camera = {lastIds={}}
camera.setInteriorTopologyPvs = function(boxes, ids)
    camera.lastIds = ids
end
mapState.pvsBoxes = {1,2,3,4,5}
mapState.pvsSignature = 'base'
mapState.r13BasePvsIds = {}
mapState.r13BasePvsIds = {1}
mapState.topoSectorId = 1
mapState.topoX = 0
mapState.topoY = 0
mapState.topoZ = 0
mapState.v30InferFloor = function(x,y,z,sec) return sec.floor end
mapState.v30R4AabbDistance = function(sec,x,y) return sec.d or 0 end
mapState.v30R4DirectDoorBarrier = function(seen,sid) return sid == 5 end
mapState.r13AabbXYGap = function(a, b) return b.gap or 0 end
mapState.r13ResetSpaceAuthority = function() end
mapState.updateTopologyPvs = function(force) end
mapState.r13ObserveSpace = function(distances, kind) return 'normal' end
mapState.r11AuthorityReport = function(distances) end
mapState.r13GiantActive = false
mapState.r13GiantCell = nil
mapState.topoCell = {
 sectors = {
  [1]={kind='vertical_connector',floor=0,center={0,0,0},bbox={0,0,0,20,20,200},d=0,portals={1,2}},
  [2]={kind='room',floor=0,center={0,0,-100},bbox={0,0,-120,100,100,-80},d=20,portals={1}},
  [3]={kind='room',floor=1,center={0,0,240},bbox={0,0,220,100,100,260},d=20,portals={2,3}},
  [4]={kind='room',floor=1,center={100,0,240},bbox={100,0,220,200,100,260},d=100,portals={3}},
  [5]={kind='small_room',floor=1,center={0,100,240},bbox={0,100,220,100,200,260},d=100,portals={4}},
 },
 portals = {
  [1]={a=1,b=2,kind='boundary'},
  [2]={a=1,b=3,kind='boundary'},
  [3]={a=3,b=4,kind='boundary'},
  [4]={a=3,b=5,kind='door'},
 }
}
-- TSP_VISGRID_LUA_V30_R4_SAME_FLOOR_PROXIMITY
-- TSP_ROOMRAY_LUA_V30_R11_FIVE_TIER_XY_HEIGHT
-- TSP_ROOMRAY_LUA_V30_R12_LONG_PRIORITY
-- TSP_ROOMRAY_LUA_V30_R13_GIANT_SHARED_SPACE
mapState.r13BaseAuthorityReport = mapState.r11AuthorityReport
print('[TSP_ROOMRAY_R13] enabled giant=up+forward+nav crossFloorMax=12 sealedSnap=10 giantRelease=20')
for i=1,4 do
 mapState.r11CastDirection = function() end
 -- mapState.r11CastDirection(eye,
end
for i=1,7 do
 mapState.topoZ = i * 8
 mapState.r13ObserveSpace({800,900,850,600}, 'vertical_connector')
end
assert(mapState.r14StairActive, 'stair authority did not enter')
mapState.updateTopologyPvs(true)
local got = {}
for i=1,#camera.lastIds do got[camera.lastIds[i]]=true end
assert(got[2] and got[3] and got[4], 'boundary landing prewake incomplete')
assert(not got[5], 'door-separated room leaked into stair prewake')
print('R14_BEHAVIOR_PASS')
'''

if len(sys.argv) == 2 and sys.argv[1] == '--selftest':
    out = patch(fixture())
    Path('/tmp/roomwake-r14-selftest.lua').write_text(out)
    print('PASS R14 structural selftest: shared-space + connector stair overlay')
elif len(sys.argv) == 3:
    src = Path(sys.argv[1]).read_text()
    Path(sys.argv[2]).write_text(patch(src))
    print('PASS R14 Lua generated from exact pulled R13 input')
else:
    raise SystemExit('usage: patch_r14.py INPUT OUTPUT | --selftest')
PY_R14
}

syntax_check() {
    local file="$1"
    if command -v texluac >/dev/null 2>&1; then
        texluac -p "$file" >/dev/null 2>&1 \
            || fail 31 "Lua syntax check failed: $file"
        echo "PASS Lua syntax: $file"
        return
    fi
    if command -v luac >/dev/null 2>&1; then
        luac -p "$file" >/dev/null 2>&1 \
            || fail 31 "Lua syntax check failed: $file"
        echo "PASS Lua syntax: $file"
        return
    fi
    if command -v docker >/dev/null 2>&1 \
        && docker inspect "$CTR" >/dev/null 2>&1; then
        if [ "$(docker inspect -f '{{.State.Running}}' "$CTR" 2>/dev/null || true)" != "true" ]; then
            docker start "$CTR" >/dev/null \
                || fail 31 "could not start Docker Lua syntax-check container"
        fi
        docker cp "$file" "$CTR:/tmp/visgrid-r14-check.lua" >/dev/null \
            || fail 31 "could not stage Lua for Docker syntax check"
        local parser
        parser="$(docker exec "$CTR" bash -lc \
            'for x in luajit lua texlua; do command -v "$x" >/dev/null 2>&1 && { echo "$x"; exit 0; }; done; exit 1' \
            2>/dev/null || true)"
        if [ -n "$parser" ]; then
            docker exec "$CTR" "$parser" -e \
                "local f,e=loadfile('/tmp/visgrid-r14-check.lua'); assert(f,e)" \
                || fail 31 "Docker Lua syntax check failed: $file"
            echo "PASS Docker Lua syntax: $file"
            return
        fi
        if docker exec "$CTR" test -x /tmp/r13_lua_check \
            && docker exec "$CTR" /tmp/r13_lua_check /tmp/visgrid-r14-check.lua; then
            echo "PASS Docker LuaJIT syntax: $file"
            return
        fi
        fail 31 "Docker has no Lua parser; rerun the R13 controller selftest tooling first"
    fi
    fail 31 "no Lua parser is available locally or in Docker"
}

selftest_action() {
    need python3
    make_patcher
    python3 -m py_compile "$TMP/patch_r14.py" \
        || fail 30 "embedded R14 Python does not compile"
    python3 "$TMP/patch_r14.py" --selftest \
        || fail 30 "R14 structural selftest failed"
    syntax_check /tmp/roomwake-r14-selftest.lua
    if command -v texlua >/dev/null 2>&1; then
        texlua /tmp/roomwake-r14-selftest.lua | grep -Fq R14_BEHAVIOR_PASS \
            || fail 30 "R14 behavior selftest failed"
        echo "PASS R14 executable behavior selftest"
    elif command -v lua >/dev/null 2>&1; then
        lua /tmp/roomwake-r14-selftest.lua | grep -Fq R14_BEHAVIOR_PASS \
            || fail 30 "R14 behavior selftest failed"
        echo "PASS R14 executable behavior selftest"
    else
        echo "INFO: no local Lua interpreter; runtime behavior fixture syntax passed"
    fi
}

restore_backup() {
    local backup="$1" expected="$2"
    [ -n "$backup" ] || return 1
    ssh "$DEV" 'bash -s' -- "$backup" "$LUA" "$PROFILE" "$expected" <<'REMOTE_RESTORE'
set -u
B="$1"; LIVE="$2"; PROFILE="$3"; EXPECTED="$4"
for f in "$B/visgrid.lua.before-r14" "$B/profile.lua.before-r14"; do
    [ -s "$f" ] || exit 1
    [ "$(sha256sum "$f" | awk '{print $1}')" = "$EXPECTED" ] || exit 2
done
install -m 644 "$B/visgrid.lua.before-r14" "$LIVE" || exit 3
install -m 644 "$B/profile.lua.before-r14" "$PROFILE" || exit 4
sync
for f in "$LIVE" "$PROFILE"; do
    [ "$(sha256sum "$f" | awk '{print $1}')" = "$EXPECTED" ] || exit 5
done
echo "PASS exact R13 Lua/profile restored"
REMOTE_RESTORE
}

collect_action() {
    ensure_ssh
    local out="$DL/openmw51-roomwake-r14-validation-$STAMP.txt"
    local total start
    total="$(ssh "$DEV" "wc -l < '$GAMELOG'" 2>/dev/null | tr -d '[:space:]' || true)"
    start="$(ssh "$DEV" "cat '$ARM' 2>/dev/null" | tr -d '[:space:]' || true)"
    case "$total" in ''|*[!0-9]*) fail 20 "invalid current game-log length: $total";; esac
    case "$start" in ''|*[!0-9]*) start=1;; esac
    if [ "$start" -gt "$total" ]; then
        if [ "$total" -gt 4999 ]; then start=$((total - 4999)); else start=1; fi
    else
        start=$((start + 1))
    fi
    scp -q "$DEV:$GAMELOG" "$TMP/openmw.log" \
        || fail 21 "could not pull game log"
    scp -q "$DEV:$PERF" "$TMP/perf.txt" 2>/dev/null || true
    {
        echo "===== OPENMW 0.51 V30 R14 SHARED-SPACE / STAIR-PREWAKE VALIDATION ====="
        date
        echo "Binary SHA: $(remote_sha "$BIN")"
        echo "Lua SHA:    $(remote_sha "$LUA")"
        echo "Log lines: total=$total capture=$start..$total"
        echo
        sed -n "${start},${total}p" "$TMP/openmw.log" \
            | grep -E '\[TSP_ROOMRAY_R14\]|\[TSP_ROOMRAY_R13\]|\[TSP_ROOMRAY_R12\]|\[TSP_ROOMRAY_R11\] tier-change|\[TSP_ROOMOBJ_V30\]|\[TSP_VISGRID_V30_R4\]|\[TSP_ACTOR_V30\]|Lua.*error|failed to render' \
            || true
        if [ -s "$TMP/perf.txt" ]; then
            echo
            echo "===== PERF TAIL ====="
            tail -180 "$TMP/perf.txt"
        fi
    } > "$out"
    echo "PASS R14 validation: $out"
    echo "Upload that file for review."
}

rollback_action() {
    ensure_ssh
    [ -s "$R14_STATE" ] || fail 22 "R14 rollback state missing: $R14_STATE"
    local backup old_sha new_sha
    backup="$(state_value "$R14_STATE" R14_DEVICE_BACKUP)"
    old_sha="$(state_value "$R14_STATE" R14_OLD_LUA_SHA)"
    new_sha="$(state_value "$R14_STATE" R14_NEW_LUA_SHA)"
    valid_sha "$old_sha" || fail 22 "R14 rollback old SHA invalid"
    valid_sha "$new_sha" || fail 22 "R14 rollback new SHA invalid"
    [ "$(remote_sha "$BIN")" = "$EXPECTED_BIN_SHA" ] \
        || fail 23 "device binary changed; refusing Lua-only rollback"
    [ "$(remote_sha "$LUA")" = "$new_sha" ] \
        || fail 23 "live Lua is not exact installed R14; refusing rollback"
    [ "$(remote_sha "$PROFILE")" = "$new_sha" ] \
        || fail 23 "profile Lua is not exact installed R14; refusing rollback"
    restore_backup "$backup" "$old_sha" \
        || fail 24 "R14 rollback could not restore exact R13"
    echo "PASS R14 rollback complete; binary unchanged and exact R13 restored."
}

case "$ACTION" in
    selftest) selftest_action; exit 0 ;;
    collect) collect_action; exit 0 ;;
    rollback) rollback_action; exit 0 ;;
    install) ;;
    *) fail 2 "usage: $0 [install|collect|rollback|selftest]" ;;
esac

exec > >(tee "$RUNLOG") 2>&1

cat <<'BANNER'
============================================================
OPENMW 0.51 — ROOMWAKE V30 R14-R1
SHARED-SPACE COMPLETION + CONNECTOR STAIR PREWAKE
============================================================
GIANT:
  up to 20 nearby same/cross-floor shared-space sectors, 2400 XY,
  with tight AABB-gap and direct-door barriers.

STAIRS:
  signed Z travel near a vertical_connector prewakes at most 8 sectors:
  the connector endpoints plus one boundary-only landing hop.
  Door portals are never crossed. Hold after leaving connector: 3.0 seconds.

Exactly the existing four rays. Existing five tiers and sealed snap unchanged.
No C++ rebuild. No binary replacement. No launcher change.
============================================================
BANNER

need python3
need sha256sum
need sed
ensure_ssh
selftest_action

if ssh "$DEV" "pgrep -af 'openmw-0\\.51|/openmw([[:space:]]|$)' 2>/dev/null" \
    | grep -v pgrep >/dev/null 2>&1; then
    fail 32 "OpenMW appears to be running; exit the game first"
fi

echo
echo "===== 1/6 VERIFY EXACT INSTALLED R13 STATE ====="
[ -s "$R13_STATE" ] || fail 33 "missing R13 state: $R13_STATE"
R13_SHA="$(state_value "$R13_STATE" R13_NEW_LUA_SHA)"
R13_BIN_SHA="$(state_value "$R13_STATE" R13_OLD_BIN_SHA)"
valid_sha "$R13_SHA" || fail 33 "R13 state contains no valid exact R13 Lua SHA"
[ "$R13_BIN_SHA" = "$EXPECTED_BIN_SHA" ] \
    || fail 33 "R13 state was not based on the expected binary"

BIN_SHA="$(remote_sha "$BIN")"
LUA_SHA="$(remote_sha "$LUA")"
PROFILE_SHA="$(remote_sha "$PROFILE")"

if [ -s "$R14_STATE" ]; then
    KNOWN_R14="$(state_value "$R14_STATE" R14_NEW_LUA_SHA)"
    if valid_sha "$KNOWN_R14" && [ "$BIN_SHA" = "$EXPECTED_BIN_SHA" ] \
        && [ "$LUA_SHA" = "$KNOWN_R14" ] && [ "$PROFILE_SHA" = "$KNOWN_R14" ] \
        && ssh "$DEV" "grep -Fq 'TSP_ROOMRAY_LUA_V30_R14_SHARED_SPACE_STAIR_PREWAKE' '$LUA'"; then
        echo "PASS exact R14 is already installed: $KNOWN_R14"
        echo "Use '$0 collect' after testing; no reinstall is needed."
        exit 0
    fi
fi

[ "$BIN_SHA" = "$EXPECTED_BIN_SHA" ] || {
    echo "EXPECTED BIN: $EXPECTED_BIN_SHA" >&2
    echo "ACTUAL BIN:   $BIN_SHA" >&2
    fail 34 "device is not on the exact successful R12/R13 binary"
}
[ "$LUA_SHA" = "$R13_SHA" ] && [ "$PROFILE_SHA" = "$R13_SHA" ] || {
    echo "EXPECTED R13 LUA: $R13_SHA" >&2
    echo "ACTUAL LIVE:      $LUA_SHA" >&2
    echo "ACTUAL PROFILE:   $PROFILE_SHA" >&2
    fail 35 "live Lua/profile are not exact installed R13"
}
ssh "$DEV" "grep -Fq 'TSP_ROOMRAY_LUA_V30_R13_GIANT_SHARED_SPACE' '$LUA' && ! grep -Fq 'TSP_ROOMRAY_LUA_V30_R14_SHARED_SPACE_STAIR_PREWAKE' '$LUA'" \
    || fail 35 "R13/R14 marker shape is not the expected pre-R14 state"
echo "PASS exact state-derived R13 Lua: $R13_SHA"
echo "PASS exact binary unchanged:      $BIN_SHA"

echo
echo "===== 2/6 BACK UP EXACT R13 LUA/PROFILE ====="
DEVICE_BACKUP="$ROOT/backups/roomwake-v30-r14-stair-$STAMP"
ssh "$DEV" 'bash -s' -- "$DEVICE_BACKUP" "$LUA" "$PROFILE" "$R13_SHA" <<'REMOTE_BACKUP'
set -u
B="$1"; LIVE="$2"; PROFILE="$3"; EXPECTED="$4"
mkdir -p "$B" || exit 1
for f in "$LIVE" "$PROFILE"; do
    [ -s "$f" ] || exit 2
    [ "$(sha256sum "$f" | awk '{print $1}')" = "$EXPECTED" ] || exit 3
done
cp -p "$LIVE" "$B/visgrid.lua.before-r14" || exit 4
cp -p "$PROFILE" "$B/profile.lua.before-r14" || exit 5
sync
echo "PASS R14 device backup: $B"
REMOTE_BACKUP
[ "$?" -eq 0 ] || fail 36 "R14 device backup failed"

scp -q "$DEV:$LUA" "$TMP/visgrid-r13.lua" \
    || fail 37 "could not pull exact R13 Lua"
[ "$(sha256sum "$TMP/visgrid-r13.lua" | awk '{print $1}')" = "$R13_SHA" ] \
    || fail 37 "pulled R13 Lua SHA changed after preflight"

echo
echo "===== 3/6 GENERATE R14 FROM EXACT PULLED R13 ====="
make_patcher
python3 -m py_compile "$TMP/patch_r14.py" \
    || fail 38 "embedded R14 Python does not compile"
python3 "$TMP/patch_r14.py" "$TMP/visgrid-r13.lua" "$TMP/visgrid-r14.lua" \
    || fail 39 "R14 transformation failed before device mutation"
syntax_check "$TMP/visgrid-r14.lua"

python3 - "$TMP/visgrid-r13.lua" "$TMP/visgrid-r14.lua" <<'PY_VERIFY'
from pathlib import Path
import sys
before = Path(sys.argv[1]).read_text()
after = Path(sys.argv[2]).read_text()
required = (
    'TSP_ROOMRAY_LUA_V30_R14_SHARED_SPACE_STAIR_PREWAKE',
    'mapState.r14GiantMaxExtra = 20',
    'mapState.r14StairMaxExtra = 8',
    '[TSP_ROOMRAY_R14] STAIR-ENTER',
    '[TSP_ROOMRAY_R14] STAIR-EXIT',
    '[TSP_ROOMRAY_R14] PVS',
)
for token in required:
    if token not in after:
        raise SystemExit('FAIL R14 semantic token missing: ' + token)
if after.count('mapState.r11CastDirection(eye,') != before.count('mapState.r11CastDirection(eye,'):
    raise SystemExit('FAIL R14 changed the four-ray call-site count')
if after.count('TSP_ROOMRAY_LUA_V30_R14_SHARED_SPACE_STAIR_PREWAKE') != 1:
    raise SystemExit('FAIL R14 marker count is not exactly one')
print('PASS semantic verify: R13 retained; four rays unchanged; R14 unique')
PY_VERIFY
[ "$?" -eq 0 ] || fail 40 "R14 semantic verification failed"

R14_SHA="$(sha256sum "$TMP/visgrid-r14.lua" | awk '{print $1}')"
echo "PASS generated R14 Lua SHA: $R14_SHA"

echo
echo "===== 4/6 INSTALL LUA/PROFILE TRANSACTIONALLY ====="
scp -q "$TMP/visgrid-r14.lua" "$DEV:/tmp/visgrid-r14.lua" \
    || { restore_backup "$DEVICE_BACKUP" "$R13_SHA" || true; fail 41 "upload failed"; }
if ! ssh "$DEV" 'bash -s' -- /tmp/visgrid-r14.lua "$R14_SHA" "$LUA" "$PROFILE" "$BIN" "$EXPECTED_BIN_SHA" <<'REMOTE_INSTALL'
set -u
STAGED="$1"; EXPECTED_LUA="$2"; LIVE="$3"; PROFILE="$4"; BIN="$5"; EXPECTED_BIN="$6"
[ -s "$STAGED" ] || exit 1
[ "$(sha256sum "$STAGED" | awk '{print $1}')" = "$EXPECTED_LUA" ] || exit 2
[ "$(sha256sum "$BIN" | awk '{print $1}')" = "$EXPECTED_BIN" ] || exit 3
grep -Fq 'TSP_ROOMRAY_LUA_V30_R14_SHARED_SPACE_STAIR_PREWAKE' "$STAGED" || exit 4
install -m 644 "$STAGED" "$PROFILE" || exit 5
install -m 644 "$STAGED" "$LIVE" || exit 6
sync
for f in "$PROFILE" "$LIVE"; do
    [ "$(sha256sum "$f" | awk '{print $1}')" = "$EXPECTED_LUA" ] || exit 7
done
rm -f "$STAGED"
echo "PASS installed exact R14 Lua/profile; binary unchanged"
REMOTE_INSTALL
then
    restore_backup "$DEVICE_BACKUP" "$R13_SHA" || true
    fail 42 "R14 device install failed; exact R13 restoration attempted"
fi

echo
echo "===== 5/6 VERIFY FINAL DEVICE STATE ====="
FINAL_BIN_SHA="$(remote_sha "$BIN")"
FINAL_LUA_SHA="$(remote_sha "$LUA")"
FINAL_PROFILE_SHA="$(remote_sha "$PROFILE")"
if [ "$FINAL_BIN_SHA" != "$EXPECTED_BIN_SHA" ] \
    || [ "$FINAL_LUA_SHA" != "$R14_SHA" ] \
    || [ "$FINAL_PROFILE_SHA" != "$R14_SHA" ]; then
    restore_backup "$DEVICE_BACKUP" "$R13_SHA" || true
    fail 43 "R14 final verification failed; exact R13 restoration attempted"
fi
echo "PASS binary unchanged: $FINAL_BIN_SHA"
echo "PASS exact R14 Lua/profile: $FINAL_LUA_SHA"

echo
echo "===== 6/6 ARM CAPTURE + SAVE ROLLBACK STATE ====="
if ! ssh "$DEV" 'bash -s' -- "$GAMELOG" "$ARM" <<'REMOTE_ARM'
set -u
LOG="$1"; ARM="$2"
[ -f "$LOG" ] || exit 1
LINES="$(wc -l < "$LOG" | tr -d '[:space:]')"
case "$LINES" in ''|*[!0-9]*) exit 2;; esac
printf '%s\n' "$LINES" > "$ARM" || exit 3
echo "PASS R14 capture armed after log line: $LINES"
REMOTE_ARM
then
    restore_backup "$DEVICE_BACKUP" "$R13_SHA" || true
    fail 44 "capture arm failed; exact R13 restoration attempted"
fi

cat > "$R14_STATE" <<EOF_STATE
R14_DEVICE_BACKUP='$DEVICE_BACKUP'
R14_OLD_BIN_SHA='$EXPECTED_BIN_SHA'
R14_OLD_LUA_SHA='$R13_SHA'
R14_NEW_LUA_SHA='$R14_SHA'
EOF_STATE
[ -s "$R14_STATE" ] || {
    restore_backup "$DEVICE_BACKUP" "$R13_SHA" || true
    fail 45 "state write failed; exact R13 restoration attempted"
}

echo
echo "============================================================"
echo "V30 R14-R1 SHARED-SPACE / STAIR-PREWAKE INSTALLED"
echo "============================================================"
echo "Binary unchanged: $FINAL_BIN_SHA"
echo "R13 Lua:          $R13_SHA"
echo "R14 Lua:          $FINAL_LUA_SHA"
echo
echo "Test the huge room and the tight staircase. Then collect with:"
echo "  cd ~/Downloads"
echo "  ./apply_openmw51_tsp_roomwake_v30_R14_R1_shared_space_stair_prewake.sh collect"
echo
echo "Rollback to exact R13:"
echo "  ./apply_openmw51_tsp_roomwake_v30_R14_R1_shared_space_stair_prewake.sh rollback"
echo "Controller log: $RUNLOG"
echo "============================================================"
