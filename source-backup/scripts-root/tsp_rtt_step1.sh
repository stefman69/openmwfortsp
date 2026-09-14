#!/bin/sh
S=${TSP_ROOT:-/root/openmw-0.51-tsp-src}
R=$S/apps/openmw/mwrender/renderingmanager.cpp
C=$S/components/terrain/compositemaprenderer.cpp
A=${TSP_AWKDIR:-/root}
T=$(date +%Y%m%d-%H%M%S)

bal() { b=$(tr -cd '{' < "$1" | wc -c); e=$(tr -cd '}' < "$1" | wc -c); echo $((b-e)); }

[ -f "$R" ] || { echo "  ABORT  no $R"; exit 1; }
[ -f "$C" ] || { echo "  ABORT  no $C"; exit 1; }

echo
echo "  ---- before ----"
for m in TspCameraViewportAudit mFallbackViewport TSP_NULL_VIEWPORT_FIX_051_V29 TspActualRenderResolutionProbe; do
  printf "    %-36s x%s\n" "$m" "$(grep -c -F "$m" "$R")"
done
for m in TSP_COMPOS_V8 TspDrainEnd TSP_COMPOS_BUILD TSP_COMPOSITE_GLES2_FIX; do
  printf "    %-36s x%s\n" "$m" "$(grep -c -F "$m" "$C")"
done
echo

if grep -q TspCameraViewportAudit "$R"; then
  if awk -f "$A/rm_camaudit.awk" "$R" > /tmp/rm.cpp 2>/tmp/rm.err; then
    if [ "$(bal "$R")" != "$(bal /tmp/rm.cpp)" ]; then
      echo "  ABORT  brace balance changed - nothing written"; exit 1
    fi
    if grep -q TspCameraViewportAudit /tmp/rm.cpp; then
      echo "  ABORT  references survive - nothing written"; exit 1
    fi
    cp "$R" "$R.tspcamrm-$T" && cp /tmp/rm.cpp "$R"
    echo "  REMOVED  camera-viewport rewriter, $(( $(wc -l < "$R.tspcamrm-$T") - $(wc -l < "$R") )) lines gone"
    echo "           backup $R.tspcamrm-$T"
  else
    echo "  ABORT  awk refused - nothing written"; cat /tmp/rm.err; exit 1
  fi
else
  echo "  SKIP     camera-viewport rewriter already gone"
fi

if grep -q TSP_COMPOS_BUILD "$C"; then
  echo "  SKIP     composite map build tag already present"
elif awk -f "$A/add_compostag.awk" "$C" > /tmp/ct.cpp 2>/tmp/ct.err; then
  if [ "$(bal "$C")" != "$(bal /tmp/ct.cpp)" ]; then
    echo "  ABORT  brace balance changed on compositemaprenderer.cpp"; exit 1
  fi
  cp "$C" "$C.tsptag-$T" && cp /tmp/ct.cpp "$C"
  echo "  ADDED    build tag TSP_COMPOS_BUILD_V8_NO_DRAINEND"
  echo "           backup $C.tsptag-$T"
else
  echo "  ABORT  no gMs anchor in compositemaprenderer.cpp"; cat /tmp/ct.err; exit 1
fi

echo
echo "  ---- after ----"
for m in TspCameraViewportAudit TSP_CAM_AUDIT TSP_CAM_FIX TspActualRenderResolutionProbe; do
  printf "    %-36s x%s\n" "$m" "$(grep -c -F "$m" "$R")"
done
printf "    %-36s x%s\n" "TSP_COMPOS_BUILD" "$(grep -c -F TSP_COMPOS_BUILD "$C")"
printf "    %-36s %s\n" "renderingmanager.cpp braces" "$(bal "$R")"
printf "    %-36s %s\n" "compositemaprenderer.cpp braces" "$(bal "$C")"
echo
