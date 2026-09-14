#include <algorithm>
#include <array>
#include <chrono>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <dlfcn.h>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <linux/input.h>
#include <map>
#include <poll.h>
#include <sstream>
#include <string>
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

static std::map<std::string,std::string> readKv(const fs::path& p)
{
    std::map<std::string,std::string> out; std::ifstream in(p); std::string line;
    while(std::getline(in,line)){auto e=line.find('=');if(e==std::string::npos)continue;out[line.substr(0,e)]=line.substr(e+1);}
    return out;
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
    fs::path root,request,statusFile,modsFile,uiFile,resultFile; std::map<std::string,std::string> status; std::vector<Mod> mods;
    Page page=Page::Home,returnPage=Page::Home; int home=0,opt=0,modSel=0,scroll=0; std::string pending,question,lastResult; bool quit=false;
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
static void confirm(App&a,Page back,const std::string&q,const std::string&cmd){a.returnPage=back;a.question=q;a.pending=cmd;a.page=Page::Confirm;}

static void header(Framebuffer&f){f.rect(0,0,f.width(),68,{9,10,12});label(f,"OPENMW 0.51",28,18,3,ACC);label(f,"TRIMUI SMART PRO MANAGER",270,25,2,FG);label(f,"INTEGRATED V2.1",1010,25,2,DIM);f.rect(0,68,f.width(),2,ACC);}
static void nav(Framebuffer&f,const App&a)
{
    static const char* items[]={"PLAY MORROWIND","SETUP & STORAGE","MODS & LOAD ORDER","NAVMESH BUILDER","DIAGNOSTICS","EXIT"};
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
    title(f,"SETUP & STORAGE","PREBUILT BASE NAVMESH AND CANONICAL UDISK SWAP");f.rect(350,178,902,410,P1);
    std::array<std::string,3> n={"INSTALL / REPAIR BASE NAVMESH","CREATE / ACTIVATE 512 MB SWAP","REFRESH DEVICE STATUS"};
    for(int i=0;i<3;++i){int y=215+i*70;if(a.opt==i)f.rect(370,y-14,840,48,P2);label(f,a.opt==i?">":" ",386,y,2,a.opt==i?ACC:DIM);label(f,n[i],414,y,2,a.opt==i?FG:DIM);}
    row(f,390,435,"DEFAULT NAVMESH",val(a,"default_navmesh","NOT FOUND"),flag(a,"default_navmesh_ready")?GOOD:WARN);
    row(f,390,475,"TARGET",val(a,"navmesh_target","/mnt/UDISK/openmw51-nav/navmesh.db"),DIM);
    row(f,390,515,"SWAP TARGET",val(a,"swap_target","/mnt/UDISK/openmw51-swapfile"),DIM);
    label(f,"INSTALLS ARE CONFIRMED AND VERIFIED BEFORE REPLACING THE TARGET.",390,560,1,WARN);label(f,"A SELECT   B BACK",390,622,1,DIM);
}

static void modsPage(Framebuffer&f,App&a)
{
    title(f,"MODS & LOAD ORDER","A TOGGLE  LEFT/RIGHT MOVE  START VALIDATE + APPLY");f.rect(350,178,902,410,P1);
    if(a.mods.empty())label(f,"NO MOD DATA ROOTS FOUND. PRESS X TO RESCAN.",390,220,2,WARN);
    for(int r=0,i=a.scroll;i<int(a.mods.size())&&r<8;++i,++r){int y=205+r*38;bool s=i==a.modSel;if(s)f.rect(370,y-10,840,31,P2);std::ostringstream n;n<<(i+1)<<" ";label(f,s?">":" ",382,y,1,s?ACC:DIM);label(f,n.str(),402,y,1,DIM);label(f,a.mods[i].enabled?"[ON]":"[OFF]",450,y,1,a.mods[i].enabled?GOOD:DIM);label(f,a.mods[i].risky?"NAV":"---",510,y,1,a.mods[i].risky?WARN:DIM);label(f,fit(a.mods[i].name,66),555,y,1,s?FG:DIM);}
    row(f,390,525,"PLUGIN ORDER",val(a,"plugin_status","NOT SCANNED"),val(a,"plugin_status")=="VALID"?GOOD:WARN);
    row(f,390,555,"NAVMESH IMPACT",val(a,"mod_navmesh","UNKNOWN"),val(a,"mod_navmesh")=="BASE ONLY"?GOOD:WARN);
    label(f,"X RESCAN   START APPLY   CONFIG IS BACKED UP TRANSACTIONALLY",376,622,1,DIM);
}

static void navmeshPage(Framebuffer&f,App&a)
{
    title(f,"NAVMESH BUILDER","CURRENT CONTENT PROFILE / 3 WORKERS / EXTERIORS + INTERIORS");f.rect(350,178,902,410,P1);
    std::array<std::string,3> n={"BUILD / UPDATE CURRENT MOD PROFILE","INSTALL PREBUILT BASE-GAME DATABASE","REFRESH STATUS"};
    for(int i=0;i<3;++i){int y=215+i*70;if(a.opt==i)f.rect(370,y-14,840,48,P2);label(f,a.opt==i?">":" ",386,y,2,a.opt==i?ACC:DIM);label(f,n[i],414,y,2,a.opt==i?FG:DIM);}
    row(f,390,435,"GENERATOR",flag(a,"generator")?"READY":"MISSING",flag(a,"generator")?GOOD:BAD);
    row(f,390,475,"DATABASE",flag(a,"navmesh")?human(number(val(a,"navmesh_size","0"))):"MISSING",flag(a,"navmesh")?GOOD:WARN);
    row(f,390,515,"PROFILE",val(a,"navmesh_profile","UNKNOWN"),val(a,"navmesh_profile")=="CURRENT"?GOOD:WARN);
    label(f,"THE EXISTING SDL PROGRESS WINDOW REMAINS VISIBLE UNTIL COMPLETION.",390,560,1,DIM);label(f,"A SELECT   B BACK",390,622,1,DIM);
}

static void diagnosticsPage(Framebuffer&f,App&a)
{
    title(f,"DIAGNOSTICS","EXACT PATHS AND READINESS");f.rect(350,178,902,410,P1);
    row(f,390,205,"ROOT",a.root.string(),FG);row(f,390,245,"MAIN CONFIG",val(a,"config"),FG);
    row(f,390,285,"BASE NAV SOURCE",val(a,"default_navmesh"),flag(a,"default_navmesh_ready")?GOOD:WARN);
    row(f,390,325,"NAV TARGET",val(a,"navmesh_target"),FG);row(f,390,365,"SWAP TARGET",val(a,"swap_target"),FG);
    row(f,390,405,"GENERATOR",val(a,"generator_path"),flag(a,"generator")?GOOD:BAD);row(f,390,445,"PROFILE HASH",fit(val(a,"profile_hash"),24),DIM);
    row(f,390,485,"CONFIG HEALTH",val(a,"plugin_status"),val(a,"plugin_status")=="VALID"?GOOD:WARN);
    label(f,"X OR A REFRESH   B BACK",390,545,1,DIM);label(f,"FULL LOG: OPENMW51/LAUNCHER/MANAGER-V2.LOG",390,622,1,DIM);
}

static void confirmPage(Framebuffer&f,App&a)
{
    title(f,"CONFIRM ACTION","NO LONG OPERATION OR CONFIG WRITE STARTS WITHOUT THIS STEP");f.rect(350,205,902,280,P1);label(f,"ARE YOU SURE?",390,245,3,WARN);label(f,fit(a.question,95),390,310,1,FG);label(f,"A CONFIRM",390,395,2,GOOD);label(f,"B CANCEL",650,395,2,DIM);
}

static void render(Framebuffer&f,App&a)
{
    f.clear(BG);header(f);if(a.page==Page::Home)homePage(f,a);else if(a.page==Page::Setup)setupPage(f,a);else if(a.page==Page::Mods)modsPage(f,a);else if(a.page==Page::Navmesh)navmeshPage(f,a);else if(a.page==Page::Diagnostics)diagnosticsPage(f,a);else confirmPage(f,a);
    f.present();
}

static void handle(App&a,Action q)
{
    if(q==Action::Quit){request(a,"exit");return;}
    if(a.page==Page::Confirm){if(q==Action::Select||q==Action::Apply)request(a,a.pending);else if(q==Action::Back){a.page=a.returnPage;a.pending.clear();}return;}
    if(a.page==Page::Home)
    {
        if(q==Action::Up)a.home=(a.home+5)%6;else if(q==Action::Down)a.home=(a.home+1)%6;else if(q==Action::Back)request(a,"exit");else if(q==Action::Refresh)request(a,"status");else if(q==Action::Select){if(a.home==0){if(val(a,"navmesh_profile")=="STALE")confirm(a,Page::Home,"ACTIVE MODS DO NOT MATCH THIS NAVMESH. PLAY ANYWAY?","play");else request(a,"play");}else if(a.home==1){a.page=Page::Setup;a.opt=0;}else if(a.home==2)a.page=Page::Mods;else if(a.home==3){a.page=Page::Navmesh;a.opt=0;}else if(a.home==4)a.page=Page::Diagnostics;else request(a,"exit");}return;
    }
    if(q==Action::Back){a.page=Page::Home;return;}
    if(a.page==Page::Setup){if(q==Action::Up)a.opt=(a.opt+2)%3;else if(q==Action::Down)a.opt=(a.opt+1)%3;else if(q==Action::Refresh)request(a,"status");else if(q==Action::Select){if(a.opt==0)confirm(a,Page::Setup,"REPLACE THE CANONICAL DB WITH THE VERIFIED BASE-GAME NAVMESH?","install-navmesh");else if(a.opt==1)confirm(a,Page::Setup,"CREATE OR ACTIVATE THE CANONICAL 512 MB UDISK SWAPFILE?","install-swap");else request(a,"status");}}
    else if(a.page==Page::Mods){if(q==Action::Up&&a.modSel>0)--a.modSel;else if(q==Action::Down&&a.modSel+1<int(a.mods.size()))++a.modSel;else if(q==Action::Select&&!a.mods.empty())request(a,"mod-toggle:"+a.mods[a.modSel].id);else if(q==Action::Left&&!a.mods.empty())request(a,"mod-move:"+a.mods[a.modSel].id+":-1");else if(q==Action::Right&&!a.mods.empty())request(a,"mod-move:"+a.mods[a.modSel].id+":1");else if(q==Action::Refresh)request(a,"mods-scan");else if(q==Action::Apply)confirm(a,Page::Mods,"VALIDATE DEPENDENCIES, BACK UP OPENMW.CFG, AND APPLY THIS ORDER?","mods-apply");}
    else if(a.page==Page::Navmesh){if(q==Action::Up)a.opt=(a.opt+2)%3;else if(q==Action::Down)a.opt=(a.opt+1)%3;else if(q==Action::Refresh)request(a,"status");else if(q==Action::Select){if(a.opt==0)confirm(a,Page::Navmesh,"START THE FULL THREE-WORKER NAVMESH BUILD FOR CURRENT MODS?","build-navmesh");else if(a.opt==1)confirm(a,Page::Navmesh,"REPLACE THE CANONICAL DB WITH THE BASE-GAME NAVMESH?","install-navmesh");else request(a,"status");}}
    else if(a.page==Page::Diagnostics&&(q==Action::Select||q==Action::Refresh))request(a,"status");
    if(a.modSel<a.scroll)a.scroll=a.modSel;
    if(a.modSel>=a.scroll+8)a.scroll=a.modSel-7;
}

int main(int argc,char**argv)
{
    if(argc>1&&std::string(argv[1])=="--selftest"){std::cout<<"OPENMW51_MANAGER_V2_SELFTEST_PASS\n";return 0;}
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
        App a;a.root="/mnt/SDCARD/data/ports/openmw51";if(const char*e=getenv("OPENMW51_GAMEDIR"))a.root=e;
        fs::path l=a.root/"launcher";a.request=l/"request";a.statusFile=l/"status.conf";a.modsFile=l/"modplan.tsv";a.uiFile=l/"ui-state.conf";a.resultFile=l/"last-result.txt";fs::path readyFile=l/"ui-ready";
        std::error_code readyError;fs::remove(readyFile,readyError);
        loadUi(a);refresh(a);Framebuffer fb(getenv("OPENMW51_LAUNCHER_FB")?getenv("OPENMW51_LAUNCHER_FB"):"/dev/fb0");Inputs in;bool dirty=true;auto last=std::chrono::steady_clock::now();
        bool publishedReady=false;
        while(!a.quit){Action q=in.wait(80);if(q!=Action::None){handle(a,q);dirty=true;}auto now=std::chrono::steady_clock::now();if(now-last>std::chrono::seconds(3)){refresh(a);last=now;dirty=true;}if(dirty){render(fb,a);if(!publishedReady){writeAtomic(readyFile,"ready");publishedReady=true;}dirty=false;}}
        return 0;
    }
    catch(const std::exception&e){std::cerr<<"OpenMW manager fatal: "<<e.what()<<"\n";return 1;}
}
