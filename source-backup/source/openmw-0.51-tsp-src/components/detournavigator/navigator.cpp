#include <cstdlib>
#include "navigator.hpp"
#include "navigatorimpl.hpp"
#include "navigatorstub.hpp"
#include "recastglobalallocator.hpp"

#include <components/debug/debuglog.hpp>
#include <components/files/conversion.hpp>

namespace DetourNavigator
{
    std::unique_ptr<Navigator> makeNavigator(const Settings& settings, const std::filesystem::path& userDataPath)
    {
        DetourNavigator::RecastGlobalAllocator::init();

        std::unique_ptr<NavMeshDb> db;
        if (settings.mEnableNavMeshDiskCache)
        {
            // TSP_NAVMESHDB_PATH_V54
            // Upstream hardcodes <userdata>/navmesh.db with no setting, which is why the
            // only way to move it was a bind mount - and sqlite kept unlinking the
            // mountpoint out from under us. OPENMW_TSP_NAVMESHDB takes an absolute path
            // so the db can live on internal storage (172 MB/s vs 41 on the card) with no
            // filesystem tricks and no reboot fragility. Unset = upstream behaviour.
            std::string path = Files::pathToUnicodeString(userDataPath / "navmesh.db");
            if (const char* tspDb = std::getenv("OPENMW_TSP_NAVMESHDB"))
                if (tspDb[0] != '\0')
                    path = tspDb;
            Log(Debug::Info) << "Using " << path << " to store navigation mesh cache";
            try
            {
                db = std::make_unique<NavMeshDb>(path, settings.mMaxDbFileSize);
            }
            catch (const std::exception& e)
            {
                Log(Debug::Error) << e.what() << ", navigation mesh disk cache will be disabled";
            }
        }

        return std::make_unique<NavigatorImpl>(settings, std::move(db));
    }

    std::unique_ptr<Navigator> makeNavigatorStub()
    {
        return std::make_unique<NavigatorStub>();
    }
}
