#!/usr/bin/env bash
# apply_visgrid_v12_gapfog.sh
#
# ONE build. Three changes, all in the engine.
#
# 1. HARDEN THE LUA BINDING  (TSP_INTERIOR_VISGRID_051_V4_NOTHROW)
#    camerabindings.cpp:113 does:
#        throw std::runtime_error("Invalid interior visibility grid dimensions");
#    from inside a sol2 lambda that LuaJIT calls. Throwing a C++ exception
#    back through LuaJIT's VM frames is not supported on aarch64 - LuaJIT uses
#    its own unwinder and external unwinding through its frames is exactly the
#    kind of thing that leaves a corrupt Lua stack behind. Line 118 then does
#        depths.push_back(values.get<float>(i));
#    with no type check at all: a nil or non-numeric element is read
#    unchecked. Both are replaced with "clear the grid and return" - a bad
#    call now degrades to "render everything", never to a damaged VM.
#
# 2. GAP FOG  (TSP_INTERIOR_VISGRID_051_V4_CULLFOG)
#    The V3 fog is driven by the 75th-percentile PUBLISHED depth, which has
#    nothing to do with whether anything was actually hidden. On the 16:50 run
#    fogq bottomed at 187, so fog ran 225 -> 900 units in a room the scan
#    measures at 2828 x 2320 x 1411. Two thirds of the room sat in full fog
#    for nothing.
#    The culler already computes nearestSurface for every object it rejects.
#    The minimum of those over a frame IS the nearest distance at which a hole
#    can appear; everything closer was drawn. So fog is now pinned to that:
#      - nothing culled this frame -> fog is left exactly as authored
#      - something culled at D     -> fog ends just short of D, starts at 60%
#    Fog can no longer sit in front of geometry that is being drawn.
#
# 3. RUNTIME KNOBS - so the next question needs a launch, not a build:
#      TSP_VISGRID_FOG=0                  no fog override at all
#      TSP_VISGRID_FOG_MODE=percentile    the old V3 behaviour
#      TSP_VISGRID_FOG_MODE=cullnear      the new one (default)
#      TSP_VISGRID_FOG_MARGIN=<units>     gap margin, default 300
#
# Also runs a read-only LuaJIT ABI check: the binary is compiled against the
# container's LuaJIT but loads the device's bundled libluajit-5.1.so.2 at
# runtime. OpenMW needs a GC64 LuaJIT for its custom allocator (see
# cmake/CheckLuaCustomAllocator.cmake). If those two differ, that is a far
# better crash explanation than anything in the sensor.
set -Eeuo pipefail

if [ -f "$HOME/Downloads/visgrid-tools/device.env" ]; then
    # shellcheck disable=SC1091
    . "$HOME/Downloads/visgrid-tools/device.env" || true
fi
if [ -n "${TSP_IP:-}" ]; then DEV="root@$TSP_IP"; else DEV="${TSP_DEV:-root@192.168.1.25}"; fi
C="${TSP_BUILDER:-openmw_builder}"
STAMP="$(date +%Y%m%d-%H%M%S)"

ROOT="/mnt/SDCARD/data/ports/openmw51"
BIN="$ROOT/bin/openmw-0.51"
MOD="$ROOT/mods/TSPInteriorVisGrid"
LUA="$MOD/scripts/TSPInteriorVisGrid/visgrid.lua"
SRC="/root/openmw-0.51-tsp-src"
BUILD="/root/openmw-0.51-tsp-build"
OPENMW_BIN="$BUILD/openmw"
IVH="$SRC/apps/openmw/mwrender/interiorvisibility.hpp"
IVC="$SRC/apps/openmw/mwrender/interiorvisibility.cpp"
CBC="$SRC/apps/openmw/mwlua/camerabindings.cpp"
RMGR="$SRC/apps/openmw/mwrender/renderingmanager.cpp"

PKG="$HOME/Downloads/openmw51-visgrid-v12-gapfog-$STAMP"
TOOLS="$HOME/Downloads/visgrid-tools"
LOG="$PKG/install.log"
mkdir -p "$PKG/source-backup" "$PKG/device-backup" "$TOOLS"

SOURCE_RESTORE=0
DEPLOY_STARTED=0
REMOTE_BACKUP="$ROOT/backups/visgrid-v12-gapfog-$STAMP"

fail() {
    local rc="${1:-1}" line="${2:-unknown}" cmd="${3:-unknown}"
    trap - ERR
    set +e
    {
        echo
        echo "=================================================================="
        echo "VISGRID V12 STOPPED SAFELY"
        echo "=================================================================="
        echo "Date: $(date)"; echo "Exit code: $rc"; echo "Line: $line"; echo "Command: $cmd"
        echo
        if [ "$SOURCE_RESTORE" = "1" ]; then
            echo "----- RESTORING CONTAINER SOURCE -----"
            docker exec -i "$C" bash -lc "
                set -euo pipefail
                for f in interiorvisibility.hpp interiorvisibility.cpp renderingmanager.cpp; do
                    cp -p '$PKG_REMOTE/\$f' '$SRC/apps/openmw/mwrender/\$f'
                done
                cp -p '$PKG_REMOTE/camerabindings.cpp' '$SRC/apps/openmw/mwlua/camerabindings.cpp'
                find '$BUILD' -type f -name 'interiorvisibility.cpp.o' -delete 2>/dev/null || true
                find '$BUILD' -type f -name 'camerabindings.cpp.o' -delete 2>/dev/null || true
                find '$BUILD' -type f -name 'renderingmanager.cpp.o' -delete 2>/dev/null || true
                echo 'PASS: source restored'
            " && echo "PASS: container source restored." || echo "WARNING: restore FAILED; backups in $PKG/source-backup"
        fi
        if [ "$DEPLOY_STARTED" = "1" ]; then
            echo "----- RESTORING DEVICE BINARY -----"
            ssh "$DEV" "
                set -e
                test -s '$REMOTE_BACKUP/openmw-0.51'
                cp -p '$REMOTE_BACKUP/openmw-0.51' '$BIN.restore'
                chmod 755 '$BIN.restore'
                mv -f '$BIN.restore' '$BIN'
                sync
                sha256sum '$BIN'
            " && echo "PASS: device binary restored." || echo "WARNING: device restore FAILED; backup at $REMOTE_BACKUP"
        fi
        echo
        [ -f "$LOG" ] && { echo "----- install.log tail -----"; tail -200 "$LOG"; }
        echo
        echo "Preserved at: $PKG"
    } | tee "$PKG/STOPPED_ERROR.txt"
    exit "$rc"
}
trap 'fail "$?" "$LINENO" "$BASH_COMMAND"' ERR
exec > >(tee "$LOG") 2>&1

echo "=================================================================="
echo "OPENMW 0.51 TSP - VISGRID V12: HARDENED BINDING + GAP FOG"
echo "=================================================================="
echo "Device : $DEV"
echo

command -v docker >/dev/null
if [ "$(docker inspect -f '{{.State.Running}}' "$C" 2>/dev/null)" != "true" ]; then
    docker start "$C" >/dev/null
fi

echo "===== 1/9 PRECONDITIONS ====="
if ssh "$DEV" 'pidof openmw-0.51 >/dev/null 2>&1 || pidof openmw >/dev/null 2>&1'; then
    echo "ERROR: OpenMW is running. Exit it normally, then rerun."
    exit 20
fi
docker exec -i "$C" bash -lc "
set -euo pipefail
test -f '$IVH'; test -f '$IVC'; test -f '$CBC'; test -f '$RMGR'
grep -Fq 'TSP_INTERIOR_VISGRID_051_V1' '$RMGR'
grep -Fq 'TSP_INTERIOR_VISGRID_051_V3_PERCENTILE_FOG' '$RMGR'
grep -Fq 'setInteriorVisibilityGrid' '$CBC'
echo 'PASS: container source is in the expected state.'
"

echo
echo "===== 2/9 LUAJIT ABI CHECK (READ-ONLY) ====="
echo "The binary is COMPILED against the container's LuaJIT and LOADS the"
echo "device's bundled one. OpenMW requires a GC64 LuaJIT for its custom"
echo "allocator; a mismatch here corrupts the VM exactly the way we are seeing."
echo
echo "-- container --"
docker exec -i "$C" bash -lc "
for p in /usr/lib/aarch64-linux-gnu/libluajit-5.1.so.2 /usr/lib/libluajit-5.1.so.2 /usr/local/lib/libluajit-5.1.so.2; do
    [ -e \"\$p\" ] && { ls -lL \"\$p\"; sha256sum \"\$(readlink -f \"\$p\")\"; }
done
echo -n 'ldd of the built binary: '
ldd '$OPENMW_BIN' 2>/dev/null | grep -i luajit || echo '(not linked or binary absent)'
" || true
echo "-- device --"
ssh "$DEV" "
ls -lL '$ROOT/lib/libluajit-5.1.so.2' 2>/dev/null || echo '  no bundled libluajit'
sha256sum \"\$(readlink -f '$ROOT/lib/libluajit-5.1.so.2')\" 2>/dev/null || true
" || true
echo "(compare the two sha256 values above - if they differ, that is a lead)"

echo
echo "===== 3/9 BACK UP SOURCE (CONTAINER + VM) ====="
PKG_REMOTE="/root/tsp-v12-source-backup-$STAMP"
docker exec -i "$C" bash -lc "
set -euo pipefail
mkdir -p '$PKG_REMOTE'
cp -p '$IVH' '$IVC' '$RMGR' '$PKG_REMOTE/'
cp -p '$CBC' '$PKG_REMOTE/'
cd '$PKG_REMOTE' && sha256sum * > SHA256SUMS.txt && cat SHA256SUMS.txt
"
for f in interiorvisibility.hpp interiorvisibility.cpp renderingmanager.cpp camerabindings.cpp; do
    docker exec -i "$C" cat "$PKG_REMOTE/$f" > "$PKG/source-backup/$f"
    [ -s "$PKG/source-backup/$f" ]
done
echo "PASS: source backed up in the container and on this VM."
SOURCE_RESTORE=1

echo
echo "===== 4/9 PATCH THE SOURCE ====="
docker exec -i "$C" python3 - "$IVH" "$IVC" "$CBC" "$RMGR" <<'PYPATCH'
import sys, re

ivh, ivc, cbc, rmgr = sys.argv[1:5]

def read(p):  return open(p, encoding='utf-8', errors='surrogateescape').read()
def write(p, s): open(p, 'w', encoding='utf-8', errors='surrogateescape').write(s)

def sub(s, old, new, label, path):
    n = s.count(old)
    if n != 1:
        raise SystemExit("ERROR: %s anchor count=%d in %s" % (label, n, path))
    return s.replace(old, new, 1)

def add_include(s, inc, path):
    if inc in s:
        return s
    m = re.search(r'^#include .*$', s, re.M)
    if not m:
        raise SystemExit("ERROR: no #include line found in " + path)
    return s[:m.end()] + "\n" + inc + s[m.end():]

MARK = "TSP_INTERIOR_VISGRID_051_V4"

# ---------------------------------------------------------------- hpp
h = read(ivh)
if MARK not in h:
    h = sub(h,
        "    // TSP_INTERIOR_VISGRID_051_V3_PERCENTILE_FOG\n"
        "    float getInteriorVisibilityFogGuide();\n",
        "    // TSP_INTERIOR_VISGRID_051_V3_PERCENTILE_FOG\n"
        "    float getInteriorVisibilityFogGuide();\n"
        "    // TSP_INTERIOR_VISGRID_051_V4_CULLFOG\n"
        "    // Nearest surface among objects the curtain actually rejected since\n"
        "    // the last call; reads and resets. 0 means nothing was rejected.\n"
        "    float takeInteriorVisibilityCullNear();\n",
        "hpp/decl", ivh)
    write(ivh, h)
    print("PASS: interiorvisibility.hpp - takeInteriorVisibilityCullNear declared")
else:
    print("NOTE: hpp already patched")

# ---------------------------------------------------------------- cpp
c = read(ivc)
if MARK not in c:
    c = sub(c,
        "        std::atomic<float> sFogGuide{ 0.f };\n",
        "        std::atomic<float> sFogGuide{ 0.f };\n"
        "        // TSP_INTERIOR_VISGRID_051_V4_CULLFOG\n"
        "        std::atomic<float> sCullNear{ 0.f };\n",
        "cpp/atomic", ivc)

    c = sub(c,
        "        sFogGuide.store(0.f, std::memory_order_relaxed);\n",
        "        sFogGuide.store(0.f, std::memory_order_relaxed);\n"
        "        sCullNear.store(0.f, std::memory_order_relaxed);\n",
        "cpp/clear", ivc)

    c = sub(c,
        "    float getInteriorVisibilityFogGuide()\n"
        "    {\n"
        "        return sFogGuide.load(std::memory_order_relaxed);\n"
        "    }\n",
        "    float getInteriorVisibilityFogGuide()\n"
        "    {\n"
        "        return sFogGuide.load(std::memory_order_relaxed);\n"
        "    }\n"
        "\n"
        "    // TSP_INTERIOR_VISGRID_051_V4_CULLFOG\n"
        "    float takeInteriorVisibilityCullNear()\n"
        "    {\n"
        "        return sCullNear.exchange(0.f, std::memory_order_relaxed);\n"
        "    }\n",
        "cpp/getter", ivc)

    c = sub(c,
        "            sCulled.fetch_add(1,std::memory_order_relaxed);\n"
        "            return;\n",
        "            sCulled.fetch_add(1,std::memory_order_relaxed);\n"
        "            // TSP_INTERIOR_VISGRID_051_V4_CULLFOG\n"
        "            // Remember the NEAREST rejected surface this frame. That is\n"
        "            // the closest distance at which a hole can appear, so it is\n"
        "            // the only place fog is needed.\n"
        "            {\n"
        "                const float tspNear = static_cast<float>(nearestSurface);\n"
        "                float tspPrev = sCullNear.load(std::memory_order_relaxed);\n"
        "                while ((tspPrev <= 0.f || tspNear < tspPrev)\n"
        "                    && !sCullNear.compare_exchange_weak(\n"
        "                        tspPrev, tspNear, std::memory_order_relaxed))\n"
        "                {\n"
        "                }\n"
        "            }\n"
        "            return;\n",
        "cpp/cullnear", ivc)
    write(ivc, c)
    print("PASS: interiorvisibility.cpp - nearest-culled tracking added")
else:
    print("NOTE: interiorvisibility.cpp already patched")

# ---------------------------------------------------------------- bindings
b = read(cbc)
if "TSP_INTERIOR_VISGRID_051_V4_NOTHROW" not in b:
    old = """        api["setInteriorVisibilityGrid"]
            = [](int cols, int rows, const sol::table& values, const FiniteFloat padding) {
                  const int count = cols * rows;
                  if (cols <= 0 || rows <= 0 || count <= 0 || count > MWRender::sInteriorVisibilityMaxTiles)
                      throw std::runtime_error("Invalid interior visibility grid dimensions");

                  std::vector<float> depths;
                  depths.reserve(static_cast<std::size_t>(count));
                  for (int i = 1; i <= count; ++i)
                      depths.push_back(values.get<float>(i));

                  MWRender::setInteriorVisibilityGrid(
                      cols, rows, std::span<const float>(depths.data(), depths.size()), padding);
              };
"""
    new = """        api["setInteriorVisibilityGrid"]
            = [](int cols, int rows, const sol::table& values, const FiniteFloat padding) {
                  // TSP_INTERIOR_VISGRID_051_V4_NOTHROW
                  // Never throw across the Lua boundary. LuaJIT on aarch64 does
                  // not support unwinding a C++ exception through its VM frames,
                  // and every element is now type-checked instead of read raw.
                  // Bad input degrades to "render everything", never to a
                  // damaged VM.
                  const int count = cols * rows;
                  if (cols <= 0 || rows <= 0 || count <= 0
                      || count > MWRender::sInteriorVisibilityMaxTiles)
                  {
                      MWRender::clearInteriorVisibilityGrid();
                      return;
                  }

                  std::vector<float> depths;
                  depths.reserve(static_cast<std::size_t>(count));
                  for (int i = 1; i <= count; ++i)
                  {
                      const sol::optional<float> tspV = values.get<sol::optional<float>>(i);
                      if (!tspV || !std::isfinite(*tspV) || *tspV <= 0.f)
                      {
                          MWRender::clearInteriorVisibilityGrid();
                          return;
                      }
                      depths.push_back(*tspV);
                  }

                  MWRender::setInteriorVisibilityGrid(
                      cols, rows, std::span<const float>(depths.data(), depths.size()), padding);
              };
"""
    b = sub(b, old, new, "bindings/setgrid", cbc)
    b = add_include(b, "#include <cmath>", cbc)
    write(cbc, b)
    print("PASS: camerabindings.cpp - throw removed, elements type-checked")
else:
    print("NOTE: camerabindings.cpp already patched")

# ---------------------------------------------------------------- fog
r = read(rmgr)
if "TSP_INTERIOR_VISGRID_051_V4_CULLFOG" not in r:
    r = sub(r,
        "        static bool tspPercentileFogLogged = false;\n"
        "        static bool tspPercentileFogWasActive = false;\n"
        "        static float tspPercentileFogAppliedEnd = 0.f;\n",
        "        static bool tspPercentileFogLogged = false;\n"
        "        static bool tspPercentileFogWasActive = false;\n"
        "        static float tspPercentileFogAppliedEnd = 0.f;\n"
        "\n"
        "        // TSP_INTERIOR_VISGRID_051_V4_CULLFOG - runtime knobs, read once.\n"
        "        //   TSP_VISGRID_FOG=0                no fog override at all\n"
        "        //   TSP_VISGRID_FOG_MODE=percentile  the old V3 behaviour\n"
        "        //   TSP_VISGRID_FOG_MODE=cullnear    gap fog (default)\n"
        "        //   TSP_VISGRID_FOG_MARGIN=<units>   gap margin (default 300)\n"
        "        static bool tspFogCfgRead = false;\n"
        "        static bool tspFogEnabled = true;\n"
        "        static bool tspFogPercentile = false;\n"
        "        static float tspFogGapMargin = 300.f;\n"
        "        if (!tspFogCfgRead)\n"
        "        {\n"
        "            tspFogCfgRead = true;\n"
        "            const char* tspEnvOn = std::getenv(\"TSP_VISGRID_FOG\");\n"
        "            if (tspEnvOn != nullptr && tspEnvOn[0] == '0')\n"
        "                tspFogEnabled = false;\n"
        "            const char* tspEnvMode = std::getenv(\"TSP_VISGRID_FOG_MODE\");\n"
        "            if (tspEnvMode != nullptr && std::strcmp(tspEnvMode, \"percentile\") == 0)\n"
        "                tspFogPercentile = true;\n"
        "            const char* tspEnvMargin = std::getenv(\"TSP_VISGRID_FOG_MARGIN\");\n"
        "            if (tspEnvMargin != nullptr)\n"
        "            {\n"
        "                const float tspM = std::strtof(tspEnvMargin, nullptr);\n"
        "                if (std::isfinite(tspM) && tspM >= 0.f)\n"
        "                    tspFogGapMargin = tspM;\n"
        "            }\n"
        "            Log(Debug::Info) << \"TSP_INTERIOR_VISGRID_051_V4_CULLFOG cfg enabled=\"\n"
        "                             << tspFogEnabled << \" mode=\"\n"
        "                             << (tspFogPercentile ? \"percentile\" : \"cullnear\")\n"
        "                             << \" margin=\" << tspFogGapMargin;\n"
        "        }\n",
        "fog/config", rmgr)

    r = sub(r,
        "            const float tspFogGuide = getInteriorVisibilityFogGuide();\n"
        "            const bool tspGuideUsable\n"
        "                = std::isfinite(tspFogGuide) && tspFogGuide > 0.f && tspFogGuide < 3200.f;\n"
        "\n"
        "            float tspFogTargetEnd = std::min(fogEnd, mViewDistance);\n"
        "            if (tspGuideUsable)\n"
        "            {\n"
        "                const float tspFogMargin = std::max(500.f, tspFogGuide * 0.50f);\n"
        "                const float tspDenseEnd\n"
        "                    = std::clamp(tspFogGuide + tspFogMargin, 900.f, mViewDistance);\n"
        "                tspFogTargetEnd = std::min(tspFogTargetEnd, tspDenseEnd);\n"
        "            }\n",
        "            // TSP_INTERIOR_VISGRID_051_V4_CULLFOG\n"
        "            // Always drain the per-frame nearest-culled value, whichever\n"
        "            // mode is active, so it never goes stale.\n"
        "            const float tspCullNear = takeInteriorVisibilityCullNear();\n"
        "\n"
        "            float tspFogTargetEnd = std::min(fogEnd, mViewDistance);\n"
        "\n"
        "            if (!tspFogEnabled)\n"
        "            {\n"
        "                // Fog left exactly as authored - the A/B baseline.\n"
        "            }\n"
        "            else if (tspFogPercentile)\n"
        "            {\n"
        "                const float tspFogGuide = getInteriorVisibilityFogGuide();\n"
        "                const bool tspGuideUsable = std::isfinite(tspFogGuide)\n"
        "                    && tspFogGuide > 0.f && tspFogGuide < 3200.f;\n"
        "                if (tspGuideUsable)\n"
        "                {\n"
        "                    const float tspFogMargin = std::max(500.f, tspFogGuide * 0.50f);\n"
        "                    const float tspDenseEnd\n"
        "                        = std::clamp(tspFogGuide + tspFogMargin, 900.f, mViewDistance);\n"
        "                    tspFogTargetEnd = std::min(tspFogTargetEnd, tspDenseEnd);\n"
        "                }\n"
        "            }\n"
        "            else\n"
        "            {\n"
        "                // Gap fog. The only thing that ever needs hiding is a hole\n"
        "                // where the curtain rejected something. Everything nearer\n"
        "                // than the nearest rejected object was DRAWN, so fog must\n"
        "                // not reach it. Nothing rejected -> fog untouched.\n"
        "                if (std::isfinite(tspCullNear) && tspCullNear > 0.f)\n"
        "                {\n"
        "                    const float tspGapEnd = std::clamp(\n"
        "                        tspCullNear - tspFogGapMargin, 600.f, mViewDistance);\n"
        "                    tspFogTargetEnd = std::min(tspFogTargetEnd, tspGapEnd);\n"
        "                }\n"
        "            }\n",
        "fog/mode", rmgr)

    r = sub(r,
        "                const float tspDenseStart = std::max(0.f, fogEnd * 0.25f);\n",
        "                // Gap fog sits right at the hole, so it needs a thin band,\n"
        "                // not the percentile mode's full-depth curtain.\n"
        "                const float tspDenseStart\n"
        "                    = std::max(0.f, fogEnd * (tspFogPercentile ? 0.25f : 0.60f));\n",
        "fog/start", rmgr)

    for inc in ("#include <cmath>", "#include <cstdlib>", "#include <cstring>"):
        r = add_include(r, inc, rmgr)
    write(rmgr, r)
    print("PASS: renderingmanager.cpp - gap fog + env knobs")
else:
    print("NOTE: renderingmanager.cpp already patched")

print("PASS: all source patches applied.")
PYPATCH

docker exec -i "$C" bash -lc "
set -euo pipefail
grep -Fq 'takeInteriorVisibilityCullNear' '$IVH'
grep -Fq 'takeInteriorVisibilityCullNear' '$IVC'
grep -Fq 'TSP_INTERIOR_VISGRID_051_V4_NOTHROW' '$CBC'
grep -Fq 'TSP_INTERIOR_VISGRID_051_V4_CULLFOG' '$RMGR'
! grep -Fq 'throw std::runtime_error(\"Invalid interior visibility grid dimensions\")' '$CBC'
echo 'PASS: all four files carry the V4 markers and the throw is gone.'
"

echo
echo "===== 5/9 REBUILD (full output) ====="
docker exec -i "$C" bash -lc "
set -euo pipefail
find '$BUILD' -type f \\( -name 'interiorvisibility.cpp.o' -o -name 'camerabindings.cpp.o' -o -name 'renderingmanager.cpp.o' \\) -print -delete 2>/dev/null || true
"
set +e
docker exec -i "$C" bash -lc "set -o pipefail; cmake --build '$BUILD' --target openmw -- -j4" 2>&1 | tee "$PKG/build.log"
BUILD_RC=${PIPESTATUS[0]}
set -e
[ "$BUILD_RC" -eq 0 ] || exit "$BUILD_RC"

echo
echo "===== 6/9 VERIFY THE BUILD ====="
docker exec -i "$C" bash -lc "
set -euo pipefail
test -x '$OPENMW_BIN'
readelf -h '$OPENMW_BIN' | grep -q 'AArch64'
grep -a -q 'TSP_INTERIOR_VISGRID_051_V1' '$OPENMW_BIN'
grep -a -q 'TSP_INTERIOR_VISGRID_051_V3_PERCENTILE_FOG' '$OPENMW_BIN'
grep -a -q 'TSP_INTERIOR_VISGRID_051_V4_CULLFOG' '$OPENMW_BIN'
grep -a -q 'TSP_INTERIOR_SCAN_051_V1' '$OPENMW_BIN'
grep -a -q 'r3=force-text-reset' '$OPENMW_BIN'
echo 'PASS: AArch64 + V1 + V3 + V4 + scanner + controller invariants.'
"
SOURCE_RESTORE=0
docker exec -i "$C" cat "$OPENMW_BIN" > "$PKG/openmw-0.51"
[ -s "$PKG/openmw-0.51" ]
LOCAL_SHA="$(sha256sum "$PKG/openmw-0.51" | awk '{print $1}')"
echo "Built binary sha256: $LOCAL_SHA"

echo
echo "===== 7/9 BACK UP THE DEVICE BINARY ====="
ssh "$DEV" "
set -e
mkdir -p '$REMOTE_BACKUP'
cp -p '$BIN' '$REMOTE_BACKUP/openmw-0.51'
test \"\$(sha256sum '$BIN' | awk '{print \$1}')\" = \"\$(sha256sum '$REMOTE_BACKUP/openmw-0.51' | awk '{print \$1}')\"
sync
echo \"PASS: device binary backed up at $REMOTE_BACKUP\"
"
scp -q "$DEV:$REMOTE_BACKUP/openmw-0.51" "$PKG/device-backup/openmw-0.51"
echo "PASS: backup copied to the VM too."

echo
echo "===== 8/9 DEPLOY ====="
DEPLOY_STARTED=1
scp -q "$PKG/openmw-0.51" "$DEV:/tmp/openmw-0.51-v12"
ssh "$DEV" "
set -e
grep -a -q 'TSP_INTERIOR_VISGRID_051_V4_CULLFOG' /tmp/openmw-0.51-v12
cp /tmp/openmw-0.51-v12 '$BIN.new'
chmod 755 '$BIN.new'
mv -f '$BIN.new' '$BIN'
rm -f /tmp/openmw-0.51-v12
sync
"
REMOTE_SHA="$(ssh "$DEV" "sha256sum '$BIN' | awk '{print \$1}'")"
[ "$LOCAL_SHA" = "$REMOTE_SHA" ] || { echo "ERROR: device SHA mismatch."; exit 1; }
DEPLOY_STARTED=0
echo "PASS: deployed and SHA-verified: $REMOTE_SHA"

echo
echo "===== 9/9 RE-ENABLE THE INTERIOR MAP + HELPERS ====="
ssh "$DEV" "
set -e
M='$MOD/scripts/TSPInteriorVisGrid'
if [ -s \"\$M/interiormap.lua.disabled\" ] && [ ! -s \"\$M/interiormap.lua\" ]; then
    mv -f \"\$M/interiormap.lua.disabled\" \"\$M/interiormap.lua\"
    sync
fi
echo -n 'interior map : '
[ -s \"\$M/interiormap.lua\" ] && echo \"ENABLED (\$(grep -c cap \"\$M/interiormap.lua\") entries)\" || echo 'absent'
echo -n 'sensor       : '
grep -Fq 'TSP_VISGRID_V11_LOADSAFE_12S' '$LUA' && echo 'V11a' || echo 'NOT V11a'
"

cat > "$TOOLS/rollback-visgrid-v12.sh" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
if [ -f "\$HOME/Downloads/visgrid-tools/device.env" ]; then . "\$HOME/Downloads/visgrid-tools/device.env" || true; fi
if [ -n "\${TSP_IP:-}" ]; then DEV="root@\$TSP_IP"; else DEV="\${TSP_DEV:-root@192.168.1.25}"; fi
if ssh "\$DEV" 'pidof openmw-0.51 >/dev/null 2>&1 || pidof openmw >/dev/null 2>&1'; then
    echo "ERROR: exit OpenMW before rollback."; exit 1
fi
ssh "\$DEV" "
set -e
test -s '$REMOTE_BACKUP/openmw-0.51'
cp -p '$REMOTE_BACKUP/openmw-0.51' '$BIN.restore'
chmod 755 '$BIN.restore'
mv -f '$BIN.restore' '$BIN'
sync
sha256sum '$BIN'
"
echo "Restored the exact pre-V12 binary."
EOF
chmod +x "$TOOLS/rollback-visgrid-v12.sh"
echo "PASS: rollback written."

echo
echo "=================================================================="
echo "V12 INSTALLED"
echo "=================================================================="
echo
echo "Three launches, same save, same spot - that is the whole experiment:"
echo
echo "  A. as installed (gap fog):        just launch"
echo "  B. no fog override at all:        TSP_VISGRID_FOG=0"
echo "  C. the old fog, for comparison:   TSP_VISGRID_FOG_MODE=percentile"
echo
echo "To set B or C, add the line to the launcher before it starts OpenMW:"
echo "  export TSP_VISGRID_FOG=0"
echo "in $ROOT/../../Roms/PORTS/Morrowind_51.sh"
echo
echo "The log now prints, once per run:"
echo "  TSP_INTERIOR_VISGRID_051_V4_CULLFOG cfg enabled=1 mode=cullnear margin=300"
echo
echo "After each run:"
echo "  ~/Downloads/pull-visgrid-perf.sh"
echo
echo "Rollback: ~/Downloads/visgrid-tools/rollback-visgrid-v12.sh"
echo "=================================================================="
