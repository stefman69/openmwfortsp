#!/bin/bash
set -Eeuo pipefail

GAMEDIR="${OPENMW51_GAMEDIR:-/mnt/SDCARD/data/ports/openmw51}"
SETTINGS="$GAMEDIR/config-0.51/settings.cfg"

LAUNCHER=""
for candidate in \
    /mnt/SDCARD/Roms/PORTS/Morrowind_51.sh \
    /mnt/SDCARD/Emus/PORTS/../../Roms/PORTS/Morrowind_51.sh
do
    if [ -f "$candidate" ]; then
        LAUNCHER="$(readlink -f "$candidate" 2>/dev/null || printf '%s' "$candidate")"
        break
    fi
done

if [ ! -f "$SETTINGS" ]; then
    echo "ERROR: settings.cfg not found:"
    echo "  $SETTINGS"
    exit 1
fi

if [ -z "$LAUNCHER" ] || [ ! -f "$LAUNCHER" ]; then
    echo "ERROR: Morrowind_51.sh launcher not found."
    exit 1
fi

STAMP="$(date +%Y%m%d-%H%M%S)"
SETTINGS_BACKUP="$SETTINGS.before-v8-$STAMP"
LAUNCHER_BACKUP="$LAUNCHER.before-v8-$STAMP"

cp -f "$SETTINGS" "$SETTINGS_BACKUP"
cp -f "$LAUNCHER" "$LAUNCHER_BACKUP"

echo "Backups:"
echo "  $SETTINGS_BACKUP"
echo "  $LAUNCHER_BACKUP"

python3 - "$SETTINGS" <<'PY_SETTINGS'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8", errors="replace")

changes = {
    "Camera": {
        "near clip": "15",
    },
    "General": {
        "texture mag filter": "linear",
        "texture min filter": "linear",
        "texture mipmap": "nearest",
        "anisotropy": "1",
    },
}

def set_key(source, section, key, value):
    section_re = re.compile(rf"(?mi)^\[{re.escape(section)}\][ \t]*$")
    match = section_re.search(source)

    if not match:
        if source and not source.endswith("\n"):
            source += "\n"
        return source + f"\n[{section}]\n{key} = {value}\n"

    next_section = re.search(r"(?m)^\[[^\]]+\][ \t]*$", source[match.end():])
    end = match.end() + next_section.start() if next_section else len(source)
    body = source[match.end():end]

    lines = body.splitlines()
    result = []
    replaced = False

    for line in lines:
        if re.match(rf"(?i)^[ \t]*{re.escape(key)}[ \t]*=", line):
            if replaced:
                continue
            indent = re.match(r"^[ \t]*", line).group(0)
            result.append(f"{indent}{key} = {value}")
            replaced = True
        else:
            result.append(line)

    if not replaced:
        result.insert(0, f"{key} = {value}")

    body = "\n".join(result)
    if source[match.end():end].endswith("\n") and not body.endswith("\n"):
        body += "\n"

    return source[:match.end()] + body + source[end:]

for section, entries in changes.items():
    for key, value in entries.items():
        text = set_key(text, section, key, value)

path.write_text(text, encoding="utf-8")
PY_SETTINGS

python3 - "$LAUNCHER" <<'PY_LAUNCHER'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8", errors="replace")

def set_export(source, name, value):
    pattern = re.compile(rf"(?m)^[ \t]*export[ \t]+{re.escape(name)}=.*$")
    matches = list(pattern.finditer(source))
    if len(matches) != 1:
        raise RuntimeError(
            f"Expected exactly one 'export {name}=...' line; found {len(matches)}"
        )
    return pattern.sub(f"export {name}={value}", source, count=1)

text = set_export(text, "LIBGL_MIPMAP", "2")
text = set_export(text, "LIBGL_FORCENPOT", "0")

if not re.search(r"(?m)^[ \t]*export[ \t]+LIBGL_NOTEST=1[ \t]*$", text):
    raise RuntimeError("Expected known-good 'export LIBGL_NOTEST=1' launcher setting")

path.write_text(text, encoding="utf-8")
PY_LAUNCHER

echo
echo "===== V8 TEXTURE SETTINGS ====="
awk '
/^\[/ { section=$0 }
$0 ~ /^(near clip|texture mag filter|texture min filter|texture mipmap|anisotropy)[[:space:]]*=/ {
    if (section == "[Camera]" || section == "[General]")
        print section " " $0
}
' "$SETTINGS"

echo
echo "===== V8 GL4ES SETTINGS ====="
grep -nE 'export LIBGL_(MIPMAP|FORCENPOT|NOTEST)=' "$LAUNCHER"

grep -q '^export LIBGL_MIPMAP=2$' "$LAUNCHER"
grep -q '^export LIBGL_FORCENPOT=0$' "$LAUNCHER"
grep -q '^export LIBGL_NOTEST=1$' "$LAUNCHER"

echo
echo "V8 runtime profile applied."
echo "POT mipmaps enabled through GL4ES/OpenMW safety gate."
echo "NPOT textures remain non-mipmapped."
echo "near clip remains 15."
