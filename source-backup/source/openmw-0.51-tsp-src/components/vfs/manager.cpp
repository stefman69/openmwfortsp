#include "manager.hpp"
#include <cstdlib>
#include <ctime>
#include <cstdio>

#include <cassert>
#include <stdexcept>

#include <components/files/conversion.hpp>
#include <components/misc/strings/lower.hpp>
#include <components/vfs/recursivedirectoryiterator.hpp>

#include "archive.hpp"
#include "file.hpp"
#include "pathutil.hpp"
#include "recursivedirectoryiterator.hpp"

namespace VFS
{
    Manager::Manager() = default;

    Manager::~Manager() = default;

    void Manager::reset()
    {
        mIndex.clear();
        mArchives.clear();
    }

    void Manager::addArchive(std::unique_ptr<Archive>&& archive)
    {
        mArchives.push_back(std::move(archive));
    }

    void Manager::buildIndex()
    {
        mIndex.clear();

        for (const auto& archive : mArchives)
            archive->listResources(mIndex);
    }

    Files::IStreamPtr Manager::find(Path::NormalizedView name) const
    {
        return findNormalized(name.value());
    }

    Files::IStreamPtr Manager::get(const Path::Normalized& name) const
    {
        return getNormalized(name);
    }

    Files::IStreamPtr Manager::get(Path::NormalizedView name) const
    {
        return getNormalized(name.value());
    }

    Files::IStreamPtr Manager::getNormalized(std::string_view normalizedName) const
    {
        assert(Path::isNormalized(normalizedName));
        auto ptr = findNormalized(normalizedName);
        if (ptr == nullptr)
            throw std::runtime_error("Resource '" + std::string(normalizedName) + "' not found");
        return ptr;
    }

    bool Manager::exists(const Path::Normalized& name) const
    {
        return mIndex.find(name) != mIndex.end();
    }

    bool Manager::exists(Path::NormalizedView name) const
    {
        return mIndex.find(name) != mIndex.end();
    }

    std::string Manager::getArchive(const Path::Normalized& name) const
    {
        for (auto it = mArchives.rbegin(); it != mArchives.rend(); ++it)
        {
            if ((*it)->contains(name))
                return (*it)->getDescription();
        }
        return {};
    }

    std::filesystem::file_time_type Manager::getLastModified(VFS::Path::NormalizedView name) const
    {
        const auto found = mIndex.find(name);
        if (found == mIndex.end())
            throw std::runtime_error("Resource '" + std::string(name.value()) + "' not found");
        return found->second->getLastModified();
    }

    std::string Manager::getStem(VFS::Path::NormalizedView name) const
    {
        const auto found = mIndex.find(name);
        if (found == mIndex.end())
            throw std::runtime_error("Resource '" + std::string(name.value()) + "' not found");
        return found->second->getStem();
    }

    RecursiveDirectoryRange Manager::getRecursiveDirectoryIterator(std::string_view path) const
    {
        if (path.empty())
            return { mIndex.begin(), mIndex.end() };
        std::string normalized = Path::normalizeFilename(path);
        const auto it = mIndex.lower_bound(normalized);
        if (it == mIndex.end() || !it->first.view().starts_with(normalized))
            return { it, it };
        ++normalized.back();
        return { it, mIndex.lower_bound(normalized) };
    }

    RecursiveDirectoryRange Manager::getRecursiveDirectoryIterator(VFS::Path::NormalizedView path) const
    {
        if (path.value().empty())
            return { mIndex.begin(), mIndex.end() };
        const auto it = mIndex.lower_bound(path);
        if (it == mIndex.end() || !it->first.view().starts_with(path.value()))
            return { it, it };
        std::string copy(path.value());
        ++copy.back();
        return { it, mIndex.lower_bound(copy) };
    }

    RecursiveDirectoryRange Manager::getRecursiveDirectoryIterator() const
    {
        return { mIndex.begin(), mIndex.end() };
    }

    
/* TSP_VFS_TRACE: log every asset the VFS is asked for, with a timestamp and
   how long the lookup took. This is the single funnel all mesh, texture and
   sound requests pass through, so it names files definitively rather than
   guessing from naming conventions. Enable with OPENMW_TSP_VFSLOG=<path>. */
namespace {
    void tsp_vfs_log(std::string_view name, double ms)
    {
        static FILE* f = nullptr;
        static bool checked = false;
        if (!checked) {
            checked = true;
            const char* p = getenv("OPENMW_TSP_VFSLOG");
            if (p && p[0]) f = fopen(p, "w");
        }
        if (!f) return;
        struct timespec ts;
        clock_gettime(CLOCK_MONOTONIC, &ts);
        double now = ts.tv_sec * 1000.0 + ts.tv_nsec / 1000000.0;
        fprintf(f, "%.1f %6.2fms %.*s\n", now, ms,
                (int)name.size(), name.data());
        static int n = 0;
        if ((++n & 0x1f) == 0) fflush(f);
    }
}

Files::IStreamPtr Manager::findNormalized(std::string_view normalizedPath) const
    {
    struct timespec tsp_t0;
    clock_gettime(CLOCK_MONOTONIC, &tsp_t0);
    struct TspGuard {
        std::string_view n; struct timespec t0;
        ~TspGuard() {
            struct timespec t1;
            clock_gettime(CLOCK_MONOTONIC, &t1);
            double ms = (t1.tv_sec - t0.tv_sec) * 1000.0
                      + (t1.tv_nsec - t0.tv_nsec) / 1000000.0;
            tsp_vfs_log(n, ms);
        }
    } tsp_guard{normalizedPath, tsp_t0};

        assert(Path::isNormalized(normalizedPath));
        const auto it = mIndex.find(normalizedPath);
        if (it == mIndex.end())
            return nullptr;
        return it->second->open();
    }
}
