#!/usr/bin/env bash
# fix-v11-worldmodel-v2.sh
#
# v1 FAILED because it ran `docker exec` WITHOUT -i, so every heredoc was
# discarded at EOF and the probe produced nothing. Fixed here; every container
# call that reads stdin now uses `docker exec -i`.
#
# PHASE A: full recon dump of the cell/WorldModel API in the container,
#          written to ~/tsp_worldmodel_dump.txt with a self-check line.
# PHASE B: auto-detect the correct accessor. If confident, rewrite the V11
#          installer payload + repair the container source + clear the stale
#          object + rerun the installer. If not confident, STOP and tell you
#          to attach the dump. Nothing is changed before detection succeeds.
set -Eeuo pipefail

C="${TSP_BUILDER:-openmw_builder}"
SRC="/root/openmw-0.51-tsp-src"
BUILD="/root/openmw-0.51-tsp-build"
RMGR="$SRC/apps/openmw/mwrender/renderingmanager.cpp"
INST="${1:-$HOME/Downloads/apply_openmw51_tsp_interior_visgrid_v11_interior_map.sh}"
TOOLS="$HOME/Downloads/visgrid-tools"
mkdir -p "$TOOLS"
D="$HOME/tsp_worldmodel_dump.txt"
: > "$D"

test -f "$INST" || { echo "ERROR: installer not found at $INST"; exit 2; }
command -v docker >/dev/null
if [ "$(docker inspect -f '{{.State.Running}}' "$C" 2>/dev/null)" != "true" ]; then
    docker start "$C" >/dev/null
fi

{
echo "########## TSP WORLDMODEL RECON - $(date) ##########"
echo "container=$C  src=$SRC"

docker exec -i "$C" bash -s <<'DOCK'
SRC=/root/openmw-0.51-tsp-src
BUILD=/root/openmw-0.51-tsp-build

full() {
  if [ ! -f "$1" ]; then echo "!! MISSING FILE: $1"; return 0; fi
  echo "########## FULL: $1 ($(wc -l < "$1") lines) ##########"
  cat -n "$1"
}
w() {
  F="$1"; P="$2"; A=${3:-3}; Z=${4:-25}; M=${5:-8}
  if [ ! -f "$F" ]; then echo "!! MISSING FILE: $F"; return 0; fi
  echo "----- windows: $F  pattern=[$P] -----"
  grep -nE "$P" "$F" | head -$M
  for L in $(grep -nE "$P" "$F" | head -$M | cut -d: -f1); do
    S=$((L-A)); if [ $S -lt 1 ]; then S=1; fi
    E=$((L+Z))
    echo "--- $F lines $S..$E ---"
    sed -n "${S},${E}p" "$F" | nl -ba -v$S -w6 -s"| "
  done
}

echo "########## SECTION 0: environment ##########"
echo "python3: $(command -v python3 || echo MISSING) $(python3 -V 2>&1)"
for f in \
  $SRC/apps/openmw/mwbase/environment.hpp \
  $SRC/apps/openmw/mwbase/world.hpp \
  $SRC/apps/openmw/mwworld/worldmodel.hpp \
  $SRC/apps/openmw/mwworld/cellstore.hpp \
  $SRC/apps/openmw/mwworld/livecellref.hpp \
  $SRC/apps/openmw/mwworld/ptr.hpp \
  $SRC/apps/openmw/mwrender/renderingmanager.cpp ; do
  if [ -f "$f" ]; then echo "  $(wc -l < "$f") lines  $f"; else echo "  MISSING  $f"; fi
done
echo "-- scanner currently in source? --"
if grep -Fq 'TSP_INTERIOR_SCAN_051_V1' $SRC/apps/openmw/mwrender/renderingmanager.cpp; then
  echo "  YES - the failed build was NOT rolled back; source still carries the scanner."
else
  echo "  NO - source was rolled back to pre-V11 (clean)."
fi
if grep -Fq 'TSP_SCAN_ACCESSOR_FIXED' $SRC/apps/openmw/mwrender/renderingmanager.cpp; then
  echo "  NOTE: source already carries TSP_SCAN_ACCESSOR_FIXED."
fi
echo "-- every getWorldModel declaration/use in apps/openmw --"
grep -rn "getWorldModel" $SRC/apps/openmw | head -25
echo "-- where class WorldModel is declared --"
grep -rn "class WorldModel" $SRC/apps/openmw | head -5

echo "########## SECTION 1: mwbase/environment.hpp (FULL) ##########"
full $SRC/apps/openmw/mwbase/environment.hpp

echo "########## SECTION 2: mwworld/worldmodel.hpp (FULL) ##########"
full $SRC/apps/openmw/mwworld/worldmodel.hpp

echo "########## SECTION 3: mwbase/world.hpp - cell lookup surface ##########"
w $SRC/apps/openmw/mwbase/world.hpp "getWorldModel|getInterior|getExterior|CellStore" 2 8 12

echo "########## SECTION 4: mwworld/cellstore.hpp - load/forEach/state ##########"
grep -nE "class CellStore|void load|void preload|forEach|getState|State_|isExterior|getCell\(" $SRC/apps/openmw/mwworld/cellstore.hpp | head -40
w $SRC/apps/openmw/mwworld/cellstore.hpp "bool forEach" 4 30 2
w $SRC/apps/openmw/mwworld/cellstore.hpp "void load\(" 3 12 2

echo "########## SECTION 5: mwworld/livecellref.hpp - isDeleted surface ##########"
grep -nE "class LiveCellRefBase|struct LiveCellRefBase|isDeleted|mData|mRef" $SRC/apps/openmw/mwworld/livecellref.hpp | head -30

echo "########## SECTION 6: mwworld/ptr.hpp (FULL) ##########"
full $SRC/apps/openmw/mwworld/ptr.hpp

echo "########## SECTION 7: ESM record-name ints (REC_STAT etc.) ##########"
grep -rn "REC_STAT" $SRC/components/esm $SRC/components/esm3 2>/dev/null | head -8
echo "-- defs.hpp candidates --"
ls -1 $SRC/components/esm/defs.hpp $SRC/components/esm3/*.hpp 2>/dev/null | head -5
grep -rnE "REC_DOOR|REC_LIGH|REC_NPC_|REC_CREA|REC_LEVC" $SRC/components/esm/defs.hpp 2>/dev/null | head -8

echo "########## SECTION 8: renderingmanager.cpp - current scanner / line 943 region ##########"
if grep -Fq 'TSP_INTERIOR_SCAN_051_V1' $SRC/apps/openmw/mwrender/renderingmanager.cpp; then
  w $SRC/apps/openmw/mwrender/renderingmanager.cpp "TSP_INTERIOR_SCAN_051_V1" 2 20 2
  w $SRC/apps/openmw/mwrender/renderingmanager.cpp "MWWorld::CellStore& tspCell" 3 8 2
else
  echo "(scanner absent - showing RenderingManager::update anchor instead)"
  w $SRC/apps/openmw/mwrender/renderingmanager.cpp "void RenderingManager::update" 2 12 2
fi
echo "-- includes already present --"
grep -nE "#include .*(worldmodel|cellstore|ptr|environment|esm/defs)" $SRC/apps/openmw/mwrender/renderingmanager.cpp | head -15

echo "########## SECTION 9: AUTO-DETECT ##########"
python3 - "$SRC" <<'PYDET'
import re, sys, os

SRC = sys.argv[1]

def rd(rel):
    try:
        return open(os.path.join(SRC, rel), encoding='utf-8', errors='replace').read()
    except Exception:
        return ""

env   = rd('apps/openmw/mwbase/environment.hpp')
world = rd('apps/openmw/mwbase/world.hpp')
wm    = rd('apps/openmw/mwworld/worldmodel.hpp')
cs    = rd('apps/openmw/mwworld/cellstore.hpp')
lcr   = rd('apps/openmw/mwworld/livecellref.hpp')

# 1. how to reach the WorldModel object
access = None
m = re.search(r'WorldModel\s*(\*|&)\s*getWorldModel\s*\(', env)
if m:
    access = ("MWBase::Environment::get().getWorldModel()",
              "->" if m.group(1) == "*" else ".")
if access is None:
    m = re.search(r'WorldModel\s*(\*|&)\s*getWorldModel\s*\(', world)
    if m:
        access = ("MWBase::Environment::get().getWorld()->getWorldModel()",
                  "->" if m.group(1) == "*" else ".")

expr = None
if access is not None:
    base, arrow = access
    m = re.search(r'CellStore\s*(\*|&)\s*getInterior\s*\(', wm)
    if m:
        expr = ("*" if m.group(1) == "*" else "") + base + arrow + "getInterior(tspName)"
    else:
        m = re.search(r'CellStore\s*(\*|&)\s*getCell\s*\(\s*(?:const\s+)?std::(?:string_view|string)', wm)
        if m:
            expr = ("*" if m.group(1) == "*" else "") + base + arrow + "getCell(tspName)"

# fallback: MWBase::World::getInterior
if expr is None:
    m = re.search(r'CellStore\s*(\*|&)\s*getInterior\s*\(', world)
    if m:
        expr = ("*" if m.group(1) == "*" else "") \
             + "MWBase::Environment::get().getWorld()->getInterior(tspName)"

load = 1 if re.search(r'\bvoid\s+load\s*\(\s*\)', cs) else 0
deleted = "ptr.mRef->isDeleted()" if re.search(r'bool\s+isDeleted\s*\(\s*\)', lcr) \
          else "ptr.getRefData().isDeleted()"

if expr is None:
    print("TSP_RESULT=UNDECIDED")
else:
    print("TSP_RESULT=OK")
    print("TSP_EXPR=%s" % expr)
    print("TSP_LOAD=%d" % load)
    print("TSP_DELETED=%s" % deleted)
PYDET

echo "########## SECTIONS EMITTED: 9 ##########"
DOCK
} 2>&1 | tee -a "$D"

echo
if ! grep -q "SECTIONS EMITTED: 9" "$D"; then
    echo "=================================================================="
    echo "DUMP SELF-CHECK FAILED - the container section produced nothing"
    echo "($(wc -l < "$D") lines total). Nothing was changed."
    echo "Paste the output above so the fault is visible."
    echo "=================================================================="
    exit 6
fi
cp -f "$D" "$TOOLS/tsp_worldmodel_dump.txt" 2>/dev/null || true
echo "DUMP SELF-CHECK OK ($(wc -l < "$D") lines) -> $D"

if ! grep -q '^TSP_RESULT=OK' "$D"; then
    echo
    echo "=================================================================="
    echo "STOPPED: could not identify the accessor automatically."
    echo "NOTHING WAS CHANGED. Attach this file:"
    echo "  $D"
    echo "=================================================================="
    exit 7
fi

EXPR="$(sed -n 's/^TSP_EXPR=//p' "$D" | head -1)"
LOAD="$(sed -n 's/^TSP_LOAD=//p' "$D" | head -1)"
DELETED="$(sed -n 's/^TSP_DELETED=//p' "$D" | head -1)"

echo
echo "=================================================================="
echo "DETECTED"
echo "=================================================================="
echo "  interior accessor  : $EXPR"
echo "  CellStore::load()  : $LOAD"
echo "  deleted-ref test   : $DELETED"

echo
echo "=================================================================="
echo "PHASE B1  REWRITE THE INSTALLER'S C++ PAYLOAD"
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

if 'TSP_SCAN_ACCESSOR_FIXED' in b:
    print("NOTE: installer already carries the fixed accessor; leaving as is.")
    sys.exit(0)

anchor = re.compile(
    r'[ \t]*MWWorld::CellStore& tspCell\r?\n'
    r'[ \t]*= MWBase::Environment::get\(\)(?:->|\.)getWorld\(\)(?:->|\.)'
    r'getWorldModel\(\)(?:->|\.)getInterior\(\r?\n'
    r'[ \t]*tspName\);\r?\n')
hits = anchor.findall(b)
if len(hits) != 1:
    raise SystemExit("ERROR: expected exactly 1 accessor anchor in the installer, found %d" % len(hits))

pad = ' ' * 28
new = pad + '// TSP_SCAN_ACCESSOR_FIXED\n'
new += pad + 'MWWorld::CellStore& tspCell = ' + expr + ';\n'
if load:
    new += pad + 'tspCell.load();\n'
b = anchor.sub(new, b, count=1)

if deleted != 'ptr.mRef->isDeleted()':
    old = 'if (ptr.mRef == nullptr || ptr.mRef->isDeleted())'
    if old in b:
        b = b.replace(old, 'if (ptr.mRef == nullptr || %s)' % deleted, 1)
        print("NOTE: deleted-ref test rewritten to %s" % deleted)

open(path, 'w', encoding='utf-8', errors='surrogateescape').write(b)

b2 = open(path, encoding='utf-8', errors='surrogateescape').read()
assert 'TSP_SCAN_ACCESSOR_FIXED' in b2
for needle in ("TSP_INTERIOR_SCAN_051_V1 begin", "tsp_interior_scan_cells.txt",
               "tsp_interior_scan.txt", "TspScanVisitor"):
    assert needle in b2, "installer lost its own postcondition needle: " + needle
print("PASS: installer payload rewritten.")
print("      MWWorld::CellStore& tspCell = %s;" % expr)
if load:
    print("      tspCell.load();")
PYFIX

bash -n "$INST"
echo "PASS: installer still parses."

echo
echo "=================================================================="
echo "PHASE B2  REPAIR THE CONTAINER SOURCE IF THE BAD BLOCK SURVIVED"
echo "=================================================================="
docker exec -i -e TSP_EXPR="$EXPR" -e TSP_LOAD="$LOAD" -e TSP_DELETED="$DELETED" \
    "$C" python3 - "$RMGR" <<'PYSRC'
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
    r'[ \t]*= MWBase::Environment::get\(\)(?:->|\.)getWorld\(\)(?:->|\.)'
    r'getWorldModel\(\)(?:->|\.)getInterior\(\r?\n'
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
docker exec -i "$C" bash -lc "
set -euo pipefail
find '$BUILD' -type f -name 'renderingmanager.cpp.o' -print -delete 2>/dev/null || true
echo 'PASS: renderingmanager object cleared.'
"

echo
echo "=================================================================="
echo "PHASE B3  RERUN THE V11 INSTALLER"
echo "=================================================================="
exec bash "$INST"
