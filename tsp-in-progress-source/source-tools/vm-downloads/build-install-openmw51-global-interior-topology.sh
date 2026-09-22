#!/usr/bin/env bash
set -Eeuo pipefail

cd "$HOME/Downloads"

DEV="${TSP_DEV:-root@192.168.1.25}"
CTR="${TSP_BUILDER:-openmw_builder}"

SRC="/root/openmw-0.51-tsp-src"
BUILD="/root/openmw-0.51-tsp-build"

ROOT="/mnt/SDCARD/data/ports/openmw51"
RUNTIME="$ROOT/navmesh-tool-runtime"
DB="/mnt/UDISK/openmw51-nav/navmesh.db"

MOD="$ROOT/mods/TSPInteriorVisGrid"
VISGRID="$MOD/scripts/TSPInteriorVisGrid/visgrid.lua"
INTERIORMAP="$MOD/scripts/TSPInteriorVisGrid/interiormap.lua"
TOPOLOGY="$MOD/scripts/TSPInteriorVisGrid/topology.lua"
TOPOLOGY_CELLS="$MOD/scripts/TSPInteriorVisGrid/topology_cells"

EXPORT_DIR="$ROOT/topology-export"
EXPORTER="$RUNTIME/openmw-navmesh-topology-export"
DEVICE_PACK="$EXPORT_DIR/all-interiors.msetpack"
DEVICE_LOG="$EXPORT_DIR/export.log"
DEVICE_STATUS="$EXPORT_DIR/export.status"
DEVICE_ALLOW="$EXPORT_DIR/interior-worldspaces.txt"
REMOTE_RUNNER="$EXPORT_DIR/run-export.sh"

STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="$HOME/Downloads/openmw51-global-interior-topology-$STAMP"
mkdir -p "$OUT"

exec > >(tee "$OUT/controller.log") 2>&1

echo "===================================================================="
echo "OPENMW 0.51 — GLOBAL INTERIOR NAVMESH -> VISGRID TOPOLOGY"
echo "===================================================================="
echo
echo "Source DB:"
echo "  $DB"
echo
echo "Safety:"
echo "  - canonical navmesh.db is opened SQLITE READ-ONLY by exporter"
echo "  - no navmesh regeneration"
echo "  - no second/work navmesh DB"
echo "  - no game executable replacement"
echo "  - no V20 sensor replacement"
echo "  - only generated topology data is installed"
echo "===================================================================="

for c in docker ssh scp python3 tar sha256sum awk grep sed file; do
    command -v "$c" >/dev/null 2>&1 || {
        echo "ERROR: required Ubuntu command missing: $c"
        exit 10
    }
done

docker inspect "$CTR" >/dev/null 2>&1 || {
    echo "ERROR: Docker container not found: $CTR"
    exit 11
}

if [ "$(docker inspect -f '{{.State.Running}}' "$CTR")" != "true" ]; then
    docker start "$CTR" >/dev/null
fi

echo
echo "===== 1/10 DEVICE + COMPLETED-DB PREFLIGHT ====="

if ssh "$DEV" 'pidof openmw-0.51 >/dev/null 2>&1 || pidof openmw >/dev/null 2>&1'; then
    echo "ERROR: Morrowind is running. Exit it normally first."
    exit 12
fi

if ssh "$DEV" 'pidof openmw-navmeshtool >/dev/null 2>&1'; then
    echo "ERROR: navmeshtool is still running; DB is not settled."
    ssh "$DEV" 'ps w | grep "[o]penmw-navmeshtool" || true'
    exit 13
fi

if ssh "$DEV" 'pidof openmw-navmesh-topology-export >/dev/null 2>&1'; then
    echo "ERROR: a topology exporter is already running."
    ssh "$DEV" 'ps w | grep "[o]penmw-navmesh-topology-export" || true'
    exit 14
fi

ssh "$DEV" "
set -e

test -s '$DB'
test -s '$ROOT/bin/openmw-0.51'
test -s '$VISGRID'
test -s '$INTERIORMAP'
test -x '$RUNTIME/openmw-navmeshtool'

grep -a -q 'TSP_INTERIOR_VISGRID_051_V5_TOPO_PVS' '$ROOT/bin/openmw-0.51'
grep -q 'TSP_VISGRID_V20' '$VISGRID'

echo '--- completed DB ---'
ls -lh '$DB'
stat -c 'bytes=%s mtime=%Y' '$DB'

echo
echo '--- worldspaces / tiles ---'
sqlite3 -tabs '$DB' \
  'SELECT COUNT(DISTINCT worldspace), COUNT(*) FROM tiles;' 2>/dev/null

echo
echo '--- interior PVS runtime ---'
grep -a -o 'TSP_INTERIOR_VISGRID_051_V5_TOPO_PVS' \
  '$ROOT/bin/openmw-0.51' | head -1
grep -n 'TSP_VISGRID_V20' '$VISGRID' | head -2

echo
echo '--- free storage ---'
df -h /mnt/UDISK /mnt/SDCARD 2>/dev/null || true
" | tee "$OUT/device-preflight.txt"

DB_STAT_BEFORE="$(ssh "$DEV" "stat -c '%s %Y' '$DB'")"
GAME_SHA_BEFORE="$(ssh "$DEV" "sha256sum '$ROOT/bin/openmw-0.51'" | awk '{print $1}')"
VISGRID_SHA_BEFORE="$(ssh "$DEV" "sha256sum '$VISGRID'" | awk '{print $1}')"

echo
echo "===== 2/10 FETCH INTERIOR ALLOWLIST ====="

scp -q "$DEV:$INTERIORMAP" "$OUT/interiormap.lua"

ssh "$DEV" \
  "sqlite3 -tabs '$DB' 'SELECT DISTINCT worldspace FROM tiles ORDER BY worldspace;'" \
  > "$OUT/db-worldspaces.txt"

python3 - \
  "$OUT/interiormap.lua" \
  "$OUT/db-worldspaces.txt" \
  "$OUT/interior-worldspaces.txt" <<'PY_ALLOW'
from pathlib import Path
import re
import sys

src = Path(sys.argv[1])
db_path = Path(sys.argv[2])
dst = Path(sys.argv[3])

rx = re.compile(r'\[\s*"((?:\\.|[^"])*)"\s*\]\s*=')

def lua_unescape(s):
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

canonical = set()

for line in src.read_text(
    encoding="utf-8",
    errors="replace",
).splitlines():
    m = rx.search(line)
    if not m:
        continue
    name = lua_unescape(m.group(1))
    if name and "\n" not in name and "\r" not in name:
        canonical.add(name)

if len(canonical) < 100:
    raise SystemExit(
        f"ERROR: only found {len(canonical)} interior names"
    )

db_names = {
    line.rstrip("\r\n")
    for line in db_path.read_text(
        encoding="utf-8",
        errors="replace",
    ).splitlines()
    if line.rstrip("\r\n")
}

db_by_fold = {}
for name in db_names:
    key = name.casefold()
    if key in db_by_fold and db_by_fold[key] != name:
        raise SystemExit(
            "ERROR: DB case-fold collision: "
            f"{db_by_fold[key]!r} vs {name!r}"
        )
    db_by_fold[key] = name

matched = []
map_only = []

for name in sorted(canonical):
    db_name = db_by_fold.get(name.casefold())
    if db_name is None:
        map_only.append(name)
        continue
    matched.append((db_name, name))

matched_db = {db_name for db_name, _ in matched}
db_only = sorted(db_names - matched_db)

print(f"interiormap names : {len(canonical)}")
print(f"DB worldspaces    : {len(db_names)}")
print(f"matched interiors : {len(matched)}")
print(f"map-only          : {len(map_only)}")
print(f"DB-only           : {len(db_only)}")

if map_only:
    print()
    print("MAP-ONLY (will use conservative V20 fallback):")
    for name in map_only:
        print("  ", repr(name))

if db_only:
    print()
    print("DB-ONLY (not interior-topology targets):")
    for name in db_only:
        print("  ", repr(name))

if len(matched) < max(1, len(canonical) - 8):
    raise SystemExit(
        "ERROR: too many interior names failed DB matching"
    )

dst.write_text(
    "".join(
        f"{db_name}\t{canonical_name}\n"
        for db_name, canonical_name in matched
    ),
    encoding="utf-8",
    newline="\n",
)

print()
print(
    "PASS: wrote case-aware DB->canonical topology map "
    f"for {len(matched)} interiors"
)
PY_ALLOW

ALLOW_COUNT="$(wc -l < "$OUT/interior-worldspaces.txt")"
echo "Interior topology targets: $ALLOW_COUNT"

echo
echo "===== 3/10 PREPARE ISOLATED READ-ONLY EXPORTER PATCH ====="

cat > "$OUT/patch_topology_exporter.py" <<'PY_PATCH'
from pathlib import Path
import re
import sys

main = Path(sys.argv[1])
srcroot = Path(sys.argv[2])

s = main.read_text(encoding="utf-8")

marker = "TSP_NAVMESH_TOPOLOGY_DB_EXPORT_V2_CASEMAP"

if marker in s:
    raise SystemExit(
        "ERROR: temporary topology exporter marker already exists"
    )

required_files = [
    srcroot / "components/detournavigator/makenavmesh.hpp",
    srcroot / "components/detournavigator/navmeshdata.hpp",
    srcroot / "components/detournavigator/preparednavmeshdata.hpp",
    srcroot / "components/detournavigator/serialization.hpp",
    srcroot / "components/detournavigator/navmeshdb.cpp",
]

for path in required_files:
    if not path.is_file():
        raise SystemExit(
            f"ERROR: discovered required source file is missing: {path}"
        )

navdata = (
    srcroot / "components/detournavigator/navmeshdata.hpp"
).read_text(
    encoding="utf-8",
    errors="replace",
)

size_match = re.search(
    r'\b(?:int|std::size_t|std::uint32_t|std::uint64_t)\s+'
    r'(m[A-Za-z0-9_]*Size)\b',
    navdata,
)

if not size_match:
    raise SystemExit(
        "ERROR: could not detect NavMeshData size field"
    )

size_field = size_match.group(1)

make_hpp = (
    srcroot / "components/detournavigator/makenavmesh.hpp"
).read_text(
    encoding="utf-8",
    errors="replace",
)

if not re.search(
    r'NavMeshData\s+makeNavMeshTileData\s*\(',
    make_hpp,
):
    raise SystemExit(
        "ERROR: makeNavMeshTileData API not found"
    )

serialization_hpp = (
    srcroot / "components/detournavigator/serialization.hpp"
).read_text(
    encoding="utf-8",
    errors="replace",
)

if "bool deserialize(" not in serialization_hpp:
    raise SystemExit(
        "ERROR: PreparedNavMeshData deserialize API not found"
    )

include_anchor = (
    "#include <components/detournavigator/navmeshdb.hpp>\n"
)

if s.count(include_anchor) != 1:
    raise SystemExit(
        "ERROR: expected exactly one navmeshdb include anchor"
    )

extra_includes = r'''#include <components/detournavigator/makenavmesh.hpp>
#include <components/detournavigator/navmeshdata.hpp>
#include <components/detournavigator/preparednavmeshdata.hpp>
#include <components/detournavigator/serialization.hpp>
#include <components/detournavigator/tileposition.hpp>
#include <components/misc/compression.hpp>

#include <DetourAlloc.h>
#include <DetourNavMesh.h>

#include <sqlite3.h>

#include <fstream>
#include <memory>
#include <stdexcept>
#include <unordered_map>
'''

s = s.replace(
    include_anchor,
    include_anchor + extra_includes,
    1,
)

run_match = re.search(
    r'(?m)^(?P<indent>[ \t]*)int[ \t]+'
    r'runNavMeshTool[ \t]*\(',
    s,
)

if run_match is None:
    raise SystemExit(
        "ERROR: runNavMeshTool definition not found"
    )

helper = r'''
// TSP_NAVMESH_TOPOLOGY_DB_EXPORT_V2_CASEMAP
int tspExportTopologyPack(
    const std::string& dbPath,
    const std::filesystem::path& packPath,
    const std::filesystem::path& allowPath,
    const DetourNavigator::AgentBounds& agentBounds,
    const DetourNavigator::Settings& navigatorSettings)
{
    std::unordered_map<std::string, std::string> allow;

    {
        std::ifstream in(allowPath);

        if (!in)
            throw std::runtime_error(
                "Unable to open topology allowlist: "
                + allowPath.string());

        std::string line;

        while (std::getline(in, line))
        {
            if (!line.empty() && line.back() == '\r')
                line.pop_back();

            if (line.empty())
                continue;

            const std::size_t tab = line.find('\t');

            if (tab == std::string::npos
                || tab == 0
                || tab + 1 >= line.size())
            {
                throw std::runtime_error(
                    "Malformed topology allowlist row");
            }

            const std::string dbKey = line.substr(0, tab);
            const std::string canonical = line.substr(tab + 1);

            const auto [it, inserted]
                = allow.emplace(dbKey, canonical);

            if (!inserted && it->second != canonical)
            {
                throw std::runtime_error(
                    "Conflicting canonical names for DB worldspace "
                    + dbKey);
            }
        }
    }

    if (allow.empty())
        throw std::runtime_error("Topology allowlist is empty");

    std::error_code ec;
    std::filesystem::create_directories(
        packPath.parent_path(), ec);

    if (ec)
        throw std::runtime_error(
            "Unable to create topology export directory: "
            + ec.message());

    sqlite3* rawDb = nullptr;

    const int openRc = sqlite3_open_v2(
        dbPath.c_str(),
        &rawDb,
        SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX,
        nullptr);

    std::unique_ptr<sqlite3, decltype(&sqlite3_close)> db(
        rawDb,
        &sqlite3_close);

    if (openRc != SQLITE_OK || rawDb == nullptr)
        throw std::runtime_error(
            "Unable to open navmesh.db SQLITE READ-ONLY");

    constexpr const char* query = R"sql(
        SELECT worldspace,
               tile_position_x,
               tile_position_y,
               data
          FROM tiles
         WHERE data IS NOT NULL
         ORDER BY worldspace,
                  tile_position_x,
                  tile_position_y
    )sql";

    sqlite3_stmt* rawStmt = nullptr;

    const int prepareRc = sqlite3_prepare_v2(
        rawDb,
        query,
        -1,
        &rawStmt,
        nullptr);

    std::unique_ptr<
        sqlite3_stmt,
        decltype(&sqlite3_finalize)
    > stmt(
        rawStmt,
        &sqlite3_finalize);

    if (prepareRc != SQLITE_OK || rawStmt == nullptr)
        throw std::runtime_error(
            "Unable to prepare read-only navmesh tile query");

    auto paramsMesh =
        std::unique_ptr<
            dtNavMesh,
            decltype(&dtFreeNavMesh)
        >(
            dtAllocNavMesh(),
            &dtFreeNavMesh);

    if (!paramsMesh)
        throw std::runtime_error("dtAllocNavMesh failed");

    DetourNavigator::initEmptyNavMesh(
        navigatorSettings,
        *paramsMesh);

    const dtNavMeshParams navParams =
        *paramsMesh->getParams();

    struct MsetHeader
    {
        int magic;
        int version;
        int numTiles;
        dtNavMeshParams params;
    };

    struct MsetTileHeader
    {
        std::uint32_t tileRef;
        int dataSize;
    };

    static_assert(
        sizeof(MsetHeader) == 40,
        "Unexpected RecastDemo MSET header layout");

    static_assert(
        sizeof(MsetTileHeader) == 8,
        "Unexpected RecastDemo tile header layout");

    constexpr int msetMagic =
        ('M' << 24)
        | ('S' << 16)
        | ('E' << 8)
        | 'T';

    constexpr int msetVersion = 1;

    std::ofstream pack(
        packPath,
        std::ios::binary | std::ios::trunc);

    if (!pack)
        throw std::runtime_error(
            "Unable to open topology pack output: "
            + packPath.string());

    pack.write("TSPMSET1", 8);

    const std::filesystem::path recordPath =
        packPath.string() + ".records.tmp";

    std::string currentDbKey;
    std::string currentCanonical;
    std::ofstream records;
    std::uint64_t recordBytes = 0;
    int tileCount = 0;
    std::uint32_t nextTileRef = 1;

    std::size_t exportedWorldspaces = 0;
    std::size_t exportedTiles = 0;

    auto beginWorldspace =
        [&](const std::string& dbKey,
            const std::string& canonical)
    {
        currentDbKey = dbKey;
        currentCanonical = canonical;
        recordBytes = 0;
        tileCount = 0;
        nextTileRef = 1;

        records.open(
            recordPath,
            std::ios::binary | std::ios::trunc);

        if (!records)
            throw std::runtime_error(
                "Unable to open temporary MSET record file");
    };

    auto flushWorldspace = [&]()
    {
        if (currentDbKey.empty())
            return;

        records.close();

        if (tileCount <= 0)
        {
            std::filesystem::remove(recordPath, ec);
            currentDbKey.clear();
            currentCanonical.clear();
            return;
        }

        const std::uint32_t nameLen =
            static_cast<std::uint32_t>(
                currentCanonical.size());

        const MsetHeader header{
            msetMagic,
            msetVersion,
            tileCount,
            navParams,
        };

        const std::uint64_t msetBytes =
            sizeof(header) + recordBytes;

        pack.write(
            reinterpret_cast<const char*>(&nameLen),
            sizeof(nameLen));

        pack.write(
            reinterpret_cast<const char*>(&msetBytes),
            sizeof(msetBytes));

        pack.write(
            currentCanonical.data(),
            static_cast<std::streamsize>(
                currentCanonical.size()));

        pack.write(
            reinterpret_cast<const char*>(&header),
            sizeof(header));

        std::ifstream in(
            recordPath,
            std::ios::binary);

        if (!in)
            throw std::runtime_error(
                "Unable to reopen temporary MSET records");

        pack << in.rdbuf();

        if (!pack)
            throw std::runtime_error(
                "Topology pack write failed");

        ++exportedWorldspaces;
        exportedTiles +=
            static_cast<std::size_t>(tileCount);

        if (exportedWorldspaces == 1
            || exportedWorldspaces % 25 == 0)
        {
            Log(Debug::Info)
                << "[TSP_TOPOLOGY_EXPORT] worldspaces="
                << exportedWorldspaces
                << "/" << allow.size()
                << " latest=\""
                << currentCanonical
                << "\" dbkey=\""
                << currentDbKey
                << "\" tiles="
                << tileCount;
        }

        std::filesystem::remove(recordPath, ec);

        currentDbKey.clear();
        currentCanonical.clear();
    };

    while (true)
    {
        const int stepRc = sqlite3_step(rawStmt);

        if (stepRc == SQLITE_DONE)
            break;

        if (stepRc != SQLITE_ROW)
            throw std::runtime_error(
                "Read-only navmesh tile query failed");

        const unsigned char* wsText =
            sqlite3_column_text(rawStmt, 0);

        if (wsText == nullptr)
            continue;

        const std::string worldspace(
            reinterpret_cast<const char*>(wsText));

        const auto allowIt = allow.find(worldspace);

        if (allowIt == allow.end())
            continue;

        if (currentDbKey != worldspace)
        {
            flushWorldspace();

            beginWorldspace(
                worldspace,
                allowIt->second);
        }

        const int tx =
            sqlite3_column_int(rawStmt, 1);

        const int ty =
            sqlite3_column_int(rawStmt, 2);

        const void* blob =
            sqlite3_column_blob(rawStmt, 3);

        const int blobBytes =
            sqlite3_column_bytes(rawStmt, 3);

        if (blob == nullptr || blobBytes <= 0)
            continue;

        const std::byte* first =
            static_cast<const std::byte*>(blob);

        std::vector<std::byte> compressed(
            first,
            first + blobBytes);

        const std::vector<std::byte> serialized =
            Misc::decompress(compressed);

        DetourNavigator::PreparedNavMeshData prepared;

        if (!DetourNavigator::deserialize(
                serialized,
                prepared))
        {
            throw std::runtime_error(
                "Unable to deserialize PreparedNavMeshData for "
                + worldspace);
        }

        const DetourNavigator::TilePosition tilePosition{
            tx,
            ty,
        };

        auto tileData =
            DetourNavigator::makeNavMeshTileData(
                prepared,
                {},
                agentBounds,
                tilePosition,
                navigatorSettings.mRecast);

        const int dataSize =
            static_cast<int>(
                tileData.__NAVDATA_SIZE_FIELD__);

        if (!tileData.mValue || dataSize <= 0)
            throw std::runtime_error(
                "Unable to reconstruct Detour tile for "
                + worldspace);

        const MsetTileHeader tileHeader{
            nextTileRef++,
            dataSize,
        };

        records.write(
            reinterpret_cast<const char*>(&tileHeader),
            sizeof(tileHeader));

        records.write(
            reinterpret_cast<const char*>(
                tileData.mValue.get()),
            dataSize);

        if (!records)
            throw std::runtime_error(
                "Temporary MSET tile write failed");

        recordBytes +=
            sizeof(tileHeader)
            + static_cast<std::uint64_t>(dataSize);

        ++tileCount;
    }

    flushWorldspace();
    pack.flush();

    std::filesystem::remove(recordPath, ec);

    Log(Debug::Info)
        << "[TSP_TOPOLOGY_EXPORT] COMPLETE worldspaces="
        << exportedWorldspaces
        << "/" << allow.size()
        << " tiles=" << exportedTiles
        << " output=" << packPath.string();

    if (exportedWorldspaces + 8 < allow.size())
        throw std::runtime_error(
            "Exporter missed too many mapped interior worldspaces");

    return 0;
}

'''

helper = helper.replace(
    "__NAVDATA_SIZE_FIELD__",
    size_field,
)

s = (
    s[:run_match.start()]
    + helper
    + "\n"
    + s[run_match.start():]
)

db_re = re.compile(
    r'(?m)^(?P<indent>[ \t]*)'
    r'DetourNavigator::NavMeshDb[ \t]+db[ \t]*'
    r'\([ \t]*dbPath[ \t]*,[ \t]*maxDbFileSize[ \t]*\)'
    r'[ \t]*;[ \t]*$'
)

db_matches = list(db_re.finditer(s))

if len(db_matches) != 1:
    raise SystemExit(
        "ERROR: expected exactly one writable NavMeshDb construction; "
        f"found {len(db_matches)}"
    )

db_match = db_matches[0]
db_indent = db_match.group("indent")

s = (
    s[:db_match.start()]
    + db_indent
    + "// TSP exporter delays writable NavMeshDb construction "
      "until after the read-only export branch."
    + s[db_match.end():]
)

status_re = re.compile(
    r'(?m)^(?P<indent>[ \t]*)'
    r'Status[ \t]+status[ \t]*=[ \t]*Status::Ok[ \t]*;'
    r'[ \t]*$'
)

status_matches = list(status_re.finditer(s))

if len(status_matches) != 1:
    raise SystemExit(
        "ERROR: expected exactly one NavMeshTool Status::Ok "
        f"initialization; found {len(status_matches)}"
    )

status_match = status_matches[0]
indent = status_match.group("indent")

required_before_status = [
    "const DetourNavigator::AgentBounds agentBounds",
    "const EsmLoader::EsmData esmData",
    "DetourNavigator::Settings navigatorSettings",
    "navigatorSettings.mRecast.mSwimHeightScale",
    "collectWorldspaceCells(",
]

prefix = s[:status_match.start()]

for token in required_before_status:
    if token not in prefix:
        raise SystemExit(
            "ERROR: confirmed pre-Status source structure missing: "
            + token
        )

branch = f'''
{indent}if (const char* exportOut =
{indent}        std::getenv("TSP_TOPOLOGY_EXPORT_OUT"))
{indent}{{
{indent}    const char* exportDb =
{indent}        std::getenv("TSP_TOPOLOGY_EXPORT_DB");
{indent}
{indent}    const char* exportAllow =
{indent}        std::getenv(
{indent}            "TSP_TOPOLOGY_EXPORT_ALLOWLIST");
{indent}
{indent}    if (exportDb == nullptr
{indent}        || exportAllow == nullptr)
{indent}    {{
{indent}        throw std::runtime_error(
{indent}            "Topology exporter environment is incomplete");
{indent}    }}
{indent}
{indent}    return tspExportTopologyPack(
{indent}        exportDb,
{indent}        std::filesystem::path(exportOut),
{indent}        std::filesystem::path(exportAllow),
{indent}        agentBounds,
{indent}        navigatorSettings);
{indent}}}
{indent}
{indent}DetourNavigator::NavMeshDb db(
{indent}    dbPath,
{indent}    maxDbFileSize);
{indent}
'''

s = (
    s[:status_match.start()]
    + branch
    + s[status_match.start():]
)

if s.count(marker) != 1:
    raise SystemExit(
        "ERROR: exporter marker count is not 1"
    )

if s.count("SQLITE_OPEN_READONLY") != 1:
    raise SystemExit(
        "ERROR: SQLITE_OPEN_READONLY marker count is not 1"
    )

if s.count(
    "TSP exporter delays writable NavMeshDb construction"
) != 1:
    raise SystemExit(
        "ERROR: writable NavMeshDb delay marker count is not 1"
    )

with main.open("w", encoding="utf-8", newline="\n") as out:
    out.write(s)

print("PASS: temporary topology exporter patch generated")
print("marker:", marker)
print("NavMeshData size field:", size_field)
print("source Status anchor: semantic regex")
print("DB mapping: exact stored key -> canonical V20 cell name")

PY_PATCH

python3 -m py_compile "$OUT/patch_topology_exporter.py"
echo
echo "===== 3B/10 SELF-TEST CURRENT SOURCE COPY ====="

SELF_PATCH="/tmp/tsp-topology-patcher-$STAMP.py"
SELF_MAIN="/tmp/tsp-navmeshtool-main-$STAMP.cpp"

docker cp \
    "$OUT/patch_topology_exporter.py" \
    "$CTR:$SELF_PATCH"

docker exec "$CTR" bash -lc "
set -Eeuo pipefail

cp -p \
  '$SRC/apps/navmeshtool/main.cpp' \
  '$SELF_MAIN'

BEFORE=\$(sha256sum '$SELF_MAIN' | awk '{print \$1}')

python3 \
  '$SELF_PATCH' \
  '$SELF_MAIN' \
  '$SRC'

AFTER=\$(sha256sum '$SELF_MAIN' | awk '{print \$1}')

[ \"\$BEFORE\" != \"\$AFTER\" ]

grep -q \
  'TSP_NAVMESH_TOPOLOGY_DB_EXPORT_V2_CASEMAP' \
  '$SELF_MAIN'

grep -q \
  'SQLITE_OPEN_READONLY' \
  '$SELF_MAIN'

grep -q \
  'TSP_TOPOLOGY_EXPORT_ALLOWLIST' \
  '$SELF_MAIN'

COUNT=\$(grep -c \
  'DetourNavigator::NavMeshDb db(' \
  '$SELF_MAIN')

[ \"\$COUNT\" -eq 1 ]

echo 'PASS: exporter patch applied to a COPY of current main.cpp.'
echo \"NavMeshDb construction count: \$COUNT\"

echo
echo '--- exporter branch context ---'

grep -n -A44 -B18 \
  'TSP_TOPOLOGY_EXPORT_OUT' \
  '$SELF_MAIN'

rm -f \
  '$SELF_MAIN' \
  '$SELF_PATCH'
"

echo

echo
echo "===== 4/10 BUILD ISOLATED AARCH64 EXPORTER ====="

cat > "$OUT/exporter.worker.sh" <<'WORKER'
#!/usr/bin/env bash
set -Eeuo pipefail

SRC="/root/openmw-0.51-tsp-src"
BUILD="/root/openmw-0.51-tsp-build"
RUN="$1"

MAIN="$SRC/apps/navmeshtool/main.cpp"
BACK="$RUN/main.cpp.before-topology-export"
LOG="$RUN/build.log"
STATUS="$RUN/status"
OUTDIR="$RUN/output"
PATCHER="$RUN/patch_topology_exporter.py"

mkdir -p "$RUN" "$OUTDIR"
: > "$LOG"
rm -f "$STATUS"

exec >>"$LOG" 2>&1

ORIG_SHA="$(sha256sum "$MAIN" | awk '{print $1}')"
cp -p "$MAIN" "$BACK"

finish() {
    rc=$?
    trap - EXIT INT TERM

    echo
    echo "===== RESTORE ORIGINAL NAVMESHTOOL SOURCE ====="

    if [ -s "$BACK" ]; then
        cp -pf "$BACK" "$MAIN"
    fi

    AFTER_SHA="$(sha256sum "$MAIN" | awk '{print $1}')"

    echo "source before=$ORIG_SHA"
    echo "source after =$AFTER_SHA"

    if [ "$AFTER_SHA" != "$ORIG_SHA" ]; then
        echo "FATAL: main.cpp did not restore byte-identically."
        printf '91\n' >"$STATUS.tmp"
        mv -f "$STATUS.tmp" "$STATUS"
        exit 91
    fi

    echo
    echo "===== RESTORE NORMAL NAVMESHTOOL TARGET ====="

    rm -f \
        "$BUILD/openmw-navmeshtool" \
        "$BUILD/apps/navmeshtool/CMakeFiles/openmw-navmeshtool.dir/main.cpp.o"

    set +e
    cmake --build \
        "$BUILD" \
        --target openmw-navmeshtool \
        --parallel 1
    restore_rc=$?
    set -e

    if [ "$restore_rc" -ne 0 ]; then
        echo "FATAL: normal navmeshtool failed to rebuild after source restore."
        printf '92\n' >"$STATUS.tmp"
        mv -f "$STATUS.tmp" "$STATUS"
        exit 92
    fi

    echo "PASS: original source restored."
    echo "PASS: normal navmeshtool target rebuilt."
    file "$BUILD/openmw-navmeshtool"
    sha256sum "$BUILD/openmw-navmeshtool"

    printf '%s\n' "$rc" >"$STATUS.tmp"
    mv -f "$STATUS.tmp" "$STATUS"
    exit "$rc"
}

trap finish EXIT INT TERM

echo "=================================================================="
echo "ISOLATED GLOBAL-TOPOLOGY EXPORTER BUILD"
echo "=================================================================="
echo "Started: $(date)"
echo "Original main SHA: $ORIG_SHA"

echo
echo "===== EXACT MAKE-NAVMESH API ====="
grep -n -A8 -B3 \
    'makeNavMeshTileData' \
    "$SRC/components/detournavigator/makenavmesh.hpp" || true

echo
echo "===== EXACT NAVMESHDATA ====="
cat "$SRC/components/detournavigator/navmeshdata.hpp"

echo
echo "===== APPLY TEMPORARY EXPORTER PATCH ====="
python3 "$PATCHER" "$MAIN" "$SRC"

grep -q \
    'TSP_NAVMESH_TOPOLOGY_DB_EXPORT_V2_CASEMAP' \
    "$MAIN"

echo
echo "===== PATCH DIFF SUMMARY ====="
git -C "$SRC" diff -- \
    apps/navmeshtool/main.cpp | head -320 || true

echo
echo "===== BUILD EXPORTER ====="

rm -f "$BUILD/openmw-navmeshtool"

cmake --build \
    "$BUILD" \
    --target openmw-navmeshtool \
    --parallel 1

test -x "$BUILD/openmw-navmeshtool"

file "$BUILD/openmw-navmeshtool"

file "$BUILD/openmw-navmeshtool" |
grep -Eiq \
    'ELF 64-bit.*(ARM aarch64|aarch64)'

cp -p \
    "$BUILD/openmw-navmeshtool" \
    "$OUTDIR/openmw-navmesh-topology-export"

chmod +x \
    "$OUTDIR/openmw-navmesh-topology-export"

echo
echo "===== EXPORTER ARTIFACT ====="
file "$OUTDIR/openmw-navmesh-topology-export"
sha256sum "$OUTDIR/openmw-navmesh-topology-export"

echo
echo "EXPORTER BUILD SUCCESS"
WORKER

chmod +x "$OUT/exporter.worker.sh"
bash -n "$OUT/exporter.worker.sh"

DOCKER_RUN="/root/tsp-global-topology-exporter-$STAMP"

docker exec "$CTR" \
    mkdir -p "$DOCKER_RUN"

docker cp \
    "$OUT/patch_topology_exporter.py" \
    "$CTR:$DOCKER_RUN/patch_topology_exporter.py"

docker cp \
    "$OUT/exporter.worker.sh" \
    "$CTR:$DOCKER_RUN/exporter.worker.sh"

docker exec "$CTR" \
    chmod +x "$DOCKER_RUN/exporter.worker.sh"

docker exec -d "$CTR" \
    bash "$DOCKER_RUN/exporter.worker.sh" \
    "$DOCKER_RUN"

echo "Detached Docker worker started."
echo "Streaming actual new build lines:"

NEXT=1

while :; do
    STATUS_VALUE="$(
        docker exec "$CTR" bash -lc \
            "cat '$DOCKER_RUN/status' 2>/dev/null || true" \
            2>/dev/null || true
    )"

    LINES="$(
        docker exec "$CTR" bash -lc \
            "wc -l < '$DOCKER_RUN/build.log' 2>/dev/null || echo 0" \
            2>/dev/null || echo 0
    )"

    case "$LINES" in
        ''|*[!0-9]*) LINES=0 ;;
    esac

    if [ "$LINES" -ge "$NEXT" ]; then
        docker exec "$CTR" bash -lc \
            "sed -n '${NEXT},${LINES}p' '$DOCKER_RUN/build.log'" \
            || true
        NEXT=$((LINES + 1))
    fi

    if [ -n "$STATUS_VALUE" ]; then
        BUILD_RC="$STATUS_VALUE"
        break
    fi

    sleep 3
done

if [ "$BUILD_RC" != "0" ]; then
    echo
    echo "ERROR: exporter build failed with code $BUILD_RC"
    docker exec "$CTR" \
        tail -260 "$DOCKER_RUN/build.log" || true
    exit 20
fi

docker cp \
    "$CTR:$DOCKER_RUN/output/openmw-navmesh-topology-export" \
    "$OUT/openmw-navmesh-topology-export"

chmod +x "$OUT/openmw-navmesh-topology-export"

file "$OUT/openmw-navmesh-topology-export" |
tee "$OUT/exporter-file.txt"

grep -Eiq \
    'ELF 64-bit.*(ARM aarch64|aarch64)' \
    "$OUT/exporter-file.txt"

EXPORTER_SHA="$(
    sha256sum "$OUT/openmw-navmesh-topology-export" |
    awk '{print $1}'
)"

echo "Exporter SHA: $EXPORTER_SHA"

echo
echo "===== 5/10 INSTALL EXPORTER + START READ-ONLY DB EXPORT ====="

cat > "$OUT/run-export.sh" <<'REMOTE_RUNNER'
#!/bin/bash
set +e

ROOT="/mnt/SDCARD/data/ports/openmw51"
RUNTIME="$ROOT/navmesh-tool-runtime"

DB="/mnt/UDISK/openmw51-nav/navmesh.db"

OUT="$ROOT/topology-export/all-interiors.msetpack"
ALLOW="$ROOT/topology-export/interior-worldspaces.txt"
LOG="$ROOT/topology-export/export.log"
STATUS="$ROOT/topology-export/export.status"
STATUS_TMP="$STATUS.tmp"

rm -f \
    "$OUT" \
    "$OUT.records.tmp" \
    "$STATUS" \
    "$STATUS_TMP"

: >"$LOG"

export LD_LIBRARY_PATH="$ROOT/lib:$ROOT/libs:$ROOT/lib/aarch64:/mnt/SDCARD/System/lib:/usr/trimui/lib:${LD_LIBRARY_PATH:-}"
export OSG_LIBRARY_PATH="$ROOT/osgPlugins-3.6.5"

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/runtime-root}"
export XDG_CONFIG_HOME="$ROOT/config-0.51"
export XDG_DATA_HOME="$ROOT/config-0.51"
export OPENMW_RESOURCES="$ROOT/resources"

mkdir -p "$XDG_RUNTIME_DIR"
chmod 0700 "$XDG_RUNTIME_DIR" 2>/dev/null || true

export TSP_TOPOLOGY_EXPORT_DB="$DB"
export TSP_TOPOLOGY_EXPORT_OUT="$OUT"
export TSP_TOPOLOGY_EXPORT_ALLOWLIST="$ALLOW"

cd "$RUNTIME" || exit 90

{
    echo "============================================================"
    echo "GLOBAL INTERIOR TOPOLOGY EXPORT STARTED: $(date)"
    echo "DB:   $DB"
    echo "OUT:  $OUT"
    echo "MODE: SQLITE_OPEN_READONLY"
    echo "============================================================"
} >>"$LOG"

"$RUNTIME/openmw-navmesh-topology-export" \
    --resources "$ROOT/resources" \
    --config "$ROOT/config-0.51" \
    --user-data "/mnt/UDISK/openmw51-nav" \
    --threads 1 \
    >>"$LOG" 2>&1

rc=$?

{
    echo
    echo "EXPORTER EXIT CODE: $rc"
    echo "EXPORTER FINISHED:  $(date)"
} >>"$LOG"

printf '%s\n' "$rc" >"$STATUS_TMP"
mv -f "$STATUS_TMP" "$STATUS"
sync

exit "$rc"
REMOTE_RUNNER

chmod +x "$OUT/run-export.sh"
bash -n "$OUT/run-export.sh"

ssh "$DEV" "
set -e
mkdir -p '$EXPORT_DIR'
rm -f '$DEVICE_STATUS'

stat -c '%s %Y' '$DB' \
    > '$EXPORT_DIR/db-stat-before.txt'
"

scp -q \
    "$OUT/openmw-navmesh-topology-export" \
    "$DEV:$EXPORTER.new"

scp -q \
    "$OUT/interior-worldspaces.txt" \
    "$DEV:$DEVICE_ALLOW"

scp -q \
    "$OUT/run-export.sh" \
    "$DEV:$REMOTE_RUNNER"

ssh "$DEV" "
set -e

chmod +x \
    '$EXPORTER.new' \
    '$REMOTE_RUNNER'

ACTUAL=\$(
    sha256sum '$EXPORTER.new' |
    awk '{print \$1}'
)

test \"\$ACTUAL\" = '$EXPORTER_SHA'

mv -f \
    '$EXPORTER.new' \
    '$EXPORTER'

nohup \
    '$REMOTE_RUNNER' \
    </dev/null \
    >/dev/null \
    2>&1 &

echo \$! > '$EXPORT_DIR/export.pid'

echo 'Detached exporter PID:'
cat '$EXPORT_DIR/export.pid'
"

echo "Read-only device exporter started."
echo "Streaming actual new export log lines:"

NEXT=1

while :; do
    STATUS_VALUE="$(
        ssh "$DEV" \
            "cat '$DEVICE_STATUS' 2>/dev/null || true" \
            2>/dev/null || true
    )"

    LINES="$(
        ssh "$DEV" \
            "wc -l < '$DEVICE_LOG' 2>/dev/null || echo 0" \
            2>/dev/null || echo 0
    )"

    case "$LINES" in
        ''|*[!0-9]*) LINES=0 ;;
    esac

    if [ "$LINES" -ge "$NEXT" ]; then
        ssh "$DEV" \
            "sed -n '${NEXT},${LINES}p' '$DEVICE_LOG'" \
            || true
        NEXT=$((LINES + 1))
    fi

    if [ -n "$STATUS_VALUE" ]; then
        EXPORT_RC="$STATUS_VALUE"
        break
    fi

    sleep 5
done

if [ "$EXPORT_RC" != "0" ]; then
    echo
    echo "ERROR: read-only topology export failed: $EXPORT_RC"
    ssh "$DEV" \
        "tail -320 '$DEVICE_LOG' 2>/dev/null || true"
    exit 21
fi

ssh "$DEV" "
set -e
test -s '$DEVICE_PACK'

echo '--- topology pack ---'
ls -lh '$DEVICE_PACK'

echo
echo '--- canonical DB after export ---'
stat -c '%s %Y' '$DB'
"

DB_STAT_AFTER_EXPORT="$(
    ssh "$DEV" "stat -c '%s %Y' '$DB'"
)"

if [ "$DB_STAT_AFTER_EXPORT" != "$DB_STAT_BEFORE" ]; then
    echo "ERROR: canonical DB size/mtime changed during read-only export."
    echo "before: $DB_STAT_BEFORE"
    echo "after:  $DB_STAT_AFTER_EXPORT"
    exit 22
fi

echo "PASS: DB size/mtime unchanged."

echo
echo "===== 6/10 COPY PACK TO UBUNTU + FREE DEVICE SD SPACE ====="

scp \
    "$DEV:$DEVICE_PACK" \
    "$OUT/all-interiors.msetpack"

python3 - "$OUT/all-interiors.msetpack" <<'PY_PACK'
from pathlib import Path
import sys

p = Path(sys.argv[1])

with p.open("rb") as f:
    magic = f.read(8)

if magic != b"TSPMSET1":
    raise SystemExit(
        f"ERROR: bad topology pack magic: {magic!r}"
    )

print("PASS: TSPMSET1 pack")
print("bytes:", p.stat().st_size)
PY_PACK

PACK_SHA="$(
    sha256sum "$OUT/all-interiors.msetpack" |
    awk '{print $1}'
)"

echo "Pack SHA: $PACK_SHA"

ssh "$DEV" "
rm -f \
    '$DEVICE_PACK' \
    '$DEVICE_PACK.records.tmp'
sync
"

echo "PASS: temporary pack removed from device SD."

echo
echo "===== 7/10 COMPILE GLOBAL LAZY TOPOLOGY ON UBUNTU ====="

cat > "$OUT/compile_openmw_navmesh_topology.py.b64" <<'EOF_BASE'
IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwoiIiIKT3Blbk1XIC8gRGV0b3VyIE1TRVQgLT4gY29tcGFj
dCBWSVNHUklEIHRvcG9sb2d5IGNvbXBpbGVyLgoKRGVwZW5kZW5jeS1mcmVlLiBQYXJzZXMgT3Bl
bk1XJ3MgYnVpbHQtaW4gYWxsX3RpbGVzX25hdm1lc2guYmluIGRlYnVnIGR1bXAuClRoZSBvdXRw
dXQgaXMgYSBMdWEgZGF0YSBtb2R1bGUuIEl0IGlzIGRlbGliZXJhdGVseSBhIFRPUE9MT0dZIEhJ
TlQsIG5ldmVyIGEKcmVuZGVyLWRpc3RhbmNlIGNsYW1wLgoKQ29vcmRpbmF0ZSBjb252ZXJzaW9u
IGZvciB0aGlzIE9wZW5NVyAwLjUxIGJ1aWxkOgogICAgbmF2LnggPSB3b3JsZC54ICogcmVjYXN0
X3NjYWxlCiAgICBuYXYueSA9IHdvcmxkLnogKiByZWNhc3Rfc2NhbGUKICAgIG5hdi56ID0gLXdv
cmxkLnkgKiByZWNhc3Rfc2NhbGUKClRoZSBzY2FsZSBpcyBpbmZlcnJlZCBmcm9tIGR0TWVzaEhl
YWRlci53YWxrYWJsZUhlaWdodCBhZ2FpbnN0IE9wZW5NVydzCmNhbm9uaWNhbCBhY3Rvci1oZWln
aHQgY29uc3RhbnQuIEZvciB0aGlzIGNhcHR1cmVkIGJ1aWxkIGl0IHJlc29sdmVzIHRvIDM0Cndv
cmxkIHVuaXRzIHBlciBuYXZtZXNoIHVuaXQuCiIiIgpmcm9tIF9fZnV0dXJlX18gaW1wb3J0IGFu
bm90YXRpb25zCmltcG9ydCBhcmdwYXJzZQppbXBvcnQgY29sbGVjdGlvbnMKaW1wb3J0IG1hdGgK
aW1wb3J0IHN0cnVjdApmcm9tIHBhdGhsaWIgaW1wb3J0IFBhdGgKCk1TRVRfTUFHSUMgPSAob3Jk
KCdNJykgPDwgMjQpIHwgKG9yZCgnUycpIDw8IDE2KSB8IChvcmQoJ0UnKSA8PCA4KSB8IG9yZCgn
VCcpCkROQVZfTUFHSUMgPSAob3JkKCdEJykgPDwgMjQpIHwgKG9yZCgnTicpIDw8IDE2KSB8IChv
cmQoJ0EnKSA8PCA4KSB8IG9yZCgnVicpCkdST1VORF9BUkVBID0gNjMKRE9PUl9BUkVBID0gMgpQ
QVRIR1JJRF9BUkVBID0gMwpOQVZfUE9MWV9UWVBFX0dST1VORCA9IDAKTkFWX1BPTFlfVFlQRV9P
RkZNRVNIID0gMQoKZGVmIHJlYWRfbXNldChwYXRoOiBQYXRoKToKICAgIGIgPSBwYXRoLnJlYWRf
Ynl0ZXMoKQogICAgb2ZmID0gMAogICAgbWFnaWMsIHZlcnNpb24sIG51bV90aWxlcyA9IHN0cnVj
dC51bnBhY2tfZnJvbSgiPGlpaSIsIGIsIG9mZikKICAgIG9mZiArPSAxMgogICAgaWYgbWFnaWMg
IT0gTVNFVF9NQUdJQzoKICAgICAgICByYWlzZSBTeXN0ZW1FeGl0KGYiRVJST1I6IG5vdCBEZXRv
dXIgTVNFVCBtYWdpYzogMHh7bWFnaWM6MDh4fSIpCiAgICBpZiB2ZXJzaW9uICE9IDE6CiAgICAg
ICAgcmFpc2UgU3lzdGVtRXhpdChmIkVSUk9SOiB1bnN1cHBvcnRlZCBNU0VUIHZlcnNpb24ge3Zl
cnNpb259IikKICAgIHBhcmFtcyA9IHN0cnVjdC51bnBhY2tfZnJvbSgiPDVmMmkiLCBiLCBvZmYp
CiAgICBvZmYgKz0gMjgKCiAgICB0aWxlcyA9IFtdCiAgICBmb3IgXyBpbiByYW5nZShudW1fdGls
ZXMpOgogICAgICAgIHRpbGVfcmVmLCBzaXplID0gc3RydWN0LnVucGFja19mcm9tKCI8SUkiLCBi
LCBvZmYpCiAgICAgICAgb2ZmICs9IDgKICAgICAgICB0YiA9IGJbb2ZmOm9mZitzaXplXQogICAg
ICAgIG9mZiArPSBzaXplCiAgICAgICAgaWYgbGVuKHRiKSAhPSBzaXplOgogICAgICAgICAgICBy
YWlzZSBTeXN0ZW1FeGl0KCJFUlJPUjogdHJ1bmNhdGVkIHRpbGUiKQogICAgICAgIGhkcl9pID0g
c3RydWN0LnVucGFja19mcm9tKCI8MTVpIiwgdGIsIDApCiAgICAgICAgaGRyX2YgPSBzdHJ1Y3Qu
dW5wYWNrX2Zyb20oIjwxMGYiLCB0YiwgNjApCiAgICAgICAgaWYgaGRyX2lbMF0gIT0gRE5BVl9N
QUdJQzoKICAgICAgICAgICAgcmFpc2UgU3lzdGVtRXhpdChmIkVSUk9SOiBiYWQgRE5BViBtYWdp
YyAweHtoZHJfaVswXTowOHh9IikKICAgICAgICB0aWxlcy5hcHBlbmQocGFyc2VfdGlsZSh0aWxl
X3JlZiwgdGIsIGhkcl9pLCBoZHJfZikpCiAgICBpZiBvZmYgIT0gbGVuKGIpOgogICAgICAgIHJh
aXNlIFN5c3RlbUV4aXQoZiJFUlJPUjogdHJhaWxpbmcgYnl0ZXM6IHBhcnNlZD17b2ZmfSB0b3Rh
bD17bGVuKGIpfSIpCiAgICByZXR1cm4gcGFyYW1zLCB0aWxlcwoKZGVmIHBhcnNlX3RpbGUodGls
ZV9yZWYsIHRiLCBoaSwgaGYpOgogICAgKG1hZ2ljLCB2ZXJzaW9uLCB0eCwgdHksIGxheWVyLCB1
c2VyX2lkLCBwb2x5X2NvdW50LCB2ZXJ0X2NvdW50LAogICAgIG1heF9saW5rX2NvdW50LCBkZXRh
aWxfbWVzaF9jb3VudCwgZGV0YWlsX3ZlcnRfY291bnQsIGRldGFpbF90cmlfY291bnQsCiAgICAg
YnZfbm9kZV9jb3VudCwgb2ZmbWVzaF9jb3VudCwgb2ZmbWVzaF9iYXNlKSA9IGhpCgogICAgb2Zm
ID0gMTAwCiAgICB2ZXJ0cyA9IFtzdHJ1Y3QudW5wYWNrX2Zyb20oIjwzZiIsIHRiLCBvZmYraSox
MikgZm9yIGkgaW4gcmFuZ2UodmVydF9jb3VudCldCiAgICBvZmYgKz0gdmVydF9jb3VudCAqIDEy
CgogICAgcG9seXMgPSBbXQogICAgZm9yIGkgaW4gcmFuZ2UocG9seV9jb3VudCk6CiAgICAgICAg
YmFzZSA9IG9mZiArIGkqMzIKICAgICAgICBwdiA9IHN0cnVjdC51bnBhY2tfZnJvbSgiPDZIIiwg
dGIsIGJhc2UrNCkKICAgICAgICBuZWlzID0gc3RydWN0LnVucGFja19mcm9tKCI8NkgiLCB0Yiwg
YmFzZSsxNikKICAgICAgICBmbGFncyA9IHN0cnVjdC51bnBhY2tfZnJvbSgiPEgiLCB0YiwgYmFz
ZSsyOClbMF0KICAgICAgICB2YyA9IHRiW2Jhc2UrMzBdCiAgICAgICAgYXQgPSB0YltiYXNlKzMx
XQogICAgICAgIHBvbHlzLmFwcGVuZCh7CiAgICAgICAgICAgICJ2ZXJ0cyI6IHB2Wzp2Y10sCiAg
ICAgICAgICAgICJuZWlzIjogbmVpc1s6dmNdLAogICAgICAgICAgICAiZmxhZ3MiOiBmbGFncywK
ICAgICAgICAgICAgImNvdW50IjogdmMsCiAgICAgICAgICAgICJhcmVhIjogYXQgJiAweDNmLAog
ICAgICAgICAgICAidHlwZSI6IGF0ID4+IDYsCiAgICAgICAgfSkKICAgIG9mZiArPSBwb2x5X2Nv
dW50ICogMzIKCiAgICAjIGR0TGluayA9IDEyOyBkdFBvbHlEZXRhaWwgPSAxMjsgZGV0YWlsIHZl
cnQgPSAxMjsKICAgICMgZGV0YWlsIHRyaSA9IDQ7IGR0QlZOb2RlID0gMTY7IGR0T2ZmTWVzaENv
bm5lY3Rpb24gPSAzNi4KICAgIG9mZiArPSBtYXhfbGlua19jb3VudCAqIDEyCiAgICBvZmYgKz0g
ZGV0YWlsX21lc2hfY291bnQgKiAxMgogICAgb2ZmICs9IGRldGFpbF92ZXJ0X2NvdW50ICogMTIK
ICAgIG9mZiArPSBkZXRhaWxfdHJpX2NvdW50ICogNAogICAgb2ZmICs9IGJ2X25vZGVfY291bnQg
KiAxNgoKICAgIG9mZm1lc2ggPSBbXQogICAgZm9yIGkgaW4gcmFuZ2Uob2ZmbWVzaF9jb3VudCk6
CiAgICAgICAgYmFzZSA9IG9mZiArIGkqMzYKICAgICAgICBwb3MgPSBzdHJ1Y3QudW5wYWNrX2Zy
b20oIjw2ZiIsIHRiLCBiYXNlKQogICAgICAgIHJhZCA9IHN0cnVjdC51bnBhY2tfZnJvbSgiPGYi
LCB0YiwgYmFzZSsyNClbMF0KICAgICAgICBwb2x5ID0gc3RydWN0LnVucGFja19mcm9tKCI8SCIs
IHRiLCBiYXNlKzI4KVswXQogICAgICAgIGZsYWdzID0gdGJbYmFzZSszMF0KICAgICAgICBzaWRl
ID0gdGJbYmFzZSszMV0KICAgICAgICB1aWQgPSBzdHJ1Y3QudW5wYWNrX2Zyb20oIjxJIiwgdGIs
IGJhc2UrMzIpWzBdCiAgICAgICAgb2ZmbWVzaC5hcHBlbmQoewogICAgICAgICAgICAicG9zIjog
cG9zLCAicmFkIjogcmFkLCAicG9seSI6IHBvbHksCiAgICAgICAgICAgICJmbGFncyI6IGZsYWdz
LCAic2lkZSI6IHNpZGUsICJ1aWQiOiB1aWQsCiAgICAgICAgfSkKICAgIG9mZiArPSBvZmZtZXNo
X2NvdW50ICogMzYKCiAgICBpZiBvZmYgIT0gbGVuKHRiKToKICAgICAgICByYWlzZSBTeXN0ZW1F
eGl0KAogICAgICAgICAgICBmIkVSUk9SOiB0aWxlICh7dHh9LHt0eX0pIHN0cnVjdHVyZSBtaXNt
YXRjaDogcGFyc2VkPXtvZmZ9IGJ5dGVzPXtsZW4odGIpfSIKICAgICAgICApCgogICAgcmV0dXJu
IHsKICAgICAgICAicmVmIjogdGlsZV9yZWYsICJ4IjogdHgsICJ5IjogdHksICJsYXllciI6IGxh
eWVyLAogICAgICAgICJ2ZXJ0cyI6IHZlcnRzLCAicG9seXMiOiBwb2x5cywgIm9mZm1lc2giOiBv
ZmZtZXNoLAogICAgICAgICJvZmZtZXNoX2Jhc2UiOiBvZmZtZXNoX2Jhc2UsCiAgICAgICAgIndh
bGthYmxlX2hlaWdodCI6IGhmWzBdLAogICAgICAgICJ3YWxrYWJsZV9yYWRpdXMiOiBoZlsxXSwK
ICAgICAgICAid2Fsa2FibGVfY2xpbWIiOiBoZlsyXSwKICAgICAgICAiYm1pbiI6IGhmWzM6Nl0s
ICJibWF4IjogaGZbNjo5XSwKICAgIH0KCmRlZiBxdih2KToKICAgIHJldHVybiB0dXBsZShyb3Vu
ZCh4LCA0KSBmb3IgeCBpbiB2KQoKZGVmIGFyZWFfeHooY29vcmRzKToKICAgIHMgPSAwLjAKICAg
IGZvciBpLCBhIGluIGVudW1lcmF0ZShjb29yZHMpOgogICAgICAgIGIgPSBjb29yZHNbKGkrMSkg
JSBsZW4oY29vcmRzKV0KICAgICAgICBzICs9IGFbMF0gKiBiWzJdIC0gYlswXSAqIGFbMl0KICAg
IHJldHVybiBhYnMocykgKiAwLjUKCmRlZiBkZXRlY3Rfc2NhbGUodGlsZXMpOgogICAgIyBPcGVu
TVcncyBwbGF5ZXIgbmF2aWdhdGlvbiBoZWlnaHQgaW4gdGhpcyBidWlsZCB5aWVsZHMgZXhhY3Rs
eSAxMzMgd29ybGQKICAgICMgdW5pdHMgLyAzLjkxMTc2NDYgbmF2IHVuaXRzID0gMzQuIFRoaXMg
YWxzbyBtYXRjaGVzIHRoZSBrbm93biByZWNhc3QKICAgICMgc2NhbGUgZmFjdG9yIDEvMzQuIFVz
ZSBuZWFyZXN0IGludGVnZXIgb25seSB3aGVuIHRoZSByYXRpbyBpcyB2ZXJ5IGNsb3NlLgogICAg
aCA9IG5leHQodFsid2Fsa2FibGVfaGVpZ2h0Il0gZm9yIHQgaW4gdGlsZXMgaWYgdFsid2Fsa2Fi
bGVfaGVpZ2h0Il0gPiAwKQogICAgZXN0aW1hdGUgPSAxMzMuMCAvIGgKICAgIHJvdW5kZWQgPSBy
b3VuZChlc3RpbWF0ZSkKICAgIGlmIGFicyhlc3RpbWF0ZSAtIHJvdW5kZWQpIDwgMC4wNSBhbmQg
MTYgPD0gcm91bmRlZCA8PSAxMjg6CiAgICAgICAgcmV0dXJuIGZsb2F0KHJvdW5kZWQpCiAgICBy
ZXR1cm4gMzQuMAoKZGVmIG5hdl90b193b3JsZCh2LCBzY2FsZSk6CiAgICByZXR1cm4gKHZbMF0q
c2NhbGUsIC12WzJdKnNjYWxlLCB2WzFdKnNjYWxlKQoKZGVmIGJ1aWxkX2dyb3VuZCh0aWxlcyk6
CiAgICBncm91bmQgPSBbXQogICAgZm9yIHRpLCB0IGluIGVudW1lcmF0ZSh0aWxlcyk6CiAgICAg
ICAgZm9yIHBpLCBwIGluIGVudW1lcmF0ZSh0WyJwb2x5cyJdKToKICAgICAgICAgICAgaWYgcFsi
dHlwZSJdICE9IE5BVl9QT0xZX1RZUEVfR1JPVU5EIG9yIHBbImFyZWEiXSAhPSBHUk9VTkRfQVJF
QToKICAgICAgICAgICAgICAgIGNvbnRpbnVlCiAgICAgICAgICAgIGNvb3JkcyA9IFt0WyJ2ZXJ0
cyJdW3ZpXSBmb3IgdmkgaW4gcFsidmVydHMiXV0KICAgICAgICAgICAgYyA9IHR1cGxlKHN1bSh2
W2tdIGZvciB2IGluIGNvb3JkcykvbGVuKGNvb3JkcykgZm9yIGsgaW4gcmFuZ2UoMykpCiAgICAg
ICAgICAgIGdyb3VuZC5hcHBlbmQoewogICAgICAgICAgICAgICAgInRpIjogdGksICJwaSI6IHBp
LCAiY29vcmRzIjogY29vcmRzLCAiYyI6IGMsCiAgICAgICAgICAgICAgICAieXJhbmdlIjogbWF4
KHZbMV0gZm9yIHYgaW4gY29vcmRzKS1taW4odlsxXSBmb3IgdiBpbiBjb29yZHMpLAogICAgICAg
ICAgICB9KQogICAgcmV0dXJuIGdyb3VuZAoKZGVmIGJ1aWxkX2FkamFjZW5jeShncm91bmQpOgog
ICAgZWRnZXMgPSBjb2xsZWN0aW9ucy5kZWZhdWx0ZGljdChsaXN0KQogICAgZm9yIGdpLCBwIGlu
IGVudW1lcmF0ZShncm91bmQpOgogICAgICAgIGMgPSBwWyJjb29yZHMiXQogICAgICAgIGZvciBp
IGluIHJhbmdlKGxlbihjKSk6CiAgICAgICAgICAgIGEsIGIgPSBxdihjW2ldKSwgcXYoY1soaSsx
KSAlIGxlbihjKV0pCiAgICAgICAgICAgIGVkZ2VzW3R1cGxlKHNvcnRlZCgoYSxiKSkpXS5hcHBl
bmQoZ2kpCiAgICBhZGogPSBbc2V0KCkgZm9yIF8gaW4gZ3JvdW5kXQogICAgZm9yIG1lbWJlcnMg
aW4gZWRnZXMudmFsdWVzKCk6CiAgICAgICAgaWYgbGVuKG1lbWJlcnMpID49IDI6CiAgICAgICAg
ICAgIGZvciBhIGluIG1lbWJlcnM6CiAgICAgICAgICAgICAgICBmb3IgYiBpbiBtZW1iZXJzOgog
ICAgICAgICAgICAgICAgICAgIGlmIGEgIT0gYjoKICAgICAgICAgICAgICAgICAgICAgICAgYWRq
W2FdLmFkZChiKQogICAgcmV0dXJuIGFkagoKZGVmIGZpbmRfZmxvb3JfcGVha3MoZ3JvdW5kKToK
ICAgIGhpc3QgPSBjb2xsZWN0aW9ucy5Db3VudGVyKHJvdW5kKHBbImMiXVsxXSoyLjApLzIuMCBm
b3IgcCBpbiBncm91bmQpCiAgICBtaW5fc3VwcG9ydCA9IG1heCgxMCwgcm91bmQobGVuKGdyb3Vu
ZCkqMC4wMykpCiAgICBjYW5kcyA9IFsobiwgeSkgZm9yIHksIG4gaW4gaGlzdC5pdGVtcygpIGlm
IG4gPj0gbWluX3N1cHBvcnRdCiAgICBjYW5kcy5zb3J0KHJldmVyc2U9VHJ1ZSkKICAgIHBlYWtz
ID0gW10KICAgIGZvciBuLCB5IGluIGNhbmRzOgogICAgICAgIGlmIGFsbChhYnMoeS16KSA+PSAz
LjAgZm9yIHogaW4gcGVha3MpOgogICAgICAgICAgICBwZWFrcy5hcHBlbmQoeSkKICAgIHBlYWtz
LnNvcnQoKQogICAgaWYgbm90IHBlYWtzOgogICAgICAgIHBlYWtzID0gW3JvdW5kKHN1bShwWyJj
Il1bMV0gZm9yIHAgaW4gZ3JvdW5kKS9sZW4oZ3JvdW5kKSoyKS8yXQogICAgcmV0dXJuIHBlYWtz
LCBoaXN0CgpkZWYgY29tcG9uZW50cyhub2RlcywgYWRqKToKICAgIG5vZGVzID0gc2V0KG5vZGVz
KQogICAgc2VlbiA9IHNldCgpCiAgICBvdXQgPSBbXQogICAgZm9yIHN0YXJ0IGluIHNvcnRlZChu
b2Rlcyk6CiAgICAgICAgaWYgc3RhcnQgaW4gc2VlbjoKICAgICAgICAgICAgY29udGludWUKICAg
ICAgICBzZWVuLmFkZChzdGFydCkKICAgICAgICBzdGFjayA9IFtzdGFydF0KICAgICAgICBjb21w
ID0gW10KICAgICAgICB3aGlsZSBzdGFjazoKICAgICAgICAgICAgdSA9IHN0YWNrLnBvcCgpCiAg
ICAgICAgICAgIGNvbXAuYXBwZW5kKHUpCiAgICAgICAgICAgIGZvciB2IGluIGFkalt1XToKICAg
ICAgICAgICAgICAgIGlmIHYgaW4gbm9kZXMgYW5kIHYgbm90IGluIHNlZW46CiAgICAgICAgICAg
ICAgICAgICAgc2Vlbi5hZGQodikKICAgICAgICAgICAgICAgICAgICBzdGFjay5hcHBlbmQodikK
ICAgICAgICBvdXQuYXBwZW5kKGNvbXApCiAgICByZXR1cm4gb3V0CgpkZWYgbWFrZV9zZWN0b3Jz
KGdyb3VuZCwgYWRqLCBwZWFrcywgc2NhbGUpOgogICAgIyBBIHBvbHlnb24gYmVsb25ncyB0byBh
IHBsYXRlYXUgd2hlbiBpdHMgY2VudHJvaWQgaXMgY2xvc2UgdG8gYSBzdHJvbmcKICAgICMgaGVp
Z2h0IG1vZGUuIEV2ZXJ5dGhpbmcgYmV0d2VlbiBwbGF0ZWF1cyBiZWNvbWVzIGEgdmVydGljYWwg
Y29ubmVjdG9yLgogICAgYXNzaWduID0ge30KICAgIGZvciBpLHAgaW4gZW51bWVyYXRlKGdyb3Vu
ZCk6CiAgICAgICAgbmVhcmVzdCA9IG1pbihyYW5nZShsZW4ocGVha3MpKSwga2V5PWxhbWJkYSBr
OiBhYnMocFsiYyJdWzFdLXBlYWtzW2tdKSkKICAgICAgICBkaXN0ID0gYWJzKHBbImMiXVsxXS1w
ZWFrc1tuZWFyZXN0XSkKICAgICAgICBpZiBkaXN0IDw9IDIuMDoKICAgICAgICAgICAgYXNzaWdu
W2ldID0gKCJmbG9vciIsIG5lYXJlc3QpCiAgICAgICAgZWxzZToKICAgICAgICAgICAgYXNzaWdu
W2ldID0gKCJjb25uZWN0b3IiLCAtMSkKCiAgICByYXcgPSBbXQogICAgZm9yIGZpIGluIHJhbmdl
KGxlbihwZWFrcykpOgogICAgICAgIG5zID0gW2kgZm9yIGksYSBpbiBhc3NpZ24uaXRlbXMoKSBp
ZiBhID09ICgiZmxvb3IiLCBmaSldCiAgICAgICAgZm9yIGNvbXAgaW4gY29tcG9uZW50cyhucywg
YWRqKToKICAgICAgICAgICAgcmF3LmFwcGVuZCh7ImtpbmQwIjoiZmxvb3IiLCAiZmxvb3IiOmZp
LCAicG9seXMiOmNvbXB9KQogICAgbnMgPSBbaSBmb3IgaSxhIGluIGFzc2lnbi5pdGVtcygpIGlm
IGFbMF0gPT0gImNvbm5lY3RvciJdCiAgICBmb3IgY29tcCBpbiBjb21wb25lbnRzKG5zLCBhZGop
OgogICAgICAgIHJhdy5hcHBlbmQoeyJraW5kMCI6ImNvbm5lY3RvciIsICJmbG9vciI6LTEsICJw
b2x5cyI6Y29tcH0pCgogICAgIyBUaW55IGlzbGFuZHMgaW5oZXJpdCB0aGUgbmVhcmVzdCBhZGph
Y2VudCBsYXJnZXIgc2VjdG9yIHdoZXJlIHBvc3NpYmxlLgogICAgcG9seV90b19yYXcgPSB7fQog
ICAgZm9yIHNpLHMgaW4gZW51bWVyYXRlKHJhdyk6CiAgICAgICAgZm9yIHAgaW4gc1sicG9seXMi
XToKICAgICAgICAgICAgcG9seV90b19yYXdbcF0gPSBzaQogICAgZm9yIHNpLHMgaW4gZW51bWVy
YXRlKHJhdyk6CiAgICAgICAgaWYgbGVuKHNbInBvbHlzIl0pID49IDM6CiAgICAgICAgICAgIGNv
bnRpbnVlCiAgICAgICAgdm90ZXMgPSBjb2xsZWN0aW9ucy5Db3VudGVyKCkKICAgICAgICBmb3Ig
cCBpbiBzWyJwb2x5cyJdOgogICAgICAgICAgICBmb3IgcSBpbiBhZGpbcF06CiAgICAgICAgICAg
ICAgICBzaiA9IHBvbHlfdG9fcmF3LmdldChxKQogICAgICAgICAgICAgICAgaWYgc2ogaXMgbm90
IE5vbmUgYW5kIHNqICE9IHNpIGFuZCBsZW4ocmF3W3NqXVsicG9seXMiXSkgPj0gMzoKICAgICAg
ICAgICAgICAgICAgICB2b3Rlc1tzal0gKz0gMQogICAgICAgIGlmIHZvdGVzOgogICAgICAgICAg
ICB0YXJnZXQgPSB2b3Rlcy5tb3N0X2NvbW1vbigxKVswXVswXQogICAgICAgICAgICByYXdbdGFy
Z2V0XVsicG9seXMiXS5leHRlbmQoc1sicG9seXMiXSkKICAgICAgICAgICAgc1sicG9seXMiXSA9
IFtdCgogICAgcmF3ID0gW3MgZm9yIHMgaW4gcmF3IGlmIHNbInBvbHlzIl1dCiAgICBwb2x5X3Rv
X3NlY3RvciA9IHt9CiAgICBzZWN0b3JzID0gW10KICAgIGZvciBzaWQwLHMgaW4gZW51bWVyYXRl
KHJhdywgc3RhcnQ9MSk6CiAgICAgICAgcHMgPSBbZ3JvdW5kW2ldIGZvciBpIGluIHNbInBvbHlz
Il1dCiAgICAgICAgd29ybGRfcHRzID0gW25hdl90b193b3JsZCh2LCBzY2FsZSkgZm9yIHAgaW4g
cHMgZm9yIHYgaW4gcFsiY29vcmRzIl1dCiAgICAgICAgeHM9W3ZbMF0gZm9yIHYgaW4gd29ybGRf
cHRzXTsgeXM9W3ZbMV0gZm9yIHYgaW4gd29ybGRfcHRzXTsgenM9W3ZbMl0gZm9yIHYgaW4gd29y
bGRfcHRzXQogICAgICAgIGFyZWEgPSBzdW0oYXJlYV94eihwWyJjb29yZHMiXSkgZm9yIHAgaW4g
cHMpICogc2NhbGUgKiBzY2FsZQogICAgICAgIGJ4PW1heCh4cyktbWluKHhzKTsgYnk9bWF4KHlz
KS1taW4oeXMpCiAgICAgICAgYmJveF9hcmVhPW1heCgxLjAsYngqYnkpCiAgICAgICAgYXNwZWN0
PW1heChieCxieSkvbWF4KDEuMCxtaW4oYngsYnkpKQogICAgICAgIGZpbGw9YXJlYS9iYm94X2Fy
ZWEKICAgICAgICB6c3Bhbj1tYXgoenMpLW1pbih6cykKCiAgICAgICAgaWYgc1sia2luZDAiXSA9
PSAiY29ubmVjdG9yIiBvciB6c3BhbiA+IDE1MDoKICAgICAgICAgICAga2luZD0idmVydGljYWxf
Y29ubmVjdG9yIgogICAgICAgIGVsaWYgYXJlYSA+PSAxODAwMDA6CiAgICAgICAgICAgIGtpbmQ9
ImxhcmdlX29wZW4iCiAgICAgICAgZWxpZiBhc3BlY3QgPj0gMy4yIGFuZCBmaWxsIDwgMC40NToK
ICAgICAgICAgICAga2luZD0iY29ycmlkb3IiCiAgICAgICAgZWxpZiBhcmVhIDwgNDUwMDA6CiAg
ICAgICAgICAgIGtpbmQ9InNtYWxsX3Jvb20iCiAgICAgICAgZWxzZToKICAgICAgICAgICAga2lu
ZD0icm9vbSIKCiAgICAgICAgY3hzPVtdOyBjeXM9W107IGN6cz1bXQogICAgICAgIGZvciBwIGlu
IHBzOgogICAgICAgICAgICB3Yz1uYXZfdG9fd29ybGQocFsiYyJdLHNjYWxlKQogICAgICAgICAg
ICBjeHMuYXBwZW5kKHdjWzBdKTsgY3lzLmFwcGVuZCh3Y1sxXSk7IGN6cy5hcHBlbmQod2NbMl0p
CgogICAgICAgIHNlY3Rvcj17CiAgICAgICAgICAgICJpZCI6c2lkMCwgImZsb29yIjpzWyJmbG9v
ciJdKzEgaWYgc1siZmxvb3IiXT49MCBlbHNlIDAsCiAgICAgICAgICAgICJraW5kIjpraW5kLCAi
cG9seV9jb3VudCI6bGVuKHBzKSwgImFyZWEiOnJvdW5kKGFyZWEpLAogICAgICAgICAgICAiYmJv
eCI6W3JvdW5kKG1pbih4cyksMSkscm91bmQobWluKHlzKSwxKSxyb3VuZChtaW4oenMpLDEpLAog
ICAgICAgICAgICAgICAgICAgIHJvdW5kKG1heCh4cyksMSkscm91bmQobWF4KHlzKSwxKSxyb3Vu
ZChtYXgoenMpLDEpXSwKICAgICAgICAgICAgImNlbnRlciI6W3JvdW5kKHN1bShjeHMpL2xlbihj
eHMpLDEpLHJvdW5kKHN1bShjeXMpL2xlbihjeXMpLDEpLHJvdW5kKHN1bShjenMpL2xlbihjenMp
LDEpXSwKICAgICAgICAgICAgIm5laWdoYm9ycyI6c2V0KCksICJwb3J0YWxzIjpbXSwKICAgICAg
ICAgICAgIl9wb2x5cyI6bGlzdChzWyJwb2x5cyJdKSwKICAgICAgICB9CiAgICAgICAgc2VjdG9y
cy5hcHBlbmQoc2VjdG9yKQogICAgICAgIGZvciBnaSBpbiBzWyJwb2x5cyJdOgogICAgICAgICAg
ICBwb2x5X3RvX3NlY3RvcltnaV09c2lkMAoKICAgICMgc3RydWN0dXJhbCBhZGphY2VuY3kgYWNy
b3NzIHBvbHlnb24gZWRnZXMKICAgIGZvciBhIGluIHJhbmdlKGxlbihncm91bmQpKToKICAgICAg
ICBzYT1wb2x5X3RvX3NlY3Rvci5nZXQoYSkKICAgICAgICBpZiBzYSBpcyBOb25lOiBjb250aW51
ZQogICAgICAgIGZvciBiIGluIGFkalthXToKICAgICAgICAgICAgc2I9cG9seV90b19zZWN0b3Iu
Z2V0KGIpCiAgICAgICAgICAgIGlmIHNiIGlzIG5vdCBOb25lIGFuZCBzYiAhPSBzYToKICAgICAg
ICAgICAgICAgIHNlY3RvcnNbc2EtMV1bIm5laWdoYm9ycyJdLmFkZChzYikKICAgICAgICAgICAg
ICAgIHNlY3RvcnNbc2ItMV1bIm5laWdoYm9ycyJdLmFkZChzYSkKCiAgICByZXR1cm4gc2VjdG9y
cywgcG9seV90b19zZWN0b3IKCmRlZiBuZWFyZXN0X2dyb3VuZF9zZWN0b3IocHQsIGdyb3VuZCwg
cG9seV90b19zZWN0b3IpOgogICAgYmVzdD0oZmxvYXQoImluZiIpLE5vbmUpCiAgICBmb3IgZ2ks
cCBpbiBlbnVtZXJhdGUoZ3JvdW5kKToKICAgICAgICBzaWQ9cG9seV90b19zZWN0b3IuZ2V0KGdp
KQogICAgICAgIGlmIHNpZCBpcyBOb25lOiBjb250aW51ZQogICAgICAgIGM9cFsiYyJdCiAgICAg
ICAgZD0oY1swXS1wdFswXSkqKjIrKGNbMV0tcHRbMV0pKioyKyhjWzJdLXB0WzJdKSoqMgogICAg
ICAgIGlmIGQ8YmVzdFswXToKICAgICAgICAgICAgYmVzdD0oZCxzaWQpCiAgICByZXR1cm4gYmVz
dFsxXQoKZGVmIG1ha2VfcG9ydGFscyh0aWxlcywgZ3JvdW5kLCBwb2x5X3RvX3NlY3Rvciwgc2Nh
bGUpOgogICAgcmF3PVtdCiAgICBmb3IgdCBpbiB0aWxlczoKICAgICAgICBmb3Igb20gaW4gdFsi
b2ZmbWVzaCJdOgogICAgICAgICAgICBwb2x5PXRbInBvbHlzIl1bb21bInBvbHkiXV0KICAgICAg
ICAgICAgaWYgcG9seVsidHlwZSJdICE9IE5BVl9QT0xZX1RZUEVfT0ZGTUVTSDoKICAgICAgICAg
ICAgICAgIGNvbnRpbnVlCiAgICAgICAgICAgICMgUnVudGltZSB2aXN1YWwgdG9wb2xvZ3kgdXNl
cyBleHBsaWNpdCBkb29ycyBvbmx5LiBQYXRoZ3JpZAogICAgICAgICAgICAjIG9mZi1tZXNoIGxp
bmtzIGFyZSBBSS1yb3V0aW5nIGhpbnRzLCBub3QgZ3VhcmFudGVlZCBzaWdodCBwb3J0YWxzLgog
ICAgICAgICAgICBpZiBwb2x5WyJhcmVhIl0gIT0gRE9PUl9BUkVBOgogICAgICAgICAgICAgICAg
Y29udGludWUKICAgICAgICAgICAgcD1vbVsicG9zIl0KICAgICAgICAgICAgYT0ocFswXSxwWzFd
LHBbMl0pOyBiPShwWzNdLHBbNF0scFs1XSkKICAgICAgICAgICAgcmF3LmFwcGVuZCgocG9seVsi
YXJlYSJdLGEsYikpCgogICAgIyBEZWR1cGxpY2F0ZSB0aGUgYmlkaXJlY3Rpb25hbCBjb3BpZXMg
Ynkgcm91bmRlZCB1bm9yZGVyZWQgZW5kcG9pbnRzLgogICAgdW5pcT17fQogICAgZm9yIGFyZWEs
YSxiIGluIHJhdzoKICAgICAgICBrYT10dXBsZShyb3VuZCh4LDMpIGZvciB4IGluIGEpCiAgICAg
ICAga2I9dHVwbGUocm91bmQoeCwzKSBmb3IgeCBpbiBiKQogICAgICAgIGtleT0oYXJlYSx0dXBs
ZShzb3J0ZWQoKGthLGtiKSkpKQogICAgICAgIHVuaXFba2V5XT0oYXJlYSxhLGIpCgogICAgcG9y
dGFscz1bXQogICAgZm9yIHBpZCwoYXJlYSxhLGIpIGluIGVudW1lcmF0ZSh1bmlxLnZhbHVlcygp
LHN0YXJ0PTEpOgogICAgICAgIHNhPW5lYXJlc3RfZ3JvdW5kX3NlY3RvcihhLGdyb3VuZCxwb2x5
X3RvX3NlY3RvcikKICAgICAgICBzYj1uZWFyZXN0X2dyb3VuZF9zZWN0b3IoYixncm91bmQscG9s
eV90b19zZWN0b3IpCiAgICAgICAgd2E9bmF2X3RvX3dvcmxkKGEsc2NhbGUpOyB3Yj1uYXZfdG9f
d29ybGQoYixzY2FsZSkKICAgICAgICBjZW50ZXI9dHVwbGUoKHdhW2ldK3diW2ldKSowLjUgZm9y
IGkgaW4gcmFuZ2UoMykpCiAgICAgICAgcG9ydGFscy5hcHBlbmQoewogICAgICAgICAgICAiaWQi
OnBpZCwKICAgICAgICAgICAgImtpbmQiOiJkb29yIiBpZiBhcmVhPT1ET09SX0FSRUEgZWxzZSAi
cGF0aGdyaWQiLAogICAgICAgICAgICAiYV9zZWN0b3IiOnNhIG9yIDAsICJiX3NlY3RvciI6c2Ig
b3IgMCwKICAgICAgICAgICAgImEiOltyb3VuZCh4LDEpIGZvciB4IGluIHdhXSwgImIiOltyb3Vu
ZCh4LDEpIGZvciB4IGluIHdiXSwKICAgICAgICAgICAgImNlbnRlciI6W3JvdW5kKHgsMSkgZm9y
IHggaW4gY2VudGVyXSwKICAgICAgICB9KQogICAgcmV0dXJuIHBvcnRhbHMKCgpkZWYgbWFrZV9i
b3VuZGFyeV9wb3J0YWxzKGdyb3VuZCwgYWRqLCBwb2x5X3RvX3NlY3Rvciwgc2NhbGUsIHN0YXJ0
X2lkKToKICAgICIiIkNyZWF0ZSBwb3J0YWwgaGludHMgYXQgc2hhcmVkIGVkZ2VzIHRoYXQgY3Jv
c3Mgb3VyIHNlY3RvciBwYXJ0aXRpb24uIiIiCiAgICBncm91cHMgPSBjb2xsZWN0aW9ucy5kZWZh
dWx0ZGljdChsaXN0KQogICAgc2VlbiA9IHNldCgpCiAgICBmb3IgYSBpbiByYW5nZShsZW4oZ3Jv
dW5kKSk6CiAgICAgICAgc2EgPSBwb2x5X3RvX3NlY3Rvci5nZXQoYSkKICAgICAgICBpZiBzYSBp
cyBOb25lOgogICAgICAgICAgICBjb250aW51ZQogICAgICAgIGNhID0gZ3JvdW5kW2FdWyJjb29y
ZHMiXQogICAgICAgIGVkZ2VzX2EgPSB7fQogICAgICAgIGZvciBpIGluIHJhbmdlKGxlbihjYSkp
OgogICAgICAgICAgICB2YSwgdmIgPSBxdihjYVtpXSksIHF2KGNhWyhpKzEpJWxlbihjYSldKQog
ICAgICAgICAgICBlZGdlc19hW3R1cGxlKHNvcnRlZCgodmEsdmIpKSldID0gKGNhW2ldLCBjYVso
aSsxKSVsZW4oY2EpXSkKICAgICAgICBmb3IgYiBpbiBhZGpbYV06CiAgICAgICAgICAgIGlmIGIg
PD0gYToKICAgICAgICAgICAgICAgIGNvbnRpbnVlCiAgICAgICAgICAgIHNiID0gcG9seV90b19z
ZWN0b3IuZ2V0KGIpCiAgICAgICAgICAgIGlmIHNiIGlzIE5vbmUgb3Igc2IgPT0gc2E6CiAgICAg
ICAgICAgICAgICBjb250aW51ZQogICAgICAgICAgICBjYiA9IGdyb3VuZFtiXVsiY29vcmRzIl0K
ICAgICAgICAgICAgZWRnZXNfYiA9IHt9CiAgICAgICAgICAgIGZvciBpIGluIHJhbmdlKGxlbihj
YikpOgogICAgICAgICAgICAgICAgdmEsIHZiID0gcXYoY2JbaV0pLCBxdihjYlsoaSsxKSVsZW4o
Y2IpXSkKICAgICAgICAgICAgICAgIGVkZ2VzX2JbdHVwbGUoc29ydGVkKCh2YSx2YikpKV0gPSAo
Y2JbaV0sIGNiWyhpKzEpJWxlbihjYildKQogICAgICAgICAgICBjb21tb24gPSBzZXQoZWRnZXNf
YSkuaW50ZXJzZWN0aW9uKGVkZ2VzX2IpCiAgICAgICAgICAgIGZvciBrZXkgaW4gY29tbW9uOgog
ICAgICAgICAgICAgICAgdmEsdmIgPSBlZGdlc19hW2tleV0KICAgICAgICAgICAgICAgIG1pZCA9
IHR1cGxlKCh2YVtrXSt2YltrXSkqMC41IGZvciBrIGluIHJhbmdlKDMpKQogICAgICAgICAgICAg
ICAgZ3JvdXBzW3R1cGxlKHNvcnRlZCgoc2Esc2IpKSldLmFwcGVuZChtaWQpCgogICAgcG9ydGFs
cz1bXQogICAgcGlkPXN0YXJ0X2lkCiAgICBmb3IgKHNhLHNiKSwgbWlkcyBpbiBzb3J0ZWQoZ3Jv
dXBzLml0ZW1zKCkpOgogICAgICAgICMgQXZlcmFnZSBhbGwgbmVpZ2hib3Jpbmcgc2hhcmVkLWVk
Z2UgbWlkcG9pbnRzIGludG8gb25lIGNvYXJzZSBwb3J0YWwKICAgICAgICAjIGhpbnQgYmV0d2Vl
biB0aGUgdHdvIHNlY3RvcnMuCiAgICAgICAgbT10dXBsZShzdW0odltrXSBmb3IgdiBpbiBtaWRz
KS9sZW4obWlkcykgZm9yIGsgaW4gcmFuZ2UoMykpCiAgICAgICAgdz1uYXZfdG9fd29ybGQobSxz
Y2FsZSkKICAgICAgICBwb3J0YWxzLmFwcGVuZCh7CiAgICAgICAgICAgICJpZCI6cGlkLCAia2lu
ZCI6ImJvdW5kYXJ5IiwKICAgICAgICAgICAgImFfc2VjdG9yIjpzYSwgImJfc2VjdG9yIjpzYiwK
ICAgICAgICAgICAgImEiOltyb3VuZCh4LDEpIGZvciB4IGluIHddLCAiYiI6W3JvdW5kKHgsMSkg
Zm9yIHggaW4gd10sCiAgICAgICAgICAgICJjZW50ZXIiOltyb3VuZCh4LDEpIGZvciB4IGluIHdd
LAogICAgICAgIH0pCiAgICAgICAgcGlkICs9IDEKICAgIHJldHVybiBwb3J0YWxzCgpkZWYgYnVp
bGRfYnVja2V0cyhncm91bmQsIHBvbHlfdG9fc2VjdG9yLCBzY2FsZSwgYnVja2V0PTM4NCk6CiAg
ICBidWNrZXRzPWNvbGxlY3Rpb25zLmRlZmF1bHRkaWN0KGxpc3QpCiAgICBmb3IgZ2kscCBpbiBl
bnVtZXJhdGUoZ3JvdW5kKToKICAgICAgICBzaWQ9cG9seV90b19zZWN0b3IuZ2V0KGdpKQogICAg
ICAgIGlmIHNpZCBpcyBOb25lOiBjb250aW51ZQogICAgICAgIHc9bmF2X3RvX3dvcmxkKHBbImMi
XSxzY2FsZSkKICAgICAgICBieD1tYXRoLmZsb29yKHdbMF0vYnVja2V0KTsgYnk9bWF0aC5mbG9v
cih3WzFdL2J1Y2tldCk7IGJ6PW1hdGguZmxvb3Iod1syXS9idWNrZXQpCiAgICAgICAgYnVja2V0
c1tmIntieH0se2J5fSx7Ynp9Il0uYXBwZW5kKChyb3VuZCh3WzBdLDEpLHJvdW5kKHdbMV0sMSks
cm91bmQod1syXSwxKSxzaWQpKQogICAgcmV0dXJuIGJ1Y2tldHMKCmRlZiBlbWl0X2x1YShjZWxs
LCBzb3VyY2Vfc2hhLCBzY2FsZSwgcGVha3MsIHNlY3RvcnMsIHBvcnRhbHMsIGJ1Y2tldHMsIG91
dF9wYXRoKToKICAgIGZvciBzIGluIHNlY3RvcnM6CiAgICAgICAgc1sibmVpZ2hib3JzIl09c29y
dGVkKHNbIm5laWdoYm9ycyJdKQogICAgZm9yIHAgaW4gcG9ydGFsczoKICAgICAgICBmb3Igc2lk
IGluIChwWyJhX3NlY3RvciJdLHBbImJfc2VjdG9yIl0pOgogICAgICAgICAgICBpZiBzaWQgYW5k
IHBbImlkIl0gbm90IGluIHNlY3RvcnNbc2lkLTFdWyJwb3J0YWxzIl06CiAgICAgICAgICAgICAg
ICBzZWN0b3JzW3NpZC0xXVsicG9ydGFscyJdLmFwcGVuZChwWyJpZCJdKQoKICAgIGRlZiBxKHMp
OgogICAgICAgIHJldHVybiAnIicgKyBzLnJlcGxhY2UoIlxcIiwiXFxcXCIpLnJlcGxhY2UoJyIn
LCdcXCInKSArICciJwogICAgbGluZXM9W10KICAgIGxpbmVzLmFwcGVuZCgiLS0gVFNQX1ZJU0dS
SURfVE9QT0xPR1lfVjEiKQogICAgbGluZXMuYXBwZW5kKCItLSBHZW5lcmF0ZWQgZnJvbSBPcGVu
TVcgbGl2ZSBEZXRvdXIgYWxsX3RpbGVzX25hdm1lc2guYmluLiIpCiAgICBsaW5lcy5hcHBlbmQo
Ii0tIFRPUE9MT0dZIEhJTlQgT05MWTogbmV2ZXIgYSBoYXJkIHJlbmRlci1kaXN0YW5jZSBjbGFt
cC4iKQogICAgbGluZXMuYXBwZW5kKCJsb2NhbCBUID0geyIpCiAgICBsaW5lcy5hcHBlbmQoIiAg
dmVyc2lvbiA9IDEsIikKICAgIGxpbmVzLmFwcGVuZChmIiAgc291cmNlX3NoYTI1NiA9IHtxKHNv
dXJjZV9zaGEpfSwiKQogICAgbGluZXMuYXBwZW5kKGYiICB3b3JsZF9wZXJfbmF2ID0ge3NjYWxl
Oi42Zn0sIikKICAgIGxpbmVzLmFwcGVuZCgiICBidWNrZXRfc2l6ZSA9IDM4NCwiKQogICAgbGlu
ZXMuYXBwZW5kKCIgIGNlbGxzID0geyIpCiAgICBsaW5lcy5hcHBlbmQoZiIgICAgW3txKGNlbGwp
fV0gPSB7eyIpCiAgICBsaW5lcy5hcHBlbmQoIiAgICAgIGZsb29ycyA9IHsiICsgIiwiLmpvaW4o
ZiJ7cCpzY2FsZTouMWZ9IiBmb3IgcCBpbiBwZWFrcykgKyAifSwiKQogICAgbGluZXMuYXBwZW5k
KCIgICAgICBzZWN0b3JzID0geyIpCiAgICBmb3IgcyBpbiBzZWN0b3JzOgogICAgICAgIGI9c1si
YmJveCJdOyBjPXNbImNlbnRlciJdCiAgICAgICAgbmVpZ2g9InsiICsgIiwiLmpvaW4obWFwKHN0
cixzWyJuZWlnaGJvcnMiXSkpICsgIn0iCiAgICAgICAgcG9ydHM9InsiICsgIiwiLmpvaW4obWFw
KHN0cixzWyJwb3J0YWxzIl0pKSArICJ9IgogICAgICAgIGxpbmVzLmFwcGVuZCgKICAgICAgICAg
ICAgZiIgICAgICAgIFt7c1snaWQnXX1dID0ge3sgaWQ9e3NbJ2lkJ119LCBmbG9vcj17c1snZmxv
b3InXX0sIGtpbmQ9e3Eoc1sna2luZCddKX0sICIKICAgICAgICAgICAgZiJhcmVhPXtzWydhcmVh
J119LCBwb2x5cz17c1sncG9seV9jb3VudCddfSwgIgogICAgICAgICAgICBmImJib3g9e3t7Jywn
LmpvaW4obWFwKHN0cixiKSl9fX0sIGNlbnRlcj17e3snLCcuam9pbihtYXAoc3RyLGMpKX19fSwg
IgogICAgICAgICAgICBmIm5laWdoYm9ycz17bmVpZ2h9LCBwb3J0YWxzPXtwb3J0c30gfX0sIgog
ICAgICAgICkKICAgIGxpbmVzLmFwcGVuZCgiICAgICAgfSwiKQogICAgbGluZXMuYXBwZW5kKCIg
ICAgICBwb3J0YWxzID0geyIpCiAgICBmb3IgcCBpbiBwb3J0YWxzOgogICAgICAgIGM9cFsiY2Vu
dGVyIl0KICAgICAgICBsaW5lcy5hcHBlbmQoCiAgICAgICAgICAgIGYiICAgICAgICBbe3BbJ2lk
J119XSA9IHt7IGlkPXtwWydpZCddfSwga2luZD17cShwWydraW5kJ10pfSwgIgogICAgICAgICAg
ICBmImE9e3BbJ2Ffc2VjdG9yJ119LCBiPXtwWydiX3NlY3RvciddfSwgY2VudGVyPXt7eycsJy5q
b2luKG1hcChzdHIsYykpfX19IH19LCIKICAgICAgICApCiAgICBsaW5lcy5hcHBlbmQoIiAgICAg
IH0sIikKICAgIGxpbmVzLmFwcGVuZCgiICAgICAgYnVja2V0cyA9IHsiKQogICAgZm9yIGtleSBp
biBzb3J0ZWQoYnVja2V0cyk6CiAgICAgICAgc2FtcGxlcz0iLCIuam9pbigKICAgICAgICAgICAg
InsiICsgIiwiLmpvaW4obWFwKHN0cixzKSkgKyAifSIgZm9yIHMgaW4gYnVja2V0c1trZXldCiAg
ICAgICAgKQogICAgICAgIGxpbmVzLmFwcGVuZChmIiAgICAgICAgW3txKGtleSl9XSA9IHt7e3Nh
bXBsZXN9fX0sIikKICAgIGxpbmVzLmFwcGVuZCgiICAgICAgfSwiKQogICAgbGluZXMuYXBwZW5k
KCIgICAgfSwiKQogICAgbGluZXMuYXBwZW5kKCIgIH0sIikKICAgIGxpbmVzLmFwcGVuZCgifSIp
CiAgICBsaW5lcy5leHRlbmQociIiIgpmdW5jdGlvbiBULmZpbmRTZWN0b3IoY2VsbE5hbWUsIHgs
IHksIHopCiAgICBsb2NhbCB0YyA9IFQuY2VsbHNbY2VsbE5hbWVdCiAgICBpZiB0YyA9PSBuaWwg
dGhlbiByZXR1cm4gbmlsLCBuaWwgZW5kCiAgICBsb2NhbCBicyA9IFQuYnVja2V0X3NpemUgb3Ig
Mzg0CiAgICBsb2NhbCBieCwgYnksIGJ6ID0gbWF0aC5mbG9vcih4IC8gYnMpLCBtYXRoLmZsb29y
KHkgLyBicyksIG1hdGguZmxvb3IoeiAvIGJzKQogICAgbG9jYWwgYmVzdFNpZCwgYmVzdEQyID0g
bmlsLCAxLjBlMzAKCiAgICBmb3IgZHpiID0gLTEsIDEgZG8KICAgICAgICBmb3IgZHliID0gLTEs
IDEgZG8KICAgICAgICAgICAgZm9yIGR4YiA9IC0xLCAxIGRvCiAgICAgICAgICAgICAgICBsb2Nh
bCBrZXkgPSB0b3N0cmluZyhieCArIGR4YikgLi4gJywnIC4uIHRvc3RyaW5nKGJ5ICsgZHliKQog
ICAgICAgICAgICAgICAgICAgIC4uICcsJyAuLiB0b3N0cmluZyhieiArIGR6YikKICAgICAgICAg
ICAgICAgIGxvY2FsIHNhbXBsZXMgPSB0Yy5idWNrZXRzW2tleV0KICAgICAgICAgICAgICAgIGlm
IHNhbXBsZXMgfj0gbmlsIHRoZW4KICAgICAgICAgICAgICAgICAgICBmb3IgaSA9IDEsICNzYW1w
bGVzIGRvCiAgICAgICAgICAgICAgICAgICAgICAgIGxvY2FsIHEgPSBzYW1wbGVzW2ldCiAgICAg
ICAgICAgICAgICAgICAgICAgIGxvY2FsIGR4LCBkeSwgZHogPSB4IC0gcVsxXSwgeSAtIHFbMl0s
IHogLSBxWzNdCiAgICAgICAgICAgICAgICAgICAgICAgIGxvY2FsIGQyID0gZHggKiBkeCArIGR5
ICogZHkgKyBkeiAqIGR6CiAgICAgICAgICAgICAgICAgICAgICAgIGlmIGQyIDwgYmVzdEQyIHRo
ZW4KICAgICAgICAgICAgICAgICAgICAgICAgICAgIGJlc3REMiA9IGQyCiAgICAgICAgICAgICAg
ICAgICAgICAgICAgICBiZXN0U2lkID0gcVs0XQogICAgICAgICAgICAgICAgICAgICAgICBlbmQK
ICAgICAgICAgICAgICAgICAgICBlbmQKICAgICAgICAgICAgICAgIGVuZAogICAgICAgICAgICBl
bmQKICAgICAgICBlbmQKICAgIGVuZAoKICAgIGlmIGJlc3RTaWQgPT0gbmlsIHRoZW4KICAgICAg
ICBmb3Igc2lkLCBzZWMgaW4gcGFpcnModGMuc2VjdG9ycykgZG8KICAgICAgICAgICAgbG9jYWwg
YiA9IHNlYy5iYm94CiAgICAgICAgICAgIGxvY2FsIHpQYWQgPSAoc2VjLmtpbmQgPT0gJ3ZlcnRp
Y2FsX2Nvbm5lY3RvcicpIGFuZCAyMjAuMCBvciAxMjAuMAogICAgICAgICAgICBpZiB4ID49IGJb
MV0gLSAyMjAgYW5kIHggPD0gYls0XSArIDIyMAogICAgICAgICAgICAgICAgYW5kIHkgPj0gYlsy
XSAtIDIyMCBhbmQgeSA8PSBiWzVdICsgMjIwCiAgICAgICAgICAgICAgICBhbmQgeiA+PSBiWzNd
IC0gelBhZCBhbmQgeiA8PSBiWzZdICsgelBhZCB0aGVuCiAgICAgICAgICAgICAgICBsb2NhbCBj
ID0gc2VjLmNlbnRlcgogICAgICAgICAgICAgICAgbG9jYWwgZHgsIGR5LCBkeiA9IHggLSBjWzFd
LCB5IC0gY1syXSwgeiAtIGNbM10KICAgICAgICAgICAgICAgIGxvY2FsIGQyID0gZHggKiBkeCAr
IGR5ICogZHkgKyBkeiAqIGR6CiAgICAgICAgICAgICAgICBpZiBkMiA8IGJlc3REMiB0aGVuCiAg
ICAgICAgICAgICAgICAgICAgYmVzdEQyID0gZDIKICAgICAgICAgICAgICAgICAgICBiZXN0U2lk
ID0gc2lkCiAgICAgICAgICAgICAgICBlbmQKICAgICAgICAgICAgZW5kCiAgICAgICAgZW5kCiAg
ICBlbmQKCiAgICByZXR1cm4gYmVzdFNpZCwgYmVzdFNpZCB+PSBuaWwgYW5kIHRjLnNlY3RvcnNb
YmVzdFNpZF0gb3IgbmlsCmVuZAoKZnVuY3Rpb24gVC5jYWNoZUtleShjZWxsTmFtZSwgc2VjdG9y
SWQpCiAgICBpZiBzZWN0b3JJZCB+PSBuaWwgYW5kIHNlY3RvcklkID4gMCB0aGVuCiAgICAgICAg
cmV0dXJuIHRvc3RyaW5nKGNlbGxOYW1lKSAuLiAnI3RvcG8nIC4uIHRvc3RyaW5nKHNlY3Rvcklk
KQogICAgZW5kCiAgICByZXR1cm4gY2VsbE5hbWUKZW5kCgpmdW5jdGlvbiBULmdldENlbGwoY2Vs
bE5hbWUpCiAgICByZXR1cm4gVC5jZWxsc1tjZWxsTmFtZV0KZW5kCgpyZXR1cm4gVAoiIiIuc3Ry
aXAoIlxuIikuc3BsaXRsaW5lcygpKQogICAgb3V0X3BhdGgud3JpdGVfdGV4dCgiXG4iLmpvaW4o
bGluZXMpKyJcbiIpCgpkZWYgbWFpbigpOgogICAgYXA9YXJncGFyc2UuQXJndW1lbnRQYXJzZXIo
KQogICAgYXAuYWRkX2FyZ3VtZW50KCJuYXZtZXNoIikKICAgIGFwLmFkZF9hcmd1bWVudCgiLS1j
ZWxsIiwgZGVmYXVsdD0iQ2FsZGVyYSwgR292ZXJub3IncyBIYWxsIikKICAgIGFwLmFkZF9hcmd1
bWVudCgiLS1vdXRwdXQiLCByZXF1aXJlZD1UcnVlKQogICAgYXJncz1hcC5wYXJzZV9hcmdzKCkK
CiAgICBwYXRoPVBhdGgoYXJncy5uYXZtZXNoKQogICAgaW1wb3J0IGhhc2hsaWIKICAgIHNoYT1o
YXNobGliLnNoYTI1NihwYXRoLnJlYWRfYnl0ZXMoKSkuaGV4ZGlnZXN0KCkKICAgIHBhcmFtcyx0
aWxlcz1yZWFkX21zZXQocGF0aCkKICAgIHNjYWxlPWRldGVjdF9zY2FsZSh0aWxlcykKICAgIGdy
b3VuZD1idWlsZF9ncm91bmQodGlsZXMpCiAgICBhZGo9YnVpbGRfYWRqYWNlbmN5KGdyb3VuZCkK
ICAgIHBlYWtzLGhpc3Q9ZmluZF9mbG9vcl9wZWFrcyhncm91bmQpCiAgICBzZWN0b3JzLHAycz1t
YWtlX3NlY3RvcnMoZ3JvdW5kLGFkaixwZWFrcyxzY2FsZSkKICAgIHBvcnRhbHM9bWFrZV9wb3J0
YWxzKHRpbGVzLGdyb3VuZCxwMnMsc2NhbGUpCiAgICBwb3J0YWxzLmV4dGVuZChtYWtlX2JvdW5k
YXJ5X3BvcnRhbHMoCiAgICAgICAgZ3JvdW5kLCBhZGosIHAycywgc2NhbGUsCiAgICAgICAgMSAr
IG1heChbcFsiaWQiXSBmb3IgcCBpbiBwb3J0YWxzXSwgZGVmYXVsdD0wKSkpCiAgICBidWNrZXRz
PWJ1aWxkX2J1Y2tldHMoZ3JvdW5kLHAycyxzY2FsZSkKCiAgICAjIEF0dGFjaCBhZGphY2VuY3kg
dmlhIHBvcnRhbHMuCiAgICBmb3IgcCBpbiBwb3J0YWxzOgogICAgICAgIGEsYj1wWyJhX3NlY3Rv
ciJdLHBbImJfc2VjdG9yIl0KICAgICAgICBpZiBhIGFuZCBiIGFuZCBhIT1iOgogICAgICAgICAg
ICBzZWN0b3JzW2EtMV1bIm5laWdoYm9ycyJdLmFkZChiKQogICAgICAgICAgICBzZWN0b3JzW2It
MV1bIm5laWdoYm9ycyJdLmFkZChhKQoKICAgIG91dD1QYXRoKGFyZ3Mub3V0cHV0KQogICAgZW1p
dF9sdWEoYXJncy5jZWxsLHNoYSxzY2FsZSxwZWFrcyxzZWN0b3JzLHBvcnRhbHMsYnVja2V0cyxv
dXQpCgogICAgZG9vcj1zdW0oMSBmb3IgcCBpbiBwb3J0YWxzIGlmIHBbImtpbmQiXT09ImRvb3Ii
KQogICAgcGF0aGdyaWQ9MAogICAgcHJpbnQoZiJQQVNTOiB7bGVuKHRpbGVzKX0gdGlsZXM7IHts
ZW4oZ3JvdW5kKX0gZ3JvdW5kIHBvbHlnb25zIikKICAgIHByaW50KGYiZmxvb3JzL3BsYXRlYXVz
OiB7bGVuKHBlYWtzKX0gLT4gIiArICIsICIuam9pbihmIntwKnNjYWxlOi4xZn0iIGZvciBwIGlu
IHBlYWtzKSkKICAgIHByaW50KGYic2VjdG9yczoge2xlbihzZWN0b3JzKX0iKQogICAgZm9yIHMg
aW4gc2VjdG9yczoKICAgICAgICBwcmludChmIiAgU3tzWydpZCddOjAyZH0gZmxvb3I9e3NbJ2Zs
b29yJ119IGtpbmQ9e3NbJ2tpbmQnXTo8MTh9ICIKICAgICAgICAgICAgICBmInBvbHlzPXtzWydw
b2x5X2NvdW50J106M2R9IGFyZWE9e3NbJ2FyZWEnXTo3ZH0gIgogICAgICAgICAgICAgIGYibmVp
Z2hib3JzPXtzb3J0ZWQoc1snbmVpZ2hib3JzJ10pfSIpCiAgICBwcmludChmInBvcnRhbHM6IHts
ZW4ocG9ydGFscyl9ICh7ZG9vcn0gZG9vciwge3BhdGhncmlkfSBwYXRoZ3JpZCkiKQogICAgcHJp
bnQoZiJvdXRwdXQ6IHtvdXR9IikKCmlmIF9fbmFtZV9fID09ICJfX21haW5fXyI6CiAgICBtYWlu
KCkK
EOF_BASE

base64 -d \
    "$OUT/compile_openmw_navmesh_topology.py.b64" \
    > "$OUT/compile_openmw_navmesh_topology.py"

chmod +x \
    "$OUT/compile_openmw_navmesh_topology.py"

cat > "$OUT/compile_openmw_global_interior_topology.py.b64" <<'EOF_GLOBAL'
IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwpmcm9tIF9fZnV0dXJlX18gaW1wb3J0IGFubm90YXRpb25z
CgppbXBvcnQgYXJncGFyc2UKaW1wb3J0IGNvbGxlY3Rpb25zCmltcG9ydCBoYXNobGliCmltcG9y
dCBpbXBvcnRsaWIudXRpbAppbXBvcnQgbWF0aAppbXBvcnQgcmUKaW1wb3J0IHNodXRpbAppbXBv
cnQgc3RydWN0CmltcG9ydCB0ZW1wZmlsZQpmcm9tIHBhdGhsaWIgaW1wb3J0IFBhdGgKCgpQQUNL
X01BR0lDID0gYiJUU1BNU0VUMSIKCgpkZWYgbHVhX3VuZXNjYXBlKHM6IHN0cikgLT4gc3RyOgog
ICAgb3V0ID0gW10KICAgIGkgPSAwCiAgICB3aGlsZSBpIDwgbGVuKHMpOgogICAgICAgIGMgPSBz
W2ldCiAgICAgICAgaWYgYyA9PSAiXFwiIGFuZCBpICsgMSA8IGxlbihzKToKICAgICAgICAgICAg
biA9IHNbaSArIDFdCiAgICAgICAgICAgIHRhYmxlID0gewogICAgICAgICAgICAgICAgIlxcIjog
IlxcIiwKICAgICAgICAgICAgICAgICciJzogJyInLAogICAgICAgICAgICAgICAgIiciOiAiJyIs
CiAgICAgICAgICAgICAgICAibiI6ICJcbiIsCiAgICAgICAgICAgICAgICAiciI6ICJcciIsCiAg
ICAgICAgICAgICAgICAidCI6ICJcdCIsCiAgICAgICAgICAgIH0KICAgICAgICAgICAgb3V0LmFw
cGVuZCh0YWJsZS5nZXQobiwgbikpCiAgICAgICAgICAgIGkgKz0gMgogICAgICAgIGVsc2U6CiAg
ICAgICAgICAgIG91dC5hcHBlbmQoYykKICAgICAgICAgICAgaSArPSAxCiAgICByZXR1cm4gIiIu
am9pbihvdXQpCgoKZGVmIGxxKHM6IHN0cikgLT4gc3RyOgogICAgcmV0dXJuICciJyArIHMucmVw
bGFjZSgiXFwiLCAiXFxcXCIpLnJlcGxhY2UoJyInLCAnXFwiJykgKyAnIicKCgpkZWYgbG9hZF9h
bGxvd2xpc3QocGF0aDogUGF0aCkgLT4gc2V0W3N0cl06CiAgICAjIGludGVyaW9ybWFwLmx1YSBp
cyBnZW5lcmF0ZWQgZGF0YS4gRXh0cmFjdCBhbGwgcXVvdGVkIHRhYmxlIGtleXMuCiAgICAjIER1
cGxpY2F0ZSBrZXlzIGFwcGVhcmluZyBpbiBhdXhpbGlhcnkgei9ib3VuZHMgdGFibGVzIGNvbGxh
cHNlIG5hdHVyYWxseS4KICAgIHJ4ID0gcmUuY29tcGlsZShyJ1xbXHMqIigoPzpcXC58W14iXSkq
KSJccypcXVxzKj0nKQogICAgbmFtZXMgPSBzZXQoKQogICAgZm9yIGxpbmUgaW4gcGF0aC5yZWFk
X3RleHQoZW5jb2Rpbmc9InV0Zi04IiwgZXJyb3JzPSJyZXBsYWNlIikuc3BsaXRsaW5lcygpOgog
ICAgICAgIG0gPSByeC5zZWFyY2gobGluZSkKICAgICAgICBpZiBtOgogICAgICAgICAgICBuYW1l
cy5hZGQobHVhX3VuZXNjYXBlKG0uZ3JvdXAoMSkpKQogICAgaWYgbm90IG5hbWVzOgogICAgICAg
IHJhaXNlIFN5c3RlbUV4aXQoZiJFUlJPUjogbm8gaW50ZXJpb3IgY2VsbCBuYW1lcyBmb3VuZCBp
biB7cGF0aH0iKQogICAgcmV0dXJuIG5hbWVzCgoKZGVmIGl0ZXJfcGFjayhwYXRoOiBQYXRoKToK
ICAgIHdpdGggcGF0aC5vcGVuKCJyYiIpIGFzIGY6CiAgICAgICAgbWFnaWMgPSBmLnJlYWQobGVu
KFBBQ0tfTUFHSUMpKQogICAgICAgIGlmIG1hZ2ljICE9IFBBQ0tfTUFHSUM6CiAgICAgICAgICAg
IHJhaXNlIFN5c3RlbUV4aXQoZiJFUlJPUjogYmFkIHRvcG9sb2d5IHBhY2sgbWFnaWM6IHttYWdp
YyFyfSIpCgogICAgICAgIGluZGV4ID0gMAogICAgICAgIHdoaWxlIFRydWU6CiAgICAgICAgICAg
IGhkciA9IGYucmVhZCgxMikKICAgICAgICAgICAgaWYgbm90IGhkcjoKICAgICAgICAgICAgICAg
IGJyZWFrCiAgICAgICAgICAgIGlmIGxlbihoZHIpICE9IDEyOgogICAgICAgICAgICAgICAgcmFp
c2UgU3lzdGVtRXhpdCgiRVJST1I6IHRydW5jYXRlZCBwYWNrIHJlY29yZCBoZWFkZXIiKQoKICAg
ICAgICAgICAgbmFtZV9sZW4sIGRhdGFfbGVuID0gc3RydWN0LnVucGFjaygiPElRIiwgaGRyKQog
ICAgICAgICAgICBuYW1lX2IgPSBmLnJlYWQobmFtZV9sZW4pCiAgICAgICAgICAgIGlmIGxlbihu
YW1lX2IpICE9IG5hbWVfbGVuOgogICAgICAgICAgICAgICAgcmFpc2UgU3lzdGVtRXhpdCgiRVJS
T1I6IHRydW5jYXRlZCB3b3JsZHNwYWNlIG5hbWUiKQoKICAgICAgICAgICAgZGF0YSA9IGYucmVh
ZChkYXRhX2xlbikKICAgICAgICAgICAgaWYgbGVuKGRhdGEpICE9IGRhdGFfbGVuOgogICAgICAg
ICAgICAgICAgcmFpc2UgU3lzdGVtRXhpdCgiRVJST1I6IHRydW5jYXRlZCBNU0VUIHBheWxvYWQi
KQoKICAgICAgICAgICAgaW5kZXggKz0gMQogICAgICAgICAgICB5aWVsZCBpbmRleCwgbmFtZV9i
LmRlY29kZSgidXRmLTgiLCBlcnJvcnM9InN0cmljdCIpLCBkYXRhCgoKZGVmIGZpbmFsaXplX3Nl
Y3Rvcl9saW5rcyhzZWN0b3JzLCBwb3J0YWxzKToKICAgIGZvciBwIGluIHBvcnRhbHM6CiAgICAg
ICAgYSwgYiA9IHBbImFfc2VjdG9yIl0sIHBbImJfc2VjdG9yIl0KICAgICAgICBpZiBhIGFuZCBi
IGFuZCBhICE9IGI6CiAgICAgICAgICAgIHNlY3RvcnNbYSAtIDFdWyJuZWlnaGJvcnMiXS5hZGQo
YikKICAgICAgICAgICAgc2VjdG9yc1tiIC0gMV1bIm5laWdoYm9ycyJdLmFkZChhKQoKCmRlZiBj
b2Fyc2VuX3NlY3RvcnMoc2VjdG9ycywgcG9seV90b19zZWN0b3IsIG1heF9zZWN0b3JzPTY0KToK
ICAgICIiIk1lcmdlIHNtYWxsZXN0IGFkamFjZW50IHNlY3RvcnMgdW50aWwgdGhlIEMrKyBQVlMg
NjQtc2VjdG9yIGxpbWl0IGZpdHMuCgogICAgVGhpcyBpcyBkZWxpYmVyYXRlbHkgY29uc2VydmF0
aXZlLiBTYW1lLWZsb29yIG5laWdoYm9ycyBhcmUgcHJlZmVycmVkOwogICAgY29ubmVjdG9ycy9t
aXhlZC1mbG9vciBtZXJnZXMgYmVjb21lIHZlcnRpY2FsX2Nvbm5lY3RvciBzZWN0b3JzLgogICAg
IiIiCiAgICBpZiBsZW4oc2VjdG9ycykgPD0gbWF4X3NlY3RvcnM6CiAgICAgICAgcmV0dXJuIHNl
Y3RvcnMsIHBvbHlfdG9fc2VjdG9yLCAwCgogICAgZ3JvdXBzID0ge30KICAgIGZvciBzIGluIHNl
Y3RvcnM6CiAgICAgICAgc2lkID0gc1siaWQiXQogICAgICAgIGdyb3Vwc1tzaWRdID0gewogICAg
ICAgICAgICAib2xkIjoge3NpZH0sCiAgICAgICAgICAgICJmbG9vciI6IHNbImZsb29yIl0sCiAg
ICAgICAgICAgICJraW5kIjogc1sia2luZCJdLAogICAgICAgICAgICAicG9seV9jb3VudCI6IHNb
InBvbHlfY291bnQiXSwKICAgICAgICAgICAgImFyZWEiOiBmbG9hdChzWyJhcmVhIl0pLAogICAg
ICAgICAgICAiYmJveCI6IGxpc3Qoc1siYmJveCJdKSwKICAgICAgICAgICAgImNlbnRlcl9zdW0i
OiBbCiAgICAgICAgICAgICAgICBmbG9hdChzWyJjZW50ZXIiXVswXSkgKiBzWyJwb2x5X2NvdW50
Il0sCiAgICAgICAgICAgICAgICBmbG9hdChzWyJjZW50ZXIiXVsxXSkgKiBzWyJwb2x5X2NvdW50
Il0sCiAgICAgICAgICAgICAgICBmbG9hdChzWyJjZW50ZXIiXVsyXSkgKiBzWyJwb2x5X2NvdW50
Il0sCiAgICAgICAgICAgIF0sCiAgICAgICAgICAgICJuZWlnaGJvcnMiOiBzZXQoc1sibmVpZ2hi
b3JzIl0pLAogICAgICAgICAgICAiX3BvbHlzIjogbGlzdChzLmdldCgiX3BvbHlzIiwgW10pKSwK
ICAgICAgICB9CgogICAgbWVyZ2VzID0gMAoKICAgIGRlZiBjZW50ZXIoZyk6CiAgICAgICAgbiA9
IG1heCgxLCBnWyJwb2x5X2NvdW50Il0pCiAgICAgICAgcmV0dXJuIHR1cGxlKHYgLyBuIGZvciB2
IGluIGdbImNlbnRlcl9zdW0iXSkKCiAgICB3aGlsZSBsZW4oZ3JvdXBzKSA+IG1heF9zZWN0b3Jz
OgogICAgICAgIHNpZCA9IG1pbihncm91cHMsIGtleT1sYW1iZGEgazogKGdyb3Vwc1trXVsiYXJl
YSJdLCBncm91cHNba11bInBvbHlfY291bnQiXSkpCiAgICAgICAgZyA9IGdyb3Vwc1tzaWRdCgog
ICAgICAgIGNhbmRpZGF0ZXMgPSBbbiBmb3IgbiBpbiBnWyJuZWlnaGJvcnMiXSBpZiBuIGluIGdy
b3VwcyBhbmQgbiAhPSBzaWRdCgogICAgICAgIGlmIG5vdCBjYW5kaWRhdGVzOgogICAgICAgICAg
ICBnYyA9IGNlbnRlcihnKQogICAgICAgICAgICBjYW5kaWRhdGVzID0gW2sgZm9yIGsgaW4gZ3Jv
dXBzIGlmIGsgIT0gc2lkXQogICAgICAgICAgICBpZiBub3QgY2FuZGlkYXRlczoKICAgICAgICAg
ICAgICAgIGJyZWFrCiAgICAgICAgICAgIHRhcmdldCA9IG1pbigKICAgICAgICAgICAgICAgIGNh
bmRpZGF0ZXMsCiAgICAgICAgICAgICAgICBrZXk9bGFtYmRhIGs6IHN1bSgKICAgICAgICAgICAg
ICAgICAgICAoY2VudGVyKGdyb3Vwc1trXSlbaV0gLSBnY1tpXSkgKiogMiBmb3IgaSBpbiByYW5n
ZSgzKQogICAgICAgICAgICAgICAgKSwKICAgICAgICAgICAgKQogICAgICAgIGVsc2U6CiAgICAg
ICAgICAgIGdjID0gY2VudGVyKGcpCgogICAgICAgICAgICBkZWYgbWVyZ2VfY29zdChrKToKICAg
ICAgICAgICAgICAgIGggPSBncm91cHNba10KICAgICAgICAgICAgICAgIGhjID0gY2VudGVyKGgp
CiAgICAgICAgICAgICAgICBzYW1lX2Zsb29yID0gKAogICAgICAgICAgICAgICAgICAgIGdbImZs
b29yIl0gPiAwCiAgICAgICAgICAgICAgICAgICAgYW5kIGhbImZsb29yIl0gPiAwCiAgICAgICAg
ICAgICAgICAgICAgYW5kIGdbImZsb29yIl0gPT0gaFsiZmxvb3IiXQogICAgICAgICAgICAgICAg
KQogICAgICAgICAgICAgICAgY29ubmVjdG9yID0gKAogICAgICAgICAgICAgICAgICAgIGdbImtp
bmQiXSA9PSAidmVydGljYWxfY29ubmVjdG9yIgogICAgICAgICAgICAgICAgICAgIG9yIGhbImtp
bmQiXSA9PSAidmVydGljYWxfY29ubmVjdG9yIgogICAgICAgICAgICAgICAgKQogICAgICAgICAg
ICAgICAgZDIgPSBzdW0oKGhjW2ldIC0gZ2NbaV0pICoqIDIgZm9yIGkgaW4gcmFuZ2UoMykpCiAg
ICAgICAgICAgICAgICAjIHN0cm9uZ2x5IHByZWZlciBzYW1lLWZsb29yIG1lcmdlcywgdGhlbiBj
b25uZWN0b3IgbWVyZ2VzCiAgICAgICAgICAgICAgICByZXR1cm4gKDAgaWYgc2FtZV9mbG9vciBl
bHNlICgxIGlmIGNvbm5lY3RvciBlbHNlIDIpLCBkMikKCiAgICAgICAgICAgIHRhcmdldCA9IG1p
bihjYW5kaWRhdGVzLCBrZXk9bWVyZ2VfY29zdCkKCiAgICAgICAgaCA9IGdyb3Vwc1t0YXJnZXRd
CgogICAgICAgIGhbIm9sZCJdLnVwZGF0ZShnWyJvbGQiXSkKICAgICAgICBoWyJwb2x5X2NvdW50
Il0gKz0gZ1sicG9seV9jb3VudCJdCiAgICAgICAgaFsiYXJlYSJdICs9IGdbImFyZWEiXQogICAg
ICAgIGZvciBpIGluIHJhbmdlKDMpOgogICAgICAgICAgICBoWyJjZW50ZXJfc3VtIl1baV0gKz0g
Z1siY2VudGVyX3N1bSJdW2ldCgogICAgICAgIGhbImJib3giXVswXSA9IG1pbihoWyJiYm94Il1b
MF0sIGdbImJib3giXVswXSkKICAgICAgICBoWyJiYm94Il1bMV0gPSBtaW4oaFsiYmJveCJdWzFd
LCBnWyJiYm94Il1bMV0pCiAgICAgICAgaFsiYmJveCJdWzJdID0gbWluKGhbImJib3giXVsyXSwg
Z1siYmJveCJdWzJdKQogICAgICAgIGhbImJib3giXVszXSA9IG1heChoWyJiYm94Il1bM10sIGdb
ImJib3giXVszXSkKICAgICAgICBoWyJiYm94Il1bNF0gPSBtYXgoaFsiYmJveCJdWzRdLCBnWyJi
Ym94Il1bNF0pCiAgICAgICAgaFsiYmJveCJdWzVdID0gbWF4KGhbImJib3giXVs1XSwgZ1siYmJv
eCJdWzVdKQoKICAgICAgICBoWyJfcG9seXMiXS5leHRlbmQoZ1siX3BvbHlzIl0pCgogICAgICAg
IGlmIGhbImZsb29yIl0gIT0gZ1siZmxvb3IiXToKICAgICAgICAgICAgaFsiZmxvb3IiXSA9IDAK
ICAgICAgICAgICAgaFsia2luZCJdID0gInZlcnRpY2FsX2Nvbm5lY3RvciIKICAgICAgICBlbGlm
IGhbImtpbmQiXSA9PSAidmVydGljYWxfY29ubmVjdG9yIiBvciBnWyJraW5kIl0gPT0gInZlcnRp
Y2FsX2Nvbm5lY3RvciI6CiAgICAgICAgICAgIGhbImtpbmQiXSA9ICJ2ZXJ0aWNhbF9jb25uZWN0
b3IiCiAgICAgICAgZWxzZToKICAgICAgICAgICAgYnggPSBoWyJiYm94Il1bM10gLSBoWyJiYm94
Il1bMF0KICAgICAgICAgICAgYnkgPSBoWyJiYm94Il1bNF0gLSBoWyJiYm94Il1bMV0KICAgICAg
ICAgICAgYXNwZWN0ID0gbWF4KGJ4LCBieSkgLyBtYXgoMS4wLCBtaW4oYngsIGJ5KSkKICAgICAg
ICAgICAgYmJveF9hcmVhID0gbWF4KDEuMCwgYnggKiBieSkKICAgICAgICAgICAgZmlsbCA9IGhb
ImFyZWEiXSAvIGJib3hfYXJlYQogICAgICAgICAgICBpZiBoWyJhcmVhIl0gPj0gMTgwMDAwOgog
ICAgICAgICAgICAgICAgaFsia2luZCJdID0gImxhcmdlX29wZW4iCiAgICAgICAgICAgIGVsaWYg
YXNwZWN0ID49IDMuMiBhbmQgZmlsbCA8IDAuNDU6CiAgICAgICAgICAgICAgICBoWyJraW5kIl0g
PSAiY29ycmlkb3IiCiAgICAgICAgICAgIGVsaWYgaFsiYXJlYSJdIDwgNDUwMDA6CiAgICAgICAg
ICAgICAgICBoWyJraW5kIl0gPSAic21hbGxfcm9vbSIKICAgICAgICAgICAgZWxzZToKICAgICAg
ICAgICAgICAgIGhbImtpbmQiXSA9ICJyb29tIgoKICAgICAgICBuZXdfbmVpZ2hib3JzID0gKGhb
Im5laWdoYm9ycyJdIHwgZ1sibmVpZ2hib3JzIl0pIC0ge3NpZCwgdGFyZ2V0fQogICAgICAgIGhb
Im5laWdoYm9ycyJdID0gbmV3X25laWdoYm9ycwoKICAgICAgICBmb3Igb3RoZXJfaWQsIG90aGVy
IGluIGdyb3Vwcy5pdGVtcygpOgogICAgICAgICAgICBpZiBvdGhlcl9pZCBpbiAoc2lkLCB0YXJn
ZXQpOgogICAgICAgICAgICAgICAgY29udGludWUKICAgICAgICAgICAgaWYgc2lkIGluIG90aGVy
WyJuZWlnaGJvcnMiXToKICAgICAgICAgICAgICAgIG90aGVyWyJuZWlnaGJvcnMiXS5kaXNjYXJk
KHNpZCkKICAgICAgICAgICAgICAgIG90aGVyWyJuZWlnaGJvcnMiXS5hZGQodGFyZ2V0KQoKICAg
ICAgICBkZWwgZ3JvdXBzW3NpZF0KICAgICAgICBtZXJnZXMgKz0gMQoKICAgIG9yZGVyZWQgPSBz
b3J0ZWQoZ3JvdXBzLnZhbHVlcygpLCBrZXk9bGFtYmRhIGc6IG1pbihnWyJvbGQiXSkpCiAgICBv
bGRfdG9fbmV3ID0ge30KICAgIG5ld19zZWN0b3JzID0gW10KCiAgICBmb3IgbmV3X2lkLCBnIGlu
IGVudW1lcmF0ZShvcmRlcmVkLCBzdGFydD0xKToKICAgICAgICBmb3Igb2xkX2lkIGluIGdbIm9s
ZCJdOgogICAgICAgICAgICBvbGRfdG9fbmV3W29sZF9pZF0gPSBuZXdfaWQKCiAgICAgICAgYyA9
IGNlbnRlcihnKQogICAgICAgIG5ld19zZWN0b3JzLmFwcGVuZCh7CiAgICAgICAgICAgICJpZCI6
IG5ld19pZCwKICAgICAgICAgICAgImZsb29yIjogZ1siZmxvb3IiXSwKICAgICAgICAgICAgImtp
bmQiOiBnWyJraW5kIl0sCiAgICAgICAgICAgICJwb2x5X2NvdW50IjogZ1sicG9seV9jb3VudCJd
LAogICAgICAgICAgICAiYXJlYSI6IHJvdW5kKGdbImFyZWEiXSksCiAgICAgICAgICAgICJiYm94
IjogW3JvdW5kKHYsIDEpIGZvciB2IGluIGdbImJib3giXV0sCiAgICAgICAgICAgICJjZW50ZXIi
OiBbcm91bmQodiwgMSkgZm9yIHYgaW4gY10sCiAgICAgICAgICAgICJuZWlnaGJvcnMiOiBzZXQo
KSwKICAgICAgICAgICAgInBvcnRhbHMiOiBbXSwKICAgICAgICAgICAgIl9wb2x5cyI6IGxpc3Qo
Z1siX3BvbHlzIl0pLAogICAgICAgIH0pCgogICAgZm9yIG5ld19pZCwgZyBpbiBlbnVtZXJhdGUo
b3JkZXJlZCwgc3RhcnQ9MSk6CiAgICAgICAgZm9yIG9sZF9uZWlnaGJvciBpbiBnWyJuZWlnaGJv
cnMiXToKICAgICAgICAgICAgb3RoZXIgPSBvbGRfdG9fbmV3LmdldChvbGRfbmVpZ2hib3IpCiAg
ICAgICAgICAgIGlmIG90aGVyIGlzIG5vdCBOb25lIGFuZCBvdGhlciAhPSBuZXdfaWQ6CiAgICAg
ICAgICAgICAgICBuZXdfc2VjdG9yc1tuZXdfaWQgLSAxXVsibmVpZ2hib3JzIl0uYWRkKG90aGVy
KQoKICAgIG5ld19wMnMgPSB7fQogICAgZm9yIHBvbHksIG9sZF9zaWQgaW4gcG9seV90b19zZWN0
b3IuaXRlbXMoKToKICAgICAgICBuZXdfc2lkID0gb2xkX3RvX25ldy5nZXQob2xkX3NpZCkKICAg
ICAgICBpZiBuZXdfc2lkIGlzIG5vdCBOb25lOgogICAgICAgICAgICBuZXdfcDJzW3BvbHldID0g
bmV3X3NpZAoKICAgIHJldHVybiBuZXdfc2VjdG9ycywgbmV3X3AycywgbWVyZ2VzCgoKZGVmIGVt
aXRfY2VsbF9zaGFyZChjZWxsLCBzb3VyY2Vfc2hhLCBzY2FsZSwgcGVha3MsIHNlY3RvcnMsIHBv
cnRhbHMsIGJ1Y2tldHMsIG91dF9wYXRoKToKICAgIGZvciBzIGluIHNlY3RvcnM6CiAgICAgICAg
c1sibmVpZ2hib3JzIl0gPSBzb3J0ZWQoc1sibmVpZ2hib3JzIl0pCgogICAgZm9yIHAgaW4gcG9y
dGFsczoKICAgICAgICBmb3Igc2lkIGluIChwWyJhX3NlY3RvciJdLCBwWyJiX3NlY3RvciJdKToK
ICAgICAgICAgICAgaWYgc2lkIGFuZCBwWyJpZCJdIG5vdCBpbiBzZWN0b3JzW3NpZCAtIDFdWyJw
b3J0YWxzIl06CiAgICAgICAgICAgICAgICBzZWN0b3JzW3NpZCAtIDFdWyJwb3J0YWxzIl0uYXBw
ZW5kKHBbImlkIl0pCgogICAgbGluZXMgPSBbXQogICAgbGluZXMuYXBwZW5kKCItLSBUU1BfVklT
R1JJRF9HTE9CQUxfVE9QT0xPR1lfQ0VMTF9WMSIpCiAgICBsaW5lcy5hcHBlbmQoIi0tIEdlbmVy
YXRlZCBmcm9tIGNvbXBsZXRlZCBPcGVuTVcgbmF2bWVzaC5kYjsgc3RhdGljIHRvcG9sb2d5IGhp
bnQgb25seS4iKQogICAgbGluZXMuYXBwZW5kKCJyZXR1cm4geyIpCiAgICBsaW5lcy5hcHBlbmQo
ZiIgIG5hbWUgPSB7bHEoY2VsbCl9LCIpCiAgICBsaW5lcy5hcHBlbmQoZiIgIHNvdXJjZV9zaGEy
NTYgPSB7bHEoc291cmNlX3NoYSl9LCIpCiAgICBsaW5lcy5hcHBlbmQoZiIgIHdvcmxkX3Blcl9u
YXYgPSB7c2NhbGU6LjZmfSwiKQogICAgbGluZXMuYXBwZW5kKCIgIGZsb29ycyA9IHsiICsgIiwi
LmpvaW4oZiJ7cCAqIHNjYWxlOi4xZn0iIGZvciBwIGluIHBlYWtzKSArICJ9LCIpCiAgICBsaW5l
cy5hcHBlbmQoIiAgc2VjdG9ycyA9IHsiKQoKICAgIGZvciBzIGluIHNlY3RvcnM6CiAgICAgICAg
YiA9IHNbImJib3giXQogICAgICAgIGMgPSBzWyJjZW50ZXIiXQogICAgICAgIG5laWdoID0gInsi
ICsgIiwiLmpvaW4obWFwKHN0ciwgc1sibmVpZ2hib3JzIl0pKSArICJ9IgogICAgICAgIHBvcnRz
ID0gInsiICsgIiwiLmpvaW4obWFwKHN0ciwgc1sicG9ydGFscyJdKSkgKyAifSIKICAgICAgICBs
aW5lcy5hcHBlbmQoCiAgICAgICAgICAgIGYiICAgIFt7c1snaWQnXX1dID0ge3sgaWQ9e3NbJ2lk
J119LCBmbG9vcj17c1snZmxvb3InXX0sIGtpbmQ9e2xxKHNbJ2tpbmQnXSl9LCAiCiAgICAgICAg
ICAgIGYiYXJlYT17c1snYXJlYSddfSwgcG9seXM9e3NbJ3BvbHlfY291bnQnXX0sICIKICAgICAg
ICAgICAgZiJiYm94PXt7eycsJy5qb2luKG1hcChzdHIsYikpfX19LCBjZW50ZXI9e3t7JywnLmpv
aW4obWFwKHN0cixjKSl9fX0sICIKICAgICAgICAgICAgZiJuZWlnaGJvcnM9e25laWdofSwgcG9y
dGFscz17cG9ydHN9IH19LCIKICAgICAgICApCgogICAgbGluZXMuYXBwZW5kKCIgIH0sIikKICAg
IGxpbmVzLmFwcGVuZCgiICBwb3J0YWxzID0geyIpCgogICAgZm9yIHAgaW4gcG9ydGFsczoKICAg
ICAgICBjID0gcFsiY2VudGVyIl0KICAgICAgICBsaW5lcy5hcHBlbmQoCiAgICAgICAgICAgIGYi
ICAgIFt7cFsnaWQnXX1dID0ge3sgaWQ9e3BbJ2lkJ119LCBraW5kPXtscShwWydraW5kJ10pfSwg
IgogICAgICAgICAgICBmImE9e3BbJ2Ffc2VjdG9yJ119LCBiPXtwWydiX3NlY3RvciddfSwgY2Vu
dGVyPXt7eycsJy5qb2luKG1hcChzdHIsYykpfX19IH19LCIKICAgICAgICApCgogICAgbGluZXMu
YXBwZW5kKCIgIH0sIikKICAgIGxpbmVzLmFwcGVuZCgiICBidWNrZXRzID0geyIpCgogICAgZm9y
IGtleSBpbiBzb3J0ZWQoYnVja2V0cyk6CiAgICAgICAgc2FtcGxlcyA9ICIsIi5qb2luKAogICAg
ICAgICAgICAieyIgKyAiLCIuam9pbihtYXAoc3RyLCBzYW1wbGUpKSArICJ9IiBmb3Igc2FtcGxl
IGluIGJ1Y2tldHNba2V5XQogICAgICAgICkKICAgICAgICBsaW5lcy5hcHBlbmQoZiIgICAgW3ts
cShrZXkpfV0gPSB7e3tzYW1wbGVzfX19LCIpCgogICAgbGluZXMuYXBwZW5kKCIgIH0sIikKICAg
IGxpbmVzLmFwcGVuZCgifSIpCiAgICBvdXRfcGF0aC53cml0ZV90ZXh0KCJcbiIuam9pbihsaW5l
cykgKyAiXG4iLCBlbmNvZGluZz0idXRmLTgiKQoKCmRlZiBlbWl0X2xvYWRlcihpbmRleCwgcGFj
a19zaGEsIHN1bW1hcnksIG91dF9wYXRoKToKICAgIGxpbmVzID0gWwogICAgICAgICItLSBUU1Bf
VklTR1JJRF9HTE9CQUxfVE9QT0xPR1lfVjEiLAogICAgICAgICItLSBMYXp5IGdsb2JhbCBpbnRl
cmlvciB0b3BvbG9neSBnZW5lcmF0ZWQgZnJvbSB0aGUgY29tcGxldGVkIG5hdm1lc2ggREIuIiwK
ICAgICAgICAiLS0gT25seSBhIHZpc2l0ZWQgY2VsbCBzaGFyZCBpcyByZXF1aXJlZDsgdW5tYXBw
ZWQgY2VsbHMgcmVtYWluIGNvbnNlcnZhdGl2ZS4iLAogICAgICAgICJsb2NhbCBUID0geyIsCiAg
ICAgICAgIiAgdmVyc2lvbiA9IDIsIiwKICAgICAgICBmIiAgc291cmNlX3NoYTI1NiA9IHtscShw
YWNrX3NoYSl9LCIsCiAgICAgICAgIiAgYnVja2V0X3NpemUgPSAzODQsIiwKICAgICAgICAiICBj
ZWxscyA9IHt9LCIsCiAgICAgICAgIn0iLAogICAgICAgICIiLAogICAgICAgICJsb2NhbCBpbmRl
eCA9IHsiLAogICAgXQoKICAgIGZvciBjZWxsIGluIHNvcnRlZChpbmRleCk6CiAgICAgICAgbGlu
ZXMuYXBwZW5kKGYiICBbe2xxKGNlbGwpfV0gPSB7bHEoaW5kZXhbY2VsbF0pfSwiKQoKICAgIGxp
bmVzLmV4dGVuZChbCiAgICAgICAgIn0iLAogICAgICAgICIiLAogICAgICAgICJsb2NhbCBmdW5j
dGlvbiBsb2FkQ2VsbChjZWxsTmFtZSkiLAogICAgICAgICIgICAgbG9jYWwgY2FjaGVkID0gcmF3
Z2V0KFQuY2VsbHMsIGNlbGxOYW1lKSIsCiAgICAgICAgIiAgICBpZiBjYWNoZWQgfj0gbmlsIHRo
ZW4gcmV0dXJuIGNhY2hlZCBlbmQiLAogICAgICAgICIiLAogICAgICAgICIgICAgbG9jYWwgbW9k
dWxlTmFtZSA9IGluZGV4W2NlbGxOYW1lXSIsCiAgICAgICAgIiAgICBpZiBtb2R1bGVOYW1lID09
IG5pbCB0aGVuIHJldHVybiBuaWwgZW5kIiwKICAgICAgICAiIiwKICAgICAgICAiICAgIGxvY2Fs
IGZ1bGxOYW1lID0gJ3NjcmlwdHMuVFNQSW50ZXJpb3JWaXNHcmlkLnRvcG9sb2d5X2NlbGxzLicg
Li4gbW9kdWxlTmFtZSIsCiAgICAgICAgIiAgICBsb2NhbCBvaywgY2VsbCA9IHBjYWxsKHJlcXVp
cmUsIGZ1bGxOYW1lKSIsCiAgICAgICAgIiAgICBpZiBub3Qgb2sgb3IgdHlwZShjZWxsKSB+PSAn
dGFibGUnIHRoZW4gcmV0dXJuIG5pbCBlbmQiLAogICAgICAgICIiLAogICAgICAgICIgICAgcmF3
c2V0KFQuY2VsbHMsIGNlbGxOYW1lLCBjZWxsKSIsCiAgICAgICAgIiAgICByZXR1cm4gY2VsbCIs
CiAgICAgICAgImVuZCIsCiAgICAgICAgIiIsCiAgICAgICAgInNldG1ldGF0YWJsZShULmNlbGxz
LCB7IiwKICAgICAgICAiICAgIF9faW5kZXggPSBmdW5jdGlvbihfLCBjZWxsTmFtZSkiLAogICAg
ICAgICIgICAgICAgIHJldHVybiBsb2FkQ2VsbChjZWxsTmFtZSkiLAogICAgICAgICIgICAgZW5k
LCIsCiAgICAgICAgIn0pIiwKICAgICAgICAiIiwKICAgICAgICAiZnVuY3Rpb24gVC5maW5kU2Vj
dG9yKGNlbGxOYW1lLCB4LCB5LCB6KSIsCiAgICAgICAgIiAgICBsb2NhbCB0YyA9IGxvYWRDZWxs
KGNlbGxOYW1lKSIsCiAgICAgICAgIiAgICBpZiB0YyA9PSBuaWwgdGhlbiByZXR1cm4gbmlsLCBu
aWwgZW5kIiwKICAgICAgICAiIiwKICAgICAgICAiICAgIGxvY2FsIGJzID0gVC5idWNrZXRfc2l6
ZSBvciAzODQiLAogICAgICAgICIgICAgbG9jYWwgYngsIGJ5LCBieiA9IG1hdGguZmxvb3IoeCAv
IGJzKSwgbWF0aC5mbG9vcih5IC8gYnMpLCBtYXRoLmZsb29yKHogLyBicykiLAogICAgICAgICIg
ICAgbG9jYWwgYmVzdFNpZCwgYmVzdEQyID0gbmlsLCAxLjBlMzAiLAogICAgICAgICIiLAogICAg
ICAgICIgICAgZm9yIGR6YiA9IC0xLCAxIGRvIiwKICAgICAgICAiICAgICAgICBmb3IgZHliID0g
LTEsIDEgZG8iLAogICAgICAgICIgICAgICAgICAgICBmb3IgZHhiID0gLTEsIDEgZG8iLAogICAg
ICAgICIgICAgICAgICAgICAgICAgbG9jYWwga2V5ID0gdG9zdHJpbmcoYnggKyBkeGIpIC4uICcs
JyAuLiB0b3N0cmluZyhieSArIGR5YikiLAogICAgICAgICIgICAgICAgICAgICAgICAgICAgIC4u
ICcsJyAuLiB0b3N0cmluZyhieiArIGR6YikiLAogICAgICAgICIgICAgICAgICAgICAgICAgbG9j
YWwgc2FtcGxlcyA9IHRjLmJ1Y2tldHNba2V5XSIsCiAgICAgICAgIiAgICAgICAgICAgICAgICBp
ZiBzYW1wbGVzIH49IG5pbCB0aGVuIiwKICAgICAgICAiICAgICAgICAgICAgICAgICAgICBmb3Ig
aSA9IDEsICNzYW1wbGVzIGRvIiwKICAgICAgICAiICAgICAgICAgICAgICAgICAgICAgICAgbG9j
YWwgcSA9IHNhbXBsZXNbaV0iLAogICAgICAgICIgICAgICAgICAgICAgICAgICAgICAgICBsb2Nh
bCBkeCwgZHksIGR6ID0geCAtIHFbMV0sIHkgLSBxWzJdLCB6IC0gcVszXSIsCiAgICAgICAgIiAg
ICAgICAgICAgICAgICAgICAgICAgIGxvY2FsIGQyID0gZHggKiBkeCArIGR5ICogZHkgKyBkeiAq
IGR6IiwKICAgICAgICAiICAgICAgICAgICAgICAgICAgICAgICAgaWYgZDIgPCBiZXN0RDIgdGhl
biIsCiAgICAgICAgIiAgICAgICAgICAgICAgICAgICAgICAgICAgICBiZXN0RDIgPSBkMiIsCiAg
ICAgICAgIiAgICAgICAgICAgICAgICAgICAgICAgICAgICBiZXN0U2lkID0gcVs0XSIsCiAgICAg
ICAgIiAgICAgICAgICAgICAgICAgICAgICAgIGVuZCIsCiAgICAgICAgIiAgICAgICAgICAgICAg
ICAgICAgZW5kIiwKICAgICAgICAiICAgICAgICAgICAgICAgIGVuZCIsCiAgICAgICAgIiAgICAg
ICAgICAgIGVuZCIsCiAgICAgICAgIiAgICAgICAgZW5kIiwKICAgICAgICAiICAgIGVuZCIsCiAg
ICAgICAgIiIsCiAgICAgICAgIiAgICBpZiBiZXN0U2lkID09IG5pbCB0aGVuIiwKICAgICAgICAi
ICAgICAgICBmb3Igc2lkLCBzZWMgaW4gcGFpcnModGMuc2VjdG9ycykgZG8iLAogICAgICAgICIg
ICAgICAgICAgICBsb2NhbCBiID0gc2VjLmJib3giLAogICAgICAgICIgICAgICAgICAgICBsb2Nh
bCB6UGFkID0gKHNlYy5raW5kID09ICd2ZXJ0aWNhbF9jb25uZWN0b3InKSBhbmQgMjIwLjAgb3Ig
MTIwLjAiLAogICAgICAgICIgICAgICAgICAgICBpZiB4ID49IGJbMV0gLSAyMjAgYW5kIHggPD0g
Yls0XSArIDIyMCIsCiAgICAgICAgIiAgICAgICAgICAgICAgICBhbmQgeSA+PSBiWzJdIC0gMjIw
IGFuZCB5IDw9IGJbNV0gKyAyMjAiLAogICAgICAgICIgICAgICAgICAgICAgICAgYW5kIHogPj0g
YlszXSAtIHpQYWQgYW5kIHogPD0gYls2XSArIHpQYWQgdGhlbiIsCiAgICAgICAgIiAgICAgICAg
ICAgICAgICBsb2NhbCBjID0gc2VjLmNlbnRlciIsCiAgICAgICAgIiAgICAgICAgICAgICAgICBs
b2NhbCBkeCwgZHksIGR6ID0geCAtIGNbMV0sIHkgLSBjWzJdLCB6IC0gY1szXSIsCiAgICAgICAg
IiAgICAgICAgICAgICAgICBsb2NhbCBkMiA9IGR4ICogZHggKyBkeSAqIGR5ICsgZHogKiBkeiIs
CiAgICAgICAgIiAgICAgICAgICAgICAgICBpZiBkMiA8IGJlc3REMiB0aGVuIiwKICAgICAgICAi
ICAgICAgICAgICAgICAgICAgICBiZXN0RDIgPSBkMiIsCiAgICAgICAgIiAgICAgICAgICAgICAg
ICAgICAgYmVzdFNpZCA9IHNpZCIsCiAgICAgICAgIiAgICAgICAgICAgICAgICBlbmQiLAogICAg
ICAgICIgICAgICAgICAgICBlbmQiLAogICAgICAgICIgICAgICAgIGVuZCIsCiAgICAgICAgIiAg
ICBlbmQiLAogICAgICAgICIiLAogICAgICAgICIgICAgcmV0dXJuIGJlc3RTaWQsIGJlc3RTaWQg
fj0gbmlsIGFuZCB0Yy5zZWN0b3JzW2Jlc3RTaWRdIG9yIG5pbCIsCiAgICAgICAgImVuZCIsCiAg
ICAgICAgIiIsCiAgICAgICAgImZ1bmN0aW9uIFQuY2FjaGVLZXkoY2VsbE5hbWUsIHNlY3Rvcklk
KSIsCiAgICAgICAgIiAgICBpZiBzZWN0b3JJZCB+PSBuaWwgYW5kIHNlY3RvcklkID4gMCB0aGVu
IiwKICAgICAgICAiICAgICAgICByZXR1cm4gdG9zdHJpbmcoY2VsbE5hbWUpIC4uICcjdG9wbycg
Li4gdG9zdHJpbmcoc2VjdG9ySWQpIiwKICAgICAgICAiICAgIGVuZCIsCiAgICAgICAgIiAgICBy
ZXR1cm4gY2VsbE5hbWUiLAogICAgICAgICJlbmQiLAogICAgICAgICIiLAogICAgICAgICJmdW5j
dGlvbiBULmdldENlbGwoY2VsbE5hbWUpIiwKICAgICAgICAiICAgIHJldHVybiBsb2FkQ2VsbChj
ZWxsTmFtZSkiLAogICAgICAgICJlbmQiLAogICAgICAgICIiLAogICAgICAgICJyZXR1cm4gVCIs
CiAgICAgICAgIiIsCiAgICBdKQoKICAgIG91dF9wYXRoLndyaXRlX3RleHQoIlxuIi5qb2luKGxp
bmVzKSwgZW5jb2Rpbmc9InV0Zi04IikKCiAgICBzdW1tYXJ5WyJsb2FkZXJfYnl0ZXMiXSA9IG91
dF9wYXRoLnN0YXQoKS5zdF9zaXplCgoKZGVmIG1haW4oKToKICAgIGFwID0gYXJncGFyc2UuQXJn
dW1lbnRQYXJzZXIoKQogICAgYXAuYWRkX2FyZ3VtZW50KCJwYWNrIikKICAgIGFwLmFkZF9hcmd1
bWVudCgiLS1iYXNlLWNvbXBpbGVyIiwgcmVxdWlyZWQ9VHJ1ZSkKICAgIGFwLmFkZF9hcmd1bWVu
dCgiLS1pbnRlcmlvcm1hcCIsIHJlcXVpcmVkPVRydWUpCiAgICBhcC5hZGRfYXJndW1lbnQoIi0t
b3V0cHV0LWRpciIsIHJlcXVpcmVkPVRydWUpCiAgICBhcmdzID0gYXAucGFyc2VfYXJncygpCgog
ICAgcGFjayA9IFBhdGgoYXJncy5wYWNrKQogICAgYmFzZV9wYXRoID0gUGF0aChhcmdzLmJhc2Vf
Y29tcGlsZXIpCiAgICBpbnRlcmlvcm1hcCA9IFBhdGgoYXJncy5pbnRlcmlvcm1hcCkKICAgIG91
dGRpciA9IFBhdGgoYXJncy5vdXRwdXRfZGlyKQogICAgc2hhcmRzID0gb3V0ZGlyIC8gInRvcG9s
b2d5X2NlbGxzIgoKICAgIGlmIG91dGRpci5leGlzdHMoKToKICAgICAgICBzaHV0aWwucm10cmVl
KG91dGRpcikKICAgIHNoYXJkcy5ta2RpcihwYXJlbnRzPVRydWUpCgogICAgc3BlYyA9IGltcG9y
dGxpYi51dGlsLnNwZWNfZnJvbV9maWxlX2xvY2F0aW9uKCJ0c3BfYmFzZV90b3BvbG9neSIsIGJh
c2VfcGF0aCkKICAgIGJhc2UgPSBpbXBvcnRsaWIudXRpbC5tb2R1bGVfZnJvbV9zcGVjKHNwZWMp
CiAgICBhc3NlcnQgc3BlYy5sb2FkZXIgaXMgbm90IE5vbmUKICAgIHNwZWMubG9hZGVyLmV4ZWNf
bW9kdWxlKGJhc2UpCgogICAgYWxsb3cgPSBsb2FkX2FsbG93bGlzdChpbnRlcmlvcm1hcCkKICAg
IHBhY2tfc2hhID0gaGFzaGxpYi5zaGEyNTYocGFjay5yZWFkX2J5dGVzKCkpLmhleGRpZ2VzdCgp
CgogICAgaW5kZXggPSB7fQogICAgY29tcGlsZWQgPSAwCiAgICBza2lwcGVkX25vdF9pbl9tYXAg
PSAwCiAgICBza2lwcGVkX2VtcHR5ID0gMAogICAgdG90YWxfc2VjdG9ycyA9IDAKICAgIHRvdGFs
X3BvcnRhbHMgPSAwCiAgICB0b3RhbF90aWxlcyA9IDAKICAgIHRvdGFsX3NlY3Rvcl9tZXJnZXMg
PSAwCiAgICBjb2Fyc2VuZWRfY2VsbHMgPSAwCiAgICBsYXJnZXN0ID0gW10KCiAgICB3aXRoIHRl
bXBmaWxlLlRlbXBvcmFyeURpcmVjdG9yeShwcmVmaXg9InRzcC10b3BvbG9neS0iKSBhcyB0ZDoK
ICAgICAgICB0ZW1wX21zZXQgPSBQYXRoKHRkKSAvICJjZWxsLmJpbiIKCiAgICAgICAgZm9yIHJl
Y29yZF9ubywgY2VsbCwgZGF0YSBpbiBpdGVyX3BhY2socGFjayk6CiAgICAgICAgICAgIGlmIGNl
bGwgbm90IGluIGFsbG93OgogICAgICAgICAgICAgICAgc2tpcHBlZF9ub3RfaW5fbWFwICs9IDEK
ICAgICAgICAgICAgICAgIGNvbnRpbnVlCgogICAgICAgICAgICB0ZW1wX21zZXQud3JpdGVfYnl0
ZXMoZGF0YSkKICAgICAgICAgICAgc291cmNlX3NoYSA9IGhhc2hsaWIuc2hhMjU2KGRhdGEpLmhl
eGRpZ2VzdCgpCgogICAgICAgICAgICB0cnk6CiAgICAgICAgICAgICAgICBfLCB0aWxlcyA9IGJh
c2UucmVhZF9tc2V0KHRlbXBfbXNldCkKICAgICAgICAgICAgICAgIGlmIG5vdCB0aWxlczoKICAg
ICAgICAgICAgICAgICAgICBza2lwcGVkX2VtcHR5ICs9IDEKICAgICAgICAgICAgICAgICAgICBj
b250aW51ZQoKICAgICAgICAgICAgICAgIHNjYWxlID0gYmFzZS5kZXRlY3Rfc2NhbGUodGlsZXMp
CiAgICAgICAgICAgICAgICBncm91bmQgPSBiYXNlLmJ1aWxkX2dyb3VuZCh0aWxlcykKICAgICAg
ICAgICAgICAgIGlmIG5vdCBncm91bmQ6CiAgICAgICAgICAgICAgICAgICAgc2tpcHBlZF9lbXB0
eSArPSAxCiAgICAgICAgICAgICAgICAgICAgY29udGludWUKCiAgICAgICAgICAgICAgICBhZGog
PSBiYXNlLmJ1aWxkX2FkamFjZW5jeShncm91bmQpCiAgICAgICAgICAgICAgICBwZWFrcywgXyA9
IGJhc2UuZmluZF9mbG9vcl9wZWFrcyhncm91bmQpCiAgICAgICAgICAgICAgICBzZWN0b3JzLCBw
MnMgPSBiYXNlLm1ha2Vfc2VjdG9ycyhncm91bmQsIGFkaiwgcGVha3MsIHNjYWxlKQogICAgICAg
ICAgICAgICAgc2VjdG9ycywgcDJzLCBtZXJnZXMgPSBjb2Fyc2VuX3NlY3RvcnMoc2VjdG9ycywg
cDJzLCA2NCkKICAgICAgICAgICAgICAgIHBvcnRhbHMgPSBiYXNlLm1ha2VfcG9ydGFscyh0aWxl
cywgZ3JvdW5kLCBwMnMsIHNjYWxlKQogICAgICAgICAgICAgICAgcG9ydGFscy5leHRlbmQoCiAg
ICAgICAgICAgICAgICAgICAgYmFzZS5tYWtlX2JvdW5kYXJ5X3BvcnRhbHMoCiAgICAgICAgICAg
ICAgICAgICAgICAgIGdyb3VuZCwKICAgICAgICAgICAgICAgICAgICAgICAgYWRqLAogICAgICAg
ICAgICAgICAgICAgICAgICBwMnMsCiAgICAgICAgICAgICAgICAgICAgICAgIHNjYWxlLAogICAg
ICAgICAgICAgICAgICAgICAgICAxICsgbWF4KFtwWyJpZCJdIGZvciBwIGluIHBvcnRhbHNdLCBk
ZWZhdWx0PTApLAogICAgICAgICAgICAgICAgICAgICkKICAgICAgICAgICAgICAgICkKICAgICAg
ICAgICAgICAgIGZpbmFsaXplX3NlY3Rvcl9saW5rcyhzZWN0b3JzLCBwb3J0YWxzKQogICAgICAg
ICAgICAgICAgYnVja2V0cyA9IGJhc2UuYnVpbGRfYnVja2V0cyhncm91bmQsIHAycywgc2NhbGUp
CgogICAgICAgICAgICAgICAgbW9kdWxlID0gImNfIiArIGhhc2hsaWIuc2hhMShjZWxsLmVuY29k
ZSgidXRmLTgiKSkuaGV4ZGlnZXN0KCkKICAgICAgICAgICAgICAgIHNoYXJkID0gc2hhcmRzIC8g
ZiJ7bW9kdWxlfS5sdWEiCiAgICAgICAgICAgICAgICBlbWl0X2NlbGxfc2hhcmQoCiAgICAgICAg
ICAgICAgICAgICAgY2VsbCwKICAgICAgICAgICAgICAgICAgICBzb3VyY2Vfc2hhLAogICAgICAg
ICAgICAgICAgICAgIHNjYWxlLAogICAgICAgICAgICAgICAgICAgIHBlYWtzLAogICAgICAgICAg
ICAgICAgICAgIHNlY3RvcnMsCiAgICAgICAgICAgICAgICAgICAgcG9ydGFscywKICAgICAgICAg
ICAgICAgICAgICBidWNrZXRzLAogICAgICAgICAgICAgICAgICAgIHNoYXJkLAogICAgICAgICAg
ICAgICAgKQoKICAgICAgICAgICAgICAgIGluZGV4W2NlbGxdID0gbW9kdWxlCiAgICAgICAgICAg
ICAgICBjb21waWxlZCArPSAxCiAgICAgICAgICAgICAgICB0b3RhbF90aWxlcyArPSBsZW4odGls
ZXMpCiAgICAgICAgICAgICAgICB0b3RhbF9zZWN0b3JzICs9IGxlbihzZWN0b3JzKQogICAgICAg
ICAgICAgICAgdG90YWxfcG9ydGFscyArPSBsZW4ocG9ydGFscykKICAgICAgICAgICAgICAgIHRv
dGFsX3NlY3Rvcl9tZXJnZXMgKz0gbWVyZ2VzCiAgICAgICAgICAgICAgICBpZiBtZXJnZXMgPiAw
OgogICAgICAgICAgICAgICAgICAgIGNvYXJzZW5lZF9jZWxscyArPSAxCiAgICAgICAgICAgICAg
ICBsYXJnZXN0LmFwcGVuZCgobGVuKGdyb3VuZCksIGxlbihzZWN0b3JzKSwgc2hhcmQuc3RhdCgp
LnN0X3NpemUsIGNlbGwpKQoKICAgICAgICAgICAgICAgIGlmIGNvbXBpbGVkID09IDEgb3IgY29t
cGlsZWQgJSAyNSA9PSAwOgogICAgICAgICAgICAgICAgICAgIHByaW50KAogICAgICAgICAgICAg
ICAgICAgICAgICBmIltjb21waWxlXSB7Y29tcGlsZWR9L3tsZW4oYWxsb3cpfSBjZWxscyAiCiAg
ICAgICAgICAgICAgICAgICAgICAgIGYibGF0ZXN0PXtjZWxsIXJ9IHRpbGVzPXtsZW4odGlsZXMp
fSAiCiAgICAgICAgICAgICAgICAgICAgICAgIGYicG9seXM9e2xlbihncm91bmQpfSBzZWN0b3Jz
PXtsZW4oc2VjdG9ycyl9IgogICAgICAgICAgICAgICAgICAgICkKCiAgICAgICAgICAgIGV4Y2Vw
dCBFeGNlcHRpb24gYXMgZXhjOgogICAgICAgICAgICAgICAgcmFpc2UgU3lzdGVtRXhpdCgKICAg
ICAgICAgICAgICAgICAgICBmIkVSUk9SIGNvbXBpbGluZyByZWNvcmQge3JlY29yZF9ub30gY2Vs
bCB7Y2VsbCFyfToge2V4Y30iCiAgICAgICAgICAgICAgICApIGZyb20gZXhjCgogICAgc3VtbWFy
eSA9IHsKICAgICAgICAiZm9ybWF0IjogMSwKICAgICAgICAicGFja19zaGEyNTYiOiBwYWNrX3No
YSwKICAgICAgICAiYWxsb3dsaXN0X2NlbGxzIjogbGVuKGFsbG93KSwKICAgICAgICAiY29tcGls
ZWRfY2VsbHMiOiBjb21waWxlZCwKICAgICAgICAic2tpcHBlZF9ub3RfaW5fbWFwIjogc2tpcHBl
ZF9ub3RfaW5fbWFwLAogICAgICAgICJza2lwcGVkX2VtcHR5Ijogc2tpcHBlZF9lbXB0eSwKICAg
ICAgICAidGlsZXMiOiB0b3RhbF90aWxlcywKICAgICAgICAic2VjdG9ycyI6IHRvdGFsX3NlY3Rv
cnMsCiAgICAgICAgInBvcnRhbHMiOiB0b3RhbF9wb3J0YWxzLAogICAgICAgICJjb2Fyc2VuZWRf
Y2VsbHMiOiBjb2Fyc2VuZWRfY2VsbHMsCiAgICAgICAgInNlY3Rvcl9tZXJnZXMiOiB0b3RhbF9z
ZWN0b3JfbWVyZ2VzLAogICAgfQoKICAgIGVtaXRfbG9hZGVyKGluZGV4LCBwYWNrX3NoYSwgc3Vt
bWFyeSwgb3V0ZGlyIC8gInRvcG9sb2d5Lmx1YSIpCgogICAgbGFyZ2VzdC5zb3J0KHJldmVyc2U9
VHJ1ZSkKICAgIHN1bW1hcnlfbGluZXMgPSBbCiAgICAgICAgIlRTUCBHTE9CQUwgSU5URVJJT1Ig
VE9QT0xPR1kiLAogICAgICAgICI9PT09PT09PT09PT09PT09PT09PT09PT09PT09IiwKICAgICAg
ICBmInBhY2tfc2hhMjU2PXtwYWNrX3NoYX0iLAogICAgICAgIGYiaW50ZXJpb3JfYWxsb3dsaXN0
PXtsZW4oYWxsb3cpfSIsCiAgICAgICAgZiJjb21waWxlZF9jZWxscz17Y29tcGlsZWR9IiwKICAg
ICAgICBmInNraXBwZWRfbm90X2luX21hcD17c2tpcHBlZF9ub3RfaW5fbWFwfSIsCiAgICAgICAg
ZiJza2lwcGVkX2VtcHR5PXtza2lwcGVkX2VtcHR5fSIsCiAgICAgICAgZiJ0aWxlcz17dG90YWxf
dGlsZXN9IiwKICAgICAgICBmInNlY3RvcnM9e3RvdGFsX3NlY3RvcnN9IiwKICAgICAgICBmInBv
cnRhbHM9e3RvdGFsX3BvcnRhbHN9IiwKICAgICAgICBmImNvYXJzZW5lZF9jZWxscz17Y29hcnNl
bmVkX2NlbGxzfSIsCiAgICAgICAgZiJzZWN0b3JfbWVyZ2VzPXt0b3RhbF9zZWN0b3JfbWVyZ2Vz
fSIsCiAgICAgICAgZiJsb2FkZXJfYnl0ZXM9e3N1bW1hcnlbJ2xvYWRlcl9ieXRlcyddfSIsCiAg
ICAgICAgIiIsCiAgICAgICAgImxhcmdlc3RfY2VsbHNfYnlfZ3JvdW5kX3BvbHlnb25zOiIsCiAg
ICBdCgogICAgZm9yIHBvbHlzLCBzZWN0b3JzLCBzaXplLCBjZWxsIGluIGxhcmdlc3RbOjMwXToK
ICAgICAgICBzdW1tYXJ5X2xpbmVzLmFwcGVuZCgKICAgICAgICAgICAgZiJ7cG9seXN9XHR7c2Vj
dG9yc31cdHtzaXplfVx0e2NlbGx9IgogICAgICAgICkKCiAgICAob3V0ZGlyIC8gIkdMT0JBTC1U
T1BPTE9HWS1TVU1NQVJZLnR4dCIpLndyaXRlX3RleHQoCiAgICAgICAgIlxuIi5qb2luKHN1bW1h
cnlfbGluZXMpICsgIlxuIiwgZW5jb2Rpbmc9InV0Zi04IgogICAgKQoKICAgIGlmIGNvbXBpbGVk
IDwgbWF4KDEsIGludChsZW4oYWxsb3cpICogMC45MCkpOgogICAgICAgIHJhaXNlIFN5c3RlbUV4
aXQoCiAgICAgICAgICAgIGYiRVJST1I6IG9ubHkgY29tcGlsZWQge2NvbXBpbGVkfS97bGVuKGFs
bG93KX0gbWFwcGVkIGludGVyaW9yIGNlbGxzIgogICAgICAgICkKCiAgICBwcmludCgpCiAgICBw
cmludCgiUEFTUzogZ2xvYmFsIHRvcG9sb2d5IGNvbXBpbGVkIikKICAgIGZvciBsaW5lIGluIHN1
bW1hcnlfbGluZXNbMjoxMF06CiAgICAgICAgcHJpbnQobGluZSkKCgppZiBfX25hbWVfXyA9PSAi
X19tYWluX18iOgogICAgbWFpbigpCg==
EOF_GLOBAL

base64 -d \
    "$OUT/compile_openmw_global_interior_topology.py.b64" \
    > "$OUT/compile_openmw_global_interior_topology.py"

chmod +x \
    "$OUT/compile_openmw_global_interior_topology.py"

python3 -m py_compile \
    "$OUT/compile_openmw_navmesh_topology.py" \
    "$OUT/compile_openmw_global_interior_topology.py"

COMPILED="$OUT/compiled"

python3 \
    "$OUT/compile_openmw_global_interior_topology.py" \
    "$OUT/all-interiors.msetpack" \
    --base-compiler \
        "$OUT/compile_openmw_navmesh_topology.py" \
    --interiormap \
        "$OUT/interiormap.lua" \
    --output-dir \
        "$COMPILED" \
    | tee "$OUT/compile-global.log"

test -s "$COMPILED/topology.lua"
test -d "$COMPILED/topology_cells"
test -s "$COMPILED/GLOBAL-TOPOLOGY-SUMMARY.txt"

SHARDS="$(
    find "$COMPILED/topology_cells" \
        -type f \
        -name '*.lua' |
    wc -l
)"

echo
echo "Compiled topology shards: $SHARDS"

MIN_SHARDS=$((ALLOW_COUNT * 90 / 100))

if [ "$SHARDS" -lt "$MIN_SHARDS" ]; then
    echo "ERROR: fewer than 90% of mapped interiors produced topology."
    exit 23
fi

grep -q \
    'TSP_VISGRID_GLOBAL_TOPOLOGY_V1' \
    "$COMPILED/topology.lua"

echo
echo "===== GOVERNOR'S HALL REGRESSION CHECK ====="

python3 - \
    "$COMPILED/topology.lua" \
    "$COMPILED/topology_cells" \
    <<'PY_GOV'
from pathlib import Path
import hashlib
import re
import sys

loader = Path(sys.argv[1]).read_text(
    encoding="utf-8",
    errors="replace",
)

cells = Path(sys.argv[2])
name = "Caldera, Governor's Hall"
module = "c_" + hashlib.sha1(
    name.encode("utf-8")
).hexdigest()

shard = cells / f"{module}.lua"

if not shard.exists():
    print("NOTE: Governor's Hall shard absent; continuing.")
    raise SystemExit(0)

text = shard.read_text(
    encoding="utf-8",
    errors="replace",
)

def extract_table(name):
    marker = f"  {name} = {{"

    begin = text.find(marker)

    if begin < 0:
        raise SystemExit(
            f"ERROR: Governor's Hall {name} table missing"
        )

    begin = text.find("\n", begin) + 1
    finish = text.find("\n  },", begin)

    if finish < 0:
        raise SystemExit(
            f"ERROR: Governor's Hall {name} table is malformed"
        )

    return text[begin:finish]


entry_re = re.compile(
    r'^\s*\[(\d+)\]\s*=\s*\{\s*id=(\d+)',
    re.M,
)

sector_entries = entry_re.findall(
    extract_table("sectors")
)

portal_entries = entry_re.findall(
    extract_table("portals")
)

sectors = len(sector_entries)
portals = len(portal_entries)

print(
    "Governor's Hall actual sectors:",
    sectors,
)

print(
    "Governor's Hall portals:",
    portals,
)

if sectors < 1 or sectors > 64:
    raise SystemExit(
        "ERROR: Governor's Hall PVS sector count "
        f"outside supported range 1..64: {sectors}"
    )

sector_ids = [
    int(a)
    for a, b in sector_entries
]

if len(set(sector_ids)) != sectors:
    raise SystemExit(
        "ERROR: duplicate Governor's Hall sector IDs"
    )

print(
    "PASS: Governor's Hall topology fits "
    "the V20 <=64-sector PVS limit."
)

PY_GOV

echo
echo "===== 8/10 PACKAGE + INSTALL TOPOLOGY DATA ONLY ====="

tar -C "$COMPILED" \
    -czf "$OUT/global-interior-topology.tar.gz" \
    topology.lua \
    topology_cells \
    GLOBAL-TOPOLOGY-SUMMARY.txt

scp -q \
    "$OUT/global-interior-topology.tar.gz" \
    "$DEV:$ROOT/global-interior-topology.tar.gz.new"

ssh "$DEV" "
set -e

TMP='$MOD/.topology-install-$STAMP'
BACK='$MOD/topology-backups/$STAMP'

rm -rf \"\$TMP\"
mkdir -p \"\$TMP\" \"\$BACK\"

tar -xzf \
    '$ROOT/global-interior-topology.tar.gz.new' \
    -C \"\$TMP\"

test -s \"\$TMP/topology.lua\"

grep -q \
    'TSP_VISGRID_GLOBAL_TOPOLOGY_V1' \
    \"\$TMP/topology.lua\"

NEWCOUNT=\$(
    find \"\$TMP/topology_cells\" \
        -type f \
        -name '*.lua' |
    wc -l
)

[ \"\$NEWCOUNT\" -ge '$MIN_SHARDS' ]

if [ -s '$TOPOLOGY' ]; then
    cp -p \
        '$TOPOLOGY' \
        \"\$BACK/topology.lua.before\"
fi

if [ -d '$TOPOLOGY_CELLS' ]; then
    mv \
        '$TOPOLOGY_CELLS' \
        \"\$BACK/topology_cells.before\"
fi

mv \
    \"\$TMP/topology_cells\" \
    '$TOPOLOGY_CELLS'

mv \
    \"\$TMP/topology.lua\" \
    '$TOPOLOGY'

mv \
    \"\$TMP/GLOBAL-TOPOLOGY-SUMMARY.txt\" \
    '$MOD/scripts/TSPInteriorVisGrid/GLOBAL-TOPOLOGY-SUMMARY.txt'

rmdir \"\$TMP\" 2>/dev/null || true

rm -f \
    '$ROOT/global-interior-topology.tar.gz.new'

sync

echo 'Installed topology:'
ls -lh '$TOPOLOGY'

echo
printf 'topology shards='
find '$TOPOLOGY_CELLS' \
    -type f \
    -name '*.lua' |
wc -l
"

echo
echo "===== 9/10 VERIFY PROTECTED RUNTIME / DB UNCHANGED ====="

GAME_SHA_AFTER="$(
    ssh "$DEV" \
        "sha256sum '$ROOT/bin/openmw-0.51'" |
    awk '{print $1}'
)"

VISGRID_SHA_AFTER="$(
    ssh "$DEV" \
        "sha256sum '$VISGRID'" |
    awk '{print $1}'
)"

DB_STAT_FINAL="$(
    ssh "$DEV" \
        "stat -c '%s %Y' '$DB'"
)"

[ "$GAME_SHA_AFTER" = "$GAME_SHA_BEFORE" ] || {
    echo "ERROR: game binary changed unexpectedly."
    exit 24
}

[ "$VISGRID_SHA_AFTER" = "$VISGRID_SHA_BEFORE" ] || {
    echo "ERROR: V20 visgrid.lua changed unexpectedly."
    exit 25
}

[ "$DB_STAT_FINAL" = "$DB_STAT_BEFORE" ] || {
    echo "ERROR: completed navmesh.db size/mtime changed unexpectedly."
    exit 26
}

ssh "$DEV" "
set -e

grep -q \
    'TSP_VISGRID_GLOBAL_TOPOLOGY_V1' \
    '$TOPOLOGY'

echo '--- global topology summary ---'
cat \
  '$MOD/scripts/TSPInteriorVisGrid/GLOBAL-TOPOLOGY-SUMMARY.txt'

echo
echo '--- installed shard count ---'
find '$TOPOLOGY_CELLS' \
    -type f \
    -name '*.lua' |
wc -l
"

echo "PASS: game binary byte-identical."
echo "PASS: V20 sensor byte-identical."
echo "PASS: completed navmesh.db size/mtime identical."

echo
echo "===== 10/10 WRITE TEST TRACE COLLECTOR ====="

cat > "$HOME/Downloads/pull-global-interior-topology-test.sh" <<'TRACE'
#!/usr/bin/env bash
set -Eeuo pipefail

cd "$HOME/Downloads"

DEV="${TSP_DEV:-root@192.168.1.25}"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="$HOME/Downloads/global-interior-topology-test-$STAMP.txt"

ssh "$DEV" '
ROOT="/mnt/SDCARD/data/ports/openmw51"
MOD="$ROOT/mods/TSPInteriorVisGrid/scripts/TSPInteriorVisGrid"

echo "===== INSTALLED GLOBAL TOPOLOGY ====="

grep -n \
    "TSP_VISGRID_GLOBAL_TOPOLOGY_V1" \
    "$MOD/topology.lua" 2>/dev/null || true

printf "shards="
find "$MOD/topology_cells" \
    -type f \
    -name "*.lua" 2>/dev/null |
wc -l

echo
echo "===== TOPOLOGY SUMMARY ====="
cat "$MOD/GLOBAL-TOPOLOGY-SUMMARY.txt" \
    2>/dev/null || true

echo
echo "===== VISGRID / PVS SESSION ====="

for LOG in \
    "$ROOT/openmw_051_log.txt" \
    "$ROOT/log-0.51.txt" \
    "$ROOT/config-0.51/openmw.log" \
    "$ROOT/config-0.51/openmw.log.old"
do
    [ -s "$LOG" ] || continue

    echo
    echo "--- $LOG ---"

    grep -E \
"TSP_VISGRID_V20|topology loaded|topology sector=|TSP_INTERIOR_VISGRID_051_V5_TOPO_PVS|PVS floor=|PVS disabled|no topology module|raycast-only" \
        "$LOG" 2>/dev/null |
    tail -500 || true
done

echo
echo "===== RECENT ERRORS ====="

for LOG in \
    "$ROOT/openmw_051_log.txt" \
    "$ROOT/log-0.51.txt" \
    "$ROOT/config-0.51/openmw.log" \
    "$ROOT/config-0.51/openmw.log.old"
do
    [ -s "$LOG" ] || continue

    echo
    echo "--- $LOG ---"

    grep -Ei \
"Lua.*error|TSP_VISGRID.*error|topology.*error|segfault|fatal|exception" \
        "$LOG" 2>/dev/null |
    tail -160 || true
done

echo
echo "===== KERNEL ====="

dmesg 2>/dev/null |
grep -Ei \
"openmw|segfault|oom|killed process|abort|bus error|illegal instruction" |
tail -180 || true
' | tee "$OUT"

echo
echo "Saved:"
echo "  $OUT"
TRACE

chmod +x \
    "$HOME/Downloads/pull-global-interior-topology-test.sh"

echo
echo "===================================================================="
echo "GLOBAL INTERIOR TOPOLOGY INSTALLED"
echo "===================================================================="
echo
echo "The completed navmesh.db was read-only and stayed unchanged."
echo "The game binary and V20 sensor stayed byte-identical."
echo
echo "Now start Morrowind normally and test several interiors."
echo
echo "Recommended first pass:"
echo "  - Caldera, Governor's Hall"
echo "  - a multi-floor dungeon"
echo "  - one unusually large interior"
echo
echo "Then collect the rendering trace:"
echo
echo "  cd ~/Downloads"
echo "  ./pull-global-interior-topology-test.sh"
echo
echo "Artifacts:"
echo "  $OUT"
echo "===================================================================="
