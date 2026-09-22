#!/bin/bash
set -Eeuo pipefail

SOURCE_DIR="${1:-/root/openmw-0.51-tsp-src}"
BUILD_DIR="${2:-/root/openmw-0.51-tsp-build}"
PACKAGE_DIR="${3:-/root/openmw-0.51-tsp-package}"
OUTPUT_BINARY="${4:-/root/openmw-0.51-tsp-v18-deferred-depth-native-res}"
JOBS="${OPENMW_JOBS:-1}"
PATCH_ONLY="${OPENMW_PATCH_ONLY:-0}"

STATE_CPP="$SOURCE_DIR/apps/openmw/mwstate/statemanagerimp.cpp"
RENDER_CPP="$SOURCE_DIR/apps/openmw/mwrender/renderingmanager.cpp"
STATEUP_CPP="$SOURCE_DIR/components/sceneutil/stateupdater.cpp"
ENGINE_CPP="$SOURCE_DIR/apps/openmw/engine.cpp"
WORLD_CPP="$SOURCE_DIR/apps/openmw/mwworld/worldimp.cpp"
CMAKE_FILE="$SOURCE_DIR/CMakeLists.txt"

BUILT_BINARY="$BUILD_DIR/openmw"
PACKAGE_BINARY="$PACKAGE_DIR/bin/openmw-0.51"

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="$SOURCE_DIR/.tsp-051-source-backups/v18-deferred-depth-native-res-$STAMP"

# The exact source snapshot made immediately before the failed depth-band
# experiment. Your diagnostic confirmed this snapshot contains
# TSP_FRESH_DEFAULT_051_V15 and is the correct fresh-reload source lineage.
BASELINE_BACKUP="${OPENMW_BASELINE_BACKUP:-$SOURCE_DIR/.tsp-051-source-backups/v15-depthbands-syncguard-20260810-052554}"

# Preserve whatever is live in Docker before restoring that baseline.
PRE_RESTORE_BACKUP="$SOURCE_DIR/.tsp-051-source-backups/v18-pre-restore-current-$STAMP"

restore_on_error() {
    rc=$?
    if [ "$rc" -ne 0 ]; then
        echo
        echo "ERROR: V18 patch/build failed."

        # Prefer returning Docker to exactly what was live before this
        # controller restored the known-good baseline.
        if [ -d "$PRE_RESTORE_BACKUP" ]; then
            echo "Restoring the pre-V18 live Docker source..."
            [ -f "$PRE_RESTORE_BACKUP/apps/openmw/mwstate/statemanagerimp.cpp" ] && \
                cp -f "$PRE_RESTORE_BACKUP/apps/openmw/mwstate/statemanagerimp.cpp" "$STATE_CPP"
            [ -f "$PRE_RESTORE_BACKUP/apps/openmw/engine.cpp" ] && \
                cp -f "$PRE_RESTORE_BACKUP/apps/openmw/engine.cpp" "$ENGINE_CPP"
            [ -f "$PRE_RESTORE_BACKUP/apps/openmw/mwrender/renderingmanager.cpp" ] && \
                cp -f "$PRE_RESTORE_BACKUP/apps/openmw/mwrender/renderingmanager.cpp" "$RENDER_CPP"
            [ -f "$PRE_RESTORE_BACKUP/components/sceneutil/stateupdater.cpp" ] && \
                cp -f "$PRE_RESTORE_BACKUP/components/sceneutil/stateupdater.cpp" "$STATEUP_CPP"
            echo "Pre-V18 source restoration complete."
            echo "Saved copy remains at:"
            echo "  $PRE_RESTORE_BACKUP"
        elif [ -d "$BACKUP_DIR" ]; then
            echo "Restoring the immediate pre-patch baseline..."
            [ -f "$BACKUP_DIR/apps/openmw/mwrender/renderingmanager.cpp" ] && \
                cp -f "$BACKUP_DIR/apps/openmw/mwrender/renderingmanager.cpp" "$RENDER_CPP"
            [ -f "$BACKUP_DIR/components/sceneutil/stateupdater.cpp" ] && \
                cp -f "$BACKUP_DIR/components/sceneutil/stateupdater.cpp" "$STATEUP_CPP"
            [ -f "$BACKUP_DIR/apps/openmw/engine.cpp" ] && \
                cp -f "$BACKUP_DIR/apps/openmw/engine.cpp" "$ENGINE_CPP"
            [ -f "$BACKUP_DIR/apps/openmw/mwstate/statemanagerimp.cpp" ] && \
                cp -f "$BACKUP_DIR/apps/openmw/mwstate/statemanagerimp.cpp" "$STATE_CPP"
            echo "Immediate source restoration complete."
        fi
    fi
    exit "$rc"
}
trap restore_on_error ERR

echo "============================================================"
echo "OpenMW 0.51 TSP V18"
echo "DEFERRED DEPTH + NATIVE RESOLUTION + FPS"
echo "============================================================"
echo "Source:        $SOURCE_DIR"
echo "Build:         $BUILD_DIR"
echo "Package:       $PACKAGE_DIR"
echo "Output binary: $OUTPUT_BINARY"
echo "Jobs:          $JOBS"
echo "Patch only:    $PATCH_ONLY"
echo "Baseline:      $BASELINE_BACKUP"
echo "Pre-restore:   $PRE_RESTORE_BACKUP"
echo "Patch backup:  $BACKUP_DIR"
echo "============================================================"

for required in \
    "$STATE_CPP" \
    "$RENDER_CPP" \
    "$STATEUP_CPP" \
    "$ENGINE_CPP" \
    "$WORLD_CPP" \
    "$CMAKE_FILE"
do
    if [ ! -f "$required" ]; then
        echo "ERROR: required source file is missing:"
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

echo
echo "===== STAGE 1 OF 2: RESTORE/REPAIR V15 FRESH-RELOAD BASELINE ====="
echo "Baseline:"
echo "  $BASELINE_BACKUP"

for rel in \
    apps/openmw/mwstate/statemanagerimp.cpp \
    apps/openmw/engine.cpp \
    apps/openmw/mwrender/renderingmanager.cpp \
    components/sceneutil/stateupdater.cpp
do
    if [ ! -f "$BASELINE_BACKUP/$rel" ]; then
        echo "ERROR: required baseline file is missing:"
        echo "  $BASELINE_BACKUP/$rel"
        echo "Nothing was changed."
        exit 1
    fi
done

# Verify the backup is actually the fresh-by-default source before touching live files.
python3 - "$BASELINE_BACKUP/apps/openmw/mwstate/statemanagerimp.cpp" <<'PY_BASELINE_CHECK'
from pathlib import Path
import re
import sys

text = Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace")

required = (
    "TSP_FRESH_DEFAULT_051_V15",
    "TSP_FRESH_PROCESS_LOAD_051_V12",
    "TSP_SAFE_RELOAD_CONFIG_051_V13",
    "TSP_LOAD_TRACE_051_V13",
    "TSP_LOAD_WATCH_051_V13",
)

missing = [marker for marker in required if marker not in text]
if missing:
    raise SystemExit(
        "ERROR: selected baseline is not the fresh-reload source; missing: "
        + ", ".join(missing)
    )

if not re.search(
    r'//\s*TSP_FRESH_DEFAULT_051_V15\s*\n\s*bool\s+enabled\s*=\s*true\s*;',
    text,
):
    raise SystemExit(
        "ERROR: selected baseline has TSP_FRESH_DEFAULT_051_V15 "
        "but does not default to enabled=true."
    )

print("PASS: selected baseline is the successful fresh-by-default source.")
PY_BASELINE_CHECK

mkdir -p \
    "$PRE_RESTORE_BACKUP/apps/openmw/mwstate" \
    "$PRE_RESTORE_BACKUP/apps/openmw/mwrender" \
    "$PRE_RESTORE_BACKUP/apps/openmw" \
    "$PRE_RESTORE_BACKUP/components/sceneutil"

cp -f "$STATE_CPP"     "$PRE_RESTORE_BACKUP/apps/openmw/mwstate/statemanagerimp.cpp"
cp -f "$ENGINE_CPP"     "$PRE_RESTORE_BACKUP/apps/openmw/engine.cpp"
cp -f "$RENDER_CPP"     "$PRE_RESTORE_BACKUP/apps/openmw/mwrender/renderingmanager.cpp"
cp -f "$STATEUP_CPP"     "$PRE_RESTORE_BACKUP/components/sceneutil/stateupdater.cpp"

echo "Saved current Docker source to:"
echo "  $PRE_RESTORE_BACKUP"

cp -f     "$BASELINE_BACKUP/apps/openmw/mwstate/statemanagerimp.cpp"     "$STATE_CPP"
cp -f     "$BASELINE_BACKUP/apps/openmw/engine.cpp"     "$ENGINE_CPP"
cp -f     "$BASELINE_BACKUP/apps/openmw/mwrender/renderingmanager.cpp"     "$RENDER_CPP"
cp -f     "$BASELINE_BACKUP/components/sceneutil/stateupdater.cpp"     "$STATEUP_CPP"

echo "PASS: restored the exact 20260810-052554 fresh-reload baseline."

echo
echo "Repairing V15 fresh-default policy in-place if necessary..."
python3 - "$STATE_CPP" "$RENDER_CPP" <<'PY_V15_REPAIR'
from pathlib import Path
import re
import sys

state_path, render_path = map(Path, sys.argv[1:])
state = state_path.read_text(encoding="utf-8")
render = render_path.read_text(encoding="utf-8")

FRESH = "TSP_FRESH_DEFAULT_051_V15"
VIS = "TSP_VISIBILITY_FIRST_051_V15"

def write_lf(path, text):
    with path.open("w", encoding="utf-8", newline="\n") as f:
        f.write(text)

if FRESH not in state:
    rx = re.compile(
        r'(?P<prefix>struct\s+TspSafeReloadSetting\s*\{\s*)'
        r'bool\s+enabled\s*=\s*false\s*;',
        flags=re.DOTALL,
    )
    m = rx.search(state)
    if not m:
        raise RuntimeError(
            "V15 repair: TspSafeReloadSetting default-false anchor not found"
        )
    state = (
        state[:m.start()]
        + m.group("prefix")
        + "// TSP_FRESH_DEFAULT_051_V15\n        bool enabled = true;"
        + state[m.end():]
    )

    hook = "            if (tspSafeReload.enabled)\n"
    if hook not in state:
        raise RuntimeError("V15 repair: safe-reload enabled hook not found")

    log = (
        '            Log(Debug::Info) << "TSP_FRESH_DEFAULT_051_V15"\n'
        '                             << " effective_fresh=" << '
        '(tspSafeReload.enabled ? 1 : 0)\n'
        '                             << " explicit=" << '
        '(tspSafeReload.found ? 1 : 0)\n'
        '                             << " source=" << tspSafeReload.source;\n'
    )
    state = state.replace(hook, log + hook, 1)
else:
    rx = re.compile(
        r'(//\s*TSP_FRESH_DEFAULT_051_V15\s*\n\s*bool\s+enabled\s*=\s*)'
        r'(?:true|false)(\s*;)'
    )
    state, count = rx.subn(r'\1true\2', state, count=1)
    if count != 1:
        raise RuntimeError(
            "V15 repair: fresh marker exists but enabled field was not recognized"
        )

if VIS not in render:
    old = (
        '    bool tspDepthPartitionEnabled()\n'
        '    {\n'
        '        return tspEnvBool("OPENMW_TSP_DEPTH_PARTITION", true);\n'
        '    }'
    )
    new = (
        '    // TSP_VISIBILITY_FIRST_051_V15\n'
        '    // Safe/default V15 path: one normal scene camera. V14 partition is opt-in.\n'
        '    bool tspDepthPartitionEnabled()\n'
        '    {\n'
        '        const bool enabled = tspEnvBool("OPENMW_TSP_DEPTH_PARTITION", false);\n'
        '        static bool logged = false;\n'
        '        if (!logged)\n'
        '        {\n'
        '            Log(Debug::Info) << "TSP_VISIBILITY_FIRST_051_V15"\n'
        '                             << " depth_partition=" << (enabled ? 1 : 0)\n'
        '                             << " default=0";\n'
        '            logged = true;\n'
        '        }\n'
        '        return enabled;\n'
        '    }'
    )
    if old not in render:
        raise RuntimeError(
            "V15 repair: V14 tspDepthPartitionEnabled baseline not found"
        )
    render = render.replace(old, new, 1)

for marker in (
    "TSP_FRESH_DEFAULT_051_V15",
    "TSP_FRESH_PROCESS_LOAD_051_V12",
    "TSP_SAFE_RELOAD_CONFIG_051_V13",
    "TSP_LOAD_TRACE_051_V13",
    "TSP_LOAD_WATCH_051_V13",
):
    if marker not in state:
        raise RuntimeError(f"V15 repair verification missing: {marker}")

if not re.search(
    r'//\s*TSP_FRESH_DEFAULT_051_V15\s*\n\s*bool\s+enabled\s*=\s*true\s*;',
    state,
):
    raise RuntimeError("V15 repair verification: fresh default is not true")

for marker in (
    "TSP_VISIBILITY_FIRST_051_V15",
    "TSP_DEPTH_PARTITION_051_V14",
    "TSP_WARM_ASYNC_GUARD_051_V14",
):
    if marker not in render:
        raise RuntimeError(f"V15 renderer verification missing: {marker}")

if 'OPENMW_TSP_DEPTH_PARTITION", false' not in render:
    raise RuntimeError("V15 renderer verification: V14 partition is not default OFF")

write_lf(state_path, state)
write_lf(render_path, render)

print("PASS: V15 fresh-reload default = TRUE")
print("PASS: V15 visibility-first path = active/default")
print("PASS: V12/V13/V14 support markers retained")
PY_V15_REPAIR

echo
echo "===== STAGE 1 V15 VERIFICATION ====="

for marker in \
    'TSP_FRESH_DEFAULT_051_V15' \
    'TSP_FRESH_PROCESS_LOAD_051_V12' \
    'TSP_SAFE_RELOAD_CONFIG_051_V13' \
    'TSP_LOAD_TRACE_051_V13' \
    'TSP_LOAD_WATCH_051_V13'
do
    if ! grep -Fq "$marker" "$STATE_CPP"; then
        echo "ERROR: restored baseline unexpectedly lacks:"
        echo "  $marker"
        exit 1
    fi
done

python3 - "$STATE_CPP" <<'PY_FRESH_CHECK'
from pathlib import Path
import re
import sys

text = Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace")
m = re.search(
    r'//\s*TSP_FRESH_DEFAULT_051_V15\s*\n\s*bool\s+enabled\s*=\s*true\s*;',
    text,
)
if not m:
    raise SystemExit(
        "ERROR: TSP_FRESH_DEFAULT_051_V15 exists but fresh-by-default is not intact."
    )
print("PASS: V15 active-save reload still defaults to fresh process.")
PY_FRESH_CHECK

for marker in \
    'TSP_DEPTH_DIAG_051_V13' \
    'TSP_DEPTH_PROJECTION_051_V13'
do
    if ! grep -Fq "$marker" "$ENGINE_CPP" "$RENDER_CPP" 2>/dev/null; then
        echo "ERROR: depth diagnostic marker missing: $marker"
        exit 1
    fi
done

if ! grep -Fq 'TSP_WARM_LIFETIME_RESET_051_V13' "$WORLD_CPP"; then
    echo "ERROR: corrected V13 world-lifetime marker is missing."
    exit 1
fi

if ! grep -Fq 'TSP_DEFERRED_DEPTH_051_V18' "$RENDER_CPP"; then
    for marker in \
        'TSP_VISIBILITY_FIRST_051_V15' \
        'TSP_DEPTH_PARTITION_051_V14' \
        'TSP_WARM_ASYNC_GUARD_051_V14'
    do
        if ! grep -Fq "$marker" "$RENDER_CPP"; then
            echo "ERROR: expected V15/V14 renderer baseline marker missing:"
            echo "  $marker"
            echo "Nothing was changed."
            exit 1
        fi
    done

    if grep -Fq 'TSP_DEPTH_PARTITION_051_V15' "$RENDER_CPP" \
        || grep -Fq 'TSP_DEPTH_PARTITION_UNIFORM_051_V15' "$STATEUP_CPP"
    then
        echo "ERROR: an older experimental OSG depth-partition patch is present."
        echo "V18 will not stack on that experimental tree."
        echo "Restore/rebuild the successful V15 visibility/fresh-guard baseline first."
        exit 1
    fi
fi

if grep -RqiE \
    'TSP_TRANSITION_MEMORY_PURGE_051|TSP_UNREFERENCED_CACHE_PURGE_051|TSP MEMPURGE|tspPurgeTransitionMemory|clearUnreferencedCache' \
    "$SOURCE_DIR/apps/openmw/mwworld/scene.cpp" \
    "$SOURCE_DIR/components/resource" 2>/dev/null
then
    echo "ERROR: old transition-memory-purge experiment was found."
    echo "V18 refuses to layer on that source tree."
    exit 1
fi

if [ "$PATCH_ONLY" != "1" ]; then
    if [ ! -f "$BUILD_DIR/build.ninja" ] || [ ! -f "$BUILD_DIR/CMakeCache.txt" ]; then
        echo "ERROR: configured Ninja build tree is missing."
        echo "This script intentionally does NOT rerun CMake."
        exit 1
    fi
fi

mkdir -p \
    "$BACKUP_DIR/apps/openmw/mwrender" \
    "$BACKUP_DIR/apps/openmw/mwstate" \
    "$BACKUP_DIR/apps/openmw" \
    "$BACKUP_DIR/components/sceneutil" \
    "$PACKAGE_DIR/bin"

cp -f "$RENDER_CPP" "$BACKUP_DIR/apps/openmw/mwrender/renderingmanager.cpp"
cp -f "$STATEUP_CPP" "$BACKUP_DIR/components/sceneutil/stateupdater.cpp"
cp -f "$ENGINE_CPP" "$BACKUP_DIR/apps/openmw/engine.cpp"
cp -f "$STATE_CPP" "$BACKUP_DIR/apps/openmw/mwstate/statemanagerimp.cpp"

STATE_SHA_BEFORE="$(sha256sum "$STATE_CPP" | awk '{print $1}')"

echo
echo "Protected state-manager SHA256:"
echo "  $STATE_SHA_BEFORE"

echo
echo "===== STAGE 2 OF 2: APPLY V18 DEFERRED DEPTH + NATIVE RESOLUTION + FPS ====="
echo "Applying V18 deferred-depth + native-resolution + FPS source revision..."

python3 - "$RENDER_CPP" "$STATEUP_CPP" "$ENGINE_CPP" <<'PY_PATCH'
from pathlib import Path
import re
import sys

render_path, stateup_path, engine_path = map(Path, sys.argv[1:])

render = render_path.read_text(encoding="utf-8")
stateup = stateup_path.read_text(encoding="utf-8")
engine = engine_path.read_text(encoding="utf-8")

DEPTH_MARK = "TSP_DEFERRED_DEPTH_051_V18"
SETUP_MARK = "TSP_DEFERRED_DEPTH_PREPARED_051_V18"
UNIFORM_MARK = "TSP_DEFERRED_DEPTH_UNIFORM_051_V18"
RES_MARK = "TSP_NATIVE_RESOLUTION_051_V18"
FPS_MARK = "TSP_FPS_OVERLAY_051_V18"


def write_lf(path: Path, text: str) -> None:
    with path.open("w", encoding="utf-8", newline="\n") as handle:
        handle.write(text)


def ensure_include(text: str, include_line: str) -> str:
    if include_line in text:
        return text
    first = re.search(r"^#include[^\n]*\n", text, flags=re.MULTILINE)
    if not first:
        raise RuntimeError(f"include insertion anchor missing for {include_line}")
    return text[:first.end()] + include_line + "\n" + text[first.end():]


def find_function(text: str, signature_pattern: str, label: str):
    matches = list(re.finditer(signature_pattern, text, flags=re.MULTILINE))
    if len(matches) != 1:
        raise RuntimeError(f"{label}: expected one signature, found {len(matches)}")

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
                    return start, i + 1
        i += 1

    raise RuntimeError(f"{label}: closing brace not found")


# =====================================================================
# 1. RENDERING: replace V14's custom slave with native OSG depth bands.
# =====================================================================
render = ensure_include(render, "#include <algorithm>")
render = ensure_include(render, "#include <cmath>")
render = ensure_include(render, "#include <cstdlib>")
render = ensure_include(render, "#include <cstring>")
render = ensure_include(render, "#include <osgViewer/View>")

if DEPTH_MARK not in render:
    old_marker_pos = render.find("// TSP_DEPTH_PARTITION_051_V14")
    if old_marker_pos < 0:
        raise RuntimeError("renderingmanager.cpp: V14 depth helper marker not found")

    inc_start, inc_end = find_function(
        render,
        r"^[ \t]*bool[ \t]+tspIncrementalCompileEnabled[ \t]*\(\)",
        "V14 tspIncrementalCompileEnabled",
    )

    if not (old_marker_pos < inc_start < inc_end):
        raise RuntimeError("renderingmanager.cpp: malformed V14 helper block")

    helper_start = render.rfind("\n", 0, old_marker_pos) + 1

    new_helper = r'''
    // TSP_DEFERRED_DEPTH_051_V18
    // V18 prepares OSG's two proper depth bands but keeps them dormant.
    // OpenMW's master camera/context remains intact until a real player cell
    // has survived a warm-up period, then rendering switches to the bands.
    static osg::ref_ptr<osgViewer::DepthPartitionSettings> sTspV18DepthSettings;
    static osg::ref_ptr<osg::Camera> sTspV18FarCamera;
    static osg::ref_ptr<osg::Camera> sTspV18NearCamera;
    static unsigned int sTspV18MasterCullMask = ~0u;
    static GLbitfield sTspV18MasterClearMask
        = GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT | GL_STENCIL_BUFFER_BIT;
    static bool sTspV18DepthPrepared = false;
    static bool sTspV18DepthActive = false;
    static unsigned int sTspV18ReadyFrames = 0;

    bool tspEnvBool(const char* name, bool fallback)
    {
        const char* value = std::getenv(name);
        if (value == nullptr || *value == '\0')
            return fallback;
        if (std::strcmp(value, "0") == 0 || std::strcmp(value, "false") == 0
            || std::strcmp(value, "off") == 0 || std::strcmp(value, "no") == 0)
            return false;
        if (std::strcmp(value, "1") == 0 || std::strcmp(value, "true") == 0
            || std::strcmp(value, "on") == 0 || std::strcmp(value, "yes") == 0)
            return true;
        return fallback;
    }

    float tspEnvFloat(const char* name, float fallback)
    {
        const char* value = std::getenv(name);
        if (value == nullptr || *value == '\0')
            return fallback;
        char* end = nullptr;
        const float parsed = std::strtof(value, &end);
        if (end == value || *end != '\0')
            return fallback;
        return parsed;
    }

    unsigned int tspEnvUInt(const char* name, unsigned int fallback)
    {
        const char* value = std::getenv(name);
        if (value == nullptr || *value == '\0')
            return fallback;
        char* end = nullptr;
        const unsigned long parsed = std::strtoul(value, &end, 10);
        if (end == value || *end != '\0' || parsed == 0 || parsed > 36000)
            return fallback;
        return static_cast<unsigned int>(parsed);
    }

    bool tspV18AdaptiveDepthEnabled()
    {
        return tspEnvBool("OPENMW_TSP_ADAPTIVE_DEPTH", true);
    }

    unsigned int tspV18DepthDelayFrames()
    {
        return tspEnvUInt("OPENMW_TSP_DEPTH_DELAY_FRAMES", 120u);
    }

    float tspV18AdaptiveSplit(float nearClip, float farClip)
    {
        const float minSplit = nearClip + 1.f;
        const float maxSplit = farClip - 1.f;
        const float manual = tspEnvFloat("OPENMW_TSP_DEPTH_SPLIT", -1.f);
        if (manual > minSplit && manual < maxSplit)
            return manual;
        const double product
            = static_cast<double>(std::max(nearClip, 0.5f))
            * static_cast<double>(std::max(farClip, nearClip + 2.f));
        float split = static_cast<float>(std::sqrt(product));
        split = std::max(split, minSplit);
        split = std::min(split, maxSplit);
        return split;
    }

    void tspV18UpdateDepthRanges(float nearClip, float farClip)
    {
        if (!sTspV18DepthSettings)
            return;
        sTspV18DepthSettings->_zNear = std::max(nearClip, 0.5f);
        sTspV18DepthSettings->_zMid
            = tspV18AdaptiveSplit(sTspV18DepthSettings->_zNear, farClip);
        sTspV18DepthSettings->_zFar = farClip;
    }

    bool tspIncrementalCompileEnabled()
    {
        return tspEnvBool("OPENMW_TSP_INCREMENTAL_COMPILE", false);
    }
'''

    render = render[:helper_start] + new_helper + render[inc_end:]

    rstart, rend = find_function(
        render,
        r"^[ \t]*void[ \t]+RenderingManager::updateProjectionMatrix[ \t]*\(\)",
        "RenderingManager::updateProjectionMatrix",
    )

    new_projection = r'''    void RenderingManager::updateProjectionMatrix()
    {
        if (mNearClip < 0.0f)
            throw std::runtime_error("Near clip is less than zero");
        if (mViewDistance < mNearClip)
            throw std::runtime_error("Viewing distance is less than near clip");

        const int width = Settings::video().mResolutionX;
        const int height = Settings::video().mResolutionY;
        const double aspect = (height == 0) ? 1.0 : static_cast<double>(width) / height;
        const float fov = mFieldOfViewOverridden ? mFieldOfViewOverride : mFieldOfView;

        Log(Debug::Info) << "TSP_DEPTH_PROJECTION_051_V13"
                         << " near=" << mNearClip
                         << " far=" << mViewDistance
                         << " far_near_ratio="
                         << (mNearClip > 0.f ? mViewDistance / mNearClip : 0.f)
                         << " fov=" << fov
                         << " reversed=" << (SceneUtil::AutoDepth::isReversed() ? 1 : 0);

        if (sTspV18DepthActive && sTspV18DepthSettings)
        {
            tspV18UpdateDepthRanges(mNearClip, mViewDistance);

            const float nearRatio
                = sTspV18DepthSettings->_zMid / sTspV18DepthSettings->_zNear;
            const float farRatio
                = sTspV18DepthSettings->_zFar / sTspV18DepthSettings->_zMid;

            Log(Debug::Info) << "TSP_DEFERRED_DEPTH_051_V18"
                             << " update=1"
                             << " near=" << sTspV18DepthSettings->_zNear
                             << " split=" << sTspV18DepthSettings->_zMid
                             << " far=" << sTspV18DepthSettings->_zFar
                             << " near_ratio=" << nearRatio
                             << " far_ratio=" << farRatio;
        }

        osg::Matrix unreversedProjectionMatrix
            = osg::Matrix::perspective(fov, aspect, mNearClip, mViewDistance);

        osg::Matrix projectionMatrix = SceneUtil::AutoDepth::isReversed()
            ? SceneUtil::getReversedZProjectionMatrixAsPerspective(
                fov, aspect, mNearClip, mViewDistance)
            : unreversedProjectionMatrix;

        if (width != 0 && height != 0)
        {
            const double offsetX = (mProjectionOffset.x() / width) * 2.0;
            const double offsetY = (mProjectionOffset.y() / height) * 2.0;
            const osg::Matrix translation = osg::Matrix::translate(offsetX, offsetY, 0.0);
            projectionMatrix.postMult(translation);
            unreversedProjectionMatrix.postMult(translation);
        }

        mViewer->getCamera()->setProjectionMatrix(unreversedProjectionMatrix);
        mPerViewUniformStateUpdater->setProjectionMatrix(projectionMatrix);

        mSharedUniformStateUpdater->setNear(mNearClip);
        mSharedUniformStateUpdater->setFar(mViewDistance);

        if (Stereo::getStereo())
        {
            const auto res = Stereo::Manager::instance().eyeResolution();
            setScreenRes(res.x(), res.y());
            Stereo::Manager::instance().setMasterProjectionMatrix(
                mPerViewUniformStateUpdater->getProjectionMatrix());
        }
        else
            setScreenRes(width, height);

        const float distanceMult
            = std::cos(osg::DegreesToRadians(std::min(fov, 140.f)) / 2.f);

        mTerrain->setViewDistance(
            mViewDistance * (distanceMult ? 1.f / distanceMult : 1.f));

        if (mPostProcessor)
        {
            mPostProcessor->getStateUpdater()->setProjectionMatrix(
                mPerViewUniformStateUpdater->getProjectionMatrix());
            mPostProcessor->getStateUpdater()->setFov(fov);
        }
    }'''

    render = render[:rstart] + new_projection + render[rend:]

    if "TSP_DEPTH_PARTITION_051_V14_NEARFAR" in render:
        nearfar_re = re.compile(
            r'(?P<indent>^[ \t]*)// TSP_DEPTH_PARTITION_051_V14_NEARFAR\n'
            r'(?P=indent)(?P<prefix>[^;\n]*setNearFar\()'
            r'tspWorldNearClip\(mNearClip,\s*mViewDistance\),\s*mViewDistance\);',
            flags=re.MULTILINE,
        )
        nm = nearfar_re.search(render)
        if not nm:
            raise RuntimeError(
                "renderingmanager.cpp: V14 shared near/far marker exists "
                "but the block was not recognized"
            )

        render = (
            render[:nm.start()]
            + nm.group("indent")
            + nm.group("prefix")
            + "mNearClip, mViewDistance);"
            + render[nm.end():]
        )

    if SETUP_MARK not in render:
        anchor = (
            "        mViewer->getCamera()->setClearMask("
            "GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT | GL_STENCIL_BUFFER_BIT);\n"
        )
        pos = render.find(anchor)
        if pos < 0:
            raise RuntimeError(
                "renderingmanager.cpp: master clear-mask constructor anchor missing"
            )
        pos += len(anchor)

        setup = r'''
        // TSP_DEFERRED_DEPTH_PREPARED_051_V18
        if (tspV18AdaptiveDepthEnabled() && !reverseZ)
        {
            osg::Camera* master = mViewer->getCamera();
            osg::ref_ptr<osg::GraphicsContext> masterContext
                = master->getGraphicsContext();
            osg::ref_ptr<osg::Viewport> masterViewport
                = master->getViewport();
            const unsigned int oldSlaveCount = mViewer->getNumSlaves();

            sTspV18MasterCullMask = master->getCullMask();
            sTspV18MasterClearMask = master->getClearMask();
            const auto masterCullingMode = master->getCullingMode();
            const osg::Vec4 masterClearColor = master->getClearColor();
            const double masterClearDepth = master->getClearDepth();
            const int masterClearStencil = master->getClearStencil();

            sTspV18DepthSettings = new osgViewer::DepthPartitionSettings(
                osgViewer::DepthPartitionSettings::FIXED_RANGE);
            tspV18UpdateDepthRanges(mNearClip, mViewDistance);

            const bool partitionOk
                = masterContext.valid()
                && masterViewport.valid()
                && mViewer->setUpDepthPartitionForCamera(
                    master, sTspV18DepthSettings.get());

            if (partitionOk && mViewer->getNumSlaves() >= oldSlaveCount + 2)
            {
                osg::Camera* farCamera
                    = mViewer->getSlave(oldSlaveCount)._camera.get();
                osg::Camera* nearCamera
                    = mViewer->getSlave(oldSlaveCount + 1)._camera.get();

                if (farCamera != nullptr && nearCamera != nullptr)
                {
                    // OSG normally detaches the master. V18 immediately
                    // restores it so OpenMW retains the GraphicsContext,
                    // viewport, callbacks and event/picking camera it was
                    // initialized around.
                    master->setGraphicsContext(masterContext.get());
                    master->setViewport(masterViewport.get());
                    master->setCullMask(sTspV18MasterCullMask);
                    master->setClearMask(sTspV18MasterClearMask);

                    farCamera->setCullingMode(masterCullingMode);
                    nearCamera->setCullingMode(masterCullingMode);
                    farCamera->setClearColor(masterClearColor);
                    nearCamera->setClearColor(masterClearColor);
                    farCamera->setClearDepth(masterClearDepth);
                    nearCamera->setClearDepth(masterClearDepth);
                    farCamera->setClearStencil(masterClearStencil);
                    nearCamera->setClearStencil(masterClearStencil);

                    // Dormant until the player has survived a real-cell
                    // warmup. Clear mask 0 is important too: a cull-disabled
                    // camera must not erase the master camera's menu/world.
                    farCamera->setCullMask(0u);
                    nearCamera->setCullMask(0u);
                    farCamera->setClearMask(0);
                    nearCamera->setClearMask(0);
                    farCamera->setAllowEventFocus(false);
                    nearCamera->setAllowEventFocus(false);
                    farCamera->setName("TSP V18 dormant far depth band");
                    nearCamera->setName("TSP V18 dormant near depth band");

                    sTspV18FarCamera = farCamera;
                    sTspV18NearCamera = nearCamera;
                    sTspV18DepthPrepared = true;

                    Log(Debug::Info)
                        << "TSP_DEFERRED_DEPTH_PREPARED_051_V18"
                        << " prepared=1 active=0"
                        << " master_context_retained=1"
                        << " callbacks=master-retained"
                        << " delay_frames=" << tspV18DepthDelayFrames()
                        << " near=" << sTspV18DepthSettings->_zNear
                        << " split=" << sTspV18DepthSettings->_zMid
                        << " far=" << sTspV18DepthSettings->_zFar
                        << " slaves=" << mViewer->getNumSlaves();
                }
            }

            if (!sTspV18DepthPrepared)
            {
                if (masterContext.valid())
                    master->setGraphicsContext(masterContext.get());
                if (masterViewport.valid())
                    master->setViewport(masterViewport.get());
                master->setCullMask(sTspV18MasterCullMask);
                master->setClearMask(sTspV18MasterClearMask);

                Log(Debug::Warning)
                    << "TSP_DEFERRED_DEPTH_PREPARED_051_V18"
                    << " prepared=0 reason=osg-setup-failed";
            }
        }
        else
        {
            Log(Debug::Info)
                << "TSP_DEFERRED_DEPTH_PREPARED_051_V18"
                << " prepared=0 reason="
                << (reverseZ ? "reverse-z-active" : "environment-disabled");
        }
'''
        render = render[:pos] + setup + render[pos:]

    # TSP_DEFERRED_DEPTH_ACTIVE_051_V18: activate only after normal master-camera
    # rendering has run with an in-cell player for a stable warm-up interval.
    ustart, uend = find_function(
        render,
        r"^[ \t]*void[ \t]+RenderingManager::update[ \t]*\(float dt,\s*bool paused\)",
        "RenderingManager::update",
    )
    ufunc = render[ustart:uend]
    update_anchor = "        reportStats();\n"
    if update_anchor not in ufunc:
        raise RuntimeError("RenderingManager::update reportStats anchor missing")

    activation = r'''
        // TSP_DEFERRED_DEPTH_ACTIVE_051_V18
        if (sTspV18DepthPrepared && !sTspV18DepthActive)
        {
            const bool playerReady
                = mPlayerAnimation && mPlayerAnimation->getPtr().isInCell();

            if (playerReady && !paused)
                ++sTspV18ReadyFrames;
            else
                sTspV18ReadyFrames = 0;

            const unsigned int delayFrames = tspV18DepthDelayFrames();

            if (sTspV18ReadyFrames == 1)
            {
                Log(Debug::Info)
                    << "TSP_DEFERRED_DEPTH_051_V18"
                    << " warmup=begin delay_frames=" << delayFrames;
            }

            if (sTspV18ReadyFrames >= delayFrames)
            {
                osg::Camera* master = mViewer->getCamera();
                master->setCullMask(0u);
                master->setClearMask(0);

                sTspV18FarCamera->setCullMask(sTspV18MasterCullMask);
                sTspV18NearCamera->setCullMask(sTspV18MasterCullMask);
                sTspV18FarCamera->setClearMask(sTspV18MasterClearMask);
                sTspV18NearCamera->setClearMask(GL_DEPTH_BUFFER_BIT);

                sTspV18FarCamera->setName("TSP V18 active far depth band");
                sTspV18NearCamera->setName("TSP V18 active near depth band");
                sTspV18DepthActive = true;
                tspV18UpdateDepthRanges(mNearClip, mViewDistance);

                Log(Debug::Info)
                    << "TSP_DEFERRED_DEPTH_ACTIVE_051_V18"
                    << " active=1"
                    << " master_context_retained="
                    << (master->getGraphicsContext() ? 1 : 0)
                    << " master_render=0"
                    << " near=" << sTspV18DepthSettings->_zNear
                    << " split=" << sTspV18DepthSettings->_zMid
                    << " far=" << sTspV18DepthSettings->_zFar
                    << " slaves=" << mViewer->getNumSlaves();
            }
        }
'''
    ufunc = ufunc.replace(update_anchor, update_anchor + activation, 1)
    render = render[:ustart] + ufunc + render[uend:]


# OSG's native partition detaches the GraphicsContext from OpenMW's master
# camera. OpenMW still writes changing fog/background clear colors to that
# master, so mirror those writes to the actual V18 rendering cameras.
CLEAR_MARK = "TSP_DEFERRED_DEPTH_CLEARCOLOR_051_V18"
if CLEAR_MARK not in render:
    fstart, fend = find_function(
        render,
        r"^[ \t]*void[ \t]+RenderingManager::setFogColor[ \t]*\(const osg::Vec4f& color\)",
        "RenderingManager::setFogColor",
    )
    ffunc = render[fstart:fend]
    old_clear = "        mViewer->getCamera()->setClearColor(color);\n"
    if old_clear not in ffunc:
        raise RuntimeError("renderingmanager.cpp: setFogColor clear-color anchor missing")
    new_clear = r'''        // TSP_DEFERRED_DEPTH_CLEARCOLOR_051_V18
        mViewer->getCamera()->setClearColor(color);
        if (sTspV18FarCamera)
            sTspV18FarCamera->setClearColor(color);
        if (sTspV18NearCamera)
            sTspV18NearCamera->setClearColor(color);
'''
    ffunc = ffunc.replace(old_clear, new_clear, 1)
    render = render[:fstart] + ffunc + render[fend:]


# =====================================================================
# 2. SHADER PROJECTION: each cull camera must expose its own projection.
# =====================================================================
stateup = ensure_include(stateup, "#include <cstdlib>")
stateup = ensure_include(stateup, "#include <cstring>")
stateup = ensure_include(stateup, "#include <osgUtil/CullVisitor>")

if UNIFORM_MARK not in stateup:
    if "TSP_DEPTH_PARTITION_UNIFORM_051_V15" in stateup:
        raise RuntimeError(
            "stateupdater.cpp: older experimental partition-uniform patch present"
        )

    ns = re.search(r"namespace\s+SceneUtil\s*\n?\{", stateup)
    if not ns:
        raise RuntimeError("stateupdater.cpp: namespace SceneUtil anchor missing")

    helper = r'''

    // TSP_DEFERRED_DEPTH_UNIFORM_051_V18
    bool tspV18AdaptiveDepthUniformEnabled()
    {
        const char* value = std::getenv("OPENMW_TSP_ADAPTIVE_DEPTH");
        if (value == nullptr || *value == '\0')
            return true;

        return !(std::strcmp(value, "0") == 0
            || std::strcmp(value, "false") == 0
            || std::strcmp(value, "off") == 0
            || std::strcmp(value, "no") == 0);
    }
'''

    stateup = stateup[:ns.end()] + helper + stateup[ns.end():]

    old = (
        '        stateset->getUniform("projectionMatrix")->set(mProjectionMatrix);\n'
    )

    if old not in stateup:
        raise RuntimeError(
            "stateupdater.cpp: projectionMatrix uniform anchor missing"
        )

    new = r'''        // TSP_DEFERRED_DEPTH_UNIFORM_051_V18_ACTIVE
        if (tspV18AdaptiveDepthUniformEnabled()
            && !AutoDepth::isReversed()
            && nv != nullptr
            && nv->getVisitorType() == osg::NodeVisitor::CULL_VISITOR)
        {
            osgUtil::CullVisitor* cv
                = static_cast<osgUtil::CullVisitor*>(nv);

            const osg::RefMatrix* currentProjection
                = cv->getProjectionMatrix();

            if (currentProjection != nullptr)
            {
                stateset->getUniform("projectionMatrix")->set(
                    osg::Matrixf(*currentProjection));
            }
            else
            {
                stateset->getUniform("projectionMatrix")->set(
                    mProjectionMatrix);
            }
        }
        else
        {
            stateset->getUniform("projectionMatrix")->set(
                mProjectionMatrix);
        }
'''

    stateup = stateup.replace(old, new, 1)


# =====================================================================
# 3. NATIVE SDL RESOLUTION PROFILES
# =====================================================================
# Unlike the failed LIBGL_FB=2 experiment, this changes OpenMW's own SDL
# drawable size before the GL context is created. The launcher can select:
# native/configured, balanced=1024x576, performance=854x480, low=640x360,
# or an explicit WxH. If SDL cannot create the custom mode after V13's normal
# depth/stencil fallbacks, V18 retries the configured resolution once.
if RES_MARK not in engine:
    cstart, cend = find_function(
        engine,
        r"^[ \t]*void[ \t]+OMW::Engine::createWindow[ \t]*\(\)",
        "Engine::createWindow",
    )
    cfunc = engine[cstart:cend]

    width_anchor = (
        "    const int screen = Settings::video().mScreen;\n"
        "    const int width = Settings::video().mResolutionX;\n"
        "    const int height = Settings::video().mResolutionY;\n"
    )
    if width_anchor not in cfunc:
        raise RuntimeError("engine.cpp: createWindow width/height anchor not found")

    setup = r'''
    const int screen = Settings::video().mScreen;

    // TSP_NATIVE_RESOLUTION_051_V18
    const int tspConfiguredWidth = Settings::video().mResolutionX;
    const int tspConfiguredHeight = Settings::video().mResolutionY;
    int width = tspConfiguredWidth;
    int height = tspConfiguredHeight;
    bool tspResolutionOverride = false;
    bool tspResolutionFallbackTried = false;
    const char* tspResolutionValue = std::getenv("OPENMW_TSP_RESOLUTION");

    if (tspResolutionValue != nullptr && *tspResolutionValue != '\0'
        && std::strcmp(tspResolutionValue, "native") != 0
        && std::strcmp(tspResolutionValue, "off") != 0)
    {
        int requestedWidth = 0;
        int requestedHeight = 0;

        if (std::strcmp(tspResolutionValue, "balanced") == 0)
        {
            requestedWidth = 1024;
            requestedHeight = 576;
        }
        else if (std::strcmp(tspResolutionValue, "performance") == 0)
        {
            requestedWidth = 854;
            requestedHeight = 480;
        }
        else if (std::strcmp(tspResolutionValue, "low") == 0)
        {
            requestedWidth = 640;
            requestedHeight = 360;
        }
        else
        {
            char* endWidth = nullptr;
            const long parsedWidth = std::strtol(tspResolutionValue, &endWidth, 10);
            if (endWidth != tspResolutionValue && (*endWidth == 'x' || *endWidth == 'X'))
            {
                char* endHeight = nullptr;
                const long parsedHeight = std::strtol(endWidth + 1, &endHeight, 10);
                if (endHeight != endWidth + 1 && *endHeight == '\0'
                    && parsedWidth >= 320 && parsedWidth <= 4096
                    && parsedHeight >= 180 && parsedHeight <= 2160)
                {
                    requestedWidth = static_cast<int>(parsedWidth);
                    requestedHeight = static_cast<int>(parsedHeight);
                }
            }
        }

        if (requestedWidth > 0 && requestedHeight > 0)
        {
            width = requestedWidth;
            height = requestedHeight;
            tspResolutionOverride = true;
            Settings::video().mResolutionX.set(width);
            Settings::video().mResolutionY.set(height);
            Log(Debug::Info) << "TSP_NATIVE_RESOLUTION_051_V18"
                             << " requested=" << tspResolutionValue
                             << " logical=" << width << "x" << height
                             << " configured=" << tspConfiguredWidth << "x" << tspConfiguredHeight;
        }
        else
        {
            Log(Debug::Warning) << "TSP_NATIVE_RESOLUTION_051_V18"
                                << " invalid_request=" << tspResolutionValue
                                << " using_configured=" << tspConfiguredWidth << "x" << tspConfiguredHeight;
        }
    }
    else
    {
        Log(Debug::Info) << "TSP_NATIVE_RESOLUTION_051_V18"
                         << " requested=native logical=" << width << "x" << height;
    }
'''
    cfunc = cfunc.replace(width_anchor, setup, 1)

    error_anchor = (
        "                    std::stringstream error;\n"
        '                    error << "Failed to create SDL window: " << SDL_GetError();\n'
    )
    if error_anchor not in cfunc:
        raise RuntimeError("engine.cpp: final SDL error anchor missing")

    fallback = r'''
                    if (tspResolutionOverride && !tspResolutionFallbackTried)
                    {
                        Log(Debug::Warning) << "TSP_NATIVE_RESOLUTION_051_V18"
                                            << " requested_mode_failed=" << width << "x" << height
                                            << " retrying_configured="
                                            << tspConfiguredWidth << "x" << tspConfiguredHeight;
                        tspResolutionFallbackTried = true;
                        tspResolutionOverride = false;
                        width = tspConfiguredWidth;
                        height = tspConfiguredHeight;
                        Settings::video().mResolutionX.set(width);
                        Settings::video().mResolutionY.set(height);
                        tspDepthBits = 24;
                        tspStencilBits = 8;
                        SDL_GL_SetAttribute(SDL_GL_DEPTH_SIZE, tspDepthBits);
                        SDL_GL_SetAttribute(SDL_GL_STENCIL_SIZE, tspStencilBits);
                        continue;
                    }

'''
    cfunc = cfunc.replace(error_anchor, fallback + error_anchor, 1)

    traits_anchor = (
        "        traits->alpha = 0; // set to 0 to stop ScreenCaptureHandler reading the alpha channel\n"
    )
    if traits_anchor not in cfunc:
        raise RuntimeError("engine.cpp: traits alpha anchor missing")

    actual = r'''
        Log(Debug::Info) << "TSP_NATIVE_RESOLUTION_051_V18"
                         << " actual_drawable=" << traits->width << "x" << traits->height
                         << " logical=" << width << "x" << height
                         << " fallback=" << (tspResolutionFallbackTried ? 1 : 0);
'''
    cfunc = cfunc.replace(traits_anchor, actual + traits_anchor, 1)
    engine = engine[:cstart] + cfunc + engine[cend:]


# =====================================================================
# 3. FPS OVERLAY: automatically perform the same first toggle as F3.
# =====================================================================
engine = ensure_include(engine, "#include <cstdlib>")
engine = ensure_include(engine, "#include <cstring>")
engine = ensure_include(engine, "#include <osgGA/GUIEventAdapter>")

if FPS_MARK not in engine:
    ns = re.search(r"namespace\s*\n?\{", engine)
    if not ns:
        raise RuntimeError("engine.cpp: anonymous namespace anchor missing")

    fps_helper = r'''

    // TSP_FPS_OVERLAY_051_V18
    bool tspV18ShowFpsEnabled()
    {
        const char* value = std::getenv("OPENMW_TSP_SHOW_FPS");
        if (value == nullptr || *value == '\0')
            return true;

        return !(std::strcmp(value, "0") == 0
            || std::strcmp(value, "false") == 0
            || std::strcmp(value, "off") == 0
            || std::strcmp(value, "no") == 0);
    }
'''

    engine = engine[:ns.end()] + fps_helper + engine[ns.end():]

    anchor = "    mViewer->addEventHandler(statsHandler);\n"
    if anchor not in engine:
        raise RuntimeError(
            "engine.cpp: profiler addEventHandler anchor missing"
        )

    fps_hook = r'''
    if (tspV18ShowFpsEnabled())
    {
        mViewer->getEventQueue()->keyPress(
            osgGA::GUIEventAdapter::KEY_F3);
        mViewer->getEventQueue()->keyRelease(
            osgGA::GUIEventAdapter::KEY_F3);

        Log(Debug::Info)
            << "TSP_FPS_OVERLAY_051_V18 enabled=1 key=F3 page=fps";
    }
    else
    {
        Log(Debug::Info)
            << "TSP_FPS_OVERLAY_051_V18 enabled=0";
    }

'''

    engine = engine.replace(anchor, anchor + fps_hook, 1)


# =====================================================================
# 4. FINAL SOURCE VERIFICATION.
# =====================================================================
for required in (
    DEPTH_MARK,
    SETUP_MARK,
    "TSP_DEFERRED_DEPTH_CLEARCOLOR_051_V18",
    "osgViewer::DepthPartitionSettings",
    "setUpDepthPartitionForCamera",
    "std::sqrt",
    "OPENMW_TSP_ADAPTIVE_DEPTH",
    "OPENMW_TSP_DEPTH_SPLIT",
    "sTspV18FarCamera",
    "sTspV18NearCamera",
    "nearCamera->setAllowEventFocus(false)",
    "TSP_DEFERRED_DEPTH_ACTIVE_051_V18",
    "OPENMW_TSP_DEPTH_DELAY_FRAMES",
    "master->setGraphicsContext(masterContext.get())",
    "master->setCullMask(0u)",
    "TSP_DEPTH_PROJECTION_051_V13",
    "TSP_WARM_ASYNC_GUARD_051_V14",
    "OPENMW_TSP_INCREMENTAL_COMPILE",
):
    if required not in render:
        raise RuntimeError(
            f"renderingmanager.cpp: V18 verification missing: {required}"
        )

for forbidden in (
    "TSP_DEPTH_PARTITION_051_V14_ACTIVE",
    "sTspNearDepthCamera",
    "tspWorldNearClip",
    "tspNearPassFarClip",
    "TSP_VISIBILITY_FIRST_051_V15",
):
    if forbidden in render:
        raise RuntimeError(
            f"renderingmanager.cpp: obsolete custom-partition residue: {forbidden}"
        )

for required in (
    UNIFORM_MARK,
    "currentProjection",
    "osgUtil::CullVisitor",
    "OPENMW_TSP_ADAPTIVE_DEPTH",
):
    if required not in stateup:
        raise RuntimeError(
            f"stateupdater.cpp: V18 verification missing: {required}"
        )

for required in (
    RES_MARK,
    "OPENMW_TSP_RESOLUTION",
    "balanced",
    "performance",
    "requested_mode_failed",
    "actual_drawable",
    FPS_MARK,
    "OPENMW_TSP_SHOW_FPS",
    "KEY_F3",
    "keyPress",
    "keyRelease",
):
    if required not in engine:
        raise RuntimeError(
            f"engine.cpp: V18 resolution/FPS verification missing: {required}"
        )

write_lf(render_path, render)
write_lf(stateup_path, stateup)
write_lf(engine_path, engine)

print("V18 source patch applied and verified.")
print("  reload stability source: NOT TOUCHED")
print("  depth: OSG bands prepared dormant; OpenMW master context retained")
print("  depth activation: delayed player-in-cell warmup; geometric split")
print("  V14 incremental-compile guard: retained")
print("  per-cull projection uniform: enabled")
print("  resolution: native SDL profiles with configured-mode fallback")
print("  FPS overlay: automatic OpenMW F3 first page")
PY_PATCH

echo
echo "===== SOURCE VERIFICATION ====="

echo
echo "-- V18 deferred/master-anchored depth --"
grep -n -m 30 \
    -e 'TSP_DEFERRED_DEPTH_051_V18' \
    -e 'TSP_DEFERRED_DEPTH_PREPARED_051_V18' \
    -e 'TSP_DEFERRED_DEPTH_ACTIVE_051_V18' \
    -e 'OPENMW_TSP_DEPTH_DELAY_FRAMES' \
    -e 'OPENMW_TSP_ADAPTIVE_DEPTH' \
    -e 'OPENMW_TSP_DEPTH_SPLIT' \
    -e 'setUpDepthPartitionForCamera' \
    "$RENDER_CPP"

echo
echo "-- V18 per-cull projection --"
grep -n -m 20 \
    -e 'TSP_DEFERRED_DEPTH_UNIFORM_051_V18' \
    -e 'currentProjection' \
    "$STATEUP_CPP"

echo
echo "-- V18 native SDL resolution profiles --"
grep -n -m 30 \
    -e 'TSP_NATIVE_RESOLUTION_051_V18' \
    -e 'OPENMW_TSP_RESOLUTION' \
    -e 'requested_mode_failed' \
    -e 'actual_drawable' \
    "$ENGINE_CPP"

echo
echo "-- V18 FPS overlay --"
grep -n -m 20 \
    -e 'TSP_FPS_OVERLAY_051_V18' \
    -e 'OPENMW_TSP_SHOW_FPS' \
    -e 'KEY_F3' \
    "$ENGINE_CPP"

echo
echo "-- V14 incremental-compile safety guard retained --"
grep -n -m 12 \
    -e 'TSP_WARM_ASYNC_GUARD_051_V14' \
    -e 'OPENMW_TSP_INCREMENTAL_COMPILE' \
    "$RENDER_CPP"

echo
echo "-- V15 fresh reload MUST remain untouched --"
STATE_SHA_AFTER="$(sha256sum "$STATE_CPP" | awk '{print $1}')"

echo "Before: $STATE_SHA_BEFORE"
echo "After:  $STATE_SHA_AFTER"

if [ "$STATE_SHA_BEFORE" != "$STATE_SHA_AFTER" ]; then
    echo "ERROR: statemanagerimp.cpp changed unexpectedly."
    exit 1
fi

echo "PASS: statemanagerimp.cpp is byte-for-byte unchanged."

for marker in \
    'TSP_FRESH_DEFAULT_051_V15' \
    'TSP_FRESH_PROCESS_LOAD_051_V12' \
    'TSP_SAFE_RELOAD_CONFIG_051_V13' \
    'TSP_LOAD_TRACE_051_V13' \
    'TSP_LOAD_WATCH_051_V13'
do
    grep -Fq "$marker" "$STATE_CPP" || {
        echo "ERROR: protected reload marker disappeared: $marker"
        exit 1
    }
done

echo "PASS: V12/V13/V15 fresh-reload markers retained."

echo
echo "-- Transition-memory purge must remain absent --"
if grep -RniE \
    'TSP_TRANSITION_MEMORY_PURGE_051|TSP_UNREFERENCED_CACHE_PURGE_051|TSP MEMPURGE|tspPurgeTransitionMemory|clearUnreferencedCache' \
    "$SOURCE_DIR/apps/openmw/mwworld/scene.cpp" \
    "$SOURCE_DIR/components/resource" 2>/dev/null
then
    echo "ERROR: transition-memory-purge remnant found."
    exit 1
else
    echo "PASS: old transition-memory-purge experiment remains absent."
fi

if [ "$PATCH_ONLY" = "1" ]; then
    trap - ERR
    echo
    echo "PATCH_ONLY=1: V18 source patch/verification complete."
    exit 0
fi

echo
echo "Incrementally rebuilding OpenMW 0.51 (UNSTRIPPED)..."

cmake --build \
    "$BUILD_DIR" \
    --target openmw \
    --parallel "$JOBS"

if [ ! -x "$BUILT_BINARY" ]; then
    echo "ERROR: rebuilt OpenMW executable is missing:"
    echo "  $BUILT_BINARY"
    exit 1
fi

echo
echo "Packaging V18 binary..."

if [ -e "$OUTPUT_BINARY" ]; then
    cp -f "$OUTPUT_BINARY" "$OUTPUT_BINARY.before-$STAMP"
fi

if [ -e "$PACKAGE_BINARY" ]; then
    cp -f "$PACKAGE_BINARY" "$PACKAGE_BINARY.before-v18-$STAMP"
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
    'TSP_DEFERRED_DEPTH_051_V18' \
    'TSP_DEFERRED_DEPTH_PREPARED_051_V18' \
    'TSP_DEFERRED_DEPTH_ACTIVE_051_V18' \
    'TSP_DEFERRED_DEPTH_UNIFORM_051_V18' \
    'TSP_NATIVE_RESOLUTION_051_V18' \
    'TSP_FPS_OVERLAY_051_V18' \
    'OPENMW_TSP_ADAPTIVE_DEPTH' \
    'OPENMW_TSP_DEPTH_SPLIT' \
    'OPENMW_TSP_DEPTH_DELAY_FRAMES' \
    'OPENMW_TSP_RESOLUTION' \
    'OPENMW_TSP_SHOW_FPS' \
    'TSP_FRESH_DEFAULT_051_V15' \
    'TSP_FRESH_PROCESS_LOAD_051_V12' \
    'TSP_SAFE_RELOAD_CONFIG_051_V13' \
    'TSP_LOAD_TRACE_051_V13' \
    'TSP_LOAD_WATCH_051_V13' \
    'TSP_DEPTH_DIAG_051_V13' \
    'TSP_WARM_ASYNC_GUARD_051_V14'
do
    if ! strings "$PACKAGE_BINARY" | grep -F "$marker" >/dev/null; then
        echo "ERROR: required runtime marker missing from rebuilt binary:"
        echo "  $marker"
        exit 1
    fi
done

if strings "$PACKAGE_BINARY" | grep -F \
    'TSP_DEPTH_PARTITION_051_V14 near_camera_created=1' >/dev/null
then
    echo "ERROR: obsolete V14 custom near-camera runtime string remains."
    exit 1
fi

if strings "$PACKAGE_BINARY" | grep -E \
    'TSP MEMPURGE|TSP_TRANSITION_MEMORY_PURGE_051|TSP_UNREFERENCED_CACHE_PURGE_051' \
    >/dev/null
then
    echo "ERROR: obsolete transition-memory-purge marker in binary."
    exit 1
fi

echo "PASS: V18 deferred-depth markers present."
echo "PASS: V18 native-resolution markers present."
echo "PASS: automatic FPS-overlay marker present."
echo "PASS: successful V15 fresh-reload markers retained."
echo "PASS: obsolete V14 custom near-camera marker absent."

trap - ERR

echo
echo "============================================================"
echo "SUCCESS: OpenMW 0.51 V18 build complete"
echo "============================================================"
echo "Package binary:"
echo "  $PACKAGE_BINARY"
echo
echo "Container standalone copy:"
echo "  $OUTPUT_BINARY"
echo
echo "Known-good baseline:"
echo "  $BASELINE_BACKUP"
echo "Original live source backup:"
echo "  $PRE_RESTORE_BACKUP"
echo "V18 patch backup:"
echo "  $BACKUP_DIR"
echo
echo "Protected state-manager SHA256:"
echo "  $STATE_SHA_AFTER"
echo
echo "V18 defaults:"
echo "  V15 fresh active-save reload = UNCHANGED / ON"
echo "  adaptive depth partition     = PREPARED at startup, delayed activation"
echo "  partition near               = configured [Camera] near clip"
echo "  partition split              = sqrt(near * view distance)"
echo "  partition activation delay   = 120 in-cell update frames"
echo "  native resolution override   = OFF unless OPENMW_TSP_RESOLUTION is set"
echo "  FPS overlay                  = ON (OpenMW F3 first page)"
echo "  incremental compile          = OFF (existing V14 safety default)"
echo
echo "Runtime switches:"
echo "  OPENMW_TSP_ADAPTIVE_DEPTH=0|1"
echo "  OPENMW_TSP_DEPTH_SPLIT=<distance>   # optional manual override"
echo "  OPENMW_TSP_DEPTH_DELAY_FRAMES=<frames>"
echo "  OPENMW_TSP_RESOLUTION=native|balanced|performance|low|WxH"
echo "  OPENMW_TSP_SHOW_FPS=0|1"
echo "  GL4ES LIBGL_FB=2 scaler       = NOT USED"
echo "============================================================"
