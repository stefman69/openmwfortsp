import sys, io, os, time

SRC = os.environ.get("TSPSRC", "/root/openmw-0.51-tsp-src")
CM  = os.path.join(SRC, "apps/openmw/mwinput/controllermanager.cpp")

MARK = "TSP_PROBE_V39"
EDITS = []

EDITS.append((CM, "ctor: dump the mapping SDL actually resolved", """                if (const char* name = SDL_GameControllerNameForIndex(i))
                    Log(Debug::Info) << "Detected game controller: " << name;
                else
                    Log(Debug::Warning) << "Detected game controller without a name: " << SDL_GetError();""",
"""                if (const char* name = SDL_GameControllerNameForIndex(i))
                    Log(Debug::Info) << "Detected game controller: " << name;
                else
                    Log(Debug::Warning) << "Detected game controller without a name: " << SDL_GetError();

                // TSP_PROBE_V39 -- measurement only. Prints the mapping string SDL
                // resolved for this pad, so we can see whether guide:b8 survived
                // OpenMW's own SDL_GameControllerAddMappingsFromFile() calls.
                if (SDL_GameController* tspProbeCntrl = mBindingsManager->getControllerOrNull())
                {
                    char* tspProbeMap = SDL_GameControllerMapping(tspProbeCntrl);
                    Log(Debug::Warning) << "TSP_PROBE_V39 mapping="
                                        << (tspProbeMap ? tspProbeMap : "(null)");
                    if (tspProbeMap)
                        SDL_free(tspProbeMap);

                    const SDL_GameControllerButtonBind tspProbeBind
                        = SDL_GameControllerGetBindForButton(tspProbeCntrl, SDL_CONTROLLER_BUTTON_GUIDE);
                    Log(Debug::Warning) << "TSP_PROBE_V39 guideBindType="
                                        << static_cast<int>(tspProbeBind.bindType)
                                        << " guideButton="
                                        << (tspProbeBind.bindType == SDL_CONTROLLER_BINDTYPE_BUTTON
                                                   ? tspProbeBind.value.button
                                                   : -1);
                }
                else
                {
                    Log(Debug::Warning) << "TSP_PROBE_V39 mapping=(no-controller-open)";
                }"""))

EDITS.append((CM, "buttonPressed: trace every button number", """    void ControllerManager::buttonPressed(int deviceID, const SDL_ControllerButtonEvent& arg)
    {
        if (!Settings::input().mEnableController || mBindingsManager->isDetectingBindingState())
            return;""",
"""    void ControllerManager::buttonPressed(int deviceID, const SDL_ControllerButtonEvent& arg)
    {
        // TSP_PROBE_V39 -- unconditional, before every gate, so silence is impossible
        // to reach: if OpenMW receives the button at all, this line is written.
        Log(Debug::Warning) << "TSP_PROBE_V39 buttonPressed=" << static_cast<int>(arg.button)
                            << " gui="
                            << (MWBase::Environment::get().getWindowManager()->isGuiMode() ? 1 : 0);

        if (!Settings::input().mEnableController || mBindingsManager->isDetectingBindingState())
            return;"""))

def balanced(text, label):
    for o, c in {'{': '}', '(': ')'}.items():
        if text.count(o) != text.count(c):
            print("FAIL: imbalance after %s: %s=%d %s=%d" % (label, o, text.count(o), c, text.count(c)))
            return False
    return True

files = {}
for path, label, old, new in EDITS:
    if path not in files:
        if not os.path.exists(path):
            print("FAIL: missing file %s" % path); sys.exit(1)
        with io.open(path, encoding="utf-8") as fh:
            files[path] = fh.read()

pending = dict(files)
applied = skipped = 0
for path, label, old, new in EDITS:
    text = pending[path]
    if new in text:
        print("SKIP (already applied): %s" % label); skipped += 1; continue
    n = text.count(old)
    if n != 1:
        print("FAIL: anchor for '%s' matched %d times (need exactly 1)" % (label, n)); sys.exit(1)
    pending[path] = text.replace(old, new, 1)
    print("OK: %s" % label); applied += 1

for path, text in pending.items():
    if not balanced(text, os.path.basename(path)):
        sys.exit(1)

if applied == 0:
    print("Nothing to do - all %d edits already present." % skipped)
else:
    stamp = time.strftime("%Y%m%d-%H%M%S")
    for path, text in pending.items():
        if text != files[path]:
            bak = "%s.before-probe-v39-%s" % (path, stamp)
            with io.open(bak, "w", encoding="utf-8", newline="") as fh:
                fh.write(files[path])
            with io.open(path, "w", encoding="utf-8", newline="") as fh:
                fh.write(text)
            print("wrote %s (backup: %s)" % (path, os.path.basename(bak)))

for path in pending:
    with io.open(path, encoding="utf-8") as fh:
        if MARK not in fh.read():
            print("FAIL: marker missing after write"); sys.exit(1)
print("VERIFIED: probe v39 present (%d applied, %d already present)" % (applied, skipped))
