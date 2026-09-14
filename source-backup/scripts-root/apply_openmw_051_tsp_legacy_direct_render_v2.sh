#!/bin/bash
set -Eeuo pipefail

# OpenMW 0.51 / TrimUI Smart Pro legacy direct-render compatibility patch v2.
#
# This is intentionally an INCREMENTAL source patch. It does NOT rerun CMake.
# It reuses the already-configured /root/openmw-0.51-tsp-build Ninja tree.
#
# Why this exists:
#   OpenMW 0.49+ moved the main scene to an FBO-only presentation path.
#   The TSP's old GL4ES/GLES2 stack can run the engine and UI but does not
#   reliably populate/present that main scene FBO. OpenMW 0.48 had a supported
#   direct-framebuffer fallback when postprocessing/depth effects were unused.
#
# This patch restores that style of fallback for this dedicated TSP build and,
# crucially, also restores the old safe first-person depth-clear fallback.
# The latter is what the previous experimental direct-FB patch was missing and
# is the likely reason it segfaulted immediately after entering first person.
#
# Existing shader fixes are NOT removed:
#   - fragment helper flattening on the TSP remains a runtime resource patch
#   - GL4ES compatibility shader edits remain untouched in the source/package
#
# Files changed:
#   apps/openmw/mwrender/postprocessor.cpp
#   apps/openmw/mwrender/renderingmanager.cpp
#   apps/openmw/mwrender/npcanimation.cpp

SOURCE_DIR="${1:-/root/openmw-0.51-tsp-src}"
BUILD_DIR="${2:-/root/openmw-0.51-tsp-build}"
PACKAGE_DIR="${3:-/root/openmw-0.51-tsp-package}"
OUTPUT_BINARY="${4:-/root/openmw-0.51-tsp-legacy-direct-render-v2}"
JOBS="${OPENMW_JOBS:-$(nproc)}"

POST_CPP="$SOURCE_DIR/apps/openmw/mwrender/postprocessor.cpp"
RENDER_CPP="$SOURCE_DIR/apps/openmw/mwrender/renderingmanager.cpp"
NPC_CPP="$SOURCE_DIR/apps/openmw/mwrender/npcanimation.cpp"
BUILT_BINARY="$BUILD_DIR/openmw"
PACKAGE_BINARY="$PACKAGE_DIR/bin/openmw-0.51"

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="$SOURCE_DIR/.tsp-051-source-backups/legacy-direct-render-v2-$STAMP"
SCRIPT_REVISION="TSP-051-LEGACY-DIRECT-RENDER-V2-2026-08-07"

restore_on_error() {
    result=$?
    if [ "$result" -ne 0 ] && [ -d "$BACKUP_DIR" ]; then
        echo
        echo "ERROR: legacy direct-render patch/build failed. Restoring pre-patch source..."
        for rel in \
            apps/openmw/mwrender/postprocessor.cpp \
            apps/openmw/mwrender/renderingmanager.cpp \
            apps/openmw/mwrender/npcanimation.cpp
        do
            if [ -f "$BACKUP_DIR/$rel" ]; then
                cp -f "$BACKUP_DIR/$rel" "$SOURCE_DIR/$rel"
            fi
        done
        echo "Source restoration complete."
        echo "Backup retained at: $BACKUP_DIR"
    fi
    exit "$result"
}
trap restore_on_error ERR

echo "============================================================"
echo "OpenMW 0.51 TSP legacy direct-render compatibility patch"
echo "Revision: $SCRIPT_REVISION"
echo "============================================================"
echo "Source:  $SOURCE_DIR"
echo "Build:   $BUILD_DIR"
echo "Package: $PACKAGE_DIR"
echo "Backup:  $BACKUP_DIR"
echo "============================================================"

for path in "$POST_CPP" "$RENDER_CPP" "$NPC_CPP"; do
    if [ ! -f "$path" ]; then
        echo "ERROR: required source file is missing: $path"
        exit 1
    fi
done

if [ ! -f "$BUILD_DIR/build.ninja" ] || [ ! -f "$BUILD_DIR/CMakeCache.txt" ]; then
    echo "ERROR: the existing configured Ninja build tree is missing."
    echo "This script intentionally refuses to rerun CMake."
    exit 1
fi

mkdir -p \
    "$BACKUP_DIR/apps/openmw/mwrender" \
    "$(dirname "$PACKAGE_BINARY")"

cp -f "$POST_CPP" "$BACKUP_DIR/apps/openmw/mwrender/postprocessor.cpp"
cp -f "$RENDER_CPP" "$BACKUP_DIR/apps/openmw/mwrender/renderingmanager.cpp"
cp -f "$NPC_CPP" "$BACKUP_DIR/apps/openmw/mwrender/npcanimation.cpp"

echo
echo "Applying source changes..."

python3 - "$POST_CPP" "$RENDER_CPP" "$NPC_CPP" <<'PY_PATCH'
from pathlib import Path
import os
import re
import sys

post_path, render_path, npc_path = map(Path, sys.argv[1:])
post = post_path.read_text(encoding="utf-8")
render = render_path.read_text(encoding="utf-8")
npc = npc_path.read_text(encoding="utf-8")

CONST_MARKER = "// TSP_LEGACY_DIRECT_RENDER_051_V2"
CTOR_MARKER = "// TSP_LEGACY_DIRECT_RENDER_CONSTRUCTOR_051_V2"
ENABLE_MARKER = "// TSP_LEGACY_DIRECT_RENDER_ENABLE_GUARD_051_V2"
DISABLE_MARKER = "// TSP_LEGACY_DIRECT_RENDER_DISABLE_GUARD_051_V2"
RESIZE_MARKER = "// TSP_LEGACY_DIRECT_RENDER_RESIZE_GUARD_051_V2"
TRAVERSE_MARKER = "// TSP_LEGACY_DIRECT_RENDER_TRAVERSE_GUARD_051_V2"
NPC_MARKER = "// TSP_LEGACY_DIRECT_RENDER_FIRSTPERSON_FALLBACK_051_V2"
DEPTH_MARKER = "// TSP_LEGACY_DIRECT_RENDER_NO_OPAQUE_DEPTH_051_V2"
NORMALS_MARKER = "// TSP_LEGACY_DIRECT_RENDER_NO_NORMALS_RT_051_V2"
WEATHER_MARKER = "// TSP_LEGACY_DIRECT_RENDER_NO_WEATHER_DEPTH_051_V2"
SOFT_MARKER = "// TSP_LEGACY_DIRECT_RENDER_NO_SOFT_PARTICLES_051_V2"


def replace_once(text, old, new, label):
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f"{label}: expected exactly one occurrence, found {count}")
    return text.replace(old, new, 1)


def insert_after_function_open(text, regex, marker, body, label):
    if marker in text:
        return text
    matches = list(re.finditer(regex, text, flags=re.MULTILINE))
    if len(matches) != 1:
        raise RuntimeError(f"{label}: expected exactly one function opening, found {len(matches)}")
    m = matches[0]
    return text[:m.end()] + "\n" + body + text[m.end():]


def transactional_write(items):
    temps = []
    try:
        for path, text in items:
            tmp = Path(str(path) + ".tsp-legacy-direct-v2.tmp")
            with tmp.open("w", encoding="utf-8", newline="\n") as handle:
                handle.write(text)
            temps.append((path, tmp))
        for path, tmp in temps:
            os.replace(str(tmp), str(path))
    finally:
        for _, tmp in temps:
            try:
                tmp.unlink()
            except FileNotFoundError:
                pass


# =====================================================================
# 1. PostProcessor: restore the old direct-framebuffer concept.
# =====================================================================
# Keep this as a compile-time TSP-only constant. This avoids depending on
# GL4ES extension detection, which the current launcher intentionally disables
# with LIBGL_NOTEST=1 to avoid its pre-window EGL probe problem.
if CONST_MARKER not in post:
    pattern = re.compile(r"(?P<indent>^[ \t]*)constexpr float DistortionRatio = 0\.25f?;", re.MULTILINE)
    matches = list(pattern.finditer(post))
    if len(matches) != 1:
        raise RuntimeError(f"PostProcessor constant anchor: expected one DistortionRatio, found {len(matches)}")
    m = matches[0]
    i = m.group("indent")
    addition = (
        m.group(0)
        + "\n" + i + CONST_MARKER
        + "\n" + i + "constexpr bool TspLegacyDirectRender = true;"
    )
    post = post[:m.start()] + addition + post[m.end():]

if CTOR_MARKER not in post:
    anchor_re = re.compile(
        r"(?P<indent>^[ \t]*)auto& shaderManager = "
        r"mRendering\.getResourceSystem\(\)->getSceneManager\(\)->getShaderManager\(\);[ \t]*$",
        re.MULTILINE,
    )
    matches = list(anchor_re.finditer(post))
    if len(matches) != 1:
        raise RuntimeError(f"PostProcessor constructor anchor: expected one, found {len(matches)}")
    m = matches[0]
    i1 = m.group("indent")
    i2 = i1 + "    "
    branch = (
        "\n"
        + i1 + CTOR_MARKER + "\n"
        + i1 + "// OpenMW 0.48 supported leaving the Viewer on its original scene root\n"
        + i1 + "// when no FBO-only depth/post effects were required. Recreate that\n"
        + i1 + "// behavior for the TSP GL4ES/GLES2 compatibility build.\n"
        + i1 + "if (TspLegacyDirectRender)\n"
        + i1 + "{\n"
        + i2 + "osg::GraphicsContext* gc = mViewer->getCamera()->getGraphicsContext();\n"
        + i2 + "osg::GLExtensions* ext = gc->getState()->get<osg::GLExtensions>();\n"
        + i2 + "mWidth = gc->getTraits()->width;\n"
        + i2 + "mHeight = gc->getTraits()->height;\n"
        + i2 + "mGLSLVersion = static_cast<int>(ext->glslLanguageVersion * 100);\n"
        + i2 + "mUBO = ext->isUniformBufferObjectSupported && mGLSLVersion >= 330;\n"
        + i2 + "mStateUpdater = new Fx::StateUpdater(mUBO);\n"
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
        + i2 + "    << \"TSP GL4ES: legacy direct framebuffer path active; main scene FBO/ping-pong presentation bypassed.\";\n"
        + i2 + "return;\n"
        + i1 + "}\n"
    )
    post = post[:m.end()] + branch + post[m.end():]

post = insert_after_function_open(
    post,
    r"^[ \t]*void[ \t]+PostProcessor::enable[ \t]*\([^)]*\)[ \t]*\n[ \t]*\{",
    ENABLE_MARKER,
    "        " + ENABLE_MARKER + "\n"
    "        if (TspLegacyDirectRender)\n"
    "        {\n"
    "            mUsePostProcessing = false;\n"
    "            return;\n"
    "        }\n",
    "PostProcessor::enable",
)

post = insert_after_function_open(
    post,
    r"^[ \t]*void[ \t]+PostProcessor::disable[ \t]*\([^)]*\)[ \t]*\n[ \t]*\{",
    DISABLE_MARKER,
    "        " + DISABLE_MARKER + "\n"
    "        if (TspLegacyDirectRender)\n"
    "        {\n"
    "            mUsePostProcessing = false;\n"
    "            return;\n"
    "        }\n",
    "PostProcessor::disable",
)

post = insert_after_function_open(
    post,
    r"^[ \t]*void[ \t]+PostProcessor::resize[ \t]*\([^)]*\)[ \t]*\n[ \t]*\{",
    RESIZE_MARKER,
    "        " + RESIZE_MARKER + "\n"
    "        if (TspLegacyDirectRender)\n"
    "        {\n"
    "            osg::GraphicsContext* gc = mViewer->getCamera()->getGraphicsContext();\n"
    "            mWidth = gc->getTraits()->width;\n"
    "            mHeight = gc->getTraits()->height;\n"
    "            mViewer->getCamera()->resize(mWidth, mHeight);\n"
    "            mRendering.updateProjectionMatrix();\n"
    "            mRendering.setScreenRes(mWidth, mHeight);\n"
    "            return;\n"
    "        }\n",
    "PostProcessor::resize",
)

post = insert_after_function_open(
    post,
    r"^[ \t]*void[ \t]+PostProcessor::traverse[ \t]*\([^)]*\)[ \t]*\n[ \t]*\{",
    TRAVERSE_MARKER,
    "        " + TRAVERSE_MARKER + "\n"
    "        if (TspLegacyDirectRender)\n"
    "        {\n"
    "            osg::Group::traverse(nv);\n"
    "            return;\n"
    "        }\n",
    "PostProcessor::traverse",
)


# =====================================================================
# 2. First-person rendering: restore the old non-FBO fallback.
# =====================================================================
# OpenMW 0.51 assumes currentCamera->getUserData() is always a PostProcessor.
# That became true after FBO-only rendering landed, but is false in the legacy
# direct path. 0.48 used a dynamic_cast and ordinary depth clear fallback.
if NPC_MARKER not in npc:
    old_cast = (
        "            PostProcessor* postProcessor = "
        "static_cast<PostProcessor*>(renderInfo.getCurrentCamera()->getUserData());"
    )
    new_cast = (
        "            PostProcessor* postProcessor = "
        "dynamic_cast<PostProcessor*>(renderInfo.getCurrentCamera()->getUserData());"
    )
    if old_cast in npc:
        npc = npc.replace(old_cast, new_cast, 1)
    elif new_cast not in npc:
        raise RuntimeError("NpcAnimation: PostProcessor cast was not found")

    frame_anchor = (
        "            unsigned int frameId = state->getFrameStamp()->getFrameNumber() % 2;"
    )
    if frame_anchor not in npc:
        raise RuntimeError("NpcAnimation: first-person frameId anchor was not found")

    fallback = (
        frame_anchor
        + "\n\n"
        + "            " + NPC_MARKER + "\n"
        + "            // This is the pre-FBO-only OpenMW fallback: when the main camera\n"
        + "            // is rendering directly, clear normal depth/stencil and draw the\n"
        + "            // first-person bin without dereferencing PostProcessor FBOs.\n"
        + "            if (!postProcessor || !postProcessor->getFbo(PostProcessor::FBO_FirstPerson, frameId))\n"
        + "            {\n"
        + "                glClear(GL_DEPTH_BUFFER_BIT | GL_STENCIL_BUFFER_BIT);\n"
        + "                bin->drawImplementation(renderInfo, previous);\n"
        + "                state->checkGLErrors(\"after DepthClearCallback::drawImplementation direct fallback\");\n"
        + "                return;\n"
        + "            }"
    )
    npc = npc.replace(frame_anchor, fallback, 1)


# =====================================================================
# 3. Disable optional features that require the unavailable scene depth/FBO.
# =====================================================================
# SceneManager must not advertise an unrendered depth texture in direct mode.
if DEPTH_MARKER not in render:
    depth_re = re.compile(
        r"(?P<indent>^[ \t]*)resourceSystem->getSceneManager\(\)->setOpaqueDepthTex\(.*?\);",
        re.MULTILINE | re.DOTALL,
    )
    matches = list(depth_re.finditer(render))
    if len(matches) != 1:
        raise RuntimeError(f"RenderingManager opaque-depth assignment: expected one, found {len(matches)}")
    m = matches[0]
    i = m.group("indent")
    replacement = (
        i + DEPTH_MARKER + "\n"
        + i + "// Direct framebuffer mode has no scene-depth texture for shader sampling.\n"
        + i + "resourceSystem->getSceneManager()->setOpaqueDepthTex(nullptr, nullptr);"
    )
    render = render[:m.start()] + replacement + render[m.end():]

# Normals MRT already has a TSP patch in the current build. Normalize to false.
if "setSupportsNormalsRT(false);" not in render:
    normals_re = re.compile(
        r"(?P<indent>^[ \t]*)resourceSystem->getSceneManager\(\)->setSupportsNormalsRT\(\s*"
        r"mPostProcessor->getSupportsNormalsRT\(\)\s*\);",
        re.MULTILINE,
    )
    matches = list(normals_re.finditer(render))
    if len(matches) != 1:
        raise RuntimeError(f"RenderingManager normals RT assignment: expected one, found {len(matches)}")
    m = matches[0]
    i = m.group("indent")
    render = render[:m.start()] + i + "resourceSystem->getSceneManager()->setSupportsNormalsRT(false);" + render[m.end():]
if NORMALS_MARKER not in render:
    target = "        resourceSystem->getSceneManager()->setSupportsNormalsRT(false);"
    if target not in render:
        raise RuntimeError("RenderingManager: normalized setSupportsNormalsRT(false) line not found")
    render = render.replace(target, "        " + NORMALS_MARKER + "\n" + target, 1)

if WEATHER_MARKER not in render:
    stock = "        resourceSystem->getSceneManager()->setWeatherParticleOcclusion(Settings::shaders().mWeatherParticleOcclusion);"
    forced = "        resourceSystem->getSceneManager()->setWeatherParticleOcclusion(false);"
    if stock in render:
        render = render.replace(stock, "        " + WEATHER_MARKER + "\n" + forced, 1)
    elif forced in render:
        render = render.replace(forced, "        " + WEATHER_MARKER + "\n" + forced, 1)
    else:
        raise RuntimeError("RenderingManager: weather particle occlusion assignment not found")

if SOFT_MARKER not in render:
    stock = "        NifOsg::Loader::setSoftEffectEnabled(Settings::shaders().mSoftParticles);"
    forced = "        NifOsg::Loader::setSoftEffectEnabled(false);"
    if stock in render:
        render = render.replace(stock, "        " + SOFT_MARKER + "\n" + forced, 1)
    elif forced in render:
        render = render.replace(forced, "        " + SOFT_MARKER + "\n" + forced, 1)
    else:
        raise RuntimeError("RenderingManager: soft-particle assignment not found")


# =====================================================================
# Final verification before any file is replaced.
# =====================================================================
required_post = (
    CONST_MARKER,
    CTOR_MARKER,
    ENABLE_MARKER,
    DISABLE_MARKER,
    RESIZE_MARKER,
    TRAVERSE_MARKER,
    "setRenderTargetImplementation(osg::Camera::FRAME_BUFFER);",
    "legacy direct framebuffer path active",
    "mStateUpdater = new Fx::StateUpdater(mUBO);",
)
for token in required_post:
    if token not in post:
        raise RuntimeError(f"postprocessor.cpp verification failed: missing {token}")

required_npc = (
    NPC_MARKER,
    "dynamic_cast<PostProcessor*>",
    "if (!postProcessor || !postProcessor->getFbo(PostProcessor::FBO_FirstPerson, frameId))",
    "glClear(GL_DEPTH_BUFFER_BIT | GL_STENCIL_BUFFER_BIT);",
)
for token in required_npc:
    if token not in npc:
        raise RuntimeError(f"npcanimation.cpp verification failed: missing {token}")

required_render = (
    DEPTH_MARKER,
    NORMALS_MARKER,
    WEATHER_MARKER,
    SOFT_MARKER,
    "setOpaqueDepthTex(nullptr, nullptr);",
    "setSupportsNormalsRT(false);",
    "setWeatherParticleOcclusion(false);",
    "NifOsg::Loader::setSoftEffectEnabled(false);",
)
for token in required_render:
    if token not in render:
        raise RuntimeError(f"renderingmanager.cpp verification failed: missing {token}")

# The old unsafe first-person static cast must be gone.
if "static_cast<PostProcessor*>(renderInfo.getCurrentCamera()->getUserData())" in npc:
    raise RuntimeError("NpcAnimation verification failed: unsafe PostProcessor static_cast remains")

transactional_write(((post_path, post), (render_path, render), (npc_path, npc)))

print("Patched and verified:")
print(post_path)
print(render_path)
print(npc_path)
PY_PATCH

echo
echo "Source markers:"
grep -n \
    -e 'TSP_LEGACY_DIRECT_RENDER' \
    "$POST_CPP" "$RENDER_CPP" "$NPC_CPP"

# Keep the already-working COLLADA linker compatibility available without
# touching the CMake cache. The successful previous build already persisted
# its -L path; these aliases are only recreated if needed.
if ninja -C "$BUILD_DIR" -t commands openmw 2>/dev/null | grep -F ' -o openmw ' | tail -1 | grep -Fq -- '-lcollada-dom2.5-dp'; then
    COLLADA_REAL=""
    for candidate in \
        /usr/lib/libcollada-dom2.4-dp.so \
        /usr/lib/aarch64-linux-gnu/libcollada-dom2.4-dp.so \
        /usr/local/lib/libcollada-dom2.4-dp.so
    do
        if [ -e "$candidate" ]; then
            COLLADA_REAL="$(readlink -f "$candidate")"
            break
        fi
    done
    if [ -z "$COLLADA_REAL" ]; then
        echo "ERROR: existing build still requests collada-dom2.5-dp, but the real 2.4 library was not found."
        exit 1
    fi
    mkdir -p /root/openmw-0.51-tsp-link-compat
    ln -sfn "$COLLADA_REAL" /root/openmw-0.51-tsp-link-compat/libcollada-dom2.5-dp.so
    ln -sfn "$COLLADA_REAL" /usr/lib/libcollada-dom2.5-dp.so
fi

echo
echo "Incremental build only -- CMake configure is intentionally skipped."
echo "Changed targets should compile as a few objects plus the final link."
cmake --build "$BUILD_DIR" --target openmw --parallel "$JOBS"

if [ ! -x "$BUILT_BINARY" ]; then
    echo "ERROR: build completed but OpenMW executable is missing: $BUILT_BINARY"
    exit 1
fi

echo
echo "Packaging rebuilt binary..."
[ ! -e "$OUTPUT_BINARY" ] || cp -f "$OUTPUT_BINARY" "$OUTPUT_BINARY.before-$STAMP"
[ ! -e "$PACKAGE_BINARY" ] || cp -f "$PACKAGE_BINARY" "$PACKAGE_BINARY.before-legacy-direct-v2-$STAMP"
cp -f "$BUILT_BINARY" "$OUTPUT_BINARY"
cp -f "$BUILT_BINARY" "$PACKAGE_BINARY"
chmod +x "$OUTPUT_BINARY" "$PACKAGE_BINARY"

# Verify we did not accidentally create a runtime dependency on the build-only
# COLLADA alias.
if readelf -d "$PACKAGE_BINARY" 2>/dev/null | grep -q 'libcollada-dom2.5-dp'; then
    echo "ERROR: packaged binary retained libcollada-dom2.5-dp as a runtime dependency."
    exit 1
fi

trap - ERR

echo
echo "============================================================"
echo "SUCCESS: OpenMW 0.51 legacy direct-render v2 build completed"
echo "============================================================"
echo "Standalone binary: $OUTPUT_BINARY"
echo "Packaged binary:   $PACKAGE_BINARY"
echo "Source backup:     $BACKUP_DIR"
echo
echo "Expected runtime log marker:"
echo "  TSP GL4ES: legacy direct framebuffer path active; main scene FBO/ping-pong presentation bypassed."
echo
echo "Keep the existing TSP runtime shader fixes, especially fragment_inline.glsl."
echo "Do NOT unset LIBGL_NOTEST for this test."
echo "============================================================"
