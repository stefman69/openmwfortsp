#!/usr/bin/env bash
# In-place repair for the Manager V2.1 SDL startup/display mistake.
# Reuses the proven openmw-navmesh-progress runtime arrangement.

set -u -o pipefail

MODE="${1:-install}"
TARGET="${OPENMW51_MANAGER_SOURCE_DIR:-$HOME/Downloads/openmw51-tsp-manager-v2.1}"
CPP="$TARGET/openmw51_launcher_manager_v2.cpp"
INSTALLER="$TARGET/build_install_openmw51_tsp_manager_v2.sh"
WRAPPER="$TARGET/OpenMW_51_Manager_v2.sh"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="$TARGET/repair-backups/proven-system-sdl-$STAMP"
HOST_OUTPUT="$HOME/Downloads"
[ -d "$HOST_OUTPUT" ] || HOST_OUTPUT="$(dirname "$TARGET")"
LOG="$HOST_OUTPUT/openmw51-manager-v2.1-system-sdl-repair-$STAMP.log"

OLD_CPP="2689351e36f92a64c6dec037b1d5d6f14cb1b3f74f33a85a51caa4f6fc3ba482"
OLD_INSTALLER="42535b68afd4d10fa5134e886dd9b76e4afb0fb7d4f0a7286e3981e8ab2a6404"
OLD_WRAPPER="2d900fbcfd598a796c1fcbfcb83f143c747e1d7eb76da8ba5f2919e6a71f5016"
NEW_CPP="ea8d32cd1decd94651c8bccbb4553819600aebddf61f51a16cbef427da9dbf62"
NEW_INSTALLER="28f19b642e21b546ba9b25dafbe1c4ec51db39b4d852500ec9a814bde56f0f3b"
NEW_WRAPPER="ff782f8ec7d3dfdc6a0304092d9062437409264bee9f1ef6ca1830549f47c600"

fail() { echo "ERROR: $*" >&2; exit 1; }
hash_of() { sha256sum "$1" | awk '{print $1}'; }

exec > >(tee "$LOG") 2>&1

echo "============================================================"
echo "OPENMW 0.51 MANAGER V2.1 — PROVEN SYSTEM-SDL REPAIR"
echo "============================================================"
echo "Edits the existing extracted Manager V2.1 source in place."
echo "Uses the working navmesh UI policy: TrimUI system SDL first,"
echo "no inherited LD_PRELOAD, and accelerated renderer first."
echo "============================================================"

command -v python3 >/dev/null 2>&1 || fail "python3 is missing"
command -v sha256sum >/dev/null 2>&1 || fail "sha256sum is missing"
for path in "$CPP" "$INSTALLER" "$WRAPPER"; do
    [ -s "$path" ] || fail "required Manager V2.1 file missing: $path"
done

cpp_sha="$(hash_of "$CPP")"
installer_sha="$(hash_of "$INSTALLER")"
wrapper_sha="$(hash_of "$WRAPPER")"

if [ "$cpp_sha" != "$OLD_CPP" ]; then
    fail "unexpected C++ source SHA: $cpp_sha (expected exact installed-package source $OLD_CPP)"
fi
if [ "$installer_sha" != "$OLD_INSTALLER" ]; then
    fail "unexpected installer SHA: $installer_sha (expected $OLD_INSTALLER)"
fi
if [ "$wrapper_sha" != "$OLD_WRAPPER" ]; then
    fail "unexpected wrapper SHA: $wrapper_sha (expected $OLD_WRAPPER)"
fi
echo "PASS exact broken V2.1 source hashes"

mkdir -p "$BACKUP" || fail "could not create repair backup"
cp -p "$CPP" "$BACKUP/" || fail "could not back up C++ source"
cp -p "$INSTALLER" "$BACKUP/" || fail "could not back up installer"
cp -p "$WRAPPER" "$BACKUP/" || fail "could not back up wrapper"
echo "PASS repair backup: $BACKUP"

restore_sources() {
    cp -p "$BACKUP/openmw51_launcher_manager_v2.cpp" "$CPP" 2>/dev/null || true
    cp -p "$BACKUP/build_install_openmw51_tsp_manager_v2.sh" "$INSTALLER" 2>/dev/null || true
    cp -p "$BACKUP/OpenMW_51_Manager_v2.sh" "$WRAPPER" 2>/dev/null || true
}

if ! python3 - "$CPP" "$INSTALLER" "$WRAPPER" <<'PY'
import os
import sys
from pathlib import Path

cpp_path, installer_path, wrapper_path = map(Path, sys.argv[1:])
sources = {
    cpp_path: cpp_path.read_text(encoding="utf-8"),
    installer_path: installer_path.read_text(encoding="utf-8"),
    wrapper_path: wrapper_path.read_text(encoding="utf-8"),
}

replacements = {
    cpp_path: [
        (
'''            mSetHint("SDL_RENDER_DRIVER", "software");
            mSetHint("SDL_RENDER_SCALE_QUALITY", "0");
            if (mInit(0x00000020u) != 0) fail("SDL_Init"); // SDL_INIT_VIDEO
            mInitialized = true;
            constexpr int centered = 0x2fff0000;
            constexpr uint32_t fullscreenDesktop = 0x00001001u;
            mWindow = mCreateWindow("OpenMW 0.51 Manager", centered, centered, width(), height(), fullscreenDesktop);
            if (!mWindow) fail("SDL_CreateWindow");
            mRenderer = mCreateRenderer(mWindow, -1, 0x00000001u); // SDL_RENDERER_SOFTWARE
            if (!mRenderer) mRenderer = mCreateRenderer(mWindow, -1, 0u);
''',
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
'''
        ),
    ],
    installer_path: [
        (
'''        SDL_VIDEODRIVER=dummy "$TMP/manager-host-test" --display-selftest | grep -Fq OPENMW51_MANAGER_V2_SDL_DISPLAY_SELFTEST_PASS || fail 15 "SDL2 presentation selftest failed"
        echo "PASS host C++ compile + behavior + SDL2 presentation selftest"
''',
'''        echo "PASS host C++ compile + non-display behavior selftest"
        echo "INFO display execution is device-only; Ubuntu is not required to provide SDL2"
'''
        ),
    ],
    wrapper_path: [
        (
'''set -u
MANAGER_LIBS="$ROOT/lib.sdl2:$ROOT/lib:$ROOT/libs:$ROOT/lib/aarch64"
if [ -n "${DEVICE_ARCH:-}" ]; then
    MANAGER_LIBS="$ROOT/libs.${DEVICE_ARCH}:$MANAGER_LIBS"
    if [ -n "${CFW_NAME:-}" ]; then
        MANAGER_LIBS="$ROOT/libs.${CFW_NAME}.${DEVICE_ARCH}:$ROOT/libs.${CFW_NAME}:$MANAGER_LIBS"
    fi
fi
export LD_LIBRARY_PATH="$MANAGER_LIBS:/mnt/SDCARD/System/lib:/usr/trimui/lib:${LD_LIBRARY_PATH:-}"
''',
'''set -u
# Exact display environment proven by openmw-navmesh-progress.
export LD_LIBRARY_PATH="/usr/trimui/lib:/mnt/SDCARD/System/lib:$ROOT/lib:$ROOT/libs:$ROOT/lib/aarch64"
unset LD_PRELOAD
unset LIBGL_FB
unset LIBGL_FBO
unset LIBGL_RECYCLEFBO
'''
        ),
    ],
}

updated = {}
for path, pairs in replacements.items():
    text = sources[path]
    for old, new in pairs:
        count = text.count(old)
        if count != 1:
            raise RuntimeError(f"{path.name}: repair anchor matches={count}, expected exactly 1")
        text = text.replace(old, new, 1)
    updated[path] = text

for path, text in updated.items():
    temp = path.with_name(path.name + ".system-sdl-repair.tmp")
    with open(temp, "w", encoding="utf-8", newline="\n") as out:
        out.write(text)
        out.flush()
        os.fsync(out.fileno())
    os.replace(temp, path)
PY
then
    restore_sources
    fail "structural repair failed; exact source backup restored"
fi

if ! bash -n "$INSTALLER"; then fail "installer syntax failed after repair"; fi
if ! bash -n "$WRAPPER"; then fail "wrapper syntax failed after repair"; fi
if ! python3 - "$CPP" "$INSTALLER" "$WRAPPER" <<'PY'
import sys
from pathlib import Path

cpp, installer, wrapper = [Path(x).read_text(encoding="utf-8") for x in sys.argv[1:]]
checks = {
    "C++ no forced software hint": 'mSetHint("SDL_RENDER_DRIVER", "software")' not in cpp,
    "C++ accelerated-first renderer": "mCreateRenderer(mWindow, -1, 0x00000006u)" in cpp,
    "C++ timer/event SDL init": "mInit(0x00004021u)" in cpp,
    "installer no Ubuntu display execution": "SDL_VIDEODRIVER=dummy" not in installer,
    "wrapper system SDL first": 'LD_LIBRARY_PATH="/usr/trimui/lib:/mnt/SDCARD/System/lib:' in wrapper,
    "wrapper clears preload": "unset LD_PRELOAD" in wrapper,
    "wrapper clears GL4ES framebuffer variables": all(x in wrapper for x in ("unset LIBGL_FB", "unset LIBGL_FBO", "unset LIBGL_RECYCLEFBO")),
}
bad = [name for name, passed in checks.items() if not passed]
if bad:
    raise SystemExit("semantic verification failed: " + ", ".join(bad))
print("PASS semantic verification: proven navmesh system-SDL policy")
PY
then
    restore_sources
    fail "post-repair semantic verification failed; exact source backup restored"
fi

new_cpp_sha="$(hash_of "$CPP")"
new_installer_sha="$(hash_of "$INSTALLER")"
new_wrapper_sha="$(hash_of "$WRAPPER")"
if [ "$new_cpp_sha" != "$NEW_CPP" ] || [ "$new_installer_sha" != "$NEW_INSTALLER" ] || [ "$new_wrapper_sha" != "$NEW_WRAPPER" ]; then
    echo "ERROR repaired hashes do not match the tested repair" >&2
    echo "C++:      $new_cpp_sha" >&2
    echo "Installer: $new_installer_sha" >&2
    echo "Wrapper:   $new_wrapper_sha" >&2
    restore_sources
    fail "exact source backup restored"
fi

echo "Repaired hashes:"
sha256sum "$CPP" "$INSTALLER" "$WRAPPER"
echo "PASS in-place Manager V2.1 source repair"

if [ "$MODE" = "patch-only" ]; then
    echo "INFO patch-only requested; installer was not started"
    echo "Log: $LOG"
    exit 0
fi
if [ "$MODE" != "install" ]; then
    fail "usage: $0 [install|patch-only]"
fi

chmod +x "$INSTALLER"
"$INSTALLER"
rc=$?
echo "Installer exit code: $rc"
echo "Repair/install log: $LOG"
exit "$rc"
