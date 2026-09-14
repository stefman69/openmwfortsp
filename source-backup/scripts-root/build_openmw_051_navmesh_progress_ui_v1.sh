#!/bin/bash
set -Eeuo pipefail

# Build the tiny SDL2 progress-screen helper for OpenMW 0.51 navmeshtool.
# Intended for the existing ARM64 OpenMW/TSP Docker environment.
#
# Output:
#   /root/openmw-0.51-tsp-package/bin/openmw-navmesh-progress
#
# This does NOT rebuild OpenMW or navmeshtool.

SDL_PREFIX="${SDL_PREFIX:-/root/sdl2-2.30.12-install}"
PACKAGE_DIR="${PACKAGE_DIR:-/root/openmw-0.51-tsp-package}"
OUTPUT="$PACKAGE_DIR/bin/openmw-navmesh-progress"
SOURCE="/root/openmw_navmesh_progress_v1.cpp"

if [ -x /usr/bin/g++-13 ]; then
    CXX=/usr/bin/g++-13
elif command -v g++ >/dev/null 2>&1; then
    CXX="$(command -v g++)"
else
    echo "ERROR: no C++ compiler found."
    exit 1
fi

if [ ! -f "$SDL_PREFIX/include/SDL2/SDL.h" ]; then
    echo "ERROR: SDL2 headers not found:"
    echo "  $SDL_PREFIX/include/SDL2/SDL.h"
    exit 1
fi

if [ ! -d "$SDL_PREFIX/lib" ]; then
    echo "ERROR: SDL2 library directory not found:"
    echo "  $SDL_PREFIX/lib"
    exit 1
fi

mkdir -p "$PACKAGE_DIR/bin"

cat > "$SOURCE" <<'CPP_SOURCE'
#include <SDL.h>

#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
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

namespace
{
    using Clock = std::chrono::steady_clock;

    struct Sample
    {
        Clock::time_point time;
        std::uint64_t current = 0;
        std::uint64_t total = 0;
    };

    using Glyph = std::array<std::uint8_t, 7>;

    Glyph glyph(char c)
    {
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
            case '?': return {14,17,1,2,4,0,4};
            case ' ': return {0,0,0,0,0,0,0};
            default:  return {31,17,2,4,4,0,4};
        }
    }

    int textWidth(const std::string& text, int scale)
    {
        if (text.empty())
            return 0;
        return static_cast<int>(text.size()) * 6 * scale - scale;
    }

    void drawText(SDL_Renderer* renderer, const std::string& input, int x, int y, int scale, SDL_Color color)
    {
        SDL_SetRenderDrawColor(renderer, color.r, color.g, color.b, color.a);

        int cursor = x;
        for (char raw : input)
        {
            char c = raw;
            if (c >= 'a' && c <= 'z')
                c = static_cast<char>(c - 'a' + 'A');

            const Glyph g = glyph(c);
            for (int row = 0; row < 7; ++row)
            {
                for (int col = 0; col < 5; ++col)
                {
                    if ((g[row] & (1u << (4 - col))) == 0)
                        continue;

                    SDL_Rect pixel{
                        cursor + col * scale,
                        y + row * scale,
                        scale,
                        scale
                    };
                    SDL_RenderFillRect(renderer, &pixel);
                }
            }
            cursor += 6 * scale;
        }
    }

    void drawCentered(SDL_Renderer* renderer, const std::string& text, int width, int y, int scale, SDL_Color color)
    {
        drawText(renderer, text, std::max(0, (width - textWidth(text, scale)) / 2), y, scale, color);
    }

    std::string formatDuration(double seconds)
    {
        if (!std::isfinite(seconds) || seconds < 0)
            return "--:--:--";

        auto total = static_cast<std::uint64_t>(seconds + 0.5);
        const std::uint64_t hours = total / 3600;
        const std::uint64_t minutes = (total % 3600) / 60;
        const std::uint64_t secs = total % 60;

        std::ostringstream out;
        out << std::setfill('0') << std::setw(2) << hours
            << ":" << std::setw(2) << minutes
            << ":" << std::setw(2) << secs;
        return out.str();
    }

    std::string formatCount(std::uint64_t value)
    {
        std::string s = std::to_string(value);
        for (std::ptrdiff_t i = static_cast<std::ptrdiff_t>(s.size()) - 3; i > 0; i -= 3)
            s.insert(static_cast<std::size_t>(i), ",");
        return s;
    }

    std::string formatBytes(std::uintmax_t bytes)
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

    double calculateRate(const std::deque<Sample>& samples)
    {
        if (samples.size() < 2)
            return 0.0;

        const Sample& newest = samples.back();

        for (auto it = samples.begin(); it != samples.end(); ++it)
        {
            if (it->total != newest.total || newest.current < it->current)
                continue;

            const double seconds = std::chrono::duration<double>(newest.time - it->time).count();
            if (seconds >= 10.0)
                return static_cast<double>(newest.current - it->current) / seconds;
        }

        const Sample& oldest = samples.front();
        const double seconds = std::chrono::duration<double>(newest.time - oldest.time).count();
        if (seconds <= 0.0 || newest.current < oldest.current || newest.total != oldest.total)
            return 0.0;
        return static_cast<double>(newest.current - oldest.current) / seconds;
    }

    void pruneSamples(std::deque<Sample>& samples, Clock::time_point now)
    {
        while (samples.size() > 2
            && std::chrono::duration<double>(now - samples.front().time).count() > 120.0)
        {
            samples.pop_front();
        }
    }
}

int main(int argc, char** argv)
{
    if (argc < 4)
    {
        std::fprintf(stderr, "Usage: %s <log> <status-file> <navmesh.db>\n", argv[0]);
        return 2;
    }

    const std::filesystem::path logPath = argv[1];
    const std::filesystem::path statusPath = argv[2];
    const std::filesystem::path dbPath = argv[3];

    if (SDL_Init(SDL_INIT_VIDEO | SDL_INIT_TIMER | SDL_INIT_EVENTS) != 0)
    {
        std::fprintf(stderr, "SDL_Init failed: %s\n", SDL_GetError());
        return 3;
    }

    SDL_DisableScreenSaver();
    SDL_ShowCursor(SDL_DISABLE);

    SDL_Window* window = SDL_CreateWindow(
        "OpenMW Navmesh Cache",
        SDL_WINDOWPOS_CENTERED,
        SDL_WINDOWPOS_CENTERED,
        1280,
        720,
        SDL_WINDOW_FULLSCREEN_DESKTOP | SDL_WINDOW_ALLOW_HIGHDPI);

    if (!window)
    {
        window = SDL_CreateWindow(
            "OpenMW Navmesh Cache",
            SDL_WINDOWPOS_CENTERED,
            SDL_WINDOWPOS_CENTERED,
            1280,
            720,
            SDL_WINDOW_SHOWN);
    }

    if (!window)
    {
        std::fprintf(stderr, "SDL_CreateWindow failed: %s\n", SDL_GetError());
        SDL_Quit();
        return 4;
    }

    SDL_Renderer* renderer = SDL_CreateRenderer(
        window, -1, SDL_RENDERER_ACCELERATED | SDL_RENDERER_PRESENTVSYNC);

    if (!renderer)
        renderer = SDL_CreateRenderer(window, -1, SDL_RENDERER_SOFTWARE);

    if (!renderer)
    {
        std::fprintf(stderr, "SDL_CreateRenderer failed: %s\n", SDL_GetError());
        SDL_DestroyWindow(window);
        SDL_Quit();
        return 5;
    }

    SDL_SetRenderDrawBlendMode(renderer, SDL_BLENDMODE_BLEND);

    const SDL_Color bg{10, 11, 13, 255};
    const SDL_Color fg{236, 236, 236, 255};
    const SDL_Color dim{145, 148, 155, 255};
    const SDL_Color edge{95, 99, 108, 255};
    const SDL_Color fill{220, 220, 220, 255};
    const SDL_Color success{150, 230, 160, 255};
    const SDL_Color failure{245, 135, 135, 255};

    std::ifstream log;
    std::streamoff logOffset = 0;

    const std::regex progressRegex(
        R"((\d+)\/(\d+)\s+\(([0-9]+(?:\.[0-9]+)?)%\)\s+navmesh tiles are generated)",
        std::regex::icase);

    const std::regex worldspaceRegex(
        R"(Generating navmesh tiles for (.+) worldspace)",
        std::regex::icase);

    std::uint64_t current = 0;
    std::uint64_t total = 0;
    bool haveProgress = false;
    std::string phase = "PREPARING NAVIGATION DATA";
    std::deque<Sample> samples;

    const Clock::time_point started = Clock::now();
    std::optional<Clock::time_point> completedAt;
    std::optional<int> finalStatus;

    bool running = true;
    while (running)
    {
        SDL_Event event;
        while (SDL_PollEvent(&event))
        {
            // Deliberately do not allow accidental cancellation during generation.
            // Once complete, any key/button dismisses the result immediately.
            if (completedAt
                && (event.type == SDL_KEYDOWN
                    || event.type == SDL_CONTROLLERBUTTONDOWN
                    || event.type == SDL_QUIT))
            {
                running = false;
            }
        }

        if (!log.is_open())
        {
            log.open(logPath);
            if (log)
                log.seekg(logOffset);
        }

        if (log)
        {
            log.clear();
            log.seekg(logOffset);

            std::string line;
            while (std::getline(log, line))
            {
                std::smatch match;

                if (std::regex_search(line, match, worldspaceRegex))
                {
                    phase = "GENERATING NAVIGATION DATA";
                }

                if (std::regex_search(line, match, progressRegex))
                {
                    const std::uint64_t newCurrent = std::stoull(match[1].str());
                    const std::uint64_t newTotal = std::stoull(match[2].str());

                    if (!haveProgress || newTotal != total || newCurrent < current)
                        samples.clear();

                    current = newCurrent;
                    total = newTotal;
                    haveProgress = total > 0;

                    const auto now = Clock::now();
                    if (samples.empty() || samples.back().current != current || samples.back().total != total)
                        samples.push_back(Sample{now, current, total});
                    pruneSamples(samples, now);
                }
            }

            const auto pos = log.tellg();
            if (pos >= 0)
                logOffset = pos;
            else
            {
                log.clear();
                log.seekg(0, std::ios::end);
                const auto end = log.tellg();
                if (end >= 0)
                    logOffset = end;
            }
        }

        if (!finalStatus)
        {
            finalStatus = readStatus(statusPath);
            if (finalStatus)
            {
                completedAt = Clock::now();
                phase = (*finalStatus == 0)
                    ? "NAVMESH CACHE COMPLETE"
                    : "NAVMESH GENERATION FAILED";
            }
        }

        int width = 1280;
        int height = 720;
        SDL_GetRendererOutputSize(renderer, &width, &height);

        const double ui = std::max(0.70, std::min(1.60, static_cast<double>(height) / 720.0));
        const auto sy = [ui](int v) { return static_cast<int>(std::lround(v * ui)); };

        const auto now = Clock::now();
        const double elapsed = std::chrono::duration<double>(now - started).count();
        const double rate = calculateRate(samples);

        double pct = 0.0;
        if (haveProgress && total > 0)
            pct = std::clamp(static_cast<double>(current) / static_cast<double>(total), 0.0, 1.0);

        double etaSeconds = -1.0;
        if (haveProgress && total >= current && rate > 0.001)
            etaSeconds = static_cast<double>(total - current) / rate;

        std::uintmax_t dbSize = 0;
        std::error_code ec;
        if (std::filesystem::exists(dbPath, ec))
            dbSize = std::filesystem::file_size(dbPath, ec);

        SDL_SetRenderDrawColor(renderer, bg.r, bg.g, bg.b, bg.a);
        SDL_RenderClear(renderer);

        drawCentered(renderer, "OPENMW NAVMESH CACHE", width, sy(60), sy(5), fg);
        drawCentered(renderer, phase, width, sy(135), sy(3),
            finalStatus ? ((*finalStatus == 0) ? success : failure) : dim);

        const int margin = std::max(sy(90), width / 12);
        const int barX = margin;
        const int barY = sy(225);
        const int barW = width - margin * 2;
        const int barH = sy(54);

        SDL_SetRenderDrawColor(renderer, edge.r, edge.g, edge.b, edge.a);
        SDL_Rect outer{barX, barY, barW, barH};
        SDL_RenderDrawRect(renderer, &outer);

        SDL_Rect inner{
            barX + sy(4),
            barY + sy(4),
            std::max(0, barW - sy(8)),
            std::max(0, barH - sy(8))
        };

        SDL_SetRenderDrawColor(renderer, 29, 31, 35, 255);
        SDL_RenderFillRect(renderer, &inner);

        if (haveProgress)
        {
            SDL_Rect done = inner;
            done.w = static_cast<int>(std::lround(static_cast<double>(inner.w) * pct));
            SDL_SetRenderDrawColor(renderer, fill.r, fill.g, fill.b, fill.a);
            SDL_RenderFillRect(renderer, &done);
        }
        else
        {
            const double pulse = (std::sin(elapsed * 2.3) + 1.0) * 0.5;
            SDL_Rect pulseRect = inner;
            pulseRect.w = std::max(sy(50), inner.w / 7);
            pulseRect.x += static_cast<int>(std::lround(
                pulse * static_cast<double>(std::max(0, inner.w - pulseRect.w))));
            SDL_SetRenderDrawColor(renderer, edge.r, edge.g, edge.b, 255);
            SDL_RenderFillRect(renderer, &pulseRect);
        }

        if (haveProgress)
        {
            std::ostringstream percentText;
            percentText << std::fixed << std::setprecision(1) << (pct * 100.0) << "%";
            drawCentered(renderer, percentText.str(), width, sy(310), sy(6), fg);

            const std::string countText =
                formatCount(current) + " / " + formatCount(total) + " TILES";
            drawCentered(renderer, countText, width, sy(380), sy(3), fg);
        }
        else
        {
            drawCentered(renderer, "SCANNING CONTENT AND BUILDING TILE LIST", width, sy(330), sy(3), fg);
        }

        std::ostringstream rateText;
        if (rate > 0.001)
            rateText << std::fixed << std::setprecision(1) << rate << " TILES/SEC";
        else
            rateText << "-- TILES/SEC";

        drawText(renderer, "RATE", margin, sy(465), sy(3), dim);
        drawText(renderer, rateText.str(), margin + sy(145), sy(465), sy(3), fg);

        drawText(renderer, "ELAPSED", margin, sy(515), sy(3), dim);
        drawText(renderer, formatDuration(elapsed), margin + sy(145), sy(515), sy(3), fg);

        drawText(renderer, "ETA", margin, sy(565), sy(3), dim);
        drawText(renderer, formatDuration(etaSeconds), margin + sy(145), sy(565), sy(3), fg);

        drawText(renderer, "DATABASE", width / 2, sy(465), sy(3), dim);
        drawText(renderer, dbSize > 0 ? formatBytes(dbSize) : "--",
            width / 2 + sy(190), sy(465), sy(3), fg);

        if (!finalStatus)
        {
            drawCentered(renderer, "PLEASE DO NOT POWER OFF", width, sy(640), sy(2), dim);

            // Small moving marker: a visual heartbeat even if a progress log line
            // has not been emitted recently.
            const int trackW = width - margin * 2;
            const double travel = std::fmod(elapsed * 90.0, std::max(1, trackW - sy(18)));
            SDL_Rect marker{margin + static_cast<int>(travel), sy(680), sy(18), sy(5)};
            SDL_SetRenderDrawColor(renderer, dim.r, dim.g, dim.b, 200);
            SDL_RenderFillRect(renderer, &marker);
        }
        else
        {
            const double sinceDone = std::chrono::duration<double>(now - *completedAt).count();
            const int remaining = std::max(0, 8 - static_cast<int>(sinceDone));
            drawCentered(renderer, "RETURNING TO PORTS IN " + std::to_string(remaining), width, sy(640), sy(2), dim);

            if (sinceDone >= 8.0)
                running = false;
        }

        SDL_RenderPresent(renderer);
        std::this_thread::sleep_for(std::chrono::milliseconds(100));
    }

    SDL_ShowCursor(SDL_ENABLE);
    SDL_EnableScreenSaver();
    SDL_DestroyRenderer(renderer);
    SDL_DestroyWindow(window);
    SDL_Quit();

    if (finalStatus)
        return *finalStatus;
    return 0;
}

CPP_SOURCE

echo "Compiler:"
"$CXX" --version | head -1
echo
echo "SDL2 prefix:"
echo "  $SDL_PREFIX"
echo
echo "Building:"
echo "  $OUTPUT"
echo

"$CXX"     -std=c++17     -O2     -pipe     -Wall     -Wextra     -I"$SDL_PREFIX/include/SDL2"     -D_REENTRANT     "$SOURCE"     -L"$SDL_PREFIX/lib"     -Wl,-rpath,'$ORIGIN/../lib'     -Wl,--enable-new-dtags     -lSDL2     -pthread     -o "$OUTPUT"

chmod +x "$OUTPUT"

if command -v aarch64-linux-gnu-strip >/dev/null 2>&1; then
    aarch64-linux-gnu-strip --strip-unneeded "$OUTPUT"
elif command -v strip >/dev/null 2>&1; then
    strip --strip-unneeded "$OUTPUT" || true
fi

echo
echo "Binary:"
file "$OUTPUT"

echo
echo "Dynamic dependencies:"
readelf -d "$OUTPUT" | grep -E 'NEEDED|RPATH|RUNPATH' || true

if ! file "$OUTPUT" | grep -qi 'ARM aarch64'; then
    echo
    echo "WARNING: output was not identified as ARM aarch64."
    echo "Do not deploy it to the TSP until the architecture is checked."
fi

echo
echo "SUCCESS:"
echo "  $OUTPUT"
