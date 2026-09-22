#!/usr/bin/env bash
# fix-v13-luajit-linkage.sh
#
# THE LINK ERROR
#   ld: undefined reference to `lua_getmetatable(lua_State*, int)'
#   ld: undefined reference to `lua_touserdata(lua_State*, int)'
#   ... hundreds more, all from camerabindings.cpp only
#
#   Note the signatures: those are C++ MANGLED names. The linker is looking for
#   _Z16lua_getmetatableP9lua_Statei instead of the C symbol lua_getmetatable.
#
#   Cause: V13's patcher does
#       b = add_include(b, "#include <luajit.h>", cbc)
#   and add_include inserts after the FIRST #include line, i.e. at the very top
#   of the file. LuaJIT's headers (luajit.h, and the lua.h it pulls in) are
#   plain C with NO extern "C" guards - LuaJIT expects the consumer to wrap
#   them, which is what sol does. Because luajit.h landed first and unwrapped,
#   every lua_* prototype in that translation unit acquired C++ linkage, and
#   lua.h's include guard then stopped sol from re-declaring them properly.
#   camerabindings.cpp is the only file V13 touched that way, which is exactly
#   where all the errors are.
#
#   Verified with a minimal repro: unwrapped-first gives
#       U luaJIT_setmode(lua_State*, int, int)
#   wrapped-last gives
#       U luaJIT_setmode
#
# THE FIX (two edits to the V13 installer, then it is rerun)
#   1. Drop the top-of-file `#include <luajit.h>`. Instead insert, AFTER the
#      last #include in the file (so sol has already declared the Lua API with
#      C linkage), an extern "C"-wrapped include.
#   2. While in there: also FLUSH the JIT. luaJIT_setmode(..., MODE_ENGINE |
#      MODE_OFF) stops NEW traces being recorded, but traces already compiled
#      before VISGRID armed stay resident. Without a flush the run can still be
#      executing JIT-generated code and a survival would prove nothing. One
#      extra setmode call with MODE_FLUSH makes the experiment conclusive.
#
# Nothing else in V13 is changed. Backups of the installer are kept.
set -Eeuo pipefail

INST="${1:-$HOME/Downloads/apply_visgrid_v13_stability.sh}"
test -f "$INST" || { echo "ERROR: V13 installer not found at $INST"; exit 2; }

C="${TSP_BUILDER:-openmw_builder}"
SRC="/root/openmw-0.51-tsp-src"
CBC="$SRC/apps/openmw/mwlua/camerabindings.cpp"

echo "=================================================================="
echo "STEP 1/3  PATCH THE V13 INSTALLER"
echo "=================================================================="
cp -p "$INST" "$INST.bak-linkage-$(date +%Y%m%d-%H%M%S)"

python3 - "$INST" <<'PYFIX'
import sys

path = sys.argv[1]
raw = open(path, encoding='utf-8', errors='surrogateescape').read()
s = raw.replace('\r\n', '\n')
changed = 0

# ---- 1. the include ------------------------------------------------------
old_inc = '''    b = sub(b, anchor, insertion, "cbc/jitoff", cbc)
    b = add_include(b, "#include <luajit.h>", cbc)
    b = add_include(b, "#include <cstdlib>", cbc)
    b = add_include(b, "#include <components/debug/debuglog.hpp>", cbc)
'''
new_inc = '''    b = sub(b, anchor, insertion, "cbc/jitoff", cbc)
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
        _blk = ('\\n'
                '// TSP_LUAJIT_HEADER_051_V1 - LuaJIT headers are plain C with no\\n'
                '// extern "C" guards. Must be included last and wrapped, or every\\n'
                '// lua_* symbol in this file gets C++ linkage and the link fails.\\n'
                'extern "C" {\\n'
                '#include <luajit.h>\\n'
                '}\\n')
        _i = b.rfind('#include')
        if _i < 0:
            raise SystemExit("ERROR: no #include line in " + cbc)
        _eol = b.find('\\n', _i)
        b = b[:_eol + 1] + _blk + b[_eol + 1:]
'''
if old_inc in s:
    s = s.replace(old_inc, new_inc, 1)
    changed += 1
    print("PASS: luajit.h now included last and wrapped in extern \"C\".")
elif 'TSP_LUAJIT_HEADER_051_V1' in s:
    print("NOTE: installer already carries the linkage fix.")
else:
    raise SystemExit("ERROR: could not find the add_include block to replace.")

# ---- 2. flush the JIT as well as turning it off --------------------------
old_off = '''                      else if (luaJIT_setmode(values.lua_state(), 0,
                                   LUAJIT_MODE_ENGINE | LUAJIT_MODE_OFF)
                          == 1)
                          Log(Debug::Warning) << "TSP_LUAJIT_SAFE_051_V1 interpreter mode ON "
                                                 "(set TSP_LUAJIT_JIT=1 to re-enable the JIT)";
'''
new_off = '''                      else if (luaJIT_setmode(values.lua_state(), 0,
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
'''
if old_off in s:
    s = s.replace(old_off, new_off, 1)
    changed += 1
    print("PASS: JIT is now flushed as well as disabled.")
elif 'LUAJIT_MODE_FLUSH' in s:
    print("NOTE: installer already flushes the JIT.")
else:
    raise SystemExit("ERROR: could not find the luaJIT_setmode block to replace.")

if changed:
    open(path, 'w', encoding='utf-8', errors='surrogateescape').write(s)

# ---- postconditions ------------------------------------------------------
b2 = open(path, encoding='utf-8', errors='surrogateescape').read()
assert 'TSP_LUAJIT_HEADER_051_V1' in b2
assert 'LUAJIT_MODE_FLUSH' in b2
assert 'add_include(b, "#include <luajit.h>", cbc)' not in b2, \
    "the unwrapped top-of-file include is still there"
for needle in ("TSP_LUAJIT_SAFE_051_V1", "TSP_INTERIOR_VISGRID_051_V4B_BORDERFOG",
               "TSP_VISGRID_V11B_MAPV2", "TSP_INTERIOR_MAP_V2"):
    assert needle in b2, "installer lost: " + needle
print("PASS: V13 installer postconditions hold.")
PYFIX

bash -n "$INST"
echo "PASS: V13 installer still parses."

echo
echo "=================================================================="
echo "STEP 2/3  CLEAN THE CONTAINER SOURCE + STALE OBJECT"
echo "=================================================================="
command -v docker >/dev/null
if [ "$(docker inspect -f '{{.State.Running}}' "$C" 2>/dev/null)" != "true" ]; then
    docker start "$C" >/dev/null
fi
docker exec -i "$C" python3 - "$CBC" <<'PYSRC'
import sys, re, shutil, time
path = sys.argv[1]
s = open(path, encoding='utf-8', errors='surrogateescape').read()
if 'TSP_LUAJIT_SAFE_051_V1' not in s:
    print("PASS: camerabindings.cpp is clean (V13 rolled it back); nothing to undo.")
    raise SystemExit(0)
# The failed run may not have been rolled back. Strip the bad top-of-file
# include so the installer's own idempotency check does not skip the fix.
if 'TSP_LUAJIT_HEADER_051_V1' in s:
    print("PASS: source already carries the wrapped include.")
    raise SystemExit(0)
shutil.copy2(path, path + '.bak-linkage-' + time.strftime('%Y%m%d-%H%M%S'))
n = len(re.findall(r'^#include <luajit\.h>\n', s, re.M))
s = re.sub(r'^#include <luajit\.h>\n', '', s, count=1, flags=re.M)
i = s.rfind('#include')
eol = s.find('\n', i)
s = (s[:eol + 1]
     + '\n// TSP_LUAJIT_HEADER_051_V1 - LuaJIT headers are plain C with no\n'
       '// extern "C" guards. Must be included last and wrapped, or every\n'
       '// lua_* symbol in this file gets C++ linkage and the link fails.\n'
       'extern "C" {\n#include <luajit.h>\n}\n'
     + s[eol + 1:])
open(path, 'w', encoding='utf-8', errors='surrogateescape').write(s)
print("PASS: repaired the surviving source in place (removed %d bad include(s))." % n)
PYSRC

docker exec -i "$C" bash -lc "
set -euo pipefail
find /root/openmw-0.51-tsp-build -type f -name 'camerabindings.cpp.o' -print -delete 2>/dev/null || true
find /root/openmw-0.51-tsp-build -type f -name 'interiorvisibility.cpp.o' -print -delete 2>/dev/null || true
echo 'PASS: stale objects cleared.'
"

echo
echo "=================================================================="
echo "STEP 3/3  RERUN THE V13 INSTALLER"
echo "=================================================================="
exec bash "$INST"
