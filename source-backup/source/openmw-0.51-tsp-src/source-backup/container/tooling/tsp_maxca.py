import re,sys
p='/root/gl4es-tsps/src/glx/hardext.c'
s=open(p).read()
if 'TSP_MAXCOLORATTACH_FIX_20260824' in s: print('SKIP already patched'); sys.exit(0)
m=re.search(r'\n[A-Za-z_][A-Za-z0-9_ \*]*\btsp_late_hardext\s*\([^;{]*\)\s*\{', s)
if not m:
    print('FAIL no tsp_late_hardext definition')
    for i,l in enumerate(s.split("\n")):
        if 'late_hardext' in l: print('  %d: %s' % (i+1,l))
    sys.exit(1)
BODY='\n'.join([
'',
'    /* TSP_MAXCOLORATTACH_FIX_20260824 - LIBGL_NOTEST=1 skips GetHardwareExtensions(),',
'       which leaves hardext.maxcolorattach at 0. gl4es_glFramebufferTexture2D then',
'       rejects GL_COLOR_ATTACHMENT0 as out of range and returns GL_INVALID_ENUM before',
'       attaching anything, so every render-to-texture gets a depth attachment and no',
'       colour one. The FBO still reports COMPLETE and every colour fragment is',
'       discarded. GLES2 guarantees at least one colour attachment. */',
'    {',
'        int tspBeforeCA = hardext.maxcolorattach;',
'        int tspBeforeDB = hardext.maxdrawbuffers;',
'        if (hardext.maxcolorattach < 1) hardext.maxcolorattach = 1;',
'        if (hardext.maxdrawbuffers  < 1) hardext.maxdrawbuffers  = 1;',
'        SHUT_LOGD("TSP_MAXCOLORATTACH before=%d/%d after=%d/%d\\n",',
'            tspBeforeCA, tspBeforeDB, hardext.maxcolorattach, hardext.maxdrawbuffers);',
'    }'])
s=s[:m.end()]+BODY+s[m.end():]
if s.count('{')!=s.count('}'): print('FAIL brace imbalance'); sys.exit(1)
open(p,'w').write(s)
print('PATCHED maxcolorattach')
