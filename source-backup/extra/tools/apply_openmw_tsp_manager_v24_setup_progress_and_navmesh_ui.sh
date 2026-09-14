#!/usr/bin/env bash
# ============================================================================
# OpenMW 0.51 / TrimUI Smart Pro — Manager V2.4 controller
#
# One command: emit sources -> host self-tests -> ARM64 build in Docker ->
# device backup -> transactional install -> device self-tests -> log pull.
#
# What V2.4 changes
#   1. SETUP GAME FOR FIRST LAUNCH installs the base navmesh and the UDISK
#      swap file only. It no longer validates or rewrites the mod profile, so
#      it can no longer stop on a TSP Atlas / Project Atlas file-count check.
#      Mod data roots and load order come from openmw.cfg and are untouched.
#   2. Long actions run as a child of the manager UI while its SDL window
#      stays alive, so setup shows a live progress bar (real copied bytes for
#      the navmesh and swap copies) instead of a black screen.
#   3. Every action ends on a COMPLETE / FAILED page that must be dismissed,
#      so a failure can never look like "nothing happened".
#   4. The startup device scan also runs behind the progress overlay instead
#      of before the UI exists.
#   5. NAVMESH BUILDER hands the screen to the standalone
#      OpenMW_Generate_Full_Navmesh_3Worker.sh with the exact environment the
#      Ports front-end gives it, so the generator's own progress window appears
#      exactly as it does when launched from Ports. The generator is found by
#      existence, not by an execute bit, and its outcome is reported back to
#      the manager UI and acknowledged on screen.
#
# Actions: install (default) | selftest | emit | collect | rollback
#
# Unchanged: openmw-launcher-backend-v2.py, Morrowind.sh, the clean-path
# migrator, saves, mods, openmw.cfg, navmesh, swap. The generator script is
# installed byte-for-byte from the copy supplied by the user.
# ============================================================================

set -u -o pipefail

ACTION="${1:-install}"
CTR="${OPENMW_CONTAINER:-openmw_builder}"
DEV="${OPENMW_DEVICE:-root@192.168.1.12}"
ROOT="${OPENMW_GAMEDIR:-/mnt/SDCARD/data/ports/openmw}"
NAVDIR="${OPENMW_NAVMESH_DIR:-/mnt/UDISK/openmw-nav}"
HOST_DIR="${OPENMW_DOWNLOADS_DIR:-$HOME/Downloads}"
WORK="$HOST_DIR/openmw-tsp-manager-v2.4"
CPP="$WORK/openmw_launcher_manager.cpp"
ACTION_SH="$WORK/openmw_manager_action.sh"
WRAPPER_SH="$WORK/OpenMW_Manager.sh"
GENERATOR_SH="$WORK/OpenMW_Generate_Full_Navmesh_3Worker.sh"
GENERATOR_EXPECTED_SHA="8656eeb9df365c4025a49869b373924f74c393133e553c8f31f2fb2cbabdd24e"
HOST_BIN="$WORK/openmw-manager-v2"
STAMP="$(date +%Y%m%d-%H%M%S)"
BUILD_LOG="$WORK/openmw-manager-v24-build-$STAMP.log"
STATE="$HOST_DIR/openmw-manager-v24-install.state"

[ -d "$HOST_DIR" ] || { echo "ERROR: host output directory missing: $HOST_DIR" >&2; exit 9; }
mkdir -p "$WORK" || exit 9
TMP="$(mktemp -d "$WORK/.stage.XXXXXX")" || exit 9
cleanup() { [ -n "${TMP:-}" ] && [ -d "$TMP" ] && rm -rf "$TMP"; }
trap cleanup EXIT

fail() { local rc="${1:-1}"; shift || true; echo "ERROR: $*" >&2; exit "$rc"; }
need() { command -v "$1" >/dev/null 2>&1 || fail 10 "required command missing: $1"; echo "PASS command: $1"; }
valid_sha() { case "$1" in ''|*[!0-9a-f]*) return 1;; esac; [ "${#1}" -eq 64 ]; }
sha_of() { sha256sum "$1" | awk '{print $1}'; }
state_value() { sed -n "s/^$2='\([^']*\)'\$/\1/p" "$1" | tail -n 1; }
ensure_ssh() {
    need ssh; need scp
    ssh -o BatchMode=yes -o ConnectTimeout=8 "$DEV" true >/dev/null 2>&1 || fail 11 "SSH failed: $DEV"
    echo "PASS SSH: $DEV"
}

# ============================================================================
# 0. EMIT EXACT SOURCES
# ============================================================================
emit_sources() {
    cat > "$CPP" <<'OPENMW_V24_MANAGER_CPP_EOF'
// OpenMW 0.51 TrimUI Smart Pro Manager V2.4
// V2.4 change: long backend actions run as a child of this UI process while the
// SDL window stays alive, so setup shows a live progress overlay instead of a
// black screen. First-launch setup is storage only (navmesh + swap).
#include <algorithm>
#include <array>
#include <cerrno>
#include <chrono>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <dlfcn.h>
#include <filesystem>
#include <fstream>
#include <functional>
#include <iostream>
#include <linux/input.h>
#include <map>
#include <poll.h>
#include <sstream>
#include <string>
#include <sys/wait.h>
#include <unistd.h>
#include <fcntl.h>
#include <vector>

namespace fs = std::filesystem;
struct Color { uint8_t r, g, b; };

static std::array<uint8_t, 7> glyph(char c)
{
    if (c >= 'a' && c <= 'z') c = char(c - 'a' + 'A');
    switch (c)
    {
        case 'A': return {14,17,17,31,17,17,17}; case 'B': return {30,17,17,30,17,17,30};
        case 'C': return {14,17,16,16,16,17,14}; case 'D': return {30,17,17,17,17,17,30};
        case 'E': return {31,16,16,30,16,16,31}; case 'F': return {31,16,16,30,16,16,16};
        case 'G': return {14,17,16,23,17,17,15}; case 'H': return {17,17,17,31,17,17,17};
        case 'I': return {14,4,4,4,4,4,14}; case 'J': return {7,2,2,2,18,18,12};
        case 'K': return {17,18,20,24,20,18,17}; case 'L': return {16,16,16,16,16,16,31};
        case 'M': return {17,27,21,21,17,17,17}; case 'N': return {17,25,21,19,17,17,17};
        case 'O': return {14,17,17,17,17,17,14}; case 'P': return {30,17,17,30,16,16,16};
        case 'Q': return {14,17,17,17,21,18,13}; case 'R': return {30,17,17,30,20,18,17};
        case 'S': return {15,16,16,14,1,1,30}; case 'T': return {31,4,4,4,4,4,4};
        case 'U': return {17,17,17,17,17,17,14}; case 'V': return {17,17,17,17,17,10,4};
        case 'W': return {17,17,17,21,21,21,10}; case 'X': return {17,17,10,4,10,17,17};
        case 'Y': return {17,17,10,4,4,4,4}; case 'Z': return {31,1,2,4,8,16,31};
        case '0': return {14,17,19,21,25,17,14}; case '1': return {4,12,4,4,4,4,14};
        case '2': return {14,17,1,2,4,8,31}; case '3': return {30,1,1,14,1,1,30};
        case '4': return {2,6,10,18,31,2,2}; case '5': return {31,16,16,30,1,1,30};
        case '6': return {14,16,16,30,17,17,14}; case '7': return {31,1,2,4,8,8,8};
        case '8': return {14,17,17,14,17,17,14}; case '9': return {14,17,17,15,1,1,14};
        case ':': return {0,4,4,0,4,4,0}; case '.': return {0,0,0,0,0,6,6};
        case '/': return {1,1,2,4,8,16,16}; case '%': return {17,2,4,8,16,17,0};
        case '-': return {0,0,0,31,0,0,0}; case '+': return {0,4,4,31,4,4,0};
        case '_': return {0,0,0,0,0,0,31}; case '(': return {2,4,8,8,8,4,2};
        case ')': return {8,4,2,2,2,4,8}; case '[': return {14,8,8,8,8,8,14};
        case ']': return {14,2,2,2,2,2,14}; case ',': return {0,0,0,0,6,4,8};
        case '=': return {0,31,0,31,0,0,0}; case '?': return {14,17,1,2,4,0,4};
        case '!': return {4,4,4,4,4,0,4}; case '<': return {2,4,8,16,8,4,2};
        case '>': return {8,4,2,1,2,4,2}; case '#': return {10,31,10,10,31,10,0};
        case '*': return {0,17,10,31,10,17,0}; case '|': return {4,4,4,4,4,4,4};
        case ' ': return {0,0,0,0,0,0,0}; default: return {31,17,2,4,4,0,4};
    }
}

class Framebuffer
{
public:
    explicit Framebuffer(const std::string&)
    {
        std::cerr << "Manager display milestone: loading SDL2\n";
        const char* overridePath = std::getenv("OPENMW51_MANAGER_SDL2");
        std::vector<std::string> libraries;
        if (overridePath && *overridePath) libraries.emplace_back(overridePath);
        libraries.insert(libraries.end(), {
            "libSDL2-2.0.so.0", "libSDL2.so.0", "libSDL2.so"});
        for (const auto& library : libraries)
        {
            mLibrary = dlopen(library.c_str(), RTLD_NOW | RTLD_LOCAL);
            if (mLibrary) { mLibraryName = library; break; }
        }
        if (!mLibrary)
        {
            const char* error=dlerror();
            throw std::runtime_error(std::string("SDL2 load failed: ")+(error&&*error?error:"library not found"));
        }
        std::cerr << "Manager display milestone: SDL2 loaded from " << mLibraryName << "\n";

        try
        {
            mInit = symbol<InitFn>("SDL_Init");
            mQuit = symbol<QuitFn>("SDL_Quit");
            mGetError = symbol<GetErrorFn>("SDL_GetError");
            mGetDriver = symbol<GetDriverFn>("SDL_GetCurrentVideoDriver");
            mSetHint = symbol<SetHintFn>("SDL_SetHint");
            mCreateWindow = symbol<CreateWindowFn>("SDL_CreateWindow");
            mDestroyWindow = symbol<DestroyWindowFn>("SDL_DestroyWindow");
            mCreateRenderer = symbol<CreateRendererFn>("SDL_CreateRenderer");
            mDestroyRenderer = symbol<DestroyRendererFn>("SDL_DestroyRenderer");
            mLogicalSize = symbol<LogicalSizeFn>("SDL_RenderSetLogicalSize");
            mCreateTexture = symbol<CreateTextureFn>("SDL_CreateTexture");
            mDestroyTexture = symbol<DestroyTextureFn>("SDL_DestroyTexture");
            mUpdateTexture = symbol<UpdateTextureFn>("SDL_UpdateTexture");
            mRenderClear = symbol<RenderClearFn>("SDL_RenderClear");
            mRenderCopy = symbol<RenderCopyFn>("SDL_RenderCopy");
            mRenderPresent = symbol<RenderPresentFn>("SDL_RenderPresent");

            mSetHint("SDL_RENDER_DRIVER", "software");
            mSetHint("SDL_RENDER_SCALE_QUALITY", "0");
            std::cerr << "Manager display milestone: SDL_Init starting\n";
            if (mInit(0x00004021u) != 0) fail("SDL_Init"); // VIDEO | TIMER | EVENTS
            mInitialized = true;
            std::cerr << "Manager display milestone: SDL_Init complete\n";
            constexpr int centered = 0x2fff0000;
            constexpr uint32_t fullscreenDesktopHighDpi = 0x00003001u;
            mWindow = mCreateWindow("OpenMW 0.51 Manager", centered, centered, width(), height(), fullscreenDesktopHighDpi);
            if (!mWindow) mWindow = mCreateWindow("OpenMW 0.51 Manager", centered, centered, width(), height(), 0x00000004u);
            if (!mWindow) fail("SDL_CreateWindow");
            std::cerr << "Manager display milestone: SDL window complete\n";
            mRenderer = mCreateRenderer(mWindow, -1, 0x00000001u); // SOFTWARE: do not load GL4ES
            if (!mRenderer) fail("SDL_CreateRenderer");
            std::cerr << "Manager display milestone: software renderer complete\n";
            if (mLogicalSize(mRenderer, width(), height()) != 0) fail("SDL_RenderSetLogicalSize");
            constexpr uint32_t argb8888 = 0x16362004u;
            mTexture = mCreateTexture(mRenderer, argb8888, 1, width(), height()); // SDL_TEXTUREACCESS_STREAMING
            if (!mTexture) fail("SDL_CreateTexture");
            mPixels.assign(size_t(width()) * size_t(height()), 0xff000000u);
            std::cerr << "Manager display: SDL2=" << mLibraryName
                      << " driver=" << (mGetDriver() ? mGetDriver() : "unknown")
                      << " logical=" << width() << "x" << height() << "\n";
        }
        catch (...)
        {
            cleanup();
            throw;
        }
    }
    ~Framebuffer() { cleanup(); }
    int width() const { return 1280; }
    int height() const { return 720; }
    void pixel(int x, int y, Color c)
    {
        if (x<0 || y<0 || x>=width() || y>=height()) return;
        mPixels[size_t(y)*size_t(width())+size_t(x)] = 0xff000000u | (uint32_t(c.r)<<16u) | (uint32_t(c.g)<<8u) | uint32_t(c.b);
    }
    void rect(int x,int y,int w,int h,Color c)
    {
        int x0=std::max(0,x), y0=std::max(0,y), x1=std::min(width(),x+w), y1=std::min(height(),y+h);
        for(int yy=y0;yy<y1;++yy) for(int xx=x0;xx<x1;++xx) pixel(xx,yy,c);
    }
    void clear(Color c) { rect(0,0,width(),height(),c); }
    void present()
    {
        if (mUpdateTexture(mTexture, nullptr, mPixels.data(), width()*int(sizeof(uint32_t))) != 0) fail("SDL_UpdateTexture");
        if (mRenderClear(mRenderer) != 0) fail("SDL_RenderClear");
        if (mRenderCopy(mRenderer, mTexture, nullptr, nullptr) != 0) fail("SDL_RenderCopy");
        mRenderPresent(mRenderer);
    }
private:
    struct Window;
    struct Renderer;
    struct Texture;
    using InitFn=int(*)(uint32_t); using QuitFn=void(*)(); using GetErrorFn=const char*(*)();
    using GetDriverFn=const char*(*)(); using SetHintFn=int(*)(const char*,const char*);
    using CreateWindowFn=Window*(*)(const char*,int,int,int,int,uint32_t); using DestroyWindowFn=void(*)(Window*);
    using CreateRendererFn=Renderer*(*)(Window*,int,uint32_t); using DestroyRendererFn=void(*)(Renderer*);
    using LogicalSizeFn=int(*)(Renderer*,int,int); using CreateTextureFn=Texture*(*)(Renderer*,uint32_t,int,int,int);
    using DestroyTextureFn=void(*)(Texture*); using UpdateTextureFn=int(*)(Texture*,const void*,const void*,int);
    using RenderClearFn=int(*)(Renderer*); using RenderCopyFn=int(*)(Renderer*,Texture*,const void*,const void*);
    using RenderPresentFn=void(*)(Renderer*);

    template<class T> T symbol(const char* name)
    {
        dlerror(); void* raw=dlsym(mLibrary,name); const char* error=dlerror();
        if (error || !raw) throw std::runtime_error(std::string("missing SDL2 symbol ")+name);
        T out{}; static_assert(sizeof(out)==sizeof(raw),"function pointer size mismatch"); std::memcpy(&out,&raw,sizeof(out)); return out;
    }
    [[noreturn]] void fail(const char* operation) const
    {
        const char* error=mGetError?mGetError():nullptr;
        throw std::runtime_error(std::string(operation)+" failed: "+(error&&*error?error:"unknown SDL2 error"));
    }
    void cleanup()
    {
        if(mTexture&&mDestroyTexture)mDestroyTexture(mTexture);
        mTexture=nullptr;
        if(mRenderer&&mDestroyRenderer)mDestroyRenderer(mRenderer);
        mRenderer=nullptr;
        if(mWindow&&mDestroyWindow)mDestroyWindow(mWindow);
        mWindow=nullptr;
        if(mInitialized&&mQuit)mQuit();
        mInitialized=false;
        if(mLibrary)dlclose(mLibrary);
        mLibrary=nullptr;
    }
    void* mLibrary=nullptr; std::string mLibraryName; bool mInitialized=false;
    Window* mWindow=nullptr; Renderer* mRenderer=nullptr; Texture* mTexture=nullptr; std::vector<uint32_t> mPixels;
    InitFn mInit=nullptr; QuitFn mQuit=nullptr; GetErrorFn mGetError=nullptr; GetDriverFn mGetDriver=nullptr; SetHintFn mSetHint=nullptr;
    CreateWindowFn mCreateWindow=nullptr; DestroyWindowFn mDestroyWindow=nullptr; CreateRendererFn mCreateRenderer=nullptr; DestroyRendererFn mDestroyRenderer=nullptr;
    LogicalSizeFn mLogicalSize=nullptr; CreateTextureFn mCreateTexture=nullptr; DestroyTextureFn mDestroyTexture=nullptr; UpdateTextureFn mUpdateTexture=nullptr;
    RenderClearFn mRenderClear=nullptr; RenderCopyFn mRenderCopy=nullptr; RenderPresentFn mRenderPresent=nullptr;
};

static void drawText(Framebuffer& f,const std::string& s,int x,int y,int z,Color c)
{
    int cx=x;
    for(char ch:s){auto g=glyph(ch);for(int r=0;r<7;++r)for(int q=0;q<5;++q)if(g[r]&(1u<<(4-q)))f.rect(cx+q*z,y+r*z,z,z,c);cx+=6*z;}
}
static std::string fit(std::string s,size_t n){if(s.size()<=n)return s;if(n<4)return s.substr(0,n);return s.substr(0,n-3)+"...";}
static uint64_t number(const std::string& s){try{return std::stoull(s);}catch(...){return 0;}}
static std::string human(uint64_t n){static const char*u[]={"B","KB","MB","GB","TB"};double v=n;int i=0;while(v>=1024&&i<4){v/=1024;++i;}std::ostringstream o;o.setf(std::ios::fixed);o.precision(i>=3?1:0);o<<v<<" "<<u[i];return o.str();}

// TSP_MANAGER_V24_WRAP: split a long single-line message into fixed-width rows.
static std::vector<std::string> wrapText(const std::string& text,size_t width,size_t rows)
{
    std::vector<std::string> out; std::string line; std::istringstream in(text); std::string word;
    while(in>>word)
    {
        if(word.size()>width) word=word.substr(0,width);
        if(line.empty()) line=word;
        else if(line.size()+1+word.size()<=width) line+=" "+word;
        else { out.push_back(line); line=word; if(out.size()==rows) break; }
    }
    if(out.size()<rows&&!line.empty()) out.push_back(line);
    if(out.empty()) out.push_back("");
    return out;
}

static std::map<std::string,std::string> readKv(const fs::path& p)
{
    std::map<std::string,std::string> out; std::ifstream in(p); std::string line;
    while(std::getline(in,line)){auto e=line.find('=');if(e==std::string::npos)continue;out[line.substr(0,e)]=line.substr(e+1);}
    return out;
}

// TSP_MANAGER_V24_PROGRESS: shared progress contract with the action backend.
struct Progress { int pct=-1; std::string phase,detail; int step=0,steps=0; };

static fs::path progressPath()
{
    if(const char* e=getenv("OPENMW_MANAGER_PROGRESS")) if(*e) return fs::path(e);
    return fs::path("/tmp/openmw-manager-progress");
}

static Progress readProgress(const fs::path& file)
{
    Progress out; auto kv=readKv(file);
    auto find=[&kv](const char* key)->std::string{auto i=kv.find(key);return i==kv.end()?std::string():i->second;};
    out.phase=find("phase"); out.detail=find("detail");
    std::string pct=find("pct");
    if(!pct.empty()){try{int v=std::stoi(pct);out.pct=v<0?-1:(v>100?100:v);}catch(...){out.pct=-1;}}
    std::string step=find("step"),steps=find("steps");
    if(!step.empty()){try{out.step=std::stoi(step);}catch(...){out.step=0;}}
    if(!steps.empty()){try{out.steps=std::stoi(steps);}catch(...){out.steps=0;}}
    return out;
}

// TSP_MANAGER_V24_PENDING_REPORT: an outcome produced while the UI was not
// running (the navmesh generator owns the screen) is handed back through this
// file so it is still acknowledged on screen instead of vanishing.
struct Report { std::string heading="ACTION"; bool ok=false; int code=0; };

static bool takePendingReport(const fs::path& file,Report& out)
{
    std::error_code ec;
    if(!fs::exists(file,ec)) return false;
    auto kv=readKv(file);
    fs::remove(file,ec);
    if(kv.empty()) return false;
    auto heading=kv.find("heading");
    if(heading!=kv.end()&&!heading->second.empty()) out.heading=heading->second;
    auto ok=kv.find("ok");
    out.ok=(ok!=kv.end()&&ok->second=="1");
    auto code=kv.find("code");
    if(code!=kv.end()){try{out.code=std::stoi(code->second);}catch(...){out.code=0;}}
    return true;
}

// TSP_MANAGER_V24_CHILD: run the action backend as a child while this process
// keeps its SDL window. Returns the child's exit status, or -1 on spawn failure.
static int runActionCore(const fs::path& script,const std::vector<std::string>& args,
                         const fs::path& progressFile,
                         const std::function<void(const Progress&,int)>& tick)
{
    std::error_code ec; fs::remove(progressFile,ec);
    pid_t pid=fork();
    if(pid<0) return -1;
    if(pid==0)
    {
        // Never hand the SDL/DRM or evdev descriptors of the UI to a child.
        for(int fd=3;fd<64;++fd) close(fd);
        std::string shell="bash",path=script.string();
        std::vector<char*> argv;
        argv.push_back(const_cast<char*>(shell.c_str()));
        argv.push_back(const_cast<char*>(path.c_str()));
        for(const auto& value:args) argv.push_back(const_cast<char*>(value.c_str()));
        argv.push_back(nullptr);
        execv("/bin/bash",argv.data());
        _exit(127);
    }
    int state=0,frame=0;
    while(true)
    {
        pid_t done=waitpid(pid,&state,WNOHANG);
        if(done==pid) break;
        if(done<0&&errno!=EINTR) return -1;
        tick(readProgress(progressFile),frame);
        ++frame;
        usleep(120000);
    }
    if(WIFEXITED(state)) return WEXITSTATUS(state);
    if(WIFSIGNALED(state)) return 128+WTERMSIG(state);
    return -1;
}

struct Mod { std::string id,name,path; bool enabled=false,risky=false; };
static std::vector<Mod> readMods(const fs::path& p)
{
    std::vector<Mod> out; std::ifstream in(p); std::string line;
    while(std::getline(in,line))
    {
        if(line.empty()||line[0]=='#')continue;
        std::vector<std::string> c; size_t b=0;
        while(true){auto e=line.find('\t',b);c.push_back(line.substr(b,e==std::string::npos?e:e-b));if(e==std::string::npos)break;b=e+1;}
        if(c.size()>=5)out.push_back({c[0],c[3],c[4],c[1]=="1",c[2]=="1"});
    }
    return out;
}

static void writeAtomic(const fs::path& p,const std::string& value)
{
    std::error_code ec; fs::create_directories(p.parent_path(),ec); fs::path t=p; t += ".tmp";
    {std::ofstream o(t,std::ios::trunc);if(!o)throw std::runtime_error("cannot write request");o<<value<<"\n";o.flush();if(!o)throw std::runtime_error("request write failed");}
    fs::rename(t,p,ec); if(ec)throw std::runtime_error("request publish failed");
}

enum class Action { None,Up,Down,Left,Right,Select,Back,Apply,Refresh,Quit };
class Inputs
{
public:
    Inputs(){for(int i=0;i<32;++i){std::string p="/dev/input/event"+std::to_string(i);int fd=open(p.c_str(),O_RDONLY|O_NONBLOCK);if(fd>=0){mFds.push_back(fd);pollfd q{};q.fd=fd;q.events=POLLIN;mPoll.push_back(q);}}}
    ~Inputs(){for(int f:mFds)close(f);}
    Action wait(int ms)
    {
        if(mPoll.empty()){usleep(ms*1000);return Action::None;} if(::poll(mPoll.data(),mPoll.size(),ms)<=0)return Action::None;
        for(auto&q:mPoll)if(q.revents&POLLIN){input_event e{};while(read(q.fd,&e,sizeof(e))==sizeof(e)){
            if(e.type==EV_KEY&&e.value==1){switch(e.code){
                case KEY_UP:case BTN_DPAD_UP:return Action::Up; case KEY_DOWN:case BTN_DPAD_DOWN:return Action::Down;
                case KEY_LEFT:case BTN_DPAD_LEFT:return Action::Left; case KEY_RIGHT:case BTN_DPAD_RIGHT:return Action::Right;
                case BTN_EAST:case KEY_ENTER:return Action::Select; case BTN_SOUTH:case KEY_ESC:case BTN_SELECT:return Action::Back;
                case BTN_START:case BTN_NORTH:return Action::Apply; case BTN_WEST:return Action::Refresh; case BTN_MODE:return Action::Quit; default:break;}
            }else if(e.type==EV_ABS){if(e.code==ABS_HAT0X){if(e.value<0&&mHx>=0){mHx=e.value;return Action::Left;}if(e.value>0&&mHx<=0){mHx=e.value;return Action::Right;}mHx=e.value;}if(e.code==ABS_HAT0Y){if(e.value<0&&mHy>=0){mHy=e.value;return Action::Up;}if(e.value>0&&mHy<=0){mHy=e.value;return Action::Down;}mHy=e.value;}}
        }}return Action::None;
    }
private:std::vector<int>mFds;std::vector<pollfd>mPoll;int mHx=0,mHy=0;
};

enum class Page { Home,Setup,Mods,Navmesh,Diagnostics,Confirm };
struct App
{
    fs::path root,request,statusFile,modsFile,uiFile,resultFile,backend; std::map<std::string,std::string> status; std::vector<Mod> mods;
    Page page=Page::Home,returnPage=Page::Home; int home=0,opt=0,modSel=0,scroll=0; std::string pending,question,lastResult,localAction; bool quit=false;
};

static const Color BG{13,15,18},P1{25,28,33},P2{38,42,49},FG{238,240,242},DIM{151,157,166},ACC{207,172,103},GOOD{126,210,142},WARN{236,191,92},BAD{229,118,118};
static void label(Framebuffer&f,const std::string&s,int x,int y,int z=2,Color c=FG){drawText(f,s,x,y,z,c);}
static void row(Framebuffer&f,int x,int y,const std::string&n,const std::string&v,Color c){label(f,n,x,y,2,DIM);label(f,fit(v,43),x+330,y,2,c);}
static bool flag(const App&a,const std::string&k){auto i=a.status.find(k);return i!=a.status.end()&&i->second=="1";}
static std::string val(const App&a,const std::string&k,const std::string&d="-"){auto i=a.status.find(k);return i==a.status.end()?d:i->second;}

static void saveUi(const App&a)
{
    std::ofstream o(a.uiFile);if(!o)return;o<<"page="<<int(a.page)<<"\nhome="<<a.home<<"\nopt="<<a.opt<<"\nmod="<<a.modSel<<"\n";
}
static void loadUi(App&a)
{
    auto k=readKv(a.uiFile);try{int p=std::stoi(k["page"]);if(p>=0&&p<=4)a.page=Page(p);a.home=std::stoi(k["home"]);a.opt=std::stoi(k["opt"]);a.modSel=std::stoi(k["mod"]);}catch(...){}
}
static void refresh(App&a){a.status=readKv(a.statusFile);a.mods=readMods(a.modsFile);if(a.modSel>=int(a.mods.size()))a.modSel=std::max(0,int(a.mods.size())-1);if(a.modSel<a.scroll)a.scroll=a.modSel;if(a.modSel>=a.scroll+8)a.scroll=a.modSel-7;std::ifstream in(a.resultFile);std::getline(in,a.lastResult);}
static void request(App&a,const std::string&cmd){saveUi(a);writeAtomic(a.request,cmd);a.quit=true;}
// TSP_MANAGER_V24_DISPATCH: only play/exit/build-navmesh still replace the UI.
static bool handoffRequest(const std::string&cmd){return cmd=="play"||cmd=="exit"||cmd=="build-navmesh";}
static void dispatch(App&a,const std::string&cmd){if(handoffRequest(cmd))request(a,cmd);else{saveUi(a);a.localAction=cmd;}}
static void confirm(App&a,Page back,const std::string&q,const std::string&cmd){a.returnPage=back;a.question=q;a.pending=cmd;a.page=Page::Confirm;}

static void header(Framebuffer&f){f.rect(0,0,f.width(),68,{9,10,12});label(f,"OPENMW 0.51",28,18,3,ACC);label(f,"TRIMUI SMART PRO MANAGER",270,25,2,FG);label(f,"INTEGRATED V2.4",1010,25,2,DIM);f.rect(0,68,f.width(),2,ACC);}
static void nav(Framebuffer&f,const App&a)
{
    static const char* items[]={"PLAY MORROWIND","SETUP STORAGE","MODS MANAGER","NAVMESH BUILDER","DIAGNOSTICS","EXIT"};
    f.rect(18,92,300,560,P1);label(f,"MANAGER",42,112,2,DIM);
    for(int i=0;i<6;++i){int y=154+i*64;bool s=a.page==Page::Home&&a.home==i;if(s)f.rect(32,y-14,272,48,P2);label(f,s?">":" ",46,y,2,s?ACC:DIM);label(f,items[i],72,y,2,s?FG:DIM);}
    label(f,"DPAD NAVIGATE",42,590,1,DIM);label(f,"A SELECT  B BACK",42,610,1,DIM);label(f,"START APPLY  X REFRESH",42,630,1,DIM);
}
static void title(Framebuffer&f,const std::string&a,const std::string&b){label(f,a,354,105,3,FG);label(f,b,356,142,1,DIM);}

static void homePage(Framebuffer&f,App&a)
{
    nav(f,a);title(f,"PORT STATUS","REAL INSTALL, MOD ORDER, NAVMESH AND SWAP CONTROL");f.rect(350,180,902,258,P1);
    row(f,380,205,"MORROWIND DATA",flag(a,"game")?"FOUND":"NOT FOUND",flag(a,"game")?GOOD:BAD);
    row(f,380,245,"UDISK",flag(a,"udisk")?val(a,"udisk_fs")+" / "+human(number(val(a,"udisk_free","0")))+" FREE":"NOT AVAILABLE",flag(a,"udisk")?GOOD:BAD);
    row(f,380,285,"NAVMESH",flag(a,"navmesh")?human(number(val(a,"navmesh_size","0"))):"NOT INSTALLED",flag(a,"navmesh")?GOOD:WARN);
    std::string np=val(a,"navmesh_profile","UNKNOWN");row(f,380,325,"NAVMESH PROFILE",np,np=="CURRENT"||np=="BASE CURRENT"?GOOD:(np=="STALE"?WARN:DIM));
    row(f,380,365,"SWAP",flag(a,"swap_active")?"ACTIVE":(flag(a,"swap_file")?"INSTALLED / INACTIVE":"NOT INSTALLED"),flag(a,"swap_active")?GOOD:WARN);
    row(f,380,405,"MOD DATA ROOTS",val(a,"mods_enabled","0")+" / "+val(a,"mods_total","0")+" ENABLED",FG);
    f.rect(350,458,902,124,P1);label(f,"LAST ACTION",380,480,2,ACC);label(f,fit(a.lastResult.empty()?"READY":a.lastResult,104),380,515,1,FG);label(f,"PLAY WARNS BEFORE USING A STALE MODDED NAVMESH.",380,548,1,DIM);
}

static void setupPage(Framebuffer&f,App&a)
{
    title(f,"SETUP STORAGE","INSTALL THE UDISK NAVMESH AND SWAP FILE BEFORE FIRST LAUNCH");f.rect(350,178,902,410,P1);
    std::array<std::string,4> n={"SETUP GAME FOR FIRST LAUNCH","INSTALL / REPAIR DEFAULT NAVMESH","INSTALL / ACTIVATE DEFAULT SWAP","REFRESH DEVICE STATUS"};
    for(int i=0;i<4;++i){int y=198+i*50;if(a.opt==i)f.rect(370,y-13,840,42,P2);label(f,a.opt==i?">":" ",386,y,2,a.opt==i?ACC:DIM);label(f,n[i],414,y,2,a.opt==i?FG:DIM);}
    row(f,390,405,"DEFAULT NAVMESH",val(a,"default_navmesh","NOT FOUND"),flag(a,"default_navmesh_ready")?GOOD:WARN);
    row(f,390,445,"DEFAULT SWAP",val(a,"default_swap","CREATE 512 MB"),flag(a,"default_swap_ready")?GOOD:DIM);
    row(f,390,485,"UDISK FREE",flag(a,"udisk")?human(number(val(a,"udisk_free","0"))):"NOT AVAILABLE",flag(a,"udisk")?GOOD:BAD);
    row(f,390,525,"STORAGE TARGET","/MNT/UDISK/OPENMW-NAV + OPENMW-SWAPFILE",DIM);
    label(f,"FIRST LAUNCH INSTALLS NAVMESH AND SWAP ONLY. MOD ORDER COMES FROM OPENMW.CFG.",390,563,1,WARN);label(f,"A SELECT   B BACK",390,622,1,DIM);
}

static void modsPage(Framebuffer&f,App&a)
{
    title(f,"MODS MANAGER","A TOGGLE  LEFT/RIGHT MOVE  START VALIDATE + APPLY");f.rect(350,178,902,410,P1);
    if(a.mods.empty())label(f,"NO MOD DATA ROOTS FOUND. PRESS X TO RESCAN.",390,220,2,WARN);
    for(int r=0,i=a.scroll;i<int(a.mods.size())&&r<8;++i,++r){int y=205+r*38;bool s=i==a.modSel;if(s)f.rect(370,y-10,840,31,P2);std::ostringstream n;n<<(i+1)<<" ";label(f,s?">":" ",382,y,1,s?ACC:DIM);label(f,n.str(),402,y,1,DIM);label(f,a.mods[i].enabled?"[ON]":"[OFF]",450,y,1,a.mods[i].enabled?GOOD:DIM);label(f,a.mods[i].risky?"NAV":"---",510,y,1,a.mods[i].risky?WARN:DIM);label(f,fit(a.mods[i].name,66),555,y,1,s?FG:DIM);}
    row(f,390,525,"PLUGIN ORDER",val(a,"plugin_status","NOT SCANNED"),val(a,"plugin_status")=="VALID"?GOOD:WARN);
    row(f,390,555,"NAVMESH IMPACT",val(a,"mod_navmesh","UNKNOWN"),val(a,"mod_navmesh")=="BASE ONLY"?GOOD:WARN);
    label(f,"X RESCAN   START APPLY   CONFIG IS BACKED UP TRANSACTIONALLY",376,622,1,DIM);
}

static void navmeshPage(Framebuffer&f,App&a)
{
    title(f,"NAVMESH BUILDER","CURRENT CONTENT PROFILE / 3 WORKERS / EXTERIORS + INTERIORS");f.rect(350,178,902,410,P1);
    std::array<std::string,3> n={"BUILD / UPDATE CURRENT MOD PROFILE","INSTALL PREBUILT DEFAULT DATABASE","REFRESH STATUS"};
    for(int i=0;i<3;++i){int y=215+i*70;if(a.opt==i)f.rect(370,y-14,840,48,P2);label(f,a.opt==i?">":" ",386,y,2,a.opt==i?ACC:DIM);label(f,n[i],414,y,2,a.opt==i?FG:DIM);}
    row(f,390,435,"GENERATOR",flag(a,"generator")?"READY":"MISSING",flag(a,"generator")?GOOD:BAD);
    row(f,390,475,"DATABASE",flag(a,"navmesh")?human(number(val(a,"navmesh_size","0"))):"MISSING",flag(a,"navmesh")?GOOD:WARN);
    row(f,390,515,"PROFILE",val(a,"navmesh_profile","UNKNOWN"),val(a,"navmesh_profile")=="CURRENT"?GOOD:WARN);
    label(f,"BUILD CLOSES THIS MENU AND HANDS THE SCREEN TO THE GENERATORS OWN",390,545,1,DIM);
    label(f,"PROGRESS WINDOW. THE MENU RETURNS WITH THE RESULT WHEN IT FINISHES.",390,570,1,DIM);label(f,"A SELECT   B BACK",390,622,1,DIM);
}

static void diagnosticsPage(Framebuffer&f,App&a)
{
    title(f,"DIAGNOSTICS","EXACT PATHS AND READINESS");f.rect(350,178,902,410,P1);
    row(f,390,205,"ROOT",a.root.string(),FG);row(f,390,245,"MAIN CONFIG",val(a,"config"),FG);
    row(f,390,285,"BASE NAV SOURCE",val(a,"default_navmesh"),flag(a,"default_navmesh_ready")?GOOD:WARN);
    row(f,390,325,"NAV TARGET",val(a,"navmesh_target"),FG);row(f,390,365,"SWAP TARGET",val(a,"swap_target"),FG);
    row(f,390,405,"GENERATOR",val(a,"generator_path"),flag(a,"generator")?GOOD:BAD);row(f,390,445,"PROFILE HASH",fit(val(a,"profile_hash"),24),DIM);
    row(f,390,485,"CONFIG HEALTH",val(a,"plugin_status"),val(a,"plugin_status")=="VALID"?GOOD:WARN);
    label(f,"X OR A REFRESH   B BACK",390,545,1,DIM);label(f,"FULL LOG: OPENMW/LAUNCHER/MANAGER-V2.LOG",390,622,1,DIM);
}

static void confirmPage(Framebuffer&f,App&a)
{
    title(f,"CONFIRM ACTION","NO LONG OPERATION OR CONFIG WRITE STARTS WITHOUT THIS STEP");f.rect(350,205,902,280,P1);label(f,"ARE YOU SURE?",390,245,3,WARN);label(f,fit(a.question,95),390,310,1,FG);label(f,"A CONFIRM",390,395,2,GOOD);label(f,"B CANCEL",650,395,2,DIM);
}

// TSP_MANAGER_V24_BUSY_PAGE: live overlay drawn while a backend action runs.
static void busyPage(Framebuffer&f,const std::string&heading,const Progress&p,int frame,int elapsed)
{
    f.clear(BG);header(f);
    title(f,"WORKING",heading);
    f.rect(350,178,902,410,P1);
    std::ostringstream step;
    if(p.steps>0&&p.step>0) step<<"STEP "<<p.step<<" OF "<<p.steps;
    else step<<"PLEASE WAIT";
    label(f,step.str(),390,205,1,ACC);
    label(f,fit(p.phase.empty()?"STARTING":p.phase,44),390,235,2,FG);

    const int bx=390,by=290,bw=822,bh=38;
    f.rect(bx-3,by-3,bw+6,bh+6,P2);
    f.rect(bx,by,bw,bh,{18,20,24});
    if(p.pct>=0)
    {
        int filled=(bw*p.pct)/100;
        if(filled>0)f.rect(bx,by,filled,bh,ACC);
    }
    else
    {
        const int blockWidth=170,span=bw+blockWidth;
        int offset=((frame*14)%span)-blockWidth;
        int x0=std::max(bx,bx+offset),x1=std::min(bx+bw,bx+offset+blockWidth);
        if(x1>x0)f.rect(x0,by,x1-x0,bh,ACC);
    }

    std::ostringstream line;
    if(p.pct>=0) line<<p.pct<<"%";
    else line<<"WORKING";
    line<<"    ELAPSED "<<(elapsed/60)<<"M "<<(elapsed%60)<<"S";
    label(f,line.str(),390,355,2,FG);
    label(f,fit(p.detail,104),390,400,1,DIM);
    label(f,"DO NOT POWER OFF THE DEVICE WHILE THIS IS RUNNING.",390,450,1,WARN);
    label(f,"LARGE COPIES AND VERIFICATION CAN TAKE SEVERAL MINUTES.",390,478,1,DIM);
    label(f,"FULL LOG: OPENMW/LAUNCHER/MANAGER-V2.LOG",390,622,1,DIM);
    f.present();
}

// TSP_MANAGER_V24_REPORT_PAGE: the outcome is always shown before returning.
static void reportPage(Framebuffer&f,const std::string&heading,bool ok,int rc,const std::string&message)
{
    f.clear(BG);header(f);
    title(f,ok?"COMPLETE":"FAILED",heading);
    f.rect(350,205,902,300,P1);
    label(f,ok?"FINISHED":"DID NOT COMPLETE",390,245,3,ok?GOOD:BAD);
    auto lines=wrapText(message.empty()?std::string("NO RESULT MESSAGE WAS RECORDED"):message,96,3);
    for(size_t i=0;i<lines.size();++i)label(f,lines[i],390,310+int(i)*26,1,FG);
    if(!ok){std::ostringstream code;code<<"BACKEND EXIT CODE "<<rc;label(f,code.str(),390,400,1,WARN);}
    label(f,"A OR B CONTINUE",390,455,2,ACC);
    label(f,"FULL LOG: OPENMW/LAUNCHER/MANAGER-V2.LOG",390,622,1,DIM);
    f.present();
}

static void render(Framebuffer&f,App&a)
{
    f.clear(BG);header(f);if(a.page==Page::Home)homePage(f,a);else if(a.page==Page::Setup)setupPage(f,a);else if(a.page==Page::Mods)modsPage(f,a);else if(a.page==Page::Navmesh)navmeshPage(f,a);else if(a.page==Page::Diagnostics)diagnosticsPage(f,a);else confirmPage(f,a);
    f.present();
}

static void handle(App&a,Action q)
{
    if(q==Action::Quit){request(a,"exit");return;}
    if(a.page==Page::Confirm){if(q==Action::Select||q==Action::Apply){std::string cmd=a.pending;a.pending.clear();a.page=a.returnPage;dispatch(a,cmd);}else if(q==Action::Back){a.page=a.returnPage;a.pending.clear();}return;}
    if(a.page==Page::Home)
    {
        if(q==Action::Up)a.home=(a.home+5)%6;else if(q==Action::Down)a.home=(a.home+1)%6;else if(q==Action::Back)request(a,"exit");else if(q==Action::Refresh)dispatch(a,"status");else if(q==Action::Select){if(a.home==0){if(val(a,"navmesh_profile")=="STALE")confirm(a,Page::Home,"ACTIVE MODS DO NOT MATCH THIS NAVMESH. PLAY ANYWAY?","play");else request(a,"play");}else if(a.home==1){a.page=Page::Setup;a.opt=0;}else if(a.home==2)a.page=Page::Mods;else if(a.home==3){a.page=Page::Navmesh;a.opt=0;}else if(a.home==4)a.page=Page::Diagnostics;else request(a,"exit");}return;
    }
    if(q==Action::Back){a.page=Page::Home;return;}
    if(a.page==Page::Setup){if(q==Action::Up)a.opt=(a.opt+3)%4;else if(q==Action::Down)a.opt=(a.opt+1)%4;else if(q==Action::Refresh)dispatch(a,"status");else if(q==Action::Select){if(a.opt==0)confirm(a,Page::Setup,"INSTALL THE VERIFIED BASE NAVMESH AND THE UDISK SWAP FILE NOW?","setup-first-launch");else if(a.opt==1)confirm(a,Page::Setup,"REPLACE THE CANONICAL DB WITH THE VERIFIED DEFAULT NAVMESH?","install-navmesh");else if(a.opt==2)confirm(a,Page::Setup,"INSTALL OR ACTIVATE THE CANONICAL UDISK SWAPFILE?","install-swap");else dispatch(a,"status");}}
    else if(a.page==Page::Mods){if(q==Action::Up&&a.modSel>0)--a.modSel;else if(q==Action::Down&&a.modSel+1<int(a.mods.size()))++a.modSel;else if(q==Action::Select&&!a.mods.empty())dispatch(a,"mod-toggle:"+a.mods[a.modSel].id);else if(q==Action::Left&&!a.mods.empty())dispatch(a,"mod-move:"+a.mods[a.modSel].id+":-1");else if(q==Action::Right&&!a.mods.empty())dispatch(a,"mod-move:"+a.mods[a.modSel].id+":1");else if(q==Action::Refresh)dispatch(a,"mods-scan");else if(q==Action::Apply)confirm(a,Page::Mods,"VALIDATE DEPENDENCIES, BACK UP OPENMW.CFG, AND APPLY THIS ORDER?","mods-apply");}
    else if(a.page==Page::Navmesh){if(q==Action::Up)a.opt=(a.opt+2)%3;else if(q==Action::Down)a.opt=(a.opt+1)%3;else if(q==Action::Refresh)dispatch(a,"status");else if(q==Action::Select){if(a.opt==0)confirm(a,Page::Navmesh,"START THE FULL THREE-WORKER NAVMESH BUILD FOR CURRENT MODS?","build-navmesh");else if(a.opt==1)confirm(a,Page::Navmesh,"REPLACE THE CANONICAL DB WITH THE DEFAULT NAVMESH?","install-navmesh");else dispatch(a,"status");}}
    else if(a.page==Page::Diagnostics&&(q==Action::Select||q==Action::Refresh))dispatch(a,"status");
    if(a.modSel<a.scroll)a.scroll=a.modSel;
    if(a.modSel>=a.scroll+8)a.scroll=a.modSel-7;
}

// TSP_MANAGER_V24_COMMANDS: UI command -> backend argv, heading and whether the
// outcome must be acknowledged by the player.
struct Command { std::vector<std::string> args; std::string heading; bool acknowledge=false; bool valid=false; };
static Command parseCommand(const std::string& cmd)
{
    Command out;
    auto simple=[&out](const char* action,const char* heading,bool ack){out.args={action};out.heading=heading;out.acknowledge=ack;out.valid=true;};
    if(cmd=="status") simple("status","REFRESHING DEVICE STATUS",false);
    else if(cmd=="mods-scan") simple("mods-scan","RESCANNING MOD DATA ROOTS",false);
    else if(cmd=="mods-apply") simple("mods-apply","APPLYING MOD ORDER TO OPENMW.CFG",true);
    else if(cmd=="install-navmesh") simple("install-navmesh","INSTALLING THE BASE NAVMESH ON UDISK",true);
    else if(cmd=="install-swap") simple("install-swap","INSTALLING AND ACTIVATING UDISK SWAP",true);
    else if(cmd=="setup-first-launch") simple("setup-first-launch","FIRST LAUNCH SETUP: NAVMESH AND SWAP",true);
    else if(cmd.rfind("mod-toggle:",0)==0){out.args={"mod-toggle",cmd.substr(11)};out.heading="UPDATING MOD SELECTION";out.valid=!out.args[1].empty();}
    else if(cmd.rfind("mod-move:",0)==0)
    {
        std::string payload=cmd.substr(9); auto colon=payload.rfind(':');
        if(colon!=std::string::npos&&colon>0){out.args={"mod-move",payload.substr(0,colon),payload.substr(colon+1)};out.heading="REORDERING MOD DATA ROOTS";out.valid=true;}
    }
    return out;
}

// Hold the outcome on screen until the player dismisses it. Input is ignored
// briefly so a queued button press cannot skip the result.
static void acknowledge(Framebuffer&f,Inputs&in,const std::string&heading,bool ok,int rc,const std::string&message)
{
    auto shown=std::chrono::steady_clock::now();
    while(true)
    {
        reportPage(f,heading,ok,rc,message);
        Action q=in.wait(100);
        bool ready=std::chrono::steady_clock::now()-shown>std::chrono::milliseconds(600);
        if(ready&&(q==Action::Select||q==Action::Back||q==Action::Apply||q==Action::Refresh))break;
    }
}

static void runLocalAction(App&a,Framebuffer&f,Inputs&in,const std::string& cmd)
{
    Command command=parseCommand(cmd);
    if(!command.valid){a.lastResult="ERROR unknown manager command: "+cmd;return;}
    const fs::path progress=progressPath();
    auto start=std::chrono::steady_clock::now();
    auto tick=[&](const Progress&p,int frame)
    {
        (void)in.wait(1);
        int elapsed=int(std::chrono::duration_cast<std::chrono::seconds>(std::chrono::steady_clock::now()-start).count());
        busyPage(f,command.heading,p,frame,elapsed);
    };
    busyPage(f,command.heading,Progress{},0,0);
    int rc=runActionCore(a.backend,command.args,progress,tick);
    std::error_code ec; fs::remove(progress,ec);
    refresh(a);
    if(rc<0)a.lastResult="ERROR manager could not start the action backend";
    bool ok=(rc==0);
    if(!ok||command.acknowledge) acknowledge(f,in,command.heading,ok,rc,a.lastResult);
}

// TSP_MANAGER_V24_SELFTEST: display-free proof of the progress/child contract.
static int selftest()
{
    std::cout<<"OPENMW51_MANAGER_V2_SELFTEST_PASS\n";
    fs::path dir=fs::temp_directory_path()/("openmw-manager-v24-selftest-"+std::to_string(getpid()));
    std::error_code ec; fs::create_directories(dir,ec);
    fs::path progress=dir/"progress",script=dir/"fixture.sh";
    {
        std::ofstream out(progress);
        out<<"phase=COPYING NAVMESH\npct=250\ndetail=1 MB / 2 MB\nstep=1\nsteps=2\n";
    }
    Progress clamped=readProgress(progress);
    if(clamped.pct!=100||clamped.phase!="COPYING NAVMESH"||clamped.step!=1||clamped.steps!=2)
    { std::cerr<<"selftest: progress clamp/parse failed\n"; return 1; }
    {
        std::ofstream out(progress);
        out<<"phase=HASHING\npct=-1\n";
    }
    if(readProgress(progress).pct!=-1){std::cerr<<"selftest: indeterminate progress failed\n";return 1;}
    if(readProgress(dir/"missing").pct!=-1){std::cerr<<"selftest: missing progress file failed\n";return 1;}
    {
        std::ofstream out(script);
        out<<"#!/bin/bash\n"
             "printf 'phase=FIXTURE STEP\\npct=42\\ndetail=x\\nstep=1\\nsteps=1\\n' > \"$1\"\n"
             "sleep 1\n"
             "exit 7\n";
    }
    int observedPct=-99; std::string observedPhase;
    int rc=runActionCore(script,{progress.string()},progress,
        [&](const Progress&p,int){ if(p.pct>=0){observedPct=p.pct;observedPhase=p.phase;} });
    if(rc!=7){std::cerr<<"selftest: child exit status not propagated: "<<rc<<"\n";return 1;}
    if(observedPct!=42||observedPhase!="FIXTURE STEP"){std::cerr<<"selftest: live progress was not observed\n";return 1;}
    {
        std::ofstream out(script);
        out<<"#!/bin/bash\nexit 0\n";
    }
    if(runActionCore(script,{},progress,[](const Progress&,int){})!=0){std::cerr<<"selftest: success status failed\n";return 1;}
    Command setup=parseCommand("setup-first-launch");
    if(!setup.valid||setup.args.size()!=1||setup.args[0]!="setup-first-launch"||!setup.acknowledge)
    { std::cerr<<"selftest: setup command mapping failed\n"; return 1; }
    Command move=parseCommand("mod-move:abc123:-1");
    if(!move.valid||move.args.size()!=3||move.args[1]!="abc123"||move.args[2]!="-1")
    { std::cerr<<"selftest: mod-move command mapping failed\n"; return 1; }
    if(parseCommand("nonsense").valid){std::cerr<<"selftest: unknown command accepted\n";return 1;}
    if(!handoffRequest("play")||!handoffRequest("exit")||!handoffRequest("build-navmesh"))
    { std::cerr<<"selftest: handoff requests misclassified\n"; return 1; }
    if(handoffRequest("setup-first-launch")||handoffRequest("install-navmesh")||handoffRequest("install-swap"))
    { std::cerr<<"selftest: long action wrongly left the UI\n"; return 1; }
    fs::path pending=dir/"pending-report";
    Report handedBack;
    if(takePendingReport(pending,handedBack)){std::cerr<<"selftest: absent report was consumed\n";return 1;}
    {
        std::ofstream out(pending);
        out<<"heading=NAVMESH BUILDER\nok=0\ncode=29\n";
    }
    if(!takePendingReport(pending,handedBack)){std::cerr<<"selftest: pending report not read\n";return 1;}
    if(handedBack.heading!="NAVMESH BUILDER"||handedBack.ok||handedBack.code!=29)
    { std::cerr<<"selftest: pending report fields wrong\n"; return 1; }
    if(fs::exists(pending)){std::cerr<<"selftest: pending report was not consumed\n";return 1;}
    {
        std::ofstream out(pending);
        out<<"heading=NAVMESH BUILDER\nok=1\ncode=0\n";
    }
    if(!takePendingReport(pending,handedBack)||!handedBack.ok)
    { std::cerr<<"selftest: successful pending report misread\n"; return 1; }
    auto wrapped=wrapText("one two three four five six seven",12,3);
    if(wrapped.size()<2||wrapped[0].size()>12){std::cerr<<"selftest: wrap failed\n";return 1;}
    fs::remove_all(dir,ec);
    std::cout<<"OPENMW_MANAGER_V24_PROGRESS_SELFTEST_PASS\n";
    return 0;
}

int main(int argc,char**argv)
{
    if(argc>1&&std::string(argv[1])=="--selftest") return selftest();
    if(argc>1&&std::string(argv[1])=="--display-selftest")
    {
        try
        {
            Framebuffer display("");display.clear({12,34,56});display.present();
            std::cout<<"OPENMW51_MANAGER_V2_SDL_DISPLAY_SELFTEST_PASS\n";return 0;
        }
        catch(const std::exception&e){std::cerr<<"OpenMW manager display selftest fatal: "<<e.what()<<"\n";return 1;}
    }
    try
    {
        App a;a.root="/mnt/SDCARD/data/ports/openmw";if(const char*e=getenv("OPENMW_GAMEDIR"))a.root=e;else if(const char*e=getenv("OPENMW51_GAMEDIR"))a.root=e;
        setenv("OPENMW_GAMEDIR",a.root.c_str(),0);
        fs::path l=a.root/"launcher";a.request=l/"request";a.statusFile=l/"status.conf";a.modsFile=l/"modplan.tsv";a.uiFile=l/"ui-state.conf";a.resultFile=l/"last-result.txt";fs::path readyFile=l/"ui-ready";
        a.backend=l/"openmw-manager-action-v2.sh";fs::path reportFile=l/"pending-report";
        std::error_code readyError;fs::remove(readyFile,readyError);
        loadUi(a);refresh(a);Framebuffer fb(getenv("OPENMW51_LAUNCHER_FB")?getenv("OPENMW51_LAUNCHER_FB"):"/dev/fb0");Inputs in;
        // Present one frame and publish readiness before the first scan so the
        // wrapper watchdog and the player both see the UI immediately.
        render(fb,a);
        writeAtomic(readyFile,"ready");
        // An action that owned the screen on its own (the navmesh generator)
        // reports back here, so its outcome is shown before anything else.
        Report handedBack;
        if(takePendingReport(reportFile,handedBack))
            acknowledge(fb,in,handedBack.heading,handedBack.ok,handedBack.code,a.lastResult);
        runLocalAction(a,fb,in,"status");
        bool dirty=true;auto last=std::chrono::steady_clock::now();
        while(!a.quit)
        {
            Action q=in.wait(80);
            if(q!=Action::None){handle(a,q);dirty=true;}
            if(!a.localAction.empty())
            {
                std::string cmd=a.localAction;a.localAction.clear();
                runLocalAction(a,fb,in,cmd);
                last=std::chrono::steady_clock::now();dirty=true;
            }
            auto now=std::chrono::steady_clock::now();
            if(now-last>std::chrono::seconds(3)){refresh(a);last=now;dirty=true;}
            if(dirty){render(fb,a);dirty=false;}
        }
        return 0;
    }
    catch(const std::exception&e){std::cerr<<"OpenMW manager fatal: "<<e.what()<<"\n";return 1;}
}
OPENMW_V24_MANAGER_CPP_EOF

    cat > "$ACTION_SH" <<'OPENMW_V24_ACTION_SH_EOF'
#!/bin/bash
# Runtime action backend for OpenMW 0.51 TSP Manager V2.4.
# TSP_MANAGER_V24_PROGRESS_BACKEND
#
# V2.4 changes:
#   - every long operation publishes live progress to $PROGRESS_FILE so the
#     manager UI can draw a progress bar instead of leaving a black screen;
#   - SETUP GAME FOR FIRST LAUNCH is storage only: base navmesh + swap.
#     Mod data roots and load order come from openmw.cfg and are never
#     rewritten by first-launch setup.
set -u -o pipefail

ACTION="${1:-status}"
SELFTEST=0
[ "$ACTION" = "selftest" ] && SELFTEST=1

if [ "$SELFTEST" -eq 1 ]; then
    ROOT="$(mktemp -d "${TMPDIR:-/tmp}/openmw-manager-action-selftest.XXXXXX")" || exit 90
    PROGRESS_FILE="$ROOT/progress"
else
    ROOT="${OPENMW_GAMEDIR:-${OPENMW51_GAMEDIR:-/mnt/SDCARD/data/ports/openmw}}"
    PROGRESS_FILE="${OPENMW_MANAGER_PROGRESS:-/tmp/openmw-manager-progress}"
fi

PY="$ROOT/launcher/openmw-launcher-backend-v2.py"
LOG="$ROOT/launcher/manager-v2.log"
RESULT="$ROOT/launcher/last-result.txt"
NAVDIR="${OPENMW_NAVMESH_DIR:-${OPENMW51_NAVMESH_DIR:-/mnt/UDISK/openmw-nav}}"
NAVDB="$NAVDIR/navmesh.db"
SWAP=/mnt/UDISK/openmw-swapfile
DEFAULT_SWAP="$ROOT/defaults/base-swapfile"
CLEANUP_FILE=""
STEP=0
STEPS=0

# Fractional sleep keeps the bar smooth; fall back to whole seconds if the
# device shell cannot do it.
SLEEP_TICK=0.5
sleep 0.1 >/dev/null 2>&1 || SLEEP_TICK=1

mkdir -p "$ROOT/launcher"
[ "$SELFTEST" -eq 1 ] || exec >>"$LOG" 2>&1

cleanup_temp() {
    if [ -n "$CLEANUP_FILE" ] && [ -f "$CLEANUP_FILE" ]; then
        rm -f "$CLEANUP_FILE"
    fi
    rm -f "$PROGRESS_FILE.tmp"
}
trap cleanup_temp EXIT INT TERM

say() {
    printf '%s\n' "$*"
    printf '%s\n' "$*" > "$RESULT"
}

# The most specific failure text already published by the failing step, so a
# multi-step wrapper never hides why it stopped.
last_reason() {
    head -n 1 "$RESULT" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# TSP_MANAGER_V24_PROGRESS_CONTRACT
# phase/pct/detail/step/steps, published atomically. pct=-1 means the UI should
# draw an indeterminate bar (hashing, mkswap, sync: no measurable byte count).
# ---------------------------------------------------------------------------
progress() {
    local phase="${1:-}" pct="${2:--1}" detail="${3:-}"
    {
        printf 'phase=%s\npct=%s\ndetail=%s\nstep=%s\nsteps=%s\n' \
            "$phase" "$pct" "$detail" "$STEP" "$STEPS" > "$PROGRESS_FILE.tmp" 2>/dev/null &&
        mv -f "$PROGRESS_FILE.tmp" "$PROGRESS_FILE" 2>/dev/null
    } || true
}

human_bytes() {
    awk -v n="${1:-0}" 'BEGIN {
        split("B KB MB GB TB", unit, " ")
        i = 1
        while (n >= 1024 && i < 5) { n /= 1024; i++ }
        if (i >= 4) printf "%.1f %s", n, unit[i]
        else printf "%.0f %s", n, unit[i]
    }'
}

# run_with_size_progress <phase> <watched file> <total bytes> <pct from> <pct to> <command...>
# Runs the command in the background and reports real byte progress by watching
# the growing output file. A completion file carries the exact child status, so
# the poll loop can never be confused by an unreaped process.
run_with_size_progress() {
    local phase="$1" watch="$2" total="$3" from="$4" to="$5"
    shift 5
    local done_file rc copied pct
    case "$total" in ''|*[!0-9]*) total=0 ;; esac
    done_file="$PROGRESS_FILE.done.$$"
    rm -f "$done_file"
    progress "$phase" "$from" "0 B / $(human_bytes "$total")"
    ( "$@"; printf '%s\n' "$?" > "$done_file" ) &
    while [ ! -s "$done_file" ]; do
        copied="$(stat -c %s "$watch" 2>/dev/null || printf '0')"
        case "$copied" in ''|*[!0-9]*) copied=0 ;; esac
        if [ "$total" -gt 0 ]; then
            pct=$(( from + ((to - from) * copied) / total ))
            [ "$pct" -le "$to" ] || pct="$to"
        else
            pct=-1
        fi
        progress "$phase" "$pct" "$(human_bytes "$copied") / $(human_bytes "$total")"
        sleep "$SLEEP_TICK"
    done
    read -r rc < "$done_file"
    rm -f "$done_file"
    wait 2>/dev/null || true
    case "$rc" in ''|*[!0-9]*) rc=1 ;; esac
    if [ "$rc" -eq 0 ]; then
        progress "$phase" "$to" "$(human_bytes "$total") / $(human_bytes "$total")"
    fi
    return "$rc"
}

run_python() {
    [ -x "$PY" ] || { say "ERROR backend missing: $PY"; return 10; }
    "$PY" "$@"
}

udisk_fs() {
    awk '$2=="/mnt/UDISK" {print $3; exit}' /proc/mounts 2>/dev/null
}

valid_udisk() {
    [ -d /mnt/UDISK ] || { say "ERROR UDISK is not mounted"; return 1; }
    case "$(udisk_fs)" in
        ext2|ext3|ext4|f2fs|btrfs|xfs) return 0 ;;
        *) say "ERROR UDISK filesystem cannot safely host swap: $(udisk_fs)"; return 1 ;;
    esac
}

tune_swap() {
    [ -w /proc/sys/vm/swappiness ] && printf '%s\n' 150 > /proc/sys/vm/swappiness 2>/dev/null || true
    [ -w /proc/sys/vm/vfs_cache_pressure ] && printf '%s\n' 50 > /proc/sys/vm/vfs_cache_pressure 2>/dev/null || true
}

activate_swap() {
    [ -e /proc/swaps ] || { say "ERROR kernel swap support unavailable"; return 20; }
    if grep -q "^$SWAP " /proc/swaps 2>/dev/null; then
        tune_swap
        say "Swap already active: $SWAP"
        return 0
    fi
    [ -f "$SWAP" ] || { say "ERROR swapfile is not installed"; return 21; }
    command -v swapon >/dev/null 2>&1 || { say "ERROR swapon is unavailable"; return 22; }
    chmod 600 "$SWAP" 2>/dev/null || true
    if swapon "$SWAP" 2>/dev/null; then
        tune_swap
        say "Swap activated: $SWAP"
        return 0
    fi
    say "ERROR swapon failed for $SWAP"
    return 23
}

install_swap() {
    progress "CHECKING UDISK" 0 "$SWAP"
    valid_udisk || return
    local mb=512 cfg=""
    if [ -r "$ROOT/tsp_swap_mb.txt" ]; then
        read -r cfg < "$ROOT/tsp_swap_mb.txt" || true
        case "$cfg" in ''|*[!0-9]*) ;; *) mb="$cfg" ;; esac
    fi
    case "$mb" in ''|*[!0-9]*|0) say "ERROR invalid swap size: $mb"; return 24;; esac
    command -v mkswap >/dev/null 2>&1 || { say "ERROR mkswap is unavailable"; return 25; }
    command -v swapon >/dev/null 2>&1 || { say "ERROR swapon is unavailable"; return 26; }
    if [ ! -f "$SWAP" ]; then
        local free need incoming source_size src_sha copied_sha
        progress "CHECKING FREE SPACE" 3 ""
        free="$(df -k /mnt/UDISK 2>/dev/null | awk 'NR==2 {print $4}')"
        case "$free" in ''|*[!0-9]*) free=0;; esac
        if [ -f "$DEFAULT_SWAP" ]; then
            source_size="$(stat -c %s "$DEFAULT_SWAP" 2>/dev/null || true)"
            case "$source_size" in ''|*[!0-9]*) say "ERROR invalid default swap size"; return 27;; esac
            [ "$source_size" -ge 67108864 ] || { say "ERROR default swap is smaller than 64 MB"; return 27; }
            need=$(((source_size / 1024) + 65536))
        else
            source_size=$((mb * 1024 * 1024))
            need=$((mb * 1024 * 2))
        fi
        [ "$free" -ge "$need" ] || { say "ERROR UDISK needs ${need} KB free for safe swap creation"; return 27; }
        incoming="$SWAP.incoming.$$"
        CLEANUP_FILE="$incoming"
        mkdir -p "$(dirname "$SWAP")" || { say "ERROR cannot create swap target directory"; return 28; }
        if [ -f "$DEFAULT_SWAP" ]; then
            say "Installing default swapfile on UDISK"
            run_with_size_progress "COPYING SWAP FILE TO UDISK" "$incoming" "$source_size" 5 60 \
                cp -p "$DEFAULT_SWAP" "$incoming" || { say "ERROR default swap copy failed"; return 28; }
            progress "VERIFYING SWAP CHECKSUM" -1 "$(human_bytes "$source_size")"
            src_sha="$(sha256sum "$DEFAULT_SWAP" | awk '{print $1}')"
            copied_sha="$(sha256sum "$incoming" | awk '{print $1}')"
            [ -n "$src_sha" ] && [ "$src_sha" = "$copied_sha" ] || { say "ERROR staged swap SHA mismatch"; return 28; }
        else
            say "Creating ${mb} MB swapfile on UDISK"
            run_with_size_progress "CREATING ${mb} MB SWAP FILE" "$incoming" "$source_size" 5 70 \
                dd if=/dev/zero of="$incoming" bs=1M count="$mb" conv=fsync || { say "ERROR swapfile write failed"; return 28; }
        fi
        progress "PREPARING SWAP FILE" 78 "mkswap"
        chmod 600 "$incoming" || { say "ERROR swapfile chmod failed"; return 29; }
        mkswap "$incoming" >/dev/null 2>&1 || { say "ERROR mkswap failed"; return 30; }
        progress "PUBLISHING SWAP FILE" 85 "$SWAP"
        mv -f "$incoming" "$SWAP" || { say "ERROR swapfile publish failed"; return 31; }
        CLEANUP_FILE=""
        progress "FLUSHING TO UDISK" -1 "sync"
        sync
    fi
    progress "ACTIVATING SWAP" 92 "$SWAP"
    activate_swap || return
    progress "SWAP READY" 100 "$SWAP"
}

install_navmesh() {
    progress "CHECKING UDISK" 0 "$NAVDB"
    [ -d /mnt/UDISK ] || { say "ERROR UDISK is not mounted"; return 40; }
    local source size free need incoming src_sha dst_sha
    progress "LOCATING BASE NAVMESH" 2 "$ROOT/defaults/base-navmesh.db"
    source="$(run_python default-path)" || return 41
    [ -s "$source" ] || { say "ERROR selected base navmesh is missing"; return 42; }
    [ "$source" != "$NAVDB" ] || { say "ERROR source and canonical navmesh are the same file"; return 43; }
    size="$(stat -c %s "$source" 2>/dev/null || true)"
    free="$(df -B1 /mnt/UDISK 2>/dev/null | awk 'NR==2 {print $4}')"
    case "$size" in ''|*[!0-9]*) say "ERROR invalid base navmesh size"; return 44;; esac
    case "$free" in ''|*[!0-9]*) free=0;; esac
    need=$((size + 67108864))
    [ "$free" -ge "$need" ] || { say "ERROR UDISK lacks space for verified navmesh staging"; return 45; }
    mkdir -p "$NAVDIR" || { say "ERROR cannot create $NAVDIR"; return 46; }
    incoming="$NAVDB.incoming.$$"
    CLEANUP_FILE="$incoming"
    say "Installing verified base-game navmesh"
    run_with_size_progress "COPYING NAVMESH TO UDISK" "$incoming" "$size" 4 62 \
        cp -p "$source" "$incoming" || { say "ERROR navmesh copy failed"; return 47; }
    progress "VERIFYING SOURCE CHECKSUM" -1 "$(human_bytes "$size")"
    src_sha="$(sha256sum "$source" | awk '{print $1}')"
    progress "VERIFYING COPIED CHECKSUM" -1 "$(human_bytes "$size")"
    dst_sha="$(sha256sum "$incoming" | awk '{print $1}')"
    [ -n "$src_sha" ] && [ "$src_sha" = "$dst_sha" ] || { say "ERROR staged navmesh SHA mismatch"; return 48; }
    if command -v sqlite3 >/dev/null 2>&1; then
        progress "SQLITE INTEGRITY CHECK" -1 "PRAGMA integrity_check"
        [ "$(sqlite3 "$incoming" 'PRAGMA integrity_check;' 2>/dev/null)" = ok ] \
            || { say "ERROR staged navmesh failed SQLite integrity_check"; return 48; }
    fi
    # One canonical database only. Intentionally no automatic DB backup.
    progress "PUBLISHING DATABASE" 92 "$NAVDB"
    mv -f "$incoming" "$NAVDB" || { say "ERROR navmesh publish failed"; return 49; }
    CLEANUP_FILE=""
    progress "FLUSHING TO UDISK" -1 "sync"
    sync
    progress "RECORDING NAVMESH PROFILE" 97 ""
    run_python mark-default || return 50
    progress "NAVMESH INSTALLED" 100 "$NAVDB"
    say "Base navmesh installed and verified: $src_sha"
}

# TSP_MANAGER_V24_FIRST_LAUNCH
# Storage only. No openmw.cfg write, no mod validation, no mod re-ordering.
setup_first_launch() {
    STEPS=3
    STEP=1
    install_navmesh || {
        STEP=0; STEPS=0
        say "ERROR setup stopped at the navmesh step; swap and configuration unchanged: $(last_reason)"
        return 61
    }
    STEP=2
    install_swap || {
        STEP=0; STEPS=0
        say "ERROR navmesh installed but setup stopped at the swap step: $(last_reason)"
        return 62
    }
    STEP=3
    progress "RECORDING NAVMESH PROFILE" 20 "current enabled data order"
    run_python mark-navmesh || {
        STEP=0; STEPS=0
        say "ERROR navmesh and swap installed but the navmesh profile could not be recorded: $(last_reason)"
        return 63
    }
    progress "REFRESHING DEVICE STATUS" 70 ""
    run_python status || {
        STEP=0; STEPS=0
        say "ERROR navmesh and swap installed but the final status refresh failed"
        return 64
    }
    progress "FIRST LAUNCH SETUP COMPLETE" 100 ""
    STEP=0
    STEPS=0
    say "First-launch setup complete: base navmesh installed, UDISK swap active, mod order untouched"
}

run_selftest() {
    local work src dst rc phase pct total
    work="$ROOT/selftest"
    mkdir -p "$work" || return 91

    [ "$(human_bytes 1048576)" = "1 MB" ] || { echo "FAIL human_bytes MB"; return 92; }
    [ "$(human_bytes 0)" = "0 B" ] || { echo "FAIL human_bytes zero"; return 92; }

    STEP=2
    STEPS=3
    progress "PHASE TEST" 55 "detail text"
    [ -s "$PROGRESS_FILE" ] || { echo "FAIL progress file was not published"; return 93; }
    [ ! -e "$PROGRESS_FILE.tmp" ] || { echo "FAIL progress temp file was left behind"; return 93; }
    grep -Fqx 'phase=PHASE TEST' "$PROGRESS_FILE" || { echo "FAIL progress phase"; return 93; }
    grep -Fqx 'pct=55' "$PROGRESS_FILE" || { echo "FAIL progress pct"; return 93; }
    grep -Fqx 'step=2' "$PROGRESS_FILE" || { echo "FAIL progress step"; return 93; }
    grep -Fqx 'steps=3' "$PROGRESS_FILE" || { echo "FAIL progress steps"; return 93; }
    STEP=0
    STEPS=0

    src="$work/source.bin"
    dst="$work/target.bin"
    dd if=/dev/zero of="$src" bs=1024 count=3072 >/dev/null 2>&1 || { echo "FAIL fixture create"; return 94; }
    total="$(stat -c %s "$src")"
    run_with_size_progress "COPY TEST" "$dst" "$total" 10 90 cp -p "$src" "$dst" || { echo "FAIL copy progress rc"; return 94; }
    [ "$(sha256sum "$src" | awk '{print $1}')" = "$(sha256sum "$dst" | awk '{print $1}')" ] \
        || { echo "FAIL copied bytes differ"; return 94; }
    grep -Fqx 'pct=90' "$PROGRESS_FILE" || { echo "FAIL copy progress did not finish at its end percent"; return 94; }

    run_with_size_progress "SLOW TEST" "$work/never" 4096 10 90 \
        bash -c 'sleep 1; exit 5'
    rc=$?
    [ "$rc" -eq 5 ] || { echo "FAIL nonzero child status not propagated: $rc"; return 95; }
    phase="$(sed -n 's/^phase=//p' "$PROGRESS_FILE" | tail -n 1)"
    [ "$phase" = "SLOW TEST" ] || { echo "FAIL live polling did not publish during the child run: $phase"; return 95; }
    pct="$(sed -n 's/^pct=//p' "$PROGRESS_FILE" | tail -n 1)"
    [ "$pct" != "90" ] || { echo "FAIL failed command was reported complete"; return 95; }

    run_with_size_progress "UNMEASURED TEST" "$work/never" 0 10 90 true || { echo "FAIL indeterminate rc"; return 96; }
    printf '%s\n' "OPENMW_MANAGER_V24_ACTION_SELFTEST_PASS"
    rm -rf "$ROOT"
    return 0
}

if [ "$SELFTEST" -eq 1 ]; then
    run_selftest
    exit $?
fi

echo "============================================================"
echo "Manager V2.4 action: $ACTION"
echo "Started: $(date)"
echo "============================================================"

case "$ACTION" in
    status) run_python status ;;
    mods-scan) run_python scan ;;
    mods-apply) run_python apply ;;
    mod-toggle) [ "$#" -eq 2 ] || { say "ERROR toggle needs an id"; exit 2; }; run_python toggle "$2" ;;
    mod-move) [ "$#" -eq 3 ] || { say "ERROR move needs id and delta"; exit 2; }; run_python move "$2" "$3" ;;
    setup-first-launch) setup_first_launch ;;
    install-navmesh) install_navmesh ;;
    install-swap) install_swap ;;
    activate-swap) activate_swap ;;
    mark-navmesh) run_python mark-navmesh ;;
    diagnostics)
        run_python status
        echo "--- mounts ---"; grep -E ' /mnt/(UDISK|SDCARD) ' /proc/mounts || true
        echo "--- swap ---"; cat /proc/swaps 2>/dev/null || true
        echo "--- navmesh ---"; ls -lh "$NAVDB" 2>/dev/null || true
        echo "--- candidates ---"; cat "$ROOT/launcher/default-navmesh-candidates.txt" 2>/dev/null || true
        ;;
    *) say "ERROR unknown manager action: $ACTION"; exit 2 ;;
esac
OPENMW_V24_ACTION_SH_EOF

    cat > "$WRAPPER_SH" <<'OPENMW_V24_WRAPPER_SH_EOF'
#!/bin/bash
# OpenMW 0.51 TSP integrated manager Ports entry.
# TSP_MANAGER_V24_WRAPPER
set +e
set +u
set +o pipefail 2>/dev/null || true

ROOT="${OPENMW_GAMEDIR:-${OPENMW51_GAMEDIR:-/mnt/SDCARD/data/ports/openmw}}"
BIN="$ROOT/bin/openmw-manager-v2"
BACKEND="$ROOT/launcher/openmw-manager-action-v2.sh"
REQUEST="$ROOT/launcher/request"
RESULT="$ROOT/launcher/last-result.txt"
LOG="$ROOT/launcher/manager-v2.log"
READY="$ROOT/launcher/ui-ready"
PIDFILE="$ROOT/launcher/manager-v2-wrapper.pid"
CHILDPID="$ROOT/launcher/manager-v2-ui.pid"
PROGRESS="${OPENMW_MANAGER_PROGRESS:-/tmp/openmw-manager-progress}"
REPORT="$ROOT/launcher/pending-report"
LAUNCH_ENV="$ROOT/launcher/.launch-env"
PLAY=""
UI_PID=""

mkdir -p "$ROOT/launcher"

# TSP_MANAGER_V24_LAUNCH_ENV_SNAPSHOT
# Snapshot the environment this Ports entry was started with, BEFORE PortMaster
# control.txt/libgl_*.txt are sourced and before any manager SDL override. The
# standalone generator Ports entry is launched with exactly this environment,
# so restoring it is what makes the manager's navmesh build behave identically.
export -p > "$LAUNCH_ENV" 2>/dev/null || : > "$LAUNCH_ENV"

exec >>"$LOG" 2>&1
echo "===== OpenMW 0.51 Manager V2.4 started: $(date) ====="

cleanup_manager() {
    if [ -n "$UI_PID" ] && kill -0 "$UI_PID" 2>/dev/null; then
        kill "$UI_PID" 2>/dev/null || true
        sleep 0.2
        kill -9 "$UI_PID" 2>/dev/null || true
        wait "$UI_PID" 2>/dev/null || true
    fi
    if [ -f "$PIDFILE" ] && [ "$(cat "$PIDFILE" 2>/dev/null)" = "$$" ]; then
        rm -f "$PIDFILE"
    fi
    rm -f "$CHILDPID" "$READY" "$PROGRESS" "$PROGRESS.tmp" "$REPORT.tmp"
}
trap cleanup_manager EXIT
trap 'exit 130' HUP INT TERM

# TSP_MANAGER_V24_GENERATOR_HANDOFF
# Run a command with the snapshotted launch environment and nothing else, so a
# tool that owns the screen never inherits the manager's SDL settings, the
# PortMaster GL4ES exports, or the OpenMW port library path.
run_with_launch_env() {
    local snapshot="$1"
    shift
    env -i /bin/bash -c '
        if [ -f "$1" ]; then . "$1" >/dev/null 2>&1 || true; fi
        shift
        exec /bin/bash "$@"
    ' _ "$snapshot" "$@"
}

report() {
    printf 'heading=%s\nok=%s\ncode=%s\n' "$1" "$2" "$3" > "$REPORT.tmp" 2>/dev/null &&
        mv -f "$REPORT.tmp" "$REPORT" 2>/dev/null || true
}

if [ -s "$PIDFILE" ]; then
    old_wrapper="$(cat "$PIDFILE" 2>/dev/null)"
    case "$old_wrapper" in
        ''|*[!0-9]*) ;;
        *)
            if kill -0 "$old_wrapper" 2>/dev/null; then
                echo "Stopping prior Manager wrapper PID $old_wrapper"
                kill "$old_wrapper" 2>/dev/null || true
                sleep 0.3
                kill -9 "$old_wrapper" 2>/dev/null || true
            fi
            ;;
    esac
fi
printf '%s\n' "$$" > "$PIDFILE"

# Clean up a manager that hung before it could accept controller input.
for old_name in openmw-manager-v2 openmw51-manager-v2; do
    for old_ui in $(pidof "$old_name" 2>/dev/null); do
        case "$old_ui" in
            ''|*[!0-9]*) continue ;;
        esac
        echo "Stopping stale Manager UI PID $old_ui"
        kill "$old_ui" 2>/dev/null || true
        sleep 0.2
        kill -9 "$old_ui" 2>/dev/null || true
    done
done

export PORT_DIR="$ROOT"
export OPENMW_GAMEDIR="$ROOT"
export OPENMW_MANAGER_PROGRESS="$PROGRESS"
rm -f "$PROGRESS" "$PROGRESS.tmp"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/runtime-root}"
mkdir -p "$XDG_RUNTIME_DIR"
chmod 0700 "$XDG_RUNTIME_DIR" 2>/dev/null || true

XDG_DATA_HOME_PM="${XDG_DATA_HOME_PM:-$HOME/.local/share}"
controlfolder=""
for candidate in /mnt/SDCARD/Apps/PortMaster /opt/system/Tools/PortMaster /opt/tools/PortMaster "$XDG_DATA_HOME_PM/PortMaster" /mnt/SDCARD/data/ports/PortMaster /roms/ports/PortMaster; do
    if [ -f "$candidate/control.txt" ]; then controlfolder="$candidate"; break; fi
done
if [ -n "$controlfolder" ] && [ -f "$controlfolder/control.txt" ]; then
    source "$controlfolder/control.txt" || true
fi
if type get_controls >/dev/null 2>&1; then get_controls 2>/dev/null || true; fi
if [ -n "${CFW_NAME:-}" ] && [ -n "$controlfolder" ] && [ -f "$controlfolder/mod_${CFW_NAME}.txt" ]; then source "$controlfolder/mod_${CFW_NAME}.txt" || true; fi
if [ -n "${CFW_NAME:-}" ] && [ -n "$controlfolder" ] && [ -f "$controlfolder/libgl_${CFW_NAME}.txt" ]; then source "$controlfolder/libgl_${CFW_NAME}.txt" || true
elif [ -n "$controlfolder" ] && [ -f "$controlfolder/libgl_default.txt" ]; then source "$controlfolder/libgl_default.txt" || true
fi
if ! type pm_finish >/dev/null 2>&1; then pm_finish(){ true; }; fi

set -u
# Manager is self-contained apart from libc/libdl. Do not put OpenMW's GL4ES
# directory in this UI process: its accelerated KMSDRM teardown poisoned the
# next SDL initialization in the repeat-launch trace.
export LD_LIBRARY_PATH="/usr/trimui/lib:/mnt/SDCARD/System/lib:/usr/lib:/lib:/lib64"
export SDL_VIDEODRIVER="kmsdrm"
export SDL_RENDER_DRIVER="software"
unset LD_PRELOAD
unset LIBGL_FB
unset LIBGL_FBO
unset LIBGL_RECYCLEFBO

for candidate in /mnt/SDCARD/Roms/PORTS/Morrowind.sh /mnt/sdcard/mmcblk1p1/Roms/PORTS/Morrowind.sh; do
    if [ -f "$candidate" ]; then PLAY="$candidate"; break; fi
done

if [ ! -x "$BIN" ] || [ ! -x "$BACKEND" ]; then
    printf '%s\n' "ERROR manager runtime missing; see $LOG" > "$RESULT"
    echo "ERROR: manager runtime missing BIN=$BIN BACKEND=$BACKEND"
    pm_finish
    exit 10
fi

run_manager_ui() {
    rm -f "$READY" "$CHILDPID"
    "$BIN" &
    UI_PID=$!
    printf '%s\n' "$UI_PID" > "$CHILDPID"
    ready=0
    ticks=0
    while [ "$ticks" -lt 80 ]; do
        if [ -s "$READY" ]; then ready=1; break; fi
        if ! kill -0 "$UI_PID" 2>/dev/null; then break; fi
        sleep 0.1
        ticks=$((ticks + 1))
    done
    if [ "$ready" -ne 1 ] && kill -0 "$UI_PID" 2>/dev/null; then
        echo "ERROR manager SDL startup exceeded 8 seconds; terminating PID $UI_PID"
        kill "$UI_PID" 2>/dev/null || true
        sleep 0.3
        kill -9 "$UI_PID" 2>/dev/null || true
        wait "$UI_PID" 2>/dev/null || true
        UI_PID=""
        rm -f "$CHILDPID" "$READY"
        return 124
    fi
    wait "$UI_PID"
    rc=$?
    UI_PID=""
    rm -f "$CHILDPID" "$READY"
    return "$rc"
}

while true; do
    # V2.4: the UI publishes its first frame, then runs the status scan itself
    # behind a progress overlay. No blind pre-UI scan, so nothing is displayed
    # as a black screen while the device is being read.
    rm -f "$REQUEST" "$PROGRESS" "$PROGRESS.tmp"
    run_manager_ui
    ui_rc=$?
    if [ "$ui_rc" -eq 124 ]; then
        echo "INFO retrying Manager UI once after bounded SDL startup cleanup"
        sleep 0.5
        run_manager_ui
        ui_rc=$?
    fi
    if [ "$ui_rc" -ne 0 ]; then
        printf '%s\n' "ERROR manager UI exited $ui_rc" > "$RESULT"
        echo "ERROR: manager UI exited $ui_rc"
        pm_finish
        exit "$ui_rc"
    fi
    request="exit"
    if [ -s "$REQUEST" ]; then read -r request < "$REQUEST" || request="exit"; fi
    rm -f "$REQUEST"
    echo "Manager request: $request"
    case "$request" in
        play)
            "$BACKEND" activate-swap || true
            if [ -z "$PLAY" ]; then
                printf '%s\n' "ERROR working Morrowind.sh was not found in PORTS" > "$RESULT"
                report "PLAY MORROWIND" 0 0
                continue
            fi
            exec /bin/bash "$PLAY"
            ;;
        status) "$BACKEND" status || true ;;
        mods-scan) "$BACKEND" mods-scan || true ;;
        mods-apply) "$BACKEND" mods-apply || true ;;
        mod-toggle:*) "$BACKEND" mod-toggle "${request#mod-toggle:}" || true ;;
        mod-move:*)
            payload="${request#mod-move:}"
            ident="${payload%%:*}"
            delta="${payload##*:}"
            "$BACKEND" mod-move "$ident" "$delta" || true
            ;;
        install-navmesh) "$BACKEND" install-navmesh || true ;;
        install-swap) "$BACKEND" install-swap || true ;;
        setup-first-launch) "$BACKEND" setup-first-launch || true ;;
        build-navmesh)
            # The generator is invoked through /bin/bash, so a missing execute
            # bit on an exFAT card can never make it look absent.
            generator=""
            for candidate in /mnt/SDCARD/Roms/PORTS/OpenMW_Generate_Full_Navmesh_3Worker.sh /mnt/sdcard/mmcblk1p1/Roms/PORTS/OpenMW_Generate_Full_Navmesh_3Worker.sh; do
                if [ -f "$candidate" ]; then generator="$candidate"; break; fi
            done
            if [ -z "$generator" ]; then
                printf '%s\n' "ERROR the three-worker navmesh generator was not found in the PORTS folder" > "$RESULT"
                report "NAVMESH BUILDER" 0 0
                continue
            fi
            echo "Handing the display to the standalone generator: $generator"
            rm -f "$PROGRESS" "$PROGRESS.tmp"
            # The manager UI has already exited and been reaped. Let KMS settle
            # before the generator's own SDL progress window starts.
            sleep 0.5
            run_with_launch_env "$LAUNCH_ENV" "$generator"
            nav_rc=$?
            echo "Generator exited: $nav_rc"
            if [ "$nav_rc" -eq 0 ]; then
                "$BACKEND" mark-navmesh || true
                printf '%s\n' "Navmesh build finished; profile recorded for the current data order" > "$RESULT"
                report "NAVMESH BUILDER" 1 0
            else
                printf '%s\n' "ERROR navmesh generator exited $nav_rc; existing database kept. See navmesh-generation-full-3worker.log" > "$RESULT"
                report "NAVMESH BUILDER" 0 "$nav_rc"
            fi
            ;;
        exit|"") pm_finish; exit 0 ;;
        *) printf '%s\n' "ERROR unknown UI request: $request" > "$RESULT" ;;
    esac
done
OPENMW_V24_WRAPPER_SH_EOF

    cat > "$GENERATOR_SH" <<'OPENMW_V24_GENERATOR_SH_EOF'
#!/bin/bash
set -Eeuo pipefail

# ============================================================
# OpenMW 0.51 / TrimUI Smart Pro S
# COMPLETE NAVMESH GENERATOR — current-runtime isolated tool
#
# Canonical database:
#   /mnt/UDISK/openmw-nav/navmesh.db
#
# Tool runtime:
#   /mnt/SDCARD/data/ports/openmw/navmesh-tool-runtime
#
# That private runtime contains a navmeshtool + defaults.bin pair
# generated from the SAME current OpenMW source tree. It does not
# replace the game's working bin/defaults.bin.
#
# Existing DB -> cached tiles are reused/updated.
# Missing DB  -> complete exterior + interior DB is generated.
# ============================================================

if [ -z "${BASH_VERSION:-}" ]; then
    exec /bin/bash "$0" "$@"
fi

ROOT="${OPENMW_GAMEDIR:-${OPENMW51_GAMEDIR:-/mnt/SDCARD/data/ports/openmw}}"
RUNTIME="$ROOT/navmesh-tool-runtime"
TOOL="$RUNTIME/openmw-navmeshtool"
LOCAL_CFG="$RUNTIME/openmw.cfg"
DEFAULTS="$RUNTIME/defaults.bin"

PROGRESS="$ROOT/bin/openmw-navmesh-progress"
MAIN_CFG="$ROOT/openmw.cfg"
CFGDIR="$ROOT/config"

NAVDIR="${OPENMW_NAVMESH_DIR:-${OPENMW51_NAVMESH_DIR:-/mnt/UDISK/openmw-nav}}"
DB="$NAVDIR/navmesh.db"
BACKUP_DIR="$NAVDIR/backups"

LOG="$ROOT/navmesh-generation-full-3worker.log"
STATUS="$ROOT/navmesh-generation-full-3worker.status"
STATUS_TMP="$STATUS.tmp"

THREADS="${NAVMESH_THREADS:-3}"
REMOVE_UNUSED="${NAVMESH_REMOVE_UNUSED:-true}"
KEEP_BACKUPS="${NAVMESH_KEEP_BACKUPS:-2}"

mkdir -p "$RUNTIME" "$NAVDIR" "$BACKUP_DIR"
rm -f "$STATUS" "$STATUS_TMP"
: > "$LOG"

fail() {
    rc=$?
    line="${1:-?}"
    cmd="${2:-?}"
    trap - ERR

    {
        echo
        echo "============================================================"
        echo "FULL NAVMESH GENERATION STOPPED"
        echo "============================================================"
        echo "Exit code: $rc"
        echo "Line:      $line"
        echo "Command:   $cmd"
        echo "Finished:  $(date)"
        echo
        echo "Log:"
        echo "  $LOG"
        echo
        echo "Database:"
        echo "  $DB"
        echo "============================================================"
    } | tee -a "$LOG"

    if [ -t 0 ]; then
        echo
        printf "Press Enter to exit..."
        read -r _unused || true
    fi

    exit "$rc"
}
trap 'fail "$LINENO" "$BASH_COMMAND"' ERR

exec > >(tee -a "$LOG") 2>&1

echo "============================================================"
echo "OpenMW 0.51 FULL Navmesh Generator"
echo "Current-runtime isolated navmeshtool"
echo "============================================================"
echo "Started:        $(date)"
echo "Tool runtime:   $RUNTIME"
echo "Database:       $DB"
echo "Workers:        $THREADS"
echo "Interiors:      true"
echo "Remove unused:  $REMOVE_UNUSED"
echo "============================================================"
echo

echo "===== 1/7 PREFLIGHT ====="

if pidof openmw-0.51 >/dev/null 2>&1 || pidof openmw >/dev/null 2>&1; then
    echo "ERROR: close Morrowind before generating navmesh tiles."
    exit 20
fi

for f in \
    "$TOOL" \
    "$DEFAULTS" \
    "$PROGRESS" \
    "$MAIN_CFG" \
    "$CFGDIR/openmw.cfg"
do
    if [ ! -e "$f" ]; then
        echo "ERROR: required navmesh runtime file is missing:"
        echo "  $f"
        exit 21
    fi
done

for f in "$TOOL" "$PROGRESS"; do
    if [ ! -x "$f" ]; then
        echo "ERROR: required helper is not executable:"
        echo "  $f"
        exit 22
    fi
done

case "$THREADS" in
    ''|*[!0-9]*|0)
        echo "ERROR: NAVMESH_THREADS must be an integer >= 1."
        exit 23
        ;;
esac

case "$REMOVE_UNUSED" in
    true|false) ;;
    *)
        echo "ERROR: NAVMESH_REMOVE_UNUSED must be true or false."
        exit 24
        ;;
esac

# Keep navmeshtool's executable-local config synchronized with the same
# content profile used by the current game launcher.
cp -f "$MAIN_CFG" "$LOCAL_CFG"
test -s "$LOCAL_CFG"

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/runtime-root}"
mkdir -p "$XDG_RUNTIME_DIR"
chmod 0700 "$XDG_RUNTIME_DIR" 2>/dev/null || true

export XDG_CONFIG_HOME="$CFGDIR"
export XDG_DATA_HOME="$CFGDIR"
export OPENMW_RESOURCES="$ROOT/resources"
export OSG_LIBRARY_PATH="$ROOT/osgPlugins-3.6.5"
export LD_LIBRARY_PATH="$ROOT/lib:$ROOT/libs:$ROOT/lib/aarch64:/mnt/SDCARD/System/lib:/usr/trimui/lib:${LD_LIBRARY_PATH:-}"

cd "$RUNTIME"

HELP="$("$TOOL" --help 2>&1 || true)"
printf '%s\n' "$HELP" | grep -q -- '--process-interior-cells' || {
    echo "ERROR: isolated navmeshtool lacks interior generation."
    exit 25
}

echo "PASS: isolated current-runtime navmeshtool is present."

echo
echo "===== 2/7 VERIFY MATCHING DEFAULTS + FULL INITIALIZATION ====="

base64 -d "$DEFAULTS" > /tmp/tsp-navmesh-defaults.cfg

for required_default in \
    "occlusion culling =" \
    "occlusion buffer width =" \
    "occlusion buffer height ="
do
    grep -Fq "$required_default" /tmp/tsp-navmesh-defaults.cfg || {
        echo "ERROR: navmeshtool private defaults.bin lacks:"
        echo "  $required_default"
        rm -f /tmp/tsp-navmesh-defaults.cfg
        exit 26
    }
done
rm -f /tmp/tsp-navmesh-defaults.cfg

VERSION_LOG="/tmp/tsp-navmesh-version-check.txt"
set +e
"$TOOL" \
    --resources "$ROOT/resources" \
    --config "$CFGDIR" \
    --user-data "$NAVDIR" \
    --version \
    > "$VERSION_LOG" 2>&1
VERSION_RC=$?
set -e

cat "$VERSION_LOG"

if [ "$VERSION_RC" -ne 0 ] || grep -q 'Fatal error:' "$VERSION_LOG"; then
    echo "ERROR: isolated navmeshtool still cannot initialize."
    echo "Version/init output preserved above and in:"
    echo "  $VERSION_LOG"
    exit 27
fi

grep -q 'OpenMW version 0.51.0' "$VERSION_LOG" || {
    echo "ERROR: expected OpenMW 0.51.0 identity not found."
    exit 28
}

rm -f "$VERSION_LOG"
echo "PASS: current navmeshtool + private current defaults initialize together."

echo
echo "===== 3/7 BACK UP CURRENT CANONICAL DATABASE ====="

if [ -s "$DB" ]; then
    STAMP="$(date +%Y%m%d-%H%M%S)"
    BEFORE_SHA="$(sha256sum "$DB" | awk '{print $1}')"
    BACKUP="$BACKUP_DIR/navmesh-before-full-$STAMP.db"

    echo "Current DB:"
    ls -lh "$DB"
    echo "SHA256:"
    echo "  $BEFORE_SHA"
    echo
    echo "Creating verified backup:"
    echo "  $BACKUP"

    cp -p "$DB" "$BACKUP"

    test "$(sha256sum "$BACKUP" | awk '{print $1}')" = "$BEFORE_SHA"

    # Keep only the newest NAVMESH_KEEP_BACKUPS full-generator backups so the
    # 4.9 GB UDISK is not slowly filled by ~500 MB copies.
    if [ "$KEEP_BACKUPS" -ge 1 ] 2>/dev/null; then
        ls -1dt "$BACKUP_DIR"/navmesh-before-full-*.db 2>/dev/null |
        awk -v keep="$KEEP_BACKUPS" 'NR > keep' |
        while IFS= read -r old; do
            [ -n "$old" ] && rm -f "$old"
        done
    fi

    echo "PASS: DB backup SHA verified."
else
    echo "No existing navmesh.db."
    echo "The tool will generate a complete cache from scratch."
fi

echo
echo "===== 4/7 BUILD GENERATION COMMAND ====="

ARGS=(
    --resources "$ROOT/resources"
    --config "$CFGDIR"
    --user-data "$NAVDIR"
    --threads "$THREADS"
    --process-interior-cells true
)

if [ "$REMOVE_UNUSED" = "true" ]; then
    ARGS+=(--remove-unused-tiles)
fi

echo "Command:"
printf '  %q' "$TOOL" "${ARGS[@]}"
printf '\n'

echo
echo "===== 5/7 GENERATE / UPDATE EXTERIORS + ALL INTERIORS ====="

(
    set +e

    echo
    echo "============================================================"
    echo "NAVMESHTOOL STARTED: $(date)"
    echo "============================================================"

    "$TOOL" "${ARGS[@]}"
    rc=$?

    echo
    echo "============================================================"
    echo "NAVMESHTOOL EXIT CODE: $rc"
    echo "NAVMESHTOOL FINISHED:  $(date)"
    echo "============================================================"

    printf '%s\n' "$rc" > "$STATUS_TMP"
    mv -f "$STATUS_TMP" "$STATUS"
    exit "$rc"
) >> "$LOG" 2>&1 &

RUNNER_PID=$!

set +e
"$PROGRESS" "$LOG" "$STATUS" "$DB" 2>> "$LOG"
UI_RC=$?

wait "$RUNNER_PID"
NAV_RC=$?
set -e

if [ -f "$STATUS" ]; then
    read -r FINAL_RC < "$STATUS" || FINAL_RC="$NAV_RC"
else
    FINAL_RC="$NAV_RC"
fi

echo
echo "Progress UI exit: $UI_RC"
echo "Navmeshtool exit: $FINAL_RC"

echo
echo "===== 6/7 VALIDATE DATABASE ====="

if [ ! -s "$DB" ]; then
    echo "ERROR: resulting database is missing or empty."
    exit 29
fi

ls -lh "$DB"
AFTER_SHA="$(sha256sum "$DB" | awk '{print $1}')"
echo "SHA256:"
echo "  $AFTER_SHA"

DB_OK=0
if command -v sqlite3 >/dev/null 2>&1; then
    INTEGRITY="$(sqlite3 "$DB" 'PRAGMA integrity_check;' 2>&1 || true)"
    echo "SQLite integrity:"
    echo "$INTEGRITY"

    if [ "$INTEGRITY" = "ok" ]; then
        DB_OK=1

        echo
        echo "Worldspaces / tiles:"
        sqlite3 -tabs "$DB" \
          'SELECT COUNT(DISTINCT worldspace), COUNT(*) FROM tiles;' \
          2>/dev/null || true
    fi
else
    echo "sqlite3 unavailable; database integrity could not be queried."
fi

if [ "$FINAL_RC" -ne 0 ]; then
    echo
    echo "WARNING: navmeshtool returned $FINAL_RC."

    # The original TSP generator could be killed during its final SQLite
    # VACUUM after writing all generated tiles. Preserve a clean DB rather
    # than automatically restoring over useful completed work.
    if [ "$DB_OK" = 1 ] && grep -q 'Generated navmesh for' "$LOG"; then
        echo "However:"
        echo "  - SQLite integrity is OK"
        echo "  - generation summary exists in the log"
        echo
        echo "The database is being PRESERVED for inspection instead of"
        echo "automatically rolling it back."
    else
        echo "Generation did not meet the safe completed-work criteria."
        exit "$FINAL_RC"
    fi
fi

echo
echo "===== 7/7 COMPLETE ====="

echo "Canonical runtime DB:"
echo "  $DB"
echo
echo "Log:"
echo "  $LOG"
echo
echo "============================================================"
echo "FULL NAVMESH GENERATION FINISHED"
echo "============================================================"

if [ -t 0 ]; then
    echo
    printf "Press Enter to exit..."
    read -r _unused || true
fi
OPENMW_V24_GENERATOR_SH_EOF

    chmod +x "$ACTION_SH" "$WRAPPER_SH" "$GENERATOR_SH"
    for file in "$CPP" "$ACTION_SH" "$WRAPPER_SH" "$GENERATOR_SH"; do
        [ -s "$file" ] || fail 12 "source emission failed: $file"
        echo "EMITTED $(sha_of "$file")  $file"
    done
}

# ============================================================================
# 1. HOST SELF-TESTS (no device, no Docker)
# ============================================================================
host_selftest() {
    need bash; need sha256sum; need awk; need sed; need grep

    bash -n "$ACTION_SH" || fail 13 "manager action shell syntax failed"
    bash -n "$WRAPPER_SH" || fail 13 "manager Ports wrapper syntax failed"
    bash -n "$GENERATOR_SH" || fail 13 "navmesh generator syntax failed"
    echo "PASS shell syntax"

    # --- the generator must be the user's exact file, unmodified ------------
    if [ "$(sha_of "$GENERATOR_SH")" != "$GENERATOR_EXPECTED_SHA" ]; then
        fail 16 "embedded navmesh generator is not byte-identical to the supplied script"
    fi
    echo "PASS navmesh generator is byte-identical to the supplied script"

    # --- structural proof: first-launch setup is storage only ---------------
    if grep -Fq 'default-check' "$ACTION_SH" || grep -Fq 'apply-default' "$ACTION_SH"; then
        fail 16 "first-launch setup still calls the default mod profile backend"
    fi
    awk '/^setup_first_launch\(\) \{/,/^\}/' "$ACTION_SH" > "$TMP/setup-body.txt"
    [ -s "$TMP/setup-body.txt" ] || fail 16 "setup_first_launch body not found"
    for token in install_navmesh install_swap mark-navmesh status; do
        grep -Fq "$token" "$TMP/setup-body.txt" || fail 16 "first-launch setup lost step: $token"
    done
    for token in apply_mods openmw.cfg TSPAtlas; do
        if grep -Fq "$token" "$TMP/setup-body.txt"; then
            fail 16 "first-launch setup must not touch mod configuration: $token"
        fi
    done
    echo "PASS first-launch setup is navmesh + swap only"

    # --- structural proof: progress contract on both sides ------------------
    grep -Fq 'TSP_MANAGER_V24_PROGRESS_CONTRACT' "$ACTION_SH" || fail 16 "progress contract marker missing"
    grep -Fq 'run_with_size_progress' "$ACTION_SH" || fail 16 "byte-accurate progress helper missing"
    grep -Fq '/tmp/openmw-manager-progress' "$ACTION_SH" || fail 16 "backend progress path missing"
    grep -Fq '/tmp/openmw-manager-progress' "$CPP" || fail 16 "UI progress path missing"
    grep -Fq 'TSP_MANAGER_V24_BUSY_PAGE' "$CPP" || fail 16 "UI progress overlay missing"
    grep -Fq 'TSP_MANAGER_V24_REPORT_PAGE' "$CPP" || fail 16 "UI result page missing"
    grep -Fq 'INTEGRATED V2.4' "$CPP" || fail 16 "V2.4 UI marker missing"
    grep -Fq 'SETUP GAME FOR FIRST LAUNCH' "$CPP" || fail 16 "first-launch menu entry missing"
    grep -Fq '"$BACKEND" status || true' "$WRAPPER_SH" && \
        grep -Eq '^[[:space:]]*"\$BACKEND" status \|\| true$' "$WRAPPER_SH" && \
        fail 16 "wrapper still runs a blind pre-UI scan"
    grep -Fq 'OPENMW_MANAGER_PROGRESS' "$WRAPPER_SH" || fail 16 "wrapper does not export the progress path"
    grep -Fq 'TSP_MANAGER_V24_PENDING_REPORT' "$CPP" || fail 16 "UI cannot consume a handed-back outcome"
    echo "PASS progress contract and menu markers"

    # --- structural proof: the navmesh builder hands off correctly ----------
    grep -Fq 'TSP_MANAGER_V24_LAUNCH_ENV_SNAPSHOT' "$WRAPPER_SH" || fail 16 "launch environment snapshot missing"
    grep -Fq 'export -p > "$LAUNCH_ENV"' "$WRAPPER_SH" || fail 16 "launch environment is never captured"
    grep -Fq 'TSP_MANAGER_V24_GENERATOR_HANDOFF' "$WRAPPER_SH" || fail 16 "generator handoff marker missing"
    grep -Fq 'run_with_launch_env "$LAUNCH_ENV" "$generator"' "$WRAPPER_SH" \
        || fail 16 "the navmesh build does not use the pristine launch environment"
    grep -Fq 'report "NAVMESH BUILDER"' "$WRAPPER_SH" || fail 16 "navmesh build outcome is never reported back"
    if grep -Fq '[ -x "$candidate" ]' "$WRAPPER_SH"; then
        fail 16 "generator discovery still depends on an execute bit"
    fi
    echo "PASS navmesh builder handoff structure"

    # --- executable proof: pristine environment reaches the generator -------
    awk '/^run_with_launch_env\(\) \{/,/^\}/' "$WRAPPER_SH" > "$TMP/handoff.sh"
    [ -s "$TMP/handoff.sh" ] || fail 16 "run_with_launch_env body not found"
    grep -Fq 'env -i' "$TMP/handoff.sh" || fail 16 "generator handoff does not isolate the environment"
    printf 'declare -x TSP_LAUNCH_MARKER="from-launch"\ndeclare -x PATH="%s"\n' "$PATH" > "$TMP/launch-env"
    cat > "$TMP/probe.sh" <<'PROBE_EOF'
#!/bin/bash
printf 'MARKER=%s\n' "${TSP_LAUNCH_MARKER:-none}"
printf 'POISON=%s\n' "${TSP_MANAGER_POISON:-none}"
printf 'LDP=%s\n' "${LD_PRELOAD:-none}"
printf 'SDLRD=%s\n' "${SDL_RENDER_DRIVER:-none}"
PROBE_EOF
    chmod +x "$TMP/probe.sh"
    (
        . "$TMP/handoff.sh"
        export TSP_MANAGER_POISON=manager LD_PRELOAD=/poison/libgl.so SDL_RENDER_DRIVER=software
        run_with_launch_env "$TMP/launch-env" "$TMP/probe.sh"
    ) > "$TMP/handoff-out.txt" 2>&1
    # The harness deliberately sets a fake LD_PRELOAD; any loader warning about
    # it only proves the poison was really present in the manager environment.
    grep -E '^(MARKER|POISON|LDP|SDLRD)=' "$TMP/handoff-out.txt" || true
    grep -Fqx 'MARKER=from-launch' "$TMP/handoff-out.txt" || fail 16 "generator does not receive the launch environment"
    grep -Fqx 'POISON=none' "$TMP/handoff-out.txt" || fail 16 "manager environment leaked into the generator"
    grep -Fqx 'LDP=none' "$TMP/handoff-out.txt" || fail 16 "LD_PRELOAD leaked into the generator"
    grep -Fqx 'SDLRD=none' "$TMP/handoff-out.txt" || fail 16 "manager SDL override leaked into the generator"
    echo "PASS generator runs with the pristine Ports launch environment"

    # --- executable proof: the handed-back outcome contract matches ---------
    awk '/^report\(\) \{/,/^\}/' "$WRAPPER_SH" > "$TMP/report-fn.sh"
    [ -s "$TMP/report-fn.sh" ] || fail 16 "report() body not found in the wrapper"
    ( REPORT="$TMP/pending-report"; . "$TMP/report-fn.sh"; report "NAVMESH BUILDER" 1 0 )
    [ -s "$TMP/pending-report" ] || fail 16 "report() did not publish a pending report"
    [ -e "$TMP/pending-report.tmp" ] && fail 16 "report() left its temp file behind"
    for key in heading ok code; do
        grep -Eq "^$key=" "$TMP/pending-report" || fail 16 "pending report is missing key: $key"
        grep -Fq "\"$key\"" "$CPP" || fail 16 "the UI never reads pending report key: $key"
    done
    grep -Fqx 'heading=NAVMESH BUILDER' "$TMP/pending-report" || fail 16 "pending report heading is wrong"
    grep -Fqx 'ok=1' "$TMP/pending-report" || fail 16 "pending report success flag is wrong"
    echo "PASS handed-back outcome contract matches on both sides"

    # --- executable proof: backend progress behaviour -----------------------
    "$ACTION_SH" selftest | tee "$TMP/action-selftest.txt"
    grep -Fq OPENMW_MANAGER_V24_ACTION_SELFTEST_PASS "$TMP/action-selftest.txt" \
        || fail 14 "manager action behaviour selftest failed"
    echo "PASS action backend behaviour selftest"

    # --- executable proof: UI child/progress handling ------------------------
    if command -v g++ >/dev/null 2>&1; then
        g++ -std=c++17 -O2 -Wall -Wextra -Wpedantic -Werror "$CPP" -o "$TMP/manager-host-test" -ldl \
            || fail 15 "host C++ compile failed"
        "$TMP/manager-host-test" --selftest | tee "$TMP/cpp-selftest.txt"
        grep -Fq OPENMW51_MANAGER_V2_SELFTEST_PASS "$TMP/cpp-selftest.txt" || fail 15 "C++ legacy selftest marker missing"
        grep -Fq OPENMW_MANAGER_V24_PROGRESS_SELFTEST_PASS "$TMP/cpp-selftest.txt" || fail 15 "C++ progress selftest failed"
        echo "PASS warning-clean host C++ compile + child/progress selftest"
        echo "INFO SDL presentation is device-only; Ubuntu is never asked to provide SDL2"
    else
        echo "INFO host g++ unavailable; Docker ARM64 compile remains mandatory"
    fi

    # --- no legacy paths reintroduced ---------------------------------------
    if grep -En '/mnt/SDCARD/data/ports/openmw51|/mnt/UDISK/openmw51|config-0\.51|savegame-0\.51|texcache-0\.51|Morrowind_51|OpenMW_51' \
        "$CPP" "$ACTION_SH" "$WRAPPER_SH" > "$TMP/legacy-paths.txt"; then
        cat "$TMP/legacy-paths.txt"
        fail 16 "legacy 51 path/name reintroduced"
    fi
    grep -Fq '/mnt/UDISK/openmw-swapfile' "$ACTION_SH" || fail 16 "clean swap target missing"
    echo "PASS clean-layout path audit"
}

# ============================================================================
# collect / rollback
# ============================================================================
collect_action() {
    ensure_ssh
    local out="$HOST_DIR/openmw-manager-v24-diagnostics-$STAMP.tar.gz"
    ssh "$DEV" 'bash -s' -- "$ROOT" "$NAVDIR" <<'REMOTE_COLLECT' > "$TMP/device-diagnostics.txt" 2>&1
set -u
ROOT="$1"; NAVDIR="$2"
echo '===== INSTALLED MANAGER FILES ====='
for f in "$ROOT/bin/openmw-manager-v2" "$ROOT/launcher/openmw-manager-action-v2.sh" "$ROOT/launcher/openmw-launcher-backend-v2.py"; do
    [ -e "$f" ] && { ls -l "$f"; sha256sum "$f"; }
done
for p in /mnt/SDCARD/Roms/PORTS /mnt/sdcard/mmcblk1p1/Roms/PORTS; do
    for entry in OpenMW_Manager.sh OpenMW_Generate_Full_Navmesh_3Worker.sh Morrowind.sh; do
        [ -f "$p/$entry" ] && { ls -l "$p/$entry"; sha256sum "$p/$entry"; }
    done
done
echo '===== NAVMESH GENERATOR RUNTIME ====='
ls -l "$ROOT/bin/openmw-navmesh-progress" "$ROOT/navmesh-tool-runtime/openmw-navmeshtool" "$ROOT/navmesh-tool-runtime/defaults.bin" 2>/dev/null || true
echo '===== LAUNCH ENV SNAPSHOT ====='; cat "$ROOT/launcher/.launch-env" 2>/dev/null || echo 'none'
echo '===== PENDING REPORT ====='; cat "$ROOT/launcher/pending-report" 2>/dev/null || echo 'none'
echo '===== GENERATOR LOG TAIL ====='; tail -200 "$ROOT/navmesh-generation-full-3worker.log" 2>/dev/null || echo 'none' 
echo '===== MANAGER VERSION MARKERS ====='
grep -Fc 'TSP_MANAGER_V24_PROGRESS_BACKEND' "$ROOT/launcher/openmw-manager-action-v2.sh" 2>/dev/null || true
strings "$ROOT/bin/openmw-manager-v2" 2>/dev/null | grep -F 'INTEGRATED V2' || true
echo '===== PROGRESS FILE (LIVE OR STALE) ====='; cat /tmp/openmw-manager-progress 2>/dev/null || echo 'none'
echo '===== MANAGER STATUS ====='; cat "$ROOT/launcher/status.conf" 2>/dev/null || true
echo '===== LAST RESULT ====='; cat "$ROOT/launcher/last-result.txt" 2>/dev/null || true
echo '===== DEFAULT SETUP ASSETS ====='; ls -lh "$ROOT/defaults/base-navmesh.db" "$ROOT/defaults/base-swapfile" 2>/dev/null || true
echo '===== DEFAULT NAVMESH CANDIDATES ====='; cat "$ROOT/launcher/default-navmesh-candidates.txt" 2>/dev/null || true
echo '===== UDISK TARGETS ====='; ls -lh "$NAVDIR/navmesh.db" "$NAVDIR/profile.sha256" /mnt/UDISK/openmw-swapfile 2>/dev/null || true
df -h /mnt/UDISK 2>/dev/null || true
cat /proc/swaps 2>/dev/null || true
echo '===== MOD PLAN ====='; cat "$ROOT/launcher/modplan.tsv" 2>/dev/null || true
echo '===== ENABLED DATA ROOTS IN OPENMW.CFG ====='; grep -E '^(data|content)=' "$ROOT/openmw.cfg" 2>/dev/null || true
echo '===== MANAGER PROCESSES / LOCKS ====='
ps w 2>/dev/null | grep -E '[o]penmw-manager-v2|OpenMW_Manager' || true
for f in "$ROOT/launcher/manager-v2-wrapper.pid" "$ROOT/launcher/manager-v2-ui.pid" "$ROOT/launcher/ui-ready"; do
    [ -f "$f" ] && { echo "[$f]"; cat "$f" 2>/dev/null || true; }
done
echo '===== MANAGER LOG TAIL ====='; tail -500 "$ROOT/launcher/manager-v2.log" 2>/dev/null || true
REMOTE_COLLECT
    cp "$STATE" "$TMP/install.state" 2>/dev/null || true
    tar -C "$TMP" -czf "$out" device-diagnostics.txt install.state 2>/dev/null \
        || tar -C "$TMP" -czf "$out" device-diagnostics.txt
    echo
    cat "$TMP/device-diagnostics.txt"
    echo
    echo "PASS manager diagnostics archive: $out"
}

rollback_action() {
    ensure_ssh
    [ -s "$STATE" ] || fail 21 "install state missing: $STATE"
    local backup
    backup="$(state_value "$STATE" DEVICE_BACKUP)"
    [ -n "$backup" ] || fail 21 "install state has no backup path"
    ssh "$DEV" 'bash -s' -- "$backup" <<'REMOTE_ROLLBACK' || fail 22 "V2.4 rollback failed"
set -u
B="$1"
[ -s "$B/manifest" ] || { echo "ERROR backup manifest missing: $B/manifest"; exit 1; }
if pidof openmw-manager-v2 >/dev/null 2>&1; then echo 'ERROR close the Manager on the device first'; exit 2; fi
while IFS='|' read -r target key; do
    [ -n "$target" ] || continue
    if [ -f "$B/$key.present" ]; then cp -p "$B/$key" "$target" || exit 3; else rm -f "$target" || exit 4; fi
done < "$B/manifest"
sync
echo 'PASS exact pre-V2.4 manager binary, action backend and Ports wrapper restored.'
REMOTE_ROLLBACK
    echo "PASS rollback complete"
}

case "$ACTION" in
    emit) emit_sources; exit 0;;
    selftest) emit_sources; host_selftest; echo; echo "PASS all host self-tests"; exit 0;;
    collect) collect_action; exit 0;;
    rollback) rollback_action; exit 0;;
    install) ;;
    *) fail 2 "usage: $0 [install|selftest|emit|collect|rollback]";;
esac

exec > >(tee "$WORK/openmw-manager-v24-install-$STAMP.log") 2>&1

cat <<'BANNER'
============================================================
OPENMW 0.51 TSP — MANAGER V2.4
SETUP PROGRESS OVERLAY + STORAGE-ONLY FIRST LAUNCH
============================================================
Replaces exactly four device files:
  <root>/bin/openmw-manager-v2
  <root>/launcher/openmw-manager-action-v2.sh
  <PORTS>/OpenMW_Manager.sh
  <PORTS>/OpenMW_Generate_Full_Navmesh_3Worker.sh  (verbatim, as supplied)

Never touched: openmw.cfg, mods, saves, navmesh.db, swapfile,
Morrowind.sh, the Python backend, the clean-path migrator.
============================================================
BANNER

echo
echo "===== 1/7 EMIT SOURCES AND RUN HOST SELF-TESTS ====="
emit_sources
host_selftest

need docker; need file; ensure_ssh
docker inspect "$CTR" >/dev/null 2>&1 || fail 24 "Docker container not found: $CTR"
if [ "$(docker inspect -f '{{.State.Running}}' "$CTR" 2>/dev/null || true)" != true ]; then
    docker start "$CTR" >/dev/null || fail 24 "could not start Docker container: $CTR"
fi
echo "PASS Docker: $CTR"

echo
echo "===== 2/7 DEVICE READ-ONLY PREFLIGHT ====="
if ! ssh "$DEV" 'bash -s' -- "$ROOT" <<'REMOTE_PREFLIGHT' > "$TMP/device-preflight.txt" 2>&1
set -u
ROOT="$1"
[ -d "$ROOT" ] || { echo "ERROR game root missing: $ROOT"; exit 1; }
[ -s "$ROOT/openmw.cfg" ] || { echo "ERROR missing $ROOT/openmw.cfg"; exit 2; }
[ -x "$ROOT/bin/openmw-manager-v2" ] || { echo "ERROR Manager V2 is not installed: $ROOT/bin/openmw-manager-v2"; exit 3; }
[ -x "$ROOT/launcher/openmw-launcher-backend-v2.py" ] || { echo "ERROR Python backend missing"; exit 4; }
[ -x "$ROOT/launcher/openmw-manager-action-v2.sh" ] || { echo "ERROR action backend missing"; exit 5; }
PORT=""
for candidate in /mnt/SDCARD/Roms/PORTS /mnt/sdcard/mmcblk1p1/Roms/PORTS; do [ -d "$candidate" ] && PORT="$candidate" && break; done
[ -n "$PORT" ] || { echo 'ERROR PORTS directory not found'; exit 6; }
[ -f "$PORT/OpenMW_Manager.sh" ] || { echo "ERROR $PORT/OpenMW_Manager.sh missing"; exit 7; }
if [ -f "$PORT/OpenMW_Generate_Full_Navmesh_3Worker.sh" ]; then
    echo 'Installed three-worker generator (replaced with the supplied copy):'
    ls -l "$PORT/OpenMW_Generate_Full_Navmesh_3Worker.sh"
    sha256sum "$PORT/OpenMW_Generate_Full_Navmesh_3Worker.sh"
else
    echo 'NOTE the three-worker generator Ports entry is absent; it will be installed'
fi
[ -x "$ROOT/bin/openmw-navmesh-progress" ] || echo 'WARNING bin/openmw-navmesh-progress is missing or not executable; the generator preflight will stop before its progress window'
[ -d "$ROOT/navmesh-tool-runtime" ] || echo 'WARNING navmesh-tool-runtime is missing; the generator will stop in its own preflight'

if pidof openmw-0.51 >/dev/null 2>&1; then echo 'ERROR close Morrowind first'; exit 8; fi
if pidof openmw-manager-v2 >/dev/null 2>&1; then echo 'ERROR close the OpenMW Manager on the device first'; exit 9; fi
if pidof openmw-navmeshtool >/dev/null 2>&1; then echo 'ERROR navmesh generation is running'; exit 10; fi
echo "PASS game root: $ROOT"
echo "PASS Ports directory: $PORT"
echo 'Installed manager artifacts:'
sha256sum "$ROOT/bin/openmw-manager-v2" "$ROOT/launcher/openmw-manager-action-v2.sh" "$PORT/OpenMW_Manager.sh"
echo 'Reusable first-launch assets:'
ls -lh "$ROOT/defaults/base-navmesh.db" "$ROOT/defaults/base-swapfile" 2>/dev/null || echo '  (none found in defaults/)'
REMOTE_PREFLIGHT
then
    cat "$TMP/device-preflight.txt"
    fail 25 "device preflight failed; nothing was changed"
fi
cat "$TMP/device-preflight.txt"

echo
echo "===== 3/7 BUILD ARM64 MANAGER (FULL OUTPUT) ====="
docker cp "$CPP" "$CTR:/tmp/openmw_launcher_manager_v24.cpp" || fail 26 "could not stage C++ source into Docker"
if ! docker exec -i "$CTR" bash -s <<'REMOTE_BUILD' 2>&1 | tee "$BUILD_LOG"
set -u
CXX=""
for cache in /root/openmw-0.51-tsp-build/CMakeCache.txt /root/openmw-0.51-tsp-build/CMakeFiles/*/CMakeCXXCompiler.cmake; do
    [ -f "$cache" ] || continue
    candidate="$(sed -n 's/^CMAKE_CXX_COMPILER:FILEPATH=//p;s/^set(CMAKE_CXX_COMPILER "\([^"]*\)".*$/\1/p' "$cache" | head -1)"
    [ -x "$candidate" ] || continue
    case "$($candidate -dumpmachine 2>/dev/null || true)" in aarch64*|arm64*) CXX="$candidate"; break;; esac
done
for candidate in aarch64-linux-gnu-g++ aarch64-none-linux-gnu-g++ g++-13 g++ c++; do
    [ -z "$CXX" ] || break
    command -v "$candidate" >/dev/null 2>&1 || continue
    case "$($candidate -dumpmachine 2>/dev/null || true)" in aarch64*|arm64*) CXX="$candidate"; break;; esac
done
[ -n "$CXX" ] || { echo 'FAIL no ARM64 C++ compiler found'; exit 20; }
echo "Compiler: $CXX ($($CXX -dumpmachine))"
rm -f /tmp/openmw-manager-v2-v24
"$CXX" -std=c++17 -O2 -Wall -Wextra -Wpedantic -static-libstdc++ -static-libgcc \
    /tmp/openmw_launcher_manager_v24.cpp -o /tmp/openmw-manager-v2-v24 -ldl || exit 21
[ -x /tmp/openmw-manager-v2-v24 ] || exit 22
file /tmp/openmw-manager-v2-v24
sha256sum /tmp/openmw-manager-v2-v24
REMOTE_BUILD
then
    fail 27 "ARM64 manager build failed; full log: $BUILD_LOG"
fi
docker cp "$CTR:/tmp/openmw-manager-v2-v24" "$HOST_BIN" || fail 28 "Docker-to-Ubuntu copy failed"
chmod +x "$HOST_BIN"
case "$(file "$HOST_BIN")" in *aarch64*|*ARM64*|*ARM\ aarch64*) ;; *) fail 28 "output is not ARM64: $(file "$HOST_BIN")";; esac

BIN_SHA="$(sha_of "$HOST_BIN")"
ACTION_SHA="$(sha_of "$ACTION_SH")"
WRAPPER_SHA="$(sha_of "$WRAPPER_SH")"
GENERATOR_SHA="$(sha_of "$GENERATOR_SH")"
for value in "$BIN_SHA" "$ACTION_SHA" "$WRAPPER_SHA" "$GENERATOR_SHA"; do valid_sha "$value" || fail 29 "invalid artifact SHA"; done
echo "PASS ARM64 manager binary: $BIN_SHA"
echo "PASS action backend:       $ACTION_SHA"
echo "PASS Ports wrapper:        $WRAPPER_SHA"
echo "PASS navmesh generator:    $GENERATOR_SHA"

echo
echo "===== 4/7 ALREADY-INSTALLED CHECK ====="
if ssh "$DEV" 'bash -s' -- "$ROOT" "$BIN_SHA" "$ACTION_SHA" "$WRAPPER_SHA" "$GENERATOR_SHA" <<'REMOTE_IDENTITY' >/dev/null 2>&1
set -u
ROOT="$1"; BIN_SHA="$2"; ACTION_SHA="$3"; WRAPPER_SHA="$4"; GENERATOR_SHA="$5"
PORT=""
for candidate in /mnt/SDCARD/Roms/PORTS /mnt/sdcard/mmcblk1p1/Roms/PORTS; do [ -d "$candidate" ] && PORT="$candidate" && break; done
check(){ [ "$(sha256sum "$1" | awk '{print $1}')" = "$2" ]; }
check "$ROOT/bin/openmw-manager-v2" "$BIN_SHA" || exit 1
check "$ROOT/launcher/openmw-manager-action-v2.sh" "$ACTION_SHA" || exit 1
check "$PORT/OpenMW_Manager.sh" "$WRAPPER_SHA" || exit 1
check "$PORT/OpenMW_Generate_Full_Navmesh_3Worker.sh" "$GENERATOR_SHA" || exit 1
REMOTE_IDENTITY
then
    echo "This exact Manager V2.4 build is already installed on $DEV."
    echo "Nothing was changed. This is a clean already-installed result, not an error."
    exit 0
fi
echo "PASS this build differs from what is installed; proceeding"

echo
echo "===== 5/7 BACK UP THE THREE REPLACED FILES ====="
DEVICE_BACKUP="$ROOT/launcher/install-backups/manager-v24-before-$STAMP"
ssh "$DEV" 'bash -s' -- "$ROOT" "$DEVICE_BACKUP" <<'REMOTE_BACKUP' || fail 30 "device backup failed"
set -u
ROOT="$1"; B="$2"
PORT=""
for candidate in /mnt/SDCARD/Roms/PORTS /mnt/sdcard/mmcblk1p1/Roms/PORTS; do [ -d "$candidate" ] && PORT="$candidate" && break; done
[ -n "$PORT" ] || exit 1
mkdir -p "$B" || exit 2
printf '%s\n' "$PORT" > "$B/ports-dir"
: > "$B/manifest"
backup(){ target="$1"; key="$2"; printf '%s|%s\n' "$target" "$key" >> "$B/manifest"; if [ -e "$target" ]; then cp -p "$target" "$B/$key" || exit 3; touch "$B/$key.present"; fi; }
backup "$ROOT/bin/openmw-manager-v2" manager-bin
backup "$ROOT/launcher/openmw-manager-action-v2.sh" manager-action
backup "$PORT/OpenMW_Manager.sh" manager-wrapper
backup "$PORT/OpenMW_Generate_Full_Navmesh_3Worker.sh" navmesh-generator
sync
echo "PASS verified backup: $B"
sha256sum "$B/manager-bin" "$B/manager-action" "$B/manager-wrapper" "$B/navmesh-generator" 2>/dev/null || true
REMOTE_BACKUP

echo
echo "===== 6/7 STAGE, INSTALL TRANSACTIONALLY AND SELF-TEST ON DEVICE ====="
scp -q "$HOST_BIN" "$DEV:$ROOT/launcher/.v24-manager-bin.incoming" || fail 31 "binary upload failed"
scp -q "$ACTION_SH" "$DEV:$ROOT/launcher/.v24-manager-action.incoming" || fail 31 "action backend upload failed"
scp -q "$WRAPPER_SH" "$DEV:$ROOT/launcher/.v24-manager-wrapper.incoming" || fail 31 "wrapper upload failed"
scp -q "$GENERATOR_SH" "$DEV:$ROOT/launcher/.v24-navmesh-generator.incoming" || fail 31 "generator upload failed"

if ! ssh "$DEV" 'bash -s' -- "$ROOT" "$DEVICE_BACKUP" "$BIN_SHA" "$ACTION_SHA" "$WRAPPER_SHA" "$GENERATOR_SHA" <<'REMOTE_INSTALL'
set -u
ROOT="$1"; B="$2"; BIN_SHA="$3"; ACTION_SHA="$4"; WRAPPER_SHA="$5"; GENERATOR_SHA="$6"
PORT="$(cat "$B/ports-dir")"; stage="$ROOT/launcher"
check(){ [ "$(sha256sum "$1" | awk '{print $1}')" = "$2" ]; }
check "$stage/.v24-manager-bin.incoming" "$BIN_SHA" || exit 1
check "$stage/.v24-manager-action.incoming" "$ACTION_SHA" || exit 2
check "$stage/.v24-manager-wrapper.incoming" "$WRAPPER_SHA" || exit 3
check "$stage/.v24-navmesh-generator.incoming" "$GENERATOR_SHA" || exit 19
bash -n "$stage/.v24-manager-action.incoming" || exit 4
bash -n "$stage/.v24-manager-wrapper.incoming" || exit 5
bash -n "$stage/.v24-navmesh-generator.incoming" || exit 20

# Prove the staged artifacts behave on this device BEFORE they are published.
chmod +x "$stage/.v24-manager-bin.incoming" "$stage/.v24-manager-action.incoming"
"$stage/.v24-manager-bin.incoming" --selftest > "$stage/.v24-bin-selftest.txt" 2>&1 || exit 6
grep -Fq OPENMW_MANAGER_V24_PROGRESS_SELFTEST_PASS "$stage/.v24-bin-selftest.txt" || exit 7
"$stage/.v24-manager-action.incoming" selftest > "$stage/.v24-action-selftest.txt" 2>&1 || exit 8
grep -Fq OPENMW_MANAGER_V24_ACTION_SELFTEST_PASS "$stage/.v24-action-selftest.txt" || exit 9

install -m 755 "$stage/.v24-manager-bin.incoming" "$ROOT/bin/openmw-manager-v2" || exit 10
install -m 755 "$stage/.v24-manager-action.incoming" "$ROOT/launcher/openmw-manager-action-v2.sh" || exit 11
install -m 755 "$stage/.v24-manager-wrapper.incoming" "$PORT/OpenMW_Manager.sh" || exit 12
install -m 755 "$stage/.v24-navmesh-generator.incoming" "$PORT/OpenMW_Generate_Full_Navmesh_3Worker.sh" || exit 21
check "$ROOT/bin/openmw-manager-v2" "$BIN_SHA" || exit 13
check "$ROOT/launcher/openmw-manager-action-v2.sh" "$ACTION_SHA" || exit 14
check "$PORT/OpenMW_Manager.sh" "$WRAPPER_SHA" || exit 15
check "$PORT/OpenMW_Generate_Full_Navmesh_3Worker.sh" "$GENERATOR_SHA" || exit 22

# Installed-state proof, including the untouched Python backend.
"$ROOT/bin/openmw-manager-v2" --selftest | grep -Fq OPENMW_MANAGER_V24_PROGRESS_SELFTEST_PASS || exit 16
"$ROOT/launcher/openmw-manager-action-v2.sh" selftest | grep -Fq OPENMW_MANAGER_V24_ACTION_SELFTEST_PASS || exit 17
OPENMW_GAMEDIR="$ROOT" "$ROOT/launcher/openmw-launcher-backend-v2.py" selftest \
    | grep -Fq OPENMW51_MANAGER_BACKEND_V2_SELFTEST_PASS || exit 18

rm -f "$stage"/.v24-*.incoming "$stage"/.v24-*-selftest.txt
rm -f /tmp/openmw-manager-progress /tmp/openmw-manager-progress.tmp
sync
echo "PASS Manager V2.4 installed and self-tested on device"
ls -l "$ROOT/bin/openmw-manager-v2" "$ROOT/launcher/openmw-manager-action-v2.sh" \
      "$PORT/OpenMW_Manager.sh" "$PORT/OpenMW_Generate_Full_Navmesh_3Worker.sh"
REMOTE_INSTALL
then
    echo "ERROR install failed; restoring the exact previous three files" >&2
    ssh "$DEV" 'bash -s' -- "$DEVICE_BACKUP" "$ROOT" <<'REMOTE_RECOVER' || true
set -u
B="$1"; ROOT="$2"
while IFS='|' read -r target key; do
    [ -n "$target" ] || continue
    if [ -f "$B/$key.present" ]; then cp -p "$B/$key" "$target"; else rm -f "$target"; fi
done < "$B/manifest"
rm -f "$ROOT/launcher"/.v24-*.incoming "$ROOT/launcher"/.v24-*-selftest.txt
sync
echo 'Previous manager files restored.'
REMOTE_RECOVER
    fail 32 "transactional device install failed; exact previous manager restored"
fi

cat > "$STATE" <<EOF_STATE
DEVICE_BACKUP='$DEVICE_BACKUP'
BIN_SHA='$BIN_SHA'
ACTION_SHA='$ACTION_SHA'
WRAPPER_SHA='$WRAPPER_SHA'
GENERATOR_SHA='$GENERATOR_SHA'
EOF_STATE
[ -s "$STATE" ] || fail 34 "could not save host rollback state"

echo
echo "===== 7/7 DEVICE STATE AND LOG PULL ====="
ssh "$DEV" 'bash -s' -- "$ROOT" <<'REMOTE_LOGS' || true
set -u
ROOT="$1"
echo '--- current manager status.conf ---'
cat "$ROOT/launcher/status.conf" 2>/dev/null || echo '(not scanned yet)'
echo
echo '--- last result ---'
cat "$ROOT/launcher/last-result.txt" 2>/dev/null || echo '(none)'
echo
echo '--- reusable first-launch assets ---'
ls -lh "$ROOT/defaults/base-navmesh.db" "$ROOT/defaults/base-swapfile" 2>/dev/null || echo '(none found in defaults/)'
echo
echo '--- UDISK ---'
df -h /mnt/UDISK 2>/dev/null || true
ls -lh /mnt/UDISK/openmw-nav/navmesh.db /mnt/UDISK/openmw-swapfile 2>/dev/null || echo '(navmesh/swap not installed yet)'
cat /proc/swaps 2>/dev/null || true
echo
echo '--- manager log tail (last 120 lines) ---'
tail -120 "$ROOT/launcher/manager-v2.log" 2>/dev/null || echo '(no log yet)'
REMOTE_LOGS

echo
echo "============================================================"
echo "MANAGER V2.4 INSTALLED"
echo "============================================================"
echo "Binary SHA:    $BIN_SHA"
echo "Action SHA:    $ACTION_SHA"
echo "Wrapper SHA:   $WRAPPER_SHA"
echo "Generator SHA: $GENERATOR_SHA"
echo
echo "On the device: Ports -> OpenMW_Manager -> SETUP STORAGE ->"
echo "SETUP GAME FOR FIRST LAUNCH."
echo "Expected: STEP 1 OF 3 copying the navmesh with a moving byte-accurate"
echo "bar, STEP 2 OF 3 swap, STEP 3 OF 3 profile + status, then a COMPLETE"
echo "page you dismiss with A."
echo
echo "NAVMESH BUILDER -> BUILD / UPDATE CURRENT MOD PROFILE now closes the"
echo "menu and shows the generator's own progress window, exactly as the"
echo "OpenMW_Generate_Full_Navmesh_3Worker Ports entry does. The menu comes"
echo "back afterwards with a COMPLETE or FAILED page carrying its exit code."
echo
echo "Diagnostics with full log:   $0 collect"
echo "Undo exactly this install:   $0 rollback"
echo "Sources kept in:             $WORK"
echo "============================================================"
