#!/usr/bin/env bash
set -Eeuo pipefail

STAMP="$(date +%Y%m%d-%H%M%S)"
ROOT="/mnt/SDCARD/data/ports/openmw51"
BIN="$ROOT/bin/openmw-0.51"
LUA="$ROOT/mods/TSPInteriorVisGrid/scripts/TSPInteriorVisGrid/visgrid.lua"
OMW="$ROOT/mods/TSPInteriorVisGrid/TSPInteriorVisGrid.omwscripts"
TOOLS="$HOME/Downloads/visgrid-tools"
PKG="$HOME/Downloads/openmw51-visgrid-v10-savecrash-fix-$STAMP"
LOG="$PKG/install.log"

mkdir -p "$PKG" "$TOOLS"

fail_report() {
    local rc="${1:-1}" line="${2:-unknown}" cmd="${3:-unknown}"
    trap - ERR
    set +e
    {
        echo
        echo "=================================================================="
        echo "V10 SAVE-CRASH FIX STOPPED SAFELY"
        echo "=================================================================="
        echo "Date: $(date)"
        echo "Exit code: $rc"
        echo "Line: $line"
        echo "Command: $cmd"
        echo
        [ -f "$LOG" ] && {
            echo "----- install.log tail -----"
            tail -180 "$LOG" || true
        }
        echo
        echo "No OpenMW rebuild/source edit is performed by this script."
        echo "Anything created so far is preserved at:"
        echo "  $PKG"
        echo "=================================================================="
    } | tee "$PKG/STOPPED_ERROR.txt"
    exit "$rc"
}
trap 'fail_report "$?" "$LINENO" "$BASH_COMMAND"' ERR
exec > >(tee "$LOG") 2>&1

echo "=================================================================="
echo "OPENMW 0.51 TSP — VISGRID V10 SAVE-LOAD CRASH FIX"
echo "=================================================================="
echo
echo "This script:"
echo "  - auto-detects the TrimUI instead of assuming 192.168.1.25"
echo "  - DOES NOT rebuild OpenMW"
echo "  - backs up the exact live V10 sensor"
echo "  - keeps VISGRID + percentile fog off for 12 seconds after save-load"
echo "  - installs only the patched Lua sensor"
echo "  - verifies the OpenMW binary SHA did not change"
echo

command -v ssh >/dev/null
command -v scp >/dev/null
command -v python3 >/dev/null
command -v ip >/dev/null

SSH_BASE=(
    -o BatchMode=yes
    -o ConnectTimeout=3
    -o ConnectionAttempts=1
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -o LogLevel=ERROR
)

device_is_openmw() {
    local ipaddr="$1"
    ssh "${SSH_BASE[@]}" "root@$ipaddr" \
        "test -s '$BIN' && test -s '$LUA' && test -s '$OMW'" \
        >/dev/null 2>&1
}

discover_device() {
    local candidates=()
    local ipaddr=""

    # Explicit override wins if supplied.
    if [ -n "${TSP_IP:-}" ]; then
        if device_is_openmw "$TSP_IP"; then
            printf '%s\n' "$TSP_IP"
            return 0
        fi
        echo "NOTE: TSP_IP=$TSP_IP is not currently reachable as the OpenMW device." >&2
    fi

    # Try the historical address first, but never depend on it.
    if device_is_openmw "192.168.1.25"; then
        printf '%s\n' "192.168.1.25"
        return 0
    fi

    # Try neighbors already known to Linux before scanning.
    while read -r ipaddr; do
        [ -n "$ipaddr" ] && candidates+=("$ipaddr")
    done < <(ip -4 neigh show 2>/dev/null | awk '$1 ~ /^[0-9]+\./ {print $1}' | sort -u)

    for ipaddr in "${candidates[@]}"; do
        if device_is_openmw "$ipaddr"; then
            printf '%s\n' "$ipaddr"
            return 0
        fi
    done

    # Finally scan port 22 on the host's /24 in parallel.
    local host_ip
    host_ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '
        { for (i=1; i<=NF; ++i) if ($i=="src") { print $(i+1); exit } }
    ')"

    if [ -z "$host_ip" ]; then
        return 1
    fi

    mapfile -t candidates < <(python3 - "$host_ip" <<'PY'
import concurrent.futures, ipaddress, socket, sys

host = ipaddress.ip_address(sys.argv[1])
net = ipaddress.ip_network(f"{host}/24", strict=False)

def port22(ip):
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(0.22)
    try:
        return str(ip) if s.connect_ex((str(ip), 22)) == 0 else None
    finally:
        s.close()

with concurrent.futures.ThreadPoolExecutor(max_workers=64) as ex:
    found = [x for x in ex.map(port22, net.hosts()) if x]
for x in found:
    print(x)
PY
)

    for ipaddr in "${candidates[@]}"; do
        if device_is_openmw "$ipaddr"; then
            printf '%s\n' "$ipaddr"
            return 0
        fi
    done

    return 1
}

echo "===== 1/7 FIND THE TRIMUI ====="
if ! TSP_IP_FOUND="$(discover_device)"; then
    cat <<'EOF'
ERROR: I could not find a reachable TrimUI running SSH on this LAN.

Nothing was changed.

On the TrimUI, make sure:
  - it is powered on
  - Wi-Fi is connected
  - SSH is enabled

Then rerun THIS SAME script. You do not need to edit an IP address.
EOF
    exit 21
fi

DEV="root@$TSP_IP_FOUND"
echo "PASS: found TrimUI OpenMW install at $DEV"
printf 'TSP_IP=%q\n' "$TSP_IP_FOUND" > "$TOOLS/device.env"

echo
echo "===== 2/7 VERIFY CURRENT V10 + GAME CLOSED ====="
if ssh "${SSH_BASE[@]}" "$DEV" \
    'pidof openmw-0.51 >/dev/null 2>&1 || pidof openmw >/dev/null 2>&1'
then
    echo "ERROR: OpenMW is still running."
    echo "Exit Morrowind normally, then rerun THIS SAME script."
    exit 20
fi

ssh "${SSH_BASE[@]}" "$DEV" "
set -e
test -s '$BIN'
test -s '$LUA'
test -s '$OMW'
grep -a -q 'TSP_INTERIOR_VISGRID_051_V1' '$BIN'
grep -a -q 'TSP_INTERIOR_VISGRID_051_V3_PERCENTILE_FOG' '$BIN'
grep -Fq 'TSP_INTERIOR_VISGRID_LUA_V10' '$LUA'
grep -Fq 'PLAYER: scripts/TSPInteriorVisGrid/visgrid.lua' '$OMW'
"

BIN_SHA_BEFORE="$(ssh "${SSH_BASE[@]}" "$DEV" "sha256sum '$BIN' | awk '{print \$1}'")"
LUA_SHA_BEFORE="$(ssh "${SSH_BASE[@]}" "$DEV" "sha256sum '$LUA' | awk '{print \$1}'")"
echo "Binary SHA: $BIN_SHA_BEFORE"
echo "Sensor SHA: $LUA_SHA_BEFORE"
echo "PASS: current percentile-fog V10 install verified."

echo
echo "===== 3/7 BACK UP EXACT LIVE SENSOR ====="
REMOTE_BACKUP="$ROOT/backups/visgrid-v10-savecrash-fix-$STAMP"

ssh "${SSH_BASE[@]}" "$DEV" "
set -e
mkdir -p '$REMOTE_BACKUP'
cp -p '$LUA' '$REMOTE_BACKUP/visgrid.lua.before-savecrash-fix'
cp -p '$OMW' '$REMOTE_BACKUP/TSPInteriorVisGrid.omwscripts.before-savecrash-fix'
test \"\$(sha256sum '$LUA' | awk '{print \$1}')\" = \
     \"\$(sha256sum '$REMOTE_BACKUP/visgrid.lua.before-savecrash-fix' | awk '{print \$1}')\"
test \"\$(sha256sum '$OMW' | awk '{print \$1}')\" = \
     \"\$(sha256sum '$REMOTE_BACKUP/TSPInteriorVisGrid.omwscripts.before-savecrash-fix' | awk '{print \$1}')\"
sha256sum \
  '$REMOTE_BACKUP/visgrid.lua.before-savecrash-fix' \
  '$REMOTE_BACKUP/TSPInteriorVisGrid.omwscripts.before-savecrash-fix' \
  > '$REMOTE_BACKUP/SHA256SUMS.txt'
sync
"

scp "${SSH_BASE[@]}" -q \
    "$DEV:$REMOTE_BACKUP/visgrid.lua.before-savecrash-fix" \
    "$PKG/visgrid.lua.before-savecrash-fix"
scp "${SSH_BASE[@]}" -q \
    "$DEV:$REMOTE_BACKUP/TSPInteriorVisGrid.omwscripts.before-savecrash-fix" \
    "$PKG/TSPInteriorVisGrid.omwscripts.before-savecrash-fix"

[ "$(sha256sum "$PKG/visgrid.lua.before-savecrash-fix" | awk '{print $1}')" = "$LUA_SHA_BEFORE" ]
echo "PASS: live sensor backed up + SHA-verified on device and Ubuntu."

echo
echo "===== 4/7 PATCH THE LIVE V10 SENSOR ====="
cp "$PKG/visgrid.lua.before-savecrash-fix" "$PKG/visgrid.lua.fixed"

python3 - "$PKG/visgrid.lua.fixed" <<'PY'
from pathlib import Path
import re, sys

p = Path(sys.argv[1])
s = p.read_text()

if "TSP_INTERIOR_VISGRID_LUA_V10" not in s:
    raise SystemExit("ERROR: active sensor is not V10.")

MARK = "TSP_VISGRID_V10_LOADSAFE_12S"
if MARK in s:
    print("PASS: active sensor already contains the 12s load-safe fix.")
    raise SystemExit(0)

# 1) Add hold state beside the existing justLoaded declaration.
pat = re.compile(r'(?m)^(local\s+justLoaded\s*=\s*true[^\n]*\n)')
m = list(pat.finditer(s))
if len(m) != 1:
    raise SystemExit(f"ERROR: expected one justLoaded declaration, found {len(m)}")

addition = (
    m[0].group(1)
    + "local POST_LOAD_ARM_DELAY = 12.0 -- TSP_VISGRID_V10_LOADSAFE_12S\n"
    + "local postLoadArmRemaining = 0.0\n"
)
s = s[:m[0].start()] + addition + s[m[0].end():]

# 2) After exterior handling, hold the grid fully disarmed.
anchor = """    if cell.isExterior then
        if inInterior then
            exitInterior()
        elseif gridMaybeArmed then
            safeDisarm('exterior-frame')
        end
        return
    end

    local okEye, eye = pcall(camera.getPosition)
"""
replacement = """    if cell.isExterior then
        postLoadArmRemaining = 0.0
        if inInterior then
            exitInterior()
        elseif gridMaybeArmed then
            safeDisarm('exterior-frame')
        end
        return
    end

    -- TSP_VISGRID_V10_LOADSAFE_12S
    -- The first post-load frame already calls safeDisarm() above. Stay inert
    -- while GL4ES/OSG rebuilds the loaded cell: no grid publish, no raycasts,
    -- and therefore no percentile-fog override.
    if postLoadArmRemaining > 0.0 then
        postLoadArmRemaining = math.max(0.0, postLoadArmRemaining - dt)
        if postLoadArmRemaining > 0.0 then
            return
        end
        print('[TSP_VISGRID_V10] load-safe hold complete -> VISGRID may arm')
    end

    local okEye, eye = pcall(camera.getPosition)
"""
if s.count(anchor) != 1:
    raise SystemExit(
        "ERROR: exact onFrame exterior/camera anchor not found once; "
        f"count={s.count(anchor)}. No patched file written."
    )
s = s.replace(anchor, replacement, 1)

# 3) onLoad must explicitly start the hold after resetRuntimeState().
pat_load = re.compile(
    r"""local function onLoad\(_savedData,\s*_initData\)\n"""
    r"""    resetRuntimeState\(\)\n"""
    r"""    print\('\[TSP_VISGRID_V10\] onLoad -> runtime state initialized'\)\n"""
    r"""end"""
)
matches = list(pat_load.finditer(s))
if len(matches) != 1:
    raise SystemExit(f"ERROR: expected one V10 onLoad block, found {len(matches)}")

new_load = """local function onLoad(_savedData, _initData)
    resetRuntimeState()
    postLoadArmRemaining = POST_LOAD_ARM_DELAY
    print(string.format(
        '[TSP_VISGRID_V10] onLoad -> runtime state initialized; grid/fog held %.1fs',
        POST_LOAD_ARM_DELAY))
end"""
s = s[:matches[0].start()] + new_load + s[matches[0].end():]

for needle in (
    "TSP_VISGRID_V10_LOADSAFE_12S",
    "POST_LOAD_ARM_DELAY = 12.0",
    "postLoadArmRemaining = POST_LOAD_ARM_DELAY",
    "load-safe hold complete -> VISGRID may arm",
):
    if needle not in s:
        raise SystemExit("ERROR: postcondition missing: " + needle)

p.write_text(s)
print("PASS: live V10 sensor patched with 12-second save-load hold.")
PY

grep -Fq 'TSP_VISGRID_V10_LOADSAFE_12S' "$PKG/visgrid.lua.fixed"
grep -Fq 'POST_LOAD_ARM_DELAY = 12.0' "$PKG/visgrid.lua.fixed"
NEW_SHA="$(sha256sum "$PKG/visgrid.lua.fixed" | awk '{print $1}')"
echo "Fixed sensor SHA: $NEW_SHA"

echo
echo "===== 5/7 INSTALL LUA ONLY ====="
scp "${SSH_BASE[@]}" -q "$PKG/visgrid.lua.fixed" "$DEV:/tmp/visgrid.lua.savecrash-fix"

ssh "${SSH_BASE[@]}" "$DEV" "
set -e
test -s /tmp/visgrid.lua.savecrash-fix
grep -Fq 'TSP_VISGRID_V10_LOADSAFE_12S' /tmp/visgrid.lua.savecrash-fix
cp /tmp/visgrid.lua.savecrash-fix '$LUA.new'
mv -f '$LUA.new' '$LUA'
rm -f /tmp/visgrid.lua.savecrash-fix
sync
test \"\$(sha256sum '$LUA' | awk '{print \$1}')\" = '$NEW_SHA'
grep -Fq 'TSP_VISGRID_V10_LOADSAFE_12S' '$LUA'
"
echo "PASS: fixed sensor installed."

echo
echo "===== 6/7 VERIFY BINARY UNCHANGED ====="
BIN_SHA_AFTER="$(ssh "${SSH_BASE[@]}" "$DEV" "sha256sum '$BIN' | awk '{print \$1}'")"
if [ "$BIN_SHA_AFTER" != "$BIN_SHA_BEFORE" ]; then
    echo "ERROR: OpenMW binary changed unexpectedly."
    exit 1
fi
echo "PASS: OpenMW binary untouched: $BIN_SHA_AFTER"

echo
echo "===== 7/7 WRITE STABLE ROLLBACK + CRASH PULLER ====="

cat > "$TOOLS/rollback-v10-savecrash-fix.sh" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
IP="${TSP_IP_FOUND}"
DEV="root@\$IP"
SSH=(-o BatchMode=yes -o ConnectTimeout=4 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)
LUA="$LUA"
BACKUP="$REMOTE_BACKUP/visgrid.lua.before-savecrash-fix"
if ssh "\${SSH[@]}" "\$DEV" 'pidof openmw-0.51 >/dev/null 2>&1 || pidof openmw >/dev/null 2>&1'; then
  echo "ERROR: exit OpenMW before rollback."
  exit 1
fi
ssh "\${SSH[@]}" "\$DEV" "
set -e
test -s '\$BACKUP'
cp -p '\$BACKUP' '\$LUA'
sync
sha256sum '\$LUA'
"
echo "Restored exact pre-fix V10 sensor."
EOF
chmod +x "$TOOLS/rollback-v10-savecrash-fix.sh"

cat > "$TOOLS/pull-v10-savecrash-test.sh" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
IP="${TSP_IP_FOUND}"
DEV="root@\$IP"
SSH=(-o BatchMode=yes -o ConnectTimeout=4 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)
STAMP="\$(date +%Y%m%d-%H%M%S)"
OUT="\$HOME/Downloads/v10-savecrash-test-\$STAMP.txt"
{
  echo "===== DEVICE ====="
  ssh "\${SSH[@]}" "\$DEV" 'hostname; date'
  echo
  echo "===== V10 / LOAD / FOG / CRASH-RELEVANT LOG ====="
  ssh "\${SSH[@]}" "\$DEV" '
    grep -hE "TSP_VISGRID_V10|TSP_INTERIOR_VISGRID_051_V[13]|PERCENTILE_FOG|TSP_LOAD_TRACE|TSP_LOAD_FREEZE|TSP_DEPTH_PROJECTION|Lua.*error|ERROR.*Lua|Segmentation|SIGSEGV" \
      /mnt/SDCARD/data/ports/openmw51/openmw_051_log.txt \
      /mnt/SDCARD/data/ports/openmw51/config-0.51/openmw.log \
      2>/dev/null | tail -1800 || true
  '
  echo
  echo "===== PERFORMANCE TAIL ====="
  ssh "\${SSH[@]}" "\$DEV" '
    [ -f /mnt/SDCARD/data/ports/openmw51/openmw51_perf_latest.txt ] &&
      tail -250 /mnt/SDCARD/data/ports/openmw51/openmw51_perf_latest.txt || true
  '
  echo
  echo "===== CRASH TAIL ====="
  ssh "\${SSH[@]}" "\$DEV" '
    [ -f /mnt/SDCARD/tsp_crash.txt ] && tail -500 /mnt/SDCARD/tsp_crash.txt || true
  '
  echo
  echo "===== INSTALLED HASHES ====="
  ssh "\${SSH[@]}" "\$DEV" '
    sha256sum \
      /mnt/SDCARD/data/ports/openmw51/bin/openmw-0.51 \
      /mnt/SDCARD/data/ports/openmw51/mods/TSPInteriorVisGrid/scripts/TSPInteriorVisGrid/visgrid.lua \
      2>/dev/null || true
  '
} 2>&1 | tee "\$OUT"
echo
echo "Saved: \$OUT"
EOF
chmod +x "$TOOLS/pull-v10-savecrash-test.sh"

echo
echo "=================================================================="
echo "DONE — NO REBUILD WAS PERFORMED"
echo "=================================================================="
echo "TrimUI detected at: $TSP_IP_FOUND"
echo
echo "Now launch OpenMW and load the SAME save that crashed."
echo
echo "Expected:"
echo "  1. save loads normally"
echo "  2. V10 remains completely off for 12 seconds"
echo "  3. then: load-safe hold complete -> VISGRID may arm"
echo
echo "If it crashes OR survives, pull everything with ONE command:"
echo
echo "  ~/Downloads/visgrid-tools/pull-v10-savecrash-test.sh"
echo
echo "Rollback:"
echo "  ~/Downloads/visgrid-tools/rollback-v10-savecrash-fix.sh"
echo "=================================================================="
