echo "=== 1  df -h ==="
df -h 2>/dev/null
echo
echo "=== 2  mount ==="
mount
echo
echo "=== 3  /proc/partitions ==="
cat /proc/partitions 2>/dev/null
echo
echo "=== 4  /mnt contents ==="
ls -la /mnt/ 2>/dev/null
echo
echo "=== 5  is /mnt/UDISK a mount point? (empty = NO) ==="
awk '$2 == "/mnt/UDISK" { print }' /proc/mounts
echo "---end---"
echo
echo "=== 6  verdict per candidate, using the launcher's NEW test ==="
TSP_STATE_MIN_MB=768
tsp_df_line() {
    _l=$(df -P "$1" 2>/dev/null | tail -1)
    [ -n "$_l" ] || _l=$(df "$1" 2>/dev/null | tail -1)
    printf '%s\n' "$_l"
}
tsp_state_ok() {
    _d=$1
    [ -d "$_d" ] || { echo "    no such directory"; return 1; }
    ( : > "$_d/.tsp-write-test" ) 2>/dev/null || { echo "    NOT writable"; return 1; }
    rm -f "$_d/.tsp-write-test" 2>/dev/null
    _line=$(tsp_df_line "$_d")
    [ -n "$_line" ] || { echo "    df gave nothing"; return 1; }
    _dev=$(printf '%s\n' "$_line" | tr -s ' ' | cut -d' ' -f1)
    _free=$(printf '%s\n' "$_line" | tr -s ' ' | cut -d' ' -f4)
    _rootdev=$(tsp_df_line / | tr -s ' ' | cut -d' ' -f1)
    echo "    dev=$_dev  rootdev=$_rootdev  freeKB=$_free"
    [ -n "$_dev" ] || return 1
    if [ "$_dev" = "$_rootdev" ]; then echo "    REJECT: same filesystem as / (rootfs)"; return 1; fi
    case "$_free" in ''|*[!0-9]*) echo "    REJECT: unreadable free space"; return 1 ;; esac
    if [ "$(( _free / 1024 ))" -lt "$TSP_STATE_MIN_MB" ]; then
        echo "    REJECT: only $(( _free / 1024 )) MB free, need $TSP_STATE_MIN_MB"
        return 1
    fi
    return 0
}
for d in /mnt/UDISK /userdata /storage /roms /userdata/roms/ports/openmw; do
    echo "  $d"
    if tsp_state_ok "$d"; then echo "    ACCEPT"; else echo "    rejected"; fi
done
echo
echo "=== 7  the cfg paths that are killing the launch ==="
G=/userdata/roms/ports/openmw
for f in "$G/openmw.cfg" "$G/openmw.base.cfg" "$G/bin/openmw.cfg" "$G/config/openmw.cfg"; do
    echo "  --- $f"
    if [ -f "$f" ]; then
        grep -n '^resources=\|^data=\|^config=\|^user-data=' "$f" 2>/dev/null | head -12
    else
        echo "      MISSING"
    fi
done
echo
echo "=== 8  does the engine and its data actually exist there? ==="
ls -la "$G/bin/openmw-0.51" 2>/dev/null || echo "  engine MISSING"
ls -la "$G/data/Data Files/Morrowind.esm" 2>/dev/null || echo "  Morrowind.esm MISSING"
ls -d "$G/resources" 2>/dev/null || echo "  resources MISSING"
echo
echo "=== 9  python3 present? (the launcher's migrator needs it) ==="
command -v python3 || echo "  python3 NOT present"
echo
echo "=== 10 ram / swap ==="
free -m 2>/dev/null || head -5 /proc/meminfo
echo "PROBE COMPLETE"
