#!/usr/bin/env bash
# OpenMW 0.51 / TrimUI Smart Pro
# V30 R15-R1: deterministic atrium authority and topology-gap stair prewake.
#
# R14 failure recorded: the opt-in shared/stair modes produced no tagged
# transition in the submitted capture, while C++ still reported tier 0/0 with
# 4/8 objects parked and 3/4 actors off-room. Earlier full telemetry proves
# connector sectors can collapse to active=1 and that landing fragments can be
# disconnected in the generated portal graph. R15 therefore does not require
# signed-Z votes and does not rely exclusively on connector portals.
#
# LUA/PROFILE ONLY. No C++ rebuild, binary replacement, or launcher change.
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
ARM="$ROOT/roomwake-r15-capture-start.line"

EXPECTED_BIN_SHA="e25f6edfe90c6610be94b285a243d7d2b673a7412ac504a026f14976332a3fab"
EXPECTED_R14_LUA_SHA="3560d7f4b9bdd0fc97085e90c3762cbf9892b038d1005f4d691b1c1363f1ebb0"

DL="${OPENMW_DOWNLOADS_DIR:-$HOME/Downloads}"
STATE="$DL/openmw51-roomwake-r15.state"
STAMP="$(date +%Y%m%d-%H%M%S)"
RUNLOG="$DL/openmw51-roomwake-r15-$STAMP.log"
[ -d "$DL" ] || { echo "ERROR: downloads directory missing: $DL" >&2; exit 9; }
TMP="$(mktemp -d "$DL/.roomwake-r15.XXXXXX")" \
    || { echo "ERROR: could not create R15 temporary directory" >&2; exit 9; }
[ -n "$TMP" ] && [ -d "$TMP" ] \
    || { echo "ERROR: invalid R15 temporary directory" >&2; exit 9; }
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
    case "$1" in *[!0-9a-f]*|'') return 1;; esac
    [ "${#1}" -eq 64 ]
}

make_patcher() {
cat > "$TMP/patch_r15.py" <<'PY_R15'
from pathlib import Path
import sys

MARK14 = 'TSP_ROOMRAY_LUA_V30_R14_SHARED_SPACE_STAIR_PREWAKE'
MARK15 = 'TSP_ROOMRAY_LUA_V30_R15_DETERMINISTIC_ATRIUM_STAIR'
ANCHOR = 'mapState.r13BaseAuthorityReport = mapState.r11AuthorityReport'
START14 = "print('[TSP_ROOMRAY_R14] enabled sharedMax=20 sameFloor=bounded stair=connector+signedZ stairMax=8')"
START15 = START14 + "\nprint('[TSP_ROOMRAY_R15] enabled atrium=nav-or-one-sample stair=near-connector geometric-landings=12 sharedMax=40')"

R15 = r'''-- TSP_ROOMRAY_LUA_V30_R15_DETERMINISTIC_ATRIUM_STAIR
-- R14's modes were too conditional. R15 activates stair authority whenever a
-- connector is current or geometrically nearby, and augments incomplete
-- connector graphs with tightly bounded AABB landing candidates. Atrium mode
-- starts immediately in large_open topology or from one combined tall/deep
-- sample, then remains cell-local until sustained sealed evidence.
mapState.r15SharedActive = false
mapState.r15SharedCell = nil
mapState.r15SharedReason = 'none'
mapState.r15SharedSealVotes = 0
mapState.r15SharedReleaseRequired = 20
mapState.r15SharedMaxExtra = 40
mapState.r15SharedRange = 3600.0
mapState.r15SharedGap = 1000.0
mapState.r15StairActive = false
mapState.r15StairHold = 0
mapState.r15StairHoldSamples = 20
mapState.r15StairConnectorRange = 720.0
mapState.r15StairLandingRange = 1900.0
mapState.r15StairLandingGap = 320.0
mapState.r15StairMaxExtra = 12
mapState.r15ConnectorIds = {}
mapState.r15OverrideApplied = false
mapState.r15Signature = nil
mapState.r15InputSignature = nil
mapState.r15SharedExtra = 0
mapState.r15StairExtra = 0

mapState.r15R14Reset = mapState.r13ResetSpaceAuthority
mapState.r13ResetSpaceAuthority = function()
    mapState.r15R14Reset()
    mapState.r15SharedActive = false
    mapState.r15SharedCell = nil
    mapState.r15SharedReason = 'reset'
    mapState.r15SharedSealVotes = 0
    mapState.r15StairActive = false
    mapState.r15StairHold = 0
    mapState.r15ConnectorIds = {}
    mapState.r15Signature = nil
    mapState.r15InputSignature = nil
    mapState.r15SharedExtra = 0
    mapState.r15StairExtra = 0
    -- r15OverrideApplied remains set until the next PVS call restores R14.
end

mapState.r15Box = function(sec)
    local b = sec and sec.bbox or nil
    if b == nil or #b < 6 then return nil end
    return {
        tonumber(b[1] or 0) or 0, tonumber(b[2] or 0) or 0,
        tonumber(b[3] or 0) or 0, tonumber(b[4] or 0) or 0,
        tonumber(b[5] or 0) or 0, tonumber(b[6] or 0) or 0,
    }
end

mapState.r15Current = function()
    local tc = mapState.topoCell
    local sectors = tc and tc.sectors or nil
    local sid = tonumber(mapState.topoSectorId or 0) or 0
    return tc, sectors, sid, sectors and sid > 0 and sectors[sid] or nil
end

mapState.r15FindConnectors = function(x, y)
    local _, sectors, current, currentSec = mapState.r15Current()
    if sectors == nil then return {} end
    local candidates = {}
    for sid, sec in pairs(sectors) do
        sid = tonumber(sid or 0) or 0
        if sid > 0 and sec ~= nil
            and tostring(sec.kind or 'room') == 'vertical_connector' then
            local d = mapState.v30R4AabbDistance(sec, x, y)
            if sid == current or d <= mapState.r15StairConnectorRange then
                candidates[#candidates + 1] = {id=sid, d=d}
            end
        end
    end
    table.sort(candidates, function(a, b)
        if a.id == current then return true end
        if b.id == current then return false end
        if a.d ~= b.d then return a.d < b.d end
        return a.id < b.id
    end)
    local ids = {}
    for i = 1, math.min(3, #candidates) do ids[#ids + 1] = candidates[i].id end
    return ids
end

mapState.r15NearbyLargeOpen = function(x, y)
    local _, sectors = mapState.r15Current()
    if sectors == nil then return false end
    for _, sec in pairs(sectors) do
        if sec ~= nil and tostring(sec.kind or 'room') == 'large_open'
            and mapState.v30R4AabbDistance(sec, x, y) <= 1200.0 then
            return true
        end
    end
    return false
end

mapState.r15Observe = function(distances, kind)
    local x = tonumber(mapState.topoX)
    local y = tonumber(mapState.topoY)
    if x == nil or y == nil or mapState.topoCell == nil then return end
    kind = tostring(kind or 'room')
    local connectors = mapState.r15FindConnectors(x, y)
    mapState.r15ConnectorIds = connectors

    local wasStair = mapState.r15StairActive
    if #connectors > 0 then
        mapState.r15StairActive = true
        mapState.r15StairHold = mapState.r15StairHoldSamples
    elseif mapState.r15StairActive then
        mapState.r15StairHold = math.max(0, mapState.r15StairHold - 1)
        if mapState.r15StairHold <= 0 then mapState.r15StairActive = false end
    end
    if wasStair ~= mapState.r15StairActive then
        mapState.r15Signature = nil
        print(string.format('[TSP_ROOMRAY_R15] STAIR-%s topo=%s connectors=%s hold=%d',
            mapState.r15StairActive and 'ENTER' or 'EXIT', kind,
            table.concat(connectors, ','), mapState.r15StairHold))
        mapState.updateTopologyPvs(true)
    end

    local sharedProof, reason = false, 'none'
    if kind == 'large_open' then
        sharedProof, reason = true, 'large-open-nav'
    elseif distances ~= nil and kind ~= 'vertical_connector'
        and kind ~= 'corridor' and kind ~= 'small_room' then
        local deep = 0
        for i = 1, 3 do if distances[i] >= 750.0 then deep = deep + 1 end end
        if distances[4] >= 850.0 and deep >= 2 then
            sharedProof, reason = true, 'one-tall-two-deep'
        elseif mapState.r15NearbyLargeOpen(x, y)
            and distances[4] >= 600.0
            and math.max(distances[1], distances[2], distances[3]) >= 900.0 then
            sharedProof, reason = true, 'near-large-open'
        end
    end

    if not mapState.r15SharedActive and sharedProof then
        mapState.r15SharedActive = true
        mapState.r15SharedCell = self.cell
        mapState.r15SharedReason = reason
        mapState.r15SharedSealVotes = 0
        mapState.r15Signature = nil
        print(string.format(
            '[TSP_ROOMRAY_R15] ATRIUM-ENTER reason=%s topo=%s L=%.0f C=%.0f R=%.0f U=%.0f',
            reason, kind, distances and distances[1] or -1,
            distances and distances[2] or -1, distances and distances[3] or -1,
            distances and distances[4] or -1))
        mapState.updateTopologyPvs(true)
    end

    if mapState.r15SharedActive then
        if mapState.r15SharedCell ~= self.cell then
            mapState.r15SharedActive = false
            mapState.r15SharedCell = nil
            mapState.r15SharedReason = 'cell-change'
            mapState.r15SharedSealVotes = 0
            mapState.updateTopologyPvs(true)
        else
            local sealed = mapState.r13SealedCondition(distances, kind)
            if sealed and (kind == 'small_room' or kind == 'corridor') then
                mapState.r15SharedSealVotes = mapState.r15SharedSealVotes + 1
            else
                mapState.r15SharedSealVotes = 0
            end
            if mapState.r15SharedSealVotes >= mapState.r15SharedReleaseRequired then
                mapState.r15SharedActive = false
                mapState.r15SharedCell = nil
                mapState.r15SharedReason = 'sealed-release'
                mapState.r15SharedSealVotes = 0
                mapState.r15Signature = nil
                print('[TSP_ROOMRAY_R15] ATRIUM-EXIT reason=20-sealed-samples')
                mapState.updateTopologyPvs(true)
            else
                mapState.r11XYScore = 4.0
                mapState.r11ZScore = 4.0
                mapState.r12ResetEvidence()
                mapState.r11SetTiers(0, 0, 'r15-atrium-hold', distances)
            end
        end
    end
end

mapState.r15CopyBase = function()
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

mapState.r15AddBoundaryFlood = function(ids, seen, sectors, portals, x, y)
    local queue = {}
    for i = 1, #ids do queue[#queue + 1] = {id=ids[i], depth=0} end
    local qi, added = 1, 0
    while qi <= #queue and added < mapState.r15SharedMaxExtra do
        local item = queue[qi]
        qi = qi + 1
        if item.depth < 4 then
            local sec = sectors[item.id]
            for j = 1, #(sec and sec.portals or {}) do
                local pid = tonumber(sec.portals[j] or 0) or 0
                local p = portals and portals[pid] or nil
                if p ~= nil and tostring(p.kind or 'boundary') == 'boundary' then
                    local other = mapState.r14PortalOther(p, item.id)
                    local target = other > 0 and sectors[other] or nil
                    if target ~= nil and not seen[other]
                        and mapState.v30R4AabbDistance(target, x, y)
                            <= mapState.r15SharedRange then
                        seen[other] = true
                        ids[#ids + 1] = other
                        queue[#queue + 1] = {id=other, depth=item.depth + 1}
                        added = added + 1
                        if added >= mapState.r15SharedMaxExtra then break end
                    end
                end
            end
        end
    end
    return added
end

mapState.r15AddSharedGeometry = function(ids, seen, sectors, currentSec, x, y, already)
    local candidates = {}
    local currentKind = tostring(currentSec.kind or 'room')
    for sid, target in pairs(sectors) do
        sid = tonumber(sid or 0) or 0
        if sid > 0 and target ~= nil and not seen[sid]
            and not mapState.v30R4DirectDoorBarrier(seen, sid) then
            local d = mapState.v30R4AabbDistance(target, x, y)
            local gap = mapState.r13AabbXYGap(currentSec, target)
            local kind = tostring(target.kind or 'room')
            if d <= mapState.r15SharedRange
                and (gap <= mapState.r15SharedGap
                    or currentKind == 'large_open' or kind == 'large_open') then
                candidates[#candidates + 1] = {
                    id=sid, d=d, gap=gap,
                    priority=(kind == 'large_open' or kind == 'vertical_connector') and 0 or 1,
                }
            end
        end
    end
    table.sort(candidates, function(a, b)
        if a.priority ~= b.priority then return a.priority < b.priority end
        if a.d ~= b.d then return a.d < b.d end
        if a.gap ~= b.gap then return a.gap < b.gap end
        return a.id < b.id
    end)
    local room = math.max(0, mapState.r15SharedMaxExtra - already)
    local added = 0
    for i = 1, #candidates do
        if added >= room then break end
        local sid = candidates[i].id
        if not seen[sid] then
            seen[sid] = true
            ids[#ids + 1] = sid
            added = added + 1
        end
    end
    return added
end

mapState.r15VerticalNear = function(a, b)
    local aa, bb = mapState.r15Box(a), mapState.r15Box(b)
    if aa == nil or bb == nil then return false end
    return bb[6] >= aa[3] - 360.0 and bb[3] <= aa[6] + 360.0
end

mapState.r15AddStairGeometry = function(ids, seen, sectors, portals, x, y)
    local candidates, candidateSeen = {}, {}
    local function consider(sid, source, priority)
        sid = tonumber(sid or 0) or 0
        local target = sid > 0 and sectors[sid] or nil
        local connector = source > 0 and sectors[source] or nil
        if target == nil or connector == nil or seen[sid] or candidateSeen[sid]
            or mapState.v30R4DirectDoorBarrier(seen, sid) then return end
        local d = mapState.v30R4AabbDistance(target, x, y)
        local gap = mapState.r13AabbXYGap(connector, target)
        if d <= mapState.r15StairLandingRange
            and gap <= mapState.r15StairLandingGap
            and mapState.r15VerticalNear(connector, target) then
            candidateSeen[sid] = true
            candidates[#candidates + 1] = {
                id=sid, source=source, priority=priority, d=d, gap=gap,
            }
        end
    end

    for i = 1, #(mapState.r15ConnectorIds or {}) do
        local cid = tonumber(mapState.r15ConnectorIds[i] or 0) or 0
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
                    consider(mapState.r14PortalOther(p, cid), cid, 0)
                end
            end
            for sid, _ in pairs(sectors) do consider(sid, cid, 1) end
        end
    end
    table.sort(candidates, function(a, b)
        if a.priority ~= b.priority then return a.priority < b.priority end
        if a.d ~= b.d then return a.d < b.d end
        if a.gap ~= b.gap then return a.gap < b.gap end
        return a.id < b.id
    end)
    local added = 0
    for i = 1, #candidates do
        if added >= mapState.r15StairMaxExtra then break end
        local sid = candidates[i].id
        if not seen[sid] then
            seen[sid] = true
            ids[#ids + 1] = sid
            added = added + 1
        end
    end
    return added
end

mapState.r15R14Update = mapState.updateTopologyPvs
mapState.updateTopologyPvs = function(force)
    local shared = mapState.r15SharedActive and mapState.r15SharedCell == self.cell
    local stair = mapState.r15StairActive
    local restoring = mapState.r15OverrideApplied and not shared and not stair
    mapState.r15R14Update(force or restoring)
    if not shared and not stair then
        mapState.r15OverrideApplied = false
        mapState.r15Signature = nil
        mapState.r15InputSignature = nil
        mapState.r15SharedExtra = 0
        mapState.r15StairExtra = 0
        return
    end

    local tc, sectors, current, currentSec = mapState.r15Current()
    local portals = tc and tc.portals or nil
    if sectors == nil or currentSec == nil or mapState.pvsBoxes == nil then return end
    local cc = currentSec.center or {0,0,0}
    local x = tonumber(mapState.topoX or cc[1] or 0) or 0
    local y = tonumber(mapState.topoY or cc[2] or 0) or 0
    local inputSignature = tostring(mapState.pvsSignature or '?')
        .. ':a' .. (shared and '1' or '0')
        .. ':s' .. (stair and '1' or '0')
        .. ':c' .. tostring(current)
        .. ':q' .. tostring(math.floor(x / 128.0))
        .. ',' .. tostring(math.floor(y / 128.0))
        .. ':k' .. table.concat(mapState.r15ConnectorIds or {}, ',')
    if not force and mapState.r15OverrideApplied
        and inputSignature == mapState.r15InputSignature then
        return
    end
    local ids, seen = mapState.r15CopyBase()
    local sharedExtra, stairExtra = 0, 0
    if shared then
        sharedExtra = mapState.r15AddBoundaryFlood(ids, seen, sectors, portals, x, y)
        sharedExtra = sharedExtra + mapState.r15AddSharedGeometry(
            ids, seen, sectors, currentSec, x, y, sharedExtra)
    end
    if stair then
        stairExtra = mapState.r15AddStairGeometry(ids, seen, sectors, portals, x, y)
    end
    table.sort(ids)
    local signature = tostring(mapState.pvsSignature or '?')
        .. ':r15:a' .. (shared and '1' or '0')
        .. ':s' .. (stair and '1' or '0')
        .. ':c' .. tostring(current)
        .. ':q' .. tostring(math.floor(x / 128.0))
        .. ',' .. tostring(math.floor(y / 128.0))
        .. ':' .. table.concat(ids, ',')
    if force or signature ~= mapState.r15Signature then
        local ok, err = pcall(camera.setInteriorTopologyPvs,
            mapState.pvsBoxes, ids, 0.0, 0.0)
        if ok then
            mapState.r15OverrideApplied = true
            mapState.r15Signature = signature
            mapState.r15InputSignature = inputSignature
            mapState.r15SharedExtra = sharedExtra
            mapState.r15StairExtra = stairExtra
            mapState.pvsActiveCount = #ids
            print(string.format(
                '[TSP_ROOMRAY_R15] PVS atrium=%d stair=%d shared=%d landing=%d active=%d current=%d ids=%s',
                shared and 1 or 0, stair and 1 or 0, sharedExtra, stairExtra,
                #ids, current, table.concat(ids, ',')))
        else
            print('[TSP_ROOMRAY_R15] PVS ERROR ' .. tostring(err))
        end
    end
end

mapState.r15R14Observe = mapState.r13ObserveSpace
mapState.r13ObserveSpace = function(distances, kind)
    local action = mapState.r15R14Observe(distances, kind)
    mapState.r15Observe(distances, kind)
    return action
end

mapState.r15R14Report = mapState.r11AuthorityReport
mapState.r11AuthorityReport = function(distances)
    mapState.r15R14Report(distances)
    print(string.format(
        '[TSP_ROOMRAY_R15] state atrium=%d reason=%s seal=%d/%d stair=%d hold=%d connectors=%s shared=%d landing=%d',
        mapState.r15SharedActive and 1 or 0,
        tostring(mapState.r15SharedReason or '?'),
        tonumber(mapState.r15SharedSealVotes or 0) or 0,
        mapState.r15SharedReleaseRequired,
        mapState.r15StairActive and 1 or 0,
        tonumber(mapState.r15StairHold or 0) or 0,
        table.concat(mapState.r15ConnectorIds or {}, ','),
        tonumber(mapState.r15SharedExtra or 0) or 0,
        tonumber(mapState.r15StairExtra or 0) or 0))
end'''

def replace_once(src, old, new, label):
    n = src.count(old)
    if n != 1:
        raise RuntimeError(f'{label} matches={n} expected=1')
    return src.replace(old, new, 1)

def patch(src):
    for token in (MARK14, ANCHOR, START14,
                  'mapState.r14R13UpdateTopologyPvs = mapState.updateTopologyPvs',
                  'mapState.r14PortalOther = function(p, sid)',
                  'mapState.r13SealedCondition = function(distances, kind)',
                  'mapState.v30R4DirectDoorBarrier'):
        if token not in src:
            raise RuntimeError('R14 precondition missing: ' + token)
    if MARK15 in src:
        raise RuntimeError('R15 marker already present')
    rays = src.count('mapState.r11CastDirection(eye,')
    src = replace_once(src, ANCHOR, R15 + '\n\n' + ANCHOR,
                       'R14-to-R15 insertion anchor')
    src = replace_once(src, START14, START15, 'R14 startup anchor')
    for token in (MARK15, 'mapState.r15SharedMaxExtra = 40',
                  'mapState.r15StairMaxExtra = 12',
                  'mapState.r15FindConnectors', 'mapState.r15NearbyLargeOpen',
                  'mapState.r15AddBoundaryFlood', 'mapState.r15AddStairGeometry',
                  '[TSP_ROOMRAY_R15] ATRIUM-ENTER',
                  '[TSP_ROOMRAY_R15] STAIR-%s', '[TSP_ROOMRAY_R15] PVS'):
        if token not in src:
            raise RuntimeError('R15 postcondition missing: ' + token)
    if src.count('mapState.r11CastDirection(eye,') != rays:
        raise RuntimeError('R15 changed exact ray call-site count')
    return src

def fixture():
    return r'''mapState = {}
self = {cell='fixture'}
camera = {lastIds={}}
camera.setInteriorTopologyPvs = function(boxes, ids) camera.lastIds=ids end
mapState.pvsBoxes={1,2,3,4,5,6}; mapState.pvsSignature='base'
mapState.r13BasePvsIds={1}; mapState.topoSectorId=1
mapState.topoX=0; mapState.topoY=0; mapState.topoZ=20
mapState.v30R4AabbDistance=function(sec,x,y) return sec.d or 0 end
mapState.v30R4DirectDoorBarrier=function(seen,sid) return sid==6 end
mapState.r13AabbXYGap=function(a,b) return b.gap or 0 end
mapState.r14PortalOther = function(p, sid) if p.a==sid then return p.b else return p.a end end
mapState.r13SealedCondition = function(distances, kind) return false end
mapState.r12ResetEvidence=function() end
mapState.r11SetTiers=function() end
mapState.r13ResetSpaceAuthority=function() end
mapState.updateTopologyPvs=function() end
mapState.r13ObserveSpace=function() return 'normal' end
mapState.r11AuthorityReport=function() end
mapState.r14R13UpdateTopologyPvs = mapState.updateTopologyPvs
mapState.r13GiantActive=false
mapState.topoCell={sectors={
 [1]={kind='room',floor=1,center={0,0,20},bbox={0,0,0,200,200,100},d=0,portals={1}},
 [2]={kind='vertical_connector',floor=1,center={200,0,100},bbox={180,0,0,260,100,400},d=150,gap=0,portals={1}},
 [3]={kind='room',floor=2,center={220,0,420},bbox={180,0,380,400,200,500},d=180,gap=0,portals={}},
 [4]={kind='large_open',floor=1,center={500,0,200},bbox={300,0,0,1200,900,900},d=300,gap=100,portals={}},
 [5]={kind='room',floor=2,center={1000,0,500},bbox={800,0,400,1300,500,650},d=800,gap=200,portals={}},
 [6]={kind='small_room',floor=1,center={100,100,20},bbox={0,100,0,200,300,100},d=100,gap=0,portals={2}},
},portals={
 [1]={a=1,b=2,kind='boundary'}, [2]={a=1,b=6,kind='door'}
}}
-- TSP_VISGRID_LUA_V30_R4_SAME_FLOOR_PROXIMITY
-- TSP_ROOMRAY_LUA_V30_R13_GIANT_SHARED_SPACE
-- TSP_ROOMRAY_LUA_V30_R14_SHARED_SPACE_STAIR_PREWAKE
print('[TSP_ROOMRAY_R14] enabled sharedMax=20 sameFloor=bounded stair=connector+signedZ stairMax=8')
mapState.r13BaseAuthorityReport = mapState.r11AuthorityReport
for i=1,4 do -- mapState.r11CastDirection(eye,
end
mapState.r13ObserveSpace({1000,900,200,900}, 'room')
assert(mapState.r15SharedActive, 'one-sample atrium proof failed')
assert(mapState.r15StairActive, 'nearby connector stair proof failed')
mapState.updateTopologyPvs(true)
local got={}; for i=1,#camera.lastIds do got[camera.lastIds[i]]=true end
assert(got[2] and got[3] and got[4] and got[5], 'shared/stair sectors missing')
assert(not got[6], 'door-separated sector leaked')
print('R15_BEHAVIOR_PASS')
'''

if len(sys.argv) == 2 and sys.argv[1] == '--selftest':
    out = patch(fixture())
    Path('/tmp/roomwake-r15-selftest.lua').write_text(out)
    print('PASS R15 structural selftest: deterministic atrium + geometric stair')
elif len(sys.argv) == 3:
    src = Path(sys.argv[1]).read_text()
    Path(sys.argv[2]).write_text(patch(src))
    print('PASS R15 Lua generated from exact pulled R14 input')
else:
    raise SystemExit('usage: patch_r15.py INPUT OUTPUT | --selftest')
PY_R15
}

syntax_check() {
    local file="$1"
    if command -v texluac >/dev/null 2>&1; then
        texluac -p "$file" >/dev/null 2>&1 || fail 31 "Lua syntax failed: $file"
        echo "PASS Lua syntax: $file"
        return
    fi
    if command -v luac >/dev/null 2>&1; then
        luac -p "$file" >/dev/null 2>&1 || fail 31 "Lua syntax failed: $file"
        echo "PASS Lua syntax: $file"
        return
    fi
    if command -v docker >/dev/null 2>&1 && docker inspect "$CTR" >/dev/null 2>&1; then
        if [ "$(docker inspect -f '{{.State.Running}}' "$CTR" 2>/dev/null || true)" != true ]; then
            docker start "$CTR" >/dev/null || fail 31 "could not start Docker parser"
        fi
        docker cp "$file" "$CTR:/tmp/visgrid-r15-check.lua" >/dev/null \
            || fail 31 "could not stage Lua syntax check"
        local parser
        parser="$(docker exec "$CTR" bash -lc 'for x in luajit lua texlua; do command -v "$x" >/dev/null 2>&1 && { echo "$x"; exit 0; }; done; exit 1' 2>/dev/null || true)"
        if [ -n "$parser" ]; then
            docker exec "$CTR" "$parser" -e "local f,e=loadfile('/tmp/visgrid-r15-check.lua'); assert(f,e)" \
                || fail 31 "Docker Lua syntax failed: $file"
            echo "PASS Docker Lua syntax: $file"
            return
        fi
        if docker exec "$CTR" test -x /tmp/r13_lua_check \
            && docker exec "$CTR" /tmp/r13_lua_check /tmp/visgrid-r15-check.lua; then
            echo "PASS Docker LuaJIT syntax: $file"
            return
        fi
    fi
    fail 31 "no working Lua parser available"
}

selftest_action() {
    need python3
    make_patcher
    python3 -m py_compile "$TMP/patch_r15.py" \
        || fail 30 "embedded R15 Python does not compile"
    python3 "$TMP/patch_r15.py" --selftest \
        || fail 30 "R15 structural selftest failed"
    syntax_check /tmp/roomwake-r15-selftest.lua
    if command -v texlua >/dev/null 2>&1; then
        texlua /tmp/roomwake-r15-selftest.lua | grep -Fq R15_BEHAVIOR_PASS \
            || fail 30 "R15 executable behavior selftest failed"
        echo "PASS R15 executable behavior selftest"
    elif command -v lua >/dev/null 2>&1; then
        lua /tmp/roomwake-r15-selftest.lua | grep -Fq R15_BEHAVIOR_PASS \
            || fail 30 "R15 executable behavior selftest failed"
        echo "PASS R15 executable behavior selftest"
    fi
}

restore_backup() {
    local backup="$1"
    [ -n "$backup" ] || return 1
    ssh "$DEV" 'bash -s' -- "$backup" "$LUA" "$PROFILE" "$EXPECTED_R14_LUA_SHA" <<'REMOTE_RESTORE'
set -u
B="$1"; LIVE="$2"; PROFILE="$3"; EXPECTED="$4"
for f in "$B/visgrid.lua.before-r15" "$B/profile.lua.before-r15"; do
    [ -s "$f" ] || exit 1
    [ "$(sha256sum "$f" | awk '{print $1}')" = "$EXPECTED" ] || exit 2
done
install -m 644 "$B/visgrid.lua.before-r15" "$LIVE" || exit 3
install -m 644 "$B/profile.lua.before-r15" "$PROFILE" || exit 4
sync
for f in "$LIVE" "$PROFILE"; do
    [ "$(sha256sum "$f" | awk '{print $1}')" = "$EXPECTED" ] || exit 5
done
echo "PASS exact validated R14 Lua/profile restored"
REMOTE_RESTORE
}

collect_action() {
    ensure_ssh
    local out="$DL/openmw51-roomwake-r15-validation-$STAMP.txt"
    local total start
    total="$(ssh "$DEV" "wc -l < '$GAMELOG'" 2>/dev/null | tr -d '[:space:]' || true)"
    start="$(ssh "$DEV" "cat '$ARM' 2>/dev/null" | tr -d '[:space:]' || true)"
    case "$total" in ''|*[!0-9]*) fail 20 "invalid game-log length: $total";; esac
    case "$start" in ''|*[!0-9]*) start=1;; esac
    if [ "$start" -gt "$total" ]; then
        if [ "$total" -gt 4999 ]; then start=$((total - 4999)); else start=1; fi
    else
        start=$((start + 1))
    fi
    scp -q "$DEV:$GAMELOG" "$TMP/openmw.log" || fail 21 "could not pull game log"
    scp -q "$DEV:$PERF" "$TMP/perf.txt" 2>/dev/null || true
    ssh "$DEV" "grep -nE 'TSP_ROOMRAY_LUA_V30_R1[345]|\[TSP_ROOMRAY_R1[345]\] enabled' '$LUA'" \
        > "$TMP/markers.txt" 2>&1 || true
    local tag_count
    tag_count="$(sed -n "${start},${total}p" "$TMP/openmw.log" | grep -c '\[TSP_ROOMRAY_R15\]' || true)"
    {
        printf '%s\n' '===== OPENMW 0.51 V30 R15 DETERMINISTIC ATRIUM / STAIR VALIDATION ====='
        date
        printf 'Binary SHA: %s\n' "$(remote_sha "$BIN")"
        printf 'Lua SHA:    %s\n' "$(remote_sha "$LUA")"
        printf 'Profile:    %s\n' "$(remote_sha "$PROFILE")"
        printf 'Log lines: total=%s capture=%s..%s R15_tags=%s\n\n' "$total" "$start" "$total" "$tag_count"
        printf '%s\n' '===== LIVE LUA MARKERS ====='
        cat "$TMP/markers.txt"
        printf '\n%s\n' '===== FILTERED TEST WINDOW ====='
        sed -n "${start},${total}p" "$TMP/openmw.log" \
            | grep -E '\[TSP_ROOMRAY_R15\]|\[TSP_ROOMRAY_R14\]|\[TSP_ROOMRAY_R13\]|\[TSP_ROOMRAY_R12\]|\[TSP_ROOMRAY_R11\]|\[TSP_ROOMOBJ_V30\]|\[TSP_VISGRID_V30_R4\]|\[TSP_ACTOR_V30\]|Lua.*error|failed to render' \
            || true
        if [ "$tag_count" -lt 3 ]; then
            printf '\n%s\n' '===== UNFILTERED FALLBACK: LAST 1200 LOG LINES ====='
            tail -1200 "$TMP/openmw.log"
        fi
        if [ -s "$TMP/perf.txt" ]; then
            printf '\n%s\n' '===== PERF TAIL ====='
            tail -180 "$TMP/perf.txt"
        fi
    } > "$out"
    echo "PASS R15 validation: $out"
    echo "Upload that file for review."
}

rollback_action() {
    ensure_ssh
    [ -s "$STATE" ] || fail 22 "R15 rollback state missing: $STATE"
    local backup new_sha
    backup="$(state_value "$STATE" R15_DEVICE_BACKUP)"
    new_sha="$(state_value "$STATE" R15_NEW_LUA_SHA)"
    valid_sha "$new_sha" || fail 22 "R15 rollback SHA invalid"
    [ "$(remote_sha "$BIN")" = "$EXPECTED_BIN_SHA" ] \
        || fail 23 "binary changed; refusing Lua-only rollback"
    [ "$(remote_sha "$LUA")" = "$new_sha" ] \
        || fail 23 "live Lua is not exact installed R15"
    [ "$(remote_sha "$PROFILE")" = "$new_sha" ] \
        || fail 23 "profile Lua is not exact installed R15"
    restore_backup "$backup" || fail 24 "could not restore exact R14"
    echo "PASS R15 rollback complete; exact validated R14 restored."
}

case "$ACTION" in
    selftest) selftest_action; exit 0;;
    collect) collect_action; exit 0;;
    rollback) rollback_action; exit 0;;
    install) ;;
    *) fail 2 "usage: $0 [install|collect|rollback|selftest]";;
esac

exec > >(tee "$RUNLOG") 2>&1

cat <<'BANNER'
============================================================
OPENMW 0.51 — ROOMWAKE V30 R15-R1
DETERMINISTIC ATRIUM + TOPOLOGY-GAP STAIR PREWAKE
============================================================
ATRIUM:
  large_open navmesh activates immediately.
  One tall-up + two deep-forward rays can activate from an adjoining room.
  Boundary flood + bounded geometry admits at most 40 shared sectors / 3600 XY.

STAIR:
  Current or nearby vertical_connector activates immediately—no movement vote.
  Portal-linked and geometric landing fragments are admitted, maximum 12.
  Direct door portals remain hard barriers. Hold after connector: 4 seconds.

Exactly four existing rays. Five tiers and tight-room policy remain unchanged.
No C++ rebuild. No binary replacement. No launcher change.
============================================================
BANNER

need python3
need sha256sum
ensure_ssh
selftest_action

if ssh "$DEV" "pgrep -af 'openmw-0\\.51|/openmw([[:space:]]|$)' 2>/dev/null" \
    | grep -v pgrep >/dev/null 2>&1; then
    fail 32 "OpenMW appears to be running; exit the game first"
fi

echo
echo "===== 1/6 VERIFY EXACT VALIDATED R14 STATE ====="
BIN_SHA="$(remote_sha "$BIN")"
LUA_SHA="$(remote_sha "$LUA")"
PROFILE_SHA="$(remote_sha "$PROFILE")"
if [ -s "$STATE" ]; then
    KNOWN="$(state_value "$STATE" R15_NEW_LUA_SHA)"
    if valid_sha "$KNOWN" && [ "$BIN_SHA" = "$EXPECTED_BIN_SHA" ] \
        && [ "$LUA_SHA" = "$KNOWN" ] && [ "$PROFILE_SHA" = "$KNOWN" ] \
        && ssh "$DEV" "grep -Fq 'TSP_ROOMRAY_LUA_V30_R15_DETERMINISTIC_ATRIUM_STAIR' '$LUA'"; then
        echo "PASS exact R15 already installed: $KNOWN"
        echo "Use '$0 collect' after testing; no reinstall is needed."
        exit 0
    fi
fi
[ "$BIN_SHA" = "$EXPECTED_BIN_SHA" ] || {
    echo "EXPECTED BIN: $EXPECTED_BIN_SHA" >&2
    echo "ACTUAL BIN:   $BIN_SHA" >&2
    fail 33 "device binary is not the exact validated R14 binary"
}
[ "$LUA_SHA" = "$EXPECTED_R14_LUA_SHA" ] \
    && [ "$PROFILE_SHA" = "$EXPECTED_R14_LUA_SHA" ] || {
    echo "EXPECTED R14 LUA: $EXPECTED_R14_LUA_SHA" >&2
    echo "ACTUAL LIVE:      $LUA_SHA" >&2
    echo "ACTUAL PROFILE:   $PROFILE_SHA" >&2
    fail 34 "device is not on the exact submitted R14 Lua/profile"
}
ssh "$DEV" "grep -Fq 'TSP_ROOMRAY_LUA_V30_R14_SHARED_SPACE_STAIR_PREWAKE' '$LUA' && ! grep -Fq 'TSP_ROOMRAY_LUA_V30_R15_DETERMINISTIC_ATRIUM_STAIR' '$LUA'" \
    || fail 34 "R14/R15 marker shape is not the exact pre-R15 state"
echo "PASS exact submitted R14 binary: $BIN_SHA"
echo "PASS exact submitted R14 Lua:    $LUA_SHA"

echo
echo "===== 2/6 BACK UP EXACT R14 LUA/PROFILE ====="
DEVICE_BACKUP="$ROOT/backups/roomwake-v30-r15-deterministic-$STAMP"
if ! ssh "$DEV" 'bash -s' -- "$DEVICE_BACKUP" "$LUA" "$PROFILE" "$EXPECTED_R14_LUA_SHA" <<'REMOTE_BACKUP'
set -u
B="$1"; LIVE="$2"; PROFILE="$3"; EXPECTED="$4"
mkdir -p "$B" || exit 1
for f in "$LIVE" "$PROFILE"; do
    [ -s "$f" ] || exit 2
    [ "$(sha256sum "$f" | awk '{print $1}')" = "$EXPECTED" ] || exit 3
done
cp -p "$LIVE" "$B/visgrid.lua.before-r15" || exit 4
cp -p "$PROFILE" "$B/profile.lua.before-r15" || exit 5
sync
echo "PASS R15 device backup: $B"
REMOTE_BACKUP
then
    fail 35 "R15 device backup failed"
fi
scp -q "$DEV:$LUA" "$TMP/visgrid-r14.lua" || fail 36 "could not pull R14 Lua"
[ "$(sha256sum "$TMP/visgrid-r14.lua" | awk '{print $1}')" = "$EXPECTED_R14_LUA_SHA" ] \
    || fail 36 "pulled R14 Lua SHA changed after preflight"

echo
echo "===== 3/6 GENERATE + VERIFY R15 BEFORE DEVICE MUTATION ====="
make_patcher
python3 -m py_compile "$TMP/patch_r15.py" || fail 37 "R15 Python compile failed"
python3 "$TMP/patch_r15.py" "$TMP/visgrid-r14.lua" "$TMP/visgrid-r15.lua" \
    || fail 38 "R15 transformation failed before device mutation"
syntax_check "$TMP/visgrid-r15.lua"
python3 - "$TMP/visgrid-r14.lua" "$TMP/visgrid-r15.lua" <<'PY_VERIFY'
from pathlib import Path
import sys
a=Path(sys.argv[1]).read_text(); b=Path(sys.argv[2]).read_text()
for t in ('TSP_ROOMRAY_LUA_V30_R15_DETERMINISTIC_ATRIUM_STAIR',
          'mapState.r15SharedMaxExtra = 40', 'mapState.r15StairMaxExtra = 12',
          '[TSP_ROOMRAY_R15] ATRIUM-ENTER', '[TSP_ROOMRAY_R15] PVS'):
    if t not in b: raise SystemExit('FAIL missing R15 semantic token: '+t)
if b.count('mapState.r11CastDirection(eye,') != a.count('mapState.r11CastDirection(eye,'):
    raise SystemExit('FAIL R15 changed the exact four-ray call count')
if b.count('TSP_ROOMRAY_LUA_V30_R15_DETERMINISTIC_ATRIUM_STAIR') != 1:
    raise SystemExit('FAIL R15 marker is not unique')
print('PASS R15 semantic verify: R14 retained; four rays unchanged; marker unique')
PY_VERIFY
[ "$?" -eq 0 ] || fail 39 "R15 semantic verification failed"
R15_SHA="$(sha256sum "$TMP/visgrid-r15.lua" | awk '{print $1}')"
echo "PASS generated R15 Lua SHA: $R15_SHA"

echo
echo "===== 4/6 INSTALL LUA/PROFILE TRANSACTIONALLY ====="
scp -q "$TMP/visgrid-r15.lua" "$DEV:/tmp/visgrid-r15.lua" \
    || { restore_backup "$DEVICE_BACKUP" || true; fail 40 "R15 upload failed"; }
if ! ssh "$DEV" 'bash -s' -- /tmp/visgrid-r15.lua "$R15_SHA" "$LUA" "$PROFILE" "$BIN" "$EXPECTED_BIN_SHA" <<'REMOTE_INSTALL'
set -u
STAGED="$1"; EXPECTED="$2"; LIVE="$3"; PROFILE="$4"; BIN="$5"; EXPECTED_BIN="$6"
[ -s "$STAGED" ] || exit 1
[ "$(sha256sum "$STAGED" | awk '{print $1}')" = "$EXPECTED" ] || exit 2
[ "$(sha256sum "$BIN" | awk '{print $1}')" = "$EXPECTED_BIN" ] || exit 3
grep -Fq 'TSP_ROOMRAY_LUA_V30_R15_DETERMINISTIC_ATRIUM_STAIR' "$STAGED" || exit 4
install -m 644 "$STAGED" "$PROFILE" || exit 5
install -m 644 "$STAGED" "$LIVE" || exit 6
sync
for f in "$PROFILE" "$LIVE"; do
    [ "$(sha256sum "$f" | awk '{print $1}')" = "$EXPECTED" ] || exit 7
done
rm -f "$STAGED"
echo "PASS installed exact R15 Lua/profile; binary unchanged"
REMOTE_INSTALL
then
    restore_backup "$DEVICE_BACKUP" || true
    fail 41 "R15 install failed; exact R14 restoration attempted"
fi

echo
echo "===== 5/6 VERIFY FINAL DEVICE STATE ====="
FINAL_BIN="$(remote_sha "$BIN")"
FINAL_LUA="$(remote_sha "$LUA")"
FINAL_PROFILE="$(remote_sha "$PROFILE")"
if [ "$FINAL_BIN" != "$EXPECTED_BIN_SHA" ] || [ "$FINAL_LUA" != "$R15_SHA" ] \
    || [ "$FINAL_PROFILE" != "$R15_SHA" ]; then
    restore_backup "$DEVICE_BACKUP" || true
    fail 42 "R15 final verification failed; exact R14 restoration attempted"
fi
echo "PASS binary unchanged: $FINAL_BIN"
echo "PASS exact R15 Lua/profile: $FINAL_LUA"

echo
echo "===== 6/6 ARM CAPTURE + SAVE ROLLBACK STATE ====="
if ! ssh "$DEV" 'bash -s' -- "$GAMELOG" "$ARM" <<'REMOTE_ARM'
set -u
LOG="$1"; ARM="$2"
[ -f "$LOG" ] || exit 1
LINES="$(wc -l < "$LOG" | tr -d '[:space:]')"
case "$LINES" in ''|*[!0-9]*) exit 2;; esac
printf '%s\n' "$LINES" > "$ARM" || exit 3
echo "PASS R15 capture armed after log line: $LINES"
REMOTE_ARM
then
    restore_backup "$DEVICE_BACKUP" || true
    fail 43 "capture arm failed; exact R14 restoration attempted"
fi
cat > "$STATE" <<EOF_STATE
R15_DEVICE_BACKUP='$DEVICE_BACKUP'
R15_OLD_BIN_SHA='$EXPECTED_BIN_SHA'
R15_OLD_LUA_SHA='$EXPECTED_R14_LUA_SHA'
R15_NEW_LUA_SHA='$R15_SHA'
EOF_STATE
[ -s "$STATE" ] || {
    restore_backup "$DEVICE_BACKUP" || true
    fail 44 "state write failed; exact R14 restoration attempted"
}

echo
echo "============================================================"
echo "V30 R15-R1 DETERMINISTIC ATRIUM / STAIR INSTALLED"
echo "============================================================"
echo "Binary unchanged: $FINAL_BIN"
echo "R14 Lua:          $EXPECTED_R14_LUA_SHA"
echo "R15 Lua:          $FINAL_LUA"
echo
echo "Test Balmora Mages Guild stairs once, then Ald-ruhn Manor once."
echo "Collect:"
echo "  cd ~/Downloads"
echo "  ./apply_openmw51_tsp_roomwake_v30_R15_R1_deterministic_atrium_stair.sh collect"
echo
echo "Rollback to exact submitted R14:"
echo "  ./apply_openmw51_tsp_roomwake_v30_R15_R1_deterministic_atrium_stair.sh rollback"
echo "Controller log: $RUNLOG"
echo "============================================================"
