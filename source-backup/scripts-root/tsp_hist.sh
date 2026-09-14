G=/root/gl4es-tsps
O=/root/openmw-0.51-tsp-src

echo "  == gl4es backups, newest first =="
find "$G/src" \( -name "*.before-*" -o -name "*.tsp*" -o -name "*.orig" -o -name "*.bak" \) 2>/dev/null \
  | while read f; do ls -l "$f"; done | sort -k6,8 -r | head -25

echo
echo "  == OpenMW texture / FBO / RTT backups, newest first =="
find "$O/components/terrain" "$O/components/sceneutil" "$O/components/resource" "$O/apps/openmw/mwrender" \
  \( -name "*.before-*" -o -name "*.tsp*" -o -name "*.orig" \) 2>/dev/null \
  | while read f; do ls -l "$f"; done | sort -k6,8 -r | head -30

echo
echo "  == live sources, by mtime =="
ls -lt "$G"/src/gl/*.c "$G"/src/glx/*.c 2>/dev/null | head -8
ls -lt "$O"/components/terrain/*.cpp "$O"/components/sceneutil/*.cpp "$O"/components/resource/*.cpp 2>/dev/null | head -10

echo
echo "  == size of each gl4es edit vs the live file =="
for b in "$G"/src/gl/framebuffers.c.*; do
  [ -f "$b" ] || continue
  printf "    %-58s %s changed lines\n" "$(basename "$b")" "$(diff "$b" "$G/src/gl/framebuffers.c" 2>/dev/null | grep -c '^[<>]')"
done

echo
echo "  == THE MOST RECENT gl4es edit, in full =="
NEW=$(ls -t "$G"/src/gl/framebuffers.c.* 2>/dev/null | head -1)
echo "    baseline: $NEW"
diff -u "$NEW" "$G/src/gl/framebuffers.c" 2>/dev/null | head -100
