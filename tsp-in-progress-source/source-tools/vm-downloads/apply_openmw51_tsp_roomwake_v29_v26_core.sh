#!/usr/bin/env bash
set -Eeuo pipefail

ACTION="${1:-install}"
DEV="${TSP_DEVICE:-root@192.168.1.25}"
ROOT="/mnt/SDCARD/data/ports/openmw51"
REMOTE_BIN="$ROOT/bin/openmw-0.51"
LUA_DIR="$ROOT/mods/TSPInteriorVisGrid/scripts/TSPInteriorVisGrid"
LIVE_LUA="$LUA_DIR/visgrid.lua"
V26_PROFILE="$LUA_DIR/v26_profiles/visgrid-v26-current-sector-only.lua"
V29_DIR="$LUA_DIR/v29_profiles"
V29_PROFILE="$V29_DIR/visgrid-v29-door-prewake-hard.lua"
V27_EXPECT_SHA="08d8cac100d12b1ab5c04d8efe6e2da1b00c1f29407de8cad5417dd5b75ce699"
DL="$HOME/Downloads"
STAMP="$(date +%Y%m%d-%H%M%S)"
LOG="$DL/openmw51-roomwake-v29-v26-core-$STAMP.log"
STATE="$DL/openmw51-roomwake-v29-v26-core.state"
TMP="$(mktemp -d "$DL/.roomwake-v29.XXXXXX")"
DEVICE_BACKUP=""
LAUNCHER=""
V27_BACKUP_BIN=""
DEVICE_DEPLOY_STARTED=0

cleanup() { rm -rf "$TMP" 2>/dev/null || true; }
trap cleanup EXIT

fail() {
    local rc="${1:-1}"
    shift || true
    echo "ERROR: $*" >&2
    exit "$rc"
}

on_error() {
    local rc="${1:-1}"
    local line="${2:-unknown}"
    local cmd="${3:-unknown}"
    trap - ERR
    set +e
    echo
    echo "============================================================"
    echo "V29 STOPPED SAFELY"
    echo "============================================================"
    echo "rc=$rc"
    echo "FAILED LINE: $line"
    echo "FAILED COMMAND: $cmd"
    if [ "$DEVICE_DEPLOY_STARTED" = 1 ] && [ -n "$DEVICE_BACKUP" ] && [ -n "$LAUNCHER" ]; then
        restore_device >/dev/null 2>&1 || true
        echo "Device state restored from: $DEVICE_BACKUP"
    fi
    echo "Log preserved: $LOG"
    exit "$rc"
}
trap 'on_error "$?" "$LINENO" "$BASH_COMMAND"' ERR

require_cmd() {
    local c="$1"
    if ! command -v "$c" >/dev/null 2>&1; then
        fail 10 "required command missing: $c"
    fi
    echo "PASS command: $c"
}

ensure_ssh() {
    require_cmd ssh
    require_cmd scp
    require_cmd python3
    require_cmd sha256sum
    if ! ssh -o BatchMode=yes -o ConnectTimeout=8 "$DEV" true; then
        fail 11 "cannot reach $DEV with non-interactive SSH"
    fi
    echo "PASS SSH: $DEV"
}

game_closed() {
    if ssh "$DEV" "pgrep -af 'openmw-0\\.51|/openmw([[:space:]]|$)' 2>/dev/null" | grep -v pgrep >/dev/null 2>&1; then
        return 1
    fi
    return 0
}

locate_launcher() {
    ssh "$DEV" 'bash -s' <<'REMOTE_LAUNCHER'
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
echo "FAIL: Morrowind_51.sh not found" >&2
exit 1
REMOTE_LAUNCHER
}

find_v27_backup_binary() {
    ssh "$DEV" bash -s -- "$ROOT" "$V27_EXPECT_SHA" <<'REMOTE_FIND_V27'
set -u
ROOT="$1"
EXPECT="$2"

exact="$ROOT/backups/visgrid-v28-separate-clutter-20260831-123423/openmw-0.51.before"
if [ -s "$exact" ]; then
    sha="$(sha256sum "$exact" | awk '{print $1}')"
    if [ "$sha" = "$EXPECT" ]; then
        printf '%s\n' "$exact"
        exit 0
    fi
fi

found=0
for f in "$ROOT"/backups/visgrid-v28-separate-clutter-*/openmw-0.51.before; do
    [ -s "$f" ] || continue
    sha="$(sha256sum "$f" | awk '{print $1}')"
    if [ "$sha" = "$EXPECT" ]; then
        printf '%s\n' "$f"
        found=1
        break
    fi
done

if [ "$found" -ne 1 ]; then
    echo "FAIL: exact V27 pre-V28 binary backup SHA not found" >&2
    echo "EXPECTED SHA: $EXPECT" >&2
    exit 31
fi
REMOTE_FIND_V27
}

restore_device() {
    ssh "$DEV" bash -s -- "$DEVICE_BACKUP" "$REMOTE_BIN" "$LIVE_LUA" "$LAUNCHER" "$V29_PROFILE" <<'REMOTE_RESTORE'
set -u
B="$1"
BIN="$2"
LIVE="$3"
LAUNCHER="$4"
V29="$5"

need() {
    if [ ! -s "$1" ]; then
        echo "FAIL rollback backup missing/empty: $1" >&2
        exit 61
    fi
}
need "$B/openmw-0.51.before"
need "$B/visgrid.lua.before"
need "$B/launcher.before"

install -m 755 "$B/openmw-0.51.before" "$BIN"
install -m 644 "$B/visgrid.lua.before" "$LIVE"
install -m 755 "$B/launcher.before" "$LAUNCHER"

if [ -f "$B/v29-profile.existed" ]; then
    need "$B/v29-profile.before"
    mkdir -p "$(dirname "$V29")"
    install -m 644 "$B/v29-profile.before" "$V29"
else
    rm -f "$V29"
fi
sync
REMOTE_RESTORE
}

collect_latest() {
    ensure_ssh
    local out="$DL/openmw51-roomwake-v29-validation-$STAMP.txt"
    ssh "$DEV" bash -s -- "$ROOT" <<'REMOTE_COLLECT' > "$out"
set +e
ROOT="$1"
echo "============================================================"
echo "OPENMW 0.51 ROOMWAKE V29 VALIDATION"
echo "============================================================"
date
printf 'Binary: '; sha256sum "$ROOT/bin/openmw-0.51" 2>/dev/null
printf 'Live Lua: '; sha256sum "$ROOT/mods/TSPInteriorVisGrid/scripts/TSPInteriorVisGrid/visgrid.lua" 2>/dev/null

echo
echo "===== V29 PORTAL ROOM AUTHORITY ====="
for f in "$ROOT/openmw_051_log.txt" "$ROOT/config-0.51/openmw.log" "$ROOT/openmw.log"; do
    [ -f "$f" ] || continue
    tail -n 30000 "$f" | grep -E '\[TSP_VISGRID_V29\]|\[TSP_ROOMOBJ_V27\]|\[TSP_VISGRID_V15\] (topology sector|sector switch)' | tail -220
 done

echo
echo "===== ERRORS ====="
for f in "$ROOT/openmw_051_log.txt" "$ROOT/config-0.51/openmw.log" "$ROOT/openmw.log"; do
    [ -f "$f" ] || continue
    tail -n 30000 "$f" | grep -E 'Bad LiveCellRef cast|failed to render|TSP_VISGRID_V29.*ERROR|Lua.*ERROR|Lua.*error' | tail -100
 done

echo
echo "===== PERF TAIL ====="
[ ! -f "$ROOT/openmw51_perf_latest.txt" ] || tail -220 "$ROOT/openmw51_perf_latest.txt"
REMOTE_COLLECT
    echo "Saved: $out"
    echo
    grep -E '\[TSP_VISGRID_V29\]|\[TSP_ROOMOBJ_V27\]' "$out" | tail -60 || true
}

rollback_all() {
    if [ ! -s "$STATE" ]; then
        fail 20 "rollback state missing: $STATE"
    fi
    # shellcheck disable=SC1090
    . "$STATE"
    ensure_ssh
    if ! game_closed; then
        fail 21 "OpenMW is running; exit the game before rollback"
    fi
    restore_device
    echo "ROLLBACK COMPLETE"
    echo "Restored: $DEVICE_BACKUP"
}

case "$ACTION" in
    collect) collect_latest; exit 0 ;;
    rollback) rollback_all; exit 0 ;;
    install) ;;
    *) fail 2 "Usage: $0 [install|collect|rollback]" ;;
esac

exec > >(tee "$LOG") 2>&1

echo "============================================================"
echo "OPENMW 0.51 — ROOMWAKE V29 / V26 HARD-DELETE CORE"
echo "============================================================"
echo "This does NOT use the V28 independent clutter bridge."
echo "Binary core: exact pre-V28 V27 binary (V26 hard removal + V27 safety)."
echo "Room authority: exact V26 topology-PVS bridge that actually parked objects."
echo "New behavior: current room + direct portal destination rooms only when close."
echo "No compile in this controller."
echo "============================================================"

ensure_ssh
if ! game_closed; then
    fail 22 "OpenMW is running; exit the game before installing V29"
fi
LAUNCHER="$(locate_launcher)"
if [ -z "$LAUNCHER" ]; then
    fail 23 "launcher resolver returned an empty path"
fi
echo "PASS launcher: $LAUNCHER"

echo
echo "===== 1/7 VERIFY PROVEN BASELINES ====="
V27_BACKUP_BIN="$(find_v27_backup_binary)"
if [ -z "$V27_BACKUP_BIN" ]; then
    fail 30 "V27 backup resolver returned empty path"
fi
echo "PASS exact V27 binary backup: $V27_BACKUP_BIN"

ssh "$DEV" bash -s -- "$V27_BACKUP_BIN" "$V27_EXPECT_SHA" "$V26_PROFILE" "$LIVE_LUA" "$LAUNCHER" <<'REMOTE_PREFLIGHT'
set -u
V27BIN="$1"
EXPECT="$2"
V26="$3"
LIVE="$4"
LAUNCHER="$5"

check_file() {
    local f="$1"
    if [ ! -s "$f" ]; then
        echo "FAIL preflight file missing/empty: $f" >&2
        exit 41
    fi
    echo "PASS file: $f"
}
check_has() {
    local token="$1" file="$2"
    if ! grep -Fq -- "$token" "$file"; then
        echo "FAIL preflight marker: [$token]" >&2
        echo "FILE: $file" >&2
        exit 42
    fi
    echo "PASS marker: $token"
}
check_absent() {
    local token="$1" file="$2"
    if grep -Fq -- "$token" "$file"; then
        echo "FAIL unexpected marker: [$token]" >&2
        echo "FILE: $file" >&2
        exit 43
    fi
    echo "PASS absent: $token"
}

check_file "$V27BIN"
actual="$(sha256sum "$V27BIN" | awk '{print $1}')"
if [ "$actual" != "$EXPECT" ]; then
    echo "FAIL V27 binary SHA" >&2
    echo "EXPECTED: $EXPECT" >&2
    echo "ACTUAL:   $actual" >&2
    exit 44
fi
echo "PASS exact V27 binary SHA: $actual"

check_file "$V26"
check_has 'TSP_VISGRID_LUA_V26_CURRENT_SECTOR_ONLY' "$V26"
check_has 'camera.setInteriorTopologyPvs' "$V26"
check_has 'mapState.updateTopologyPvs = function(force)' "$V26"
check_has "mapState.v23RayMode = 1" "$V26"
check_absent 'TSP_VISGRID_LUA_V27_ADAPTIVE_CLUTTER' "$V26"
check_absent 'TSP_VISGRID_LUA_V28_SEPARATE_CLUTTER' "$V26"

check_file "$LIVE"
check_file "$LAUNCHER"
REMOTE_PREFLIGHT

PRE_BIN_SHA="$(ssh "$DEV" "sha256sum '$REMOTE_BIN'" | awk '{print $1}')"
PRE_LUA_SHA="$(ssh "$DEV" "sha256sum '$LIVE_LUA'" | awk '{print $1}')"
V26_SHA="$(ssh "$DEV" "sha256sum '$V26_PROFILE'" | awk '{print $1}')"
echo "Current binary SHA: $PRE_BIN_SHA"
echo "Current live Lua:   $PRE_LUA_SHA"
echo "Proven V26 profile: $V26_SHA"

echo
echo "===== 2/7 BACKUP CURRENT DEVICE STATE ====="
DEVICE_BACKUP="$ROOT/backups/roomwake-v29-v26-core-$STAMP"
ssh "$DEV" bash -s -- "$DEVICE_BACKUP" "$REMOTE_BIN" "$LIVE_LUA" "$LAUNCHER" "$V29_PROFILE" <<'REMOTE_BACKUP'
set -u
B="$1"; BIN="$2"; LIVE="$3"; LAUNCHER="$4"; V29="$5"
mkdir -p "$B"
for f in "$BIN" "$LIVE" "$LAUNCHER"; do
    if [ ! -s "$f" ]; then
        echo "FAIL backup source missing/empty: $f" >&2
        exit 51
    fi
done
install -m 755 "$BIN" "$B/openmw-0.51.before"
install -m 644 "$LIVE" "$B/visgrid.lua.before"
install -m 755 "$LAUNCHER" "$B/launcher.before"
if [ -f "$V29" ]; then
    touch "$B/v29-profile.existed"
    install -m 644 "$V29" "$B/v29-profile.before"
fi
sha256sum "$B/openmw-0.51.before" "$B/visgrid.lua.before" "$B/launcher.before"
REMOTE_BACKUP

if ! scp -q "$DEV:$V26_PROFILE" "$TMP/visgrid.v26.lua"; then
    fail 52 "failed to pull proven V26 profile"
fi
if ! scp -q "$DEV:$LAUNCHER" "$TMP/Morrowind_51.current.sh"; then
    fail 53 "failed to pull current launcher"
fi
if [ "$(sha256sum "$TMP/visgrid.v26.lua" | awk '{print $1}')" != "$V26_SHA" ]; then
    fail 54 "pulled V26 profile SHA mismatch"
fi
echo "PASS pulled proven V26 profile byte-for-byte"

echo
echo "===== 3/7 BUILD V29 PORTAL-PREWAKE PROFILE ====="
cat > "$TMP/patch_v29.py" <<'PY_PATCH'
#!/usr/bin/env python3
import sys
import re

src_path, lua_out, launcher_in, launcher_out = sys.argv[1:5]

def read(path):
    with open(path, 'r', encoding='utf-8', newline='') as f:
        return f.read()

def write(path, text):
    with open(path, 'w', encoding='utf-8', newline='\n') as f:
        f.write(text)

s = read(src_path)
required = (
    'TSP_VISGRID_LUA_V26_CURRENT_SECTOR_ONLY',
    "mapState.v26CurrentOnlyLast = ''",
    'mapState.updateTopologyPvs = function(force)',
    '-- No ray learning/prewarm in this diagnostic.',
    "mapState.v23RayMode = 1",
    'onFrameBody',
    'engineHandlers',
)
for token in required:
    if token not in s:
        raise RuntimeError('V26 profile missing required token: ' + token)
if 'TSP_VISGRID_LUA_V29_DOOR_PREWAKE_HARD' in s:
    raise RuntimeError('V29 marker already present in V26 source')

start = s.index("mapState.v26CurrentOnlyLast = ''")
end = s.index('-- No ray learning/prewarm in this diagnostic.', start)

block = r'''-- TSP_VISGRID_LUA_V29_DOOR_PREWAKE_HARD
-- Proven V26 authority with one addition: a destination room is added ONLY when
-- the player is physically close to a portal connecting the CURRENT room to it.
-- No whole-floor set, no recent-room cache, no ray-promoted clutter rooms, and
-- no generic AABB-distance halo. Portal center distance is full 3-D, so a room
-- two floors below a staircase cannot remain alive merely because it is connected.
mapState.v29LastSignature = ''
mapState.v29LastLine = ''

mapState.v29WakeRange = function(currentKind, targetKind, portalKind)
    local range
    if targetKind == 'small_room' then
        range = 180.0
    elseif targetKind == 'large_open' then
        range = 300.0
    elseif targetKind == 'corridor' then
        range = 260.0
    elseif targetKind == 'vertical_connector' then
        range = 220.0
    else
        range = 220.0
    end

    -- Closed/load-bearing doorways get a little earlier wake than an open
    -- navmesh boundary, but never enough to span a different staircase floor.
    if portalKind == 'door' then range = range + 35.0 end

    -- Staircases are the critical case: one nearby endpoint only, and its portal
    -- must be genuinely close in 3-D. No first-floor room survives on floor three.
    if currentKind == 'vertical_connector' then
        range = math.min(range, 240.0)
    end
    return range
end

mapState.v29MaxExtra = function(kind)
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
        if force or mapState.v29LastLine ~= 'unmapped' then
            mapState.v29LastLine = 'unmapped'
            print(string.format('[TSP_VISGRID_V29] UNMAPPED current=%d total=%d',
                current, tonumber(mapState.pvsSectorCount or 0) or 0))
        end
        return
    end

    local cc = sec.center or {0, 0, 0}
    local x = tonumber(mapState.topoX or cc[1] or 0) or 0
    local y = tonumber(mapState.topoY or cc[2] or 0) or 0
    local z = tonumber(mapState.topoZ or cc[3] or 0) or 0
    local currentKind = tostring(sec.kind or 'room')
    local maxExtra = mapState.v29MaxExtra(currentKind)
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
                    local px = tonumber(p.center[1] or 0) or 0
                    local py = tonumber(p.center[2] or 0) or 0
                    local pz = tonumber(p.center[3] or 0) or 0
                    local dx, dy, dz = px - x, py - y, pz - z
                    local d = math.sqrt(dx*dx + dy*dy + dz*dz)
                    local pkind = tostring(p.kind or 'boundary')
                    local tkind = tostring(target.kind or 'room')
                    local limit = mapState.v29WakeRange(currentKind, tkind, pkind)
                    if d <= limit then
                        seen[other] = true
                        candidates[#candidates + 1] = {
                            id = other, d = d, limit = limit,
                            portal = pid, pkind = pkind, tkind = tkind,
                        }
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
        detail[#detail + 1] = string.format('%d@%.0f/%.0f', c.id, c.d, c.limit)
    end
    table.sort(ids)

    local signature = 'v29:' .. table.concat(ids, ',')
    if force or signature ~= mapState.pvsSignature then
        -- EXACT V26 bridge and zero topology padding. The binary's hard lifecycle
        -- decides renderer/physics presence from this active room mask.
        local ok, err = pcall(camera.setInteriorTopologyPvs,
            mapState.pvsBoxes, ids, 0.0, 0.0)
        if ok then
            mapState.pvsSignature = signature
            mapState.pvsActiveCount = #ids
            if force or signature ~= mapState.v29LastSignature then
                mapState.v29LastSignature = signature
                local ds = #detail > 0 and table.concat(detail, ',') or '-'
                print(string.format(
                    '[TSP_VISGRID_V29] current=%d/%d kind=%s active=%d ids=%s portalWake=%s',
                    current, tonumber(mapState.pvsSectorCount or 0) or 0,
                    currentKind, #ids, table.concat(ids, ','), ds))
            end
        else
            print('[TSP_VISGRID_V29] BRIDGE ERROR: ' .. tostring(err))
            pcall(camera.clearInteriorTopologyPvs)
            mapState.pvsSignature = nil
            mapState.pvsActiveCount = 0
        end
    end
end

'''
s = s[:start] + block + s[end:]

# Door distance must be reconsidered while the player walks WITHIN the same room.
# V26 only needed sector changes; V29 explicitly evaluates portal proximity every frame.
# IMPORTANT: match STRUCTURE, never a byte-for-byte source line.
return_pat = re.compile(
    r'(?m)^(?P<indent>[ \t]*)return[ \t]*\{[ \t]*\n'
    r'(?P=indent)[ \t]+engineHandlers[ \t]*=[ \t]*\{[ \t]*$'
)

return_matches = list(return_pat.finditer(s))

if len(return_matches) != 1:
    candidates = [
        line for line in s.splitlines()
        if 'engineHandlers' in line or line.lstrip().startswith('return {')
    ]
    raise RuntimeError(
        'engineHandlers return structure matches=%d, expected 1; candidates=%r'
        % (len(return_matches), candidates[-20:])
    )

frame_wrapper = r'''-- TSP_VISGRID_LUA_V29_DOOR_PREWAKE_HARD
mapState.v29OnFrameBody = function(dt)
    onFrameBody(dt)

    -- Re-evaluate the cheap portal-distance room set every frame,
    -- even while the player remains inside the same topology sector.
    mapState.updateTopologyPvs(false)
end

'''

rm = return_matches[0]
s = s[:rm.start()] + frame_wrapper + s[rm.start():]

handler_pat = re.compile(
    r'''(?m)^(?P<indent>[ \t]*)onFrame[ \t]*=[ \t]*function[ \t]*\([ \t]*dt[ \t]*\)[ \t]*'''
    r'''guarded[ \t]*\([ \t]*["']onFrame["'][ \t]*,[ \t]*onFrameBody[ \t]*,[ \t]*dt[ \t]*\)[ \t]*'''
    r'''end[ \t]*,?[ \t]*$'''
)

handler_matches = list(handler_pat.finditer(s))

if len(handler_matches) != 1:
    candidates = [
        line for line in s.splitlines()
        if 'onFrame' in line and ('guarded' in line or '=' in line)
    ]
    raise RuntimeError(
        'onFrame guarded-handler structure matches=%d, expected 1; candidates=%r'
        % (len(handler_matches), candidates[-20:])
    )

hm = handler_matches[0]

handler_replacement = (
    hm.group('indent')
    + "onFrame = function(dt) guarded('onFrame', mapState.v29OnFrameBody, dt) end,"
)

s = s[:hm.start()] + handler_replacement + s[hm.end():]

startup_pat = re.compile(
    r"(?m)^(?P<line>[ \t]*print\([\"']\[TSP_VISGRID_V26\] CURRENT-SECTOR-ONLY[^\n]*\)[ \t]*)$"
)

startup_matches = list(startup_pat.finditer(s))

if len(startup_matches) != 1:
    candidates = [
        line for line in s.splitlines()
        if '[TSP_VISGRID_V26] CURRENT-SECTOR-ONLY' in line
    ]
    raise RuntimeError(
        'V26 startup marker structure matches=%d, expected 1; candidates=%r'
        % (len(startup_matches), candidates[-10:])
    )

sm = startup_matches[0]

s = (
    s[:sm.end()]
    + "\nprint('[TSP_VISGRID_V29] DOOR-PREWAKE-HARD v26-core=1 portal-3d=1 rays=0')"
    + s[sm.end():]
)

for token in (
    'TSP_VISGRID_LUA_V29_DOOR_PREWAKE_HARD',
    "pcall(camera.setInteriorTopologyPvs,",
    'mapState.pvsBoxes, ids, 0.0, 0.0',
    'mapState.v29OnFrameBody = function(dt)',
    "currentKind == 'vertical_connector'",
    '[TSP_VISGRID_V29] DOOR-PREWAKE-HARD',
):
    if token not in s:
        raise RuntimeError('V29 Lua postcondition missing: ' + token)
if 'setInteriorClutterResidency' in s:
    raise RuntimeError('V28 clutter bridge reference leaked into V29 profile')
write(lua_out, s)

l = read(launcher_in)
old_profile = '$TSP_VISGRID_DIR/v28_profiles/visgrid-v28-separate-clutter.lua'
new_profile = '$TSP_VISGRID_DIR/v29_profiles/visgrid-v29-door-prewake-hard.lua'
if l.count(old_profile) != 1:
    raise RuntimeError('current launcher V28 selected-profile count=%d, expected 1' % l.count(old_profile))
l = l.replace(old_profile, new_profile, 1)
l = l.replace('Visgrid Profile=v28-separate-clutter', 'Visgrid Profile=v29-door-prewake-hard')
l = l.replace(
    'Visgrid room policy=separate clutter mask; portal-distance first; staircase strict; structural PVS independent',
    'Visgrid room policy=V26 hard delete; current room + physically-near portal destinations')
l = l.replace(
    'Visgrid room policy=separate clutter mask; current + portal-near rooms; structural PVS independent',
    'Visgrid room policy=V26 hard delete; current room + physically-near portal destinations')

for token in (
    'v29_profiles/visgrid-v29-door-prewake-hard.lua',
    'Visgrid Profile=v29-door-prewake-hard',
):
    if token not in l:
        raise RuntimeError('V29 launcher postcondition missing: ' + token)
if 'export TSP_OBJECT_DIAG=1' in l:
    raise RuntimeError('enabled heavy object diagnostics survived launcher patch')
if '# >>> TSP_VISGRID_V24_AUTO_CAPTURE BEGIN' in l:
    raise RuntimeError('synchronous auto-capture block survived launcher patch')
write(launcher_out, l)

print('PASS: V29 generated directly from proven V26 profile.')
print('PASS: only current room + physically-close direct portal destinations are active.')
print('PASS: vertical_connector wakes at most one portal room within <=240 units.')
print('PASS: portal distance is full 3-D and reevaluated every frame.')
print('PASS: V28 independent clutter bridge is not referenced.')
PY_PATCH

if ! python3 -m py_compile "$TMP/patch_v29.py"; then
    fail 55 "embedded V29 Python does not compile"
fi
if ! python3 "$TMP/patch_v29.py" \
    "$TMP/visgrid.v26.lua" "$TMP/visgrid.v29.lua" \
    "$TMP/Morrowind_51.current.sh" "$TMP/Morrowind_51.v29.sh"; then
    fail 56 "V29 profile/launcher generation failed"
fi

if ! bash -n "$TMP/Morrowind_51.v29.sh"; then
    fail 57 "generated V29 launcher has invalid Bash syntax"
fi
echo "PASS generated launcher Bash syntax"

PARSER=""
for x in texlua lua luajit; do
    if command -v "$x" >/dev/null 2>&1; then PARSER="$x"; break; fi
done
if [ -n "$PARSER" ]; then
    cat > "$TMP/check.lua" <<'LUA_CHECK'
local f,e=loadfile(arg[1])
if not f then error(e) end
print('LUA_PARSE_PASS ' .. arg[1])
LUA_CHECK
    if ! "$PARSER" "$TMP/check.lua" "$TMP/visgrid.v29.lua"; then
        fail 58 "generated V29 Lua failed parser=$PARSER"
    fi
    echo "PASS generated V29 Lua syntax: $PARSER"
else
    echo "NOTE: no host Lua parser found; structural Python postconditions passed"
fi

V29_LUA_SHA="$(sha256sum "$TMP/visgrid.v29.lua" | awk '{print $1}')"
V29_LAUNCH_SHA="$(sha256sum "$TMP/Morrowind_51.v29.sh" | awk '{print $1}')"
echo "V29 Lua SHA:      $V29_LUA_SHA"
echo "V29 launcher SHA: $V29_LAUNCH_SHA"

echo
echo "===== 4/7 STATIC REGRESSION SCAN ====="
python3 - "$0" "$TMP/visgrid.v29.lua" "$TMP/Morrowind_51.v29.sh" <<'PY_SCAN'
from pathlib import Path
import re,sys
controller,lua_path,launcher_path=sys.argv[1:4]
c=Path(controller).read_text(encoding='utf-8')
lua=Path(lua_path).read_text(encoding='utf-8')
launcher=Path(launcher_path).read_text(encoding='utf-8')

# Our recurring shell bug class: positional parameters inside UNQUOTED heredocs.
problems=[]
for m in re.finditer(r'<<-?\s*([A-Za-z_][A-Za-z0-9_]*)', c):
    delim=m.group(1)
    body_start=c.find('\n',m.end())
    if body_start < 0: continue
    body_start += 1
    em=re.search(r'(?m)^'+re.escape(delim)+r'[ \t]*$',c[body_start:])
    if not em: continue
    body=c[body_start:body_start+em.start()]
    pm=re.search(r'(?<!\\)\$(?:[0-9]+|[@*#?!-])|(?<!\\)\$\{(?:[0-9]+|[@*#?!-])\}',body)
    if pm:
        line=c.count('\n',0,body_start+pm.start())+1
        problems.append((delim,line,pm.group(0)))
if problems:
    raise SystemExit('unsafe unquoted heredoc positional expansion(s): '+repr(problems))

for token in (
    'TSP_VISGRID_LUA_V29_DOOR_PREWAKE_HARD',
    'mapState.v29OnFrameBody = function(dt)',
    'mapState.pvsBoxes, ids, 0.0, 0.0',
):
    if token not in lua:
        raise SystemExit('V29 Lua scan missing: '+token)
if 'setInteriorClutterResidency' in lua:
    raise SystemExit('V28 clutter bridge leaked into V29 Lua')
for token in ('v29_profiles/visgrid-v29-door-prewake-hard.lua','Visgrid Profile=v29-door-prewake-hard'):
    if token not in launcher:
        raise SystemExit('launcher scan missing: '+token)
print('PASS: no unsafe positional parameters inside unquoted heredocs.')
print('PASS: V29 profile uses old proven topology-PVS bridge only.')
print('PASS: launcher selects V29 profile and keeps auto-capture absent.')
PY_SCAN

echo
echo "===== 5/7 UPLOAD + VERIFY BEFORE INSTALL ====="
if ! scp -q "$TMP/visgrid.v29.lua" "$DEV:/tmp/visgrid-v29-door-prewake-hard.lua"; then
    fail 59 "failed to upload V29 Lua"
fi
if ! scp -q "$TMP/Morrowind_51.v29.sh" "$DEV:/tmp/Morrowind_51.v29.sh"; then
    fail 60 "failed to upload V29 launcher"
fi

ssh "$DEV" bash -s -- \
    "$V27_BACKUP_BIN" "$V27_EXPECT_SHA" \
    /tmp/visgrid-v29-door-prewake-hard.lua "$V29_LUA_SHA" \
    /tmp/Morrowind_51.v29.sh "$V29_LAUNCH_SHA" <<'REMOTE_UPLOAD_VERIFY'
set -u
V27="$1"; V27SHA="$2"; LUA="$3"; LUASHA="$4"; LAUNCH="$5"; LAUNCHSHA="$6"
check_sha() {
    local f="$1" expect="$2" label="$3"
    if [ ! -s "$f" ]; then
        echo "FAIL uploaded file missing/empty: $label ($f)" >&2
        exit 71
    fi
    local got
    got="$(sha256sum "$f" | awk '{print $1}')"
    if [ "$got" != "$expect" ]; then
        echo "FAIL SHA: $label" >&2
        echo "EXPECTED: $expect" >&2
        echo "ACTUAL:   $got" >&2
        exit 72
    fi
    echo "PASS SHA: $label = $got"
}
check_sha "$V27" "$V27SHA" 'proven V27 binary backup'
check_sha "$LUA" "$LUASHA" 'uploaded V29 Lua'
check_sha "$LAUNCH" "$LAUNCHSHA" 'uploaded V29 launcher'
if ! bash -n "$LAUNCH"; then
    echo "FAIL uploaded launcher syntax" >&2
    exit 73
fi
echo "PASS uploaded launcher syntax"
REMOTE_UPLOAD_VERIFY

echo
echo "===== 6/7 INSTALL PROVEN HARD-DELETE CORE + V29 ROOM POLICY ====="
DEVICE_DEPLOY_STARTED=1
ssh "$DEV" bash -s -- \
    "$V27_BACKUP_BIN" "$V27_EXPECT_SHA" "$REMOTE_BIN" \
    /tmp/visgrid-v29-door-prewake-hard.lua "$V29_LUA_SHA" "$V29_PROFILE" "$LIVE_LUA" \
    /tmp/Morrowind_51.v29.sh "$V29_LAUNCH_SHA" "$LAUNCHER" "$V29_DIR" <<'REMOTE_INSTALL'
set -u
V27="$1"; V27SHA="$2"; BIN="$3"
TMP_LUA="$4"; LUASHA="$5"; PROFILE="$6"; LIVE="$7"
TMP_LAUNCH="$8"; LAUNCHSHA="$9"; LAUNCHER="${10}"; V29DIR="${11}"

check_sha() {
    local f="$1" expect="$2" label="$3"
    if [ ! -s "$f" ]; then
        echo "FAIL install file missing/empty: $label ($f)" >&2
        exit 81
    fi
    local got
    got="$(sha256sum "$f" | awk '{print $1}')"
    if [ "$got" != "$expect" ]; then
        echo "FAIL install SHA: $label" >&2
        echo "EXPECTED: $expect" >&2
        echo "ACTUAL:   $got" >&2
        exit 82
    fi
    echo "PASS install SHA: $label = $got"
}
check_has() {
    local token="$1" file="$2"
    if ! grep -Fq -- "$token" "$file"; then
        echo "FAIL install marker: [$token]" >&2
        echo "FILE: $file" >&2
        exit 83
    fi
    echo "PASS install marker: $token"
}
check_absent() {
    local token="$1" file="$2"
    if grep -Fq -- "$token" "$file"; then
        echo "FAIL install forbidden marker: [$token]" >&2
        echo "FILE: $file" >&2
        exit 84
    fi
    echo "PASS install absent: $token"
}

check_sha "$V27" "$V27SHA" 'source V27 binary backup'
check_sha "$TMP_LUA" "$LUASHA" 'source V29 Lua'
check_sha "$TMP_LAUNCH" "$LAUNCHSHA" 'source V29 launcher'

mkdir -p "$V29DIR"
install -m 755 "$V27" "$BIN"
install -m 644 "$TMP_LUA" "$PROFILE"
install -m 644 "$TMP_LUA" "$LIVE"
install -m 755 "$TMP_LAUNCH" "$LAUNCHER"
sync

check_sha "$BIN" "$V27SHA" 'installed V27 hard-delete binary'
check_sha "$PROFILE" "$LUASHA" 'installed V29 profile'
check_sha "$LIVE" "$LUASHA" 'installed live V29 Lua'
check_sha "$LAUNCHER" "$LAUNCHSHA" 'installed V29 launcher'
check_has 'TSP_VISGRID_LUA_V29_DOOR_PREWAKE_HARD' "$LIVE"
check_has 'camera.setInteriorTopologyPvs' "$LIVE"
check_has 'v29_profiles/visgrid-v29-door-prewake-hard.lua' "$LAUNCHER"
check_absent 'setInteriorClutterResidency' "$LIVE"
check_absent '# >>> TSP_VISGRID_V24_AUTO_CAPTURE BEGIN' "$LAUNCHER"
if ! bash -n "$LAUNCHER"; then
    echo "FAIL installed launcher syntax" >&2
    exit 85
fi
echo "PASS installed launcher syntax"

rm -f "$TMP_LUA" "$TMP_LAUNCH"
sync
REMOTE_INSTALL

echo
echo "===== 7/7 SAVE ROLLBACK STATE ====="
cat > "$STATE" <<EOF_STATE
DEVICE_BACKUP='$DEVICE_BACKUP'
LAUNCHER='$LAUNCHER'
REMOTE_BIN='$REMOTE_BIN'
LIVE_LUA='$LIVE_LUA'
V29_PROFILE='$V29_PROFILE'
PRE_BIN_SHA='$PRE_BIN_SHA'
PRE_LUA_SHA='$PRE_LUA_SHA'
V27_EXPECT_SHA='$V27_EXPECT_SHA'
V29_LUA_SHA='$V29_LUA_SHA'
EOF_STATE
trap - ERR

echo
echo "============================================================"
echo "ROOMWAKE V29 INSTALLED"
echo "============================================================"
echo "Hard removal core: exact V27 pre-V28 binary SHA $V27_EXPECT_SHA"
echo "  (same V25/V26 renderer + physics/nav/mechanics suppress/wake path)"
echo
echo "CLUTTER ROOM POLICY:"
echo "  current room = always materialized"
echo "  only DIRECT portal destinations may prewake"
echo "  portal proximity = full 3-D distance to portal center"
echo "  small room target = 180 (+35 for a door)"
echo "  normal room target = 220 (+35 for a door)"
echo "  corridor target = 260 (+35 for a door)"
echo "  large-open target = 300 (+35 for a door)"
echo "  vertical connector current room = max ONE extra and <=240"
echo "  no recent-room tail / no whole floor / no ray clutter rooms / no AABB halo"
echo
echo "STRUCTURE:"
echo "  V27 static-wall/floor/stair bypass retained"
echo "  doors/actors remain materialized"
echo "  V27 clean-exit parked-ref purge retained"
echo
echo "FIRST TEST: Caldera staircase."
echo "At the third-floor blank wall we need BOTH:"
echo "  [TSP_VISGRID_V29] ... active=1 (or 2 only beside the actual doorway)"
echo "  [TSP_ROOMOBJ_V27] pvs=1 ... parked=<large>"
echo
echo "Then approach the doorway: active should become 2 BEFORE crossing it."
echo "After one run:"
echo "  cd ~/Downloads"
echo "  ./$(basename "$0") collect"
echo
echo "Rollback: ./$(basename "$0") rollback"
echo "============================================================"
