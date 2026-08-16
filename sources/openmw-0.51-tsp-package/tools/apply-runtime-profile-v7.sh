#!/bin/bash
set -eu

GAMEDIR="${OPENMW51_GAMEDIR:-/mnt/SDCARD/data/ports/openmw51}"
CFG="$GAMEDIR/config-0.51/openmw.cfg"
COMPAT="$GAMEDIR/config-0.51/openmw/openmw.cfg"
SETTINGS="$GAMEDIR/config-0.51/settings.cfg"

STAMP="$(date +%Y%m%d-%H%M%S)"

for required in "$CFG" "$SETTINGS"; do
    if [ ! -f "$required" ]; then
        echo "ERROR: missing:"
        echo "  $required"
        exit 1
    fi
done

ATLAS_CORE="$GAMEDIR/mods/Project Atlas/00 Core"
ATLAS_TEXTURES="$GAMEDIR/mods/Project Atlas/01 Textures - Vanilla"
MOP_CORE="$GAMEDIR/mods/Morrowind Optimization Patch/00 Core"

for required in "$MOP_CORE" "$ATLAS_CORE" "$ATLAS_TEXTURES"; do
    if [ ! -d "$required" ]; then
        echo "ERROR: required optimization-mod directory is missing:"
        echo "  $required"
        exit 1
    fi
done

cp -f "$CFG" "$CFG.before-v7-$STAMP"
cp -f "$SETTINGS" "$SETTINGS.before-v7-$STAMP"

python3 - "$CFG" "$GAMEDIR" <<'PY_CFG'
from pathlib import Path
import sys

path = Path(sys.argv[1])
gamedir = sys.argv[2]

text = path.read_text(encoding="utf-8", errors="replace")
lines = text.splitlines()

filtered = []
for line in lines:
    if "/mods/Morrowind Optimization Patch/" in line:
        continue
    if "/mods/Project Atlas/" in line:
        continue
    if "/mods/ProjectAtlas/" in line:
        continue
    if line.strip() in (
        "# Morrowind Optimization Patch",
        "# Project Atlas",
        "# TSP optimization mods",
    ):
        continue
    filtered.append(line)

while filtered and not filtered[-1].strip():
    filtered.pop()

filtered.extend(
    [
        "",
        "# TSP optimization mods",
        f'data="{gamedir}/mods/Morrowind Optimization Patch/00 Core"',
        f'data="{gamedir}/mods/Project Atlas/00 Core"',
        f'data="{gamedir}/mods/Project Atlas/01 Textures - Vanilla"',
        "",
    ]
)

path.write_text("\n".join(filtered), encoding="utf-8", newline="\n")
PY_CFG

mkdir -p "$(dirname "$COMPAT")"
cp -f "$CFG" "$COMPAT"

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
    "Terrain": {
        "object paging active grid": "false",
        "water culling": "true",
    },
    "Cells": {
        "preload enabled": "false",
        "cache expiry delay": "1",
    },
    "Navigator": {
        "enable": "true",
        "wait until min distance to player": "0",
        "enable nav mesh disk cache": "true",
        "write to navmeshdb": "true",
        "async nav mesh updater threads": "1",
        "max nav mesh tiles cache size": "33554432",
    },
}

def set_key(source, section, key, value):
    section_pat = re.compile(
        rf"(?mi)^\[{re.escape(section)}\][ \t]*$"
    )
    match = section_pat.search(source)

    if not match:
        if source and not source.endswith("\n"):
            source += "\n"
        source += f"\n[{section}]\n{key} = {value}\n"
        return source

    next_section = re.search(r"(?m)^\[[^\]]+\][ \t]*$", source[match.end():])
    end = match.end() + next_section.start() if next_section else len(source)

    body = source[match.end():end]
    key_pat = re.compile(
        rf"(?mi)^(?P<prefix>[ \t]*){re.escape(key)}[ \t]*=.*$"
    )

    matches = list(key_pat.finditer(body))
    if matches:
        first = matches[0]
        replacement = first.group("prefix") + f"{key} = {value}"
        body = body[:first.start()] + replacement + body[first.end():]

        body_lines = body.splitlines()
        seen = False
        cleaned = []
        for line in body_lines:
            if re.match(rf"(?i)^[ \t]*{re.escape(key)}[ \t]*=", line):
                if seen:
                    continue
                seen = True
            cleaned.append(line)
        body = "\n".join(cleaned)
        if source[match.end():end].endswith("\n") and not body.endswith("\n"):
            body += "\n"
    else:
        if body and not body.startswith("\n"):
            body = "\n" + body
        body = "\n" + f"{key} = {value}" + body

    return source[:match.end()] + body + source[end:]

for section, values in changes.items():
    for key, value in values.items():
        text = set_key(text, section, key, value)

path.write_text(text, encoding="utf-8", newline="\n")
PY_SETTINGS

echo
echo "===== V7 PROJECT ATLAS / MOP ====="
grep -n \
    -e 'Morrowind Optimization Patch' \
    -e 'Project Atlas' \
    "$CFG"

echo
echo "===== V7 MEMORY / WATER SETTINGS ====="
awk '
/^\[/ { section=$0 }
$0 ~ /^(near clip|object paging active grid|water culling|preload enabled|cache expiry delay|enable|wait until min distance to player|enable nav mesh disk cache|write to navmeshdb|async nav mesh updater threads|max nav mesh tiles cache size)[[:space:]]*=/ {
    if (section == "[Camera]" || section == "[Terrain]" || section == "[Cells]" || section == "[Navigator]")
        print section " " $0
}
' "$SETTINGS"

echo
echo "Runtime profile v7 applied."
echo "Project Atlas remains ENABLED."
echo "near clip remains 15."
echo "navmesh cache is persistent and capped at 32 MiB in RAM."
