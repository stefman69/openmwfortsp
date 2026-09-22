#!/bin/sh
# tsp_texfix.sh - the NIF texture resolution path, untruncated.
#
#   dump   read-only, no game run, no rebuild. ONE file.
#
# WHY
#
# imagemanager.cpp:148-171. checkSupported() returns false only for an S3TC
# image on a GPU without S3TC - which is every DDS on this build. The fallback,
# active because OPENMW_DECOMPRESS_TEXTURES=1 is in the environ:
#
#     newImage->allocateImage(..., GL_RGBA or GL_RGB, GL_UNSIGNED_BYTE);
#     for (s) for (t) for (r)
#         newImage->setColor(image->getColor(s, t, r), s, t, r);
#
# A per-texel virtual getColor/setColor pair - 262144 of them for a 512x512 -
# producing full RGBA8888 with NO mip chain (allocateImage makes one level).
# 512x512 DXT1 is 128 kB; the same texture ends up 1 MB resident, 8x. That is
# the 328 MB heap and the reason each GL upload is heavy enough to show up as a
# draw-traversal spike.
#
# TSP_KTX exists to avoid all of it: gl4es hands non-DXTc compressed formats
# straight to GLES, so an ASTC .ktx uploads with no decompress and stays 2 bpp.
#
# But tspPreferKtx() is called from exactly ONE function, correctTexturePath,
# and its callers are tooltips, class/birth images, cloud textures, sky.cpp and
# util.cpp. GUI and sky. Nothing that textures world geometry - which is why the
# only ktx loads visible are the eight sky/star textures.
#
# (Correction to an earlier claim of mine: those eight are NOT the total number
# of ktx loads. imagemanager.cpp:214 is `if (tspKtxLogged < 8)` - the log is
# capped at eight by design. How many actually load is still unknown, which is
# why section 5 below exists.)
#
# THE ONE THING THIS NEEDS TO SETTLE
#
# Where do NIF texture paths get resolved, and does anything rewrite them to
# .ktx? The previous dump's caller list was cut off at exactly 50 lines by a
# head -50, so nifloader.cpp may or may not have been in the part that was lost.
# Everything here is untruncated or generously capped.

set -u
CONT="openmw_builder"
SRC="/root/openmw-0.51-tsp-src"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="$HOME/Downloads/tsp_texfix_$STAMP.txt"

say() { printf '  %s\n' "$*"; }
hr()  { printf '\n########## %s ##########\n' "$1"; }
d()   { docker exec "$CONT" sh -c "$1" 2>&1; }
sec() { printf '\n\n==============================================================\n== %s\n==============================================================\n' "$1" >>"$OUT"
        printf '  .. %s\n' "$1"; }

docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$CONT" \
    || { printf '\n  STOPPING: container %s is not running\n\n' "$CONT"; exit 1; }

mkdir -p "$HOME/Downloads"
: >"$OUT"
printf '# tsp_texfix - %s\n' "$STAMP" >>"$OUT"
hr "DUMPING THE WORLD-TEXTURE RESOLUTION PATH"

sec "1. EVERY caller of correctTexturePath, NOT truncated"
d "cd $SRC && grep -rn 'correctTexturePath' apps components 2>/dev/null \
   | grep -v -e '\.before-' -e '\.preoverlay' -e '\.abandoned-' -e '\.tspterrain'" >>"$OUT"
printf '\n-- and the count, so a truncation can never hide one again --\n' >>"$OUT"
d "cd $SRC && grep -rn 'correctTexturePath' apps components 2>/dev/null \
   | grep -v -e '\.before-' -e '\.preoverlay' -e '\.abandoned-' | wc -l" >>"$OUT"

sec "2. THE DECIDER - how a NIF texture filename becomes a VFS path"
d "cd $SRC && grep -rn -e 'correctTexturePath' -e 'changeExtensionToDds' -e 'mFilename' \
   -e 'NiSourceTexture' -e 'handleTextureSet' -e 'textures/' -e 'BSShaderTextureSet' \
   components/nifosg/nifloader.cpp 2>/dev/null" >>"$OUT"
printf '\n----- nifloader.cpp: the texture handling bodies -----\n' >>"$OUT"
d "cd $SRC && awk '/handleTextureSet|handleTextureControllers|attachTexture|NiSourceTexture/,/^        }\$/' \
   components/nifosg/nifloader.cpp 2>/dev/null | head -220" >>"$OUT"

sec "3. anything anywhere that builds a texture path"
d "cd $SRC && grep -rn -e 'textures/' -e '\"textures\"' components/nifosg components/resource \
   components/misc components/vfs apps/openmw/mwrender 2>/dev/null \
   | grep -v -e '\.before-' -e '\.preoverlay' -e '\.abandoned-' | head -70" >>"$OUT"

sec "4. the DDS decompress fallback and what decides it"
d "cd $SRC && grep -n -e 'checkSupported' -e 'isS3TC' -e 'DECOMPRESS' -e 'allocateImage' \
   -e 'setColor' -e 'getNumMipmapLevels' -e 'mOptions' \
   components/resource/imagemanager.cpp 2>/dev/null" >>"$OUT"
printf '\n----- scenemanager.cpp: texture filtering, mipmaps and what it does with an Image -----\n' >>"$OUT"
d "cd $SRC && grep -n -e 'setFilterSettings' -e 'MIPMAP' -e 'mipmap' -e 'getImage' \
   -e 'setUnRefImageDataAfterApply' -e 'Texture2D' \
   components/resource/scenemanager.cpp 2>/dev/null | head -50" >>"$OUT"

sec "5. the log cap that made me miscount, and where a real counter would go"
d "cd $SRC && sed -n '205,230p' components/resource/imagemanager.cpp | cat -n" >>"$OUT"

sec "6. is the ktx osgDB plugin actually registered for this build"
d "cd $SRC && grep -rn -e 'osgdb_ktx' -e 'USE_OSGPLUGIN' CMakeLists.txt \
   components/resource/imagemanager.cpp 2>/dev/null" >>"$OUT"
d "ls -l /usr/local/lib/osgPlugins-* 2>/dev/null | grep -i -e ktx -e dds" >>"$OUT"

hr "SUMMARY"
say "saved to $OUT  ($(wc -l < "$OUT") lines)"
say ""
say "Section 2 decides the patch. If NIF textures resolve without ever calling"
say "correctTexturePath, then tspPreferKtx is wired to the GUI and sky path only"
say "and every world texture is taking the per-pixel software decompress to"
say "RGBA8888 with no mips. The fix is then one call in one place, plus a real"
say "load counter so it can be proven rather than assumed."
printf '\n'
