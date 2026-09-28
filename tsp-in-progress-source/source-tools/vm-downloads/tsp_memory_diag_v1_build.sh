#!/usr/bin/env bash
set -Eeuo pipefail

fail()
{
    rc=$?
    echo
    echo "===== TSP MEMORY DIAG BUILD FAILED ====="
    echo "exit=$rc line=${BASH_LINENO[0]:-unknown}"
    echo "No files were deployed to the TSP."
    exit "$rc"
}
trap fail ERR

echo "===== TSP MEMORY DIAG V1 ====="
echo "Purpose: map lifetime instrumentation + broad runtime memory monitor"
echo "This chunk PATCHES / BUILDS / EXPORTS ONLY."
echo "It does NOT deploy to the TSP."
echo

CONTAINER="openmw_builder"
SRC="/root/openmw-0.51-tsp-src"
BUILD="/root/openmw-0.51-tsp-build"
CPP="$SRC/apps/openmw/mwrender/localmap.cpp"

OUT="/home/bob-simpson/Downloads"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="$OUT/tsp-memory-diag-v1-backup-$STAMP"

mkdir -p "$BACKUP"

echo "===== 1. VERIFY CURRENT SOURCE ====="

docker exec "$CONTAINER" test -f "$CPP"

for marker in \
    TSP_LOCALMAP_PERSIST_V7 \
    TSP_LOCALMAP_CPU_PIPE_V78 \
    TSP_LOCALMAP_FRAMEBUFFER_BYPASS_V73
do
    if ! docker exec "$CONTAINER" grep -q "$marker" "$CPP"; then
        echo "ERROR: required marker missing: $marker"
        exit 20
    fi
done

echo "Current localmap markers: PASS"

echo
echo "===== 2. BACKUP AUTHORITATIVE SOURCE ====="

docker cp \
    "$CONTAINER:$CPP" \
    "$BACKUP/localmap.cpp.before"

sha256sum "$BACKUP/localmap.cpp.before" \
    > "$BACKUP/SHA256.before.txt"

echo "Backup:"
echo "$BACKUP/localmap.cpp.before"

echo
echo "===== 3. PATCH LOCALMAP MEMORY TELEMETRY ====="

cat > "$OUT/tsp_memory_diag_v1_patch.py" <<'PY'
from pathlib import Path

p = Path("/root/openmw-0.51-tsp-src/apps/openmw/mwrender/localmap.cpp")
s = p.read_text()

MARKER = "TSP_MAPMEM_V1"

if MARKER in s:
    print("TSP_MAPMEM_V1 already present; no duplicate patch.")
    raise SystemExit(0)

needle = """    // TSP_MAPLIFE_V2
    static unsigned long tspMapLifeGeneration = 0;
"""

replacement = r"""    // TSP_MAPLIFE_V2
    static unsigned long tspMapLifeGeneration = 0;

    // TSP_MAPMEM_V1
    //
    // Lightweight local-map lifetime accounting.  This deliberately
    // counts OpenMW/OSG-side objects only; the launcher-side memory
    // monitor records process/system/swap/driver pressure separately.
    //
    // A 256x256 RGBA CPU tile is 262144 bytes.  V7 keeps the osg::Image
    // referenced by Texture2D, so counting live map textures with images
    // gives us the directly attributable local-map CPU pixel footprint.
    static unsigned long long tspMapMemLoads = 0;
    static unsigned long long tspMapMemLoadFails = 0;
    static unsigned long long tspMapMemSaves = 0;
    static unsigned long long tspMapMemSaveFails = 0;
    static unsigned long long tspMapMemRttCreated = 0;
    static unsigned long long tspMapMemRttDestroyed = 0;
    static unsigned long long tspMapMemExteriorErased = 0;
    static unsigned long long tspMapMemSummarySeq = 0;

    static std::size_t tspMapMemTextureBytes(osg::Texture2D* texture)
    {
        if (texture == nullptr)
            return 0;

        osg::Image* image = texture->getImage();

        if (image == nullptr || image->data() == nullptr)
            return 0;

        return image->getTotalSizeInBytes();
    }
"""

if needle not in s:
    raise SystemExit("PATCH ERROR: TSP_MAPLIFE_V2 anchor not found")

s = s.replace(needle, replacement, 1)

# Count successful persistent loads.
needle = """        Log(Debug::Warning)
            << "TSP_LOCALMAP_PERSIST_V7 "
               "CACHE_LOAD_PASS"
"""

replacement = """        ++tspMapMemLoads;

        Log(Debug::Warning)
            << "TSP_LOCALMAP_PERSIST_V7 "
               "CACHE_LOAD_PASS"
"""

if needle not in s:
    raise SystemExit("PATCH ERROR: CACHE_LOAD_PASS anchor not found")
s = s.replace(needle, replacement, 1)

# Count successful persistent writes.
needle = """        Log(Debug::Warning)
            << "TSP_LOCALMAP_PERSIST_V7 "
               "CACHE_SAVE_PASS"
"""

replacement = """        ++tspMapMemSaves;

        Log(Debug::Warning)
            << "TSP_LOCALMAP_PERSIST_V7 "
               "CACHE_SAVE_PASS"
"""

if needle not in s:
    raise SystemExit("PATCH ERROR: CACHE_SAVE_PASS anchor not found")
s = s.replace(needle, replacement, 1)

# Count RTT creation.
needle = """        Log(Debug::Warning)
            << "TSP_LOCALMAP_PERSIST_V7 "
               "RTT_CREATED"
"""

replacement = """        ++tspMapMemRttCreated;

        Log(Debug::Warning)
            << "TSP_LOCALMAP_PERSIST_V7 "
               "RTT_CREATED"
"""

if needle not in s:
    raise SystemExit("PATCH ERROR: RTT_CREATED anchor not found")
s = s.replace(needle, replacement, 1)

# Record exterior segment release.  This is particularly important:
# current V7 already saves then erases unloaded exterior segments.
needle = """        if (it != mExteriorSegments.end())
        {
            tspLocalMapV7Save(
                x,
                y,
                mMapResolution,
                it->second.mMapTexture.get());
        }

        mExteriorSegments.erase({ x, y });
"""

replacement = r"""        if (it != mExteriorSegments.end())
        {
            const std::size_t releasingBytes
                = tspMapMemTextureBytes(
                    it->second.mMapTexture.get());

            const bool saved
                = tspLocalMapV7Save(
                    x,
                    y,
                    mMapResolution,
                    it->second.mMapTexture.get());

            if (!saved)
                ++tspMapMemSaveFails;

            ++tspMapMemExteriorErased;

            Log(Debug::Warning)
                << "TSP_MAPMEM_V1 RELEASE_EXT"
                << " cell=" << x << "," << y
                << " cpu_image_bytes=" << releasingBytes
                << " saved=" << (saved ? 1 : 0)
                << " ext_before=" << mExteriorSegments.size();
        }

        mExteriorSegments.erase({ x, y });
"""

if needle not in s:
    raise SystemExit("PATCH ERROR: removeExteriorCell anchor not found")
s = s.replace(needle, replacement, 1)

# Replace cleanupCameras tail with periodic map residency summary.
needle = """        if (tspMapLifeEnabled() && removed)
        {
            Log(Debug::Warning)
                << "TSP_MAPLIFE_V2 phase=rtt_cleanup"
                << " gen=" << tspMapLifeGeneration
                << " before=" << before
                << " removed=" << removed
                << " after=" << mLocalMapRTTs.size()
                << " ext=" << mExteriorSegments.size()
                << " interior=" << mInteriorSegments.size();
        }
    }
"""

replacement = r"""        tspMapMemRttDestroyed += removed;

        if (tspMapLifeEnabled() && removed)
        {
            Log(Debug::Warning)
                << "TSP_MAPLIFE_V2 phase=rtt_cleanup"
                << " gen=" << tspMapLifeGeneration
                << " before=" << before
                << " removed=" << removed
                << " after=" << mLocalMapRTTs.size()
                << " ext=" << mExteriorSegments.size()
                << " interior=" << mInteriorSegments.size();
        }

        /*
         * Do not scan every frame.  Once every 300 cleanup calls is
         * enough to correlate local-map residency with the external
         * 10-second memory sampler, while keeping logging negligible.
         */
        ++tspMapMemSummarySeq;

        if (removed != 0 || (tspMapMemSummarySeq % 300) == 0)
        {
            std::size_t exteriorTextureCount = 0;
            std::size_t exteriorCpuBytes = 0;
            std::size_t exteriorFogBytes = 0;

            for (const auto& entry : mExteriorSegments)
            {
                const MapSegment& seg = entry.second;

                if (seg.mMapTexture)
                {
                    ++exteriorTextureCount;
                    exteriorCpuBytes
                        += tspMapMemTextureBytes(
                            seg.mMapTexture.get());
                }

                if (seg.mFogOfWarImage)
                    exteriorFogBytes
                        += seg.mFogOfWarImage
                               ->getTotalSizeInBytes();
            }

            std::size_t interiorTextureCount = 0;
            std::size_t interiorCpuBytes = 0;
            std::size_t interiorFogBytes = 0;

            for (const auto& entry : mInteriorSegments)
            {
                const MapSegment& seg = entry.second;

                if (seg.mMapTexture)
                {
                    ++interiorTextureCount;
                    interiorCpuBytes
                        += tspMapMemTextureBytes(
                            seg.mMapTexture.get());
                }

                if (seg.mFogOfWarImage)
                    interiorFogBytes
                        += seg.mFogOfWarImage
                               ->getTotalSizeInBytes();
            }

            std::size_t activeRttCpuBytes = 0;
            std::size_t activeRttReadbackBytes = 0;

            for (const auto& rtt : mLocalMapRTTs)
            {
                if (!rtt)
                    continue;

                if (rtt->mTspCpuImage)
                    activeRttCpuBytes
                        += rtt->mTspCpuImage
                               ->getTotalSizeInBytes();

                activeRttReadbackBytes
                    += rtt->mTspReadbackBuffer.size();
            }

            Log(Debug::Warning)
                << "TSP_MAPMEM_V1 SUMMARY"
                << " ext_segments=" << mExteriorSegments.size()
                << " ext_textures=" << exteriorTextureCount
                << " ext_cpu_bytes=" << exteriorCpuBytes
                << " ext_fog_bytes=" << exteriorFogBytes
                << " int_segments=" << mInteriorSegments.size()
                << " int_textures=" << interiorTextureCount
                << " int_cpu_bytes=" << interiorCpuBytes
                << " int_fog_bytes=" << interiorFogBytes
                << " active_rtt=" << mLocalMapRTTs.size()
                << " rtt_cpu_bytes=" << activeRttCpuBytes
                << " rtt_readback_bytes=" << activeRttReadbackBytes
                << " loads=" << tspMapMemLoads
                << " saves=" << tspMapMemSaves
                << " save_fail=" << tspMapMemSaveFails
                << " rtt_created=" << tspMapMemRttCreated
                << " rtt_destroyed=" << tspMapMemRttDestroyed
                << " ext_erased=" << tspMapMemExteriorErased;
        }
    }
"""

if needle not in s:
    raise SystemExit("PATCH ERROR: cleanupCameras anchor not found")
s = s.replace(needle, replacement, 1)

p.write_text(s)

print("TSP_MAPMEM_V1 patch applied.")
PY

docker cp \
    "$OUT/tsp_memory_diag_v1_patch.py" \
    "$CONTAINER:/tmp/tsp_memory_diag_v1_patch.py"

docker exec "$CONTAINER" \
    python3 /tmp/tsp_memory_diag_v1_patch.py

COUNT="$(
    docker exec "$CONTAINER" \
        grep -c 'TSP_MAPMEM_V1' "$CPP"
)"

if [ "$COUNT" -lt 3 ]; then
    echo "ERROR: instrumentation verification failed."
    exit 30
fi

echo "Patch verification: PASS"
echo "TSP_MAPMEM_V1 occurrences: $COUNT"

echo
echo "===== 4. BUILD OPENMW ====="

BUILDLOG="$OUT/tsp-memory-diag-v1-build.log"

if docker exec "$CONTAINER" \
    cmake --build "$BUILD" \
    --target openmw -- -j2 \
    >"$BUILDLOG" 2>&1
then
    echo "OpenMW build: PASS"
else
    echo "OpenMW build: FAIL"
    echo
    echo "===== LAST 80 BUILD LINES ====="
    tail -80 "$BUILDLOG"
    exit 40
fi

echo
echo "===== 5. LOCATE BUILT BINARY ====="

BIN=""

for candidate in \
    "$BUILD/openmw" \
    "$BUILD/apps/openmw/openmw" \
    "$BUILD/bin/openmw"
do
    if docker exec "$CONTAINER" test -f "$candidate"; then
        BIN="$candidate"
        break
    fi
done

if [ -z "$BIN" ]; then
    echo "ERROR: built OpenMW binary not found in expected locations."
    exit 50
fi

echo "Built binary: $BIN"

echo
echo "===== 6. EXPORT ====="

docker cp \
    "$CONTAINER:$BIN" \
    "$OUT/openmw-0.51-tsp-memory-diag-v1"

docker cp \
    "$CONTAINER:$CPP" \
    "$OUT/localmap.cpp.tsp-memory-diag-v1"

chmod +x "$OUT/openmw-0.51-tsp-memory-diag-v1"

sha256sum \
    "$OUT/openmw-0.51-tsp-memory-diag-v1" \
    "$OUT/localmap.cpp.tsp-memory-diag-v1" \
    > "$OUT/tsp-memory-diag-v1-SHA256.txt"

echo
echo "===== 7. BUILD RUNTIME MEMORY MONITOR ====="

cat > "$OUT/tsp_memwatch_v1.sh" <<'MEMWATCH'
#!/bin/sh

# TSP_MEMWATCH_V1
#
# Usage:
#   tsp_memwatch_v1.sh OPENMW_PID OUTPUT_DIR
#
# BusyBox-friendly.  No Python, smem, pmap, gdb or other optional
# packages are required.

PID="$1"
OUT="${2:-/mnt/SDCARD/data/ports/openmw/tsp-memory-diag}"

mkdir -p "$OUT" 2>/dev/null || exit 1

TSV="$OUT/memory.tsv"
EVENTS="$OUT/events.log"
FINAL="$OUT/final.txt"

echo "TSP_MEMWATCH_V1 start pid=$PID date=$(date)" > "$EVENTS"

echo "epoch	memavail_kb	memfree_kb	cached_kb	buffers_kb	slab_kb	sreclaim_kb	shmem_kb	swaptotal_kb	swapfree_kb	vmrss_kb	vmsize_kb	vmdata_kb	vmswap_kb	rssanon_kb	rssfile_kb	threads	fds	pss_kb	private_dirty_kb	private_clean_kb	shared_dirty_kb	shared_clean_kb	psi_some_avg10	psi_full_avg10	zram_mem_bytes" > "$TSV"

threshold160=0
threshold120=0
threshold80=0

value()
{
    awk -v k="$1" '$1 == k":" {print $2; exit}' "$2" 2>/dev/null
}

snapshot()
{
    tag="$1"
    dir="$OUT/snapshot-$tag"
    mkdir -p "$dir" 2>/dev/null || return

    date > "$dir/date.txt" 2>/dev/null
    cat /proc/meminfo > "$dir/meminfo.txt" 2>/dev/null
    cat /proc/swaps > "$dir/swaps.txt" 2>/dev/null
    cat /proc/pressure/memory > "$dir/pressure-memory.txt" 2>/dev/null

    cat "/proc/$PID/status" \
        > "$dir/openmw-status.txt" 2>/dev/null

    cat "/proc/$PID/smaps_rollup" \
        > "$dir/openmw-smaps-rollup.txt" 2>/dev/null

    cat "/proc/$PID/limits" \
        > "$dir/openmw-limits.txt" 2>/dev/null

    if [ -d "/proc/$PID/fd" ]; then
        ls "/proc/$PID/fd" 2>/dev/null \
            > "$dir/openmw-fds.txt"
    fi

    if [ -d "/proc/$PID/task" ]; then
        for t in /proc/"$PID"/task/*; do
            [ -r "$t/status" ] || continue
            {
                echo "===== $t ====="
                grep -E \
                    '^(Name|Pid|Tgid|State|VmRSS|VmSize|VmData|VmSwap|Threads):' \
                    "$t/status" 2>/dev/null
            } >> "$dir/threads.txt"
        done
    fi

    for z in /sys/block/zram*; do
        [ -d "$z" ] || continue

        zn="$(basename "$z")"

        {
            echo "===== $zn ====="
            cat "$z/mm_stat" 2>/dev/null
            cat "$z/stat" 2>/dev/null
        } > "$dir/$zn.txt"
    done

    if [ -r /sys/kernel/debug/dma_buf/bufinfo ]; then
        cat /sys/kernel/debug/dma_buf/bufinfo \
            > "$dir/dma-buf.txt" 2>/dev/null
    fi

    CACHE="/mnt/SDCARD/data/ports/openmw/savegame/tsp-localmap-cache-v7"

    if [ -d "$CACHE" ]; then
        {
            echo -n "files="
            find "$CACHE" -type f 2>/dev/null | wc -l
            du -sk "$CACHE" 2>/dev/null
        } > "$dir/localmap-cache.txt"
    fi

    echo "snapshot=$tag date=$(date)" >> "$EVENTS"
}

while kill -0 "$PID" 2>/dev/null
do
    MEM="/proc/meminfo"
    STATUS="/proc/$PID/status"
    ROLL="/proc/$PID/smaps_rollup"

    [ -r "$STATUS" ] || break

    epoch="$(date +%s)"

    memavail="$(value MemAvailable "$MEM")"
    memfree="$(value MemFree "$MEM")"
    cached="$(value Cached "$MEM")"
    buffers="$(value Buffers "$MEM")"
    slab="$(value Slab "$MEM")"
    sreclaim="$(value SReclaimable "$MEM")"
    shmem="$(value Shmem "$MEM")"
    swaptotal="$(value SwapTotal "$MEM")"
    swapfree="$(value SwapFree "$MEM")"

    vmrss="$(value VmRSS "$STATUS")"
    vmsize="$(value VmSize "$STATUS")"
    vmdata="$(value VmData "$STATUS")"
    vmswap="$(value VmSwap "$STATUS")"
    rssanon="$(value RssAnon "$STATUS")"
    rssfile="$(value RssFile "$STATUS")"
    threads="$(value Threads "$STATUS")"

    fds=0
    if [ -d "/proc/$PID/fd" ]; then
        fds="$(ls "/proc/$PID/fd" 2>/dev/null | wc -l)"
    fi

    pss=""
    pdirty=""
    pclean=""
    sdirty=""
    sclean=""

    if [ -r "$ROLL" ]; then
        pss="$(value Pss "$ROLL")"
        pdirty="$(value Private_Dirty "$ROLL")"
        pclean="$(value Private_Clean "$ROLL")"
        sdirty="$(value Shared_Dirty "$ROLL")"
        sclean="$(value Shared_Clean "$ROLL")"
    fi

    psi_some=""
    psi_full=""

    if [ -r /proc/pressure/memory ]; then
        psi_some="$(
            awk '/^some / {
                for(i=1;i<=NF;i++)
                    if($i ~ /^avg10=/) {
                        sub("avg10=","",$i)
                        print $i
                    }
            }' /proc/pressure/memory
        )"

        psi_full="$(
            awk '/^full / {
                for(i=1;i<=NF;i++)
                    if($i ~ /^avg10=/) {
                        sub("avg10=","",$i)
                        print $i
                    }
            }' /proc/pressure/memory
        )"
    fi

    zram_mem=0

    for z in /sys/block/zram*/mm_stat; do
        [ -r "$z" ] || continue
        n="$(awk '{print $3}' "$z" 2>/dev/null)"
        case "$n" in
            ''|*[!0-9]*) ;;
            *) zram_mem=$((zram_mem + n)) ;;
        esac
    done

    echo "$epoch	${memavail:-0}	${memfree:-0}	${cached:-0}	${buffers:-0}	${slab:-0}	${sreclaim:-0}	${shmem:-0}	${swaptotal:-0}	${swapfree:-0}	${vmrss:-0}	${vmsize:-0}	${vmdata:-0}	${vmswap:-0}	${rssanon:-0}	${rssfile:-0}	${threads:-0}	$fds	${pss:-0}	${pdirty:-0}	${pclean:-0}	${sdirty:-0}	${sclean:-0}	${psi_some:-0}	${psi_full:-0}	$zram_mem" >> "$TSV"

    ma="${memavail:-999999}"

    if [ "$ma" -lt 163840 ] && [ "$threshold160" -eq 0 ]; then
        threshold160=1
        snapshot "160mb"
    fi

    if [ "$ma" -lt 122880 ] && [ "$threshold120" -eq 0 ]; then
        threshold120=1
        snapshot "120mb"
    fi

    if [ "$ma" -lt 81920 ] && [ "$threshold80" -eq 0 ]; then
        threshold80=1
        snapshot "80mb"
    fi

    if [ "$ma" -lt 81920 ]; then
        sleep 2
    elif [ "$ma" -lt 163840 ]; then
        sleep 5
    else
        sleep 10
    fi
done

{
    echo "TSP_MEMWATCH_V1 final"
    echo "date=$(date)"
    echo "pid=$PID"
    echo
    echo "===== MEMINFO ====="
    cat /proc/meminfo 2>/dev/null
    echo
    echo "===== SWAPS ====="
    cat /proc/swaps 2>/dev/null
    echo
    echo "===== MEMORY PRESSURE ====="
    cat /proc/pressure/memory 2>/dev/null
} > "$FINAL"

echo "TSP_MEMWATCH_V1 stop pid=$PID date=$(date)" >> "$EVENTS"

exit 0
MEMWATCH

chmod +x "$OUT/tsp_memwatch_v1.sh"

echo
echo "===== COMPLETE ====="
echo
echo "Built OpenMW:"
echo "  $OUT/openmw-0.51-tsp-memory-diag-v1"
echo
echo "Runtime monitor:"
echo "  $OUT/tsp_memwatch_v1.sh"
echo
echo "Patched source:"
echo "  $OUT/localmap.cpp.tsp-memory-diag-v1"
echo
echo "Build log:"
echo "  $BUILDLOG"
echo
echo "Hashes:"
echo "  $OUT/tsp-memory-diag-v1-SHA256.txt"
echo
echo "Source backup:"
echo "  $BACKUP"
echo
echo "NO TSP FILES WERE CHANGED."
