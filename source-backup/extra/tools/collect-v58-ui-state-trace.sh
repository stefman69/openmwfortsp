#!/usr/bin/env bash
set -Eeuo pipefail

DEV="${TSP_DEV:-root@192.168.1.25}"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="${1:-$HOME/Downloads/openmw51-v58-ui-state-trace-$STAMP.txt}"

echo "Collecting V58 controller/text/mouse trace from $DEV..."
echo "IMPORTANT: run this while OpenMW is STILL RUNNING."
echo

{
    echo "=================================================================="
    echo "OPENMW V58 EXPLICIT UI STATE TRACE"
    echo "=================================================================="
    echo

    echo "===== DEVICE / TIME ====="
    ssh "$DEV" '
        hostname
        date
    '

    echo
    echo "===== LIVE HELPER LOG ====="

    ssh "$DEV" '
        if [ -f /tmp/tsp_controls_051.log ]; then
            cat /tmp/tsp_controls_051.log
        elif [ -f /tmp/tsp_openmw_controls_051.log ]; then
            cat /tmp/tsp_openmw_controls_051.log
        else
            echo "NO LIVE HELPER LOG FOUND."
            echo "Checked:"
            echo "  /tmp/tsp_controls_051.log"
            echo "  /tmp/tsp_openmw_controls_051.log"
        fi
    '

    echo
    echo "===== FILTERED HELPER STATE EVENTS ====="

    ssh "$DEV" '
        F=""
        if [ -f /tmp/tsp_controls_051.log ]; then
            F=/tmp/tsp_controls_051.log
        elif [ -f /tmp/tsp_openmw_controls_051.log ]; then
            F=/tmp/tsp_openmw_controls_051.log
        fi

        if [ -n "$F" ]; then
            grep -E \
              "TSP_EXPLICIT_UI_STATE_051_V58|TSP_B_EXIT_MENU_HANDOFF_051_V57|TSP_TEXT_EXIT_CONTROLLER_051_V55|TSP_NO_STICKCLICK_MODES_051_V54|MENU:|MODE=|CONTROLLER GRAB|RAW KEY|RAW ABS|LEFT STICK|B:" \
              "$F" | tail -700 || true
        fi
    '

    echo
    echo "===== ENGINE STATE EVENTS ====="

    ssh "$DEV" '
        grep -hE \
          "TSP_EXPLICIT_UI_STATE_051_V58|TSP_B_EXIT_MENU_HANDOFF_051_V57|TSP_TEXT_EXIT_CONTROLLER_051_V55|TSP_NO_STICKCLICK_MODES_051_V54|TSP_TEXT_HANDOFF_051_V51|TSP_MOUSE_MODE_051_V38|TSP_MOUSE_MODE_051_V41|TSP_CHORD_051_V43" \
          /mnt/SDCARD/data/ports/openmw51/config-0.51/openmw.log \
          /mnt/SDCARD/tsp_prog.txt \
          2>/dev/null | tail -700 || true
    '

    echo
    echo "===== CURRENT IPC / HANDSHAKE FILES ====="

    ssh "$DEV" '
        for f in \
          /tmp/openmw-tsp-text-active \
          /tmp/openmw-tsp-text-char \
          /tmp/openmw-tsp-text-off \
          /tmp/openmw-tsp-force-controller \
          /tmp/openmw-tsp-text-exit-latch \
          /tmp/openmw-tsp-request-controller \
          /tmp/openmw-tsp-mouse-mode \
          /tmp/openmw-tsp-mouse-request \
          /tmp/openmw-tsp-mouse-active \
          /tmp/openmw-tsp-text-reset
        do
            if [ -e "$f" ]; then
                printf "EXISTS: %s = " "$f"
                cat "$f" 2>/dev/null || true
                echo
            else
                echo "absent: $f"
            fi
        done
    '

    echo
    echo "===== RUNNING PROCESSES ====="

    ssh "$DEV" '
        ps | grep -E "openmw|tsp_openmw_controls" | grep -v grep || true
    '

    echo
    echo "===== INSTALLED FILE HASHES ====="

    ssh "$DEV" '
        sha256sum \
          /mnt/SDCARD/data/ports/openmw51/bin/openmw-0.51 \
          /mnt/SDCARD/data/ports/openmw51/tsp_openmw_controls \
          2>/dev/null || true
    '

    echo
    echo "===== INSTALLED V58 MARKERS ====="

    ssh "$DEV" '
        echo "--- OpenMW ---"
        if grep -a -q "TSP_EXPLICIT_UI_STATE_051_V58" \
            /mnt/SDCARD/data/ports/openmw51/bin/openmw-0.51
        then
            echo "PASS: V58 engine marker found"
        else
            echo "FAIL: V58 engine marker NOT found"
        fi

        echo "--- helper ---"
        if grep -a -q "TSP_EXPLICIT_UI_STATE_051_V58 active" \
            /mnt/SDCARD/data/ports/openmw51/tsp_openmw_controls
        then
            echo "PASS: V58 helper marker found"
        else
            echo "FAIL: V58 helper marker NOT found"
        fi
    '

    echo
    echo "=================================================================="
    echo "END V58 TRACE"
    echo "=================================================================="
} 2>&1 | tee "$OUT"

echo
echo "Trace saved to:"
echo "  $OUT"
