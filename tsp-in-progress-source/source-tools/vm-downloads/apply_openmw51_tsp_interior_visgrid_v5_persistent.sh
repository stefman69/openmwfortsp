#!/usr/bin/env bash
set -Eeuo pipefail

DEV="${TSP_DEV:-root@192.168.1.25}"
STAMP="$(date +%Y%m%d-%H%M%S)"

ROOT="/mnt/SDCARD/data/ports/openmw51"
BIN="$ROOT/bin/openmw-0.51"
MOD="$ROOT/mods/TSPInteriorVisGrid"
OMW="$MOD/TSPInteriorVisGrid.omwscripts"
LUA="$MOD/scripts/TSPInteriorVisGrid/visgrid.lua"

PKG="$HOME/Downloads/openmw51-interior-visgrid-v5-persistent-$STAMP"
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
        echo "VISGRID V5 PERSISTENT STOPPED SAFELY"
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
        echo "Everything produced so far is preserved at:"
        echo "  $PKG"
        echo "=================================================================="
    } 2>&1 | tee "$report"
    if [ -t 0 ]; then
        echo
        read -r -p "Press Enter to return to the shell... " _ || true
    fi
    exit "$rc"
}
trap 'fail_report "$?" "$LINENO" "$BASH_COMMAND"' ERR

exec > >(tee "$LOG") 2>&1

echo "=================================================================="
echo "OPENMW 0.51 TSP — INTERIOR VISGRID V5 PERSISTENT"
echo "=================================================================="
echo
echo "V5 keeps the successful V1 tile model and removes V4's huge global"
echo "movement uncertainty."
echo
echo "Changes:"
echo "  - interior max/far floor: 3000"
echo "  - 8x5 V1 camera-space tiles retained"
echo "  - 5 rays/frame steady"
echo "  - 10 rays/frame short burst after entry/turn/opening"
echo "  - small per-tile motion slack instead of global 5500 inflation"
echo "  - temporal averaging of confirmed close hits"
echo "  - opening events prioritize a local fan of neighboring tiles"
echo "  - vertical screen rows capped more tightly while looking level"
echo "  - pitching up OR down gradually lifts vertical caps toward 3000"
echo
echo "No C++ rebuild. Working V1 culler remains installed."
echo "Package:"
echo "  $PKG"
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
echo 'PASS: V1 engine bridge present.'
"

if ssh "$DEV" 'pidof openmw-0.51 >/dev/null 2>&1 || pidof openmw >/dev/null 2>&1'; then
    echo
    echo "ERROR: OpenMW is running."
    echo "Exit Morrowind normally and rerun this SAME V5 script."
    exit 20
fi
echo "PASS: OpenMW is closed."

echo
echo "===== 2/7 BACK UP CURRENT SENSOR ====="

REMOTE_BACKUP="$ROOT/backups/interior-visgrid-v5-persistent-$STAMP"

ssh "$DEV" "
set -e
mkdir -p '$REMOTE_BACKUP'
cp -p '$LUA' '$REMOTE_BACKUP/visgrid.lua.before-v5'
cp -p '$OMW' '$REMOTE_BACKUP/TSPInteriorVisGrid.omwscripts'
sha256sum '$BIN' '$LUA' '$OMW' > '$REMOTE_BACKUP/SHA256SUMS.before.txt'
sync
cat '$REMOTE_BACKUP/SHA256SUMS.before.txt'
"

scp -q "$DEV:$LUA" "$PKG/visgrid.lua.before-v5"
scp -q "$DEV:$OMW" "$PKG/TSPInteriorVisGrid.omwscripts.before-v5"
sha256sum "$PKG/visgrid.lua.before-v5" "$PKG/TSPInteriorVisGrid.omwscripts.before-v5" \
    > "$PKG/SHA256SUMS.before.txt"

echo "PASS: rollback copies preserved."
echo "Device backup: $REMOTE_BACKUP"

echo
echo "===== 3/7 GENERATE V5 SENSOR ====="

cat > "$PKG/visgrid.lua" <<'EOF_LUA'
-- TSP_INTERIOR_VISGRID_LUA_V5
--
-- PERSISTENT V1 TILE MODEL
--
-- V1 proved the culling mechanism. V4 proved the remaining movement problem:
-- its global motion uncertainty could inflate a settled ~200-unit room grid
-- back toward MAX_DIST. V5 removes that architecture.
--
-- V5 rules:
--   * Keep one proven depth per camera-space 8x5 tile (V1 model).
--   * Keep only SMALL per-tile motion slack.
--   * Refresh the least trustworthy tiles first.
--   * 5 rays/frame normally, 10 briefly after a turn/opening/entry.
--   * Close hits require confirmation and are temporally averaged.
--   * Far/open hits expand immediately.
--   * A newly opened tile queues a local neighbor fan for fast repair.
--   * Interior maximum is 3000.
--   * Vertical screen rows are shorter at level view and gradually open toward
--     3000 as pitch magnitude increases.
--
-- "Vertical" here means camera/screen vertical, not literal world-Z. It is
-- intentionally implemented in Lua first so it can be tuned without rebuilding.

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
local BURST_SECONDS = 0.70

local CLOSE_CONFIRM_TOLERANCE = 240.0
local TEMPORAL_ALPHA = 0.55

-- Small translation/rotation safety only. Unlike V4, rotation does not add
-- thousands of world units to every tile.
local MOVE_SLACK_SCALE = 1.20
local ANGLE_SLACK_SCALE = 0.60
local ANGLE_SLACK_DEPTH_FLOOR = 500.0
local MAX_TILE_SLACK = 650.0

local FAST_TURN_TRIGGER = math.rad(2.0)
local TELEPORT_RESET_DIST = 900.0

local OPENING_JUMP = 700.0
local OPENING_PRIORITY = 8

local PRINT_PERIOD = 1.0

-- Level-view vertical caps by screen row.
-- Row 3 (center) always has the full 3000.
local LEVEL_ROW_CAP = {
    1900.0,
    2500.0,
    3000.0,
    2500.0,
    1900.0,
}

-- At |pitch| >= 35 degrees all rows may use the full 3000.
local FULL_VERTICAL_PITCH = math.rad(35.0)

local RAY_MASK = nearby.COLLISION_TYPE.World + (nearby.COLLISION_TYPE.Door or 0)

local provenDepth = {}
local slack = {}
local pendingClose = {}
local age = {}
local priority = {}
local screenPos = {}
local neighbors3 = {}

local inInterior = false
local lastCell = nil
local lastEye = nil
local lastYaw = nil
local lastPitch = nil

local burstRemaining = 0.0
local statusElapsed = 0.0

local lastStatsTested = 0.0
local lastStatsCulled = 0.0

local raysSincePrint = 0
local rayFailuresSincePrint = 0
local openingEventsSincePrint = 0
local burstFramesSincePrint = 0

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

local function initTables()
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
            neighbors3[idx] = list
        end
    end
end

local function fillMax()
    for i = 1, COUNT do
        provenDepth[i] = MAX_DIST
        slack[i] = 0.0
        pendingClose[i] = nil
        age[i] = 100000
        priority[i] = 0
    end
end

local function effectiveDepth(idx)
    return clamp(
        (provenDepth[idx] or MAX_DIST) + (slack[idx] or 0.0),
        1.0,
        MAX_DIST
    )
end

local function verticalRowCap(row, pitch)
    local base = LEVEL_ROW_CAP[row] or MAX_DIST
    local t = clamp(math.abs(pitch or 0.0) / FULL_VERTICAL_PITCH, 0.0, 1.0)
    return base + (MAX_DIST - base) * t
end

local function publishGrid(pitch)
    -- First preserve V1's exact 3x3 MAX dilation.
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

            -- Then apply the experimental vertical cap to the published row.
            local cap = verticalRowCap(row, pitch)
            out[(row - 1) * COLS + col] = math.min(best, cap)
        end
    end

    camera.setInteriorVisibilityGrid(COLS, ROWS, out, PADDING)
    return out
end

local function queueOpeningFan(idx)
    openingEventsSincePrint = openingEventsSincePrint + 1
    burstRemaining = math.max(burstRemaining, BURST_SECONDS)

    local row = math.floor((idx - 1) / COLS) + 1
    local col = ((idx - 1) % COLS) + 1

    -- Two-tile local fan. This is a visibility-prefetch fan, not a literal
    -- reflected ray. It spends the next cheap rays around a newly opened door/
    -- corner instead of scanning unrelated screen regions.
    for rr = math.max(1, row - 2), math.min(ROWS, row + 2) do
        for cc = math.max(1, col - 2), math.min(COLS, col + 2) do
            local j = (rr - 1) * COLS + cc
            local manhattan = math.abs(rr - row) + math.abs(cc - col)
            local p = OPENING_PRIORITY - manhattan
            if p > (priority[j] or 0) then
                priority[j] = p
            end
        end
    end
end

local function acceptDepth(idx, measured)
    measured = clamp(measured or MAX_DIST, 1.0, MAX_DIST)

    local currentProven = provenDepth[idx] or MAX_DIST
    local currentEffective = effectiveDepth(idx)

    -- A fresh ray makes this tile current again.
    slack[idx] = 0.0
    age[idx] = 0

    -- Opening/farther measurement: safe to expand immediately.
    if measured >= currentEffective - 1.0 then
        local wasOpening = (
            measured >= MAX_DIST - 1.0
            and currentProven < MAX_DIST - OPENING_JUMP
        ) or (
            measured - currentProven >= OPENING_JUMP
        )

        provenDepth[idx] = measured
        pendingClose[idx] = nil

        if wasOpening then
            queueOpeningFan(idx)
        end

        return
    end

    -- Close measurement: keep V1's two-sample confirmation.
    local pending = pendingClose[idx]

    if pending ~= nil and math.abs(pending - measured) <= CLOSE_CONFIRM_TOLERANCE then
        local confirmed = 0.5 * (pending + measured)

        if currentProven >= MAX_DIST - 1.0 then
            -- Fast initial convergence: exactly what made V1 useful.
            provenDepth[idx] = confirmed
        elseif confirmed >= currentProven then
            provenDepth[idx] = confirmed
        else
            -- Once established, average repeated close measurements over time.
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
    local okDir, dir = pcall(camera.viewportToWorldVector, screenPos[idx])

    if not okDir or dir == nil then
        rayFailuresSincePrint = rayFailuresSincePrint + 1
        acceptDepth(idx, MAX_DIST)
        return
    end

    -- Use V1's proven normalization path.
    local okNorm, norm = pcall(function() return dir:normalize() end)

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

local function addSmallMotionSlack(moveDist, yawDelta, pitchDelta)
    for i = 1, COUNT do
        local d = provenDepth[i] or MAX_DIST

        if d < MAX_DIST then
            local addMove = moveDist * MOVE_SLACK_SCALE
            local referenceDepth = math.max(ANGLE_SLACK_DEPTH_FLOOR, d)
            local addAngle =
                (math.abs(yawDelta) + math.abs(pitchDelta))
                * referenceDepth
                * ANGLE_SLACK_SCALE

            slack[i] = math.min(
                MAX_TILE_SLACK,
                (slack[i] or 0.0) + addMove + addAngle
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
            priority = priority[i] or 0,
            pending = pendingClose[i] ~= nil and 1 or 0,
            slack = slack[i] or 0.0,
            age = age[i] or 0,
        }
    end

    table.sort(candidates, function(a, b)
        if a.pending ~= b.pending then
            return a.pending > b.pending
        end
        if a.priority ~= b.priority then
            return a.priority > b.priority
        end
        if math.abs(a.slack - b.slack) > 0.01 then
            return a.slack > b.slack
        end
        return a.age > b.age
    end)

    local selected = {}

    for i = 1, math.min(budget, #candidates) do
        local idx = candidates[i].idx
        selected[#selected + 1] = idx

        if priority[idx] > 0 then
            priority[idx] = priority[idx] - 1
        end
    end

    return selected
end

local function printStatus(out, pitch, budget)
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
        '[TSP_VISGRID_V5] min=%.0f mean=%.0f max=%.0f lt1k=%d lt2k=%d reject=%.1f%% slack_mean=%.0f slack_max=%.0f pending=%d budget=%d burst=%.2f pitch_deg=%.1f rowcaps=%.0f/%.0f/%.0f/%.0f/%.0f rays=%d failures=%d openings=%d',
        minD,
        sum / COUNT,
        maxD,
        under1k,
        under2k,
        reject,
        slackSum / COUNT,
        slackMax,
        pendingN,
        budget,
        burstRemaining,
        math.deg(math.abs(pitch or 0.0)),
        verticalRowCap(1, pitch),
        verticalRowCap(2, pitch),
        verticalRowCap(3, pitch),
        verticalRowCap(4, pitch),
        verticalRowCap(5, pitch),
        raysSincePrint,
        rayFailuresSincePrint,
        openingEventsSincePrint
    ))

    raysSincePrint = 0
    rayFailuresSincePrint = 0
    openingEventsSincePrint = 0
end

local function fullReset(reason)
    fillMax()
    burstRemaining = BURST_SECONDS
    camera.setInteriorVisibilityGrid(COLS, ROWS, provenDepth, PADDING)
    print(string.format('[TSP_VISGRID_V5] full-reset reason=%s', reason or 'unknown'))
end

local function onInit()
    initTables()
    fillMax()

    if camera.clearInteriorVisibilityGrid ~= nil then
        camera.clearInteriorVisibilityGrid()
    end

    print(string.format(
        '[TSP_VISGRID_V5] loaded max=%.0f grid=%dx%d steady=%d burst=%d padding=%.0f vertical=on',
        MAX_DIST, COLS, ROWS, RAYS_STEADY, RAYS_BURST, PADDING
    ))
end

local function onFrame(dt)
    if dt == nil or dt <= 0.0 then return end

    statusElapsed = statusElapsed + dt

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
            fillMax()
            camera.clearInteriorVisibilityGrid()
            print('[TSP_VISGRID_V5] exit interior -> grid off')
        end
        return
    end

    local eye = camera.getPosition()
    if eye == nil then return end

    local yaw = camera.getYaw() or 0.0
    local pitch = camera.getPitch() or 0.0

    if not inInterior then
        inInterior = true
        lastCell = cell
        lastEye = eye
        lastYaw = yaw
        lastPitch = pitch

        fillMax()
        burstRemaining = BURST_SECONDS
        camera.resetInteriorVisibilityStats()
        lastStatsTested = 0.0
        lastStatsCulled = 0.0

        camera.setInteriorVisibilityGrid(COLS, ROWS, provenDepth, PADDING)
        print('[TSP_VISGRID_V5] enter interior -> persistent grid active')
    elseif cell ~= lastCell then
        lastCell = cell
        lastEye = eye
        lastYaw = yaw
        lastPitch = pitch
        fullReset('cell-change')
    else
        local moveDist = lastEye ~= nil and (eye - lastEye):length() or 0.0

        if moveDist > TELEPORT_RESET_DIST then
            lastEye = eye
            lastYaw = yaw
            lastPitch = pitch
            fullReset('teleport')
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
    if budget == RAYS_BURST then
        burstFramesSincePrint = burstFramesSincePrint + 1
    end

    local selected = chooseTiles(budget)

    for i = 1, #selected do
        sampleTile(selected[i], eye)
    end

    local out = publishGrid(pitch)

    -- Real projection maximum is deliberately 3000 in V5.
    local live = camera.getViewDistance() or MAX_DIST
    if math.abs(live - MAX_DIST) > 1.0 then
        camera.setViewDistance(MAX_DIST)
    end

    if statusElapsed >= PRINT_PERIOD then
        statusElapsed = statusElapsed - PRINT_PERIOD
        printStatus(out, pitch, budget)
    end
end

return {
    engineHandlers = {
        onInit = onInit,
        onFrame = onFrame,
    },
}
EOF_LUA

grep -Fq 'TSP_INTERIOR_VISGRID_LUA_V5' "$PKG/visgrid.lua"
grep -Fq 'local MAX_DIST = 3000.0' "$PKG/visgrid.lua"
grep -Fq 'local RAYS_STEADY = 5' "$PKG/visgrid.lua"
grep -Fq 'local RAYS_BURST = 10' "$PKG/visgrid.lua"
grep -Fq 'queueOpeningFan' "$PKG/visgrid.lua"
grep -Fq 'LEVEL_ROW_CAP' "$PKG/visgrid.lua"

if grep -Fq 'worldToViewportVector' "$PKG/visgrid.lua"; then
    echo "ERROR: V3 reprojection survived into V5."
    exit 1
fi

echo "PASS: V5 candidate generated."

echo
echo "===== 4/7 INSTALL V5 LUA ONLY ====="

scp -q "$PKG/visgrid.lua" "$DEV:/tmp/visgrid-v5.lua"

ssh "$DEV" "
set -e
test -s /tmp/visgrid-v5.lua
grep -Fq 'TSP_INTERIOR_VISGRID_LUA_V5' /tmp/visgrid-v5.lua
cp /tmp/visgrid-v5.lua '$LUA.new'
mv -f '$LUA.new' '$LUA'
rm -f /tmp/visgrid-v5.lua
sync
"

echo "PASS: V5 installed."

echo
echo "===== 5/7 VERIFY ENGINE UNCHANGED + SHA ====="

REMOTE_BIN_SHA="$(ssh "$DEV" "sha256sum '$BIN' | awk '{print \$1}'")"
REMOTE_LUA_SHA="$(ssh "$DEV" "sha256sum '$LUA' | awk '{print \$1}'")"
LOCAL_LUA_SHA="$(sha256sum "$PKG/visgrid.lua" | awk '{print $1}')"

[ "$LOCAL_LUA_SHA" = "$REMOTE_LUA_SHA" ] || {
    echo "ERROR: V5 Lua SHA mismatch."
    exit 1
}

ssh "$DEV" "
set -e
grep -a -q 'TSP_INTERIOR_VISGRID_051_V1' '$BIN'
grep -Fq 'TSP_INTERIOR_VISGRID_LUA_V5' '$LUA'
"

echo "OpenMW binary (unchanged V1 engine): $REMOTE_BIN_SHA"
echo "V5 Lua:                            $REMOTE_LUA_SHA"

echo
echo "===== 6/7 CREATE TRACE + ROLLBACK HELPERS ====="

cat > "$PKG/collect-visgrid-v5-trace.sh" <<'EOF_TRACE'
#!/usr/bin/env bash
set -Eeuo pipefail
DEV="${TSP_DEV:-root@192.168.1.25}"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="${1:-$HOME/Downloads/openmw51-visgrid-v5-trace-$STAMP.txt}"

{
    echo "=================================================================="
    echo "OPENMW INTERIOR VISGRID V5 TRACE"
    echo "=================================================================="
    ssh "$DEV" 'hostname; date'

    echo
    echo "===== VISGRID V5 ====="
    ssh "$DEV" '
        grep -hE \
          "TSP_VISGRID_V5|TSP_INTERIOR_VISGRID_051_V1|TSP_DEPTH_PROJECTION|Lua.*error|ERROR.*Lua" \
          /mnt/SDCARD/data/ports/openmw51/config-0.51/openmw.log \
          /mnt/SDCARD/tsp_prog.txt \
          2>/dev/null | tail -2400 || true
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
                tail -750 "$f"
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
chmod +x "$PKG/collect-visgrid-v5-trace.sh"

cat > "$PKG/rollback-visgrid-v5.sh" <<EOF_ROLLBACK
#!/usr/bin/env bash
set -Eeuo pipefail
DEV="\${TSP_DEV:-root@192.168.1.25}"
LUA="$LUA"
BACKUP="$REMOTE_BACKUP/visgrid.lua.before-v5"

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
echo "Restored exact pre-V5 sensor."
EOF_ROLLBACK
chmod +x "$PKG/rollback-visgrid-v5.sh"

cat > "$PKG/README-V5.txt" <<EOF_README
TSP INTERIOR VISGRID V5 PERSISTENT
==================================

Engine:
  unchanged TSP_INTERIOR_VISGRID_051_V1 C++ culler

Interior maximum:
  3000

Ray budget:
  steady 5/frame
  temporary burst 10/frame

Persistent movement:
  V4 global uncertainty removed
  per-tile slack max 650
  translation and angle add only small local safety allowance
  sampled tile immediately clears its own slack

Temporal:
  initial close contraction after two close hits
  established close depth uses EMA alpha 0.55

Opening/corner handling:
  new large far/open result creates a 2-tile priority fan
  neighbors are sampled during a short 10-ray burst
  no literal reflected/bounce rays

Vertical prototype:
  level row caps = 1900 / 2500 / 3000 / 2500 / 1900
  absolute camera pitch gradually lifts every row toward 3000
  full vertical allowance at 35 degrees pitch

Device backup:
  $REMOTE_BACKUP
EOF_README

echo
echo "===== 7/7 FINAL ====="
echo
echo "=================================================================="
echo "VISGRID V5 INSTALLED"
echo "=================================================================="
echo
echo "Test priority:"
echo "  1. Same bad Caldera wall — do NOT wait a long time."
echo "     The grid should settle much faster because entry uses 10 rays/frame."
echo "  2. Walk slowly while keeping that wall in view."
echo "     We specifically want to see whether FPS stays elevated instead of"
echo "     collapsing immediately to ~12."
echo "  3. Turn a corner."
echo "  4. Door -> long hallway."
echo "  5. Look level, then look strongly up/down and watch for vertical popping."
echo
echo "WHILE OPENMW IS STILL RUNNING:"
echo "  $PKG/collect-visgrid-v5-trace.sh"
echo
echo "Rollback (OpenMW closed):"
echo "  $PKG/rollback-visgrid-v5.sh"
echo "=================================================================="
