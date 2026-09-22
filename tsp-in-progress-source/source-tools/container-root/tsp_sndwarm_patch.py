#!/usr/bin/env python3
# TSP_SNDWARM_V1 patcher. Idempotent, transactional, prints every anchor as tried.
import os
import shutil
import sys
import time

SRC = os.environ.get("TSP_SRC", "/root/openmw-0.51-tsp-src")
STAMP = time.strftime("%Y%m%d-%H%M%S")

FUNC = r"""    // TSP_SNDWARM_V1 - the first play of any sound decodes it synchronously on the calling
    // thread (OpenALOutput::loadSound: ffmpeg open + readAll + alBufferData), measured at ~33 ms
    // inside SoundManager::update(). Warm the set a cell can play while the load screen is up.
    void SoundManager::tspWarmCellSounds(const ESM::RefId& region)
    {
        if (mOutput->isInitialized() == false || std::getenv("TSP_NO_SNDWARM") != nullptr)
            return;

        const auto tspWarmStart = std::chrono::steady_clock::now();
        std::vector<ESM::RefId> tspWarmIds;

        // Water: the two ids updateWaterSound can play.
        tspWarmIds.push_back(ESM::RefId::stringRefId(Fallback::Map::getString("Water_NearWaterIndoorID")));
        tspWarmIds.push_back(ESM::RefId::stringRefId(Fallback::Map::getString("Water_NearWaterOutdoorID")));

        if (region.empty() == false)
        {
            // Region ambients: exactly the set RegionSoundSelector can pick from.
            const MWWorld::ESMStore& tspStore = *MWBase::Environment::get().getESMStore();
            if (const ESM::Region* const tspRegion = tspStore.get<ESM::Region>().search(region))
            {
                for (const ESM::Region::SoundRef& tspRef : tspRegion->mSoundList)
                    tspWarmIds.push_back(tspRef.mSound);
            }

            // Weather loops and thunder, once per session: a weather change mid-cell gets no load screen.
            if (mTspWarmedWeather == false && std::getenv("TSP_NO_SNDWARM_WEATHER") == nullptr)
            {
                mTspWarmedWeather = true;
                for (const MWWorld::Weather& tspWeather : MWBase::Environment::get().getWorld()->getAllWeather())
                {
                    tspWarmIds.push_back(tspWeather.mAmbientLoopSoundID);
                    tspWarmIds.push_back(tspWeather.mRainLoopSoundID);
                    for (const ESM::RefId& tspThunder : tspWeather.mThunderSoundID)
                        tspWarmIds.push_back(tspThunder);
                }
            }
        }

        const char* const tspMaxEnv = std::getenv("TSP_SNDWARM_MAX");
        const int tspMaxParsed = tspMaxEnv != nullptr ? std::atoi(tspMaxEnv) : 0;
        const int tspMax = tspMaxParsed > 0 ? tspMaxParsed : 48;

        int tspWarmed = 0;
        int tspCached = 0;
        int tspFailed = 0;
        for (const ESM::RefId& tspId : tspWarmIds)
        {
            if (tspId.empty())
                continue;
            if (mSoundBuffers.lookup(tspId) != nullptr)
            {
                ++tspCached;
                continue;
            }
            if (tspWarmed >= tspMax)
                break;
            if (mSoundBuffers.load(tspId) != nullptr)
                ++tspWarmed;
            else
                ++tspFailed;
        }

        const double tspWarmMs
            = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - tspWarmStart).count();
        if (std::getenv("TSP_SNDWARM_LOG") != nullptr)
            Log(Debug::Warning) << "TSP_SNDWARM_V1 region=" << region << " warmed=" << tspWarmed
                                << " cached=" << tspCached << " failed=" << tspFailed << " ms=" << tspWarmMs;
        else
            Log(Debug::Info) << "TSP_SNDWARM_V1 region=" << region << " warmed=" << tspWarmed
                             << " cached=" << tspCached << " failed=" << tspFailed << " ms=" << tspWarmMs;
    }

"""

EDITS = [
    (
        "apps/openmw/mwbase/soundmanager.hpp",
        "base-interface",
        "        virtual void clear() = 0;",
        "before",
        "        // TSP_SNDWARM_V1 - default no-op so no other implementation has to care.\n"
        "        virtual void tspWarmCellSounds(const ESM::RefId&) {}\n\n",
    ),
    (
        "apps/openmw/mwsound/soundmanagerimp.hpp",
        "impl-decl",
        "        void clear() override;",
        "before",
        "        void tspWarmCellSounds(const ESM::RefId& region) override;\n\n",
    ),
    (
        "apps/openmw/mwsound/soundmanagerimp.hpp",
        "impl-member",
        "        Sound* mCurrentRegionSound;",
        "after",
        "\n\n        // TSP_SNDWARM_V1\n        bool mTspWarmedWeather = false;",
    ),
    (
        "apps/openmw/mwsound/soundmanagerimp.cpp",
        "impl-includes-std",
        "#include <components/misc/resourcehelpers.hpp>",
        "before",
        "#include <chrono>\n#include <cstdlib>\n#include <vector>\n\n"
        "#include <components/esm3/loadregn.hpp>\n#include <components/fallback/fallback.hpp>\n",
    ),
    (
        "apps/openmw/mwsound/soundmanagerimp.cpp",
        "impl-includes-weather",
        '#include "../mwworld/esmstore.hpp"',
        "after",
        '\n#include "../mwworld/weather.hpp"',
    ),
    (
        "apps/openmw/mwsound/soundmanagerimp.cpp",
        "impl-function",
        "    void SoundManager::updateRegionSound(float duration)\n    {",
        "before",
        FUNC,
    ),
    (
        "apps/openmw/mwworld/scene.cpp",
        "call-exterior",
        "        MWBase::Environment::get().getWindowManager()->changeCell(&current);",
        "after",
        "\n        // TSP_SNDWARM_V1 - the load screen is still up here.\n"
        "        MWBase::Environment::get().getSoundManager()->tspWarmCellSounds(current.getCell()->getRegion());",
    ),
    (
        "apps/openmw/mwworld/scene.cpp",
        "call-interior",
        "        MWBase::Environment::get().getWindowManager()->changeCell(mCurrentCell);",
        "after",
        "\n        // TSP_SNDWARM_V1\n"
        "        MWBase::Environment::get().getSoundManager()->tspWarmCellSounds(cell.getCell()->getRegion());",
    ),
]

# expected count of the string literal TSP_SNDWARM_V1 after patching, per file
EXPECT_LITERAL = {
    "apps/openmw/mwsound/soundmanagerimp.cpp": 2,  # the two Log() lines
}

files = sorted({e[0] for e in EDITS})

# ---- read and guard -------------------------------------------------------
original = {}
for rel in files:
    path = os.path.join(SRC, rel)
    if not os.path.isfile(path):
        print("FAIL  missing source file: " + path)
        sys.exit(1)
    with open(path, "r", encoding="utf-8") as fh:
        original[rel] = fh.read()

already = [rel for rel in files if "TSP_SNDWARM" in original[rel]]
if already:
    print("ALREADY PATCHED - nothing done. TSP_SNDWARM found in:")
    for rel in already:
        print("      " + rel + "   occurrences=" + str(original[rel].count("TSP_SNDWARM")))
    sys.exit(2)

# ---- backups --------------------------------------------------------------
print("=== backups ===")
for rel in files:
    path = os.path.join(SRC, rel)
    bak = path + ".before-sndwarm-" + STAMP
    shutil.copy2(path, bak)
    print("      " + bak + "   " + str(os.path.getsize(bak)) + " bytes")

# ---- anchors --------------------------------------------------------------
print("=== anchors ===")
patched = dict(original)
ok = True
for rel, label, anchor, where, payload in EDITS:
    n = patched[rel].count(anchor)
    status = "OK" if n == 1 else "FAIL"
    print("      " + status + "  " + rel + "  [" + label + "]  matches=" + str(n))
    if n != 1:
        ok = False
        needle = anchor.strip().split("\n")[0][:40]
        print("      ---- source lines containing " + repr(needle) + " ----")
        for i, line in enumerate(patched[rel].split("\n"), 1):
            if needle in line:
                print("      " + str(i) + ": " + line)
        print("      ---- end ----")
        continue
    if where == "before":
        patched[rel] = patched[rel].replace(anchor, payload + anchor, 1)
    else:
        patched[rel] = patched[rel].replace(anchor, anchor + payload, 1)

if not ok:
    print("=== NO FILE WRITTEN - an anchor did not match exactly once ===")
    sys.exit(1)

# ---- write and re-assert --------------------------------------------------
print("=== write ===")
for rel in files:
    with open(os.path.join(SRC, rel), "w", encoding="utf-8") as fh:
        fh.write(patched[rel])
    added = patched[rel].count("TSP_SNDWARM")
    lit = patched[rel].count("TSP_SNDWARM_V1 region=")
    print(
        "      "
        + rel
        + "   +"
        + str(len(patched[rel].split("\n")) - len(original[rel].split("\n")))
        + " lines, TSP_SNDWARM=" + str(added)
        + ", log-literals=" + str(lit)
    )
    want = EXPECT_LITERAL.get(rel)
    if want is not None and lit != want:
        print("FAIL  expected " + str(want) + " log literals in " + rel + ", found " + str(lit))
        sys.exit(1)

# one definition, one declaration, one override, two call sites
defs = patched["apps/openmw/mwsound/soundmanagerimp.cpp"].count("void SoundManager::tspWarmCellSounds")
calls = patched["apps/openmw/mwworld/scene.cpp"].count("->tspWarmCellSounds(")
print("=== counts ===")
print("      definitions=" + str(defs) + " (want 1)   call sites=" + str(calls) + " (want 2)")
if defs != 1 or calls != 2:
    print("FAIL  count assertion")
    sys.exit(1)
print("=== PATCH OK ===")
