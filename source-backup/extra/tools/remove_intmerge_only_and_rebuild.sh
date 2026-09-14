#!/usr/bin/env bash
set -Eeuo pipefail

CONTAINER="openmw_builder"
SRC="/root/openmw-0.51-tsp-src"
BUILD="/root/openmw-0.51-tsp-build"
BUILT="$BUILD/openmw"
PREV_INFO="/root/openmw-0.51-pre-intmerge-info.txt"
CONTAINER_OUT="/root/openmw-0.51-no-intmerge"
CONTAINER_INFO="/root/openmw-0.51-no-intmerge-info.txt"
HOST_DIR="$HOME/Downloads"
HOST_OUT="$HOST_DIR/openmw-0.51"
HOST_INFO="$HOST_DIR/openmw-0.51-no-intmerge-info.txt"
STAMP="$(date +%Y%m%d-%H%M%S)"

mkdir -p "$HOST_DIR"
command -v docker >/dev/null 2>&1 || { echo "ERROR: docker is unavailable."; exit 1; }
docker inspect "$CONTAINER" >/dev/null 2>&1 || { echo "ERROR: container $CONTAINER does not exist."; exit 1; }
docker start "$CONTAINER" >/dev/null

echo "============================================================"
echo "OpenMW 0.51 A/B build: remove TSP_INTMERGE_V1 ONLY"
echo "Preserves current UI/text/default-setting source"
echo "============================================================"

docker exec -i -e TSP_STAMP="$STAMP" "$CONTAINER" bash -s <<'DOCKER'
set -Eeuo pipefail
SRC=/root/openmw-0.51-tsp-src
BUILD=/root/openmw-0.51-tsp-build
BUILT="$BUILD/openmw"
PREV_INFO=/root/openmw-0.51-pre-intmerge-info.txt
OUT=/root/openmw-0.51-no-intmerge
INFO=/root/openmw-0.51-no-intmerge-info.txt
BUILD_LOG=/root/openmw-0.51-no-intmerge-build.log
cd "$SRC"

F1=apps/openmw/mwrender/objectpaging.cpp
F2=apps/openmw/mwworld/scene.cpp
F3=apps/openmw/mwrender/objects.cpp

[ -d .git ] || { echo "ERROR: $SRC is not a git tree."; exit 1; }
if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "ERROR: tracked source changes are currently uncommitted."
    echo "Refusing to overwrite them."
    git status --short --untracked-files=no
    exit 1
fi

has_intmerge_at() {
    git show "$1:$F1" 2>/dev/null | grep -q 'TSP_INTMERGE_V1'
}

HEAD_START=$(git rev-parse HEAD)
RESTORED_FROM_PRIOR_ROLLBACK=0

# The previous whole-tree rollback saved its exact original HEAD in this record.
# If that test left the tree at the wrong old commit, restore that exact HEAD first.
if ! grep -q 'TSP_INTMERGE_V1' "$F1"; then
    if [ -r "$PREV_INFO" ]; then
        ORIGINAL_HEAD=$(sed -n 's/^Original HEAD: //p' "$PREV_INFO" | head -1)
        if [ -n "$ORIGINAL_HEAD" ] && git cat-file -e "$ORIGINAL_HEAD^{commit}" 2>/dev/null && has_intmerge_at "$ORIGINAL_HEAD"; then
            echo "Previous whole-tree rollback detected."
            echo "  current HEAD : $HEAD_START"
            echo "  restoring exact saved HEAD: $ORIGINAL_HEAD"
            git reset --hard "$ORIGINAL_HEAD"
            RESTORED_FROM_PRIOR_ROLLBACK=1
        else
            echo "ERROR: current tree has no INTMERGE, but the previous rollback record"
            echo "does not point to a valid saved HEAD containing INTMERGE."
            echo "Refusing to guess which source revision to restore."
            exit 1
        fi
    else
        echo "ERROR: current tree has no TSP_INTMERGE_V1 and no prior rollback record exists."
        echo "Refusing to guess the source revision."
        exit 1
    fi
fi

BASE_HEAD=$(git rev-parse HEAD)
BASE_BRANCH=$(git symbolic-ref --short -q HEAD || echo DETACHED)

# UI/default-setting safety sentinel. The bad test binary failed on this exact key.
mapfile -t UI_FILES < <(grep -RIl --exclude-dir=.git --exclude='*.before-*' -- 'controls font size' components apps files 2>/dev/null | sort || true)
if [ "${#UI_FILES[@]}" -eq 0 ]; then
    echo "ERROR: restored source does not contain the 'controls font size' UI setting."
    echo "This is not the source state we want to benchmark."
    exit 1
fi
UI_BEFORE=$(sha256sum "${UI_FILES[@]}" | sha256sum | awk '{print $1}')
echo "UI/default sentinel files: ${#UI_FILES[@]}"
printf '  %s\n' "${UI_FILES[@]}"
echo "UI sentinel hash before: $UI_BEFORE"

# Locate the introduction commit only on THIS restored HEAD's ancestry, never --all.
INTMERGE=""
for c in $(git rev-list HEAD -- "$F1"); do
    if has_intmerge_at "$c"; then
        p=$(git rev-parse "$c^")
        if ! has_intmerge_at "$p"; then
            INTMERGE="$c"
            break
        fi
    fi
done
[ -n "$INTMERGE" ] || { echo "ERROR: could not locate INTMERGE introduction on current ancestry."; exit 1; }
PRE=$(git rev-parse "$INTMERGE^")

echo
printf 'Base branch      : %s\n' "$BASE_BRANCH"
printf 'Base HEAD        : %s\n' "$BASE_HEAD"
printf 'INTMERGE commit  : %s\n' "$INTMERGE"
printf 'Its parent       : %s\n' "$PRE"
echo "Important: the whole tree will NOT be reset to that parent."
echo "Only the INTMERGE diff in the three render/world files will be reversed."

# Permanent recovery pointer + byte backups before touching source.
BACKUP_BRANCH="backup/before-intmerge-ab-${TSP_STAMP}"
git branch "$BACKUP_BRANCH" "$BASE_HEAD"
for f in "$F1" "$F2" "$F3"; do
    cp "$f" "$f.before-remove-intmerge-${TSP_STAMP}"
    cmp -s "$f" "$f.before-remove-intmerge-${TSP_STAMP}" || { echo "ERROR: backup verification failed: $f"; exit 1; }
done
echo "Safety branch: $BACKUP_BRANCH"
echo "Verified byte backups created beside all three source files."

DIFF=/tmp/tsp-intmerge-only-${TSP_STAMP}.diff
git diff "$PRE" "$INTMERGE" -- "$F1" "$F2" "$F3" > "$DIFF"
[ -s "$DIFF" ] || { echo "ERROR: INTMERGE three-file diff is empty."; exit 1; }

if ! git apply --reverse --check "$DIFF"; then
    echo "ERROR: the exact INTMERGE diff cannot be reversed cleanly on the restored current source."
    echo "Nothing was modified. This usually means one of those three files changed again later."
    exit 1
fi
git apply --reverse "$DIFF"

for f in "$F1" "$F2" "$F3"; do
    if grep -q 'TSP_INTMERGE_V1' "$f"; then
        echo "ERROR: INTMERGE marker survived in $f"
        git checkout "$BASE_HEAD" -- "$F1" "$F2" "$F3"
        exit 1
    fi
done

# The reverse operation must touch exactly these three tracked files and nothing else.
CHANGED=$(git diff --name-only | sort)
EXPECTED=$(printf '%s\n' "$F1" "$F2" "$F3" | sort)
if [ "$CHANGED" != "$EXPECTED" ]; then
    echo "ERROR: reverse patch changed an unexpected tracked-file set:"
    printf '%s\n' "$CHANGED"
    git checkout "$BASE_HEAD" -- "$F1" "$F2" "$F3"
    exit 1
fi

UI_AFTER=$(sha256sum "${UI_FILES[@]}" | sha256sum | awk '{print $1}')
if [ "$UI_AFTER" != "$UI_BEFORE" ]; then
    echo "ERROR: UI/default sentinel changed while removing INTMERGE. Restoring source."
    git checkout "$BASE_HEAD" -- "$F1" "$F2" "$F3"
    exit 1
fi
echo "PASS: UI/default-setting source remained byte-identical."
echo "PASS: TSP_INTMERGE_V1 removed from exactly three source files."

echo
echo "Incrementally rebuilding OpenMW 0.51..."
set +e
cmake --build "$BUILD" --target openmw -- -j4 2>&1 | tee "$BUILD_LOG"
RC=${PIPESTATUS[0]}
set -e
if [ "$RC" -ne 0 ]; then
    echo "BUILD FAILED (exit $RC). Restoring the three source files to $BASE_HEAD."
    git checkout "$BASE_HEAD" -- "$F1" "$F2" "$F3"
    echo "Build log preserved: $BUILD_LOG"
    exit "$RC"
fi

[ -x "$BUILT" ] || { echo "ERROR: build succeeded but $BUILT is missing."; exit 1; }
DESC=$(file "$BUILT")
echo "$DESC"
printf '%s\n' "$DESC" | grep -qi 'aarch64' || { echo "ERROR: rebuilt executable is not AArch64."; exit 1; }
if grep -a -q 'TSP_INTMERGE_V1' "$BUILT"; then
    echo "ERROR: rebuilt binary still contains TSP_INTMERGE_V1."
    exit 1
fi

# Supplementary UI compatibility check; source hash preservation above is the hard gate.
if strings "$BUILT" | grep -Fq 'controls font size'; then
    UI_STRING=present
else
    UI_STRING='not-found (non-fatal; source sentinel was preserved)'
fi

# Commit only after a green build, exact files only.
git add "$F1" "$F2" "$F3"
if ! git diff --cached --quiet; then
    git commit -q -m 'TSP A/B: remove TSP_INTMERGE_V1 only'
fi
NO_MERGE_HEAD=$(git rev-parse HEAD)

cp -f "$BUILT" "$OUT"
chmod 755 "$OUT"
SHA=$(sha256sum "$OUT" | awk '{print $1}')

{
    echo "OpenMW 0.51 - INTMERGE-only rollback A/B build"
    echo "Built: $(date)"
    echo "Started HEAD: $HEAD_START"
    echo "Restored from prior whole-tree rollback: $RESTORED_FROM_PRIOR_ROLLBACK"
    echo "Restored/base HEAD: $BASE_HEAD"
    echo "INTMERGE introduction: $INTMERGE"
    echo "No-INTMERGE commit: $NO_MERGE_HEAD"
    echo "Recovery branch: $BACKUP_BRANCH"
    echo "UI sentinel hash: $UI_BEFORE"
    echo "controls font size string in binary: $UI_STRING"
    echo "Build log: $BUILD_LOG"
    echo "Binary: $OUT"
    echo "SHA256: $SHA"
    echo "TSP_INTMERGE_V1 marker in binary: 0"
    echo
    echo "To restore the exact pre-A/B source later:"
    echo "  git -C $SRC reset --hard $BACKUP_BRANCH"
} > "$INFO"
cat "$INFO"
DOCKER

if [ -e "$HOST_OUT" ]; then
    cp -f "$HOST_OUT" "$HOST_OUT.before-no-intmerge-$STAMP"
    echo "Backed up previous $HOST_OUT"
fi

docker cp "$CONTAINER:$CONTAINER_OUT" "$HOST_OUT"
docker cp "$CONTAINER:$CONTAINER_INFO" "$HOST_INFO"
chmod +x "$HOST_OUT"

echo
echo "============================================================"
echo "READY: INTMERGE-ONLY ROLLBACK BINARY"
echo "============================================================"
ls -lh "$HOST_OUT"
file "$HOST_OUT"
sha256sum "$HOST_OUT"
echo
echo "Copy manually to the stock TSP as:"
echo "  /mnt/SDCARD/data/ports/openmw51/bin/openmw-0.51"
echo
echo "Record: $HOST_INFO"
echo "============================================================"
