#!/usr/bin/env bash
set -Eeuo pipefail

DEV="${TSP_DEV:-root@192.168.1.25}"
ROOT="/mnt/SDCARD/data/ports/openmw51"
BIN="$ROOT/bin/openmw-0.51"
MOD="$ROOT/mods/TSPInteriorVisGrid"
OMW="$MOD/TSPInteriorVisGrid.omwscripts"
LUA="$MOD/scripts/TSPInteriorVisGrid/visgrid.lua"
STAMP="$(date +%Y%m%d-%H%M%S)"
PKG="$HOME/Downloads/openmw51-interior-visgrid-v2-realtime-$STAMP"
LOG="$PKG/install.log"
BACKUP="$ROOT/backups/interior-visgrid-v2-realtime-$STAMP"
mkdir -p "$PKG"

fail_report() {
  local rc="${1:-1}" line="${2:-unknown}" cmd="${3:-unknown}"
  trap - ERR
  set +e
  local report="$PKG/STOPPED_ERROR.txt"
  {
    echo
    echo "=================================================================="
    echo "VISGRID V2 REALTIME STOPPED SAFELY"
    echo "=================================================================="
    echo "Date: $(date)"
    echo "Exit code: $rc"
    echo "Script line: $line"
    echo "Failing command: $cmd"
    echo
    if [ -f "$LOG" ]; then
      echo "----- install.log : LAST 220 LINES -----"
      tail -220 "$LOG" || true
    fi
    echo
    echo "Everything produced so far is preserved at: $PKG"
    echo "Error report: $report"
    echo "=================================================================="
  } 2>&1 | tee "$report"
  echo
  echo "SCRIPT STOPPED. TERMINAL REMAINS OPEN."
  if [ -t 0 ]; then
    read -r -p "Press Enter to return to the shell... " _ || true
  fi
  exit "$rc"
}
trap 'fail_report "$?" "$LINENO" "$BASH_COMMAND"' ERR
exec > >(tee "$LOG") 2>&1

echo "=================================================================="
echo "OPENMW 0.51 TSP — INTERIOR VISGRID V2 REALTIME SENSOR"
echo "=================================================================="
echo "Lua-only update. The working V1 C++ culler/binary is left untouched."
echo "V2 samples all 40 tiles every frame and removes V1 camera-reset storms."
echo "Package: $PKG"
echo

echo "===== 1/6 VERIFY CURRENT INSTALL ====="
ssh -o BatchMode=yes -o ConnectTimeout=8 "$DEV" "
set -e
test -s '$BIN'
test -f '$OMW'
test -f '$LUA'
grep -a -q 'TSP_INTERIOR_VISGRID_051_V1' '$BIN'
grep -Fq 'TSPInteriorVisGrid/visgrid.lua' '$OMW'
echo PASS
"
if ssh "$DEV" 'pidof openmw-0.51 >/dev/null 2>&1 || pidof openmw >/dev/null 2>&1'; then
  echo "ERROR: OpenMW is running. Exit it normally and rerun this same script."
  exit 20
fi

echo "===== 2/6 BACK UP V1 LUA ====="
ssh "$DEV" "
set -e
mkdir -p '$BACKUP'
cp -p '$LUA' '$BACKUP/visgrid.lua.before-v2'
cp -p '$OMW' '$BACKUP/TSPInteriorVisGrid.omwscripts'
sha256sum '$LUA' '$OMW' > '$BACKUP/SHA256SUMS.before.txt'
sync
cat '$BACKUP/SHA256SUMS.before.txt'
"
scp -q "$DEV:$LUA" "$PKG/visgrid.lua.before-v2"
scp -q "$DEV:$OMW" "$PKG/TSPInteriorVisGrid.omwscripts.before-v2"

echo "===== 3/6 GENERATE V2 LUA ====="
cat > "$PKG/visgrid.lua" <<'EOF_LUA'
-- TSP_INTERIOR_VISGRID_LUA_V2
-- Realtime sensor for the existing TSP_INTERIOR_VISGRID_051_V1 C++ culler.
-- V2 samples all 8x5=40 tiles from the CURRENT camera pose every frame.

local camera = require('openmw.camera')
local core = require('openmw.core')
local nearby = require('openmw.nearby')
local self = require('openmw.self')
local util = require('openmw.util')

local COLS, ROWS = 8, 5
local COUNT = COLS * ROWS
local MAX_DIST = 5500.0
local PADDING = 350.0
local CLOSE_CONFIRM_TOLERANCE = 180.0
local PRINT_PERIOD = 2.0
local RAY_MASK = nearby.COLLISION_TYPE.World + (nearby.COLLISION_TYPE.Door or 0)

local depth, pendingClose, screenPos, neighbors, published = {}, {}, {}, {}, {}
local inInterior = false
local lastPrint = 0.0
local lastStatsTested, lastStatsCulled = 0.0, 0.0
local sensorFrames, sensorTimeSum, sensorTimeMax, sensorRayFailures = 0, 0.0, 0.0, 0

local function precompute()
  for row = 1, ROWS do
    for col = 1, COLS do
      local idx = (row - 1) * COLS + col
      screenPos[idx] = util.vector2((col - 0.5) / COLS, (row - 0.5) / ROWS)
      local list = {}
      for rr = math.max(1, row - 1), math.min(ROWS, row + 1) do
        for cc = math.max(1, col - 1), math.min(COLS, col + 1) do
          list[#list + 1] = (rr - 1) * COLS + cc
        end
      end
      neighbors[idx] = list
    end
  end
end

local function fillMax()
  for i = 1, COUNT do
    depth[i] = MAX_DIST
    pendingClose[i] = nil
    published[i] = MAX_DIST
  end
end

local function acceptDepth(idx, measured)
  if measured == nil or measured ~= measured or measured <= 0.0 then measured = MAX_DIST end
  measured = math.max(1.0, math.min(MAX_DIST, measured))
  local current = depth[idx] or MAX_DIST

  -- Openings/farther visibility become permissive immediately.
  if measured >= current then
    depth[idx] = measured
    pendingClose[idx] = nil
    return
  end

  -- New close walls require two consecutive current-frame confirmations.
  local pending = pendingClose[idx]
  if pending ~= nil and math.abs(pending - measured) <= CLOSE_CONFIRM_TOLERANCE then
    depth[idx] = math.max(pending, measured)
    pendingClose[idx] = nil
  else
    pendingClose[idx] = measured
  end
end

local function sampleCurrentFrame(eye)
  local t0 = core.getRealTime()
  for idx = 1, COUNT do
    local okDir, dir = pcall(camera.viewportToWorldVector, screenPos[idx])
    if not okDir or dir == nil then
      sensorRayFailures = sensorRayFailures + 1
      acceptDepth(idx, MAX_DIST)
    else
      local len = dir:length()
      if len == nil or len <= 0.0001 then
        sensorRayFailures = sensorRayFailures + 1
        acceptDepth(idx, MAX_DIST)
      else
        local dest = eye + dir / len * MAX_DIST
        local okRay, res = pcall(nearby.castRay, eye, dest, { collisionType = RAY_MASK })
        if not okRay or res == nil then
          sensorRayFailures = sensorRayFailures + 1
          acceptDepth(idx, MAX_DIST)
        else
          local d = MAX_DIST
          if res.hit and res.hitPos ~= nil then d = (res.hitPos - eye):length() end
          acceptDepth(idx, d)
        end
      end
    end
  end
  local t1 = core.getRealTime()
  if t0 ~= nil and t1 ~= nil and t1 >= t0 then
    local e = t1 - t0
    sensorFrames = sensorFrames + 1
    sensorTimeSum = sensorTimeSum + e
    if e > sensorTimeMax then sensorTimeMax = e end
  end
end

local function publishGrid()
  -- Keep V1's conservative 3x3 max dilation; reuse the table each frame.
  for idx = 1, COUNT do
    local best = 0.0
    local list = neighbors[idx]
    for n = 1, #list do
      local d = depth[list[n]]
      if d > best then best = d end
    end
    published[idx] = best
  end
  camera.setInteriorVisibilityGrid(COLS, ROWS, published, PADDING)
end

local function printStatus()
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
  local tested, culled = stats.tested or 0.0, stats.culled or 0.0
  local dt, dc = tested - lastStatsTested, culled - lastStatsCulled
  lastStatsTested, lastStatsCulled = tested, culled
  local reject = dt > 0.0 and (dc * 100.0 / dt) or 0.0
  local avgMs = sensorFrames > 0 and (sensorTimeSum * 1000.0 / sensorFrames) or 0.0
  local maxMs = sensorTimeMax * 1000.0

  print(string.format(
    '[TSP_VISGRID_V2] grid=%dx%d min=%.0f mean=%.0f max=%.0f tested_delta=%.0f culled_delta=%.0f reject=%.1f%% total_tested=%.0f total_culled=%.0f rays_per_frame=%d sensor_avg_ms=%.3f sensor_max_ms=%.3f ray_failures=%d',
    COLS, ROWS, minD, sum / COUNT, maxD, dt, dc, reject, tested, culled,
    COUNT, avgMs, maxMs, sensorRayFailures))

  sensorFrames, sensorTimeSum, sensorTimeMax, sensorRayFailures = 0, 0.0, 0.0, 0
end

local function onInit()
  precompute()
  fillMax()
  if camera.clearInteriorVisibilityGrid ~= nil then camera.clearInteriorVisibilityGrid() end
  print(string.format('[TSP_VISGRID_V2] realtime loaded grid=%dx%d rays_per_frame=%d max=%.0f padding=%.0f', COLS, ROWS, COUNT, MAX_DIST, PADDING))
end

local function onFrame(dt)
  if dt == nil or dt <= 0.0 then return end
  local cell = self.cell
  if cell == nil then return end

  if cell.isExterior then
    if inInterior then
      inInterior = false
      camera.clearInteriorVisibilityGrid()
      fillMax()
      print('[TSP_VISGRID_V2] exit interior -> grid off')
    end
    return
  end

  local eye = camera.getPosition()
  if eye == nil then return end

  if not inInterior then
    inInterior = true
    fillMax()
    camera.resetInteriorVisibilityStats()
    lastStatsTested, lastStatsCulled = 0.0, 0.0
    sensorFrames, sensorTimeSum, sensorTimeMax, sensorRayFailures = 0, 0.0, 0.0, 0
    print('[TSP_VISGRID_V2] enter interior -> realtime grid active')
  end

  sampleCurrentFrame(eye)
  publishGrid()

  local live = camera.getViewDistance() or MAX_DIST
  if live < MAX_DIST - 1.0 then camera.setViewDistance(MAX_DIST) end

  printStatus()
end

return { engineHandlers = { onInit = onInit, onFrame = onFrame } }
EOF_LUA

grep -Fq 'TSP_INTERIOR_VISGRID_LUA_V2' "$PKG/visgrid.lua"
grep -Fq 'rays_per_frame=%d sensor_avg_ms=' "$PKG/visgrid.lua"

echo "===== 4/6 INSTALL V2 LUA ONLY ====="
scp -q "$PKG/visgrid.lua" "$DEV:/tmp/visgrid-v2.lua"
ssh "$DEV" "
set -e
grep -Fq 'TSP_INTERIOR_VISGRID_LUA_V2' /tmp/visgrid-v2.lua
cp /tmp/visgrid-v2.lua '$LUA.new'
mv -f '$LUA.new' '$LUA'
rm -f /tmp/visgrid-v2.lua
sync
"
LOCAL_SHA="$(sha256sum "$PKG/visgrid.lua" | awk '{print $1}')"
REMOTE_SHA="$(ssh "$DEV" "sha256sum '$LUA' | awk '{print \$1}'")"
[ "$LOCAL_SHA" = "$REMOTE_SHA" ]
ssh "$DEV" "grep -a -q 'TSP_INTERIOR_VISGRID_051_V1' '$BIN'"
echo "PASS: V1 engine unchanged; V2 Lua installed."

echo "===== 5/6 CREATE TRACE + ROLLBACK HELPERS ====="
cat > "$PKG/collect-visgrid-v2-trace.sh" <<'EOF_TRACE'
#!/usr/bin/env bash
set -Eeuo pipefail
DEV="${TSP_DEV:-root@192.168.1.25}"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="${1:-$HOME/Downloads/openmw51-visgrid-v2-trace-$STAMP.txt}"
{
  echo "=================================================================="
  echo "OPENMW INTERIOR VISGRID V2 REALTIME TRACE"
  echo "=================================================================="
  ssh "$DEV" 'hostname; date'
  echo; echo "===== VISGRID V2 ====="
  ssh "$DEV" 'grep -hE "TSP_VISGRID_V2|TSP_INTERIOR_VISGRID_051_V1|TSP_DEPTH_PROJECTION" /mnt/SDCARD/data/ports/openmw51/config-0.51/openmw.log /mnt/SDCARD/tsp_prog.txt 2>/dev/null | tail -1800 || true'
  echo; echo "===== RENDER / PERFORMANCE ====="
  ssh "$DEV" 'for f in /mnt/SDCARD/tsp_diag.txt /mnt/SDCARD/tsp_ring.txt /mnt/SDCARD/tsp_state.txt /mnt/SDCARD/data/ports/openmw51/openmw51_perf_latest.txt; do if [ -f "$f" ]; then echo "--- $f ---"; tail -600 "$f"; fi; done'
  echo; echo "===== INSTALLED STATE ====="
  ssh "$DEV" 'sha256sum /mnt/SDCARD/data/ports/openmw51/bin/openmw-0.51 /mnt/SDCARD/data/ports/openmw51/mods/TSPInteriorVisGrid/scripts/TSPInteriorVisGrid/visgrid.lua 2>/dev/null || true'
} 2>&1 | tee "$OUT"
echo; echo "Trace saved: $OUT"
EOF_TRACE
chmod +x "$PKG/collect-visgrid-v2-trace.sh"

cat > "$PKG/rollback-visgrid-v2-to-v1.sh" <<EOF_ROLLBACK
#!/usr/bin/env bash
set -Eeuo pipefail
DEV="\${TSP_DEV:-root@192.168.1.25}"
if ssh "\$DEV" 'pidof openmw-0.51 >/dev/null 2>&1 || pidof openmw >/dev/null 2>&1'; then
  echo "ERROR: exit OpenMW before rollback."
  exit 1
fi
ssh "\$DEV" "set -e; test -s '$BACKUP/visgrid.lua.before-v2'; cp -p '$BACKUP/visgrid.lua.before-v2' '$LUA'; sync; sha256sum '$LUA'"
echo "Restored exact pre-V2 VISGRID Lua."
EOF_ROLLBACK
chmod +x "$PKG/rollback-visgrid-v2-to-v1.sh"

cat > "$PKG/README-V2.txt" <<EOF_README
VISGRID V2 REALTIME
===================
Engine: unchanged TSP_INTERIOR_VISGRID_051_V1 C++ culler.
Sensor: 8x5, all 40 rays every frame, current camera pose only.
Safety: two-frame close confirmation, immediate openings, 3x3 max dilation,
        existing C++ one-tile dilation + 350-unit padding, actors excluded.
Backup: $BACKUP

Key next-trace fields:
  reject
  sensor_avg_ms
  sensor_max_ms
  ray_failures
EOF_README

echo "===== 6/6 DONE ====="
echo "Package: $PKG"
echo "Test while WALKING/TURNING; do not wait stationary for the grid."
echo "While OpenMW is still running, collect:"
echo "  $PKG/collect-visgrid-v2-trace.sh"
echo "Rollback (OpenMW closed):"
echo "  $PKG/rollback-visgrid-v2-to-v1.sh"
