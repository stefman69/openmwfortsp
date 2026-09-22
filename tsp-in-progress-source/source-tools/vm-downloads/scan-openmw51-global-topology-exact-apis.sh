#!/usr/bin/env bash
set -Eeuo pipefail

cd "$HOME/Downloads"

CTR="${TSP_BUILDER:-openmw_builder}"
DEV="${TSP_DEV:-root@192.168.1.25}"

SRC="/root/openmw-0.51-tsp-src"
BUILD="/root/openmw-0.51-tsp-build"

ROOT="/mnt/SDCARD/data/ports/openmw51"
DB="/mnt/UDISK/openmw51-nav/navmesh.db"
MAP="$ROOT/mods/TSPInteriorVisGrid/scripts/TSPInteriorVisGrid/interiormap.lua"

STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="$HOME/Downloads/openmw51-global-topology-api-scan-$STAMP.txt"
WORK="$HOME/Downloads/openmw51-global-topology-api-scan-$STAMP"

mkdir -p "$WORK"

exec > >(tee "$OUT") 2>&1

echo "======================================================================"
echo "OPENMW 0.51 GLOBAL TOPOLOGY — EXACT API / SOURCE SCAN"
echo "======================================================================"
echo "READ ONLY."
echo "No source edits."
echo "No builds."
echo "No navmesh generation."
echo "No DB writes."
echo "No runtime installation."
echo
echo "Started: $(date)"
echo "Container: $CTR"
echo "Device:    $DEV"
echo "======================================================================"

command -v docker >/dev/null
command -v ssh >/dev/null
command -v scp >/dev/null
command -v python3 >/dev/null

if [ "$(docker inspect -f '{{.State.Running}}' "$CTR" 2>/dev/null || true)" != "true" ]; then
    docker start "$CTR" >/dev/null
fi

echo
echo "######################################################################"
echo "# 1 — EXACT SOURCE / BUILD IDENTITY"
echo "######################################################################"

docker exec "$CTR" bash -lc "
set -e
echo 'SOURCE HEAD:'
git -C '$SRC' rev-parse HEAD
git -C '$SRC' describe --always --dirty --tags 2>/dev/null || true

echo
echo 'MAIN SHA:'
sha256sum '$SRC/apps/navmeshtool/main.cpp'

echo
echo 'SOURCE STATUS — files relevant to this exporter:'
git -C '$SRC' status --short -- \
  apps/navmeshtool \
  components/detournavigator \
  components/misc/compression.cpp \
  components/misc/compression.hpp \
  components/settings/categories/navigator.cpp \
  components/settings/categories/navigator.hpp \
  2>/dev/null || true

echo
echo 'NAVMESHTOOL BINARY:'
file '$BUILD/openmw-navmeshtool'
sha256sum '$BUILD/openmw-navmeshtool'
"

echo
echo "######################################################################"
echo "# 2 — EXACT apps/navmeshtool/main.cpp, WITH LINE NUMBERS"
echo "######################################################################"

# Important: -i is intentional; it passes this Python program into Docker.
docker exec -i "$CTR" python3 - "$SRC/apps/navmeshtool/main.cpp" <<'PY_MAIN'
from pathlib import Path
import sys

p = Path(sys.argv[1])
lines = p.read_text(encoding="utf-8", errors="surrogateescape").splitlines()

print(f"FILE: {p}")
print(f"LINES: {len(lines)}")
print()

# main.cpp is small enough (~340 lines) that printing the entire file is safer
# than guessing another narrow anchor.
for i, line in enumerate(lines, 1):
    print(f"{i:6d}  {line}")
PY_MAIN

echo
echo "######################################################################"
echo "# 3 — EXACT WORLDSPACE COLLECTION / GATHERING API"
echo "######################################################################"

docker exec "$CTR" bash -lc "
set +e

for f in \
  '$SRC/apps/navmeshtool/worldspacedata.hpp' \
  '$SRC/apps/navmeshtool/worldspacedata.cpp'
do
    echo
    echo '================================================================'
    echo \"FILE: \$f\"
    echo '================================================================'
    nl -ba \"\$f\"
done
"

echo
echo "######################################################################"
echo "# 4 — EXACT GENERATE-ALL-TILES API + WHERE DB DATA IS PRODUCED"
echo "######################################################################"

docker exec "$CTR" bash -lc "
set +e

for f in \
  '$SRC/apps/navmeshtool/generateallnavmeshtiles.hpp' \
  '$SRC/apps/navmeshtool/generateallnavmeshtiles.cpp'
do
    echo
    echo '================================================================'
    echo \"FILE: \$f\"
    echo '================================================================'
    nl -ba \"\$f\"
done
"

echo
echo "######################################################################"
echo "# 5 — PREPARED TILE -> DETOUR TILE API"
echo "######################################################################"

docker exec "$CTR" bash -lc "
set +e

for f in \
  '$SRC/components/detournavigator/makenavmesh.hpp' \
  '$SRC/components/detournavigator/makenavmesh.cpp' \
  '$SRC/components/detournavigator/navmeshdata.hpp' \
  '$SRC/components/detournavigator/preparednavmeshdata.hpp' \
  '$SRC/components/detournavigator/preparednavmeshdata.cpp' \
  '$SRC/components/detournavigator/offmeshconnection.hpp'
do
    if [ -f \"\$f\" ]; then
        echo
        echo '================================================================'
        echo \"FILE: \$f\"
        echo '================================================================'
        nl -ba \"\$f\"
    fi
done
"

echo
echo "######################################################################"
echo "# 6 — SERIALIZATION + COMPRESSION EXACT IMPLEMENTATION"
echo "######################################################################"

docker exec "$CTR" bash -lc "
set +e

for f in \
  '$SRC/components/detournavigator/serialization.hpp' \
  '$SRC/components/detournavigator/serialization.cpp' \
  '$SRC/components/misc/compression.hpp' \
  '$SRC/components/misc/compression.cpp'
do
    if [ -f \"\$f\" ]; then
        echo
        echo '================================================================'
        echo \"FILE: \$f\"
        echo '================================================================'
        nl -ba \"\$f\"
    fi
done
"

echo
echo "######################################################################"
echo "# 7 — NAVMESH DB SCHEMA / GET / INSERT / COMPRESSION"
echo "######################################################################"

docker exec "$CTR" bash -lc "
set +e

for f in \
  '$SRC/components/detournavigator/navmeshdb.hpp' \
  '$SRC/components/detournavigator/navmeshdb.cpp'
do
    echo
    echo '================================================================'
    echo \"FILE: \$f\"
    echo '================================================================'
    nl -ba \"\$f\"
done
"

echo
echo "######################################################################"
echo "# 8 — STATUS / SETTINGS / AGENT TYPES USED BY main.cpp"
echo "######################################################################"

docker exec "$CTR" bash -lc "
set +e

echo '----- Status enum / uses -----'
grep -RnsE \
  'enum class Status|Status::NotEnoughSpace|Status::Cancelled|Status::Ok' \
  '$SRC/apps/navmeshtool' \
  '$SRC/components/detournavigator' \
  2>/dev/null | head -240

echo
echo '----- AgentBounds definition -----'
grep -RnsE \
  'struct AgentBounds|class AgentBounds|using AgentBounds' \
  '$SRC/components/detournavigator' \
  2>/dev/null | head -80

echo
echo '----- Settings / Recast settings definitions -----'
grep -RnsE \
  'struct Settings|class Settings|struct RecastSettings|mSwimHeightScale|mMaxNavmeshdbFileSize' \
  '$SRC/components/detournavigator' \
  '$SRC/components/settings' \
  2>/dev/null | head -320
"

echo
echo "######################################################################"
echo "# 9 — NAVMESHTOOL CMAKE TARGET / LINK LIBRARIES"
echo "######################################################################"

docker exec "$CTR" bash -lc "
set +e

echo '----- apps/navmeshtool/CMakeLists.txt -----'
if [ -f '$SRC/apps/navmeshtool/CMakeLists.txt' ]; then
    nl -ba '$SRC/apps/navmeshtool/CMakeLists.txt'
fi

echo
echo '----- root/app CMake references to navmeshtool -----'
grep -RnsE \
  'openmw-navmeshtool|navmeshtool|SQLite|sqlite3' \
  '$SRC/CMakeLists.txt' \
  '$SRC/apps' \
  '$SRC/components/CMakeLists.txt' \
  2>/dev/null | head -360

echo
echo '----- link command if generated -----'
find '$BUILD' -path '*navmeshtool*' \
  \( -name link.txt -o -name build.ninja \) \
  -print 2>/dev/null | head -20

echo
echo '----- build.ninja target link stanza -----'
grep -n -A18 -B8 \
  'build openmw-navmeshtool:' \
  '$BUILD/build.ninja' \
  2>/dev/null || true
"

echo
echo "######################################################################"
echo "# 10 — EXISTING MSET / NAVMESH DUMP FORMAT CODE"
echo "######################################################################"

docker exec "$CTR" bash -lc "
set +e

grep -RnsE \
  \"MSET|NAVMESHSET_MAGIC|NAVMESHSET_VERSION|dtNavMeshParams|tileRef|dataSize|all_tiles_navmesh|write.*NavMesh|dump.*navmesh|TSP_NAVMESH_DUMP\" \
  '$SRC' \
  2>/dev/null | head -500
"

echo
echo "######################################################################"
echo "# 11 — ACTUAL COMPLETED DB SCHEMA / COUNTS — READ ONLY"
echo "######################################################################"

# Use ssh -T + a literal heredoc to avoid nested quote damage.
ssh -T "$DEV" 'sh -s' <<'REMOTE_DB'
set -e

DB="/mnt/UDISK/openmw51-nav/navmesh.db"

echo "DB:"
ls -lh "$DB"
stat -c 'bytes=%s mtime=%Y' "$DB"

echo
echo "----- sqlite_master -----"
sqlite3 -header -column "$DB" <<'SQL'
SELECT type, name, sql
FROM sqlite_master
WHERE type IN ('table','index')
ORDER BY type, name;
SQL

echo
echo "----- PRAGMA table_info(tiles) -----"
sqlite3 -header -column "$DB" 'PRAGMA table_info(tiles);'

echo
echo "----- COUNTS -----"
sqlite3 -header -column "$DB" <<'SQL'
SELECT
    COUNT(*) AS rows,
    COUNT(DISTINCT worldspace) AS worldspaces,
    SUM(CASE WHEN input IS NULL THEN 1 ELSE 0 END) AS null_input_rows,
    SUM(CASE WHEN data IS NULL THEN 1 ELSE 0 END) AS null_data_rows,
    SUM(length(input)) AS input_blob_bytes,
    SUM(length(data)) AS data_blob_bytes
FROM tiles;
SQL

echo
echo "----- TILE VERSION / REVISION RANGE -----"
sqlite3 -header -column "$DB" <<'SQL'
SELECT
    MIN(revision) AS min_revision,
    MAX(revision) AS max_revision,
    MIN(version) AS min_version,
    MAX(version) AS max_version
FROM tiles;
SQL

echo
echo "----- DUPLICATE WORLDSPACE+POSITION -----"
sqlite3 -header -column "$DB" <<'SQL'
SELECT COUNT(*) AS duplicate_positions
FROM (
    SELECT worldspace, tile_position_x, tile_position_y
    FROM tiles
    GROUP BY worldspace, tile_position_x, tile_position_y
    HAVING COUNT(*) > 1
);
SQL

echo
echo "----- FIRST 20 DISTINCT WORLDSPACES -----"
sqlite3 -tabs "$DB" \
  'SELECT DISTINCT worldspace FROM tiles ORDER BY worldspace LIMIT 20;'

echo
echo "----- LAST 20 DISTINCT WORLDSPACES -----"
sqlite3 -tabs "$DB" \
  'SELECT DISTINCT worldspace FROM tiles ORDER BY worldspace DESC LIMIT 20;'
REMOTE_DB

echo
echo "######################################################################"
echo "# 12 — COMPARE DB WORLDSPACE SET VS interiormap.lua SET"
echo "######################################################################"

scp -q "$DEV:$MAP" "$WORK/interiormap.lua"

ssh -T "$DEV" 'sh -s' > "$WORK/db-worldspaces.txt" <<'REMOTE_NAMES'
set -e
sqlite3 -tabs "/mnt/UDISK/openmw51-nav/navmesh.db" \
  'SELECT DISTINCT worldspace FROM tiles ORDER BY worldspace;'
REMOTE_NAMES

python3 - "$WORK/interiormap.lua" "$WORK/db-worldspaces.txt" <<'PY_COMPARE'
from pathlib import Path
import re
import sys

map_path = Path(sys.argv[1])
db_path = Path(sys.argv[2])

rx = re.compile(r'\[\s*"((?:\\.|[^"])*)"\s*\]\s*=')

def unescape(s):
    out = []
    i = 0
    while i < len(s):
        if s[i] == "\\" and i + 1 < len(s):
            n = s[i + 1]
            out.append({
                "\\": "\\",
                '"': '"',
                "'": "'",
                "n": "\n",
                "r": "\r",
                "t": "\t",
            }.get(n, n))
            i += 2
        else:
            out.append(s[i])
            i += 1
    return "".join(out)

mapped = set()
for line in map_path.read_text(encoding="utf-8", errors="replace").splitlines():
    m = rx.search(line)
    if m:
        mapped.add(unescape(m.group(1)))

db = {
    line.rstrip("\r\n")
    for line in db_path.read_text(encoding="utf-8", errors="replace").splitlines()
    if line.rstrip("\r\n")
}

print("interiormap unique names:", len(mapped))
print("DB distinct worldspaces: ", len(db))
print("intersection:             ", len(mapped & db))
print("map-only:                 ", len(mapped - db))
print("DB-only:                  ", len(db - mapped))

if mapped - db:
    print()
    print("----- MAP-ONLY NAMES -----")
    for name in sorted(mapped - db):
        print(repr(name))

if db - mapped:
    print()
    print("----- DB-ONLY NAMES -----")
    for name in sorted(db - mapped):
        print(repr(name))
PY_COMPARE

echo
echo "######################################################################"
echo "# 13 — SAMPLE REAL DB DATA BLOBS / MAGIC AFTER DECOMPRESSION"
echo "######################################################################"

# We do not modify the DB. Pull a few compressed BLOBs as hex and inspect them
# using the exact OpenMW compression implementation context gathered above.
ssh -T "$DEV" 'sh -s' > "$WORK/sample-blobs.tsv" <<'REMOTE_SAMPLE'
set -e
DB="/mnt/UDISK/openmw51-nav/navmesh.db"

sqlite3 -tabs "$DB" <<'SQL'
SELECT
    tile_id,
    worldspace,
    tile_position_x,
    tile_position_y,
    length(input),
    length(data),
    hex(substr(input,1,24)),
    hex(substr(data,1,24))
FROM tiles
ORDER BY tile_id
LIMIT 20;
SQL
REMOTE_SAMPLE

cat "$WORK/sample-blobs.tsv"

echo
echo "######################################################################"
echo "# 14 — CONFIRM NOTHING CHANGED"
echo "######################################################################"

docker exec "$CTR" bash -lc "
set -e

MAIN='$SRC/apps/navmeshtool/main.cpp'
TOOL='$BUILD/openmw-navmeshtool'

echo 'main.cpp:'
sha256sum \"\$MAIN\"

echo
echo 'navmeshtool:'
file \"\$TOOL\"
sha256sum \"\$TOOL\"

echo
if grep -q 'TSP_NAVMESH_TOPOLOGY_DB_EXPORT_V1' \"\$MAIN\"; then
    echo 'ERROR: temporary exporter marker unexpectedly present.'
    exit 1
else
    echo 'PASS: temporary exporter marker absent.'
fi
"

ssh -T "$DEV" 'sh -s' <<'REMOTE_FINAL'
set -e
DB="/mnt/UDISK/openmw51-nav/navmesh.db"
echo "DB final identity:"
ls -lh "$DB"
stat -c 'bytes=%s mtime=%Y' "$DB"
REMOTE_FINAL

echo
echo "======================================================================"
echo "SCAN COMPLETE"
echo "======================================================================"
echo "Full report:"
echo "  $OUT"
echo
echo "Auxiliary files:"
echo "  $WORK"
echo "======================================================================"
