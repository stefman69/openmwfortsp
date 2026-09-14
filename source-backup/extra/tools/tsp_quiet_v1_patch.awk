# TSP_QUIET_V1 patcher. Input: the current Roms/PORTS/Morrowind.sh. GAMEDIR passed with -v gamedir=...
BEGIN { top = 0; opened = 0; perf = 0; ring = 0 }
/TSP_QUIET_V1/ { print "TSP_QUIET_V1 PATCH REFUSED: launcher already carries the marker" > "/dev/stderr"; exit 4 }
NR == 1 {
    print
    print "# >>> TSP_QUIET_V1 BEGIN"
    print "# Shipping: every proof line the launcher used to scatter over the SD card (tsp_prog.txt) goes into the one"
    print "# game log, the perf sampler (openmw_perf_latest.txt) and the stall ring dumps (tsp_ring/) stay off."
    print "# quiet=off in $GAMEDIR/tsp_drawthread_policy.txt, or touch /mnt/SDCARD/tsp_quiet_off, brings them back."
    print "TSP_QUIET=1"
    print "if grep -qs '^quiet=off' \"" gamedir "/tsp_drawthread_policy.txt\" || [ -f /mnt/SDCARD/tsp_quiet_off ]; then TSP_QUIET=0; fi"
    print "if [ \"$TSP_QUIET\" = 1 ]; then TSP_PROG=/tmp/tsp_prog_early.$$; TSP_PROG_TEE=/dev/null; else TSP_PROG=/mnt/SDCARD/tsp_prog.txt; TSP_PROG_TEE=/mnt/SDCARD/tsp_prog.txt; fi"
    print "# <<< TSP_QUIET_V1 END"
    top = 1
    next
}
{ line = $0; sub(/^[ \t]+/, "", line); sub(/[ \t]+$/, "", line) }
line == "exec >> \"$LOG_FILE\" 2>&1" && opened == 0 {
    opened = 1
    print
    print "if [ \"$TSP_QUIET\" = 1 ]; then [ -f \"$TSP_PROG\" ] && { cat \"$TSP_PROG\"; rm -f \"$TSP_PROG\"; }; TSP_PROG=\"$LOG_FILE\"; echo \"TSP_QUIET_V1 on: proof lines in this log only, perf sampler off, ring dumps off\"; else echo \"TSP_QUIET_V1 off (policy): side files as before\"; fi   # TSP_QUIET_V1 OPEN"
    next
}
line == "tsp_perf_sampler \"$OPENMW_PID\" &" && perf == 0 {
    perf = 1
    print "if [ \"$TSP_QUIET\" = 1 ]; then TSP_PERF_MONITOR_PID=\"\"; else   # TSP_QUIET_V1 PERF"
    print "tsp_perf_sampler \"$OPENMW_PID\" &"
    print "TSP_PERF_MONITOR_PID=$!"
    print "fi"
    getline nxt
    n2 = nxt; sub(/^[ \t]+/, "", n2); sub(/[ \t]+$/, "", n2)
    if (n2 != "TSP_PERF_MONITOR_PID=$!") { print "TSP_QUIET_V1 PATCH FAILED: line after the sampler start is not TSP_PERF_MONITOR_PID=$!" > "/dev/stderr"; exit 3 }
    next
}
line == "if [ -f /mnt/SDCARD/tsp_ring_off ]; then" && ring == 0 {
    ring = 1
    print "if [ -f /mnt/SDCARD/tsp_ring_off ] || [ \"$TSP_QUIET\" = 1 ]; then   # TSP_QUIET_V1 RING"
    next
}
{
    gsub(/>> \/mnt\/SDCARD\/tsp_prog\.txt/, ">> \"$TSP_PROG\"")
    gsub(/tee -a \/mnt\/SDCARD\/tsp_prog\.txt/, "tee -a \"$TSP_PROG_TEE\"")
    print
}
END { if (top != 1 || opened != 1 || perf != 1 || ring != 1) { print "TSP_QUIET_V1 PATCH FAILED top=" top " opened=" opened " perf=" perf " ring=" ring > "/dev/stderr"; exit 3 } }
