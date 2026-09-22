// TSP_TEXCONV_V1 - on-device DDS/TGA -> ASTC KTX converter for the OpenMW TSP port.
//
// One process, no temp files, no subprocess spawns: reads textures straight out of the
// Morrowind BSAs (and loose directories), decodes DXT in-process, builds the mip pyramid,
// compresses each level with libastcenc, and writes a multi-level KTX1 container.
//
// Why in-process: the CLI route needs a PNG per mip level and an astcenc spawn per level,
// which for ~3600 textures is ~36000 process spawns and ~36000 temp-file writes onto an
// SD card. On four A53 cores that is the difference between half an hour and several hours.
//
// Format decisions, each verified against the engine before this was written:
//   * gl4es passes non-DXTc compressed formats straight to gles_glCompressedTexImage2D and
//     never sets mipmap_auto, so the container MUST carry its own full mip chain.
//   * The mip chain must be largest-first or OSG reads a 1x1 texture as level 0.
//   * KTX1 defaults to bottom-up. We keep DDS row order (top-down) and declare
//     KTXorientation=S=r,T=d, matching the ext=="ktx" TOP_LEFT branch in ImageManager.
//     Get this wrong and the non-S3TC flip guard paints the magenta warning texture.
//   * Per-level payload must equal ceil(w/bx)*ceil(h/by)*16, which is what
//     osg::Image::computeImageSizeInBytes derives independently.
//
// Build (aarch64, in openmw_builder):
//   cmake -S astc-encoder -B ac-build -DCMAKE_BUILD_TYPE=Release
//         -DASTCENC_ISA_NEON=ON -DASTCENC_CLI=OFF && cmake --build ac-build -j4
//   g++ -O2 -std=c++17 tsp_texconv.cpp -I astc-encoder/Source
//       ac-build/Source/libastcenc-neon-static.a -lpthread -o tsp_texconv

#include <astcenc.h>

#include <algorithm>
#include <atomic>
#include <cctype>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <map>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace fs = std::filesystem;

// ---------------------------------------------------------------- ASTC / KTX

static const char* kAstcBlocks[] = { "4x4", "5x4", "5x5", "6x5", "6x6", "8x5", "8x6", "8x8",
                                     "10x5", "10x6", "10x8", "10x10", "12x10", "12x12" };
static const int kAstcBlockCount = 14;

static bool blockToFormat(const std::string& block, unsigned& bx, unsigned& by, uint32_t& glFormat)
{
    for (int i = 0; i < kAstcBlockCount; ++i)
    {
        if (block == kAstcBlocks[i])
        {
            if (sscanf(kAstcBlocks[i], "%ux%u", &bx, &by) != 2)
                return false;
            glFormat = 0x93B0u + static_cast<uint32_t>(i);
            return true;
        }
    }
    return false;
}

static size_t astcPayloadBytes(unsigned w, unsigned h, unsigned bx, unsigned by)
{
    return static_cast<size_t>((w + bx - 1) / bx) * ((h + by - 1) / by) * 16u;
}

struct Image
{
    unsigned w = 0, h = 0;
    std::vector<uint8_t> rgba; // top-down, 4 bytes per texel
};

// ------------------------------------------------------------------ BC decode

static inline void rgb565(uint16_t c, uint8_t& r, uint8_t& g, uint8_t& b)
{
    const uint8_t r5 = static_cast<uint8_t>((c >> 11) & 0x1F);
    const uint8_t g6 = static_cast<uint8_t>((c >> 5) & 0x3F);
    const uint8_t b5 = static_cast<uint8_t>(c & 0x1F);
    r = static_cast<uint8_t>((r5 << 3) | (r5 >> 2));
    g = static_cast<uint8_t>((g6 << 2) | (g6 >> 4));
    b = static_cast<uint8_t>((b5 << 3) | (b5 >> 2));
}

// Fills 16 RGBA texels in row-major 4x4 order. dxt1Alpha selects the punch-through rule.
static void decodeBc1Colour(const uint8_t* src, uint8_t out[16][4], bool dxt1Alpha)
{
    const uint16_t c0 = static_cast<uint16_t>(src[0] | (src[1] << 8));
    const uint16_t c1 = static_cast<uint16_t>(src[2] | (src[3] << 8));
    uint8_t r[4], g[4], b[4], a[4];
    rgb565(c0, r[0], g[0], b[0]);
    rgb565(c1, r[1], g[1], b[1]);
    a[0] = a[1] = 255;
    if (c0 > c1)
    {
        r[2] = static_cast<uint8_t>((2 * r[0] + r[1]) / 3);
        g[2] = static_cast<uint8_t>((2 * g[0] + g[1]) / 3);
        b[2] = static_cast<uint8_t>((2 * b[0] + b[1]) / 3);
        r[3] = static_cast<uint8_t>((r[0] + 2 * r[1]) / 3);
        g[3] = static_cast<uint8_t>((g[0] + 2 * g[1]) / 3);
        b[3] = static_cast<uint8_t>((b[0] + 2 * b[1]) / 3);
        a[2] = a[3] = 255;
    }
    else
    {
        r[2] = static_cast<uint8_t>((r[0] + r[1]) / 2);
        g[2] = static_cast<uint8_t>((g[0] + g[1]) / 2);
        b[2] = static_cast<uint8_t>((b[0] + b[1]) / 2);
        a[2] = 255;
        r[3] = g[3] = b[3] = 0;
        a[3] = dxt1Alpha ? 0 : 255;
    }
    uint32_t bits = static_cast<uint32_t>(src[4]) | (static_cast<uint32_t>(src[5]) << 8)
        | (static_cast<uint32_t>(src[6]) << 16) | (static_cast<uint32_t>(src[7]) << 24);
    for (int i = 0; i < 16; ++i)
    {
        const int idx = static_cast<int>((bits >> (2 * i)) & 3u);
        out[i][0] = r[idx];
        out[i][1] = g[idx];
        out[i][2] = b[idx];
        out[i][3] = a[idx];
    }
}

static void decodeBc2Alpha(const uint8_t* src, uint8_t out[16][4])
{
    for (int i = 0; i < 16; ++i)
    {
        const uint8_t nib = (i & 1) ? static_cast<uint8_t>(src[i / 2] >> 4)
                                    : static_cast<uint8_t>(src[i / 2] & 0x0F);
        out[i][3] = static_cast<uint8_t>(nib * 17);
    }
}

static void decodeBc3Alpha(const uint8_t* src, uint8_t out[16][4])
{
    const uint8_t a0 = src[0], a1 = src[1];
    uint8_t lut[8];
    lut[0] = a0;
    lut[1] = a1;
    if (a0 > a1)
        for (int i = 1; i <= 6; ++i)
            lut[i + 1] = static_cast<uint8_t>(((6 - i) * a0 + i * a1) / 7);
    else
    {
        for (int i = 1; i <= 4; ++i)
            lut[i + 1] = static_cast<uint8_t>(((4 - i) * a0 + i * a1) / 5);
        lut[6] = 0;
        lut[7] = 255;
    }
    uint64_t bits = 0;
    for (int i = 0; i < 6; ++i)
        bits |= static_cast<uint64_t>(src[2 + i]) << (8 * i);
    for (int i = 0; i < 16; ++i)
        out[i][3] = lut[(bits >> (3 * i)) & 7u];
}

enum class BcKind
{
    Bc1,
    Bc2,
    Bc3
};

static bool decodeBc(const uint8_t* data, size_t len, unsigned w, unsigned h, BcKind kind,
    Image& img, std::string& err)
{
    const size_t blockBytes = (kind == BcKind::Bc1) ? 8u : 16u;
    const unsigned bw = (w + 3) / 4, bh = (h + 3) / 4;
    const size_t need = static_cast<size_t>(bw) * bh * blockBytes;
    if (len < need)
    {
        err = "truncated block data: " + std::to_string(len) + " < " + std::to_string(need);
        return false;
    }
    img.w = w;
    img.h = h;
    img.rgba.assign(static_cast<size_t>(w) * h * 4u, 0);
    for (unsigned by = 0; by < bh; ++by)
    {
        for (unsigned bx = 0; bx < bw; ++bx)
        {
            const uint8_t* blk = data + (static_cast<size_t>(by) * bw + bx) * blockBytes;
            uint8_t texels[16][4];
            if (kind == BcKind::Bc1)
                decodeBc1Colour(blk, texels, true);
            else
            {
                decodeBc1Colour(blk + 8, texels, false);
                if (kind == BcKind::Bc2)
                    decodeBc2Alpha(blk, texels);
                else
                    decodeBc3Alpha(blk, texels);
            }
            for (int t = 0; t < 16; ++t)
            {
                const unsigned x = bx * 4 + static_cast<unsigned>(t % 4);
                const unsigned y = by * 4 + static_cast<unsigned>(t / 4);
                if (x >= w || y >= h)
                    continue;
                uint8_t* dst = img.rgba.data() + (static_cast<size_t>(y) * w + x) * 4u;
                dst[0] = texels[t][0];
                dst[1] = texels[t][1];
                dst[2] = texels[t][2];
                dst[3] = texels[t][3];
            }
        }
    }
    return true;
}

// ----------------------------------------------------------------- DDS parsing

static inline uint32_t rd32(const uint8_t* p)
{
    return static_cast<uint32_t>(p[0]) | (static_cast<uint32_t>(p[1]) << 8)
        | (static_cast<uint32_t>(p[2]) << 16) | (static_cast<uint32_t>(p[3]) << 24);
}

// Generic mask extraction, so 32/24/16/8-bit DDS variants all work without special cases.
static void maskInfo(uint32_t mask, int& shift, int& bits)
{
    shift = 0;
    bits = 0;
    if (mask == 0)
        return;
    while (((mask >> shift) & 1u) == 0u)
        ++shift;
    uint32_t m = mask >> shift;
    while (m & 1u)
    {
        ++bits;
        m >>= 1;
    }
}

static inline uint8_t scaleTo8(uint32_t value, int bits)
{
    if (bits <= 0)
        return 255;
    if (bits == 8)
        return static_cast<uint8_t>(value);
    const uint32_t maxv = (1u << bits) - 1u;
    return static_cast<uint8_t>((value * 255u + maxv / 2u) / maxv);
}

static bool decodeDds(const uint8_t* data, size_t len, Image& img, std::string& err)
{
    if (len < 128 || rd32(data) != 0x20534444u)
    {
        err = "not a DDS";
        return false;
    }
    const uint8_t* hdr = data + 4;
    const uint32_t h = rd32(hdr + 8);
    const uint32_t w = rd32(hdr + 12);
    const uint8_t* pf = hdr + 72;
    const uint32_t pfFlags = rd32(pf + 4);
    const uint32_t fourCC = rd32(pf + 8);
    const uint32_t bitCount = rd32(pf + 12);
    const uint32_t rMask = rd32(pf + 16), gMask = rd32(pf + 20), bMask = rd32(pf + 24),
                   aMask = rd32(pf + 28);

    if (w == 0 || h == 0 || w > 16384 || h > 16384)
    {
        err = "implausible dimensions " + std::to_string(w) + "x" + std::to_string(h);
        return false;
    }

    const uint8_t* body = data + 128;
    const size_t bodyLen = len - 128;

    if (pfFlags & 0x4u) // DDPF_FOURCC
    {
        switch (fourCC)
        {
            case 0x31545844u: // DXT1
                return decodeBc(body, bodyLen, w, h, BcKind::Bc1, img, err);
            case 0x32545844u: // DXT2 (premultiplied BC2; treated as BC2)
            case 0x33545844u: // DXT3
                return decodeBc(body, bodyLen, w, h, BcKind::Bc2, img, err);
            case 0x34545844u: // DXT4 (premultiplied BC3)
            case 0x35545844u: // DXT5
                return decodeBc(body, bodyLen, w, h, BcKind::Bc3, img, err);
            default:
            {
                char cc[5] = { static_cast<char>(fourCC & 0xFF), static_cast<char>((fourCC >> 8) & 0xFF),
                    static_cast<char>((fourCC >> 16) & 0xFF), static_cast<char>((fourCC >> 24) & 0xFF), 0 };
                for (int i = 0; i < 4; ++i)
                    if (!isprint(static_cast<unsigned char>(cc[i])))
                        cc[i] = '?';
                err = std::string("unsupported fourCC '") + cc + "'";
                return false;
            }
        }
    }

    // Uncompressed: RGB, RGBA or luminance, any bit layout described by the masks.
    const uint32_t bytesPerPixel = bitCount / 8u;
    if (bytesPerPixel < 1u || bytesPerPixel > 4u)
    {
        err = "unsupported bit count " + std::to_string(bitCount);
        return false;
    }
    const size_t need = static_cast<size_t>(w) * h * bytesPerPixel;
    if (bodyLen < need)
    {
        err = "truncated pixel data";
        return false;
    }

    int rs, rb, gs, gb, bs, bb, as, ab;
    maskInfo(rMask, rs, rb);
    maskInfo(gMask, gs, gb);
    maskInfo(bMask, bs, bb);
    maskInfo(aMask, as, ab);
    const bool luminance = (pfFlags & 0x20000u) != 0u || (rMask != 0u && gMask == 0u && bMask == 0u);

    img.w = w;
    img.h = h;
    img.rgba.assign(static_cast<size_t>(w) * h * 4u, 0);
    for (size_t i = 0; i < static_cast<size_t>(w) * h; ++i)
    {
        const uint8_t* src = body + i * bytesPerPixel;
        uint32_t v = 0;
        for (uint32_t k = 0; k < bytesPerPixel; ++k)
            v |= static_cast<uint32_t>(src[k]) << (8u * k);
        uint8_t* dst = img.rgba.data() + i * 4u;
        if (luminance)
        {
            const uint8_t l = scaleTo8((v & rMask) >> rs, rb);
            dst[0] = dst[1] = dst[2] = l;
            dst[3] = aMask ? scaleTo8((v & aMask) >> as, ab) : 255;
        }
        else
        {
            dst[0] = scaleTo8((v & rMask) >> rs, rb);
            dst[1] = scaleTo8((v & gMask) >> gs, gb);
            dst[2] = scaleTo8((v & bMask) >> bs, bb);
            dst[3] = aMask ? scaleTo8((v & aMask) >> as, ab) : 255;
        }
    }
    return true;
}

// ----------------------------------------------------------------- TGA parsing

static bool decodeTga(const uint8_t* data, size_t len, Image& img, std::string& err)
{
    if (len < 18)
    {
        err = "TGA too short";
        return false;
    }
    const uint8_t idLen = data[0];
    const uint8_t cmapType = data[1];
    const uint8_t type = data[2];
    const unsigned w = static_cast<unsigned>(data[12] | (data[13] << 8));
    const unsigned h = static_cast<unsigned>(data[14] | (data[15] << 8));
    const uint8_t depth = data[16];
    const uint8_t desc = data[17];
    if (cmapType != 0)
    {
        err = "palettised TGA unsupported";
        return false;
    }
    const bool rle = (type == 10 || type == 11);
    if (type != 2 && type != 3 && !rle)
    {
        err = "TGA image type " + std::to_string(type) + " unsupported";
        return false;
    }
    const unsigned bpp = depth / 8u;
    if (bpp < 1u || bpp > 4u || w == 0 || h == 0)
    {
        err = "TGA depth/dimensions unsupported";
        return false;
    }

    size_t pos = 18u + idLen;
    if (pos > len)
    {
        err = "TGA header overruns file";
        return false;
    }

    std::vector<uint8_t> raw;
    raw.reserve(static_cast<size_t>(w) * h * bpp);
    if (!rle)
    {
        const size_t need = static_cast<size_t>(w) * h * bpp;
        if (len - pos < need)
        {
            err = "TGA pixel data truncated";
            return false;
        }
        raw.assign(data + pos, data + pos + need);
    }
    else
    {
        const size_t want = static_cast<size_t>(w) * h;
        size_t got = 0;
        while (got < want && pos < len)
        {
            const uint8_t packet = data[pos++];
            const unsigned count = static_cast<unsigned>(packet & 0x7F) + 1u;
            if (packet & 0x80)
            {
                if (pos + bpp > len)
                    break;
                for (unsigned c = 0; c < count && got < want; ++c, ++got)
                    raw.insert(raw.end(), data + pos, data + pos + bpp);
                pos += bpp;
            }
            else
            {
                if (pos + static_cast<size_t>(count) * bpp > len)
                    break;
                raw.insert(raw.end(), data + pos, data + pos + static_cast<size_t>(count) * bpp);
                pos += static_cast<size_t>(count) * bpp;
                got += count;
            }
        }
        if (got < want)
        {
            err = "TGA RLE stream ended early";
            return false;
        }
    }

    img.w = w;
    img.h = h;
    img.rgba.assign(static_cast<size_t>(w) * h * 4u, 0);
    const bool topDown = (desc & 0x20u) != 0u;
    for (unsigned y = 0; y < h; ++y)
    {
        const unsigned srcY = topDown ? y : (h - 1u - y);
        for (unsigned x = 0; x < w; ++x)
        {
            const uint8_t* s = raw.data() + (static_cast<size_t>(srcY) * w + x) * bpp;
            uint8_t* d = img.rgba.data() + (static_cast<size_t>(y) * w + x) * 4u;
            if (bpp == 1u)
            {
                d[0] = d[1] = d[2] = s[0];
                d[3] = 255;
            }
            else
            {
                d[0] = s[2];
                d[1] = s[1];
                d[2] = s[0];
                d[3] = (bpp == 4u) ? s[3] : 255;
            }
        }
    }
    return true;
}

// -------------------------------------------------------------------- mip chain

// Area-box filter. For the power-of-two halving that Morrowind textures use this is an
// exact 2x2 average, which is the conventional mip filter and matches the host-side tool.
static Image downsample(const Image& src)
{
    Image dst;
    dst.w = std::max(1u, src.w / 2u);
    dst.h = std::max(1u, src.h / 2u);
    dst.rgba.assign(static_cast<size_t>(dst.w) * dst.h * 4u, 0);
    for (unsigned y = 0; y < dst.h; ++y)
    {
        const unsigned y0 = y * src.h / dst.h;
        const unsigned y1 = std::max(y0 + 1u, (y + 1u) * src.h / dst.h);
        for (unsigned x = 0; x < dst.w; ++x)
        {
            const unsigned x0 = x * src.w / dst.w;
            const unsigned x1 = std::max(x0 + 1u, (x + 1u) * src.w / dst.w);
            unsigned acc[4] = { 0, 0, 0, 0 };
            unsigned n = 0;
            for (unsigned sy = y0; sy < y1 && sy < src.h; ++sy)
                for (unsigned sx = x0; sx < x1 && sx < src.w; ++sx)
                {
                    const uint8_t* s = src.rgba.data() + (static_cast<size_t>(sy) * src.w + sx) * 4u;
                    acc[0] += s[0];
                    acc[1] += s[1];
                    acc[2] += s[2];
                    acc[3] += s[3];
                    ++n;
                }
            uint8_t* d = dst.rgba.data() + (static_cast<size_t>(y) * dst.w + x) * 4u;
            for (int c = 0; c < 4; ++c)
                d[c] = static_cast<uint8_t>(n ? (acc[c] + n / 2) / n : 0);
        }
    }
    return dst;
}

// ------------------------------------------------------------------ KTX writer

static const uint8_t kKtxMagic[12] = { 0xAB, 0x4B, 0x54, 0x58, 0x20, 0x31, 0x31, 0xBB, 0x0D, 0x0A,
    0x1A, 0x0A };

static void put32(std::vector<uint8_t>& out, uint32_t v)
{
    out.push_back(static_cast<uint8_t>(v & 0xFF));
    out.push_back(static_cast<uint8_t>((v >> 8) & 0xFF));
    out.push_back(static_cast<uint8_t>((v >> 16) & 0xFF));
    out.push_back(static_cast<uint8_t>((v >> 24) & 0xFF));
}

static std::vector<uint8_t> buildKtx1(
    uint32_t glFormat, unsigned w, unsigned h, const std::vector<std::vector<uint8_t>>& levels)
{
    static const char kKey[] = "KTXorientation";
    static const char kVal[] = "S=r,T=d";
    std::vector<uint8_t> kv;
    {
        std::vector<uint8_t> pair;
        pair.insert(pair.end(), kKey, kKey + sizeof(kKey)); // includes the NUL
        pair.insert(pair.end(), kVal, kVal + sizeof(kVal));
        put32(kv, static_cast<uint32_t>(pair.size()));
        kv.insert(kv.end(), pair.begin(), pair.end());
        while (kv.size() % 4u)
            kv.push_back(0);
    }

    std::vector<uint8_t> out;
    out.insert(out.end(), kKtxMagic, kKtxMagic + 12);
    put32(out, 0x04030201u);                                  // endianness
    put32(out, 0u);                                           // glType
    put32(out, 1u);                                           // glTypeSize
    put32(out, 0u);                                           // glFormat
    put32(out, glFormat);                                     // glInternalFormat
    put32(out, 0x1908u);                                      // glBaseInternalFormat = GL_RGBA
    put32(out, w);
    put32(out, h);
    put32(out, 0u);                                           // pixelDepth
    put32(out, 0u);                                           // numberOfArrayElements
    put32(out, 1u);                                           // numberOfFaces
    put32(out, static_cast<uint32_t>(levels.size()));
    put32(out, static_cast<uint32_t>(kv.size()));
    out.insert(out.end(), kv.begin(), kv.end());
    for (const std::vector<uint8_t>& lvl : levels)
    {
        put32(out, static_cast<uint32_t>(lvl.size()));
        out.insert(out.end(), lvl.begin(), lvl.end());
        while (out.size() % 4u)
            out.push_back(0);
    }
    return out;
}

// ------------------------------------------------------------------ BSA reader

struct Entry
{
    std::string name;   // lowercase, forward slashes, VFS-relative
    std::string archive; // empty for a loose file
    std::string loose;   // absolute path for a loose file
    uint64_t offset = 0;
    uint32_t size = 0;
};

// Layout per OpenMW components/bsa/bsafile.cpp:
//   12 bytes: uint32 id (0x100), uint32 dirsize, uint32 numfiles
//   8*n: (size, offset) pairs   4*n: name offsets   (dirsize - 12n): name buffer
//   8*n: hash table (ignored)   then data, offsets relative to 12 + dirsize + 8n
static bool readBsa(const std::string& path, std::vector<Entry>& out, std::string& err)
{
    std::ifstream in(path, std::ios::binary);
    if (!in)
    {
        err = "cannot open " + path;
        return false;
    }
    uint8_t head[12];
    in.read(reinterpret_cast<char*>(head), 12);
    if (!in)
    {
        err = "short header";
        return false;
    }
    const uint32_t magic = rd32(head), dirsize = rd32(head + 4), numfiles = rd32(head + 8);
    if (magic != 0x100u)
    {
        err = "not a Morrowind BSA (id != 0x100)";
        return false;
    }
    if (numfiles == 0u || numfiles > 1000000u || dirsize < 12u * numfiles)
    {
        err = "implausible directory (" + std::to_string(numfiles) + " files, dirsize "
            + std::to_string(dirsize) + ")";
        return false;
    }
    std::vector<uint8_t> table(12u * static_cast<size_t>(numfiles));
    in.read(reinterpret_cast<char*>(table.data()), static_cast<std::streamsize>(table.size()));
    const size_t nameBytes = dirsize - 12u * static_cast<size_t>(numfiles);
    std::vector<char> names(nameBytes);
    in.read(names.data(), static_cast<std::streamsize>(nameBytes));
    if (!in)
    {
        err = "truncated directory";
        return false;
    }
    const uint64_t dataOffset = 12ull + dirsize + 8ull * numfiles;
    for (uint32_t i = 0; i < numfiles; ++i)
    {
        const uint32_t size = rd32(table.data() + static_cast<size_t>(i) * 8u);
        const uint32_t rel = rd32(table.data() + static_cast<size_t>(i) * 8u + 4u);
        const uint32_t nameOff = rd32(table.data() + 8u * static_cast<size_t>(numfiles) + 4u * i);
        if (nameOff >= nameBytes)
        {
            err = "name offset outside the buffer";
            return false;
        }
        const char* begin = names.data() + nameOff;
        const size_t maxLen = nameBytes - nameOff;
        const size_t nameLen = strnlen(begin, maxLen);
        if (nameLen == maxLen)
        {
            err = "unterminated name";
            return false;
        }
        Entry e;
        e.name.assign(begin, nameLen);
        for (char& c : e.name)
        {
            if (c == '\\')
                c = '/';
            c = static_cast<char>(tolower(static_cast<unsigned char>(c)));
        }
        e.archive = path;
        e.offset = dataOffset + rel;
        e.size = size;
        out.push_back(std::move(e));
    }
    return true;
}

// ------------------------------------------------------------------ exclusions

// UI art, CPU-read-back textures and normal maps stay on the DXT path:
//   * killAlpha and OPENMW_DECOMPRESS_TEXTURES use osg::Image::getColor(), garbage for ASTC
//   * ASTC without -normal wrecks normal maps, and -normal changes the channel layout
static const char* kExclude[]
    = { "menu", "cursor", "mouse", "font", "icon", "loading", "splash", "logo", "bookart",
          "/omw/", "mygui", "_n.", "_nh.", "magicitem" };

static const char* excludedBy(const std::string& name)
{
    const std::string probe = "/" + name;
    for (const char* bad : kExclude)
        if (probe.find(bad) != std::string::npos)
            return bad;
    return nullptr;
}

// ------------------------------------------------------------------- progress

struct Progress
{
    std::string file;
    std::string phase = "CONVERTING TEXTURES";
    std::mutex mutex;

    void publish(int pct, const std::string& detail)
    {
        if (file.empty())
            return;
        std::lock_guard<std::mutex> lock(mutex);
        const std::string tmp = file + ".tmp";
        {
            std::ofstream out(tmp, std::ios::trunc);
            if (!out)
                return;
            out << "phase=" << phase << "\n";
            out << "pct=" << pct << "\n";
            out << "detail=" << detail << "\n";
            out << "step=1\n";
            out << "steps=1\n";
        }
        std::error_code ec;
        fs::rename(tmp, file, ec);
    }
};

// -------------------------------------------------------------------- worker

struct Options
{
    std::string block = "8x8";
    float quality = ASTCENC_PRE_MEDIUM;
    std::string qualityName = "medium";
    std::string out;
    unsigned threads = 0;
    unsigned minSize = 128;
    unsigned maxSize = 0; // 0 = no upper bound
    size_t limit = 0;
    bool force = false;
    bool dryRun = false;
    unsigned reportEvery = 25;
    std::string progressFile;
};

struct Counters
{
    std::chrono::steady_clock::time_point start = std::chrono::steady_clock::now();
    std::atomic<size_t> next{ 0 };
    std::atomic<size_t> done{ 0 };
    std::atomic<size_t> ok{ 0 };
    std::atomic<size_t> small{ 0 };
    std::atomic<size_t> large{ 0 };
    std::atomic<size_t> fail{ 0 };
    std::atomic<uint64_t> bytesIn{ 0 };
    std::atomic<uint64_t> bytesOut{ 0 };
};

static bool readBytes(const Entry& e, std::vector<uint8_t>& buf, std::string& err)
{
    if (!e.archive.empty())
    {
        std::ifstream in(e.archive, std::ios::binary);
        if (!in)
        {
            err = "cannot open archive";
            return false;
        }
        in.seekg(static_cast<std::streamoff>(e.offset));
        buf.resize(e.size);
        in.read(reinterpret_cast<char*>(buf.data()), e.size);
        if (!in)
        {
            err = "short read from archive";
            return false;
        }
        return true;
    }
    std::ifstream in(e.loose, std::ios::binary | std::ios::ate);
    if (!in)
    {
        err = "cannot open file";
        return false;
    }
    const std::streamoff len = in.tellg();
    in.seekg(0);
    buf.resize(static_cast<size_t>(len));
    in.read(reinterpret_cast<char*>(buf.data()), len);
    return static_cast<bool>(in);
}

static void worker(const std::vector<Entry>& jobs, const Options& opt, unsigned bx, unsigned by,
    uint32_t glFormat, Counters& counters, Progress& progress, std::mutex& logMutex)
{
    astcenc_config config{};
    if (astcenc_config_init(ASTCENC_PRF_LDR, bx, by, 1, opt.quality, 0, &config) != ASTCENC_SUCCESS)
    {
        std::lock_guard<std::mutex> lock(logMutex);
        printf("TSP_TEXCONV_V1 fatal astcenc_config_init failed\n");
        return;
    }
    astcenc_context* context = nullptr;
    if (astcenc_context_alloc(&config, 1, &context, nullptr) != ASTCENC_SUCCESS)
    {
        std::lock_guard<std::mutex> lock(logMutex);
        printf("TSP_TEXCONV_V1 fatal astcenc_context_alloc failed\n");
        return;
    }
    static const astcenc_swizzle swizzle{ ASTCENC_SWZ_R, ASTCENC_SWZ_G, ASTCENC_SWZ_B,
        ASTCENC_SWZ_A };

    for (;;)
    {
        const size_t index = counters.next.fetch_add(1);
        if (index >= jobs.size())
            break;
        const Entry& e = jobs[index];
        std::string failure;
        bool wasSmall = false;
        bool wasLarge = false;
        bool succeeded = false;
        uint64_t produced = 0;

        std::vector<uint8_t> raw;
        Image image;
        if (!readBytes(e, raw, failure))
        {
            // failure already set
        }
        else
        {
            const bool isTga = e.name.size() > 4 && e.name.compare(e.name.size() - 4, 4, ".tga") == 0;
            const bool decoded = isTga ? decodeTga(raw.data(), raw.size(), image, failure)
                                       : decodeDds(raw.data(), raw.size(), image, failure);
            if (decoded)
            {
                if (std::max(image.w, image.h) < opt.minSize)
                    wasSmall = true;
                else if (opt.maxSize != 0 && std::max(image.w, image.h) > opt.maxSize)
                    wasLarge = true;
                else
                {
                    std::vector<std::vector<uint8_t>> levels;
                    Image level = image;
                    for (;;)
                    {
                        std::vector<uint8_t> payload(astcPayloadBytes(level.w, level.h, bx, by));
                        astcenc_image ai{};
                        ai.dim_x = level.w;
                        ai.dim_y = level.h;
                        ai.dim_z = 1;
                        ai.data_type = ASTCENC_TYPE_U8;
                        void* slice = level.rgba.data();
                        ai.data = &slice;
                        const astcenc_error rc = astcenc_compress_image(
                            context, &ai, &swizzle, payload.data(), payload.size(), 0);
                        astcenc_compress_reset(context);
                        if (rc != ASTCENC_SUCCESS)
                        {
                            failure = std::string("astcenc: ") + astcenc_get_error_string(rc);
                            break;
                        }
                        levels.push_back(std::move(payload));
                        if (level.w == 1u && level.h == 1u)
                            break;
                        level = downsample(level);
                    }
                    if (failure.empty())
                    {
                        const std::vector<uint8_t> blob
                            = buildKtx1(glFormat, image.w, image.h, levels);
                        const fs::path dst
                            = fs::path(opt.out) / (e.name.substr(0, e.name.size() - 4) + ".ktx");
                        std::error_code ec;
                        fs::create_directories(dst.parent_path(), ec);
                        const fs::path tmp = dst.string() + ".part";
                        {
                            std::ofstream out(tmp, std::ios::binary | std::ios::trunc);
                            if (!out)
                                failure = "cannot write " + tmp.string();
                            else
                                out.write(reinterpret_cast<const char*>(blob.data()),
                                    static_cast<std::streamsize>(blob.size()));
                        }
                        if (failure.empty())
                        {
                            fs::rename(tmp, dst, ec);
                            if (ec)
                                failure = "rename failed: " + ec.message();
                            else
                            {
                                succeeded = true;
                                produced = blob.size();
                            }
                        }
                    }
                }
            }
        }

        if (succeeded)
        {
            counters.ok.fetch_add(1);
            counters.bytesIn.fetch_add(e.size ? e.size : raw.size());
            counters.bytesOut.fetch_add(produced);
        }
        else if (wasSmall)
            counters.small.fetch_add(1);
        else if (wasLarge)
            counters.large.fetch_add(1);
        else
        {
            counters.fail.fetch_add(1);
            std::lock_guard<std::mutex> lock(logMutex);
            printf("TSP_TEXCONV_V1 fail name=%s reason=%s\n", e.name.c_str(), failure.c_str());
            fflush(stdout);
        }

        const size_t completed = counters.done.fetch_add(1) + 1;
        if (completed % opt.reportEvery == 0 || completed == jobs.size())
        {
            const int pct = static_cast<int>(completed * 100 / std::max<size_t>(1, jobs.size()));
            const double secs
                = std::chrono::duration<double>(std::chrono::steady_clock::now() - counters.start)
                      .count();
            const double rate = completed / std::max(0.001, secs);
            const long long eta
                = static_cast<long long>((jobs.size() - completed) / std::max(0.001, rate));
            char detail[64];
            snprintf(detail, sizeof(detail), "%zu / %zu textures", completed, jobs.size());
            {
                std::lock_guard<std::mutex> lock(logMutex);
                printf("TSP_TEXCONV_V1 progress done=%zu total=%zu ok=%zu small=%zu fail=%zu "
                       "pct=%d rate=%.2f eta=%lld\n",
                    completed, jobs.size(), counters.ok.load(), counters.small.load(),
                    counters.fail.load(), pct, rate, eta);
                fflush(stdout);
            }
            progress.publish(pct, detail);
        }
    }
    astcenc_context_free(context);
}

// ----------------------------------------------------------------------- main

static void usage()
{
    printf("TSP_TEXCONV_V1\n"
           "usage: tsp_texconv --out DIR [--bsa FILE]... [--loose DIR]... [options]\n"
           "  --block 8x8|6x6|...   ASTC block size (default 8x8)\n"
           "  --quality NAME        fastest|fast|medium|thorough (default medium)\n"
           "  --threads N           worker threads (default: all cores)\n"
           "  --min-size N          skip textures whose larger side is below N (default 128)\n"
           "  --max-size N          skip textures whose larger side is above N (0 = no limit)\n"
           "  --limit N             stop after N textures (smoke test)\n"
           "  --progress-file PATH  publish phase/pct/detail atomically for the manager UI\n"
           "  --force               reconvert even if the .ktx already exists\n"
           "  --dry-run             list what would be done and exit\n");
}

int main(int argc, char** argv)
{
    Options opt;
    std::vector<std::string> bsas, looseDirs;

    for (int i = 1; i < argc; ++i)
    {
        const std::string a = argv[i];
        auto next = [&](const char* what) -> std::string {
            if (i + 1 >= argc)
            {
                printf("TSP_TEXCONV_V1 fatal %s needs a value\n", what);
                exit(2);
            }
            return argv[++i];
        };
        if (a == "--bsa")
            bsas.push_back(next("--bsa"));
        else if (a == "--loose")
            looseDirs.push_back(next("--loose"));
        else if (a == "--out")
            opt.out = next("--out");
        else if (a == "--block")
            opt.block = next("--block");
        else if (a == "--quality")
        {
            opt.qualityName = next("--quality");
            if (opt.qualityName == "fastest")
                opt.quality = ASTCENC_PRE_FASTEST;
            else if (opt.qualityName == "fast")
                opt.quality = ASTCENC_PRE_FAST;
            else if (opt.qualityName == "medium")
                opt.quality = ASTCENC_PRE_MEDIUM;
            else if (opt.qualityName == "thorough")
                opt.quality = ASTCENC_PRE_THOROUGH;
            else
            {
                printf("TSP_TEXCONV_V1 fatal unknown quality %s\n", opt.qualityName.c_str());
                return 2;
            }
        }
        else if (a == "--threads")
            opt.threads = static_cast<unsigned>(atoi(next("--threads").c_str()));
        else if (a == "--min-size")
            opt.minSize = static_cast<unsigned>(atoi(next("--min-size").c_str()));
        else if (a == "--max-size")
            opt.maxSize = static_cast<unsigned>(atoi(next("--max-size").c_str()));
        else if (a == "--limit")
            opt.limit = static_cast<size_t>(atoll(next("--limit").c_str()));
        else if (a == "--report-every")
            opt.reportEvery = std::max(1, atoi(next("--report-every").c_str()));
        else if (a == "--progress-file")
            opt.progressFile = next("--progress-file");
        else if (a == "--force")
            opt.force = true;
        else if (a == "--dry-run")
            opt.dryRun = true;
        else if (a == "-h" || a == "--help")
        {
            usage();
            return 0;
        }
        else
        {
            printf("TSP_TEXCONV_V1 fatal unknown argument %s\n", a.c_str());
            return 2;
        }
    }

    if (opt.out.empty() || (bsas.empty() && looseDirs.empty()))
    {
        usage();
        return 2;
    }

    unsigned bx = 0, by = 0;
    uint32_t glFormat = 0;
    if (!blockToFormat(opt.block, bx, by, glFormat))
    {
        printf("TSP_TEXCONV_V1 fatal unsupported block %s\n", opt.block.c_str());
        return 2;
    }
    if (opt.threads == 0u)
        opt.threads = std::max(1u, std::thread::hardware_concurrency());

    // Discover, applying archive precedence: a later archive wins for the same name, which
    // matches the fallback-archive order in openmw.cfg. Loose files beat both.
    std::map<std::string, Entry> chosen;
    std::map<std::string, size_t> skipped;
    for (const std::string& bsa : bsas)
    {
        std::vector<Entry> entries;
        std::string err;
        if (!readBsa(bsa, entries, err))
        {
            printf("TSP_TEXCONV_V1 fatal %s: %s\n", bsa.c_str(), err.c_str());
            return 3;
        }
        size_t eligible = 0;
        for (Entry& e : entries)
        {
            if (e.name.compare(0, 9, "textures/") != 0)
                continue;
            const bool isDds = e.name.size() > 4 && e.name.compare(e.name.size() - 4, 4, ".dds") == 0;
            const bool isTga = e.name.size() > 4 && e.name.compare(e.name.size() - 4, 4, ".tga") == 0;
            if (!isDds && !isTga)
                continue;
            if (const char* bad = excludedBy(e.name))
            {
                ++skipped[std::string("excluded:") + bad];
                continue;
            }
            chosen[e.name] = e;
            ++eligible;
        }
        printf("TSP_TEXCONV_V1 archive %s entries=%zu eligible=%zu\n",
            fs::path(bsa).filename().string().c_str(), entries.size(), eligible);
    }
    for (const std::string& dir : looseDirs)
    {
        std::error_code ec;
        for (fs::recursive_directory_iterator it(dir, ec), end; it != end; it.increment(ec))
        {
            if (ec || !it->is_regular_file())
                continue;
            std::string path = it->path().string();
            std::string lower = path;
            for (char& c : lower)
                c = static_cast<char>(tolower(static_cast<unsigned char>(c)));
            const bool isDds = lower.size() > 4 && lower.compare(lower.size() - 4, 4, ".dds") == 0;
            const bool isTga = lower.size() > 4 && lower.compare(lower.size() - 4, 4, ".tga") == 0;
            if (!isDds && !isTga)
                continue;
            const size_t at = lower.rfind("textures/");
            if (at == std::string::npos)
                continue;
            Entry e;
            e.name = lower.substr(at);
            e.loose = path;
            if (const char* bad = excludedBy(e.name))
            {
                ++skipped[std::string("excluded:") + bad];
                continue;
            }
            chosen[e.name] = e;
        }
    }

    std::vector<Entry> jobs;
    for (const auto& kv : chosen)
    {
        const fs::path dst
            = fs::path(opt.out) / (kv.first.substr(0, kv.first.size() - 4) + ".ktx");
        if (!opt.force && fs::exists(dst))
        {
            ++skipped["already-converted"];
            continue;
        }
        jobs.push_back(kv.second);
        if (opt.limit && jobs.size() >= opt.limit)
            break;
    }

    printf("TSP_TEXCONV_V1 start total=%zu unique=%zu threads=%u block=%s quality=%s "
           "min=%u max=%u out=%s\n",
        jobs.size(), chosen.size(), opt.threads, opt.block.c_str(), opt.qualityName.c_str(),
        opt.minSize, opt.maxSize, opt.out.c_str());
    for (const auto& kv : skipped)
        printf("TSP_TEXCONV_V1 skipped %s=%zu\n", kv.first.c_str(), kv.second);
    fflush(stdout);

    if (opt.dryRun)
    {
        size_t shown = 0;
        for (const Entry& e : jobs)
        {
            if (shown++ >= 20)
                break;
            printf("TSP_TEXCONV_V1 would-convert %s\n", e.name.c_str());
        }
        return 0;
    }
    if (jobs.empty())
    {
        printf("TSP_TEXCONV_V1 done ok=0 small=0 fail=0 in=0 out=0 secs=0.0 nothing-to-do\n");
        return 0;
    }

    Counters counters;
    Progress progress;
    progress.file = opt.progressFile;
    std::mutex logMutex;
    progress.publish(0, "0 / " + std::to_string(jobs.size()) + " textures");

    counters.start = std::chrono::steady_clock::now();
    const auto started = counters.start;
    std::vector<std::thread> pool;
    for (unsigned t = 0; t < opt.threads; ++t)
        pool.emplace_back(worker, std::cref(jobs), std::cref(opt), bx, by, glFormat,
            std::ref(counters), std::ref(progress), std::ref(logMutex));
    for (std::thread& th : pool)
        th.join();
    const double secs = std::chrono::duration<double>(std::chrono::steady_clock::now() - started)
                            .count();

    printf("TSP_TEXCONV_V1 done ok=%zu small=%zu large=%zu fail=%zu in=%llu out=%llu secs=%.1f\n",
        counters.ok.load(), counters.small.load(), counters.large.load(), counters.fail.load(),
        static_cast<unsigned long long>(counters.bytesIn.load()),
        static_cast<unsigned long long>(counters.bytesOut.load()), secs);
    fflush(stdout);

    // A marker the manager can test for "already converted", and re-test for staleness.
    {
        std::error_code ec;
        fs::create_directories(opt.out, ec);
        std::ofstream marker(fs::path(opt.out) / "tsp_texconv.done", std::ios::trunc);
        if (marker)
        {
            marker << "version=TSP_TEXCONV_V1\n";
            marker << "block=" << opt.block << "\n";
            marker << "quality=" << opt.qualityName << "\n";
            marker << "min_size=" << opt.minSize << "\n";
            marker << "max_size=" << opt.maxSize << "\n";
            marker << "converted=" << counters.ok.load() << "\n";
            marker << "skipped_small=" << counters.small.load() << "\n";
            marker << "failed=" << counters.fail.load() << "\n";
            for (const std::string& bsa : bsas)
            {
                std::error_code se;
                const uintmax_t size = fs::file_size(bsa, se);
                marker << "source=" << fs::path(bsa).filename().string() << ":"
                       << (se ? 0u : size) << "\n";
            }
        }
    }

    return counters.fail.load() ? 1 : 0;
}
