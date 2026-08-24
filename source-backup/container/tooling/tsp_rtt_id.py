import os, re, sys, time
ROOT = os.environ.get("TSP_ROOT", "/root/openmw-0.51-tsp-src")
F = ROOT + "/components/sceneutil/rtt.cpp"
STAMP = time.strftime("%Y%m%d-%H%M%S")

def die(m):
    print("  " + m + "\n\n  NOTHING WRITTEN."); sys.exit(1)

def sub1(s, rx, rep, what):
    n = len(rx.findall(s))
    if n != 1: die("ANCHOR MISS (%s): expected 1, found %d." % (what, n))
    return rx.sub(rep, s, count=1)

print("\n  TSP_RTT_IDENTITY_V1   which VDD entry does each caller get")
print("  ========================================================\n")
if not os.path.isfile(F): die("ERROR: %s not found." % F)
s = open(F, encoding="utf-8").read()
if "TSP_RTT_IDENTITY_V1" in s:
    print("  already applied"); sys.exit(0)

if "debuglog.hpp" not in s:
    s = sub1(s, re.compile(r'^#include "rtt\.hpp"\n', re.M),
             lambda m: m.group(0) + '\n#include <components/debug/debuglog.hpp>\n',
             "rtt.hpp include")
    print("  added   #include <components/debug/debuglog.hpp>")

s = sub1(s, re.compile(
    r'^([ \t]*)RTTNode::ViewDependentData\* RTTNode::getViewDependentData\(osgUtil::CullVisitor\* cv\)\n'
    r'([ \t]*)\{\n'
    r'([ \t]*)if \(!shouldDoPerViewMapping\(\)\)\n', re.M),
    lambda m: (m.group(1) + 'RTTNode::ViewDependentData* RTTNode::getViewDependentData(osgUtil::CullVisitor* cv)\n'
        + m.group(2) + '{\n'
        + m.group(3) + '// TSP_RTT_IDENTITY_V1 - instrument, measures only, changes no behaviour.\n'
        + m.group(3) + '// CharacterPreview::getTexture() calls getColorTexture(nullptr) while the cull\n'
        + m.group(3) + '// traversal calls it with a real CullVisitor. Those are the same map entry ONLY\n'
        + m.group(3) + '// when shouldDoPerViewMapping() is false. If it is true, the GUI gets its own\n'
        + m.group(3) + '// entry - its own camera and its own colour texture - that nothing renders into.\n'
        + m.group(3) + 'osgUtil::CullVisitor* const tspInCv = cv;\n'
        + m.group(3) + 'bool tspCreated = false;\n\n'
        + m.group(3) + 'if (!shouldDoPerViewMapping())\n'),
    "getViewDependentData head")

s = sub1(s, re.compile(
    r'^([ \t]*)if \(mViewDependentDataMap\.count\(cv\) == 0\)\n'
    r'([ \t]*)\{\n'
    r'([ \t]*)auto camera = new osg::Camera\(\);\n', re.M),
    lambda m: (m.group(1) + 'if (mViewDependentDataMap.count(cv) == 0)\n'
        + m.group(2) + '{\n'
        + m.group(3) + 'tspCreated = true;   // TSP_RTT_IDENTITY_V1\n'
        + m.group(3) + 'auto camera = new osg::Camera();\n'),
    "map-miss branch")

s = sub1(s, re.compile(
    r'^([ \t]*)return mViewDependentDataMap\[cv\]\.get\(\);\n', re.M),
    lambda m: (m.group(1) + '// TSP_RTT_IDENTITY_V1\n'
        + m.group(1) + '{\n'
        + m.group(1) + '    ViewDependentData* tspVdd = mViewDependentDataMap[cv].get();\n'
        + m.group(1) + '    static int tspLogged = 0;\n'
        + m.group(1) + '    if (tspLogged < 60)\n'
        + m.group(1) + '    {\n'
        + m.group(1) + '        ++tspLogged;\n'
        + m.group(1) + '        Log(Debug::Warning) << "TSP_RTT_ID node=" << static_cast<const void*>(this)\n'
        + m.group(1) + '            << " in_cv=" << static_cast<const void*>(tspInCv)\n'
        + m.group(1) + '            << " key_cv=" << static_cast<const void*>(cv)\n'
        + m.group(1) + '            << " perview=" << (shouldDoPerViewMapping() ? 1 : 0)\n'
        + m.group(1) + '            << " created=" << (tspCreated ? 1 : 0)\n'
        + m.group(1) + '            << " entries=" << static_cast<int>(mViewDependentDataMap.size())\n'
        + m.group(1) + '            << " color=" << static_cast<const void*>(tspVdd->mColorTexture.get())\n'
        + m.group(1) + '            << " size=" << mTextureWidth << "x" << mTextureHeight\n'
        + m.group(1) + '            << " samples=" << mSamples;\n'
        + m.group(1) + '    }\n'
        + m.group(1) + '}\n'
        + m.group(1) + 'return mViewDependentDataMap[cv].get();\n'),
    "return statement")

d = 0
for ch in s:
    d += (ch == '{') - (ch == '}')
if d != 0: die("BRACE IMBALANCE (depth %d)." % d)

open(F + ".tsprttid-" + STAMP, "w", encoding="utf-8").write(open(F, encoding="utf-8").read())
open(F, "w", encoding="utf-8").write(s)
print("\n  backup   %s.tsprttid-%s" % (F, STAMP))
print("\n  VERIFIED: instrument applied, braces balanced, no behaviour changed")
