#!/bin/bash
# tsp_blanktex.sh - TSP_BLANKTEX_V1
#
# The global fix for empty texture names.
#
# A source census (tsp_texcensus.sh) found ~20 genuine sites that can hand the
# texture pipeline a name from a variable rather than a literal - overwhelmingly
# ESM record fields (rec.mIcon in ten mwlua/types files, effect->mIcon in the GUI,
# sign->mTexture, w.mCloudTexture) plus three built from the Water_SurfaceTexture
# fallback. Guarding 20 call sites is 20 chances to miss one, and every new call
# site reintroduces the bug. They all funnel through correctIconPath /
# correctTexturePath / correctBookartPath into ImageManager::getImage, so the fix
# goes at that choke point.
#
# TSP_WARNCACHE_V1 (B1) already returns early for a degenerate name - empty, or a
# bare directory - without caching it. This changes WHAT it returns: a 1x1 fully
# transparent image instead of the magenta warning image. An empty name means
# "no texture specified", and drawing nothing beats drawing magenta.
#
# A real filename that fails to load is UNCHANGED and still goes magenta. That is
# a genuine asset error and must stay visible.
#
# One TU, no header touched. Modes: go (default) | plan | log | rollback

set -u

TSP=root@192.168.1.12
SSH_OPTS="-o BatchMode=yes -o ConnectTimeout=8 -o ServerAliveInterval=15"
G=/mnt/SDCARD/data/ports/openmw
BIN="$G/bin/openmw-0.51"
CTR=openmw_builder
SRC=/root/openmw-0.51-tsp-src
BLD=/root/openmw-0.51-tsp-build
IMG=components/resource/imagemanager.cpp
M1=TSP_BLANKTEX_V1
MODE="${1:-go}"
STAMP=$(date +%Y%m%d-%H%M%S)

r()   { ssh -n $SSH_OPTS "$TSP" "$@"; }
rin() { ssh    $SSH_OPTS "$TSP" "$@"; }
d()   { docker exec "$CTR" "$@" </dev/null; }
di()  { docker exec -i "$CTR" "$@"; }

say() { echo "$*"; }
die() { echo ""; echo "STOPPED: $*"; exit 1; }

say "TSP_BLANKTEX_V1 mode=$MODE stamp=$STAMP"

# ================================================================ log
if [ "$MODE" = "log" ]; then
  rin 'sh -s' <<'REMOTE'
G=/mnt/SDCARD/data/ports/openmw
L="$G/config/openmw.log"
if [ -f "$L" ]; then
  ls -l "$L"; echo ""
  echo "--- degenerate names caught (each one is a surface that WOULD have gone magenta)"
  grep -n 'TSP_BLANKTEX_V1\|TSP_WARNCACHE_V1' "$L" | head -25
  echo "    blanktex/warncache lines: $(grep -c 'TSP_BLANKTEX_V1\|TSP_WARNCACHE_V1' "$L" ; true)"
  echo "--- the sky guard, should still be zero"
  echo "    count: $(grep -c TSP_EMPTY_CLOUDTEX_V1 "$L" ; true)"
  echo "--- REAL asset failures, which correctly still go magenta"
  grep -nE 'Failed to open image|Error loading' "$L" | head -15
  echo "    count: $(grep -cE 'Failed to open image|Error loading' "$L" ; true)"
else
  echo "NO LOG at $L"
fi
REMOTE
  exit 0
fi

# ================================================================ preflight
say ""
say "[1/8] preflight"
d test -d "$SRC" >/dev/null 2>&1 || die "container $CTR not up, or $SRC missing"
d test -f "$BLD/build.ninja" >/dev/null 2>&1 || die "$BLD is not a ninja tree - refusing (agreement 22-A)"
d sh -c "grep -q 'TSP_WARNCACHE_V1' $SRC/$IMG" >/dev/null 2>&1 \
  || die "TSP_WARNCACHE_V1 is not in $IMG - run tsp_pinksky_fix.sh first, this patch builds on it"
say "      container up, ninja tree present, TSP_WARNCACHE_V1 present"
d sh -c "cd $SRC && md5sum $IMG" | sed 's/^/        /'
DEV_OK=0
if r 'echo tsp_ok' 2>/dev/null | grep -q tsp_ok; then DEV_OK=1; say "      device reachable"; else say "      device NOT reachable - will build but not deploy"; fi

# ================================================================ rollback
if [ "$MODE" = "rollback" ]; then
  say ""
  say "[2/8] rollback"
  di python3 - "$SRC/$IMG" "$M1" <<'PYEOF'
import sys, os, io, glob
p, marker = sys.argv[1], sys.argv[2]
cands = sorted(glob.glob(p + ".before-blanktex-*"), key=os.path.getmtime, reverse=True)
for c in cands:
    if marker not in io.open(c, encoding="utf-8").read():
        io.open(p, "w", encoding="utf-8").write(io.open(c, encoding="utf-8").read())
        print("   restored from %s" % os.path.basename(c)); sys.exit(0)
print("   NO CLEAN BACKUP (%d candidates, all already patched)" % len(cands)); sys.exit(1)
PYEOF
  [ $? = 0 ] || die "nothing restored"
  ROLLED_BACK=1
  SKIP_PATCH=1
else
  ROLLED_BACK=0
  SKIP_PATCH=0
fi

# ================================================================ patch
if [ "$SKIP_PATCH" = "0" ]; then
  say ""
  if [ "$MODE" = "plan" ]; then
    say "[2/8] patch: PLAN, into a scratch copy"
    W=/tmp/tsp_blanktex_plan_$STAMP
    d sh -c "rm -rf $W && mkdir -p $W && cp $SRC/$IMG $W/img.cpp"
    TARGET="$W/img.cpp"; BSTAMP=none
  else
    say "[2/8] patch"
    TARGET="$SRC/$IMG"; BSTAMP="$STAMP"
  fi
  di python3 - "$TARGET" "$BSTAMP" <<'PYEOF'
import sys, io

path, bstamp = sys.argv[1], sys.argv[2]
t = io.open(path, "r", encoding="utf-8").read()

if "TSP_BLANKTEX_V1" in t:
    print("   ALREADY PATCHED - nothing written"); sys.exit(0)

DEF_ANCHOR = "    osg::ref_ptr<osg::Image> ImageManager::getImage(VFS::Path::NormalizedView path, bool disableFlip)\n"
OLD_RET = ('                                        << "\\" - returning warning image WITHOUT caching it";\n'
           '                }\n'
           '                return mWarningImage;\n')
NEW_RET = ('                                        << "\\" - TSP_BLANKTEX_V1 returning a blank 1x1, not caching it";\n'
           '                }\n'
           '                return tspBlankImage();\n')
HELPER = '''    // TSP_BLANKTEX_V1 - a degenerate name means "no texture specified", not "broken
    // texture". Drawing nothing beats drawing magenta: a blank icon slot, a cloudless
    // sky. A real filename that fails to load still gets mWarningImage, because that
    // is a genuine asset error and must stay visible.
    static osg::Image* tspBlankImage()
    {
        static const osg::ref_ptr<osg::Image> img = [] {
            osg::ref_ptr<osg::Image> i = new osg::Image;
            i->allocateImage(1, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE);
            unsigned char* d = i->data();
            d[0] = 0; d[1] = 0; d[2] = 0; d[3] = 0;
            i->setInternalTextureFormat(GL_RGBA);
            return i;
        }();
        return img.get();
    }

'''

fail = []
for name, s in (("getImage definition", DEF_ANCHOR), ("B1 return", OLD_RET)):
    n = t.count(s)
    if n != 1:
        fail.append("%s anchor matched %d times, expected 1" % (name, n))

magenta_before = t.count("return mWarningImage;")
if magenta_before < 2:
    fail.append("expected at least 2 'return mWarningImage;' (B1 plus the real-failure branches), found %d" % magenta_before)

if fail:
    print("ANCHOR FAILURE - NOTHING WRITTEN")
    for f in fail:
        print("   " + f)
    print("")
    print("   SURVEY:")
    for i, ln in enumerate(t.split("\n"), 1):
        if "mWarningImage" in ln or "TSP_WARNCACHE" in ln or "ImageManager::getImage" in ln:
            print("     %6d  %s" % (i, ln.rstrip()[:130]))
    sys.exit(3)

out = t.replace(DEF_ANCHOR, HELPER + DEF_ANCHOR).replace(OLD_RET, NEW_RET)

checks = []
if out.count("{") - out.count("}") != t.count("{") - t.count("}"):
    checks.append("brace balance changed")
if out.count("return mWarningImage;") != magenta_before - 1:
    checks.append("the real-failure magenta branches were disturbed (%d -> %d, expected %d)"
                  % (magenta_before, out.count("return mWarningImage;"), magenta_before - 1))
if out.count("static osg::Image* tspBlankImage()") != 1:
    checks.append("helper defined %d times" % out.count("static osg::Image* tspBlankImage()"))
if out.count("return tspBlankImage();") != 1:
    checks.append("helper called %d times" % out.count("return tspBlankImage();"))
if out.index("tspBlankImage") < out.rindex("#include"):
    checks.append("helper landed before the last #include")
if "namespace Resource" in out and out.index("static osg::Image* tspBlankImage") < out.index("namespace Resource"):
    checks.append("helper landed outside namespace Resource")
# The binary gate greps the compiled binary for the marker, so it must live inside a
# string literal. It sits mid-string, so assert the exact literal fragment instead.
if out.count("- TSP_BLANKTEX_V1 returning a blank 1x1") != 1:
    checks.append("the marker string literal the binary gate greps for is missing (%d)"
                  % out.count("- TSP_BLANKTEX_V1 returning a blank 1x1"))

if checks:
    print("POST-SPLICE CHECK FAILED - NOTHING WRITTEN")
    for c in checks:
        print("   " + c)
    sys.exit(4)

if bstamp != "none":
    io.open(path + ".before-blanktex-" + bstamp, "w", encoding="utf-8").write(t)
    print("   backed up -> %s" % (path.split("/")[-1] + ".before-blanktex-" + bstamp))
io.open(path, "w", encoding="utf-8").write(out)
print("   patched: helper inside namespace Resource, B1 now returns a blank 1x1")
print("   real-failure magenta branches left intact: %d" % out.count("return mWarningImage;"))
PYEOF
  PRC=$?
  [ "$PRC" = "0" ] || die "the patcher refused (exit $PRC) - nothing was written"

  say ""
  say "[3/8] diff"
  if [ "$MODE" = "plan" ]; then
    d sh -c "diff -u $SRC/$IMG $W/img.cpp" || true
    say ""
    say "PLAN ONLY - the real tree was not touched. Run it with: bash ~/Downloads/tsp_blanktex.sh go"
    exit 0
  fi
  d sh -c "cd $SRC && b=\$(ls -t $IMG.before-blanktex-* 2>/dev/null | head -1); if [ -n \"\$b\" ]; then diff -u \"\$b\" $IMG; fi" || true
fi

# ================================================================ gates
say ""
say "[4/8] source gate"
if [ "$ROLLED_BACK" = "1" ]; then
  if d sh -c "grep -q '$M1' $SRC/$IMG" >/dev/null 2>&1; then die "rollback left $M1 in the source"; fi
  say "      VERIFIED (rollback): $M1 gone"
else
  d sh -c "grep -q '$M1' $SRC/$IMG" >/dev/null 2>&1 || die "$M1 not in the source after patching"
  say "      VERIFIED: $M1 present"
fi
d sh -c "grep -q 'TSP_WARNCACHE_V1' $SRC/$IMG" >/dev/null 2>&1 || die "TSP_WARNCACHE_V1 disappeared - refusing"
say "      VERIFIED: TSP_WARNCACHE_V1 survived"

say ""
say "[5/8] commit (never git add -A, two chats share this tree)"
d sh -c "cd $SRC && git add $IMG && (git diff --cached --quiet && echo 'nothing to commit' || git commit -q -m 'TSP_BLANKTEX_V1: a degenerate texture name returns a blank 1x1, not magenta') && git log --oneline -1" 2>&1 | sed 's/^/        /'

say ""
say "[6/8] build - FULL output, nothing truncated"
say "-------------------------------------------------------------------------"
docker exec "$CTR" cmake --build "$BLD" --target openmw -- -j2 </dev/null
BRC=$?
say "-------------------------------------------------------------------------"
[ "$BRC" = "0" ] || die "build failed (exit $BRC) - source is patched and committed, nothing deployed"

say ""
say "[7/8] binary gate"
rm -f /tmp/openmw-staged
docker cp "$CTR:$BLD/openmw" /tmp/openmw-staged >/dev/null 2>&1 || die "could not copy the built binary out"
if [ "$ROLLED_BACK" = "1" ]; then
  if grep -a -q "$M1" /tmp/openmw-staged; then die "rollback build still contains $M1"; fi
  say "      VERIFIED (rollback): $M1 gone from the binary"
else
  grep -a -q "$M1" /tmp/openmw-staged || die "GATE FAIL: $M1 not in the built binary - nothing deployed"
  say "      VERIFIED: $M1 present in the built binary"
fi
say "      staged md5: $(md5sum /tmp/openmw-staged | cut -d' ' -f1)"
[ "$DEV_OK" = "1" ] || { say ""; say "[8/8] device unreachable - staged at /tmp/openmw-staged, NOT deployed"; exit 0; }

say ""
say "[8/8] marker regression, then deploy"
grep -a -o 'TSP_[A-Za-z0-9_]*' /tmp/openmw-staged | grep -v '^$' | LC_ALL=C sort -u > /tmp/tsp_ms.txt
r "grep -a -o 'TSP_[A-Za-z0-9_]*' $BIN" 2>/dev/null | tr -d '\r' | grep -v '^$' | LC_ALL=C sort -u > /tmp/tsp_md.txt
[ -s /tmp/tsp_ms.txt ] || die "no markers in the staged binary"
[ -s /tmp/tsp_md.txt ] || die "could not read markers off the device binary - refusing to guess"
if [ "$ROLLED_BACK" = "1" ]; then grep -v -x "$M1" /tmp/tsp_md.txt > /tmp/tsp_mdc.txt; else cp /tmp/tsp_md.txt /tmp/tsp_mdc.txt; fi
CERR=$(LC_ALL=C comm -13 /tmp/tsp_ms.txt /tmp/tsp_mdc.txt 2>&1 >/tmp/tsp_lost.txt)
[ -z "$CERR" ] || die "comm complained about its own input ($CERR) - refusing to trust it"
LOST=$(cat /tmp/tsp_lost.txt)
say "      staged $(wc -l < /tmp/tsp_ms.txt | tr -d ' ')   device $(wc -l < /tmp/tsp_md.txt | tr -d ' ')"
if [ -n "$LOST" ]; then
  echo "$LOST" | sed 's/^/        /'
  die "markers on the device are missing from this build - refusing to deploy"
fi
say "      VERIFIED: nothing on the device is missing from this build"
rin "cat > $BIN.new" < /tmp/openmw-staged || die "transfer failed"
rin 'sh -s' <<REMOTE
set -e
B=$BIN
cp "\$B" "\$B.before-blanktex-$STAMP"
mv "\$B.new" "\$B"
chmod +x "\$B"
echo "        deployed, backup \$B.before-blanktex-$STAMP"
if grep -a -q "$M1" "\$B"; then F=1; else F=0; fi
if [ "$ROLLED_BACK" = "1" ]; then
  if [ "\$F" = "0" ]; then echo "        DEVICE VERIFIED (rollback): $M1 gone"; else echo "        DEVICE FAIL"; exit 1; fi
else
  if [ "\$F" = "1" ]; then echo "        DEVICE VERIFIED: $M1"; else echo "        DEVICE FAIL"; exit 1; fi
fi
REMOTE
[ $? = 0 ] || die "device verification failed"

say ""
say "===== DONE ====="
say "Launch  Morrowind  from PORTS and play normally. Then:"
say ""
say "    bash ~/Downloads/tsp_blanktex.sh log"
say ""
say "Every TSP_BLANKTEX_V1 line names a surface that WOULD have gone magenta."
say "Real asset failures still show as magenta and still log - that is deliberate."
say "Undo with: bash ~/Downloads/tsp_blanktex.sh rollback"
