#!/usr/bin/env python3
"""Run the GitHub Action's checks locally, on exactly what you would push.

The checks in the working folder can pass while the Action fails: uncommitted or untracked files, or line-ending
conversion by git (core.autocrlf). So this script writes the committed files (HEAD, or --staged for what is staged
now) byte for byte, as GitHub's checkout gets them, to a temporary folder and runs the checks there:

  1. tools/urdf/build_urdf.py --check-only   sw2robot extract matches the SolidWorks files
  2. tools/export/check_exports.py           STEP / STL / DXF exports match the SolidWorks files

It does not build the URDF (that needs sw2robot installed; run tools/urdf/build_urdf.py for that).
Standard library + git only.

Usage (from the repository root):
  python tools/check_before_push.py            # check the last commit (HEAD)
  python tools/check_before_push.py --staged   # check what is staged (git add) but not committed yet
  python tools/check_before_push.py --install-hook   # run it automatically before every git push
Exit code 0 = all checks pass (the Action's checks will pass), 1 = a check fails.
"""
import argparse
import os
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
CHECKS = [
    ("sw2robot extract (URDF)", ["tools/urdf/build_urdf.py", "--check-only"]),
    ("part exports (STEP/STL/DXF)", ["tools/export/check_exports.py"]),
]
HOOK = """#!/bin/sh
# installed by tools/check_before_push.py --install-hook; skip once with: git push --no-verify
exec python tools/check_before_push.py
"""


def git(*args, **kw):
    return subprocess.run(["git", "-C", str(REPO), *args], check=True, **kw)


def materialize(dst: Path, staged: bool) -> int:
    """Write every file of HEAD (or the index) to dst, raw blob bytes = what a Linux checkout gets."""
    if staged:
        out = git("ls-files", "-s", "-z", capture_output=True).stdout
        entries = [(e.split(b" ")[1], e.split(b"\t", 1)[1]) for e in out.split(b"\0") if e]
    else:
        out = git("ls-tree", "-r", "-z", "HEAD", capture_output=True).stdout
        entries = [(e.split(b" ")[2].split(b"\t")[0], e.split(b"\t", 1)[1]) for e in out.split(b"\0") if e]
    proc = subprocess.Popen(["git", "-C", str(REPO), "cat-file", "--batch"],
                            stdin=subprocess.PIPE, stdout=subprocess.PIPE)
    n = 0
    for sha, path in entries:
        proc.stdin.write(sha + b"\n")
        proc.stdin.flush()
        header = proc.stdout.readline().split()
        if len(header) < 3 or header[1] != b"blob":   # submodule or missing object
            continue
        data = proc.stdout.read(int(header[2]))
        proc.stdout.read(1)  # trailing newline
        p = dst / os.fsdecode(path)
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(data)
        n += 1
    proc.stdin.close()
    proc.wait()
    return n


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--staged", action="store_true", help="check the staged files instead of the last commit")
    ap.add_argument("--install-hook", action="store_true", help="install as git pre-push hook")
    args = ap.parse_args()

    if args.install_hook:
        hooks = Path(git("rev-parse", "--git-path", "hooks", capture_output=True, text=True).stdout.strip())
        hooks = hooks if hooks.is_absolute() else REPO / hooks
        hooks.mkdir(parents=True, exist_ok=True)
        (hooks / "pre-push").write_text(HOOK, newline="\n")
        print(f"Installed {hooks / 'pre-push'}: every git push now runs these checks first "
              "(skip once with git push --no-verify).")
        return 0

    what = "staged files" if args.staged else "last commit (HEAD)"
    dirty = git("status", "--porcelain", "--", "solidworks", "sw2robot", "exports",
                capture_output=True, text=True).stdout.rstrip()
    if args.staged:  # only changes in the working folder that are not staged (2nd status column)
        dirty = "\n".join(l for l in dirty.splitlines() if len(l) > 1 and l[1] != " ")
    with tempfile.TemporaryDirectory(prefix="mirte-check-") as tmp:
        print(f"Checking the {what}, as GitHub sees it ...")
        n = materialize(Path(tmp), args.staged)
        print(f"  {n} files")
        failed = []
        for name, cmd in CHECKS:
            print(f"\n== {name}")
            r = subprocess.run([sys.executable, *cmd], cwd=tmp)
            if r.returncode != 0:
                failed.append(name)
    print()
    if dirty:
        print("Note: solidworks/, sw2robot/ or exports/ have changes that are not "
              f"{'staged' if args.staged else 'committed'}; they were NOT checked:")
        print("\n".join("  " + l for l in dirty.splitlines()[:15]))
        print()
    if failed:
        print("FAILED: " + ", ".join(failed) + ". The GitHub Action would fail; fix this before pushing.")
        return 1
    print("All checks pass: the GitHub Action's checks will pass for this "
          f"{'staged state (once committed)' if args.staged else 'commit'}.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
