#include "imagemanager.hpp"

#include <cassert>
#include <osgDB/Registry>

#include <components/debug/debuglog.hpp>
#include <components/misc/pathhelpers.hpp>
#include <components/sceneutil/glextensions.hpp>
#include <components/vfs/manager.hpp>
#include <components/vfs/pathutil.hpp>

#include "objectcache.hpp"

#ifdef OSG_LIBRARY_STATIC
// This list of plugins should match with the list in the top-level CMakelists.txt.
USE_OSGPLUGIN(png)
USE_OSGPLUGIN(tga)
USE_OSGPLUGIN(dds)
USE_OSGPLUGIN(jpeg)
USE_OSGPLUGIN(bmp)
USE_OSGPLUGIN(osg)
USE_SERIALIZER_WRAPPER_LIBRARY(osg)
#endif

namespace
{

    osg::ref_ptr<osg::Image> createWarningImage()
    {
        osg::ref_ptr<osg::Image> warningImage = new osg::Image;

        int width = 8, height = 8;
        warningImage->allocateImage(width, height, 1, GL_RGB, GL_UNSIGNED_BYTE);
        assert(warningImage->isDataContiguous());
        unsigned char* data = warningImage->data();
        for (int i = 0; i < width * height; ++i)
        {
            data[3 * i] = (255);
            data[3 * i + 1] = (0);
            data[3 * i + 2] = (255);
        }
        return warningImage;
    }

    bool isS3TC(osg::Image* image)
    {
        switch (image->getPixelFormat())
        {
            case GL_COMPRESSED_RGB_S3TC_DXT1_EXT:
            case GL_COMPRESSED_RGBA_S3TC_DXT1_EXT:
            case GL_COMPRESSED_RGBA_S3TC_DXT3_EXT:
            case GL_COMPRESSED_RGBA_S3TC_DXT5_EXT:
                return true;
        }
        return false;
    }

    bool checkSupported(osg::Image* image)
    {
        // not bothering with checks for other compression formats right now
        if (!isS3TC(image))
            return true;

        // hashtag yolo (CS might not have context when loading assets)
        if (!SceneUtil::glExtensionsReady())
            return true;

        return SceneUtil::getGLExtensions().isTextureCompressionS3TCSupported;
    }

}

namespace Resource
{

    ImageManager::ImageManager(const VFS::Manager* vfs, double expiryDelay)
        : ResourceManager(vfs, expiryDelay)
        , mWarningImage(createWarningImage())
        , mOptions(new osgDB::Options("dds_dxt1_detect_rgba ignoreTga2Fields"))
    {
    }

    ImageManager::~ImageManager() {}

    // TSP_BLANKTEX_V1 - a degenerate name means "no texture specified", not "broken
    // texture". Drawing nothing beats drawing magenta: a blank icon slot, a cloudless
    // sky. A real filename that fails to load still gets mWarningImage, because that
    // is a genuine asset error and must stay visible.
    static osg::Image* tspBlankImage()
    {
        static const osg::ref_ptr<osg::Image> img = [] {
            osg::ref_ptr<osg::Image> i = new osg::Image;
            i->allocateImage(1, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE);
            unsigned char* d = i->data();
            d[0] = 0; d[1] = 0; d[2] = 0; d[3] = 0;
            i->setInternalTextureFormat(GL_RGBA);
            return i;
        }();
        return img.get();
    }

    osg::ref_ptr<osg::Image> ImageManager::getImage(VFS::Path::NormalizedView path, bool disableFlip)
    {
        // TSP_WARNCACHE_V1 (B1) - a path with no filename part can never resolve.
        // Return the warning image but do NOT cache it, so one bad frame cannot bind
        // a real path to magenta for the rest of the process.
        {
            const std::string_view tspVal = path.value();
            if (tspVal.empty() || tspVal.back() == '/')
            {
                static int tspDegenSeen = 0;
                if (tspDegenSeen < 8)
                {
                    ++tspDegenSeen;
                    Log(Debug::Warning) << "TSP_WARNCACHE_V1 degenerate image path \"" << tspVal
                                        << "\" - TSP_BLANKTEX_V1 returning a blank 1x1, not caching it";
                }
                return tspBlankImage();
            }
        }

        osg::ref_ptr<osg::Object> obj = mCache->getRefFromObjectCache(path);
        if (obj)
        {
            // TSP_WARNCACHE_V1 (B2) - a cached warning image is otherwise completely
            // silent: getImage logs once when the load fails and never again, and with
            // TSP_NO_LOADPURGE=1 the entry survives every save load. This is the only
            // way to see a texture that is still being served magenta.
            osg::Image* tspCached = static_cast<osg::Image*>(obj.get());
            if (tspCached == mWarningImage.get())
            {
                static int tspWarnHits = 0;
                if (tspWarnHits < 16)
                {
                    ++tspWarnHits;
                    Log(Debug::Warning) << "TSP_WARNCACHE_V1 serving CACHED warning image for " << path;
                }
            }
            return osg::ref_ptr<osg::Image>(tspCached);
        }
        else
        {
            Files::IStreamPtr stream;
            try
            {
                stream = mVFS->get(path);
            }
            catch (std::exception& e)
            {
                Log(Debug::Error) << "Failed to open image: " << e.what();
                mCache->addEntryToObjectCache(path.value(), mWarningImage);
                return mWarningImage;
            }

            const std::string ext(Misc::getFileExtension(path.value()));
            osgDB::ReaderWriter* reader = osgDB::Registry::instance()->getReaderWriterForExtension(ext);
            if (!reader)
            {
                Log(Debug::Error) << "Error loading " << path << ": no readerwriter for '" << ext << "' found";
                mCache->addEntryToObjectCache(path.value(), mWarningImage);
                return mWarningImage;
            }

            bool killAlpha = false;
            if (reader->supportedExtensions().count("tga"))
            {
                // Morrowind ignores the alpha channel of 16bpp TGA files even when the header says not to
                unsigned char header[18];
                stream->read((char*)header, 18);
                if (stream->gcount() != 18)
                {
                    Log(Debug::Error) << "Error loading " << path << ": couldn't read TGA header";
                    mCache->addEntryToObjectCache(path.value(), mWarningImage);
                    return mWarningImage;
                }
                int type = header[2];
                int depth;
                if (type == 1 || type == 9)
                    depth = header[7];
                else
                    depth = header[16];
                int alphaBPP = header[17] & 0x0F;
                killAlpha = depth == 16 && alphaBPP == 1;
                stream->seekg(0);
            }

            osgDB::ReaderWriter::ReadResult result = reader->readImage(*stream, mOptions);
            if (!result.success())
            {
                Log(Debug::Error) << "Error loading " << path << ": " << result.message() << " code "
                                  << result.status();
                mCache->addEntryToObjectCache(path.value(), mWarningImage);
                return mWarningImage;
            }

            osg::ref_ptr<osg::Image> image = result.getImage();

            image->setFileName(std::string(path.value()));
            if (!checkSupported(image))
            {
                static bool uncompress = (getenv("OPENMW_DECOMPRESS_TEXTURES") != nullptr);
                if (!uncompress)
                {
                    Log(Debug::Error) << "Error loading " << path << ": no S3TC texture compression support installed";
                    mCache->addEntryToObjectCache(path.value(), mWarningImage);
                    return mWarningImage;
                }
                else
                {
                    // decompress texture in software if not supported by GPU
                    // requires update to getColor() to be released with OSG 3.6
                    osg::ref_ptr<osg::Image> newImage = new osg::Image;
                    newImage->setFileName(image->getFileName());
                    newImage->setOrigin(image->getOrigin());
                    newImage->allocateImage(image->s(), image->t(), image->r(),
                        image->isImageTranslucent() ? GL_RGBA : GL_RGB, GL_UNSIGNED_BYTE);
                    for (int s = 0; s < image->s(); ++s)
                        for (int t = 0; t < image->t(); ++t)
                            for (int r = 0; r < image->r(); ++r)
                                newImage->setColor(image->getColor(s, t, r), s, t, r);
                    image = newImage;
                }
            }
            else if (killAlpha)
            {
                osg::ref_ptr<osg::Image> newImage = new osg::Image;
                newImage->setFileName(image->getFileName());
                newImage->setOrigin(image->getOrigin());
                newImage->allocateImage(image->s(), image->t(), image->r(), GL_RGB, GL_UNSIGNED_BYTE);
                // OSG just won't write the alpha as there's nowhere to put it.
                for (int s = 0; s < image->s(); ++s)
                    for (int t = 0; t < image->t(); ++t)
                        for (int r = 0; r < image->r(); ++r)
                            newImage->setColor(image->getColor(s, t, r), s, t, r);
                image = newImage;
            }

            // OSG might not set the right origin for DDS
            // TSP_KTX_V1 - the converter preserves DDS row order, so a .ktx is top-left too.
            // Without this the flip guard below rejects it as a non-S3TC compressed image
            // and paints the magenta warning texture instead.
            if (ext == "dds" || ext == "ktx")
                image->setOrigin(osg::Image::TOP_LEFT);

            // Convert the image to the convention we expect
            if (image->getOrigin() == osg::Image::BOTTOM_LEFT && !disableFlip)
            {
                if (image->isCompressed() && !isS3TC(image))
                {
                    // This is most likely a KTX texture that OSG can't flip
                    // We don't want it to be corrupted or displayed incorrectly, so bail
                    // OSGoS *can* flip RGTC, but we can't verify that (yet?)
                    Log(Debug::Error) << "Error loading " << path << ": cannot flip non-S3TC compressed texture";
                    mCache->addEntryToObjectCache(path.value(), mWarningImage);
                    return mWarningImage;
                }

                image->flipVertical();
                image->setOrigin(osg::Image::TOP_LEFT);
            }

            // TSP_KTX_V1 - first few only, enough to prove the format and mip chain arrived intact.
            if (ext == "ktx")
            {
                static int tspKtxLogged = 0;
                if (tspKtxLogged < 8)
                {
                    ++tspKtxLogged;
                    Log(Debug::Warning)
                        << "TSP_KTX_V1 loaded " << path << " compressed=" << image->isCompressed()
                        << " fmt=" << image->getPixelFormat() << " " << image->s() << "x" << image->t()
                        << " levels=" << image->getNumMipmapLevels()
                        << " bytes=" << image->getTotalSizeInBytesIncludingMipmaps();
                }
            }

            mCache->addEntryToObjectCache(path.value(), image);
            return image;
        }
    }

    osg::Image* ImageManager::getWarningImage()
    {
        return mWarningImage;
    }

    void ImageManager::reportStats(unsigned int frameNumber, osg::Stats* stats) const
    {
        Resource::reportStats("Image", frameNumber, mCache->getStats(), *stats);
    }

}
