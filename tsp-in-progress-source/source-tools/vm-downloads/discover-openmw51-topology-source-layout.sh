#!/usr/bin/env bash
set -Eeuo pipefail

cd "$HOME/Downloads"

CTR="${TSP_BUILDER:-openmw_builder}"
SRC="/root/openmw-0.51-tsp-src"

STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="$HOME/Downloads/openmw51-topology-source-discovery-$STAMP.txt"

exec > >(tee "$OUT") 2>&1

echo "======================================================================"
echo "OPENMW 0.51 TOPOLOGY SOURCE DISCOVERY"
echo "======================================================================"
echo "READ ONLY."
echo "No source edits."
echo "No builds."
echo "No DB access."
echo "No runtime changes."
echo
echo "Purpose:"
echo "  Discover actual file locations from symbols first."
echo "  Never assume filenames/directories."
echo "======================================================================"

if [ "$(docker inspect -f '{{.State.Running}}' "$CTR" 2>/dev/null || true)" != "true" ]; then
    docker start "$CTR" >/dev/null
fi

echo
echo "######################################################################"
echo "# 1 — ACTUAL NAVMESHTOOL DIRECTORY TREE"
echo "######################################################################"

docker exec "$CTR" bash -lc "
echo '----- apps/navmeshtool -----'
find '$SRC/apps/navmeshtool' \
  -maxdepth 3 \
  -type f \
  -printf '%p\n' 2>/dev/null | sort

echo
echo '----- components/detournavigator -----'
find '$SRC/components/detournavigator' \
  -maxdepth 2 \
  -type f \
  -printf '%p\n' 2>/dev/null | sort
"

echo
echo "######################################################################"
echo "# 2 — SYMBOL-DRIVEN SEARCH ACROSS ENTIRE SOURCE TREE"
echo "######################################################################"

docker exec -i "$CTR" python3 - "$SRC" <<'PY'
from pathlib import Path
import re
import sys

src = Path(sys.argv[1])

# Search the filesystem directly rather than git-grep because this source tree
# contains relevant untracked files.
extensions = {
    ".cpp", ".cc", ".cxx", ".c",
    ".hpp", ".hh", ".hxx", ".h",
    ".ipp", ".inl", ".tpp",
    ".cmake", ".txt",
}

special_names = {"CMakeLists.txt"}

symbols = [
    "generateAllNavMeshTiles",
    "GenerateAllNavMeshTilesOptions",
    "GenerateTilesResult",
    "GenerateTilesStats",
    "enum class Status",
    "Status::Ok",
    "Status::Cancelled",
    "Status::NotEnoughSpace",
    "makeNavMeshTileData",
    "prepareNavMeshTileData",
    "PreparedNavMeshData",
    "NavMeshData",
    "NavMeshDb::insertTile",
    "NavMeshDb::updateTile",
    "NavMeshDb::getTileData",
    "NavMeshDb db",
    "serialize(const PreparedNavMeshData",
    "deserialize(",
    "Misc::compress",
    "Misc::decompress",
    "OffMeshConnection",
    "initEmptyNavMesh",
    "collectWorldspaceCells",
    "gatherWorldspaceData",
    "worldspaceCells",
    "TSP_NAVMESH_DUMP",
    "NAVMESHSET_MAGIC",
    "MSET",
]

files = []

for p in src.rglob("*"):
    if not p.is_file():
        continue
    if p.name in special_names or p.suffix.lower() in extensions:
        files.append(p)

print(f"Scannable source files: {len(files)}")
print()

all_hits = {}
matched_files = set()

for symbol in symbols:
    hits = []

    for p in files:
        try:
            text = p.read_text(encoding="utf-8", errors="surrogateescape")
        except Exception:
            continue

        for lineno, line in enumerate(text.splitlines(), 1):
            if symbol in line:
                hits.append((p, lineno, line.rstrip()))
                matched_files.add(p)

    all_hits[symbol] = hits

    print("=" * 78)
    print("SYMBOL:", symbol)
    print("=" * 78)

    if not hits:
        print("NO MATCHES")
        print()
        continue

    for p, lineno, line in hits:
        print(f"{p}:{lineno}: {line}")
    print()

print()
print("######################################################################")
print("# UNIQUE FILES DISCOVERED FROM SYMBOLS")
print("######################################################################")

for p in sorted(matched_files):
    print(p)

# Produce a conservative high-value subset for full printing.
high_value = set()

wanted_symbols = {
    "generateAllNavMeshTiles",
    "GenerateAllNavMeshTilesOptions",
    "GenerateTilesResult",
    "enum class Status",
    "makeNavMeshTileData",
    "NavMeshDb::insertTile",
    "serialize(const PreparedNavMeshData",
    "Misc::compress",
    "OffMeshConnection",
    "initEmptyNavMesh",
}

for symbol in wanted_symbols:
    for p, _, _ in all_hits.get(symbol, []):
        high_value.add(p)

print()
print("######################################################################")
print("# HIGH-VALUE FILES TO PRINT IN FULL")
print("######################################################################")

for p in sorted(high_value):
    print(p)

print()
print("######################################################################")
print("# FULL CONTENTS OF HIGH-VALUE DISCOVERED FILES")
print("######################################################################")

for p in sorted(high_value):
    try:
        lines = p.read_text(
            encoding="utf-8",
            errors="surrogateescape"
        ).splitlines()
    except Exception as exc:
        print()
        print(f"ERROR READING {p}: {exc}")
        continue

    print()
    print("=" * 78)
    print(f"FILE: {p}")
    print(f"LINES: {len(lines)}")
    print("=" * 78)

    for i, line in enumerate(lines, 1):
        print(f"{i:6d}  {line}")
PY

echo
echo "######################################################################"
echo "# 3 — FIND THE ACTUAL FILE THAT DEFINES generateAllNavMeshTiles"
echo "######################################################################"

docker exec -i "$CTR" python3 - "$SRC" <<'PY'
from pathlib import Path
import re
import sys

src = Path(sys.argv[1])

pattern = re.compile(r"\bgenerateAllNavMeshTiles\s*\(")

candidates = []

for p in src.rglob("*"):
    if not p.is_file():
        continue

    if p.suffix.lower() not in {
        ".cpp", ".cc", ".cxx", ".c",
        ".hpp", ".hh", ".hxx", ".h",
        ".ipp", ".inl", ".tpp"
    }:
        continue

    try:
        lines = p.read_text(
            encoding="utf-8",
            errors="surrogateescape"
        ).splitlines()
    except Exception:
        continue

    for i, line in enumerate(lines):
        if not pattern.search(line):
            continue

        # Print surrounding context so declaration vs definition vs call is clear.
        lo = max(0, i - 8)
        hi = min(len(lines), i + 24)
        candidates.append((p, i + 1, lines, lo, hi))

print("Occurrences:", len(candidates))

for n, (p, lineno, lines, lo, hi) in enumerate(candidates, 1):
    print()
    print("=" * 78)
    print(f"OCCURRENCE {n}: {p}:{lineno}")
    print("=" * 78)
    for j in range(lo, hi):
        marker = ">>" if j + 1 == lineno else "  "
        print(f"{marker} {j + 1:6d}  {lines[j]}")
PY

echo
echo "######################################################################"
echo "# 4 — CMAKE: WHAT FILES DOES NAVMESHTOOL ACTUALLY BUILD?"
echo "######################################################################"

docker exec "$CTR" bash -lc "
set +e

echo '----- navmeshtool CMakeLists if present -----'
find '$SRC/apps/navmeshtool' \
  -maxdepth 2 \
  -type f \
  -name 'CMakeLists.txt' \
  -print \
  -exec sh -c 'echo; nl -ba \"\$1\"' sh {} \;

echo
echo '----- every CMake reference to navmeshtool -----'
grep -RnsE \
  'navmeshtool|openmw-navmeshtool' \
  '$SRC' \
  --include='CMakeLists.txt' \
  --include='*.cmake' \
  2>/dev/null || true

echo
echo '----- build.ninja references to apps/navmeshtool -----'
grep -n \
  'apps/navmeshtool' \
  '/root/openmw-0.51-tsp-build/build.ninja' \
  2>/dev/null | head -300 || true
"

echo
echo "######################################################################"
echo "# 5 — BASENAME / FUZZY FILENAME DISCOVERY"
echo "######################################################################"

docker exec "$CTR" bash -lc "
set +e

echo 'Files whose names contain navmesh/tile/generate/status:'
find '$SRC' -type f \
  \( \
    -iname '*navmesh*' -o \
    -iname '*tile*' -o \
    -iname '*generate*' -o \
    -iname '*status*' \
  \) \
  -printf '%p\n' 2>/dev/null |
sort |
head -1200
"

echo
echo "######################################################################"
echo "# 6 — CONFIRM THIS SCAN CHANGED NOTHING"
echo "######################################################################"

docker exec "$CTR" bash -lc "
set -e

echo 'main.cpp:'
sha256sum '$SRC/apps/navmeshtool/main.cpp'

echo
echo 'normal navmeshtool:'
file '/root/openmw-0.51-tsp-build/openmw-navmeshtool'
sha256sum '/root/openmw-0.51-tsp-build/openmw-navmeshtool'

echo
if grep -q \
  'TSP_NAVMESH_TOPOLOGY_DB_EXPORT_V1' \
  '$SRC/apps/navmeshtool/main.cpp'
then
    echo 'ERROR: temporary exporter marker unexpectedly present.'
    exit 1
else
    echo 'PASS: temporary exporter marker absent.'
fi
"

echo
echo "======================================================================"
echo "DISCOVERY COMPLETE"
echo "======================================================================"
echo "Saved report:"
echo "  $OUT"
echo
echo "This scanner intentionally does NOT fail when an expected filename"
echo "does not exist. It discovers source locations from symbols instead."
echo "======================================================================"
