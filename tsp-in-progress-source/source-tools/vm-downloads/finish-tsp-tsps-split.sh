#!/usr/bin/env bash

set -Eeuo pipefail

STAMP="$(date +%Y%m%d-%H%M%S)"

fail()
{
    rc=$?
    trap - ERR
    echo
    echo "============================================================"
    echo "FAILED - exit $rc"
    echo "============================================================"
    echo "No source rollback was performed."
    exit "$rc"
}

trap fail ERR

echo "[1/5] Verifying source split..."

# TSP side MUST contain diagnostics.
docker exec openmw_builder \
    grep -aF 'TSP_TEXLIFE_V2' \
    /root/gl4es-tsp/src/gl/texture_params.c \
    >/dev/null

docker exec openmw_builder \
    grep -aF 'TSP_MAPLIFE_V2' \
    /root/openmw-0.51-tsp-src/apps/openmw/mwrender/localmap.cpp \
    >/dev/null

# TSPS side MUST NOT contain diagnostics.
if docker exec openmw_builder \
    grep -aF 'TSP_TEXLIFE_V2' \
    /root/gl4es-tsps/src/gl/texture_params.c \
    >/dev/null
then
    echo "ERROR: TSPS gl4es still contains diagnostic instrumentation."
    exit 20
fi

if docker exec openmw_builder \
    grep -aF 'TSP_MAPLIFE_V2' \
    /root/openmw-0.51-tsps-src/apps/openmw/mwrender/localmap.cpp \
    >/dev/null
then
    echo "ERROR: TSPS OpenMW still contains diagnostic instrumentation."
    exit 21
fi

echo "      PASS: source trees are already correctly separated."


echo
echo "[2/5] Creating the missing TSP gl4es build script..."

# NOTE THE -i. This was the bug before.
docker exec -i openmw_builder python3 - <<'PY'
from pathlib import Path

src = Path("/root/rebuild_gl4es_tsps_o3.sh")
dst = Path("/root/rebuild_gl4es_tsp_o3.sh")

if not src.is_file():
    raise SystemExit("ERROR: TSPS rebuild script is missing")

s = src.read_text()

if "gl4es-tsps" not in s:
    raise SystemExit(
        "ERROR: could not find gl4es-tsps in original rebuild script"
    )

s = s.replace("gl4es-tsps", "gl4es-tsp")

dst.write_text(s)
dst.chmod(0o755)

print("created:", dst)
PY

docker exec openmw_builder \
    test -x /root/rebuild_gl4es_tsp_o3.sh

docker exec openmw_builder \
    grep -F '/root/gl4es-tsp' \
    /root/rebuild_gl4es_tsp_o3.sh \
    >/dev/null

echo "      PASS: /root/rebuild_gl4es_tsp_o3.sh"


echo
echo "[3/5] Replacing ONLY the broken empty TSPS CMake build directory..."

docker exec openmw_builder bash -lc "
    set -e

    if [ -d /root/openmw-0.51-tsps-build ]; then
        mv \
          /root/openmw-0.51-tsps-build \
          /root/openmw-0.51-tsps-build.bad-$STAMP
    fi

    mkdir -p /root/openmw-0.51-tsps-build
"

echo "      Source trees were NOT touched."


echo
echo "[4/5] Configuring separate TSPS OpenMW build..."
echo "      This is CONFIGURE ONLY. It will NOT compile OpenMW."
echo

# NOTE THE -i HERE TOO.
docker exec -i openmw_builder python3 - <<'PY'
from pathlib import Path
import re
import subprocess

SRC_TSP = "/root/openmw-0.51-tsp-src"
BUILD_TSP = "/root/openmw-0.51-tsp-build"

SRC_TSPS = "/root/openmw-0.51-tsps-src"
BUILD_TSPS = "/root/openmw-0.51-tsps-build"

cache = Path(BUILD_TSP) / "CMakeCache.txt"

if not cache.is_file():
    raise SystemExit(
        "ERROR: working diagnostic TSP CMakeCache.txt is missing"
    )

generator = None
platform = None
toolset = None

args = []

allowed_types = {
    "BOOL",
    "STRING",
    "PATH",
    "FILEPATH",
}

skip = {
    "CMAKE_CACHEFILE_DIR",
    "CMAKE_HOME_DIRECTORY",
    "CMAKE_GENERATOR",
    "CMAKE_GENERATOR_INSTANCE",
    "CMAKE_GENERATOR_PLATFORM",
    "CMAKE_GENERATOR_TOOLSET",
    "CMAKE_COMMAND",
    "CMAKE_CPACK_COMMAND",
    "CMAKE_CTEST_COMMAND",
    "CMAKE_ROOT",
}

for line in cache.read_text(errors="replace").splitlines():

    if not line or line.startswith("//") or line.startswith("#"):
        continue

    m = re.match(r"([^:=]+):([^=]+)=(.*)", line)

    if not m:
        continue

    key, typ, value = m.groups()

    if key == "CMAKE_GENERATOR":
        generator = value
        continue

    if key == "CMAKE_GENERATOR_PLATFORM":
        platform = value
        continue

    if key == "CMAKE_GENERATOR_TOOLSET":
        toolset = value
        continue

    if typ not in allowed_types:
        continue

    if key in skip:
        continue

    # CMake-generated identity values.
    if key.endswith("_SOURCE_DIR"):
        continue

    if key.endswith("_BINARY_DIR"):
        continue

    value = value.replace(SRC_TSP, SRC_TSPS)
    value = value.replace(BUILD_TSP, BUILD_TSPS)

    args.append(f"-D{key}:{typ}={value}")

cmd = [
    "cmake",
    "-S", SRC_TSPS,
    "-B", BUILD_TSPS,
]

if generator:
    cmd += ["-G", generator]

if platform:
    cmd += ["-A", platform]

if toolset:
    cmd += ["-T", toolset]

cmd += args

print("generator:", generator)
print("copied configuration options:", len(args))
print("source:", SRC_TSPS)
print("build:", BUILD_TSPS)
print()
print("Running CMake configure now...")
print()

subprocess.run(cmd, check=True)
PY


echo
echo "[5/5] Final verification..."

docker exec openmw_builder bash -lc '
    set -e

    test -f /root/openmw-0.51-tsps-build/CMakeCache.txt

    grep -F \
      "CMAKE_HOME_DIRECTORY:INTERNAL=/root/openmw-0.51-tsps-src" \
      /root/openmw-0.51-tsps-build/CMakeCache.txt \
      >/dev/null

    grep -F \
      "/root/openmw-0.51-tsps-build" \
      /root/openmw-0.51-tsps-build/CMakeCache.txt \
      >/dev/null

    test -x /root/rebuild_gl4es_tsps_o3.sh
    test -x /root/rebuild_gl4es_tsp_o3.sh
'

echo
echo "============================================================"
echo "PASS: SPLIT FINISHED -- NOTHING WAS REBUILT"
echo "============================================================"
echo
echo "KNOWN-GOOD TSPS"
echo "  gl4es source: /root/gl4es-tsps"
echo "  gl4es build:  /root/rebuild_gl4es_tsps_o3.sh"
echo "  OpenMW src:   /root/openmw-0.51-tsps-src"
echo "  OpenMW build: /root/openmw-0.51-tsps-build"
echo
echo "DIAGNOSTIC TSP"
echo "  gl4es source: /root/gl4es-tsp"
echo "  gl4es build:  /root/rebuild_gl4es_tsp_o3.sh"
echo "  OpenMW src:   /root/openmw-0.51-tsp-src"
echo "  OpenMW build: /root/openmw-0.51-tsp-build"
echo
echo "Your ALREADY-BUILT diagnostic binaries remain:"
echo "  /home/bob-simpson/Downloads/libGL.so.1-tsp-texlife-v2"
echo "  /home/bob-simpson/Downloads/openmw-tsp-maplife-v2"
echo "============================================================"
