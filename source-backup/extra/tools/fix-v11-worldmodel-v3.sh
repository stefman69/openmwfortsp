#!/usr/bin/env bash
# fix-v11-worldmodel-v3.sh
#
# The API is now known from the recon dump, so this script does NOT guess.
#
#   apps/openmw/mwbase/environment.hpp:101
#       Misc::NotNullPtr<MWWorld::WorldModel> getWorldModel() const;
#   apps/openmw/mwworld/worldmodel.hpp:62
#       CellStore& getInterior(std::string_view name, bool forceLoad = true) const;
#   apps/openmw/mwworld/livecellref.hpp:75
#       bool isDeleted() const;
#   apps/openmw/mwworld/cellstore.hpp:200
#       void load();
#
# So the broken line
#     = MWBase::Environment::get().getWorld()->getWorldModel().getInterior(tspName);
# becomes
#     = MWBase::Environment::get().getWorldModel()->getInterior(tspName);
# NotNullPtr has operator->, which is exactly how the rest of the tree uses it
# (mwgui/hud.cpp:550, mwmechanics/summoning.cpp:119).
#
# Also adds <algorithm> (the visitor uses std::min/std::max) and
# <components/debug/debuglog.hpp> (the scanner uses Log(Debug::Warning)) to the
# injected include block, so neither can be a second build stop.
set -Eeuo pipefail

C="${TSP_BUILDER:-openmw_builder}"
SRC="/root/openmw-0.51-tsp-src"
BUILD="/root/openmw-0.51-tsp-build"
RMGR="$SRC/apps/openmw/mwrender/renderingmanager.cpp"
INST="${1:-$HOME/Downloads/apply_openmw51_tsp_interior_visgrid_v11_interior_map.sh}"

EXPR='MWBase::Environment::get().getWorldModel()->getInterior(tspName)'

test -f "$INST" || { echo "ERROR: installer not found at $INST"; exit 2; }
command -v docker >/dev/null
if [ "$(docker inspect -f '{{.State.Running}}' "$C" 2>/dev/null)" != "true" ]; then
    docker start "$C" >/dev/null
fi

echo "=================================================================="
echo "STEP 1/5  CONFIRM THE API IS WHAT THE RECON DUMP SHOWED"
echo "=================================================================="
docker exec -i "$C" bash -s <<'DOCK'
set -euo pipefail
SRC=/root/openmw-0.51-tsp-src
fail=0
chk() { # file  pattern  label
    if grep -qE "$2" "$1"; then
        echo "  OK   $3"
        grep -nE "$2" "$1" | head -2 | sed 's/^/       /'
    else
        echo "  FAIL $3   (pattern: $2)"
        fail=1
    fi
}
chk $SRC/apps/openmw/mwbase/environment.hpp \
    'NotNullPtr<MWWorld::WorldModel>[[:space:]]+getWorldModel' \
    'Environment::getWorldModel() -> NotNullPtr<WorldModel>'
chk $SRC/apps/openmw/mwworld/worldmodel.hpp \
    'CellStore&[[:space:]]+getInterior[[:space:]]*\([[:space:]]*std::string_view' \
    'WorldModel::getInterior(std::string_view) -> CellStore&'
chk $SRC/apps/openmw/mwworld/livecellref.hpp \
    'bool[[:space:]]+isDeleted[[:space:]]*\([[:space:]]*\)' \
    'LiveCellRefBase::isDeleted()'
chk $SRC/apps/openmw/mwworld/cellstore.hpp \
    'void[[:space:]]+load[[:space:]]*\([[:space:]]*\)' \
    'CellStore::load()'
chk $SRC/apps/openmw/mwrender/renderingmanager.cpp \
    'void RenderingManager::update\(float dt, bool paused\)' \
    'RenderingManager::update anchor'
chk $SRC/apps/openmw/mwrender/renderingmanager.cpp \
    'TSP_INTERIOR_VISGRID_051_V1' \
    'V1 bridge still in source'
test "$fail" -eq 0
echo "PASS: API matches the recon dump."
DOCK

echo
echo "=================================================================="
echo "STEP 2/5  REWRITE THE INSTALLER'S C++ PAYLOAD"
echo "=================================================================="
cp -p "$INST" "$INST.bak-v3-$(date +%Y%m%d-%H%M%S)"

TSP_EXPR="$EXPR" python3 - "$INST" <<'PYFIX'
import os, re, sys

path = sys.argv[1]
expr = os.environ['TSP_EXPR']
b = open(path, encoding='utf-8', errors='surrogateescape').read()
changed = 0

# ---- 1. the accessor -----------------------------------------------------
if 'TSP_SCAN_ACCESSOR_FIXED' in b:
    print("NOTE: accessor already fixed; skipping.")
else:
    anchor = re.compile(
        r'[ \t]*MWWorld::CellStore& tspCell\r?\n'
        r'[ \t]*= MWBase::Environment::get\(\)(?:->|\.)getWorld\(\)(?:->|\.)'
        r'getWorldModel\(\)(?:->|\.)getInterior\(\r?\n'
        r'[ \t]*tspName\);\r?\n')
    hits = anchor.findall(b)
    if len(hits) != 1:
        raise SystemExit("ERROR: expected exactly 1 accessor anchor, found %d" % len(hits))
    pad = ' ' * 28
    new = (pad + '// TSP_SCAN_ACCESSOR_FIXED\n'
           + pad + 'MWWorld::CellStore& tspCell = ' + expr + ';\n'
           + pad + 'tspCell.load();\n')
    b = anchor.sub(new, b, count=1)
    changed += 1
    print("PASS: accessor rewritten ->", expr)

# ---- 2. the include block ------------------------------------------------
inc_old = '#include <fstream>'
inc_new = '#include <fstream>\n#include <algorithm>\n#include <components/debug/debuglog.hpp>'
if '#include <components/debug/debuglog.hpp>' in b:
    print("NOTE: extra includes already present; skipping.")
else:
    n = b.count(inc_old)
    if n != 1:
        raise SystemExit("ERROR: expected exactly 1 '#include <fstream>' in the payload, found %d" % n)
    b = b.replace(inc_old, inc_new, 1)
    changed += 1
    print("PASS: added <algorithm> + debuglog.hpp to the injected includes.")

if changed:
    open(path, 'w', encoding='utf-8', errors='surrogateescape').write(b)

# ---- 3. postconditions ---------------------------------------------------
b2 = open(path, encoding='utf-8', errors='surrogateescape').read()
assert 'TSP_SCAN_ACCESSOR_FIXED' in b2
assert 'getWorld()->getWorldModel()' not in b2, "old broken accessor still present"
for needle in ("TSP_INTERIOR_SCAN_051_V1 begin", "tsp_interior_scan_cells.txt",
               "tsp_interior_scan.txt", "TspScanVisitor",
               "#include <components/debug/debuglog.hpp>"):
    assert needle in b2, "installer lost/never got: " + needle
print("PASS: installer postconditions hold.")
PYFIX

bash -n "$INST"
echo "PASS: installer still parses."

echo
echo "=================================================================="
echo "STEP 3/5  REPAIR THE CONTAINER SOURCE IF THE BAD BLOCK SURVIVED"
echo "=================================================================="
docker exec -i -e TSP_EXPR="$EXPR" "$C" python3 - "$RMGR" <<'PYSRC'
import os, re, sys, shutil, time

path = sys.argv[1]
expr = os.environ['TSP_EXPR']
b = open(path, encoding='utf-8', errors='surrogateescape').read()

if 'TSP_INTERIOR_SCAN_051_V1' not in b:
    print("PASS: container source is clean (scanner rolled back); nothing to repair.")
    sys.exit(0)
if 'TSP_SCAN_ACCESSOR_FIXED' in b:
    print("PASS: container source already carries the fixed accessor.")
    sys.exit(0)

anchor = re.compile(
    r'[ \t]*MWWorld::CellStore& tspCell\r?\n'
    r'[ \t]*= MWBase::Environment::get\(\)(?:->|\.)getWorld\(\)(?:->|\.)'
    r'getWorldModel\(\)(?:->|\.)getInterior\(\r?\n'
    r'[ \t]*tspName\);\r?\n')
hits = anchor.findall(b)
if len(hits) != 1:
    raise SystemExit("ERROR: scanner present but accessor anchor count=%d - stop and report." % len(hits))

shutil.copy2(path, path + '.bak-v3-' + time.strftime('%Y%m%d-%H%M%S'))
pad = ' ' * 28
new = (pad + '// TSP_SCAN_ACCESSOR_FIXED\n'
       + pad + 'MWWorld::CellStore& tspCell = ' + expr + ';\n'
       + pad + 'tspCell.load();\n')
b = anchor.sub(new, b, count=1)
if '#include <components/debug/debuglog.hpp>' not in b:
    b = b.replace('#include <fstream>',
                  '#include <fstream>\n#include <algorithm>\n#include <components/debug/debuglog.hpp>', 1)
open(path, 'w', encoding='utf-8', errors='surrogateescape').write(b)
print("PASS: container source repaired in place (backup kept beside it).")
PYSRC

echo
echo "=================================================================="
echo "STEP 4/5  CLEAR THE STALE OBJECT"
echo "=================================================================="
docker exec -i "$C" bash -lc "
set -euo pipefail
find '$BUILD' -type f -name 'renderingmanager.cpp.o' -print -delete 2>/dev/null || true
echo 'PASS: renderingmanager object cleared.'
"

echo
echo "=================================================================="
echo "STEP 5/5  RERUN THE V11 INSTALLER"
echo "=================================================================="
exec bash "$INST"
