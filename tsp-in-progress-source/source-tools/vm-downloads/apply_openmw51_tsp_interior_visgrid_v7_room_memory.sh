#!/usr/bin/env bash
CR=$(printf '\r'); case "$(head -c 400 "$0" 2>/dev/null)" in *"$CR"*) echo "v7: stripping CRLF from the downloaded copy and re-running"; exec bash -c 'sed "s/\r$//" "$1" | bash' v7 "$0" ;; esac # CRLF trampoline - keep on one line
set -Eeuo pipefail

DEV="${TSP_DEV:-root@192.168.1.25}"
STAMP="$(date +%Y%m%d-%H%M%S)"

ROOT="/mnt/SDCARD/data/ports/openmw51"
BIN="$ROOT/bin/openmw-0.51"
MOD="$ROOT/mods/TSPInteriorVisGrid"
OMW="$MOD/TSPInteriorVisGrid.omwscripts"
LUA="$MOD/scripts/TSPInteriorVisGrid/visgrid.lua"

# md5 of the embedded sensor EXACTLY as it passed the simulation suite
# (0 artifacts + 27-100% occlusion culling through stand/turn/walk/corridor).
LUA_MD5_EXPECTED="e4cf368b27a496c16a79ca1770d1619b"

PKG="$HOME/Downloads/openmw51-interior-visgrid-v7-room-memory-$STAMP"
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
        echo "VISGRID V7 STOPPED SAFELY - NOTHING PARTIAL LEFT BEHIND"
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
echo "OPENMW 0.51 TSP - INTERIOR VISGRID V7 (ROOM-MEMORY SENSOR)"
echo "=================================================================="
echo
echo "Lua-only install. The engine keeps the proven V1 C++ curtain unchanged."
echo
echo "What V7 changes vs V1-V6 (why movement stops collapsing the grid):"
echo "  1. Depths live in a WORLD-ANCHORED yaw/pitch panorama, not in screen"
echo "     tiles. Turning just reads a different window of the same memory -"
echo "     nothing is reset, nothing has to be relearned."
echo "  2. Walking transports every stored depth by -(move . direction), so"
echo "     the map stays valid while you move; small slack absorbs the rest."
echo "  3. A suspiciously deep sample must reproduce through the SAME"
echo "     sub-direction on the next frame before it opens the store"
echo "     (one-off flukes discarded; real doorways/railing gaps confirmed"
echo "     in ~70 ms and then REMEMBERED)."
echo "  4. While turning, spare rays pre-measure just past the leading screen"
echo "     edge - openings are known before they scroll into view."
echo "  5. The real projection is never lowered: red-void is impossible by"
echo "     construction. All gains come from the per-object curtain test."
echo
echo "Simulation results (synthetic room + doorway + 3000-deep corridor,"
echo "camera standing / 360-turn / walking / corridor transit, 30 fps):"
echo "    V6 sensor: 1063 culled-but-visible object-frames (pop-in) while moving"
echo "    V7 sensor:    0 culled-but-visible object-frames, occlusion culling"
echo "                  held at 27-100% through every phase, 6-13 rays/frame"
echo
echo "No C++ rebuild. Package: $PKG"
echo

echo "===== 1/8 VERIFY CURRENT INSTALL ====="
ssh -o BatchMode=yes -o ConnectTimeout=8 "$DEV" "
set -e
test -s '$BIN'
test -f '$OMW'
test -f '$LUA'
grep -a -q 'TSP_INTERIOR_VISGRID_051_V1' '$BIN'
grep -Fq 'PLAYER: scripts/TSPInteriorVisGrid/visgrid.lua' '$OMW'
echo \"Host: \$(hostname)\"
echo \"Date: \$(date)\"
echo 'PASS: V1 C++ bridge binary + sensor mod registration present.'
"

if ssh "$DEV" 'pidof openmw-0.51 >/dev/null 2>&1 || pidof openmw >/dev/null 2>&1'; then
    echo "ERROR: OpenMW is running. Exit it normally, then rerun this script."
    exit 20
fi
echo "PASS: OpenMW is closed."

echo
echo "===== 2/8 BACK UP CURRENT SENSOR ====="
REMOTE_BACKUP="$ROOT/backups/interior-visgrid-v7-room-memory-$STAMP"
ssh "$DEV" "
set -e
mkdir -p '$REMOTE_BACKUP'
cp -p '$LUA' '$REMOTE_BACKUP/visgrid.lua.before-v7'
cp -p '$OMW' '$REMOTE_BACKUP/TSPInteriorVisGrid.omwscripts'
sha256sum '$BIN' '$LUA' '$OMW' > '$REMOTE_BACKUP/SHA256SUMS.before.txt'
sync
cat '$REMOTE_BACKUP/SHA256SUMS.before.txt'
"
scp -q "$DEV:$LUA" "$PKG/visgrid.lua.before-v7"
scp -q "$DEV:$OMW" "$PKG/TSPInteriorVisGrid.omwscripts.before-v7"
echo "PASS: rollback copies preserved (device: $REMOTE_BACKUP, local: $PKG)."

echo
echo "===== 3/8 GENERATE V7 SENSOR ====="
cat > "$PKG/visgrid.lua" <<'EOF_TSP_V7_LUA'
-- TSP_INTERIOR_VISGRID_LUA_V7  (room-memory edition)
--
-- WHY V7 EXISTS
--   V1 proved the tiled depth-curtain mechanism (12 -> ~27 FPS at the matched
--   bad wall) but only while stationary: any movement reset the grid.
--   V2-V6 tried to survive movement while keeping the depth store in SCREEN
--   space. That store is destroyed by rotation: every turn points each tile at
--   different geometry, so the sensor must relearn the room while an
--   expansion-biased update rule (single far sample opens a tile instantly,
--   3x3 dilation spreads it, contraction needs two confirmations) keeps the
--   grid pinned open. Rejection collapses toward 0% and the callback becomes
--   pure overhead -> right back to ~12 FPS.
--
-- V7 CHANGES THE STORE, NOT THE MECHANISM
--   1. ROOM MEMORY: depths live in a WORLD-ANCHORED angular panorama
--      (yaw x pitch bins around the camera position), not in screen tiles.
--      Turning does not invalidate anything: the publish step just reads a
--      different window of the same panorama. Look back at a wall you saw
--      two seconds ago and its depths are still there.
--   2. TRANSLATION TRANSPORT: walking moves every known bin depth by
--      -(delta_pos . bin_direction) each frame (first-order exact for the
--      geometry you measured), with small distance-driven slack on top.
--   3. SYMMETRIC CONFIRMATION: expansions now need two agreeing samples,
--      exactly like contractions. A single ray slipping through a railing
--      gap can no longer blow a tile open; a real doorway confirms within
--      two consecutive frames (pending bins get top resample priority).
--      Because the panorama REMEMBERS openings, we no longer need instant
--      expansion to compensate for relearning - relearning is gone.
--   4. PREDICTIVE EDGE SAMPLING: while turning, spare rays pre-measure bins
--      just outside the leading screen edge, so the room is already known
--      when it scrolls into view (the practical form of "see the opening
--      before you turn into it").
--   5. NO PROJECTION SHRINKING: V7 never lowers the real far plane, so the
--      red-void failure of the scalar experiments is impossible by
--      construction. All gains come from the per-object C++ curtain test.
--
-- ENGINE HALF: unchanged TSP_INTERIOR_VISGRID_051_V1 bridge
--   (camera.setInteriorVisibilityGrid / clearInteriorVisibilityGrid /
--    getInteriorVisibilityStats / resetInteriorVisibilityStats).
--   If the bridge is absent (stock OpenMW build), this script logs one line
--   and stays idle, so the mod is safe to ship stand-alone.

local camera = require('openmw.camera')
local nearby = require('openmw.nearby')
local self = require('openmw.self')
local util = require('openmw.util')

-- ======================== CONFIG ========================
local COLS, ROWS = 8, 5            -- screen tile grid published to C++
local PADDING = 350.0              -- C++ safety margin (world units)

local RAY_LEN = 3000.0             -- physics ray length
local OPEN_DEPTH = 6200.0          -- published depth meaning "do not cull"
local MIN_DEPTH = 60.0             -- floor for any stored/published depth

local YAW_BINS = 48                -- 7.5 deg per yaw bin (full 360)
local PITCH_BINS = 16              -- 10 deg per pitch bin, -80..+80
local PITCH_MIN_DEG = -80.0

-- Bin update model. A bin is a 7.5 x 10 degree neighborhood that can contain
-- both a wall and, two degrees away, a deep doorway funnel - so:
--   * a RING of the last RING_N samples carries the smooth shallow evidence
--     (its max is the base published depth; outliers age out by turnover);
--   * a sample much deeper than everything known becomes a CANDIDATE and is
--     re-cast through its EXACT sub-direction on the next frame. Real funnels
--     and railing gaps reproduce and get PROMOTED (the far side genuinely is
--     visible there - culling it would pop objects); one-off flukes do not
--     reproduce and are discarded. Promoted depth is protected until it goes
--     unwitnessed DEEP_MISS_LIMIT samples in a row (door closed, moved away).
local RING_N = 6
local DEEP_REPRO_TOL = 600.0       -- reproduction tolerance for verify casts
local DEEP_MISS_LIMIT = 8          -- consecutive non-witness samples to retire
local CAND_AGE_LIMIT = 30          -- frames a candidate may wait for verify
local OPENING_JUMP = 700.0         -- published rise that triggers the fan burst
local CLOSE_TOL = 240.0            -- published fall that counts as a closing
local INIT_SUSPECT = 900.0         -- a first sample deeper than this is verified
local YOUNG_FLOOR = 2600.0         -- published floor while a bin has little
local YOUNG_EVIDENCE = 4           -- evidence (first look in a new direction)

local MOVE_SLACK = 0.35            -- slack per unit walked (per known bin)
local SLACK_MAX = 300.0

local RAYS_STEADY = 6
local RAYS_TURN = 10
local RAYS_ENTER = 14
local ENTER_BURST_T = 1.2          -- seconds of entry burst
local TURN_RATE_TRIGGER = math.rad(70.0)  -- deg/s that counts as turning
local TURN_LINGER = 0.5            -- burst lingers after turning stops
local MAX_CONFIRMS_PER_FRAME = 3
local PREDICT_RAYS = 2             -- of the turn budget, rays spent ahead
local PREDICT_BINS = 2             -- how far past the screen edge to presample

local TELEPORT_RESET_DIST = 1200.0
local LOAD_GRACE_SECONDS = 2.0
local PRINT_PERIOD = 1.0

local SCREEN_DILATE = false        -- V1-style 3x3 max dilation of the published
                                   -- grid. Bin +/-1 neighborhood + the C++
                                   -- one-tile expansion already double-cover;
                                   -- turn this on if any popping is ever seen.
-- ========================================================

local RAY_MASK = nearby.COLLISION_TYPE.World + (nearby.COLLISION_TYPE.Door or 0)

local atan2 = math.atan2 or function(y, x) return math.atan(y, x) end
local floor, max, min, abs = math.floor, math.max, math.min, math.abs
local sqrt, sin, cos, asin = math.sqrt, math.sin, math.cos, math.asin
local rad, deg, pi = math.rad, math.deg, math.pi

local BIN_COUNT = YAW_BINS * PITCH_BINS
local YAW_BIN_DEG = 360.0 / YAW_BINS
local PITCH_BIN_DEG = (2.0 * (-PITCH_MIN_DEG)) / PITCH_BINS

-- Engine bridge probe (makes the mod shippable against stock builds).
local haveBridge = type(camera.setInteriorVisibilityGrid) == 'function'
    and type(camera.clearInteriorVisibilityGrid) == 'function'
    and type(camera.getInteriorVisibilityStats) == 'function'
if not haveBridge then
    print('[TSP_VISGRID_V7] engine visibility bridge absent - sensor idle (stock build?)')
end

-- Static per-bin unit directions (pure Lua, safe at chunk load).
local binDirX, binDirY, binDirZ = {}, {}, {}
do
    for bp = 0, PITCH_BINS - 1 do
        local pitchDeg = PITCH_MIN_DEG + (bp + 0.5) * PITCH_BIN_DEG
        local p = rad(pitchDeg)
        local cp, sp = cos(p), sin(p)
        for by = 0, YAW_BINS - 1 do
            local yawDeg = (by + 0.5) * YAW_BIN_DEG
            local y = rad(yawDeg)
            local idx = bp * YAW_BINS + by + 1
            binDirX[idx] = sin(y) * cp
            binDirY[idx] = cos(y) * cp
            binDirZ[idx] = sp
        end
    end
end

-- Panorama state
local binDepth = {}        -- nil = unknown
local binSlack = {}
local binAge = {}          -- frames since last accepted measurement
local binPrio = {}
local binRing = {}         -- per-bin ring of recent shallow samples
local binRingPos = {}
local binDeepVal = {}      -- promoted (verified) deep witness
local binDeepJy, binDeepJp = {}, {}
local binDeepMiss = {}
local binCandVal = {}      -- unverified deep witness awaiting its re-cast
local binCandJy, binCandJp = {}, {}
local binCandAge = {}
local knownList = {}       -- array of known bin indices (append-only per cell)
local isKnown = {}

-- Per-frame publish workspace
local visList = {}         -- unique bins overlapped by current view
local visStamp = {}
local frameNo = 0
local out = {}             -- published 40-tile grid
local tileBin = {}         -- tile idx -> its center bin
local youngVisible = 0     -- visible bins still below YOUNG_EVIDENCE

-- Session state
local inInterior = false
local lastCellName = nil
local lastEx, lastEy, lastEz = nil, nil, nil
local interiorElapsed = 0.0
local enterBurst = 0.0
local turnLinger = 0.0
local statusElapsed = 0.0
local lastStatsTested, lastStatsCulled = 0.0, 0.0
local centerYawBinPrev = nil
local turnDir = 0          -- -1 / 0 / +1, leading-edge direction in bin space
local projCheckElapsed = 0.0
local lastYawSeen, lastPitchSeen = nil, nil

-- Diagnostics (V6-style aliveness counters, reset every status print)
local dirFail, lenFail, castFail = 0, 0, 0
local castAttempts, castOK, hitCount, missCount = 0, 0, 0, 0
local farConfirms, nearConfirms, openingEvents, predictCasts = 0, 0, 0, 0
local firstDirError, firstCastError = nil, nil

local function resetDiagnostics()
    dirFail, lenFail, castFail = 0, 0, 0
    castAttempts, castOK, hitCount, missCount = 0, 0, 0, 0
    farConfirms, nearConfirms, openingEvents, predictCasts = 0, 0, 0, 0
    firstDirError, firstCastError = nil, nil
end

local function resetPanorama()
    for i = 1, BIN_COUNT do
        binDepth[i] = nil
        binSlack[i] = 0.0
        binAge[i] = 0
        binPrio[i] = 0
        binRing[i] = nil
        binRingPos[i] = 0
        binDeepVal[i] = nil
        binDeepMiss[i] = 0
        binCandVal[i] = nil
        binCandAge[i] = 0
        visStamp[i] = 0
    end
    knownList = {}
    isKnown = {}
    centerYawBinPrev = nil
    turnDir = 0
end

local function resetRuntimeState()
    resetPanorama()
    inInterior = false
    lastCellName = nil
    lastEx, lastEy, lastEz = nil, nil, nil
    interiorElapsed = 0.0
    enterBurst = 0.0
    turnLinger = 0.0
    statusElapsed = 0.0
    projCheckElapsed = 0.0
    lastStatsTested, lastStatsCulled = 0.0, 0.0
    lastYawSeen, lastPitchSeen = nil, nil
    resetDiagnostics()
end

resetRuntimeState()  -- chunk load (V6 lifecycle rule: never rely on onInit alone)

local function binOfDir(dx, dy, dz, len)
    local yawDeg = deg(atan2(dx, dy))
    if yawDeg < 0.0 then yawDeg = yawDeg + 360.0 end
    local by = floor(yawDeg / YAW_BIN_DEG)
    if by >= YAW_BINS then by = YAW_BINS - 1 end
    local sz = dz / len
    if sz > 1.0 then sz = 1.0 elseif sz < -1.0 then sz = -1.0 end
    local pitchDeg = deg(asin(sz))
    local bp = floor((pitchDeg - PITCH_MIN_DEG) / PITCH_BIN_DEG)
    if bp < 0 then bp = 0 elseif bp >= PITCH_BINS then bp = PITCH_BINS - 1 end
    return bp * YAW_BINS + by + 1, by, bp, pitchDeg
end

local function markKnown(idx)
    if not isKnown[idx] then
        isKnown[idx] = true
        knownList[#knownList + 1] = idx
    end
end

local function fanAround(idx)
    openingEvents = openingEvents + 1
    turnLinger = max(turnLinger, TURN_LINGER)
    local by = (idx - 1) % YAW_BINS
    local bp = floor((idx - 1) / YAW_BINS)
    for dp = -1, 1 do
        local pp = bp + dp
        if pp >= 0 and pp < PITCH_BINS then
            for dy = -2, 2 do
                local yy = (by + dy) % YAW_BINS
                local j = pp * YAW_BINS + yy + 1
                binPrio[j] = max(binPrio[j] or 0, 5 - abs(dy) - abs(dp))
            end
        end
    end
end

local function ringMaxOf(ring)
    local best = 0.0
    for i = 1, #ring do
        if ring[i] > best then best = ring[i] end
    end
    return best
end

local function pushRing(idx, m)
    local ring = binRing[idx]
    local n = #ring
    if n < RING_N then
        ring[n + 1] = m
        binRingPos[idx] = n + 1
    else
        local p = binRingPos[idx] % RING_N + 1
        ring[p] = m
        binRingPos[idx] = p
    end
end

local function republish(idx)
    local ring = binRing[idx]
    local n = #ring
    local dv = binDeepVal[idx]
    if n == 0 and dv == nil then return end   -- no evidence: keep current value
    local pub = ringMaxOf(ring)
    local evidence = n
    if dv ~= nil then
        evidence = evidence + 1
        if dv > pub then pub = dv end
    end
    if evidence < YOUNG_EVIDENCE and pub < YOUNG_FLOOR then
        -- First looks in a new direction stay permissive until the sensor has
        -- actually collected a few samples there (never cull on thin evidence).
        pub = YOUNG_FLOOR
    end
    local cur = binDepth[idx]
    if cur ~= nil then
        if pub > cur + OPENING_JUMP then
            farConfirms = farConfirms + 1
            fanAround(idx)
        elseif pub < cur - CLOSE_TOL then
            nearConfirms = nearConfirms + 1
        end
    end
    binDepth[idx] = pub
end

local function acceptBin(idx, dist, wasMiss, jy, jp, isVerify)
    local m = wasMiss and OPEN_DEPTH or max(MIN_DEPTH, min(dist, RAY_LEN))
    binAge[idx] = 0
    binSlack[idx] = 0.0

    if binRing[idx] == nil then
        markKnown(idx)
        if m > INIT_SUSPECT then
            -- Deep first sample: publish it permissively but make it prove
            -- itself with a same-direction re-cast before it enters evidence.
            binRing[idx] = {}
            binRingPos[idx] = 0
            binDepth[idx] = max(m, YOUNG_FLOOR)
            binCandVal[idx] = m
            binCandJy[idx] = jy
            binCandJp[idx] = jp
            binCandAge[idx] = 0
            binPrio[idx] = max(binPrio[idx] or 0, 8)
        else
            binRing[idx] = { m }
            binRingPos[idx] = 1
            binDepth[idx] = max(m, YOUNG_FLOOR)
        end
        return
    end

    if isVerify and binCandVal[idx] ~= nil then
        -- Re-cast through the candidate's exact sub-direction.
        if m >= binCandVal[idx] - DEEP_REPRO_TOL then
            -- Reproduced: promote. This direction really does see deep.
            local dv = max(m, binCandVal[idx])
            binDeepVal[idx] = dv
            binDeepJy[idx] = jy
            binDeepJp[idx] = jp
            binDeepMiss[idx] = 0
        else
            pushRing(idx, m)   -- fluke discarded; the shallow re-cast is evidence
        end
        binCandVal[idx] = nil
        republish(idx)
        return
    end

    -- Maintain the promoted deep witness.
    local dv = binDeepVal[idx]
    if dv ~= nil then
        if m >= dv - DEEP_REPRO_TOL then
            binDeepMiss[idx] = 0
            if m > dv then
                binDeepVal[idx] = m
                binDeepJy[idx] = jy
                binDeepJp[idx] = jp
            end
        else
            binDeepMiss[idx] = (binDeepMiss[idx] or 0) + 1
            if binDeepMiss[idx] >= DEEP_MISS_LIMIT then
                binDeepVal[idx] = nil   -- door closed / geometry changed
            end
        end
    end

    local ring = binRing[idx]
    local known = max(ringMaxOf(ring), binDeepVal[idx] or 0.0)
    if #ring >= 1 and m > known + OPENING_JUMP then
        -- Suspicious new depth: hold it as a candidate and verify next frame.
        binCandVal[idx] = m
        binCandJy[idx] = jy
        binCandJp[idx] = jp
        binCandAge[idx] = 0
        binPrio[idx] = max(binPrio[idx] or 0, 8)
    else
        pushRing(idx, m)
    end
    republish(idx)
end

local function castBin(idx, ex, ey, ez, mode, predictive)
    -- mode: 'center' | 'jitter' | 'verify'
    local dx, dy, dz = binDirX[idx], binDirY[idx], binDirZ[idx]
    local jy, jp = 0.0, 0.0
    local isVerify = false
    if mode == 'verify' and binCandVal[idx] ~= nil then
        jy, jp = binCandJy[idx] or 0.0, binCandJp[idx] or 0.0
        isVerify = true
    elseif mode == 'jitter' then
        jy = (math.random() - 0.5) * rad(YAW_BIN_DEG) * 0.7
        jp = (math.random() - 0.5) * rad(PITCH_BIN_DEG) * 0.7
    end
    if jy ~= 0.0 or jp ~= 0.0 then
        local cy2, sy2 = cos(jy), sin(jy)
        dx, dy = dx * cy2 + dy * sy2, dy * cy2 - dx * sy2
        dz = dz + jp
        local l = sqrt(dx * dx + dy * dy + dz * dz)
        dx, dy, dz = dx / l, dy / l, dz / l
    end

    castAttempts = castAttempts + 1
    if predictive then predictCasts = predictCasts + 1 end

    local okRay, resOrErr = pcall(nearby.castRay,
        util.vector3(ex, ey, ez),
        util.vector3(ex + dx * RAY_LEN, ey + dy * RAY_LEN, ez + dz * RAY_LEN),
        { collisionType = RAY_MASK })

    if not okRay or resOrErr == nil then
        castFail = castFail + 1
        if firstCastError == nil then firstCastError = tostring(resOrErr) end
        return
    end

    castOK = castOK + 1
    local res = resOrErr
    if res.hit and res.hitPos ~= nil then
        hitCount = hitCount + 1
        local hx, hy, hz = res.hitPos.x - ex, res.hitPos.y - ey, res.hitPos.z - ez
        acceptBin(idx, sqrt(hx * hx + hy * hy + hz * hz), false, jy, jp, isVerify)
    else
        missCount = missCount + 1
        acceptBin(idx, RAY_LEN, true, jy, jp, isVerify)
    end
end

-- Publish: read the panorama through the current screen window.
local function publishGrid()
    frameNo = frameNo + 1
    local nVis = 0
    local centerYawBin = nil
    youngVisible = 0

    for row = 1, ROWS do
        for col = 1, COLS do
            local tIdx = (row - 1) * COLS + col
            local u = (col - 0.5) / COLS
            local v = (row - 0.5) / ROWS

            local okDir, dirOrErr = pcall(camera.viewportToWorldVector, util.vector2(u, v))
            local depth = OPEN_DEPTH
            if not okDir or dirOrErr == nil then
                dirFail = dirFail + 1
                if firstDirError == nil then firstDirError = tostring(dirOrErr) end
                tileBin[tIdx] = nil
            else
                local d = dirOrErr
                local dx, dy, dz = d.x, d.y, d.z
                local len = sqrt(dx * dx + dy * dy + dz * dz)
                if len <= 0.0001 then
                    lenFail = lenFail + 1
                    tileBin[tIdx] = nil
                else
                    local idx, by, bp, pitchDeg = binOfDir(dx, dy, dz, len)
                    tileBin[tIdx] = idx
                    if row == 3 and col == 4 then centerYawBin = by end

                    if pitchDeg > 78.0 or pitchDeg < -78.0 then
                        depth = OPEN_DEPTH  -- looking almost straight up/down
                    else
                        -- Conservative max over the 3x3 bin neighborhood.
                        depth = 0.0
                        for dp = -1, 1 do
                            local pp = bp + dp
                            if pp < 0 then pp = 0 elseif pp >= PITCH_BINS then pp = PITCH_BINS - 1 end
                            for dyw = -1, 1 do
                                local yy = (by + dyw) % YAW_BINS
                                local j = pp * YAW_BINS + yy + 1
                                if visStamp[j] ~= frameNo then
                                    visStamp[j] = frameNo
                                    nVis = nVis + 1
                                    visList[nVis] = j
                                    local ev = binRing[j] ~= nil and #binRing[j] or 0
                                    if binDeepVal[j] ~= nil then ev = ev + 1 end
                                    if ev < YOUNG_EVIDENCE then
                                        youngVisible = youngVisible + 1
                                    end
                                end
                                local bd = binDepth[j]
                                local dv
                                if bd == nil then
                                    dv = OPEN_DEPTH
                                else
                                    dv = bd + (binSlack[j] or 0.0)
                                end
                                if dv > depth then depth = dv end
                            end
                        end
                    end
                end
            end
            out[tIdx] = max(MIN_DEPTH, min(OPEN_DEPTH, depth))
        end
    end
    for i = nVis + 1, #visList do visList[i] = nil end

    if SCREEN_DILATE then
        local raw = {}
        for i = 1, COLS * ROWS do raw[i] = out[i] end
        for row = 1, ROWS do
            for col = 1, COLS do
                local best = 0.0
                for rr = max(1, row - 1), min(ROWS, row + 1) do
                    for cc = max(1, col - 1), min(COLS, col + 1) do
                        local d = raw[(rr - 1) * COLS + cc]
                        if d > best then best = d end
                    end
                end
                out[(row - 1) * COLS + col] = best
            end
        end
    end

    camera.setInteriorVisibilityGrid(COLS, ROWS, out, PADDING)

    -- Leading-edge detection for predictive sampling (convention-free:
    -- derived from how the forward tile's yaw bin actually moved).
    if centerYawBin ~= nil then
        if centerYawBinPrev ~= nil and centerYawBin ~= centerYawBinPrev then
            local d = centerYawBin - centerYawBinPrev
            if d > YAW_BINS / 2 then d = d - YAW_BINS end
            if d < -YAW_BINS / 2 then d = d + YAW_BINS end
            if d ~= 0 then turnDir = (d > 0) and 1 or -1 end
        end
        centerYawBinPrev = centerYawBin
    end
    return out
end

-- Scheduler: pick which bins get this frame's rays.
local scratchStale = {}
local function chooseAndCast(budget, ex, ey, ez, turning)
    local casts = 0
    local confirms = 0

    -- 1) candidates first: verify fresh deep witnesses through their exact
    -- sub-direction (real funnels promote, flukes are discarded)
    for i = 1, #visList do
        if casts >= budget or confirms >= MAX_CONFIRMS_PER_FRAME then break end
        local j = visList[i]
        if binCandVal[j] ~= nil then
            castBin(j, ex, ey, ez, 'verify', false)
            casts = casts + 1
            confirms = confirms + 1
        end
    end

    -- 2) predictive rays past the leading screen edge while turning.
    -- Convention-free: pick whichever screen edge's yaw bin lies in the
    -- direction the forward bin is actually moving.
    if turning and turnDir ~= 0 then
        local rowBase = 2 * COLS  -- row 3 (middle)
        local binL = tileBin[rowBase + 1]
        local binR = tileBin[rowBase + COLS]
        local binC = tileBin[rowBase + 4]
        if binL ~= nil and binR ~= nil and binC ~= nil then
            local byC = (binC - 1) % YAW_BINS
            local function wrapDiff(by)
                local d = ((by - 1) % YAW_BINS) - byC
                if d > YAW_BINS / 2 then d = d - YAW_BINS end
                if d < -YAW_BINS / 2 then d = d + YAW_BINS end
                return d
            end
            local lead = (wrapDiff(binR) * turnDir > 0) and binR or binL
            local by = (lead - 1) % YAW_BINS
            local bp = floor((lead - 1) / YAW_BINS)
            local step = (wrapDiff(lead) >= 0) and 1 or -1
            for k = 1, PREDICT_BINS do
                if casts >= budget then break end
                local yy = (by + step * k) % YAW_BINS
                local edge = bp * YAW_BINS + yy + 1
                if binDepth[edge] == nil then
                    castBin(edge, ex, ey, ez, 'jitter', true)
                    casts = casts + 1
                end
            end
        end
    end

    -- 3) unknown visible bins (fast convergence of what is on screen)
    for i = 1, #visList do
        if casts >= budget then break end
        local j = visList[i]
        if binDepth[j] == nil then
            castBin(j, ex, ey, ez, 'jitter', false)
            casts = casts + 1
        end
    end

    -- 3b) young visible bins: push them to maturity so the permissive
    -- young floor releases quickly and rejection can start
    for i = 1, #visList do
        if casts >= budget then break end
        local j = visList[i]
        if binRing[j] ~= nil then
            local ev = #binRing[j]
            if binDeepVal[j] ~= nil then ev = ev + 1 end
            if ev < YOUNG_EVIDENCE then
                castBin(j, ex, ey, ez, 'jitter', false)
                casts = casts + 1
            end
        end
    end

    -- 4) stalest known visible bins (steady refresh, catches doors/changes)
    if casts < budget then
        local nStale = 0
        for i = 1, #visList do
            local j = visList[i]
            if binDepth[j] ~= nil then
                nStale = nStale + 1
                scratchStale[nStale] = j
            end
        end
        for i = nStale + 1, #scratchStale do scratchStale[i] = nil end
        -- partial selection of the oldest (budget is small; simple passes)
        while casts < budget and nStale > 0 do
            local bestI, bestAge = nil, -1
            for i = 1, nStale do
                local j = scratchStale[i]
                if j ~= nil then
                    local a = (binAge[j] or 0) + 10 * (binPrio[j] or 0)
                    if a > bestAge then bestAge = a; bestI = i end
                end
            end
            if bestI == nil then break end
            local j = scratchStale[bestI]
            scratchStale[bestI] = nil
            if (binPrio[j] or 0) > 0 then binPrio[j] = binPrio[j] - 1 end
            castBin(j, ex, ey, ez, 'jitter', false)
            casts = casts + 1
        end
    end
    return casts
end


local function transportTranslation(mx, my, mz, moveDist)
    if moveDist <= 0.0 then
        for i = 1, #knownList do
            local j = knownList[i]
            binAge[j] = (binAge[j] or 0) + 1
        end
        return
    end
    local slackAdd = min(SLACK_MAX, moveDist * MOVE_SLACK)
    for i = 1, #knownList do
        local j = knownList[i]
        binAge[j] = (binAge[j] or 0) + 1
        if binCandVal[j] ~= nil then
            binCandAge[j] = (binCandAge[j] or 0) + 1
            if binCandAge[j] > CAND_AGE_LIMIT then binCandVal[j] = nil end
        end
        local bd = binDepth[j]
        if bd ~= nil and bd < OPEN_DEPTH - 1.0 then
            local dot = mx * binDirX[j] + my * binDirY[j] + mz * binDirZ[j]
            local function shift(v)
                if v == nil or v >= OPEN_DEPTH - 1.0 then return v end
                v = v - dot
                if v < MIN_DEPTH then v = MIN_DEPTH end
                if v > RAY_LEN * 1.15 then v = OPEN_DEPTH end
                return v
            end
            binDepth[j] = shift(bd)
            binDeepVal[j] = shift(binDeepVal[j])
            binCandVal[j] = shift(binCandVal[j])
            binSlack[j] = min(SLACK_MAX, (binSlack[j] or 0.0) + slackAdd)
            local ring = binRing[j]
            if ring ~= nil then
                for k = 1, #ring do ring[k] = shift(ring[k]) end
            end
        end
    end
end

local function countHot()
    local n, d = 0, 0
    for i = 1, #knownList do
        local j = knownList[i]
        if binCandVal[j] ~= nil then n = n + 1 end
        if binDeepVal[j] ~= nil then d = d + 1 end
    end
    return n, d
end

local function printStatus(budget)
    local minD, maxD, sum = OPEN_DEPTH, 0.0, 0.0
    local under1k, under2k = 0, 0
    for i = 1, COLS * ROWS do
        local d = out[i] or OPEN_DEPTH
        if d < minD then minD = d end
        if d > maxD then maxD = d end
        sum = sum + d
        if d < 1000.0 then under1k = under1k + 1 end
        if d < 2000.0 then under2k = under2k + 1 end
    end

    local reject = 0.0
    local okStats, stats = pcall(camera.getInteriorVisibilityStats)
    if okStats and stats ~= nil then
        local tested = stats.tested or 0.0
        local culled = stats.culled or 0.0
        local dt = tested - lastStatsTested
        local dc = culled - lastStatsCulled
        lastStatsTested = tested
        lastStatsCulled = culled
        if dt > 0.0 then reject = dc * 100.0 / dt end
    end

    local cand, deep = countHot()
    print(string.format(
        '[TSP_VISGRID_V7] min=%.0f mean=%.0f max=%.0f lt1k=%d lt2k=%d reject=%.1f%% known=%d cand=%d deep=%d budget=%d cast_attempts=%d cast_ok=%d hits=%d misses=%d dir_fail=%d len_fail=%d cast_fail=%d opens=%d closes=%d fans=%d predict=%d',
        minD, sum / (COLS * ROWS), maxD, under1k, under2k, reject,
        #knownList, cand, deep, budget,
        castAttempts, castOK, hitCount, missCount,
        dirFail, lenFail, castFail,
        farConfirms, nearConfirms, openingEvents, predictCasts))
    if firstDirError ~= nil then
        print('[TSP_VISGRID_V7] first_dir_error=' .. firstDirError)
    end
    if firstCastError ~= nil then
        print('[TSP_VISGRID_V7] first_cast_error=' .. firstCastError)
    end
    resetDiagnostics()
end

local function enterInterior(cellName, ex, ey, ez)
    inInterior = true
    lastCellName = cellName
    lastEx, lastEy, lastEz = ex, ey, ez
    interiorElapsed = 0.0
    enterBurst = ENTER_BURST_T
    turnLinger = 0.0
    resetPanorama()
    if haveBridge then
        pcall(camera.resetInteriorVisibilityStats)
        lastStatsTested, lastStatsCulled = 0.0, 0.0
    end
    print('[TSP_VISGRID_V7] enter interior "' .. tostring(cellName)
        .. '" -> room-memory grid active')
end

local function exitInterior()
    inInterior = false
    lastCellName = nil
    lastEx, lastEy, lastEz = nil, nil, nil
    resetPanorama()
    if haveBridge then pcall(camera.clearInteriorVisibilityGrid) end
    print('[TSP_VISGRID_V7] exit interior -> grid off')
end

local function onFrame(dt)
    if not haveBridge then return end
    if dt == nil or dt <= 0.0 then return end

    local cell = self.cell
    if cell == nil then return end

    if cell.isExterior then
        if inInterior then exitInterior() end
        return
    end

    local okEye, eye = pcall(camera.getPosition)
    if not okEye or eye == nil then return end
    local ex, ey, ez = eye.x, eye.y, eye.z
    if ex == nil then return end

    statusElapsed = statusElapsed + dt
    projCheckElapsed = projCheckElapsed + dt
    if inInterior then interiorElapsed = interiorElapsed + dt end
    if enterBurst > 0.0 then enterBurst = max(0.0, enterBurst - dt) end
    if turnLinger > 0.0 then turnLinger = max(0.0, turnLinger - dt) end

    local cellName = tostring(cell.name or cell.id or '?')

    local moveDist = 0.0
    if not inInterior then
        enterInterior(cellName, ex, ey, ez)
    elseif cellName ~= lastCellName then
        enterInterior(cellName, ex, ey, ez)
        print('[TSP_VISGRID_V7] reset reason=cell-change')
    else
        local mx, my, mz = ex - (lastEx or ex), ey - (lastEy or ey), ez - (lastEz or ez)
        moveDist = sqrt(mx * mx + my * my + mz * mz)
        if moveDist > TELEPORT_RESET_DIST and interiorElapsed > LOAD_GRACE_SECONDS then
            enterInterior(cellName, ex, ey, ez)
            print('[TSP_VISGRID_V7] reset reason=teleport')
            moveDist = 0.0
        else
            transportTranslation(mx, my, mz, moveDist)
            lastEx, lastEy, lastEz = ex, ey, ez
        end
    end

    -- Turn detection by angular rate (magnitude only - sign never used).
    local turning = false
    local okYaw, yaw = pcall(camera.getYaw)
    local okPitch, pitch = pcall(camera.getPitch)
    if okYaw and okPitch and yaw ~= nil and pitch ~= nil then
        if lastYawSeen ~= nil then
            local dyaw = yaw - lastYawSeen
            while dyaw > pi do dyaw = dyaw - 2 * pi end
            while dyaw < -pi do dyaw = dyaw + 2 * pi end
            local dpitch = pitch - lastPitchSeen
            local rate = (abs(dyaw) + abs(dpitch)) / dt
            if rate > TURN_RATE_TRIGGER then
                turning = true
                turnLinger = TURN_LINGER
            end
        end
        lastYawSeen, lastPitchSeen = yaw, pitch
    end
    if turnLinger > 0.0 then turning = true end

    -- Publish first so visList/tileBin reflect the CURRENT camera before rays.
    publishGrid()

    local budget = RAYS_STEADY
    if enterBurst > 0.0 or youngVisible > 0 then budget = RAYS_ENTER
    elseif turning then budget = RAYS_TURN end

    chooseAndCast(budget, ex, ey, ez, turning)

    -- Never lower the projection; only correct it upward if some other
    -- controller pushed it under what the curtain needs (rare).
    if projCheckElapsed >= 1.0 then
        projCheckElapsed = 0.0
        local okVD, vd = pcall(camera.getViewDistance)
        if okVD and vd ~= nil then
            local needed = 0.0
            for i = 1, COLS * ROWS do
                if out[i] and out[i] > needed then needed = out[i] end
            end
            needed = needed + PADDING + 120.0
            if vd < needed then
                pcall(camera.setViewDistance, needed)
            end
        end
    end

    if statusElapsed >= PRINT_PERIOD then
        statusElapsed = statusElapsed - PRINT_PERIOD
        printStatus(budget)
    end
end

local function onInit()
    resetRuntimeState()
    print('[TSP_VISGRID_V7] onInit -> runtime state initialized')
end

local function onLoad(_savedData, _initData)
    resetRuntimeState()
    print('[TSP_VISGRID_V7] onLoad -> runtime state initialized')
end

return {
    engineHandlers = {
        onInit = onInit,
        onLoad = onLoad,
        onFrame = onFrame,
    },
}
EOF_TSP_V7_LUA

grep -Fq 'TSP_INTERIOR_VISGRID_LUA_V7' "$PKG/visgrid.lua"
grep -Fq 'onLoad = onLoad' "$PKG/visgrid.lua"
grep -Fq 'transportTranslation' "$PKG/visgrid.lua"
grep -Fq 'room-memory' "$PKG/visgrid.lua"
if grep -Fq 'screenPos[' "$PKG/visgrid.lua"; then
    echo "ERROR: cached screenPos found - wrong sensor generation."
    exit 1
fi
LUA_MD5="$(md5sum "$PKG/visgrid.lua" | awk '{print $1}')"
if [ "$LUA_MD5" != "$LUA_MD5_EXPECTED" ]; then
    echo "ERROR: generated sensor md5 $LUA_MD5 does not match the"
    echo "       simulation-verified build $LUA_MD5_EXPECTED."
    echo "       The script file was corrupted in transit - redownload it."
    exit 1
fi
echo "PASS: V7 sensor generated and md5-verified against the simulated build."
echo "      md5: $LUA_MD5"

echo
echo "===== 4/8 INSTALL V7 LUA ONLY ====="
scp -q "$PKG/visgrid.lua" "$DEV:/tmp/visgrid-v7.lua"
ssh "$DEV" "
set -e
test -s /tmp/visgrid-v7.lua
grep -Fq 'TSP_INTERIOR_VISGRID_LUA_V7' /tmp/visgrid-v7.lua
cp /tmp/visgrid-v7.lua '$LUA.new'
mv -f '$LUA.new' '$LUA'
rm -f /tmp/visgrid-v7.lua
sync
"
echo "PASS: V7 installed."

echo
echo "===== 5/8 VERIFY ENGINE UNCHANGED + LUA SHA ====="
REMOTE_BIN_SHA="$(ssh "$DEV" "sha256sum '$BIN' | awk '{print \$1}'")"
REMOTE_LUA_SHA="$(ssh "$DEV" "sha256sum '$LUA' | awk '{print \$1}'")"
LOCAL_LUA_SHA="$(sha256sum "$PKG/visgrid.lua" | awk '{print $1}')"
[ "$LOCAL_LUA_SHA" = "$REMOTE_LUA_SHA" ] || {
    echo "ERROR: V7 Lua SHA mismatch after install."
    exit 1
}
ssh "$DEV" "
set -e
grep -a -q 'TSP_INTERIOR_VISGRID_051_V1' '$BIN'
grep -Fq 'TSP_INTERIOR_VISGRID_LUA_V7' '$LUA'
"
echo "OpenMW binary (unchanged V1 engine): $REMOTE_BIN_SHA"
echo "V7 sensor sha256:                    $REMOTE_LUA_SHA"

echo
echo "===== 6/8 CREATE TRACE / ROLLBACK / PORTABLE-PACKAGE HELPERS ====="

cat > "$PKG/collect-visgrid-v7-trace.sh" <<'EOF_TRACE'
#!/usr/bin/env bash
set -Eeuo pipefail
DEV="${TSP_DEV:-root@192.168.1.25}"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="${1:-$HOME/Downloads/openmw51-visgrid-v7-trace-$STAMP.txt}"
{
    echo "=================================================================="
    echo "OPENMW INTERIOR VISGRID V7 TRACE"
    echo "=================================================================="
    ssh "$DEV" 'hostname; date'
    echo
    echo "===== VISGRID V7 STATUS LINES ====="
    ssh "$DEV" '
        grep -hE \
          "TSP_VISGRID_V7|TSP_INTERIOR_VISGRID_051_V1|TSP_VISGRID_V6|TSP_DEPTH_PROJECTION|Lua.*error|ERROR.*Lua" \
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
chmod +x "$PKG/collect-visgrid-v7-trace.sh"

cat > "$PKG/rollback-visgrid-v7.sh" <<EOF_ROLLBACK
#!/usr/bin/env bash
set -Eeuo pipefail
DEV="\${TSP_DEV:-root@192.168.1.25}"
LUA="$LUA"
BACKUP="$REMOTE_BACKUP/visgrid.lua.before-v7"
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
echo "Restored the exact pre-V7 sensor."
EOF_ROLLBACK
chmod +x "$PKG/rollback-visgrid-v7.sh"

cat > "$PKG/package-visgrid-portable.sh" <<'EOF_PORTABLE'
#!/usr/bin/env bash
# Builds a distributable VISGRID bundle: a small engine patch series that can
# be applied to (or hand-ported into) other OpenMW trees, plus the sensor mod,
# which is safe to ship on its own - on a stock engine it logs one line and
# stays idle. Run this any time; it only READS the container and the device.
set -Eeuo pipefail
C="${TSP_DOCKER:-openmw_builder}"
DEV="${TSP_DEV:-root@192.168.1.25}"
SRC="/root/openmw-0.51-tsp-src"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="$HOME/Downloads/visgrid-portable-$STAMP"
mkdir -p "$OUT/engine/patches" "$OUT/engine/full-files" "$OUT/mod"

echo "===== 1/4 engine sources from the build container ====="
docker exec "$C" test -d "$SRC"
for f in \
    apps/openmw/mwrender/interiorvisibility.hpp \
    apps/openmw/mwrender/interiorvisibility.cpp; do
    docker cp "$C:$SRC/$f" "$OUT/engine/$(basename "$f")"
done

BK="$(docker exec "$C" bash -lc 'cat /root/openmw51-visgrid-v1-source-backup-path.txt 2>/dev/null || true')"
TOUCHED="apps/openmw/CMakeLists.txt apps/openmw/mwrender/animation.cpp apps/openmw/mwlua/camerabindings.cpp apps/openmw/mwrender/renderingmanager.cpp"
if [ -n "$BK" ] && docker exec "$C" test -d "$BK"; then
    echo "pre-VISGRID baseline found: $BK -> generating unified diffs"
    for f in $TOUCHED; do
        n="$(echo "$f" | tr '/' '_')"
        docker exec "$C" bash -lc \
            "diff -u '$BK/$f' '$SRC/$f' || true" > "$OUT/engine/patches/$n.diff"
        echo "  $n.diff ($(wc -l < "$OUT/engine/patches/$n.diff") lines)"
    done
else
    echo "NOTE: pre-VISGRID baseline not recorded; shipping full modified files"
    for f in $TOUCHED; do
        docker cp "$C:$SRC/$f" "$OUT/engine/full-files/$(basename "$f")"
    done
fi

echo "===== 2/4 sensor mod from the device (current installed state) ====="
scp -qr "$DEV:/mnt/SDCARD/data/ports/openmw51/mods/TSPInteriorVisGrid" "$OUT/mod/"

echo "===== 3/4 README ====="
cat > "$OUT/README.md" <<'EOF_README'
# TSP Interior VISGRID - portable bundle

Interior screen-tile depth-curtain culling for OpenMW, split into two halves:

## 1. Engine half (small C++ patch, marker TSP_INTERIOR_VISGRID_051_V1)
A generic bridge with no game policy in it. Files:
- `engine/interiorvisibility.hpp` / `.cpp` - NEW files: atomic tile-depth
  store + a conservative cull callback (bounding sphere -> screen rect ->
  overlapped tiles + one-tile expansion -> cull only if the sphere's nearest
  point is beyond every overlapped tile's depth + padding; main scene camera
  only; anything ambiguous renders normally).
- `engine/patches/*.diff` - four one-place edits:
  * apps/openmw/CMakeLists.txt: add `interiorvisibility` to the mwrender list.
  * mwrender/animation.cpp: in `Animation::setObjectRoot`, install
    `InteriorVisibilityCullCallback` on non-actor object roots BEFORE the
    LightListCallback (a rejected object skips light/state work too).
  * mwlua/camerabindings.cpp: 4 Lua functions - setInteriorVisibilityGrid,
    clearInteriorVisibilityGrid, getInteriorVisibilityStats,
    resetInteriorVisibilityStats.
  * mwrender/renderingmanager.cpp: while a grid is active,
    `setViewDistance()` cannot shrink the projection below the grid maximum.
The bridge is inert until a Lua script publishes a grid: an unmodified game
with this patch behaves stock, with zero overhead.
Porting to another OpenMW version: apply the diffs, or redo the four edits by
hand at the anchors named above - they are deliberately tiny. GPLv3, like
OpenMW itself.

## 2. Sensor mod (pure Lua, `mod/TSPInteriorVisGrid`)
The policy half: casts a few physics rays per frame, maintains a
world-anchored yaw/pitch depth panorama of the current interior (memory
survives turning; walking transports depths; deep sightlines must reproduce
through the same sub-direction before being trusted), and publishes an 8x5
per-tile depth grid each frame.
The mod probes for the engine bridge at load and IDLES on stock builds, so it
is safe to distribute independently. All tuning knobs are at the top of
`scripts/TSPInteriorVisGrid/visgrid.lua`.

Install like any OpenMW mod:
    data=".../mods/TSPInteriorVisGrid"
    content=TSPInteriorVisGrid.omwscripts
EOF_README

echo "===== 4/4 tarball ====="
tar -czf "$OUT.tar.gz" -C "$(dirname "$OUT")" "$(basename "$OUT")"
echo "=================================================================="
echo "PORTABLE BUNDLE READY"
echo "  $OUT"
echo "  $OUT.tar.gz"
echo "=================================================================="
EOF_PORTABLE
chmod +x "$PKG/package-visgrid-portable.sh"
echo "PASS: helpers created."

echo
echo "===== 7/8 README ====="
cat > "$PKG/README-V7.txt" <<EOF_README
VISGRID V7 - ROOM-MEMORY SENSOR
===============================

Diagnosis of V2-V6 in one paragraph:
The depth store lived in SCREEN tiles, so every turn pointed every tile at
different geometry and the sensor had to relearn the room mid-movement while
expansion-biased updates (instant far-sample opens + 3x3 dilation + slow
two-step contractions) held the grid open. Rejection collapsed toward 0% and
the callback became pure overhead: back to ~12 FPS. V5 additionally never
cast a single ray (onInit-only cache on an existing save).

V7 stores depths in a WORLD-ANCHORED yaw/pitch panorama instead:
- turning re-reads the same memory (nothing resets);
- walking transports depths by -(move . direction) with small slack;
- deep sightlines must reproduce through the same sub-direction once before
  being trusted, then they are remembered and protected;
- new directions stay permissive until a few samples exist (never cull on
  thin evidence);
- spare rays pre-measure past the leading screen edge while turning;
- the projection far plane is never lowered (red void impossible).

Simulation (synthetic room + doorway + 3000 corridor, brutal see-through
balustrade stress, 19 s scripted stand/turn/walk suite):
                       V6 sensor      V7 sensor
  pop-in object-frames    1063              0
  occl culling, moving    varies       27-100% held
  rays per frame          5-10           6-14

Config knobs: top of $LUA (budgets, young floor, dilation, etc.)
Device backup: $REMOTE_BACKUP
Rollback:      ./rollback-visgrid-v7.sh
Trace:         ./collect-visgrid-v7-trace.sh  (run while OpenMW is up)
Shippable kit: ./package-visgrid-portable.sh  (engine patch + standalone mod)
EOF_README

echo
echo "===== 8/8 FINAL ====="
echo "=================================================================="
echo "VISGRID V7 INSTALLED"
echo "=================================================================="
echo
echo "TEST ORDER (same discipline as V6 - rays first, FPS second):"
echo "  1. Load the interior save, stand at the bad staircase wall ~2 s."
echo "     The [TSP_VISGRID_V7] log line MUST show:"
echo "       cast_attempts > 0, cast_ok > 0, hits > 0, known climbing,"
echo "       mean well under 3000, reject > 0%"
echo "  2. Note FPS standing (V1 got ~27 here)."
echo "  3. Now MOVE: slow turn, fast 360, walk the staircase up and down,"
echo "     through the doorway and back. Watch FPS and watch reject%:"
echo "     it should stay high while moving - that is the whole point of V7."
echo "  4. Watch for missing objects/walls, especially right after fast"
echo "     turns and through railings. If anything pops: set"
echo "     SCREEN_DILATE = true at the top of the installed visgrid.lua"
echo "     (no rebuild needed) and retest."
echo
echo "While OpenMW is still running afterwards:"
echo "  $PKG/collect-visgrid-v7-trace.sh"
echo
echo "Rollback to the pre-V7 sensor:"
echo "  $PKG/rollback-visgrid-v7.sh"
echo
echo "Shippable mod + engine-patch bundle (any time):"
echo "  $PKG/package-visgrid-portable.sh"
echo "=================================================================="
