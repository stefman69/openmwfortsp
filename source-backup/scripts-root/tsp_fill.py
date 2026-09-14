import sys
p='/root/openmw-0.51-tsp-src/components/sceneutil/rtt.cpp'
s=open(p).read()
if 'TSP_RTT_INIT_PATTERN' in s: print('SKIP already flipped'); sys.exit(0)
a='                    const bool tspZero = (std::getenv("TSP_RTT_INIT_ZERO") != nullptr);'
if s.count(a)!=1:
    print('FAIL anchor x%d' % s.count(a))
    for i,l in enumerate(s.split("\n")):
        if 'tspZero' in l: print('  %d: %s' % (i+1,l))
    sys.exit(1)
s=s.replace(a,'                    // TSP_RTT_INIT_PATTERN=1 restores the diagnostic checkerboard.\n'
              '                    const bool tspZero = (std::getenv("TSP_RTT_INIT_PATTERN") == nullptr);')
open(p,'w').write(s)
print('PATCHED fill default -> zero')
