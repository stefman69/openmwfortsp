#!/usr/bin/env bash
# Ubuntu-side installer for the CURRENT-source 3-worker Ports launcher.
# Does not start navmesh generation.

set -Eeuo pipefail

cd "$HOME/Downloads"

DEV="${TSP_DEV:-root@192.168.1.25}"
CTR="${TSP_BUILDER:-openmw_builder}"

ROOT="/mnt/SDCARD/data/ports/openmw51"
RUNTIME="$ROOT/navmesh-tool-runtime"
PROGRESS="$ROOT/bin/openmw-navmesh-progress"

PORTS="/mnt/SDCARD/Roms/PORTS"
REMOTE_LAUNCHER="$PORTS/OpenMW_51_Generate_Full_Navmesh_3Worker.sh"
LOCAL_LAUNCHER="$HOME/Downloads/OpenMW_51_Generate_Full_Navmesh_3Worker.sh"

EXPECTED_TOOL_SHA="eac7e0e01ed7507ee32da113c46f36511dd8a3f1f56aa1b684545924b1083229"
DOCKER_PROGRESS="/root/openmw-0.51-tsp-package/bin/openmw-navmesh-progress"

STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="$HOME/Downloads/navmesh-launcher-install-$STAMP"
mkdir -p "$OUT"

exec > >(tee "$OUT/install.log") 2>&1

SSH=(-o BatchMode=yes -o ConnectTimeout=8)

echo "=================================================================="
echo "INSTALL CURRENT-SOURCE 3-WORKER NAVMESH PORTS LAUNCHER"
echo "=================================================================="
echo "Generation DB:"
echo "  /mnt/UDISK/openmw51-nav/navmesh.db"
echo
echo "NO second/work DB will be created."
echo "NO navmesh DB backup will be created."
echo "This installer does NOT start generation."
echo "=================================================================="

test -s "$LOCAL_LAUNCHER"
bash -n "$LOCAL_LAUNCHER"

echo
echo "===== 1/5 VERIFY CURRENT NAVMESHTOOL ====="

TOOL_SHA="$(
    ssh "${SSH[@]}" "$DEV" \
      "sha256sum '$RUNTIME/openmw-navmeshtool'" |
    awk '{print $1}'
)"

echo "Device navmeshtool SHA:"
echo "  $TOOL_SHA"

[ "$TOOL_SHA" = "$EXPECTED_TOOL_SHA" ] || {
    echo "ERROR: device is not using the freshly rebuilt current-source navmeshtool."
    exit 20
}

echo "PASS."

echo
echo "===== 2/5 ENSURE EXISTING SDL PROGRESS HELPER ====="

if ssh "${SSH[@]}" "$DEV" "test -x '$PROGRESS'"; then
    echo "Progress helper already installed:"
    ssh "${SSH[@]}" "$DEV" "ls -lh '$PROGRESS'; sha256sum '$PROGRESS'"
else
    echo "Progress helper is missing on the device."
    echo "Restoring the already-built helper from the Docker package only."

    docker inspect "$CTR" >/dev/null

    if [ "$(docker inspect -f '{{.State.Running}}' "$CTR")" != "true" ]; then
        docker start "$CTR" >/dev/null
    fi

    docker exec "$CTR" test -x "$DOCKER_PROGRESS"
    docker exec "$CTR" file "$DOCKER_PROGRESS" | tee "$OUT/progress-file.txt"
    grep -Eqi 'ARM aarch64|aarch64' "$OUT/progress-file.txt"

    docker cp "$CTR:$DOCKER_PROGRESS" "$OUT/openmw-navmesh-progress"
    chmod +x "$OUT/openmw-navmesh-progress"

    PROGRESS_SHA="$(sha256sum "$OUT/openmw-navmesh-progress" | awk '{print $1}')"

    scp "${SSH[@]}" -q \
      "$OUT/openmw-navmesh-progress" \
      "$DEV:$PROGRESS.new"

    ssh "${SSH[@]}" "$DEV" "
        set -e
        chmod +x '$PROGRESS.new'
        test \"\$(sha256sum '$PROGRESS.new' | awk '{print \$1}')\" = '$PROGRESS_SHA'
        mv -f '$PROGRESS.new' '$PROGRESS'
        sync
    "

    echo "PASS: progress helper restored."
fi

echo
echo "===== 3/5 INSTALL/REPLACE CANONICAL PORTS LAUNCHER ====="

ssh "${SSH[@]}" "$DEV" "
    set -e
    mkdir -p '$PORTS'

    if [ -e '$REMOTE_LAUNCHER' ]; then
        cp -p \
          '$REMOTE_LAUNCHER' \
          '$REMOTE_LAUNCHER.before-current-$STAMP'
    fi
"

scp "${SSH[@]}" -q \
  "$LOCAL_LAUNCHER" \
  "$DEV:$REMOTE_LAUNCHER.new"

ssh "${SSH[@]}" "$DEV" "
    set -e
    chmod +x '$REMOTE_LAUNCHER.new'
    bash -n '$REMOTE_LAUNCHER.new'

    grep -Fq '$RUNTIME/openmw-navmeshtool' '$REMOTE_LAUNCHER.new'
    grep -Fq 'NAVDIR=\"/mnt/UDISK/openmw51-nav\"' '$REMOTE_LAUNCHER.new'
    grep -Fq 'THREADS=\"\${NAVMESH_THREADS:-3}\"' '$REMOTE_LAUNCHER.new'

    if grep -Fq 'openmw51-nav-global-work' '$REMOTE_LAUNCHER.new'; then
        echo 'ERROR: obsolete work-DB path survived in launcher.'
        exit 31
    fi

    mv -f '$REMOTE_LAUNCHER.new' '$REMOTE_LAUNCHER'
    sync
"

echo "PASS: canonical Ports launcher installed."

echo
echo "===== 4/5 DEVICE PREFLIGHT — NO GENERATION ====="

ssh "${SSH[@]}" "$DEV" "
    set -e

    test -x '$RUNTIME/openmw-navmeshtool'
    test -s '$RUNTIME/defaults.bin'
    test -s '$RUNTIME/openmw.cfg'
    test -x '$PROGRESS'
    test -x '$REMOTE_LAUNCHER'
    test -s '/mnt/UDISK/openmw51-nav/navmesh.db'

    echo '--- launcher ---'
    ls -lh '$REMOTE_LAUNCHER'

    echo
    echo '--- current navmeshtool ---'
    sha256sum '$RUNTIME/openmw-navmeshtool'

    echo
    echo '--- progress helper ---'
    sha256sum '$PROGRESS'

    echo
    echo '--- EXISTING game navmesh DB ---'
    ls -lh '/mnt/UDISK/openmw51-nav/navmesh.db'
    sha256sum '/mnt/UDISK/openmw51-nav/navmesh.db'

    echo
    echo '--- currently running navmeshtool processes ---'
    ps w 2>/dev/null | grep '[o]penmw-navmeshtool' || echo 'none'
"

echo
echo "===== 5/5 READY ====="
echo
echo "On the TrimUI Ports menu run:"
echo
echo "  OpenMW_51_Generate_Full_Navmesh_3Worker.sh"
echo
echo "It will use:"
echo "  3 workers"
echo "  exterior + interiors"
echo "  current rebuilt navmeshtool"
echo "  existing /mnt/UDISK/openmw51-nav/navmesh.db"
echo "  existing SDL progress/ETA display"
echo
echo "It will NOT create:"
echo "  /mnt/UDISK/openmw51-nav-global-work/navmesh.db"
echo "  any automatic navmesh DB backup"
echo
echo "Installer log:"
echo "  $OUT/install.log"
