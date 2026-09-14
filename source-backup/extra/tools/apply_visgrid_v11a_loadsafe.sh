#!/usr/bin/env bash
# apply_visgrid_v11a_loadsafe.sh
#
# WHAT THIS FIXES
#   The V10 hotfix (TSP_VISGRID_V10_LOADSAFE_12S) held the sensor completely
#   off for 12 seconds after a save load, so it could not touch anything while
#   the device's prewarm / TSP_LOAD_FREEZE window was still running. The V11
#   rewrite DROPPED that hold - grep the shipped V11 sensor and there is not
#   one occurrence of postLoadArmRemaining.
#
#   The 2026-08-27 16:29 log shows the consequence exactly:
#       16:30:03.116  onLoad -> runtime state initialized
#       16:30:04.695  TSP_LOAD_FREEZE armed for 300 frames
#       16:30:04.703  enter interior "Caldera, Governor's Hall" -> grid active
#       16:30:07.247  <last line>            exit code 139 (SIGSEGV)
#   The sensor armed and fired a full entry raycast burst 8 ms after the
#   engine armed a 300-frame freeze, and the process died 2.5 s later.
#
#   This script reinstates the hold in V11 as V11a. Lua only - no rebuild,
#   the OpenMW binary is not touched, and the binary SHA is verified unchanged.
#
# It also DIAGNOSES (read-only) why the interior scan never produced
# tsp_interior_scan.txt, and prints a verdict.
set -Eeuo pipefail

if [ -f "$HOME/Downloads/visgrid-tools/device.env" ]; then
    # shellcheck disable=SC1091
    . "$HOME/Downloads/visgrid-tools/device.env" || true
fi
if [ -n "${TSP_IP:-}" ]; then DEV="root@$TSP_IP"; else DEV="${TSP_DEV:-root@192.168.1.25}"; fi

HOLD="${TSP_HOLD:-12.0}"
STAMP="$(date +%Y%m%d-%H%M%S)"
ROOT="/mnt/SDCARD/data/ports/openmw51"
BIN="$ROOT/bin/openmw-0.51"
MOD="$ROOT/mods/TSPInteriorVisGrid"
LUA="$MOD/scripts/TSPInteriorVisGrid/visgrid.lua"
TOOLS="$HOME/Downloads/visgrid-tools"
PKG="$HOME/Downloads/openmw51-visgrid-v11a-loadsafe-$STAMP"
LOG="$PKG/install.log"
mkdir -p "$PKG" "$TOOLS"

fail() {
    local rc="${1:-1}" line="${2:-unknown}" cmd="${3:-unknown}"
    trap - ERR
    set +e
    {
        echo
        echo "=================================================================="
        echo "V11a LOAD-SAFE HOTFIX STOPPED SAFELY"
        echo "=================================================================="
        echo "Date: $(date)"; echo "Exit code: $rc"; echo "Line: $line"; echo "Command: $cmd"
        echo
        [ -f "$LOG" ] && { echo "----- install.log tail -----"; tail -180 "$LOG"; }
        echo
        echo "No rebuild and no source edit is performed by this script."
        echo "Preserved at: $PKG"
    } | tee "$PKG/STOPPED_ERROR.txt"
    exit "$rc"
}
trap 'fail "$?" "$LINENO" "$BASH_COMMAND"' ERR
exec > >(tee "$LOG") 2>&1

echo "=================================================================="
echo "OPENMW 0.51 TSP - VISGRID V11a LOAD-SAFE HOLD (Lua only)"
echo "=================================================================="
echo "Device : $DEV"
echo "Hold   : ${HOLD}s after every (re)load before the sensor may arm"
echo

echo "===== 1/7 VERIFY DEVICE STATE + GAME CLOSED ====="
if ssh "$DEV" 'pidof openmw-0.51 >/dev/null 2>&1 || pidof openmw >/dev/null 2>&1'; then
    echo "ERROR: OpenMW is running. Exit it normally, then rerun this script."
    exit 20
fi
ssh "$DEV" "
set -e
test -s '$BIN'
test -s '$LUA'
grep -a -q 'TSP_INTERIOR_VISGRID_051_V1' '$BIN'
grep -a -q 'TSP_INTERIOR_VISGRID_051_V3_PERCENTILE_FOG' '$BIN'
grep -Fq 'TSP_INTERIOR_VISGRID_LUA_V11' '$LUA'
echo 'PASS: V11 sensor + V1/V3 engine markers present.'
"
BIN_SHA_BEFORE="$(ssh "$DEV" "sha256sum '$BIN' | awk '{print \$1}'")"
LUA_SHA_BEFORE="$(ssh "$DEV" "sha256sum '$LUA' | awk '{print \$1}'")"
echo "Binary SHA: $BIN_SHA_BEFORE"
echo "Sensor SHA: $LUA_SHA_BEFORE"

echo
echo "===== 2/7 DIAGNOSE THE INTERIOR SCAN (READ-ONLY) ====="
ssh "$DEV" "
echo -n '  scanner in binary        : '
if grep -a -q 'TSP_INTERIOR_SCAN_051_V1' '$BIN'; then echo 'YES'; else echo 'NO'; fi
echo -n '  tsp_interior_scan_cells  : '
if [ -s '$ROOT/tsp_interior_scan_cells.txt' ]; then echo \"YES (\$(wc -l < '$ROOT/tsp_interior_scan_cells.txt') cells)\"; else echo 'MISSING/EMPTY'; fi
echo -n '  tsp_scan_interiors.flag  : '
if [ -f '$ROOT/tsp_scan_interiors.flag' ]; then echo 'PRESENT (scan still armed)'; else echo 'ABSENT'; fi
echo -n '  tsp_interior_scan.txt    : '
if [ -s '$ROOT/tsp_interior_scan.txt' ]; then echo 'PRESENT'; else echo 'MISSING'; fi
echo -n '  interiormap.lua          : '
if [ -s '$MOD/scripts/TSPInteriorVisGrid/interiormap.lua' ]; then echo 'PRESENT'; else echo 'MISSING'; fi
" || true

LASTPKG="$(ls -1dt "$HOME"/Downloads/openmw51-interior-visgrid-v11-interior-map-*/ 2>/dev/null | head -1 || true)"
if [ -n "$LASTPKG" ] && [ -f "$LASTPKG/install.log" ]; then
    echo "  last V11 installer log   : $LASTPKG/install.log"
    echo "  --- what it said about the scan ---"
    grep -E "6/11|interior cells listed|content files unreadable|openmw.cfg unreadable|scan NOT armed|scan name list|SCAN_READY|raycast-only" \
        "$LASTPKG/install.log" | sed 's/^/    /' || echo "    (no scan lines found)"
else
    echo "  last V11 installer log   : not found under ~/Downloads"
fi

echo
echo "===== 3/7 BACK UP THE EXACT LIVE SENSOR ====="
REMOTE_BACKUP="$ROOT/backups/visgrid-v11a-loadsafe-$STAMP"
ssh "$DEV" "
set -e
mkdir -p '$REMOTE_BACKUP'
cp -p '$LUA' '$REMOTE_BACKUP/visgrid.lua.before-v11a'
test \"\$(sha256sum '$LUA' | awk '{print \$1}')\" = \"\$(sha256sum '$REMOTE_BACKUP/visgrid.lua.before-v11a' | awk '{print \$1}')\"
sha256sum '$REMOTE_BACKUP/visgrid.lua.before-v11a' > '$REMOTE_BACKUP/SHA256SUMS.txt'
sync
"
scp -q "$DEV:$REMOTE_BACKUP/visgrid.lua.before-v11a" "$PKG/visgrid.lua.before-v11a"
[ "$(sha256sum "$PKG/visgrid.lua.before-v11a" | awk '{print $1}')" = "$LUA_SHA_BEFORE" ]
echo "PASS: live sensor backed up + SHA-verified on device and VM."
echo "      $REMOTE_BACKUP/visgrid.lua.before-v11a"

echo
echo "===== 4/7 PATCH THE EXACT LIVE SENSOR ====="
cp "$PKG/visgrid.lua.before-v11a" "$PKG/visgrid-v11a.lua"

TSP_HOLD="$HOLD" python3 - "$PKG/visgrid-v11a.lua" <<'PYPATCH'
import sys, os
path = sys.argv[1]
DELAY = os.environ.get('TSP_HOLD', '12.0')
float(DELAY)
s = open(path, encoding='utf-8').read()

if "TSP_INTERIOR_VISGRID_LUA_V11" not in s:
    raise SystemExit("ERROR: the live sensor is not V11.")
if "TSP_VISGRID_V11_LOADSAFE" in s:
    print("PASS: live sensor already carries the load-safe hold; nothing to do.")
    raise SystemExit(0)

def sub(old, new, label):
    global s
    n = s.count(old)
    if n != 1:
        raise SystemExit("ERROR: anchor %s count=%d" % (label, n))
    s = s.replace(old, new, 1)

# A) state
old = "local justLoaded = true       -- first frame after chunk-load/onInit/onLoad\n"
sub(old, old +
    "-- TSP_VISGRID_V11_LOADSAFE_12S\n"
    "-- The device prewarm / TSP_LOAD_FREEZE runs for hundreds of frames after\n"
    "-- a save load. V10 held the sensor off for 12s through that window; the\n"
    "-- V11 rewrite dropped the hold, the sensor armed ~1.6s after onLoad and\n"
    "-- 8ms after the engine armed a 300-frame freeze. Reinstated here.\n"
    "local POST_LOAD_ARM_DELAY = " + DELAY + "\n"
    "local postLoadArmRemaining = 0.0\n"
    "local holdPrintElapsed = 0.0\n", "A/state")

# B) arm on every (re)load path: resetRuntimeState covers chunk-load, onInit, onLoad
old = "    justLoaded = true       -- first frame disarms BEFORE any enter logic\n"
sub(old, old +
    "    postLoadArmRemaining = POST_LOAD_ARM_DELAY  -- TSP_VISGRID_V11_LOADSAFE_12S\n"
    "    holdPrintElapsed = 0.0\n", "B/reset")

# C) the gate
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
        postLoadArmRemaining = 0.0
        if inInterior then
            exitInterior()
        elseif gridMaybeArmed then
            safeDisarm('exterior-frame')
        end
        return
    end

    -- TSP_VISGRID_V11_LOADSAFE_12S
    -- justLoaded above has already disarmed the engine grid. Now stay fully
    -- inert while the device rebuilds GL/OSG state for the loaded cell: no
    -- grid publish, no raycasts, no door polling, and therefore no
    -- percentile-fog override. The engine's prewarm owns these frames.
    if postLoadArmRemaining > 0.0 then
        postLoadArmRemaining = max(0.0, postLoadArmRemaining - dt)
        holdPrintElapsed = holdPrintElapsed + dt
        if postLoadArmRemaining > 0.0 then
            if holdPrintElapsed >= 3.0 then
                holdPrintElapsed = 0.0
                print(string.format(
                    '[TSP_VISGRID_V11] load-safe hold: %.1fs remaining',
                    postLoadArmRemaining))
            end
            return
        end
        print('[TSP_VISGRID_V11] load-safe hold complete -> VISGRID may arm')
    end

    local okEye, eye = pcall(camera.getPosition)
"""
sub(old, new, "C/gate")

# D+E) make the hold visible at load time
sub("""    print('[TSP_VISGRID_V11] onLoad -> runtime state initialized')""",
    """    print(string.format(
        '[TSP_VISGRID_V11] onLoad -> runtime state initialized; grid/fog held %.1fs',
        POST_LOAD_ARM_DELAY))""", "D/onLoad")
sub("""    print('[TSP_VISGRID_V11] onInit -> runtime state initialized')""",
    """    print(string.format(
        '[TSP_VISGRID_V11] onInit -> runtime state initialized; grid/fog held %.1fs',
        POST_LOAD_ARM_DELAY))""", "E/onInit")

for n in ("TSP_VISGRID_V11_LOADSAFE_12S", "POST_LOAD_ARM_DELAY",
          "postLoadArmRemaining = POST_LOAD_ARM_DELAY",
          "load-safe hold complete -> VISGRID may arm"):
    if n not in s:
        raise SystemExit("ERROR: postcondition missing: " + n)

open(path, 'w', encoding='utf-8').write(s)
print("PASS: live V11 sensor patched with the %ss load-safe hold." % DELAY)
PYPATCH

grep -Fq 'TSP_VISGRID_V11_LOADSAFE_12S' "$PKG/visgrid-v11a.lua"
grep -Fq 'load-safe hold complete -> VISGRID may arm' "$PKG/visgrid-v11a.lua"

# Optional Lua syntax check if any Lua is available on this VM.
LUABIN=""
for c in luajit lua5.1 lua5.4 lua texlua; do command -v "$c" >/dev/null 2>&1 && { LUABIN="$c"; break; }; done
if [ -n "$LUABIN" ]; then
    if [ "$LUABIN" = "texlua" ]; then
        printf 'local f,e=loadfile("%s") if not f then print("SYNTAX ERROR: "..tostring(e)) os.exit(1) end print("PASS: Lua syntax OK")\n' \
            "$PKG/visgrid-v11a.lua" > "$PKG/synchk.lua"
        texlua --luaonly "$PKG/synchk.lua"
    else
        "$LUABIN" -e "local f,e=loadfile('$PKG/visgrid-v11a.lua') if not f then print('SYNTAX ERROR: '..tostring(e)) os.exit(1) end print('PASS: Lua syntax OK')"
    fi
else
    echo "NOTE: no Lua interpreter on this VM - syntax was verified upstream before shipping."
fi

NEW_SHA="$(sha256sum "$PKG/visgrid-v11a.lua" | awk '{print $1}')"
echo "V11a sensor SHA: $NEW_SHA"

echo
echo "===== 5/7 INSTALL LUA ONLY ====="
scp -q "$PKG/visgrid-v11a.lua" "$DEV:/tmp/visgrid-v11a.lua"
ssh "$DEV" "
set -e
test -s /tmp/visgrid-v11a.lua
grep -Fq 'TSP_VISGRID_V11_LOADSAFE_12S' /tmp/visgrid-v11a.lua
mkdir -p '$MOD/sensors'
cp /tmp/visgrid-v11a.lua '$MOD/sensors/visgrid-v11a.lua'
cp /tmp/visgrid-v11a.lua '$LUA.new'
mv -f '$LUA.new' '$LUA'
rm -f /tmp/visgrid-v11a.lua
sync
test \"\$(sha256sum '$LUA' | awk '{print \$1}')\" = '$NEW_SHA'
grep -Fq 'TSP_VISGRID_V11_LOADSAFE_12S' '$LUA'
"
echo "PASS: V11a installed and SHA-verified (also staged at $MOD/sensors/visgrid-v11a.lua)."

echo
echo "===== 6/7 VERIFY THE BINARY WAS NOT TOUCHED ====="
BIN_SHA_AFTER="$(ssh "$DEV" "sha256sum '$BIN' | awk '{print \$1}'")"
[ "$BIN_SHA_AFTER" = "$BIN_SHA_BEFORE" ] || { echo "ERROR: binary changed unexpectedly."; exit 1; }
echo "PASS: OpenMW binary unchanged: $BIN_SHA_AFTER"

echo
echo "===== 7/7 ROLLBACK + LOG PULLER ====="
cat > "$TOOLS/rollback-v11a-loadsafe.sh" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
if [ -f "\$HOME/Downloads/visgrid-tools/device.env" ]; then . "\$HOME/Downloads/visgrid-tools/device.env" || true; fi
if [ -n "\${TSP_IP:-}" ]; then DEV="root@\$TSP_IP"; else DEV="\${TSP_DEV:-root@192.168.1.25}"; fi
if ssh "\$DEV" 'pidof openmw-0.51 >/dev/null 2>&1 || pidof openmw >/dev/null 2>&1'; then
    echo "ERROR: exit OpenMW before rollback."; exit 1
fi
ssh "\$DEV" "
set -e
test -s '$REMOTE_BACKUP/visgrid.lua.before-v11a'
cp -p '$REMOTE_BACKUP/visgrid.lua.before-v11a' '$LUA'
sync
sha256sum '$LUA'
"
echo "Restored the exact pre-V11a sensor."
EOF
chmod +x "$TOOLS/rollback-v11a-loadsafe.sh"

cat > "$TOOLS/pull-v11a-loadsafe.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
if [ -f "$HOME/Downloads/visgrid-tools/device.env" ]; then . "$HOME/Downloads/visgrid-tools/device.env" || true; fi
if [ -n "${TSP_IP:-}" ]; then DEV="root@$TSP_IP"; else DEV="${TSP_DEV:-root@192.168.1.25}"; fi
R=/mnt/SDCARD/data/ports/openmw51
OUT="$HOME/Downloads/v11a-loadsafe-$(date +%Y%m%d-%H%M%S).txt"
{
  echo "===== DEVICE ====="; ssh "$DEV" 'hostname; date'
  echo; echo "===== HOLD / VISGRID / LOAD / CRASH LINES ====="
  ssh "$DEV" "grep -hE 'TSP_VISGRID_V11|load-safe hold|TSP_INTERIOR_VISGRID_051_V[13]|TSP_INTERIOR_SCAN_051_V1|PERCENTILE_FOG|TSP_LOAD_FREEZE|TSP_LOAD_TRACE|TSP_WARMDRAW|Lua.*error|ERROR.*Lua|SIGSEGV|exited with code' $R/openmw_051_log.txt 2>/dev/null | tail -400 || true"
  echo; echo "===== SCAN FILES ====="
  ssh "$DEV" "ls -l $R/tsp_interior_scan*.txt $R/tsp_scan_interiors.flag $R/mods/TSPInteriorVisGrid/scripts/TSPInteriorVisGrid/interiormap.lua 2>&1 || true"
  echo; echo "===== CRASH TAIL (last 200) ====="
  ssh "$DEV" '[ -f /mnt/SDCARD/tsp_crash.txt ] && tail -200 /mnt/SDCARD/tsp_crash.txt || true'
  echo; echo "===== HASHES ====="
  ssh "$DEV" "sha256sum $R/bin/openmw-0.51 $R/mods/TSPInteriorVisGrid/scripts/TSPInteriorVisGrid/visgrid.lua 2>/dev/null || true"
} 2>&1 | tee "$OUT"
echo; echo "Saved: $OUT"
EOF
chmod +x "$TOOLS/pull-v11a-loadsafe.sh"
echo "PASS: helpers written."

echo
echo "=================================================================="
echo "V11a INSTALLED - NO REBUILD, BINARY UNTOUCHED"
echo "=================================================================="
echo "Backup : $REMOTE_BACKUP/visgrid.lua.before-v11a"
echo "         $PKG/visgrid.lua.before-v11a"
echo
echo "Launch Morrowind_51 and load the SAME save that crashed. Expect:"
echo "  [TSP_VISGRID_V11] onLoad -> runtime state initialized; grid/fog held ${HOLD}s"
echo "  [TSP_VISGRID_V11] load-safe hold: 9.0s remaining"
echo "  [TSP_VISGRID_V11] load-safe hold: 6.0s remaining ..."
echo "  [TSP_VISGRID_V11] load-safe hold complete -> VISGRID may arm"
echo "  [TSP_VISGRID_V11] enter interior \"...\" -> wall-model grid active"
echo
echo "Then pull everything with ONE command:"
echo "  ~/Downloads/visgrid-tools/pull-v11a-loadsafe.sh"
echo
echo "Rollback:"
echo "  ~/Downloads/visgrid-tools/rollback-v11a-loadsafe.sh"
echo "=================================================================="
