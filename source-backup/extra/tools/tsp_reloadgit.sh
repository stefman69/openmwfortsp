#!/usr/bin/env bash
# TSP_RELOADGIT_V1 - stop guessing at mechanisms. Read the code and the history.
#
#   bash ~/Downloads/tsp_reloadgit.sh
#
# READ ONLY. No build, no deploy, no patch, nothing written to the source tree.
#
# Why this instead of another theory: /root/openmw-0.51-tsp-src is a git repo and
# every patch block commits before it builds. The reload was fixed on 2026-09-09.
# So the commit that fixed it, and anything that has touched those files since,
# are both already recorded. I have been grepping logs and inferring from memory
# numbers when `git log -p` would have answered it outright.
#
# The 09-09 fix had TWO halves and I have only been chasing one of them:
#   1. TSP_NO_LOADPURGE=1  - config. We now know nothing was delivering it until
#      tonight, so this half has been dead for days.
#   2. TSP_GMAP_CAMERA_DRAIN_V1 in MWRender::GlobalMap::clear() - SOURCE. It
#      drains mActiveCameras / pending-removal so `mOverlayImage = image` on the
#      next load frees the old overlay instead of handing it to a lingering
#      camera. That half is code, it can be lost in a rebuild or a revert, and I
#      have never once checked whether it is still there.
#      Note from the 09-09 doc: the marker exists only in a COMMENT and does not
#      survive compilation, so a binary grep for it is meaningless. Grep the
#      Log() string TSP_GMAP_MEM_V1 instead. Section 6 does that.
#
# Also checked, because my own build could have done it: I ran
# `git add -A && git commit` in a tree TWO chats write to, then built and
# deployed. If the other lane had reverted or half-applied something, my commit
# captured it and my build shipped it. Section 3 shows exactly what each recent
# commit touched.

set -u
OUT="${HOME}/Downloads/tsp-reloadgit-$(date +%Y%m%d-%H%M%S).txt"
CONT=""
SRC=""
KNOWN="/root/openmw-0.51-tsp-src"
TSP="root@192.168.1.12"
SSH_OPTS="-o ConnectTimeout=8 -o StrictHostKeyChecking=no -o BatchMode=yes"
BIN="/mnt/SDCARD/data/ports/openmw/bin/openmw-0.51"

r() { ssh -n $SSH_OPTS "$TSP" "$@"; }

{
echo "########## 0. WHERE THE SOURCE IS ##########"
if ! command -v docker >/dev/null 2>&1; then
    echo "  docker not on PATH - cannot reach the source tree"
    exit 0
fi
for c in $(docker ps -a --format '{{.Names}}' 2>/dev/null); do
    if docker exec "$c" test -d "$KNOWN/.git" 2>/dev/null; then CONT="$c"; SRC="$KNOWN"; break; fi
done
if [ -z "$SRC" ]; then
    for c in $(docker ps -a --format '{{.Names}}' 2>/dev/null); do
        hit="$(docker exec "$c" sh -c "find / /root /home /src -maxdepth 5 -type d -name mwsound 2>/dev/null | head -1" 2>/dev/null)"
        if [ -n "$hit" ]; then
            CONT="$c"
            SRC="$(dirname "$(dirname "$(dirname "$hit")")")"
            break
        fi
    done
fi
[ -n "$SRC" ] || { echo "  NO SOURCE TREE FOUND in any container"; exit 0; }
echo "  container: $CONT"
echo "  source:    $SRC"

g() { docker exec "$CONT" git -C "$SRC" "$@" 2>&1; }
q() { docker exec "$CONT" sh -c "$1" 2>/dev/null; }

echo
echo "########## 1. IS THE TREE CLEAN - does the source match what was built ##########"
echo "  Any modified file here means the deployed binary was built from something"
echo "  other than what git records, and the other chat may be mid-edit."
S="$(g status --porcelain)"
if [ -z "$S" ]; then echo "  clean - no uncommitted changes"; else echo "$S" | head -40 | sed 's/^/    /'; fi
echo
echo "  -- current HEAD --"
g log -1 --pretty='    %h %ad %an%n    %s' --date=iso

echo
echo "########## 2. HISTORY, LAST 30 COMMITS, WITH DATES ##########"
g log -30 --pretty='    %h  %ad  %s' --date=short

echo
echo "########## 3. WHAT EVERY COMMIT SINCE 09-08 TOUCHED ##########"
echo "  The 09-09 reload fix is in here somewhere, and so is anything that"
echo "  undid it - including my own sndwarm commit, which used git add -A."
g log --since=2026-09-08 --pretty='  === %h %ad %s' --date=short --name-status

echo
echo "########## 4. WHERE THE RELOAD / RESTART / PURGE CODE LIVES NOW ##########"
for pat in tspRestartForSaveLoad TSP_MEMGATE TSP_NO_LOADPURGE TSP_RELOAD_MEM_FLOOR_KB TSP_LOADPURGE mOverlayImage mActiveCameras cleanupCameras markForRemoval; do
    echo "  -- $pat --"
    q "grep -rn --include=*.cpp --include=*.hpp '$pat' '$SRC/apps' '$SRC/components' 2>/dev/null | head -8" | sed 's/^/      /'
done

echo
echo "########## 5. THE GLOBAL MAP CLEAR - THE SOURCE HALF OF THE 09-09 FIX ##########"
GM="$SRC/apps/openmw/mwrender/globalmap.cpp"
if q "test -f '$GM' && echo yes" | grep -q yes; then
    echo "  file: $GM"
    echo "  -- every TSP marker in it --"
    q "grep -n 'TSP_' '$GM'" | sed 's/^/      /'
    echo
    echo "  -- GlobalMap::clear(), verbatim --"
    LN="$(q "grep -n 'void GlobalMap::clear' '$GM' | head -1 | cut -d: -f1")"
    if [ -n "$LN" ]; then
        A=$((LN - 4)); [ "$A" -lt 1 ] && A=1
        B=$((LN + 45))
        q "awk -v a=$A -v b=$B '{ if (NR>=a && NR<=b) printf \"%6d  %s\\n\", NR, \$0 }' '$GM'" | sed 's/^/      /'
    else
        echo "      GlobalMap::clear not found - survey of every function in the file:"
        q "grep -n '^[A-Za-z_].*::.*(' '$GM' | head -30" | sed 's/^/        /'
    fi
    echo
    echo "  -- git history of THIS file --"
    g log -10 --pretty='      %h  %ad  %s' --date=short -- apps/openmw/mwrender/globalmap.cpp
    echo
    echo "  -- every change to it since 09-08, as a patch --"
    g log -p --since=2026-09-08 --pretty='      === %h %ad %s' --date=short -- apps/openmw/mwrender/globalmap.cpp
else
    echo "  globalmap.cpp NOT FOUND at $GM"
    q "find '$SRC/apps' -maxdepth 4 -name 'globalmap*' 2>/dev/null | head -5" | sed 's/^/    /'
fi

echo
echo "########## 6. THE PURGE / CLEANUP PATH, AND ITS HISTORY ##########"
echo "  TSP_NO_LOADPURGE gates a cleanup() that clears the resource cache on"
echo "  every load. Find its call site and show what has changed around it."
F="$(q "grep -rln --include=*.cpp 'TSP_NO_LOADPURGE' '$SRC/apps' '$SRC/components' 2>/dev/null | head -1")"
if [ -n "$F" ]; then
    echo "  file: $F"
    REL="$(echo "$F" | sed "s|^$SRC/||")"
    LN="$(q "grep -n 'TSP_NO_LOADPURGE' '$F' | head -1 | cut -d: -f1")"
    A=$((LN - 30)); [ "$A" -lt 1 ] && A=1
    B=$((LN + 30))
    q "awk -v a=$A -v b=$B '{ if (NR>=a && NR<=b) printf \"%6d  %s\\n\", NR, \$0 }' '$F'" | sed 's/^/      /'
    echo
    echo "  -- git history of $REL --"
    g log -10 --pretty='      %h  %ad  %s' --date=short -- "$REL"
    echo
    echo "  -- changes since 09-08 --"
    g log -p --since=2026-09-08 --pretty='      === %h %ad %s' --date=short -- "$REL"
else
    echo "  TSP_NO_LOADPURGE is not in the source at all."
    echo "  It IS a string in the deployed binary, so the binary is older than the"
    echo "  source, or the code was removed after that build. Section 3 says which."
fi

echo
echo "########## 7. THE RESTART-ON-SAVE-LOAD PATH ##########"
F2="$(q "grep -rln --include=*.cpp --include=*.hpp 'tspRestartForSaveLoad\|TSP_MEMGATE' '$SRC/apps' '$SRC/components' 2>/dev/null | head -2")"
if [ -n "$F2" ]; then
    for f in $F2; do
        echo "  file: $f"
        LN="$(q "grep -n 'tspRestartForSaveLoad\|TSP_MEMGATE' '$f' | head -1 | cut -d: -f1")"
        A=$((LN - 25)); [ "$A" -lt 1 ] && A=1
        B=$((LN + 45))
        q "awk -v a=$A -v b=$B '{ if (NR>=a && NR<=b) printf \"%6d  %s\\n\", NR, \$0 }' '$f'" | sed 's/^/      /'
        echo
    done
    echo "  This is the only path that re-execs the process. What gates it, what the"
    echo "  default floor is when TSP_RELOAD_MEM_FLOOR_KB is unset, and whether it"
    echo "  logs when it fires, are all visible above - no inference needed."
else
    echo "  no restart path in the source, yet TSP_RELOAD_MEM_FLOOR_KB IS a string"
    echo "  in the deployed binary. Same conclusion as section 6."
fi

echo
echo "########## 8. SOURCE vs DEPLOYED BINARY ##########"
echo "  Which markers are in the source, and which are in the binary on the card."
echo "  A marker in one and not the other localises the problem immediately."
printf '  %-32s %-10s %s\n' MARKER SOURCE BINARY
for m in TSP_GMAP_MEM_V1 TSP_NO_LOADPURGE TSP_RELOAD_MEM_FLOOR_KB TSP_LOAD_TRACE_051_V13 \
         TSP_PLAYERANIM_MEM_V1 TSP_WORLDCLEAR_MEM_V1 TSP_SNDWARM_V2 TSP_SNDCACHE_WARN_V2 \
         TSP_PURGE_CONFIG TSP_MEMGATE_V1; do
    IN_SRC="no"
    if q "grep -rq --include=*.cpp --include=*.hpp '$m' '$SRC/apps' '$SRC/components' 2>/dev/null && echo y" | grep -q y; then IN_SRC="yes"; fi
    IN_BIN="$(r "if grep -a -q '$m' $BIN 2>/dev/null; then echo yes; else echo no; fi")"
    printf '  %-32s %-10s %s\n' "$m" "$IN_SRC" "${IN_BIN:-unreachable}"
done
echo
echo "  source=yes binary=no  -> the tree has it but this binary predates it: rebuild"
echo "  source=no  binary=yes -> the code was removed after that build: git says when"
echo "  both yes              -> present and shipped"
echo "  both no               -> gone from both, and section 3 shows which commit"

echo
echo "########## 9. WHAT I WILL DO WITH THIS ##########"
cat <<'NOTE'
  One of three, and section 3 plus section 8 decide it between them - not me:

  A. A commit since 09-08 removed the globalmap drain or the purge gate. Then the
     fix is `git show <hash>` for the exact lines, restore them, incremental
     build, redeploy. No new theory required.

  B. Both are still in the source but the deployed binary predates them
     (source=yes binary=no). Then nothing is broken in the code and the repair is
     one incremental build - which also explains why it worked two days ago and
     not now, with no mystery at all.

  C. Both are in the source and in the binary. Then the reload regression is
     neither of these, and the next step is the restart path in section 7 read
     properly - what its default floor is with the env var unset, which is the
     one number that decides whether my patch armed it tonight.
NOTE
} 2>&1 | tee "$OUT"
echo
echo "full report: $OUT"
