# OpenMW 0.51 TrimUI Smart Pro Manager V2

This is the first functional revision built from the framebuffer launcher mockup. It is installed as a separate Ports entry named `OpenMW_51_Manager_v2`; the proven `Morrowind_51.sh` remains unchanged and is executed only after the player selects **Play Morrowind**.

## Integrated paths

| Component | Canonical path |
|---|---|
| OpenMW port | `/mnt/SDCARD/data/ports/openmw51` |
| Main content profile | `/mnt/SDCARD/data/ports/openmw51/openmw.cfg` |
| Manager state | `/mnt/SDCARD/data/ports/openmw51/launcher` |
| Navmesh database | `/mnt/UDISK/openmw51-nav/navmesh.db` |
| Navmesh profile fingerprint | `/mnt/UDISK/openmw51-nav/profile.sha256` |
| Swapfile | `/mnt/UDISK/openmw51-swapfile` |
| Existing generator | `OpenMW_51_Generate_Full_Navmesh_3Worker.sh` in the active Ports directory |

## What is functional

- Direct framebuffer/controller UI using the prototype's proven `/dev/fb0` and evdev approach.
- Play handoff to the unchanged working Morrowind launcher.
- Read-only startup scan of game data, UDisk, swap, canonical navmesh, generator, mod roots, plugins and configuration health.
- Automatic discovery of a valid prebuilt SQLite navmesh beneath `/mnt/SDCARD/data/ports`, excluding save, backup and tool-runtime databases. A configured path in `launcher/default-navmesh.path` has priority. Tied candidates are rejected rather than guessed; all candidates are printed in `launcher/default-navmesh-candidates.txt`.
- Confirmed, transactional base-navmesh installation into the one canonical UDisk database. The staged copy is SHA-256 verified before publication. There is intentionally no second working database and no automatic navmesh backup.
- Confirmed creation/activation of the same 512 MB `/mnt/UDISK/openmw51-swapfile` already proven by the working launcher. It requires a swap-capable UDisk filesystem and twice the requested capacity free before creation, then applies swappiness `150` and VFS cache pressure `50`.
- Direct launch of the existing current-source navmesh generator with its three-worker, exterior-plus-interior, stale-tile-pruning and graphical progress behavior.
- Persistent mod data-root discovery, enable/disable and manual asset-priority ordering. Discovery covers both `openmw51/mods` and valid non-base mod roots already referenced by `openmw.cfg`; the root containing `Morrowind.esm` is never exposed as a toggleable mod.
- Natural numeric ordering for newly discovered layered roots such as `00 Core`, `01 Textures`, and similar packages.
- TES3 `MAST` parsing for `.esm`, `.esp`, `.omwgame` and `.omwaddon` files. Enabled plugins are topologically sorted so every available master precedes its dependent. Duplicate names, missing masters, malformed TES3 headers and dependency cycles refuse configuration application.
- Transactional managed block in `openmw.cfg`. Existing non-mod/base entries remain intact; migrated mod `data=` and `content=` entries are replaced by one manager-owned block. The exact pre-write config is backed up and restored automatically if verification fails.
- A navmesh profile fingerprint derived from enabled plugins and collision-bearing mod roots. Base-only profiles accept the prebuilt database. A changed collision/plugin profile becomes **STALE** until the integrated builder finishes successfully.
- One-command diagnostic collection and manager-only installer rollback/uninstall.

## Controls

| Control | Action |
|---|---|
| D-pad | Navigate |
| A | Select or toggle a mod root |
| B | Back |
| Left/Right | Move a mod root earlier/later in asset override order |
| Start or X/North | Validate/apply on the Mods page |
| West button | Refresh/rescan |
| Menu/Guide | Exit manager |

## Installation

The downloadable package expands to one `openmw51-tsp-manager-v2` directory containing:

- `build_install_openmw51_tsp_manager_v2.sh`
- `openmw51_launcher_manager_v2.cpp`
- `openmw51_launcher_backend_v2.py`
- `openmw51_manager_action_v2.sh`
- `OpenMW_51_Manager_v2.sh`
- `OPENMW51_TSP_MANAGER_V2_README.md`

Run:

```bash
cd ~/Downloads
tar -xzf ./openmw51-tsp-manager-v2-package.tar.gz
cd ./openmw51-tsp-manager-v2
chmod +x ./build_install_openmw51_tsp_manager_v2.sh
./build_install_openmw51_tsp_manager_v2.sh
```

The installer builds an ARM64 binary in `openmw_builder`, copies it back to Ubuntu, verifies architecture and hashes, installs only the separate manager files, executes both behavior self-tests on the device, and performs the initial read-only scan. It does not install the navmesh, create swap, or edit `openmw.cfg`; those require explicit confirmation in the manager UI.

## Diagnostics and recovery

```bash
cd ~/Downloads/openmw51-tsp-manager-v2
./build_install_openmw51_tsp_manager_v2.sh collect
```

This collects manager status, selected mod order, default-navmesh candidates, swap state, UDisk state, navmesh profile, generator tail, manager tail and current `openmw.cfg`.

Rollback only the manager installation:

```bash
./build_install_openmw51_tsp_manager_v2.sh rollback
```

Remove only Manager V2:

```bash
./build_install_openmw51_tsp_manager_v2.sh uninstall
```

Neither operation deletes the canonical navmesh, swapfile, mods, saves, game launcher or game data.

## General load-order boundary

Dependency order can be proven automatically; arbitrary conflict preference cannot. The manager therefore uses two mechanisms: automatic master-before-dependent plugin sorting, and player-controlled data-root order for asset/plugin conflicts where there is no universal correct answer. This avoids pretending alphabetical order is equivalent to a correct mod order.
