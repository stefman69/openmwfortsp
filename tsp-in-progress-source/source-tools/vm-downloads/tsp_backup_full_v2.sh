#!/usr/bin/env bash
# tsp_backup_full_v2.sh
#
# Full TSP/TSPS source snapshotter for stefman69/openmwfortsp.
#
# Branch policy:
#   source-backup   = CLEAN TSPS reference branch. NEVER written by this script.
#   tsp-in-progress = original-TSP / PowerVR working backup branch.
#
# On the first push, tsp-in-progress is created from origin/source-backup.
# After that, only tsp-in-progress is updated.
#
# Unlike the old marker-based backup, this also snapshots COMPLETE source trees
# while excluding build products/binaries:
#   /root/openmw-0.51-tsp-src
#   /root/gl4es-tsps
#   one active TSP gl4es tree (currently prefers /root/gl4es-tsp-pvr-texture-v2)
#
# Usage:
#   bash ~/Downloads/tsp_backup_full_v2.sh
#   bash ~/Downloads/tsp_backup_full_v2.sh list
#
# Optional:
#   TSP_ACTIVE_GL4ES=/root/path bash ~/Downloads/tsp_backup_full_v2.sh
#
# GitHub token:
#   ~/.tsp_github_token, mode 600

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

STAGE="$HOME/tsp-source-backup"
REPO_DIR="$HOME/tsp-source-backup-repo"
TOKEN_FILE="$HOME/.tsp_github_token"
EXTRA_LIST="$HOME/tsp_backup_extra.txt"
CONTAINER="${TSP_CONTAINER:-openmw_builder}"

OPENMW_SRC="${TSP_OPENMW_SRC:-/root/openmw-0.51-tsp-src}"
TSPS_GL4ES_SRC="${TSP_TSPS_GL4ES:-/root/gl4es-tsps}"
ACTIVE_GL4ES="${TSP_ACTIVE_GL4ES:-}"

STAMP="$(date +%Y%m%d-%H%M%S)"
MAN_DIR="$STAGE/manifests"
EXTRA="$STAGE/extra"
FULL="$STAGE/full-source"

hdr(){ printf '\n============================================================\n%s\n============================================================\n' "$*"; }
say(){ printf '  %s\n' "$*"; }
fail(){
    local rc="$1"; shift
    echo
    echo "============================================================"
    echo "BACKUP STOPPED"
    echo "============================================================"
    echo "ERROR: $*"
    echo "return_code=$rc"
    echo "Your VM terminal remains open."
    echo "Clean branch '$CLEAN_BR' was not intentionally modified."
    echo "============================================================"
    exit "$rc"
}

for cmd in git tar sha256sum docker; do
    command -v "$cmd" >/dev/null 2>&1 || fail 3 "$cmd is not installed"
done

# Docker access: if sudo is needed, authenticate once here.
DOCKER=(docker)
if ! docker info >/dev/null 2>&1; then
    hdr "DOCKER ACCESS"
    echo "Docker needs sudo on this VM. If prompted, enter the password once now."
    sudo -v || fail 4 "sudo authentication failed"
    DOCKER=(sudo docker)
    "${DOCKER[@]}" info >/dev/null 2>&1 || fail 4 "Docker unavailable even with sudo"
fi

# Start/unpause the existing container; this preserves its filesystem.
hdr "CONTAINER STATE"
CONTAINER_STATE="$("${DOCKER[@]}" inspect -f '{{.State.Status}}' "$CONTAINER" 2>/dev/null || true)"
case "$CONTAINER_STATE" in
    running) say "$CONTAINER is running" ;;
    paused)
        say "$CONTAINER paused -> unpausing"
        "${DOCKER[@]}" unpause "$CONTAINER" >/dev/null || fail 5 "could not unpause $CONTAINER"
        ;;
    exited|created)
        say "$CONTAINER $CONTAINER_STATE -> starting"
        "${DOCKER[@]}" start "$CONTAINER" >/dev/null || fail 5 "could not start $CONTAINER"
        ;;
    "") fail 5 "Docker container '$CONTAINER' does not exist" ;;
    *) fail 5 "unsupported container state '$CONTAINER_STATE'" ;;
esac
"${DOCKER[@]}" exec "$CONTAINER" true >/dev/null 2>&1 || fail 5 "$CONTAINER is not usable"

# Choose ONE active TSP gl4es tree. No new local source fork is created here.
if [ -z "$ACTIVE_GL4ES" ]; then
    for cand in \
        /root/gl4es-tsp-pvr-texture-v2 \
        /root/gl4es-tsp-pvr-lifetime-v1 \
        /root/gl4es-tsp
    do
        if "${DOCKER[@]}" exec "$CONTAINER" test -d "$cand"; then
            ACTIVE_GL4ES="$cand"
            break
        fi
    done
fi

[ -n "$ACTIVE_GL4ES" ] || fail 6 "no original-TSP gl4es source found; set TSP_ACTIVE_GL4ES=/root/path"
"${DOCKER[@]}" exec "$CONTAINER" test -d "$OPENMW_SRC" || fail 6 "missing OpenMW source $OPENMW_SRC"
"${DOCKER[@]}" exec "$CONTAINER" test -d "$TSPS_GL4ES_SRC" || fail 6 "missing TSPS source $TSPS_GL4ES_SRC"
"${DOCKER[@]}" exec "$CONTAINER" test -d "$ACTIVE_GL4ES" || fail 6 "missing TSP source $ACTIVE_GL4ES"
[ "$ACTIVE_GL4ES" != "$TSPS_GL4ES_SRC" ] || fail 6 "TSP and TSPS paths are the same"

hdr "SOURCE POLICY"
say "clean GitHub TSPS branch : $CLEAN_BR"
say "working GitHub TSP branch: $WORK_BR"
say "OpenMW source            : $OPENMW_SRC"
say "TSPS gl4es source        : $TSPS_GL4ES_SRC"
say "TSP gl4es source         : $ACTIVE_GL4ES"
say "No new local gl4es tree will be created."

# Fresh base stage every backup by default.
hdr "1. FRESH BASE STAGE"
mkdir -p "$STAGE" "$MAN_DIR"
if [ -f "$HOME/tsp_source_backup.sh" ]; then
    TSP_FORCE_STAGE=1 bash "$HOME/tsp_source_backup.sh" || fail 10 "~/tsp_source_backup.sh failed"
else
    say "WARNING: ~/tsp_source_backup.sh missing; continuing with full source capture"
fi
mkdir -p "$MAN_DIR" "$EXTRA" "$FULL"

sanitize_name(){ printf '%s' "$1" | sed 's#[^A-Za-z0-9._-]#_#g'; }

copy_container_tree(){
    local src="$1" dst="$2" label="$3"
    local meta="$MAN_DIR/git/$(sanitize_name "$label")"
    mkdir -p "$MAN_DIR/git"
    rm -rf "$dst"; mkdir -p "$dst"

    say "capturing complete source: $src"
    "${DOCKER[@]}" exec "$CONTAINER" bash -s -- "$src" <<'DOCKER_TAR' | tar -xf - -C "$dst"
set -euo pipefail
src="$1"
[ -d "$src" ] || { echo "ERROR: missing source tree $src" >&2; exit 41; }
cd "$src"
tar -cf - \
    --exclude='./.git' \
    --exclude='./.cache' \
    --exclude='./build' \
    --exclude='./build-*' \
    --exclude='./cmake-build-*' \
    --exclude='*/CMakeFiles/*' \
    --exclude='*/CMakeCache.txt' \
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
DOCKER_TAR
    local p0="${PIPESTATUS[0]}" p1="${PIPESTATUS[1]}"
    [ "$p0" -eq 0 ] && [ "$p1" -eq 0 ] || fail 41 "source capture failed for $src (docker=$p0 tar=$p1)"

    {
        echo "label=$label"
        echo "source=$src"
        echo "captured=$(date -Is 2>/dev/null || date)"
        echo
        echo "===== HEAD ====="
        "${DOCKER[@]}" exec "$CONTAINER" git -C "$src" rev-parse HEAD 2>/dev/null || true
        echo
        echo "===== BRANCH ====="
        "${DOCKER[@]}" exec "$CONTAINER" git -C "$src" branch --show-current 2>/dev/null || true
        echo
        echo "===== STATUS ====="
        "${DOCKER[@]}" exec "$CONTAINER" git -C "$src" status --short --untracked-files=all 2>/dev/null || true
        echo
        echo "===== RECENT COMMITS ====="
        "${DOCKER[@]}" exec "$CONTAINER" git -C "$src" log --oneline -20 2>/dev/null || true
    } > "${meta}-state.txt" 2>&1

    "${DOCKER[@]}" exec "$CONTAINER" git -C "$src" diff --binary 2>/dev/null > "${meta}-working.diff" || true
    "${DOCKER[@]}" exec "$CONTAINER" git -C "$src" diff --cached --binary 2>/dev/null > "${meta}-staged.diff" || true

    say "  -> $dst : $(find "$dst" -type f | wc -l) files, $(du -sh "$dst" 2>/dev/null | cut -f1)"
}

hdr "2. COMPLETE SOURCE TREES"
rm -rf "$FULL"; mkdir -p "$FULL"

copy_container_tree "$OPENMW_SRC" "$FULL/openmw-0.51-tsp-src" "openmw-tsp"
copy_container_tree "$TSPS_GL4ES_SRC" "$FULL/gl4es-tsps" "gl4es-tsps"
copy_container_tree "$ACTIVE_GL4ES" "$FULL/gl4es-tsp" "gl4es-tsp-active"

# Capture full OSG source if a source root can be positively identified.
hdr "3. OPENSCENEGRAPH SOURCE DISCOVERY"
OSG_LIST="$MAN_DIR/osg-source-paths.txt"
: > "$OSG_LIST"
"${DOCKER[@]}" exec "$CONTAINER" bash -s <<'DOCKER_OSG' > "$OSG_LIST" 2>/dev/null || true
for d in /root/OpenSceneGraph /root/openscenegraph /root/osg /root/OpenSceneGraph-* /root/openscenegraph-* /root/osg-*; do
    [ -d "$d" ] || continue
    case "$d" in *build*|*/lib|*/lib64) continue ;; esac
    if [ -f "$d/CMakeLists.txt" ] || [ -d "$d/src/osg" ] || [ -d "$d/include/osg" ]; then
        printf '%s\n' "$d"
    fi
done
DOCKER_OSG
sort -u "$OSG_LIST" -o "$OSG_LIST"

osg_n=0
while IFS= read -r osg_src; do
    [ -n "$osg_src" ] || continue
    osg_n=$((osg_n+1))
    copy_container_tree "$osg_src" "$FULL/osg-source-$osg_n" "osg-source-$osg_n"
done < "$OSG_LIST"
[ "$osg_n" -gt 0 ] && say "captured $osg_n OSG source tree(s)" || say "no full OSG root found; old stager capture remains"

# Root-level build/patch tooling in the container.
hdr "4. CONTAINER TOOLING"
TOOL_DST="$FULL/container-root-tooling"
rm -rf "$TOOL_DST"; mkdir -p "$TOOL_DST"
while IFS= read -r f; do
    [ -n "$f" ] || continue
    "${DOCKER[@]}" cp "$CONTAINER:$f" "$TOOL_DST/" >/dev/null 2>&1 || true
done < <(
    "${DOCKER[@]}" exec "$CONTAINER" sh -c \
      "find /root -maxdepth 1 -type f \( -name '*.sh' -o -name '*.py' -o -name '*.patch' -o -name '*.awk' -o -name '*.txt' \) -print 2>/dev/null" \
      || true
)
say "container tooling: $(find "$TOOL_DST" -type f | wc -l) files"

# VM-side patches/tools and optional explicit extras.
hdr "5. VM EXTRAS"
rm -rf "$EXTRA"; mkdir -p "$EXTRA/tools" "$EXTRA/launchers" "$EXTRA/manager"

for f in "$HOME"/Downloads/*.sh "$HOME"/Downloads/*.patch "$HOME"/Downloads/*.awk "$HOME"/Downloads/*.py; do
    [ -f "$f" ] && cp -p "$f" "$EXTRA/tools/"
done
say "Downloads tools: $(find "$EXTRA/tools" -maxdepth 1 -type f | wc -l) files"

if [ -d "$HOME/Downloads/tsp_ship" ]; then
    cp -a "$HOME/Downloads/tsp_ship/." "$EXTRA/launchers/"
    say "captured ~/Downloads/tsp_ship"
fi

if [ ! -f "$EXTRA_LIST" ]; then
    cat > "$EXTRA_LIST" <<'EOF_EXTRA'
# Additional backup roots, one per line.
# /path/on/vm
# vm:/path/on/vm
# docker:/root/path/in/container
EOF_EXTRA
    say "created $EXTRA_LIST"
fi

extra_i=0
while IFS= read -r entry; do
    case "$entry" in ''|'#'*) continue ;; esac
    extra_i=$((extra_i+1))
    case "$entry" in
        docker:*)
            src="${entry#docker:}"
            dst="$EXTRA/manager/docker-$extra_i-$(basename "$src")"
            if "${DOCKER[@]}" exec "$CONTAINER" test -d "$src"; then
                copy_container_tree "$src" "$dst" "extra-docker-$extra_i"
            elif "${DOCKER[@]}" exec "$CONTAINER" test -f "$src"; then
                mkdir -p "$dst"
                "${DOCKER[@]}" cp "$CONTAINER:$src" "$dst/" >/dev/null 2>&1 || true
            else
                say "WARNING: missing docker extra $src"
            fi
            ;;
        vm:*|/*)
            src="${entry#vm:}"
            if [ -d "$src" ]; then
                dst="$EXTRA/manager/vm-$extra_i-$(basename "$src")"
                mkdir -p "$dst"; cp -a "$src/." "$dst/"
            elif [ -f "$src" ]; then
                mkdir -p "$EXTRA/manager/vm-files"; cp -p "$src" "$EXTRA/manager/vm-files/"
            else
                say "WARNING: missing VM extra $src"
            fi
            ;;
        *) say "WARNING: unrecognized extra entry: $entry" ;;
    esac
done < "$EXTRA_LIST"

# Auto-discover manager/navmesh source roots on VM.
while IFS= read -r d; do
    [ -n "$d" ] || continue
    name="$(basename "$d")"
    dst="$EXTRA/manager/auto-$name"
    [ -e "$dst" ] && continue
    mkdir -p "$dst"
    cp -a "$d/." "$dst/" 2>/dev/null || true
done < <(
    find "$HOME" -maxdepth 3 -type d \
      \( -iname '*manager*' -o -iname '*navmesh-progress*' -o -iname '*navmeshtool*' \) \
      -not -path '*/.*' \
      -not -path "$STAGE*" \
      -not -path "$REPO_DIR*" \
      2>/dev/null || true
)

find "$EXTRA" -type f \
  \( -name '*.o' -o -name '*.a' -o -name '*.so' -o -name '*.so.*' \
     -o -name '*.tar' -o -name '*.tar.gz' -o -name '*.tgz' \
     -o -name '*.zip' -o -name '*.7z' \) \
  -delete 2>/dev/null || true

hdr "6. SNAPSHOT MANIFESTS"

cat > "$MAN_DIR/TSP-WORKING-SNAPSHOT.txt" <<EOF_POLICY
TSP WORKING SNAPSHOT
====================
captured=$STAMP

repository=$GH_USER/$GH_REPO

clean_tsps_branch=$CLEAN_BR
working_tsp_branch=$WORK_BR

container=$CONTAINER
openmw_source=$OPENMW_SRC
tsps_gl4es_source=$TSPS_GL4ES_SRC
active_tsp_gl4es_source=$ACTIVE_GL4ES

stable GitHub snapshot paths:
  full-source/openmw-0.51-tsp-src/
  full-source/gl4es-tsps/
  full-source/gl4es-tsp/

Policy:
  source-backup remains the clean TSPS reference.
  tsp-in-progress is the original-TSP/PowerVR work branch.
  Future TSP patches should continue editing/backing up ONE live TSP gl4es tree
  instead of creating another local source fork for each patch.
EOF_POLICY

BIG="$(find "$STAGE" -type f -size +95M -print 2>/dev/null || true)"
if [ -n "$BIG" ]; then
    printf '%s\n' "$BIG" > "$MAN_DIR/FILES-OVER-95MB.txt"
    fail 50 "files over 95 MB found; see $MAN_DIR/FILES-OVER-95MB.txt"
fi

FULL_MAN="$MAN_DIR/SHA256SUMS-FULL-SNAPSHOT.txt"
rm -f "$FULL_MAN"
(
    cd "$STAGE" || exit 1
    find . -type f ! -path './manifests/SHA256SUMS-FULL-SNAPSHOT.txt' -print0 \
      | sort -z | xargs -0 -r sha256sum
) > "$FULL_MAN" || fail 51 "could not create full SHA256 manifest"

say "snapshot files: $(find "$STAGE" -type f | wc -l)"
say "snapshot size : $(du -sh "$STAGE" | cut -f1)"
say "full manifest : $(grep -c . "$FULL_MAN" 2>/dev/null || true) entries"

if [ "$MODE" = list ]; then
    hdr "LIST MODE - NOTHING PUSHED"
    find "$FULL" -maxdepth 2 -type d | sed 's/^/  /'
    echo
    cat "$MAN_DIR/TSP-WORKING-SNAPSHOT.txt"
    echo
    echo "No GitHub branch or file was changed."
    exit 0
fi

hdr "7. GITHUB AUTH"
[ -s "$TOKEN_FILE" ] || fail 60 "missing $TOKEN_FILE"
chmod 600 "$TOKEN_FILE" 2>/dev/null || true
GITHUB_TOKEN="$(head -n1 "$TOKEN_FILE" | tr -d '[:space:]')"
[ -n "$GITHUB_TOKEN" ] || fail 60 "$TOKEN_FILE is empty"

AUTH_URL="https://$GH_USER:$GITHUB_TOKEN@github.com/$GH_USER/$GH_REPO.git"
SAFE_URL="https://github.com/$GH_USER/$GH_REPO.git"

if [ ! -d "$REPO_DIR/.git" ]; then
    rm -rf "$REPO_DIR"
    git clone -q "$AUTH_URL" "$REPO_DIR" || fail 61 "GitHub clone failed"
else
    git -C "$REPO_DIR" remote set-url origin "$AUTH_URL"
fi

clear_remote_token(){
    git -C "$REPO_DIR" remote set-url origin "$SAFE_URL" >/dev/null 2>&1 || true
}
trap clear_remote_token EXIT

git -C "$REPO_DIR" fetch -q --prune origin || fail 62 "GitHub fetch failed"

# Hard safety rule: clean TSPS branch must exist and is NEVER pushed by this script.
git -C "$REPO_DIR" show-ref --verify --quiet "refs/remotes/origin/$CLEAN_BR" \
  || fail 63 "clean TSPS branch origin/$CLEAN_BR does not exist"
CLEAN_SHA="$(git -C "$REPO_DIR" rev-parse "origin/$CLEAN_BR")"

hdr "8. WORKING BRANCH"
if git -C "$REPO_DIR" show-ref --verify --quiet "refs/remotes/origin/$WORK_BR"; then
    say "origin/$WORK_BR already exists"
    git -C "$REPO_DIR" reset --hard >/dev/null 2>&1 || true
    git -C "$REPO_DIR" clean -fd >/dev/null 2>&1 || true
    git -C "$REPO_DIR" checkout -q -B "$WORK_BR" "origin/$WORK_BR" \
      || fail 64 "could not check out $WORK_BR"
else
    say "origin/$WORK_BR does not exist"
    say "creating it once from clean origin/$CLEAN_BR"
    git -C "$REPO_DIR" reset --hard >/dev/null 2>&1 || true
    git -C "$REPO_DIR" clean -fd >/dev/null 2>&1 || true
    git -C "$REPO_DIR" checkout -q -B "$WORK_BR" "origin/$CLEAN_BR" \
      || fail 64 "could not create local $WORK_BR"
    git -C "$REPO_DIR" push -q -u origin "$WORK_BR" \
      || fail 65 "could not create GitHub branch $WORK_BR"
    say "created GitHub branch $WORK_BR from $CLEAN_BR"
fi

WORK_BEFORE_SHA="$(git -C "$REPO_DIR" rev-parse HEAD)"
cat >> "$MAN_DIR/TSP-WORKING-SNAPSHOT.txt" <<EOF_GIT

clean_branch_sha=$CLEAN_SHA
working_branch_before_sha=$WORK_BEFORE_SHA
EOF_GIT

# Refresh manifest after branch metadata was added.
rm -f "$FULL_MAN"
(
    cd "$STAGE" || exit 1
    find . -type f ! -path './manifests/SHA256SUMS-FULL-SNAPSHOT.txt' -print0 \
      | sort -z | xargs -0 -r sha256sum
) > "$FULL_MAN" || fail 66 "could not refresh SHA256 manifest"

# Keep historical directory name for compatibility, but only update it on WORK_BR.
rm -rf "$REPO_DIR/source-backup"
mkdir -p "$REPO_DIR/source-backup"
cp -a "$STAGE/." "$REPO_DIR/source-backup/"
cp -f "$STAGE/README.md" "$REPO_DIR/README-tsp-port.md" 2>/dev/null || true

cd "$REPO_DIR" || fail 67 "cannot enter $REPO_DIR"
git add -A

hdr "9. CHANGES TO $WORK_BR"
git diff --cached --stat | tail -40 || true
CHANGED="$(git diff --cached --numstat | grep -c . || true)"
say "$CHANGED changed files"

if [ "$CHANGED" -eq 0 ]; then
    say "nothing changed since previous TSP working snapshot"
else
    git -c user.email="simantonstefan@gmail.com" \
        -c user.name="Steve" \
        commit -q -m "TSP in-progress full source snapshot $STAMP" \
        || fail 68 "git commit failed"
    git push -q origin "$WORK_BR" || fail 69 "push to $WORK_BR failed"
    say "pushed commit $(git rev-parse HEAD)"
fi

clear_remote_token
trap - EXIT

hdr "BACKUP COMPLETE"
echo "Clean TSPS branch left untouched:"
echo "  https://github.com/$GH_USER/$GH_REPO/tree/$CLEAN_BR"
echo
echo "TSP work-in-progress branch:"
echo "  https://github.com/$GH_USER/$GH_REPO/tree/$WORK_BR"
echo
echo "Active TSP source backed up:"
echo "  $ACTIVE_GL4ES"
echo
echo "Going forward, keep editing/backing up that same TSP tree."
echo
git log --oneline -3
