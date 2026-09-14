{ print }
/double gMs = 0\.0;/ && !done {
    print "        // TSP_COMPOS_BUILD: greppable in the deployed binary, so"
    print "        // \"which composite map generation is actually running\" stops"
    print "        // being a guess. Bump the string whenever this file changes."
    print "        const char* volatile gBuildTag = \"TSP_COMPOS_BUILD_V8_NO_DRAINEND\";"
    done = 1
}
END { if (!done) { print "AWK_ERROR no-gMs-anchor" > "/dev/stderr"; exit 5 } }
