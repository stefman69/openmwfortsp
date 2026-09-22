import sys
p='/root/gl4es-tsps/src/gl/framebuffers.c'
s=open(p).read()
if 'TSP_FBOSNAP_V2_20260823' in s:
    print('SKIP already patched'); sys.exit(0)
i=s.find('static void tsp_fbo_snap(void)')
if i<0: print('FAIL tsp_fbo_snap not found'); sys.exit(1)
b=s.find('{',i); d=0; j=b
while j<len(s):
    if s[j]=='{': d+=1
    elif s[j]=='}':
        d-=1
        if d==0: break
    j+=1
old=s[i:j+1]
if 'gl4es_glReadPixels' not in old: print('FAIL wrong span'); sys.exit(1)
NEW=r'''/* TSP_FBOSNAP_V2_20260823 */
#ifndef RTLD_NOLOAD
#define RTLD_NOLOAD 0x00004
#endif
const char* volatile tspFboSnapV2Tag = "TSP_FBOSNAP_V2_20260823";
static void* tsp_snap_gles(void) {
    static void* gh = NULL; static int tried = 0;
    if (tried) return gh;
    tried = 1;
    const char* cand[6]; int nc = 0; int i;
    const char* ev = getenv("LIBGL_GLES");
    if (ev && ev[0]) cand[nc++] = ev;
    cand[nc++] = "libGLESv2.so.2";
    cand[nc++] = "libGLESv2.so";
    cand[nc++] = "libmali.so.1";
    cand[nc++] = "libmali.so";
    cand[nc++] = "libGLESv2_mali.so";
    for (i = 0; i < nc && !gh; ++i) gh = dlopen(cand[i], RTLD_LAZY | RTLD_NOLOAD);
    for (i = 0; i < nc && !gh; ++i) gh = dlopen(cand[i], RTLD_LAZY);
    return gh;
}
static void tsp_fbo_snap(void) {
    static int chk = 0; static const char* dir = NULL; static int n = 0;
    static int nsmall = 0, nbig = 0, nsize = 0, libdone = 0;
    static void (*nat_rp)(int,int,int,int,unsigned int,unsigned int,void*) = NULL;
    static void (*nat_bf)(unsigned int,unsigned int) = NULL;
    static unsigned int (*nat_ge)(void) = NULL;
    size_t k, sz;
    if (!chk) { dir = getenv("LIBGL_TSP_FBOSNAP"); chk = 1; }
    if (!dir || !dir[0]) return;
    if (!glstate || !glstate->fbo.fbo_draw) return;
    int w = glstate->fbo.fbo_draw->width;
    int h = glstate->fbo.fbo_draw->height;
    unsigned int id = glstate->fbo.fbo_draw->id;
    if (id == 0 || w <= 0 || h <= 0) return;
    if (nsize < 300) { nsize++; tsp_fbo_log("SNAPSIZE fb=%u %dx%d", id, w, h); }
    if (n >= 64) return;
    if (!((w == 256 && h == 256) || (w == 512 && h == 1024))) return;
    if (w == 256) { if (nsmall >= 24) return; nsmall++; }
    else { if (nbig >= 8) return; nbig++; }
    if (!libdone) {
        libdone = 1;
        void* gh = tsp_snap_gles();
        if (gh) {
            *(void**)(&nat_rp) = dlsym(gh, "glReadPixels");
            *(void**)(&nat_bf) = dlsym(gh, "glBindFramebuffer");
            *(void**)(&nat_ge) = dlsym(gh, "glGetError");
        }
        tsp_fbo_log("SNAPLIB gh=%p rp=%p bf=%p ge=%p", gh, (void*)nat_rp, (void*)nat_bf, (void*)nat_ge);
    }
    sz = (size_t)w * (size_t)h * 4;
    unsigned char* buf = (unsigned char*)malloc(sz);
    if (!buf) return;
    unsigned long chg_nat = 0, chg_g4 = 0; unsigned int e_nat = 0, e_g4 = 0;
    if (nat_rp && nat_bf) {
        memset(buf, 0xAB, sz);
        if (nat_ge) { while (nat_ge() != 0) {} }
        nat_bf(0x8D40u, id);
        nat_rp(0, 0, w, h, 0x1908u, 0x1401u, buf);
        e_nat = nat_ge ? nat_ge() : 0u;
        nat_bf(0x8D40u, 0u);
        for (k = 0; k < sz; ++k) if (buf[k] != 0xAB) chg_nat++;
    }
    if (chg_nat == 0) {
        memset(buf, 0xAB, sz);
        gl4es_glReadPixels(0, 0, w, h, 0x1908u, 0x1401u, buf);
        e_g4 = nat_ge ? nat_ge() : 0u;
        for (k = 0; k < sz; ++k) if (buf[k] != 0xAB) chg_g4++;
    }
    char path[512];
    snprintf(path, sizeof(path), "%s/fbo%02d_id%u_%dx%d.ppm", dir, n, id, w, h);
    tsp_fbo_log("SNAP %s nat_changed=%lu nat_err=0x%x g4_changed=%lu g4_err=0x%x of=%lu",
                path, chg_nat, e_nat, chg_g4, e_g4, (unsigned long)sz);
    if (chg_nat == 0 && chg_g4 == 0) { free(buf); return; }
    FILE* f = fopen(path, "wb");
    if (f) {
        fprintf(f, "P6\n%d %d\n255\n", w, h);
        int y, x;
        for (y = h - 1; y >= 0; --y) {
            const unsigned char* row = buf + (size_t)y * (size_t)w * 4;
            for (x = 0; x < w; ++x) fwrite(row + x * 4, 1, 3, f);
        }
        fclose(f);
        n++;
    }
    free(buf);
}'''
s=s[:i]+NEW+s[j+1:]
if '#include <dlfcn.h>' not in s:
    L=s.split('\n')
    last=max(k for k,l in enumerate(L) if l.startswith('#include'))
    L.insert(last+1,'#include <dlfcn.h>')
    L.insert(last+2,'#include <string.h>')
    s='\n'.join(L)
open(p,'w').write(s)
print('PATCHED ok')
