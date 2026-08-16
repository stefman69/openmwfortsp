OpenMW 0.51 TrimUI Smart Pro S - v7 optional tools
===================================================

apply-runtime-profile-v7.sh
---------------------------
Run once on the TSP after installing the v7 binary.

It keeps:
  near clip = 15
  Project Atlas enabled

It sets:
  water culling = true
  object paging active grid = false
  preload enabled = false
  cache expiry delay = 1
  navigator in-memory tile cache = 32 MiB
  navmesh updater threads = 1
  navmesh disk cache = enabled
  runtime navmesh database writes = enabled

generate-navmesh.sh
-------------------
OPTIONAL. The launcher does not call this.

Run manually to pre-generate navmesh.db using the currently installed
Morrowind data files and active OpenMW mod/content profile.

Default:
  NAVMESH_THREADS=1
  exterior worldspaces only

Examples:

  /mnt/SDCARD/data/ports/openmw51/tools/generate-navmesh.sh

Include interiors:
  NAVMESH_INTERIORS=true \
  /mnt/SDCARD/data/ports/openmw51/tools/generate-navmesh.sh

Use two workers:
  NAVMESH_THREADS=2 \
  /mnt/SDCARD/data/ports/openmw51/tools/generate-navmesh.sh

The generated database is:
  /mnt/SDCARD/data/ports/openmw51/savegame-0.51/navmesh.db

If mods that change collision/world geometry are added or removed, run the
tool again. By default it removes cached tiles not used by the current content
profile and updates the tiles that need regeneration.
