#!/usr/bin/env bash
# In-place repair for Manager V2.1 repeat-launch black screen/hang.
# Patches only the already-extracted Manager source and reruns its installer.

set -u -o pipefail

MODE="${1:-install}"
TARGET="${OPENMW51_MANAGER_SOURCE_DIR:-$HOME/Downloads/openmw51-tsp-manager-v2.1}"
CPP="$TARGET/openmw51_launcher_manager_v2.cpp"
INSTALLER="$TARGET/build_install_openmw51_tsp_manager_v2.sh"
WRAPPER="$TARGET/OpenMW_51_Manager_v2.sh"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="$TARGET/repair-backups/repeat-launch-$STAMP"
HOST_OUTPUT="$HOME/Downloads"
[ -d "$HOST_OUTPUT" ] || HOST_OUTPUT="$(dirname "$TARGET")"
LOG="$HOST_OUTPUT/openmw51-manager-v2.1-repeat-launch-repair-$STAMP.log"
STAGE="$(mktemp -d "$HOST_OUTPUT/.manager-repeat-repair.XXXXXX")" || exit 9

OLD_CPP="ea8d32cd1decd94651c8bccbb4553819600aebddf61f51a16cbef427da9dbf62"
OLD_INSTALLER="28f19b642e21b546ba9b25dafbe1c4ec51db39b4d852500ec9a814bde56f0f3b"
OLD_WRAPPER="ff782f8ec7d3dfdc6a0304092d9062437409264bee9f1ef6ca1830549f47c600"
NEW_CPP="5406b48d250253ee03d9540b139327d765b3b45a75205b93dd1b44db991dc416"
NEW_INSTALLER="68c576b73e916711dd8ec32d1aa12cdda5fb8d10a85dce6f8687841f5e7cfe8c"
NEW_WRAPPER="56c84db28473eb7c7de47b573b203e329671eccaf42375f14c85819e6b9b70e4"

cleanup() { [ -n "$STAGE" ] && [ -d "$STAGE" ] && rm -rf "$STAGE"; }
trap cleanup EXIT
fail() { echo "ERROR: $*" >&2; exit 1; }
hash_of() { sha256sum "$1" | awk '{print $1}'; }

exec > >(tee "$LOG") 2>&1

echo "============================================================"
echo "OPENMW 0.51 MANAGER V2.1 — REPEAT-LAUNCH REPAIR"
echo "============================================================"
echo "Patches the existing Manager V2.1 source in place."
echo "No new Ports launcher is created. Morrowind_51.sh is unchanged."
echo
echo "Fixes: clean system-SDL environment, software KMSDRM renderer,"
echo "single-instance cleanup, first-frame readiness, and an 8-second"
echo "startup watchdog with one clean retry."
echo "============================================================"

command -v python3 >/dev/null 2>&1 || fail "python3 is missing"
command -v sha256sum >/dev/null 2>&1 || fail "sha256sum is missing"
for path in "$CPP" "$INSTALLER" "$WRAPPER"; do
    [ -s "$path" ] || fail "required Manager V2.1 file missing: $path"
done

cpp_sha="$(hash_of "$CPP")"
installer_sha="$(hash_of "$INSTALLER")"
wrapper_sha="$(hash_of "$WRAPPER")"
if [ "$cpp_sha" = "$NEW_CPP" ] && [ "$installer_sha" = "$NEW_INSTALLER" ] && [ "$wrapper_sha" = "$NEW_WRAPPER" ]; then
    echo "PASS repeat-launch source repair is already present"
    if [ "$MODE" = patch-only ]; then exit 0; fi
    [ "$MODE" = install ] || fail "usage: $0 [install|patch-only]"
    chmod +x "$INSTALLER"
    "$INSTALLER"
    rc=$?
    echo "Installer exit code: $rc"
    echo "Repair/install log: $LOG"
    exit "$rc"
fi
if [ "$cpp_sha" != "$OLD_CPP" ] || [ "$installer_sha" != "$OLD_INSTALLER" ] || [ "$wrapper_sha" != "$OLD_WRAPPER" ]; then
    echo "C++:      $cpp_sha" >&2
    echo "Installer: $installer_sha" >&2
    echo "Wrapper:   $wrapper_sha" >&2
    fail "source is neither the exact installed V2.1 baseline nor the exact repaired state; nothing changed"
fi
echo "PASS exact installed V2.1 source hashes"

if ! python3 - "$CPP" "$INSTALLER" "$WRAPPER" "$STAGE" <<'PY'
import hashlib
import os
import sys
from pathlib import Path

cpp_path, installer_path, wrapper_path = map(Path, sys.argv[1:4])
stage = Path(sys.argv[4])

def replace_once(text, old, new, label):
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f"{label}: anchor matches={count}, expected exactly 1")
    return text.replace(old, new, 1)

cpp = cpp_path.read_text(encoding="utf-8")
cpp = replace_once(cpp,
'''    explicit Framebuffer(const std::string&)
    {
        const char* overridePath = std::getenv("OPENMW51_MANAGER_SDL2");
''',
'''    explicit Framebuffer(const std::string&)
    {
        std::cerr << "Manager display milestone: loading SDL2\\n";
        const char* overridePath = std::getenv("OPENMW51_MANAGER_SDL2");
''', "C++ SDL-load milestone")
cpp = replace_once(cpp,
'''        libraries.insert(libraries.end(), {
            "libSDL2-2.0.so.0", "libSDL2.so.0", "libSDL2.so",
            "/mnt/SDCARD/data/ports/openmw51/lib/libSDL2-2.0.so.0",
            "/mnt/SDCARD/data/ports/openmw51/lib/libSDL2.so.0"});
''',
'''        libraries.insert(libraries.end(), {
            "libSDL2-2.0.so.0", "libSDL2.so.0", "libSDL2.so"});
''', "C++ system-only SDL candidates")
cpp = replace_once(cpp,
'''        if (!mLibrary)
        {
            const char* error=dlerror();
            throw std::runtime_error(std::string("SDL2 load failed: ")+(error&&*error?error:"library not found"));
        }

        try
''',
'''        if (!mLibrary)
        {
            const char* error=dlerror();
            throw std::runtime_error(std::string("SDL2 load failed: ")+(error&&*error?error:"library not found"));
        }
        std::cerr << "Manager display milestone: SDL2 loaded from " << mLibraryName << "\\n";

        try
''', "C++ loaded milestone")
cpp = replace_once(cpp,
'''            mSetHint("SDL_RENDER_SCALE_QUALITY", "0");
            if (mInit(0x00004021u) != 0) fail("SDL_Init"); // VIDEO | TIMER | EVENTS
            mInitialized = true;
            constexpr int centered = 0x2fff0000;
            constexpr uint32_t fullscreenDesktopHighDpi = 0x00003001u;
            mWindow = mCreateWindow("OpenMW 0.51 Manager", centered, centered, width(), height(), fullscreenDesktopHighDpi);
            if (!mWindow) mWindow = mCreateWindow("OpenMW 0.51 Manager", centered, centered, width(), height(), 0x00000004u);
            if (!mWindow) fail("SDL_CreateWindow");
            mRenderer = mCreateRenderer(mWindow, -1, 0x00000006u); // ACCELERATED | PRESENTVSYNC
            if (!mRenderer) mRenderer = mCreateRenderer(mWindow, -1, 0x00000001u); // SOFTWARE fallback
            if (!mRenderer) fail("SDL_CreateRenderer");
''',
'''            mSetHint("SDL_RENDER_DRIVER", "software");
            mSetHint("SDL_RENDER_SCALE_QUALITY", "0");
            std::cerr << "Manager display milestone: SDL_Init starting\\n";
            if (mInit(0x00004021u) != 0) fail("SDL_Init"); // VIDEO | TIMER | EVENTS
            mInitialized = true;
            std::cerr << "Manager display milestone: SDL_Init complete\\n";
            constexpr int centered = 0x2fff0000;
            constexpr uint32_t fullscreenDesktopHighDpi = 0x00003001u;
            mWindow = mCreateWindow("OpenMW 0.51 Manager", centered, centered, width(), height(), fullscreenDesktopHighDpi);
            if (!mWindow) mWindow = mCreateWindow("OpenMW 0.51 Manager", centered, centered, width(), height(), 0x00000004u);
            if (!mWindow) fail("SDL_CreateWindow");
            std::cerr << "Manager display milestone: SDL window complete\\n";
            mRenderer = mCreateRenderer(mWindow, -1, 0x00000001u); // SOFTWARE: do not load GL4ES
            if (!mRenderer) fail("SDL_CreateRenderer");
            std::cerr << "Manager display milestone: software renderer complete\\n";
''', "C++ software renderer")
cpp = replace_once(cpp,
'''        fs::path l=a.root/"launcher";a.request=l/"request";a.statusFile=l/"status.conf";a.modsFile=l/"modplan.tsv";a.uiFile=l/"ui-state.conf";a.resultFile=l/"last-result.txt";
        loadUi(a);refresh(a);Framebuffer fb(getenv("OPENMW51_LAUNCHER_FB")?getenv("OPENMW51_LAUNCHER_FB"):"/dev/fb0");Inputs in;bool dirty=true;auto last=std::chrono::steady_clock::now();
        while(!a.quit){Action q=in.wait(80);if(q!=Action::None){handle(a,q);dirty=true;}auto now=std::chrono::steady_clock::now();if(now-last>std::chrono::seconds(3)){refresh(a);last=now;dirty=true;}if(dirty){render(fb,a);dirty=false;}}
''',
'''        fs::path l=a.root/"launcher";a.request=l/"request";a.statusFile=l/"status.conf";a.modsFile=l/"modplan.tsv";a.uiFile=l/"ui-state.conf";a.resultFile=l/"last-result.txt";fs::path readyFile=l/"ui-ready";
        std::error_code readyError;fs::remove(readyFile,readyError);
        loadUi(a);refresh(a);Framebuffer fb(getenv("OPENMW51_LAUNCHER_FB")?getenv("OPENMW51_LAUNCHER_FB"):"/dev/fb0");Inputs in;bool dirty=true;auto last=std::chrono::steady_clock::now();
        bool publishedReady=false;
        while(!a.quit){Action q=in.wait(80);if(q!=Action::None){handle(a,q);dirty=true;}auto now=std::chrono::steady_clock::now();if(now-last>std::chrono::seconds(3)){refresh(a);last=now;dirty=true;}if(dirty){render(fb,a);if(!publishedReady){writeAtomic(readyFile,"ready");publishedReady=true;}dirty=false;}}
''', "C++ first-frame readiness")

installer = installer_path.read_text(encoding="utf-8")
installer = replace_once(installer,
'''echo '===== DISPLAY / SDL ====='; cat /proc/fb 2>/dev/null || true; ls -l /dev/fb* /dev/dri/* 2>/dev/null || true
for d in /sys/class/graphics/fb*; do''',
'''echo '===== DISPLAY / SDL ====='; cat /proc/fb 2>/dev/null || true; ls -l /dev/fb* /dev/dri/* 2>/dev/null || true
echo '===== MANAGER PROCESSES / LOCKS ====='; ps w 2>/dev/null | grep -E '[o]penmw51-manager-v2|OpenMW_51_Manager_v2' || true; ls -l "$ROOT/launcher/manager-v2-wrapper.pid" "$ROOT/launcher/manager-v2-ui.pid" "$ROOT/launcher/ui-ready" 2>/dev/null || true; for f in "$ROOT/launcher/manager-v2-wrapper.pid" "$ROOT/launcher/manager-v2-ui.pid" "$ROOT/launcher/ui-ready"; do [ -f "$f" ] && { echo "[$f]"; cat "$f" 2>/dev/null || true; }; done
for d in /sys/class/graphics/fb*; do''', "installer process diagnostics")

wrapper = wrapper_path.read_text(encoding="utf-8")
wrapper = replace_once(wrapper,
'''LOG="$ROOT/launcher/manager-v2.log"
PLAY=""
''',
'''LOG="$ROOT/launcher/manager-v2.log"
READY="$ROOT/launcher/ui-ready"
PIDFILE="$ROOT/launcher/manager-v2-wrapper.pid"
CHILDPID="$ROOT/launcher/manager-v2-ui.pid"
PLAY=""
UI_PID=""
''', "wrapper lifecycle variables")
wrapper = replace_once(wrapper,
'''echo "===== OpenMW 0.51 Manager V2.1 started: $(date) ====="

export PORT_DIR="$ROOT"
''',
'''echo "===== OpenMW 0.51 Manager V2.1 started: $(date) ====="

cleanup_manager() {
    if [ -n "$UI_PID" ] && kill -0 "$UI_PID" 2>/dev/null; then
        kill "$UI_PID" 2>/dev/null || true
        sleep 0.2
        kill -9 "$UI_PID" 2>/dev/null || true
        wait "$UI_PID" 2>/dev/null || true
    fi
    if [ -f "$PIDFILE" ] && [ "$(cat "$PIDFILE" 2>/dev/null)" = "$$" ]; then
        rm -f "$PIDFILE"
    fi
    rm -f "$CHILDPID" "$READY"
}
trap cleanup_manager EXIT
trap 'exit 130' HUP INT TERM

if [ -s "$PIDFILE" ]; then
    old_wrapper="$(cat "$PIDFILE" 2>/dev/null)"
    case "$old_wrapper" in
        ''|*[!0-9]*) ;;
        *)
            if kill -0 "$old_wrapper" 2>/dev/null; then
                echo "Stopping prior Manager wrapper PID $old_wrapper"
                kill "$old_wrapper" 2>/dev/null || true
                sleep 0.3
                kill -9 "$old_wrapper" 2>/dev/null || true
            fi
            ;;
    esac
fi
printf '%s\\n' "$$" > "$PIDFILE"

# Clean up a pre-repair manager that hung before it could accept controller input.
for old_ui in $(pidof openmw51-manager-v2 2>/dev/null); do
    case "$old_ui" in
        ''|*[!0-9]*) continue ;;
    esac
    echo "Stopping stale Manager UI PID $old_ui"
    kill "$old_ui" 2>/dev/null || true
    sleep 0.2
    kill -9 "$old_ui" 2>/dev/null || true
done

export PORT_DIR="$ROOT"
''', "wrapper lifecycle setup")
wrapper = replace_once(wrapper,
'''set -u
# Exact display environment proven by openmw-navmesh-progress.
export LD_LIBRARY_PATH="/usr/trimui/lib:/mnt/SDCARD/System/lib:$ROOT/lib:$ROOT/libs:$ROOT/lib/aarch64"
unset LD_PRELOAD
''',
'''set -u
# Manager is self-contained apart from libc/libdl. Do not put OpenMW's GL4ES
# directory in this UI process: its accelerated KMSDRM teardown poisoned the
# next SDL initialization in the repeat-launch trace.
export LD_LIBRARY_PATH="/usr/trimui/lib:/mnt/SDCARD/System/lib:/usr/lib:/lib:/lib64"
export SDL_VIDEODRIVER="kmsdrm"
export SDL_RENDER_DRIVER="software"
unset LD_PRELOAD
''', "wrapper clean SDL environment")
wrapper = replace_once(wrapper,
'''while true; do
    "$BACKEND" status || true
    rm -f "$REQUEST"
    "$BIN"
    ui_rc=$?
''',
'''run_manager_ui() {
    rm -f "$READY" "$CHILDPID"
    "$BIN" &
    UI_PID=$!
    printf '%s\\n' "$UI_PID" > "$CHILDPID"
    ready=0
    ticks=0
    while [ "$ticks" -lt 80 ]; do
        if [ -s "$READY" ]; then ready=1; break; fi
        if ! kill -0 "$UI_PID" 2>/dev/null; then break; fi
        sleep 0.1
        ticks=$((ticks + 1))
    done
    if [ "$ready" -ne 1 ] && kill -0 "$UI_PID" 2>/dev/null; then
        echo "ERROR manager SDL startup exceeded 8 seconds; terminating PID $UI_PID"
        kill "$UI_PID" 2>/dev/null || true
        sleep 0.3
        kill -9 "$UI_PID" 2>/dev/null || true
        wait "$UI_PID" 2>/dev/null || true
        UI_PID=""
        rm -f "$CHILDPID" "$READY"
        return 124
    fi
    wait "$UI_PID"
    rc=$?
    UI_PID=""
    rm -f "$CHILDPID" "$READY"
    return "$rc"
}

while true; do
    "$BACKEND" status || true
    rm -f "$REQUEST"
    run_manager_ui
    ui_rc=$?
    if [ "$ui_rc" -eq 124 ]; then
        echo "INFO retrying Manager UI once after bounded SDL startup cleanup"
        sleep 0.5
        run_manager_ui
        ui_rc=$?
    fi
''', "wrapper supervised UI launch")

outputs = {
    "openmw51_launcher_manager_v2.cpp": cpp,
    "build_install_openmw51_tsp_manager_v2.sh": installer,
    "OpenMW_51_Manager_v2.sh": wrapper,
}
expected = {
    "openmw51_launcher_manager_v2.cpp": "5406b48d250253ee03d9540b139327d765b3b45a75205b93dd1b44db991dc416",
    "build_install_openmw51_tsp_manager_v2.sh": "68c576b73e916711dd8ec32d1aa12cdda5fb8d10a85dce6f8687841f5e7cfe8c",
    "OpenMW_51_Manager_v2.sh": "56c84db28473eb7c7de47b573b203e329671eccaf42375f14c85819e6b9b70e4",
}
for name, text in outputs.items():
    actual = hashlib.sha256(text.encode()).hexdigest()
    if actual != expected[name]:
        raise RuntimeError(f"{name}: staged SHA {actual} != tested {expected[name]}")
    target = stage / name
    with open(target, "w", encoding="utf-8", newline="\n") as out:
        out.write(text)
        out.flush()
        os.fsync(out.fileno())
print("PASS structural patch selftest produced all three exact tested files")
PY
then
    fail "structural patch selftest failed before source mutation; nothing changed"
fi

bash -n "$STAGE/build_install_openmw51_tsp_manager_v2.sh" || fail "staged installer syntax failed; nothing changed"
bash -n "$STAGE/OpenMW_51_Manager_v2.sh" || fail "staged wrapper syntax failed; nothing changed"
if command -v g++ >/dev/null 2>&1; then
    if ! g++ -std=c++17 -O2 -Wall -Wextra -Wpedantic -Werror "$STAGE/openmw51_launcher_manager_v2.cpp" -o "$STAGE/manager-host-test" -ldl; then
        fail "staged C++ compile failed; nothing changed"
    fi
    "$STAGE/manager-host-test" --selftest | grep -Fq OPENMW51_MANAGER_V2_SELFTEST_PASS || fail "staged C++ selftest failed; nothing changed"
    echo "PASS staged warning-clean C++ compile + non-display behavior selftest"
    echo "INFO SDL presentation is device-only; Ubuntu is not required to provide SDL2"
else
    echo "INFO host g++ unavailable; the existing installer still performs the mandatory ARM64 Docker build"
fi

mkdir -p "$BACKUP" || fail "could not create source backup"
cp -p "$CPP" "$BACKUP/" || fail "could not back up C++ source"
cp -p "$INSTALLER" "$BACKUP/" || fail "could not back up installer"
cp -p "$WRAPPER" "$BACKUP/" || fail "could not back up wrapper"
echo "PASS exact pre-repair source backup: $BACKUP"

restore_sources() {
    cp -p "$BACKUP/openmw51_launcher_manager_v2.cpp" "$CPP" 2>/dev/null || true
    cp -p "$BACKUP/build_install_openmw51_tsp_manager_v2.sh" "$INSTALLER" 2>/dev/null || true
    cp -p "$BACKUP/OpenMW_51_Manager_v2.sh" "$WRAPPER" 2>/dev/null || true
}

if ! install -m 644 "$STAGE/openmw51_launcher_manager_v2.cpp" "$CPP" \
    || ! install -m 755 "$STAGE/build_install_openmw51_tsp_manager_v2.sh" "$INSTALLER" \
    || ! install -m 755 "$STAGE/OpenMW_51_Manager_v2.sh" "$WRAPPER"; then
    restore_sources
    fail "source installation failed; exact source backup restored"
fi

new_cpp_sha="$(hash_of "$CPP")"
new_installer_sha="$(hash_of "$INSTALLER")"
new_wrapper_sha="$(hash_of "$WRAPPER")"
if [ "$new_cpp_sha" != "$NEW_CPP" ] || [ "$new_installer_sha" != "$NEW_INSTALLER" ] || [ "$new_wrapper_sha" != "$NEW_WRAPPER" ]; then
    restore_sources
    fail "installed source hashes differ from tested files; exact source backup restored"
fi
echo "PASS exact repeat-launch source installed"
sha256sum "$CPP" "$INSTALLER" "$WRAPPER"

if [ "$MODE" = patch-only ]; then
    echo "INFO patch-only requested; device installer was not started"
    echo "Repair log: $LOG"
    exit 0
fi
[ "$MODE" = install ] || fail "usage: $0 [install|patch-only]"

chmod +x "$INSTALLER"
"$INSTALLER"
rc=$?
echo "Installer exit code: $rc"
echo "Repair/install log: $LOG"
exit "$rc"
