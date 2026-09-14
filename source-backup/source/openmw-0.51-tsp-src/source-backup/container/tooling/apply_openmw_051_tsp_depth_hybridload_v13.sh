#!/bin/bash
set -Eeuo pipefail

SOURCE_DIR="${1:-/root/openmw-0.51-tsp-src}"
BUILD_DIR="${2:-/root/openmw-0.51-tsp-build}"
PACKAGE_DIR="${3:-/root/openmw-0.51-tsp-package}"
OUTPUT_BINARY="${4:-/root/openmw-0.51-tsp-depth-hybridload-v13}"

JOBS="${OPENMW_JOBS:-1}"
PATCH_ONLY="${OPENMW_PATCH_ONLY:-0}"

STATE_CPP="$SOURCE_DIR/apps/openmw/mwstate/statemanagerimp.cpp"
ENGINE_CPP="$SOURCE_DIR/apps/openmw/engine.cpp"
RENDER_CPP="$SOURCE_DIR/apps/openmw/mwrender/renderingmanager.cpp"
CMAKE_FILE="$SOURCE_DIR/CMakeLists.txt"
BUILT_BINARY="$BUILD_DIR/openmw"
PACKAGE_BINARY="$PACKAGE_DIR/bin/openmw-0.51"

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="$SOURCE_DIR/.tsp-051-source-backups/depth-hybridload-v13-$STAMP"

restore_on_error() {
    rc=$?
    if [ "$rc" -ne 0 ] && [ -d "$BACKUP_DIR" ]; then
        echo
        echo "ERROR: V13 combined patch/build failed."
        echo "Restoring the source files changed by this attempt..."
        [ -f "$BACKUP_DIR/apps/openmw/mwstate/statemanagerimp.cpp" ] && \
            cp -f "$BACKUP_DIR/apps/openmw/mwstate/statemanagerimp.cpp" "$STATE_CPP"
        [ -f "$BACKUP_DIR/apps/openmw/engine.cpp" ] && \
            cp -f "$BACKUP_DIR/apps/openmw/engine.cpp" "$ENGINE_CPP"
        [ -f "$BACKUP_DIR/apps/openmw/mwrender/renderingmanager.cpp" ] && \
            cp -f "$BACKUP_DIR/apps/openmw/mwrender/renderingmanager.cpp" "$RENDER_CPP"
        echo "Source restoration complete."
        echo "Failed-attempt backup retained at:"
        echo "  $BACKUP_DIR"
    fi
    exit "$rc"
}
trap restore_on_error ERR

echo "============================================================"
echo "OpenMW 0.51 TSP V13 DEPTH + HYBRID LOAD REVISION"
echo "============================================================"
echo "Source:        $SOURCE_DIR"
echo "Build:         $BUILD_DIR"
echo "Package:       $PACKAGE_DIR"
echo "Output binary: $OUTPUT_BINARY"
echo "Patch only:    $PATCH_ONLY"
echo "Jobs:          $JOBS"
echo "Backup:        $BACKUP_DIR"
echo "============================================================"

for required in "$STATE_CPP" "$ENGINE_CPP" "$RENDER_CPP" "$CMAKE_FILE"; do
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
    "$PACKAGE_DIR/bin"

cp -f "$STATE_CPP"  "$BACKUP_DIR/apps/openmw/mwstate/statemanagerimp.cpp"
cp -f "$ENGINE_CPP" "$BACKUP_DIR/apps/openmw/engine.cpp"
cp -f "$RENDER_CPP" "$BACKUP_DIR/apps/openmw/mwrender/renderingmanager.cpp"

echo
echo "Applying combined V13 source revision..."

python3 - "$STATE_CPP" "$ENGINE_CPP" "$RENDER_CPP" <<'PY_PATCH'
from pathlib import Path
import re
import sys

state_path, engine_path, render_path = map(Path, sys.argv[1:])
state = state_path.read_text(encoding="utf-8")
engine = engine_path.read_text(encoding="utf-8")
render = render_path.read_text(encoding="utf-8")

V12 = "TSP_FRESH_PROCESS_LOAD_051_V12"
LOAD_V13 = "TSP_HYBRID_LOAD_POLICY_051_V13"
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
# 1. HYBRID WARM/FRESH SAVE LOADING
# =====================================================================
if V12 not in state:
    raise RuntimeError("statemanagerimp.cpp: V12 fresh-load baseline marker missing")

if LOAD_V13 not in state:
    if "#include <malloc.h>" not in state:
        linux_include = "#include <unistd.h>\n"
        if linux_include not in state:
            raise RuntimeError("statemanagerimp.cpp: V12 Linux include anchor not found")
        state = state.replace(
            linux_include,
            linux_include + "#if defined(__GLIBC__)\n#include <malloc.h>\n#endif\n",
            1,
        )

    fresh_sig = r"^[ \t]*bool[ \t]+tspFreshProcessLoadsEnabled[ \t]*\(\)"
    _fstart, fend = find_function(state, fresh_sig, "tspFreshProcessLoadsEnabled")

    policy = r'''

    // TSP_HYBRID_LOAD_POLICY_051_V13
    // Default: one warm in-process reload, then the proven V12 fresh exec.
    // Death reloads stay fresh by default because death->load was a strong
    // crash trigger during the TSP stability tests.
    enum class TspLoadMode
    {
        Fresh,
        Warm,
        Hybrid,
    };

    TspLoadMode tspGetLoadMode()
    {
        if (const char* mode = std::getenv("OPENMW_TSP_LOAD_MODE"))
        {
            if (std::strcmp(mode, "fresh") == 0)
                return TspLoadMode::Fresh;
            if (std::strcmp(mode, "warm") == 0)
                return TspLoadMode::Warm;
            if (std::strcmp(mode, "hybrid") == 0)
                return TspLoadMode::Hybrid;

            Log(Debug::Warning)
                << "TSP LOADMODE unknown OPENMW_TSP_LOAD_MODE='" << mode
                << "'; using hybrid";
        }

        if (!tspFreshProcessLoadsEnabled())
            return TspLoadMode::Warm;

        return TspLoadMode::Hybrid;
    }

    const char* tspLoadModeName(TspLoadMode mode)
    {
        switch (mode)
        {
            case TspLoadMode::Fresh:
                return "fresh";
            case TspLoadMode::Warm:
                return "warm";
            case TspLoadMode::Hybrid:
            default:
                return "hybrid";
        }
    }

    unsigned tspWarmLoadsBeforeFresh()
    {
        constexpr unsigned defaultLimit = 1;
        const char* value = std::getenv("OPENMW_TSP_WARM_LOADS_BEFORE_FRESH");
        if (value == nullptr || *value == '\0')
            return defaultLimit;

        char* end = nullptr;
        errno = 0;
        const long parsed = std::strtol(value, &end, 10);
        if (errno != 0 || end == value || *end != '\0' || parsed < 0)
        {
            Log(Debug::Warning)
                << "TSP LOADMODE invalid OPENMW_TSP_WARM_LOADS_BEFORE_FRESH='"
                << value << "'; using " << defaultLimit;
            return defaultLimit;
        }

        return static_cast<unsigned>(parsed > 100 ? 100 : parsed);
    }

    bool tspShouldFreshRestartForLoad(const std::filesystem::path& filepath, bool deathReload)
    {
        static unsigned warmLoadsSinceFresh = 0;
        const TspLoadMode mode = tspGetLoadMode();

        if (mode == TspLoadMode::Warm)
        {
            Log(Debug::Info)
                << "TSP LOADMODE mode=" << tspLoadModeName(mode)
                << " action=warm reason=forced save=" << filepath.filename();
            return false;
        }

        if (deathReload)
        {
            Log(Debug::Info)
                << "TSP LOADMODE mode=" << tspLoadModeName(mode)
                << " action=fresh reason=death save=" << filepath.filename();
            return true;
        }

        if (mode == TspLoadMode::Fresh)
        {
            Log(Debug::Info)
                << "TSP LOADMODE mode=fresh action=fresh reason=forced save="
                << filepath.filename();
            return true;
        }

        const unsigned limit = tspWarmLoadsBeforeFresh();
        if (warmLoadsSinceFresh < limit)
        {
            ++warmLoadsSinceFresh;
            Log(Debug::Info)
                << "TSP LOADMODE mode=hybrid action=warm warm_index="
                << warmLoadsSinceFresh << " warm_limit=" << limit
                << " save=" << filepath.filename();
            return false;
        }

        Log(Debug::Info)
            << "TSP LOADMODE mode=hybrid action=fresh warm_index="
            << warmLoadsSinceFresh << " warm_limit=" << limit
            << " reason=periodic-reset save=" << filepath.filename();
        return true;
    }
'''
    state = state[:fend] + policy + state[fend:]

    load_sig = r"^[ \t]*void[ \t]+MWState::StateManager::loadGame[ \t]*\(const Character\* character,[ \t]*const std::filesystem::path& filepath\)"
    lstart, lend = find_function(state, load_sig, "StateManager::loadGame(Character*, path)")
    func = state[lstart:lend]

    old_hook_re = re.compile(
        r'#if defined\(__linux__\)\n'
        r'[ \t]*if \(mState != State_NoGame && tspFreshProcessLoadsEnabled\(\)\)\n'
        r'[ \t]*tspRestartForSaveLoad\(filepath\);\n'
        r'#endif\n\n'
    )
    func, hook_count = old_hook_re.subn("", func, count=1)
    if hook_count != 1:
        raise RuntimeError("statemanagerimp.cpp: could not remove the V12 direct fresh-load hook")

    cleanup_anchor = "        cleanup();\n"
    if cleanup_anchor not in func:
        raise RuntimeError("statemanagerimp.cpp: loadGame cleanup() anchor missing")

    new_hook = r'''        bool tspWarmLoadThisTime = false;
#if defined(__linux__)
        if (mState != State_NoGame)
        {
            const bool deathReload = (mState == State_Ended);
            if (tspShouldFreshRestartForLoad(filepath, deathReload))
                tspRestartForSaveLoad(filepath);
            tspWarmLoadThisTime = true;
        }
#endif

        cleanup();

#if defined(__linux__) && defined(__GLIBC__)
        if (tspWarmLoadThisTime)
        {
            ::malloc_trim(0);
            Log(Debug::Info) << "TSP LOADMODE warm-cleanup malloc_trim=1";
        }
#endif
'''
    func = func.replace(cleanup_anchor, new_hook, 1)
    state = state[:lstart] + func + state[lend:]

for required in (
    V12,
    LOAD_V13,
    "OPENMW_TSP_LOAD_MODE",
    "OPENMW_TSP_WARM_LOADS_BEFORE_FRESH",
    "tspShouldFreshRestartForLoad(filepath, deathReload)",
    '::execv("/proc/self/exe", argv.data());',
    "TSP LOADMODE mode=hybrid action=warm",
    "TSP LOADMODE warm-cleanup malloc_trim=1",
):
    if required not in state:
        raise RuntimeError(f"statemanagerimp.cpp: missing load-policy verification string: {required}")


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

write_lf(state_path, state)
write_lf(engine_path, engine)
write_lf(render_path, render)

print("V13 combined source revision applied.")
print("  load policy: default hybrid (1 warm, then fresh); death fresh")
print("  depth request: default 32-bit with 24/16 + stencil fallback")
print("  diagnostics: actual GL/SDL depth + projection near/far")
print("  transition purge: remains absent")
PY_PATCH

echo
echo "===== SOURCE VERIFICATION ====="
echo "Load policy markers:"
grep -n -m 12 \
    -e 'TSP_HYBRID_LOAD_POLICY_051_V13' \
    -e 'OPENMW_TSP_LOAD_MODE' \
    -e 'OPENMW_TSP_WARM_LOADS_BEFORE_FRESH' \
    -e 'TSP LOADMODE' \
    "$STATE_CPP"

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
    cp -f "$PACKAGE_BINARY" "$PACKAGE_BINARY.before-depth-hybridload-v13-$STAMP"
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
    'TSP_HYBRID_LOAD_POLICY_051_V13' \
    'TSP_FRESH_PROCESS_LOAD_051_V12' \
    'TSP_DEPTH_DIAG_051_V13' \
    'TSP_DEPTH_REQUEST_051_V13' \
    'TSP_DEPTH_PROJECTION_051_V13' \
    'OPENMW_TSP_LOAD_MODE' \
    'OPENMW_TSP_DEPTH_BITS'
do
    if ! strings "$PACKAGE_BINARY" | grep -F "$marker" >/dev/null; then
        echo "ERROR: required marker missing from rebuilt binary: $marker"
        exit 1
    fi
done
printf '  PASS: V12 fallback + V13 load/depth markers present.\n'

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
echo "SUCCESS: OpenMW 0.51 V13 depth + hybrid-load build complete"
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
echo "  first active-game load  = warm/in-process"
echo "  second active-game load = fresh exec, then counter resets"
echo "  death reload            = fresh exec"
echo "  depth request           = 32, fallback 24, then 16"
echo
echo "Runtime switches (no rebuild):"
echo "  OPENMW_TSP_LOAD_MODE=fresh|warm|hybrid"
echo "  OPENMW_TSP_WARM_LOADS_BEFORE_FRESH=0..100"
echo "  OPENMW_TSP_DEPTH_BITS=16|24|32"
echo "  Legacy: OPENMW_TSP_FRESH_LOADS=0 forces warm when LOAD_MODE is unset"
echo "============================================================"
