import sys
P = "/root/openmw-0.51-tsp-src/apps/openmw/mwrender/occlusionculling.cpp"
if len(sys.argv) > 1:
    P = sys.argv[1]
MARK = "TSP_INTOCC_V1"
src = open(P, encoding="utf-8").read()
if MARK in src:
    print("ALREADY APPLIED: " + MARK + " present. Nothing written.")
    sys.exit(0)
A1 = "#include <cmath>"
A2 = "        std::string_view getModelPathForNode(osg::Node* node)"
A3 = "            if (!bs.valid() || bs.radius() < mOccluderMinRadius)"
A4 = "                    if (!scaledBB.contains(cv->getEyePoint()))"
A5 = "            // is reserved for culling small objects in Pass 2."
fail = []
for nm, a in (("A1", A1), ("A2", A2), ("A3", A3), ("A4", A4), ("A5", A5)):
    n = src.count(a)
    if n != 1:
        fail.append(nm + " matched " + str(n) + " times: " + repr(a))
if fail:
    print("ANCHOR FAILURE - NOTHING WRITTEN")
    for f in fail:
        print("  " + f)
    print("--- survey of nearby lines ---")
    for i, l in enumerate(src.split("\n"), 1):
        if ("scaledBB" in l) or ("getModelPathForNode" in l) or ("cmath" in l) or ("Pass 2" in l) or ("mOccluderMinRadius" in l):
            print("  %5d| %s" % (i, l))
    sys.exit(1)
H = ""
H += "        // TSP_INTOCC_V1 - interior occlusion. Env TSP_INTOCC selects behaviour:\n"
H += "        //   0 = upstream (occluders must not contain the eye; large objects always traversed)\n"
H += "        //   1 = allow occluders that contain the eye, so interior room shells can occlude\n"
H += "        //   2 = 1, plus visibility-test large objects instead of always traversing them\n"
H += "        int tspIntOccMode()\n"
H += "        {\n"
H += "            static int sMode = -1;\n"
H += "            if (sMode < 0)\n"
H += "            {\n"
H += "                const char* e = std::getenv(\"TSP_INTOCC\");\n"
H += "                sMode = (e && e[0] >= '0' && e[0] <= '9') ? (e[0] - '0') : 0;\n"
H += "                Log(Debug::Warning) << \"TSP_INTOCC_V1 mode=\" << sMode;\n"
H += "            }\n"
H += "            return sMode;\n"
H += "        }\n"
H += "\n"
H += "        // One-shot so a null result can be diagnosed without another build.\n"
H += "        void tspIntOccReport(float minR, float maxR, float maxDistSq, float insideThresh)\n"
H += "        {\n"
H += "            static bool sDone = false;\n"
H += "            if (sDone)\n"
H += "                return;\n"
H += "            sDone = true;\n"
H += "            Log(Debug::Warning) << \"TSP_INTOCC_V1 thresholds minRadius=\" << minR << \" maxRadius=\" << maxR\n"
H += "                                << \" maxDistance=\" << std::sqrt(maxDistSq) << \" insideThreshold=\" << insideThresh\n"
H += "                                << \" mode=\" << tspIntOccMode();\n"
H += "        }\n"
H += "\n"
N1 = A1 + "\n#include <cstdlib>"
N2 = H + A2
N3 = "            tspIntOccReport(mOccluderMinRadius, mOccluderMaxRadius, mOccluderMaxDistanceSq, mOccluderInsideThreshold);\n" + A3
N4 = "                    if (tspIntOccMode() >= 1 || !scaledBB.contains(cv->getEyePoint()))"
N5 = A5 + "\n"
N5 += "            if (tspIntOccMode() >= 2)\n"
N5 += "            {\n"
N5 += "                osg::BoundingBox tspBigBB;\n"
N5 += "                tspBigBB.expandBy(bs);\n"
N5 += "                if (!mCuller->testVisibleAABB(tspBigBB))\n"
N5 += "                    continue;\n"
N5 += "            }"
out = src
for a, n in ((A1, N1), (A2, N2), (A3, N3), (A4, N4), (A5, N5)):
    out = out.replace(a, n, 1)
if out.count("{") != out.count("}"):
    print("BRACE IMBALANCE - NOTHING WRITTEN: " + str(out.count("{")) + " open vs " + str(out.count("}")) + " close")
    sys.exit(1)
if out.count(MARK) < 3:
    print("MARKER CHECK FAILED - NOTHING WRITTEN")
    sys.exit(1)
if "#include <cstdlib>" not in out:
    print("CSTDLIB MISSING - NOTHING WRITTEN")
    sys.exit(1)
open(P, "w", encoding="utf-8").write(out)
print("PATCH APPLIED: " + MARK)
print("  file      : " + P)
print("  bytes     : " + str(len(src)) + " -> " + str(len(out)))
print("  braces    : " + str(out.count("{")) + " balanced")
print("  markers   : " + str(out.count(MARK)))
