import glob,re,sys
GL='/root/gl4es-tsps/src/gl/'
def defspan(s,name):
    m=re.search(r'\n[A-Za-z_][A-Za-z0-9_ \*]*\b'+name+r'\s*\([^;{]*\)\s*\{',s)
    return m
# 1. counters + mark + new snap in framebuffers.c
p=GL+'framebuffers.c'
s=open(p).read()
if 'TSP_DRAWCOUNT_V4' in s: print('SKIP fb already v4')
else:
    i=s.find('/* TSP_FBOSNAP_V3_20260824 */')
    if i<0: print('FAIL no V3 tag'); sys.exit(1)
    f=s.find('static void tsp_fbo_snap(void)',i); b=s.find('{',f); d=0; j=b
    while j<len(s):
        if s[j]=='{': d+=1
        elif s[j]=='}':
            d-=1
            if d==0: break
        j+=1
    NEW=r'''/* TSP_DRAWCOUNT_V4 */
#ifndef RTLD_NOLOAD
#define RTLD_NOLOAD 0x00004
#endif
const char* volatile tspDrawCountV4Tag = "TSP_DRAWCOUNT_V4";
unsigned long tsp_drawcount = 0;
unsigned long tsp_clearcount = 0;
static unsigned long tsp_draw_at_bind = 0;
static unsigned long tsp_clear_at_bind = 0;
static int tsp_snap_on(void) {
    static int chk = 0; static int on = 0;
    if (!chk) { const char* d = getenv("LIBGL_TSP_FBOSNAP"); on = (d && d[0]) ? 1 : 0; chk = 1; }
    return on;
}
void tsp_fbo_mark(unsigned int fb) {
    if (!tsp_snap_on()) return;
    if (fb != 0) { tsp_draw_at_bind = tsp_drawcount; tsp_clear_at_bind = tsp_clearcount; }
}
static void tsp_fbo_snap(void) {
    static int nlog = 0;
    if (!tsp_snap_on()) return;
    if (!glstate || !glstate->fbo.fbo_draw) return;
    int w = glstate->fbo.fbo_draw->width;
    int h = glstate->fbo.fbo_draw->height;
    unsigned int id = glstate->fbo.fbo_draw->id;
    if (id == 0 || w <= 0 || h <= 0) return;
    if (nlog >= 600) return;
    nlog++;
    tsp_fbo_log("DRAWS fb=%u %dx%d draws=%lu clears=%lu",
                id, w, h,
                tsp_drawcount - tsp_draw_at_bind,
                tsp_clearcount - tsp_clear_at_bind);
}'''
    s=s[:i]+NEW+s[j+1:]
    open(p,'w').write(s); print('framebuffers.c -> V4')
# 2. call tsp_fbo_mark at the top of gl4es_glBindFramebuffer
s=open(p).read()
if 'tsp_fbo_mark(' in s.split('void tsp_fbo_mark')[-1][200:]:
    pass
m=defspan(s,'gl4es_glBindFramebuffer')
if not m: print('FAIL no gl4es_glBindFramebuffer def')
else:
    head=m.group(0)
    args=head[head.index('(')+1:head.rindex(')')].split(',')
    fbarg=re.findall(r'([A-Za-z_][A-Za-z0-9_]*)\s*$',args[-1].strip())
    if not fbarg: print('FAIL cannot name fb arg')
    else:
        call='\n    tsp_fbo_mark((unsigned int)'+fbarg[0]+');'
        if call not in s:
            s=s[:m.end()]+call+s[m.end():]
            open(p,'w').write(s); print('mark call inserted, arg='+fbarg[0])
        else: print('mark call already present')
# 3. counters in the draw + clear entry points
for name,var in (('gl4es_glDrawElements','tsp_drawcount'),
                 ('gl4es_glDrawArrays','tsp_drawcount'),
                 ('gl4es_glClear','tsp_clearcount')):
    hit=0
    for fn in sorted(glob.glob(GL+'*.c'))+sorted(glob.glob('/root/gl4es-tsps/src/glx/*.c')):
        t=open(fn).read()
        m=defspan(t,name)
        if not m: continue
        if 'TSPCOUNT_'+name in t: print(name+' already in '+fn); hit+=1; continue
        ins='\n    /* TSPCOUNT_'+name+' */ { extern unsigned long '+var+'; '+var+'++; }'
        t=t[:m.end()]+ins+t[m.end():]
        open(fn,'w').write(t); print(name+' -> '+fn); hit+=1
    if not hit: print('WARN no definition found for '+name)
