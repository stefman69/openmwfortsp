#!/usr/bin/env bash
set -u -o pipefail

ACTION="${1:-install}"
CTR="${OPENMW_CONTAINER:-openmw_builder}"
DEV="${TSP_DEVICE:-root@192.168.1.25}"
DL="$HOME/Downloads"
ROOT="/mnt/SDCARD/data/ports/openmw51"
REMOTE_BIN="$ROOT/bin/openmw-0.51"
LUA_DIR="$ROOT/mods/TSPInteriorVisGrid/scripts/TSPInteriorVisGrid"
LIVE_LUA="$LUA_DIR/visgrid.lua"
V29_PROFILE="$LUA_DIR/v29_profiles/visgrid-v29-door-prewake-hard.lua"
V30_DIR="$LUA_DIR/v30_profiles"
V30_PROFILE="$V30_DIR/visgrid-v30-floor-actor-roomwake.lua"
HOST_BIN="$DL/openmw-0.51-v30-r1-floor-actor-roomwake"
EXPECTED_V29_BIN_SHA="08d8cac100d12b1ab5c04d8efe6e2da1b00c1f29407de8cad5417dd5b75ce699"
EXPECTED_V30_BIN_SHA="9203cc3dbdd4c0352c2e2db8c09a3ae10241972b5a1bb93c87b3e9f28ff0904d"
STATE="$DL/openmw51-roomwake-v30-r2-resume.state"
STAMP="$(date +%Y%m%d-%H%M%S)"
TMP="$(mktemp -d "$DL/.roomwake-v30-r2.XXXXXX")"
DEVICE_BACKUP=""
DEPLOY_STARTED=0
LAUNCHER=""

cleanup() {
    rm -rf "$TMP" 2>/dev/null || true
}

die() {
    local rc="$1"
    shift
    echo "ERROR: $*" >&2
    exit "$rc"
}

sha_of() {
    sha256sum "$1" | awk '{print $1}'
}

restore_device() {
    if [ -z "$DEVICE_BACKUP" ] || [ -z "$LAUNCHER" ]; then
        echo "FAIL rollback: backup path or launcher unresolved" >&2
        return 1
    fi
    ssh "$DEV" bash -s -- "$DEVICE_BACKUP" "$REMOTE_BIN" "$LIVE_LUA" "$LAUNCHER" "$V30_PROFILE" <<'REMOTE_ROLLBACK'
set -u
B="$1"; BIN="$2"; LIVE="$3"; LAUNCH="$4"; V30="$5"
if [ ! -s "$B/openmw-0.51.before" ] || [ ! -s "$B/visgrid.lua.before" ] || [ ! -s "$B/launcher.before" ]; then
    echo "FAIL rollback backup incomplete: $B" >&2
    exit 1
fi
install -m 755 "$B/openmw-0.51.before" "$BIN"
install -m 644 "$B/visgrid.lua.before" "$LIVE"
install -m 755 "$B/launcher.before" "$LAUNCH"
if [ -f "$B/v30-profile.existed" ] && [ -s "$B/v30-profile.before" ]; then
    install -m 644 "$B/v30-profile.before" "$V30"
else
    rm -f "$V30"
fi
sync
echo "PASS device rollback restored pre-V30 state"
REMOTE_ROLLBACK
}

on_exit() {
    local rc=$?
    trap - EXIT
    if [ "$rc" -ne 0 ] && [ "$DEPLOY_STARTED" -eq 1 ]; then
        echo
        echo "===== FAILURE: RESTORING DEVICE BACKUP ====="
        restore_device || echo "WARNING: device rollback failed; backup remains at $DEVICE_BACKUP" >&2
    fi
    cleanup
    exit "$rc"
}
trap on_exit EXIT

require_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        die 10 "required command missing: $1"
    fi
    echo "PASS command: $1"
}

locate_launcher() {
    ssh "$DEV" 'bash -s' <<'REMOTE_LAUNCH'
for p in \
  /mnt/SDCARD/Roms/PORTS/Morrowind_51.sh \
  /mnt/SDCARD/Emus/PORTS/../../Roms/PORTS/Morrowind_51.sh \
  /mnt/SDCARD/roms/ports/Morrowind_51.sh
do
    if [ -f "$p" ]; then
        readlink -f "$p" 2>/dev/null || printf '%s\n' "$p"
        exit 0
    fi
done
exit 1
REMOTE_LAUNCH
}

collect_latest() {
    require_cmd ssh
    local out="$DL/openmw51-roomwake-v30-r2-validation-$STAMP.txt"
    if ! ssh "$DEV" bash -s -- "$ROOT" > "$out" <<'REMOTE_COLLECT'
set +e
ROOT="$1"
for f in "$ROOT/openmw_051_log.txt" "$ROOT/config-0.51/openmw.log" "$ROOT/openmw.log"; do
    [ -f "$f" ] || continue
    echo "===== $f ====="
    tail -n 16000 "$f" | grep -E '\[TSP_VISGRID_V30\]|\[TSP_ROOMOBJ_V30\]|\[TSP_ACTOR_V30\]|BRIDGE ERROR|Bad LiveCellRef cast|failed to render' | tail -500
    echo
done
if [ -f "$ROOT/openmw51_perf_latest.txt" ]; then
    echo "===== PERF TAIL ====="
    tail -250 "$ROOT/openmw51_perf_latest.txt"
fi
REMOTE_COLLECT
    then
        die 20 "failed to collect V30 validation log"
    fi
    echo "Saved: $out"
    cat "$out"
}

rollback_saved() {
    if [ ! -s "$STATE" ]; then
        die 21 "rollback state missing: $STATE"
    fi
    # shellcheck disable=SC1090
    . "$STATE"
    if [ -z "${DEVICE_BACKUP:-}" ] || [ -z "${LAUNCHER:-}" ]; then
        die 22 "rollback state incomplete: $STATE"
    fi
    restore_device || die 23 "device rollback failed"
    echo "PASS V30 R2 rollback complete"
}

case "$ACTION" in
    collect) collect_latest; exit 0 ;;
    rollback) rollback_saved; exit 0 ;;
    install) ;;
    *) die 2 "Usage: $0 [install|collect|rollback]" ;;
esac

echo "============================================================"
echo "OPENMW 0.51 — V30 R2 RESUME AFTER SUCCESSFUL C++ BUILD"
echo "============================================================"
echo "NO REBUILD. Uses exact already-built V30 binary SHA:"
echo "  $EXPECTED_V30_BIN_SHA"
echo "Lua syntax validation: CLI parser if present; otherwise a tiny"
echo "checker compiled against the LuaJIT library OpenMW already links."
echo "============================================================"

for c in docker ssh scp python3 sha256sum file; do
    require_cmd "$c"
done

if ! docker inspect "$CTR" >/dev/null 2>&1; then
    die 30 "Docker container not found: $CTR"
fi
running="$(docker inspect -f '{{.State.Running}}' "$CTR" 2>/dev/null || true)"
if [ "$running" != "true" ]; then
    if ! docker start "$CTR" >/dev/null; then
        die 31 "failed to start Docker container: $CTR"
    fi
fi
echo "PASS Docker: $CTR"

if ! ssh -o BatchMode=yes -o ConnectTimeout=8 "$DEV" true; then
    die 32 "cannot reach $DEV"
fi
echo "PASS SSH: $DEV"

LAUNCHER="$(locate_launcher || true)"
if [ -z "$LAUNCHER" ]; then
    die 33 "Morrowind_51.sh not found on device"
fi
echo "PASS launcher: $LAUNCHER"

echo
echo "===== 1/6 VERIFY ALREADY-BUILT V30 BINARY + V29 DEVICE ====="
if [ ! -s "$HOST_BIN" ]; then
    die 40 "already-built V30 binary missing: $HOST_BIN"
fi
got_bin_sha="$(sha_of "$HOST_BIN")"
if [ "$got_bin_sha" != "$EXPECTED_V30_BIN_SHA" ]; then
    echo "EXPECTED: $EXPECTED_V30_BIN_SHA" >&2
    echo "ACTUAL:   $got_bin_sha" >&2
    die 41 "already-built V30 binary SHA mismatch"
fi
echo "PASS exact already-built V30 binary SHA: $got_bin_sha"
file "$HOST_BIN"
if ! grep -aFq '[TSP_ACTOR_V30]' "$HOST_BIN"; then
    die 42 "V30 binary telemetry marker missing: [TSP_ACTOR_V30]"
fi
if ! grep -aFq '[TSP_ROOMOBJ_V30]' "$HOST_BIN"; then
    die 43 "V30 binary telemetry marker missing: [TSP_ROOMOBJ_V30]"
fi
echo "PASS V30 binary telemetry markers"

remote_sha="$(ssh "$DEV" "sha256sum '$REMOTE_BIN' | awk '{print \$1}'" 2>/dev/null || true)"
if [ "$remote_sha" != "$EXPECTED_V29_BIN_SHA" ]; then
    echo "EXPECTED V29: $EXPECTED_V29_BIN_SHA" >&2
    echo "DEVICE:       $remote_sha" >&2
    die 44 "device is not still on proven V29 binary"
fi
echo "PASS device still on proven V29 binary"

if ! ssh "$DEV" "grep -Fq 'TSP_VISGRID_LUA_V29_DOOR_PREWAKE_HARD' '$LIVE_LUA'"; then
    die 45 "device live Lua is not working V29 profile"
fi
if ssh "$DEV" "grep -Fq 'setInteriorClutterResidency' '$LIVE_LUA'"; then
    die 46 "broken V28 clutter bridge found in live Lua"
fi
echo "PASS working V29 Lua baseline"

echo
echo "===== 2/6 PULL V29 PROFILE + GENERATE V30 PROFILE ====="
if ! scp -q "$DEV:$V29_PROFILE" "$TMP/visgrid.v29.lua"; then
    die 50 "failed to pull working V29 profile"
fi
if ! scp -q "$DEV:$LAUNCHER" "$TMP/Morrowind_51.v29.sh"; then
    die 51 "failed to pull current V29 launcher"
fi

cat > "$TMP/patch_v30_profile.py" <<'PY_PROFILE'
#!/usr/bin/env python3
import re
import sys

src_path, lua_out, launcher_in, launcher_out = sys.argv[1:5]


def read(path):
    with open(path, 'r', encoding='utf-8', newline='') as f:
        return f.read()


def write(path, text):
    with open(path, 'w', encoding='utf-8', newline='\n') as f:
        f.write(text)


s = read(src_path)
required = (
    'TSP_VISGRID_LUA_V29_DOOR_PREWAKE_HARD',
    'mapState.v29BaseOnFrame = ',
    'mapState.v29BaseOnFrame(dt)',
    'mapState.updateTopologyPvs = function(force)',
    'camera.setInteriorTopologyPvs',
    '-- No ray learning/prewarm in this diagnostic.',
)
for token in required:
    if token not in s:
        raise RuntimeError('V29 profile missing required token: ' + token)
if 'TSP_VISGRID_LUA_V30_FLOOR_ACTOR_ROOMWAKE' in s:
    raise RuntimeError('V30 marker already present; refusing ambiguous re-application')
if 'setInteriorClutterResidency' in s:
    raise RuntimeError('broken V28 clutter bridge reference exists in V29 source')

base_pat = re.compile(r'(?m)^mapState\.v29BaseOnFrame\s*=\s*(?P<base>mapState\.[A-Za-z_][A-Za-z0-9_]*)\s*$')
base_matches = list(base_pat.finditer(s))
if len(base_matches) != 1:
    candidates = [line for line in s.splitlines() if 'v29BaseOnFrame' in line]
    raise RuntimeError('V29 base frame callback matches=%d, expected 1; candidates=%r'
                       % (len(base_matches), candidates[-20:]))
base_callback = base_matches[0].group('base')
print('PASS: captured V29 original frame callback: ' + base_callback)

start = s.index('-- TSP_VISGRID_LUA_V29_DOOR_PREWAKE_HARD')
end = s.index('-- No ray learning/prewarm in this diagnostic.', start)

block = r'''-- TSP_VISGRID_LUA_V30_FLOOR_ACTOR_ROOMWAKE
-- V26/V29 hard topology-PVS authority, now with explicit FLOOR authority.
-- Current sector always lives. A vertical connector itself may prewake, but a
-- normal room on another floor is never admitted merely because a staircase
-- portal is physically nearby. On a connector, the player's effective floor is
-- inferred from the nearest NON-connector sector AABB.
mapState.v30LastSignature = ''
mapState.v30LastLine = ''

mapState.v30BoxDistance2 = function(x, y, z, b)
    if b == nil then return math.huge end
    local minX = tonumber(b[1] or 0) or 0
    local minY = tonumber(b[2] or 0) or 0
    local minZ = tonumber(b[3] or 0) or 0
    local maxX = tonumber(b[4] or 0) or 0
    local maxY = tonumber(b[5] or 0) or 0
    local maxZ = tonumber(b[6] or 0) or 0
    local dx = x < minX and (minX - x) or (x > maxX and (x - maxX) or 0)
    local dy = y < minY and (minY - y) or (y > maxY and (y - maxY) or 0)
    local dz = z < minZ and (minZ - z) or (z > maxZ and (z - maxZ) or 0)
    return dx*dx + dy*dy + dz*dz
end

mapState.v30InferFloor = function(x, y, z, currentSec)
    if currentSec == nil then return nil end
    local currentKind = tostring(currentSec.kind or 'room')
    local currentFloor = tonumber(currentSec.floor)
    if currentKind ~= 'vertical_connector' and currentFloor ~= nil then
        return currentFloor
    end

    local bestFloor = nil
    local bestD2 = math.huge
    local sectors = mapState.topoCell and mapState.topoCell.sectors or nil
    if sectors ~= nil then
        for id, candidate in pairs(sectors) do
            if tonumber(id) ~= tonumber(mapState.topoSectorId or 0)
                and candidate ~= nil
                and tostring(candidate.kind or 'room') ~= 'vertical_connector'
                and tonumber(candidate.floor) ~= nil then
                local d2 = mapState.v30BoxDistance2(x, y, z, candidate.bbox)
                if d2 < bestD2 then
                    bestD2 = d2
                    bestFloor = tonumber(candidate.floor)
                end
            end
        end
    end
    return bestFloor ~= nil and bestFloor or currentFloor
end

mapState.v30WakeRange = function(currentKind, targetKind, portalKind)
    local range
    if targetKind == 'small_room' then
        range = 240.0
    elseif targetKind == 'large_open' then
        range = 380.0
    elseif targetKind == 'corridor' then
        range = 340.0
    elseif targetKind == 'vertical_connector' then
        range = 280.0
    else
        range = 300.0
    end

    if portalKind == 'door' then range = range + 60.0 end

    -- Staircase/connector is still the critical performance case. Wake the one
    -- room on the player's inferred floor earlier than V29, but never a remote
    -- room from another floor.
    if currentKind == 'vertical_connector' then
        range = math.min(range, 320.0)
    end
    return range
end

mapState.v30MaxExtra = function(kind)
    if kind == 'vertical_connector' then return 1 end
    if kind == 'small_room' then return 1 end
    if kind == 'large_open' then return 3 end
    if kind == 'corridor' then return 2 end
    return 2
end

mapState.updateTopologyPvs = function(force)
    if not mapState.pvsBridge or mapState.topoCell == nil
        or mapState.pvsBoxes == nil then
        if mapState.pvsBridge then pcall(camera.clearInteriorTopologyPvs) end
        mapState.pvsSignature = nil
        mapState.pvsActiveCount = 0
        return
    end

    local current = tonumber(mapState.topoSectorId or 0) or 0
    local sec = current > 0 and mapState.topoCell.sectors[current] or nil
    if current <= 0 or sec == nil then
        pcall(camera.clearInteriorTopologyPvs)
        mapState.pvsSignature = nil
        mapState.pvsActiveCount = 0
        if force or mapState.v30LastLine ~= 'unmapped' then
            mapState.v30LastLine = 'unmapped'
            print(string.format('[TSP_VISGRID_V30] UNMAPPED current=%d total=%d',
                current, tonumber(mapState.pvsSectorCount or 0) or 0))
        end
        return
    end

    local cc = sec.center or {0, 0, 0}
    local x = tonumber(mapState.topoX or cc[1] or 0) or 0
    local y = tonumber(mapState.topoY or cc[2] or 0) or 0
    local z = tonumber(mapState.topoZ or cc[3] or 0) or 0
    local currentKind = tostring(sec.kind or 'room')
    local playerFloor = mapState.v30InferFloor(x, y, z, sec)
    local maxExtra = mapState.v30MaxExtra(currentKind)
    local candidates = {}
    local seen = {}

    local portals = mapState.topoCell.portals
    if sec.portals ~= nil and portals ~= nil then
        for i = 1, #sec.portals do
            local pid = tonumber(sec.portals[i] or 0) or 0
            local p = portals[pid]
            if p ~= nil and p.center ~= nil then
                local a = tonumber(p.a or 0) or 0
                local b = tonumber(p.b or 0) or 0
                local other = 0
                if a == current then other = b
                elseif b == current then other = a end

                local target = other > 0 and mapState.topoCell.sectors[other] or nil
                if target ~= nil and other ~= current and not seen[other] then
                    local targetKind = tostring(target.kind or 'room')
                    local targetFloor = tonumber(target.floor)

                    -- Floor is stronger than portal proximity. Connectors are the
                    -- only cross-floor structure allowed to stay live. Normal rooms
                    -- must match the player's inferred floor exactly.
                    local floorAllowed = targetKind == 'vertical_connector'
                        or (playerFloor ~= nil and targetFloor ~= nil and targetFloor == playerFloor)

                    if floorAllowed then
                        local px = tonumber(p.center[1] or 0) or 0
                        local py = tonumber(p.center[2] or 0) or 0
                        local pz = tonumber(p.center[3] or 0) or 0
                        local dx, dy, dz = px - x, py - y, pz - z
                        local d = math.sqrt(dx*dx + dy*dy + dz*dz)
                        local pkind = tostring(p.kind or 'boundary')
                        local limit = mapState.v30WakeRange(currentKind, targetKind, pkind)
                        if d <= limit then
                            seen[other] = true
                            candidates[#candidates + 1] = {
                                id = other, d = d, limit = limit,
                                portal = pid, pkind = pkind, tkind = targetKind,
                                floor = targetFloor,
                            }
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

    local ids = { current }
    local detail = {}
    local n = math.min(maxExtra, #candidates)
    for i = 1, n do
        local c = candidates[i]
        ids[#ids + 1] = c.id
        detail[#detail + 1] = string.format('%d@%.0f/%.0f:f%s',
            c.id, c.d, c.limit, tostring(c.floor or '?'))
    end
    table.sort(ids)

    local signature = 'v30:f' .. tostring(playerFloor or '?') .. ':' .. table.concat(ids, ',')
    if force or signature ~= mapState.pvsSignature then
        local ok, err = pcall(camera.setInteriorTopologyPvs,
            mapState.pvsBoxes, ids, 0.0, 0.0)
        if ok then
            mapState.pvsSignature = signature
            mapState.pvsActiveCount = #ids
            if force or signature ~= mapState.v30LastSignature then
                mapState.v30LastSignature = signature
                local ds = #detail > 0 and table.concat(detail, ',') or '-'
                print(string.format(
                    '[TSP_VISGRID_V30] current=%d/%d kind=%s floor=%s active=%d ids=%s portalWake=%s',
                    current, tonumber(mapState.pvsSectorCount or 0) or 0,
                    currentKind, tostring(playerFloor or '?'), #ids,
                    table.concat(ids, ','), ds))
            end
        else
            print('[TSP_VISGRID_V30] BRIDGE ERROR: ' .. tostring(err))
            pcall(camera.clearInteriorTopologyPvs)
            mapState.pvsSignature = nil
            mapState.pvsActiveCount = 0
        end
    end
end

'''

frame_wrapper = (
    "\nmapState.v30BaseOnFrame = %s\n"
    "%s = function(dt)\n"
    "    mapState.v30BaseOnFrame(dt)\n"
    "    mapState.updateTopologyPvs(false)\n"
    "end\n\n"
) % (base_callback, base_callback)
block = block + frame_wrapper
s = s[:start] + block + s[end:]

# Replace V29 runtime identity with V30. Preserve V26 historical startup marker.
startup_pat = re.compile(r"(?m)^[ \t]*print\(['\"]\[TSP_VISGRID_V29\] DOOR-PREWAKE-HARD[^\n]*\)[ \t]*$")
startup_matches = list(startup_pat.finditer(s))
if len(startup_matches) != 1:
    candidates = [line for line in s.splitlines() if '[TSP_VISGRID_V29]' in line]
    raise RuntimeError('V29 startup marker matches=%d, expected 1; candidates=%r'
                       % (len(startup_matches), candidates[-10:]))
sm = startup_matches[0]
s = (s[:sm.start()]
     + "print('[TSP_VISGRID_V30] FLOOR-AUTHORITY earlier-door-wake=1 actor-room-mask=1')"
     + s[sm.end():])

for token in (
    'TSP_VISGRID_LUA_V30_FLOOR_ACTOR_ROOMWAKE',
    'mapState.v30InferFloor',
    "targetKind == 'vertical_connector'",
    'targetFloor == playerFloor',
    'mapState.pvsBoxes, ids, 0.0, 0.0',
    'mapState.v30BaseOnFrame = ' + base_callback,
    base_callback + ' = function(dt)',
    '[TSP_VISGRID_V30] FLOOR-AUTHORITY',
):
    if token not in s:
        raise RuntimeError('V30 Lua postcondition missing: ' + token)
if 'TSP_VISGRID_LUA_V29_DOOR_PREWAKE_HARD' in s:
    raise RuntimeError('old V29 policy block marker survived V30 replacement')
if 'setInteriorClutterResidency' in s:
    raise RuntimeError('broken V28 clutter bridge leaked into V30')
write(lua_out, s)

l = read(launcher_in)
profile_pat = re.compile(r"\$TSP_VISGRID_DIR/v(?:26|27|28|29|30)_profiles/visgrid-[^'\"\n]+\.lua")
profile_matches = list(profile_pat.finditer(l))
if len(profile_matches) != 1:
    candidates = [line for line in l.splitlines() if 'TSP_VISGRID_SELECTED=' in line or '_profiles/visgrid-' in line]
    raise RuntimeError('launcher selected-profile structure matches=%d, expected 1; candidates=%r'
                       % (len(profile_matches), candidates[-20:]))
pm = profile_matches[0]
new_profile = '$TSP_VISGRID_DIR/v30_profiles/visgrid-v30-floor-actor-roomwake.lua'
l = l[:pm.start()] + new_profile + l[pm.end():]

l, n_profile = re.subn(
    r"(?m)^([ \t]*echo[ \t]+['\"]Visgrid Profile=)[^'\"]*(['\"][ \t]*)$",
    r"\1v30-floor-actor-roomwake\2",
    l,
    count=1,
)
if n_profile != 1:
    raise RuntimeError('launcher Visgrid Profile label matches=%d, expected 1' % n_profile)

l, n_policy = re.subn(
    r"(?m)^[ \t]*echo[ \t]+['\"]Visgrid room policy=[^'\"]*['\"][ \t]*$",
    'echo "Visgrid room policy=V26 hard delete; FLOOR authority + earlier same-floor portal prewake + actor hibernation"',
    l,
    count=1,
)
if n_policy != 1:
    raise RuntimeError('launcher Visgrid room policy matches=%d, expected 1' % n_policy)

for token in (
    'v30_profiles/visgrid-v30-floor-actor-roomwake.lua',
    'Visgrid Profile=v30-floor-actor-roomwake',
):
    if token not in l:
        raise RuntimeError('V30 launcher postcondition missing: ' + token)
if 'export TSP_OBJECT_DIAG=1' in l:
    raise RuntimeError('heavy object diagnostics survived V30 launcher patch')
if '# >>> TSP_VISGRID_V24_AUTO_CAPTURE BEGIN' in l:
    raise RuntimeError('synchronous auto-capture survived V30 launcher patch')
write(launcher_out, l)

print('PASS: V30 floor authority generated directly from working V29 profile.')
print('PASS: normal destination rooms must match inferred player floor; connector is the only cross-floor exception.')
print('PASS: doorway prewake ranges increased while connector current remains capped at 320.')
print('PASS: proven setInteriorTopologyPvs bridge remains the only room authority.')
PY_PROFILE

if ! python3 -m py_compile "$TMP/patch_v30_profile.py"; then
    die 52 "embedded V30 profile generator does not compile"
fi
if ! python3 "$TMP/patch_v30_profile.py" \
    "$TMP/visgrid.v29.lua" "$TMP/visgrid.v30.lua" \
    "$TMP/Morrowind_51.v29.sh" "$TMP/Morrowind_51.v30.sh"; then
    die 53 "V30 profile/launcher generation failed"
fi
if ! bash -n "$TMP/Morrowind_51.v30.sh"; then
    die 54 "generated V30 launcher Bash syntax failed"
fi
echo "PASS generated V30 launcher Bash syntax"

echo
echo "===== 3/6 PARSE GENERATED V30 LUA ====="
PARSER=""
for x in luajit texlua lua; do
    if command -v "$x" >/dev/null 2>&1; then
        PARSER="$x"
        break
    fi
done

if [ -n "$PARSER" ]; then
    cat > "$TMP/check-v30.lua" <<'LUA_CHECK'
local f,e=loadfile(arg[1])
if not f then error(e) end
print('LUA_PARSE_PASS ' .. arg[1])
LUA_CHECK
    if ! "$PARSER" "$TMP/check-v30.lua" "$TMP/visgrid.v30.lua"; then
        die 60 "generated V30 Lua failed host parser=$PARSER"
    fi
    echo "PASS generated V30 Lua syntax: host $PARSER"
else
    if ! docker cp "$TMP/visgrid.v30.lua" "$CTR:/tmp/visgrid.v30.lua" >/dev/null; then
        die 61 "failed to stage generated Lua in Docker"
    fi
    DOCKER_PARSER="$(docker exec "$CTR" bash -lc 'for x in luajit texlua lua; do if command -v "$x" >/dev/null 2>&1; then echo "$x"; exit 0; fi; done; exit 1' 2>/dev/null || true)"
    if [ -n "$DOCKER_PARSER" ]; then
        if ! docker exec "$CTR" "$DOCKER_PARSER" -e 'local f,e=loadfile(arg[1]); assert(f,e); print("LUA_PARSE_PASS " .. arg[1])' /tmp/visgrid.v30.lua; then
            die 62 "generated V30 Lua failed Docker CLI parser=$DOCKER_PARSER"
        fi
        echo "PASS generated V30 Lua syntax: Docker $DOCKER_PARSER"
    else
        echo "INFO: no Lua CLI executable; compiling syntax checker against installed LuaJIT library."
        if ! docker exec -i "$CTR" bash -s <<'REMOTE_BUILD_LUA_CHECK'
set -u
HEADER="$(find /usr/include /usr/local/include -type f -name lua.h -path '*luajit*' -print 2>/dev/null | head -1)"
if [ -z "$HEADER" ]; then
    echo "FAIL: LuaJIT lua.h not found" >&2
    exit 1
fi
INC="$(dirname "$HEADER")"
LIB="$(find /usr/lib /usr/local/lib \( -type f -o -type l \) -name 'libluajit-5.1.so*' -print 2>/dev/null | head -1)"
if [ -z "$LIB" ]; then
    echo "FAIL: libluajit-5.1.so not found" >&2
    exit 2
fi
CC=""
for c in gcc-13 gcc cc; do
    if command -v "$c" >/dev/null 2>&1; then CC="$c"; break; fi
done
if [ -z "$CC" ]; then
    echo "FAIL: no C compiler available for LuaJIT syntax checker" >&2
    exit 3
fi
cat > /tmp/v30_lua_syntax_check.c <<'C_CHECK'
#include <stdio.h>
#include <lua.h>
#include <lauxlib.h>
int main(int argc, char **argv)
{
    if (argc != 2) {
        fprintf(stderr, "usage: %s file.lua\n", argv[0]);
        return 2;
    }
    lua_State *L = luaL_newstate();
    if (!L) {
        fprintf(stderr, "luaL_newstate failed\n");
        return 3;
    }
    int rc = luaL_loadfile(L, argv[1]);
    if (rc != 0) {
        const char *msg = lua_tostring(L, -1);
        fprintf(stderr, "LUA_PARSE_FAIL: %s\n", msg ? msg : "unknown Lua error");
        lua_close(L);
        return 4;
    }
    lua_close(L);
    printf("LUA_PARSE_PASS %s\n", argv[1]);
    return 0;
}
C_CHECK
if ! "$CC" -O2 -I"$INC" /tmp/v30_lua_syntax_check.c "$LIB" -lm -ldl -pthread -o /tmp/v30_lua_syntax_check; then
    echo "FAIL: compiling LuaJIT syntax checker" >&2
    echo "HEADER: $HEADER" >&2
    echo "LIB:    $LIB" >&2
    echo "CC:     $CC" >&2
    exit 4
fi
if ! /tmp/v30_lua_syntax_check /tmp/visgrid.v30.lua; then
    exit 5
fi
echo "PASS generated V30 Lua syntax via compiled LuaJIT checker"
REMOTE_BUILD_LUA_CHECK
        then
            die 63 "generated V30 Lua could not be validated against installed LuaJIT library"
        fi
    fi
    if ! docker exec "$CTR" rm -f /tmp/visgrid.v30.lua /tmp/v30_lua_syntax_check /tmp/v30_lua_syntax_check.c >/dev/null; then
        die 64 "failed to clean Docker Lua validation temporaries"
    fi
fi

V30_LUA_SHA="$(sha_of "$TMP/visgrid.v30.lua")"
V30_LAUNCH_SHA="$(sha_of "$TMP/Morrowind_51.v30.sh")"
echo "V30 Lua SHA:      $V30_LUA_SHA"
echo "V30 launcher SHA: $V30_LAUNCH_SHA"

for token in TSP_VISGRID_LUA_V30_FLOOR_ACTOR_ROOMWAKE mapState.v30InferFloor 'targetFloor == playerFloor' 'mapState.pvsBoxes, ids, 0.0, 0.0'; do
    if ! grep -Fq -- "$token" "$TMP/visgrid.v30.lua"; then
        die 65 "generated V30 Lua missing required token: $token"
    fi
done
if grep -Fq 'setInteriorClutterResidency' "$TMP/visgrid.v30.lua"; then
    die 66 "broken V28 clutter bridge leaked into generated V30 Lua"
fi
if ! grep -Fq 'v30_profiles/visgrid-v30-floor-actor-roomwake.lua' "$TMP/Morrowind_51.v30.sh"; then
    die 67 "generated launcher does not select V30 profile"
fi
echo "PASS generated profile/launcher structural verification"

echo
echo "===== 4/6 BACKUP CURRENT V29 DEVICE STATE ====="
DEVICE_BACKUP="$ROOT/backups/roomwake-v30-r2-resume-$STAMP"
if ! ssh "$DEV" bash -s -- "$DEVICE_BACKUP" "$REMOTE_BIN" "$LIVE_LUA" "$LAUNCHER" "$V30_PROFILE" <<'REMOTE_BACKUP'
set -u
B="$1"; BIN="$2"; LIVE="$3"; LAUNCH="$4"; V30="$5"
mkdir -p "$B"
for spec in "$BIN|openmw-0.51.before|755" "$LIVE|visgrid.lua.before|644" "$LAUNCH|launcher.before|755"; do
    src="${spec%%|*}"; rest="${spec#*|}"; name="${rest%%|*}"; mode="${rest##*|}"
    if [ ! -s "$src" ]; then
        echo "FAIL backup input missing: $src" >&2
        exit 1
    fi
    install -m "$mode" "$src" "$B/$name"
done
if [ -f "$V30" ]; then
    touch "$B/v30-profile.existed"
    install -m 644 "$V30" "$B/v30-profile.before"
fi
sha256sum "$B/openmw-0.51.before" "$B/visgrid.lua.before" "$B/launcher.before"
REMOTE_BACKUP
then
    die 70 "device backup failed"
fi
echo "PASS device backup: $DEVICE_BACKUP"

echo
echo "===== 5/6 STAGE + INSTALL V30 ====="
REMOTE_TMP_BIN="/tmp/openmw-0.51.v30-r2"
REMOTE_TMP_LUA="/tmp/visgrid-v30-r2.lua"
REMOTE_TMP_LAUNCH="/tmp/Morrowind_51.v30-r2.sh"

if ! scp -q "$HOST_BIN" "$DEV:$REMOTE_TMP_BIN"; then die 71 "V30 binary upload failed"; fi
if ! scp -q "$TMP/visgrid.v30.lua" "$DEV:$REMOTE_TMP_LUA"; then die 72 "V30 Lua upload failed"; fi
if ! scp -q "$TMP/Morrowind_51.v30.sh" "$DEV:$REMOTE_TMP_LAUNCH"; then die 73 "V30 launcher upload failed"; fi

DEPLOY_STARTED=1
if ! ssh "$DEV" bash -s -- \
    "$REMOTE_TMP_BIN" "$EXPECTED_V30_BIN_SHA" "$REMOTE_BIN" \
    "$REMOTE_TMP_LUA" "$V30_LUA_SHA" "$V30_PROFILE" "$LIVE_LUA" "$V30_DIR" \
    "$REMOTE_TMP_LAUNCH" "$V30_LAUNCH_SHA" "$LAUNCHER" <<'REMOTE_INSTALL'
set -u
TB="$1"; BS="$2"; BIN="$3"; TL="$4"; LS="$5"; PROFILE="$6"; LIVE="$7"; DIR="$8"; TS="$9"; SS="${10}"; LAUNCH="${11}"
check_sha() {
    f="$1"; expect="$2"; label="$3"
    if [ ! -s "$f" ]; then echo "FAIL missing $label: $f" >&2; exit 1; fi
    got="$(sha256sum "$f" | awk '{print $1}')"
    if [ "$got" != "$expect" ]; then
        echo "FAIL SHA $label expected=$expect actual=$got" >&2
        exit 2
    fi
    echo "PASS SHA $label: $got"
}
check_sha "$TB" "$BS" 'staged V30 binary'
check_sha "$TL" "$LS" 'staged V30 Lua'
check_sha "$TS" "$SS" 'staged V30 launcher'
if ! bash -n "$TS"; then echo "FAIL staged launcher syntax" >&2; exit 3; fi
mkdir -p "$DIR"
install -m 755 "$TB" "$BIN"
install -m 644 "$TL" "$PROFILE"
install -m 644 "$TL" "$LIVE"
install -m 755 "$TS" "$LAUNCH"
sync
check_sha "$BIN" "$BS" 'installed V30 binary'
check_sha "$PROFILE" "$LS" 'installed V30 profile'
check_sha "$LIVE" "$LS" 'installed live V30 Lua'
check_sha "$LAUNCH" "$SS" 'installed V30 launcher'
if ! grep -Fq 'TSP_VISGRID_LUA_V30_FLOOR_ACTOR_ROOMWAKE' "$LIVE"; then echo "FAIL installed V30 Lua marker" >&2; exit 4; fi
if ! grep -Fq 'camera.setInteriorTopologyPvs' "$LIVE"; then echo "FAIL installed topology bridge marker" >&2; exit 5; fi
if grep -Fq 'setInteriorClutterResidency' "$LIVE"; then echo "FAIL broken V28 clutter bridge present" >&2; exit 6; fi
if ! grep -Fq 'v30_profiles/visgrid-v30-floor-actor-roomwake.lua' "$LAUNCH"; then echo "FAIL launcher V30 path" >&2; exit 7; fi
if ! bash -n "$LAUNCH"; then echo "FAIL installed launcher syntax" >&2; exit 8; fi
rm -f "$TB" "$TL" "$TS"
sync
REMOTE_INSTALL
then
    die 74 "V30 install/verification failed"
fi
DEPLOY_STARTED=0

echo
echo "===== 6/6 SAVE STATE + FINAL VERIFY ====="
cat > "$STATE" <<EOF_STATE
DEVICE_BACKUP='$DEVICE_BACKUP'
LAUNCHER='$LAUNCHER'
EOF_STATE

final_bin_sha="$(ssh "$DEV" "sha256sum '$REMOTE_BIN' | awk '{print \$1}'" 2>/dev/null || true)"
final_lua_sha="$(ssh "$DEV" "sha256sum '$LIVE_LUA' | awk '{print \$1}'" 2>/dev/null || true)"
if [ "$final_bin_sha" != "$EXPECTED_V30_BIN_SHA" ]; then die 80 "final device binary SHA mismatch"; fi
if [ "$final_lua_sha" != "$V30_LUA_SHA" ]; then die 81 "final device Lua SHA mismatch"; fi
echo "PASS final device binary SHA: $final_bin_sha"
echo "PASS final device Lua SHA:    $final_lua_sha"

echo
echo "============================================================"
echo "V30 R2 RESUME INSTALL COMPLETE — NO REBUILD WAS PERFORMED"
echo "============================================================"
echo "Test once: Caldera first -> second -> third floor, then doorway."
echo "Then collect with:"
echo "  cd ~/Downloads"
echo "  ./$(basename "$0") collect"
echo "Rollback if needed:"
echo "  ./$(basename "$0") rollback"
