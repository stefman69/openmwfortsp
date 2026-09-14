#!/bin/bash
set -euo pipefail

SOURCE_DIR="${1:-/root/openmw}"
BUILD_DIR="${2:-$SOURCE_DIR/build}"
OUTPUT_BINARY="${3:-/root/openmw_cursor_graphics_compat_v11}"

CPP="$SOURCE_DIR/apps/openmw/mwinput/inputmanagerimp.cpp"
HPP="$SOURCE_DIR/apps/openmw/mwinput/inputmanagerimp.hpp"
WATER_CPP="$SOURCE_DIR/apps/openmw/mwrender/water.cpp"
GROUNDCOVER_CPP="$SOURCE_DIR/apps/openmw/mwrender/groundcover.cpp"
OBJECTPAGING_CPP="$SOURCE_DIR/apps/openmw/mwrender/objectpaging.cpp"
CMAKE_FILE="$SOURCE_DIR/CMakeLists.txt"
BUILT_BINARY="$BUILD_DIR/openmw"

echo "============================================================"
echo "OpenMW 0.48 TSP cursor + GL4ES compatibility patch V11"
echo "Cursor desync fix, fixed-function water, non-instanced grass"
echo "and conservative distant-object paging"
echo "============================================================"
echo "Source:          $SOURCE_DIR"
echo "Build:           $BUILD_DIR"
echo "Stripped output: $OUTPUT_BINARY"
echo ""

for required in "$CPP" "$HPP" "$WATER_CPP" "$GROUNDCOVER_CPP" "$OBJECTPAGING_CPP" "$CMAKE_FILE"; do
    if [ ! -f "$required" ]; then
        echo "ERROR: Required file is missing:"
        echo "$required"
        exit 1
    fi
done

if [ ! -f "$BUILD_DIR/CMakeCache.txt" ]; then
    echo "ERROR: Existing OpenMW build cache was not found:"
    echo "$BUILD_DIR/CMakeCache.txt"
    exit 1
fi

VERSION_MAJOR="$(
    sed -n \
        's/^[[:space:]]*set(OPENMW_VERSION_MAJOR[[:space:]]*\([0-9][0-9]*\)).*/\1/p' \
        "$CMAKE_FILE" |
    head -1
)"

VERSION_MINOR="$(
    sed -n \
        's/^[[:space:]]*set(OPENMW_VERSION_MINOR[[:space:]]*\([0-9][0-9]*\)).*/\1/p' \
        "$CMAKE_FILE" |
    head -1
)"

VERSION_RELEASE="$(
    sed -n \
        's/^[[:space:]]*set(OPENMW_VERSION_RELEASE[[:space:]]*\([0-9][0-9]*\)).*/\1/p' \
        "$CMAKE_FILE" |
    head -1
)"

echo "Detected source version:"
echo "${VERSION_MAJOR:-?}.${VERSION_MINOR:-?}.${VERSION_RELEASE:-?}"
echo ""

if [ "${VERSION_MAJOR:-}" != "0" ] ||
   [ "${VERSION_MINOR:-}" != "48" ] ||
   [ "${VERSION_RELEASE:-}" != "0" ]
then
    echo "ERROR: This script is only for OpenMW 0.48.0."
    exit 1
fi

STAMP="$(date +%Y%m%d-%H%M%S)"
CPP_BACKUP="$CPP.before-tsp-compat-v11.$STAMP"
HPP_BACKUP="$HPP.before-tsp-compat-v11.$STAMP"
WATER_BACKUP="$WATER_CPP.before-tsp-compat-v11.$STAMP"
GROUNDCOVER_BACKUP="$GROUNDCOVER_CPP.before-tsp-compat-v11.$STAMP"
OBJECTPAGING_BACKUP="$OBJECTPAGING_CPP.before-tsp-compat-v11.$STAMP"

cp -f "$CPP" "$CPP_BACKUP"
cp -f "$HPP" "$HPP_BACKUP"
cp -f "$WATER_CPP" "$WATER_BACKUP"
cp -f "$GROUNDCOVER_CPP" "$GROUNDCOVER_BACKUP"
cp -f "$OBJECTPAGING_CPP" "$OBJECTPAGING_BACKUP"

echo "Created source backups:"
echo "$CPP_BACKUP"
echo "$HPP_BACKUP"
echo "$WATER_BACKUP"
echo "$GROUNDCOVER_BACKUP"
echo "$OBJECTPAGING_BACKUP"
echo ""

python3 - "$CPP" "$HPP" "$WATER_CPP" "$GROUNDCOVER_CPP" "$OBJECTPAGING_CPP" <<'PY'
from pathlib import Path
import re
import sys

cpp_path = Path(sys.argv[1])
hpp_path = Path(sys.argv[2])
water_path = Path(sys.argv[3])
groundcover_path = Path(sys.argv[4])
objectpaging_path = Path(sys.argv[5])

cpp = cpp_path.read_text(encoding="utf-8")
hpp = hpp_path.read_text(encoding="utf-8")
water = water_path.read_text(encoding="utf-8")
groundcover = groundcover_path.read_text(encoding="utf-8")
objectpaging = objectpaging_path.read_text(encoding="utf-8")


def find_function(text, signature_regex):
    match = re.search(signature_regex, text, flags=re.MULTILINE)
    if not match:
        raise RuntimeError(
            "Could not locate InputManager::update by signature."
        )

    opening = text.find("{", match.end())
    if opening < 0:
        raise RuntimeError(
            "Located InputManager::update, but its opening brace is missing."
        )

    depth = 0
    in_string = False
    in_char = False
    escaped = False
    line_comment = False
    block_comment = False
    i = opening

    while i < len(text):
        ch = text[i]
        nxt = text[i + 1] if i + 1 < len(text) else ""

        if line_comment:
            if ch == "\n":
                line_comment = False
            i += 1
            continue

        if block_comment:
            if ch == "*" and nxt == "/":
                block_comment = False
                i += 2
            else:
                i += 1
            continue

        if in_string:
            if escaped:
                escaped = False
            elif ch == "\\":
                escaped = True
            elif ch == '"':
                in_string = False
            i += 1
            continue

        if in_char:
            if escaped:
                escaped = False
            elif ch == "\\":
                escaped = True
            elif ch == "'":
                in_char = False
            i += 1
            continue

        if ch == "/" and nxt == "/":
            line_comment = True
            i += 2
            continue

        if ch == "/" and nxt == "*":
            block_comment = True
            i += 2
            continue

        if ch == '"':
            in_string = True
            i += 1
            continue

        if ch == "'":
            in_char = True
            i += 1
            continue

        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                return match.start(), i + 1

        i += 1

    raise RuntimeError(
        "InputManager::update opening brace was found, but its end was not."
    )


if "#include <MyGUI_PointerManager.h>" not in cpp:
    include_matches = list(
        re.finditer(r"^#include[^\n]*\n", cpp, flags=re.MULTILINE)
    )

    if not include_matches:
        raise RuntimeError("Could not find an include insertion point.")

    insertion = include_matches[-1].end()
    cpp = (
        cpp[:insertion]
        + "#include <MyGUI_PointerManager.h>\n"
        + cpp[insertion:]
    )


new_update = r'''    // TSP_MYGUI_CURSOR_V11
    void InputManager::update(float dt, bool disableControls, bool disableEvents)
    {
        mControlsDisabled = disableControls;

        MWBase::WindowManager* windowManager
            = MWBase::Environment::get().getWindowManager();

        // The TSP/GL4ES path does not reliably display SDL's hardware
        // cursor. Always use MyGUI's in-engine pointer instead.
        mInputWrapper->setMouseVisible(false);
        mInputWrapper->capture(disableEvents);

        // gptokeyb2 emits Pause only for Menu+Select.
        //
        // Select itself is deliberately not tracked here. gptokeyb2 alone
        // owns normal <-> mouse-profile switching, preventing the mapper
        // and OpenMW from drifting out of synchronization after quick taps.
        const Uint8* keyboardState = SDL_GetKeyboardState(nullptr);
        const bool cursorChordPressed
            = keyboardState != nullptr
            && keyboardState[SDL_SCANCODE_PAUSE] != 0;

        if (cursorChordPressed && !mTspCursorChordWasPressed)
            mTspCursorVisible = !mTspCursorVisible;

        mTspCursorChordWasPressed = cursorChordPressed;

        const bool showMyGuiPointer
            = mTspCursorVisible
            && windowManager->isGuiMode();

        MyGUI::PointerManager::getInstance().setVisible(
            showMyGuiPointer);

        if (disableControls)
        {
            mMouseManager->updateCursorMode();
            return;
        }

        mBindingsManager->update(dt);

        mMouseManager->updateCursorMode();
        bool controllerMove = mControllerManager->update(dt);
        mMouseManager->update(dt);
        mSensorManager->update(dt);
        mActionManager->update(dt, controllerMove);

        if (mGyroManager->isEnabled())
        {
            bool controllerAvailable
                = mControllerManager->isGyroAvailable();
            bool sensorAvailable
                = mSensorManager->isGyroAvailable();

            if (controllerAvailable || sensorAvailable)
            {
                mGyroManager->update(
                    dt,
                    controllerAvailable
                        ? mControllerManager->getGyroValues()
                        : mSensorManager->getGyroValues());
            }
        }
    }'''

start, end = find_function(
    cpp,
    r"^[ \t]*void[ \t]+InputManager::update[ \t]*\("
)
cpp = cpp[:start] + new_update + cpp[end:]


# Remove every member from older TSP cursor revisions.
hpp = re.sub(
    r"^[ \t]*// TSP_MYGUI_CURSOR_V[0-9]+\s*\n",
    "",
    hpp,
    flags=re.MULTILINE,
)

old_member_names = (
    "mTspMouseModeEnabled",
    "mTspTextModeEnabled",
    "mTspSelectWasPressed",
    "mTspLeftShoulderWasPressed",
    "mTspCursorVisible",
    "mTspLeftStickWasPressed",
    "mTspCursorChordWasPressed",
    "mTspSelectConsumedByChord",
)

for member_name in old_member_names:
    hpp = re.sub(
        r"^[ \t]*bool[ \t]+"
        + re.escape(member_name)
        + r"[ \t]*=[ \t]*false;[ \t]*\n",
        "",
        hpp,
        flags=re.MULTILINE,
    )

member_anchor = "        std::unique_ptr<GyroManager> mGyroManager;\n"

if member_anchor not in hpp:
    raise RuntimeError(
        "Could not find the GyroManager member insertion point."
    )

member_block = (
    member_anchor
    + "\n"
    + "        // TSP_MYGUI_CURSOR_V11\n"
    + "        bool mTspCursorVisible = false;\n"
    + "        bool mTspCursorChordWasPressed = false;\n"
)

hpp = hpp.replace(member_anchor, member_block, 1)

for token in (
    "TSP_MYGUI_CURSOR_V11",
    "SDL_SCANCODE_PAUSE",
    "mTspCursorVisible",
    "mTspCursorChordWasPressed",
    "MyGUI::PointerManager",
):
    if token not in cpp:
        raise RuntimeError(
            "CPP verification failed: missing " + token
        )

for token in (
    "TSP_MYGUI_CURSOR_V11",
    "mTspCursorVisible",
    "mTspCursorChordWasPressed",
):
    if token not in hpp:
        raise RuntimeError(
            "HPP verification failed: missing " + token
        )

# Confirm that Select is no longer part of the cursor state machine.
for forbidden in (
    "mTspSelectWasPressed",
    "mTspSelectConsumedByChord",
    "mTspMouseModeEnabled",
):
    if forbidden in cpp or forbidden in hpp:
        raise RuntimeError(
            "Old synchronization state remains: " + forbidden
        )



# -------------------------------------------------------------------------
# TSP / GL4ES rendering compatibility patches
# -------------------------------------------------------------------------

# WATER: disable GL_DEPTH_CLAMP on the GLES2/gl4es path. Some gl4es builds
# advertise the desktop extension but render the large water plane
# incorrectly when it is enabled.
depth_callback_line = "    mWaterGeom->setDrawCallback(new DepthClampCallback);"
if depth_callback_line in water:
    water = water.replace(
        depth_callback_line,
        "    // TSP_GL4ES_WATER_V11: depth clamp disabled for gl4es/GLES2.",
        1,
    )
elif "TSP_GL4ES_WATER_V11: depth clamp disabled" not in water:
    raise RuntimeError("Could not locate the water depth-clamp callback.")

new_simple_water = r'''void Water::createSimpleWaterStateSet(osg::Node* node, float alpha)
{
    // TSP_GL4ES_WATER_V11
    osg::ref_ptr<osg::StateSet> stateset
        = SceneUtil::createSimpleWaterStateSet(
            alpha, MWRender::RenderBin_Water);

    node->setStateSet(stateset);
    node->setUpdateCallback(nullptr);
    mRainIntensityUpdater = nullptr;

    // Keep OpenMW's animated water textures, but do not force a generated
    // desktop GLSL shader. The fixed-function state is translated much more
    // reliably by gl4es on the TrimUI Smart Pro S.
    std::vector<osg::ref_ptr<osg::Texture2D>> textures;
    const int frameCount = std::clamp(
        Fallback::Map::getInt("Water_SurfaceFrameCount"), 0, 320);
    const std::string& texture
        = Fallback::Map::getString("Water_SurfaceTexture");

    for (int i = 0; i < frameCount; ++i)
    {
        std::ostringstream texname;
        texname << "textures/water/" << texture
                << std::setw(2) << std::setfill('0') << i << ".dds";

        osg::ref_ptr<osg::Texture2D> tex(new osg::Texture2D(
            mResourceSystem->getImageManager()->getImage(texname.str())));
        tex->setWrap(osg::Texture::WRAP_S, osg::Texture::REPEAT);
        tex->setWrap(osg::Texture::WRAP_T, osg::Texture::REPEAT);
        mResourceSystem->getSceneManager()->applyFilterSettings(tex);
        textures.push_back(tex);
    }

    if (textures.empty())
        return;

    const float fps = Fallback::Map::getFloat("Water_SurfaceFPS");
    osg::ref_ptr<NifOsg::FlipController> controller(
        new NifOsg::FlipController(0, 1.f / fps, textures));
    controller->setSource(
        std::make_shared<SceneUtil::FrameTimeSource>());
    node->setUpdateCallback(controller);

    stateset->setTextureAttributeAndModes(
        0, textures[0], osg::StateAttribute::ON);
}'''

water_start, water_end = find_function(
    water,
    r"^[ \t]*void[ \t]+Water::createSimpleWaterStateSet[ \t]*\(",
)
water = water[:water_start] + new_simple_water + water[water_end:]


# GROUNDCOVER: remove the dedicated instancing attributes/divisors and render
# each placement through a normal transform. This costs more draw calls, but
# avoids the vertex-divisor and special groundcover shader path that is not
# reliable on GLES2/gl4es.
position_include = (
    "#include <components/sceneutil/positionattitudetransform.hpp>\n"
)
if position_include not in groundcover:
    anchor = "#include <components/sceneutil/nodecallback.hpp>\n"
    if anchor not in groundcover:
        raise RuntimeError(
            "Could not find the groundcover include insertion point."
        )
    groundcover = groundcover.replace(anchor, anchor + position_include, 1)

def find_cpp_function(text, signature_pattern, label):
    match = re.search(signature_pattern, text, flags=re.MULTILINE)
    if not match:
        raise RuntimeError("Could not locate " + label + ".")

    opening = text.find("{", match.end())
    if opening < 0:
        raise RuntimeError("Located " + label + ", but its opening brace is missing.")

    depth = 0
    i = opening
    in_string = False
    in_char = False
    escaped = False
    line_comment = False
    block_comment = False

    while i < len(text):
        ch = text[i]
        nxt = text[i + 1] if i + 1 < len(text) else ""

        if line_comment:
            if ch == "\\n":
                line_comment = False
            i += 1
            continue
        if block_comment:
            if ch == "*" and nxt == "/":
                block_comment = False
                i += 2
            else:
                i += 1
            continue
        if in_string:
            if escaped:
                escaped = False
            elif ch == "\\\\":
                escaped = True
            elif ch == '"':
                in_string = False
            i += 1
            continue
        if in_char:
            if escaped:
                escaped = False
            elif ch == "\\\\":
                escaped = True
            elif ch == "'":
                in_char = False
            i += 1
            continue
        if ch == "/" and nxt == "/":
            line_comment = True
            i += 2
            continue
        if ch == "/" and nxt == "*":
            block_comment = True
            i += 2
            continue
        if ch == '"':
            in_string = True
            i += 1
            continue
        if ch == "'":
            in_char = True
            i += 1
            continue
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                return match.start(), opening, i + 1
        i += 1

    raise RuntimeError("Located " + label + ", but its closing brace is missing.")

if "TSP_GL4ES_GROUNDCOVER_V11: use normal transforms" not in groundcover:
    ctor_start, ctor_open, ctor_end = find_cpp_function(
        groundcover,
        r"^[ \\t]*Groundcover::Groundcover[ \\t]*\(",
        "Groundcover::Groundcover",
    )
    ctor = groundcover[ctor_start:ctor_end]

    required_patterns = (
        r"^[ \\t]*mStateset->setAttribute\\([ \\t]*new[ \\t]+osg::VertexAttribDivisor\\([ \\t]*6[ \\t]*,[ \\t]*1[ \\t]*\\)[ \\t]*\\)[ \\t]*;[ \\t]*\\n?",
        r"^[ \\t]*mStateset->setAttribute\\([ \\t]*new[ \\t]+osg::VertexAttribDivisor\\([ \\t]*7[ \\t]*,[ \\t]*1[ \\t]*\\)[ \\t]*\\)[ \\t]*;[ \\t]*\\n?",
        r"^[ \\t]*mProgramTemplate[ \\t]*=[^;]*;[ \\t]*\\n?",
        r"^[ \\t]*mProgramTemplate->addBindAttribLocation\\([ \\t]*\"aOffset\"[ \\t]*,[ \\t]*6[ \\t]*\\)[ \\t]*;[ \\t]*\\n?",
        r"^[ \\t]*mProgramTemplate->addBindAttribLocation\\([ \\t]*\"aRotation\"[ \\t]*,[ \\t]*7[ \\t]*\\)[ \\t]*;[ \\t]*\\n?",
    )

    removed = 0
    for pattern in required_patterns:
        ctor, count = re.subn(pattern, "", ctor, count=1, flags=re.MULTILINE)
        removed += count

    if removed < 2:
        diagnostic = "\\n".join(
            line for line in ctor.splitlines()
            if "VertexAttribDivisor" in line
            or "mProgramTemplate" in line
            or "addBindAttribLocation" in line
        )
        raise RuntimeError(
            "Could not remove the groundcover instancing setup from "
            "Groundcover::Groundcover. Matching lines found:\\n" + diagnostic
        )

    marker = "        // TSP_GL4ES_GROUNDCOVER_V11: use normal transforms, not instancing.\\n"
    brace = ctor.find("{")
    ctor = ctor[:brace + 1] + "\\n" + marker + ctor[brace + 1:]
    groundcover = groundcover[:ctor_start] + ctor + groundcover[ctor_end:]

new_groundcover_chunk = r'''    osg::ref_ptr<osg::Node> Groundcover::createChunk(
        InstanceMap& instances, const osg::Vec2f& center)
    {
        // TSP_GL4ES_GROUNDCOVER_V11
        // Compatibility fallback: ordinary transforms and ordinary mesh
        // rendering instead of glDraw*Instanced plus vertex divisors.
        osg::ref_ptr<osg::Group> group = new osg::Group;
        const osg::Vec3f worldCenter
            = osg::Vec3f(center.x(), center.y(), 0)
              * ESM::Land::REAL_SIZE;

        for (auto& pair : instances)
        {
            const osg::Node* temp = mSceneManager->getTemplate(pair.first);

            // Keep the cached template alive while it is shared by all of
            // the placement transforms in this chunk.
            group->getOrCreateUserDataContainer()->addUserObject(
                new Resource::TemplateRef(temp));

            for (const GroundcoverEntry& entry : pair.second)
            {
                const osg::Vec3f relativePos
                    = entry.mPos.asVec3() - worldCenter;
                const osg::Quat attitude
                    = osg::Quat(
                          entry.mPos.rot[2], osg::Vec3f(0, 0, -1))
                      * osg::Quat(
                          entry.mPos.rot[1], osg::Vec3f(0, -1, 0))
                      * osg::Quat(
                          entry.mPos.rot[0], osg::Vec3f(-1, 0, 0));

                osg::ref_ptr<SceneUtil::PositionAttitudeTransform> trans
                    = new SceneUtil::PositionAttitudeTransform;
                trans->setPosition(relativePos);
                trans->setScale(osg::Vec3f(
                    entry.mScale, entry.mScale, entry.mScale));
                trans->setAttitude(attitude);
                trans->addChild(const_cast<osg::Node*>(temp));
                group->addChild(trans);
            }
        }

        osg::ComputeBoundsVisitor cbv;
        group->accept(cbv);
        const osg::BoundingBox box = cbv.getBoundingBox();
        group->addCullCallback(
            new ViewDistanceCallback(getViewDistance(), box));
        group->setStateSet(mStateset);
        group->setNodeMask(Mask_Groundcover);

        if (mSceneManager->getLightingMethod()
            != SceneUtil::LightingMethod::FFP)
        {
            group->addCullCallback(new SceneUtil::LightListCallback);
        }

        // Do not call recreateShaders(..., "groundcover", ...): that shader
        // requires the removed per-instance attributes 6 and 7.
        mSceneManager->shareState(group);
        group->getBound();
        return group;
    }'''

ground_start, ground_end = find_function(
    groundcover,
    r"^[ \t]*osg::ref_ptr<osg::Node>[ \t]+Groundcover::createChunk[ \t]*\(",
)
groundcover = (
    groundcover[:ground_start]
    + new_groundcover_chunk
    + groundcover[ground_end:]
)


# DISTANT OBJECTS: keep object paging, but stop flattening/merging geometry and
# stop freezing billboard orientation relative to the viewpoint used when the
# chunk was built. Both optimizations are risky for alpha-tested trees through
# gl4es and can produce black or angle-dependent missing pieces.
merge_setting = '''         mMergeFactor = Settings::Manager::getFloat("object paging merge factor", "Terrain");'''
if merge_setting in objectpaging:
    objectpaging = objectpaging.replace(
        merge_setting,
        "         // TSP_GL4ES_OBJECT_PAGING_V9\n"
        "         mMergeFactor = 0.f;",
        1,
    )
elif "TSP_GL4ES_OBJECT_PAGING_V9" not in objectpaging:
    raise RuntimeError(
        "Could not locate the object-paging merge-factor assignment."
    )

billboard_line = "                copyop.mOptimizeBillboards = (size > 1/4.f);"
if billboard_line in objectpaging:
    objectpaging = objectpaging.replace(
        billboard_line,
        "                copyop.mOptimizeBillboards = false;",
        1,
    )
elif "copyop.mOptimizeBillboards = false;" not in objectpaging:
    raise RuntimeError(
        "Could not locate the object-paging billboard optimization."
    )

compile_display_lines = '''                    if (!merge)
                        mode |= osgUtil::GLObjectsVisitor::COMPILE_DISPLAY_LISTS;
'''
if compile_display_lines in objectpaging:
    objectpaging = objectpaging.replace(
        compile_display_lines,
        "                    // TSP GL4ES: compile state only; do not force display lists.\n",
        1,
    )
elif "compile state only; do not force display lists" not in objectpaging:
    raise RuntimeError(
        "Could not locate the object-paging display-list compile block."
    )


for token in (
    "TSP_GL4ES_WATER_V11",
    "depth clamp disabled for gl4es/GLES2",
):
    if token not in water:
        raise RuntimeError("Water verification failed: missing " + token)

for token in (
    "TSP_GL4ES_GROUNDCOVER_V11",
    "PositionAttitudeTransform",
    "Do not call recreateShaders",
):
    if token not in groundcover:
        raise RuntimeError(
            "Groundcover verification failed: missing " + token
        )

for token in (
    "TSP_GL4ES_OBJECT_PAGING_V9",
    "mMergeFactor = 0.f",
    "copyop.mOptimizeBillboards = false",
):
    if token not in objectpaging:
        raise RuntimeError(
            "Object-paging verification failed: missing " + token
        )

with open(cpp_path, "w", encoding="utf-8", newline="\n") as handle:
    handle.write(cpp)

with open(hpp_path, "w", encoding="utf-8", newline="\n") as handle:
    handle.write(hpp)

with open(water_path, "w", encoding="utf-8", newline="\n") as handle:
    handle.write(water)

with open(groundcover_path, "w", encoding="utf-8", newline="\n") as handle:
    handle.write(groundcover)

with open(objectpaging_path, "w", encoding="utf-8", newline="\n") as handle:
    handle.write(objectpaging)

print("Updated:")
print(cpp_path)
print(hpp_path)
print(water_path)
print(groundcover_path)
print(objectpaging_path)
PY

echo ""
echo "Patch verification:"
grep -n "TSP_MYGUI_CURSOR_V11" "$CPP" "$HPP"
grep -n "SDL_SCANCODE_PAUSE" "$CPP"
grep -n "mTspCursorVisible" "$CPP" "$HPP"
grep -n "TSP_GL4ES_WATER_V11" "$WATER_CPP"
grep -n "TSP_GL4ES_GROUNDCOVER_V11" "$GROUNDCOVER_CPP"
grep -n "TSP_GL4ES_OBJECT_PAGING_V9" "$OBJECTPAGING_CPP"
grep -n "mOptimizeBillboards = false" "$OBJECTPAGING_CPP"
echo ""

echo "Incrementally rebuilding OpenMW 0.48..."
cmake --build \
    "$BUILD_DIR" \
    --target openmw \
    --parallel "$(nproc)"

if [ ! -x "$BUILT_BINARY" ]; then
    echo "ERROR: Build completed, but the executable was not found:"
    echo "$BUILT_BINARY"
    exit 1
fi

echo ""
echo "Creating stripped deployment binary..."
cp -f "$BUILT_BINARY" "$OUTPUT_BINARY"

STRIP_TOOL=""

if command -v aarch64-linux-gnu-strip >/dev/null 2>&1; then
    STRIP_TOOL="$(command -v aarch64-linux-gnu-strip)"
elif command -v strip >/dev/null 2>&1; then
    STRIP_TOOL="$(command -v strip)"
else
    echo "ERROR: No strip tool was found."
    exit 1
fi

"$STRIP_TOOL" --strip-unneeded "$OUTPUT_BINARY"
chmod +x "$OUTPUT_BINARY"

echo ""
echo "============================================================"
echo "Patch and rebuild completed"
echo "============================================================"
echo "Deployment binary:"
ls -lh "$OUTPUT_BINARY"
file "$OUTPUT_BINARY"
echo ""
echo "Copy it to the SD card as:"
echo "  D:\\Data\\ports\\openmw\\openmw"
echo ""
echo "IMPORTANT: keep the existing dropdown/text-fixed"
echo "libMyGUIEngine.so and the existing openmw.ini."
echo "This script does not modify or replace any MyGUI source/library."
echo "============================================================"
