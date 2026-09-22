#!/usr/bin/env bash
set -Eeuo pipefail

DEV="${TSP_DEV:-root@192.168.1.25}"
STAMP="$(date +%Y%m%d-%H%M%S)"

ROOT="/mnt/SDCARD/data/ports/openmw51"
BIN="$ROOT/bin/openmw-0.51"
MOD="$ROOT/mods/TSPInteriorVisGrid"
OMW="$MOD/TSPInteriorVisGrid.omwscripts"
LUA="$MOD/scripts/TSPInteriorVisGrid/visgrid.lua"

PKG="$HOME/Downloads/openmw51-interior-visgrid-v4-v1-temporal-$STAMP"
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
        echo "VISGRID V4 V1-TEMPORAL STOPPED SAFELY"
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
echo "OPENMW 0.51 TSP — INTERIOR VISGRID V4"
echo "V1 SENSOR RESTORE + TEMPORAL MOTION UNCERTAINTY"
echo "=================================================================="
echo
echo "This deliberately ABANDONS the V2/V3 sensor designs."
echo
echo "Restored from the successful V1 model:"
echo "  - direct camera-space 8x5 screen tiles"
echo "  - 5 World+Door rays per frame"
echo "  - each ray updates ONLY its own tile"
echo "  - two similar close hits before contraction"
echo "  - farther/open result expands immediately"
echo "  - exact V1-style 3x3 MAX dilation"
echo
echo "Only V1's destructive movement reset changes:"
echo "  - NO fillMax() on normal walking/turning"
echo "  - each tile keeps its last proven depth"
echo "  - camera movement adds a temporary per-tile uncertainty margin"
echo "  - that uncertainty is cleared when that tile is freshly sampled"
echo "  - close depths are temporally averaged after V1's two-hit confirmation"
echo
echo "Full MAX reset is reserved for:"
echo "  - entering a new interior"
echo "  - changing cells"
echo "  - a true large teleport"
echo
echo "The working V1 C++ culler/binary is NOT modified."
echo
echo "Package:"
echo "  $PKG"
echo

echo "===== 1/7 VERIFY CURRENT VISGRID INSTALL ====="

ssh -o BatchMode=yes -o ConnectTimeout=8 "$DEV" "
set -e

echo \"Host: \$(hostname)\"
echo \"Date: \$(date)\"

test -s '$BIN'
test -f '$OMW'
test -f '$LUA'

grep -a -q 'TSP_INTERIOR_VISGRID_051_V1' '$BIN'
grep -Fq 'PLAYER: scripts/TSPInteriorVisGrid/visgrid.lua' '$OMW'

if grep -Fq 'TSP_INTERIOR_VISGRID_LUA_V4' '$LUA'; then
    echo 'CURRENT_SENSOR=V4'
elif grep -Fq 'TSP_INTERIOR_VISGRID_LUA_V3' '$LUA'; then
    echo 'CURRENT_SENSOR=V3'
elif grep -Fq 'TSP_INTERIOR_VISGRID_LUA_V2' '$LUA'; then
    echo 'CURRENT_SENSOR=V2'
elif grep -Fq 'TSP_INTERIOR_VISGRID_LUA_V1' '$LUA'; then
    echo 'CURRENT_SENSOR=V1'
else
    echo 'ERROR: installed VISGRID Lua is not recognized.'
    exit 1
fi

echo 'PASS: V1 C++ visibility-grid bridge is installed.'
"

if ssh "$DEV" 'pidof openmw-0.51 >/dev/null 2>&1 || pidof openmw >/dev/null 2>&1'; then
    echo
    echo "ERROR: OpenMW is currently running."
    echo "Exit Morrowind normally, then rerun this SAME V4 script."
    exit 20
fi

echo "PASS: OpenMW is closed."

CURRENT_STATE="$(
    ssh "$DEV" "
        if grep -Fq 'TSP_INTERIOR_VISGRID_LUA_V4' '$LUA'; then
            echo V4
        elif grep -Fq 'TSP_INTERIOR_VISGRID_LUA_V3' '$LUA'; then
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
echo "===== 2/7 BACK UP CURRENT SENSOR ====="

REMOTE_BACKUP="$ROOT/backups/interior-visgrid-v4-v1-temporal-$STAMP"

ssh "$DEV" "
set -e

mkdir -p '$REMOTE_BACKUP'

cp -p '$LUA' '$REMOTE_BACKUP/visgrid.lua.before-v4'
cp -p '$OMW' '$REMOTE_BACKUP/TSPInteriorVisGrid.omwscripts'

sha256sum \
    '$BIN' \
    '$LUA' \
    '$OMW' \
    > '$REMOTE_BACKUP/SHA256SUMS.before.txt'

sync

echo 'Device backup: $REMOTE_BACKUP'
cat '$REMOTE_BACKUP/SHA256SUMS.before.txt'
"

scp -q "$DEV:$LUA" "$PKG/visgrid.lua.before-v4"
scp -q "$DEV:$OMW" "$PKG/TSPInteriorVisGrid.omwscripts.before-v4"

sha256sum \
    "$PKG/visgrid.lua.before-v4" \
    "$PKG/TSPInteriorVisGrid.omwscripts.before-v4" \
    > "$PKG/SHA256SUMS.before.txt"

echo "PASS: exact current sensor preserved."

echo
echo "===== 3/7 GENERATE V4 LUA ====="

cat > "$PKG/visgrid.lua" <<'EOF_LUA'
-- TSP_INTERIOR_VISGRID_LUA_V4
--
-- V1 SENSOR RESTORE + TEMPORAL MOTION UNCERTAINTY
--
-- This revision intentionally returns to the exact successful V1 model:
--   * one depth per 8x5 CAMERA-SPACE screen tile
--   * five World+Door rays per frame
--   * each ray updates only its own tile
--   * farther/open is immediate
--   * closer requires two similar observations
--   * 3x3 max dilation before publishing
--
-- The ONLY major behavior removed from V1 is its full-grid camera-change reset.
--
-- Instead every tile has:
--   provenDepth[idx]  = the last temporally accepted V1-style depth
--   uncertainty[idx]  = extra safe distance accumulated since THAT tile was
--                       last freshly sampled
--
-- The renderer receives:
--   effectiveDepth = min(MAX_DIST, provenDepth + uncertainty)
--
-- Therefore:
--   standing still -> uncertainty ~= 0 -> V1 behavior returns
--   walking/turning -> old culling is not discarded, only loosened
--   freshly sampled tile -> uncertainty is cleared for that tile
--
-- Close accepted depths are then gently averaged over time, rather than
-- replacing the stable room solution with every individual close hit.
--
-- No world-space sample splatting. No 40-ray brute force. No ordinary
-- camera-motion fillMax().

local camera = require('openmw.camera')
local nearby = require('openmw.nearby')
local self = require('openmw.self')
local util = require('openmw.util')

local COLS = 8
local ROWS = 5
local COUNT = COLS * ROWS

local MAX_DIST = 5500.0
local PADDING = 350.0
local RAYS_PER_FRAME = 5

-- V1 used 180. Slightly wider here because the camera is now allowed to move
-- between the two confirmation samples.
local CLOSE_CONFIRM_TOLERANCE = 240.0

-- After a tile has already established a proven close value, newly confirmed
-- close hits are blended into it instead of hard-replacing it.
local TEMPORAL_ALPHA = 0.45

-- Motion does NOT directly erase a tile. It increases that tile's safe far
-- allowance until the tile receives a fresh ray.
--
-- Translation is naturally measured in world units.
local MOVE_UNCERTAINTY_SCALE = 1.75

-- Radians -> world units of temporary far allowance.
-- ~6 degrees adds ~470 units before that tile is refreshed.
local ANGLE_UNCERTAINTY_PER_RAD = 4500.0

-- True teleport/cell transitions still need a clean model.
local TELEPORT_RESET_DIST = 900.0

-- Use accumulated dt instead of wall-clock print timing so status cannot vanish
-- because of timer semantics.
local PRINT_PERIOD = 1.0

local RAY_MASK = nearby.COLLISION_TYPE.World + (nearby.COLLISION_TYPE.Door or 0)

local provenDepth = {}
local uncertainty = {}

local pendingClose = {}
local pendingCount = {}

local sampleAge = {}
local order = {}

local inInterior = false
local lastCell = nil
local lastEye = nil
local lastYaw = nil
local lastPitch = nil

local frameCounter = 0
local statusElapsed = 0.0

local lastStatsTested = 0.0
local lastStatsCulled = 0.0

local rayFailuresSincePrint = 0
local raysSincePrint = 0

local function angleDiffSigned(a, b)
    local d = a - b

    while d > math.pi do
        d = d - 2.0 * math.pi
    end

    while d < -math.pi do
        d = d + 2.0 * math.pi
    end

    return d
end

local function buildOrder()
    order = {}

    local cx = (COLS + 1) * 0.5
    local cy = (ROWS + 1) * 0.5

    for row = 1, ROWS do
        for col = 1, COLS do
            local idx = (row - 1) * COLS + col
            local dx = col - cx
            local dy = row - cy

            order[#order + 1] = {
                idx = idx,
                centerScore = dx * dx + dy * dy,
            }
        end
    end
end

local function fillMax()
    for i = 1, COUNT do
        provenDepth[i] = MAX_DIST
        uncertainty[i] = 0.0
        pendingClose[i] = nil
        pendingCount[i] = 0
        sampleAge[i] = 1000000
    end
end

local function effectiveDepth(idx)
    local d = (provenDepth[idx] or MAX_DIST) + (uncertainty[idx] or 0.0)

    if d > MAX_DIST then
        d = MAX_DIST
    elseif d < 1.0 then
        d = 1.0
    end

    return d
end

local function publishGrid()
    -- This is intentionally the SAME conservative V1 3x3 max dilation.
    local out = {}

    for row = 1, ROWS do
        for col = 1, COLS do
            local best = 0.0

            for rr = math.max(1, row - 1), math.min(ROWS, row + 1) do
                for cc = math.max(1, col - 1), math.min(COLS, col + 1) do
                    local idx = (rr - 1) * COLS + cc
                    local d = effectiveDepth(idx)

                    if d > best then
                        best = d
                    end
                end
            end

            out[(row - 1) * COLS + col] = best
        end
    end

    camera.setInteriorVisibilityGrid(
        COLS,
        ROWS,
        out,
        PADDING
    )

    return out
end

local function clearForNewSpace(reason)
    fillMax()

    camera.setInteriorVisibilityGrid(
        COLS,
        ROWS,
        provenDepth,
        PADDING
    )

    print(string.format(
        '[TSP_VISGRID_V4] full-reset reason=%s max=%.0f',
        reason or 'unknown',
        MAX_DIST
    ))
end

local function addMotionUncertainty(moveDist, yawDelta, pitchDelta)
    local add = moveDist * MOVE_UNCERTAINTY_SCALE
        + (math.abs(yawDelta) + math.abs(pitchDelta))
            * ANGLE_UNCERTAINTY_PER_RAD

    if add <= 0.0 then
        return
    end

    for i = 1, COUNT do
        -- Open tiles are already fully permissive.
        if provenDepth[i] < MAX_DIST then
            uncertainty[i] = math.min(
                MAX_DIST - provenDepth[i],
                (uncertainty[i] or 0.0) + add
            )
        end
    end
end

local function acceptDepth(idx, measured)
    measured = math.max(
        1.0,
        math.min(MAX_DIST, measured)
    )

    local currentEffective = effectiveDepth(idx)
    local currentProven = provenDepth[idx] or MAX_DIST

    -- V1 behavior: farther/open is safe and immediate.
    if measured >= currentEffective then
        provenDepth[idx] = measured
        uncertainty[idx] = 0.0
        pendingClose[idx] = nil
        pendingCount[idx] = 0
        sampleAge[idx] = 0
        return
    end

    -- A fresh ray confirms the CURRENT direction, so this tile no longer needs
    -- its accumulated motion uncertainty. However, do not contract provenDepth
    -- until the close reading passes V1-style confirmation.
    uncertainty[idx] = 0.0
    sampleAge[idx] = 0

    local pending = pendingClose[idx]

    if pending ~= nil
        and math.abs(pending - measured) <= CLOSE_CONFIRM_TOLERANCE
    then
        local confirmed = 0.5 * (pending + measured)

        if currentProven >= MAX_DIST - 1.0 then
            -- Critical V1 restore:
            -- after two close hits an initially-open tile contracts immediately.
            provenDepth[idx] = confirmed
        elseif confirmed >= currentProven then
            -- More distant remains immediate/permissive.
            provenDepth[idx] = confirmed
        else
            -- Persistent room history:
            -- smooth subsequent close contractions over time.
            provenDepth[idx] =
                currentProven * (1.0 - TEMPORAL_ALPHA)
                + confirmed * TEMPORAL_ALPHA
        end

        pendingClose[idx] = nil
        pendingCount[idx] = 0
    else
        pendingClose[idx] = measured
        pendingCount[idx] = 1
    end
end

local function sampleTile(idx, eye)
    local row = math.floor((idx - 1) / COLS) + 1
    local col = ((idx - 1) % COLS) + 1

    local u = (col - 0.5) / COLS
    local v = (row - 0.5) / ROWS

    local okDir, dir = pcall(
        camera.viewportToWorldVector,
        util.vector2(u, v)
    )

    if not okDir or dir == nil then
        rayFailuresSincePrint = rayFailuresSincePrint + 1
        acceptDepth(idx, MAX_DIST)
        return
    end

    -- Preserve the exact V1 normalization method.
    local okNorm, norm = pcall(
        function()
            return dir:normalize()
        end
    )

    if not okNorm or norm == nil then
        rayFailuresSincePrint = rayFailuresSincePrint + 1
        acceptDepth(idx, MAX_DIST)
        return
    end

    local dest = eye + norm * MAX_DIST

    local okRay, res = pcall(
        nearby.castRay,
        eye,
        dest,
        { collisionType = RAY_MASK }
    )

    raysSincePrint = raysSincePrint + 1

    if not okRay or res == nil then
        rayFailuresSincePrint = rayFailuresSincePrint + 1
        acceptDepth(idx, MAX_DIST)
        return
    end

    local d = MAX_DIST

    if res.hit and res.hitPos ~= nil then
        d = (res.hitPos - eye):length()
    end

    acceptDepth(idx, d)
end

local function chooseTiles()
    local candidates = {}

    for i = 1, COUNT do
        sampleAge[i] = (sampleAge[i] or 0) + 1

        candidates[#candidates + 1] = {
            idx = i,
            pending = pendingClose[i] ~= nil and 1 or 0,
            uncertainty = uncertainty[i] or 0.0,
            age = sampleAge[i] or 0,
            centerScore = order[i] and order[i].centerScore or 999.0,
        }
    end

    table.sort(
        candidates,
        function(a, b)
            -- Confirm a possible new wall immediately on the next frame.
            if a.pending ~= b.pending then
                return a.pending > b.pending
            end

            -- Then fix tiles made least trustworthy by player motion.
            if math.abs(a.uncertainty - b.uncertainty) > 0.01 then
                return a.uncertainty > b.uncertainty
            end

            -- Then ordinary oldest-sample-first refresh.
            if a.age ~= b.age then
                return a.age > b.age
            end

            -- Deterministic center preference only as a final tie break.
            return a.centerScore < b.centerScore
        end
    )

    local selected = {}

    for i = 1, math.min(RAYS_PER_FRAME, #candidates) do
        selected[i] = candidates[i].idx
    end

    return selected
end

local function printStatus(out)
    local minD = MAX_DIST
    local maxD = 0.0
    local sum = 0.0

    local under1000 = 0
    local under2000 = 0
    local under4000 = 0

    local uncertaintySum = 0.0
    local uncertaintyMax = 0.0
    local pendingN = 0

    for i = 1, COUNT do
        local d = out[i] or MAX_DIST

        minD = math.min(minD, d)
        maxD = math.max(maxD, d)
        sum = sum + d

        if d < 1000.0 then under1000 = under1000 + 1 end
        if d < 2000.0 then under2000 = under2000 + 1 end
        if d < 4000.0 then under4000 = under4000 + 1 end

        local u = uncertainty[i] or 0.0
        uncertaintySum = uncertaintySum + u
        uncertaintyMax = math.max(uncertaintyMax, u)

        if pendingClose[i] ~= nil then
            pendingN = pendingN + 1
        end
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

    print(string.format(
        '[TSP_VISGRID_V4] grid=%dx%d min=%.0f mean=%.0f max=%.0f lt1k=%d lt2k=%d lt4k=%d reject=%.1f%% tested_delta=%.0f culled_delta=%.0f uncertainty_mean=%.0f uncertainty_max=%.0f pending=%d rays=%d ray_failures=%d',
        COLS,
        ROWS,
        minD,
        sum / COUNT,
        maxD,
        under1000,
        under2000,
        under4000,
        reject,
        dt,
        dc,
        uncertaintySum / COUNT,
        uncertaintyMax,
        pendingN,
        raysSincePrint,
        rayFailuresSincePrint
    ))

    raysSincePrint = 0
    rayFailuresSincePrint = 0
end

local function onInit()
    buildOrder()
    fillMax()

    if camera.clearInteriorVisibilityGrid ~= nil then
        camera.clearInteriorVisibilityGrid()
    end

    print(string.format(
        '[TSP_VISGRID_V4] loaded mode=v1-temporal grid=%dx%d rays_per_frame=%d max=%.0f padding=%.0f alpha=%.2f',
        COLS,
        ROWS,
        RAYS_PER_FRAME,
        MAX_DIST,
        PADDING,
        TEMPORAL_ALPHA
    ))
end

local function onFrame(dt)
    if dt == nil or dt <= 0.0 then
        return
    end

    frameCounter = frameCounter + 1
    statusElapsed = statusElapsed + dt

    local cell = self.cell

    if cell == nil then
        return
    end

    if cell.isExterior then
        if inInterior then
            inInterior = false
            lastCell = nil
            lastEye = nil
            lastYaw = nil
            lastPitch = nil

            fillMax()
            camera.clearInteriorVisibilityGrid()

            print('[TSP_VISGRID_V4] exit interior -> grid off')
        end

        return
    end

    local eye = camera.getPosition()

    if eye == nil then
        return
    end

    local yaw = camera.getYaw() or 0.0
    local pitch = camera.getPitch() or 0.0

    if not inInterior then
        inInterior = true
        lastCell = cell
        lastEye = eye
        lastYaw = yaw
        lastPitch = pitch

        fillMax()
        camera.resetInteriorVisibilityStats()

        lastStatsTested = 0.0
        lastStatsCulled = 0.0

        camera.setInteriorVisibilityGrid(
            COLS,
            ROWS,
            provenDepth,
            PADDING
        )

        print('[TSP_VISGRID_V4] enter interior -> V1 temporal grid active')
    elseif cell ~= lastCell then
        lastCell = cell
        lastEye = eye
        lastYaw = yaw
        lastPitch = pitch

        clearForNewSpace('cell-change')
    else
        local moveDist = 0.0
        local yawDelta = 0.0
        local pitchDelta = 0.0

        if lastEye ~= nil then
            moveDist = (eye - lastEye):length()
        end

        if moveDist > TELEPORT_RESET_DIST then
            lastEye = eye
            lastYaw = yaw
            lastPitch = pitch

            clearForNewSpace('teleport')
        else
            if lastYaw ~= nil then
                yawDelta = angleDiffSigned(yaw, lastYaw)
            end

            if lastPitch ~= nil then
                pitchDelta = angleDiffSigned(pitch, lastPitch)
            end

            addMotionUncertainty(
                moveDist,
                yawDelta,
                pitchDelta
            )

            lastEye = eye
            lastYaw = yaw
            lastPitch = pitch
        end
    end

    -- Same ray budget as successful V1, but prioritize pending/stale tiles.
    local selected = chooseTiles()

    for i = 1, #selected do
        sampleTile(selected[i], eye)
    end

    local out = publishGrid()

    -- Keep projection long; VISGRID is the submission limiter.
    local live = camera.getViewDistance() or MAX_DIST

    if live < MAX_DIST - 1.0 then
        camera.setViewDistance(MAX_DIST)
    end

    if statusElapsed >= PRINT_PERIOD then
        statusElapsed = statusElapsed - PRINT_PERIOD
        printStatus(out)
    end
end

return {
    engineHandlers = {
        onInit = onInit,
        onFrame = onFrame,
    },
}
EOF_LUA

grep -Fq 'TSP_INTERIOR_VISGRID_LUA_V4' "$PKG/visgrid.lua"
grep -Fq 'mode=v1-temporal' "$PKG/visgrid.lua"
grep -Fq 'local RAYS_PER_FRAME = 5' "$PKG/visgrid.lua"
grep -Fq 'dir:normalize()' "$PKG/visgrid.lua"
grep -Fq 'uncertainty[idx]' "$PKG/visgrid.lua"
grep -Fq 'TEMPORAL_ALPHA = 0.45' "$PKG/visgrid.lua"

# V2/V3 mechanisms must not survive.
if grep -Fq 'worldToViewportVector' "$PKG/visgrid.lua"; then
    echo "ERROR: V3 world-point reprojection survived V4 generation."
    exit 1
fi

if grep -Fq 'RAYS_PER_FRAME = 40' "$PKG/visgrid.lua"; then
    echo "ERROR: V2 40-ray mode survived V4 generation."
    exit 1
fi

echo "PASS: V4 candidate is V1-derived and contains no V2/V3 sensor mechanism."

echo
echo "===== 4/7 INSTALL V4 SENSOR ONLY ====="

scp -q "$PKG/visgrid.lua" "$DEV:/tmp/visgrid-v4.lua"

ssh "$DEV" "
set -e

test -s /tmp/visgrid-v4.lua
grep -Fq 'TSP_INTERIOR_VISGRID_LUA_V4' /tmp/visgrid-v4.lua
grep -Fq 'mode=v1-temporal' /tmp/visgrid-v4.lua

cp /tmp/visgrid-v4.lua '$LUA.new'
mv -f '$LUA.new' '$LUA'

rm -f /tmp/visgrid-v4.lua

sync
"

echo "PASS: V4 sensor installed."

echo
echo "===== 5/7 VERIFY ENGINE UNCHANGED + V4 SHA ====="

REMOTE_BIN_SHA="$(ssh "$DEV" "sha256sum '$BIN' | awk '{print \$1}'")"
REMOTE_LUA_SHA="$(ssh "$DEV" "sha256sum '$LUA' | awk '{print \$1}'")"
LOCAL_LUA_SHA="$(sha256sum "$PKG/visgrid.lua" | awk '{print $1}')"

ssh "$DEV" "
set -e

grep -a -q 'TSP_INTERIOR_VISGRID_051_V1' '$BIN'
grep -Fq 'TSP_INTERIOR_VISGRID_LUA_V4' '$LUA'
grep -Fq 'PLAYER: scripts/TSPInteriorVisGrid/visgrid.lua' '$OMW'

if grep -Fq 'worldToViewportVector' '$LUA'; then
    echo 'ERROR: V3 reprojection unexpectedly exists in installed V4.'
    exit 1
fi
"

[ "$LOCAL_LUA_SHA" = "$REMOTE_LUA_SHA" ] || {
    echo "ERROR: installed V4 Lua SHA mismatch."
    exit 1
}

echo "OpenMW binary (working V1 C++ engine, unchanged):"
echo "  $REMOTE_BIN_SHA"
echo
echo "V4 Lua:"
echo "  $REMOTE_LUA_SHA"
echo
echo "PASS: V1 engine preserved; V4 sensor installed."

echo
echo "===== 6/7 CREATE TRACE + ROLLBACK TOOLS ====="

cat > "$PKG/collect-visgrid-v4-trace.sh" <<'EOF_TRACE'
#!/usr/bin/env bash
set -Eeuo pipefail

DEV="${TSP_DEV:-root@192.168.1.25}"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="${1:-$HOME/Downloads/openmw51-visgrid-v4-trace-$STAMP.txt}"

{
    echo "=================================================================="
    echo "OPENMW INTERIOR VISGRID V4 V1-TEMPORAL TRACE"
    echo "=================================================================="

    ssh "$DEV" 'hostname; date'

    echo
    echo "===== VISGRID V4 ====="

    ssh "$DEV" '
        grep -hE \
          "TSP_VISGRID_V4|TSP_INTERIOR_VISGRID_051_V1|TSP_DEPTH_PROJECTION|Lua.*error|ERROR.*Lua|scripts/tspinteriorvisgrid" \
          /mnt/SDCARD/data/ports/openmw51/config-0.51/openmw.log \
          /mnt/SDCARD/tsp_prog.txt \
          2>/dev/null |
          tail -2200 || true
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
                tail -700 "$f"
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

        echo
        echo "--- V4 marker / forbidden old mechanisms ---"

        grep -nF "TSP_INTERIOR_VISGRID_LUA_V4" \
          /mnt/SDCARD/data/ports/openmw51/mods/TSPInteriorVisGrid/scripts/TSPInteriorVisGrid/visgrid.lua \
          || true

        if grep -q "worldToViewportVector" \
          /mnt/SDCARD/data/ports/openmw51/mods/TSPInteriorVisGrid/scripts/TSPInteriorVisGrid/visgrid.lua
        then
            echo "FAIL: V3 reprojection text present"
        else
            echo "PASS: no V3 reprojection"
        fi
    '

} 2>&1 | tee "$OUT"

echo
echo "Trace saved:"
echo "  $OUT"
EOF_TRACE

chmod +x "$PKG/collect-visgrid-v4-trace.sh"

cat > "$PKG/rollback-visgrid-v4.sh" <<EOF_ROLLBACK
#!/usr/bin/env bash
set -Eeuo pipefail

DEV="\${TSP_DEV:-root@192.168.1.25}"
LUA="$LUA"
BACKUP="$REMOTE_BACKUP/visgrid.lua.before-v4"

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

echo "Restored exact pre-V4 sensor from:"
echo "  $REMOTE_BACKUP"
EOF_ROLLBACK

chmod +x "$PKG/rollback-visgrid-v4.sh"

cat > "$PKG/README-V4.txt" <<EOF_README
TSP INTERIOR VISGRID V4 — V1 TEMPORAL
=====================================

Purpose
-------
Restore the exact successful V1 sensor topology while removing ONLY the
destructive full-grid reset during normal movement.

Restored V1 behavior
--------------------
8x5 camera-space tiles
5 World+Door rays/frame
ray updates only its own tile
two similar close hits before contraction
far/open expansion immediate
3x3 max dilation
same V1 C++ culler
same 350 C++ padding
actors excluded

Removed
-------
V2 40 rays/frame
V3 worldToViewportVector
V3 world-space hit splatting
V1 fillMax() on ordinary camera movement

New
---
Each tile retains provenDepth.
Each tile has motion uncertainty.
Movement/rotation increases uncertainty.
A fresh ray resets uncertainty for THAT tile.
Initial close contraction still occurs after two close hits like V1.
Later confirmed close measurements are temporally averaged.

Current sensor before V4:
$CURRENT_STATE

Device backup:
$REMOTE_BACKUP
EOF_README

echo
echo "===== 7/7 FINAL ====="

echo "=================================================================="
echo "VISGRID V4 V1-TEMPORAL INSTALLED"
echo "=================================================================="
echo
echo "No OpenMW rebuild occurred."
echo "The successful V1 C++ culler is unchanged."
echo
echo "MOST IMPORTANT TEST ORDER:"
echo
echo "  A. First reproduce the EXACT stationary V1 test:"
echo "     same Caldera bad wall"
echo "     stop moving completely"
echo "     give it ~2 seconds"
echo
echo "     If the V1-style large speedup DOES NOT return,"
echo "     stop there and collect the trace."
echo
echo "  B. Only if A works:"
echo "     walk slowly while looking at/around the same wall"
echo "     turn"
echo "     approach a doorway"
echo "     use the staircase"
echo
echo "We are explicitly testing two separate claims:"
echo "  1. V4 restored the V1 stationary mechanism."
echo "  2. temporal uncertainty preserves useful culling during motion."
echo
echo "WHILE OPENMW IS STILL RUNNING:"
echo "  $PKG/collect-visgrid-v4-trace.sh"
echo
echo "Rollback to exact pre-V4 sensor (OpenMW closed):"
echo "  $PKG/rollback-visgrid-v4.sh"
echo
echo "Package:"
echo "  $PKG"
echo "=================================================================="
