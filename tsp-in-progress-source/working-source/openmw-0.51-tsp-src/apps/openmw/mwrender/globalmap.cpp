#include <cstdlib>
#include <malloc.h>
#include "globalmap.hpp"

#include <osg/Geometry>
#include <osg/Group>
#include <osg/Image>
#include <osg/Texture2D>

#include <osgDB/WriteFile>

#include <components/files/memorystream.hpp>
#include <components/settings/values.hpp>

#include <components/debug/debuglog.hpp>

#include <components/resource/imagemanager.hpp>
#include <components/resource/resourcesystem.hpp>

#include <components/sceneutil/depth.hpp>
#include <components/sceneutil/nodecallback.hpp>
#include <components/sceneutil/workqueue.hpp>

#include <components/vfs/pathutil.hpp>

#include <components/esm3/globalmap.hpp>
#include <components/esm3/loadland.hpp>

#include "../mwbase/environment.hpp"

#include "../mwworld/esmstore.hpp"

#include "vismask.hpp"

namespace
{

    // Create a screen-aligned quad with given texture coordinates.
    // Assumes a top-left origin of the sampled image.
    osg::ref_ptr<osg::Geometry> createTexturedQuad(
        float leftTexCoord, float topTexCoord, float rightTexCoord, float bottomTexCoord)
    {
        osg::ref_ptr<osg::Geometry> geom = new osg::Geometry;

        osg::ref_ptr<osg::Vec3Array> verts = new osg::Vec3Array;
        verts->push_back(osg::Vec3f(-1, -1, 0));
        verts->push_back(osg::Vec3f(-1, 1, 0));
        verts->push_back(osg::Vec3f(1, 1, 0));
        verts->push_back(osg::Vec3f(1, -1, 0));

        geom->setVertexArray(verts);

        osg::ref_ptr<osg::Vec2Array> texcoords = new osg::Vec2Array;
        texcoords->push_back(osg::Vec2f(leftTexCoord, 1.f - bottomTexCoord));
        texcoords->push_back(osg::Vec2f(leftTexCoord, 1.f - topTexCoord));
        texcoords->push_back(osg::Vec2f(rightTexCoord, 1.f - topTexCoord));
        texcoords->push_back(osg::Vec2f(rightTexCoord, 1.f - bottomTexCoord));

        osg::ref_ptr<osg::Vec4Array> colors = new osg::Vec4Array;
        colors->push_back(osg::Vec4(1.f, 1.f, 1.f, 1.f));
        geom->setColorArray(colors, osg::Array::BIND_OVERALL);

        geom->setTexCoordArray(0, texcoords, osg::Array::BIND_PER_VERTEX);

        geom->addPrimitiveSet(new osg::DrawArrays(osg::PrimitiveSet::QUADS, 0, 4));

        return geom;
    }

    class CameraUpdateGlobalCallback : public SceneUtil::NodeCallback<CameraUpdateGlobalCallback, osg::Camera*>
    {
    public:
        CameraUpdateGlobalCallback(MWRender::GlobalMap* parent)
            : mRendered(false)
            , mParent(parent)
        {
        }

        void operator()(osg::Camera* node, osg::NodeVisitor* nv)
        {
            if (mRendered)
            {
                if (mParent->copyResult(node, nv->getTraversalNumber()))
                {
                    node->setNodeMask(0);
                    mParent->markForRemoval(node);
                }
                return;
            }

            traverse(node, nv);

            mRendered = true;
        }

    private:
        bool mRendered;
        MWRender::GlobalMap* mParent;
    };

    std::vector<char> writePng(const osg::Image& overlayImage)
    {
        std::ostringstream ostream;
        osgDB::ReaderWriter* readerwriter = osgDB::Registry::instance()->getReaderWriterForExtension("png");
        if (!readerwriter)
        {
            Log(Debug::Error) << "Error: Can't write map overlay: no png readerwriter found";
            return std::vector<char>();
        }

        osgDB::ReaderWriter::WriteResult result = readerwriter->writeImage(overlayImage, ostream);
        if (!result.success())
        {
            Log(Debug::Warning) << "Error: Can't write map overlay: " << result.message() << " code "
                                << result.status();
            return std::vector<char>();
        }

        std::string data = ostream.str();
        return std::vector<char>(data.begin(), data.end());
    }
}

namespace MWRender
{

    class CreateMapWorkItem : public SceneUtil::WorkItem
    {
    public:
        CreateMapWorkItem(int width, int height, int minX, int minY, int maxX, int maxY, int cellSize,
            const MWWorld::Store<ESM::Land>& landStore, osg::ref_ptr<osg::Image> colorLut)
            : mWidth(width)
            , mHeight(height)
            , mMinX(minX)
            , mMinY(minY)
            , mMaxX(maxX)
            , mMaxY(maxY)
            , mCellSize(cellSize)
            , mLandStore(landStore)
            , mColorLut(colorLut)
        {
        }

        void doWork() override
        {
            osg::ref_ptr<osg::Image> image = new osg::Image;
            image->allocateImage(mWidth, mHeight, 1, GL_RGB, GL_UNSIGNED_BYTE);

            osg::ref_ptr<osg::Image> alphaImage = new osg::Image;
            alphaImage->allocateImage(mWidth, mHeight, 1, GL_ALPHA, GL_UNSIGNED_BYTE);

            for (int x = mMinX; x <= mMaxX; ++x)
            {
                for (int y = mMinY; y <= mMaxY; ++y)
                {
                    const ESM::Land* land = mLandStore.search(x, y);

                    for (int cellY = 0; cellY < mCellSize; ++cellY)
                    {
                        for (int cellX = 0; cellX < mCellSize; ++cellX)
                        {
                            int vertexX = (cellX * 9) / mCellSize; // 0..8
                            int vertexY = (cellY * 9) / mCellSize; // 0..8

                            int texelX = (x - mMinX) * mCellSize + cellX;
                            int texelY = (y - mMinY) * mCellSize + cellY;

                            int lutIndex = 0;
                            // Converting [-128; 127] WNAM range to [0; 255] index
                            if (land != nullptr && (land->mDataTypes & ESM::Land::DATA_WNAM))
                                lutIndex = static_cast<int>(land->mWnam[vertexY * 9 + vertexX]) + 128;

                            // Use getColor to handle all pixel format conversions automatically
                            osg::Vec4 color = mColorLut->getColor(lutIndex, 0);

                            // Use setColor to write to output images
                            image->setColor(color, texelX, texelY);

                            // Set alpha based on lutIndex threshold
                            osg::Vec4 alpha(0.0f, 0.0f, 0.0f, lutIndex < 128 ? 0.0f : 1.0f);
                            alphaImage->setColor(alpha, texelX, texelY);
                        }
                    }
                }
            }

            mBaseTexture = new osg::Texture2D;
            mBaseTexture->setWrap(osg::Texture::WRAP_S, osg::Texture::CLAMP_TO_EDGE);
            mBaseTexture->setWrap(osg::Texture::WRAP_T, osg::Texture::CLAMP_TO_EDGE);
            mBaseTexture->setFilter(osg::Texture::MIN_FILTER, osg::Texture::LINEAR);
            mBaseTexture->setFilter(osg::Texture::MAG_FILTER, osg::Texture::LINEAR);
            mBaseTexture->setImage(image);
            mBaseTexture->setResizeNonPowerOfTwoHint(false);

            mAlphaTexture = new osg::Texture2D;
            mAlphaTexture->setWrap(osg::Texture::WRAP_S, osg::Texture::CLAMP_TO_EDGE);
            mAlphaTexture->setWrap(osg::Texture::WRAP_T, osg::Texture::CLAMP_TO_EDGE);
            mAlphaTexture->setFilter(osg::Texture::MIN_FILTER, osg::Texture::LINEAR);
            mAlphaTexture->setFilter(osg::Texture::MAG_FILTER, osg::Texture::LINEAR);
            mAlphaTexture->setImage(alphaImage);
            mAlphaTexture->setResizeNonPowerOfTwoHint(false);

            mOverlayImage = new osg::Image;
            mOverlayImage->allocateImage(mWidth, mHeight, 1, GL_RGBA, GL_UNSIGNED_BYTE);
            assert(mOverlayImage->isDataContiguous());

            memset(mOverlayImage->data(), 0, mOverlayImage->getTotalSizeInBytes());

            mOverlayTexture = new osg::Texture2D;
            mOverlayTexture->setWrap(osg::Texture::WRAP_S, osg::Texture::CLAMP_TO_EDGE);
            mOverlayTexture->setWrap(osg::Texture::WRAP_T, osg::Texture::CLAMP_TO_EDGE);
            mOverlayTexture->setFilter(osg::Texture::MIN_FILTER, osg::Texture::LINEAR);
            mOverlayTexture->setFilter(osg::Texture::MAG_FILTER, osg::Texture::LINEAR);
            mOverlayTexture->setResizeNonPowerOfTwoHint(false);
            mOverlayTexture->setInternalFormat(GL_RGBA);
            mOverlayTexture->setTextureSize(mWidth, mHeight);
        }

        int mWidth, mHeight;
        int mMinX, mMinY, mMaxX, mMaxY;
        int mCellSize;
        const MWWorld::Store<ESM::Land>& mLandStore;
        osg::ref_ptr<osg::Image> mColorLut;

        osg::ref_ptr<osg::Texture2D> mBaseTexture;
        osg::ref_ptr<osg::Texture2D> mAlphaTexture;

        osg::ref_ptr<osg::Image> mOverlayImage;
        osg::ref_ptr<osg::Texture2D> mOverlayTexture;
    };

    struct GlobalMap::WritePng final : public SceneUtil::WorkItem
    {
        osg::ref_ptr<const osg::Image> mOverlayImage;
        std::vector<char> mImageData;

        explicit WritePng(osg::ref_ptr<const osg::Image> overlayImage)
            : mOverlayImage(std::move(overlayImage))
        {
        }

        void doWork() override { mImageData = writePng(*mOverlayImage); }
    };

    GlobalMap::GlobalMap(osg::Group* root, SceneUtil::WorkQueue* workQueue)
        : mRoot(root)
        , mWorkQueue(workQueue)
        , mWidth(0)
        , mHeight(0)
        , mMinX(0)
        , mMaxX(0)
        , mMinY(0)
        , mMaxY(0)
    {
    }

    GlobalMap::~GlobalMap()
    {
        for (auto& camera : mCamerasPendingRemoval)
            removeCamera(camera);
        for (auto& camera : mActiveCameras)
            removeCamera(camera);

        if (mWorkItem)
            mWorkItem->waitTillDone();
    }

    void GlobalMap::render()
    {
        const MWWorld::ESMStore& esmStore = *MWBase::Environment::get().getESMStore();

        // get the size of the world
        MWWorld::Store<ESM::Cell>::iterator it = esmStore.get<ESM::Cell>().extBegin();
        for (; it != esmStore.get<ESM::Cell>().extEnd(); ++it)
        {
            if (it->getGridX() < mMinX)
                mMinX = it->getGridX();
            if (it->getGridX() > mMaxX)
                mMaxX = it->getGridX();
            if (it->getGridY() < mMinY)
                mMinY = it->getGridY();
            if (it->getGridY() > mMaxY)
                mMaxY = it->getGridY();
        }

        const int cellSize = Settings::map().mGlobalMapCellSize;

        mWidth = cellSize * (mMaxX - mMinX + 1);
        mHeight = cellSize * (mMaxY - mMinY + 1);

        // Load color LUT texture
        constexpr VFS::Path::NormalizedView colorLutPath("textures/omw_map_color_palette.dds");
        auto resourceSystem = MWBase::Environment::get().getResourceSystem();
        osg::ref_ptr<osg::Image> colorLut = resourceSystem->getImageManager()->getImage(colorLutPath);

        // Validate LUT dimensions
        if (!colorLut || colorLut->s() != 256 || colorLut->t() != 1)
        {
            throw std::runtime_error("Global map color LUT must be 256x1 pixels, got "
                + std::to_string(colorLut ? colorLut->s() : 0) + "x" + std::to_string(colorLut ? colorLut->t() : 0));
        }

        mWorkItem = new CreateMapWorkItem(
            mWidth, mHeight, mMinX, mMinY, mMaxX, mMaxY, cellSize, esmStore.get<ESM::Land>(), colorLut);
        mWorkQueue->addWorkItem(mWorkItem);
    }

    void GlobalMap::worldPosToImageSpace(float x, float z, float& imageX, float& imageY)
    {
        imageX = (float(x / float(Constants::CellSizeInUnits) - mMinX) / (mMaxX - mMinX + 1)) * getWidth();

        imageY = (1.f - float(z / float(Constants::CellSizeInUnits) - mMinY) / (mMaxY - mMinY + 1)) * getHeight();
    }

    void GlobalMap::requestOverlayTextureUpdate(int x, int y, int width, int height,
        osg::ref_ptr<osg::Texture2D> texture, bool clear, bool cpuCopy, float srcLeft, float srcTop, float srcRight,
        float srcBottom)
    {
        osg::ref_ptr<osg::Camera> camera(new osg::Camera);
        camera->setNodeMask(Mask_RenderToTexture);
        camera->setReferenceFrame(osg::Camera::ABSOLUTE_RF);
        camera->setViewMatrix(osg::Matrix::identity());
        camera->setProjectionMatrix(osg::Matrix::identity());
        camera->setProjectionResizePolicy(osg::Camera::FIXED);
        camera->setRenderOrder(osg::Camera::PRE_RENDER, 1); // Make sure the global map is rendered after the local map
        y = mHeight - y - height; // convert top-left origin to bottom-left
        camera->setViewport(x, y, width, height);

        if (clear)
        {
            camera->setClearMask(GL_COLOR_BUFFER_BIT);
            camera->setClearColor(osg::Vec4(0, 0, 0, 0));
        }
        else
            camera->setClearMask(GL_NONE);

        camera->setUpdateCallback(new CameraUpdateGlobalCallback(this));

        camera->setRenderTargetImplementation(osg::Camera::FRAME_BUFFER_OBJECT, osg::Camera::PIXEL_BUFFER_RTT);
        camera->attach(osg::Camera::COLOR_BUFFER, mOverlayTexture);

        /* TSP_GLOBALMAP_DEPTH: upstream suppresses the depth attachment here because a
           2D overlay blit does not need one - true on desktop GL. GLES2 via gl4es
           rejects a colour-only FBO with GL_FRAMEBUFFER_INCOMPLETE_MISSING_ATTACHMENT
           (0x8CD7), observed three times per global map update on a 954x864 target.
           Letting OSG attach its implicit depth buffer makes the FBO validate. */
        camera->setImplicitBufferAttachmentMask(osg::DisplaySettings::IMPLICIT_COLOR_BUFFER_ATTACHMENT
            | osg::DisplaySettings::IMPLICIT_DEPTH_BUFFER_ATTACHMENT);

        if (cpuCopy)
        {
            // Attach an image to copy the render back to the CPU when finished
            osg::ref_ptr<osg::Image> image(new osg::Image);
            image->setPixelFormat(mOverlayImage->getPixelFormat());
            image->setDataType(mOverlayImage->getDataType());
            camera->attach(osg::Camera::COLOR_BUFFER, image);

            ImageDest imageDest;
            imageDest.mImage = image;
            imageDest.mX = x;
            imageDest.mY = y;
            mPendingImageDest[camera] = std::move(imageDest);
        }

        // Create a quad rendering the updated texture
        if (texture)
        {
            osg::ref_ptr<osg::Geometry> geom = createTexturedQuad(srcLeft, srcTop, srcRight, srcBottom);
            osg::ref_ptr<osg::Depth> depth = new SceneUtil::AutoDepth;
            depth->setWriteMask(false);
            osg::StateSet* stateset = geom->getOrCreateStateSet();
            stateset->setAttribute(depth);
            stateset->setTextureAttributeAndModes(0, texture, osg::StateAttribute::ON);
            stateset->setMode(GL_DEPTH_TEST, osg::StateAttribute::OFF);

            if (mAlphaTexture)
            {
                osg::ref_ptr<osg::Vec2Array> texcoords = new osg::Vec2Array;

                float x1 = x / static_cast<float>(mWidth);
                float x2 = (x + width) / static_cast<float>(mWidth);
                float y1 = y / static_cast<float>(mHeight);
                float y2 = (y + height) / static_cast<float>(mHeight);
                texcoords->push_back(osg::Vec2f(x1, y1));
                texcoords->push_back(osg::Vec2f(x1, y2));
                texcoords->push_back(osg::Vec2f(x2, y2));
                texcoords->push_back(osg::Vec2f(x2, y1));
                geom->setTexCoordArray(1, texcoords, osg::Array::BIND_PER_VERTEX);

                stateset->setTextureAttributeAndModes(1, mAlphaTexture, osg::StateAttribute::ON);
            }

            camera->addChild(geom);
        }

        mRoot->addChild(camera);

        mActiveCameras.push_back(camera);
    }

    void GlobalMap::exploreCell(int cellX, int cellY, osg::ref_ptr<osg::Texture2D> localMapTexture)
    {
        ensureLoaded();

        if (!localMapTexture)
            return;

        const int cellSize = Settings::map().mGlobalMapCellSize;
        const int originX = (cellX - mMinX) * cellSize;
        // +1 because we want the top left corner of the cell, not the bottom left
        const int originY = (cellY - mMinY + 1) * cellSize;

        if (cellX > mMaxX || cellX < mMinX || cellY > mMaxY || cellY < mMinY)
            return;

        requestOverlayTextureUpdate(
            originX, mHeight - originY, cellSize, cellSize, std::move(localMapTexture), false, true);
    }

    // TSP_GMAP_MEM_V1
    static long long tspGlobalMapInuseKb()
    {
#if defined(__GLIBC__)
#if defined(__GLIBC_PREREQ)
#if __GLIBC_PREREQ(2, 33)
        struct mallinfo2 tspMi = mallinfo2();
        return static_cast<long long>(tspMi.uordblks / 1024);
#else
        struct mallinfo tspMi = mallinfo();
        return static_cast<long long>(tspMi.uordblks) / 1024;
#endif
#endif
#endif
        return -1;
    }

    // TSP_GMAP_REPAIR_V1
    // Cells blitted from an incomplete FBO (before TSP_GLOBALMAP_DEPTH) or from a stale
    // RTT camera (before TSP_GMAP_CAMERA_DRAIN_V1) were read back as garbage and baked
    // into the saved overlay. Four signatures, none of which real map content produces:
    //   BAD-NOISE   roughness >= hi        high-frequency dither from a bad readback
    //   BAD-FLAT    roughness <= lo        solid single-colour block
    //   BAD-PARTIAL coverage < mincover%   stray blit into a never-explored cell
    //   BAD-BLUE    meanB - meanR >= maxblue   channel-dropped readback. Real overlay
    //               content is warm: measured across 37 good cells, meanB - meanR runs
    //               -17..-2, while corrupt cells measure +89 and +101.
    // TSP_GMAP_REPAIR=1 report only, =2 zero the bad cells so they re-explore clean.
    static void tspRepairOverlay(osg::Image* tspImg, int tspW, int tspH, int tspCellSize)
    {
        const char* tspModeEnv = std::getenv("TSP_GMAP_REPAIR");
        if (!tspModeEnv || tspImg == nullptr || tspCellSize <= 0)
            return;
        const int tspMode = std::atoi(tspModeEnv);
        if (tspMode < 1)
            return;
        const char* tspHiEnv = std::getenv("TSP_GMAP_REPAIR_THRESH");
        const char* tspLoEnv = std::getenv("TSP_GMAP_REPAIR_MINROUGH");
        const char* tspCovEnv = std::getenv("TSP_GMAP_REPAIR_MINCOVER");
        const char* tspBluEnv = std::getenv("TSP_GMAP_REPAIR_MAXBLUE");
        const int tspHi = tspHiEnv ? std::atoi(tspHiEnv) : 60;
        const int tspLo = tspLoEnv ? std::atoi(tspLoEnv) : 12;
        const int tspMinCover = tspCovEnv ? std::atoi(tspCovEnv) : 50;
        const int tspMaxBlue = tspBluEnv ? std::atoi(tspBluEnv) : 50;

        unsigned char* tspData = tspImg->data();
        const int tspStride = static_cast<int>(tspImg->getRowSizeInBytes());
        const int tspPix = tspImg->getPixelSizeInBits() / 8;
        if (tspData == nullptr || tspPix < 3)
        {
            Log(Debug::Info) << "TSP_GMAP_REPAIR_V1 FAIL reason=bad-image pix=" << tspPix;
            return;
        }

        int tspBadHi = 0, tspBadLo = 0, tspBadPart = 0, tspBadBlue = 0, tspTotal = 0;
        for (int tspCy = 0; tspCy + tspCellSize <= tspH; tspCy += tspCellSize)
        {
            for (int tspCx = 0; tspCx + tspCellSize <= tspW; tspCx += tspCellSize)
            {
                long long tspSum = 0, tspN = 0, tspSeen = 0, tspPixN = 0;
                long long tspR = 0, tspG = 0, tspB = 0;
                for (int tspYy = 0; tspYy < tspCellSize; ++tspYy)
                {
                    const unsigned char* tspRow = tspData
                        + static_cast<size_t>(tspCy + tspYy) * tspStride
                        + static_cast<size_t>(tspCx) * tspPix;
                    for (int tspXx = 0; tspXx < tspCellSize; ++tspXx)
                    {
                        const unsigned char* tspA = tspRow + static_cast<size_t>(tspXx) * tspPix;
                        ++tspPixN;
                        tspR += tspA[0];
                        tspG += tspA[1];
                        tspB += tspA[2];
                        if (tspPix >= 4 ? (tspA[3] != 0) : (tspA[0] || tspA[1] || tspA[2]))
                            ++tspSeen;
                        if (tspXx + 1 < tspCellSize)
                        {
                            const unsigned char* tspB2 = tspA + tspPix;
                            int tspD = 0;
                            for (int tspC = 0; tspC < 3; ++tspC)
                                tspD += (tspA[tspC] > tspB2[tspC]) ? (tspA[tspC] - tspB2[tspC])
                                                                   : (tspB2[tspC] - tspA[tspC]);
                            tspSum += tspD;
                            ++tspN;
                        }
                    }
                }
                if (tspN == 0 || tspSeen == 0)
                    continue; // genuinely unexplored
                ++tspTotal;
                const int tspMeanR = static_cast<int>(tspR / tspPixN);
                const int tspMeanG = static_cast<int>(tspG / tspPixN);
                const int tspMeanB = static_cast<int>(tspB / tspPixN);
                const int tspCover = static_cast<int>((tspSeen * 100) / tspPixN);
                const int tspAvg = static_cast<int>(tspSum / tspN);
                const bool tspPartBad = (tspCover < tspMinCover);
                const bool tspBlueBad = !tspPartBad && ((tspMeanB - tspMeanR) >= tspMaxBlue);
                const bool tspHiBad = !tspPartBad && !tspBlueBad && (tspAvg >= tspHi);
                const bool tspLoBad = !tspPartBad && !tspBlueBad && (tspAvg <= tspLo);
                if (tspPartBad)
                    ++tspBadPart;
                if (tspBlueBad)
                    ++tspBadBlue;
                if (tspHiBad)
                    ++tspBadHi;
                if (tspLoBad)
                    ++tspBadLo;
                const bool tspIsBad = tspPartBad || tspBlueBad || tspHiBad || tspLoBad;
                if (tspMode == 1 || tspIsBad)
                    Log(Debug::Info) << "TSP_GMAP_REPAIR_V1 cell px=" << tspCx << "," << tspCy
                                     << " roughness=" << tspAvg << " cover=" << tspCover << "%"
                                     << " rgb=" << tspMeanR << "," << tspMeanG << "," << tspMeanB
                                     << " b_minus_r=" << (tspMeanB - tspMeanR)
                                     << (tspPartBad ? " BAD-PARTIAL"
                                                    : (tspBlueBad ? " BAD-BLUE"
                                                                  : (tspHiBad ? " BAD-NOISE"
                                                                              : (tspLoBad ? " BAD-FLAT" : " ok"))))
                                     << ((tspIsBad && tspMode >= 2) ? " ZEROED" : "");
                if (tspIsBad && tspMode >= 2)
                    for (int tspYy = 0; tspYy < tspCellSize; ++tspYy)
                        memset(tspData + static_cast<size_t>(tspCy + tspYy) * tspStride
                                + static_cast<size_t>(tspCx) * tspPix,
                            0, static_cast<size_t>(tspCellSize) * tspPix);
            }
        }
        Log(Debug::Info) << "TSP_GMAP_REPAIR_V1 done mode=" << tspMode << " hi=" << tspHi
                         << " lo=" << tspLo << " mincover=" << tspMinCover
                         << " maxblue=" << tspMaxBlue
                         << " explored_cells=" << tspTotal << " bad_noise=" << tspBadHi
                         << " bad_flat=" << tspBadLo << " bad_partial=" << tspBadPart
                         << " bad_blue=" << tspBadBlue
                         << " cell_px=" << tspCellSize << " image=" << tspW << "x" << tspH;
    }

    void GlobalMap::clear()
    {
        ensureLoaded();

        // TSP_GMAP_MEM_V1
        const long long tspGm0 = tspGlobalMapInuseKb();
        const size_t tspPendingBefore = mPendingImageDest.size();
        const size_t tspActiveBefore = mActiveCameras.size();
        const size_t tspRemovalBefore = mCamerasPendingRemoval.size();
        const size_t tspOverlayBytes = mOverlayImage ? mOverlayImage->getTotalSizeInBytes() : 0;

        memset(mOverlayImage->data(), 0, mOverlayImage->getTotalSizeInBytes());

        mPendingImageDest.clear();

        // TSP_GMAP_CAMERA_DRAIN_V1
        // Every GlobalMap::read() parks an RTT camera in mRoot whose quad holds a
        // Texture2D wrapping the freshly decoded overlay image. cleanupCameras() only
        // runs from MapWindow::cellExplored, so across a save reload these accumulate,
        // one whole overlay image each, and keep re-blitting onto the live overlay.
        // The destructor (globalmap.cpp:258) drains both vectors exactly this way.
        if (std::getenv("TSP_NO_GMAP_DRAIN") == nullptr)
        {
            for (auto& tspCam : mCamerasPendingRemoval)
                removeCamera(tspCam);
            mCamerasPendingRemoval.clear();
            for (auto& tspCam : mActiveCameras)
                removeCamera(tspCam);
            mActiveCameras.clear();
        }
        const long long tspGm1 = tspGlobalMapInuseKb();

        // just push a Camera to clear the FBO, instead of setImage()/dirty()
        // easier, since we don't need to worry about synchronizing access :)
        requestOverlayTextureUpdate(0, 0, mWidth, mHeight, osg::ref_ptr<osg::Texture2D>(), true, false);

        Log(Debug::Info) << "TSP_GMAP_MEM_V1 phase=clear pending_before=" << tspPendingBefore
                         << " active_cams=" << tspActiveBefore
                         << " pending_removal_cams=" << tspRemovalBefore
                         << " drain_freed_kb=" << (tspGm0 - tspGm1)
                         << " overlay_bytes=" << tspOverlayBytes
                         << " size=" << mWidth << "x" << mHeight;
    }

    void GlobalMap::write(ESM::GlobalMap& map)
    {
        ensureLoaded();

        map.mBounds.mMinX = mMinX;
        map.mBounds.mMaxX = mMaxX;
        map.mBounds.mMinY = mMinY;
        map.mBounds.mMaxY = mMaxY;

        if (mWritePng != nullptr)
        {
            mWritePng->waitTillDone();
            map.mImageData = std::move(mWritePng->mImageData);
            mWritePng = nullptr;
            return;
        }

        map.mImageData = writePng(*mOverlayImage);
    }

    struct Box
    {
        int mLeft, mTop, mRight, mBottom;

        Box(int left, int top, int right, int bottom)
            : mLeft(left)
            , mTop(top)
            , mRight(right)
            , mBottom(bottom)
        {
        }
        bool operator==(const Box& other) const
        {
            return mLeft == other.mLeft && mTop == other.mTop && mRight == other.mRight && mBottom == other.mBottom;
        }
    };

    void GlobalMap::read(ESM::GlobalMap& map)
    {
        ensureLoaded();

        const ESM::GlobalMap::Bounds& bounds = map.mBounds;

        if (bounds.mMaxX - bounds.mMinX < 0)
            return;
        if (bounds.mMaxY - bounds.mMinY < 0)
            return;

        if (bounds.mMinX > bounds.mMaxX || bounds.mMinY > bounds.mMaxY)
            throw std::runtime_error("invalid map bounds");

        if (map.mImageData.empty())
            return;

        Files::IMemStream istream(map.mImageData.data(), map.mImageData.size());

        osgDB::ReaderWriter* readerwriter = osgDB::Registry::instance()->getReaderWriterForExtension("png");
        if (!readerwriter)
        {
            Log(Debug::Error) << "Error: Can't read map overlay: no png readerwriter found";
            return;
        }

        osgDB::ReaderWriter::ReadResult result = readerwriter->readImage(istream);
        if (!result.success())
        {
            Log(Debug::Error) << "Error: Can't read map overlay: " << result.message() << " code " << result.status();
            return;
        }

        osg::ref_ptr<osg::Image> image = result.getImage();
        int imageWidth = image->s();
        int imageHeight = image->t();

        int xLength = (bounds.mMaxX - bounds.mMinX + 1);
        int yLength = (bounds.mMaxY - bounds.mMinY + 1);

        // Size of one cell in image space
        int cellImageSizeSrc = imageWidth / xLength;
        if (int(imageHeight / yLength) != cellImageSizeSrc)
            throw std::runtime_error("cell size must be quadratic");

        // If cell bounds of the currently loaded content and the loaded savegame do not match,
        // we need to resize source/dest boxes to accommodate
        // This means nonexisting cells will be dropped silently
        const int cellImageSizeDst = Settings::map().mGlobalMapCellSize;

        // Completely off-screen? -> no need to blit anything
        if (bounds.mMaxX < mMinX || bounds.mMaxY < mMinY || bounds.mMinX > mMaxX || bounds.mMinY > mMaxY)
            return;

        int leftDiff = (mMinX - bounds.mMinX);
        int topDiff = (bounds.mMaxY - mMaxY);
        int rightDiff = (bounds.mMaxX - mMaxX);
        int bottomDiff = (mMinY - bounds.mMinY);

        Box srcBox(std::max(0, leftDiff * cellImageSizeSrc), std::max(0, topDiff * cellImageSizeSrc),
            std::min(imageWidth, imageWidth - rightDiff * cellImageSizeSrc),
            std::min(imageHeight, imageHeight - bottomDiff * cellImageSizeSrc));

        Box destBox(std::max(0, -leftDiff * cellImageSizeDst), std::max(0, -topDiff * cellImageSizeDst),
            std::min(mWidth, mWidth + rightDiff * cellImageSizeDst),
            std::min(mHeight, mHeight + bottomDiff * cellImageSizeDst));

        osg::ref_ptr<osg::Texture2D> texture(new osg::Texture2D);
        texture->setImage(image);
        texture->setWrap(osg::Texture::WRAP_S, osg::Texture::CLAMP_TO_EDGE);
        texture->setWrap(osg::Texture::WRAP_T, osg::Texture::CLAMP_TO_EDGE);
        texture->setFilter(osg::Texture::MIN_FILTER, osg::Texture::LINEAR);
        texture->setFilter(osg::Texture::MAG_FILTER, osg::Texture::LINEAR);
        texture->setResizeNonPowerOfTwoHint(false);

        if (srcBox == destBox && imageWidth == mWidth && imageHeight == mHeight)
        {
            mOverlayImage = image;
            // TSP_GMAP_REPAIR_V1 - repair before the blit so the GPU gets the fixed copy too
            tspRepairOverlay(mOverlayImage.get(), mWidth, mHeight, cellImageSizeDst);

            requestOverlayTextureUpdate(0, 0, mWidth, mHeight, std::move(texture), true, false);
        }
        else
        {
            // Dimensions don't match. This could mean a changed map region, or a changed map resolution.
            // In the latter case, we'll want filtering.
            // Create a RTT Camera and draw the image onto mOverlayImage in the next frame.
            requestOverlayTextureUpdate(destBox.mLeft, destBox.mTop, destBox.mRight - destBox.mLeft,
                destBox.mBottom - destBox.mTop, std::move(texture), true, true, srcBox.mLeft / float(imageWidth),
                srcBox.mTop / float(imageHeight), srcBox.mRight / float(imageWidth),
                srcBox.mBottom / float(imageHeight));
        }
    }

    osg::ref_ptr<osg::Texture2D> GlobalMap::getBaseTexture()
    {
        ensureLoaded();
        return mBaseTexture;
    }

    osg::ref_ptr<osg::Texture2D> GlobalMap::getOverlayTexture()
    {
        ensureLoaded();
        return mOverlayTexture;
    }

    void GlobalMap::ensureLoaded()
    {
        if (mWorkItem)
        {
            mWorkItem->waitTillDone();

            mOverlayImage = mWorkItem->mOverlayImage;
            mBaseTexture = mWorkItem->mBaseTexture;
            mAlphaTexture = mWorkItem->mAlphaTexture;
            mOverlayTexture = mWorkItem->mOverlayTexture;

            requestOverlayTextureUpdate(0, 0, mWidth, mHeight, osg::ref_ptr<osg::Texture2D>(), true, false);

            mWorkItem = nullptr;
        }
    }

    bool GlobalMap::copyResult(osg::Camera* camera, unsigned int frame)
    {
        ImageDestMap::iterator it = mPendingImageDest.find(camera);
        if (it == mPendingImageDest.end())
            return true;
        else
        {
            ImageDest& imageDest = it->second;
            if (imageDest.mFrameDone == 0)
                imageDest.mFrameDone
                    = frame + 2; // wait an extra frame to ensure the draw thread has completed its frame.
            if (imageDest.mFrameDone > frame)
            {
                ++it;
                return false;
            }

            mOverlayImage->copySubImage(imageDest.mX, imageDest.mY, 0, imageDest.mImage);
            mPendingImageDest.erase(it);
            return true;
        }
    }

    void GlobalMap::markForRemoval(osg::Camera* camera)
    {
        CameraVector::iterator found = std::find(mActiveCameras.begin(), mActiveCameras.end(), camera);
        if (found == mActiveCameras.end())
        {
            Log(Debug::Error) << "Error: GlobalMap trying to remove an inactive camera";
            return;
        }
        mActiveCameras.erase(found);
        mCamerasPendingRemoval.push_back(camera);
    }

    void GlobalMap::cleanupCameras()
    {
        for (auto& camera : mCamerasPendingRemoval)
            removeCamera(camera);

        mCamerasPendingRemoval.clear();
    }

    void GlobalMap::removeCamera(osg::Camera* cam)
    {
        cam->removeChildren(0, cam->getNumChildren());
        mRoot->removeChild(cam);
    }

    void GlobalMap::asyncWritePng()
    {
        if (mOverlayImage == nullptr)
            return;
        // Use deep copy to avoid any sychronization
        mWritePng = new WritePng(new osg::Image(*mOverlayImage, osg::CopyOp::DEEP_COPY_ALL));
        mWorkQueue->addWorkItem(mWritePng, /*front=*/true);
    }
}
