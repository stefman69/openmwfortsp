import sys
p='/root/openmw-0.51-tsp-src/components/sceneutil/rtt.cpp'
s=open(p).read()
if 'TSP_RTT_PATTERN_V57' in s: print('SKIP already patched'); sys.exit(0)
a='                std::memset(tspImg->data(), 0, tspImg->getTotalSizeInBytes());'
if s.count(a)!=1:
    print('FAIL memset anchor matched %d' % s.count(a))
    for i,l in enumerate(s.split("\n")):
        if 'memset' in l: print('  %d: %s' % (i+1,l))
    sys.exit(1)
NEW='\n'.join([
'                // TSP_RTT_PATTERN_V57 - a readable fill, so an unwritten region is',
'                // visually distinct from a region that was rendered into.',
'                {',
'                    unsigned char* tspD = tspImg->data();',
'                    const bool tspZero = (std::getenv("TSP_RTT_INIT_ZERO") != nullptr);',
'                    for (int tspY = 0; tspY < tspH; ++tspY)',
'                    {',
'                        for (int tspX = 0; tspX < tspW; ++tspX)',
'                        {',
'                            unsigned char* tspP = tspD + ((size_t)tspY * (size_t)tspW + (size_t)tspX) * 4;',
'                            if (tspZero) { tspP[0] = 0; tspP[1] = 0; tspP[2] = 0; tspP[3] = 0; continue; }',
'                            if (tspY < 8) { tspP[0] = 0; tspP[1] = 255; tspP[2] = 0; tspP[3] = 255; continue; }',
'                            const int tspB = (((tspX >> 5) + (tspY >> 5)) & 1);',
'                            tspP[0] = tspB ? 255 : 0;',
'                            tspP[1] = 0;',
'                            tspP[2] = tspB ? 255 : 128;',
'                            tspP[3] = 255;',
'                        }',
'                    }',
'                }'])
s=s.replace(a,NEW)
s=s.replace('"TSP_RTT_INIT_TEXTURE_V55 path=tex2d active="',
            '"TSP_RTT_INIT_TEXTURE_V55 TSP_RTT_PATTERN_V57 path=tex2d active="')
if s.count('{')!=s.count('}'): print('FAIL brace imbalance'); sys.exit(1)
open(p,'w').write(s)
print('PATCHED V57')
