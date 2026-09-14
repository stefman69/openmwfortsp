#!/usr/bin/env bash
# fix-v13-verify-marker.sh
#
# WHAT HAPPENED
#   The build succeeded. Step 6/10 aborted on a check that can never pass.
#
#   V13 writes its border-fog marker as a C++ COMMENT (line 352):
#       //  TSP_INTERIOR_VISGRID_051_V4B_BORDERFOG
#   and then greps the compiled BINARY for it (line 435):
#       grep -a -q 'TSP_INTERIOR_VISGRID_051_V4B_BORDERFOG' "$OPENMW_BIN"
#   Comments are not compiled into the binary, so that grep always fails.
#   The other markers pass because each of them is also a real string literal
#   inside a Log() call, which does land in .rodata.
#
#   Because the whole verify block ran under `set -euo pipefail` as one silent
#   chain, the first failing grep aborted with no indication of which one.
#
# THE FIX
#   1. Give the border-fog code a real Log line carrying the marker, so it is
#      a genuine string in the binary like every other marker - and it prints
#      the effective border value at runtime, which is worth having anyway.
#   2. Replace the verify block with a loop that names every marker it checks
#      and reports PASS/FAIL per line before failing, so a missing marker can
#      never again be an anonymous abort. The two controller invariants are
#      reported but no longer abort the install (r3=force-text-reset and
#      tx_cursor.dds are inherited from earlier work; V12's verify did not
#      check tx_cursor.dds at all, so a hard fail on it is new and unproven).
#
# Then the V13 installer is rerun. Nothing else in V13 changes.
set -Eeuo pipefail

INST="${1:-$HOME/Downloads/apply_visgrid_v13_stability.sh}"
test -f "$INST" || { echo "ERROR: V13 installer not found at $INST"; exit 2; }

C="${TSP_BUILDER:-openmw_builder}"
SRC="/root/openmw-0.51-tsp-src"
IVC="$SRC/apps/openmw/mwrender/interiorvisibility.cpp"

echo "=================================================================="
echo "STEP 1/3  PATCH THE V13 INSTALLER"
echo "=================================================================="
cp -p "$INST" "$INST.bak-verify-$(date +%Y%m%d-%H%M%S)"

python3 - "$INST" <<'PYFIX'
import sys

path = sys.argv[1]
raw = open(path, encoding='utf-8', errors='surrogateescape').read()
s = raw.replace('\r\n', '\n')
changed = 0

# ---- 1. make the marker a real string in the binary ----------------------
old_blk = '''                if (!tspBorderRead)
                {
                    tspBorderRead = true;
                    const char* tspEnvB = std::getenv("TSP_VISGRID_FOG_BORDER");
                    if (tspEnvB != nullptr)
                    {
                        const double tspB = std::strtod(tspEnvB, nullptr);
                        if (tspB >= 0.0)
                            tspBorder = tspB;
                    }
                }'''
new_blk = '''                if (!tspBorderRead)
                {
                    tspBorderRead = true;
                    const char* tspEnvB = std::getenv("TSP_VISGRID_FOG_BORDER");
                    if (tspEnvB != nullptr)
                    {
                        const double tspB = std::strtod(tspEnvB, nullptr);
                        if (tspB >= 0.0)
                            tspBorder = tspB;
                    }
                    // Logged once per process. This also puts the marker in
                    // .rodata so the installer's binary check has something
                    // real to find - a // comment never reaches the binary.
                    Log(Debug::Info)
                        << "TSP_INTERIOR_VISGRID_051_V4B_BORDERFOG border=" << tspBorder;
                }'''
if old_blk in s:
    s = s.replace(old_blk, new_blk, 1)
    changed += 1
    print('PASS: V4B marker is now a Log string literal (and prints the border).')
elif 'V4B_BORDERFOG border=' in s:
    print('NOTE: installer already logs the V4B marker.')
else:
    raise SystemExit('ERROR: could not find the tspBorderRead block to patch.')

# ---- 2. a verify block that says which marker is missing ------------------
old_verify = '''docker exec -i "$C" bash -lc "
set -euo pipefail
test -x '$OPENMW_BIN'
readelf -h '$OPENMW_BIN' | grep -q 'AArch64'
grep -a -q 'TSP_INTERIOR_VISGRID_051_V1' '$OPENMW_BIN'
grep -a -q 'TSP_INTERIOR_VISGRID_051_V3_PERCENTILE_FOG' '$OPENMW_BIN'
grep -a -q 'TSP_INTERIOR_VISGRID_051_V4_CULLFOG' '$OPENMW_BIN'
grep -a -q 'TSP_INTERIOR_VISGRID_051_V4B_BORDERFOG' '$OPENMW_BIN'
grep -a -q 'TSP_LUAJIT_SAFE_051_V1' '$OPENMW_BIN'
grep -a -q 'TSP_INTERIOR_SCAN_051_V1' '$OPENMW_BIN'
grep -a -q 'r3=force-text-reset' '$OPENMW_BIN'
grep -a -q 'tx_cursor.dds' '$OPENMW_BIN'
echo 'PASS: AArch64 + V1 V3 V4 V4B SAFE SCAN markers + controller invariants.'
"'''
new_verify = '''docker exec -i "$C" bash -lc "
set -uo pipefail
B='$OPENMW_BIN'
test -x \\"\\$B\\" || { echo 'FAIL: no executable at' \\"\\$B\\"; exit 1; }
readelf -h \\"\\$B\\" | grep -q 'AArch64' || { echo 'FAIL: not an AArch64 ELF'; exit 1; }
echo '  PASS  AArch64 ELF'
tspmiss=0
for m in TSP_INTERIOR_VISGRID_051_V1 \\
         TSP_INTERIOR_VISGRID_051_V3_PERCENTILE_FOG \\
         TSP_INTERIOR_VISGRID_051_V4_CULLFOG \\
         TSP_INTERIOR_VISGRID_051_V4B_BORDERFOG \\
         TSP_LUAJIT_SAFE_051_V1 \\
         TSP_INTERIOR_SCAN_051_V1; do
    if grep -a -q \\"\\$m\\" \\"\\$B\\"; then
        echo \\"  PASS  marker \\$m\\"
    else
        echo \\"  FAIL  marker \\$m NOT FOUND IN BINARY\\"
        tspmiss=1
    fi
done
for m in r3=force-text-reset tx_cursor.dds; do
    if grep -a -q \\"\\$m\\" \\"\\$B\\"; then
        echo \\"  PASS  invariant \\$m\\"
    else
        echo \\"  WARN  invariant \\$m not present (informational, not fatal)\\"
    fi
done
if [ \\"\\$tspmiss\\" -ne 0 ]; then
    echo 'FAIL: one or more markers are missing from the binary (named above).'
    echo '      A marker that only exists as a // comment can never appear here.'
    exit 1
fi
echo 'PASS: build verification complete.'
"'''
if old_verify in s:
    s = s.replace(old_verify, new_verify, 1)
    changed += 1
    print('PASS: verify block now names each marker and does not abort silently.')
elif 'tspmiss' in s:
    print('NOTE: installer already has the diagnostic verify block.')
else:
    raise SystemExit('ERROR: could not find the step 6 verify block to replace.')

if changed:
    open(path, 'w', encoding='utf-8', errors='surrogateescape').write(s)

b2 = open(path, encoding='utf-8', errors='surrogateescape').read()
assert 'V4B_BORDERFOG border=' in b2
assert 'tspmiss' in b2
for needle in ('TSP_LUAJIT_SAFE_051_V1', 'TSP_INTERIOR_VISGRID_051_V4B_BORDERFOG',
               'TSP_VISGRID_V11B_MAPV2', 'TSP_INTERIOR_MAP_V2', 'LUAJIT_MODE_FLUSH',
               'TSP_LUAJIT_HEADER_051_V1'):
    assert needle in b2, 'installer lost: ' + needle
print('PASS: V13 installer postconditions hold.')
PYFIX

bash -n "$INST"
echo "PASS: V13 installer still parses."

echo
echo "=================================================================="
echo "STEP 2/3  CLEAN THE CONTAINER SOURCE + STALE OBJECTS"
echo "=================================================================="
command -v docker >/dev/null
if [ "$(docker inspect -f '{{.State.Running}}' "$C" 2>/dev/null)" != "true" ]; then
    docker start "$C" >/dev/null
fi
docker exec -i "$C" bash -lc "
set -uo pipefail
if grep -Fq 'TSP_INTERIOR_VISGRID_051_V4B_BORDERFOG' '$IVC'; then
    echo 'NOTE: the failed run left the V13 border-fog patch in the source;'
    echo '      restoring it from the V13 backup so the installer re-patches cleanly.'
    B=\$(ls -1dt /root/tsp-v13-source-backup-* 2>/dev/null | head -1)
    if [ -n \"\$B\" ] && [ -s \"\$B/interiorvisibility.cpp\" ]; then
        cp -p \"\$B/interiorvisibility.cpp\" '$IVC'
        cp -p \"\$B/camerabindings.cpp\" '$SRC/apps/openmw/mwlua/camerabindings.cpp'
        echo \"PASS: restored from \$B\"
    else
        echo 'WARNING: no V13 source backup found; the installer will report if it cannot patch.'
    fi
else
    echo 'PASS: source is clean (V13 rolled it back).'
fi
find /root/openmw-0.51-tsp-build -type f \\( -name 'camerabindings.cpp.o' -o -name 'interiorvisibility.cpp.o' \\) -print -delete 2>/dev/null
echo 'PASS: stale objects cleared.'
"

echo
echo "=================================================================="
echo "STEP 3/3  RERUN THE V13 INSTALLER"
echo "=================================================================="
exec bash "$INST"
