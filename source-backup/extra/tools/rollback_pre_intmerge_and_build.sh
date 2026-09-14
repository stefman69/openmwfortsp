#!/usr/bin/env bash
set -Eeuo pipefail

CONTAINER="openmw_builder"
SRC="/root/openmw-0.51-tsp-src"
BUILD="/root/openmw-0.51-tsp-build"
BUILT="$BUILD/openmw"
CONTAINER_OUT="/root/openmw-0.51-pre-intmerge"
CONTAINER_INFO="/root/openmw-0.51-pre-intmerge-info.txt"
HOST_DIR="$HOME/Downloads"
HOST_OUT="$HOST_DIR/openmw-0.51"
HOST_INFO="$HOST_DIR/openmw-0.51-pre-intmerge-info.txt"
STAMP="$(date +%Y%m%d-%H%M%S)"

mkdir -p "$HOST_DIR"

if ! command -v docker >/dev/null 2>&1; then
    echo "ERROR: docker is not installed/available in this Ubuntu session."
    exit 1
fi

if ! docker inspect "$CONTAINER" >/dev/null 2>&1; then
    echo "ERROR: Docker container '$CONTAINER' does not exist."
    exit 1
fi

docker start "$CONTAINER" >/dev/null

echo "============================================================"
echo "OpenMW 0.51 PRE-INTMERGE rollback + rebuild"
echo "Container: $CONTAINER"
echo "Source:    $SRC"
echo "Build:     $BUILD"
echo "============================================================"

docker exec -i -e TSP_STAMP="$STAMP" "$CONTAINER" bash -s <<'DOCKER_ROLLBACK'
set -Eeuo pipefail
SRC=/root/openmw-0.51-tsp-src
BUILD=/root/openmw-0.51-tsp-build
BUILT="$BUILD/openmw"
OUT=/root/openmw-0.51-pre-intmerge
INFO=/root/openmw-0.51-pre-intmerge-info.txt
cd "$SRC"

if [ ! -d .git ]; then
    echo "ERROR: $SRC is not a git working tree."
    exit 1
fi

# Refuse to destroy tracked work from another experiment/chat.
if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "ERROR: tracked source changes are currently uncommitted."
    echo "Nothing was reset or built. Current status:"
    git status --short --untracked-files=no
    exit 1
fi

HEAD_BEFORE=$(git rev-parse HEAD)
BRANCH_BEFORE=$(git symbolic-ref --short -q HEAD || echo DETACHED)

# Find the exact commit where TSP_INTMERGE_V1 first appears in objectpaging.cpp.
# Do not depend on Claude's abbreviated commit hash or commit-message wording.
INTMERGE=""
FILE=apps/openmw/mwrender/objectpaging.cpp
for c in $(git log --all --format=%H -- "$FILE"); do
    if git show "$c:$FILE" 2>/dev/null | grep -q "TSP_INTMERGE_V1"; then
        p=$(git rev-parse "$c^")
        if ! git show "$p:$FILE" 2>/dev/null | grep -q "TSP_INTMERGE_V1"; then
            INTMERGE=$c
            break
        fi
    fi
done

if [ -z "$INTMERGE" ]; then
    echo "ERROR: could not locate the commit that introduced TSP_INTMERGE_V1."
    echo "Nothing changed."
    exit 1
fi

PRE=$(git rev-parse "$INTMERGE^")

if ! git merge-base --is-ancestor "$INTMERGE" "$HEAD_BEFORE"; then
    if [ "$HEAD_BEFORE" = "$PRE" ]; then
        echo "Source is already exactly at the pre-INTMERGE parent."
    else
        echo "ERROR: current HEAD does not descend from the located INTMERGE commit."
        echo "HEAD:      $HEAD_BEFORE"
        echo "INTMERGE:  $INTMERGE"
        echo "PRE:       $PRE"
        echo "Refusing to guess which history you intended."
        exit 1
    fi
fi

BACKUP_BRANCH="backup/pre-intmerge-rollback-${TSP_STAMP}"
if [ "$HEAD_BEFORE" != "$PRE" ]; then
    git branch "$BACKUP_BRANCH" "$HEAD_BEFORE"
fi

echo
echo "Current branch : $BRANCH_BEFORE"
echo "Current HEAD   : $HEAD_BEFORE"
echo "INTMERGE commit: $INTMERGE"
echo "Rollback target: $PRE"
if [ "$HEAD_BEFORE" != "$PRE" ]; then
    echo "Safety branch  : $BACKUP_BRANCH"
    echo
    echo "Commits being removed from the active source tree:"
    git --no-pager log --oneline --decorate "$PRE..$HEAD_BEFORE" | head -30
fi

echo
if [ "$HEAD_BEFORE" != "$PRE" ]; then
    git reset --hard "$PRE"
fi

# Clean rollback verification: the three changed source files must not retain INTMERGE.
for f in \
    apps/openmw/mwrender/objectpaging.cpp \
    apps/openmw/mwworld/scene.cpp \
    apps/openmw/mwrender/objects.cpp
do
    if grep -q "TSP_INTMERGE_V1" "$f"; then
        echo "ERROR: INTMERGE marker survived rollback in $f"
        exit 1
    fi
done

echo "PASS: TSP_INTMERGE_V1 absent from all three rollback source files."

echo
echo "Incrementally rebuilding OpenMW 0.51 with Ninja..."
cmake --build "$BUILD" --target openmw -- -j4

if [ ! -x "$BUILT" ]; then
    echo "ERROR: build returned but executable is missing: $BUILT"
    exit 1
fi

FILE_DESC=$(file "$BUILT")
echo "$FILE_DESC"
if ! printf "%s\n" "$FILE_DESC" | grep -qi "aarch64"; then
    echo "ERROR: built executable does not identify as AArch64."
    exit 1
fi

if grep -a -q "TSP_INTMERGE_V1" "$BUILT"; then
    echo "ERROR: rebuilt binary still contains TSP_INTMERGE_V1."
    exit 1
fi

echo "PASS: rebuilt binary does not contain TSP_INTMERGE_V1."
cp -f "$BUILT" "$OUT"
chmod 755 "$OUT"
SHA=$(sha256sum "$OUT" | awk "{print \$1}")

{
    echo "OpenMW 0.51 pre-INTMERGE build"
    echo "Built: $(date)"
    echo "Original branch: $BRANCH_BEFORE"
    echo "Original HEAD: $HEAD_BEFORE"
    echo "INTMERGE commit: $INTMERGE"
    echo "Active rollback HEAD: $(git rev-parse HEAD)"
    if [ "$HEAD_BEFORE" != "$PRE" ]; then
        echo "Restore branch: $BACKUP_BRANCH"
    fi
    echo "Binary: $OUT"
    echo "SHA256: $SHA"
    echo "INTMERGE marker in binary: 0"
    if grep -a -q "TSP_LIGHTSIMPLE_V3" "$OUT"; then
        echo "TSP_LIGHTSIMPLE_V3 marker: present"
    else
        echo "TSP_LIGHTSIMPLE_V3 marker: absent"
    fi
    echo
    echo "To restore the source tree later (then rebuild):"
    if [ "$HEAD_BEFORE" != "$PRE" ]; then
        echo "  git -C $SRC reset --hard $BACKUP_BRANCH"
    else
        echo "  Source was already pre-INTMERGE; no restore needed."
    fi
} > "$INFO"

cat "$INFO"
DOCKER_ROLLBACK


if [ -e "$HOST_OUT" ]; then
    cp -f "$HOST_OUT" "$HOST_OUT.before-pre-intmerge-$STAMP"
    echo "Backed up previous ~/Downloads/openmw-0.51"
fi

docker cp "$CONTAINER:$CONTAINER_OUT" "$HOST_OUT"
docker cp "$CONTAINER:$CONTAINER_INFO" "$HOST_INFO"
chmod +x "$HOST_OUT"

echo
echo "============================================================"
echo "READY FOR STOCK TSP MANUAL COPY"
echo "============================================================"
ls -lh "$HOST_OUT"
file "$HOST_OUT"
sha256sum "$HOST_OUT"
echo
echo "Copy this file from Ubuntu/your PC:"
echo "  $HOST_OUT"
echo "to the stock TSP SD card as:"
echo "  /mnt/SDCARD/data/ports/openmw51/bin/openmw-0.51"
echo
echo "Build/rollback record:"
echo "  $HOST_INFO"
echo "============================================================"
