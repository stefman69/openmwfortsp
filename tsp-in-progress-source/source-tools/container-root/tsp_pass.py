import glob,re,sys
GL='/root/gl4es-tsps/src/gl/'
p=GL+'framebuffers.c'
s=open(p).read()
if 'TSP_PASSSTATE_V5' in s:
    print('SKIP fb already v5')
else:
    i=s.find('/* TSP_DRAWCOUNT_V4 */')
    if i<0: print('FAIL no V4 tag'); sys.exit(1)
    f=s.find('static void tsp_fbo_snap(void)',i); b=s.find('{',f); d=0; j=b
    while j<len(s):
        if s[j]=='{': d+=1
        elif s[j]=='}':
            d-=1
            if d==0: break
        j+=1
    NEW=r'''/* TSP_PASSSTATE_V5 */
#ifndef RTLD_NOLOAD
#define RTLD_NOLOAD 0x00004
#endif
const char* volatile tspPassStateV5Tag = "TSP_PASSSTATE_V5";
unsigned long tsp_drawcount = 0;
unsigned long tsp_clearcount = 0;
unsigned int tsp_clearmask = 0;
static unsigned long tsp_draw_at_bind = 0;
static unsigned long tsp_clear_at_bind = 0;
static int tsp_snap_on(void) {
    static int chk = 0; static int on = 0;
    if (!chk) { const char* d = getenv("LIBGL_TSP_FBOSNAP"); on = (d && d[0]) ? 1 : 0; chk = 1; }
    return on;
}
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
void tsp_fbo_mark(unsigned int fb) {
    if (!tsp_snap_on()) return;
    if (fb != 0) { tsp_draw_at_bind = tsp_drawcount; tsp_clear_at_bind = tsp_clearcount; tsp_clearmask = 0; }
}
static void tsp_fbo_snap(void) {
    static int nlog = 0; static int libdone = 0;
    static void (*nat_gi)(unsigned int,int*) = NULL;
    static void (*nat_gf)(unsigned int,float*) = NULL;
    if (!tsp_snap_on()) return;
    if (!glstate || !glstate->fbo.fbo_draw) return;
    int w = glstate->fbo.fbo_draw->width;
    int h = glstate->fbo.fbo_draw->height;
    unsigned int id = glstate->fbo.fbo_draw->id;
    if (id == 0 || w <= 0 || h <= 0) return;
    if (nlog >= 500) return;
    nlog++;
    if (!libdone) {
        libdone = 1;
        void* gh = tsp_snap_gles();
        if (gh) {
            *(void**)(&nat_gi) = dlsym(gh, "glGetIntegerv");
            *(void**)(&nat_gf) = dlsym(gh, "glGetFloatv");
        }
        tsp_fbo_log("PASSLIB gi=%p gf=%p", (void*)nat_gi, (void*)nat_gf);
    }
    int vp[4]; int sc[4]; int cm[4];
    int sct=-1, dt=-1, df=-1, dm=-1, bl=-1, cf=-1, fb=-1;
    float dcv = -1.0f; float ccv[4];
    vp[0]=vp[1]=vp[2]=vp[3]=-1; sc[0]=sc[1]=sc[2]=sc[3]=-1;
    cm[0]=cm[1]=cm[2]=cm[3]=-1; ccv[0]=ccv[1]=ccv[2]=ccv[3]=-1.0f;
    if (nat_gi) {
        nat_gi(0x0BA2u, vp);
        nat_gi(0x0C10u, sc);
        nat_gi(0x0C23u, cm);
        nat_gi(0x0C11u, &sct);
        nat_gi(0x0B71u, &dt);
        nat_gi(0x0B74u, &df);
        nat_gi(0x0B72u, &dm);
        nat_gi(0x0BE2u, &bl);
        nat_gi(0x0B44u, &cf);
        nat_gi(0x8CA6u, &fb);
    }
    if (nat_gf) { nat_gf(0x0B73u, &dcv); nat_gf(0x0C22u, ccv); }
    tsp_fbo_log("PASS fb=%u %dx%d bind=%d draws=%lu clears=%lu cmask=0x%x vp=%d,%d,%dx%d sc=%d,%d,%dx%d scis=%d cwrite=%d%d%d%d dtest=%d dfunc=0x%x dmask=%d dclear=%.3f cclear=%.2f,%.2f,%.2f,%.2f blend=%d cull=%d",
        id, w, h, fb,
        tsp_drawcount - tsp_draw_at_bind,
        tsp_clearcount - tsp_clear_at_bind,
        tsp_clearmask,
        vp[0],vp[1],vp[2],vp[3], sc[0],sc[1],sc[2],sc[3], sct,
        cm[0],cm[1],cm[2],cm[3], dt, df, dm, (double)dcv,
        (double)ccv[0],(double)ccv[1],(double)ccv[2],(double)ccv[3], bl, cf);
}'''
    s=s[:i]+NEW+s[j+1:]
    open(p,'w').write(s); print('framebuffers.c -> V5')
# capture the clear mask argument
def defspan(t,name):
    return re.search(r'\n[A-Za-z_][A-Za-z0-9_ \*]*\b'+name+r'\s*\([^;{]*\)\s*\{',t)
for fn in sorted(glob.glob(GL+'*.c'))+sorted(glob.glob('/root/gl4es-tsps/src/glx/*.c')):
    t=open(fn).read()
    if 'TSPCOUNT_gl4es_glClear' not in t: continue
    m=defspan(t,'gl4es_glClear')
    if not m: print('WARN marker but no def in '+fn); continue
    head=m.group(0)
    arg=re.findall(r'([A-Za-z_][A-Za-z0-9_]*)\s*$',head[head.index('(')+1:head.rindex(')')].split(',')[-1].strip())
    if not arg: print('WARN cannot name clear arg in '+fn); continue
    new='/* TSPCOUNT_gl4es_glClear */ { extern unsigned long tsp_clearcount; extern unsigned int tsp_clearmask; tsp_clearcount++; tsp_clearmask |= (unsigned int)'+arg[0]+'; }'
    t2=re.sub(r'/\* TSPCOUNT_gl4es_glClear \*/[^\n]*', new, t)
    if t2!=t: open(fn,'w').write(t2); print('clear mask captured in '+fn+' arg='+arg[0])
    else: print('clear line already current in '+fn)
