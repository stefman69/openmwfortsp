#!/usr/bin/env bash
set -Eeuo pipefail

cd "$HOME/Downloads"

DEV="${TSP_DEV:-root@192.168.1.25}"
CTR="${TSP_BUILDER:-openmw_builder}"

ROOT="/mnt/SDCARD/data/ports/openmw51"
RUNTIME="$ROOT/navmesh-tool-runtime"
PROGRESS="$ROOT/bin/openmw-navmesh-progress"
PORTS="/mnt/SDCARD/Roms/PORTS"

GEN_LAUNCHER="$PORTS/OpenMW_51_Generate_Full_Navmesh_3Worker.sh"
ATTACH_LAUNCHER="$PORTS/OpenMW_51_Attach_Navmesh_Progress.sh"
DEMO_LAUNCHER="$PORTS/OpenMW_51_Navmesh_UI_Demo.sh"

STAMP="$(date +%Y%m%d-%H%M%S)"
PKG="$HOME/Downloads/navmesh-framebuffer-ui-$STAMP"
mkdir -p "$PKG"

exec > >(tee "$PKG/install.log") 2>&1

echo "=================================================================="
echo "OPENMW 0.51 NAVMESH FRAMEBUFFER UI"
echo "=================================================================="
echo "Purpose:"
echo "  remove SDL/EGL/GL4ES/Weston from the navmesh progress display"
echo
echo "This installer:"
echo "  - rebuilds ONLY the tiny progress helper"
echo "  - installs an attach-only Ports entry"
echo "  - installs a demo Ports entry"
echo "  - replaces the generator launcher with a clean framebuffer version"
echo
echo "This installer DOES NOT:"
echo "  - start navmeshtool"
echo "  - stop a running navmeshtool"
echo "  - modify navmesh.db"
echo "=================================================================="

cat > "$PKG/navmesh_progress_fb.cpp" <<'CPP'
#include <linux/fb.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <signal.h>

#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <deque>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <optional>
#include <regex>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

namespace
{
    using Clock = std::chrono::steady_clock;
    volatile sig_atomic_t gStop = 0;

    void onSignal(int) { gStop = 1; }

    struct Color { uint8_t r, g, b; };

    using Glyph = std::array<uint8_t, 7>;

    Glyph glyph(char raw)
    {
        char c = raw;
        if (c >= 'a' && c <= 'z')
            c = static_cast<char>(c - 'a' + 'A');

        switch (c)
        {
            case 'A': return {14,17,17,31,17,17,17};
            case 'B': return {30,17,17,30,17,17,30};
            case 'C': return {14,17,16,16,16,17,14};
            case 'D': return {30,17,17,17,17,17,30};
            case 'E': return {31,16,16,30,16,16,31};
            case 'F': return {31,16,16,30,16,16,16};
            case 'G': return {14,17,16,23,17,17,15};
            case 'H': return {17,17,17,31,17,17,17};
            case 'I': return {31,4,4,4,4,4,31};
            case 'J': return {7,2,2,2,18,18,12};
            case 'K': return {17,18,20,24,20,18,17};
            case 'L': return {16,16,16,16,16,16,31};
            case 'M': return {17,27,21,21,17,17,17};
            case 'N': return {17,25,21,19,17,17,17};
            case 'O': return {14,17,17,17,17,17,14};
            case 'P': return {30,17,17,30,16,16,16};
            case 'Q': return {14,17,17,17,21,18,13};
            case 'R': return {30,17,17,30,20,18,17};
            case 'S': return {15,16,16,14,1,1,30};
            case 'T': return {31,4,4,4,4,4,4};
            case 'U': return {17,17,17,17,17,17,14};
            case 'V': return {17,17,17,17,17,10,4};
            case 'W': return {17,17,17,21,21,21,10};
            case 'X': return {17,17,10,4,10,17,17};
            case 'Y': return {17,17,10,4,4,4,4};
            case 'Z': return {31,1,2,4,8,16,31};

            case '0': return {14,17,19,21,25,17,14};
            case '1': return {4,12,4,4,4,4,14};
            case '2': return {14,17,1,2,4,8,31};
            case '3': return {30,1,1,14,1,1,30};
            case '4': return {2,6,10,18,31,2,2};
            case '5': return {31,16,16,30,1,1,30};
            case '6': return {14,16,16,30,17,17,14};
            case '7': return {31,1,2,4,8,8,8};
            case '8': return {14,17,17,14,17,17,14};
            case '9': return {14,17,17,15,1,1,14};

            case ':': return {0,4,4,0,4,4,0};
            case '.': return {0,0,0,0,0,6,6};
            case '/': return {1,1,2,4,8,16,16};
            case '%': return {17,2,4,8,16,17,0};
            case '-': return {0,0,0,31,0,0,0};
            case '+': return {0,4,4,31,4,4,0};
            case '_': return {0,0,0,0,0,0,31};
            case '(': return {2,4,8,8,8,4,2};
            case ')': return {8,4,2,2,2,4,8};
            case '[': return {14,8,8,8,8,8,14};
            case ']': return {14,2,2,2,2,2,14};
            case ',': return {0,0,0,0,6,4,8};
            case '\'': return {4,4,2,0,0,0,0};
            case '"': return {10,10,0,0,0,0,0};
            case '=': return {0,31,0,31,0,0,0};
            case '?': return {14,17,1,2,4,0,4};
            case ' ': return {0,0,0,0,0,0,0};
            default:  return {31,17,2,4,4,0,4};
        }
    }

    class Framebuffer
    {
    public:
        ~Framebuffer()
        {
            restore();
            if (mMap != MAP_FAILED)
                munmap(mMap, mMapLength);
            if (mFd >= 0)
                close(mFd);
        }

        bool openDevice(std::string& error)
        {
            const char* candidates[] = {"/dev/fb0", "/dev/graphics/fb0"};

            for (const char* path : candidates)
            {
                mFd = ::open(path, O_RDWR);
                if (mFd >= 0)
                {
                    mPath = path;
                    break;
                }
            }

            if (mFd < 0)
            {
                error = "could not open /dev/fb0 or /dev/graphics/fb0";
                return false;
            }

            if (ioctl(mFd, FBIOGET_FSCREENINFO, &mFix) != 0)
            {
                error = "FBIOGET_FSCREENINFO failed";
                return false;
            }

            if (ioctl(mFd, FBIOGET_VSCREENINFO, &mVar) != 0)
            {
                error = "FBIOGET_VSCREENINFO failed";
                return false;
            }

            mBytesPerPixel = (mVar.bits_per_pixel + 7) / 8;

            if (mBytesPerPixel < 2 || mBytesPerPixel > 4)
            {
                std::ostringstream out;
                out << "unsupported framebuffer bpp " << mVar.bits_per_pixel;
                error = out.str();
                return false;
            }

            mMapLength = mFix.smem_len;
            mMap = mmap(nullptr, mMapLength, PROT_READ | PROT_WRITE, MAP_SHARED, mFd, 0);

            if (mMap == MAP_FAILED)
            {
                error = "mmap framebuffer failed";
                return false;
            }

            const size_t visibleBytes =
                static_cast<size_t>(mFix.line_length) *
                static_cast<size_t>(mVar.yres);

            const size_t visibleOffset =
                static_cast<size_t>(mVar.yoffset) * mFix.line_length;

            if (visibleOffset + visibleBytes <= mMapLength)
            {
                mBackup.resize(visibleBytes);
                std::memcpy(
                    mBackup.data(),
                    static_cast<uint8_t*>(mMap) + visibleOffset,
                    visibleBytes);
                mHaveBackup = true;
            }

            return true;
        }

        int width() const { return static_cast<int>(mVar.xres); }
        int height() const { return static_cast<int>(mVar.yres); }

        std::string description() const
        {
            std::ostringstream out;
            out << mPath
                << " " << mVar.xres << "x" << mVar.yres
                << " virtual=" << mVar.xres_virtual << "x" << mVar.yres_virtual
                << " bpp=" << mVar.bits_per_pixel
                << " stride=" << mFix.line_length
                << " rgba="
                << mVar.red.offset << "/" << mVar.red.length << ","
                << mVar.green.offset << "/" << mVar.green.length << ","
                << mVar.blue.offset << "/" << mVar.blue.length << ","
                << mVar.transp.offset << "/" << mVar.transp.length;
            return out.str();
        }

        void restore()
        {
            if (!mHaveBackup || mMap == MAP_FAILED)
                return;

            const size_t visibleOffset =
                static_cast<size_t>(mVar.yoffset) * mFix.line_length;

            std::memcpy(
                static_cast<uint8_t*>(mMap) + visibleOffset,
                mBackup.data(),
                mBackup.size());

            msync(
                static_cast<uint8_t*>(mMap) + visibleOffset,
                mBackup.size(),
                MS_ASYNC);

            mHaveBackup = false;
        }

        void clear(Color c)
        {
            rect(0, 0, width(), height(), c);
        }

        void rect(int x, int y, int w, int h, Color c)
        {
            if (w <= 0 || h <= 0)
                return;

            const int x0 = std::max(0, x);
            const int y0 = std::max(0, y);
            const int x1 = std::min(width(), x + w);
            const int y1 = std::min(height(), y + h);

            const uint32_t pixel = pack(c);

            for (int py = y0; py < y1; ++py)
            {
                for (int px = x0; px < x1; ++px)
                    putPixel(px, py, pixel);
            }
        }

        void present()
        {
            if (mMap != MAP_FAILED)
                msync(mMap, mMapLength, MS_ASYNC);
        }

    private:
        static uint32_t scaleChannel(uint8_t value, const fb_bitfield& field)
        {
            if (field.length == 0)
                return 0;

            const uint32_t maxValue =
                field.length >= 32 ? 0xffffffffu : ((1u << field.length) - 1u);

            const uint32_t scaled =
                (static_cast<uint32_t>(value) * maxValue + 127u) / 255u;

            return scaled << field.offset;
        }

        uint32_t pack(Color c) const
        {
            uint32_t p = 0;
            p |= scaleChannel(c.r, mVar.red);
            p |= scaleChannel(c.g, mVar.green);
            p |= scaleChannel(c.b, mVar.blue);

            if (mVar.transp.length)
                p |= scaleChannel(255, mVar.transp);

            return p;
        }

        void putPixel(int x, int y, uint32_t pixel)
        {
            const size_t byteOffset =
                static_cast<size_t>(y + mVar.yoffset) * mFix.line_length +
                static_cast<size_t>(x + mVar.xoffset) * mBytesPerPixel;

            if (byteOffset + mBytesPerPixel > mMapLength)
                return;

            uint8_t* dst = static_cast<uint8_t*>(mMap) + byteOffset;

            switch (mBytesPerPixel)
            {
                case 2:
                {
                    uint16_t v = static_cast<uint16_t>(pixel);
                    std::memcpy(dst, &v, sizeof(v));
                    break;
                }
                case 3:
                    dst[0] = static_cast<uint8_t>(pixel & 0xff);
                    dst[1] = static_cast<uint8_t>((pixel >> 8) & 0xff);
                    dst[2] = static_cast<uint8_t>((pixel >> 16) & 0xff);
                    break;
                default:
                    std::memcpy(dst, &pixel, sizeof(pixel));
                    break;
            }
        }

        int mFd = -1;
        void* mMap = MAP_FAILED;
        size_t mMapLength = 0;
        size_t mBytesPerPixel = 0;
        fb_fix_screeninfo mFix{};
        fb_var_screeninfo mVar{};
        std::string mPath;
        std::vector<uint8_t> mBackup;
        bool mHaveBackup = false;
    };

    int textWidth(const std::string& text, int scale)
    {
        if (text.empty())
            return 0;
        return static_cast<int>(text.size()) * 6 * scale - scale;
    }

    void drawText(
        Framebuffer& fb,
        const std::string& text,
        int x,
        int y,
        int scale,
        Color color)
    {
        int cursor = x;

        for (char c : text)
        {
            const Glyph g = glyph(c);

            for (int row = 0; row < 7; ++row)
            {
                for (int col = 0; col < 5; ++col)
                {
                    if (g[row] & (1u << (4 - col)))
                    {
                        fb.rect(
                            cursor + col * scale,
                            y + row * scale,
                            scale,
                            scale,
                            color);
                    }
                }
            }

            cursor += 6 * scale;
        }
    }

    void drawCentered(
        Framebuffer& fb,
        const std::string& text,
        int y,
        int scale,
        Color color)
    {
        const int x = std::max(0, (fb.width() - textWidth(text, scale)) / 2);
        drawText(fb, text, x, y, scale, color);
    }

    std::string shorten(const std::string& s, size_t max)
    {
        if (s.size() <= max)
            return s;
        if (max <= 3)
            return s.substr(0, max);
        return s.substr(0, max - 3) + "...";
    }

    std::string formatDuration(double seconds)
    {
        if (seconds < 0.0)
            seconds = 0.0;

        const long total = static_cast<long>(seconds);
        const long h = total / 3600;
        const long m = (total % 3600) / 60;
        const long s = total % 60;

        std::ostringstream out;
        if (h > 0)
            out << h << "H ";
        out << std::setw(2) << std::setfill('0') << m
            << ":"
            << std::setw(2) << std::setfill('0') << s;
        return out.str();
    }

    std::string formatBytes(uintmax_t bytes)
    {
        const double mib = static_cast<double>(bytes) / (1024.0 * 1024.0);
        std::ostringstream out;
        if (mib < 1024.0)
            out << std::fixed << std::setprecision(1) << mib << " MIB";
        else
            out << std::fixed << std::setprecision(2) << (mib / 1024.0) << " GIB";
        return out.str();
    }

    std::optional<int> readStatus(const std::filesystem::path& path)
    {
        std::ifstream in(path);
        if (!in)
            return std::nullopt;

        int value = -9999;
        if (in >> value)
            return value;

        return std::nullopt;
    }

    struct Progress
    {
        uint64_t worldCurrent = 0;
        uint64_t worldTotal = 0;
        uint64_t tileCurrent = 0;
        uint64_t tileTotal = 0;
        double tilePercent = 0.0;
        std::string worldName = "PREPARING NAVIGATION DATA";
    };

    class LogReader
    {
    public:
        explicit LogReader(std::filesystem::path path)
            : mPath(std::move(path))
        {
        }

        void update(Progress& p)
        {
            std::error_code ec;
            const auto size = std::filesystem::file_size(mPath, ec);
            if (ec)
                return;

            if (size < static_cast<uintmax_t>(mOffset))
                mOffset = 0;

            std::ifstream in(mPath);
            if (!in)
                return;

            in.seekg(mOffset);

            std::string line;
            while (std::getline(in, line))
                parse(line, p);

            const auto pos = in.tellg();
            if (pos >= 0)
                mOffset = pos;
            else
                mOffset = static_cast<std::streamoff>(size);
        }

    private:
        static void parse(const std::string& line, Progress& p)
        {
            static const std::regex worldDone(
                R"rx(Processed worldspace \((\d+)\/(\d+)\) "([^"]*)")rx",
                std::regex::icase);

            static const std::regex worldStart(
                R"rx(Generating navmesh tiles for "([^"]*)" worldspace)rx",
                std::regex::icase);

            static const std::regex tile(
                R"((\d+)\/(\d+)\s+\(([0-9]+(?:\.[0-9]+)?)%\)\s+navmesh tiles are generated)",
                std::regex::icase);

            std::smatch m;

            if (std::regex_search(line, m, worldDone))
            {
                p.worldCurrent = std::stoull(m[1].str());
                p.worldTotal = std::stoull(m[2].str());
                p.worldName = m[3].str();
                p.tileCurrent = 0;
                p.tileTotal = 0;
                p.tilePercent = 0.0;
                return;
            }

            if (std::regex_search(line, m, worldStart))
            {
                p.worldName = m[1].str();
                p.tileCurrent = 0;
                p.tileTotal = 0;
                p.tilePercent = 0.0;
                return;
            }

            if (std::regex_search(line, m, tile))
            {
                p.tileCurrent = std::stoull(m[1].str());
                p.tileTotal = std::stoull(m[2].str());
                p.tilePercent = std::stod(m[3].str());
            }
        }

        std::filesystem::path mPath;
        std::streamoff mOffset = 0;
    };

    void render(
        Framebuffer& fb,
        const Progress& p,
        const std::filesystem::path& dbPath,
        double elapsed,
        const std::optional<int>& status,
        bool demo)
    {
        const Color bg{10, 11, 13};
        const Color fg{236, 236, 236};
        const Color dim{145, 148, 155};
        const Color edge{85, 89, 98};
        const Color fill{220, 220, 220};
        const Color success{150, 230, 160};
        const Color failure{245, 135, 135};

        fb.clear(bg);

        const double sx = fb.width() / 1280.0;
        const double sy = fb.height() / 720.0;
        const auto X = [&](int v) { return static_cast<int>(std::round(v * sx)); };
        const auto Y = [&](int v) { return static_cast<int>(std::round(v * sy)); };
        const int s2 = std::max(1, Y(2));
        const int s3 = std::max(1, Y(3));

        drawCentered(fb, "OPENMW 0.51 NAVMESH GENERATOR", Y(55), s3, fg);
        drawCentered(
            fb,
            demo ? "FRAMEBUFFER UI DEMO" : "EXTERIOR + INTERIORS - 3 WORKERS",
            Y(105),
            s2,
            dim);

        std::string phase;
        Color phaseColor = fg;

        if (status)
        {
            if (*status == 0)
            {
                phase = "NAVMESH GENERATION COMPLETE";
                phaseColor = success;
            }
            else
            {
                phase = "NAVMESH GENERATION FAILED - CODE " + std::to_string(*status);
                phaseColor = failure;
            }
        }
        else
        {
            phase = "GENERATING NAVIGATION DATA";
        }

        drawCentered(fb, phase, Y(165), s2, phaseColor);

        const int left = X(120);
        const int right = X(1160);
        const int trackW = right - left;
        const int trackH = std::max(8, Y(24));

        double worldFraction = 0.0;
        if (p.worldTotal > 0)
            worldFraction = std::clamp(
                static_cast<double>(p.worldCurrent) /
                static_cast<double>(p.worldTotal),
                0.0, 1.0);

        fb.rect(left, Y(225), trackW, trackH, edge);
        fb.rect(
            left + Y(3),
            Y(225) + Y(3),
            std::max(0, static_cast<int>((trackW - 2 * Y(3)) * worldFraction)),
            std::max(1, trackH - 2 * Y(3)),
            fill);

        std::ostringstream overall;
        if (p.worldTotal > 0)
        {
            overall << "WORLDSPACE "
                    << p.worldCurrent
                    << " / "
                    << p.worldTotal
                    << "   "
                    << std::fixed
                    << std::setprecision(1)
                    << worldFraction * 100.0
                    << "%";
        }
        else
        {
            overall << "COLLECTING / PREPARING WORLDSPACES";
        }

        drawCentered(fb, overall.str(), Y(275), s2, fg);

        drawCentered(
            fb,
            shorten(p.worldName, 74),
            Y(330),
            s2,
            fg);

        double tileFraction = 0.0;
        if (p.tileTotal > 0)
            tileFraction = std::clamp(
                static_cast<double>(p.tileCurrent) /
                static_cast<double>(p.tileTotal),
                0.0, 1.0);

        fb.rect(left, Y(390), trackW, trackH, edge);
        fb.rect(
            left + Y(3),
            Y(390) + Y(3),
            std::max(0, static_cast<int>((trackW - 2 * Y(3)) * tileFraction)),
            std::max(1, trackH - 2 * Y(3)),
            fill);

        std::ostringstream tiles;
        if (p.tileTotal > 0)
        {
            tiles << "CURRENT CELL TILES "
                  << p.tileCurrent
                  << " / "
                  << p.tileTotal
                  << "   "
                  << std::fixed
                  << std::setprecision(1)
                  << p.tilePercent
                  << "%";
        }
        else
        {
            tiles << "CURRENT CELL: PREPARING GEOMETRY";
        }

        drawCentered(fb, tiles.str(), Y(440), s2, dim);

        std::error_code ec;
        const auto bytes = std::filesystem::file_size(dbPath, ec);

        std::string dbText = "DATABASE ";
        dbText += ec ? "NOT AVAILABLE" : formatBytes(bytes);

        drawCentered(fb, dbText, Y(510), s2, fg);
        drawCentered(fb, "ELAPSED " + formatDuration(elapsed), Y(555), s2, fg);

        if (!status)
            drawCentered(fb, "DO NOT POWER OFF WHILE DATABASE IS BEING WRITTEN", Y(630), s2, dim);
        else
            drawCentered(fb, "RETURNING TO PORTS", Y(630), s2, dim);

        fb.present();
    }

    int runDemo(Framebuffer& fb)
    {
        const auto started = Clock::now();

        while (!gStop)
        {
            const double elapsed =
                std::chrono::duration<double>(Clock::now() - started).count();

            if (elapsed >= 12.0)
                break;

            Progress p;
            p.worldTotal = 1329;
            p.worldCurrent = std::min<uint64_t>(
                p.worldTotal,
                static_cast<uint64_t>(1 + elapsed * 42.0));
            p.worldName = "BALMORA, DEMO INTERIOR";
            p.tileTotal = 96;
            p.tileCurrent = static_cast<uint64_t>(
                std::fmod(elapsed * 18.0, 97.0));
            p.tilePercent =
                100.0 * static_cast<double>(p.tileCurrent) /
                static_cast<double>(p.tileTotal);

            render(fb, p, "/mnt/UDISK/openmw51-nav/navmesh.db", elapsed, std::nullopt, true);
            std::this_thread::sleep_for(std::chrono::milliseconds(100));
        }

        const auto done = Clock::now();
        while (!gStop &&
               std::chrono::duration<double>(Clock::now() - done).count() < 3.0)
        {
            Progress p;
            p.worldTotal = 1329;
            p.worldCurrent = 1329;
            p.worldName = "DEMO COMPLETE";
            p.tileTotal = 96;
            p.tileCurrent = 96;
            p.tilePercent = 100.0;
            render(fb, p, "/mnt/UDISK/openmw51-nav/navmesh.db", 12.0, 0, true);
            std::this_thread::sleep_for(std::chrono::milliseconds(100));
        }

        return 0;
    }
}

int main(int argc, char** argv)
{
    signal(SIGINT, onSignal);
    signal(SIGTERM, onSignal);
    signal(SIGHUP, onSignal);

    Framebuffer fb;
    std::string error;

    if (!fb.openDevice(error))
    {
        std::fprintf(stderr, "Framebuffer UI failed: %s\n", error.c_str());
        return 6;
    }

    std::fprintf(stderr, "Framebuffer UI: %s\n", fb.description().c_str());

    if (argc == 2 && std::string(argv[1]) == "--demo")
        return runDemo(fb);

    if (argc < 4)
    {
        std::fprintf(
            stderr,
            "Usage: %s <log> <status-file> <navmesh.db>\n"
            "       %s --demo\n",
            argv[0],
            argv[0]);
        return 2;
    }

    const std::filesystem::path logPath = argv[1];
    const std::filesystem::path statusPath = argv[2];
    const std::filesystem::path dbPath = argv[3];

    Progress progress;
    LogReader reader(logPath);

    const auto started = Clock::now();
    std::optional<Clock::time_point> completedAt;
    std::optional<int> finalStatus;

    while (!gStop)
    {
        reader.update(progress);

        if (!finalStatus)
        {
            finalStatus = readStatus(statusPath);
            if (finalStatus)
                completedAt = Clock::now();
        }

        const double elapsed =
            std::chrono::duration<double>(Clock::now() - started).count();

        render(
            fb,
            progress,
            dbPath,
            elapsed,
            finalStatus,
            false);

        if (completedAt)
        {
            const double sinceDone =
                std::chrono::duration<double>(Clock::now() - *completedAt).count();

            if (sinceDone >= 8.0)
                break;
        }

        std::this_thread::sleep_for(std::chrono::milliseconds(100));
    }

    if (finalStatus)
        return *finalStatus;

    return 0;
}
CPP

cat > "$PKG/OpenMW_51_Attach_Navmesh_Progress.sh" <<'ATTACH'
#!/bin/bash
set -u

ROOT="/mnt/SDCARD/data/ports/openmw51"
UI="$ROOT/bin/openmw-navmesh-progress"
LOG="$ROOT/navmesh-generation-full-3worker.log"
STATUS="$ROOT/navmesh-generation-full-3worker.status"
DB="/mnt/UDISK/openmw51-nav/navmesh.db"

export LD_LIBRARY_PATH="$ROOT/lib:$ROOT/libs:$ROOT/lib/aarch64:/mnt/SDCARD/System/lib:/usr/trimui/lib:${LD_LIBRARY_PATH:-}"

exec "$UI" "$LOG" "$STATUS" "$DB" 2>>"$LOG"
ATTACH

cat > "$PKG/OpenMW_51_Navmesh_UI_Demo.sh" <<'DEMO'
#!/bin/bash
set -u

ROOT="/mnt/SDCARD/data/ports/openmw51"
UI="$ROOT/bin/openmw-navmesh-progress"

export LD_LIBRARY_PATH="$ROOT/lib:$ROOT/libs:$ROOT/lib/aarch64:/mnt/SDCARD/System/lib:/usr/trimui/lib:${LD_LIBRARY_PATH:-}"

exec "$UI" --demo 2>>"$ROOT/navmesh-progress-framebuffer-demo.log"
DEMO

cat > "$PKG/OpenMW_51_Generate_Full_Navmesh_3Worker.sh" <<'GENERATOR'
#!/bin/bash
set -u

# OpenMW 0.51 / TrimUI Smart Pro
# End-user complete navmesh generator.
#
# UI is direct Linux framebuffer: no SDL/EGL/GL4ES/Weston requirement.

ROOT="${OPENMW51_GAMEDIR:-/mnt/SDCARD/data/ports/openmw51}"
RUNTIME="$ROOT/navmesh-tool-runtime"
TOOL="$RUNTIME/openmw-navmeshtool"
UI="$ROOT/bin/openmw-navmesh-progress"
CFG="$ROOT/config-0.51"

NAVDIR="/mnt/UDISK/openmw51-nav"
DB="$NAVDIR/navmesh.db"

LOG="$ROOT/navmesh-generation-full-3worker.log"
STATUS="$ROOT/navmesh-generation-full-3worker.status"
STATUS_TMP="$STATUS.tmp"

THREADS="${NAVMESH_THREADS:-3}"

mkdir -p "$NAVDIR"

export LD_LIBRARY_PATH="$ROOT/lib:$ROOT/libs:$ROOT/lib/aarch64:/mnt/SDCARD/System/lib:/usr/trimui/lib:${LD_LIBRARY_PATH:-}"
export OSG_LIBRARY_PATH="$ROOT/osgPlugins-3.6.5"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/runtime-root}"
export XDG_CONFIG_HOME="$CFG"
export XDG_DATA_HOME="$CFG"
export OPENMW_RESOURCES="$ROOT/resources"

mkdir -p "$XDG_RUNTIME_DIR"
chmod 0700 "$XDG_RUNTIME_DIR" 2>/dev/null || true

unset OPENMW_TSP_ENABLE_NAVIGATOR 2>/dev/null || true

rm -f "$STATUS" "$STATUS_TMP"
: > "$LOG"

{
    echo "============================================================"
    echo "OpenMW 0.51 COMPLETE Navmesh Generator"
    echo "Framebuffer progress UI"
    echo "============================================================"
    echo "Started:   $(date)"
    echo "Tool:      $TOOL"
    echo "Database:  $DB"
    echo "Workers:   $THREADS"
    echo "Interiors: true"
    echo "============================================================"
} >>"$LOG"

if pidof openmw-0.51 >/dev/null 2>&1 || pidof openmw >/dev/null 2>&1; then
    echo "ERROR: close Morrowind before generating navmesh." >>"$LOG"
    printf '22\n' >"$STATUS"
    exec "$UI" "$LOG" "$STATUS" "$DB" 2>>"$LOG"
fi

if pidof openmw-navmeshtool >/dev/null 2>&1; then
    echo "ERROR: openmw-navmeshtool is already running." >>"$LOG"
    echo "Use OpenMW_51_Attach_Navmesh_Progress.sh to view it." >>"$LOG"
    printf '23\n' >"$STATUS"
    exec "$UI" "$LOG" "$STATUS" "$DB" 2>>"$LOG"
fi

for f in "$TOOL" "$UI" "$RUNTIME/defaults.bin" "$RUNTIME/openmw.cfg" "$CFG/openmw.cfg"; do
    if [ ! -e "$f" ]; then
        echo "ERROR: missing required item: $f" >>"$LOG"
        printf '24\n' >"$STATUS"
        exec "$UI" "$LOG" "$STATUS" "$DB" 2>>"$LOG"
    fi
done

ARGS=(
    --resources "$ROOT/resources"
    --config "$CFG"
    --user-data "$NAVDIR"
    --threads "$THREADS"
    --process-interior-cells true
)

(
    set +e
    cd "$RUNTIME" || exit 90

    echo >>"$LOG"
    echo "NAVMESHTOOL STARTED: $(date)" >>"$LOG"

    "$TOOL" "${ARGS[@]}" >>"$LOG" 2>&1
    rc=$?

    echo >>"$LOG"
    echo "NAVMESHTOOL EXIT CODE: $rc" >>"$LOG"
    echo "NAVMESHTOOL FINISHED: $(date)" >>"$LOG"

    printf '%s\n' "$rc" >"$STATUS_TMP"
    mv -f "$STATUS_TMP" "$STATUS"
    sync

    exit "$rc"
) &

RUNNER_PID=$!

set +e
"$UI" "$LOG" "$STATUS" "$DB" 2>>"$LOG"
UI_RC=$?
wait "$RUNNER_PID"
NAV_RC=$?
set -e

if [ -s "$STATUS" ]; then
    read -r FINAL_RC <"$STATUS" || FINAL_RC="$NAV_RC"
else
    FINAL_RC="$NAV_RC"
fi

{
    echo
    echo "Framebuffer UI exit code: $UI_RC"
    echo "Navmeshtool exit code: $FINAL_RC"
    echo "Finished: $(date)"
} >>"$LOG"

exit "$FINAL_RC"
GENERATOR

chmod +x \
    "$PKG/OpenMW_51_Attach_Navmesh_Progress.sh" \
    "$PKG/OpenMW_51_Navmesh_UI_Demo.sh" \
    "$PKG/OpenMW_51_Generate_Full_Navmesh_3Worker.sh"

bash -n "$PKG/OpenMW_51_Attach_Navmesh_Progress.sh"
bash -n "$PKG/OpenMW_51_Navmesh_UI_Demo.sh"
bash -n "$PKG/OpenMW_51_Generate_Full_Navmesh_3Worker.sh"

echo
echo "===== 1/6 BUILD FRAMEBUFFER HELPER IN DOCKER ====="

docker inspect "$CTR" >/dev/null

if [ "$(docker inspect -f '{{.State.Running}}' "$CTR")" != "true" ]; then
    docker start "$CTR" >/dev/null
fi

docker cp "$PKG/navmesh_progress_fb.cpp" "$CTR:/tmp/navmesh_progress_fb.cpp"

docker exec "$CTR" bash -lc '
set -e
CXX=/usr/bin/g++-13
[ -x "$CXX" ] || CXX="$(command -v g++)"

"$CXX" \
    -std=c++17 \
    -O2 \
    -pipe \
    -Wall \
    -Wextra \
    /tmp/navmesh_progress_fb.cpp \
    -pthread \
    -o /tmp/openmw-navmesh-progress-fb

chmod +x /tmp/openmw-navmesh-progress-fb

echo "Compiler:"
"$CXX" --version | head -1

echo
echo "Binary:"
file /tmp/openmw-navmesh-progress-fb

echo
echo "Dependencies:"
readelf -d /tmp/openmw-navmesh-progress-fb |
grep -E "NEEDED|RPATH|RUNPATH" || true
' | tee "$PKG/build.log"

docker exec "$CTR" file /tmp/openmw-navmesh-progress-fb |
tee "$PKG/file.txt"

grep -Eqi 'ARM aarch64|aarch64' "$PKG/file.txt"

docker cp \
    "$CTR:/tmp/openmw-navmesh-progress-fb" \
    "$PKG/openmw-navmesh-progress"

chmod +x "$PKG/openmw-navmesh-progress"

HELPER_SHA="$(sha256sum "$PKG/openmw-navmesh-progress" | awk '{print $1}')"

echo
echo "New framebuffer helper SHA:"
echo "  $HELPER_SHA"

echo
echo "===== 2/6 DEVICE FRAMEBUFFER PREFLIGHT ====="

ssh "$DEV" '
set +e

echo "--- framebuffer devices ---"
ls -l /dev/fb0 /dev/graphics/fb0 2>/dev/null || true

echo
echo "--- sysfs ---"
for f in \
    /sys/class/graphics/fb0/name \
    /sys/class/graphics/fb0/virtual_size \
    /sys/class/graphics/fb0/bits_per_pixel \
    /sys/class/graphics/fb0/stride
do
    if [ -r "$f" ]; then
        printf "%s=" "$f"
        cat "$f"
    fi
done

echo
echo "--- running navmeshtool (left untouched) ---"
ps w 2>/dev/null | grep "[o]penmw-navmeshtool" || echo none
' | tee "$PKG/device-framebuffer-preflight.txt"

echo
echo "===== 3/6 INSTALL FRAMEBUFFER HELPER ====="

ssh "$DEV" "
set -e
mkdir -p '$ROOT/backups/navmesh-progress-$STAMP'

if [ -e '$PROGRESS' ]; then
    cp -p '$PROGRESS' '$ROOT/backups/navmesh-progress-$STAMP/openmw-navmesh-progress.sdl-before'
fi
"

scp -q \
    "$PKG/openmw-navmesh-progress" \
    "$DEV:$PROGRESS.new"

ssh "$DEV" "
set -e
chmod +x '$PROGRESS.new'

test \"\$(sha256sum '$PROGRESS.new' | awk '{print \$1}')\" = '$HELPER_SHA'

mv -f '$PROGRESS.new' '$PROGRESS'
sync

echo 'Installed framebuffer helper:'
ls -lh '$PROGRESS'
sha256sum '$PROGRESS'
"

echo
echo "===== 4/6 INSTALL ATTACH + DEMO PORTS ENTRIES ====="

scp -q \
    "$PKG/OpenMW_51_Attach_Navmesh_Progress.sh" \
    "$DEV:$ATTACH_LAUNCHER.new"

scp -q \
    "$PKG/OpenMW_51_Navmesh_UI_Demo.sh" \
    "$DEV:$DEMO_LAUNCHER.new"

ssh "$DEV" "
set -e
chmod +x '$ATTACH_LAUNCHER.new' '$DEMO_LAUNCHER.new'
bash -n '$ATTACH_LAUNCHER.new'
bash -n '$DEMO_LAUNCHER.new'
mv -f '$ATTACH_LAUNCHER.new' '$ATTACH_LAUNCHER'
mv -f '$DEMO_LAUNCHER.new' '$DEMO_LAUNCHER'
sync
"

echo
echo "===== 5/6 INSTALL CLEAN END-USER GENERATOR LAUNCHER ====="

scp -q \
    "$PKG/OpenMW_51_Generate_Full_Navmesh_3Worker.sh" \
    "$DEV:$GEN_LAUNCHER.new"

ssh "$DEV" "
set -e

if [ -e '$GEN_LAUNCHER' ]; then
    cp -p '$GEN_LAUNCHER' '$GEN_LAUNCHER.before-framebuffer-$STAMP'
fi

chmod +x '$GEN_LAUNCHER.new'
bash -n '$GEN_LAUNCHER.new'

grep -q 'Framebuffer progress UI' '$GEN_LAUNCHER.new'
grep -q 'NAVMESH_THREADS:-3' '$GEN_LAUNCHER.new'
grep -q '/mnt/UDISK/openmw51-nav' '$GEN_LAUNCHER.new'

mv -f '$GEN_LAUNCHER.new' '$GEN_LAUNCHER'
sync
"

echo
echo "===== 6/6 READY ====="

ssh "$DEV" "
echo 'Generator launcher:'
ls -lh '$GEN_LAUNCHER'

echo
echo 'Attach launcher:'
ls -lh '$ATTACH_LAUNCHER'

echo
echo 'Demo launcher:'
ls -lh '$DEMO_LAUNCHER'

echo
echo 'Current navmeshtool:'
ps w 2>/dev/null | grep '[o]penmw-navmeshtool' || echo none
"

echo
echo "=================================================================="
echo "INSTALL COMPLETE"
echo "=================================================================="
echo
echo "Nothing was started or stopped."
echo "navmesh.db was not modified by this installer."
echo
echo "TEST RIGHT NOW from the TrimUI Ports menu:"
echo
echo "  OpenMW_51_Attach_Navmesh_Progress.sh"
echo
echo "If the current navmeshtool is still running, this attaches the"
echo "new framebuffer display to the CURRENT run without starting another."
echo
echo "Or test the screen by itself:"
echo
echo "  OpenMW_51_Navmesh_UI_Demo.sh"
echo
echo "Permanent generator:"
echo
echo "  OpenMW_51_Generate_Full_Navmesh_3Worker.sh"
echo
echo "Artifacts/log:"
echo "  $PKG"
echo "=================================================================="
