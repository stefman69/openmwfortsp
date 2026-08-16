#!/bin/bash
set -eu

GAMEDIR="${OPENMW51_GAMEDIR:-/mnt/SDCARD/data/ports/openmw51}"
CFG="$GAMEDIR/config-0.51/openmw.cfg"
COMPAT="$GAMEDIR/config-0.51/openmw/openmw.cfg"
SETTINGS="$GAMEDIR/config-0.51/settings.cfg"
NAVDB="$GAMEDIR/savegame-0.51/navmesh.db"
STAMP="$(date +%Y%m%d-%H%M%S)"

for required in "$CFG" "$SETTINGS"; do
    if [ ! -f "$required" ]; then
        echo "ERROR: missing:"
        echo "  $required"
        exit 1
    fi
done

cp -f "$CFG" "$CFG.before-safenav-v10-$STAMP"
cp -f "$SETTINGS" "$SETTINGS.before-safenav-v10-$STAMP"

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
        # v10 hard-safe runtime profile. The v10 executable ALSO defaults to a
        # Navigator stub, so this remains safe even if another config source
        # accidentally contains different Navigator values.
        "enable": "false",
        "wait until min distance to player": "0",
        "enable nav mesh disk cache": "true",
        "write to navmeshdb": "false",
        "async nav mesh updater threads": "1",
        "max nav mesh tiles cache size": "33554432",
        "wait for all jobs on exit": "false",
    },
}


def set_key(source, section, key, value):
    section_pat = re.compile(rf"(?mi)^\[{re.escape(section)}\][ \t]*$")
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

# Do not use Path.write_text(..., newline=...): the Python version used by the
# user's build/device workflow does not support that keyword on Path.write_text.
with path.open("w", encoding="utf-8", newline="\n") as handle:
    handle.write(text)
PY_SETTINGS

mkdir -p "$(dirname "$COMPAT")"
cp -f "$CFG" "$COMPAT"

echo
echo "===== V10 SAFENAV SETTINGS ====="
awk '
/^\[/ { section=$0 }
$0 ~ /^(near clip|object paging active grid|water culling|preload enabled|cache expiry delay|enable|wait until min distance to player|enable nav mesh disk cache|write to navmeshdb|async nav mesh updater threads|max nav mesh tiles cache size|wait for all jobs on exit)[[:space:]]*=/ {
    if (section == "[Camera]" || section == "[Terrain]" || section == "[Cells]" || section == "[Navigator]")
        print section " " $0
}
' "$SETTINGS"

echo
if [ -f "$NAVDB" ]; then
    echo "Existing pre-generated navmesh cache PRESERVED:"
    ls -lh "$NAVDB"
else
    echo "No navmesh.db is currently present; v10 does not create or require one."
fi

echo
echo "SafeNav v10 runtime profile applied."
echo "Navigator is disabled in settings."
echo "The v10 binary independently defaults to the Navigator stub."
echo "Runtime navmesh DB writes are disabled."
echo "Do NOT set OPENMW_TSP_ENABLE_NAVIGATOR=1 during this stability test."
