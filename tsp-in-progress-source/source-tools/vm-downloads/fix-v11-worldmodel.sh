#!/usr/bin/env bash
# fix-v11-worldmodel.sh
#
# The V11 installer's interior-scanner patch calls
#     MWBase::Environment::get().getWorld()->getWorldModel().getInterior(name)
# which does not exist in this 0.51 tree (MWBase::World has no getWorldModel).
#
# This script:
#   1. PROBES the container source for the real declarations and prints them
#      (also saved to ~/Downloads/visgrid-tools/worldmodel-probe.txt).
#   2. Picks the correct accessor form automatically.
#   3. Rewrites the V11 installer's embedded C++ payload in place (backup kept).
#   4. Reruns the V11 installer end to end.
#
# If the probe cannot decide, it stops BEFORE touching anything and prints the
# declarations to send back.
set -Eeuo pipefail

C="${TSP_BUILDER:-openmw_builder}"
SRC="/root/openmw-0.51-tsp-src"
INST="${1:-$HOME/Downloads/apply_openmw51_tsp_interior_visgrid_v11_interior_map.sh}"
TOOLS="$HOME/Downloads/visgrid-tools"
mkdir -p "$TOOLS"
PROBE="$TOOLS/worldmodel-probe.txt"

test -f "$INST" || { echo "ERROR: installer not found at $INST"; exit 2; }

command -v docker >/dev/null
if [ "$(docker inspect -f '{{.State.Running}}' "$C" 2>/dev/null)" != "true" ]; then
    docker start "$C" >/dev/null
fi

echo "=================================================================="
echo "STEP 1/4  PROBE THE 0.51 SOURCE FOR THE REAL WorldModel API"
echo "=================================================================="

docker exec "$C" python3 - "$SRC" <<'PYPROBE' 2>&1 | tee "$PROBE"
import re, sys, os

SRC = sys.argv[1]

def rd(rel):
    p = os.path.join(SRC, rel)
    try:
        return open(p, encoding='utf-8', errors='replace').read()
    except Exception as e:
        return ""

FILES = {
    'env':   'apps/openmw/mwbase/environment.hpp',
    'world': 'apps/openmw/mwbase/world.hpp',
    'wm':    'apps/openmw/mwworld/worldmodel.hpp',
    'cs':    'apps/openmw/mwworld/cellstore.hpp',
    'lcr':   'apps/openmw/mwworld/livecellref.hpp',
    'ptr':   'apps/openmw/mwworld/ptr.hpp',
}
T = {k: rd(v) for k, v in FILES.items()}

print("----- declarations found -----")
for key, rel in FILES.items():
    if not T[key]:
        print("MISSING FILE: %s" % rel)
        continue
    for i, line in enumerate(T[key].splitlines(), 1):
        if re.search(r'getWorldModel|getInterior\s*\(|CellStore&?\*?\s+getCell\s*\(|'
                     r'\bvoid\s+load\s*\(|\bisDeleted\s*\(|\bgetType\s*\(', line):
            print("%-14s %5d: %s" % (os.path.basename(rel), i, line.strip()))
print("------------------------------")

# ---- 1. how to reach the WorldModel object -------------------------------
access = None
m = re.search(r'WorldModel\s*(\*|&)\s*getWorldModel\s*\(', T['env'])
if m:
    access = ("MWBase::Environment::get().getWorldModel()",
              "->" if m.group(1) == "*" else ".")
if access is None:
    m = re.search(r'WorldModel\s*(\*|&)\s*getWorldModel\s*\(', T['world'])
    if m:
        access = ("MWBase::Environment::get().getWorld()->getWorldModel()",
                  "->" if m.group(1) == "*" else ".")

expr = None
# ---- 2. the interior lookup ----------------------------------------------
if access is not None:
    base, arrow = access
    m = re.search(r'CellStore\s*(\*|&)\s*getInterior\s*\(', T['wm'])
    if m:
        deref = "*" if m.group(1) == "*" else ""
        expr = "%s%s%sgetInterior(tspName)" % (deref, base, arrow)
    else:
        m = re.search(r'CellStore\s*(\*|&)\s*getCell\s*\(\s*(?:const\s+)?std::(?:string_view|string)', T['wm'])
        if m:
            deref = "*" if m.group(1) == "*" else ""
            expr = "%s%s%sgetCell(tspName)" % (deref, base, arrow)

# ---- 3. fallback: MWBase::World::getInterior -------------------------------
if expr is None:
    m = re.search(r'CellStore\s*(\*|&)\s*getInterior\s*\(', T['world'])
    if m:
        deref = "*" if m.group(1) == "*" else ""
        expr = "%sMWBase::Environment::get().getWorld()->getInterior(tspName)" % deref

# ---- 4. does CellStore expose load()? -------------------------------------
load = 1 if re.search(r'\bvoid\s+load\s*\(\s*\)', T['cs']) else 0

# ---- 5. is isDeleted() on LiveCellRefBase, or only on RefData? ------------
if re.search(r'bool\s+isDeleted\s*\(\s*\)', T['lcr']):
    deleted = "ptr.mRef->isDeleted()"
else:
    deleted = "ptr.getRefData().isDeleted()"

print()
if expr is None:
    print("TSP_RESULT=UNDECIDED")
    print("Could not identify the interior-cell accessor in this tree.")
    sys.exit(7)

print("TSP_RESULT=OK")
print("TSP_EXPR=%s" % expr)
print("TSP_LOAD=%d" % load)
print("TSP_DELETED=%s" % deleted)
PYPROBE

grep -q '^TSP_RESULT=OK' "$PROBE" || {
    echo
    echo "=================================================================="
    echo "STOPPED: could not identify the API automatically."
    echo "Nothing was changed. Send this file back:"
    echo "  $PROBE"
    echo "=================================================================="
    exit 7
}

EXPR="$(sed -n 's/^TSP_EXPR=//p' "$PROBE" | head -1)"
LOAD="$(sed -n 's/^TSP_LOAD=//p' "$PROBE" | head -1)"
DELETED="$(sed -n 's/^TSP_DELETED=//p' "$PROBE" | head -1)"

echo
echo "Chosen interior accessor : $EXPR"
echo "CellStore::load() present: $LOAD"
echo "Deleted-ref test         : $DELETED"

echo
echo "=================================================================="
echo "STEP 2/4  REWRITE THE INSTALLER'S C++ PAYLOAD"
echo "=================================================================="

cp -p "$INST" "$INST.bak-worldmodel-$(date +%Y%m%d-%H%M%S)"

TSP_EXPR="$EXPR" TSP_LOAD="$LOAD" TSP_DELETED="$DELETED" \
python3 - "$INST" <<'PYFIX'
import os, re, sys

path = sys.argv[1]
expr = os.environ['TSP_EXPR']
load = os.environ['TSP_LOAD'] == '1'
deleted = os.environ['TSP_DELETED']

b = open(path, encoding='utf-8', errors='surrogateescape').read()

# The installer may have arrived with CRLF; match either.
anchor = re.compile(
    r'[ \t]*MWWorld::CellStore& tspCell\r?\n'
    r'[ \t]*= MWBase::Environment::get\(\)(?:->|\.)getWorld\(\)(?:->|\.)getWorldModel\(\)(?:->|\.)getInterior\(\r?\n'
    r'[ \t]*tspName\);\r?\n')

hits = anchor.findall(b)
if len(hits) != 1:
    # already fixed?
    if 'TSP_SCAN_ACCESSOR_FIXED' in b:
        print("NOTE: installer already carries the fixed accessor; leaving as is.")
        sys.exit(0)
    raise SystemExit("ERROR: expected exactly 1 getWorldModel anchor, found %d" % len(hits))

pad = ' ' * 28
new = pad + '// TSP_SCAN_ACCESSOR_FIXED\n'
new += pad + 'MWWorld::CellStore& tspCell = ' + expr + ';\n'
if load:
    new += pad + 'tspCell.load();\n'

b = anchor.sub(new, b, count=1)

# deleted-ref test
if deleted != 'ptr.mRef->isDeleted()':
    old = 'if (ptr.mRef == nullptr || ptr.mRef->isDeleted())'
    if old in b:
        b = b.replace(old, 'if (ptr.mRef == nullptr || %s)' % deleted, 1)
        print("NOTE: deleted-ref test rewritten to %s" % deleted)

open(path, 'w', encoding='utf-8', errors='surrogateescape').write(b)

# postconditions
b2 = open(path, encoding='utf-8', errors='surrogateescape').read()
assert 'TSP_SCAN_ACCESSOR_FIXED' in b2
for needle in ("TSP_INTERIOR_SCAN_051_V1 begin", "tsp_interior_scan_cells.txt",
               "tsp_interior_scan.txt", "TspScanVisitor"):
    assert needle in b2, "installer lost its own postcondition needle: " + needle
print("PASS: installer payload rewritten.")
print("      new line: MWWorld::CellStore& tspCell = %s;" % expr)
if load:
    print("      plus:     tspCell.load();")
PYFIX

bash -n "$INST"
echo "PASS: installer still parses."

echo
echo "=================================================================="
echo "STEP 3/4  REPAIR THE CONTAINER SOURCE IF THE BAD BLOCK SURVIVED"
echo "=================================================================="
# If the failed build did NOT get auto-restored, renderingmanager.cpp still
# carries the broken scanner. The installer would then call the rerun
# "idempotent" and never re-patch it. Fix it in place here.
docker exec -e TSP_EXPR="$EXPR" -e TSP_LOAD="$LOAD" -e TSP_DELETED="$DELETED" \
    "$C" python3 - "$SRC/apps/openmw/mwrender/renderingmanager.cpp" <<'PYSRC'
import os, re, sys, shutil, time
path = sys.argv[1]
expr = os.environ['TSP_EXPR']
load = os.environ['TSP_LOAD'] == '1'
deleted = os.environ['TSP_DELETED']
b = open(path, encoding='utf-8', errors='surrogateescape').read()

if 'TSP_INTERIOR_SCAN_051_V1' not in b:
    print("PASS: container source is clean (scanner was rolled back); nothing to repair.")
    sys.exit(0)
if 'TSP_SCAN_ACCESSOR_FIXED' in b:
    print("PASS: container source already carries the fixed accessor.")
    sys.exit(0)

anchor = re.compile(
    r'[ \t]*MWWorld::CellStore& tspCell\r?\n'
    r'[ \t]*= MWBase::Environment::get\(\)(?:->|\.)getWorld\(\)(?:->|\.)getWorldModel\(\)(?:->|\.)getInterior\(\r?\n'
    r'[ \t]*tspName\);\r?\n')
hits = anchor.findall(b)
if len(hits) != 1:
    raise SystemExit("ERROR: scanner present but accessor anchor count=%d - stop and report." % len(hits))

shutil.copy2(path, path + '.bak-worldmodel-' + time.strftime('%Y%m%d-%H%M%S'))
pad = ' ' * 28
new = pad + '// TSP_SCAN_ACCESSOR_FIXED\n'
new += pad + 'MWWorld::CellStore& tspCell = ' + expr + ';\n'
if load:
    new += pad + 'tspCell.load();\n'
b = anchor.sub(new, b, count=1)
if deleted != 'ptr.mRef->isDeleted()':
    b = b.replace('if (ptr.mRef == nullptr || ptr.mRef->isDeleted())',
                  'if (ptr.mRef == nullptr || %s)' % deleted, 1)
open(path, 'w', encoding='utf-8', errors='surrogateescape').write(b)
print("PASS: container source repaired in place (backup kept beside it).")
PYSRC

echo
echo "Clearing the stale object so the rebuild is honest."
docker exec "$C" bash -lc "
set -euo pipefail
find /root/openmw-0.51-tsp-build -type f -name 'renderingmanager.cpp.o' -print -delete 2>/dev/null || true
echo 'PASS: renderingmanager object cleared.'
"

echo
echo "=================================================================="
echo "STEP 4/4  RERUN THE V11 INSTALLER"
echo "=================================================================="
exec bash "$INST"
