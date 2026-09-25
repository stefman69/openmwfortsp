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
if ctl.count("// TSP_CLICK_EDITBOX_TO_TEXT_051_V72") != 1:
    raise RuntimeError("expected exactly one TSP_CLICK_EDITBOX_TO_TEXT_051_V72 patch comment")
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
if ctl2.count("// TSP_PRECISE_EDITBOX_CLICK_051_V73") != 1:
    raise RuntimeError("V73 controller patch-comment assertion failed")

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
