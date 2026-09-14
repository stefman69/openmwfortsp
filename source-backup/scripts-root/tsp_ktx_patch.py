#!/usr/bin/env python3
# TSP_KTX_V1 patcher. Idempotent, transactional, prints every anchor as tried.
import os, shutil, sys, time

SRC = os.environ.get("TSP_SRC", "/root/openmw-0.51-tsp-src")
STAMP = time.strftime("%Y%m%d-%H%M%S")

HELPERS = r'''
    // TSP_KTX_V1 - prefer a sibling .ktx (ASTC/ETC2) over the resolved .dds when one exists.
    // gl4es hands non-DXTc compressed formats straight to GLES, so a .ktx is uploaded with no
    // CPU decompress, no pixel_convert and no halfscale chain, and stays 2 bpp resident.
    // Gated on TSP_KTX=1 so a binary without converted textures behaves exactly as before.
    bool tspKtxEnabled()
    {
        static const bool tspEnabled = [] {
            const char* const tspEnv = std::getenv("TSP_KTX");
            return tspEnv != nullptr && tspEnv[0] == '1';
        }();
        return tspEnabled;
    }

    void tspPreferKtx(VFS::Path::Normalized& path, const VFS::Manager& vfs)
    {
        if (tspKtxEnabled() == false)
            return;
        VFS::Path::Normalized tspCandidate = path;
        if (tspCandidate.changeExtension(ktx) == false)
            return;
        if (vfs.exists(tspCandidate))
            path = std::move(tspCandidate);
    }
'''

KTXLOG = r'''            // TSP_KTX_V1 - first few only, enough to prove the format and mip chain arrived intact.
            if (ext == "ktx")
            {
                static int tspKtxLogged = 0;
                if (tspKtxLogged < 8)
                {
                    ++tspKtxLogged;
                    Log(Debug::Warning)
                        << "TSP_KTX_V1 loaded " << path << " compressed=" << image->isCompressed()
                        << " fmt=" << image->getPixelFormat() << " " << image->s() << "x" << image->t()
                        << " levels=" << image->getNumMipmapLevels()
                        << " bytes=" << image->getTotalSizeInBytesIncludingMipmaps();
                }
            }

'''

EDITS = [
    (
        "components/misc/resourcehelpers.cpp",
        "rh-include",
        "#include <components/vfs/pathutil.hpp>",
        "before",
        "#include <cstdlib>\n\n",
    ),
    (
        "components/misc/resourcehelpers.cpp",
        "rh-ktx-constant",
        '    constexpr VFS::Path::ExtensionView dds("dds");',
        "after",
        '\n    constexpr VFS::Path::ExtensionView ktx("ktx"); // TSP_KTX_V1',
    ),
    (
        "components/misc/resourcehelpers.cpp",
        "rh-helpers",
        "    bool changeExtension(std::string& path, std::string_view ext)",
        "before",
        HELPERS.lstrip("\n") + "\n",
    ),
    (
        "components/misc/resourcehelpers.cpp",
        "rh-texture-path",
        "    return correctResourcePath({ { textures, bookart } }, resPath, vfs, dds);",
        "replace",
        "    // TSP_KTX_V1\n"
        "    VFS::Path::Normalized tspResult = correctResourcePath({ { textures, bookart } }, resPath, vfs, dds);\n"
        "    tspPreferKtx(tspResult, vfs);\n"
        "    return tspResult;",
    ),
    (
        "components/resource/imagemanager.cpp",
        "im-origin",
        '            if (ext == "dds")\n                image->setOrigin(osg::Image::TOP_LEFT);',
        "replace",
        "            // TSP_KTX_V1 - the converter preserves DDS row order, so a .ktx is top-left too.\n"
        "            // Without this the flip guard below rejects it as a non-S3TC compressed image\n"
        "            // and paints the magenta warning texture instead.\n"
        '            if (ext == "dds" || ext == "ktx")\n'
        "                image->setOrigin(osg::Image::TOP_LEFT);",
    ),
    (
        "components/resource/imagemanager.cpp",
        "im-log",
        "            mCache->addEntryToObjectCache(path.value(), image);\n            return image;",
        "before",
        KTXLOG,
    ),
]

files = sorted({e[0] for e in EDITS})

original = {}
for rel in files:
    path = os.path.join(SRC, rel)
    if not os.path.isfile(path):
        print("FAIL  missing source file: " + path); sys.exit(1)
    with open(path, "r", encoding="utf-8") as fh:
        original[rel] = fh.read()

already = [rel for rel in files if "TSP_KTX_V1" in original[rel]]
if already:
    print("ALREADY PATCHED - nothing done. TSP_KTX_V1 found in:")
    for rel in already:
        print("      " + rel + "   occurrences=" + str(original[rel].count("TSP_KTX_V1")))
    sys.exit(2)

print("=== backups ===")
for rel in files:
    path = os.path.join(SRC, rel)
    bak = path + ".before-ktx-" + STAMP
    shutil.copy2(path, bak)
    print("      " + bak + "   " + str(os.path.getsize(bak)) + " bytes")

print("=== anchors ===")
patched = dict(original)
ok = True
for rel, label, anchor, where, payload in EDITS:
    n = patched[rel].count(anchor)
    status = "OK" if n == 1 else "FAIL"
    print("      " + status + "  " + rel + "  [" + label + "]  matches=" + str(n))
    if n != 1:
        ok = False
        needle = anchor.strip().split("\n")[0][:44]
        print("      ---- lines containing " + repr(needle) + " ----")
        for i, line in enumerate(patched[rel].split("\n"), 1):
            if needle in line:
                print("      " + str(i) + ": " + line)
        print("      ---- end ----")
        continue
    if where == "before":
        patched[rel] = patched[rel].replace(anchor, payload + anchor, 1)
    elif where == "after":
        patched[rel] = patched[rel].replace(anchor, anchor + payload, 1)
    else:
        patched[rel] = patched[rel].replace(anchor, payload, 1)

if not ok:
    print("=== NO FILE WRITTEN - an anchor did not match exactly once ===")
    sys.exit(1)

print("=== write ===")
for rel in files:
    with open(os.path.join(SRC, rel), "w", encoding="utf-8") as fh:
        fh.write(patched[rel])
    print("      " + rel + "   +"
          + str(len(patched[rel].split("\n")) - len(original[rel].split("\n")))
          + " lines, TSP_KTX_V1=" + str(patched[rel].count("TSP_KTX_V1")))

rh = patched["components/misc/resourcehelpers.cpp"]
im = patched["components/resource/imagemanager.cpp"]
print("=== counts ===")
print("      tspPreferKtx defined=" + str(rh.count("void tspPreferKtx")) + " (want 1)"
      + "  called=" + str(rh.count("tspPreferKtx(tspResult")) + " (want 1)")
print("      ktx origin branch=" + str(im.count('ext == "ktx"')) + " (want 2)")
print("      no header was touched: " + str(all(f.endswith(".cpp") for f in files)))
if rh.count("void tspPreferKtx") != 1 or rh.count("tspPreferKtx(tspResult") != 1 or im.count('ext == "ktx"') != 2:
    print("FAIL  count assertion"); sys.exit(1)
print("=== PATCH OK ===")
