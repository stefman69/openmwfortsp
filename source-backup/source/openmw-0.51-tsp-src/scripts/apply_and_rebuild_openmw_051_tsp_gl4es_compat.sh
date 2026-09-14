#!/bin/bash
set -Eeuo pipefail

# OpenMW 0.51 / TrimUI Smart Pro GL4ES compatibility rebuild.
#
# Purpose:
#   1. Remove/undo the experimental direct-framebuffer bypass that caused a
#      new-game crash by restoring the newest verified pre-direct-FB source
#      backup made by that patch.
#   2. Apply the narrower GL4ES depth-path workaround used by later OpenMW
#      GL4ES work: keep PostProcessor fully initialized, use the regular scene
#      depth texture instead of the copied opaque-depth texture, and avoid the
#      GL4ES-hostile depth blit / opaque-depth postpass target switch.
#   3. Preserve the existing TSP normals-MRT workaround (glColorMaski is not
#      available through this GL4ES/GLES2 stack).
#   4. Patch the OpenMW compatibility shader sources for the known GL4ES
#      uniform-initializer white-screen/compiler issue.
#
# This script intentionally does NOT touch input/controller/cursor code,
# water.cpp, waterutil.cpp, launcher files, saves, or Morrowind data.

SOURCE_DIR="${1:-/root/openmw-0.51-tsp-src}"
BUILD_DIR="${2:-/root/openmw-0.51-tsp-build}"
PACKAGE_DIR="${3:-/root/openmw-0.51-tsp-package}"
OUTPUT_BINARY="${4:-/root/openmw-0.51-tsp-gl4es-compat}"
JOBS="${OPENMW_JOBS:-$(nproc)}"
NO_STRIP="${OPENMW_NO_STRIP:-0}"

POST_CPP="$SOURCE_DIR/apps/openmw/mwrender/postprocessor.cpp"
RENDER_CPP="$SOURCE_DIR/apps/openmw/mwrender/renderingmanager.cpp"
TRANSPARENT_CPP="$SOURCE_DIR/apps/openmw/mwrender/transparentpass.cpp"
NPC_CPP="$SOURCE_DIR/apps/openmw/mwrender/npcanimation.cpp"
FULLSCREEN_VERT="$SOURCE_DIR/files/shaders/compatibility/fullscreen_tri.vert"
SHADOW_VERT="$SOURCE_DIR/files/shaders/compatibility/shadowcasting.vert"
FOG_GLSL="$SOURCE_DIR/files/shaders/compatibility/fog.glsl"

BUILT_BINARY="$BUILD_DIR/openmw"
PACKAGE_BINARY="$PACKAGE_DIR/bin/openmw-0.51"
PACKAGE_SHADER_DIR="$PACKAGE_DIR/resources/shaders/compatibility"

STAMP="$(date +%Y%m%d-%H%M%S)"
CURRENT_BACKUP="$SOURCE_DIR/.tsp-051-source-backups/gl4es-compat-current-$STAMP"
BASELINE_BACKUP="$SOURCE_DIR/.tsp-051-source-backups/gl4es-compat-baseline-$STAMP"
SCRIPT_REVISION="TSP-051-GL4ES-COMPAT-2026-08-07"

TARGET_FILES=(
    "$POST_CPP"
    "$RENDER_CPP"
    "$TRANSPARENT_CPP"
    "$NPC_CPP"
    "$FULLSCREEN_VERT"
    "$SHADOW_VERT"
    "$FOG_GLSL"
)

restore_baseline_on_error() {
    result=$?
    if [ "$result" -ne 0 ] && [ -d "$BASELINE_BACKUP" ]; then
        echo
        echo "ERROR: GL4ES compatibility patch/build failed. Restoring the verified baseline source..."
        for rel in \
            apps/openmw/mwrender/postprocessor.cpp \
            apps/openmw/mwrender/renderingmanager.cpp \
            apps/openmw/mwrender/transparentpass.cpp \
            apps/openmw/mwrender/npcanimation.cpp \
            files/shaders/compatibility/fullscreen_tri.vert \
            files/shaders/compatibility/shadowcasting.vert \
            files/shaders/compatibility/fog.glsl
        do
            if [ -f "$BASELINE_BACKUP/$rel" ]; then
                mkdir -p "$(dirname "$SOURCE_DIR/$rel")"
                cp -f "$BASELINE_BACKUP/$rel" "$SOURCE_DIR/$rel"
            fi
        done
        echo "Baseline source restoration complete."
        echo "Failed-attempt backup retained at: $CURRENT_BACKUP"
        echo "Baseline backup retained at:       $BASELINE_BACKUP"
    fi
    exit "$result"
}
trap restore_baseline_on_error ERR

echo "============================================================"
echo "OpenMW 0.51 TSP GL4ES compatibility rebuild"
echo "Revision: $SCRIPT_REVISION"
echo "============================================================"
echo "Source:   $SOURCE_DIR"
echo "Build:    $BUILD_DIR"
echo "Package:  $PACKAGE_DIR"
echo

for path in "${TARGET_FILES[@]}"; do
    if [ ! -f "$path" ]; then
        echo "ERROR: Required source/resource file not found:"
        echo "  $path"
        exit 1
    fi
done

if [ ! -d "$BUILD_DIR" ]; then
    echo "ERROR: Build directory not found: $BUILD_DIR"
    exit 1
fi

# Verify the Python APIs used by the embedded patcher before touching source.
python3 - <<'PY_PREFLIGHT'
from pathlib import Path
import os
p = Path('/tmp/openmw051_gl4es_write_preflight.tmp')
try:
    with p.open('w', encoding='utf-8', newline='\n') as h:
        h.write('ok\n')
    if p.read_text(encoding='utf-8') != 'ok\n':
        raise RuntimeError('unexpected preflight contents')
finally:
    try:
        os.unlink(p)
    except FileNotFoundError:
        pass
print('Python file-write preflight: OK')
PY_PREFLIGHT

# Save the exact current state first for forensic recovery. This may contain
# the crashy direct-framebuffer experiment and is intentionally NOT our error
# rollback target.
mkdir -p \
    "$CURRENT_BACKUP/apps/openmw/mwrender" \
    "$CURRENT_BACKUP/files/shaders/compatibility"
cp -f "$POST_CPP" "$CURRENT_BACKUP/apps/openmw/mwrender/postprocessor.cpp"
cp -f "$RENDER_CPP" "$CURRENT_BACKUP/apps/openmw/mwrender/renderingmanager.cpp"
cp -f "$TRANSPARENT_CPP" "$CURRENT_BACKUP/apps/openmw/mwrender/transparentpass.cpp"
cp -f "$NPC_CPP" "$CURRENT_BACKUP/apps/openmw/mwrender/npcanimation.cpp"
cp -f "$FULLSCREEN_VERT" "$CURRENT_BACKUP/files/shaders/compatibility/fullscreen_tri.vert"
cp -f "$SHADOW_VERT" "$CURRENT_BACKUP/files/shaders/compatibility/shadowcasting.vert"
cp -f "$FOG_GLSL" "$CURRENT_BACKUP/files/shaders/compatibility/fog.glsl"

echo "Saved current source state: $CURRENT_BACKUP"

# ---------------------------------------------------------------------------
# Undo the crashy direct-framebuffer experiment if it is present.
# Every successful/failed direct-framebuffer patch created a backup before
# touching postprocessor.cpp/renderingmanager.cpp. Pick the newest backup that
# is itself free of direct-FB markers.
# ---------------------------------------------------------------------------
if grep -q 'TSP_GL4ES_DIRECT_FRAMEBUFFER' "$POST_CPP" \
    || grep -q 'TSP_GL4ES_DISABLE_OPAQUE_DEPTH_UNIT_051_V1' "$RENDER_CPP"
then
    echo
    echo "Direct-framebuffer experiment detected; locating newest clean pre-direct-FB backup..."

    BASELINE_DIR=""
    while IFS= read -r candidate; do
        [ -n "$candidate" ] || continue
        p="$candidate/apps/openmw/mwrender/postprocessor.cpp"
        r="$candidate/apps/openmw/mwrender/renderingmanager.cpp"
        if [ -f "$p" ] && [ -f "$r" ] \
            && ! grep -q 'TSP_GL4ES_DIRECT_FRAMEBUFFER' "$p" \
            && ! grep -q 'TSP_GL4ES_DISABLE_OPAQUE_DEPTH_UNIT_051_V1' "$r"
        then
            BASELINE_DIR="$candidate"
            break
        fi
    done < <(
        find "$SOURCE_DIR/.tsp-051-source-backups" -maxdepth 1 -type d \
            -name 'direct-framebuffer-*' -printf '%T@ %p\n' 2>/dev/null \
            | sort -nr | cut -d' ' -f2-
    )

    if [ -z "$BASELINE_DIR" ]; then
        echo "ERROR: The source contains the direct-framebuffer experiment,"
        echo "but no clean direct-framebuffer backup could be found."
        echo "Nothing further was modified."
        exit 1
    fi

    echo "Restoring pre-direct-FB renderer source from:"
    echo "  $BASELINE_DIR"
    cp -f "$BASELINE_DIR/apps/openmw/mwrender/postprocessor.cpp" "$POST_CPP"
    cp -f "$BASELINE_DIR/apps/openmw/mwrender/renderingmanager.cpp" "$RENDER_CPP"
fi

# We must now be back on a fully initialized PostProcessor implementation.
if grep -q 'TSP_GL4ES_DIRECT_FRAMEBUFFER' "$POST_CPP"; then
    echo "ERROR: Direct-framebuffer marker remains after baseline restoration."
    exit 1
fi
if ! grep -q 'mViewer->setSceneData(this)' "$POST_CPP"; then
    echo "ERROR: Restored PostProcessor does not contain the stock scene interception path."
    exit 1
fi

# This becomes the rollback target for every later error, so a failed new
# patch leaves the source on the last non-crashy renderer baseline.
mkdir -p \
    "$BASELINE_BACKUP/apps/openmw/mwrender" \
    "$BASELINE_BACKUP/files/shaders/compatibility"
cp -f "$POST_CPP" "$BASELINE_BACKUP/apps/openmw/mwrender/postprocessor.cpp"
cp -f "$RENDER_CPP" "$BASELINE_BACKUP/apps/openmw/mwrender/renderingmanager.cpp"
cp -f "$TRANSPARENT_CPP" "$BASELINE_BACKUP/apps/openmw/mwrender/transparentpass.cpp"
cp -f "$NPC_CPP" "$BASELINE_BACKUP/apps/openmw/mwrender/npcanimation.cpp"
cp -f "$FULLSCREEN_VERT" "$BASELINE_BACKUP/files/shaders/compatibility/fullscreen_tri.vert"
cp -f "$SHADOW_VERT" "$BASELINE_BACKUP/files/shaders/compatibility/shadowcasting.vert"
cp -f "$FOG_GLSL" "$BASELINE_BACKUP/files/shaders/compatibility/fog.glsl"
echo "Verified non-direct renderer baseline: $BASELINE_BACKUP"

echo
echo "Applying GL4ES depth-path and shader compatibility changes..."

python3 - \
    "$POST_CPP" \
    "$RENDER_CPP" \
    "$TRANSPARENT_CPP" \
    "$NPC_CPP" \
    "$FULLSCREEN_VERT" \
    "$SHADOW_VERT" \
    "$FOG_GLSL" <<'PY_PATCH'
from pathlib import Path
import os
import re
import sys

(
    post_path,
    render_path,
    transparent_path,
    npc_path,
    fullscreen_path,
    shadow_path,
    fog_path,
) = map(Path, sys.argv[1:])

post = post_path.read_text(encoding='utf-8')
render = render_path.read_text(encoding='utf-8')
transparent = transparent_path.read_text(encoding='utf-8')
npc = npc_path.read_text(encoding='utf-8')
fullscreen = fullscreen_path.read_text(encoding='utf-8')
shadow = shadow_path.read_text(encoding='utf-8')
fog = fog_path.read_text(encoding='utf-8')


def replace_once(text, old, new, label):
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f'{label}: expected exactly one stock occurrence, found {count}')
    return text.replace(old, new, 1)


def write_transactionally(items):
    temps = []
    try:
        for path, text in items:
            tmp = Path(str(path) + '.tsp-gl4es.tmp')
            with tmp.open('w', encoding='utf-8', newline='\n') as h:
                h.write(text)
            temps.append((path, tmp))
        for path, tmp in temps:
            os.replace(str(tmp), str(path))
    finally:
        for _, tmp in temps:
            try:
                tmp.unlink()
            except FileNotFoundError:
                pass


# -------------------------------------------------------------------------
# 1. PostProcessor: keep the complete FBO/postprocessor lifecycle intact,
#    but feed postprocess consumers the regular scene depth texture on GL4ES.
#    This mirrors the GL4ES workaround proposed upstream rather than deleting
#    the entire PostProcessor object graph.
# -------------------------------------------------------------------------
post_marker = '// TSP_GL4ES_USE_SCENE_DEPTH_051'
if post_marker not in post:
    old = '        mCanvases[frameId]->setTextureDepth(getTexture(Tex_OpaqueDepth, frameId));'
    new = (
        '        ' + post_marker + '\n'
        '        // GL4ES/GLES2 cannot reliably populate the copied opaque-depth target.\n'
        '        // Use the primary scene depth texture instead.\n'
        '        mCanvases[frameId]->setTextureDepth(getTexture(Tex_Depth, frameId));'
    )
    post = replace_once(post, old, new, 'PostProcessor scene-depth substitution')


# -------------------------------------------------------------------------
# 2. RenderingManager: expose Tex_Depth in the slot historically named
#    OpaqueDepthTexture. Keep the reserved texture unit; shaders/soft effects
#    expect that global slot to exist. Force normals MRT off because this
#    GL4ES/GLES2 stack lacks the indexed color-mask path (glColorMaski).
# -------------------------------------------------------------------------
render_depth_marker = '// TSP_GL4ES_SCENEMANAGER_SCENE_DEPTH_051'
if render_depth_marker not in render:
    pattern = re.compile(
        r'(?P<indent>[ \t]*)resourceSystem->getSceneManager\(\)->setOpaqueDepthTex\(\s*'
        r'mPostProcessor->getTexture\(PostProcessor::Tex_OpaqueDepth,\s*0\),\s*'
        r'mPostProcessor->getTexture\(PostProcessor::Tex_OpaqueDepth,\s*1\)\s*\);',
        flags=re.MULTILINE,
    )
    matches = list(pattern.finditer(render))
    if len(matches) != 1:
        raise RuntimeError(
            f'RenderingManager scene-depth substitution: expected one stock block, found {len(matches)}'
        )
    m = matches[0]
    i = m.group('indent')
    replacement = (
        i + render_depth_marker + '\n'
        + i + '// Supply the primary scene depth textures to the global depth slot on GL4ES.\n'
        + i + 'resourceSystem->getSceneManager()->setOpaqueDepthTex(\n'
        + i + '    mPostProcessor->getTexture(PostProcessor::Tex_Depth, 0),\n'
        + i + '    mPostProcessor->getTexture(PostProcessor::Tex_Depth, 1));'
    )
    render = render[:m.start()] + replacement + render[m.end():]

# Normalize any earlier TSP normals-RT patch and guarantee exactly one false assignment.
# We accept either stock source or the V6 source currently used by this port.
render = re.sub(
    r'(?m)^[ \t]*// TSP_GL4ES_DISABLE_NORMALS_RT[^\n]*\n(?:^[ \t]*//[^\n]*\n){0,4}',
    '',
    render,
)
stock_normals = re.compile(
    r'(?P<indent>[ \t]*)resourceSystem->getSceneManager\(\)->setSupportsNormalsRT\(\s*'
    r'mPostProcessor->getSupportsNormalsRT\(\)\s*\);'
)
false_normals = re.compile(
    r'(?P<indent>[ \t]*)resourceSystem->getSceneManager\(\)->setSupportsNormalsRT\(false\);'
)
stock_matches = list(stock_normals.finditer(render))
false_matches = list(false_normals.finditer(render))
if len(stock_matches) == 1 and len(false_matches) == 0:
    m = stock_matches[0]
    i = m.group('indent')
    replacement = (
        i + '// TSP_GL4ES_DISABLE_NORMALS_RT_051\n'
        + i + '// Indexed color masks (glColorMaski) are unavailable on this GL4ES/GLES2 path.\n'
        + i + 'resourceSystem->getSceneManager()->setSupportsNormalsRT(false);'
    )
    render = render[:m.start()] + replacement + render[m.end():]
elif len(stock_matches) == 0 and len(false_matches) == 1:
    m = false_matches[0]
    i = m.group('indent')
    start = m.start()
    render = (
        render[:start]
        + i + '// TSP_GL4ES_DISABLE_NORMALS_RT_051\n'
        + i + '// Indexed color masks (glColorMaski) are unavailable on this GL4ES/GLES2 path.\n'
        + m.group(0)
        + render[m.end():]
    )
else:
    raise RuntimeError(
        'Normals-RT normalization: expected one stock OR one existing false assignment; '
        f'found stock={len(stock_matches)} false={len(false_matches)}'
    )


# -------------------------------------------------------------------------
# 3. First-person depth callback: on GL4ES do not switch to the separate
#    OpaqueDepth FBO for the depth accumulation pass. This is the TSP-specific
#    unconditional equivalent of the upstream GL4ES condition.
# -------------------------------------------------------------------------
npc_marker = '// TSP_GL4ES_SKIP_FIRSTPERSON_OPAQUE_DEPTH_FBO_051'
if npc_marker not in npc:
    old = '            postProcessor->getFbo(PostProcessor::FBO_OpaqueDepth, frameId)->apply(*state);'
    new = (
        '            ' + npc_marker + '\n'
        '            // Keep the primary FBO bound; the separate opaque-depth copy is unreliable on GL4ES.'
    )
    npc = replace_once(npc, old, new, 'NpcAnimation opaque-depth FBO bypass')


# -------------------------------------------------------------------------
# 4. Transparent depth pass: GL4ES cannot reliably blit depth into the
#    separate opaque-depth target. Clear that target instead of depth-blitting,
#    then keep the primary FBO active for the optional transparent postpass.
#    This follows the upstream GL4ES workaround.
# -------------------------------------------------------------------------
transparent_blit_marker = '// TSP_GL4ES_SKIP_DEPTH_BLIT_051'
if transparent_blit_marker not in transparent:
    ext_decl = '        osg::GLExtensions* ext = state.get<osg::GLExtensions>();'
    if ext_decl in transparent:
        transparent = transparent.replace(
            ext_decl,
            '        // TSP_GL4ES_NO_DEPTH_BLIT_EXTENSION_OBJECT_051\n'
            '        // No GLExtensions depth-blit call is needed on the GL4ES path.',
            1,
        )
    elif 'TSP_GL4ES_NO_DEPTH_BLIT_EXTENSION_OBJECT_051' not in transparent:
        raise RuntimeError('Transparent pass GLExtensions declaration not found')
    pattern = re.compile(
        r'(?P<indent>[ \t]*)ext->glBlitFramebuffer\('
        r'0, 0, tex->getTextureWidth\(\), tex->getTextureHeight\(\), 0, 0, tex->getTextureWidth\(\),\s*'
        r'tex->getTextureHeight\(\), GL_DEPTH_BUFFER_BIT, GL_NEAREST\);'
    )
    matches = list(pattern.finditer(transparent))
    if len(matches) != 1:
        raise RuntimeError(f'Transparent depth blit: expected one stock call, found {len(matches)}')
    m = matches[0]
    i = m.group('indent')
    replacement = (
        i + transparent_blit_marker + '\n'
        + i + '// The primary scene depth texture is used elsewhere; do not depth-blit on GL4ES.\n'
        + i + 'glClear(GL_DEPTH_BUFFER_BIT | GL_STENCIL_BUFFER_BIT);'
    )
    transparent = transparent[:m.start()] + replacement + transparent[m.end():]

transparent_post_marker = '// TSP_GL4ES_KEEP_PRIMARY_FOR_TRANSPARENT_POSTPASS_051'
if transparent_post_marker not in transparent:
    # There are two opaqueFbo->apply calls in the stock function. The first one
    # must remain (the just-cleared auxiliary target); patch only the second,
    # located after "if (!mPostPass) return".
    anchor = '        if (!mPostPass)\n            return;'
    anchor_pos = transparent.find(anchor)
    if anchor_pos < 0:
        raise RuntimeError('Transparent postpass anchor not found')
    target = '        opaqueFbo->apply(state, osg::FrameBufferObject::DRAW_FRAMEBUFFER);'
    target_pos = transparent.find(target, anchor_pos + len(anchor))
    if target_pos < 0:
        raise RuntimeError('Transparent postpass opaque-FBO switch not found')
    # Ensure there is only one such target after the anchor.
    if transparent.find(target, target_pos + len(target)) >= 0:
        raise RuntimeError('Transparent postpass has multiple opaque-FBO switches after anchor')
    replacement = (
        '        ' + transparent_post_marker + '\n'
        '        // Leave the primary FBO bound for this pass on GL4ES.'
    )
    transparent = transparent[:target_pos] + replacement + transparent[target_pos + len(target):]


# -------------------------------------------------------------------------
# 5. Known GL4ES shader compiler/white-screen fixes from OpenMW MR !3948.
#    GLSL 1.20 uniform initializers are valid on desktop GL but rejected by
#    the GLES translator used in this GL4ES path.
# -------------------------------------------------------------------------
if 'uniform vec2 scaling = vec2(1.0, 1.0);' in fullscreen:
    fullscreen = fullscreen.replace(
        'uniform vec2 scaling = vec2(1.0, 1.0);',
        'uniform vec2 scaling;',
        1,
    )
elif 'uniform vec2 scaling;' not in fullscreen:
    raise RuntimeError('fullscreen_tri.vert: neither stock nor patched scaling uniform was found')

for old, new, label in (
    ('uniform bool useDiffuseMapForShadowAlpha = true;', 'uniform bool useDiffuseMapForShadowAlpha;', 'useDiffuseMapForShadowAlpha'),
    ('uniform bool alphaTestShadows = true;', 'uniform bool alphaTestShadows;', 'alphaTestShadows'),
):
    if old in shadow:
        shadow = shadow.replace(old, new, 1)
    elif new not in shadow:
        raise RuntimeError(f'shadowcasting.vert: neither stock nor patched {label} uniform was found')

# Later OpenMW GL4ES work also changed these checks for the GL4ES shader parser.
fog = fog.replace('#ifdef ADDITIVE_BLENDING', '#if defined(ADDITIVE_BLENDING)')


# -------------------------------------------------------------------------
# Verification before committing any file.
# -------------------------------------------------------------------------
checks = [
    ('postprocessor direct-FB marker removed', 'TSP_GL4ES_DIRECT_FRAMEBUFFER' not in post),
    ('postprocessor uses scene depth', post_marker in post and 'setTextureDepth(getTexture(Tex_Depth, frameId))' in post),
    ('postprocessor still intercepts scene normally', 'mViewer->setSceneData(this)' in post),
    ('render manager scene-depth mapping', render_depth_marker in render),
    ('opaque depth texture unit still reserved', 'reserveGlobalTextureUnits' in render and 'Slot::OpaqueDepthTexture' in render),
    ('normals MRT disabled', 'setSupportsNormalsRT(false);' in render),
    ('first person opaque-depth switch bypassed', npc_marker in npc),
    ('transparent depth blit bypassed', transparent_blit_marker in transparent),
    ('transparent postpass keeps primary', transparent_post_marker in transparent),
    ('fullscreen uniform initializer removed', 'uniform vec2 scaling;' in fullscreen and 'uniform vec2 scaling =' not in fullscreen),
    ('shadow uniform initializers removed', 'useDiffuseMapForShadowAlpha = true' not in shadow and 'alphaTestShadows = true' not in shadow),
    ('fog GL4ES form present', '#if defined(ADDITIVE_BLENDING)' in fog),
]
failed = [label for label, ok in checks if not ok]
if failed:
    raise RuntimeError('Patch verification failed: ' + '; '.join(failed))

write_transactionally((
    (post_path, post),
    (render_path, render),
    (transparent_path, transparent),
    (npc_path, npc),
    (fullscreen_path, fullscreen),
    (shadow_path, shadow),
    (fog_path, fog),
))

for label, _ in checks:
    print('OK:', label)
PY_PATCH

echo
echo "Verifying patched source markers..."
grep -n \
    -e 'TSP_GL4ES_USE_SCENE_DEPTH_051' \
    -e 'TSP_GL4ES_SCENEMANAGER_SCENE_DEPTH_051' \
    -e 'TSP_GL4ES_DISABLE_NORMALS_RT_051' \
    -e 'TSP_GL4ES_SKIP_FIRSTPERSON_OPAQUE_DEPTH_FBO_051' \
    -e 'TSP_GL4ES_SKIP_DEPTH_BLIT_051' \
    -e 'TSP_GL4ES_KEEP_PRIMARY_FOR_TRANSPARENT_POSTPASS_051' \
    "$POST_CPP" "$RENDER_CPP" "$NPC_CPP" "$TRANSPARENT_CPP"

echo
echo "Verifying shader source changes..."
grep -n 'uniform vec2 scaling' "$FULLSCREEN_VERT"
grep -n -e 'useDiffuseMapForShadowAlpha' -e 'alphaTestShadows' "$SHADOW_VERT" | head -10
grep -n 'defined(ADDITIVE_BLENDING)' "$FOG_GLSL"

echo
echo "Incrementally rebuilding OpenMW 0.51..."
cmake --build "$BUILD_DIR" --target openmw --parallel "$JOBS"

if [ ! -x "$BUILT_BINARY" ]; then
    echo "ERROR: Build completed but executable is missing: $BUILT_BINARY"
    exit 1
fi

mkdir -p "$(dirname "$OUTPUT_BINARY")" "$(dirname "$PACKAGE_BINARY")" "$PACKAGE_SHADER_DIR"

[ ! -e "$OUTPUT_BINARY" ] || cp -f "$OUTPUT_BINARY" "$OUTPUT_BINARY.before-$STAMP"
[ ! -e "$PACKAGE_BINARY" ] || cp -f "$PACKAGE_BINARY" "$PACKAGE_BINARY.before-gl4es-compat-$STAMP"

cp -f "$BUILT_BINARY" "$OUTPUT_BINARY"
cp -f "$BUILT_BINARY" "$PACKAGE_BINARY"
chmod +x "$OUTPUT_BINARY" "$PACKAGE_BINARY"

# Keep the package's compatibility shaders in sync where applicable. The TSP
# may already have a runtime fragment-flatten patch; this script does not alter
# fragment.h.glsl/fragment.glsl and does not undo that runtime fix.
cp -f "$FULLSCREEN_VERT" "$PACKAGE_SHADER_DIR/fullscreen_tri.vert"
cp -f "$SHADOW_VERT" "$PACKAGE_SHADER_DIR/shadowcasting.vert"
cp -f "$FOG_GLSL" "$PACKAGE_SHADER_DIR/fog.glsl"

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
echo "============================================================"
echo "OpenMW 0.51 TSP GL4ES compatibility rebuild completed"
echo "============================================================"
echo "Standalone binary:      $OUTPUT_BINARY"
echo "Packaged binary:        $PACKAGE_BINARY"
echo "Patched package shaders: $PACKAGE_SHADER_DIR"
echo "Pre-patch state backup: $CURRENT_BACKUP"
echo "Rollback baseline:      $BASELINE_BACKUP"
echo
echo "Important: keep the existing fragment-link flattening patch on the TSP."
echo "This build restores the full PostProcessor lifecycle; it does NOT use the"
echo "experimental direct-framebuffer bypass that caused the new-game crash."
echo "============================================================"
