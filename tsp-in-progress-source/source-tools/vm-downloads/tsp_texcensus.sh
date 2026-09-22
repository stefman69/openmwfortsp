#!/bin/bash
# tsp_texcensus.sh - TSP_TEXCENSUS_V1
#
# Answers: how many places in the engine can hand the texture pipeline a name that
# is not a string literal, and which of those lack an empty-name guard.
#
# A literal-named request (getImage("textures/tx_sun_05.dds")) can never be empty.
# Only a variable-named one can do what SkyManager::setWeather did. This walks every
# call site of the name-resolving functions, classifies the first argument, and
# reports whether an .empty() check guards it.
#
# Read only. Nothing is written on the device or in the container.
# Output: terminal summary + full table in ~/Downloads/tsp_texcensus_<stamp>.txt

set -u

CTR=openmw_builder
SRC=/root/openmw-0.51-tsp-src
STAMP=$(date +%Y%m%d-%H%M%S)
OUT="$HOME/Downloads/tsp_texcensus_$STAMP.txt"
mkdir -p "$HOME/Downloads"

d()  { docker exec "$CTR" "$@" </dev/null; }
di() { docker exec -i "$CTR" "$@"; }

say() { echo "$*"; }

say "TSP_TEXCENSUS_V1"
d test -d "$SRC" >/dev/null 2>&1 || { echo "STOPPED: container $CTR not up, or $SRC missing"; exit 1; }
say "scanning $SRC ..."

di python3 - "$SRC" > "$OUT" 2>&1 <<'PYEOF'
import os, re, sys, io

src = sys.argv[1]

# The functions that turn a name into an image or a resolved texture path.
FUNCS = ["getImage", "correctTexturePath", "correctIconPath", "correctBigIconPath",
         "correctBookartPath", "getTexture2D"]
CALL = re.compile(r"\b(" + "|".join(FUNCS) + r")\s*\(")

# constexpr VFS::Path::NormalizedView foo("textures/bar.dds");  -> foo is a literal
LITDECL = re.compile(r"(?:constexpr|const)\s+.*?(?:NormalizedView|Normalized)\s+(\w+)\s*\(\s*\"")

def first_arg(text, open_idx):
    depth, i, n = 0, open_idx, len(text)
    while i < n:
        c = text[i]
        if c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
            if depth == 0:
                return text[open_idx + 1:i]
        elif c == "," and depth == 1:
            return text[open_idx + 1:i]
        i += 1
    return text[open_idx + 1:open_idx + 120]

rows = []
for root, dirs, files in os.walk(src):
    dirs[:] = [x for x in dirs if x not in (".git", "extern", "build")]
    rel_root = os.path.relpath(root, src)
    if not (rel_root.startswith("apps") or rel_root.startswith("components")):
        continue
    for fn in files:
        if not fn.endswith((".cpp", ".hpp")):
            continue
        p = os.path.join(root, fn)
        try:
            text = io.open(p, "r", encoding="utf-8", errors="replace").read()
        except Exception:
            continue
        literals = set(LITDECL.findall(text))
        lines = text.split("\n")
        starts = [0]
        for ln in lines:
            starts.append(starts[-1] + len(ln) + 1)
        for m in CALL.finditer(text):
            fname = m.group(1)
            arg = first_arg(text, m.end() - 1).strip()
            off = m.start()
            lineno = 1
            lo, hi = 0, len(starts) - 1
            while lo <= hi:
                mid = (lo + hi) // 2
                if starts[mid] <= off:
                    lineno = mid + 1
                    lo = mid + 1
                else:
                    hi = mid - 1
            # A DEFINITION, not a call: the first argument is a declaration
            # (a type followed by a parameter name), e.g. "NormalizedView path".
            if re.match(r"^[A-Za-z_][\w:<>,\s\*&]*\s+\w+$", arg) and "(" not in arg:
                continue
            # classify
            base = arg.split("(")[0].strip()
            if arg.startswith('"') or arg.startswith("u8\""):
                kind = "literal"
            elif base in literals or arg.split(")")[0].strip() in literals:
                kind = "literal"
            elif any(w + "(" in arg for w in FUNCS) and '"' in arg:
                kind = "literal"
            else:
                kind = "VARIABLE"
            # guard: .empty() anywhere in the 25 lines before the call
            ctx = "\n".join(lines[max(0, lineno - 26):lineno])
            guarded = "empty()" in ctx
            rows.append((os.path.relpath(p, src), lineno, fname, kind, guarded, arg[:96].replace("\n", " ")))

var = [r for r in rows if r[3] == "VARIABLE"]
lit = [r for r in rows if r[3] == "literal"]
unguarded = [r for r in var if not r[4]]

print("TSP_TEXCENSUS_V1")
print("")
print("call sites of: " + ", ".join(FUNCS))
print("NOTE: a resolve+load pair (correctTexturePath then getImage on its result)")
print("      counts as two sites. They are one bug, fixed by one guard.")
print("")
print("  total            %d" % len(rows))
print("  literal name     %d   (cannot ever be empty - safe by construction)" % len(lit))
print("  VARIABLE name    %d   (could be handed an empty string)" % len(var))
print("    with an empty() check within 25 lines   %d" % (len(var) - len(unguarded)))
print("    WITHOUT one                             %d" % len(unguarded))
print("")
print("=" * 100)
print("VARIABLE-NAME SITES WITHOUT A NEARBY empty() CHECK - the candidates")
print("=" * 100)
for r in sorted(unguarded):
    print("%-58s :%-6d %-20s %s" % (r[0], r[1], r[2], r[5]))
print("")
print("--- the same sites with 6 lines of context each ---")
for r in sorted(unguarded):
    print("")
    print(">>> %s:%d  (%s)" % (r[0], r[1], r[2]))
    try:
        ls = io.open(os.path.join(src, r[0]), "r", encoding="utf-8", errors="replace").read().split("\n")
        for i in range(max(0, r[1] - 7), min(len(ls), r[1] + 3)):
            print("    %6d  %s" % (i + 1, ls[i]))
    except Exception as e:
        print("    context unavailable: %s" % e)
print("")
print("=" * 100)
print("VARIABLE-NAME SITES THAT DO HAVE A NEARBY empty() CHECK")
print("=" * 100)
for r in sorted([x for x in var if x[4]]):
    print("%-58s :%-6d %-20s %s" % (r[0], r[1], r[2], r[5]))
print("")
print("=" * 100)
print("LITERAL SITES (listed only so the classification can be audited)")
print("=" * 100)
for r in sorted(lit):
    print("%-58s :%-6d %-20s %s" % (r[0], r[1], r[2], r[5]))
PYEOF

say ""
sed -n '1,30p' "$OUT"
say ""
say "----- the unguarded variable-name sites -----"
sed -n '/WITHOUT A NEARBY/,/--- the same sites/p' "$OUT" | head -80
say ""
say "full table: $OUT"
say "lines:      $(wc -l < "$OUT" | tr -d ' ')"
