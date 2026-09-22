#!/usr/bin/env bash
# OpenMW 0.51 / TrimUI Smart Pro
# V30 R12-R1: R11 five-tier controller with dominant two-long-ray expansion.
#
# LUA/PROFILE ONLY. No C++ source edit, no rebuild, no binary replacement,
# and no launcher change.
#
# Exact input required:
#   R11 binary e25f6edf...a3fab
#   R11 Lua    9dc4b2ed...7e2d0
#
# Policy:
#   - Keep exactly four rays every 0.20 seconds and all R11 XY/Z ranges.
#   - Use the three forward rays for XY; keep the up ray's R11 Z EMA.
#   - A forward witness is "dominant long" when it is at least 2x the
#     current tier's gameplay/render-bypass XY distance.
#   - Two dominant-long witnesses within 0.65 seconds immediately expand XY
#     to the smallest tier whose render distance covers the lower witness.
#   - One long witness cannot contract XY and remains evidence for 0.65 sec.
#   - Contraction is one tier at a time after 10 consecutive samples (2 sec)
#     where all three forward rays fit the next tier and do not disagree by
#     roughly 2x or more. Any long/discrepant report resets contraction votes.
#   - Cell/topology changes wipe the evidence and reinitialize from R11's R4
#     navmesh kind/AABB authority.
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
ARM="$ROOT/roomwake-r12-capture-start.line"

EXPECTED_R11_BIN_SHA="e25f6edfe90c6610be94b285a243d7d2b673a7412ac504a026f14976332a3fab"
EXPECTED_R11_LUA_SHA="9dc4b2ed05ca2d5f7d8a7fb44102035d537f93b86ab5a5ec8945deebaa47e2d0"

DL="$HOME/Downloads"
STAMP="$(date +%Y%m%d-%H%M%S)"
RUNLOG="$DL/openmw51-roomwake-r12-$STAMP.log"
STATE="$DL/openmw51-roomwake-r12.state"
TMP="$(mktemp -d "$DL/.roomwake-r12.XXXXXX")"
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
        echo "FAIL R12 restore path is empty" >&2
        return 1
    fi
    ssh "$DEV" 'bash -s' -- \
        "$backup" "$LUA" "$PROFILE" "$EXPECTED_R11_LUA_SHA" <<'REMOTE_RESTORE'
set -u
B="$1"; LIVE="$2"; PROFILE="$3"; EXPECTED="$4"
if [ ! -s "$B/visgrid.lua.before-r12" ] || [ ! -s "$B/profile.lua.before-r12" ]; then
    echo "FAIL R12 backup Lua files missing: $B" >&2
    exit 1
fi
for f in "$B/visgrid.lua.before-r12" "$B/profile.lua.before-r12"; do
    GOT="$(sha256sum "$f" | awk '{print $1}')"
    if [ "$GOT" != "$EXPECTED" ]; then
        echo "FAIL backup is not exact R11 Lua: $f expected=$EXPECTED actual=$GOT" >&2
        exit 2
    fi
done
install -m 644 "$B/visgrid.lua.before-r12" "$LIVE" || exit 3
install -m 644 "$B/profile.lua.before-r12" "$PROFILE" || exit 4
sync
for f in "$LIVE" "$PROFILE"; do
    GOT="$(sha256sum "$f" | awk '{print $1}')"
    if [ "$GOT" != "$EXPECTED" ]; then
        echo "FAIL restored R11 Lua SHA: $f expected=$EXPECTED actual=$GOT" >&2
        exit 5
    fi
done
echo "PASS exact R11 Lua/profile restored"
REMOTE_RESTORE
}

collect_action() {
    ensure_ssh
    local out="$DL/openmw51-roomwake-r12-validation-$STAMP.txt"
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
        echo "===== OPENMW 0.51 V30 R12 LONG-RAY PRIORITY VALIDATION ====="
        date
        echo "Binary SHA: $(remote_sha "$BIN")"
        echo "Lua SHA:    $(remote_sha "$LUA")"
        echo "Log lines: total=$total capture=$start..$total"
        echo
        sed -n "${start},${total}p" "$TMP/openmw.log" \
            | grep -E '\[TSP_ROOMRAY_R12\]|\[TSP_ROOMRAY_R11\] tier-change|\[TSP_ROOMOBJ_V30\]|\[TSP_VISGRID_V30_R4\]|\[TSP_ACTOR_V30\]|Lua.*error|failed to render' \
            || true
        if [ -s "$TMP/perf.txt" ]; then
            echo
            echo "===== PERF TAIL ====="
            tail -180 "$TMP/perf.txt"
        fi
    } > "$out"
    echo "PASS R12 validation: $out"
    echo "Upload that file for review."
}

rollback_action() {
    ensure_ssh
    if [ ! -s "$STATE" ]; then
        fail 22 "R12 rollback state missing: $STATE"
    fi
    # Generated locally by this exact controller.
    # shellcheck disable=SC1090
    . "$STATE"
    if [ "${R12_OLD_BIN_SHA:-}" != "$EXPECTED_R11_BIN_SHA" ] \
        || [ "${R12_OLD_LUA_SHA:-}" != "$EXPECTED_R11_LUA_SHA" ] \
        || [ -z "${R12_DEVICE_BACKUP:-}" ]; then
        fail 23 "R12 rollback state is incomplete or not based on exact R11"
    fi
    if [ "$(remote_sha "$BIN")" != "$EXPECTED_R11_BIN_SHA" ]; then
        fail 24 "device binary is no longer exact R11; refusing Lua-only rollback"
    fi
    restore_device_backup "$R12_DEVICE_BACKUP" \
        || fail 25 "R12 rollback could not restore exact R11 Lua"
    echo "PASS R12 rollback complete; binary unchanged and exact R11 Lua restored."
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
OPENMW 0.51 — ROOMWAKE V30 R12-R1
LONG-RAY PRIORITY / CONSENSUS CONTRACTION
============================================================
R11 five XY tiers, five Z tiers, four rays, and 0.20-second period unchanged.

XY EXPANSION:
  Two forward rays within 0.65 seconds at >=2x the current render-bypass XY
  immediately snap outward to cover the lower of the two long witnesses.

XY CONTRACTION:
  One tier inward only after 10 consecutive agreeing short samples (2 sec).
  Any recent long witness or roughly 2x discrepancy resets contraction votes.

HEIGHT:
  R11 upward-ray/navmesh Z authority unchanged.

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
echo "===== 1/6 VERIFY EXACT SUCCESSFUL R11 DEVICE STATE ====="
BIN_SHA="$(remote_sha "$BIN")"
LUA_SHA="$(remote_sha "$LUA")"
PROFILE_SHA="$(remote_sha "$PROFILE")"
if [ "$BIN_SHA" = "$EXPECTED_R11_BIN_SHA" ] \
    && [ "$LUA_SHA" = "$PROFILE_SHA" ] && [ -s "$STATE" ]; then
    # A safe no-op on an exact rerun. Do not mistake an already-installed R12
    # for a bad R11 baseline, as older controllers did.
    # shellcheck disable=SC1090
    . "$STATE"
    if [ "${R12_OLD_BIN_SHA:-}" = "$EXPECTED_R11_BIN_SHA" ] \
        && [ "${R12_OLD_LUA_SHA:-}" = "$EXPECTED_R11_LUA_SHA" ] \
        && [ -n "${R12_NEW_LUA_SHA:-}" ] \
        && [ "$LUA_SHA" = "$R12_NEW_LUA_SHA" ] \
        && ssh "$DEV" "grep -Fq 'TSP_ROOMRAY_LUA_V30_R12_LONG_PRIORITY' '$LUA'"; then
        echo "PASS exact R12 is already installed: $LUA_SHA"
        echo "No files changed. Use '$0 collect' after testing."
        exit 0
    fi
fi
if [ "$BIN_SHA" != "$EXPECTED_R11_BIN_SHA" ]; then
    echo "EXPECTED R11 BIN: $EXPECTED_R11_BIN_SHA" >&2
    echo "ACTUAL DEVICE:    $BIN_SHA" >&2
    fail 31 "device binary is not exact validated R11"
fi
if [ "$LUA_SHA" != "$EXPECTED_R11_LUA_SHA" ] || [ "$PROFILE_SHA" != "$EXPECTED_R11_LUA_SHA" ]; then
    echo "EXPECTED R11 LUA: $EXPECTED_R11_LUA_SHA" >&2
    echo "ACTUAL LIVE:      $LUA_SHA" >&2
    echo "ACTUAL PROFILE:   $PROFILE_SHA" >&2
    fail 32 "device Lua/profile is not exact validated R11"
fi
if ! ssh "$DEV" "grep -Fq 'TSP_ROOMRAY_LUA_V30_R11_FIVE_TIER_XY_HEIGHT' '$LUA' && ! grep -Fq 'TSP_ROOMRAY_LUA_V30_R12_LONG_PRIORITY' '$LUA'"; then
    fail 33 "exact R11 markers are not in the expected pre-R12 state"
fi
echo "PASS exact validated R11 binary: $BIN_SHA"
echo "PASS exact validated R11 Lua:    $LUA_SHA"

echo
echo "===== 2/6 BACK UP EXACT R11 LUA/PROFILE ====="
DEVICE_BACKUP="$ROOT/backups/roomwake-v30-r12-long-priority-$STAMP"
if ! ssh "$DEV" 'bash -s' -- \
    "$DEVICE_BACKUP" "$LUA" "$PROFILE" "$EXPECTED_R11_LUA_SHA" <<'REMOTE_BACKUP'
set -u
B="$1"; LIVE="$2"; PROFILE="$3"; EXPECTED="$4"
mkdir -p "$B" || exit 1
for spec in "$LIVE:visgrid.lua.before-r12" "$PROFILE:profile.lua.before-r12"; do
    SRC="${spec%%:*}"; NAME="${spec#*:}"
    [ -s "$SRC" ] || exit 2
    GOT="$(sha256sum "$SRC" | awk '{print $1}')"
    [ "$GOT" = "$EXPECTED" ] || exit 3
    install -m 644 "$SRC" "$B/$NAME" || exit 4
done
sha256sum "$B/visgrid.lua.before-r12" "$B/profile.lua.before-r12"
echo "PASS exact R11 Lua/profile backup: $B"
REMOTE_BACKUP
then
    fail 34 "R12 device backup failed"
fi

if ! scp -q "$DEV:$PROFILE" "$TMP/visgrid-r11.lua"; then
    fail 35 "could not pull exact R11 profile"
fi
if [ "$(sha256sum "$TMP/visgrid-r11.lua" | awk '{print $1}')" != "$EXPECTED_R11_LUA_SHA" ]; then
    fail 36 "pulled R11 profile SHA changed after preflight"
fi

echo
echo "===== 3/6 GENERATE + SELFTEST R12 LUA ====="
cat > "$TMP/patch_r12_lua.py" <<'PY_PATCH'
#!/usr/bin/env python3
import sys

MARK = 'TSP_ROOMRAY_LUA_V30_R12_LONG_PRIORITY'


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
    print('PASS R12 Lua selftest: two-long snap + consensus-only tier contraction')


if len(sys.argv) == 2 and sys.argv[1] == '--selftest':
    selftest()
    raise SystemExit(0)
if len(sys.argv) != 3:
    raise SystemExit('usage: patch_r12_lua.py INPUT_R11_LUA OUTPUT_R12_LUA | --selftest')
write(sys.argv[2], patch_lua(read(sys.argv[1])))
print('PASS R12 long-ray-priority Lua generated from exact R11')
PY_PATCH

if ! python3 -m py_compile "$TMP/patch_r12_lua.py"; then
    fail 40 "embedded R12 patcher does not compile"
fi
if ! python3 "$TMP/patch_r12_lua.py" --selftest; then
    fail 41 "R12 structural/behavior selftest failed"
fi
if ! python3 "$TMP/patch_r12_lua.py" "$TMP/visgrid-r11.lua" "$TMP/visgrid-r12.lua"; then
    fail 42 "R12 Lua transformation failed"
fi

echo
echo "===== 4/6 PARSE GENERATED LUA + VERIFY FOUR-RAY BUDGET ====="
if ! docker cp "$TMP/visgrid-r12.lua" "$CTR:/tmp/visgrid-r12.lua" >/dev/null; then
    fail 43 "could not stage R12 Lua for parsing"
fi
LUA_PARSER="$(docker exec "$CTR" bash -lc 'for x in luajit lua texlua; do command -v "$x" >/dev/null 2>&1 && { echo "$x"; exit 0; }; done; exit 1' 2>/dev/null || true)"
if [ -n "$LUA_PARSER" ]; then
    if [ "$LUA_PARSER" = "texlua" ]; then
        if ! docker exec "$CTR" texlua --luaconly /tmp/visgrid-r12.lua; then
            fail 44 "generated R12 Lua syntax failed texlua --luaconly"
        fi
    else
        if ! docker exec -e R12_LUA_FILE=/tmp/visgrid-r12.lua "$CTR" "$LUA_PARSER" -e \
            'local p=os.getenv("R12_LUA_FILE"); local f,e=loadfile(p); assert(f,e); print("LUA_PARSE_PASS " .. p)'
        then
            fail 44 "generated R12 Lua syntax validation failed"
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
cat > /tmp/r12_lua_check.c <<'C_CHECK'
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
"$CC" -O2 -I"$INC" /tmp/r12_lua_check.c "$LIB" -lm -ldl -pthread -o /tmp/r12_lua_check || exit 4
/tmp/r12_lua_check /tmp/visgrid-r12.lua || exit 5
REMOTE_LUA_CHECK
    then
        fail 44 "generated R12 Lua could not be syntax-validated"
    fi
fi

python3 - "$TMP/visgrid-r11.lua" "$TMP/visgrid-r12.lua" <<'PY_VERIFY'
import sys
before=open(sys.argv[1],encoding='utf-8').read()
after=open(sys.argv[2],encoding='utf-8').read()
for token in (
    'TSP_ROOMRAY_LUA_V30_R11_FIVE_TIER_XY_HEIGHT',
    'TSP_ROOMRAY_LUA_V30_R12_LONG_PRIORITY',
    'mapState.r11SampleFour = function()',
    'mapState.r11CastDirection(eye, 0.28 + dx, 0.50 + dy)',
    'mapState.r11CastDirection(eye, 0.50,      0.50)',
    'mapState.r11CastDirection(eye, 0.72 - dx, 0.50 - dy)',
    'mapState.r11CastDirection(eye, 0.50 + dy, 0.24 + dx)',
    'mapState.r12LongWindow = 0.65',
    'mapState.r12ShrinkRequired = 10',
    '[TSP_ROOMRAY_R12] LONG-SNAP',
    '[TSP_ROOMRAY_R12] CONTRACT',
):
    if token not in after:
        raise SystemExit('FAIL R12 semantic token missing: ' + token)
if before.count('mapState.r11CastDirection(eye,') != after.count('mapState.r11CastDirection(eye,'):
    raise SystemExit('FAIL R12 changed four-ray call-site count')
if after.count('mapState.r11CastDirection(eye,') != 4:
    raise SystemExit('FAIL R12 expected exactly four R11 ray call sites, got %d'
                     % after.count('mapState.r11CastDirection(eye,'))
if 'weighted = ordered[1] * 0.10 + ordered[2] * 0.25 + ordered[3] * 0.65' in after:
    raise SystemExit('FAIL obsolete weighted XY classifier survived')
print('PASS exact four-ray budget preserved; only XY authority policy changed')
PY_VERIFY

R12_LUA_SHA="$(sha256sum "$TMP/visgrid-r12.lua" | awk '{print $1}')"
echo "PASS generated R12 Lua SHA: $R12_LUA_SHA"

echo
echo "===== 5/6 INSTALL LUA/PROFILE TRANSACTIONALLY ====="
if ! scp -q "$TMP/visgrid-r12.lua" "$DEV:/tmp/visgrid-r12.lua"; then
    fail 50 "could not upload staged R12 Lua"
fi
if ! ssh "$DEV" 'bash -s' -- \
    /tmp/visgrid-r12.lua "$R12_LUA_SHA" "$LUA" "$PROFILE" \
    "$BIN" "$EXPECTED_R11_BIN_SHA" <<'REMOTE_INSTALL'
set -u
STAGED="$1"; EXPECTED_LUA="$2"; LIVE="$3"; PROFILE="$4"; BIN="$5"; EXPECTED_BIN="$6"
[ -s "$STAGED" ] || exit 1
[ "$(sha256sum "$STAGED" | awk '{print $1}')" = "$EXPECTED_LUA" ] || exit 2
[ "$(sha256sum "$BIN" | awk '{print $1}')" = "$EXPECTED_BIN" ] || exit 3
grep -Fq 'TSP_ROOMRAY_LUA_V30_R12_LONG_PRIORITY' "$STAGED" || exit 4
install -m 644 "$STAGED" "$PROFILE" || exit 5
install -m 644 "$STAGED" "$LIVE" || exit 6
sync
for f in "$PROFILE" "$LIVE"; do
    [ "$(sha256sum "$f" | awk '{print $1}')" = "$EXPECTED_LUA" ] || exit 7
    grep -Fq 'TSP_ROOMRAY_LUA_V30_R12_LONG_PRIORITY' "$f" || exit 8
done
rm -f "$STAGED"
echo "PASS installed exact R12 Lua/profile; R11 binary unchanged"
REMOTE_INSTALL
then
    echo "INSTALL FAILED — restoring exact R11 Lua/profile..." >&2
    restore_device_backup "$DEVICE_BACKUP" || true
    fail 51 "R12 device install failed; restoration attempted"
fi

FINAL_BIN_SHA="$(remote_sha "$BIN")"
FINAL_LUA_SHA="$(remote_sha "$LUA")"
if [ "$FINAL_BIN_SHA" != "$EXPECTED_R11_BIN_SHA" ] || [ "$FINAL_LUA_SHA" != "$R12_LUA_SHA" ]; then
    restore_device_backup "$DEVICE_BACKUP" || true
    fail 52 "R12 final device verification failed; restoration attempted"
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
echo "PASS R12 capture armed after log line: $LINES"
REMOTE_ARM
then
    restore_device_backup "$DEVICE_BACKUP" || true
    fail 53 "R12 capture arm failed; exact R11 Lua restoration attempted"
fi

cat > "$STATE" <<EOF_STATE
R12_DEVICE_BACKUP='$DEVICE_BACKUP'
R12_OLD_BIN_SHA='$EXPECTED_R11_BIN_SHA'
R12_OLD_LUA_SHA='$EXPECTED_R11_LUA_SHA'
R12_NEW_LUA_SHA='$R12_LUA_SHA'
EOF_STATE
if [ ! -s "$STATE" ]; then
    restore_device_backup "$DEVICE_BACKUP" || true
    fail 54 "R12 state file write failed; exact R11 Lua restoration attempted"
fi

echo
echo "============================================================"
echo "V30 R12-R1 LONG-RAY PRIORITY INSTALLED"
echo "============================================================"
echo "Binary unchanged: $FINAL_BIN_SHA"
echo "R11 Lua:          $EXPECTED_R11_LUA_SHA"
echo "R12 Lua:          $FINAL_LUA_SHA"
echo
echo "Test once through the previous failure locations."
echo "Expected behavior:"
echo "  - [TSP_ROOMRAY_R12] LONG-SNAP after two >=2x witnesses within 0.65 sec"
echo "  - one long/discrepant ray holds the current XY tier"
echo "  - [TSP_ROOMRAY_R12] CONTRACT after 10 agreeing samples per inward tier"
echo "  - Z continues to respond independently to the upward ray"
echo
echo "Collect:"
echo "  cd ~/Downloads"
echo "  ./apply_openmw51_tsp_roomwake_v30_R12_R1_long_ray_priority.sh collect"
echo
echo "Rollback to exact successful R11 Lua:"
echo "  ./apply_openmw51_tsp_roomwake_v30_R12_R1_long_ray_priority.sh rollback"
echo "Controller log: $RUNLOG"
echo "============================================================"
