import sys
p='/root/gl4es-tsps/src/gl/framebuffers.c'
s=open(p).read()
if 'TSP_FBOSNAP_V3_20260824' in s:
    print('SKIP already patched'); sys.exit(0)
i=s.find('/* TSP_FBOSNAP_V2_20260823 */')
if i<0: print('FAIL V2 tag not found'); sys.exit(1)
f=s.find('static void tsp_fbo_snap(void)', i)
if f<0: print('FAIL tsp_fbo_snap not found'); sys.exit(1)
b=s.find('{',f); d=0; j=b
while j<len(s):
    if s[j]=='{': d+=1
    elif s[j]=='}':
        d-=1
        if d==0: break
    j+=1
NEW=r'''/* TSP_FBOSNAP_V3_20260824 */
#ifndef RTLD_NOLOAD
#define RTLD_NOLOAD 0x00004
#endif
const char* volatile tspFboSnapV3Tag = "TSP_FBOSNAP_V3_20260824";
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
    static int nsmall = 0, nbig = 0, nmap = 0, nprobe = 0, libdone = 0;
    static void (*nat_rp)(int,int,int,int,unsigned int,unsigned int,void*) = NULL;
    static void (*nat_bf)(unsigned int,unsigned int) = NULL;
    static unsigned int (*nat_ge)(void) = NULL;
    static unsigned int (*nat_cs)(unsigned int) = NULL;
    static void (*nat_gi)(unsigned int,int*) = NULL;
    static void (*nat_ga)(unsigned int,unsigned int,unsigned int,int*) = NULL;
    size_t k, sz;
    if (!chk) { dir = getenv("LIBGL_TSP_FBOSNAP"); chk = 1; }
    if (!dir || !dir[0]) return;
    if (!glstate || !glstate->fbo.fbo_draw) return;
    int w = glstate->fbo.fbo_draw->width;
    int h = glstate->fbo.fbo_draw->height;
    unsigned int id = glstate->fbo.fbo_draw->id;
    if (id == 0 || w <= 0 || h <= 0) return;
    if (!libdone) {
        libdone = 1;
        void* gh = tsp_snap_gles();
        if (gh) {
            *(void**)(&nat_rp) = dlsym(gh, "glReadPixels");
            *(void**)(&nat_bf) = dlsym(gh, "glBindFramebuffer");
            *(void**)(&nat_ge) = dlsym(gh, "glGetError");
            *(void**)(&nat_cs) = dlsym(gh, "glCheckFramebufferStatus");
            *(void**)(&nat_gi) = dlsym(gh, "glGetIntegerv");
            *(void**)(&nat_ga) = dlsym(gh, "glGetFramebufferAttachmentParameteriv");
        }
        tsp_fbo_log("SNAPLIB gh=%p rp=%p bf=%p ge=%p cs=%p gi=%p ga=%p",
            gh,(void*)nat_rp,(void*)nat_bf,(void*)nat_ge,(void*)nat_cs,(void*)nat_gi,(void*)nat_ga);
    }
    if (!nat_bf || !nat_cs) return;
    int prevfb = -1;
    if (nat_gi) nat_gi(0x8CA6u, &prevfb);
    if (nat_ge) { while (nat_ge() != 0) {} }
    nat_bf(0x8D40u, id);
    unsigned int st = nat_cs(0x8D40u);
    int cname=0, ctype=0, dname=0, dtype=0, sname=0, stype=0;
    if (nat_ga) {
        nat_ga(0x8D40u, 0x8CE0u, 0x8CD1u, &cname);
        nat_ga(0x8D40u, 0x8CE0u, 0x8CD0u, &ctype);
        nat_ga(0x8D40u, 0x8D00u, 0x8CD1u, &dname);
        nat_ga(0x8D40u, 0x8D00u, 0x8CD0u, &dtype);
        nat_ga(0x8D40u, 0x8D20u, 0x8CD1u, &sname);
        nat_ga(0x8D40u, 0x8D20u, 0x8CD0u, &stype);
    }
    unsigned int e_probe = nat_ge ? nat_ge() : 0u;
    if (nprobe < 400) {
        nprobe++;
        tsp_fbo_log("PROBE fb=%u %dx%d prevbind=%d status=0x%x color=%d/0x%x depth=%d/0x%x stencil=%d/0x%x err=0x%x",
            id, w, h, prevfb, st, cname, ctype, dname, dtype, sname, stype, e_probe);
    }
    int want = ((w == 256 && h == 256) || (w == 512 && h == 1024) || (w == 954 && h == 864));
    if (!want || n >= 48 || !nat_rp) { if (prevfb >= 0) nat_bf(0x8D40u,(unsigned int)prevfb); return; }
    if (w == 256) { if (nsmall >= 16) { if (prevfb>=0) nat_bf(0x8D40u,(unsigned int)prevfb); return; } nsmall++; }
    else if (w == 512) { if (nbig >= 8) { if (prevfb>=0) nat_bf(0x8D40u,(unsigned int)prevfb); return; } nbig++; }
    else { if (nmap >= 4) { if (prevfb>=0) nat_bf(0x8D40u,(unsigned int)prevfb); return; } nmap++; }
    sz = (size_t)w * (size_t)h * 4;
    unsigned char* buf = (unsigned char*)malloc(sz);
    if (!buf) { if (prevfb>=0) nat_bf(0x8D40u,(unsigned int)prevfb); return; }
    memset(buf, 0xAB, sz);
    unsigned long chg = 0; unsigned int e_rd = 0;
    if (st == 0x8CD5u) {
        if (nat_ge) { while (nat_ge() != 0) {} }
        nat_rp(0, 0, w, h, 0x1908u, 0x1401u, buf);
        e_rd = nat_ge ? nat_ge() : 0u;
        for (k = 0; k < sz; ++k) if (buf[k] != 0xAB) chg++;
    }
    if (prevfb >= 0) nat_bf(0x8D40u, (unsigned int)prevfb);
    char path[512];
    snprintf(path, sizeof(path), "%s/fbo%02d_id%u_%dx%d.ppm", dir, n, id, w, h);
    tsp_fbo_log("SNAP %s status=0x%x changed=%lu of=%lu err=0x%x", path, st, chg, (unsigned long)sz, e_rd);
    if (chg > 0) {
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
    }
    free(buf);
}'''
s=s[:i]+NEW+s[j+1:]
open(p,'w').write(s)
print('PATCHED V3 ok')
