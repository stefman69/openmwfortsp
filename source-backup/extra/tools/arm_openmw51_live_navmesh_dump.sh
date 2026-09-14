#!/usr/bin/env bash
set -Eeuo pipefail

STAMP="$(date +%Y%m%d-%H%M%S)"
ROOT="/mnt/SDCARD/data/ports/openmw51"
MOD="$ROOT/mods/TSPInteriorVisGrid"
BIN="$ROOT/bin/openmw-0.51"
LUA="$MOD/scripts/TSPInteriorVisGrid/visgrid.lua"
SETTINGS="$ROOT/config-0.51/settings.cfg"
DUMPDIR="$ROOT/tsp-navdump"
PREFIX="$DUMPDIR/${STAMP}-"
REMOTE_BAK="$ROOT/backups/navmesh-dump-$STAMP"
TOOLS="$HOME/Downloads/visgrid-tools"
PKG="$HOME/Downloads/openmw51-navmesh-dump-$STAMP"
LOG="$PKG/arm.log"

mkdir -p "$PKG/device-backup" "$TOOLS"

if [ -f "$TOOLS/device.env" ]; then
    # shellcheck disable=SC1091
    . "$TOOLS/device.env" || true
fi
if [ -n "${TSP_IP:-}" ]; then
    DEV="root@$TSP_IP"
else
    DEV="${TSP_DEV:-root@192.168.1.25}"
fi

SSH=(-o BatchMode=yes -o ConnectTimeout=8)

ROLLBACK_NEEDED=0
SETTINGS_SHA_BEFORE=""
BIN_SHA_BEFORE=""
LUA_SHA_BEFORE=""

fail_report() {
    local rc="${1:-1}" line="${2:-unknown}" cmd="${3:-unknown}"
    trap - ERR
    set +e

    if [ "$ROLLBACK_NEEDED" = 1 ]; then
        echo
        echo "Attempting automatic settings rollback..."
        ssh "${SSH[@]}" "$DEV" "
          set -e
          test -s '$REMOTE_BAK/settings.cfg.before'
          cp -p '$REMOTE_BAK/settings.cfg.before' '$SETTINGS'
          sync
          test \"\$(sha256sum '$SETTINGS' | awk '{print \$1}')\" = '$SETTINGS_SHA_BEFORE'
        " && echo "PASS: original settings.cfg restored." \
          || echo "WARNING: automatic rollback failed; backup remains at $REMOTE_BAK"
    fi

    {
        echo
        echo "=================================================================="
        echo "NAVMESH DUMP ARM STOPPED SAFELY"
        echo "=================================================================="
        echo "Date: $(date)"
        echo "Exit code: $rc"
        echo "Line: $line"
        echo "Command: $cmd"
        echo
        [ -f "$LOG" ] && { echo "----- arm.log tail -----"; tail -180 "$LOG" || true; }
        echo
        echo "Package preserved at:"
        echo "  $PKG"
        echo "=================================================================="
    } | tee "$PKG/STOPPED_ERROR.txt"

    exit "$rc"
}
trap 'fail_report "$?" "$LINENO" "$BASH_COMMAND"' ERR
exec > >(tee "$LOG") 2>&1

echo "=================================================================="
echo "OPENMW 0.51 TSP — ARM ONE-LAUNCH LIVE NAVMESH DUMP"
echo "=================================================================="
echo
echo "NO rebuild."
echo "NO source edit."
echo "NO VISGRID sensor edit."
echo "V14's 12-second post-load safety hold must remain installed."
echo
echo "This temporarily enables OpenMW's built-in Detour navmesh writer."
echo "The original settings.cfg is restored by the finish/rollback helper."
echo

command -v ssh >/dev/null
command -v scp >/dev/null
command -v python3 >/dev/null

echo "===== 1/7 VERIFY DEVICE + GAME CLOSED + V14 LOAD SAFETY ====="
ssh "${SSH[@]}" "$DEV" "
set -e
test -s '$BIN'
test -s '$LUA'
test -f '$SETTINGS'
grep -a -q 'TSP_INTERIOR_VISGRID_051_V1' '$BIN'
grep -Fq 'TSP_VISGRID_LUA_V14_MAPSYNC' '$LUA'
grep -Fq 'TSP_VISGRID_V11_LOADSAFE_12S' '$LUA'
grep -Fq 'POST_LOAD_ARM_DELAY = 12.0' '$LUA'
"
if ssh "${SSH[@]}" "$DEV" 'pidof openmw-0.51 >/dev/null 2>&1 || pidof openmw >/dev/null 2>&1'; then
    echo "ERROR: OpenMW is running. Exit it normally, then rerun this same script."
    exit 20
fi

BIN_SHA_BEFORE="$(ssh "${SSH[@]}" "$DEV" "sha256sum '$BIN' | awk '{print \$1}'")"
LUA_SHA_BEFORE="$(ssh "${SSH[@]}" "$DEV" "sha256sum '$LUA' | awk '{print \$1}'")"
SETTINGS_SHA_BEFORE="$(ssh "${SSH[@]}" "$DEV" "sha256sum '$SETTINGS' | awk '{print \$1}'")"

echo "Binary SHA : $BIN_SHA_BEFORE"
echo "Sensor SHA : $LUA_SHA_BEFORE"
echo "Settings   : $SETTINGS_SHA_BEFORE"
echo "PASS: V14 + exact 12.0s load-safe hold verified."

echo
echo "===== 2/7 BACK UP EXACT ACTIVE SETTINGS ====="
ssh "${SSH[@]}" "$DEV" "
set -e
mkdir -p '$REMOTE_BAK' '$DUMPDIR'
cp -p '$SETTINGS' '$REMOTE_BAK/settings.cfg.before'
test \"\$(sha256sum '$REMOTE_BAK/settings.cfg.before' | awk '{print \$1}')\" = '$SETTINGS_SHA_BEFORE'
printf '%s\n' '$BIN_SHA_BEFORE  $BIN' '$LUA_SHA_BEFORE  $LUA' '$SETTINGS_SHA_BEFORE  $SETTINGS' \
  > '$REMOTE_BAK/SHA256SUMS.before.txt'
sync
"

scp "${SSH[@]}" -q "$DEV:$REMOTE_BAK/settings.cfg.before" "$PKG/device-backup/settings.cfg.before"
[ "$(sha256sum "$PKG/device-backup/settings.cfg.before" | awk '{print $1}')" = "$SETTINGS_SHA_BEFORE" ]
echo "PASS: settings backup SHA-verified on device and Ubuntu."

echo
echo "===== 3/7 BUILD TEMPORARY NAVIGATOR SETTINGS LOCALLY ====="
cp -p "$PKG/device-backup/settings.cfg.before" "$PKG/settings.cfg.navdump"

python3 - "$PKG/settings.cfg.navdump" "$PREFIX" <<'PY'
from pathlib import Path
import re, sys

path = Path(sys.argv[1])
prefix = sys.argv[2]
raw = path.read_text(encoding='utf-8', errors='surrogateescape')
lines = raw.splitlines(True)

keys = {
    'enable write nav mesh to file': 'true',
    'enable nav mesh file name revision': 'false',
    'nav mesh path prefix': prefix,
}

section_re = re.compile(r'^\s*\[([^\]]+)\]\s*(?:[#;].*)?$')
key_re = re.compile(r'^\s*([^#;=\r\n]+?)\s*=')

# Remove every existing target-key assignment inside every [Navigator] section.
out = []
in_nav = False
last_nav_insert = None
for line in lines:
    sm = section_re.match(line.rstrip('\r\n'))
    if sm:
        in_nav = sm.group(1).strip().lower() == 'navigator'
        out.append(line)
        if in_nav:
            last_nav_insert = len(out)
        continue

    if in_nav:
        km = key_re.match(line)
        if km and km.group(1).strip().lower() in keys:
            continue

    out.append(line)
    if in_nav:
        last_nav_insert = len(out)

if last_nav_insert is None:
    if out and not out[-1].endswith(('\n', '\r')):
        out[-1] += '\n'
    if out and out[-1].strip():
        out.append('\n')
    out.append('[Navigator]\n')
    last_nav_insert = len(out)

inject = [
    '\n',
    '# TSP one-launch topology/navmesh capture; restored byte-for-byte afterward.\n',
    'enable write nav mesh to file = true\n',
    'enable nav mesh file name revision = false\n',
    f'nav mesh path prefix = {prefix}\n',
]

out[last_nav_insert:last_nav_insert] = inject
path.write_text(''.join(out), encoding='utf-8', errors='surrogateescape')

s = path.read_text(encoding='utf-8', errors='replace')
for needle in (
    'enable write nav mesh to file = true',
    'enable nav mesh file name revision = false',
    f'nav mesh path prefix = {prefix}',
):
    if s.count(needle) != 1:
        raise SystemExit(f'ERROR: expected exactly one [{needle}], found {s.count(needle)}')

print('PASS: temporary [Navigator] dump settings prepared.')
PY

TEMP_SETTINGS_SHA="$(sha256sum "$PKG/settings.cfg.navdump" | awk '{print $1}')"
echo "Temporary settings SHA: $TEMP_SETTINGS_SHA"

echo
echo "===== 4/7 INSTALL TEMP SETTINGS ONLY ====="
ROLLBACK_NEEDED=1
scp "${SSH[@]}" -q "$PKG/settings.cfg.navdump" "$DEV:$SETTINGS.navdump-new"
ssh "${SSH[@]}" "$DEV" "
set -e
test \"\$(sha256sum '$SETTINGS.navdump-new' | awk '{print \$1}')\" = '$TEMP_SETTINGS_SHA'
mv -f '$SETTINGS.navdump-new' '$SETTINGS'
sync
test \"\$(sha256sum '$SETTINGS' | awk '{print \$1}')\" = '$TEMP_SETTINGS_SHA'
grep -Fq 'enable write nav mesh to file = true' '$SETTINGS'
grep -Fq 'enable nav mesh file name revision = false' '$SETTINGS'
grep -Fq 'nav mesh path prefix = $PREFIX' '$SETTINGS'
"
echo "PASS: only settings.cfg changed."

echo
echo "===== 5/7 VERIFY BINARY + VISGRID SENSOR UNCHANGED ====="
BIN_SHA_NOW="$(ssh "${SSH[@]}" "$DEV" "sha256sum '$BIN' | awk '{print \$1}'")"
LUA_SHA_NOW="$(ssh "${SSH[@]}" "$DEV" "sha256sum '$LUA' | awk '{print \$1}'")"
[ "$BIN_SHA_NOW" = "$BIN_SHA_BEFORE" ]
[ "$LUA_SHA_NOW" = "$LUA_SHA_BEFORE" ]
echo "PASS: binary and V14 sensor byte-identical."
echo "PASS: 12-second load-safe sensor was not modified."

echo
echo "===== 6/7 WRITE FIXED FINISH + ROLLBACK HELPERS ====="
EXPECTED="$PREFIX"'all_tiles_navmesh.bin'

cat > "$TOOLS/finish-navmesh-dump.sh" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail

DEV='$DEV'
ROOT='$ROOT'
BIN='$BIN'
LUA='$LUA'
SETTINGS='$SETTINGS'
REMOTE_BAK='$REMOTE_BAK'
EXPECTED='$EXPECTED'
PKG='$PKG'
SETTINGS_SHA_BEFORE='$SETTINGS_SHA_BEFORE'
BIN_SHA_BEFORE='$BIN_SHA_BEFORE'
LUA_SHA_BEFORE='$LUA_SHA_BEFORE'
SSH=(-o BatchMode=yes -o ConnectTimeout=8)

restore_settings() {
  set +e
  ssh "\${SSH[@]}" "\$DEV" "
    set -e
    test -s '\$REMOTE_BAK/settings.cfg.before'
    cp -p '\$REMOTE_BAK/settings.cfg.before' '\$SETTINGS'
    sync
    test \"\\\$(sha256sum '\$SETTINGS' | awk '{print \\\$1}')\" = '\$SETTINGS_SHA_BEFORE'
  "
}
trap 'rc=\$?; if [ \$rc -ne 0 ]; then echo; echo "ERROR: finish failed; restoring original settings..."; restore_settings || true; fi; exit \$rc' ERR

echo "=================================================================="
echo "FINISH LIVE NAVMESH DUMP + RESTORE SETTINGS"
echo "=================================================================="

if ssh "\${SSH[@]}" "\$DEV" 'pidof openmw-0.51 >/dev/null 2>&1 || pidof openmw >/dev/null 2>&1'; then
  echo "ERROR: OpenMW is still running."
  echo "Exit Morrowind normally first, then rerun this same finish command."
  exit 20
fi

echo
echo "===== 1/5 VERIFY DUMP EXISTS ====="
ssh "\${SSH[@]}" "\$DEV" "
  set -e
  test -s '\$EXPECTED'
  ls -lh '\$EXPECTED'
  sha256sum '\$EXPECTED'
"
DUMP_SHA="\$(ssh "\${SSH[@]}" "\$DEV" "sha256sum '\$EXPECTED' | awk '{print \\\$1}')"
DUMP_SIZE="\$(ssh "\${SSH[@]}" "\$DEV" "wc -c < '\$EXPECTED'")"
if [ "\$DUMP_SIZE" -lt 256 ]; then
  echo "ERROR: navmesh dump is implausibly small: \$DUMP_SIZE bytes"
  false
fi

echo
echo "===== 2/5 PULL + VERIFY DUMP ====="
scp "\${SSH[@]}" -q "\$DEV:\$EXPECTED" "\$PKG/all_tiles_navmesh.bin"
test "\$(sha256sum "\$PKG/all_tiles_navmesh.bin" | awk '{print \$1}')" = "\$DUMP_SHA"
printf '%s  %s\n' "\$DUMP_SHA" "\$PKG/all_tiles_navmesh.bin" > "\$PKG/NAVMESH_SHA256.txt"
echo "PASS: navmesh dump pulled byte-identically (\$DUMP_SIZE bytes)."

echo
echo "===== 3/5 PULL DUMP-RUN EVIDENCE ====="
{
  echo "##### NAVMESH DUMP RUN #####"
  ssh "\${SSH[@]}" "\$DEV" 'date; hostname'
  echo
  echo "dump remote: \$EXPECTED"
  echo "dump sha   : \$DUMP_SHA"
  echo "dump bytes : \$DUMP_SIZE"
  echo
  echo "----- relevant OpenMW log tail -----"
  ssh "\${SSH[@]}" "\$DEV" "
    grep -hEi 'nav.?mesh|TSP_VISGRID|TSP_LOAD_FREEZE|Failed to write debug navmesh' \
      '\$ROOT/openmw_051_log.txt' '\$ROOT/config-0.51/openmw.log' 2>/dev/null | tail -1200 || true
  "
} > "\$PKG/navmesh-dump-run.txt"

echo
echo "===== 4/5 RESTORE ORIGINAL SETTINGS BYTE-FOR-BYTE ====="
restore_settings
test "\$(ssh "\${SSH[@]}" "\$DEV" "sha256sum '\$SETTINGS' | awk '{print \\\$1}')" = "\$SETTINGS_SHA_BEFORE"
echo "PASS: original settings.cfg restored."

echo
echo "===== 5/5 VERIFY V14 + BINARY STILL UNCHANGED ====="
test "\$(ssh "\${SSH[@]}" "\$DEV" "sha256sum '\$BIN' | awk '{print \\\$1}')" = "\$BIN_SHA_BEFORE"
test "\$(ssh "\${SSH[@]}" "\$DEV" "sha256sum '\$LUA' | awk '{print \\\$1}')" = "\$LUA_SHA_BEFORE"
ssh "\${SSH[@]}" "\$DEV" "
  grep -Fq 'TSP_VISGRID_LUA_V14_MAPSYNC' '\$LUA'
  grep -Fq 'TSP_VISGRID_V11_LOADSAFE_12S' '\$LUA'
  grep -Fq 'POST_LOAD_ARM_DELAY = 12.0' '\$LUA'
"
echo "PASS: binary unchanged; V14 unchanged; 12-second hold intact."

echo
echo "=================================================================="
echo "NAVMESH CAPTURE COMPLETE"
echo "=================================================================="
echo "Upload these two files:"
echo "  \$PKG/all_tiles_navmesh.bin"
echo "  \$PKG/navmesh-dump-run.txt"
echo
echo "Package:"
echo "  \$PKG"
echo "=================================================================="
EOF
chmod +x "$TOOLS/finish-navmesh-dump.sh"

cat > "$TOOLS/rollback-navmesh-dump.sh" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
DEV='$DEV'
SETTINGS='$SETTINGS'
REMOTE_BAK='$REMOTE_BAK'
SETTINGS_SHA_BEFORE='$SETTINGS_SHA_BEFORE'
SSH=(-o BatchMode=yes -o ConnectTimeout=8)

if ssh "\${SSH[@]}" "\$DEV" 'pidof openmw-0.51 >/dev/null 2>&1 || pidof openmw >/dev/null 2>&1'; then
  echo "ERROR: OpenMW is running. Exit it normally before rollback."
  exit 20
fi

ssh "\${SSH[@]}" "\$DEV" "
 set -e
 test -s '\$REMOTE_BAK/settings.cfg.before'
 cp -p '\$REMOTE_BAK/settings.cfg.before' '\$SETTINGS'
 sync
 test \"\\\$(sha256sum '\$SETTINGS' | awk '{print \\\$1}')\" = '\$SETTINGS_SHA_BEFORE'
"
echo "PASS: exact original settings.cfg restored."
EOF
chmod +x "$TOOLS/rollback-navmesh-dump.sh"

cat > "$PKG/README.txt" <<EOF
VISGRID V15 topology capture - $STAMP

Armed only OpenMW's built-in navmesh debug writer.
No source edit. No rebuild. No binary edit. No VISGRID Lua edit.

Target dump:
  $EXPECTED

V14 load-safe invariant verified before arming:
  TSP_VISGRID_V11_LOADSAFE_12S
  POST_LOAD_ARM_DELAY = 12.0

After normal gameplay capture, exit OpenMW and run:
  ~/Downloads/visgrid-tools/finish-navmesh-dump.sh

Emergency settings rollback:
  ~/Downloads/visgrid-tools/rollback-navmesh-dump.sh
EOF

echo "PASS: finish and rollback helpers written."

echo
echo "===== 7/7 ARMED ====="
ROLLBACK_NEEDED=0

echo "=================================================================="
echo "NAVMESH DUMP IS ARMED — NO REBUILD PERFORMED"
echo "=================================================================="
echo
echo "Now:"
echo "  1. Launch Morrowind_51 normally from the TrimUI menu."
echo "  2. Load the same Caldera, Governor's Hall save."
echo "  3. Walk through the problem wall/room, hallway, doorway and staircase"
echo "     so the live navmesh around those areas is present."
echo "  4. Exit OpenMW normally."
echo "  5. Back in Ubuntu run:"
echo
echo "       ~/Downloads/visgrid-tools/finish-navmesh-dump.sh"
echo
echo "That command pulls the dump AND restores your exact original settings."
echo
echo "Emergency rollback, with OpenMW closed:"
echo "       ~/Downloads/visgrid-tools/rollback-navmesh-dump.sh"
echo
echo "Expected device dump:"
echo "  $EXPECTED"
echo
echo "Package:"
echo "  $PKG"
echo "=================================================================="
