#!/usr/bin/env bash
# OpenMW 0.51 TSP — V30 R3 open-space cluster hotfix
# Lua/profile-only. NO OPENMW REBUILD.

set -u

DL="$HOME/Downloads"
DEV="${TSP_DEVICE:-root@192.168.1.25}"
ROOT="/mnt/SDCARD/data/ports/openmw51"
BIN="$ROOT/bin/openmw-0.51"
LUA_DIR="$ROOT/mods/TSPInteriorVisGrid/scripts/TSPInteriorVisGrid"
LIVE_LUA="$LUA_DIR/visgrid.lua"
PROFILE="$LUA_DIR/v30_profiles/visgrid-v30-floor-actor-roomwake.lua"
STATE="$DL/openmw51-roomwake-v30-r3-open-space-cluster.state"
EXPECTED_BIN_SHA="9203cc3dbdd4c0352c2e2db8c09a3ae10241972b5a1bb93c87b3e9f28ff0904d"
STAMP="$(date +%Y%m%d-%H%M%S)"
TMP="$(mktemp -d "$DL/.roomwake-v30-r3.XXXXXX")"

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
    out="$DL/openmw51-roomwake-v30-r3-open-space-validation-$(date +%Y%m%d-%H%M%S).txt"
    if ! ssh "$DEV" bash -s -- "$ROOT" >"$out" <<'REMOTE_COLLECT'
ROOT="$1"
for f in "$ROOT/openmw_051_log.txt" "$ROOT/config-0.51/openmw.log" "$ROOT/openmw.log"; do
    if [ -f "$f" ]; then
        tail -n 18000 "$f" |
            grep -E '\[TSP_VISGRID_V30_R3\]|\[TSP_VISGRID_V30\]|\[TSP_ROOMOBJ_V30\]|\[TSP_ACTOR_V30\]|BRIDGE ERROR|Bad LiveCellRef cast|failed to render' |
            tail -700
    fi
done
REMOTE_COLLECT
    then
        rm -f "$out"
        die 20 "failed to collect V30 R3 validation log"
    fi
    echo "Saved: $out"
    echo
    tail -80 "$out" 2>/dev/null || true
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

if grep -Fq 'TSP_VISGRID_LUA_V30_R3_OPEN_SPACE_CLUSTER' "$LIVE"; then
    echo "FAIL R3 marker survived rollback in live Lua" >&2
    exit 3
fi

echo "PASS V30 R3 rollback restored prior profile/live Lua/launcher"
REMOTE_ROLLBACK
    then
        die 23 "V30 R3 rollback failed"
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
echo "OPENMW 0.51 — V30 R3 OPEN-SPACE CLUSTER HOTFIX"
echo "============================================================"
echo "NO OPENMW REBUILD."
echo "Same-floor synthetic boundary splits stay resident together."
echo "Adjacent stair/landing connector sectors stay resident, but"
echo "connectors are never traversed into another floor's room."
echo "Real doors remain barriers and prewake slightly earlier."
echo "============================================================"

need_cmd ssh
need_cmd scp
need_cmd python3
need_cmd sha256sum

if ! ssh -o BatchMode=yes -o ConnectTimeout=8 "$DEV" true; then
    die 30 "SSH failed: $DEV"
fi
echo "PASS SSH: $DEV"

LAUNCHER="$(resolve_launcher)" || die 31 "could not resolve Morrowind_51.sh on device"
if [ -z "$LAUNCHER" ]; then die 32 "resolved launcher path is empty"; fi
echo "PASS launcher: $LAUNCHER"

echo
echo "===== 1/5 VERIFY INSTALLED V30 BASELINE ====="

BIN_SHA="$(remote_sha "$BIN")" || die 33 "failed to hash installed V30 binary"
if [ "$BIN_SHA" != "$EXPECTED_BIN_SHA" ]; then
    echo "EXPECTED: $EXPECTED_BIN_SHA" >&2
    echo "GOT:      $BIN_SHA" >&2
    die 34 "installed binary is not the V30 actor/floor build"
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
    if grep -Fq 'TSP_VISGRID_LUA_V30_R3_OPEN_SPACE_CLUSTER' "$f"; then
        echo "FAIL R3 marker already present; refusing ambiguous reapplication: $f" >&2
        exit 4
    fi
    if grep -Fq 'setInteriorClutterResidency' "$f"; then
        echo "FAIL dead V28 clutter bridge found: $f" >&2
        exit 5
    fi
done

if ! grep -Fq 'v30_profiles/visgrid-v30-floor-actor-roomwake.lua' "$LAUNCH"; then
    echo "FAIL launcher does not select the V30 profile: $LAUNCH" >&2
    exit 6
fi

echo "PASS working V30 Lua/profile/launcher baseline"
REMOTE_VERIFY
then
    die 35 "device V30 baseline verification failed"
fi

echo
echo "===== 2/5 BACKUP + PULL CURRENT V30 LUA ====="

DEVICE_BACKUP="$ROOT/backups/roomwake-v30-r3-open-space-$STAMP"

if ! ssh "$DEV" bash -s -- "$DEVICE_BACKUP" "$LIVE_LUA" "$PROFILE" "$LAUNCHER" <<'REMOTE_BACKUP'
B="$1"
LIVE="$2"
PROFILE="$3"
LAUNCH="$4"

mkdir -p "$B" || {
    echo "FAIL could not create backup directory: $B" >&2
    exit 2
}

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

if ! scp -q "$DEV:$PROFILE" "$TMP/visgrid.v30.lua"; then
    die 41 "failed to pull current V30 profile"
fi
echo "PASS pulled current V30 profile"

cat > "$STATE" <<EOF_STATE
DEVICE_BACKUP='$DEVICE_BACKUP'
LAUNCHER='$LAUNCHER'
EOF_STATE
echo "PASS rollback state: $STATE"

echo
echo "===== 3/5 GENERATE OPEN-SPACE CLUSTER R3 LUA ====="

cat > "$TMP/r3_payload.lua" <<'LUA_R3'
-- TSP_VISGRID_LUA_V30_R3_OPEN_SPACE_CLUSTER
-- Treat synthetic same-floor boundary splits as one open visual room.
-- Physical doors and vertical connectors remain residency barriers.
print('[TSP_VISGRID_V30_R3] OPEN-SPACE-CLUSTER same-floor-boundary=1 connector-attach=1 door-barrier=1')

mapState.v30R3LastSignature = ''

mapState.v30R3BuildOpenCluster = function(current, playerFloor)
    local tc = mapState.topoCell
    local sectors = tc and tc.sectors or nil
    local portals = tc and tc.portals or nil
    local seen = {}
    local queue = {}
    local ids = {}

    if sectors == nil or portals == nil or current <= 0 or sectors[current] == nil then
        if current > 0 then
            ids[1] = current
            seen[current] = true
        end
        return ids, seen, #ids, 0
    end

    seen[current] = true
    queue[1] = current

    local currentKind = tostring(sectors[current].kind or 'room')
    if currentKind == 'vertical_connector' then
        ids[1] = current
        return ids, seen, 0, 1
    end

    -- Flood only through synthetic BOUNDARY edges joining ordinary sectors on
    -- the same inferred floor. A real door is never crossed here, and a
    -- connector is never used as a bridge to another room/floor.
    local head = 1
    while head <= #queue do
        local sid = queue[head]
        head = head + 1
        local src = sectors[sid]
        if src ~= nil and src.portals ~= nil then
            for i = 1, #src.portals do
                local pid = tonumber(src.portals[i] or 0) or 0
                local p = portals[pid]
                if p ~= nil and tostring(p.kind or 'boundary') == 'boundary' then
                    local a = tonumber(p.a or 0) or 0
                    local b = tonumber(p.b or 0) or 0
                    local other = 0
                    if a == sid then other = b
                    elseif b == sid then other = a end

                    local target = other > 0 and sectors[other] or nil
                    if target ~= nil and not seen[other] then
                        local targetKind = tostring(target.kind or 'room')
                        local targetFloor = tonumber(target.floor)
                        if targetKind ~= 'vertical_connector'
                            and playerFloor ~= nil and targetFloor ~= nil
                            and targetFloor == playerFloor then
                            seen[other] = true
                            queue[#queue + 1] = other
                        end
                    end
                end
            end
        end
    end

    -- queue now contains the ordinary-sector open-space component.
    local normalCount = #queue
    for i = 1, #queue do
        ids[#ids + 1] = queue[i]
    end

    -- Keep staircase/landing sectors that directly touch this open space.
    -- They are allowed to exist, but we DO NOT traverse through them, so they
    -- cannot pull a room from the floor above/below into the active set.
    for qi = 1, #queue do
        local sid = queue[qi]
        local src = sectors[sid]
        if src ~= nil and src.portals ~= nil then
            for i = 1, #src.portals do
                local pid = tonumber(src.portals[i] or 0) or 0
                local p = portals[pid]
                if p ~= nil and tostring(p.kind or 'boundary') == 'boundary' then
                    local a = tonumber(p.a or 0) or 0
                    local b = tonumber(p.b or 0) or 0
                    local other = 0
                    if a == sid then other = b
                    elseif b == sid then other = a end
                    local target = other > 0 and sectors[other] or nil
                    if target ~= nil and not seen[other]
                        and tostring(target.kind or 'room') == 'vertical_connector' then
                        seen[other] = true
                        ids[#ids + 1] = other
                    end
                end
            end
        end
    end

    table.sort(ids)
    return ids, seen, normalCount, #ids - normalCount
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
    local sectors = mapState.topoCell.sectors
    local portals = mapState.topoCell.portals
    local sec = current > 0 and sectors[current] or nil
    if current <= 0 or sec == nil then
        pcall(camera.clearInteriorTopologyPvs)
        mapState.pvsSignature = nil
        mapState.pvsActiveCount = 0
        if force or mapState.v30LastLine ~= 'r3-unmapped' then
            mapState.v30LastLine = 'r3-unmapped'
            print(string.format('[TSP_VISGRID_V30_R3] UNMAPPED current=%d total=%d',
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
    local ids, seen, openCount, connectorCount =
        mapState.v30R3BuildOpenCluster(current, playerFloor)

    local candidates = {}
    local candidateSeen = {}
    local scanIds = {}

    if currentKind == 'vertical_connector' then
        scanIds[1] = current
    else
        -- Scan only ordinary sectors from the open component. Connector sectors
        -- are resident but never used as a path to prewake another floor.
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
                    if a == sid then other = b
                    elseif b == sid then other = a end

                    local target = other > 0 and sectors[other] or nil
                    if target ~= nil and not seen[other] and not candidateSeen[other] then
                        local targetKind = tostring(target.kind or 'room')
                        local targetFloor = tonumber(target.floor)
                        local pkind = tostring(p.kind or 'boundary')

                        local allowed = false
                        if currentKind == 'vertical_connector' then
                            -- Preserve V30 staircase behavior: only the room on
                            -- the player's inferred floor may wake from the stair.
                            allowed = targetKind == 'vertical_connector'
                                or (playerFloor ~= nil and targetFloor ~= nil
                                    and targetFloor == playerFloor)
                        else
                            -- Ordinary open-space sectors only prewake across a
                            -- REAL DOOR. Synthetic same-floor boundaries were
                            -- already absorbed into the open cluster above.
                            allowed = pkind == 'door'
                                and (targetKind == 'vertical_connector'
                                    or (playerFloor ~= nil and targetFloor ~= nil
                                        and targetFloor == playerFloor))
                        end

                        if allowed then
                            local px = tonumber(p.center[1] or 0) or 0
                            local py = tonumber(p.center[2] or 0) or 0
                            local pz = tonumber(p.center[3] or 0) or 0
                            local dx, dy, dz = px - x, py - y, pz - z
                            local d = math.sqrt(dx*dx + dy*dy + dz*dz)
                            local limit = mapState.v30WakeRange(
                                currentKind, targetKind, pkind)
                            if d <= limit then
                                candidateSeen[other] = true
                                candidates[#candidates + 1] = {
                                    id = other, d = d, limit = limit,
                                    portal = pid, pkind = pkind,
                                    tkind = targetKind, floor = targetFloor,
                                }
                            end
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

    local maxExtra = mapState.v30MaxExtra(currentKind)
    local detail = {}
    local n = math.min(maxExtra, #candidates)
    for i = 1, n do
        local c = candidates[i]
        if not seen[c.id] then
            seen[c.id] = true
            ids[#ids + 1] = c.id
            detail[#detail + 1] = string.format('%d@%.0f/%.0f:%s:f%s',
                c.id, c.d, c.limit, tostring(c.pkind),
                tostring(c.floor or '?'))
        end
    end
    table.sort(ids)

    local signature = 'v30r3:f' .. tostring(playerFloor or '?')
        .. ':o' .. tostring(openCount)
        .. ':c' .. tostring(connectorCount)
        .. ':' .. table.concat(ids, ',')

    if force or signature ~= mapState.pvsSignature then
        local ok, err = pcall(camera.setInteriorTopologyPvs,
            mapState.pvsBoxes, ids, 0.0, 0.0)
        if ok then
            mapState.pvsSignature = signature
            mapState.pvsActiveCount = #ids
            if force or signature ~= mapState.v30R3LastSignature then
                mapState.v30R3LastSignature = signature
                local ds = #detail > 0 and table.concat(detail, ',') or '-'
                print(string.format(
                    '[TSP_VISGRID_V30_R3] current=%d/%d kind=%s floor=%s open=%d connectors=%d active=%d ids=%s doorWake=%s',
                    current, tonumber(mapState.pvsSectorCount or 0) or 0,
                    currentKind, tostring(playerFloor or '?'),
                    openCount, connectorCount, #ids,
                    table.concat(ids, ','), ds))
            end
        else
            print('[TSP_VISGRID_V30_R3] BRIDGE ERROR: ' .. tostring(err))
            pcall(camera.clearInteriorTopologyPvs)
            mapState.pvsSignature = nil
            mapState.pvsActiveCount = 0
        end
    end
end

LUA_R3

cat > "$TMP/patch_r3.py" <<'PY_PATCH'
#!/usr/bin/env python3
import sys

src, dst, payload_path = sys.argv[1:4]

with open(src, 'r', encoding='utf-8', newline='') as f:
    s = f.read()
with open(payload_path, 'r', encoding='utf-8', newline='') as f:
    payload = f.read()

required = (
    'TSP_VISGRID_LUA_V30_FLOOR_ACTOR_ROOMWAKE',
    'mapState.v30InferFloor',
    'mapState.v30WakeRange',
    'mapState.v30MaxExtra',
    'mapState.v30BaseOnFrame = ',
    'camera.setInteriorTopologyPvs',
)
for token in required:
    if token not in s:
        raise RuntimeError('V30 profile missing required token: ' + token)

mark = 'TSP_VISGRID_LUA_V30_R3_OPEN_SPACE_CLUSTER'
if mark in s:
    raise RuntimeError('R3 marker already present; refusing reapplication')
if 'setInteriorClutterResidency' in s:
    raise RuntimeError('dead V28 clutter bridge present in V30 baseline')
if mark not in payload:
    raise RuntimeError('R3 payload marker missing')

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
    'mapState.v30R3BuildOpenCluster',
    "tostring(p.kind or 'boundary') == 'boundary'",
    "targetKind ~= 'vertical_connector'",
    "pkind == 'door'",
    'mapState.pvsBoxes, ids, 0.0, 0.0',
    '[TSP_VISGRID_V30_R3] current=',
):
    if token not in s:
        raise RuntimeError('R3 postcondition missing: ' + token)

with open(dst, 'w', encoding='utf-8', newline='\n') as f:
    f.write(s)

print('PASS: V30 R3 open-space cluster generated.')
print('PASS: same-floor ordinary boundary sectors flood as one visual room.')
print('PASS: adjacent connector sectors stay resident but are never traversed to another floor.')
print('PASS: real doors remain barriers and use earlier prewake.')
PY_PATCH

if ! python3 -m py_compile "$TMP/patch_r3.py"; then
    die 50 "embedded R3 patcher does not compile under host Python"
fi

if ! python3 "$TMP/patch_r3.py" \
    "$TMP/visgrid.v30.lua" "$TMP/visgrid.v30.r3.lua" "$TMP/r3_payload.lua"
then
    die 51 "R3 Lua transformation failed"
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
local f, e = loadfile(arg[1])
if not f then error(e) end
print('LUA_PARSE_PASS ' .. arg[1])
LUA_CHECK
    if ! "$PARSER" "$TMP/check.lua" "$TMP/visgrid.v30.r3.lua"; then
        die 52 "generated R3 Lua failed parser: $PARSER"
    fi
    echo "PASS generated R3 Lua syntax: $PARSER"
else
    echo "INFO: no standalone Lua CLI present; continuing with prevalidated R3 payload + structural checks."
fi

R3_SHA="$(sha256sum "$TMP/visgrid.v30.r3.lua" | awk '{print $1}')"
echo "V30 R3 Lua SHA: $R3_SHA"

for token in \
  TSP_VISGRID_LUA_V30_R3_OPEN_SPACE_CLUSTER \
  mapState.v30R3BuildOpenCluster \
  "pkind == 'door'" \
  "targetKind ~= 'vertical_connector'" \
  'mapState.pvsBoxes, ids, 0.0, 0.0'
do
    if ! grep -Fq "$token" "$TMP/visgrid.v30.r3.lua"; then
        die 53 "generated R3 Lua missing required token: $token"
    fi
done
echo "PASS generated R3 structural postconditions"

echo
echo "===== 4/5 STAGE + INSTALL LUA-ONLY HOTFIX ====="

REMOTE_TMP="/tmp/visgrid-v30-r3-open-space.lua"
if ! scp -q "$TMP/visgrid.v30.r3.lua" "$DEV:$REMOTE_TMP"; then
    die 60 "failed to upload staged R3 Lua"
fi

if ! ssh "$DEV" bash -s -- \
    "$REMOTE_TMP" "$R3_SHA" "$PROFILE" "$LIVE_LUA" "$LAUNCHER" "$BIN" "$EXPECTED_BIN_SHA" <<'REMOTE_INSTALL'
TMP_LUA="$1"
EXPECTED_LUA="$2"
PROFILE="$3"
LIVE="$4"
LAUNCH="$5"
BIN="$6"
EXPECTED_BIN="$7"

sha() { sha256sum "$1" | awk '{print $1}'; }

if [ ! -f "$TMP_LUA" ]; then
    echo "FAIL staged R3 Lua missing: $TMP_LUA" >&2
    exit 2
fi

GOT="$(sha "$TMP_LUA")"
if [ "$GOT" != "$EXPECTED_LUA" ]; then
    echo "FAIL staged R3 Lua SHA mismatch" >&2
    echo "EXPECTED: $EXPECTED_LUA" >&2
    echo "GOT:      $GOT" >&2
    exit 3
fi

BIN_SHA="$(sha "$BIN")"
if [ "$BIN_SHA" != "$EXPECTED_BIN" ]; then
    echo "FAIL V30 binary changed before Lua install" >&2
    echo "EXPECTED: $EXPECTED_BIN" >&2
    echo "GOT:      $BIN_SHA" >&2
    exit 4
fi

install -m 644 "$TMP_LUA" "$PROFILE"
install -m 644 "$TMP_LUA" "$LIVE"
rm -f "$TMP_LUA"
sync

for f in "$PROFILE" "$LIVE"; do
    GOT="$(sha "$f")"
    if [ "$GOT" != "$EXPECTED_LUA" ]; then
        echo "FAIL installed R3 Lua SHA mismatch: $f" >&2
        exit 5
    fi
    if ! grep -Fq 'TSP_VISGRID_LUA_V30_R3_OPEN_SPACE_CLUSTER' "$f"; then
        echo "FAIL installed R3 marker missing: $f" >&2
        exit 6
    fi
    if grep -Fq 'setInteriorClutterResidency' "$f"; then
        echo "FAIL dead V28 clutter bridge found after install: $f" >&2
        exit 7
    fi
done

if ! grep -Fq 'v30_profiles/visgrid-v30-floor-actor-roomwake.lua' "$LAUNCH"; then
    echo "FAIL launcher V30 profile selection changed unexpectedly: $LAUNCH" >&2
    exit 8
fi

echo "PASS installed V30 R3 profile/live Lua"
echo "PASS V30 actor/floor binary unchanged"
REMOTE_INSTALL
then
    echo
    echo "INSTALL FAILED — restoring previous Lua/profile/launcher..."
    rollback || true
    die 61 "V30 R3 install/verification failed"
fi

echo
echo "===== 5/5 FINAL VERIFY ====="

FINAL_BIN_SHA="$(remote_sha "$BIN")" || die 70 "failed final binary hash"
FINAL_LUA_SHA="$(remote_sha "$LIVE_LUA")" || die 71 "failed final live Lua hash"

if [ "$FINAL_BIN_SHA" != "$EXPECTED_BIN_SHA" ]; then
    die 72 "final binary SHA changed unexpectedly: $FINAL_BIN_SHA"
fi
if [ "$FINAL_LUA_SHA" != "$R3_SHA" ]; then
    die 73 "final live Lua SHA mismatch: $FINAL_LUA_SHA"
fi

echo "PASS final V30 binary SHA unchanged: $FINAL_BIN_SHA"
echo "PASS final V30 R3 Lua SHA: $FINAL_LUA_SHA"

echo
echo "============================================================"
echo "V30 R3 OPEN-SPACE CLUSTER INSTALLED — NO REBUILD"
echo "============================================================"
echo "Test the SAME Caldera room from both sides."
echo "Then test the staircase once to make sure lower-floor rooms still stay off."
echo
echo "Collect:"
echo "  cd ~/Downloads"
echo "  ./hotfix_openmw51_tsp_roomwake_v30_R3_open_space_cluster.sh collect"
echo
echo "Rollback:"
echo "  ./hotfix_openmw51_tsp_roomwake_v30_R3_open_space_cluster.sh rollback"
echo "============================================================"
