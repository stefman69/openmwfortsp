OpenMW 0.51 TrimUI Smart Pro S - SafeNav + memory trace v10
===========================================================

WHAT V10 CHANGES
---------------
The v10 executable defaults to a Navigator stub instead of starting the live
Recast/Detour Navigator. It also short-circuits Detour path queries to
NavMeshNotFound unless OPENMW_TSP_ENABLE_NAVIGATOR=1 is explicitly exported.

Normal v10 gameplay therefore uses OpenMW's existing pathgrid/straight-path
fallback and does not run the live Recast navmesh updater.

The existing pre-generated navmesh.db is preserved. It is simply dormant in
the default SafeNav test so we can isolate the navigation subsystem as a crash
source without throwing away the expensive cache generation work.

MEMORY TRACE
------------
This diagnostic build writes a low-overhead memory snapshot to the normal
OpenMW log every two seconds. No separate profiler is required.

Search the log for:

  TSP MEMPROC   process/kernel/allocator memory and per-sample deltas
  TSP MEMCACHE  OpenMW resource-cache sizes/hits/expired counters
  TSP MEMSCENE  scene nodes, shared textures, shared StateSets, compile queue
  TSP MEMCLEAR  entries removed by a full ResourceSystem cache clear

Important fields:

  rss_kb / rss_d            resident memory and change since prior sample
  anon_kb / anon_d          anonymous resident memory and its change
  file_kb / file_d          file-backed resident memory and its change
  vmdata_kb / vmdata_d      process data/heap virtual memory
  malloc_inuse_b            glibc heap bytes currently allocated
  malloc_free_b             free bytes retained inside glibc arenas
  cmafree_kb / cmafree_d    system contiguous-memory pool; useful for GPU/driver
  size / size_d             resource cache entries and change since prior sample
  expired                   cumulative entries expired from that cache

Interpretation:

  RSS + malloc_inuse + cache sizes rise together:
      OpenMW is keeping live CPU-side objects/resources.

  RSS stays high while malloc_inuse drops and malloc_free rises:
      allocator fragmentation/arena retention is a leading suspect.

  Scene shared_textures/shared_statesets continually rise:
      OSG/render-resource retention is a leading suspect.

  Process heap is stable but cmafree steadily falls:
      graphics/driver/CMA retention becomes a leading suspect.

  Cache sizes repeatedly return to baseline while RSS rises:
      the persistent memory is outside the ordinary OpenMW resource caches.

RUNTIME PROFILE
---------------
Run once after installing v10:

  /mnt/SDCARD/data/ports/openmw51/tools/apply-runtime-profile-v10.sh

It preserves the existing TSP memory/render settings and sets:

  [Navigator]
  enable = false
  wait until min distance to player = 0
  enable nav mesh disk cache = true
  write to navmeshdb = false
  async nav mesh updater threads = 1
  max nav mesh tiles cache size = 33554432
  wait for all jobs on exit = false

EXPECTED LOG
------------
When an existing settings source still says Navigator is enabled, the binary
may print once during startup:

  TSP SafeNav v10: Navigator forced to stub; set OPENMW_TSP_ENABLE_NAVIGATOR=1 to opt back in.

During the SafeNav test there should be NO new messages such as:

  Added ... collision shape to navmeshdb with id ...

and no runtime Recast tile-generation activity should be required.

LATER CACHED-NAVIGATOR RETEST
-----------------------------
Only after SafeNav has been stability-tested, the real Navigator can be
explicitly re-enabled by BOTH:

  export OPENMW_TSP_ENABLE_NAVIGATOR=1

and:

  [Navigator]
  enable = true
  write to navmeshdb = false

Keeping write to navmeshdb=false makes that later test read-only with respect
to the persistent database. Missing/changed tiles may still be generated in
RAM by the real Navigator, which is why that mode is NOT the v10 stability
default.

DEBUGGER
--------
The v10 OpenMW executable is intentionally left unstripped. The build script
also makes a best-effort attempt to place libncursesw.so.5 and libtinfo.so.5 in
package/lib for the TSP crash handler's gdb dependency.
