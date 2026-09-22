import sys
p='/root/gl4es-tsps/src/gl/framebuffers.c'
s=open(p).read()
if 'TSP_FBO_GLNAME_FIX_20260824' in s: print('SKIP already patched'); sys.exit(0)
a='    gles_glFramebufferTexture2D(ntarget, attachment, realtarget, texture, 0);'
if s.count(a)!=1:
    print('FAIL anchor matched %d' % s.count(a))
    for i,l in enumerate(s.split("\n")):
        if 'realtarget, texture' in l: print('  %d: %s' % (i+1,l))
    sys.exit(1)
NEW='\n'.join([
'    /* TSP_FBO_GLNAME_FIX_20260824 - `texture` was captured from tex->glname near the',
'       top of this function, long before realize_1texture() runs. A texture that was',
'       created and attached without ever being uploaded - every RTT colour target -',
'       still has glname==0 at that point, so the call below attaches name 0, which',
'       DETACHES colour. The FBO keeps only depth, still reports COMPLETE, and every',
'       colour fragment is discarded. Re-read the name after realization. */',
'    if (tex && tex->glname && texture != tex->glname) {',
'        static int tspFixSaid = 0;',
'        if (tspFixSaid < 8) { tspFixSaid++;',
'            tsp_fbo_log("GLNAMEFIX att=0x%x stale=%u real=%u", attachment, texture, tex->glname); }',
'        texture = tex->glname;',
'    }',
'    if (tex && !texture && attachment >= GL_COLOR_ATTACHMENT0',
'        && attachment < (GL_COLOR_ATTACHMENT0 + hardext.maxcolorattach)) {',
'        static int tspZeroSaid = 0;',
'        if (tspZeroSaid < 8) { tspZeroSaid++;',
'            tsp_fbo_log("GLNAMEZERO att=0x%x app=%u glname=%u", attachment, tex->texture, tex->glname); }',
'    }',
a])
s=s.replace(a,NEW)
m='/* TSP_FBO_DIAG_20260815 */'
if s.count(m)!=1: print('FAIL tag anchor x%d' % s.count(m)); sys.exit(1)
s=s.replace(m,'const char* volatile tspFboGlnameFixTag = "TSP_FBO_GLNAME_FIX_20260824";\n'+m)
if s.count('{')!=s.count('}'): print('FAIL brace imbalance'); sys.exit(1)
open(p,'w').write(s)
print('PATCHED glname fix')
