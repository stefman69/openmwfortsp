#!/usr/bin/env bash

main() {
    CONTAINER="openmw_builder"
    SRC="/root/gl4es-tsps/src/gl/buffers.c"
    REBUILD="/root/rebuild_gl4es_tsps_o3.sh"
    EXPORT="/root/gl4es-tsps-export-o3/libGL.so.1"
    DOWNLOADS="/home/bob-simpson/Downloads"
    DEVICE="root@192.168.1.12"
    GAME="/mnt/SDCARD/data/ports/openmw"
    TARGET="$GAME/lib/libGL.so.1"
    STAMP="$(date +%Y%m%d-%H%M%S)"
    BACKUP="$DOWNLOADS/buffers.c.before-MULTIOWNER-$STAMP"
    BUILDLOG="$DOWNLOADS/gl4es-multiowner-v1-build-$STAMP.log"
    OUT="$DOWNLOADS/libGL.so.1-TSP_MULTI_OWNER_V1"
    LAUNCH_LOCAL="$DOWNLOADS/Morrowind-DIAGNOSTICS-MULTIOWNER-V1.sh"

    echo
    echo "============================================================"
    echo "TSP MULTI-OWNER V1: PATCH + BUILD + DEPLOY"
    echo "============================================================"

    echo "===== VERIFY LIVE SOURCE ====="
    docker exec "$CONTAINER" sh -c "[ -f '$SRC' ] && grep -n 'TSP_GL4ES_SHADOW_SHRINK_V1' '$SRC' | head -3" 2>&1
    if [ $? -ne 0 ]; then
        echo "ERROR: live GL4ES source or SHADOW_SHRINK_V1 marker is missing."
        echo "Nothing changed. Terminal remains open."
        return 1
    fi

    echo
    echo "===== BACKUP LIVE buffers.c ====="
    docker cp "$CONTAINER:$SRC" "$BACKUP" 2>&1
    if [ $? -ne 0 ] || [ ! -s "$BACKUP" ]; then
        echo "ERROR: source backup failed."
        return 1
    fi
    echo "PASS: $BACKUP"

    echo
    echo "===== PATCH VAO RELEASE + GL4ES OWNER ACCOUNTING ====="
    docker exec -i "$CONTAINER" python3 - "$SRC" <<'PY_EOF'
import sys
from pathlib import Path

p = Path(sys.argv[1])
s = p.read_text()

if "TSP_GL4ES_VAO_RELEASE_V1" in s and "TSP_GL4ES_OWNER_V1" in s:
    print("PASS: MULTIOWNER patch already present")
    raise SystemExit(0)

if "TSP_GL4ES_SHADOW_SHRINK_V1" not in s:
    print("ERROR: existing shadow-shrink patch missing")
    raise SystemExit(2)

anchor = "KHASH_MAP_IMPL_INT(glvao, glvao_t*);"
if anchor not in s:
    print("ERROR: glvao khash anchor missing")
    raise SystemExit(3)

owner = r'''\n/* TSP_GL4ES_OWNER_V1 */
static const char tsp_gl4es_owner_marker[] __attribute__((used)) = "TSP_GL4ES_OWNER_V1";
static const char tsp_gl4es_vao_release_marker[] __attribute__((used)) = "TSP_GL4ES_VAO_RELEASE_V1";
static unsigned long tsp_owner_events = 0;
static unsigned long tsp_owner_vao_created = 0;
static unsigned long tsp_owner_vao_freed = 0;

static FILE* tsp_owner_file(void) {
    static int checked = 0;
    static FILE* f = NULL;
    if (!checked) {
        const char* path = getenv("LIBGL_TSP_OWNER_DIAG");
        checked = 1;
        if (path && path[0]) f = fopen(path, "w");
    }
    return f;
}

static void tsp_owner_snapshot(const char* why) {
    FILE* f = tsp_owner_file();
    if (!f || !glstate) return;
    unsigned long ev = ++tsp_owner_events;
    if (ev != 1 && (ev & 0xffUL) != 0) return;

    unsigned long live_buffers = 0, real_buffers = 0, live_vaos = 0;
    unsigned long long shadow_bytes = 0;

    if (glstate->buffers) {
        khash_t(buff)* list = glstate->buffers;
        for (khint_t k = kh_begin(list); k != kh_end(list); ++k) {
            if (!kh_exist(list, k)) continue;
            glbuffer_t* b = kh_value(list, k);
            if (!b) continue;
            ++live_buffers;
            if (b->real_buffer) ++real_buffers;
            if (b->data && b->size > 0) shadow_bytes += (unsigned long long)b->size;
        }
    }

    if (glstate->vaos) {
        khash_t(glvao)* list = glstate->vaos;
        for (khint_t k = kh_begin(list); k != kh_end(list); ++k)
            if (kh_exist(list, k) && kh_value(list, k)) ++live_vaos;
    }

    fprintf(f,
        "TSP_GL4ES_OWNER_V1 event=%lu why=%s buffers=%lu real_buffers=%lu shadow_b=%llu vao_live=%lu vao_created=%lu vao_freed=%lu vao_outstanding=%ld\n",
        ev, why ? why : "?", live_buffers, real_buffers, shadow_bytes,
        live_vaos, tsp_owner_vao_created, tsp_owner_vao_freed,
        (long)tsp_owner_vao_created - (long)tsp_owner_vao_freed);
    fflush(f);
}
'''

s = s.replace(anchor, anchor + owner, 1)

alloc = "glvao = kh_value(list, k) = malloc(sizeof(glvao_t));"
if alloc not in s:
    print("ERROR: VAO allocation anchor missing")
    raise SystemExit(4)
s = s.replace(alloc, alloc + '\n            ++tsp_owner_vao_created;\n            tsp_owner_snapshot("VAO_CREATE");', 1)

old = "                    VaoSharedClear(glvao);\n                    kh_del(glvao, list, k);\n                    //free(glvao);  //let the use delete those"
if old not in s:
    print("ERROR: glDeleteVertexArrays ownership block missing")
    raise SystemExit(5)
new = "                    if (glstate->vao == glvao)\n                        glstate->vao = glstate->defaultvao;\n                    VaoSharedClear(glvao);\n                    kh_del(glvao, list, k);\n                    free(glvao);\n                    ++tsp_owner_vao_freed;\n                    tsp_owner_snapshot(\"VAO_DELETE\");  /* TSP_GL4ES_VAO_RELEASE_V1 */"
s = s.replace(old, new, 1)

copy_anchor = "    if (data)\n        memcpy(buff->data, data, size);\n    // update binded VA"
if s.count(copy_anchor) < 2:
    print("ERROR: BufferData snapshot anchors missing")
    raise SystemExit(6)
s = s.replace(copy_anchor, "    if (data)\n        memcpy(buff->data, data, size);\n    tsp_owner_snapshot(\"BUFFER_DATA\");\n    // update binded VA", 2)

start = s.find("void APIENTRY_GL4ES gl4es_glDeleteBuffers")
end = s.find("GLboolean APIENTRY_GL4ES gl4es_glIsBuffer", start)
if start < 0 or end < 0:
    print("ERROR: could not isolate glDeleteBuffers")
    raise SystemExit(7)
seg = s[start:end]
if "                    free(buff);" not in seg:
    print("ERROR: free(buff) anchor missing")
    raise SystemExit(8)
seg = seg.replace("                    free(buff);", "                    free(buff);\n                    tsp_owner_snapshot(\"BUFFER_DELETE\");", 1)
s = s[:start] + seg + s[end:]

p.write_text(s)
print("PASS: TSP_GL4ES_VAO_RELEASE_V1")
print("PASS: TSP_GL4ES_OWNER_V1")
PY_EOF
    PATCH_RC=$?

    if [ "$PATCH_RC" -ne 0 ]; then
        echo "ERROR: patch failed RC=$PATCH_RC"
        echo "Restoring source backup..."
        docker cp "$BACKUP" "$CONTAINER:$SRC" 2>&1
        echo "Terminal remains open."
        return 1
    fi

    echo
    echo "===== VERIFY PATCHED SOURCE ====="
    docker exec "$CONTAINER" sh -c "grep -n -E 'TSP_GL4ES_(SHADOW_SHRINK|VAO_RELEASE|OWNER)_V1' '$SRC' | head -40" 2>&1

    echo
    echo "===== BUILD GL4ES ====="
    echo "Live compiler output follows."
    echo "Build log: $BUILDLOG"
    docker exec "$CONTAINER" bash "$REBUILD" 2>&1 | tee "$BUILDLOG"
    BUILD_RC=${PIPESTATUS[0]}
    echo "Build return code: $BUILD_RC"

    if [ "$BUILD_RC" -ne 0 ]; then
        echo
        echo "================ BUILD FAILED ================"
        tail -n 120 "$BUILDLOG"
        echo "Nothing deployed. Terminal remains open."
        return 1
    fi

    echo
    echo "===== VERIFY FINISHED LIBGL ====="
    docker exec "$CONTAINER" sh -c "
        [ -s '$EXPORT' ] || { echo 'ERROR: export missing'; false; }
        ls -lh '$EXPORT'
        sha256sum '$EXPORT'
        for M in TSP_GL4ES_SHADOW_SHRINK_V1 TSP_GL4ES_VAO_RELEASE_V1 TSP_GL4ES_OWNER_V1; do
            grep -a -q \"\$M\" '$EXPORT' && echo \"PASS marker: \$M\" || { echo \"ERROR marker: \$M\"; false; }
        done
    " 2>&1
    if [ $? -ne 0 ]; then
        echo "ERROR: built library verification failed. Nothing deployed."
        return 1
    fi

    rm -f "$OUT"
    docker cp "$CONTAINER:$EXPORT" "$OUT" 2>&1
    if [ $? -ne 0 ] || [ ! -s "$OUT" ]; then
        echo "ERROR: could not export libGL to Downloads."
        return 1
    fi
    chmod 755 "$OUT"
    EXPECTED="$(sha256sum "$OUT" | awk '{print $1}')"
    echo "PASS export: $OUT"
    echo "SHA256: $EXPECTED"

    echo
    echo "===== CREATE MULTI-OWNER LAUNCHER ====="
    cat > "$LAUNCH_LOCAL" <<'LAUNCH_EOF'
#!/bin/sh

run_multiowner() {
    GAME=""
    for G in /mnt/SDCARD/data/ports/openmw /mnt/sdcard/mmcblk1p1/data/ports/openmw /mnt/mmc/ports/openmw /userdata/roms/ports/openmw; do
        [ -x "$G/bin/openmw-0.51" ] && { GAME="$G"; break; }
    done
    [ -z "$GAME" ] && { echo "ERROR: OpenMW game directory not found"; return 1; }

    SELF_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd)"
    OLD="$SELF_DIR/Morrowind-DIAGNOSTICS-GLOWNER-V1-remade.sh"
    if [ ! -f "$OLD" ]; then
        OLD="$(find /mnt/SDCARD/Roms/PORTS /mnt/SDCARD/Emus/PORTS /mnt/sdcard/mmcblk1p1/ROMS/PORTS /mnt/sdcard/mmcblk1p1/Emus/PORTS -maxdepth 2 -type f -name 'Morrowind-DIAGNOSTICS-GLOWNER-V1-remade.sh' 2>/dev/null | head -1)"
    fi
    [ -z "$OLD" ] || [ ! -f "$OLD" ] && { echo "ERROR: existing GLOWNER launcher not found"; return 1; }

    D="$GAME/tsp-multiowner-v1"
    ARCHIVE="$GAME/tsp-multiowner-v1.tar.gz"
    rm -rf "$D" "$ARCHIVE" 2>/dev/null
    mkdir -p "$D"
    export LIBGL_TSP_OWNER_DIAG="$D/gl4es-owner.log"

    {
        echo "TSP MULTI-OWNER V1"; date; uname -a; echo
        echo "GAME=$GAME"; echo "BASE_LAUNCHER=$OLD"; echo
        echo "===== HASHES ====="
        sha256sum "$GAME/bin/openmw-0.51" "$GAME/lib/libGL.so.1" "$OLD" 2>/dev/null
        echo "===== LIBGL MARKERS ====="
        grep -ao 'TSP_[A-Z0-9_]*V[0-9][A-Z0-9_]*' "$GAME/lib/libGL.so.1" 2>/dev/null | sort -u | head -200
        echo "===== ENV ====="
        env | sort | grep -E '^(LIBGL|OPENMW|OSG|TSP_)' || true
    } > "$D/identity.txt" 2>&1

    {
        echo "===== MEMINFO START ====="; cat /proc/meminfo 2>/dev/null
        echo "===== VMSTAT START ====="; cat /proc/vmstat 2>/dev/null
        echo "===== ZRAM START ====="
        for Z in /sys/block/zram*/mm_stat; do [ -r "$Z" ] && { echo "--- $Z"; cat "$Z"; }; done
        echo "===== GPU/PVR CANDIDATES ====="
        find /sys/kernel/debug /sys/class -maxdepth 5 -type f 2>/dev/null | grep -Ei '(pvr|powervr|gpu|mali|dma_buf|ion).*(mem|heap|stat|usage|info)' | head -100
        if [ -r /sys/kernel/debug/dma_buf/bufinfo ]; then
            echo "===== DMA BUF START ====="; head -n 1000 /sys/kernel/debug/dma_buf/bufinfo
        fi
    } > "$D/system-start.txt" 2>&1

    monitor_process() {
        PID=""
        while [ -z "$PID" ]; do
            PID="$(pgrep -o -f "$GAME/bin/openmw-0.51" 2>/dev/null)"
            [ -z "$PID" ] && PID="$(pgrep -o -f 'openmw-0.51' 2>/dev/null)"
            [ -z "$PID" ] && sleep 1
        done

        echo "PID=$PID" > "$D/pid.txt"; date >> "$D/pid.txt"
        cp "/proc/$PID/maps" "$D/maps-start.txt" 2>/dev/null
        N=0

        while kill -0 "$PID" 2>/dev/null; do
            TS="$(date '+%Y-%m-%dT%H:%M:%S%z')"
            STATUS="$(cat "/proc/$PID/status" 2>/dev/null)"
            RSS="$(printf '%s\n' "$STATUS" | awk '/^VmRSS:/ {print $2}')"
            SIZE="$(printf '%s\n' "$STATUS" | awk '/^VmSize:/ {print $2}')"
            DATA="$(printf '%s\n' "$STATUS" | awk '/^VmData:/ {print $2}')"
            SWAP="$(printf '%s\n' "$STATUS" | awk '/^VmSwap:/ {print $2}')"
            ANON="$(printf '%s\n' "$STATUS" | awk '/^RssAnon:/ {print $2}')"
            FILE="$(printf '%s\n' "$STATUS" | awk '/^RssFile:/ {print $2}')"
            SHMEM="$(printf '%s\n' "$STATUS" | awk '/^RssShmem:/ {print $2}')"
            THR="$(printf '%s\n' "$STATUS" | awk '/^Threads:/ {print $2}')"
            FD="$(find "/proc/$PID/fd" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l)"
            MAPS="$(wc -l < "/proc/$PID/maps" 2>/dev/null)"

            echo "$TS pid=$PID vmrss_kb=${RSS:-0} vmsize_kb=${SIZE:-0} vmdata_kb=${DATA:-0} vmswap_kb=${SWAP:-0} rssanon_kb=${ANON:-0} rssfile_kb=${FILE:-0} rssshmem_kb=${SHMEM:-0} threads=${THR:-0} fds=${FD:-0} maps=${MAPS:-0}" >> "$D/process-samples.log"

            { echo "===== $TS ====="; cat "/proc/$PID/smaps_rollup" 2>/dev/null; } >> "$D/smaps-rollup.log"

            awk -v ts="$TS" '
                BEGIN { cat="anon" }
                /^[0-9a-fA-F]+-[0-9a-fA-F]+/ {
                    line=tolower($0); cat="anon";
                    if (line ~ /\[heap\]/) cat="heap";
                    else if (line ~ /libgl|libgles|powervr|pvr|mali/) cat="gpu_lib";
                    else if (line ~ /\[stack/) cat="stack";
                    else if ($0 ~ /\//) cat="file";
                }
                /^Rss:/ {rss[cat]+=$2} /^Pss:/ {pss[cat]+=$2} /^Private_Dirty:/ {pd[cat]+=$2}
                END { printf "%s",ts; for(c in rss) printf " %s_rss_kb=%d %s_pss_kb=%d %s_private_dirty_kb=%d",c,rss[c],c,pss[c],c,pd[c]; printf "\n" }
            ' "/proc/$PID/smaps" 2>/dev/null >> "$D/smaps-categories.log"

            awk -v ts="$TS" '
                /^MemAvailable:/ {a=$2} /^MemFree:/ {f=$2} /^Cached:/ {c=$2} /^Slab:/ {s=$2}
                /^SReclaimable:/ {sr=$2} /^SUnreclaim:/ {su=$2} /^CmaTotal:/ {ct=$2} /^CmaFree:/ {cf=$2}
                /^SwapTotal:/ {st=$2} /^SwapFree:/ {sf=$2}
                END { printf "%s memavail_kb=%d memfree_kb=%d cached_kb=%d slab_kb=%d sreclaim_kb=%d sunreclaim_kb=%d cma_total_kb=%d cma_free_kb=%d swap_total_kb=%d swap_free_kb=%d\n",ts,a,f,c,s,sr,su,ct,cf,st,sf }
            ' /proc/meminfo >> "$D/system-memory-samples.log"

            awk -v ts="$TS" 'BEGIN{printf "%s",ts} /^(nr_free_pages|nr_slab_reclaimable|nr_slab_unreclaimable|nr_anon_pages|nr_file_pages|nr_page_table_pages|pgscan_|pgsteal_|compact_|oom_kill)/ {printf " %s=%s",$1,$2} END{printf "\n"}' /proc/vmstat 2>/dev/null >> "$D/vmstat-samples.log"

            for Z in /sys/block/zram*/mm_stat; do [ -r "$Z" ] && echo "$TS $Z $(cat "$Z" 2>/dev/null)" >> "$D/zram-samples.log"; done

            N=$((N + 1))
            if [ $((N % 6)) -eq 0 ]; then
                { echo "===== $TS PID=$PID ====="; ps -T -p "$PID" -o pid,tid,stat,pcpu,rss,vsz,comm 2>/dev/null; } >> "$D/thread-samples.log"
                cp "/proc/$PID/maps" "$D/maps-latest.txt" 2>/dev/null
            fi
            sleep 10
        done
        date > "$D/monitor-ended.txt"
    }

    monitor_process &
    MON_PID=$!

    echo "============================================================"
    echo "TSP MULTI-OWNER V1"
    echo "Using base launcher: $OLD"
    echo "============================================================"

    "$OLD"
    GAME_RC=$?

    kill "$MON_PID" 2>/dev/null
    wait "$MON_PID" 2>/dev/null

    {
        echo "GAME_RC=$GAME_RC"; date
        echo "===== MEMINFO END ====="; cat /proc/meminfo 2>/dev/null
        echo "===== VMSTAT END ====="; cat /proc/vmstat 2>/dev/null
        if [ -r /sys/kernel/debug/dma_buf/bufinfo ]; then echo "===== DMA BUF END ====="; head -n 1000 /sys/kernel/debug/dma_buf/bufinfo; fi
    } > "$D/system-end.txt" 2>&1

    [ -f "$GAME/tsp-glowner-v1.tar.gz" ] && cp -f "$GAME/tsp-glowner-v1.tar.gz" "$D/glowner-run.tar.gz" 2>/dev/null
    [ -d "$GAME/tsp-glowner-v1" ] && cp -a "$GAME/tsp-glowner-v1" "$D/glowner-directory" 2>/dev/null

    tar -C "$GAME" -czf "$ARCHIVE" tsp-multiowner-v1 2>"$D/tar-error.log"
    TAR_RC=$?
    mkdir -p /root/diagnostics 2>/dev/null

    if [ "$TAR_RC" -eq 0 ] && [ -s "$ARCHIVE" ]; then
        cp -f "$ARCHIVE" /root/diagnostics/tsp-multiowner-v1.tar.gz 2>/dev/null
        echo "============================================================"
        echo "MULTI-OWNER DIAGNOSTIC READY"
        echo "============================================================"
        ls -lh "$ARCHIVE"; sha256sum "$ARCHIVE" 2>/dev/null
        echo "/root/diagnostics/tsp-multiowner-v1.tar.gz"
    else
        echo "ERROR: archive creation failed. Raw diagnostics: $D"
        cat "$D/tar-error.log" 2>/dev/null
    fi

    return "$GAME_RC"
}

run_multiowner "$@"
LAUNCH_EOF
    chmod 755 "$LAUNCH_LOCAL"
    echo "PASS launcher: $LAUNCH_LOCAL"

    echo
    echo "===== DEPLOY LIBGL + NEW LAUNCHER (ONE SSH CONNECTION) ====="
    STAGE="$(mktemp -d)"
    if [ -z "$STAGE" ] || [ ! -d "$STAGE" ]; then
        echo "ERROR: staging directory failed."
        return 1
    fi
    cp "$OUT" "$STAGE/libGL.so.1"
    cp "$LAUNCH_LOCAL" "$STAGE/Morrowind-DIAGNOSTICS-MULTIOWNER-V1.sh"

    tar -C "$STAGE" -cf - libGL.so.1 Morrowind-DIAGNOSTICS-MULTIOWNER-V1.sh | ssh "$DEVICE" "
        GAME='$GAME'; TARGET='$TARGET'; EXPECTED='$EXPECTED'; STAMP='$STAMP'; TMP='/tmp/tsp-multiowner-$STAMP'; OK=1
        rm -rf \"\$TMP\" 2>/dev/null; mkdir -p \"\$TMP\" || OK=0
        if [ \"\$OK\" = 1 ]; then tar -xf - -C \"\$TMP\" || OK=0; else cat >/dev/null; fi

        if [ \"\$OK\" = 1 ]; then
            GOT=\$(sha256sum \"\$TMP/libGL.so.1\" 2>/dev/null | awk '{print \$1}')
            echo \"Expected SHA: \$EXPECTED\"; echo \"Received SHA: \$GOT\"
            [ \"\$GOT\" = \"\$EXPECTED\" ] || { echo 'ERROR: SHA mismatch'; OK=0; }
        fi

        if [ \"\$OK\" = 1 ]; then
            for M in TSP_GL4ES_SHADOW_SHRINK_V1 TSP_GL4ES_VAO_RELEASE_V1 TSP_GL4ES_OWNER_V1; do
                grep -a -q \"\$M\" \"\$TMP/libGL.so.1\" && echo \"PASS marker: \$M\" || { echo \"ERROR marker: \$M\"; OK=0; }
            done
        fi

        OLD=''
        for P in /mnt/SDCARD/Roms/PORTS/Morrowind-DIAGNOSTICS-GLOWNER-V1-remade.sh /mnt/SDCARD/Emus/PORTS/Morrowind-DIAGNOSTICS-GLOWNER-V1-remade.sh /mnt/sdcard/mmcblk1p1/ROMS/PORTS/Morrowind-DIAGNOSTICS-GLOWNER-V1-remade.sh /mnt/sdcard/mmcblk1p1/Emus/PORTS/Morrowind-DIAGNOSTICS-GLOWNER-V1-remade.sh; do
            [ -f \"\$P\" ] && { OLD=\"\$P\"; break; }
        done
        if [ -z \"\$OLD\" ]; then OLD=\$(find /mnt/SDCARD/Roms/PORTS /mnt/SDCARD/Emus/PORTS /mnt/sdcard/mmcblk1p1/ROMS/PORTS /mnt/sdcard/mmcblk1p1/Emus/PORTS -maxdepth 2 -type f -name 'Morrowind-DIAGNOSTICS-GLOWNER-V1-remade.sh' 2>/dev/null | head -1); fi
        [ -z \"\$OLD\" ] && { echo 'ERROR: old GLOWNER launcher not found'; OK=0; }

        if [ \"\$OK\" = 1 ]; then
            BDIR=\"\$GAME/tsp_patch_backups\"; mkdir -p \"\$BDIR\" || OK=0
            BACK=\"\$BDIR/libGL.so.1.before-MULTIOWNER-\$STAMP\"
            [ -s \"\$TARGET\" ] || { echo 'ERROR: current libGL missing'; OK=0; }
            if [ \"\$OK\" = 1 ]; then cp -p \"\$TARGET\" \"\$BACK\" || OK=0; fi
            [ \"\$OK\" = 1 ] && echo \"PASS backup: \$BACK\"
        fi

        if [ \"\$OK\" = 1 ]; then
            cp \"\$TMP/libGL.so.1\" \"\$TARGET.new\" || OK=0
            chmod 755 \"\$TARGET.new\" 2>/dev/null
            [ \"\$OK\" = 1 ] && mv -f \"\$TARGET.new\" \"\$TARGET\" || true
        fi

        if [ \"\$OK\" = 1 ]; then
            LDIR=\$(dirname \"\$OLD\")
            NEWL=\"\$LDIR/Morrowind-DIAGNOSTICS-MULTIOWNER-V1.sh\"
            cp \"\$TMP/Morrowind-DIAGNOSTICS-MULTIOWNER-V1.sh\" \"\$NEWL\" || OK=0
            chmod 755 \"\$NEWL\" 2>/dev/null
        fi

        if [ \"\$OK\" = 1 ]; then
            rm -rf \"\$GAME/tsp-multiowner-v1\" \"\$GAME/tsp-multiowner-v1.tar.gz\" 2>/dev/null
            sync
            echo '===== INSTALLED ====='; ls -lh \"\$TARGET\"; sha256sum \"\$TARGET\"
            echo \"Launcher: \$NEWL\"
            echo 'DEPLOYMENT SUCCESSFUL'
        else
            echo 'DEPLOYMENT FAILED -- see errors above. Terminal remains open.'
        fi
        rm -rf \"\$TMP\" 2>/dev/null
        [ \"\$OK\" = 1 ]
    "
    SSH_RC=$?
    rm -rf "$STAGE" 2>/dev/null

    echo "SSH/deployment return code: $SSH_RC"
    if [ "$SSH_RC" -ne 0 ]; then
        echo "ERROR: deployment failed. Built files remain in Downloads."
        return 1
    fi

    echo
    echo "============================================================"
    echo "ALL DONE"
    echo "Run: Morrowind-DIAGNOSTICS-MULTIOWNER-V1.sh"
    echo "Afterwards send: /root/diagnostics/tsp-multiowner-v1.tar.gz"
    echo "Terminal remains open."
    echo "============================================================"
    return 0
}

main "$@"
