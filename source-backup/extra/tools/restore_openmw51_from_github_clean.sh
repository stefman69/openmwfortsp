#!/usr/bin/env bash
set -Eeuo pipefail

# Restore the active OpenMW/TSP source tree to the current default-branch HEAD of:
#   https://github.com/stefman69/openmwfortsp
# while preserving the entire current/interior-performance experiment lineage first.
#
# Run on the Ubuntu VM from ~/Downloads.

CONTAINER="${OPENMW_CONTAINER:-openmw_builder}"
SRC="/root/openmw-0.51-tsp-src"
BUILD="/root/openmw-0.51-tsp-build"
REMOTE_URL="https://github.com/stefman69/openmwfortsp.git"
REMOTE_NAME="tspgithub"
HOST_OUT="${HOME}/Downloads"
STAMP="$(date +%Y%m%d-%H%M%S)"
PRESERVE_BRANCH="tsp-interior-experiments-preserved-${STAMP}"
INTMERGE_BRANCH="tsp-interior-merge-lineage-${STAMP}"
CLEAN_BRANCH="tsp-clean-github-restore"
PRESERVE_DIR="/root/tsp-source-preserve/${STAMP}"
REPORT_IN_CONTAINER="${PRESERVE_DIR}/restore-report.txt"
BUILD_LOG="/root/openmw-github-restore-build-${STAMP}.log"
BUILT="${BUILD}/openmw"
HOST_BINARY="${HOST_OUT}/openmw-0.51"
HOST_REPORT="${HOST_OUT}/openmw51-github-restore-report.txt"
HOST_BUNDLE="${HOST_OUT}/openmw51-pre-restore-history.bundle"
HOST_TREE_TAR="${HOST_OUT}/openmw51-pre-restore-source-tree.tar.gz"
HOST_DEFAULTS="${HOST_OUT}/defaults.bin"

say() { printf '%s\n' "$*"; }
die() { say "ERROR: $*" >&2; exit 1; }

command -v docker >/dev/null 2>&1 || die "docker is not installed on the Ubuntu VM"
docker inspect "$CONTAINER" >/dev/null 2>&1 || die "Docker container '$CONTAINER' does not exist"
if [ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER")" != "true" ]; then
    say "Starting Docker container: $CONTAINER"
    docker start "$CONTAINER" >/dev/null
fi
mkdir -p "$HOST_OUT"

say "============================================================"
say "OpenMW/TSP clean GitHub restore"
say "Remote:   $REMOTE_URL"
say "Source:   $SRC"
say "Preserve: $PRESERVE_BRANCH"
say "============================================================"

# Everything destructive happens only after the remote snapshot is fetched and validated.
set +e
docker exec \
    -e SRC="$SRC" \
    -e BUILD="$BUILD" \
    -e REMOTE_URL="$REMOTE_URL" \
    -e REMOTE_NAME="$REMOTE_NAME" \
    -e STAMP="$STAMP" \
    -e PRESERVE_BRANCH="$PRESERVE_BRANCH" \
    -e INTMERGE_BRANCH="$INTMERGE_BRANCH" \
    -e CLEAN_BRANCH="$CLEAN_BRANCH" \
    -e PRESERVE_DIR="$PRESERVE_DIR" \
    -e REPORT="$REPORT_IN_CONTAINER" \
    -e BUILD_LOG="$BUILD_LOG" \
    -e BUILT="$BUILT" \
    "$CONTAINER" bash -lc '
set -Eeuo pipefail
say() { printf "%s\n" "$*"; }
die() { say "ERROR: $*" >&2; exit 1; }

[ -d "$SRC/.git" ] || die "$SRC is not a Git working tree"
[ -f "$BUILD/build.ninja" ] || die "configured Ninja tree missing: $BUILD/build.ninja"
mkdir -p "$PRESERVE_DIR"
cd "$SRC"

ORIGINAL_HEAD="$(git rev-parse HEAD)"
ORIGINAL_BRANCH="$(git symbolic-ref --quiet --short HEAD || printf detached)"
ORIGINAL_STATUS="$(git status --porcelain=v1 --untracked-files=all || true)"

say "Current branch: $ORIGINAL_BRANCH"
say "Current HEAD:   $ORIGINAL_HEAD"

# 1) Preserve the committed lineage by creating a local branch at the exact current HEAD.
if git show-ref --verify --quiet "refs/heads/$PRESERVE_BRANCH"; then
    die "preservation branch unexpectedly already exists: $PRESERVE_BRANCH"
fi
git branch "$PRESERVE_BRANCH" "$ORIGINAL_HEAD"
say "Preservation branch created: $PRESERVE_BRANCH -> $ORIGINAL_HEAD"

# Also pin a branch directly to the newest existing history state whose tree still
# contains the interior-merge implementation. This protects that experimental lineage
# even if current HEAD is already on a later revert or rollback commit.
INTMERGE_TREE_COMMIT=""
while IFS= read -r c; do
    if git grep -q "TSP_INTMERGE_V1" "$c" -- apps components 2>/dev/null; then
        INTMERGE_TREE_COMMIT="$c"
        break
    fi
done < <(git log --all --format=%H -- apps/openmw/mwrender/objectpaging.cpp apps/openmw/mwworld/scene.cpp apps/openmw/mwrender/objects.cpp)
if [ -n "$INTMERGE_TREE_COMMIT" ]; then
    git branch "$INTMERGE_BRANCH" "$INTMERGE_TREE_COMMIT"
    say "Interior-merge lineage branch: $INTMERGE_BRANCH -> $INTMERGE_TREE_COMMIT"
else
    say "NOTE: no reachable Git commit containing TSP_INTMERGE_V1 was found; the exact working-tree tar still preserves uncommitted files."
fi

# 2) Preserve all refs/history in a standalone Git bundle.
git bundle create "$PRESERVE_DIR/pre-restore-history.bundle" --all
[ -s "$PRESERVE_DIR/pre-restore-history.bundle" ] || die "Git bundle creation failed"

# 3) Preserve the exact working tree too, including untracked/ignored experiment files and
#    the old .tsp source backups. The .git database is omitted because the bundle owns history.
tar --exclude="./.git" -czf "$PRESERVE_DIR/pre-restore-source-tree.tar.gz" -C "$SRC" .
[ -s "$PRESERVE_DIR/pre-restore-source-tree.tar.gz" ] || die "source-tree tarball creation failed"

# 4) Fetch the GitHub backup without changing the active tree.
if git remote get-url "$REMOTE_NAME" >/dev/null 2>&1; then
    git remote set-url "$REMOTE_NAME" "$REMOTE_URL"
else
    git remote add "$REMOTE_NAME" "$REMOTE_URL"
fi
say "Fetching GitHub backup..."
git fetch --prune --tags "$REMOTE_NAME"

DEFAULT_REF="$(git ls-remote --symref "$REMOTE_URL" HEAD 2>/dev/null | awk "/^ref:/ {print \$2; exit}")"
DEFAULT_BRANCH="${DEFAULT_REF#refs/heads/}"
if [ -z "$DEFAULT_BRANCH" ] || [ "$DEFAULT_BRANCH" = "$DEFAULT_REF" ]; then
    if git show-ref --verify --quiet "refs/remotes/$REMOTE_NAME/main"; then
        DEFAULT_BRANCH=main
    elif git show-ref --verify --quiet "refs/remotes/$REMOTE_NAME/master"; then
        DEFAULT_BRANCH=master
    else
        die "could not determine the GitHub repository default branch"
    fi
fi
REMOTE_REF="refs/remotes/$REMOTE_NAME/$DEFAULT_BRANCH"
git show-ref --verify --quiet "$REMOTE_REF" || die "fetched default branch is missing: $REMOTE_REF"
REMOTE_HEAD="$(git rev-parse "$REMOTE_REF")"
REMOTE_DATE="$(git show -s --format=%cI "$REMOTE_HEAD")"
REMOTE_SUBJECT="$(git show -s --format=%s "$REMOTE_HEAD")"

say "GitHub default branch: $DEFAULT_BRANCH"
say "GitHub restore SHA:    $REMOTE_HEAD"
say "GitHub commit date:     $REMOTE_DATE"
say "GitHub commit subject:  $REMOTE_SUBJECT"

# Validate that this really is an OpenMW/TSP source snapshot BEFORE discarding anything.
for path in \
    apps/openmw/engine.cpp \
    apps/openmw/mwrender/renderingmanager.cpp \
    apps/openmw/mwworld/scene.cpp \
    components/settings/categories/gui.hpp \
    files/settings-default.cfg
 do
    git cat-file -e "$REMOTE_HEAD:$path" 2>/dev/null || \
        die "GitHub snapshot does not contain expected source path: $path"
done

# This restore is specifically meant to be the branch point before interior merging.
# Refuse to overwrite the active tree if the GitHub backup itself already contains INTMERGE.
if git grep -q "TSP_INTMERGE_V1" "$REMOTE_HEAD" -- apps components 2>/dev/null; then
    die "GitHub default-branch HEAD already contains TSP_INTMERGE_V1; refusing to use it as the pre-interior-merge restart point"
fi

# Record a concise before/after ledger before the clean reset.
{
    echo "OpenMW/TSP GitHub clean restore"
    echo "timestamp=$STAMP"
    echo "source=$SRC"
    echo "original_branch=$ORIGINAL_BRANCH"
    echo "original_head=$ORIGINAL_HEAD"
    echo "preservation_branch=$PRESERVE_BRANCH"
    echo "intmerge_lineage_branch=${INTMERGE_BRANCH:-}"
    echo "intmerge_lineage_commit=${INTMERGE_TREE_COMMIT:-}"
    echo "remote_url=$REMOTE_URL"
    echo "remote_default_branch=$DEFAULT_BRANCH"
    echo "remote_head=$REMOTE_HEAD"
    echo "remote_date=$REMOTE_DATE"
    echo "remote_subject=$REMOTE_SUBJECT"
    echo
    echo "--- pre-restore working tree status ---"
    if [ -n "$ORIGINAL_STATUS" ]; then printf "%s\n" "$ORIGINAL_STATUS"; else echo "clean"; fi
    echo
    echo "--- commits present in current lineage but not GitHub restore point (first 100) ---"
    git log --oneline --decorate "$REMOTE_HEAD..$ORIGINAL_HEAD" -100 2>/dev/null || true
} > "$REPORT"

# 5) Fresh restart: discard the active working copy only AFTER branch+bundle+tar+remote validation.
git reset --hard HEAD
git clean -fdx
# Re-create preserve directory because git clean may remove source-local generated paths only;
# our preservation artifacts live under /root, outside $SRC.
git switch -C "$CLEAN_BRANCH" "$REMOTE_HEAD"
git reset --hard "$REMOTE_HEAD"
git clean -fdx

git submodule sync --recursive || true
git submodule update --init --recursive || true

ACTIVE_HEAD="$(git rev-parse HEAD)"
[ "$ACTIVE_HEAD" = "$REMOTE_HEAD" ] || die "active HEAD $ACTIVE_HEAD does not equal GitHub restore $REMOTE_HEAD"
[ -z "$(git status --porcelain=v1 --untracked-files=all)" ] || die "active tree is not clean after restore"

# Explicitly prove that late interior-merge marker is not present if the GitHub backup predates it.
INTMERGE_COUNT="$(grep -R -l --exclude-dir=.git "TSP_INTMERGE_V1" apps components 2>/dev/null | wc -l | tr -d " ")"
{
    echo
    echo "--- restored active tree ---"
    echo "active_branch=$CLEAN_BRANCH"
    echo "active_head=$ACTIVE_HEAD"
    echo "working_tree=clean"
    echo "TSP_INTMERGE_V1_source_files=$INTMERGE_COUNT"
} >> "$REPORT"

say "Active source tree is now a clean checkout of $REMOTE_HEAD"
say "TSP_INTMERGE_V1 source-file count: $INTMERGE_COUNT"

# 6) Build. Git checkout gives changed files fresh mtimes, so Ninja will correctly rebuild every
#    object whose source differs while retaining unchanged toolchain/dependency objects.
rm -f "$BUILD_LOG"
say "Building openmw target..."
set +e
cmake --build "$BUILD" --target openmw -- -j4 >"$BUILD_LOG" 2>&1
BUILD_RC=$?
set -e
if [ "$BUILD_RC" -ne 0 ]; then
    {
        echo
        echo "build_result=FAIL"
        echo "build_exit=$BUILD_RC"
        echo "build_log=$BUILD_LOG"
        echo "--- first compiler/linker errors ---"
        grep -n -E "error:|undefined reference|FAILED:" "$BUILD_LOG" | head -40 || true
    } >> "$REPORT"
    say "BUILD FAILED. Source remains on the clean GitHub restore branch for inspection."
    say "Last 120 build-log lines:"
    tail -120 "$BUILD_LOG" || true
    exit "$BUILD_RC"
fi

[ -s "$BUILT" ] || die "build reported success but output is missing: $BUILT"
if command -v readelf >/dev/null 2>&1; then
    MACHINE="$(readelf -h "$BUILT" 2>/dev/null | awk -F: "/Machine:/ {gsub(/^[ \\t]+/, \"\", \$2); print \$2; exit}")"
    case "$MACHINE" in
        *AArch64*|*aarch64*) ;;
        *) die "built ELF machine is unexpected: $MACHINE" ;;
    esac
else
    MACHINE="readelf-unavailable"
fi
SHA256="$(sha256sum "$BUILT" | awk "{print \$1}")"
SIZE="$(stat -c %s "$BUILT")"
DEFAULTS_BUILT="$(find "$BUILD" -type f -name defaults.bin -printf "%T@ %p\n" 2>/dev/null | sort -nr | head -1 | cut -d" " -f2- || true)"

{
    echo
    echo "build_result=PASS"
    echo "binary=$BUILT"
    echo "binary_machine=$MACHINE"
    echo "binary_size=$SIZE"
    echo "binary_sha256=$SHA256"
    echo "defaults_bin=${DEFAULTS_BUILT:-not-found}"
    if [ -n "$DEFAULTS_BUILT" ] && [ -s "$DEFAULTS_BUILT" ]; then
        echo "defaults_sha256=$(sha256sum "$DEFAULTS_BUILT" | awk "{print \$1}")"
    fi
    echo "build_log=$BUILD_LOG"
} >> "$REPORT"

say "Build PASS"
say "Machine: $MACHINE"
say "SHA256:  $SHA256"
'
RESTORE_RC=$?
set -e

# Copy preservation/restore records back even if the fetch/restore/build step failed.
# That way a failed build can never strand the saved pre-restore lineage only inside Docker.
rm -f "$HOST_REPORT" "$HOST_BUNDLE" "$HOST_TREE_TAR"
if docker exec "$CONTAINER" test -s "$REPORT_IN_CONTAINER" >/dev/null 2>&1; then
    docker cp "$CONTAINER:$REPORT_IN_CONTAINER" "$HOST_REPORT" || true
fi
if docker exec "$CONTAINER" test -s "$PRESERVE_DIR/pre-restore-history.bundle" >/dev/null 2>&1; then
    docker cp "$CONTAINER:$PRESERVE_DIR/pre-restore-history.bundle" "$HOST_BUNDLE" || true
fi
if docker exec "$CONTAINER" test -s "$PRESERVE_DIR/pre-restore-source-tree.tar.gz" >/dev/null 2>&1; then
    docker cp "$CONTAINER:$PRESERVE_DIR/pre-restore-source-tree.tar.gz" "$HOST_TREE_TAR" || true
fi

if [ "$RESTORE_RC" -ne 0 ]; then
    say
    say "RESTORE/BUILD STOPPED with exit code $RESTORE_RC."
    say "The script did not pretend this succeeded."
    [ -s "$HOST_REPORT" ] && say "Restore report copied to: $HOST_REPORT"
    [ -s "$HOST_BUNDLE" ] && say "Git history bundle copied to: $HOST_BUNDLE"
    [ -s "$HOST_TREE_TAR" ] && say "Exact old source-tree tar copied to: $HOST_TREE_TAR"
    exit "$RESTORE_RC"
fi

# Successful build: copy the binary and independently verify Docker -> Ubuntu bytes.
rm -f "$HOST_BINARY"
docker cp "$CONTAINER:$BUILT" "$HOST_BINARY"
chmod +x "$HOST_BINARY" 2>/dev/null || true
[ -s "$HOST_BINARY" ] || die "host binary copy is missing"
rm -f "$HOST_DEFAULTS"
DEFAULTS_IN_CONTAINER="$(docker exec "$CONTAINER" bash -lc 'find /root/openmw-0.51-tsp-build -type f -name defaults.bin -printf "%T@ %p\n" 2>/dev/null | sort -nr | head -1 | cut -d" " -f2-' || true)"
if [ -n "$DEFAULTS_IN_CONTAINER" ] && docker exec "$CONTAINER" test -s "$DEFAULTS_IN_CONTAINER" >/dev/null 2>&1; then
    docker cp "$CONTAINER:$DEFAULTS_IN_CONTAINER" "$HOST_DEFAULTS"
fi
HOST_SHA="$(sha256sum "$HOST_BINARY" | awk '{print $1}')"
CONTAINER_SHA="$(docker exec "$CONTAINER" sha256sum "$BUILT" | awk '{print $1}')"
[ "$HOST_SHA" = "$CONTAINER_SHA" ] || die "Docker/Ubuntu binary SHA256 mismatch"

say
say "============================================================"
say "RESTORE COMPLETE"
say "============================================================"
say "Active Docker source branch: $CLEAN_BRANCH"
say "Preserved experiment branch: $PRESERVE_BRANCH"
say "Interior-merge history:      $INTMERGE_BRANCH (when marker was found)"
say "Rebuilt binary:              $HOST_BINARY"
say "Restore report:              $HOST_REPORT"
say "Git history bundle:          $HOST_BUNDLE"
say "Exact old working-tree tar:  $HOST_TREE_TAR"
say "Binary SHA256:               $HOST_SHA"
if [ -s "$HOST_DEFAULTS" ]; then say "Matching defaults.bin:        $HOST_DEFAULTS"; fi
say
say "Nothing was pushed to GitHub. The preservation branch exists locally in Docker,"
say "and the bundle/tarball are copied to ~/Downloads so this experiment lineage is recoverable."
