import re,sys
p='/root/openmw-0.51-tsp-src/components/sceneutil/rtt.cpp'
s=open(p).read()
L=s.split('\n')
# --- A: cerr -> Log in the existing V55 block
hit=[i for i,l in enumerate(L) if 'std::cerr << "TSP_RTT_INIT_TEXTURE_V55' in l]
if len(hit)==1:
    k=hit[0]; e=k
    while e<len(L) and not L[e].rstrip().endswith(';'): e+=1
    ind=re.match(r'\s*',L[k]).group(0)
    L[k:e+1]=[ind+'Log(Debug::Warning) << "TSP_RTT_INIT_TEXTURE_V55 path=tex2d active=" << (tspOff ? 0 : 1) << " size=" << tspW << "x" << tspH << " fmt=0x" << std::hex << tspFmt << std::dec << " depth=" << (tspIsDepth ? 1 : 0);']
    print('A: cerr -> Log done')
elif 'path=tex2d' in s: print('A: already Log')
else: print('A: FAIL cerr line matched %d' % len(hit)); sys.exit(1)
s='\n'.join(L)
# --- B: make the image STATIC and release it after upload
if 'TSP_RTT_INIT_STATIC' not in s:
    a='tspImg->setInternalTextureFormat(GL_RGBA);'
    if s.count(a)!=1: print('B: FAIL anchor x%d' % s.count(a)); sys.exit(1)
    s=s.replace(a, a+'\n                tspImg->setDataVariance(osg::Object::STATIC); // TSP_RTT_INIT_STATIC\n                texture->setUnRefImageDataAfterApply(true);')
    print('B: static+unref done')
else: print('B: already present')
# --- C: same treatment for the texture-array path
if 'TSP_RTT_INIT_TEXARRAY_V56' not in s:
    a='        textureArray->setSourceFormat(sourceFormat);'
    if s.count(a)!=1: print('C: FAIL anchor x%d' % s.count(a)); sys.exit(1)
    BLOCK='\n'.join([
'        // TSP_RTT_INIT_TEXARRAY_V56',
'        {',
'            const int tspFmt = textureArray->getInternalFormat();',
'            const bool tspIsDepth = (tspFmt == 0x1902 || tspFmt == 0x81A5 || tspFmt == 0x81A6',
'                || tspFmt == 0x88F0 || tspFmt == 0x84F9 || tspFmt == 0x8CAC || tspFmt == 0x8CAD);',
'            const int tspW = textureArray->getTextureWidth();',
'            const int tspH = textureArray->getTextureHeight();',
'            const int tspD = textureArray->getTextureDepth();',
'            const bool tspOff = (std::getenv("TSP_RTT_NO_INIT") != nullptr);',
'            static bool tspSaidA = false;',
'            if (!tspSaidA)',
'            {',
'                tspSaidA = true;',
'                Log(Debug::Warning) << "TSP_RTT_INIT_TEXTURE_V55 path=texarray active=" << (tspOff ? 0 : 1) << " size=" << tspW << "x" << tspH << "x" << tspD << " fmt=0x" << std::hex << tspFmt << std::dec << " depth=" << (tspIsDepth ? 1 : 0);',
'            }',
'            if (!tspOff && !tspIsDepth && tspW > 0 && tspH > 0)',
'            {',
'                for (int tspL = 0; tspL < (tspD > 0 ? tspD : 1); ++tspL)',
'                {',
'                    osg::ref_ptr<osg::Image> tspImgA = new osg::Image;',
'                    tspImgA->allocateImage(tspW, tspH, 1, GL_RGBA, GL_UNSIGNED_BYTE);',
'                    std::memset(tspImgA->data(), 0, tspImgA->getTotalSizeInBytes());',
'                    tspImgA->setInternalTextureFormat(GL_RGBA);',
'                    tspImgA->setDataVariance(osg::Object::STATIC);',
'                    textureArray->setImage(tspL, tspImgA);',
'                }',
'                textureArray->setUnRefImageDataAfterApply(true);',
'            }',
'        }',
''])
    s=s.replace(a, BLOCK+a)
    print('C: texarray block done')
else: print('C: already present')
if s.count('{')!=s.count('}'): print('FAIL brace imbalance'); sys.exit(1)
open(p,'w').write(s)
print('PATCHED V56')
