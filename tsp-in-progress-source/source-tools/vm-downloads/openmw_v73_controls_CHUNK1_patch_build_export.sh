#!/usr/bin/env bash
set -Eeuo pipefail

CONTAINER="${CONTAINER:-openmw_builder}"
SRC="${SRC:-/root/openmw-0.51-tsp-src}"
BUILD="${BUILD:-/root/openmw-0.51-tsp-build}"
GLSRC="${GLSRC:-/root/gl4es-tsps}"
DEVICE="${DEVICE:-root@192.168.1.12}"
LIVE_BIN="${LIVE_BIN:-/mnt/SDCARD/data/ports/openmw/bin/openmw-0.51}"
OUTDIR="${OUTDIR:-/home/bob-simpson/Downloads}"
OUTBIN="$OUTDIR/openmw-0.51-v73-controls-safe"
MANIFEST="$OUTDIR/openmw-0.51-v73-controls-safe.manifest"

fail() { echo "ERROR: $*" >&2; exit 1; }
trap 'rc=$?; echo; echo "ERROR: CHUNK 1 stopped at host line $LINENO (status $rc)." >&2; echo "No device deployment was attempted." >&2' ERR

mkdir -p "$OUTDIR"

echo "===== CHUNK 1: V73 CONTROLS PATCH / BUILD / EXPORT ====="
echo "This chunk does NOT deploy to the TSP."
echo

DOCKER=(docker)
if ! docker info >/dev/null 2>&1; then
    echo "Docker needs elevated access; requesting it once."
    sudo -v
    DOCKER=(sudo docker)
fi

"${DOCKER[@]}" inspect "$CONTAINER" >/dev/null 2>&1 || fail "container '$CONTAINER' not found"

# -----------------------------------------------------------------------------
# Authoritative preflight: the current built binary must match the live device,
# and the current OpenMW tree must have no pending build work BEFORE we patch.
# This prevents an in-progress localmap V7 source edit from being pulled into a
# controls-only build by Ninja.
# -----------------------------------------------------------------------------
echo "===== AUTHORITATIVE BASELINE CHECK ====="

LIVE_HASH="$(ssh -n -o BatchMode=yes "$DEVICE" "test -s '$LIVE_BIN' && sha256sum '$LIVE_BIN' | awk '{print \\$1}'")" \
    || fail "could not read live OpenMW hash from $DEVICE:$LIVE_BIN"
[ -n "$LIVE_HASH" ] || fail "live OpenMW hash was empty"

echo "Live OpenMW SHA256:  $LIVE_HASH"

BUILD_HASH="$("${DOCKER[@]}" exec "$CONTAINER" bash -lc \
    "test -s '$BUILD/openmw' && sha256sum '$BUILD/openmw' | awk '{print \\$1}'")" \
    || fail "current Docker build binary is missing"
[ -n "$BUILD_HASH" ] || fail "Docker build hash was empty"

echo "Build OpenMW SHA256: $BUILD_HASH"

if [ "$BUILD_HASH" != "$LIVE_HASH" ]; then
    fail "Docker build binary does not match the live TSP binary. Refusing to layer controls onto an uncertain map/build baseline."
fi

echo "Build/live baseline match: PASS"

echo
echo "===== CURRENT SOURCE / MAP STATE ====="
"${DOCKER[@]}" exec "$CONTAINER" bash -lc "
set -eu
SRC='$SRC'
GLSRC='$GLSRC'
for f in \
  \"\$SRC/apps/openmw/mwrender/localmap.cpp\" \
  \"\$SRC/apps/openmw/mwgui/mapwindow.cpp\" \
  \"\$SRC/apps/openmw/mwinput/inputmanagerimp.cpp\" \
  \"\$SRC/apps/openmw/mwinput/controllermanager.cpp\" \
  \"\$GLSRC/src/gl/texture_read.c\"
do
  test -f \"\$f\" || { echo \"ERROR: missing \$f\" >&2; exit 2; }
done

sha256sum \
  \"\$SRC/apps/openmw/mwrender/localmap.cpp\" \
  \"\$SRC/apps/openmw/mwgui/mapwindow.cpp\" \
  \"\$GLSRC/src/gl/texture_read.c\"

echo
echo 'Map markers currently present:'
grep -nE 'TSP_LOCALMAP_BROAD_V6|TSP_LOCALMAP_CPU_PIPE_V78|TSP_LOCALMAP_FRAMEBUFFER_BYPASS_V73|TSP_LOCALMAP_PERSIST_V7' \
  \"\$SRC/apps/openmw/mwrender/localmap.cpp\" || true

echo
echo 'Current controls markers:'
grep -nE 'TSP_FOCUSED_EDITBOX_TEXT_051_V72|TSP_CLICK_EDITBOX_TO_TEXT_051_V72|TSP_TEXT_ENTRY_SDL_ONLY_051_V73|TSP_PRECISE_EDITBOX_CLICK_051_V73' \
  \"\$SRC/apps/openmw/mwinput/inputmanagerimp.cpp\" \
  \"\$SRC/apps/openmw/mwinput/controllermanager.cpp\" || true
"

echo
echo "===== PRE-PATCH BUILD DRY RUN ====="
PRE_DRY="$("${DOCKER[@]}" exec "$CONTAINER" bash -lc \
    "cmake --build '$BUILD' --target openmw -- -n 2>&1")" \
    || { printf '%s\n' "$PRE_DRY"; fail "pre-patch dry-run failed"; }
printf '%s\n' "$PRE_DRY"

if ! printf '%s\n' "$PRE_DRY" | grep -Eq 'no work to do|ninja: no work to do'; then
    echo >&2
    echo "ERROR: The current OpenMW tree already has pending build work BEFORE the controls patch." >&2
    echo "That can pull unrelated V7/map/UI source into a controls-only binary." >&2
    echo "Nothing has been modified. Resolve/confirm that pending source state first." >&2
    exit 10
fi

echo "Pre-patch tree/build synchronization: PASS"

STAMP="$(date +%Y%m%d-%H%M%S)"
PATCHER="/tmp/tsp_v73_safe_patch_$$.py"
trap 'rm -f "$PATCHER"' EXIT

cat > "$PATCHER" <<'PY'
from pathlib import Path
import os
import re
import sys

root = Path(sys.argv[1])
input_cpp = root / "apps/openmw/mwinput/inputmanagerimp.cpp"
controller_cpp = root / "apps/openmw/mwinput/controllermanager.cpp"

for p in (input_cpp, controller_cpp):
    if not p.is_file():
        raise RuntimeError(f"missing source file: {p}")

inp = input_cpp.read_text(encoding="utf-8")
ctl = controller_cpp.read_text(encoding="utf-8")

# Refuse unknown/already-partial states instead of guessing.
if "TSP_TEXT_ENTRY_SDL_ONLY_051_V73" in inp or "TSP_PRECISE_EDITBOX_CLICK_051_V73" in ctl:
    raise RuntimeError("V73 marker already present; refusing to apply a second/partial V73 patch")
if inp.count("TSP_FOCUSED_EDITBOX_TEXT_051_V72") != 1:
    raise RuntimeError("expected exactly one TSP_FOCUSED_EDITBOX_TEXT_051_V72 marker")
if ctl.count("TSP_CLICK_EDITBOX_TO_TEXT_051_V72") != 1:
    raise RuntimeError("expected exactly one TSP_CLICK_EDITBOX_TO_TEXT_051_V72 marker")
if "tspSetTextSuppressed" not in ctl or "tspSetMouseMode" not in ctl:
    raise RuntimeError("current ControllerManager is missing the existing TSP text/mouse mode helpers")

# 1) Return helper activation to the architecture used by the audited TSP input
#    code: SDL text-input state is authoritative.
pat_inp = re.compile(
    r"        // TSP_FOCUSED_EDITBOX_TEXT_051_V72\n"
    r".*?"
    r"        const bool tspTextEntryActive\n"
    r"            = SDL_IsTextInputActive\(\) == SDL_TRUE \|\| tspFocusedEditBoxV72;\n",
    re.S,
)
repl_inp = '''        // TSP_TEXT_ENTRY_SDL_ONLY_051_V73
        // Keep the helper tied to real SDL text-input state. Controller-mouse
        // code explicitly restarts SDL text input only for a direct editable
        // EditBox click.
        const bool tspTextEntryActive = SDL_IsTextInputActive() == SDL_TRUE;
'''
inp2, n = pat_inp.subn(repl_inp, inp, count=1)
if n != 1:
    raise RuntimeError(f"failed to replace V72 focused-EditBox text block (matches={n})")

# 2) Replace only the V72 broad post-click block. Use actual mouse focus, not
#    stale key focus, and explicitly route focus through OpenMW's wrapper.
if "#include <MyGUI_EditBox.h>" not in ctl:
    anchor = "#include <MyGUI_Button.h>\n"
    if anchor not in ctl:
        raise RuntimeError("MyGUI_Button include anchor missing")
    ctl = ctl.replace(anchor, anchor + "#include <MyGUI_EditBox.h>\n", 1)
if "#include <MyGUI_InputManager.h>" not in ctl:
    anchor = "#include <MyGUI_EditBox.h>\n"
    ctl = ctl.replace(anchor, anchor + "#include <MyGUI_InputManager.h>\n", 1)

pat_ctl = re.compile(
    r"                    // TSP_CLICK_EDITBOX_TO_TEXT_051_V72\n"
    r".*?"
    r"(?=                    if \(mBindingsManager->isDetectingBindingState\(\)\))",
    re.S,
)
repl_ctl = '''                    // TSP_PRECISE_EDITBOX_CLICK_051_V73
                    // Only the widget physically under the controller-mouse
                    // cursor may enter text mode. Walk through skin children
                    // to an owning enabled, editable MyGUI EditBox.
                    MyGUI::InputManager& tspInputV73 = MyGUI::InputManager::getInstance();
                    MyGUI::EditBox* tspClickedEditV73 = nullptr;
                    for (MyGUI::Widget* tspHitV73 = tspInputV73.getMouseFocusWidget();
                         tspHitV73 != nullptr;
                         tspHitV73 = tspHitV73->getParent())
                    {
                        if (MyGUI::EditBox* tspEditV73 = tspHitV73->castType<MyGUI::EditBox>(false))
                        {
                            if (tspEditV73->getEnabled() && !tspEditV73->getEditStatic())
                                tspClickedEditV73 = tspEditV73;
                            break;
                        }
                    }

                    MWBase::WindowManager* tspWindowV73
                        = MWBase::Environment::get().getWindowManager();

                    if (tspClickedEditV73 != nullptr)
                    {
                        // OpenMW 0.51's wrapper also refreshes SDL text-input
                        // state, fixing re-entry into Create Class -> name.
                        tspWindowV73->setKeyFocusWidget(tspClickedEditV73);
                        std::remove("/tmp/openmw-tsp-force-controller");
                        tspSetTextSuppressed(false);
                        tspSetMouseMode(false);
                        Log(Debug::Info)
                            << "TSP_PRECISE_EDITBOX_CLICK_051_V73 action=mouse-to-text widget="
                            << tspClickedEditV73->getName();
                    }
                    else
                    {
                        // If the previous key focus was an editable EditBox,
                        // clicking elsewhere must end that stale text focus.
                        bool tspHadEditableKeyFocusV73 = false;
                        for (MyGUI::Widget* tspKeyV73 = tspInputV73.getKeyFocusWidget();
                             tspKeyV73 != nullptr;
                             tspKeyV73 = tspKeyV73->getParent())
                        {
                            if (MyGUI::EditBox* tspEditV73 = tspKeyV73->castType<MyGUI::EditBox>(false))
                            {
                                tspHadEditableKeyFocusV73 = !tspEditV73->getEditStatic();
                                break;
                            }
                        }

                        if (tspHadEditableKeyFocusV73)
                        {
                            tspWindowV73->setKeyFocusWidget(nullptr);
                            Log(Debug::Info)
                                << "TSP_PRECISE_EDITBOX_CLICK_051_V73 action=leave-text";
                        }
                    }

'''
ctl2, n = pat_ctl.subn(repl_ctl, ctl, count=1)
if n != 1:
    raise RuntimeError(f"failed to replace V72 broad click-to-text block (matches={n})")

# Final assertions before touching either file.
if "TSP_FOCUSED_EDITBOX_TEXT_051_V72" in inp2:
    raise RuntimeError("old V72 input fallback remains")
if "TSP_CLICK_EDITBOX_TO_TEXT_051_V72" in ctl2:
    raise RuntimeError("old V72 controller click block remains")
if inp2.count("TSP_TEXT_ENTRY_SDL_ONLY_051_V73") != 1:
    raise RuntimeError("V73 input marker assertion failed")
if ctl2.count("TSP_PRECISE_EDITBOX_CLICK_051_V73") != 1:
    raise RuntimeError("V73 controller marker assertion failed")

# Transactional two-file write.
temps = []
try:
    for path, data in ((input_cpp, inp2), (controller_cpp, ctl2)):
        tmp = Path(str(path) + ".v73-safe.tmp")
        tmp.write_text(data, encoding="utf-8")
        temps.append((path, tmp))
    for path, tmp in temps:
        os.replace(tmp, path)
finally:
    for _, tmp in temps:
        try:
            tmp.unlink()
        except FileNotFoundError:
            pass

print("V73 surgical source patch: PASS")
PY

"${DOCKER[@]}" cp "$PATCHER" "$CONTAINER:/root/tsp_v73_safe_patch.py"

# Save critical pre-patch hashes on the host so we can compare after build.
MAP_HASHES_BEFORE="$("${DOCKER[@]}" exec "$CONTAINER" bash -lc "sha256sum \
 '$SRC/apps/openmw/mwrender/localmap.cpp' \
 '$SRC/apps/openmw/mwgui/mapwindow.cpp' \
 '$GLSRC/src/gl/texture_read.c'")"

"${DOCKER[@]}" exec -i \
    -e V73_SRC="$SRC" \
    -e V73_BUILD="$BUILD" \
    -e V73_STAMP="$STAMP" \
    "$CONTAINER" bash -s <<'CONTAINER'
set -Eeuo pipefail
trap 'rc=$?; echo; echo "ERROR: V73 container step stopped at line $LINENO (status $rc)." >&2' ERR

SRC="$V73_SRC"
BUILD="$V73_BUILD"
STAMP="$V73_STAMP"
BACK="/root/.tsp-v73-controls-backups/$STAMP"
INPUT="$SRC/apps/openmw/mwinput/inputmanagerimp.cpp"
CONTROLLER="$SRC/apps/openmw/mwinput/controllermanager.cpp"

mkdir -p "$BACK"
cp -a "$INPUT" "$BACK/inputmanagerimp.cpp.before-v73"
cp -a "$CONTROLLER" "$BACK/controllermanager.cpp.before-v73"
cp -a "$BUILD/openmw" "$BACK/openmw.before-v73"
echo "Source/build backup: $BACK"

python3 /root/tsp_v73_safe_patch.py "$SRC"

echo
echo "===== PATCHED MARKERS ====="
grep -n "TSP_TEXT_ENTRY_SDL_ONLY_051_V73" "$INPUT"
grep -n "TSP_PRECISE_EDITBOX_CLICK_051_V73" "$CONTROLLER"

echo
echo "===== POST-PATCH BUILD DRY RUN ====="
DRY="$(cmake --build "$BUILD" --target openmw -- -n 2>&1)"
printf '%s\n' "$DRY"

# A controls-only patch must not cause map objects to rebuild.
if printf '%s\n' "$DRY" | grep -Eq 'localmap\.cpp|mapwindow\.cpp'; then
    echo "ERROR: controls build would also rebuild map source; refusing." >&2
    exit 30
fi

# Any C++ compile shown by Ninja must be one of the two intended controls TUs.
BAD_COMPILES="$(printf '%s\n' "$DRY" | grep 'Building CXX object' | grep -Ev 'mwinput/(inputmanagerimp|controllermanager)\.cpp\.o' || true)"
if [ -n "$BAD_COMPILES" ]; then
    echo "ERROR: controls build would compile unexpected C++ source:" >&2
    printf '%s\n' "$BAD_COMPILES" >&2
    exit 31
fi

echo
echo "===== INCREMENTAL OPENMW BUILD ====="
cmake --build "$BUILD" --target openmw -- -j2

test -s "$BUILD/openmw" || { echo "ERROR: OpenMW binary missing after build." >&2; exit 32; }
readelf -h "$BUILD/openmw" | grep -E 'Class:|Machine:|Type:'
readelf -h "$BUILD/openmw" | grep -q 'AArch64' || { echo "ERROR: result is not AArch64." >&2; exit 33; }

grep -a -q 'TSP_PRECISE_EDITBOX_CLICK_051_V73' "$BUILD/openmw" || {
    echo "ERROR: V73 runtime marker string not found in built binary." >&2
    exit 34
}

sha256sum "$BUILD/openmw"
echo "CHUNK 1 container build: PASS"
CONTAINER

MAP_HASHES_AFTER="$("${DOCKER[@]}" exec "$CONTAINER" bash -lc "sha256sum \
 '$SRC/apps/openmw/mwrender/localmap.cpp' \
 '$SRC/apps/openmw/mwgui/mapwindow.cpp' \
 '$GLSRC/src/gl/texture_read.c'")"

if [ "$MAP_HASHES_BEFORE" != "$MAP_HASHES_AFTER" ]; then
    echo "ERROR: one or more protected map/GL4ES source files changed during the controls operation." >&2
    echo "BEFORE:" >&2; printf '%s\n' "$MAP_HASHES_BEFORE" >&2
    echo "AFTER:" >&2;  printf '%s\n' "$MAP_HASHES_AFTER" >&2
    exit 40
fi

echo
echo "Protected map/GL4ES source hashes unchanged: PASS"

rm -f "$OUTBIN" "$MANIFEST"
"${DOCKER[@]}" cp "$CONTAINER:$BUILD/openmw" "$OUTBIN"
chmod 755 "$OUTBIN"

test -s "$OUTBIN" || fail "exported binary missing"
readelf -h "$OUTBIN" | grep -q 'AArch64' || fail "exported binary is not AArch64"
grep -a -q 'TSP_PRECISE_EDITBOX_CLICK_051_V73' "$OUTBIN" || fail "exported binary lacks V73 runtime marker"

OUT_HASH="$(sha256sum "$OUTBIN" | awk '{print $1}')"
CONTAINER_HASH="$("${DOCKER[@]}" exec "$CONTAINER" sha256sum "$BUILD/openmw" | awk '{print $1}')"
[ "$OUT_HASH" = "$CONTAINER_HASH" ] || fail "container/export SHA256 mismatch"

{
    echo "V73_CONTROLS_SAFE_MANIFEST=1"
    echo "CREATED=$STAMP"
    echo "BASELINE_LIVE_SHA256=$LIVE_HASH"
    echo "BASELINE_BUILD_SHA256=$BUILD_HASH"
    echo "OUTPUT_SHA256=$OUT_HASH"
    echo "OUTPUT_BINARY=$OUTBIN"
    echo "LIVE_BINARY=$LIVE_BIN"
    echo "DEVICE=$DEVICE"
    echo
    echo "PROTECTED_SOURCE_HASHES_BEFORE_AFTER_IDENTICAL=1"
    printf '%s\n' "$MAP_HASHES_AFTER"
} > "$MANIFEST"

echo
echo "===== CHUNK 1 COMPLETE ====="
ls -lh "$OUTBIN" "$MANIFEST"
echo "SHA256: $OUT_HASH"
echo "No TSP files were changed."
echo "Run CHUNK 2 only after this chunk passes."
