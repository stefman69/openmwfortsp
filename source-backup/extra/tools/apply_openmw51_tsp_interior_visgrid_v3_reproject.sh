#!/usr/bin/env bash
set -Eeuo pipefail

DEV="${TSP_DEV:-root@192.168.1.25}"
STAMP="$(date +%Y%m%d-%H%M%S)"

ROOT="/mnt/SDCARD/data/ports/openmw51"
BIN="$ROOT/bin/openmw-0.51"
MOD="$ROOT/mods/TSPInteriorVisGrid"
OMW="$MOD/TSPInteriorVisGrid.omwscripts"
LUA="$MOD/scripts/TSPInteriorVisGrid/visgrid.lua"

PKG="$HOME/Downloads/openmw51-interior-visgrid-v3-reproject-$STAMP"
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
        echo
        echo "=================================================================="
        echo "VISGRID V3 REPROJECT STOPPED SAFELY"
        echo "=================================================================="
        echo "Date: $(date)"
        echo "Exit code: $rc"
        echo "Script line: $line"
        echo "Failing command:"
        echo "  $cmd"
        echo

        if [ -f "$LOG" ]; then
            echo "----- install.log : LAST 220 LINES -----"
            tail -220 "$LOG" || true
        fi

        echo
        echo "Nothing after the failed step was intentionally run."
        echo "Everything produced so far is preserved at:"
        echo "  $PKG"
        echo
        echo "Error report:"
        echo "  $report"
        echo "=================================================================="
    } 2>&1 | tee "$report"

    echo
    echo "SCRIPT STOPPED. TERMINAL REMAINS OPEN."

    if [ -t 0 ]; then
        echo
        read -r -p "Press Enter to return to the shell... " _ || true
    fi

    exit "$rc"
}

trap 'fail_report "$?" "$LINENO" "$BASH_COMMAND"' ERR

exec > >(tee "$LOG") 2>&1

echo "=================================================================="
echo "OPENMW 0.51 TSP — INTERIOR VISGRID V3 WORLD-REPROJECT SENSOR"
echo "=================================================================="
echo
echo "The working V1 C++ culler is NOT rebuilt or changed."
echo
echo "V3 fixes the sensor update architecture:"
echo
echo "  V1: 5 rays/frame, but camera motion erased the whole grid."
echo "  V2: 40 rays/frame, no erase, but synchronous ray cost was enormous."
echo
echo "  V3: 5 rays/frame + keep WORLD-SPACE hit points."
echo "      Existing wall/door samples are reprojected into the CURRENT view"
echo "      every frame using camera.worldToViewportVector()."
echo "      Fresh rays only repair newly exposed/stale tiles."
echo
echo "Safety:"
echo "  - close/new occluder requires two fresh confirmations"
echo "  - far/open result expands immediately"
echo "  - uncovered current-view tile becomes MAX_DIST (never guessed closed)"
echo "  - existing 3x3 Lua dilation retained"
echo "  - existing C++ one-tile dilation + 350-unit padding retained"
echo "  - large teleport / cell change safely clears samples"
echo
echo "No OpenMW source or binary is modified by this installer."
echo
echo "Package:"
echo "  $PKG"
echo

echo "===== 1/7 CONNECT + VERIFY CURRENT VISGRID ENGINE ====="

ssh -o BatchMode=yes -o ConnectTimeout=8 "$DEV" "
set -e
echo \"Host: \$(hostname)\"
echo \"Date: \$(date)\"

test -s '$BIN'
test -f '$OMW'
test -f '$LUA'

grep -a -q 'TSP_INTERIOR_VISGRID_051_V1' '$BIN'
grep -Fq 'PLAYER: scripts/TSPInteriorVisGrid/visgrid.lua' '$OMW'

if grep -Fq 'TSP_INTERIOR_VISGRID_LUA_V3' '$LUA'; then
    echo 'STATE=V3'
elif grep -Fq 'TSP_INTERIOR_VISGRID_LUA_V2' '$LUA'; then
    echo 'STATE=V2'
elif grep -Fq 'TSP_INTERIOR_VISGRID_LUA_V1' '$LUA'; then
    echo 'STATE=V1'
else
    echo 'ERROR: installed VISGRID Lua is not recognized as V1/V2/V3.'
    exit 1
fi

echo 'PASS: V1 C++ bridge/culler is installed.'
"

if ssh "$DEV" 'pidof openmw-0.51 >/dev/null 2>&1 || pidof openmw >/dev/null 2>&1'; then
    echo
    echo "ERROR: OpenMW is currently running."
    echo "Exit Morrowind normally and rerun this SAME script."
    exit 20
fi

echo "PASS: OpenMW is closed."

CURRENT_STATE="$(
    ssh "$DEV" "
        if grep -Fq 'TSP_INTERIOR_VISGRID_LUA_V3' '$LUA'; then
            echo V3
        elif grep -Fq 'TSP_INTERIOR_VISGRID_LUA_V2' '$LUA'; then
            echo V2
        else
            echo V1
        fi
    "
)"

echo "Current sensor: $CURRENT_STATE"

echo
echo "===== 2/7 BACK UP CURRENT SENSOR BEFORE EDIT ====="

REMOTE_BACKUP="$ROOT/backups/interior-visgrid-v3-reproject-$STAMP"

ssh "$DEV" "
set -e
mkdir -p '$REMOTE_BACKUP'
cp -p '$LUA' '$REMOTE_BACKUP/visgrid.lua.before-v3'
cp -p '$OMW' '$REMOTE_BACKUP/TSPInteriorVisGrid.omwscripts'
sha256sum '$BIN' '$LUA' '$OMW' > '$REMOTE_BACKUP/SHA256SUMS.before.txt'
sync
echo 'Device backup: $REMOTE_BACKUP'
cat '$REMOTE_BACKUP/SHA256SUMS.before.txt'
"

scp -q "$DEV:$LUA" "$PKG/visgrid.lua.before-v3"
scp -q "$DEV:$OMW" "$PKG/TSPInteriorVisGrid.omwscripts.before-v3"

sha256sum \
    "$PKG/visgrid.lua.before-v3" \
    "$PKG/TSPInteriorVisGrid.omwscripts.before-v3" \
    > "$PKG/SHA256SUMS.before.txt"

echo "PASS: exact current Lua/config rollback copies preserved."

echo
echo "===== 3/7 GENERATE V3 WORLD-REPROJECT SENSOR ====="

cat > "$PKG/visgrid.lua" <<'EOF_LUA'
-- TSP_INTERIOR_VISGRID_LUA_V3
--
-- WORLD-REPROJECT SENSOR
--
-- Renderer/culling bridge:
--     TSP_INTERIOR_VISGRID_051_V1 (unchanged)
--
-- Why V3:
--   V1 proved the tiled culler can give a very large stationary FPS win, but
--   erased the whole grid whenever the camera moved.
--
--   V2 removed that erase by firing all 40 synchronous physics rays every
--   frame. On the TSP that put very large work back on the Lua/main thread.
--
--   V3 keeps accepted ray endpoints in WORLD SPACE. Every frame those already
--   known walls/openings are cheaply reprojected into the CURRENT viewport.
--   Only five fresh World+Door rays are cast per frame to repair/newly expose
--   the room model.
--
-- Safety policy:
--   * New farther/open result is accepted immediately.
--   * New closer result needs two similar fresh samples.
--   * A current-view tile with no trustworthy reprojected sample is MAX_DIST.
--   * 3x3 max dilation remains before publishing.
--   * V1 C++ still expands object coverage by one tile and adds 350 units.
--   * Actors remain excluded by the V1 renderer callback.
--   * Cell change / huge single-frame teleport clears the cache.
--
-- Current TSP build uses 1280x720. worldToViewportVector() returns physical
-- pixel coordinates based on Settings::video resolution in OpenMW 0.51.
-- This V3 prototype therefore uses the current build's native dimensions.
-- A future community version can expose/obtain the dimensions generically.

local camera = require('openmw.camera')
local core = require('openmw.core')
local nearby = require('openmw.nearby')
local self = require('openmw.self')
local util = require('openmw.util')

local COLS = 8
local ROWS = 5
local COUNT = COLS * ROWS

local SCREEN_W = 1280.0
local SCREEN_H = 720.0

local MAX_DIST = 5500.0
local PADDING = 350.0

-- Same steady ray budget that was already viable in V1.
local RAYS_PER_FRAME = 5

-- Two close measurements must agree this closely before replacing a more
-- permissive existing sample.
local CLOSE_CONFIRM_TOLERANCE = 180.0

local PRINT_PERIOD = 2.0
local TELEPORT_RESET_DIST = 900.0

local RAY_MASK = nearby.COLLISION_TYPE.World + (nearby.COLLISION_TYPE.Door or 0)

-- One accepted world-space endpoint per logical scan slot.
-- A no-hit/open ray stores its MAX_DIST endpoint too, so an opening remains
-- reprojectable as the camera moves.
local samplePoint = {}

local pendingPoint = {}
local pendingDepth = {}

local screenPos = {}
local neighbors = {}
local centerOrder = {}

local projectedDepth = {}
local projectedCoverage = {}
local published = {}

local inInterior = false
local lastCell = nil
local lastEye = nil

local roundPos = 1

local lastPrint = 0.0
local lastStatsTested = 0.0
local lastStatsCulled = 0.0

local sensorFrames = 0
local sensorTimeSum = 0.0
local sensorTimeMax = 0.0
local sensorRayFailures = 0
local sensorProjectedSamples = 0
local sensorUncoveredTiles = 0
local sensorFreshRays = 0

local function clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

local function dot(a, b)
    return a.x * b.x + a.y * b.y + a.z * b.z
end

local function precompute()
    centerOrder = {}

    local cx = (COLS + 1) * 0.5
    local cy = (ROWS + 1) * 0.5

    for row = 1, ROWS do
        for col = 1, COLS do
            local idx = (row - 1) * COLS + col

            screenPos[idx] = util.vector2(
                (col - 0.5) / COLS,
                (row - 0.5) / ROWS
            )

            local list = {}
            for rr = math.max(1, row - 1), math.min(ROWS, row + 1) do
                for cc = math.max(1, col - 1), math.min(COLS, col + 1) do
                    list[#list + 1] = (rr - 1) * COLS + cc
                end
            end
            neighbors[idx] = list

            local dx = col - cx
            local dy = row - cy
            centerOrder[#centerOrder + 1] = {
                idx = idx,
                score = dx * dx + dy * dy,
            }
        end
    end

    table.sort(centerOrder, function(a, b)
        return a.score < b.score
    end)
end

local function clearSamples()
    for i = 1, COUNT do
        samplePoint[i] = nil
        pendingPoint[i] = nil
        pendingDepth[i] = nil
        projectedDepth[i] = MAX_DIST
        projectedCoverage[i] = 0
        published[i] = MAX_DIST
    end
    roundPos = 1
end

local function deposit(idx, distance)
    if idx < 1 or idx > COUNT then
        return
    end

    local old = projectedDepth[idx]
    if projectedCoverage[idx] == 0 or distance > old then
        projectedDepth[idx] = distance
    end
    projectedCoverage[idx] = projectedCoverage[idx] + 1
end

local function splatProjected(u, v, distance)
    -- Project to the containing tile plus the nearest horizontal/vertical
    -- neighbors. This gives old world samples a small footprint as the camera
    -- moves, while the MAX rule remains conservative if an opening overlaps.
    local gx = u * COLS
    local gy = v * ROWS

    local col = math.floor(gx) + 1
    local row = math.floor(gy) + 1

    if col < 1 or col > COLS or row < 1 or row > ROWS then
        return
    end

    local fx = gx - math.floor(gx)
    local fy = gy - math.floor(gy)

    local col2 = col + (fx >= 0.5 and 1 or -1)
    local row2 = row + (fy >= 0.5 and 1 or -1)

    local function at(c, r)
        if c >= 1 and c <= COLS and r >= 1 and r <= ROWS then
            deposit((r - 1) * COLS + c, distance)
        end
    end

    at(col, row)
    at(col2, row)
    at(col, row2)
    at(col2, row2)
end

local function projectAcceptedSamples(eye)
    for i = 1, COUNT do
        projectedDepth[i] = MAX_DIST
        projectedCoverage[i] = 0
    end

    local okForward, forward = pcall(
        camera.viewportToWorldVector,
        util.vector2(0.5, 0.5)
    )

    if not okForward or forward == nil then
        return 0
    end

    local flen = forward:length()
    if flen == nil or flen <= 0.0001 then
        return 0
    end
    forward = forward / flen

    local projectedCount = 0

    for i = 1, COUNT do
        local point = samplePoint[i]
        if point ~= nil then
            local delta = point - eye
            local dlen = delta:length()

            if dlen ~= nil and dlen > 1.0 and dot(delta, forward) > 0.0 then
                local okVp, vp = pcall(camera.worldToViewportVector, point)

                if okVp and vp ~= nil then
                    local u = vp.x / SCREEN_W
                    local v = vp.y / SCREEN_H
                    local distance = vp.z

                    if distance == nil or distance ~= distance or distance <= 0.0 then
                        distance = dlen
                    end

                    if u >= 0.0 and u < 1.0 and v >= 0.0 and v < 1.0 then
                        splatProjected(
                            u,
                            v,
                            clamp(distance, 1.0, MAX_DIST)
                        )
                        projectedCount = projectedCount + 1
                    end
                end
            end
        end
    end

    return projectedCount
end

local function countUncovered()
    local n = 0
    for i = 1, COUNT do
        if projectedCoverage[i] == 0 then
            n = n + 1
        end
    end
    return n
end

local function measureTile(idx, eye)
    local okDir, dir = pcall(camera.viewportToWorldVector, screenPos[idx])
    if not okDir or dir == nil then
        sensorRayFailures = sensorRayFailures + 1
        return MAX_DIST, nil
    end

    local len = dir:length()
    if len == nil or len <= 0.0001 then
        sensorRayFailures = sensorRayFailures + 1
        return MAX_DIST, nil
    end

    local dest = eye + dir / len * MAX_DIST

    local okRay, res = pcall(
        nearby.castRay,
        eye,
        dest,
        { collisionType = RAY_MASK }
    )

    if not okRay or res == nil then
        sensorRayFailures = sensorRayFailures + 1
        -- Failure is permissive. Store no new world sample.
        return MAX_DIST, nil
    end

    if res.hit and res.hitPos ~= nil then
        return clamp((res.hitPos - eye):length(), 1.0, MAX_DIST), res.hitPos
    end

    -- No hit is a valid OPEN sample. Keep the world-space far endpoint.
    return MAX_DIST, dest
end

local function acceptMeasurement(idx, measured, point)
    if point == nil then
        -- An actual ray failure is never used to hide anything.
        pendingPoint[idx] = nil
        pendingDepth[idx] = nil
        return
    end

    local current = projectedDepth[idx]
    if projectedCoverage[idx] == 0 then
        current = MAX_DIST
    end

    -- Farther/more-open information is always safe and takes effect now.
    if measured >= current - 1.0 then
        samplePoint[idx] = point
        pendingPoint[idx] = nil
        pendingDepth[idx] = nil
        return
    end

    -- A new closer wall can hide geometry. Confirm it with the same tile on
    -- a later fresh-ray update before replacing the accepted sample.
    local pending = pendingDepth[idx]

    if pending ~= nil
        and math.abs(pending - measured) <= CLOSE_CONFIRM_TOLERANCE
    then
        samplePoint[idx] = point
        pendingPoint[idx] = nil
        pendingDepth[idx] = nil
    else
        pendingPoint[idx] = point
        pendingDepth[idx] = measured
    end
end

local function chooseFreshTiles()
    local selected = {}
    local used = {}

    local function add(idx)
        if idx ~= nil
            and idx >= 1
            and idx <= COUNT
            and not used[idx]
            and #selected < RAYS_PER_FRAME
        then
            used[idx] = true
            selected[#selected + 1] = idx
        end
    end

    -- 1. Confirm pending close samples as quickly as possible.
    for _, entry in ipairs(centerOrder) do
        local idx = entry.idx
        if pendingDepth[idx] ~= nil then
            add(idx)
        end
    end

    -- 2. Newly exposed tiles have no reprojected sample. Repair them next.
    for _, entry in ipairs(centerOrder) do
        local idx = entry.idx
        if projectedCoverage[idx] == 0 then
            add(idx)
        end
    end

    -- 3. Spend remaining budget refreshing the whole room in a rolling cycle.
    local guard = 0
    while #selected < RAYS_PER_FRAME and guard < COUNT * 2 do
        if roundPos > #centerOrder then
            roundPos = 1
        end

        add(centerOrder[roundPos].idx)
        roundPos = roundPos + 1
        guard = guard + 1
    end

    return selected
end

local function refreshFreshRays(eye)
    local selected = chooseFreshTiles()

    for i = 1, #selected do
        local idx = selected[i]
        local measured, point = measureTile(idx, eye)
        acceptMeasurement(idx, measured, point)
    end

    sensorFreshRays = sensorFreshRays + #selected
end

local function publishGrid()
    -- Uncovered tiles remain MAX_DIST. Covered tiles use the farthest
    -- reprojected sample, then the V1 3x3 max dilation is applied.
    for idx = 1, COUNT do
        if projectedCoverage[idx] == 0 then
            projectedDepth[idx] = MAX_DIST
        end
    end

    for idx = 1, COUNT do
        local best = 0.0
        local list = neighbors[idx]

        for n = 1, #list do
            local d = projectedDepth[list[n]]
            if d > best then
                best = d
            end
        end

        published[idx] = best
    end

    camera.setInteriorVisibilityGrid(
        COLS,
        ROWS,
        published,
        PADDING
    )
end

local function printStatus()
    local now = core.getRealTime()
    if now == nil or now - lastPrint < PRINT_PERIOD then
        return
    end
    lastPrint = now

    local minD = MAX_DIST
    local maxD = 0.0
    local sum = 0.0

    for i = 1, COUNT do
        local d = published[i] or MAX_DIST
        minD = math.min(minD, d)
        maxD = math.max(maxD, d)
        sum = sum + d
    end

    local stats = camera.getInteriorVisibilityStats()
    local tested = stats.tested or 0.0
    local culled = stats.culled or 0.0

    local dt = tested - lastStatsTested
    local dc = culled - lastStatsCulled

    lastStatsTested = tested
    lastStatsCulled = culled

    local reject = 0.0
    if dt > 0.0 then
        reject = dc * 100.0 / dt
    end

    local sensorAvgMs = 0.0
    if sensorFrames > 0 then
        sensorAvgMs = sensorTimeSum * 1000.0 / sensorFrames
    end

    print(string.format(
        '[TSP_VISGRID_V3] grid=%dx%d min=%.0f mean=%.0f max=%.0f reject=%.1f%% tested_delta=%.0f culled_delta=%.0f projected_avg=%.1f uncovered_avg=%.1f fresh_rays_avg=%.1f sensor_avg_ms=%.3f sensor_max_ms=%.3f ray_failures=%d',
        COLS,
        ROWS,
        minD,
        sum / COUNT,
        maxD,
        reject,
        dt,
        dc,
        sensorFrames > 0 and sensorProjectedSamples / sensorFrames or 0.0,
        sensorFrames > 0 and sensorUncoveredTiles / sensorFrames or 0.0,
        sensorFrames > 0 and sensorFreshRays / sensorFrames or 0.0,
        sensorAvgMs,
        sensorTimeMax * 1000.0,
        sensorRayFailures
    ))

    sensorFrames = 0
    sensorTimeSum = 0.0
    sensorTimeMax = 0.0
    sensorRayFailures = 0
    sensorProjectedSamples = 0
    sensorUncoveredTiles = 0
    sensorFreshRays = 0
end

local function safeReset(reason)
    clearSamples()

    camera.setInteriorVisibilityGrid(
        COLS,
        ROWS,
        published,
        PADDING
    )

    print(string.format(
        '[TSP_VISGRID_V3] reset reason=%s',
        reason or 'unknown'
    ))
end

local function onInit()
    precompute()
    clearSamples()

    if camera.clearInteriorVisibilityGrid ~= nil then
        camera.clearInteriorVisibilityGrid()
    end

    print(string.format(
        '[TSP_VISGRID_V3] world-reproject sensor loaded grid=%dx%d rays_per_frame=%d max=%.0f padding=%.0f',
        COLS,
        ROWS,
        RAYS_PER_FRAME,
        MAX_DIST,
        PADDING
    ))
end

local function onFrame(dt)
    if dt == nil or dt <= 0.0 then
        return
    end

    local cell = self.cell
    if cell == nil then
        return
    end

    if cell.isExterior then
        if inInterior then
            inInterior = false
            lastCell = nil
            lastEye = nil
            clearSamples()
            camera.clearInteriorVisibilityGrid()
            print('[TSP_VISGRID_V3] exit interior -> grid off')
        end
        return
    end

    local eye = camera.getPosition()
    if eye == nil then
        return
    end

    if not inInterior then
        inInterior = true
        lastCell = cell
        lastEye = eye

        clearSamples()
        camera.resetInteriorVisibilityStats()

        lastStatsTested = 0.0
        lastStatsCulled = 0.0

        camera.setInteriorVisibilityGrid(
            COLS,
            ROWS,
            published,
            PADDING
        )

        print('[TSP_VISGRID_V3] enter interior -> world-reproject grid active')
    elseif cell ~= lastCell then
        lastCell = cell
        lastEye = eye
        safeReset('cell-change')
    elseif lastEye ~= nil and (eye - lastEye):length() > TELEPORT_RESET_DIST then
        lastEye = eye
        safeReset('teleport')
    end

    local t0 = core.getRealTime()

    -- FIRST: carry accepted world-space room samples into the CURRENT camera.
    local projected = projectAcceptedSamples(eye)
    local uncovered = countUncovered()

    -- SECOND: use only five expensive physics rays to repair the model.
    refreshFreshRays(eye)

    -- THIRD: reproject again so newly accepted far/confirmed-close samples can
    -- affect this very frame.
    projected = projectAcceptedSamples(eye)
    uncovered = countUncovered()

    publishGrid()

    -- VISGRID is the submission limiter; the projection itself remains long.
    local live = camera.getViewDistance() or MAX_DIST
    if live < MAX_DIST - 1.0 then
        camera.setViewDistance(MAX_DIST)
    end

    local t1 = core.getRealTime()
    if t0 ~= nil and t1 ~= nil and t1 >= t0 then
        local elapsed = t1 - t0
        sensorFrames = sensorFrames + 1
        sensorTimeSum = sensorTimeSum + elapsed
        if elapsed > sensorTimeMax then
            sensorTimeMax = elapsed
        end
    end

    sensorProjectedSamples = sensorProjectedSamples + projected
    sensorUncoveredTiles = sensorUncoveredTiles + uncovered

    lastEye = eye

    printStatus()
end

return {
    engineHandlers = {
        onInit = onInit,
        onFrame = onFrame,
    },
}
EOF_LUA

grep -Fq 'TSP_INTERIOR_VISGRID_LUA_V3' "$PKG/visgrid.lua"
grep -Fq 'camera.worldToViewportVector' "$PKG/visgrid.lua"
grep -Fq 'local RAYS_PER_FRAME = 5' "$PKG/visgrid.lua"
grep -Fq 'projectAcceptedSamples(eye)' "$PKG/visgrid.lua"
grep -Fq 'fresh_rays_avg=' "$PKG/visgrid.lua"

echo "PASS: V3 Lua candidate generated."

echo
echo "===== 4/7 INSTALL V3 SENSOR ONLY ====="

scp -q "$PKG/visgrid.lua" "$DEV:/tmp/visgrid-v3.lua"

ssh "$DEV" "
set -e

test -s /tmp/visgrid-v3.lua
grep -Fq 'TSP_INTERIOR_VISGRID_LUA_V3' /tmp/visgrid-v3.lua
grep -Fq 'camera.worldToViewportVector' /tmp/visgrid-v3.lua

cp /tmp/visgrid-v3.lua '$LUA.new'
mv -f '$LUA.new' '$LUA'
rm -f /tmp/visgrid-v3.lua

sync
"

echo "PASS: V3 sensor installed."

echo
echo "===== 5/7 VERIFY ENGINE UNCHANGED + LUA SHA ====="

REMOTE_BIN_SHA="$(ssh "$DEV" "sha256sum '$BIN' | awk '{print \$1}'")"
REMOTE_LUA_SHA="$(ssh "$DEV" "sha256sum '$LUA' | awk '{print \$1}'")"
LOCAL_LUA_SHA="$(sha256sum "$PKG/visgrid.lua" | awk '{print $1}')"

ssh "$DEV" "
set -e

grep -a -q 'TSP_INTERIOR_VISGRID_051_V1' '$BIN'
grep -Fq 'TSP_INTERIOR_VISGRID_LUA_V3' '$LUA'
grep -Fq 'PLAYER: scripts/TSPInteriorVisGrid/visgrid.lua' '$OMW'
"

[ "$LOCAL_LUA_SHA" = "$REMOTE_LUA_SHA" ] || {
    echo "ERROR: V3 Lua SHA mismatch after install."
    exit 1
}

echo "OpenMW binary (unchanged V1 engine):"
echo "  $REMOTE_BIN_SHA"
echo
echo "V3 sensor Lua:"
echo "  $REMOTE_LUA_SHA"

echo "PASS: V1 engine retained; V3 sensor installed."

echo
echo "===== 6/7 CREATE TRACE + ROLLBACK HELPERS ====="

cat > "$PKG/collect-visgrid-v3-trace.sh" <<'EOF_TRACE'
#!/usr/bin/env bash
set -Eeuo pipefail

DEV="${TSP_DEV:-root@192.168.1.25}"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="${1:-$HOME/Downloads/openmw51-visgrid-v3-trace-$STAMP.txt}"

{
    echo "=================================================================="
    echo "OPENMW INTERIOR VISGRID V3 WORLD-REPROJECT TRACE"
    echo "=================================================================="

    ssh "$DEV" 'hostname; date'

    echo
    echo "===== VISGRID V3 ====="
    ssh "$DEV" '
        grep -hE \
          "TSP_VISGRID_V3|TSP_INTERIOR_VISGRID_051_V1|TSP_DEPTH_PROJECTION" \
          /mnt/SDCARD/data/ports/openmw51/config-0.51/openmw.log \
          /mnt/SDCARD/tsp_prog.txt \
          2>/dev/null |
          tail -1800 || true
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
                tail -650 "$f"
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

        echo

        grep -nF "TSPInteriorVisGrid" \
          /mnt/SDCARD/data/ports/openmw51/config-0.51/openmw.cfg \
          /mnt/SDCARD/data/ports/openmw51/config-0.51/openmw/openmw.cfg \
          2>/dev/null || true
    '

} 2>&1 | tee "$OUT"

echo
echo "Trace saved:"
echo "  $OUT"
EOF_TRACE

chmod +x "$PKG/collect-visgrid-v3-trace.sh"

cat > "$PKG/rollback-visgrid-v3.sh" <<EOF_ROLLBACK
#!/usr/bin/env bash
set -Eeuo pipefail

DEV="\${TSP_DEV:-root@192.168.1.25}"
LUA="$LUA"
BACKUP="$REMOTE_BACKUP/visgrid.lua.before-v3"

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

echo "Restored exact pre-V3 VISGRID sensor from:"
echo "  $REMOTE_BACKUP"
EOF_ROLLBACK

chmod +x "$PKG/rollback-visgrid-v3.sh"

cat > "$PKG/README-V3.txt" <<EOF_README
TSP INTERIOR VISGRID V3 WORLD-REPROJECT SENSOR
==============================================

C++:
  unchanged working TSP_INTERIOR_VISGRID_051_V1 culler

V3 sensor:
  8x5 visibility field
  only 5 expensive World+Door physics rays per frame
  accepted ray endpoints are stored in WORLD SPACE
  every frame they are reprojected into the CURRENT camera using:
      camera.worldToViewportVector()

This avoids:
  V1 full-grid camera motion invalidation
  V2 40 synchronous rays every frame

Current TSP-specific screen dimensions:
  1280x720

Safety:
  close contraction requires two similar fresh measurements
  far/open expansion is immediate
  uncovered tile = MAX_DIST
  3x3 Lua max dilation
  V1 C++ one-tile object overlap dilation
  V1 C++ padding = 350
  actor culling remains disabled

Device backup:
  $REMOTE_BACKUP

Most important trace fields:
  reject
  projected_avg
  uncovered_avg
  fresh_rays_avg
  sensor_avg_ms
  sensor_max_ms
  ray_failures
EOF_README

echo
echo "===== 7/7 FINAL ====="

echo "=================================================================="
echo "VISGRID V3 WORLD-REPROJECT INSTALLED"
echo "=================================================================="
echo
echo "No source rebuild occurred."
echo "The V1 C++ culling mechanism that produced the large stationary win"
echo "is unchanged."
echo
echo "TEST THIS ONE WHILE MOVING:"
echo
echo "  1. Same Caldera slowdown."
echo "  2. Walk continuously toward/away from the wall."
echo "  3. Turn slowly and quickly."
echo "  4. Walk through a doorway."
echo "  5. Use a staircase/opening."
echo
echo "The target is NOT just stationary 27 FPS."
echo "The target is to keep a large portion of that gain while moving."
echo
echo "WHILE OPENMW IS STILL RUNNING, collect:"
echo "  $PKG/collect-visgrid-v3-trace.sh"
echo
echo "Rollback to exact pre-V3 sensor (OpenMW closed):"
echo "  $PKG/rollback-visgrid-v3.sh"
echo
echo "Package:"
echo "  $PKG"
echo "=================================================================="
