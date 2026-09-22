#!/usr/bin/env bash
# tsp_backup_source_only_v3.sh
#
# SOURCE-ONLY backup for stefman69/openmwfortsp.
#
# NO DEVICE/CONSOLE ACCESS:
#   - no ssh
#   - no scp
#   - no TSP/TSPS card probing
#   - no launcher pulls
#   - no built binaries
#
# GitHub branch policy:
#   source-backup   = clean historical TSPS reference; NEVER written here
#   tsp-in-progress = ongoing original-TSP / PowerVR working branch
#
# If tsp-in-progress does not exist, this script creates it ONCE from
# origin/source-backup. After that, it only updates tsp-in-progress.
#
# Local source policy:
#   /root/gl4es-tsps                 = persistent TSPS source tree
#   /root/gl4es-tsp-pvr-texture-v2   = persistent original-TSP source tree
#   /root/openmw-0.51-tsp-src         = OpenMW source tree
#
# Future TSP patches should keep using the SAME TSP tree and make timestamped
# backups before edits. This backup script does not create another gl4es fork.
#
# Usage:
#   bash ~/Downloads/tsp_backup_source_only_v3.sh
#   bash ~/Downloads/tsp_backup_source_only_v3.sh list
#
# Optional source override:
#   TSP_ACTIVE_GL4ES=/root/gl4es-tsp-pvr-texture-v2 \
#     bash ~/Downloads/tsp_backup_source_only_v3.sh
#
# Optional extra source paths, one per line:
#   ~/tsp_backup_source_extra.txt
#
# Entries can be:
#   /path/on/vm
#   vm:/path/on/vm
#   docker:/root/path/in/container
#
# GitHub token:
#   ~/.tsp_github_token (mode 600)

set -uo pipefail

MODE="${1:-push}"
case "$MODE" in
    push|list) ;;
    *)
        echo "ERROR: mode must be 'push' or 'list'"
        echo "Your VM terminal remains open."
        exit 2
        ;;
esac

GH_USER="${TSP_GH_USER:-stefman69}"
GH_REPO="${TSP_GH_REPO:-openmwfortsp}"

CLEAN_BR="${TSP_TSPS_BASE_BRANCH:-source-backup}"
WORK_BR="${TSP_TSP_WORK_BRANCH:-tsp-in-progress}"

CONTAINER="${TSP_CONTAINER:-openmw_builder}"
OPENMW_SRC="${TSP_OPENMW_SRC:-/root/openmw-0.51-tsp-src}"
TSPS_GL4ES_SRC="${TSP_TSPS_GL4ES:-/root/gl4es-tsps}"
ACTIVE_GL4ES="${TSP_ACTIVE_GL4ES:-/root/gl4es-tsp-pvr-texture-v2}"

STAGE="$HOME/tsp-source-only-stage"
REPO_DIR="$HOME/tsp-source-backup-repo"
TOKEN_FILE="$HOME/.tsp_github_token"
EXTRA_LIST="$HOME/tsp_backup_source_extra.txt"

STAMP="$(date +%Y%m%d-%H%M%S)"
MAN_DIR="$STAGE/manifests"

hdr() {
    printf '\n============================================================\n'
    printf '%s\n' "$*"
    printf '============================================================\n'
}

say() {
    printf '  %s\n' "$*"
}

fail() {
    local rc="$1"
    shift
    echo
    echo "============================================================"
    echo "SOURCE BACKUP STOPPED"
    echo "============================================================"
    echo "ERROR: $*"
    echo "return_code=$rc"
    echo "Your VM terminal remains open."
    echo "No TSP/TSPS console connection was attempted."
    echo "Clean branch '$CLEAN_BR' was not intentionally modified."
    echo "============================================================"
    exit "$rc"
}

command -v git >/dev/null 2>&1 || fail 3 "git is not installed"
command -v tar >/dev/null 2>&1 || fail 3 "tar is not installed"
command -v sha256sum >/dev/null 2>&1 || fail 3 "sha256sum is not installed"
command -v docker >/dev/null 2>&1 || fail 3 "docker is not installed"

# ---------------------------------------------------------------------------
# LOCAL VM AUTH ONLY, AND ONLY IF DOCKER REQUIRES SUDO.
# There is deliberately no handheld/device password because this script never
# touches either console.
# ---------------------------------------------------------------------------
DOCKER=(docker)

if ! docker info >/dev/null 2>&1; then
    hdr "LOCAL VM PASSWORD PRECHECK"
    echo "Docker requires sudo on this VM."
    echo "If sudo needs a password, enter it ONCE now."
    sudo -v || fail 4 "sudo authentication failed"
    DOCKER=(sudo docker)
    "${DOCKER[@]}" info >/dev/null 2>&1 \
        || fail 4 "Docker is unavailable even with sudo"
fi

# ---------------------------------------------------------------------------
# Container state
# ---------------------------------------------------------------------------
hdr "CONTAINER STATE"

STATE="$("${DOCKER[@]}" inspect -f '{{.State.Status}}' "$CONTAINER" 2>/dev/null || true)"

case "$STATE" in
    running)
        say "$CONTAINER is running"
        ;;
    paused)
        say "$CONTAINER is paused -> unpausing"
        "${DOCKER[@]}" unpause "$CONTAINER" >/dev/null \
            || fail 5 "could not unpause $CONTAINER"
        ;;
    exited|created)
        say "$CONTAINER is $STATE -> starting"
        "${DOCKER[@]}" start "$CONTAINER" >/dev/null \
            || fail 5 "could not start $CONTAINER"
        ;;
    "")
        fail 5 "Docker container '$CONTAINER' does not exist"
        ;;
    *)
        fail 5 "unsupported container state '$STATE'"
        ;;
esac

"${DOCKER[@]}" exec "$CONTAINER" true >/dev/null 2>&1 \
    || fail 5 "$CONTAINER is not usable"

# ---------------------------------------------------------------------------
# Verify source trees. No new source fork is created.
# ---------------------------------------------------------------------------
hdr "SOURCE POLICY"

for src in "$OPENMW_SRC" "$TSPS_GL4ES_SRC" "$ACTIVE_GL4ES"; do
    "${DOCKER[@]}" exec "$CONTAINER" test -d "$src" \
        || fail 6 "source tree missing: $src"
done

[ "$ACTIVE_GL4ES" != "$TSPS_GL4ES_SRC" ] \
    || fail 6 "TSP and TSPS gl4es paths are the same; refusing"

say "clean GitHub TSPS branch : $CLEAN_BR"
say "working GitHub TSP branch: $WORK_BR"
say "OpenMW source            : $OPENMW_SRC"
say "TSPS gl4es source        : $TSPS_GL4ES_SRC"
say "TSP gl4es source         : $ACTIVE_GL4ES"
say "device/console capture   : DISABLED"
say "built binaries           : DISABLED"
say "new gl4es forks          : DISABLED"

# ---------------------------------------------------------------------------
# Start from a totally clean local staging directory.
# This intentionally does NOT call the old tsp_source_backup.sh because that
# script captured device/card state and build/export directories.
# ---------------------------------------------------------------------------
hdr "1. FRESH SOURCE-ONLY STAGE"

rm -rf "$STAGE"
mkdir -p \
    "$STAGE/working-source" \
    "$STAGE/reference-source" \
    "$STAGE/source-tools" \
    "$MAN_DIR/git"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
safe_name() {
    printf '%s' "$1" | sed 's#[^A-Za-z0-9._-]#_#g'
}

capture_git_metadata() {
    local src="$1"
    local label="$2"
    local base="$MAN_DIR/git/$(safe_name "$label")"

    {
        echo "label=$label"
        echo "container=$CONTAINER"
        echo "source=$src"
        echo "captured=$(date -Is 2>/dev/null || date)"
        echo
        echo "===== HEAD ====="
        "${DOCKER[@]}" exec "$CONTAINER" git -C "$src" rev-parse HEAD 2>/dev/null || true
        echo
        echo "===== BRANCH ====="
        "${DOCKER[@]}" exec "$CONTAINER" git -C "$src" branch --show-current 2>/dev/null || true
        echo
        echo "===== STATUS INCLUDING UNTRACKED ====="
        "${DOCKER[@]}" exec "$CONTAINER" git -C "$src" status --short --untracked-files=all 2>/dev/null || true
        echo
        echo "===== RECENT COMMITS ====="
        "${DOCKER[@]}" exec "$CONTAINER" git -C "$src" log --oneline -25 2>/dev/null || true
    } > "${base}-state.txt" 2>&1

    "${DOCKER[@]}" exec "$CONTAINER" git -C "$src" diff --binary 2>/dev/null \
        > "${base}-working.diff" || true

    "${DOCKER[@]}" exec "$CONTAINER" git -C "$src" diff --cached --binary 2>/dev/null \
        > "${base}-staged.diff" || true
}

capture_container_source_tree() {
    # capture_container_source_tree <src> <dst> <label>
    local src="$1"
    local dst="$2"
    local label="$3"

    rm -rf "$dst"
    mkdir -p "$dst"

    say "capturing source tree: $src"

    # IMPORTANT: docker exec -i is required because bash -s receives the heredoc
    # on stdin. The previous V2 omitted -i, so Docker produced an empty pipe and
    # host tar correctly reported "This does not look like a tar archive".
    "${DOCKER[@]}" exec -i "$CONTAINER" bash -s -- "$src" <<'DOCKER_SOURCE_TAR' \
        | tar -xf - -C "$dst"
set -uo pipefail
src="$1"

[ -d "$src" ] || {
    echo "ERROR: missing source tree: $src" >&2
    exit 41
}

cd "$src" || exit 42

# Keep source/config/scripts/assets needed to reconstruct the source state.
# Exclude VCS internals, build trees and compiled/archive output only.
tar -cf - \
    --exclude='./.git' \
    --exclude='./.cache' \
    --exclude='./build' \
    --exclude='./build-*' \
    --exclude='./cmake-build-*' \
    --exclude='*/CMakeFiles/*' \
    --exclude='*/CMakeCache.txt' \
    --exclude='*/cmake_install.cmake' \
    --exclude='*/Makefile' \
    --exclude='*.o' \
    --exclude='*.obj' \
    --exclude='*.a' \
    --exclude='*.so' \
    --exclude='*.so.*' \
    --exclude='*.dll' \
    --exclude='*.dylib' \
    --exclude='*.exe' \
    --exclude='*.tar' \
    --exclude='*.tar.gz' \
    --exclude='*.tgz' \
    --exclude='*.zip' \
    --exclude='*.7z' \
    .
DOCKER_SOURCE_TAR

    local -a tsp_pipe_rc=( "${PIPESTATUS[@]}" )
    local docker_rc="${tsp_pipe_rc[0]:-99}"
    local tar_rc="${tsp_pipe_rc[1]:-99}"

    if [ "$docker_rc" -ne 0 ] || [ "$tar_rc" -ne 0 ]; then
        fail 41 "source capture failed for $src (docker=$docker_rc tar=$tar_rc)"
    fi

    capture_git_metadata "$src" "$label"

    local count size
    count="$(find "$dst" -type f | wc -l)"
    size="$(du -sh "$dst" 2>/dev/null | cut -f1)"
    say "  -> $count files, $size"
}

# ---------------------------------------------------------------------------
# Core source trees
# ---------------------------------------------------------------------------
hdr "2. CORE SOURCE TREES"

capture_container_source_tree \
    "$OPENMW_SRC" \
    "$STAGE/working-source/openmw-0.51-tsp-src" \
    "openmw-tsp"

capture_container_source_tree \
    "$ACTIVE_GL4ES" \
    "$STAGE/working-source/gl4es-tsp" \
    "gl4es-tsp"

# Keep the current TSPS source tree as a reference INSIDE tsp-in-progress.
# The historical clean GitHub source-backup branch itself remains untouched.
capture_container_source_tree \
    "$TSPS_GL4ES_SRC" \
    "$STAGE/reference-source/gl4es-tsps-current" \
    "gl4es-tsps-current"

# ---------------------------------------------------------------------------
# OpenSceneGraph source discovery.
# Capture only actual source roots; no build directories.
# ---------------------------------------------------------------------------
hdr "3. OPENSCENEGRAPH SOURCE"

OSG_PATHS="$MAN_DIR/osg-source-paths.txt"
: > "$OSG_PATHS"

"${DOCKER[@]}" exec "$CONTAINER" bash -c '
for d in \
    /root/OpenSceneGraph \
    /root/openscenegraph \
    /root/osg \
    /root/OpenSceneGraph-* \
    /root/openscenegraph-* \
    /root/osg-*
do
    [ -d "$d" ] || continue
    case "$d" in
        *build*|*/lib|*/lib64) continue ;;
    esac
    if [ -f "$d/CMakeLists.txt" ] || [ -d "$d/src/osg" ] || [ -d "$d/include/osg" ]; then
        printf "%s\n" "$d"
    fi
done
' > "$OSG_PATHS" 2>/dev/null || true

sort -u "$OSG_PATHS" -o "$OSG_PATHS"

osg_n=0
while IFS= read -r osg_src; do
    [ -n "$osg_src" ] || continue
    osg_n=$((osg_n + 1))
    capture_container_source_tree \
        "$osg_src" \
        "$STAGE/working-source/osg-source-$osg_n" \
        "osg-source-$osg_n"
done < "$OSG_PATHS"

if [ "$osg_n" -eq 0 ]; then
    say "no standalone OSG source root positively identified"
    say "OpenMW tree is still fully captured"
else
    say "captured $osg_n OSG source tree(s)"
fi

# ---------------------------------------------------------------------------
# Source-level tooling only.
# No built/export directories and no Downloads tarballs/binaries.
# ---------------------------------------------------------------------------
hdr "4. SOURCE TOOLING"

TOOL_DST="$STAGE/source-tools/container-root"
mkdir -p "$TOOL_DST"

while IFS= read -r f; do
    [ -n "$f" ] || continue
    "${DOCKER[@]}" cp "$CONTAINER:$f" "$TOOL_DST/" >/dev/null 2>&1 || true
done < <(
    "${DOCKER[@]}" exec "$CONTAINER" sh -c \
        "find /root -maxdepth 1 -type f \( \
            -name '*.sh' -o \
            -name '*.py' -o \
            -name '*.patch' -o \
            -name '*.awk' -o \
            -name '*.c' -o \
            -name '*.h' -o \
            -name '*.cpp' -o \
            -name '*.hpp' -o \
            -name '*.cmake' -o \
            -name 'CMakeLists.txt' \
        \) -print 2>/dev/null" || true
)

say "container source/tool files: $(find "$TOOL_DST" -type f | wc -l)"

# VM-side patch/source scripts only.
VM_TOOL_DST="$STAGE/source-tools/vm-downloads"
mkdir -p "$VM_TOOL_DST"

for f in \
    "$HOME"/Downloads/*.sh \
    "$HOME"/Downloads/*.py \
    "$HOME"/Downloads/*.patch \
    "$HOME"/Downloads/*.awk \
    "$HOME"/Downloads/*.c \
    "$HOME"/Downloads/*.h \
    "$HOME"/Downloads/*.cpp \
    "$HOME"/Downloads/*.hpp
do
    [ -f "$f" ] && cp -p "$f" "$VM_TOOL_DST/"
done

say "VM source/tool files: $(find "$VM_TOOL_DST" -type f | wc -l)"

# ---------------------------------------------------------------------------
# Optional source extras
# ---------------------------------------------------------------------------
hdr "5. OPTIONAL SOURCE EXTRAS"

if [ ! -f "$EXTRA_LIST" ]; then
    cat > "$EXTRA_LIST" <<'EOF_EXTRA'
# Source-only extras, one per line.
# /path/on/vm
# vm:/path/on/vm
# docker:/root/path/in/container
EOF_EXTRA
    say "created $EXTRA_LIST"
fi

extra_n=0

while IFS= read -r entry; do
    case "$entry" in
        ''|'#'*) continue ;;
    esac

    extra_n=$((extra_n + 1))

    case "$entry" in
        docker:*)
            src="${entry#docker:}"
            if "${DOCKER[@]}" exec "$CONTAINER" test -d "$src"; then
                capture_container_source_tree \
                    "$src" \
                    "$STAGE/working-source/extra-$extra_n-$(basename "$src")" \
                    "extra-docker-$extra_n"
            elif "${DOCKER[@]}" exec "$CONTAINER" test -f "$src"; then
                mkdir -p "$STAGE/source-tools/extra-docker"
                "${DOCKER[@]}" cp "$CONTAINER:$src" \
                    "$STAGE/source-tools/extra-docker/" >/dev/null 2>&1 \
                    || say "WARNING: could not copy $src"
            else
                say "WARNING: missing Docker source extra: $src"
            fi
            ;;
        vm:*|/*)
            src="${entry#vm:}"
            if [ -d "$src" ]; then
                dst="$STAGE/working-source/extra-$extra_n-$(basename "$src")"
                mkdir -p "$dst"
                # Source-only copy from VM directory.
                (
                    cd "$src" || exit 1
                    tar -cf - \
                        --exclude='./.git' \
                        --exclude='./build' \
                        --exclude='./build-*' \
                        --exclude='./cmake-build-*' \
                        --exclude='*.o' \
                        --exclude='*.a' \
                        --exclude='*.so' \
                        --exclude='*.so.*' \
                        --exclude='*.exe' \
                        --exclude='*.tar' \
                        --exclude='*.tar.gz' \
                        --exclude='*.tgz' \
                        --exclude='*.zip' \
                        --exclude='*.7z' \
                        .
                ) | tar -xf - -C "$dst"
                tsp_vm_pipe_rc=( "${PIPESTATUS[@]}" )
                vm_tar_a="${tsp_vm_pipe_rc[0]:-99}"
                vm_tar_b="${tsp_vm_pipe_rc[1]:-99}"
                if [ "$vm_tar_a" -ne 0 ] || [ "$vm_tar_b" -ne 0 ]; then
                    fail 45 "VM source extra capture failed for $src"
                fi
            elif [ -f "$src" ]; then
                mkdir -p "$STAGE/source-tools/extra-vm"
                cp -p "$src" "$STAGE/source-tools/extra-vm/"
            else
                say "WARNING: missing VM source extra: $src"
            fi
            ;;
        *)
            say "WARNING: ignored unrecognized source extra: $entry"
            ;;
    esac
done < "$EXTRA_LIST"

say "optional extras processed: $extra_n"

# ---------------------------------------------------------------------------
# Hard audit: this staging tree should contain source, not compiled/archive
# output. Fail before GitHub if any obvious build artifact slipped through.
# ---------------------------------------------------------------------------
hdr "6. SOURCE-ONLY AUDIT"

BAD_LIST="$MAN_DIR/unexpected-built-files.txt"

find "$STAGE" -type f \
    \( -name '*.o' -o \
       -name '*.obj' -o \
       -name '*.a' -o \
       -name '*.so' -o \
       -name '*.so.*' -o \
       -name '*.dll' -o \
       -name '*.dylib' -o \
       -name '*.exe' -o \
       -name '*.tar' -o \
       -name '*.tar.gz' -o \
       -name '*.tgz' -o \
       -name '*.zip' -o \
       -name '*.7z' \) \
    -print > "$BAD_LIST" 2>/dev/null || true

if [ -s "$BAD_LIST" ]; then
    cat "$BAD_LIST"
    fail 50 "built/archive files slipped into the source-only stage"
fi

BIG_LIST="$MAN_DIR/files-over-95mb.txt"
find "$STAGE" -type f -size +95M -print > "$BIG_LIST" 2>/dev/null || true

if [ -s "$BIG_LIST" ]; then
    cat "$BIG_LIST"
    fail 51 "source stage contains files over 95 MB"
fi

cat > "$MAN_DIR/SNAPSHOT-POLICY.txt" <<EOF_POLICY
TSP SOURCE-ONLY WORKING SNAPSHOT
================================
captured=$STAMP

repository=$GH_USER/$GH_REPO

clean_tsps_branch=$CLEAN_BR
working_tsp_branch=$WORK_BR

openmw_source=$OPENMW_SRC
tsps_gl4es_source=$TSPS_GL4ES_SRC
tsp_gl4es_source=$ACTIVE_GL4ES

NO device/card/console access was performed.
NO built/export binaries were intentionally captured.
NO new local gl4es source fork was created.

Persistent local source policy:
  TSPS: $TSPS_GL4ES_SRC
  TSP : $ACTIVE_GL4ES

Persistent GitHub policy:
  $CLEAN_BR is historical clean TSPS reference and is never pushed by this script.
  $WORK_BR is the ongoing TSP development backup branch.
EOF_POLICY

FULL_MAN="$MAN_DIR/SHA256SUMS-SOURCE-ONLY.txt"
rm -f "$FULL_MAN"

(
    cd "$STAGE" || exit 1
    find . -type f \
        ! -path './manifests/SHA256SUMS-SOURCE-ONLY.txt' \
        -print0 \
        | sort -z \
        | xargs -0 -r sha256sum
) > "$FULL_MAN" || fail 52 "could not create source manifest"

say "source files: $(find "$STAGE" -type f | wc -l)"
say "stage size  : $(du -sh "$STAGE" | cut -f1)"
say "built files : 0"

if [ "$MODE" = "list" ]; then
    hdr "LIST MODE - NOTHING PUSHED"

    find "$STAGE" -maxdepth 3 -type d | sed 's/^/  /'
    echo
    cat "$MAN_DIR/SNAPSHOT-POLICY.txt"
    echo
    echo "No GitHub branch or file was modified."
    exit 0
fi

# ---------------------------------------------------------------------------
# GitHub auth and branch management.
# ---------------------------------------------------------------------------
hdr "7. GITHUB AUTH"

[ -s "$TOKEN_FILE" ] \
    || fail 60 "missing GitHub token file: $TOKEN_FILE"

chmod 600 "$TOKEN_FILE" 2>/dev/null || true

TOKEN="$(head -n1 "$TOKEN_FILE" | tr -d '[:space:]')"
[ -n "$TOKEN" ] || fail 60 "$TOKEN_FILE is empty"

AUTH_URL="https://$GH_USER:$TOKEN@github.com/$GH_USER/$GH_REPO.git"
SAFE_URL="https://github.com/$GH_USER/$GH_REPO.git"

if [ ! -d "$REPO_DIR/.git" ]; then
    rm -rf "$REPO_DIR"
    git clone -q "$AUTH_URL" "$REPO_DIR" \
        || fail 61 "GitHub clone failed"
else
    git -C "$REPO_DIR" remote set-url origin "$AUTH_URL"
fi

clear_token() {
    git -C "$REPO_DIR" remote set-url origin "$SAFE_URL" >/dev/null 2>&1 || true
}
trap clear_token EXIT

git -C "$REPO_DIR" fetch -q --prune origin \
    || fail 62 "GitHub fetch failed"

git -C "$REPO_DIR" show-ref --verify --quiet "refs/remotes/origin/$CLEAN_BR" \
    || fail 63 "clean branch origin/$CLEAN_BR does not exist"

CLEAN_BEFORE="$(git -C "$REPO_DIR" rev-parse "origin/$CLEAN_BR")"

hdr "8. TSP WORKING BRANCH"

if git -C "$REPO_DIR" show-ref --verify --quiet "refs/remotes/origin/$WORK_BR"; then
    say "origin/$WORK_BR already exists; reusing it"
    git -C "$REPO_DIR" reset --hard >/dev/null 2>&1 || true
    git -C "$REPO_DIR" clean -fd >/dev/null 2>&1 || true
    git -C "$REPO_DIR" checkout -q -B "$WORK_BR" "origin/$WORK_BR" \
        || fail 64 "could not check out $WORK_BR"
else
    say "origin/$WORK_BR does not exist"
    say "creating it ONCE from origin/$CLEAN_BR"

    git -C "$REPO_DIR" reset --hard >/dev/null 2>&1 || true
    git -C "$REPO_DIR" clean -fd >/dev/null 2>&1 || true
    git -C "$REPO_DIR" checkout -q -B "$WORK_BR" "origin/$CLEAN_BR" \
        || fail 64 "could not create local $WORK_BR"

    git -C "$REPO_DIR" push -q -u origin "$WORK_BR" \
        || fail 65 "could not create GitHub branch $WORK_BR"

    say "created GitHub branch $WORK_BR"
fi

# Put the new source snapshot under one stable directory. This leaves all of
# the historical content inherited from source-backup available underneath it.
SNAP_DST="$REPO_DIR/tsp-in-progress-source"

rm -rf "$SNAP_DST"
mkdir -p "$SNAP_DST"
cp -a "$STAGE/." "$SNAP_DST/"

cd "$REPO_DIR" || fail 66 "cannot enter $REPO_DIR"

git add -A -- tsp-in-progress-source

hdr "9. WHAT WILL BE COMMITTED"

git diff --cached --stat | tail -50 || true

CHANGED="$(git diff --cached --numstat | grep -c . || true)"
say "$CHANGED changed files"

if [ "$CHANGED" -eq 0 ]; then
    say "nothing changed since the previous TSP source snapshot"
else
    git -c user.email="simantonstefan@gmail.com" \
        -c user.name="Steve" \
        commit -q \
        -m "TSP in-progress source-only snapshot $STAMP" \
        || fail 67 "git commit failed"

    git push -q origin "$WORK_BR" \
        || fail 68 "push to $WORK_BR failed"

    say "pushed branch: $WORK_BR"
    say "commit: $(git rev-parse HEAD)"
fi

# Prove the historical clean branch did not move.
git fetch -q origin "$CLEAN_BR" \
    || fail 69 "could not refresh clean branch for verification"

CLEAN_AFTER="$(git rev-parse "origin/$CLEAN_BR")"

if [ "$CLEAN_BEFORE" != "$CLEAN_AFTER" ]; then
    fail 70 "clean branch $CLEAN_BR moved during this run (before=$CLEAN_BEFORE after=$CLEAN_AFTER)"
fi

clear_token
trap - EXIT

hdr "SOURCE BACKUP COMPLETE"

echo "Clean TSPS branch unchanged:"
echo "  https://github.com/$GH_USER/$GH_REPO/tree/$CLEAN_BR"
echo "  $CLEAN_AFTER"
echo
echo "TSP work-in-progress branch:"
echo "  https://github.com/$GH_USER/$GH_REPO/tree/$WORK_BR"
echo
echo "Source snapshot directory:"
echo "  tsp-in-progress-source/"
echo
echo "NO handheld console/device connection was used."
echo "NO built libGL/OpenMW binaries were intentionally uploaded."
echo "NO new gl4es source fork was created."
