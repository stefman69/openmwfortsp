#!/usr/bin/env bash
set -Eeuo pipefail

cd "$HOME/Downloads"

DEV="${TSP_DEV:-root@192.168.1.25}"
SSH=(-o BatchMode=yes -o ConnectTimeout=8)
ROOT="/mnt/SDCARD/data/ports/openmw51"
MOD="$ROOT/mods/TSPInteriorVisGrid"
LUA="$MOD/scripts/TSPInteriorVisGrid/visgrid.lua"
TOPO="$MOD/scripts/TSPInteriorVisGrid/topology.lua"
DB="/mnt/UDISK/openmw51-nav/navmesh.db"
BIN="$ROOT/bin/openmw-0.51"

EXPECTED_V21_SHA="d41fd6e77765aa0fa1c468027400501d0e83eb284068b26340078026a0f35150"
EXPECTED_V21_1_SHA="6072186e2e0983347c2009ba48dcc9d2ff0b26fb279cbbd86d56890b9aab3d4b"
EXPECTED_GAME_SHA="5ba39a9869c592f1e21349521ad19fce0a04c6d03bb378c22170929c9792c555"
EXPECTED_TOPO_SHA="528802bf4e8913dc3629c5c46f204b01ab0087de533331ca3ef6d5f86bbfafc4"
EXPECTED_DB_STAT="934629376 1787961889"

STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="$HOME/Downloads/openmw51-visgrid-v21-1-$STAMP"
LOG="$OUT/controller.log"
mkdir -p "$OUT"

fail() {
    rc=$?
    line="${1:-?}"
    cmd="${2:-?}"
    trap - ERR
    {
        echo
        echo "=================================================================="
        echo "V21.1 CONTROLLER STOPPED"
        echo "=================================================================="
        echo "Exit code: $rc"
        echo "Line:      $line"
        echo "Command:   $cmd"
        echo "Output:    $OUT"
        echo
        [ -s "$LOG" ] && {
            echo "----- log tail -----"
            tail -220 "$LOG" || true
        }
    } | tee "$OUT/STOPPED_ERROR.txt"
    exit "$rc"
}
trap 'fail "$LINENO" "$BASH_COMMAND"' ERR
exec > >(tee "$LOG") 2>&1

echo "=================================================================="
echo "OPENMW 0.51 — VISGRID V21.1 STABLE APERTURE HYSTERESIS"
echo "=================================================================="
echo "This is a targeted sensing tune on the exact installed V21."
echo
cat <<'EOF'
Changes only:
  - neighboring close rays may REFRESH an aperture but never disprove it
  - only the saved exact witness direction may retire a proven opening
  - exact-witness retirement is frozen during camera turns + turn linger
  - camera view-away becomes 2.5s dormant memory, not a 0.18s deletion
  - a sudden deep->near collapse >=1200 units needs 5 exact failures
    instead of 3 before the remembered opening is forgotten

No OpenMW-running process gate is used.
The game binary, doorgraph, global topology and navmesh DB are not modified.
Restart OpenMW after installation if it is currently open.
EOF

echo "=================================================================="

echo
echo "===== 1/6 FETCH + VERIFY EXACT LIVE V21 ====="
scp -q "${DEV}:$LUA" "$OUT/visgrid-v21-live.lua"

LIVE_SHA="$(sha256sum "$OUT/visgrid-v21-live.lua" | awk '{print $1}')"
GAME_BEFORE="$(ssh "${SSH[@]}" "$DEV" "sha256sum '$BIN'" | awk '{print $1}')"
TOPO_BEFORE="$(ssh "${SSH[@]}" "$DEV" "sha256sum '$TOPO'" | awk '{print $1}')"
DB_BEFORE="$(ssh "${SSH[@]}" "$DEV" "stat -c '%s %Y' '$DB'")"

printf 'live sensor SHA: %s\n' "$LIVE_SHA"
printf 'game SHA:        %s\n' "$GAME_BEFORE"
printf 'topology SHA:    %s\n' "$TOPO_BEFORE"
printf 'DB size/mtime:   %s\n' "$DB_BEFORE"

if [ "$LIVE_SHA" = "$EXPECTED_V21_1_SHA" ]; then
    echo "PASS: exact V21.1 is already installed."
    exit 0
fi

[ "$LIVE_SHA" = "$EXPECTED_V21_SHA" ] || {
    echo "ERROR: exact V21 input required; refusing to guess against another sensor."
    exit 20
}
[ "$GAME_BEFORE" = "$EXPECTED_GAME_SHA" ] || {
    echo "ERROR: game binary is not the protected build."
    exit 21
}
[ "$TOPO_BEFORE" = "$EXPECTED_TOPO_SHA" ] || {
    echo "ERROR: global topology loader changed unexpectedly."
    exit 22
}
[ "$DB_BEFORE" = "$EXPECTED_DB_STAT" ] || {
    echo "ERROR: canonical navmesh DB size/mtime changed unexpectedly."
    exit 23
}

grep -Fq 'TSP_VISGRID_LUA_V21_DOORGRAPH_VIEWHOLD' "$OUT/visgrid-v21-live.lua"

echo
 echo "===== 2/6 GENERATE DETERMINISTIC V21.1 ====="
cat > "$OUT/patch_v21_1.py" <<'PY_PATCH'
from pathlib import Path
import hashlib
import sys

EXPECTED_IN = "d41fd6e77765aa0fa1c468027400501d0e83eb284068b26340078026a0f35150"
EXPECTED_OUT = "6072186e2e0983347c2009ba48dcc9d2ff0b26fb279cbbd86d56890b9aab3d4b"


def replace_once(s, old, new, name):
    count = s.count(old)
    if count != 1:
        raise SystemExit(f"ERROR: {name}: expected exactly one anchor, got {count}")
    return s.replace(old, new, 1)


src = Path(sys.argv[1])
dst = Path(sys.argv[2])
raw = src.read_bytes()
sha = hashlib.sha256(raw).hexdigest()
if sha != EXPECTED_IN:
    raise SystemExit(f"ERROR: exact V21 SHA required; got {sha}")

s = raw.decode("utf-8")

s = replace_once(
    s,
    "-- TSP_VISGRID_LUA_V21_DOORGRAPH_VIEWHOLD  (real-door overlay + view-relative positive-ray memory)\n",
    "-- TSP_VISGRID_LUA_V21_DOORGRAPH_VIEWHOLD  (real-door overlay + view-relative positive-ray memory)\n"
    "-- TSP_VISGRID_LUA_V21_1_STABLE_APERTURE  (camera-turn freeze + exact-witness disproof)\n",
    "marker",
)

s = replace_once(
    s,
    """    rayViewHolds = {}, rayViewHoldCount = 0, rayViewHoldTouches = 0,
    rayViewHoldCloseReleases = 0, rayViewHoldAwayReleases = 0,
    rayViewHoldVerifyReleases = 0,
""",
    """    rayViewHolds = {}, rayViewHoldCount = 0, rayViewHoldTouches = 0,
    rayViewHoldCloseReleases = 0, rayViewHoldAwayReleases = 0,
    rayViewHoldVerifyReleases = 0,
    rayViewHoldJumpDefers = 0, rayViewHoldTurnSkips = 0,
""",
    "state counters",
)

s = replace_once(
    s,
    """    v21RayHoldInitial = 0.80,
    v21RayHoldAwayGrace = 0.18,
    v21RayHoldCloseVotes = 3,
    v21RayHoldCloseDrop = 280.0,
    v21RayHoldPositiveTol = 180.0,
""",
    """    v21RayHoldInitial = 0.80,
    -- V21.1: do not erase a proven aperture just because the camera sweeps
    -- past it. Off-screen holds are dormant (they render nothing) and are
    -- retired only after the view has been stably elsewhere for a while.
    v21RayHoldAwayGrace = 2.50,
    -- Neighbor jitter rays are expected to hit the wall/roof AROUND a narrow
    -- slit, so they are no longer allowed to vote the slit closed.
    v21RayHoldCloseVotes = 3,
    v21RayHoldCloseDrop = 280.0,
    v21RayHoldPositiveTol = 180.0,
    -- A large discontinuous depth collapse is suspicious. Require stronger
    -- exact-witness evidence before accepting that the deep space vanished.
    v21RayHoldJumpDrop = 1200.0,
    v21RayHoldJumpMisses = 5,
""",
    "hold policy",
)

s = replace_once(
    s,
    """    mapState.rayViewHoldVerifyReleases = 0
    gridMaybeArmed = true""",
    """    mapState.rayViewHoldVerifyReleases = 0
    mapState.rayViewHoldJumpDefers = 0
    mapState.rayViewHoldTurnSkips = 0
    gridMaybeArmed = true""",
    "runtime reset",
)

old_observe = """mapState.observeRayViewHold = function(idx, depth, wasMiss)
    if idx == nil or depth == nil or mapState.rayViewHoldCount <= 0 then return end
    local moving = vdState.spd >= V14.MOVE_EPS
    local turning = vdState.turnf ~= 0
    for hid, h in pairs(mapState.rayViewHolds) do
        if h ~= nil and mapState.rayViewBinsClose(idx, hid) then
            local positive = wasMiss
                or depth >= (h.depth or depth) - mapState.v21RayHoldPositiveTol
            if positive then
                if depth > (h.depth or 0.0) then h.depth = min(OPEN_DEPTH, depth) end
                h.closeVotes = 0
                h.awaySince = nil
                mapState.rayViewHoldTouches = mapState.rayViewHoldTouches + 1
            elseif h.confirmed == true and not moving and not turning
                and depth < (h.depth or depth) - mapState.v21RayHoldCloseDrop then
                h.closeVotes = (h.closeVotes or 0) + 1
                if h.closeVotes >= mapState.v21RayHoldCloseVotes then
                    mapState.dropRayViewHold(hid, 'close')
                end
            end
        end
    end
end
"""
new_observe = """mapState.observeRayViewHold = function(idx, depth, wasMiss)
    if idx == nil or depth == nil or mapState.rayViewHoldCount <= 0 then return end
    for hid, h in pairs(mapState.rayViewHolds) do
        if h ~= nil and mapState.rayViewBinsClose(idx, hid) then
            local positive = wasMiss
                or depth >= (h.depth or depth) - mapState.v21RayHoldPositiveTol
            if positive then
                if depth > (h.depth or 0.0) then h.depth = min(OPEN_DEPTH, depth) end
                h.closeVotes = 0
                h.awaySince = nil
                mapState.rayViewHoldTouches = mapState.rayViewHoldTouches + 1
            end
            -- V21.1: ordinary/neighbor jitter rays may REFRESH an aperture,
            -- but can NEVER disprove it. A slit is supposed to be surrounded
            -- by close roof/wall hits. Only its saved exact witness direction
            -- below owns retirement authority.
        end
    end
end
"""
s = replace_once(s, old_observe, new_observe, "neighbor close retirement")

s = replace_once(
    s,
    """            else
                if h.awaySince == nil then h.awaySince = interiorElapsed end
                if interiorElapsed - h.awaySince >= mapState.v21RayHoldAwayGrace then
                    drop[#drop + 1] = { hid, 'away' }
                end
            end
""",
    """            else
                -- Camera motion is not evidence that world-space geometry
                -- vanished. During a turn (including TURN_LINGER), keep the
                -- aperture dormant and do not even start its away timer.
                if vdState.turnf ~= 0 or turnLinger > 0.0 then
                    h.awaySince = nil
                    mapState.rayViewHoldTurnSkips
                        = mapState.rayViewHoldTurnSkips + 1
                else
                    if h.awaySince == nil then h.awaySince = interiorElapsed end
                    if interiorElapsed - h.awaySince >= mapState.v21RayHoldAwayGrace then
                        drop[#drop + 1] = { hid, 'away' }
                    end
                end
            end
""",
    "camera turn/away policy",
)

s = replace_once(
    s,
    """        else
            binDeepMiss[idx] = (binDeepMiss[idx] or 0) + 1
            pushRing(idx, m)
            if binDeepMiss[idx] >= DEEP_MISS_LIMIT then
                binDeepVal[idx] = nil
                binDeepJy[idx] = nil
                binDeepJp[idx] = nil
                binDeepMiss[idx] = 0
            end
        end
""",
    """        else
            binDeepMiss[idx] = (binDeepMiss[idx] or 0) + 1
            pushRing(idx, m)
            local missLimit = DEEP_MISS_LIMIT
            if dv - m >= mapState.v21RayHoldJumpDrop then
                missLimit = max(missLimit, mapState.v21RayHoldJumpMisses)
                mapState.rayViewHoldJumpDefers
                    = mapState.rayViewHoldJumpDefers + 1
            end
            if binDeepMiss[idx] >= missLimit then
                binDeepVal[idx] = nil
                binDeepJy[idx] = nil
                binDeepJp[idx] = nil
                binDeepMiss[idx] = 0
                mapState.dropRayViewHold(idx, 'close')
            end
        end
""",
    "exact witness retirement",
)

s = replace_once(
    s,
    """    if casts < budget and vdState.spd < V14.MOVE_EPS then
        local bestDeep, bestDeepAge = nil, DEEP_VERIFY_AGE - 1
""",
    """    if casts < budget and vdState.spd < V14.MOVE_EPS and not turning then
        local bestDeep, bestDeepAge = nil, DEEP_VERIFY_AGE - 1
""",
    "turn freeze exact verifier",
)

s = replace_once(
    s,
    """            ' v21=1 rh=%d rht=%d rhc=%d rha=%d rhv=%d rd=%d rdm=%d rdx=%d rdt=%d',
            mapState.rayViewHoldCount or 0, mapState.rayViewHoldTouches or 0,
            mapState.rayViewHoldCloseReleases or 0,
            mapState.rayViewHoldAwayReleases or 0,
            mapState.rayViewHoldVerifyReleases or 0,
            mapState.realDoorCount or 0, mapState.realDoorPortalMatches or 0,
            mapState.realDoorWorldExits or 0, mapState.realDoorTargetSectors or 0))
""",
    """            ' v21=1 rh=%d rht=%d rhc=%d rha=%d rhv=%d rhj=%d rhs=%d rd=%d rdm=%d rdx=%d rdt=%d',
            mapState.rayViewHoldCount or 0, mapState.rayViewHoldTouches or 0,
            mapState.rayViewHoldCloseReleases or 0,
            mapState.rayViewHoldAwayReleases or 0,
            mapState.rayViewHoldVerifyReleases or 0,
            mapState.rayViewHoldJumpDefers or 0,
            mapState.rayViewHoldTurnSkips or 0,
            mapState.realDoorCount or 0, mapState.realDoorPortalMatches or 0,
            mapState.realDoorWorldExits or 0, mapState.realDoorTargetSectors or 0))
""",
    "status fields",
)

s = replace_once(
    s,
    "print('[TSP_VISGRID_V21] real-door overlay + view-relative positive-ray memory loaded')\n",
    "print('[TSP_VISGRID_V21] real-door overlay + view-relative positive-ray memory loaded')\n"
    "print('[TSP_VISGRID_V21.1] stable-aperture hysteresis loaded (turn freeze + exact-witness disproof + jump guard)')\n",
    "runtime marker",
)

out = s.encode("utf-8")
out_sha = hashlib.sha256(out).hexdigest()
if out_sha != EXPECTED_OUT:
    raise SystemExit(f"ERROR: unexpected V21.1 output SHA {out_sha}")

for token in (
    "TSP_VISGRID_LUA_V21_1_STABLE_APERTURE",
    "ordinary/neighbor jitter rays may REFRESH an aperture",
    "and not turning then",
    "v21RayHoldJumpMisses = 5",
    "rhj=%d rhs=%d",
    "[TSP_VISGRID_V21.1] stable-aperture hysteresis loaded",
):
    if token not in s:
        raise SystemExit("ERROR: postcondition missing: " + token)

if 0 in out:
    raise SystemExit("ERROR: NUL byte in generated V21.1")

dst.write_bytes(out)
print("PASS: exact V21 -> V21.1 patch generated")
print("V21.1 SHA:", out_sha)
PY_PATCH

python3 -m py_compile "$OUT/patch_v21_1.py"
python3 "$OUT/patch_v21_1.py" \
    "$OUT/visgrid-v21-live.lua" \
    "$OUT/visgrid-v21-1.lua"

NEW_SHA="$(sha256sum "$OUT/visgrid-v21-1.lua" | awk '{print $1}')"
[ "$NEW_SHA" = "$EXPECTED_V21_1_SHA" ]

grep -Fq 'TSP_VISGRID_LUA_V21_1_STABLE_APERTURE' "$OUT/visgrid-v21-1.lua"
grep -Fq 'ordinary/neighbor jitter rays may REFRESH an aperture' "$OUT/visgrid-v21-1.lua"
grep -Fq '[TSP_VISGRID_V21.1] stable-aperture hysteresis loaded' "$OUT/visgrid-v21-1.lua"

# If a Lua CLI happens to exist, use it. The exact output SHA above is also
# the independently parse-validated V21.1 reference build.
if command -v luac >/dev/null 2>&1; then
    luac -p "$OUT/visgrid-v21-1.lua"
    echo "PASS: host luac syntax parse."
elif command -v lua >/dev/null 2>&1; then
    lua -e 'assert(loadfile(arg[1]))' "$OUT/visgrid-v21-1.lua"
    echo "PASS: host lua syntax parse."
else
    echo "NOTE: no host Lua CLI; exact independently parsed V21.1 SHA matched."
fi

echo "PASS: deterministic V21.1 generation verified."

echo
 echo "===== 3/6 INSTALL SENSOR ONLY ====="
BACKUP="$LUA.v21-before-v21-1-$STAMP"
scp -q "$OUT/visgrid-v21-1.lua" "${DEV}:$LUA.v21-1.new"

ssh "${SSH[@]}" "$DEV" "
set -e
cp -p '$LUA' '$BACKUP'
mv '$LUA.v21-1.new' '$LUA'
sync
sha256sum '$LUA'
"

echo
 echo "===== 4/6 VERIFY + ROLLBACK ON ANY PROTECTED CHANGE ====="
LIVE_AFTER="$(ssh "${SSH[@]}" "$DEV" "sha256sum '$LUA'" | awk '{print $1}')"
GAME_AFTER="$(ssh "${SSH[@]}" "$DEV" "sha256sum '$BIN'" | awk '{print $1}')"
TOPO_AFTER="$(ssh "${SSH[@]}" "$DEV" "sha256sum '$TOPO'" | awk '{print $1}')"
DB_AFTER="$(ssh "${SSH[@]}" "$DEV" "stat -c '%s %Y' '$DB'")"

VERIFY_OK=1
[ "$LIVE_AFTER" = "$EXPECTED_V21_1_SHA" ] || VERIFY_OK=0
[ "$GAME_AFTER" = "$GAME_BEFORE" ] || VERIFY_OK=0
[ "$TOPO_AFTER" = "$TOPO_BEFORE" ] || VERIFY_OK=0
[ "$DB_AFTER" = "$DB_BEFORE" ] || VERIFY_OK=0

if [ "$VERIFY_OK" -ne 1 ]; then
    echo "ERROR: verification failed. Restoring exact V21 sensor."
    ssh "${SSH[@]}" "$DEV" "
set -e
cp -p '$BACKUP' '$LUA'
sync
sha256sum '$LUA'
"
    exit 30
fi

printf 'sensor after:   %s\n' "$LIVE_AFTER"
printf 'game unchanged: %s\n' "$GAME_AFTER"
printf 'topology same:  %s\n' "$TOPO_AFTER"
printf 'DB same:        %s\n' "$DB_AFTER"

echo "PASS: only visgrid.lua changed V21 -> V21.1."

echo
 echo "===== 5/6 WRITE TRACE COLLECTOR ====="
COLLECT="$HOME/Downloads/pull-visgrid-v21-1-stable-aperture.sh"
cat > "$COLLECT" <<'TRACE'
#!/usr/bin/env bash
set -Eeuo pipefail
cd "$HOME/Downloads"
DEV="${TSP_DEV:-root@192.168.1.25}"
ROOT="/mnt/SDCARD/data/ports/openmw51"
LUA="$ROOT/mods/TSPInteriorVisGrid/scripts/TSPInteriorVisGrid/visgrid.lua"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="$HOME/Downloads/visgrid-v21-1-stable-aperture-$STAMP.txt"
{
    echo "===== V21.1 SENSOR ====="
    ssh "$DEV" "sha256sum '$LUA'; grep -n 'TSP_VISGRID_LUA_V21_1_STABLE_APERTURE' '$LUA' || true"
    echo
    echo "===== V21.1 SESSION ====="
    ssh "$DEV" '
ROOT="/mnt/SDCARD/data/ports/openmw51"
for LOG in "$ROOT/openmw_051_log.txt" "$ROOT/config-0.51/openmw.log"; do
  [ -s "$LOG" ] || continue
  echo
  echo "--- $LOG ---"
  tail -n 7000 "$LOG" | grep -E "TSP_VISGRID_V21\\.1|TSP_VISGRID_V21|TSP_VISGRID_V20|topology sector=|v21=1| ERROR #|sensor DISABLED" || true
done
'
} | tee "$OUT"
echo
echo "Saved:"
echo "  $OUT"
TRACE
chmod +x "$COLLECT"
echo "Collector: $COLLECT"

echo
 echo "===== 6/6 COMPLETE ====="
echo "=================================================================="
echo "VISGRID V21.1 INSTALL COMPLETE"
echo "=================================================================="
echo "V21.1 sensor SHA:"
echo "  $LIVE_AFTER"
echo
echo "Key new diagnostics:"
echo "  rhc = confirmed openings retired ONLY by exact witness failures"
echo "  rha = dormant openings retired after 2.5s stably out of view"
echo "  rhj = large depth-collapse failures deferred by jump guard"
echo "  rhs = hold-retirement opportunities skipped during camera turns"
echo
echo "The watch-tower test is especially useful because this session logged"
echo "sect=0 / pvsA=0 there, so it isolates the ray sensor from structural PVS."
echo
echo "Restart OpenMW before testing if it was open during installation."
echo "Then collect with:"
echo "  cd ~/Downloads"
echo "  ./pull-visgrid-v21-1-stable-aperture.sh"
echo
echo "Full controller log:"
echo "  $LOG"
echo "=================================================================="
