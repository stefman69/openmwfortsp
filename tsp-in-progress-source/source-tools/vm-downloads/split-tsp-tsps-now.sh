#!/usr/bin/env bash

# Child script only. "set -e" cannot poison/close the interactive shell.
set -Eeuo pipefail

D=/home/bob-simpson/Downloads
PRE="$D/tsp-maptex-live-pre-v2-20260919-053704.tar.gz"
LOG="$D/tsp-tsps-split.log"

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
    echo "Last 60 lines:"
    tail -n 60 "$LOG" 2>/dev/null || true
    exit "$rc"
}

trap fail ERR

run_live()
{
    title="$1"
    shift

    echo
    echo "============================================================"
    echo "$title"
    echo "============================================================"

    # tee shows the real command output live AND records it.
    "$@" 2>&1 | tee -a "$LOG"
}


echo "[1/9] Checking current diagnostic source..."

test -s "$PRE"

docker inspect openmw_builder >/dev/null

docker exec openmw_builder \
    grep -aF 'TSP_TEXLIFE_V2' \
    /root/gl4es-tsps/src/gl/texture_params.c \
    >/dev/null

docker exec openmw_builder \
    grep -aF 'TSP_MAPLIFE_V2' \
    /root/openmw-0.51-tsp-src/apps/openmw/mwrender/localmap.cpp \
    >/dev/null

echo "      Current gl4es = diagnostic V2"
echo "      Current OpenMW = diagnostic V2"


echo
echo "[2/9] Saving current diagnostic source files..."

STAMP="$(date +%Y%m%d-%H%M%S)"

docker exec openmw_builder bash -lc "
    cd /root

    tar -czf /tmp/tsp-diag-source-$STAMP.tar.gz \
        gl4es-tsps/src/gl/texture.h \
        gl4es-tsps/src/gl/texture_params.c \
        gl4es-tsps/src/gl/texture.c \
        gl4es-tsps/src/gl/framebuffers.c \
        openmw-0.51-tsp-src/apps/openmw/mwrender/localmap.cpp
"

docker cp \
    "openmw_builder:/tmp/tsp-diag-source-$STAMP.tar.gz" \
    "$D/tsp-diag-source-$STAMP.tar.gz"

echo "      saved: $D/tsp-diag-source-$STAMP.tar.gz"


echo
echo "[3/9] Copying current diagnostic gl4es to /root/gl4es-tsp..."

docker exec openmw_builder bash -lc "
    set -e

    if [ -e /root/gl4es-tsp ]; then
        mv \
            /root/gl4es-tsp \
            /root/gl4es-tsp.before-$STAMP
    fi

    cp -a \
        /root/gl4es-tsps \
        /root/gl4es-tsp
"

echo "      diagnostic gl4es preserved."


echo
echo "[4/9] Creating known-good TSPS OpenMW source copy..."

docker exec openmw_builder bash -lc "
    set -e

    if [ -e /root/openmw-0.51-tsps-src ]; then
        mv \
            /root/openmw-0.51-tsps-src \
            /root/openmw-0.51-tsps-src.before-$STAMP
    fi

    cp -a \
        /root/openmw-0.51-tsp-src \
        /root/openmw-0.51-tsps-src
"

echo "      source copy complete."


echo
echo "[5/9] Restoring exact pre-V2 files on TSPS side..."

docker cp \
    "$PRE" \
    openmw_builder:/root/tsp-live-pre-v2.tar.gz

docker exec openmw_builder bash -lc "
    set -e

    R=/root/tsp-live-pre-v2

    rm -rf \"\$R\"
    mkdir -p \"\$R\"

    tar -xzf \
        /root/tsp-live-pre-v2.tar.gz \
        -C \"\$R\"

    cp -a \
        \"\$R/gl4es-tsps/src/gl/texture.h\" \
        /root/gl4es-tsps/src/gl/texture.h

    cp -a \
        \"\$R/gl4es-tsps/src/gl/texture_params.c\" \
        /root/gl4es-tsps/src/gl/texture_params.c

    cp -a \
        \"\$R/gl4es-tsps/src/gl/texture.c\" \
        /root/gl4es-tsps/src/gl/texture.c

    cp -a \
        \"\$R/gl4es-tsps/src/gl/framebuffers.c\" \
        /root/gl4es-tsps/src/gl/framebuffers.c

    cp -a \
        \"\$R/openmw-0.51-tsp-src/apps/openmw/mwrender/localmap.cpp\" \
        /root/openmw-0.51-tsps-src/apps/openmw/mwrender/localmap.cpp
"

echo "      TSPS source restored to exact 05:37 pre-V2 state."


echo
echo "[6/9] Creating separate TSP gl4es rebuild script..."

docker exec openmw_builder python3 - <<'PY'
from pathlib import Path

src = Path("/root/rebuild_gl4es_tsps_o3.sh")
dst = Path("/root/rebuild_gl4es_tsp_o3.sh")

s = src.read_text()

if "gl4es-tsps" not in s:
    raise SystemExit("ERROR: gl4es-tsps string not found in rebuild script")

s = s.replace("gl4es-tsps", "gl4es-tsp")

dst.write_text(s)
dst.chmod(0o755)

print("TSPS builder:", src)
print("TSP builder: ", dst)
PY


echo
echo "[7/9] Creating independent TSPS OpenMW build tree..."

docker exec openmw_builder bash -lc "
    set -e

    if [ -e /root/openmw-0.51-tsps-build ]; then
        mv \
            /root/openmw-0.51-tsps-build \
            /root/openmw-0.51-tsps-build.before-$STAMP
    fi

    cp -a \
        /root/openmw-0.51-tsp-build \
        /root/openmw-0.51-tsps-build
"

echo "      build tree copied."

docker exec openmw_builder python3 - <<'PY'
from pathlib import Path

root = Path("/root/openmw-0.51-tsps-build")

old_src = "/root/openmw-0.51-tsp-src"
new_src = "/root/openmw-0.51-tsps-src"

old_build = "/root/openmw-0.51-tsp-build"
new_build = "/root/openmw-0.51-tsps-build"

changed = 0

for p in root.rglob("*"):
    if not p.is_file():
        continue

    try:
        if p.stat().st_size > 16 * 1024 * 1024:
            continue

        data = p.read_bytes()
    except OSError:
        continue

    if b"\0" in data:
        continue

    s = data.decode("utf-8", errors="ignore")

    n = s.replace(old_src, new_src)
    n = n.replace(old_build, new_build)

    if n != s:
        p.write_text(n)
        changed += 1

print("Repointed build metadata files:", changed)
PY

run_live \
    "Regenerating TSPS OpenMW build files" \
    docker exec openmw_builder bash -lc '
        cmake \
          -S /root/openmw-0.51-tsps-src \
          -B /root/openmw-0.51-tsps-build
    '

# Force restored LocalMap to rebuild.
docker exec openmw_builder \
    touch \
    /root/openmw-0.51-tsps-src/apps/openmw/mwrender/localmap.cpp


echo
echo "[8/9] Rebuilding KNOWN-GOOD TSPS outputs..."
echo
echo "You will see the real build output below."

run_live \
    "BUILDING KNOWN-GOOD TSPS GL4ES" \
    docker exec openmw_builder bash -lc '
        /root/rebuild_gl4es_tsps_o3.sh
    '

run_live \
    "BUILDING KNOWN-GOOD TSPS OPENMW" \
    docker exec openmw_builder bash -lc '
        cmake --build \
          /root/openmw-0.51-tsps-build \
          --target openmw \
          -j2
    '


echo
echo "[9/9] Verifying the split..."

# TSP must contain diagnostics.
docker exec openmw_builder \
    grep -aF 'TSP_TEXLIFE_V2' \
    /root/gl4es-tsp/src/gl/texture_params.c \
    >/dev/null

docker exec openmw_builder \
    grep -aF 'TSP_MAPLIFE_V2' \
    /root/openmw-0.51-tsp-src/apps/openmw/mwrender/localmap.cpp \
    >/dev/null


# TSPS must NOT contain diagnostics.
if docker exec openmw_builder \
    grep -aF 'TSP_TEXLIFE_V2' \
    /root/gl4es-tsps/src/gl/texture_params.c \
    >/dev/null
then
    echo "ERROR: diagnostic gl4es marker still exists in TSPS"
    exit 30
fi

if docker exec openmw_builder \
    grep -aF 'TSP_MAPLIFE_V2' \
    /root/openmw-0.51-tsps-src/apps/openmw/mwrender/localmap.cpp \
    >/dev/null
then
    echo "ERROR: diagnostic OpenMW marker still exists in TSPS"
    exit 31
fi


# Export the rebuilt known-good TSPS files for safety.
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
        | head -n1
    ' | tr -d '\r'
)"

[ -n "$TSPS_OMW_BIN" ]

docker cp \
    "openmw_builder:$TSPS_OMW_BIN" \
    "$TSPS_OMW_OUT"

chmod +x "$TSPS_OMW_OUT"


echo
echo "============================================================"
echo "PASS: SOURCE / BUILD TREES ARE SPLIT"
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
echo "Known-good TSPS exports:"
echo "  $TSPS_GL_OUT"
echo "  $TSPS_OMW_OUT"
echo
echo "Hashes:"
sha256sum \
    "$TSPS_GL_OUT" \
    "$TSPS_OMW_OUT"
echo
echo "Full log:"
echo "  $LOG"
echo "============================================================"

