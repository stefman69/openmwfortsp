#!/bin/bash
set -Eeuo pipefail

SOURCE_DIR="${1:-/root/openmw-0.51-tsp-src}"
BUILD_DIR="${2:-/root/openmw-0.51-tsp-build}"
PACKAGE_DIR="${3:-/root/openmw-0.51-tsp-package}"
OUTPUT_BINARY="${4:-/root/openmw-0.51-tsp-depth-warmreload-v13}"

JOBS="${OPENMW_JOBS:-1}"
PATCH_ONLY="${OPENMW_PATCH_ONLY:-0}"

STATE_CPP="$SOURCE_DIR/apps/openmw/mwstate/statemanagerimp.cpp"
ENGINE_CPP="$SOURCE_DIR/apps/openmw/engine.cpp"
RENDER_CPP="$SOURCE_DIR/apps/openmw/mwrender/renderingmanager.cpp"
WORLD_CPP="$SOURCE_DIR/apps/openmw/mwworld/worldimp.cpp"
CMAKE_FILE="$SOURCE_DIR/CMakeLists.txt"
BUILT_BINARY="$BUILD_DIR/openmw"
PACKAGE_BINARY="$PACKAGE_DIR/bin/openmw-0.51"

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="$SOURCE_DIR/.tsp-051-source-backups/depth-warmreload-v13-$STAMP"

restore_on_error() {
    rc=$?
    if [ "$rc" -ne 0 ] && [ -d "$BACKUP_DIR" ]; then
        echo
        echo "ERROR: V13 corrected depth/warm-load patch/build failed."
        echo "Restoring the source files changed by this attempt..."
        [ -f "$BACKUP_DIR/apps/openmw/mwstate/statemanagerimp.cpp" ] && \
            cp -f "$BACKUP_DIR/apps/openmw/mwstate/statemanagerimp.cpp" "$STATE_CPP"
        [ -f "$BACKUP_DIR/apps/openmw/engine.cpp" ] && \
            cp -f "$BACKUP_DIR/apps/openmw/engine.cpp" "$ENGINE_CPP"
        [ -f "$BACKUP_DIR/apps/openmw/mwrender/renderingmanager.cpp" ] && \
            cp -f "$BACKUP_DIR/apps/openmw/mwrender/renderingmanager.cpp" "$RENDER_CPP"
        [ -f "$BACKUP_DIR/apps/openmw/mwworld/worldimp.cpp" ] && \
            cp -f "$BACKUP_DIR/apps/openmw/mwworld/worldimp.cpp" "$WORLD_CPP"
        echo "Source restoration complete."
        echo "Failed-attempt backup retained at:"
        echo "  $BACKUP_DIR"
    fi
    exit "$rc"
}
trap restore_on_error ERR

echo "============================================================"
echo "OpenMW 0.51 TSP V13 DEPTH + WARM LOAD REPAIR"
echo "============================================================"
echo "Source:        $SOURCE_DIR"
echo "Build:         $BUILD_DIR"
echo "Package:       $PACKAGE_DIR"
echo "Output binary: $OUTPUT_BINARY"
echo "Patch only:    $PATCH_ONLY"
echo "Jobs:          $JOBS"
echo "Backup:        $BACKUP_DIR"
echo "============================================================"

for required in "$STATE_CPP" "$ENGINE_CPP" "$RENDER_CPP" "$WORLD_CPP" "$CMAKE_FILE"; do
    if [ ! -f "$required" ]; then
        echo "ERROR: missing required source file:"
        echo "  $required"
        exit 1
    fi
done

VERSION_MAJOR="$(sed -n 's/^[[:space:]]*set(OPENMW_VERSION_MAJOR[[:space:]]*\([0-9][0-9]*\)).*/\1/p' "$CMAKE_FILE" | head -1)"
VERSION_MINOR="$(sed -n 's/^[[:space:]]*set(OPENMW_VERSION_MINOR[[:space:]]*\([0-9][0-9]*\)).*/\1/p' "$CMAKE_FILE" | head -1)"
if [ "$VERSION_MAJOR" != "0" ] || [ "$VERSION_MINOR" != "51" ]; then
    echo "ERROR: expected OpenMW 0.51 source; detected ${VERSION_MAJOR:-?}.${VERSION_MINOR:-?}."
    exit 1
fi

if ! grep -q 'TSP_FRESH_PROCESS_LOAD_051_V12' "$STATE_CPP"; then
    echo "ERROR: V12 fresh-load source marker was not found."
    echo "This script expects the stable source tree produced by the previous"
    echo "run_openmw051_freshload_stability_revision.sh build."
    echo "Nothing was changed."
    exit 1
fi

if grep -RqiE \
    'TSP_TRANSITION_MEMORY_PURGE_051|TSP_UNREFERENCED_CACHE_PURGE_051|TSP MEMPURGE|tspPurgeTransitionMemory|clearUnreferencedCache' \
    "$SOURCE_DIR/apps/openmw/mwworld/scene.cpp" \
    "$SOURCE_DIR/components/resource" 2>/dev/null
then
    echo "ERROR: transition-memory-purge remnants were found in the source tree."
    echo "Refusing to layer V13 on top of that experimental lifetime policy."
    exit 1
fi

if [ "$PATCH_ONLY" != "1" ]; then
    if [ ! -f "$BUILD_DIR/build.ninja" ] || [ ! -f "$BUILD_DIR/CMakeCache.txt" ]; then
        echo "ERROR: configured Ninja build tree is missing."
        echo "This script intentionally does not re-run CMake."
        exit 1
    fi
fi

mkdir -p \
    "$BACKUP_DIR/apps/openmw/mwstate" \
    "$BACKUP_DIR/apps/openmw/mwrender" \
    "$BACKUP_DIR/apps/openmw/mwworld" \
    "$PACKAGE_DIR/bin"

cp -f "$STATE_CPP"  "$BACKUP_DIR/apps/openmw/mwstate/statemanagerimp.cpp"
cp -f "$ENGINE_CPP" "$BACKUP_DIR/apps/openmw/engine.cpp"
cp -f "$RENDER_CPP" "$BACKUP_DIR/apps/openmw/mwrender/renderingmanager.cpp"
cp -f "$WORLD_CPP"  "$BACKUP_DIR/apps/openmw/mwworld/worldimp.cpp"

echo
echo "Applying corrected V13 depth + warm-reload source revision..."

python3 - "$STATE_CPP" "$ENGINE_CPP" "$RENDER_CPP" "$WORLD_CPP" <<'PY_PATCH'
from pathlib import Path
import re
import sys

state_path, engine_path, render_path, world_path = map(Path, sys.argv[1:])
state = state_path.read_text(encoding="utf-8")
engine = engine_path.read_text(encoding="utf-8")
render = render_path.read_text(encoding="utf-8")
world = world_path.read_text(encoding="utf-8")

V12 = "TSP_FRESH_PROCESS_LOAD_051_V12"
DEPTH_V13 = "TSP_DEPTH_DIAG_051_V13"
PROJ_V13 = "TSP_DEPTH_PROJECTION_051_V13"


def find_function(text, signature_pattern, label):
    matches = list(re.finditer(signature_pattern, text, flags=re.MULTILINE))
    if len(matches) != 1:
        raise RuntimeError(f"{label}: expected one signature, found {len(matches)}")
    start = matches[0].start()
    opening = text.find("{", matches[0].end())
    if opening < 0:
        raise RuntimeError(f"{label}: opening brace not found")

    depth = 0
    i = opening
    in_string = in_char = in_line_comment = in_block_comment = False
    escaped = False
    while i < len(text):
        ch = text[i]
        nxt = text[i + 1] if i + 1 < len(text) else ""
        if in_line_comment:
            if ch == "\n":
                in_line_comment = False
        elif in_block_comment:
            if ch == "*" and nxt == "/":
                in_block_comment = False
                i += 1
        elif in_string:
            if escaped:
                escaped = False
            elif ch == "\\":
                escaped = True
            elif ch == '"':
                in_string = False
        elif in_char:
            if escaped:
                escaped = False
            elif ch == "\\":
                escaped = True
            elif ch == "'":
                in_char = False
        else:
            if ch == "/" and nxt == "/":
                in_line_comment = True
                i += 1
            elif ch == "/" and nxt == "*":
                in_block_comment = True
                i += 1
            elif ch == '"':
                in_string = True
            elif ch == "'":
                in_char = True
            elif ch == "{":
                depth += 1
            elif ch == "}":
                depth -= 1
                if depth == 0:
                    return start, i + 1
        i += 1
    raise RuntimeError(f"{label}: closing brace not found")


def write_lf(path, text):
    with path.open("w", encoding="utf-8", newline="\n") as f:
        f.write(text)


# =====================================================================
# 1. CORRECTED WARM RELOAD + SETTINGS.CFG SAFETY FALLBACK + DIAGNOSTICS
# =====================================================================
V13_SAFE = "TSP_SAFE_RELOAD_CONFIG_051_V13"
V13_TRACE = "TSP_LOAD_TRACE_051_V13"
V13_WATCH = "TSP_LOAD_WATCH_051_V13"
OLD_HYBRID = "TSP_HYBRID_LOAD_POLICY_051_V13"

# If the accidentally-issued hybrid V13 was already applied to the Docker
# source tree, remove its file-scope policy block first.
if OLD_HYBRID in state:
    marker_pos = state.find("    // " + OLD_HYBRID)
    if marker_pos < 0:
        marker_pos = state.find("// " + OLD_HYBRID)
    if marker_pos < 0:
        raise RuntimeError("statemanagerimp.cpp: old hybrid marker found but marker line could not be located")
    marker_line = state.rfind("\n", 0, marker_pos) + 1
    fstart, fend = find_function(
        state,
        r"^[ \t]*bool[ \t]+tspShouldFreshRestartForLoad[ \t]*\(const std::filesystem::path& filepath,[ \t]*bool deathReload\)",
        "old tspShouldFreshRestartForLoad",
    )
    if fstart < marker_line:
        raise RuntimeError("statemanagerimp.cpp: old hybrid function ordering was unexpected")
    state = state[:marker_line] + state[fend:]

# Normalize the loadGame function back to one plain cleanup() call before
# applying the corrected policy. This handles either the V12 direct-fresh hook
# or the mistakenly-issued hybrid V13 hook.
load_sig = r"^[ \t]*void[ \t]+MWState::StateManager::loadGame[ \t]*\(const Character\* character,[ \t]*const std::filesystem::path& filepath\)"
lstart, lend = find_function(state, load_sig, "StateManager::loadGame(Character*, path)")
func = state[lstart:lend]

# Remove V12 direct fresh hook when present.
func = re.sub(
    r'#if defined\(__linux__\)\n[ \t]*if \(mState != State_NoGame && tspFreshProcessLoadsEnabled\(\)\)\n[ \t]*tspRestartForSaveLoad\(filepath\);\n#endif\n\n',
    '', func, count=1,
)

# Remove the old hybrid hook + malloc_trim block when present.
func = re.sub(
    r'[ \t]*bool tspWarmLoadThisTime = false;\n'
    r'#if defined\(__linux__\)\n.*?'
    r'#endif\n\n'
    r'[ \t]*cleanup\(\);\n\n'
    r'#if defined\(__linux__\) && defined\(__GLIBC__\)\n.*?'
    r'#endif\n',
    '        cleanup();\n', func, count=1, flags=re.DOTALL,
)
state = state[:lstart] + func + state[lend:]

if V13_SAFE not in state:
    # Required standard-library includes for the small settings.cfg parser and
    # load trace. The V12 helper already provides several of these in most
    # trees, but make the patch independent of that detail.
    include_anchor = '#include "statemanagerimp.hpp"\n'
    if include_anchor not in state:
        raise RuntimeError("statemanagerimp.cpp: include anchor missing")
    needed = []
    for inc in (
        '#include <array>\n',
        '#include <cctype>\n',
        '#include <chrono>\n',
        '#include <cstdint>\n',
        '#include <cstdlib>\n',
        '#include <fstream>\n',
        '#include <map>\n',
        '#include <string>\n',
        '#include <utility>\n',
    ):
        if inc.strip() not in state:
            needed.append(inc)
    if needed:
        state = state.replace(include_anchor, include_anchor + ''.join(needed), 1)

    helper_anchor = "void MWState::StateManager::cleanup(bool force)\n"
    if helper_anchor not in state:
        raise RuntimeError("statemanagerimp.cpp: cleanup anchor missing")

    helper = r'''// TSP_SAFE_RELOAD_CONFIG_051_V13
// Normal/default behaviour: keep the process and already-parsed ESM/ESP content
// alive and perform an in-process load. If [TSP] safe reload = 1 is present in
// settings.cfg, use the proven V12 exec-based load as an opt-in fallback.
namespace
{
    struct TspSafeReloadSetting
    {
        bool enabled = false;
        bool found = false;
        std::filesystem::path path;
        std::string source = "default";
    };

    std::string tspTrim(std::string value)
    {
        auto isSpace = [](unsigned char c) { return std::isspace(c) != 0; };
        while (!value.empty() && isSpace(static_cast<unsigned char>(value.front())))
            value.erase(value.begin());
        while (!value.empty() && isSpace(static_cast<unsigned char>(value.back())))
            value.pop_back();
        return value;
    }

    std::string tspLower(std::string value)
    {
        for (char& c : value)
            c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
        return value;
    }

    bool tspBoolValue(std::string value)
    {
        value = tspLower(tspTrim(std::move(value)));
        return value == "1" || value == "true" || value == "yes" || value == "on";
    }

    TspSafeReloadSetting tspReadSafeReloadSetting()
    {
        TspSafeReloadSetting result;

        // Optional emergency override, mainly useful over SSH. settings.cfg is
        // the normal control requested for this port.
        if (const char* overrideValue = std::getenv("OPENMW_TSP_SAFE_RELOAD"))
        {
            result.enabled = tspBoolValue(overrideValue);
            result.found = true;
            result.source = "environment";
            return result;
        }

        if (const char* explicitPath = std::getenv("OPENMW_TSP_SETTINGS_FILE"))
            result.path = explicitPath;
        else if (const char* xdg = std::getenv("XDG_CONFIG_HOME"))
            result.path = std::filesystem::path(xdg) / "settings.cfg";
        else
            result.path = "settings.cfg";

        std::ifstream input(result.path);
        if (!input)
            return result;

        bool inTspSection = false;
        std::string line;
        while (std::getline(input, line))
        {
            if (!line.empty() && line.back() == '\r')
                line.pop_back();

            const std::size_t comment = line.find_first_of("#;");
            if (comment != std::string::npos)
                line.erase(comment);
            line = tspTrim(std::move(line));
            if (line.empty())
                continue;

            if (line.front() == '[' && line.back() == ']')
            {
                inTspSection = tspLower(tspTrim(line.substr(1, line.size() - 2))) == "tsp";
                continue;
            }
            if (!inTspSection)
                continue;

            const std::size_t eq = line.find('=');
            if (eq == std::string::npos)
                continue;
            const std::string key = tspLower(tspTrim(line.substr(0, eq)));
            if (key != "safe reload")
                continue;

            result.enabled = tspBoolValue(line.substr(eq + 1));
            result.found = true;
            result.source = "settings.cfg";
            return result;
        }
        return result;
    }

    std::uint64_t gTspLoadGeneration = 0;
    bool gTspLoadTraceActive = false;
    bool gTspLoadWatchActive = false;
    std::chrono::steady_clock::time_point gTspLoadWatchStart;
    std::size_t gTspLoadWatchIndex = 0;
    constexpr std::array<long long, 8> gTspLoadWatchMs{ 250, 500, 1000, 2000, 3000, 5000, 10000, 20000 };

    void tspLoadPhase(const char* phase)
    {
        if (!gTspLoadTraceActive)
            return;
        Log(Debug::Info) << "TSP_LOAD_TRACE_051_V13 generation=" << gTspLoadGeneration
                         << " phase=" << phase;
    }

    void tspBeginLoadTrace(const std::filesystem::path& filepath, bool activeReload, bool safeReload)
    {
        ++gTspLoadGeneration;
        gTspLoadTraceActive = true;
        gTspLoadWatchActive = false;
        gTspLoadWatchIndex = 0;
        Log(Debug::Info) << "TSP_LOAD_TRACE_051_V13 generation=" << gTspLoadGeneration
                         << " phase=begin active_reload=" << (activeReload ? 1 : 0)
                         << " safe_reload=" << (safeReload ? 1 : 0)
                         << " save=" << filepath.filename();
    }

    void tspFinishLoadTrace()
    {
        tspLoadPhase("complete");
        gTspLoadTraceActive = false;
        gTspLoadWatchStart = std::chrono::steady_clock::now();
        gTspLoadWatchIndex = 0;
        gTspLoadWatchActive = true;
    }

    void tspUpdateLoadWatch()
    {
        if (!gTspLoadWatchActive || gTspLoadWatchIndex >= gTspLoadWatchMs.size())
            return;
        const auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::steady_clock::now() - gTspLoadWatchStart).count();
        while (gTspLoadWatchIndex < gTspLoadWatchMs.size()
            && elapsed >= gTspLoadWatchMs[gTspLoadWatchIndex])
        {
            Log(Debug::Info) << "TSP_LOAD_WATCH_051_V13 generation=" << gTspLoadGeneration
                             << " survived_ms=" << gTspLoadWatchMs[gTspLoadWatchIndex];
            ++gTspLoadWatchIndex;
        }
        if (gTspLoadWatchIndex >= gTspLoadWatchMs.size())
            gTspLoadWatchActive = false;
    }
}

'''
    state = state.replace(helper_anchor, helper + helper_anchor, 1)

    # Instrument cleanup so a crash during teardown leaves a precise final phase.
    cleanup_sig = r"^[ \t]*void[ \t]+MWState::StateManager::cleanup[ \t]*\(bool force\)"
    cstart, cend = find_function(state, cleanup_sig, "StateManager::cleanup")
    cfunc = state[cstart:cend]
    cleanup_calls = [
        ('MWBase::Environment::get().getSoundManager()->clear();', 'cleanup-sound'),
        ('MWBase::Environment::get().getDialogueManager()->clear();', 'cleanup-dialogue'),
        ('MWBase::Environment::get().getJournal()->clear();', 'cleanup-journal'),
        ('MWBase::Environment::get().getScriptManager()->clear();', 'cleanup-scripts'),
        ('MWBase::Environment::get().getWindowManager()->clear();', 'cleanup-window'),
        ('MWBase::Environment::get().getWorld()->clear();', 'cleanup-world'),
        ('MWBase::Environment::get().getInputManager()->clear();', 'cleanup-input'),
        ('MWBase::Environment::get().getMechanicsManager()->clear();', 'cleanup-mechanics'),
    ]
    for call, phase in cleanup_calls:
        if call in cfunc and f'tspLoadPhase("{phase}")' not in cfunc:
            cfunc = cfunc.replace(call, f'tspLoadPhase("{phase}");\n            {call}', 1)
    state = state[:cstart] + cfunc + state[cend:]

    # Apply the corrected load policy and detailed loader diagnostics.
    lstart, lend = find_function(state, load_sig, "StateManager::loadGame(Character*, path)")
    func = state[lstart:lend]
    try_anchor = "    try\n    {\n"
    if try_anchor not in func:
        raise RuntimeError("statemanagerimp.cpp: loadGame try anchor missing")

    hook = r'''        const bool tspActiveReload = (mState != State_NoGame);
        TspSafeReloadSetting tspSafeReload;
#if defined(__linux__)
        if (tspActiveReload)
        {
            tspSafeReload = tspReadSafeReloadSetting();
            Log(Debug::Info) << "TSP_SAFE_RELOAD_CONFIG_051_V13"
                             << " enabled=" << (tspSafeReload.enabled ? 1 : 0)
                             << " found=" << (tspSafeReload.found ? 1 : 0)
                             << " source=" << tspSafeReload.source
                             << " path=" << tspSafeReload.path;
            if (tspSafeReload.enabled)
            {
                Log(Debug::Info) << "TSP_SAFE_RELOAD_051_V13 action=fresh save=" << filepath.filename();
                tspRestartForSaveLoad(filepath);
            }
            Log(Debug::Info) << "TSP_SAFE_RELOAD_051_V13 action=warm save=" << filepath.filename();
        }
#endif
        tspBeginLoadTrace(filepath, tspActiveReload, tspSafeReload.enabled);
        tspLoadPhase("cleanup-begin");
'''
    func = func.replace(try_anchor, try_anchor + hook, 1)

    cleanup_anchor = "        cleanup();\n"
    if cleanup_anchor not in func:
        raise RuntimeError("statemanagerimp.cpp: loadGame cleanup anchor missing")
    func = func.replace(cleanup_anchor, cleanup_anchor + '        tspLoadPhase("cleanup-done");\n', 1)

    reader_anchor = "        reader.open(filepath);\n"
    if reader_anchor not in func:
        raise RuntimeError("statemanagerimp.cpp: reader.open anchor missing")
    reader_diag = r'''        tspLoadPhase("reader-open");
        {
            std::size_t tspIndex = 0;
            for (const std::string& tspContent : MWBase::Environment::get().getWorld()->getContentFiles())
                Log(Debug::Info) << "TSP_LOAD_CONTENT_051_V13 source=current index=" << tspIndex++
                                 << " name=" << tspContent;
            tspIndex = 0;
            for (const auto& tspMaster : reader.getGameFiles())
                Log(Debug::Info) << "TSP_LOAD_CONTENT_051_V13 source=save-master index=" << tspIndex++
                                 << " name=" << tspMaster.name;
        }
'''
    func = func.replace(reader_anchor, reader_anchor + reader_diag, 1)

    map_anchor = "        std::map<int, int> contentFileMap = buildContentFileIndexMap(reader);\n"
    if map_anchor not in func:
        # tolerate explicit std::map formatting differences
        m = re.search(r'^[ \t]*std::map<[^\n]+contentFileMap = buildContentFileIndexMap\(reader\);\n', func, re.MULTILINE)
        if not m:
            raise RuntimeError("statemanagerimp.cpp: contentFileMap anchor missing")
        map_anchor = m.group(0)
    map_diag = r'''        for (const auto& tspMapping : contentFileMap)
            Log(Debug::Info) << "TSP_LOAD_CONTENT_051_V13 source=content-map save_index=" << tspMapping.first
                             << " current_index=" << tspMapping.second;
        tspLoadPhase("content-map-ready");
'''
    func = func.replace(map_anchor, map_anchor + map_diag, 1)

    loop_anchor = "        int currentPercent = 0;\n        while (reader.hasMoreRecs())\n"
    if loop_anchor not in func:
        raise RuntimeError("statemanagerimp.cpp: record loop anchor missing")
    func = func.replace(loop_anchor,
        "        int currentPercent = 0;\n"
        "        std::map<std::string, std::size_t> tspRecordCounts;\n"
        "        std::size_t tspRecordTotal = 0;\n"
        "        while (reader.hasMoreRecs())\n", 1)

    rec_anchor = "            ESM::NAME n = reader.getRecName();\n"
    if rec_anchor not in func:
        raise RuntimeError("statemanagerimp.cpp: record-name anchor missing")
    rec_diag = r'''            ++tspRecordTotal;
            ++tspRecordCounts[std::string(n.toStringView())];
            if ((tspRecordTotal % 128) == 0)
                Log(Debug::Info) << "TSP_LOAD_RECORD_PROGRESS_051_V13 generation=" << gTspLoadGeneration
                                 << " records=" << tspRecordTotal
                                 << " offset=" << reader.getFileOffset()
                                 << " total=" << total;
'''
    func = func.replace(rec_anchor, rec_anchor + rec_diag, 1)

    after_loop_anchor = "        mCharacterManager.setCurrentCharacter(character);\n"
    if after_loop_anchor not in func:
        raise RuntimeError("statemanagerimp.cpp: post-record anchor missing")
    summary = r'''        for (const auto& tspCount : tspRecordCounts)
            Log(Debug::Info) << "TSP_LOAD_RECORDS_051_V13 type=" << tspCount.first
                             << " count=" << tspCount.second;
        Log(Debug::Info) << "TSP_LOAD_RECORDS_051_V13 total=" << tspRecordTotal;
        tspLoadPhase("records-parsed");
'''
    func = func.replace(after_loop_anchor, summary + after_loop_anchor, 1)

    phase_after = [
        ('MWBase::Environment::get().getWorld()->saveLoaded(reader);', 'world-saveLoaded'),
        ('actorIdConverter.apply();', 'actor-id-map-applied'),
        ('MWBase::Environment::get().getWorld()->setupPlayer();', 'player-setup'),
        ('MWBase::Environment::get().getWorld()->renderPlayer();', 'player-rendered'),
        ('MWBase::Environment::get().getWindowManager()->updatePlayer();', 'window-player-updated'),
        ('MWBase::Environment::get().getMechanicsManager()->playerLoaded();', 'mechanics-playerLoaded'),
        ('MWBase::Environment::get().getWorld()->updateProjectilesCasters();', 'projectile-casters-updated'),
        ('MWBase::Environment::get().getScriptManager()->getGlobalScripts().addStartup();', 'startup-scripts-added'),
        ('MWBase::Environment::get().getLuaManager()->gameLoaded();', 'lua-gameLoaded'),
    ]
    for call, phase in phase_after:
        if call not in func:
            raise RuntimeError(f"statemanagerimp.cpp: phase anchor missing: {call}")
        func = func.replace(call, call + f'\n        tspLoadPhase("{phase}");', 1)

    grave_re = re.compile(
        r'(        for \(int actorId : actorIdConverter\.mGraveyard\)\n'
        r'        \{.*?\n        \}\n)', re.DOTALL)
    gm = grave_re.search(func)
    if not gm:
        raise RuntimeError("statemanagerimp.cpp: graveyard cleanup block missing")
    func = func[:gm.end()] + '        tspFinishLoadTrace();\n' + func[gm.end():]

    state = state[:lstart] + func + state[lend:]

    update_sig = r"^[ \t]*void[ \t]+MWState::StateManager::update[ \t]*\(float duration\)"
    ustart, uend = find_function(state, update_sig, "StateManager::update")
    ufunc = state[ustart:uend]

    # Install the post-load survival watchdog once per frame.
    #
    # Different 0.51/TSP source revisions do not all contain the exact
    # "mTimePlayed += duration;" statement, so do not depend on that
    # brittle anchor. Prefer it when present; otherwise insert directly
    # after the update() function's opening brace.
    if "tspUpdateLoadWatch();" not in ufunc:
        update_anchor = "        mTimePlayed += duration;\n"

        if update_anchor in ufunc:
            ufunc = ufunc.replace(
                update_anchor,
                update_anchor + "        tspUpdateLoadWatch();\n",
                1,
            )
        else:
            opening = ufunc.find("{")
            if opening < 0:
                raise RuntimeError(
                    "statemanagerimp.cpp: StateManager::update opening brace missing"
                )

            insert_at = opening + 1
            ufunc = (
                ufunc[:insert_at]
                + "\n        tspUpdateLoadWatch();"
                + ufunc[insert_at:]
            )

    state = state[:ustart] + ufunc + state[uend:]

for required in (
    V12,
    V13_SAFE,
    V13_TRACE,
    V13_WATCH,
    "TSP_SAFE_RELOAD_051_V13 action=fresh",
    "TSP_SAFE_RELOAD_051_V13 action=warm",
    "TSP_LOAD_CONTENT_051_V13",
    "TSP_LOAD_RECORDS_051_V13",
    "TSP_LOAD_RECORD_PROGRESS_051_V13",
    "OPENMW_TSP_SAFE_RELOAD",
    '::execv("/proc/self/exe", argv.data());',
):
    if required not in state:
        raise RuntimeError(f"statemanagerimp.cpp: corrected V13 verification missing: {required}")

if "OPENMW_TSP_WARM_LOADS_BEFORE_FRESH" in state or "periodic-reset" in state:
    raise RuntimeError("statemanagerimp.cpp: old automatic hybrid reload policy still remains")

# =====================================================================
# 2. DEFAULT-FRAMEBUFFER DEPTH PRECISION + DIAGNOSTICS
# =====================================================================
if DEPTH_V13 not in engine:
    include_anchor = '#include "engine.hpp"\n'
    if include_anchor not in engine:
        raise RuntimeError("engine.cpp: engine.hpp include anchor missing")
    extra = ""
    if "#include <cstdlib>" not in engine:
        extra += "#include <cstdlib>\n"
    if "#include <cstring>" not in engine:
        extra += "#include <cstring>\n"
    if extra:
        engine = engine.replace(include_anchor, include_anchor + "\n" + extra, 1)

    class_match = re.search(r"^[ \t]*class[ \t]+IdentifyOpenGLOperation\b", engine, flags=re.MULTILINE)
    if not class_match:
        raise RuntimeError("engine.cpp: IdentifyOpenGLOperation class anchor not found")
    indent = re.match(r"[ \t]*", engine[class_match.start():]).group(0)

    helper_lines = [
        "// TSP_DEPTH_DIAG_051_V13",
        "// Prefer a 32-bit default depth buffer on the TSP. SDL/GL4ES may",
        "// return 24 or 16; createWindow() retries progressively when needed.",
        "int tspRequestedDepthBits()",
        "{",
        "    constexpr int defaultDepth = 32;",
        '    const char* value = std::getenv("OPENMW_TSP_DEPTH_BITS");',
        "    if (value == nullptr || *value == '\\0')",
        "        return defaultDepth;",
        "    char* end = nullptr;",
        "    const long parsed = std::strtol(value, &end, 10);",
        "    if (end != value && *end == '\\0' && (parsed == 16 || parsed == 24 || parsed == 32))",
        "        return static_cast<int>(parsed);",
        '    Log(Debug::Warning) << "TSP DEPTH invalid OPENMW_TSP_DEPTH_BITS=\'" << value',
        '                        << "\'; using " << defaultDepth;',
        "    return defaultDepth;",
        "}",
        "",
    ]
    depth_helper = "\n".join(indent + line if line else "" for line in helper_lines)
    engine = engine[:class_match.start()] + depth_helper + engine[class_match.start():]

    version_re = re.compile(
        r'(?P<indent>^[ \t]*)Log\(Debug::Info\)[ \t]*<<[ \t]*"OpenGL Version: "[ \t]*<<[ \t]*glGetString\(GL_VERSION\);',
        flags=re.MULTILINE,
    )
    vm = version_re.search(engine)
    if not vm:
        raise RuntimeError("engine.cpp: OpenGL Version log anchor not found")
    ind = vm.group("indent")
    diag_lines = [
        "GLint tspGlDepthBits = -1;",
        "GLint tspGlStencilBits = -1;",
        "GLint tspDepthFunc = -1;",
        "GLfloat tspDepthRange[2] = { -1.f, -1.f };",
        "glGetIntegerv(GL_DEPTH_BITS, &tspGlDepthBits);",
        "glGetIntegerv(GL_STENCIL_BITS, &tspGlStencilBits);",
        "glGetIntegerv(GL_DEPTH_FUNC, &tspDepthFunc);",
        "glGetFloatv(GL_DEPTH_RANGE, tspDepthRange);",
        "int tspSdlDepthBits = -1;",
        "int tspSdlStencilBits = -1;",
        "SDL_GL_GetAttribute(SDL_GL_DEPTH_SIZE, &tspSdlDepthBits);",
        "SDL_GL_GetAttribute(SDL_GL_STENCIL_SIZE, &tspSdlStencilBits);",
        "const char* tspExtensions = reinterpret_cast<const char*>(glGetString(GL_EXTENSIONS));",
        'const bool tspOesDepth24 = tspExtensions && std::strstr(tspExtensions, "GL_OES_depth24");',
        "const bool tspPackedDepthStencil",
        '    = tspExtensions && (std::strstr(tspExtensions, "GL_OES_packed_depth_stencil")',
        '        || std::strstr(tspExtensions, "GL_EXT_packed_depth_stencil"));',
        'const bool tspFragDepth = tspExtensions && std::strstr(tspExtensions, "GL_EXT_frag_depth");',
        'Log(Debug::Info) << "TSP_DEPTH_DIAG_051_V13"',
        '                 << " gl_depth_bits=" << tspGlDepthBits',
        '                 << " gl_stencil_bits=" << tspGlStencilBits',
        '                 << " sdl_depth_bits=" << tspSdlDepthBits',
        '                 << " sdl_stencil_bits=" << tspSdlStencilBits',
        '                 << " depth_func=" << tspDepthFunc',
        '                 << " depth_range=" << tspDepthRange[0] << "," << tspDepthRange[1]',
        '                 << " oes_depth24=" << (tspOesDepth24 ? 1 : 0)',
        '                 << " packed_depth_stencil=" << (tspPackedDepthStencil ? 1 : 0)',
        '                 << " ext_frag_depth=" << (tspFragDepth ? 1 : 0);',
    ]
    diag = "\n" + "\n".join(ind + line for line in diag_lines)
    engine = engine[:vm.end()] + diag + engine[vm.end():]

    depth_line_re = re.compile(
        r'(?P<indent>^[ \t]*)(?:checkSDLError\()?SDL_GL_SetAttribute\(SDL_GL_DEPTH_SIZE,[ \t]*24\)\)?;',
        flags=re.MULTILINE,
    )
    dm = depth_line_re.search(engine)
    if not dm:
        raise RuntimeError("engine.cpp: stock SDL_GL_DEPTH_SIZE=24 request anchor not found")
    dind = dm.group("indent")
    request_lines = [
        "int tspDepthBits = tspRequestedDepthBits();",
        "const int tspInitialDepthBits = tspDepthBits;",
        "int tspStencilBits = 8;",
        'Log(Debug::Info) << "TSP_DEPTH_REQUEST_051_V13 requested_depth=" << tspDepthBits',
        '                 << " requested_stencil=" << tspStencilBits;',
        "SDL_GL_SetAttribute(SDL_GL_DEPTH_SIZE, tspDepthBits);",
        "SDL_GL_SetAttribute(SDL_GL_STENCIL_SIZE, tspStencilBits);",
    ]
    request_block = "\n".join(dind + line for line in request_lines)
    engine = engine[:dm.start()] + request_block + engine[dm.end():]

    create_sig_candidates = [
        r"^[ \t]*(?:SDL_Window\*|void)[ \t]+(?:OMW::)?Engine::createWindow[ \t]*\(",
        r"^[ \t]*[^\n;{]+[ \t]+(?:OMW::)?Engine::createWindow[ \t]*\(",
    ]
    last_error = None
    for candidate in create_sig_candidates:
        try:
            cstart, cend = find_function(engine, candidate, "Engine::createWindow")
            break
        except RuntimeError as exc:
            last_error = exc
    else:
        raise last_error

    cfunc = engine[cstart:cend]
    error_anchor_re = re.compile(
        r'(?P<indent>^[ \t]*)std::stringstream[ \t]+error;\n(?P=indent)error[ \t]*<<[ \t]*"Failed to create SDL window',
        flags=re.MULTILINE,
    )
    em = error_anchor_re.search(cfunc)
    if not em:
        raise RuntimeError("engine.cpp: final SDL window error anchor not found")
    eind = em.group("indent")
    fallback_lines = [
        "if (tspDepthBits > 24)",
        "{",
        '    Log(Debug::Warning) << "TSP DEPTH: SDL window creation failed at depth="',
        '                        << tspDepthBits << "; retrying depth=24";',
        "    tspDepthBits = 24;",
        "    SDL_GL_SetAttribute(SDL_GL_DEPTH_SIZE, tspDepthBits);",
        "    continue;",
        "}",
        "if (tspDepthBits > 16)",
        "{",
        '    Log(Debug::Warning) << "TSP DEPTH: SDL window creation failed at depth=24; retrying depth=16";',
        "    tspDepthBits = 16;",
        "    SDL_GL_SetAttribute(SDL_GL_DEPTH_SIZE, tspDepthBits);",
        "    continue;",
        "}",
        "if (tspStencilBits > 0)",
        "{",
        '    Log(Debug::Warning) << "TSP DEPTH: SDL window creation still failed; retrying stencil=0";',
        "    tspStencilBits = 0;",
        "    SDL_GL_SetAttribute(SDL_GL_STENCIL_SIZE, tspStencilBits);",
        "    continue;",
        "}",
    ]
    fallback = "\n".join(eind + line for line in fallback_lines) + "\n"
    cfunc = cfunc[:em.start()] + fallback + cfunc[em.start():]
    engine = engine[:cstart] + cfunc + engine[cend:]

    traits_re = re.compile(
        r'(?P<indent>^[ \t]*)if[ \t]*\(traits->depth[ \t]*<[ \t]*24\)',
        flags=re.MULTILINE,
    )
    tm = traits_re.search(engine)
    if tm:
        tind = tm.group("indent")
        traits_lines = [
            'Log(Debug::Info) << "TSP_DEPTH_TRAITS_051_V13 initial_request=" << tspInitialDepthBits',
            '                 << " active_request=" << tspDepthBits',
            '                 << " active_stencil_request=" << tspStencilBits',
            '                 << " osg_depth=" << traits->depth',
            '                 << " osg_stencil=" << traits->stencil;',
        ]
        traits_log = "\n".join(tind + line for line in traits_lines) + "\n"
        engine = engine[:tm.start()] + traits_log + engine[tm.start():]

for required in (
    DEPTH_V13,
    "TSP_DEPTH_REQUEST_051_V13",
    "OPENMW_TSP_DEPTH_BITS",
    "GL_DEPTH_BITS",
    "GL_STENCIL_BITS",
    "GL_OES_depth24",
    "GL_EXT_frag_depth",
    "retrying depth=24",
    "retrying depth=16",
):
    if required not in engine:
        raise RuntimeError(f"engine.cpp: missing depth verification string: {required}")


# =====================================================================
# 3. PROJECTION/NEAR-FAR DIAGNOSTICS
# =====================================================================
if PROJ_V13 not in render:
    sig = r"^[ \t]*void[ \t]+RenderingManager::updateProjectionMatrix[ \t]*\(\)"
    rstart, rend = find_function(render, sig, "RenderingManager::updateProjectionMatrix")
    rfunc = render[rstart:rend]

    anchor = "        const float fov = mFieldOfViewOverridden ? mFieldOfViewOverride : mFieldOfView;\n"
    if anchor not in rfunc:
        raise RuntimeError("renderingmanager.cpp: FOV anchor in updateProjectionMatrix missing")
    proj_log = r'''        Log(Debug::Info) << "TSP_DEPTH_PROJECTION_051_V13"
                         << " near=" << mNearClip
                         << " far=" << mViewDistance
                         << " far_near_ratio=" << (mNearClip > 0.f ? mViewDistance / mNearClip : 0.f)
                         << " fov=" << fov
                         << " reversed=" << (SceneUtil::AutoDepth::isReversed() ? 1 : 0);
'''
    rfunc = rfunc.replace(anchor, anchor + "\n" + proj_log, 1)
    render = render[:rstart] + rfunc + render[rend:]

if PROJ_V13 not in render:
    raise RuntimeError("renderingmanager.cpp: projection diagnostic marker missing")


# =====================================================================
# 4. WARM-RELOAD LIFETIME REPAIR
# =====================================================================
WARM_RESET = "TSP_WARM_LIFETIME_RESET_051_V13"
ANIM_SWAP = "TSP_PLAYER_ANIMATION_SWAP_051_V13"

if WARM_RESET not in world:
    w_sig = r"^[ \t]*void[ \t]+World::clear[ \t]*\(\)"
    wstart, wend = find_function(world, w_sig, "World::clear")
    wfunc = world[wstart:wend]
    anchor_world = "        mWeatherManager->clear();\n"
    if anchor_world not in wfunc:
        raise RuntimeError("worldimp.cpp: World::clear weather anchor missing")
    detach = r'''        // TSP_WARM_LIFETIME_RESET_051_V13
        // Detach raw InventoryStore listeners while the old NpcAnimation and
        // old dynamic player data are both still valid. They are rebound by
        // World::renderPlayer() after the save has been read.
        if (mPlayer)
        {
            MWWorld::Ptr tspOldPlayer = getPlayerPtr();
            auto& tspInventory = tspOldPlayer.getClass().getInventoryStore(tspOldPlayer);
            tspInventory.setInvListener(nullptr);
            tspInventory.setContListener(nullptr);
            Log(Debug::Info) << "TSP_WARM_LIFETIME_RESET_051_V13 phase=player-listeners-detached";
        }
'''
    wfunc = wfunc.replace(anchor_world, detach + anchor_world, 1)
    world = world[:wstart] + wfunc + world[wend:]

if WARM_RESET not in render:
    clear_sig = r"^[ \t]*void[ \t]+RenderingManager::clear[ \t]*\(\)"
    rstart, rend = find_function(render, clear_sig, "RenderingManager::clear")
    rfunc = render[rstart:rend]
    clear_anchor = "        mSky->setMoonColour(false);\n"
    if clear_anchor not in rfunc:
        raise RuntimeError("renderingmanager.cpp: clear sky anchor missing")
    release = r'''        // TSP_WARM_LIFETIME_RESET_051_V13
        // Release the old player animation before World::clear() destroys and
        // replaces the dynamic player record. Camera is immediately rebound by
        // renderPlayer() before control returns to the frame loop.
        if (mPlayerAnimation)
        {
            mCamera->setAnimation(nullptr);
            mPlayerAnimation = nullptr;
            Log(Debug::Info) << "TSP_WARM_LIFETIME_RESET_051_V13 phase=old-player-animation-released";
        }
        if (mPlayerNode)
            mPlayerNode->setUserDataContainer(new osg::DefaultUserDataContainer);
'''
    rfunc = rfunc.replace(clear_anchor, release + clear_anchor, 1)
    render = render[:rstart] + rfunc + render[rend:]

if ANIM_SWAP not in render:
    rp_sig = r"^[ \t]*void[ \t]+RenderingManager::renderPlayer[ \t]*\(const MWWorld::Ptr& player\)"
    rpstart, rpend = find_function(render, rp_sig, "RenderingManager::renderPlayer")
    old_func = render[rpstart:rpend]
    signature_end = old_func.find("{")
    if signature_end < 0:
        raise RuntimeError("renderingmanager.cpp: renderPlayer opening brace missing")
    signature = old_func[:signature_end]
    new_func = signature + r'''{
        // TSP_PLAYER_ANIMATION_SWAP_051_V13
        // Keep the previous animation alive until the camera has been pointed
        // at the new one. This avoids a raw camera pointer briefly referring to
        // an animation that is being destroyed during a warm save reload.
        osg::ref_ptr<NpcAnimation> tspPreviousAnimation = mPlayerAnimation;
        Log(Debug::Info) << "TSP_PLAYER_ANIMATION_SWAP_051_V13 phase=construct-new-begin";
        osg::ref_ptr<NpcAnimation> tspNewAnimation = new NpcAnimation(player,
            player.getRefData().getBaseNode(), mResourceSystem, 0,
            NpcAnimation::VM_Normal, mFirstPersonFieldOfView);
        Log(Debug::Info) << "TSP_PLAYER_ANIMATION_SWAP_051_V13 phase=construct-new-done";

        mCamera->setAnimation(tspNewAnimation.get());
        mCamera->attachTo(player);
        mPlayerAnimation = tspNewAnimation;
        Log(Debug::Info) << "TSP_PLAYER_ANIMATION_SWAP_051_V13 phase=camera-repointed";

        tspPreviousAnimation = nullptr;
        Log(Debug::Info) << "TSP_PLAYER_ANIMATION_SWAP_051_V13 phase=old-animation-released";
    }'''
    render = render[:rpstart] + new_func + render[rpend:]

for text, marker, label in (
    (world, WARM_RESET, "worldimp.cpp"),
    (render, WARM_RESET, "renderingmanager.cpp"),
    (render, ANIM_SWAP, "renderingmanager.cpp"),
):
    if marker not in text:
        raise RuntimeError(f"{label}: warm reload lifetime marker missing: {marker}")

write_lf(state_path, state)
write_lf(engine_path, engine)
write_lf(render_path, render)
write_lf(world_path, world)

print("Corrected V13 source revision applied.")
print("  load policy: warm/in-process by default; settings.cfg safe reload is opt-in")
print("  warm repair: old player listeners/animation lifetime hardened")
print("  load diagnostics: phases, content mapping, records, post-load watch")
print("  depth request: default 32-bit with 24/16 + stencil fallback")
print("  diagnostics: actual GL/SDL depth + projection near/far")
print("  transition purge: remains absent")
PY_PATCH

echo
echo "===== SOURCE VERIFICATION ====="
echo "Corrected warm-load/safety markers:"
grep -n -m 24 \
    -e 'TSP_SAFE_RELOAD_CONFIG_051_V13' \
    -e 'TSP_SAFE_RELOAD_051_V13' \
    -e 'TSP_LOAD_TRACE_051_V13' \
    -e 'TSP_LOAD_CONTENT_051_V13' \
    -e 'TSP_LOAD_RECORDS_051_V13' \
    -e 'TSP_LOAD_WATCH_051_V13' \
    "$STATE_CPP"

echo
echo "Warm lifetime repair markers:"
grep -n -m 16 -e 'TSP_WARM_LIFETIME_RESET_051_V13' "$WORLD_CPP" "$RENDER_CPP"
grep -n -m 16 -e 'TSP_PLAYER_ANIMATION_SWAP_051_V13' "$RENDER_CPP"

echo
echo "Old automatic hybrid policy must be absent:"
if grep -q \
    -e 'TSP_HYBRID_LOAD_POLICY_051_V13' \
    -e 'OPENMW_TSP_LOAD_MODE' \
    -e 'OPENMW_TSP_WARM_LOADS_BEFORE_FRESH' \
    -e 'periodic-reset' \
    "$STATE_CPP"; then
    echo "ERROR: old automatic hybrid policy still exists in source."
    exit 1
else
    echo "  PASS: no automatic warm/fresh counter remains."
fi
echo
echo "Depth markers:"
grep -n -m 16 \
    -e 'TSP_DEPTH_DIAG_051_V13' \
    -e 'TSP_DEPTH_REQUEST_051_V13' \
    -e 'TSP_DEPTH_TRAITS_051_V13' \
    -e 'OPENMW_TSP_DEPTH_BITS' \
    -e 'retrying depth=' \
    "$ENGINE_CPP"

echo
echo "Projection marker:"
grep -n -m 4 'TSP_DEPTH_PROJECTION_051_V13' "$RENDER_CPP"

echo
echo "Stable V12 fresh-exec fallback still present:"
grep -n -m 4 \
    -e 'TSP_FRESH_PROCESS_LOAD_051_V12' \
    -e 'execv("/proc/self/exe"' \
    "$STATE_CPP"

echo
echo "Transition-memory purge must still be absent:"
if grep -RniE \
    'TSP_TRANSITION_MEMORY_PURGE_051|TSP_UNREFERENCED_CACHE_PURGE_051|TSP MEMPURGE|tspPurgeTransitionMemory|clearUnreferencedCache' \
    "$SOURCE_DIR/apps/openmw/mwworld/scene.cpp" \
    "$SOURCE_DIR/components/resource" 2>/dev/null
then
    echo "ERROR: transition-memory-purge remnant found after patch."
    exit 1
else
    echo "  PASS: no transition-memory-purge source markers found."
fi

if [ "$PATCH_ONLY" = "1" ]; then
    trap - ERR
    echo
    echo "PATCH_ONLY=1: V13 source patch/verification completed."
    exit 0
fi

echo
echo "Incrementally rebuilding OpenMW 0.51 (UNSTRIPPED)..."
cmake --build "$BUILD_DIR" --target openmw --parallel "$JOBS"

if [ ! -x "$BUILT_BINARY" ]; then
    echo "ERROR: rebuilt OpenMW executable is missing:"
    echo "  $BUILT_BINARY"
    exit 1
fi

if [ -e "$OUTPUT_BINARY" ]; then
    cp -f "$OUTPUT_BINARY" "$OUTPUT_BINARY.before-$STAMP"
fi
if [ -e "$PACKAGE_BINARY" ]; then
    cp -f "$PACKAGE_BINARY" "$PACKAGE_BINARY.before-depth-warmreload-v13-$STAMP"
fi

cp -f "$BUILT_BINARY" "$OUTPUT_BINARY"
cp -f "$BUILT_BINARY" "$PACKAGE_BINARY"
chmod +x "$OUTPUT_BINARY" "$PACKAGE_BINARY"

echo
echo "===== BINARY VERIFICATION ====="
file "$PACKAGE_BINARY"
sha256sum "$PACKAGE_BINARY"
"$PACKAGE_BINARY" --version || true

for marker in \
    'TSP_FRESH_PROCESS_LOAD_051_V12' \
    'TSP_SAFE_RELOAD_CONFIG_051_V13' \
    'TSP_SAFE_RELOAD_051_V13 action=warm' \
    'TSP_LOAD_TRACE_051_V13' \
    'TSP_LOAD_CONTENT_051_V13' \
    'TSP_LOAD_RECORDS_051_V13' \
    'TSP_LOAD_WATCH_051_V13' \
    'TSP_WARM_LIFETIME_RESET_051_V13' \
    'TSP_PLAYER_ANIMATION_SWAP_051_V13' \
    'TSP_DEPTH_DIAG_051_V13' \
    'TSP_DEPTH_REQUEST_051_V13' \
    'TSP_DEPTH_PROJECTION_051_V13' \
    'OPENMW_TSP_SAFE_RELOAD' \
    'OPENMW_TSP_DEPTH_BITS'
do
    if ! strings "$PACKAGE_BINARY" | grep -F "$marker" >/dev/null; then
        echo "ERROR: required runtime marker missing from rebuilt binary: $marker"
        exit 1
    fi
done
printf '  PASS: corrected warm-load/safety + V12 fallback + depth markers present.\n'

if strings "$PACKAGE_BINARY" | grep -E 'OPENMW_TSP_LOAD_MODE|OPENMW_TSP_WARM_LOADS_BEFORE_FRESH|periodic-reset' >/dev/null; then
    echo "ERROR: old automatic hybrid policy survived into rebuilt binary."
    exit 1
else
    echo "  PASS: old automatic hybrid counter absent from binary."
fi


if strings "$PACKAGE_BINARY" | grep -E \
    'TSP MEMPURGE|TSP_TRANSITION_MEMORY_PURGE_051|TSP_UNREFERENCED_CACHE_PURGE_051' >/dev/null
then
    echo "ERROR: transition-memory-purge marker unexpectedly present in binary."
    exit 1
else
    echo "  PASS: transition-memory-purge markers absent."
fi

echo
echo "SafeNav marker (expected to remain):"
strings "$PACKAGE_BINARY" | grep -F -m 3 'TSP SafeNav' || \
    echo "WARNING: SafeNav marker string not found; inspect source/runtime before enabling navigator."

trap - ERR

echo
echo "============================================================"
echo "SUCCESS: OpenMW 0.51 V13 depth + warm-load repair build complete"
echo "============================================================"
echo "Package binary:"
echo "  $PACKAGE_BINARY"
echo "Container backup copy:"
echo "  $OUTPUT_BINARY"
echo "Source backup:"
echo "  $BACKUP_DIR"
echo
echo "Default runtime policy:"
echo "  title-screen first load = normal"
echo "  every active-game load  = repaired warm/in-process load"
echo "  ESM/ESP content          = NOT reparsed on warm reload"
echo "  safe fallback            = OFF unless settings.cfg enables it"
echo "  depth request            = 32, fallback 24, then 16"
echo
echo "settings.cfg safety switch:"
echo "  [TSP]"
echo "  safe reload = 0    # default: warm/in-process"
echo "  safe reload = 1    # proven fresh-process fallback"
echo
echo "Optional SSH/environment overrides:"
echo "  OPENMW_TSP_SAFE_RELOAD=0|1"
echo "  OPENMW_TSP_DEPTH_BITS=16|24|32"
echo "============================================================"
