#include "rtt.hpp"
#include "util.hpp"

#include <cstdlib>

#include <osg/Texture2D>
#include <osg/Texture2DArray>
#include <osgUtil/CullVisitor>

#include <components/debug/debuglog.hpp>
#include <components/sceneutil/color.hpp>
#include <components/sceneutil/depth.hpp>
#include <components/sceneutil/nodecallback.hpp>
#include <components/stereo/multiview.hpp>
#include <components/stereo/stereomanager.hpp>
#include <osg/Image>
#include <cstring>
#include <iostream>

namespace SceneUtil
{
    class CullCallback : public SceneUtil::NodeCallback<CullCallback, RTTNode*, osgUtil::CullVisitor*>
    {
    public:
        void operator()(RTTNode* node, osgUtil::CullVisitor* cv) { node->cull(cv); }
    };

    // TSP_RTT_FINISH_V51
    // Mali resolves a render pass's tiles to memory at the end of the pass. The local
    // map and the character preview render exactly once and then switch themselves
    // off, so a tile that has not resolved by the time the texture is sampled stays
    // wrong forever - flat single-colour blocks where a block header sat, correct
    // pixels where it did resolve. Every-frame RTTs are immune because you are always
    // looking at a finished frame. TSP_RTT_NO_FINISH=1 disables this without a rebuild.
    namespace
    {
        struct TspRttFinish : public osg::Camera::DrawCallback
        {
            void operator()(osg::RenderInfo&) const override { glFinish(); }
        };

        bool tspRttFinishEnabled()
        {
            static const bool v = [] {
                const char* e = std::getenv("TSP_RTT_NO_FINISH");
                const bool on = !(e && e[0] == '1');
                Log(Debug::Info) << "TSP_RTT_FINISH_V51 finish_after_rtt=" << on;
                return on;
            }();
            return v;
        }
    }

    RTTNode::RTTNode(uint32_t textureWidth, uint32_t textureHeight, uint32_t samples, bool generateMipmaps,
        int renderOrderNum, StereoAwareness stereoAwareness, bool addMSAAIntermediateTarget)
        : mTextureWidth(textureWidth)
        , mTextureHeight(textureHeight)
        , mSamples(samples)
        , mGenerateMipmaps(generateMipmaps)
        , mColorBufferInternalFormat(Color::colorInternalFormat())
        , mDepthBufferInternalFormat(SceneUtil::AutoDepth::depthInternalFormat())
        , mRenderOrderNum(renderOrderNum)
        , mStereoAwareness(stereoAwareness)
        , mAddMSAAIntermediateTarget(addMSAAIntermediateTarget)
    {
        addCullCallback(new CullCallback);
        setCullingActive(false);
    }

    RTTNode::~RTTNode()
    {
        for (auto& vdd : mViewDependentDataMap)
        {
            auto* camera = vdd.second->mCamera.get();
            if (camera)
            {
                camera->removeChildren(0, camera->getNumChildren());
            }
        }
        mViewDependentDataMap.clear();
    }

    void RTTNode::cull(osgUtil::CullVisitor* cv)
    {
        auto frameNumber = cv->getFrameStamp()->getFrameNumber();
        auto* vdd = getViewDependentData(cv);
        if (frameNumber > vdd->mFrameNumber)
        {
            apply(vdd->mCamera);
            if (Stereo::getStereo())
            {
                auto& sm = Stereo::Manager::instance();
                if (sm.getEye(cv) == Stereo::Eye::Left)
                    applyLeft(vdd->mCamera);
                if (sm.getEye(cv) == Stereo::Eye::Right)
                    applyRight(vdd->mCamera);
            }
            vdd->mCamera->accept(*cv);
        }
        vdd->mFrameNumber = frameNumber;
    }

    void RTTNode::setColorBufferInternalFormat(GLint internalFormat)
    {
        mColorBufferInternalFormat = internalFormat;
    }

    void RTTNode::setDepthBufferInternalFormat(GLint internalFormat)
    {
        mDepthBufferInternalFormat = internalFormat;
    }

    bool RTTNode::shouldDoPerViewMapping()
    {
        if (mStereoAwareness != StereoAwareness::Aware)
            return false;
        if (!Stereo::getMultiview())
            return true;
        return false;
    }

    bool RTTNode::shouldDoTextureArray()
    {
        if (mStereoAwareness == StereoAwareness::Unaware)
            return false;
        if (Stereo::getMultiview())
            return true;
        return false;
    }

    bool RTTNode::shouldDoTextureView()
    {
        if (mStereoAwareness != StereoAwareness::Unaware_MultiViewShaders)
            return false;
        if (Stereo::getMultiview())
            return true;
        return false;
    }

    osg::Texture2DArray* RTTNode::createTextureArray(GLint internalFormat)
    {
        osg::Texture2DArray* textureArray = new osg::Texture2DArray;
        textureArray->setTextureSize(mTextureWidth, mTextureHeight, 2);
        textureArray->setInternalFormat(internalFormat);
        GLenum sourceFormat = 0;
        GLenum sourceType = 0;
        if (SceneUtil::isDepthFormat(internalFormat))
        {
            SceneUtil::getDepthFormatSourceFormatAndType(internalFormat, sourceFormat, sourceType);
        }
        else
        {
            SceneUtil::getColorFormatSourceFormatAndType(internalFormat, sourceFormat, sourceType);
        }
        // TSP_RTT_INIT_TEXARRAY_V56
        {
            const int tspFmt = textureArray->getInternalFormat();
            const bool tspIsDepth = (tspFmt == 0x1902 || tspFmt == 0x81A5 || tspFmt == 0x81A6
                || tspFmt == 0x88F0 || tspFmt == 0x84F9 || tspFmt == 0x8CAC || tspFmt == 0x8CAD);
            const int tspW = textureArray->getTextureWidth();
            const int tspH = textureArray->getTextureHeight();
            const int tspD = textureArray->getTextureDepth();
            const bool tspOff = (std::getenv("TSP_RTT_NO_INIT") != nullptr);
            static bool tspSaidA = false;
            if (!tspSaidA)
            {
                tspSaidA = true;
                Log(Debug::Warning) << "TSP_RTT_INIT_TEXTURE_V55 path=texarray active=" << (tspOff ? 0 : 1) << " size=" << tspW << "x" << tspH << "x" << tspD << " fmt=0x" << std::hex << tspFmt << std::dec << " depth=" << (tspIsDepth ? 1 : 0);
            }
            if (!tspOff && !tspIsDepth && tspW > 0 && tspH > 0)
            {
                for (int tspL = 0; tspL < (tspD > 0 ? tspD : 1); ++tspL)
                {
                    osg::ref_ptr<osg::Image> tspImgA = new osg::Image;
                    tspImgA->allocateImage(tspW, tspH, 1, GL_RGBA, GL_UNSIGNED_BYTE);
                    std::memset(tspImgA->data(), 0, tspImgA->getTotalSizeInBytes());
                    tspImgA->setInternalTextureFormat(GL_RGBA);
                    tspImgA->setDataVariance(osg::Object::STATIC);
                    textureArray->setImage(tspL, tspImgA);
                }
                textureArray->setUnRefImageDataAfterApply(true);
            }
        }
        textureArray->setSourceFormat(sourceFormat);
        textureArray->setSourceType(sourceType);
        textureArray->setFilter(osg::Texture::MIN_FILTER, osg::Texture::LINEAR);
        textureArray->setFilter(osg::Texture::MAG_FILTER, osg::Texture::LINEAR);
        textureArray->setWrap(osg::Texture::WRAP_S, osg::Texture::CLAMP_TO_EDGE);
        textureArray->setWrap(osg::Texture::WRAP_T, osg::Texture::CLAMP_TO_EDGE);
        textureArray->setWrap(osg::Texture::WRAP_R, osg::Texture::CLAMP_TO_EDGE);
        return textureArray;
    }

    osg::Texture2D* RTTNode::createTexture(GLint internalFormat)
    {
        osg::Texture2D* texture = new osg::Texture2D;
        texture->setTextureSize(mTextureWidth, mTextureHeight);
        texture->setInternalFormat(internalFormat);
        GLenum sourceFormat = 0;
        GLenum sourceType = 0;
        if (SceneUtil::isDepthFormat(internalFormat))
        {
            SceneUtil::getDepthFormatSourceFormatAndType(internalFormat, sourceFormat, sourceType);
        }
        else
        {
            SceneUtil::getColorFormatSourceFormatAndType(internalFormat, sourceFormat, sourceType);
        }
        // TSP_RTT_DYNAMIC_V53 - an RTT colour texture changes without OSG being told,
        // so it must not be advertised as STATIC to consumers that key off variance.
        texture->setDataVariance(osg::Object::DYNAMIC);
        // TSP_RTT_INIT_TEXTURE_V55
        {
            const int tspFmt = texture->getInternalFormat();
            const bool tspIsDepth = (tspFmt == 0x1902 || tspFmt == 0x81A5 || tspFmt == 0x81A6
                || tspFmt == 0x88F0 || tspFmt == 0x84F9 || tspFmt == 0x8CAC || tspFmt == 0x8CAD);
            const int tspW = texture->getTextureWidth();
            const int tspH = texture->getTextureHeight();
            const bool tspOff = (std::getenv("TSP_RTT_NO_INIT") != nullptr);
            static bool tspSaid = false;
            if (!tspSaid)
            {
                tspSaid = true;
                Log(Debug::Warning) << "TSP_RTT_INIT_TEXTURE_V55 TSP_RTT_PATTERN_V57 path=tex2d active=" << (tspOff ? 0 : 1) << " size=" << tspW << "x" << tspH << " fmt=0x" << std::hex << tspFmt << std::dec << " depth=" << (tspIsDepth ? 1 : 0);
            }
            if (!tspOff && !tspIsDepth && tspW > 0 && tspH > 0)
            {
                osg::ref_ptr<osg::Image> tspImg = new osg::Image;
                tspImg->allocateImage(tspW, tspH, 1, GL_RGBA, GL_UNSIGNED_BYTE);
                // TSP_RTT_PATTERN_V57 - a readable fill, so an unwritten region is
                // visually distinct from a region that was rendered into.
                {
                    unsigned char* tspD = tspImg->data();
                    // TSP_RTT_INIT_PATTERN=1 restores the diagnostic checkerboard.
                    const bool tspZero = (std::getenv("TSP_RTT_INIT_PATTERN") == nullptr);
                    for (int tspY = 0; tspY < tspH; ++tspY)
                    {
                        for (int tspX = 0; tspX < tspW; ++tspX)
                        {
                            unsigned char* tspP = tspD + ((size_t)tspY * (size_t)tspW + (size_t)tspX) * 4;
                            if (tspZero) { tspP[0] = 0; tspP[1] = 0; tspP[2] = 0; tspP[3] = 0; continue; }
                            if (tspY < 8) { tspP[0] = 0; tspP[1] = 255; tspP[2] = 0; tspP[3] = 255; continue; }
                            const int tspB = (((tspX >> 5) + (tspY >> 5)) & 1);
                            tspP[0] = tspB ? 255 : 0;
                            tspP[1] = 0;
                            tspP[2] = tspB ? 255 : 128;
                            tspP[3] = 255;
                        }
                    }
                }
                tspImg->setInternalTextureFormat(GL_RGBA);
                tspImg->setDataVariance(osg::Object::STATIC); // TSP_RTT_INIT_STATIC
                texture->setUnRefImageDataAfterApply(true);
                texture->setImage(tspImg);
            }
        }
        texture->setSourceFormat(sourceFormat);
        texture->setSourceType(sourceType);
        texture->setFilter(osg::Texture::MIN_FILTER, osg::Texture::LINEAR);
        texture->setFilter(osg::Texture::MAG_FILTER, osg::Texture::LINEAR);
        texture->setWrap(osg::Texture::WRAP_S, osg::Texture::CLAMP_TO_EDGE);
        texture->setWrap(osg::Texture::WRAP_T, osg::Texture::CLAMP_TO_EDGE);
        texture->setWrap(osg::Texture::WRAP_R, osg::Texture::CLAMP_TO_EDGE);
        return texture;
    }

    osg::Texture* RTTNode::getColorTexture(osgUtil::CullVisitor* cv)
    {
        return getViewDependentData(cv)->mColorTexture;
    }

    osg::Texture* RTTNode::getDepthTexture(osgUtil::CullVisitor* cv)
    {
        return getViewDependentData(cv)->mDepthTexture;
    }

    osg::Camera* RTTNode::getCamera(osgUtil::CullVisitor* cv)
    {
        return getViewDependentData(cv)->mCamera;
    }

    RTTNode::ViewDependentData* RTTNode::getViewDependentData(osgUtil::CullVisitor* cv)
    {
        if (!shouldDoPerViewMapping())
            // Always setting it to null is an easy way to disable per-view mapping when mDoPerViewMapping is false.
            // This is safe since the visitor is never dereferenced.
            cv = nullptr;

        if (mViewDependentDataMap.count(cv) == 0)
        {
            auto camera = new osg::Camera();
            auto vdd = std::make_shared<ViewDependentData>();
            mViewDependentDataMap[cv] = vdd;
            mViewDependentDataMap[cv]->mCamera = camera;

            camera->setRenderOrder(osg::Camera::PRE_RENDER, mRenderOrderNum);
            camera->setClearMask(GL_DEPTH_BUFFER_BIT | GL_COLOR_BUFFER_BIT | GL_STENCIL_BUFFER_BIT);
            camera->setRenderTargetImplementation(osg::Camera::FRAME_BUFFER_OBJECT);
            camera->setViewport(0, 0, mTextureWidth, mTextureHeight);
            SceneUtil::setCameraClearDepth(camera);

            setDefaults(camera);
            if (tspRttFinishEnabled())          // TSP_RTT_FINISH_V51
                camera->setFinalDrawCallback(new TspRttFinish);

            if (camera->getBufferAttachmentMap().count(osg::Camera::COLOR_BUFFER))
                vdd->mColorTexture = camera->getBufferAttachmentMap()[osg::Camera::COLOR_BUFFER]._texture;
            if (camera->getBufferAttachmentMap().count(osg::Camera::PACKED_DEPTH_STENCIL_BUFFER))
                vdd->mDepthTexture
                    = camera->getBufferAttachmentMap()[osg::Camera::PACKED_DEPTH_STENCIL_BUFFER]._texture;

            if (shouldDoTextureArray())
            {
                // Create any buffer attachments not added in setDefaults
                if (camera->getBufferAttachmentMap().count(osg::Camera::COLOR_BUFFER) == 0)
                {
                    vdd->mColorTexture = createTextureArray(mColorBufferInternalFormat);
                    camera->attach(osg::Camera::COLOR_BUFFER, vdd->mColorTexture, 0,
                        Stereo::osgFaceControlledByMultiviewShader(), mGenerateMipmaps, mSamples);
                    SceneUtil::attachAlphaToCoverageFriendlyFramebufferToCamera(camera, osg::Camera::COLOR_BUFFER,
                        vdd->mColorTexture, 0, Stereo::osgFaceControlledByMultiviewShader(), mGenerateMipmaps,
                        mAddMSAAIntermediateTarget);
                }

                if (camera->getBufferAttachmentMap().count(osg::Camera::PACKED_DEPTH_STENCIL_BUFFER) == 0)
                {
                    vdd->mDepthTexture = createTextureArray(mDepthBufferInternalFormat);
                    camera->attach(osg::Camera::PACKED_DEPTH_STENCIL_BUFFER, vdd->mDepthTexture, 0,
                        Stereo::osgFaceControlledByMultiviewShader(), false, mSamples);
                }

                if (shouldDoTextureView())
                {
                    // In this case, shaders being set to multiview forces us to render to a multiview framebuffer even
                    // though we don't need that. This forces us to make Texture2DArray. To make this possible to sample
                    // as a Texture2D, make a Texture2D view into the texture array.
                    vdd->mColorTexture = Stereo::createTextureView_Texture2DFromTexture2DArray(
                        static_cast<osg::Texture2DArray*>(vdd->mColorTexture.get()), 0);
                    vdd->mDepthTexture = Stereo::createTextureView_Texture2DFromTexture2DArray(
                        static_cast<osg::Texture2DArray*>(vdd->mDepthTexture.get()), 0);
                }
            }
            else
            {
                // Create any buffer attachments not added in setDefaults
                if (camera->getBufferAttachmentMap().count(osg::Camera::COLOR_BUFFER) == 0)
                {
                    vdd->mColorTexture = createTexture(mColorBufferInternalFormat);
                    camera->attach(osg::Camera::COLOR_BUFFER, vdd->mColorTexture, 0, 0, mGenerateMipmaps, mSamples);

                    // TSP_RTT_NO_MSAA_RESOLVE_V49
                    // An MSAA intermediate target only makes sense when there are
                    // samples to resolve. With antialiasing off, mSamples is 0 or 1
                    // and this still builds a multisampled renderbuffer and resolves
                    // through it - on gl4es that goes via
                    // GL_EXT_multisampled_render_to_texture, and a resolve that does
                    // not land leaves the colour texture holding whatever was in that
                    // memory. That is the black / white-with-coloured-blocks / rainbow
                    // noise on the HUD compass and the inventory doll, and why it
                    // differs per location and per load.
                    //
                    // Sky and water read their RTTs through scene shaders and come out
                    // fine; the local map and character preview are the two consumed by
                    // MyGUI, and they are also the ones that ask for this target.
                    const bool tspWantMsaaTarget = mAddMSAAIntermediateTarget && mSamples > 1;
                    SceneUtil::attachAlphaToCoverageFriendlyFramebufferToCamera(camera, osg::Camera::COLOR_BUFFER,
                        vdd->mColorTexture, 0, 0, mGenerateMipmaps, tspWantMsaaTarget);
                }

                if (camera->getBufferAttachmentMap().count(osg::Camera::PACKED_DEPTH_STENCIL_BUFFER) == 0)
                {
                    // TSP_RTT_IMPLICIT_DEPTH_V50
                    // Depth was attached here as a PACKED_DEPTH_STENCIL osg::Texture2D at
                    // GL_DEPTH24_STENCIL8. gl4es accepts that, reports the FBO complete and
                    // OSG logs nothing - but the result is undefined, and both consumers
                    // clear and depth-test against it. That is the local map and the
                    // character preview coming out black / partly right / wrong-coloured /
                    // noisy, differently on every load.
                    //
                    // globalmap.cpp already records the same wall on this device under
                    // TSP_GLOBALMAP_DEPTH: letting OSG attach its own implicit depth buffer
                    // is what made that FBO validate, and the global map is the only RTT
                    // here that displays correctly. Do the same - keep the texture so
                    // getDepthTexture() never returns null, but do not attach it.
                    static const bool tspExplicitDepth = [] {
                        const char* e = std::getenv("TSP_RTT_EXPLICIT_DEPTH");
                        const bool v = e && e[0] == '1';
                        Log(Debug::Info) << "TSP_RTT_IMPLICIT_DEPTH_V50 explicit_depth_attachment=" << v;
                        return v;
                    }();
                    vdd->mDepthTexture = createTexture(mDepthBufferInternalFormat);
                    if (tspExplicitDepth)
                        camera->attach(
                            osg::Camera::PACKED_DEPTH_STENCIL_BUFFER, vdd->mDepthTexture, 0, 0, false, mSamples);
                }
            }

            // OSG appears not to properly initialize this metadata. So when multisampling is enabled, OSG will use
            // incorrect formats for the resolve buffers.
            if (mSamples > 1)
            {
                camera->getBufferAttachmentMap()[osg::Camera::COLOR_BUFFER]._internalFormat
                    = mColorBufferInternalFormat;
                camera->getBufferAttachmentMap()[osg::Camera::COLOR_BUFFER]._mipMapGeneration = mGenerateMipmaps;
                camera->getBufferAttachmentMap()[osg::Camera::PACKED_DEPTH_STENCIL_BUFFER]._internalFormat
                    = mDepthBufferInternalFormat;
                camera->getBufferAttachmentMap()[osg::Camera::PACKED_DEPTH_STENCIL_BUFFER]._mipMapGeneration
                    = mGenerateMipmaps;
            }
        }

        return mViewDependentDataMap[cv].get();
    }
}
