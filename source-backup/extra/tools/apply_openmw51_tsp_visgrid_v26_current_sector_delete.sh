#!/usr/bin/env bash
set -Eeuo pipefail

ACTION="${1:-install}"
CTR="${OPENMW_CONTAINER:-openmw_builder}"
DEV="${TSP_DEVICE:-root@192.168.1.25}"

SRC=/root/openmw-0.51-tsp-src
BUILD=/root/openmw-0.51-tsp-build
PACKAGE=/root/openmw-0.51-tsp-package
SCENE_CPP="$SRC/apps/openmw/mwworld/scene.cpp"
VIS_CPP="$SRC/apps/openmw/mwrender/interiorvisibility.cpp"
ANIM="$SRC/apps/openmw/mwrender/animation.cpp"
BUILT="$BUILD/openmw"
PACKAGED="$PACKAGE/bin/openmw-0.51"

ROOT=/mnt/SDCARD/data/ports/openmw51
REMOTE_BIN="$ROOT/bin/openmw-0.51"
LUA_DIR="$ROOT/mods/TSPInteriorVisGrid/scripts/TSPInteriorVisGrid"
LIVE_LUA="$LUA_DIR/visgrid.lua"
V26_DIR="$LUA_DIR/v26_profiles"
V26_PROFILE="$V26_DIR/visgrid-v26-current-sector-only.lua"
CAPTURE_HELPER="$ROOT/tsp_visgrid_v24_capture.sh"
REMOTE_TMP_BIN=/tmp/openmw-0.51.v26-current-sector

DL="$HOME/Downloads"
HOST_BIN="$DL/openmw-0.51-v26-current-sector-delete"
STATE="$DL/openmw51-visgrid-v26-current-sector-delete.state"
STAMP="$(date +%Y%m%d-%H%M%S)"
LOG="$DL/openmw51-visgrid-v26-current-sector-delete-$STAMP.log"
TMP="$(mktemp -d "$DL/.v26-current-sector.XXXXXX")"
SOURCE_BACKUP=""
DEVICE_BACKUP=""
DEVICE_DEPLOY_STARTED=0
LAUNCHER=""

cleanup(){ rm -rf "$TMP" 2>/dev/null || true; }
trap cleanup EXIT

die(){ echo "ERROR: $*" >&2; exit 1; }

ensure_docker(){
  command -v docker >/dev/null 2>&1 || die "docker not found"
  docker inspect "$CTR" >/dev/null 2>&1 || die "Docker container '$CTR' not found"
  [ "$(docker inspect -f '{{.State.Running}}' "$CTR")" = true ] || docker start "$CTR" >/dev/null
}

ensure_ssh(){
  command -v ssh >/dev/null 2>&1 || die "ssh not found"
  command -v scp >/dev/null 2>&1 || die "scp not found"
  ssh -o BatchMode=yes -o ConnectTimeout=8 "$DEV" true || die "cannot reach $DEV"
}

game_closed(){
  ! ssh "$DEV" "pgrep -af 'openmw-0\\.51|/openmw([[:space:]]|$)' 2>/dev/null" | grep -v pgrep
}

locate_launcher(){
  ssh "$DEV" 'bash -s' <<'REMOTE'
for p in \
  /mnt/SDCARD/Roms/PORTS/Morrowind_51.sh \
  /mnt/SDCARD/Emus/PORTS/../../Roms/PORTS/Morrowind_51.sh \
  /mnt/SDCARD/roms/ports/Morrowind_51.sh
 do
   [ -f "$p" ] || continue
   readlink -f "$p" 2>/dev/null || printf '%s\n' "$p"
   exit 0
 done
exit 1
REMOTE
}

restore_device(){
  [ -n "${DEVICE_BACKUP:-}" ] || return 0
  ssh "$DEV" "bash -s" <<REMOTE
set -e
B='$DEVICE_BACKUP'
test -s "\$B/openmw-0.51.before"
test -s "\$B/visgrid.lua.before"
test -s "\$B/launcher.before"
cp -pf "\$B/openmw-0.51.before" '$REMOTE_BIN'
cp -pf "\$B/visgrid.lua.before" '$LIVE_LUA'
cp -pf "\$B/launcher.before" '$LAUNCHER'
if [ -f "\$B/profile.existed" ]; then
  mkdir -p '$V26_DIR'
  cp -pf "\$B/v26-profile.before" '$V26_PROFILE'
else
  rm -f '$V26_PROFILE'
fi
if [ -f "\$B/helper.existed" ]; then
  cp -pf "\$B/capture-helper.before" '$CAPTURE_HELPER'
else
  rm -f '$CAPTURE_HELPER'
fi
chmod 755 '$REMOTE_BIN' '$LAUNCHER'
[ ! -f '$CAPTURE_HELPER' ] || chmod 755 '$CAPTURE_HELPER'
sync
REMOTE
}

collect_latest(){
  ensure_ssh
  OUT="$DL/openmw51-visgrid-v26-current-sector-validation-$STAMP.txt"
  ssh "$DEV" "test -s '$ROOT/visgrid-v26-latest.txt'" || die "no V26 automatic capture yet; run once and exit normally"
  scp -q "$DEV:$ROOT/visgrid-v26-latest.txt" "$OUT"
  echo "Saved: $OUT"
  echo
  grep -E '^V26 SUMMARY|^V26 SECTOR LAST|^V26 OBJECT LAST|^Bad STAT|^Render failures' "$OUT" || true
}

rollback_all(){
  [ -s "$STATE" ] || die "state file missing: $STATE"
  # shellcheck disable=SC1090
  . "$STATE"
  ensure_docker; ensure_ssh
  game_closed || die "OpenMW is running"
  docker exec "$CTR" bash -lc "set -e; cp -pf '$SOURCE_BACKUP/scene.cpp' '$SCENE_CPP'; cp -pf '$SOURCE_BACKUP/interiorvisibility.cpp' '$VIS_CPP'"
  restore_device
  echo "ROLLBACK COMPLETE"
}

case "$ACTION" in
  collect) collect_latest; exit 0 ;;
  rollback) rollback_all; exit 0 ;;
  install) ;;
  *) die "Usage: $0 [install|collect|rollback]" ;;
esac

exec > >(tee "$LOG") 2>&1

on_error(){
  rc=$?
  trap - ERR
  set +e
  echo
  echo "===== V26 STOPPED SAFELY (rc=$rc) ====="
  if [ -n "$SOURCE_BACKUP" ]; then
    docker exec "$CTR" bash -lc "cp -pf '$SOURCE_BACKUP/scene.cpp' '$SCENE_CPP'; cp -pf '$SOURCE_BACKUP/interiorvisibility.cpp' '$VIS_CPP'" >/dev/null 2>&1 || true
  fi
  if [ "$DEVICE_DEPLOY_STARTED" = 1 ] && [ -n "$DEVICE_BACKUP" ]; then restore_device >/dev/null 2>&1 || true; fi
  echo "Log preserved: $LOG"
  exit "$rc"
}
trap on_error ERR

echo "============================================================"
echo "OPENMW 0.51 — VISGRID V26 CURRENT-SECTOR HARD DELETE TEST"
echo "============================================================"
echo "Exactly ONE active navmesh sector: the player's current sector."
echo "No prewarm, recent tail, portal latch, ray sector, neighbor envelope."
echo "Small-object ownership: XY padding=0, Z slack=100."
echo "Unmapped eligible clutter fails CLOSED for this diagnostic."
echo "Heavy TSP_OBJECT_DIAG logging disabled."
echo "============================================================"

ensure_docker
ensure_ssh
LAUNCHER="$(locate_launcher)"
[ -n "$LAUNCHER" ] || die "could not locate Morrowind_51.sh"

echo
echo "===== 1/9 PRE-FLIGHT ====="
game_closed || die "OpenMW is running. Exit normally and rerun."

docker exec "$CTR" bash -lc "set -e; test -s '$SCENE_CPP'; test -s '$VIS_CPP'; test -s '$BUILT'; grep -Fq 'TSP_ROOM_OBJECT_LIFECYCLE_051_V25' '$SCENE_CPP'; grep -Fq '[TSP_ROOMOBJ_V25]' '$SCENE_CPP'; grep -Fq 'TSP_VISGRID_ROOM_RESIDENCY_051_V24' '$VIS_CPP'; ! grep -Fq 'TSP_ROOM_OBJECT_CURRENT_SECTOR_051_V26' '$SCENE_CPP'; ! grep -Fq 'mPtr.get<ESM::Static>()' '$ANIM'"
ssh "$DEV" "set -e; test -s '$REMOTE_BIN'; test -s '$LIVE_LUA'; test -s '$LAUNCHER'; grep -Fq 'TSP_VISGRID_LUA_V24_ROOM_RESIDENCY' '$LIVE_LUA'"
PRE_SHA="$(ssh "$DEV" "sha256sum '$REMOTE_BIN' | awk '{print \$1}'")"
PRE_LUA_SHA="$(ssh "$DEV" "sha256sum '$LIVE_LUA' | awk '{print \$1}'")"
echo "Current binary SHA: $PRE_SHA"
echo "Current Lua SHA:    $PRE_LUA_SHA"

echo
echo "===== 2/9 BACKUP SOURCE + PULL LIVE LUA/LAUNCHER ====="
SOURCE_BACKUP="$SRC/.tsp-051-source-backups/visgrid-v26-current-sector-$STAMP"
docker exec "$CTR" bash -lc "set -e; mkdir -p '$SOURCE_BACKUP'; cp -pf '$SCENE_CPP' '$SOURCE_BACKUP/scene.cpp'; cp -pf '$VIS_CPP' '$SOURCE_BACKUP/interiorvisibility.cpp'; sha256sum '$SOURCE_BACKUP/'*"
scp -q "$DEV:$LIVE_LUA" "$TMP/visgrid.v25.lua"
scp -q "$DEV:$LAUNCHER" "$TMP/Morrowind_51.v25.sh"

echo
echo "===== 3/9 PATCH C++ CURRENT-SECTOR LIFECYCLE ====="
cat > "$TMP/v26_cpp_patch.py" <<'PY_CPP'
#!/usr/bin/env python3
import sys

scene_path, vis_path = sys.argv[1:3]

def read(path):
    with open(path, 'r', encoding='utf-8', newline='') as f:
        return f.read()

def write(path, text):
    with open(path, 'w', encoding='utf-8', newline='\n') as f:
        f.write(text)

sc = read(scene_path)
vc = read(vis_path)
MARK = 'TSP_ROOM_OBJECT_CURRENT_SECTOR_051_V26'

for token in ('TSP_ROOM_OBJECT_LIFECYCLE_051_V25', '[TSP_ROOMOBJ_V25]', 'isInteriorTopologyObjectResident'):
    if token not in sc and token not in vc:
        raise RuntimeError('V25 baseline token missing: ' + token)
if MARK in sc or MARK in vc:
    raise RuntimeError('V26 marker already present; refusing ambiguous re-application')

# Current-sector test: no object radius at all.
old = '''            const bool shouldLive = MWRender::isInteriorTopologyObjectResident(
                origin, 48.f, false);'''
new = '''            // TSP_ROOM_OBJECT_CURRENT_SECTOR_051_V26
            // Hard diagnostic: current navmesh sector only. No object-radius keepalive.
            const bool shouldLive = MWRender::isInteriorTopologyObjectResident(
                origin, 0.f, false);'''
if sc.count(old) != 1:
    raise RuntimeError('V25 lifecycle residency call count=%d, expected 1' % sc.count(old))
sc = sc.replace(old, new, 1)

# Make each state transition complete in one lifecycle pass. No gradual prewarm.
old = '''        // Prewarm always wins before old-room suppression work.
        constexpr std::size_t wakeBudget = 32;
        constexpr std::size_t suppressBudget = 64;'''
new = '''        // V26 CURRENT-SECTOR-ONLY: there is deliberately no prewarm queue.
        // Complete each room-state transition in one lifecycle pass so a 10-second
        // stationary test cannot hide behind an amortization budget.
        constexpr std::size_t wakeBudget = 4096;
        constexpr std::size_t suppressBudget = 4096;'''
if sc.count(old) != 1:
    raise RuntimeError('V25 wake/suppress budget block count=%d, expected 1' % sc.count(old))
sc = sc.replace(old, new, 1)

# Rename the compact telemetry line.
if sc.count('[TSP_ROOMOBJ_V25]') != 1:
    raise RuntimeError('V25 telemetry tag count=%d, expected 1' % sc.count('[TSP_ROOMOBJ_V25]'))
sc = sc.replace('[TSP_ROOMOBJ_V25]', '[TSP_ROOMOBJ_V26]', 1)

# Lifecycle membership must NOT fail open for clutter that misses all sector boxes.
# This is intentionally aggressive: it tests whether the navmesh can own clutter.
old = '''        // Anything outside all generated topology boxes fails open.
        return !touchedMappedSector;'''
new = '''        // TSP_ROOM_OBJECT_CURRENT_SECTOR_051_V26
        // Hard diagnostic: an eligible clutter object not owned by ANY topology
        // sector is NOT resident. This avoids the V25 fail-open that kept shelf/
        // tabletop objects alive merely because their origin missed a navmesh box.
        // We retain the variable for telemetry/debuggability even though both
        // non-visible cases return false in this test.
        (void)touchedMappedSector;
        return false;'''
if vc.count(old) != 1:
    raise RuntimeError('V25 fail-open return count=%d, expected 1' % vc.count(old))
vc = vc.replace(old, new, 1)

# The normal callback keeps its old structural/gameplay padding policy. The lifecycle
# query gets its own exact XY + 100-unit vertical ownership test below.
old = '''            if (!pvsOriginOverlapsSector(origin, radius, sector, structural))
                continue;
            touchedMappedSector = true;
            if ((visibleMask & (std::uint64_t{ 1 } << sector)) != 0)
                return true;'''
new = '''            bool overlaps = false;
            if (structural)
            {
                overlaps = pvsOriginOverlapsSector(origin, radius, sector, true);
            }
            else
            {
                // TSP_ROOM_OBJECT_CURRENT_SECTOR_051_V26
                // Small-object room ownership: exact XY footprint, only +/-100 Z.
                // No horizontal minimum distance can bleed through a wall.
                const int base = sector * 6;
                const float minX = sPvsBoxes[static_cast<std::size_t>(base + 0)].load(std::memory_order_relaxed);
                const float minY = sPvsBoxes[static_cast<std::size_t>(base + 1)].load(std::memory_order_relaxed);
                const float minZ = sPvsBoxes[static_cast<std::size_t>(base + 2)].load(std::memory_order_relaxed);
                const float maxX = sPvsBoxes[static_cast<std::size_t>(base + 3)].load(std::memory_order_relaxed);
                const float maxY = sPvsBoxes[static_cast<std::size_t>(base + 4)].load(std::memory_order_relaxed);
                const float maxZ = sPvsBoxes[static_cast<std::size_t>(base + 5)].load(std::memory_order_relaxed);
                constexpr float zSlack = 100.f;
                overlaps = std::isfinite(minX) && std::isfinite(minY) && std::isfinite(minZ)
                    && std::isfinite(maxX) && std::isfinite(maxY) && std::isfinite(maxZ)
                    && origin.x() >= minX && origin.x() <= maxX
                    && origin.y() >= minY && origin.y() <= maxY
                    && origin.z() >= minZ - zSlack && origin.z() <= maxZ + zSlack;
            }
            if (!overlaps)
                continue;
            touchedMappedSector = true;
            if ((visibleMask & (std::uint64_t{ 1 } << sector)) != 0)
                return true;'''
if vc.count(old) != 1:
    raise RuntimeError('V25 lifecycle overlap loop count=%d, expected 1' % vc.count(old))
vc = vc.replace(old, new, 1)

for token in (MARK, 'origin, 0.f, false', 'wakeBudget = 4096', 'suppressBudget = 4096', '[TSP_ROOMOBJ_V26]'):
    if token not in sc:
        raise RuntimeError('scene.cpp V26 postcondition missing: ' + token)
for token in (MARK, 'constexpr float zSlack = 100.f;', 'return false;'):
    if token not in vc:
        raise RuntimeError('interiorvisibility.cpp V26 postcondition missing: ' + token)

write(scene_path, sc)
write(vis_path, vc)
print('PASS: V26 hard current-sector lifecycle patch applied.')
print('PASS: small-object ownership has 0 XY padding and +/-100 Z only.')
print('PASS: unmapped eligible clutter fails CLOSED for this diagnostic.')
print('PASS: wake/suppress completes in one 20 Hz lifecycle pass.')
PY_CPP
python3 -m py_compile "$TMP/v26_cpp_patch.py"
docker cp "$TMP/v26_cpp_patch.py" "$CTR:/tmp/v26_cpp_patch.py"
docker exec "$CTR" python3 /tmp/v26_cpp_patch.py "$SCENE_CPP" "$VIS_CPP"
docker exec "$CTR" rm -f /tmp/v26_cpp_patch.py

docker exec "$CTR" bash -lc "set -e; grep -Fq 'TSP_ROOM_OBJECT_CURRENT_SECTOR_051_V26' '$SCENE_CPP'; grep -Fq '[TSP_ROOMOBJ_V26]' '$SCENE_CPP'; grep -Fq 'constexpr float zSlack = 100.f;' '$VIS_CPP'; grep -Fq 'origin, 0.f, false' '$SCENE_CPP'; ! grep -Fq 'mPtr.get<ESM::Static>()' '$ANIM'"

echo
echo "===== 4/9 GENERATE CURRENT-SECTOR-ONLY LUA / LAUNCHER ====="
cat > "$TMP/v26_lua_patch.py" <<'PY_LUA'
#!/usr/bin/env python3
import sys
src_path, dst_path = sys.argv[1:3]
with open(src_path, 'r', encoding='utf-8', newline='') as f:
    s = f.read()
MARK = 'TSP_VISGRID_LUA_V26_CURRENT_SECTOR_ONLY'
for token in ('TSP_VISGRID_LUA_V24_ROOM_RESIDENCY', 'mapState.updateTopologyPvs = function(force)', 'local function onInit()'):
    if token not in s:
        raise RuntimeError('V24 baseline token missing: ' + token)
if MARK in s:
    raise RuntimeError('V26 marker already present')

# Shorten the old six-second safety hold: this test is only ~10 seconds long.
if s.count('local POST_LOAD_ARM_DELAY = 6.0') != 1:
    raise RuntimeError('POST_LOAD_ARM_DELAY baseline count=%d' % s.count('local POST_LOAD_ARM_DELAY = 6.0'))
s = s.replace('local POST_LOAD_ARM_DELAY = 6.0', 'local POST_LOAD_ARM_DELAY = 0.25  -- TSP_VISGRID_LUA_V26_CURRENT_SECTOR_ONLY', 1)

# Install final overrides after all V23/V24 wrappers have been defined.
anchor = 'local function onInit()\n'
override = r'''-- TSP_VISGRID_LUA_V26_CURRENT_SECTOR_ONLY
-- Hard diagnostic policy. The render-residency active set is EXACTLY the sector
-- containing the player. No prewarm, no recent/resident tail, no portal latch,
-- no ray-PVS, no staircase envelope, no whole floor, no quarantine.
mapState.v26CurrentOnlyLast = ''
mapState.updateTopologyPvs = function(force)
    if not mapState.pvsBridge or mapState.topoCell == nil
        or mapState.pvsBoxes == nil then
        if mapState.pvsBridge then pcall(camera.clearInteriorTopologyPvs) end
        mapState.pvsSignature = nil
        mapState.pvsActiveCount = 0
        return
    end

    local current = mapState.topoSectorId or 0
    local sec = current > 0 and mapState.topoCell.sectors[current] or nil
    if current <= 0 or sec == nil then
        pcall(camera.clearInteriorTopologyPvs)
        mapState.pvsSignature = nil
        mapState.pvsActiveCount = 0
        local sig = 'unmapped'
        if sig ~= mapState.v26CurrentOnlyLast then
            mapState.v26CurrentOnlyLast = sig
            print(string.format('[TSP_VISGRID_V26] current-only UNMAPPED current=%d total=%d',
                current, mapState.pvsSectorCount or 0))
        end
        return
    end

    local signature = 'v26:' .. tostring(current)
    if force or signature ~= mapState.pvsSignature then
        -- Zero PVS padding. V26 C++ lifecycle ownership separately allows only
        -- +/-100 vertical units for shelf/tabletop clutter and exactly 0 XY bleed.
        local ok, err = pcall(camera.setInteriorTopologyPvs,
            mapState.pvsBoxes, { current }, 0.0, 0.0)
        if ok then
            mapState.pvsSignature = signature
            mapState.pvsActiveCount = 1
            local b = sec.bbox or {0,0,0,0,0,0}
            local sig = tostring(current)
            if force or sig ~= mapState.v26CurrentOnlyLast then
                mapState.v26CurrentOnlyLast = sig
                print(string.format(
                    '[TSP_VISGRID_V26] current-only sector=%d/%d floor=%d kind=%s bbox=(%.0f,%.0f,%.0f)-(%.0f,%.0f,%.0f)',
                    current, mapState.pvsSectorCount or 0,
                    tonumber(sec.floor or 0) or 0, tostring(sec.kind or '?'),
                    tonumber(b[1] or 0), tonumber(b[2] or 0), tonumber(b[3] or 0),
                    tonumber(b[4] or 0), tonumber(b[5] or 0), tonumber(b[6] or 0)))
            end
        else
            print('[TSP_VISGRID_V26] bridge error: ' .. tostring(err))
            pcall(camera.clearInteriorTopologyPvs)
            mapState.pvsSignature = nil
            mapState.pvsActiveCount = 0
        end
    end
end

-- No ray learning/prewarm in this diagnostic. Current player sector is the only
-- authority. This also removes ray overhead from the 10-second FPS check.
mapState.v23RayMode = 1
mapState.v23Emergency = function() return false end
mapState.v23ChooseEmergencyQuartet = function(_ex,_ey,_ez,_turning) return 0 end

'''
if s.count(anchor) != 1:
    raise RuntimeError('onInit anchor count=%d' % s.count(anchor))
s = s.replace(anchor, override + anchor, 1)

# Replace the V24 startup line with a V26 one while preserving historical markers.
startup = "print('[TSP_VISGRID_V24] ROOM-RESIDENCY raw-topology=1 rays=5/6 whole-floor=0 gameplay-pvs=1')"
if s.count(startup) != 1:
    raise RuntimeError('V24 startup print count=%d' % s.count(startup))
s = s.replace(startup, startup + "\nprint('[TSP_VISGRID_V26] CURRENT-SECTOR-ONLY no-prewarm=1 rays=0 xy=0 z=100 failclosed=1')", 1)

for token in (MARK, "mapState.pvsBoxes, { current }, 0.0, 0.0", 'mapState.v23Emergency = function() return false end', '[TSP_VISGRID_V26] CURRENT-SECTOR-ONLY'):
    if token not in s:
        raise RuntimeError('V26 Lua postcondition missing: ' + token)
with open(dst_path, 'w', encoding='utf-8', newline='\n') as f:
    f.write(s)
print('PASS: V26 current-sector-only Lua generated.')
print('PASS: no prewarm/resident/ray/portal sector can enter the active set.')
print('PASS: routine rays disabled for the short FPS proof.')
PY_LUA
cat > "$TMP/v26_launcher_patch.py" <<'PY_LAUNCH'
#!/usr/bin/env python3
import sys
src_path, dst_path = sys.argv[1:3]
with open(src_path, 'r', encoding='utf-8', newline='') as f:
    s = f.read()
old = '$TSP_VISGRID_DIR/v24_profiles/visgrid-v24-room-residency.lua'
new = '$TSP_VISGRID_DIR/v26_profiles/visgrid-v26-current-sector-only.lua'
if s.count(old) != 1:
    raise RuntimeError('V24 selected-profile path count=%d, expected 1' % s.count(old))
s = s.replace(old, new, 1)
diag_count = s.count('export TSP_OBJECT_DIAG=1')
if diag_count < 1:
    raise RuntimeError('TSP_OBJECT_DIAG=1 count=0, expected at least 1')
s = s.replace(
    'export TSP_OBJECT_DIAG=1',
    'export TSP_OBJECT_DIAG=0  # V26 compact diagnostics only'
)
if 'export TSP_OBJECT_DIAG=1' in s:
    raise RuntimeError(
        'an enabled TSP_OBJECT_DIAG export survived the V26 launcher patch'
    )
print(
    'V26 launcher: disabled %d TSP_OBJECT_DIAG=1 export(s).' % diag_count
)
s = s.replace('Visgrid Profile=v24-room-residency', 'Visgrid Profile=v26-current-sector-only', 1)
s = s.replace('Visgrid room policy=raw sectors; whole-floor off; rays 5/6', 'Visgrid room policy=CURRENT SECTOR ONLY; no prewarm; rays 0; XY bleed 0; Z slack 100', 1)
for token in ('v26_profiles/visgrid-v26-current-sector-only.lua', 'export TSP_OBJECT_DIAG=0', 'Visgrid Profile=v26-current-sector-only'):
    if token not in s:
        raise RuntimeError('launcher V26 postcondition missing: ' + token)
with open(dst_path, 'w', encoding='utf-8', newline='\n') as f:
    f.write(s)
print('PASS: launcher selects V26 and heavy object diagnostics are disabled.')
PY_LAUNCH
python3 -m py_compile "$TMP/v26_lua_patch.py" "$TMP/v26_launcher_patch.py"
python3 "$TMP/v26_lua_patch.py" "$TMP/visgrid.v25.lua" "$TMP/visgrid.v26.lua"
python3 "$TMP/v26_launcher_patch.py" "$TMP/Morrowind_51.v25.sh" "$TMP/Morrowind_51.v26.sh"
chmod +x "$TMP/Morrowind_51.v26.sh"
bash -n "$TMP/Morrowind_51.v26.sh"

PARSER=""
for x in texlua lua luajit; do command -v "$x" >/dev/null 2>&1 && { PARSER="$x"; break; }; done
if [ -n "$PARSER" ]; then
  cat > "$TMP/parse.lua" <<'LUA'
local f,e=loadfile(arg[1]); if not f then error(e) end; print('LUA_PARSE_PASS '..arg[1])
LUA
  "$PARSER" "$TMP/parse.lua" "$TMP/visgrid.v26.lua"
fi
V26_LUA_SHA="$(sha256sum "$TMP/visgrid.v26.lua" | awk '{print $1}')"
echo "V26 Lua SHA: $V26_LUA_SHA"

echo
echo "===== 5/9 BUILD ====="
BUILD_LOG=/root/openmw51-visgrid-v26-current-sector-$STAMP.log
set +e
docker exec "$CTR" bash -lc "set -o pipefail; cd '$BUILD'; cmake --build . --target openmw --parallel '${OPENMW_JOBS:-2}' 2>&1 | tee '$BUILD_LOG'"
RC=$?
set -e
if [ "$RC" -ne 0 ]; then
  echo "BUILD FAILED — last 200 lines:"
  docker exec "$CTR" bash -lc "tail -n 200 '$BUILD_LOG' || true"
  false
fi

echo
echo "===== 6/9 PACKAGE / VERIFY ====="
docker exec "$CTR" bash -lc "set -e; test -s '$BUILT'; mkdir -p '$(dirname "$PACKAGED")'; install -m 755 '$BUILT' '$PACKAGED'; file '$PACKAGED'; file '$PACKAGED' | grep -Eq 'ARM aarch64|ARM64|AArch64'; sha256sum '$PACKAGED'; strings '$PACKAGED' | grep -E 'TSP_ROOMOBJ_V26|TSP_OBJECT_DIAG_051_V1' | sort -u | head -40 || true"
NEW_SHA="$(docker exec "$CTR" sha256sum "$PACKAGED" | awk '{print $1}')"
[ "$NEW_SHA" != "$PRE_SHA" ] || die "rebuilt hash did not change"
docker cp "$CTR:$PACKAGED" "$HOST_BIN"
chmod +x "$HOST_BIN"
[ "$(sha256sum "$HOST_BIN" | awk '{print $1}')" = "$NEW_SHA" ] || die "Docker->Ubuntu SHA mismatch"
file "$HOST_BIN"; sha256sum "$HOST_BIN"

echo
echo "===== 7/9 CREATE SHORT AUTOMATIC V26 CAPTURE ====="
cat > "$TMP/tsp_visgrid_v26_capture.sh" <<'CAPTURE'
#!/bin/bash
set +e
ROOT=/mnt/SDCARD/data/ports/openmw51
OUTDIR="$ROOT/visgrid-v26-captures"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="$OUTDIR/visgrid-v26-$STAMP.txt"
LATEST="$ROOT/visgrid-v26-latest.txt"
mkdir -p "$OUTDIR"
RAW=/tmp/visgrid-v26-raw.$$
: > "$RAW"
for f in "$ROOT/openmw_051_log.txt" "$ROOT/config-0.51/openmw.log" "$ROOT/openmw.log"; do
  [ -f "$f" ] || continue
  tail -n 14000 "$f" | awk '
    /\[TSP_VISGRID_V26\] CURRENT-SECTOR-ONLY/ { buf=""; found=1 }
    found { buf=buf $0 ORS }
    END { if (found) printf "%s", buf }
  ' >> "$RAW"
done
{
  echo "============================================================"
  echo "OPENMW 0.51 V26 CURRENT-SECTOR SHORT CAPTURE"
  echo "============================================================"
  date
  echo
  BAD="$(grep -c 'Bad LiveCellRef cast to STAT' "$RAW" || true)"
  FAIL="$(grep -c 'failed to render' "$RAW" || true)"
  SECTOR="$(grep '\[TSP_VISGRID_V26\] current-only' "$RAW" | tail -1)"
  OBJ="$(grep '\[TSP_ROOMOBJ_V26\]' "$RAW" | tail -1)"
  echo "V26 SUMMARY"
  echo "Bad STAT casts: $BAD"
  echo "Render failures: $FAIL"
  echo "V26 SECTOR LAST: $SECTOR"
  echo "V26 OBJECT LAST: $OBJ"
  echo
  echo "===== ROOM COUNTS (last 20) ====="
  grep '\[TSP_ROOMOBJ_V26\]' "$RAW" | tail -20 || true
  echo
  echo "===== CURRENT-SECTOR EVENTS ====="
  grep -E '\[TSP_VISGRID_V26\] current-only|sector switch|topology sector=' "$RAW" | tail -50 || true
  echo
  echo "===== ERRORS ====="
  grep -E 'Bad LiveCellRef cast|failed to render|TSP_VISGRID_V11.*ERROR|TSP_VISGRID_V26.*error' "$RAW" | tail -80 || true
  echo
  echo "===== PERF TAIL ====="
  [ ! -f "$ROOT/openmw51_perf_latest.txt" ] || tail -180 "$ROOT/openmw51_perf_latest.txt"
} > "$OUT"
cp -f "$OUT" "$LATEST"
sync
rm -f "$RAW"
echo "V26 automatic capture: $OUT"
CAPTURE
chmod +x "$TMP/tsp_visgrid_v26_capture.sh"
bash -n "$TMP/tsp_visgrid_v26_capture.sh"

echo
echo "===== 8/9 DEVICE BACKUP / INSTALL ====="
DEVICE_BACKUP="$ROOT/backups/visgrid-v26-current-sector-$STAMP"
ssh "$DEV" "bash -s" <<REMOTE_BACKUP
set -e
B='$DEVICE_BACKUP'
mkdir -p "\$B"
cp -pf '$REMOTE_BIN' "\$B/openmw-0.51.before"
cp -pf '$LIVE_LUA' "\$B/visgrid.lua.before"
cp -pf '$LAUNCHER' "\$B/launcher.before"
if [ -f '$V26_PROFILE' ]; then touch "\$B/profile.existed"; cp -pf '$V26_PROFILE' "\$B/v26-profile.before"; fi
if [ -f '$CAPTURE_HELPER' ]; then touch "\$B/helper.existed"; cp -pf '$CAPTURE_HELPER' "\$B/capture-helper.before"; fi
sha256sum "\$B/openmw-0.51.before" "\$B/visgrid.lua.before" "\$B/launcher.before"
REMOTE_BACKUP
DEVICE_DEPLOY_STARTED=1

scp -q "$HOST_BIN" "$DEV:$REMOTE_TMP_BIN"
scp -q "$TMP/visgrid.v26.lua" "$DEV:/tmp/visgrid-v26.lua"
scp -q "$TMP/Morrowind_51.v26.sh" "$DEV:/tmp/Morrowind_51.v26.sh"
scp -q "$TMP/tsp_visgrid_v26_capture.sh" "$DEV:/tmp/tsp_visgrid_v26_capture.sh"
ssh "$DEV" "bash -s" <<REMOTE_INSTALL
set -e
mkdir -p '$V26_DIR'
test "\$(sha256sum '$REMOTE_TMP_BIN' | awk '{print \$1}')" = '$NEW_SHA'
test "\$(sha256sum /tmp/visgrid-v26.lua | awk '{print \$1}')" = '$V26_LUA_SHA'
install -m 755 '$REMOTE_TMP_BIN' '$REMOTE_BIN'
install -m 644 /tmp/visgrid-v26.lua '$V26_PROFILE'
install -m 644 /tmp/visgrid-v26.lua '$LIVE_LUA'
install -m 755 /tmp/Morrowind_51.v26.sh '$LAUNCHER'
install -m 755 /tmp/tsp_visgrid_v26_capture.sh '$CAPTURE_HELPER'
rm -f '$REMOTE_TMP_BIN' /tmp/visgrid-v26.lua /tmp/Morrowind_51.v26.sh /tmp/tsp_visgrid_v26_capture.sh
sync
test "\$(sha256sum '$REMOTE_BIN' | awk '{print \$1}')" = '$NEW_SHA'
test "\$(sha256sum '$LIVE_LUA' | awk '{print \$1}')" = '$V26_LUA_SHA'
bash -n '$LAUNCHER'
grep -Fq 'v26_profiles/visgrid-v26-current-sector-only.lua' '$LAUNCHER'
grep -Fq 'export TSP_OBJECT_DIAG=0' '$LAUNCHER'
grep -Fq 'TSP_VISGRID_LUA_V26_CURRENT_SECTOR_ONLY' '$LIVE_LUA'
echo "Installed binary:"; sha256sum '$REMOTE_BIN'
echo "Installed Lua:"; sha256sum '$LIVE_LUA'
REMOTE_INSTALL

echo
echo "===== 9/9 STATE ====="
cat > "$STATE" <<EOF_STATE
SOURCE_BACKUP='$SOURCE_BACKUP'
DEVICE_BACKUP='$DEVICE_BACKUP'
LAUNCHER='$LAUNCHER'
PRE_DEVICE_SHA='$PRE_SHA'
FIX_DEVICE_SHA='$NEW_SHA'
PRE_LUA_SHA='$PRE_LUA_SHA'
V26_LUA_SHA='$V26_LUA_SHA'
EOF_STATE

trap - ERR

echo
echo "============================================================"
echo "V26 CURRENT-SECTOR HARD TEST INSTALLED"
echo "============================================================"
echo "For eligible non-static/non-actor/non-door interior objects:"
echo "  current sector -> materialized"
echo "  every other sector -> renderer + physics/navmesh removed"
echo "  unmapped -> removed for this diagnostic"
echo "  XY keep distance -> ZERO"
echo "  vertical room slack -> 100 units"
echo "  prewarm -> NONE"
echo "  ray sectors -> NONE"
echo "  wake/suppress -> complete in one 0.05 s lifecycle pass"
echo "  heavy object diagnostics -> OFF"
echo
echo "TEST: load the Caldera spot, face the blank wall, stand still ~10 seconds, exit normally."
echo "Then download the small capture with:"
echo "  cd ~/Downloads"
echo "  ./apply_openmw51_tsp_visgrid_v26_current_sector_delete.sh collect"
echo
echo "Rollback:"
echo "  ./apply_openmw51_tsp_visgrid_v26_current_sector_delete.sh rollback"
echo "============================================================"
