#!/bin/bash
# tsp_pinksky_fix.sh - TSP_PINKSKY_FIX_V1
#
# Two source patches, one build, one deploy.
#
#   TSP_EMPTY_CLOUDTEX_V1  apps/openmw/mwrender/sky.cpp
#       SkyManager::setWeather requests the cloud texture whenever the name
#       changes, with no empty-string guard - the mNextClouds branch 20 lines
#       below has one, this branch does not. An empty name becomes "textures/",
#       which cannot load. Unreachable from a cold boot because mClouds also
#       starts empty; reachable the moment any earlier save left a name behind.
#
#   TSP_WARNCACHE_V1       components/resource/imagemanager.cpp
#       All six failure branches in getImage bind mWarningImage to the path key.
#       With TSP_NO_LOADPURGE=1 that entry now survives a save load, so one bad
#       frame makes a texture magenta for the rest of the process, silently -
#       the failure logs once and every later request is a cache hit.
#       B1: a path with no filename part returns the warning image and is NOT
#           cached, so it can never poison a real path.
#       B2: a cache hit that returns the warning image now logs (first 16).
#
# Modes:  go (default) = backup, patch, verify, commit, build, gate, deploy
#         plan         = patch into a scratch copy and show the diff, write nothing
#         log          = pull the markers out of the device log after playing
#         rollback     = restore both .cpp from the newest backup, rebuild, redeploy
#
# No headers are touched, so this is a two-TU incremental build (agreement 19).

set -u

TSP=root@192.168.1.12
SSH_OPTS="-o BatchMode=yes -o ConnectTimeout=8 -o ServerAliveInterval=15"
G=/mnt/SDCARD/data/ports/openmw
BIN="$G/bin/openmw-0.51"
CTR=openmw_builder
SRC=/root/openmw-0.51-tsp-src
BLD=/root/openmw-0.51-tsp-build
MODE="${1:-go}"
STAMP=$(date +%Y%m%d-%H%M%S)

SKY=apps/openmw/mwrender/sky.cpp
IMG=components/resource/imagemanager.cpp
M1=TSP_EMPTY_CLOUDTEX_V1
M2=TSP_WARNCACHE_V1

# --- the only two ssh wrappers; bare ssh is a bug (agreement 28) -------------
r()   { ssh -n $SSH_OPTS "$TSP" "$@"; }
rin() { ssh    $SSH_OPTS "$TSP" "$@"; }
d()   { docker exec "$CTR" "$@" </dev/null; }
di()  { docker exec -i "$CTR" "$@"; }   # heredoc callers ONLY

say() { echo "$*"; }
die() { echo ""; echo "STOPPED: $*"; exit 1; }

say "TSP_PINKSKY_FIX_V1  mode=$MODE  stamp=$STAMP"

# ============================================================== log mode
if [ "$MODE" = "log" ]; then
  say "pulling the proof-log out of the device log"
  rin 'sh -s' <<'REMOTE'
G=/mnt/SDCARD/data/ports/openmw
L="$G/config/openmw.log"
if [ -f "$L" ]; then
  ls -l "$L"
  echo ""
  echo "--- TSP_EMPTY_CLOUDTEX_V1 (the sky guard firing)"
  grep -n 'TSP_EMPTY_CLOUDTEX_V1' "$L" | head -20
  echo "--- TSP_WARNCACHE_V1 (degenerate paths, and cached-magenta hits)"
  grep -n 'TSP_WARNCACHE_V1' "$L" | head -20
  echo "--- any image failure at all"
  grep -nE 'Failed to open image|Error loading|no readerwriter|no S3TC|cannot flip' "$L" | head -20
  echo "--- crash / signal"
  grep -niE 'signal|fatal|abort' "$L" | head -10
  echo ""
  echo "--- counts"
  echo "    cloudtex guard : $(grep -c TSP_EMPTY_CLOUDTEX_V1 "$L" ; true)"
  echo "    warncache      : $(grep -c TSP_WARNCACHE_V1 "$L" ; true)"
  echo "    image failures : $(grep -cE 'Failed to open image|Error loading' "$L" ; true)"
else
  echo "NO LOG at $L"
fi
if [ -f /mnt/SDCARD/tsp_crash.txt ]; then
  echo ""
  echo "--- tail of tsp_crash.txt (append-mode, survives restarts)"
  tail -25 /mnt/SDCARD/tsp_crash.txt
fi
REMOTE
  exit 0
fi

# ============================================================== preflight
say ""
say "[1/9] preflight"
d test -d "$SRC" >/dev/null 2>&1 || die "container $CTR not up, or $SRC missing"
d test -f "$BLD/build.ninja" >/dev/null 2>&1 || die "$BLD is not a ninja tree - refusing to build (agreement 22-A)"
say "      container up, ninja tree present"
say "      source md5 before:"
d sh -c "cd $SRC && md5sum $SKY $IMG" | sed 's/^/        /'

DEV_OK=0
if r 'echo tsp_ok' 2>/dev/null | grep -q tsp_ok; then DEV_OK=1; say "      device reachable"; else say "      device NOT reachable (build will still run; deploy will be skipped)"; fi

# ============================================================== rollback
if [ "$MODE" = "rollback" ]; then
  say ""
  say "[2/9] rollback: restoring the newest backup that is NOT already patched"
  di python3 - "$SRC" "$SKY" "$M1" "$IMG" "$M2" <<'PYEOF'
import sys, os, io, glob
src = sys.argv[1]
pairs = [(sys.argv[2], sys.argv[3]), (sys.argv[4], sys.argv[5])]
rc = 0
for rel, marker in pairs:
    p = os.path.join(src, rel)
    # newest FIRST, but skip any backup that already contains the marker - running
    # go twice used to back up its own output, and restoring that is a silent no-op.
    cands = sorted(glob.glob(p + ".before-pinksky-*"), key=os.path.getmtime, reverse=True)
    chosen = None
    for c in cands:
        with io.open(c, "r", encoding="utf-8") as f:
            if marker not in f.read():
                chosen = c
                break
    if chosen is None:
        print("   %-20s NO CLEAN BACKUP (%d candidates, all already patched)" % (os.path.basename(rel), len(cands)))
        rc = 1
    else:
        with io.open(chosen, "r", encoding="utf-8") as f:
            text = f.read()
        with io.open(p, "w", encoding="utf-8") as f:
            f.write(text)
        print("   %-20s restored from %s" % (os.path.basename(rel), os.path.basename(chosen)))
sys.exit(rc)
PYEOF
  [ $? = 0 ] || die "rollback could not find a clean backup for both files - nothing rebuilt"
  MODE=go
  SKIP_PATCH=1
  ROLLED_BACK=1
else
  SKIP_PATCH=0
  ROLLED_BACK=0
fi

# ============================================================== patch
if [ "$SKIP_PATCH" = "0" ]; then
  say ""
  if [ "$MODE" = "plan" ]; then
    say "[2/9] patch: PLAN - splicing into a scratch copy, writing nothing"
    WORKDIR=/tmp/tsp_pinksky_plan_$STAMP
    d sh -c "rm -rf $WORKDIR && mkdir -p $WORKDIR/$(dirname $SKY) $WORKDIR/$(dirname $IMG) && cp $SRC/$SKY $WORKDIR/$SKY && cp $SRC/$IMG $WORKDIR/$IMG"
    TARGET="$WORKDIR"
    BSTAMP="none"
  else
    say "[2/9] patch: splicing in place; only a file that actually changes gets backed up"
    TARGET="$SRC"
    BSTAMP="$STAMP"
  fi

  di python3 - "$TARGET" "$SKY" "$IMG" "$BSTAMP" <<'PYEOF'
import sys, io, os

target, sky_rel, img_rel, bstamp = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
sky_p = os.path.join(target, sky_rel)
img_p = os.path.join(target, img_rel)

def read(p):
    with io.open(p, "r", encoding="utf-8") as f:
        return f.read()

def braces(s):
    return s.count("{") - s.count("}")

fail = []
plans = []

# ---------------------------------------------------------------- sky.cpp
sky = read(sky_p)
sky_before_braces = braces(sky)

SKY_OLD = """        if (mClouds != weather.mCloudTexture)
        {
            mClouds = weather.mCloudTexture;

            const VFS::Path::Normalized texture
                = Misc::ResourceHelpers::correctTexturePath(VFS::Path::toNormalized(mClouds), *mSceneManager->getVFS());

            osg::ref_ptr<osg::Texture2D> cloudTex
                = new osg::Texture2D(mSceneManager->getImageManager()->getImage(texture));
            cloudTex->setWrap(osg::Texture::WRAP_S, osg::Texture::REPEAT);
            cloudTex->setWrap(osg::Texture::WRAP_T, osg::Texture::REPEAT);

            mCloudUpdater->setTexture(std::move(cloudTex));
        }
"""

SKY_NEW = """        if (mClouds != weather.mCloudTexture)
        {
            // TSP_EMPTY_CLOUDTEX_V1 - the mNextClouds branch below guards on empty();
            // this one did not. An empty name becomes "textures/", which cannot load,
            // and every failure branch in ImageManager::getImage binds the magenta
            // warning image to that key for the life of the process. Unreachable from
            // a cold boot (mClouds starts empty too, so the comparison is false) and
            // reachable the moment an earlier load left a real name in mClouds.
            const std::string tspPrevClouds = mClouds;
            mClouds = weather.mCloudTexture;

            if (mClouds.empty())
            {
                Log(Debug::Warning) << "TSP_EMPTY_CLOUDTEX_V1 empty cloud texture name, prev=\\""
                                    << tspPrevClouds << "\\" - not requesting it, cloud layer left as is";
            }
            else
            {
                const VFS::Path::Normalized texture
                    = Misc::ResourceHelpers::correctTexturePath(VFS::Path::toNormalized(mClouds), *mSceneManager->getVFS());

                osg::ref_ptr<osg::Texture2D> cloudTex
                    = new osg::Texture2D(mSceneManager->getImageManager()->getImage(texture));
                cloudTex->setWrap(osg::Texture::WRAP_S, osg::Texture::REPEAT);
                cloudTex->setWrap(osg::Texture::WRAP_T, osg::Texture::REPEAT);

                mCloudUpdater->setTexture(std::move(cloudTex));
            }
        }
"""

if "TSP_EMPTY_CLOUDTEX_V1" in sky:
    plans.append(("sky.cpp", "ALREADY PATCHED - left alone", sky))
else:
    n = sky.count(SKY_OLD)
    if n != 1:
        fail.append("sky.cpp: mClouds anchor matched %d times, expected exactly 1" % n)
    else:
        new = sky.replace(SKY_OLD, SKY_NEW)
        # debuglog include, only if it is not already there
        if "debug/debuglog.hpp" not in new:
            inc = "#include <components/debug/debuglog.hpp>\n"
            lines = new.split("\n")
            last = -1
            for i, ln in enumerate(lines):
                if ln.startswith("#include <components/"):
                    last = i
            if last < 0:
                fail.append("sky.cpp: no #include <components/...> line to anchor the debuglog include on")
            else:
                lines.insert(last + 1, inc.rstrip("\n"))
                new = "\n".join(lines)
        if braces(new) != sky_before_braces:
            fail.append("sky.cpp: brace balance changed %d -> %d" % (sky_before_braces, braces(new)))
        elif new.count("TSP_EMPTY_CLOUDTEX_V1") != 2:
            fail.append("sky.cpp: expected 2 marker occurrences, got %d" % new.count("TSP_EMPTY_CLOUDTEX_V1"))
        elif "if (!mNextClouds.empty())" not in new:
            fail.append("sky.cpp: the mNextClouds guard disappeared - refusing")
        else:
            plans.append(("sky.cpp", "patched", new))

# -------------------------------------------------------- imagemanager.cpp
img = read(img_p)
img_before_braces = braces(img)

IMG_OLD = """        osg::ref_ptr<osg::Object> obj = mCache->getRefFromObjectCache(path);
        if (obj)
            return osg::ref_ptr<osg::Image>(static_cast<osg::Image*>(obj.get()));
        else
"""

IMG_NEW = """        // TSP_WARNCACHE_V1 (B1) - a path with no filename part can never resolve.
        // Return the warning image but do NOT cache it, so one bad frame cannot bind
        // a real path to magenta for the rest of the process.
        {
            const std::string_view tspVal = path.value();
            if (tspVal.empty() || tspVal.back() == '/')
            {
                static int tspDegenSeen = 0;
                if (tspDegenSeen < 8)
                {
                    ++tspDegenSeen;
                    Log(Debug::Warning) << "TSP_WARNCACHE_V1 degenerate image path \\"" << tspVal
                                        << "\\" - returning warning image WITHOUT caching it";
                }
                return mWarningImage;
            }
        }

        osg::ref_ptr<osg::Object> obj = mCache->getRefFromObjectCache(path);
        if (obj)
        {
            // TSP_WARNCACHE_V1 (B2) - a cached warning image is otherwise completely
            // silent: getImage logs once when the load fails and never again, and with
            // TSP_NO_LOADPURGE=1 the entry survives every save load. This is the only
            // way to see a texture that is still being served magenta.
            osg::Image* tspCached = static_cast<osg::Image*>(obj.get());
            if (tspCached == mWarningImage.get())
            {
                static int tspWarnHits = 0;
                if (tspWarnHits < 16)
                {
                    ++tspWarnHits;
                    Log(Debug::Warning) << "TSP_WARNCACHE_V1 serving CACHED warning image for " << path;
                }
            }
            return osg::ref_ptr<osg::Image>(tspCached);
        }
        else
"""

if "TSP_WARNCACHE_V1" in img:
    plans.append(("imagemanager.cpp", "ALREADY PATCHED - left alone", img))
else:
    n = img.count(IMG_OLD)
    if n != 1:
        fail.append("imagemanager.cpp: cache-lookup anchor matched %d times, expected exactly 1" % n)
    else:
        new = img.replace(IMG_OLD, IMG_NEW)
        if braces(new) != img_before_braces:
            fail.append("imagemanager.cpp: brace balance changed %d -> %d" % (img_before_braces, braces(new)))
        elif new.count("TSP_WARNCACHE_V1") != 4:
            fail.append("imagemanager.cpp: expected 4 marker occurrences, got %d" % new.count("TSP_WARNCACHE_V1"))
        elif new.count('"TSP_WARNCACHE_V1') != 2:
            fail.append("imagemanager.cpp: expected 2 marker STRING LITERALS (the binary gate greps those), got %d"
                        % new.count('"TSP_WARNCACHE_V1'))
        elif "debug/debuglog.hpp" not in new:
            fail.append("imagemanager.cpp: no debuglog include - refusing to add Log() calls")
        else:
            plans.append(("imagemanager.cpp", "patched", new))

# ------------------------------------------------- all or nothing, then write
if fail:
    print("ANCHOR FAILURE - NOTHING WRITTEN")
    for f in fail:
        print("   " + f)
    # Agreement 5: a miss must ship its own survey, or diagnosing it costs another
    # round trip. Print every line near where the anchor should have been.
    print("")
    print("   SURVEY - what the files actually contain around the anchors:")
    for label, path, pats in (
        ("sky.cpp", sky_p, ("mClouds", "mNextClouds", "mCloudUpdater", "correctTexturePath", "TSP_")),
        ("imagemanager.cpp", img_p, ("getRefFromObjectCache", "addEntryToObjectCache", "mWarningImage", "getImage", "TSP_")),
    ):
        print("   --- %s" % label)
        try:
            for i, ln in enumerate(read(path).split("\n"), 1):
                for p in pats:
                    if p in ln:
                        print("     %6d  %s" % (i, ln.rstrip()[:132]))
                        break
        except Exception as e:
            print("     could not read: %s" % e)
    sys.exit(3)

wrote = 0
for (name, what, text) in plans:
    print("   %-20s %s" % (name, what))
for (name, what, text), p in zip(plans, [sky_p, img_p]):
    if what != "patched":
        continue
    # Back up ONLY a file this run actually changes. Backing up on every run means
    # the second run backs up its own output and rollback becomes a silent no-op.
    if bstamp != "none":
        with io.open(p, "r", encoding="utf-8") as f:
            original = f.read()
        bpath = p + ".before-pinksky-" + bstamp
        with io.open(bpath, "w", encoding="utf-8") as f:
            f.write(original)
        print("   %-20s backed up -> %s" % ("", os.path.basename(bpath)))
    with io.open(p, "w", encoding="utf-8") as f:
        f.write(text)
    wrote += 1
print("   files written: %d" % wrote)
sys.exit(0)
PYEOF
  PRC=$?
  [ "$PRC" = "0" ] || die "the patcher refused (exit $PRC) - nothing was written"

  say ""
  say "[3/9] diff"
  if [ "$MODE" = "plan" ]; then
    d sh -c "for f in $SKY $IMG; do echo \"----- \$f\"; diff -u $SRC/\$f $WORKDIR/\$f; done" || true
  else
    d sh -c "cd $SRC && for f in $SKY $IMG; do b=\$(ls -t \$f.before-pinksky-* 2>/dev/null | head -1); if [ -n \"\$b\" ]; then echo \"----- \$f\"; diff -u \"\$b\" \"\$f\"; fi; done" || true
  fi

  if [ "$MODE" = "plan" ]; then
    say ""
    say "[4/9] PLAN ONLY - the real tree was not touched."
    say "      run it for real with:  bash ~/Downloads/tsp_pinksky_fix.sh go"
    exit 0
  fi
fi

# ============================================================== verify source
say ""
say "[4/9] source-side gate"
if [ "$ROLLED_BACK" = "1" ]; then
  for M in "$M1" "$M2"; do
    if d sh -c "grep -rq '$M' $SRC/$SKY $SRC/$IMG" >/dev/null 2>&1; then
      die "rollback left marker $M in the source - refusing to build"
    fi
  done
  say "      VERIFIED (rollback): both markers gone from the source"
else
  for M in "$M1" "$M2"; do
    d sh -c "grep -rq '$M' $SRC/$SKY $SRC/$IMG" >/dev/null 2>&1 || die "marker $M not in the source after patching"
  done
  say "      VERIFIED: both markers present"
fi
d sh -c "grep -q 'if (!mNextClouds.empty())' $SRC/$SKY" >/dev/null 2>&1 || die "the pre-existing mNextClouds guard is gone - refusing to build"
say "      VERIFIED: the pre-existing mNextClouds guard survived"
say "      source md5 after:"
d sh -c "cd $SRC && md5sum $SKY $IMG" | sed 's/^/        /'

# ============================================================== commit
say ""
say "[5/9] commit before building (agreement 20; never git add -A, two chats share this tree)"
d sh -c "cd $SRC && git add $SKY $IMG && (git diff --cached --quiet && echo 'nothing to commit' || git commit -q -m 'TSP_EMPTY_CLOUDTEX_V1 + TSP_WARNCACHE_V1: guard the empty cloud texture name; stop poisoning the image cache') && git log --oneline -1" 2>&1 | sed 's/^/        /'

# ============================================================== build
say ""
say "[6/9] incremental build - FULL output, nothing truncated"
say "-------------------------------------------------------------------------"
docker exec "$CTR" cmake --build "$BLD" --target openmw -- -j2 </dev/null
BRC=$?
say "-------------------------------------------------------------------------"
[ "$BRC" = "0" ] || die "build failed (exit $BRC) - the source is patched and committed, nothing was deployed"

# ============================================================== binary gate
say ""
say "[7/9] binary gate"
rm -f /tmp/openmw-staged
docker cp "$CTR:$BLD/openmw" /tmp/openmw-staged >/dev/null 2>&1 || die "could not copy the built binary out"
for M in "$M1" "$M2"; do
  if [ "$ROLLED_BACK" = "1" ]; then
    if grep -a -q "$M" /tmp/openmw-staged; then die "GATE FAIL: rollback build still contains '$M' - nothing deployed"; fi
    say "      VERIFIED (rollback): '$M' is gone from the built binary"
  else
    grep -a -q "$M" /tmp/openmw-staged || die "GATE FAIL: '$M' is not in the freshly built binary - nothing deployed"
    say "      VERIFIED: '$M' present in the built binary"
  fi
done
say "      staged md5: $(md5sum /tmp/openmw-staged | cut -d' ' -f1)"

if [ "$DEV_OK" = "0" ]; then
  say ""
  say "[8/9] device not reachable - build is staged at /tmp/openmw-staged, NOT deployed"
  say "      re-run this script when the device is up"
  exit 0
fi

# ================================================== marker regression check
say ""
say "[8/9] marker regression check against the live device binary"
# TSP_MARKERCMP_V2. V1 sorted the staged list with GNU sort here and the device
# list with busybox sort on the device, then handed both to comm. Two collations,
# and comm printed "input is not in sorted order" plus a garbage answer that read
# as 15 lost markers on a two-file patch. Sort BOTH locally under LC_ALL=C, and
# refuse to believe comm if it complains about its own input.
# grep -v '^$' matters: a blank line is not a marker, but it makes the list
# non-empty and the -s guard below pass on nothing.
grep -a -o 'TSP_[A-Za-z0-9_]*' /tmp/openmw-staged | grep -v '^$' | LC_ALL=C sort -u > /tmp/tsp_markers_staged.txt
r "grep -a -o 'TSP_[A-Za-z0-9_]*' $BIN" 2>/dev/null | tr -d '\r' | grep -v '^$' | LC_ALL=C sort -u > /tmp/tsp_markers_device.txt
# an empty device list would make the comparison pass on nothing - a gate that cannot fail
[ -s /tmp/tsp_markers_staged.txt ] || die "no TSP markers in the staged binary - refusing"
[ -s /tmp/tsp_markers_device.txt ] || die "could not read markers off the device binary - refusing to guess"
LC_ALL=C sort -c /tmp/tsp_markers_staged.txt 2>/dev/null || die "staged marker list is not sorted - refusing"
LC_ALL=C sort -c /tmp/tsp_markers_device.txt 2>/dev/null || die "device marker list is not sorted - refusing"
if [ "$ROLLED_BACK" = "1" ]; then
  # a rollback deliberately removes our own two markers; everything else must survive
  grep -v -x -e "$M1" -e "$M2" /tmp/tsp_markers_device.txt > /tmp/tsp_markers_device_cmp.txt
else
  cp /tmp/tsp_markers_device.txt /tmp/tsp_markers_device_cmp.txt
fi
LC_ALL=C sort -c /tmp/tsp_markers_device_cmp.txt 2>/dev/null || die "comparison list is not sorted - refusing"
CERR=$(LC_ALL=C comm -13 /tmp/tsp_markers_staged.txt /tmp/tsp_markers_device_cmp.txt 2>&1 >/tmp/tsp_lost.txt)
[ -z "$CERR" ] || die "comm complained about its own input ($CERR) - refusing to trust the result"
LOST=$(cat /tmp/tsp_lost.txt)
say "      staged markers: $(wc -l < /tmp/tsp_markers_staged.txt | tr -d ' ')   device markers: $(wc -l < /tmp/tsp_markers_device.txt | tr -d ' ')"
if [ -n "$LOST" ]; then
  say "      markers on the DEVICE but not in this build:"
  echo "$LOST" | sed 's/^/        /'
  die "another chat's engine work would be lost - refusing to deploy (CURRENT-STATE rule 3)"
fi
say "      VERIFIED: no marker on the device is missing from this build"
NEWM=$(LC_ALL=C comm -23 /tmp/tsp_markers_staged.txt /tmp/tsp_markers_device.txt 2>/dev/null)
if [ -n "$NEWM" ]; then say "      new in this build:"; echo "$NEWM" | sed 's/^/        /'; fi

# ============================================================== deploy
say ""
say "[9/9] deploy"
rin "cat > $BIN.new" < /tmp/openmw-staged || die "transfer failed"
rin 'sh -s' <<REMOTE
set -e
B=$BIN
cp "\$B" "\$B.before-pinksky-$STAMP"
mv "\$B.new" "\$B"
chmod +x "\$B"
echo "        deployed, backup \$B.before-pinksky-$STAMP"
for M in $M1 $M2; do
  if grep -a -q "\$M" "\$B"; then FOUND=1; else FOUND=0; fi
  if [ "$ROLLED_BACK" = "1" ]; then
    if [ "\$FOUND" = "0" ]; then echo "        DEVICE VERIFIED (rollback): \$M gone"; else echo "        DEVICE FAIL: \$M still present"; exit 1; fi
  else
    if [ "\$FOUND" = "1" ]; then echo "        DEVICE VERIFIED: \$M"; else echo "        DEVICE FAIL: \$M missing"; exit 1; fi
  fi
done
REMOTE
DRC=$?
[ "$DRC" = "0" ] || die "device-side verification failed"

say ""
say "===== DONE ====="
say "Launch  Morrowind  from PORTS. Reproduce it: load any save, then the storm save,"
say "look at the sky in Ald-ruhn. Quit, then pull the log with:"
say ""
say "    bash ~/Downloads/tsp_pinksky_fix.sh log"
say ""
say "Roll the whole thing back with:"
say "    bash ~/Downloads/tsp_pinksky_fix.sh rollback"
