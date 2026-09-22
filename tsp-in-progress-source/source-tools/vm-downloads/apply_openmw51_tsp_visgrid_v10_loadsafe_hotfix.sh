#!/usr/bin/env bash
set -Eeuo pipefail

DEV="${TSP_DEV:-root@192.168.1.25}"
STAMP="$(date +%Y%m%d-%H%M%S)"

ROOT="/mnt/SDCARD/data/ports/openmw51"
BIN="$ROOT/bin/openmw-0.51"
LUA="$ROOT/mods/TSPInteriorVisGrid/scripts/TSPInteriorVisGrid/visgrid.lua"
TOOLS="$HOME/Downloads/visgrid-tools"

PKG="$HOME/Downloads/openmw51-visgrid-v10-loadsafe-$STAMP"
LOG="$PKG/install.log"
mkdir -p "$PKG"

fail() {
    local rc="${1:-1}" line="${2:-unknown}" cmd="${3:-unknown}"
    trap - ERR
    set +e
    {
        echo "=================================================================="
        echo "VISGRID V10 LOAD-SAFE HOTFIX STOPPED"
        echo "=================================================================="
        echo "Date: $(date)"
        echo "Exit code: $rc"
        echo "Line: $line"
        echo "Command: $cmd"
        echo
        [ -f "$LOG" ] && tail -180 "$LOG" || true
        echo
        echo "No binary/source rebuild was performed by this hotfix."
        echo "Package preserved at:"
        echo "  $PKG"
    } | tee "$PKG/STOPPED_ERROR.txt"
    exit "$rc"
}
trap 'fail "$?" "$LINENO" "$BASH_COMMAND"' ERR
exec > >(tee "$LOG") 2>&1

echo "=================================================================="
echo "OPENMW 0.51 TSP — VISGRID V10 LOAD-SAFE HOTFIX"
echo "=================================================================="
echo
echo "Purpose:"
echo "  Keep VISGRID + percentile fog COMPLETELY DISARMED for 12 seconds"
echo "  after loading a save. No grid publish, sensor rays, or percentile"
echo "  fog can run during that post-load GL/OSG warmup window."
echo
echo "This is Lua-only. The OpenMW binary is not changed."
echo

command -v ssh >/dev/null
command -v scp >/dev/null
command -v python3 >/dev/null

echo "===== 1/6 VERIFY CURRENT V10 INSTALL ====="
if ssh "$DEV" 'pidof openmw-0.51 >/dev/null 2>&1 || pidof openmw >/dev/null 2>&1'; then
    echo "ERROR: OpenMW is running. Exit it normally and rerun."
    exit 20
fi

ssh "$DEV" "
set -e
test -s '$BIN'
test -s '$LUA'
grep -a -q 'TSP_INTERIOR_VISGRID_051_V1' '$BIN'
grep -a -q 'TSP_INTERIOR_VISGRID_051_V3_PERCENTILE_FOG' '$BIN'
grep -Fq 'TSP_INTERIOR_VISGRID_LUA_V10' '$LUA'
"
BIN_SHA_BEFORE="$(ssh "$DEV" "sha256sum '$BIN' | awk '{print \$1}'")"
LUA_SHA_BEFORE="$(ssh "$DEV" "sha256sum '$LUA' | awk '{print \$1}'")"
echo "Binary SHA: $BIN_SHA_BEFORE"
echo "Sensor SHA: $LUA_SHA_BEFORE"

echo
echo "===== 2/6 BACK UP ACTIVE SENSOR ====="
REMOTE_BACKUP="$ROOT/backups/visgrid-v10-loadsafe-$STAMP"
ssh "$DEV" "
set -e
mkdir -p '$REMOTE_BACKUP'
cp -p '$LUA' '$REMOTE_BACKUP/visgrid.lua.before-loadsafe'
test \"\$(sha256sum '$LUA' | awk '{print \$1}')\" = \
     \"\$(sha256sum '$REMOTE_BACKUP/visgrid.lua.before-loadsafe' | awk '{print \$1}')\"
sha256sum '$REMOTE_BACKUP/visgrid.lua.before-loadsafe' > '$REMOTE_BACKUP/SHA256SUMS.txt'
sync
"
scp -q "$DEV:$REMOTE_BACKUP/visgrid.lua.before-loadsafe" "$PKG/visgrid.lua.before-loadsafe"
[ "$(sha256sum "$PKG/visgrid.lua.before-loadsafe" | awk '{print $1}')" = "$LUA_SHA_BEFORE" ]
echo "PASS: exact active sensor backed up on device + VM."

echo
echo "===== 3/6 PATCH THE EXACT ACTIVE V10 SENSOR ====="
cp "$PKG/visgrid.lua.before-loadsafe" "$PKG/visgrid.lua.loadsafe"

python3 - "$PKG/visgrid.lua.loadsafe" <<'PY'
from pathlib import Path
import sys

p = Path(sys.argv[1])
s = p.read_text()

MARK = "TSP_VISGRID_V10_LOADSAFE"
if MARK in s:
    print("PASS: load-safe marker already present; leaving code unchanged.")
    raise SystemExit(0)

needles = [
    "TSP_INTERIOR_VISGRID_LUA_V10",
    "local justLoaded = true       -- first frame after chunk-load/onInit/onLoad\n",
    "local function resetRuntimeState()\n",
    "local function onFrame(dt)\n",
    "local function onLoad(_savedData, _initData)\n",
]
for needle in needles:
    if needle not in s:
        raise SystemExit(f"ERROR: expected V10 anchor missing: {needle!r}")

old = "local justLoaded = true       -- first frame after chunk-load/onInit/onLoad\n"
new = old + (
    "local POST_LOAD_ARM_DELAY = 12.0 -- V10.1: no grid/fog for 12s after loading a save\n"
    "local postLoadArmRemaining = 0.0\n"
)
if s.count(old) != 1:
    raise SystemExit(f"ERROR: justLoaded anchor count={s.count(old)}")
s = s.replace(old, new, 1)

old = """    justLoaded = true       -- first frame disarms BEFORE any enter logic
    vdState.cmd = nil
"""
new = """    justLoaded = true       -- first frame disarms BEFORE any enter logic
    postLoadArmRemaining = 0.0
    vdState.cmd = nil
"""
if s.count(old) != 1:
    raise SystemExit(f"ERROR: resetRuntimeState anchor count={s.count(old)}")
s = s.replace(old, new, 1)

old = """    if cell.isExterior then
        if inInterior then
            exitInterior()
        elseif gridMaybeArmed then
            safeDisarm('exterior-frame')
        end
        return
    end

    local okEye, eye = pcall(camera.getPosition)
"""
new = """    if cell.isExterior then
        if inInterior then
            exitInterior()
        elseif gridMaybeArmed then
            safeDisarm('exterior-frame')
        end
        return
    end

    -- TSP_VISGRID_V10_LOADSAFE
    -- A loaded interior arrives while this device is still rebuilding GL/OSG
    -- state for hundreds of frames. Keep the C++ grid completely disabled
    -- during that window. Percentile fog is gated by grid-enabled, so authored
    -- fog remains untouched until the hold expires.
    if postLoadArmRemaining > 0.0 then
        postLoadArmRemaining = max(0.0, postLoadArmRemaining - dt)
        if postLoadArmRemaining > 0.0 then
            return
        end
        print('[TSP_VISGRID_V10] load-safe hold complete -> VISGRID may arm')
    end

    local okEye, eye = pcall(camera.getPosition)
"""
if s.count(old) != 1:
    raise SystemExit(f"ERROR: onFrame load-safe insertion anchor count={s.count(old)}")
s = s.replace(old, new, 1)

old = """local function onLoad(_savedData, _initData)
    resetRuntimeState()
    print('[TSP_VISGRID_V10] onLoad -> runtime state initialized')
end
"""
new = """local function onLoad(_savedData, _initData)
    resetRuntimeState()
    postLoadArmRemaining = POST_LOAD_ARM_DELAY
    print(string.format(
        '[TSP_VISGRID_V10] onLoad -> runtime state initialized; grid/fog held %.1fs',
        POST_LOAD_ARM_DELAY))
end
"""
if s.count(old) != 1:
    raise SystemExit(f"ERROR: onLoad anchor count={s.count(old)}")
s = s.replace(old, new, 1)

for needle in (
    "TSP_VISGRID_V10_LOADSAFE",
    "local POST_LOAD_ARM_DELAY = 12.0",
    "postLoadArmRemaining = POST_LOAD_ARM_DELAY",
    "load-safe hold complete -> VISGRID may arm",
):
    if needle not in s:
        raise SystemExit("ERROR: postcondition missing: " + needle)

p.write_text(s)
print("PASS: V10 load-safe Lua patch applied.")
PY

grep -Fq 'TSP_VISGRID_V10_LOADSAFE' "$PKG/visgrid.lua.loadsafe"
grep -Fq 'POST_LOAD_ARM_DELAY = 12.0' "$PKG/visgrid.lua.loadsafe"
NEW_LUA_SHA="$(sha256sum "$PKG/visgrid.lua.loadsafe" | awk '{print $1}')"
echo "Patched sensor SHA: $NEW_LUA_SHA"

echo
echo "===== 4/6 INSTALL LUA ONLY ====="
scp -q "$PKG/visgrid.lua.loadsafe" "$DEV:/tmp/visgrid-v10-loadsafe.lua"
ssh "$DEV" "
set -e
test -s /tmp/visgrid-v10-loadsafe.lua
grep -Fq 'TSP_VISGRID_V10_LOADSAFE' /tmp/visgrid-v10-loadsafe.lua
cp /tmp/visgrid-v10-loadsafe.lua '$LUA.new'
mv -f '$LUA.new' '$LUA'
rm -f /tmp/visgrid-v10-loadsafe.lua
sync
test \"\$(sha256sum '$LUA' | awk '{print \$1}')\" = '$NEW_LUA_SHA'
"
echo "PASS: load-safe V10 sensor installed."

echo
echo "===== 5/6 VERIFY BINARY WAS NOT TOUCHED ====="
BIN_SHA_AFTER="$(ssh "$DEV" "sha256sum '$BIN' | awk '{print \$1}'")"
[ "$BIN_SHA_AFTER" = "$BIN_SHA_BEFORE" ] || {
    echo "ERROR: binary changed unexpectedly."
    exit 1
}
echo "PASS: binary unchanged sha256=$BIN_SHA_AFTER"

echo
echo "===== 6/6 CREATE ROLLBACK ====="
cat > "$PKG/rollback-v10-loadsafe.sh" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
DEV="\${TSP_DEV:-root@192.168.1.25}"
LUA="$LUA"
BACKUP="$REMOTE_BACKUP/visgrid.lua.before-loadsafe"
if ssh "\$DEV" 'pidof openmw-0.51 >/dev/null 2>&1 || pidof openmw >/dev/null 2>&1'; then
    echo "ERROR: exit OpenMW before rollback."
    exit 1
fi
ssh "\$DEV" "
set -e
test -s '\$BACKUP'
cp -p '\$BACKUP' '\$LUA'
sync
sha256sum '\$LUA'
"
echo "Restored exact pre-loadsafe V10 sensor."
EOF
chmod +x "$PKG/rollback-v10-loadsafe.sh"

mkdir -p "$TOOLS"
cp "$PKG/rollback-v10-loadsafe.sh" "$TOOLS/rollback-v10-loadsafe.sh"

echo
echo "=================================================================="
echo "V10 LOAD-SAFE HOTFIX INSTALLED"
echo "=================================================================="
echo "Expected save-load sequence:"
echo "  onLoad -> grid/fog held 12.0s"
echo "  load-safe hold complete -> VISGRID may arm"
echo "  enter interior -> grid active"
echo "  percentile fog becomes active only AFTER that"
echo
echo "Test the SAME save that just crashed."
echo
echo "While OpenMW is still running:"
echo "  ~/Downloads/visgrid-tools/pull-visgrid-print.sh"
echo
echo "Full trace:"
echo "  ~/Downloads/visgrid-tools/collect-visgrid-trace.sh"
echo
echo "Rollback:"
echo "  ~/Downloads/visgrid-tools/rollback-v10-loadsafe.sh"
echo "=================================================================="
