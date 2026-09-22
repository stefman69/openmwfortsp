#!/usr/bin/env bash
# Read-only VM/container source-lineage dump.
# Captures BOTH /root/gl4es-tsp and /root/gl4es-tsps before any new fork is made.
# Does not patch, build, install, SSH, or touch the handheld.

if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
    echo "ERROR: run this script; do not source it."
    return 1
fi

set -u
set -o pipefail

CONTAINER="${TSP_CONTAINER:-openmw_builder}"
DL="$HOME/Downloads"
STAMP="$(date +%Y%m%d-%H%M%S)"
WORK="$DL/.tsp_gl4es_source_lineage_$STAMP"
OUT="$DL/tsp_gl4es_source_lineage_$STAMP.tar"

cleanup_on_signal() {
    echo
    echo "SOURCE LINEAGE DUMP INTERRUPTED."
    echo "Your terminal remains open."
}
trap cleanup_on_signal INT TERM HUP

echo "============================================================"
echo "TSP GL4ES SOURCE LINEAGE DUMP V1"
echo "============================================================"
echo "This is READ-ONLY."
echo "No SSH. No password. No build. No source edits."
echo "Output: $OUT"
echo

if ! command -v docker >/dev/null 2>&1; then
    echo "ERROR: docker is not available."
else
    if ! docker inspect "$CONTAINER" >/dev/null 2>&1; then
        echo "ERROR: Docker container not found: $CONTAINER"
    else
        rm -rf "$WORK" 2>/dev/null || true
        mkdir -p "$WORK/tsp" "$WORK/tsps" "$WORK/compare"

        dump_tree() {
            TREE="$1"
            TAG="$2"
            DEST="$WORK/$TAG"

            echo "---- $TAG: $TREE ----"

            if ! docker exec "$CONTAINER" test -d "$TREE"; then
                echo "MISSING: $TREE" | tee "$DEST/MISSING.txt"
                return 0
            fi

            echo "[1] identity/git"
            docker exec "$CONTAINER" bash -s -- "$TREE" > "$DEST/git-state.txt" 2>&1 <<'DOCKER'
TREE="$1"
cd "$TREE" || exit 0
echo "path=$TREE"
echo "realpath=$(readlink -f "$TREE" 2>/dev/null)"
echo
echo "===== ls root ====="
ls -la
echo
echo "===== git HEAD ====="
git rev-parse HEAD 2>&1 || true
echo
echo "===== git status ====="
git status --short --branch 2>&1 || true
echo
echo "===== git remotes ====="
git remote -v 2>&1 || true
echo
echo "===== git describe ====="
git describe --always --dirty --tags 2>&1 || true
echo
echo "===== git log 120 ====="
git log -120 --decorate --date=iso --pretty=fuller 2>&1 || true
DOCKER

            docker exec "$CONTAINER" bash -c '
                cd "$1" || exit 0
                git diff --no-ext-diff --full-index --binary 2>&1 || true
            ' _ "$TREE" > "$DEST/working-tree.diff" 2>&1 || true

            docker exec "$CONTAINER" bash -c '
                cd "$1" || exit 0
                git diff --cached --no-ext-diff --full-index --binary 2>&1 || true
            ' _ "$TREE" > "$DEST/index.diff" 2>&1 || true

            echo "[2] source manifest"
            docker exec "$CONTAINER" bash -c '
                cd "$1" || exit 0
                find . -type f \
                  -not -path "./.git/*" \
                  -not -path "./build*/*" \
                  -not -path "./lib/*" \
                  -print0 2>/dev/null \
                | sort -z \
                | xargs -0 sha256sum 2>/dev/null
            ' _ "$TREE" > "$DEST/source-sha256.txt" 2>&1 || true

            docker exec "$CONTAINER" bash -c '
                cd "$1" || exit 0
                grep -RInE "TSP_TEXLIFE|LIBGL_TSP_TEXLIFE|TSP_FBO|TSP_DRAWFBO|TSP_ATTACH|TSP_MAXCOLOR|TSP_VBO_ORPHAN|TSP_PRGCACHE|TSP_SHCACHE" \
                  --include="*.c" --include="*.h" . 2>/dev/null || true
            ' _ "$TREE" > "$DEST/key-markers.txt" 2>&1 || true

            echo "[3] exact relevant source files"
            for rel in \
                src/gl/framebuffers.c \
                src/gl/framebuffers.h \
                src/gl/texture.c \
                src/gl/texture.h \
                src/gl/texture_params.c \
                src/gl/texture_params.h \
                src/gl/glstate.c \
                src/gl/glstate.h \
                src/gl/buffers.c \
                src/gl/buffers.h \
                src/gl/loader.c \
                src/gl/loader.h \
                src/glx/hardext.c \
                src/glx/hardext.h
            do
                safe="$(printf '%s' "$rel" | tr '/' '_')"
                docker exec "$CONTAINER" bash -c '
                    [ -f "$1/$2" ] && cat "$1/$2"
                ' _ "$TREE" "$rel" > "$DEST/$safe" 2>/dev/null || true
                [ -s "$DEST/$safe" ] || rm -f "$DEST/$safe"
            done

            echo "[4] source tree tar"
            docker exec "$CONTAINER" bash -c '
                TREE="$1"
                BASE="$(dirname "$TREE")"
                NAME="$(basename "$TREE")"
                tar -cf - \
                  --exclude="$NAME/.git" \
                  --exclude="$NAME/build" \
                  --exclude="$NAME/build-*" \
                  --exclude="$NAME/lib" \
                  --exclude="*.o" \
                  --exclude="*.a" \
                  --exclude="*.so" \
                  --exclude="*.so.*" \
                  -C "$BASE" "$NAME"
            ' _ "$TREE" > "$DEST/source-tree.tar" 2>"$DEST/source-tree-tar.stderr" || true

            echo "[5] current binary identity"
            docker exec "$CONTAINER" bash -s -- "$TREE" > "$DEST/binary-identity.txt" 2>&1 <<'DOCKER'
TREE="$1"
for f in \
  "$TREE/lib/libGL.so.1" \
  "$TREE/build-tsps-o3/lib/libGL.so.1" \
  "$TREE/build-tsps-o3/libGL.so.1"
do
  [ -e "$f" ] || continue
  echo "--- $f ---"
  ls -lh "$f" 2>/dev/null || true
  readlink -f "$f" 2>/dev/null || true
  sha256sum "$f" 2>/dev/null || true
  strings -a "$f" 2>/dev/null \
    | grep -E 'TSP_TEXLIFE|LIBGL_TSP_TEXLIFE|TSP_FBO|TSP_ATTACH|TSP_DRAWFBO|TSP_MAXCOLOR' \
    | sort -u || true
done
DOCKER

            echo
        }

        echo "[1/4] Dumping /root/gl4es-tsp"
        dump_tree /root/gl4es-tsp tsp

        echo "[2/4] Dumping /root/gl4es-tsps"
        dump_tree /root/gl4es-tsps tsps

        echo "[3/4] Comparing the two trees"

        {
            echo "===== relevant source SHA comparison ====="
            for f in \
                src/gl/framebuffers.c \
                src/gl/texture.c \
                src/gl/texture_params.c \
                src/gl/glstate.c \
                src/gl/texture.h \
                src/gl/buffers.c \
                src/glx/hardext.c
            do
                echo
                echo "--- $f ---"
                docker exec "$CONTAINER" bash -c '
                    f="$1"
                    for root in /root/gl4es-tsp /root/gl4es-tsps; do
                        if [ -f "$root/$f" ]; then
                            printf "%-20s " "$root"
                            sha256sum "$root/$f" | awk "{print \$1}"
                        else
                            echo "$root MISSING"
                        fi
                    done
                ' _ "$f" 2>/dev/null || true
            done

            echo
            echo "===== TEXLIFE marker locations ====="
            docker exec "$CONTAINER" bash -c '
                for root in /root/gl4es-tsp /root/gl4es-tsps; do
                    echo "--- $root ---"
                    grep -RInE "TSP_TEXLIFE|LIBGL_TSP_TEXLIFE" \
                      --include="*.c" --include="*.h" "$root/src" 2>/dev/null || true
                done
            ' 2>/dev/null || true

            echo
            echo "===== production-sized binary hash comparison ====="
            docker exec "$CONTAINER" bash -c '
                for f in /root/gl4es-tsp/lib/libGL.so.1 /root/gl4es-tsps/lib/libGL.so.1; do
                    [ -e "$f" ] || continue
                    sha256sum "$f"
                done
            ' 2>/dev/null || true
        } > "$WORK/compare/summary.txt" 2>&1

        # A direct diff of only the live source extensions, with build/backup noise excluded.
        docker exec "$CONTAINER" bash -c '
            A=/root/gl4es-tsp
            B=/root/gl4es-tsps
            [ -d "$A" ] && [ -d "$B" ] || exit 0
            diff -ruN \
              --exclude=.git \
              --exclude="build*" \
              --exclude=lib \
              --exclude="*.before-*" \
              --exclude="*.tspsnap*" \
              --exclude="*.tsptrack*" \
              --exclude="*.tspstencil*" \
              --exclude="*.tsppacked*" \
              "$A/src" "$B/src" 2>/dev/null || true
        ' > "$WORK/compare/live-src.diff" 2>&1 || true

        cat > "$WORK/README.txt" <<'EOF'
TSP_GL4ES_SOURCE_LINEAGE_V1

Purpose:
  Resolve which source tree actually produced the currently installed TSP libGL
  before creating the NEW isolated PowerVR-only fork.

This dump is read-only. It performs no build and no source edits.
EOF

        echo "[4/4] Creating archive"

        rm -f "$OUT" 2>/dev/null || true

        if tar -cf "$OUT" -C "$WORK" .; then
            if tar -tf "$OUT" >/dev/null 2>&1; then
                sync 2>/dev/null || true
                echo
                echo "============================================================"
                echo "SOURCE LINEAGE DUMP COMPLETE"
                echo "============================================================"
                echo "File:"
                echo "$OUT"
                echo
                echo "SHA256:"
                sha256sum "$OUT" 2>/dev/null || true
                echo
                echo "Size:"
                ls -lh "$OUT" 2>/dev/null || true
                echo
                echo "Upload this tar."
            else
                echo "ERROR: archive was created but validation failed."
                echo "Working data remains at:"
                echo "$WORK"
            fi
        else
            echo "ERROR: archive creation failed."
            echo "Working data remains at:"
            echo "$WORK"
        fi
    fi
fi

echo
echo "Returned safely to your VM shell."
