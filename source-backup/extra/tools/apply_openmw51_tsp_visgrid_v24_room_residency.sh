#!/usr/bin/env bash
set -Eeuo pipefail

# OpenMW 0.51 / TrimUI Smart Pro
# VISGRID V24 ROOM RESIDENCY
#
# Main change:
#   - raw navmesh/topology sectors become coarse render-residency authority
#   - gameplay clutter participates in topology PVS (render only)
#   - V22.1G whole-floor keepalive is removed from the active set
#   - broad structural-shell fail-open is removed from the active set
#   - current/resident/recent/portal/ray/trail sectors remain safety authority
#   - continuous live learning restored to 5 rays/frame; 6 on turn/entry/emergency
#   - structural roots keep generous sector overlap padding
#   - gameplay roots get tight 96 XY / 64 Z overlap padding
#
# Actors and doors remain outside room residency for this proof run.
# Every normal game exit automatically creates a V24 capture until rollback.
#
# Usage:
#   ./apply_openmw51_tsp_visgrid_v24_room_residency.sh
#   ./apply_openmw51_tsp_visgrid_v24_room_residency.sh collect
#   ./apply_openmw51_tsp_visgrid_v24_room_residency.sh rollback

ACTION="${1:-install}"
CTR="${OPENMW_CONTAINER:-openmw_builder}"
DEV="${TSP_DEVICE:-root@192.168.1.25}"

SRC="/root/openmw-0.51-tsp-src"
BUILD="/root/openmw-0.51-tsp-build"
PACKAGE="/root/openmw-0.51-tsp-package"
ANIM="$SRC/apps/openmw/mwrender/animation.cpp"
HPP="$SRC/apps/openmw/mwrender/interiorvisibility.hpp"
CPP="$SRC/apps/openmw/mwrender/interiorvisibility.cpp"
BUILT="$BUILD/openmw"
PACKAGED="$PACKAGE/bin/openmw-0.51"

ROOT="/mnt/SDCARD/data/ports/openmw51"
REMOTE_BIN="$ROOT/bin/openmw-0.51"
MOD="$ROOT/mods/TSPInteriorVisGrid"
LUA_DIR="$MOD/scripts/TSPInteriorVisGrid"
LIVE_LUA="$LUA_DIR/visgrid.lua"
V24_DIR="$LUA_DIR/v24_profiles"
V24_PROFILE="$V24_DIR/visgrid-v24-room-residency.lua"
CAPTURE_HELPER="$ROOT/tsp_visgrid_v24_capture.sh"
REMOTE_TMP_BIN="/tmp/openmw-0.51.v24-room-residency"

DL="$HOME/Downloads"
HOST_BIN="$DL/openmw-0.51-v24-room-residency"
STATE="$DL/openmw51-visgrid-v24-room-residency.state"
STAMP="$(date +%Y%m%d-%H%M%S)"
LOG="$DL/openmw51-visgrid-v24-room-residency-$STAMP.log"
TMP="$(mktemp -d "$DL/.v24-room-residency.XXXXXX")"

SOURCE_BACKUP=""
DEVICE_BACKUP=""
DEVICE_DEPLOY_STARTED=0
LAUNCHER=""

cleanup() { rm -rf "$TMP" 2>/dev/null || true; }
trap cleanup EXIT

die() { echo "ERROR: $*" >&2; exit 1; }

ensure_docker() {
    command -v docker >/dev/null 2>&1 || die "docker command not found"
    docker inspect "$CTR" >/dev/null 2>&1 || die "Docker container '$CTR' not found"
    if [ "$(docker inspect -f '{{.State.Running}}' "$CTR")" != "true" ]; then
        docker start "$CTR" >/dev/null
    fi
}

ensure_ssh() {
    command -v ssh >/dev/null 2>&1 || die "ssh command not found"
    command -v scp >/dev/null 2>&1 || die "scp command not found"
    ssh -o BatchMode=yes -o ConnectTimeout=8 "$DEV" true \
        || die "Cannot reach $DEV with non-interactive SSH"
}

locate_launcher() {
    ssh "$DEV" 'bash -s' <<'REMOTE'
ROOT=/mnt/SDCARD/data/ports/openmw51
for p in \
  /mnt/SDCARD/Roms/PORTS/Morrowind_51.sh \
  /mnt/SDCARD/Emus/PORTS/../../Roms/PORTS/Morrowind_51.sh \
  /mnt/SDCARD/roms/ports/Morrowind_51.sh \
  "$ROOT/Morrowind_51.sh"
do
    if [ -f "$p" ]; then
        readlink -f "$p" 2>/dev/null || printf '%s\n' "$p"
        exit 0
    fi
done
exit 1
REMOTE
}

restore_device_backup() {
    [ -n "${DEVICE_BACKUP:-}" ] || return 0
    ssh "$DEV" "bash -s" <<REMOTE_RESTORE
set -e
B='$DEVICE_BACKUP'
test -s "\$B/openmw-0.51.before" && cp -pf "\$B/openmw-0.51.before" '$REMOTE_BIN'
test -s "\$B/visgrid.lua.before" && cp -pf "\$B/visgrid.lua.before" '$LIVE_LUA'
test -s "\$B/launcher.before" && cp -pf "\$B/launcher.before" '$LAUNCHER'
if [ -f "\$B/v24profile.existed" ]; then
    mkdir -p '$V24_DIR'
    test -s "\$B/v24profile.before" && cp -pf "\$B/v24profile.before" '$V24_PROFILE'
else
    rm -f '$V24_PROFILE'
fi
if [ -f "\$B/helper.existed" ]; then
    test -s "\$B/capture-helper.before" && cp -pf "\$B/capture-helper.before" '$CAPTURE_HELPER'
else
    rm -f '$CAPTURE_HELPER'
fi
chmod 755 '$REMOTE_BIN' 2>/dev/null || true
sync
REMOTE_RESTORE
}

on_error() {
    rc=$?
    trap - ERR
    set +e
    echo
    echo "============================================================"
    echo "V24 STOPPED SAFELY"
    echo "============================================================"
    echo "Exit code: $rc"
    if [ -n "${SOURCE_BACKUP:-}" ]; then
        echo "Restoring Docker source from: $SOURCE_BACKUP"
        docker exec "$CTR" bash -lc "
            cp -pf '$SOURCE_BACKUP/animation.cpp' '$ANIM' &&
            cp -pf '$SOURCE_BACKUP/interiorvisibility.hpp' '$HPP' &&
            cp -pf '$SOURCE_BACKUP/interiorvisibility.cpp' '$CPP'
        " >/dev/null 2>&1 || echo "WARNING: Docker source restore failed."
    fi
    if [ "${DEVICE_DEPLOY_STARTED:-0}" = "1" ] && [ -n "${DEVICE_BACKUP:-}" ]; then
        echo "Restoring TSP files from: $DEVICE_BACKUP"
        restore_device_backup || echo "WARNING: device restore failed."
    fi
    echo "Controller log: $LOG"
    exit "$rc"
}
trap on_error ERR

collect_latest() {
    ensure_ssh
    remote="$ROOT/visgrid-v24-latest.txt"
    out="$DL/openmw51-visgrid-v24-room-residency-validation-$STAMP.txt"
    ssh "$DEV" "test -s '$remote'" \
        || die "No V24 automatic capture yet. Run OpenMW once and exit normally."
    scp -q "$DEV:$remote" "$out"
    echo "Downloaded: $out"
    echo
    grep -E '^V24 SUMMARY|^Bad STAT|^Render failures|^PVS culls|^GRID culls|^PVS-eligible' "$out" || true
}

rollback_all() {
    [ -s "$STATE" ] || die "State file missing: $STATE"
    # shellcheck disable=SC1090
    . "$STATE"
    ensure_docker
    ensure_ssh
    [ -n "${SOURCE_BACKUP:-}" ] || die "STATE missing SOURCE_BACKUP"
    [ -n "${DEVICE_BACKUP:-}" ] || die "STATE missing DEVICE_BACKUP"
    [ -n "${LAUNCHER:-}" ] || die "STATE missing LAUNCHER"
    docker exec "$CTR" bash -lc "
        set -e
        cp -pf '$SOURCE_BACKUP/animation.cpp' '$ANIM'
        cp -pf '$SOURCE_BACKUP/interiorvisibility.hpp' '$HPP'
        cp -pf '$SOURCE_BACKUP/interiorvisibility.cpp' '$CPP'
    "
    restore_device_backup
    echo "ROLLBACK COMPLETE. V24 capture history was left intact."
}

case "$ACTION" in
    collect) collect_latest; exit 0 ;;
    rollback) rollback_all; exit 0 ;;
    install) ;;
    *) die "Usage: $0 [install|collect|rollback]" ;;
esac

exec > >(tee "$LOG") 2>&1

echo "============================================================"
echo "OPENMW 0.51 — VISGRID V24 ROOM RESIDENCY"
echo "============================================================"
echo "Container: $CTR"
echo "Device:    $DEV"
echo "Log:       $LOG"
echo "============================================================"

ensure_docker
ensure_ssh
LAUNCHER="$(locate_launcher)"
[ -n "$LAUNCHER" ] || die "Could not locate Morrowind_51.sh"
echo "Launcher: $LAUNCHER"

echo
echo "===== 1/10 PRE-FLIGHT ====="
if ssh "$DEV" "pgrep -af 'openmw-0\.51|/openmw([[:space:]]|$)' 2>/dev/null" | grep -v pgrep; then
    die "OpenMW appears to be running. Exit normally and rerun."
fi
echo "PASS: OpenMW is not running."

docker exec "$CTR" bash -lc "
    set -e
    test -s '$ANIM'; test -s '$HPP'; test -s '$CPP'; test -s '$BUILT'
    grep -Fq 'TSP_VISGRID_OBJECT_CLASS_FIX_051_V1' '$ANIM'
    grep -Fq 'TSP_VISGRID_CLUTTER_CULL_051_V1' '$ANIM'
    grep -Fq 'TSP_OBJECT_DIAG_051_V1' '$ANIM'
    ! grep -Fq 'mPtr.get<ESM::Static>()' '$ANIM'
"
ssh "$DEV" "
    set -e
    test -s '$REMOTE_BIN'; test -s '$LIVE_LUA'; test -s '$LAUNCHER'
    grep -Fq 'TSP_VISGRID_LUA_V23_PERF_MATRIX' '$LIVE_LUA'
    grep -Fq 'TSP_VISGRID_LUA_V22_1G_STRUCTURAL_PVS_SAFETY' '$LIVE_LUA'
"
PRE_DEVICE_SHA="$(ssh "$DEV" "sha256sum '$REMOTE_BIN' | awk '{print \$1}'")"
PRE_LUA_SHA="$(ssh "$DEV" "sha256sum '$LIVE_LUA' | awk '{print \$1}'")"
echo "Current device binary SHA: $PRE_DEVICE_SHA"
echo "Current live sensor SHA:   $PRE_LUA_SHA"

echo
echo "===== 2/10 BACK UP CURRENT SOURCE ====="
SOURCE_BACKUP="$SRC/.tsp-051-source-backups/visgrid-v24-room-residency-$STAMP"
docker exec "$CTR" bash -lc "
    set -e
    mkdir -p '$SOURCE_BACKUP'
    cp -pf '$ANIM' '$SOURCE_BACKUP/animation.cpp'
    cp -pf '$HPP' '$SOURCE_BACKUP/interiorvisibility.hpp'
    cp -pf '$CPP' '$SOURCE_BACKUP/interiorvisibility.cpp'
    sha256sum '$SOURCE_BACKUP/animation.cpp' '$SOURCE_BACKUP/interiorvisibility.hpp' '$SOURCE_BACKUP/interiorvisibility.cpp'
"

echo
echo "===== 3/10 PATCH C++ ROOM-RESIDENCY ELIGIBILITY ====="
docker exec -i "$CTR" python3 - "$ANIM" "$HPP" "$CPP" <<'PY_CPP'
import sys
anim_path, hpp_path, cpp_path = sys.argv[1:4]
def read(path):
    with open(path, "r", encoding="utf-8", newline="") as f: return f.read()
def write(path, text):
    with open(path, "w", encoding="utf-8", newline="\n") as f: f.write(text)
a, h, c = read(anim_path), read(hpp_path), read(cpp_path)
MARK = "TSP_VISGRID_ROOM_RESIDENCY_051_V24"
if MARK not in a:
    for token in (
        "TSP_VISGRID_OBJECT_CLASS_FIX_051_V1", "TSP_VISGRID_CLUTTER_CULL_051_V1",
        "TSP_OBJECT_DIAG_051_V1",
        "const bool tspIsStatic = mPtr.getType() == ESM::Static::sRecordId;",
    ):
        if token not in a: raise RuntimeError("animation.cpp missing baseline token: " + token)
    if "mPtr.get<ESM::Static>()" in a: raise RuntimeError("unsafe Static cast present")
    old = '''            float tspPvsRadius = 0.f;
            if (tspIsStatic)
            {
                const osg::BoundingSphere tspBound = mObjectRoot->getBound();
                if (tspBound.valid() && std::isfinite(tspBound.radius()) && tspBound.radius() > 0.f)
                {
                    const float tspScale = std::max(0.01f, std::abs(mPtr.getCellRef().getScale()));
                    tspPvsRadius = (tspBound.center().length() + tspBound.radius()) * tspScale;
                }
            }
            const bool tspPvsEligible = tspIsStatic && std::isfinite(tspPvsRadius)
                && tspPvsRadius > 0.f && tspPvsRadius <= 900.f;
'''
    new = '''            // TSP_VISGRID_ROOM_RESIDENCY_051_V24
            // Every non-actor/non-door root gets a placement sphere for room residency.
            // Gameplay state, activation and physics remain fully alive.
            float tspPvsRadius = 0.f;
            {
                const osg::BoundingSphere tspBound = mObjectRoot->getBound();
                if (tspBound.valid() && std::isfinite(tspBound.radius()) && tspBound.radius() > 0.f)
                {
                    const float tspScale = std::max(0.01f, std::abs(mPtr.getCellRef().getScale()));
                    tspPvsRadius = (tspBound.center().length() + tspBound.radius()) * tspScale;
                }
            }
            const bool tspPvsEligible = std::isfinite(tspPvsRadius)
                && tspPvsRadius > 0.f && tspPvsRadius <= 900.f;
'''
    if a.count(old) != 1: raise RuntimeError("animation PVS block count=%d" % a.count(old))
    a = a.replace(old, new, 1)
    old = '''            mObjectRoot->addCullCallback(new InteriorVisibilityCullCallback(
                tspPvsOrigin, tspPvsRadius, tspPvsEligible, std::move(tspDiagId), tspDiagType, tspIsStatic));'''
    new = '''            mObjectRoot->addCullCallback(new InteriorVisibilityCullCallback(
                tspPvsOrigin, tspPvsRadius, tspPvsEligible, tspIsStatic,
                std::move(tspDiagId), tspDiagType, tspIsStatic));'''
    if a.count(old) != 1: raise RuntimeError("animation callback ctor count=%d" % a.count(old))
    a = a.replace(old, new, 1)
    old = '''        InteriorVisibilityCullCallback(const osg::Vec3f& worldOrigin, float pvsRadius, bool pvsEligible,
            std::string diagId = {}, int diagType = -1, bool diagStatic = false)
            : mWorldOrigin(worldOrigin)
            , mPvsRadius(pvsRadius)
            , mPvsEligible(pvsEligible)
            , mDiagId(std::move(diagId))
'''
    new = '''        InteriorVisibilityCullCallback(const osg::Vec3f& worldOrigin, float pvsRadius, bool pvsEligible,
            bool pvsStructural, std::string diagId = {}, int diagType = -1, bool diagStatic = false)
            : mWorldOrigin(worldOrigin)
            , mPvsRadius(pvsRadius)
            , mPvsEligible(pvsEligible)
            , mPvsStructural(pvsStructural)
            , mDiagId(std::move(diagId))
'''
    if h.count(old) != 1: raise RuntimeError("hpp constructor count=%d" % h.count(old))
    h = h.replace(old, new, 1)
    old = '''            , mPvsRadius(copy.mPvsRadius)
            , mPvsEligible(copy.mPvsEligible)
            , mDiagId(copy.mDiagId)
'''
    new = '''            , mPvsRadius(copy.mPvsRadius)
            , mPvsEligible(copy.mPvsEligible)
            , mPvsStructural(copy.mPvsStructural)
            , mDiagId(copy.mDiagId)
'''
    if h.count(old) != 1: raise RuntimeError("hpp copy ctor count=%d" % h.count(old))
    h = h.replace(old, new, 1)
    old = '''        float mPvsRadius = 0.f;
        bool mPvsEligible = false;

        // TSP_OBJECT_DIAG_051_V1
'''
    new = '''        float mPvsRadius = 0.f;
        bool mPvsEligible = false;
        // Static structure retains legacy generous PVS padding; gameplay clutter
        // uses tight room ownership padding to avoid cross-wall/floor residency.
        bool mPvsStructural = false;

        // TSP_OBJECT_DIAG_051_V1
'''
    if h.count(old) != 1: raise RuntimeError("hpp field anchor count=%d" % h.count(old))
    h = h.replace(old, new, 1)
    old = '''        bool pvsOriginOverlapsSector(const osg::Vec3f& origin, float radius, int sector)
        {
'''
    new = '''        // TSP_VISGRID_ROOM_RESIDENCY_051_V24
        bool pvsOriginOverlapsSector(const osg::Vec3f& origin, float radius, int sector, bool structural)
        {
'''
    if c.count(old) != 1: raise RuntimeError("cpp overlap function count=%d" % c.count(old))
    c = c.replace(old, new, 1)
    old = '''            const float xy = std::max(0.f, radius)
                + sPvsXyPadding.load(std::memory_order_relaxed);
            const float z = std::max(0.f, radius)
                + sPvsZPadding.load(std::memory_order_relaxed);
'''
    new = '''            const float configuredXy = sPvsXyPadding.load(std::memory_order_relaxed);
            const float configuredZ = sPvsZPadding.load(std::memory_order_relaxed);
            const float pvsXy = structural ? configuredXy : std::min(configuredXy, 96.f);
            const float pvsZ = structural ? configuredZ : std::min(configuredZ, 64.f);
            const float xy = std::max(0.f, radius) + std::max(0.f, pvsXy);
            const float z = std::max(0.f, radius) + std::max(0.f, pvsZ);
'''
    if c.count(old) != 1: raise RuntimeError("cpp padding block count=%d" % c.count(old))
    c = c.replace(old, new, 1)
    old = '''                    if (!pvsOriginOverlapsSector(mWorldOrigin, mPvsRadius, sector))
'''
    new = '''                    if (!pvsOriginOverlapsSector(
                            mWorldOrigin, mPvsRadius, sector, mPvsStructural))
'''
    if c.count(old) != 1: raise RuntimeError("cpp overlap call count=%d" % c.count(old))
    c = c.replace(old, new, 1)
    c = c.replace("// Only conservative, stationary ESM::Static roots are eligible.",
        "// Room residency applies to safe non-actor/non-door roots; structural roots keep wider padding.", 1)
for token in (MARK, "const bool tspPvsEligible = std::isfinite(tspPvsRadius)", "tspPvsEligible, tspIsStatic"):
    if token not in a: raise RuntimeError("animation postcondition missing: " + token)
for token in ("mPvsStructural", "bool pvsStructural"):
    if token not in h: raise RuntimeError("hpp postcondition missing: " + token)
for token in (MARK, "std::min(configuredXy, 96.f)", "std::min(configuredZ, 64.f)", "mPvsStructural"):
    if token not in c: raise RuntimeError("cpp postcondition missing: " + token)
if "mPtr.get<ESM::Static>()" in a: raise RuntimeError("unsafe Static cast survived")
write(anim_path, a); write(hpp_path, h); write(cpp_path, c)
print("PASS: gameplay roots now participate in room PVS.")
print("PASS: static padding remains wide; gameplay padding is 96 XY / 64 Z max.")
print("PASS: unsafe LiveCellRef Static cast remains absent.")
PY_CPP

docker exec "$CTR" bash -lc "
    set -e
    grep -nE -B6 -A28 'TSP_VISGRID_ROOM_RESIDENCY_051_V24|tspPvsEligible|mPvsStructural' '$ANIM' '$HPP' '$CPP' | head -260
    ! grep -Fq 'mPtr.get<ESM::Static>()' '$ANIM'
"

echo
echo "===== 4/10 BUILD OPENMW ====="
BUILD_LOG="/root/openmw51-visgrid-v24-room-residency-$STAMP.log"
set +e
docker exec "$CTR" bash -lc "set -o pipefail; cd '$BUILD'; cmake --build . --target openmw --parallel '${OPENMW_JOBS:-2}' 2>&1 | tee '$BUILD_LOG'"
BUILD_RC=$?
set -e
if [ "$BUILD_RC" -ne 0 ]; then
    docker exec "$CTR" bash -lc "tail -n 180 '$BUILD_LOG' || true"
    false
fi

echo
echo "===== 5/10 PACKAGE + VERIFY ====="
docker exec "$CTR" bash -lc "
    set -e
    test -s '$BUILT'
    mkdir -p '$(dirname "$PACKAGED")'
    install -m 755 '$BUILT' '$PACKAGED'
    file '$PACKAGED'
    sha256sum '$PACKAGED'
    file '$PACKAGED' | grep -Eq 'ARM aarch64|ARM64|AArch64'
    strings '$PACKAGED' | grep -E 'TSP_OBJECT_DIAG_051_V1|TSP_INTERIOR_VISGRID_051_V5_TOPO_PVS' | sort -u | head -40 || true
"
NEW_SHA="$(docker exec "$CTR" sha256sum "$PACKAGED" | awk '{print $1}')"
[ -n "$NEW_SHA" ] || die "Could not determine rebuilt SHA"
[ "$NEW_SHA" != "$PRE_DEVICE_SHA" ] || die "Rebuilt binary SHA did not change"
[ -f "$HOST_BIN" ] && cp -pf "$HOST_BIN" "$HOST_BIN.before-$STAMP"
docker cp "$CTR:$PACKAGED" "$HOST_BIN"
chmod +x "$HOST_BIN"
HOST_SHA="$(sha256sum "$HOST_BIN" | awk '{print $1}')"
[ "$HOST_SHA" = "$NEW_SHA" ] || die "Docker -> Ubuntu SHA mismatch"
file "$HOST_BIN"; sha256sum "$HOST_BIN"

echo
echo "===== 6/10 PATCH CURRENT SENSOR INTO V24 ====="
scp -q "$DEV:$LIVE_LUA" "$TMP/visgrid.current.lua"
scp -q "$DEV:$LAUNCHER" "$TMP/Morrowind_51.current.sh"
python3 - "$TMP/visgrid.current.lua" "$TMP/visgrid.v24.lua" <<'PY_LUA'
import re, sys
src_path, dst_path = sys.argv[1:3]
with open(src_path, "r", encoding="utf-8", newline="") as f: s = f.read()
MARK = "TSP_VISGRID_LUA_V24_ROOM_RESIDENCY"
if MARK not in s:
    for token in ("TSP_VISGRID_LUA_V23_PERF_MATRIX", "TSP_VISGRID_LUA_V22_1G_STRUCTURAL_PVS_SAFETY",
                  "mapState.updateTopologyPvs = function(force)", "mapState.v23Emergency = function()"):
        if token not in s: raise RuntimeError("visgrid.lua missing V23 token: " + token)
    lines = s.splitlines(True)
    hits = [i for i,line in enumerate(lines) if "TSP_VISGRID_LUA_V23_PERF_MATRIX" in line]
    if len(hits) != 1: raise RuntimeError("V23 marker count=%d" % len(hits))
    lines.insert(hits[0]+1, "-- TSP_VISGRID_LUA_V24_ROOM_RESIDENCY  (raw navmesh room PVS + gameplay-root residency + V1-class ray budget)\n")
    s = "".join(lines)
    old = "    v23TopologyMode = 1, v23RayMode = 1, v23Core = require('openmw.core'),\n"
    new = "    v23TopologyMode = 0, v23RayMode = 0, v23Core = require('openmw.core'),\n"
    if s.count(old) != 1: raise RuntimeError("t1p1 mode line count=%d" % s.count(old))
    s = s.replace(old,new,1)
    old = "    v23VerboseStructural = false, v23VerboseRayPvs = false, v23VerbosePvs = false,\n"
    new = "    v23VerboseStructural = false, v23VerboseRayPvs = true, v23VerbosePvs = true,\n"
    if s.count(old) != 1: raise RuntimeError("verbosity line count=%d" % s.count(old))
    s = s.replace(old,new,1)
    old = '''        elseif floorNow > 0 then
            mapState.pvsAddEnvelope(
                active, current,
                currentSec.kind == 'large_open')
'''
    new = '''        elseif floorNow > 0 then
            -- V24: current raw room/group only; do not reopen ordinary same-floor neighbors.
            mapState.pvsAddLatchedSector(active, current)
'''
    if s.count(old) != 1: raise RuntimeError("current room seed count=%d" % s.count(old))
    s = s.replace(old,new,1)
    old = '''    -- V22.1G is deliberately independent of ray evidence. It is the structural
    -- floor/shell safety net that must already be present before a wall or railing
    -- can ever become a blue hole.
    local structUnsafe = mapState.addStructuralPvsSafety(active)
'''
    new = '''    -- V24 ROOM RESIDENCY: do not reopen the whole current floor and do not
    -- fail PVS open merely because a broad local shell crosses several sectors.
    -- Current/resident/portal/recent/ray/trail sectors above are the residency set.
    mapState.pvsStructNearCount = 0
    mapState.pvsStructFloorCount = 0
    mapState.pvsStructWholeFloorCount = 0
    mapState.pvsStructUnsafe = false
    mapState.pvsStructUnsafeReason = ''
    local structUnsafe = false
'''
    if s.count(old) != 1: raise RuntimeError("structural safety call count=%d" % s.count(old))
    s = s.replace(old,new,1)
    old = '''    if mapState.v23RayMode == 0 then
        budget = 1
        if turning or emergency or enterBurst > 0.0
            or youngVisible > YOUNG_BURST_MIN
            or (mapState.upBoostUntil or 0.0) > interiorElapsed then
            budget = 2
        end
'''
    new = '''    if mapState.v23RayMode == 0 then
        -- V24: restore the proven V1-class continuous learning rate.
        -- Five rays/frame produced the matched Caldera 12 -> ~27 FPS proof.
        -- This remains far below the failed V2 40-rays/frame brute-force test.
        budget = 5
        if turning or emergency or enterBurst > 0.0
            or youngVisible > YOUNG_BURST_MIN
            or (mapState.upBoostUntil or 0.0) > interiorElapsed then
            budget = 6
        end
'''
    if s.count(old) != 1: raise RuntimeError("ray policy block count=%d" % s.count(old))
    s = s.replace(old,new,1)
    pat = re.compile(r"^print\('\[TSP_VISGRID_V23\] perf matrix loaded topology=.*?'\)\n", re.MULTILINE)
    m = pat.search(s)
    if not m: raise RuntimeError("V23 startup marker print not found")
    s = s[:m.end()] + "print('[TSP_VISGRID_V24] ROOM-RESIDENCY raw-topology=1 rays=5/6 whole-floor=0 gameplay-pvs=1')\n" + s[m.end():]
for token in (MARK, "v23TopologyMode = 0, v23RayMode = 0", "mapState.pvsAddLatchedSector(active, current)",
              "local structUnsafe = false", "budget = 5", "budget = 6", "v23VerboseRayPvs = true",
              "v23VerbosePvs = true", "[TSP_VISGRID_V24] ROOM-RESIDENCY"):
    if token not in s: raise RuntimeError("V24 postcondition missing: " + token)
with open(dst_path, "w", encoding="utf-8", newline="\n") as f: f.write(s)
print("PASS: V24 raw-sector room residency Lua generated.")
print("PASS: whole-floor/shell safety removed from active set.")
print("PASS: continuous ray budget = 5 steady / 6 turn-entry-emergency.")
PY_LUA

PARSER=""
for x in texlua lua luajit; do command -v "$x" >/dev/null 2>&1 && { PARSER="$x"; break; }; done
if [ -n "$PARSER" ]; then
    cat > "$TMP/parse-v24.lua" <<'LUA_PARSE'
local f,e=loadfile(arg[1])
if not f then error(e) end
print("LUA_PARSE_PASS " .. arg[1])
LUA_PARSE
    "$PARSER" "$TMP/parse-v24.lua" "$TMP/visgrid.v24.lua"
fi
V24_LUA_SHA="$(sha256sum "$TMP/visgrid.v24.lua" | awk '{print $1}')"
echo "V24 Lua SHA: $V24_LUA_SHA"

echo
echo "===== 7/10 BUILD V24 LAUNCHER + EVERY-RUN CAPTURE ====="
python3 - "$TMP/Morrowind_51.current.sh" "$TMP/Morrowind_51.v24.sh" <<'PY_LAUNCHER'
import sys
src_path,dst_path=sys.argv[1:3]
with open(src_path,"r",encoding="utf-8",newline="") as f: s=f.read()
v23b="# >>> TSP_VISGRID_V23_PROFILE BEGIN"; v23e="# <<< TSP_VISGRID_V23_PROFILE END"
v24b="# >>> TSP_VISGRID_V24_ROOM_RESIDENCY BEGIN"; v24e="# <<< TSP_VISGRID_V24_ROOM_RESIDENCY END"
block='''# >>> TSP_VISGRID_V24_ROOM_RESIDENCY BEGIN
# Fixed V24 profile: raw navmesh-sector room residency + continuous 5/6-ray learning.
TSP_VISGRID_DIR="$GAMEDIR/mods/TSPInteriorVisGrid/scripts/TSPInteriorVisGrid"
TSP_VISGRID_LIVE="$TSP_VISGRID_DIR/visgrid.lua"
TSP_VISGRID_SELECTED="$TSP_VISGRID_DIR/v24_profiles/visgrid-v24-room-residency.lua"
if [ ! -s "$TSP_VISGRID_SELECTED" ]; then
    echo "ERROR: V24 room-residency profile is missing:"
    echo "  $TSP_VISGRID_SELECTED"
    exit 72
fi
TSP_VISGRID_SELECTED_SHA="$(sha256sum "$TSP_VISGRID_SELECTED" | awk 'NF {print $1; exit}')"
TSP_VISGRID_LIVE_SHA=""
[ -s "$TSP_VISGRID_LIVE" ] && TSP_VISGRID_LIVE_SHA="$(sha256sum "$TSP_VISGRID_LIVE" | awk 'NF {print $1; exit}')"
if [ "$TSP_VISGRID_SELECTED_SHA" != "$TSP_VISGRID_LIVE_SHA" ]; then
    cp -f "$TSP_VISGRID_SELECTED" "$TSP_VISGRID_LIVE.v24-new"
    chmod 644 "$TSP_VISGRID_LIVE.v24-new" 2>/dev/null || true
    mv -f "$TSP_VISGRID_LIVE.v24-new" "$TSP_VISGRID_LIVE"
    sync
fi
export TSP_OBJECT_DIAG=1
echo "Visgrid Profile=v24-room-residency"
echo "Visgrid SHA=$(sha256sum "$TSP_VISGRID_LIVE" | awk 'NF {print $1; exit}')"
echo "Visgrid room policy=raw sectors; whole-floor off; rays 5/6"
# <<< TSP_VISGRID_V24_ROOM_RESIDENCY END'''
if v24b in s or v24e in s:
    if s.count(v24b)!=1 or s.count(v24e)!=1: raise RuntimeError("V24 launcher markers not unique")
    a=s.index(v24b); b=s.index(v24e,a)+len(v24e); s=s[:a]+block+s[b:]
else:
    if s.count(v23b)!=1 or s.count(v23e)!=1: raise RuntimeError("V23 launcher block markers not unique")
    a=s.index(v23b); b=s.index(v23e,a)+len(v23e); s=s[:a]+block+s[b:]
capb="# >>> TSP_VISGRID_V24_AUTO_CAPTURE BEGIN"
cap='''# >>> TSP_VISGRID_V24_AUTO_CAPTURE BEGIN
if [ -x "$GAMEDIR/tsp_visgrid_v24_capture.sh" ]; then
    "$GAMEDIR/tsp_visgrid_v24_capture.sh" "$OPENMW_EXIT_CODE" || true
fi
# <<< TSP_VISGRID_V24_AUTO_CAPTURE END'''
if capb not in s:
    anchor='    echo "TSP resolution launcher: normal game exit"\n'
    if s.count(anchor)!=1: raise RuntimeError("normal-exit capture anchor count=%d" % s.count(anchor))
    s=s.replace(anchor,anchor+cap+"\n",1)
for token in (v24b,v24e,'v24_profiles/visgrid-v24-room-residency.lua','export TSP_OBJECT_DIAG=1',capb,'tsp_visgrid_v24_capture.sh'):
    if token not in s: raise RuntimeError("launcher postcondition missing: "+token)
with open(dst_path,"w",encoding="utf-8",newline="\n") as f: f.write(s)
print("PASS: launcher fixed to V24 and automatic capture enabled.")
PY_LAUNCHER
chmod +x "$TMP/Morrowind_51.v24.sh"
bash -n "$TMP/Morrowind_51.v24.sh"

cat > "$TMP/tsp_visgrid_v24_capture.sh" <<'CAPTURE'
#!/bin/bash
set +e
ROOT="/mnt/SDCARD/data/ports/openmw51"
OUTDIR="$ROOT/visgrid-v24-captures"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="$OUTDIR/visgrid-v24-$STAMP.txt"
LATEST="$ROOT/visgrid-v24-latest.txt"
EXIT_CODE="${1:-unknown}"
TMP="/tmp/visgrid-v24-capture.$$"
mkdir -p "$OUTDIR"
: > "$TMP"
extract_latest_run() {
    f="$1"; [ -f "$f" ] || return 0
    tail -n 35000 "$f" | awk '
        /\[TSP_VISGRID_V24\] ROOM-RESIDENCY/ { buf=""; found=1 }
        found { buf=buf $0 ORS }
        END { if (found) printf "%s", buf }
    '
}
for f in "$ROOT/openmw_051_log.txt" "$ROOT/config-0.51/openmw.log" "$ROOT/openmw.log"; do
    [ -f "$f" ] && extract_latest_run "$f" >> "$TMP"
done
{
    echo "============================================================"
    echo "OPENMW 0.51 VISGRID V24 AUTOMATIC RUN CAPTURE"
    echo "============================================================"
    echo "Captured: $(date)"
    echo "OpenMW exit code: $EXIT_CODE"
    echo
    echo "===== IDENTITY ====="
    printf "Current binary: "; sha256sum "$ROOT/bin/openmw-0.51" 2>/dev/null || true
    printf "Current sensor: "; sha256sum "$ROOT/mods/TSPInteriorVisGrid/scripts/TSPInteriorVisGrid/visgrid.lua" 2>/dev/null || true
    echo
    BAD_CAST="$(grep -c 'Bad LiveCellRef cast to STAT' "$TMP" 2>/dev/null || true)"
    FAIL_RENDER="$(grep -c 'failed to render' "$TMP" 2>/dev/null || true)"
    PVS_CULL="$(grep -c '\[TSP_VISOBJ_CULL\] reason=PVS' "$TMP" 2>/dev/null || true)"
    PVS_DYNAMIC="$(grep -c '\[TSP_VISOBJ_CULL\] reason=PVS.*static=0' "$TMP" 2>/dev/null || true)"
    PVS_STATIC="$(grep -c '\[TSP_VISOBJ_CULL\] reason=PVS.*static=1' "$TMP" 2>/dev/null || true)"
    GRID_CULL="$(grep -c '\[TSP_VISOBJ_CULL\] reason=GRID' "$TMP" 2>/dev/null || true)"
    ATTACH_ELIG="$(grep -c '\[TSP_VISOBJ_ATTACH\].*pvsEligible=1' "$TMP" 2>/dev/null || true)"
    ATTACH_DYNAMIC="$(grep -c '\[TSP_VISOBJ_ATTACH\].*static=0.*pvsEligible=1' "$TMP" 2>/dev/null || true)"
    echo "V24 SUMMARY"
    echo "Bad STAT casts: $BAD_CAST"
    echo "Render failures: $FAIL_RENDER"
    echo "PVS culls total: $PVS_CULL"
    echo "PVS culls gameplay/non-static: $PVS_DYNAMIC"
    echo "PVS culls structural/static: $PVS_STATIC"
    echo "GRID culls: $GRID_CULL"
    echo "PVS-eligible roots attached: $ATTACH_ELIG"
    echo "PVS-eligible gameplay roots attached: $ATTACH_DYNAMIC"
    echo
    echo "===== V24 / ROOM / RAY / PVS TELEMETRY ====="
    grep -E 'TSP_VISGRID_V24|TSP_VISGRID_V23PERF|TSP_VISGRID_V11|TSP_VISGRID_V20.*PVS|RAY-PVS|PVS SHADOW|PVS RELEASE|topology sector=|sector switch' "$TMP" 2>/dev/null | tail -2200 || true
    echo
    echo "===== OBJECT ROOM-PVS CULLS ====="
    grep -E '\[TSP_VISOBJ_CULL\] reason=PVS' "$TMP" 2>/dev/null | tail -2500 || true
    echo
    echo "===== GRID CULLS ====="
    grep -E '\[TSP_VISOBJ_CULL\] reason=GRID' "$TMP" 2>/dev/null | tail -1200 || true
    echo
    echo "===== PVS-ELIGIBLE GAMEPLAY ROOT EXAMPLES ====="
    grep -E '\[TSP_VISOBJ_ATTACH\].*static=0.*pvsEligible=1' "$TMP" 2>/dev/null | head -400 || true
    echo
    echo "===== BAD CAST / RENDER FAILURE ====="
    grep -E 'Bad LiveCellRef cast|failed to render' "$TMP" 2>/dev/null | tail -400 || true
    echo
    echo "===== PERF SAMPLER TAIL ====="
    [ -f "$ROOT/openmw51_perf_latest.txt" ] && tail -500 "$ROOT/openmw51_perf_latest.txt"
} > "$OUT"
cp -f "$OUT" "$LATEST"
sync
rm -f "$TMP"
echo "V24 automatic capture: $OUT"
CAPTURE
chmod +x "$TMP/tsp_visgrid_v24_capture.sh"

echo
echo "===== 8/10 DEVICE BACKUP ====="
DEVICE_BACKUP="$ROOT/backups/visgrid-v24-room-residency-$STAMP"
ssh "$DEV" "bash -s" <<REMOTE_BACKUP
set -e
B='$DEVICE_BACKUP'; mkdir -p "\$B"
cp -pf '$REMOTE_BIN' "\$B/openmw-0.51.before"
cp -pf '$LIVE_LUA' "\$B/visgrid.lua.before"
cp -pf '$LAUNCHER' "\$B/launcher.before"
if [ -f '$V24_PROFILE' ]; then touch "\$B/v24profile.existed"; cp -pf '$V24_PROFILE' "\$B/v24profile.before"; fi
if [ -f '$CAPTURE_HELPER' ]; then touch "\$B/helper.existed"; cp -pf '$CAPTURE_HELPER' "\$B/capture-helper.before"; fi
sha256sum "\$B/openmw-0.51.before" "\$B/visgrid.lua.before" "\$B/launcher.before"
REMOTE_BACKUP

echo
echo "===== 9/10 INSTALL V24 ====="
DEVICE_DEPLOY_STARTED=1
scp -q "$HOST_BIN" "$DEV:$REMOTE_TMP_BIN"
scp -q "$TMP/visgrid.v24.lua" "$DEV:/tmp/visgrid-v24-room-residency.lua"
scp -q "$TMP/Morrowind_51.v24.sh" "$DEV:/tmp/Morrowind_51.v24.sh"
scp -q "$TMP/tsp_visgrid_v24_capture.sh" "$DEV:/tmp/tsp_visgrid_v24_capture.sh"
ssh "$DEV" "bash -s" <<REMOTE_INSTALL
set -e
NEW_SHA='$NEW_SHA'; LUA_SHA='$V24_LUA_SHA'
test "\$(sha256sum '$REMOTE_TMP_BIN' | awk '{print \$1}')" = "\$NEW_SHA"
test "\$(sha256sum /tmp/visgrid-v24-room-residency.lua | awk '{print \$1}')" = "\$LUA_SHA"
mkdir -p '$V24_DIR'
install -m 755 '$REMOTE_TMP_BIN' '$REMOTE_BIN'
install -m 644 /tmp/visgrid-v24-room-residency.lua '$V24_PROFILE'
install -m 644 /tmp/visgrid-v24-room-residency.lua '$LIVE_LUA'
install -m 755 /tmp/Morrowind_51.v24.sh '$LAUNCHER'
install -m 755 /tmp/tsp_visgrid_v24_capture.sh '$CAPTURE_HELPER'
rm -f '$REMOTE_TMP_BIN' /tmp/visgrid-v24-room-residency.lua /tmp/Morrowind_51.v24.sh /tmp/tsp_visgrid_v24_capture.sh
sync
test "\$(sha256sum '$REMOTE_BIN' | awk '{print \$1}')" = "\$NEW_SHA"
test "\$(sha256sum '$V24_PROFILE' | awk '{print \$1}')" = "\$LUA_SHA"
test "\$(sha256sum '$LIVE_LUA' | awk '{print \$1}')" = "\$LUA_SHA"
bash -n '$LAUNCHER'
grep -Fq 'TSP_VISGRID_V24_ROOM_RESIDENCY' '$LAUNCHER'
grep -Fq 'export TSP_OBJECT_DIAG=1' '$LAUNCHER'
grep -Fq 'TSP_VISGRID_LUA_V24_ROOM_RESIDENCY' '$LIVE_LUA'
grep -Fq 'v23TopologyMode = 0, v23RayMode = 0' '$LIVE_LUA'
grep -Fq 'budget = 5' '$LIVE_LUA'
grep -Fq 'local structUnsafe = false' '$LIVE_LUA'
echo 'Installed binary:'; sha256sum '$REMOTE_BIN'
echo 'Installed sensor:'; sha256sum '$LIVE_LUA'
echo 'Installed launcher:'; sha256sum '$LAUNCHER'
REMOTE_INSTALL

echo
echo "===== 10/10 SAVE ROLLBACK STATE ====="
cat > "$STATE" <<EOF_STATE
SOURCE_BACKUP='$SOURCE_BACKUP'
DEVICE_BACKUP='$DEVICE_BACKUP'
LAUNCHER='$LAUNCHER'
PRE_DEVICE_SHA='$PRE_DEVICE_SHA'
FIX_DEVICE_SHA='$NEW_SHA'
PRE_LUA_SHA='$PRE_LUA_SHA'
V24_LUA_SHA='$V24_LUA_SHA'
HOST_BIN='$HOST_BIN'
EOF_STATE
trap - ERR

echo
echo "============================================================"
echo "V24 ROOM RESIDENCY INSTALLED"
echo "============================================================"
echo "Old binary SHA: $PRE_DEVICE_SHA"
echo "New binary SHA: $NEW_SHA"
echo "V24 Lua SHA:    $V24_LUA_SHA"
echo
echo "Policy:"
echo "  raw navmesh sectors; V23 macro regions OFF"
echo "  whole-current-floor keepalive OFF"
echo "  broad V22.1G structural shell fail-open OFF"
echo "  current/resident/recent/portal/ray/trail sectors remain"
echo "  gameplay clutter participates in room PVS"
echo "  gameplay overlap padding max = 96 XY / 64 Z"
echo "  static architecture keeps old generous padding"
echo "  rays = 5/frame steady, 6 on turn/entry/emergency"
echo "  actors and doors still bypass room residency"
echo
echo "Every NORMAL game exit automatically writes:"
echo "  $ROOT/visgrid-v24-latest.txt"
echo "and timestamped copies under:"
echo "  $ROOT/visgrid-v24-captures/"
echo
echo "ONE TEST: same bad Caldera multi-floor interior; upper/third floor; face the blank inward wall;"
echo "give it the same few seconds V1 needed; note FPS; then expose stairs/doorways and check for popping."
echo "Also verify a nearby container is visible when appropriate, solid, and activatable. Exit normally."
echo
echo "Then download the automatic capture with:"
echo "  cd ~/Downloads"
echo "  ./apply_openmw51_tsp_visgrid_v24_room_residency.sh collect"
echo
echo "Rollback:"
echo "  ./apply_openmw51_tsp_visgrid_v24_room_residency.sh rollback"
echo "============================================================"
