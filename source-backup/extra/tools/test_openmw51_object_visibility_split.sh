#!/usr/bin/env bash
set -Eeuo pipefail

# OpenMW 0.51 / TSP - object visibility split A/B
#
# Modes:
#   both      = disable VISGRID 8x5 depth curtain, keep topology PVS;
#               disable active-grid object paging.
#   interior  = disable VISGRID 8x5 depth curtain only.
#   exterior  = disable active-grid object paging only.
#   status    = print current state.
#   rollback  = restore the exact files backed up by the most recent apply.
#
# No Docker and no binary rebuild.

DEV="${TSP_DEV:-root@192.168.1.25}"
MODE="${1:-status}"

ROOT="/mnt/SDCARD/data/ports/openmw51"
BASE="$ROOT/mods/TSPInteriorVisGrid/scripts/TSPInteriorVisGrid"
LIVE="$BASE/visgrid.lua"
PROFILE="$BASE/v23_profiles/visgrid-v23-t1-p1.lua"
SETTINGS="$ROOT/config-0.51/settings.cfg"
EXPECTED_CURRENT_SHA="ed155ccd7bea88becce3d9f6a262a77b9c20fe91859d020a14bd41fcb3797c5e"
POINTER="$ROOT/backups/object-visibility-split-ab.latest"

SSH=(ssh -o BatchMode=yes -o ConnectTimeout=8)
SCP=(scp -q -o BatchMode=yes -o ConnectTimeout=8)

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

ensure_closed() {
    if "${SSH[@]}" "$DEV" 'pidof openmw-0.51 >/dev/null 2>&1 || pidof openmw >/dev/null 2>&1'; then
        echo "ERROR: OpenMW is running. Exit it normally first."
        exit 20
    fi
}

show_status() {
    "${SSH[@]}" "$DEV" "
        set +e
        echo '===== OBJECT VISIBILITY SPLIT STATUS ====='
        sha256sum '$LIVE' '$PROFILE' '$SETTINGS' 2>/dev/null || true
        echo
        echo '--- depth-curtain A/B marker ---'
        grep -n 'TSP_OBJECT_SPLIT_AB_NO_DEPTH_CURTAIN' '$LIVE' '$PROFILE' 2>/dev/null || true
        echo
        echo '--- object paging active grid ---'
        awk '
          BEGIN { inTerrain=0 }
          /^\[Terrain\][[:space:]]*$/ { inTerrain=1; next }
          /^\[/ { inTerrain=0 }
          inTerrain && /^[[:space:]]*object paging active grid[[:space:]]*=/ { print }
        ' '$SETTINGS' 2>/dev/null
        echo
        echo '--- macro1 profile marker ---'
        grep -n -m1 'TSP_VISGRID_LUA_V23_PERF_MATRIX' '$LIVE' 2>/dev/null || true
        echo
        echo '--- rollback pointer ---'
        cat '$POINTER' 2>/dev/null || true
    "
}

apply_mode() {
    ensure_closed

    LIVE_SHA="$("${SSH[@]}" "$DEV" "sha256sum '$LIVE' | awk '{print \$1}'")"
    PROFILE_SHA="$("${SSH[@]}" "$DEV" "sha256sum '$PROFILE' | awk '{print \$1}'")"

    echo "live SHA:    $LIVE_SHA"
    echo "profile SHA: $PROFILE_SHA"

    if [ "$MODE" = "interior" ] || [ "$MODE" = "both" ]; then
        if ! "${SSH[@]}" "$DEV" "grep -Fq 'TSP_OBJECT_SPLIT_AB_NO_DEPTH_CURTAIN' '$PROFILE'"; then
            if [ "$PROFILE_SHA" != "$EXPECTED_CURRENT_SHA" ]; then
                echo "ERROR: macro1 profile is not the exact recon state."
                echo "Expected: $EXPECTED_CURRENT_SHA"
                echo "Got:      $PROFILE_SHA"
                echo "Nothing changed."
                exit 30
            fi
        fi
    fi

    STAMP="$(date +%Y%m%d-%H%M%S)"
    BACK="$ROOT/backups/object-visibility-split-ab-$STAMP"

    "${SSH[@]}" "$DEV" "
        set -e
        mkdir -p '$BACK'
        cp -p '$LIVE' '$BACK/visgrid.lua.before'
        cp -p '$PROFILE' '$BACK/visgrid-v23-t1-p1.lua.before'
        cp -p '$SETTINGS' '$BACK/settings.cfg.before'
        sha256sum '$LIVE' '$PROFILE' '$SETTINGS' > '$BACK/SHA256SUMS.before.txt'
        printf '%s\n' '$MODE' > '$BACK/mode.txt'
        printf '%s\n' '$BACK' > '$POINTER'
        sync
    "

    if [ "$MODE" = "interior" ] || [ "$MODE" = "both" ]; then
        "${SCP[@]}" "$DEV:$PROFILE" "$TMP/profile.lua"

        python3 - "$TMP/profile.lua" "$TMP/profile.new.lua" <<'PY'
from pathlib import Path
import sys

src = Path(sys.argv[1]).read_text(encoding="utf-8")

if "TSP_OBJECT_SPLIT_AB_NO_DEPTH_CURTAIN" in src:
    out = src
else:
    old = '''        if mapState.topoCell ~= nil
            and (mapState.topoKind == 'small_room'
                or mapState.topoKind == 'room'
                or mapState.topoKind == 'corridor') then
            camera.setInteriorVisibilityGrid(COLS, ROWS, out, mapState.v16TightPadding)
        else
            camera.setInteriorVisibilityGrid(COLS, ROWS, out, PADDING)
        end
        gridMaybeArmed = true
'''
    new = '''        -- TSP_OBJECT_SPLIT_AB_NO_DEPTH_CURTAIN
        -- A/B: retain the navmesh/topology PVS but do NOT publish the old
        -- ray-derived 8x5 depth curtain. This makes every non-PVS object fail
        -- open while structural ESM::Static PVS remains active.
        pcall(camera.clearInteriorVisibilityGrid)
        gridMaybeArmed = false
'''
    if src.count(old) != 1:
        raise SystemExit(
            "ERROR: expected exact macro1 publish block once; found %d. No edit." % src.count(old)
        )
    out = src.replace(old, new, 1)

Path(sys.argv[2]).write_text(out, encoding="utf-8", newline="\n")
PY

        grep -Fq 'TSP_OBJECT_SPLIT_AB_NO_DEPTH_CURTAIN' "$TMP/profile.new.lua"
        "${SCP[@]}" "$TMP/profile.new.lua" "$DEV:/tmp/visgrid-v23-t1-p1.object-ab.lua"

        "${SSH[@]}" "$DEV" "
            set -e
            cp -f /tmp/visgrid-v23-t1-p1.object-ab.lua '$PROFILE.new'
            chmod 644 '$PROFILE.new'
            mv -f '$PROFILE.new' '$PROFILE'
            cp -f '$PROFILE' '$LIVE.new'
            chmod 644 '$LIVE.new'
            mv -f '$LIVE.new' '$LIVE'
            rm -f /tmp/visgrid-v23-t1-p1.object-ab.lua
            grep -Fq 'TSP_OBJECT_SPLIT_AB_NO_DEPTH_CURTAIN' '$PROFILE'
            grep -Fq 'TSP_OBJECT_SPLIT_AB_NO_DEPTH_CURTAIN' '$LIVE'
            sync
        "
    fi

    if [ "$MODE" = "exterior" ] || [ "$MODE" = "both" ]; then
        "${SCP[@]}" "$DEV:$SETTINGS" "$TMP/settings.cfg"

        python3 - "$TMP/settings.cfg" "$TMP/settings.new.cfg" <<'PY'
from pathlib import Path
import sys

src = Path(sys.argv[1]).read_text(encoding="utf-8")
lines = src.splitlines()
in_terrain = False
hits = 0

for i, line in enumerate(lines):
    stripped = line.strip()
    if stripped.startswith("[") and stripped.endswith("]"):
        in_terrain = stripped.lower() == "[terrain]"
        continue
    if in_terrain and stripped.lower().startswith("object paging active grid"):
        key, sep, value = line.partition("=")
        if not sep:
            continue
        lines[i] = key.rstrip() + " = false"
        hits += 1

if hits != 1:
    raise SystemExit(
        "ERROR: expected one [Terrain] object paging active grid setting; found %d." % hits
    )

Path(sys.argv[2]).write_text("\n".join(lines) + "\n", encoding="utf-8", newline="\n")
PY

        "${SCP[@]}" "$TMP/settings.new.cfg" "$DEV:/tmp/settings.object-ab.cfg"
        "${SSH[@]}" "$DEV" "
            set -e
            cp -f /tmp/settings.object-ab.cfg '$SETTINGS.new'
            mv -f '$SETTINGS.new' '$SETTINGS'
            rm -f /tmp/settings.object-ab.cfg
            awk '
              BEGIN { inTerrain=0; ok=0 }
              /^\[Terrain\][[:space:]]*$/ { inTerrain=1; next }
              /^\[/ { inTerrain=0 }
              inTerrain && /^[[:space:]]*object paging active grid[[:space:]]*=[[:space:]]*false[[:space:]]*$/ { ok=1 }
              END { exit(ok ? 0 : 1) }
            ' '$SETTINGS'
            sync
        "
    fi

    echo
    echo "PASS: split A/B mode '$MODE' applied."
    echo "Backup: $BACK"
    echo
    show_status
}

rollback_mode() {
    ensure_closed

    BACK="$("${SSH[@]}" "$DEV" "test -s '$POINTER' && cat '$POINTER'")" || {
        echo "ERROR: no split-A/B rollback pointer found."
        exit 40
    }

    echo "Restoring:"
    echo "  $BACK"

    "${SSH[@]}" "$DEV" "
        set -e
        test -s '$BACK/visgrid.lua.before'
        test -s '$BACK/visgrid-v23-t1-p1.lua.before'
        test -s '$BACK/settings.cfg.before'

        cp -p '$BACK/visgrid.lua.before' '$LIVE.restore'
        mv -f '$LIVE.restore' '$LIVE'

        cp -p '$BACK/visgrid-v23-t1-p1.lua.before' '$PROFILE.restore'
        mv -f '$PROFILE.restore' '$PROFILE'

        cp -p '$BACK/settings.cfg.before' '$SETTINGS.restore'
        mv -f '$SETTINGS.restore' '$SETTINGS'

        sync
        echo '===== RESTORED ====='
        sha256sum '$LIVE' '$PROFILE' '$SETTINGS'
    "

    echo
    echo "PASS: exact pre-A/B files restored."
}

case "$MODE" in
    status)
        show_status
        ;;
    interior|exterior|both)
        apply_mode
        ;;
    rollback)
        rollback_mode
        ;;
    *)
        echo "Usage: $0 {status|interior|exterior|both|rollback}"
        exit 2
        ;;
esac
