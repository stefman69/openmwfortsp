#!/usr/bin/env python3
# TSP_SNDWARM_V2 patcher.
#
# Three edits, all source, all in apps/openmw/mwsound:
#
#   1. soundbuffer.hpp  - expose the cache accounting (3 inline accessors).
#   2. soundbuffer.cpp  - fix the unreachable over-budget warning in loadSfx.
#   3. soundmanagerimp.cpp - replace tspWarmCellSounds with the budgeted, ordered,
#                            deduped V2 that reports resident survivors.
#
# All-or-nothing: every anchor in every file must match exactly once, brace balance
# must be preserved, or NOTHING is written.
#
# Idempotent: re-running after a successful apply changes nothing and exits 0.

import os
import re
import sys

ROOT = sys.argv[1] if len(sys.argv) > 1 else "/root/openmw-0.51-tsp-src"
MWS = os.path.join(ROOT, "apps", "openmw", "mwsound")

HPP = os.path.join(MWS, "soundbuffer.hpp")
BUF = os.path.join(MWS, "soundbuffer.cpp")
SMI = os.path.join(MWS, "soundmanagerimp.cpp")

# ---------------------------------------------------------------- edit 1: hpp ---
# Single-line anchor. `void clear();` occurs exactly once in the header.
HPP_ANCHOR = "        void clear();\n"
HPP_MARK = "tspGetCacheSize"
HPP_INSERT = (
    "        // TSP_SNDWARM_V2 - the cache accounting a budgeted warm needs. Read-only;\n"
    "        // inline, so no new symbols and no link-order surprises.\n"
    "        std::size_t tspGetCacheSize() const noexcept { return mBufferCacheSize; }\n"
    "        std::size_t tspGetCacheMin() const noexcept { return mBufferCacheMin; }\n"
    "        std::size_t tspGetCacheMax() const noexcept { return mBufferCacheMax; }\n"
    "\n"
)

# ---------------------------------------------------------------- edit 2: buf ---
# The warning below this line can never print. After unloadUnused() returns, either
# mUnusedBuffers is empty, or mBufferCacheSize <= mBufferCacheMin <= mBufferCacheMax.
# So `!mUnusedBuffers.empty() && mBufferCacheSize > mBufferCacheMax` is always false,
# and the one diagnostic that would have told us the sound cache was thrashing has
# been dead since the refactor. Invert it to upstream's intent.
BUF_OLD = "            if (!mUnusedBuffers.empty() && mBufferCacheSize > mBufferCacheMax)\n"
BUF_NEW = (
    "            // TSP_SNDCACHE_WARN_V2 - was !mUnusedBuffers.empty(), which is\n"
    "            // unreachable here: unloadUnused() returns only when the deque is\n"
    "            // empty or the cache is back under min. The warning never printed.\n"
    "            if (mUnusedBuffers.empty() && mBufferCacheSize > mBufferCacheMax)\n"
)
BUF_MARK = "TSP_SNDCACHE_WARN_V2"

# ---------------------------------------------------------------- edit 3: smi ---
SMI_SIG = "    void SoundManager::tspWarmCellSounds(const ESM::RefId& region)\n"
SMI_MARK = "TSP_SNDWARM_V2"

SMI_NEW = r'''    /* TSP_SNDWARM_V2 - the warm is BUDGETED, ORDERED and DEDUPED.

       What V1 did wrong, mechanically:

       V1 named every id it could reach - the two water ids, every region ambient,
       and every weather ambient loop, rain loop and thunder - and called
       mSoundBuffers.load() on all of them. load() -> loadSfx() decodes to raw PCM
       and does:

           mBufferCacheSize += size;
           if (mBufferCacheSize > mBufferCacheMax) unloadUnused();
           mUnusedBuffers.push_front(sfx);

       unloadUnused() frees from the BACK of mUnusedBuffers. Nothing the warm loads
       is ever used(), so every warmed buffer sits in that deque with mUses == 0 and
       the deque order is warm order. The back is therefore the id warmed FIRST.

       So once the warm's total passed `buffer cache max`, each further load freed
       the earliest thing the warm had loaded: the water ids, then the region
       ambients - the exact set updateRegionSound starts playing seconds later - to
       make room for the weather ambience loops, which are the largest files in the
       set and are not played at all unless the weather changes.

       updateRegionSound then re-decoded the region set one sound at a time on the
       gameplay thread (OpenALOutput::loadSound: ffmpeg open + readAll +
       alBufferData, ~33 ms each), and each of those decodes evicted another member
       of the same set, so the next pick missed too. That is a thrash loop that runs
       until the set actually being played fits under `buffer cache min` - the
       reported 15-18 fps for roughly the first 45 seconds of play, recovering on
       its own.

       V1 could not show any of this. `warmed` counted load() calls, not survivors,
       so warmed=18 was reported while some of those 18 were already freed; and the
       "No unused sound buffers to free" warning in loadSfx was unreachable (see
       TSP_SNDCACHE_WARN_V2), so cache pressure was invisible.

       V2:
         - dedupe the id list, so `cached` means "already resident" and nothing else
           (thunder ids repeat across weather types and inflated it);
         - split into a CORE tier that gameplay actually plays (water + region
           ambients) and an OPTIONAL tier that it usually does not (weather);
         - cap each tier by total cache bytes, core at `buffer cache min` and
           optional at half of it. Staying at or under min is what guarantees
           loadSfx never calls unloadUnused() while the warm is running, so the warm
           can no longer evict itself;
         - report resident= : how many of the ids are still loaded when the warm
           returns. resident < warmed means the budget is STILL too large and the
           next step is to lower it, not to guess again. */
    void SoundManager::tspWarmCellSounds(const ESM::RefId& region)
    {
        if (mOutput->isInitialized() == false || std::getenv("TSP_NO_SNDWARM") != nullptr)
            return;

        // Share of `buffer cache min` the optional tier may occupy. Named so tuning
        // it is a one-token sed, not a new patch.
        const double tspOptionalShare = 0.5;

        const auto tspWarmStart = std::chrono::steady_clock::now();

        std::vector<ESM::RefId> tspCoreIds;
        std::vector<ESM::RefId> tspOptIds;

        // Hand-rolled rather than std::find so this adds no include to a file that
        // does not already have <algorithm>.
        const auto tspAddId = [](std::vector<ESM::RefId>& tspInto, const ESM::RefId& tspId) {
            if (tspId.empty())
                return;
            for (const ESM::RefId& tspSeen : tspInto)
            {
                if (tspSeen == tspId)
                    return;
            }
            tspInto.push_back(tspId);
        };

        // CORE, tier 1: the two ids updateWaterSound can play.
        tspAddId(tspCoreIds, ESM::RefId::stringRefId(Fallback::Map::getString("Water_NearWaterIndoorID")));
        tspAddId(tspCoreIds, ESM::RefId::stringRefId(Fallback::Map::getString("Water_NearWaterOutdoorID")));

        // CORE, tier 2: exactly the set RegionSoundSelector can pick from, which is
        // the set updateRegionSound begins playing within seconds of the load screen
        // lifting. This is the tier V1 was evicting.
        if (region.empty() == false)
        {
            const MWWorld::ESMStore& tspStore = *MWBase::Environment::get().getESMStore();
            if (const ESM::Region* const tspRegion = tspStore.get<ESM::Region>().search(region))
            {
                for (const ESM::Region::SoundRef& tspRef : tspRegion->mSoundList)
                    tspAddId(tspCoreIds, tspRef.mSound);
            }
        }

        // OPTIONAL: weather loops and thunder, once per session. Large, and unplayed
        // unless the weather changes. A weather change against a cold buffer costs
        // one ~33 ms frame; this tier displacing the core tier cost 45 seconds.
        if (region.empty() == false && mTspWarmedWeather == false
            && std::getenv("TSP_NO_SNDWARM_WEATHER") == nullptr)
        {
            mTspWarmedWeather = true;
            for (const MWWorld::Weather& tspWeather : MWBase::Environment::get().getWorld()->getAllWeather())
            {
                tspAddId(tspOptIds, tspWeather.mAmbientLoopSoundID);
                tspAddId(tspOptIds, tspWeather.mRainLoopSoundID);
                for (const ESM::RefId& tspThunder : tspWeather.mThunderSoundID)
                    tspAddId(tspOptIds, tspThunder);
            }
        }

        const char* const tspMaxEnv = std::getenv("TSP_SNDWARM_MAX");
        const int tspMaxParsed = tspMaxEnv != nullptr ? std::atoi(tspMaxEnv) : 0;
        const int tspMax = tspMaxParsed > 0 ? tspMaxParsed : 48;

        // The budgets are on the WHOLE cache, not on this warm's share of it: what
        // has to stay true is mBufferCacheSize <= mBufferCacheMin, because that is
        // what keeps loadSfx from ever reaching its unloadUnused() branch.
        const std::size_t tspBudgetCore = mSoundBuffers.tspGetCacheMin();
        const std::size_t tspBudgetOpt = static_cast<std::size_t>(tspBudgetCore * tspOptionalShare);
        const std::size_t tspBytesBefore = mSoundBuffers.tspGetCacheSize();

        int tspWarmed = 0;
        int tspCached = 0;
        int tspFailed = 0;
        int tspSkipped = 0;

        const auto tspWarmList = [&](const std::vector<ESM::RefId>& tspIds, std::size_t tspLimit) {
            for (const ESM::RefId& tspId : tspIds)
            {
                if (mSoundBuffers.lookup(tspId) != nullptr)
                {
                    ++tspCached;
                    continue;
                }
                if (tspWarmed >= tspMax || mSoundBuffers.tspGetCacheSize() >= tspLimit)
                {
                    ++tspSkipped;
                    continue;
                }
                if (mSoundBuffers.load(tspId) != nullptr)
                    ++tspWarmed;
                else
                    ++tspFailed;
            }
        };

        tspWarmList(tspCoreIds, tspBudgetCore);
        tspWarmList(tspOptIds, tspBudgetOpt);

        // Survivors, not load calls. If this is below warmed, the warm is still
        // evicting itself and tspOptionalShare / the core budget must come down.
        int tspResident = 0;
        for (const ESM::RefId& tspId : tspCoreIds)
        {
            if (mSoundBuffers.lookup(tspId) != nullptr)
                ++tspResident;
        }
        int tspResidentOpt = 0;
        for (const ESM::RefId& tspId : tspOptIds)
        {
            if (mSoundBuffers.lookup(tspId) != nullptr)
                ++tspResidentOpt;
        }

        const double tspWarmMs
            = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - tspWarmStart).count();

        // Unconditional, and on Warning: openmw.log keeps Info, but Warning is the
        // channel that has never been swallowed, and one line per cell load is not
        // volume. TSP_SNDWARM_LOG is no longer needed and is harmless if still set.
        Log(Debug::Warning) << "TSP_SNDWARM_V2 region=" << region << " core=" << tspCoreIds.size()
                            << " opt=" << tspOptIds.size() << " warmed=" << tspWarmed << " cached=" << tspCached
                            << " failed=" << tspFailed << " skipped=" << tspSkipped
                            << " resident_core=" << tspResident << "/" << tspCoreIds.size()
                            << " resident_opt=" << tspResidentOpt << "/" << tspOptIds.size()
                            << " bytes=" << mSoundBuffers.tspGetCacheSize() << " was=" << tspBytesBefore
                            << " budget_core=" << tspBudgetCore << " budget_opt=" << tspBudgetOpt
                            << " min=" << mSoundBuffers.tspGetCacheMin() << " max=" << mSoundBuffers.tspGetCacheMax()
                            << " ms=" << tspWarmMs;
    }
'''


def die(msg):
    print("REFUSING: %s" % msg)
    print("NOTHING WAS WRITTEN.")
    sys.exit(1)


def balanced(text, label):
    """Brace balance, ignoring nothing - a crude but sufficient whole-file check."""
    n = text.count("{") - text.count("}")
    if n != 0:
        die("%s brace balance is off by %+d" % (label, n))


def survey(text, pattern, label):
    print("  survey of %s in %s:" % (pattern, label))
    for i, line in enumerate(text.splitlines(), 1):
        if re.search(pattern, line):
            print("    %6d  %s" % (i, line))


def read(path):
    if not os.path.isfile(path):
        die("missing file: %s" % path)
    with open(path, "r", encoding="utf-8") as fh:
        return fh.read()


def find_function_span(text, sig):
    """Return (start, end) covering sig through the matching close brace."""
    at = text.find(sig)
    if at < 0:
        return None
    # walk forward to the first '{' after the signature
    i = at + len(sig)
    while i < len(text) and text[i] != "{":
        if text[i] not in " \t\r\n":
            die("unexpected text between the signature and its opening brace")
        i += 1
    if i >= len(text):
        die("no opening brace after the signature")
    depth = 0
    while i < len(text):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                end = i + 1
                if end < len(text) and text[end] == "\n":
                    end += 1
                return (at, end)
        i += 1
    die("unterminated function body")


def main():
    print("TSP_SNDWARM_V2 patcher")
    print("  root: %s" % ROOT)

    hpp = read(HPP)
    buf = read(BUF)
    smi = read(SMI)

    done = [HPP_MARK in hpp, BUF_MARK in buf, SMI_MARK in smi]
    if all(done):
        print("ALREADY APPLIED: all three markers present. Nothing to do.")
        print("VERIFIED: TSP_SNDWARM_V2")
        return
    if any(done):
        die("PARTIALLY applied (hpp=%s buf=%s smi=%s). Restore the .before-sndwarmv2 "
            "backups and re-run rather than patching over half a change."
            % tuple("yes" if d else "no" for d in done))

    # ---- assert every anchor exactly once BEFORE writing anything -------------
    if hpp.count(HPP_ANCHOR) != 1:
        survey(hpp, r"void clear", "soundbuffer.hpp")
        die("soundbuffer.hpp anchor matched %d times, need exactly 1" % hpp.count(HPP_ANCHOR))
    if buf.count(BUF_OLD) != 1:
        survey(buf, r"mUnusedBuffers\.empty", "soundbuffer.cpp")
        die("soundbuffer.cpp anchor matched %d times, need exactly 1" % buf.count(BUF_OLD))
    if smi.count(SMI_SIG) != 1:
        survey(smi, r"tspWarmCellSounds", "soundmanagerimp.cpp")
        die("soundmanagerimp.cpp signature matched %d times, need exactly 1" % smi.count(SMI_SIG))

    span = find_function_span(smi, SMI_SIG)
    if span is None:
        die("could not brace-match tspWarmCellSounds")
    start, end = span
    old_fn = smi[start:end]
    if old_fn.count("{") != old_fn.count("}"):
        die("the function span I matched is not brace balanced - refusing")
    if "mSoundBuffers.load" not in old_fn:
        survey(smi, r"tspWarmCellSounds|mSoundBuffers\.load", "soundmanagerimp.cpp")
        die("the matched span does not contain mSoundBuffers.load - wrong span")

    print("  anchors: hpp 1, buf 1, smi 1   (V1 function span %d lines)"
          % old_fn.count("\n"))

    # ---- build the new contents ----------------------------------------------
    new_hpp = hpp.replace(HPP_ANCHOR, HPP_INSERT + HPP_ANCHOR, 1)
    new_buf = buf.replace(BUF_OLD, BUF_NEW, 1)
    new_smi = smi[:start] + SMI_NEW + smi[end:]

    balanced(new_hpp, "soundbuffer.hpp")
    balanced(new_buf, "soundbuffer.cpp")
    balanced(new_smi, "soundmanagerimp.cpp")

    for text, mark, label in ((new_hpp, HPP_MARK, "hpp"),
                              (new_buf, BUF_MARK, "buf"),
                              (new_smi, SMI_MARK, "smi")):
        if mark not in text:
            die("post-write check: %s marker missing from %s" % (mark, label))
    # the V1 shape must be gone
    if "tspWarmIds.push_back(ESM::RefId::stringRefId" in new_smi:
        die("post-write check: V1 body still present in soundmanagerimp.cpp")

    # ---- write ---------------------------------------------------------------
    stamp = os.environ.get("TSP_STAMP", "sndwarmv2")
    for path, text in ((HPP, new_hpp), (BUF, new_buf), (SMI, new_smi)):
        bak = "%s.before-%s" % (path, stamp)
        if not os.path.exists(bak):
            with open(bak, "w", encoding="utf-8") as fh:
                fh.write(read(path))
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(text)
        print("  wrote %s  (backup %s)" % (os.path.basename(path), os.path.basename(bak)))

    print("VERIFIED: TSP_SNDWARM_V2")


if __name__ == "__main__":
    main()
