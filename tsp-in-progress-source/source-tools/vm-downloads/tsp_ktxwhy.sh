#!/bin/sh
# tsp_ktxwhy.sh - why do only 8 of 4481 .ktx files ever load?
#
# Read-only. One dump, no device writes, no rebuild, no game run needed.
#
# THE OBSERVATION
#
# TSP_KTX=1 is confirmed working. The log proves ASTC reaches the GPU:
#     TSP_KTX_V1 loaded textures/tx_stars.ktx compressed=1 fmt=37815
#         512x512 levels=10 bytes=87424
# fmt 37815 = 0x93B7 = GL_COMPRESSED_RGBA_ASTC_8x8_KHR, with a full mip chain.
#
# But there are exactly EIGHT such lines in a 2-minute run, all sky textures,
# all inside 27 ms at startup. TSP_KTX_V1 logs at Debug::Warning so every load
# would appear. Eight out of 4481 converted files.
#
# That matters twice over:
#   - the 09-10 A/B measured +87 MB MemAvailable and -62 MB RSS from ASTC. None
#     of that is landing.
#   - this build has NO S3TC, so every DDS that loads instead is decompressed by
#     gl4es to full RGBA before upload. The measured hitches are draw-traversal
#     spikes (draw 8 ms -> 21-35 ms) and the ICO runs inside draw, compiling
#     exactly those uploads.
#
# THE LEADING HYPOTHESIS, which this dump confirms or kills
#
# The eight that DO load are all referenced by the engine as ".ktx" directly
# (sky/star textures). Every other texture in Morrowind is referenced as .tga
# or .dds by the ESM and the NIFs. If the resolver never REWRITES a requested
# .dds/.tga into .ktx, then only assets already named .ktx can ever hit the
# path - which would produce exactly this, eight of them.
#
# Upstream's own patch for this (bmdhacks, in RESEARCH-PATCH-astc-ktx-loader)
# adds sTextureExtensionPriority = { dds, ktx } and findBestTextureVariant to
# do that rewrite. Section 3 below shows whether any of that is in this tree.
#
# Section 5 checks the other candidate: the eMMC root is the LAST data= line so
# it wins in the VFS, but it holds 62.4 MB against 571.6 MB on the SD card. If
# the resolver only consults the winning root, only that subset can resolve.

set -u
DEV="root@192.168.1.12"
G="/mnt/SDCARD/data/ports/openmw"
CONT="openmw_builder"
SRC="/root/openmw-0.51-tsp-src"
SSHO="-o ConnectTimeout=8 -o StrictHostKeyChecking=no -o BatchMode=yes"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="$HOME/Downloads/tsp_ktxwhy_$STAMP.txt"

say() { printf '  %s\n' "$*"; }
hr()  { printf '\n########## %s ##########\n' "$1"; }
rin() { ssh $SSHO "$DEV" "sh -s" 2>&1; }
d()   { docker exec "$CONT" sh -c "$1" 2>&1; }
sec() { printf '\n\n==============================================================\n== %s\n==============================================================\n' "$1" >>"$OUT"
        printf '  .. %s\n' "$1"; }
abort() { printf '\n  STOPPING: %s\n\n' "$*"; exit 1; }

ssh $SSHO -n "$DEV" "echo ok" 2>&1 | grep -q ok \
    || abort "cannot reach $DEV - is the handheld awake and on wifi?"
docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$CONT" \
    || abort "container $CONT is not running - start it and re-run"

mkdir -p "$HOME/Downloads"
: >"$OUT"
printf '# tsp_ktxwhy - %s\n' "$STAMP" >>"$OUT"
hr "DUMPING THE TEXTURE RESOLUTION PATH"

sec "1. TSP_KTX_V1 - every occurrence in the tree, with context"
d "cd $SRC && grep -rn 'TSP_KTX' apps components files 2>/dev/null | grep -v '\.before-' | head -60" >>"$OUT"

sec "2. the TSP_KTX_V1 loader itself, in full"
d "cd $SRC && grep -rln 'TSP_KTX_V1' apps components 2>/dev/null | grep -v '\.before-' | head -4" >>"$OUT"
for f in components/resource/imagemanager.cpp components/misc/resourcehelpers.cpp; do
    printf '\n----- %s -----\n' "$f" >>"$OUT"
    d "cd $SRC && cat -n $f 2>/dev/null | head -260" >>"$OUT"
done

sec "3. THE DECIDER - is there any .dds/.tga -> .ktx REWRITE at all"
d "cd $SRC && grep -rn -e 'changeExtensionToDds' -e 'ExtensionPriority' -e 'findBestTexture' \
    -e 'correctTexturePath' -e 'correctResourcePath' -e \"ExtensionView\" \
    apps components 2>/dev/null | grep -v '\.before-' | head -50" >>"$OUT"
printf '\n----- resourcehelpers.hpp, in full: what the API offers -----\n' >>"$OUT"
d "cd $SRC && cat -n components/misc/resourcehelpers.hpp 2>/dev/null | head -90" >>"$OUT"
printf '\n----- every function body in resourcehelpers.cpp that touches an extension -----\n' >>"$OUT"
d "cd $SRC && awk '/^[A-Za-z].*Misc::ResourceHelpers::/,/^}/' components/misc/resourcehelpers.cpp 2>/dev/null | head -200" >>"$OUT"

sec "4. how a texture request becomes a file - the VFS lookup order"
d "cd $SRC && grep -rn -e 'ktx' -e 'astc' components/vfs/*.cpp components/vfs/*.hpp \
    components/resource/*.cpp 2>/dev/null | grep -v '\.before-' | head -40" >>"$OUT"
d "cd $SRC && grep -rn 'osgdb_ktx\|USE_OSGPLUGIN' CMakeLists.txt 2>/dev/null | head -10" >>"$OUT"

sec "5. DEVICE - how many .ktx are under each data= root, and are the names the same"
rin <<'KEOF' >>"$OUT"
G="/mnt/SDCARD/data/ports/openmw"
SD="$G/data/Data Files/textures"
EM="/mnt/UDISK/openmw-tex/textures"
echo "--- the data= roots, in the order the VFS applies them (LAST one wins)"
grep -n '^data=' "$G/openmw.cfg" 2>/dev/null
echo ""
for p in "$SD" "$EM"; do
    [ -d "$p" ] || { printf '%-46s MISSING\n' "$p"; continue; }
    printf '%-46s %6s ktx at depth 1, %6s total files, %s\n' "$p" \
      "$(find "$p/" -maxdepth 1 -iname '*.ktx' 2>/dev/null | wc -l)" \
      "$(find "$p/" -maxdepth 1 -type f 2>/dev/null | wc -l)" \
      "$(du -sh "$p/" 2>/dev/null | cut -f1)"
    printf '%-46s subdirs: %s\n' "" "$(find "$p/" -maxdepth 1 -type d 2>/dev/null | wc -l)"
done
echo ""
echo "--- the EIGHT that actually loaded - are they in BOTH roots or only one?"
for n in tx_stars.ktx tx_stars_mage.ktx tx_stars_nebula.ktx; do
    for p in "$SD/$n" "$EM/$n"; do
        [ -e "$p" ] && printf '    PRESENT %s\n' "$p" || printf '    absent  %s\n' "$p"
    done
done
echo ""
echo "--- a texture Balmora certainly needs: does a .ktx exist for it, and a .dds"
for base in tx_wood_rough tx_stucco_brown tx_rock_brown tx_ashl_wall; do
    printf '  %-22s' "$base"
    for p in "$SD" "$EM"; do
        printf ' %s:%s' "$(basename "$(dirname "$p")")" \
          "$(find "$p/" -maxdepth 1 -iname "$base*" 2>/dev/null | wc -l)"
    done
    printf '\n'
done
echo ""
echo "--- and are those names present INSIDE the BSAs as .dds (the fallback)"
grep -n '^fallback-archive=' "$G/openmw.cfg" 2>/dev/null
ls -l "$G/data/Data Files"/*.bsa 2>/dev/null | awk '{printf "    %10s  %s\n", $5, $NF}'
KEOF

sec "6. what the game logged about textures this run"
rin <<'LEOF' >>"$OUT"
L="/mnt/SDCARD/data/ports/openmw/openmw_log.txt"
echo "--- every TSP_KTX_V1 line, in full"
grep -h 'TSP_KTX_V1' "$L" 2>/dev/null
printf 'total TSP_KTX_V1 lines: %s\n' "$(grep -c 'TSP_KTX_V1' "$L" 2>/dev/null)"
echo "--- any texture error, fallback or format complaint"
grep -h -i -e 'cannot flip' -e 'no s3tc' -e 'error loading' -e 'failed to open' \
        -e 'unsupported' -e 'decompress' "$L" 2>/dev/null | sort | uniq -c | sort -rn | head -20
echo "--- the ICO budget line and the frame-cost lines, for the record"
grep -h -e 'TSP_ICO_BUDGET_V1' "$L" 2>/dev/null | tail -3
LEOF

hr "SUMMARY"
say "saved to $OUT  ($(wc -l < "$OUT") lines)"
say ""
say "Send me that file. Section 3 is the one that matters: if there is no"
say ".dds/.tga -> .ktx rewrite in this tree, then only assets already named"
say ".ktx can ever load, which is exactly the eight sky textures - and the"
say "fix is the resolver, not the converter, not the device, not the config."
printf '\n'
