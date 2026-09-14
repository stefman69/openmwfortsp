#!/usr/bin/env bash
# Build/install the functional OpenMW 0.51 TrimUI Smart Pro Manager V2.
# Keep the four companion source files beside this controller.
# Actions: install (default), collect, rollback, uninstall, selftest

set -u -o pipefail

ACTION="${1:-install}"
CTR="${OPENMW_CONTAINER:-openmw_builder}"
DEV="${OPENMW51_DEVICE:-root@192.168.1.12}"
ROOT="${OPENMW51_GAMEDIR:-/mnt/SDCARD/data/ports/openmw51}"
HERE="$(cd "$(dirname "$0")" && pwd)"
HOST_DIR="${OPENMW_DOWNLOADS_DIR:-$HOME/Downloads}"
CPP="$HERE/openmw51_launcher_manager_v2.cpp"
PY="$HERE/openmw51_launcher_backend_v2.py"
ACTION_SH="$HERE/openmw51_manager_action_v2.sh"
WRAPPER="$HERE/OpenMW_51_Manager_v2.sh"
HOST_BIN="$HOST_DIR/openmw51-manager-v2"
BUILD_LOG="$HOST_DIR/openmw51-manager-v2-build.log"
STATE="$HOST_DIR/openmw51-manager-v2-install.state"
STAMP="$(date +%Y%m%d-%H%M%S)"
if [ ! -d "$HOST_DIR" ]; then
    if [ "$ACTION" = selftest ]; then
        HOST_DIR="$HERE"
    else
        echo "ERROR: host output directory missing: $HOST_DIR" >&2
        exit 9
    fi
fi
TMP="$(mktemp -d "$HOST_DIR/.openmw51-manager-v2.XXXXXX")" || exit 9

cleanup() { [ -n "$TMP" ] && [ -d "$TMP" ] && rm -rf "$TMP"; }
trap cleanup EXIT
fail() { local rc="${1:-1}"; shift || true; echo "ERROR: $*" >&2; exit "$rc"; }
need() { command -v "$1" >/dev/null 2>&1 || fail 10 "required command missing: $1"; echo "PASS command: $1"; }
valid_sha() { case "$1" in ''|*[!0-9a-f]*) return 1;; esac; [ "${#1}" -eq 64 ]; }
state_value() { sed -n "s/^$2='\([^']*\)'$/\1/p" "$1" | tail -n 1; }
ensure_ssh() {
    need ssh; need scp
    ssh -o BatchMode=yes -o ConnectTimeout=8 "$DEV" true >/dev/null 2>&1 || fail 11 "SSH failed: $DEV"
    echo "PASS SSH: $DEV"
}

source_selftest() {
    need bash; need python3
    for f in "$CPP" "$PY" "$ACTION_SH" "$WRAPPER"; do [ -s "$f" ] || fail 12 "companion file missing: $f"; done
    bash -n "$ACTION_SH" || fail 13 "runtime action shell syntax failed"
    bash -n "$WRAPPER" || fail 13 "Ports wrapper syntax failed"
    python3 -m py_compile "$PY" || fail 14 "Python backend syntax failed"
    python3 "$PY" selftest | grep -Fq OPENMW51_MANAGER_BACKEND_V2_SELFTEST_PASS || fail 14 "Python backend behavior selftest failed"
    if command -v g++ >/dev/null 2>&1; then
        g++ -std=c++17 -O2 -Wall -Wextra -Wpedantic "$CPP" -o "$TMP/manager-host-test" -ldl || fail 15 "host C++ compile failed"
        "$TMP/manager-host-test" --selftest | grep -Fq OPENMW51_MANAGER_V2_SELFTEST_PASS || fail 15 "C++ behavior selftest failed"
        echo "PASS host C++ compile + non-display behavior selftest"
        echo "INFO display execution is device-only; Ubuntu is not required to provide SDL2"
    else
        echo "INFO host g++ unavailable; Docker ARM64 compile remains mandatory"
    fi
    echo "PASS four-file manager source selftest"
}

collect_action() {
    ensure_ssh
    local out="$HOST_DIR/openmw51-manager-v2-diagnostics-$STAMP.tar.gz"
    ssh "$DEV" 'bash -s' -- "$ROOT" <<'REMOTE_COLLECT' > "$TMP/device-diagnostics.txt" 2>&1
set -u
ROOT="$1"
echo '===== MANAGER STATUS ====='; cat "$ROOT/launcher/status.conf" 2>/dev/null || true
echo '===== LAST RESULT ====='; cat "$ROOT/launcher/last-result.txt" 2>/dev/null || true
echo '===== MOD PLAN ====='; cat "$ROOT/launcher/modplan.tsv" 2>/dev/null || true
echo '===== DEFAULT NAVMESH CANDIDATES ====='; cat "$ROOT/launcher/default-navmesh-candidates.txt" 2>/dev/null || true
echo '===== SWAP ====='; cat /proc/swaps 2>/dev/null || true
echo '===== UDISK ====='; df -h /mnt/UDISK 2>/dev/null || true; grep ' /mnt/UDISK ' /proc/mounts 2>/dev/null || true
echo '===== NAVMESH ====='; ls -lh /mnt/UDISK/openmw51-nav/navmesh.db /mnt/UDISK/openmw51-nav/profile.sha256 2>/dev/null || true
echo '===== GENERATOR STATUS ====='; cat "$ROOT/navmesh-generation-full-3worker.status" 2>/dev/null || true
echo '===== GENERATOR LOG TAIL ====='; tail -240 "$ROOT/navmesh-generation-full-3worker.log" 2>/dev/null || true
echo '===== DISPLAY / SDL ====='; cat /proc/fb 2>/dev/null || true; ls -l /dev/fb* /dev/dri/* 2>/dev/null || true
echo '===== MANAGER PROCESSES / LOCKS ====='; ps w 2>/dev/null | grep -E '[o]penmw51-manager-v2|OpenMW_51_Manager_v2' || true; ls -l "$ROOT/launcher/manager-v2-wrapper.pid" "$ROOT/launcher/manager-v2-ui.pid" "$ROOT/launcher/ui-ready" 2>/dev/null || true; for f in "$ROOT/launcher/manager-v2-wrapper.pid" "$ROOT/launcher/manager-v2-ui.pid" "$ROOT/launcher/ui-ready"; do [ -f "$f" ] && { echo "[$f]"; cat "$f" 2>/dev/null || true; }; done
for d in /sys/class/graphics/fb*; do [ -d "$d" ] || continue; echo "[$d]"; for f in name bits_per_pixel virtual_size stride rotate blank; do [ -r "$d/$f" ] && { printf '%s=' "$f"; cat "$d/$f"; }; done; done
echo 'SDL libraries:'; find "$ROOT/lib" /usr/lib /usr/trimui/lib -maxdepth 3 -type f -name 'libSDL2*.so*' 2>/dev/null | head -80 || true
echo 'Manager linkage:'; ldd "$ROOT/bin/openmw51-manager-v2" 2>/dev/null || true
echo '===== MANAGER LOG TAIL ====='; tail -400 "$ROOT/launcher/manager-v2.log" 2>/dev/null || true
REMOTE_COLLECT
    scp -q "$DEV:$ROOT/openmw.cfg" "$TMP/openmw.cfg" 2>/dev/null || true
    cp "$STATE" "$TMP/install.state" 2>/dev/null || true
    tar -C "$TMP" -czf "$out" device-diagnostics.txt openmw.cfg install.state 2>/dev/null \
        || tar -C "$TMP" -czf "$out" device-diagnostics.txt
    echo "PASS manager diagnostics: $out"
}

uninstall_action() {
    ensure_ssh
    ssh "$DEV" 'bash -s' -- "$ROOT" <<'REMOTE_UNINSTALL' || fail 20 "manager uninstall failed"
set -u
ROOT="$1"
rm -f "$ROOT/bin/openmw51-manager-v2"
rm -f "$ROOT/launcher/openmw51-launcher-backend-v2.py" "$ROOT/launcher/openmw51-manager-action-v2.sh"
rm -f "$ROOT/launcher/request" "$ROOT/launcher/status.conf" "$ROOT/launcher/modplan.tsv" "$ROOT/launcher/modplan.json" "$ROOT/launcher/ui-state.conf"
for p in /mnt/SDCARD/Roms/PORTS/OpenMW_51_Manager_v2.sh /mnt/sdcard/mmcblk1p1/Roms/PORTS/OpenMW_51_Manager_v2.sh; do [ -e "$p" ] && rm -f "$p" || true; done
sync
echo 'PASS Manager V2 removed. Navmesh, swap, game launcher, mods and openmw.cfg remain intact.'
REMOTE_UNINSTALL
    echo "PASS uninstall complete"
}

rollback_action() {
    ensure_ssh
    [ -s "$STATE" ] || fail 21 "install state missing: $STATE"
    local backup bin_sha py_sha action_sha wrap_sha
    backup="$(state_value "$STATE" DEVICE_BACKUP)"
    bin_sha="$(state_value "$STATE" BIN_SHA)"; py_sha="$(state_value "$STATE" PY_SHA)"
    action_sha="$(state_value "$STATE" ACTION_SHA)"; wrap_sha="$(state_value "$STATE" WRAP_SHA)"
    for s in "$bin_sha" "$py_sha" "$action_sha" "$wrap_sha"; do valid_sha "$s" || fail 21 "invalid rollback hash"; done
    ssh "$DEV" 'bash -s' -- "$ROOT" "$backup" "$bin_sha" "$py_sha" "$action_sha" "$wrap_sha" <<'REMOTE_ROLLBACK' || fail 22 "manager rollback failed"
set -u
ROOT="$1"; B="$2"; BIN_SHA="$3"; PY_SHA="$4"; ACTION_SHA="$5"; WRAP_SHA="$6"
BIN="$ROOT/bin/openmw51-manager-v2"; PY="$ROOT/launcher/openmw51-launcher-backend-v2.py"; ACT="$ROOT/launcher/openmw51-manager-action-v2.sh"
PORT="$(cat "$B/ports-path" 2>/dev/null || true)"; [ -n "$PORT" ] || exit 1
[ "$(sha256sum "$BIN" | awk '{print $1}')" = "$BIN_SHA" ] || exit 2
[ "$(sha256sum "$PY" | awk '{print $1}')" = "$PY_SHA" ] || exit 3
[ "$(sha256sum "$ACT" | awk '{print $1}')" = "$ACTION_SHA" ] || exit 4
[ "$(sha256sum "$PORT" | awk '{print $1}')" = "$WRAP_SHA" ] || exit 5
restore(){ target="$1"; name="$2"; if [ -f "$B/$name.present" ]; then cp -p "$B/$name" "$target"; else rm -f "$target"; fi; }
restore "$BIN" manager-bin; restore "$PY" manager-python; restore "$ACT" manager-action; restore "$PORT" manager-wrapper
sync
echo 'PASS exact pre-install Manager files restored; game data remains untouched.'
REMOTE_ROLLBACK
    echo "PASS rollback complete"
}

case "$ACTION" in
    selftest) source_selftest; exit 0;;
    collect) collect_action; exit 0;;
    rollback) rollback_action; exit 0;;
    uninstall) uninstall_action; exit 0;;
    install) ;;
    *) fail 2 "usage: $0 [install|collect|rollback|uninstall|selftest]";;
esac

exec > >(tee "$HOST_DIR/openmw51-manager-v2-install-$STAMP.log") 2>&1

cat <<'BANNER'
============================================================
OPENMW 0.51 TSP MANAGER V2.1
FUNCTIONAL NAVMESH / SWAP / MOD LOAD-ORDER INTEGRATION
============================================================
Installs a separate Ports entry. The working Morrowind_51.sh is not edited.
No navmesh, swapfile, or openmw.cfg is changed during this installer run.
Those actions require confirmation inside the manager.

Canonical DB:   /mnt/UDISK/openmw51-nav/navmesh.db
Canonical swap: /mnt/UDISK/openmw51-swapfile (512 MB default)
Generator:      existing full 3-worker exterior + interior Ports tool
Mods:           persistent data-root order + TES3 master dependency sorting
============================================================
BANNER

source_selftest
need docker; need sha256sum; need file; ensure_ssh
[ -d "$HOST_DIR" ] || fail 23 "host output directory missing: $HOST_DIR"
docker inspect "$CTR" >/dev/null 2>&1 || fail 24 "Docker container not found: $CTR"
if [ "$(docker inspect -f '{{.State.Running}}' "$CTR" 2>/dev/null || true)" != true ]; then
    docker start "$CTR" >/dev/null || fail 24 "could not start Docker"
fi
echo "PASS Docker: $CTR"

echo
echo "===== 1/6 DEVICE READ-ONLY PREFLIGHT ====="
ssh "$DEV" 'bash -s' -- "$ROOT" <<'REMOTE_PREFLIGHT' || fail 25 "device preflight failed before mutation"
set -u
ROOT="$1"
[ -d "$ROOT" ] || { echo "ERROR missing root: $ROOT"; exit 1; }
[ -s "$ROOT/openmw.cfg" ] || { echo 'ERROR missing main openmw.cfg'; exit 2; }
[ -d /mnt/UDISK ] || { echo 'ERROR UDISK is not mounted'; exit 3; }
PLAY=""; GEN=""
for p in /mnt/SDCARD/Roms/PORTS/Morrowind_51.sh /mnt/sdcard/mmcblk1p1/Roms/PORTS/Morrowind_51.sh; do [ -s "$p" ] && PLAY="$p" && break; done
for p in /mnt/SDCARD/Roms/PORTS/OpenMW_51_Generate_Full_Navmesh_3Worker.sh /mnt/sdcard/mmcblk1p1/Roms/PORTS/OpenMW_51_Generate_Full_Navmesh_3Worker.sh; do [ -x "$p" ] && GEN="$p" && break; done
[ -n "$PLAY" ] || { echo 'ERROR working Morrowind_51.sh not found'; exit 4; }
[ -n "$GEN" ] || { echo 'ERROR full three-worker navmesh generator not found'; exit 5; }
if pidof openmw-0.51 >/dev/null 2>&1 || pidof openmw-navmeshtool >/dev/null 2>&1; then echo 'ERROR close OpenMW/navmeshtool first'; exit 6; fi
echo "PASS root: $ROOT"
echo "PASS game launcher: $PLAY"
echo "PASS navmesh generator: $GEN"
grep ' /mnt/UDISK ' /proc/mounts || true
df -h /mnt/UDISK || true
REMOTE_PREFLIGHT

echo
echo "===== 2/6 BUILD ARM64 MANAGER ====="
docker cp "$CPP" "$CTR:/tmp/openmw51_launcher_manager_v2.cpp" || fail 26 "could not stage C++ source"
if ! docker exec -i "$CTR" bash -s <<'REMOTE_BUILD' 2>&1 | tee "$BUILD_LOG"
set -u
CXX=""
for cache in /root/openmw-0.51-tsp-build/CMakeCache.txt /root/openmw-0.51-tsp-build/CMakeFiles/*/CMakeCXXCompiler.cmake; do
    [ -f "$cache" ] || continue
    candidate="$(sed -n 's/^CMAKE_CXX_COMPILER:FILEPATH=//p;s/^set(CMAKE_CXX_COMPILER "\([^"]*\)".*$/\1/p' "$cache" | head -1)"
    [ -x "$candidate" ] || continue
    machine="$($candidate -dumpmachine 2>/dev/null || true)"
    case "$machine" in aarch64*|arm64*) CXX="$candidate"; break;; esac
done
for c in aarch64-linux-gnu-g++ aarch64-none-linux-gnu-g++ g++-13 g++ c++; do
    [ -z "$CXX" ] || break
    command -v "$c" >/dev/null 2>&1 || continue
    machine="$($c -dumpmachine 2>/dev/null || true)"
    case "$machine" in aarch64*|arm64*) CXX="$c"; break;; esac
done
[ -n "$CXX" ] || { echo 'FAIL no ARM64 C++ compiler found in openmw_builder'; exit 20; }
echo "Compiler: $CXX ($($CXX -dumpmachine))"
"$CXX" -std=c++17 -O2 -Wall -Wextra -Wpedantic -static-libstdc++ -static-libgcc \
    /tmp/openmw51_launcher_manager_v2.cpp -o /tmp/openmw51-manager-v2 -ldl || exit 21
[ -x /tmp/openmw51-manager-v2 ] || exit 22
file /tmp/openmw51-manager-v2
sha256sum /tmp/openmw51-manager-v2
REMOTE_BUILD
then
    fail 27 "ARM64 manager build failed; log: $BUILD_LOG"
fi
docker cp "$CTR:/tmp/openmw51-manager-v2" "$HOST_BIN" || fail 28 "Docker-to-Ubuntu copy failed"
chmod +x "$HOST_BIN"
case "$(file "$HOST_BIN")" in *aarch64*|*ARM64*|*ARM\ aarch64*) ;; *) fail 28 "output is not ARM64: $(file "$HOST_BIN")";; esac

BIN_SHA="$(sha256sum "$HOST_BIN" | awk '{print $1}')"
PY_SHA="$(sha256sum "$PY" | awk '{print $1}')"
ACTION_SHA="$(sha256sum "$ACTION_SH" | awk '{print $1}')"
WRAP_SHA="$(sha256sum "$WRAPPER" | awk '{print $1}')"
for s in "$BIN_SHA" "$PY_SHA" "$ACTION_SHA" "$WRAP_SHA"; do valid_sha "$s" || fail 29 "invalid local artifact SHA"; done
echo "PASS ARM64 manager: $BIN_SHA"

echo
echo "===== 3/6 BACK UP ONLY PRIOR MANAGER FILES ====="
DEVICE_BACKUP="$ROOT/launcher/install-backups/manager-v2-before-$STAMP"
ssh "$DEV" 'bash -s' -- "$ROOT" "$DEVICE_BACKUP" <<'REMOTE_BACKUP' || fail 30 "manager-file backup failed"
set -u
ROOT="$1"; B="$2"
mkdir -p "$B" "$ROOT/bin" "$ROOT/launcher"
PORT=""
for p in /mnt/SDCARD/Roms/PORTS/OpenMW_51_Manager_v2.sh /mnt/sdcard/mmcblk1p1/Roms/PORTS/OpenMW_51_Manager_v2.sh; do
    if [ -d "$(dirname "$p")" ]; then PORT="$p"; break; fi
done
[ -n "$PORT" ] || exit 1
backup(){ src="$1"; name="$2"; if [ -e "$src" ]; then cp -p "$src" "$B/$name"; touch "$B/$name.present"; fi; }
backup "$ROOT/bin/openmw51-manager-v2" manager-bin
backup "$ROOT/launcher/openmw51-launcher-backend-v2.py" manager-python
backup "$ROOT/launcher/openmw51-manager-action-v2.sh" manager-action
backup "$PORT" manager-wrapper
printf '%s\n' "$PORT" > "$B/ports-path"
echo "PASS manager-only backup: $B"
REMOTE_BACKUP

echo
echo "===== 4/6 STAGE + INSTALL TRANSACTIONALLY ====="
scp -q "$HOST_BIN" "$DEV:$ROOT/launcher/.manager-bin.incoming" || fail 31 "binary upload failed"
scp -q "$PY" "$DEV:$ROOT/launcher/.manager-python.incoming" || fail 31 "Python upload failed"
scp -q "$ACTION_SH" "$DEV:$ROOT/launcher/.manager-action.incoming" || fail 31 "action upload failed"
scp -q "$WRAPPER" "$DEV:$ROOT/launcher/.manager-wrapper.incoming" || fail 31 "wrapper upload failed"

if ! ssh "$DEV" 'bash -s' -- "$ROOT" "$DEVICE_BACKUP" "$BIN_SHA" "$PY_SHA" "$ACTION_SHA" "$WRAP_SHA" <<'REMOTE_INSTALL'
set -u
ROOT="$1"; B="$2"; BIN_SHA="$3"; PY_SHA="$4"; ACTION_SHA="$5"; WRAP_SHA="$6"
stage="$ROOT/launcher"
check(){ [ "$(sha256sum "$1" | awk '{print $1}')" = "$2" ]; }
check "$stage/.manager-bin.incoming" "$BIN_SHA" || exit 1
check "$stage/.manager-python.incoming" "$PY_SHA" || exit 2
check "$stage/.manager-action.incoming" "$ACTION_SHA" || exit 3
check "$stage/.manager-wrapper.incoming" "$WRAP_SHA" || exit 4
bash -n "$stage/.manager-action.incoming" || exit 5
bash -n "$stage/.manager-wrapper.incoming" || exit 6
python3 -m py_compile "$stage/.manager-python.incoming" || exit 7
PORT="$(cat "$B/ports-path")"; [ -n "$PORT" ] || exit 8
install -m 755 "$stage/.manager-bin.incoming" "$ROOT/bin/openmw51-manager-v2" || exit 9
install -m 755 "$stage/.manager-python.incoming" "$ROOT/launcher/openmw51-launcher-backend-v2.py" || exit 10
install -m 755 "$stage/.manager-action.incoming" "$ROOT/launcher/openmw51-manager-action-v2.sh" || exit 11
install -m 755 "$stage/.manager-wrapper.incoming" "$PORT" || exit 12
rm -f "$stage"/.manager-*.incoming
sync
check "$ROOT/bin/openmw51-manager-v2" "$BIN_SHA" || exit 13
check "$ROOT/launcher/openmw51-launcher-backend-v2.py" "$PY_SHA" || exit 14
check "$ROOT/launcher/openmw51-manager-action-v2.sh" "$ACTION_SHA" || exit 15
check "$PORT" "$WRAP_SHA" || exit 16
"$ROOT/bin/openmw51-manager-v2" --selftest | grep -Fq OPENMW51_MANAGER_V2_SELFTEST_PASS || exit 17
"$ROOT/launcher/openmw51-launcher-backend-v2.py" selftest | grep -Fq OPENMW51_MANAGER_BACKEND_V2_SELFTEST_PASS || exit 18
echo "PASS installed Manager V2: $PORT"
REMOTE_INSTALL
then
    echo "ERROR install failed; restoring prior manager files" >&2
    ssh "$DEV" 'bash -s' -- "$ROOT" "$DEVICE_BACKUP" <<'REMOTE_RECOVER' || true
set -u
ROOT="$1"; B="$2"; PORT="$(cat "$B/ports-path" 2>/dev/null || true)"
restore(){ target="$1"; name="$2"; if [ -f "$B/$name.present" ]; then cp -p "$B/$name" "$target"; else rm -f "$target"; fi; }
restore "$ROOT/bin/openmw51-manager-v2" manager-bin
restore "$ROOT/launcher/openmw51-launcher-backend-v2.py" manager-python
restore "$ROOT/launcher/openmw51-manager-action-v2.sh" manager-action
[ -n "$PORT" ] && restore "$PORT" manager-wrapper || true
rm -f "$ROOT/launcher"/.manager-*.incoming
sync
REMOTE_RECOVER
    fail 32 "transactional device install failed; prior manager restored"
fi

echo
echo "===== 5/6 INITIAL READ-ONLY SCAN ====="
ssh "$DEV" "$ROOT/launcher/openmw51-manager-action-v2.sh status" || fail 33 "initial manager status scan failed"
ssh "$DEV" 'bash -s' -- "$ROOT" <<'REMOTE_STATUS'
set -u
ROOT="$1"
echo '--- status ---'; cat "$ROOT/launcher/status.conf"
echo '--- default navmesh candidates ---'; cat "$ROOT/launcher/default-navmesh-candidates.txt"
echo '--- mod plan ---'; cat "$ROOT/launcher/modplan.tsv"
REMOTE_STATUS

echo
echo "===== 6/6 SAVE ROLLBACK STATE ====="
cat > "$STATE" <<EOF_STATE
DEVICE_BACKUP='$DEVICE_BACKUP'
BIN_SHA='$BIN_SHA'
PY_SHA='$PY_SHA'
ACTION_SHA='$ACTION_SHA'
WRAP_SHA='$WRAP_SHA'
EOF_STATE
[ -s "$STATE" ] || fail 34 "could not save host rollback state"

echo "============================================================"
echo "OPENMW 0.51 TSP MANAGER V2 INSTALLED"
echo "============================================================"
echo "Ports entry: OpenMW_51_Manager_v2"
echo "Working Morrowind_51.sh: unchanged"
echo "Navmesh/swap/openmw.cfg: scanned only, not changed"
echo
echo "Use the Manager entry to install the base DB and swap, sort/apply mods,"
echo "launch the existing 3-worker builder when required, or play Morrowind."
echo
echo "Collect diagnostics: $0 collect"
echo "Rollback manager install: $0 rollback"
echo "Remove manager only: $0 uninstall"
echo "============================================================"
