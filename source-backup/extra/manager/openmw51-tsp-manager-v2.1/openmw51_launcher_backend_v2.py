#!/usr/bin/env python3
"""OpenMW 0.51 TSP manager backend: discovery, dependency sorting and status."""

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

ROOT = Path(os.environ.get("OPENMW51_GAMEDIR", "/mnt/SDCARD/data/ports/openmw51"))
LAUNCHER = ROOT / "launcher"
MODROOT = ROOT / "mods"
CFG = ROOT / "openmw.cfg"
PLAN_JSON = LAUNCHER / "modplan.json"
PLAN_TSV = LAUNCHER / "modplan.tsv"
STATUS = LAUNCHER / "status.conf"
RESULT = LAUNCHER / "last-result.txt"
NAVDIR = Path(os.environ.get("OPENMW51_NAVMESH_DIR", "/mnt/UDISK/openmw51-nav"))
NAVDB = NAVDIR / "navmesh.db"
NAVPROFILE = NAVDIR / "profile.sha256"
SWAP = Path("/mnt/UDISK/openmw51-swapfile")
GENERATOR_CANDIDATES = (
    Path("/mnt/SDCARD/Roms/PORTS/OpenMW_51_Generate_Full_Navmesh_3Worker.sh"),
    Path("/mnt/sdcard/mmcblk1p1/Roms/PORTS/OpenMW_51_Generate_Full_Navmesh_3Worker.sh"),
)
BASE_PLUGINS = {"morrowind.esm", "tribunal.esm", "bloodmoon.esm", "builtin.omwscripts"}
PLUGIN_EXTS = {".esm", ".esp", ".omwaddon", ".omwgame"}
DATA_DIRS = {"meshes", "textures", "icons", "sound", "music", "bookart", "fonts", "video", "shaders", "scripts", "groundcover"}


def atomic_text(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".tmp")
    with tmp.open("w", encoding="utf-8", newline="\n") as out:
        out.write(text)
        out.flush()
        os.fsync(out.fileno())
    os.replace(tmp, path)


def result(message: str) -> None:
    clean = " ".join(message.replace("=", ":").split())[:150]
    atomic_text(RESULT, clean + "\n")
    print(clean)


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
    try:
        lines = CFG.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        lines = []
    cfg_data, _ = cfg_entries(lines)
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
    def root_priority(path: Path):
        try:
            label = str(path.relative_to(MODROOT.resolve()))
        except ValueError:
            label = str(path)
        return old_order.get(str(path), 10**6), cfg_order.get(str(path), 10**6), natural(label)
    roots = sorted(set(roots), key=root_priority)
    plan = []
    for p in roots:
        key = str(p)
        prior = old_by_path.get(key, {})
        enabled = bool(prior.get("enabled", key in cfg_paths))
        ident = hashlib.sha1(key.encode("utf-8")).hexdigest()[:12]
        try:
            name = str(p.relative_to(MODROOT.resolve()))
        except ValueError:
            name = p.name + " (configured)"
        plan.append({"id": ident, "name": name, "path": key, "enabled": enabled, "needs_navmesh": collision_sensitive(p)})
    save_plan(plan)
    return plan


def save_plan(plan) -> None:
    atomic_text(PLAN_JSON, json.dumps(plan, indent=2, sort_keys=True) + "\n")
    rows = ["# id\tenabled\tneeds_navmesh\tname\tpath"]
    for item in plan:
        clean_name = str(item["name"]).replace("\t", " ").replace("\n", " ")
        clean_path = str(item["path"]).replace("\t", " ").replace("\n", " ")
        rows.append("\t".join((item["id"], "1" if item["enabled"] else "0", "1" if item["needs_navmesh"] else "0", clean_name, clean_path)))
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
        lines = CFG.read_text(encoding="utf-8", errors="replace").splitlines()
        _, existing = cfg_entries(lines)
        all_mod_names = {p.name.casefold() for item in plan for p in plugin_files(Path(item["path"]))}
        external = [x for x in existing if x.casefold() not in all_mod_names]
        sort_plugins(selected_plugins(plan), external)
        return "VALID"
    except (OSError, ValueError) as exc:
        return "ERROR: " + str(exc)


def apply_mods():
    plan = discover_mods()
    lines = CFG.read_text(encoding="utf-8", errors="replace").splitlines()
    _data, existing_content = cfg_entries(lines)
    all_mod_plugins = {p.name.casefold() for item in plan for p in plugin_files(Path(item["path"]))}
    external_content = [x for x in existing_content if x.casefold() not in all_mod_plugins]
    sorted_plugins = sort_plugins(selected_plugins(plan), external_content)
    managed_roots = {str(Path(x["path"]).resolve()) for x in plan}
    cleaned = []
    inside = False
    for line in lines:
        if line.strip() == "# TSP_MANAGER_V2_BEGIN":
            inside = True
            continue
        if line.strip() == "# TSP_MANAGER_V2_END":
            inside = False
            continue
        if inside:
            continue
        s = line.strip()
        if s.startswith("data="):
            try:
                path = cfg_path(unquote(s[5:]))
                if str(path) in managed_roots:
                    continue
            except OSError:
                pass
        if s.startswith("content=") and unquote(s[8:]).casefold() in all_mod_plugins:
            continue
        cleaned.append(line)
    block = ["", "# TSP_MANAGER_V2_BEGIN", "# Managed data order; edit through OpenMW 0.51 Manager V2."]
    for item in plan:
        if item["enabled"]:
            escaped = str(item["path"]).replace("\\", "\\\\").replace('"', r'\"')
            block.append(f'data="{escaped}"')
    for path in sorted_plugins:
        block.append("content=" + path.name)
    block.append("# TSP_MANAGER_V2_END")
    new_text = "\n".join(cleaned + block).rstrip() + "\n"
    backup_dir = LAUNCHER / "backups"
    backup_dir.mkdir(parents=True, exist_ok=True)
    stamp = time.strftime("%Y%m%d-%H%M%S") + f"-{time.time_ns() % 1_000_000_000:09d}"
    backup = backup_dir / f"openmw.cfg.before-manager-{stamp}"
    shutil.copy2(CFG, backup)
    try:
        atomic_text(CFG, new_text)
        check = CFG.read_text(encoding="utf-8", errors="strict")
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
    except Exception:
        shutil.copy2(backup, CFG)
        raise
    backups = sorted(backup_dir.glob("openmw.cfg.before-manager-*"), key=lambda p: p.stat().st_mtime, reverse=True)
    for old in backups[10:]:
        old.unlink(missing_ok=True)
    result(f"Applied {sum(1 for x in plan if x['enabled'])} mod roots and {len(sorted_plugins)} dependency-sorted plugins")


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
    override = LAUNCHER / "default-navmesh.path"
    if override.is_file():
        try:
            path = Path(override.read_text().strip())
            if sqlite_navmesh(path) and path != NAVDB:
                return [(10**6, path)]
        except OSError:
            pass
    base = Path("/mnt/SDCARD/data/ports") if base is None else Path(base)
    candidates = []
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
    try:
        data, _ = cfg_entries(CFG.read_text(encoding="utf-8", errors="replace").splitlines())
        candidates.extend(Path(x) / "Morrowind.esm" for x in data)
    except OSError:
        pass
    return any(path.is_file() for path in candidates)


def write_status():
    plan = discover_mods()
    profile, mod_kind = profile_hash(plan)
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
    gen = generator_path()
    values = {
        "game": int(game_found()), "udisk": udisk, "udisk_fs": fs_kind or "UNMOUNTED", "udisk_free": free,
        "navmesh": nav, "navmesh_size": NAVDB.stat().st_size if NAVDB.is_file() else 0, "navmesh_target": str(NAVDB),
        "navmesh_profile": nav_state, "profile_hash": profile, "mod_navmesh": mod_kind,
        "default_navmesh_ready": int(source is not None), "default_navmesh": source_label,
        "swap_file": int(SWAP.is_file()), "swap_active": int(swap_active()), "swap_size": SWAP.stat().st_size if SWAP.is_file() else 0, "swap_target": str(SWAP),
        "mods_total": len(plan), "mods_enabled": sum(1 for x in plan if x["enabled"]), "plugin_status": plugin_health(plan),
        "config": str(CFG), "generator": int(gen is not None), "generator_path": str(gen) if gen else "NOT FOUND",
    }
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
    global ROOT, LAUNCHER, MODROOT, CFG, PLAN_JSON, PLAN_TSV, STATUS, RESULT, NAVDIR, NAVDB, NAVPROFILE, SWAP
    with tempfile.TemporaryDirectory() as tmp:
        ROOT = Path(tmp) / "openmw51"; LAUNCHER = ROOT / "launcher"; MODROOT = ROOT / "mods"; CFG = ROOT / "openmw.cfg"
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
        base_nav = ports / "openmw51-assets" / "prebuilt" / "base-navmesh.db"
        for nav in (old_nav, base_nav):
            nav.parent.mkdir(parents=True, exist_ok=True)
            with nav.open("wb") as out:
                out.write(b"SQLite format 3\0"); out.seek(1024 * 1024 + 7); out.write(b"\0")
        candidates = default_navmesh_candidates(ports)
        assert [path for _score, path in candidates] == [base_nav]
        toggle_mod(plan[0]["id"]); assert not read_plan()[0]["enabled"]
        move_mod(plan[1]["id"], -1); assert read_plan()[0]["id"] == plan[1]["id"]
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
        values = write_status(); result(f"Mod scan refreshed: {values['mods_enabled']} enabled, navmesh {values['navmesh_profile']}")
    elif command == "apply":
        apply_mods(); write_status()
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
