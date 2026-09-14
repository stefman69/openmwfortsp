#!/bin/sh
# tsp_orphan5.sh - TSP_VBO_ORPHAN_V5: fresh GLES buffer name per dynamic-VBO write (gl4es), built once,
# deployed to every card, verified. POSIX sh on the host VM (bob-simpson). Modes:
#   sh ~/Downloads/tsp_orphan5.sh            build + apply + policy on   (the one command)
#   sh ~/Downloads/tsp_orphan5.sh build      patch buffers.c from git HEAD, rebuild (full output), gate, export
#   sh ~/Downloads/tsp_orphan5.sh apply      deploy ~/Downloads/libGL.so.1.orphan5 to each card (backup kept)
#   sh ~/Downloads/tsp_orphan5.sh check      after a play session: proof lines + GPU kernel messages per card
#   sh ~/Downloads/tsp_orphan5.sh revert     put back the lib each card had before V5 (backups/libGL.so.1.before-orphan5-*)
# Cards come from ~/.tsp_hosts (name<TAB>host); TSP=<host> in the environment limits it to one card.
# Everything V5 does in the game is gated on LIBGL_TSP_ORPHAN=1, exported by the TSP_LEVER_V1 launcher
# block unless tsp_lever_policy.txt says orphan=off - the script clears that policy with tsp_lever.sh on.

MODE="${1:-all}"
STAMP=$(date +%Y%m%d-%H%M%S)
DL="$HOME/Downloads"
LIB_OUT="$DL/libGL.so.1.orphan5"
LIBDIR=/mnt/SDCARD/data/ports/openmw/lib
MARK=TSP_VBO_ORPHAN_V5
SSH="ssh -o ConnectTimeout=10"
CONTAINER=openmw_builder
TREE=/root/gl4es-tsps
mkdir -p "$DL"

say() { printf '%s\n' "$*"; }
hdr() { say ""; say "########## $* ##########"; }
die() { say "  !! $*"; exit 1; }

# ---------------------------------------------------------------- card list
hosts() {
    if [ -n "$TSP" ]; then
        printf '%s\t%s\n' "${TSP_NAME:-tsp?}" "$TSP"; return
    fi
    if [ -f "$HOME/.tsp_hosts" ]; then
        grep -v '^[[:space:]]*#' "$HOME/.tsp_hosts" | awk 'NF>=2 {print $1 "\t" $2}'
        return
    fi
    say "  !! ~/.tsp_hosts not found - falling back to the two known cards" >&2
    printf 'tsps\t192.168.1.12\ntsp\t192.168.1.21\n'
}
sshhost() { case "$1" in *@*) printf '%s' "$1";; *) printf 'root@%s' "$1";; esac; }

# ---------------------------------------------------------------- docker
DOCKER=docker
docker info >/dev/null 2>&1 || DOCKER="sudo docker"

# ---------------------------------------------------------------- the patcher (awk, runs inside the container)
write_patcher() {
cat > "$1" <<'EOF_AWK'
# TSP_VBO_ORPHAN_V5 patcher for gl4es src/gl/buffers.c (input must be pristine HEAD)
BEGIN { helpers = 0; hook = 0; refused = 0 }
/TSP_VBO_ORPHAN/ { refused = 1; print "TSP_VBO_ORPHAN_V5 PATCH REFUSED: input already carries an orphan marker" > "/dev/stderr"; exit 4 }
/^\/\/#define DEBUG[[:space:]]*$/ && helpers == 0 {
    helpers = 1
    print "#include <stdio.h>"
    print "#include <stdlib.h>"
    print "#include <string.h>"
    print "/* TSP_VBO_ORPHAN_V5 - a fresh GLES buffer name for every write into a DYNAMIC/STREAM array VBO."
    print " * The full gl4es shadow is uploaded into the new name with glBufferData, the old name is deleted"
    print " * (the driver keeps its storage alive for any draw already queued on it), every attrib that"
    print " * referenced the old name is repointed, and the gles-side attrib cache is invalidated so"
    print " * realize_glenv re-issues glVertexAttribPointer before the next draw. Nothing here relies on"
    print " * the driver honouring a respec of a bound buffer (which is what V2/V3/V4 all assumed)."
    print " * STATIC_DRAW buffers keep the stock glBufferSubData path. Gate: LIBGL_TSP_ORPHAN exactly \"1\". */"
    print "void rebind_real_buff_arrays(int old_buffer, int new_buffer);   /* defined further down in this file */"
    print "static int tsp_orphan_on(void) {"
    print "    static int v = -1;"
    print "    if (v < 0) { const char* e = getenv(\"LIBGL_TSP_ORPHAN\"); v = (e && e[0] == '1' && e[1] == 0) ? 1 : 0; }"
    print "    return v;"
    print "}"
    print "static void tsp_orphan_report(long sz, int fallback) {"
    print "    static unsigned long n = 0, kb = 0, fb = 0;"
    print "    kb += (unsigned long)(sz >> 10);"
    print "    if (fallback) ++fb;"
    print "    if ((++n & 0xffff) == 1) {   /* first rotation, then every 65536 */"
    print "        printf(\"TSP_VBO_ORPHAN_V5 on=1 (fresh buffer name per dynamic write; supersedes V1-V4) rotate=%lu kb=%lu fallback=%lu\\n\", n, kb, fb);"
    print "        fflush(stdout);"
    print "    }"
    print "}"
    print "/* returns 1 when the buffer was rotated onto a fresh name, 0 when the caller must take the stock path */"
    print "static int tsp_orphan_rotate(glbuffer_t* buff, GLenum target) {"
    print "    LOAD_GLES(glGenBuffers);"
    print "    LOAD_GLES(glBufferData);"
    print "    GLuint old = buff->real_buffer, fresh = 0;"
    print "    if (!buff->data || buff->size <= 0) return 0;"
    print "    gles_glGenBuffers(1, &fresh);"
    print "    if (!fresh) return 0;"
    print "    bindBuffer(target, fresh);"
    print "    gles_glBufferData(target, buff->size, buff->data, buff->usage);"
    print "    buff->real_buffer = fresh;"
    print "    rebind_real_buff_arrays(old, fresh);   /* glstate->vao attribs that named the old buffer */"
    print "    if (glstate->gleshard) {              /* gles-side cache: force a fresh glVertexAttribPointer */"
    print "        for (int i = 0; i < hardext.maxvattrib; ++i)"
    print "            if (glstate->gleshard->vertexattrib[i].real_buffer == old)"
    print "                glstate->gleshard->vertexattrib[i].real_buffer = 0;"
    print "    }"
    print "    deleteSingleBuffer(old);"
    print "    return 1;"
    print "}"
    print ""
}
{ print }
/^    if\(\(target==GL_ARRAY_BUFFER \|\| target==GL_ELEMENT_ARRAY_BUFFER\) && buff->real_buffer\) \{$/ && hook == 0 {
    hook = 1
    print "        if(target==GL_ARRAY_BUFFER && (buff->usage==GL_DYNAMIC_DRAW || buff->usage==GL_STREAM_DRAW) && tsp_orphan_on()) {   /* TSP_VBO_ORPHAN_V5 */"
    print "            memcpy((char*)buff->data + offset, data, size);   /* shadow first: the fresh name is filled from it */"
    print "            if(tsp_orphan_rotate(buff, target)) {"
    print "                tsp_orphan_report(size, 0);"
    print "                noerrorShim();"
    print "                return;"
    print "            }"
    print "            tsp_orphan_report(size, 1);   /* could not rotate: fall through to the stock SubData below */"
    print "        }"
}
END { if (refused) exit 4; if (helpers != 1 || hook != 1) { print "TSP_VBO_ORPHAN_V5 PATCH FAILED helpers=" helpers " hook=" hook > "/dev/stderr"; exit 3 } }
EOF_AWK
}

# ---------------------------------------------------------------- build
do_build() {
    hdr "BUILD 1/4  patch gl4es in $CONTAINER  ($STAMP)"
    $DOCKER ps --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER" || die "container $CONTAINER is not running ($DOCKER ps)"
    PATCHER="$DL/tsp_orphan5_patch.awk"
    write_patcher "$PATCHER"
    $DOCKER cp "$PATCHER" "$CONTAINER:/root/tsp_orphan5_patch.awk" || die "docker cp of the patcher failed"
    $DOCKER exec -e STAMP="$STAMP" "$CONTAINER" bash -c '
        set -e
        cd '"$TREE"'
        git checkout -- src/gl/buffers.c src/gl/buffers.h src/gl/fpe.c src/gl/listdraw.c
        left=$(git status --short src/gl/buffers.c src/gl/buffers.h src/gl/fpe.c src/gl/listdraw.c | wc -l)
        echo "  restored buffers.c, buffers.h, fpe.c, listdraw.c to git HEAD (uncommitted lines left: $left)"
        [ "$left" = 0 ] || { echo "  !! restore failed"; exit 1; }
        n=$(grep -c TSP_VBO_ORPHAN src/gl/buffers.c || true)
        [ "$n" = 0 ] || { echo "  !! HEAD buffers.c already carries an orphan marker ($n) - refusing"; exit 1; }
        cp src/gl/buffers.c src/gl/buffers.c.before-orphan5-$STAMP
        awk -f /root/tsp_orphan5_patch.awk src/gl/buffers.c.before-orphan5-$STAMP > src/gl/buffers.c.tmp
        mv src/gl/buffers.c.tmp src/gl/buffers.c
        echo "  patched src/gl/buffers.c with '"$MARK"' (buffers.h, fpe.c, listdraw.c stay pristine)"
        echo "  -- diffstat --"; git diff --stat -- src/gl/buffers.c
        echo "  -- marker lines --"; grep -n '"$MARK"' src/gl/buffers.c
        echo "  -- the hook, in place --"; grep -n -A9 "TSP_VBO_ORPHAN_V5 \*/" src/gl/buffers.c | head -12
    ' || { $DOCKER exec "$CONTAINER" bash -c 'cd '"$TREE"' && git checkout -- src/gl/buffers.c' ; die "patch step failed - buffers.c restored to HEAD, nothing built"; }

    hdr "BUILD 2/4  rebuild gl4es (full output; also saved to $DL/tsp-orphan5-build-$STAMP.txt)"
    say "  lib before: $($DOCKER exec "$CONTAINER" md5sum $TREE/lib/libGL.so.1 2>/dev/null)"
    RC="$DL/.tsp-orphan5-rc-$STAMP"
    ( $DOCKER exec "$CONTAINER" bash -c 'export MAKEFLAGS=-j4; bash /root/rebuild_gl4es_tsps_o3.sh' 2>&1; echo $? > "$RC" ) | tee "$DL/tsp-orphan5-build-$STAMP.txt"
    rc=$(cat "$RC" 2>/dev/null || echo 99); rm -f "$RC"
    [ "$rc" = 0 ] || die "rebuild exited $rc - not exporting, nothing deployed (buffers.c left patched for inspection; git checkout -- src/gl/buffers.c to drop it)"

    hdr "BUILD 3/4  gate: the built lib must carry $MARK and be new"
    $DOCKER exec "$CONTAINER" bash -c '
        L='"$TREE"'/lib/libGL.so.1
        m=$(grep -a -c '"$MARK"' "$L" || true)
        v4=$(grep -a -c TSP_VBO_ORPHAN_V4 "$L" || true)
        echo "  $L  marker=$m stale_v4=$v4 $(md5sum "$L" | cut -c1-32) $(stat -c "%s %y" "$L")"
        [ "$m" -ge 1 ] || { echo "  !! marker missing from the built lib"; exit 1; }
        [ "$v4" = 0 ] || { echo "  !! a V4 string is still in the lib - stale build?"; exit 1; }
        [ -z "$(find "$L" -mmin +15)" ] || { echo "  !! lib is older than 15 minutes - the rebuild did not produce it"; exit 1; }
    ' || die "gate failed - nothing deployed"

    hdr "BUILD 4/4  export"
    rm -f "$LIB_OUT" "$LIB_OUT-$STAMP"
    $DOCKER cp "$CONTAINER:$TREE/lib/libGL.so.1" "$LIB_OUT-$STAMP" || die "docker cp of the lib failed"
    cp "$LIB_OUT-$STAMP" "$LIB_OUT"
    HOST_MD5=$(md5sum "$LIB_OUT" | cut -c1-32)
    say "  $LIB_OUT  md5=$HOST_MD5  size=$(stat -c %s "$LIB_OUT")  marker=$(grep -a -c "$MARK" "$LIB_OUT")"
    say "  (copy kept as $LIB_OUT-$STAMP)"
}

# ---------------------------------------------------------------- apply
do_apply() {
    [ -f "$LIB_OUT" ] || die "$LIB_OUT missing - run build first"
    HOST_MD5=$(md5sum "$LIB_OUT" | cut -c1-32)
    [ "$(grep -a -c "$MARK" "$LIB_OUT")" -ge 1 ] || die "$LIB_OUT does not carry $MARK - refusing to deploy it"
    hosts | while IFS="$(printf '\t')" read -r NAME HOST; do
        H=$(sshhost "$HOST")
        hdr "APPLY on $NAME ($H)  $STAMP"
        say "  live lib before: $($SSH "$H" "md5sum $LIBDIR/libGL.so.1 2>/dev/null | cut -c1-32; ls -l $LIBDIR/libGL.so.1 2>/dev/null" | tr '\n' ' ')"
        if ! $SSH "$H" "test -f $LIBDIR/libGL.so.1"; then say "  !! $LIBDIR/libGL.so.1 not on $NAME - skipping"; continue; fi
        say "  uploading $(stat -c %s "$LIB_OUT") bytes ..."
        if ! $SSH "$H" "cat > $LIBDIR/libGL.so.1.orphan5.tmp" < "$LIB_OUT"; then say "  !! upload failed on $NAME"; continue; fi
        REM=$($SSH "$H" "cd $LIBDIR && mkdir -p backups && cp libGL.so.1 backups/libGL.so.1.before-orphan5-$STAMP && mv libGL.so.1.orphan5.tmp libGL.so.1 && chmod +x libGL.so.1 && md5sum libGL.so.1 | cut -c1-32" | tail -n 1)
        if [ "$REM" = "$HOST_MD5" ]; then
            say "  deployed: md5=$REM matches the host copy   backup: backups/libGL.so.1.before-orphan5-$STAMP"
        else
            say "  !! md5 on $NAME is '$REM', host is $HOST_MD5 - deploy NOT verified on $NAME"
        fi
    done
    hdr "POLICY  orphan must be ON for V5 to run (clears any orphan=off left from the last test)"
    if [ -f "$DL/tsp_net.sh" ] && [ -f "$DL/tsp_lever.sh" ]; then
        sh "$DL/tsp_net.sh" each tsp_lever.sh on 2>&1 | grep -v '^$' | sed 's/^/  /'
    else
        say "  tsp_net.sh / tsp_lever.sh not in ~/Downloads - if you ran 'off orphan' earlier, run: sh ~/Downloads/tsp_net.sh each tsp_lever.sh on"
    fi
    say ""
    say "  next: launch Morrowind on each card, look at an NPC, a flag, the water and a Balmora wall up close, play ~5 min, quit, then:"
    say "        sh ~/Downloads/tsp_orphan5.sh check && sh ~/Downloads/tsp_net.sh each tsp_lever.sh check"
}

# ---------------------------------------------------------------- check (after a play session)
do_check() {
    hosts | while IFS="$(printf '\t')" read -r NAME HOST; do
        H=$(sshhost "$HOST")
        hdr "CHECK on $NAME ($H)  $(date +%Y%m%d-%H%M%S)"
        $SSH "$H" '
            L='"$LIBDIR"'/libGL.so.1
            echo "  deployed lib: $(md5sum $L | cut -c1-32) $(ls -l $L | awk "{print \$5, \$6, \$7, \$8}")"
            echo "  -- last two launches (tsp_prog.txt) --"
            grep "TSP_LEVER_V1 armed" /mnt/SDCARD/tsp_prog.txt 2>/dev/null | tail -2 | sed "s/^/  /"
            F=$(find /mnt/SDCARD/data/ports/openmw /root/.local/share/openmw /mnt/SDCARD/.local/share/openmw -maxdepth 4 -name openmw_log.txt 2>/dev/null)
            LOG=""; [ -n "$F" ] && LOG=$(ls -t $F | head -1)
            if [ -z "$LOG" ]; then echo "  !! openmw_log.txt not found under the usual roots"; exit 0; fi
            echo "  -- $LOG ($(ls -l "$LOG" | awk "{print \$5, \$6, \$7, \$8}")) --"
            echo "  V5 proof lines (expect rotate=1 first, then every 65536; fallback must stay 0):"
            grep -n "TSP_VBO_ORPHAN" "$LOG" | head -3 | sed "s/^/    /"
            echo "    ... last:"; grep "TSP_VBO_ORPHAN" "$LOG" | tail -1 | sed "s/^/    /"
            [ "$(grep -c TSP_VBO_ORPHAN_V5 "$LOG")" = 0 ] && echo "    (no V5 line: the launcher did not export LIBGL_TSP_ORPHAN=1, or this log is from before the deploy)"
            echo "  GL errors logged by openmw: $(grep -c -i "GL error\|glGetError\|invalid operation" "$LOG")"
            echo "  -- GPU kernel messages (last 5; a job/page fault here would be V5 hurting the driver) --"
            dmesg 2>/dev/null | grep -i "kbase\|mali\|pvr\|gpu" | tail -5 | sed "s/^/    /"
        '
    done
}

# ---------------------------------------------------------------- revert (lib only; launcher levers untouched)
do_revert() {
    hosts | while IFS="$(printf '\t')" read -r NAME HOST; do
        H=$(sshhost "$HOST")
        hdr "REVERT on $NAME ($H)"
        $SSH "$H" '
            cd '"$LIBDIR"' || exit 1
            B=$(ls -t backups/libGL.so.1.before-orphan5-* 2>/dev/null | head -1)
            [ -n "$B" ] || { echo "  no before-orphan5 backup here - nothing to do"; exit 0; }
            cp libGL.so.1 backups/libGL.so.1.orphan5-removed-'"$STAMP"' && cp "$B" libGL.so.1 && chmod +x libGL.so.1
            echo "  restored $B -> libGL.so.1  md5=$(md5sum libGL.so.1 | cut -c1-32)"
        '
    done
}

case "$MODE" in
    all)    do_build; do_apply ;;
    build)  do_build ;;
    apply)  do_apply ;;
    check)  do_check ;;
    revert) do_revert ;;
    *) die "unknown mode '$MODE' (all|build|apply|check|revert)" ;;
esac
