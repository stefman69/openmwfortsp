import os, re, sys, time
ROOT = os.environ.get("TSP_ROOT", "/root/openmw-0.51-tsp-src")
F = ROOT + "/components/resource/scenemanager.cpp"
STAMP = time.strftime("%Y%m%d-%H%M%S")

def die(m):
    print("  " + m + "\n\n  NOTHING WRITTEN."); sys.exit(1)

if not os.path.isfile(F): die("ERROR: %s not found." % F)
s = open(F, encoding="utf-8").read()

if "getTspMemoryCacheStats" not in s:
    print("  already clean - no reference to the abandoned purge"); sys.exit(0)

n = s.count("getTspMemoryCacheStats")
if n != 1:
    die("expected exactly 1 reference to getTspMemoryCacheStats, found %d" % n)

rx = re.compile(r'^[ \t]*const CacheStats nodeStats = getTspMemoryCacheStats\(\);\n', re.M)
if len(rx.findall(s)) != 1:
    die("ANCHOR MISS: the nodeStats declaration is not in the expected form")
s = rx.sub('', s, count=1)

rx2 = re.compile(r'^[ \t]*<< " node_cache=" << nodeStats\.mSize\n', re.M)
if len(rx2.findall(s)) != 1:
    die("ANCHOR MISS: the node_cache log term is not in the expected form")
s = rx2.sub('', s, count=1)

if "nodeStats" in s:
    die("nodeStats is still referenced after removal - not safe to write")

d = 0
for ch in s:
    d += (ch == '{') - (ch == '}')
old = open(F, encoding="utf-8").read()
d0 = 0
for ch in old:
    d0 += (ch == '{') - (ch == '}')
if d != d0:
    die("BRACE BALANCE CHANGED (%d -> %d)" % (d0, d))

open(F + ".prepurgefix-" + STAMP, "w", encoding="utf-8").write(old)
open(F, "w", encoding="utf-8").write(s)
print("  removed the two lines that depended on the abandoned gradual purge")
print("  backup %s.prepurgefix-%s" % (F, STAMP))
print("  VERIFIED: getTspMemoryCacheStats gone, nodeStats gone, braces unchanged")
