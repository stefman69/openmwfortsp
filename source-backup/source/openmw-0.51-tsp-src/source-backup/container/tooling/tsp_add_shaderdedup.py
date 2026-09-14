#!/usr/bin/env python3
"""
tsp_add_shaderdedup.py

Stop compiling the same GLSL over and over.

===========================================================================
THE BUG
===========================================================================

components/shader/shadermanager.hpp:

    typedef std::pair<std::string, DefineMap> MapKey;
    typedef std::map<MapKey, osg::ref_ptr<osg::Shader>> ShaderMap;
    ShaderMap mShaders;

    typedef std::map<std::pair<osg::ref_ptr<osg::Shader>,
                               osg::ref_ptr<osg::Shader>>,
                     osg::ref_ptr<osg::Program>> ProgramMap;
    ProgramMap mPrograms;

mShaders is keyed on the DEFINE MAP. mPrograms is keyed on SHADER POINTER
IDENTITY. So two define maps that generate byte-identical GLSL produce two
separate osg::Shader objects, which produce two separate osg::Program
objects, and the driver compiles the same code twice.

Measured on device: 98 shader objects for 31 unique texts. One fragment
shader appeared 16 times. On Mali-G57 each program costs ~137ms in
glLinkProgram plus ~236ms deferred into its first draw, so every duplicate
is ~370ms of pure waste.

Why duplicates are so common here: ShaderVisitor::createProgram writes a UV
index for every texture slot whether or not that slot is used -

    defineMap[texIt->second] = "1";
    defineMap[texIt->second + "UV"] = std::to_string(texIt->first);

and defines are substituted into #if conditions rather than removed, so the
dumped shaders are full of "#if 0 varying vec2 envMapUV; #endif". When
envMap is 0 the value of envMapUV cannot affect the output text, but it
still differs in the map key. Same GLSL, different key, extra compile.

===========================================================================
THE FIX
===========================================================================

Add a second cache in front of the define-keyed one, keyed on the generated
source text and shader type. In getShader, after createSourceFromTemplate
produces the final source:

  - look the source up; on a hit, reuse that existing osg::Shader, record it
    under the new define key too, and return it
  - on a miss, create the shader as before and record it under both keys

Because mPrograms keys on shader pointers, reusing the pointer makes program
lookup hit as well, so duplicate programs disappear for free.

This is safe: shaders are immutable once built here, and a shader whose
source is identical is interchangeable by definition. Linked shaders are
resolved on the original, so the reuse path correctly skips getLinkedShaders.

===========================================================================
WHAT TO EXPECT
===========================================================================

  grep -c "TSP_WARMDRAW queued" openmw.log   -> program count, was 15
  grep -c "^LINK" tsp_diag.txt               -> link count, was 17
  grep "TSP_DEDUP" openmw.log                -> hits, and unique vs total

If the 98/31 ratio holds, program count should fall substantially and total
warm-up cost falls with it. This reduces the NUMBER of compiles; it does not
make an individual compile faster.

Honest caveat: if OpenMW's define maps for the programs that actually matter
are all genuinely distinct, dedup hits will be low and this changes little.
The TSP_DEDUP counters say which, immediately.

===========================================================================
USAGE
===========================================================================

  python3 tsp_add_shaderdedup.py           apply
  python3 tsp_add_shaderdedup.py --revert  restore newest backups
"""

import glob
import os
import shutil
import sys
import time

C = "/root/openmw-0.51-tsp-src/components/shader"
HPP = C + "/shadermanager.hpp"
CPP = C + "/shadermanager.cpp"
TAG = "TSP_SHADER_DEDUP"


def backup(p):
    shutil.copy(p, p + ".before-dedup-" + time.strftime("%Y%m%d-%H%M%S"))


def revert():
    n = 0
    for p in (HPP, CPP):
        b = sorted(glob.glob(p + ".before-dedup-*"))
        if b:
            shutil.copy(b[-1], p)
            print("restored", os.path.basename(p))
            n += 1
    return 0 if n else 1


HPP_MEMBERS = """
        /* """ + TAG + """: mShaders is keyed on the DefineMap, but many
           different define maps generate byte-identical GLSL - unused texture
           slots still contribute a UV index to the key while landing inside
           "#if 0" in the output. Measured 98 shader objects for 31 unique
           texts, one of them repeated 16 times, each duplicate costing Mali
           ~137ms to link plus ~236ms on its first draw. This second cache is
           keyed on the generated source so identical GLSL reuses one
           osg::Shader; since mPrograms keys on shader pointers, duplicate
           programs then collapse as well. */
        typedef std::pair<int, std::string> SourceKey;
        typedef std::map<SourceKey, osg::ref_ptr<osg::Shader>> SourceShaderMap;
        SourceShaderMap mShadersBySource;
        unsigned int mDedupHits = 0;
        unsigned int mDedupMisses = 0;
"""

CPP_LOOKUP = """
            /* """ + TAG + """: reuse an existing shader whose generated source
               is byte-identical, so the driver compiles this code once rather
               than once per define map that happens to produce it. */
            const int tspShaderType
                = static_cast<int>(type ? *type : getShaderType(templateName));
            SourceKey tspSourceKey(tspShaderType, shaderSource);
            SourceShaderMap::iterator tspDedup = mShadersBySource.find(tspSourceKey);
            if (tspDedup != mShadersBySource.end() && tspDedup->second)
            {
                ++mDedupHits;
                Log(Debug::Info) << "TSP_DEDUP reuse " << templateName
                                 << " hits=" << mDedupHits
                                 << " unique=" << mShadersBySource.size()
                                 << " total=" << (mDedupHits + mDedupMisses);
                shaderIt = mShaders.insert(
                    std::make_pair(std::make_pair(templateName, defines), tspDedup->second)).first;
                return shaderIt->second;
            }
            ++mDedupMisses;
"""

CPP_INSERT = """
            /* """ + TAG + """: record under the source key too, so the next
               define map that generates this same text reuses this shader. */
            mShadersBySource[tspSourceKey] = shader;
"""


def main():
    if "--revert" in sys.argv:
        return revert()

    for p in (HPP, CPP):
        if not os.path.exists(p):
            print("ERROR: missing", p)
            return 1

    report = []

    # ---------------- header ----------------
    h = open(HPP).read()
    if TAG in h:
        print("header already patched")
    else:
        anchor = "        ProgramMap mPrograms;"
        if anchor not in h:
            print("ERROR: 'ProgramMap mPrograms;' not found. Candidates:")
            for i, l in enumerate(h.split("\n"), 1):
                if "mPrograms" in l:
                    print("  %d: %s" % (i, l.rstrip()[:90]))
            return 1
        h = h.replace(anchor, anchor + "\n" + HPP_MEMBERS, 1)
        backup(HPP)
        open(HPP, "w").write(h)
        report.append("shadermanager.hpp: source-keyed cache + counters")

    # ---------------- implementation ----------------
    s = open(CPP).read()
    if TAG in s:
        print("shadermanager.cpp already patched")
    else:
        # 1. lookup, immediately after the source is generated and validated
        anchor = """            osg::ref_ptr<osg::Shader> shader(new osg::Shader(type ? *type : getShaderType(templateName)));"""
        if anchor not in s:
            print("ERROR: shader construction anchor not found. Candidates:")
            for i, l in enumerate(s.split("\n"), 1):
                if "new osg::Shader(" in l:
                    print("  %d: %s" % (i, l.rstrip()[:100]))
            return 1
        s = s.replace(anchor, CPP_LOOKUP + anchor, 1)

        # 2. record the new shader under the source key as well
        anchor2 = """            shaderIt = mShaders.insert(std::make_pair(std::make_pair(templateName, defines), shader)).first;"""
        if anchor2 not in s:
            print("ERROR: mShaders.insert anchor not found. Candidates:")
            for i, l in enumerate(s.split("\n"), 1):
                if "mShaders.insert" in l:
                    print("  %d: %s" % (i, l.rstrip()[:100]))
            return 1
        s = s.replace(anchor2, CPP_INSERT + anchor2, 1)

        backup(CPP)
        open(CPP, "w").write(s)
        report.append("shadermanager.cpp: dedup lookup + record in getShader")

    print("\n".join("  " + r for r in report) if report else "  nothing to do")
    print("\nbuild with:")
    print("  cd /root/openmw-0.51-tsp-build && cmake --build . --target openmw --parallel 4")
    return 0


sys.exit(main())
