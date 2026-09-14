#!/usr/bin/env bash
# OpenMW 0.51 / TrimUI Smart Pro
# V30 R17-R2: dual-extreme room awareness.
#
# R16 fixed Ald-ruhn and Balmora Mages Guild by making stair/shared-space PVS
# submission single-writer and monotonic. The submitted Caldera capture proves
# the remaining performance regression: its 40-sector cell contains seventeen
# vertical connectors, so proximity alone held R16 stair mode continuously even
# while all four rays repeatedly terminated within roughly 70..370 units.
# R17-R2 keeps coarse multi-level and real atrium authority unchanged, but
# distinguishes broad openings from long narrow passages. A deep centre ray
# cannot by itself open the stair/shared-space continuity mask when both side
# rays and the ceiling remain shallow. Sustained narrow evidence uses R4's
# exact topology, XY/Z tier 3/4, and releases immediately on a side/up opening.
# Sustained all-shallow evidence still uses exact R4 plus tier 4/4.
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
ARM="$ROOT/roomwake-r17-r2-capture-start.line"

EXPECTED_BIN_SHA="e25f6edfe90c6610be94b285a243d7d2b673a7412ac504a026f14976332a3fab"
EXPECTED_R16_LUA_SHA="6073f42af7db1c3d82943d4adc0ff1c75f29f72508c78e4dcf225285a8772a32"

DL="${OPENMW_DOWNLOADS_DIR:-$HOME/Downloads}"
STATE="$DL/openmw51-roomwake-r17-r2.state"
STAMP="$(date +%Y%m%d-%H%M%S)"
RUNLOG="$DL/openmw51-roomwake-r17-r2-$STAMP.log"
[ -d "$DL" ] || { echo "ERROR: downloads directory missing: $DL" >&2; exit 9; }
TMP="$(mktemp -d "$DL/.roomwake-r17.XXXXXX")" \
    || { echo "ERROR: could not create R17 temporary directory" >&2; exit 9; }
[ -n "$TMP" ] && [ -d "$TMP" ] \
    || { echo "ERROR: invalid R17 temporary directory" >&2; exit 9; }
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
cat > "$TMP/patch_r17_r2.py" <<'PY_R17'
from pathlib import Path
import sys

MARK16 = 'TSP_ROOMRAY_LUA_V30_R16_SINGLE_WRITER_STABLE_TRANSITION'
MARK17 = 'TSP_ROOMRAY_LUA_V30_R17_R2_DUAL_EXTREMES'
ANCHOR = 'mapState.r13BaseAuthorityReport = mapState.r11AuthorityReport'
START16 = "print('[TSP_ROOMRAY_R16] enabled single-writer stable-union coarse-multilevel=8..20/2-connectors stairCap=32')"
START17 = START16 + "\nprint('[TSP_ROOMRAY_R17_R2] enabled broad=fast narrow=6-sample-R4-tier3/4 blank=R4-tier4 coarse/atrium=unchanged')"

R17 = r'''-- TSP_ROOMRAY_LUA_V30_R17_R2_DUAL_EXTREMES
-- Fine-cell connector proximity is not enough to justify a continuity mask:
-- Caldera exposes 17 connector sectors even when the camera faces a wall.
-- A stair earns R16 continuity from an actual opening seen by the existing
-- three forward rays or upward ray. A four-second grace bridges brief stair
-- occlusion. Coarse multi-level halls and real atria always retain R16.
mapState.r17ExposureHold = 0
mapState.r17ExposureHoldSamples = 20
mapState.r17BlankVotes = 0
mapState.r17BlankRequired = 6
mapState.r17GateOpen = false
mapState.r17BlankActive = false
mapState.r17DirectBase = false
mapState.r17NarrowVotes = 0
mapState.r17NarrowRequired = 6
mapState.r17NarrowActive = false
mapState.r17ForwardPair = 450.0
mapState.r17SideRelease = 520.0
mapState.r17UpOpen = 550.0
mapState.r17BlankForward = 400.0
mapState.r17BlankUp = 400.0
mapState.r17NarrowSide = 360.0
mapState.r17NarrowCenter = 650.0
mapState.r17NarrowUp = 450.0
mapState.r17LastReason = 'reset'

mapState.r17OpeningProof = function(distances)
    if distances == nil then return false, 0, 0.0, 0.0, 0.0 end
    local left = tonumber(distances[1] or 0) or 0
    local center = tonumber(distances[2] or 0) or 0
    local right = tonumber(distances[3] or 0) or 0
    local up = tonumber(distances[4] or 0) or 0
    local count = 0
    if left >= mapState.r17ForwardPair then count = count + 1 end
    if center >= mapState.r17ForwardPair then count = count + 1 end
    if right >= mapState.r17ForwardPair then count = count + 1 end
    local longest = math.max(left, center, right)
    local sideLongest = math.max(left, right)
    -- A long centre ray alone proves passage depth, not room volume. Broad
    -- authority needs two forward witnesses, a real side opening, or height.
    local proof = count >= 2 or sideLongest >= mapState.r17SideRelease
        or up >= mapState.r17UpOpen
    return proof, count, longest, up, sideLongest
end

mapState.r17NarrowEvidence = function(distances)
    if distances == nil then return false, false, 0.0, 0.0, 0.0, 0.0 end
    local left = tonumber(distances[1] or 0) or 0
    local center = tonumber(distances[2] or 0) or 0
    local right = tonumber(distances[3] or 0) or 0
    local up = tonumber(distances[4] or 0) or 0
    local candidate = center >= mapState.r17NarrowCenter
        and left <= mapState.r17NarrowSide
        and right <= mapState.r17NarrowSide
        and up <= mapState.r17NarrowUp
    local release = left >= mapState.r17SideRelease
        or right >= mapState.r17SideRelease
        or up >= mapState.r17UpOpen
        or (left >= mapState.r17ForwardPair
            and right >= mapState.r17ForwardPair)
    return candidate, release, left, center, right, up
end

mapState.r17AllShallow = function(distances)
    if distances == nil then return false end
    for i = 1, 3 do
        if (tonumber(distances[i] or 0) or 0) > mapState.r17BlankForward then
            return false
        end
    end
    return (tonumber(distances[4] or 0) or 0) <= mapState.r17BlankUp
end

mapState.r17LowerReset = mapState.r13ResetSpaceAuthority
mapState.r13ResetSpaceAuthority = function()
    mapState.r17LowerReset()
    mapState.r17ExposureHold = 0
    mapState.r17BlankVotes = 0
    mapState.r17GateOpen = false
    mapState.r17BlankActive = false
    mapState.r17DirectBase = false
    mapState.r17NarrowVotes = 0
    mapState.r17NarrowActive = false
    mapState.r17LastReason = 'reset'
end

mapState.r17LowerUpdate = mapState.updateTopologyPvs
mapState.updateTopologyPvs = function(force)
    local mode = mapState.r16EffectiveMode()
    local protected = mode == 'coarse-multilevel' or mode == 'atrium'
    local continuity = protected
        or (mode == 'stair' and mapState.r17ExposureHold > 0)
    if mapState.r17NarrowActive then
        local restore = not mapState.r17DirectBase
        if restore and mapState.r16Mode ~= 'normal' then
            print(string.format(
                '[TSP_ROOMRAY_R17_R2] NARROW-PVS prior=%s stable=%d',
                tostring(mapState.r16Mode), #(mapState.r16StableIds or {})))
            mapState.r16Clear()
            mapState.r16Mode = 'normal'
        end
        mapState.r17DirectBase = true
        return mapState.r13BaseUpdateTopologyPvs(restore)
    elseif continuity or mode ~= 'stair' then
        mapState.r17DirectBase = false
        return mapState.r17LowerUpdate(force)
    end

    -- Fine stair with no recent view proof: bypass R13/R14/R15/R16 special
    -- writers and submit only R4's exact door/floor-aware base result.
    local restore = not mapState.r17DirectBase
    if restore and mapState.r16Mode ~= 'normal' then
        print(string.format(
            '[TSP_ROOMRAY_R17_R2] GATE-CLOSE reason=no-volume-proof prior=%s stable=%d',
            tostring(mapState.r16Mode), #(mapState.r16StableIds or {})))
        mapState.r16Clear()
        mapState.r16Mode = 'normal'
    end
    mapState.r17DirectBase = true
    return mapState.r13BaseUpdateTopologyPvs(restore)
end

mapState.r17LowerObserve = mapState.r13ObserveSpace
mapState.r13ObserveSpace = function(distances, kind)
    local action = mapState.r17LowerObserve(distances, kind)
    local mode = mapState.r16EffectiveMode()
    local protected = mode == 'coarse-multilevel' or mode == 'atrium'
    local stair = mode == 'stair'
    local proof, pairCount, longest, up = mapState.r17OpeningProof(distances)
    local shallow = mapState.r17AllShallow(distances)
    local narrow, release, left, center, right = mapState.r17NarrowEvidence(distances)
    local oldGate = mapState.r17GateOpen
    local oldBlank = mapState.r17BlankActive
    local oldNarrow = mapState.r17NarrowActive

    if protected or release then
        mapState.r17NarrowVotes = 0
        mapState.r17NarrowActive = false
    elseif narrow then
        mapState.r17NarrowVotes = math.min(mapState.r17NarrowRequired,
            mapState.r17NarrowVotes + 1)
        if mapState.r17NarrowVotes >= mapState.r17NarrowRequired then
            mapState.r17NarrowActive = true
        end
    else
        mapState.r17NarrowVotes = math.max(0, mapState.r17NarrowVotes - 2)
    end

    if mapState.r17NarrowActive then
        mapState.r17ExposureHold = 0
        if shallow then
            mapState.r17BlankVotes = mapState.r17BlankVotes + 1
        else
            mapState.r17BlankVotes = 0
            mapState.r17BlankActive = false
        end
        if mapState.r17BlankVotes >= mapState.r17BlankRequired then
            mapState.r17BlankActive = true
        end
        mapState.r17LastReason = mapState.r17BlankActive
            and 'sustained-all-shallow' or 'long-narrow-passage'
    elseif protected then
        mapState.r17ExposureHold = mapState.r17ExposureHoldSamples
        mapState.r17BlankVotes = 0
        mapState.r17BlankActive = false
        mapState.r17LastReason = mode
    elseif stair then
        if proof then
            mapState.r17ExposureHold = mapState.r17ExposureHoldSamples
            mapState.r17BlankVotes = 0
            mapState.r17BlankActive = false
            mapState.r17LastReason = pairCount >= 2 and 'two-forward'
                or (up >= mapState.r17UpOpen and 'upward')
                or 'side-opening'
        else
            mapState.r17ExposureHold = math.max(0,
                mapState.r17ExposureHold - 1)
            if shallow then
                mapState.r17BlankVotes = mapState.r17BlankVotes + 1
            else
                mapState.r17BlankVotes = 0
            end
            if mapState.r17ExposureHold <= 0
                and mapState.r17BlankVotes >= mapState.r17BlankRequired then
                mapState.r17BlankActive = true
                mapState.r17LastReason = 'sustained-all-shallow'
            end
        end
    else
        mapState.r17ExposureHold = 0
        mapState.r17BlankVotes = 0
        mapState.r17BlankActive = false
        mapState.r17LastReason = 'not-stair'
    end

    mapState.r17GateOpen = protected
        or (stair and mapState.r17ExposureHold > 0)

    if mapState.r17BlankActive and not protected then
        mapState.r11XYScore = 0.0
        mapState.r11ZScore = 0.0
        mapState.r12ResetEvidence()
        mapState.r11SetTiers(4, 4, 'r17-blank-wall', distances)
    elseif mapState.r17NarrowActive and not protected then
        -- Tier 3 preserves useful forward depth while R4's door/floor-aware
        -- topology removes lateral rooms behind the two proven close walls.
        mapState.r11XYScore = 0.25
        mapState.r11ZScore = 0.0
        mapState.r12ResetEvidence()
        mapState.r11SetTiers(3, 4, 'r17-r2-narrow-passage', distances)
    end

    local pvsPublished = false
    if oldGate ~= mapState.r17GateOpen then
        print(string.format(
            '[TSP_ROOMRAY_R17_R2] GATE-%s reason=%s mode=%s hold=%d pair=%d longest=%.0f up=%.0f',
            mapState.r17GateOpen and 'OPEN' or 'CLOSE',
            tostring(mapState.r17LastReason), mode,
            mapState.r17ExposureHold, pairCount, longest, up))
        mapState.updateTopologyPvs(true)
        pvsPublished = true
    elseif oldBlank ~= mapState.r17BlankActive then
        print(string.format(
            '[TSP_ROOMRAY_R17_R2] BLANK-%s votes=%d/%d longest=%.0f up=%.0f',
            mapState.r17BlankActive and 'ENTER' or 'EXIT',
            mapState.r17BlankVotes, mapState.r17BlankRequired, longest, up))
        mapState.updateTopologyPvs(true)
        pvsPublished = true
    end
    if oldNarrow ~= mapState.r17NarrowActive then
        print(string.format(
            '[TSP_ROOMRAY_R17_R2] NARROW-%s votes=%d/%d L=%.0f C=%.0f R=%.0f U=%.0f',
            mapState.r17NarrowActive and 'ENTER' or 'EXIT',
            mapState.r17NarrowVotes, mapState.r17NarrowRequired,
            left, center, right, up))
        if not pvsPublished then mapState.updateTopologyPvs(true) end
    end
    return action
end

mapState.r17LowerReport = mapState.r11AuthorityReport
mapState.r11AuthorityReport = function(distances)
    mapState.r17LowerReport(distances)
    local mode = mapState.r16EffectiveMode()
    local _, pairCount, longest, up = mapState.r17OpeningProof(distances)
    print(string.format(
        '[TSP_ROOMRAY_R17_R2] state mode=%s gate=%d hold=%d narrow=%d nvotes=%d/%d blank=%d bvotes=%d/%d directR4=%d pair=%d longest=%.0f up=%.0f reason=%s',
        mode, mapState.r17GateOpen and 1 or 0,
        mapState.r17ExposureHold, mapState.r17NarrowActive and 1 or 0,
        mapState.r17NarrowVotes, mapState.r17NarrowRequired,
        mapState.r17BlankActive and 1 or 0,
        mapState.r17BlankVotes, mapState.r17BlankRequired,
        mapState.r17DirectBase and 1 or 0, pairCount, longest, up,
        tostring(mapState.r17LastReason)))
end'''

def replace_once(src, old, new, label):
    n = src.count(old)
    if n != 1:
        raise RuntimeError(f'{label} matches={n} expected=1')
    return src.replace(old, new, 1)

def patch(src):
    for token in (MARK16, ANCHOR, START16,
                  'mapState.r16LowerUpdate = mapState.updateTopologyPvs',
                  'mapState.r16EffectiveMode = function()',
                  'mapState.r16Clear = function()',
                  'mapState.r13BaseUpdateTopologyPvs',
                  'mapState.r12ResetEvidence()',
                  'mapState.r11SetTiers'):
        if token not in src:
            raise RuntimeError('R16 precondition missing: ' + token)
    if MARK17 in src:
        raise RuntimeError('R17-R2 marker already present')
    rays = src.count('mapState.r11CastDirection(eye,')
    out = replace_once(src, ANCHOR, R17 + '\n\n' + ANCHOR,
                       'R16-to-R17 insertion anchor')
    out = replace_once(out, START16, START17, 'R16 startup anchor')
    if out.count('mapState.r11CastDirection(eye,') != rays:
        raise RuntimeError('R17 changed exact ray call-site count')
    for token in (MARK17, 'mapState.r17ExposureHoldSamples = 20',
                  'mapState.r17BlankRequired = 6',
                  'mapState.r17NarrowRequired = 6',
                  'mapState.r17OpeningProof', 'mapState.r17NarrowEvidence',
                  'mapState.r17AllShallow',
                  'mapState.r13BaseUpdateTopologyPvs(restore)',
                  "mapState.r11SetTiers(4, 4, 'r17-blank-wall'",
                  "mapState.r11SetTiers(3, 4, 'r17-r2-narrow-passage'",
                  '[TSP_ROOMRAY_R17_R2] GATE-%s',
                  '[TSP_ROOMRAY_R17_R2] NARROW-%s',
                  '[TSP_ROOMRAY_R17_R2] state mode='):
        if token not in out:
            raise RuntimeError('R17 postcondition missing: ' + token)
    restored = out.replace(R17 + '\n\n', '', 1).replace(START17, START16, 1)
    if restored != src:
        raise RuntimeError('R17 reversible transformation check failed')
    return out

def fixture():
    return r'''mapState={}
self={cell='fixture'}
mapState.testMode='stair'
mapState.testStats={count=40,connectors=17,floors=5,coarse=false}
mapState.r15StairActive=true
mapState.r16Mode='normal'; mapState.r16StableIds={1,2,3}
mapState.r16Clear = function() mapState.r16StableIds={} end
mapState.r16EffectiveMode = function() return mapState.testMode,mapState.testStats end
mapState.r13ResetSpaceAuthority=function() end
mapState.r13BaseUpdateTopologyPvs=function(force)
 mapState.baseCalls=(mapState.baseCalls or 0)+1
 if force then mapState.baseForced=(mapState.baseForced or 0)+1 end
end
mapState.updateTopologyPvs=function(force)
 mapState.r16Calls=(mapState.r16Calls or 0)+1
end
mapState.r13ObserveSpace=function() return 'normal' end
mapState.r12ResetEvidence=function() mapState.resetCalls=(mapState.resetCalls or 0)+1 end
mapState.r11SetTiers=function(xy,z,reason)
 mapState.lastXY=xy; mapState.lastZ=z; mapState.lastTierReason=reason
end
mapState.r11AuthorityReport=function() end
mapState.r12ResetEvidence()
mapState.r11SetTiers(1,1,'fixture-precondition')
-- TSP_ROOMRAY_LUA_V30_R16_SINGLE_WRITER_STABLE_TRANSITION
print('[TSP_ROOMRAY_R16] enabled single-writer stable-union coarse-multilevel=8..20/2-connectors stairCap=32')
mapState.r16LowerUpdate = mapState.updateTopologyPvs
mapState.r13BaseAuthorityReport = mapState.r11AuthorityReport
for i=1,4 do -- mapState.r11CastDirection(eye,
end

-- A deep centre alone must never claim broad room/stair authority.
local proof=mapState.r17OpeningProof({100,1000,120,150})
assert(not proof,'centre-only depth incorrectly proved broad volume')
for i=1,5 do mapState.r13ObserveSpace({100,1000,120,150},'vertical_connector') end
assert(not mapState.r17NarrowActive,'narrow passage contracted before six samples')
mapState.r13ObserveSpace({100,1000,120,150},'vertical_connector')
assert(mapState.r17NarrowActive and not mapState.r17GateOpen,
 'six sustained centre-deep/side-shallow samples did not enter narrow mode')
assert(mapState.lastXY==3 and mapState.lastZ==4
 and mapState.lastTierReason=='r17-r2-narrow-passage',
 'narrow passage did not select tier 3/4')
assert((mapState.baseCalls or 0)>=1 and mapState.r16Calls==nil,
 'narrow passage did not use direct R4 topology')

-- One real side opening cancels narrow mode and restores R16 immediately.
mapState.r13ObserveSpace({700,1000,120,150},'vertical_connector')
assert(not mapState.r17NarrowActive and mapState.r17GateOpen,
 'side opening did not immediately release narrow mode')
assert(mapState.r16Calls==1,'side opening did not restore R16 writer')

-- Existing grace and blank-wall contraction remain intact.
for i=1,19 do mapState.r13ObserveSpace({100,110,120,90},'vertical_connector') end
assert(mapState.r17GateOpen and not mapState.r17BlankActive,
 'four-second grace contracted early')
mapState.r13ObserveSpace({100,110,120,90},'vertical_connector')
assert(not mapState.r17GateOpen and mapState.r17BlankActive,
 'sustained blank wall did not close gate and clamp')
assert(mapState.lastXY==4 and mapState.lastZ==4
 and mapState.lastTierReason=='r17-blank-wall','blank tier 4/4 missing')

-- The same narrow classifier applies to an ordinary hallway, not only stairs.
mapState.r13ResetSpaceAuthority()
mapState.testMode='normal'
for i=1,6 do mapState.r13ObserveSpace({120,900,100,140},'ordinary_room') end
assert(mapState.r17NarrowActive and mapState.lastXY==3 and mapState.lastZ==4,
 'ordinary hallway did not enter narrow policy')

-- Coarse multi-level topology is permanently protected from contraction.
mapState.testMode='coarse-multilevel'
local coarseCalls=mapState.r16Calls or 0
mapState.r13ObserveSpace({100,1000,120,150},'large_open')
assert(not mapState.r17NarrowActive,'coarse multi-level entered narrow policy')
assert(mapState.r16Calls==coarseCalls+1,
 'coarse multi-level transition did not publish through R16')
mapState.updateTopologyPvs(true)
assert(mapState.r16Calls==coarseCalls+2,'coarse multi-level protection was gated')
print('R17_R2_BEHAVIOR_PASS')'''

if len(sys.argv) == 2 and sys.argv[1] == '--selftest':
    out = patch(fixture())
    Path('/tmp/roomwake-r17-r2-selftest.lua').write_text(out)
    print('PASS R17-R2 structural selftest: broad/narrow/blank dual extremes')
elif len(sys.argv) == 3:
    src = Path(sys.argv[1]).read_text()
    Path(sys.argv[2]).write_text(patch(src))
    print('PASS R17-R2 Lua generated from exact pulled R16 input')
else:
    raise SystemExit('usage: patch_r17_r2.py INPUT OUTPUT | --selftest')
PY_R17
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
        docker cp "$file" "$CTR:/tmp/visgrid-r17-check.lua" >/dev/null \
            || fail 31 "could not stage Lua syntax check"
        local parser
        parser="$(docker exec "$CTR" bash -lc 'for x in luajit lua texlua; do command -v "$x" >/dev/null 2>&1 && { echo "$x"; exit 0; }; done; exit 1' 2>/dev/null || true)"
        if [ -n "$parser" ]; then
            docker exec "$CTR" "$parser" -e "local f,e=loadfile('/tmp/visgrid-r17-check.lua'); assert(f,e)" \
                || fail 31 "Docker Lua syntax failed: $file"
            echo "PASS Docker Lua syntax: $file"
            return
        fi
        if docker exec "$CTR" test -x /tmp/r13_lua_check \
            && docker exec "$CTR" /tmp/r13_lua_check /tmp/visgrid-r17-check.lua; then
            echo "PASS Docker LuaJIT syntax: $file"
            return
        fi
    fi
    fail 31 "no working Lua parser available"
}

selftest_action() {
    need python3
    make_patcher
    python3 -m py_compile "$TMP/patch_r17_r2.py" \
        || fail 30 "embedded R17-R2 Python does not compile"
    python3 "$TMP/patch_r17_r2.py" --selftest \
        || fail 30 "R17-R2 structural selftest failed"
    syntax_check /tmp/roomwake-r17-r2-selftest.lua
    if command -v texlua >/dev/null 2>&1; then
        texlua /tmp/roomwake-r17-r2-selftest.lua | grep -Fq R17_R2_BEHAVIOR_PASS \
            || fail 30 "R17-R2 executable behavior selftest failed"
        echo "PASS R17-R2 executable behavior selftest"
    elif command -v lua >/dev/null 2>&1; then
        lua /tmp/roomwake-r17-r2-selftest.lua | grep -Fq R17_R2_BEHAVIOR_PASS \
            || fail 30 "R17-R2 executable behavior selftest failed"
        echo "PASS R17-R2 executable behavior selftest"
    fi
}

restore_backup() {
    local backup="$1"
    [ -n "$backup" ] || return 1
    ssh "$DEV" 'bash -s' -- "$backup" "$LUA" "$PROFILE" "$EXPECTED_R16_LUA_SHA" <<'REMOTE_RESTORE'
set -u
B="$1"; LIVE="$2"; PROFILE="$3"; EXPECTED="$4"
for f in "$B/visgrid.lua.before-r17-r2" "$B/profile.lua.before-r17-r2"; do
    [ -s "$f" ] || exit 1
    [ "$(sha256sum "$f" | awk '{print $1}')" = "$EXPECTED" ] || exit 2
done
install -m 644 "$B/visgrid.lua.before-r17-r2" "$LIVE" || exit 3
install -m 644 "$B/profile.lua.before-r17-r2" "$PROFILE" || exit 4
sync
for f in "$LIVE" "$PROFILE"; do
    [ "$(sha256sum "$f" | awk '{print $1}')" = "$EXPECTED" ] || exit 5
done
echo "PASS exact validated R16 Lua/profile restored"
REMOTE_RESTORE
}

collect_action() {
    ensure_ssh
    local out="$DL/openmw51-roomwake-r17-r2-validation-$STAMP.txt"
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
    ssh "$DEV" "grep -nE 'TSP_ROOMRAY_LUA_V30_R1[34567]|\[TSP_ROOMRAY_R1[34567]\] enabled' '$LUA'" \
        > "$TMP/markers.txt" 2>&1 || true
    local tag_count
    tag_count="$(sed -n "${start},${total}p" "$TMP/openmw.log" | grep -c '\[TSP_ROOMRAY_R17_R2\]' || true)"
    {
        printf '%s\n' '===== OPENMW 0.51 V30 R17-R2 DUAL-EXTREME ROOM AWARENESS VALIDATION ====='
        date
        printf 'Binary SHA: %s\n' "$(remote_sha "$BIN")"
        printf 'Lua SHA:    %s\n' "$(remote_sha "$LUA")"
        printf 'Profile:    %s\n' "$(remote_sha "$PROFILE")"
        printf 'Log lines: total=%s capture=%s..%s R17_R2_tags=%s\n\n' "$total" "$start" "$total" "$tag_count"
        printf '%s\n' '===== LIVE LUA MARKERS ====='
        cat "$TMP/markers.txt"
        printf '\n%s\n' '===== FILTERED TEST WINDOW ====='
        sed -n "${start},${total}p" "$TMP/openmw.log" \
            | grep -E '\[TSP_ROOMRAY_R17_R2\]|\[TSP_ROOMRAY_R16\]|\[TSP_ROOMRAY_R15\]|\[TSP_ROOMRAY_R14\]|\[TSP_ROOMRAY_R13\]|\[TSP_ROOMRAY_R12\]|\[TSP_ROOMRAY_R11\]|\[TSP_ROOMOBJ_V30\]|\[TSP_VISGRID_V30_R4\]|\[TSP_ACTOR_V30\]|Lua.*error|failed to render' \
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
    echo "PASS R17-R2 validation: $out"
    echo "Upload that file for review."
}

rollback_action() {
    ensure_ssh
    [ -s "$STATE" ] || fail 22 "R17 rollback state missing: $STATE"
    local backup new_sha
    backup="$(state_value "$STATE" R17_DEVICE_BACKUP)"
    new_sha="$(state_value "$STATE" R17_NEW_LUA_SHA)"
    valid_sha "$new_sha" || fail 22 "R17 rollback SHA invalid"
    [ "$(remote_sha "$BIN")" = "$EXPECTED_BIN_SHA" ] \
        || fail 23 "binary changed; refusing Lua-only rollback"
    [ "$(remote_sha "$LUA")" = "$new_sha" ] \
        || fail 23 "live Lua is not exact installed R17"
    [ "$(remote_sha "$PROFILE")" = "$new_sha" ] \
        || fail 23 "profile Lua is not exact installed R17"
    restore_backup "$backup" || fail 24 "could not restore exact R16"
    echo "PASS R17 rollback complete; exact validated R16 restored."
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
OPENMW 0.51 — ROOMWAKE V30 R17-R2
DUAL-EXTREME ROOM AWARENESS
============================================================
R16's Ald-ruhn coarse multi-floor protection is unchanged.
R16's single-writer monotonic transition mask is unchanged when enabled.

OPEN / LARGE END:
  OPEN immediately if 2 forward rays >=450,
                      either side ray >=520, or upward ray >=550.
  A long center ray alone does not claim a large room.
  HOLD through 20 no-proof samples (approximately 4 seconds).
  CLOSED uses the exact R4 base topology mask, bypassing R13-R16 widening.

NARROW PASSAGE END:
  Center >=650 while both sides <=360 and upward <=450
  for 6 samples selects exact R4 topology plus XY/Z tier 3/4.
  A side >=520, upward >=550, or protected topology releases immediately.

BLANK WALL:
  All 3 forward rays <=400 and upward <=400 for 6 samples
  forces exact tier 4/4 plus the direct R4 mask.

Exactly the existing four rays. No new casts or launcher.
No C++ rebuild, binary replacement, or general distance change.
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
echo "===== 1/6 VERIFY EXACT VALIDATED R16 STATE ====="
BIN_SHA="$(remote_sha "$BIN")"
LUA_SHA="$(remote_sha "$LUA")"
PROFILE_SHA="$(remote_sha "$PROFILE")"
if [ -s "$STATE" ]; then
    KNOWN="$(state_value "$STATE" R17_NEW_LUA_SHA)"
    if valid_sha "$KNOWN" && [ "$BIN_SHA" = "$EXPECTED_BIN_SHA" ] \
        && [ "$LUA_SHA" = "$KNOWN" ] && [ "$PROFILE_SHA" = "$KNOWN" ] \
        && ssh "$DEV" "grep -Fq 'TSP_ROOMRAY_LUA_V30_R17_R2_DUAL_EXTREMES' '$LUA'"; then
        echo "PASS exact R17-R2 already installed: $KNOWN"
        echo "Use '$0 collect' after testing; no reinstall is needed."
        exit 0
    fi
fi
[ "$BIN_SHA" = "$EXPECTED_BIN_SHA" ] || {
    echo "EXPECTED BIN: $EXPECTED_BIN_SHA" >&2
    echo "ACTUAL BIN:   $BIN_SHA" >&2
    fail 33 "device binary is not the exact validated R16 binary"
}
[ "$LUA_SHA" = "$EXPECTED_R16_LUA_SHA" ] \
    && [ "$PROFILE_SHA" = "$EXPECTED_R16_LUA_SHA" ] || {
    echo "EXPECTED R16 LUA: $EXPECTED_R16_LUA_SHA" >&2
    echo "ACTUAL LIVE:      $LUA_SHA" >&2
    echo "ACTUAL PROFILE:   $PROFILE_SHA" >&2
    fail 34 "device is not on the exact submitted R16 Lua/profile"
}
ssh "$DEV" "grep -Fq 'TSP_ROOMRAY_LUA_V30_R16_SINGLE_WRITER_STABLE_TRANSITION' '$LUA' && ! grep -Fq 'TSP_ROOMRAY_LUA_V30_R17_R2_DUAL_EXTREMES' '$LUA'" \
    || fail 34 "R16/R17-R2 marker shape is not the exact pre-R17-R2 state"
echo "PASS exact submitted R16 binary: $BIN_SHA"
echo "PASS exact submitted R16 Lua:    $LUA_SHA"

echo
echo "===== 2/6 BACK UP EXACT R16 LUA/PROFILE ====="
DEVICE_BACKUP="$ROOT/backups/roomwake-v30-r17-r2-dual-extremes-$STAMP"
if ! ssh "$DEV" 'bash -s' -- "$DEVICE_BACKUP" "$LUA" "$PROFILE" "$EXPECTED_R16_LUA_SHA" <<'REMOTE_BACKUP'
set -u
B="$1"; LIVE="$2"; PROFILE="$3"; EXPECTED="$4"
mkdir -p "$B" || exit 1
for f in "$LIVE" "$PROFILE"; do
    [ -s "$f" ] || exit 2
    [ "$(sha256sum "$f" | awk '{print $1}')" = "$EXPECTED" ] || exit 3
done
cp -p "$LIVE" "$B/visgrid.lua.before-r17-r2" || exit 4
cp -p "$PROFILE" "$B/profile.lua.before-r17-r2" || exit 5
sync
echo "PASS R17 device backup: $B"
REMOTE_BACKUP
then
    fail 35 "R17 device backup failed"
fi
scp -q "$DEV:$LUA" "$TMP/visgrid-r16.lua" || fail 36 "could not pull R16 Lua"
[ "$(sha256sum "$TMP/visgrid-r16.lua" | awk '{print $1}')" = "$EXPECTED_R16_LUA_SHA" ] \
    || fail 36 "pulled R16 Lua SHA changed after preflight"

echo
echo "===== 3/6 GENERATE + VERIFY R17-R2 BEFORE DEVICE MUTATION ====="
make_patcher
python3 -m py_compile "$TMP/patch_r17_r2.py" || fail 37 "R17-R2 Python compile failed"
python3 "$TMP/patch_r17_r2.py" "$TMP/visgrid-r16.lua" "$TMP/visgrid-r17.lua" \
    || fail 38 "R17-R2 transformation failed before device mutation"
syntax_check "$TMP/visgrid-r17.lua"
python3 - "$TMP/visgrid-r16.lua" "$TMP/visgrid-r17.lua" <<'PY_VERIFY'
from pathlib import Path
import sys
a=Path(sys.argv[1]).read_text(); b=Path(sys.argv[2]).read_text()
for token in ('TSP_ROOMRAY_LUA_V30_R17_R2_DUAL_EXTREMES',
              'mapState.r17ExposureHoldSamples = 20',
              'mapState.r17BlankRequired = 6',
              'mapState.r17NarrowRequired = 6',
              'mapState.r13BaseUpdateTopologyPvs(restore)',
              "mapState.r11SetTiers(4, 4, 'r17-blank-wall'",
              "mapState.r11SetTiers(3, 4, 'r17-r2-narrow-passage'",
              '[TSP_ROOMRAY_R17_R2] state mode='):
    if token not in b: raise SystemExit('FAIL missing R17-R2 semantic token: '+token)
if b.count('mapState.r11CastDirection(eye,') != a.count('mapState.r11CastDirection(eye,'):
    raise SystemExit('FAIL R17 changed the exact four-ray call count')
if b.count('TSP_ROOMRAY_LUA_V30_R17_R2_DUAL_EXTREMES') != 1:
    raise SystemExit('FAIL R17-R2 marker is not unique')
if 'TSP_ROOMRAY_LUA_V30_R16_SINGLE_WRITER_STABLE_TRANSITION' not in b:
    raise SystemExit('FAIL exact R16 lineage missing')
print('PASS R17-R2 semantic verify: exact R16 retained; four rays unchanged; marker unique')
PY_VERIFY
[ "$?" -eq 0 ] || fail 39 "R17-R2 semantic verification failed"
R17_SHA="$(sha256sum "$TMP/visgrid-r17.lua" | awk '{print $1}')"
echo "PASS generated R17-R2 Lua SHA: $R17_SHA"

echo
echo "===== 4/6 INSTALL LUA/PROFILE TRANSACTIONALLY ====="
scp -q "$TMP/visgrid-r17.lua" "$DEV:/tmp/visgrid-r17.lua" \
    || { restore_backup "$DEVICE_BACKUP" || true; fail 40 "R17 upload failed"; }
if ! ssh "$DEV" 'bash -s' -- /tmp/visgrid-r17.lua "$R17_SHA" "$LUA" "$PROFILE" "$BIN" "$EXPECTED_BIN_SHA" <<'REMOTE_INSTALL'
set -u
STAGED="$1"; EXPECTED="$2"; LIVE="$3"; PROFILE="$4"; BIN="$5"; EXPECTED_BIN="$6"
[ -s "$STAGED" ] || exit 1
[ "$(sha256sum "$STAGED" | awk '{print $1}')" = "$EXPECTED" ] || exit 2
[ "$(sha256sum "$BIN" | awk '{print $1}')" = "$EXPECTED_BIN" ] || exit 3
grep -Fq 'TSP_ROOMRAY_LUA_V30_R17_R2_DUAL_EXTREMES' "$STAGED" || exit 4
install -m 644 "$STAGED" "$PROFILE" || exit 5
install -m 644 "$STAGED" "$LIVE" || exit 6
sync
for f in "$PROFILE" "$LIVE"; do
    [ "$(sha256sum "$f" | awk '{print $1}')" = "$EXPECTED" ] || exit 7
done
rm -f "$STAGED"
echo "PASS installed exact R17-R2 Lua/profile; binary unchanged"
REMOTE_INSTALL
then
    restore_backup "$DEVICE_BACKUP" || true
    fail 41 "R17 install failed; exact R16 restoration attempted"
fi

echo
echo "===== 5/6 VERIFY FINAL DEVICE STATE ====="
FINAL_BIN="$(remote_sha "$BIN")"
FINAL_LUA="$(remote_sha "$LUA")"
FINAL_PROFILE="$(remote_sha "$PROFILE")"
if [ "$FINAL_BIN" != "$EXPECTED_BIN_SHA" ] || [ "$FINAL_LUA" != "$R17_SHA" ] \
    || [ "$FINAL_PROFILE" != "$R17_SHA" ]; then
    restore_backup "$DEVICE_BACKUP" || true
    fail 42 "R17 final verification failed; exact R16 restoration attempted"
fi
echo "PASS binary unchanged: $FINAL_BIN"
echo "PASS exact R17-R2 Lua/profile: $FINAL_LUA"

echo
echo "===== 6/6 ARM CAPTURE + SAVE ROLLBACK STATE ====="
if ! ssh "$DEV" 'bash -s' -- "$GAMELOG" "$ARM" <<'REMOTE_ARM'
set -u
LOG="$1"; ARM="$2"
[ -f "$LOG" ] || exit 1
LINES="$(wc -l < "$LOG" | tr -d '[:space:]')"
case "$LINES" in ''|*[!0-9]*) exit 2;; esac
printf '%s\n' "$LINES" > "$ARM" || exit 3
echo "PASS R17 capture armed after log line: $LINES"
REMOTE_ARM
then
    restore_backup "$DEVICE_BACKUP" || true
    fail 43 "capture arm failed; exact R16 restoration attempted"
fi
cat > "$STATE" <<EOF_STATE
R17_DEVICE_BACKUP='$DEVICE_BACKUP'
R17_OLD_BIN_SHA='$EXPECTED_BIN_SHA'
R17_OLD_LUA_SHA='$EXPECTED_R16_LUA_SHA'
R17_NEW_LUA_SHA='$R17_SHA'
EOF_STATE
[ -s "$STATE" ] || {
    restore_backup "$DEVICE_BACKUP" || true
    fail 44 "state write failed; exact R16 restoration attempted"
}

echo
echo "============================================================"
echo "V30 R17-R2 DUAL-EXTREME ROOM AWARENESS INSTALLED"
echo "============================================================"
echo "Binary unchanged: $FINAL_BIN"
echo "R16 Lua:          $EXPECTED_R16_LUA_SHA"
echo "R17-R2 Lua:       $FINAL_LUA"
echo
echo "Test once each:"
echo "  1. Caldera Governor's Hall staircase facing the blank wall."
echo "  2. Balmora Mages Guild staircase."
echo "  3. Ald-ruhn Manor District hall."
echo "Collect:"
echo "  cd ~/Downloads"
echo "  ./apply_openmw51_tsp_roomwake_v30_R17_R2_dual_extremes.sh collect"
echo
echo "Rollback to exact submitted R16:"
echo "  ./apply_openmw51_tsp_roomwake_v30_R17_R2_dual_extremes.sh rollback"
echo "Controller log: $RUNLOG"
echo "============================================================"
