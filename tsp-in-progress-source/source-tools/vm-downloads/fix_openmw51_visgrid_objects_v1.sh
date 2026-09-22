#!/usr/bin/env bash
set -Eeuo pipefail

# OpenMW 0.51 / TrimUI Smart Pro
# TSP object-class correctness fix V1
#
# Fix 1:
#   VISGRID must classify ESM::Static without attempting Ptr::get<ESM::Static>()
#   on every non-actor. The old cast throws for Container/Misc/Book/etc and
#   aborts Scene::addObject before the later physics insertion.
#
# Fix 2:
#   Containers are gameplay objects. Keep ESM3/ESM4 containers out of exterior
#   object paging so they retain an individual render node, activation identity,
#   and Bullet body instead of relying on a merged paging shell.
#
# Default action: patch current Docker source in place, build, verify, copy to
# ~/Downloads, back up the current TSP binary, install, and verify hashes.
#
# After ONE correctness test and normal game exit:
#   ./fix_openmw51_visgrid_objects_v1.sh collect
#
# Roll back source + installed binary:
#   ./fix_openmw51_visgrid_objects_v1.sh rollback

ACTION="${1:-install}"

CTR="${OPENMW_CONTAINER:-openmw_builder}"
DEV="${TSP_DEVICE:-root@192.168.1.25}"

SRC="/root/openmw-0.51-tsp-src"
BUILD="/root/openmw-0.51-tsp-build"
PACKAGE="/root/openmw-0.51-tsp-package"

ANIM="$SRC/apps/openmw/mwrender/animation.cpp"
PAGING="$SRC/apps/openmw/mwrender/objectpaging.cpp"
BUILT="$BUILD/openmw"
PACKAGED="$PACKAGE/bin/openmw-0.51"

ROOT="/mnt/SDCARD/data/ports/openmw51"
REMOTE_BIN="$ROOT/bin/openmw-0.51"
REMOTE_TMP="/tmp/openmw-0.51.tsp-object-fix-v1"

DL="${HOME}/Downloads"
HOST_OUT="$DL/openmw-0.51-object-fix-v1"
STATE="$DL/openmw51-object-fix-v1.state"
STAMP="$(date +%Y%m%d-%H%M%S)"
LOG="$DL/openmw51-object-fix-v1-$STAMP.log"

mkdir -p "$DL"

die() {
    echo "ERROR: $*" >&2
    exit 1
}

ensure_docker() {
    command -v docker >/dev/null 2>&1 || die "docker command not found"
    docker inspect "$CTR" >/dev/null 2>&1 || die "Docker container '$CTR' not found"
    if [ "$(docker inspect -f '{{.State.Running}}' "$CTR")" != "true" ]; then
        echo "Starting Docker container '$CTR'..."
        docker start "$CTR" >/dev/null
    fi
}

ensure_ssh() {
    command -v ssh >/dev/null 2>&1 || die "ssh command not found"
    command -v scp >/dev/null 2>&1 || die "scp command not found"
    ssh -o BatchMode=yes -o ConnectTimeout=8 "$DEV" true \
        || die "Cannot reach $DEV with non-interactive SSH"
}

collect_validation() {
    ensure_ssh
    OUT="$DL/openmw51-object-fix-v1-validation-$STAMP.txt"
    RAW="$DL/.openmw51-object-fix-v1-validation-raw-$STAMP.txt"

    echo "Collecting the latest object-diagnostic run from the TSP..."

    ssh "$DEV" "bash -s" >"$RAW" <<'TSP_COLLECT'
set +e
ROOT="/mnt/SDCARD/data/ports/openmw51"

echo "===== DEVICE IDENTITY ====="
date
sha256sum "$ROOT/bin/openmw-0.51" 2>/dev/null || true
echo

echo "===== AVAILABLE OPENMW LOGS ====="
for f in \
    "$ROOT/openmw_051_log.txt" \
    "$ROOT/openmw.log" \
    "$ROOT/config-0.51/openmw.log" \
    "$ROOT/config/openmw.log"
do
    if [ -f "$f" ]; then
        echo "### FILE: $f"
        tail -n 50000 "$f"
    fi
done

find "$ROOT" -maxdepth 4 -type f -name 'openmw.log' 2>/dev/null \
  | while read -r f; do
        case "$f" in
            "$ROOT/openmw.log"|"$ROOT/config-0.51/openmw.log"|"$ROOT/config/openmw.log")
                ;;
            *)
                echo "### FILE: $f"
                tail -n 50000 "$f"
                ;;
        esac
    done
TSP_COLLECT

    # Keep only the most recent diagnostic launch when that marker exists.
    awk '
        /TSP_OBJECT_DIAG_051_V1 enabled/ {
            buf = ""
            found = 1
        }
        found {
            buf = buf $0 ORS
        }
        END {
            if (found)
                printf "%s", buf
        }
    ' "$RAW" >"$OUT.latest"

    {
        echo "============================================================"
        echo "OPENMW 0.51 TSP OBJECT FIX V1 - VALIDATION"
        echo "============================================================"
        echo "Collected: $(date)"
        echo
        echo "Fix expectations:"
        echo "  1. Bad LiveCellRef STAT-cast errors: ZERO"
        echo "  2. Interior Container/Misc/Book/etc. create TSP_OBJROOT callback=0"
        echo "  3. Exterior containers: TSP_OBJINSERT ... exterior=1 paged=0"
        echo "  4. Exterior containers: TSP_NAVOBJ ... physics=1"
        echo "  5. TSP_VISOBJ_ATTACH should be structural ESM::Static only"
        echo
        echo "===== COUNTS FROM LATEST DIAGNOSTIC LAUNCH ====="
        LATEST="$OUT.latest"
        if [ -s "$LATEST" ]; then
            printf "bad STAT casts:                         "
            grep -c 'Bad LiveCellRef cast to STAT' "$LATEST" || true
            printf "all failed-to-render lines:             "
            grep -c 'failed to render' "$LATEST" || true
            printf "exterior containers still paged=1:      "
            grep -Ec 'TSP_OBJINSERT.*type=1414418243.*exterior=1.*paged=1' "$LATEST" || true
            printf "exterior containers now paged=0:        "
            grep -Ec 'TSP_OBJINSERT.*type=1414418243.*exterior=1.*paged=0' "$LATEST" || true
            printf "container render roots:                  "
            grep -Ec 'TSP_OBJROOT.*type=1414418243' "$LATEST" || true
            printf "container physics observations:          "
            grep -Ec 'TSP_NAVOBJ.*type=1414418243.*physics=1' "$LATEST" || true
            printf "non-static VISGRID attachments:          "
            grep -Ec 'TSP_VISOBJ_ATTACH.*static=0' "$LATEST" || true
        else
            echo "No TSP_OBJECT_DIAG_051_V1 launch marker found."
        fi
        echo
        echo "===== RELEVANT LATEST-RUN LINES ====="
        if [ -s "$OUT.latest" ]; then
            grep -E \
              'Bad LiveCellRef cast to STAT|failed to render|TSP_OBJINSERT|TSP_OBJROOT|TSP_VISOBJ_ATTACH|TSP_VISOBJ_CULL|TSP_NAVOBJ|TSP_PICK_|TSP_OBJECT_DIAG_051_V1' \
              "$OUT.latest" || true
        else
            grep -E \
              'Bad LiveCellRef cast to STAT|failed to render|TSP_OBJINSERT|TSP_OBJROOT|TSP_VISOBJ_ATTACH|TSP_VISOBJ_CULL|TSP_NAVOBJ|TSP_PICK_|TSP_OBJECT_DIAG_051_V1' \
              "$RAW" || true
        fi
    } >"$OUT"

    rm -f "$OUT.latest" "$RAW"

    echo
    echo "Validation saved:"
    echo "  $OUT"
    echo
    echo "Upload that ONE validation .txt file if anything is still wrong."
    return 0
}

rollback_fix() {
    [ -f "$STATE" ] || die "No state file found: $STATE"
    # shellcheck disable=SC1090
    . "$STATE"

    ensure_docker
    ensure_ssh

    [ -n "${SOURCE_BACKUP:-}" ] || die "STATE missing SOURCE_BACKUP"
    [ -n "${DEVICE_BACKUP:-}" ] || die "STATE missing DEVICE_BACKUP"

    echo "Rolling Docker source back from:"
    echo "  $SOURCE_BACKUP"

    docker exec "$CTR" bash -lc "
        set -e
        test -f '$SOURCE_BACKUP/apps/openmw/mwrender/animation.cpp'
        test -f '$SOURCE_BACKUP/apps/openmw/mwrender/objectpaging.cpp'
        cp -f '$SOURCE_BACKUP/apps/openmw/mwrender/animation.cpp' '$ANIM'
        cp -f '$SOURCE_BACKUP/apps/openmw/mwrender/objectpaging.cpp' '$PAGING'
    "

    echo "Restoring device binary from:"
    echo "  $DEVICE_BACKUP"

    ssh "$DEV" "bash -s" <<TSP_ROLLBACK
set -e
test -f '$DEVICE_BACKUP'
cp -pf '$DEVICE_BACKUP' '$REMOTE_BIN'
chmod 755 '$REMOTE_BIN'
sync
sha256sum '$REMOTE_BIN'
TSP_ROLLBACK

    echo
    echo "ROLLBACK COMPLETE."
    echo "Docker source and the installed TSP binary are back to the pre-fix state."
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
echo "OpenMW 0.51 TSP OBJECT CLASS FIX V1"
echo "============================================================"
echo "Container: $CTR"
echo "Device:    $DEV"
echo "Host out:  $HOST_OUT"
echo "Log:       $LOG"
echo
echo "Fix A: type-safe, Static-only VISGRID callback"
echo "Fix B: containers bypass exterior object paging"
echo "============================================================"

ensure_docker
ensure_ssh

echo
echo "===== PRE-FLIGHT: GAME MUST NOT BE RUNNING ====="
if ssh "$DEV" "pgrep -af 'openmw-0\.51|/openmw([[:space:]]|$)' 2>/dev/null" | grep -v pgrep; then
    die "OpenMW appears to be running on the TSP. Exit the game normally, then rerun this script."
fi
echo "PASS: OpenMW is not running."

echo
echo "===== VERIFY CURRENT SOURCE / BINARY IDENTITY ====="
docker exec "$CTR" bash -lc "
    set -e
    test -f '$ANIM'
    test -f '$PAGING'
    test -f '$BUILT'
    echo 'animation.cpp:'
    sha256sum '$ANIM'
    echo 'objectpaging.cpp:'
    sha256sum '$PAGING'
    echo 'current built binary:'
    file '$BUILT'
    sha256sum '$BUILT'
"

PRE_DEVICE_SHA="$(ssh "$DEV" "sha256sum '$REMOTE_BIN' | awk '{print \$1}'")"
echo "Current device binary SHA256:"
echo "  $PRE_DEVICE_SHA"

echo
echo "===== SOURCE BACKUP ====="
SOURCE_BACKUP="$SRC/.tsp-051-source-backups/object-class-fix-v1-$STAMP"
docker exec "$CTR" bash -lc "
    set -e
    mkdir -p '$SOURCE_BACKUP/apps/openmw/mwrender'
    cp -a '$ANIM' '$SOURCE_BACKUP/apps/openmw/mwrender/animation.cpp'
    cp -a '$PAGING' '$SOURCE_BACKUP/apps/openmw/mwrender/objectpaging.cpp'
    echo '$SOURCE_BACKUP'
    sha256sum \
      '$SOURCE_BACKUP/apps/openmw/mwrender/animation.cpp' \
      '$SOURCE_BACKUP/apps/openmw/mwrender/objectpaging.cpp'
"

echo
echo "===== APPLY SURGICAL SOURCE FIX ====="
docker exec -i "$CTR" python3 - "$ANIM" "$PAGING" <<'PY_PATCH'
import re
import sys

anim_path = sys.argv[1]
paging_path = sys.argv[2]

def read(path):
    with open(path, "r", encoding="utf-8", newline="") as f:
        return f.read()

def write(path, text):
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(text)

anim = read(anim_path)
paging = read(paging_path)

# ------------------------------------------------------------------
# A. VISGRID object classification.
#
# Ptr::get<ESM::Static>() is a typed LiveCellRef cast. It THROWS when the
# reference is Container/Misc/Book/etc. It must never be used as a type test.
# ------------------------------------------------------------------
if "TSP_VISGRID_OBJECT_CLASS_FIX_051_V1" not in anim:
    unsafe_patterns = [
        (
            r"const bool tspIsStatic\s*=\s*"
            r"!tspDiagActor\s*&&\s*!tspDiagDoor\s*&&\s*"
            r"mPtr\.get<ESM::Static>\(\)\s*!=\s*nullptr\s*;",
            "const bool tspIsStatic = mPtr.getType() == ESM::Static::sRecordId;"
        ),
        (
            r"const bool tspIsStatic\s*=\s*"
            r"mPtr\.get<ESM::Static>\(\)\s*!=\s*nullptr\s*;",
            "const bool tspIsStatic = mPtr.getType() == ESM::Static::sRecordId;"
        ),
    ]

    replacements = 0
    for pattern, replacement in unsafe_patterns:
        anim, n = re.subn(pattern, replacement, anim, count=1, flags=re.MULTILINE)
        replacements += n
        if n:
            break

    if replacements != 1:
        raise RuntimeError(
            "animation.cpp: expected exactly one unsafe ESM::Static LiveCellRef cast; "
            "found/replaced %d" % replacements
        )

    # Current diagnostic build: only real ESM::Static refs receive the callback.
    diag_if = re.compile(
        r"(?P<indent>^[ \t]*)if\s*\(\s*!tspDiagActor\s*&&\s*!tspDiagDoor\s*\)\s*\n"
        r"(?P=indent)\{",
        re.MULTILINE,
    )
    anim, diag_n = diag_if.subn(
        lambda m: m.group("indent") + "if (tspIsStatic)\n" + m.group("indent") + "{",
        anim,
        count=1,
    )

    # Fallback for a non-diagnostic V20/V23 lineage source.
    fallback_n = 0
    if diag_n == 0:
        fallback_if = re.compile(
            r"(?P<indent>^[ \t]*)if\s*\(\s*!mPtr\.getClass\(\)\.isActor\(\)\s*"
            r"&&\s*!mPtr\.getClass\(\)\.isDoor\(\)\s*\)\s*\n"
            r"(?P=indent)\{",
            re.MULTILINE,
        )
        anim, fallback_n = fallback_if.subn(
            lambda m: m.group("indent")
            + "if (mPtr.getType() == ESM::Static::sRecordId)\n"
            + m.group("indent") + "{",
            anim,
            count=1,
        )

    if diag_n + fallback_n != 1:
        raise RuntimeError(
            "animation.cpp: could not uniquely convert the VISGRID attachment condition "
            "to Static-only"
        )

    # Diagnostic field must describe the NEW callback policy.
    callback_patterns = [
        r'<<\s*" callback="\s*<<\s*\(\(\s*!tspDiagActor\s*&&\s*!tspDiagDoor\s*\)\s*\?\s*1\s*:\s*0\s*\)',
        r'<<\s*" callback="\s*<<\s*\(\s*!tspDiagActor\s*&&\s*!tspDiagDoor\s*\)',
    ]
    for pattern in callback_patterns:
        anim, n = re.subn(
            pattern,
            '<< " callback=" << (tspIsStatic ? 1 : 0)',
            anim,
            count=1,
        )
        if n:
            break

    # Put a durable source marker immediately above the safe classification.
    anchor = "const bool tspIsStatic = mPtr.getType() == ESM::Static::sRecordId;"
    if anim.count(anchor) != 1:
        raise RuntimeError(
            "animation.cpp: safe static classification anchor count is %d, expected 1"
            % anim.count(anchor)
        )
    anim = anim.replace(
        anchor,
        "// TSP_VISGRID_OBJECT_CLASS_FIX_051_V1\n"
        "        // Ptr::get<ESM::Static>() is a throwing cast, not a type predicate.\n"
        "        // Gameplay objects bypass the entire VISGRID callback.\n"
        "        " + anchor,
        1,
    )

# Hard safety checks.
if re.search(r"mPtr\.get<ESM::Static>\(\)", anim):
    raise RuntimeError(
        "animation.cpp: unsafe mPtr.get<ESM::Static>() remains after patch"
    )
if "TSP_VISGRID_OBJECT_CLASS_FIX_051_V1" not in anim:
    raise RuntimeError("animation.cpp: fix marker missing")
if anim.count("if (tspIsStatic)") < 1:
    raise RuntimeError(
        "animation.cpp: Static-only VISGRID callback gate is missing"
    )

# ------------------------------------------------------------------
# B. Containers must stay individual gameplay objects.
#
# Keep statics and the existing paging system intact. We only remove
# ESM3/ESM4 Container records from paging eligibility.
# ------------------------------------------------------------------
if "TSP_CONTAINER_PAGING_BYPASS_051_V1" not in paging:
    old = """                case ESM::REC_CONT:
                case ESM::REC_ACTI4:
                case ESM::REC_CONT4:
                case ESM::REC_FURN4:
                    return !far;
"""
    new = """                // TSP_CONTAINER_PAGING_BYPASS_051_V1
                // Containers need an individual scene identity and Bullet body.
                // Never replace a gameplay container with only a merged paging shell.
                case ESM::REC_CONT:
                case ESM::REC_CONT4:
                    return false;
                case ESM::REC_ACTI4:
                case ESM::REC_FURN4:
                    return !far;
"""
    if paging.count(old) != 1:
        raise RuntimeError(
            "objectpaging.cpp: expected one stock container paging typeFilter block; "
            "found %d" % paging.count(old)
        )
    paging = paging.replace(old, new, 1)

if "TSP_CONTAINER_PAGING_BYPASS_051_V1" not in paging:
    raise RuntimeError("objectpaging.cpp: container paging bypass marker missing")

# Ensure REC_CONT / REC_CONT4 are false in the typeFilter region.
tf_start = paging.find("bool typeFilter(int type, bool far)")
tf_end = paging.find("template <typename Record>", tf_start)
if tf_start < 0 or tf_end < 0:
    raise RuntimeError("objectpaging.cpp: could not isolate typeFilter")
tf = paging[tf_start:tf_end]
if "case ESM::REC_CONT:" not in tf or "case ESM::REC_CONT4:" not in tf:
    raise RuntimeError("objectpaging.cpp: container cases missing from typeFilter")
if not re.search(
    r"case ESM::REC_CONT:\s*case ESM::REC_CONT4:\s*return false;",
    tf,
    flags=re.MULTILINE,
):
    raise RuntimeError("objectpaging.cpp: container cases are not forced to return false")

write(anim_path, anim)
write(paging_path, paging)

print("PASS: animation.cpp uses a non-throwing Static type check.")
print("PASS: entire VISGRID callback is gated to ESM::Static only.")
print("PASS: ESM3/ESM4 containers are excluded from object paging.")
PY_PATCH

echo
echo "===== POST-PATCH SOURCE VERIFICATION ====="
docker exec "$CTR" bash -lc "
    set -e
    echo '--- VISGRID fix ---'
    grep -nE -B5 -A25 \
      'TSP_VISGRID_OBJECT_CLASS_FIX_051_V1|const bool tspIsStatic|if \\(tspIsStatic\\)|callback=' \
      '$ANIM' | head -140

    echo
    echo 'Unsafe Static casts remaining:'
    COUNT=\$(grep -cF 'mPtr.get<ESM::Static>()' '$ANIM' || true)
    echo \"  \$COUNT\"
    [ \"\$COUNT\" -eq 0 ]

    echo
    echo '--- Container paging fix ---'
    grep -nE -B12 -A18 \
      'TSP_CONTAINER_PAGING_BYPASS_051_V1|case ESM::REC_CONT|case ESM::REC_CONT4' \
      '$PAGING' | head -120
"

echo
echo "===== INCREMENTAL BUILD ====="
BUILD_LOG="/root/openmw51-object-fix-v1-build-$STAMP.log"
set +e
docker exec "$CTR" bash -lc "
    set -o pipefail
    cd '$BUILD'
    cmake --build . --target openmw --parallel '${OPENMW_JOBS:-1}' 2>&1 \
      | tee '$BUILD_LOG'
"
BUILD_RC=$?
set -e

if [ "$BUILD_RC" -ne 0 ]; then
    echo
    echo "BUILD FAILED."
    echo "Docker build log: $BUILD_LOG"
    echo
    echo "Last 160 build-log lines:"
    docker exec "$CTR" bash -lc "tail -n 160 '$BUILD_LOG' || true"
    echo
    echo "Source backup remains at:"
    echo "  $SOURCE_BACKUP"
    exit "$BUILD_RC"
fi

echo
echo "===== PACKAGE + MULTI-METHOD VERIFY ====="
docker exec "$CTR" bash -lc "
    set -e
    test -f '$BUILT'
    mkdir -p '$(dirname "$PACKAGED")'
    install -m 755 '$BUILT' '$PACKAGED'

    echo 'Built:'
    ls -lh '$BUILT'
    file '$BUILT'
    sha256sum '$BUILT'

    echo
    echo 'Packaged:'
    ls -lh '$PACKAGED'
    file '$PACKAGED'
    sha256sum '$PACKAGED'

    file '$PACKAGED' | grep -Eq 'ARM aarch64|ARM64|AArch64'

    # Marker checks are supplemental only. Build/ELF/hash/path checks above
    # remain authoritative.
    echo
    echo 'Supplemental marker scan:'
    strings '$PACKAGED' | grep -E \
      'TSP_OBJECT_DIAG_051_V1|TSP_INTERIOR_VISGRID_051_V5_TOPO_PVS' \
      | sort -u | head -30 || true
"

NEW_SHA="$(docker exec "$CTR" sha256sum "$PACKAGED" | awk '{print $1}')"
[ -n "$NEW_SHA" ] || die "Could not determine rebuilt package SHA256"
[ "$NEW_SHA" != "$PRE_DEVICE_SHA" ] \
    || die "Rebuilt binary hash did not change; refusing to install"

echo
echo "===== COPY RESULT TO ~/Downloads ====="
if [ -f "$HOST_OUT" ]; then
    cp -pf "$HOST_OUT" "$HOST_OUT.before-$STAMP"
fi
docker cp "$CTR:$PACKAGED" "$HOST_OUT"
chmod +x "$HOST_OUT"

HOST_SHA="$(sha256sum "$HOST_OUT" | awk '{print $1}')"
[ "$HOST_SHA" = "$NEW_SHA" ] || die "Docker->Ubuntu hash mismatch"

ls -lh "$HOST_OUT"
file "$HOST_OUT"
sha256sum "$HOST_OUT"

echo
echo "===== DEVICE BACKUP + INSTALL ====="
DEVICE_BACKUP_DIR="$ROOT/backups/object-class-fix-v1-$STAMP"
DEVICE_BACKUP="$DEVICE_BACKUP_DIR/openmw-0.51.before-object-class-fix-v1"

ssh "$DEV" "mkdir -p '$DEVICE_BACKUP_DIR' && cp -pf '$REMOTE_BIN' '$DEVICE_BACKUP'"
scp "$HOST_OUT" "$DEV:$REMOTE_TMP"

ssh "$DEV" "bash -s" <<TSP_INSTALL
set -e
test -f '$REMOTE_TMP'
INCOMING_SHA="\$(sha256sum '$REMOTE_TMP' | awk '{print \$1}')"
[ "\$INCOMING_SHA" = '$NEW_SHA' ] || {
    echo "ERROR: Ubuntu->TSP incoming hash mismatch"
    exit 71
}
install -m 755 '$REMOTE_TMP' '$REMOTE_BIN'
rm -f '$REMOTE_TMP'
sync
FINAL_SHA="\$(sha256sum '$REMOTE_BIN' | awk '{print \$1}')"
[ "\$FINAL_SHA" = '$NEW_SHA' ] || {
    echo "ERROR: installed TSP hash mismatch"
    exit 72
}
echo "Installed TSP binary:"
ls -lh '$REMOTE_BIN'
file '$REMOTE_BIN' 2>/dev/null || true
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
echo "Old device SHA: $PRE_DEVICE_SHA"
echo "New device SHA: $NEW_SHA"
echo
echo "Docker source backup:"
echo "  $SOURCE_BACKUP"
echo
echo "Device binary backup:"
echo "  $DEVICE_BACKUP"
echo
echo "Ubuntu binary:"
echo "  $HOST_OUT"
echo
echo "State file:"
echo "  $STATE"
echo
echo "NO Lua/topology/doorgraph/navmesh files were changed."
echo
echo "ONE correctness run only:"
echo "  1. Enter a previously broken interior."
echo "     Check containers + books + cups/silverware/food/weapons."
echo "  2. Confirm an interior container opens and has collision."
echo "  3. Go to a previously visible-but-walk-through exterior crate."
echo "     Confirm it is solid and activates."
echo "  4. Exit OpenMW normally."
echo
echo "Then run:"
echo "  cd ~/Downloads"
echo "  ./fix_openmw51_visgrid_objects_v1.sh collect"
echo
echo "If you need to revert:"
echo "  ./fix_openmw51_visgrid_objects_v1.sh rollback"
echo "============================================================"
