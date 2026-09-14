#!/usr/bin/env bash
CR=$(printf '\r'); case "$(head -c 400 "$0" 2>/dev/null)" in *"$CR"*) echo "v14: stripping CRLF from the downloaded copy and re-running"; exec bash -c 'sed "s/\r$//" "$1" | bash' v14 "$0" ;; esac # CRLF trampoline - keep on one line
# apply_visgrid_v14_mapsync.sh
#
# V14 MAPSYNC - Lua-only. NO rebuild, NO docker, NO binary change: this run
# only replaces the sensor script and the interior map on the device (with
# verified backups and a rollback script). It fixes the V13 regression Steve
# reported on 2026-08-28: open rooms turning to fog unless standing still,
# and the Caldera wall speedup taking 10+s instead of 4-5s.
#
# WHAT WAS WRONG (diagnosed from the pasted status lines + sensor source):
#   1. Deep-opening "witnesses" were re-checked along their saved direction
#      WHILE MOVING. From a new position that ray sweeps different geometry
#      (parallax), so the re-checks kept "failing" and 2 failures retired
#      the witness. The log shows deep 28 -> 2 the moment you move: the
#      grid's memory of every open sightline was being erased wholesale,
#      publishes collapsed, and the engine fog followed. Standing still,
#      re-checks reproduce, witnesses rebuild (8->13->21->28 in your log),
#      and the fog receded - exactly what you experienced.
#   2. The wall-plane model could capture near-horizontal bins at GRAZING
#      incidence (the floor plane especially - biggest support, biggest
#      extent) and re-derive their depth analytically every frame, gluing
#      them shallow past all real evidence (pref=140/s in your log).
#   3. Closing at a wall was braked by design leftovers: 4 samples before
#      the young floor releases, then a 6-sample ring turnover per bin,
#      then up to 300 units of stale walk-slack that never drained.
#   4. The map (format v2) was ONE number per cell - a publish ceiling.
#      No floor, no room, no heading: none of what the map was for.
#
# WHAT V14 DOES (sensor TSP_VISGRID_LUA_V14_MAPSYNC, harness-validated):
#   W1 witness hold  - re-checks pause while moving; witnesses age and are
#                      re-verified within ~1-2s of stopping (retire needs 3
#                      true same-position misses now, not 2 parallax ones).
#   W2 grazing gate  - plane walk/refresh/fill require >=~27deg incidence.
#   W3 fast close    - stationary only: 2 agreeing samples release the
#                      young floor; 3 consecutive much-shallower samples
#                      rebuild the ring; slack drains while standing still.
#                      Moving or turning, closing stays conservative.
#   W4 map v3 zcap   - the map now carries each cell's true z-range from
#                      your scanner. Every pitched tile is bounded by
#                      floor/ceiling geometry from the first armed frame:
#                      tight z-axis instantly, stable while moving, zero
#                      rays spent. ("what floor am I on" - answered every
#                      frame from the map + your position.)
#   W5 budget relief - the re-check ray W1 frees while moving goes to
#                      unknown bins instead.
#
# HARNESS (25 phases incl. new pillar-hall strafe + wall-stare):
#   - strafing an open hall: witnesses held (no deep collapse), fog-guide
#     churn 215 vs 480, over-culling while moving down 48%->39%
#   - look-down with map v3: churn 623 vs 3922 (6x stabler), no artifacts
#   - door-opens pop-in: 0 artifact events vs 12 on the live sensor
#   - total culled-but-visible events: 31 vs 43 (the rest are the known
#     2-frame candidate latency crossing a doorway sightline - present and
#     equal in both sensors, masked by the V4B border fog on device)
#   - view-distance writes: 0 everywhere (V11 invariant kept)
#
# The status line keeps its [TSP_VISGRID_V11] prefix ON PURPOSE so
# pull-visgrid-perf.sh keeps working; new fields are appended at the end
# (spd= zc= v14=1) and the load banner names V14.
set -Eeuo pipefail

if [ -f "$HOME/Downloads/visgrid-tools/device.env" ]; then
    # shellcheck disable=SC1091
    . "$HOME/Downloads/visgrid-tools/device.env" || true
fi
if [ -n "${TSP_IP:-}" ]; then DEV="root@$TSP_IP"; else DEV="${TSP_DEV:-root@192.168.1.25}"; fi
STAMP="$(date +%Y%m%d-%H%M%S)"

ROOT="/mnt/SDCARD/data/ports/openmw51"
MOD="$ROOT/mods/TSPInteriorVisGrid"
LUA="$MOD/scripts/TSPInteriorVisGrid/visgrid.lua"
MAPLUA="$MOD/scripts/TSPInteriorVisGrid/interiormap.lua"
SCAN="$ROOT/tsp_interior_scan.txt"

PKG="$HOME/Downloads/openmw51-visgrid-v14-mapsync-$STAMP"
TOOLS="$HOME/Downloads/visgrid-tools"
LOG="$PKG/install.log"
mkdir -p "$PKG/device-backup" "$TOOLS"
exec > >(tee -a "$LOG") 2>&1

SENSOR_MD5="544c83ba8f52ccc262f03c92978ae73d"
CONV_MD5="b5ee6d1e039e10e04267f096b9f74b80"
REMOTE_BACKUP="$ROOT/backups/visgrid-v14-mapsync-$STAMP"
DEPLOY_STARTED=0

fail() {
    local rc="${1:-1}" line="${2:-unknown}"
    echo
    echo "!!!!! V14 INSTALL FAILED (exit $rc at line $line) !!!!!"
    if [ "$DEPLOY_STARTED" = "1" ]; then
        echo "----- DEPLOY WAS IN FLIGHT: RESTORING DEVICE SENSOR + MAP -----"
        if ssh "$DEV" "set -e
            test -s '$REMOTE_BACKUP/visgrid.lua.before-v14'
            cp -p '$REMOTE_BACKUP/visgrid.lua.before-v14' '$LUA'
            if [ -s '$REMOTE_BACKUP/interiormap.lua.before-v14' ]; then
                cp -p '$REMOTE_BACKUP/interiormap.lua.before-v14' '$MAPLUA'
            fi
            sync"; then
            echo "----- DEVICE RESTORED FROM $REMOTE_BACKUP -----"
        else
            echo "!!! AUTOMATIC RESTORE FAILED - run: bash $TOOLS/rollback-visgrid-v14.sh"
            echo "    (or restore by hand from $REMOTE_BACKUP on the device)"
        fi
    else
        echo "No deploy had started - the device was not modified by this run."
    fi
    echo "Log: $LOG"
    exit "$rc"
}
trap 'fail $? $LINENO' ERR

echo "=================================================================="
echo "V14 MAPSYNC installer  $STAMP"
echo "device=$DEV  pkg=$PKG"
echo "Lua-only: no rebuild, no docker, the game binary is not touched."
echo "=================================================================="

echo
echo "===== 1/8 PRECONDITIONS ====="
ssh "$DEV" "echo device-reachable"
ssh "$DEV" "test -s '$LUA'" || { echo "ERROR: no sensor at $LUA on the device"; false; }
ssh "$DEV" "test -s '$SCAN'" || {
    echo "ERROR: no interior scan at $SCAN on the device."
    echo "       V14's map v3 is built from that scan. Re-run the scanner"
    echo "       first (bash ~/Downloads/arm-interior-scan.sh, launch"
    echo "       Morrowind_51 once, then rerun this installer)."
    false
}
echo "device sensor now : $(ssh "$DEV" "md5sum '$LUA'" | awk '{print $1}')"
if ssh "$DEV" "test -s '$MAPLUA'"; then
    echo "device map now    : $(ssh "$DEV" "md5sum '$MAPLUA'" | awk '{print $1}')"
else
    echo "device map now    : (none installed)"
fi
echo "PASS: preconditions."

echo
echo "===== 2/8 EXTRACT PAYLOADS (md5-gated) ====="
cat > "$PKG/visgrid-v14.lua" <<'TSPEOF_SENSOR_V14'
-- TSP_VISGRID_LUA_V14_MAPSYNC  (map-integrated stability edition)
--
-- V14 = V11b with five changes, all driven by the 2026-08-28 device log
-- (open rooms fogging over while moving; wall convergence 10s vs V1's 4-5s):
--
--   W1 WITNESS HOLD  - deep-opening re-checks run only while STATIONARY.
--      Moving, the saved re-check direction sweeps different geometry
--      (parallax): its misses retired real openings wholesale (deep 28->2
--      in the log) and the grid collapsed into fog until you stood still.
--      Held witnesses still age; the moment you stop they are re-verified.
--   W2 GRAZING GATE  - the wall-plane model may only drive a bin when the
--      bin direction meets the plane at >=~27 degrees. The floor/ceiling
--      planes (biggest support, biggest extent) were capturing near-
--      horizontal bins at grazing angles and gluing them shallow, writing
--      binDepth directly past all ring evidence.
--   W3 FAST CLOSE    - closing is now as fast as V1 again when the evidence
--      agrees: two agreeing samples release the young floor; three
--      consecutive much-shallower samples rebuild the ring (stale deep
--      memory cannot prop the max up for a whole extra turnover); slack
--      (which models motion drift) drains while standing still.
--   W4 MAP V3 ZCAP   - the interior map now carries each cell's true
--      z-range from the scanner. Every pitched tile is bounded by the
--      floor/ceiling geometry from the FIRST armed frame: the z-axis is
--      tight instantly, stays tight while moving, and costs zero rays.
--      (Map v3 = flat caps + z-ranges; v2/v1 maps still load, zcap off.)
--   W5 BUDGET RELIEF - the re-check ray W1 frees while moving goes to
--      unknown bins instead: faster learning exactly when it is needed.
--
-- (original V11 header follows)
-- TSP_INTERIOR_VISGRID_LUA_V11  (contained + interior-map edition)
--
-- V11 = the V10 wall-model/witness sensor with three changes:
--
--   1. ERROR CONTAINMENT - the entire frame handler runs under pcall. Any
--      Lua error is logged ONCE with its real message, and after 3 errors
--      the sensor disarms the engine grid and idles for the session. The
--      V10 device crash was a per-frame script error repeating into the
--      engine's error path until LuaJIT's latent VM bug segfaulted; an
--      error may never again reach that path more than a handful of times.
--   2. ZERO PROJECTION-API SURFACE - the sensor never calls
--      setViewDistance/getBaseViewDistance at all (fog and projection are
--      entirely engine-side: V1 floor clamp + V3 percentile fog).
--   3. OFFLINE INTERIOR MAP - if the TSP interior scanner's map is
--      installed, every published tile is clamped to the current cell's
--      real bounding size. Unknown directions then publish the ROOM's
--      diagonal instead of 6200: nothing outside the cell can ever be
--      drawn, first entries start tight, and the percentile fog guide gets
--      sane values immediately. No map = identical to V10 behavior.
--
-- (original V10 header follows)
-- TSP_INTERIOR_VISGRID_LUA_V10  (fog-follow edition)
--
-- V10 = V9.1 with two targeted correctness/performance changes:
--
--   * promoted deep openings are retired ONLY by exact re-checks through the
--     saved witness direction; random jitter elsewhere in the same panorama
--     bin can no longer erase a valid narrow doorway/railing sightline.
--   * Lua no longer drives global view distance. The V10 engine computes a
--     dense fog guide from the shallow-majority (75th percentile) VISGRID
--     depths, so a few deep doorway tiles cannot push the whole fog wall away.
--
-- V9 = V8 with five changes driven by on-device testing:
--
--   1. FOG-FOLLOW VIEW DISTANCE - the real far plane now tracks the deepest
--      published tile (plus a margin), and the paired engine patch
--      (TSP_INTERIOR_VISGRID_051_V2_FOGFOLLOW) drags the fog wall with it.
--      Globally-shallow transients land at/behind the fog wall and read as
--      fog - like cutting view distance in an exterior - instead of red
--      holes. (Honest limit: the fog wall is GLOBAL, driven by the deepest
--      tile on screen, so a tile-local misjudgement in front of a deep view
--      is reduced by the young/candidate machinery, not hidden by fog.)
--      Falls are slew-limited (smooth fog), rises are instant (correctness).
--      The engine still clamps every request to >= the grid's far floor, so
--      this can never clip published geometry.
--   2. PLANE MATH FIX - merging a new hit into an existing wall plane now
--      measures point-to-plane distance with the PLANE's normal (was: the new
--      hit's normal). One wall = one plane again; fills and analytic
--      refreshes reach full strength.
--   3. PLANE-EXACT WALKING - bins backed by a supported wall plane re-derive
--      their depth each frame by intersecting the bin direction with the
--      plane (exact for any translation, lateral included), instead of the
--      first-order -dot(step, dir) shift. Non-plane bins keep the old rule.
--   4. TIGHT VERTICAL - the publish-OPEN escape for near-vertical tiles is
--      gone: steep tiles publish their MEASURED ceiling/floor depths, so the
--      z axis shrinks to what the room actually is (unknown stays OPEN=safe).
--   5. CHEAPER STEADY STATE - the 14-ray burst now needs >4 immature visible
--      bins (was >0), known-depth bins cast SHORT rays (adaptive length),
--      and the publish neighborhood is a 5-bin cross (was 9-bin square).
--
-- (original V8 header follows)
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
local DEEP_MISS_LIMIT = 3          -- consecutive EXACT re-check failures to retire
                                   -- (V14: re-checks only run while stationary,
                                   -- so these are true same-position misses)
local DEEP_VERIFY_AGE = 24         -- frames between exact re-checks of a promoted narrow opening
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
local DOOR_GRACE_SECONDS = 2.4  -- V9.1: covers the bin-learn window after a
                                -- door opens (async short-miss verify needs a
                                -- few more samples than the old flow)

local SCREEN_DILATE = false        -- V1-style 3x3 max dilation of the published
                                   -- grid. Bin +/-1 neighborhood + the C++
                                   -- one-tile expansion already double-cover;
                                   -- turn this on if any popping is ever seen.

-- ==================== V14 MAPSYNC ====================
local V14 = {
    MOVE_EPS = 30.0,        -- u/s smoothed speed; above = "moving"
    SPD_TAU = 0.30,         -- speed EMA time constant (seconds)
    AGREE_SPREAD = 300.0,   -- thin evidence that AGREES this closely may close
    CLOSE_RUN_N = 3,        -- consecutive much-shallower samples that rebuild a ring
    CLOSE_RUN_DROP = 500.0, -- "much shallower" = this far under the ring max
    SLACK_DECAY_F = 8.0,    -- stationary slack drain per frame (world units)
    ZCAP_MARGIN = 250.0,    -- safety margin on the scanner's cell z-range
    ZCAP_FLOOR = 900.0,     -- never cap a tile below this
    PLANE_DENOM = -0.45,    -- plane walk/refresh incidence gate (~27 degrees)
}

-- V9.1 fog-follow view distance ("red -> fog")
-- WRITE DISCIPLINE (crash fix, 2026-08-27): this device's build has a
-- pre-existing LuaJIT-fragility around scripts that mutate view distance
-- (documented 08-19, long before VISGRID), and setViewDistance also kicks
-- off projection + cell-grid machinery engine-side. The first V9 wrote the
-- far plane nearly every frame, hardest right in the post-load window - and
-- the game segfaulted in LuaJIT ~2.5s after loading, twice. So: NO writes
-- at all during the warmup window after entering/loading, at most one write
-- per VD_UPDATE_PERIOD after that, only for moves > VD_SEND_EPS - with the
-- single exception that a RISE the curtain needs goes out immediately.
-- V11: all VD_* projection-control config removed - the sensor never
-- touches the projection (engine-side V1 clamp + V3 percentile fog only).

-- V9.4 tight vertical
-- The z-axis win comes from REMOVING the old publish-OPEN pole escape: steep
-- tiles now publish their MEASURED ceiling/floor depths, which in a normal
-- room is a few hundred units. The extra hard cap below is OFF by default:
-- on-device it capped UNKNOWN bins during the post-load look-down frames
-- (far_floor pinned to 2600 on frame 1), which violates "unknown = don't
-- cull" - and once you exempt unknown/young/deep-witness bins it is
-- redundant anyway (measured-deep bins carry a promoted witness and young
-- bins already publish the 2600 floor). Kept only as an experiment switch.
local VERT_TIGHT = false           -- hard cap for steep tiles (experiment only)
local VERT_TIGHT_DEG = 45.0
local VERT_TIGHT_CAP = 2600.0      -- (door-grace tiles exempt while it lasts)

-- V9.5 steady-state cost
local YOUNG_BURST_MIN = 4          -- immature visible bins needed to trigger
                                   -- the 14-ray burst (was: any)
local ADAPT_RAY = true             -- known bins cast short rays
local ADAPT_RAY_MULT = 1.6         -- length = depth*mult + pad, clamped
local ADAPT_RAY_PAD = 300.0
local ADAPT_RAY_MIN = 900.0
local NEIGHBOR_CROSS = false       -- publish max over 5-bin cross instead of
                                   -- the 3x3 square. SIM-VETOED as default:
                                   -- diagonal bins carry door-grace and funnel
                                   -- influence to adjacent tiles (67 turn +
                                   -- 36 door artifacts without them). Left as
                                   -- a switch for future experiments only.
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
    print('[TSP_VISGRID_V11] engine visibility bridge absent - sensor idle (stock build?)')
end

-- ======== V11: offline interior map (optional, from the TSP scanner) ========
local mapState = { cells = nil, zdata = nil, cap = 6200.0, zMin = nil, zMax = nil }
do
    local okMap, m = pcall(require, 'scripts.TSPInteriorVisGrid.interiormap')
    if okMap and type(m) == 'table' and type(m.cells) == 'table' then
        mapState.cells = m.cells
        -- TSP_V14: map v3 also carries per-cell z-ranges for the zcap
        if type(m.z) == 'table' then mapState.zdata = m.z end
        print(string.format('[TSP_VISGRID_V11] interior map loaded: %s cells (format v%s)',
            tostring(m.count or '?'), tostring(m.version or '?')))
    else
        print('[TSP_VISGRID_V11] no interior map installed - raycast-only mode')
    end
end
mapState.cap = OPEN_DEPTH    -- per-cell publish ceiling (map-driven)

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
local binDeepAge = {}
local binCandVal = {}      -- unverified deep witness awaiting its re-cast
local binCandJy, binCandJp = {}, {}
local binCandAge = {}
local binCloseRun = {}     -- V14: consecutive much-shallower samples per bin
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

-- V9 fog-follow state (one table: the main chunk is near Lua's 200-local cap)
--   vdState.pubMax  deepest tile published this frame
--   cmd     far plane we are currently commanding
--   sent    last value actually written to the engine
--   base    cached settings view distance (read once on enter)
--   elapsed time since the last engine write
--   sends   writes since last status print (diagnostic)
--   saved   fallback restore value (getBaseViewDistance preferred)
local vdState = { pubMax = 0.0, cmd = nil, sent = nil, sentEff = nil,
    base = nil, elapsed = 0.0, sends = 0, saved = nil,
    spd = 0.0, zc = 0, turnf = 0 }  -- V14: speed EMA, zcap count, turn flag
local justLoaded = true       -- first frame after chunk-load/onInit/onLoad
-- TSP_VISGRID_V11_LOADSAFE_12S
local POST_LOAD_ARM_DELAY = 12.0
local postLoadArmRemaining = 0.0
local holdPrintElapsed = 0.0
local gridMaybeArmed = false  -- true until we KNOW the engine grid is clear
                              -- (covers load-into-exterior with a stale grid)

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
    vdState.sends = 0
    vdState.zc = 0
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
        binDeepAge[i] = 0
        binCandVal[i] = nil
        binCandAge[i] = 0
        binCloseRun[i] = 0
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
    gridMaybeArmed = true   -- engine grid state unknown after any (re)load:
                            -- the first frame outside our control disarms it
    justLoaded = true       -- first frame disarms BEFORE any enter logic
    postLoadArmRemaining = POST_LOAD_ARM_DELAY  -- TSP_VISGRID_V11_LOADSAFE_12S
    holdPrintElapsed = 0.0
    mapState.cap = OPEN_DEPTH
    mapState.zMin = nil
    mapState.zMax = nil
    vdState.spd = 0.0
    vdState.turnf = 0
    vdState.cmd = nil
    vdState.sent = nil
    vdState.sentEff = nil
    vdState.elapsed = 0.0
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
            -- V9 fix: point-to-plane distance uses the PLANE's normal with the
            -- plane's d. (V8 paired the new hit's normal with p.d, which let
            -- one wall fragment into many planes and starved fills/refreshes.)
            local dist = p.nx * hx + p.ny * hy + p.nz * hz + p.d
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
                    -- V14: fills also avoid grazing intersections
                    if denom < -0.35 then
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
                -- V9: a fill is a PREDICTION about a direction no ray has
                -- ever measured, and a wall's witnessed extent box spans
                -- straight across any doorway hole in that wall - so a fill
                -- may never publish tighter than the young floor. Real rays
                -- (age 25 -> resampled soon) bring the full depth one sample
                -- later; until then the floor still halves the curtain vs
                -- OPEN and keeps the fog wall near.
                binDepth[j] = max(bestT, YOUNG_FLOOR)
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
        -- TSP_V14_FAST_CLOSE(a): thin evidence keeps the permissive floor
        -- only while the samples DISAGREE. Two-plus rays landing within
        -- AGREE_SPREAD of each other (no witness or candidate pending) are
        -- V7's symmetric confirmation - publish what they measured.
        local agree = false
        if n >= 2 and dv == nil and binCandVal[idx] == nil
            and vdState.spd < V14.MOVE_EPS and vdState.turnf == 0 then
            local lo, hi = ring[1], ring[1]
            for k = 2, n do
                local rv = ring[k]
                if rv < lo then lo = rv elseif rv > hi then hi = rv end
            end
            agree = (hi - lo) <= V14.AGREE_SPREAD
        end
        if not agree then pub = YOUNG_FLOOR end
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

local function acceptBin(idx, dist, wasMiss, jy, jp, isVerify, isDeepVerify)
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
            binDeepAge[idx] = 0
        else
            pushRing(idx, m)   -- fluke discarded; the shallow re-cast is evidence
        end
        binCandVal[idx] = nil
        republish(idx)
        return
    end

    -- A promoted deep witness represents one EXACT sub-direction inside this
    -- coarse panorama bin. Arbitrary jitter rays elsewhere in the same bin
    -- must never retire it (that was V9's narrow-door/railing failure mode).
    -- Only a scheduled re-cast through the saved witness direction may retire.
    if isDeepVerify and binDeepVal[idx] ~= nil then
        local dv = binDeepVal[idx]
        binDeepAge[idx] = 0
        if m >= dv - DEEP_REPRO_TOL then
            binDeepMiss[idx] = 0
            if m > dv then binDeepVal[idx] = m end
        else
            binDeepMiss[idx] = (binDeepMiss[idx] or 0) + 1
            pushRing(idx, m)
            if binDeepMiss[idx] >= DEEP_MISS_LIMIT then
                binDeepVal[idx] = nil
                binDeepJy[idx] = nil
                binDeepJp[idx] = nil
                binDeepMiss[idx] = 0
            end
        end
        republish(idx)
        return
    end

    -- Ordinary jitter samples update shallow evidence only. They do NOT count
    -- as misses against a narrow promoted opening because they are different
    -- sub-directions by design.
    local ring = binRing[idx]
    local known = max(ringMaxOf(ring), binDeepVal[idx] or 0.0)
    if #ring >= 1 and m > known + OPENING_JUMP then
        -- Suspicious new depth: hold it as a candidate and verify next frame.
        binCloseRun[idx] = 0
        binCandVal[idx] = m
        binCandJy[idx] = jy
        binCandJp[idx] = jp
        binCandAge[idx] = 0
        binPrio[idx] = max(binPrio[idx] or 0, 8)
    else
        -- TSP_V14_FAST_CLOSE(b): N consecutive samples all far shallower
        -- than the remembered max mean the deep memory is stale (walked up
        -- to a wall): rebuild the ring from just those samples, so closing
        -- costs N rays instead of N plus a full ring turnover.
        local prevMax = ringMaxOf(ring)
        pushRing(idx, m)
        if m < prevMax - V14.CLOSE_RUN_DROP
            and vdState.spd < V14.MOVE_EPS and vdState.turnf == 0 then
            local run = (binCloseRun[idx] or 0) + 1
            binCloseRun[idx] = run
            if run >= V14.CLOSE_RUN_N and #ring >= RING_N then
                local p = binRingPos[idx]
                local rn = #ring
                local i2 = p - 1; if i2 < 1 then i2 = i2 + rn end
                local i3 = p - 2; if i3 < 1 then i3 = i3 + rn end
                binRing[idx] = { ring[i3], ring[i2], ring[p] }
                binRingPos[idx] = 3
                binCloseRun[idx] = 0
            end
        else
            binCloseRun[idx] = 0
        end
    end
    republish(idx)
end

local function castBin(idx, ex, ey, ez, mode, predictive)
    -- mode: 'center' | 'jitter' | 'verify'
    local dx, dy, dz = binDirX[idx], binDirY[idx], binDirZ[idx]
    local jy, jp = 0.0, 0.0
    local isVerify = false
    local isDeepVerify = false
    if mode == 'verify' and binCandVal[idx] ~= nil then
        jy, jp = binCandJy[idx] or 0.0, binCandJp[idx] or 0.0
        isVerify = true
    elseif mode == 'deepverify' and binDeepVal[idx] ~= nil then
        jy, jp = binDeepJy[idx] or 0.0, binDeepJp[idx] or 0.0
        isDeepVerify = true
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

    -- V9.5 adaptive ray length: a bin whose depth is known only needs a ray
    -- a little past that depth, so the steady state casts SHORT (cheaper in
    -- Bullet). A short-ray MISS never caps learning and never double-casts:
    -- it flips the bin permissive and queues a full-length verify next frame
    -- (see the miss branch below). Verify casts always run full length, and
    -- bins holding a promoted deep witness always get full rays (a short
    -- miss must never erode a verified funnel).
    local rayLen = RAY_LEN
    if ADAPT_RAY and not isVerify and not isDeepVerify then
        local bd = binDepth[idx]
        if bd ~= nil and bd < OPEN_DEPTH - 1.0
            and binCandVal[idx] == nil and binDeepVal[idx] == nil then
            rayLen = bd * ADAPT_RAY_MULT + ADAPT_RAY_PAD
            if rayLen < ADAPT_RAY_MIN then rayLen = ADAPT_RAY_MIN end
            if rayLen > RAY_LEN then rayLen = RAY_LEN end
        end
    end

    local okRay, resOrErr = pcall(nearby.castRay,
        util.vector3(ex, ey, ez),
        util.vector3(ex + dx * rayLen, ey + dy * rayLen, ez + dz * rayLen),
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
        acceptBin(idx, sqrt(hx * hx + hy * hy + hz * hz), false, jy, jp, isVerify, isDeepVerify)
        -- feed the wall model (normals may not exist on every build)
        if planeDataOk == nil then
            planeDataOk = (res.hitNormal ~= nil)
            if not planeDataOk then
                print('[TSP_VISGRID_V11] castRay has no hitNormal - plane inference off')
            end
        end
        if planeDataOk == true and res.hitNormal ~= nil then
            local okP = pcall(planeObserveHit, idx, wx, wy, wz,
                res.hitNormal.x, res.hitNormal.y, res.hitNormal.z)
            if not okP then planeDataOk = false end
        end
    else
        missCount = missCount + 1
        if rayLen < RAY_LEN - 1.0 then
            -- A short ray that MISSES saw an opening deeper than it reached
            -- (a door opened, or the stored depth was stale). Two wrong
            -- answers exist here: recording a deep sample at the ray's own
            -- length "ladders" (publishes too shallow for several frames -
            -- the sim caught pop-in), and a second synchronous full-length
            -- cast silently exceeds the per-frame ray budget. So: go
            -- PERMISSIVE right now (one frame of extra rendering at worst,
            -- never a hole) and queue a priority FULL-LENGTH verify of this
            -- exact sub-direction for the next frame through the normal
            -- candidate machinery. A real wall re-confirms and republishes
            -- one frame later; a real opening promotes at its true depth.
            binDepth[idx] = OPEN_DEPTH
            binSlack[idx] = 0.0
            binAge[idx] = 0
            binCandVal[idx] = rayLen
            binCandJy[idx] = jy
            binCandJp[idx] = jp
            binCandAge[idx] = 0
            binPrio[idx] = max(binPrio[idx] or 0, 9)
        else
            acceptBin(idx, RAY_LEN, true, jy, jp, isVerify, isDeepVerify)
        end
    end
end

-- Publish: read the panorama through the current screen window.
local function publishGrid(ez)
    frameNo = frameNo + 1
    -- TSP_V14_ZCAP setup: half the angular row spacing, probed from the live
    -- projection. A tile is capped by its edge NEAREST the horizon, never
    -- its center, so a cap can never clip content in the shallow half.
    local rowHalf = nil
    if mapState.zMin ~= nil then
        local okA, dA = pcall(camera.viewportToWorldVector, util.vector2(0.5, 0.3))
        local okB, dB = pcall(camera.viewportToWorldVector, util.vector2(0.5, 0.5))
        if okA and okB and dA ~= nil and dB ~= nil then
            local lA = sqrt(dA.x * dA.x + dA.y * dA.y + dA.z * dA.z)
            local lB = sqrt(dB.x * dB.x + dB.y * dB.y + dB.z * dB.z)
            if lA > 0.0001 and lB > 0.0001 then
                local pA = deg(asin(max(-1.0, min(1.0, dA.z / lA))))
                local pB = deg(asin(max(-1.0, min(1.0, dB.z / lB))))
                rowHalf = abs(pA - pB) * 0.5 + 1.0
            end
        end
    end
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

                    -- V9: no more publish-OPEN escape near the poles - the
                    -- bins measure close ceilings/floors just fine, and the
                    -- z axis is exactly where cheap culling lives.
                    -- Conservative max over the bin neighborhood
                    -- (5-bin cross by default, 3x3 square if NEIGHBOR_CROSS
                    -- is off).
                    depth = 0.0
                    local hadGrace = false
                    for dp = -1, 1 do
                        local pp = bp + dp
                        if pp < 0 then pp = 0 elseif pp >= PITCH_BINS then pp = PITCH_BINS - 1 end
                        for dyw = -1, 1 do
                            if not (NEIGHBOR_CROSS and dp ~= 0 and dyw ~= 0) then
                                local j = pp * YAW_BINS + ((by + dyw) % YAW_BINS) + 1
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
                                        hadGrace = true
                                    else
                                        doorGrace[j] = nil
                                        doorGraceCount = doorGraceCount - 1
                                    end
                                end
                                if dv > depth then depth = dv end
                            end
                        end
                    end
                    -- V9: steep tiles cap hard. Looking >45 deg up/down, the
                    -- room's own ceiling/floor bounds the scene; nothing
                    -- needs to render past the cap (door grace exempts).
                    if VERT_TIGHT and not hadGrace and depth > VERT_TIGHT_CAP
                        and (pitchDeg > VERT_TIGHT_DEG or pitchDeg < -VERT_TIGHT_DEG) then
                        depth = VERT_TIGHT_CAP
                    end
                    -- TSP_V14_ZCAP: the offline map knows this cell's true
                    -- vertical extent. Nothing exists above zMax or below
                    -- zMin, so a tile pitched into floor or ceiling is
                    -- bounded by pure geometry: tight z-axis from the first
                    -- armed frame, stable under movement, zero rays spent.
                    if rowHalf ~= nil and not hadGrace then
                        local pe = pitchDeg
                        if pe > 0.0 then
                            pe = pe - rowHalf
                            if pe < 0.0 then pe = 0.0 end
                        else
                            pe = pe + rowHalf
                            if pe > 0.0 then pe = 0.0 end
                        end
                        local sp2 = sin(rad(pe))
                        local zc = nil
                        if sp2 > 0.10 then
                            zc = (mapState.zMax - ez + V14.ZCAP_MARGIN) / sp2
                        elseif sp2 < -0.10 then
                            zc = (ez - mapState.zMin + V14.ZCAP_MARGIN) / (-sp2)
                        end
                        if zc ~= nil then
                            if zc < V14.ZCAP_FLOOR then zc = V14.ZCAP_FLOOR end
                            if zc < depth then
                                depth = zc
                                vdState.zc = vdState.zc + 1
                            end
                        end
                    end
                end
            end
            -- V11: nothing beyond the cell's own bounds can ever need drawing
            out[tIdx] = max(MIN_DEPTH, min(mapState.cap, depth))
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

    vdState.pubMax = 0.0
    for i = 1, COLS * ROWS do
        if out[i] > vdState.pubMax then vdState.pubMax = out[i] end
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

    -- 1b) periodically re-check promoted narrow openings through THEIR exact
    -- saved sub-direction. One exact witness check per frame is enough; random
    -- jitter elsewhere in the bin is never allowed to retire it.
    -- TSP_V14_WITNESS_HOLD: exact re-checks only run while stationary. A
    -- re-check ray cast from a NEW position sweeps different geometry
    -- (parallax) and its miss says nothing about the opening - retiring on
    -- it collapsed open rooms into fog during movement. Held witnesses
    -- still age; stopping resumes verification within a second or two.
    if casts < budget and vdState.spd < V14.MOVE_EPS then
        local bestDeep, bestDeepAge = nil, DEEP_VERIFY_AGE - 1
        for i = 1, #visList do
            local j = visList[i]
            if binDeepVal[j] ~= nil and (binDeepAge[j] or 0) > bestDeepAge then
                bestDeep = j
                bestDeepAge = binDeepAge[j] or 0
            end
        end
        if bestDeep ~= nil then
            castBin(bestDeep, ex, ey, ez, 'deepverify', false)
            casts = casts + 1
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
                            if denom < V14.PLANE_DENOM then -- TSP_V14_GRAZING_GATE
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


local planeById = {}   -- transport-time scratch: plane id -> plane
local function transportTranslation(mx, my, mz, moveDist, ex, ey, ez)
    if moveDist <= 0.0 then
        for i = 1, #knownList do
            local j = knownList[i]
            binAge[j] = (binAge[j] or 0) + 1
            if binDeepVal[j] ~= nil then binDeepAge[j] = (binDeepAge[j] or 0) + 1 end
            -- TSP_V14_FAST_CLOSE(c): slack models translation drift, so
            -- standing still it drains - the curtain settles onto the
            -- measured walls instead of carrying stale walk-slack forever.
            local sl = binSlack[j]
            if sl ~= nil and sl > 0.0 then
                sl = sl - V14.SLACK_DECAY_F
                if sl < 0.0 then sl = 0.0 end
                binSlack[j] = sl
            end
        end
        return
    end
    -- V9: bins backed by a well-supported wall plane get their depth
    -- re-derived EXACTLY by intersecting the bin direction with the plane
    -- from the NEW eye position. Correct for any translation, lateral
    -- included, so these bins collect no drift slack while walking.
    local usePlanes = planeDataOk == true and #planes > 0
    if usePlanes then
        for k in pairs(planeById) do planeById[k] = nil end
        for k = 1, #planes do
            local p = planes[k]
            if p.support >= PLANE_MIN_SUPPORT then planeById[p.id] = p end
        end
    end
    local slackAdd = min(SLACK_MAX, moveDist * MOVE_SLACK)
    for i = 1, #knownList do
        local j = knownList[i]
        binAge[j] = (binAge[j] or 0) + 1
        if binDeepVal[j] ~= nil then binDeepAge[j] = (binDeepAge[j] or 0) + 1 end
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
            local exact = nil
            if usePlanes and binDeepVal[j] == nil then
                local p = planeById[planeSupport[j]]
                if p ~= nil then
                    local dx, dy, dz = binDirX[j], binDirY[j], binDirZ[j]
                    local denom = p.nx * dx + p.ny * dy + p.nz * dz
                    -- TSP_V14_GRAZING_GATE: a plane may only re-derive a bin
                    -- it meets head-on enough; grazing floor/ceiling
                    -- intersections glued near-horizontal bins shallow.
                    if denom < V14.PLANE_DENOM then
                        local t = -(p.nx * ex + p.ny * ey + p.nz * ez + p.d) / denom
                        if t > MIN_DEPTH and t < RAY_LEN and abs(t - (bd - dot)) < 500.0 then
                            exact = t
                        end
                    end
                end
            end
            binDepth[j] = exact or shift(bd)
            binDeepVal[j] = shift(binDeepVal[j])
            binCandVal[j] = shift(binCandVal[j])
            if exact ~= nil then
                -- exact depth needs only a token safety margin
                binSlack[j] = min((binSlack[j] or 0.0) + slackAdd * 0.15, 80.0)
            else
                binSlack[j] = min(SLACK_MAX, (binSlack[j] or 0.0) + slackAdd)
            end
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
    print('[TSP_VISGRID_V11] no readable door state - door portals off')
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
        binDeepAge[j] = 60
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
            '[TSP_VISGRID_V11] warm start from session cache: %d bins, %d planes (entry delta %.0f)',
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

    local vdNow = -1
    local okVD, vd = pcall(camera.getViewDistance)
    if okVD and vd ~= nil then vdNow = vd end

    local cand, deep = countHot()

    -- Diagnostic mirror of the engine's V10 percentile fog guide.
    local fogVals = {}
    for i = 1, COLS * ROWS do fogVals[i] = out[i] or OPEN_DEPTH end
    table.sort(fogVals)
    local fogIdx = math.ceil(#fogVals * 0.75)
    if fogIdx < 1 then fogIdx = 1 elseif fogIdx > #fogVals then fogIdx = #fogVals end
    local fogGuide = fogVals[fogIdx]

    print(string.format(
        '[TSP_VISGRID_V11] min=%.0f mean=%.0f max=%.0f lt1k=%d lt2k=%d reject=%.1f%% known=%d cand=%d deep=%d planes=%d fill=%d warm=%d doorEv=%d grace=%d budget=%d cast_attempts=%d cast_ok=%d hits=%d misses=%d dir_fail=%d len_fail=%d cast_fail=%d opens=%d closes=%d fans=%d predict=%d',
        minD, sum / (COLS * ROWS), maxD, under1k, under2k, reject,
        #knownList, cand, deep,
        #planes, fillCount, cacheWasWarm and 1 or 0, doorEvents, doorGraceCount,
        budget,
        castAttempts, castOK, hitCount, missCount,
        dirFail, lenFail, castFail,
        farConfirms, nearConfirms, openingEvents, predictCasts)
        .. string.format(' pref=%d vd=%.0f cap=%.0f map=%d fogq=%.0f',
            planeRefresh, vdNow, mapState.cap, mapState.cells ~= nil and 1 or 0, fogGuide)
        .. string.format(' spd=%.0f zc=%d v14=1', vdState.spd, vdState.zc))
    if firstDirError ~= nil then
        print('[TSP_VISGRID_V11] first_dir_error=' .. firstDirError)
    end
    if firstCastError ~= nil then
        print('[TSP_VISGRID_V11] first_cast_error=' .. firstCastError)
    end
    resetDiagnostics()
end

local function restoreViewDistance()
    -- V11: the sensor never writes the view distance, so there is never
    -- anything to restore, and the whole projection/settings API surface
    -- stays untouched (two crash investigations both circled that area).
    vdState.cmd = nil
    vdState.sent = nil
    vdState.sentEff = nil
end

-- Make sure the engine holds NO curtain and a sane view distance. Covers the
-- lifecycle hole where a save is loaded while a previous script instance had
-- the grid armed: the C++ store survives the load, and without this the
-- stale interior curtain would cull the freshly loaded scene.
local function safeDisarm(reason)
    -- Restore the view distance only when there is actually something to
    -- undo (a stale armed grid from before a load, or our own writes).
    -- The common post-load case then touches nothing but the grid clear -
    -- no view-distance write inside the fragile load window.
    local hadStale = false
    if haveBridge then
        local okS, st = pcall(camera.getInteriorVisibilityStats)
        hadStale = okS and st ~= nil and st.enabled == true
        pcall(camera.clearInteriorVisibilityGrid)
    end
    local didRestore = hadStale or vdState.sent ~= nil
    if didRestore then
        restoreViewDistance()
    else
        vdState.cmd = nil
        vdState.sent = nil
        vdState.sentEff = nil
    end
    if gridMaybeArmed and didRestore then
        print('[TSP_VISGRID_V11] disarm (' .. tostring(reason) .. ') -> grid off')
    end
    gridMaybeArmed = false
end

local function enterInterior(cellName, ex, ey, ez)
    -- bank the outgoing cell's learned panorama first (B)
    if inInterior and lastCellName ~= nil and lastEx ~= nil then
        cacheSave(lastCellName, lastEx, lastEy, lastEz)
    end
    -- V11: look up this cell in the offline interior map (if installed)
    mapState.cap = OPEN_DEPTH
    mapState.zMin = nil
    mapState.zMax = nil
    if mapState.cells ~= nil then
        -- TSP_VISGRID_V11B_MAPV2: flat map entries (a bare cap number per
        -- cell) shrink the resident Lua heap ~10x vs the v1 subtables; both
        -- formats are accepted so any installed map keeps working.
        local e = mapState.cells[cellName]
        local capv = nil
        if type(e) == 'number' then
            capv = e
        elseif type(e) == 'table' and type(e.cap) == 'number' then
            capv = e.cap
        end
        if capv ~= nil and capv >= 900 then
            mapState.cap = min(OPEN_DEPTH, capv)
            -- TSP_V14: map v3 carries "minz|maxz" per cell for the zcap
            local zdata = mapState.zdata
            if zdata ~= nil then
                local zs = zdata[cellName]
                if type(zs) == 'string' then
                    local zl, zh = string.match(zs, '^(%-?%d+)|(%-?%d+)$')
                    zl = tonumber(zl)
                    zh = tonumber(zh)
                    if zl ~= nil and zh ~= nil and zh > zl + 50 then
                        mapState.zMin = zl
                        mapState.zMax = zh
                    end
                end
            end
            print(string.format('[TSP_VISGRID_V11] map: "%s" cap=%.0f z=%s..%s',
                tostring(cellName), mapState.cap,
                tostring(mapState.zMin or '?'), tostring(mapState.zMax or '?')))
        else
            print('[TSP_VISGRID_V11] map: no entry for "' .. tostring(cellName) .. '"')
        end
    end
    vdState.cmd = nil
    vdState.sent = nil
    vdState.sentEff = nil
    vdState.elapsed = 0.0
    gridMaybeArmed = true
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
    print('[TSP_VISGRID_V11] enter interior "' .. tostring(cellName)
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
    restoreViewDistance()
    gridMaybeArmed = false
    print('[TSP_VISGRID_V11] exit interior -> grid off')
end

local function onFrameBody(dt)
    if not haveBridge then return end
    if dt == nil or dt <= 0.0 then return end

    local cell = self.cell
    if cell == nil then return end

    -- First frame after any (re)load: disarm whatever the previous script
    -- instance left in the engine BEFORE deciding anything else, interior
    -- destination included. (The C++ grid store survives loads.)
    if justLoaded then
        justLoaded = false
        safeDisarm('post-load')
    end

    if cell.isExterior then
        postLoadArmRemaining = 0.0
        if inInterior then
            exitInterior()
        elseif gridMaybeArmed then
            safeDisarm('exterior-frame')
        end
        return
    end

    -- TSP_VISGRID_V11_LOADSAFE_12S
    if postLoadArmRemaining > 0.0 then
        postLoadArmRemaining = max(0.0, postLoadArmRemaining - dt)
        holdPrintElapsed = holdPrintElapsed + dt
        if postLoadArmRemaining > 0.0 then
            if holdPrintElapsed >= 3.0 then
                holdPrintElapsed = 0.0
                print(string.format(
                    '[TSP_VISGRID_V11] load-safe hold: %.1fs remaining',
                    postLoadArmRemaining))
            end
            return
        end
        print('[TSP_VISGRID_V11] load-safe hold complete -> VISGRID may arm')
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
        print('[TSP_VISGRID_V11] reset reason=cell-change')
    else
        local mx, my, mz = ex - (lastEx or ex), ey - (lastEy or ey), ez - (lastEz or ez)
        moveDist = sqrt(mx * mx + my * my + mz * mz)
        if moveDist > TELEPORT_RESET_DIST and interiorElapsed > LOAD_GRACE_SECONDS then
            enterInterior(cellName, ex, ey, ez)
            print('[TSP_VISGRID_V11] reset reason=teleport')
            moveDist = 0.0
        else
            transportTranslation(mx, my, mz, moveDist, ex, ey, ez)
            lastEx, lastEy, lastEz = ex, ey, ez
        end
    end

    -- TSP_V14: smoothed player speed. Drives the witness hold (W1) - and
    -- nothing else touches it, so a bad read just means "stationary".
    local sAlpha = dt / (V14.SPD_TAU + dt)
    vdState.spd = vdState.spd + ((moveDist / dt) - vdState.spd) * sAlpha

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
    publishGrid(ez)

    -- V14: expose turn state to the publish/accept paths (fast-close gate)
    vdState.turnf = turning and 1 or 0

    local budget = RAYS_STEADY
    if enterBurst > 0.0 or youngVisible > YOUNG_BURST_MIN then budget = RAYS_ENTER
    elseif turning or youngVisible > 0 then budget = RAYS_TURN end

    chooseAndCast(budget, ex, ey, ez, turning)

    -- A. analytically fill unsampled visible directions from the wall model
    planeFillPass(ex, ey, ez)

    -- V9.1 fog-follow: the far plane tracks the deepest published tile plus a
    -- margin. The engine's fog-follow patch keeps the fog wall glued to the
    -- far plane, so everything past the curtain fades exterior-style. The
    -- engine also clamps every request to >= the grid far floor - this
    -- controller can never clip published geometry even if it misjudges.
    -- V11: no projection control of any kind. The engine's V1 floor clamp
    -- guards outside writers; V3 percentile fog handles masking; this script
    -- only publishes the grid.

    if statusElapsed >= PRINT_PERIOD then
        statusElapsed = statusElapsed - PRINT_PERIOD
        printStatus(budget)
    end
end

local function onInit()
    resetRuntimeState()
    print(string.format(
        '[TSP_VISGRID_V11] onInit -> runtime state initialized; grid/fog held %.1fs',
        POST_LOAD_ARM_DELAY))
end

local function onLoad(_savedData, _initData)
    resetRuntimeState()
    print(string.format(
        '[TSP_VISGRID_V11] onLoad -> runtime state initialized; grid/fog held %.1fs',
        POST_LOAD_ARM_DELAY))
end

-- ======== V11 error containment ========
-- A scripting error must cost at most a few log lines - never the game.
-- The V10 device crash was an unhandled per-frame error repeating into the
-- engine's Lua error machinery until the VM's latent bug segfaulted.
local guardState = { dead = false, n = 0 }

local function guarded(name, fn, arg)
    if guardState.dead then return end
    local ok, err = pcall(fn, arg)
    if ok then return end
    guardState.n = guardState.n + 1
    print(string.format('[TSP_VISGRID_V11] %s ERROR #%d (%s): %s',
        name, guardState.n, type(err), tostring(err)))
    if guardState.n >= 3 then
        guardState.dead = true
        if haveBridge then pcall(camera.clearInteriorVisibilityGrid) end
        print('[TSP_VISGRID_V11] sensor DISABLED for this session after repeated errors; game continues without interior culling')
    end
end

print('[TSP_VISGRID_V11] V14 MAPSYNC sensor loaded (witness-hold + zcap + fast-close)')

return {
    engineHandlers = {
        onInit = function() guarded('onInit', onInit) end,
        onLoad = function(a) guarded('onLoad', onLoad, a) end,
        onFrame = function(dt) guarded('onFrame', onFrameBody, dt) end,
    },
}

TSPEOF_SENSOR_V14
cat > "$PKG/tsp_scan_to_map_v3.py" <<'TSPEOF_CONV_V14'
#!/usr/bin/env python3
# TSP scan -> interiormap.lua converter, FORMAT V3.
# V3 = the flat V2 caps PLUS one packed "minz|maxz" string per cell, giving
# the V14 sensor the cell's true vertical extent for its publish-time
# floor/ceiling caps (zcap). Heap cost over V2: one short interned string
# per cell (~1300 strings, tens of KB) - nowhere near the V1 subtable load.
# All other detail (full box, objects, doors, lights) stays in the scan file.
import sys, math

inp, outp = sys.argv[1], sys.argv[2]
cells = {}
zdata = {}
for line in open(inp, encoding='utf-8', errors='replace'):
    if not line.startswith('CELL\t'):
        continue
    parts = line.rstrip('\n').split('\t')
    if len(parts) < 7:
        continue
    name = parts[1]
    try:
        lo = [float(x) for x in parts[2].split()]
        hi = [float(x) for x in parts[3].split()]
        objects = int(parts[4])
    except ValueError:
        continue
    if objects < 3:
        continue
    dx, dy, dz = hi[0] - lo[0], hi[1] - lo[1], hi[2] - lo[2]
    diag = math.sqrt(dx * dx + dy * dy + dz * dz)
    cells[name] = max(1200.0, min(6200.0, diag * 1.05 + 400.0))
    if dz > 50.0:
        zdata[name] = '%d|%d' % (round(lo[2]), round(hi[2]))

def lq(s):
    return s.replace('\\', '\\\\').replace('"', '\\"')

with open(outp, 'w', encoding='utf-8') as f:
    f.write('-- TSP_INTERIOR_MAP_V3 - flat caps + per-cell z-range for the V14 zcap.\n')
    f.write('-- Details (full box, objects, doors, lights) live in tsp_interior_scan.txt.\n')
    f.write('return {\n  version = 3,\n  count = %d,\n  cells = {\n' % len(cells))
    for name in sorted(cells):
        f.write('    ["%s"] = %.0f,\n' % (lq(name), cells[name]))
    f.write('  },\n  z = {\n')
    for name in sorted(zdata):
        f.write('    ["%s"] = "%s",\n' % (lq(name), zdata[name]))
    f.write('  },\n}\n')

caps = sorted(cells.values())
print('cells kept: %d (%d with z-range)' % (len(cells), len(zdata)))
if caps:
    print('cap range : %.0f .. %.0f (median %.0f)' % (caps[0], caps[-1], caps[len(caps) // 2]))
TSPEOF_CONV_V14

echo "$SENSOR_MD5  $PKG/visgrid-v14.lua" | md5sum -c - >/dev/null \
    || { echo "ERROR: embedded sensor is corrupt (md5 mismatch - re-download this installer)"; false; }
echo "PASS: sensor payload intact ($SENSOR_MD5)"
echo "$CONV_MD5  $PKG/tsp_scan_to_map_v3.py" | md5sum -c - >/dev/null \
    || { echo "ERROR: embedded converter is corrupt (md5 mismatch - re-download this installer)"; false; }
python3 -c "compile(open('$PKG/tsp_scan_to_map_v3.py').read(), 'conv', 'exec')"
echo "PASS: converter payload intact ($CONV_MD5)"

echo
echo "===== 3/8 PULL SCAN FROM DEVICE + BUILD MAP V3 ====="
DEV_SCAN_MD5="$(ssh "$DEV" "md5sum '$SCAN'" | awk '{print $1}')"
ssh "$DEV" "cat '$SCAN'" > "$PKG/tsp_interior_scan.txt"
echo "$DEV_SCAN_MD5  $PKG/tsp_interior_scan.txt" | md5sum -c - >/dev/null \
    || { echo "ERROR: scan transfer corrupted (device $DEV_SCAN_MD5)"; false; }
grep -Fq 'TSP_INTERIOR_SCAN_051_V1' "$PKG/tsp_interior_scan.txt" \
    || { echo "ERROR: pulled file is not a TSP interior scan"; false; }
echo "scan cells        : $(grep -c '^CELL' "$PKG/tsp_interior_scan.txt")"
python3 "$PKG/tsp_scan_to_map_v3.py" "$PKG/tsp_interior_scan.txt" "$PKG/interiormap.lua"
grep -Fq 'TSP_INTERIOR_MAP_V3' "$PKG/interiormap.lua" \
    || { echo "ERROR: converter did not produce a v3 map"; false; }
if grep -Fq "Governor's Hall" "$PKG/interiormap.lua"; then
    echo "PASS: Caldera, Governor's Hall present in the map:"
    grep -F "Governor's Hall" "$PKG/interiormap.lua" | sed 's/^/    /'
else
    echo "WARN: Caldera, Governor's Hall not found in this scan's map (informational)"
fi
MAP_MD5="$(md5sum "$PKG/interiormap.lua" | awk '{print $1}')"
echo "map v3 built      : $MAP_MD5"
# future rescans (finish-interior-map.sh) should also produce v3
if [ -f "$TOOLS/tsp_scan_to_map.py" ]; then
    cp -p "$TOOLS/tsp_scan_to_map.py" "$TOOLS/tsp_scan_to_map.py.pre-v14-$STAMP"
fi
cp -p "$PKG/tsp_scan_to_map_v3.py" "$TOOLS/tsp_scan_to_map.py"
cp -p "$PKG/tsp_scan_to_map_v3.py" "$TOOLS/tsp_scan_to_map_v3.py"
echo "PASS: \$TOOLS/tsp_scan_to_map.py upgraded to v3 (old copy kept)."

echo
echo "===== 4/8 VERIFIED DEVICE BACKUP (hash -> copy -> hash -> compare) ====="
ssh "$DEV" "set -e
mkdir -p '$REMOTE_BACKUP'
H1=\$(md5sum '$LUA' | awk '{print \$1}')
cp -p '$LUA' '$REMOTE_BACKUP/visgrid.lua.before-v14'
H2=\$(md5sum '$REMOTE_BACKUP/visgrid.lua.before-v14' | awk '{print \$1}')
[ \"\$H1\" = \"\$H2\" ] || { echo 'ERROR: sensor backup copy mismatch'; exit 1; }
echo \"\$H1  visgrid.lua.before-v14\" > '$REMOTE_BACKUP/manifest.md5'
if [ -s '$MAPLUA' ]; then
    H3=\$(md5sum '$MAPLUA' | awk '{print \$1}')
    cp -p '$MAPLUA' '$REMOTE_BACKUP/interiormap.lua.before-v14'
    H4=\$(md5sum '$REMOTE_BACKUP/interiormap.lua.before-v14' | awk '{print \$1}')
    [ \"\$H3\" = \"\$H4\" ] || { echo 'ERROR: map backup copy mismatch'; exit 1; }
    echo \"\$H3  interiormap.lua.before-v14\" >> '$REMOTE_BACKUP/manifest.md5'
fi
sync
echo 'device backup verified:'
cat '$REMOTE_BACKUP/manifest.md5' | sed 's/^/    /'
"
# a second, VM-side copy of the same backup
ssh "$DEV" "cat '$REMOTE_BACKUP/visgrid.lua.before-v14'" > "$PKG/device-backup/visgrid.lua.before-v14"
ssh "$DEV" "cat '$REMOTE_BACKUP/manifest.md5'" > "$PKG/device-backup/manifest.md5"
if ssh "$DEV" "test -s '$REMOTE_BACKUP/interiormap.lua.before-v14'"; then
    ssh "$DEV" "cat '$REMOTE_BACKUP/interiormap.lua.before-v14'" > "$PKG/device-backup/interiormap.lua.before-v14"
fi
( cd "$PKG/device-backup" && md5sum -c manifest.md5 >/dev/null ) \
    || { echo "ERROR: VM-side backup copy does not match the device manifest"; false; }
echo "PASS: backups verified on device AND mirrored to $PKG/device-backup"

echo
echo "===== 5/8 TRANSACTIONAL DEPLOY ====="
scp -q "$PKG/visgrid-v14.lua" "$DEV:$LUA.new-v14"
scp -q "$PKG/interiormap.lua" "$DEV:$MAPLUA.new-v14"
ssh "$DEV" "set -e
H=\$(md5sum '$LUA.new-v14' | awk '{print \$1}')
[ \"\$H\" = '$SENSOR_MD5' ] || { echo \"ERROR: staged sensor md5 \$H != $SENSOR_MD5\"; exit 1; }
H=\$(md5sum '$MAPLUA.new-v14' | awk '{print \$1}')
[ \"\$H\" = '$MAP_MD5' ] || { echo \"ERROR: staged map md5 \$H != $MAP_MD5\"; exit 1; }
echo 'staged files verified on device'
"
DEPLOY_STARTED=1
ssh "$DEV" "set -e
mv -f '$LUA.new-v14' '$LUA'
mv -f '$MAPLUA.new-v14' '$MAPLUA'
sync
"
echo "PASS: sensor + map swapped in one window."

echo
echo "===== 6/8 VERIFY INSTALLED ====="
VOK=1
H="$(ssh "$DEV" "md5sum '$LUA'" | awk '{print $1}')"
if [ "$H" = "$SENSOR_MD5" ]; then echo "  PASS  sensor md5 $H"; else echo "  FAIL  sensor md5 $H != $SENSOR_MD5"; VOK=0; fi
H="$(ssh "$DEV" "md5sum '$MAPLUA'" | awk '{print $1}')"
if [ "$H" = "$MAP_MD5" ]; then echo "  PASS  map md5 $H"; else echo "  FAIL  map md5 $H != $MAP_MD5"; VOK=0; fi
for m in TSP_VISGRID_LUA_V14_MAPSYNC TSP_V14_WITNESS_HOLD TSP_V14_ZCAP TSP_VISGRID_V11_LOADSAFE_12S; do
    if ssh "$DEV" "grep -Fq '$m' '$LUA'"; then echo "  PASS  sensor marker $m"; else echo "  FAIL  sensor marker $m missing"; VOK=0; fi
done
if ssh "$DEV" "grep -Fq 'TSP_INTERIOR_MAP_V3' '$MAPLUA'"; then echo "  PASS  map marker TSP_INTERIOR_MAP_V3"; else echo "  FAIL  map marker missing"; VOK=0; fi
[ "$VOK" = "1" ] || { echo "ERROR: verification failed (named above)"; false; }
DEPLOY_STARTED=0
echo "PASS: install verified."

echo
echo "===== 7/8 ROLLBACK SCRIPT ====="
WRITE_ROLLBACK=1
if ssh "$DEV" "grep -Fq 'TSP_VISGRID_LUA_V14' '$REMOTE_BACKUP/visgrid.lua.before-v14'"; then
    if [ -f "$TOOLS/rollback-visgrid-v14.sh" ]; then
        echo "NOTE: device was already on V14 when this run backed it up;"
        echo "      keeping the existing rollback (true pre-V14 backup)."
        WRITE_ROLLBACK=0
    else
        echo "NOTE: this run's backup is already-V14 and no earlier rollback"
        echo "      exists; installing one that restores the pre-rerun state."
    fi
fi
if [ "$WRITE_ROLLBACK" = "1" ]; then
# quoted heredoc + placeholder substitution (no nested-escaping hazards)
cat > "$TOOLS/rollback-visgrid-v14.sh" <<'RBEOF'
#!/usr/bin/env bash
# Restores the device sensor + interior map exactly as they were before the
# V14 MAPSYNC install of @STAMP@ (verified against the backup manifest).
# The game binary was never touched by V14, so this is a full V14 rollback.
set -Eeuo pipefail
if [ -f "$HOME/Downloads/visgrid-tools/device.env" ]; then . "$HOME/Downloads/visgrid-tools/device.env" || true; fi
if [ -n "${TSP_IP:-}" ]; then DEV="root@$TSP_IP"; else DEV="${TSP_DEV:-root@192.168.1.25}"; fi
B="@REMOTE_BACKUP@"
# verify the backup against its manifest (explicit compare - no md5sum -c
# on the device, busybox may lack it), then restore, then confirm.
EXP_S="$(ssh "$DEV" "grep visgrid '$B/manifest.md5'" | awk '{print $1}')"
GOT_S="$(ssh "$DEV" "md5sum '$B/visgrid.lua.before-v14'" | awk '{print $1}')"
[ -n "$EXP_S" ] && [ "$EXP_S" = "$GOT_S" ] || { echo "ERROR: sensor backup corrupt ($GOT_S != $EXP_S)"; exit 1; }
HAVE_MAP=0
if ssh "$DEV" "test -s '$B/interiormap.lua.before-v14'"; then
    HAVE_MAP=1
    EXP_M="$(ssh "$DEV" "grep interiormap '$B/manifest.md5'" | awk '{print $1}')"
    GOT_M="$(ssh "$DEV" "md5sum '$B/interiormap.lua.before-v14'" | awk '{print $1}')"
    [ -n "$EXP_M" ] && [ "$EXP_M" = "$GOT_M" ] || { echo "ERROR: map backup corrupt"; exit 1; }
fi
ssh "$DEV" "set -e
cp -p '$B/visgrid.lua.before-v14' '@LUA@'
if [ -s '$B/interiormap.lua.before-v14' ]; then cp -p '$B/interiormap.lua.before-v14' '@MAPLUA@'; fi
sync"
NOW_S="$(ssh "$DEV" "md5sum '@LUA@'" | awk '{print $1}')"
[ "$NOW_S" = "$EXP_S" ] || { echo "ERROR: restore verify failed on sensor"; exit 1; }
if [ "$HAVE_MAP" = "1" ]; then
    NOW_M="$(ssh "$DEV" "md5sum '@MAPLUA@'" | awk '{print $1}')"
    [ "$NOW_M" = "$EXP_M" ] || { echo "ERROR: restore verify failed on map"; exit 1; }
fi
echo "ROLLBACK COMPLETE (sensor $NOW_S) - launch Morrowind_51 to confirm."
RBEOF
sed -i "s|@STAMP@|$STAMP|g; s|@REMOTE_BACKUP@|$REMOTE_BACKUP|g; s|@LUA@|$LUA|g; s|@MAPLUA@|$MAPLUA|g" \
    "$TOOLS/rollback-visgrid-v14.sh"
chmod +x "$TOOLS/rollback-visgrid-v14.sh"
bash -n "$TOOLS/rollback-visgrid-v14.sh"
echo "PASS: rollback at $TOOLS/rollback-visgrid-v14.sh"
fi

echo
echo "===== 8/8 DONE ====="
echo "Installed : sensor V14 MAPSYNC ($SENSOR_MD5)"
echo "            interior map v3    ($MAP_MD5)"
echo "Backup    : $REMOTE_BACKUP (device) + $PKG/device-backup (VM)"
echo "Rollback  : bash $TOOLS/rollback-visgrid-v14.sh"
echo
echo "NEXT - on the TrimUI, launch Morrowind_51 and:"
echo "  1. Load your Caldera save. Expect the load banner"
echo "     '[TSP_VISGRID_V11] V14 MAPSYNC sensor loaded' and, on entering,"
echo "     'map: \"Caldera, Governor's Hall\" cap=... z=...' in the log."
echo "  2. Walk the big hall: open rooms should STAY open while you move"
echo "     (no fog closing in), fog should only appear briefly at genuinely"
echo "     new sightlines."
echo "  3. Stand at the bad wall: the speedup should land in a few seconds"
echo "     (watch reject=% climb in the status lines)."
echo "  4. Pull results as usual:  bash ~/Downloads/pull-visgrid-perf.sh"
echo "     (unchanged - the status line kept its V11 prefix on purpose;"
echo "      new fields spd= zc= v14=1 are at the end of each line)"
echo
echo "A/B knobs (launcher env, unchanged from V13):"
echo "  TSP_VISGRID_FOG=0        fog off (culling only) - separates fog cost"
echo "  TSP_VISGRID_FOG_BORDER=N border-fog band (default 700)"
echo "  TSP_LUAJIT_JIT=1         re-enable the JIT (only after V14 proves"
echo "                           stable interpreted - one variable at a time)"
echo
echo "Log: $LOG"
