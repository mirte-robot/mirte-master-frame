#!/usr/bin/env python3
"""Check that the committed part exports (exports/, made by Export-Parts.ps1) match the SolidWorks files.

Runs in the GitHub Action (no SolidWorks there, so the export itself is made locally). Standard library only.

Fails (exit 1) when:
  - the export is missing, or the export run reported failed parts;
  - an exported part file (.SLDPRT) changed after the export;
  - any assembly (.SLDASM) was added, removed or changed after the export: assemblies decide which parts and
    configurations are exported, and in which group;
  - an output file (STEP / STL / DXF) listed in the manifest is missing or was modified, or an output file is not
    in the manifest.

Usage:
  python tools/export/check_exports.py            # check
  python tools/export/check_exports.py --out DIR  # check, then copy the exports to DIR (for the artifact)
"""
import argparse
import hashlib
import json
import os
import shutil
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
OUT_EXT = {".step", ".stl", ".dxf"}

HELP = """How to fix (on a Windows PC with SolidWorks):
  1. Open {assembly} in SolidWorks.
  2. Run  .\\tools\\export\\Export-Parts.ps1   (writes {out_dir}/; unchanged parts keep their files)
  3. Commit {out_dir}/ and push."""


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def gh_escape(s: str) -> str:
    return s.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")


def fail(title: str, body: str, help_text: str):
    print(f"\nERROR: {title}\n\n{body}\n\n{help_text}", file=sys.stderr)
    if os.environ.get("GITHUB_ACTIONS"):
        print(f"::error title={gh_escape(title)}::{gh_escape(body)}")
        summary = os.environ.get("GITHUB_STEP_SUMMARY")
        if summary:
            with open(summary, "a", encoding="utf-8") as f:
                f.write(f"## :x: Part exports: {title}\n\n```\n{body}\n\n{help_text}\n```\n")
    sys.exit(1)


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--out", help="copy the checked exports to this folder")
    args = ap.parse_args()

    with open(HERE / "export.config.json", encoding="utf-8") as f:
        cfg = json.load(f)
    out_dir = cfg.get("out_dir", "exports")
    help_text = HELP.format(assembly=cfg["assembly"], out_dir=out_dir)
    exp = REPO / out_dir
    man_path = exp / "export_manifest.json"
    if not man_path.exists():
        fail("No part exports", f"{out_dir}/export_manifest.json does not exist.", help_text)
    with open(man_path, encoding="utf-8-sig") as f:  # Windows PowerShell writes a BOM
        man = json.load(f)

    problems = []
    if not man.get("passed", False):
        problems.append("the export run had failed parts (see export_report.txt)")
    if "assemblies" not in man:
        problems.append("the manifest has no assembly hashes (made by an older Export-Parts.ps1)")

    # exported parts: their source file must be unchanged
    listed = set()
    for p in man.get("parts", []):
        if p.get("kind") == "none":
            continue
        src = REPO / p["source"]
        what = f'{p["source"]} ({p.get("configuration", "")})'
        if not src.exists():
            problems.append(f"removed: {what}")
        elif sha256(src) != p["source_sha256"]:
            problems.append(f"changed: {what}")
        for o in p.get("outputs", []):
            listed.add(o["path"])
            q = REPO / o["path"]
            if not q.exists():
                problems.append(f"output missing: {o['path']}")
            elif sha256(q) != o["sha256"]:
                problems.append(f"output modified by hand: {o['path']}")

    # assemblies: decide which parts are exported
    rec = man.get("assemblies", {}) or {}
    cur = {p.relative_to(REPO).as_posix(): p for p in (REPO / "solidworks").rglob("*")
           if p.is_file() and p.suffix.lower() == ".sldasm" and not p.name.startswith("~$")}
    for k in sorted(set(cur) | set(rec)):
        if k not in rec:
            problems.append(f"assembly added: {k}")
        elif k not in cur:
            problems.append(f"assembly removed: {k}")
        elif sha256(cur[k]) != rec[k]:
            problems.append(f"assembly changed: {k}")

    # stray output files (e.g. left from an older export)
    for q in sorted(exp.rglob("*")):
        if q.is_file() and q.suffix.lower() in OUT_EXT and q.relative_to(REPO).as_posix() not in listed:
            problems.append(f"output not in the manifest: {q.relative_to(REPO).as_posix()}")

    if problems:
        fail("Part exports are out of date with the SolidWorks model",
             f"The committed exports ({out_dir}/) no longer match the CAD:\n" +
             "\n".join(f"  {p}" for p in problems), help_text)

    n = {k: sum(1 for x in listed if x.lower().endswith(k)) for k in (".step", ".stl", ".dxf")}
    print(f"Part exports OK: {n['.step']} STEP, {n['.stl']} STL, {n['.dxf']} DXF; "
          f"{len(cur)} assemblies match (exported {man.get('time_utc', '?')}).")

    if args.out:
        dst = Path(args.out)
        if dst.exists():
            shutil.rmtree(dst)
        shutil.copytree(exp, dst)
        print(f"Copied to {dst}")
        summary = os.environ.get("GITHUB_STEP_SUMMARY")
        if summary:
            with open(summary, "a", encoding="utf-8") as f:
                f.write(f"## Part exports\n\n| STEP | STL | DXF |\n|---|---|---|\n"
                        f"| {n['.step']} | {n['.stl']} | {n['.dxf']} |\n")


if __name__ == "__main__":
    main()
