#!/usr/bin/env bash
# TSP_ASTCCHECK_V1 - does the GPU actually accept our ASTC, or is something decoding
# it in software at upload time? READ ONLY. No play session, nothing changed.
#
#   bash ~/Downloads/tsp_astccheck.sh
#
# Steve, 2026-09-10: "the draw distance is the one I least suspect because I walked
# around outside a lot with it. I did not really notice it until after we set up the
# texture down scaling."
#
# That observation points somewhere my A/B could not look. Texture UPLOAD happens at
# cell load, not during steady play, so a per-texture upload cost is concentrated in
# exactly the post-load window and is invisible in the steady-state frame time that
# TSP_KTX=0 vs 1 compared. If the Mali driver does not natively accept 8x8/6x6 ASTC
# LDR, gl4es or the driver decodes each one in software on upload.
#
# gl4es sets hardext.* from the real extension string; LIBGL_TSP_LOG=1 and TSP_EXTDUMP
# already exist in this build, so the answer should be in the logs.
#
# Rule Zero: file, not paste; r() uses -n, rin() takes the heredoc (NEVER -n).

set -u
TSP="${TSP:-root@192.168.1.12}"
SSH_OPTS="-o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=6"
DL="${DL:-$HOME/Downloads}"
REP="$DL/tsp-astccheck-$(date +%Y%m%d-%H%M%S).txt"

r()   { ssh -n $SSH_OPTS "$TSP" "$@"; }
rin() { ssh    $SSH_OPTS "$TSP" "$@"; }

r 'echo ok' >/dev/null 2>&1 || { echo "FAIL: cannot reach the TSP at $TSP" >&2; exit 1; }

rin 'sh -s' <<'REMOTE' 2>&1 | tee "$REP"
S=/mnt/SDCARD
G=$S/data/ports/openmw

# every log we might find the extension string in, newest first
LOGS=""
for c in "$G/openmw_log.txt" $(ls -t "$G"/openmw_log.txt.* 2>/dev/null | head -4) \
         "$S/tsp_prog.txt" "$G/config/openmw.log"; do
    [ -s "$c" ] && LOGS="$LOGS $c"
done
echo "logs searched:"; for l in $LOGS; do printf '  %s (%s bytes)\n' "$l" "$(wc -c < "$l")"; done
echo

echo "########## 1. DOES THE DRIVER ADVERTISE ASTC ##########"
for k in astc ASTC compressed_texture_astc KHR_texture_compression; do
    printf -- '-- %s --\n' "$k"
    for l in $LOGS; do grep -ai "$k" "$l" 2>/dev/null | head -6 | sed 's/^/    /'; done
done
echo "-- the raw extension string, if it was dumped --"
for l in $LOGS; do
    grep -ai 'GL_EXTENSIONS\|TSP_EXTDUMP\|GL_KHR\|GL_OES_\|extensions:' "$l" 2>/dev/null | head -8 | sed 's/^/    /'
done
echo "SECTION 1 DONE"
echo

echo "########## 2. WHAT gl4es DECIDED ##########"
for k in hardext prgbinary TSP_MAXCOLORATTACH 'LIBGL:' gl4es 'TSP_LATE'; do
    printf -- '-- %s --\n' "$k"
    for l in $LOGS; do grep -ai "$k" "$l" 2>/dev/null | head -5 | sed 's/^/    /'; done
done
echo "SECTION 2 DONE"
echo

echo "########## 3. IS THE KTX PATH BEING TAKEN, AND COMPLAINING ##########"
for k in ktx KTX 'TSP_KTX' 'unsupported' 'unable to load' 'Failed to load' 'not supported' 'fallback' 'decompress'; do
    printf -- '-- %s --\n' "$k"
    for l in $LOGS; do grep -ai "$k" "$l" 2>/dev/null | head -6 | sed 's/^/    /'; done
done
echo "SECTION 3 DONE"
echo

echo "########## 4. THE TEXTURE CACHES NOBODY HAS LOOKED AT ##########"
for d in "$G/texcache" "$G/shadercache"; do
    if [ -d "$d" ]; then
        printf -- '-- %s --\n' "$d"
        printf '   entries: %s\n' "$(ls -1 "$d" 2>/dev/null | wc -l)"
        printf '   newest:\n'; ls -lt "$d" 2>/dev/null | head -6 | sed 's/^/     /'
    else
        echo "-- $d : absent --"
    fi
done
echo "SECTION 4 DONE"
echo

echo "########## 5. THE UPLOAD THROTTLE ##########"
# TSP_ICO_MAXOBJ caps GL object creation per frame. If each ASTC upload is expensive,
# this is the knob that decides how much of that lands in one frame.
grep -n 'TSP_ICO' "$S/tsp_iotune.conf" 2>/dev/null | sed 's/^/  /'
for c in "$G/config/settings.cfg" "$G/config-0.51/settings.cfg"; do
    [ -f "$c" ] || continue
    printf -- '-- %s --\n' "$c"
    grep -n -i 'texture mipmap\|anisotropy\|texture mag\|texture min\|\[Cells\]\|preload\|\[Shaders\]' "$c" | head -20
done
echo "SECTION 5 DONE"
echo

echo "########## 6. WHAT A KTX FILE ACTUALLY SAYS ##########"
K="$(find "$G/data/Data Files/textures" -name '*.ktx' 2>/dev/null | head -1)"
if [ -n "$K" ]; then
    echo "sample: $K ($(wc -c < "$K") bytes)"
    echo "first 64 bytes, the KTX1 header (glInternalFormat is bytes 29-32, little endian):"
    od -A d -t x1 -N 64 "$K" | sed 's/^/  /'
    echo
    echo "0x93B7 = ASTC 8x8, 0x93B4 = ASTC 6x6, 0x93B0 = ASTC 4x4"
else
    echo "no ktx files found"
fi
echo "SECTION 6 DONE"
REMOTE

echo
echo "full report: $REP"
