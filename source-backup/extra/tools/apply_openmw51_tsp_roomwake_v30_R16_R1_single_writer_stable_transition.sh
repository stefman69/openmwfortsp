#!/usr/bin/env bash
# OpenMW 0.51 / TrimUI Smart Pro
# V30 R16-R1: one PVS writer with a monotonic stair/shared-space mask.
#
# R15 failure recorded: its broad final PVS was installed, but every call first
# ran the R4/R13/R14 chain. In Ald-ruhn that transiently submitted active=1,
# immediately parking 52/154 objects and sleeping 4/7 actors, before R15 wrote
# active=11. R16 bypasses lower writers while a transition is active and never
# removes a sector from that transition mask until exit or cell change.
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
ARM="$ROOT/roomwake-r16-capture-start.line"

EXPECTED_BIN_SHA="e25f6edfe90c6610be94b285a243d7d2b673a7412ac504a026f14976332a3fab"
EXPECTED_R15_LUA_SHA="83d58c28d43650e6526d8efeaf573051d7e5ae738b3183efe8a05439eb9d0aee"

DL="${OPENMW_DOWNLOADS_DIR:-$HOME/Downloads}"
STATE="$DL/openmw51-roomwake-r16.state"
STAMP="$(date +%Y%m%d-%H%M%S)"
RUNLOG="$DL/openmw51-roomwake-r16-$STAMP.log"
[ -d "$DL" ] || { echo "ERROR: downloads directory missing: $DL" >&2; exit 9; }
TMP="$(mktemp -d "$DL/.roomwake-r16.XXXXXX")" \
    || { echo "ERROR: could not create R16 temporary directory" >&2; exit 9; }
[ -n "$TMP" ] && [ -d "$TMP" ] \
    || { echo "ERROR: invalid R16 temporary directory" >&2; exit 9; }
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
cat > "$TMP/patch_r16.py" <<'PY_R16'
from pathlib import Path
import sys

MARK15 = 'TSP_ROOMRAY_LUA_V30_R15_DETERMINISTIC_ATRIUM_STAIR'
MARK16 = 'TSP_ROOMRAY_LUA_V30_R16_SINGLE_WRITER_STABLE_TRANSITION'
ANCHOR = 'mapState.r13BaseAuthorityReport = mapState.r11AuthorityReport'
START15 = "print('[TSP_ROOMRAY_R15] enabled atrium=nav-or-one-sample stair=near-connector geometric-landings=12 sharedMax=40')"
START16 = START15 + "\nprint('[TSP_ROOMRAY_R16] enabled single-writer stable-union coarse-multilevel=8..20/2-connectors stairCap=32')"

R16 = r'''-- TSP_ROOMRAY_LUA_V30_R16_SINGLE_WRITER_STABLE_TRANSITION
-- R15 validation proved that the final broad PVS was usually correct, but the
-- R4/R13/R14/R15 wrapper chain submitted narrow intermediate masks first.
-- Scene consumed those transient masks: one active sector parked 52/154
-- objects and slept 4/7 actors before R15 restored 11/12 sectors.  While a
-- transition is active, R16 is therefore the only camera PVS writer.  Its mask
-- only grows until the transition ends or the cell changes.
mapState.r16LowerUpdate = mapState.updateTopologyPvs
mapState.r16StableSeen = {}
mapState.r16StableIds = {}
mapState.r16StableCell = nil
mapState.r16Mode = 'normal'
mapState.r16Signature = nil
mapState.r16Writes = 0
mapState.r16Suppressed = 0
mapState.r16StatsCell = nil
mapState.r16Stats = nil
mapState.r16StairCap = 32
mapState.r16AtriumCap = 48
mapState.r16CoarseCap = 20

mapState.r16Clear = function()
    mapState.r16StableSeen = {}
    mapState.r16StableIds = {}
    mapState.r16StableCell = nil
    mapState.r16Signature = nil
end

mapState.r16LowerReset = mapState.r13ResetSpaceAuthority
mapState.r13ResetSpaceAuthority = function()
    mapState.r16LowerReset()
    mapState.r16Clear()
    mapState.r16Mode = 'normal'
    mapState.r16StatsCell = nil
    mapState.r16Stats = nil
    mapState.r16FilteredCell = nil
end

mapState.r16CellStats = function()
    local tc, sectors = mapState.r15Current()
    if tc == nil or sectors == nil then return nil end
    if mapState.r16StatsCell == tc and mapState.r16Stats ~= nil then
        return mapState.r16Stats
    end
    local count, connectors = 0, 0
    local floors, floorCount = {}, 0
    for _, sec in pairs(sectors) do
        if sec ~= nil then
            count = count + 1
            if tostring(sec.kind or 'room') == 'vertical_connector' then
                connectors = connectors + 1
            end
            local floor = tonumber(sec.floor)
            if floor ~= nil and not floors[floor] then
                floors[floor] = true
                floorCount = floorCount + 1
            end
        end
    end
    local stats = {
        count=count, connectors=connectors, floors=floorCount,
        -- Coarse multi-level navmeshes are the Ald-ruhn failure shape: a small
        -- sector census represents a physically large, vertically shared hall.
        coarse=count >= 8 and count <= 20 and connectors >= 2 and floorCount >= 2,
    }
    mapState.r16StatsCell = tc
    mapState.r16Stats = stats
    return stats
end

mapState.r16EffectiveMode = function()
    local _, _, _, currentSec = mapState.r15Current()
    local kind = tostring(currentSec and currentSec.kind or 'room')
    local stats = mapState.r16CellStats()
    if stats ~= nil and stats.coarse then return 'coarse-multilevel', stats end
    if mapState.r15StairActive then return 'stair', stats end
    local realAtrium = mapState.r15SharedActive
        and (kind == 'large_open'
            or mapState.r15NearbyLargeOpen(
                tonumber(mapState.topoX or 0) or 0,
                tonumber(mapState.topoY or 0) or 0))
    if realAtrium then return 'atrium', stats end
    return 'normal', stats
end

mapState.r16Add = function(ids, seen, sid)
    sid = tonumber(sid or 0) or 0
    if sid > 0 and not seen[sid] then
        seen[sid] = true
        ids[#ids + 1] = sid
        return true
    end
    return false
end

mapState.r16BoundaryComponent = function(ids, seen, sectors, portals, seed, cap)
    local queue, queued = {}, {}
    local function enqueue(sid)
        sid = tonumber(sid or 0) or 0
        if sid > 0 and sectors[sid] ~= nil and not queued[sid] then
            queued[sid] = true
            queue[#queue + 1] = sid
        end
    end
    enqueue(seed)
    local qi = 1
    while qi <= #queue and #ids < cap do
        local sid = queue[qi]
        qi = qi + 1
        mapState.r16Add(ids, seen, sid)
        local sec = sectors[sid]
        for j = 1, #(sec and sec.portals or {}) do
            local pid = tonumber(sec.portals[j] or 0) or 0
            local portal = portals and portals[pid] or nil
            if portal ~= nil and tostring(portal.kind or 'boundary') == 'boundary' then
                enqueue(mapState.r14PortalOther(portal, sid))
            end
        end
    end
end

mapState.r16MergeStable = function(candidates, current, cap)
    mapState.r16Add(mapState.r16StableIds, mapState.r16StableSeen, current)
    table.sort(candidates)
    for i = 1, #candidates do
        if #mapState.r16StableIds >= cap then break end
        mapState.r16Add(mapState.r16StableIds, mapState.r16StableSeen, candidates[i])
    end
    table.sort(mapState.r16StableIds)
end

mapState.updateTopologyPvs = function(force)
    local mode, stats = mapState.r16EffectiveMode()
    if mode == 'normal' then
        if mapState.r16Mode ~= 'normal' then
            print(string.format('[TSP_ROOMRAY_R16] EXIT mode=%s active=%d writes=%d suppressed=%d',
                mapState.r16Mode, #mapState.r16StableIds,
                mapState.r16Writes, mapState.r16Suppressed))
            mapState.r16Clear()
        end
        mapState.r16Mode = 'normal'
        return mapState.r16LowerUpdate(force)
    end

    local tc, sectors, current, currentSec = mapState.r15Current()
    local portals = tc and tc.portals or nil
    if tc == nil or sectors == nil or currentSec == nil or mapState.pvsBoxes == nil then
        return mapState.r16LowerUpdate(force)
    end
    if mapState.r16StableCell ~= tc then
        mapState.r16Clear()
        mapState.r16StableCell = tc
    end
    if mapState.r16Mode ~= mode then
        print(string.format(
            '[TSP_ROOMRAY_R16] ENTER mode=%s sectors=%d connectors=%d floors=%d current=%d',
            mode, stats and stats.count or 0, stats and stats.connectors or 0,
            stats and stats.floors or 0, current))
        mapState.r16Mode = mode
    end

    local ids, seen = {}, {}
    for i = 1, #(mapState.r13BasePvsIds or {}) do
        mapState.r16Add(ids, seen, mapState.r13BasePvsIds[i])
    end
    mapState.r16Add(ids, seen, current)
    local cap = mapState.r16StairCap
    if mode == 'coarse-multilevel' then
        cap = mapState.r16CoarseCap
        -- Flood only boundary portals, then admit R15's tightly bounded
        -- geometric connector landings. Door portals never enter the flood.
        mapState.r16BoundaryComponent(ids, seen, sectors, portals, current, cap)
        mapState.r15AddStairGeometry(ids, seen, sectors, portals,
            tonumber(mapState.topoX or 0) or 0,
            tonumber(mapState.topoY or 0) or 0)
        mapState.r16BoundaryComponent(ids, seen, sectors, portals, current, cap)
    elseif mode == 'atrium' then
        cap = mapState.r16AtriumCap
        local x = tonumber(mapState.topoX or 0) or 0
        local y = tonumber(mapState.topoY or 0) or 0
        local added = mapState.r15AddBoundaryFlood(ids, seen, sectors, portals, x, y)
        mapState.r15AddSharedGeometry(ids, seen, sectors, currentSec, x, y, added)
    else
        mapState.r15AddStairGeometry(ids, seen, sectors, portals,
            tonumber(mapState.topoX or 0) or 0,
            tonumber(mapState.topoY or 0) or 0)
    end
    mapState.r16MergeStable(ids, current, cap)

    local signature = table.concat(mapState.r16StableIds, ',')
    if signature == mapState.r16Signature then
        mapState.r16Suppressed = mapState.r16Suppressed + 1
        return
    end
    local ok, err = pcall(camera.setInteriorTopologyPvs,
        mapState.pvsBoxes, mapState.r16StableIds, 0.0, 0.0)
    if not ok then
        print('[TSP_ROOMRAY_R16] PVS ERROR ' .. tostring(err))
        return
    end
    mapState.r16Signature = signature
    mapState.r16Writes = mapState.r16Writes + 1
    mapState.pvsActiveCount = #mapState.r16StableIds
    print(string.format('[TSP_ROOMRAY_R16] PVS mode=%s active=%d write=%d ids=%s',
        mode, #mapState.r16StableIds, mapState.r16Writes, signature))
end

-- R15 split its lower observer and its own observer before wrapping them.  Use
-- that seam to retain stair detection while feeding zero-depth evidence only
-- to R15's atrium guess in fine-grained cells. The original four casts and the
-- R11/R12 authority still receive the real ray distances.
mapState.r16R15WrappedObserve = mapState.r13ObserveSpace
mapState.r13ObserveSpace = function(distances, kind)
    local action = mapState.r15R14Observe(distances, kind)
    local stats = mapState.r16CellStats()
    local x = tonumber(mapState.topoX or 0) or 0
    local y = tonumber(mapState.topoY or 0) or 0
    local allowAtrium = tostring(kind or 'room') == 'large_open'
        or (stats ~= nil and stats.coarse)
        or mapState.r15NearbyLargeOpen(x, y)
    if allowAtrium then
        mapState.r15Observe(distances, kind)
    else
        if mapState.r15SharedActive then
            mapState.r15SharedActive = false
            mapState.r15SharedCell = nil
            mapState.r15SharedReason = 'r16-filtered-fine-cell'
            mapState.r15SharedSealVotes = 0
            mapState.r15Signature = nil
        end
        mapState.r15Observe({0.0, 0.0, 0.0, 0.0}, kind)
        if mapState.r16FilteredCell ~= mapState.topoCell then
            mapState.r16FilteredCell = mapState.topoCell
            print('[TSP_ROOMRAY_R16] FILTER atrium-rays reason=fine-topology')
        end
    end
    return action
end

mapState.r16R15Report = mapState.r11AuthorityReport
mapState.r11AuthorityReport = function(distances)
    mapState.r16R15Report(distances)
    local mode, stats = mapState.r16EffectiveMode()
    print(string.format(
        '[TSP_ROOMRAY_R16] state mode=%s stable=%d writes=%d suppressed=%d sectors=%d connectors=%d floors=%d coarse=%d',
        mode, #mapState.r16StableIds, mapState.r16Writes,
        mapState.r16Suppressed, stats and stats.count or 0,
        stats and stats.connectors or 0, stats and stats.floors or 0,
        stats and stats.coarse and 1 or 0))
end'''

def replace_once(src, old, new, label):
    n = src.count(old)
    if n != 1:
        raise RuntimeError(f'{label} matches={n} expected=1')
    return src.replace(old, new, 1)

def patch(src):
    for token in (MARK15, ANCHOR, START15,
                  'mapState.r15R14Update = mapState.updateTopologyPvs',
                  'mapState.r15AddStairGeometry',
                  'mapState.r15AddBoundaryFlood',
                  'mapState.r15NearbyLargeOpen'):
        if token not in src:
            raise RuntimeError('R15 precondition missing: ' + token)
    if MARK16 in src:
        raise RuntimeError('R16 marker already present')
    rays = src.count('mapState.r11CastDirection(eye,')
    out = replace_once(src, ANCHOR, R16 + '\n\n' + ANCHOR,
                       'R15-to-R16 insertion anchor')
    out = replace_once(out, START15, START16, 'R15 startup anchor')
    if out.count('mapState.r11CastDirection(eye,') != rays:
        raise RuntimeError('R16 changed exact ray call-site count')
    for token in (MARK16, 'mapState.r16LowerUpdate = mapState.updateTopologyPvs',
                  "return 'coarse-multilevel', stats",
                  'mapState.r16BoundaryComponent',
                  'mapState.r16MergeStable',
                  '[TSP_ROOMRAY_R16] FILTER atrium-rays',
                  '[TSP_ROOMRAY_R16] PVS mode='):
        if token not in out:
            raise RuntimeError('R16 postcondition missing: ' + token)
    # Exact reversible transform: R16 only appends its block and startup line.
    restored = out.replace(R16 + '\n\n', '', 1).replace(START16, START15, 1)
    if restored != src:
        raise RuntimeError('R16 reversible transformation check failed')
    return out

def fixture():
    return r'''mapState = {}
self = {cell='fixture'}
camera = {calls=0, lastIds={}}
camera.setInteriorTopologyPvs = function(boxes, ids)
 camera.calls=camera.calls+1; camera.lastIds={};
 for i=1,#ids do camera.lastIds[i]=ids[i] end
end
mapState.pvsBoxes={1,2,3}; mapState.pvsSignature='base'
mapState.r13BasePvsIds={1}; mapState.topoSectorId=1
mapState.topoX=0; mapState.topoY=0
mapState.r15SharedActive=false; mapState.r15StairActive=true
mapState.r15SharedCell=nil; mapState.r15SharedReason='none'
mapState.r15SharedSealVotes=0; mapState.r15Signature=nil
mapState.r15ConnectorIds={2}
mapState.r14PortalOther=function(p,sid) if p.a==sid then return p.b else return p.a end end
mapState.r15NearbyLargeOpen=function() return false end
mapState.r15Current=function()
 local s=mapState.topoCell.sectors; local id=mapState.topoSectorId
 return mapState.topoCell,s,id,s[id]
end
mapState.r15AddStairGeometry=function(ids,seen)
 for _,sid in ipairs({2,3}) do if not seen[sid] then seen[sid]=true; ids[#ids+1]=sid end end
 return 2
end
mapState.r15AddBoundaryFlood=function() return 0 end
mapState.r15AddSharedGeometry=function() return 0 end
mapState.r13ResetSpaceAuthority=function() end
mapState.r15R14Observe=function() return 'normal' end
mapState.r15Observe=function() end
mapState.topoCell={sectors={
 [1]={kind='room',floor=1,portals={1,9}},
 [2]={kind='vertical_connector',floor=1,portals={1,2}},
 [3]={kind='room',floor=2,portals={2,3}},
 [4]={kind='room',floor=2,portals={3,4}},
 [5]={kind='vertical_connector',floor=2,portals={4,5}},
 [6]={kind='room',floor=3,portals={5,6}},
 [7]={kind='room',floor=3,portals={6,7}},
 [8]={kind='room',floor=3,portals={7}},
 [9]={kind='small_room',floor=1,portals={9}},
},portals={
 [1]={a=1,b=2,kind='boundary'}, [2]={a=2,b=3,kind='boundary'},
 [3]={a=3,b=4,kind='boundary'}, [4]={a=4,b=5,kind='boundary'},
 [5]={a=5,b=6,kind='boundary'}, [6]={a=6,b=7,kind='boundary'},
 [7]={a=7,b=8,kind='boundary'}, [9]={a=1,b=9,kind='door'},
}}
mapState.lowerCalls=0
mapState.updateTopologyPvs=function() mapState.lowerCalls=mapState.lowerCalls+1 end
mapState.r13ObserveSpace=function() return 'normal' end
mapState.r11AuthorityReport=function() end
-- TSP_ROOMRAY_LUA_V30_R15_DETERMINISTIC_ATRIUM_STAIR
print('[TSP_ROOMRAY_R15] enabled atrium=nav-or-one-sample stair=near-connector geometric-landings=12 sharedMax=40')
mapState.r15R14Update = mapState.updateTopologyPvs
mapState.r13BaseAuthorityReport = mapState.r11AuthorityReport
for i=1,4 do -- mapState.r11CastDirection(eye,
end
mapState.updateTopologyPvs(true)
assert(camera.calls==1, 'first stable write missing')
assert(mapState.lowerCalls==0, 'lower writer leaked during transition')
assert(#camera.lastIds==8, 'coarse boundary component incomplete or door leaked')
mapState.updateTopologyPvs(true)
assert(camera.calls==1, 'identical forced update rewrote PVS')
assert(mapState.r16Suppressed==1, 'duplicate suppression missing')
mapState.topoSectorId=8; mapState.r15ConnectorIds={5}
mapState.updateTopologyPvs(true)
assert(camera.calls==1, 'stable union should already contain new current sector')
mapState.r15StairActive=false
mapState.topoCell={sectors={
 [1]={kind='room',floor=1,portals={}}
},portals={}}
mapState.topoSectorId=1
mapState.updateTopologyPvs(true)
assert(mapState.lowerCalls==1, 'normal mode did not restore lower writer')
print('R16_BEHAVIOR_PASS')'''

if len(sys.argv) == 2 and sys.argv[1] == '--selftest':
    out = patch(fixture())
    Path('/tmp/roomwake-r16-selftest.lua').write_text(out)
    print('PASS R16 structural selftest: single writer + monotonic union + coarse census')
elif len(sys.argv) == 3:
    src = Path(sys.argv[1]).read_text()
    Path(sys.argv[2]).write_text(patch(src))
    print('PASS R16 Lua generated from exact pulled R15 input')
else:
    raise SystemExit('usage: patch_r16.py INPUT OUTPUT | --selftest')
PY_R16
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
        docker cp "$file" "$CTR:/tmp/visgrid-r16-check.lua" >/dev/null \
            || fail 31 "could not stage Lua syntax check"
        local parser
        parser="$(docker exec "$CTR" bash -lc 'for x in luajit lua texlua; do command -v "$x" >/dev/null 2>&1 && { echo "$x"; exit 0; }; done; exit 1' 2>/dev/null || true)"
        if [ -n "$parser" ]; then
            docker exec "$CTR" "$parser" -e "local f,e=loadfile('/tmp/visgrid-r16-check.lua'); assert(f,e)" \
                || fail 31 "Docker Lua syntax failed: $file"
            echo "PASS Docker Lua syntax: $file"
            return
        fi
        if docker exec "$CTR" test -x /tmp/r13_lua_check \
            && docker exec "$CTR" /tmp/r13_lua_check /tmp/visgrid-r16-check.lua; then
            echo "PASS Docker LuaJIT syntax: $file"
            return
        fi
    fi
    fail 31 "no working Lua parser available"
}

selftest_action() {
    need python3
    make_patcher
    python3 -m py_compile "$TMP/patch_r16.py" \
        || fail 30 "embedded R16 Python does not compile"
    python3 "$TMP/patch_r16.py" --selftest \
        || fail 30 "R16 structural selftest failed"
    syntax_check /tmp/roomwake-r16-selftest.lua
    if command -v texlua >/dev/null 2>&1; then
        texlua /tmp/roomwake-r16-selftest.lua | grep -Fq R16_BEHAVIOR_PASS \
            || fail 30 "R16 executable behavior selftest failed"
        echo "PASS R16 executable behavior selftest"
    elif command -v lua >/dev/null 2>&1; then
        lua /tmp/roomwake-r16-selftest.lua | grep -Fq R16_BEHAVIOR_PASS \
            || fail 30 "R16 executable behavior selftest failed"
        echo "PASS R16 executable behavior selftest"
    fi
}

restore_backup() {
    local backup="$1"
    [ -n "$backup" ] || return 1
    ssh "$DEV" 'bash -s' -- "$backup" "$LUA" "$PROFILE" "$EXPECTED_R15_LUA_SHA" <<'REMOTE_RESTORE'
set -u
B="$1"; LIVE="$2"; PROFILE="$3"; EXPECTED="$4"
for f in "$B/visgrid.lua.before-r16" "$B/profile.lua.before-r16"; do
    [ -s "$f" ] || exit 1
    [ "$(sha256sum "$f" | awk '{print $1}')" = "$EXPECTED" ] || exit 2
done
install -m 644 "$B/visgrid.lua.before-r16" "$LIVE" || exit 3
install -m 644 "$B/profile.lua.before-r16" "$PROFILE" || exit 4
sync
for f in "$LIVE" "$PROFILE"; do
    [ "$(sha256sum "$f" | awk '{print $1}')" = "$EXPECTED" ] || exit 5
done
echo "PASS exact validated R15 Lua/profile restored"
REMOTE_RESTORE
}

collect_action() {
    ensure_ssh
    local out="$DL/openmw51-roomwake-r16-validation-$STAMP.txt"
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
    ssh "$DEV" "grep -nE 'TSP_ROOMRAY_LUA_V30_R1[3456]|\[TSP_ROOMRAY_R1[3456]\] enabled' '$LUA'" \
        > "$TMP/markers.txt" 2>&1 || true
    local tag_count
    tag_count="$(sed -n "${start},${total}p" "$TMP/openmw.log" | grep -c '\[TSP_ROOMRAY_R16\]' || true)"
    {
        printf '%s\n' '===== OPENMW 0.51 V30 R16 SINGLE-WRITER STABLE TRANSITION VALIDATION ====='
        date
        printf 'Binary SHA: %s\n' "$(remote_sha "$BIN")"
        printf 'Lua SHA:    %s\n' "$(remote_sha "$LUA")"
        printf 'Profile:    %s\n' "$(remote_sha "$PROFILE")"
        printf 'Log lines: total=%s capture=%s..%s R16_tags=%s\n\n' "$total" "$start" "$total" "$tag_count"
        printf '%s\n' '===== LIVE LUA MARKERS ====='
        cat "$TMP/markers.txt"
        printf '\n%s\n' '===== FILTERED TEST WINDOW ====='
        sed -n "${start},${total}p" "$TMP/openmw.log" \
            | grep -E '\[TSP_ROOMRAY_R16\]|\[TSP_ROOMRAY_R15\]|\[TSP_ROOMRAY_R14\]|\[TSP_ROOMRAY_R13\]|\[TSP_ROOMRAY_R12\]|\[TSP_ROOMRAY_R11\]|\[TSP_ROOMOBJ_V30\]|\[TSP_VISGRID_V30_R4\]|\[TSP_ACTOR_V30\]|Lua.*error|failed to render' \
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
    echo "PASS R16 validation: $out"
    echo "Upload that file for review."
}

rollback_action() {
    ensure_ssh
    [ -s "$STATE" ] || fail 22 "R16 rollback state missing: $STATE"
    local backup new_sha
    backup="$(state_value "$STATE" R16_DEVICE_BACKUP)"
    new_sha="$(state_value "$STATE" R16_NEW_LUA_SHA)"
    valid_sha "$new_sha" || fail 22 "R16 rollback SHA invalid"
    [ "$(remote_sha "$BIN")" = "$EXPECTED_BIN_SHA" ] \
        || fail 23 "binary changed; refusing Lua-only rollback"
    [ "$(remote_sha "$LUA")" = "$new_sha" ] \
        || fail 23 "live Lua is not exact installed R16"
    [ "$(remote_sha "$PROFILE")" = "$new_sha" ] \
        || fail 23 "profile Lua is not exact installed R16"
    restore_backup "$backup" || fail 24 "could not restore exact R15"
    echo "PASS R16 rollback complete; exact validated R15 restored."
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
OPENMW 0.51 — ROOMWAKE V30 R16-R1
SINGLE-WRITER STABLE TRANSITION AUTHORITY
============================================================
R15 evidence: R14 briefly wrote active=1 in Ald-ruhn before R15 wrote 11.
That one intermediate mask parked 52/154 objects and slept 4/7 actors.

R16 uses exactly one PVS writer during stairs and shared multi-level spaces.
Its sector set may grow but cannot shrink until transition exit/cell change.
Coarse multi-level cells: 8..20 sectors, >=2 connectors, >=2 floors.
Fine cells keep bounded stair prewake; false one-sample atrium guesses filtered.

Exactly four existing rays. No ray, tier, or distance changes.
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
echo "===== 1/6 VERIFY EXACT VALIDATED R15 STATE ====="
BIN_SHA="$(remote_sha "$BIN")"
LUA_SHA="$(remote_sha "$LUA")"
PROFILE_SHA="$(remote_sha "$PROFILE")"
if [ -s "$STATE" ]; then
    KNOWN="$(state_value "$STATE" R16_NEW_LUA_SHA)"
    if valid_sha "$KNOWN" && [ "$BIN_SHA" = "$EXPECTED_BIN_SHA" ] \
        && [ "$LUA_SHA" = "$KNOWN" ] && [ "$PROFILE_SHA" = "$KNOWN" ] \
        && ssh "$DEV" "grep -Fq 'TSP_ROOMRAY_LUA_V30_R16_SINGLE_WRITER_STABLE_TRANSITION' '$LUA'"; then
        echo "PASS exact R16 already installed: $KNOWN"
        echo "Use '$0 collect' after testing; no reinstall is needed."
        exit 0
    fi
fi
[ "$BIN_SHA" = "$EXPECTED_BIN_SHA" ] || {
    echo "EXPECTED BIN: $EXPECTED_BIN_SHA" >&2
    echo "ACTUAL BIN:   $BIN_SHA" >&2
    fail 33 "device binary is not the exact validated R15 binary"
}
[ "$LUA_SHA" = "$EXPECTED_R15_LUA_SHA" ] \
    && [ "$PROFILE_SHA" = "$EXPECTED_R15_LUA_SHA" ] || {
    echo "EXPECTED R15 LUA: $EXPECTED_R15_LUA_SHA" >&2
    echo "ACTUAL LIVE:      $LUA_SHA" >&2
    echo "ACTUAL PROFILE:   $PROFILE_SHA" >&2
    fail 34 "device is not on the exact submitted R15 Lua/profile"
}
ssh "$DEV" "grep -Fq 'TSP_ROOMRAY_LUA_V30_R15_DETERMINISTIC_ATRIUM_STAIR' '$LUA' && ! grep -Fq 'TSP_ROOMRAY_LUA_V30_R16_SINGLE_WRITER_STABLE_TRANSITION' '$LUA'" \
    || fail 34 "R15/R16 marker shape is not the exact pre-R16 state"
echo "PASS exact submitted R15 binary: $BIN_SHA"
echo "PASS exact submitted R15 Lua:    $LUA_SHA"

echo
echo "===== 2/6 BACK UP EXACT R15 LUA/PROFILE ====="
DEVICE_BACKUP="$ROOT/backups/roomwake-v30-r16-single-writer-$STAMP"
if ! ssh "$DEV" 'bash -s' -- "$DEVICE_BACKUP" "$LUA" "$PROFILE" "$EXPECTED_R15_LUA_SHA" <<'REMOTE_BACKUP'
set -u
B="$1"; LIVE="$2"; PROFILE="$3"; EXPECTED="$4"
mkdir -p "$B" || exit 1
for f in "$LIVE" "$PROFILE"; do
    [ -s "$f" ] || exit 2
    [ "$(sha256sum "$f" | awk '{print $1}')" = "$EXPECTED" ] || exit 3
done
cp -p "$LIVE" "$B/visgrid.lua.before-r16" || exit 4
cp -p "$PROFILE" "$B/profile.lua.before-r16" || exit 5
sync
echo "PASS R16 device backup: $B"
REMOTE_BACKUP
then
    fail 35 "R16 device backup failed"
fi
scp -q "$DEV:$LUA" "$TMP/visgrid-r15.lua" || fail 36 "could not pull R15 Lua"
[ "$(sha256sum "$TMP/visgrid-r15.lua" | awk '{print $1}')" = "$EXPECTED_R15_LUA_SHA" ] \
    || fail 36 "pulled R15 Lua SHA changed after preflight"

echo
echo "===== 3/6 GENERATE + VERIFY R16 BEFORE DEVICE MUTATION ====="
make_patcher
python3 -m py_compile "$TMP/patch_r16.py" || fail 37 "R16 Python compile failed"
python3 "$TMP/patch_r16.py" "$TMP/visgrid-r15.lua" "$TMP/visgrid-r16.lua" \
    || fail 38 "R16 transformation failed before device mutation"
syntax_check "$TMP/visgrid-r16.lua"
python3 - "$TMP/visgrid-r15.lua" "$TMP/visgrid-r16.lua" <<'PY_VERIFY'
from pathlib import Path
import sys
a=Path(sys.argv[1]).read_text(); b=Path(sys.argv[2]).read_text()
for t in ('TSP_ROOMRAY_LUA_V30_R16_SINGLE_WRITER_STABLE_TRANSITION',
          'mapState.r16LowerUpdate = mapState.updateTopologyPvs',
          "return 'coarse-multilevel', stats", 'mapState.r16MergeStable',
          '[TSP_ROOMRAY_R16] FILTER atrium-rays', '[TSP_ROOMRAY_R16] PVS mode='):
    if t not in b: raise SystemExit('FAIL missing R16 semantic token: '+t)
if b.count('mapState.r11CastDirection(eye,') != a.count('mapState.r11CastDirection(eye,'):
    raise SystemExit('FAIL R16 changed the exact four-ray call count')
if b.count('TSP_ROOMRAY_LUA_V30_R16_SINGLE_WRITER_STABLE_TRANSITION') != 1:
    raise SystemExit('FAIL R16 marker is not unique')
print('PASS R16 semantic verify: exact R15 retained; four rays unchanged; marker unique')
PY_VERIFY
[ "$?" -eq 0 ] || fail 39 "R16 semantic verification failed"
R16_SHA="$(sha256sum "$TMP/visgrid-r16.lua" | awk '{print $1}')"
echo "PASS generated R16 Lua SHA: $R16_SHA"

echo
echo "===== 4/6 INSTALL LUA/PROFILE TRANSACTIONALLY ====="
scp -q "$TMP/visgrid-r16.lua" "$DEV:/tmp/visgrid-r16.lua" \
    || { restore_backup "$DEVICE_BACKUP" || true; fail 40 "R16 upload failed"; }
if ! ssh "$DEV" 'bash -s' -- /tmp/visgrid-r16.lua "$R16_SHA" "$LUA" "$PROFILE" "$BIN" "$EXPECTED_BIN_SHA" <<'REMOTE_INSTALL'
set -u
STAGED="$1"; EXPECTED="$2"; LIVE="$3"; PROFILE="$4"; BIN="$5"; EXPECTED_BIN="$6"
[ -s "$STAGED" ] || exit 1
[ "$(sha256sum "$STAGED" | awk '{print $1}')" = "$EXPECTED" ] || exit 2
[ "$(sha256sum "$BIN" | awk '{print $1}')" = "$EXPECTED_BIN" ] || exit 3
grep -Fq 'TSP_ROOMRAY_LUA_V30_R16_SINGLE_WRITER_STABLE_TRANSITION' "$STAGED" || exit 4
install -m 644 "$STAGED" "$PROFILE" || exit 5
install -m 644 "$STAGED" "$LIVE" || exit 6
sync
for f in "$PROFILE" "$LIVE"; do
    [ "$(sha256sum "$f" | awk '{print $1}')" = "$EXPECTED" ] || exit 7
done
rm -f "$STAGED"
echo "PASS installed exact R16 Lua/profile; binary unchanged"
REMOTE_INSTALL
then
    restore_backup "$DEVICE_BACKUP" || true
    fail 41 "R16 install failed; exact R15 restoration attempted"
fi

echo
echo "===== 5/6 VERIFY FINAL DEVICE STATE ====="
FINAL_BIN="$(remote_sha "$BIN")"
FINAL_LUA="$(remote_sha "$LUA")"
FINAL_PROFILE="$(remote_sha "$PROFILE")"
if [ "$FINAL_BIN" != "$EXPECTED_BIN_SHA" ] || [ "$FINAL_LUA" != "$R16_SHA" ] \
    || [ "$FINAL_PROFILE" != "$R16_SHA" ]; then
    restore_backup "$DEVICE_BACKUP" || true
    fail 42 "R16 final verification failed; exact R15 restoration attempted"
fi
echo "PASS binary unchanged: $FINAL_BIN"
echo "PASS exact R16 Lua/profile: $FINAL_LUA"

echo
echo "===== 6/6 ARM CAPTURE + SAVE ROLLBACK STATE ====="
if ! ssh "$DEV" 'bash -s' -- "$GAMELOG" "$ARM" <<'REMOTE_ARM'
set -u
LOG="$1"; ARM="$2"
[ -f "$LOG" ] || exit 1
LINES="$(wc -l < "$LOG" | tr -d '[:space:]')"
case "$LINES" in ''|*[!0-9]*) exit 2;; esac
printf '%s\n' "$LINES" > "$ARM" || exit 3
echo "PASS R16 capture armed after log line: $LINES"
REMOTE_ARM
then
    restore_backup "$DEVICE_BACKUP" || true
    fail 43 "capture arm failed; exact R15 restoration attempted"
fi
cat > "$STATE" <<EOF_STATE
R16_DEVICE_BACKUP='$DEVICE_BACKUP'
R16_OLD_BIN_SHA='$EXPECTED_BIN_SHA'
R16_OLD_LUA_SHA='$EXPECTED_R15_LUA_SHA'
R16_NEW_LUA_SHA='$R16_SHA'
EOF_STATE
[ -s "$STATE" ] || {
    restore_backup "$DEVICE_BACKUP" || true
    fail 44 "state write failed; exact R15 restoration attempted"
}

echo
echo "============================================================"
echo "V30 R16-R1 SINGLE-WRITER STABLE TRANSITION INSTALLED"
echo "============================================================"
echo "Binary unchanged: $FINAL_BIN"
echo "R15 Lua:          $EXPECTED_R15_LUA_SHA"
echo "R16 Lua:          $FINAL_LUA"
echo
echo "Test Balmora Mages Guild stairs once, then Ald-ruhn Manor once."
echo "Collect:"
echo "  cd ~/Downloads"
echo "  ./apply_openmw51_tsp_roomwake_v30_R16_R1_single_writer_stable_transition.sh collect"
echo
echo "Rollback to exact submitted R15:"
echo "  ./apply_openmw51_tsp_roomwake_v30_R16_R1_single_writer_stable_transition.sh rollback"
echo "Controller log: $RUNLOG"
echo "============================================================"
