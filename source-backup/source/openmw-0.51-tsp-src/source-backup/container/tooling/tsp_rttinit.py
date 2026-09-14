import re,sys
p='/root/openmw-0.51-tsp-src/components/sceneutil/rtt.cpp'
s=open(p).read()
if 'TSP_RTT_INIT_TEXTURE_V55' in s:
    print('SKIP already patched'); sys.exit(0)
L=s.split('\n')
hit=[i for i,l in enumerate(L) if 'TSP_RTT_DYNAMIC_V53' in l]
if len(hit)!=1:
    print('FAIL TSP_RTT_DYNAMIC_V53 matched %d times' % len(hit))
    for i,l in enumerate(L):
        if 'setDataVariance' in l or 'createTexture' in l: print('  %d: %s' % (i+1,l))
    sys.exit(1)
k=hit[0]
while k < len(L) and not L[k].rstrip().endswith(';'): k+=1
if k>=len(L): print('FAIL no statement after marker'); sys.exit(1)
ind=re.match(r'\s*',L[hit[0]]).group(0)
BODY=[
'// TSP_RTT_INIT_TEXTURE_V55',
'{',
'    const int tspFmt = texture->getInternalFormat();',
'    const bool tspIsDepth = (tspFmt == 0x1902 || tspFmt == 0x81A5 || tspFmt == 0x81A6',
'        || tspFmt == 0x88F0 || tspFmt == 0x84F9 || tspFmt == 0x8CAC || tspFmt == 0x8CAD);',
'    const int tspW = texture->getTextureWidth();',
'    const int tspH = texture->getTextureHeight();',
'    const bool tspOff = (std::getenv("TSP_RTT_NO_INIT") != nullptr);',
'    static bool tspSaid = false;',
'    if (!tspSaid)',
'    {',
'        tspSaid = true;',
'        std::cerr << "TSP_RTT_INIT_TEXTURE_V55 active=" << (tspOff ? 0 : 1)',
'                  << " first=" << tspW << "x" << tspH << " fmt=0x" << std::hex << tspFmt',
'                  << std::dec << " depth=" << (tspIsDepth ? 1 : 0) << std::endl;',
'    }',
'    if (!tspOff && !tspIsDepth && tspW > 0 && tspH > 0)',
'    {',
'        osg::ref_ptr<osg::Image> tspImg = new osg::Image;',
'        tspImg->allocateImage(tspW, tspH, 1, GL_RGBA, GL_UNSIGNED_BYTE);',
'        std::memset(tspImg->data(), 0, tspImg->getTotalSizeInBytes());',
'        tspImg->setInternalTextureFormat(GL_RGBA);',
'        texture->setImage(tspImg);',
'    }',
'}',
]
L[k+1:k+1]=[ind+b for b in BODY]
s='\n'.join(L)
for inc in ('<osg/Image>','<cstring>','<cstdlib>','<iostream>'):
    if '#include '+inc not in s:
        LL=s.split('\n')
        last=max(i for i,l in enumerate(LL) if l.startswith('#include'))
        LL.insert(last+1,'#include '+inc)
        s='\n'.join(LL)
if s.count('{')!=s.count('}'): print('FAIL brace imbalance'); sys.exit(1)
open(p,'w').write(s)
print('PATCHED V55')
