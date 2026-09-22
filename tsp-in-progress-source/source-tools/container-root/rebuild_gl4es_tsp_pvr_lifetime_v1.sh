#!/bin/bash
#
# rebuild_gl4es_tsps_o3.sh
#
# Rebuild the TSP-patched GL4ES translation layer at maximum safe optimization.
#
# Run INSIDE the ARM64 container:
#   sudo docker start openmw_builder
#   sudo docker exec -it openmw_builder /bin/bash
#   bash /root/rebuild_gl4es_tsps_o3.sh
#
# SAFETY GUARANTEES:
#   * Never deletes, cleans, or re-clones /root/gl4es-tsp-pvr-lifetime-v1.
#     (The old build_gl4es_tsps.sh did `rm -rf` + `git clone`, which would
#      destroy the batchsafe / clientbuf / native-FBO-scaler patches.)
#   * Uses a separate build directory, leaving build-tsps/ untouched.
#   * Backs up the currently built lib/libGL.so.1 before overwriting it.
#   * Refuses to run if the expected local patches are missing.
#
# Output:
#   /root/gl4es-tsp-pvr-lifetime-v1-export-o3/libGL.so.1
#   /root/gl4es-tsp-pvr-lifetime-v1-o3.tar.gz
#
set -Eeuo pipefail

SOURCE_DIR="/root/gl4es-tsp-pvr-lifetime-v1"
BUILD_DIR="$SOURCE_DIR/build-tsps-o3"
EXPORT_DIR="/root/gl4es-tsp-pvr-lifetime-v1-export-o3"
ARCHIVE="/root/gl4es-tsp-pvr-lifetime-v1-o3.tar.gz"
BACKUP_DIR="/root/gl4es-tsp-pvr-lifetime-v1-libbackup"

# Conservative ARM target. Cortex-A53 code runs correctly on both the
# A133P (Cortex-A53) and the newer A523 (Cortex-A55, backward compatible).
# Targeting A55 on an A53 device would SIGILL, so A53 is the safe default.
# Override with:  TSP_CPU=cortex-a55 bash rebuild_gl4es_tsps_o3.sh
TSP_CPU="${TSP_CPU:-cortex-a53}"

# Set TSP_LTO=1 to additionally enable link-time optimization.
TSP_LTO="${TSP_LTO:-0}"

JOBS="${TSP_JOBS:-$(nproc)}"

echo "=========================================="
echo "GL4ES TSP rebuild at -O3"
echo "Date:        $(date)"
echo "Arch:        $(uname -m)"
echo "Source:      $SOURCE_DIR   (NOT modified, NOT re-cloned)"
echo "Build dir:   $BUILD_DIR"
echo "CPU target:  $TSP_CPU"
echo "LTO:         $TSP_LTO"
echo "Jobs:        $JOBS"
echo "=========================================="

if [ "$(uname -m)" != "aarch64" ]; then
    echo "ERROR: must run inside the ARM64/aarch64 container."
    exit 1
fi

if [ ! -d "$SOURCE_DIR/.git" ]; then
    echo "ERROR: $SOURCE_DIR is not a git checkout. Refusing to continue."
    exit 1
fi

# --- Guard: confirm the local patches are still present -------------------
echo
echo "Verifying local TSP patches are intact before building..."

MISSING=0
for marker in \
    "TSP_GL4ES_NATIVE_MAINFBO_051_V31:src/gl/framebuffers.c" \
    "TSP_GL4ES_BATCHSAFE_20260812:src/gl/list.c" \
    "TSP_GL4ES_BATCH_CLIENTBUF_FIX_PROD_20260813:src/gl/listdraw.c"
do
    tag="${marker%%:*}"
    file="${marker#*:}"
    if grep -q "$tag" "$SOURCE_DIR/$file" 2>/dev/null; then
        echo "  OK      $tag  ($file)"
    else
        echo "  MISSING $tag  ($file)"
        MISSING=1
    fi
done

if [ "$MISSING" -ne 0 ]; then
    echo
    echo "ERROR: expected TSP patches were not found in the source tree."
    echo "Something has reset /root/gl4es-tsp-pvr-lifetime-v1. Not building."
    exit 1
fi

echo
echo "Current uncommitted changes (these are being preserved):"
git -C "$SOURCE_DIR" status --short

# --- Back up the currently built library ----------------------------------
mkdir -p "$BACKUP_DIR"

if [ -f "$SOURCE_DIR/lib/libGL.so.1" ]; then
    STAMP="$(date +%Y%m%d-%H%M%S)"
    cp -f "$(readlink -f "$SOURCE_DIR/lib/libGL.so.1")" \
        "$BACKUP_DIR/libGL.so.1.relwithdebinfo-$STAMP"
    echo
    echo "Backed up existing library to:"
    echo "  $BACKUP_DIR/libGL.so.1.relwithdebinfo-$STAMP"
fi

# --- Compose optimization flags -------------------------------------------
# -O3                        full optimization (was -O2 under RelWithDebInfo)
# -DNDEBUG                   strip asserts
# -mcpu=<target>             ARM scheduling + ISA selection
# -fno-semantic-interposition  let internal calls in the shared library bind
#                            directly instead of going through the PLT; this
#                            matters for GL4ES because its hot paths make many
#                            intra-library calls per draw
# NOTE: deliberately NOT using -ffast-math. It relaxes float semantics and can
# corrupt vertex/matrix math in a GL translation layer.
TSP_CFLAGS="-O3 -DNDEBUG -mcpu=${TSP_CPU} -fno-semantic-interposition"

if [ "$TSP_LTO" = "1" ]; then
    TSP_CFLAGS="$TSP_CFLAGS -flto=${JOBS} -ffat-lto-objects"
    echo
    echo "LTO enabled."
fi

echo
echo "C flags: $TSP_CFLAGS"

# --- Configure -------------------------------------------------------------
# Same feature options as the original TSP build. Only the optimization
# level and CPU tuning change, so behaviour should be identical.
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
echo "=========================================="
echo "Configured options"
echo "=========================================="
grep -E \
'^(ODROID|GBM|NOX11|NOEGL|GLX_STUBS|EGL_WRAPPER|DEFAULT_ES|DEFAULT_FB|USE_CLOCK|CMAKE_BUILD_TYPE|CMAKE_C_FLAGS_RELEASE):' \
    "$BUILD_DIR/CMakeCache.txt" || true

# --- Build -----------------------------------------------------------------
echo
echo "Building..."
cmake --build "$BUILD_DIR" -- -j"$JOBS"

# --- Locate the built library ---------------------------------------------
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

if [ -z "$REAL_GL" ] || [ ! -f "$REAL_GL" ]; then
    echo "ERROR: built libGL.so.1 was not found."
    find "$SOURCE_DIR/lib" "$BUILD_DIR" -name 'libGL.so*' -maxdepth 2 -ls 2>/dev/null || true
    exit 1
fi

echo
echo "Built library: $REAL_GL"

# --- Export ----------------------------------------------------------------
rm -rf "$EXPORT_DIR"
mkdir -p "$EXPORT_DIR"

cp -f "$REAL_GL" "$EXPORT_DIR/libGL.so.1"
chmod 755 "$EXPORT_DIR/libGL.so.1"

# Strip: -O3 Release has no debug info to keep, and a smaller library means
# less to fault in from the SD card at load time.
strip "$EXPORT_DIR/libGL.so.1" || true

if ! file "$EXPORT_DIR/libGL.so.1" | grep -q "ELF 64-bit.*ARM aarch64"; then
    echo "ERROR: exported library is not ARM64."
    file "$EXPORT_DIR/libGL.so.1"
    exit 1
fi

GL4ES_COMMIT="$(git -C "$SOURCE_DIR" rev-parse HEAD)"

cat > "$EXPORT_DIR/build-info.txt" << EOF
GL4ES TSP build - maximum optimization
Built:        $(date)
Base commit:  $GL4ES_COMMIT
Build type:   Release
C flags:      $TSP_CFLAGS
CPU target:   $TSP_CPU
LTO:          $TSP_LTO
Options:      ODROID=ON GBM=ON NOX11=ON NOEGL=OFF GLX_STUBS=ON
              DEFAULT_ES=2 DEFAULT_FB=2 USE_CLOCK=ON

Local patches included:
  TSP_GL4ES_NATIVE_MAINFBO_051_V31            (framebuffers.c)
  TSP_GL4ES_NATIVE_PRESENT_051_V31            (framebuffers.c)
  TSP_GL4ES_BATCHSAFE_20260812                (list.c)
  TSP_GL4ES_BATCH_CLIENTBUF_FIX_PROD_20260813 (listdraw.c)

Previous build was RelWithDebInfo (-O2 -g -DNDEBUG).
EOF

sha256sum "$EXPORT_DIR/libGL.so.1" > "$EXPORT_DIR/libGL.so.1.sha256"

tar -czf "$ARCHIVE" \
    -C "$EXPORT_DIR" \
    libGL.so.1 \
    libGL.so.1.sha256 \
    build-info.txt

echo
echo "=========================================="
echo "Done"
echo "=========================================="
ls -lh "$EXPORT_DIR/libGL.so.1"
file "$EXPORT_DIR/libGL.so.1"
echo
echo "Old library size for comparison:"
ls -lh "$BACKUP_DIR"/libGL.so.1.relwithdebinfo-* 2>/dev/null | tail -1 || echo "  (no prior backup)"
echo
cat "$EXPORT_DIR/libGL.so.1.sha256"
echo
echo "Archive: $ARCHIVE"
ls -lh "$ARCHIVE"
echo
echo "Copy out of the container with:"
echo "  sudo docker cp openmw_builder:$ARCHIVE /home/bob-simpson/downloads/"
