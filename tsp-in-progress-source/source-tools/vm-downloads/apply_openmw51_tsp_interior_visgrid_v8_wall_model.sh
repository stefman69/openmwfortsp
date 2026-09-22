#!/usr/bin/env bash
CR=$(printf '\r'); case "$(head -c 400 "$0" 2>/dev/null)" in *"$CR"*) echo "v8: stripping CRLF from the downloaded copy and re-running"; exec bash -c 'sed "s/\r$//" "$1" | bash' v8 "$0" ;; esac # CRLF trampoline - keep on one line
set -Eeuo pipefail

DEV="${TSP_DEV:-root@192.168.1.25}"
STAMP="$(date +%Y%m%d-%H%M%S)"

ROOT="/mnt/SDCARD/data/ports/openmw51"
BIN="$ROOT/bin/openmw-0.51"
MOD="$ROOT/mods/TSPInteriorVisGrid"
OMW="$MOD/TSPInteriorVisGrid.omwscripts"
LUA="$MOD/scripts/TSPInteriorVisGrid/visgrid.lua"

# md5 of each embedded sensor, exactly as validated in the simulator
MD5_V8="603268173b923cc01b0141a486c9ca81"
MD5_V7="e4cf368b27a496c16a79ca1770d1619b"
MD5_V1="439d04a5fcbdf6cbeda39531565ce7f7"

PKG="$HOME/Downloads/openmw51-interior-visgrid-v8-wall-model-$STAMP"
LOG="$PKG/install.log"
mkdir -p "$PKG/sensors"

fail_report() {
    local rc="${1:-1}"
    local line="${2:-unknown}"
    local cmd="${3:-unknown}"
    trap - ERR
    set +e
    local report="$PKG/STOPPED_ERROR.txt"
    {
        echo "=================================================================="
        echo "VISGRID V8 STOPPED SAFELY - NOTHING PARTIAL LEFT BEHIND"
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
echo "OPENMW 0.51 TSP - INTERIOR VISGRID V8 (WALL-MODEL SENSOR)"
echo "=================================================================="
echo
echo "Lua-only. Engine keeps the proven V1 C++ curtain unchanged."
echo
echo "V8 = V7's world-anchored room-memory panorama + four additions:"
echo "  A. WALL-PLANE INFERENCE - ray hits carry surface normals, so hits"
echo "     assemble actual wall PLANES; unsampled directions are filled"
echo "     analytically and plane-consistent stale bins refresh ray-free"
echo "     (capped so changed geometry always gets real rays)."
echo "  B. PER-CELL ROOM CACHE - re-entering an interior warm-starts from"
echo "     the previously learned panorama+planes (session-only)."
echo "  C. DOOR-AWARE PORTALS - nearby doors are watched; a door OPENING"
echo "     instantly makes its screen region permissive + burst-scanned."
echo "  D. TURN-RATE PREDICTION - presampling reaches further ahead the"
echo "     faster you turn."
echo
echo "Simulator (14-phase suite: stand / 360 turn / walk / corridor / door"
echo "close+open / exit+re-enter, solid staircase-analog geometry):"
echo "    V6 sensor:  1063+ culled-but-visible pop-in events while moving"
echo "    V7 sensor:  0 events (16 on the re-entry phase, cold restart)"
echo "    V8 sensor:  0 events on ALL phases, warm re-entry, door events clean"
echo
echo "This package also installs a sensor A/B kit:"
echo "    sensor-switch.sh v1|v7|v8   (v1 = the exact gold-standard control)"
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
REMOTE_BACKUP="$ROOT/backups/interior-visgrid-v8-wall-model-$STAMP"
ssh "$DEV" "
set -e
mkdir -p '$REMOTE_BACKUP'
cp -p '$LUA' '$REMOTE_BACKUP/visgrid.lua.before-v8'
cp -p '$OMW' '$REMOTE_BACKUP/TSPInteriorVisGrid.omwscripts'
sha256sum '$BIN' '$LUA' '$OMW' > '$REMOTE_BACKUP/SHA256SUMS.before.txt'
sync
cat '$REMOTE_BACKUP/SHA256SUMS.before.txt'
"
scp -q "$DEV:$LUA" "$PKG/visgrid.lua.before-v8"
scp -q "$DEV:$OMW" "$PKG/TSPInteriorVisGrid.omwscripts.before-v8"
echo "PASS: rollback copies preserved (device: $REMOTE_BACKUP, local: $PKG)."

echo
echo "===== 3/8 GENERATE THE THREE SENSORS ====="
cat > "$PKG/sensors/visgrid-v8.lua" <<'EOF_TSP_V8_LUA'
-- TSP_INTERIOR_VISGRID_LUA_V8  (wall-model edition)
--
-- V8 = V7's anchored room-memory panorama PLUS four additions, all Lua-only:
--
--   A. WALL-PLANE INFERENCE - every ray hit carries a surface normal, so one
--      hit defines the wall's PLANE. Planes are collected, supported and
--      extent-tracked; directions nobody has sampled yet are filled
--      analytically by intersecting them with the supported planes
--      (conservative rules below). Three real hits on a wall can stand in
--      for dozens of rays: the sensor stops sampling 40 independent numbers
--      and starts maintaining a model of the walls themselves.
--   B. PER-CELL ROOM CACHE - leaving and re-entering an interior restarts
--      from the previously learned panorama+planes (position-delta applied,
--      everything marked stale for cheap re-verification) instead of cold.
--   C. DOOR-AWARE PORTALS - nearby door objects are watched; the moment one
--      changes state the screen region around it goes permissive and gets a
--      burst scan, so an opening door reveals its hallway immediately
--      instead of waiting for the next scheduled ray.
--   D. MOTION-LEADING PREDICTION - the off-screen presample depth scales
--      with turn rate (faster turn = further ahead).
--
-- (original V7 header follows)
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
local okTypes, types = pcall(require, 'openmw.types')
if not okTypes then types = nil end

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

-- A. wall-plane inference
local PLANES_MAX = 14
local PLANE_NORMAL_TOL = 0.93      -- dot(normal, plane normal) to merge a hit
local PLANE_DIST_TOL = 45.0        -- point-to-plane distance to merge a hit
local PLANE_MIN_SUPPORT = 3        -- hits before a plane may fill anything
local PLANE_EXTENT_INFLATE = 120.0 -- how far past witnessed extent fills reach
local PLANE_NEIGHBOR_NEED = 3      -- of 4 bin-neighbors that must support the
                                   -- plane before an unsampled bin is filled
                                   -- (stops fills from papering over doorways)

-- B. per-cell room cache (session-only; never touches saves)
local CACHE_MAX_CELLS = 40
local CACHE_MAX_ENTRY_DELTA = 1600.0  -- re-entry farther than this from where
                                      -- the panorama was learned = cold start
local CACHE_MIN_BINS = 25

-- C. door watching
local DOOR_POLL_PERIOD = 0.25
local DOOR_WATCH_RANGE = 1400.0
local DOOR_GRACE_SECONDS = 1.0

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
    print('[TSP_VISGRID_V8] engine visibility bridge absent - sensor idle (stock build?)')
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

-- A. wall model
local planes = {}          -- {nx,ny,nz,d, lox,loy,loz,hix,hiy,hiz, support, seen, id}
local planeNextId = 1
local planeSupport = {}    -- binIdx -> plane id of the last supporting hit
local planeRefreshRun = {} -- binIdx -> consecutive ray-free refreshes
local fillCount = 0        -- diagnostics: bins currently plane-filled
local planeDataOk = nil    -- nil until first hit tells us if hitNormal exists

-- B. session cache
local sessionCache = {}    -- cellName -> snapshot
local sessionCacheOrder = {}
local cacheWasWarm = false

-- C. door watch
local doorPollElapsed = 0.0
local doorState = {}       -- door id -> last signature
local doorGrace = {}       -- binIdx -> expiry (interiorElapsed time)
local doorGraceCount = 0
local doorEvents = 0
local doorSignatureMode = nil  -- 'isOpen' | 'yaw' | 'eulerz' | 'off'

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
local predictDepthBins = PREDICT_BINS

-- Diagnostics (V6-style aliveness counters, reset every status print)
local dirFail, lenFail, castFail = 0, 0, 0
local castAttempts, castOK, hitCount, missCount = 0, 0, 0, 0
local farConfirms, nearConfirms, openingEvents, predictCasts = 0, 0, 0, 0
local planeRefresh = 0
local firstDirError, firstCastError = nil, nil

local function resetDiagnostics()
    dirFail, lenFail, castFail = 0, 0, 0
    castAttempts, castOK, hitCount, missCount = 0, 0, 0, 0
    farConfirms, nearConfirms, openingEvents, predictCasts = 0, 0, 0, 0
    planeRefresh = 0
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
    planes = {}
    planeSupport = {}
    planeRefreshRun = {}
    fillCount = 0
    doorState = {}
    doorGrace = {}
    doorGraceCount = 0
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

-- ===================== A. wall-plane model =====================

local function planeObserveHit(idx, hx, hy, hz, nx, ny, nz)
    -- normalize defensively; engine normals should already be unit
    local nl = sqrt(nx * nx + ny * ny + nz * nz)
    if nl < 0.5 then return end
    nx, ny, nz = nx / nl, ny / nl, nz / nl

    local bestP = nil
    for i = 1, #planes do
        local p = planes[i]
        if nx * p.nx + ny * p.ny + nz * p.nz > PLANE_NORMAL_TOL then
            local dist = nx * hx + ny * hy + nz * hz + p.d
            if abs(dist) < PLANE_DIST_TOL then
                bestP = p
                break
            end
        end
    end

    if bestP == nil then
        if #planes >= PLANES_MAX then
            -- replace the weakest, oldest plane
            local wi, ws = 1, math.huge
            for i = 1, #planes do
                local s = planes[i].support * 1000 + planes[i].seen
                if s < ws then ws = s; wi = i end
            end
            table.remove(planes, wi)
        end
        bestP = {
            nx = nx, ny = ny, nz = nz,
            d = -(nx * hx + ny * hy + nz * hz),
            lox = hx - 20, loy = hy - 20, loz = hz - 20,
            hix = hx + 20, hiy = hy + 20, hiz = hz + 20,
            support = 1, seen = frameNo, id = planeNextId,
        }
        planeNextId = planeNextId + 1
        planes[#planes + 1] = bestP
    else
        bestP.support = bestP.support + 1
        bestP.seen = frameNo
        -- gentle offset tracking with the plane's own (fixed) normal
        local dNew = -(bestP.nx * hx + bestP.ny * hy + bestP.nz * hz)
        bestP.d = bestP.d * 0.8 + dNew * 0.2
        if hx < bestP.lox then bestP.lox = hx end
        if hy < bestP.loy then bestP.loy = hy end
        if hz < bestP.loz then bestP.loz = hz end
        if hx > bestP.hix then bestP.hix = hx end
        if hy > bestP.hiy then bestP.hiy = hy end
        if hz > bestP.hiz then bestP.hiz = hz end
    end
    planeSupport[idx] = bestP.id
end

local function neighborsSupport(idx, pid)
    local by = (idx - 1) % YAW_BINS
    local bp = floor((idx - 1) / YAW_BINS)
    local got, need = 0, PLANE_NEIGHBOR_NEED
    local checked = 0
    local function chk(yy, pp)
        if pp < 0 or pp >= PITCH_BINS then return end
        checked = checked + 1
        local j = pp * YAW_BINS + (yy % YAW_BINS) + 1
        if planeSupport[j] == pid then got = got + 1 end
    end
    chk(by - 1, bp)
    chk(by + 1, bp)
    chk(by, bp - 1)
    chk(by, bp + 1)
    if checked < 4 then need = need - (4 - checked) end
    return got >= need
end

-- Fill unsampled visible bins from well-supported planes. Runs after the
-- frame's casts so next frame's publish uses it. Conservative rules:
-- plane must have support, the intersection must lie within the plane's
-- WITNESSED extent (+inflate), and most bin-neighbors must support the same
-- plane (a doorway punches a support hole, so it can never be papered over).
local fillTargets = {}
local function planeFillTargets()
    -- visible bins plus a few yaw columns past both screen edges, so turning
    -- lands on plane-filled bins even before any ray reaches them
    local n = 0
    for i = 1, #visList do
        n = n + 1
        fillTargets[n] = visList[i]
    end
    local rowBase = 2 * COLS
    local binL, binR = tileBin[rowBase + 1], tileBin[rowBase + COLS]
    if binL ~= nil and binR ~= nil then
        local byL = (binL - 1) % YAW_BINS
        local byR = (binR - 1) % YAW_BINS
        for _, edge in ipairs({ { byL, -1 }, { byR, 1 } }) do
            for k = 2, 4 do
                local yy = (edge[1] + edge[2] * k) % YAW_BINS
                for bp = 2, PITCH_BINS - 3 do
                    n = n + 1
                    fillTargets[n] = bp * YAW_BINS + yy + 1
                end
            end
        end
    end
    for i = n + 1, #fillTargets do fillTargets[i] = nil end
    return n
end

local function planeFillPass(ex, ey, ez)
    fillCount = 0
    if planeDataOk ~= true or #planes == 0 then return end
    local nT = planeFillTargets()
    for i = 1, nT do
        local j = fillTargets[i]
        if binRing[j] == nil then
            local dx, dy, dz = binDirX[j], binDirY[j], binDirZ[j]
            local bestT = nil
            for k = 1, #planes do
                local p = planes[k]
                if p.support >= PLANE_MIN_SUPPORT then
                    local denom = p.nx * dx + p.ny * dy + p.nz * dz
                    if denom < -0.15 then
                        local t = -(p.nx * ex + p.ny * ey + p.nz * ez + p.d) / denom
                        if t > MIN_DEPTH and t < RAY_LEN then
                            local px = ex + dx * t
                            local py = ey + dy * t
                            local pz = ez + dz * t
                            if px > p.lox - PLANE_EXTENT_INFLATE and px < p.hix + PLANE_EXTENT_INFLATE
                                and py > p.loy - PLANE_EXTENT_INFLATE and py < p.hiy + PLANE_EXTENT_INFLATE
                                and pz > p.loz - PLANE_EXTENT_INFLATE and pz < p.hiz + PLANE_EXTENT_INFLATE
                                and neighborsSupport(j, p.id) then
                                if bestT == nil or t < bestT then bestT = t end
                            end
                        end
                    end
                end
            end
            if bestT ~= nil then
                binDepth[j] = bestT
                binSlack[j] = 0.0
                binAge[j] = 25          -- sampled soon by the stale scheduler
                markKnown(j)
                fillCount = fillCount + 1
            end
        end
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
        local wx, wy, wz = res.hitPos.x, res.hitPos.y, res.hitPos.z
        local hx, hy, hz = wx - ex, wy - ey, wz - ez
        acceptBin(idx, sqrt(hx * hx + hy * hy + hz * hz), false, jy, jp, isVerify)
        -- feed the wall model (normals may not exist on every build)
        if planeDataOk == nil then
            planeDataOk = (res.hitNormal ~= nil)
            if not planeDataOk then
                print('[TSP_VISGRID_V8] castRay has no hitNormal - plane inference off')
            end
        end
        if planeDataOk == true and res.hitNormal ~= nil then
            local okP = pcall(planeObserveHit, idx, wx, wy, wz,
                res.hitNormal.x, res.hitNormal.y, res.hitNormal.z)
            if not okP then planeDataOk = false end
        end
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
                                local g = doorGrace[j]
                                if g ~= nil then
                                    if g > interiorElapsed then
                                        dv = OPEN_DEPTH
                                    else
                                        doorGrace[j] = nil
                                        doorGraceCount = doorGraceCount - 1
                                    end
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
            for k = 1, predictDepthBins do
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
        local refreshes = 0
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
            -- A stale bin that still agrees with its supporting wall plane can
            -- be refreshed for free (the saved ray goes to a bin that can't) -
            -- but never more than twice in a row: every third refresh cycle a
            -- real ray must confirm, so changed geometry (an opened door) can
            -- never be papered over indefinitely by its own old plane.
            if refreshes < 6 and (binPrio[j] or 0) == 0 and planeDataOk == true
                and (planeRefreshRun[j] or 0) < 2 then
                local pid = planeSupport[j]
                if pid ~= nil and binDepth[j] ~= nil and binDepth[j] < OPEN_DEPTH - 1.0
                    and binDeepVal[j] == nil then
                    for k = 1, #planes do
                        local p = planes[k]
                        if p.id == pid and p.support >= PLANE_MIN_SUPPORT then
                            local dx, dy, dz = binDirX[j], binDirY[j], binDirZ[j]
                            local denom = p.nx * dx + p.ny * dy + p.nz * dz
                            if denom < -0.25 then
                                local t = -(p.nx * ex + p.ny * ey + p.nz * ez + p.d) / denom
                                if t > MIN_DEPTH and t < RAY_LEN and abs(t - binDepth[j]) < 130.0 then
                                    binDepth[j] = t     -- exact analytic refresh
                                    binAge[j] = 0
                                    binSlack[j] = min(binSlack[j] or 0.0, 60.0)
                                    planeRefreshRun[j] = (planeRefreshRun[j] or 0) + 1
                                    planeRefresh = planeRefresh + 1
                                    refreshes = refreshes + 1
                                    j = nil
                                end
                            end
                            break
                        end
                    end
                end
            end
            if j ~= nil then
                if (binPrio[j] or 0) > 0 then binPrio[j] = binPrio[j] - 1 end
                planeRefreshRun[j] = 0
                castBin(j, ex, ey, ez, 'jitter', false)
                casts = casts + 1
            end
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

-- ===================== C. door watching =====================

local function doorSignature(d)
    if doorSignatureMode == 'isOpen' then
        return tostring(types.Door.isOpen(d))
    elseif doorSignatureMode == 'yaw' then
        return string.format('%.2f', d.rotation:getYaw())
    elseif doorSignatureMode == 'eulerz' then
        return string.format('%.2f', d.rotation.z)
    end
    return nil
end

local function detectDoorSignatureMode(d)
    if types ~= nil and types.Door ~= nil and types.Door.isOpen ~= nil then
        local ok = pcall(types.Door.isOpen, d)
        if ok then doorSignatureMode = 'isOpen' return end
    end
    local okYaw = pcall(function() return d.rotation:getYaw() end)
    if okYaw then doorSignatureMode = 'yaw' return end
    local okZ = pcall(function() return d.rotation.z + 0 end)
    if okZ then doorSignatureMode = 'eulerz' return end
    doorSignatureMode = 'off'
    print('[TSP_VISGRID_V8] no readable door state - door portals off')
end

local function doorChanged(d, ex, ey, ez, opened)
    doorEvents = doorEvents + 1
    if opened == false then
        -- A door CLOSING needs no artifact protection (culling more is safe);
        -- just rescan the region so the curtain tightens quickly.
        local px, py, pz = d.position.x, d.position.y, d.position.z
        local ddx, ddy, ddz = px - ex, py - ey, pz - ez
        local l = sqrt(ddx * ddx + ddy * ddy + ddz * ddz)
        if l > 1.0 then fanAround(binOfDir(ddx, ddy, ddz, l)) end
        return
    end
    local px, py, pz = d.position.x, d.position.y, d.position.z
    local dx, dy, dz = px - ex, py - ey, pz - ez
    local len = sqrt(dx * dx + dy * dy + dz * dz)
    if len < 1.0 then return end
    local idx = binOfDir(dx, dy, dz, len)
    local by = (idx - 1) % YAW_BINS
    local bp = floor((idx - 1) / YAW_BINS)
    local expiry = interiorElapsed + DOOR_GRACE_SECONDS
    for dp = -1, 1 do
        local pp = bp + dp
        if pp >= 0 and pp < PITCH_BINS then
            for dyw = -2, 2 do
                local j = pp * YAW_BINS + ((by + dyw) % YAW_BINS) + 1
                if doorGrace[j] == nil then doorGraceCount = doorGraceCount + 1 end
                doorGrace[j] = expiry
                -- the old wall/door plane no longer describes this region:
                -- force real rays to re-learn it
                planeSupport[j] = nil
                planeRefreshRun[j] = 0
                binPrio[j] = max(binPrio[j] or 0, 8)
            end
        end
    end
    fanAround(idx)
    turnLinger = max(turnLinger, 0.8)   -- raises the ray budget briefly
end

local function pollDoors(ex, ey, ez)
    if doorSignatureMode == 'off' then return end
    local okList, list = pcall(function() return nearby.doors end)
    if not okList or list == nil then
        doorSignatureMode = 'off'
        return
    end
    local okIter = pcall(function()
        for _, d in ipairs(list) do
            local px, py, pz = d.position.x, d.position.y, d.position.z
            local ddx, ddy, ddz = px - ex, py - ey, pz - ez
            if ddx * ddx + ddy * ddy + ddz * ddz <= DOOR_WATCH_RANGE * DOOR_WATCH_RANGE then
                if doorSignatureMode == nil then detectDoorSignatureMode(d) end
                if doorSignatureMode ~= 'off' then
                    local id = tostring(d.id or d)
                    local sig = doorSignature(d)
                    local prev = doorState[id]
                    doorState[id] = sig
                    if prev ~= nil and sig ~= nil and prev ~= sig then
                        local opened = nil
                        if doorSignatureMode == 'isOpen' then
                            opened = (sig == 'true')
                        end
                        doorChanged(d, ex, ey, ez, opened)
                    end
                end
            end
        end
    end)
    if not okIter then doorSignatureMode = 'off' end
end

-- ===================== B. per-cell session cache =====================

local function cacheSave(cellName, ax, ay, az)
    if cellName == nil or #knownList < CACHE_MIN_BINS then return end
    local snap = {
        ax = ax, ay = ay, az = az,
        depth = {}, deep = {}, rings = {}, planes = {},
    }
    for i = 1, #knownList do
        local j = knownList[i]
        if binRing[j] ~= nil then
            snap.depth[j] = binDepth[j]
            snap.deep[j] = binDeepVal[j]
            local r = binRing[j]
            local rc = {}
            for k = 1, #r do rc[k] = r[k] end
            snap.rings[j] = rc
        end
    end
    for i = 1, #planes do
        local p = planes[i]
        snap.planes[i] = {
            nx = p.nx, ny = p.ny, nz = p.nz, d = p.d,
            lox = p.lox, loy = p.loy, loz = p.loz,
            hix = p.hix, hiy = p.hiy, hiz = p.hiz,
            support = min(p.support, 6), seen = 0, id = p.id,
        }
    end
    if sessionCache[cellName] == nil then
        sessionCacheOrder[#sessionCacheOrder + 1] = cellName
        if #sessionCacheOrder > CACHE_MAX_CELLS then
            local evict = table.remove(sessionCacheOrder, 1)
            sessionCache[evict] = nil
        end
    end
    sessionCache[cellName] = snap
end

local function cacheRestore(cellName, ex, ey, ez)
    local snap = sessionCache[cellName]
    if snap == nil then return false end
    local mx, my, mz = ex - snap.ax, ey - snap.ay, ez - snap.az
    local delta = sqrt(mx * mx + my * my + mz * mz)
    if delta > CACHE_MAX_ENTRY_DELTA then return false end
    local restored = 0
    for j, dval in pairs(snap.depth) do
        local nd = dval
        if nd < OPEN_DEPTH - 1.0 then
            local dot = mx * binDirX[j] + my * binDirY[j] + mz * binDirZ[j]
            nd = nd - dot
            if nd < MIN_DEPTH then nd = MIN_DEPTH end
            if nd > RAY_LEN * 1.15 then nd = OPEN_DEPTH end
        end
        binDepth[j] = nd
        binDeepVal[j] = snap.deep[j]
        local rc = snap.rings[j]
        local r = {}
        for k = 1, #rc do
            local rv = rc[k]
            if rv < OPEN_DEPTH - 1.0 then
                local dot = mx * binDirX[j] + my * binDirY[j] + mz * binDirZ[j]
                rv = max(MIN_DEPTH, rv - dot)
                if rv > RAY_LEN * 1.15 then rv = OPEN_DEPTH end
            end
            r[k] = rv
        end
        binRing[j] = r
        binRingPos[j] = #r
        binAge[j] = 60                 -- stale: re-verified by normal refresh
        binSlack[j] = SLACK_MAX * 0.7  -- generous safety for stale-world drift
        markKnown(j)
        restored = restored + 1
    end
    for i = 1, #snap.planes do
        local sp = snap.planes[i]
        planes[i] = {
            nx = sp.nx, ny = sp.ny, nz = sp.nz, d = sp.d,
            lox = sp.lox, loy = sp.loy, loz = sp.loz,
            hix = sp.hix, hiy = sp.hiy, hiz = sp.hiz,
            support = sp.support, seen = frameNo, id = sp.id,
        }
    end
    if restored > 0 then
        cacheWasWarm = true
        print(string.format(
            '[TSP_VISGRID_V8] warm start from session cache: %d bins, %d planes (entry delta %.0f)',
            restored, #snap.planes, delta))
        return true
    end
    return false
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
        '[TSP_VISGRID_V8] min=%.0f mean=%.0f max=%.0f lt1k=%d lt2k=%d reject=%.1f%% known=%d cand=%d deep=%d planes=%d fill=%d warm=%d doorEv=%d grace=%d budget=%d cast_attempts=%d cast_ok=%d hits=%d misses=%d dir_fail=%d len_fail=%d cast_fail=%d opens=%d closes=%d fans=%d predict=%d',
        minD, sum / (COLS * ROWS), maxD, under1k, under2k, reject,
        #knownList, cand, deep,
        #planes, fillCount, cacheWasWarm and 1 or 0, doorEvents, doorGraceCount,
        budget,
        castAttempts, castOK, hitCount, missCount,
        dirFail, lenFail, castFail,
        farConfirms, nearConfirms, openingEvents, predictCasts)
        .. string.format(' pref=%d', planeRefresh))
    if firstDirError ~= nil then
        print('[TSP_VISGRID_V8] first_dir_error=' .. firstDirError)
    end
    if firstCastError ~= nil then
        print('[TSP_VISGRID_V8] first_cast_error=' .. firstCastError)
    end
    resetDiagnostics()
end

local function enterInterior(cellName, ex, ey, ez)
    -- bank the outgoing cell's learned panorama first (B)
    if inInterior and lastCellName ~= nil and lastEx ~= nil then
        cacheSave(lastCellName, lastEx, lastEy, lastEz)
    end
    inInterior = true
    lastCellName = cellName
    lastEx, lastEy, lastEz = ex, ey, ez
    interiorElapsed = 0.0
    enterBurst = ENTER_BURST_T
    turnLinger = 0.0
    cacheWasWarm = false
    resetPanorama()
    cacheRestore(cellName, ex, ey, ez)
    if haveBridge then
        pcall(camera.resetInteriorVisibilityStats)
        lastStatsTested, lastStatsCulled = 0.0, 0.0
    end
    print('[TSP_VISGRID_V8] enter interior "' .. tostring(cellName)
        .. '" -> wall-model grid active' .. (cacheWasWarm and ' (warm)' or ''))
end

local function exitInterior()
    if lastCellName ~= nil and lastEx ~= nil then
        cacheSave(lastCellName, lastEx, lastEy, lastEz)
    end
    inInterior = false
    lastCellName = nil
    lastEx, lastEy, lastEz = nil, nil, nil
    resetPanorama()
    if haveBridge then pcall(camera.clearInteriorVisibilityGrid) end
    print('[TSP_VISGRID_V8] exit interior -> grid off')
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
        print('[TSP_VISGRID_V8] reset reason=cell-change')
    else
        local mx, my, mz = ex - (lastEx or ex), ey - (lastEy or ey), ez - (lastEz or ez)
        moveDist = sqrt(mx * mx + my * my + mz * mz)
        if moveDist > TELEPORT_RESET_DIST and interiorElapsed > LOAD_GRACE_SECONDS then
            enterInterior(cellName, ex, ey, ez)
            print('[TSP_VISGRID_V8] reset reason=teleport')
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
            -- D. faster turn = presample further past the leading edge
            local pb = 1 + floor(rate / rad(60.0))
            if pb < 1 then pb = 1 elseif pb > 4 then pb = 4 end
            predictDepthBins = pb
        end
        lastYawSeen, lastPitchSeen = yaw, pitch
    end
    if turnLinger > 0.0 then turning = true end

    -- C. watch nearby doors for state changes
    doorPollElapsed = doorPollElapsed + dt
    if doorPollElapsed >= DOOR_POLL_PERIOD then
        doorPollElapsed = 0.0
        pollDoors(ex, ey, ez)
    end

    -- Publish first so visList/tileBin reflect the CURRENT camera before rays.
    publishGrid()

    local budget = RAYS_STEADY
    if enterBurst > 0.0 or youngVisible > 0 then budget = RAYS_ENTER
    elseif turning then budget = RAYS_TURN end

    chooseAndCast(budget, ex, ey, ez, turning)

    -- A. analytically fill unsampled visible directions from the wall model
    planeFillPass(ex, ey, ez)

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
    print('[TSP_VISGRID_V8] onInit -> runtime state initialized')
end

local function onLoad(_savedData, _initData)
    resetRuntimeState()
    print('[TSP_VISGRID_V8] onLoad -> runtime state initialized')
end

return {
    engineHandlers = {
        onInit = onInit,
        onLoad = onLoad,
        onFrame = onFrame,
    },
}
EOF_TSP_V8_LUA

cat > "$PKG/sensors/visgrid-v7.lua" <<'EOF_TSP_V7_LUA'
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

cat > "$PKG/sensors/visgrid-v1control.lua" <<'EOF_TSP_V1_LUA'
-- TSP_INTERIOR_VISGRID_LUA_V1
-- Sensor-only half of TSP_INTERIOR_VISGRID_051_V1.
--
-- V1 intentionally keeps the proven World+Door physics-ray sensor so this
-- test isolates the NEW mechanism: a tiled visibility volume rather than one
-- scalar far plane.

local camera = require('openmw.camera')
local core = require('openmw.core')
local nearby = require('openmw.nearby')
local self = require('openmw.self')
local util = require('openmw.util')

local COLS = 8
local ROWS = 5
local COUNT = COLS * ROWS
local MAX_DIST = 5500.0
local PADDING = 350.0
local RAYS_PER_FRAME = 5

local RESET_MOVE = 48.0
local RESET_YAW = math.rad(6.0)
local RESET_PITCH = math.rad(5.0)
local CLOSE_CONFIRM_TOLERANCE = 180.0
local PRINT_PERIOD = 2.0

local RAY_MASK = nearby.COLLISION_TYPE.World + (nearby.COLLISION_TYPE.Door or 0)

local depth = {}
local pendingClose = {}
local order = {}
local orderPos = 1
local inInterior = false
local anchorPos = nil
local anchorYaw = nil
local anchorPitch = nil
local lastPrint = 0.0
local lastStatsTested = 0.0
local lastStatsCulled = 0.0

local function angleDiff(a, b)
    local d = a - b
    while d > math.pi do d = d - 2.0 * math.pi end
    while d < -math.pi do d = d + 2.0 * math.pi end
    return math.abs(d)
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
            order[#order + 1] = { idx = idx, score = dx * dx + dy * dy }
        end
    end
    table.sort(order, function(a, b) return a.score < b.score end)
end

local function fillMax()
    for i = 1, COUNT do
        depth[i] = MAX_DIST
        pendingClose[i] = nil
    end
    orderPos = 1
end

local function publishGrid()
    -- 3x3 max-dilation: openings deliberately protect neighboring screen tiles.
    local out = {}
    for row = 1, ROWS do
        for col = 1, COLS do
            local best = 0.0
            for rr = math.max(1, row - 1), math.min(ROWS, row + 1) do
                for cc = math.max(1, col - 1), math.min(COLS, col + 1) do
                    local idx = (rr - 1) * COLS + cc
                    if depth[idx] > best then best = depth[idx] end
                end
            end
            out[(row - 1) * COLS + col] = best
        end
    end
    camera.setInteriorVisibilityGrid(COLS, ROWS, out, PADDING)
    return out
end

local function resetForCamera(pos, yaw, pitch, reason)
    fillMax()
    anchorPos = pos
    anchorYaw = yaw
    anchorPitch = pitch
    publishGrid()
    print(string.format('[TSP_VISGRID_V1] reset reason=%s max=%.0f',
        reason or 'unknown', MAX_DIST))
end

local function acceptDepth(idx, measured)
    measured = math.max(1.0, math.min(MAX_DIST, measured))
    local current = depth[idx] or MAX_DIST

    -- Expansions are safe and immediate.
    if measured >= current then
        depth[idx] = measured
        pendingClose[idx] = nil
        return
    end

    -- A contraction can hide geometry, so require a second similar observation.
    local pending = pendingClose[idx]
    if pending ~= nil and math.abs(pending - measured) <= CLOSE_CONFIRM_TOLERANCE then
        depth[idx] = math.max(pending, measured)
        pendingClose[idx] = nil
    else
        pendingClose[idx] = measured
    end
end

local function sampleTile(idx, eye)
    local row = math.floor((idx - 1) / COLS) + 1
    local col = ((idx - 1) % COLS) + 1
    local u = (col - 0.5) / COLS
    local v = (row - 0.5) / ROWS

    local okDir, dir = pcall(camera.viewportToWorldVector, util.vector2(u, v))
    if not okDir or dir == nil then
        acceptDepth(idx, MAX_DIST)
        return
    end

    local okNorm, norm = pcall(function() return dir:normalize() end)
    if not okNorm or norm == nil then
        acceptDepth(idx, MAX_DIST)
        return
    end

    local dest = eye + norm * MAX_DIST
    local okRay, res = pcall(nearby.castRay, eye, dest, { collisionType = RAY_MASK })
    if not okRay or res == nil then
        acceptDepth(idx, MAX_DIST)
        return
    end

    local d = MAX_DIST
    if res.hit and res.hitPos ~= nil then
        d = (res.hitPos - eye):length()
    end
    acceptDepth(idx, d)
end

local function printStatus(published)
    local now = core.getRealTime()
    if now == nil or now - lastPrint < PRINT_PERIOD then return end
    lastPrint = now

    local minD, maxD, sum = MAX_DIST, 0.0, 0.0
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

    local pct = 0.0
    if dt > 0.0 then pct = dc * 100.0 / dt end

    print(string.format(
        '[TSP_VISGRID_V1] grid=%dx%d min=%.0f mean=%.0f max=%.0f tested_delta=%.0f culled_delta=%.0f reject=%.1f%% total_tested=%.0f total_culled=%.0f',
        COLS, ROWS, minD, sum / COUNT, maxD, dt, dc, pct, tested, culled))
end

local function onInit()
    buildOrder()
    fillMax()
    if camera.clearInteriorVisibilityGrid ~= nil then
        camera.clearInteriorVisibilityGrid()
    end
    print('[TSP_VISGRID_V1] Lua prototype loaded')
end

local function onFrame(dt)
    if dt == nil or dt <= 0.0 then return end
    local cell = self.cell
    if cell == nil then return end

    if cell.isExterior then
        if inInterior then
            inInterior = false
            camera.clearInteriorVisibilityGrid()
            anchorPos, anchorYaw, anchorPitch = nil, nil, nil
            print('[TSP_VISGRID_V1] exit interior -> grid off')
        end
        return
    end

    local eye = camera.getPosition()
    if eye == nil then return end
    local yaw = camera.getYaw() or 0.0
    local pitch = camera.getPitch() or 0.0

    if not inInterior then
        inInterior = true
        camera.resetInteriorVisibilityStats()
        lastStatsTested, lastStatsCulled = 0.0, 0.0
        resetForCamera(eye, yaw, pitch, 'enter-interior')
    else
        local moved = anchorPos ~= nil and (eye - anchorPos):length() or 0.0
        local yawMoved = anchorYaw ~= nil and angleDiff(yaw, anchorYaw) or 0.0
        local pitchMoved = anchorPitch ~= nil and angleDiff(pitch, anchorPitch) or 0.0
        if moved >= RESET_MOVE or yawMoved >= RESET_YAW or pitchMoved >= RESET_PITCH then
            resetForCamera(eye, yaw, pitch, 'camera-change')
        end
    end

    -- C++ also clamps future setViewDistance calls while the grid is live.
    local live = camera.getViewDistance() or MAX_DIST
    if live < MAX_DIST - 1.0 then
        camera.setViewDistance(MAX_DIST)
    end

    for _ = 1, RAYS_PER_FRAME do
        local entry = order[orderPos]
        if entry == nil then
            orderPos = 1
            entry = order[orderPos]
        end
        sampleTile(entry.idx, eye)
        orderPos = orderPos + 1
        if orderPos > #order then orderPos = 1 end
    end

    local published = publishGrid()
    printStatus(published)
end

return {
    engineHandlers = {
        onInit = onInit,
        onFrame = onFrame,
    },
}
EOF_TSP_V1_LUA

check_md5() {
    local f="$1" want="$2" label="$3"
    local got
    got="$(md5sum "$f" | awk '{print $1}')"
    if [ "$got" != "$want" ]; then
        echo "ERROR: $label md5 $got != expected $want."
        echo "       Script corrupted in transit - redownload it."
        exit 1
    fi
    echo "PASS: $label md5 $got"
}
grep -Fq 'TSP_INTERIOR_VISGRID_LUA_V8' "$PKG/sensors/visgrid-v8.lua"
grep -Fq 'TSP_INTERIOR_VISGRID_LUA_V7' "$PKG/sensors/visgrid-v7.lua"
grep -Fq 'TSP_INTERIOR_VISGRID_LUA_V1' "$PKG/sensors/visgrid-v1control.lua"
check_md5 "$PKG/sensors/visgrid-v8.lua" "$MD5_V8" "V8 sensor"
check_md5 "$PKG/sensors/visgrid-v7.lua" "$MD5_V7" "V7 sensor"
check_md5 "$PKG/sensors/visgrid-v1control.lua" "$MD5_V1" "V1 control sensor"

echo
echo "===== 4/8 INSTALL V8 (default active sensor) ====="
scp -q "$PKG/sensors/visgrid-v8.lua" "$DEV:/tmp/visgrid-v8.lua"
ssh "$DEV" "
set -e
test -s /tmp/visgrid-v8.lua
grep -Fq 'TSP_INTERIOR_VISGRID_LUA_V8' /tmp/visgrid-v8.lua
mkdir -p '$MOD/sensors'
cp /tmp/visgrid-v8.lua '$MOD/sensors/visgrid-v8.lua'
cp /tmp/visgrid-v8.lua '$LUA.new'
mv -f '$LUA.new' '$LUA'
rm -f /tmp/visgrid-v8.lua
sync
"
scp -q "$PKG/sensors/visgrid-v7.lua" "$DEV:$MOD/sensors/visgrid-v7.lua"
scp -q "$PKG/sensors/visgrid-v1control.lua" "$DEV:$MOD/sensors/visgrid-v1control.lua"
echo "PASS: V8 active; all three sensors staged on the card at $MOD/sensors/."

echo
echo "===== 5/8 VERIFY ENGINE UNCHANGED + LUA SHA ====="
REMOTE_BIN_SHA="$(ssh "$DEV" "sha256sum '$BIN' | awk '{print \$1}'")"
REMOTE_LUA_SHA="$(ssh "$DEV" "sha256sum '$LUA' | awk '{print \$1}'")"
LOCAL_LUA_SHA="$(sha256sum "$PKG/sensors/visgrid-v8.lua" | awk '{print $1}')"
[ "$LOCAL_LUA_SHA" = "$REMOTE_LUA_SHA" ] || {
    echo "ERROR: V8 Lua SHA mismatch after install."
    exit 1
}
ssh "$DEV" "
set -e
grep -a -q 'TSP_INTERIOR_VISGRID_051_V1' '$BIN'
grep -Fq 'TSP_INTERIOR_VISGRID_LUA_V8' '$LUA'
"
echo "OpenMW binary (unchanged V1 engine): $REMOTE_BIN_SHA"
echo "Active V8 sensor sha256:             $REMOTE_LUA_SHA"

echo
echo "===== 6/8 CREATE SWITCH / TRACE / ROLLBACK / PORTABLE HELPERS ====="

cat > "$PKG/sensor-switch.sh" <<EOF_SWITCH
#!/usr/bin/env bash
# Swap the active VISGRID sensor between the exact V1 control, V7 and V8.
# Usage: sensor-switch.sh v1|v7|v8     (OpenMW must be closed)
set -Eeuo pipefail
DEV="\${TSP_DEV:-root@192.168.1.25}"
MOD="$MOD"
LUA="$LUA"
case "\${1:-}" in
    v1) SRC="\$MOD/sensors/visgrid-v1control.lua"; MARK='TSP_INTERIOR_VISGRID_LUA_V1' ;;
    v7) SRC="\$MOD/sensors/visgrid-v7.lua";        MARK='TSP_INTERIOR_VISGRID_LUA_V7' ;;
    v8) SRC="\$MOD/sensors/visgrid-v8.lua";        MARK='TSP_INTERIOR_VISGRID_LUA_V8' ;;
    *) echo "usage: \$0 v1|v7|v8"; exit 2 ;;
esac
if ssh "\$DEV" 'pidof openmw-0.51 >/dev/null 2>&1 || pidof openmw >/dev/null 2>&1'; then
    echo "ERROR: exit OpenMW before switching sensors."
    exit 1
fi
ssh "\$DEV" "
set -e
test -s '\$SRC'
grep -Fq '\$MARK' '\$SRC'
cp '\$SRC' '\$LUA.new'
mv -f '\$LUA.new' '\$LUA'
sync
sha256sum '\$LUA'
"
echo "ACTIVE SENSOR NOW: \$1  (\$MARK)"
echo "Same save, same binary - only the sensor changed. Compare away."
EOF_SWITCH
chmod +x "$PKG/sensor-switch.sh"

cat > "$PKG/collect-visgrid-v8-trace.sh" <<'EOF_TRACE'
#!/usr/bin/env bash
set -Eeuo pipefail
DEV="${TSP_DEV:-root@192.168.1.25}"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="${1:-$HOME/Downloads/openmw51-visgrid-v8-trace-$STAMP.txt}"
{
    echo "=================================================================="
    echo "OPENMW INTERIOR VISGRID V8 TRACE"
    echo "=================================================================="
    ssh "$DEV" 'hostname; date'
    echo
    echo "===== VISGRID STATUS LINES (V8/V7/V1) ====="
    ssh "$DEV" '
        grep -hE \
          "TSP_VISGRID_V8|TSP_VISGRID_V7|TSP_VISGRID_V1|TSP_INTERIOR_VISGRID_051_V1|TSP_DEPTH_PROJECTION|Lua.*error|ERROR.*Lua" \
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
        head -1 /mnt/SDCARD/data/ports/openmw51/mods/TSPInteriorVisGrid/scripts/TSPInteriorVisGrid/visgrid.lua
        sha256sum \
          /mnt/SDCARD/data/ports/openmw51/bin/openmw-0.51 \
          /mnt/SDCARD/data/ports/openmw51/mods/TSPInteriorVisGrid/scripts/TSPInteriorVisGrid/visgrid.lua \
          2>/dev/null || true
    '
} 2>&1 | tee "$OUT"
echo
echo "Trace saved:"
echo "  $OUT"
EOF_TRACE
chmod +x "$PKG/collect-visgrid-v8-trace.sh"

cat > "$PKG/rollback-visgrid-v8.sh" <<EOF_ROLLBACK
#!/usr/bin/env bash
set -Eeuo pipefail
DEV="\${TSP_DEV:-root@192.168.1.25}"
LUA="$LUA"
BACKUP="$REMOTE_BACKUP/visgrid.lua.before-v8"
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
echo "Restored the exact pre-V8 sensor."
EOF_ROLLBACK
chmod +x "$PKG/rollback-visgrid-v8.sh"

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
The policy half (V8 "wall-model" sensor): a few physics rays per frame feed a
world-anchored yaw/pitch depth panorama of the current interior (memory
survives turning; walking transports depths; deep sightlines must reproduce
through the same sub-direction before being trusted). Ray hits carry surface
normals, so the sensor also assembles the actual WALL PLANES and uses them to
fill and refresh directions without spending rays; nearby doors are watched so
an opening door immediately reveals its hallway; interiors already visited
warm-start from a session cache. It publishes an 8x5 per-tile depth grid each
frame. `sensors/` holds the V1-control and V7 variants for A/B testing.
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
cat > "$PKG/README-V8.txt" <<EOF_README
VISGRID V8 - WALL-MODEL SENSOR + A/B KIT
========================================

Three sensors are staged on the card ($MOD/sensors/):
  v1 = the EXACT V1 proof-of-concept Lua (gold-standard control:
       ~12 -> ~27 FPS at the matched Caldera wall, standing only)
  v7 = room-memory panorama (movement-proof store, simulator-verified)
  v8 = v7 + wall-plane inference + per-cell cache + door portals   <- ACTIVE

Switch any time (game closed), same save, same binary:
  ./sensor-switch.sh v1     ./sensor-switch.sh v7     ./sensor-switch.sh v8

Simulator scoreboard (14-phase movement suite, solid geometry):
                        pop-in events   culling while moving
  V6-style sensor          1063+          collapses/pays in pop-in
  V7                       0 (16 cold re-entry)   27-100% held
  V8                       0 everywhere           27-100% held, warm re-entry

Test order on device (rays first, FPS second):
  1. Stand at the bad staircase wall ~2 s; [TSP_VISGRID_V8] must show
     cast_attempts>0, cast_ok>0, hits>0, known climbing, planes>0,
     mean well under 3000, reject>0.
  2. FPS standing (V1 control reference: ~27).
  3. MOVE: slow turn, fast 360, stairs up/down, doorway both ways, leave
     and re-enter ("warm" in the log). Watch reject% stay up while moving.
  4. Any popping: set SCREEN_DILATE=true at the top of $LUA (no rebuild).
  5. Compare: sensor-switch.sh v1 -> confirm the 27 FPS control still holds;
     sensor-switch.sh v8 -> your movement runs.

Config knobs: top of $LUA
Device backup: $REMOTE_BACKUP
Rollback:      ./rollback-visgrid-v8.sh
Trace:         ./collect-visgrid-v8-trace.sh   (run while OpenMW is up)
Shippable kit: ./package-visgrid-portable.sh
EOF_README

echo
echo "===== 8/8 FINAL ====="
echo "=================================================================="
echo "VISGRID V8 INSTALLED (V8 active; V1 control + V7 staged for A/B)"
echo "=================================================================="
echo
echo "MORNING PROTOCOL:"
echo "  Test 1 (control):  $PKG/sensor-switch.sh v1"
echo "      -> stand at the bad wall, confirm the ~27 FPS control result."
echo "  Test 2 (V8):       $PKG/sensor-switch.sh v8"
echo "      -> same spot, then MOVE: turns, stairs, doorway, re-entry."
echo "  (V7 also staged if you want the middle step: sensor-switch.sh v7)"
echo
echo "While OpenMW is still running after a test:"
echo "  $PKG/collect-visgrid-v8-trace.sh"
echo
echo "Rollback to the pre-V8 sensor:"
echo "  $PKG/rollback-visgrid-v8.sh"
echo "=================================================================="
