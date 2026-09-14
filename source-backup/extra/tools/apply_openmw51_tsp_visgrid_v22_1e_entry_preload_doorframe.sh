#!/usr/bin/env bash
set -Eeuo pipefail
cd "$HOME/Downloads"

DEV="${TSP_DEV:-root@192.168.1.25}"
CTR="${TSP_BUILDER:-openmw_builder}"
ROOT="/mnt/SDCARD/data/ports/openmw51"
MOD="$ROOT/mods/TSPInteriorVisGrid"
BASE="$MOD/scripts/TSPInteriorVisGrid"
LIVE_LUA="$BASE/visgrid.lua"
TOPOLOGY="$BASE/topology.lua"
TOPOLOGY_CELLS="$BASE/topology_cells"
DOORGRAPH="$BASE/doorgraph.lua"
DOORGRAPH_CELLS="$BASE/doorgraph_cells"
DB="/mnt/UDISK/openmw51-nav/navmesh.db"
GAME="$ROOT/bin/openmw-0.51"

EXPECTED_BASE_SHA="65d068f66936e4ee48a0747c403ead58151d61c6b0c320d745c2fac5e00dc866"
EXPECTED_NEW_SHA="bf5097ae5a5a668eb38802b8b9b67dc9ec3620e73d9b0a3fe0c2c5c19a524df4"
EXPECTED_GAME_SHA="5ba39a9869c592f1e21349521ad19fce0a04c6d03bb378c22170929c9792c555"
EXPECTED_DB_SIZE="934629376"
EXPECTED_DB_MTIME="1787961889"
EXPECTED_TOPO_SHARDS="1321"
EXPECTED_DOOR_SHARDS="1317"

STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="$HOME/Downloads/openmw51-visgrid-v22-1e-$STAMP"
PKG="$OUT/pkg"
LOG="$OUT/controller.log"
mkdir -p "$PKG"
exec > >(tee "$LOG") 2>&1

ROLLBACK_READY=0
REMOTE_BACKUP=""
BASE_SHA=""

on_error() {
    rc=$?
    trap - ERR
    set +e
    echo
    echo "=================================================================="
    echo "V22.1E CONTROLLER STOPPED (rc=$rc)"
    echo "=================================================================="
    if [ "$ROLLBACK_READY" = "1" ] && [ -n "$REMOTE_BACKUP" ]; then
        echo "Attempting automatic sensor rollback..."
        ssh -o BatchMode=yes -o ConnectTimeout=8 "$DEV" "
            set -e
            test -s '$REMOTE_BACKUP'
            cp -p '$REMOTE_BACKUP' '$LIVE_LUA'
            sync
            test \"\$(sha256sum '$LIVE_LUA' | awk '{print \$1}')\" = '$EXPECTED_BASE_SHA'
        " && echo "PASS: exact V22.1D sensor restored." || echo "WARNING: automatic rollback could not be verified."
    else
        echo "No device install had begun; nothing to roll back."
    fi
    echo "Controller log preserved at: $LOG"
    exit "$rc"
}
trap on_error ERR

echo "=================================================================="
echo "OPENMW 0.51 — VISGRID V22.1E ENTRY PRELOAD + DOOR-FRAME HALO"
echo "=================================================================="
echo "Exact base required: V22.1D $EXPECTED_BASE_SHA"
echo "Exact output:        V22.1E $EXPECTED_NEW_SHA"
echo
echo "This revision targets the two faults isolated by the V22.1D trace:"
echo "  1) new-cell hall/stair red/fog while structural PVS was already OFF"
echo "  2) rendered load door with red adjoining frame because the door's"
echo "     source topology sector was not resident"
echo
echo "V22.1E behavior:"
echo "  - first 6.0s after interior->interior load: VISGRID and topology PVS"
echo "    are fail-open, but the ray sensor keeps learning at entry budget"
echo "  - up to 12 physically nearest topology sectors within 1350 units are"
echo "    preloaded for 8s, covering immediate turns/stairs/halls"
echo "  - nearby real door source sectors are also preloaded on arrival"
echo "  - after arrival, nearby TELEPORT/load-door source sectors stay alive"
echo "    so a door cannot render without its frame/wall sector"
echo
echo "No OpenMW-running process gate is used. Restart OpenMW after install."
echo "No binary, global topology, door graph, or canonical navmesh DB is modified."
echo "=================================================================="

echo
echo "===== 1/7 VERIFY EXACT CURRENT DEVICE STATE ====="
ssh -o BatchMode=yes -o ConnectTimeout=8 "$DEV" "
    set -e
    test -s '$LIVE_LUA'
    test -s '$GAME'
    test -s '$TOPOLOGY'
    test -d '$TOPOLOGY_CELLS'
    test -s '$DOORGRAPH'
    test -d '$DOORGRAPH_CELLS'
    test -s '$DB'
    grep -Fq 'TSP_VISGRID_LUA_V22_1D_INTERCELL_PVS_QUARANTINE' '$LIVE_LUA'
    grep -Fq 'TSP_VISGRID_GLOBAL_TOPOLOGY_V1' '$TOPOLOGY'
    grep -Fq 'TSP_VISGRID_REAL_DOOR_GRAPH_V1' '$DOORGRAPH'
"

# Normalize machine-readable SSH output before exact comparisons.
# This remains fail-closed, but avoids invisible CR/spacing from BusyBox/coreutils
# making a visibly-correct value fail a raw shell-string comparison.
BASE_SHA="$(ssh "$DEV" "sha256sum '$LIVE_LUA'" | awk 'NF {print $1; exit}' | tr -d '\r')"
GAME_SHA_BEFORE="$(ssh "$DEV" "sha256sum '$GAME'" | awk 'NF {print $1; exit}' | tr -d '\r')"
TOPO_SHA_BEFORE="$(ssh "$DEV" "sha256sum '$TOPOLOGY'" | awk 'NF {print $1; exit}' | tr -d '\r')"
DOOR_SHA_BEFORE="$(ssh "$DEV" "sha256sum '$DOORGRAPH'" | awk 'NF {print $1; exit}' | tr -d '\r')"
DB_STAT_BEFORE="$(ssh "$DEV" "stat -c '%s %Y' '$DB'" | awk 'NF >= 2 {print $1, $2; exit}' | tr -d '\r')"
TOPO_COUNT_BEFORE="$(ssh "$DEV" "find '$TOPOLOGY_CELLS' -maxdepth 1 -type f -name 'c_*.lua' | wc -l" | awk 'NF {print $1; exit}' | tr -d '\r')"
DOOR_COUNT_BEFORE="$(ssh "$DEV" "find '$DOORGRAPH_CELLS' -maxdepth 1 -type f -name 'c_*.lua' | wc -l" | awk 'NF {print $1; exit}' | tr -d '\r')"

echo "sensor SHA:       $BASE_SHA"
echo "game SHA:         $GAME_SHA_BEFORE"
echo "topology SHA:     $TOPO_SHA_BEFORE"
echo "doorgraph SHA:    $DOOR_SHA_BEFORE"
echo "DB size/mtime:    $DB_STAT_BEFORE"
echo "topology shards:  $TOPO_COUNT_BEFORE"
echo "doorgraph shards: $DOOR_COUNT_BEFORE"

assert_exact() {
    local label="$1" actual="$2" expected="$3"

    if [[ "$actual" != "$expected" ]]; then
        printf 'ERROR: %s invariant mismatch.\n' "$label" >&2
        printf '  actual:   %q  (len=%d)\n' \
            "$actual" "${#actual}" >&2
        printf '  expected: %q  (len=%d)\n' \
            "$expected" "${#expected}" >&2
        return 1
    fi

    printf 'PASS: %s invariant exact.\n' "$label"
}

assert_exact "V22.1D sensor SHA" \
    "$BASE_SHA" "$EXPECTED_BASE_SHA"

assert_exact "game SHA" \
    "$GAME_SHA_BEFORE" "$EXPECTED_GAME_SHA"

assert_exact "navmesh DB size/mtime" \
    "$DB_STAT_BEFORE" "$EXPECTED_DB_SIZE $EXPECTED_DB_MTIME"

assert_exact "topology shard count" \
    "$TOPO_COUNT_BEFORE" "$EXPECTED_TOPO_SHARDS"

assert_exact "doorgraph shard count" \
    "$DOOR_COUNT_BEFORE" "$EXPECTED_DOOR_SHARDS"

echo "PASS: exact V22.1D base + protected invariants verified."

scp -q "$DEV:$LIVE_LUA" "$PKG/visgrid-v22.1d.lua"
[ "$(sha256sum "$PKG/visgrid-v22.1d.lua" | awk '{print $1}')" = "$EXPECTED_BASE_SHA" ]

echo
echo "===== 2/7 MATERIALIZE EXACT V22.1E SENSOR ====="
cat > "$PKG/visgrid-v22.1e.lua" <<'EOF_V221E_SENSOR'
-- TSP_VISGRID_LUA_V20_THRESHOLD_LATCH  (structural PVS + live-ray authority)
-- TSP_VISGRID_LUA_V21_DOORGRAPH_VIEWHOLD  (real-door overlay + view-relative positive-ray memory)
-- TSP_VISGRID_LUA_V21_1_STABLE_APERTURE  (camera-turn freeze + exact-witness disproof)
-- TSP_VISGRID_LUA_V22_RESIDENT_SECTORS  (bounded resident room-groups + additive ray promotion)
-- TSP_VISGRID_LUA_V22_1_UPWARD_ANTICIPATION  (camera-Z momentum + vertical predictive rays)
-- TSP_VISGRID_LUA_V22_1D_INTERCELL_PVS_QUARANTINE  (cell-local purge + fail-open PVS + deep transition diagnostics)
-- TSP_VISGRID_LUA_V22_1E_ENTRY_PRELOAD_DOORFRAME  (learn-first entry + local-sector preload + door-frame halo)
-- Based on V14; old scalar map cap/zcap is disabled.
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
local DOOR_POLL_PERIOD = 0.12
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
local mapState = {
    cells = nil, zdata = nil, cap = 6200.0, zMin = nil, zMax = nil,
    topology = nil, topoCell = nil, topoSector = nil, topoSectorId = 0,
    topoKind = 'unmapped', topoFloor = 0,
    topoCandidate = 0, topoCandidateFrames = 0,
    topoCandidateTime = 0.0, topoDwell = 0.0,
    topoSwitches = 0, topoPortalHints = 0,
    topoPortalPoll = 0.0, topoPortalNext = {},
    topoX = nil, topoY = nil, topoZ = nil,

    -- V17: navmesh topology becomes a structural PVS provider.
    pvsBoxes = nil, pvsSectorCount = 0, pvsSignature = nil,
    pvsPortalSector = 0, pvsPortalUntil = 0.0, pvsActiveCount = 0,
    pvsRecent = {}, pvsRecentActive = 0, pvsRefreshElapsed = 0.0,
    pvsDoorPair = {}, pvsProbeCount = 0, pvsProbeClear = 0,
    rayPortalChecks = 0, rayPortalOpens = 0, proximityOpens = 0,
    doorProtectDepth = {}, doorProtectUntil = {}, doorProtectSeen = 0,

    -- V20 symmetric threshold memory.  Each mapped portal can keep BOTH sides
    -- structurally alive across a crossing/turn-around instead of remembering
    -- only one destination sector.
    portalLatches = {}, portalLatchCount = 0, portalLatchTouches = 0,
    transitionOpenUntil = 0.0, transitionOld = 0, transitionNew = 0,
    transitionOpens = 0,

    -- V21 real ESM/ESP door overlay.  The sidecar stays optional: missing
    -- door data can never disable the proven topology/raycast fallback.
    doorGraph = nil, realDoors = nil, realDoorCount = 0,
    realDoorPortalMatches = 0, realDoorWorldExits = 0,
    realDoorTargetSectors = 0,

    -- V21 positive-ray view memory.  A verified narrow opening stays
    -- authoritative while its angular region remains in view.  Several
    -- convincing close rays can retire it; looking away releases it quickly.
    rayViewHolds = {}, rayViewHoldCount = 0, rayViewHoldTouches = 0,
    rayViewHoldCloseReleases = 0, rayViewHoldAwayReleases = 0,
    rayViewHoldVerifyReleases = 0,
    rayViewHoldJumpDefers = 0, rayViewHoldTurnSkips = 0,

    -- V22 resident room-groups. Current room is always structural; up to three
    -- non-current groups are retained and replaced only by stronger/newer rooms.
    -- A group is a seed sector plus its safe connector/embedded-room envelope.
    residentSectors = {}, residentCount = 0, residentPromotions = 0,
    residentRayPromotions = 0, residentPredictions = 0, residentRecent = 0,
    residentEvictions = 0, residentOverflows = 0, residentRejects = 0,
    residentRayFinds = 0, residentDepthTouches = 0,
    moveDirX = 0.0, moveDirY = 0.0, moveDirZ = 0.0,

    -- V22.1 upward-look anticipation. Camera center-vector Z velocity is the
    -- controller/mouse-independent right-stick signal. A short speculative
    -- upper-screen depth floor gives tall shafts/towers time to populate; fresh
    -- close ceiling rays cancel it quickly, while deep/miss rays reinforce it.
    upLookLastZ = nil, upLookRate = 0.0, upBoostUntil = 0.0,
    upBoostStrength = 0.0, upBlockedUntil = 0.0, upCloseRun = 0, upOpenRun = 0,
    upBoostEvents = 0, upPredictCasts = 0, upDeepReports = 0,
    upPullbacks = 0, upFloorApplications = 0,

    -- V22.1D interior->interior correctness gate. PVS sector IDs, recent-room
    -- tails, portal latches and the C++ visibility stores are CELL-LOCAL and
    -- must never bleed across a load door. A destination that initially proves
    -- only one sector out of a larger topology fails OPEN (PVS disabled) until
    -- ray/movement evidence grows the justified set to at least two sectors.
    holdCellName = nil, pendingIntercellSource = nil, pendingIntercellDest = nil,
    pendingIntercellDuringHold = false,
    intercellSource = nil, intercellDest = nil, intercellDuringHold = false,
    intercellPvsQuarantine = false, intercellEntrySector = 0,
    intercellShadowPvsCount = 0, intercellShadowPvsIds = '',
    intercellLastShadowPvsIds = '', intercellTransitions = 0,
    intercellPurges = 0, intercellPvsReleases = 0,
    intercellDebugDumps = 0,

    -- V22.1E correctness state. During an interior load-door arrival the
    -- ordinary VISGRID curtain is learn-only for a few seconds: it still
    -- computes screen bins and casts rays, but is not allowed to cull. The
    -- topology PVS is held fail-open for the same window. A bounded local
    -- sector preload covers the immediate turn/stair/hall area, while real
    -- load-door source sectors stay resident whenever the player is nearby so
    -- the door mesh cannot survive without its adjoining frame/wall geometry.
    intercellGridLearnUntil = 0.0, intercellPvsReleaseAfter = 0.0,
    intercellGridSuppressFrames = 0, intercellGridLearnEnds = 0,
    intercellEntryNearUntil = {}, intercellEntryNearCount = 0,
    intercellEntryNearSignature = '',
    realDoorSourceUntil = {}, realDoorSourceCount = 0,
    realDoorSourceTouches = 0, realDoorSourceChanges = 0,
    realDoorSourceSignature = '',

    pvsBridge = type(camera.setInteriorTopologyPvs) == 'function'
        and type(camera.clearInteriorTopologyPvs) == 'function',

    -- Revert V16's 250 padding. It created staircase-corner fog.
    v16TightPadding = 350.0,
    v16LargeOpenMinDepth = 2600.0,
    v16SectorHoldNormal = 0.45,
    v16SectorHoldConnector = 0.65,
    v16MinSectorDwell = 0.75,

    -- Faster topology portal attention + a dedicated large-room traversal
    -- wedge so the destination is drawable BEFORE the player steps inside.
    v16PortalPollPeriod = 0.12,
    v16PortalRehint = 0.45,
    v16PortalGrace = 0.40,
    v16DoorRange = 750.0,
    v16BoundaryRange = 480.0,
    v17LargePortalRange = 1350.0,
    v17LargePortalGrace = 1.10,
    v17DoorPortalGrace = 0.85,

    -- V18 room traversal policy.
    v18TailGrace = 1.35,
    v18PvsRefresh = 0.10,
    v18DoorRange = 1300.0,
    v18LargeRange = 1900.0,
    v18BoundaryRange = 760.0,
    v18DoorGrace = 1.45,
    v18LargeGrace = 1.85,
    v18BoundaryGrace = 0.80,
    v18PortalProbeBeyond = 1800.0,
    v18PortalProbeMargin = 130.0,
    v18PortalBurst = 0.90,
    v18LargeEmbedPad = 80.0,

    -- V19: the successful V17/V18 PVS remains the backbone.  The ordinary
    -- VISGRID rays are now authoritative opening witnesses: if one reaches
    -- beyond a mapped portal, the destination sector opens immediately.
    v19RayPortalMargin = 70.0,
    v19RayPortalDoorGrace = 1.65,
    v19RayPortalLargeGrace = 2.10,
    v19RayPortalBoundaryGrace = 1.20,
    v19DoorPrefetchRange = 900.0,
    v19LargePrefetchRange = 1850.0,
    v19BoundaryPrefetchRange = 760.0,
    v19NearPortalHoldDoor = 560.0,
    v19NearPortalHoldLarge = 900.0,
    v19NearPortalHoldOther = 420.0,
    v19NearPortalHoldSeconds = 0.70,

    -- Door meshes themselves must NEVER disappear behind the depth curtain.
    -- This is deliberately a depth floor only (door distance + margin), not
    -- OPEN_DEPTH, so a closed load door does not render the whole world behind it.
    v19DoorProtectRange = 2400.0,
    v19DoorProtectMargin = 520.0,
    v19DoorProtectTtl = 0.38,

    -- Once topology says we're physically in a large/open chamber, let that
    -- chamber breathe.  Structural PVS now handles hidden rooms/floors.
    v19LargeOpenMinDepth = 3600.0,

    -- V20 threshold policy.  The map is deliberately allowed to spend a
    -- little more rendering only around the ONE portal the player is actually
    -- traversing.  This avoids red turn-around frames without reopening floors.
    v20NearDoor = 760.0,
    v20NearLarge = 1250.0,
    v20NearBoundary = 640.0,
    v20NearLatchSeconds = 1.80,
    v20RayLatchSeconds = 2.35,
    v20CrossLatchSeconds = 2.20,
    v20VisibleNearGrace = 0.90,
    v20TransitionOpenSeconds = 1.20,
    v20TransitionMinDepth = 6200.0,

    -- V21 view-relative positive-ray memory.  Unverified openings receive
    -- only a short bridge until the existing exact-direction verifier runs.
    -- Verified openings have no dumb fixed timeout while still on-screen:
    -- view-away or three close confirmations release them instead.
    -- V22 unmapped-cell fallback: a positively proven aperture cannot be
    -- revoked for at least five seconds. V21.1's 2.5s dormant camera memory
    -- and exact-witness-only disproof remain intact.
    v21RayHoldInitial = 5.00,
    -- V21.1: do not erase a proven aperture just because the camera sweeps
    -- past it. Off-screen holds are dormant (they render nothing) and are
    -- retired only after the view has been stably elsewhere for a while.
    v21RayHoldAwayGrace = 2.50,
    -- Neighbor jitter rays are expected to hit the wall/roof AROUND a narrow
    -- slit, so they are no longer allowed to vote the slit closed.
    v21RayHoldCloseVotes = 3,
    v21RayHoldCloseDrop = 280.0,
    v21RayHoldPositiveTol = 180.0,
    -- A large discontinuous depth collapse is suspicious. Require stronger
    -- exact-witness evidence before accepting that the deep space vanished.
    v21RayHoldJumpDrop = 1200.0,
    v21RayHoldJumpMisses = 5,
    v21RayHoldYawSpread = 1,
    v21RayHoldPitchSpread = 1,
    v21RayHoldPriority = 14,

    -- Real-door overlay policy.  Only non-teleport/local ESM doors may
    -- reclassify a nearby static boundary portal.  Teleport/load doors are
    -- WORLD_EXIT edges: protect the door itself but never PVS-open a fake
    -- same-cell destination.
    v21DoorPortalMatch = 420.0,
    v21RealDoorProtectRange = 2600.0,
    v21RealDoorProtectMargin = 560.0,
    v21RealDoorProtectTtl = 0.45,

    -- V22 working-set policy. Three non-current seeds + current room means the
    -- common case is roughly 3-4 resident room-groups. Positive evidence grants
    -- a hard five-second minimum; after that a room is evicted only when a new
    -- candidate needs its slot. Protected overlaps may temporarily grow to five.
    v22ResidentTarget = 3,
    v22ResidentHardMax = 5,
    v22ResidentMinHold = 5.00,
    v22RayMinDepth = 850.0,
    v22RaySampleNear = 0.42,
    v22RaySampleMid = 0.62,
    v22RaySampleFar = 0.82,
    v22RaySampleEnd = 0.94,
    v22ResidentYawSpread = 2,
    v22ResidentPitchSpread = 2,
    v22PortalDepthPad = 1800.0,
    v22MovePrefetchDot = 0.42,
    v22MovePrefetchMult = 1.35,

    -- V22.1 upward anticipation. We intentionally key off change in the live
    -- center view vector, not a controller API, so right-stick and mouse behave
    -- identically. Speculation is brief and bounded; real ray evidence wins.
    v221UpRateTrigger = 0.30,       -- normalized view-Z / second
    v221UpRateStrong = 1.05,        -- reaches full speculative strength
    v221UpHold = 0.72,              -- seconds after a fast upward look
    v221UpDeepHold = 1.10,          -- deep upper ray extends anticipation
    v221UpPitchStart = -5.0,        -- begin just before tile points above horizon
    v221UpFloorMin = 2800.0,        -- conservative speculative floor
    v221UpFloorMax = 5600.0,        -- never OPEN_DEPTH without real evidence
    v221UpOpenDepth = 1900.0,       -- upper ray this deep reinforces open space
    v221UpCeilingDepth = 900.0,     -- close upper hit votes for ceiling
    v221UpCeilingNeed = 3,          -- three fresh close reports pull back
    v221UpBlockedHold = 0.35,      -- stop immediate re-boost after solid ceiling
    v221UpPredictBins = 2,          -- pitch bins ahead of center
    v221UpExtraRays = 2,            -- only during brief upward anticipation

    -- V22.1D: an interior load-door destination with a large topology may not
    -- arm structural PVS from a lone isolated sector. This is deliberately a
    -- correctness-first fail-open rule, analogous to the proven exterior-frame
    -- safeDisarm path. VISGRID rays continue to work while PVS is quarantined.
    v221dPvsMinIds = 2,
    v221dLargeTopologyMin = 6,

    -- V22.1E. The diagnostic proved two independent problems:
    --  (1) South Wall still fogged with structural PVS completely disabled,
    --      so the ordinary depth curtain must learn before it may cull;
    --  (2) the Fort return door is physically in source sector 22 while the
    --      active PVS near the top of the stair was only sectors 15/16, so the
    --      door mesh survived its adjoining frame sector.
    v221eGridLearnGrace = 6.0,
    v221eEntryNearRange = 1350.0,
    v221eEntryNearMax = 12,
    v221eEntryNearHold = 8.0,
    v221eArrivalDoorSourceRange = 1400.0,
    v221eLoadDoorSourceRange = 1800.0,
    v221eDoorSourceTtl = 1.25,

    -- Conservative static-object/sector overlap margins in the C++ PVS.
    v17PvsXyPad = 160.0,
    v17PvsZPad = 110.0,
}
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
do
    local okTopo, t = pcall(require, 'scripts.TSPInteriorVisGrid.topology')
    if okTopo and type(t) == 'table' and type(t.cells) == 'table'
        and type(t.findSector) == 'function' then
        mapState.topology = t
        print(string.format(
            '[TSP_VISGRID_V15] topology loaded: format v%s source=%s',
            tostring(t.version or '?'), tostring(t.source_sha256 or '?')))
    else
        print('[TSP_VISGRID_V15] no topology module - raycast-only mode')
    end
end
do
    mapState.doorGraphLoadOk, mapState.doorGraph
        = pcall(require, 'scripts.TSPInteriorVisGrid.doorgraph')
    if mapState.doorGraphLoadOk
        and type(mapState.doorGraph) == 'table'
        and type(mapState.doorGraph.getCell) == 'function' then
        print(string.format(
            '[TSP_VISGRID_V21] real door graph loaded: format v%s refs=%s cells=%s',
            tostring(mapState.doorGraph.version or '?'),
            tostring(mapState.doorGraph.count or '?'),
            tostring(mapState.doorGraph.cellCount or '?')))
    else
        mapState.doorGraph = nil
        print('[TSP_VISGRID_V21] no real door graph - topology/raycast fallback unchanged')
    end
end
mapState.cap = OPEN_DEPTH    -- V15: kept only for diagnostics; never clamps rays

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
local lastPvsTested, lastPvsCulled = 0.0, 0.0
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
-- TSP_VISGRID_V20_LOADSAFE_6S
local POST_LOAD_ARM_DELAY = 6.0
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
    mapState.topoCell = nil
    mapState.topoSector = nil
    mapState.topoSectorId = 0
    mapState.topoKind = 'unmapped'
    mapState.topoFloor = 0
    mapState.topoCandidate = 0
    mapState.topoCandidateFrames = 0
    mapState.topoCandidateTime = 0.0
    mapState.topoDwell = 0.0
    mapState.topoPortalHints = 0
    mapState.pvsBoxes = nil
    mapState.pvsSectorCount = 0
    mapState.pvsSignature = nil
    mapState.pvsPortalSector = 0
    mapState.pvsPortalUntil = 0.0
    mapState.pvsActiveCount = 0
    mapState.pvsRecent = {}
    mapState.pvsRecentActive = 0
    mapState.pvsRefreshElapsed = 0.0
    mapState.pvsDoorPair = {}
    mapState.pvsProbeCount = 0
    mapState.pvsProbeClear = 0
    mapState.rayPortalChecks = 0
    mapState.rayPortalOpens = 0
    mapState.proximityOpens = 0
    mapState.doorProtectDepth = {}
    mapState.doorProtectUntil = {}
    mapState.doorProtectSeen = 0
    mapState.portalLatches = {}
    mapState.portalLatchCount = 0
    mapState.portalLatchTouches = 0
    mapState.transitionOpenUntil = 0.0
    mapState.transitionOld = 0
    mapState.transitionNew = 0
    mapState.transitionOpens = 0
    mapState.realDoors = nil
    mapState.realDoorCount = 0
    mapState.realDoorPortalMatches = 0
    mapState.realDoorWorldExits = 0
    mapState.realDoorTargetSectors = 0
    mapState.rayViewHolds = {}
    mapState.rayViewHoldCount = 0
    mapState.rayViewHoldTouches = 0
    mapState.rayViewHoldCloseReleases = 0
    mapState.rayViewHoldAwayReleases = 0
    mapState.rayViewHoldVerifyReleases = 0
    mapState.rayViewHoldJumpDefers = 0
    mapState.rayViewHoldTurnSkips = 0
    mapState.residentSectors = {}
    mapState.residentCount = 0
    mapState.residentPromotions = 0
    mapState.residentRayPromotions = 0
    mapState.residentPredictions = 0
    mapState.residentRecent = 0
    mapState.residentEvictions = 0
    mapState.residentOverflows = 0
    mapState.residentRejects = 0
    mapState.residentRayFinds = 0
    mapState.residentDepthTouches = 0
    mapState.moveDirX, mapState.moveDirY, mapState.moveDirZ = 0.0, 0.0, 0.0
    mapState.upLookLastZ = nil
    mapState.upLookRate = 0.0
    mapState.upBoostUntil = 0.0
    mapState.upBoostStrength = 0.0
    mapState.upBlockedUntil = 0.0
    mapState.upCloseRun = 0
    mapState.upOpenRun = 0
    mapState.upBoostEvents = 0
    mapState.upPredictCasts = 0
    mapState.upDeepReports = 0
    mapState.upPullbacks = 0
    mapState.upFloorApplications = 0
    mapState.holdCellName = nil
    mapState.pendingIntercellSource = nil
    mapState.pendingIntercellDest = nil
    mapState.pendingIntercellDuringHold = false
    mapState.intercellSource = nil
    mapState.intercellDest = nil
    mapState.intercellDuringHold = false
    mapState.intercellPvsQuarantine = false
    mapState.intercellEntrySector = 0
    mapState.intercellShadowPvsCount = 0
    mapState.intercellShadowPvsIds = ''
    mapState.intercellLastShadowPvsIds = ''
    mapState.intercellTransitions = 0
    mapState.intercellPurges = 0
    mapState.intercellPvsReleases = 0
    mapState.intercellDebugDumps = 0
    mapState.intercellGridLearnUntil = 0.0
    mapState.intercellPvsReleaseAfter = 0.0
    mapState.intercellGridSuppressFrames = 0
    mapState.intercellGridLearnEnds = 0
    mapState.intercellEntryNearUntil = {}
    mapState.intercellEntryNearCount = 0
    mapState.intercellEntryNearSignature = ''
    mapState.realDoorSourceUntil = {}
    mapState.realDoorSourceCount = 0
    mapState.realDoorSourceTouches = 0
    mapState.realDoorSourceChanges = 0
    mapState.realDoorSourceSignature = ''
    gridMaybeArmed = true   -- engine grid state unknown after any (re)load:
                            -- the first frame outside our control disarms it
    justLoaded = true       -- first frame disarms BEFORE any enter logic
    postLoadArmRemaining = POST_LOAD_ARM_DELAY  -- TSP_VISGRID_V20_LOADSAFE_6S
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
    lastPvsTested, lastPvsCulled = 0.0, 0.0
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


-- ======== V22.1: upward-look anticipation ========
-- The live center view vector is effectively the post-input camera stick. Using
-- its Z velocity avoids controller-binding assumptions and also works with mouse.
-- A fast upward sweep briefly pre-opens only upward-facing screen tiles and casts
-- two pitch-leading rays. Three fresh close ceiling reports cancel speculation;
-- a deep/miss report reinforces it and lets V22's normal resident-sector logic
-- promote whatever real upper room/shaft the ray actually reaches.
mapState.updateUpwardAnticipation = function(dt)
    if dt == nil or dt <= 0.0 then return end
    local ok, d = pcall(camera.viewportToWorldVector, util.vector2(0.5, 0.5))
    if not ok or d == nil then return end
    local len = sqrt(d.x*d.x + d.y*d.y + d.z*d.z)
    if len <= 0.0001 then return end
    local vz = d.z / len
    local prev = mapState.upLookLastZ
    mapState.upLookLastZ = vz
    if prev == nil then
        mapState.upLookRate = 0.0
        return
    end

    local rate = (vz - prev) / dt
    mapState.upLookRate = rate

    if rate > mapState.v221UpRateTrigger
        and (mapState.upBlockedUntil or 0.0) <= interiorElapsed then
        local wasActive = (mapState.upBoostUntil or 0.0) > interiorElapsed
        if not wasActive then
            mapState.upCloseRun = 0
            mapState.upOpenRun = 0
            mapState.upBoostEvents = mapState.upBoostEvents + 1
        end
        local denom = mapState.v221UpRateStrong - mapState.v221UpRateTrigger
        local strength = denom > 0.001
            and (rate - mapState.v221UpRateTrigger) / denom or 1.0
        if strength < 0.18 then strength = 0.18 elseif strength > 1.0 then strength = 1.0 end
        mapState.upBoostStrength = max(mapState.upBoostStrength or 0.0, strength)
        mapState.upBoostUntil = max(mapState.upBoostUntil or 0.0,
            interiorElapsed + mapState.v221UpHold)
    elseif rate < -mapState.v221UpRateStrong then
        -- A decisive downward reversal ends speculative Z look-ahead quickly.
        mapState.upBoostUntil = min(mapState.upBoostUntil or 0.0, interiorElapsed + 0.12)
    end

    if (mapState.upBoostUntil or 0.0) <= interiorElapsed then
        mapState.upBoostStrength = 0.0
        mapState.upCloseRun = 0
        mapState.upOpenRun = 0
    end
end

mapState.observeUpwardRay = function(idx, observedDepth, wasMiss, rayLen)
    if idx == nil then return end
    local z = binDirZ[idx]
    if z == nil or z < 0.17 then return end

    local active = (mapState.upBoostUntil or 0.0) > interiorElapsed
    local rising = (mapState.upLookRate or 0.0) > 0.08
    if not active and not rising then return end

    local depth = observedDepth or 0.0
    if wasMiss then depth = max(depth, rayLen or 0.0) end

    if wasMiss or depth >= mapState.v221UpOpenDepth then
        if not active then
            mapState.upBoostEvents = mapState.upBoostEvents + 1
        end
        mapState.upOpenRun = min(8, (mapState.upOpenRun or 0) + 1)
        mapState.upCloseRun = max(0, (mapState.upCloseRun or 0) - 2)
        mapState.upDeepReports = mapState.upDeepReports + 1
        mapState.upBlockedUntil = 0.0
        mapState.upBoostStrength = max(mapState.upBoostStrength or 0.0, 0.82)
        mapState.upBoostUntil = max(mapState.upBoostUntil or 0.0,
            interiorElapsed + mapState.v221UpDeepHold)
        return
    end

    if depth <= mapState.v221UpCeilingDepth then
        mapState.upCloseRun = (mapState.upCloseRun or 0) + 1
        local need = mapState.v221UpCeilingNeed
        if (mapState.upOpenRun or 0) > 0 then need = need + 2 end
        if mapState.upCloseRun >= need then
            mapState.upBoostUntil = min(mapState.upBoostUntil or 0.0, interiorElapsed + 0.08)
            mapState.upBoostStrength = min(mapState.upBoostStrength or 0.0, 0.12)
            mapState.upBlockedUntil = interiorElapsed + mapState.v221UpBlockedHold
            mapState.upPullbacks = mapState.upPullbacks + 1
            mapState.upCloseRun = 0
            mapState.upOpenRun = 0
        end
    else
        mapState.upCloseRun = max(0, (mapState.upCloseRun or 0) - 1)
    end
end

mapState.upwardSpecDepth = function(pitchDeg)
    if pitchDeg == nil or pitchDeg < mapState.v221UpPitchStart then return nil end
    if (mapState.upBoostUntil or 0.0) <= interiorElapsed then return nil end
    local strength = mapState.upBoostStrength or 0.0
    if strength <= 0.0 then return nil end

    local pw = (pitchDeg - mapState.v221UpPitchStart) / 50.0
    if pw < 0.0 then pw = 0.0 elseif pw > 1.0 then pw = 1.0 end
    pw = 0.35 + 0.65 * pw
    local d = mapState.v221UpFloorMin
        + (mapState.v221UpFloorMax - mapState.v221UpFloorMin) * strength * pw
    if (mapState.upOpenRun or 0) > 0 then d = d + 350.0 end
    if d > mapState.v221UpFloorMax then d = mapState.v221UpFloorMax end
    return d
end

-- ======== V21: view-relative positive-ray memory ========
-- The panorama bins are world-anchored.  That lets a successful ray own a
-- small angular region without screen-space bookkeeping: as long as that bin
-- (or a close neighbor) remains in the current view, the live positive result
-- can override offline vertical caps.  Turning away releases it quickly.

mapState.rayViewBinsClose = function(a, b)
    if a == nil or b == nil then return false end
    local aby = (a - 1) % YAW_BINS
    local abp = floor((a - 1) / YAW_BINS)
    local bby = (b - 1) % YAW_BINS
    local bbp = floor((b - 1) / YAW_BINS)
    local dy = abs(aby - bby)
    dy = min(dy, YAW_BINS - dy)
    return dy <= mapState.v21RayHoldYawSpread
        and abs(abp - bbp) <= mapState.v21RayHoldPitchSpread
end

mapState.armRayViewHold = function(idx, depth, confirmed)
    if idx == nil or depth == nil then return end
    depth = max(MIN_DEPTH, min(OPEN_DEPTH, depth))
    local h = mapState.rayViewHolds[idx]
    if h == nil then
        h = {
            depth = depth,
            confirmed = confirmed == true,
            closeVotes = 0,
            initialUntil = interiorElapsed + mapState.v21RayHoldInitial,
            awaySince = nil,
        }
        mapState.rayViewHolds[idx] = h
        mapState.rayViewHoldCount = mapState.rayViewHoldCount + 1
    else
        if depth > (h.depth or 0.0) then h.depth = depth end
        if confirmed == true then h.confirmed = true end
        h.closeVotes = 0
        h.initialUntil = interiorElapsed + mapState.v21RayHoldInitial
        h.awaySince = nil
    end
    binPrio[idx] = max(binPrio[idx] or 0, mapState.v21RayHoldPriority)
    mapState.rayViewHoldTouches = mapState.rayViewHoldTouches + 1
end

mapState.dropRayViewHold = function(idx, reason)
    local h = mapState.rayViewHolds[idx]
    if h == nil then return end
    mapState.rayViewHolds[idx] = nil
    mapState.rayViewHoldCount = max(0, mapState.rayViewHoldCount - 1)
    if reason == 'close' then
        mapState.rayViewHoldCloseReleases = mapState.rayViewHoldCloseReleases + 1
    elseif reason == 'away' then
        mapState.rayViewHoldAwayReleases = mapState.rayViewHoldAwayReleases + 1
    elseif reason == 'verify' then
        mapState.rayViewHoldVerifyReleases = mapState.rayViewHoldVerifyReleases + 1
    end
end

mapState.confirmRayViewHold = function(idx, depth)
    mapState.armRayViewHold(idx, depth, true)
end

mapState.rejectInitialRayViewHold = function(idx)
    local h = mapState.rayViewHolds[idx]
    if h ~= nil and h.confirmed ~= true then
        mapState.dropRayViewHold(idx, 'verify')
    end
end

mapState.observeRayViewHold = function(idx, depth, wasMiss)
    if idx == nil or depth == nil or mapState.rayViewHoldCount <= 0 then return end
    for hid, h in pairs(mapState.rayViewHolds) do
        if h ~= nil and mapState.rayViewBinsClose(idx, hid) then
            local positive = wasMiss
                or depth >= (h.depth or depth) - mapState.v21RayHoldPositiveTol
            if positive then
                if depth > (h.depth or 0.0) then h.depth = min(OPEN_DEPTH, depth) end
                h.closeVotes = 0
                h.awaySince = nil
                mapState.rayViewHoldTouches = mapState.rayViewHoldTouches + 1
            end
            -- V21.1: ordinary/neighbor jitter rays may REFRESH an aperture,
            -- but can NEVER disprove it. A slit is supposed to be surrounded
            -- by close roof/wall hits. Only its saved exact witness direction
            -- below owns retirement authority.
        end
    end
end

mapState.rayViewHeldDepth = function(idx)
    if idx == nil or mapState.rayViewHoldCount <= 0 then return nil end
    local best = nil
    for hid, h in pairs(mapState.rayViewHolds) do
        if h ~= nil and mapState.rayViewBinsClose(idx, hid) then
            if h.confirmed == true or (h.initialUntil or 0.0) > interiorElapsed then
                local d = h.depth or 0.0
                if best == nil or d > best then best = d end
            end
        end
    end
    return best
end

mapState.updateRayViewHolds = function()
    if mapState.rayViewHoldCount <= 0 then return end
    local drop = {}
    for hid, h in pairs(mapState.rayViewHolds) do
        if h ~= nil then
            local visible = false
            for i = 1, #visList do
                if mapState.rayViewBinsClose(hid, visList[i]) then
                    visible = true
                    break
                end
            end
            if visible then
                h.awaySince = nil
                binPrio[hid] = max(binPrio[hid] or 0, mapState.v21RayHoldPriority)
                if h.confirmed ~= true and (h.initialUntil or 0.0) <= interiorElapsed then
                    drop[#drop + 1] = { hid, 'verify' }
                end
            else
                -- Camera motion is not evidence that world-space geometry
                -- vanished. During a turn (including TURN_LINGER), keep the
                -- aperture dormant and do not even start its away timer.
                if vdState.turnf ~= 0 or turnLinger > 0.0 then
                    h.awaySince = nil
                    mapState.rayViewHoldTurnSkips
                        = mapState.rayViewHoldTurnSkips + 1
                else
                    if h.awaySince == nil then h.awaySince = interiorElapsed end
                    if interiorElapsed - h.awaySince >= mapState.v21RayHoldAwayGrace then
                        drop[#drop + 1] = { hid, 'away' }
                    end
                end
            end
        end
    end
    for i = 1, #drop do
        mapState.dropRayViewHold(drop[i][1], drop[i][2])
    end
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
            mapState.armRayViewHold(idx, m, false)
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
            mapState.confirmRayViewHold(idx, dv)
        else
            mapState.rejectInitialRayViewHold(idx)
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
            mapState.confirmRayViewHold(idx, max(m, dv))
        else
            binDeepMiss[idx] = (binDeepMiss[idx] or 0) + 1
            pushRing(idx, m)
            local missLimit = DEEP_MISS_LIMIT
            if dv - m >= mapState.v21RayHoldJumpDrop then
                missLimit = max(missLimit, mapState.v21RayHoldJumpMisses)
                mapState.rayViewHoldJumpDefers
                    = mapState.rayViewHoldJumpDefers + 1
            end
            if binDeepMiss[idx] >= missLimit then
                local h = mapState.rayViewHolds[idx]
                if h == nil or (h.initialUntil or 0.0) <= interiorElapsed then
                    binDeepVal[idx] = nil
                    binDeepJy[idx] = nil
                    binDeepJp[idx] = nil
                    binDeepMiss[idx] = 0
                    mapState.dropRayViewHold(idx, 'close')
                else
                    -- Keep the exact witness pending but below threshold until
                    -- the hard five-second fallback residency expires.
                    binDeepMiss[idx] = max(0, missLimit - 1)
                end
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
        mapState.armRayViewHold(idx, m, false)
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
        local hitDist = sqrt(hx * hx + hy * hy + hz * hz)
        if mapState.rayPvsEvidence ~= nil then
            mapState.rayPvsEvidence(idx, ex, ey, ez, hitDist, false, rayLen)
        end
        mapState.observeUpwardRay(idx, hitDist, false, rayLen)
        mapState.observeRayViewHold(idx, hitDist, false)
        acceptBin(idx, hitDist, false, jy, jp, isVerify, isDeepVerify)
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
        if mapState.rayPvsEvidence ~= nil then
            mapState.rayPvsEvidence(idx, ex, ey, ez, rayLen, true, rayLen)
        end
        mapState.observeUpwardRay(idx, rayLen, true, rayLen)
        mapState.observeRayViewHold(idx, rayLen, true)
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
            mapState.armRayViewHold(idx, OPEN_DEPTH, false)
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
                                local protectUntil = mapState.doorProtectUntil[j]
                                if protectUntil ~= nil then
                                    if protectUntil > interiorElapsed then
                                        local protectDepth = mapState.doorProtectDepth[j] or 0.0
                                        if protectDepth > dv then dv = protectDepth end
                                    else
                                        mapState.doorProtectUntil[j] = nil
                                        mapState.doorProtectDepth[j] = nil
                                    end
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

                    -- V22.1 rapid-upward anticipation comes after offline Z caps but
                    -- before verified ray/resident authority. It is deliberately only a
                    -- temporary FLOOR on upward-facing tiles; three close ceiling reports
                    -- remove it, while real deep rays take over through V21/V22 below.
                    local upDepth = mapState.upwardSpecDepth(pitchDeg)
                    if upDepth ~= nil and upDepth > depth then
                        depth = upDepth
                        mapState.upFloorApplications = mapState.upFloorApplications + 1
                    end

                    -- V21 live positive-ray authority comes AFTER vertical/Z caps.
                    -- A verified ray through a watch-tower slit, railing gap, high
                    -- doorway, etc. is stronger evidence than an offline cell-height
                    -- heuristic while the player is still looking at that region.
                    local heldDepth = mapState.rayViewHeldDepth(idx)
                    if heldDepth ~= nil and heldDepth > depth then
                        depth = heldDepth
                    end
                    local residentDepth = mapState.residentDepthForBin(idx)
                    if residentDepth ~= nil and residentDepth > depth then
                        depth = residentDepth
                    end
                end
            end
            -- V15 contract: topology-mapped cells never hard-clamp live ray depth.
            -- Unmapped cells retain V14 exactly so this one-cell prototype cannot
            -- regress the rest of the game.
            if mapState.topoCell ~= nil then
                if mapState.topoKind == 'large_open'
                    and depth < mapState.v19LargeOpenMinDepth then
                    depth = mapState.v19LargeOpenMinDepth
                end

                -- V20 transition bridge: for only ~1.2s after actually crossing
                -- a mapped room threshold, temporarily remove the depth curtain.
                -- Structural PVS remains active, so this opens the current/latched
                -- rooms, NOT four floors of the castle.
                if mapState.transitionOpenUntil > interiorElapsed
                    and depth < mapState.v20TransitionMinDepth then
                    depth = mapState.v20TransitionMinDepth
                end
                out[tIdx] = max(MIN_DEPTH, depth)
            else
                out[tIdx] = max(MIN_DEPTH, min(mapState.cap, depth))
            end
        end
    end
    for i = nVis + 1, #visList do visList[i] = nil end
    mapState.updateRayViewHolds()

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

    -- V22.1E learn-first arrival gate. Do NOT throw away the sensor work:
    -- visList/tileBin/out are already current, and the ray scheduler later in
    -- this same frame still learns from them. We only withhold the final C++
    -- culling publish until the entry window has had time to observe the room.
    local learnOnly = (mapState.intercellGridLearnUntil or 0.0) > interiorElapsed
    if learnOnly then
        pcall(camera.clearInteriorVisibilityGrid)
        gridMaybeArmed = false
        mapState.intercellGridSuppressFrames = (mapState.intercellGridSuppressFrames or 0) + 1
    else
        if (mapState.intercellGridLearnUntil or 0.0) > 0.0 then
            mapState.intercellGridLearnUntil = 0.0
            mapState.intercellGridLearnEnds = (mapState.intercellGridLearnEnds or 0) + 1
            print(string.format(
                '[TSP_VISGRID_V22.1E] GRID LEARN-GRACE end dest=%s t=%.2f known=%d frames=%d',
                tostring(lastCellName or mapState.intercellDest or '?'), interiorElapsed,
                #knownList, mapState.intercellGridSuppressFrames or 0))
        end
        if mapState.topoCell ~= nil
            and (mapState.topoKind == 'small_room'
                or mapState.topoKind == 'room'
                or mapState.topoKind == 'corridor') then
            camera.setInteriorVisibilityGrid(COLS, ROWS, out, mapState.v16TightPadding)
        else
            camera.setInteriorVisibilityGrid(COLS, ROWS, out, PADDING)
        end
        gridMaybeArmed = true
    end

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
    if casts < budget and vdState.spd < V14.MOVE_EPS and not turning then
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

    -- V22.1: while the camera is accelerating upward, spend the temporary
    -- extra budget sampling one/two pitch bins ABOVE the center view. This is
    -- prefetch, not blind opening: these casts immediately feed the normal ray,
    -- room-residency and ceiling-pullback paths.
    if casts < budget and (mapState.upBoostUntil or 0.0) > interiorElapsed then
        local center = tileBin[2 * COLS + 4]
        if center ~= nil then
            local by = (center - 1) % YAW_BINS
            local bp = floor((center - 1) / YAW_BINS)
            for k = 1, mapState.v221UpPredictBins do
                if casts >= budget then break end
                local pp = bp + k
                if pp >= PITCH_BINS then pp = PITCH_BINS - 1 end
                local j = pp * YAW_BINS + by + 1
                if j ~= center and binCandVal[j] == nil then
                    castBin(j, ex, ey, ez, 'jitter', true)
                    mapState.upPredictCasts = mapState.upPredictCasts + 1
                    casts = casts + 1
                end
            end
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
    local okList, list = pcall(function() return nearby.doors end)
    if not okList or list == nil then return end

    local okIter = pcall(function()
        for _, d in ipairs(list) do
            local px, py, pz = d.position.x, d.position.y, d.position.z
            local ddx, ddy, ddz = px - ex, py - ey, pz - ez
            local d2 = ddx * ddx + ddy * ddy + ddz * ddz

            if d2 <= mapState.v19DoorProtectRange * mapState.v19DoorProtectRange
                and d2 > 1.0 then
                local len = sqrt(d2)
                local idx = binOfDir(ddx, ddy, ddz, len)
                local by = (idx - 1) % YAW_BINS
                local bp = floor((idx - 1) / YAW_BINS)
                local yRad = len < 650.0 and 2 or 1
                local floorDepth = min(OPEN_DEPTH,
                    len + mapState.v19DoorProtectMargin)
                local expiry = interiorElapsed + mapState.v19DoorProtectTtl

                for dp = -1, 1 do
                    local pp = bp + dp
                    if pp >= 0 and pp < PITCH_BINS then
                        for dyw = -yRad, yRad do
                            local j = pp * YAW_BINS
                                + ((by + dyw) % YAW_BINS) + 1
                            if mapState.doorProtectUntil[j] == nil
                                or mapState.doorProtectUntil[j] < expiry then
                                mapState.doorProtectUntil[j] = expiry
                            end
                            if mapState.doorProtectDepth[j] == nil
                                or mapState.doorProtectDepth[j] < floorDepth then
                                mapState.doorProtectDepth[j] = floorDepth
                            end
                        end
                    end
                end
                mapState.doorProtectSeen = mapState.doorProtectSeen + 1
            end

            -- State-change sensing is optional.  If this API is unreadable,
            -- continuous protection above still remains active.
            if d2 <= DOOR_WATCH_RANGE * DOOR_WATCH_RANGE then
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

    -- Do not disable geometric door protection when only state introspection
    -- fails.  The next poll can still protect door meshes.
    if not okIter and doorSignatureMode ~= 'off' then
        doorSignatureMode = 'off'
        print('[TSP_VISGRID_V19] door state poll failed; continuous door protection remains active')
    end
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

-- ======== V16: stable topology context + portal hints ========

mapState.topologyPosition = function(fx, fy, fz)
    local ok, p = pcall(function() return self.position end)
    if ok and p ~= nil and p.x ~= nil and p.y ~= nil and p.z ~= nil then
        return p.x, p.y, p.z
    end
    return fx, fy, fz
end

mapState.topologyBinVisible = function(idx, spread)
    if idx == nil then return false end
    spread = spread or 1
    local iby = (idx - 1) % YAW_BINS
    local ibp = floor((idx - 1) / YAW_BINS)
    for i = 1, #visList do
        local j = visList[i]
        local jby = (j - 1) % YAW_BINS
        local jbp = floor((j - 1) / YAW_BINS)
        local dy = abs(jby - iby)
        dy = min(dy, YAW_BINS - dy)
        if dy <= spread and abs(jbp - ibp) <= spread then return true end
    end
    return false
end


-- ======== V21: real ESM/ESP door overlay ========
mapState.loadRealDoors = function(cellName)
    mapState.realDoors = nil
    mapState.realDoorCount = 0
    mapState.realDoorPortalMatches = 0
    mapState.realDoorWorldExits = 0
    mapState.realDoorTargetSectors = 0

    if mapState.doorGraph == nil then return end
    local doors = mapState.doorGraph.getCell(cellName)
    if type(doors) ~= 'table' then return end
    mapState.realDoors = doors

    for i = 1, #doors do
        local d = doors[i]
        if d ~= nil and type(d.x) == 'number' and type(d.y) == 'number'
            and type(d.z) == 'number' then
            mapState.realDoorCount = mapState.realDoorCount + 1

            if d.teleport == true and d.destKind == 'exterior' then
                d.worldExit = true
                mapState.realDoorWorldExits = mapState.realDoorWorldExits + 1
            end

            if mapState.topology ~= nil and mapState.topoCell ~= nil then
                local sid = mapState.topology.findSector(cellName, d.x, d.y, d.z)
                d.sourceSector = sid or 0

                if d.teleport == true and d.destKind == 'interior'
                    and type(d.destCell) == 'string' and d.destCell ~= ''
                    and type(d.destX) == 'number' and type(d.destY) == 'number'
                    and type(d.destZ) == 'number' then
                    local dsid = mapState.topology.findSector(
                        d.destCell, d.destX, d.destY, d.destZ)
                    d.destSector = dsid or 0
                    if d.destSector > 0 then
                        mapState.realDoorTargetSectors
                            = mapState.realDoorTargetSectors + 1
                    end
                end

                -- Only a physical/local door may reclassify an existing
                -- same-cell portal. Teleport/load doors are WORLD_EXIT edges.
                if d.teleport ~= true and mapState.topoCell.portals ~= nil then
                    local bestPid, bestPortal, bestD2 = nil, nil, nil
                    for pid, p in pairs(mapState.topoCell.portals) do
                        if p ~= nil and p.center ~= nil
                            and (d.sourceSector == 0
                                or p.a == d.sourceSector or p.b == d.sourceSector) then
                            local dx = p.center[1] - d.x
                            local dy = p.center[2] - d.y
                            local dz = p.center[3] - d.z
                            local d2 = dx*dx + dy*dy + dz*dz
                            if bestD2 == nil or d2 < bestD2 then
                                bestPid, bestPortal, bestD2 = pid, p, d2
                            end
                        end
                    end
                    if bestPortal ~= nil
                        and bestD2 <= mapState.v21DoorPortalMatch
                            * mapState.v21DoorPortalMatch then
                        bestPortal.kind = 'door'
                        bestPortal.realDoor = true
                        bestPortal.doorId = d.id
                        bestPortal.teleport = false
                        d.portalId = bestPid
                        mapState.realDoorPortalMatches
                            = mapState.realDoorPortalMatches + 1
                    end
                end
            end
        end
    end

    if mapState.realDoorCount > 0 then
        print(string.format(
            '[TSP_VISGRID_V21] doors cell=%s refs=%d localPortalMatches=%d worldExits=%d targetSectors=%d',
            tostring(cellName), mapState.realDoorCount,
            mapState.realDoorPortalMatches, mapState.realDoorWorldExits,
            mapState.realDoorTargetSectors))
    end
end

mapState.refreshRealDoorSourceSectors = function(ex, ey, ez)
    local doors = mapState.realDoors
    if type(doors) ~= 'table' then return false end
    local hold = mapState.realDoorSourceUntil
    if type(hold) ~= 'table' then hold = {}; mapState.realDoorSourceUntil = hold end
    local arrival = (mapState.intercellGridLearnUntil or 0.0) > interiorElapsed
        or ((mapState.intercellEntryNearCount or 0) > 0
            and interiorElapsed < (mapState.v221eEntryNearHold or 0.0))
    local changed = false

    for sid, expiry in pairs(hold) do
        if expiry == nil or expiry <= interiorElapsed then
            hold[sid] = nil
            changed = true
        end
    end

    for i = 1, #doors do
        local d = doors[i]
        local sid = d ~= nil and tonumber(d.sourceSector or 0) or 0
        if sid > 0 and type(d.x) == 'number' and type(d.y) == 'number'
            and type(d.z) == 'number' then
            local dx, dy, dz = d.x-ex, d.y-ey, d.z-ez
            local dist = sqrt(dx*dx + dy*dy + dz*dz)
            local range = 0.0
            if arrival then
                range = mapState.v221eArrivalDoorSourceRange
            elseif d.teleport == true then
                range = mapState.v221eLoadDoorSourceRange
            end
            if range > 0.0 and dist <= range then
                local expiry = interiorElapsed + mapState.v221eDoorSourceTtl
                if arrival and expiry < mapState.v221eEntryNearHold then
                    expiry = mapState.v221eEntryNearHold
                end
                if hold[sid] == nil then changed = true end
                if hold[sid] == nil or hold[sid] < expiry then hold[sid] = expiry end
                mapState.realDoorSourceTouches = (mapState.realDoorSourceTouches or 0) + 1
            end
        end
    end

    local ids = {}
    for sid, expiry in pairs(hold) do
        if expiry ~= nil and expiry > interiorElapsed then ids[#ids + 1] = sid end
    end
    table.sort(ids)
    local signature = table.concat(ids, ',')
    if signature ~= (mapState.realDoorSourceSignature or '') then
        mapState.realDoorSourceSignature = signature
        mapState.realDoorSourceChanges = (mapState.realDoorSourceChanges or 0) + 1
        changed = true
        print(string.format(
            '[TSP_VISGRID_V22.1E] DOOR-SOURCE HALO active=%d ids=%s arrival=%d changes=%d',
            #ids, signature, arrival and 1 or 0, mapState.realDoorSourceChanges or 0))
    end
    mapState.realDoorSourceCount = #ids
    return changed
end

mapState.seedIntercellEntryNeighborhood = function(ex, ey, ez)
    mapState.intercellEntryNearUntil = {}
    mapState.intercellEntryNearCount = 0
    mapState.intercellEntryNearSignature = ''
    if mapState.topoCell == nil or mapState.intercellDest == nil then return end

    local tx, ty, tz = mapState.topologyPosition(ex, ey, ez)
    local candidates = {}
    local r2 = mapState.v221eEntryNearRange * mapState.v221eEntryNearRange
    for sid, sec in pairs(mapState.topoCell.sectors or {}) do
        local b = sec ~= nil and sec.bbox or nil
        if type(sid) == 'number' and b ~= nil and #b >= 6 then
            local dx, dy, dz = 0.0, 0.0, 0.0
            if tx < b[1] then dx = b[1]-tx elseif tx > b[4] then dx = tx-b[4] end
            if ty < b[2] then dy = b[2]-ty elseif ty > b[5] then dy = ty-b[5] end
            if tz < b[3] then dz = b[3]-tz elseif tz > b[6] then dz = tz-b[6] end
            local d2 = dx*dx + dy*dy + dz*dz
            if d2 <= r2 then candidates[#candidates + 1] = {sid=sid,d2=d2} end
        end
    end
    table.sort(candidates, function(a,b)
        if a.d2 == b.d2 then return a.sid < b.sid end
        return a.d2 < b.d2
    end)
    local ids = {}
    local lim = min(#candidates, mapState.v221eEntryNearMax)
    for i = 1, lim do
        local sid = candidates[i].sid
        mapState.intercellEntryNearUntil[sid] = mapState.v221eEntryNearHold
        ids[#ids + 1] = sid
    end
    table.sort(ids)
    mapState.intercellEntryNearCount = #ids
    mapState.intercellEntryNearSignature = table.concat(ids, ',')
    print(string.format(
        '[TSP_VISGRID_V22.1E] ENTRY-NEAR PRELOAD dest=%s active=%d ids=%s range=%.0f hold=%.1f',
        tostring(mapState.intercellDest or '?'), #ids,
        mapState.intercellEntryNearSignature, mapState.v221eEntryNearRange,
        mapState.v221eEntryNearHold))
end

mapState.primeRealDoors = function(ex, ey, ez)
    local doors = mapState.realDoors
    if type(doors) ~= 'table' then return end

    local haloChanged = mapState.refreshRealDoorSourceSectors(ex, ey, ez)

    for i = 1, #doors do
        local d = doors[i]
        if d ~= nil and type(d.x) == 'number' and type(d.y) == 'number'
            and type(d.z) == 'number' then
            local dx, dy, dz = d.x-ex, d.y-ey, d.z-ez
            local dist = sqrt(dx*dx + dy*dy + dz*dz)
            if dist > 1.0 and dist <= mapState.v21RealDoorProtectRange then
                local idx = binOfDir(dx, dy, dz, dist)
                if mapState.topologyBinVisible(idx, 3) then
                    local by = (idx - 1) % YAW_BINS
                    local bp = floor((idx - 1) / YAW_BINS)
                    local expiry = interiorElapsed + mapState.v21RealDoorProtectTtl
                    local floorDepth = min(
                        OPEN_DEPTH, dist + mapState.v21RealDoorProtectMargin)
                    for dp = -1, 1 do
                        local pp = bp + dp
                        if pp >= 0 and pp < PITCH_BINS then
                            for dyw = -2, 2 do
                                local j = pp * YAW_BINS
                                    + ((by + dyw) % YAW_BINS) + 1
                                if mapState.doorProtectUntil[j] == nil
                                    or mapState.doorProtectUntil[j] < expiry then
                                    mapState.doorProtectUntil[j] = expiry
                                end
                                if mapState.doorProtectDepth[j] == nil
                                    or mapState.doorProtectDepth[j] < floorDepth then
                                    mapState.doorProtectDepth[j] = floorDepth
                                end
                                binPrio[j] = max(binPrio[j] or 0, 11)
                            end
                        end
                    end
                    mapState.doorProtectSeen = mapState.doorProtectSeen + 1
                end
            end
        end
    end
    if haloChanged and mapState.updateTopologyPvs ~= nil then
        mapState.updateTopologyPvs(false)
    end
end

-- ======== V17: navmesh structural PVS ========
-- The topology table is offline data. Runtime never queries Detour here.
-- We send the 38 sector AABBs to C++ only when the structural candidate set
-- changes; C++ can then reject small static roots before LightList traversal.

mapState.buildPvsBoxes = function()
    mapState.pvsBoxes = nil
    mapState.pvsSectorCount = 0
    mapState.pvsSignature = nil
    if not mapState.pvsBridge or mapState.topoCell == nil then return end

    local boxes = {}
    local maxSid = 0
    for sid, sec in pairs(mapState.topoCell.sectors) do
        if type(sid) == 'number' and sid > maxSid then maxSid = sid end
    end
    if maxSid <= 0 or maxSid > 64 then
        print(string.format('[TSP_VISGRID_V17] PVS disabled: sector count %d outside 1..64', maxSid))
        return
    end

    for sid = 1, maxSid do
        local sec = mapState.topoCell.sectors[sid]
        if sec == nil or sec.bbox == nil or #sec.bbox < 6 then
            print(string.format('[TSP_VISGRID_V17] PVS disabled: missing bbox sector=%d', sid))
            return
        end
        local b = sec.bbox
        local o = (sid - 1) * 6
        boxes[o + 1], boxes[o + 2], boxes[o + 3] = b[1], b[2], b[3]
        boxes[o + 4], boxes[o + 5], boxes[o + 6] = b[4], b[5], b[6]
    end

    mapState.pvsBoxes = boxes
    mapState.pvsSectorCount = maxSid

    mapState.pvsDoorPair = {}
    if mapState.topoCell.portals ~= nil then
        for _, p in pairs(mapState.topoCell.portals) do
            if p ~= nil and p.kind == 'door' and p.a ~= nil and p.b ~= nil
                and p.a ~= p.b then
                local lo = min(p.a, p.b)
                local hi = max(p.a, p.b)
                mapState.pvsDoorPair[tostring(lo) .. ':' .. tostring(hi)] = true
            end
        end
    end
end

mapState.pvsPairHasDoor = function(a, b)
    local lo = min(a or 0, b or 0)
    local hi = max(a or 0, b or 0)
    return mapState.pvsDoorPair[tostring(lo) .. ':' .. tostring(hi)] == true
end

-- ======== V22: bounded resident room-group working set ========
-- Negative rays never evict these groups. A new room/sector competes for the
-- bounded working set only after the incumbent's five-second minimum expires.

mapState.residentSourceRank = function(source)
    if source == 'ray' then return 4 end
    if source == 'recent' then return 3 end
    if source == 'proximity' or source == 'predict' then return 2 end
    if source == 'probe' then return 1 end
    return 2
end

mapState.residentBinsClose = function(a, b)
    if a == nil or b == nil then return false end
    local aby = (a - 1) % YAW_BINS
    local abp = floor((a - 1) / YAW_BINS)
    local bby = (b - 1) % YAW_BINS
    local bbp = floor((b - 1) / YAW_BINS)
    local dy = abs(aby - bby)
    dy = min(dy, YAW_BINS - dy)
    return dy <= mapState.v22ResidentYawSpread
        and abs(abp - bbp) <= mapState.v22ResidentPitchSpread
end

mapState.residentDrop = function(sid)
    if sid == nil or mapState.residentSectors[sid] == nil then return end
    mapState.residentSectors[sid] = nil
    mapState.residentCount = max(0, mapState.residentCount - 1)
    mapState.residentEvictions = mapState.residentEvictions + 1
end

mapState.residentTrimOverflow = function()
    while mapState.residentCount > mapState.v22ResidentTarget do
        local victim, victimRank, victimTouch = nil, 999, 1.0e30
        for sid, r in pairs(mapState.residentSectors) do
            if r ~= nil and (r.minUntil or 0.0) <= interiorElapsed then
                local rank = mapState.residentSourceRank(r.source)
                local touch = r.lastTouch or 0.0
                if victim == nil or rank < victimRank
                    or (rank == victimRank and touch < victimTouch) then
                    victim, victimRank, victimTouch = sid, rank, touch
                end
            end
        end
        if victim == nil then break end
        mapState.residentDrop(victim)
    end
end

mapState.residentPromote = function(sid, source, idx, depth, ttl)
    if sid == nil or sid <= 0 then return false end
    if sid == (mapState.topoSectorId or 0) then
        -- Current room is already pinned by updateTopologyPvs; no slot needed.
        return true
    end
    local tc = mapState.topoCell
    if tc == nil or tc.sectors == nil or tc.sectors[sid] == nil then return false end

    local r = mapState.residentSectors[sid]
    local fresh = r == nil
    if fresh then
        mapState.residentTrimOverflow()
        if mapState.residentCount >= mapState.v22ResidentTarget then
            local victim, victimRank, victimTouch = nil, 999, 1.0e30
            for oid, old in pairs(mapState.residentSectors) do
                if old ~= nil and (old.minUntil or 0.0) <= interiorElapsed then
                    local rank = mapState.residentSourceRank(old.source)
                    local touch = old.lastTouch or 0.0
                    if victim == nil or rank < victimRank
                        or (rank == victimRank and touch < victimTouch) then
                        victim, victimRank, victimTouch = oid, rank, touch
                    end
                end
            end
            if victim ~= nil then
                mapState.residentDrop(victim)
            elseif mapState.residentCount >= mapState.v22ResidentHardMax then
                mapState.residentRejects = mapState.residentRejects + 1
                return false
            else
                mapState.residentOverflows = mapState.residentOverflows + 1
            end
        end
        r = { sid=sid, source=source or 'predict', bins={} }
        mapState.residentSectors[sid] = r
        mapState.residentCount = mapState.residentCount + 1
        mapState.residentPromotions = mapState.residentPromotions + 1
        if source == 'ray' then
            mapState.residentRayPromotions = mapState.residentRayPromotions + 1
        elseif source == 'recent' then
            mapState.residentRecent = mapState.residentRecent + 1
        else
            mapState.residentPredictions = mapState.residentPredictions + 1
        end
    elseif mapState.residentSourceRank(source)
        > mapState.residentSourceRank(r.source) then
        r.source = source
    end

    r.lastTouch = interiorElapsed
    local hold = ttl or mapState.v22ResidentMinHold
    r.minUntil = max(r.minUntil or 0.0, interiorElapsed + hold)

    if idx ~= nil and depth ~= nil then
        local d = max(MIN_DEPTH, min(OPEN_DEPTH, depth))
        local old = r.bins[idx]
        if old == nil or d > old then r.bins[idx] = d end
        mapState.residentDepthTouches = mapState.residentDepthTouches + 1
        binPrio[idx] = max(binPrio[idx] or 0, 15)
    end
    return true
end

mapState.residentRemoveCurrent = function()
    local sid = mapState.topoSectorId or 0
    if sid > 0 and mapState.residentSectors[sid] ~= nil then
        mapState.residentSectors[sid] = nil
        mapState.residentCount = max(0, mapState.residentCount - 1)
    end
end

mapState.residentDepthForBin = function(idx)
    if idx == nil or mapState.residentCount <= 0 then return nil end
    local best = nil
    for _, r in pairs(mapState.residentSectors) do
        if r ~= nil and r.bins ~= nil then
            for bid, depth in pairs(r.bins) do
                if mapState.residentBinsClose(idx, bid) then
                    if best == nil or depth > best then best = depth end
                end
            end
        end
    end
    return best
end

mapState.residentRayDiscover = function(idx, ex, ey, ez, observedDepth, wasMiss, rayLen)
    if idx == nil or mapState.topology == nil or mapState.topoCell == nil
        or lastCellName == nil then return false end

    local reach = observedDepth or 0.0
    if wasMiss then reach = max(reach, rayLen or 0.0) end
    reach = min(OPEN_DEPTH, reach)
    if reach < mapState.v22RayMinDepth then return false end

    local dx, dy, dz = binDirX[idx], binDirY[idx], binDirZ[idx]
    if dx == nil then return false end
    local samples = {
        mapState.v22RaySampleEnd,
        mapState.v22RaySampleFar,
        mapState.v22RaySampleMid,
        mapState.v22RaySampleNear,
    }
    local current = mapState.topoSectorId or 0
    for i = 1, #samples do
        local d = reach * samples[i]
        if d >= mapState.v22RayMinDepth * 0.70 then
            local sx, sy, sz = ex + dx*d, ey + dy*d, ez + dz*d
            local sid = mapState.topology.findSector(lastCellName, sx, sy, sz)
            if sid ~= nil and sid > 0 and sid ~= current then
                if mapState.residentPromote(
                    sid, 'ray', idx, reach, mapState.v22ResidentMinHold) then
                    mapState.residentRayFinds = mapState.residentRayFinds + 1
                    return true
                end
            end
        end
    end
    return false
end

mapState.pvsRememberSector = function(sid, ttl)
    if sid == nil or sid <= 0 then return end
    local expiry = interiorElapsed + (ttl or mapState.v18TailGrace)
    if mapState.pvsRecent[sid] == nil or mapState.pvsRecent[sid] < expiry then
        mapState.pvsRecent[sid] = expiry
    end
end

mapState.pvsAddEnvelope = function(active, sid, largeSafe)
    local tc = mapState.topoCell
    local sec = tc ~= nil and tc.sectors[sid] or nil
    if sec == nil then return end
    active[sid] = true
    local sf = tonumber(sec.floor or 0)

    if largeSafe and sec.kind == 'large_open' and sf > 0
        and sec.bbox ~= nil then
        local b = sec.bbox
        local pad = mapState.v18LargeEmbedPad
        for oid, other in pairs(tc.sectors) do
            if tonumber(other.floor or 0) == sf and other.center ~= nil then
                local c = other.center
                if c[1] >= b[1] - pad and c[1] <= b[4] + pad
                    and c[2] >= b[2] - pad and c[2] <= b[5] + pad
                    and c[3] >= b[3] - pad and c[3] <= b[6] + pad then
                    active[oid] = true
                end
            end
        end
    end

    if sec.neighbors ~= nil then
        for i = 1, #sec.neighbors do
            local nid = sec.neighbors[i]
            local ns = tc.sectors[nid]
            if ns ~= nil then
                if ns.kind == 'vertical_connector' then
                    active[nid] = true
                    if ns.neighbors ~= nil then
                        for j = 1, #ns.neighbors do active[ns.neighbors[j]] = true end
                    end
                elseif sf > 0 and tonumber(ns.floor or 0) == sf
                    and not mapState.pvsPairHasDoor(sid, nid) then
                    active[nid] = true
                end
            end
        end
    end
end

mapState.pvsAddLatchedSector = function(active, sid)
    local tc = mapState.topoCell
    local sec = tc ~= nil and tc.sectors[sid] or nil
    if sec == nil then return end
    active[sid] = true

    -- A large room may contain tiny disconnected walk islands that are still
    -- visually part of the same chamber.  Keep only islands embedded in its
    -- own bbox; do not expand to unrelated same-floor rooms.
    if sec.kind == 'large_open' and tonumber(sec.floor or 0) > 0
        and sec.bbox ~= nil then
        local b = sec.bbox
        local pad = mapState.v18LargeEmbedPad
        for oid, other in pairs(tc.sectors) do
            if tonumber(other.floor or 0) == tonumber(sec.floor or 0)
                and other.center ~= nil then
                local c = other.center
                if c[1] >= b[1] - pad and c[1] <= b[4] + pad
                    and c[2] >= b[2] - pad and c[2] <= b[5] + pad
                    and c[3] >= b[3] - pad and c[3] <= b[6] + pad then
                    active[oid] = true
                end
            end
        end
    end

    -- A latched staircase must keep its immediate endpoints, but still does
    -- not reopen every sector on an endpoint floor.
    if sec.kind == 'vertical_connector' and sec.neighbors ~= nil then
        for i = 1, #sec.neighbors do active[sec.neighbors[i]] = true end
    end
end

mapState.latchPortal = function(pid, p, ttl, source)
    if pid == nil or p == nil or p.a == nil or p.b == nil
        or p.a <= 0 or p.b <= 0 or p.a == p.b then return false end

    local expiry = interiorElapsed + (ttl or mapState.v20NearLatchSeconds)
    local l = mapState.portalLatches[pid]
    if l == nil then
        l = { a = p.a, b = p.b, untilTime = expiry, source = source or 'unknown' }
        mapState.portalLatches[pid] = l
    else
        l.a, l.b = p.a, p.b
        if expiry > (l.untilTime or 0.0) then l.untilTime = expiry end
        l.source = source or l.source
    end

    mapState.pvsRememberSector(p.a, ttl)
    mapState.pvsRememberSector(p.b, ttl)
    mapState.portalLatchTouches = mapState.portalLatchTouches + 1
    return true
end

mapState.findPortalBetween = function(a, b)
    local tc = mapState.topoCell
    if tc == nil or tc.portals == nil or a == nil or b == nil then return nil, nil end

    local sec = tc.sectors[a]
    if sec ~= nil and sec.portals ~= nil then
        for i = 1, #sec.portals do
            local pid = sec.portals[i]
            local p = tc.portals[pid]
            if p ~= nil
                and ((p.a == a and p.b == b) or (p.a == b and p.b == a)) then
                return pid, p
            end
        end
    end

    -- Conservative fallback in case a compiler omitted the portal id from one
    -- sector's local list.
    for pid, p in pairs(tc.portals) do
        if p ~= nil
            and ((p.a == a and p.b == b) or (p.a == b and p.b == a)) then
            return pid, p
        end
    end
    return nil, nil
end

mapState.pvsProbePortal = function(ex, ey, ez, p)
    if p == nil or p.center == nil then return false, 0.0 end
    local px, py, pz = p.center[1], p.center[2], p.center[3]
    local dx, dy, dz = px - ex, py - ey, pz - ez
    local dist = sqrt(dx*dx + dy*dy + dz*dz)
    if dist < 1.0 then return true, dist end
    dx, dy, dz = dx / dist, dy / dist, dz / dist

    local n = (p.kind == 'door') and 3 or 1
    for k = 1, n do
        local ax, ay = dx, dy
        if n == 3 and k ~= 1 then
            local ang = (k == 2) and -0.055 or 0.055
            local ca, sa = cos(ang), sin(ang)
            ax, ay = dx * ca + dy * sa, dy * ca - dx * sa
        end
        local rayLen = dist + mapState.v18PortalProbeBeyond
        mapState.pvsProbeCount = mapState.pvsProbeCount + 1
        local ok, res = pcall(nearby.castRay,
            util.vector3(ex, ey, ez),
            util.vector3(ex + ax * rayLen, ey + ay * rayLen, ez + dz * rayLen),
            { collisionType = RAY_MASK })
        if ok and res ~= nil then
            if not res.hit or res.hitPos == nil then
                mapState.pvsProbeClear = mapState.pvsProbeClear + 1
                return true, rayLen
            end
            local hx = res.hitPos.x - ex
            local hy = res.hitPos.y - ey
            local hz = res.hitPos.z - ez
            local hd = sqrt(hx*hx + hy*hy + hz*hz)
            if hd > dist + mapState.v18PortalProbeMargin then
                mapState.pvsProbeClear = mapState.pvsProbeClear + 1
                return true, hd
            end
        end
    end
    return false, dist
end

mapState.pvsBinsClose = function(a, b, yawSpread, pitchSpread)
    if a == nil or b == nil then return false end
    local aby = (a - 1) % YAW_BINS
    local abp = floor((a - 1) / YAW_BINS)
    local bby = (b - 1) % YAW_BINS
    local bbp = floor((b - 1) / YAW_BINS)
    local dy = abs(aby - bby)
    dy = min(dy, YAW_BINS - dy)
    return dy <= (yawSpread or 2)
        and abs(abp - bbp) <= (pitchSpread or 1)
end

mapState.openPortalWedge = function(idx, largeTarget, dist, expiry, priority)
    if idx == nil then return end
    local pRad, yRad
    if largeTarget then
        if dist < 550.0 then pRad, yRad = 2, 5
        elseif dist < 1100.0 then pRad, yRad = 2, 4
        else pRad, yRad = 1, 3 end
    else
        if dist < 400.0 then pRad, yRad = 2, 4
        elseif dist < 800.0 then pRad, yRad = 2, 3
        else pRad, yRad = 1, 2 end
    end

    local by = (idx - 1) % YAW_BINS
    local bp = floor((idx - 1) / YAW_BINS)
    for dp = -pRad, pRad do
        local pp = bp + dp
        if pp >= 0 and pp < PITCH_BINS then
            for dyw = -yRad, yRad do
                local j = pp * YAW_BINS + ((by + dyw) % YAW_BINS) + 1
                if doorGrace[j] == nil then
                    doorGraceCount = doorGraceCount + 1
                end
                if doorGrace[j] == nil or doorGrace[j] < expiry then
                    doorGrace[j] = expiry
                end
                planeSupport[j] = nil
                planeRefreshRun[j] = 0
                binPrio[j] = max(binPrio[j] or 0, priority or 12)
            end
        end
    end
end

mapState.openPvsDestination = function(other, idx, largeTarget, dist, grace, source)
    if other == nil or other <= 0 or other == mapState.topoSectorId then return false end
    local expiry = interiorElapsed + grace
    local residentDepth = min(OPEN_DEPTH, (dist or 0.0) + mapState.v22PortalDepthPad)
    mapState.residentPromote(
        other, source == 'ray' and 'ray' or (source or 'predict'),
        idx, residentDepth, mapState.v22ResidentMinHold)
    mapState.pvsRememberSector(other, grace)
    mapState.pvsPortalSector = other
    mapState.pvsPortalUntil = max(mapState.pvsPortalUntil or 0.0, expiry)
    mapState.openPortalWedge(idx, largeTarget, dist, expiry,
        source == 'ray' and 15 or 13)
    enterBurst = max(enterBurst, mapState.v18PortalBurst)
    turnLinger = max(turnLinger, largeTarget and 1.05 or 0.80)
    mapState.updateTopologyPvs(false)
    return true
end

-- V19 primary opening detector: ordinary VISGRID rays already fan across the
-- live view.  If one reaches beyond a mapped portal, that is direct evidence
-- that geometry behind the portal is about to matter.  Open the destination
-- PVS immediately; a false positive only costs temporary rendering, never a hole.
mapState.rayPvsEvidence = function(idx, ex, ey, ez, observedDepth, wasMiss, rayLen)
    local tc, sec = mapState.topoCell, mapState.topoSector
    if tc == nil or idx == nil then return end

    mapState.rayPortalChecks = mapState.rayPortalChecks + 1
    local opened = false

    if sec ~= nil and sec.portals ~= nil then
        for i = 1, #sec.portals do
            local pid = sec.portals[i]
            local p = tc.portals[pid]
            if p ~= nil and (p.kind == 'door' or p.kind == 'boundary')
                and p.center ~= nil then
                local other = (p.a == mapState.topoSectorId) and p.b or p.a
                if other ~= nil and other > 0 and other ~= mapState.topoSectorId then
                    local os = tc.sectors[other]
                    local largeTarget = os ~= nil and os.kind == 'large_open'
                    local px, py, pz = p.center[1], p.center[2], p.center[3]
                    local dx, dy, dz = px-ex, py-ey, pz-ez
                    local pd = sqrt(dx*dx + dy*dy + dz*dz)

                    if pd > 1.0 then
                        local pidx = binOfDir(dx, dy, dz, pd)
                        local ys = largeTarget and 4 or ((p.kind == 'door') and 3 or 2)
                        local ps = largeTarget and 2 or 1
                        if mapState.pvsBinsClose(idx, pidx, ys, ps) then
                            local enough = observedDepth
                                >= pd + mapState.v19RayPortalMargin
                            if wasMiss and rayLen >= pd - 40.0 then enough = true end

                            if enough then
                                local grace
                                if largeTarget then grace = mapState.v19RayPortalLargeGrace
                                elseif p.kind == 'door' then grace = mapState.v19RayPortalDoorGrace
                                else grace = mapState.v19RayPortalBoundaryGrace end

                                mapState.latchPortal(
                                    pid, p, mapState.v20RayLatchSeconds, 'ray')
                                if mapState.openPvsDestination(
                                    other, pidx, largeTarget, pd, grace, 'ray') then
                                    mapState.rayPortalOpens = mapState.rayPortalOpens + 1
                                    opened = true
                                    break
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    -- V22 direct positive-ray promotion does not require the player itself to
    -- resolve to a sector. This is important for stairs, tower platforms and
    -- other places where the navmesh omits the exact standing point but the ray
    -- clearly enters a real destination sector.
    local found = mapState.residentRayDiscover(
        idx, ex, ey, ez, observedDepth, wasMiss, rayLen)
    if opened or found then mapState.updateTopologyPvs(false) end
end

mapState.updateTopologyPvs = function(force)
    if not mapState.pvsBridge or mapState.topoCell == nil
        or mapState.pvsBoxes == nil
        or (mapState.topoSector == nil and mapState.residentCount <= 0) then
        if mapState.pvsBridge then pcall(camera.clearInteriorTopologyPvs) end
        mapState.pvsSignature = nil
        mapState.pvsActiveCount = 0
        mapState.pvsRecentActive = 0
        return
    end

    mapState.residentTrimOverflow()
    local active = {}
    local floorNow = mapState.topoFloor or 0
    local current = mapState.topoSectorId or 0
    local currentSec = mapState.topoSector

    if current > 0 and currentSec ~= nil then
        if floorNow > 0 then
            mapState.pvsAddEnvelope(
                active, current,
                currentSec.kind == 'large_open')
        else
            active[current] = true
            if currentSec.neighbors ~= nil then
                local endpointFloors = {}
                for i = 1, #currentSec.neighbors do
                    local nid = currentSec.neighbors[i]
                    active[nid] = true
                    local ns = mapState.topoCell.sectors[nid]
                    if ns ~= nil and tonumber(ns.floor or 0) > 0 then
                        endpointFloors[tonumber(ns.floor)] = true
                    end
                end
                for sid, candidate in pairs(mapState.topoCell.sectors) do
                    if endpointFloors[tonumber(candidate.floor or 0)] then
                        active[sid] = true
                    end
                end
            end
        end
    end

    -- Resident seeds are room-groups, not whole floors. Large-room islands and
    -- staircase endpoints are included by pvsAddLatchedSector; ordinary same-
    -- floor neighbors are not automatically exploded into the working set.
    for sid, r in pairs(mapState.residentSectors) do
        if r ~= nil then mapState.pvsAddLatchedSector(active, sid) end
    end

    local recentN = 0
    for sid, expiry in pairs(mapState.pvsRecent) do
        if expiry > interiorElapsed then
            -- Recent rooms are a turn-around safety tail, not a reason to
            -- re-expand their whole same-floor adjacency.
            mapState.pvsAddLatchedSector(active, sid)
            recentN = recentN + 1
        else
            mapState.pvsRecent[sid] = nil
        end
    end
    mapState.pvsRecentActive = recentN

    local latchN = 0
    for pid, l in pairs(mapState.portalLatches) do
        if l ~= nil and (l.untilTime or 0.0) > interiorElapsed then
            mapState.pvsAddLatchedSector(active, l.a)
            mapState.pvsAddLatchedSector(active, l.b)
            latchN = latchN + 1
        else
            mapState.portalLatches[pid] = nil
        end
    end
    mapState.portalLatchCount = latchN

    if mapState.pvsPortalSector ~= nil and mapState.pvsPortalSector > 0
        and mapState.pvsPortalUntil > interiorElapsed then
        local ps = mapState.topoCell.sectors[mapState.pvsPortalSector]
        mapState.pvsAddEnvelope(
            active, mapState.pvsPortalSector,
            ps ~= nil and ps.kind == 'large_open')
    elseif mapState.pvsPortalSector ~= 0 then
        mapState.pvsPortalSector = 0
        mapState.pvsPortalUntil = 0.0
    end

    -- V22.1E: entry-local preload and authored door source-sector halo.
    -- pvsAddLatchedSector deliberately adds only the sector plus safe connector
    -- envelope; it does not recursively explode ordinary room adjacency.
    local entryIds = {}
    for sid, expiry in pairs(mapState.intercellEntryNearUntil or {}) do
        if expiry ~= nil and expiry > interiorElapsed then
            mapState.pvsAddLatchedSector(active, sid)
            entryIds[#entryIds + 1] = sid
        else
            mapState.intercellEntryNearUntil[sid] = nil
        end
    end
    table.sort(entryIds)
    mapState.intercellEntryNearCount = #entryIds
    mapState.intercellEntryNearSignature = table.concat(entryIds, ',')
    for sid, expiry in pairs(mapState.realDoorSourceUntil or {}) do
        if expiry ~= nil and expiry > interiorElapsed then
            mapState.pvsAddLatchedSector(active, sid)
        end
    end

    local ids = {}
    for sid = 1, mapState.pvsSectorCount do
        if active[sid] then ids[#ids + 1] = sid end
    end
    if #ids == 0 then
        pcall(camera.clearInteriorTopologyPvs)
        mapState.pvsSignature = nil
        mapState.pvsActiveCount = 0
        return
    end

    local signature = table.concat(ids, ',')

    -- V22.1D correctness gate: a lone sector out of a larger destination
    -- topology is low-confidence immediately after a load door. Keep PVS
    -- completely disabled until rays/movement/residency justify >=2 sectors.
    -- This never disables the ordinary VISGRID depth curtain.
    if mapState.intercellPvsQuarantine then
        mapState.intercellShadowPvsCount = #ids
        mapState.intercellShadowPvsIds = signature
        if signature ~= mapState.intercellLastShadowPvsIds then
            mapState.intercellLastShadowPvsIds = signature
            print(string.format(
                '[TSP_VISGRID_V22.1D] PVS SHADOW dest=%s active=%d/%d ids=%s entry=%d current=%d',
                tostring(mapState.intercellDest or '?'), #ids,
                mapState.pvsSectorCount or 0, signature,
                mapState.intercellEntrySector or 0, current))
        end
        local enoughSet = #ids >= mapState.v221dPvsMinIds
            or (mapState.pvsSectorCount or 0) < mapState.v221dLargeTopologyMin
        local learnDone = interiorElapsed >= (mapState.intercellPvsReleaseAfter or 0.0)
        local enough = enoughSet and learnDone
        if enough then
            mapState.intercellPvsQuarantine = false
            mapState.intercellPvsReleases = (mapState.intercellPvsReleases or 0) + 1
            print(string.format(
                '[TSP_VISGRID_V22.1D] PVS RELEASE dest=%s active=%d/%d ids=%s releases=%d',
                tostring(mapState.intercellDest or '?'), #ids,
                mapState.pvsSectorCount or 0, signature,
                mapState.intercellPvsReleases or 0))
        else
            pcall(camera.clearInteriorTopologyPvs)
            mapState.pvsSignature = nil
            mapState.pvsActiveCount = 0
            return
        end
    end

    if force or signature ~= mapState.pvsSignature then
        local ok, err = pcall(camera.setInteriorTopologyPvs,
            mapState.pvsBoxes, ids, mapState.v17PvsXyPad, mapState.v17PvsZPad)
        if ok then
            mapState.pvsSignature = signature
            mapState.pvsActiveCount = #ids
            print(string.format(
                '[TSP_VISGRID_V20] PVS floor=%d sector=%d active=%d/%d recent=%d latch=%d portal=%d',
                floorNow, current, #ids, mapState.pvsSectorCount,
                mapState.pvsRecentActive or 0, mapState.portalLatchCount or 0,
                mapState.pvsPortalSector or 0))
        else
            print('[TSP_VISGRID_V20] PVS bridge error -> disabled: ' .. tostring(err))
            pcall(camera.clearInteriorTopologyPvs)
            mapState.pvsBridge = false
            mapState.pvsSignature = nil
            mapState.pvsActiveCount = 0
        end
    end
end

mapState.switchTopology = function(cellName, x, y, z, dt)
    if mapState.topology == nil or mapState.topoCell == nil then return false end
    mapState.topoDwell = (mapState.topoDwell or 0.0) + (dt or 0.0)
    local sid, sec = mapState.topology.findSector(cellName, x, y, z)
    if sid == nil or sid == mapState.topoSectorId then
        mapState.topoCandidate = 0
        mapState.topoCandidateFrames = 0
        mapState.topoCandidateTime = 0.0
        return false
    end
    if mapState.topoCandidate == sid then
        mapState.topoCandidateFrames = mapState.topoCandidateFrames + 1
        mapState.topoCandidateTime = mapState.topoCandidateTime + (dt or 0.0)
    else
        mapState.topoCandidate = sid
        mapState.topoCandidateFrames = 1
        mapState.topoCandidateTime = 0.0
    end
    local candidateKind = sec ~= nil and tostring(sec.kind or 'room') or 'unmapped'
    local need = candidateKind == 'vertical_connector'
        and mapState.v16SectorHoldConnector or mapState.v16SectorHoldNormal
    if mapState.topoDwell < mapState.v16MinSectorDwell
        or mapState.topoCandidateTime < need then return false end

    local oldId, oldFloor = mapState.topoSectorId, mapState.topoFloor
    if oldId ~= nil and oldId > 0 then
        mapState.pvsRememberSector(oldId, mapState.v20CrossLatchSeconds)
    end
    mapState.pvsRememberSector(sid, mapState.v20CrossLatchSeconds)

    local crossPid, crossPortal = mapState.findPortalBetween(oldId, sid)
    if crossPortal ~= nil then
        mapState.latchPortal(
            crossPid, crossPortal, mapState.v20CrossLatchSeconds, 'cross')
        mapState.transitionOpenUntil
            = max(mapState.transitionOpenUntil,
                  interiorElapsed + mapState.v20TransitionOpenSeconds)
        mapState.transitionOld = oldId or 0
        mapState.transitionNew = sid or 0
        mapState.transitionOpens = mapState.transitionOpens + 1
        enterBurst = max(enterBurst, mapState.v18PortalBurst)
    end

    mapState.topoSectorId = sid
    mapState.topoSector = sec
    mapState.topoKind = candidateKind
    mapState.residentRemoveCurrent()
    if oldId ~= nil and oldId > 0 and oldId ~= sid then
        mapState.residentPromote(
            oldId, 'recent', nil, nil, mapState.v22ResidentMinHold)
    end
    mapState.topoFloor = sec ~= nil and tonumber(sec.floor or 0) or 0
    mapState.topoCandidate = 0
    mapState.topoCandidateFrames = 0
    mapState.topoCandidateTime = 0.0
    mapState.topoDwell = 0.0
    mapState.topoSwitches = mapState.topoSwitches + 1

    -- V16/V17: preserve the world-anchored live model across topology changes.
    turnLinger = max(turnLinger, 0.18)
    mapState.updateTopologyPvs(true)
    print(string.format(
        '[TSP_VISGRID_V20] context switch %d->%d floor=%d->%d kind=%s model=preserved',
        oldId or 0, mapState.topoSectorId, oldFloor or 0, mapState.topoFloor,
        mapState.topoKind))
    return true
end

mapState.primeTopologyPortals = function(ex, ey, ez, dt)
    mapState.primeRealDoors(ex, ey, ez)
    local tc, sec = mapState.topoCell, mapState.topoSector
    mapState.topoPortalPoll = (mapState.topoPortalPoll or 0.0) + (dt or 0.0)

    if tc == nil or sec == nil or sec.portals == nil then
        mapState.topoPortalHints = 0
        return
    end
    if mapState.topoPortalPoll < mapState.v16PortalPollPeriod then return end
    mapState.topoPortalPoll = 0.0

    local hinted = 0

    for i = 1, #sec.portals do
        local pid = sec.portals[i]
        local p = tc.portals[pid]
        if p ~= nil and (p.kind == 'door' or p.kind == 'boundary')
            and p.center ~= nil then
            local px, py, pz = p.center[1], p.center[2], p.center[3]
            local dx, dy, dz = px-ex, py-ey, pz-ez
            local d2 = dx*dx + dy*dy + dz*dz
            local dist = sqrt(d2)

            if dist > 1.0 then
                local idx = binOfDir(dx, dy, dz, dist)

                -- Mapped door portals can be self-loops (there is no second
                -- navmesh sector on the other side, as with a cell/load exit).
                -- Protect the physical door direction anyway.
                if p.kind == 'door' and dist <= mapState.v19DoorProtectRange
                    and mapState.topologyBinVisible(idx, 3) then
                    local by = (idx - 1) % YAW_BINS
                    local bp = floor((idx - 1) / YAW_BINS)
                    local expiry = interiorElapsed + mapState.v19DoorProtectTtl
                    local floorDepth = min(OPEN_DEPTH,
                        dist + mapState.v19DoorProtectMargin)
                    for dp = -1, 1 do
                        local pp = bp + dp
                        if pp >= 0 and pp < PITCH_BINS then
                            for dyw = -2, 2 do
                                local j = pp * YAW_BINS
                                    + ((by + dyw) % YAW_BINS) + 1
                                if mapState.doorProtectUntil[j] == nil
                                    or mapState.doorProtectUntil[j] < expiry then
                                    mapState.doorProtectUntil[j] = expiry
                                end
                                if mapState.doorProtectDepth[j] == nil
                                    or mapState.doorProtectDepth[j] < floorDepth then
                                    mapState.doorProtectDepth[j] = floorDepth
                                end
                            end
                        end
                    end
                    mapState.doorProtectSeen = mapState.doorProtectSeen + 1
                end

                local other = (p.a == mapState.topoSectorId) and p.b or p.a
                if other ~= nil and other > 0 and other ~= mapState.topoSectorId then
                    local otherSec = tc.sectors[other]
                    local largeTarget = otherSec ~= nil
                        and otherSec.kind == 'large_open'

                    -- Proximity is strong structural evidence.  Keep both sides
                    -- alive while physically near the threshold even if the
                    -- player has just turned away from it.
                    local nearRange
                    if largeTarget then nearRange = mapState.v19NearPortalHoldLarge
                    elseif p.kind == 'door' then nearRange = mapState.v19NearPortalHoldDoor
                    else nearRange = mapState.v19NearPortalHoldOther end

                    local v20Near
                    if largeTarget then v20Near = mapState.v20NearLarge
                    elseif p.kind == 'door' then v20Near = mapState.v20NearDoor
                    else v20Near = mapState.v20NearBoundary end

                    -- V20 threshold memory is symmetric and facing-independent.
                    -- Merely standing near the doorway keeps BOTH rooms alive,
                    -- and continues to do so after the topology sector flips.
                    if dist <= v20Near then
                        mapState.latchPortal(
                            pid, p, mapState.v20NearLatchSeconds, 'near')
                    elseif dist <= nearRange then
                        mapState.pvsRememberSector(
                            other, mapState.v19NearPortalHoldSeconds)
                    end

                    local structural = p.kind == 'door'
                        or largeTarget
                        or mapState.topoKind == 'vertical_connector'
                        or (otherSec ~= nil
                            and otherSec.kind == 'vertical_connector')

                    if structural then
                        local spread = largeTarget and 4
                            or ((p.kind == 'door') and 3 or 2)
                        local visible = mapState.topologyBinVisible(idx, spread)
                        local toward = false
                        if vdState.spd > 30.0 then
                            local md = mapState.moveDirX*dx
                                + mapState.moveDirY*dy + mapState.moveDirZ*dz
                            toward = (md / dist) >= mapState.v22MovePrefetchDot
                        end

                        if visible or toward then
                            -- If we're physically at the threshold, opening the
                            -- PVS alone is not enough: old short panorama depths
                            -- can still paint the destination red on a turn-back.
                            -- Open the portal wedge immediately every time it
                            -- re-enters the view while the near latch is active.
                            if dist <= v20Near then
                                local nearExpiry
                                    = interiorElapsed + mapState.v20VisibleNearGrace
                                mapState.openPortalWedge(
                                    idx, largeTarget, dist, nearExpiry, 15)
                                enterBurst = max(enterBurst, mapState.v18PortalBurst)
                                turnLinger = max(
                                    turnLinger, largeTarget and 1.05 or 0.85)
                            end

                            -- Pre-enable the destination BEFORE the player
                            -- reaches the doorway/opening.  This is intentionally
                            -- conservative: one neighboring room is cheaper than
                            -- one frame of red void.
                            local preRange
                            if largeTarget then preRange = mapState.v19LargePrefetchRange
                            elseif p.kind == 'door' then preRange = mapState.v19DoorPrefetchRange
                            else preRange = mapState.v19BoundaryPrefetchRange end

                            if toward then
                                preRange = preRange * mapState.v22MovePrefetchMult
                            end
                            if dist <= preRange then
                                local grace
                                if largeTarget then grace = mapState.v19RayPortalLargeGrace
                                elseif p.kind == 'door' then grace = mapState.v19RayPortalDoorGrace
                                else grace = mapState.v19RayPortalBoundaryGrace end

                                mapState.latchPortal(
                                    pid, p, mapState.v20NearLatchSeconds,
                                    'proximity')
                                if mapState.openPvsDestination(
                                    other, idx, largeTarget, dist, grace, 'proximity') then
                                    mapState.proximityOpens
                                        = mapState.proximityOpens + 1
                                    hinted = hinted + 1
                                end
                            end

                            -- Keep the old dedicated probe as SECONDARY evidence.
                            -- V19 no longer waits for it before opening a room.
                            local nextOk = mapState.topoPortalNext[pid] or 0.0
                            if interiorElapsed >= nextOk then
                                mapState.topoPortalNext[pid]
                                    = interiorElapsed + mapState.v16PortalRehint
                                local clear = mapState.pvsProbePortal(ex, ey, ez, p)
                                if clear then
                                    local grace
                                    if largeTarget then grace = mapState.v19RayPortalLargeGrace
                                    elseif p.kind == 'door' then grace = mapState.v19RayPortalDoorGrace
                                    else grace = mapState.v19RayPortalBoundaryGrace end

                                    mapState.latchPortal(
                                        pid, p, mapState.v20RayLatchSeconds,
                                        'probe')
                                    if mapState.openPvsDestination(
                                        other, idx, largeTarget, dist, grace, 'probe') then
                                        hinted = hinted + 1
                                    end
                                else
                                    -- Even a blocked probe means this mapped
                                    -- opening deserves live-ray attention.
                                    local by = (idx - 1) % YAW_BINS
                                    local bp = floor((idx - 1) / YAW_BINS)
                                    for dp = -1, 1 do
                                        local pp = bp + dp
                                        if pp >= 0 and pp < PITCH_BINS then
                                            for dyw = -2, 2 do
                                                local j = pp * YAW_BINS
                                                    + ((by + dyw) % YAW_BINS) + 1
                                                binPrio[j] = max(binPrio[j] or 0, 12)
                                            end
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    -- A proximity-held sector may have been added without the signature
    -- changing through openPvsDestination.
    mapState.updateTopologyPvs(false)
    mapState.topoPortalHints = hinted
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
    local pvsReject = 0.0
    local okStats, stats = pcall(camera.getInteriorVisibilityStats)
    if okStats and stats ~= nil then
        local tested = stats.tested or 0.0
        local culled = stats.culled or 0.0
        local dt = tested - lastStatsTested
        local dc = culled - lastStatsCulled
        lastStatsTested = tested
        lastStatsCulled = culled
        if dt > 0.0 then reject = dc * 100.0 / dt end

        local pt = stats.pvsTested or 0.0
        local pc = stats.pvsCulled or 0.0
        local pdt = pt - lastPvsTested
        local pdc = pc - lastPvsCulled
        lastPvsTested = pt
        lastPvsCulled = pc
        if pdt > 0.0 then pvsReject = pdc * 100.0 / pdt end
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
        .. string.format(
            ' spd=%.0f zc=%d v14=1 topo=%d sect=%d floor=%d kind=%s ph=%d sw=%d v20=1 pvsA=%d pvsR=%.1f%% pvsN=%d lat=%d lt=%d xop=%d pp=%d po=%d rp=%d ro=%d prox=%d dp=%d',
            vdState.spd, vdState.zc,
            mapState.topology ~= nil and 1 or 0, mapState.topoSectorId or 0,
            mapState.topoFloor or 0, tostring(mapState.topoKind or 'unmapped'),
            mapState.topoPortalHints or 0, mapState.topoSwitches or 0,
            mapState.pvsActiveCount or 0, pvsReject,
            mapState.pvsRecentActive or 0,
            mapState.portalLatchCount or 0, mapState.portalLatchTouches or 0,
            mapState.transitionOpens or 0,
            mapState.pvsProbeCount or 0, mapState.pvsProbeClear or 0,
            mapState.rayPortalChecks or 0, mapState.rayPortalOpens or 0,
            mapState.proximityOpens or 0, mapState.doorProtectSeen or 0)
        .. string.format(
            ' v21=1 rh=%d rht=%d rhc=%d rha=%d rhv=%d rhj=%d rhs=%d rd=%d rdm=%d rdx=%d rdt=%d',
            mapState.rayViewHoldCount or 0, mapState.rayViewHoldTouches or 0,
            mapState.rayViewHoldCloseReleases or 0,
            mapState.rayViewHoldAwayReleases or 0,
            mapState.rayViewHoldVerifyReleases or 0,
            mapState.rayViewHoldJumpDefers or 0,
            mapState.rayViewHoldTurnSkips or 0,
            mapState.realDoorCount or 0, mapState.realDoorPortalMatches or 0,
            mapState.realDoorWorldExits or 0, mapState.realDoorTargetSectors or 0)
        .. string.format(
            ' v22=1 rs=%d rprom=%d rray=%d rpre=%d rrec=%d rev=%d rov=%d rrj=%d rrf=%d rdt=%d',
            mapState.residentCount or 0, mapState.residentPromotions or 0,
            mapState.residentRayPromotions or 0, mapState.residentPredictions or 0,
            mapState.residentRecent or 0, mapState.residentEvictions or 0,
            mapState.residentOverflows or 0, mapState.residentRejects or 0,
            mapState.residentRayFinds or 0, mapState.residentDepthTouches or 0)
        .. string.format(
            ' v221=1 uzr=%.2f ub=%d upr=%d udeep=%d uclose=%d upb=%d uf=%d',
            mapState.upLookRate or 0.0, mapState.upBoostEvents or 0,
            mapState.upPredictCasts or 0, mapState.upDeepReports or 0,
            mapState.upCloseRun or 0, mapState.upPullbacks or 0,
            mapState.upFloorApplications or 0)
        .. string.format(
            ' v221d=1 pq=%d pqs=%d itx=%d ipurge=%d iprel=%d',
            mapState.intercellPvsQuarantine and 1 or 0,
            mapState.intercellShadowPvsCount or 0,
            mapState.intercellTransitions or 0, mapState.intercellPurges or 0,
            mapState.intercellPvsReleases or 0)
        .. string.format(
            ' v221e=1 igr=%d igf=%d igx=%d en=%d dh=%d dht=%d dhc=%d',
            (mapState.intercellGridLearnUntil or 0.0) > interiorElapsed and 1 or 0,
            mapState.intercellGridSuppressFrames or 0,
            mapState.intercellGridLearnEnds or 0,
            mapState.intercellEntryNearCount or 0,
            mapState.realDoorSourceCount or 0,
            mapState.realDoorSourceTouches or 0,
            mapState.realDoorSourceChanges or 0))
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
        hadStale = okS and st ~= nil
            and (st.enabled == true or st.pvsEnabled == true)
        pcall(camera.clearInteriorVisibilityGrid)
        if mapState.pvsBridge then pcall(camera.clearInteriorTopologyPvs) end
        mapState.pvsSignature = nil
        mapState.pvsActiveCount = 0
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

-- V22.1D: exact interior-cell analogue of the exterior safe-disarm path.
-- The exterior fix worked because the engine-side grid/PVS stores and all
-- cell-local structural memory were purged before the new worldspace could be
-- culled. Interior load doors need the same ownership boundary.
mapState.clearCellLocalVisibilityState = function(reason)
    if haveBridge then
        pcall(camera.clearInteriorVisibilityGrid)
        if mapState.pvsBridge then pcall(camera.clearInteriorTopologyPvs) end
    end
    mapState.pvsSignature = nil
    mapState.pvsActiveCount = 0
    mapState.pvsPortalSector = 0
    mapState.pvsPortalUntil = 0.0
    mapState.pvsRecent = {}
    mapState.pvsRecentActive = 0
    mapState.pvsRefreshElapsed = 0.0
    mapState.pvsDoorPair = {}
    mapState.pvsProbeCount = 0
    mapState.pvsProbeClear = 0
    mapState.doorProtectDepth = {}
    mapState.doorProtectUntil = {}
    mapState.portalLatches = {}
    mapState.portalLatchCount = 0
    mapState.portalLatchTouches = 0
    mapState.transitionOpenUntil = 0.0
    mapState.transitionOld = 0
    mapState.transitionNew = 0
    mapState.residentSectors = {}
    mapState.residentCount = 0
    mapState.rayViewHolds = {}
    mapState.rayViewHoldCount = 0
    mapState.realDoors = nil
    mapState.realDoorCount = 0
    mapState.intercellGridLearnUntil = 0.0
    mapState.intercellPvsReleaseAfter = 0.0
    mapState.intercellEntryNearUntil = {}
    mapState.intercellEntryNearCount = 0
    mapState.intercellEntryNearSignature = ''
    mapState.realDoorSourceUntil = {}
    mapState.realDoorSourceCount = 0
    mapState.realDoorSourceSignature = ''
    gridMaybeArmed = false
    mapState.intercellPurges = (mapState.intercellPurges or 0) + 1
    print(string.format(
        '[TSP_VISGRID_V22.1D] CELL-LOCAL PURGE reason=%s count=%d',
        tostring(reason), mapState.intercellPurges or 0))
end

mapState.beginIntercell = function(sourceName, destName, duringHold)
    mapState.intercellSource = sourceName
    mapState.intercellDest = destName
    mapState.intercellDuringHold = duringHold == true
    mapState.intercellPvsQuarantine = true
    mapState.intercellGridLearnUntil = mapState.v221eGridLearnGrace
    mapState.intercellPvsReleaseAfter = mapState.v221eGridLearnGrace
    mapState.intercellGridSuppressFrames = 0
    mapState.intercellEntryNearUntil = {}
    mapState.intercellEntryNearCount = 0
    mapState.intercellEntryNearSignature = ''
    mapState.realDoorSourceUntil = {}
    mapState.realDoorSourceCount = 0
    mapState.realDoorSourceSignature = ''
    mapState.intercellEntrySector = 0
    mapState.intercellShadowPvsCount = 0
    mapState.intercellShadowPvsIds = ''
    mapState.intercellLastShadowPvsIds = ''
    mapState.intercellTransitions = (mapState.intercellTransitions or 0) + 1
    mapState.pendingIntercellSource = nil
    mapState.pendingIntercellDest = nil
    mapState.pendingIntercellDuringHold = false
    print(string.format(
        '[TSP_VISGRID_V22.1D] INTERCELL BEGIN #%d source=%s dest=%s duringLoadHold=%d',
        mapState.intercellTransitions or 0, tostring(sourceName), tostring(destName),
        duringHold == true and 1 or 0))
    print(string.format(
        '[TSP_VISGRID_V22.1E] GRID LEARN-GRACE begin dest=%s seconds=%.1f (VISGRID+PVS fail-open; rays keep learning)',
        tostring(destName), mapState.v221eGridLearnGrace))
end

mapState.debugIntercellArrival = function(cellName, ex, ey, ez)
    if mapState.intercellDest ~= cellName then return end
    mapState.intercellEntrySector = mapState.topoSectorId or 0
    mapState.intercellDebugDumps = (mapState.intercellDebugDumps or 0) + 1
    local tx, ty, tz = mapState.topologyPosition(ex, ey, ez)
    local sec = mapState.topoSector
    local area = sec ~= nil and tonumber(sec.area or 0) or 0
    local center = sec ~= nil and sec.center or nil
    local bbox = sec ~= nil and sec.bbox or nil
    print(string.format(
        '[TSP_VISGRID_V22.1D] ARRIVAL dest=%s eye=(%.1f,%.1f,%.1f) topo=(%.1f,%.1f,%.1f) sector=%d/%d floor=%d kind=%s area=%.0f shadowPvs=%d ids=%s',
        tostring(cellName), ex, ey, ez, tx, ty, tz,
        mapState.topoSectorId or 0, mapState.pvsSectorCount or 0,
        mapState.topoFloor or 0, tostring(mapState.topoKind or 'unmapped'), area,
        mapState.intercellShadowPvsCount or 0,
        tostring(mapState.intercellShadowPvsIds or '')))
    if center ~= nil then
        print(string.format(
            '[TSP_VISGRID_V22.1D] ARRIVAL sectorCenter=(%.1f,%.1f,%.1f)',
            center[1] or 0, center[2] or 0, center[3] or 0))
    end
    if bbox ~= nil then
        print(string.format(
            '[TSP_VISGRID_V22.1D] ARRIVAL bbox=(%.1f,%.1f,%.1f)-(%.1f,%.1f,%.1f)',
            bbox[1] or 0, bbox[2] or 0, bbox[3] or 0,
            bbox[4] or 0, bbox[5] or 0, bbox[6] or 0))
    end
    if sec ~= nil and sec.neighbors ~= nil then
        local a = {}
        for i = 1, #sec.neighbors do a[#a + 1] = tostring(sec.neighbors[i]) end
        print('[TSP_VISGRID_V22.1D] ARRIVAL neighbors=' .. table.concat(a, ','))
    else
        print('[TSP_VISGRID_V22.1D] ARRIVAL neighbors=')
    end
    if sec ~= nil and sec.portals ~= nil and mapState.topoCell ~= nil then
        local a = {}
        for i = 1, #sec.portals do
            local pid = sec.portals[i]
            local p = mapState.topoCell.portals ~= nil and mapState.topoCell.portals[pid] or nil
            if p ~= nil then
                a[#a + 1] = string.format('%s:%s:%s-%s', tostring(pid),
                    tostring(p.kind or '?'), tostring(p.a or '?'), tostring(p.b or '?'))
            else
                a[#a + 1] = tostring(pid) .. ':missing'
            end
        end
        print('[TSP_VISGRID_V22.1D] ARRIVAL portals=' .. table.concat(a, ','))
    else
        print('[TSP_VISGRID_V22.1D] ARRIVAL portals=')
    end

    -- Door graph evidence nearest the arrival point, with reverse links to the
    -- source cell called out explicitly. This distinguishes bad topology from
    -- a bad/missing ESM transition edge without another instrumented build.
    local doors = mapState.realDoors
    if type(doors) == 'table' then
        local near = {}
        for i = 1, #doors do
            local d = doors[i]
            if d ~= nil and type(d.x) == 'number' and type(d.y) == 'number'
                and type(d.z) == 'number' then
                local dx, dy, dz = d.x-ex, d.y-ey, d.z-ez
                local dist = sqrt(dx*dx + dy*dy + dz*dz)
                if dist <= 2200.0 or (d.teleport == true
                    and d.destKind == 'interior'
                    and d.destCell == mapState.intercellSource) then
                    near[#near + 1] = { dist, d }
                end
            end
        end
        table.sort(near, function(a,b) return a[1] < b[1] end)
        local lim = min(#near, 8)
        for i = 1, lim do
            local d = near[i][2]
            local rev = d.teleport == true and d.destKind == 'interior'
                and d.destCell == mapState.intercellSource
            print(string.format(
                '[TSP_VISGRID_V22.1D] ARRIVAL door#%d dist=%.0f id=%s teleport=%d destKind=%s destCell=%s srcSec=%s destSec=%s reverseToSource=%d',
                i, near[i][1], tostring(d.id or '?'), d.teleport == true and 1 or 0,
                tostring(d.destKind or '?'), tostring(d.destCell or ''),
                tostring(d.sourceSector or 0), tostring(d.destSector or 0), rev and 1 or 0))
        end
    end

    if haveBridge then
        local ok, st = pcall(camera.getInteriorVisibilityStats)
        if ok and st ~= nil then
            print(string.format(
                '[TSP_VISGRID_V22.1D] ENGINE arrival enabled=%s pvsEnabled=%s tested=%s culled=%s pvsTested=%s pvsCulled=%s',
                tostring(st.enabled), tostring(st.pvsEnabled), tostring(st.tested),
                tostring(st.culled), tostring(st.pvsTested), tostring(st.pvsCulled)))
        end
    end
end

local function enterInterior(cellName, ex, ey, ez)
    -- bank the outgoing cell's learned panorama first (B)
    if inInterior and lastCellName ~= nil and lastEx ~= nil then
        cacheSave(lastCellName, lastEx, lastEy, lastEz)
    end
    -- V15: determine whether this cell has a real navmesh topology entry.
    -- Mapped cells use topology only as a structural hint: no scalar cap/Z
    -- clamp may override live ray depth. Unmapped cells retain V14 unchanged.
    mapState.topoCell = mapState.topology ~= nil and mapState.topology.getCell(cellName) or nil
    mapState.cap = OPEN_DEPTH
    mapState.zMin = nil
    mapState.zMax = nil
    if mapState.topoCell == nil and mapState.cells ~= nil then
        local e = mapState.cells[cellName]
        local capv = nil
        if type(e) == 'number' then
            capv = e
        elseif type(e) == 'table' and type(e.cap) == 'number' then
            capv = e.cap
        end
        if capv ~= nil and capv >= 900 then
            mapState.cap = min(OPEN_DEPTH, capv)
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
    mapState.rayViewHolds = {}
    mapState.rayViewHoldCount = 0
    mapState.residentSectors = {}
    mapState.residentCount = 0
    mapState.realDoors = nil
    mapState.moveDirX, mapState.moveDirY, mapState.moveDirZ = 0.0, 0.0, 0.0
    mapState.upLookLastZ = nil
    mapState.upLookRate = 0.0
    mapState.upBoostUntil = 0.0
    mapState.upBoostStrength = 0.0
    mapState.upBlockedUntil = 0.0
    mapState.upCloseRun = 0
    mapState.upOpenRun = 0
    resetPanorama()
    if mapState.topology ~= nil and mapState.topoCell ~= nil then
        local tx, ty, tz = mapState.topologyPosition(ex, ey, ez)
        local sid, sec = mapState.topology.findSector(cellName, tx, ty, tz)
        mapState.topoX, mapState.topoY, mapState.topoZ = tx, ty, tz
        mapState.topoDwell = 0.0
        mapState.topoCandidateTime = 0.0
        mapState.topoPortalPoll = 0.0
        mapState.topoPortalNext = {}
        mapState.topoSectorId = sid or 0
        mapState.topoSector = sec
        mapState.topoKind = sec ~= nil and tostring(sec.kind or 'room') or 'unmapped'
        mapState.topoFloor = sec ~= nil and tonumber(sec.floor or 0) or 0
        print(string.format(
            '[TSP_VISGRID_V15] topology sector=%d floor=%d kind=%s area=%s',
            mapState.topoSectorId, mapState.topoFloor, mapState.topoKind,
            tostring(sec ~= nil and sec.area or '?')))
    else
        mapState.topoSectorId = 0
        mapState.topoSector = nil
        mapState.topoKind = 'unmapped'
        mapState.topoFloor = 0
    end
    mapState.loadRealDoors(cellName)
    mapState.buildPvsBoxes()
    if mapState.intercellDest == cellName then
        mapState.seedIntercellEntryNeighborhood(ex, ey, ez)
        local tx, ty, tz = mapState.topologyPosition(ex, ey, ez)
        mapState.refreshRealDoorSourceSectors(tx, ty, tz)
    end
    mapState.updateTopologyPvs(true)
    cacheRestore(cellName, ex, ey, ez)
    if mapState.intercellDest == cellName then
        mapState.debugIntercellArrival(cellName, ex, ey, ez)
    end
    if haveBridge then
        pcall(camera.resetInteriorVisibilityStats)
        lastStatsTested, lastStatsCulled = 0.0, 0.0
    lastPvsTested, lastPvsCulled = 0.0, 0.0
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
    if haveBridge then
        pcall(camera.clearInteriorVisibilityGrid)
        if mapState.pvsBridge then pcall(camera.clearInteriorTopologyPvs) end
    end
    mapState.pvsSignature = nil
    mapState.pvsActiveCount = 0
    mapState.pvsPortalSector = 0
    mapState.pvsPortalUntil = 0.0
    mapState.pvsRecent = {}
    mapState.pvsRecentActive = 0
    mapState.pvsRefreshElapsed = 0.0
    mapState.portalLatches = {}
    mapState.portalLatchCount = 0
    mapState.portalLatchTouches = 0
    mapState.transitionOpenUntil = 0.0
    mapState.transitionOld = 0
    mapState.transitionNew = 0
    mapState.realDoors = nil
    mapState.realDoorCount = 0
    mapState.rayViewHolds = {}
    mapState.rayViewHoldCount = 0
    mapState.residentSectors = {}
    mapState.residentCount = 0
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

    -- TSP_VISGRID_V20_LOADSAFE_6S
    -- V22.1D diagnostic/lifecycle fix: even while culling is intentionally
    -- disabled, remember which interior cell owns each frame. A load-door
    -- transition during this six-second gate used to disappear from the Lua
    -- lifecycle entirely (exactly what the Pelagiad trace showed).
    local holdName = tostring(cell.name or cell.id or '?')
    if postLoadArmRemaining > 0.0 then
        if mapState.holdCellName == nil then
            mapState.holdCellName = holdName
            print('[TSP_VISGRID_V22.1D] LOAD-HOLD cell=' .. holdName)
        elseif holdName ~= mapState.holdCellName then
            mapState.pendingIntercellSource = mapState.holdCellName
            mapState.pendingIntercellDest = holdName
            mapState.pendingIntercellDuringHold = true
            print(string.format(
                '[TSP_VISGRID_V22.1D] LOAD-HOLD CELL CHANGE source=%s dest=%s',
                tostring(mapState.holdCellName), holdName))
            mapState.holdCellName = holdName
        end
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
        if mapState.pendingIntercellDest == cellName
            and mapState.pendingIntercellSource ~= nil then
            mapState.clearCellLocalVisibilityState('pending-intercell-after-load-hold')
            mapState.beginIntercell(
                mapState.pendingIntercellSource, cellName, true)
        end
        enterInterior(cellName, ex, ey, ez)
    elseif cellName ~= lastCellName then
        local sourceCell = lastCellName
        mapState.clearCellLocalVisibilityState('interior-cell-change')
        mapState.beginIntercell(sourceCell, cellName, false)
        enterInterior(cellName, ex, ey, ez)
        print('[TSP_VISGRID_V11] reset reason=cell-change')
    else
        local mx, my, mz = ex - (lastEx or ex), ey - (lastEy or ey), ez - (lastEz or ez)
        moveDist = sqrt(mx * mx + my * my + mz * mz)
        if moveDist > 1.0 and moveDist <= TELEPORT_RESET_DIST then
            mapState.moveDirX = mx / moveDist
            mapState.moveDirY = my / moveDist
            mapState.moveDirZ = mz / moveDist
        end
        if moveDist > TELEPORT_RESET_DIST and interiorElapsed > LOAD_GRACE_SECONDS then
            enterInterior(cellName, ex, ey, ez)
            print('[TSP_VISGRID_V11] reset reason=teleport')
            moveDist = 0.0
        else
            transportTranslation(mx, my, mz, moveDist, ex, ey, ez)
            lastEx, lastEy, lastEz = ex, ey, ez
        end
    end

    -- V16: topology is slow context, never visibility-model ownership.
    if mapState.switchTopology ~= nil then
        local tx, ty, tz = mapState.topologyPosition(ex, ey, ez)
        mapState.topoX, mapState.topoY, mapState.topoZ = tx, ty, tz
        mapState.switchTopology(cellName, tx, ty, tz, dt)
        mapState.pvsRefreshElapsed = (mapState.pvsRefreshElapsed or 0.0) + dt
        if mapState.pvsRefreshElapsed >= mapState.v18PvsRefresh then
            mapState.pvsRefreshElapsed = 0.0
            mapState.updateTopologyPvs(false)
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

    -- V22.1: read post-input camera direction before publish, so a fast right-stick
    -- upward motion can pre-open Z on THIS frame rather than waiting for stale rays.
    mapState.updateUpwardAnticipation(dt)

    -- C. watch nearby doors for state changes
    doorPollElapsed = doorPollElapsed + dt
    if doorPollElapsed >= DOOR_POLL_PERIOD then
        doorPollElapsed = 0.0
        pollDoors(ex, ey, ez)
    end

    -- Publish first so visList/tileBin reflect the CURRENT camera.
    publishGrid(ez)

    -- V16: view-aware topology hints intentionally affect the next frame.
    if mapState.primeTopologyPortals ~= nil then
        local tx, ty, tz = mapState.topologyPosition(ex, ey, ez)
        mapState.primeTopologyPortals(tx, ty, tz, dt)
    end

    -- V14: expose turn state to the publish/accept paths (fast-close gate)
    vdState.turnf = turning and 1 or 0

    local budget = RAYS_STEADY
    if enterBurst > 0.0 or youngVisible > YOUNG_BURST_MIN then budget = RAYS_ENTER
    elseif turning or youngVisible > 0 then budget = RAYS_TURN end
    if (mapState.upBoostUntil or 0.0) > interiorElapsed then
        budget = budget + mapState.v221UpExtraRays
    end
    if (mapState.intercellGridLearnUntil or 0.0) > interiorElapsed then
        budget = max(budget, RAYS_ENTER)
    end

    chooseAndCast(budget, ex, ey, ez, turning)

    -- A. Large/open sectors remain real-ray authoritative. In tighter mapped
    -- rooms/corridors the existing wall-plane fill remains useful.
    if mapState.topoKind ~= 'large_open' then
        planeFillPass(ex, ey, ez)
    end

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

print('[TSP_VISGRID_V20] threshold-latch PVS loaded (symmetric portal memory + ray authority + door bypass companion)')
print('[TSP_VISGRID_V21] real-door overlay + view-relative positive-ray memory loaded')
print('[TSP_VISGRID_V21.1] stable-aperture hysteresis loaded (turn freeze + exact-witness disproof + jump guard)')
print('[TSP_VISGRID_V22] resident room-groups loaded (current + predicted + ray-promoted; negative rays cannot evict)')
print('[TSP_VISGRID_V22.1] upward anticipation loaded (camera-Z momentum + pitch-leading rays + ceiling pullback)')
print('[TSP_VISGRID_V22.1D] intercell cell-local purge + fail-open PVS quarantine + deep diagnostics loaded')
print('[TSP_VISGRID_V22.1E] learn-first intercell preload + local topology neighborhood + real-door source-sector frame halo loaded')

return {
    engineHandlers = {
        onInit = function() guarded('onInit', onInit) end,
        onLoad = function(a) guarded('onLoad', onLoad, a) end,
        onFrame = function(dt) guarded('onFrame', onFrameBody, dt) end,
    },
}

EOF_V221E_SENSOR

NEW_SHA="$(sha256sum "$PKG/visgrid-v22.1e.lua" | awk '{print $1}')"
echo "Generated sensor SHA: $NEW_SHA"
[ "$NEW_SHA" = "$EXPECTED_NEW_SHA" ]
grep -Fq 'TSP_VISGRID_LUA_V22_1E_ENTRY_PRELOAD_DOORFRAME' "$PKG/visgrid-v22.1e.lua"
grep -Fq 'GRID LEARN-GRACE begin' "$PKG/visgrid-v22.1e.lua"
grep -Fq 'ENTRY-NEAR PRELOAD' "$PKG/visgrid-v22.1e.lua"
grep -Fq 'DOOR-SOURCE HALO' "$PKG/visgrid-v22.1e.lua"
grep -Fq 'v221e=1 igr=' "$PKG/visgrid-v22.1e.lua"
echo "PASS: exact deterministic V22.1E bytes/material markers verified."

echo
echo "===== 3/7 LUA SYNTAX GATE ====="
PARSED=0
if command -v luac >/dev/null 2>&1; then
    luac -p "$PKG/visgrid-v22.1e.lua"
    echo "PASS: host luac parse"
    PARSED=1
elif command -v lua >/dev/null 2>&1; then
    lua -e 'local f,e=loadfile(arg[1]); assert(f,e)' "$PKG/visgrid-v22.1e.lua"
    echo "PASS: host lua parse"
    PARSED=1
elif command -v texlua >/dev/null 2>&1; then
    cat > "$PKG/check-lua.lua" <<'LUA_PARSE'
local f, e = loadfile(arg[1])
if not f then error(e) end
print('PARSE PASS ' .. tostring(arg[1]))
LUA_PARSE
    texlua "$PKG/check-lua.lua" "$PKG/visgrid-v22.1e.lua"
    PARSED=1
elif command -v luatex >/dev/null 2>&1; then
    cat > "$PKG/check-lua.lua" <<'LUA_PARSE'
local f, e = loadfile(arg[1])
if not f then error(e) end
print('PARSE PASS ' .. tostring(arg[1]))
LUA_PARSE
    luatex --luaonly "$PKG/check-lua.lua" "$PKG/visgrid-v22.1e.lua"
    PARSED=1
elif command -v docker >/dev/null 2>&1 && docker inspect "$CTR" >/dev/null 2>&1; then
    if [ "$(docker inspect -f '{{.State.Running}}' "$CTR")" != "true" ]; then
        docker start "$CTR" >/dev/null
    fi
    docker cp "$PKG/visgrid-v22.1e.lua" "$CTR:/tmp/visgrid-v22.1e.lua" >/dev/null
    if docker exec "$CTR" bash -lc 'command -v luac >/dev/null 2>&1'; then
        docker exec "$CTR" luac -p /tmp/visgrid-v22.1e.lua
        echo "PASS: Docker luac parse"
        PARSED=1
    elif docker exec "$CTR" bash -lc 'command -v lua >/dev/null 2>&1'; then
        docker exec "$CTR" lua -e 'local f,e=loadfile(arg[1]); assert(f,e)' /tmp/visgrid-v22.1e.lua
        echo "PASS: Docker lua parse"
        PARSED=1
    elif docker exec "$CTR" bash -lc 'command -v luajit >/dev/null 2>&1'; then
        docker exec "$CTR" luajit -b /tmp/visgrid-v22.1e.lua /tmp/visgrid-v22.1e.ljbc
        echo "PASS: Docker LuaJIT parse/bytecode"
        PARSED=1
    fi
fi
if [ "$PARSED" = "0" ]; then
    echo "NOTE: no Lua CLI parser is installed on this VM/container."
    echo "PASS: continuing because the materialized file is byte-identical to the"
    echo "      independently texlua-parse-validated V22.1E SHA $EXPECTED_NEW_SHA."
fi

echo
echo "===== 4/7 BACK UP EXACT V22.1D SENSOR ====="
REMOTE_BACKUP_DIR="$MOD/visgrid-backups/v22-1e-$STAMP"
REMOTE_BACKUP="$REMOTE_BACKUP_DIR/visgrid-v22.1d.lua"
ssh "$DEV" "
    set -e
    mkdir -p '$REMOTE_BACKUP_DIR'
    cp -p '$LIVE_LUA' '$REMOTE_BACKUP'
    test \"\$(sha256sum '$REMOTE_BACKUP' | awk '{print \$1}')\" = '$EXPECTED_BASE_SHA'
    sync
"
ROLLBACK_READY=1
echo "PASS: device backup $REMOTE_BACKUP"

echo
echo "===== 5/7 INSTALL V22.1E SENSOR ONLY ====="
REMOTE_TMP="$LIVE_LUA.v22-1e-$STAMP.tmp"
scp -q "$PKG/visgrid-v22.1e.lua" "$DEV:$REMOTE_TMP"
ssh "$DEV" "
    set -e
    test \"\$(sha256sum '$REMOTE_TMP' | awk '{print \$1}')\" = '$EXPECTED_NEW_SHA'
    chmod --reference='$LIVE_LUA' '$REMOTE_TMP' 2>/dev/null || chmod 644 '$REMOTE_TMP'
    mv '$REMOTE_TMP' '$LIVE_LUA'
    sync
    test \"\$(sha256sum '$LIVE_LUA' | awk '{print \$1}')\" = '$EXPECTED_NEW_SHA'
    grep -Fq 'TSP_VISGRID_LUA_V22_1E_ENTRY_PRELOAD_DOORFRAME' '$LIVE_LUA'
"
echo "PASS: V22.1E installed."

echo
echo "===== 6/7 VERIFY NOTHING ELSE CHANGED ====="
LIVE_SHA_AFTER="$(ssh "$DEV" "sha256sum '$LIVE_LUA'" | awk '{print $1}')"
GAME_SHA_AFTER="$(ssh "$DEV" "sha256sum '$GAME'" | awk '{print $1}')"
TOPO_SHA_AFTER="$(ssh "$DEV" "sha256sum '$TOPOLOGY'" | awk '{print $1}')"
DOOR_SHA_AFTER="$(ssh "$DEV" "sha256sum '$DOORGRAPH'" | awk '{print $1}')"
DB_STAT_AFTER="$(ssh "$DEV" "stat -c '%s %Y' '$DB'")"
TOPO_COUNT_AFTER="$(ssh "$DEV" "find '$TOPOLOGY_CELLS' -maxdepth 1 -type f -name 'c_*.lua' | wc -l")"
DOOR_COUNT_AFTER="$(ssh "$DEV" "find '$DOORGRAPH_CELLS' -maxdepth 1 -type f -name 'c_*.lua' | wc -l")"

[ "$LIVE_SHA_AFTER" = "$EXPECTED_NEW_SHA" ]
[ "$GAME_SHA_AFTER" = "$GAME_SHA_BEFORE" ]
[ "$TOPO_SHA_AFTER" = "$TOPO_SHA_BEFORE" ]
[ "$DOOR_SHA_AFTER" = "$DOOR_SHA_BEFORE" ]
[ "$DB_STAT_AFTER" = "$DB_STAT_BEFORE" ]
[ "$TOPO_COUNT_AFTER" = "$TOPO_COUNT_BEFORE" ]
[ "$DOOR_COUNT_AFTER" = "$DOOR_COUNT_BEFORE" ]

echo "sensor:          $LIVE_SHA_AFTER"
echo "game unchanged:  $GAME_SHA_AFTER"
echo "topology same:   $TOPO_SHA_AFTER"
echo "doorgraph same:  $DOOR_SHA_AFTER"
echo "DB same:         $DB_STAT_AFTER"
echo "topology shards: $TOPO_COUNT_AFTER"
echo "doorgraph shards:$DOOR_COUNT_AFTER"
echo "PASS: protected binary/data invariants remained byte-identical."
ROLLBACK_READY=0

echo
echo "===== 7/7 WRITE TRACE + ROLLBACK HELPERS ====="
COLLECTOR="$HOME/Downloads/pull-visgrid-v22-1e-entry-doorframe.sh"
cat > "$COLLECTOR" <<'TRACE'
#!/usr/bin/env bash
set -Eeuo pipefail
cd "$HOME/Downloads"
DEV="${TSP_DEV:-root@192.168.1.25}"
ROOT="/mnt/SDCARD/data/ports/openmw51"
BASE="$ROOT/mods/TSPInteriorVisGrid/scripts/TSPInteriorVisGrid"
STAMP="$(date +%Y%m%d-%H%M%S)"
CORE="$HOME/Downloads/visgrid-v22-1e-entry-doorframe-core-$STAMP.txt"
RAW="$HOME/Downloads/visgrid-v22-1e-entry-doorframe-raw-$STAMP.txt"

{
    echo "===== INSTALLED SENSOR / DATA ====="
    ssh "$DEV" "sha256sum '$BASE/visgrid.lua' 2>/dev/null || true; grep -nE 'TSP_VISGRID_LUA_V22_1(D|E)' '$BASE/visgrid.lua' 2>/dev/null || true; echo topology_shards=\$(find '$BASE/topology_cells' -maxdepth 1 -type f -name 'c_*.lua' 2>/dev/null | wc -l); echo doorgraph_shards=\$(find '$BASE/doorgraph_cells' -maxdepth 1 -type f -name 'c_*.lua' 2>/dev/null | wc -l)"
    echo
    echo "===== V22.1E ENTRY / DOOR-FRAME TRACE ====="
    ssh "$DEV" '
        ROOT=/mnt/SDCARD/data/ports/openmw51
        for LOG in \
            "$ROOT/openmw_051_log.txt" \
            "$ROOT/log-0.51.txt" \
            "$ROOT/config-0.51/openmw.log" \
            "$ROOT/config-0.51/openmw.log.old"
        do
            [ -s "$LOG" ] || continue
            echo
            echo "--- $LOG ---"
            tail -n 20000 "$LOG" |
            grep -E "TSP_VISGRID_V22\\.1E|TSP_VISGRID_V22\\.1D|GRID LEARN-GRACE|ENTRY-NEAR PRELOAD|DOOR-SOURCE HALO|INTERCELL BEGIN|PVS SHADOW|PVS RELEASE|PVS floor=|context switch|v221e=1|first_.*error| ERROR #|sensor DISABLED|Changing to interior|Loading cell |Unloading cell " || true
        done
    '
} | tee "$CORE"

ssh "$DEV" '
    ROOT=/mnt/SDCARD/data/ports/openmw51
    for LOG in \
        "$ROOT/openmw_051_log.txt" \
        "$ROOT/log-0.51.txt" \
        "$ROOT/config-0.51/openmw.log" \
        "$ROOT/config-0.51/openmw.log.old"
    do
        [ -s "$LOG" ] || continue
        echo
        echo "--- $LOG ---"
        tail -n 20000 "$LOG"
    done
' > "$RAW"

echo
echo "Saved core trace: $CORE"
echo "Saved raw 20k-line tails: $RAW"
TRACE
chmod +x "$COLLECTOR"

ROLLBACK_HELPER="$HOME/Downloads/restore-visgrid-v22-1d-from-v22-1e.sh"
cat > "$ROLLBACK_HELPER" <<'ROLLBACK'
#!/usr/bin/env bash
set -Eeuo pipefail
DEV="${TSP_DEV:-root@192.168.1.25}"
LIVE="__LIVE__"
BACKUP="__BACKUP__"
EXPECTED="__EXPECTED__"
BACKUP_SHA="$(ssh "$DEV" "sha256sum '$BACKUP'" | awk '{print $1}')"
[ "$BACKUP_SHA" = "$EXPECTED" ]
ssh "$DEV" "set -e; cp -p '$BACKUP' '$LIVE'; sync"
LIVE_SHA="$(ssh "$DEV" "sha256sum '$LIVE'" | awk '{print $1}')"
echo "$LIVE_SHA  $LIVE"
[ "$LIVE_SHA" = "$EXPECTED" ]
echo "PASS: exact V22.1D restored. Restart OpenMW."
ROLLBACK
python3 - "$ROLLBACK_HELPER" "$LIVE_LUA" "$REMOTE_BACKUP" "$EXPECTED_BASE_SHA" <<'PY_ROLLBACK_FILL'
from pathlib import Path
import sys
p = Path(sys.argv[1])
s = p.read_text()
for token, value in (("__LIVE__", sys.argv[2]), ("__BACKUP__", sys.argv[3]), ("__EXPECTED__", sys.argv[4])):
    if token not in s:
        raise SystemExit("missing rollback placeholder: " + token)
    if any(c in value for c in ('\n', '\r', '"')):
        raise SystemExit("unsafe rollback placeholder value")
    s = s.replace(token, value)
p.write_text(s, encoding='utf-8', newline='\n')
PY_ROLLBACK_FILL
chmod +x "$ROLLBACK_HELPER"

bash -n "$COLLECTOR"
bash -n "$ROLLBACK_HELPER"

echo
echo "=================================================================="
echo "VISGRID V22.1E INSTALL COMPLETE"
echo "=================================================================="
echo "Installed SHA: $LIVE_SHA_AFTER"
echo
echo "Test one route:"
echo "  Fort Pelagiad -> South Wall -> immediately turn/down staircase ->"
echo "  bottom hallway -> back up -> stand/look at Fort Pelagiad door/frame"
echo
echo "Expected V22.1E diagnostics:"
echo "  igr=1  : first six seconds are learn-only/fail-open"
echo "  en=N   : bounded entry-near topology sectors preloaded (max 12)"
echo "  dh=N   : currently protected real-door source sectors"
echo "  South Wall should show a DOOR-SOURCE HALO containing sector 22"
echo "  while you are back near the Fort Pelagiad return door."
echo
echo "After the single test run:"
echo "  cd ~/Downloads"
echo "  ./pull-visgrid-v22-1e-entry-doorframe.sh"
echo
echo "One-command rollback if visual behavior regresses:"
echo "  cd ~/Downloads"
echo "  ./restore-visgrid-v22-1d-from-v22-1e.sh"
echo
echo "Controller log: $LOG"
echo "=================================================================="
