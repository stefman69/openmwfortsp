#include <cstdlib>
#include "localmap.hpp"

#include <cstdint>

#include <osg/ComputeBoundsVisitor>
#include <osg/Fog>
#include <osg/LightModel>
#include <osg/LightSource>
#include <osg/PolygonMode>
#include <osg/Texture2D>
#include <cstdio>
#include <filesystem>
#include <fstream>

#include <osg/Camera>
#include <osg/GL>
#include <osg/Image>

#include <algorithm>
#include <cstddef>
#include <cstring>
#include <vector>

#include <osgDB/ReadFile>

#include <components/debug/debuglog.hpp>
#include <components/esm3/fogstate.hpp>
#include <components/esm3/loadcell.hpp>
#include <components/files/memorystream.hpp>
#include <components/misc/constants.hpp>
#include <components/sceneutil/depth.hpp>
#include <components/sceneutil/lightmanager.hpp>
#include <components/sceneutil/nodecallback.hpp>
#include <components/sceneutil/rtt.hpp>
#include <components/sceneutil/shadow.hpp>
#include <components/sceneutil/visitor.hpp>
#include <components/settings/values.hpp>
#include <components/stereo/multiview.hpp>

#include "../mwbase/environment.hpp"
#include "../mwbase/windowmanager.hpp"

#include "../mwworld/cellstore.hpp"

#include "util.hpp"
#include "vismask.hpp"

namespace
{
    // TSP_LOCALMAP_CPU_PIPE_V78
    //
    // Actual TSP local-map replacement pipeline:
    //
    // local-map camera
    //       -> default framebuffer
    //       -> manual glReadPixels
    //       -> CPU osg::Image
    //       -> ordinary image-backed Texture2D
    //
    // MapSegment never exposes RTTNode's GPU-copy texture when enabled.
    bool tspLocalMapCpuPipeEnabled()
    {
        const char* value = std::getenv(
            "TSP_LOCALMAP_CPU_PIPE");

        return value != nullptr
            && value[0] == '1'
            && value[1] == '\0';
    }

    const char* tspLocalMapGlErrorName(GLenum error)
    {
        switch (error)
        {
            case GL_NO_ERROR:
                return "GL_NO_ERROR";

            case GL_INVALID_ENUM:
                return "GL_INVALID_ENUM";

            case GL_INVALID_VALUE:
                return "GL_INVALID_VALUE";

            case GL_INVALID_OPERATION:
                return "GL_INVALID_OPERATION";

            case GL_OUT_OF_MEMORY:
                return "GL_OUT_OF_MEMORY";

#ifdef GL_INVALID_FRAMEBUFFER_OPERATION
            case GL_INVALID_FRAMEBUFFER_OPERATION:
                return "GL_INVALID_FRAMEBUFFER_OPERATION";
#endif

            default:
                return "UNKNOWN_GL_ERROR";
        }
    }

    float square(float val)
    {
        return val * val;
    }

    // TSP_MAPLIFE_V2
    static unsigned long tspMapLifeGeneration = 0;

    static bool tspMapLifeEnabled()
    {
        return std::getenv("TSP_MAPLIFE") != nullptr
            || std::getenv("TSP_GMAP_DUMP") != nullptr;
    }

    std::pair<int, int> divideIntoSegments(const osg::BoundingBox& bounds, int mapSize)
    {
        osg::Vec2f min(bounds.xMin(), bounds.yMin());
        osg::Vec2f max(bounds.xMax(), bounds.yMax());
        osg::Vec2f length = max - min;
        const int segsX = static_cast<int>(std::ceil(length.x() / mapSize));
        const int segsY = static_cast<int>(std::ceil(length.y() / mapSize));
        return { segsX, segsY };
    }
}

namespace MWRender
{

    // TSP_LOCALMAP_PERSIST_V7
    //
    // Persistent local-map colour tiles.
    //
    // OpenMW normally serializes fog-of-war state, but not the
    // generated local-map colour texture. On the TSP that means
    // a corrected runtime tile can be thrown away during reload
    // and regenerated from the broken graphics path.
    //
    // These sidecar files preserve ONLY the underlying map image.
    // Fog/exploration visibility remains controlled by the savegame.
    static const char* tspLocalMapV7CacheRoot()
    {
        const char* env
            = std::getenv("TSP_LOCALMAP_CACHE_DIR");

        if (env != nullptr && env[0] != '\0')
            return env;

        return
            "/mnt/SDCARD/data/ports/openmw/"
            "savegame/tsp-localmap-cache-v7";
    }


    static std::uint64_t tspLocalMapV7Hash(
        const unsigned char* data,
        std::size_t bytes)
    {
        std::uint64_t h
            = 1469598103934665603ULL;

        for (std::size_t i = 0; i < bytes; ++i)
        {
            h ^= static_cast<std::uint64_t>(
                data[i]);

            h *= 1099511628211ULL;
        }

        return h;
    }


    static bool tspLocalMapV7PixelBlack(
        const unsigned char* p)
    {
        return
            p[0] <= 5
            && p[1] <= 5
            && p[2] <= 5;
    }


    static std::string tspLocalMapV7Path(
        int x,
        int y,
        int resolution)
    {
        std::filesystem::path root(
            tspLocalMapV7CacheRoot());

        const std::string name
            = "exterior_"
            + std::to_string(x)
            + "_"
            + std::to_string(y)
            + "_"
            + std::to_string(resolution)
            + ".rgba";

        return (root / name).string();
    }


    static osg::ref_ptr<osg::Texture2D>
    tspLocalMapV7Load(
        int x,
        int y,
        int resolution)
    {
        const std::string path
            = tspLocalMapV7Path(
                x,
                y,
                resolution);

        std::ifstream in(
            path,
            std::ios::binary);

        if (!in)
            return nullptr;

        char magic[8]{};

        std::uint32_t version = 0;
        std::int32_t storedX = 0;
        std::int32_t storedY = 0;
        std::uint32_t storedRes = 0;
        std::uint64_t storedHash = 0;

        in.read(
            magic,
            sizeof(magic));

        in.read(
            reinterpret_cast<char*>(&version),
            sizeof(version));

        in.read(
            reinterpret_cast<char*>(&storedX),
            sizeof(storedX));

        in.read(
            reinterpret_cast<char*>(&storedY),
            sizeof(storedY));

        in.read(
            reinterpret_cast<char*>(&storedRes),
            sizeof(storedRes));

        in.read(
            reinterpret_cast<char*>(&storedHash),
            sizeof(storedHash));

        const char expectedMagic[8]
            = { 'T', 'S', 'P', 'L',
                'M', 'V', '7', '\0' };

        if (!in
            || std::memcmp(
                   magic,
                   expectedMagic,
                   sizeof(magic))
                != 0
            || version != 1
            || storedX != x
            || storedY != y
            || storedRes
                != static_cast<std::uint32_t>(
                    resolution))
        {
            Log(Debug::Warning)
                << "TSP_LOCALMAP_PERSIST_V7 "
                   "CACHE_LOAD_REJECT"
                << " cell=" << x << "," << y
                << " path=" << path;

            return nullptr;
        }

        const std::size_t bytes
            = static_cast<std::size_t>(
                  resolution)
            * static_cast<std::size_t>(
                  resolution)
            * 4;

        osg::ref_ptr<osg::Image> image
            = new osg::Image;

        image->allocateImage(
            resolution,
            resolution,
            1,
            GL_RGBA,
            GL_UNSIGNED_BYTE,
            1);

        in.read(
            reinterpret_cast<char*>(
                image->data()),
            static_cast<std::streamsize>(
                bytes));

        if (!in)
        {
            Log(Debug::Warning)
                << "TSP_LOCALMAP_PERSIST_V7 "
                   "CACHE_LOAD_FAIL"
                << " cell=" << x << "," << y
                << " reason=short-read";

            return nullptr;
        }

        const std::uint64_t actualHash
            = tspLocalMapV7Hash(
                image->data(),
                bytes);

        if (actualHash != storedHash)
        {
            Log(Debug::Warning)
                << "TSP_LOCALMAP_PERSIST_V7 "
                   "CACHE_LOAD_FAIL"
                << " cell=" << x << "," << y
                << " reason=hash-mismatch";

            return nullptr;
        }

        osg::ref_ptr<osg::Texture2D> texture
            = new osg::Texture2D;

        texture->setImage(
            image.get());

        texture->setTextureSize(
            resolution,
            resolution);

        texture->setInternalFormat(
            GL_RGBA);

        texture->setSourceFormat(
            GL_RGBA);

        texture->setSourceType(
            GL_UNSIGNED_BYTE);

        texture->setFilter(
            osg::Texture::MIN_FILTER,
            osg::Texture::LINEAR);

        texture->setFilter(
            osg::Texture::MAG_FILTER,
            osg::Texture::LINEAR);

        texture->setWrap(
            osg::Texture::WRAP_S,
            osg::Texture::CLAMP_TO_EDGE);

        texture->setWrap(
            osg::Texture::WRAP_T,
            osg::Texture::CLAMP_TO_EDGE);

        texture->setUnRefImageDataAfterApply(
            false);

        std::size_t black = 0;

        for (std::size_t i = 0;
             i < bytes / 4;
             ++i)
        {
            if (tspLocalMapV7PixelBlack(
                    image->data() + i * 4))
            {
                ++black;
            }
        }

        Log(Debug::Warning)
            << "TSP_LOCALMAP_PERSIST_V7 "
               "CACHE_LOAD_PASS"
            << " cell=" << x << "," << y
            << " res=" << resolution
            << " black=" << black
            << "/" << (bytes / 4)
            << " hash=" << actualHash;

        return texture;
    }


    static bool tspLocalMapV7Save(
        int x,
        int y,
        int resolution,
        osg::Texture2D* texture)
    {
        if (texture == nullptr)
            return false;

        osg::Image* image
            = texture->getImage();

        if (image == nullptr
            || image->data() == nullptr)
        {
            return false;
        }

        if (image->s() != resolution
            || image->t() != resolution
            || image->getPixelFormat()
                != GL_RGBA
            || image->getDataType()
                != GL_UNSIGNED_BYTE)
        {
            Log(Debug::Warning)
                << "TSP_LOCALMAP_PERSIST_V7 "
                   "CACHE_SAVE_SKIP"
                << " cell=" << x << "," << y
                << " reason=image-format"
                << " image="
                << image->s()
                << "x"
                << image->t()
                << " format=0x"
                << std::hex
                << image->getPixelFormat()
                << " type=0x"
                << image->getDataType()
                << std::dec;

            return false;
        }

        const std::size_t bytes
            = static_cast<std::size_t>(
                  resolution)
            * static_cast<std::size_t>(
                  resolution)
            * 4;

        const std::uint64_t hash
            = tspLocalMapV7Hash(
                image->data(),
                bytes);

        const std::string path
            = tspLocalMapV7Path(
                x,
                y,
                resolution);

        /*
         * Avoid rewriting the SD card if this exact best tile is
         * already persistent.
         */
        {
            std::ifstream existing(
                path,
                std::ios::binary);

            if (existing)
            {
                char magic[8]{};

                std::uint32_t version = 0;
                std::int32_t oldX = 0;
                std::int32_t oldY = 0;
                std::uint32_t oldRes = 0;
                std::uint64_t oldHash = 0;

                existing.read(
                    magic,
                    sizeof(magic));

                existing.read(
                    reinterpret_cast<char*>(
                        &version),
                    sizeof(version));

                existing.read(
                    reinterpret_cast<char*>(
                        &oldX),
                    sizeof(oldX));

                existing.read(
                    reinterpret_cast<char*>(
                        &oldY),
                    sizeof(oldY));

                existing.read(
                    reinterpret_cast<char*>(
                        &oldRes),
                    sizeof(oldRes));

                existing.read(
                    reinterpret_cast<char*>(
                        &oldHash),
                    sizeof(oldHash));

                if (existing
                    && version == 1
                    && oldX == x
                    && oldY == y
                    && oldRes
                        == static_cast<
                            std::uint32_t>(
                                resolution)
                    && oldHash == hash)
                {
                    return true;
                }
            }
        }

        std::error_code ec;

        std::filesystem::create_directories(
            tspLocalMapV7CacheRoot(),
            ec);

        if (ec)
        {
            Log(Debug::Warning)
                << "TSP_LOCALMAP_PERSIST_V7 "
                   "CACHE_SAVE_FAIL"
                << " cell=" << x << "," << y
                << " reason=mkdir"
                << " error=" << ec.message();

            return false;
        }

        const std::string tmp
            = path + ".tmp";

        std::ofstream out(
            tmp,
            std::ios::binary
                | std::ios::trunc);

        if (!out)
        {
            Log(Debug::Warning)
                << "TSP_LOCALMAP_PERSIST_V7 "
                   "CACHE_SAVE_FAIL"
                << " cell=" << x << "," << y
                << " reason=open";

            return false;
        }

        const char magic[8]
            = { 'T', 'S', 'P', 'L',
                'M', 'V', '7', '\0' };

        const std::uint32_t version = 1;

        const std::int32_t storedX = x;
        const std::int32_t storedY = y;

        const std::uint32_t storedRes
            = static_cast<std::uint32_t>(
                resolution);

        out.write(
            magic,
            sizeof(magic));

        out.write(
            reinterpret_cast<const char*>(
                &version),
            sizeof(version));

        out.write(
            reinterpret_cast<const char*>(
                &storedX),
            sizeof(storedX));

        out.write(
            reinterpret_cast<const char*>(
                &storedY),
            sizeof(storedY));

        out.write(
            reinterpret_cast<const char*>(
                &storedRes),
            sizeof(storedRes));

        out.write(
            reinterpret_cast<const char*>(
                &hash),
            sizeof(hash));

        out.write(
            reinterpret_cast<const char*>(
                image->data()),
            static_cast<std::streamsize>(
                bytes));

        out.close();

        if (!out)
        {
            std::remove(
                tmp.c_str());

            Log(Debug::Warning)
                << "TSP_LOCALMAP_PERSIST_V7 "
                   "CACHE_SAVE_FAIL"
                << " cell=" << x << "," << y
                << " reason=write";

            return false;
        }

        if (std::rename(
                tmp.c_str(),
                path.c_str())
            != 0)
        {
            std::remove(
                path.c_str());

            if (std::rename(
                    tmp.c_str(),
                    path.c_str())
                != 0)
            {
                std::remove(
                    tmp.c_str());

                Log(Debug::Warning)
                    << "TSP_LOCALMAP_PERSIST_V7 "
                       "CACHE_SAVE_FAIL"
                    << " cell="
                    << x << "," << y
                    << " reason=rename";

                return false;
            }
        }

        std::size_t black = 0;

        for (std::size_t i = 0;
             i < bytes / 4;
             ++i)
        {
            if (tspLocalMapV7PixelBlack(
                    image->data() + i * 4))
            {
                ++black;
            }
        }

        Log(Debug::Warning)
            << "TSP_LOCALMAP_PERSIST_V7 "
               "CACHE_SAVE_PASS"
            << " cell=" << x << "," << y
            << " black=" << black
            << "/" << (bytes / 4)
            << " bytes=" << bytes
            << " hash=" << hash;

        return true;
    }


    class LocalMapRenderToTexture : public SceneUtil::RTTNode
    {
    public:
        LocalMapRenderToTexture(osg::Node* sceneRoot, int res, int mapWorldSize, float x, float y,
            const osg::Vec3d& upVector, float zmin, float zmax, osg::Texture2D* reuseColorTexture);

        void setDefaults(osg::Camera* camera) override;

        osg::Texture2D* getMapTextureForSegment();

        void captureCpuFramebuffer();

        osg::ref_ptr<osg::Image> mTspCpuImage;
        osg::ref_ptr<osg::Texture2D> mTspCpuTexture;

        std::vector<unsigned char> mTspReadbackBuffer;

        unsigned int mTspCaptureSequence = 0;

        // TSP_LOCALMAP_PERSIST_V7
        std::size_t mTspFusedBlackPixels
            = static_cast<std::size_t>(-1);

        bool mTspCpuInitialized = false;

        osg::Node* mSceneRoot;
        osg::ref_ptr<osg::Texture2D> mReuseColorTexture;
        osg::Matrix mProjectionMatrix;
        osg::Matrix mViewMatrix;
        bool mActive;
    };

    class CameraLocalUpdateCallback
        : public SceneUtil::NodeCallback<CameraLocalUpdateCallback, LocalMapRenderToTexture*>
    {
    public:
        void operator()(LocalMapRenderToTexture* node, osg::NodeVisitor* nv);
    };

    class TspLocalMapCpuCaptureCallback final
        : public osg::Camera::DrawCallback
    {
    public:
        explicit TspLocalMapCpuCaptureCallback(
            LocalMapRenderToTexture* owner)
            : mOwner(owner)
        {
        }

        void operator()(osg::RenderInfo&) const override
        {
            if (mOwner != nullptr)
                mOwner->captureCpuFramebuffer();
        }

    private:
        LocalMapRenderToTexture* mOwner;
    };

    LocalMap::LocalMap(osg::Group* root)
        : mRoot(root)
        , mMapResolution(static_cast<int>(
              Settings::map().mLocalMapResolution * MWBase::Environment::get().getWindowManager()->getScalingFactor()))
        , mMapWorldSize(Constants::CellSizeInUnits)
        , mCellDistance(Constants::CellGridRadius)
        , mAngle(0.f)
        , mInterior(false)
    {
        /*
         * TSP_LOCALMAP_PERSIST_V7
         *
         * V7 makes OpenMW's existing CPU-backed local-map texture
         * authoritative. Keep GL4ES's V6 CPU interception available
         * for diagnostics, but do not pay for both readback systems
         * in normal gameplay.
         */
        if (std::getenv(
                "TSP_LOCALMAP_CPU_PIPE")
            == nullptr)
        {
            ::setenv(
                "TSP_LOCALMAP_CPU_PIPE",
                "1",
                0);
        }

        if (std::getenv(
                "LIBGL_TSP_LOCALMAP_CPUCOPY")
            == nullptr)
        {
            ::setenv(
                "LIBGL_TSP_LOCALMAP_CPUCOPY",
                "0",
                0);
        }

        Log(Debug::Warning)
            << "TSP_LOCALMAP_PERSIST_V7 ARMED"
            << " cpu_texture=AUTHORITATIVE"
            << " persistent_cache="
            << tspLocalMapV7CacheRoot()
            << " adaptive_hold=3..8"
            << " duplicate_gl4es_cpu="
            << (std::getenv(
                    "LIBGL_TSP_LOCALMAP_CPUCOPY")
                    ? std::getenv(
                        "LIBGL_TSP_LOCALMAP_CPUCOPY")
                    : "unset");

        SceneUtil::FindByNameVisitor find("Scene Root");
        mRoot->accept(find);
        mSceneRoot = find.mFoundNode;
        if (!mSceneRoot)
            throw std::runtime_error("no scene root found");

        Log(Debug::Warning)
            << "TSP_LOCALMAP_BROAD_V6 ARMED"
            << " resident_refresh=1"
            << " texture_reuse=1"
            << " request_rerender=1"
            << " hold_default=8";
    }

    LocalMap::~LocalMap()
    {
        std::size_t tspV7ShutdownSaved = 0;

        for (const auto& [coords, segment]
             : mExteriorSegments)
        {
            if (tspLocalMapV7Save(
                    coords.first,
                    coords.second,
                    mMapResolution,
                    segment.mMapTexture.get()))
            {
                ++tspV7ShutdownSaved;
            }
        }

        Log(Debug::Warning)
            << "TSP_LOCALMAP_PERSIST_V7 "
               "SHUTDOWN_FLUSH"
            << " tiles="
            << tspV7ShutdownSaved;

        if (tspMapLifeEnabled())
        {
            Log(Debug::Warning)
                << "TSP_MAPLIFE_V2 phase=destruct"
                << " gen=" << tspMapLifeGeneration
                << " ext=" << mExteriorSegments.size()
                << " interior=" << mInteriorSegments.size()
                << " rtt=" << mLocalMapRTTs.size();
        }

        for (auto& rtt : mLocalMapRTTs)
            mRoot->removeChild(rtt);
    }

    const osg::Vec2f LocalMap::rotatePoint(const osg::Vec2f& point, const osg::Vec2f& center, const float angle) const
    {
        return osg::Vec2f(
            std::cos(angle) * (point.x() - center.x()) - std::sin(angle) * (point.y() - center.y()) + center.x(),
            std::sin(angle) * (point.x() - center.x()) + std::cos(angle) * (point.y() - center.y()) + center.y());
    }

    void LocalMap::clear()
    {
        ++tspMapLifeGeneration;
        const std::size_t tspRttBefore = mLocalMapRTTs.size();

        if (tspMapLifeEnabled())
        {
            Log(Debug::Warning)
                << "TSP_MAPLIFE_V2 phase=clear_begin"
                << " gen=" << tspMapLifeGeneration
                << " ext=" << mExteriorSegments.size()
                << " interior=" << mInteriorSegments.size()
                << " rtt=" << tspRttBefore;
        }

        // TSP_LOCALMAP_CAMERA_DRAIN_V13
        // A save-load clear is a hard lifetime boundary for one-shot PRE_RENDER
        // local-map RTT cameras. Do not leave them attached until a later GUI frame.
        for (auto& rtt : mLocalMapRTTs)
        {
            if (rtt)
            {
                rtt->setNodeMask(0);
                mRoot->removeChild(rtt);
            }
        }
        mLocalMapRTTs.clear();

        std::size_t tspV7Flushed = 0;

        for (const auto& [coords, segment]
             : mExteriorSegments)
        {
            if (tspLocalMapV7Save(
                    coords.first,
                    coords.second,
                    mMapResolution,
                    segment.mMapTexture.get()))
            {
                ++tspV7Flushed;
            }
        }

        Log(Debug::Warning)
            << "TSP_LOCALMAP_PERSIST_V7 "
               "CACHE_FLUSH_BEFORE_CLEAR"
            << " tiles="
            << tspV7Flushed;

        mExteriorSegments.clear();
        mInteriorSegments.clear();

        if (tspMapLifeEnabled())
        {
            Log(Debug::Warning)
                << "TSP_LOCALMAP_CAMERA_DRAIN_V13"
                << " gen=" << tspMapLifeGeneration
                << " drained=" << tspRttBefore
                << " remaining=" << mLocalMapRTTs.size();

            Log(Debug::Warning)
                << "TSP_MAPLIFE_V2 phase=clear_end"
                << " gen=" << tspMapLifeGeneration
                << " ext=" << mExteriorSegments.size()
                << " interior=" << mInteriorSegments.size()
                << " rtt=" << mLocalMapRTTs.size();
        }
    }

    void LocalMap::saveFogOfWar(MWWorld::CellStore* cell) const
    {
        if (!mInterior)
        {
            const auto it
                = mExteriorSegments.find(std::make_pair(cell->getCell()->getGridX(), cell->getCell()->getGridY()));
            if (it == mExteriorSegments.end())
                return;
            const MapSegment& segment = it->second;

            // TSP_LOCALMAP_PERSIST_V7
            // Persist the best CPU-backed colour tile at the same
            // point OpenMW persists this exterior cell's fog state.
            tspLocalMapV7Save(
                cell->getCell()->getGridX(),
                cell->getCell()->getGridY(),
                mMapResolution,
                segment.mMapTexture.get());

            if (segment.mFogOfWarImage && segment.mHasFogState)
            {
                auto fog = std::make_unique<ESM::FogState>();
                fog->mFogTextures.emplace_back();

                segment.saveFogOfWar(fog->mFogTextures.back());

                cell->setFog(std::move(fog));
            }
        }
        else
        {
            auto segments = divideIntoSegments(mBounds, mMapWorldSize);

            auto fog = std::make_unique<ESM::FogState>();

            fog->mBounds.mMinX = mBounds.xMin();
            fog->mBounds.mMaxX = mBounds.xMax();
            fog->mBounds.mMinY = mBounds.yMin();
            fog->mBounds.mMaxY = mBounds.yMax();
            fog->mNorthMarkerAngle = mAngle;
            fog->mCenterX = mCenter.x();
            fog->mCenterY = mCenter.y();

            fog->mFogTextures.reserve(segments.first * segments.second);

            for (int x = 0; x < segments.first; ++x)
            {
                for (int y = 0; y < segments.second; ++y)
                {
                    const auto it = mInteriorSegments.find(std::make_pair(x, y));
                    if (it == mInteriorSegments.end())
                        continue;
                    const MapSegment& segment = it->second;
                    if (!segment.mHasFogState)
                        continue;
                    ESM::FogTexture& texture = fog->mFogTextures.emplace_back();
                    segment.saveFogOfWar(texture);
                    texture.mX = x;
                    texture.mY = y;
                }
            }

            cell->setFog(std::move(fog));
        }
    }


    void LocalMap::setupRenderToTexture(
        int segmentX,
        int segmentY,
        float left,
        float top,
        const osg::Vec3d& upVector,
        float zmin,
        float zmax)
    {
        MapSegment& segment
            = mInterior
            ? mInteriorSegments[
                std::make_pair(
                    segmentX,
                    segmentY)]
            : mExteriorSegments[
                std::make_pair(
                    segmentX,
                    segmentY)];

        osg::ref_ptr<osg::Texture2D>
            previousTexture
                = segment.mMapTexture;

        /*
         * Pass nullptr as the old RTT attachment.
         *
         * The previous CPU map is seeded manually below. This
         * prevents V6's experimental reuse attachment from putting
         * the display texture back into OSG's framebuffer-copy path.
         */
        mLocalMapRTTs.emplace_back(
            new LocalMapRenderToTexture(
                mSceneRoot,
                mMapResolution,
                mMapWorldSize,
                left,
                top,
                upVector,
                zmin,
                zmax,
                nullptr));

        LocalMapRenderToTexture* rtt
            = mLocalMapRTTs.back().get();

        mRoot->addChild(rtt);

        bool seeded = false;

        if (previousTexture
            && previousTexture->getImage()
            && rtt->mTspCpuImage
            && previousTexture->getImage()->s()
                == rtt->mTspCpuImage->s()
            && previousTexture->getImage()->t()
                == rtt->mTspCpuImage->t()
            && previousTexture->getImage()
                   ->getPixelFormat()
                == GL_RGBA
            && previousTexture->getImage()
                   ->getDataType()
                == GL_UNSIGNED_BYTE)
        {
            const std::size_t bytes
                = static_cast<std::size_t>(
                      rtt->mTspCpuImage->s())
                * static_cast<std::size_t>(
                      rtt->mTspCpuImage->t())
                * 4;

            std::memcpy(
                rtt->mTspCpuImage->data(),
                previousTexture->getImage()
                    ->data(),
                bytes);

            rtt->mTspCpuInitialized = true;

            std::size_t black = 0;

            for (std::size_t i = 0;
                 i < bytes / 4;
                 ++i)
            {
                if (tspLocalMapV7PixelBlack(
                        rtt->mTspCpuImage
                            ->data()
                        + i * 4))
                {
                    ++black;
                }
            }

            rtt->mTspFusedBlackPixels
                = black;

            rtt->mTspCpuImage->dirty();

            seeded = true;
        }

        /*
         * THIS is the key V7 wiring correction.
         */
        segment.mMapTexture
            = rtt->getMapTextureForSegment();

        Log(Debug::Warning)
            << "TSP_LOCALMAP_PERSIST_V7 "
               "RTT_CREATED"
            << " segment="
            << segmentX
            << ","
            << segmentY
            << " seeded="
            << (seeded ? 1 : 0)
            << " cpu_texture="
            << (rtt->mTspCpuTexture ? 1 : 0)
            << " authoritative=CPU";
    }


    void LocalMap::requestMap(
        const MWWorld::CellStore* cell)
    {
        if (!cell->isExterior())
        {
            requestInteriorMap(cell);
            return;
        }

        const int cellX
            = cell->getCell()->getGridX();

        const int cellY
            = cell->getCell()->getGridY();

        MapSegment& segment
            = mExteriorSegments[
                std::make_pair(
                    cellX,
                    cellY)];

        if (!segment.mMapTexture)
        {
            segment.mMapTexture
                = tspLocalMapV7Load(
                    cellX,
                    cellY,
                    mMapResolution);

            if (segment.mMapTexture)
            {
                Log(Debug::Warning)
                    << "TSP_LOCALMAP_PERSIST_V7 "
                       "RESTORE_BEFORE_RENDER"
                    << " cell="
                    << cellX
                    << ","
                    << cellY;
            }
        }

        const std::uint8_t neighbourFlags
            = getExteriorNeighbourFlags(
                cellX,
                cellY);

        const bool cachedAndSameNeighbours
            = segment.mMapTexture
            && segment.mLastRenderNeighbourFlags
                != 0
            && (segment
                    .mLastRenderNeighbourFlags
                & neighbourFlags)
                == neighbourFlags;

        if (cachedAndSameNeighbours)
        {
            Log(Debug::Warning)
                << "TSP_LOCALMAP_PERSIST_V7 "
                   "CACHE_HIT_SKIP_RENDER"
                << " cell="
                << cellX
                << ","
                << cellY;

            return;
        }

        Log(Debug::Warning)
            << "TSP_LOCALMAP_PERSIST_V7 "
               "REQUEST_RENDER"
            << " cell="
            << cellX
            << ","
            << cellY
            << " seeded="
            << (segment.mMapTexture ? 1 : 0);

        requestExteriorMap(
            cell,
            segment);

        segment.mLastRenderNeighbourFlags
            = neighbourFlags;
    }


    void LocalMap::addCell(
        MWWorld::CellStore* cell)
    {
        if (!cell->isExterior())
            return;

        const int cellX
            = cell->getCell()->getGridX();

        const int cellY
            = cell->getCell()->getGridY();

        const auto coords
            = std::make_pair(
                cellX,
                cellY);

        auto [it, inserted]
            = mExteriorSegments.emplace(
                coords,
                MapSegment{});

        if (inserted
            && !it->second.mMapTexture)
        {
            it->second.mMapTexture
                = tspLocalMapV7Load(
                    cellX,
                    cellY,
                    mMapResolution);
        }

        if (!inserted
            && it->second.mMapTexture)
        {
            Log(Debug::Warning)
                << "TSP_LOCALMAP_PERSIST_V7 "
                   "RESIDENT_REFRESH_ENTER"
                << " cell="
                << cellX
                << ","
                << cellY;

            requestExteriorMap(
                cell,
                it->second);

            it->second.mLastRenderNeighbourFlags
                = getExteriorNeighbourFlags(
                    cellX,
                    cellY);

            Log(Debug::Warning)
                << "TSP_LOCALMAP_PERSIST_V7 "
                   "RESIDENT_REFRESH_PASS"
                << " cell="
                << cellX
                << ","
                << cellY;
        }
    }

    void LocalMap::removeExteriorCell(int x, int y)
    {
        const auto it = mExteriorSegments.find({ x, y });

        if (tspMapLifeEnabled())
        {
            Log(Debug::Warning)
                << "TSP_MAPLIFE_V2 phase=remove_ext"
                << " gen=" << tspMapLifeGeneration
                << " cell=" << x << "," << y
                << " found=" << (it != mExteriorSegments.end() ? 1 : 0)
                << " maptex="
                << (it != mExteriorSegments.end()
                        && it->second.mMapTexture
                    ? 1 : 0)
                << " fogtex="
                << (it != mExteriorSegments.end()
                        && it->second.mFogOfWarTexture
                    ? 1 : 0)
                << " ext_before=" << mExteriorSegments.size();
        }

        if (it != mExteriorSegments.end())
        {
            tspLocalMapV7Save(
                x,
                y,
                mMapResolution,
                it->second.mMapTexture.get());
        }

        mExteriorSegments.erase({ x, y });
    }

    void LocalMap::removeCell(MWWorld::CellStore* cell)
    {
        saveFogOfWar(cell);

        if (!cell->isExterior())
            mInteriorSegments.clear();
    }

    osg::ref_ptr<osg::Texture2D> LocalMap::getMapTexture(int x, int y)
    {
        auto& segments(mInterior ? mInteriorSegments : mExteriorSegments);
        SegmentMap::iterator found = segments.find(std::make_pair(x, y));
        if (found == segments.end())
            return osg::ref_ptr<osg::Texture2D>();
        else
            return found->second.mMapTexture;
    }

    osg::ref_ptr<osg::Texture2D> LocalMap::getFogOfWarTexture(int x, int y)
    {
        auto& segments(mInterior ? mInteriorSegments : mExteriorSegments);
        SegmentMap::iterator found = segments.find(std::make_pair(x, y));
        if (found == segments.end())
            return osg::ref_ptr<osg::Texture2D>();
        else
            return found->second.mFogOfWarTexture;
    }

    void LocalMap::cleanupCameras()
    {
        const std::size_t before = mLocalMapRTTs.size();
        std::size_t removed = 0;

        auto it = mLocalMapRTTs.begin();

        while (it != mLocalMapRTTs.end())
        {
            if (!(*it)->mActive)
            {
                mRoot->removeChild(*it);
                it = mLocalMapRTTs.erase(it);
                ++removed;
            }
            else
                it++;
        }

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
    }

    void LocalMap::requestExteriorMap(const MWWorld::CellStore* cell, MapSegment& segment)
    {
        mInterior = false;

        const int x = cell->getCell()->getGridX();
        const int y = cell->getCell()->getGridY();

        osg::BoundingSphere bound = mSceneRoot->getBound();
        float zmin = bound.center().z() - bound.radius();
        float zmax = bound.center().z() + bound.radius();

        setupRenderToTexture(x, y, x * mMapWorldSize + mMapWorldSize / 2.f, y * mMapWorldSize + mMapWorldSize / 2.f,
            osg::Vec3d(0, 1, 0), zmin, zmax);

        if (segment.mFogOfWarImage != nullptr)
            return;

        if (cell->getFog() && !cell->getFog()->mFogTextures.empty())
            segment.loadFogOfWar(cell->getFog()->mFogTextures.back());
        else
            segment.initFogOfWar();
    }

    static osg::Vec2f getNorthVector(const MWWorld::CellStore* cell)
    {
        MWWorld::ConstPtr northmarker = cell->searchConst(ESM::RefId::stringRefId("northmarker"));

        if (northmarker.isEmpty())
            return osg::Vec2f(0, 1);

        osg::Quat orient(-northmarker.getRefData().getPosition().rot[2], osg::Vec3f(0, 0, 1));
        osg::Vec3f dir = orient * osg::Vec3f(0, 1, 0);
        osg::Vec2f d(dir.x(), dir.y());
        return d;
    }

    void LocalMap::requestInteriorMap(const MWWorld::CellStore* cell)
    {
        osg::ComputeBoundsVisitor computeBoundsVisitor;
        computeBoundsVisitor.setTraversalMask(Mask_Scene | Mask_Terrain | Mask_Object | Mask_Static);
        mSceneRoot->accept(computeBoundsVisitor);

        osg::BoundingBox bounds = computeBoundsVisitor.getBoundingBox();

        // If we're in an empty cell, bail out
        // The operations in this function are only valid for finite bounds
        if (!bounds.valid() || bounds.radius2() == 0.0)
            return;

        mInterior = true;
        mExteriorSegments.clear();

        mBounds = bounds;

        // Get the cell's NorthMarker rotation. This is used to rotate the entire map.
        osg::Vec2f north = getNorthVector(cell);

        mAngle = std::atan2(north.x(), north.y());

        // Rotate the cell and merge the rotated corners to the bounding box
        osg::Vec2f origCenter(bounds.center().x(), bounds.center().y());
        osg::Vec3f origCorners[8];
        for (int i = 0; i < 8; ++i)
            origCorners[i] = mBounds.corner(i);

        for (int i = 0; i < 8; ++i)
        {
            osg::Vec3f corner = origCorners[i];
            osg::Vec2f corner2d(corner.x(), corner.y());
            corner2d = rotatePoint(corner2d, origCenter, mAngle);
            mBounds.expandBy(osg::Vec3f(corner2d.x(), corner2d.y(), 0));
        }

        // Do NOT change padding! This will break older savegames.
        // If the padding really needs to be changed, then it must be saved in the ESM::FogState and
        // assume the old (500) value as default for older savegames.
        const float padding = 500.0f;

        // Apply a little padding
        mBounds.set(mBounds._min - osg::Vec3f(padding, padding, 0.f), mBounds._max + osg::Vec3f(padding, padding, 0.f));

        float zMin = mBounds.zMin();
        float zMax = mBounds.zMax();
        mCenter = osg::Vec2f(mBounds.center().x(), mBounds.center().y());

        // If there is fog state in the CellStore (e.g. when it came from a savegame) we need to do some checks
        // to see if this state is still valid.
        // Both the cell bounds and the NorthMarker rotation could be changed by the content files or exchanged models.
        // If they changed by too much then parts of the interior might not be covered by the map anymore.
        // The following code detects this, and discards the CellStore's fog state if it needs to.
        int xOffset = 0;
        int yOffset = 0;
        if (const ESM::FogState* fog = cell->getFog())
        {
            if (std::abs(mAngle - fog->mNorthMarkerAngle) < osg::DegreesToRadians(5.f))
            {
                // Expand mBounds so the saved textures fit the same grid
                if (fog->mBounds.mMinX < mBounds.xMin())
                {
                    mBounds.xMin() = fog->mBounds.mMinX;
                }
                else if (fog->mBounds.mMinX > mBounds.xMin())
                {
                    float diff = fog->mBounds.mMinX - mBounds.xMin();
                    xOffset = static_cast<int>(std::ceil(diff / mMapWorldSize));
                    mBounds.xMin() = fog->mBounds.mMinX - xOffset * mMapWorldSize;
                }
                if (fog->mBounds.mMinY < mBounds.yMin())
                {
                    mBounds.yMin() = fog->mBounds.mMinY;
                }
                else if (fog->mBounds.mMinY > mBounds.yMin())
                {
                    float diff = fog->mBounds.mMinY - mBounds.yMin();
                    yOffset = static_cast<int>(std::ceil(diff / mMapWorldSize));
                    mBounds.yMin() = fog->mBounds.mMinY - yOffset * mMapWorldSize;
                }
                if (fog->mBounds.mMaxX > mBounds.xMax())
                    mBounds.xMax() = fog->mBounds.mMaxX;
                if (fog->mBounds.mMaxY > mBounds.yMax())
                    mBounds.yMax() = fog->mBounds.mMaxY;

                if (xOffset != 0 || yOffset != 0)
                    Log(Debug::Warning) << "Warning: expanding fog by " << xOffset << ", " << yOffset;

                mAngle = fog->mNorthMarkerAngle;
                mCenter.x() = fog->mCenterX;
                mCenter.y() = fog->mCenterY;
            }
        }

        osg::Vec2f min(mBounds.xMin(), mBounds.yMin());

        osg::Quat cameraOrient(mAngle, osg::Vec3d(0, 0, -1));

        auto segments = divideIntoSegments(mBounds, mMapWorldSize);
        for (int x = 0; x < segments.first; ++x)
        {
            for (int y = 0; y < segments.second; ++y)
            {
                osg::Vec2f start
                    = min + osg::Vec2f(static_cast<float>(mMapWorldSize * x), static_cast<float>(mMapWorldSize * y));
                osg::Vec2f newcenter = start + osg::Vec2f(mMapWorldSize / 2.f, mMapWorldSize / 2.f);

                osg::Vec2f a = newcenter - mCenter;
                osg::Vec3f rotatedCenter = cameraOrient * (osg::Vec3f(a.x(), a.y(), 0));

                osg::Vec2f pos = osg::Vec2f(rotatedCenter.x(), rotatedCenter.y()) + mCenter;

                setupRenderToTexture(x, y, pos.x(), pos.y(), osg::Vec3f(north.x(), north.y(), 0.f), zMin, zMax);

                auto coords = std::make_pair(x, y);
                MapSegment& segment = mInteriorSegments[coords];
                if (!segment.mFogOfWarImage)
                {
                    bool loaded = false;
                    if (const ESM::FogState* fog = cell->getFog())
                    {
                        auto match = std::find_if(
                            fog->mFogTextures.begin(), fog->mFogTextures.end(), [&](const ESM::FogTexture& texture) {
                                return texture.mX == x - xOffset && texture.mY == y - yOffset;
                            });
                        if (match != fog->mFogTextures.end())
                        {
                            segment.loadFogOfWar(*match);
                            loaded = true;
                        }
                    }
                    if (!loaded)
                        segment.initFogOfWar();
                }
            }
        }
    }

    void LocalMap::worldToInteriorMapPosition(osg::Vec2f pos, float& nX, float& nY, int& x, int& y) const
    {
        pos = rotatePoint(pos, mCenter, mAngle);

        osg::Vec2f min(mBounds.xMin(), mBounds.yMin());

        x = static_cast<int>(std::ceil((pos.x() - min.x()) / mMapWorldSize) - 1);
        y = static_cast<int>(std::ceil((pos.y() - min.y()) / mMapWorldSize) - 1);

        nX = (pos.x() - min.x() - mMapWorldSize * x) / mMapWorldSize;
        nY = 1.0f - (pos.y() - min.y() - mMapWorldSize * y) / mMapWorldSize;
    }

    osg::Vec2f LocalMap::interiorMapToWorldPosition(float nX, float nY, int x, int y) const
    {
        osg::Vec2f min(mBounds.xMin(), mBounds.yMin());
        osg::Vec2f pos(mMapWorldSize * (nX + x) + min.x(), mMapWorldSize * (1.0f - nY + y) + min.y());

        pos = rotatePoint(pos, mCenter, -mAngle);
        return pos;
    }

    bool LocalMap::isPositionExplored(float nX, float nY, int x, int y)
    {
        auto& segments(mInterior ? mInteriorSegments : mExteriorSegments);
        const MapSegment& segment = segments[std::make_pair(x, y)];
        if (!segment.mFogOfWarImage)
            return false;

        nX = std::clamp(nX, 0.f, 1.f);
        nY = std::clamp(nY, 0.f, 1.f);

        int texU = static_cast<int>((sFogOfWarResolution - 1) * nX);
        int texV = static_cast<int>((sFogOfWarResolution - 1) * nY);

        const std::uint32_t clr
            = reinterpret_cast<const uint32_t*>(segment.mFogOfWarImage->data())[texV * sFogOfWarResolution + texU];
        uint8_t alpha = (clr >> 24);
        return alpha < 200;
    }

    osg::Group* LocalMap::getRoot()
    {
        return mRoot;
    }

    void LocalMap::updatePlayer(const osg::Vec3f& position, const osg::Quat& orientation, float& u, float& v, int& x,
        int& y, osg::Vec3f& direction)
    {
        // retrieve the x,y grid coordinates the player is in
        osg::Vec2f pos(position.x(), position.y());

        if (mInterior)
        {
            worldToInteriorMapPosition(pos, u, v, x, y);

            osg::Quat cameraOrient(mAngle, osg::Vec3(0, 0, -1));
            direction = orientation * cameraOrient.inverse() * osg::Vec3f(0, 1, 0);
        }
        else
        {
            direction = orientation * osg::Vec3f(0, 1, 0);

            x = static_cast<int>(std::ceil(pos.x() / mMapWorldSize) - 1);
            y = static_cast<int>(std::ceil(pos.y() / mMapWorldSize) - 1);

            // convert from world coordinates to texture UV coordinates
            u = std::abs((pos.x() - (mMapWorldSize * x)) / mMapWorldSize);
            v = 1.0f - std::abs((pos.y() - (mMapWorldSize * y)) / mMapWorldSize);
        }

        // explore radius (squared)
        const float exploreRadius = 0.17f * (sFogOfWarResolution - 1); // explore radius from 0 to sFogOfWarResolution-1
        const float sqrExploreRadius = square(exploreRadius);
        const float exploreRadiusUV = exploreRadius / sFogOfWarResolution; // explore radius from 0 to 1 (UV space)

        // change the affected fog of war textures (in a 3x3 grid around the player)
        for (int mx = -mCellDistance; mx <= mCellDistance; ++mx)
        {
            for (int my = -mCellDistance; my <= mCellDistance; ++my)
            {
                // is this texture affected at all?
                bool affected = false;
                if (mx == 0 && my == 0) // the player is always in the center of the 3x3 grid
                    affected = true;
                else
                {
                    bool affectsX = (mx > 0) ? (u + exploreRadiusUV > 1) : (u - exploreRadiusUV < 0);
                    bool affectsY = (my > 0) ? (v + exploreRadiusUV > 1) : (v - exploreRadiusUV < 0);
                    affected = (affectsX && (my == 0)) || (affectsY && mx == 0) || (affectsX && affectsY);
                }

                if (!affected)
                    continue;

                int texX = x + mx;
                int texY = y + my * -1;

                auto& segments(mInterior ? mInteriorSegments : mExteriorSegments);
                MapSegment& segment = segments[std::make_pair(texX, texY)];

                if (!segment.mFogOfWarImage || !segment.mMapTexture)
                    continue;

                std::uint32_t* data = reinterpret_cast<std::uint32_t*>(segment.mFogOfWarImage->data());
                bool changed = false;
                for (int texV = 0; texV < sFogOfWarResolution; ++texV)
                {
                    for (int texU = 0; texU < sFogOfWarResolution; ++texU)
                    {
                        float sqrDist = square((texU + mx * (sFogOfWarResolution - 1)) - u * (sFogOfWarResolution - 1))
                            + square((texV + my * (sFogOfWarResolution - 1)) - v * (sFogOfWarResolution - 1));

                        const std::uint8_t alpha = std::min<std::uint8_t>(*data >> 24,
                            static_cast<std::uint8_t>(std::clamp(sqrDist / sqrExploreRadius, 0.f, 1.f) * 255));
                        std::uint32_t val = static_cast<std::uint32_t>(alpha << 24);
                        if (*data != val)
                        {
                            *data = val;
                            changed = true;
                        }

                        ++data;
                    }
                }

                if (changed)
                {
                    segment.mHasFogState = true;
                    segment.mFogOfWarImage->dirty();
                }
            }
        }
    }

    std::uint8_t LocalMap::getExteriorNeighbourFlags(int cellX, int cellY) const
    {
        constexpr std::tuple<NeighbourCellFlag, int, int> flags[] = {
            { NeighbourCellTopLeft, -1, -1 },
            { NeighbourCellTopCenter, 0, -1 },
            { NeighbourCellTopRight, 1, -1 },
            { NeighbourCellMiddleLeft, -1, 0 },
            { NeighbourCellMiddleRight, 1, 0 },
            { NeighbourCellBottomLeft, -1, 1 },
            { NeighbourCellBottomCenter, 0, 1 },
            { NeighbourCellBottomRight, 1, 1 },
        };
        std::uint8_t result = 0;
        for (const auto& [flag, dx, dy] : flags)
        {
            auto it = mExteriorSegments.find(std::pair(cellX + dx, cellY + dy));
            if (it != mExteriorSegments.end() && it->second.mMapTexture)
                result |= flag;
        }
        return result;
    }

    MyGUI::IntRect LocalMap::getInteriorGrid() const
    {
        auto segments = divideIntoSegments(mBounds, mMapWorldSize);
        return { -1, -1, segments.first, segments.second };
    }

    void LocalMap::MapSegment::createFogOfWarTexture()
    {
        if (mFogOfWarTexture)
            return;
        mFogOfWarTexture = new osg::Texture2D;
        // TODO: synchronize access? for now, the worst that could happen is the draw thread jumping a frame ahead.
        // TSP_FOG_DYNAMIC_V53 - restored. MyGUI's Drawable is reset to STATIC every
        // frame and only promoted to DYNAMIC if a texture it draws reports DYNAMIC
        // (myguirendermanager.cpp begin()/doRender()). With this commented out the
        // GUI drawable stayed STATIC, and its batch ring could be read out of step
        // with the frame that filled it - binding other widgets' textures to the map
        // quads. That is the solid coloured squares over correctly rendered streets.
        mFogOfWarTexture->setDataVariance(osg::Object::DYNAMIC);
        mFogOfWarTexture->setFilter(osg::Texture::MIN_FILTER, osg::Texture::LINEAR);
        mFogOfWarTexture->setFilter(osg::Texture::MAG_FILTER, osg::Texture::LINEAR);
        mFogOfWarTexture->setWrap(osg::Texture::WRAP_S, osg::Texture::CLAMP_TO_EDGE);
        mFogOfWarTexture->setWrap(osg::Texture::WRAP_T, osg::Texture::CLAMP_TO_EDGE);
        mFogOfWarTexture->setUnRefImageDataAfterApply(false);
        mFogOfWarTexture->setImage(mFogOfWarImage);

        if (tspMapLifeEnabled())
        {
            Log(Debug::Warning)
                << "TSP_MAPLIFE_V2 phase=fog_texture"
                << " gen=" << tspMapLifeGeneration
                << " texture="
                << static_cast<const void*>(mFogOfWarTexture.get())
                << " image="
                << static_cast<const void*>(mFogOfWarImage.get())
                << " size="
                << (mFogOfWarImage ? mFogOfWarImage->s() : 0)
                << "x"
                << (mFogOfWarImage ? mFogOfWarImage->t() : 0);
        }
    }

    void LocalMap::MapSegment::initFogOfWar()
    {
        mFogOfWarImage = new osg::Image;
        // TSP_FOG_NO_PBO_V1
        //
        // Original TSP / PowerVR A/B. OSG normally gives this tiny, frequently
        // dirtied fog-of-war image a PixelBufferObject. gl4es must emulate that
        // unpack-PBO path, and the local map + compass are the two consumers that
        // corrupt together on the PowerVR unit. When the launcher exports
        // TSP_FOG_NO_PBO=1, upload this image directly instead.
        //
        // TSPS/Mali and every normal launcher keep the upstream PBO path.
        const bool tspFogNoPbo = (std::getenv("TSP_FOG_NO_PBO") != nullptr);
        if (!tspFogNoPbo)
            mFogOfWarImage->setPixelBufferObject(new osg::PixelBufferObject);

        static bool tspFogNoPboLogged = false;
        if (!tspFogNoPboLogged)
        {
            tspFogNoPboLogged = true;
            Log(Debug::Info) << "TSP_FOG_NO_PBO_V1 active=" << (tspFogNoPbo ? 1 : 0)
                             << " pbo=" << (tspFogNoPbo ? 0 : 1)
                             << " size=" << sFogOfWarResolution << "x" << sFogOfWarResolution;
        }

        mFogOfWarImage->allocateImage(sFogOfWarResolution, sFogOfWarResolution, 1, GL_RGBA, GL_UNSIGNED_BYTE);

        if (tspMapLifeEnabled())
        {
            Log(Debug::Warning)
                << "TSP_MAPLIFE_V2 phase=fog_image"
                << " gen=" << tspMapLifeGeneration
                << " image="
                << static_cast<const void*>(mFogOfWarImage.get())
                << " size=" << sFogOfWarResolution
                << "x" << sFogOfWarResolution
                << " pbo=1";
        }
        assert(mFogOfWarImage->isDataContiguous());
        std::vector<uint32_t> data;
        data.resize(sFogOfWarResolution * sFogOfWarResolution, 0xff000000);

        memcpy(mFogOfWarImage->data(), data.data(), data.size() * 4);

        createFogOfWarTexture();
    }

    void LocalMap::MapSegment::loadFogOfWar(const ESM::FogTexture& esm)
    {
        const std::vector<char>& data = esm.mImageData;
        if (data.empty())
        {
            initFogOfWar();
            return;
        }

        osgDB::ReaderWriter* readerwriter = osgDB::Registry::instance()->getReaderWriterForExtension("png");
        if (!readerwriter)
        {
            Log(Debug::Error) << "Error: Unable to load fog, can't find a png ReaderWriter";
            return;
        }

        Files::IMemStream in(data.data(), data.size());

        osgDB::ReaderWriter::ReadResult result = readerwriter->readImage(in);
        if (!result.success())
        {
            Log(Debug::Error) << "Error: Failed to read fog: " << result.message() << " code " << result.status();
            return;
        }

        mFogOfWarImage = result.getImage();
        mFogOfWarImage->flipVertical();
        mFogOfWarImage->dirty();

        createFogOfWarTexture();
        mHasFogState = true;
    }

    void LocalMap::MapSegment::saveFogOfWar(ESM::FogTexture& fog) const
    {
        if (!mFogOfWarImage)
            return;

        std::ostringstream ostream;

        osgDB::ReaderWriter* readerwriter = osgDB::Registry::instance()->getReaderWriterForExtension("png");
        if (!readerwriter)
        {
            Log(Debug::Error) << "Error: Unable to write fog, can't find a png ReaderWriter";
            return;
        }

        // extra flips are unfortunate, but required for compatibility with older versions
        mFogOfWarImage->flipVertical();
        osgDB::ReaderWriter::WriteResult result = readerwriter->writeImage(*mFogOfWarImage, ostream);
        if (!result.success())
        {
            Log(Debug::Error) << "Error: Unable to write fog: " << result.message() << " code " << result.status();
            return;
        }
        mFogOfWarImage->flipVertical();

        std::string data = ostream.str();
        fog.mImageData = std::vector<char>(data.begin(), data.end());
    }

    LocalMapRenderToTexture::LocalMapRenderToTexture(osg::Node* sceneRoot, int res, int mapWorldSize, float x, float y,
        const osg::Vec3d& upVector, float zmin, float zmax, osg::Texture2D* reuseColorTexture)
        : RTTNode(res, res, 0, false, 0, StereoAwareness::Unaware_MultiViewShaders, shouldAddMSAAIntermediateTarget())
        , mSceneRoot(sceneRoot)
        , mReuseColorTexture(reuseColorTexture)
        , mActive(true)
    {
        if (tspLocalMapCpuPipeEnabled())
        {
            const std::size_t pixelCount
                = static_cast<std::size_t>(res)
                * static_cast<std::size_t>(res);

            const std::size_t byteCount
                = pixelCount * 4;

            mTspReadbackBuffer.resize(byteCount);

            mTspCpuImage = new osg::Image;

            mTspCpuImage->setDataVariance(
                osg::Object::DYNAMIC);

            mTspCpuImage->allocateImage(
                res,
                res,
                1,
                GL_RGBA,
                GL_UNSIGNED_BYTE);

            mTspCpuImage->setOrigin(
                osg::Image::BOTTOM_LEFT);

            if (!mTspCpuImage->data())
            {
                Log(Debug::Error)
                    << "TSP_LOCALMAP_CPU_PIPE_V78 "
                    << "INIT_FAIL "
                    << "reason=osg-image-allocation-returned-null "
                    << "res=" << res;
            }
            else
            {
                std::memset(
                    mTspCpuImage->data(),
                    0,
                    mTspCpuImage->getTotalSizeInBytes());

                // Opaque black until first capture.
                for (std::size_t i = 3;
                     i < byteCount;
                     i += 4)
                {
                    mTspCpuImage->data()[i] = 255;
                }

                mTspCpuImage->dirty();
            }

            mTspCpuTexture = new osg::Texture2D;

            mTspCpuTexture->setDataVariance(
                osg::Object::DYNAMIC);

            mTspCpuTexture->setTextureSize(
                res,
                res);

            mTspCpuTexture->setInternalFormat(
                GL_RGBA);

            mTspCpuTexture->setSourceFormat(
                GL_RGBA);

            mTspCpuTexture->setSourceType(
                GL_UNSIGNED_BYTE);

            mTspCpuTexture->setFilter(
                osg::Texture::MIN_FILTER,
                osg::Texture::LINEAR);

            mTspCpuTexture->setFilter(
                osg::Texture::MAG_FILTER,
                osg::Texture::LINEAR);

            mTspCpuTexture->setWrap(
                osg::Texture::WRAP_S,
                osg::Texture::CLAMP_TO_EDGE);

            mTspCpuTexture->setWrap(
                osg::Texture::WRAP_T,
                osg::Texture::CLAMP_TO_EDGE);

            mTspCpuTexture
                ->setUnRefImageDataAfterApply(false);

            mTspCpuTexture->setImage(
                mTspCpuImage.get());

            Log(Debug::Warning)
                << "TSP_LOCALMAP_CPU_PIPE_V78 "
                << "INIT_PASS "
                << "res=" << res
                << " bytes=" << byteCount
                << " output=CPU-backed-Texture2D";
        }

        setNodeMask(Mask_RenderToTexture);

        if (SceneUtil::AutoDepth::isReversed())
            mProjectionMatrix = SceneUtil::getReversedZProjectionMatrixAsOrtho(
                -mapWorldSize / 2, mapWorldSize / 2, -mapWorldSize / 2, mapWorldSize / 2, 5, (zmax - zmin) + 10);
        else
            mProjectionMatrix.makeOrtho(
                -mapWorldSize / 2, mapWorldSize / 2, -mapWorldSize / 2, mapWorldSize / 2, 5, (zmax - zmin) + 10);

        mViewMatrix.makeLookAt(osg::Vec3d(x, y, zmax + 5), osg::Vec3d(x, y, zmin), upVector);

        setUpdateCallback(new CameraLocalUpdateCallback);
        setDepthBufferInternalFormat(GL_DEPTH24_STENCIL8);
    }

    osg::Texture2D*
    LocalMapRenderToTexture::getMapTextureForSegment()
    {
        if (mTspCpuTexture)
        {
            return mTspCpuTexture.get();
        }

        Log(Debug::Warning)
            << "TSP_LOCALMAP_PERSIST_V7 "
               "CPU_TEXTURE_FAIL"
            << " action=fallback-rtt-texture";

        return static_cast<osg::Texture2D*>(
            getColorTexture(nullptr));
    }


    void LocalMapRenderToTexture::captureCpuFramebuffer()
    {
        if (!mTspCpuImage
            || !mTspCpuTexture)
        {
            Log(Debug::Warning)
                << "TSP_LOCALMAP_PERSIST_V7 "
                   "CAPTURE_FAIL"
                << " reason=no-cpu-texture";

            return;
        }

        const int width
            = mTspCpuImage->s();

        const int height
            = mTspCpuImage->t();

        if (width <= 0 || height <= 0)
        {
            Log(Debug::Warning)
                << "TSP_LOCALMAP_PERSIST_V7 "
                   "CAPTURE_FAIL"
                << " reason=invalid-size";

            return;
        }

        const std::size_t pixels
            = static_cast<std::size_t>(
                  width)
            * static_cast<std::size_t>(
                  height);

        const std::size_t bytes
            = pixels * 4;

        if (mTspReadbackBuffer.size()
            != bytes)
        {
            mTspReadbackBuffer.resize(
                bytes);
        }

        const unsigned int sequence
            = ++mTspCaptureSequence;

        /*
         * Drain stale state so the error below belongs to this
         * readback. No glFinish here: readPixels provides the
         * synchronization needed by this post-draw capture.
         */
        for (int i = 0; i < 16; ++i)
        {
            if (glGetError() == GL_NO_ERROR)
                break;
        }

        glPixelStorei(
            GL_PACK_ALIGNMENT,
            1);

        glReadPixels(
            0,
            0,
            width,
            height,
            GL_RGBA,
            GL_UNSIGNED_BYTE,
            mTspReadbackBuffer.data());

        const GLenum error
            = glGetError();

        if (error != GL_NO_ERROR)
        {
            Log(Debug::Warning)
                << "TSP_LOCALMAP_PERSIST_V7 "
                   "CAPTURE_FAIL"
                << " seq=" << sequence
                << " stage=glReadPixels"
                << " error=0x"
                << std::hex
                << error
                << std::dec;

            return;
        }

        unsigned char* dst
            = mTspCpuImage->data();

        const unsigned char* src
            = mTspReadbackBuffer.data();

        std::size_t captureBlack = 0;
        std::size_t fusedBlack = 0;
        std::size_t recovered = 0;

        for (std::size_t i = 0;
             i < pixels;
             ++i)
        {
            const unsigned char* sp
                = src + i * 4;

            unsigned char* dp
                = dst + i * 4;

            const bool srcBlack
                = tspLocalMapV7PixelBlack(sp);

            const bool oldBlack
                = !mTspCpuInitialized
                || tspLocalMapV7PixelBlack(dp);

            if (srcBlack)
                ++captureBlack;

            /*
             * First capture establishes the tile.
             *
             * Later captures:
             *   - latest non-black pixel wins
             *   - black cannot destroy a known-good pixel
             */
            if (!mTspCpuInitialized
                || !srcBlack)
            {
                dp[0] = sp[0];
                dp[1] = sp[1];
                dp[2] = sp[2];
            }

            /*
             * Default-framebuffer alpha was one suspected source of
             * the V3/V5 puzzle-piece seams. Local map colour tiles
             * are always opaque; fog is a different texture layer.
             */
            dp[3] = 255;

            const bool nowBlack
                = tspLocalMapV7PixelBlack(dp);

            if (nowBlack)
                ++fusedBlack;

            if (oldBlack
                && !nowBlack)
            {
                ++recovered;
            }
        }

        mTspCpuInitialized = true;

        mTspFusedBlackPixels
            = fusedBlack;

        /*
         * OSG Texture2D watches the osg::Image modified count and
         * performs its normal image upload. Do not destroy/recreate
         * texture storage here.
         */
        mTspCpuImage->dirty();

        const std::uint64_t hash
            = tspLocalMapV7Hash(
                dst,
                bytes);

        Log(Debug::Warning)
            << "TSP_LOCALMAP_PERSIST_V7 "
               "CAPTURE_PASS"
            << " seq=" << sequence
            << " capture_black="
            << captureBlack
            << "/"
            << pixels
            << " fused_black="
            << fusedBlack
            << "/"
            << pixels
            << " recovered="
            << recovered
            << " hash="
            << hash
            << " path=FRAMEBUFFER->CPU-IMAGE"
            << " glfinish=0"
            << " gl4es-cpu-copy=0";
    }

    void LocalMapRenderToTexture::setDefaults(osg::Camera* camera)
    {
        // Disable small feature culling, it's not going to be reliable for this camera
        osg::Camera::CullingMode cullingMode
            = (osg::Camera::DEFAULT_CULLING | osg::Camera::FAR_PLANE_CULLING) & ~(osg::Camera::SMALL_FEATURE_CULLING);
        camera->setCullingMode(cullingMode);

        SceneUtil::setCameraClearDepth(camera);
        camera->setComputeNearFarMode(osg::Camera::DO_NOT_COMPUTE_NEAR_FAR);
        camera->setReferenceFrame(osg::Camera::ABSOLUTE_RF_INHERIT_VIEWPOINT);
        // TSP_LOCALMAP_FRAMEBUFFER_BYPASS_V73
        // Avoid the GL4ES/OSG RTT FBO path for local-map rendering.
        // Render the PRE_RENDER map camera into the normal framebuffer;
        // OSG then copies the completed pixels into the map texture.
        camera->setRenderTargetImplementation(osg::Camera::FRAME_BUFFER);

        // TSP_LOCALMAP_BROAD_V6
        // A resident-cell refresh must update the same texture object
        // already held by HUD/MapWindow. This also lets the GL4ES CPU
        // fusion cache accumulate improvements across rerenders.
        if (mReuseColorTexture)
        {
            camera->attach(
                osg::Camera::COLOR_BUFFER,
                mReuseColorTexture.get(),
                0,
                0,
                false,
                0);

            Log(Debug::Warning)
                << "TSP_LOCALMAP_BROAD_V6 REUSE_TEXTURE_ARMED"
                << " osg_texture=" << mReuseColorTexture.get();
        }
        Log(Debug::Warning)
            << "TSP_LOCALMAP_FRAMEBUFFER_BYPASS_V73 phase=configured target=FRAME_BUFFER";
        if (tspLocalMapCpuPipeEnabled())
        {
            camera->setPostDrawCallback(
                new TspLocalMapCpuCaptureCallback(this));

            Log(Debug::Warning)
                << "TSP_LOCALMAP_CPU_PIPE_V78 "
                << "CAMERA_ARMED "
                << "target=FRAME_BUFFER "
                << "capture=manual-glReadPixels "
                << "output=separate-CPU-Texture2D "
                << "rtt-copy=discarded";
        }

        camera->setClearColor(osg::Vec4(0.f, 0.f, 0.f, 1.f));
        camera->setClearMask(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT | GL_STENCIL_BUFFER_BIT);
        camera->setRenderOrder(osg::Camera::PRE_RENDER);

        camera->setCullMask(Mask_Scene | Mask_SimpleWater | Mask_Terrain | Mask_Object | Mask_Static);
        camera->setCullMaskLeft(Mask_Scene | Mask_SimpleWater | Mask_Terrain | Mask_Object | Mask_Static);
        camera->setCullMaskRight(Mask_Scene | Mask_SimpleWater | Mask_Terrain | Mask_Object | Mask_Static);
        camera->setNodeMask(Mask_RenderToTexture);
        camera->setProjectionMatrix(mProjectionMatrix);
        camera->setViewMatrix(mViewMatrix);

        auto* stateset = camera->getOrCreateStateSet();

        stateset->setAttribute(new osg::PolygonMode(osg::PolygonMode::FRONT_AND_BACK, osg::PolygonMode::FILL),
            osg::StateAttribute::OVERRIDE);
        stateset->addUniform(new osg::Uniform("projectionMatrix", static_cast<osg::Matrixf>(mProjectionMatrix)),
            osg::StateAttribute::ON | osg::StateAttribute::OVERRIDE);

        if (Stereo::getMultiview())
            Stereo::setMultiviewMatrices(stateset, { mProjectionMatrix, mProjectionMatrix });

        // assign large value to effectively turn off fog
        // shaders don't respect glDisable(GL_FOG)
        osg::ref_ptr<osg::Fog> fog(new osg::Fog);
        fog->setStart(10000000);
        fog->setEnd(10000000);
        stateset->setAttributeAndModes(fog, osg::StateAttribute::OFF | osg::StateAttribute::OVERRIDE);

        // turn of sky blending
        stateset->addUniform(new osg::Uniform("far", 10000000.0f));
        stateset->addUniform(new osg::Uniform("skyBlendingStart", 8000000.0f));
        stateset->addUniform(new osg::Uniform("screenRes", osg::Vec2f{ 1, 1 }));

        osg::ref_ptr<osg::LightModel> lightmodel = new osg::LightModel;
        lightmodel->setAmbientIntensity(osg::Vec4(0.3f, 0.3f, 0.3f, 1.f));
        stateset->setAttributeAndModes(lightmodel, osg::StateAttribute::ON | osg::StateAttribute::OVERRIDE);

        osg::ref_ptr<osg::Light> light = new osg::Light;
        light->setPosition(osg::Vec4(-0.3f, -0.3f, 0.7f, 0.f));
        light->setDiffuse(osg::Vec4(0.7f, 0.7f, 0.7f, 1.f));
        light->setAmbient(osg::Vec4(0, 0, 0, 1));
        light->setSpecular(osg::Vec4(0, 0, 0, 0));
        light->setLightNum(0);
        light->setConstantAttenuation(1.f);
        light->setLinearAttenuation(0.f);
        light->setQuadraticAttenuation(0.f);

        osg::ref_ptr<osg::LightSource> lightSource = new osg::LightSource;
        lightSource->setLight(light);

        lightSource->setStateSetModes(*stateset, osg::StateAttribute::ON | osg::StateAttribute::OVERRIDE);

        SceneUtil::ShadowManager::instance().disableShadowsForStateSet(*stateset);

        // override sun for local map
        SceneUtil::configureStateSetSunOverride(static_cast<SceneUtil::LightManager*>(mSceneRoot), light, stateset);

        camera->addChild(lightSource);
        camera->addChild(mSceneRoot);
    }


    void CameraLocalUpdateCallback::operator()(
        LocalMapRenderToTexture* node,
        osg::NodeVisitor* nv)
    {
        int maxFrames = 8;

        if (const char* env
                = std::getenv(
                    "TSP_RTT_HOLD_FRAMES"))
        {
            const int requested
                = std::atoi(env);

            if (requested > 0)
                maxFrames
                    = std::min(
                        requested,
                        32);
        }

        const int minFrames
            = std::min(
                3,
                maxFrames);

        const unsigned int completed
            = node->mTspCaptureSequence;

        const bool tileHealthy
            = node->mTspCpuInitialized
            && node->mTspFusedBlackPixels
                <= 64;

        const bool done
            = completed
                >= static_cast<unsigned int>(
                    maxFrames)
            || (completed
                    >= static_cast<
                        unsigned int>(
                            minFrames)
                && tileHealthy);

        if (completed == 0)
        {
            Log(Debug::Warning)
                << "TSP_LOCALMAP_PERSIST_V7 "
                   "HOLD_ARMED"
                << " min="
                << minFrames
                << " max="
                << maxFrames
                << " stop_black_lte=64";
        }

        if (done)
        {
            node->mActive = false;
            node->setNodeMask(0);

            Log(Debug::Warning)
                << "TSP_LOCALMAP_PERSIST_V7 "
                   "HOLD_DONE"
                << " frames="
                << completed
                << " fused_black="
                << node->mTspFusedBlackPixels
                << " reason="
                << (tileHealthy
                        ? "healthy"
                        : "max-frames");

            return;
        }

        node->mActive = true;

        traverse(
            node,
            nv);
    }

}
