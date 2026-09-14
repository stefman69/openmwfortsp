#!/usr/bin/env bash

# Export the OpenMW 0.51 ARM64 binary and its recursive shared-library
# dependency closure from the Ubuntu/Docker build environment.
#
# Run this INSIDE the openmw_builder container.
#
# Output:
#   /root/openmw-0.51-runtime-export/
#   /root/openmw-0.51-runtime-aarch64.tar.gz
#
# The active runtime libraries go in:
#   runtime-0.51/lib/
#
# Core OS and graphics-stack libraries are copied separately into:
#   review-system-libs/
#
# They are intentionally NOT placed in runtime-0.51/lib because overriding
# CrossMix's glibc, EGL/GLES, DRM, X11, or Wayland stack can prevent booting.

set -Eeuo pipefail

OPENMW_BIN="${OPENMW_BIN:-/root/openmw-0.51-tsp-package/bin/openmw-0.51}"
EXPORT_ROOT="${EXPORT_ROOT:-/root/openmw-0.51-runtime-export}"
RUNTIME_DIR="$EXPORT_ROOT/runtime-0.51"
BIN_DIR="$RUNTIME_DIR/bin"
LIB_DIR="$RUNTIME_DIR/lib"
REVIEW_DIR="$EXPORT_ROOT/review-system-libs"
REPORT_DIR="$EXPORT_ROOT/reports"
ARCHIVE="${ARCHIVE:-/root/openmw-0.51-runtime-aarch64.tar.gz}"

# Known build prefixes used for this OpenMW 0.51 build.
KNOWN_LIB_DIRS=(
    "/root/openmw-0.51-tsp-package/lib"
    "/root/mygui-3.4.3-openmw051-gcc13-build/lib"
    "/root/sdl2-2.30.12-install/lib"
    "/usr/local/lib"
    "/usr/local/lib/aarch64-linux-gnu"
    "/usr/lib/aarch64-linux-gnu"
    "/lib/aarch64-linux-gnu"
    "/usr/lib/gcc/aarch64-linux-gnu/13"
)

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

command -v ldd >/dev/null 2>&1 || fail "ldd was not found."
command -v readelf >/dev/null 2>&1 || fail "readelf was not found."
command -v tar >/dev/null 2>&1 || fail "tar was not found."
[ -f "$OPENMW_BIN" ] || fail "OpenMW binary was not found: $OPENMW_BIN"

rm -rf "$EXPORT_ROOT"
rm -f "$ARCHIVE"

mkdir -p \
    "$BIN_DIR" \
    "$LIB_DIR" \
    "$REVIEW_DIR" \
    "$REPORT_DIR"

# Build a deterministic library search path.
SEARCH_LD_LIBRARY_PATH=""
for directory in "${KNOWN_LIB_DIRS[@]}"; do
    if [ -d "$directory" ]; then
        if [ -z "$SEARCH_LD_LIBRARY_PATH" ]; then
            SEARCH_LD_LIBRARY_PATH="$directory"
        else
            SEARCH_LD_LIBRARY_PATH="$SEARCH_LD_LIBRARY_PATH:$directory"
        fi
    fi
done

export LD_LIBRARY_PATH="$SEARCH_LD_LIBRARY_PATH${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

echo "=========================================="
echo "OpenMW 0.51 ARM64 runtime export"
echo "=========================================="
echo "Binary: $OPENMW_BIN"
echo "Export root: $EXPORT_ROOT"
echo "Archive: $ARCHIVE"
echo "LD_LIBRARY_PATH: $LD_LIBRARY_PATH"
echo "=========================================="

# Rename the executable to "openmw" so the existing gptokeyb2 profile and
# process-name matching from the working 0.48 launcher remain valid.
cp -a "$OPENMW_BIN" "$BIN_DIR/openmw"
chmod +x "$BIN_DIR/openmw"

# Libraries in this category are target-platform components. Copying Ubuntu's
# versions into LD_LIBRARY_PATH can override CrossMix and break graphics,
# input, audio, or the dynamic loader. They are retained for inspection only.
is_review_only_library() {
    local name="$1"

    case "$name" in
        ld-linux-aarch64.so.*|\
        libc.so.*|\
        libm.so.*|\
        libpthread.so.*|\
        libdl.so.*|\
        librt.so.*|\
        libresolv.so.*|\
        libutil.so.*|\
        libnss_*.so.*|\
        libanl.so.*|\
        libEGL.so*|\
        libGLES*.so*|\
        libGL.so*|\
        libGLX.so*|\
        libOpenGL.so*|\
        libglapi.so*|\
        libdrm.so*|\
        libdrm_*.so*|\
        libgbm.so*|\
        libvulkan.so*|\
        libwayland-*.so*|\
        libxkbcommon.so*|\
        libX11.so*|\
        libX11-xcb.so*|\
        libXau.so*|\
        libXdmcp.so*|\
        libXext.so*|\
        libXfixes.so*|\
        libXi.so*|\
        libXrandr.so*|\
        libXrender.so*|\
        libXcursor.so*|\
        libXinerama.so*|\
        libxcb.so*|\
        libxcb-*.so*|\
        libudev.so*|\
        libasound.so*|\
        libpulse.so*|\
        libpulsecommon-*.so*|\
        libjack.so*)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

copy_library_with_links() {
    local source_path="$1"
    local destination="$2"
    local real_path
    local source_name
    local real_name
    local soname

    [ -e "$source_path" ] || return 0

    real_path="$(readlink -f "$source_path")"
    [ -f "$real_path" ] || return 0

    source_name="$(basename "$source_path")"
    real_name="$(basename "$real_path")"

    cp -a "$real_path" "$destination/$real_name"

    if [ "$source_name" != "$real_name" ]; then
        ln -sfn "$real_name" "$destination/$source_name"
    fi

    soname="$(
        readelf -d "$real_path" 2>/dev/null \
            | sed -n 's/.*(SONAME).*Shared library: \[\(.*\)\].*/\1/p' \
            | head -n 1
    )"

    if [ -n "$soname" ] && [ "$soname" != "$real_name" ]; then
        ln -sfn "$real_name" "$destination/$soname"
    fi
}

declare -a QUEUE=()
declare -A QUEUED=()
declare -A SCANNED=()
declare -A ACTIVE_PATHS=()
declare -A REVIEW_PATHS=()
declare -A MISSING_NAMES=()

queue_file() {
    local item="$1"
    local real_item

    [ -e "$item" ] || return 0
    real_item="$(readlink -f "$item")"
    [ -f "$real_item" ] || return 0

    if [ -z "${QUEUED[$real_item]+x}" ]; then
        QUEUED["$real_item"]=1
        QUEUE+=("$real_item")
    fi
}

record_and_queue_library() {
    local library_path="$1"
    local real_path
    local name

    [ -e "$library_path" ] || return 0
    real_path="$(readlink -f "$library_path")"
    [ -f "$real_path" ] || return 0
    name="$(basename "$library_path")"

    if is_review_only_library "$name"; then
        copy_library_with_links "$library_path" "$REVIEW_DIR"
        REVIEW_PATHS["$real_path"]=1
    else
        copy_library_with_links "$library_path" "$LIB_DIR"
        ACTIVE_PATHS["$real_path"]=1
    fi

    queue_file "$real_path"
}

# Seed exact libraries that are critical to this build, even if ldd resolves
# a same-SONAME system copy first.
FORCED_LIBRARIES=(
    "/root/mygui-3.4.3-openmw051-gcc13-build/lib/libMyGUIEngine.so.3.4.3"
    "/root/sdl2-2.30.12-install/lib/libSDL2-2.0.so.0"
    "/root/openmw-0.51-tsp-package/lib/libMyGUIEngine.so.3.4.3"
)

for forced in "${FORCED_LIBRARIES[@]}"; do
    if [ -e "$forced" ]; then
        echo "Forced library: $forced"
        record_and_queue_library "$forced"
    fi
done

# Explicitly locate GCC 13 runtime libraries.
for pattern in \
    "/usr/lib/aarch64-linux-gnu/libstdc++.so.6" \
    "/lib/aarch64-linux-gnu/libgcc_s.so.1" \
    "/usr/lib/gcc/aarch64-linux-gnu/13/libstdc++.so.6" \
    "/usr/lib/gcc/aarch64-linux-gnu/13/libgcc_s.so.1"
do
    if [ -e "$pattern" ]; then
        record_and_queue_library "$pattern"
    fi
done

queue_file "$OPENMW_BIN"

LDD_REPORT="$REPORT_DIR/ldd-recursive.txt"
: > "$LDD_REPORT"

queue_index=0

while [ "$queue_index" -lt "${#QUEUE[@]}" ]; do
    current="${QUEUE[$queue_index]}"
    queue_index=$((queue_index + 1))

    if [ -n "${SCANNED[$current]+x}" ]; then
        continue
    fi
    SCANNED["$current"]=1

    echo "" >> "$LDD_REPORT"
    echo "### $current" >> "$LDD_REPORT"

    mapfile -t ldd_lines < <(
        LD_LIBRARY_PATH="$LD_LIBRARY_PATH" ldd "$current" 2>&1 || true
    )

    printf '%s\n' "${ldd_lines[@]}" >> "$LDD_REPORT"

    for line in "${ldd_lines[@]}"; do
        if [[ "$line" =~ ^[[:space:]]*([^[:space:]]+)[[:space:]]*=\>[[:space:]]*not[[:space:]]found ]]; then
            missing_name="${BASH_REMATCH[1]}"
            MISSING_NAMES["$missing_name"]=1
            continue
        fi

        library_path=""

        if [[ "$line" =~ =\>[[:space:]]*(/[^[:space:]]+) ]]; then
            library_path="${BASH_REMATCH[1]}"
        elif [[ "$line" =~ ^[[:space:]]*(/[^[:space:]]+) ]]; then
            library_path="${BASH_REMATCH[1]}"
        fi

        if [ -n "$library_path" ] && [ -e "$library_path" ]; then
            record_and_queue_library "$library_path"
        fi
    done
done

# Copy the complete matching OSG plugin directory and scan every plugin too.
OSG_PLUGIN_SOURCE=""

for candidate in \
    "/usr/local/lib/osgPlugins-3.6.5" \
    "/usr/local/lib/aarch64-linux-gnu/osgPlugins-3.6.5" \
    "/root/openmw-0.51-tsp-package/lib/osgPlugins-3.6.5"
do
    if [ -d "$candidate" ]; then
        OSG_PLUGIN_SOURCE="$candidate"
        break
    fi
done

if [ -n "$OSG_PLUGIN_SOURCE" ]; then
    echo "Copying OSG plugins from: $OSG_PLUGIN_SOURCE"
    mkdir -p "$LIB_DIR/osgPlugins-3.6.5"
    cp -a "$OSG_PLUGIN_SOURCE"/. "$LIB_DIR/osgPlugins-3.6.5/"

    while IFS= read -r -d '' plugin; do
        queue_file "$plugin"
    done < <(
        find "$OSG_PLUGIN_SOURCE" -type f \
            \( -name '*.so' -o -name '*.so.*' \) -print0
    )

    # Scan dependencies introduced by plugins.
    while [ "$queue_index" -lt "${#QUEUE[@]}" ]; do
        current="${QUEUE[$queue_index]}"
        queue_index=$((queue_index + 1))

        if [ -n "${SCANNED[$current]+x}" ]; then
            continue
        fi
        SCANNED["$current"]=1

        echo "" >> "$LDD_REPORT"
        echo "### $current" >> "$LDD_REPORT"

        mapfile -t ldd_lines < <(
            LD_LIBRARY_PATH="$LD_LIBRARY_PATH" ldd "$current" 2>&1 || true
        )

        printf '%s\n' "${ldd_lines[@]}" >> "$LDD_REPORT"

        for line in "${ldd_lines[@]}"; do
            if [[ "$line" =~ ^[[:space:]]*([^[:space:]]+)[[:space:]]*=\>[[:space:]]*not[[:space:]]found ]]; then
                missing_name="${BASH_REMATCH[1]}"
                MISSING_NAMES["$missing_name"]=1
                continue
            fi

            library_path=""

            if [[ "$line" =~ =\>[[:space:]]*(/[^[:space:]]+) ]]; then
                library_path="${BASH_REMATCH[1]}"
            elif [[ "$line" =~ ^[[:space:]]*(/[^[:space:]]+) ]]; then
                library_path="${BASH_REMATCH[1]}"
            fi

            if [ -n "$library_path" ] && [ -e "$library_path" ]; then
                record_and_queue_library "$library_path"
            fi
        done
    done
else
    echo "WARNING: No osgPlugins-3.6.5 directory was found."
fi

# Reports
{
    echo "OpenMW binary:"
    file "$BIN_DIR/openmw" || true
    echo
    echo "ELF interpreter:"
    readelf -l "$BIN_DIR/openmw" 2>/dev/null \
        | grep 'Requesting program interpreter' || true
    echo
    echo "Direct NEEDED entries:"
    readelf -d "$BIN_DIR/openmw" 2>/dev/null \
        | grep '(NEEDED)' || true
} > "$REPORT_DIR/openmw-binary.txt"

find "$LIB_DIR" -maxdepth 1 -mindepth 1 -printf '%f\n' \
    | sort > "$REPORT_DIR/active-runtime-libs.txt"

find "$REVIEW_DIR" -maxdepth 1 -mindepth 1 -printf '%f\n' \
    | sort > "$REPORT_DIR/review-only-system-libs.txt"

: > "$REPORT_DIR/unresolved-libs.txt"
if [ "${#MISSING_NAMES[@]}" -gt 0 ]; then
    printf '%s\n' "${!MISSING_NAMES[@]}" \
        | sort > "$REPORT_DIR/unresolved-libs.txt"
fi

# Record maximum GLIBC and GLIBCXX requirements visible in the runtime.
{
    echo "Symbol-version requirements found in binary and active libraries:"
    echo
    find "$BIN_DIR" "$LIB_DIR" -type f -print0 \
        | xargs -0 strings 2>/dev/null \
        | grep -E '^(GLIBC|GLIBCXX|CXXABI)_[0-9]' \
        | sort -Vu || true
} > "$REPORT_DIR/symbol-version-requirements.txt"

cat > "$EXPORT_ROOT/README.txt" <<'EOF_README'
OpenMW 0.51 ARM64 runtime export
================================

Copy this folder to the SD card:

    runtime-0.51/

Expected destination:

    /mnt/SDCARD/data/ports/openmw/runtime-0.51/

The executable has been renamed to:

    runtime-0.51/bin/openmw

Application libraries are in:

    runtime-0.51/lib/

Core OS and graphics-stack libraries are intentionally NOT active. They are
stored in review-system-libs/ because Ubuntu's glibc, EGL/GLES, DRM, X11,
Wayland, ALSA, and PulseAudio libraries should not override CrossMix.

Review reports/unresolved-libs.txt before copying the runtime.
EOF_README

tar -C "$EXPORT_ROOT" -czf "$ARCHIVE" \
    runtime-0.51 \
    review-system-libs \
    reports \
    README.txt

echo ""
echo "=========================================="
echo "Export complete"
echo "=========================================="
echo "Runtime folder:"
echo "  $RUNTIME_DIR"
echo
echo "Archive:"
echo "  $ARCHIVE"
echo
echo "Active library count:"
find "$LIB_DIR" -maxdepth 1 -type f | wc -l
echo
echo "Review-only library count:"
find "$REVIEW_DIR" -maxdepth 1 -type f | wc -l
echo

if [ -s "$REPORT_DIR/unresolved-libs.txt" ]; then
    echo "WARNING: unresolved libraries were found:"
    cat "$REPORT_DIR/unresolved-libs.txt"
    echo
    echo "See:"
    echo "  $REPORT_DIR/unresolved-libs.txt"
else
    echo "No unresolved recursive dependencies were reported by ldd."
fi

echo ""
echo "From the normal Ubuntu host, copy the archive out with:"
echo
echo "  docker cp openmw_builder:$ARCHIVE ."
echo
echo "Then extract openmw-0.51-runtime-aarch64.tar.gz and copy"
echo "runtime-0.51 to the SD card."
