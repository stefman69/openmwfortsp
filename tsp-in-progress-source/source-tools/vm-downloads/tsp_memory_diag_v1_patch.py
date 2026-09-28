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
