#!/usr/bin/env bash
set -Eeuo pipefail

ACTION="${1:-install}"
CTR="${OPENMW_CONTAINER:-openmw_builder}"
DEV="${TSP_DEVICE:-root@192.168.1.25}"

SRC=/root/openmw-0.51-tsp-src
BUILD=/root/openmw-0.51-tsp-build
PACKAGE=/root/openmw-0.51-tsp-package
SCENE_CPP="$SRC/apps/openmw/mwworld/scene.cpp"
SCENE_HPP="$SRC/apps/openmw/mwworld/scene.hpp"
VIS_CPP="$SRC/apps/openmw/mwrender/interiorvisibility.cpp"
VIS_HPP="$SRC/apps/openmw/mwrender/interiorvisibility.hpp"
ANIM="$SRC/apps/openmw/mwrender/animation.cpp"
BUILT="$BUILD/openmw"
PACKAGED="$PACKAGE/bin/openmw-0.51"

ROOT=/mnt/SDCARD/data/ports/openmw51
REMOTE_BIN="$ROOT/bin/openmw-0.51"
LIVE_LUA="$ROOT/mods/TSPInteriorVisGrid/scripts/TSPInteriorVisGrid/visgrid.lua"
CAPTURE_HELPER="$ROOT/tsp_visgrid_v24_capture.sh"
REMOTE_TMP_BIN=/tmp/openmw-0.51.v25-room-object-lifecycle

DL="$HOME/Downloads"
HOST_BIN="$DL/openmw-0.51-v25-room-object-lifecycle"
STATE="$DL/openmw51-visgrid-v25-room-object-lifecycle.state"
STAMP="$(date +%Y%m%d-%H%M%S)"
LOG="$DL/openmw51-visgrid-v25-room-object-lifecycle-$STAMP.log"
TMP="$(mktemp -d "$DL/.v25-roomobj.XXXXXX")"
SOURCE_BACKUP=""
DEVICE_BACKUP=""
DEVICE_DEPLOY_STARTED=0

cleanup() { rm -rf "$TMP" 2>/dev/null || true; }
trap cleanup EXIT

die() { echo "ERROR: $*" >&2; exit 1; }

ensure_docker() {
  command -v docker >/dev/null 2>&1 || die "docker not found"
  docker inspect "$CTR" >/dev/null 2>&1 || die "Docker container '$CTR' not found"
  [ "$(docker inspect -f '{{.State.Running}}' "$CTR")" = true ] || docker start "$CTR" >/dev/null
}

ensure_ssh() {
  command -v ssh >/dev/null 2>&1 || die "ssh not found"
  command -v scp >/dev/null 2>&1 || die "scp not found"
  ssh -o BatchMode=yes -o ConnectTimeout=8 "$DEV" true || die "cannot reach $DEV"
}

game_closed() {
  ! ssh "$DEV" "pgrep -af 'openmw-0\.51|/openmw([[:space:]]|$)' 2>/dev/null" | grep -v pgrep
}

restore_device() {
  [ -n "${DEVICE_BACKUP:-}" ] || return 0
  ssh "$DEV" "bash -s" <<REMOTE
set -e
B='$DEVICE_BACKUP'
test -s "\$B/openmw-0.51.before"
cp -pf "\$B/openmw-0.51.before" '$REMOTE_BIN'
if [ -f "\$B/helper.existed" ]; then
  test -s "\$B/capture-helper.before"
  cp -pf "\$B/capture-helper.before" '$CAPTURE_HELPER'
else
  rm -f '$CAPTURE_HELPER'
fi
chmod 755 '$REMOTE_BIN'
[ ! -f '$CAPTURE_HELPER' ] || chmod 755 '$CAPTURE_HELPER'
sync
REMOTE
}

collect_latest() {
  ensure_ssh
  OUT="$DL/openmw51-visgrid-v25-room-object-lifecycle-validation-$STAMP.txt"
  ssh "$DEV" "test -s '$ROOT/visgrid-v25-latest.txt'" || die "no V25 automatic capture yet; run once and exit normally"
  scp -q "$DEV:$ROOT/visgrid-v25-latest.txt" "$OUT"
  echo "Saved: $OUT"
  echo
  grep -E '^V25 SUMMARY|^V25 LAST|^Bad STAT|^Render failures|^PVS culls|^GRID culls' "$OUT" || true
}

rollback_all() {
  [ -s "$STATE" ] || die "state file missing: $STATE"
  # shellcheck disable=SC1090
  . "$STATE"
  ensure_docker; ensure_ssh
  game_closed || die "OpenMW is running"
  docker exec "$CTR" bash -lc "set -e; cp -pf '$SOURCE_BACKUP/scene.cpp' '$SCENE_CPP'; cp -pf '$SOURCE_BACKUP/scene.hpp' '$SCENE_HPP'; cp -pf '$SOURCE_BACKUP/interiorvisibility.cpp' '$VIS_CPP'; cp -pf '$SOURCE_BACKUP/interiorvisibility.hpp' '$VIS_HPP'"
  restore_device
  echo "ROLLBACK COMPLETE"
}

case "$ACTION" in
  collect) collect_latest; exit 0 ;;
  rollback) rollback_all; exit 0 ;;
  install) ;;
  *) die "Usage: $0 [install|collect|rollback]" ;;
esac

exec > >(tee "$LOG") 2>&1

on_error() {
  rc=$?
  trap - ERR
  set +e
  echo
  echo "===== V25 STOPPED SAFELY (rc=$rc) ====="
  if [ -n "$SOURCE_BACKUP" ]; then
    docker exec "$CTR" bash -lc "cp -pf '$SOURCE_BACKUP/scene.cpp' '$SCENE_CPP'; cp -pf '$SOURCE_BACKUP/scene.hpp' '$SCENE_HPP'; cp -pf '$SOURCE_BACKUP/interiorvisibility.cpp' '$VIS_CPP'; cp -pf '$SOURCE_BACKUP/interiorvisibility.hpp' '$VIS_HPP'" >/dev/null 2>&1 || true
  fi
  if [ "$DEVICE_DEPLOY_STARTED" = 1 ] && [ -n "$DEVICE_BACKUP" ]; then restore_device >/dev/null 2>&1 || true; fi
  echo "Log preserved: $LOG"
  exit "$rc"
}
trap on_error ERR

echo "============================================================"
echo "OPENMW 0.51 — VISGRID V25 ROOM OBJECT LIFECYCLE"
echo "============================================================"
echo "V24 room/prewarm authority: unchanged"
echo "Inactive clutter: renderer + Bullet/navmesh removed"
echo "Actors: untouched"
echo "============================================================"

ensure_docker; ensure_ssh
game_closed || die "OpenMW is running; exit normally first"

echo
echo "===== 1/8 VERIFY V24 BASELINE ====="
docker exec "$CTR" bash -lc "set -e; test -s '$SCENE_CPP'; test -s '$SCENE_HPP'; test -s '$VIS_CPP'; test -s '$VIS_HPP'; test -s '$BUILT'; grep -Fq 'TSP_VISGRID_ROOM_RESIDENCY_051_V24' '$VIS_CPP'; grep -Fq 'TSP_VISGRID_ROOM_RESIDENCY_051_V24' '$ANIM'; ! grep -Fq 'TSP_ROOM_OBJECT_LIFECYCLE_051_V25' '$SCENE_CPP'; ! grep -Fq 'mPtr.get<ESM::Static>()' '$ANIM'"
ssh "$DEV" "set -e; test -s '$REMOTE_BIN'; test -s '$LIVE_LUA'; grep -Fq 'TSP_VISGRID_LUA_V24_ROOM_RESIDENCY' '$LIVE_LUA'"
PRE_SHA="$(ssh "$DEV" "sha256sum '$REMOTE_BIN'" | awk '{print $1}')"
LUA_SHA="$(ssh "$DEV" "sha256sum '$LIVE_LUA'" | awk '{print $1}')"
echo "Binary: $PRE_SHA"
echo "V24 Lua: $LUA_SHA"

echo
echo "===== 2/8 BACKUP SOURCE ====="
SOURCE_BACKUP="$SRC/.tsp-051-source-backups/visgrid-v25-room-object-lifecycle-$STAMP"
docker exec "$CTR" bash -lc "set -e; mkdir -p '$SOURCE_BACKUP'; cp -pf '$SCENE_CPP' '$SOURCE_BACKUP/scene.cpp'; cp -pf '$SCENE_HPP' '$SOURCE_BACKUP/scene.hpp'; cp -pf '$VIS_CPP' '$SOURCE_BACKUP/interiorvisibility.cpp'; cp -pf '$VIS_HPP' '$SOURCE_BACKUP/interiorvisibility.hpp'; sha256sum '$SOURCE_BACKUP/'*"

echo
echo "===== 3/8 APPLY V25 SOURCE PATCH ====="
base64 -d > "$TMP/v25_patch.py" <<'PATCH_B64'
aW1wb3J0IHN5cwoKc2NlbmVfY3BwX3BhdGgsIHNjZW5lX2hwcF9wYXRoLCB2aXNfY3BwX3BhdGgsIHZpc19ocHBfcGF0aCA9IHN5cy5hcmd2WzE6NV0KCmRlZiByZWFkKHBhdGgpOgogICAgd2l0aCBvcGVuKHBhdGgsICdyJywgZW5jb2Rpbmc9J3V0Zi04JywgbmV3bGluZT0nJykgYXMgZjoKICAgICAgICByZXR1cm4gZi5yZWFkKCkKCmRlZiB3cml0ZShwYXRoLCB0ZXh0KToKICAgIHdpdGggb3BlbihwYXRoLCAndycsIGVuY29kaW5nPSd1dGYtOCcsIG5ld2xpbmU9J1xuJykgYXMgZjoKICAgICAgICBmLndyaXRlKHRleHQpCgpzYyA9IHJlYWQoc2NlbmVfY3BwX3BhdGgpCnNoID0gcmVhZChzY2VuZV9ocHBfcGF0aCkKdmMgPSByZWFkKHZpc19jcHBfcGF0aCkKdmggPSByZWFkKHZpc19ocHBfcGF0aCkKTUFSSyA9ICdUU1BfUk9PTV9PQkpFQ1RfTElGRUNZQ0xFXzA1MV9WMjUnCgpmb3IgdG9rZW4gaW4gKCdUU1BfVklTR1JJRF9ST09NX1JFU0lERU5DWV8wNTFfVjI0JywgJ2Jvb2wgcHZzU3RydWN0dXJhbCcpOgogICAgaWYgdG9rZW4gbm90IGluIHZoIGFuZCB0b2tlbiBub3QgaW4gdmM6CiAgICAgICAgcmFpc2UgUnVudGltZUVycm9yKCdWMjQgdmlzaWJpbGl0eSBiYXNlbGluZSB0b2tlbiBtaXNzaW5nOiAnICsgdG9rZW4pCmlmIGFueShNQVJLIGluIHggZm9yIHggaW4gKHNjLCBzaCwgdmMsIHZoKSk6CiAgICByYWlzZSBSdW50aW1lRXJyb3IoJ1YyNSBtYXJrZXIgYWxyZWFkeSBwcmVzZW50OyByZWZ1c2luZyBhbWJpZ3VvdXMgcmUtYXBwbGljYXRpb24nKQoKIyBFeHBvc2UgVjI0J3Mgcm9vbS9QVlMgYXV0aG9yaXR5IHRvIFNjZW5lLgpvbGQgPSAnJycgICAgdm9pZCBjbGVhckludGVyaW9yVG9wb2xvZ3lQdnMoKTsKICAgIHZvaWQgY2xlYXJJbnRlcmlvclZpc2liaWxpdHlHcmlkKCk7CicnJwpuZXcgPSAnJycgICAgdm9pZCBjbGVhckludGVyaW9yVG9wb2xvZ3lQdnMoKTsKCiAgICAvLyBUU1BfUk9PTV9PQkpFQ1RfTElGRUNZQ0xFXzA1MV9WMjUKICAgIC8vIE1haW4tdGhyZWFkIHJvb20gcmVzaWRlbmN5IHF1ZXJ5IGZvciBzY2VuZSBtYXRlcmlhbGl6YXRpb24uIFVubWFwcGVkIG9iamVjdHMKICAgIC8vIGFuZCBkaXNhYmxlZC9pbnZhbGlkIFBWUyBmYWlsIG9wZW4gKHJlc2lkZW50PXRydWUpLgogICAgYm9vbCBpc0ludGVyaW9yVG9wb2xvZ3lQdnNFbmFibGVkKCk7CiAgICBib29sIGlzSW50ZXJpb3JUb3BvbG9neU9iamVjdFJlc2lkZW50KAogICAgICAgIGNvbnN0IG9zZzo6VmVjM2YmIG9yaWdpbiwgZmxvYXQgcmFkaXVzLCBib29sIHN0cnVjdHVyYWwgPSBmYWxzZSk7CgogICAgdm9pZCBjbGVhckludGVyaW9yVmlzaWJpbGl0eUdyaWQoKTsKJycnCmlmIHZoLmNvdW50KG9sZCkgIT0gMToKICAgIHJhaXNlIFJ1bnRpbWVFcnJvcignaW50ZXJpb3J2aXNpYmlsaXR5LmhwcCBwdWJsaWMgUFZTIGFuY2hvciBjb3VudD0lZCcgJSB2aC5jb3VudChvbGQpKQp2aCA9IHZoLnJlcGxhY2Uob2xkLCBuZXcsIDEpCgphbmNob3IgPSAnJycgICAgdm9pZCBjbGVhckludGVyaW9yVG9wb2xvZ3lQdnMoKQogICAgewogICAgICAgIGNvbnN0IGJvb2wgd2FzRW5hYmxlZCA9IHNQdnNFbmFibGVkLmV4Y2hhbmdlKGZhbHNlLCBzdGQ6Om1lbW9yeV9vcmRlcl9hY3FfcmVsKTsKICAgICAgICBzUHZzU2VjdG9yQ291bnQuc3RvcmUoMCwgc3RkOjptZW1vcnlfb3JkZXJfcmVsYXhlZCk7CiAgICAgICAgc1B2c0FjdGl2ZUNvdW50LnN0b3JlKDAsIHN0ZDo6bWVtb3J5X29yZGVyX3JlbGF4ZWQpOwogICAgICAgIHNQdnNWaXNpYmxlTWFzay5zdG9yZSgwLCBzdGQ6Om1lbW9yeV9vcmRlcl9yZWxheGVkKTsKICAgICAgICBpZiAod2FzRW5hYmxlZCkKICAgICAgICAgICAgTG9nKERlYnVnOjpJbmZvKSA8PCAiVFNQX0lOVEVSSU9SX1ZJU0dSSURfMDUxX1Y1X1RPUE9fUFZTIGluYWN0aXZlIjsKICAgIH0KJycnCmFkZGl0aW9uID0gYW5jaG9yICsgJycnCgogICAgLy8gVFNQX1JPT01fT0JKRUNUX0xJRkVDWUNMRV8wNTFfVjI1CiAgICBib29sIGlzSW50ZXJpb3JUb3BvbG9neVB2c0VuYWJsZWQoKQogICAgewogICAgICAgIHJldHVybiBzUHZzRW5hYmxlZC5sb2FkKHN0ZDo6bWVtb3J5X29yZGVyX2FjcXVpcmUpOwogICAgfQoKICAgIGJvb2wgaXNJbnRlcmlvclRvcG9sb2d5T2JqZWN0UmVzaWRlbnQoCiAgICAgICAgY29uc3Qgb3NnOjpWZWMzZiYgb3JpZ2luLCBmbG9hdCByYWRpdXMsIGJvb2wgc3RydWN0dXJhbCkKICAgIHsKICAgICAgICBpZiAoIXNQdnNFbmFibGVkLmxvYWQoc3RkOjptZW1vcnlfb3JkZXJfYWNxdWlyZSkpCiAgICAgICAgICAgIHJldHVybiB0cnVlOwoKICAgICAgICBjb25zdCBpbnQgc2VjdG9yQ291bnQgPSBzUHZzU2VjdG9yQ291bnQubG9hZChzdGQ6Om1lbW9yeV9vcmRlcl9yZWxheGVkKTsKICAgICAgICBjb25zdCBzdGQ6OnVpbnQ2NF90IHZpc2libGVNYXNrID0gc1B2c1Zpc2libGVNYXNrLmxvYWQoc3RkOjptZW1vcnlfb3JkZXJfcmVsYXhlZCk7CiAgICAgICAgaWYgKHNlY3RvckNvdW50IDw9IDAgfHwgc2VjdG9yQ291bnQgPiBzUHZzTWF4U2VjdG9ycyB8fCB2aXNpYmxlTWFzayA9PSAwKQogICAgICAgICAgICByZXR1cm4gdHJ1ZTsKCiAgICAgICAgYm9vbCB0b3VjaGVkTWFwcGVkU2VjdG9yID0gZmFsc2U7CiAgICAgICAgZm9yIChpbnQgc2VjdG9yID0gMDsgc2VjdG9yIDwgc2VjdG9yQ291bnQ7ICsrc2VjdG9yKQogICAgICAgIHsKICAgICAgICAgICAgaWYgKCFwdnNPcmlnaW5PdmVybGFwc1NlY3RvcihvcmlnaW4sIHJhZGl1cywgc2VjdG9yLCBzdHJ1Y3R1cmFsKSkKICAgICAgICAgICAgICAgIGNvbnRpbnVlOwogICAgICAgICAgICB0b3VjaGVkTWFwcGVkU2VjdG9yID0gdHJ1ZTsKICAgICAgICAgICAgaWYgKCh2aXNpYmxlTWFzayAmIChzdGQ6OnVpbnQ2NF90eyAxIH0gPDwgc2VjdG9yKSkgIT0gMCkKICAgICAgICAgICAgICAgIHJldHVybiB0cnVlOwogICAgICAgIH0KICAgICAgICAvLyBBbnl0aGluZyBvdXRzaWRlIGFsbCBnZW5lcmF0ZWQgdG9wb2xvZ3kgYm94ZXMgZmFpbHMgb3Blbi4KICAgICAgICByZXR1cm4gIXRvdWNoZWRNYXBwZWRTZWN0b3I7CiAgICB9CicnJwppZiB2Yy5jb3VudChhbmNob3IpICE9IDE6CiAgICByYWlzZSBSdW50aW1lRXJyb3IoJ2ludGVyaW9ydmlzaWJpbGl0eS5jcHAgY2xlYXItUFZTIGFuY2hvciBjb3VudD0lZCcgJSB2Yy5jb3VudChhbmNob3IpKQp2YyA9IHZjLnJlcGxhY2UoYW5jaG9yLCBhZGRpdGlvbiwgMSkKCiMgU2NlbmUgc3RhdGUuCm9sZCA9ICcnJyAgICAgICAgc3RkOjp2ZWN0b3I8RVNNOjpSZWZOdW0+IG1QYWdlZFJlZnM7CgogICAgICAgIHN0ZDo6dmVjdG9yPG9zZzo6cmVmX3B0cjxTY2VuZVV0aWw6OldvcmtJdGVtPj4gbVdvcmtJdGVtczsKJycnCm5ldyA9ICcnJyAgICAgICAgc3RkOjp2ZWN0b3I8RVNNOjpSZWZOdW0+IG1QYWdlZFJlZnM7CgogICAgICAgIC8vIFRTUF9ST09NX09CSkVDVF9MSUZFQ1lDTEVfMDUxX1YyNQogICAgICAgIHN0ZDo6c2V0PEVTTTo6UmVmTnVtPiBtVHNwUm9vbVN1cHByZXNzZWRSZWZzOwogICAgICAgIENlbGxTdG9yZSogbVRzcFJvb21MaWZlY3ljbGVDZWxsID0gbnVsbHB0cjsKICAgICAgICBmbG9hdCBtVHNwUm9vbUxpZmVjeWNsZUFjY3VtdWxhdG9yID0gMC5mOwogICAgICAgIHN0ZDo6dWludDY0X3QgbVRzcFJvb21TdXBwcmVzc1RvdGFsID0gMDsKICAgICAgICBzdGQ6OnVpbnQ2NF90IG1Uc3BSb29tV2FrZVRvdGFsID0gMDsKICAgICAgICBmbG9hdCBtVHNwUm9vbUxvZ0FjY3VtdWxhdG9yID0gMC5mOwoKICAgICAgICBib29sIHRzcFJvb21PYmplY3RFbGlnaWJsZShjb25zdCBQdHImIHB0cikgY29uc3Q7CiAgICAgICAgdm9pZCB0c3BSb29tU3VwcHJlc3NPYmplY3QoY29uc3QgUHRyJiBwdHIpOwogICAgICAgIHZvaWQgdHNwUm9vbVdha2VPYmplY3QoY29uc3QgUHRyJiBwdHIpOwogICAgICAgIHZvaWQgdHNwVXBkYXRlUm9vbU9iamVjdExpZmVjeWNsZShmbG9hdCBkdXJhdGlvbik7CgogICAgICAgIHN0ZDo6dmVjdG9yPG9zZzo6cmVmX3B0cjxTY2VuZVV0aWw6OldvcmtJdGVtPj4gbVdvcmtJdGVtczsKJycnCmlmIHNoLmNvdW50KG9sZCkgIT0gMToKICAgIHJhaXNlIFJ1bnRpbWVFcnJvcignc2NlbmUuaHBwIG1QYWdlZFJlZnMgYW5jaG9yIGNvdW50PSVkJyAlIHNoLmNvdW50KG9sZCkpCnNoID0gc2gucmVwbGFjZShvbGQsIG5ldywgMSkKaWYgJyNpbmNsdWRlIDxjc3RkaW50Picgbm90IGluIHNoOgogICAgaW5jID0gJyNpbmNsdWRlIDxtZW1vcnk+XG4nCiAgICBpZiBzaC5jb3VudChpbmMpICE9IDE6CiAgICAgICAgcmFpc2UgUnVudGltZUVycm9yKCdzY2VuZS5ocHAgbWVtb3J5IGluY2x1ZGUgYW5jaG9yIGNvdW50PSVkJyAlIHNoLmNvdW50KGluYykpCiAgICBzaCA9IHNoLnJlcGxhY2UoaW5jLCAnI2luY2x1ZGUgPGNzdGRpbnQ+XG4nICsgaW5jLCAxKQoKIyBTY2VuZSBuZWVkcyB0aGUgcXVlcnkgZGVjbGFyYXRpb24uCm9sZCA9ICcnJyNpbmNsdWRlICIuLi9td3JlbmRlci9sYW5kbWFuYWdlci5ocHAiCiNpbmNsdWRlICIuLi9td3JlbmRlci9wb3N0cHJvY2Vzc29yLmhwcCIKI2luY2x1ZGUgIi4uL213cmVuZGVyL3JlbmRlcmluZ21hbmFnZXIuaHBwIgonJycKbmV3ID0gJycnI2luY2x1ZGUgIi4uL213cmVuZGVyL2xhbmRtYW5hZ2VyLmhwcCIKI2luY2x1ZGUgIi4uL213cmVuZGVyL3Bvc3Rwcm9jZXNzb3IuaHBwIgojaW5jbHVkZSAiLi4vbXdyZW5kZXIvcmVuZGVyaW5nbWFuYWdlci5ocHAiCiNpbmNsdWRlICIuLi9td3JlbmRlci9pbnRlcmlvcnZpc2liaWxpdHkuaHBwIgonJycKaWYgc2MuY291bnQob2xkKSAhPSAxOgogICAgcmFpc2UgUnVudGltZUVycm9yKCdzY2VuZS5jcHAgbXdyZW5kZXIgaW5jbHVkZSBhbmNob3IgY291bnQ9JWQnICUgc2MuY291bnQob2xkKSkKc2MgPSBzYy5yZXBsYWNlKG9sZCwgbmV3LCAxKQoKIyBPcmRpbmFyeSBPcGVuTVcgaW5kaXZpZHVhdGlvbiBvZiBhIHBhZ2VkIHJlZiBtdXN0IGNsZWFyIFYyNSBib29ra2VlcGluZyB0b28uCm9sZCA9ICcnJyAgICB2b2lkIFNjZW5lOjpyZW1vdmVGcm9tUGFnZWRSZWZzKGNvbnN0IFB0ciYgcHRyKQogICAgewogICAgICAgIEVTTTo6UmVmTnVtIHJlZm51bSA9IHB0ci5nZXRDZWxsUmVmKCkuZ2V0UmVmTnVtKCk7CiAgICAgICAgaWYgKHJlZm51bS5oYXNDb250ZW50RmlsZSgpICYmIHJlbW92ZUZyb21Tb3J0ZWQocmVmbnVtLCBtUGFnZWRSZWZzKSkKICAgICAgICB7CiAgICAgICAgICAgIGlmICghcHRyLmdldFJlZkRhdGEoKS5nZXRCYXNlTm9kZSgpKQogICAgICAgICAgICAgICAgcmV0dXJuOwogICAgICAgICAgICBwdHIuZ2V0Q2xhc3MoKS5pbnNlcnRPYmplY3RSZW5kZXJpbmcocHRyLCBnZXRNb2RlbChwdHIpLCBtUmVuZGVyaW5nKTsKICAgICAgICAgICAgc2V0Tm9kZVJvdGF0aW9uKHB0ciwgbVJlbmRlcmluZywgbWFrZU5vZGVSb3RhdGlvbihwdHIsIFJvdGF0aW9uT3JkZXI6OmRpcmVjdCkpOwogICAgICAgICAgICByZWxvYWRUZXJyYWluKCk7CiAgICAgICAgfQogICAgfQonJycKbmV3ID0gJycnICAgIHZvaWQgU2NlbmU6OnJlbW92ZUZyb21QYWdlZFJlZnMoY29uc3QgUHRyJiBwdHIpCiAgICB7CiAgICAgICAgRVNNOjpSZWZOdW0gcmVmbnVtID0gcHRyLmdldENlbGxSZWYoKS5nZXRSZWZOdW0oKTsKICAgICAgICBpZiAocmVmbnVtLmhhc0NvbnRlbnRGaWxlKCkgJiYgcmVtb3ZlRnJvbVNvcnRlZChyZWZudW0sIG1QYWdlZFJlZnMpKQogICAgICAgIHsKICAgICAgICAgICAgLy8gVFNQX1JPT01fT0JKRUNUX0xJRkVDWUNMRV8wNTFfVjI1CiAgICAgICAgICAgIG1Uc3BSb29tU3VwcHJlc3NlZFJlZnMuZXJhc2UocmVmbnVtKTsKICAgICAgICAgICAgaWYgKCFwdHIuZ2V0UmVmRGF0YSgpLmdldEJhc2VOb2RlKCkpCiAgICAgICAgICAgICAgICByZXR1cm47CiAgICAgICAgICAgIHB0ci5nZXRDbGFzcygpLmluc2VydE9iamVjdFJlbmRlcmluZyhwdHIsIGdldE1vZGVsKHB0ciksIG1SZW5kZXJpbmcpOwogICAgICAgICAgICBzZXROb2RlUm90YXRpb24ocHRyLCBtUmVuZGVyaW5nLCBtYWtlTm9kZVJvdGF0aW9uKHB0ciwgUm90YXRpb25PcmRlcjo6ZGlyZWN0KSk7CiAgICAgICAgICAgIHJlbG9hZFRlcnJhaW4oKTsKICAgICAgICB9CiAgICB9CicnJwppZiBzYy5jb3VudChvbGQpICE9IDE6CiAgICByYWlzZSBSdW50aW1lRXJyb3IoJ1NjZW5lOjpyZW1vdmVGcm9tUGFnZWRSZWZzIGFuY2hvciBjb3VudD0lZCcgJSBzYy5jb3VudChvbGQpKQpzYyA9IHNjLnJlcGxhY2Uob2xkLCBuZXcsIDEpCgp1cGRhdGVfYW5jaG9yID0gJycnICAgIHZvaWQgU2NlbmU6OnVwZGF0ZShmbG9hdCBkdXJhdGlvbikKICAgIHsKJycnCmltcGwgPSByJycnICAgIC8vIFRTUF9ST09NX09CSkVDVF9MSUZFQ1lDTEVfMDUxX1YyNQogICAgYm9vbCBTY2VuZTo6dHNwUm9vbU9iamVjdEVsaWdpYmxlKGNvbnN0IFB0ciYgcHRyKSBjb25zdAogICAgewogICAgICAgIGlmIChtQ3VycmVudENlbGwgPT0gbnVsbHB0ciB8fCBtQ3VycmVudENlbGwtPmlzRXh0ZXJpb3IoKSkKICAgICAgICAgICAgcmV0dXJuIGZhbHNlOwogICAgICAgIGlmIChwdHIuZ2V0Q2VsbCgpICE9IG1DdXJyZW50Q2VsbCkKICAgICAgICAgICAgcmV0dXJuIGZhbHNlOwogICAgICAgIGlmIChwdHIubVJlZi0+aXNEZWxldGVkKCkgfHwgIXB0ci5nZXRSZWZEYXRhKCkuaXNFbmFibGVkKCkKICAgICAgICAgICAgfHwgcHRyLm1SZWYtPm1SZWYuZ2V0Q291bnQoKSA8PSAwKQogICAgICAgICAgICByZXR1cm4gZmFsc2U7CiAgICAgICAgaWYgKHB0ci5nZXRDbGFzcygpLmlzQWN0b3IoKSB8fCBwdHIuZ2V0Q2xhc3MoKS5pc0Rvb3IoKSkKICAgICAgICAgICAgcmV0dXJuIGZhbHNlOwoKICAgICAgICBjb25zdCBpbnQgdHlwZSA9IHB0ci5nZXRUeXBlKCk7CiAgICAgICAgaWYgKHR5cGUgPT0gRVNNOjpSRUNfU1RBVCB8fCB0eXBlID09IEVTTTo6UkVDX1NUQVQ0KQogICAgICAgICAgICByZXR1cm4gZmFsc2U7CgogICAgICAgIGNvbnN0IEVTTTo6UmVmTnVtIHJlZm51bSA9IHB0ci5nZXRDZWxsUmVmKCkuZ2V0UmVmTnVtKCk7CiAgICAgICAgaWYgKCFyZWZudW0uaGFzQ29udGVudEZpbGUoKSkKICAgICAgICAgICAgcmV0dXJuIGZhbHNlOwoKICAgICAgICByZXR1cm4gIWdldE1vZGVsKHB0cikuZW1wdHkoKTsKICAgIH0KCiAgICB2b2lkIFNjZW5lOjp0c3BSb29tU3VwcHJlc3NPYmplY3QoY29uc3QgUHRyJiBwdHIpCiAgICB7CiAgICAgICAgY29uc3QgRVNNOjpSZWZOdW0gcmVmbnVtID0gcHRyLmdldENlbGxSZWYoKS5nZXRSZWZOdW0oKTsKICAgICAgICBpZiAoIXJlZm51bS5oYXNDb250ZW50RmlsZSgpCiAgICAgICAgICAgIHx8IG1Uc3BSb29tU3VwcHJlc3NlZFJlZnMuZmluZChyZWZudW0pICE9IG1Uc3BSb29tU3VwcHJlc3NlZFJlZnMuZW5kKCkpCiAgICAgICAgICAgIHJldHVybjsKCiAgICAgICAgLy8gUmVtb3ZlIHNjZW5lLXNpZGUgbWFjaGluZXJ5IG9ubHkuIFRoZSBDZWxsU3RvcmUvbGl2ZSByZWYgYW5kIHBlcnNpc3RlbnQKICAgICAgICAvLyBlbmFibGVkL2RlbGV0ZWQvY291bnQvaW52ZW50b3J5L3NjcmlwdCBzdGF0ZSByZW1haW4gYXV0aG9yaXRhdGl2ZS4KICAgICAgICBNV0Jhc2U6OkVudmlyb25tZW50OjpnZXQoKS5nZXRNZWNoYW5pY3NNYW5hZ2VyKCktPnJlbW92ZShwdHIsIHRydWUpOwoKICAgICAgICBpZiAoY29uc3QgYXV0byBvYmplY3QgPSBtUGh5c2ljcy0+Z2V0T2JqZWN0KHB0cikpCiAgICAgICAgewogICAgICAgICAgICBpZiAob2JqZWN0LT5nZXRTaGFwZUluc3RhbmNlKCktPm1WaXN1YWxDb2xsaXNpb25UeXBlCiAgICAgICAgICAgICAgICA9PSBSZXNvdXJjZTo6VmlzdWFsQ29sbGlzaW9uVHlwZTo6Tm9uZSkKICAgICAgICAgICAgICAgIG1OYXZpZ2F0b3IucmVtb3ZlT2JqZWN0KERldG91ck5hdmlnYXRvcjo6T2JqZWN0SWQob2JqZWN0KSwgbnVsbHB0cik7CiAgICAgICAgfQoKICAgICAgICBtUGh5c2ljcy0+cmVtb3ZlKHB0cik7CiAgICAgICAgbVJlbmRlcmluZy5yZW1vdmVPYmplY3QocHRyKTsKICAgICAgICBwdHIuZ2V0UmVmRGF0YSgpLnNldEJhc2VOb2RlKHBhZ2VkTm9kZSk7CgogICAgICAgIGNvbnN0IGF1dG8gcG9zID0gc3RkOjpsb3dlcl9ib3VuZChtUGFnZWRSZWZzLmJlZ2luKCksIG1QYWdlZFJlZnMuZW5kKCksIHJlZm51bSk7CiAgICAgICAgaWYgKHBvcyA9PSBtUGFnZWRSZWZzLmVuZCgpIHx8ICpwb3MgIT0gcmVmbnVtKQogICAgICAgICAgICBtUGFnZWRSZWZzLmluc2VydChwb3MsIHJlZm51bSk7CgogICAgICAgIG1Uc3BSb29tU3VwcHJlc3NlZFJlZnMuaW5zZXJ0KHJlZm51bSk7CiAgICAgICAgKyttVHNwUm9vbVN1cHByZXNzVG90YWw7CiAgICB9CgogICAgdm9pZCBTY2VuZTo6dHNwUm9vbVdha2VPYmplY3QoY29uc3QgUHRyJiBwdHIpCiAgICB7CiAgICAgICAgY29uc3QgRVNNOjpSZWZOdW0gcmVmbnVtID0gcHRyLmdldENlbGxSZWYoKS5nZXRSZWZOdW0oKTsKICAgICAgICBjb25zdCBhdXRvIHN1cHByZXNzZWQgPSBtVHNwUm9vbVN1cHByZXNzZWRSZWZzLmZpbmQocmVmbnVtKTsKICAgICAgICBpZiAoc3VwcHJlc3NlZCA9PSBtVHNwUm9vbVN1cHByZXNzZWRSZWZzLmVuZCgpKQogICAgICAgICAgICByZXR1cm47CgogICAgICAgIHJlbW92ZUZyb21Tb3J0ZWQocmVmbnVtLCBtUGFnZWRSZWZzKTsKICAgICAgICBtVHNwUm9vbVN1cHByZXNzZWRSZWZzLmVyYXNlKHN1cHByZXNzZWQpOwoKICAgICAgICBpZiAocHRyLm1SZWYtPmlzRGVsZXRlZCgpIHx8ICFwdHIuZ2V0UmVmRGF0YSgpLmlzRW5hYmxlZCgpCiAgICAgICAgICAgIHx8IHB0ci5tUmVmLT5tUmVmLmdldENvdW50KCkgPD0gMCkKICAgICAgICB7CiAgICAgICAgICAgIHB0ci5nZXRSZWZEYXRhKCkuc2V0QmFzZU5vZGUobnVsbHB0cik7CiAgICAgICAgICAgIHJldHVybjsKICAgICAgICB9CgogICAgICAgIGlmIChwdHIuZ2V0UmVmRGF0YSgpLmdldEJhc2VOb2RlKCkgPT0gcGFnZWROb2RlLmdldCgpKQogICAgICAgICAgICBwdHIuZ2V0UmVmRGF0YSgpLnNldEJhc2VOb2RlKG51bGxwdHIpOwoKICAgICAgICBjb25zdCBWRlM6OlBhdGg6Ok5vcm1hbGl6ZWQgbW9kZWwgPSBnZXRNb2RlbChwdHIpOwogICAgICAgIGlmIChtb2RlbC5lbXB0eSgpKQogICAgICAgICAgICByZXR1cm47CgogICAgICAgIGNvbnN0IGF1dG8gcm90YXRpb24gPSBtYWtlRGlyZWN0Tm9kZVJvdGF0aW9uKHB0cik7CiAgICAgICAgcHRyLmdldENsYXNzKCkuaW5zZXJ0T2JqZWN0UmVuZGVyaW5nKHB0ciwgbW9kZWwsIG1SZW5kZXJpbmcpOwogICAgICAgIHNldE5vZGVSb3RhdGlvbihwdHIsIG1SZW5kZXJpbmcsIHJvdGF0aW9uKTsKCiAgICAgICAgaWYgKHB0ci5nZXRDbGFzcygpLnVzZUFuaW0oKSkKICAgICAgICAgICAgTVdCYXNlOjpFbnZpcm9ubWVudDo6Z2V0KCkuZ2V0TWVjaGFuaWNzTWFuYWdlcigpLT5hZGQocHRyKTsKCiAgICAgICAgbVdvcmxkLmFwcGx5TG9vcGluZ1BhcnRpY2xlcyhwdHIpOwogICAgICAgIHB0ci5nZXRDbGFzcygpLmluc2VydE9iamVjdChwdHIsIG1vZGVsLCByb3RhdGlvbiwgKm1QaHlzaWNzKTsKICAgICAgICBhZGRPYmplY3QocHRyLCBtV29ybGQsICptUGh5c2ljcywgbUxvd2VzdFBvaW50LCB0cnVlLCBtTmF2aWdhdG9yKTsKICAgICAgICArK21Uc3BSb29tV2FrZVRvdGFsOwogICAgfQoKICAgIHZvaWQgU2NlbmU6OnRzcFVwZGF0ZVJvb21PYmplY3RMaWZlY3ljbGUoZmxvYXQgZHVyYXRpb24pCiAgICB7CiAgICAgICAgaWYgKG1DdXJyZW50Q2VsbCAhPSBtVHNwUm9vbUxpZmVjeWNsZUNlbGwpCiAgICAgICAgewogICAgICAgICAgICBtVHNwUm9vbUxpZmVjeWNsZUNlbGwgPSBtQ3VycmVudENlbGw7CiAgICAgICAgICAgIG1Uc3BSb29tU3VwcHJlc3NlZFJlZnMuY2xlYXIoKTsKICAgICAgICAgICAgbVRzcFJvb21MaWZlY3ljbGVBY2N1bXVsYXRvciA9IDAuZjsKICAgICAgICAgICAgbVRzcFJvb21Mb2dBY2N1bXVsYXRvciA9IDAuZjsKICAgICAgICB9CgogICAgICAgIGlmIChtQ3VycmVudENlbGwgPT0gbnVsbHB0ciB8fCBtQ3VycmVudENlbGwtPmlzRXh0ZXJpb3IoKSkKICAgICAgICAgICAgcmV0dXJuOwoKICAgICAgICBtVHNwUm9vbUxpZmVjeWNsZUFjY3VtdWxhdG9yICs9IHN0ZDo6bWF4KDAuZiwgZHVyYXRpb24pOwogICAgICAgIG1Uc3BSb29tTG9nQWNjdW11bGF0b3IgKz0gc3RkOjptYXgoMC5mLCBkdXJhdGlvbik7CiAgICAgICAgaWYgKG1Uc3BSb29tTGlmZWN5Y2xlQWNjdW11bGF0b3IgPCAwLjA1ZikKICAgICAgICAgICAgcmV0dXJuOwogICAgICAgIG1Uc3BSb29tTGlmZWN5Y2xlQWNjdW11bGF0b3IgPSAwLmY7CgogICAgICAgIGNvbnN0IGJvb2wgcHZzRW5hYmxlZCA9IE1XUmVuZGVyOjppc0ludGVyaW9yVG9wb2xvZ3lQdnNFbmFibGVkKCk7CiAgICAgICAgc3RkOjp2ZWN0b3I8UHRyPiB0b1dha2U7CiAgICAgICAgc3RkOjp2ZWN0b3I8UHRyPiB0b1N1cHByZXNzOwogICAgICAgIGludCBlbGlnaWJsZSA9IDA7CiAgICAgICAgaW50IHJlc2lkZW50ID0gMDsKICAgICAgICBpbnQgaW5hY3RpdmUgPSAwOwoKICAgICAgICBtQ3VycmVudENlbGwtPmZvckVhY2goWyZdKGNvbnN0IFB0ciYgcHRyKSB7CiAgICAgICAgICAgIGlmICghdHNwUm9vbU9iamVjdEVsaWdpYmxlKHB0cikpCiAgICAgICAgICAgICAgICByZXR1cm4gdHJ1ZTsKCiAgICAgICAgICAgICsrZWxpZ2libGU7CiAgICAgICAgICAgIGNvbnN0IEVTTTo6UmVmTnVtIHJlZm51bSA9IHB0ci5nZXRDZWxsUmVmKCkuZ2V0UmVmTnVtKCk7CiAgICAgICAgICAgIGNvbnN0IG9zZzo6VmVjM2Ygb3JpZ2luID0gcHRyLmdldFJlZkRhdGEoKS5nZXRQb3NpdGlvbigpLmFzVmVjMygpOwogICAgICAgICAgICBjb25zdCBib29sIHNob3VsZExpdmUgPSBNV1JlbmRlcjo6aXNJbnRlcmlvclRvcG9sb2d5T2JqZWN0UmVzaWRlbnQoCiAgICAgICAgICAgICAgICBvcmlnaW4sIDQ4LmYsIGZhbHNlKTsKCiAgICAgICAgICAgIGlmIChzaG91bGRMaXZlKQogICAgICAgICAgICB7CiAgICAgICAgICAgICAgICArK3Jlc2lkZW50OwogICAgICAgICAgICAgICAgaWYgKG1Uc3BSb29tU3VwcHJlc3NlZFJlZnMuZmluZChyZWZudW0pICE9IG1Uc3BSb29tU3VwcHJlc3NlZFJlZnMuZW5kKCkpCiAgICAgICAgICAgICAgICAgICAgdG9XYWtlLnB1c2hfYmFjayhwdHIpOwogICAgICAgICAgICB9CiAgICAgICAgICAgIGVsc2UKICAgICAgICAgICAgewogICAgICAgICAgICAgICAgKytpbmFjdGl2ZTsKICAgICAgICAgICAgICAgIGlmIChtVHNwUm9vbVN1cHByZXNzZWRSZWZzLmZpbmQocmVmbnVtKSA9PSBtVHNwUm9vbVN1cHByZXNzZWRSZWZzLmVuZCgpKQogICAgICAgICAgICAgICAgICAgIHRvU3VwcHJlc3MucHVzaF9iYWNrKHB0cik7CiAgICAgICAgICAgIH0KICAgICAgICAgICAgcmV0dXJuIHRydWU7CiAgICAgICAgfSk7CgogICAgICAgIC8vIFByZXdhcm0gYWx3YXlzIHdpbnMgYmVmb3JlIG9sZC1yb29tIHN1cHByZXNzaW9uIHdvcmsuCiAgICAgICAgY29uc3RleHByIHN0ZDo6c2l6ZV90IHdha2VCdWRnZXQgPSAzMjsKICAgICAgICBjb25zdGV4cHIgc3RkOjpzaXplX3Qgc3VwcHJlc3NCdWRnZXQgPSA2NDsKICAgICAgICBmb3IgKHN0ZDo6c2l6ZV90IGkgPSAwOyBpIDwgdG9XYWtlLnNpemUoKSAmJiBpIDwgd2FrZUJ1ZGdldDsgKytpKQogICAgICAgICAgICB0c3BSb29tV2FrZU9iamVjdCh0b1dha2VbaV0pOwogICAgICAgIGZvciAoc3RkOjpzaXplX3QgaSA9IDA7IGkgPCB0b1N1cHByZXNzLnNpemUoKSAmJiBpIDwgc3VwcHJlc3NCdWRnZXQ7ICsraSkKICAgICAgICAgICAgdHNwUm9vbVN1cHByZXNzT2JqZWN0KHRvU3VwcHJlc3NbaV0pOwoKICAgICAgICBpZiAobVRzcFJvb21Mb2dBY2N1bXVsYXRvciA+PSAxLmYpCiAgICAgICAgewogICAgICAgICAgICBtVHNwUm9vbUxvZ0FjY3VtdWxhdG9yID0gMC5mOwogICAgICAgICAgICBMb2coRGVidWc6OkluZm8pCiAgICAgICAgICAgICAgICA8PCAiW1RTUF9ST09NT0JKX1YyNV0gcHZzPSIgPDwgKHB2c0VuYWJsZWQgPyAxIDogMCkKICAgICAgICAgICAgICAgIDw8ICIgZWxpZ2libGU9IiA8PCBlbGlnaWJsZQogICAgICAgICAgICAgICAgPDwgIiByZXNpZGVudD0iIDw8IHJlc2lkZW50CiAgICAgICAgICAgICAgICA8PCAiIGluYWN0aXZlPSIgPDwgaW5hY3RpdmUKICAgICAgICAgICAgICAgIDw8ICIgcGFya2VkPSIgPDwgbVRzcFJvb21TdXBwcmVzc2VkUmVmcy5zaXplKCkKICAgICAgICAgICAgICAgIDw8ICIgd2FrZVE9IiA8PCB0b1dha2Uuc2l6ZSgpCiAgICAgICAgICAgICAgICA8PCAiIHN1cHByZXNzUT0iIDw8IHRvU3VwcHJlc3Muc2l6ZSgpCiAgICAgICAgICAgICAgICA8PCAiIHN1cHByZXNzVG90YWw9IiA8PCBtVHNwUm9vbVN1cHByZXNzVG90YWwKICAgICAgICAgICAgICAgIDw8ICIgd2FrZVRvdGFsPSIgPDwgbVRzcFJvb21XYWtlVG90YWw7CiAgICAgICAgfQogICAgfQoKJycnCmlmIHNjLmNvdW50KHVwZGF0ZV9hbmNob3IpICE9IDE6CiAgICByYWlzZSBSdW50aW1lRXJyb3IoJ1NjZW5lOjp1cGRhdGUgYW5jaG9yIGNvdW50PSVkJyAlIHNjLmNvdW50KHVwZGF0ZV9hbmNob3IpKQpzYyA9IHNjLnJlcGxhY2UodXBkYXRlX2FuY2hvciwgaW1wbCArIHVwZGF0ZV9hbmNob3IsIDEpCgpvbGQgPSAnJycgICAgICAgIG1QcmVsb2FkZXItPnVwZGF0ZUNhY2hlKG1SZW5kZXJpbmcuZ2V0UmVmZXJlbmNlVGltZSgpKTsKICAgICAgICBwcmVsb2FkQ2VsbHMoZHVyYXRpb24pOwonJycKbmV3ID0gJycnICAgICAgICBtUHJlbG9hZGVyLT51cGRhdGVDYWNoZShtUmVuZGVyaW5nLmdldFJlZmVyZW5jZVRpbWUoKSk7CiAgICAgICAgcHJlbG9hZENlbGxzKGR1cmF0aW9uKTsKCiAgICAgICAgLy8gVFNQX1JPT01fT0JKRUNUX0xJRkVDWUNMRV8wNTFfVjI1CiAgICAgICAgdHNwVXBkYXRlUm9vbU9iamVjdExpZmVjeWNsZShkdXJhdGlvbik7CicnJwppZiBzYy5jb3VudChvbGQpICE9IDE6CiAgICByYWlzZSBSdW50aW1lRXJyb3IoJ1NjZW5lOjp1cGRhdGUgdGFpbCBhbmNob3IgY291bnQ9JWQnICUgc2MuY291bnQob2xkKSkKc2MgPSBzYy5yZXBsYWNlKG9sZCwgbmV3LCAxKQoKZm9yIHRva2VuIGluIChNQVJLLCAndHNwUm9vbU9iamVjdEVsaWdpYmxlJywgJ3RzcFJvb21TdXBwcmVzc09iamVjdCcsICd0c3BSb29tV2FrZU9iamVjdCcsCiAgICAgICAgICAgICAgJ3RzcFVwZGF0ZVJvb21PYmplY3RMaWZlY3ljbGUnLCAnW1RTUF9ST09NT0JKX1YyNV0nLCAnbVBoeXNpY3MtPnJlbW92ZShwdHIpOycsCiAgICAgICAgICAgICAgJ21SZW5kZXJpbmcucmVtb3ZlT2JqZWN0KHB0cik7JywgJ3B0ci5nZXRDbGFzcygpLmluc2VydE9iamVjdFJlbmRlcmluZyhwdHIsIG1vZGVsLCBtUmVuZGVyaW5nKTsnLAogICAgICAgICAgICAgICdwdHIuZ2V0Q2xhc3MoKS5pbnNlcnRPYmplY3QocHRyLCBtb2RlbCwgcm90YXRpb24sICptUGh5c2ljcyk7Jyk6CiAgICBpZiB0b2tlbiBub3QgaW4gc2M6CiAgICAgICAgcmFpc2UgUnVudGltZUVycm9yKCdzY2VuZS5jcHAgVjI1IHBvc3Rjb25kaXRpb24gbWlzc2luZzogJyArIHRva2VuKQpmb3IgdG9rZW4gaW4gKE1BUkssICdtVHNwUm9vbVN1cHByZXNzZWRSZWZzJywgJ21Uc3BSb29tTGlmZWN5Y2xlQWNjdW11bGF0b3InLCAnI2luY2x1ZGUgPGNzdGRpbnQ+Jyk6CiAgICBpZiB0b2tlbiBub3QgaW4gc2g6CiAgICAgICAgcmFpc2UgUnVudGltZUVycm9yKCdzY2VuZS5ocHAgVjI1IHBvc3Rjb25kaXRpb24gbWlzc2luZzogJyArIHRva2VuKQpmb3IgdG9rZW4gaW4gKE1BUkssICdpc0ludGVyaW9yVG9wb2xvZ3lQdnNFbmFibGVkJywgJ2lzSW50ZXJpb3JUb3BvbG9neU9iamVjdFJlc2lkZW50Jyk6CiAgICBpZiB0b2tlbiBub3QgaW4gdmMgb3IgdG9rZW4gbm90IGluIHZoOgogICAgICAgIHJhaXNlIFJ1bnRpbWVFcnJvcigndmlzaWJpbGl0eSBWMjUgcG9zdGNvbmRpdGlvbiBtaXNzaW5nOiAnICsgdG9rZW4pCgphbmltX3BhdGggPSBzY2VuZV9jcHBfcGF0aC5yZXBsYWNlKCcvbXd3b3JsZC9zY2VuZS5jcHAnLCAnL213cmVuZGVyL2FuaW1hdGlvbi5jcHAnKQp0cnk6CiAgICBhbmltID0gcmVhZChhbmltX3BhdGgpCiAgICBpZiAnbVB0ci5nZXQ8RVNNOjpTdGF0aWM+KCknIGluIGFuaW06CiAgICAgICAgcmFpc2UgUnVudGltZUVycm9yKCd1bnNhZmUgbVB0ci5nZXQ8RVNNOjpTdGF0aWM+KCkgY2FzdCBpcyBwcmVzZW50OyByZWZ1c2luZyBWMjUnKQpleGNlcHQgRmlsZU5vdEZvdW5kRXJyb3I6CiAgICBwYXNzCgp3cml0ZShzY2VuZV9jcHBfcGF0aCwgc2MpCndyaXRlKHNjZW5lX2hwcF9wYXRoLCBzaCkKd3JpdGUodmlzX2NwcF9wYXRoLCB2YykKd3JpdGUodmlzX2hwcF9wYXRoLCB2aCkKCnByaW50KCdQQVNTOiBWMjUgc2NlbmUgbGlmZWN5Y2xlIHBhdGNoIGFwcGxpZWQuJykKcHJpbnQoJ1BBU1M6IGluYWN0aXZlIG1hcHBlZC1yb29tIGNsdXR0ZXIgcmVtb3ZlcyByZW5kZXJpbmcgKyBwaHlzaWNzL25hdm1lc2guJykKcHJpbnQoJ1BBU1M6IHJlc2lkZW50L3ByZXdhcm1lZCBjbHV0dGVyIHJlY29uc3RydWN0cyByZW5kZXJpbmcgKyBwaHlzaWNzL25hdm1lc2guJykKcHJpbnQoJ1BBU1M6IENlbGxTdG9yZSByZWZzIGFyZSBuZXZlciBkaXNhYmxlZC9kZWxldGVkLicpCnByaW50KCdQQVNTOiBubyBmYWtlIEx1YSBvYmplY3RSZW1vdmVkL29iamVjdEFkZGVkIG5vdGlmaWNhdGlvbnMgd2VyZSBhZGRlZC4nKQpwcmludCgnUEFTUzogYWN0b3JzL2Rvb3JzL3N0YXRpY3MgYXJlIGV4Y2x1ZGVkIGZyb20gVjI1IG9iamVjdCBsaWZlY3ljbGUuJykK
PATCH_B64
python3 -m py_compile "$TMP/v25_patch.py"
docker cp "$TMP/v25_patch.py" "$CTR:/tmp/v25_patch.py"
docker exec "$CTR" python3 /tmp/v25_patch.py "$SCENE_CPP" "$SCENE_HPP" "$VIS_CPP" "$VIS_HPP"
docker exec "$CTR" rm -f /tmp/v25_patch.py
docker exec "$CTR" bash -lc "set -e; grep -Fq 'TSP_ROOM_OBJECT_LIFECYCLE_051_V25' '$SCENE_CPP'; grep -Fq '[TSP_ROOMOBJ_V25]' '$SCENE_CPP'; grep -Fq 'isInteriorTopologyObjectResident' '$VIS_CPP'; ! grep -Fq 'mPtr.get<ESM::Static>()' '$ANIM'"

echo
echo "===== 4/8 BUILD ====="
BUILD_LOG=/root/openmw51-visgrid-v25-room-object-lifecycle-$STAMP.log
set +e
docker exec "$CTR" bash -lc "set -o pipefail; cd '$BUILD'; cmake --build . --target openmw --parallel '${OPENMW_JOBS:-2}' 2>&1 | tee '$BUILD_LOG'"
RC=$?
set -e
if [ "$RC" -ne 0 ]; then
  echo "BUILD FAILED — last 200 lines:"
  docker exec "$CTR" bash -lc "tail -n 200 '$BUILD_LOG' || true"
  false
fi

echo
echo "===== 5/8 PACKAGE / VERIFY ====="
docker exec "$CTR" bash -lc "set -e; test -s '$BUILT'; mkdir -p '$(dirname "$PACKAGED")'; install -m 755 '$BUILT' '$PACKAGED'; file '$PACKAGED'; file '$PACKAGED' | grep -Eq 'ARM aarch64|ARM64|AArch64'; sha256sum '$PACKAGED'; strings '$PACKAGED' | grep -E 'TSP_ROOMOBJ_V25|TSP_OBJECT_DIAG_051_V1' | sort -u | head -40 || true"
NEW_SHA="$(docker exec "$CTR" sha256sum "$PACKAGED" | awk '{print $1}')"
[ "$NEW_SHA" != "$PRE_SHA" ] || die "rebuilt hash did not change"
docker cp "$CTR:$PACKAGED" "$HOST_BIN"
chmod +x "$HOST_BIN"
[ "$(sha256sum "$HOST_BIN" | awk '{print $1}')" = "$NEW_SHA" ] || die "Docker->Ubuntu SHA mismatch"
file "$HOST_BIN"; sha256sum "$HOST_BIN"

echo
echo "===== 6/8 CREATE V25 AUTOMATIC CAPTURE ====="
cat > "$TMP/tsp_visgrid_v25_capture.sh" <<'CAPTURE'
#!/bin/bash
set +e
ROOT=/mnt/SDCARD/data/ports/openmw51
OUTDIR="$ROOT/visgrid-v25-captures"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="$OUTDIR/visgrid-v25-$STAMP.txt"
LATEST="$ROOT/visgrid-v25-latest.txt"
mkdir -p "$OUTDIR"
RAW=/tmp/visgrid-v25-raw.$$
: > "$RAW"
for f in "$ROOT/openmw_051_log.txt" "$ROOT/config-0.51/openmw.log" "$ROOT/openmw.log"; do
  [ -f "$f" ] || continue
  tail -n 50000 "$f" | awk '
    /\[TSP_VISGRID_V24\] ROOM-RESIDENCY/ { buf=""; found=1 }
    found { buf=buf $0 ORS }
    END { if (found) printf "%s", buf }
  ' >> "$RAW"
done
{
  echo "============================================================"
  echo "OPENMW 0.51 VISGRID V25 AUTOMATIC CAPTURE"
  echo "============================================================"
  date
  echo
  echo "===== IDENTITY ====="
  sha256sum "$ROOT/bin/openmw-0.51" "$ROOT/mods/TSPInteriorVisGrid/scripts/TSPInteriorVisGrid/visgrid.lua" 2>/dev/null || true
  echo
  BAD="$(grep -c 'Bad LiveCellRef cast to STAT' "$RAW" || true)"
  FAIL="$(grep -c 'failed to render' "$RAW" || true)"
  PVS="$(grep -c '\[TSP_VISOBJ_CULL\] reason=PVS' "$RAW" || true)"
  GRID="$(grep -c '\[TSP_VISOBJ_CULL\] reason=GRID' "$RAW" || true)"
  LAST="$(grep '\[TSP_ROOMOBJ_V25\]' "$RAW" | tail -1)"
  echo "V25 SUMMARY"
  echo "Bad STAT casts: $BAD"
  echo "Render failures: $FAIL"
  echo "PVS culls logged: $PVS"
  echo "GRID culls logged: $GRID"
  echo "V25 LAST: $LAST"
  echo
  echo "===== V25 ROOM OBJECT LIFECYCLE ====="
  grep '\[TSP_ROOMOBJ_V25\]' "$RAW" | tail -2500 || true
  echo
  echo "===== V24 ROOM / PVS / RAY ====="
  grep -E 'TSP_VISGRID_V24|TSP_VISGRID_V23PERF|TSP_VISGRID_V20.*PVS|RAY-PVS|PVS SHADOW|PVS RELEASE|topology sector=|sector switch' "$RAW" | tail -2200 || true
  echo
  echo "===== OBJECT DIAGNOSTICS ====="
  grep -E 'TSP_VISOBJ_CULL|TSP_VISOBJ_ATTACH|Bad LiveCellRef cast|failed to render' "$RAW" | tail -2600 || true
  echo
  echo "===== PERF TAIL ====="
  [ ! -f "$ROOT/openmw51_perf_latest.txt" ] || tail -700 "$ROOT/openmw51_perf_latest.txt"
} > "$OUT"
cp -f "$OUT" "$LATEST"
sync
rm -f "$RAW"
echo "V25 automatic capture: $OUT"
CAPTURE
chmod +x "$TMP/tsp_visgrid_v25_capture.sh"
bash -n "$TMP/tsp_visgrid_v25_capture.sh"

echo
echo "===== 7/8 DEVICE BACKUP / INSTALL ====="
DEVICE_BACKUP="$ROOT/backups/visgrid-v25-room-object-lifecycle-$STAMP"
ssh "$DEV" "bash -s" <<REMOTE_BACKUP
set -e
B='$DEVICE_BACKUP'
mkdir -p "\$B"
cp -pf '$REMOTE_BIN' "\$B/openmw-0.51.before"
if [ -f '$CAPTURE_HELPER' ]; then touch "\$B/helper.existed"; cp -pf '$CAPTURE_HELPER' "\$B/capture-helper.before"; fi
sha256sum "\$B/openmw-0.51.before"
REMOTE_BACKUP
DEVICE_DEPLOY_STARTED=1
scp -q "$HOST_BIN" "$DEV:$REMOTE_TMP_BIN"
scp -q "$TMP/tsp_visgrid_v25_capture.sh" "$DEV:/tmp/tsp_visgrid_v25_capture.sh"
ssh "$DEV" "bash -s" <<REMOTE_INSTALL
set -e
test "\$(sha256sum '$REMOTE_TMP_BIN' | awk '{print \$1}')" = '$NEW_SHA'
install -m 755 '$REMOTE_TMP_BIN' '$REMOTE_BIN'
install -m 755 /tmp/tsp_visgrid_v25_capture.sh '$CAPTURE_HELPER'
rm -f '$REMOTE_TMP_BIN' /tmp/tsp_visgrid_v25_capture.sh
sync
test "\$(sha256sum '$REMOTE_BIN' | awk '{print \$1}')" = '$NEW_SHA'
grep -Fq 'TSP_VISGRID_LUA_V24_ROOM_RESIDENCY' '$LIVE_LUA'
sha256sum '$REMOTE_BIN' '$LIVE_LUA'
REMOTE_INSTALL

echo
echo "===== 8/8 STATE ====="
cat > "$STATE" <<EOF_STATE
SOURCE_BACKUP='$SOURCE_BACKUP'
DEVICE_BACKUP='$DEVICE_BACKUP'
PRE_DEVICE_SHA='$PRE_SHA'
FIX_DEVICE_SHA='$NEW_SHA'
LIVE_LUA_SHA='$LUA_SHA'
HOST_BIN='$HOST_BIN'
EOF_STATE
trap - ERR

echo
echo "============================================================"
echo "V25 INSTALLED"
echo "============================================================"
echo "Inactive mapped-room objects are now genuinely absent from:"
echo "  - OpenMW object renderer"
echo "  - Bullet object set"
echo "  - navigator object set when applicable"
echo "The CellStore ref / inventory / scripts / persistent state remain."
echo
echo "Prewarm runs first: 32 wakes per 0.05 s tick; 64 suppressions per tick."
echo "Actors, doors and static architecture are untouched."
echo
echo "TEST ONCE in the same Caldera upper-floor wall case, then walk through"
echo "stairs/doors and check item appearance, container activation/collision,"
echo "and revisiting the prior room. Exit normally."
echo
echo "Then download the automatic capture:"
echo "  cd ~/Downloads"
echo "  ./apply_openmw51_tsp_visgrid_v25_room_object_lifecycle.sh collect"
echo
echo "Rollback:"
echo "  ./apply_openmw51_tsp_visgrid_v25_room_object_lifecycle.sh rollback"
echo "============================================================"
