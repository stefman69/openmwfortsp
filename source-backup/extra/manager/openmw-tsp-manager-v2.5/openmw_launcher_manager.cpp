// OpenMW 0.51 TrimUI Smart Pro Manager V2.5
// V2.4: long backend actions run as a child of this UI process while the SDL
// window stays alive, so setup shows a live progress overlay instead of a black
// screen. First-launch setup is storage only (navmesh + swap).
// V2.5: the navmesh build is one of those actions. The generator runs headless
// and this UI draws its progress, so the build is visible from its first second
// instead of handing the screen to a window that only appears near the end.
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
// Only leaving for the game or quitting still replaces this UI.
static bool handoffRequest(const std::string&cmd){return cmd=="play"||cmd=="exit";}
static void dispatch(App&a,const std::string&cmd){if(handoffRequest(cmd))request(a,cmd);else{saveUi(a);a.localAction=cmd;}}
static void confirm(App&a,Page back,const std::string&q,const std::string&cmd){a.returnPage=back;a.question=q;a.pending=cmd;a.page=Page::Confirm;}

static void header(Framebuffer&f){f.rect(0,0,f.width(),68,{9,10,12});label(f,"OPENMW 0.51",28,18,3,ACC);label(f,"TRIMUI SMART PRO MANAGER",270,25,2,FG);label(f,"INTEGRATED V2.5",1010,25,2,DIM);f.rect(0,68,f.width(),2,ACC);}
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
    label(f,"BUILD RUNS THE THREE-WORKER GENERATOR AND SHOWS ITS CELL AND TILE",390,545,1,DIM);
    label(f,"PROGRESS HERE. A FULL REBUILD CAN TAKE A LONG TIME.",390,570,1,DIM);label(f,"A SELECT   B BACK",390,622,1,DIM);
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
    else if(cmd=="startup") simple("startup","STARTING UP: SWAP AND DEVICE SCAN",false);
    else if(cmd=="build-navmesh") simple("build-navmesh","BUILDING THE NAVMESH FOR THE CURRENT MODS",true);
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
    if(!handoffRequest("play")||!handoffRequest("exit"))
    { std::cerr<<"selftest: handoff requests misclassified\n"; return 1; }
    if(handoffRequest("setup-first-launch")||handoffRequest("install-navmesh")
       ||handoffRequest("install-swap")||handoffRequest("build-navmesh"))
    { std::cerr<<"selftest: long action wrongly left the UI\n"; return 1; }
    Command build=parseCommand("build-navmesh");
    if(!build.valid||build.args.size()!=1||build.args[0]!="build-navmesh"||!build.acknowledge)
    { std::cerr<<"selftest: navmesh build command mapping failed\n"; return 1; }
    Command boot=parseCommand("startup");
    if(!boot.valid||boot.args.size()!=1||boot.args[0]!="startup")
    { std::cerr<<"selftest: startup command mapping failed\n"; return 1; }
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
        runLocalAction(a,fb,in,"startup");
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
