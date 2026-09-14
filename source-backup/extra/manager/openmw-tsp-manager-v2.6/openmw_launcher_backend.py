#!/usr/bin/env python3
"""OpenMW 0.51 TSP manager backend: discovery, dependency sorting and status.

V2.5 changes:
  - the status scan publishes progress phases, so a slow scan is legible in the
    manager instead of being an unexplained wait;
  - default-navmesh discovery stops at the fixed defaults/base-navmesh.db
    instead of walking the whole ports tree (game data, mods, texture cache) on
    a slow card every single scan;
  - the expensive optimized-mod-profile validation is opt-in, because
    first-launch setup no longer depends on it.

V2.6 changes:
  - data roots are recorded with their canonical /mnt/SDCARD spelling instead
    of the resolved mount alias, so a written openmw.cfg is portable;
  - every OpenMW config is read for data=/content=, and the managed block is
    written into the config that already declares Morrowind.esm: mod content=
    lines in a config that loads BEFORE the base game make every master
    missing;
  - the plan records whether each root is actually present in a config, so the
    manager can show enabled-but-not-applied instead of a bare ON;
  - the TSP Atlas audit checks layout - are the NIFs under meshes/ - and
    reports the observed size instead of asserting a hard-coded byte total.
"""

import hashlib
import json
import os
import re
import shutil
import struct
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(os.environ.get("OPENMW_GAMEDIR", os.environ.get("OPENMW51_GAMEDIR", "/mnt/SDCARD/data/ports/openmw")))
LAUNCHER = ROOT / "launcher"
MODROOT = ROOT / "mods"
DEFAULTS = ROOT / "defaults"
CFG = ROOT / "openmw.cfg"
PLAN_JSON = LAUNCHER / "modplan.json"
PLAN_TSV = LAUNCHER / "modplan.tsv"
STATUS = LAUNCHER / "status.conf"
RESULT = LAUNCHER / "last-result.txt"
NAVDIR = Path(os.environ.get("OPENMW_NAVMESH_DIR", os.environ.get("OPENMW51_NAVMESH_DIR", "/mnt/UDISK/openmw-nav")))
NAVDB = NAVDIR / "navmesh.db"
NAVPROFILE = NAVDIR / "profile.sha256"
SWAP = Path("/mnt/UDISK/openmw-swapfile")
DEFAULT_SWAP = DEFAULTS / "base-swapfile"
PROGRESS_FILE = Path(os.environ.get("OPENMW_MANAGER_PROGRESS", "/tmp/openmw-manager-progress"))
GENERATOR_CANDIDATES = (
    Path("/mnt/SDCARD/Roms/PORTS/OpenMW_Generate_Full_Navmesh_3Worker.sh"),
    Path("/mnt/sdcard/mmcblk1p1/Roms/PORTS/OpenMW_Generate_Full_Navmesh_3Worker.sh"),
)
BASE_PLUGINS = {"morrowind.esm", "tribunal.esm", "bloodmoon.esm", "builtin.omwscripts"}
PLUGIN_EXTS = {".esm", ".esp", ".omwaddon", ".omwgame"}
DATA_DIRS = {"meshes", "textures", "icons", "sound", "music", "bookart", "fonts", "video", "shaders", "scripts", "groundcover"}
DEFAULT_MOD_PROFILE = (
    ("mop-core", "Morrowind Optimization Patch / 00 Core", "Morrowind Optimization Patch/00 Core"),
    ("project-atlas-core", "Project Atlas / 00 Core", "Project Atlas/00 Core"),
    ("project-atlas-textures-vanilla", "Project Atlas / 01 Textures - Vanilla", "Project Atlas/01 Textures - Vanilla"),
    ("tsp-atlas-global-v02", "TSP Atlas Global V02", "TSPAtlasGlobalV02"),
)
TSP_ATLAS_TEXTURES = (
    "atlad_6th.dds",
    "atlad_colony_wood.dds",
    "atlad_shack.dds",
    "atlad_wood_docks.dds",
    "atlas_de_furniture.dds",
    "atlas_velothi_01.dds",
    "atlas_woodpoles.dds",
    "tx_hlaalu_atlas.dds",
    "tx_parasol_atlas.dds",
)
TSP_ATLAS_NIF_COUNT = 63
TSP_ATLAS_NIF_BYTES = 12320768
TSP_ATLAS_DESCRIPTOR_NAME = "openmw-tsp-mod.json"


def atomic_text(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".tmp")
    with tmp.open("w", encoding="utf-8", newline="\n") as out:
        out.write(text)
        out.flush()
        os.fsync(out.fileno())
    os.replace(tmp, path)


def progress(phase: str, pct: int = -1, detail: str = "") -> None:
    """Publish one manager progress frame. Best effort; never fails a command."""
    step = steps = "0"
    try:
        for line in PROGRESS_FILE.read_text(encoding="utf-8", errors="replace").splitlines():
            if line.startswith("step="):
                step = line[5:]
            elif line.startswith("steps="):
                steps = line[6:]
    except OSError:
        pass
    try:
        tmp = PROGRESS_FILE.with_name(PROGRESS_FILE.name + ".tmp")
        tmp.write_text(
            f"phase={phase}\npct={pct}\ndetail={detail}\nstep={step}\nsteps={steps}\n",
            encoding="utf-8",
        )
        os.replace(tmp, PROGRESS_FILE)
    except OSError:
        pass


def result(message: str) -> None:
    clean = " ".join(message.replace("=", ":").split())[:150]
    atomic_text(RESULT, clean + "\n")
    print(clean)


def human_bytes(count: int) -> str:
    value = float(count)
    for unit in ("B", "KB", "MB"):
        if value < 1024:
            return f"{int(value)} B" if unit == "B" else f"{value:.1f} {unit}"
        value /= 1024
    return f"{value:.1f} GB"


def natural(value: str):
    return [int(x) if x.isdigit() else x.casefold() for x in re.split(r"(\d+)", value)]


def unquote(value: str) -> str:
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] == '"':
        value = value[1:-1].replace(r'\"', '"').replace(r"\\", "\\")
    return value


def cfg_entries(lines):
    data, content = [], []
    for line in lines:
        s = line.strip()
        if s.startswith("data="):
            data.append(unquote(s[5:]))
        elif s.startswith("content="):
            content.append(unquote(s[8:]))
    return data, content


def config_files():
    """OpenMW reads several configs in order. data= may live in any of them,
    but a mod content= line has to sit beside the base game content list.
    Computed, not frozen, so the selftest can relocate ROOT."""
    return (CFG, ROOT / "config" / "openmw.cfg", ROOT / "config" / "openmw" / "openmw.cfg")


def existing_configs():
    return [path for path in config_files() if path.is_file()]


def read_config(path: Path):
    try:
        return path.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        return []


def all_cfg_entries():
    """data= and content= across every config OpenMW will read."""
    data, content = [], []
    for path in existing_configs():
        one_data, one_content = cfg_entries(read_config(path))
        data.extend(one_data)
        content.extend(one_content)
    return data, content


def managed_config() -> Path:
    """Where the managed block belongs: beside the base game content list. A
    mod content= line in a config that loads before Morrowind.esm makes every
    master missing, so the block follows the base game, not the other way."""
    for path in existing_configs():
        _data, content = cfg_entries(read_config(path))
        if any(name.casefold() == "morrowind.esm" for name in content):
            return path
    return CFG


def canonical_root(path: Path) -> Path:
    """Prefer the /mnt/SDCARD spelling over the resolved mount alias, so a
    written openmw.cfg does not hard-code this device's mount point."""
    try:
        resolved = path.resolve()
    except OSError:
        return path
    try:
        return MODROOT / resolved.relative_to(MODROOT.resolve())
    except (ValueError, OSError):
        return resolved


def cfg_path(value: str) -> Path:
    path = Path(value).expanduser()
    if not path.is_absolute():
        path = CFG.parent / path
    return path.resolve()


def read_plan():
    try:
        raw = json.loads(PLAN_JSON.read_text(encoding="utf-8"))
        if isinstance(raw, list):
            return raw
    except (OSError, ValueError, TypeError):
        pass
    return []


def is_data_root(path: Path) -> bool:
    try:
        for child in path.iterdir():
            if child.is_file() and child.suffix.casefold() in PLUGIN_EXTS:
                return True
            if child.is_dir() and child.name.casefold() in DATA_DIRS:
                return True
    except OSError:
        return False
    return False


def plugin_files(path: Path):
    try:
        return sorted((p for p in path.iterdir() if p.is_file() and p.suffix.casefold() in PLUGIN_EXTS), key=lambda p: natural(p.name))
    except OSError:
        return []


def collision_sensitive(path: Path) -> bool:
    if plugin_files(path):
        return True
    try:
        names = {p.name.casefold() for p in path.iterdir() if p.is_dir()}
    except OSError:
        return False
    return bool(names & {"meshes", "groundcover", "navmesh", "navmeshes"})


def is_base_runtime_root(path: Path) -> bool:
    """Keep engine resources and the base game root out of the mod toggle list."""
    try:
        resolved = path.resolve()
        root = ROOT.resolve()
        if resolved in {(root / "resources" / "vfs").resolve(), (root / "resources" / "vfs-mw").resolve()}:
            return True
        if (root / "resources").resolve() in resolved.parents:
            return True
        return any(plugin.name.casefold() == "morrowind.esm" for plugin in plugin_files(resolved))
    except OSError:
        return False


def discover_mods():
    old = read_plan()
    old_by_path = {str(cfg_path(x.get("path", ""))): x for x in old if x.get("path")}
    old_order = {str(cfg_path(x.get("path", ""))): i for i, x in enumerate(old) if x.get("path")}
    cfg_data, _ = all_cfg_entries()
    configured = [cfg_path(x) for x in cfg_data]
    cfg_paths = {str(x) for x in configured}
    cfg_order = {str(x): i for i, x in enumerate(configured)}
    roots = []
    if MODROOT.is_dir():
        for current, dirs, _files in os.walk(MODROOT):
            rel = Path(current).relative_to(MODROOT)
            if len(rel.parts) > 5:
                dirs[:] = []
                continue
            p = Path(current)
            if is_data_root(p):
                roots.append(p.resolve())
                dirs[:] = []
    # Also manage non-base data roots already active in openmw.cfg. This covers
    # mod layouts outside ROOT/mods without accidentally treating Data Files as
    # a toggleable mod.
    for path in configured:
        if not is_data_root(path) or is_base_runtime_root(path):
            continue
        roots.append(path)
    current_default_paths = [str((MODROOT / relative).resolve()) for _ident, _name, relative in DEFAULT_MOD_PROFILE]
    current_default_set = set(current_default_paths)
    default_order = {path: i for i, path in enumerate(current_default_paths)}
    def root_priority(path: Path):
        try:
            label = str(path.relative_to(MODROOT.resolve()))
        except ValueError:
            label = str(path)
        return old_order.get(str(path), 10**6), cfg_order.get(str(path), 10**6), default_order.get(str(path), 10**6), natural(label)
    roots = sorted(set(roots), key=root_priority)
    plan = []
    for p in roots:
        key = str(p)
        prior = old_by_path.get(key, {})
        if prior:
            enabled = bool(prior.get("enabled", False))
        else:
            enabled = key in cfg_paths or key in current_default_set
        canon = canonical_root(p)
        ident = hashlib.sha1(str(canon).encode("utf-8")).hexdigest()[:12]
        try:
            name = str(p.relative_to(MODROOT.resolve()))
        except ValueError:
            name = p.name + " (configured)"
        plan.append({
            "id": ident,
            "name": name,
            "path": str(canon),
            "enabled": enabled,
            "needs_navmesh": collision_sensitive(p),
            # Present in a config right now? Without this the manager cannot
            # tell "switched on" from "switched on and written to openmw.cfg",
            # which looks exactly like a mod manager that does nothing.
            "applied": key in cfg_paths,
        })
    save_plan(plan)
    return plan


def default_mod_roots():
    roots = []
    errors = []
    for ident, name, relative in DEFAULT_MOD_PROFILE:
        path = (MODROOT / relative).resolve()
        if not path.is_dir():
            errors.append(f"missing {name}: {path}")
        elif not is_data_root(path):
            errors.append(f"not an OpenMW data root: {path}")
        else:
            roots.append((ident, name, path))
    if errors:
        raise RuntimeError("default mod profile incomplete; " + "; ".join(errors))
    return roots


def atlas_descriptor(nif_count=TSP_ATLAS_NIF_COUNT, nif_bytes=TSP_ATLAS_NIF_BYTES):
    return {
        "schema": "openmw-tsp-data-mod-v1",
        "id": "tsp-atlas-global-v02",
        "name": "TSP Atlas Global V02",
        "version": "2",
        "type": "data-only-mesh-replacements",
        "data_root": ".",
        "load_after": ["mop-core", "project-atlas-core", "project-atlas-textures-vanilla"],
        "requires": ["project-atlas-core", "project-atlas-textures-vanilla"],
        "content_plugins": [],
        "installed_assets": {"nif_count": nif_count, "nif_bytes": nif_bytes},
        "captured_assets": {"nif_count": TSP_ATLAS_NIF_COUNT, "nif_bytes": TSP_ATLAS_NIF_BYTES},
        "required_project_atlas_textures": list(TSP_ATLAS_TEXTURES),
        "validation": {
            "candidate_meshes_audited": 414,
            "visible_draw_shapes_removed": 99,
            "placement_weighted_draw_shapes_removed": 3907,
            "visible_triangles_preserved": 89160,
            "collision_geometry": "preserved-and-validated",
        },
    }


def validate_default_mod_profile():
    roots = default_mod_roots()
    by_id = {ident: path for ident, _name, path in roots}
    atlas_root = by_id["tsp-atlas-global-v02"]
    # V2.6: layout is what decides whether a data-only mesh mod works. The
    # recorded capture totals are reported, never asserted: the installed files
    # are allowed to differ from the August capture.
    nifs, nif_bytes, misplaced = atlas_layout_report(atlas_root)
    if plugin_files(atlas_root):
        raise RuntimeError("TSPAtlasGlobalV02 must be data-only; it contains a content plugin")
    if not nifs:
        raise RuntimeError("TSPAtlasGlobalV02 contains no NIF replacements")
    if misplaced:
        raise RuntimeError(
            f"TSPAtlasGlobalV02 layout: {len(misplaced)} of {len(nifs)} NIFs are not under meshes/ "
            f"(e.g. {misplaced[0].relative_to(atlas_root)})"
        )
    texture_roots = (
        by_id["project-atlas-textures-vanilla"],
        by_id["project-atlas-core"],
        ROOT / "data" / "Data Files",
        ROOT / "data",
    )
    missing_textures = []
    for filename in TSP_ATLAS_TEXTURES:
        found = False
        for base in texture_roots:
            for directory in ("Textures/atl", "textures/atl"):
                if (base / directory / filename).is_file():
                    found = True
                    break
            if found:
                break
        if not found:
            missing_textures.append(filename)
    if missing_textures:
        raise RuntimeError("TSPAtlasGlobalV02 missing Project Atlas textures: " + ", ".join(missing_textures))
    return roots, len(nifs), nif_bytes


def install_atlas_descriptor(atlas_root: Path, nif_count=TSP_ATLAS_NIF_COUNT, nif_bytes=TSP_ATLAS_NIF_BYTES) -> None:
    target = atlas_root / TSP_ATLAS_DESCRIPTOR_NAME
    text = json.dumps(atlas_descriptor(nif_count, nif_bytes), indent=2, sort_keys=True) + "\n"
    try:
        if target.read_text(encoding="utf-8") == text:
            return
    except OSError:
        pass
    if target.exists():
        backup_dir = LAUNCHER / "backups"
        backup_dir.mkdir(parents=True, exist_ok=True)
        stamp = time.strftime("%Y%m%d-%H%M%S") + f"-{time.time_ns() % 1_000_000_000:09d}"
        shutil.copy2(target, backup_dir / f"{TSP_ATLAS_DESCRIPTOR_NAME}.before-manager-{stamp}")
    atomic_text(target, text)
    if json.loads(target.read_text(encoding="utf-8")) != atlas_descriptor(nif_count, nif_bytes):
        raise RuntimeError("TSP Atlas data-mod manifest verification failed")


def apply_default_mod_profile():
    roots, nif_count, nif_bytes = validate_default_mod_profile()
    install_atlas_descriptor(
        dict((ident, path) for ident, _name, path in roots)["tsp-atlas-global-v02"],
        nif_count,
        nif_bytes,
    )
    plan = discover_mods()
    plan_by_path = {str(Path(item["path"]).resolve()): item for item in plan}
    missing = [name for _ident, name, path in roots if str(path) not in plan_by_path]
    if missing:
        raise RuntimeError("default roots were not discovered: " + ", ".join(missing))
    default_paths = {str(path) for _ident, _name, path in roots}
    other = [item for item in plan if str(Path(item["path"]).resolve()) not in default_paths]
    selected = []
    for _ident, _name, path in roots:
        item = plan_by_path[str(path)]
        item["enabled"] = True
        selected.append(item)
    save_plan(other + selected)
    apply_mods()
    text = managed_config().read_text(encoding="utf-8", errors="strict")
    positions = []
    for _ident, _name, path in roots:
        canon = canonical_root(path)
        position = -1
        for candidate in (canon, path):
            position = max(position, text.rfind(f'data="{candidate}"'), text.rfind(f"data={candidate}"))
        if position < 0:
            raise RuntimeError(f"default mod missing after apply: {path}")
        positions.append(position)
    if positions != sorted(positions) or len(set(positions)) != len(positions):
        raise RuntimeError("default mod override order verification failed")
    result("Default mods applied: MOP, Project Atlas Core/Vanilla Textures, TSP Atlas Global V02")


def save_plan(plan) -> None:
    atomic_text(PLAN_JSON, json.dumps(plan, indent=2, sort_keys=True) + "\n")
    rows = ["# id\tenabled\tneeds_navmesh\tname\tpath\tapplied"]
    for item in plan:
        clean_name = str(item["name"]).replace("\t", " ").replace("\n", " ")
        clean_path = str(item["path"]).replace("\t", " ").replace("\n", " ")
        rows.append("\t".join((
            item["id"],
            "1" if item["enabled"] else "0",
            "1" if item["needs_navmesh"] else "0",
            clean_name,
            clean_path,
            "1" if item.get("applied") else "0",
        )))
    atomic_text(PLAN_TSV, "\n".join(rows) + "\n")


def read_masters(path: Path):
    with path.open("rb") as src:
        header = src.read(16)
        if len(header) != 16 or header[:4] != b"TES3":
            raise ValueError(f"not a TES3 plugin: {path.name}")
        size = struct.unpack_from("<I", header, 4)[0]
        payload = src.read(size)
    masters, pos = [], 0
    while pos + 8 <= len(payload):
        tag = payload[pos:pos + 4]
        length = struct.unpack_from("<I", payload, pos + 4)[0]
        pos += 8
        if length > len(payload) - pos:
            raise ValueError(f"bad TES3 subrecord size: {path.name}")
        value = payload[pos:pos + length]
        pos += length
        if tag == b"MAST":
            masters.append(value.split(b"\0", 1)[0].decode("cp1252", errors="replace"))
    return masters


def selected_plugins(plan):
    found = []
    for item in plan:
        if item["enabled"]:
            for path in plugin_files(Path(item["path"])):
                found.append(path)
    return found


def sort_plugins(paths, external_content):
    by_name = {}
    for path in paths:
        key = path.name.casefold()
        if key in by_name and by_name[key] != path:
            raise ValueError(f"duplicate plugin filename: {path.name}")
        by_name[key] = path
    external = {x.casefold() for x in external_content}
    dependencies = {}
    for key, path in by_name.items():
        deps = []
        for master in read_masters(path):
            m = master.casefold()
            if m in by_name:
                deps.append(m)
            elif m not in external and m not in BASE_PLUGINS:
                raise ValueError(f"{path.name} missing master {master}")
        dependencies[key] = set(deps)
    order_hint = {name.casefold(): i for i, name in enumerate(external_content)}
    def priority(key):
        suffix = by_name[key].suffix.casefold()
        kind = 0 if suffix in {".esm", ".omwgame"} else 1
        return (kind, order_hint.get(key, 10**6), natural(by_name[key].name))
    ready = sorted((k for k, deps in dependencies.items() if not deps), key=priority)
    output = []
    while ready:
        key = ready.pop(0)
        output.append(by_name[key])
        for other in dependencies:
            if key in dependencies[other]:
                dependencies[other].remove(key)
                if not dependencies[other] and other not in {p.name.casefold() for p in output} and other not in ready:
                    ready.append(other)
                    ready.sort(key=priority)
    if len(output) != len(by_name):
        cycle = ", ".join(by_name[k].name for k, deps in dependencies.items() if deps)
        raise ValueError("plugin dependency cycle: " + cycle)
    return output


def profile_hash(plan):
    active = [x for x in plan if x["enabled"] and x["needs_navmesh"]]
    if not active:
        return "BASE_GAME_ONLY", "BASE ONLY"
    h = hashlib.sha256()
    for item in active:
        root = Path(item["path"])
        h.update((str(root) + "\0").encode("utf-8"))
        for current, dirs, files in os.walk(root):
            rel_current = Path(current).relative_to(root)
            if rel_current.parts and rel_current.parts[0].casefold() not in {"meshes", "groundcover", "navmesh", "navmeshes"}:
                dirs[:] = []
                files = [x for x in files if Path(x).suffix.casefold() in PLUGIN_EXTS]
            dirs.sort(key=natural)
            for name in sorted(files, key=natural):
                path = Path(current) / name
                if path.suffix.casefold() not in PLUGIN_EXTS and (not rel_current.parts or rel_current.parts[0].casefold() not in {"meshes", "groundcover", "navmesh", "navmeshes"}):
                    continue
                try:
                    st = path.stat()
                except OSError:
                    continue
                h.update((str(path.relative_to(root)) + f"\0{st.st_size}\0{st.st_mtime_ns}\n").encode("utf-8"))
    return h.hexdigest(), "MODDED"


def plugin_health(plan):
    try:
        _, existing = all_cfg_entries()
        all_mod_names = {p.name.casefold() for item in plan for p in plugin_files(Path(item["path"]))}
        external = [x for x in existing if x.casefold() not in all_mod_names]
        sort_plugins(selected_plugins(plan), external)
        return "VALID"
    except (OSError, ValueError) as exc:
        return "ERROR: " + str(exc)


def apply_mods():
    """Write the managed data/content block, and make every config agree.

    The block goes into the config that already declares the base game, and
    every other config is stripped of managed entries, so a root can never be
    half-applied across the config chain.
    """
    plan = discover_mods()
    target = managed_config()
    all_mod_plugins = {p.name.casefold() for item in plan for p in plugin_files(Path(item["path"]))}
    _all_data, all_content = all_cfg_entries()
    external_content = [x for x in all_content if x.casefold() not in all_mod_plugins]
    sorted_plugins = sort_plugins(selected_plugins(plan), external_content)
    managed_roots = {str(cfg_path(x["path"])) for x in plan}

    def strip(lines):
        out, inside = [], False
        for line in lines:
            s = line.strip()
            if s == "# TSP_MANAGER_V2_BEGIN":
                inside = True
                continue
            if s == "# TSP_MANAGER_V2_END":
                inside = False
                continue
            if inside:
                continue
            if s.startswith("data="):
                try:
                    if str(cfg_path(unquote(s[5:]))) in managed_roots:
                        continue
                except OSError:
                    pass
            if s.startswith("content=") and unquote(s[8:]).casefold() in all_mod_plugins:
                continue
            out.append(line)
        return out

    block = ["", "# TSP_MANAGER_V2_BEGIN", "# Managed data order; edit through the OpenMW Manager."]
    for item in plan:
        if item["enabled"]:
            escaped = str(item["path"]).replace("\\", "\\\\").replace('"', r'\"')
            block.append(f'data="{escaped}"')
    for path in sorted_plugins:
        block.append("content=" + path.name)
    block.append("# TSP_MANAGER_V2_END")

    backup_dir = LAUNCHER / "backups"
    backup_dir.mkdir(parents=True, exist_ok=True)
    stamp = time.strftime("%Y%m%d-%H%M%S") + f"-{time.time_ns() % 1_000_000_000:09d}"
    written = []
    try:
        for cfg in existing_configs():
            current = cfg.read_text(encoding="utf-8", errors="replace")
            new_text = "\n".join(strip(current.splitlines()) + (block if cfg == target else [])).rstrip() + "\n"
            if new_text == current:
                continue
            try:
                tag = str(cfg.relative_to(ROOT)).replace(os.sep, "_")
            except ValueError:
                tag = cfg.name
            backup = backup_dir / f"{tag}.before-manager-{stamp}"
            shutil.copy2(cfg, backup)
            atomic_text(cfg, new_text)
            written.append((cfg, backup))

        check = target.read_text(encoding="utf-8", errors="strict")
        if check.count("# TSP_MANAGER_V2_BEGIN") != 1 or check.count("# TSP_MANAGER_V2_END") != 1:
            raise RuntimeError("post-write marker verification failed")
        check_lines = check.splitlines()
        begin = check_lines.index("# TSP_MANAGER_V2_BEGIN")
        end = check_lines.index("# TSP_MANAGER_V2_END")
        managed_data, managed_content = cfg_entries(check_lines[begin + 1:end])
        expected_data = [str(x["path"]) for x in plan if x["enabled"]]
        expected_content = [path.name for path in sorted_plugins]
        if managed_data != expected_data or managed_content != expected_content:
            raise RuntimeError("post-write managed load-order verification failed")
        for cfg in existing_configs():
            if cfg == target:
                continue
            other_data, other_content = cfg_entries(read_config(cfg))
            if any(str(cfg_path(x)) in managed_roots for x in other_data):
                raise RuntimeError(f"a managed data root survived in {cfg}")
            if any(x.casefold() in all_mod_plugins for x in other_content):
                raise RuntimeError(f"a managed content plugin survived in {cfg}")
    except Exception:
        for cfg, backup in written:
            shutil.copy2(backup, cfg)
        raise

    for old in sorted(backup_dir.glob("*.before-manager-*"), key=lambda x: x.stat().st_mtime, reverse=True)[30:]:
        old.unlink(missing_ok=True)
    result(
        f"Applied {sum(1 for x in plan if x['enabled'])} mod roots and "
        f"{len(sorted_plugins)} dependency-sorted plugins to {target.name} ({target})"
    )


def toggle_mod(ident: str):
    plan = discover_mods()
    for item in plan:
        if item["id"] == ident:
            item["enabled"] = not item["enabled"]
            save_plan(plan)
            result(("Enabled " if item["enabled"] else "Disabled ") + item["name"] + " (not applied yet)")
            return
    raise ValueError("unknown mod id")


def move_mod(ident: str, delta: int):
    plan = discover_mods()
    index = next((i for i, x in enumerate(plan) if x["id"] == ident), -1)
    if index < 0:
        raise ValueError("unknown mod id")
    target = max(0, min(len(plan) - 1, index + delta))
    item = plan.pop(index)
    plan.insert(target, item)
    save_plan(plan)
    result(f"Moved {item['name']} to position {target + 1} (not applied yet)")


def generator_path():
    for path in GENERATOR_CANDIDATES:
        if path.is_file() and os.access(path, os.X_OK):
            return path
    return None


def mount_info(target="/mnt/UDISK"):
    try:
        for line in Path("/proc/mounts").read_text().splitlines():
            fields = line.split()
            if len(fields) >= 3 and fields[1] == target:
                return fields[2]
    except OSError:
        pass
    return ""


def sqlite_navmesh(path: Path):
    try:
        return path.stat().st_size > 1024 * 1024 and path.open("rb").read(16) == b"SQLite format 3\0"
    except OSError:
        return False


def default_navmesh_candidates(base=None):
    fixed = DEFAULTS / "base-navmesh.db"
    candidates = []
    if sqlite_navmesh(fixed) and fixed != NAVDB:
        candidates.append((2 * 10**6, fixed))
    override = LAUNCHER / "default-navmesh.path"
    if override.is_file():
        try:
            path = Path(override.read_text().strip())
            if sqlite_navmesh(path) and path != NAVDB and path != fixed:
                candidates.append((10**6, path))
        except OSError:
            pass
    # The fixed default outranks anything the deep scan can produce, and that
    # scan walks the entire ports tree - game data, every mod root and the
    # texture cache - on a slow card, on every status refresh. Stop here when
    # the fixed default is present. Touch launcher/deep-navmesh-scan to force
    # the old exhaustive search.
    if candidates and candidates[0][0] == 2 * 10**6 and not (LAUNCHER / "deep-navmesh-scan").exists():
        return candidates
    base = Path("/mnt/SDCARD/data/ports") if base is None else Path(base)
    if not base.is_dir():
        return candidates
    excluded = {"backups", "backup", "navmesh-tool-runtime", ".tsp-051-source-backups"}
    provenance = ("default", "prebuilt", "vanilla", "base", "stock", "assets", "install")
    for current, dirs, files in os.walk(base):
        dirs[:] = [d for d in dirs if d.casefold() not in excluded and not d.casefold().startswith("savegame")]
        p = Path(current)
        if len(p.relative_to(base).parts) > 7:
            dirs[:] = []
            continue
        for name in files:
            low = name.casefold()
            if not (low == "navmesh.db" or ("navmesh" in low and low.endswith(".db"))):
                continue
            path = p / name
            if path.resolve() == NAVDB.resolve() or not sqlite_navmesh(path):
                continue
            words = str(path).casefold()
            evidence = sum(1 for token in provenance if token in words)
            if evidence == 0:
                continue
            score = 10 if low == "navmesh.db" else 20
            for token in provenance:
                if token in words:
                    score += 10
            if path != fixed and all(path != existing for _score, existing in candidates):
                candidates.append((score, path))
    return sorted(candidates, key=lambda x: (-x[0], natural(str(x[1]))))


def choose_default_navmesh():
    candidates = default_navmesh_candidates()
    report = LAUNCHER / "default-navmesh-candidates.txt"
    atomic_text(report, "\n".join(f"score={score}\t{path}" for score, path in candidates) + ("\n" if candidates else "NO VALID SQLITE NAVMESH CANDIDATES\n"))
    if not candidates:
        return None, "NOT FOUND"
    top = candidates[0][0]
    ties = [path for score, path in candidates if score == top]
    if len(ties) != 1:
        return None, f"AMBIGUOUS ({len(ties)})"
    return ties[0], str(ties[0])


def swap_active():
    try:
        return any(line.split()[0] == str(SWAP) for line in Path("/proc/swaps").read_text().splitlines()[1:] if line.split())
    except OSError:
        return False


def game_found():
    candidates = [ROOT / "Data Files/Morrowind.esm", ROOT / "data/Data Files/Morrowind.esm", ROOT / "data/Morrowind.esm"]
    data, _ = all_cfg_entries()
    candidates.extend(Path(x) / "Morrowind.esm" for x in data)
    return any(path.is_file() for path in candidates)


def atlas_layout_report(root: Path):
    """A data-only NIF replacement mod only works when its meshes sit under
    <root>/meshes. Anything else is a repackaging mistake that silently does
    nothing in game."""
    nifs, misplaced, total = [], [], 0
    for path in root.rglob("*"):
        if not path.is_file() or path.suffix.casefold() != ".nif":
            continue
        nifs.append(path)
        try:
            total += path.stat().st_size
        except OSError:
            pass
        parts = path.relative_to(root).parts
        if not parts or parts[0].casefold() != "meshes":
            misplaced.append(path)
    return nifs, total, misplaced


def default_mod_profile_health():
    # First-launch setup installs storage only, so this content audit is not on
    # any critical path. It rglobs a large mod root, so during a plain status
    # refresh it only runs when launcher/check-default-mods exists. The mod
    # rescan action always forces it.
    if not (LAUNCHER / "check-default-mods").exists():
        return "NOT CHECKED"
    return default_mod_profile_report()


def default_mod_profile_report():
    """Describe the optimized profile as it actually is on disk. Reports, never
    asserts a hard-coded byte total: the recorded capture and the installed
    files are allowed to differ, and saying so beats refusing to work."""
    try:
        roots = default_mod_roots()
    except (OSError, RuntimeError) as exc:
        return "MISSING: " + " ".join(str(exc).split())[:110]

    by_id = {ident: path for ident, _name, path in roots}
    atlas = by_id["tsp-atlas-global-v02"]
    nifs, total, misplaced = atlas_layout_report(atlas)

    plugins = plugin_files(atlas)
    if plugins:
        return "PLUGIN: data-only mod must have no content plugin (" + plugins[0].name + ")"
    if not nifs:
        return "EMPTY: no NIF replacements found in " + atlas.name
    if misplaced:
        example = str(misplaced[0].relative_to(atlas))
        return f"LAYOUT: {len(misplaced)} of {len(nifs)} NIFs are not under meshes/ (e.g. {example})"

    missing = []
    texture_roots = (
        by_id["project-atlas-textures-vanilla"],
        by_id["project-atlas-core"],
        ROOT / "data" / "Data Files",
        ROOT / "data",
    )
    for filename in TSP_ATLAS_TEXTURES:
        found = False
        for base in texture_roots:
            for directory in ("Textures/atl", "textures/atl"):
                if (base / directory / filename).is_file():
                    found = True
                    break
            if found:
                break
        if not found:
            missing.append(filename)
    if missing:
        return "TEXTURES: missing " + ", ".join(missing[:4])

    note = ""
    if len(nifs) != TSP_ATLAS_NIF_COUNT or total != TSP_ATLAS_NIF_BYTES:
        note = f" (capture recorded {TSP_ATLAS_NIF_COUNT} / {human_bytes(TSP_ATLAS_NIF_BYTES)})"
    return f"OK: {len(nifs)} NIFs / {human_bytes(total)} under meshes{note}"


def write_status():
    progress("SCANNING MOD DATA ROOTS", 15)
    plan = discover_mods()
    progress("HASHING MOD CONTENT", 40, f"{sum(1 for x in plan if x['enabled'])} enabled roots")
    profile, mod_kind = profile_hash(plan)
    progress("CHECKING THE BASE NAVMESH SOURCE", 62)
    source, source_label = choose_default_navmesh()
    fs_kind = mount_info()
    try:
        stat = os.statvfs("/mnt/UDISK")
        free = stat.f_bavail * stat.f_frsize
        udisk = 1
    except OSError:
        free, udisk = 0, 0
    nav = int(sqlite_navmesh(NAVDB))
    try:
        built_profile = NAVPROFILE.read_text().strip()
    except OSError:
        built_profile = ""
    if not nav:
        nav_state = "MISSING"
    elif built_profile == profile:
        nav_state = "BASE CURRENT" if profile == "BASE_GAME_ONLY" else "CURRENT"
    elif built_profile:
        nav_state = "STALE"
    else:
        nav_state = "UNKNOWN"
    progress("CHECKING PLUGIN ORDER", 80)
    gen = generator_path()
    default_mods = default_mod_profile_health()
    pending = [x for x in plan if x["enabled"] and not x.get("applied")]
    stale = [x for x in plan if not x["enabled"] and x.get("applied")]
    if pending or stale:
        sync = f"{len(pending)} TO ADD / {len(stale)} TO REMOVE"
    elif any(x["enabled"] for x in plan):
        sync = "IN SYNC"
    else:
        sync = "NO MODS ENABLED"
    values = {
        "game": int(game_found()), "udisk": udisk, "udisk_fs": fs_kind or "UNMOUNTED", "udisk_free": free,
        "navmesh": nav, "navmesh_size": NAVDB.stat().st_size if NAVDB.is_file() else 0, "navmesh_target": str(NAVDB),
        "navmesh_profile": nav_state, "profile_hash": profile, "mod_navmesh": mod_kind,
        "default_navmesh_ready": int(source is not None), "default_navmesh": source_label,
        "default_swap_ready": int(DEFAULT_SWAP.is_file() and DEFAULT_SWAP.stat().st_size >= 64 * 1024 * 1024),
        "default_swap": str(DEFAULT_SWAP) if DEFAULT_SWAP.is_file() else "CREATE 512 MB",
        "swap_file": int(SWAP.is_file()), "swap_active": int(swap_active()), "swap_size": SWAP.stat().st_size if SWAP.is_file() else 0, "swap_target": str(SWAP),
        "mods_total": len(plan), "mods_enabled": sum(1 for x in plan if x["enabled"]), "plugin_status": plugin_health(plan),
        "mods_pending": len(pending), "mods_stale": len(stale), "mods_sync": sync,
        "mods_applied": int(not pending and not stale), "mods_config": str(managed_config()),
        "default_mods_ready": int(default_mods == "READY"), "default_mods": default_mods,
        "config": str(CFG), "generator": int(gen is not None), "generator_path": str(gen) if gen else "NOT FOUND",
    }
    progress("WRITING DEVICE STATUS", 95)
    atomic_text(STATUS, "\n".join(f"{key}={value}" for key, value in values.items()) + "\n")
    return values


def mark_navmesh(default=False):
    plan = discover_mods()
    profile, _ = profile_hash(plan)
    NAVDIR.mkdir(parents=True, exist_ok=True)
    atomic_text(NAVPROFILE, ("BASE_GAME_ONLY" if default else profile) + "\n")
    result("Navmesh profile recorded as " + ("base game" if default else "current mod order"))


def fake_plugin(path: Path, masters):
    payload = b""
    for master in masters:
        value = master.encode("cp1252") + b"\0"
        payload += b"MAST" + struct.pack("<I", len(value)) + value
    path.write_bytes(b"TES3" + struct.pack("<III", len(payload), 0, 0) + payload)


def selftest():
    global ROOT, LAUNCHER, MODROOT, DEFAULTS, DEFAULT_SWAP, CFG, PLAN_JSON, PLAN_TSV, STATUS, RESULT, NAVDIR, NAVDB, NAVPROFILE, SWAP
    with tempfile.TemporaryDirectory() as tmp:
        ROOT = Path(tmp) / "openmw"; LAUNCHER = ROOT / "launcher"; MODROOT = ROOT / "mods"; DEFAULTS = ROOT / "defaults"; DEFAULT_SWAP = DEFAULTS / "base-swapfile"; CFG = ROOT / "openmw.cfg"
        PLAN_JSON = LAUNCHER / "modplan.json"; PLAN_TSV = LAUNCHER / "modplan.tsv"; STATUS = LAUNCHER / "status.conf"; RESULT = LAUNCHER / "last-result.txt"
        NAVDIR = Path(tmp) / "nav"; NAVDB = NAVDIR / "navmesh.db"; NAVPROFILE = NAVDIR / "profile.sha256"; SWAP = Path(tmp) / "swapfile"
        a = MODROOT / "10 Core"; b = MODROOT / "20 Patch"; external = Path(tmp) / "External Mod"
        vfs = ROOT / "resources" / "vfs"
        (a / "meshes").mkdir(parents=True); b.mkdir(parents=True); external.mkdir(); (vfs / "meshes").mkdir(parents=True)
        fake_plugin(a / "A.esm", ["Morrowind.esm"]); fake_plugin(b / "B.esp", ["A.esm"])
        fake_plugin(external / "External.esp", ["Morrowind.esm"])
        CFG.parent.mkdir(parents=True, exist_ok=True)
        CFG.write_text(f'data="{vfs}"\ndata="{a}"\ndata="{b}"\ndata="{external}"\ncontent=Morrowind.esm\ncontent=B.esp\ncontent=A.esm\ncontent=External.esp\n')
        plan = discover_mods(); assert len(plan) == 3 and all(x["enabled"] for x in plan)
        assert any(x["path"] == str(external.resolve()) for x in plan)
        assert all(x["path"] != str(vfs.resolve()) for x in plan)
        ordered = sort_plugins(selected_plugins(plan), ["Morrowind.esm"]); assert [x.name for x in ordered] == ["A.esm", "B.esp", "External.esp"]
        apply_mods(); text = CFG.read_text(); assert text.index("content=A.esm") < text.index("content=B.esp")
        missing = MODROOT / "30 Missing"; missing.mkdir(); fake_plugin(missing / "Missing.esp", ["Absent.esm"])
        try:
            sort_plugins([missing / "Missing.esp"], ["Morrowind.esm"])
            raise AssertionError("missing master was accepted")
        except ValueError as exc:
            assert "missing master" in str(exc)
        cycle = MODROOT / "40 Cycle"; cycle.mkdir()
        fake_plugin(cycle / "C.esm", ["D.esm"]); fake_plugin(cycle / "D.esm", ["C.esm"])
        try:
            sort_plugins([cycle / "C.esm", cycle / "D.esm"], ["Morrowind.esm"])
            raise AssertionError("dependency cycle was accepted")
        except ValueError as exc:
            assert "cycle" in str(exc)
        duplicate = MODROOT / "50 Duplicate"; duplicate.mkdir(); fake_plugin(duplicate / "A.esm", ["Morrowind.esm"])
        try:
            sort_plugins([a / "A.esm", duplicate / "A.esm"], ["Morrowind.esm"])
            raise AssertionError("duplicate filename was accepted")
        except ValueError as exc:
            assert "duplicate" in str(exc)
        ports = Path(tmp) / "ports"
        old_nav = ports / "openmw" / "savegame" / "navmesh.db"
        base_nav = DEFAULTS / "base-navmesh.db"
        for nav in (old_nav, base_nav):
            nav.parent.mkdir(parents=True, exist_ok=True)
            with nav.open("wb") as out:
                out.write(b"SQLite format 3\0"); out.seek(1024 * 1024 + 7); out.write(b"\0")
        candidates = default_navmesh_candidates(ports)
        assert [path for _score, path in candidates] == [base_nav]
        # Without the fixed default the exhaustive scan must still run and must
        # still refuse the retired savegame database.
        base_nav.rename(base_nav.with_name("base-navmesh.db.hidden"))
        assert default_navmesh_candidates(ports) == []
        (LAUNCHER / "deep-navmesh-scan").write_text("1")
        assert default_navmesh_candidates(ports) == []
        (LAUNCHER / "deep-navmesh-scan").unlink()
        base_nav.with_name("base-navmesh.db.hidden").rename(base_nav)
        assert [path for _score, path in default_navmesh_candidates(ports)] == [base_nav]
        toggle_mod(plan[0]["id"]); assert not read_plan()[0]["enabled"]
        toggle_mod(plan[0]["id"]); assert read_plan()[0]["enabled"]
        move_mod(plan[1]["id"], -1); assert read_plan()[0]["id"] == plan[1]["id"]

        # V2.6: the managed block must follow the base game content list, and
        # every other config must be left without managed entries.
        user_cfg = ROOT / "config" / "openmw.cfg"
        user_cfg.parent.mkdir(parents=True, exist_ok=True)
        user_cfg.write_text("fallback-archive=Morrowind.bsa\ncontent=Morrowind.esm\n", encoding="utf-8")
        CFG.write_text(f'data="{vfs}"\ndata="{a}"\ndata="{b}"\ndata="{external}"\n', encoding="utf-8")
        assert managed_config() == user_cfg
        apply_mods()
        user_text = user_cfg.read_text(encoding="utf-8")
        assert user_text.count("# TSP_MANAGER_V2_BEGIN") == 1
        assert user_text.index("content=Morrowind.esm") < user_text.index("content=A.esm")
        assert "# TSP_MANAGER_V2_BEGIN" not in CFG.read_text(encoding="utf-8")
        main_data, _main_content = cfg_entries(CFG.read_text(encoding="utf-8").splitlines())
        assert all(str(cfg_path(x)) != str(a.resolve()) for x in main_data)
        applied_plan = discover_mods()
        assert all(x["applied"] for x in applied_plan if x["enabled"])
        toggle_mod(applied_plan[0]["id"])
        pending_plan = read_plan()
        assert any(x["applied"] and not x["enabled"] for x in pending_plan)
        toggle_mod(applied_plan[0]["id"])

        # A root reached through a symlinked mount alias must still be recorded
        # with its canonical spelling.
        alias = Path(tmp) / "ALIAS"
        alias.symlink_to(ROOT)
        aliased = alias / "mods" / "10 Core"
        assert str(canonical_root(aliased)) == str(MODROOT / "10 Core")

        # Atlas layout audit: a NIF outside meshes/ is the repackaging mistake.
        layout_root = MODROOT / "LayoutProbe"
        (layout_root / "meshes").mkdir(parents=True)
        (layout_root / "meshes" / "good.nif").write_bytes(b"x" * 10)
        nifs, total, misplaced = atlas_layout_report(layout_root)
        assert len(nifs) == 1 and total == 10 and not misplaced
        (layout_root / "loose.nif").write_bytes(b"y" * 5)
        nifs, total, misplaced = atlas_layout_report(layout_root)
        assert len(nifs) == 2 and total == 15 and len(misplaced) == 1
        shutil.rmtree(layout_root)

        mop = MODROOT / "Morrowind Optimization Patch" / "00 Core"
        atlas_core = MODROOT / "Project Atlas" / "00 Core"
        atlas_textures = MODROOT / "Project Atlas" / "01 Textures - Vanilla"
        tsp_atlas = MODROOT / "TSPAtlasGlobalV02"
        for data_root in (mop, atlas_core, tsp_atlas):
            (data_root / "meshes").mkdir(parents=True)
        (mop / "meshes" / "mop.nif").write_bytes(b"mop")
        (atlas_core / "meshes" / "atlas.nif").write_bytes(b"atlas")
        texture_dir = atlas_textures / "Textures" / "atl"
        texture_dir.mkdir(parents=True)
        for texture in TSP_ATLAS_TEXTURES:
            (texture_dir / texture).write_bytes(b"dds")
        remaining = TSP_ATLAS_NIF_BYTES
        for index in range(TSP_ATLAS_NIF_COUNT):
            size = 1 if index + 1 < TSP_ATLAS_NIF_COUNT else remaining
            with (tsp_atlas / "meshes" / f"fixture-{index:02d}.nif").open("wb") as out:
                out.truncate(size)
            remaining -= size
        assert remaining == 0
        assert default_mod_profile_health() == "NOT CHECKED"
        (LAUNCHER / "check-default-mods").write_text("1")
        report = default_mod_profile_health()
        assert report.startswith("OK: 63 NIFs"), report
        assert "capture recorded" not in report, report
        # A size that differs from the recorded capture is reported, not refused.
        drifted = sorted(tsp_atlas.rglob("*.nif"))[0]
        drifted.write_bytes(drifted.read_bytes() + b"\0")
        drift_report = default_mod_profile_report()
        assert drift_report.startswith("OK: 63 NIFs"), drift_report
        assert "capture recorded" in drift_report, drift_report
        stray = tsp_atlas / "stray.nif"
        stray.write_bytes(b"z")
        assert default_mod_profile_report().startswith("LAYOUT: 1 of 64"), default_mod_profile_report()
        stray.unlink()
        (LAUNCHER / "check-default-mods").unlink()
        PLAN_JSON.unlink(missing_ok=True); PLAN_TSV.unlink(missing_ok=True)
        fresh_plan = discover_mods()
        fresh_by_path = {str(Path(item["path"]).resolve()): item for item in fresh_plan}
        for _ident, _name, relative in DEFAULT_MOD_PROFILE:
            assert fresh_by_path[str((MODROOT / relative).resolve())]["enabled"]
        apply_default_mod_profile()
        managed = managed_config().read_text(encoding="utf-8")
        expected_roots = [str(MODROOT / relative) for _ident, _name, relative in DEFAULT_MOD_PROFILE]
        positions = [managed.index(f'data="{path}"') for path in expected_roots]
        assert positions == sorted(positions)
        assert managed.index("content=Morrowind.esm") < min(positions) or "content=" not in managed
        descriptor = json.loads((tsp_atlas / TSP_ATLAS_DESCRIPTOR_NAME).read_text(encoding="utf-8"))
        assert descriptor["type"] == "data-only-mesh-replacements" and descriptor["content_plugins"] == []
        assert not plugin_files(tsp_atlas)
    print("OPENMW51_MANAGER_BACKEND_V2_SELFTEST_PASS")


def main(argv):
    command = argv[1] if len(argv) > 1 else "status"
    if command == "selftest":
        selftest(); return
    LAUNCHER.mkdir(parents=True, exist_ok=True)
    if command == "status":
        values = write_status()
        print(f"Status refreshed: {values['mods_enabled']} mods, navmesh {values['navmesh_profile']}")
    elif command == "scan":
        values = write_status()
        audit = default_mod_profile_report()
        result(
            f"Mod scan: {values['mods_enabled']} of {values['mods_total']} roots enabled, "
            f"config {values['mods_sync']}, navmesh {values['navmesh_profile']}. Atlas {audit}"
        )
    elif command == "audit":
        print(default_mod_profile_report())
    elif command == "apply":
        apply_mods(); write_status()
    elif command == "default-check":
        validate_default_mod_profile(); print("OPENMW_TSP_DEFAULT_MOD_PROFILE_V1_READY")
    elif command == "apply-default":
        apply_default_mod_profile(); write_status()
    elif command == "toggle" and len(argv) == 3:
        toggle_mod(argv[2]); write_status()
    elif command == "move" and len(argv) == 4:
        move_mod(argv[2], int(argv[3])); write_status()
    elif command == "mark-navmesh":
        mark_navmesh(False); write_status()
    elif command == "mark-default":
        mark_navmesh(True); write_status()
    elif command == "default-path":
        path, label = choose_default_navmesh()
        if path is None:
            raise RuntimeError(label + "; see default-navmesh-candidates.txt")
        print(path)
    else:
        raise ValueError("unknown backend command")


if __name__ == "__main__":
    try:
        main(sys.argv)
    except Exception as exc:
        LAUNCHER.mkdir(parents=True, exist_ok=True)
        result("ERROR " + str(exc))
        raise SystemExit(1)
