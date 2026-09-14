import sys
p='/root/gl4es-tsps/src/gl/framebuffers.c'
s=open(p).read()
if 'TSP_FBO_ALWAYS_REATTACH_20260824' in s: print('SKIP already patched'); sys.exit(0)
a='    if ((old_attachment_type == textarget) && (old_attachment == (tex?tex->texture:texture)))'
if s.count(a)!=1:
    print('FAIL anchor matched %d' % s.count(a))
    for i,l in enumerate(s.split("\n")):
        if 'no need to reattach' in l or 'old_attachment_type ==' in l: print('  %d: %s' % (i+1,l))
    sys.exit(1)
s=s.replace(a,'    if (0) /* TSP_FBO_ALWAYS_REATTACH_20260824 - see tag below */')
m='/* TSP_FBO_DIAG_20260815 */'
if s.count(m)!=1: print('FAIL tag anchor x%d' % s.count(m)); sys.exit(1)
s=s.replace(m,'const char* volatile tspFboAlwaysReattachTag = "TSP_FBO_ALWAYS_REATTACH_20260824";\n'+m)
if s.count('{')!=s.count('}'): print('FAIL brace imbalance'); sys.exit(1)
open(p,'w').write(s)
print('PATCHED reattach')
