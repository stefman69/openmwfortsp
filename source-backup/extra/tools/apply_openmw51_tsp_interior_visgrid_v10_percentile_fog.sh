#!/usr/bin/env bash
CR=$(printf '\r'); case "$(head -c 400 "$0" 2>/dev/null)" in *"$CR"*) echo "v10: stripping CRLF and re-running"; exec bash -c 'sed "s/\r$//" "$1" | bash' v10 "$0" ;; esac
set -Eeuo pipefail

DEV="${TSP_DEV:-root@192.168.1.25}"
C="${TSP_BUILDER:-openmw_builder}"
STAMP="$(date +%Y%m%d-%H%M%S)"

ROOT="/mnt/SDCARD/data/ports/openmw51"
BIN="$ROOT/bin/openmw-0.51"
MOD="$ROOT/mods/TSPInteriorVisGrid"
OMW="$MOD/TSPInteriorVisGrid.omwscripts"
LUA="$MOD/scripts/TSPInteriorVisGrid/visgrid.lua"

SRC="/root/openmw-0.51-tsp-src"
BUILD="/root/openmw-0.51-tsp-build"
OPENMW_BIN="$BUILD/openmw"
HPP="$SRC/apps/openmw/mwrender/interiorvisibility.hpp"
CPP="$SRC/apps/openmw/mwrender/interiorvisibility.cpp"
RMGR="$SRC/apps/openmw/mwrender/renderingmanager.cpp"

PKG="$HOME/Downloads/openmw51-interior-visgrid-v10-percentile-fog-$STAMP"
TOOLS="$HOME/Downloads/visgrid-tools"
LOG="$PKG/install.log"
mkdir -p "$PKG/sensors" "$PKG/device-backup" "$PKG/source-backup" "$PKG/patched-source" "$TOOLS"

V10_MD5="dac6a729e1ba886de099dbfaf774192c"

SOURCE_BACKUP_DIR=""
SOURCE_RESTORE_ON_ERROR=0
SOURCE_EDITED=0
REMOTE_BACKUP=""
DEVICE_ROLLBACK_READY=0
DEVICE_DEPLOY_STARTED=0
DEVICE_ROLLBACK_DONE=0

fail_report() {
    local rc="${1:-1}"
    local line="${2:-unknown}"
    local cmd="${3:-unknown}"
    trap - ERR
    set +e

    local report="$PKG/STOPPED_ERROR.txt"
    {
        echo "=================================================================="
        echo "VISGRID V10 STOPPED SAFELY"
        echo "=================================================================="
        echo "Date: $(date)"
        echo "Exit code: $rc"
        echo "Line: $line"
        echo "Command: $cmd"
        echo

        if [ "${SOURCE_RESTORE_ON_ERROR:-0}" = "1" ] && [ "${SOURCE_EDITED:-0}" = "1" ] \
            && [ -n "${SOURCE_BACKUP_DIR:-}" ]; then
            echo "----- RESTORING CONTAINER SOURCE -----"
            docker exec "$C" bash -lc "
                set -euo pipefail
                for base in interiorvisibility.hpp interiorvisibility.cpp renderingmanager.cpp; do
                    test -s '$SOURCE_BACKUP_DIR/'\"\$base\"
                done
                cp -p '$SOURCE_BACKUP_DIR/interiorvisibility.hpp' '$HPP'
                cp -p '$SOURCE_BACKUP_DIR/interiorvisibility.cpp' '$CPP'
                cp -p '$SOURCE_BACKUP_DIR/renderingmanager.cpp' '$RMGR'
                touch '$HPP' '$CPP' '$RMGR'
                find '$BUILD' -type f \( -name 'interiorvisibility.cpp.o' -o -name 'renderingmanager.cpp.o' \) -print -delete 2>/dev/null || true
                rm -f '$OPENMW_BIN' '$BUILD/apps/openmw/openmw' 2>/dev/null || true
                test \"\$(sha256sum '$HPP' | awk '{print \$1}')\" = \"\$(sha256sum '$SOURCE_BACKUP_DIR/interiorvisibility.hpp' | awk '{print \$1}')\"
                test \"\$(sha256sum '$CPP' | awk '{print \$1}')\" = \"\$(sha256sum '$SOURCE_BACKUP_DIR/interiorvisibility.cpp' | awk '{print \$1}')\"
                test \"\$(sha256sum '$RMGR' | awk '{print \$1}')\" = \"\$(sha256sum '$SOURCE_BACKUP_DIR/renderingmanager.cpp' | awk '{print \$1}')\"
                echo 'PASS: exact pre-V10 source restored.'
            " || echo "WARNING: automatic source restore failed; backups remain at $SOURCE_BACKUP_DIR"
            echo
        fi

        if [ "${DEVICE_DEPLOY_STARTED:-0}" = "1" ] \
            && [ "${DEVICE_ROLLBACK_READY:-0}" = "1" ] \
            && [ "${DEVICE_ROLLBACK_DONE:-0}" != "1" ] \
            && [ -n "${REMOTE_BACKUP:-}" ]; then
            echo "----- RESTORING DEVICE PRE-V10 STATE -----"
            if ssh "$DEV" "
                set -e
                test -s '$REMOTE_BACKUP/openmw-0.51'
                test -s '$REMOTE_BACKUP/visgrid.lua.before-v10'
                test -s '$REMOTE_BACKUP/TSPInteriorVisGrid.omwscripts'
                cp -p '$REMOTE_BACKUP/openmw-0.51' '$BIN.new'
                chmod 755 '$BIN.new'
                mv -f '$BIN.new' '$BIN'
                cp -p '$REMOTE_BACKUP/visgrid.lua.before-v10' '$LUA.new'
                mv -f '$LUA.new' '$LUA'
                cp -p '$REMOTE_BACKUP/TSPInteriorVisGrid.omwscripts' '$OMW.new'
                mv -f '$OMW.new' '$OMW'
                sync
                test \"\$(sha256sum '$BIN' | awk '{print \$1}')\" = \"\$(sha256sum '$REMOTE_BACKUP/openmw-0.51' | awk '{print \$1}')\"
                test \"\$(sha256sum '$LUA' | awk '{print \$1}')\" = \"\$(sha256sum '$REMOTE_BACKUP/visgrid.lua.before-v10' | awk '{print \$1}')\"
                test \"\$(sha256sum '$OMW' | awk '{print \$1}')\" = \"\$(sha256sum '$REMOTE_BACKUP/TSPInteriorVisGrid.omwscripts' | awk '{print \$1}')\"
            "; then
                DEVICE_ROLLBACK_DONE=1
                echo "PASS: exact pre-V10 device state restored."
            else
                echo "WARNING: automatic device rollback failed."
                echo "Backup remains at $REMOTE_BACKUP"
            fi
            echo
        fi

        [ -f "$LOG" ] && { echo "----- install.log tail -----"; tail -220 "$LOG" || true; }
        [ -f "$PKG/build.log" ] && { echo "----- build.log tail -----"; tail -160 "$PKG/build.log" || true; }
        echo
        echo "Preserved package: $PKG"
        echo "=================================================================="
    } 2>&1 | tee "$report"

    if [ -t 0 ]; then
        read -r -p "Press Enter to return to the shell... " _ || true
    fi
    exit "$rc"
}
trap 'fail_report "$?" "$LINENO" "$BASH_COMMAND"' ERR
exec > >(tee "$LOG") 2>&1

echo "=================================================================="
echo "OPENMW 0.51 TSP — VISGRID V10 PERSISTENT OPENINGS + PERCENTILE FOG"
echo "=================================================================="
echo
echo "V10 does NOT lower the projection during normal interior play."
echo "The VISGRID curtain remains the performance culler."
echo
echo "Fog is now independent of the deepest doorway tile:"
echo "  - C++ computes the 75th-percentile published tile depth"
echo "  - fog end follows that shallow-majority guide"
echo "  - fog starts at <=25% of fog end, deliberately thick"
echo "  - fog moves inward immediately, recedes gradually"
echo
echo "Narrow openings are also hardened:"
echo "  - an accepted deep doorway/slit is periodically rechecked through"
echo "    its exact saved sub-direction"
echo "  - random shallow jitter elsewhere in its coarse bin cannot erase it"
echo
echo "No hard Z cap in V10."
echo

command -v docker >/dev/null
docker inspect "$C" >/dev/null
if [ "$(docker inspect -f '{{.State.Running}}' "$C")" != "true" ]; then docker start "$C"; fi

echo "===== 1/10 VERIFY CURRENT SOURCE + DEVICE ====="
docker exec "$C" bash -lc "
set -euo pipefail
test -s '$HPP'; test -s '$CPP'; test -s '$RMGR'
grep -Fq 'TSP_INTERIOR_VISGRID_051_V1' '$HPP'
grep -Fq 'TSP_INTERIOR_VISGRID_051_V1' '$CPP'
grep -Fq 'TSP_INTERIOR_VISGRID_051_V1' '$RMGR'
grep -Fq 'getInteriorVisibilityFarFloor' '$HPP'
grep -Fq 'getInteriorVisibilityFarFloor' '$CPP'
if grep -Fq 'TSP_INTERIOR_VISGRID_051_V3_PERCENTILE_FOG' '$RMGR'; then
    echo SOURCE_STATE=V10_V3
elif grep -Fq 'TSP_INTERIOR_VISGRID_051_V2_FOGFOLLOW' '$RMGR'; then
    echo SOURCE_STATE=V9_V2
else
    echo SOURCE_STATE=V1_NO_FOG
fi
"
ssh -o BatchMode=yes -o ConnectTimeout=8 "$DEV" "
set -e
test -s '$BIN'; test -s '$LUA'; test -s '$OMW'
grep -a -q 'TSP_INTERIOR_VISGRID_051_V1' '$BIN'
grep -Fq 'PLAYER: scripts/TSPInteriorVisGrid/visgrid.lua' '$OMW'
echo \"Host: \$(hostname)\"
echo \"Date: \$(date)\"
"
if ssh "$DEV" 'pidof openmw-0.51 >/dev/null 2>&1 || pidof openmw >/dev/null 2>&1'; then
    echo "ERROR: OpenMW is running. Exit normally and rerun this same script."
    exit 20
fi
echo "PASS: expected VISGRID source/device state; OpenMW closed."

echo
echo "===== 2/10 DEVICE BACKUP + SHA VERIFICATION ====="
REMOTE_BACKUP="$ROOT/backups/interior-visgrid-v10-percentile-fog-$STAMP"
ssh "$DEV" "
set -e
mkdir -p '$REMOTE_BACKUP'
cp -p '$BIN' '$REMOTE_BACKUP/openmw-0.51'
cp -p '$LUA' '$REMOTE_BACKUP/visgrid.lua.before-v10'
cp -p '$OMW' '$REMOTE_BACKUP/TSPInteriorVisGrid.omwscripts'
test \"\$(sha256sum '$BIN' | awk '{print \$1}')\" = \"\$(sha256sum '$REMOTE_BACKUP/openmw-0.51' | awk '{print \$1}')\"
test \"\$(sha256sum '$LUA' | awk '{print \$1}')\" = \"\$(sha256sum '$REMOTE_BACKUP/visgrid.lua.before-v10' | awk '{print \$1}')\"
test \"\$(sha256sum '$OMW' | awk '{print \$1}')\" = \"\$(sha256sum '$REMOTE_BACKUP/TSPInteriorVisGrid.omwscripts' | awk '{print \$1}')\"
sha256sum '$REMOTE_BACKUP/openmw-0.51' '$REMOTE_BACKUP/visgrid.lua.before-v10' '$REMOTE_BACKUP/TSPInteriorVisGrid.omwscripts' > '$REMOTE_BACKUP/SHA256SUMS.before.txt'
sync
cat '$REMOTE_BACKUP/SHA256SUMS.before.txt'
"
scp -q "$DEV:$REMOTE_BACKUP/openmw-0.51" "$PKG/device-backup/openmw-0.51"
scp -q "$DEV:$REMOTE_BACKUP/visgrid.lua.before-v10" "$PKG/device-backup/visgrid.lua.before-v10"
scp -q "$DEV:$REMOTE_BACKUP/TSPInteriorVisGrid.omwscripts" "$PKG/device-backup/TSPInteriorVisGrid.omwscripts"
test "$(ssh "$DEV" "sha256sum '$BIN' | awk '{print \$1}'")" = "$(sha256sum "$PKG/device-backup/openmw-0.51" | awk '{print $1}')"
test "$(ssh "$DEV" "sha256sum '$LUA' | awk '{print \$1}'")" = "$(sha256sum "$PKG/device-backup/visgrid.lua.before-v10" | awk '{print $1}')"
test "$(ssh "$DEV" "sha256sum '$OMW' | awk '{print \$1}'")" = "$(sha256sum "$PKG/device-backup/TSPInteriorVisGrid.omwscripts" | awk '{print $1}')"
sha256sum "$PKG/device-backup/"* > "$PKG/device-backup/SHA256SUMS.txt"
DEVICE_ROLLBACK_READY=1
echo "PASS: device + VM backup copies verified."

echo
echo "===== 3/10 SOURCE BACKUP + SHA VERIFICATION BEFORE ANY EDIT ====="
SOURCE_BACKUP_DIR="/root/openmw51-visgrid-v10-src-backup-$STAMP"
docker exec "$C" bash -lc "
set -euo pipefail
mkdir -p '$SOURCE_BACKUP_DIR'
cp -p '$HPP' '$SOURCE_BACKUP_DIR/interiorvisibility.hpp'
cp -p '$CPP' '$SOURCE_BACKUP_DIR/interiorvisibility.cpp'
cp -p '$RMGR' '$SOURCE_BACKUP_DIR/renderingmanager.cpp'
test \"\$(sha256sum '$HPP' | awk '{print \$1}')\" = \"\$(sha256sum '$SOURCE_BACKUP_DIR/interiorvisibility.hpp' | awk '{print \$1}')\"
test \"\$(sha256sum '$CPP' | awk '{print \$1}')\" = \"\$(sha256sum '$SOURCE_BACKUP_DIR/interiorvisibility.cpp' | awk '{print \$1}')\"
test \"\$(sha256sum '$RMGR' | awk '{print \$1}')\" = \"\$(sha256sum '$SOURCE_BACKUP_DIR/renderingmanager.cpp' | awk '{print \$1}')\"
sha256sum '$SOURCE_BACKUP_DIR/'* > '$SOURCE_BACKUP_DIR/SHA256SUMS.prepatch.txt'
echo 'PASS: source backup verified before edit.'
"
for base in interiorvisibility.hpp interiorvisibility.cpp renderingmanager.cpp; do
    docker cp "$C:$SOURCE_BACKUP_DIR/$base" "$PKG/source-backup/$base"
    test "$(docker exec "$C" sha256sum "$SOURCE_BACKUP_DIR/$base" | awk '{print $1}')" = "$(sha256sum "$PKG/source-backup/$base" | awk '{print $1}')"
done
sha256sum "$PKG/source-backup/"* > "$PKG/source-backup/SHA256SUMS.txt"
SOURCE_RESTORE_ON_ERROR=1
echo "PASS: source backup verified in container + VM."

echo
echo "===== 4/10 APPLY V10 ENGINE PATCH ====="
docker exec -i "$C" python3 - <<'PY_V10_PATCH'
from pathlib import Path

root = Path("/root/openmw-0.51-tsp-src")
hpp = root / "apps/openmw/mwrender/interiorvisibility.hpp"
cpp = root / "apps/openmw/mwrender/interiorvisibility.cpp"
rmgr = root / "apps/openmw/mwrender/renderingmanager.cpp"

HMARK = "TSP_INTERIOR_VISGRID_051_V3_PERCENTILE_FOG"

ht = hpp.read_text()
ct = cpp.read_text()
rt = rmgr.read_text()

for name, text in (("hpp", ht), ("cpp", ct), ("render", rt)):
    if "TSP_INTERIOR_VISGRID_051_V1" not in text:
        raise RuntimeError(f"{name}: V1 marker missing; refusing source mutation")

changed = False

if "getInteriorVisibilityFogGuide" not in ht:
    anchor = "    float getInteriorVisibilityFarFloor();\n"
    if ht.count(anchor) != 1:
        raise RuntimeError(f"hpp fog getter anchor count={ht.count(anchor)}")
    ht = ht.replace(
        anchor,
        anchor
        + "    // TSP_INTERIOR_VISGRID_051_V3_PERCENTILE_FOG\n"
        + "    float getInteriorVisibilityFogGuide();\n",
        1,
    )
    changed = True

if "sFogGuide" not in ct:
    anchor = "        std::atomic<float> sFarFloor{ 0.f };\n"
    if ct.count(anchor) != 1:
        raise RuntimeError(f"cpp sFarFloor anchor count={ct.count(anchor)}")
    ct = ct.replace(
        anchor,
        anchor
        + "        // TSP_INTERIOR_VISGRID_051_V3_PERCENTILE_FOG\n"
        + "        std::atomic<float> sFogGuide{ 0.f };\n",
        1,
    )
    changed = True

if "tspFogDepths" not in ct:
    old = """        float farFloor = 0.f;
        for (int i = 0; i < count; ++i)
        {
            float d = depths[static_cast<std::size_t>(i)];
            if (!finitePositive(d))
                d = std::numeric_limits<float>::max() / 1024.f;
            sDepths[static_cast<std::size_t>(i)].store(d, std::memory_order_relaxed);
            farFloor = std::max(farFloor, d);
        }

        sCols.store(cols, std::memory_order_relaxed);
        sRows.store(rows, std::memory_order_relaxed);
        sPadding.store(std::max(0.f, padding), std::memory_order_relaxed);
        sFarFloor.store(farFloor, std::memory_order_relaxed);
        sEnabled.store(true, std::memory_order_release);
"""
    if ct.count(old) != 1:
        raise RuntimeError(f"cpp set-grid block count={ct.count(old)}")
    new = """        float farFloor = 0.f;
        // TSP_INTERIOR_VISGRID_051_V3_PERCENTILE_FOG
        // Fog follows the SHALLOW MAJORITY of the curtain, not its deepest
        // doorway tile. Projection correctness still uses farFloor.
        std::array<float, sInteriorVisibilityMaxTiles> tspFogDepths{};
        for (int i = 0; i < count; ++i)
        {
            float d = depths[static_cast<std::size_t>(i)];
            if (!finitePositive(d))
                d = std::numeric_limits<float>::max() / 1024.f;
            sDepths[static_cast<std::size_t>(i)].store(d, std::memory_order_relaxed);
            tspFogDepths[static_cast<std::size_t>(i)] = d;
            farFloor = std::max(farFloor, d);
        }

        std::sort(tspFogDepths.begin(), tspFogDepths.begin() + count);
        // 75th percentile: up to one quarter of the screen may be a genuinely
        // deep doorway/corridor without pushing the fog wall to that depth.
        const int tspFogIndex = std::clamp(
            static_cast<int>(std::ceil(static_cast<float>(count) * 0.75f)) - 1,
            0, count - 1);
        const float tspFogGuide = tspFogDepths[static_cast<std::size_t>(tspFogIndex)];

        sCols.store(cols, std::memory_order_relaxed);
        sRows.store(rows, std::memory_order_relaxed);
        sPadding.store(std::max(0.f, padding), std::memory_order_relaxed);
        sFarFloor.store(farFloor, std::memory_order_relaxed);
        sFogGuide.store(tspFogGuide, std::memory_order_relaxed);
        sEnabled.store(true, std::memory_order_release);
"""
    ct = ct.replace(old, new, 1)
    changed = True

if "sFogGuide.store(0.f" not in ct:
    anchor = "        sFarFloor.store(0.f, std::memory_order_relaxed);\n"
    if ct.count(anchor) != 1:
        raise RuntimeError(f"cpp clear farFloor anchor count={ct.count(anchor)}")
    ct = ct.replace(
        anchor,
        anchor + "        sFogGuide.store(0.f, std::memory_order_relaxed);\n",
        1,
    )
    changed = True

if "float getInteriorVisibilityFogGuide()" not in ct:
    anchor = """    float getInteriorVisibilityFarFloor()
    {
        return sFarFloor.load(std::memory_order_relaxed);
    }

"""
    if ct.count(anchor) != 1:
        raise RuntimeError(f"cpp getter anchor count={ct.count(anchor)}")
    ct = ct.replace(
        anchor,
        anchor
        + "    // TSP_INTERIOR_VISGRID_051_V3_PERCENTILE_FOG\n"
        + "    float getInteriorVisibilityFogGuide()\n"
        + "    {\n"
        + "        return sFogGuide.load(std::memory_order_relaxed);\n"
        + "    }\n\n",
        1,
    )
    changed = True

v3_block = r"""        // TSP_INTERIOR_VISGRID_051_V3_PERCENTILE_FOG
        //
        // The visibility curtain is NON-UNIFORM: a close wall tile may be
        // ~200 while a doorway tile is 3000+. A single global fog end tied to
        // the DEEPEST tile cannot hide a mistake in the close-wall tile.
        //
        // The C++ VISGRID store therefore computes the 75th-percentile
        // published depth. Fog follows the shallow majority of the screen while
        // the real projection remains deep enough for legitimate portals.
        //
        // Fog moves IN immediately and recedes OUT gradually. Starting fog at
        // <=25% of its end distance creates a deliberate thick curtain rather
        // than V9's thin shell at the far plane.
        static bool tspPercentileFogLogged = false;
        static bool tspPercentileFogWasActive = false;
        static float tspPercentileFogAppliedEnd = 0.f;

        if (isInteriorVisibilityGridEnabled() && !isUnderwater)
        {
            if (!tspPercentileFogLogged)
            {
                tspPercentileFogLogged = true;
                Log(Debug::Info) << "TSP_INTERIOR_VISGRID_051_V3_PERCENTILE_FOG active";
            }

            const float tspFogGuide = getInteriorVisibilityFogGuide();
            const bool tspGuideUsable
                = std::isfinite(tspFogGuide) && tspFogGuide > 0.f && tspFogGuide < 3200.f;

            float tspFogTargetEnd = std::min(fogEnd, mViewDistance);
            if (tspGuideUsable)
            {
                const float tspFogMargin = std::max(500.f, tspFogGuide * 0.50f);
                const float tspDenseEnd
                    = std::clamp(tspFogGuide + tspFogMargin, 900.f, mViewDistance);
                tspFogTargetEnd = std::min(tspFogTargetEnd, tspDenseEnd);
            }

            if (!tspPercentileFogWasActive || !std::isfinite(tspPercentileFogAppliedEnd)
                || tspPercentileFogAppliedEnd <= 0.f)
                tspPercentileFogAppliedEnd = tspFogTargetEnd;

            if (tspFogTargetEnd < tspPercentileFogAppliedEnd)
            {
                // Inward: immediate. Hide newly uncertain/empty curtain space now.
                tspPercentileFogAppliedEnd = tspFogTargetEnd;
            }
            else
            {
                // Outward: give geometry time to populate behind retreating fog.
                constexpr float tspFogReleaseSpeed = 1200.f;
                tspPercentileFogAppliedEnd
                    = std::min(tspFogTargetEnd, tspPercentileFogAppliedEnd + tspFogReleaseSpeed * dt);
            }

            tspPercentileFogWasActive = true;

            if (tspPercentileFogAppliedEnd < fogEnd)
            {
                fogEnd = tspPercentileFogAppliedEnd;
                const float tspDenseStart = std::max(0.f, fogEnd * 0.25f);
                if (!std::isfinite(fogStart) || fogStart < 0.f)
                    fogStart = 0.f;
                fogStart = std::min(fogStart, tspDenseStart);
            }
        }
        else
        {
            tspPercentileFogWasActive = false;
            tspPercentileFogAppliedEnd = 0.f;
        }

"""

if HMARK not in rt:
    old_marker = "        // TSP_INTERIOR_VISGRID_051_V2_FOGFOLLOW\n"
    state_anchor = "        mStateUpdater->setFogStart(fogStart);\n"
    if old_marker in rt:
        start = rt.index(old_marker)
        end = rt.find(state_anchor, start)
        if end < 0:
            raise RuntimeError("render: could not find state updater after V2 fog block")
        rt = rt[:start] + v3_block + rt[end:]
    else:
        fog_anchor = """        float fogStart = mFog->getFogStart(isUnderwater);
        float fogEnd = mFog->getFogEnd(isUnderwater);
        osg::Vec4f fogColor = mFog->getFogColor(isUnderwater);

"""
        if rt.count(fog_anchor) != 1:
            raise RuntimeError(f"render fog variable anchor count={rt.count(fog_anchor)}")
        rt = rt.replace(fog_anchor, fog_anchor + v3_block, 1)
    changed = True

if "getInteriorVisibilityFogGuide" not in ht:
    raise RuntimeError("hpp postcondition failed")
for needle in ("sFogGuide", "tspFogDepths", "getInteriorVisibilityFogGuide",
               "TSP_INTERIOR_VISGRID_051_V3_PERCENTILE_FOG"):
    if needle not in ct:
        raise RuntimeError("cpp postcondition missing " + needle)
if HMARK not in rt:
    raise RuntimeError("render V3 fog marker missing")
if "TSP_INTERIOR_VISGRID_051_V2_FOGFOLLOW" in rt:
    raise RuntimeError("old V2 fog-follow block survived; refusing mixed fog logic")

if changed:
    hpp.write_text(ht)
    cpp.write_text(ct)
    rmgr.write_text(rt)
    print("PASS: V10 C++ source patch applied")
else:
    print("PASS: V10 C++ source already present; no edits needed")
PY_V10_PATCH
SOURCE_EDITED=1

docker exec "$C" bash -lc "
set -euo pipefail
grep -Fq 'getInteriorVisibilityFogGuide' '$HPP'
grep -Fq 'sFogGuide' '$CPP'
grep -Fq 'tspFogDepths' '$CPP'
grep -Fq 'TSP_INTERIOR_VISGRID_051_V3_PERCENTILE_FOG' '$CPP'
grep -Fq 'TSP_INTERIOR_VISGRID_051_V3_PERCENTILE_FOG' '$RMGR'
if grep -Fq 'TSP_INTERIOR_VISGRID_051_V2_FOGFOLLOW' '$RMGR'; then
    echo 'ERROR: old V2 fog block survived.'
    exit 1
fi
"
echo "PASS: exact source postconditions."

echo
echo "===== 5/10 INCREMENTAL REBUILD + REAL BINARY VERIFY ====="
PRE_SHA="$(docker exec "$C" bash -lc "test -f '$OPENMW_BIN' && sha256sum '$OPENMW_BIN' | awk '{print \$1}' || true")"
echo "Pre-build SHA: ${PRE_SHA:-none}"
set +e
docker exec "$C" bash -lc "set -o pipefail; cmake --build '$BUILD' --target openmw -- -j4" 2>&1 | tee "$PKG/build.log"
BUILD_RC=${PIPESTATUS[0]}
set -e
[ "$BUILD_RC" -eq 0 ] || exit "$BUILD_RC"

if ! docker exec "$C" grep -a -q 'TSP_INTERIOR_VISGRID_051_V3_PERCENTILE_FOG' "$OPENMW_BIN"; then
    echo "Marker missing after incremental build; forcing affected objects + relink."
    docker exec "$C" bash -lc "
        set -euo pipefail
        find '$BUILD' -type f \( -name 'interiorvisibility.cpp.o' -o -name 'renderingmanager.cpp.o' \) -print -delete
        rm -f '$OPENMW_BIN' '$BUILD/apps/openmw/openmw'
    "
    set +e
    docker exec "$C" bash -lc "set -o pipefail; cmake --build '$BUILD' --target openmw -- -j4" 2>&1 | tee -a "$PKG/build.log"
    BUILD_RC=${PIPESTATUS[0]}
    set -e
    [ "$BUILD_RC" -eq 0 ] || exit "$BUILD_RC"
fi

docker exec "$C" bash -lc "
set -euo pipefail
test -x '$OPENMW_BIN'
readelf -h '$OPENMW_BIN' | grep -E 'Class:|Machine:|Type:'
readelf -h '$OPENMW_BIN' | grep -q AArch64
grep -a -q 'TSP_INTERIOR_VISGRID_051_V1' '$OPENMW_BIN'
grep -a -q 'TSP_INTERIOR_VISGRID_051_V3_PERCENTILE_FOG' '$OPENMW_BIN'
CM='$SRC/apps/openmw/mwinput/controllermanager.cpp'
if grep -Fq 'TSP_MOUSE_CURSOR_CLEAR_051_V60' \"\$CM\"; then grep -a -q 'TSP_MOUSE_CURSOR_CLEAR_051_V60' '$OPENMW_BIN'; fi
if grep -Fq 'TSP_MOUSE_MENU_OFF_051_V59' \"\$CM\"; then grep -a -q 'TSP_MOUSE_MENU_OFF_051_V59' '$OPENMW_BIN'; fi
grep -a -q 'r3=force-text-reset' '$OPENMW_BIN'
grep -a -q 'tx_cursor.dds' '$OPENMW_BIN'
echo 'PASS: AArch64 + VISGRID V1 + percentile fog V3 + controller invariants.'
sha256sum '$OPENMW_BIN'
"
POST_SHA="$(docker exec "$C" sha256sum "$OPENMW_BIN" | awk '{print $1}')"
echo "Post-build SHA: $POST_SHA"
docker cp "$C:$OPENMW_BIN" "$PKG/openmw-0.51"
docker cp "$C:$HPP" "$PKG/patched-source/interiorvisibility.hpp"
docker cp "$C:$CPP" "$PKG/patched-source/interiorvisibility.cpp"
docker cp "$C:$RMGR" "$PKG/patched-source/renderingmanager.cpp"
chmod 755 "$PKG/openmw-0.51"
SOURCE_RESTORE_ON_ERROR=0
echo "PASS: verified binary packaged; source rollback disarmed."

echo
echo "===== 6/10 WRITE EXACT V10 SENSOR ====="
cat > "$PKG/sensors/visgrid-v10.lua" <<'EOF_TSP_V10_SENSOR'
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
local DEEP_MISS_LIMIT = 2          -- consecutive EXACT witness re-check failures to retire
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
local VD_FOLLOW = false             -- drive the far plane down to the room; the
                                   -- engine fog-follow patch turns the cut
                                   -- into an exterior-style fog wall
local VD_MARGIN_FRAC = 0.22        -- margin above the deepest published tile
local VD_MARGIN_MIN = 600.0        -- (also covers curtain padding + object radius)
local VD_FLOOR = 1200.0            -- never command less than this
local VD_FALL_RATE = 1600.0        -- units/s the far plane may creep IN
                                   -- (rises are instant - correctness)
local VD_WARMUP = 3.0              -- seconds after enter/load with ZERO writes
local VD_UPDATE_PERIOD = 0.5       -- steady state: at most one write per this
local VD_SEND_EPS = 150.0          -- and only for a move at least this big

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
    print('[TSP_VISGRID_V10] engine visibility bridge absent - sensor idle (stock build?)')
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
local binDeepAge = {}
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

-- V9 fog-follow state (one table: the main chunk is near Lua's 200-local cap)
--   vdState.pubMax  deepest tile published this frame
--   cmd     far plane we are currently commanding
--   sent    last value actually written to the engine
--   base    cached settings view distance (read once on enter)
--   elapsed time since the last engine write
--   sends   writes since last status print (diagnostic)
--   saved   fallback restore value (getBaseViewDistance preferred)
local vdState = { pubMax = 0.0, cmd = nil, sent = nil, sentEff = nil,
    base = nil, elapsed = 0.0, sends = 0, saved = nil }
local justLoaded = true       -- first frame after chunk-load/onInit/onLoad
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
                print('[TSP_VISGRID_V10] castRay has no hitNormal - plane inference off')
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
    if casts < budget then
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


local planeById = {}   -- transport-time scratch: plane id -> plane
local function transportTranslation(mx, my, mz, moveDist, ex, ey, ez)
    if moveDist <= 0.0 then
        for i = 1, #knownList do
            local j = knownList[i]
            binAge[j] = (binAge[j] or 0) + 1
            if binDeepVal[j] ~= nil then binDeepAge[j] = (binDeepAge[j] or 0) + 1 end
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
                    if denom < -0.15 then
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
    print('[TSP_VISGRID_V10] no readable door state - door portals off')
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
            '[TSP_VISGRID_V10] warm start from session cache: %d bins, %d planes (entry delta %.0f)',
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
        '[TSP_VISGRID_V10] min=%.0f mean=%.0f max=%.0f lt1k=%d lt2k=%d reject=%.1f%% known=%d cand=%d deep=%d planes=%d fill=%d warm=%d doorEv=%d grace=%d budget=%d cast_attempts=%d cast_ok=%d hits=%d misses=%d dir_fail=%d len_fail=%d cast_fail=%d opens=%d closes=%d fans=%d predict=%d',
        minD, sum / (COLS * ROWS), maxD, under1k, under2k, reject,
        #knownList, cand, deep,
        #planes, fillCount, cacheWasWarm and 1 or 0, doorEvents, doorGraceCount,
        budget,
        castAttempts, castOK, hitCount, missCount,
        dirFail, lenFail, castFail,
        farConfirms, nearConfirms, openingEvents, predictCasts)
        .. string.format(' pref=%d vd=%.0f vdcmd=%.0f vdtx=%d fogq=%.0f',
            planeRefresh, vdNow, vdState.cmd or -1, vdState.sends, fogGuide))
    if firstDirError ~= nil then
        print('[TSP_VISGRID_V10] first_dir_error=' .. firstDirError)
    end
    if firstCastError ~= nil then
        print('[TSP_VISGRID_V10] first_cast_error=' .. firstCastError)
    end
    resetDiagnostics()
end

local function restoreViewDistance()
    local okB, base = pcall(camera.getBaseViewDistance)
    if okB and base ~= nil and base > 0 then
        pcall(camera.setViewDistance, base)
    elseif vdState.saved ~= nil then
        pcall(camera.setViewDistance, vdState.saved)
    end
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
        print('[TSP_VISGRID_V10] disarm (' .. tostring(reason) .. ') -> grid off, view distance restored')
    end
    gridMaybeArmed = false
end

local function enterInterior(cellName, ex, ey, ez)
    -- bank the outgoing cell's learned panorama first (B)
    if inInterior and lastCellName ~= nil and lastEx ~= nil then
        cacheSave(lastCellName, lastEx, lastEy, lastEz)
    end
    if not inInterior then
        -- coming from outside our control: remember the real far plane
        local okVD, vd = pcall(camera.getViewDistance)
        if okVD and vd ~= nil and vd > 0 then vdState.saved = vd end
    end
    if vdState.base == nil then
        -- settings value; read once here so the frame loop never touches
        -- this binding (part of the engine-write discipline)
        local okB, base = pcall(camera.getBaseViewDistance)
        if okB and base ~= nil and base > 0 then vdState.base = base end
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
    print('[TSP_VISGRID_V10] enter interior "' .. tostring(cellName)
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
    print('[TSP_VISGRID_V10] exit interior -> grid off, view distance restored')
end

local function onFrame(dt)
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
        if inInterior then
            exitInterior()
        elseif gridMaybeArmed then
            safeDisarm('exterior-frame')
        end
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
        print('[TSP_VISGRID_V10] reset reason=cell-change')
    else
        local mx, my, mz = ex - (lastEx or ex), ey - (lastEy or ey), ez - (lastEz or ez)
        moveDist = sqrt(mx * mx + my * my + mz * mz)
        if moveDist > TELEPORT_RESET_DIST and interiorElapsed > LOAD_GRACE_SECONDS then
            enterInterior(cellName, ex, ey, ez)
            print('[TSP_VISGRID_V10] reset reason=teleport')
            moveDist = 0.0
        else
            transportTranslation(mx, my, mz, moveDist, ex, ey, ez)
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
    if VD_FOLLOW then
        vdState.elapsed = vdState.elapsed + dt
        local target = vdState.pubMax + max(vdState.pubMax * VD_MARGIN_FRAC, VD_MARGIN_MIN)
        if target < VD_FLOOR then target = VD_FLOOR end
        -- never push the far plane past what the player runs outside (open /
        -- unknown tiles publish OPEN_DEPTH; that must not RAISE the fog)
        local ceilVD = vdState.base or vdState.saved
        if ceilVD ~= nil and target > ceilVD then target = ceilVD end
        if vdState.cmd == nil then
            local okVD, vd = pcall(camera.getViewDistance)
            vdState.cmd = (okVD and vd ~= nil) and vd or target
        end
        if target >= vdState.cmd then
            vdState.cmd = target                          -- rises are instant
        else
            vdState.cmd = max(target, vdState.cmd - VD_FALL_RATE * dt)  -- falls slew (fog creeps in)
        end
        -- Engine-write discipline (see config comment). The engine's own
        -- farFloor clamp still guards every value we do send; the only write
        -- allowed past the rate limit is a rise the curtain needs NOW, and
        -- nothing at all is written during the post-enter warmup window.
        -- needRise compares against sentEff - what the engine actually holds
        -- after its farFloor clamp of our last write - not the raw value we
        -- sent, otherwise an OPEN tile above the base-vd ceiling would read
        -- as "needs a rise" forever and write every frame again.
        if interiorElapsed >= VD_WARMUP then
            local needRise = vdState.sentEff ~= nil and vdState.pubMax > vdState.sentEff + 1.0
            if needRise
                or ((vdState.sent == nil or abs(vdState.cmd - vdState.sent) > VD_SEND_EPS)
                    and vdState.elapsed >= VD_UPDATE_PERIOD) then
                if pcall(camera.setViewDistance, vdState.cmd) then
                    vdState.sent = vdState.cmd
                    vdState.sentEff = max(vdState.cmd, vdState.pubMax)
                    vdState.elapsed = 0.0
                    vdState.sends = vdState.sends + 1
                end
            end
        end
    else
        -- V10: the sensor does not drive projection distance at all. The C++
        -- V1 bridge already prevents any competing controller from shrinking
        -- the projection below the deepest published tile. Fog masking is now
        -- independent of the global far plane, so extra projection writes are
        -- unnecessary overhead and were implicated in the V9 load crash.
        projCheckElapsed = 0.0
    end

    if statusElapsed >= PRINT_PERIOD then
        statusElapsed = statusElapsed - PRINT_PERIOD
        printStatus(budget)
    end
end

local function onInit()
    resetRuntimeState()
    print('[TSP_VISGRID_V10] onInit -> runtime state initialized')
end

local function onLoad(_savedData, _initData)
    resetRuntimeState()
    print('[TSP_VISGRID_V10] onLoad -> runtime state initialized')
end

return {
    engineHandlers = {
        onInit = onInit,
        onLoad = onLoad,
        onFrame = onFrame,
    },
}

EOF_TSP_V10_SENSOR
ACTUAL_MD5="$(md5sum "$PKG/sensors/visgrid-v10.lua" | awk '{print $1}')"
[ "$ACTUAL_MD5" = "$V10_MD5" ] || { echo "ERROR: V10 sensor MD5 mismatch."; exit 1; }
grep -Fq 'TSP_INTERIOR_VISGRID_LUA_V10' "$PKG/sensors/visgrid-v10.lua"
grep -Fq 'DEEP_VERIFY_AGE' "$PKG/sensors/visgrid-v10.lua"
grep -Fq 'VD_FOLLOW = false' "$PKG/sensors/visgrid-v10.lua"
grep -Fq 'fogq=' "$PKG/sensors/visgrid-v10.lua"
echo "PASS: V10 sensor MD5=$ACTUAL_MD5"

echo
echo "===== 7/10 TRANSACTIONAL DEVICE DEPLOY ====="
DEVICE_DEPLOY_STARTED=1
scp -q "$PKG/openmw-0.51" "$DEV:/tmp/openmw-0.51-visgrid-v10"
scp -q "$PKG/sensors/visgrid-v10.lua" "$DEV:/tmp/visgrid-v10.lua"
ssh "$DEV" "
set -e
test -s /tmp/openmw-0.51-visgrid-v10
test -s /tmp/visgrid-v10.lua
grep -a -q 'TSP_INTERIOR_VISGRID_051_V1' /tmp/openmw-0.51-visgrid-v10
grep -a -q 'TSP_INTERIOR_VISGRID_051_V3_PERCENTILE_FOG' /tmp/openmw-0.51-visgrid-v10
grep -Fq 'TSP_INTERIOR_VISGRID_LUA_V10' /tmp/visgrid-v10.lua

mkdir -p '$MOD/sensors'
cp -p '$LUA' '$MOD/sensors/visgrid-pre-v10.lua'

cp /tmp/openmw-0.51-visgrid-v10 '$BIN.new'
chmod 755 '$BIN.new'
mv -f '$BIN.new' '$BIN'
cp /tmp/visgrid-v10.lua '$MOD/sensors/visgrid-v10.lua'
cp /tmp/visgrid-v10.lua '$LUA.new'
mv -f '$LUA.new' '$LUA'
rm -f /tmp/openmw-0.51-visgrid-v10 /tmp/visgrid-v10.lua
sync
"

echo
echo "===== 8/10 REMOTE SHA + MARKER VERIFY ====="
LOCAL_BIN_SHA="$(sha256sum "$PKG/openmw-0.51" | awk '{print $1}')"
LOCAL_LUA_SHA="$(sha256sum "$PKG/sensors/visgrid-v10.lua" | awk '{print $1}')"
REMOTE_BIN_SHA="$(ssh "$DEV" "sha256sum '$BIN' | awk '{print \$1}'")"
REMOTE_LUA_SHA="$(ssh "$DEV" "sha256sum '$LUA' | awk '{print \$1}'")"
[ "$LOCAL_BIN_SHA" = "$REMOTE_BIN_SHA" ] || { echo "ERROR: binary SHA mismatch."; exit 1; }
[ "$LOCAL_LUA_SHA" = "$REMOTE_LUA_SHA" ] || { echo "ERROR: Lua SHA mismatch."; exit 1; }
ssh "$DEV" "
set -e
grep -a -q 'TSP_INTERIOR_VISGRID_051_V1' '$BIN'
grep -a -q 'TSP_INTERIOR_VISGRID_051_V3_PERCENTILE_FOG' '$BIN'
grep -Fq 'TSP_INTERIOR_VISGRID_LUA_V10' '$LUA'
grep -Fq 'PLAYER: scripts/TSPInteriorVisGrid/visgrid.lua' '$OMW'
"
DEVICE_DEPLOY_STARTED=0
echo "PASS: V10 binary + sensor installed and SHA-verified."

echo
echo "===== 9/10 STABLE LIVE-PRINT / TRACE / ROLLBACK HELPERS ====="
cat > "$TOOLS/pull-visgrid-print.sh" <<'EOF_PULL'
#!/usr/bin/env bash
set -Eeuo pipefail
DEV="${TSP_DEV:-root@192.168.1.25}"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="${1:-$HOME/Downloads/openmw51-visgrid-v10-print-$STAMP.txt}"
{
    echo "=================================================================="
    echo "VISGRID V10 LIVE PRINT"
    echo "=================================================================="
    ssh "$DEV" 'hostname; date'
    echo
    ssh "$DEV" '
        grep -hE \
          "TSP_VISGRID_V10|TSP_INTERIOR_VISGRID_051_V3_PERCENTILE_FOG|TSP_INTERIOR_VISGRID_051_V1|Lua.*error|ERROR.*Lua|segfault|SIGSEGV" \
          /mnt/SDCARD/data/ports/openmw51/config-0.51/openmw.log \
          /mnt/SDCARD/tsp_prog.txt 2>/dev/null | tail -650 || true
    '
    echo
    ssh "$DEV" '
        for f in /mnt/SDCARD/tsp_diag.txt /mnt/SDCARD/tsp_ring.txt /mnt/SDCARD/tsp_state.txt
        do
            if [ -f "$f" ]; then echo "--- $f ---"; tail -220 "$f"; fi
        done
    '
} 2>&1 | tee "$OUT"
echo
echo "Saved: $OUT"
EOF_PULL
chmod +x "$TOOLS/pull-visgrid-print.sh"

cat > "$TOOLS/collect-visgrid-trace.sh" <<'EOF_TRACE'
#!/usr/bin/env bash
set -Eeuo pipefail
DEV="${TSP_DEV:-root@192.168.1.25}"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="${1:-$HOME/Downloads/openmw51-visgrid-v10-trace-$STAMP.txt}"
{
    echo "=================================================================="
    echo "OPENMW INTERIOR VISGRID V10 FULL TRACE"
    echo "=================================================================="
    ssh "$DEV" 'hostname; date'
    echo
    echo "===== VISGRID / FOG / LUA ====="
    ssh "$DEV" '
        grep -hE \
          "TSP_VISGRID_V10|TSP_VISGRID_V9|TSP_INTERIOR_VISGRID_051_V3_PERCENTILE_FOG|TSP_INTERIOR_VISGRID_051_V1|Lua.*error|ERROR.*Lua|segfault|SIGSEGV" \
          /mnt/SDCARD/data/ports/openmw51/config-0.51/openmw.log \
          /mnt/SDCARD/tsp_prog.txt 2>/dev/null | tail -3200 || true
    '
    echo
    echo "===== RENDER / PERFORMANCE ====="
    ssh "$DEV" '
        for f in /mnt/SDCARD/tsp_diag.txt /mnt/SDCARD/tsp_ring.txt /mnt/SDCARD/tsp_state.txt /mnt/SDCARD/data/ports/openmw51/openmw51_perf_latest.txt
        do
            if [ -f "$f" ]; then echo "--- $f ---"; tail -950 "$f"; fi
        done
    '
    echo
    echo "===== INSTALLED STATE ====="
    ssh "$DEV" '
        head -2 /mnt/SDCARD/data/ports/openmw51/mods/TSPInteriorVisGrid/scripts/TSPInteriorVisGrid/visgrid.lua 2>/dev/null || true
        sha256sum \
          /mnt/SDCARD/data/ports/openmw51/bin/openmw-0.51 \
          /mnt/SDCARD/data/ports/openmw51/mods/TSPInteriorVisGrid/TSPInteriorVisGrid.omwscripts \
          /mnt/SDCARD/data/ports/openmw51/mods/TSPInteriorVisGrid/scripts/TSPInteriorVisGrid/visgrid.lua 2>/dev/null || true
    '
} 2>&1 | tee "$OUT"
echo
echo "Trace saved: $OUT"
EOF_TRACE
chmod +x "$TOOLS/collect-visgrid-trace.sh"

cat > "$TOOLS/rollback-visgrid-v10.sh" <<EOF_ROLLBACK
#!/usr/bin/env bash
set -Eeuo pipefail
DEV="\${TSP_DEV:-root@192.168.1.25}"
BIN="$BIN"; LUA="$LUA"; OMW="$OMW"; BK="$REMOTE_BACKUP"
if ssh "\$DEV" 'pidof openmw-0.51 >/dev/null 2>&1 || pidof openmw >/dev/null 2>&1'; then
    echo "ERROR: exit OpenMW before rollback."; exit 1
fi
ssh "\$DEV" "
set -e
test -s '\$BK/openmw-0.51'; test -s '\$BK/visgrid.lua.before-v10'; test -s '\$BK/TSPInteriorVisGrid.omwscripts'
cp -p '\$BK/openmw-0.51' '\$BIN.new'; chmod 755 '\$BIN.new'; mv -f '\$BIN.new' '\$BIN'
cp -p '\$BK/visgrid.lua.before-v10' '\$LUA.new'; mv -f '\$LUA.new' '\$LUA'
cp -p '\$BK/TSPInteriorVisGrid.omwscripts' '\$OMW.new'; mv -f '\$OMW.new' '\$OMW'
sync
test \"\$(sha256sum '\$BIN' | awk '{print \\\$1}')\" = \"\$(sha256sum '\$BK/openmw-0.51' | awk '{print \\\$1}')\"
test \"\$(sha256sum '\$LUA' | awk '{print \\\$1}')\" = \"\$(sha256sum '\$BK/visgrid.lua.before-v10' | awk '{print \\\$1}')\"
test \"\$(sha256sum '\$OMW' | awk '{print \\\$1}')\" = \"\$(sha256sum '\$BK/TSPInteriorVisGrid.omwscripts' | awk '{print \\\$1}')\"
sha256sum '\$BIN' '\$LUA' '\$OMW'
"
echo "Restored exact pre-V10 device state from: $REMOTE_BACKUP"
EOF_ROLLBACK
chmod +x "$TOOLS/rollback-visgrid-v10.sh"

cp -f "$TOOLS/pull-visgrid-print.sh" "$PKG/pull-visgrid-print.sh"
cp -f "$TOOLS/collect-visgrid-trace.sh" "$PKG/collect-visgrid-trace.sh"
cp -f "$TOOLS/rollback-visgrid-v10.sh" "$PKG/rollback-visgrid-v10.sh"
echo "PASS: helpers at $TOOLS"

echo
echo "===== 10/10 README + DONE ====="
cat > "$PKG/README-V10.txt" <<EOF_README
VISGRID V10 — PERSISTENT OPENINGS + DENSE PERCENTILE FOG
========================================================

Engine marker:
  TSP_INTERIOR_VISGRID_051_V3_PERCENTILE_FOG

Sensor marker:
  TSP_INTERIOR_VISGRID_LUA_V10
Sensor MD5:
  $V10_MD5

What changed:
- projection/view distance remains at the real base distance during normal play
- deep doorway/slit witnesses are retired only by exact-subdirection rechecks
- random shallow jitter cannot delete a valid narrow opening
- C++ computes a 75th-percentile fog guide from the published 40-tile curtain
- fog end ~= guide + max(500, guide*0.5), minimum 900
- fog starts at <=25% of fog end
- fog comes inward instantly; recedes at ~1200 units/sec
- no hard Z cap

Synthetic validation only (not a device-runtime claim):
- solid geometry: 0 raw visibility artifacts
- deliberate railing/slit case with percentile fog model: 0 raw artifacts;
  transient holes fall behind fog instead
- normal-play view-distance writes: 0

Test:
1. Caldera slowdown wall
2. move/turn continuously
3. sideways walk along a wall
4. open door into long hall / large room
5. railing / thin opening
6. staircase

Live print while OpenMW is running:
  ~/Downloads/visgrid-tools/pull-visgrid-print.sh

Full trace:
  ~/Downloads/visgrid-tools/collect-visgrid-trace.sh

Rollback with OpenMW closed:
  ~/Downloads/visgrid-tools/rollback-visgrid-v10.sh

Device backup:
  $REMOTE_BACKUP
EOF_README

echo "=================================================================="
echo "VISGRID V10 INSTALLED AND VERIFIED"
echo "=================================================================="
echo "Package: $PKG"
echo
echo "WHILE OPENMW IS STILL RUNNING AFTER THE TEST:"
echo "  ~/Downloads/visgrid-tools/pull-visgrid-print.sh"
echo
echo "FULL TRACE:"
echo "  ~/Downloads/visgrid-tools/collect-visgrid-trace.sh"
echo
echo "ROLLBACK:"
echo "  ~/Downloads/visgrid-tools/rollback-visgrid-v10.sh"
echo
if [ -t 0 ]; then read -r -p "Press Enter to return to the shell... " _ || true; fi
