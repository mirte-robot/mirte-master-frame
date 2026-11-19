#!/usr/bin/env python3
"""Build the MIRTE Master URDF + xacro from the committed sw2robot extract (no SolidWorks needed).

Runs in the GitHub Action, and locally with a Python that has sw2robot + xacro installed.

Steps
  1. stale check   the SolidWorks files must match the hashes recorded when the extract was made
                   (sw2robot/<robot>.sources.json, written by Sync-Sw2Robot.ps1)
  2. build         sw2robot.exporter.build on a copy of sw2robot/<robot>/ with sw2robot/<robot>.joints.yaml
  3. joint check   every joint in the built model must be in the joint config with the same type, and every
                   joint config entry must match a joint in the model (sw2robot itself only warns and guesses)
  4. package       <out>/<robot>/urdf/<robot>.urdf        (mesh paths relative: ../meshes/...)
                   <out>/<robot>/urdf/<robot>.macro.xacro  (xacro macro: prefix, mesh_path, parent, xyz, rpy)
                   <out>/<robot>/urdf/<robot>.urdf.xacro   (instantiates the macro)
                   <out>/<robot>/meshes/                   (.dae visuals, .stl collisions)
                   <out>/<robot>/build_info.json
  5. validate      URDF tree, mesh files, and that the expanded xacro equals the URDF

Exit code: 0 = OK, 1 = a check failed (stale extract, joint config mismatch, invalid output), 2 = could not build.

Usage
  python tools/urdf/build_urdf.py                         # everything, output in build/urdf-dist
  python tools/urdf/build_urdf.py --out dist
  python tools/urdf/build_urdf.py --check-only            # only the stale check (standard library only)
  python tools/urdf/build_urdf.py --print-sw2robot-version
"""
from __future__ import annotations

import argparse
import copy
import datetime as dt
import glob
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
GH = os.environ.get("GITHUB_ACTIONS") == "true"

REGENERATE_HELP = """\
How to fix (on a Windows PC with SolidWorks and the sw2robot editor):
  1. Pull this branch and run   .\\tools\\urdf\\Sync-Sw2Robot.ps1
  2. In the editor that opens, extract {assembly} again (file browser or path bar),
     check / fix the joints (new parts get a guessed joint type), then close the editor's console window.
  3. Commit the changes in sw2robot/ and push.
See tools/urdf/README.md."""


# --------------------------------------------------------------------------------------------------------------------
# helpers

def log(msg=""):
    print(msg, flush=True)


def gh_annotation(kind, title, msg):
    if GH:
        enc = msg.replace("%", "%25").replace("\r", "").replace("\n", "%0A")
        print(f"::{kind} title={title}::{enc}", flush=True)


def summary(md):
    path = os.environ.get("GITHUB_STEP_SUMMARY")
    if path:
        with open(path, "a", encoding="utf-8") as f:
            f.write(md + "\n")


def fail(code, title, msg):
    log(f"\nERROR: {title}\n{msg}")
    gh_annotation("error", title, msg)
    summary(f"### ❌ {title}\n\n```\n{msg}\n```")
    sys.exit(code)


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def load_config():
    with open(HERE / "urdf.config.json", encoding="utf-8") as f:
        cfg = json.load(f)
    name = cfg["robot_name"]
    d = REPO / cfg.get("sw2robot_dir", "sw2robot")
    return cfg, name, d / name, d / f"{name}.joints.yaml", d / f"{name}.sources.json"


def cad_files(cad_dir: Path):
    """{repo-relative posix path: sha256} of every SolidWorks part / assembly (temp files ~$* excluded)."""
    out = {}
    for p in sorted(cad_dir.rglob("*")):
        if p.is_file() and p.suffix.lower() in (".sldprt", ".sldasm") and not p.name.startswith("~$"):
            out[p.relative_to(REPO).as_posix()] = sha256(p)
    return out


# --------------------------------------------------------------------------------------------------------------------
# 1. stale check

def stale_check(cfg, extract_dir, joints_yaml, sources_json):
    for p, what in ((extract_dir / "graph.json", "sw2robot extract"), (joints_yaml, "joint config"),
                    (sources_json, "extract source hashes")):
        if not p.exists():
            fail(1, f"Missing {what}", f"{p.relative_to(REPO)} does not exist.\n\n" +
                 REGENERATE_HELP.format(assembly=cfg["assembly"]))
    with open(sources_json, encoding="utf-8") as f:
        rec = json.load(f)["files"]
    cur = cad_files(REPO / cfg.get("cad_dir", "solidworks"))
    changed = sorted(k for k in cur if k in rec and cur[k] != rec[k])
    added = sorted(set(cur) - set(rec))
    removed = sorted(set(rec) - set(cur))
    if changed or added or removed:
        lines = ["The SolidWorks model changed after the sw2robot extract was made, so the committed extract",
                 f"(sw2robot/{cfg['robot_name']}/) no longer matches the CAD:"]
        lines += [f"  changed: {p}" for p in changed] + [f"  added:   {p}" for p in added] + \
                 [f"  removed: {p}" for p in removed]
        fail(1, "sw2robot extract is out of date with the SolidWorks model",
             "\n".join(lines) + "\n\n" + REGENERATE_HELP.format(assembly=cfg["assembly"]))
    log(f"Stale check OK: {len(cur)} SolidWorks files match the extract.")


# --------------------------------------------------------------------------------------------------------------------
# 2. build

def run_build(cfg, name, extract_dir, joints_yaml, work):
    if work.exists():
        shutil.rmtree(work)
    pkg = work / name
    shutil.copytree(extract_dir, pkg)
    cfg_copy = pkg / f"{name}.joints.yaml"
    shutil.copyfile(joints_yaml, cfg_copy)
    cmd = [sys.executable, "-m", "sw2robot.exporter.build", str(pkg), "--config", str(cfg_copy), "--ros-pkg"]
    cmd += [str(a) for a in cfg.get("build_args", [])]
    log("\n$ " + " ".join(cmd))
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                            encoding="utf-8", errors="replace", cwd=work)
    out_lines = []
    for line in proc.stdout:
        sys.stdout.write(line)
        out_lines.append(line.rstrip("\n"))
    proc.wait()
    if proc.returncode != 0:
        tail = "\n".join(out_lines[-25:])
        fail(2, "sw2robot build failed", f"sw2robot exited with code {proc.returncode}:\n{tail}\n\n"
             "If the error is about missing meshes or names, the committed extract is probably incomplete.\n" +
             REGENERATE_HELP.format(assembly=cfg["assembly"]))
    # sw2robot's warnings (e.g. geometry missing from the URDF); joint config mismatches are checked ourselves
    warns = []
    for i, l in enumerate(out_lines):
        if re.match(r"\s*WARN(ING)?:", l):
            w = l.strip()
            j = i + 1
            while j < len(out_lines) and re.match(r"\s+- ", out_lines[j]):
                w += " " + out_lines[j].strip()
                j += 1
            warns.append(w)
    descs = [Path(p).parent.parent for p in glob.glob(str(work / "*_description" / "urdf" / "*.urdf"))]
    if len(descs) != 1:
        fail(2, "sw2robot build output not found", f"expected one <name>_description package in {work}, found {descs}")
    desc = descs[0]
    return desc, next((desc / "urdf").glob("*.urdf")), warns


# --------------------------------------------------------------------------------------------------------------------
# 3. joint check

def joint_check(cfg, joints_yaml, urdf_root):
    import yaml  # sw2robot dependency

    with open(joints_yaml, encoding="utf-8") as f:
        jc = yaml.safe_load(f) or {}
    base = jc.get("base")

    links = {l.get("name"): l for l in urdf_root.findall("link")}
    children = {j.find("child").get("link") for j in urdf_root.findall("joint")}
    roots = [n for n in links if n not in children]
    # sw2robot names the root link 'base_link'; the joint config calls it by its part name
    alias = {roots[0]: base} if (base and len(roots) == 1) else {}

    def norm(n):
        return alias.get(n, n)

    model = {}
    for j in urdf_root.findall("joint"):
        p, c = j.find("parent").get("link"), j.find("child").get("link")
        if p == "world":  # --world-link
            continue
        lk = links.get(c)
        if lk is not None and lk.find("visual") is None and lk.find("inertial") is None:
            continue      # frame-only link (port / CAD coordinate system), not a joint config entry
        model[(norm(p), norm(c))] = j.get("type")

    conf = {}
    for e in jc.get("joints") or []:
        conf[(e.get("parent"), e.get("child"))] = e.get("type")

    problems = []
    for (p, c), t in conf.items():
        if (p, c) not in model:
            problems.append(f"  joint config entry '{p} -> {c}' ({t}) matches no joint in the model "
                            "(component renamed, removed or re-inserted?)")
        elif model[(p, c)] != t:
            problems.append(f"  joint '{p} -> {c}': joint config says {t}, model has {model[(p, c)]}")
    for (p, c), t in model.items():
        if (p, c) not in conf:
            problems.append(f"  joint '{p} -> {c}' is not in the joint config; sw2robot guessed '{t}' "
                            "(new or changed component?)")
    if problems:
        fail(1, "Joint config does not match the model",
             f"sw2robot/{joints_yaml.name} does not match the kinematic tree sw2robot built from the extract:\n" +
             "\n".join(problems) + "\n\n" + REGENERATE_HELP.format(assembly=cfg["assembly"]))
    log(f"Joint check OK: {len(conf)} joints in the joint config match the model.")
    return jc


# --------------------------------------------------------------------------------------------------------------------
# 4a. simplify: merge fixed links, one mesh per link

def merge_fixed(root):
    """Fold every fixed-joint child into its parent (mass / inertia lumped, movable joint frames unchanged).
    Links without geometry (ports / coordinate frames placed in the editor, e.g. a sensor frame) are kept."""
    from skrobot.urdf import merge_fixed_links
    n = merge_fixed_links(root, keep_frames=True)
    log(f"Merged {n} fixed links: {len(root.findall('link'))} links, {len(root.findall('joint'))} joints left.")
    return n


def _origin_matrix(o):
    import numpy as np
    from trimesh.transformations import euler_matrix
    if o is None:
        return np.eye(4)
    xyz = [float(v) for v in (o.get("xyz") or "0 0 0").split()]
    rpy = [float(v) for v in (o.get("rpy") or "0 0 0").split()]
    m = euler_matrix(*rpy, "sxyz")
    m[:3, 3] = xyz
    return m


def _part_color(p):
    v = p.visual
    c = getattr(v, "main_color", None)
    if c is None and getattr(v, "material", None) is not None:
        c = getattr(v.material, "main_color", None)
    return None if c is None else tuple(int(x) for x in c)


def _rigid_match(a_parts, b_parts, tol):
    """Return T (4x4) with b = T @ a when the two part lists are the same geometry (vertex for vertex, same colours)
    up to a rotation + translation, else None. Mirrored geometry (det -1) does not match."""
    import numpy as np
    if len(a_parts) != len(b_parts):
        return None
    for a, b in zip(a_parts, b_parts):
        if a.vertices.shape != b.vertices.shape or a.faces.shape != b.faces.shape:
            return None
        if not np.array_equal(a.faces, b.faces) or _part_color(a) != _part_color(b):
            return None
    A = np.vstack([p.vertices for p in a_parts])
    B = np.vstack([p.vertices for p in b_parts])
    ca, cb = A.mean(0), B.mean(0)
    U, _, Vt = np.linalg.svd((A - ca).T @ (B - cb))
    R = (U @ Vt).T
    if np.linalg.det(R) < 0:
        return None
    T = np.eye(4)
    T[:3, :3] = R
    T[:3, 3] = cb - R @ ca
    err = np.abs(A @ R.T + T[:3, 3] - B).max()
    return T if err <= tol else None


def _origin_attrs(T):
    from trimesh.transformations import euler_from_matrix
    f = lambda vals: " ".join("0" if abs(v) < 1e-12 else f"{v:.10g}" for v in vals)
    return {"xyz": f(T[:3, 3]), "rpy": f(euler_from_matrix(T, "sxyz"))}


def _shared_name(names, taken):
    """File name for a mesh shared by several links: their common name without the trailing instance number."""
    prefix = os.path.commonprefix(names)
    base = re.sub(r"[_\-\s]*\d*$", "", prefix) or names[0]
    n, i = base, 2
    while n in taken:
        n, i = f"{base}_{i}", i + 1
    return n


def combine_meshes(root, desc, mesh_out, dedupe=True, tol=1e-6):
    """Replace each link's visuals / collisions by ONE .dae (every part keeps its own colour) and ONE .stl.
    With dedupe, links whose combined geometry is identical up to a rigid transform (e.g. the same wheel used
    several times) share one mesh file, placed with the visual / collision <origin>."""
    import numpy as np
    import trimesh
    from trimesh.exchange.dae import export_collada

    def load(el, kind):
        mesh = el.find("geometry/mesh")
        if mesh is None:  # primitive geometry: cannot be combined
            return None
        if mesh.get("scale") not in (None, "1 1 1", "1.0 1.0 1.0"):
            return None
        src = desc / "meshes" / mesh_rel(mesh.get("filename"))
        if kind == "visual":
            parts = trimesh.load(str(src), force="scene").dump()
        else:
            parts = [trimesh.load(str(src), force="mesh")]
        m = _origin_matrix(el.find("origin"))
        for p in parts:
            p.apply_transform(m)
        return parts

    mesh_out.mkdir(parents=True, exist_ok=True)
    link_names = {l.get("name") for l in root.findall("link")}
    shared = []
    for kind, ext in (("visual", "dae"), ("collision", "stl")):
        # 1. every link's parts, in the link frame
        items = []  # (link, elements, parts)
        for link in root.findall("link"):
            els = link.findall(kind)
            if not els:
                continue
            loaded = [load(e, kind) for e in els]
            if any(x is None for x in loaded):  # keep as-is
                log(f"  {link.get('name')}: {kind} not combined (primitive or scaled geometry)")
                continue
            items.append((link, els, [p for x in loaded for p in x]))
        # 2. group links with the same geometry: groups[i] = [(item, T: canonical -> this link)]
        groups = []
        for it in items:
            for g in groups if dedupe else []:
                T = _rigid_match(g[0][0][2], it[2], tol)
                if T is not None:
                    g.append((it, T))
                    break
            else:
                groups.append([(it, np.eye(4))])
        # 3. one file per group; each link places it with its <origin>
        for g in groups:
            names = [it[0].get("name") for it, _ in g]
            fname = names[0] if len(g) == 1 else _shared_name(names, link_names | {f for f, e, _ in shared if e == ext})
            parts = g[0][0][2]
            out = mesh_out / f"{fname}.{ext}"
            if kind == "visual":
                out.write_bytes(export_collada(parts))
            else:
                trimesh.util.concatenate(parts).export(str(out))
            if len(g) > 1:
                shared.append((fname, ext, names))
            for (link, els, _), T in g:
                first = els[0]
                for e in els:
                    link.remove(e)
                new = ET.Element(kind)
                if first.get("name"):
                    new.set("name", first.get("name"))
                ET.SubElement(new, "origin", _origin_attrs(T))
                ET.SubElement(ET.SubElement(new, "geometry"), "mesh", {"filename": f"meshes/{fname}.{ext}"})
                # visual colours are inside the .dae; a URDF <material> would override them
                idx = 0
                for i, child in enumerate(list(link)):
                    if child.tag in ("inertial", "visual"):
                        idx = i + 1
                link.insert(idx, new)
    for fname, ext, names in shared:
        log(f"  shared mesh {fname}.{ext}: {', '.join(names)}")
    return shared
    # meshes the URDF still points at (not combined) are copied unchanged
    for m in root.iter("mesh"):
        rel = mesh_rel(m.get("filename"))
        if not (mesh_out / rel).exists():
            (mesh_out / rel).parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(desc / "meshes" / rel, mesh_out / rel)


# --------------------------------------------------------------------------------------------------------------------
# 4b. package (URDF with relative meshes, xacro macro, xacro wrapper)

MESH_RE = re.compile(r"^(?:package://[^/]+/)?(?:\.\./)?meshes/(.+)$")


def mesh_rel(fn):
    m = MESH_RE.match(fn.replace("\\", "/"))
    if not m:
        fail(2, "Unexpected mesh reference", f"cannot map mesh '{fn}' to the meshes/ folder")
    return m.group(1)


def write_xml(root, path, header_comment):
    ET.indent(root, space="  ")
    body = ET.tostring(root, encoding="unicode")
    path.write_text(f'<?xml version="1.0" encoding="utf-8"?>\n<!-- {header_comment} -->\n{body}\n', encoding="utf-8")


def make_urdf(src_root, name):
    root = copy.deepcopy(src_root)
    root.set("name", name)
    for m in root.iter("mesh"):
        m.set("filename", "../meshes/" + mesh_rel(m.get("filename")))
    return root


def make_macro(urdf_root, macro):
    """xacro macro of the URDF: names get ${prefix}, meshes ${mesh_path}, optional fixed mount joint to ${parent}."""
    X = "http://www.ros.org/wiki/xacro"
    ET.register_namespace("xacro", X)

    def esc(s):  # a literal '$' in xacro is '$$'
        return s.replace("$", "$$") if s else s

    body = copy.deepcopy(urdf_root)
    for el in body.iter():
        for k, v in list(el.attrib.items()):
            el.set(k, esc(v))
        if el.text and el.text.strip():
            el.text = esc(el.text)
    link_names = {l.get("name") for l in body.findall("link")}
    joint_names = {j.get("name") for j in body.findall("joint")}
    for el in body.iter():
        tag = el.tag
        if tag in ("link", "joint") and el in list(body):
            el.set("name", "${prefix}" + el.get("name"))
        elif tag in ("parent", "child") and el.get("link") in {esc(n) for n in link_names}:
            el.set("link", "${prefix}" + el.get("link"))
        elif tag == "mimic" and el.get("joint") in {esc(n) for n in joint_names}:
            el.set("joint", "${prefix}" + el.get("joint"))
        elif tag == "mesh":
            el.set("filename", "${mesh_path}/" + mesh_rel(el.get("filename").replace("$$", "$")).replace("$", "$$"))
    children = {j.find("child").get("link") for j in urdf_root.findall("joint")}
    base = next(n for n in link_names if n not in children)

    robot = ET.Element("robot", {"name": macro})
    m = ET.SubElement(robot, f"{{{X}}}macro", {
        "name": macro,
        "params": "prefix:='' mesh_path:='../meshes' parent:='' xyz:='0 0 0' rpy:='0 0 0'"})
    cond = ET.SubElement(m, f"{{{X}}}if", {"value": "${parent != ''}"})
    j = ET.SubElement(cond, "joint", {"name": "${prefix}" + esc(base) + "_mount_joint", "type": "fixed"})
    ET.SubElement(j, "parent", {"link": "${parent}"})
    ET.SubElement(j, "child", {"link": "${prefix}" + esc(base)})
    ET.SubElement(j, "origin", {"xyz": "${xyz}", "rpy": "${rpy}"})
    for el in list(body):
        m.append(el)
    return robot


def make_wrapper(name, macro, macro_file):
    X = "http://www.ros.org/wiki/xacro"
    robot = ET.Element("robot", {"name": name})
    ET.SubElement(robot, f"{{{X}}}arg", {"name": "prefix", "default": ""})
    ET.SubElement(robot, f"{{{X}}}arg", {"name": "mesh_path", "default": "../meshes"})
    # relative includes resolve against this file's folder (more portable than $(dirname))
    ET.SubElement(robot, f"{{{X}}}include", {"filename": macro_file})
    ET.SubElement(robot, f"{{{X}}}{macro}", {"prefix": "$(arg prefix)", "mesh_path": "$(arg mesh_path)"})
    return robot


# --------------------------------------------------------------------------------------------------------------------
# 5. validate

def canon(el):
    return ET.canonicalize(ET.tostring(el, encoding="unicode"), strip_text=True)


def validate(pkg_out, urdf_path, xacro_path):
    errs = []
    root = ET.parse(urdf_path).getroot()
    links = [l.get("name") for l in root.findall("link")]
    if len(links) != len(set(links)):
        errs.append("duplicate link names")
    parents = {}
    for j in root.findall("joint"):
        p, c = j.find("parent").get("link"), j.find("child").get("link")
        for n in (p, c):
            if n not in links:
                errs.append(f"joint {j.get('name')} refers to unknown link {n}")
        if c in parents:
            errs.append(f"link {c} has two parents")
        parents[c] = p
    roots = [n for n in links if n not in parents]
    if len(roots) != 1:
        errs.append(f"expected one root link, found {roots}")
    for m in root.iter("mesh"):
        if not (urdf_path.parent / m.get("filename")).resolve().exists():
            errs.append(f"mesh file missing: {m.get('filename')}")

    def run_xacro(*mappings):
        # the xacro command line, as users run it ($(dirname) only resolves there, not via xacro.process_file)
        r = subprocess.run([sys.executable, "-c", "import xacro; xacro.main()", str(xacro_path), *mappings],
                           capture_output=True, text=True, encoding="utf-8")
        if r.returncode != 0:
            errs.append(f"xacro {' '.join(mappings)} failed: {r.stderr.strip()[-500:]}")
            return None
        return ET.fromstring(r.stdout.encode("utf-8"))

    try:
        import xacro  # noqa: F401
    except ImportError:
        log("WARNING: xacro not installed, xacro output not validated")
    else:
        exp = run_xacro()
        if exp is not None:
            a = {(e.tag, e.get("name")): canon(e) for e in root}
            b = {(e.tag, e.get("name")): canon(e) for e in exp}
            if a != b:
                diff = sorted(set(a) ^ set(b)) or sorted(k for k in a if a[k] != b.get(k))
                errs.append(f"expanded xacro differs from the URDF: {diff[:5]}")
        exp2 = run_xacro("prefix:=t_")
        if exp2 is not None and any(not l.get("name", "").startswith("t_") for l in exp2.findall("link")):
            errs.append("xacro prefix is not applied to every link")
    if errs:
        fail(1, "Generated URDF / xacro is invalid", "\n".join("  " + e for e in errs))
    log(f"Validation OK: {len(links)} links, {len(parents)} joints, root '{roots[0]}', xacro expands to the URDF.")
    return len(links), len(parents)


# --------------------------------------------------------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--out", default=str(REPO / "build" / "urdf-dist"), help="output folder (emptied first)")
    ap.add_argument("--check-only", action="store_true", help="only check that the extract matches the CAD")
    ap.add_argument("--skip-stale-check", action="store_true", help="build even if the CAD changed (local tests)")
    ap.add_argument("--print-sw2robot-version", action="store_true",
                    help="print the sw2robot version that made the extract (to install the same in CI)")
    args = ap.parse_args()

    cfg, name, extract_dir, joints_yaml, sources_json = load_config()

    if args.print_sw2robot_version:
        with open(extract_dir / "graph.json", encoding="utf-8") as f:
            ext = (json.load(f).get("source") or {}).get("extractor", "")
        m = re.search(r"(\d+\.\d+\.\d+\S*)", ext)
        print(m.group(1) if m else cfg.get("sw2robot_version", ""))
        return

    if not args.skip_stale_check:
        stale_check(cfg, extract_dir, joints_yaml, sources_json)
    if args.check_only:
        return

    out = Path(args.out).resolve()
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)
    work = out.parent / (out.name + "-work")

    desc, src_urdf, warns = run_build(cfg, name, extract_dir, joints_yaml, work)
    src_root = ET.parse(src_urdf).getroot()
    joint_check(cfg, joints_yaml, src_root)

    pkg_out = out / name
    (pkg_out / "urdf").mkdir(parents=True)
    n_merged = 0
    if cfg.get("merge_fixed", False):
        src_root = copy.deepcopy(src_root)
        n_merged = merge_fixed(src_root)
    shared = []
    if cfg.get("combine_meshes", False):
        shared = combine_meshes(src_root, desc, pkg_out / "meshes", dedupe=cfg.get("dedupe_meshes", True))
        log(f"Combined meshes: {len(list((pkg_out / 'meshes').iterdir()))} mesh files.")
    else:
        shutil.copytree(desc / "meshes", pkg_out / "meshes")
        used = {mesh_rel(m.get("filename")) for m in src_root.iter("mesh")}
        for f in (pkg_out / "meshes").rglob("*"):
            if f.is_file() and f.relative_to(pkg_out / "meshes").as_posix() not in used:
                f.unlink()
    macro = re.sub(r"\W", "_", name).lower()
    gen = (f"Generated by tools/urdf/build_urdf.py from {cfg['assembly']} and "
           f"{joints_yaml.relative_to(REPO).as_posix()}. Do not edit; change the joint config instead.")
    urdf_path = pkg_out / "urdf" / f"{name}.urdf"
    macro_file = f"{name}.macro.xacro"
    xacro_path = pkg_out / "urdf" / f"{name}.urdf.xacro"
    urdf_root = make_urdf(src_root, name)
    write_xml(urdf_root, urdf_path, gen)
    write_xml(make_macro(urdf_root, macro), pkg_out / "urdf" / macro_file,
              gen + f" Usage: <xacro:include filename=\"{macro_file}\"/> <xacro:{macro} prefix=\"\" "
              "mesh_path=\"package://<pkg>/meshes\" parent=\"\" xyz=\"0 0 0\" rpy=\"0 0 0\"/>")
    write_xml(make_wrapper(name, macro, macro_file), xacro_path, gen)

    n_links, n_joints = validate(pkg_out, urdf_path, xacro_path)

    try:
        commit = os.environ.get("GITHUB_SHA") or subprocess.check_output(
            ["git", "-C", str(REPO), "rev-parse", "HEAD"], text=True, stderr=subprocess.DEVNULL).strip()
    except Exception:
        commit = ""
    import importlib.metadata as md
    info = {
        "tool": "mirte-urdf-build", "version": 1,
        "time_utc": dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds"),
        "git_commit": commit, "git_ref": os.environ.get("GITHUB_REF_NAME", ""),
        "sw2robot_version": md.version("sw2robot"),
        "assembly": cfg["assembly"],
        "joints_config": joints_yaml.relative_to(REPO).as_posix(),
        "joints_config_sha256": sha256(joints_yaml),
        "build_args": cfg.get("build_args", []),
        "merge_fixed": bool(cfg.get("merge_fixed", False)), "merged_links": n_merged,
        "combine_meshes": bool(cfg.get("combine_meshes", False)),
        "shared_meshes": {f"{f}.{e}": n for f, e, n in shared},
        "links": n_links, "joints": n_joints,
        "movable_joints": sum(1 for j in urdf_root.findall("joint") if j.get("type") != "fixed"),
        "sw2robot_warnings": warns,
    }
    (pkg_out / "build_info.json").write_text(json.dumps(info, indent=2) + "\n", encoding="utf-8")
    shutil.rmtree(work, ignore_errors=True)

    for w in warns:
        gh_annotation("warning", "sw2robot", w)
    summary(f"### ✅ URDF built\n\n| | |\n|---|---|\n| Links | {n_links} |\n| Joints | {n_joints} "
            f"({info['movable_joints']} movable) |\n| sw2robot | {info['sw2robot_version']} |\n" +
            "".join(f"\n⚠️ {w}\n" for w in warns))
    log(f"\nOutput: {pkg_out}")
    for w in warns:
        log(f"  sw2robot {w}")


if __name__ == "__main__":
    main()
