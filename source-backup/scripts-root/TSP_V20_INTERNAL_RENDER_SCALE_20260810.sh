#!/bin/bash
set -Eeuo pipefail

SOURCE_DIR="${1:-/root/openmw-0.51-tsp-src}"
BUILD_DIR="${2:-/root/openmw-0.51-tsp-build}"
PACKAGE_DIR="${3:-/root/openmw-0.51-tsp-package}"
OUTPUT_BINARY="${4:-/root/openmw-0.51-tsp-v20-internal-render-scale}"

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
POST_CPP="$SOURCE_DIR/apps/openmw/mwrender/postprocessor.cpp"
POST_HPP="$SOURCE_DIR/apps/openmw/mwrender/postprocessor.hpp"

CMAKE_FILE="$SOURCE_DIR/CMakeLists.txt"
BUILT_BINARY="$BUILD_DIR/openmw"
PACKAGE_BINARY="$PACKAGE_DIR/bin/openmw-0.51"

STAMP="$(date +%Y%m%d-%H%M%S)"

V15_BASE="${OPENMW_V20_V15_BASE:-$SOURCE_DIR/.tsp-051-source-backups/v15-depthbands-syncguard-20260810-052554}"

# V19 saved a clean pre-patch copy of settingswindow/sdlvideowrapper and the
# diagnostic source. Find the newest clean V19 backup automatically.
V19_CLEAN_BASE="${OPENMW_V20_PREV_UI_BASE:-}"
if [ -z "$V19_CLEAN_BASE" ]; then
    V19_CLEAN_BASE="$(
        find "$SOURCE_DIR/.tsp-051-source-backups" \
            -mindepth 1 \
            -maxdepth 1 \
            -type d \
            -name 'v19-clean-performance-resolutions-*' \
            2>/dev/null \
        | sort \
        | tail -1
    )"
fi

PRE_RESTORE_BACKUP="$SOURCE_DIR/.tsp-051-source-backups/v20-pre-restore-current-$STAMP"
PATCH_BACKUP="$SOURCE_DIR/.tsp-051-source-backups/v20-internal-render-scale-$STAMP"

CORE_PATHS=(
    "apps/openmw/mwstate/statemanagerimp.cpp"
    "apps/openmw/engine.cpp"
    "apps/openmw/mwrender/renderingmanager.cpp"
    "components/sceneutil/stateupdater.cpp"
)

CLEAN_UI_PATHS=(
    "components/resource/resourcesystem.cpp"
    "components/resource/scenemanager.cpp"
    "apps/openmw/mwinput/inputmanagerimp.cpp"
    "apps/openmw/mwgui/settingswindow.cpp"
    "components/sdlutil/sdlvideowrapper.cpp"
)

EXTRA_PATHS=(
    "apps/openmw/mwrender/postprocessor.cpp"
    "apps/openmw/mwrender/postprocessor.hpp"
)

ALL_PATHS=(
    "${CORE_PATHS[@]}"
    "${CLEAN_UI_PATHS[@]}"
    "${EXTRA_PATHS[@]}"
)

copy_selected() {
    local src_root="$1"
    local dst_root="$2"
    shift 2
    local rel

    for rel in "$@"; do
        if [ -f "$src_root/$rel" ]; then
            mkdir -p "$dst_root/$(dirname "$rel")"
            cp -f "$src_root/$rel" "$dst_root/$rel"
        fi
    done
}

restore_selected() {
    local src_root="$1"
    shift
    local rel

    for rel in "$@"; do
        if [ -f "$src_root/$rel" ]; then
            cp -f "$src_root/$rel" "$SOURCE_DIR/$rel"
        fi
    done
}

restore_on_error() {
    rc=$?

    if [ "$rc" -ne 0 ]; then
        echo
        echo "ERROR: V20 patch/build failed."

        if [ -d "$PRE_RESTORE_BACKUP" ]; then
            echo "Restoring exact source that was live before V20..."
            restore_selected "$PRE_RESTORE_BACKUP" "${ALL_PATHS[@]}"
            echo "Source restored."
            echo "Pre-V20 backup retained:"
            echo "  $PRE_RESTORE_BACKUP"
        fi
    fi

    exit "$rc"
}
trap restore_on_error ERR

echo "============================================================"
echo "OpenMW 0.51 TSP V20"
echo "INTERNAL RENDER SCALE"
echo "============================================================"
echo "Source:          $SOURCE_DIR"
echo "Build:           $BUILD_DIR"
echo "Package:         $PACKAGE_DIR"
echo "V15 core base:   $V15_BASE"
echo "Pre-V19 UI base: ${V19_CLEAN_BASE:-<not found>}"
echo "Pre-V20 backup:  $PRE_RESTORE_BACKUP"
echo "Patch backup:    $PATCH_BACKUP"
echo "Jobs:            $JOBS"
echo "Patch only:      $PATCH_ONLY"
echo "============================================================"

for rel in "${ALL_PATHS[@]}"; do
    [ -f "$SOURCE_DIR/$rel" ] || {
        echo "ERROR: required live source file missing:"
        echo "  $SOURCE_DIR/$rel"
        exit 1
    }
done

for rel in "${CORE_PATHS[@]}"; do
    [ -f "$V15_BASE/$rel" ] || {
        echo "ERROR: exact V15 baseline file missing:"
        echo "  $V15_BASE/$rel"
        exit 1
    }
done

if [ -z "$V19_CLEAN_BASE" ] || [ ! -d "$V19_CLEAN_BASE" ]; then
    echo "ERROR: could not find a V19 clean pre-patch backup."
    echo "Expected a directory matching:"
    echo "  $SOURCE_DIR/.tsp-051-source-backups/v19-clean-performance-resolutions-*"
    exit 1
fi

for rel in "${CLEAN_UI_PATHS[@]}"; do
    [ -f "$V19_CLEAN_BASE/$rel" ] || {
        echo "ERROR: V19 clean backup is missing:"
        echo "  $V19_CLEAN_BASE/$rel"
        exit 1
    }
done

VERSION_MAJOR="$(
    sed -n \
        's/^[[:space:]]*set(OPENMW_VERSION_MAJOR[[:space:]]*\([0-9][0-9]*\)).*/\1/p' \
        "$CMAKE_FILE" \
        | head -1
)"
VERSION_MINOR="$(
    sed -n \
        's/^[[:space:]]*set(OPENMW_VERSION_MINOR[[:space:]]*\([0-9][0-9]*\)).*/\1/p' \
        "$CMAKE_FILE" \
        | head -1
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
echo "===== SAVING CURRENT SOURCE ====="

copy_selected "$SOURCE_DIR" "$PRE_RESTORE_BACKUP" "${ALL_PATHS[@]}"

echo "PASS: saved current source to:"
echo "  $PRE_RESTORE_BACKUP"

echo
echo "===== RESTORING CLEAN BASELINE ====="

# Core stability/render topology comes from exact V15.
restore_selected "$V15_BASE" "${CORE_PATHS[@]}"

# UI/video/diagnostic source comes from the clean backup captured before V19
# modified those files.
restore_selected "$V19_CLEAN_BASE" "${CLEAN_UI_PATHS[@]}"

echo "PASS: restored exact V15 crash-stability core."
echo "PASS: restored pre-V19 settings/video/diagnostic source."

echo
echo "===== CLEAN BASE VERIFICATION ====="

python3 - "$STATE_CPP" "$RENDER_CPP" "$ENGINE_CPP" "$STATEUP_CPP" <<'PY_BASE'
from pathlib import Path
import re
import sys

state, render, engine, stateup = [
    Path(p).read_text(encoding="utf-8", errors="replace")
    for p in sys.argv[1:]
]

for marker in (
    "TSP_FRESH_DEFAULT_051_V15",
    "TSP_FRESH_PROCESS_LOAD_051_V12",
    "TSP_SAFE_RELOAD_CONFIG_051_V13",
    "TSP_LOAD_TRACE_051_V13",
    "TSP_LOAD_WATCH_051_V13",
):
    if marker not in state:
        raise SystemExit(f"ERROR: V15 state source lacks {marker}")

if not re.search(
    r'//\s*TSP_FRESH_DEFAULT_051_V15\s*\n\s*bool\s+enabled\s*=\s*true\s*;',
    state,
):
    raise SystemExit("ERROR: V15 fresh reload does not default true")

if "TSP_VISIBILITY_FIRST_051_V15" not in render:
    raise SystemExit("ERROR: V15 visibility-first renderer marker missing")

if 'OPENMW_TSP_DEPTH_PARTITION", false' not in render:
    raise SystemExit("ERROR: old V14 partition does not default OFF")

for bad in (
    "TSP_ADAPTIVE_DEPTH_051_V17",
    "TSP_DEFERRED_DEPTH_051_V18",
    "TSP_NATIVE_RESOLUTION_051_V18",
    "TSP_STARTUP_RESOLUTION_APPLY_051_V19",
):
    if bad in state or bad in render or bad in engine or bad in stateup:
        raise SystemExit(f"ERROR: failed experiment survived clean restore: {bad}")

print("PASS: V15 fresh-process reload intact.")
print("PASS: V15 one-camera renderer intact.")
print("PASS: V17/V18/V19 physical-mode source absent from restored core.")
PY_BASE

for check in \
    "$RESOURCE_CPP:TSP_MEMORY_PROCESS_TRACE_051_V10" \
    "$SCENE_CPP:TSP_MEMORY_SCENE_TRACE_051_V10" \
    "$INPUT_CPP:TSP_CURSOR_RUNTIME_DEBUG_051_V10"
do
    file="${check%%:*}"
    marker="${check#*:}"

    grep -Fq "$marker" "$file" || {
        echo "ERROR: expected diagnostic source marker missing:"
        echo "  $marker"
        echo "  $file"
        exit 1
    }
done

if grep -Fq 'TSP_CUSTOM_RESOLUTIONS_051_V19' "$SETTINGS_CPP"; then
    echo "ERROR: V19 resolution-menu patch survived clean UI restore."
    exit 1
fi

if grep -Fq 'TSP_RESOLUTION_APPLY_051_V19' "$VIDEO_CPP"; then
    echo "ERROR: V19 physical SDL mode patch survived clean video restore."
    exit 1
fi

if grep -RqiE \
    'TSP_TRANSITION_MEMORY_PURGE_051|TSP_UNREFERENCED_CACHE_PURGE_051|TSP MEMPURGE|tspPurgeTransitionMemory|clearUnreferencedCache' \
    "$SOURCE_DIR/apps/openmw/mwworld/scene.cpp" \
    "$SOURCE_DIR/components/resource" 2>/dev/null
then
    echo "ERROR: forbidden transition-memory-purge source is present."
    exit 1
fi

echo "PASS: failed physical-resolution patch removed."
echo "PASS: transition-memory purge absent."

echo
echo "===== BACKING UP CLEAN SOURCE BEFORE V20 ====="

copy_selected "$SOURCE_DIR" "$PATCH_BACKUP" "${ALL_PATHS[@]}"

STATE_SHA_BEFORE="$(sha256sum "$STATE_CPP" | awk '{print $1}')"
RENDER_SHA_BEFORE="$(sha256sum "$RENDER_CPP" | awk '{print $1}')"
STATEUP_SHA_BEFORE="$(sha256sum "$STATEUP_CPP" | awk '{print $1}')"

echo "Protected V15 SHA256:"
echo "  state:   $STATE_SHA_BEFORE"
echo "  render:  $RENDER_SHA_BEFORE"
echo "  stateup: $STATEUP_SHA_BEFORE"

echo
echo "===== APPLYING V20 INTERNAL RENDER-SCALE PATCH ====="

python3 - \
    "$RESOURCE_CPP" \
    "$SCENE_CPP" \
    "$INPUT_CPP" \
    "$SETTINGS_CPP" \
    "$POST_CPP" \
    "$ENGINE_CPP" <<'PY_PATCH'
from pathlib import Path
import re
import sys

(
    resource_path,
    scene_path,
    input_path,
    settings_path,
    post_path,
    engine_path,
) = map(Path, sys.argv[1:])

resource = resource_path.read_text(encoding="utf-8")
scene = scene_path.read_text(encoding="utf-8")
input_cpp = input_path.read_text(encoding="utf-8")
settings = settings_path.read_text(encoding="utf-8")
post = post_path.read_text(encoding="utf-8")
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
        raise RuntimeError(f"include insertion point missing: {include_line}")

    pos = includes[-1].end()
    return text[:pos] + include_line + "\n" + text[pos:]


def find_function(text: str, signature_pattern: str, label: str):
    matches = list(
        re.finditer(signature_pattern, text, flags=re.MULTILINE)
    )

    if len(matches) != 1:
        raise RuntimeError(
            f"{label}: expected one signature; found {len(matches)}"
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


def add_debug_helper(text: str, namespace_name: str) -> str:
    marker = "// TSP_PERF_QUIET_HELPER_051_V20"

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
        // TSP_PERF_QUIET_HELPER_051_V20
        bool tspV20DeepDebugEnabled()
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


def gate_trace_tail(
    text: str,
    signature_pattern: str,
    label: str,
    trace_marker: str,
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
    marker_pos = func.find(trace_marker)

    if marker_pos < 0:
        raise RuntimeError(
            f"{label}: diagnostic marker missing: {trace_marker}"
        )

    line_start = func.rfind("\n", 0, marker_pos) + 1
    closing = func.rfind("}")

    diagnostic_tail = func[line_start:closing]

    wrapped = (
        func[:line_start]
        + f"        // {gate_marker}\n"
        + "        if (tspV20DeepDebugEnabled())\n"
        + "        {\n"
        + diagnostic_tail
        + "        }\n"
        + func[closing:]
    )

    return text[:start] + wrapped + text[end:]


# =====================================================================
# 1. QUIET THE OLD DEEP DIAGNOSTICS BY DEFAULT
# =====================================================================

resource = add_debug_helper(resource, "Resource")

resource = gate_trace_tail(
    resource,
    r"^[ \t]*void[ \t]+ResourceSystem::updateCache[ \t]*\([^)]*\)",
    "ResourceSystem::updateCache",
    "// TSP_MEMORY_PROCESS_TRACE_051_V10",
    "TSP_PERF_QUIET_MEMORY_GATE_051_V20",
)

scene = add_debug_helper(scene, "Resource")

scene = gate_trace_tail(
    scene,
    r"^[ \t]*void[ \t]+SceneManager::updateCache[ \t]*\([^)]*\)",
    "SceneManager::updateCache",
    "// TSP_MEMORY_SCENE_TRACE_051_V10",
    "TSP_PERF_QUIET_SCENE_GATE_051_V20",
)

if "TSP_PERF_QUIET_CURSOR_GATE_051_V20" not in input_cpp:
    input_cpp = ensure_include(input_cpp, "#include <cstdlib>")
    input_cpp = ensure_include(input_cpp, "#include <cstring>")

    marker = input_cpp.find("// TSP_CURSOR_RUNTIME_DEBUG_051_V10")

    if marker < 0:
        raise RuntimeError("cursor diagnostic marker missing")

    lambda_pos = input_cpp.find(
        "auto tspLogCursorState = [&]()",
        marker,
    )

    if lambda_pos < 0:
        raise RuntimeError("tspLogCursorState lambda missing")

    opening = input_cpp.find("{", lambda_pos)

    if opening < 0:
        raise RuntimeError("cursor logger opening brace missing")

    gate = r'''
            // TSP_PERF_QUIET_CURSOR_GATE_051_V20
            static const bool tspV20CursorDebugEnabled = [] {
                const char* value = std::getenv("OPENMW_TSP_DEEP_DEBUG");

                if (value == nullptr || *value == '\0')
                    return false;

                return !(std::strcmp(value, "0") == 0
                    || std::strcmp(value, "false") == 0
                    || std::strcmp(value, "off") == 0
                    || std::strcmp(value, "no") == 0);
            }();

            if (!tspV20CursorDebugEnabled)
                return;
'''

    input_cpp = (
        input_cpp[:opening + 1]
        + gate
        + input_cpp[opening + 1:]
    )


# =====================================================================
# 2. RESOLUTION MENU = INTERNAL RENDER RESOLUTION
# =====================================================================

if "TSP_INTERNAL_RESOLUTION_MENU_051_V20" not in settings:
    sort_anchor = (
        "        std::sort(resolutions.begin(), resolutions.end(), "
        "sortResolutions);\n"
    )

    if sort_anchor not in settings:
        raise RuntimeError("settingswindow.cpp: resolution sort anchor missing")

    presets = r'''        // TSP_INTERNAL_RESOLUTION_MENU_051_V20
        // These are INTERNAL scene-render targets on the TSP.
        // The physical SDL/KMS output remains 1280x720.
        resolutions.emplace_back(1280, 720);
        resolutions.emplace_back(1152, 648);
        resolutions.emplace_back(1024, 576);
        resolutions.emplace_back(960, 540);
        resolutions.emplace_back(854, 480);
        resolutions.emplace_back(800, 450);
        resolutions.emplace_back(640, 360);

        Log(Debug::Info)
            << "TSP_INTERNAL_RESOLUTION_MENU_051_V20"
            << " targets=1280x720,1152x648,1024x576,960x540,854x480,800x450,640x360";

'''

    settings = settings.replace(
        sort_anchor,
        presets + sort_anchor,
        1,
    )

    # Do NOT call apply(): that would invoke SDLVideoWrapper::setVideoMode and
    # ask the fixed LCD backend to change physical display mode.
    old_accept = r'''            Settings::video().mResolutionX.set(resolution->first);
            Settings::video().mResolutionY.set(resolution->second);

            apply();
'''

    if old_accept not in settings:
        raise RuntimeError(
            "settingswindow.cpp: resolution accept block missing"
        )

    new_accept = r'''            // TSP_INTERNAL_RESOLUTION_ACCEPT_051_V20
            Settings::video().mResolutionX.set(resolution->first);
            Settings::video().mResolutionY.set(resolution->second);

            // Internal render target is rebuilt safely at next startup.
            // Deliberately do NOT call apply() here: the fixed TSP panel
            // rejects non-native physical fullscreen modes.
            MWBase::Environment::get().getWindowManager()->interactiveMessageBox(
                "#{OMWEngine:ChangeRequiresRestart}", { "#{Interface:OK}" }, true);

            Log(Debug::Info)
                << "TSP_INTERNAL_RESOLUTION_ACCEPT_051_V20"
                << " selected=" << resolution->first
                << "x" << resolution->second
                << " action=restart-required";
'''

    settings = settings.replace(
        old_accept,
        new_accept,
        1,
    )


# =====================================================================
# 3. OPENMW-OWNED INTERNAL RENDER SCALE
# =====================================================================
#
# PostProcessor already owns the game's scene FBOs and a full-output HUD /
# presentation camera. Keep physical output mWidth/mHeight untouched; only
# make renderWidth/renderHeight follow the selected Video resolution.

if "TSP_INTERNAL_RENDER_SCALE_051_V20" not in post:
    # Scene camera uses the INTERNAL viewport.
    old_resize = r'''    void PostProcessor::resize()
    {
        mHUDCamera->resize(mWidth, mHeight);
        mViewer->getCamera()->resize(mWidth, mHeight);
'''

    if old_resize not in post:
        raise RuntimeError("postprocessor.cpp: resize() anchor missing")

    new_resize = r'''    void PostProcessor::resize()
    {
        // TSP_INTERNAL_RENDER_SCALE_051_V20
        // HUD/presentation stays native; the single scene camera/FBO uses
        // the user-selected internal resolution.
        mHUDCamera->resize(mWidth, mHeight);
        mViewer->getCamera()->resize(renderWidth(), renderHeight());

        Log(Debug::Info)
            << "TSP_INTERNAL_RENDER_SCALE_051_V20"
            << " output=" << mWidth << "x" << mHeight
            << " internal=" << renderWidth() << "x" << renderHeight()
            << " pixels_percent="
            << ((mWidth > 0 && mHeight > 0)
                    ? (100.0 * renderWidth() * renderHeight()
                        / (static_cast<double>(mWidth) * mHeight))
                    : 100.0);
'''

    post = post.replace(
        old_resize,
        new_resize,
        1,
    )

    old_width = r'''    int PostProcessor::renderWidth() const
    {
        if (Stereo::getStereo())
            return Stereo::Manager::instance().eyeResolution().x();
        return mWidth;
    }

    int PostProcessor::renderHeight() const
    {
        if (Stereo::getStereo())
            return Stereo::Manager::instance().eyeResolution().y();
        return mHeight;
    }
'''

    if old_width not in post:
        raise RuntimeError(
            "postprocessor.cpp: renderWidth/renderHeight block missing"
        )

    new_width = r'''    int PostProcessor::renderWidth() const
    {
        if (Stereo::getStereo())
            return Stereo::Manager::instance().eyeResolution().x();

        // TSP_INTERNAL_RENDER_WIDTH_051_V20
        // Clamp to physical output so a stale config cannot allocate a larger
        // scene target than the handheld's native framebuffer.
        return std::max(
            320,
            std::min(
                mWidth,
                static_cast<int>(Settings::video().mResolutionX)));
    }

    int PostProcessor::renderHeight() const
    {
        if (Stereo::getStereo())
            return Stereo::Manager::instance().eyeResolution().y();

        // TSP_INTERNAL_RENDER_HEIGHT_051_V20
        return std::max(
            180,
            std::min(
                mHeight,
                static_cast<int>(Settings::video().mResolutionY)));
    }
'''

    post = post.replace(
        old_width,
        new_width,
        1,
    )


# =====================================================================
# 4. OPTIONAL FPS OVERLAY, DEFAULT OFF
# =====================================================================

engine = ensure_include(engine, "#include <cstdlib>")
engine = ensure_include(engine, "#include <cstring>")
engine = ensure_include(engine, "#include <osgGA/GUIEventAdapter>")

if "TSP_OPTIONAL_FPS_OVERLAY_051_V20" not in engine:
    ns = re.search(r"namespace\s*\n?\{", engine)

    if not ns:
        raise RuntimeError("engine.cpp: anonymous namespace missing")

    helper = r'''

    // TSP_OPTIONAL_FPS_OVERLAY_051_V20
    bool tspV20ShowFpsEnabled()
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

    engine = engine[:ns.end()] + helper + engine[ns.end():]

    event_anchor = "    mViewer->addEventHandler(statsHandler);\n"

    if event_anchor not in engine:
        raise RuntimeError("engine.cpp: statsHandler anchor missing")

    hook = r'''
    if (tspV20ShowFpsEnabled())
    {
        mViewer->getEventQueue()->keyPress(
            osgGA::GUIEventAdapter::KEY_F3);
        mViewer->getEventQueue()->keyRelease(
            osgGA::GUIEventAdapter::KEY_F3);

        Log(Debug::Info)
            << "TSP_OPTIONAL_FPS_OVERLAY_051_V20 enabled=1";
    }

'''

    engine = engine.replace(
        event_anchor,
        event_anchor + hook,
        1,
    )


# =====================================================================
# 5. SOURCE VERIFICATION
# =====================================================================

checks = (
    (
        "resourcesystem.cpp",
        resource,
        (
            "TSP_PERF_QUIET_MEMORY_GATE_051_V20",
            "OPENMW_TSP_DEEP_DEBUG",
        ),
    ),
    (
        "scenemanager.cpp",
        scene,
        (
            "TSP_PERF_QUIET_SCENE_GATE_051_V20",
            "OPENMW_TSP_DEEP_DEBUG",
        ),
    ),
    (
        "inputmanagerimp.cpp",
        input_cpp,
        (
            "TSP_PERF_QUIET_CURSOR_GATE_051_V20",
            "OPENMW_TSP_DEEP_DEBUG",
        ),
    ),
    (
        "settingswindow.cpp",
        settings,
        (
            "TSP_INTERNAL_RESOLUTION_MENU_051_V20",
            "TSP_INTERNAL_RESOLUTION_ACCEPT_051_V20",
            "1024, 576",
            "854, 480",
            "640, 360",
            "ChangeRequiresRestart",
        ),
    ),
    (
        "postprocessor.cpp",
        post,
        (
            "TSP_INTERNAL_RENDER_SCALE_051_V20",
            "TSP_INTERNAL_RENDER_WIDTH_051_V20",
            "TSP_INTERNAL_RENDER_HEIGHT_051_V20",
            "mHUDCamera->resize(mWidth, mHeight)",
            "mViewer->getCamera()->resize(renderWidth(), renderHeight())",
            "Settings::video().mResolutionX",
            "Settings::video().mResolutionY",
        ),
    ),
    (
        "engine.cpp",
        engine,
        (
            "TSP_OPTIONAL_FPS_OVERLAY_051_V20",
            "OPENMW_TSP_SHOW_FPS",
        ),
    ),
)

for label, body, tokens in checks:
    for token in tokens:
        if token not in body:
            raise RuntimeError(
                f"{label}: V20 verification missing {token}"
            )

for bad in (
    "TSP_RESOLUTION_APPLY_051_V19",
    "TSP_STARTUP_RESOLUTION_APPLY_051_V19",
    "TSP_ADAPTIVE_DEPTH_051_V17",
    "TSP_DEFERRED_DEPTH_051_V18",
):
    if (
        bad in settings
        or bad in post
        or bad in engine
        or bad in resource
        or bad in scene
        or bad in input_cpp
    ):
        raise RuntimeError(
            f"obsolete failed experiment survived into V20: {bad}"
        )

write_lf(resource_path, resource)
write_lf(scene_path, scene)
write_lf(input_path, input_cpp)
write_lf(settings_path, settings)
write_lf(post_path, post)
write_lf(engine_path, engine)

print("V20 source patch applied and verified.")
print("  physical output: native SDL/KMS mode")
print("  scene render: OpenMW PostProcessor FBO at selected internal size")
print("  scene cameras: ONE")
print("  scaling filter: existing LINEAR scene texture filter")
print("  resolution change: restart-required; no physical SDL mode switch")
print("  deep diagnostics: default OFF")
print("  FPS overlay: optional")
PY_PATCH

echo
echo "===== V20 SOURCE VERIFICATION ====="

echo
echo "-- Internal resolution menu --"
grep -n -m 30 \
    -e 'TSP_INTERNAL_RESOLUTION_MENU_051_V20' \
    -e 'TSP_INTERNAL_RESOLUTION_ACCEPT_051_V20' \
    "$SETTINGS_CPP"

echo
echo "-- Internal scene FBO scaling --"
grep -n -m 40 \
    -e 'TSP_INTERNAL_RENDER_SCALE_051_V20' \
    -e 'TSP_INTERNAL_RENDER_WIDTH_051_V20' \
    -e 'TSP_INTERNAL_RENDER_HEIGHT_051_V20' \
    "$POST_CPP"

echo
echo "-- Quiet diagnostics --"
grep -n -m 30 \
    -e 'TSP_PERF_QUIET_MEMORY_GATE_051_V20' \
    -e 'TSP_PERF_QUIET_SCENE_GATE_051_V20' \
    -e 'TSP_PERF_QUIET_CURSOR_GATE_051_V20' \
    "$RESOURCE_CPP" "$SCENE_CPP" "$INPUT_CPP"

STATE_SHA_AFTER="$(sha256sum "$STATE_CPP" | awk '{print $1}')"
RENDER_SHA_AFTER="$(sha256sum "$RENDER_CPP" | awk '{print $1}')"
STATEUP_SHA_AFTER="$(sha256sum "$STATEUP_CPP" | awk '{print $1}')"

echo
echo "-- Protected V15 stability/render topology --"
echo "state before:   $STATE_SHA_BEFORE"
echo "state after:    $STATE_SHA_AFTER"
echo "render before:  $RENDER_SHA_BEFORE"
echo "render after:   $RENDER_SHA_AFTER"
echo "stateup before: $STATEUP_SHA_BEFORE"
echo "stateup after:  $STATEUP_SHA_AFTER"

[ "$STATE_SHA_BEFORE" = "$STATE_SHA_AFTER" ] || {
    echo "ERROR: V20 changed StateManager."
    exit 1
}

[ "$RENDER_SHA_BEFORE" = "$RENDER_SHA_AFTER" ] || {
    echo "ERROR: V20 changed V15 RenderingManager."
    exit 1
}

[ "$STATEUP_SHA_BEFORE" = "$STATEUP_SHA_AFTER" ] || {
    echo "ERROR: V20 changed V15 StateUpdater."
    exit 1
}

echo "PASS: V15 StateManager/RenderingManager/StateUpdater unchanged."

if grep -R -Fq \
    'TSP_DEFERRED_DEPTH_051_V18' \
    "$ENGINE_CPP" "$RENDER_CPP" "$STATEUP_CPP" "$POST_CPP"
then
    echo "ERROR: V18 deferred depth remains."
    exit 1
fi

if grep -R -Fq \
    'TSP_RESOLUTION_APPLY_051_V19' \
    "$ENGINE_CPP" "$VIDEO_CPP" "$SETTINGS_CPP"
then
    echo "ERROR: V19 physical-mode switching remains."
    exit 1
fi

echo "PASS: failed depth and physical-resolution experiments absent."

if [ "$PATCH_ONLY" = "1" ]; then
    trap - ERR
    echo
    echo "PATCH_ONLY=1: V20 source patch complete."
    exit 0
fi

echo
echo "===== INCREMENTAL V20 BUILD ====="

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
    cp -f "$PACKAGE_BINARY" "$PACKAGE_BINARY.before-v20-$STAMP"
fi

cp -f "$BUILT_BINARY" "$OUTPUT_BINARY"
cp -f "$BUILT_BINARY" "$PACKAGE_BINARY"

chmod +x "$OUTPUT_BINARY" "$PACKAGE_BINARY"

echo
echo "===== V20 BINARY VERIFICATION ====="

file "$PACKAGE_BINARY"
sha256sum "$PACKAGE_BINARY"
"$PACKAGE_BINARY" --version || true

for marker in \
    'TSP_FRESH_DEFAULT_051_V15' \
    'TSP_FRESH_PROCESS_LOAD_051_V12' \
    'TSP_VISIBILITY_FIRST_051_V15' \
    'TSP_INTERNAL_RESOLUTION_MENU_051_V20' \
    'TSP_INTERNAL_RESOLUTION_ACCEPT_051_V20' \
    'TSP_INTERNAL_RENDER_SCALE_051_V20' \
    'TSP_INTERNAL_RENDER_WIDTH_051_V20' \
    'TSP_INTERNAL_RENDER_HEIGHT_051_V20' \
    'OPENMW_TSP_DEEP_DEBUG' \
    'OPENMW_TSP_SHOW_FPS'
do
    if ! strings "$PACKAGE_BINARY" | grep -F "$marker" >/dev/null; then
        echo "ERROR: required V20 runtime marker missing:"
        echo "  $marker"
        exit 1
    fi
done

for bad in \
    'TSP_ADAPTIVE_DEPTH_051_V17' \
    'TSP_DEFERRED_DEPTH_051_V18' \
    'TSP_RESOLUTION_APPLY_051_V19' \
    'TSP_STARTUP_RESOLUTION_APPLY_051_V19'
do
    if strings "$PACKAGE_BINARY" | grep -F "$bad" >/dev/null; then
        echo "ERROR: failed old experiment remains in V20 binary:"
        echo "  $bad"
        exit 1
    fi
done

echo "PASS: V15 crash-stability markers present."
echo "PASS: V20 internal render-scale markers present."
echo "PASS: V17/V18 depth absent."
echo "PASS: V19 physical display-mode switching absent."

trap - ERR

echo
echo "============================================================"
echo "SUCCESS: OpenMW 0.51 V20 INTERNAL RENDER SCALE complete"
echo "============================================================"
echo "Package binary:"
echo "  $PACKAGE_BINARY"
echo
echo "Standalone container binary:"
echo "  $OUTPUT_BINARY"
echo
echo "V15 baseline:"
echo "  $V15_BASE"
echo
echo "Pre-V19 clean UI base:"
echo "  $V19_CLEAN_BASE"
echo
echo "Pre-V20 source backup:"
echo "  $PRE_RESTORE_BACKUP"
echo
echo "V20 clean patch backup:"
echo "  $PATCH_BACKUP"
echo
echo "Runtime:"
echo "  OPENMW_TSP_DEEP_DEBUG=0|1"
echo "  OPENMW_TSP_SHOW_FPS=0|1"
echo
echo "Resolution menu now controls INTERNAL scene rendering."
echo "Physical output remains native."
echo "Resolution changes require one restart."
echo "============================================================"
