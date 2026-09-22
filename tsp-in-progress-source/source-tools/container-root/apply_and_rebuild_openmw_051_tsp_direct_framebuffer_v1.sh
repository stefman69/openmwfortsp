#!/bin/bash
set -Eeuo pipefail

# OpenMW 0.51.0 TrimUI Smart Pro / gl4es direct-framebuffer diagnostic rebuild.
#
# Purpose:
#   Restore the direct FRAME_BUFFER fallback that existed in OpenMW 0.48-style
#   rendering, while retaining OpenMW 0.51's shader-based world renderer.
#
# Why:
#   OpenMW 0.51 constructs its PostProcessor/FBO chain even when post-processing
#   effects are disabled. On the TSP's gl4es -> GLES2 stack, the game simulation
#   and UI can run while the 3D scene presented through that FBO chain is white.
#
# This patch deliberately disables, for this diagnostic build:
#   - PostProcessor FBO interception / fullscreen scene presentation
#   - opaque-depth texture reservation and binding
#   - normals MRT support
#   - weather-particle depth occlusion
#   - soft-particle depth effects
#
# It does NOT revert OpenMW 0.51 to fixed-function world rendering and it does
# NOT modify the runtime fragment-flattening resource patch already tested on
# the TSP.
#
# Defaults match the existing OpenMW 0.51 TSP build tree:
#   source:  /root/openmw-0.51-tsp-src
#   build:   /root/openmw-0.51-tsp-build
#   package: /root/openmw-0.51-tsp-package
#
# Optional positional arguments:
#   1: source directory
#   2: build directory
#   3: package directory
#   4: standalone output binary
#
# Optional environment variables:
#   OPENMW_JOBS=<count>   build parallelism
#   OPENMW_PATCH_ONLY=1   patch + verify source, do not compile
#   OPENMW_NO_STRIP=1     leave deployment copies unstripped

SOURCE_DIR="${1:-/root/openmw-0.51-tsp-src}"
BUILD_DIR="${2:-/root/openmw-0.51-tsp-build}"
PACKAGE_DIR="${3:-/root/openmw-0.51-tsp-package}"
OUTPUT_BINARY="${4:-/root/openmw-0.51-tsp-direct-fb-v1}"
JOBS="${OPENMW_JOBS:-$(nproc)}"
PATCH_ONLY="${OPENMW_PATCH_ONLY:-0}"
NO_STRIP="${OPENMW_NO_STRIP:-0}"

POST_CPP="$SOURCE_DIR/apps/openmw/mwrender/postprocessor.cpp"
RENDER_CPP="$SOURCE_DIR/apps/openmw/mwrender/renderingmanager.cpp"
BUILT_BINARY="$BUILD_DIR/openmw"
PACKAGE_BINARY="$PACKAGE_DIR/bin/openmw-0.51"

SCRIPT_REVISION="TSP-051-DIRECT-FRAMEBUFFER-V1-2026-08-07"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="$SOURCE_DIR/.tsp-051-source-backups/direct-framebuffer-$STAMP"

restore_on_error() {
    result=$?
    if [ "$result" -ne 0 ] && [ -d "$BACKUP_DIR" ]; then
        echo
        echo "ERROR: Direct-framebuffer patch/build failed. Restoring source files..."
        [ -f "$BACKUP_DIR/apps/openmw/mwrender/postprocessor.cpp" ] && \
            cp -f "$BACKUP_DIR/apps/openmw/mwrender/postprocessor.cpp" "$POST_CPP"
        [ -f "$BACKUP_DIR/apps/openmw/mwrender/renderingmanager.cpp" ] && \
            cp -f "$BACKUP_DIR/apps/openmw/mwrender/renderingmanager.cpp" "$RENDER_CPP"
        echo "Source restoration complete."
        echo "Backup retained at: $BACKUP_DIR"
    fi
    exit "$result"
}
trap restore_on_error ERR

require_file() {
    if [ ! -f "$1" ]; then
        echo "ERROR: Required file not found: $1"
        exit 1
    fi
}

require_file "$POST_CPP"
require_file "$RENDER_CPP"

if [ "$PATCH_ONLY" != "1" ] && [ ! -d "$BUILD_DIR" ]; then
    echo "ERROR: Build directory not found: $BUILD_DIR"
    exit 1
fi

mkdir -p "$BACKUP_DIR/apps/openmw/mwrender"
cp -f "$POST_CPP" "$BACKUP_DIR/apps/openmw/mwrender/postprocessor.cpp"
cp -f "$RENDER_CPP" "$BACKUP_DIR/apps/openmw/mwrender/renderingmanager.cpp"

echo "============================================================"
echo "OpenMW 0.51 TSP direct-framebuffer compatibility patch"
echo "Revision: $SCRIPT_REVISION"
echo "============================================================"
echo "Source:   $SOURCE_DIR"
echo "Build:    $BUILD_DIR"
echo "Package:  $PACKAGE_DIR"
echo "Backup:   $BACKUP_DIR"
echo

python3 - "$POST_CPP" "$RENDER_CPP" <<'PY_PATCH'
from pathlib import Path
import re
import sys

post_path = Path(sys.argv[1])
render_path = Path(sys.argv[2])
post = post_path.read_text(encoding="utf-8")
render = render_path.read_text(encoding="utf-8")

CONST_MARKER = "// TSP_GL4ES_DIRECT_FRAMEBUFFER_051_V1"
CTOR_MARKER = "// TSP_GL4ES_DIRECT_FRAMEBUFFER_CONSTRUCTOR_051_V1"
ENABLE_MARKER = "// TSP_GL4ES_DIRECT_FRAMEBUFFER_ENABLE_GUARD_051_V1"
DISABLE_MARKER = "// TSP_GL4ES_DIRECT_FRAMEBUFFER_DISABLE_GUARD_051_V1"
RESIZE_MARKER = "// TSP_GL4ES_DIRECT_FRAMEBUFFER_RESIZE_GUARD_051_V1"
TRAVERSE_MARKER = "// TSP_GL4ES_DIRECT_FRAMEBUFFER_TRAVERSE_GUARD_051_V1"


def replace_exact_once(text, old, new, description):
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f"{description}: expected exactly one match, found {count}")
    return text.replace(old, new, 1)


def insert_after_function_open(text, function_regex, marker, body, description):
    if marker in text:
        return text
    pattern = re.compile(function_regex, re.MULTILINE)
    matches = list(pattern.finditer(text))
    if len(matches) != 1:
        raise RuntimeError(f"{description}: expected exactly one function opening, found {len(matches)}")
    m = matches[0]
    return text[:m.end()] + "\n" + body + text[m.end():]


# ------------------------------------------------------------------
# postprocessor.cpp: restore a direct framebuffer path before any
# ping-pong canvases, FBOs, depth textures, HUD presentation cameras,
# or viewer scene-data interception are constructed.
# ------------------------------------------------------------------
if CONST_MARKER not in post:
    candidates = [
        "        constexpr float DistortionRatio = 0.25f;",
        "        constexpr float DistortionRatio = 0.25;",
        "    constexpr float DistortionRatio = 0.25f;",
        "    constexpr float DistortionRatio = 0.25;",
    ]
    chosen = next((c for c in candidates if c in post), None)
    if chosen is None:
        # Last-resort insertion inside the anonymous namespace before the
        # first PostProcessor method, without depending on exact float syntax.
        ctor_pos = post.find("PostProcessor::PostProcessor(")
        if ctor_pos < 0:
            raise RuntimeError("Could not locate PostProcessor constructor")
        namespace_close = post.rfind("}", 0, ctor_pos)
        if namespace_close < 0:
            raise RuntimeError("Could not locate insertion point for direct-FB constant")
        addition = (
            "\n        " + CONST_MARKER + "\n"
            "        constexpr bool TspGl4esDirectFramebuffer = true;\n"
        )
        post = post[:namespace_close] + addition + post[namespace_close:]
    else:
        indent = re.match(r"[ \t]*", chosen).group(0)
        replacement = (
            chosen
            + "\n"
            + indent + CONST_MARKER
            + "\n"
            + indent + "constexpr bool TspGl4esDirectFramebuffer = true;"
        )
        post = replace_exact_once(post, chosen, replacement, "direct-FB constant insertion")

if CTOR_MARKER not in post:
    anchor_re = re.compile(
        r"^(?P<indent>[ \t]*)auto& shaderManager = "
        r"mRendering\.getResourceSystem\(\)->getSceneManager\(\)->getShaderManager\(\);[ \t]*$",
        re.MULTILINE,
    )
    matches = list(anchor_re.finditer(post))
    if len(matches) != 1:
        raise RuntimeError(
            "PostProcessor constructor: could not uniquely locate shaderManager anchor; "
            f"found {len(matches)}"
        )
    m = matches[0]
    indent = m.group("indent")
    i1 = indent
    i2 = indent + "    "
    branch = (
        "\n"
        + i1 + CTOR_MARKER + "\n"
        + i1 + "// The engine already attached the real root node to the Viewer before\n"
        + i1 + "// RenderingManager is constructed.  In direct mode we intentionally do\n"
        + i1 + "// NOT replace that scene with PostProcessor, so the world and MyGUI draw\n"
        + i1 + "// straight to the default framebuffer.\n"
        + i1 + "if (TspGl4esDirectFramebuffer)\n"
        + i1 + "{\n"
        + i2 + "osg::GraphicsContext* gc = mViewer->getCamera()->getGraphicsContext();\n"
        + i2 + "osg::GLExtensions* ext = gc->getState()->get<osg::GLExtensions>();\n"
        + "\n"
        + i2 + "mWidth = gc->getTraits()->width;\n"
        + i2 + "mHeight = gc->getTraits()->height;\n"
        + i2 + "mGLSLVersion = static_cast<int>(ext->glslLanguageVersion * 100);\n"
        + i2 + "mUBO = ext->isUniformBufferObjectSupported && mGLSLVersion >= 330;\n"
        + i2 + "mStateUpdater = new Fx::StateUpdater(mUBO);\n"
        + "\n"
        + i2 + "auto directDefines = shaderManager.getGlobalDefines();\n"
        + i2 + "directDefines[\"distorionRTRatio\"] = std::to_string(DistortionRatio);\n"
        + i2 + "shaderManager.setGlobalDefines(directDefines);\n"
        + "\n"
        + i2 + "mUsePostProcessing = false;\n"
        + i2 + "mNormalsSupported = false;\n"
        + i2 + "mSamples = 0;\n"
        + "\n"
        + i2 + "mViewer->getCamera()->setRenderTargetImplementation(osg::Camera::FRAME_BUFFER);\n"
        + i2 + "mViewer->getCamera()->getGraphicsContext()->setResizedCallback(nullptr);\n"
        + i2 + "mViewer->getCamera()->setUserData(nullptr);\n"
        + "\n"
        + i2 + "Log(Debug::Info)\n"
        + i2 + "    << \"TSP GL4ES compatibility: direct framebuffer rendering enabled; \"\n"
        + i2 + "       \"PostProcessor FBO interception disabled.\";\n"
        + i2 + "return;\n"
        + i1 + "}\n"
    )
    post = post[:m.end()] + branch + post[m.end():]

# Guard methods that could otherwise touch objects intentionally not created
# by the direct-framebuffer constructor path.
post = insert_after_function_open(
    post,
    r"^[ \t]*void[ \t]+PostProcessor::enable[ \t]*\([^)]*\)[ \t]*\n[ \t]*\{",
    ENABLE_MARKER,
    "        " + ENABLE_MARKER + "\n"
    "        if (TspGl4esDirectFramebuffer)\n"
    "        {\n"
    "            mUsePostProcessing = false;\n"
    "            return;\n"
    "        }\n",
    "PostProcessor::enable guard",
)

post = insert_after_function_open(
    post,
    r"^[ \t]*void[ \t]+PostProcessor::disable[ \t]*\([^)]*\)[ \t]*\n[ \t]*\{",
    DISABLE_MARKER,
    "        " + DISABLE_MARKER + "\n"
    "        if (TspGl4esDirectFramebuffer)\n"
    "        {\n"
    "            mUsePostProcessing = false;\n"
    "            return;\n"
    "        }\n",
    "PostProcessor::disable guard",
)

post = insert_after_function_open(
    post,
    r"^[ \t]*void[ \t]+PostProcessor::resize[ \t]*\([^)]*\)[ \t]*\n[ \t]*\{",
    RESIZE_MARKER,
    "        " + RESIZE_MARKER + "\n"
    "        if (TspGl4esDirectFramebuffer)\n"
    "        {\n"
    "            mViewer->getCamera()->resize(mWidth, mHeight);\n"
    "            mRendering.updateProjectionMatrix();\n"
    "            mRendering.setScreenRes(mWidth, mHeight);\n"
    "            return;\n"
    "        }\n",
    "PostProcessor::resize guard",
)

# OSG's traverse signature changed historically, so match either `void` or
# the exact return spelling used by this source tree.
if TRAVERSE_MARKER not in post:
    traverse_re = re.compile(
        r"^(?P<indent>[ \t]*)void[ \t]+PostProcessor::traverse[ \t]*\("
        r"(?P<args>[^)]*)\)[ \t]*(?:const[ \t]*)?\n(?P=indent)\{",
        re.MULTILINE,
    )
    matches = list(traverse_re.finditer(post))
    if len(matches) != 1:
        raise RuntimeError(
            "PostProcessor::traverse guard: expected exactly one function opening, "
            f"found {len(matches)}"
        )
    m = matches[0]
    indent = m.group("indent")
    # Find the NodeVisitor argument name from the signature.  0.51 uses nv.
    args = m.group("args")
    visitor_match = re.search(r"(?:NodeVisitor|osg::NodeVisitor)[^,]*\b([A-Za-z_][A-Za-z0-9_]*)\s*$", args)
    visitor = visitor_match.group(1) if visitor_match else "nv"
    body = (
        "\n"
        + indent + "    " + TRAVERSE_MARKER + "\n"
        + indent + "    if (TspGl4esDirectFramebuffer)\n"
        + indent + "    {\n"
        + indent + "        osg::Group::traverse(" + visitor + ");\n"
        + indent + "        return;\n"
        + indent + "    }\n"
    )
    post = post[:m.end()] + body + post[m.end():]

# Verify direct-mode PostProcessor patch.
for token in (
    CONST_MARKER,
    CTOR_MARKER,
    ENABLE_MARKER,
    DISABLE_MARKER,
    RESIZE_MARKER,
    TRAVERSE_MARKER,
    "setRenderTargetImplementation(osg::Camera::FRAME_BUFFER)",
    "PostProcessor FBO interception disabled",
):
    if token not in post:
        raise RuntimeError(f"postprocessor.cpp verification failed; missing {token!r}")


# ------------------------------------------------------------------
# renderingmanager.cpp: stop reserving/binding opaque-depth resources
# and force dependent optional effects off for this diagnostic build.
# ------------------------------------------------------------------
PER_VIEW_MARKER = "// TSP_GL4ES_DISABLE_OPAQUE_DEPTH_UNIT_051_V1"
OPAQUE_MARKER = "// TSP_GL4ES_DISABLE_OPAQUE_DEPTH_051_V1"
NORMALS_MARKER = "// TSP_GL4ES_DISABLE_NORMALS_RT_DIRECT_FB_051_V1"
WEATHER_MARKER = "// TSP_GL4ES_DISABLE_WEATHER_DEPTH_OCCLUSION_051_V1"
SOFT_MARKER = "// TSP_GL4ES_DISABLE_SOFT_PARTICLES_051_V1"

if PER_VIEW_MARKER not in render:
    per_view_re = re.compile(
        r"(?P<indent>^[ \t]*)mPerViewUniformStateUpdater[ \t]*=[ \t]*"
        r"new[ \t]+SceneUtil::PerViewUniformStateUpdater\([ \t\n]*"
        r"mResourceSystem->getSceneManager\(\),[ \t\n]*"
        r"mResourceSystem->getSceneManager\(\)->getShaderManager\(\)\.reserveGlobalTextureUnits\([ \t\n]*"
        r"Shader::ShaderManager::Slot::OpaqueDepthTexture\)[ \t\n]*\);",
        re.MULTILINE,
    )
    matches = list(per_view_re.finditer(render))
    if len(matches) != 1:
        raise RuntimeError(
            "Could not uniquely locate PerViewUniformStateUpdater opaque-depth reservation; "
            f"found {len(matches)}"
        )
    m = matches[0]
    indent = m.group("indent")
    replacement = (
        indent + PER_VIEW_MARKER + "\n"
        + indent + "// A negative unit makes PerViewUniformStateUpdater skip the depth bind.\n"
        + indent + "mPerViewUniformStateUpdater =\n"
        + indent + "    new SceneUtil::PerViewUniformStateUpdater(mResourceSystem->getSceneManager(), -1);"
    )
    render = render[:m.start()] + replacement + render[m.end():]

if OPAQUE_MARKER not in render:
    opaque_re = re.compile(
        r"(?P<indent>^[ \t]*)resourceSystem->getSceneManager\(\)->setOpaqueDepthTex\([ \t\n]*"
        r"mPostProcessor->getTexture\(PostProcessor::Tex_OpaqueDepth,[ \t]*0\),[ \t\n]*"
        r"mPostProcessor->getTexture\(PostProcessor::Tex_OpaqueDepth,[ \t]*1\)\);",
        re.MULTILINE,
    )
    matches = list(opaque_re.finditer(render))
    if len(matches) != 1:
        raise RuntimeError(
            "Could not uniquely locate SceneManager opaque-depth texture assignment; "
            f"found {len(matches)}"
        )
    m = matches[0]
    indent = m.group("indent")
    replacement = (
        indent + OPAQUE_MARKER + "\n"
        + indent + "resourceSystem->getSceneManager()->setOpaqueDepthTex(nullptr, nullptr);"
    )
    render = render[:m.start()] + replacement + render[m.end():]

# V6 already forces normals RT off.  Preserve it if present; otherwise force it
# off here as an independent safety requirement for direct framebuffer mode.
if "setSupportsNormalsRT(false);" not in render:
    normals_re = re.compile(
        r"(?P<indent>^[ \t]*)resourceSystem->getSceneManager\(\)->setSupportsNormalsRT\([ \t]*"
        r"mPostProcessor->getSupportsNormalsRT\(\)[ \t]*\);",
        re.MULTILINE,
    )
    matches = list(normals_re.finditer(render))
    if len(matches) != 1:
        raise RuntimeError(
            "Could not locate stock SceneManager normals-RT assignment and no prior false override exists"
        )
    m = matches[0]
    indent = m.group("indent")
    replacement = (
        indent + NORMALS_MARKER + "\n"
        + indent + "resourceSystem->getSceneManager()->setSupportsNormalsRT(false);"
    )
    render = render[:m.start()] + replacement + render[m.end():]

if WEATHER_MARKER not in render:
    weather_re = re.compile(
        r"(?P<indent>^[ \t]*)resourceSystem->getSceneManager\(\)->setWeatherParticleOcclusion\([ \t]*"
        r"Settings::shaders\(\)\.mWeatherParticleOcclusion[ \t]*\);",
        re.MULTILINE,
    )
    matches = list(weather_re.finditer(render))
    if len(matches) == 1:
        m = matches[0]
        indent = m.group("indent")
        replacement = (
            indent + WEATHER_MARKER + "\n"
            + indent + "resourceSystem->getSceneManager()->setWeatherParticleOcclusion(false);"
        )
        render = render[:m.start()] + replacement + render[m.end():]
    elif len(matches) == 0 and "setWeatherParticleOcclusion(false);" in render:
        pass
    else:
        raise RuntimeError(
            "Could not uniquely locate weather-particle occlusion assignment; "
            f"found {len(matches)}"
        )

if SOFT_MARKER not in render:
    soft_re = re.compile(
        r"(?P<indent>^[ \t]*)NifOsg::Loader::setSoftEffectEnabled\([ \t]*"
        r"Settings::shaders\(\)\.mSoftParticles[ \t]*\);",
        re.MULTILINE,
    )
    matches = list(soft_re.finditer(render))
    if len(matches) == 1:
        m = matches[0]
        indent = m.group("indent")
        replacement = (
            indent + SOFT_MARKER + "\n"
            + indent + "NifOsg::Loader::setSoftEffectEnabled(false);"
        )
        render = render[:m.start()] + replacement + render[m.end():]
    elif len(matches) == 0 and "NifOsg::Loader::setSoftEffectEnabled(false);" in render:
        pass
    else:
        raise RuntimeError(
            "Could not uniquely locate soft-particle assignment; "
            f"found {len(matches)}"
        )

for token in (
    PER_VIEW_MARKER,
    OPAQUE_MARKER,
    "new SceneUtil::PerViewUniformStateUpdater(mResourceSystem->getSceneManager(), -1)",
    "setOpaqueDepthTex(nullptr, nullptr);",
    "setSupportsNormalsRT(false);",
    "setWeatherParticleOcclusion(false);",
    "NifOsg::Loader::setSoftEffectEnabled(false);",
):
    if token not in render:
        raise RuntimeError(f"renderingmanager.cpp verification failed; missing {token!r}")

# The old runtime reservation must be gone from this source path.
if re.search(
    r"reserveGlobalTextureUnits\([ \t\n]*Shader::ShaderManager::Slot::OpaqueDepthTexture",
    render,
):
    raise RuntimeError("OpaqueDepthTexture global texture-unit reservation still remains")

# Transactional writes: create both temporary files first, then replace originals.
def write_temp(path: Path, text: str) -> Path:
    temp = path.with_name(path.name + ".tsp-direct-fb.tmp")
    temp.write_text(text, encoding="utf-8", newline="\n")
    return temp

post_tmp = write_temp(post_path, post)
render_tmp = write_temp(render_path, render)
post_tmp.replace(post_path)
render_tmp.replace(render_path)

print("Patched and verified:")
print(post_path)
print(render_path)
PY_PATCH

echo
echo "Source verification markers:"
grep -n \
    -e 'TSP_GL4ES_DIRECT_FRAMEBUFFER' \
    -e 'TSP_GL4ES_DISABLE_OPAQUE_DEPTH' \
    -e 'TSP_GL4ES_DISABLE_WEATHER_DEPTH_OCCLUSION' \
    -e 'TSP_GL4ES_DISABLE_SOFT_PARTICLES' \
    "$POST_CPP" "$RENDER_CPP"

echo
echo "Verifying opaque-depth texture-unit reservation is absent..."
if grep -n -E \
    'reserveGlobalTextureUnits[[:space:]]*\([[:space:]]*Shader::ShaderManager::Slot::OpaqueDepthTexture' \
    "$RENDER_CPP"; then
    echo "ERROR: Opaque-depth texture-unit reservation still exists."
    exit 1
else
    echo "OK: no OpaqueDepthTexture global texture-unit reservation remains."
fi

if [ "$PATCH_ONLY" = "1" ]; then
    trap - ERR
    echo
    echo "PATCH_ONLY=1: source patch completed; build skipped."
    echo "Backup: $BACKUP_DIR"
    exit 0
fi

echo
echo "Incrementally rebuilding OpenMW 0.51..."
cmake --build "$BUILD_DIR" --target openmw --parallel "$JOBS"

if [ ! -x "$BUILT_BINARY" ]; then
    echo "ERROR: Build completed, but executable was not found:"
    echo "  $BUILT_BINARY"
    exit 1
fi

mkdir -p "$(dirname "$OUTPUT_BINARY")" "$(dirname "$PACKAGE_BINARY")"
[ ! -e "$OUTPUT_BINARY" ] || cp -f "$OUTPUT_BINARY" "$OUTPUT_BINARY.before-$STAMP"
[ ! -e "$PACKAGE_BINARY" ] || cp -f "$PACKAGE_BINARY" "$PACKAGE_BINARY.before-direct-fb-$STAMP"

cp -f "$BUILT_BINARY" "$OUTPUT_BINARY"
cp -f "$BUILT_BINARY" "$PACKAGE_BINARY"
chmod +x "$OUTPUT_BINARY" "$PACKAGE_BINARY"

# At this point source patching, compilation, and deployment copies succeeded.
# Do not restore the source on a non-critical strip/version-print issue below.
trap - ERR

if [ "$NO_STRIP" != "1" ]; then
    STRIP_TOOL=""
    if command -v aarch64-linux-gnu-strip >/dev/null 2>&1; then
        STRIP_TOOL="$(command -v aarch64-linux-gnu-strip)"
    elif command -v strip >/dev/null 2>&1; then
        STRIP_TOOL="$(command -v strip)"
    fi
    if [ -n "$STRIP_TOOL" ]; then
        "$STRIP_TOOL" --strip-unneeded "$OUTPUT_BINARY" || true
        "$STRIP_TOOL" --strip-unneeded "$PACKAGE_BINARY" || true
    fi
fi

echo
echo "Verifying binaries..."
file "$BUILT_BINARY"
file "$OUTPUT_BINARY"
file "$PACKAGE_BINARY"
"$BUILT_BINARY" --version || true

echo
echo "============================================================"
echo "OpenMW 0.51 TSP DIRECT FRAMEBUFFER rebuild completed"
echo "============================================================"
echo "Standalone test binary: $OUTPUT_BINARY"
echo "Packaged OpenMW:         $PACKAGE_BINARY"
echo "Source backup:           $BACKUP_DIR"
echo
echo "Expected TSP log evidence on the next run:"
echo "  SHOULD appear:"
echo "    TSP GL4ES compatibility: direct framebuffer rendering enabled"
echo "  SHOULD NOT appear:"
echo "    Reserving texture unit for opaque depth texture"
echo "    lib/core/fragment.glsl ... Missing main()"
echo
echo "Keep the already-tested runtime fragment-flattening shader patch on the TSP."
echo "The launcher can remain at Post Processing=false and antialiasing=0."
echo
