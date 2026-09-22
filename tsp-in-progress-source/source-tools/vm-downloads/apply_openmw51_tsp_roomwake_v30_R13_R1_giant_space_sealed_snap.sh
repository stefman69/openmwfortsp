#!/usr/bin/env bash
# OpenMW 0.51 / TrimUI Smart Pro
# V30 R13-R1: R12 long-ray priority plus giant shared-space authority and
# conservative sealed-wall acceleration.
#
# LUA/PROFILE ONLY. No C++ source edit, no rebuild, no binary replacement,
# and no launcher change.
#
# Exact input required (successful R12 validation):
#   R12 binary e25f6edf...a3fab
#   R12 Lua    242bf8e5...0701
#
# Policy:
#   - Preserve all R12 XY behavior, all five XY/Z ranges, and four-ray budget.
#   - Two tall up-ray witnesses plus two wide/deep forward witnesses inside
#     1.20 seconds prove a giant shared space. A large_open navmesh prior may
#     substitute for the second tall witness.
#   - Giant authority forces Z open and augments R4 PVS with at most twelve
#     nearby, horizontally-overlapping cross-floor sectors. This is the layer
#     actors actually use, so it protects both lights and NPCs across floors.
#   - Giant authority remains cell-local and is released only by twenty
#     consecutive sealed samples in a small-room/corridor topology.
#   - Outside giant mode, ten sealed-wall samples snap directly to the already
#     proven R12 very-tight ranges. Any disagreement exits fully open first.
#
# Actions: install (default), collect, rollback

set -u -o pipefail

ACTION="${1:-install}"
CTR="${OPENMW_CONTAINER:-openmw_builder}"
DEV="${TSP_DEVICE:-root@192.168.1.12}"
ROOT="/mnt/SDCARD/data/ports/openmw51"
BIN="$ROOT/bin/openmw-0.51"
LUA="$ROOT/mods/TSPInteriorVisGrid/scripts/TSPInteriorVisGrid/visgrid.lua"
PROFILE="$ROOT/mods/TSPInteriorVisGrid/scripts/TSPInteriorVisGrid/v30_profiles/visgrid-v30-floor-actor-roomwake.lua"
GAMELOG="$ROOT/openmw_051_log.txt"
PERF="$ROOT/openmw51_perf_latest.txt"
ARM="$ROOT/roomwake-r13-capture-start.line"

EXPECTED_R12_BIN_SHA="e25f6edfe90c6610be94b285a243d7d2b673a7412ac504a026f14976332a3fab"
EXPECTED_R12_LUA_SHA="242bf8e5ced906374565e88a6fd9fc284bc28d87c1732e189877ca6b04de0701"

DL="$HOME/Downloads"
STAMP="$(date +%Y%m%d-%H%M%S)"
RUNLOG="$DL/openmw51-roomwake-r13-$STAMP.log"
STATE="$DL/openmw51-roomwake-r13.state"
TMP="$(mktemp -d "$DL/.roomwake-r13.XXXXXX")"
DEVICE_BACKUP=""

cleanup() {
    if [ -n "$TMP" ] && [ -d "$TMP" ]; then
        rm -rf "$TMP"
    fi
}
trap cleanup EXIT

fail() {
    local rc="${1:-1}"
    shift || true
    echo "ERROR: $*" >&2
    exit "$rc"
}

need() {
    if ! command -v "$1" >/dev/null 2>&1; then
        fail 10 "required command missing: $1"
    fi
    echo "PASS command: $1"
}

ensure_docker() {
    need docker
    if ! docker inspect "$CTR" >/dev/null 2>&1; then
        fail 11 "Docker container not found: $CTR"
    fi
    if [ "$(docker inspect -f '{{.State.Running}}' "$CTR" 2>/dev/null || true)" != "true" ]; then
        if ! docker start "$CTR" >/dev/null; then
            fail 12 "failed to start Docker: $CTR"
        fi
    fi
    echo "PASS Docker: $CTR"
}

ensure_ssh() {
    need ssh
    need scp
    if ! ssh -o BatchMode=yes -o ConnectTimeout=8 "$DEV" true >/dev/null 2>&1; then
        fail 13 "SSH failed: $DEV"
    fi
    echo "PASS SSH: $DEV"
}

remote_sha() {
    ssh "$DEV" 'bash -s' -- "$1" <<'REMOTE_SHA' 2>/dev/null || true
P="$1"
if [ -f "$P" ]; then
    sha256sum "$P" | awk '{print $1}'
fi
REMOTE_SHA
}

restore_device_backup() {
    local backup="$1"
    if [ -z "$backup" ]; then
        echo "FAIL R13 restore path is empty" >&2
        return 1
    fi
    ssh "$DEV" 'bash -s' -- \
        "$backup" "$LUA" "$PROFILE" "$EXPECTED_R12_LUA_SHA" <<'REMOTE_RESTORE'
set -u
B="$1"; LIVE="$2"; PROFILE="$3"; EXPECTED="$4"
if [ ! -s "$B/visgrid.lua.before-r13" ] || [ ! -s "$B/profile.lua.before-r13" ]; then
    echo "FAIL R13 backup Lua files missing: $B" >&2
    exit 1
fi
for f in "$B/visgrid.lua.before-r13" "$B/profile.lua.before-r13"; do
    GOT="$(sha256sum "$f" | awk '{print $1}')"
    if [ "$GOT" != "$EXPECTED" ]; then
        echo "FAIL backup is not exact R12 Lua: $f expected=$EXPECTED actual=$GOT" >&2
        exit 2
    fi
done
install -m 644 "$B/visgrid.lua.before-r13" "$LIVE" || exit 3
install -m 644 "$B/profile.lua.before-r13" "$PROFILE" || exit 4
sync
for f in "$LIVE" "$PROFILE"; do
    GOT="$(sha256sum "$f" | awk '{print $1}')"
    if [ "$GOT" != "$EXPECTED" ]; then
        echo "FAIL restored R11 Lua SHA: $f expected=$EXPECTED actual=$GOT" >&2
        exit 5
    fi
done
echo "PASS exact R12 Lua/profile restored"
REMOTE_RESTORE
}

collect_action() {
    ensure_ssh
    local out="$DL/openmw51-roomwake-r13-validation-$STAMP.txt"
    local start total
    total="$(ssh "$DEV" "wc -l < '$GAMELOG'" 2>/dev/null | tr -d '[:space:]' || true)"
    start="$(ssh "$DEV" "cat '$ARM' 2>/dev/null" | tr -d '[:space:]' || true)"
    case "$total" in ''|*[!0-9]*) fail 20 "invalid current game-log length: $total";; esac
    case "$start" in ''|*[!0-9]*) start=1;; esac
    if [ "$start" -gt "$total" ]; then
        if [ "$total" -gt 3999 ]; then start=$((total - 3999)); else start=1; fi
        echo "INFO capture marker exceeded current log; using current tail"
    else
        start=$((start + 1))
    fi
    if ! scp -q "$DEV:$GAMELOG" "$TMP/openmw.log"; then
        fail 21 "could not pull game log"
    fi
    scp -q "$DEV:$PERF" "$TMP/perf.txt" 2>/dev/null || true
    {
        echo "===== OPENMW 0.51 V30 R13 GIANT-SPACE / SEALED-SNAP VALIDATION ====="
        date
        echo "Binary SHA: $(remote_sha "$BIN")"
        echo "Lua SHA:    $(remote_sha "$LUA")"
        echo "Log lines: total=$total capture=$start..$total"
        echo
        sed -n "${start},${total}p" "$TMP/openmw.log" \
            | grep -E '\[TSP_ROOMRAY_R13\]|\[TSP_ROOMRAY_R12\]|\[TSP_ROOMRAY_R11\] tier-change|\[TSP_ROOMOBJ_V30\]|\[TSP_VISGRID_V30_R4\]|\[TSP_ACTOR_V30\]|Lua.*error|failed to render' \
            || true
        if [ -s "$TMP/perf.txt" ]; then
            echo
            echo "===== PERF TAIL ====="
            tail -180 "$TMP/perf.txt"
        fi
    } > "$out"
    echo "PASS R13 validation: $out"
    echo "Upload that file for review."
}

rollback_action() {
    ensure_ssh
    if [ ! -s "$STATE" ]; then
        fail 22 "R13 rollback state missing: $STATE"
    fi
    # Generated locally by this exact controller.
    # shellcheck disable=SC1090
    . "$STATE"
    if [ "${R13_OLD_BIN_SHA:-}" != "$EXPECTED_R12_BIN_SHA" ] \
        || [ "${R13_OLD_LUA_SHA:-}" != "$EXPECTED_R12_LUA_SHA" ] \
        || [ -z "${R13_DEVICE_BACKUP:-}" ]; then
        fail 23 "R13 rollback state is incomplete or not based on exact R12"
    fi
    if [ "$(remote_sha "$BIN")" != "$EXPECTED_R12_BIN_SHA" ]; then
        fail 24 "device binary is no longer exact R12; refusing Lua-only rollback"
    fi
    restore_device_backup "$R13_DEVICE_BACKUP" \
        || fail 25 "R13 rollback could not restore exact R12 Lua"
    echo "PASS R13 rollback complete; binary unchanged and exact R12 Lua restored."
}

case "$ACTION" in
    collect) collect_action; exit 0;;
    rollback) rollback_action; exit 0;;
    install) ;;
    *) fail 2 "usage: $0 [install|collect|rollback]";;
esac

exec > >(tee "$RUNLOG") 2>&1

cat <<'BANNER'
============================================================
OPENMW 0.51 — ROOMWAKE V30 R13-R1
GIANT SHARED-SPACE AUTHORITY / SEALED-WALL SNAP
============================================================
R12 five XY/Z ranges, four rays, long priority, and contraction unchanged.

GIANT SPACE:
  Rolling upward + forward proof forces Z open and temporarily admits up to
  12 nearby overlapping cross-floor sectors to R4 topology authority.
  This protects both lights and actors across atrium floors.

SEALED WALL:
  10 unanimous very-short samples snap to existing very-tight ranges.
  The first disagreement exits fully open. No new smaller range is introduced.

No C++ rebuild. No binary replacement. No launcher change.
============================================================
BANNER

need python3
need sha256sum
ensure_docker
ensure_ssh

if ssh "$DEV" "pgrep -af 'openmw-0\\.51|/openmw([[:space:]]|$)' 2>/dev/null" \
    | grep -v pgrep >/dev/null 2>&1; then
    fail 30 "OpenMW appears to be running; exit the game first"
fi

echo
echo "===== 1/6 VERIFY EXACT SUCCESSFUL R12 DEVICE STATE ====="
BIN_SHA="$(remote_sha "$BIN")"
LUA_SHA="$(remote_sha "$LUA")"
PROFILE_SHA="$(remote_sha "$PROFILE")"
if [ "$BIN_SHA" = "$EXPECTED_R12_BIN_SHA" ] \
    && [ "$LUA_SHA" = "$PROFILE_SHA" ] && [ -s "$STATE" ]; then
    # A safe no-op on an exact rerun.
    # shellcheck disable=SC1090
    . "$STATE"
    if [ "${R13_OLD_BIN_SHA:-}" = "$EXPECTED_R12_BIN_SHA" ] \
        && [ "${R13_OLD_LUA_SHA:-}" = "$EXPECTED_R12_LUA_SHA" ] \
        && [ -n "${R13_NEW_LUA_SHA:-}" ] \
        && [ "$LUA_SHA" = "$R13_NEW_LUA_SHA" ] \
        && ssh "$DEV" "grep -Fq 'TSP_ROOMRAY_LUA_V30_R13_GIANT_SHARED_SPACE' '$LUA'"; then
        echo "PASS exact R13 is already installed: $LUA_SHA"
        echo "No files changed. Use '$0 collect' after testing."
        exit 0
    fi
fi
if [ "$BIN_SHA" != "$EXPECTED_R12_BIN_SHA" ]; then
    echo "EXPECTED R12 BIN: $EXPECTED_R12_BIN_SHA" >&2
    echo "ACTUAL DEVICE:    $BIN_SHA" >&2
    fail 31 "device binary is not exact validated R12"
fi
if [ "$LUA_SHA" != "$EXPECTED_R12_LUA_SHA" ] || [ "$PROFILE_SHA" != "$EXPECTED_R12_LUA_SHA" ]; then
    echo "EXPECTED R12 LUA: $EXPECTED_R12_LUA_SHA" >&2
    echo "ACTUAL LIVE:      $LUA_SHA" >&2
    echo "ACTUAL PROFILE:   $PROFILE_SHA" >&2
    fail 32 "device Lua/profile is not exact validated R12"
fi
if ! ssh "$DEV" "grep -Fq 'TSP_ROOMRAY_LUA_V30_R12_LONG_PRIORITY' '$LUA' && ! grep -Fq 'TSP_ROOMRAY_LUA_V30_R13_GIANT_SHARED_SPACE' '$LUA'"; then
    fail 33 "exact R12 markers are not in the expected pre-R13 state"
fi
echo "PASS exact validated R12 binary: $BIN_SHA"
echo "PASS exact validated R12 Lua:    $LUA_SHA"

echo
echo "===== 2/6 BACK UP EXACT R12 LUA/PROFILE ====="
DEVICE_BACKUP="$ROOT/backups/roomwake-v30-r13-giant-space-$STAMP"
if ! ssh "$DEV" 'bash -s' -- \
    "$DEVICE_BACKUP" "$LUA" "$PROFILE" "$EXPECTED_R12_LUA_SHA" <<'REMOTE_BACKUP'
set -u
B="$1"; LIVE="$2"; PROFILE="$3"; EXPECTED="$4"
mkdir -p "$B" || exit 1
for spec in "$LIVE:visgrid.lua.before-r13" "$PROFILE:profile.lua.before-r13"; do
    SRC="${spec%%:*}"; NAME="${spec#*:}"
    [ -s "$SRC" ] || exit 2
    GOT="$(sha256sum "$SRC" | awk '{print $1}')"
    [ "$GOT" = "$EXPECTED" ] || exit 3
    install -m 644 "$SRC" "$B/$NAME" || exit 4
done
sha256sum "$B/visgrid.lua.before-r13" "$B/profile.lua.before-r13"
echo "PASS exact R12 Lua/profile backup: $B"
REMOTE_BACKUP
then
    fail 34 "R13 device backup failed"
fi

if ! scp -q "$DEV:$PROFILE" "$TMP/visgrid-r12.lua"; then
    fail 35 "could not pull exact R12 profile"
fi
if [ "$(sha256sum "$TMP/visgrid-r12.lua" | awk '{print $1}')" != "$EXPECTED_R12_LUA_SHA" ]; then
    fail 36 "pulled R12 profile SHA changed after preflight"
fi

echo
echo "===== 3/6 GENERATE + SELFTEST R13 LUA ====="
cat > "$TMP/patch_r13_lua.py" <<'PY_PATCH'
#!/usr/bin/env python3
import sys

MARK = 'TSP_ROOMRAY_LUA_V30_R12_LONG_PRIORITY'
MARK13 = 'TSP_ROOMRAY_LUA_V30_R13_GIANT_SHARED_SPACE'


def read(path):
    with open(path, 'r', encoding='utf-8', newline='') as f:
        return f.read()


def write(path, text):
    with open(path, 'w', encoding='utf-8', newline='\n') as f:
        f.write(text)


def replace_one(text, old, new, label):
    count = text.count(old)
    if count != 1:
        raise RuntimeError('%s count=%d expected 1' % (label, count))
    return text.replace(old, new, 1)


def line_start(text, pos):
    return text.rfind('\n', 0, pos) + 1


def patch_lua(src):
    for token in (
        'TSP_ROOMRAY_LUA_V30_R11_FIVE_TIER_XY_HEIGHT',
        'mapState.r11ResetAuthority = function(reason)',
        'mapState.r11Classify = function(distances)',
        'mapState.r11RayUpdate = function(dt)',
        'mapState.r11AuthorityReport = function(distances)',
        'mapState.r11SetTiers',
        'mapState.r11ZTarget',
        'mapState.r11BlendAuthority',
        "print('[TSP_ROOMRAY_R11] enabled rays=4 period=0.20 phases=8 authority=dual-ema+topology XYtiers=5 Ztiers=5 long-weight=0.65')",
    ):
        if token not in src:
            raise RuntimeError('R11 Lua precondition missing: ' + token)
    if MARK in src:
        raise RuntimeError('R12 Lua marker already present')

    state_anchor = 'mapState.r11UpDepth = 2400.0\n'
    state_block = r'''mapState.r11UpDepth = 2400.0
-- TSP_ROOMRAY_LUA_V30_R12_LONG_PRIORITY
-- R11 ranges/rays stay unchanged. Two dominant-long forward witnesses in a
-- 0.65-second window snap XY outward. Contraction requires ten consecutive
-- mutually consistent samples and advances only one tier at a time.
mapState.r12LongWindow = 0.65
mapState.r12ShrinkRequired = 10
mapState.r12ShrinkVotes = 0
mapState.r12LongWitnesses = {}
mapState.r12LastLongThreshold = 0.0
mapState.r12LastLongCount = 0
mapState.r12LastCrazy = false
mapState.r12LastShortLimit = 0.0
mapState.r12RenderXY = {1450.0, 1200.0, 950.0, 700.0, 450.0}

mapState.r12ResetEvidence = function()
    mapState.r12ShrinkVotes = 0
    mapState.r12LongWitnesses = {}
    mapState.r12LastLongThreshold = 0.0
    mapState.r12LastLongCount = 0
    mapState.r12LastCrazy = false
    mapState.r12LastShortLimit = 0.0
end

mapState.r12RenderForTier = function(tier)
    tier = math.floor(math.max(0, math.min(4, tonumber(tier or 0) or 0)) + 0.5)
    return mapState.r12RenderXY[tier + 1] or 1450.0
end

mapState.r12TierForDepth = function(depth)
    depth = math.max(0.0, tonumber(depth or 0) or 0)
    if depth <= 450.0 then return 4 end
    if depth <= 700.0 then return 3 end
    if depth <= 950.0 then return 2 end
    if depth <= 1200.0 then return 1 end
    return 0
end

mapState.r12AgeLongWitnesses = function()
    local kept = {}
    for i = 1, #(mapState.r12LongWitnesses or {}) do
        local event = mapState.r12LongWitnesses[i]
        local age = (tonumber(event.age or 0) or 0) + mapState.r11RayPeriod
        if age <= mapState.r12LongWindow then
            kept[#kept + 1] = {age = age, depth = tonumber(event.depth or 0) or 0}
        end
    end
    mapState.r12LongWitnesses = kept
end
'''
    src = replace_one(src, state_anchor, state_block, 'R11 state insertion anchor')

    reset_start = src.index('mapState.r11ResetAuthority = function(reason)')
    reset_end = src.index('\nend\n\nmapState.r11CastDirection', reset_start)
    reset_block = src[reset_start:reset_end]
    old_reset = '    mapState.r11SampleCount = 0\n    mapState.r11ReportElapsed = 0.0'
    new_reset = ('    mapState.r11SampleCount = 0\n'
                 '    mapState.r12ResetEvidence()\n'
                 '    mapState.r11ReportElapsed = 0.0')
    reset_new = replace_one(reset_block, old_reset, new_reset,
                            'R11 authority-reset evidence anchor')
    src = src[:reset_start] + reset_new + src[reset_end:]

    class_pos = src.index('mapState.r11Classify = function(distances)')
    class_start = line_start(src, class_pos)
    update_pos = src.index('mapState.r11RayUpdate = function(dt)', class_pos)
    class_end = line_start(src, update_pos)
    old_class = src[class_start:class_end]
    new_class = r'''mapState.r12BaseAuthorityReport = mapState.r11AuthorityReport
mapState.r11AuthorityReport = function(distances)
    mapState.r12BaseAuthorityReport(distances)
    print(string.format(
        '[TSP_ROOMRAY_R12] state XY=%d/%s render=%.0f longWindow=%d threshold=%.0f shrink=%d/%d shortLimit=%.0f crazy=%d',
        tonumber(mapState.r11XYTier or 0) or 0,
        mapState.r11TierName(mapState.r11XYTier),
        mapState.r12RenderForTier(mapState.r11XYTier),
        #(mapState.r12LongWitnesses or {}),
        tonumber(mapState.r12LastLongThreshold or 0) or 0,
        tonumber(mapState.r12ShrinkVotes or 0) or 0,
        tonumber(mapState.r12ShrinkRequired or 0) or 0,
        tonumber(mapState.r12LastShortLimit or 0) or 0,
        mapState.r12LastCrazy and 1 or 0))
end

mapState.r11Classify = function(distances)
    if distances == nil then
        -- API/direction failure is not small-space evidence. Fail fully open.
        mapState.r12ResetEvidence()
        mapState.r11XYScore = 4.0
        mapState.r11ZScore = 4.0
        mapState.r11SetTiers(0, 0, 'ray-api-failure', nil)
        return
    end

    local ordered = {distances[1], distances[2], distances[3]}
    table.sort(ordered)
    local shortest = ordered[1]
    local middle = ordered[2]
    local longest = ordered[3]
    local forwardMean = (shortest + middle + longest) / 3.0
    local up = distances[4]
    mapState.r11WeightedXY = forwardMean
    mapState.r11UpDepth = up
    mapState.r11SampleCount = mapState.r11SampleCount + 1

    local xyPrior, zPrior, kind, xySpan, zSpan = mapState.r11TopologyPrior()
    mapState.r11TopoXYPrior = xyPrior
    mapState.r11TopoZPrior = zPrior
    mapState.r11TopoKind = kind
    mapState.r11TopoXYSpan = xySpan
    mapState.r11TopoZSpan = zSpan

    -- Height remains exactly R11's independent up-ray EMA.
    local zTarget = mapState.r11ZTarget(up)
    mapState.r11ZScore = mapState.r11BlendAuthority(
        mapState.r11ZScore, zTarget, zPrior, up >= 1500.0)
    local zTier = mapState.r11ScoreToTier(mapState.r11ZScore)

    local currentTier = math.floor(mapState.r11Clamp(mapState.r11XYTier, 0, 4) + 0.5)
    local currentRender = mapState.r12RenderForTier(currentTier)
    local longThreshold = currentRender * 2.0
    mapState.r12LastLongThreshold = longThreshold
    mapState.r12AgeLongWitnesses()

    local addedLong = 0
    if currentTier > 0 then
        for i = 1, 3 do
            if distances[i] >= longThreshold then
                mapState.r12LongWitnesses[#mapState.r12LongWitnesses + 1]
                    = {age = 0.0, depth = distances[i]}
                addedLong = addedLong + 1
            end
        end
    end
    mapState.r12LastLongCount = addedLong

    if currentTier > 0 and #mapState.r12LongWitnesses >= 2 then
        local depths = {}
        for i = 1, #mapState.r12LongWitnesses do
            depths[#depths + 1] = mapState.r12LongWitnesses[i].depth
        end
        table.sort(depths)
        local lowerOfTwoLongest = depths[#depths - 1]
        local snapTier = mapState.r12TierForDepth(lowerOfTwoLongest)
        if snapTier >= currentTier then snapTier = currentTier - 1 end
        snapTier = math.max(0, snapTier)
        mapState.r11XYScore = 4.0 - snapTier
        mapState.r12ShrinkVotes = 0
        mapState.r12LongWitnesses = {}
        mapState.r11SetTiers(snapTier, zTier, 'two-long-priority', distances)
        print(string.format(
            '[TSP_ROOMRAY_R12] LONG-SNAP from=%d/%s to=%d/%s witness=%.0f threshold=%.0f currentRender=%.0f L=%.0f C=%.0f R=%.0f',
            currentTier, mapState.r11TierName(currentTier),
            snapTier, mapState.r11TierName(snapTier),
            lowerOfTwoLongest, longThreshold, currentRender,
            distances[1], distances[2], distances[3]))
        return
    end

    local nextTier = math.min(4, currentTier + 1)
    local shortLimit = mapState.r12RenderForTier(nextTier) * 1.15
    mapState.r12LastShortLimit = shortLimit
    -- A lone deep aperture may be legitimate. It blocks contraction even if
    -- it has not yet gained the second witness needed for an outward snap.
    local crazy = longest >= math.max(middle * 2.0, shortest * 2.5)
    mapState.r12LastCrazy = crazy
    local recentLong = #mapState.r12LongWitnesses > 0
    local allShort = longest <= shortLimit

    if currentTier < 4 and allShort and not crazy and not recentLong then
        mapState.r12ShrinkVotes = mapState.r12ShrinkVotes + 1
    else
        mapState.r12ShrinkVotes = 0
    end

    if currentTier < 4 and mapState.r12ShrinkVotes >= mapState.r12ShrinkRequired then
        local newTier = currentTier + 1
        mapState.r11XYScore = 4.0 - newTier
        mapState.r12ShrinkVotes = 0
        mapState.r11SetTiers(newTier, zTier, 'consensus-contract', distances)
        print(string.format(
            '[TSP_ROOMRAY_R12] CONTRACT from=%d/%s to=%d/%s samples=%d limit=%.0f observed=%.0f/%.0f/%.0f',
            currentTier, mapState.r11TierName(currentTier),
            newTier, mapState.r11TierName(newTier),
            mapState.r12ShrinkRequired, shortLimit,
            shortest, middle, longest))
    else
        -- Hold XY exactly; only the independent Z authority may change.
        mapState.r11XYScore = 4.0 - currentTier
        mapState.r11SetTiers(currentTier, zTier, 'long-priority-hold', distances)
    end
end

'''
    if 'weighted = ordered[1] * 0.10 + ordered[2] * 0.25 + ordered[3] * 0.65' not in old_class:
        raise RuntimeError('R11 weighted classifier signature missing from bounded block')
    src = src[:class_start] + new_class + src[class_end:]

    old_startup = "print('[TSP_ROOMRAY_R11] enabled rays=4 period=0.20 phases=8 authority=dual-ema+topology XYtiers=5 Ztiers=5 long-weight=0.65')"
    new_startup = old_startup + "\nprint('[TSP_ROOMRAY_R12] enabled XY=two-long-priority window=0.65 contraction=10-consensus-samples Z=R11-independent')"
    src = replace_one(src, old_startup, new_startup, 'R11 startup marker')

    for token in (
        MARK,
        'mapState.r12LongWindow = 0.65',
        'mapState.r12ShrinkRequired = 10',
        'local longThreshold = currentRender * 2.0',
        '#mapState.r12LongWitnesses >= 2',
        "'two-long-priority'",
        "'consensus-contract'",
        'local crazy = longest >= math.max(middle * 2.0, shortest * 2.5)',
        '[TSP_ROOMRAY_R12] LONG-SNAP',
        '[TSP_ROOMRAY_R12] CONTRACT',
        '[TSP_ROOMRAY_R12] state',
        'mapState.r11ZScore = mapState.r11BlendAuthority',
    ):
        if token not in src:
            raise RuntimeError('R12 postcondition missing: ' + token)
    if 'weighted = ordered[1] * 0.10 + ordered[2] * 0.25 + ordered[3] * 0.65' in src:
        raise RuntimeError('obsolete R11 weighted XY classifier survived R12')
    return src


def patch_r13(src):
    for token in (
        'TSP_VISGRID_LUA_V30_R4_SAME_FLOOR_PROXIMITY',
        'TSP_ROOMRAY_LUA_V30_R11_FIVE_TIER_XY_HEIGHT',
        'TSP_ROOMRAY_LUA_V30_R12_LONG_PRIORITY',
        'mapState.updateTopologyPvs = function(force)',
        'mapState.v30InferFloor',
        'mapState.v30R4AabbDistance',
        'mapState.r12RenderXY = {1450.0, 1200.0, 950.0, 700.0, 450.0}',
        'mapState.r12ResetEvidence()',
        'mapState.r11Classify = function(distances)',
        "print('[TSP_ROOMRAY_R12] enabled XY=two-long-priority window=0.65 contraction=10-consensus-samples Z=R11-independent')",
    ):
        if token not in src:
            raise RuntimeError('R12 Lua precondition missing: ' + token)
    if MARK13 in src:
        raise RuntimeError('R13 Lua marker already present')

    # Expose the exact R4 base PVS IDs to the bounded R13 wrapper. This is a
    # structural insertion inside the unique R4 function, not a reimplementation
    # of R4's door/floor policy.
    old_ids = "    table.sort(ids)\n    local signature = 'v30r4:f'"
    new_ids = r'''    table.sort(ids)
    mapState.r13BasePvsIds = {}
    for r13i = 1, #ids do
        mapState.r13BasePvsIds[r13i] = ids[r13i]
    end
    local signature = 'v30r4:f' '''.rstrip()
    src = replace_one(src, old_ids, new_ids, 'R4 sorted-ID snapshot anchor')

    state_anchor = 'mapState.r12RenderXY = {1450.0, 1200.0, 950.0, 700.0, 450.0}\n'
    state_block = r'''mapState.r12RenderXY = {1450.0, 1200.0, 950.0, 700.0, 450.0}

-- TSP_ROOMRAY_LUA_V30_R13_GIANT_SHARED_SPACE
-- Giant proof joins upward depth, forward depth, and the R4 topology prior.
-- It augments only nearby horizontally-overlapping cross-floor sectors and
-- never admits more than twelve extra sectors. Sealed-wall mode introduces no
-- smaller C++ range: it reaches R12's already-proven tier 4 sooner and exits
-- fully open on the first disagreeing sample.
mapState.r13ProofWindow = 1.20
mapState.r13UpProof = {}
mapState.r13ForwardProof = {}
mapState.r13GiantActive = false
mapState.r13GiantCell = nil
mapState.r13GiantReason = 'none'
mapState.r13GiantExtra = 0
mapState.r13GiantMaxExtra = 12
mapState.r13GiantXYRadius = 1700.0
mapState.r13GiantAabbGap = 480.0
mapState.r13PvsOverrideApplied = false
mapState.r13GiantSignature = nil
mapState.r13GiantInputSignature = nil
mapState.r13BasePvsIds = {}
mapState.r13SealVotes = 0
mapState.r13SealRequired = 10
mapState.r13GiantReleaseRequired = 20
mapState.r13SealedActive = false

mapState.r13ResetSpaceAuthority = function()
    mapState.r13UpProof = {}
    mapState.r13ForwardProof = {}
    mapState.r13GiantActive = false
    mapState.r13GiantCell = nil
    mapState.r13GiantReason = 'reset'
    mapState.r13GiantExtra = 0
    mapState.r13GiantSignature = nil
    mapState.r13GiantInputSignature = nil
    mapState.r13SealVotes = 0
    mapState.r13SealedActive = false
    -- Keep r13PvsOverrideApplied set until the wrapper performs a forced
    -- restoration of R4's exact base mask on its next call.
end

mapState.r13AgeProof = function(events)
    local kept = {}
    for i = 1, #(events or {}) do
        local age = (tonumber(events[i] or 0) or 0) + mapState.r11RayPeriod
        if age <= mapState.r13ProofWindow then kept[#kept + 1] = age end
    end
    return kept
end

mapState.r13AabbXYGap = function(a, b)
    local aa = a and a.bbox or nil
    local bb = b and b.bbox or nil
    if aa == nil or bb == nil or #aa < 6 or #bb < 6 then return math.huge end
    local ax0, ay0 = tonumber(aa[1] or 0) or 0, tonumber(aa[2] or 0) or 0
    local ax1, ay1 = tonumber(aa[4] or ax0) or ax0, tonumber(aa[5] or ay0) or ay0
    local bx0, by0 = tonumber(bb[1] or 0) or 0, tonumber(bb[2] or 0) or 0
    local bx1, by1 = tonumber(bb[4] or bx0) or bx0, tonumber(bb[5] or by0) or by0
    local dx, dy = 0.0, 0.0
    if ax1 < bx0 then dx = bx0 - ax1 elseif bx1 < ax0 then dx = ax0 - bx1 end
    if ay1 < by0 then dy = by0 - ay1 elseif by1 < ay0 then dy = ay0 - by1 end
    return math.sqrt(dx*dx + dy*dy)
end

mapState.r13BaseUpdateTopologyPvs = mapState.updateTopologyPvs
mapState.updateTopologyPvs = function(force)
    local cell = self.cell
    local giant = mapState.r13GiantActive and mapState.r13GiantCell == cell
    if mapState.r13GiantActive and not giant then
        mapState.r13GiantActive = false
        mapState.r13GiantCell = nil
        mapState.r13GiantReason = 'cell-mismatch'
    end

    local restoring = mapState.r13PvsOverrideApplied and not giant
    mapState.r13BaseUpdateTopologyPvs(force or restoring)
    if not giant then
        mapState.r13PvsOverrideApplied = false
        mapState.r13GiantSignature = nil
        mapState.r13GiantInputSignature = nil
        mapState.r13GiantExtra = 0
        return
    end

    local tc = mapState.topoCell
    local sectors = tc and tc.sectors or nil
    local current = tonumber(mapState.topoSectorId or 0) or 0
    local currentSec = sectors and current > 0 and sectors[current] or nil
    if currentSec == nil or mapState.pvsBoxes == nil then
        mapState.r13PvsOverrideApplied = false
        mapState.r13GiantSignature = nil
        mapState.r13GiantInputSignature = nil
        mapState.r13GiantExtra = 0
        return
    end

    local cc = currentSec.center or {0, 0, 0}
    local x = tonumber(mapState.topoX or cc[1] or 0) or 0
    local y = tonumber(mapState.topoY or cc[2] or 0) or 0
    local z = tonumber(mapState.topoZ or cc[3] or 0) or 0
    local playerFloor = mapState.v30InferFloor(x, y, z, currentSec)
    local inputSignature = tostring(mapState.pvsSignature or '?')
        .. ':s' .. tostring(current)
        .. ':f' .. tostring(playerFloor or '?')
        .. ':q' .. tostring(math.floor(x / 128.0))
        .. ',' .. tostring(math.floor(y / 128.0))
    if not force and mapState.r13PvsOverrideApplied
        and inputSignature == mapState.r13GiantInputSignature then
        return
    end
    local ids, seen = {}, {}
    for i = 1, #(mapState.r13BasePvsIds or {}) do
        local sid = tonumber(mapState.r13BasePvsIds[i] or 0) or 0
        if sid > 0 and not seen[sid] then
            seen[sid] = true
            ids[#ids + 1] = sid
        end
    end
    if current > 0 and not seen[current] then
        seen[current] = true
        ids[#ids + 1] = current
    end

    local candidates = {}
    for sid, target in pairs(sectors) do
        sid = tonumber(sid or 0) or 0
        if sid > 0 and target ~= nil and not seen[sid] then
            local targetFloor = tonumber(target.floor)
            local targetKind = tostring(target.kind or 'room')
            local crossFloor = playerFloor ~= nil and targetFloor ~= nil
                and targetFloor ~= playerFloor
            if crossFloor or targetKind == 'vertical_connector' then
                local d = mapState.v30R4AabbDistance(target, x, y)
                local gap = mapState.r13AabbXYGap(currentSec, target)
                if d <= mapState.r13GiantXYRadius and gap <= mapState.r13GiantAabbGap then
                    candidates[#candidates + 1] = {id=sid, d=d, gap=gap}
                end
            end
        end
    end
    table.sort(candidates, function(a, b)
        if a.d ~= b.d then return a.d < b.d end
        if a.gap ~= b.gap then return a.gap < b.gap end
        return a.id < b.id
    end)
    local extra = math.min(mapState.r13GiantMaxExtra, #candidates)
    for i = 1, extra do
        local sid = candidates[i].id
        if not seen[sid] then
            seen[sid] = true
            ids[#ids + 1] = sid
        end
    end
    table.sort(ids)
    local signature = tostring(mapState.pvsSignature or '?') .. ':r13giant:'
        .. table.concat(ids, ',')
    if force or signature ~= mapState.r13GiantSignature then
        local ok, err = pcall(camera.setInteriorTopologyPvs,
            mapState.pvsBoxes, ids, 0.0, 0.0)
        if ok then
            mapState.r13PvsOverrideApplied = true
            mapState.r13GiantSignature = signature
            mapState.r13GiantInputSignature = inputSignature
            mapState.r13GiantExtra = extra
            mapState.pvsActiveCount = #ids
            print(string.format(
                '[TSP_ROOMRAY_R13] GIANT-PVS reason=%s base=%d cross=%d active=%d floor=%s ids=%s',
                tostring(mapState.r13GiantReason or '?'),
                #(mapState.r13BasePvsIds or {}), extra, #ids,
                tostring(playerFloor or '?'), table.concat(ids, ',')))
        else
            print('[TSP_ROOMRAY_R13] GIANT-PVS ERROR ' .. tostring(err))
        end
    end
end

mapState.r13SealedCondition = function(distances, kind)
    if distances == nil then return false end
    kind = tostring(kind or 'room')
    local limit = 0.0
    if kind == 'small_room' or kind == 'corridor' then limit = 280.0
    elseif kind == 'room' then limit = 220.0 end
    if limit <= 0.0 then return false end
    local ordered = {distances[1], distances[2], distances[3]}
    table.sort(ordered)
    return ordered[3] <= limit and distances[4] <= limit
        and (ordered[3] - ordered[1]) <= 120.0
end

mapState.r13ObserveSpace = function(distances, kind)
    if distances == nil then return 'failure-open' end
    mapState.r13UpProof = mapState.r13AgeProof(mapState.r13UpProof)
    mapState.r13ForwardProof = mapState.r13AgeProof(mapState.r13ForwardProof)

    if distances[4] >= 1800.0 then
        mapState.r13UpProof[#mapState.r13UpProof + 1] = 0.0
    end
    for i = 1, 3 do
        if distances[i] >= 1200.0 then
            mapState.r13ForwardProof[#mapState.r13ForwardProof + 1] = 0.0
        end
    end

    local rayProof = #mapState.r13UpProof >= 2
        and #mapState.r13ForwardProof >= 2
    local navProof = tostring(kind or '') == 'large_open'
        and #mapState.r13UpProof >= 1
        and #mapState.r13ForwardProof >= 2
    if not mapState.r13GiantActive and (rayProof or navProof) then
        mapState.r13GiantActive = true
        mapState.r13GiantCell = self.cell
        mapState.r13GiantReason = rayProof and 'ray-combined' or 'nav-plus-rays'
        mapState.r13SealVotes = 0
        mapState.r13SealedActive = false
        print(string.format(
            '[TSP_ROOMRAY_R13] GIANT-ENTER reason=%s upProof=%d forwardProof=%d topo=%s L=%.0f C=%.0f R=%.0f U=%.0f',
            mapState.r13GiantReason, #mapState.r13UpProof,
            #mapState.r13ForwardProof, tostring(kind or '?'),
            distances[1], distances[2], distances[3], distances[4]))
        mapState.updateTopologyPvs(true)
    end

    local sealed = mapState.r13SealedCondition(distances, kind)
    if mapState.r13GiantActive then
        if sealed and (kind == 'small_room' or kind == 'corridor') then
            mapState.r13SealVotes = mapState.r13SealVotes + 1
        else
            mapState.r13SealVotes = 0
        end
        if mapState.r13SealVotes >= mapState.r13GiantReleaseRequired then
            mapState.r13GiantActive = false
            mapState.r13GiantCell = nil
            mapState.r13GiantReason = 'sealed-release'
            mapState.r13SealVotes = 0
            mapState.updateTopologyPvs(true)
            print('[TSP_ROOMRAY_R13] GIANT-EXIT reason=20-sealed-samples')
            -- The same proof safely enters tier 4 after restoring exact R4 PVS.
            mapState.r13SealedActive = true
            return 'sealed-enter'
        end
        return 'giant-hold'
    end

    if mapState.r13SealedActive then
        if sealed then return 'sealed-hold' end
        mapState.r13SealedActive = false
        mapState.r13SealVotes = 0
        print('[TSP_ROOMRAY_R13] SEALED-EXIT reason=first-disagreement mode=open')
        return 'sealed-exit-open'
    end

    if sealed then mapState.r13SealVotes = mapState.r13SealVotes + 1
    else mapState.r13SealVotes = 0 end
    if mapState.r13SealVotes >= mapState.r13SealRequired then
        mapState.r13SealVotes = 0
        mapState.r13SealedActive = true
        print(string.format(
            '[TSP_ROOMRAY_R13] SEALED-ENTER samples=%d topo=%s L=%.0f C=%.0f R=%.0f U=%.0f',
            mapState.r13SealRequired, tostring(kind or '?'),
            distances[1], distances[2], distances[3], distances[4]))
        return 'sealed-enter'
    end
    return 'normal'
end
'''
    src = replace_one(src, state_anchor, state_block, 'R12 state insertion anchor')

    reset_anchor = '    mapState.r12ResetEvidence()\n    mapState.r11ReportElapsed = 0.0'
    reset_new = ('    mapState.r12ResetEvidence()\n'
                 '    mapState.r13ResetSpaceAuthority()\n'
                 '    mapState.r11ReportElapsed = 0.0')
    src = replace_one(src, reset_anchor, reset_new, 'R12 reset-to-R13 anchor')

    report_anchor = 'mapState.r11Classify = function(distances)'
    report_block = r'''mapState.r13BaseAuthorityReport = mapState.r11AuthorityReport
mapState.r11AuthorityReport = function(distances)
    mapState.r13BaseAuthorityReport(distances)
    print(string.format(
        '[TSP_ROOMRAY_R13] state giant=%d reason=%s upProof=%d forwardProof=%d cross=%d sealed=%d sealVotes=%d/%d',
        mapState.r13GiantActive and 1 or 0,
        tostring(mapState.r13GiantReason or '?'),
        #(mapState.r13UpProof or {}), #(mapState.r13ForwardProof or {}),
        tonumber(mapState.r13GiantExtra or 0) or 0,
        mapState.r13SealedActive and 1 or 0,
        tonumber(mapState.r13SealVotes or 0) or 0,
        mapState.r13GiantActive and mapState.r13GiantReleaseRequired
            or mapState.r13SealRequired))
end

mapState.r11Classify = function(distances)'''
    src = replace_one(src, report_anchor, report_block, 'R12 classifier/report anchor')

    topo_anchor = '''    mapState.r11TopoZSpan = zSpan

    -- Height remains exactly R11's independent up-ray EMA.'''
    topo_new = '''    mapState.r11TopoZSpan = zSpan

    local r13Action = mapState.r13ObserveSpace(distances, kind)
    if r13Action == 'sealed-enter' or r13Action == 'sealed-hold' then
        mapState.r11XYScore = 0.0
        mapState.r11ZScore = 0.0
        mapState.r12ResetEvidence()
        mapState.r11SetTiers(4, 4, 'r13-' .. r13Action, distances)
        return
    elseif r13Action == 'sealed-exit-open' then
        mapState.r11XYScore = 4.0
        mapState.r11ZScore = 4.0
        mapState.r12ResetEvidence()
        mapState.r11SetTiers(0, 0, 'r13-sealed-exit-open', distances)
        return
    end

    -- Height remains R11's independent up-ray EMA unless combined giant-space
    -- proof requires cross-floor safety.'''
    src = replace_one(src, topo_anchor, topo_new, 'R12 topology-to-Z anchor')

    z_anchor = '''    local zTier = mapState.r11ScoreToTier(mapState.r11ZScore)

    local currentTier ='''
    z_new = '''    local zTier = mapState.r11ScoreToTier(mapState.r11ZScore)
    if mapState.r13GiantActive then
        mapState.r11XYScore = 4.0
        mapState.r11ZScore = 4.0
        mapState.r12ShrinkVotes = 0
        mapState.r12LongWitnesses = {}
        zTier = 0
    end

    local currentTier = mapState.r13GiantActive and 0 or'''
    src = replace_one(src, z_anchor, z_new, 'R12 Z-tier giant clamp anchor')

    startup = "print('[TSP_ROOMRAY_R12] enabled XY=two-long-priority window=0.65 contraction=10-consensus-samples Z=R11-independent')"
    startup13 = startup + "\nprint('[TSP_ROOMRAY_R13] enabled giant=up+forward+nav crossFloorMax=12 sealedSnap=10 giantRelease=20')"
    src = replace_one(src, startup, startup13, 'R12 startup marker')

    for token in (
        MARK13,
        'mapState.r13BasePvsIds = {}',
        'mapState.r13GiantMaxExtra = 12',
        'mapState.r13ProofWindow = 1.20',
        '#mapState.r13UpProof >= 2',
        '#mapState.r13ForwardProof >= 2',
        'mapState.r13GiantActive then',
        'local currentTier = mapState.r13GiantActive and 0 or',
        'mapState.r13SealedCondition',
        "return 'sealed-exit-open'",
        '[TSP_ROOMRAY_R13] GIANT-ENTER',
        '[TSP_ROOMRAY_R13] GIANT-PVS',
        '[TSP_ROOMRAY_R13] SEALED-ENTER',
        '[TSP_ROOMRAY_R13] SEALED-EXIT',
        "mapState.r11SetTiers(4, 4, 'r13-' .. r13Action, distances)",
        "mapState.r11SetTiers(0, 0, 'r13-sealed-exit-open', distances)",
    ):
        if token not in src:
            raise RuntimeError('R13 postcondition missing: ' + token)
    if src.count('mapState.r11CastDirection(eye,') != 4:
        raise RuntimeError('R13 changed exact four-ray call-site count')
    return src


def sample():
    return r'''-- TSP_ROOMRAY_LUA_V30_R11_FIVE_TIER_XY_HEIGHT
mapState.r11UpDepth = 2400.0
mapState.r11ResetAuthority = function(reason)
    mapState.r11SampleCount = 0
    mapState.r11ReportElapsed = 0.0
end

mapState.r11CastDirection = function() return 1 end
mapState.r11SetTiers = function() end
mapState.r11ZTarget = function(v) return v end
mapState.r11BlendAuthority = function(a,b) return b end
mapState.r11ScoreToTier = function() return 0 end
mapState.r11Clamp = function(v) return v end
mapState.r11TierName = function() return 'x' end
mapState.r11TopologyPrior = function() return 1,1,'room',1,1 end
mapState.r11AuthorityReport = function(distances)
    print('[TSP_ROOMRAY_R11] authority XY=')
end

mapState.r11Classify = function(distances)
    local ordered = { distances[1], distances[2], distances[3] }
    table.sort(ordered)
    local weighted = ordered[1] * 0.10 + ordered[2] * 0.25 + ordered[3] * 0.65
    local zTarget = mapState.r11ZTarget(distances[4])
    mapState.r11ZScore = mapState.r11BlendAuthority(mapState.r11ZScore, zTarget, 1, false)
end

mapState.r11RayUpdate = function(dt) end
print('[TSP_ROOMRAY_R11] enabled rays=4 period=0.20 phases=8 authority=dual-ema+topology XYtiers=5 Ztiers=5 long-weight=0.65')
return {}
'''


def selftest():
    out = patch_lua(sample())
    assert MARK in out
    assert 'mapState.r12ResetEvidence()' in out
    assert 'currentRender * 2.0' in out
    assert '#mapState.r12LongWitnesses >= 2' in out
    assert 'mapState.r12ShrinkRequired = 10' in out
    assert 'weighted = ordered[1] * 0.10' not in out

    render = [1450.0, 1200.0, 950.0, 700.0, 450.0]
    def tier_for_depth(d):
        if d <= 450: return 4
        if d <= 700: return 3
        if d <= 950: return 2
        if d <= 1200: return 1
        return 0
    # In SMALL, 2x current render is 1400. One 1500 report only holds;
    # a second inside the window snaps directly OPEN to cover 1500.
    assert render[3] * 2 == 1400
    assert tier_for_depth(1500) == 0
    # In VERY_TIGHT, two 950 reports snap to MEDIUM.
    assert render[4] * 2 == 900
    assert tier_for_depth(950) == 2
    # Contraction cannot advance before ten agreeing samples.
    votes = 0
    for _ in range(9): votes += 1
    assert votes < 10
    votes += 1
    assert votes == 10
    # A roughly 2x outlier is explicitly disagreement, not shrink evidence.
    shortest, middle, longest = 300, 420, 900
    assert longest >= max(middle * 2.0, shortest * 2.5)
    shortest, middle, longest = 400, 600, 900
    assert not (longest >= max(middle * 2.0, shortest * 2.5))
    # With 0.20-second sampling, evidence at t=0 is accepted through t=0.60
    # and gone at t=0.80: the discrete equivalent of the 0.65-second window.
    ages = [0.0]
    for _ in range(3):
        ages = [age + 0.20 for age in ages if age + 0.20 <= 0.65]
    assert len(ages) == 1 and abs(ages[0] - 0.60) < 0.001
    ages = [age + 0.20 for age in ages if age + 0.20 <= 0.65]
    assert ages == []
    r4_fixture = r'''-- TSP_VISGRID_LUA_V30_R4_SAME_FLOOR_PROXIMITY
mapState.v30InferFloor = function() return 1 end
mapState.v30R4AabbDistance = function() return 0 end
mapState.updateTopologyPvs = function(force)
    local ids = {1}
    table.sort(ids)
    local signature = 'v30r4:f' .. tostring(1)
end
mapState.r11SampleFour = function()
    mapState.r11CastDirection(eye, 0.28, 0.50)
    mapState.r11CastDirection(eye, 0.50, 0.50)
    mapState.r11CastDirection(eye, 0.72, 0.50)
    mapState.r11CastDirection(eye, 0.50, 0.24)
end

'''
    out = out.replace('-- TSP_ROOMRAY_LUA_V30_R11_FIVE_TIER_XY_HEIGHT',
                      r4_fixture + '-- TSP_ROOMRAY_LUA_V30_R11_FIVE_TIER_XY_HEIGHT', 1)
    out13 = patch_r13(out)
    assert MARK13 in out13
    assert out13.count('mapState.r11CastDirection(eye,') == 4
    assert 'mapState.r13GiantMaxExtra = 12' in out13
    assert "return 'sealed-exit-open'" in out13
    assert "local signature = 'v30r4:f' .. tostring(1)" in out13
    print('PASS R13 Lua selftest: R12 retained + giant PVS + sealed snap/escape')


if len(sys.argv) == 2 and sys.argv[1] == '--selftest':
    selftest()
    raise SystemExit(0)
if len(sys.argv) != 3:
    raise SystemExit('usage: patch_r13_lua.py INPUT_R12_LUA OUTPUT_R13_LUA | --selftest')
write(sys.argv[2], patch_r13(read(sys.argv[1])))
print('PASS R13 giant-space/sealed-snap Lua generated from exact R12')
PY_PATCH

if ! python3 -m py_compile "$TMP/patch_r13_lua.py"; then
    fail 40 "embedded R13 patcher does not compile"
fi
if ! python3 "$TMP/patch_r13_lua.py" --selftest; then
    fail 41 "R13 structural/behavior selftest failed"
fi
if ! python3 "$TMP/patch_r13_lua.py" "$TMP/visgrid-r12.lua" "$TMP/visgrid-r13.lua"; then
    fail 42 "R13 Lua transformation failed"
fi

echo
echo "===== 4/6 PARSE GENERATED LUA + VERIFY FOUR-RAY BUDGET ====="
if ! docker cp "$TMP/visgrid-r13.lua" "$CTR:/tmp/visgrid-r13.lua" >/dev/null; then
    fail 43 "could not stage R13 Lua for parsing"
fi
LUA_PARSER="$(docker exec "$CTR" bash -lc 'for x in luajit lua texlua; do command -v "$x" >/dev/null 2>&1 && { echo "$x"; exit 0; }; done; exit 1' 2>/dev/null || true)"
if [ -n "$LUA_PARSER" ]; then
    if [ "$LUA_PARSER" = "texlua" ]; then
        if ! docker exec "$CTR" texlua --luaconly /tmp/visgrid-r13.lua; then
            fail 44 "generated R13 Lua syntax failed texlua --luaconly"
        fi
    else
        if ! docker exec -e R13_LUA_FILE=/tmp/visgrid-r13.lua "$CTR" "$LUA_PARSER" -e \
            'local p=os.getenv("R13_LUA_FILE"); local f,e=loadfile(p); assert(f,e); print("LUA_PARSE_PASS " .. p)'
        then
            fail 44 "generated R13 Lua syntax validation failed"
        fi
    fi
else
    echo "INFO: no Lua CLI in Docker; compiling a LuaJIT syntax checker."
    if ! docker exec -i "$CTR" bash -s <<'REMOTE_LUA_CHECK'
set -u
HEADER="$(find /usr/include /usr/local/include -type f -name lua.h -path '*luajit*' -print 2>/dev/null | head -1)"
[ -n "$HEADER" ] || exit 1
INC="$(dirname "$HEADER")"
LIB="$(find /usr/lib /usr/local/lib \( -type f -o -type l \) -name 'libluajit-5.1.so*' -print 2>/dev/null | head -1)"
[ -n "$LIB" ] || exit 2
CC=""
for c in gcc-13 gcc cc; do command -v "$c" >/dev/null 2>&1 && { CC="$c"; break; }; done
[ -n "$CC" ] || exit 3
cat > /tmp/r13_lua_check.c <<'C_CHECK'
#include <stdio.h>
#include <lua.h>
#include <lauxlib.h>
int main(int argc, char **argv) {
    lua_State *L; int rc;
    if (argc != 2) return 2;
    L = luaL_newstate(); if (!L) return 3;
    rc = luaL_loadfile(L, argv[1]);
    if (rc != 0) {
        const char *msg = lua_tostring(L, -1);
        fprintf(stderr, "LUA_PARSE_FAIL: %s\n", msg ? msg : "unknown");
        lua_close(L); return 4;
    }
    lua_close(L); printf("LUA_PARSE_PASS %s\n", argv[1]); return 0;
}
C_CHECK
"$CC" -O2 -I"$INC" /tmp/r13_lua_check.c "$LIB" -lm -ldl -pthread -o /tmp/r13_lua_check || exit 4
/tmp/r13_lua_check /tmp/visgrid-r13.lua || exit 5
REMOTE_LUA_CHECK
    then
        fail 44 "generated R13 Lua could not be syntax-validated"
    fi
fi

python3 - "$TMP/visgrid-r12.lua" "$TMP/visgrid-r13.lua" <<'PY_VERIFY'
import sys
before=open(sys.argv[1],encoding='utf-8').read()
after=open(sys.argv[2],encoding='utf-8').read()
for token in (
    'TSP_ROOMRAY_LUA_V30_R11_FIVE_TIER_XY_HEIGHT',
    'TSP_ROOMRAY_LUA_V30_R12_LONG_PRIORITY',
    'TSP_ROOMRAY_LUA_V30_R13_GIANT_SHARED_SPACE',
    'mapState.r11SampleFour = function()',
    'mapState.r11CastDirection(eye, 0.28 + dx, 0.50 + dy)',
    'mapState.r11CastDirection(eye, 0.50,      0.50)',
    'mapState.r11CastDirection(eye, 0.72 - dx, 0.50 - dy)',
    'mapState.r11CastDirection(eye, 0.50 + dy, 0.24 + dx)',
    'mapState.r12LongWindow = 0.65',
    'mapState.r12ShrinkRequired = 10',
    '[TSP_ROOMRAY_R12] LONG-SNAP',
    '[TSP_ROOMRAY_R12] CONTRACT',
    '[TSP_ROOMRAY_R13] GIANT-ENTER',
    '[TSP_ROOMRAY_R13] GIANT-PVS',
    '[TSP_ROOMRAY_R13] SEALED-ENTER',
    '[TSP_ROOMRAY_R13] SEALED-EXIT',
):
    if token not in after:
        raise SystemExit('FAIL R13 semantic token missing: ' + token)
if before.count('mapState.r11CastDirection(eye,') != after.count('mapState.r11CastDirection(eye,'):
    raise SystemExit('FAIL R13 changed four-ray call-site count')
if after.count('mapState.r11CastDirection(eye,') != 4:
    raise SystemExit('FAIL R13 expected exactly four R11 ray call sites, got %d'
                     % after.count('mapState.r11CastDirection(eye,'))
if 'weighted = ordered[1] * 0.10 + ordered[2] * 0.25 + ordered[3] * 0.65' in after:
    raise SystemExit('FAIL obsolete weighted XY classifier survived')
if after.count('mapState.r13BasePvsIds[r13i] = ids[r13i]') != 1:
    raise SystemExit('FAIL R13 base-PVS ID capture count is not exactly one')
print('PASS exact four-ray budget and R12 policy preserved; giant PVS capture is unique')
PY_VERIFY

R13_LUA_SHA="$(sha256sum "$TMP/visgrid-r13.lua" | awk '{print $1}')"
echo "PASS generated R13 Lua SHA: $R13_LUA_SHA"

echo
echo "===== 5/6 INSTALL LUA/PROFILE TRANSACTIONALLY ====="
if ! scp -q "$TMP/visgrid-r13.lua" "$DEV:/tmp/visgrid-r13.lua"; then
    fail 50 "could not upload staged R13 Lua"
fi
if ! ssh "$DEV" 'bash -s' -- \
    /tmp/visgrid-r13.lua "$R13_LUA_SHA" "$LUA" "$PROFILE" \
    "$BIN" "$EXPECTED_R12_BIN_SHA" <<'REMOTE_INSTALL'
set -u
STAGED="$1"; EXPECTED_LUA="$2"; LIVE="$3"; PROFILE="$4"; BIN="$5"; EXPECTED_BIN="$6"
[ -s "$STAGED" ] || exit 1
[ "$(sha256sum "$STAGED" | awk '{print $1}')" = "$EXPECTED_LUA" ] || exit 2
[ "$(sha256sum "$BIN" | awk '{print $1}')" = "$EXPECTED_BIN" ] || exit 3
grep -Fq 'TSP_ROOMRAY_LUA_V30_R13_GIANT_SHARED_SPACE' "$STAGED" || exit 4
install -m 644 "$STAGED" "$PROFILE" || exit 5
install -m 644 "$STAGED" "$LIVE" || exit 6
sync
for f in "$PROFILE" "$LIVE"; do
    [ "$(sha256sum "$f" | awk '{print $1}')" = "$EXPECTED_LUA" ] || exit 7
    grep -Fq 'TSP_ROOMRAY_LUA_V30_R13_GIANT_SHARED_SPACE' "$f" || exit 8
done
rm -f "$STAGED"
echo "PASS installed exact R13 Lua/profile; R12 binary unchanged"
REMOTE_INSTALL
then
    echo "INSTALL FAILED — restoring exact R12 Lua/profile..." >&2
    restore_device_backup "$DEVICE_BACKUP" || true
    fail 51 "R13 device install failed; restoration attempted"
fi

FINAL_BIN_SHA="$(remote_sha "$BIN")"
FINAL_LUA_SHA="$(remote_sha "$LUA")"
if [ "$FINAL_BIN_SHA" != "$EXPECTED_R12_BIN_SHA" ] || [ "$FINAL_LUA_SHA" != "$R13_LUA_SHA" ]; then
    restore_device_backup "$DEVICE_BACKUP" || true
    fail 52 "R13 final device verification failed; restoration attempted"
fi

echo
echo "===== 6/6 ARM CAPTURE + SAVE ROLLBACK STATE ====="
if ! ssh "$DEV" 'bash -s' -- "$GAMELOG" "$ARM" <<'REMOTE_ARM'
set -u
LOG="$1"; ARM="$2"
[ -f "$LOG" ] || exit 1
LINES="$(wc -l < "$LOG" | tr -d '[:space:]')"
case "$LINES" in ''|*[!0-9]*) exit 2;; esac
printf '%s\n' "$LINES" > "$ARM" || exit 3
echo "PASS R13 capture armed after log line: $LINES"
REMOTE_ARM
then
    restore_device_backup "$DEVICE_BACKUP" || true
    fail 53 "R13 capture arm failed; exact R12 Lua restoration attempted"
fi

cat > "$STATE" <<EOF_STATE
R13_DEVICE_BACKUP='$DEVICE_BACKUP'
R13_OLD_BIN_SHA='$EXPECTED_R12_BIN_SHA'
R13_OLD_LUA_SHA='$EXPECTED_R12_LUA_SHA'
R13_NEW_LUA_SHA='$R13_LUA_SHA'
EOF_STATE
if [ ! -s "$STATE" ]; then
    restore_device_backup "$DEVICE_BACKUP" || true
    fail 54 "R13 state file write failed; exact R12 Lua restoration attempted"
fi

echo
echo "============================================================"
echo "V30 R13-R1 GIANT-SPACE / SEALED-SNAP INSTALLED"
echo "============================================================"
echo "Binary unchanged: $FINAL_BIN_SHA"
echo "R12 Lua:          $EXPECTED_R12_LUA_SHA"
echo "R13 Lua:          $FINAL_LUA_SHA"
echo
echo "Test once through the previous failure locations."
echo "Expected behavior:"
echo "  - R12 LONG-SNAP and contraction behavior remains unchanged"
echo "  - GIANT-ENTER follows combined tall-up + deep-forward proof"
echo "  - GIANT-PVS adds only bounded overlapping cross-floor sectors"
echo "  - Z stays open while giant shared-space authority is active"
echo "  - SEALED-ENTER reaches existing tier 4 after 10 unanimous samples"
echo "  - SEALED-EXIT fails fully open on the first disagreement"
echo
echo "Collect:"
echo "  cd ~/Downloads"
echo "  ./apply_openmw51_tsp_roomwake_v30_R13_R1_giant_space_sealed_snap.sh collect"
echo
echo "Rollback to exact successful R12 Lua:"
echo "  ./apply_openmw51_tsp_roomwake_v30_R13_R1_giant_space_sealed_snap.sh rollback"
echo "Controller log: $RUNLOG"
echo "============================================================"
