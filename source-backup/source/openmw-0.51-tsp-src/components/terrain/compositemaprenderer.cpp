#include "compositemaprenderer.hpp"

#include <osg/FrameBufferObject>
#include <osg/RenderInfo>
#include <osg/Texture2D>

#include <algorithm>

namespace Terrain
{

    // TSP_COMPOS_BUILD: greppable in the deployed binary, so "which composite map
    // generation is actually running" stops being a guess. Bump the string whenever
    // this file changes. The V8 claim is literal and asserted at patch time: this
    // tree has no TspDrainEnd and no RAII guard in drawImplementation, so no GL call
    // is issued on a frame with nothing to compile.
    const char* volatile gBuildTag = "TSP_COMPOS_BUILD_V8_NO_DRAINEND";

    CompositeMapRenderer::CompositeMapRenderer()
        : mTargetFrameRate(120)
        , mMinimumTimeAvailable(0.0025)
    {
        setSupportsDisplayList(false);
        setCullingActive(false);

        mFBO = new osg::FrameBufferObject;
    }

    CompositeMapRenderer::~CompositeMapRenderer() = default;

    void CompositeMapRenderer::drawImplementation(osg::RenderInfo& renderInfo) const
    {
        double dt = mTimer.time_s();
        dt = std::min(dt, 0.2);
        mTimer.setStartTick();
        double targetFrameTime = 1.0 / static_cast<double>(mTargetFrameRate);
        double conservativeTimeRatio(0.75);
        double availableTime = std::max((targetFrameTime - dt) * conservativeTimeRatio, mMinimumTimeAvailable);

        std::lock_guard<std::mutex> lock(mMutex);

        if (mImmediateCompileSet.empty() && mCompileSet.empty())
            return;

        while (!mImmediateCompileSet.empty())
        {
            osg::ref_ptr<CompositeMap> node = *mImmediateCompileSet.begin();
            mImmediateCompileSet.erase(node);

            mMutex.unlock();
            compile(*node, renderInfo);
            mMutex.lock();
        }

        const auto deadline = std::chrono::steady_clock::now() + std::chrono::duration<double>(availableTime);
        while (!mCompileSet.empty() && std::chrono::steady_clock::now() < deadline)
        {
            osg::ref_ptr<CompositeMap> node = *mCompileSet.begin();
            mCompileSet.erase(node);

            mMutex.unlock();
            compile(*node, renderInfo);
            mMutex.lock();

            if (node->mCompiled < node->mDrawables.size())
            {
                // We did not compile the map fully.
                // Place it back to queue to continue work in the next time.
                mCompileSet.insert(node);
            }
        }
        mTimer.setStartTick();
    }

    void CompositeMapRenderer::compile(CompositeMap& compositeMap, osg::RenderInfo& renderInfo) const
    {
        // if there are no more external references we can assume the texture is no longer required
        if (compositeMap.mTexture->referenceCount() <= 1)
        {
            compositeMap.mCompiled = compositeMap.mDrawables.size();
            return;
        }

        osg::Timer timer;
        osg::State& state = *renderInfo.getState();
        osg::GLExtensions* ext = state.get<osg::GLExtensions>();

        if (!mFBO)
            return;

        if (!ext->isFrameBufferObjectSupported)
            return;

        osg::FrameBufferAttachment attach(compositeMap.mTexture);
        mFBO->setAttachment(osg::Camera::COLOR_BUFFER, attach);

        // TSP_COMPOSITE_DEPTH_RB_V48
        // Upstream attaches COLOUR only. A colour-only FBO is legal, but on this
        // Mali/gl4es path it is not the fast path - the driver takes a different
        // route for an incomplete-looking attachment set, and every composite map
        // pays for it. Give the FBO a real depth renderbuffer, cached across calls
        // and rebuilt only when the composite map size changes, so the cost is one
        // allocation per size rather than one per map.
        //
        // DEPTH_COMPONENT16 deliberately: composite maps never need stencil, and 16
        // bits is the one depth renderbuffer format guaranteed everywhere on GLES2.
        static osg::ref_ptr<osg::RenderBuffer> tspDepthRB;
        static int tspDepthW = 0;
        static int tspDepthH = 0;

        const int tspW = static_cast<int>(compositeMap.mTexture->getTextureWidth());
        const int tspH = static_cast<int>(compositeMap.mTexture->getTextureHeight());

        if (tspW > 0 && tspH > 0)
        {
            if (!tspDepthRB || tspDepthW != tspW || tspDepthH != tspH)
            {
                tspDepthRB = new osg::RenderBuffer(tspW, tspH, GL_DEPTH_COMPONENT16);
                tspDepthW = tspW;
                tspDepthH = tspH;
            }
            mFBO->setAttachment(osg::Camera::DEPTH_BUFFER, osg::FrameBufferAttachment(tspDepthRB));
        }

        mFBO->apply(state, osg::FrameBufferObject::DRAW_FRAMEBUFFER);

        GLenum status = ext->glCheckFramebufferStatus(GL_FRAMEBUFFER_EXT);

        if (status != GL_FRAMEBUFFER_COMPLETE_EXT)
        {
            GLuint fboId = state.getGraphicsContext() ? state.getGraphicsContext()->getDefaultFboId() : 0;
            ext->glBindFramebuffer(GL_FRAMEBUFFER_EXT, fboId);
            OSG_ALWAYS << "Error attaching FBO" << std::endl;
            return;
        }

        // inform State that Texture attribute has changed due to compiling of FBO texture
        // should OSG be doing this on its own?
        state.haveAppliedTextureAttribute(state.getActiveTextureUnit(), osg::StateAttribute::TEXTURE);

        for (size_t i = compositeMap.mCompiled; i < compositeMap.mDrawables.size(); ++i)
        {
            osg::Drawable* drw = compositeMap.mDrawables[i];
            osg::StateSet* stateset = drw->getStateSet();

            if (stateset)
                renderInfo.getState()->pushStateSet(stateset);

            renderInfo.getState()->apply();

            glViewport(0, 0, compositeMap.mTexture->getTextureWidth(), compositeMap.mTexture->getTextureHeight());
            drw->drawImplementation(renderInfo);

            if (stateset)
                renderInfo.getState()->popStateSet();

            ++compositeMap.mCompiled;

            compositeMap.mDrawables[i] = nullptr;
        }
        if (compositeMap.mCompiled == compositeMap.mDrawables.size())
            compositeMap.mDrawables = std::vector<osg::ref_ptr<osg::Drawable>>();

        state.haveAppliedAttribute(osg::StateAttribute::VIEWPORT);

        GLuint fboId = state.getGraphicsContext() ? state.getGraphicsContext()->getDefaultFboId() : 0;
        ext->glBindFramebuffer(GL_FRAMEBUFFER_EXT, fboId);
    }

    void CompositeMapRenderer::setMinimumTimeAvailableForCompile(double time)
    {
        mMinimumTimeAvailable = time;
    }

    void CompositeMapRenderer::setTargetFrameRate(float framerate)
    {
        mTargetFrameRate = framerate;
    }

    void CompositeMapRenderer::addCompositeMap(CompositeMap* compositeMap, bool immediate)
    {
        std::lock_guard<std::mutex> lock(mMutex);
        if (immediate)
            mImmediateCompileSet.insert(compositeMap);
        else
            mCompileSet.insert(compositeMap);
    }

    void CompositeMapRenderer::setImmediate(CompositeMap* compositeMap)
    {
        std::lock_guard<std::mutex> lock(mMutex);
        CompileSet::iterator found = mCompileSet.find(compositeMap);
        if (found == mCompileSet.end())
            return;
        else
        {
            mImmediateCompileSet.insert(compositeMap);
            mCompileSet.erase(found);
        }
    }

    size_t CompositeMapRenderer::getCompileSetSize() const
    {
        std::lock_guard<std::mutex> lock(mMutex);
        return mCompileSet.size();
    }

    CompositeMap::CompositeMap()
        : mCompiled(0)
    {
    }

    CompositeMap::~CompositeMap() {}

}
