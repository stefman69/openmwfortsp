#ifndef OPENMW_COMPONENTS_SHADERMANAGER_H
#define OPENMW_COMPONENTS_SHADERMANAGER_H

#include <array>
#include <filesystem>
#include <map>
#include <memory>
#include <mutex>
#include <optional>
#include <set>
#include <string>
#include <vector>

#include <osg/Program>
#include <osg/Group>
#include <osgUtil/IncrementalCompileOperation>
#include <osg/Shader>
#include <osg/ref_ptr>

namespace osgViewer
{
    class Viewer;
}

namespace Shader
{
    struct HotReloadManager;
    /// @brief Reads shader template files and turns them into a concrete shader, based on a list of define's.
    /// @par Shader templates can get the value of a define with the syntax @define.
    class ShaderManager
    {
    public:
        friend HotReloadManager;
        ShaderManager();
        ~ShaderManager();

        void setShaderPath(const std::filesystem::path& path);

        typedef std::map<std::string, std::string> DefineMap;

        /// Create or retrieve a shader instance.
        /// @param templateName The path of the shader template.
        /// @param defines Define values that can be retrieved by the shader template.
        /// @param shaderType The type of shader (usually vertex or fragment shader).
        /// @note May return nullptr on failure.
        /// @note Thread safe.
        osg::ref_ptr<osg::Shader> getShader(std::string templateName, const DefineMap& defines = {},
            std::optional<osg::Shader::Type> type = std::nullopt);

        osg::ref_ptr<osg::Program> getProgram(const std::string& templateName, const DefineMap& defines = {},
            const osg::Program* programTemplate = nullptr);

        osg::ref_ptr<osg::Program> getProgram(osg::ref_ptr<osg::Shader> vertexShader,
            osg::ref_ptr<osg::Shader> fragmentShader, const osg::Program* programTemplate = nullptr);

        const osg::Program* getProgramTemplate() const { return mProgramTemplate; }
        /* TSP_SHADER_WARMDRAW: OSG links a program lazily and OSG's incremental
           compile only ever links it - Mali defers ~236ms more until the first
           real draw. This group holds a tiny throwaway drawable per new program
           so that draw happens during the loading screen instead of mid-combat.
           RenderingManager attaches it to the scene root. */
        osg::Group* getWarmupGroup() { return mWarmupGroup.get(); }

        /* TSP_VARIANT_PRECOMPILE_V1: the warm-draw and ICO machinery above only
           fires for a program that something has already asked for. A define
           permutation whose first use is mid-combat - blood spray, a spell
           effect, a decal - is therefore created during combat and costs ~165ms
           (98 link + 38 gl4es GLSL convert + 30 compile) right then.
           tspRecordVariant appends every permutation ever requested to a file;
           tspPrecompileVariants replays the whole file on each loading screen,
           before the TSP_WARMDRAW_GATE drain in LoadingScreen::loadingOff().
           Only permutations that used the DEFAULT program template are replayed:
           mPrograms is keyed on the shader pair alone, so replaying one that
           wants a custom template would hand that caller our program instead. */
        void tspRecordVariant(
            const std::string& templateName, const DefineMap& defines, bool defaultTemplate);
        void tspPrecompileVariants();

        /* TSP_WARMDRAIN_V3: while a loading screen is up, let the warm-up prune
           release several programs per frame instead of one - the ~236ms each
           costs is what we are deliberately spending the load screen on. Off
           again the moment the screen goes away, so gameplay keeps the
           one-at-a-time policy that stops them clustering into one freeze. */
        void tspSetWarmupDrainFast(bool fast);

        /* TSP_SHADER_PRECOMPILE: OSG links an osg::Program lazily on first apply()
           during draw. On Mali that first draw costs ~236ms of CPU, and the
           instrumented run showed every program is created during the loading
           screen while the stall lands mid-combat. Handing the ICO each new
           program moves that compile into the load, using the same machinery
           OpenMW already pumps for textures and geometry. */
        void setIncrementalCompileOperation(osgUtil::IncrementalCompileOperation* ico)
        {
            mIncrementalCompileOperation = ico;
        }
        void setProgramTemplate(const osg::Program* program) { mProgramTemplate = program; }

        /// Clone an osg::Program including bindUniformBlocks that osg::Program::clone does not copy for some reason.
        static osg::ref_ptr<osg::Program> cloneProgram(const osg::Program*);

        /// Get (a copy of) the DefineMap used to construct all shaders
        DefineMap getGlobalDefines();

        /// Set the DefineMap used to construct all shaders
        /// @param defines The DefineMap to use
        /// @note This will change the source code for any shaders already created, potentially causing problems if
        /// they're being used to render a frame. It is recommended that any associated Viewers have their threading
        /// stopped while this function is running if any shaders are in use.
        void setGlobalDefines(DefineMap& globalDefines);

        void releaseGLObjects(osg::State* state);

        bool createSourceFromTemplate(std::string& source, std::vector<std::string>& linkedShaderTemplateNames,
            const std::string& templateName, const ShaderManager::DefineMap& defines);

        void setMaxTextureUnits(int maxTextureUnits) { mMaxTextureUnits = maxTextureUnits; }
        int getMaxTextureUnits() const { return mMaxTextureUnits; }
        int getAvailableTextureUnits() const { return mMaxTextureUnits - mReservedTextureUnits; }

        enum class Slot
        {
            OpaqueDepthTexture,
            SkyTexture,
            ShadowMaps,
            SLOT_COUNT
        };

        int reserveGlobalTextureUnits(Slot slot, int count = 1);

        void update(osgViewer::Viewer& viewer);
        void setHotReloadEnabled(bool value);
        void triggerShaderReload();

    private:
        void getLinkedShaders(osg::ref_ptr<osg::Shader> shader, const std::vector<std::string>& linkedShaderNames,
            const DefineMap& defines);
        void addLinkedShaders(osg::ref_ptr<osg::Shader> shader, osg::ref_ptr<osg::Program> program);

        std::filesystem::path mPath;

        DefineMap mGlobalDefines;

        // <name, code>
        typedef std::map<std::string, std::string> TemplateMap;
        TemplateMap mShaderTemplates;

        typedef std::pair<std::string, DefineMap> MapKey;
        typedef std::map<MapKey, osg::ref_ptr<osg::Shader>> ShaderMap;
        ShaderMap mShaders;

        typedef std::map<std::pair<osg::ref_ptr<osg::Shader>, osg::ref_ptr<osg::Shader>>, osg::ref_ptr<osg::Program>>
            ProgramMap;
        ProgramMap mPrograms;

        /* TSP_SHADER_DEDUP: mShaders is keyed on the DefineMap, but many
           different define maps generate byte-identical GLSL - unused texture
           slots still contribute a UV index to the key while landing inside
           "#if 0" in the output. Measured 98 shader objects for 31 unique
           texts, one of them repeated 16 times, each duplicate costing Mali
           ~137ms to link plus ~236ms on its first draw. This second cache is
           keyed on the generated source so identical GLSL reuses one
           osg::Shader; since mPrograms keys on shader pointers, duplicate
           programs then collapse as well. */
        typedef std::pair<int, std::string> SourceKey;
        typedef std::map<SourceKey, osg::ref_ptr<osg::Shader>> SourceShaderMap;
        SourceShaderMap mShadersBySource;
        unsigned int mDedupHits = 0;
        unsigned int mDedupMisses = 0;

        osg::ref_ptr<osg::Group> mWarmupGroup = new osg::Group;

        /* TSP_VARIANT_PRECOMPILE_V1 */
        std::set<std::string> mTspVariantSeen;
        std::vector<std::string> mTspVariantQueue;
        bool mTspVariantsLoaded = false;
        int mTspVariantRetries = 0; /* TSP_VARIANT_PRECOMPILE_V2 */
        std::mutex mTspVariantMutex;
        osg::ref_ptr<osgUtil::IncrementalCompileOperation> mIncrementalCompileOperation;

        typedef std::vector<osg::ref_ptr<osg::Shader>> ShaderList;
        typedef std::map<osg::ref_ptr<osg::Shader>, ShaderList> LinkedShadersMap;
        LinkedShadersMap mLinkedShaders;

        std::mutex mMutex;

        osg::ref_ptr<const osg::Program> mProgramTemplate;

        int mMaxTextureUnits = 0;
        int mReservedTextureUnits = 0;
        std::unique_ptr<HotReloadManager> mHotReloadManager;
        struct ReservedTextureUnits
        {
            int index = -1;
            int count = 0;
        };
        std::array<ReservedTextureUnits, static_cast<int>(Slot::SLOT_COUNT)> mReservedTextureUnitsBySlot = {};
    };

    bool parseForeachDirective(std::string& source, const std::string& templateName, size_t foundPos);
    bool parseLinkDirective(
        std::string& source, std::string& linkTarget, const std::string& templateName, size_t foundPos);

    bool parseDefines(std::string& source, const ShaderManager::DefineMap& defines,
        const ShaderManager::DefineMap& globalDefines, const std::string& templateName);

    bool parseDirectives(std::string& source, std::vector<std::string>& linkedShaderTemplateNames,
        const ShaderManager::DefineMap& defines, const ShaderManager::DefineMap& globalDefines,
        const std::string& templateName);

    ShaderManager::DefineMap getDefaultDefines();
}

#endif
