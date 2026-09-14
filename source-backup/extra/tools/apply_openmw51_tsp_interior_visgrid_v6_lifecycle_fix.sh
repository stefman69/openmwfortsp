#!/usr/bin/env bash
set -Eeuo pipefail

DEV="${TSP_DEV:-root@192.168.1.25}"
STAMP="$(date +%Y%m%d-%H%M%S)"

ROOT="/mnt/SDCARD/data/ports/openmw51"
BIN="$ROOT/bin/openmw-0.51"
MOD="$ROOT/mods/TSPInteriorVisGrid"
OMW="$MOD/TSPInteriorVisGrid.omwscripts"
LUA="$MOD/scripts/TSPInteriorVisGrid/visgrid.lua"

PKG="$HOME/Downloads/openmw51-interior-visgrid-v6-lifecycle-fix-$STAMP"
LOG="$PKG/install.log"
mkdir -p "$PKG"

fail_report() {
    local rc="${1:-1}"
    local line="${2:-unknown}"
    local cmd="${3:-unknown}"
    trap - ERR
    set +e
    local report="$PKG/STOPPED_ERROR.txt"
    {
        echo "=================================================================="
        echo "VISGRID V6 STOPPED SAFELY"
        echo "=================================================================="
        echo "Date: $(date)"
        echo "Exit code: $rc"
        echo "Line: $line"
        echo "Command: $cmd"
        echo
        [ -f "$LOG" ] && tail -220 "$LOG" || true
        echo
        echo "Preserved at: $PKG"
    } 2>&1 | tee "$report"
    if [ -t 0 ]; then
        read -r -p "Press Enter to return to the shell... " _ || true
    fi
    exit "$rc"
}
trap 'fail_report "$?" "$LINENO" "$BASH_COMMAND"' ERR

exec > >(tee "$LOG") 2>&1

echo "=================================================================="
echo "OPENMW 0.51 TSP — INTERIOR VISGRID V6 LIFECYCLE/RAY FIX"
echo "=================================================================="
echo
echo "Primary bug fixed:"
echo "  V5 built screenPos[] only in onInit."
echo "  Existing saves load an already-created script via onLoad, so screenPos[]"
echo "  could remain empty and every ray failed before nearby.castRay."
echo
echo "V6:"
echo "  - no cached viewport Vector2 objects at all"
echo "  - computes util.vector2(u,v) fresh for every ray, like working V1/V4"
echo "  - uses dir:length() and dir/len"
echo "  - has onInit AND onLoad runtime reset handlers"
echo "  - 3000 interior maximum retained"
echo "  - V5 persistent history/scheduler retained"
echo "  - vertical row cap DISABLED for this isolation run"
echo "  - no per-frame camera.setViewDistance spam"
echo "  - stage-specific ray diagnostics"
echo
echo "No C++ rebuild."
echo "Package: $PKG"
echo

echo "===== 1/7 VERIFY CURRENT INSTALL ====="
ssh -o BatchMode=yes -o ConnectTimeout=8 "$DEV" "
set -e
test -s '$BIN'
test -f '$OMW'
test -f '$LUA'
grep -a -q 'TSP_INTERIOR_VISGRID_051_V1' '$BIN'
grep -Fq 'PLAYER: scripts/TSPInteriorVisGrid/visgrid.lua' '$OMW'
echo \"Host: \$(hostname)\"
echo \"Date: \$(date)\"
echo 'PASS: V1 C++ bridge present.'
"

if ssh "$DEV" 'pidof openmw-0.51 >/dev/null 2>&1 || pidof openmw >/dev/null 2>&1'; then
    echo "ERROR: OpenMW is running. Exit normally, then rerun this script."
    exit 20
fi

echo "PASS: OpenMW is closed."

echo
echo "===== 2/7 BACK UP CURRENT SENSOR ====="
REMOTE_BACKUP="$ROOT/backups/interior-visgrid-v6-lifecycle-fix-$STAMP"

ssh "$DEV" "
set -e
mkdir -p '$REMOTE_BACKUP'
cp -p '$LUA' '$REMOTE_BACKUP/visgrid.lua.before-v6'
cp -p '$OMW' '$REMOTE_BACKUP/TSPInteriorVisGrid.omwscripts'
sha256sum '$BIN' '$LUA' '$OMW' > '$REMOTE_BACKUP/SHA256SUMS.before.txt'
sync
cat '$REMOTE_BACKUP/SHA256SUMS.before.txt'
"

scp -q "$DEV:$LUA" "$PKG/visgrid.lua.before-v6"
scp -q "$DEV:$OMW" "$PKG/TSPInteriorVisGrid.omwscripts.before-v6"
echo "PASS: rollback copies preserved."

echo
echo "===== 3/7 GENERATE V6 SENSOR ====="

cat > "$PKG/visgrid.lua" <<'EOF_LUA'
-- TSP_INTERIOR_VISGRID_LUA_V6
--
-- LIFECYCLE + RAY PIPELINE FIX
--
-- Critical fix:
--   Do not rely on onInit to build runtime ray tables.
--   OpenMW calls onInit only when a script is CREATED. Existing saved scripts
--   are loaded through onLoad. V5 cached screenPos[] only in onInit, causing
--   nil viewport coordinates on existing saves and zero castRay attempts.
--
-- V6 computes viewport coordinates fresh in sampleTile(), exactly like the
-- working V1/V4 path, and initializes pure-Lua state from onInit AND onLoad.
--
-- C++ culler remains TSP_INTERIOR_VISGRID_051_V1.

local camera = require('openmw.camera')
local nearby = require('openmw.nearby')
local self = require('openmw.self')
local util = require('openmw.util')

local COLS = 8
local ROWS = 5
local COUNT = COLS * ROWS

local MAX_DIST = 3000.0
local PADDING = 350.0

local RAYS_STEADY = 5
local RAYS_BURST = 10
local BURST_SECONDS = 0.80

local CLOSE_CONFIRM_TOLERANCE = 240.0
local TEMPORAL_ALPHA = 0.55

local MOVE_SLACK_SCALE = 1.10
local ANGLE_SLACK_SCALE = 0.35
local ANGLE_SLACK_DEPTH_FLOOR = 500.0
local MAX_TILE_SLACK = 350.0

local FAST_TURN_TRIGGER = math.rad(2.0)
local TELEPORT_RESET_DIST = 1200.0
local LOAD_GRACE_SECONDS = 2.0

local OPENING_JUMP = 700.0
local OPENING_PRIORITY = 8

local PRINT_PERIOD = 1.0
local RAY_MASK = nearby.COLLISION_TYPE.World + (nearby.COLLISION_TYPE.Door or 0)

-- Disable extra vertical experiment until the ray/culling path is proven alive.
local ENABLE_VERTICAL_CAP = false

local provenDepth = {}
local slack = {}
local pendingClose = {}
local age = {}
local priority = {}

local inInterior = false
local lastCell = nil
local lastEye = nil
local lastYaw = nil
local lastPitch = nil

local burstRemaining = 0.0
local statusElapsed = 0.0
local interiorElapsed = 0.0

local lastStatsTested = 0.0
local lastStatsCulled = 0.0

-- Stage-specific diagnostics.
local dirFail = 0
local lenFail = 0
local normFail = 0
local castFail = 0
local castAttempts = 0
local castOK = 0
local hitCount = 0
local missCount = 0
local openingEvents = 0

local firstDirError = nil
local firstLenError = nil
local firstNormError = nil
local firstCastError = nil

local function clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

local function angleDiffSigned(a, b)
    local d = a - b
    while d > math.pi do d = d - 2.0 * math.pi end
    while d < -math.pi do d = d + 2.0 * math.pi end
    return d
end

local function resetTables()
    for i = 1, COUNT do
        provenDepth[i] = MAX_DIST
        slack[i] = 0.0
        pendingClose[i] = nil
        age[i] = 100000
        priority[i] = 0
    end
end

local function resetDiagnostics()
    dirFail = 0
    lenFail = 0
    normFail = 0
    castFail = 0
    castAttempts = 0
    castOK = 0
    hitCount = 0
    missCount = 0
    openingEvents = 0
    firstDirError = nil
    firstLenError = nil
    firstNormError = nil
    firstCastError = nil
end

local function resetRuntimeState()
    resetTables()
    inInterior = false
    lastCell = nil
    lastEye = nil
    lastYaw = nil
    lastPitch = nil
    burstRemaining = 0.0
    statusElapsed = 0.0
    interiorElapsed = 0.0
    lastStatsTested = 0.0
    lastStatsCulled = 0.0
    resetDiagnostics()
end

-- Run once when the Lua chunk itself is loaded, regardless of whether OpenMW
-- later invokes onInit or onLoad.
resetRuntimeState()

local function effectiveDepth(idx)
    return clamp(
        (provenDepth[idx] or MAX_DIST) + (slack[idx] or 0.0),
        1.0,
        MAX_DIST
    )
end

local function publishGrid()
    -- Preserve successful V1's conservative 3x3 MAX dilation.
    local out = {}

    for row = 1, ROWS do
        for col = 1, COLS do
            local best = 0.0

            for rr = math.max(1, row - 1), math.min(ROWS, row + 1) do
                for cc = math.max(1, col - 1), math.min(COLS, col + 1) do
                    local idx = (rr - 1) * COLS + cc
                    local d = effectiveDepth(idx)
                    if d > best then best = d end
                end
            end

            out[(row - 1) * COLS + col] = best
        end
    end

    camera.setInteriorVisibilityGrid(COLS, ROWS, out, PADDING)
    return out
end

local function queueOpeningFan(idx)
    openingEvents = openingEvents + 1
    burstRemaining = math.max(burstRemaining, BURST_SECONDS)

    local row = math.floor((idx - 1) / COLS) + 1
    local col = ((idx - 1) % COLS) + 1

    for rr = math.max(1, row - 2), math.min(ROWS, row + 2) do
        for cc = math.max(1, col - 2), math.min(COLS, col + 2) do
            local j = (rr - 1) * COLS + cc
            local manhattan = math.abs(rr - row) + math.abs(cc - col)
            priority[j] = math.max(priority[j] or 0, OPENING_PRIORITY - manhattan)
        end
    end
end

local function acceptDepth(idx, measured)
    measured = clamp(measured or MAX_DIST, 1.0, MAX_DIST)

    local currentProven = provenDepth[idx] or MAX_DIST
    local currentEffective = effectiveDepth(idx)

    -- A valid fresh sample clears this tile's temporary movement slack.
    slack[idx] = 0.0
    age[idx] = 0

    if measured >= currentEffective - 1.0 then
        local isOpening =
            (measured >= MAX_DIST - 1.0 and currentProven < MAX_DIST - OPENING_JUMP)
            or (measured - currentProven >= OPENING_JUMP)

        provenDepth[idx] = measured
        pendingClose[idx] = nil

        if isOpening then
            queueOpeningFan(idx)
        end
        return
    end

    local pending = pendingClose[idx]

    if pending ~= nil and math.abs(pending - measured) <= CLOSE_CONFIRM_TOLERANCE then
        local confirmed = 0.5 * (pending + measured)

        if currentProven >= MAX_DIST - 1.0 then
            -- Fast initial contraction, preserving successful V1 behavior.
            provenDepth[idx] = confirmed
        elseif confirmed >= currentProven then
            provenDepth[idx] = confirmed
        else
            provenDepth[idx] =
                currentProven * (1.0 - TEMPORAL_ALPHA)
                + confirmed * TEMPORAL_ALPHA
        end

        pendingClose[idx] = nil
    else
        pendingClose[idx] = measured
        priority[idx] = math.max(priority[idx] or 0, OPENING_PRIORITY)
    end
end

local function sampleTile(idx, eye)
    -- EXACT V1-style fresh camera-space coordinate. Do not cache this Vector2.
    local row = math.floor((idx - 1) / COLS) + 1
    local col = ((idx - 1) % COLS) + 1
    local u = (col - 0.5) / COLS
    local v = (row - 0.5) / ROWS

    local okDir, dirOrErr = pcall(
        camera.viewportToWorldVector,
        util.vector2(u, v)
    )

    if not okDir or dirOrErr == nil then
        dirFail = dirFail + 1
        if firstDirError == nil then firstDirError = tostring(dirOrErr) end
        return
    end

    local dir = dirOrErr

    local okLen, lenOrErr = pcall(function()
        return dir:length()
    end)

    if not okLen or lenOrErr == nil or lenOrErr <= 0.0001 then
        lenFail = lenFail + 1
        if firstLenError == nil then firstLenError = tostring(lenOrErr) end
        return
    end

    local len = lenOrErr

    -- Avoid Vector3:normalize() entirely for this isolation test.
    local okNorm, normOrErr = pcall(function()
        return dir / len
    end)

    if not okNorm or normOrErr == nil then
        normFail = normFail + 1
        if firstNormError == nil then firstNormError = tostring(normOrErr) end
        return
    end

    local norm = normOrErr
    local dest = eye + norm * MAX_DIST

    castAttempts = castAttempts + 1

    local okRay, resOrErr = pcall(
        nearby.castRay,
        eye,
        dest,
        { collisionType = RAY_MASK }
    )

    if not okRay or resOrErr == nil then
        castFail = castFail + 1
        if firstCastError == nil then firstCastError = tostring(resOrErr) end
        return
    end

    castOK = castOK + 1
    local res = resOrErr
    local d = MAX_DIST

    if res.hit and res.hitPos ~= nil then
        hitCount = hitCount + 1
        d = (res.hitPos - eye):length()
    else
        missCount = missCount + 1
    end

    acceptDepth(idx, d)
end

local function addSmallMotionSlack(moveDist, yawDelta, pitchDelta)
    for i = 1, COUNT do
        local d = provenDepth[i] or MAX_DIST

        if d < MAX_DIST then
            local moveAdd = moveDist * MOVE_SLACK_SCALE
            local refDepth = math.max(ANGLE_SLACK_DEPTH_FLOOR, d)
            local angleAdd =
                (math.abs(yawDelta) + math.abs(pitchDelta))
                * refDepth
                * ANGLE_SLACK_SCALE

            slack[i] = math.min(
                MAX_TILE_SLACK,
                (slack[i] or 0.0) + moveAdd + angleAdd
            )
        end
    end

    if math.abs(yawDelta) + math.abs(pitchDelta) >= FAST_TURN_TRIGGER then
        burstRemaining = math.max(burstRemaining, BURST_SECONDS)
    end
end

local function chooseTiles(budget)
    local candidates = {}

    for i = 1, COUNT do
        age[i] = (age[i] or 0) + 1

        candidates[#candidates + 1] = {
            idx = i,
            pending = pendingClose[i] ~= nil and 1 or 0,
            priority = priority[i] or 0,
            slack = slack[i] or 0.0,
            age = age[i] or 0,
        }
    end

    table.sort(candidates, function(a, b)
        if a.pending ~= b.pending then return a.pending > b.pending end
        if a.priority ~= b.priority then return a.priority > b.priority end
        if math.abs(a.slack - b.slack) > 0.01 then return a.slack > b.slack end
        return a.age > b.age
    end)

    local selected = {}
    for i = 1, math.min(budget, #candidates) do
        local idx = candidates[i].idx
        selected[#selected + 1] = idx
        if (priority[idx] or 0) > 0 then
            priority[idx] = priority[idx] - 1
        end
    end

    return selected
end

local function printStatus(out, budget)
    local minD = MAX_DIST
    local maxD = 0.0
    local sum = 0.0
    local under1k = 0
    local under2k = 0

    local slackSum = 0.0
    local slackMax = 0.0
    local pendingN = 0

    for i = 1, COUNT do
        local d = out[i] or MAX_DIST
        minD = math.min(minD, d)
        maxD = math.max(maxD, d)
        sum = sum + d
        if d < 1000.0 then under1k = under1k + 1 end
        if d < 2000.0 then under2k = under2k + 1 end

        local s = slack[i] or 0.0
        slackSum = slackSum + s
        slackMax = math.max(slackMax, s)

        if pendingClose[i] ~= nil then pendingN = pendingN + 1 end
    end

    local stats = camera.getInteriorVisibilityStats()
    local tested = stats.tested or 0.0
    local culled = stats.culled or 0.0
    local dt = tested - lastStatsTested
    local dc = culled - lastStatsCulled
    lastStatsTested = tested
    lastStatsCulled = culled

    local reject = 0.0
    if dt > 0.0 then reject = dc * 100.0 / dt end

    print(string.format(
        '[TSP_VISGRID_V6] min=%.0f mean=%.0f max=%.0f lt1k=%d lt2k=%d reject=%.1f%% slack_mean=%.0f slack_max=%.0f pending=%d budget=%d burst=%.2f cast_attempts=%d cast_ok=%d hits=%d misses=%d dir_fail=%d len_fail=%d norm_fail=%d cast_fail=%d openings=%d',
        minD, sum / COUNT, maxD,
        under1k, under2k, reject,
        slackSum / COUNT, slackMax,
        pendingN, budget, burstRemaining,
        castAttempts, castOK, hitCount, missCount,
        dirFail, lenFail, normFail, castFail, openingEvents
    ))

    if firstDirError ~= nil then
        print('[TSP_VISGRID_V6] first_dir_error=' .. firstDirError)
    end
    if firstLenError ~= nil then
        print('[TSP_VISGRID_V6] first_len_error=' .. firstLenError)
    end
    if firstNormError ~= nil then
        print('[TSP_VISGRID_V6] first_norm_error=' .. firstNormError)
    end
    if firstCastError ~= nil then
        print('[TSP_VISGRID_V6] first_cast_error=' .. firstCastError)
    end

    resetDiagnostics()
end

local function enterInterior(cell, eye, yaw, pitch)
    inInterior = true
    lastCell = cell
    lastEye = eye
    lastYaw = yaw
    lastPitch = pitch
    interiorElapsed = 0.0
    burstRemaining = BURST_SECONDS
    resetTables()
    camera.resetInteriorVisibilityStats()
    lastStatsTested = 0.0
    lastStatsCulled = 0.0

    -- Grid activation establishes a C++ far floor of 3000.
    camera.setInteriorVisibilityGrid(COLS, ROWS, provenDepth, PADDING)

    -- One explicit request only. C++ clamps later competing lower requests.
    camera.setViewDistance(MAX_DIST)

    print('[TSP_VISGRID_V6] enter interior -> lifecycle-fixed persistent grid active')
end

local function onInit()
    -- Pure Lua only. No nearby access required here.
    resetRuntimeState()
    print('[TSP_VISGRID_V6] onInit -> runtime tables initialized')
end

local function onLoad(_savedData, _initData)
    -- Existing saves come here instead of onInit.
    -- Pure Lua initialization is safe while the player object is inactive.
    resetRuntimeState()
    print('[TSP_VISGRID_V6] onLoad -> runtime tables initialized')
end

local function onFrame(dt)
    if dt == nil or dt <= 0.0 then return end

    statusElapsed = statusElapsed + dt
    if inInterior then interiorElapsed = interiorElapsed + dt end

    if burstRemaining > 0.0 then
        burstRemaining = math.max(0.0, burstRemaining - dt)
    end

    local cell = self.cell
    if cell == nil then return end

    if cell.isExterior then
        if inInterior then
            inInterior = false
            lastCell = nil
            lastEye = nil
            lastYaw = nil
            lastPitch = nil
            resetTables()
            camera.clearInteriorVisibilityGrid()
            print('[TSP_VISGRID_V6] exit interior -> grid off')
        end
        return
    end

    local eye = camera.getPosition()
    if eye == nil then return end

    local yaw = camera.getYaw() or 0.0
    local pitch = camera.getPitch() or 0.0

    if not inInterior then
        enterInterior(cell, eye, yaw, pitch)
    elseif cell ~= lastCell then
        enterInterior(cell, eye, yaw, pitch)
        print('[TSP_VISGRID_V6] reset reason=cell-change')
    else
        local moveDist = lastEye ~= nil and (eye - lastEye):length() or 0.0

        -- Ignore camera-settling jumps immediately after cell/load activation.
        if moveDist > TELEPORT_RESET_DIST and interiorElapsed > LOAD_GRACE_SECONDS then
            enterInterior(cell, eye, yaw, pitch)
            print('[TSP_VISGRID_V6] reset reason=teleport')
        else
            local yawDelta = lastYaw ~= nil and angleDiffSigned(yaw, lastYaw) or 0.0
            local pitchDelta = lastPitch ~= nil and angleDiffSigned(pitch, lastPitch) or 0.0

            addSmallMotionSlack(moveDist, yawDelta, pitchDelta)

            lastEye = eye
            lastYaw = yaw
            lastPitch = pitch
        end
    end

    local budget = burstRemaining > 0.0 and RAYS_BURST or RAYS_STEADY
    local selected = chooseTiles(budget)

    for i = 1, #selected do
        sampleTile(selected[i], eye)
    end

    local out = publishGrid()

    -- IMPORTANT: no per-frame setViewDistance call in V6.

    if statusElapsed >= PRINT_PERIOD then
        statusElapsed = statusElapsed - PRINT_PERIOD
        printStatus(out, budget)
    end
end

return {
    engineHandlers = {
        onInit = onInit,
        onLoad = onLoad,
        onFrame = onFrame,
    },
}
EOF_LUA

grep -Fq 'TSP_INTERIOR_VISGRID_LUA_V6' "$PKG/visgrid.lua"
grep -Fq 'onLoad = onLoad' "$PKG/visgrid.lua"
grep -Fq 'local MAX_DIST = 3000.0' "$PKG/visgrid.lua"
grep -Fq 'return dir / len' "$PKG/visgrid.lua"
grep -Fq 'cast_attempts=' "$PKG/visgrid.lua"

if grep -Fq 'screenPos[' "$PKG/visgrid.lua"; then
    echo "ERROR: cached screenPos survived V6."
    exit 1
fi

if grep -Fq 'dir:normalize()' "$PKG/visgrid.lua"; then
    echo "ERROR: Vector3:normalize survived V6 isolation path."
    exit 1
fi

echo "PASS: V6 candidate generated."

echo
echo "===== 4/7 INSTALL V6 LUA ONLY ====="

scp -q "$PKG/visgrid.lua" "$DEV:/tmp/visgrid-v6.lua"

ssh "$DEV" "
set -e
test -s /tmp/visgrid-v6.lua
grep -Fq 'TSP_INTERIOR_VISGRID_LUA_V6' /tmp/visgrid-v6.lua
grep -Fq 'onLoad = onLoad' /tmp/visgrid-v6.lua
cp /tmp/visgrid-v6.lua '$LUA.new'
mv -f '$LUA.new' '$LUA'
rm -f /tmp/visgrid-v6.lua
sync
"

echo "PASS: V6 installed."

echo
echo "===== 5/7 VERIFY ENGINE UNCHANGED + LUA SHA ====="

REMOTE_BIN_SHA="$(ssh "$DEV" "sha256sum '$BIN' | awk '{print \$1}'")"
REMOTE_LUA_SHA="$(ssh "$DEV" "sha256sum '$LUA' | awk '{print \$1}'")"
LOCAL_LUA_SHA="$(sha256sum "$PKG/visgrid.lua" | awk '{print $1}')"

[ "$LOCAL_LUA_SHA" = "$REMOTE_LUA_SHA" ] || {
    echo "ERROR: V6 Lua SHA mismatch."
    exit 1
}

ssh "$DEV" "
set -e
grep -a -q 'TSP_INTERIOR_VISGRID_051_V1' '$BIN'
grep -Fq 'TSP_INTERIOR_VISGRID_LUA_V6' '$LUA'
"

echo "OpenMW binary (unchanged V1 engine): $REMOTE_BIN_SHA"
echo "V6 Lua:                            $REMOTE_LUA_SHA"

echo
echo "===== 6/7 CREATE TRACE + ROLLBACK HELPERS ====="

cat > "$PKG/collect-visgrid-v6-trace.sh" <<'EOF_TRACE'
#!/usr/bin/env bash
set -Eeuo pipefail

DEV="${TSP_DEV:-root@192.168.1.25}"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="${1:-$HOME/Downloads/openmw51-visgrid-v6-trace-$STAMP.txt}"

{
    echo "=================================================================="
    echo "OPENMW INTERIOR VISGRID V6 TRACE"
    echo "=================================================================="
    ssh "$DEV" 'hostname; date'

    echo
    echo "===== VISGRID V6 / RAY PIPELINE ====="
    ssh "$DEV" '
        grep -hE \
          "TSP_VISGRID_V6|TSP_INTERIOR_VISGRID_051_V1|TSP_DEPTH_PROJECTION|Lua.*error|ERROR.*Lua" \
          /mnt/SDCARD/data/ports/openmw51/config-0.51/openmw.log \
          /mnt/SDCARD/tsp_prog.txt \
          2>/dev/null | tail -2600 || true
    '

    echo
    echo "===== RENDER / PERFORMANCE ====="
    ssh "$DEV" '
        for f in \
          /mnt/SDCARD/tsp_diag.txt \
          /mnt/SDCARD/tsp_ring.txt \
          /mnt/SDCARD/tsp_state.txt \
          /mnt/SDCARD/data/ports/openmw51/openmw51_perf_latest.txt
        do
            if [ -f "$f" ]; then
                echo "--- $f ---"
                tail -800 "$f"
            fi
        done
    '

    echo
    echo "===== INSTALLED STATE ====="
    ssh "$DEV" '
        sha256sum \
          /mnt/SDCARD/data/ports/openmw51/bin/openmw-0.51 \
          /mnt/SDCARD/data/ports/openmw51/mods/TSPInteriorVisGrid/TSPInteriorVisGrid.omwscripts \
          /mnt/SDCARD/data/ports/openmw51/mods/TSPInteriorVisGrid/scripts/TSPInteriorVisGrid/visgrid.lua \
          2>/dev/null || true
    '
} 2>&1 | tee "$OUT"

echo
echo "Trace saved:"
echo "  $OUT"
EOF_TRACE
chmod +x "$PKG/collect-visgrid-v6-trace.sh"

cat > "$PKG/rollback-visgrid-v6.sh" <<EOF_ROLLBACK
#!/usr/bin/env bash
set -Eeuo pipefail
DEV="\${TSP_DEV:-root@192.168.1.25}"
LUA="$LUA"
BACKUP="$REMOTE_BACKUP/visgrid.lua.before-v6"

if ssh "\$DEV" 'pidof openmw-0.51 >/dev/null 2>&1 || pidof openmw >/dev/null 2>&1'; then
    echo "ERROR: exit OpenMW before rollback."
    exit 1
fi

ssh "\$DEV" "
set -e
test -s '\$BACKUP'
cp -p '\$BACKUP' '\$LUA'
sync
sha256sum '\$LUA'
"
echo "Restored exact pre-V6 sensor."
EOF_ROLLBACK
chmod +x "$PKG/rollback-visgrid-v6.sh"

cat > "$PKG/README-V6.txt" <<EOF_README
VISGRID V6 — LIFECYCLE/RAY FIX
==============================

Critical diagnosis:
V5 recorded zero castRay attempts and hundreds of failures.

Cause addressed:
Runtime tables were built only from onInit. OpenMW calls onInit only when a
script is created. Existing saved scripts use onLoad. V5 therefore could load
with no cached screenPos vectors.

V6:
- adds onLoad initialization
- initializes pure-Lua state at chunk load too
- removes cached viewport Vector2 values entirely
- computes util.vector2(u,v) fresh per ray
- uses dir:length() + dir/len
- logs dir_fail / len_fail / norm_fail / cast_fail separately
- logs cast_attempts / cast_ok / hits / misses
- keeps 3000 interior maximum
- keeps V5 persistent per-tile history/scheduler
- disables the vertical-row experiment for this isolation test
- removes per-frame camera.setViewDistance
- retains one setViewDistance(3000) on interior entry only

Device backup:
$REMOTE_BACKUP
EOF_README

echo
echo "===== 7/7 FINAL ====="
echo "=================================================================="
echo "VISGRID V6 INSTALLED"
echo "=================================================================="
echo
echo "FIRST CHECK IS NOT FPS:"
echo "  At the bad wall, after ~1 second the V6 log MUST show:"
echo "    cast_attempts > 0"
echo "    cast_ok > 0"
echo "    hits > 0"
echo
echo "Then check whether:"
echo "    mean depth contracts from 3000 toward wall distance"
echo "    reject rises above 0%"
echo "    FPS returns toward the original V1 improvement"
echo
echo "Only after those are true should movement behavior be judged."
echo
echo "While OpenMW is still running:"
echo "  $PKG/collect-visgrid-v6-trace.sh"
echo
echo "Rollback:"
echo "  $PKG/rollback-visgrid-v6.sh"
echo "=================================================================="
