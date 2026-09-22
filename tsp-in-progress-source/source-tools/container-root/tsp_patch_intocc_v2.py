import sys
P = "/root/openmw-0.51-tsp-src/apps/openmw/mwrender/occlusionculling.cpp"
if len(sys.argv) > 1:
    P = sys.argv[1]
MARK = "TSP_INTOCC_V2"
src = open(P, encoding="utf-8").read()
if MARK in src:
    print("ALREADY APPLIED: " + MARK + " present. Nothing written.")
    sys.exit(0)
if "TSP_INTOCC_V1" in src:
    print("REFUSING: file still carries TSP_INTOCC_V1. Restore the pristine backup first.")
    sys.exit(1)
A1 = "#include <cmath>"
A2 = "        std::string_view getModelPathForNode(osg::Node* node)"
A3 = "            if (!bs.valid() || bs.radius() < mOccluderMinRadius)"
A4 = "                    if (!scaledBB.contains(cv->getEyePoint()))"
A5 = "            // is reserved for culling small objects in Pass 2."
A6 = "        , mEnableStaticOccluders(enableStaticOccluders)"
fail = []
for nm, a in (("A1", A1), ("A2", A2), ("A3", A3), ("A4", A4), ("A5", A5), ("A6", A6)):
    n = src.count(a)
    if n != 1:
        fail.append(nm + " matched " + str(n) + " times: " + repr(a))
if fail:
    print("ANCHOR FAILURE - NOTHING WRITTEN")
    for f in fail:
        print("  " + f)
    print("--- survey ---")
    for i, l in enumerate(src.split("\n"), 1):
        if ("scaledBB" in l) or ("getModelPathForNode" in l) or ("cmath" in l) or ("Pass 2" in l) or ("mOccluderMinRadius" in l) or ("EnableStaticOccluders" in l):
            print("  %5d| %s" % (i, l))
    sys.exit(1)
H = ""
H += "        // TSP_INTOCC_V2 - interior occlusion. Env TSP_INTOCC: 0 = upstream (default),\n"
H += "        // 1 = also rasterise occluders that contain the eye (interior room shells),\n"
H += "        // 2 = 1 plus visibility-test large objects instead of always traversing them.\n"
H += "        // V1 had NO budget on the eye-inside case and stalled the frame. Every limit\n"
H += "        // below is hard-capped and env-tunable without a rebuild.\n"
H += "        struct TspIntOccCfg\n"
H += "        {\n"
H += "            int mMode;\n"
H += "            int mMaxOcc;\n"
H += "            int mMaxTri;\n"
H += "            int mBudget;\n"
H += "            int mMinRMul;\n"
H += "        };\n"
H += "\n"
H += "        int tspIntOccEnvInt(const char* name, int def)\n"
H += "        {\n"
H += "            const char* e = std::getenv(name);\n"
H += "            if (e == nullptr || e[0] == 0)\n"
H += "                return def;\n"
H += "            return std::atoi(e);\n"
H += "        }\n"
H += "\n"
H += "        const TspIntOccCfg& tspIntOccCfg()\n"
H += "        {\n"
H += "            static TspIntOccCfg sCfg;\n"
H += "            static bool sInit = false;\n"
H += "            if (!sInit)\n"
H += "            {\n"
H += "                sInit = true;\n"
H += "                sCfg.mMode = tspIntOccEnvInt(\"TSP_INTOCC\", 0);\n"
H += "                if (sCfg.mMode < 0)\n"
H += "                    sCfg.mMode = 0;\n"
H += "                sCfg.mMaxOcc = tspIntOccEnvInt(\"TSP_INTOCC_MAXOCC\", 12);\n"
H += "                sCfg.mMaxTri = tspIntOccEnvInt(\"TSP_INTOCC_MAXTRI\", 512);\n"
H += "                sCfg.mBudget = tspIntOccEnvInt(\"TSP_INTOCC_BUDGET\", 8000);\n"
H += "                sCfg.mMinRMul = tspIntOccEnvInt(\"TSP_INTOCC_MINRMUL\", 2);\n"
H += "                if (sCfg.mMinRMul < 1)\n"
H += "                    sCfg.mMinRMul = 1;\n"
H += "                Log(Debug::Warning) << \"TSP_INTOCC_V2 mode=\" << sCfg.mMode << \" maxocc=\" << sCfg.mMaxOcc\n"
H += "                                    << \" maxtri=\" << sCfg.mMaxTri << \" budget=\" << sCfg.mBudget\n"
H += "                                    << \" minrmul=\" << sCfg.mMinRMul;\n"
H += "            }\n"
H += "            return sCfg;\n"
H += "        }\n"
H += "\n"
H += "        unsigned int sTspIntOccFrame = 0xffffffffu;\n"
H += "        int sTspIntOccCount = 0;\n"
H += "        int sTspIntOccTris = 0;\n"
H += "        int sTspIntOccSeen = 0;\n"
H += "        int sTspIntOccRejSmall = 0;\n"
H += "        int sTspIntOccRejTri = 0;\n"
H += "        int sTspIntOccRejCap = 0;\n"
H += "        int sTspIntOccReports = 0;\n"
H += "\n"
H += "        void tspIntOccBeginFrame(unsigned int frame)\n"
H += "        {\n"
H += "            if (frame == sTspIntOccFrame)\n"
H += "                return;\n"
H += "            if (sTspIntOccFrame != 0xffffffffu && sTspIntOccReports < 10 && tspIntOccCfg().mMode >= 1)\n"
H += "            {\n"
H += "                ++sTspIntOccReports;\n"
H += "                Log(Debug::Warning) << \"TSP_INTOCC_V2 frame=\" << sTspIntOccFrame << \" eyeinside_seen=\" << sTspIntOccSeen\n"
H += "                                    << \" rasterised=\" << sTspIntOccCount << \" tris=\" << sTspIntOccTris\n"
H += "                                    << \" rej_small=\" << sTspIntOccRejSmall << \" rej_tri=\" << sTspIntOccRejTri\n"
H += "                                    << \" rej_cap=\" << sTspIntOccRejCap;\n"
H += "            }\n"
H += "            sTspIntOccFrame = frame;\n"
H += "            sTspIntOccCount = 0;\n"
H += "            sTspIntOccTris = 0;\n"
H += "            sTspIntOccSeen = 0;\n"
H += "            sTspIntOccRejSmall = 0;\n"
H += "            sTspIntOccRejTri = 0;\n"
H += "            sTspIntOccRejCap = 0;\n"
H += "        }\n"
H += "\n"
H += "        bool tspIntOccAllowInside(float radius, float minRadius, int tris)\n"
H += "        {\n"
H += "            const TspIntOccCfg& c = tspIntOccCfg();\n"
H += "            ++sTspIntOccSeen;\n"
H += "            if (radius < minRadius * static_cast<float>(c.mMinRMul))\n"
H += "            {\n"
H += "                ++sTspIntOccRejSmall;\n"
H += "                return false;\n"
H += "            }\n"
H += "            if (c.mMaxTri > 0 && tris > c.mMaxTri)\n"
H += "            {\n"
H += "                ++sTspIntOccRejTri;\n"
H += "                return false;\n"
H += "            }\n"
H += "            if ((c.mMaxOcc > 0 && sTspIntOccCount >= c.mMaxOcc)\n"
H += "                || (c.mBudget > 0 && sTspIntOccTris + tris > c.mBudget))\n"
H += "            {\n"
H += "                ++sTspIntOccRejCap;\n"
H += "                return false;\n"
H += "            }\n"
H += "            ++sTspIntOccCount;\n"
H += "            sTspIntOccTris += tris;\n"
H += "            return true;\n"
H += "        }\n"
H += "\n"
N1 = A1 + "\n#include <cstdlib>"
N2 = H + A2
N3 = "            tspIntOccBeginFrame(cv->getTraversalNumber());\n" + A3
N4 = "                    const bool tspEyeInside = scaledBB.contains(cv->getEyePoint());\n"
N4 += "                    const int tspTris = static_cast<int>(mesh.indices.size() / 3);\n"
N4 += "                    if (!tspEyeInside\n"
N4 += "                        || (tspIntOccCfg().mMode >= 1\n"
N4 += "                            && tspIntOccAllowInside(bs.radius(), mOccluderMinRadius, tspTris)))"
N5 = A5 + "\n"
N5 += "            if (tspIntOccCfg().mMode >= 2)\n"
N5 += "            {\n"
N5 += "                osg::BoundingBox tspBigBB;\n"
N5 += "                tspBigBB.expandBy(bs);\n"
N5 += "                if (!mCuller->testVisibleAABB(tspBigBB))\n"
N5 += "                    continue;\n"
N5 += "            }"
N6 = A6 + "\n        // TSP_INTOCC_V2 - force the config to resolve and log at cell-load time, well\n        // before the first gameplay frame, so a lost log tail cannot hide whether it ran."
out = src
for a, n in ((A1, N1), (A2, N2), (A3, N3), (A4, N4), (A5, N5), (A6, N6)):
    out = out.replace(a, n, 1)
CTOR = "        , mStorage(storage)\n    {\n    }\n\n    const OccluderMesh& CellOcclusionCallback::getOccluderMesh"
CTORNEW = "        , mStorage(storage)\n    {\n        tspIntOccCfg();\n    }\n\n    const OccluderMesh& CellOcclusionCallback::getOccluderMesh"
if out.count(CTOR) != 1:
    print("ANCHOR FAILURE: CellOcclusionCallback ctor body matched " + str(out.count(CTOR)) + " times - NOTHING WRITTEN")
    sys.exit(1)
out = out.replace(CTOR, CTORNEW, 1)
if out.count("{") != out.count("}"):
    print("BRACE IMBALANCE - NOTHING WRITTEN: " + str(out.count("{")) + " vs " + str(out.count("}")))
    sys.exit(1)
if out.count(MARK) < 4:
    print("MARKER CHECK FAILED (" + str(out.count(MARK)) + ") - NOTHING WRITTEN")
    sys.exit(1)
if "#include <cstdlib>" not in out or "tspIntOccCfg();" not in out:
    print("REQUIRED FRAGMENT MISSING - NOTHING WRITTEN")
    sys.exit(1)
open(P, "w", encoding="utf-8").write(out)
print("PATCH APPLIED: " + MARK)
print("  bytes   : " + str(len(src)) + " -> " + str(len(out)))
print("  braces  : " + str(out.count("{")) + " balanced")
print("  markers : " + str(out.count(MARK)))
