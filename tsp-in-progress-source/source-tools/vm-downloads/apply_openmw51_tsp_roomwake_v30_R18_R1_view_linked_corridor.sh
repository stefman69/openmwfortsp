#!/usr/bin/env bash
# OpenMW 0.51 / TrimUI Smart Pro
# V30 R18-R1: view-linked open-space continuity for narrow Vivec corridors.
#
# LUA/PROFILE ONLY. No C++ rebuild, binary replacement, launcher change, or
# additional raycast. Actions: install (default), collect, rollback, selftest

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
ARM="$ROOT/roomwake-r18-r1-capture-start.line"

EXPECTED_BIN_SHA="e25f6edfe90c6610be94b285a243d7d2b673a7412ac504a026f14976332a3fab"
EXPECTED_R17_LUA_SHA="4940cc0632e4d0d99f8588b2bbd1ce10670fbbb33dfa9c679e5801b6ea40225b"

DL="${OPENMW_DOWNLOADS_DIR:-$HOME/Downloads}"
STATE="$DL/openmw51-roomwake-r18-r1.state"
STAMP="$(date +%Y%m%d-%H%M%S)"
RUNLOG="$DL/openmw51-roomwake-r18-r1-$STAMP.log"
[ -d "$DL" ] || { echo "ERROR: downloads directory missing: $DL" >&2; exit 9; }
TMP="$(mktemp -d "$DL/.roomwake-r18.XXXXXX")" \
    || { echo "ERROR: could not create R18 temporary directory" >&2; exit 9; }
[ -n "$TMP" ] && [ -d "$TMP" ] \
    || { echo "ERROR: invalid R18 temporary directory" >&2; exit 9; }

DEVICE_BACKUP=""
DEVICE_MUTATED=0
INSTALL_COMPLETE=0

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

restore_backup() {
    local backup="$1"
    [ -n "$backup" ] || return 1
    ssh "$DEV" 'bash -s' -- "$backup" "$LUA" "$PROFILE" "$EXPECTED_R17_LUA_SHA" <<'REMOTE_RESTORE'
set -u
B="$1"; LIVE="$2"; PROFILE="$3"; EXPECTED="$4"
for f in "$B/visgrid.lua.before-r18-r1" "$B/profile.lua.before-r18-r1"; do
    [ -s "$f" ] || exit 1
    [ "$(sha256sum "$f" | awk '{print $1}')" = "$EXPECTED" ] || exit 2
done
install -m 644 "$B/visgrid.lua.before-r18-r1" "$LIVE" || exit 3
install -m 644 "$B/profile.lua.before-r18-r1" "$PROFILE" || exit 4
sync
for f in "$LIVE" "$PROFILE"; do
    [ "$(sha256sum "$f" | awk '{print $1}')" = "$EXPECTED" ] || exit 5
done
echo "PASS exact validated R17-R2 Lua/profile restored"
REMOTE_RESTORE
}

recover_now() {
    if [ "$DEVICE_MUTATED" -eq 1 ] && [ -n "$DEVICE_BACKUP" ]; then
        restore_backup "$DEVICE_BACKUP" || return 1
        DEVICE_MUTATED=0
    fi
    return 0
}

cleanup() {
    local rc=$?
    trap - EXIT INT TERM
    if [ "$DEVICE_MUTATED" -eq 1 ] && [ "$INSTALL_COMPLETE" -eq 0 ] \
        && [ -n "$DEVICE_BACKUP" ]; then
        echo "INFO: unexpected exit after mutation; restoring exact R17-R2..." >&2
        restore_backup "$DEVICE_BACKUP" || \
            echo "ERROR: automatic R17-R2 restoration failed" >&2
    fi
    if [ -n "$TMP" ] && [ -d "$TMP" ]; then rm -rf "$TMP"; fi
    exit "$rc"
}
trap cleanup EXIT INT TERM

make_patcher() {
cat > "$TMP/patch_r18_r1.py" <<'PY_R18'
from pathlib import Path
import sys

MARK17 = 'TSP_ROOMRAY_LUA_V30_R17_R2_DUAL_EXTREMES'
MARK18 = 'TSP_ROOMRAY_LUA_V30_R18_R1_VIEW_LINKED_CORRIDOR'
ANCHOR = 'mapState.r13BaseAuthorityReport = mapState.r11AuthorityReport'
START17 = "print('[TSP_ROOMRAY_R17_R2] enabled broad=fast narrow=6-sample-R4-tier3/4 blank=R4-tier4 coarse/atrium=unchanged')"
START18 = START17 + "\nprint('[TSP_ROOMRAY_R18_R1] enabled view-link=large-open+forward>=900 topologyHold=12 witnessHold=10 adaptive-light-depth')"

R18 = r'''-- TSP_ROOMRAY_LUA_V30_R18_R1_VIEW_LINKED_CORRIDOR
-- R17-R2 correctly recognizes a centre-deep/side-shallow passage, but the
-- Vivec trace proved that the same shape can be a hallway visibly connected
-- to a large-open sector. R17 contracted an 18-sector R16 stable mask to four
-- R4 sectors and all five actors slept. R18 combines the existing ray result
-- with navmesh large-open adjacency. It adds no raycasts. A recent combined
-- witness lets R16 retain continuity while light/object distance tiers follow
-- only the depth actually seen. Reports decay and are wiped on cell change.
mapState.r18TopologyHold = 0
mapState.r18TopologyHoldSamples = 12
mapState.r18WitnessHold = 0
mapState.r18WitnessHoldSamples = 10
mapState.r18ForwardMinimum = 900.0
mapState.r18ForwardDepth = 0.0
mapState.r18UpDepth = 0.0
mapState.r18CorridorActive = false
mapState.r18TopologyNow = false
mapState.r18LastLongest = 0.0
mapState.r18LastUp = 0.0

mapState.r18Clear = function()
    mapState.r18TopologyHold = 0
    mapState.r18WitnessHold = 0
    mapState.r18ForwardDepth = 0.0
    mapState.r18UpDepth = 0.0
    mapState.r18CorridorActive = false
    mapState.r18TopologyNow = false
    mapState.r18LastLongest = 0.0
    mapState.r18LastUp = 0.0
end

mapState.r18SharedTopology = function()
    local _, _, _, currentSec = mapState.r15Current()
    local kind = tostring(currentSec and currentSec.kind or 'room')
    local x = tonumber(mapState.topoX or 0) or 0
    local y = tonumber(mapState.topoY or 0) or 0
    return kind == 'large_open' or mapState.r15NearbyLargeOpen(x, y)
end

mapState.r18UpdateWitness = function(distances)
    local left = tonumber(distances and distances[1] or 0) or 0
    local center = tonumber(distances and distances[2] or 0) or 0
    local right = tonumber(distances and distances[3] or 0) or 0
    local up = tonumber(distances and distances[4] or 0) or 0
    local longest = math.max(left, center, right)
    local topology = mapState.r18SharedTopology()
    mapState.r18TopologyNow = topology
    mapState.r18LastLongest = longest
    mapState.r18LastUp = up
    if topology then
        mapState.r18TopologyHold = mapState.r18TopologyHoldSamples
    else
        mapState.r18TopologyHold = math.max(0, mapState.r18TopologyHold - 1)
    end
    if mapState.r18TopologyHold > 0 and longest >= mapState.r18ForwardMinimum then
        mapState.r18WitnessHold = mapState.r18WitnessHoldSamples
        mapState.r18ForwardDepth = math.max(longest, mapState.r18ForwardDepth * 0.88)
        mapState.r18UpDepth = math.max(up, mapState.r18UpDepth * 0.88)
    else
        mapState.r18WitnessHold = math.max(0, mapState.r18WitnessHold - 1)
        mapState.r18ForwardDepth = mapState.r18ForwardDepth * 0.88
        mapState.r18UpDepth = mapState.r18UpDepth * 0.88
    end
    mapState.r18CorridorActive = mapState.r18WitnessHold > 0
    return mapState.r18CorridorActive
end

mapState.r18DepthTiers = function()
    local depth = tonumber(mapState.r18ForwardDepth or 0) or 0
    local up = tonumber(mapState.r18UpDepth or 0) or 0
    local xy = 3
    if depth > 2100.0 then xy = 0
    elseif depth > 1650.0 then xy = 1
    elseif depth > 1200.0 then xy = 2 end
    local z = 3
    if up > 416.0 then z = 0
    elseif up > 336.0 then z = 1
    elseif up > 256.0 then z = 2 end
    return xy, z
end

-- R18 updates its combined witness before R17 asks these two classifiers.
-- Active view-link evidence is an opening for continuity, but it does not
-- force R17's full open distance table; the outer observer sets bounded tiers.
mapState.r18R17OpeningProof = mapState.r17OpeningProof
mapState.r17OpeningProof = function(distances)
    local proof, count, longest, up, side = mapState.r18R17OpeningProof(distances)
    if mapState.r18CorridorActive then
        return true, math.max(2, count), longest, up, side
    end
    return proof, count, longest, up, side
end

mapState.r18R17NarrowEvidence = mapState.r17NarrowEvidence
mapState.r17NarrowEvidence = function(distances)
    local candidate, release, left, center, right, up =
        mapState.r18R17NarrowEvidence(distances)
    if mapState.r18CorridorActive then
        return false, true, left, center, right, up
    end
    return candidate, release, left, center, right, up
end

mapState.r18R17Reset = mapState.r13ResetSpaceAuthority
mapState.r13ResetSpaceAuthority = function()
    mapState.r18R17Reset()
    mapState.r18Clear()
end

mapState.r18R17Observe = mapState.r13ObserveSpace
mapState.r13ObserveSpace = function(distances, kind)
    local oldActive = mapState.r18CorridorActive
    mapState.r18UpdateWitness(distances)
    local action = mapState.r18R17Observe(distances, kind)
    if mapState.r18CorridorActive then
        local xy, z = mapState.r18DepthTiers()
        mapState.r11XYScore = 4.5 - xy
        mapState.r11ZScore = 4.5 - z
        mapState.r12ResetEvidence()
        mapState.r11SetTiers(xy, z, 'r18-view-linked-corridor', distances)
        -- R18 already supplies a decaying grace. Keep only a short R17 tail
        -- so narrow mode can return promptly when the combined proof expires.
        mapState.r17ExposureHold = math.min(
            tonumber(mapState.r17ExposureHold or 0) or 0, 8)
        mapState.r17LastReason = 'view-linked-corridor'
    end
    if oldActive ~= mapState.r18CorridorActive then
        print(string.format(
            '[TSP_ROOMRAY_R18_R1] VIEW-LINK-%s topology=%d topoHold=%d witnessHold=%d depth=%.0f up=%.0f',
            mapState.r18CorridorActive and 'ENTER' or 'EXIT',
            mapState.r18TopologyNow and 1 or 0,
            mapState.r18TopologyHold, mapState.r18WitnessHold,
            mapState.r18ForwardDepth, mapState.r18UpDepth))
    end
    return action
end

mapState.r18R17Report = mapState.r11AuthorityReport
mapState.r11AuthorityReport = function(distances)
    mapState.r18R17Report(distances)
    local xy, z = mapState.r18DepthTiers()
    print(string.format(
        '[TSP_ROOMRAY_R18_R1] state active=%d topology=%d topoHold=%d/%d witnessHold=%d/%d depth=%.0f up=%.0f tier=%d/%d raw=%.0f/%.0f',
        mapState.r18CorridorActive and 1 or 0,
        mapState.r18TopologyNow and 1 or 0,
        mapState.r18TopologyHold, mapState.r18TopologyHoldSamples,
        mapState.r18WitnessHold, mapState.r18WitnessHoldSamples,
        mapState.r18ForwardDepth, mapState.r18UpDepth, xy, z,
        mapState.r18LastLongest, mapState.r18LastUp))
end'''

def replace_once(src, old, new, label):
    count = src.count(old)
    if count != 1:
        raise RuntimeError(f'{label} matches={count} expected=1')
    return src.replace(old, new, 1)

def patch(src):
    for token in (MARK17, ANCHOR, START17,
                  'mapState.r17OpeningProof = function',
                  'mapState.r17NarrowEvidence = function',
                  'mapState.r17ExposureHoldSamples = 20',
                  'mapState.r16EffectiveMode = function',
                  'mapState.r15NearbyLargeOpen',
                  'mapState.r15Current',
                  'mapState.r12ResetEvidence()',
                  'mapState.r11SetTiers'):
        if token not in src:
            raise RuntimeError('R17-R2 precondition missing: ' + token)
    if MARK18 in src:
        raise RuntimeError('R18-R1 marker already present')
    rays = src.count('mapState.r11CastDirection(eye,')
    if rays != 4:
        raise RuntimeError(f'R17 ray call-site count={rays} expected=4')
    out = replace_once(src, ANCHOR, R18 + '\n\n' + ANCHOR,
                       'R17-to-R18 insertion anchor')
    out = replace_once(out, START17, START18, 'R17 startup anchor')
    if out.count('mapState.r11CastDirection(eye,') != rays:
        raise RuntimeError('R18 changed exact four-ray call-site count')
    for token in (MARK18, 'mapState.r18TopologyHoldSamples = 12',
                  'mapState.r18WitnessHoldSamples = 10',
                  'mapState.r18ForwardMinimum = 900.0',
                  'mapState.r18UpdateWitness', 'mapState.r18DepthTiers',
                  'mapState.r18R17OpeningProof',
                  'mapState.r18R17NarrowEvidence',
                  "'r18-view-linked-corridor'",
                  '[TSP_ROOMRAY_R18_R1] VIEW-LINK-%s',
                  '[TSP_ROOMRAY_R18_R1] state active='):
        if token not in out:
            raise RuntimeError('R18 postcondition missing: ' + token)
    restored = out.replace(R18 + '\n\n', '', 1).replace(START18, START17, 1)
    if restored != src:
        raise RuntimeError('R18 reversible transformation check failed')
    return out

def fixture():
    return r'''mapState={}
mapState.topoX=0; mapState.topoY=0
mapState.nearLarge=true
mapState.currentSec={kind='room'}
mapState.r15Current=function() return {},{},1,mapState.currentSec end
mapState.r15NearbyLargeOpen=function() return mapState.nearLarge end
mapState.r12ResetEvidence=function() mapState.resets=(mapState.resets or 0)+1 end
mapState.r12ResetEvidence()
mapState.r11SetTiers=function(xy,z,reason)
 mapState.lastXY=xy; mapState.lastZ=z; mapState.lastTierReason=reason
end
mapState.r11AuthorityReport=function() end
mapState.r13ResetSpaceAuthority=function() end
mapState.r17ExposureHoldSamples = 20
mapState.r17ExposureHold=0; mapState.r17GateOpen=false
mapState.r17NarrowActive=false; mapState.r17LastReason='fixture'
mapState.r16EffectiveMode = function() return 'stair' end
mapState.r17OpeningProof = function(d)
 local c=0
 for i=1,3 do if d[i]>=450 then c=c+1 end end
 return c>=2 or d[1]>=520 or d[3]>=520 or d[4]>=550,
  c,math.max(d[1],d[2],d[3]),d[4],math.max(d[1],d[3])
end
mapState.r17NarrowEvidence = function(d)
 local candidate=d[2]>=650 and d[1]<=360 and d[3]<=360 and d[4]<=450
 local release=d[1]>=520 or d[3]>=520 or d[4]>=550
 return candidate,release,d[1],d[2],d[3],d[4]
end
mapState.r13ObserveSpace=function(distances)
 local proof=mapState.r17OpeningProof(distances)
 local candidate,release=mapState.r17NarrowEvidence(distances)
 if release then mapState.r17NarrowActive=false
 elseif candidate then mapState.r17NarrowActive=true end
 mapState.r17GateOpen=proof
 if proof then mapState.r17ExposureHold=20 end
 return 'fixture-action'
end
-- TSP_ROOMRAY_LUA_V30_R17_R2_DUAL_EXTREMES
print('[TSP_ROOMRAY_R17_R2] enabled broad=fast narrow=6-sample-R4-tier3/4 blank=R4-tier4 coarse/atrium=unchanged')
-- mapState.r11CastDirection(eye,
-- mapState.r11CastDirection(eye,
-- mapState.r11CastDirection(eye,
-- mapState.r11CastDirection(eye,
mapState.r13BaseAuthorityReport = mapState.r11AuthorityReport

-- Centre-deep/side-shallow plus large-open adjacency is the Vivec case.
local action=mapState.r13ObserveSpace({120,1600,140,300},'room')
assert(action=='fixture-action','observer return value changed')
assert(mapState.r18CorridorActive,'combined topology/ray witness did not activate')
assert(mapState.r17GateOpen,'view-linked corridor did not protect continuity')
assert(not mapState.r17NarrowActive,'view-linked corridor entered R17 narrow mode')
assert(mapState.lastXY==2 and mapState.lastZ==2,
 'recent 1600/300 witness did not select bounded tier 2/2')
assert(mapState.lastTierReason=='r18-view-linked-corridor','R18 tier reason missing')
assert(mapState.r17ExposureHold==8,'R17 tail was not bounded to eight samples')

-- Losing the current adjacency does not flicker on one occluded sample.
mapState.nearLarge=false
mapState.r13ObserveSpace({100,120,110,100},'room')
assert(mapState.r18CorridorActive,'one occluded sample dropped recent witness')
for i=1,12 do mapState.r13ObserveSpace({100,120,110,100},'room') end
assert(not mapState.r18CorridorActive,'decayed view-link evidence did not expire')

-- A long centre ray without large-open adjacency leaves R17-R2 unchanged.
mapState.r13ResetSpaceAuthority()
mapState.nearLarge=false
mapState.r13ObserveSpace({100,1400,120,200},'room')
assert(not mapState.r18CorridorActive,'unlinked long hallway gained R18 authority')
assert(not mapState.r17GateOpen and mapState.r17NarrowActive,
 'unlinked long hallway no longer follows R17 narrow policy')

-- Reset must erase all old room evidence.
mapState.nearLarge=true
mapState.r13ObserveSpace({100,1400,120,300},'room')
assert(mapState.r18CorridorActive,'reset fixture could not reactivate')
mapState.r13ResetSpaceAuthority()
assert(not mapState.r18CorridorActive and mapState.r18TopologyHold==0
 and mapState.r18WitnessHold==0,'cell reset retained R18 evidence')
print('R18_R1_BEHAVIOR_PASS')'''

if len(sys.argv) == 2 and sys.argv[1] == '--selftest':
    output = patch(fixture())
    Path('/tmp/roomwake-r18-r1-selftest.lua').write_text(output)
    print('PASS R18-R1 structural selftest: view-linked continuity + bounded tiers')
elif len(sys.argv) == 3:
    source = Path(sys.argv[1]).read_text()
    Path(sys.argv[2]).write_text(patch(source))
    print('PASS R18-R1 Lua generated from exact pulled R17-R2 input')
else:
    raise SystemExit('usage: patch_r18_r1.py INPUT OUTPUT | --selftest')
PY_R18
}

ensure_docker_checker() {
    docker inspect "$CTR" >/dev/null 2>&1 || return 1
    if [ "$(docker inspect -f '{{.State.Running}}' "$CTR" 2>/dev/null || true)" != true ]; then
        docker start "$CTR" >/dev/null || return 1
    fi
    if docker exec "$CTR" test -x /tmp/r18_lua_check; then return 0; fi
    docker exec -i "$CTR" bash -s <<'REMOTE_CHECKER'
set -u
HEADER="$(find /usr/include /usr/local/include -type f -name lua.h -path '*luajit*' -print 2>/dev/null | head -1)"
[ -n "$HEADER" ] || { echo 'FAIL LuaJIT lua.h not found' >&2; exit 1; }
INC="$(dirname "$HEADER")"
LIB="$(find /usr/lib /usr/local/lib \( -type f -o -type l \) -name 'libluajit-5.1.so*' -print 2>/dev/null | head -1)"
[ -n "$LIB" ] || { echo 'FAIL libluajit-5.1.so not found' >&2; exit 2; }
CC=""
for c in gcc-13 gcc cc; do
    command -v "$c" >/dev/null 2>&1 && { CC="$c"; break; }
done
[ -n "$CC" ] || { echo 'FAIL no C compiler for LuaJIT checker' >&2; exit 3; }
cat > /tmp/r18_lua_check.c <<'C_CHECK'
#include <stdio.h>
#include <string.h>
#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>
int main(int argc, char **argv) {
    lua_State *L;
    int rc;
    if (argc < 2 || argc > 3) return 2;
    L = luaL_newstate();
    if (!L) return 3;
    luaL_openlibs(L);
    rc = luaL_loadfile(L, argv[1]);
    if (rc == 0 && argc == 3 && strcmp(argv[2], "run") == 0)
        rc = lua_pcall(L, 0, LUA_MULTRET, 0);
    if (rc != 0) {
        const char *msg = lua_tostring(L, -1);
        fprintf(stderr, "LUA_CHECK_FAIL: %s\n", msg ? msg : "unknown");
        lua_close(L);
        return 4;
    }
    lua_close(L);
    printf("LUA_CHECK_PASS %s\n", argv[1]);
    return 0;
}
C_CHECK
"$CC" -O2 -I"$INC" /tmp/r18_lua_check.c "$LIB" -lm -ldl -pthread -o /tmp/r18_lua_check || exit 4
REMOTE_CHECKER
}

syntax_check() {
    local file="$1" parser=""
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
    need docker
    docker inspect "$CTR" >/dev/null 2>&1 || fail 31 "Docker container missing: $CTR"
    if [ "$(docker inspect -f '{{.State.Running}}' "$CTR" 2>/dev/null || true)" != true ]; then
        docker start "$CTR" >/dev/null || fail 31 "could not start Docker parser"
    fi
    docker cp "$file" "$CTR:/tmp/visgrid-r18-check.lua" >/dev/null \
        || fail 31 "could not stage Lua syntax check"
    parser="$(docker exec "$CTR" bash -lc 'for x in luajit lua texlua; do command -v "$x" >/dev/null 2>&1 && { echo "$x"; exit 0; }; done; exit 1' 2>/dev/null || true)"
    if [ "$parser" = texlua ]; then
        docker exec "$CTR" texlua --luaconly /tmp/visgrid-r18-check.lua \
            || fail 31 "Docker texlua syntax failed: $file"
    elif [ -n "$parser" ]; then
        docker exec -e R18_LUA_FILE=/tmp/visgrid-r18-check.lua "$CTR" "$parser" -e \
            'local p=os.getenv("R18_LUA_FILE"); local f,e=loadfile(p); assert(f,e)' \
            || fail 31 "Docker Lua syntax failed: $file"
    else
        ensure_docker_checker || fail 31 "could not build LuaJIT syntax checker"
        docker exec "$CTR" /tmp/r18_lua_check /tmp/visgrid-r18-check.lua \
            || fail 31 "Docker LuaJIT syntax failed: $file"
    fi
    echo "PASS Lua syntax: $file"
}

behavior_check() {
    local file="$1" output=""
    if command -v texlua >/dev/null 2>&1; then
        output="$(texlua "$file" 2>&1)" || { echo "$output"; fail 30 "R18 behavior selftest failed"; }
    elif command -v lua >/dev/null 2>&1; then
        output="$(lua "$file" 2>&1)" || { echo "$output"; fail 30 "R18 behavior selftest failed"; }
    elif command -v luajit >/dev/null 2>&1; then
        output="$(luajit "$file" 2>&1)" || { echo "$output"; fail 30 "R18 behavior selftest failed"; }
    else
        need docker
        ensure_docker_checker || fail 30 "could not build LuaJIT behavior checker"
        docker cp "$file" "$CTR:/tmp/roomwake-r18-r1-selftest.lua" >/dev/null \
            || fail 30 "could not stage R18 behavior selftest"
        output="$(docker exec "$CTR" /tmp/r18_lua_check /tmp/roomwake-r18-r1-selftest.lua run 2>&1)" \
            || { echo "$output"; fail 30 "Docker R18 behavior selftest failed"; }
    fi
    printf '%s\n' "$output" | grep -Fq R18_R1_BEHAVIOR_PASS \
        || fail 30 "R18 behavior pass marker missing"
    echo "PASS R18-R1 executable behavior selftest"
}

selftest_action() {
    need python3
    make_patcher
    python3 -m py_compile "$TMP/patch_r18_r1.py" \
        || fail 30 "embedded R18-R1 Python does not compile"
    python3 "$TMP/patch_r18_r1.py" --selftest \
        || fail 30 "R18-R1 structural selftest failed"
    syntax_check /tmp/roomwake-r18-r1-selftest.lua
    behavior_check /tmp/roomwake-r18-r1-selftest.lua
}

collect_action() {
    ensure_ssh
    local out="$DL/openmw51-roomwake-r18-r1-validation-$STAMP.txt"
    local total start tag_count
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
    ssh "$DEV" "grep -nE 'TSP_ROOMRAY_LUA_V30_R1[345678]|\[TSP_ROOMRAY_R1[345678].*enabled' '$LUA'" \
        > "$TMP/markers.txt" 2>&1 || true
    tag_count="$(sed -n "${start},${total}p" "$TMP/openmw.log" | grep -c '\[TSP_ROOMRAY_R18_R1\]' || true)"
    {
        printf '%s\n' '===== OPENMW 0.51 V30 R18-R1 VIEW-LINKED CORRIDOR VALIDATION ====='
        date
        printf 'Binary SHA: %s\n' "$(remote_sha "$BIN")"
        printf 'Lua SHA:    %s\n' "$(remote_sha "$LUA")"
        printf 'Profile:    %s\n' "$(remote_sha "$PROFILE")"
        printf 'Log lines: total=%s capture=%s..%s R18_R1_tags=%s\n\n' "$total" "$start" "$total" "$tag_count"
        printf '%s\n' '===== LIVE LUA MARKERS ====='
        cat "$TMP/markers.txt"
        printf '\n%s\n' '===== FILTERED TEST WINDOW ====='
        sed -n "${start},${total}p" "$TMP/openmw.log" \
            | grep -E '\[TSP_ROOMRAY_R18_R1\]|\[TSP_ROOMRAY_R17_R2\]|\[TSP_ROOMRAY_R16\]|\[TSP_ROOMRAY_R15\]|\[TSP_ROOMRAY_R14\]|\[TSP_ROOMRAY_R13\]|\[TSP_ROOMRAY_R12\]|\[TSP_ROOMRAY_R11\]|\[TSP_ROOMOBJ_V30\]|\[TSP_VISGRID_V30_R4\]|\[TSP_ACTOR_V30\]|Lua.*error|failed to render' \
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
    echo "PASS R18-R1 validation: $out"
    echo "Upload that file for review."
}

rollback_action() {
    ensure_ssh
    [ -s "$STATE" ] || fail 22 "R18 rollback state missing: $STATE"
    local backup new_sha
    backup="$(state_value "$STATE" R18_DEVICE_BACKUP)"
    new_sha="$(state_value "$STATE" R18_NEW_LUA_SHA)"
    valid_sha "$new_sha" || fail 22 "R18 rollback SHA invalid"
    [ "$(remote_sha "$BIN")" = "$EXPECTED_BIN_SHA" ] \
        || fail 23 "binary changed; refusing Lua-only rollback"
    [ "$(remote_sha "$LUA")" = "$new_sha" ] \
        || fail 23 "live Lua is not exact installed R18-R1"
    [ "$(remote_sha "$PROFILE")" = "$new_sha" ] \
        || fail 23 "profile Lua is not exact installed R18-R1"
    restore_backup "$backup" || fail 24 "could not restore exact R17-R2"
    echo "PASS R18 rollback complete; exact validated R17-R2 restored."
}

case "$ACTION" in
    selftest) selftest_action; INSTALL_COMPLETE=1; exit 0;;
    collect) collect_action; INSTALL_COMPLETE=1; exit 0;;
    rollback) rollback_action; INSTALL_COMPLETE=1; exit 0;;
    install) ;;
    *) fail 2 "usage: $0 [install|collect|rollback|selftest]";;
esac

exec > >(tee "$RUNLOG") 2>&1

cat <<'BANNER'
============================================================
OPENMW 0.51 — ROOMWAKE V30 R18-R1
VIEW-LINKED OPEN-SPACE CORRIDOR CONTINUITY
============================================================
Vivec trace diagnosis:
  R17 narrow entry replaced an 18-sector mask with 4 R4 sectors.
  All 5 actors slept; ordinary residency fell from 68 to 8..16.
  A later second long ray restored the mask and woke all 5 actors.

R18 view link requires BOTH:
  - current/recent navmesh adjacency to a large_open sector, and
  - a current/recent forward witness of at least 900 units.

While linked:
  - R16 continuity stays active for lights and actors.
  - XY/Z tiers follow only the recently witnessed forward/up depth.
  - witness depth decays and the authority expires automatically.

Caldera blank-wall and unlinked narrow-hall policies are unchanged.
Exactly the existing 4 rays at 0.20 seconds. No C++ or launcher change.
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
echo "===== 1/6 VERIFY EXACT VALIDATED R17-R2 STATE ====="
BIN_SHA="$(remote_sha "$BIN")"
LUA_SHA="$(remote_sha "$LUA")"
PROFILE_SHA="$(remote_sha "$PROFILE")"
if [ -s "$STATE" ]; then
    KNOWN="$(state_value "$STATE" R18_NEW_LUA_SHA)"
    if valid_sha "$KNOWN" && [ "$BIN_SHA" = "$EXPECTED_BIN_SHA" ] \
        && [ "$LUA_SHA" = "$KNOWN" ] && [ "$PROFILE_SHA" = "$KNOWN" ] \
        && ssh "$DEV" "grep -Fq 'TSP_ROOMRAY_LUA_V30_R18_R1_VIEW_LINKED_CORRIDOR' '$LUA'"; then
        echo "PASS exact R18-R1 already installed: $KNOWN"
        echo "Use '$0 collect' after testing; no reinstall is needed."
        INSTALL_COMPLETE=1
        exit 0
    fi
fi
[ "$BIN_SHA" = "$EXPECTED_BIN_SHA" ] || {
    echo "EXPECTED BIN: $EXPECTED_BIN_SHA" >&2
    echo "ACTUAL BIN:   $BIN_SHA" >&2
    fail 33 "device binary is not the exact validated R17-R2 binary"
}
[ "$LUA_SHA" = "$EXPECTED_R17_LUA_SHA" ] \
    && [ "$PROFILE_SHA" = "$EXPECTED_R17_LUA_SHA" ] || {
    echo "EXPECTED R17-R2 LUA: $EXPECTED_R17_LUA_SHA" >&2
    echo "ACTUAL LIVE:         $LUA_SHA" >&2
    echo "ACTUAL PROFILE:      $PROFILE_SHA" >&2
    fail 34 "device is not on the exact validated R17-R2 Lua/profile"
}
ssh "$DEV" "grep -Fq 'TSP_ROOMRAY_LUA_V30_R17_R2_DUAL_EXTREMES' '$LUA' && ! grep -Fq 'TSP_ROOMRAY_LUA_V30_R18_R1_VIEW_LINKED_CORRIDOR' '$LUA'" \
    || fail 34 "R17-R2/R18 marker shape is not the exact pre-R18 state"
echo "PASS exact validated R17-R2 binary: $BIN_SHA"
echo "PASS exact validated R17-R2 Lua:    $LUA_SHA"

echo
echo "===== 2/6 BACK UP EXACT R17-R2 LUA/PROFILE ====="
DEVICE_BACKUP="$ROOT/backups/roomwake-v30-r18-r1-view-linked-$STAMP"
if ! ssh "$DEV" 'bash -s' -- "$DEVICE_BACKUP" "$LUA" "$PROFILE" "$EXPECTED_R17_LUA_SHA" <<'REMOTE_BACKUP'
set -u
B="$1"; LIVE="$2"; PROFILE="$3"; EXPECTED="$4"
mkdir -p "$B" || exit 1
for f in "$LIVE" "$PROFILE"; do
    [ -s "$f" ] || exit 2
    [ "$(sha256sum "$f" | awk '{print $1}')" = "$EXPECTED" ] || exit 3
done
cp -p "$LIVE" "$B/visgrid.lua.before-r18-r1" || exit 4
cp -p "$PROFILE" "$B/profile.lua.before-r18-r1" || exit 5
sync
echo "PASS R18 device backup: $B"
REMOTE_BACKUP
then
    fail 35 "R18 device backup failed"
fi
scp -q "$DEV:$LUA" "$TMP/visgrid-r17.lua" || fail 36 "could not pull R17-R2 Lua"
[ "$(sha256sum "$TMP/visgrid-r17.lua" | awk '{print $1}')" = "$EXPECTED_R17_LUA_SHA" ] \
    || fail 36 "pulled R17-R2 Lua SHA changed after preflight"

echo
echo "===== 3/6 GENERATE + VERIFY R18-R1 BEFORE DEVICE MUTATION ====="
make_patcher
python3 -m py_compile "$TMP/patch_r18_r1.py" || fail 37 "R18-R1 Python compile failed"
python3 "$TMP/patch_r18_r1.py" "$TMP/visgrid-r17.lua" "$TMP/visgrid-r18.lua" \
    || fail 38 "R18-R1 transformation failed before device mutation"
syntax_check "$TMP/visgrid-r18.lua"
python3 - "$TMP/visgrid-r17.lua" "$TMP/visgrid-r18.lua" <<'PY_VERIFY'
from pathlib import Path
import sys
before=Path(sys.argv[1]).read_text(); after=Path(sys.argv[2]).read_text()
for token in ('TSP_ROOMRAY_LUA_V30_R18_R1_VIEW_LINKED_CORRIDOR',
              'mapState.r18TopologyHoldSamples = 12',
              'mapState.r18WitnessHoldSamples = 10',
              'mapState.r18ForwardMinimum = 900.0',
              'mapState.r18UpdateWitness', 'mapState.r18DepthTiers',
              'mapState.r18R17OpeningProof',
              'mapState.r18R17NarrowEvidence',
              "'r18-view-linked-corridor'",
              '[TSP_ROOMRAY_R18_R1] state active='):
    if token not in after:
        raise SystemExit('FAIL missing R18-R1 semantic token: '+token)
if after.count('mapState.r11CastDirection(eye,') != 4:
    raise SystemExit('FAIL R18 changed exact four-ray call count')
if after.count('TSP_ROOMRAY_LUA_V30_R18_R1_VIEW_LINKED_CORRIDOR') != 1:
    raise SystemExit('FAIL R18-R1 marker is not unique')
if 'TSP_ROOMRAY_LUA_V30_R17_R2_DUAL_EXTREMES' not in after:
    raise SystemExit('FAIL exact R17-R2 lineage missing')
if len(after) <= len(before):
    raise SystemExit('FAIL R18 output did not grow')
print('PASS R18-R1 semantic verify: R17-R2 retained; four rays unchanged; marker unique')
PY_VERIFY
[ "$?" -eq 0 ] || fail 39 "R18-R1 semantic verification failed"
R18_SHA="$(sha256sum "$TMP/visgrid-r18.lua" | awk '{print $1}')"
valid_sha "$R18_SHA" || fail 39 "generated R18-R1 SHA is invalid"
echo "PASS generated R18-R1 Lua SHA: $R18_SHA"

echo
echo "===== 4/6 INSTALL LUA/PROFILE TRANSACTIONALLY ====="
scp -q "$TMP/visgrid-r18.lua" "$DEV:/tmp/visgrid-r18.lua" \
    || fail 40 "R18 upload failed before mutation"
DEVICE_MUTATED=1
if ! ssh "$DEV" 'bash -s' -- /tmp/visgrid-r18.lua "$R18_SHA" "$LUA" "$PROFILE" "$BIN" "$EXPECTED_BIN_SHA" <<'REMOTE_INSTALL'
set -u
STAGED="$1"; EXPECTED="$2"; LIVE="$3"; PROFILE="$4"; BIN="$5"; EXPECTED_BIN="$6"
[ -s "$STAGED" ] || exit 1
[ "$(sha256sum "$STAGED" | awk '{print $1}')" = "$EXPECTED" ] || exit 2
[ "$(sha256sum "$BIN" | awk '{print $1}')" = "$EXPECTED_BIN" ] || exit 3
grep -Fq 'TSP_ROOMRAY_LUA_V30_R18_R1_VIEW_LINKED_CORRIDOR' "$STAGED" || exit 4
install -m 644 "$STAGED" "$PROFILE" || exit 5
install -m 644 "$STAGED" "$LIVE" || exit 6
sync
for f in "$PROFILE" "$LIVE"; do
    [ "$(sha256sum "$f" | awk '{print $1}')" = "$EXPECTED" ] || exit 7
done
rm -f "$STAGED"
echo "PASS installed exact R18-R1 Lua/profile; binary unchanged"
REMOTE_INSTALL
then
    recover_now || true
    fail 41 "R18 install failed; exact R17-R2 restoration attempted"
fi

echo
echo "===== 5/6 VERIFY FINAL DEVICE STATE ====="
FINAL_BIN="$(remote_sha "$BIN")"
FINAL_LUA="$(remote_sha "$LUA")"
FINAL_PROFILE="$(remote_sha "$PROFILE")"
if [ "$FINAL_BIN" != "$EXPECTED_BIN_SHA" ] || [ "$FINAL_LUA" != "$R18_SHA" ] \
    || [ "$FINAL_PROFILE" != "$R18_SHA" ]; then
    recover_now || true
    fail 42 "R18 final verification failed; exact R17-R2 restoration attempted"
fi
echo "PASS binary unchanged: $FINAL_BIN"
echo "PASS exact R18-R1 Lua/profile: $FINAL_LUA"

echo
echo "===== 6/6 ARM CAPTURE + SAVE ROLLBACK STATE ====="
if ! ssh "$DEV" 'bash -s' -- "$GAMELOG" "$ARM" <<'REMOTE_ARM'
set -u
LOG="$1"; ARM="$2"
[ -f "$LOG" ] || exit 1
LINES="$(wc -l < "$LOG" | tr -d '[:space:]')"
case "$LINES" in ''|*[!0-9]*) exit 2;; esac
printf '%s\n' "$LINES" > "$ARM" || exit 3
echo "PASS R18 capture armed after log line: $LINES"
REMOTE_ARM
then
    recover_now || true
    fail 43 "capture arm failed; exact R17-R2 restoration attempted"
fi
cat > "$STATE" <<EOF_STATE
R18_DEVICE_BACKUP='$DEVICE_BACKUP'
R18_OLD_BIN_SHA='$EXPECTED_BIN_SHA'
R18_OLD_LUA_SHA='$EXPECTED_R17_LUA_SHA'
R18_NEW_LUA_SHA='$R18_SHA'
EOF_STATE
[ -s "$STATE" ] || {
    recover_now || true
    fail 44 "state write failed; exact R17-R2 restoration attempted"
}

INSTALL_COMPLETE=1
DEVICE_MUTATED=0

echo
echo "============================================================"
echo "V30 R18-R1 VIEW-LINKED CORRIDOR CONTINUITY INSTALLED"
echo "============================================================"
echo "Binary unchanged: $FINAL_BIN"
echo "R17-R2 Lua:       $EXPECTED_R17_LUA_SHA"
echo "R18-R1 Lua:       $FINAL_LUA"
echo
echo "Test once each:"
echo "  1. The exact Vivec hallway/open-space route from the submitted trace."
echo "  2. Caldera Governor's Hall blank-wall staircase regression check."
echo "  3. Balmora Mages Guild stairs and Ald-ruhn Manor quick regressions."
echo "Collect:"
echo "  cd ~/Downloads"
echo "  ./apply_openmw51_tsp_roomwake_v30_R18_R1_view_linked_corridor.sh collect"
echo
echo "Rollback to exact validated R17-R2:"
echo "  ./apply_openmw51_tsp_roomwake_v30_R18_R1_view_linked_corridor.sh rollback"
echo "Controller log: $RUNLOG"
echo "============================================================"
