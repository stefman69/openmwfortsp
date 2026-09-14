#!/bin/bash
set -Eeuo pipefail

SOURCE_DIR="${1:-/root/openmw-0.51-tsp-src}"
BUILD_DIR="${2:-/root/openmw-0.51-tsp-build}"
PACKAGE_DIR="${3:-/root/openmw-0.51-tsp-package}"
OUTPUT_BINARY="${4:-/root/openmw-0.51-tsp-v19-clean-performance-resolutions}"

JOBS="${OPENMW_JOBS:-1}"
PATCH_ONLY="${OPENMW_PATCH_ONLY:-0}"

STATE_CPP="$SOURCE_DIR/apps/openmw/mwstate/statemanagerimp.cpp"
ENGINE_CPP="$SOURCE_DIR/apps/openmw/engine.cpp"
RENDER_CPP="$SOURCE_DIR/apps/openmw/mwrender/renderingmanager.cpp"
STATEUP_CPP="$SOURCE_DIR/components/sceneutil/stateupdater.cpp"

RESOURCE_CPP="$SOURCE_DIR/components/resource/resourcesystem.cpp"
SCENE_CPP="$SOURCE_DIR/components/resource/scenemanager.cpp"
INPUT_CPP="$SOURCE_DIR/apps/openmw/mwinput/inputmanagerimp.cpp"
SETTINGS_CPP="$SOURCE_DIR/apps/openmw/mwgui/settingswindow.cpp"
VIDEO_CPP="$SOURCE_DIR/components/sdlutil/sdlvideowrapper.cpp"

CMAKE_FILE="$SOURCE_DIR/CMakeLists.txt"
BUILT_BINARY="$BUILD_DIR/openmw"
PACKAGE_BINARY="$PACKAGE_DIR/bin/openmw-0.51"

STAMP="$(date +%Y%m%d-%H%M%S)"

# Exact source snapshot taken immediately before the old depth-band experiment.
# This is the known-good V15 fresh-process / visibility-first core.
BASELINE_BACKUP="${OPENMW_V19_BASELINE:-$SOURCE_DIR/.tsp-051-source-backups/v15-depthbands-syncguard-20260810-052554}"

PRE_RESTORE_BACKUP="$SOURCE_DIR/.tsp-051-source-backups/v19-pre-restore-current-$STAMP"
BACKUP_DIR="$SOURCE_DIR/.tsp-051-source-backups/v19-clean-performance-resolutions-$STAMP"

CORE_PATHS=(
    "apps/openmw/mwstate/statemanagerimp.cpp"
    "apps/openmw/engine.cpp"
    "apps/openmw/mwrender/renderingmanager.cpp"
    "components/sceneutil/stateupdater.cpp"
)

PATCH_PATHS=(
    "components/resource/resourcesystem.cpp"
    "components/resource/scenemanager.cpp"
    "apps/openmw/mwinput/inputmanagerimp.cpp"
    "apps/openmw/mwgui/settingswindow.cpp"
    "components/sdlutil/sdlvideowrapper.cpp"
)

ALL_PATHS=(
    "${CORE_PATHS[@]}"
    "${PATCH_PATHS[@]}"
)

copy_tree_files() {
    local src_root="$1"
    local dst_root="$2"
    local rel

    for rel in "${ALL_PATHS[@]}"; do
        if [ -f "$src_root/$rel" ]; then
            mkdir -p "$dst_root/$(dirname "$rel")"
            cp -f "$src_root/$rel" "$dst_root/$rel"
        fi
    done
}

restore_tree_files() {
    local src_root="$1"
    local rel

    for rel in "${ALL_PATHS[@]}"; do
        if [ -f "$src_root/$rel" ]; then
            cp -f "$src_root/$rel" "$SOURCE_DIR/$rel"
        fi
    done
}

restore_on_error() {
    rc=$?

    if [ "$rc" -ne 0 ]; then
        echo
        echo "ERROR: V19 patch/build failed."

        if [ -d "$PRE_RESTORE_BACKUP" ]; then
            echo "Restoring the exact Docker source that was live before V19..."
            restore_tree_files "$PRE_RESTORE_BACKUP"
            echo "Pre-V19 source restoration complete."
            echo "Saved copy retained at:"
            echo "  $PRE_RESTORE_BACKUP"
        elif [ -d "$BACKUP_DIR" ]; then
            echo "Restoring immediate pre-patch source..."
            restore_tree_files "$BACKUP_DIR"
            echo "Immediate source restoration complete."
        fi
    fi

    exit "$rc"
}
trap restore_on_error ERR

echo "============================================================"
echo "OpenMW 0.51 TSP V19"
echo "CLEAN PERFORMANCE + REAL RESOLUTION MENU"
echo "============================================================"
echo "Source:       $SOURCE_DIR"
echo "Build:        $BUILD_DIR"
echo "Package:      $PACKAGE_DIR"
echo "Baseline:     $BASELINE_BACKUP"
echo "Pre-restore:  $PRE_RESTORE_BACKUP"
echo "Patch backup: $BACKUP_DIR"
echo "Jobs:         $JOBS"
echo "Patch only:   $PATCH_ONLY"
echo "============================================================"

for rel in "${ALL_PATHS[@]}"; do
    [ -f "$SOURCE_DIR/$rel" ] || {
        echo "ERROR: required live source file missing:"
        echo "  $SOURCE_DIR/$rel"
        exit 1
    }
done

for rel in "${CORE_PATHS[@]}"; do
    [ -f "$BASELINE_BACKUP/$rel" ] || {
        echo "ERROR: exact V15 baseline is missing:"
        echo "  $BASELINE_BACKUP/$rel"
        exit 1
    }
done

VERSION_MAJOR="$(
    sed -n \
        's/^[[:space:]]*set(OPENMW_VERSION_MAJOR[[:space:]]*\([0-9][0-9]*\)).*/\1/p' \
        "$CMAKE_FILE" | head -1
)"
VERSION_MINOR="$(
    sed -n \
        's/^[[:space:]]*set(OPENMW_VERSION_MINOR[[:space:]]*\([0-9][0-9]*\)).*/\1/p' \
        "$CMAKE_FILE" | head -1
)"

if [ "$VERSION_MAJOR" != "0" ] || [ "$VERSION_MINOR" != "51" ]; then
    echo "ERROR: expected OpenMW 0.51; got ${VERSION_MAJOR:-?}.${VERSION_MINOR:-?}."
    exit 1
fi

if [ "$PATCH_ONLY" != "1" ]; then
    [ -f "$BUILD_DIR/build.ninja" ] || {
        echo "ERROR: configured Ninja build tree is missing."
        exit 1
    }
fi

echo
echo "===== SAVING CURRENT DOCKER SOURCE ====="

copy_tree_files "$SOURCE_DIR" "$PRE_RESTORE_BACKUP"

echo "Saved current source to:"
echo "  $PRE_RESTORE_BACKUP"

echo
echo "===== VERIFYING EXACT V15 BASELINE ====="

python3 - "$BASELINE_BACKUP/apps/openmw/mwstate/statemanagerimp.cpp" <<'PY_BASELINE'
from pathlib import Path
import re
import sys

text = Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace")

for marker in (
    "TSP_FRESH_DEFAULT_051_V15",
    "TSP_FRESH_PROCESS_LOAD_051_V12",
    "TSP_SAFE_RELOAD_CONFIG_051_V13",
    "TSP_LOAD_TRACE_051_V13",
    "TSP_LOAD_WATCH_051_V13",
):
    if marker not in text:
        raise SystemExit(f"ERROR: selected V15 baseline lacks {marker}")

if not re.search(
    r'//\s*TSP_FRESH_DEFAULT_051_V15\s*\n\s*bool\s+enabled\s*=\s*true\s*;',
    text,
):
    raise SystemExit(
        "ERROR: selected V15 baseline does not default fresh reload to true."
    )

print("PASS: selected V15 baseline is fresh-process by default.")
PY_BASELINE

echo
echo "===== RESTORING EXACT V15 CORE ====="

for rel in "${CORE_PATHS[@]}"; do
    cp -f "$BASELINE_BACKUP/$rel" "$SOURCE_DIR/$rel"
done

echo "PASS: exact V15 state/engine/renderer/state-updater restored."

echo
echo "===== V15 CLEAN-BASE VERIFICATION ====="

for marker in \
    'TSP_FRESH_DEFAULT_051_V15' \
    'TSP_FRESH_PROCESS_LOAD_051_V12' \
    'TSP_SAFE_RELOAD_CONFIG_051_V13' \
    'TSP_LOAD_TRACE_051_V13' \
    'TSP_LOAD_WATCH_051_V13'
do
    grep -Fq "$marker" "$STATE_CPP" || {
        echo "ERROR: restored V15 StateManager lacks:"
        echo "  $marker"
        exit 1
    }
done

grep -Fq 'TSP_VISIBILITY_FIRST_051_V15' "$RENDER_CPP" || {
    echo "ERROR: V15 visibility-first renderer marker missing."
    exit 1
}

grep -Fq 'OPENMW_TSP_DEPTH_PARTITION", false' "$RENDER_CPP" || {
    echo "ERROR: V15 old partition does not default OFF."
    exit 1
}

for bad in \
    'TSP_ADAPTIVE_DEPTH_051_V17' \
    'TSP_DEFERRED_DEPTH_051_V18' \
    'TSP_NATIVE_RESOLUTION_051_V18'
do
    if grep -Fq "$bad" "$STATE_CPP" "$ENGINE_CPP" "$RENDER_CPP" "$STATEUP_CPP"; then
        echo "ERROR: failed V17/V18 source residue survived V15 restore:"
        echo "  $bad"
        exit 1
    fi
done

if grep -RqiE \
    'TSP_TRANSITION_MEMORY_PURGE_051|TSP_UNREFERENCED_CACHE_PURGE_051|TSP MEMPURGE|tspPurgeTransitionMemory|clearUnreferencedCache' \
    "$SOURCE_DIR/apps/openmw/mwworld/scene.cpp" \
    "$SOURCE_DIR/components/resource" 2>/dev/null
then
    echo "ERROR: forbidden transition-memory-purge source is present."
    exit 1
fi

echo "PASS: crash-stable V15 fresh reload restored."
echo "PASS: V15 one-camera visibility renderer restored."
echo "PASS: V17/V18 depth code absent."
echo "PASS: transition-memory purge absent."

# These diagnostic files were outside the four-file depth experiments and
# remain from the known stable device lineage. V19 makes their hot paths opt-in.
for check in \
    "$RESOURCE_CPP:TSP_MEMORY_PROCESS_TRACE_051_V10" \
    "$SCENE_CPP:TSP_MEMORY_SCENE_TRACE_051_V10" \
    "$INPUT_CPP:TSP_CURSOR_RUNTIME_DEBUG_051_V10"
do
    file="${check%%:*}"
    marker="${check#*:}"

    grep -Fq "$marker" "$file" || {
        echo "ERROR: expected existing diagnostic marker missing:"
        echo "  $marker"
        echo "from:"
        echo "  $file"
        exit 1
    }
done

echo
echo "===== BACKING UP CLEAN V15 SOURCE BEFORE V19 PATCH ====="

copy_tree_files "$SOURCE_DIR" "$BACKUP_DIR"

STATE_SHA_BEFORE="$(sha256sum "$STATE_CPP" | awk '{print $1}')"
RENDER_SHA_BEFORE="$(sha256sum "$RENDER_CPP" | awk '{print $1}')"
STATEUP_SHA_BEFORE="$(sha256sum "$STATEUP_CPP" | awk '{print $1}')"

echo "Protected crash-stability SHA256:"
echo "  state manager: $STATE_SHA_BEFORE"
echo "  renderer:      $RENDER_SHA_BEFORE"
echo "  state updater: $STATEUP_SHA_BEFORE"

echo
echo "===== APPLYING V19 PATCH ====="

python3 - \
    "$RESOURCE_CPP" \
    "$SCENE_CPP" \
    "$INPUT_CPP" \
    "$SETTINGS_CPP" \
    "$VIDEO_CPP" \
    "$ENGINE_CPP" <<'PY_PATCH'
from pathlib import Path
import re
import sys

(
    resource_path,
    scene_path,
    input_path,
    settings_path,
    video_path,
    engine_path,
) = map(Path, sys.argv[1:])

resource = resource_path.read_text(encoding="utf-8")
scene = scene_path.read_text(encoding="utf-8")
input_cpp = input_path.read_text(encoding="utf-8")
settings = settings_path.read_text(encoding="utf-8")
video = video_path.read_text(encoding="utf-8")
engine = engine_path.read_text(encoding="utf-8")


def write_lf(path: Path, text: str):
    with path.open("w", encoding="utf-8", newline="\n") as handle:
        handle.write(text)


def ensure_include(text: str, include_line: str) -> str:
    if include_line in text:
        return text

    includes = list(
        re.finditer(r"^#include[^\n]*\n", text, flags=re.MULTILINE)
    )

    if not includes:
        raise RuntimeError(f"include insertion point missing for {include_line}")

    pos = includes[-1].end()
    return text[:pos] + include_line + "\n" + text[pos:]


def find_function(text: str, signature_pattern: str, label: str):
    matches = list(
        re.finditer(signature_pattern, text, flags=re.MULTILINE)
    )

    if len(matches) != 1:
        raise RuntimeError(
            f"{label}: expected one function signature; found {len(matches)}"
        )

    start = matches[0].start()
    opening = text.find("{", matches[0].end())

    if opening < 0:
        raise RuntimeError(f"{label}: opening brace not found")

    depth = 0
    i = opening
    in_string = False
    in_char = False
    in_line_comment = False
    in_block_comment = False
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
                    return start, opening, i + 1

        i += 1

    raise RuntimeError(f"{label}: closing brace not found")


def insert_namespace_debug_helper(text: str, namespace_name: str) -> str:
    marker = "// TSP_PERF_QUIET_HELPER_051_V19"

    if marker in text:
        return text

    text = ensure_include(text, "#include <cstdlib>")
    text = ensure_include(text, "#include <cstring>")

    ns = re.search(
        rf"namespace[ \t]+{re.escape(namespace_name)}[ \t]*\n?[ \t]*\{{",
        text,
    )

    if not ns:
        raise RuntimeError(
            f"{namespace_name}: namespace opening not found"
        )

    helper = r'''
    namespace
    {
        // TSP_PERF_QUIET_HELPER_051_V19
        bool tspV19DeepDebugEnabled()
        {
            static const bool enabled = [] {
                const char* value = std::getenv("OPENMW_TSP_DEEP_DEBUG");

                if (value == nullptr || *value == '\0')
                    return false;

                return !(std::strcmp(value, "0") == 0
                    || std::strcmp(value, "false") == 0
                    || std::strcmp(value, "off") == 0
                    || std::strcmp(value, "no") == 0);
            }();

            return enabled;
        }
    }

'''

    return text[:ns.end()] + "\n" + helper + text[ns.end():]


def gate_diagnostic_tail(
    text: str,
    signature_pattern: str,
    label: str,
    diagnostic_marker: str,
    gate_marker: str,
) -> str:
    if gate_marker in text:
        return text

    start, opening, end = find_function(
        text,
        signature_pattern,
        label,
    )

    func = text[start:end]
    marker_pos = func.find(diagnostic_marker)

    if marker_pos < 0:
        raise RuntimeError(
            f"{label}: diagnostic marker missing: {diagnostic_marker}"
        )

    line_start = func.rfind("\n", 0, marker_pos) + 1
    closing = func.rfind("}")

    if closing <= line_start:
        raise RuntimeError(f"{label}: malformed diagnostic tail")

    diagnostic_tail = func[line_start:closing]

    wrapped = (
        func[:line_start]
        + f"        // {gate_marker}\n"
        + "        if (tspV19DeepDebugEnabled())\n"
        + "        {\n"
        + diagnostic_tail
        + "        }\n"
        + func[closing:]
    )

    return text[:start] + wrapped + text[end:]


# =====================================================================
# 1. QUIET NORMAL GAMEPLAY
# =====================================================================
#
# The old memory tracer samples /proc, allocator and resource-cache state.
# The scene tracer also inspects shared OSG state under a mutex.
# Both remain available, but normal gameplay now pays only a cached bool check.

resource = insert_namespace_debug_helper(resource, "Resource")

resource = gate_diagnostic_tail(
    resource,
    r"^[ \t]*void[ \t]+ResourceSystem::updateCache[ \t]*\([^)]*\)",
    "ResourceSystem::updateCache",
    "// TSP_MEMORY_PROCESS_TRACE_051_V10",
    "TSP_PERF_QUIET_MEMORY_GATE_051_V19",
)

scene = insert_namespace_debug_helper(scene, "Resource")

scene = gate_diagnostic_tail(
    scene,
    r"^[ \t]*void[ \t]+SceneManager::updateCache[ \t]*\([^)]*\)",
    "SceneManager::updateCache",
    "// TSP_MEMORY_SCENE_TRACE_051_V10",
    "TSP_PERF_QUIET_SCENE_GATE_051_V19",
)

# Cursor diagnostic code is called from a hot input path. Keep it compiled,
# but return before doing SDL/MyGUI state queries unless deep debug is enabled.
if "TSP_PERF_QUIET_CURSOR_GATE_051_V19" not in input_cpp:
    input_cpp = ensure_include(input_cpp, "#include <cstdlib>")
    input_cpp = ensure_include(input_cpp, "#include <cstring>")

    marker_pos = input_cpp.find("// TSP_CURSOR_RUNTIME_DEBUG_051_V10")

    if marker_pos < 0:
        raise RuntimeError(
            "inputmanagerimp.cpp: cursor diagnostic marker missing"
        )

    lambda_pos = input_cpp.find(
        "auto tspLogCursorState = [&]()",
        marker_pos,
    )

    if lambda_pos < 0:
        raise RuntimeError(
            "inputmanagerimp.cpp: tspLogCursorState lambda missing"
        )

    opening = input_cpp.find("{", lambda_pos)

    if opening < 0:
        raise RuntimeError(
            "inputmanagerimp.cpp: cursor lambda opening brace missing"
        )

    gate = r'''
            // TSP_PERF_QUIET_CURSOR_GATE_051_V19
            static const bool tspV19CursorDebugEnabled = [] {
                const char* value = std::getenv("OPENMW_TSP_DEEP_DEBUG");

                if (value == nullptr || *value == '\0')
                    return false;

                return !(std::strcmp(value, "0") == 0
                    || std::strcmp(value, "false") == 0
                    || std::strcmp(value, "off") == 0
                    || std::strcmp(value, "no") == 0);
            }();

            if (!tspV19CursorDebugEnabled)
                return;
'''

    input_cpp = (
        input_cpp[:opening + 1]
        + gate
        + input_cpp[opening + 1:]
    )


# =====================================================================
# 2. REAL RESOLUTION OPTIONS IN OPENMW'S VIDEO MENU
# =====================================================================
#
# Stock OpenMW builds this list only from SDL_GetDisplayMode(). Fixed-panel
# handhelds commonly enumerate only the native panel mode. Add our own 16:9
# choices to the same vector; the existing list code still sorts and dedupes.

if "TSP_CUSTOM_RESOLUTIONS_051_V19" not in settings:
    anchor = (
        "        std::sort(resolutions.begin(), resolutions.end(), "
        "sortResolutions);\n"
    )

    if anchor not in settings:
        raise RuntimeError(
            "settingswindow.cpp: resolution sort anchor missing"
        )

    block = r'''        // TSP_CUSTOM_RESOLUTIONS_051_V19
        resolutions.emplace_back(1280, 720);
        resolutions.emplace_back(1152, 648);
        resolutions.emplace_back(1024, 576);
        resolutions.emplace_back(960, 540);
        resolutions.emplace_back(854, 480);
        resolutions.emplace_back(800, 450);
        resolutions.emplace_back(640, 360);

        Log(Debug::Info)
            << "TSP_CUSTOM_RESOLUTIONS_051_V19"
            << " presets=1280x720,1152x648,1024x576,960x540,854x480,800x450,640x360";

'''

    settings = settings.replace(
        anchor,
        block + anchor,
        1,
    )


# =====================================================================
# 3. RUNTIME RESOLUTION APPLY DIAGNOSTIC
# =====================================================================
#
# Keep OpenMW's existing SDL_SetWindowDisplayMode strategy, but check its
# return values and log the actual GL drawable after a user accepts a mode.

if "TSP_RESOLUTION_APPLY_051_V19" not in video:
    old = r'''        if (windowMode == Settings::WindowMode::Fullscreen || windowMode == Settings::WindowMode::WindowedFullscreen)
        {
            SDL_DisplayMode mode;
            SDL_GetWindowDisplayMode(mWindow, &mode);
            mode.w = width / (dw / w);
            mode.h = height / (dh / h);
            SDL_SetWindowDisplayMode(mWindow, &mode);
            SDL_SetWindowFullscreen(mWindow,
                windowMode == Settings::WindowMode::Fullscreen ? SDL_WINDOW_FULLSCREEN : SDL_WINDOW_FULLSCREEN_DESKTOP);
        }
'''

    if old not in video:
        raise RuntimeError(
            "sdlvideowrapper.cpp: stock fullscreen mode block missing"
        )

    new = r'''        if (windowMode == Settings::WindowMode::Fullscreen || windowMode == Settings::WindowMode::WindowedFullscreen)
        {
            // TSP_RESOLUTION_APPLY_051_V19
            SDL_DisplayMode mode{};
            const int getModeRc = SDL_GetWindowDisplayMode(mWindow, &mode);

            if (getModeRc == 0)
            {
                mode.w = width / (dw / w);
                mode.h = height / (dh / h);
            }

            int setModeRc = 0;

            if (windowMode == Settings::WindowMode::Fullscreen)
                setModeRc = SDL_SetWindowDisplayMode(
                    mWindow,
                    getModeRc == 0 ? &mode : nullptr);

            const int fullscreenRc = SDL_SetWindowFullscreen(
                mWindow,
                windowMode == Settings::WindowMode::Fullscreen
                    ? SDL_WINDOW_FULLSCREEN
                    : SDL_WINDOW_FULLSCREEN_DESKTOP);

            int actualW = 0;
            int actualH = 0;
            SDL_GL_GetDrawableSize(mWindow, &actualW, &actualH);

            Log(Debug::Info)
                << "TSP_RESOLUTION_APPLY_051_V19"
                << " requested=" << width << "x" << height
                << " window_mode=" << static_cast<int>(windowMode)
                << " get_mode_rc=" << getModeRc
                << " set_mode_rc=" << setModeRc
                << " fullscreen_rc=" << fullscreenRc
                << " actual_drawable=" << actualW << "x" << actualH;

            if (getModeRc < 0 || setModeRc < 0 || fullscreenRc < 0)
            {
                const std::string tspResolutionError = SDL_GetError();

                if (windowMode == Settings::WindowMode::Fullscreen)
                {
                    SDL_SetWindowFullscreen(mWindow, 0);
                    SDL_SetWindowDisplayMode(mWindow, nullptr);
                    SDL_SetWindowFullscreen(
                        mWindow,
                        SDL_WINDOW_FULLSCREEN_DESKTOP);
                }

                SDL_GL_GetDrawableSize(
                    mWindow,
                    &actualW,
                    &actualH);

                Log(Debug::Warning)
                    << "TSP resolution apply fallback"
                    << " error=" << tspResolutionError
                    << " actual_drawable="
                    << actualW << "x" << actualH;
            }
        }
'''

    video = video.replace(old, new, 1)


# =====================================================================
# 4. APPLY PERSISTED EXCLUSIVE-FULLSCREEN RESOLUTION AT STARTUP
# =====================================================================
#
# SDL2 ignores SDL_CreateWindow(width,height) when FULLSCREEN is present.
# Therefore a saved 1024x576 setting can still create a native 1280x720
# fullscreen window. Before OSG creates its GraphicsContext, switch out of
# fullscreen, set the requested fullscreen display mode, then switch back in.

if "TSP_STARTUP_RESOLUTION_APPLY_051_V19" not in engine:
    anchor = (
        "        // Since we use physical resolution internally, "
        "we have to create the window with scaled resolution,\n"
    )

    pos = engine.find(anchor)

    if pos < 0:
        raise RuntimeError(
            "engine.cpp: post-window physical-resolution anchor missing"
        )

    block = r'''        // TSP_STARTUP_RESOLUTION_APPLY_051_V19
        if (windowMode == Settings::WindowMode::Fullscreen)
        {
            const int leaveFullscreenRc
                = SDL_SetWindowFullscreen(mWindow, 0);

            SDL_DisplayMode mode{};
            const int getModeRc
                = SDL_GetWindowDisplayMode(mWindow, &mode);

            if (getModeRc == 0)
            {
                mode.w = width;
                mode.h = height;
            }

            const int setModeRc = SDL_SetWindowDisplayMode(
                mWindow,
                getModeRc == 0 ? &mode : nullptr);

            const int fullscreenRc
                = SDL_SetWindowFullscreen(
                    mWindow,
                    SDL_WINDOW_FULLSCREEN);

            int actualW = 0;
            int actualH = 0;
            SDL_GL_GetDrawableSize(
                mWindow,
                &actualW,
                &actualH);

            Log(Debug::Info)
                << "TSP_STARTUP_RESOLUTION_APPLY_051_V19"
                << " requested=" << width << "x" << height
                << " leave_fullscreen_rc=" << leaveFullscreenRc
                << " get_mode_rc=" << getModeRc
                << " set_mode_rc=" << setModeRc
                << " fullscreen_rc=" << fullscreenRc
                << " actual_drawable=" << actualW << "x" << actualH;

            if (getModeRc < 0 || setModeRc < 0 || fullscreenRc < 0)
            {
                const std::string tspResolutionError = SDL_GetError();

                // A custom handheld mode may be rejected by the SDL/KMS
                // backend even though OpenMW can list it. Never make that a
                // launch failure: fall back to native desktop fullscreen.
                SDL_SetWindowFullscreen(mWindow, 0);
                SDL_SetWindowDisplayMode(mWindow, nullptr);
                const int fallbackRc = SDL_SetWindowFullscreen(
                    mWindow,
                    SDL_WINDOW_FULLSCREEN_DESKTOP);

                SDL_GL_GetDrawableSize(
                    mWindow,
                    &actualW,
                    &actualH);

                Log(Debug::Warning)
                    << "TSP startup resolution fallback"
                    << " error=" << tspResolutionError
                    << " fallback_rc=" << fallbackRc
                    << " actual_drawable="
                    << actualW << "x" << actualH;
            }
        }

'''

    engine = engine[:pos] + block + engine[pos:]


# =====================================================================
# 5. OPTIONAL FPS DISPLAY, DEFAULT OFF
# =====================================================================

engine = ensure_include(engine, "#include <cstdlib>")
engine = ensure_include(engine, "#include <cstring>")
engine = ensure_include(engine, "#include <osgGA/GUIEventAdapter>")

if "TSP_OPTIONAL_FPS_OVERLAY_051_V19" not in engine:
    # Put one cached environment helper in the anonymous namespace.
    anonymous_ns = re.search(r"namespace\s*\n?\{", engine)

    if not anonymous_ns:
        raise RuntimeError(
            "engine.cpp: anonymous namespace anchor missing"
        )

    helper = r'''

    // TSP_OPTIONAL_FPS_OVERLAY_051_V19
    bool tspV19ShowFpsEnabled()
    {
        static const bool enabled = [] {
            const char* value = std::getenv("OPENMW_TSP_SHOW_FPS");

            if (value == nullptr || *value == '\0')
                return false;

            return !(std::strcmp(value, "0") == 0
                || std::strcmp(value, "false") == 0
                || std::strcmp(value, "off") == 0
                || std::strcmp(value, "no") == 0);
        }();

        return enabled;
    }
'''

    engine = (
        engine[:anonymous_ns.end()]
        + helper
        + engine[anonymous_ns.end():]
    )

    anchor = "    mViewer->addEventHandler(statsHandler);\n"

    if anchor not in engine:
        raise RuntimeError(
            "engine.cpp: statsHandler event anchor missing"
        )

    hook = r'''
    if (tspV19ShowFpsEnabled())
    {
        mViewer->getEventQueue()->keyPress(
            osgGA::GUIEventAdapter::KEY_F3);
        mViewer->getEventQueue()->keyRelease(
            osgGA::GUIEventAdapter::KEY_F3);

        Log(Debug::Info)
            << "TSP_OPTIONAL_FPS_OVERLAY_051_V19 enabled=1";
    }

'''

    engine = engine.replace(
        anchor,
        anchor + hook,
        1,
    )


# =====================================================================
# 6. PATCH VERIFICATION
# =====================================================================

checks = (
    (
        "resourcesystem.cpp",
        resource,
        (
            "TSP_PERF_QUIET_MEMORY_GATE_051_V19",
            "OPENMW_TSP_DEEP_DEBUG",
            "TSP_MEMORY_PROCESS_TRACE_051_V10",
            "TSP MEMPROC",
            "TSP MEMCACHE",
        ),
    ),
    (
        "scenemanager.cpp",
        scene,
        (
            "TSP_PERF_QUIET_SCENE_GATE_051_V19",
            "OPENMW_TSP_DEEP_DEBUG",
            "TSP_MEMORY_SCENE_TRACE_051_V10",
            "TSP MEMSCENE",
        ),
    ),
    (
        "inputmanagerimp.cpp",
        input_cpp,
        (
            "TSP_PERF_QUIET_CURSOR_GATE_051_V19",
            "OPENMW_TSP_DEEP_DEBUG",
            "TSP_CURSOR_RUNTIME_DEBUG_051_V10",
            "TSP_CURSOR_DEBUG",
        ),
    ),
    (
        "settingswindow.cpp",
        settings,
        (
            "TSP_CUSTOM_RESOLUTIONS_051_V19",
            "1024, 576",
            "854, 480",
            "640, 360",
        ),
    ),
    (
        "sdlvideowrapper.cpp",
        video,
        (
            "TSP_RESOLUTION_APPLY_051_V19",
            "SDL_SetWindowDisplayMode",
            "actual_drawable",
        ),
    ),
    (
        "engine.cpp",
        engine,
        (
            "TSP_STARTUP_RESOLUTION_APPLY_051_V19",
            "TSP_OPTIONAL_FPS_OVERLAY_051_V19",
            "OPENMW_TSP_SHOW_FPS",
            "SDL_SetWindowDisplayMode",
            "actual_drawable",
        ),
    ),
)

for label, body, tokens in checks:
    for token in tokens:
        if token not in body:
            raise RuntimeError(
                f"{label}: V19 verification missing {token}"
            )

for bad in (
    "TSP_ADAPTIVE_DEPTH_051_V17",
    "TSP_DEFERRED_DEPTH_051_V18",
    "TSP_NATIVE_RESOLUTION_051_V18",
):
    if bad in engine:
        raise RuntimeError(
            f"engine.cpp: obsolete V17/V18 token survived: {bad}"
        )

write_lf(resource_path, resource)
write_lf(scene_path, scene)
write_lf(input_path, input_cpp)
write_lf(settings_path, settings)
write_lf(video_path, video)
write_lf(engine_path, engine)

print("V19 source patch applied and verified.")
print("  V15 StateManager: untouched")
print("  V15 renderer: untouched")
print("  V15 state updater: untouched")
print("  deep memory/cursor diagnostics: default OFF")
print("  deep diagnostics opt-in: OPENMW_TSP_DEEP_DEBUG=1")
print("  custom in-game resolution list: installed")
print("  SDL exclusive-fullscreen resolution apply: installed")
print("  FPS overlay: optional, default OFF")
PY_PATCH

echo
echo "===== V19 SOURCE VERIFICATION ====="

echo
echo "-- Quiet diagnostic gates --"
grep -n -m 40 \
    -e 'TSP_PERF_QUIET_MEMORY_GATE_051_V19' \
    -e 'TSP_PERF_QUIET_SCENE_GATE_051_V19' \
    -e 'TSP_PERF_QUIET_CURSOR_GATE_051_V19' \
    -e 'OPENMW_TSP_DEEP_DEBUG' \
    "$RESOURCE_CPP" "$SCENE_CPP" "$INPUT_CPP"

echo
echo "-- Real resolution menu/apply --"
grep -n -m 50 \
    -e 'TSP_CUSTOM_RESOLUTIONS_051_V19' \
    -e 'TSP_RESOLUTION_APPLY_051_V19' \
    -e 'TSP_STARTUP_RESOLUTION_APPLY_051_V19' \
    "$SETTINGS_CPP" "$VIDEO_CPP" "$ENGINE_CPP"

echo
echo "-- Optional FPS switch --"
grep -n -m 20 \
    -e 'TSP_OPTIONAL_FPS_OVERLAY_051_V19' \
    -e 'OPENMW_TSP_SHOW_FPS' \
    "$ENGINE_CPP"

STATE_SHA_AFTER="$(sha256sum "$STATE_CPP" | awk '{print $1}')"
RENDER_SHA_AFTER="$(sha256sum "$RENDER_CPP" | awk '{print $1}')"
STATEUP_SHA_AFTER="$(sha256sum "$STATEUP_CPP" | awk '{print $1}')"

echo
echo "-- Crash-stability protection --"
echo "state before:   $STATE_SHA_BEFORE"
echo "state after:    $STATE_SHA_AFTER"
echo "render before:  $RENDER_SHA_BEFORE"
echo "render after:   $RENDER_SHA_AFTER"
echo "stateup before: $STATEUP_SHA_BEFORE"
echo "stateup after:  $STATEUP_SHA_AFTER"

[ "$STATE_SHA_BEFORE" = "$STATE_SHA_AFTER" ] || {
    echo "ERROR: V19 changed statemanagerimp.cpp."
    exit 1
}

[ "$RENDER_SHA_BEFORE" = "$RENDER_SHA_AFTER" ] || {
    echo "ERROR: V19 changed the V15 renderer."
    exit 1
}

[ "$STATEUP_SHA_BEFORE" = "$STATEUP_SHA_AFTER" ] || {
    echo "ERROR: V19 changed the V15 state updater."
    exit 1
}

echo "PASS: V15 StateManager/renderer/state-updater are byte-for-byte untouched."

for marker in \
    'TSP_FRESH_DEFAULT_051_V15' \
    'TSP_FRESH_PROCESS_LOAD_051_V12' \
    'TSP_SAFE_RELOAD_CONFIG_051_V13' \
    'TSP_VISIBILITY_FIRST_051_V15'
do
    if ! grep -Fq "$marker" "$STATE_CPP" "$RENDER_CPP"; then
        echo "ERROR: protected V15 marker disappeared:"
        echo "  $marker"
        exit 1
    fi
done

if grep -R -Fq \
    'TSP_DEFERRED_DEPTH_051_V18' \
    "$ENGINE_CPP" "$RENDER_CPP" "$STATEUP_CPP"
then
    echo "ERROR: V18 deferred depth exists after clean V19 patch."
    exit 1
fi

echo "PASS: V18 deferred depth absent."

if [ "$PATCH_ONLY" = "1" ]; then
    trap - ERR
    echo
    echo "PATCH_ONLY=1: V19 source patch/verification complete."
    exit 0
fi

echo
echo "===== INCREMENTAL V19 BUILD ====="

cmake --build \
    "$BUILD_DIR" \
    --target openmw \
    --parallel "$JOBS"

[ -x "$BUILT_BINARY" ] || {
    echo "ERROR: rebuilt OpenMW executable missing:"
    echo "  $BUILT_BINARY"
    exit 1
}

if [ -e "$OUTPUT_BINARY" ]; then
    cp -f "$OUTPUT_BINARY" "$OUTPUT_BINARY.before-$STAMP"
fi

if [ -e "$PACKAGE_BINARY" ]; then
    cp -f "$PACKAGE_BINARY" "$PACKAGE_BINARY.before-v19-$STAMP"
fi

cp -f "$BUILT_BINARY" "$OUTPUT_BINARY"
cp -f "$BUILT_BINARY" "$PACKAGE_BINARY"

chmod +x "$OUTPUT_BINARY" "$PACKAGE_BINARY"

echo
echo "===== V19 BINARY VERIFICATION ====="

file "$PACKAGE_BINARY"
sha256sum "$PACKAGE_BINARY"
"$PACKAGE_BINARY" --version || true

for marker in \
    'TSP_FRESH_DEFAULT_051_V15' \
    'TSP_FRESH_PROCESS_LOAD_051_V12' \
    'TSP_SAFE_RELOAD_CONFIG_051_V13' \
    'TSP_VISIBILITY_FIRST_051_V15' \
    'OPENMW_TSP_DEEP_DEBUG' \
    'TSP_CUSTOM_RESOLUTIONS_051_V19' \
    'TSP_RESOLUTION_APPLY_051_V19' \
    'TSP_STARTUP_RESOLUTION_APPLY_051_V19' \
    'OPENMW_TSP_SHOW_FPS' \
    'TSP_OPTIONAL_FPS_OVERLAY_051_V19'
do
    if ! strings "$PACKAGE_BINARY" | grep -F "$marker" >/dev/null; then
        echo "ERROR: required V19 runtime marker missing:"
        echo "  $marker"
        exit 1
    fi
done

for bad in \
    'TSP_ADAPTIVE_DEPTH_051_V17' \
    'TSP_DEFERRED_DEPTH_051_V18' \
    'TSP_DEFERRED_DEPTH_ACTIVE_051_V18' \
    'TSP_NATIVE_RESOLUTION_051_V18'
do
    if strings "$PACKAGE_BINARY" | grep -F "$bad" >/dev/null; then
        echo "ERROR: failed V17/V18 experiment survived in V19 binary:"
        echo "  $bad"
        exit 1
    fi
done

if strings "$PACKAGE_BINARY" | grep -E \
    'TSP MEMPURGE|TSP_TRANSITION_MEMORY_PURGE_051|TSP_UNREFERENCED_CACHE_PURGE_051' \
    >/dev/null
then
    echo "ERROR: forbidden transition-memory-purge marker in binary."
    exit 1
fi

echo "PASS: crash-stable V15 markers retained."
echo "PASS: V19 quiet-debug runtime switch present."
echo "PASS: V19 real resolution menu/apply present."
echo "PASS: V19 optional FPS switch present."
echo "PASS: V17/V18 depth experiments absent."

trap - ERR

echo
echo "============================================================"
echo "SUCCESS: OpenMW 0.51 V19 CLEAN PERFORMANCE build complete"
echo "============================================================"
echo "Package binary:"
echo "  $PACKAGE_BINARY"
echo
echo "Standalone container binary:"
echo "  $OUTPUT_BINARY"
echo
echo "Known-good V15 baseline:"
echo "  $BASELINE_BACKUP"
echo
echo "Original pre-V19 Docker source backup:"
echo "  $PRE_RESTORE_BACKUP"
echo
echo "V19 clean patch backup:"
echo "  $BACKUP_DIR"
echo
echo "Runtime switches:"
echo "  OPENMW_TSP_DEEP_DEBUG=0|1    default 0"
echo "  OPENMW_TSP_SHOW_FPS=0|1      default 0"
echo
echo "In-game 16:9 resolution presets:"
echo "  1280x720"
echo "  1152x648"
echo "  1024x576"
echo "  960x540"
echo "  854x480"
echo "  800x450"
echo "  640x360"
echo
echo "IMPORTANT:"
echo "  Lower display modes require exclusive Fullscreen."
echo "  Windowed Fullscreen intentionally remains native desktop resolution."
echo "============================================================"
