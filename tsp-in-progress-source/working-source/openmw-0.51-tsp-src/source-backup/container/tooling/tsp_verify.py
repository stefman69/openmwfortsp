import sys
p='/root/gl4es-tsps/src/gl/framebuffers.c'
s=open(p).read()
if 'TSP_ATTACH_VERIFY_20260824' in s: print('SKIP already patched'); sys.exit(0)
L=s.split('\n')
tag=[i for i,l in enumerate(L) if 'TSP_DRAWFBO_V7' in l and 'volatile' in l]
call=[i for i,l in enumerate(L) if 'gles_glFramebufferTexture2D(ntarget, attachment, realtarget, texture, 0);' in l]
if len(tag)!=1 or len(call)!=1:
    print('FAIL tag=%d call=%d' % (len(tag),len(call))); sys.exit(1)
if tag[0] > call[0]:
    print('FAIL V7 helpers defined AFTER the call site'); sys.exit(1)
# add glGetError to the native loader
a='        *(void**)(&tsp_nat_cs) = dlsym(gh, "glCheckFramebufferStatus");'
if s.count(a)!=1: print('FAIL natload anchor x%d' % s.count(a)); sys.exit(1)
s=s.replace(a, a+'\n        *(void**)(&tsp_nat_ge) = dlsym(gh, "glGetError");')
b='static unsigned int (*tsp_nat_cs)(unsigned int) = NULL;'
if s.count(b)!=1: print('FAIL decl anchor x%d' % s.count(b)); sys.exit(1)
s=s.replace(b, b+'\nstatic unsigned int (*tsp_nat_ge)(void) = NULL;')
s=s.replace('const char* volatile tspDrawFboV7Tag = "TSP_DRAWFBO_V7";',
            'const char* volatile tspDrawFboV7Tag = "TSP_DRAWFBO_V7";\nconst char* volatile tspAttachVerifyTag = "TSP_ATTACH_VERIFY_20260824";')
c='    gles_glFramebufferTexture2D(ntarget, attachment, realtarget, texture, 0);'
NEW='\n'.join([
c,
'    /* TSP_ATTACH_VERIFY_20260824 */',
'    {',
'        static int tspVN = 0;',
'        if (tspVN < 16 && attachment >= GL_COLOR_ATTACHMENT0',
'            && attachment < (GL_COLOR_ATTACHMENT0 + hardext.maxcolorattach)) {',
'            int ct = 0, cn = 0, bind = -1;',
'            unsigned int e = 0;',
'            tspVN++;',
'            tsp_natload();',
'            if (tsp_nat_ge) e = tsp_nat_ge();',
'            if (tsp_nat_gi) tsp_nat_gi(0x8CA6u, &bind);',
'            if (tsp_nat_ga) {',
'                tsp_nat_ga(0x8D40u, 0x8CE0u, 0x8CD0u, &ct);',
'                if (ct) tsp_nat_ga(0x8D40u, 0x8CE0u, 0x8CD1u, &cn);',
'            }',
'            tsp_fbo_log("ATTACHVERIFY gl4esfb=%u ntarget=0x%x att=0x%x realtarget=0x%x tex=%u err=0x%x driverbind=%d after=0x%x/%d",',
'                fb ? fb->id : 0u, ntarget, attachment, realtarget, texture, e, bind, ct, cn);',
'        }',
'    }'])
s=s.replace(c,NEW)
if s.count('{')!=s.count('}'): print('FAIL brace imbalance'); sys.exit(1)
open(p,'w').write(s)
print('PATCHED attach verify')
