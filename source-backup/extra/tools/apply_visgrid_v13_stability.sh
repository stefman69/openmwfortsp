#!/usr/bin/env bash
CR=$(printf '\r'); case "$(head -c 400 "$0" 2>/dev/null)" in *"$CR"*) echo "v13: stripping CRLF from the downloaded copy and re-running"; exec bash -c 'sed "s/\r$//" "$1" | bash' v13 "$0" ;; esac # CRLF trampoline - keep on one line
# apply_visgrid_v13_stability.sh
#
# THE CRASH EXPERIMENT + THE FOG FIX + THE LIGHT MAP, one transactional run.
#
# 1. TSP_LUAJIT_SAFE_051_V1 - the moment VISGRID first publishes its grid,
#    the engine switches LuaJIT to pure INTERPRETER mode (the C-API twin of
#    jit.off()). Every VISGRID crash (9/9) faults at ONE instruction inside
#    the device's bundled beta-era libluajit with a tagged-TValue pattern in
#    the fault address, under the sensor's allocation load - the classic
#    aarch64 trace-compiler/GC bug family. Interpreter mode removes that
#    entire class. Reversible per launch: TSP_LUAJIT_JIT=1.
# 2. LuaJIT FORENSICS (read-only): resolves the crash pc/lr against the
#    device library's symbol table, prints both libraries' versions/hashes -
#    the check the handoff called for that was never captured.
# 3. TSP_INTERIOR_VISGRID_051_V4B_BORDERFOG - V12's gap fog fed EVERY
#    rejection into the fog distance, so in a well-culled room the fog wall
#    parked just past the nearest wall (nearest rejected object is right
#    behind it). Now only BORDERLINE rejections - within 700 units of their
#    own curtain edge, the actual pop-risk band - move the fog. A quiet,
#    fully-drawn view keeps its authored fog. TSP_VISGRID_FOG_BORDER tunes.
# 4. Interior map FORMAT V2 - one number per cell instead of a subtable
#    (~10x less resident Lua heap; the crash fuse shortened with map size).
#    Sensor V11b reads both formats; your V11a load-safe hold is preserved.
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
MAPLUA="$MOD/scripts/TSPInteriorVisGrid/interiormap.lua"
DEVLJ="$ROOT/lib/libluajit-5.1.so.2"
SRC="/root/openmw-0.51-tsp-src"
BUILD="/root/openmw-0.51-tsp-build"
OPENMW_BIN="$BUILD/openmw"
IVC="$SRC/apps/openmw/mwrender/interiorvisibility.cpp"
CBC="$SRC/apps/openmw/mwlua/camerabindings.cpp"

PKG="$HOME/Downloads/openmw51-visgrid-v13-stability-$STAMP"
TOOLS="$HOME/Downloads/visgrid-tools"
LOG="$PKG/install.log"
mkdir -p "$PKG/source-backup" "$PKG/device-backup" "$TOOLS"

SOURCE_RESTORE=0
DEPLOY_STARTED=0
LUA_STARTED=0
PKG_REMOTE="/root/tsp-v13-source-backup-$STAMP"
REMOTE_BACKUP="$ROOT/backups/visgrid-v13-stability-$STAMP"

fail() {
    local rc="${1:-1}" line="${2:-unknown}" cmd="${3:-unknown}"
    trap - ERR
    set +e
    {
        echo
        echo "=================================================================="
        echo "VISGRID V13 STOPPED SAFELY"
        echo "=================================================================="
        echo "Date: $(date)"; echo "Exit code: $rc"; echo "Line: $line"; echo "Command: $cmd"
        echo
        if [ "$SOURCE_RESTORE" = "1" ]; then
            echo "----- RESTORING CONTAINER SOURCE -----"
            docker exec -i "$C" bash -lc "
                set -euo pipefail
                cp -p '$PKG_REMOTE/interiorvisibility.cpp' '$IVC'
                cp -p '$PKG_REMOTE/camerabindings.cpp' '$CBC'
                test \"\$(sha256sum '$IVC' | awk '{print \$1}')\" = \"\$(sed -n 's/  .*interiorvisibility.cpp\$//p;' '$PKG_REMOTE/SHA256SUMS.txt' | head -1 | awk '{print \$1}')\" 2>/dev/null || true
                find '$BUILD' -type f -name 'interiorvisibility.cpp.o' -delete 2>/dev/null || true
                find '$BUILD' -type f -name 'camerabindings.cpp.o' -delete 2>/dev/null || true
                echo 'PASS: source restored'
            " && echo "PASS: container source restored." || echo "WARNING: restore FAILED; backups in $PKG/source-backup + $PKG_REMOTE"
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
            " && echo "PASS: device binary restored." || echo "WARNING: device binary restore FAILED; backup at $REMOTE_BACKUP"
        fi
        if [ "$LUA_STARTED" = "1" ]; then
            echo "----- RESTORING DEVICE SENSOR + MAP -----"
            ssh "$DEV" "
                set -e
                if [ -s '$REMOTE_BACKUP/visgrid.lua.before-v13' ]; then
                    cp -p '$REMOTE_BACKUP/visgrid.lua.before-v13' '$LUA'
                fi
                if [ -s '$REMOTE_BACKUP/interiormap.lua.before-v13' ]; then
                    cp -p '$REMOTE_BACKUP/interiormap.lua.before-v13' '$MAPLUA'
                fi
                sync
            " && echo "PASS: sensor + map restored." || echo "WARNING: sensor/map restore FAILED; backups at $REMOTE_BACKUP"
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
echo "OPENMW 0.51 TSP - VISGRID V13: INTERPRETER MODE + BORDER FOG + MAP V2"
echo "=================================================================="
echo "Device : $DEV"
echo

command -v docker >/dev/null
if [ "$(docker inspect -f '{{.State.Running}}' "$C" 2>/dev/null)" != "true" ]; then
    docker start "$C" >/dev/null
fi

echo "===== 1/10 PRECONDITIONS ====="
if ssh "$DEV" 'pidof openmw-0.51 >/dev/null 2>&1 || pidof openmw >/dev/null 2>&1'; then
    echo "ERROR: OpenMW is running. Exit it normally, then rerun."
    exit 20
fi
docker exec -i "$C" bash -lc "
set -euo pipefail
test -f '$IVC'; test -f '$CBC'
grep -Fq 'TSP_INTERIOR_VISGRID_051_V4_NOTHROW' '$CBC'
grep -Fq 'TSP_INTERIOR_VISGRID_051_V4_CULLFOG' '$IVC'
grep -Fq 'takeInteriorVisibilityCullNear' '$IVC'
echo 'PASS: container source carries the V12 state (NOTHROW + CULLFOG).'
"
ssh "$DEV" "
set -e
test -s '$BIN'
test -s '$LUA'
grep -a -q 'TSP_INTERIOR_VISGRID_051_V1' '$BIN'
grep -a -q 'TSP_INTERIOR_VISGRID_051_V4_CULLFOG' '$BIN'
grep -Fq 'TSP_INTERIOR_VISGRID_LUA_V11' '$LUA'
echo 'PASS: device carries the V12 binary + a V11-lineage sensor.'
if grep -Fq 'TSP_VISGRID_V11_LOADSAFE_12S' '$LUA'; then
    echo 'PASS: V11a load-safe hold present (will be preserved).'
else
    echo 'NOTE: no load-safe hold in the live sensor.'
fi
"

echo
echo "===== 2/10 LUAJIT FORENSICS (READ-ONLY) ====="
FORENSICS="$TOOLS/luajit-forensics-$STAMP.txt"
{
echo "########## LUAJIT FORENSICS - $(date) ##########"
echo "crash signature under investigation: pc +0x94f0  lr +0x17adc"
echo
echo "-- device bundled library --"
ssh "$DEV" "ls -lL '$DEVLJ'; sha256sum \"\$(readlink -f '$DEVLJ')\"" || true
ssh "$DEV" "cat '$DEVLJ'" > "$PKG/device-libluajit-5.1.so.2" || true
if [ -s "$PKG/device-libluajit-5.1.so.2" ]; then
    docker cp "$PKG/device-libluajit-5.1.so.2" "$C:/tmp/device-libluajit.so"
    docker exec -i "$C" bash -lc '
set -e
L=/tmp/device-libluajit.so
echo "  version strings:"
strings "$L" | grep -m3 -E "LuaJIT [0-9]" | sed "s/^/    /" || echo "    (none found)"
echo "  ELF class:"
readelf -h "$L" | grep -E "Class:|Machine:" | sed "s/^/    /"
echo
echo "  symbol resolution for the crash addresses:"
nm -D --defined-only "$L" 2>/dev/null | sort > /tmp/devsyms.txt || true
python3 - <<PYS
lines = []
for ln in open("/tmp/devsyms.txt"):
    parts = ln.split()
    if len(parts) >= 3 and parts[1] in ("T", "t", "W"):
        try:
            lines.append((int(parts[0], 16), parts[2]))
        except ValueError:
            pass
lines.sort()
def resolve(addr):
    prev = None
    for a, n in lines:
        if a > addr:
            break
        prev = (a, n)
    nxt = None
    for a, n in lines:
        if a > addr:
            nxt = (a, n)
            break
    if prev is None:
        return "BEFORE the first exported symbol%s - i.e. inside the non-exported ASM interpreter/GC core" % (
            " (first export: %s at 0x%x)" % (nxt[1], nxt[0]) if nxt else "")
    s = "%s+0x%x" % (prev[1], addr - prev[0])
    if nxt:
        s += "   (next export: %s at 0x%x)" % (nxt[1], nxt[0])
    return s
for a in (0x94f0, 0x17adc):
    print("    +0x%-6x -> %s" % (a, resolve(a)))
print("    exported symbols total: %d" % len(lines))
PYS
' || true
else
    echo "  (could not pull the device library)"
fi
echo
echo "-- container library (what the binary was compiled against) --"
docker exec -i "$C" bash -lc '
for p in /usr/lib/aarch64-linux-gnu/libluajit-5.1.so.2 /usr/lib/libluajit-5.1.so.2 /usr/local/lib/libluajit-5.1.so.2; do
    if [ -e "$p" ]; then
        ls -lL "$p"; sha256sum "$(readlink -f "$p")"
        strings "$(readlink -f "$p")" | grep -m2 -E "LuaJIT [0-9]" | sed "s/^/    /" || true
    fi
done
echo -n "ldd of built binary: "
ldd '"$OPENMW_BIN"' 2>/dev/null | grep -i luajit || echo "(binary absent or static)"
grep -i "GC64\|LUA_CUSTOM" '"$BUILD"'/CMakeCache.txt 2>/dev/null | head -5 || true
' || true
} 2>&1 | tee "$FORENSICS"
echo
echo "Forensics saved: $FORENSICS  (send this file back either way)"

echo
echo "===== 3/10 VERIFIED SOURCE BACKUP (CONTAINER + VM) ====="
docker exec -i "$C" bash -lc "
set -euo pipefail
mkdir -p '$PKG_REMOTE'
for f in '$IVC' '$CBC'; do
    b=\"\$(basename \"\$f\")\"
    S1=\$(sha256sum \"\$f\" | awk '{print \$1}')
    cp -p \"\$f\" \"$PKG_REMOTE/\$b\"
    S2=\$(sha256sum \"$PKG_REMOTE/\$b\" | awk '{print \$1}')
    test \"\$S1\" = \"\$S2\"
done
cd '$PKG_REMOTE' && sha256sum * > SHA256SUMS.txt && cat SHA256SUMS.txt
"
for f in interiorvisibility.cpp camerabindings.cpp; do
    docker exec -i "$C" cat "$PKG_REMOTE/$f" > "$PKG/source-backup/$f"
    [ -s "$PKG/source-backup/$f" ]
done
echo "PASS: hash -> copy -> hash -> compare done in the container; VM copies kept."
SOURCE_RESTORE=1

echo
echo "===== 4/10 PATCH THE SOURCE ====="
docker exec -i "$C" python3 - "$CBC" "$IVC" <<'PYPATCH'
import sys

# V13 stability patcher: (A) LuaJIT interpreter-mode switch in the grid
# binding, (B) borderline-gated cull fog. Anchors are the VERBATIM blocks the
# V12 installer wrote (confirmed applied on this tree by its own postchecks).
cbc = sys.argv[1] if len(sys.argv) > 1 else "/root/openmw-0.51-tsp-src/apps/openmw/mwlua/camerabindings.cpp"
ivc = sys.argv[2] if len(sys.argv) > 2 else "/root/openmw-0.51-tsp-src/apps/openmw/mwrender/interiorvisibility.cpp"

def read(p):
    return open(p, encoding='utf-8', errors='surrogateescape').read()

def write(p, s):
    open(p, 'w', encoding='utf-8', errors='surrogateescape').write(s)

def sub(s, old, new, label, path):
    n = s.count(old)
    if n != 1:
        raise SystemExit("ERROR: %s anchor count=%d in %s" % (label, n, path))
    return s.replace(old, new, 1)

def add_include(s, inc, path):
    if inc in s:
        return s
    i = s.find('#include')
    if i < 0:
        raise SystemExit("ERROR: no #include line in " + path)
    j = s.find('\n', i)
    return s[:j+1] + inc + '\n' + s[j+1:]

# ---------------------------------------------------------------- A) jit off
b = read(cbc)
if "TSP_LUAJIT_SAFE_051_V1" in b:
    print("NOTE: camerabindings already carries TSP_LUAJIT_SAFE_051_V1")
else:
    if "TSP_INTERIOR_VISGRID_051_V4_NOTHROW" not in b:
        raise SystemExit("ERROR: V4 NOTHROW binding missing - run the V12 installer first")
    anchor = """                  // Bad input degrades to "render everything", never to a
                  // damaged VM.
                  const int count = cols * rows;"""
    insertion = """                  // Bad input degrades to "render everything", never to a
                  // damaged VM.

                  // TSP_LUAJIT_SAFE_051_V1
                  // Every VISGRID crash (9 of 9) faults at ONE instruction
                  // inside libluajit with a tagged-TValue pattern in the fault
                  // address, on the device's bundled beta-era LuaJIT, under
                  // the sensor's allocation load. The trace compiler and its
                  // GC interactions are the classic home of that bug family
                  // on aarch64, so the VM is switched to pure interpreter
                  // mode the moment VISGRID first publishes (same mechanism
                  // as Lua's own jit.off()). Interpreter Lua costs a few ms
                  // at our call rates; a corrupted VM costs the session.
                  //   TSP_LUAJIT_JIT=1   keeps the JIT enabled (A/B switch)
                  static bool tspJitConfigured = false;
                  if (!tspJitConfigured)
                  {
                      tspJitConfigured = true;
                      const char* tspKeepJit = std::getenv("TSP_LUAJIT_JIT");
                      if (tspKeepJit != nullptr && tspKeepJit[0] == '1')
                          Log(Debug::Warning)
                              << "TSP_LUAJIT_SAFE_051_V1 JIT kept ON (TSP_LUAJIT_JIT=1)";
                      else if (luaJIT_setmode(values.lua_state(), 0,
                                   LUAJIT_MODE_ENGINE | LUAJIT_MODE_OFF)
                          == 1)
                      {
                          // MODE_OFF stops NEW traces being recorded. Traces
                          // compiled before VISGRID armed stay resident and
                          // keep executing, so without a flush a survival
                          // would not prove the JIT was out of the picture.
                          const int tspFlushed = luaJIT_setmode(values.lua_state(), 0,
                              LUAJIT_MODE_ENGINE | LUAJIT_MODE_FLUSH);
                          Log(Debug::Warning)
                              << "TSP_LUAJIT_SAFE_051_V1 interpreter mode ON flush="
                              << tspFlushed
                              << " (set TSP_LUAJIT_JIT=1 to re-enable the JIT)";
                      }
                      else
                          Log(Debug::Warning)
                              << "TSP_LUAJIT_SAFE_051_V1 luaJIT_setmode FAILED - JIT left as-is";
                  }

                  const int count = cols * rows;"""
    b = sub(b, anchor, insertion, "cbc/jitoff", cbc)
    b = add_include(b, "#include <cstdlib>", cbc)
    b = add_include(b, "#include <components/debug/debuglog.hpp>", cbc)
    # TSP_LUAJIT_HEADER_051_V1
    # luajit.h (and the lua.h it pulls in) are plain C with NO extern "C"
    # guards. Inserting it at the TOP of the file, unwrapped, gives every
    # lua_* prototype in this translation unit C++ linkage - which is what
    # produced hundreds of
    #     undefined reference to `lua_getmetatable(lua_State*, int)'
    # Include it AFTER everything else (sol has by then declared the Lua API
    # with C linkage) and wrap it, so luaJIT_setmode is C too.
    if "TSP_LUAJIT_HEADER_051_V1" not in b:
        _blk = ('\n'
                '// TSP_LUAJIT_HEADER_051_V1 - LuaJIT headers are plain C with no\n'
                '// extern "C" guards. Must be included last and wrapped, or every\n'
                '// lua_* symbol in this file gets C++ linkage and the link fails.\n'
                'extern "C" {\n'
                '#include <luajit.h>\n'
                '}\n')
        _i = b.rfind('#include')
        if _i < 0:
            raise SystemExit("ERROR: no #include line in " + cbc)
        _eol = b.find('\n', _i)
        b = b[:_eol + 1] + _blk + b[_eol + 1:]
    write(cbc, b)
    print("PASS: camerabindings.cpp - interpreter-mode switch added")

# ------------------------------------------------------- B) borderline fog
c = read(ivc)
if "TSP_INTERIOR_VISGRID_051_V4B_BORDERFOG" in c:
    print("NOTE: interiorvisibility already carries V4B_BORDERFOG")
else:
    old = """            // TSP_INTERIOR_VISGRID_051_V4_CULLFOG
            // Remember the NEAREST rejected surface this frame. That is
            // the closest distance at which a hole can appear, so it is
            // the only place fog is needed.
            {
                const float tspNear = static_cast<float>(nearestSurface);
                float tspPrev = sCullNear.load(std::memory_order_relaxed);
                while ((tspPrev <= 0.f || tspNear < tspPrev)
                    && !sCullNear.compare_exchange_weak(
                        tspPrev, tspNear, std::memory_order_relaxed))
                {
                }
            }"""
    new = """            // TSP_INTERIOR_VISGRID_051_V4B_BORDERFOG
            // Fog exists to hide POP-RISK holes. A rejection far behind the
            // curtain (deep behind a drawn wall) can never appear on screen,
            // so it must not pull the fog wall in - V12 fed EVERY rejection
            // into the fog distance, which parked dense fog just past the
            // nearest wall whenever the curtain was working well. Only a
            // rejection within BORDER units of its own curtain edge - the
            // band where a stale bin could genuinely reveal a hole - feeds
            // the fog distance now.
            //   TSP_VISGRID_FOG_BORDER=<units>  default 700
            //   (huge value = V12 behaviour, 0 = exact-edge rejections only)
            {
                static bool tspBorderRead = false;
                static double tspBorder = 700.0;
                if (!tspBorderRead)
                {
                    tspBorderRead = true;
                    const char* tspEnvB = std::getenv("TSP_VISGRID_FOG_BORDER");
                    if (tspEnvB != nullptr)
                    {
                        const double tspB = std::strtod(tspEnvB, nullptr);
                        if (tspB >= 0.0)
                            tspBorder = tspB;
                    }
                    // Logged once per process. This also puts the marker in
                    // .rodata so the installer's binary check has something
                    // real to find - a // comment never reaches the binary.
                    Log(Debug::Info)
                        << "TSP_INTERIOR_VISGRID_051_V4B_BORDERFOG border=" << tspBorder;
                }
                if (nearestSurface < static_cast<double>(allowedDepth) + safety + tspBorder)
                {
                    const float tspNear = static_cast<float>(nearestSurface);
                    float tspPrev = sCullNear.load(std::memory_order_relaxed);
                    while ((tspPrev <= 0.f || tspNear < tspPrev)
                        && !sCullNear.compare_exchange_weak(
                            tspPrev, tspNear, std::memory_order_relaxed))
                    {
                    }
                }
            }"""
    c = sub(c, old, new, "ivc/borderfog", ivc)
    c = add_include(c, "#include <cstdlib>", ivc)
    write(ivc, c)
    print("PASS: interiorvisibility.cpp - borderline-gated cull fog")

# ---------------------------------------------------------------- postconds
b2, c2 = read(cbc), read(ivc)
for needle, where in (
    ("TSP_LUAJIT_SAFE_051_V1", b2), ("luaJIT_setmode", b2),
    ("#include <luajit.h>", b2), ("TSP_INTERIOR_VISGRID_051_V4_NOTHROW", b2),
    ("TSP_INTERIOR_VISGRID_051_V4B_BORDERFOG", c2), ("tspBorder", c2),
    ("takeInteriorVisibilityCullNear", c2),
):
    if needle not in where:
        raise SystemExit("ERROR: postcondition missing: " + needle)
print("PASS: all V13 postconditions hold.")
PYPATCH

docker exec -i "$C" bash -lc "
set -euo pipefail
grep -Fq 'TSP_LUAJIT_SAFE_051_V1' '$CBC'
grep -Fq 'luaJIT_setmode' '$CBC'
grep -Fq 'TSP_INTERIOR_VISGRID_051_V4B_BORDERFOG' '$IVC'
echo 'PASS: both files carry the V13 markers.'
"

echo
echo "===== 5/10 REBUILD ====="
docker exec -i "$C" bash -lc "
set -euo pipefail
find '$BUILD' -type f \\( -name 'interiorvisibility.cpp.o' -o -name 'camerabindings.cpp.o' \\) -print -delete 2>/dev/null || true
"
set +e
docker exec -i "$C" bash -lc "set -o pipefail; cmake --build '$BUILD' --target openmw -- -j4" 2>&1 | tee "$PKG/build.log"
BUILD_RC=${PIPESTATUS[0]}
set -e
[ "$BUILD_RC" -eq 0 ] || exit "$BUILD_RC"

echo
echo "===== 6/10 VERIFY THE BUILD ====="
docker exec -i "$C" bash -lc "
set -uo pipefail
B='$OPENMW_BIN'
test -x \"\$B\" || { echo 'FAIL: no executable at' \"\$B\"; exit 1; }
readelf -h \"\$B\" | grep -q 'AArch64' || { echo 'FAIL: not an AArch64 ELF'; exit 1; }
echo '  PASS  AArch64 ELF'
tspmiss=0
for m in TSP_INTERIOR_VISGRID_051_V1 \
         TSP_INTERIOR_VISGRID_051_V3_PERCENTILE_FOG \
         TSP_INTERIOR_VISGRID_051_V4_CULLFOG \
         TSP_INTERIOR_VISGRID_051_V4B_BORDERFOG \
         TSP_LUAJIT_SAFE_051_V1 \
         TSP_INTERIOR_SCAN_051_V1; do
    if grep -a -q \"\$m\" \"\$B\"; then
        echo \"  PASS  marker \$m\"
    else
        echo \"  FAIL  marker \$m NOT FOUND IN BINARY\"
        tspmiss=1
    fi
done
for m in r3=force-text-reset tx_cursor.dds; do
    if grep -a -q \"\$m\" \"\$B\"; then
        echo \"  PASS  invariant \$m\"
    else
        echo \"  WARN  invariant \$m not present (informational, not fatal)\"
    fi
done
if [ \"\$tspmiss\" -ne 0 ]; then
    echo 'FAIL: one or more markers are missing from the binary (named above).'
    echo '      A marker that only exists as a // comment can never appear here.'
    exit 1
fi
echo 'PASS: build verification complete.'
"
SOURCE_RESTORE=0
docker exec -i "$C" cat "$OPENMW_BIN" > "$PKG/openmw-0.51"
[ -s "$PKG/openmw-0.51" ]
LOCAL_SHA="$(sha256sum "$PKG/openmw-0.51" | awk '{print $1}')"
echo "Built binary sha256: $LOCAL_SHA"

echo
echo "===== 7/10 BACK UP DEVICE BINARY + SENSOR + MAP ====="
ssh "$DEV" "
set -e
mkdir -p '$REMOTE_BACKUP'
cp -p '$BIN' '$REMOTE_BACKUP/openmw-0.51'
cp -p '$LUA' '$REMOTE_BACKUP/visgrid.lua.before-v13'
if [ -s '$MAPLUA' ]; then cp -p '$MAPLUA' '$REMOTE_BACKUP/interiormap.lua.before-v13'; fi
test \"\$(sha256sum '$BIN' | awk '{print \$1}')\" = \"\$(sha256sum '$REMOTE_BACKUP/openmw-0.51' | awk '{print \$1}')\"
test \"\$(sha256sum '$LUA' | awk '{print \$1}')\" = \"\$(sha256sum '$REMOTE_BACKUP/visgrid.lua.before-v13' | awk '{print \$1}')\"
sha256sum '$REMOTE_BACKUP'/* > '$REMOTE_BACKUP/SHA256SUMS.txt'
sync
cat '$REMOTE_BACKUP/SHA256SUMS.txt'
"
scp -q "$DEV:$REMOTE_BACKUP/openmw-0.51" "$PKG/device-backup/openmw-0.51"
scp -q "$DEV:$REMOTE_BACKUP/visgrid.lua.before-v13" "$PKG/device-backup/visgrid.lua.before-v13"
echo "PASS: verified backups on device and VM."

echo
echo "===== 8/10 DEPLOY THE BINARY (TRANSACTIONAL) ====="
DEPLOY_STARTED=1
scp -q "$PKG/openmw-0.51" "$DEV:/tmp/openmw-0.51-v13"
ssh "$DEV" "
set -e
grep -a -q 'TSP_LUAJIT_SAFE_051_V1' /tmp/openmw-0.51-v13
grep -a -q 'TSP_INTERIOR_VISGRID_051_V4B_BORDERFOG' /tmp/openmw-0.51-v13
cp /tmp/openmw-0.51-v13 '$BIN.new'
chmod 755 '$BIN.new'
mv -f '$BIN.new' '$BIN'
rm -f /tmp/openmw-0.51-v13
sync
"
REMOTE_SHA="$(ssh "$DEV" "sha256sum '$BIN' | awk '{print \$1}'")"
[ "$LOCAL_SHA" = "$REMOTE_SHA" ] || { echo "ERROR: device SHA mismatch."; exit 1; }
echo "PASS: deployed and SHA-verified: $REMOTE_SHA"

echo
echo "===== 9/10 SENSOR V11b + INTERIOR MAP V2 ====="
LUA_STARTED=1
scp -q "$DEV:$LUA" "$PKG/visgrid.live.lua"
cp "$PKG/visgrid.live.lua" "$PKG/visgrid-v11b.lua"
python3 - "$PKG/visgrid-v11b.lua" <<'PYSENSOR'
import sys

# V11b sensor patch: the map lookup accepts BOTH formats -
#   v2 (flat):  cells["name"] = <cap number>     (the new low-heap format)
#   v1 (table): cells["name"] = { cap = n, ... } (whatever is still installed)
# Nothing else in the sensor changes; the V11a load-safe hold is untouched.
path = sys.argv[1]
s = open(path, encoding='utf-8').read()

if "TSP_INTERIOR_VISGRID_LUA_V11" not in s:
    raise SystemExit("ERROR: active sensor is not V11-lineage.")
if "TSP_VISGRID_V11B_MAPV2" in s:
    print("PASS: sensor already carries the V11b dual-format lookup.")
    raise SystemExit(0)

old = """        local e = mapState.cells[cellName]
        if e ~= nil and type(e.cap) == 'number' and e.cap >= 900 then
            mapState.cap = min(OPEN_DEPTH, e.cap)
            print(string.format(
                '[TSP_VISGRID_V11] map: "%s" cap=%.0f box=%.0fx%.0fx%.0f objs=%s',
                tostring(cellName), mapState.cap, e.dx or -1, e.dy or -1, e.dz or -1,
                tostring(e.objects or '?')))
        else
            print('[TSP_VISGRID_V11] map: no entry for "' .. tostring(cellName) .. '"')
        end"""
new = """        -- TSP_VISGRID_V11B_MAPV2: flat map entries (a bare cap number per
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
            print(string.format('[TSP_VISGRID_V11] map: "%s" cap=%.0f',
                tostring(cellName), mapState.cap))
        else
            print('[TSP_VISGRID_V11] map: no entry for "' .. tostring(cellName) .. '"')
        end"""
n = s.count(old)
if n != 1:
    raise SystemExit("ERROR: map-lookup anchor count=%d" % n)
s = s.replace(old, new, 1)

for needle in ("TSP_VISGRID_V11B_MAPV2", "type(e) == 'number'"):
    if needle not in s:
        raise SystemExit("ERROR: postcondition missing: " + needle)
open(path, 'w', encoding='utf-8').write(s)
print("PASS: sensor patched with the V11b dual-format map lookup.")
PYSENSOR
NEW_LUA_SHA="$(sha256sum "$PKG/visgrid-v11b.lua" | awk '{print $1}')"
scp -q "$PKG/visgrid-v11b.lua" "$DEV:/tmp/visgrid-v11b.lua"
ssh "$DEV" "
set -e
test -s /tmp/visgrid-v11b.lua
grep -Fq 'TSP_VISGRID_V11B_MAPV2' /tmp/visgrid-v11b.lua
mkdir -p '$MOD/sensors'
cp /tmp/visgrid-v11b.lua '$MOD/sensors/visgrid-v11b.lua'
cp /tmp/visgrid-v11b.lua '$LUA.new'
mv -f '$LUA.new' '$LUA'
rm -f /tmp/visgrid-v11b.lua
sync
test \"\$(sha256sum '$LUA' | awk '{print \$1}')\" = '$NEW_LUA_SHA'
"
echo "PASS: V11b sensor installed (dual-format map lookup; hold preserved)."

cat > "$TOOLS/tsp_scan_to_map.py" <<'PYCONV'
#!/usr/bin/env python3
# TSP scan -> interiormap.lua converter, FORMAT V2 (flat).
# V1 stored a subtable per cell (1323 tables + 9000+ values) and the crash
# fuse shortened dramatically with that heap resident. V2 stores ONE number
# per cell - the publish cap - cutting the map's Lua object count ~10x.
# All the detail (box, objects, doors, lights) stays in tsp_interior_scan.txt.
import sys, math

inp, outp = sys.argv[1], sys.argv[2]
cells = {}
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

def lq(s):
    return s.replace('\\', '\\\\').replace('"', '\\"')

with open(outp, 'w', encoding='utf-8') as f:
    f.write('-- TSP_INTERIOR_MAP_V2 - generated by finish-interior-map.sh (flat format)\n')
    f.write('-- one number per cell: the publish cap. Details live in tsp_interior_scan.txt.\n')
    f.write('return {\n  version = 2,\n  count = %d,\n  cells = {\n' % len(cells))
    for name in sorted(cells):
        f.write('    ["%s"] = %.0f,\n' % (lq(name), cells[name]))
    f.write('  },\n}\n')

caps = sorted(cells.values())
print('cells kept: %d' % len(cells))
if caps:
    print('cap range : %.0f .. %.0f (median %.0f)' % (caps[0], caps[-1], caps[len(caps) // 2]))
PYCONV
echo "PASS: converter updated to map format v2 (finish-interior-map.sh uses it)."

if ssh "$DEV" "test -s '$ROOT/tsp_interior_scan.txt'"; then
    ssh "$DEV" "cat '$ROOT/tsp_interior_scan.txt'" > "$PKG/tsp_interior_scan.txt"
    grep -Fq 'TSP_INTERIOR_SCAN_051_V1' "$PKG/tsp_interior_scan.txt"
    python3 "$TOOLS/tsp_scan_to_map.py" "$PKG/tsp_interior_scan.txt" "$PKG/interiormap.lua"
    grep -Fq 'TSP_INTERIOR_MAP_V2' "$PKG/interiormap.lua"
    MAP_SHA="$(sha256sum "$PKG/interiormap.lua" | awk '{print $1}')"
    scp -q "$PKG/interiormap.lua" "$DEV:/tmp/interiormap.lua.v2"
    ssh "$DEV" "
set -e
test -s /tmp/interiormap.lua.v2
grep -Fq 'TSP_INTERIOR_MAP_V2' /tmp/interiormap.lua.v2
if [ -s '$MAPLUA' ]; then cp -p '$MAPLUA' '$MAPLUA.v1-$STAMP'; fi
if [ -s '$MAPLUA.disabled' ]; then mv -f '$MAPLUA.disabled' '$MAPLUA.disabled.v1-$STAMP'; fi
mv -f /tmp/interiormap.lua.v2 '$MAPLUA'
sync
test \"\$(sha256sum '$MAPLUA' | awk '{print \$1}')\" = '$MAP_SHA'
"
    echo "PASS: interior map regenerated as FORMAT V2 and installed (old map kept as .v1-$STAMP)."
else
    echo "NOTE: no tsp_interior_scan.txt on the card - existing map left as is."
    echo "      (finish-interior-map.sh will produce a v2 map after the next scan.)"
fi
DEPLOY_STARTED=0
LUA_STARTED=0

echo
echo "===== 10/10 ROLLBACK + SUMMARY ====="
# The stable rollback must always point at a TRUE pre-V13 backup. On a rerun
# (device already V13) this run's backup is just V13 again - keep the stable
# rollback aimed at the original pre-V13 snapshot in that case.
WRITE_ROLLBACK=1
if ssh "$DEV" "grep -a -q 'TSP_LUAJIT_SAFE_051_V1' '$REMOTE_BACKUP/openmw-0.51'"; then
    if [ -f "$TOOLS/rollback-visgrid-v13.sh" ]; then
        echo "NOTE: device was already on V13 when this run backed it up;"
        echo "      keeping the existing stable rollback (true pre-V13 backup)."
        WRITE_ROLLBACK=0
    else
        echo "NOTE: rerun backup is already-V13 and no earlier rollback exists;"
        echo "      installing this run's (restores the state just before this rerun)."
    fi
fi
if [ "$WRITE_ROLLBACK" = "1" ]; then
cat > "$TOOLS/rollback-visgrid-v13.sh" <<EOF
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
cp -p '$REMOTE_BACKUP/visgrid.lua.before-v13' '$LUA'
if [ -s '$REMOTE_BACKUP/interiormap.lua.before-v13' ]; then
    cp -p '$REMOTE_BACKUP/interiormap.lua.before-v13' '$MAPLUA'
fi
sync
sha256sum '$BIN' '$LUA'
"
echo "Restored the exact pre-V13 binary + sensor + map."
EOF
chmod +x "$TOOLS/rollback-visgrid-v13.sh"
fi

echo
echo "=================================================================="
echo "V13 INSTALLED"
echo "=================================================================="
echo
echo "What the next launch should print, in order:"
echo "  [TSP_VISGRID_V11] interior map loaded: <N> cells (format v2)"
echo "  ... grid/fog held 12.0s ... load-safe hold complete ..."
echo "  [TSP_VISGRID_V11] map: \"<cell>\" cap=<n>"
echo "  TSP_LUAJIT_SAFE_051_V1 interpreter mode ON"
echo "  TSP_INTERIOR_VISGRID_051_V4_CULLFOG cfg ..."
echo "  then one status line per second."
echo
echo "THE LADDER - one launch per rung, stop at the first one that survives:"
echo "  1. Launch as installed (interpreter mode + map v2 + border fog)."
echo "  2. Still crashes -> disable the map:  bash ~/Downloads/visgrid-triage.sh"
echo "     then launch again."
echo "  3. Still crashes -> the control:  ~/Downloads/visgrid-tools/sensor-switch.sh v1c"
echo "     then launch again. (If V1C also dies at +0x94f0, the sensor is"
echo "     innocent and the library itself is next.)"
echo
echo "After EVERY run, one command:  ~/Downloads/pull-visgrid-perf.sh"
echo "Also send: $FORENSICS"
echo
echo "Fog knobs (in the launcher, before OpenMW starts):"
echo "  TSP_VISGRID_FOG_BORDER=700   pop-risk band that pulls fog (default)"
echo "  TSP_VISGRID_FOG=0            no fog override at all"
echo "  TSP_LUAJIT_JIT=1             put the JIT back (A/B the crash fix)"
echo
echo "Rollback everything: ~/Downloads/visgrid-tools/rollback-visgrid-v13.sh"
echo "=================================================================="
