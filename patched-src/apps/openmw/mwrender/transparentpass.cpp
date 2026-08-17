#include "transparentpass.hpp"

#include <osg/AlphaFunc>
#include <osg/BlendFunc>
#include <osg/Material>
#include <osg/Texture2D>
#include <osg/Texture2DArray>

#include <osgUtil/RenderStage>

#include <components/sceneutil/depth.hpp>
#include <components/shader/shadermanager.hpp>
#include <components/stereo/multiview.hpp>
#include <components/stereo/stereomanager.hpp>

#include "vismask.hpp"

namespace MWRender
{
    TransparentDepthBinCallback::TransparentDepthBinCallback(Shader::ShaderManager& shaderManager, bool postPass)
        : mStateSet(new osg::StateSet)
        , mPostPass(postPass)
    {
        osg::ref_ptr<osg::Image> image = new osg::Image;
        image->allocateImage(1, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE);
        image->setColor(osg::Vec4(1, 1, 1, 1), 0, 0);

        osg::ref_ptr<osg::Texture2D> dummyTexture = new osg::Texture2D(image);
        dummyTexture->setWrap(osg::Texture::WRAP_S, osg::Texture::CLAMP_TO_EDGE);
        dummyTexture->setWrap(osg::Texture::WRAP_T, osg::Texture::CLAMP_TO_EDGE);

        constexpr osg::StateAttribute::OverrideValue modeOff = osg::StateAttribute::OFF | osg::StateAttribute::OVERRIDE;
        constexpr osg::StateAttribute::OverrideValue modeOn = osg::StateAttribute::ON | osg::StateAttribute::OVERRIDE;

        mStateSet->setTextureAttributeAndModes(0, dummyTexture);

        Shader::ShaderManager::DefineMap defines;
        Stereo::shaderStereoDefines(defines);

        mStateSet->setAttributeAndModes(new osg::BlendFunc, modeOff);
        mStateSet->setAttributeAndModes(shaderManager.getProgram("depthclipped", defines), modeOn);
        mStateSet->setAttributeAndModes(new SceneUtil::AutoDepth, modeOn);

        for (unsigned int unit = 1; unit < 8; ++unit)
            mStateSet->setTextureMode(unit, GL_TEXTURE_2D, modeOff);
    }

    void TransparentDepthBinCallback::drawImplementation(
        osgUtil::RenderBin* bin, osg::RenderInfo& renderInfo, osgUtil::RenderLeaf*& previous)
    {
        osg::State& state = *renderInfo.getState();
        // TSP_GL4ES_NO_DEPTH_BLIT_EXTENSION_OBJECT_051
        // No GLExtensions depth-blit call is needed on the GL4ES path.

        bool validFbo = false;
        unsigned int frameId = state.getFrameStamp()->getFrameNumber() % 2;

        const auto& fbo = mFbo[frameId];
        const auto& msaaFbo = mMsaaFbo[frameId];
        const auto& opaqueFbo = mOpaqueFbo[frameId];

        if (bin->getStage()->getMultisampleResolveFramebufferObject()
            && bin->getStage()->getMultisampleResolveFramebufferObject() == fbo)
            validFbo = true;
        else if (bin->getStage()->getFrameBufferObject()
            && (bin->getStage()->getFrameBufferObject() == fbo || bin->getStage()->getFrameBufferObject() == msaaFbo))
            validFbo = true;

        if (!validFbo)
        {
            bin->drawImplementation(renderInfo, previous);
            return;
        }

        const osg::Texture* tex
            = opaqueFbo->getAttachment(osg::FrameBufferObject::BufferComponent::PACKED_DEPTH_STENCIL_BUFFER)
                  .getTexture();

        if (Stereo::getMultiview())
        {
            if (!mMultiviewResolve[frameId])
            {
                mMultiviewResolve[frameId] = std::make_unique<Stereo::MultiviewFramebufferResolve>(
                    msaaFbo ? msaaFbo : fbo, opaqueFbo, GL_DEPTH_BUFFER_BIT);
            }
            else
            {
                mMultiviewResolve[frameId]->setResolveFbo(opaqueFbo);
                mMultiviewResolve[frameId]->setMsaaFbo(msaaFbo ? msaaFbo : fbo);
            }
            mMultiviewResolve[frameId]->resolveImplementation(state);
        }
        else
        {
            opaqueFbo->apply(state, osg::FrameBufferObject::DRAW_FRAMEBUFFER);
            // TSP_GL4ES_SKIP_DEPTH_BLIT_051
            // The primary scene depth texture is used elsewhere; do not depth-blit on GL4ES.
            glClear(GL_DEPTH_BUFFER_BIT | GL_STENCIL_BUFFER_BIT);
        }

        msaaFbo ? msaaFbo->apply(state, osg::FrameBufferObject::DRAW_FRAMEBUFFER)
                : fbo->apply(state, osg::FrameBufferObject::DRAW_FRAMEBUFFER);

        // draws scene into primary attachments
        bin->drawImplementation(renderInfo, previous);

        if (!mPostPass)
            return;

        // TSP_GL4ES_KEEP_PRIMARY_FOR_TRANSPARENT_POSTPASS_051
        // Leave the primary FBO bound for this pass on GL4ES.

        // draw transparent post-pass to populate a postprocess friendly depth texture with alpha-clipped geometry

        unsigned int numToPop = previous ? osgUtil::StateGraph::numToPop(previous->_parent) : 0;
        if (numToPop > 1)
            numToPop--;
        unsigned int insertStateSetPosition = state.getStateSetStackSize() - numToPop;

        state.insertStateSet(insertStateSetPosition, mStateSet);
        for (auto rit = bin->getRenderLeafList().begin(); rit != bin->getRenderLeafList().end(); rit++)
        {
            osgUtil::RenderLeaf* rl = *rit;
            const osg::StateSet* ss = rl->_parent->getStateSet();

            if (rl->_drawable->getNodeMask() == Mask_ParticleSystem)
                continue;

            if (ss->getAttribute(osg::StateAttribute::MATERIAL))
            {
                const osg::Material* mat
                    = static_cast<const osg::Material*>(ss->getAttribute(osg::StateAttribute::MATERIAL));
                if (mat->getDiffuse(osg::Material::FRONT).a() < 0.5)
                    continue;
            }

            rl->render(renderInfo, previous);
            previous = rl;
        }
        state.removeStateSet(insertStateSetPosition);

        msaaFbo ? msaaFbo->apply(state, osg::FrameBufferObject::DRAW_FRAMEBUFFER)
                : fbo->apply(state, osg::FrameBufferObject::DRAW_FRAMEBUFFER);
        state.checkGLErrors("after TransparentDepthBinCallback::drawImplementation");
    }
}
