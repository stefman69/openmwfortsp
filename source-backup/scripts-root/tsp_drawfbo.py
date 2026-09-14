import glob,re,sys
GL='/root/gl4es-tsps/src/gl/'
p=GL+'framebuffers.c'
s=open(p).read()
if 'TSP_DRAWFBO_V7' in s: print('SKIP fb already v7')
else:
    i=s.find('/* TSP_PASSSTATE_V5 */')
    if i<0: print('FAIL no V5 tag'); sys.exit(1)
    f=s.find('static void tsp_fbo_snap(void)',i); b=s.find('{',f); d=0; j=b
    while j<len(s):
        if s[j]=='{': d+=1
        elif s[j]=='}':
            d-=1
            if d==0: break
        j+=1
    NEW=r'''/* TSP_DRAWFBO_V7 */
#ifndef RTLD_NOLOAD
#define RTLD_NOLOAD 0x00004
#endif
const char* volatile tspDrawFboV7Tag = "TSP_DRAWFBO_V7";
unsigned long tsp_drawcount = 0;
unsigned long tsp_clearcount = 0;
unsigned int tsp_clearmask = 0;
static unsigned long tsp_draw_at_bind = 0;
static unsigned long tsp_clear_at_bind = 0;
static void (*tsp_nat_gi)(unsigned int,int*) = NULL;
static void (*tsp_nat_ga)(unsigned int,unsigned int,unsigned int,int*) = NULL;
static unsigned int (*tsp_nat_cs)(unsigned int) = NULL;
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
static void tsp_natload(void) {
    static int done = 0;
    if (done) return;
    done = 1;
    void* gh = tsp_snap_gles();
    if (gh) {
        *(void**)(&tsp_nat_gi) = dlsym(gh, "glGetIntegerv");
        *(void**)(&tsp_nat_ga) = dlsym(gh, "glGetFramebufferAttachmentParameteriv");
        *(void**)(&tsp_nat_cs) = dlsym(gh, "glCheckFramebufferStatus");
    }
    tsp_fbo_log("NATLOAD gh=%p gi=%p ga=%p cs=%p", gh, (void*)tsp_nat_gi, (void*)tsp_nat_ga, (void*)tsp_nat_cs);
}
void tsp_fbo_mark(unsigned int fb) {
    if (!tsp_snap_on()) return;
    if (fb != 0) { tsp_draw_at_bind = tsp_drawcount; tsp_clear_at_bind = tsp_clearcount; tsp_clearmask = 0; }
}
void tsp_draw_probe(void) {
    static int nlog = 0;
    unsigned long n;
    if (!tsp_snap_on()) return;
    if (nlog >= 150) return;
    n = tsp_drawcount - tsp_draw_at_bind;
    if (n != 1 && n != 2) return;
    if (!glstate || !glstate->fbo.fbo_draw) return;
    if (glstate->fbo.fbo_draw->id == 0) return;
    tsp_natload();
    {
        int bind = -1, ct = 0, cn = 0, dt = 0, dn = 0;
        unsigned int st = 0;
        if (tsp_nat_gi) tsp_nat_gi(0x8CA6u, &bind);
        if (tsp_nat_ga) {
            tsp_nat_ga(0x8D40u, 0x8CE0u, 0x8CD0u, &ct);
            if (ct != 0) tsp_nat_ga(0x8D40u, 0x8CE0u, 0x8CD1u, &cn);
            tsp_nat_ga(0x8D40u, 0x8D00u, 0x8CD0u, &dt);
            if (dt != 0) tsp_nat_ga(0x8D40u, 0x8D00u, 0x8CD1u, &dn);
        }
        if (tsp_nat_cs) st = tsp_nat_cs(0x8D40u);
        nlog++;
        tsp_fbo_log("DRAWFBO gl4esfb=%u %dx%d draw=%lu driverbind=%d color=0x%x/%d depth=0x%x/%d status=0x%x",
            glstate->fbo.fbo_draw->id, glstate->fbo.fbo_draw->width, glstate->fbo.fbo_draw->height,
            n, bind, ct, cn, dt, dn, st);
    }
}
void tsp_tex_bind_note(unsigned int t) {
    static unsigned char seen[8192];
    static int nlog = 0;
    if (!tsp_snap_on()) return;
    if (t == 0 || t >= 8192) return;
    if (!glstate || !glstate->fbo.fbo_draw) return;
    if (glstate->fbo.fbo_draw->id != 0) return;
    if (seen[t]) return;
    seen[t] = 1;
    if (nlog >= 400) return;
    nlog++;
    tsp_fbo_log("SAMPLE0 tex=%u", t);
}
static void tsp_fbo_snap(void) {
    static int nlog = 0;
    if (!tsp_snap_on()) return;
    if (!glstate || !glstate->fbo.fbo_draw) return;
    if (glstate->fbo.fbo_draw->id == 0) return;
    if (nlog >= 400) return;
    nlog++;
    tsp_fbo_log("PASS fb=%u %dx%d draws=%lu clears=%lu cmask=0x%x",
        glstate->fbo.fbo_draw->id, glstate->fbo.fbo_draw->width, glstate->fbo.fbo_draw->height,
        tsp_drawcount - tsp_draw_at_bind, tsp_clearcount - tsp_clear_at_bind, tsp_clearmask);
}'''
    s=s[:i]+NEW+s[j+1:]
    open(p,'w').write(s); print('framebuffers.c -> V7')
def defspan(t,name):
    return re.search(r'\n[A-Za-z_][A-Za-z0-9_ \*]*\b'+name+r'\s*\([^;{]*\)\s*\{',t)
# draw probe call sites
for fn in sorted(glob.glob(GL+'*.c')):
    t=open(fn).read(); ch=0
    for nm in ('gl4es_glDrawElements','gl4es_glDrawArrays'):
        mk='/* TSPCOUNT_'+nm+' */'
        if mk not in t: continue
        if 'tsp_draw_probe' in t.split(mk)[1][:200]: continue
        t=t.replace(mk+' { extern unsigned long tsp_drawcount; tsp_drawcount++; }',
                    mk+' { extern unsigned long tsp_drawcount; extern void tsp_draw_probe(void); tsp_drawcount++; tsp_draw_probe(); }')
        ch=1
    if ch: open(fn,'w').write(t); print('draw probe -> '+fn)
# texture bind hook
tp=GL+'texture.c'
t=open(tp).read()
if 'TSPBINDNOTE' in t: print('bind note already present')
else:
    m=defspan(t,'gl4es_glBindTexture')
    if not m: print('FAIL no gl4es_glBindTexture def'); sys.exit(1)
    head=m.group(0)
    arg=re.findall(r'([A-Za-z_][A-Za-z0-9_]*)\s*$',head[head.index('(')+1:head.rindex(')')].split(',')[-1].strip())
    if not arg: print('FAIL cannot name texture arg'); sys.exit(1)
    ins='\n    /* TSPBINDNOTE */ { extern void tsp_tex_bind_note(unsigned int); tsp_tex_bind_note((unsigned int)'+arg[0]+'); }'
    t=t[:m.end()]+ins+t[m.end():]
    open(tp,'w').write(t); print('bind note -> texture.c arg='+arg[0])
