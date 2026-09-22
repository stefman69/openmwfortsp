#!/bin/bash
# Run this ONLY from the Ubuntu VM.
# It never asks the user to launch a script manually on the TSP.
set -u

DEV="root@192.168.1.21"
CTRL="${CTRL:-$HOME/Downloads/TSP_Experimental_Controller_Patch_muOS_Jacaranda_V2.sh}"
MGR="${MGR:-$HOME/Downloads/apply_openmw_tsp_manager_v51_NO_STICK_CONTROL_FIXED-21.sh}"
REMOTE_PORT="/mnt/mmc/ROMS/Ports/TSP_Experimental_Controller_Patch.sh"

fail(){ echo "ERROR: $*" >&2; exit 1; }
[ -f "$CTRL" ] || fail "missing controller file: $CTRL"
[ -f "$MGR" ] || fail "missing manager file: $MGR"
chmod +x "$CTRL" "$MGR" || fail "chmod failed"

echo "===== 1/5 CONTROLLER V2 HOST SELFTEST ====="
bash "$CTRL" --selftest || fail "controller V2 selftest failed"

echo
echo "===== 2/5 COPY CONTROLLER V2 TO TSP ====="
ssh "$DEV" 'mkdir -p /mnt/mmc/ROMS/Ports' || fail "could not prepare TSP Ports directory"
scp "$CTRL" "$DEV:$REMOTE_PORT" || fail "controller V2 copy failed"
ssh "$DEV" "chmod +x '$REMOTE_PORT'" || fail "remote chmod failed"

echo
echo "===== 3/5 UPDATE ACTIVE SYSTEM CONTROLLER REMOTELY ====="
ssh "$DEV" "sh '$REMOTE_PORT' --deploy-only" || fail "remote controller V2 update failed"

echo
echo "===== 4/5 MANAGER V5.1 HOST SELFTEST ====="
bash "$MGR" selftest || fail "manager V5.1 selftest failed"

echo
echo "===== 5/5 INSTALL CONTROLLER-NEUTRAL MANAGER ====="
bash "$MGR" || fail "manager V5.1 install failed"

echo
echo "============================================================"
echo "COMPLETE"
echo "============================================================"
echo "Controller V2 is deployed system-wide."
echo "Manager V5.1 no longer owns stick calibration or muOS UART input."
echo "The V5.1 installer created a device-side backup directory and .tar archive"
echo "before replacing the current manager/Morrowind launcher."
