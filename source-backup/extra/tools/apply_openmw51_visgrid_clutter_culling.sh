#!/usr/bin/env bash
set -Eeuo pipefail

# OpenMW 0.51 / TrimUI Smart Pro
# VISGRID gameplay-clutter render culling, safe version.
#
# Goal:
#   Keep gameplay objects fully alive (render root creation, activation identity,
#   Bullet collision, scripts, inventory state), but attach the interior
#   CullVisitor callback to non-actor/non-door objects again.
#
#   Structural PVS remains Static-only.
#   Dynamic clutter gets ONLY the screen-depth/grid rejection.
#
#   This restores the intended "don't render books/plates/etc behind a wall"
#   behavior without the unsafe Ptr::get<ESM::Static>() cast that previously
#   aborted object creation.
#
# Actions:
#   install  (default)
#   collect
#   rollback

ACTION="${1:-install}"

CTR="${OPENMW_CONTAINER:-openmw_builder}"
DEV="${TSP_DEVICE:-root@192.168.1.25}"

SRC="/root/openmw-0.51-tsp-src"
BUILD="/root/openmw-0.51-tsp-build"
PACKAGE="/root/openmw-0.51-tsp-package"

ANIM="$SRC/apps/openmw/mwrender/animation.cpp"
BUILT="$BUILD/openmw"
PACKAGED="$PACKAGE/bin/openmw-0.51"

ROOT="/mnt/SDCARD/data/ports/openmw51"
REMOTE_BIN="$ROOT/bin/openmw-0.51"
REMOTE_TMP="/tmp/openmw-0.51.tsp-visgrid-clutter"

DL="$HOME/Downloads"
HOST_OUT="$DL/openmw-0.51-visgrid-clutter-cull"
STATE="$DL/openmw51-visgrid-clutter-cull.state"
STAMP="$(date +%Y%m%d-%H%M%S)"
LOG="$DL/openmw51-visgrid-clutter-cull-$STAMP.log"

mkdir -p "$DL"

die() {
    echo "ERROR: $*" >&2
    exit 1
}

ensure_docker() {
    command -v docker >/dev/null 2>&1 || die "docker command not found"
    docker inspect "$CTR" >/dev/null 2>&1 || die "Docker container '$CTR' not found"
    if [ "$(docker inspect -f '{{.State.Running}}' "$CTR")" != "true" ]; then
        docker start "$CTR" >/dev/null
    fi
}

ensure_ssh() {
    command -v ssh >/dev/null 2>&1 || die "ssh command not found"
    command -v scp >/dev/null 2>&1 || die "scp command not found"
    ssh -o BatchMode=yes -o ConnectTimeout=8 "$DEV" true \
        || die "Cannot reach $DEV over SSH"
}

collect_validation() {
    ensure_ssh

    OUT="$DL/openmw51-visgrid-clutter-cull-validation-$STAMP.txt"
    RAW="$DL/.openmw51-visgrid-clutter-cull-raw-$STAMP.txt"

    ssh "$DEV" "bash -s" >"$RAW" <<'TSP_COLLECT'
set +e
ROOT="/mnt/SDCARD/data/ports/openmw51"

echo "===== DEVICE ====="
date
sha256sum "$ROOT/bin/openmw-0.51" 2>/dev/null || true
echo

for f in \
    "$ROOT/openmw_051_log.txt" \
    "$ROOT/config-0.51/openmw.log" \
    "$ROOT/openmw.log"
do
    if [ -f "$f" ]; then
        echo "### FILE: $f"
        tail -n 60000 "$f"
    fi
done
TSP_COLLECT

    # Isolate the latest instrumented launch if possible.
    awk '
        /TSP_OBJECT_DIAG_051_V1 enabled/ {
            buf = ""
            found = 1
        }
        found { buf = buf $0 ORS }
        END { if (found) printf "%s", buf }
    ' "$RAW" >"$OUT.latest"

    {
        echo "============================================================"
        echo "VISGRID CLUTTER CULL VALIDATION"
        echo "============================================================"
        echo "Collected: $(date)"
        echo

        LATEST="$OUT.latest"
        if [ ! -s "$LATEST" ]; then
            LATEST="$RAW"
        fi

        printf "bad STAT casts:                    "
        grep -c 'Bad LiveCellRef cast to STAT' "$LATEST" || true

        printf "failed-to-render lines:             "
        grep -c 'failed to render' "$LATEST" || true

        printf "non-static callbacks attached:      "
        grep -Ec 'TSP_VISOBJ_ATTACH.*static=0.*pvsEligible=0' "$LATEST" || true

        printf "non-static GRID culls:              "
        grep -Ec 'TSP_VISOBJ_CULL.*reason=GRID.*static=0' "$LATEST" || true

        printf "non-static PVS culls (MUST be zero):"
        grep -Ec 'TSP_VISOBJ_CULL.*reason=PVS.*static=0' "$LATEST" || true

        printf "container roots created:            "
        grep -Ec 'TSP_OBJROOT.*type=1414418243' "$LATEST" || true

        printf "container physics=1 observations:   "
        grep -Ec 'TSP_NAVOBJ.*type=1414418243.*physics=1' "$LATEST" || true

        echo
        echo "===== NON-STATIC GRID CULL EXAMPLES ====="
        grep -E 'TSP_VISOBJ_CULL.*reason=GRID.*static=0' "$LATEST" | head -120 || true

        echo
        echo "===== NON-STATIC CALLBACK EXAMPLES ====="
        grep -E 'TSP_VISOBJ_ATTACH.*static=0.*pvsEligible=0' "$LATEST" | head -120 || true

        echo
        echo "===== ANY BAD CAST / RENDER FAILURE ====="
        grep -E 'Bad LiveCellRef cast|failed to render' "$LATEST" | head -200 || true

        echo
        echo "===== PERF TAIL ====="
        ssh "$DEV" "
            [ -f '$ROOT/openmw51_perf_latest.txt' ] &&
            tail -300 '$ROOT/openmw51_perf_latest.txt' || true
        " 2>/dev/null || true
    } >"$OUT"

    rm -f "$RAW" "$OUT.latest"

    echo
    echo "Saved:"
    echo "  $OUT"
}

rollback_fix() {
    [ -f "$STATE" ] || die "State file missing: $STATE"
    # shellcheck disable=SC1090
    . "$STATE"

    ensure_docker
    ensure_ssh

    test -n "${SOURCE_BACKUP:-}" || die "SOURCE_BACKUP missing from state"
    test -n "${DEVICE_BACKUP:-}" || die "DEVICE_BACKUP missing from state"

    docker exec "$CTR" bash -lc "
        set -e
        test -f '$SOURCE_BACKUP/animation.cpp'
        cp -pf '$SOURCE_BACKUP/animation.cpp' '$ANIM'
    "

    ssh "$DEV" "bash -s" <<TSP_ROLLBACK
set -e
test -f '$DEVICE_BACKUP'
cp -pf '$DEVICE_BACKUP' '$REMOTE_BIN'
chmod 755 '$REMOTE_BIN'
sync
sha256sum '$REMOTE_BIN'
TSP_ROLLBACK

    echo "ROLLBACK COMPLETE"
}

case "$ACTION" in
    collect)
        collect_validation
        exit 0
        ;;
    rollback)
        rollback_fix
        exit 0
        ;;
    install)
        ;;
    *)
        die "Usage: $0 [install|collect|rollback]"
        ;;
esac

exec > >(tee "$LOG") 2>&1

echo "============================================================"
echo "OPENMW 0.51 VISGRID SAFE GAMEPLAY-CLUTTER CULL"
echo "============================================================"
echo "Container: $CTR"
echo "Device:    $DEV"
echo "Log:       $LOG"
echo
echo "Objects remain alive."
echo "Only their render traversal is skipped while hidden."
echo "============================================================"

ensure_docker
ensure_ssh

echo
echo "===== PRE-FLIGHT ====="
if ssh "$DEV" "pgrep -af 'openmw-0\.51|/openmw([[:space:]]|$)' 2>/dev/null" | grep -v pgrep; then
    die "OpenMW is running. Exit normally and rerun."
fi
echo "PASS: OpenMW is not running."

docker exec "$CTR" test -f "$ANIM"
docker exec "$CTR" test -f "$BUILT"

echo
echo "===== VERIFY SAFE OBJECT FIX IS PRESENT ====="
docker exec "$CTR" bash -lc "
    set -e
    grep -F 'TSP_VISGRID_OBJECT_CLASS_FIX_051_V1' '$ANIM'
    ! grep -F 'mPtr.get<ESM::Static>()' '$ANIM'
    grep -F 'const bool tspIsStatic = mPtr.getType() == ESM::Static::sRecordId;' '$ANIM'
    grep -F 'TSP_INTERIOR_VISGRID_051_V5_TOPO_PVS' '$ANIM'
"
echo "PASS: no throwing Static cast remains."

PRE_DEVICE_SHA="$(ssh "$DEV" "sha256sum '$REMOTE_BIN' | awk '{print \$1}'")"
echo "Current device SHA: $PRE_DEVICE_SHA"

echo
echo "===== SOURCE BACKUP ====="
SOURCE_BACKUP="$SRC/.tsp-051-source-backups/visgrid-clutter-cull-$STAMP"
docker exec "$CTR" bash -lc "
    set -e
    mkdir -p '$SOURCE_BACKUP'
    cp -pf '$ANIM' '$SOURCE_BACKUP/animation.cpp'
    sha256sum '$SOURCE_BACKUP/animation.cpp'
"

echo
echo "===== PATCH CALLBACK POLICY ====="
docker exec -i "$CTR" python3 - "$ANIM" <<'PY_PATCH'
import re
import sys

path = sys.argv[1]

with open(path, "r", encoding="utf-8", newline="") as f:
    s = f.read()

required = [
    "TSP_VISGRID_OBJECT_CLASS_FIX_051_V1",
    "const bool tspIsStatic = mPtr.getType() == ESM::Static::sRecordId;",
    "TSP_INTERIOR_VISGRID_051_V5_TOPO_PVS",
    "new InteriorVisibilityCullCallback",
]
for token in required:
    if token not in s:
        raise RuntimeError("animation.cpp missing required current-state token: " + token)

if "mPtr.get<ESM::Static>()" in s:
    raise RuntimeError("unsafe Static LiveCellRef cast has returned; refusing patch")

if "TSP_VISGRID_CLUTTER_CULL_051_V1" not in s:
    old_comment = (
        "        // Ptr::get<ESM::Static>() is a throwing cast, not a type predicate.\n"
        "        // Gameplay objects bypass the entire VISGRID callback.\n"
    )
    new_comment = (
        "        // Ptr::get<ESM::Static>() is a throwing cast, not a type predicate.\n"
        "        // TSP_VISGRID_CLUTTER_CULL_051_V1\n"
        "        // Safe type classification: only Static roots may use topology PVS.\n"
        "        // Gameplay clutter may still use the screen-depth CullVisitor.\n"
    )
    if s.count(old_comment) != 1:
        raise RuntimeError(
            "expected the V1 safe-fix comment exactly once; found %d"
            % s.count(old_comment)
        )
    s = s.replace(old_comment, new_comment, 1)

# The exact callback block has a distinctive three-line comment immediately
# before its outer gate. Change ONLY that gate.
pattern = re.compile(
    r"(?P<prefix>"
    r"        // The VISGRID callback is deliberately installed first, outside the\n"
    r"        // normal LightList callback\. A rejected object therefore avoids the\n"
    r"        // ordinary per-object light/state traversal\.\n"
    r")"
    r"        if \(tspIsStatic\)\n"
    r"        \{",
    re.MULTILINE,
)

replacement = (
    r"\g<prefix>"
    "        // Actors and doors always render normally. Every other object gets\n"
    "        // the render-only depth curtain; tspPvsEligible below remains Static-only.\n"
    "        if (!tspDiagActor && !tspDiagDoor)\n"
    "        {"
)

s, n = pattern.subn(replacement, s, count=1)
if n != 1:
    # Non-diagnostic fallback, if the current source no longer has tspDiag vars.
    pattern2 = re.compile(
        r"(?P<prefix>"
        r"        // The VISGRID callback is deliberately installed first, outside the\n"
        r"        // normal LightList callback\. A rejected object therefore avoids the\n"
        r"        // ordinary per-object light/state traversal\.\n"
        r")"
        r"        if \(mPtr\.getType\(\) == ESM::Static::sRecordId\)\n"
        r"        \{",
        re.MULTILINE,
    )
    replacement2 = (
        r"\g<prefix>"
        "        // Actors and doors always render normally. Every other object gets\n"
        "        // the render-only depth curtain; topology PVS remains Static-only.\n"
        "        if (!mPtr.getClass().isActor() && !mPtr.getClass().isDoor())\n"
        "        {"
    )
    s, n2 = pattern2.subn(replacement2, s, count=1)
    n += n2

if n != 1:
    raise RuntimeError(
        "could not uniquely locate the Static-only outer VISGRID callback gate"
    )

# Diagnostic callback= field should reflect actual callback attachment.
s = re.sub(
    r'<< " callback=" << \(tspIsStatic \? 1 : 0\)',
    r'<< " callback=" << ((!tspDiagActor && !tspDiagDoor) ? 1 : 0)',
    s,
    count=1,
)

# Safety invariants.
if "mPtr.get<ESM::Static>()" in s:
    raise RuntimeError("unsafe Static cast exists after patch")

if "TSP_VISGRID_CLUTTER_CULL_051_V1" not in s:
    raise RuntimeError("clutter-cull marker missing")

if "const bool tspPvsEligible = tspIsStatic" not in s:
    raise RuntimeError("topology PVS is no longer explicitly Static-only")

if "if (!tspDiagActor && !tspDiagDoor)" not in s and \
   "if (!mPtr.getClass().isActor() && !mPtr.getClass().isDoor())" not in s:
    raise RuntimeError("broad safe callback gate missing")

with open(path, "w", encoding="utf-8", newline="\n") as f:
    f.write(s)

print("PASS: gameplay clutter receives render-only VISGRID callback again.")
print("PASS: topology PVS remains Static-only.")
print("PASS: unsafe Ptr::get<ESM::Static>() cast remains absent.")
PY_PATCH

echo
echo "===== VERIFY PATCHED SOURCE ====="
docker exec "$CTR" bash -lc "
    set -e

    echo '--- classification / callback ---'
    grep -nE -B8 -A35 \
      'TSP_VISGRID_OBJECT_CLASS_FIX_051_V1|TSP_VISGRID_CLUTTER_CULL_051_V1|tspIsStatic|VISGRID callback|tspPvsEligible' \
      '$ANIM' | head -220

    echo
    echo 'Unsafe cast count:'
    C=\$(grep -cF 'mPtr.get<ESM::Static>()' '$ANIM' || true)
    echo \"  \$C\"
    [ \"\$C\" -eq 0 ]

    grep -F 'TSP_VISGRID_CLUTTER_CULL_051_V1' '$ANIM'
    grep -F 'const bool tspPvsEligible = tspIsStatic' '$ANIM'
"

echo
echo "===== BUILD ====="
BUILD_LOG="/root/openmw51-visgrid-clutter-cull-$STAMP.log"

set +e
docker exec "$CTR" bash -lc "
    set -o pipefail
    cd '$BUILD'
    cmake --build . --target openmw --parallel '${OPENMW_JOBS:-2}' 2>&1 \
      | tee '$BUILD_LOG'
"
RC=$?
set -e

if [ "$RC" -ne 0 ]; then
    echo
    echo "BUILD FAILED."
    docker exec "$CTR" bash -lc "tail -n 180 '$BUILD_LOG' || true"
    echo
    echo "Source backup:"
    echo "  $SOURCE_BACKUP"
    exit "$RC"
fi

echo
echo "===== PACKAGE / VERIFY ====="
docker exec "$CTR" bash -lc "
    set -e
    test -f '$BUILT'
    mkdir -p '$(dirname "$PACKAGED")'
    install -m 755 '$BUILT' '$PACKAGED'

    file '$PACKAGED'
    sha256sum '$PACKAGED'
    file '$PACKAGED' | grep -Eq 'ARM aarch64|ARM64|AArch64'

    echo 'Diagnostic/VisGrid markers (supplemental):'
    strings '$PACKAGED' | grep -E \
      'TSP_OBJECT_DIAG_051_V1|TSP_INTERIOR_VISGRID_051_V5_TOPO_PVS' \
      | sort -u | head -40 || true
"

NEW_SHA="$(docker exec "$CTR" sha256sum "$PACKAGED" | awk '{print $1}')"
[ -n "$NEW_SHA" ] || die "could not determine rebuilt SHA"
[ "$NEW_SHA" != "$PRE_DEVICE_SHA" ] || die "rebuilt binary hash did not change"

echo
echo "===== DOCKER -> UBUNTU ====="
if [ -f "$HOST_OUT" ]; then
    cp -pf "$HOST_OUT" "$HOST_OUT.before-$STAMP"
fi
docker cp "$CTR:$PACKAGED" "$HOST_OUT"
chmod +x "$HOST_OUT"

HOST_SHA="$(sha256sum "$HOST_OUT" | awk '{print $1}')"
[ "$HOST_SHA" = "$NEW_SHA" ] || die "Docker->Ubuntu SHA mismatch"

file "$HOST_OUT"
sha256sum "$HOST_OUT"

echo
echo "===== BACKUP / INSTALL TO TSP ====="
DEVICE_BACKUP_DIR="$ROOT/backups/visgrid-clutter-cull-$STAMP"
DEVICE_BACKUP="$DEVICE_BACKUP_DIR/openmw-0.51.before-visgrid-clutter-cull"

ssh "$DEV" "mkdir -p '$DEVICE_BACKUP_DIR' && cp -pf '$REMOTE_BIN' '$DEVICE_BACKUP'"
scp "$HOST_OUT" "$DEV:$REMOTE_TMP"

ssh "$DEV" "bash -s" <<TSP_INSTALL
set -e
INCOMING="\$(sha256sum '$REMOTE_TMP' | awk '{print \$1}')"
[ "\$INCOMING" = '$NEW_SHA' ]
install -m 755 '$REMOTE_TMP' '$REMOTE_BIN'
rm -f '$REMOTE_TMP'
sync
FINAL="\$(sha256sum '$REMOTE_BIN' | awk '{print \$1}')"
[ "\$FINAL" = '$NEW_SHA' ]
echo "Installed:"
sha256sum '$REMOTE_BIN'
TSP_INSTALL

cat >"$STATE" <<EOF_STATE
SOURCE_BACKUP='$SOURCE_BACKUP'
DEVICE_BACKUP='$DEVICE_BACKUP'
PRE_DEVICE_SHA='$PRE_DEVICE_SHA'
FIX_DEVICE_SHA='$NEW_SHA'
HOST_OUT='$HOST_OUT'
EOF_STATE

echo
echo "============================================================"
echo "INSTALL COMPLETE"
echo "============================================================"
echo "Old SHA: $PRE_DEVICE_SHA"
echo "New SHA: $NEW_SHA"
echo
echo "What changed:"
echo "  - books/plates/weapons/containers/etc still EXIST normally"
echo "  - actors and doors bypass VISGRID"
echo "  - structural PVS stays Static-only"
echo "  - non-static clutter can be skipped by the wall-depth CullVisitor"
echo "  - container exterior paging bypass remains untouched"
echo
echo "ONE test run:"
echo "  1. Use the same clutter-heavy interior where FPS fell back to ~10."
echo "  2. Face a solid wall with a clutter-heavy room behind it."
echo "  3. Turn/move until that room should become visible."
echo "  4. Confirm clutter appears normally when exposed."
echo "  5. Confirm nearby containers still activate and remain solid."
echo "  6. Exit normally."
echo
echo "Then:"
echo "  cd ~/Downloads"
echo "  ./apply_openmw51_visgrid_clutter_culling.sh collect"
echo
echo "Rollback:"
echo "  ./apply_openmw51_visgrid_clutter_culling.sh rollback"
echo "============================================================"
