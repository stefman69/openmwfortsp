#!/usr/bin/env bash
# Rebuild OpenMW 0.51 openmw-navmeshtool from the CURRENT Docker source/build
# tree, install it ONLY into the isolated navmesh-tool-runtime, pair it with
# the exact currently-working game defaults.bin, then perform a fully detached
# initialization test.
#
# This script does NOT build/install the game binary.
# This script does NOT generate navmesh.
# This script does NOT modify the live navmesh.db.
# The risky device-side navmeshtool test is detached from SSH/terminal.

set -u
set -o pipefail

STAMP="$(date +%Y%m%d-%H%M%S)"
CTR="${TSP_BUILDER:-openmw_builder}"
DEV="${TSP_DEV:-root@192.168.1.25}"

SRC="/root/openmw-0.51-tsp-src"
BUILD="/root/openmw-0.51-tsp-build"

ROOT="/mnt/SDCARD/data/ports/openmw51"
RUNTIME="$ROOT/navmesh-tool-runtime"
GAME_BIN="$ROOT/bin/openmw-0.51"
GAME_DEFAULTS="$ROOT/bin/defaults.bin"
MAIN_CFG="$ROOT/openmw.cfg"
USER_CFG="$ROOT/config-0.51"
V20_LUA="$ROOT/mods/TSPInteriorVisGrid/scripts/TSPInteriorVisGrid/visgrid.lua"
LIVE_DB="/mnt/UDISK/openmw51-nav/navmesh.db"

HOST_OUT="$HOME/Downloads/openmw51-current-navtool-rebuild-$STAMP"
HOST_LOG="$HOST_OUT/controller.log"
mkdir -p "$HOST_OUT"

SSH=(-o BatchMode=yes -o ConnectTimeout=7 -o ServerAliveInterval=4 -o ServerAliveCountMax=2)

exec > >(tee -a "$HOST_LOG") 2>&1

finish() {
    rc=$?
    trap - EXIT
    echo
    echo "=================================================================="
    echo "CURRENT NAVMESHTOOL REBUILD CONTROLLER FINISHED"
    echo "Controller exit code: $rc"
    echo "Your Ubuntu terminal remains independent."
    echo "Artifacts:"
    echo "  $HOST_OUT"
    echo "=================================================================="
    exit "$rc"
}
trap finish EXIT

echo "=================================================================="
echo "OPENMW 0.51 — REBUILD NAVMESHTOOL FROM CURRENT SOURCE"
echo "=================================================================="
echo "Current source:  $SRC"
echo "Current build:   $BUILD"
echo
echo "Will NOT:"
echo "  - rebuild/install the game executable"
echo "  - overwrite the game's defaults.bin"
echo "  - modify V20"
echo "  - generate navmesh"
echo "  - modify the live navmesh.db"
echo
echo "Device initialization test will run fully detached."
echo "=================================================================="

for c in docker ssh scp python3 sha256sum awk grep sed file; do
    command -v "$c" >/dev/null 2>&1 || {
        echo "ERROR: required host command missing: $c"
        exit 10
    }
done

echo
echo "===== 1/10 DEVICE + DOCKER PREFLIGHT ====="

docker inspect "$CTR" >/dev/null 2>&1 || {
    echo "ERROR: Docker container not found: $CTR"
    exit 11
}

if [ "$(docker inspect -f '{{.State.Running}}' "$CTR")" != "true" ]; then
    docker start "$CTR" >/dev/null || {
        echo "ERROR: could not start Docker container."
        exit 12
    }
fi

if ! ssh "${SSH[@]}" "$DEV" 'echo CONNECTED' >"$HOST_OUT/device-connect.txt" 2>&1; then
    echo "ERROR: cannot reach TrimUI."
    cat "$HOST_OUT/device-connect.txt" || true
    exit 13
fi

if ssh "${SSH[@]}" "$DEV" \
    'pidof openmw-0.51 >/dev/null 2>&1 || pidof openmw >/dev/null 2>&1'
then
    echo "ERROR: OpenMW game is running. Exit it normally before rebuilding/installing tooling."
    exit 14
fi

if ! ssh "${SSH[@]}" "$DEV" "
set -e
test -s '$GAME_BIN'
test -s '$GAME_DEFAULTS'
test -s '$MAIN_CFG'
test -s '$USER_CFG/openmw.cfg'
test -s '$V20_LUA'
test -s '$LIVE_DB'
mkdir -p '$RUNTIME'
" >"$HOST_OUT/device-preflight.txt" 2>&1; then
    echo "ERROR: required current runtime file is missing."
    cat "$HOST_OUT/device-preflight.txt" || true
    exit 15
fi

if ! docker exec "$CTR" bash -lc "
set -e
test -d '$SRC'
test -d '$BUILD'
test -s '$SRC/CMakeLists.txt'
test -s '$SRC/apps/navmeshtool/main.cpp'
test -s '$SRC/components/settings/categories/camera.hpp'
test -s '$BUILD/CMakeCache.txt'
" >"$HOST_OUT/docker-preflight.txt" 2>&1; then
    echo "ERROR: current OpenMW source/build tree is incomplete."
    cat "$HOST_OUT/docker-preflight.txt" || true
    exit 16
fi

echo "PASS: current source/build and device runtime are present."

echo
echo "===== 2/10 PROTECT CURRENT GAME / V20 / LIVE DB ====="

hash_remote() {
    ssh "${SSH[@]}" "$DEV" "sha256sum '$1'" 2>/dev/null | awk '{print $1}'
}

GAME_BIN_SHA="$(hash_remote "$GAME_BIN")"
GAME_DEFAULTS_SHA="$(hash_remote "$GAME_DEFAULTS")"
V20_SHA="$(hash_remote "$V20_LUA")"
LIVE_DB_SHA="$(hash_remote "$LIVE_DB")"

{
    echo "game_binary=$GAME_BIN_SHA"
    echo "game_defaults=$GAME_DEFAULTS_SHA"
    echo "v20_lua=$V20_SHA"
    echo "live_db=$LIVE_DB_SHA"
} | tee "$HOST_OUT/protected-before.txt"

echo
echo "===== 3/10 CAPTURE CURRENT SOURCE/BUILD IDENTITY ====="

docker exec "$CTR" bash -lc "
set +e
echo '----- SOURCE REVISION -----'
git -C '$SRC' rev-parse HEAD
git -C '$SRC' describe --always --dirty --tags
echo
echo '----- SOURCE DIRTY STATE -----'
git -C '$SRC' status --short
echo
echo '----- CRITICAL SOURCE HASHES -----'
sha256sum \
  '$SRC/apps/navmeshtool/main.cpp' \
  '$SRC/components/settings/categories/camera.hpp' \
  '$SRC/files/settings-default.cfg' \
  '$SRC/components/settings/settings.cpp' 2>/dev/null
echo
echo '----- CURRENT CACHE -----'
grep -E '^(BUILD_NAVMESHTOOL|CMAKE_BUILD_TYPE|CMAKE_C_COMPILER|CMAKE_CXX_COMPILER|SDL2_DIR|MyGUI_LIBRARY):' \
  '$BUILD/CMakeCache.txt' || true
" | tee "$HOST_OUT/source-build-identity.txt"

echo
echo "===== 4/10 CREATE DETACHED DOCKER BUILD WORKER ====="

WORKER_LOCAL="$HOST_OUT/rebuild-navtool.worker.sh"
WORKER_REMOTE="/root/rebuild-current-navtool-$STAMP.sh"
DOCKER_RUN="/root/current-navtool-rebuild-$STAMP"
DOCKER_LOG="$DOCKER_RUN/build.log"
DOCKER_STATUS="$DOCKER_RUN/status"
DOCKER_OUTPUT="$DOCKER_RUN/output"

cat > "$WORKER_LOCAL" <<EOF_WORKER
#!/usr/bin/env bash
set -Eeuo pipefail

SRC='$SRC'
BUILD='$BUILD'
RUN='$DOCKER_RUN'
LOG='$DOCKER_LOG'
STATUS='$DOCKER_STATUS'
OUT='$DOCKER_OUTPUT'

mkdir -p "\$RUN" "\$OUT"
rm -f "\$STATUS"

finish_worker() {
    rc=\$?
    trap - EXIT
    printf '%s\n' "\$rc" > "\$STATUS.tmp"
    mv -f "\$STATUS.tmp" "\$STATUS"
    sync
    exit "\$rc"
}
trap finish_worker EXIT

exec </dev/null >"\$LOG" 2>&1

echo "=================================================================="
echo "CURRENT OPENMW 0.51 NAVMESHTOOL BUILD"
echo "=================================================================="
date
echo "SRC=\$SRC"
echo "BUILD=\$BUILD"
echo

test -d "\$SRC"
test -d "\$BUILD"
test -s "\$BUILD/CMakeCache.txt"

cache_value() {
    local key="\$1"
    sed -n "s/^\${key}:[^=]*=//p" "\$BUILD/CMakeCache.txt" | head -1
}

C_BEFORE="\$(cache_value CMAKE_C_COMPILER)"
CXX_BEFORE="\$(cache_value CMAKE_CXX_COMPILER)"
SDL_BEFORE="\$(cache_value SDL2_DIR)"
MYGUI_BEFORE="\$(cache_value MyGUI_LIBRARY)"
TYPE_BEFORE="\$(cache_value CMAKE_BUILD_TYPE)"
NAV_BEFORE="\$(cache_value BUILD_NAVMESHTOOL)"

echo "Before reconfigure:"
echo "  BUILD_NAVMESHTOOL=\$NAV_BEFORE"
echo "  C=\$C_BEFORE"
echo "  CXX=\$CXX_BEFORE"
echo "  SDL2_DIR=\$SDL_BEFORE"
echo "  MyGUI_LIBRARY=\$MYGUI_BEFORE"
echo "  BUILD_TYPE=\$TYPE_BEFORE"

echo
echo "----- CURRENT SOURCE IDENTITY -----"
git -C "\$SRC" rev-parse HEAD 2>/dev/null || true
git -C "\$SRC" describe --always --dirty --tags 2>/dev/null || true
git -C "\$SRC" status --short 2>/dev/null || true

echo
echo "----- ENABLE NAVMESHTOOL IN EXISTING BUILD TREE -----"
if [ "\$NAV_BEFORE" != "ON" ]; then
    cmake -S "\$SRC" -B "\$BUILD" -DBUILD_NAVMESHTOOL=ON
else
    echo "BUILD_NAVMESHTOOL already ON."
fi

C_AFTER="\$(cache_value CMAKE_C_COMPILER)"
CXX_AFTER="\$(cache_value CMAKE_CXX_COMPILER)"
SDL_AFTER="\$(cache_value SDL2_DIR)"
MYGUI_AFTER="\$(cache_value MyGUI_LIBRARY)"
TYPE_AFTER="\$(cache_value CMAKE_BUILD_TYPE)"
NAV_AFTER="\$(cache_value BUILD_NAVMESHTOOL)"

echo
echo "After reconfigure:"
echo "  BUILD_NAVMESHTOOL=\$NAV_AFTER"
echo "  C=\$C_AFTER"
echo "  CXX=\$CXX_AFTER"
echo "  SDL2_DIR=\$SDL_AFTER"
echo "  MyGUI_LIBRARY=\$MYGUI_AFTER"
echo "  BUILD_TYPE=\$TYPE_AFTER"

[ "\$NAV_AFTER" = "ON" ]

compare_if_known() {
    label="\$1"
    before="\$2"
    after="\$3"
    if [ -n "\$before" ] && [ "\$before" != "\$after" ]; then
        echo "ERROR: CMake reconfigure changed \$label"
        echo "  before: \$before"
        echo "  after:  \$after"
        exit 31
    fi
}

compare_if_known "C compiler" "\$C_BEFORE" "\$C_AFTER"
compare_if_known "C++ compiler" "\$CXX_BEFORE" "\$CXX_AFTER"
compare_if_known "SDL2_DIR" "\$SDL_BEFORE" "\$SDL_AFTER"
compare_if_known "MyGUI_LIBRARY" "\$MYGUI_BEFORE" "\$MYGUI_AFTER"
compare_if_known "build type" "\$TYPE_BEFORE" "\$TYPE_AFTER"

echo
echo "----- VERIFY TARGET EXISTS -----"
TARGET_HELP="\$(cmake --build "\$BUILD" --target help 2>/dev/null || true)"
printf '%s\n' "\$TARGET_HELP" | grep -F 'openmw-navmeshtool' >/dev/null || {
    echo "ERROR: openmw-navmeshtool target was not created."
    exit 32
}
echo "PASS: target exists."

echo
echo "----- FORCE ONLY NAVMESHTOOL EXECUTABLE TO RELINK -----"
if [ -f "\$BUILD/openmw-navmeshtool" ]; then
    cp -p "\$BUILD/openmw-navmeshtool" "\$RUN/openmw-navmeshtool.before"
    sha256sum "\$RUN/openmw-navmeshtool.before"
    rm -f "\$BUILD/openmw-navmeshtool"
fi

echo
echo "----- BUILD NAVMESHTOOL ONLY, ONE JOB -----"
cmake --build "\$BUILD" --target openmw-navmeshtool --parallel 1

NAVTOOL="\$BUILD/openmw-navmeshtool"
if [ ! -x "\$NAVTOOL" ]; then
    NAVTOOL="\$(find "\$BUILD" -type f -name openmw-navmeshtool -perm -111 -print -quit 2>/dev/null)"
fi

[ -n "\${NAVTOOL:-}" ]
[ -x "\$NAVTOOL" ]

echo
echo "----- VERIFY NEW ARTIFACT -----"
file "\$NAVTOOL"
file "\$NAVTOOL" | grep -Eiq 'ELF 64-bit.*(ARM aarch64|aarch64)' || {
    echo "ERROR: rebuilt navmeshtool is not ELF64 AArch64."
    exit 33
}

sha256sum "\$NAVTOOL"
stat "\$NAVTOOL"

cp -p "\$NAVTOOL" "\$OUT/openmw-navmeshtool"
cp -p "\$SRC/files/settings-default.cfg" "\$OUT/settings-default.current-source.cfg"

{
    echo "built=\$(date)"
    echo "source_head=\$(git -C "\$SRC" rev-parse HEAD 2>/dev/null || true)"
    echo "source_describe=\$(git -C "\$SRC" describe --always --dirty --tags 2>/dev/null || true)"
    echo "navtool_sha=\$(sha256sum "\$NAVTOOL" | awk '{print \$1}')"
    echo "settings_source_sha=\$(sha256sum "\$SRC/files/settings-default.cfg" | awk '{print \$1}')"
    echo "camera_sha=\$(sha256sum "\$SRC/components/settings/categories/camera.hpp" | awk '{print \$1}')"
    echo "build_navmeshtool=\$NAV_AFTER"
    echo "c_compiler=\$C_AFTER"
    echo "cxx_compiler=\$CXX_AFTER"
} > "\$OUT/BUILD_INFO.txt"

echo
echo "BUILD SUCCESS"
cat "\$OUT/BUILD_INFO.txt"
EOF_WORKER

chmod +x "$WORKER_LOCAL"
docker cp "$WORKER_LOCAL" "$CTR:$WORKER_REMOTE" >/dev/null
docker exec "$CTR" chmod +x "$WORKER_REMOTE"

echo "Launching detached Docker build worker..."
docker exec -d "$CTR" bash "$WORKER_REMOTE"

echo "Docker build is detached from this terminal."

echo
echo "===== 5/10 POLL DETACHED BUILD STATUS ====="

BUILD_RC=""
FAILS=0
COUNT=0
LAST_BUILD_LINE=0

while :; do
    COUNT=$((COUNT + 1))

    if ! docker inspect "$CTR" >/dev/null 2>&1; then
        echo
        echo "ERROR: Docker container disappeared while build was running."
        break
    fi

    if [ "$(docker inspect -f '{{.State.Running}}' "$CTR" 2>/dev/null || echo false)" != "true" ]; then
        echo
        echo "ERROR: Docker container stopped while build was running."
        break
    fi

    POLL="$(
        docker exec "$CTR" bash -lc "
        if [ -s '$DOCKER_STATUS' ]; then
            echo STATUS
            cat '$DOCKER_STATUS'
        else
            echo RUNNING
        fi
        " 2>/dev/null
    )"
    PRC=$?

    if [ "$PRC" -eq 0 ]; then
        FAILS=0
        if [ "$(printf '%s\n' "$POLL" | sed -n '1p')" = "STATUS" ]; then
            BUILD_RC="$(printf '%s\n' "$POLL" | sed -n '2p' | tr -cd '0-9-')"
            echo
            echo "Detached Docker build returned: ${BUILD_RC:-unknown}"
            break
        fi
    else
        FAILS=$((FAILS + 1))
        if [ "$FAILS" -ge 3 ]; then
            echo
            echo "ERROR: lost contact with Docker build worker."
            break
        fi
    fi

    # Keep the build process detached from this terminal, but show
    # newly-written build.log lines so the build remains observable.
    if [ $((COUNT % 2)) -eq 0 ]; then
        CURRENT_LINES="$(
            docker exec "$CTR" sh -c "wc -l < '$DOCKER_LOG' 2>/dev/null || echo 0"                 2>/dev/null | tr -cd '0-9'
        )"

        CURRENT_LINES="${CURRENT_LINES:-0}"

        if [ "$CURRENT_LINES" -gt "$LAST_BUILD_LINE" ] 2>/dev/null; then
            FIRST_NEW=$((LAST_BUILD_LINE + 1))

            echo
            echo "----- detached build progress -----"

            docker exec "$CTR" sh -c                 "sed -n '${FIRST_NEW},${CURRENT_LINES}p' '$DOCKER_LOG'"                 2>/dev/null || true

            LAST_BUILD_LINE="$CURRENT_LINES"
        fi
    fi

    sleep 2
done
echo

docker cp "$CTR:$DOCKER_LOG" "$HOST_OUT/build.log" >/dev/null 2>&1 || true

if [ -s "$HOST_OUT/build.log" ]; then
    echo
    echo "----- BUILD LOG TAIL -----"
    tail -180 "$HOST_OUT/build.log" || true
fi

if [ -z "$BUILD_RC" ] || [ "$BUILD_RC" != "0" ]; then
    echo "ERROR: current navmeshtool build failed or produced no status."
    echo "Build log: $HOST_OUT/build.log"
    exit 40
fi

mkdir -p "$HOST_OUT/output"
docker cp "$CTR:$DOCKER_OUTPUT/." "$HOST_OUT/output/" >/dev/null

NEW_TOOL="$HOST_OUT/output/openmw-navmeshtool"
SOURCE_DEFAULTS="$HOST_OUT/output/settings-default.current-source.cfg"

test -x "$NEW_TOOL" || {
    echo "ERROR: rebuilt navmeshtool was not copied out."
    exit 41
}

echo
echo "===== 6/10 VERIFY REBUILT TOOL ON UBUNTU ====="

file "$NEW_TOOL" | tee "$HOST_OUT/new-navtool.file.txt"
grep -Eiq 'ELF 64-bit.*(ARM aarch64|aarch64)' "$HOST_OUT/new-navtool.file.txt" || {
    echo "ERROR: copied output is not ELF64 AArch64."
    exit 42
}

NEW_TOOL_SHA="$(sha256sum "$NEW_TOOL" | awk '{print $1}')"
echo "New navmeshtool SHA:"
echo "  $NEW_TOOL_SHA"

cat "$HOST_OUT/output/BUILD_INFO.txt" || true

echo
echo "===== 7/10 PAIR NEW TOOL WITH EXACT WORKING GAME DEFAULTS ====="

# Pull exact current runtime files. We do NOT re-encode defaults.bin.
scp -q "${SSH[@]}" "$DEV:$GAME_DEFAULTS" "$HOST_OUT/defaults.current-game.bin"
scp -q "${SSH[@]}" "$DEV:$MAIN_CFG" "$HOST_OUT/openmw.current-game.cfg"

test "$(sha256sum "$HOST_OUT/defaults.current-game.bin" | awk '{print $1}')" = "$GAME_DEFAULTS_SHA"

# Decode only for diagnostics; the byte-for-byte original is what gets installed.
if base64 -d "$HOST_OUT/defaults.current-game.bin" \
    >"$HOST_OUT/defaults.current-game.decoded.cfg" 2>"$HOST_OUT/defaults-decode.err"
then
    echo "PASS: working game defaults.bin decodes for audit."
else
    echo "NOTE: host base64 decoder did not decode the working game file."
    echo "      The original bytes will still be used unchanged."
    cat "$HOST_OUT/defaults-decode.err" || true
fi

# Keep a source-vs-runtime settings audit for later diagnosis, but do not modify
# either defaults source.
python3 - \
  "$SOURCE_DEFAULTS" \
  "$HOST_OUT/defaults.current-game.decoded.cfg" \
  "$HOST_OUT/settings-key-audit.txt" <<'PY_AUDIT'
from pathlib import Path
import sys

src = Path(sys.argv[1])
dev = Path(sys.argv[2])
out = Path(sys.argv[3])

def keys(path):
    if not path.exists() or not path.stat().st_size:
        return set()
    section = ""
    result = set()
    for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("[") and line.endswith("]"):
            section = line[1:-1].strip()
            continue
        if "=" in raw and section:
            key = raw.split("=",1)[0].strip()
            result.add((section, key))
    return result

a = keys(src)
b = keys(dev)

lines = [
    f"current_source_keys={len(a)}",
    f"current_game_default_keys={len(b)}",
    f"source_only={len(a-b)}",
    f"game_only={len(b-a)}",
    "",
    "SOURCE_ONLY:",
]
lines += [f"[{s}] {k}" for s,k in sorted(a-b)]
lines += ["", "GAME_ONLY:"]
lines += [f"[{s}] {k}" for s,k in sorted(b-a)]

out.write_text("\n".join(lines) + "\n", encoding="utf-8")
print("\n".join(lines[:5]))
PY_AUDIT

# Build a concrete executable-local config for the private runtime.
python3 - \
  "$HOST_OUT/openmw.current-game.cfg" \
  "$HOST_OUT/openmw.navtool.cfg" \
  "$ROOT" <<'PY_CFG'
from pathlib import Path
import sys

src = Path(sys.argv[1]).read_text(encoding="utf-8", errors="strict")
out = Path(sys.argv[2])
root = sys.argv[3]

# Handle ordinary and backslash-escaped shell-variable spellings.
for token in (r"\${ROOT}", r"\$ROOT", "${ROOT}", "$ROOT"):
    src = src.replace(token, root)

out.write_text(src, encoding="utf-8", newline="\n")

if "$ROOT" in src or "${ROOT}" in src or r"\$ROOT" in src or r"\${ROOT}" in src:
    raise SystemExit("ERROR: unresolved ROOT token remains in private config")

print("PASS: private navtool openmw.cfg has concrete paths.")
PY_CFG

echo
echo "===== 8/10 INSTALL ONLY THE ISOLATED TOOL RUNTIME ====="

PRIVATE_CFG_SHA="$(sha256sum "$HOST_OUT/openmw.navtool.cfg" | awk '{print $1}')"
BACKUP="$RUNTIME/.before-current-rebuild-$STAMP"

scp -q "${SSH[@]}" "$NEW_TOOL" "$DEV:$RUNTIME/openmw-navmeshtool.new"
scp -q "${SSH[@]}" "$HOST_OUT/defaults.current-game.bin" "$DEV:$RUNTIME/defaults.bin.new"
scp -q "${SSH[@]}" "$HOST_OUT/openmw.navtool.cfg" "$DEV:$RUNTIME/openmw.cfg.new"

if ! ssh "${SSH[@]}" "$DEV" "
set -e

test \"\$(sha256sum '$RUNTIME/openmw-navmeshtool.new' | awk '{print \$1}')\" = '$NEW_TOOL_SHA'
test \"\$(sha256sum '$RUNTIME/defaults.bin.new' | awk '{print \$1}')\" = '$GAME_DEFAULTS_SHA'
test \"\$(sha256sum '$RUNTIME/openmw.cfg.new' | awk '{print \$1}')\" = '$PRIVATE_CFG_SHA'

mkdir -p '$BACKUP'

[ ! -f '$RUNTIME/openmw-navmeshtool' ] || cp -p '$RUNTIME/openmw-navmeshtool' '$BACKUP/openmw-navmeshtool'
[ ! -f '$RUNTIME/defaults.bin' ] || cp -p '$RUNTIME/defaults.bin' '$BACKUP/defaults.bin'
[ ! -f '$RUNTIME/openmw.cfg' ] || cp -p '$RUNTIME/openmw.cfg' '$BACKUP/openmw.cfg'

mv -f '$RUNTIME/openmw-navmeshtool.new' '$RUNTIME/openmw-navmeshtool'
mv -f '$RUNTIME/defaults.bin.new' '$RUNTIME/defaults.bin'
mv -f '$RUNTIME/openmw.cfg.new' '$RUNTIME/openmw.cfg'
chmod 755 '$RUNTIME/openmw-navmeshtool'
sync

echo 'Installed isolated runtime:'
sha256sum \
  '$RUNTIME/openmw-navmeshtool' \
  '$RUNTIME/defaults.bin' \
  '$RUNTIME/openmw.cfg'
" | tee "$HOST_OUT/install.txt"
then
    echo "ERROR: isolated runtime installation failed."
    exit 50
fi

echo "Backup of previous isolated runtime:"
echo "  $BACKUP"

echo
echo "===== 9/10 FULLY DETACHED DEVICE INITIALIZATION TEST ====="

REMOTE_TEST_BASE="/mnt/UDISK/openmw51-navtool-safe-tests"
REMOTE_TEST="$REMOTE_TEST_BASE/current-rebuild-$STAMP"
REMOTE_RUNNER="$REMOTE_TEST/run.sh"
REMOTE_LOG="$REMOTE_TEST/navtool-version.log"
REMOTE_STATUS="$REMOTE_TEST/status"
REMOTE_KERNEL="$REMOTE_TEST/kernel.txt"

TEST_RUNNER="$HOST_OUT/device-init-runner.sh"

cat > "$TEST_RUNNER" <<EOF_TEST
#!/bin/sh
ROOT='$ROOT'
RUNTIME='$RUNTIME'
TOOL="\$RUNTIME/openmw-navmeshtool"
CFGDIR='\$ROOT/config-0.51'
NAVDIR='/mnt/UDISK/openmw51-nav'
LOG='$REMOTE_LOG'
STATUS='$REMOTE_STATUS'
KERNEL='$REMOTE_KERNEL'

rm -f "\$STATUS"
exec </dev/null >>"\$LOG" 2>&1

echo "=================================================================="
echo "CURRENTLY REBUILT NAVMESHTOOL DETACHED INIT TEST"
echo "=================================================================="
date
echo "PID=\$\$"
echo

export XDG_RUNTIME_DIR="\${XDG_RUNTIME_DIR:-/tmp/runtime-root}"
mkdir -p "\$XDG_RUNTIME_DIR"
chmod 0700 "\$XDG_RUNTIME_DIR" 2>/dev/null || true
export XDG_CONFIG_HOME="\$CFGDIR"
export XDG_DATA_HOME="\$CFGDIR"
export OPENMW_RESOURCES="\$ROOT/resources"
export OSG_LIBRARY_PATH="\$ROOT/osgPlugins-3.6.5"
export LD_LIBRARY_PATH="\$ROOT/lib:\$ROOT/libs:\$ROOT/lib/aarch64:/mnt/SDCARD/System/lib:/usr/trimui/lib:\${LD_LIBRARY_PATH:-}"

cd "\$RUNTIME" || {
    RC=\$?
    printf '%s\n' "\$RC" > "\$STATUS"
    exit 0
}

echo "Runtime hashes:"
sha256sum "\$TOOL" "\$RUNTIME/defaults.bin" "\$RUNTIME/openmw.cfg" 2>&1
echo

"\$TOOL" \
  --resources "\$ROOT/resources" \
  --config "\$CFGDIR" \
  --user-data "\$NAVDIR" \
  --version

RC=\$?
echo
echo "NAVTOOL_RC=\$RC"
date

dmesg 2>/dev/null | tail -180 > "\$KERNEL" 2>&1 || true

TMP="\$STATUS.tmp.\$\$"
printf '%s\n' "\$RC" > "\$TMP"
mv -f "\$TMP" "\$STATUS"
sync
exit 0
EOF_TEST

chmod +x "$TEST_RUNNER"

ssh "${SSH[@]}" "$DEV" "mkdir -p '$REMOTE_TEST'"
scp -q "${SSH[@]}" "$TEST_RUNNER" "$DEV:$REMOTE_RUNNER"
ssh "${SSH[@]}" "$DEV" "chmod +x '$REMOTE_RUNNER'"

LAUNCH="
rm -f '$REMOTE_STATUS' '$REMOTE_LOG'
if command -v nohup >/dev/null 2>&1; then
    nohup sh '$REMOTE_RUNNER' </dev/null >/dev/null 2>&1 &
else
    sh '$REMOTE_RUNNER' </dev/null >/dev/null 2>&1 &
fi
echo \$!
"

ssh "${SSH[@]}" "$DEV" "$LAUNCH" >"$HOST_OUT/device-test-launch.txt" 2>&1 || {
    echo "ERROR: could not launch detached device test."
    cat "$HOST_OUT/device-test-launch.txt" || true
    exit 60
}

echo "Detached device PID: $(cat "$HOST_OUT/device-test-launch.txt" 2>/dev/null || echo unknown)"

TEST_RC=""
FAILS=0
COUNT=0
while :; do
    COUNT=$((COUNT + 1))
    POLL="$(
        ssh "${SSH[@]}" "$DEV" "
        if [ -s '$REMOTE_STATUS' ]; then
            echo STATUS
            cat '$REMOTE_STATUS'
        else
            echo RUNNING
        fi
        " 2>/dev/null
    )"
    PRC=$?

    if [ "$PRC" -eq 0 ]; then
        FAILS=0
        if [ "$(printf '%s\n' "$POLL" | sed -n '1p')" = "STATUS" ]; then
            TEST_RC="$(printf '%s\n' "$POLL" | sed -n '2p' | tr -cd '0-9-')"
            echo
            echo "Detached navmeshtool returned: ${TEST_RC:-unknown}"
            break
        fi
    else
        FAILS=$((FAILS + 1))
        if [ "$FAILS" -ge 3 ]; then
            echo
            echo "ERROR: device became unreachable during detached test."
            break
        fi
    fi

    if [ $((COUNT % 4)) -eq 0 ]; then printf '.'; fi
    sleep 2
done
echo

scp -q "${SSH[@]}" "$DEV:$REMOTE_LOG" "$HOST_OUT/navtool-version.log" 2>/dev/null || true
scp -q "${SSH[@]}" "$DEV:$REMOTE_KERNEL" "$HOST_OUT/device-kernel.txt" 2>/dev/null || true
scp -q "${SSH[@]}" "$DEV:$REMOTE_STATUS" "$HOST_OUT/device-status.txt" 2>/dev/null || true

if [ -s "$HOST_OUT/navtool-version.log" ]; then
    echo
    echo "----- NEW NAVMESHTOOL INIT LOG -----"
    cat "$HOST_OUT/navtool-version.log"
fi

echo
echo "===== 10/10 VERIFY PROTECTED STATE + RESULT ====="

GAME_BIN_AFTER="$(hash_remote "$GAME_BIN")"
GAME_DEFAULTS_AFTER="$(hash_remote "$GAME_DEFAULTS")"
V20_AFTER="$(hash_remote "$V20_LUA")"
LIVE_DB_AFTER="$(hash_remote "$LIVE_DB")"

CHANGED=0
[ "$GAME_BIN_AFTER" = "$GAME_BIN_SHA" ] || { echo "ERROR: game binary changed"; CHANGED=1; }
[ "$GAME_DEFAULTS_AFTER" = "$GAME_DEFAULTS_SHA" ] || { echo "ERROR: game defaults changed"; CHANGED=1; }
[ "$V20_AFTER" = "$V20_SHA" ] || { echo "ERROR: V20 Lua changed"; CHANGED=1; }
[ "$LIVE_DB_AFTER" = "$LIVE_DB_SHA" ] || { echo "ERROR: live navmesh DB changed"; CHANGED=1; }

{
    echo "new_navtool_sha=$NEW_TOOL_SHA"
    echo "navtool_rc=${TEST_RC:-NO_STATUS}"
    echo "protected_changed=$CHANGED"
    echo "game_binary=$GAME_BIN_AFTER"
    echo "game_defaults=$GAME_DEFAULTS_AFTER"
    echo "v20_lua=$V20_AFTER"
    echo "live_db=$LIVE_DB_AFTER"
} | tee "$HOST_OUT/RESULT.txt"

if [ "$CHANGED" -eq 0 ]; then
    echo "PASS: game binary/defaults, V20, and live DB are unchanged."
fi

if [ "${TEST_RC:-}" = "0" ] \
   && [ -s "$HOST_OUT/navtool-version.log" ] \
   && ! grep -q 'Fatal error:' "$HOST_OUT/navtool-version.log"
then
    echo
    echo "=================================================================="
    echo "SUCCESS: CURRENT-SOURCE NAVMESHTOOL FULLY INITIALIZED"
    echo "=================================================================="
    echo "New tool:"
    echo "  $RUNTIME/openmw-navmeshtool"
    echo "SHA256:"
    echo "  $NEW_TOOL_SHA"
    echo
    echo "It is paired with an exact copy of the current working game defaults.bin."
    echo "No navmesh generation has been started."
    echo
    echo "Next step is the isolated global work DB:"
    echo "  /mnt/UDISK/openmw51-nav-global-work/navmesh.db"
    echo "=================================================================="
else
    echo
    echo "=================================================================="
    echo "NEW TOOL BUILT, BUT INITIALIZATION STILL FAILED"
    echo "=================================================================="
    echo "This is now useful evidence from TODAY'S source tree."
    echo "Inspect:"
    echo "  $HOST_OUT/navtool-version.log"
    echo "  $HOST_OUT/settings-key-audit.txt"
    echo "  $HOST_OUT/build.log"
    echo
    echo "The previous isolated runtime is backed up at:"
    echo "  $BACKUP"
    echo "=================================================================="
    exit 70
fi
