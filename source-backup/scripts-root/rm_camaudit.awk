# Removes the TSP camera-viewport audit/repair visitor and its call site.
/\/\/ TSP_CAMERA_VIEWPORT_AUDIT_051_V26/ { dc = 1 }
dc && /^    \};[ \t]*$/                  { dc = 0; gotClass = 1; next }
dc                                       { next }

/\/\/ On the first and last fire, walk the graph/ { cm = 1 }
cm && /^[ \t]*\/\//                               { next }
cm                                                { cm = 0 }

/if \(camera && \(mFires == 1 \|\| mFires == 10\)\)/ { cs = 1; next }
cs && /^[ \t]*\}[ \t]*$/                             { cs = 0; gotCall = 1; next }
cs                                                   { next }

{ print }
END {
    if (!gotClass) { print "AWK_ERROR class-block-not-removed" > "/dev/stderr"; exit 3 }
    if (!gotCall)  { print "AWK_ERROR call-site-not-removed"  > "/dev/stderr"; exit 4 }
}
