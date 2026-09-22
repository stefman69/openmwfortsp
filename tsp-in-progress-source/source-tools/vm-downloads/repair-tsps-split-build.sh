#!/usr/bin/env bash

set -Eeuo pipefail

D=/home/bob-simpson/Downloads
LOG="$D/repair-tsps-split-build.log"
STAMP="$(date +%Y%m%d-%H%M%S)"

TSPS_GL_OUT="$D/libGL.so.1-tsps-known-good"
TSPS_OMW_OUT="$D/openmw-tsps-known-good"

: > "$LOG"

fail()
{
    rc=$?
    trap - ERR

    echo
    echo "============================================================"
    echo "FAILED - exit $rc"
    echo "============================================================"
    echo "Your terminal is still usable."
    echo
    echo "Log:"
    echo "  $LOG"
    echo
    echo "Last 70 lines:"
    tail -n 70 "$LOG" 2>/dev/null || true
    exit "$rc"
}

trap fail ERR


run_live()
{
    local title="$1"
    shift

    local tmp
    tmp="$(mktemp "$D/.build-progress.XXXXXX")"

    echo
    echo "============================================================"
    echo "$title"
    echo "============================================================"

    "$@" >"$tmp" 2>&1 &
    local pid=$!

    local shown=0
    local beat=0

    while kill -0 "$pid" 2>/dev/null
    do
        sleep 2

        local now
        now="$(wc -l < "$tmp")"

        if [ "$now" -gt "$shown" ]; then
            sed -n "$((shown + 1)),$now p" "$tmp" \
                | grep -E \
'^\[[[:space:]]*[0-9]+%]|^\[[0-9]+/[0-9]+\]|Building (C|CXX)|Linking|Built target|Built library|Configuring|Generating|-- |error:|Error:|FAILED|undefined reference|collect2:' \
                | tail -n 25 \
                | sed 's/^/      /' \
                || true

            shown="$now"
        fi

        beat=$((beat + 2))

        if [ "$beat" -ge 10 ]; then
            echo "      [$(date +%H:%M:%S)] still running..."
            beat=0
        fi
    done

    local rc=0

    if wait "$pid"; then
        rc=0
    else
        rc=$?
    fi

    cat "$tmp" >> "$LOG"

    if [ "$rc" -ne 0 ]; then
        echo
        echo "Command failed. Last output:"
        tail -n 50 "$tmp"
        rm -f "$tmp"
        return "$rc"
    fi

    rm -f "$tmp"

    echo "      completed successfully."
}


echo "[1/7] Verifying the source split that already happened..."

docker inspect openmw_builder >/dev/null

# Diagnostic TSP MUST contain V2.
docker exec openmw_builder \
    grep -aF 'TSP_TEXLIFE_V2' \
    /root/gl4es-tsp/src/gl/texture_params.c \
    >/dev/null

docker exec openmw_builder \
    grep -aF 'TSP_MAPLIFE_V2' \
    /root/openmw-0.51-tsp-src/apps/openmw/mwrender/localmap.cpp \
    >/dev/null

# Known-good TSPS MUST NOT contain V2.
if docker exec openmw_builder \
    grep -aF 'TSP_TEXLIFE_V2' \
    /root/gl4es-tsps/src/gl/texture_params.c \
    >/dev/null
then
    echo "ERROR: TSPS gl4es still contains diagnostic V2"
    exit 20
fi

if docker exec openmw_builder \
    grep -aF 'TSP_MAPLIFE_V2' \
    /root/openmw-0.51-tsps-src/apps/openmw/mwrender/localmap.cpp \
    >/dev/null
then
    echo "ERROR: TSPS OpenMW still contains diagnostic V2"
    exit 21
fi

echo "      PASS: TSP source contains diagnostics."
echo "      PASS: TSPS source is pre-diagnostic."


echo
echo "[2/7] Verifying separate gl4es rebuild scripts..."

docker exec openmw_builder bash -lc '
    test -x /root/rebuild_gl4es_tsps_o3.sh
    test -x /root/rebuild_gl4es_tsp_o3.sh

    grep -q "/root/gl4es-tsp" /root/rebuild_gl4es_tsp_o3.sh

    if grep -q "/root/gl4es-tsps" /root/rebuild_gl4es_tsp_o3.sh; then
        echo "ERROR: TSP rebuild script still references TSPS"
        exit 1
    fi
'

echo "      PASS: gl4es build scripts are separated."


echo
echo "[3/7] Removing only the BROKEN copied TSPS CMake build..."

docker exec openmw_builder bash -lc "
    set -e

    if [ -d /root/openmw-0.51-tsps-build ]; then
        mv \
            /root/openmw-0.51-tsps-build \
            /root/openmw-0.51-tsps-build.failed-$STAMP
    fi

    mkdir -p /root/openmw-0.51-tsps-build
"

echo "      old failed build preserved as:"
echo "      /root/openmw-0.51-tsps-build.failed-$STAMP"


echo
echo "[4/7] Configuring a CLEAN TSPS build from the working TSP cache..."

docker exec openmw_builder \
    python3 - <<'PY' >>"$LOG" 2>&1
from pathlib import Path
import re
import subprocess

old_src = "/root/openmw-0.51-tsp-src"
old_build = "/root/openmw-0.51-tsp-build"

new_src = "/root/openmw-0.51-tsps-src"
new_build = "/root/openmw-0.51-tsps-build"

cache = Path(old_build) / "CMakeCache.txt"

if not cache.is_file():
    raise SystemExit("ERROR: working TSP CMakeCache.txt is missing")

generator = None
generator_platform = None
generator_toolset = None

args = []

allowed_types = {
    "BOOL",
    "STRING",
    "PATH",
    "FILEPATH",
}

skip_exact = {
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

for raw in cache.read_text(errors="replace").splitlines():
    if not raw or raw.startswith("//") or raw.startswith("#"):
        continue

    m = re.match(r"([^:=]+):([^=]+)=(.*)", raw)

    if not m:
        continue

    key, typ, value = m.groups()

    if key == "CMAKE_GENERATOR":
        generator = value
        continue

    if key == "CMAKE_GENERATOR_PLATFORM":
        generator_platform = value
        continue

    if key == "CMAKE_GENERATOR_TOOLSET":
        generator_toolset = value
        continue

    if typ not in allowed_types:
        continue

    if key in skip_exact:
        continue

    # These are generated identities, not user configuration.
    if key.endswith("_SOURCE_DIR"):
        continue

    if key.endswith("_BINARY_DIR"):
        continue

    value = value.replace(old_src, new_src)
    value = value.replace(old_build, new_build)

    args.append(f"-D{key}:{typ}={value}")


cmd = [
    "cmake",
    "-S", new_src,
    "-B", new_build,
]

if generator:
    cmd += ["-G", generator]

if generator_platform:
    cmd += ["-A", generator_platform]

if generator_toolset:
    cmd += ["-T", generator_toolset]

cmd += args

print("Generator:", generator)
print("Cache options copied:", len(args))
print("Source:", new_src)
print("Build:", new_build)
print()
print("Running clean CMake configure...")
print()

subprocess.run(cmd, check=True)
PY

echo "      clean configuration completed."


echo
echo "[5/7] Building known-good TSPS OpenMW..."

run_live \
    "BUILDING TSPS OPENMW" \
    docker exec openmw_builder bash -lc '
        cmake --build \
            /root/openmw-0.51-tsps-build \
            --target openmw \
            -j2
    '


echo
echo "[6/7] Building known-good TSPS gl4es..."

run_live \
    "BUILDING TSPS GL4ES" \
    docker exec openmw_builder bash -lc '
        /root/rebuild_gl4es_tsps_o3.sh
    '


echo
echo "[7/7] Verifying and exporting known-good branch..."

docker cp \
    openmw_builder:/root/gl4es-tsps/lib/libGL.so.1 \
    "$TSPS_GL_OUT"

TSPS_OMW_BIN="$(
    docker exec openmw_builder bash -lc '
        find /root/openmw-0.51-tsps-build \
            -type f \
            -name openmw \
            -perm -111 \
            -print \
        | head -n 1
    ' | tr -d '\r'
)"

[ -n "$TSPS_OMW_BIN" ] || {
    echo "ERROR: TSPS OpenMW build output not found"
    exit 30
}

docker cp \
    "openmw_builder:$TSPS_OMW_BIN" \
    "$TSPS_OMW_OUT"

chmod +x "$TSPS_OMW_OUT"


# Known-good outputs must NOT contain diagnostic V2 markers.

if grep -aF 'TSP_TEXLIFE_V2' "$TSPS_GL_OUT" >/dev/null; then
    echo "ERROR: known-good TSPS libGL contains diagnostic marker"
    exit 31
fi

if grep -aF 'TSP_MAPLIFE_V2' "$TSPS_OMW_OUT" >/dev/null; then
    echo "ERROR: known-good TSPS OpenMW contains diagnostic marker"
    exit 32
fi


echo
echo "============================================================"
echo "PASS: TSP / TSPS SPLIT IS REPAIRED"
echo "============================================================"
echo
echo "KNOWN-GOOD TSPS:"
echo "  /root/gl4es-tsps"
echo "  /root/rebuild_gl4es_tsps_o3.sh"
echo "  /root/openmw-0.51-tsps-src"
echo "  /root/openmw-0.51-tsps-build"
echo
echo "DIAGNOSTIC TSP:"
echo "  /root/gl4es-tsp"
echo "  /root/rebuild_gl4es_tsp_o3.sh"
echo "  /root/openmw-0.51-tsp-src"
echo "  /root/openmw-0.51-tsp-build"
echo
echo "Known-good exports:"
echo "  $TSPS_GL_OUT"
echo "  $TSPS_OMW_OUT"
echo
echo "SHA256:"
sha256sum \
    "$TSPS_GL_OUT" \
    "$TSPS_OMW_OUT"
echo
echo "Full log:"
echo "  $LOG"
echo "============================================================"
