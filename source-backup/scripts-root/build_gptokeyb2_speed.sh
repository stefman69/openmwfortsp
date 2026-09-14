#!/bin/bash
set -euo pipefail

SRC_DIR="/root/gptokeyb2-speed-src"
BUILD_DIR="/root/gptokeyb2-speed-build"
OUTPUT="/root/gptokeyb2_speed.aarch64"
INTERPOSE_OUTPUT="/root/libinterpose.so"

echo "=========================================="
echo "Building custom gptokeyb2 speed mapper"
echo "=========================================="
echo "Host architecture: $(uname -m)"

apt-get update

if [ "$(uname -m)" = "aarch64" ]; then
    apt-get install -y --no-install-recommends \
        build-essential \
        cmake \
        git \
        pkg-config \
        python3 \
        libsdl2-dev \
        libevdev-dev

    TOOLCHAIN_ARGS=()
else
    dpkg --add-architecture arm64
    apt-get update

    apt-get install -y --no-install-recommends \
        cmake \
        git \
        make \
        pkg-config \
        python3 \
        gcc-aarch64-linux-gnu \
        g++-aarch64-linux-gnu \
        libc6-dev-arm64-cross \
        libsdl2-dev:arm64 \
        libevdev-dev:arm64

    TOOLCHAIN_ARGS=(
        "-DCMAKE_TOOLCHAIN_FILE=$SRC_DIR/cmake/toolchains/debian-arm64-gcc-toolchain.cmake"
    )

    export PKG_CONFIG_LIBDIR="/usr/lib/aarch64-linux-gnu/pkgconfig:/usr/share/pkgconfig"
    export PKG_CONFIG_PATH="/usr/lib/aarch64-linux-gnu/pkgconfig"
fi

rm -rf "$SRC_DIR" "$BUILD_DIR" "$OUTPUT" "$INTERPOSE_OUTPUT"

git clone --depth 1 \
    https://github.com/PortsMaster/gptokeyb2.git \
    "$SRC_DIR"

python3 - "$SRC_DIR" <<'PY'
from pathlib import Path
import re
import sys

root = Path(sys.argv[1])
header = root / "src" / "gptokeyb2.h"
config = root / "src" / "config.c"
state = root / "src" / "state.c"

def replace_once(path: Path, pattern: str, replacement: str) -> None:
    text = path.read_text(encoding="utf-8")
    updated, count = re.subn(
        pattern,
        replacement,
        text,
        count=1,
        flags=re.MULTILINE | re.DOTALL,
    )
    if count != 1:
        raise RuntimeError(
            f"Patch failed for {path}: pattern matched {count} times:\n{pattern}"
        )
    with open(path, "w", encoding="utf-8", newline="\n") as handle:
        handle.write(updated)

replace_once(
    header,
    r"(SPC_MOUSE_SLOW,\s*)(SPC_ADD_LETTER,)",
    r"\1SPC_MOUSE_SPEED_DOWN,\n    SPC_MOUSE_SPEED_UP,\n    \2",
)

replace_once(
    config,
    r'("mouse_slow",\s*)("add_letter",)',
    r'\1"mouse_speed_down",\n    "mouse_speed_up",\n    \2',
)

speed_handler = r'''
    else if (button->action == ACT_SPECIAL &&
             (button->special == SPC_MOUSE_SPEED_DOWN ||
              button->special == SPC_MOUSE_SPEED_UP))
    {
        static const int mouse_speed_scale[5] = { 2, 4, 6, 8, 10 };
        static int mouse_speed_level = 2;

        if (button->special == SPC_MOUSE_SPEED_DOWN)
        {
            if (mouse_speed_level > 0)
                mouse_speed_level--;
        }
        else
        {
            if (mouse_speed_level < 4)
                mouse_speed_level++;
        }

        current_state.deadzone_scale =
            mouse_speed_scale[mouse_speed_level];

        printf(
            "MOUSE_SPEED level=%d/5 percent=%d scale=%d\\n",
            mouse_speed_level + 1,
            (mouse_speed_level + 1) * 20,
            current_state.deadzone_scale
        );
        fflush(stdout);
    }
'''

replace_once(
    state,
    r"(\s*else if \(button->action == ACT_SPECIAL && "
    r"button->special >= SPC_ADD_LETTER\))",
    speed_handler + r"\1",
)

print("Custom speed actions added:")
print("  mouse_speed_down")
print("  mouse_speed_up")
PY

cmake \
    -S "$SRC_DIR" \
    -B "$BUILD_DIR" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_FLAGS="-Wno-error=unused-result" \
    "${TOOLCHAIN_ARGS[@]}"

cmake --build "$BUILD_DIR" --parallel "$(nproc)"

if [ ! -f "$BUILD_DIR/gptokeyb2" ]; then
    echo "ERROR: Build completed but gptokeyb2 was not found."
    exit 1
fi

cp -f "$BUILD_DIR/gptokeyb2" "$OUTPUT"

if [ ! -f "$BUILD_DIR/lib/libinterpose.so" ]; then
    echo "ERROR: Build completed but libinterpose.so was not found."
    exit 1
fi

cp -f "$BUILD_DIR/lib/libinterpose.so" "$INTERPOSE_OUTPUT"

if command -v aarch64-linux-gnu-strip >/dev/null 2>&1; then
    aarch64-linux-gnu-strip "$OUTPUT"
    aarch64-linux-gnu-strip "$INTERPOSE_OUTPUT"
else
    strip "$OUTPUT"
    strip "$INTERPOSE_OUTPUT"
fi

chmod +x "$OUTPUT"
chmod 644 "$INTERPOSE_OUTPUT"

echo ""
echo "=========================================="
echo "Custom mapper created"
echo "=========================================="
file "$OUTPUT"
file "$INTERPOSE_OUTPUT"
echo ""
echo "Created:"
echo "$OUTPUT"
echo "$INTERPOSE_OUTPUT"
echo ""
echo "Both files must be copied into the OpenMW game directory."
echo "Expected architecture: ARM aarch64"
