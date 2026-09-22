#!/usr/bin/env bash
set -Eeuo pipefail

SOURCE_DIR="/root/gl4es-tsp-pvr-texture-v2"
BUILD_DIR="$SOURCE_DIR/build-tsp-pvr-texture-v2-o3"
EXPORT_DIR="/root/gl4es-tsp-pvr-texture-v2-export-o3"
ARCHIVE="/root/gl4es-tsp-pvr-texture-v2-o3.tar.gz"

TSP_CPU="${TSP_CPU:-cortex-a53}"
JOBS="${TSP_JOBS:-2}"

echo "=========================================="
echo "GL4ES TSP PowerVR texture-v2 build"
echo "Source: $SOURCE_DIR"
echo "Build:  $BUILD_DIR"
echo "Jobs:   $JOBS (automatic -j1 retry on compiler failure)"
echo "=========================================="

[ "$(uname -m)" = "aarch64" ] || {
    echo "ERROR: this build must run in the ARM64 container"
    exit 1
}

for marker in \
    TSP_PVR_RB_LIFETIME_FIX_V1 \
    TSP_NATIVE_LIFE_DIAG_V1 \
    TSP_NATIVE_TEXTURE_DIAG_V2 \
    TSP_MAP_RTT_READBACK_V1
do
    grep -Rqs --include='*.c' --include='*.h' "$marker" "$SOURCE_DIR/src" || {
        echo "ERROR: missing source marker $marker"
        exit 2
    }
done

TSP_CFLAGS="-O3 -DNDEBUG -mcpu=${TSP_CPU} -fno-semantic-interposition"

rm -rf "$BUILD_DIR"

cmake \
    -S "$SOURCE_DIR" \
    -B "$BUILD_DIR" \
    -DODROID=ON \
    -DGBM=ON \
    -DNOX11=ON \
    -DNOEGL=OFF \
    -DGLX_STUBS=ON \
    -DEGL_WRAPPER=OFF \
    -DDEFAULT_ES=2 \
    -DDEFAULT_FB=2 \
    -DUSE_CLOCK=ON \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_FLAGS_RELEASE="$TSP_CFLAGS"

echo
echo "Building with -j$JOBS..."

if cmake --build "$BUILD_DIR" -- -j"$JOBS"; then
    :
else
    rc=$?
    echo
    echo "WARNING: parallel build failed rc=$rc"
    echo "Retrying the SAME configured build at -j1."
    echo "This avoids throwing away already compiled objects."
    cmake --build "$BUILD_DIR" -- -j1
fi

REAL_GL=""
for candidate in \
    "$SOURCE_DIR/lib/libGL.so.1" \
    "$BUILD_DIR/lib/libGL.so.1" \
    "$BUILD_DIR/libGL.so.1"
do
    if [ -e "$candidate" ]; then
        REAL_GL="$(readlink -f "$candidate")"
        break
    fi
done

[ -n "$REAL_GL" ] && [ -f "$REAL_GL" ] || {
    echo "ERROR: built libGL.so.1 not found"
    exit 3
}

rm -rf "$EXPORT_DIR"
mkdir -p "$EXPORT_DIR"

cp -f "$REAL_GL" "$EXPORT_DIR/libGL.so.1"
chmod 0755 "$EXPORT_DIR/libGL.so.1"
strip "$EXPORT_DIR/libGL.so.1" 2>/dev/null || true

file "$EXPORT_DIR/libGL.so.1" | grep -q 'ELF 64-bit.*ARM aarch64' || {
    echo "ERROR: export is not ARM64"
    file "$EXPORT_DIR/libGL.so.1"
    exit 4
}

# Runtime strings, not comment-only markers.
grep -a -q 'TSP_NATIVE_TEXTURE_DIAG_V2' "$EXPORT_DIR/libGL.so.1" || {
    echo "ERROR: runtime texture diagnostic marker missing"
    exit 5
}

grep -a -q 'TSP_MAP_RTT_READBACK_V1' "$EXPORT_DIR/libGL.so.1" || {
    echo "ERROR: runtime map readback marker missing"
    exit 6
}

sha256sum "$EXPORT_DIR/libGL.so.1" > "$EXPORT_DIR/libGL.so.1.sha256"

cat > "$EXPORT_DIR/build-info.txt" <<EOF
TSP PowerVR texture-v2 isolated gl4es build
Built: $(date)
Source: $SOURCE_DIR
C flags: $TSP_CFLAGS
Jobs requested: $JOBS
Base: previous TSP-only pvr-lifetime-v1 source tree
Diagnostics: TSP_NATIVE_TEXTURE_DIAG_V2 + TSP_MAP_RTT_READBACK_V1
EOF

tar -czf "$ARCHIVE" \
    -C "$EXPORT_DIR" \
    libGL.so.1 \
    libGL.so.1.sha256 \
    build-info.txt

echo
echo "BUILD PASS"
sha256sum "$EXPORT_DIR/libGL.so.1"
ls -lh "$EXPORT_DIR/libGL.so.1" "$ARCHIVE"
